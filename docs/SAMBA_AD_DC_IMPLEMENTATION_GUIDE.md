# Samba 4 Active Directory Domain Controller (Samba AD DC) Technical Implementation Guide

**Document Target**: Engineering, DevOps, and Security Architecture Teams  
**Scope**: Sandbox POC Validation, Greenfield Deployment & Active Directory Migration  
**Base OS**: Red Hat Enterprise Linux 9 / Rocky Linux 9 / UBI 9  

---

## Architectural Core: Decoupled Policy & Directory Architecture

Before executing deployment tracks, it is essential to understand the **Decoupled Policy Architecture** when Microsoft Active Directory is replaced by Samba 4 AD DC and Red Hat Identity Management (IdM).

```text
                      DECOUPLED POLICY ARCHITECTURE
                      
  [ Admin PAW ] --( GPMC / SMB3 )--> [ Samba-AD DC ]
                                     /var/lib/samba/sysvol/
                                              ||
  1. Trigger Event (Boot / Logon)             || 3. SMB3 File Download
  2. LDAP Policy Query                        ||    (Registry.pol, GPT.ini)
                                              vv
  [ Windows Workstation ] <====================+
           ||
           vv 4. Client-Side Parsing (CSEs)
  [ Local Windows Registry (HKLM / HKCU) ]
```

### How Windows GPOs Work on Samba AD DC
1. **Zero Translation on Server Side**: Samba AD DC acts purely as a standard LDAP directory and SMB3 file server. It does **not** convert, interpret, or translate Windows Group Policies.
2. **Server Storage (`SysVol`)**: When an administrator creates or edits a GPO using the standard Group Policy Management Console (GPMC) on a Tier-0 Privileged Access Workstation (PAW), GPMC writes LDAP metadata to Samba and uploads raw policy files (`Registry.pol`, `.admx` templates, scripts) directly to the `SysVol` SMB share (`/var/lib/samba/sysvol/`). Samba preserves Windows security descriptors using Linux **POSIX Extended Attributes (`security.NTACL`)**.
3. **Client-Side Execution Engine**: Windows workstations query LDAP over ports 389/636, discover linked GPOs, download policy hives over SMB3, and parse/apply settings locally into `HKLM`/`HKCU` using native Windows **Client-Side Extensions (CSEs)**.
4. **Linux Policy Separation**: Linux workstations and servers do **not** use Windows GPOs. Linux host configuration, security baselines (OpenSCAP CIS), and local limits are managed natively via **Ansible Playbooks** and **Red Hat IdM** (Host-Based Access Control / sudoers).

---

## Package Availability & Source Build Reference

This implementation guide assumes that pre-compiled, verified **Samba 4 AD DC RPM packages** (`samba-ad-dc-4.24.7-1.el9.x86_64.rpm`) are hosted in your enterprise YUM/DNF repository or Red Hat Satellite instance.

> **Custom RHEL 9 Compilation Reference**:  
> Red Hat Enterprise Linux 9 omits native `samba-dc` packages from standard AppStream repositories. If your organization needs to compile custom Samba 4 binaries against RHEL 9's system MIT Kerberos headers (`--with-system-mitkrb5 --with-experimental-mit-ad-dc`) and package them into custom RPMs using UBI 9 container test harnesses, refer to the standalone guide:  
> **[Samba 4 AD DC RPM Build & Container Verification Guide (`SAMBA_RPM_BUILD_GUIDE.md`)](SAMBA_RPM_BUILD_GUIDE.md)**.

---

## Phase 0: The Isolated POC & Complex GPO Validation Gate (Mandatory Go/No-Go)

The non-negotiable **Phase 0 Gate** requires standing up an isolated sandbox environment to prove that Samba 4 AD DC ingests, serves, and enforces our enterprise's most complex existing Windows GPOs—especially those required for Windows internals/kernel developers—without error.

