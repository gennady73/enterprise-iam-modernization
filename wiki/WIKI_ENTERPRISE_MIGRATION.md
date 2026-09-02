# Wiki: Enterprise Identity Migration - Active Directory to Red Hat IdM

This document details the architectural analysis, trade-offs, and design patterns associated with migrating an enterprise-level identity database from Microsoft Active Directory (AD) to Red Hat Identity Management (IdM).

---

## 1. Architectural Evolution: Moving Away from Synchronization

In previous integration paradigms (e.g., RHEL 6 and 7), administrators commonly integrated Linux clients with Active Directory using **database-level synchronization**. In this model, accounts were actively replicated between AD and a Linux LDAP directory server using tools like the 389 Directory Server's **Windows Synchronization (WinSync)** plugin.

### The Failure of the Synchronization Model
WinSync was deprecated in RHEL 8 and has been completely removed in RHEL 9. Enterprise environments moved away from active account synchronization due to four severe architectural liabilities:

1.  **LSA Notification Package Vulnerabilities (PassSync)**: Because Active Directory does not store cleartext passwords, password synchronization required installing a custom LSA (Local Security Authority) notification package—**Password Sync (PassSync)**—on *every single Active Directory Domain Controller*. If the PassSync DLL experienced a memory leak or conflicted with a Windows security patch, it could crash the Windows LSASS process, causing the Domain Controller to experience a Blue Screen of Death (BSOD) or halt authentications.
2.  **Replication Lag & Account Lockout Storms**: A password change made on Windows is not immediately present on the Linux directory server. During this replication window, automated service scripts or logged-in user clients on Linux will attempt authentication with legacy credentials, frequently triggering security lockouts in AD.
3.  **Divergent Attributes & Attribute Duplication**: Synchronizing accounts creates two distinct directory entries (one in AD, one in LDAP). These duplicates frequently experience attribute drift, inconsistent group nesting, and naming collisions.
4.  **POSIX Attribute Collision**: Standard Active Directory schemas do not natively allocate Linux POSIX attributes (such as UIDs, GIDs, or home directory paths). Synchronizing users into a separate directory forces administrators to manage complex, fragile dynamic translation tables.

### The Modern Standard: Cross-Forest trusts
Rather than copying databases, RHEL 9 standardizes on **Cross-Forest trusts** utilizing Kerberos realm trusts. The Linux directory (Red Hat IdM) establishes a secure, cryptographically validated trust relationship directly with Active Directory. SSSD (System Security Services Daemon) on the Linux clients dynamically resolves AD SIDs on the fly, keeping Active Directory as the absolute, single source of truth for passwords, with zero data duplication.

---

## 2. Strategic Comparison: Direct AD Join vs. Cross-Forest Trust

For mixed Linux and Windows environments, administrators typically choose between two non-synchronization pathways:

| Criteria | Direct AD Join (SSSD + `realmd`) | Cross-Forest Trust (RHEL IdM + AD) |
|:--- |:--- |:--- |
| **Directory Server Footprint** | None (Linux clients talk directly to AD). | Linux-native Directory Server (IdM) must be maintained. |
| **Target Infrastructure Scale** | Excellent for small, Linux-only server pools. | Ideal for enterprise environments with workstations and servers. |
| **Linux Client Identity Management** | Limited. Linux settings are managed client-by-client. | Centralized. Central SSH keys, Sudoers, and HBAC rules are managed in IdM. |
| **Sudo and Access Policies** | Configured locally on every server (or pushed via Ansible). | Configured once in IdM LDAP and enforced globally on all hosts. |
| **User Experience (SSO)** | Direct Kerberos authentication against AD KDC. | SSSD handles referrals from IdM KDC to AD KDC. |

---

## 3. The Target Decoupled State

When deploying Red Hat IdM, your architecture utilizes two distinct directory tiers. Understanding their boundaries is critical for stability and scaling:

```
                      +---------------------------------------+
                      |         Active Directory (AD)         |  <--- Absolute Source of Truth
                      |      (User Passwords & SIDs)          |
                      +---------------------------------------+
                                          ^
                                          | One-Way Cross-Realm Trust
                                          v
+------------------+         +--------------------------------+
| Keycloak (RHBK)  |  OIDC   |          Red Hat IdM           |  <--- System/OS-level Authentication
| (Federation Tier)| <=====> | (Embedded 389-ds / IdM KDC)    |       (Resolves SIDs dynamically via Trust)
+------------------+         +--------------------------------+
         ^                                    ^
         |                                    | System Policy Configuration
         | Federated LDAP Query               v
+------------------+         +--------------------------------+
| Standalone RHDS  |         |      Ansible Automation        |  <--- System and GPO Management
| (App User Store) |         | (Replaces Windows GPO Policies)|       (Continuous baseline enforcement)
+------------------+         +--------------------------------+
```

### The System Tier: Embedded 389-ds (within Red Hat IdM)
*   **Purpose**: Dedicated exclusively to system-level infrastructure access (SSH, workstation console logins, Sudo rules, automount fileshare maps, and certificate management).
*   **Management Policy**: Completely abstracted and managed by Red Hat's native utilities. Schema modifications, custom index configurations, or importing raw third-party application data into this embedded directory is strongly discouraged, as it can destabilize OS-level logins.

### The Application Tier: Standalone External RHDS (or upstream 389-ds)
*   **Purpose**: Serves as a high-performance, general-purpose LDAP user store for web applications, SaaS, and custom software.
*   **Why Decouple?** High-frequency application writes, JIT user provisioning from Keycloak, and complex database queries from developer APIs are absorbed entirely by the standalone RHDS mesh. This prevents application-level query surges from exhausting the IdM thread pool, ensuring that system administrators can always log in and establish SSH sessions even during application-level traffic spikes.

---

## 🔗 Official Documentation References
*   [Red Hat Enterprise Linux 9: Migrating to Identity Management](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html-single/migrating_to_identity_management_on_rhel_9/index)
*   [Red Hat Enterprise Linux 9: Planning Identity Management](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html-single/planning_identity_management/index)
*   [Red Hat Directory Server 12: Planning and Designing](https://docs.redhat.com/en/documentation/red_hat_directory_server/12/html-single/planning_and_designing_directory_server/index)
