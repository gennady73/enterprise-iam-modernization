# Wiki: 389 Directory Server Replication Recovery and Verification Playbook

This playbook provides step-by-step procedures to deploy automated backup and restore frameworks, simulate active replica node crashes, execute automated database recoveries using your custom recovery utilities, and successfully rejoin hosts back into your high-availability multi-supplier replication topology.

Official manuals for deeper reference:
*   [Red Hat Enterprise Linux 9: Performing disaster recovery with Identity Management](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html-single/performing_disaster_recovery_with_identity_management/index)
*   [Red Hat Directory Server 12: Configuring and managing replication](https://docs.redhat.com/en/documentation/red_hat_directory_server/12/html-single/configuring_and_managing_replication/index)

---

## 1. Automated Directory Backup and Recovery Utilities

To establish a resilient infrastructure, we deploy two dedicated administrative tools: **`ds389-backup-manager.sh`** and **`ds389-restore-manager.sh`**. These scripts must be deployed on every standalone 389-ds supplier or IdM master node.

### A. Deploy and Schedule the Backup Manager (`ds389-backup-manager.sh`)

The Backup Manager is a non-disruptive, production-grade utility that automates directory server snapshot lifecycles. It utilizes the native `dsctl` tool to execute safe backups without interrupting client read/write connections.

#### How to Deploy and Schedule the Backup Manager
1.  **Deploy the Script**: Save the backup manager script into the administrative bin folder:
    ```bash
    # Move script to the standard executable path
    mv ds389-backup-manager.sh /usr/local/sbin/ds389-backup-manager.sh
    ```
2.  **Apply Security Permissions**: Restrict script execution exclusively to the `root` administrative account to protect the embedded Directory Manager credential:
    ```bash
    chown root:root /usr/local/sbin/ds389-backup-manager.sh
    chmod 700 /usr/local/sbin/ds389-backup-manager.sh
    ```
3.  **Configure Cron Scheduling**: Automate daily backups by creating a cron configuration file `/etc/cron.d/ds389-backup`:
    ```ini
    # Schedule the backup manager to run daily at 2:00 AM
    00 02 * * * root /usr/local/sbin/ds389-backup-manager.sh &> /dev/null
    ```

#### Core Features of the Backup Manager
*   **Logical flat-text Exports (`db2ldif`)**: Executes online, portable LDIF database exports of your suffixes. Excellent for migrations, cross-architecture restores, or manual record audits.
*   **Physical binary Backups (`db2bak`)**: Generates high-speed, hot-database binary snapshots of Berkeley DB directories, allowing instantaneous system restorations.
*   **Automated Rolling Retention**: Scans backup directories and automatically purges old backups exceeding your retention policy (default is `14` days), keeping disk usage under control.
*   **Validation & Disk Space Checks**: Confirms files are written correctly, and appends a partition capacity audit directly to `/var/log/dirsrv/ds389-backup-manager.log`.

---

### B. Deploy and Use the Restore Manager (`ds389-restore-manager.sh`)

The Restore Manager is a parameters-driven database restoration manager. It automates physical binary restores (`bak2db`) and logical LDIF imports (`ldif2db`) while handling the systemd service state transitions safely.

#### Core Features of the Restore Manager
*   **Dual-Engine Support**: Seamlessly accepts both physical DB backup folders (running high-speed block restorations) and logical LDIF text files (re-indexing schema strings).
*   **Service Orchestration**: Automatically executes systemd service locking, stopping target `dirsrv@instance-name` processes before writing data, and restarting the service post-restore.
*   **Safety Guards**: Enforces mandatory terminal confirmation prompts to prevent accidental database overwrites, which can be bypassed in Ansible pipelines with the `-f` flag.
*   **Integrity Verifications**: Conducts local socket tests, checks LDAP Root DSE connectivity, and checks the Replication Update Vector (RUV) values.

#### How to Deploy and Use the Restore Manager
1.  **Deploy and Restrict the Utility**:
    ```bash
    mv ds389-restore-manager.sh /usr/local/sbin/ds389-restore-manager.sh
    chown root:root /usr/local/sbin/ds389-restore-manager.sh
    chmod 700 /usr/local/sbin/ds389-restore-manager.sh
    ```
2.  **Command-Line Options**:
    *   `-i` : 389-ds instance name (e.g., `slapd-app-user-store`) [Required].
    *   `-p` : Absolute path to the backup (directory for physical backup, file for LDIF) [Required].
    *   `-s` : Suffix domain (required for logical LDIF imports, e.g., `dc=app,dc=company,dc=com`).
    *   `-f` : Force execution unattended, skipping interactive warning checkpoints.

3.  **Restore Command Examples**:
    *   *To restore a physical binary backup directory (Active/Active Supplier)*:
        ```bash
        sudo /usr/local/sbin/ds389-restore-manager.sh \
          -i slapd-app-user-store \
          -p /var/lib/dirsrv/backups/ds_backup_20260901_020000/slapd-app-user-store_db_bak
        ```
    *   *To restore a logical LDIF flat-text export file*:
        ```bash
        sudo /usr/local/sbin/ds389-restore-manager.sh \
          -i slapd-app-user-store \
          -p /var/lib/dirsrv/backups/ds_backup_20260901_020000/slapd-app-user-store_backup_20260901_020000.ldif \
          -s "dc=app,dc=company,dc=com"
        ```

---

## 2. Phase 1: Simulating an Active Replica Crash

To validate your backup and restore pipelines, administrators must periodically run automated disaster drills. In this section, we simulate a complete database volume corruption on a secondary replica node (`host-b.company.com`).

### Step-by-Step Simulation Commands
1.  **Stop the Active Directory Server Instance**:
    To prevent active file descriptors or incomplete locks from altering your file paths, cleanly stop the target slapd service:
    ```bash
    systemctl stop dirsrv@slapd-app-user-store
    ```
2.  **Simulate Database Volume Corruption**:
    Delete the underlying Berkeley DB files, index trees, and active transactional logs to simulate a catastrophic hardware volume failure:
    ```bash
    # Wipe the database storage directory completely
    rm -rf /var/lib/dirsrv/slapd-app-user-store/db/*
    ```
3.  **Attempt Startup (Failure Verification)**:
    Attempting to start the service now will result in database initialization errors. The slapd daemon will exit immediately, and the journal logs will report missing databases:
    ```bash
    systemctl start dirsrv@slapd-app-user-store
    # Inspect service state (expect failed/error status)
    systemctl status dirsrv@slapd-app-user-store
    ```

---

## 3. Phase 2: Restoring the Node using the Restore Manager

Using your pre-compiled restore utility (**`ds389-restore-manager.sh`**), you will perform a physical block-level restore of the transacted database engine.

### Step-by-Step Recovery Commands
1.  **Locate the Latest Hot Backup Directory**:
    Identify your latest verified directory-level backup generated by **`ds389-backup-manager.sh`**:
    ```bash
    ls -ld /var/lib/dirsrv/backups/ds_backup_*
    ```
    *Example path: `/var/lib/dirsrv/backups/ds_backup_20260901_020000/slapd-app-user-store_db_bak`*

2.  **Execute the Restore Manager**:
    Run the restore script as `root`. The script automatically stops the systemd instance, restores the physical Berkeley DB database blocks, re-establishes proper system ownerships, and starts the directory engine:
    ```bash
    sudo /usr/local/sbin/ds389-restore-manager.sh \
      -i slapd-app-user-store \
      -p /var/lib/dirsrv/backups/ds_backup_20260901_020000/slapd-app-user-store_db_bak \
      -f
    ```
    *Note: The `-f` flag bypasses interactive prompts, allowing the restore to run unattended.*

3.  **Perform Post-Restore Connectivity Checks**:
    Verify that the local LDAP engine is actively running and responding to local queries:
    ```bash
    # Check running service status
    dsctl slapd-app-user-store status
    
    # Run an unauthenticated local test query against the root DSE
    ldapsearch -x -H ldap://localhost -b "" -s base "(objectclass=*)"
    ```

---

## 4. Phase 3: Rejoining the Multi-Supplier Replication Topology

Once the directory database has been restored on `host-b`, you must handle re-synchronization. The re-integration process depends on the **duration of the outage**.

### Scenario A: Outage Duration is Less Than the Changelog Purge Window
If `host-b` was offline for a short period (e.g., under 24 hours) and your other suppliers have not purged their database change history, **the replica catches up automatically**:
1.  When `host-b` starts, its local replication thread contacts its replication peers (such as `host-a`).
2.  `host-a` inspects `host-b`'s **Replication Update Vector (RUV)** timestamp.
3.  `host-a` transmits only the missing transaction modifications (deltas) stored in its local active changelog database.
4.  No manual database initialization is required.

### Scenario B: Outage Duration Exceeds the Changelog Purge Window
If `host-b` was offline for a prolonged period (exceeding the changelog retention interval or tombstone lifespan, typically 7 days), the replication peers will have already purged the historical updates required to bring `host-b` current. The replication agreement will fail with an **"OutOfSync"** error.

To recover from this, you must trigger an online **Suffix Re-initialization**:
1.  **Initiate Online Suffix Initialization**:
    From your healthy master supplier (`host-a`), execute the online init command. This completely overwrites `host-b`'s user database suffix with a clean snapshot from `host-a` over the network:
    ```bash
    dsconf -D "cn=Directory Manager" ldap://host-a.company.com repl-tasks init-agreement \
      --suffix="dc=app,dc=company,dc=com" \
      "agreement-to-host-b"
    ```
2.  **Monitor Suffix Sync Progress**:
    Query the status of the replication agreement initialization task from `host-a`:
    ```bash
    dsconf -D "cn=Directory Manager" ldap://host-a.company.com repl-tasks status-init \
      --suffix="dc=app,dc=company,dc=com" \
      "agreement-to-host-b"
    ```
    *Ensure the output returns: `Agreement successfully initialized` before proceeding.*

---

## 5. Phase 4: Validating Replication & Topology Health

To ensure your high-availability directory layer has fully recovered and is actively propagating writes across your network, perform these three audits:

### Audit 1: Replication Update Vector (RUV) Alignment
The Replica Update Vector (RUV) tracks the Change State Number (CSN) for every supplier in your topology. Ensure the sequence numbers are dynamically advancing across all nodes:
```bash
# Query the replication vectors from the local database
dsconf -D "cn=Directory Manager" ldap://localhost replication get-ruv --suffix="dc=app,dc=company,dc=com"
```
*Verify that the maximum CSN matches across your suppliers, indicating that no replication lag exists.*

### Audit 2: Split-Brain Collision Detection
In active/active topologies, network splits can lead to collision entries (where duplicate modifications are made on disconnected nodes). 389-ds stores conflicting entries with a hidden `nsds5ReplConflict` attribute. Query your database suffix to locate and audit conflicts:
```bash
ldapsearch -x -H ldap://localhost \
  -D "cn=Directory Manager" -y /root/.ldap_password.txt \
  -b "dc=app,dc=company,dc=com" \
  "(objectclass=nsds5ReplConflict)"
```
*An optimal, healthy system should return `numResponses: 0`. If conflicts are detected, manually reconcile the divergent attributes and remove the conflict records.*

### Audit 3: Centralized IdM Healthcheck Screening
On your core Red Hat IdM master infrastructure servers, execute the integrated `ipa-healthcheck` suite to scan replication links, certificate states, and SSSD modes:
```bash
# Run replication and topology health checks
ipa-healthcheck --source=ipahealthcheck.ds.replication --source=ipahealthcheck.ipa.topology
```
*Ensure the final output returns empty brackets `[]`, indicating that no replication conflicts, expired CA records, or disconnected topology segments were detected.*

---

## 🔗 Official Documentation References
*   [Red Hat Enterprise Linux 9: Performing disaster recovery with Identity Management](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html-single/performing_disaster_recovery_with_identity_management/index)
*   [Red Hat Directory Server 12: Configuring and managing replication](https://docs.redhat.com/en/documentation/red_hat_directory_server/12/html-single/configuring_and_managing_replication/index)
*   [389 Directory Server Project Site: Replication Architecture and Administration](https://www.port389.org/docs/389ds/FAQ/replication.html)
