# Wiki: Modernized Hybrid Identity - Active Directory and Red Hat Federation

This document describes how the Red Hat build of Keycloak (RHBK) and SSSD coordinate to bridge legacy Kerberos desktop/server logins with modern federated application access during your migration from Active Directory (AD).

---

## 1. Keycloak (RHBK) in the Modernized Identity Stack

During your phased migration, Keycloak acts as the central **Identity Federation and Single Sign-On (SSO) engine**. 

Keycloak abstracts authentication, allowing you to swap underlying databases without modifying your applications:
*   **In Phase 1 (Coexistence)**: Keycloak uses its **User Storage Federation** provider to connect directly to your legacy Active Directory Domain Controllers via LDAPS. Web application users authenticate against AD credentials, but receive modern OpenID Connect (OIDC) or SAML tokens.
*   **In Phase 2 (Target)**: Once Active Directory is decommissioned, Keycloak's federation provider is simply pointed to the new standalone external Directory Server (RHDS 12 / 389-ds) or the IdM embedded LDAP. Because Keycloak abstracts this backend, your applications continue working seamlessly with zero code changes.

---

## 2. Desktop Identity Delegation: SSSD and Keycloak (Scenario 3)

For newly migrated RHEL 9 workstations and servers, we implement **SSSD-to-Keycloak Authentication Delegation**. This allows Linux console/SSH logins to leverage Keycloak's advanced authentication capabilities (such as WebAuthn/MFA, hardware keys, or external IdP federation) while preserving command-line Kerberos SSO.

### The SSSD-IdP Delegation Protocol
This modern RHEL 9 authentication flow relies on the integration of SSSD 2.7.0+ (utilizing the `sssd-idp` package) and Keycloak:

```
+----------------+       1. Local System Login Request       +------------------+
|  RHEL 9 Client | ========================================> |       SSSD       |
| (Workstation)  | <---------------------------------------- | (PAM Integration)|
+----------------+       2. Display Auth URL + Code          +------------------+
        |                                                             ||
        | 3. Access URL via Browser / Phone                           || 4. Triggers OAuth Device
        v                                                             ||    Authorization Grant
+--------------------+                                                ||    (RFC 8628)
|  Keycloak (RHBK)   | <==============================================++
| (Federation Tier)  |
+--------------------+
        |
        | 5. Authenticates User against AD/RHDS User Store
        v
+--------------------+
|  Active Directory  |
|  (Source of Truth) |
+--------------------+
```

### Protocol Steps:
1.  **User Login**: The user initiates a local terminal or SSH login on a RHEL 9 host configured with SSSD-IdP.
2.  **Device Flow Trigger**: Instead of prompting for an LDAP password, SSSD triggers the **OAuth 2.0 Device Authorization Grant flow (RFC 8628)** against Keycloak.
3.  **User Verification**: SSSD displays a verification URL and a one-time user code on the terminal screen.
4.  **Modern Authentication**: The user accesses the URL from their web browser (or mobile device), enters the code, and authenticates against Keycloak. Here, Keycloak can enforce passwordless FIDO2/WebAuthn, biometric keys, or multi-factor checks.
5.  **Kerberos Ticket Issuance**: 
    *   Once Keycloak validates the user, SSSD receives the OIDC Access Token.
    *   The RHEL 9 SSSD daemon transmits this token to the **Red Hat IdM KDC (Key Distribution Center)**.
    *   The IdM KDC validates the token and issues a native **Kerberos Ticket-Granting Ticket (TGT)** back to SSSD.
    *   Crucially, this TGT contains the **pa_type = 152** pre-authentication indicator. This informs the system that authentication was successfully delegated to Keycloak, allowing CLI utilities (like SSH or database clients) to continue leveraging passwordless Kerberos SSO natively.

---

## 3. High Availability and Server Constraints: Keycloak 26

Deploying Keycloak 26 (RHBK) in an enterprise environment requires careful planning regarding container virtualization, high-availability, and server lifecycles.

### JGroups Virtual Thread Requirements
Keycloak 26 and its underlying Quarkus runtime rely heavily on JVM virtual threads to schedule asynchronous operations. 
*   **Technical Constraint**: Your Kubernetes or OpenShift worker nodes hosting the Keycloak pods **must be allocated at least 4 physical CPU cores**. Allocating fewer cores starves the JVM fork-join pool, leading to thread contention, JGroups heartbeat timeouts, and random cluster split-brain scenarios.

### Infinispan & ProtoStream distributed Caching upgrade Rules (v26.0 to v26.6)
Keycloak utilizes Infinispan as its distributed clustering cache to sync user sessions, brute-force trackers, and authentication states. 
*   Keycloak 26.6 transitions fully to **ProtoStream-based serialization** for cluster coordination.
*   **Upgrades and Lifecycles**: During rolling updates of Keycloak pods, a cluster cannot run mixed serialization engines. Performing a standard rolling upgrade results in class serialization mismatches, cache rebalancing failures, and lock deadlocks.
*   **The Upgrade Mandate**: Upgrading a Keycloak 26 cluster (such as moving from 26.2 to 26.6) requires a **simultaneous, full cluster shutdown**. All Keycloak instances must be stopped, the upgrade applied, and the cluster restarted as a unified state to reinitialize the Infinispan caches securely.

---

## 🔗 Official Documentation References
*   [Red Hat build of Keycloak 26.6: Server Configuration Guide](https://docs.redhat.com/en/documentation/red_hat_build_of_keycloak/26.6/html-single/server_configuration_guide/index)
*   [Red Hat build of Keycloak 26.6: High Availability Guide](https://docs.redhat.com/en/documentation/red_hat_build_of_keycloak/26.6/html-single/high_availability_guide/index)
*   [Red Hat build of Keycloak Supported Configurations Matrix](https://access.redhat.com/articles/7033107)
