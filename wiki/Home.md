# DevOps Onboarding & Deployment Roadmap: Active Directory to Red Hat IdM

Welcome to the **Enterprise IAM Modernization Blueprint** workspace. This Wiki home page serves as our master chronological deployment guide, onboarding manual, and operational map.

To help you get up to speed quickly, this document is structured as a **DevOps Field Journal**. Rather than presenting dry, encyclopedic configuration dumps, we trace the chronological path of implementing **Phase 1 (The Coexistence Core)**. Each step covers the high-level objectives, underlying technical concepts, and—most importantly—real-world **Struggle Warnings** ("When you hit the wall") and **Aha! Moments** compiled by our engineering team during deployment.

---

## The Decoupled Target Architecture

Our blueprint decouples secure infrastructure-level OS accounts from application-level Single Sign-On (SSO) credentials. This design eliminates single points of failure, administrative overlap, and synchronization lag across a several hundreds workstations\servers footprint.

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

## Chronological Deployment Journey

```
  [Strategic Alignment]       [Infrastructure Setup]         [Forest Bridging]
        Step 1                      Step 2                       Step 3
  Target Architecture   ===>   Deploy IdM & ds389   ====>   Establish Trust
  (Migration Strategy)         (RHEL Satellite/umask)       (Samba Port Lockdowns)
                                                                     ||
                                                                     v
  [Security Hardening]        [Client Integration]         [Performance Tuning]
        Step 6                      Step 5                       Step 4
  Advanced KDC Policies  <===  Client Enrollment   <====   sssd.conf Cache Tuning
  (MFA/OTP Ticket Lifes)       (Ansible Playbooks)         (tmpfs Memory Mounts)
```

---

### 📍 Step 1: Strategic Planning & Architectural Alignment
*   **Objective**: Understand the structural and security trade-offs of migrating our Linux infrastructure from database-level replication to a native Kerberos cross-realm trust model.
*   **The Technical Concept**: 
    We completely separate the infrastructure directory tier from the application user store tier. Red Hat Identity Management (IdM) acts as our dedicated systems directory (managing host SSH keys, sudo rules, and host-based access controls), while a standalone Red Hat Directory Server (RHDS 12 / ds389) serves application user accounts to Keycloak (RHBK). Rather than synchronizing passwords or replicating databases across boundaries, IdM establishes a native Cross-Forest Trust with Active Directory, delegating password evaluations directly to the AD Kerberos Key Distribution Center (KDC).
*   **Struggle Warning (Synchronization Hell)**:
    In past setups, administrators synchronized Windows accounts into Linux directories using tools like the 389 Directory Server's *Windows Synchronization (WinSync)* plugin. This required installing a custom, un-supported local security authority (LSA) notification package—*Password Sync (PassSync)*—on **every single Active Directory Domain Controller**. If the PassSync DLL leaked memory or conflicted with a Windows security patch, it crashed the Windows LSASS process, causing the Domain Controller to experience a Blue Screen of Death (BSOD). Active synchronization also suffered from replication lag, leading to automated system script failures and account lockout storms in AD.
*   **Aha! Moment (The Native Trust Solution)**:
    By moving to a Cross-Forest Kerberos Trust, we treat Active Directory as the absolute, single source of truth for passwords, with **zero database replication or password synchronization**. SSSD (System Security Services Daemon) on the Linux clients dynamically resolves AD SIDs on the fly using secure cross-realm referrals, leaving our AD Domain Controllers completely untouched and stable.
*   **Deep-Dive Guides**:
    *   📖 Read [**Enterprise Identity Migration Strategy**](WIKI_ENTERPRISE_MIGRATION) to explore the technical reasons why Active Directory database-level synchronization was deprecated and removed in RHEL 9.
    *   📖 Read [**Modernized Hybrid Identity & Federation**](WIKI_HYBRID_IDENTITY) to analyze how SSSD coordinates with the Red Hat build of Keycloak (RHBK) to bridge legacy Kerberos logins with web-based application single sign-on.

---

### 📍 Step 2: Standing Up the Directory Cores
*   **Objective**: Deploy our primary Red Hat IdM master server (`idm-master-01.linux.company.com`) and standalone application Directory Server (`host-a.company.com`).
*   **The Technical Concept**: 
    Synchronizing RHEL 9 AppStream repository packages via **Red Hat Satellite**, configuring network firewall rules, enforcing file system creation masks, overriding cryptographic baselines for AD compatibility, and deploying silent, file-driven `dscreate` directory installations.