```text
                      PHASE 0 POC SANDBOX ARCHITECTURE
                      
  +-------------------------------------------------------------------+
  | ISOLATED SANDBOX VLAN (No Route to Production AD)                 |
  |                                                                   |
  |  [ Prod AD GPO Backup ] ===( Import )===> [ Test Samba-AD DC ]   |
  |                                                (SysVol / BIND9)   |
  |                                                       ||          |
  |                                                (SMB3 / LDAP)      |
  |                                                       vv          |
  |                                            [ Test Windows Dev WS ] |
  |                                            (Evaluates GPOs 100%)  |
  +-------------------------------------------------------------------+
```

### Step 1: Exporting Complex GPOs from Production Active Directory
On a production Windows Domain Controller, export active Group Policy Objects using PowerShell:

```powershell
# Create backup directory
New-Item -ItemType Directory -Path "C:\GPO_Backups"

# Backup all GPOs including security descriptors and WMI filters
Backup-Gpo -All -Path "C:\GPO_Backups"

# Export GPO report in HTML for baseline verification
Get-GPOReport -All -ReportType HTML -Path "C:\GPO_Backups\Production_GPO_Report.html"
```

> **Lab-tested status (2026-10-13)**: Step 2 and the DC-side commands of Step 3 (item 6) were executed against `samba-ad-dc-4.24.7` in a UBI 9.7 container. Step 1, the Windows-side import (Step 3, items 1–5) and Step 4 need Windows hosts and have not yet been run. Earlier revisions of this section used `samba-tool gpo aclreset` (does not exist) and copied `Backup-GPO` folders straight into SysVol (Samba never registers them as GPOs).

#### Choose the import path first

| Path | When | Fidelity |
| :--- | :--- | :--- |
| **A. Clone** | Security allows restoring one production DC into the sealed sandbox VLAN | Highest: real GUIDs, SIDs, links, WMI filters. Also rehearses Track B |
| **B. Fresh domain + `Import-GPO`** | No production data may leave production | Good for settings; group SIDs must be mapped with a migration table |

Path A: restore a production DC from system-state backup into the sandbox, record `Get-ADForest`/`Get-ADDomain` functional levels, then `samba-tool domain join` it (Track B Step 2), copy SYSVOL, run `samba-tool ntacl sysvolreset`, transfer FSMO roles and shut the Windows DC down. Continue at Step 4.

Path B follows below.

### Step 2: Standing Up the Sandbox Samba-AD DC
On an isolated RHEL 9 / Rocky Linux 9 VM (`192.168.100.10`):

```bash
# 1. Host identity: FQDN, hosts entry, time
hostnamectl set-hostname dc1.sandbox.lab
echo "192.168.100.10 dc1.sandbox.lab dc1" >> /etc/hosts
dnf install -y chrony && systemctl enable --now chronyd

# 2. Firewall (incl. dynamic RPC range used by GPMC and replication)
firewall-cmd --permanent --add-service={dns,kerberos,kpasswd,ldap,ldaps,samba}
firewall-cmd --permanent --add-port={135/tcp,3268/tcp,3269/tcp,49152-65535/tcp}
firewall-cmd --reload

# 3. Packages (samba-ad-dc RPM from samba-rpm-build-rhel9, or a maintained el9 Samba DC repo)
dnf install -y ./samba-ad-dc-4.24.7-*.el9.x86_64.rpm krb5-workstation bind-utils

# 4. Provision. Use a sandbox realm, never the production name, unless this is a sealed clone.
rm -f /etc/samba/smb.conf
samba-tool domain provision \
    --server-role=dc --use-rfc2307 \
    --dns-backend=SAMBA_INTERNAL \
    --realm=SANDBOX.LAB --domain=SANDBOX \
    --host-ip=192.168.100.10 \
    --option="dns forwarder = 192.168.100.1" \
    --adminpass='<sandbox-admin-password>'

# 5. Kerberos and resolver point at the DC
cp /var/lib/samba/private/krb5.conf /etc/krb5.conf
nmcli con mod "$(nmcli -g NAME con show --active | head -1)" ipv4.dns 192.168.100.10 ipv4.ignore-auto-dns yes
nmcli con up "$(nmcli -g NAME con show --active | head -1)"

# 6. Start (requires samba.service in the RPM; older builds: run `samba -D`)
systemctl enable --now samba
```

