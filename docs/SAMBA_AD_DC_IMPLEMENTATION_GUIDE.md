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

Phase 0 proves, before any migration, that a Samba AD domain controller serves our most complex Windows GPOs (above all those for Windows internals / kernel developers) and that a real Windows workstation applies them without error.

It does this in the dev environment with a **second domain**: a RHEL 9 VM becomes the domain controller of a new domain (`mydomain2.com` in the examples); the GPOs under test are exported from the existing domain (`mydomain.com`) and imported into it; one existing workstation moves from `mydomain.com` to `mydomain2.com` and is measured.

```text
   mydomain.com (existing AD, read only)             mydomain2.com (new, Samba)
  +------------------------------------+          +------------------------------------+
  |  Windows DC                        |  Backup  |  RHEL 9 VM = Samba AD DC           |
  |  GPOs under test --(Export, Step 1)|--------->|  (Steps 2-3: provision, import,    |
  |                                    |   scp    |   map principals)                  |
  |  Workstation (member) -------------|--------->|  Workstation (member, Step 4)      |
  |                     leaves (pass 1)|  moves   |  joins (pass 2), Go/No-Go check    |
  +------------------------------------+          +------------------------------------+
```

The RHEL 9 VM becomes a **domain controller**, not a member server: a member server joins someone else's domain, while a domain controller hosts its own domain, its directory, Kerberos, DNS and the SysVol share that serves GPOs. `mydomain.com` is not changed, apart from the moved workstation's computer account being disabled.

### What you need

