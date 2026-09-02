# Wiki: Active Directory and Red Hat IdM Authentication Workflows

This document details the exact technical transaction logs, Kerberos KDC handshakes, and directory query protocols that execute when domain user `user123` authenticates across different client systems.

---

## 1. Core Directory Integration Principles

Before reviewing individual transaction logs, it is critical to outline how identities are resolved across security boundaries:
*   **The Single Source of Truth**: Active Directory (AD) stores `user123`’s profile, password hash, AD group memberships, and Security Identifier (SID).
*   **Zero Account Duplication**: Red Hat IdM stores **no credentials or database objects** for `user123`.
*   **SSSD SID-to-POSIX Mapping**: When a RHEL 9 system receives an authentication request for an AD domain user (e.g., `user123@ad.company.com`), the local **System Security Services Daemon (SSSD)** uses deterministic hashing to map the user's AD SID to a virtual POSIX UID and GID on the fly. This ensures that `user123` has the exact same UID across all Linux systems without needing a synchronized database.
*   **The Kerberos KDC Referral Process**: Because RHEL 9 systems trust the Red Hat IdM Kerberos KDC, and the IdM KDC maintains a cross-forest realm trust with AD, the IdM KDC can issue Kerberos referrals redirecting authentication queries directly to AD KDCs.

---

## 2. Technical Transaction Flows

---

### 1.1 The Linux Workstation (RHEL 9 Desktop Client)

#### Scenario A: SSH Login (`ssh user123@linux-workstation.linux.company.com`)
1.  **Workstation SSHD**: Listens on port 22. When `user123@ad.company.com` attempts an SSH connection, PAM delegates the request to **SSSD** on the workstation.
2.  **SSSD Lookup**: SSSD contacts the local **Red Hat IdM Master** over LDAP to resolve the username.
3.  **Cross-Forest Query**: The IdM Master uses the established trust link to query an **Active Directory Domain Controller** (via Global Catalog port 3268) in real-time, retrieving the user's AD SID and group memberships.
4.  **SSSD Mapping**: SSSD receives this metadata and deterministic hashes the AD SID into Linux POSIX values (e.g., UID `105260123`, GID `105260001`).
5.  **Kerberos Auth Request**: SSSD requests a Kerberos Ticket-Granting Ticket (TGT) for `user123@ad.company.com` from the **IdM Kerberos KDC (port 88)**.
6.  **KDC Referral**: The IdM KDC does not store AD passwords. It recognizes the realm `AD.COMPANY.COM` as trusted, and returns a **Kerberos Referral Ticket** to the workstation client.
7.  **Direct AD Handshake**: SSSD follows the referral and connects directly to the **AD KDC** on a Windows Domain Controller. SSSD presents the user's password.
8.  **TGT Issuance**: The AD KDC validates the credentials, generates a native AD TGT, and returns it to SSSD. SSSD caches this ticket in the client's local Kerberos credential cache (`ccache`), granting SSH access.

#### Scenario B: UI Login (GNOME / GDM Graphical Console)
1.  **GDM Display Manager**: Prompts for credentials. The user types `user123@ad.company.com` and password.
2.  **PAM / SSSD Flow**: Follows the identical **KDC Referral** protocol described in the SSH flow above:
    *   SSSD queries IdM Master to dynamically map POSIX attributes.
    *   Workstation talks to IdM KDC, receives AD referral.
    *   Workstation connects directly to AD KDC, verifies password, and receives AD Kerberos TGT.
3.  **Local Session Initialization**: PAM mounts the local desktop home directory, reads the local GDM configurations, and starts the GNOME desktop session with a valid AD Kerberos TGT cached locally.

