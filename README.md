# Enterprise IAM Modernization Blueprint: Active Directory to Red Hat IdM/Keycloak

This repository provides a blueprint for migrating an enterprise network (a several hundreds of workstations/servers) from a legacy Microsoft Active Directory (AD) infrastructure to a modern, decoupled Linux-native Identity and Access Management (IAM) framework.

The architecture is built entirely on **Red Hat Enterprise Linux 9 (RHEL 9)** components - specifically **Red Hat Identity Management (IdM)** and **Red Hat build of Keycloak (RHBK)** - or their upstream open-source equivalents (**FreeIPA** and **Keycloak**).

---

## Target Decoupled Architecture

The target architecture decouples secure infrastructure-level accounts from application single sign-on (SSO) credentials to eliminate single points of failure, administrative overlap, and synchronization lag.

```
                    +------------------------------------+
                    |      Active Directory (AD)         |  <--- Windows Clients (Remaining 20%)
                    |  (Legacy DC / AD Kerberos KDC)     |       (Authenticated Natively)
                    +------------------------------------+
                                      ^
                                      | (Disposable One-Way Cross-Forest Trust)
                                      v
+------------------+  SSO   +--------------------+
| Keycloak (RHBK)  | <====> |    Red Hat IdM     |  <--- RHEL 9 Workstations & Servers (Migrated 80%)
| (Federation Tier)|  SAML  | (IdM Kerberos KDC) |       (Enrolled Natively via SSSD)
+------------------+  OIDC  +--------------------+
         ^                            ^
         |                            | Configuration Management
         | LDAP Federated             | (Automated GPO Replacements)
         v                            v
+------------------+        +--------------------+
| Standalone RHDS  |        |  Ansible Platform  |
| (App User Store) |        | (Hardening/Sudoers)|
+------------------+        +--------------------+
```

---

## Phased Migration Strategy

To avoid "synchronization hell" (fragile LDAP synchronization pipelines, password interceptor DLLs, and LSASS instability), this project implements a **Scaffolded Sunset** strategy.

### Phase 1: The Dual-Core Scaffold (Coexistence)
*   **The AD Core**: Retain a minimal, low-cost Microsoft AD footprint (e.g., two small Domain Controller VMs) to natively manage the remaining 20% of Windows clients (workstations and servers).
*   **The Linux Core**: Stand up Red Hat IdM as a clean Linux infrastructure directory. Join RHEL 9 servers and workstations directly.
*   **The Trust Scaffold**: Configure a one-way **Cross-Forest Kerberos Trust** where IdM trusts Active Directory. Linux clients resolve AD identities on the fly via SSSD with zero password synchronization or data replication.
*   **Modern Federation**: Deploy Keycloak (RHBK) as the single sign-on (SSO) provider, federating user identity directly from AD and IdM.

### Phase 2: Pure Linux Target State (Sunset)
*   **Decommission AD**: As Windows clients are gradually converted to RHEL 9, move remaining administrative accounts directly into the IdM directory.
*   **Tear Down the Scaffold**: Disconnect the Cross-Forest Trust and power down the AD Domain Controllers.
*   **Pure Target State**: Operate a lightweight, high-performance, unified IAM stack managed entirely by Red Hat IdM (using the high-performance embedded 389 Directory Server engine) and Keycloak (RHBK).

---

## Repository Structure

This repository is structured to serve as both an architectural guide and an automation codebase:

```
.
├── README.md                             # This repository homepage (and main roadmap)
├── hosts.ini                             # Standardized Ansible Inventory for Infrastructure Deployment
├── playbooks/                            # Ansible Playbooks for enrollment & hardening
│   ├── deploy-ad-trust.yml               # Automated cross-forest trust setup
│   ├── deploy-krb5-policies.yml          # Centrally managing KDC ticket policies
│   ├── enroll-idm-client.yml             # Automated RHEL 9 IdM domain join
│   ├── enforce-sudoers.yml               # Restructuring local sudo/admin rights
│   └── enforce-scap-hardening.yml        # Enforcing security baselines on workstations/servers
├── scripts/                              # Custom automated backup/restore/trust scripts
│   ├── ds389-backup-manager.sh           # Non-disruptive hot backup utility
│   ├── ds389-restore-manager.sh          # Physical and logical database recovery utility
│   └── setup-ssh-trust.sh                # One-pass key propagation engine
└── docs/                                 # Code-locked Technical Guides
    ├── INSTALLATION_GUIDE.md             # Standard OS setup, Satellite, and umask configs
    ├── HYBRID_TRUST_MANAGEMENT.md        # AD Trust playbooks, Samba configs, RPC port mappings
    ├── SSSD_TEMPLATES.md                 # Highly tuned Jinja2 sssd.conf templates & variables
    └── KERBEROS_LIFECYCLE.md             # External hosts setup, KDC ticket policies & playbooks
└── wiki/                                 # Detailed architecture guides (GitHub Wiki)
    ├── WIKI_AUTHENTICATION_WORKFLOWS.md  # Technical workings of SSSD's ldap_id_mapping setting
    ├── WIKI_DISASTER_RECOVERY.md         # Replication recovery and verification playbook 
    ├── WIKI_ENTERPRISE_MIGRATION.md      # Explains the migration reasoning
    └── WIKI_HYBRID_IDENTITY.md           # Keycloak (RHBK) and SSSD coordination
```

---

## Deep-Dive Architecture Wiki & Documentation Suite

