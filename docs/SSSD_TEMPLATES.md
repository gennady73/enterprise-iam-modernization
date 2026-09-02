# Advanced SSSD Configuration Blueprints

This document contains updated, production-grade `sssd.conf` templates designed to support your gradual migration from Microsoft Active Directory to Red Hat Enterprise Linux 9 and Red Hat Identity Management (IdM). 

These templates incorporate **specific SSSD performance tuning variables** designed to prevent login latency, connection timeouts, and authentication blockages in large or geographically distributed IdM-AD trust environments.

---

## SSSD High-Performance RAM Caching (tmpfs)

SSSD constantly performs write transactions to its local database cache (`/var/lib/sss/db/config.ldb`). Under heavy multi-user lookups (common in environments with active AD trusts), disk I/O bottlenecks can cause substantial login delays. 

To optimize performance, mount the SSSD cache in a temporary RAM-based filesystem (`tmpfs`) on your RHEL 9 clients and IdM servers:

1.  **Add fstab entry**: Add the following line to `/etc/fstab`:
    ```ini
    tmpfs /var/lib/sss/db/ tmpfs size=300M,mode=0700,uid=sssd,gid=sssd,rootcontext=system_u:object_r:sssd_var_lib_t:s0 0 0
    ```
    *Note: Estimate approximately 100 MB of RAM size per 10,000 LDAP entries in your domain.*

2.  **Mount the filesystem & Restart SSSD**:
    ```bash
    mount /var/lib/sss/db/
    systemctl restart sssd
    ```
    *Warning: Cached entries do not persist after a reboot when stored in RAM. While this is entirely safe on IdM servers (as SSSD can immediately re-query the local Directory Server), a client system that is rebooted while disconnected from the network will be unable to authenticate offline users until connectivity is restored.*

---

## Template 1: SSSD on RHEL 9 Client (Joined to IdM with AD Forest Trust)

This template is configured for the **RHEL 9 clients (workstations and servers)** in **Phase 1**. It natively joins the systems to the Red Hat IdM domain while dynamically resolving Active Directory users (such as `user123@ad.company.com`) via the secure Cross-Forest trust.

It includes advanced tuning variables to optimize search response times and prevent worker thread blockage:

### `sssd.conf.j2`
```ini
[sssd]
config_file_version = 2
services = nss, pam, ssh, sudo
# Explicitly list the target Linux domain. Subdomains (AD trust forest) are resolved dynamically.
domains = {{ ipa_domain }}

[nss]
homedir_substring = /home
# Performance tuning for fast dynamic system reads
entry_negative_timeout = 15
entry_cache_nowait_percentage = 50

[pam]
# Enable offline login capability for RHEL 9 workstations (laptops)
offline_credentials_expiration = 30
offline_failed_login_attempts = 3
offline_failed_login_delay = 5
# Timeout configurations to avoid excessive round-trips to Active Directory
pam_id_timeout = 9

[ssh]

[sudo]

[domain/{{ ipa_domain }}]
# Primary Identity, Auth, and Access providers are Red Hat IdM (IPA)
id_provider = ipa
auth_provider = ipa
access_provider = ipa
chpass_provider = ipa
sudo_provider = ipa

# Core Domain Settings
ipa_domain = {{ ipa_domain }}
ipa_server = {{ ipa_servers | join(', _srv_, ') }}
ipa_hostname = {{ ansible_fqdn }}
krb5_realm = {{ ipa_realm | upper }}

# Security & Encryption Settings
krb5_store_password_if_offline = True
cache_credentials = True
secure_channel_req_force_strong_crypto = True

# Dynamic POSIX Attribute Resolution for Active Directory Users
subdomains_provider = ipa
ldap_id_mapping = True
ldap_idmap_range_size = 200000

# Home Directory and Default Shell Layouts for AD Domain Users
fallback_homedir = /home/%d/%u
default_shell = /bin/bash

# Multi-Factor & Federated Device Grant Login Integration (SSSD-IdP 2.7.0+)
# Enables RHEL 9 GUI and console logins to prompt for Keycloak OAuth2 validation
# If IdM has an associated external IDP mapping configured for the AD user
ipa_hbac_support_idp = True

# Advanced Performance Tuning for Active Directory Trusts
# 1. Ignore group member enumeration on group queries for a major performance boost
subdomain_inherit = ignore_group_members
# 2. Disable dereference lookups to prevent heavy, slow nested LDAP calls
ldap_deref_threshold = 0
# 3. Increase Kerberos auth timeout to allow processing complex, large AD group memberships
krb5_auth_timeout = 9
# 4. Increase DNS resolver timeout in case client discovers remote AD sites first
dns_resolver_timeout = 6
```