Health gate (all must pass before Step 3):
```bash
host -t SRV _ldap._tcp.dc._msdcs.sandbox.lab
echo '<sandbox-admin-password>' | kinit administrator@SANDBOX.LAB && klist
smbclient -L dc1.sandbox.lab --use-kerberos=required      # lists sysvol, netlogon
samba-tool dbcheck --cross-ncs                             # 0 errors
```
`SAMBA_INTERNAL` DNS is deliberate: Phase 0 tests Group Policy, not the DNS backend. Switch to BIND9 DLZ later with `samba_upgradedns --dns-backend=BIND9_DLZ` (Track A, section B).

### Step 3: Importing Production GPOs into the Sandbox
A GPO is two things that must match: a `groupPolicyContainer` object in LDAP and a SysVol folder named after its GUID. Copying `Backup-GPO` output into `Policies/` creates neither, and `samba-tool gpo restore` only reads backups written by `samba-tool gpo backup`. Import with the Windows tooling instead, from a sandbox-joined admin VM with RSAT Group Policy Management:

1. **Central Store**: copy the production `PolicyDefinitions` folder (`\\<prod-dc>\SYSVOL\<prod-domain>\Policies\PolicyDefinitions`) to `\\dc1.sandbox.lab\SYSVOL\sandbox.lab\Policies\PolicyDefinitions`. Do **not** run `samba-tool gpo admxload` here: it installs Samba's Linux templates and GPMC then stops showing the Windows ones.
2. **Principals**: create the sandbox groups and accounts that the GPOs reference (security filtering, User Rights, Restricted Groups, GPP).
3. **Migration table**: in GPMC, *Open Migration Table Editor*, populate from the backups, map each production principal and UNC path to its sandbox equivalent, save as `C:\GPO_Backups\poc.migtable`.
4. **Import and link** each GPO (PowerShell as sandbox Domain Admin):
   ```powershell
   $map = 'C:\GPO_Backups\poc.migtable'
   Get-ChildItem C:\GPO_Backups -Directory | ForEach-Object {
       $name = ([xml](Get-Content "$($_.FullName)\bkupInfo.xml")).BackupInst.GPODisplayName.'#cdata-section'
       Import-GPO -BackupId $_.Name.Trim('{}') -Path C:\GPO_Backups -TargetName $name `
                  -MigrationTable $map -CreateIfNeeded
   }
   New-GPLink -Name "<GPO name>" -Target "OU=Dev Workstations,DC=sandbox,DC=lab"
   ```
5. **WMI filters** are not part of `Backup-GPO`: export them from production (`Get-ADObject -Filter 'objectClass -eq "msWMI-Som"'`) and recreate them.
6. **ACL check on the DC**:
   ```bash
   samba-tool gpo listall | grep -c '^GPO'     # one per imported GPO + 2 defaults
   samba-tool ntacl sysvolcheck || samba-tool ntacl sysvolreset
   ```

### Step 4: Verification & Audit Protocol on Test Windows Developer Workstation
Join a test Windows developer workstation to the sandbox domain, move it into the linked OU, then:

1. Write the list of GPOs under test, with an owner per GPO, **before** testing.
2. `gpupdate /force`, then `gpresult /h C:\GPO_POC_Report.html /f`.
3. Compare each GPO's applied settings in the report against its section of `Production_GPO_Report.html`.
4. Event Viewer: no Error or Warning events in `Applications and Services Logs -> Microsoft -> Windows -> GroupPolicy -> Operational`; in the **System** log, event 1502 (computer policy) and 1503 (user policy) report success.
5. **Go** = every listed GPO applied with matching settings. Anything else is recorded as a named gap with an owner, not a pass.

---

## 2. Track A: Greenfield "Plan B" Implementation

Follow this track when deploying a brand-new Linux-native IAM infrastructure for Windows and Linux hosts from scratch.

### A. Network & Host Prerequisites
* **Hostname**: `dc-01.ad.company.com`
* **Static IP**: `192.168.1.10/24`
* **Realm**: `AD.COMPANY.COM` (Uppercase)
* **Domain NetBIOS**: `AD`

Open mandatory firewall ports:
```bash
firewall-cmd --permanent --add-port={53/tcp,53/udp,88/tcp,88/udp,135/tcp,389/tcp,389/udp,445/tcp,464/tcp,464/udp,636/tcp,3268/tcp,3269/tcp}
firewall-cmd --reload
```

### B. BIND9 DLZ Dynamic DNS Configuration
RHEL 9 ships BIND 9.16, so Samba's `dlz_bind9_16.so` module is required. Provisioning writes `/var/lib/samba/bind-dns/named.conf`; uncomment the 9.16 line in it and include that file from `/etc/named.conf` (tested with BIND 9.16.23 on UBI 9.7: `named-checkconf` passes and BIND serves the AD SRV records). BIND's `plugin { }` statement is for query plugins and is a syntax error here.

```bash
# After provisioning with --dns-backend=BIND9_DLZ (section C):
sed -i 's|^\(\s*\)# \(database "dlopen .*dlz_bind9_16.so";\)|\1\2|' /var/lib/samba/bind-dns/named.conf
chgrp -R named /var/lib/samba/bind-dns && chmod -R g+rX /var/lib/samba/bind-dns
```

`/etc/named.conf`:
```bind
options {
    directory "/var/named";
    listen-on port 53 { 192.168.1.10; 127.0.0.1; };
    allow-query { any; };
    forwarders { 192.168.1.1; };
    tkey-gssapi-keytab "/var/lib/samba/bind-dns/dns.keytab";
    minimal-responses yes;
};
include "/var/lib/samba/bind-dns/named.conf";
```
Module path: `/usr/lib/samba/bind9/` for the current `samba-ad-dc` 4.24.7-1 RPM, `/usr/lib64/samba/bind9/` for builds from the corrected spec (Release 2+). The generated file always holds the right path.

### C. Provisioning the Domain
```bash
rm -f /etc/samba/smb.conf /etc/krb5.conf
samba-tool domain provision \
    --server-role=dc \
    --use-rfc2307 \
    --dns-backend=BIND9_DLZ \
    --realm=AD.COMPANY.COM \
    --domain=AD \
    --adminpass='SecureP@ssw0rd2026!'

