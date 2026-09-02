# Configuring External System Kerberos and Managing KDC Ticket Policies

This guide provides step-by-step procedures for configuring external (non-enrolled) systems to use your Red Hat Identity Management (IdM) Kerberos infrastructure, and details how to manage global and per-user ticket lifecycles and renewal policies on the IdM Key Distribution Center (KDC).

Official manuals for deeper reference:
*   [Red Hat Enterprise Linux 9: Accessing Identity Management services](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html-single/accessing_identity_management_services/index)
*   [Red Hat Enterprise Linux 9: Managing IdM users, groups, hosts, and access control rules](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html-single/managing_idm_users_groups_hosts_and_access_control_rules/index)

---

## 1. Configuring External (Non-Enrolled) Systems for Kerberos

In high-volume, multi-realm, or overlapping domain environments, administrators often need to authenticate against the Red Hat IdM realm from external systems (such as administrative workstations or jump boxes) without fully enrolling the system into the domain via `ipa-client-install`.

This is achieved by defining a distinct, isolated Kerberos configuration file on the external system.

### A. Prerequisites
Verify that the `krb5-workstation` package is installed on the external machine:
```bash
# dnf list installed krb5-workstation
```
If the package is missing, install it:
```bash
# dnf install krb5-workstation -y
```

### B. Setup Procedure
1.  **Copy the Configuration**: Copy the master `/etc/krb5.conf` from your primary IdM master to a dedicated, separate configuration path on the external system to prevent overwriting the host's existing authentication settings:
    ```bash
    # Run from the external system to copy IdM's krb5 configuration
    scp root@idm-master-01.linux.company.com:/etc/krb5.conf /etc/krb5_ipa.conf
    ```
2.  **Synchronize SNI / Configuration Snippets**: Copy any Kerberos configuration sub-files or snippets from the IdM master's `/etc/krb5.conf.d/` directory to the external machine's local directory structure:
    ```bash
    # Sync krb5 configuration subdirectories if populated
    rsync -avz root@idm-master-01.linux.company.com:/etc/krb5.conf.d/ /etc/krb5.conf.d/
    ```
3.  **Establish Environment Context**: Configure your active terminal session to read from the copied IdM Kerberos configuration file:
    ```bash
    $ export KRB5_CONFIG=/etc/krb5_ipa.conf
    ```
    *Note: The `KRB5_CONFIG` environment variable is session-scoped. To persist this setting across user logouts, append this export statement to the user's local shell profile (e.g., `~/.bashrc`) or configure it globally.*

### C. Active Session Operations
Once the configuration is in place, use standard MIT Kerberos tools to manage your sessions against the IdM realm:

*   **Request a Ticket-Granting Ticket (TGT)**:
    ```bash
    # Request a ticket for an IdM user (such as admin)
    $ kinit admin
    Password for admin@LINUX.COMPANY.COM:
    ```
*   **Verify Active Credentials**:
    ```bash
    # List the active tickets in your credentials cache
    $ klist
    Ticket cache: KEYRING:persistent:1000:1000
    Default principal: admin@LINUX.COMPANY.COM

    Valid starting       Expires              Service principal
    2026-09-01 08:30:00  2026-09-02 08:30:00  krbtgt/LINUX.COMPANY.COM@LINUX.COMPANY.COM
    ```
*   **Destroy Active Tickets**:
    ```bash
    # Clear the credentials cache when tasks are complete
    $ kdestroy
    ```

---

## 2. Managing Kerberos Ticket Lifecycle Policies on the IdM KDC

The Kerberos Key Distribution Center (KDC) running on your Red Hat IdM master regulates ticket access, duration, and renewal limits. Understanding and managing these policies is essential for meeting compliance standards (such as reducing session lifetimes for privileged users) and ensuring secure Single Sign-On (SSO).

### A. Ticket Policy Attributes
Each Kerberos ticket-granting ticket (TGT) has two primary lifecycle constraints:
1.  **Ticket Lifetime (`--maxlife`)**: The maximum duration a ticket remains valid for authentication before requiring a new credentials handshake (default is **24 hours / 86400 seconds**).
2.  **Maximum Renewable Age (`--maxrenew`)**: The maximum timeframe within which an active ticket can be renewed without prompting the user for their primary credentials (default is **7 days / 604800 seconds**).

In Red Hat IdM, these configurations are managed centrally in the LDAP database using `krbtpolicy` commands and enforced globally by the KDC.

---

### B. Configuring the Global Ticket Lifecycle Policy

The global ticket policy serves as the default baseline for all hosts, services, and users in the realm who do not have custom individual policies assigned.

