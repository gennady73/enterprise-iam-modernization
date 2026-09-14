# Samba 4 Active Directory Domain Controller (Samba AD DC) Technical Implementation Guide

**Document Target**: Engineering & DevOps Teams  
**Scope**: Greenfield "Plan B" Deployment & Phase 2 Active Directory Migration  
**Base OS**: Rocky Linux 9 (RHEL 9 Binary Compatible)  
**Status**: Production-Ready Technical Runbook  

---

## 🏗️ Overview & Dual-Purpose Strategy

This guide provides step-by-step technical procedures for deploying **Samba 4 Active Directory Domain Controllers (Samba AD DC)** on **Rocky Linux 9**.

It serves two primary operational mandates:
1. **Track A ("Plan B" Greenfield Deployment)**: A standalone, self-contained blueprint to establish a 100% Linux-native IAM infrastructure (Samba AD DC + Red Hat IdM + Keycloak) from scratch with zero Microsoft AD dependencies.
2. **Track B (Phase 2 AD Migration Runbook)**: An in-place migration runbook for existing environments moving from **Phase 1 Coexistence** to **Phase 2 Pure Open-Source Target State**, executing replica joins, FSMO transfers, and Windows DC decommissioning with zero user profile disruption.

---

## 1. Containerized RPM Compilation Pipeline (Podman)

Red Hat Enterprise Linux and Rocky Linux 9 disable AD DC capabilities in default OS Samba packages due to Heimdal vs. MIT Kerberos dependencies. To maintain host security without installing compilers or IDEs on production Domain Controllers, compile custom Samba RPMs against MIT Kerberos inside an isolated Podman container.

### A. Build Container Specification (`Dockerfile.samba-build`)
Create the build definition on a dedicated CI/CD runner:

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
Run the containerized build script to compile Samba with MIT Kerberos support (`--with-system-mitkrb5`):

```bash
# Spin up the build container and compile Samba AD DC RPMs
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
Publish the resulting RPM packages to your private Red Hat Satellite or internal DNF repository.

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
Remove standard configuration stubs and provision the new domain:

```bash
# rm -f /etc/samba/smb.conf /etc/krb5.conf
# samba-tool domain provision \
    --server-role=dc \
    --use-rfc2307 \
    --dns-backend=BIND9_DLZ \
    --realm=AD.COMPANY.COM \
    --domain=AD \
    --adminpass='SecureP@ssw0rd2026!'
```

Start and enable system services:
```bash
# cp /var/lib/samba/private/krb5.conf /etc/krb5.conf
# systemctl enable --now named samba
```

---

## 3. Track B: Phase 2 Active Directory Migration Runbook

Follow this track when migrating an existing Active Directory domain from Microsoft Windows Server Domain Controllers to Samba 4 AD DCs.

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
On an existing Windows Domain Controller, verify FSMO role locations and forest health:
```powershell
# Run from Windows PowerShell as Domain Admin
Get-ADDomainController -Filter * | Select-Name, IPv4Address, OperatingSystem
netdom query fsmo
dcdiag /test:DNS /v
```

### Step 2: Executing the In-Place Replica Join
Joining Samba directly to the existing Active Directory domain replicates the directory database, SID history, user credentials, and machine accounts. **Because the Domain SID is unchanged, local user desktop profiles on Windows clients are preserved without requiring domain re-joins.**

Run `samba-tool domain join` on the Rocky Linux 9 Samba node:

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
Transfer all five FSMO roles (Schema, Domain Naming, RID, PDC Emulator, Infrastructure) from the Microsoft DC to the new Samba AD DC:

```bash
# samba-tool fsmo transfer --role=all -U "AD\Administrator"
```

Verify role ownership:
```bash
# samba-tool fsmo show
```

### Step 4: Stateful SysVol Replication (Rsync over SSH)
Because Samba AD DC does not natively support DFS-R, deploy a systemd-timer-driven **rsync over SSH** process between primary (`dc-01`) and secondary (`dc-02`) Samba DCs.

Create `/usr/local/bin/sysvol-sync.sh`:
```bash
#!/bin/bash
# Unidirectional, stateful SysVol replication with extended attribute preservation
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

1. **Enable ACME on IdM**:
   ```bash
   # ipa-acme-manage enable
   ```
2. **Deploy `cepces` Proxy or Windows ACME Client**:
   On Windows clients, deploy an automated background scheduled task running *win-acme* pointing to `https://idm-master-01.linux.company.com/acme/directory`. This auto-enrolls and auto-renews machine certificates silently.

### B. Zero-Trust Administrative Governance (GPMC on Tier-0 PAWs)
To prevent credential-dumping attacks (LSASS memory extraction) on end-user devices:
* **Never** install the Group Policy Management Console (GPMC) on standard employee laptops.
* Deploy GPMC on an isolated **Tier-0 Privileged Access Workstation (PAW)** virtual machine.
* Require administrators to authenticate via **Keycloak (RHBK) Multi-Factor Authentication (OTP)** to access an ephemeral HTML5 jump session (e.g., Apache Guacamole) to run GPMC.

### C. CLI Group Policy Administration
Manage GPOs directly from the Samba CLI without launching a Windows GUI:

```bash
# Load official Samba ADMX templates into SysVol
$ samba-tool gpo admxload -U Administrator

# List active GPOs in the domain
$ samba-tool gpo listall
```

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
