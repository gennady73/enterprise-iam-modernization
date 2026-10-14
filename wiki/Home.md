# DevOps Onboarding & Deployment Roadmap: Active Directory to Red Hat IdM

Welcome to the **Enterprise IAM Modernization Blueprint** workspace. This Wiki home page serves as our master chronological deployment guide, onboarding manual, and operational map.

To help you get up to speed quickly, this document is structured as a **DevOps Field Journal**. Rather than presenting dry, encyclopedic configuration dumps, we trace the chronological path of implementing **Phase 0 (POC Sandbox)**, **Phase 1 (The Coexistence Core)**, and **Phase 2 (Pure Target State / Samba AD DC Migration)**.

---

## The Decoupled Target Architecture

Our blueprint decouples secure infrastructure-level OS accounts from application-level Single Sign-On (SSO) credentials. This design eliminates single points of failure, administrative overlap, and synchronization lag across our 150–300 server footprint.

```
                    +------------------------------------+
                    |      Active Directory (AD)         |  <--- Windows Clients (Remaining 20%)
                    |  (Legacy DC or Samba AD DC)        |       (Authenticated Natively)
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
  [Phase 0: POC Sandbox]      [Infrastructure Setup]         [Forest Bridging]
        Step 0                      Step 2                       Step 3
  Complex GPO Validation ===>  Deploy IdM & ds389   ====>   Establish Trust
  (Windows Dev Workstations)   (RHEL Satellite/umask)       (Samba Port Lockdowns)
                                                                     ||
                                                                     v
  [Phase 2: AD Sunset]        [Client Integration]         [Performance Tuning]
        Step 7                      Step 5                       Step 4
  Samba AD DC Migration <===   Client Enrollment   <====   sssd.conf Cache Tuning
  (In-Place Replica Join)      (Ansible Playbooks)         (tmpfs Memory Mounts)
```

---

