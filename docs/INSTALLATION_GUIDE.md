# Red Hat Identity Management (IdM) and 389 Directory Server Installation Guide

This guide provides step-by-step, production-ready instructions for deploying the two directory tiers of your decoupled IAM architecture: **Red Hat Identity Management (IdM)** (using its native embedded directory for host management) and **389 Directory Server (RHDS 12 / ds389)** (as your standalone, general-purpose application user store).

Official manuals for deeper reference:
*   [Red Hat Enterprise Linux 9: Installing Identity Management](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html-single/accessing_identity_management_services/index)
*   [Red Hat Directory Server 12: Installing Red Hat Directory Server](https://docs.redhat.com/en/documentation/red_hat_directory_server/12/html-single/installing_red_hat_directory_server/index)

---

## 1. Red Hat Satellite & Repository Enablement (Enterprise Prerequisites)

In enterprise environments, systems do not pull packages directly from the public internet. Instead, they obtain verified software packages from local **Red Hat Satellite** or Red Hat Subscription Management.

### A. Enabling Repositories in Red Hat Satellite
Before attempting package installations, ensure that the RHEL 9 AppStream repositories are enabled and synchronized:
1.  **Log in** to your Red Hat Satellite Web UI.
2.  **Navigate** to **Content** > **Red Hat Repositories**.
3.  **Search** for and enable the following repository for your target client architecture:
    *   `Red Hat Enterprise Linux 9 for x86_64 - AppStream (RPMs)` (specifically the `rhel-9-for-x86_64-appstream-rpms` repository).
4.  **Synchronize**: Ensure that the enabled repository has successfully synchronized under your designated Product and is added to your target Content Views.
5.  **Activation Keys**: Assign the Content View containing this repository to your target RHEL 9 system's activation key.

### B. Registering and Enabling on the RHEL 9 Host
On the target IdM server host, register the system and verify the AppStream channel is enabled:
```bash
# Register the client to Satellite (if not already done via kickstart)
subscription-manager register --org="Your_Org" --activationkey="Your_Key"

# Verify that the AppStream repository is active
subscription-manager repos --enable=rhel-9-for-x86_64-appstream-rpms
```

---

## 2. Host Preparation and Prerequisites

Before installation, verify your hardware sizing, root mask, cryptographic policies, and firewall configurations to ensure long-term stability and support replica deployments:

### A. Hardware Sizing & Resource Sizing
RAM is the single most critical asset to size correctly. Directory database cache and active LDAP operations require ample memory to prevent disk I/O bottlenecks:
*   **Up to 10,000 Users and 100 Groups**: At least **4 GB of RAM** and **4 GB of swap space**.
*   **Up to 100,000 Users and 50,000 Groups**: At least **16 GB of RAM** and **4 GB of swap space**.
*   *Virtualization Note*: Memory ballooning must be disabled, and the complete RAM allocated must be fully reserved for the guest IdM virtual machines.

### B. File Mode Creation Mask (`umask`)
*   **Critical Requirement**: The file mode creation mask (`umask`) for the `root` account **must be set to `0022`** before executing any IdM server or client installation scripts. This allows non-root system users (and internal system accounts like `dirsrv` or `pkiuser`) to read configuration and certificate files generated during deployment.
*   If a different `umask` is configured (such as `0027`), the installer displays a warning; ignoring this warning causes system permissions failures and prevents future replica enrollments.
*   *Command sequence to verify and set umask*:
    ```bash
    # Verify current mask
    umask
    # Set to required value
    umask 0022
    # (Execute installation, then optionally restore legacy mask)
    umask 0027
    ```

### C. FIPS and Cryptographic Policies
*   If your RHEL 9 IdM environment is configured in **FIPS mode**, the IdM-AD trust will fail to establish by default. This is because Windows Active Directory requires RC4 or AES HMAC-SHA1 encryptions, which are disabled by default on RHEL 9 in FIPS mode (which allows only AES HMAC-SHA2).
*   *Workaround*: Enable AES HMAC-SHA1 encryption on your RHEL 9 KDC servers. Do not configure your IdM servers with the more restrictive `FIPS:OSPP` policy, as it is unsupported.

### D. Hostname & DNS Configuration
1.  **Set static fully qualified domain name (FQDN)**:
    ```bash
    hostnamectl set-hostname idm-master-01.linux.company.com
    ```
2.  **Verify local DNS resolution**: Ensure the hostname resolves strictly to the server's static IP address (and not a loopback address like `127.0.0.1` in `/etc/hosts`).

### E. Firewall Configurations
Open ports required for LDAP, Kerberos, DNS, and Certificate Authority services on your RHEL 9 host:
```bash
firewall-cmd --add-service={freeipa-client,dns,kerberos,ldap,ldaps,http,https} --permanent
# Ensure port 135 (DCE RPC End-point Mapper) is open on the trust controller
firewall-cmd --add-port=135/tcp --permanent
firewall-cmd --reload
```
*Note: Ports 8080 and 8443 are used internally by the `pki-tomcat` servlet engine and must remain blocked in the public firewall to prevent direct external exploitation.*

---

## 3. Package Installation Options

Red Hat packages IdM as a module stream to manage its complex dependencies cleanly. Choose between the packages below depending on your target infrastructure needs:

### Key IdM Server RPM Packages
*   `ipa-server` (The main meta-package that pulls down the Directory Server, Kerberos KDC, and base components).
*   `ipa-server-dns` (If integrating an integrated DNS server).
*   `ipa-server-trust-ad` (Samba-based extensions required to support Cross-Forest Trusts with AD).
*   `ipa-client` (For client enrollment).

### A. Enable the IdM Module Stream
To enable the standard DL1 module stream for RHEL 9:
```bash
sudo dnf module enable idm:DL1 -y
```

### B. Run the DNF Installation Command
Choose the installation variant that matches your infrastructure:
*   **IdM Server with Integrated DNS & AD Trust (Recommended for this Blueprint)**:
    ```bash
    sudo dnf install ipa-server ipa-server-dns ipa-server-trust-ad samba-client -y
    ```
*   **Standard IdM Server (Without Integrated DNS & AD Trust)**:
    ```bash
    sudo dnf install ipa-server -y
    ```

---

## 4. Running the IdM Installation Wizard

After the DNF package installation finishes successfully, configure your domain, realm, and directory administrative passwords.

### Option A: Interactive Installation
Running the installer without flags triggers the interactive setup wizard, which prompts you with a sequence of configuration questions:
```bash
# Start interactive setup (with integrated DNS)
sudo ipa-server-install --setup-dns
```
The wizard will ask you to confirm:
1.  **Server Hostname**: Defaults to your static FQDN (e.g., `idm-master-01.linux.company.com`).
2.  **Domain Name**: The DNS domain for the identity pool (e.g., `linux.company.com`).
3.  **Realm Name**: The Kerberos realm, which must be capitalized (e.g., `LINUX.COMPANY.COM`).
4.  **Directory Manager Password**: Sets the password for the local administrative `cn=Directory Manager` account in the embedded 389-ds engine.
5.  **Kerberos Admin Password**: Sets the administrative password for the Kerberos admin portal and the IdM Web UI.
6.  **DNS Forwarders**: If configuring integrated DNS, it will ask for forwarders (e.g., pointing to your gateway or primary DNS like `192.168.1.1`).

### Option B: Unattended, Silent Installation (Recommended for Automation)
To deploy your primary master without interactive prompts, pass all configuration parameters inline:
```bash
sudo ipa-server-install \
  --domain=linux.company.com \
  --realm=LINUX.COMPANY.COM \
  --ds-password=SecureDirectoryManagerPassword \
  --admin-password=SecureAdminPassword \
  --setup-dns \
  --forwarder=192.168.1.1 \
  --no-host-dns \
  --unattended
```

---

## 5. Standalone 389 Directory Server (RHDS 12 / ds389) Installation

A standalone **389 Directory Server** instance is used to handle application-specific users, groups, and Single Sign-On (SSO) queries, keeping them decoupled from RHEL system login operations.

### A. Package Installation
Install the Directory Server base utility packages on your dedicated server:
```bash
sudo dnf install 389-ds-base -y
```

### B. Automated Instance Creation (`dscreate`)
389-ds utilizes the silent, file-driven `dscreate` configuration engine. Save the following template content to `/tmp/instance.inf`:
```ini
[general]
config_version = 2
strict_hostname_checking = False

[slapd]
instance_name = slapd-app-user-store
port = 389
secure_port = 636
root_dn = cn=Directory Manager
root_password = SecureDirectoryManagerPassword
suffix = dc=app,dc=company,dc=com
self_sign_cert = True

[backend-userroot]
create_backend = True
sample_entries = False
```

Run the installation command to instantiate the new directory instance silently:
```bash
sudo dscreate from-file /tmp/instance.inf
```

Enable and start the systemd service for your directory instance:
```bash
sudo systemctl enable dirsrv@slapd-app-user-store --now
```

### C. Verification and Dynamic Configuration
Verify the running status and perform a quick configuration update using `dsconf`:
```bash
# Check status
dsctl slapd-app-user-store status

# Adjust search limits dynamically
dsconf -D "cn=Directory Manager" ldap://localhost config replace nsslapd-sizelimit=5000
```

---

## 6. Automated Infrastructure Deployment with Ansible

To enroll multiple systems securely, utilize Ansible's standard collections to automate server installations on your infrastructure nodes.

### Playbook: Deploy Red Hat IdM Server (`playbooks/install-idm-server.yml`)
```yaml
---
- name: Deploy Red Hat IdM Primary Server
  hosts: idm_masters
  become: true
  vars:
    # Set deployment variables matching target infrastructure
    ipaserver_domain: linux.company.com
    ipaserver_realm: LINUX.COMPANY.COM
    ipa_admin_password: "SecureAdminPasswordSecure" # Deploy via Vault in production
    ipa_dm_password: "SecureDirectoryManagerPasswordSecure"
    ipaserver_setup_dns: true
    ipaserver_dns_forwarders:
      - 192.168.1.1

  tasks:
    - name: Ensure firewalld rules are configured
      ansible.builtin.firewalld:
        service: "{{ item }}"
        state: enabled
        permanent: true
        immediate: true
      loop:
        - freeipa-server
        - dns
        - ldap
        - ldaps

    - name: Ensure TCP port 135 is open for trust capabilities
      ansible.builtin.firewalld:
        port: 135/tcp
        state: enabled
        permanent: true
        immediate: true

    - name: Deploy Master Directory Server via Ansible System Role
      ansible.builtin.import_role:
        name: freeipa.ansible_freeipa.ipaserver
      vars:
        state: present
```

---

## 🔗 Official Documentation References
*   [Red Hat Enterprise Linux 9: Installing Identity Management](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html-single/accessing_identity_management_services/index)
*   [Red Hat Directory Server 12: Installing Red Hat Directory Server](https://docs.redhat.com/en/documentation/red_hat_directory_server/12/html-single/installing_red_hat_directory_server/index)
*   [389 Directory Server Project Site: Quick Start Installation Guide](https://www.port389.org/docs/389ds/download.html)