For detailed architectural strategies and conceptual reviews, explore the [GitHub Wiki](../../wiki) sections:

1.  [**Enterprise Identity Migration: Active Directory to Red Hat IdM**](../../wiki/WIKI_ENTERPRISE_MIGRATION)  
    *Detailed analysis of migration trade-offs, database decoupling, and why legacy synchronization models were rejected.*
2.  [**Modernized Hybrid Identity: Active Directory and Red Hat Federation**](../../wiki/WIKI_HYBRID_IDENTITY)  
    *How Keycloak (RHBK) and SSSD coordinate to bridge legacy Kerberos-based desktop authentication with modern SaaS SSO.*
3.  [**Active Directory and Red Hat IdM Authentication Workflows**](../../wiki/WIKI_AUTHENTICATION_WORKFLOWS)  
    *Step-by-step transaction logs, Kerberos KDC referral mechanics, and browser SPNEGO flows across RHEL 9 and Windows environments.*
4.  [**389 Directory Server Replication Recovery and Verification Playbook**](../../wiki/WIKI_DISASTER_RECOVERY)  
    *Detailed step-by-step procedures to deploy automated backup and restore tools, simulate replica node crashes, execute physical restorations, and resolve topology split-brains.*

---

## Code-Locked Technical Guides (`/docs` Directory)

For active step-by-step operational instructions and configuration templates, view the files locally in the `/docs` folder:

5.  [**Red Hat Identity Management (IdM) and 389 Directory Server Installation Guide**](docs/INSTALLATION_GUIDE.md)  
    *Detailed deployment instructions, including Red Hat Satellite repo syncing, umask rules, installation prompts, and FIPS mode overrides.*
6.  [**Hybrid Identity Management via Active Directory and IdM Trust**](docs/HYBRID_TRUST_MANAGEMENT.md)  
    *Step-by-step administration guides for trust creation, Samba port lockdowns, AD decommissioning, and GPO replacement playbooks.*
7.  [**Advanced SSSD Configuration Blueprints**](docs/SSSD_TEMPLATES.md)  
    *Production-grade sssd.conf templates featuring RAM-cached SSSD databases (tmpfs) and low-latency nested group settings.*
8.  [**Configuring External System Kerberos and Managing KDC Ticket Policies**](docs/KERBEROS_LIFECYCLE.md)  
    *Guides to bridge external hosts, administer KDC ticket lifetimes, deploy indicator-based (MFA) policies, and run verification audits.*

---

## Prerequisites & System Requirements

Before deploying the playbooks, ensure your environment meets these core infrastructure requirements:

1.  **DNS Delegation**: Red Hat IdM must reside in a distinct DNS domain from Active Directory to prevent Kerberos realm collisions.
    *   *Example AD Domain*: `corp.local` or `ad.company.com`
    *   *Example IdM Domain*: `linux.company.com` or `ipa.company.com`
2.  **Network Ports**: Ensure TCP/UDP port 88 (Kerberos), TCP/UDP port 389 (LDAP), TCP/UDP port 464 (Kerberos password change), TCP port 636 (LDAPS), and TCP port 135 (DCE RPC End-point mapper) are open between the AD Domain Controllers, the IdM Masters, and all RHEL 9 clients.
3.  **Red Hat Subscriptions**: Active subscriptions for RHEL 9, Red Hat IdM, and Keycloak (RHBK). If you do not have enterprise licenses, ensure you deploy their upstream counterparts (Rocky Linux/AlmaLinux, FreeIPA, and Keycloak).
4.  **Ansible Engine**: Ensure Ansible Core 2.14+ is installed with the `ansible-freeipa` and `redhat.rhel_system_roles` collections.

---

## 🔗 Official Reference Documentation

To explore specific product features and low-level settings, refer directly to the official vendor documentation:

*   **Red Hat Enterprise Linux 9: Identity Management (IdM)**:
    *   [Planning Identity Management on RHEL 9](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html-single/planning_identity_management/index)
    *   [Installing Identity Management on RHEL 9](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html-single/installing_identity_management/index)
    *   [Installing trust between IdM and AD on RHEL 9](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html-single/installing_trust_between_idm_and_ad/index)
    *   [Using Ansible to install and manage IdM on RHEL 9](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html-single/using_ansible_to_install_and_manage_identity_management/index)
*   **Red Hat Directory Server 12 (RHDS)**:
    *   [Configuring and managing replication in RHDS 12](https://docs.redhat.com/en/documentation/red_hat_directory_server/12/html-single/configuring_and_managing_replication/index)
    *   [Tuning the performance of RHDS 12](https://docs.redhat.com/en/documentation/red_hat_directory_server/12/html-single/tuning_the_performance_of_red_hat_directory_server/index)
*   **Red Hat build of Keycloak (RHBK) 26**:
    *   [Server Configuration Guide for RHBK 26.6](https://docs.redhat.com/en/documentation/red_hat_build_of_keycloak/26.6/html-single/server_configuration_guide/index)
    *   [Operator Guide for RHBK 26.6](https://docs.redhat.com/en/documentation/red_hat_build_of_keycloak/26.6/html-single/operator_guide/index)
    *   [Supported Configurations Matrix](https://access.redhat.com/articles/7033107)
*   **Upstream 389 Directory Server (389-ds)**:
    *   [Official Upstream Architecture Guide](https://www.port389.org/docs/389ds/documentation.html)
    *   [Upstream Download and Build Reference](https://www.port389.org/docs/389ds/download.html)
