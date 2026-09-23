# Red Hat Directory Server (RHDS 12 / 389ds) Advanced Replication & Conflict Operations Guide

**Document Version:** 1.0.0  
**Target Platform:** Red Hat Directory Server 12 / 389 Directory Server (RHEL 9)  

---

## 1. Executive Summary

Red Hat Directory Server (RHDS 12 / 389-ds) provides high-availability multi-supplier replication (active-active topology), allowing multiple directory servers to accept read and write operations concurrently. 

This guide details:
1. Operational differences between `systemctl` (OS daemon lifecycle) and `dsctl` (instance and database maintenance).
2. Deployment workflows for multi-supplier active-active topology.
3. Internal conflict resolution mechanics (CSN timestamps, state tracking, glue entries, and naming collisions).
4. Network load balancing dynamics (HAProxy / DNS SRV impact on replication traffic).
5. Automated cluster auditing scripts for replication conflicts (`nsds5ReplConflict`).

---

## 2. Administration Layering: `systemctl` vs `dsctl`

When managing 389 Directory Server on RHEL 9, administration is split across two distinct system layers:

| Feature / Aspect | `systemctl` | `dsctl` |
| :--- | :--- | :--- |
| **Primary Scope** | RHEL Systemd Daemon Lifecycle | 389 Directory Server Instance Maintenance |
| **Target Unit / Syntax** | `dirsrv@<instance_name>.service` | `dsctl <instance_name> <command>` |
| **Operational State** | OS Process (PID 1 tracking of `ns-slapd`) | Internal database state, indexing, backups |
| **Database Tasks** | None | `db2ldif`, `ldif2db`, `db2bak`, `bak2db`, `db2index` |
| **Online Configuration** | N/A | Offline instance control (`dsconf` used for online LDAP) |

### 2.1 Workflow Synergy
For operations requiring an offline database engine (such as binary restores via `bak2db`), both utilities are combined:

```bash
# 1. Stop OS daemon
sudo systemctl stop dirsrv@app-user-store

# 2. Perform offline binary restore
sudo dsctl app-user-store bak2db /var/lib/dirsrv/backups/bak_20260918

# 3. Start OS daemon
sudo systemctl start dirsrv@app-user-store
```

---

## 3. Multi-Supplier Topology Deployment

Multi-supplier replication is configured at the **database suffix level** (e.g., `dc=app,dc=company,dc=com`). Each node requires a unique 16-bit **Replica ID** and dedicated replication manager credentials.

```text
               Bilateral Replication (LDAP 389/636)
┌─────────────────────────┐                   ┌─────────────────────────┐
│  RHDS Supplier 01       │◄─────────────────►│  RHDS Supplier 02       │
│  Replica ID: 1          │                   │  Replica ID: 2          │
│  Suffix: dc=app,dc=com  │                   │  Suffix: dc=app,dc=com  │
└─────────────────────────┘                   └─────────────────────────┘
```

### 3.1 Step-by-Step CLI Configuration

```bash
# Node 1 (Supplier 01)
sudo dsconf app-user-store backend changelog create --suffix "dc=app,dc=company,dc=com"
sudo dsconf app-user-store replication enable --suffix "dc=app,dc=company,dc=com" --role "supplier" --replica-id 1

# Node 2 (Supplier 02)
sudo dsconf app-user-store backend changelog create --suffix "dc=app,dc=company,dc=com"
sudo dsconf app-user-store replication enable --suffix "dc=app,dc=company,dc=com" --role "supplier" --replica-id 2

# Create Replication Manager on both nodes
sudo dsconf app-user-store manager create --dn "cn=replication manager,cn=config" --password "ReplPass2026!"

# Create Bilateral Replication Agreements
# On Supplier 01:
sudo dsconf app-user-store replication create-agmt --suffix "dc=app,dc=company,dc=com" \
  --host "supplier-02.company.com" --port 389 --conn-protocol LDAP \
  --bind-dn "cn=replication manager,cn=config" --bind-passwd "ReplPass2026!" "agmt_01_to_02"

# On Supplier 02:
sudo dsconf app-user-store replication create-agmt --suffix "dc=app,dc=company,dc=com" \
  --host "supplier-01.company.com" --port 389 --conn-protocol LDAP \
  --bind-dn "cn=replication manager,cn=config" --bind-passwd "ReplPass2026!" "agmt_02_to_01"

# Initialize Data Sync (Supplier 01 -> Supplier 02)
sudo dsconf app-user-store replication init-agmt --suffix "dc=app,dc=company,dc=com" "agmt_01_to_02"
```

---

## 4. Conflict Resolution Architecture (`urp.c`)

When concurrent writes occur across multiple suppliers, 389 Directory Server employs automated update resolution protocols to ensure data convergence without locking.

### 4.1 Change State Numbers (CSNs)
Every update generates a 4-part **Change State Number (CSN)**:
1. **Timestamp**: 1-second resolution Unix `time_t`.
2. **Sequence Number**: Sub-second operation counter.
3. **Replica ID**: 16-bit integer identifying originating supplier.
4. **Sub-sequence Number**: Transaction step marker.