*   **Struggle Warning (The Secret Installation Blocks)**:
    1.  **The `umask` Trap**: Our corporate RHEL 9 server templates enforce a highly restrictive default root creation mask of `umask 0027` for security hardening. If you execute the IdM server installer (`ipa-server-install`) under this mask, the installation **will fail and corrupt the deployment** halfway through. The internal Certificate Authority (CA) PKI-Tomcat servlet requires a **strict `umask 0022`** during deployment so that non-root system services can read generated certificate bundles and trust chains.
    2.  **The FIPS Mode Cryptographic Lock**: Our production RHEL 9 hosts run in FIPS-compliant mode. FIPS mode disables legacy cryptographic algorithms like MD5, RC4, and AES HMAC-SHA1 by default, permitting only AES HMAC-SHA2. However, Microsoft Active Directory strictly requires AES HMAC-SHA1 to negotiate cross-realm trust handshakes. If you do not override your IdM master KDC configuration to explicitly permit AES HMAC-SHA1, your future AD trust will fail to bind.
*   **Aha! Moment (Non-Interactive `dscreate` Deployments)**:
    Instead of manually running interactive scripts or clicking through menus to deploy our standalone application Directory Server (RHDS 12 / ds389), we use the silent, file-driven `dscreate` engine. By defining a simple `.inf` configuration file, we can instantiate, secure, and start new directory server engines in under 10 seconds via automation.
