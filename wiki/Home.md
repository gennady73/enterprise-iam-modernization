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

### 📍 Step 0: Phase 0 Isolated POC Sandbox & Complex GPO Validation Gate
*   **Objective**: Prove in an isolated sandbox environment that Samba 4 AD DC ingests, serves, and enforces our enterprise's most complex Windows GPOs—specifically those governing low-level Windows developer workstations—with 100% fidelity before touching production.
*   **The Technical Concept**: 
    Deploy an isolated test Samba 4 AD DC (`BIND9_DLZ`) in a sandbox VLAN. Export production GPOs and copy the raw policy hives into Samba's `SysVol` (`/var/lib/samba/sysvol/`). Join a test Windows developer workstation and run `gpupdate /force` and `gpresult /h` to verify that all Client-Side Extensions (CSEs) execute without error (Event ID 1501).
*   **Aha! Moment (Zero Translation Required)**:
    We confirmed that Samba AD DC acts purely as an SMB3 file share and LDAP directory. It performs **zero translation** of Windows policies. The Windows client OS downloads the raw `Registry.pol` files over SMB3 and applies them locally using its own internal CSEs. Complex GPOs apply identically whether served by Windows Server or Samba AD DC.

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
*   **Implementation Guide**:
    *   Refer to the code-locked [**IdM and 389-ds Installation Guide**](https://github.com/gennady73/enterprise-iam-modernization/blob/main/docs/INSTALLATION_GUIDE.md)

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
*   **Implementation Guide**:
    *   📖 Read [**Disaster Recovery, Backups, & Replication Rebuilds**](WIKI_DISASTER_RECOVERY)

---

### 📍 Step 7: Phase 2 Active Directory Sunset & Samba 4 AD DC Migration (Plan B)
*   **Objective**: Complete the transition to a 100% open-source IAM stack by replacing Microsoft AD with Samba 4 AD DCs on Rocky Linux 9 (or deploy a standalone open-source AD domain for greenfield projects).
*   **The Technical Concept**: 
    1. **Containerized Build**: Compile Samba 4 AD DC against MIT Kerberos development headers inside a Podman container to produce clean, signed RPMs.
    2. **In-Place Replica Join**: Join Samba directly to the active forest (`samba-tool domain join`) to replicate LDAP database, user credentials, and Domain SIDs natively without client desktop profile resets.
    3. **SysVol Synchronization**: Deploy a unidirectional **rsync over SSH** wrapper run by systemd timers (`rsync -XAavz --delete`) to replicate GPOs while preserving mandatory POSIX Extended Attributes (`security.NTACL`).
    4. **PKI Auto-Enrollment**: Enable Tomcat ACME responders on IdM (Dogtag CA) and deploy `cepces` proxies for Windows machine certificate auto-enrollment without Microsoft AD CS.
*   **Implementation Guide**:
    *   🛠️ Refer to the code-locked [**Samba 4 AD DC Technical Implementation Guide**](https://github.com/gennady73/enterprise-iam-modernization/blob/main/docs/SAMBA_AD_DC_IMPLEMENTATION_GUIDE.md)

---

## Project Navigation Map

| Phase / Focus Area | Strategic Wiki Resource | Technical Repository Code-Adjacent Resource |
| :--- | :--- | :--- |
| **Phase 0: Sandbox POC** | — | 🛠️ [Samba 4 AD DC Implementation Guide](https://github.com/gennady73/enterprise-iam-modernization/blob/main/docs/SAMBA_AD_DC_IMPLEMENTATION_GUIDE.md) |
| **Phase 1: Strategy** | 📖 [Migration Strategy](WIKI_ENTERPRISE_MIGRATION) | 🛠️ [Installation Guide](https://github.com/gennady73/enterprise-iam-modernization/blob/main/docs/INSTALLATION_GUIDE.md) |
| **Phase 1: Forest Trust** | 📖 [Federation Architecture](WIKI_HYBRID_IDENTITY) | 🛠️ [Trust Management Guide](https://github.com/gennady73/enterprise-iam-modernization/blob/main/docs/HYBRID_TRUST_MANAGEMENT.md) |
| **Phase 1: Client Tuning** | 📖 [Authentication Workflows](WIKI_AUTHENTICATION_WORKFLOWS) | 🛠️ [SSSD Blueprints](https://github.com/gennady73/enterprise-iam-modernization/blob/main/docs/SSSD_TEMPLATES.md) |
| **Phase 1: Hardening** | — | 🛠️ [Kerberos & KDC Policies](https://github.com/gennady73/enterprise-iam-modernization/blob/main/docs/KERBEROS_LIFECYCLE.md) |
| **Phase 1: Resilience** | 📖 [Replication Recovery Playbook](WIKI_DISASTER_RECOVERY) | — |
| **Phase 2: AD Sunset** | — | 🛠️ [Samba 4 AD DC Implementation Guide](https://github.com/gennady73/enterprise-iam-modernization/blob/main/docs/SAMBA_AD_DC_IMPLEMENTATION_GUIDE.md) |