### 4.2 3-Step Evaluation Hierarchy
When two updates target the same attribute, the higher CSN takes precedence:

```text
Step 1: Compare Timestamps  ───(If equal)───►  Step 2: Compare Sequence Numbers  ───(If equal)───►  Step 3: Compare Replica IDs
 (Higher Unix time wins)                         (Higher sequence count wins)                       (Higher Replica ID wins)
```

Because Replica IDs are unique across the cluster, Step 3 provides a **100% deterministic tie-breaker**.

### 4.3 Structural Conflict Mechanics

* **Attribute Conflicts (Last-Write-Wins)**: Evaluates CSNs and updates the active value. Metadata is stored in the operational attribute `nscpEntryWSI` (With State Information).
* **Parent-Child Deletion Conflicts ("Glue Entries")**: If Supplier A deletes a container (`ou=Sales`) while Supplier B adds a child (`cn=Alice,ou=Sales`), the deleted container is converted into a **tombstone entry** (`objectclass=nsTombstone`) and resurrected into a **glue entry** (`objectclass=glue`). This preserves tree hierarchy until child records are removed.
* **Naming Collisions**: If two users with the exact same RDN are added simultaneously on different suppliers, the winning CSN retains the requested name. The losing entry is automatically renamed by appending its `nsUniqueId` (`cn=John Smith+nsuniqueid=<UUID>`) and tagged with **`nsds5ReplConflict: naming conflict`**.

---

## 5. Load Balancing & Replication Volume Impact

Distributing incoming client LDAP queries across active-active suppliers via HAProxy or DNS SRV **does not increase replication network overhead**:

* **Read Operations (90%+ of traffic)**: `SEARCH` and `BIND` requests are handled locally by the receiving supplier and generate **zero replication traffic**.
* **Write Operations (100% constant payload)**: Replication volume depends on the total count of write operations executed, not which supplier receives them. 100 writes to Supplier 01 produce 100 replication updates to Supplier 02. Splitting writes (50 to 01, 50 to 02) produces 50 updates in each direction, totaling the exact same **100 replication updates**.
* **Sticky Sessions**: HAProxy sticky sessions (`balance source` or `stick-table`) are recommended to avoid read-after-write consistency delays during sub-second replication propagation windows.

---

## 6. Conflict Audit Tools

### 6.1 Bash Audit Utility (`audit-rhds-conflicts.sh`)
```bash
#!/usr/bin/env bash
# Usage: ./audit-rhds-conflicts.sh -b "dc=app,dc=company,dc=com" -s "supplier01 supplier02" -D "cn=Directory Manager" -y /etc/dirsrv/pw.txt
set -euo pipefail

BASE_DN=""
SUPPLIERS=""
BIND_DN=""
PW_FILE=""
EMAIL=""
PORT=389

while [[ $# -gt 0 ]]; do
  case "$1" in
    -b|--base-dn) BASE_DN="$2"; shift 2 ;;
    -s|--suppliers) SUPPLIERS="$2"; shift 2 ;;
    -D|--bind-dn) BIND_DN="$2"; shift 2 ;;
    -y|--pw-file) PW_FILE="$2"; shift 2 ;;
    -m|--email) EMAIL="$2"; shift 2 ;;
    *) shift ;;
  esac
done

TOTAL_CONFLICTS=0
REPORT="RHDS Replication Conflict Audit Summary\nGenerated: $(date)\n========================================\n"

for SUPPLIER in $SUPPLIERS; do
  REPORT+="\n--- Checking Supplier: ${SUPPLIER} ---\n"
  ENTRIES=$(ldapsearch -x -h "$SUPPLIER" -p "$PORT" -D "$BIND_DN" -y "$PW_FILE" \
    -b "$BASE_DN" "(&(!(objectclass=nstombstone))(nsds5ReplConflict=*))" dn nsds5ReplConflict 2>/dev/null || true)
  
  COUNT=$(echo "$ENTRIES" | grep -c "^dn:" || true)
  if [ "$COUNT" -gt 0 ]; then
    TOTAL_CONFLICTS=$((TOTAL_CONFLICTS + COUNT))
    REPORT+="[ALERT] Found ${COUNT} conflict entries on ${SUPPLIER}:\n${ENTRIES}\n"
  else
    REPORT+="[PASS] Zero conflicts detected.\n"
  fi
done

echo -e "$REPORT"

if [ "$TOTAL_CONFLICTS" -gt 0 ] && [ -n "$EMAIL" ]; then
  echo -e "$REPORT" | mail -s "[ALERT] RHDS Replication Conflicts Detected (${TOTAL_CONFLICTS})" "$EMAIL"
  exit 1
fi

[ "$TOTAL_CONFLICTS" -eq 0 ] && exit 0 || exit 1
```

---

## 7. Upstream References

* [389 Directory Server Architecture](https://www.port389.org/docs/389ds/design/architecture.html)
* [Red Hat Documentation: Managing Replication in IdM/RHDS](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/managing_replication_in_identity_management/index)
* [389ds Ansible Galaxy Collection (`ansible-ds`)](https://github.com/389ds/ansible-ds)