### 📍 Step 0: Phase 0 POC & Complex GPO Validation Gate
*   **Objective**: Prove, before any migration, that a Samba 4 AD domain controller serves our most complex Windows GPOs (especially those for low-level Windows developer workstations) and that a real workstation applies them without error.
*   **The Technical Concept**:
    A RHEL 9 VM becomes the domain controller of a new domain (`mydomain2.com`) beside the existing AD (`mydomain.com`), which is only read. GPOs under test are exported with `Backup-GPO`, imported into the Samba domain and their group SIDs mapped. One workstation leaves `mydomain.com`, joins `mydomain2.com`, and a script checks RSoP, every policy registry value and the Group Policy event logs. Every step is scripted with pass/fail checks in [`scripts/phase0/`](https://github.com/gennady73/enterprise-iam-modernization/tree/main/scripts/phase0).
*   **Why it works (Zero Translation)**:
    Samba AD DC acts as an LDAP directory and SMB file server and does not translate Windows policies. The Windows client downloads the policy files (`Registry.pol`, `GptTmpl.inf`, preferences) over SMB and applies them with its own Client-Side Extensions. This is the hypothesis Phase 0 tests, not a result yet.
*   **Implementation Guide**: [Samba 4 AD DC Implementation Guide — Phase 0](https://github.com/gennady73/enterprise-iam-modernization/blob/main/docs/SAMBA_AD_DC_IMPLEMENTATION_GUIDE.md#phase-0-the-isolated-poc--complex-gpo-validation-gate-mandatory-gono-go)

---

### 📍 Step 1: Strategic Planning & Architectural Alignment
*   **Objective**: Understand the structural and security trade-offs of migrating our Linux infrastructure from database-level replication to a native Kerberos cross-realm trust model.
*   **The Technical Concept**: 
    We completely separate the infrastructure directory tier from the application user store tier. Red Hat Identity Management (IdM) acts as our dedicated systems directory, while a standalone Red Hat Directory Server (RHDS 12 / ds389) serves application user accounts to Keycloak (RHBK). Rather than synchronizing passwords, IdM establishes a native Cross-Forest Trust with Active Directory, delegating password evaluations directly to the AD Kerberos KDC.
*   **Deep-Dive Guides**:
    *   📖 Read [**Enterprise Identity Migration Strategy**](WIKI_ENTERPRISE_MIGRATION)
    *   📖 Read [**Modernized Hybrid Identity & Federation**](WIKI_HYBRID_IDENTITY)

---

### 📍 Step 2: Standing Up the Directory Cores
*   **Objective**: Deploy our primary Red Hat IdM master server (`idm-master-01.linux.company.com`) and standalone application Directory Server (`host-a.company.com`).
*   **Implementation Guides**:
    *   Refer to the code-locked [**IdM and 389-ds Installation Guide**](https://github.com/gennady73/enterprise-iam-modernization/blob/main/docs/INSTALLATION_GUIDE.md)
    *   Refer to the [**RHDS 12 / 389ds Advanced Multi-Supplier Replication Guide**](https://github.com/gennady73/enterprise-iam-modernization/blob/main/docs/RHDS_ADVANCED_REPLICATION_GUIDE.md)

---

### 📍 Step 3: Bridging the Forest (The Trust)
*   **Objective**: Configure a secure, one-way cross-realm trust connecting our Linux directory infrastructure directly to Active Directory.
*   **Implementation Guide**:
    *   Refer to the code-locked [**Hybrid Trust Administration Guide**](https://github.com/gennady73/enterprise-iam-modernization/blob/main/docs/HYBRID_TRUST_MANAGEMENT.md)

---

### 📍 Step 4: Client Integration & SSSD Performance Tuning
*   **Objective**: Enroll RHEL 9 servers and workstations into our new Linux domain, and optimize directory query performance.
*   **Implementation Guide**:
    *   Refer to the code-locked [**Advanced SSSD Configuration Blueprints**](https://github.com/gennady73/enterprise-iam-modernization/blob/main/docs/SSSD_TEMPLATES.md)

---

### 📍 Step 5: Advanced Security Hardening (KDC Ticket Policies)
*   **Objective**: Manage security baselines, and configure dynamic, factor-based Kerberos ticket lifetimes on our IdM KDC.
*   **Implementation Guide**:
    *   Refer to the code-locked [**Kerberos Configuration & Lifecycle Guide**](https://github.com/gennady73/enterprise-iam-modernization/blob/main/docs/KERBEROS_LIFECYCLE.md)

---

### 📍 Step 6: Day-2 Resilience (Backups & Disaster Recovery)
*   **Objective**: Ensure directory system availability, run simulated node failures, and recover multi-supplier databases.
*   **Implementation Guides**:
    *   📖 Read [**Disaster Recovery, Backups, & Replication Rebuilds**](WIKI_DISASTER_RECOVERY.md)
    *   Refer to the [**RHDS 12 / 389ds Advanced Multi-Supplier Replication Guide**](https://github.com/gennady73/enterprise-iam-modernization/blob/main/docs/RHDS_ADVANCED_REPLICATION_GUIDE.md)

---

### 📍 Step 7: Phase 2 Active Directory Sunset & Samba 4 AD DC Migration (Plan B)
*   **Objective**: Complete the transition to a 100% open-source IAM stack by replacing Microsoft AD with Samba 4 AD DCs on RHEL 9 / Rocky Linux 9 (or deploy a standalone open-source AD domain for greenfield projects).
*   **The Technical Concept**: 
    1. **Containerized RPM Build**: Obtain pre-compiled binaries from the `/rpm` directory or build custom Samba 4.24+ RPMs against MIT Kerberos using the standalone [`samba-rpm-build-rhel9`](https://github.com/gennady73/samba-rpm-build-rhel9) repository.
    2. **In-Place Replica Join**: Join Samba directly to the active forest (`samba-tool domain join`) to replicate LDAP database, user credentials, and Domain SIDs natively without client desktop profile resets.
    3. **SysVol Synchronization**: Deploy a unidirectional **rsync over SSH** wrapper run by systemd timers (`rsync -XAavz --delete`) to replicate GPOs while preserving mandatory POSIX Extended Attributes (`security.NTACL`).
    4. **PKI Auto-Enrollment**: Enable Tomcat ACME responders on IdM (Dogtag CA) and deploy `cepces` proxies for Windows machine certificate auto-enrollment without Microsoft AD CS.
*   **Implementation Guides**:
    * Refer to [**Samba 4 AD DC Technical Implementation Guide**](https://github.com/gennady73/enterprise-iam-modernization/blob/main/docs/SAMBA_AD_DC_IMPLEMENTATION_GUIDE.md)
    * Refer to [**Standalone Custom Samba 4 AD DC RPM Build Guide**](https://github.com/gennady73/enterprise-iam-modernization/blob/main/docs/SAMBA_RPM_BUILD_GUIDE.md)
    *   🔗 External Repository: [`samba-rpm-build-rhel9` on GitHub](https://github.com/gennady73/samba-rpm-build-rhel9)

---

## Project Navigation Map

| Phase / Focus Area | Strategic Wiki Resource | Technical Repository Code-Adjacent Resource |
| :--- | :--- | :--- |
| **Phase 0: GPO Validation Gate** | — | 🛠️ [Samba 4 AD DC Implementation Guide](https://github.com/gennady73/enterprise-iam-modernization/blob/main/docs/SAMBA_AD_DC_IMPLEMENTATION_GUIDE.md) |
| **Phase 1: Strategy** | 📖 [Migration Strategy](WIKI_ENTERPRISE_MIGRATION.md) | 🛠️ [Installation Guide](https://github.com/gennady73/enterprise-iam-modernization/blob/main/docs/INSTALLATION_GUIDE.md) |
| **Phase 1: Forest Trust** | 📖 [Federation Architecture](WIKI_HYBRID_IDENTITY.md) | 🛠️ [Trust Management Guide](https://github.com/gennady73/enterprise-iam-modernization/blob/main/docs/HYBRID_TRUST_MANAGEMENT.md) |
| **Phase 1: Client Tuning** | 📖 [Authentication Workflows](WIKI_AUTHENTICATION_WORKFLOWS.md) | 🛠️ [SSSD Blueprints](https://github.com/gennady73/enterprise-iam-modernization/blob/main/docs/SSSD_TEMPLATES.md) |
| **Phase 1: Hardening** | — | 🛠️ [Kerberos & KDC Policies](https://github.com/gennady73/enterprise-iam-modernization/blob/main/docs/KERBEROS_LIFECYCLE.md) |
| **Phase 1: Resilience** | 📖 [Replication Recovery Playbook](WIKI_DISASTER_RECOVERY.md) | 🛠️ [RHDS Advanced Replication Guide](https://github.com/gennady73/enterprise-iam-modernization/blob/main/docs/RHDS_ADVANCED_REPLICATION_GUIDE.md) |
| **Phase 2: AD Sunset** | — | 🛠️ [Samba 4 AD DC Implementation Guide](https://github.com/gennady73/enterprise-iam-modernization/blob/main/docs/SAMBA_AD_DC_IMPLEMENTATION_GUIDE.md) <br> 🛠️ [Samba RPM Build Guide](https://github.com/gennady73/enterprise-iam-modernization/blob/main/docs/SAMBA_RPM_BUILD_GUIDE.md) <br> 🔗 [`samba-rpm-build-rhel9` Repository](https://github.com/gennady73/samba-rpm-build-rhel9) |