#### Scenario C: Web Browser (Accessing a Keycloak-Secured Portal)
1.  **App Redirect**: The user opens Firefox and accesses an internal corporate web portal. The portal redirects the browser to Keycloak (RHBK) for authentication.
2.  **SPNEGO Negotiation**: Keycloak responds with a `WWW-Authenticate: Negotiate` header, requesting Kerberos authentication (SPNEGO).
3.  **Browser Kerberos Ticket Request**: The browser sees the negotiation request, reads the user's locally cached AD Kerberos TGT, and requests an HTTP service ticket for Keycloak (e.g., `HTTP/keycloak.linux.company.com`) from the **AD KDC**.
4.  **Silent SSO Auth**: The browser transmits this service ticket to Keycloak inside the HTTP request headers.
5.  **Validation**: Keycloak validates the Kerberos ticket against the AD/IdM trust endpoints. Once validated, Keycloak logs the user in silently, generating OIDC tokens with zero password prompt.

---

### 1.2 The Linux Server (RHEL 9 Headless Server)

#### Scenario A: SSH Login (`ssh user123@rhel-server.linux.company.com`)
1.  **Target Server SSHD**: Calls SSSD to validate the SSH login attempt.
2.  **Referral Handshake**: Follows the exact **Cross-Forest KDC Referral** protocol:
    *   Server SSSD queries the IdM master to fetch POSIX attributes in real-time.
    *   KDC referral redirects the authentication query directly to the Active Directory Domain Controllers.
3.  **Group / Sudo Resolution**: SSSD fetches the user's AD group SIDs. SSSD checks these groups against IdM's centralized **Host-Based Access Control (HBAC)** and **Sudo Rules** cached locally.
4.  **Access Granted**: SSSD confirms `user123` has sudo privileges, creates the login session, and caches the Kerberos TGT.

---

### 2.1 The Windows Workstation (Windows Client OS)

#### Scenario A: CLI (PowerShell / Command Prompt)
1.  **Local Execution**: The user opens PowerShell on a domain-joined Windows workstation.
2.  **Native Windows Handshake**: Commands are executed within the local Windows Security Support Provider Interface (SSPI). 
3.  **Kerberos Execution**: Windows OS talks directly to the local **AD Domain Controller (AD KDC)** to request native Active Directory Kerberos tickets. Red Hat IdM is completely bypassed.

#### Scenario B: UI Login (Windows Desktop Console)
1.  **Ctrl+Alt+Del Console**: The user logs in with `user123` and password.
2.  **AD DC Query**: The workstation's Local Security Authority Subsystem Service (LSASS) communicates directly with a local **AD Domain Controller**.
3.  **TGT & GPO Execution**: AD validates the password, issues an AD TGT, and triggers Windows GPO enforcement (such as mounting DFS file shares, and mapping local administrative groups). No Linux servers are contacted.

#### Scenario C: Web Browser (Accessing Keycloak-Secured Portal)
1.  **OIDC Redirect**: Browser redirects to Keycloak.
2.  **Integrated Windows Auth**: Keycloak requests `Negotiate` (SPNEGO).
3.  **Ticket Exchange**: The Windows browser grabs the locally cached AD TGT, requests a service ticket for Keycloak from AD, and transmits it to Keycloak.
4.  **SSO Login**: Keycloak validates the ticket and grants instant access.

---

### 2.2 The Windows Server (Windows Server OS)

#### Scenario A: CLI
1.  **Execution**: System script or scheduled task runs locally on a Windows Server.
2.  **AD DC Query**: Authenticates natively using direct Kerberos handshakes against the AD Domain Controller KDC.

#### Scenario B: UI (Remote Desktop / Console)
1.  **RDP Connection**: Administrator initiates a Remote Desktop (RDP) session to a Windows Server.
2.  **LSASS Validation**: The target Windows Server delegates authentication directly to the AD Domain Controller. 
3.  **Login Completed**: The AD DC issues session tickets, verifies access rights, and the desktop session initializes entirely within the Active Directory domain boundary.

---

## 🔗 Official Documentation References
*   [Red Hat Enterprise Linux 9: Configuring Authentication and Authorization](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html-single/configuring_authentication_and_authorization_in_rhel/index)
*   [Red Hat Enterprise Linux 9: Integrating RHEL with Windows Active Directory](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html-single/integrating_rhel_systems_directly_with_windows_active_directory/index)
*   [Red Hat Enterprise Linux 9: Managing IdM Users and Access Control Rules](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html-single/managing_idm_users_groups_hosts_and_access_control_rules/index)