cp /var/lib/samba/private/krb5.conf /etc/krb5.conf
# apply section B to named.conf, then:
named-checkconf && systemctl enable --now named samba
```

---

## 3. Track B: Phase 2 Active Directory Migration Runbook

Follow this track when migrating an existing Active Directory domain from Microsoft Windows Server Domain Controllers to Samba 4 AD DCs after Phase 0 POC approval.

```text
                    IN-PLACE REPLICA MIGRATION FLOW
                    
  [ Windows DC-01 ] --( DRS Replica Join )--> [ Samba DC-01 ]
  (FSMO Master)                                (Synced Database)
        |                                            |
        +========( Promote FSMO Roles )==============+
        |
  [ Windows DC-01 ] (Demoted / Decommissioned)
```

### Step 1: Pre-Migration Discovery & Health Audits
```powershell
# Run from Windows PowerShell as Domain Admin
Get-ADDomainController -Filter * | Select-Object Name, IPv4Address, OperatingSystem
netdom query fsmo
dcdiag /test:DNS /v
```

### Step 2: Executing the In-Place Replica Join
Joining Samba directly to the existing Active Directory domain replicates the directory database, SID history, user credentials, and machine accounts. **Because the Domain SID is unchanged, local user desktop profiles on Windows clients are preserved without requiring domain re-joins.**

```bash
samba-tool domain join ad.company.com DC \
    -U "AD\Administrator" \
    --password='WindowsAdminPassword!' \
    --dns-backend=BIND9_DLZ
```

Verify replication status across all directory partitions:
```bash
samba-tool drs showrepl
```

### Step 3: FSMO Role Transfer
Transfer all five FSMO roles to the new Samba AD DC:
```bash
samba-tool fsmo transfer --role=all -U "AD\Administrator"
samba-tool fsmo show
```

### Step 4: Stateful SysVol Replication (Rsync over SSH)
Deploy a systemd-timer-driven **rsync over SSH** process between primary (`dc-01`) and secondary (`dc-02`) Samba DCs.

Create `/usr/local/bin/sysvol-sync.sh`:
```bash
#!/bin/bash
set -euo pipefail