*   **Implementation Guide**:
    *   🛠️ Refer to the code-locked [**IdM and 389-ds Installation Guide**](https://github.com/gennady73/enterprise-iam-modernization/blob/main/docs/INSTALLATION_GUIDE.md) in our repository to configure Red Hat Satellite streams, set umasks, override FIPS policies, and deploy standalone directory engines.

---

### 📍 Step 3: Bridging the Forest (The Trust)
*   **Objective**: Configure a secure, one-way cross-realm trust connecting our Linux directory infrastructure directly to Active Directory.
*   **The Technical Concept**: 
    Automating trust configurations using the native `ipatrust` Ansible role, validating Kerberos KDC referral logic, and configuring secure Samba-based domain controller emulations on our IdM trust controllers.
*   **Struggle Warning (Firewall Dynamic Port Rejections)**:
    During trust establishment, Samba dynamically allocates high RPC ports to negotiate DCE/RPC sessions with the Windows Domain Controller. If your network DMZ firewalls have closed everything except basic ports, your trust will hang indefinitely and fail. You must restrict Samba's dynamic RPC port assignments to a predictable, static block (`55000-65000`) and map them in your hardware firewalls.
*   **Aha! Moment (The Ansible `ipatrust` Automation)**:
    Rather than executing long, error-prone command-line prompts on each master server, we automate the entire trust creation process across our directory masters. Using the `freeipa.ansible_freeipa.ipatrust` role, we can provision trust zones, configure forward paths, and establish AD linkages via Ansible.
*   **Implementation Guide**:
    *   🛠️ Refer to the code-locked [**Hybrid Trust Administration Guide**](https://github.com/gennady73/enterprise-iam-modernization/blob/main/docs/HYBRID_TRUST_MANAGEMENT.md) to deploy the trust playbooks, restrict dynamic RPC ports, and access our Windows GPO-replacement playbooks.

---

### 📍 Step 4: Client Integration & SSSD Performance Tuning
*   **Objective**: Enroll our first batches of RHEL 9 servers and workstations into our new Linux domain, and optimize directory query performance.
*   **The Technical Concept**: 
    Using `ansible-freeipa` to automate host enrollment, deploying standardized Jinja2-based `sssd.conf` templates, and tuning LDAP caching parameters to handle large AD trust structures.
*   **Struggle Warning (The 12-Second Login Lag)**:
    When you first log into an enrolled RHEL host using an Active Directory trust credential (such as `user123@ad.company.com`), you will experience a painful **10-to-12 second delay** before receiving a shell prompt. This is because SSSD is executing slow disk write I/O operations against its local database cache on `/var/lib/sss/db/` and traversing massive, nested AD group lists across high-latency WAN links.
*   **Aha! Moment (Accelerating Logins to under 0.8 Seconds)**:
    We resolved this latency and achieved ultra-fast logins using two SSSD tuning techniques:
    1.  **RAM-Caching**: Mount the SSSD cache directory (`/var/lib/sss/db/`) in volatile memory using a RAM-based **`tmpfs`** filesystem inside `/etc/fstab`. This removes disk I/O bottlenecks completely.
    2.  **Nested Group Exclusions**: Add SSSD performance variables to ignore nested AD group enumeration and disable heavy LDAP dereferencing:
        ```ini
        subdomain_inherit = ignore_group_members
        ldap_deref_threshold = 0
        ```
*   **Deep-Dive Guides**:
    *   📖 Read [**Active Directory and Red Hat IdM Authentication Workflows**](WIKI_AUTHENTICATION_WORKFLOWS) to trace the exact network-level Kerberos transaction logs and KDC referral steps.
    *   🛠️ Refer to the code-locked [**Advanced SSSD Configuration Blueprints**](https://github.com/gennady73/enterprise-iam-modernization/blob/main/docs/SSSD_TEMPLATES.md) in our repository to deploy these high-performance caching and tuning configurations.

---

### 📍 Step 5: Advanced Security Hardening (KDC Ticket Policies)
*   **Objective**: Manage security baselines, and configure dynamic, factor-based Kerberos ticket lifetimes on our IdM KDC.
*   **The Technical Concept**: 
    Setting up global realm limits, establishing user overrides for administrative accounts, and writing indicator-based MFA rules.
*   **Aha! Moment (Factor-Based Session Lifetimes)**:
    You do not have to settle for one generic ticket duration. By configuring **Authentication Indicators**, we can enforce adaptive lifetimes. If an administrator authenticates with a simple password, they get a standard 8-hour session. If they authenticate using Multi-Factor Authentication (OTP), the KDC attaches an `otp` indicator, granting them a highly secure, non-renewable **4-hour session** with access to critical system sudo roles.
*   **Implementation Guide**:
    *   🛠️ Refer to the code-locked [**Kerberos Configuration & Lifecycle Guide**](https://github.com/gennady73/enterprise-iam-modernization/blob/main/docs/KERBEROS_LIFECYCLE.md) in our repository to deploy the `deploy-krb5-policies.yml` playbook, map indicators, and run the 5-stage KDC verification workflow.

---

### 📍 Step 6: Day-2 Resilience (Backups & Disaster Recovery)
*   **Objective**: Ensure directory system availability, run simulated node failures, and recover multi-supplier databases.
*   **The Technical Concept**: 
    Scheduling text-based and hot-binary backups, executing physical database restores, and resolving topology split-brains.
*   **Struggle Warning (Changelog Purge Expirations)**:
    If a replication master host falls offline and is restored using a backup that is older than the replication **changelog purge window** (typically 7 days), it will be blocked from rejoining the topology and throw `OutOfSync` errors. The other suppliers have already cleaned up the change history required to sync the host. You must resolve this by executing a master supplier-initiated online Suffix Re-initialization over the network.
*   **Implementation Guide**:
    *   📖 Read [**Disaster Recovery, Backups, & Replication Rebuilds**](WIKI_DISASTER_RECOVERY) to deploy the automated `ds389-backup-manager.sh` and `ds389-restore-manager.sh` scripts, simulate replica failures, and run split-brain audits.

---

## Project Navigation Map

To keep our automation and documentation perfectly aligned, we separate our resources based on their lifecycle:

*   **The GitHub Wiki (Strategic & Conceptual)**: Holds long-term architectural models, communication protocols, and strategic analyses that rarely change.
*   **The Repository `/docs` Folder (Code-Locked & Technical)**: Houses code-adjacent, version-locked resources (such as SSSD templates, variable mappings, installation checklists, and backup scripts) that must stay perfectly aligned with our active Ansible playbooks in the master Git branch.

| Phase 1 Focus Area | Strategic Wiki Resource | Technical Repository Code-Adjacent Resource |
| :--- | :--- | :--- |
| **Strategy & Sizing** | 📖 [Migration Strategy](WIKI_ENTERPRISE_MIGRATION) | 🛠️ [Installation Guide](https://github.com/gennady73/enterprise-iam-modernization/blob/main/docs/INSTALLATION_GUIDE) |
| **Forest Trust Link** | 📖 [Federation Architecture](WIKI_HYBRID_IDENTITY) | 🛠️ [Trust Management Guide](https://github.com/gennady73/enterprise-iam-modernization/blob/main/docs/HYBRID_TRUST_MANAGEMENT.md) |
| **Client Tuning** | 📖 [Authentication Workflows](WIKI_AUTHENTICATION_WORKFLOWS) | 🛠️ [SSSD Blueprints](https://github.com/gennady73/enterprise-iam-modernization/blob/main/docs/SSSD_TEMPLATES.md) |
| **Security Hardening** | — | 🛠️ [Kerberos & KDC Policies](https://github.com/gennady73/enterprise-iam-modernization/blob/main/docs/KERBEROS_LIFECYCLE.md) |
| **Disaster Resilience** | 📖 [Replication Recovery Playbook](WIKI_DISASTER_RECOVERY) | — |