---

## Template 2: SSSD on RHEL 9 Client (Direct Join to Active Directory)

This template serves as the **Direct AD-Join blueprint** discussed as a "midway alternative." It connects RHEL 9 systems directly to Active Directory domain controllers using `realmd` and SSSD, skipping IdM entirely.

### `sssd.conf.j2`
```ini
[sssd]
config_file_version = 2
services = nss, pam, ssh, sudo
domains = {{ ad_domain }}

[nss]
homedir_substring = /home

[pam]
offline_credentials_expiration = 30
# Timeout configurations to avoid excessive round-trips to Active Directory
pam_id_timeout = 9

[domain/{{ ad_domain }}]
# Primary providers set to native Active Directory
id_provider = ad
auth_provider = ad
access_provider = ad
chpass_provider = ad

# Core Active Directory Configuration
ad_domain = {{ ad_domain }}
ad_servers = {{ ad_domain_controllers | join(', ') }}
krb5_realm = {{ ad_domain | upper }}
cache_credentials = True
krb5_store_password_if_offline = True

# Deterministic SID Hashing
# Ensures that user123 gets the exact same UID/GID on every Linux machine in the network
ldap_id_mapping = True
ldap_idmap_range_size = 200000
ldap_idmap_default_domain_sid = {{ ad_domain_sid }}

# Client-Side Shell and Home Dir Customization for AD Logins
default_shell = /bin/bash
fallback_homedir = /home/%u@%d

# Host-Based Access Control via AD GPOs
# SSSD parses AD GPOs directly and applies logon restrictions on RHEL 9 clients
ad_gpo_access_control = enforcing
ad_gpo_map_interactive = +gdm-vm, +gdm-password
ad_gpo_map_remote_interactive = +sshd

# Advanced Performance Tuning for Active Directory Trusts
# 1. Ignore group member enumeration on group queries for a major performance boost
subdomain_inherit = ignore_group_members
# 2. Disable dereference lookups to prevent heavy, slow nested LDAP calls
ldap_deref_threshold = 0
# 3. Increase Kerberos auth timeout to allow processing complex, large AD group memberships
krb5_auth_timeout = 9
# 4. Increase DNS resolver timeout in case client discovers remote AD sites first
dns_resolver_timeout = 6
```

---

## Configuration Variable Mappings (`group_vars/all.yml`)

These Ansible variables are consumed by the templates during rollout. Place this in your repository under `group_vars/all.yml`.

```yaml
---
# Variables for Template 1 (Red Hat IdM + AD Trust)
ipa_domain: linux.company.com
ipa_realm: LINUX.COMPANY.COM
ipa_servers:
  - idm-master-01.linux.company.com
  - idm-master-02.linux.company.com

# Variables for Template 2 (Direct Active Directory Join)
ad_domain: ad.company.com
ad_domain_controllers:
  - dc-01.ad.company.com
  - dc-02.ad.company.com
ad_domain_sid: "S-1-5-21-1122334455-6677889900-1122334455"
```

---

## Deployment Playbook Summary (`deploy-sssd.yml`)

This lightweight Ansible tasks block deploys and locks down SSSD on the RHEL 9 clients:

```yaml
- name: Configure and Deploy System Security Services Daemon (SSSD)
  hosts: rhel_clients
  become: true
  tasks:
    - name: Install SSSD packages
      ansible.builtin.dnf:
        name:
          - sssd
          - sssd-tools
          - sssd-idp  # Required for Keycloak Device Auth Integration (SSSD 2.7.0+)
        state: present

    - name: Deploy sssd.conf configuration
      ansible.builtin.template:
        src: sssd.conf.j2
        dest: /etc/sssd/sssd.conf
        owner: root
        group: root
        mode: '0600'
      notify: Restart SSSD

    - name: Enable SSSD service
      ansible.builtin.systemd:
        name: sssd
        state: started
        enabled: true

  handlers:
    - name: Restart SSSD
      ansible.builtin.systemd:
        name: sssd
        state: restarted
```

---

## 🔗 Official Documentation References
*   [Red Hat Enterprise Linux 9: Tuning Performance in Identity Management](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html-single/tuning_performance_in_identity_management/index)
*   [Red Hat Enterprise Linux 9: Configuring Authentication and Authorization in RHEL](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html-single/configuring_authentication_and_authorization_in_rhel/index)
