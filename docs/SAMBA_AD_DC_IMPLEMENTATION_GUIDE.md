# Samba 4 Active Directory Domain Controller (Samba AD DC) Technical Implementation Guide

**Document Target**: Engineering, DevOps, and Security Architecture Teams  
**Scope**: Sandbox POC Validation, Greenfield "Plan B" Deployment & Phase 2 Active Directory Migration  
**Base OS**: Rocky Linux 9 (RHEL 9 Binary Compatible)  
**Status**: Production-Ready Technical Runbook & Validation Framework  

---

## Architectural Core: Decoupled Policy & Directory Architecture

Before executing deployment tracks, it is essential to understand the **Decoupled Policy Architecture** when Microsoft Active Directory is replaced by Samba 4 AD DC and Red Hat Identity Management (IdM).

```
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
3. **Client-Side Execution Engine**: Windows workstations query LDAP over ports 389/636, discover linked GPOs, download policy hives over SMB3, and parse/apply the settings locally into `HKLM`/`HKCU` using native Windows **Client-Side Extensions (CSEs)**.
4. **Linux Policy Separation**: Linux workstations and servers do **not** use Windows GPOs. Linux host configuration, security baselines (OpenSCAP CIS), and local limits are managed natively via **Ansible Playbooks** and **Red Hat IdM** (Host-Based Access Control / sudoers).

---

## Phase 0: The Isolated POC & Complex GPO Validation Gate (Mandatory Go/No-Go)

The non-negotiable **Phase 0 Gate** requires standing up an isolated sandbox environment to prove that Samba 4 AD DC ingests, serves, and enforces our enterprise's most complex existing Windows GPOs—especially those required for Windows internals/kernel developers—without error.

```
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

### Step 2: Standing Up the Sandbox Samba-AD DC
On an isolated Rocky Linux 9 VM (`192.168.100.10`), provision a sandbox domain matching your domain structure:

```bash
# Clean existing configs
rm -f /etc/samba/smb.conf /etc/krb5.conf

# Provision sandbox domain
samba-tool domain provision     --server-role=dc     --use-rfc2307     --dns-backend=BIND9_DLZ     --realm=AD.COMPANY.COM     --domain=AD     --adminpass='PocP@ssw0rd2026!'

# Start services
cp /var/lib/samba/private/krb5.conf /etc/krb5.conf
systemctl enable --now named samba
```

### Step 3: Ingesting Production GPOs into Sandbox SysVol
Copy the exported GPO folders (`{GUID}`) from `C:\GPO_Backups\` directly into the sandbox Samba `SysVol` path (`/var/lib/samba/sysvol/ad.company.com/Policies/`):

```bash
# Restore file ownership and apply NTACLs
samba-tool gpo aclreset

# Reload ADMX templates into SysVol
samba-tool gpo admxload -U Administrator
```

### Step 4: Verification & Audit Protocol on Test Windows Developer Workstation
Join a test Windows developer workstation to the sandbox Samba AD DC and execute the verification sequence:

1. **Force Policy Refresh**:
   ```cmd
   gpupdate /force
   ```
2. **Generate Resultant Set of Policy (RSOP) Report**:
   ```cmd
   gpresult /h C:\GPO_POC_Report.html /f
   ```
3. **Audit Windows Event Logs**:
   Open Windows Event Viewer and inspect `Applications and Services Logs -> Microsoft -> Windows -> GroupPolicy -> Operational`:
   * **Event ID 1500**: Group Policy preprocessing started successfully.
   * **Event ID 1501**: Group Policy processing completed successfully with zero errors.
   * **Event ID 7016/7017**: Confirm all Client-Side Extensions (Registry, Security, Administrative Templates) completed in under 1000ms.

**Phase 0 Gate Approval**: If `gpresult` shows 100% policy application matching `Production_GPO_Report.html` and Event ID 1501 reports zero errors, the POC is officially approved to proceed to deployment.

---

## 1. Containerized RPM Compilation Pipeline (Podman)

Red Hat Enterprise Linux and Rocky Linux 9 disable AD DC capabilities in default OS Samba packages due to Heimdal vs. MIT Kerberos dependencies. To maintain host security without installing compilers or IDEs on production Domain Controllers, compile custom Samba RPMs against MIT Kerberos inside an isolated Podman container.

### A. Build Container Specification (`Dockerfile.samba-build`)
```dockerfile
FROM rockylinux:9

RUN dnf install -y \
    gcc make python3-devel flex bison \
    krb5-devel libacl-devel libattr-devel \
    openldap-devel pam-devel gnutls-devel \
    libxml2-devel libxslt-devel bind-devel \
    rpm-build rsync git && \
    dnf clean all