| Machine | State | Role in Phase 0 |
| :--- | :--- | :--- |
| `mydomain.com` domain controller | running | Source of the GPOs under test. Only read. |
| Admin PC with RSAT Group Policy Management | running, member of `mydomain.com` | Runs the export (Step 1) |
| **Samba VM**: RHEL 9, subscribed, static IPv4, ≥ 2 GB RAM | running, **not configured** | Becomes the `mydomain2.com` domain controller (Steps 2–3) |
| **Workstation**: Windows 10/11 Pro or Enterprise | running, member of `mydomain.com` | Moves to `mydomain2.com` and is measured (Step 4). Snapshot or back it up first. |
| `samba-ad-dc` RPM | built with [samba-rpm-build-rhel9](https://github.com/gennady73/samba-rpm-build-rhel9) | Copied to the Samba VM |

Naming rules for the new domain: a DNS name you control (not a public name owned by someone else), **not** a subdomain of `mydomain.com`, NetBIOS name (`MYDOMAIN2`) different from the source domain's and at most 15 characters.

All scripts are in [`scripts/phase0/`](../scripts/phase0/). Every step ends with checks that print `[PASS]`/`[FAIL]` and exit non-zero on failure: do not continue past a failed step.

> **Verification status (2026-10-14).** Steps 2 and 3 (`01`–`06` scripts) were run end-to-end against `samba-ad-dc-4.24.7-2.el9` with RHEL 9 runtime libraries for realm `MYDOMAIN2.COM`, using sample `Backup-GPO` folders: all checks passed, imported files were byte-identical in SysVol, source SIDs were rewritten, and an ordinary domain user could read the GPO files over SMB. Not yet run on a real RHEL 9 VM: the `dnf`, `firewalld`, `chronyd`, SELinux and NetworkManager parts of `01-prepare-host.sh`. The Windows scripts were parse-checked and their logic unit-tested in PowerShell 7, but have not yet run on Windows.

### Step 1: Export the GPOs under test (admin PC, `mydomain.com`)

Choose the GPOs that must work and write their names down: this list is what Step 4 judges.

```powershell
# Copy scripts\phase0\windows\ to the admin PC, then in PowerShell:
.\Export-Phase0Gpos.ps1 -Name 'Dev Workstation Baseline','Kernel Debug Policy' -Path C:\GPO_Backups
scp -r C:\GPO_Backups root@<samba-vm>:/root/
```

**Check:** `C:\GPO_Backups\manifest.csv` lists every GPO with its links and WMI filter; `reports\` holds one HTML/XML report per GPO (the baseline for Step 4).

Also note the SIDs of the `mydomain.com` groups the GPOs name (User Rights, Restricted Groups, preference targeting), for Step 3b: `(Get-ADGroup 'Kernel Developers').SID.Value`.

### Step 2: Make the Samba VM the `mydomain2.com` domain controller

Copy `scripts/phase0/` and the RPM to the VM (for example to `/root/phase0/`), then as root:

```bash
cd /root/phase0
cp phase0.env.example phase0.env && chmod 600 phase0.env
vi phase0.env               # REALM=MYDOMAIN2.COM, DOMAIN=MYDOMAIN2, DC_HOSTNAME, DC_IP,
                            # DNS_FORWARDER (a mydomain.com DNS server), SAMBA_RPM, TARGET_OU

./01-prepare-host.sh        # host name, /etc/hosts, chrony, firewall, SELinux, installs the RPM
./02-provision-dc.sh        # asks for the new Administrator password, creates the domain,
                            # starts samba, points the VM's DNS at itself, runs 03-check-dc.sh
```

If `01-prepare-host.sh` stops on package conflicts (`samba-client-libs`, `sssd-ad`, …), the VM has RHEL's own Samba client packages. A DC must not run SSSD: re-run with `./01-prepare-host.sh --allow-erase`.

**`smb.conf` is generated, not written by hand.** `samba-tool domain provision` (run by `02-provision-dc.sh`) writes `/etc/samba/smb.conf` from `phase0.env`; the script prints it and keeps a copy as `smb.conf.provisioned`. For the example values it is:

```ini
[global]
	bind interfaces only = Yes
	dns forwarder = 192.168.100.1
	interfaces = 192.168.100.10 lo
	netbios name = DC1
	realm = MYDOMAIN2.COM
	server role = active directory domain controller
	workgroup = MYDOMAIN2
	idmap_ldb:use rfc2307 = yes

[sysvol]
	path = /var/lib/samba/sysvol
	read only = No

[netlogon]
	path = /var/lib/samba/sysvol/mydomain2.com/scripts
	read only = No
```

`server role = active directory domain controller` is what makes this a DC. The DC's IP must be the first entry of `interfaces`: with the MIT Kerberos KDC, the password-change service (port 464) listens only on the first interface. Do not add member-server settings (`security =`, `idmap config …`, `passdb backend`, `winbind …`) found in many guides: they break a DC, and `03-check-dc.sh` fails if it finds them.

**Check:** `02-provision-dc.sh` ends with `RESULT: all checks passed` from `03-check-dc.sh`: `smb.conf` loads, has the DC role, the right realm and no member-server settings; samba and the MIT KDC run; ports 53, 88, 135, 389, 445, 464, 636 and 3268 answer on `DC_IP`; the DC's DNS serves its SRV records; Kerberos, LDAP and SMB (`sysvol`, `netlogon`) work; `dbcheck` and `sysvolcheck` are clean. Re-run `./03-check-dc.sh` at any time.

### Step 3: Import the GPOs (Samba VM)

**3a. Import**

```bash
./04-import-gpos.sh /root/GPO_Backups
```

Creates each GPO under its original name, uploads its `DomainSysvol\GPO` content (Administrative Templates, security settings, scripts, preferences) byte-for-byte, sets the client-side extension list, raises the version so clients apply it, links it to `TARGET_OU` and resets SysVol ACLs. Safe to re-run: existing GPOs are skipped. It prints `REVIEW:` lines for content tied to `mydomain.com`.

**3b. Users, groups and SID mapping**

```bash
cp principals.csv.example principals.csv && vi principals.csv
./06-map-principals.sh
```

Each row creates a `mydomain2.com` user or group. A row with `source_sid` (a `mydomain.com` SID from a `REVIEW:` line) also rewrites that SID, wherever it appears in the imported GPO files, to the new group's SID, and raises those GPOs' versions: the job a GPMC migration table does. The step fails while any `mydomain.com` SID is left (`UNMAPPED:` lines): add a row for it, or remove that setting in GPMC.

The other `REVIEW:` lines:

| `REVIEW:` line | What to do |
| :--- | :--- |
| `UNC path \\server\share` | The path must resolve and be reachable from the workstation once it is in `mydomain2.com` (with `DNS_FORWARDER` pointing at `mydomain.com` DNS, `mydomain.com` names resolve; access rights on the share are still `mydomain.com`'s). |
| `WMI filter in source GPO` | WMI filters are not in `Backup-GPO` output. Re-create the filter in GPMC against `mydomain2.com` and attach it. |

Security filtering (who a GPO applies to) is not imported: each imported GPO applies to Authenticated Users in the OU.

**3c. Check**

```bash
./05-check-gpos.sh
```

**Check:** every GPO has matching LDAP and `GPT.INI` versions, content implies registered extensions, the GPOs are linked to `TARGET_OU`, `sysvolcheck` is clean.

Do not run `samba-tool gpo admxload` for Phase 0: it puts Samba's Linux templates into the Central Store and GPMC then hides the Windows templates.

### Step 4: Move the workstation and decide Go / No-Go

**Before:** snapshot or back up the workstation; make sure a local administrator account is enabled and its password is known (with LAPS, read it from `mydomain.com` first). After the workstation leaves `mydomain.com`, that account is the only way to log on.

**What changes for users:** `mydomain.com` accounts can no longer log on to this workstation. A `mydomain2.com` user gets a **new** Windows profile; the old profile stays on disk unused. Machine certificates, BitLocker key escrow in `mydomain.com` and management agents (SCCM/Intune) stay tied to the old domain.

Copy `scripts\phase0\windows\` and `C:\GPO_Backups` to the workstation, then elevated, twice (the same command for both passes):

```powershell
.\Move-WorkstationToSamba.ps1 -DomainName mydomain2.com -DcIp 192.168.100.10 `
    -OUPath 'OU=Dev Workstations,DC=mydomain2,DC=com' -LocalAdmin Administrator `
    -SourceCredential (Get-Credential MYDOMAIN\admin)
```

| Pass | Computer state | What happens |
| :--- | :--- | :--- |
| 1 | member of `mydomain.com` | Checks the local admin account; saves rollback data (old domain, DNS servers, BitLocker recovery keys) to `C:\Phase0_Rollback` — copy it off the machine; leaves `mydomain.com` (its computer account is disabled); restarts. |
| 2 | workgroup; log on as `.\Administrator` | Points DNS at the Samba DC; checks SRV records, ports 88/135/389/445/464 and clock; joins `mydomain2.com` into `OU=Dev Workstations`; restarts. |

Then log on to the workstation as a `mydomain2.com` test user (e.g. `MYDOMAIN2\devuser` from `principals.csv`) once and keep the session open. From an elevated PowerShell running as `MYDOMAIN2\Administrator`:

```powershell
.\Test-Phase0Workstation.ps1 -BackupPath C:\GPO_Backups -TestUser 'MYDOMAIN2\devuser'
```

It refreshes computer policy and collects RSoP, then checks:
1. Each GPO under test is applied for computer and/or user: not filtered, not denied.
2. Every Administrative Templates value in each GPO's `Registry.pol` is present in `HKLM` or the test user's hive, with the same data.
3. Every client-side extension finished with error 0.
4. The GroupPolicy Operational log holds no errors or warnings since the refresh, and System event 1502 is present.

**Go** = `GO: all Phase 0 checks passed` for the GPO list from Step 1. Anything else is **No-Go**: `C:\Phase0_Results\results.csv` names each failing GPO and value, and `rsop.html` is the full RSoP report. For settings that are not registry values (security settings, preferences), compare `rsop.html` with the Step 1 baseline `reports\<name>.html`.

**Rollback:** `.\Restore-WorkstationDomain.ps1`, run twice the same way: pass 1 leaves `mydomain2.com`, pass 2 restores the saved DNS servers and rejoins `mydomain.com`. Users get their original profiles back.

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