*   **View Current Global Policy**:
    ```bash
    $ ipa krbtpolicy-show
    Max life: 86400
    Max renew: 604800
    ```
*   **Modify Global Durations**:
    To set the global maximum ticket lifetime to 8 hours (28,800 seconds) and the maximum renewal age to 24 hours (86,400 seconds):
    ```bash
    # ipa krbtpolicy-mod --maxlife=28800 --maxrenew=86400
    Max life: 28800
    Max renew: 86400
    ```
*   **Reset Global Policy to Default**:
    To discard overrides and restore the factory-default ticket lifecycle parameters:
    ```bash
    # ipa krbtpolicy-reset
    Max life: 86400
    Max renew: 604800
    ```

---

### C. Configuring Global Policies per Authentication Indicator

To support adaptive, multi-factor authentication (MFA) models, the KDC attaches **authentication indicators** to a user's TGT based on the pre-authentication mechanism used. You can configure different ticket lifecycles depending on these indicators:
*   `otp`: Two-factor authentication (LDAP Password + One-Time Password)
*   `pkinit`: Smart card, certificate, or PKINIT authentication
*   `radius`: RADIUS server authentication
*   `hardened`: Hardened password mechanisms (such as SPAKE or FAST)

For example, to enforce a shorter 4-hour (14,400 seconds) lifetime for standard OTP sessions while allowing certificate-based PKINIT sessions a longer 12-hour (43,200 seconds) lifetime:
```bash
# Configure indicator-specific ticket lifecycles globally
# ipa krbtpolicy-mod   --otp-maxlife=14400   --otp-maxrenew=14400   --pkinit-maxlife=43200   --pkinit-maxrenew=86400
```

To verify the updated indicator limits:
```bash
$ ipa krbtpolicy-show
Max life: 86400
OTP max life: 14400
PKINIT max life: 43200
Max renew: 604800
OTP max renew: 14400
PKINIT max renew: 86400
```

---

### D. Configuring Per-User Ticket Policies

For administrative or highly privileged service accounts (such as the default `admin` principal), you can establish specific ticket lifecycle policies that override all global defaults and authentication indicator policies.

*   **Configure a Custom Policy for a Specific User**:
    To restrict the `admin` principal's maximum ticket lifetime to 12 hours (43,200 seconds) and the renewal window to 2 days (172,800 seconds):
    ```bash
    # ipa krbtpolicy-mod admin --maxlife=43200 --maxrenew=172800
    Max life: 43200
    Max renew: 172800
    ```
*   **Configure Indicator-Specific Policies for a Specific User**:
    You can also combine per-user overrides with authentication indicators. For example, to allow the `admin` user to renew their ticket for 2 days *only* if they authenticate using an OTP:
    ```bash
    # ipa krbtpolicy-mod admin --otp-maxrenew=172800
    OTP max renew: 172800
    ```
*   **Show Per-User Effective Policy**:
    ```bash
    $ ipa krbtpolicy-show admin
    Max life: 43200
    Max renew: 172800
    OTP max renew: 172800
    ```
*   **Reset a User's Ticket Policy**:
    To remove individual overrides and return the user to the default global limits:
    ```bash
    # ipa krbtpolicy-reset admin
    ```

---

## 3. Best Practices & Operational Constraints

1.  **Client-Side Cache Expirations (SSSD Integration)**:
    SSSD caches user credentials to support offline logins. If you configure incredibly short ticket lifetimes (such as 1 hour), SSSD will constantly query the KDC to refresh its credentials cache. In environments with 200+ clients, this can trigger a performance bottleneck on the KDC.
2.  **Active Sessions remain Valid**:
    Disabling an account or modifying a ticket policy does not revoke tickets that have already been issued. An active TGT remains valid until its original expiration timestamp is reached. To force an immediate session termination, the administrator must either revoke the host certificate or instruct the client to run `kdestroy -A`.
3.  **Active Directory Cross-Realm Trust Lifetimes**:
    Kerberos referrals for AD trust accounts rely on the cross-realm TGT lifetime settings. Ensure that your IdM global `krbtpolicy` settings align with the AD domain's MaxServiceTicketAge group policies to prevent cross-forest authentication failures.

---

## 🔗 Official Documentation References
*   [Red Hat Enterprise Linux 9: Accessing Identity Management services](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html-single/accessing_identity_management_services/index)
*   [Red Hat Enterprise Linux 9: Managing IdM users, groups, hosts, and access control rules](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html-single/managing_idm_users_groups_hosts_and_access_control_rules/index)
*   [MIT Kerberos Documentation: kdc.conf configuration rules](https://web.mit.edu/kerberos/krb5-1.13/doc/admin/conf_files/kdc_conf.html)