WORKDIR /build
```

### B. Build Execution & Packaging
```bash
# Spin up the build container and compile Samba AD DC RPMs against MIT Kerberos
$ podman build -t samba-ad-builder -f Dockerfile.samba-build .
$ podman run --rm -v $(pwd)/output:/build/output samba-ad-builder bash -c "
    git clone --depth 1 https://git.samba.org/samba.git && \
    cd samba && \
    ./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var \
                --with-system-mitkrb5 --enable-fhs && \
    make -j\$(nproc) && \
    make rpm && \
    cp *.rpm /build/output/
"
```

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
# firewall-cmd --permanent --add-port={53/tcp,53/udp,88/tcp,88/udp,135/tcp,389/tcp,389/udp,445/tcp,464/tcp,464/udp,636/tcp,3268/tcp,3269/tcp}
# firewall-cmd --reload
```

### B. BIND9 DLZ Dynamic DNS Configuration
Configure BIND9 (`named`) to use Samba's Dynamic Loadable Zones (DLZ) module (`/etc/named.conf`):
```bind
options {
    directory "/var/named";
    dump-file "/var/named/data/cache_dump.db";
    tkey-gssapi-keytab "/var/lib/samba/bind-dns/dns.keytab";
    minimal-responses yes;
};

plugin {
    file "/usr/lib64/samba/bind9/dlz_bind9_12.so";
};
```

### C. Provisioning the Domain
```bash
# rm -f /etc/samba/smb.conf /etc/krb5.conf
# samba-tool domain provision \
    --server-role=dc \
    --use-rfc2307 \
    --dns-backend=BIND9_DLZ \
    --realm=AD.COMPANY.COM \
    --domain=AD \
    --adminpass='SecureP@ssw0rd2026!'

# cp /var/lib/samba/private/krb5.conf /etc/krb5.conf
# systemctl enable --now named samba
```

---

## 3. Track B: Phase 2 Active Directory Migration Runbook

Follow this track when migrating an existing Active Directory domain from Microsoft Windows Server Domain Controllers to Samba 4 AD DCs after Phase 0 POC approval.

```
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
Get-ADDomainController -Filter * | Select-Name, IPv4Address, OperatingSystem
netdom query fsmo
dcdiag /test:DNS /v
```

### Step 2: Executing the In-Place Replica Join
Joining Samba directly to the existing Active Directory domain replicates the directory database, SID history, user credentials, and machine accounts. **Because the Domain SID is unchanged, local user desktop profiles on Windows clients are preserved without requiring domain re-joins.**

```bash
# samba-tool domain join ad.company.com DC \
    -U "AD\Administrator" \
    --password='WindowsAdminPassword!' \
    --dns-backend=BIND9_DLZ
```

Verify replication status across all directory partitions:
```bash
# samba-tool drs showrepl
```

### Step 3: FSMO Role Transfer
Transfer all five FSMO roles to the new Samba AD DC:
```bash
# samba-tool fsmo transfer --role=all -U "AD\Administrator"
# samba-tool fsmo show
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
# ipa dnsforwardzone-mod ad.company.com --forwarder=192.168.1.10 --forwarder=192.168.1.11
# ipa trust-show ad.company.com
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
# ipa-acme-manage enable
```
On Windows clients, deploy an automated background scheduled task running *win-acme* pointing to `https://idm-master-01.linux.company.com/acme/directory`.

### B. Zero-Trust Administrative Governance (GPMC on Tier-0 PAWs)
* **Never** install the Group Policy Management Console (GPMC) on standard employee laptops.
* Deploy GPMC on an isolated **Tier-0 Privileged Access Workstation (PAW)** virtual machine.
* Require administrators to authenticate via **Keycloak (RHBK) Multi-Factor Authentication (OTP)** to access an ephemeral HTML5 jump session (e.g., Apache Guacamole) to run GPMC.

---

## 5. Verification & Audit Playbook

Execute these validation commands to confirm cluster health:

```bash
# 1. Verify DNS SRV Record Resolution
$ dig _kerberos._tcp.ad.company.com SRV
$ dig _ldap._tcp.dc._msdcs.ad.company.com SRV

# 2. Test Kerberos Ticket Granting Ticket (TGT) Issuance
$ kinit Administrator@AD.COMPANY.COM
$ klist

# 3. Test Samba LDAP Query
$ ldapsearch -H ldap://dc-01.ad.company.com -Y GSSAPI -b "dc=ad,dc=company,dc=com" "(objectClass=user)" sAMAccountName

# 4. Audit Cross-Forest Trust from RHEL IdM
$ ipa user-show user123@ad.company.com
```

---

## 🔗 Related Documentation & References
* [Samba AD DC Official Setup Guide](https://wiki.samba.org/index.php/Setting_up_Samba_as_an_Active_Directory_Domain_Controller)
* [Samba BIND9 DLZ Configuration](https://wiki.samba.org/index.php/BIND9_DLZ_DNS_Back_End)
* [Red Hat Enterprise Linux 9: Identity Management Planning](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html-single/planning_identity_management/index)