# Mandatory -X (xattrs/NTACLs) and -A (ACLs) flags to protect Windows security SIDs
rsync -XAavz --delete \
    --exclude='*~' \
    /var/lib/samba/sysvol/ \
    root@dc-02.ad.company.com:/var/lib/samba/sysvol/
```

Configure systemd timer on `dc-01` (`/etc/systemd/system/sysvol-sync.timer`):
```ini
[Unit]
Description=Synchronize SysVol to Secondary Samba DC every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Unit=sysvol-sync.service

[Install]
WantedBy=timers.target
```

### Step 5: Red Hat IdM Trust Re-Pointing
Update the DNS forwarders on your Red Hat IdM master nodes to target the new Samba AD DCs:
```bash
ipa dnsforwardzone-mod ad.company.com --forwarder=192.168.1.10 --forwarder=192.168.1.11
ipa trust-show ad.company.com
```

### Step 6: Windows Server Decommissioning
Gracefully demote and power down the legacy Microsoft Windows Domain Controllers:
1. Run `Uninstall-ADDSDomainController` on the Windows Server nodes.
2. Confirm FSMO role integrity on Samba: `samba-tool fsmo show`.
3. Power down the Windows Server VMs.

---

## 4. Post-Deployment Security & Operations

### A. Windows Certificate Auto-Enrollment (IdM + ACME / `cepces`)
Replace Active Directory Certificate Services (AD CS) by leveraging Red Hat IdM's integrated **Dogtag CA** and Tomcat ACME responder:
```bash
ipa-acme-manage enable
```
On Windows clients, deploy an automated background scheduled task running *win-acme* pointing to `https://idm-master-01.linux.company.com/acme/directory`.

### B. Directory Server High Availability & Replication Reference
For high availability and multi-supplier replication across Red Hat Directory Server (RHDS 12 / 389ds) application stores, conflict resolution mechanics (CSN timestamp evaluation hierarchy, glue entries), and `dsctl` vs `systemctl` operational controls, refer to:  
**[Red Hat Directory Server Advanced Replication & Conflict Operations Guide (`RHDS_ADVANCED_REPLICATION_GUIDE.md`)](RHDS_ADVANCED_REPLICATION_GUIDE.md)**.

### C. Zero-Trust Administrative Governance (GPMC on Tier-0 PAWs)
* **Never** install the Group Policy Management Console (GPMC) on standard employee laptops.
* Deploy GPMC on an isolated **Tier-0 Privileged Access Workstation (PAW)** virtual machine.
* Require administrators to authenticate via **Keycloak (RHBK) Multi-Factor Authentication (OTP)** to access an ephemeral HTML5 jump session (e.g., Apache Guacamole) to run GPMC.

---

## 5. Verification & Audit Playbook

Execute these validation commands to confirm cluster health:

```bash
# 1. Verify DNS SRV Record Resolution
dig _kerberos._tcp.ad.company.com SRV
dig _ldap._tcp.dc._msdcs.ad.company.com SRV

# 2. Test Kerberos Ticket Granting Ticket (TGT) Issuance
kinit Administrator@AD.COMPANY.COM
klist

# 3. Test Samba LDAP Query
ldapsearch -H ldap://dc-01.ad.company.com -Y GSSAPI -b "dc=ad,dc=company,dc=com" "(objectClass=user)" sAMAccountName

# 4. Audit Cross-Forest Trust from RHEL IdM
ipa user-show user123@ad.company.com
```

---

## 6. Document Map & Related Guides

| Document | Description |
| :--- | :--- |
| **`SAMBA_AD_DC_IMPLEMENTATION_GUIDE.md`** | Main active directory migration, Phase 0 GPO gate, and deployment runbook. |
| **`SAMBA_RPM_BUILD_GUIDE.md`** | Custom Samba 4 RPM compilation for RHEL 9 against system MIT Kerberos and Podman UBI-9 test harness. |
| **`RHDS_ADVANCED_REPLICATION_GUIDE.md`** | 389 Directory Server multi-supplier replication setup, CSN 4-part conflict resolution mechanics, and audit tooling. |
