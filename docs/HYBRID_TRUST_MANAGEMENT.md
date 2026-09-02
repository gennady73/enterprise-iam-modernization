# Hybrid Identity Management via Active Directory and IdM Trust

This document outlines the administrative procedures for configuring the Cross-Forest Trust, executing the final Active Directory sunset, and replacing Windows Group Policy Objects (GPOs) with Linux-native Ansible automation.

Official manuals for deeper reference:
*   [Red Hat Enterprise Linux 9: Installing Trust Between IdM and AD](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html-single/installing_trust_between_idm_and_ad/index)
*   [Red Hat Enterprise Linux 9: Using Ansible to Install and Manage IdM](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html-single/using_ansible_to_install_and_manage_identity_management/index)

---

## 1. Setting Up the Cross-Forest Trust (Phase 1)

Establishing a Cross-Forest Trust allows Red Hat IdM to delegate password checks to Active Directory natively.

### A. Network & Port Requirements
Ensure the following ports are open between the AD Domain Controllers and your Red Hat IdM Masters:
*   **Kerberos (TCP/UDP 88, TCP 464)**
*   **LDAP (TCP 389)**
*   **DNS (TCP/UDP 53)**
*   **DCE RPC end-point mapper (TCP 135)**: Strictly required during trust establishment.
*   *Security Note*: NetBIOS ports 138 (NetBIOS-DGM) and 139 (NetBIOS-SSN) are not required and should remain blocked.

### B. Command-Line Sequence on Red Hat IdM Master
Execute these administrative commands on the primary IdM server to configure DNS, prepare Kerberos, and create the trust:

1.  **Configure DNS Forwarding**: Ensure IdM can resolve the AD domain.
    ```bash
    # Configure DNS forwarding on the IdM DNS server targeting AD DCs
    ipa dnsforwardzone-add ad.company.com --forwarder=192.168.10.10 --forwarder=192.168.10.11 --forward-policy=only
    ```
2.  **Prepare the IdM Master for Trust**: Install Samba and promote the IdM server to a Trust Controller:
    ```bash
    # Install Samba and trust packages
    dnf install ipa-server-trust-ad samba-client -y
    # Authenticate as IdM admin
    kinit admin
    # Run the trust configuration utility
    ipa-adtrust-install --add-sids
    ```
3.  **Lock down Samba RPC Port Allocation**: Restrict Samba's dynamic RPC port allocation to a defined range for strict firewall compliance:
    ```bash
    net conf setparm global 'rpc server dynamic port range' 55000-65000
    firewall-cmd --add-port=55000-65000/tcp --permanent
    firewall-cmd --reload
    ipactl restart
    ```
4.  **Establish the One-Way Trust**: Create the trust relationship from IdM to AD, specifying dynamic POSIX range allocation:
    ```bash
    # Create the trust with AD, authenticating as an AD Enterprise or Domain Admin
    ipa trust-add --type=ad "ad.company.com" --admin "Administrator" --password --range-type=ipa-ad-trust-posix
    ```

---

## 2. Replacing AD GPOs with Ansible

Because RHEL 9 clients cannot execute Windows GPOs, we use **Ansible** (which is already available in your environment) to enforce system configurations, apply security baselines, and manage local access controls.

Here is how AD GPO configurations are mapped to their Linux-native equivalents:

### 1. Security Hardening (AD GPO Security Baselines)
*   **Linux Equivalent**: **OpenSCAP** profiles (e.g., CIS or DISA STIG baselines) applied continuously via Ansible's `redhat.rhel_system_roles.security_hardening` role.

### 2. Software Installation (Pushed MSI packages)
*   **Linux Equivalent**: Ansible Playbooks utilizing the `dnf` module to deploy enterprise software and schedule cron-based package updates.

### 3. Mounting Network Shares (GPO Drive Mapping)
*   **Linux Equivalent**: **Autofs maps** managed centrally in IdM. SSSD automatically retrieves these maps, mounting enterprise NFS or SMB fileshares dynamically when a user logs in.

### 4. Local Administrator Rights (AD Restricted Groups)
*   **Linux Equivalent**: Centralized **IdM Sudo Rules** and **Host-Based Access Control (HBAC)**.

---

## 3. Automation Code Templates

Below are the production-ready Ansible playbooks to automate client deployment and trust setup:

### Playbook 1: Deploy AD Trust via Ansible (`playbooks/deploy-ad-trust.yml`)
Instead of manual CLI commands, automate the AD trust configuration across your IdM masters using the native `ipatrust` role:

```yaml
---
- name: Deploy Cross-Forest Active Directory Trust
  hosts: idm_masters
  become: true
  vars_files:
    - /home/user_name/MyPlaybooks/secret.yml # Stores your admin passwords securely
  tasks:
    - name: Ensure AD Trust is established in IdM
      freeipa.ansible_freeipa.ipatrust:
        ipaadmin_password: "{{ ipaadmin_password }}"
        realm: ad.company.com
        admin: Administrator
        password: "{{ ad_admin_password }}"
        range_type: ipa-ad-trust-posix
        state: present
```

### Playbook 2: Automated Client Enrollment (`playbooks/enroll-idm-client.yml`)
This playbook automates enrolling a newly migrated RHEL 9 server or workstation into the Red Hat IdM realm:

```yaml
---
- name: Enroll RHEL 9 Host into Red Hat IdM Domain
  hosts: rhel_clients
  become: true
  vars:
    ipa_domain: linux.company.com
    ipa_realm: LINUX.COMPANY.COM
    ipa_server: idm-master.linux.company.com
    ipa_admin_user: admin
    ipa_admin_password: "SecureAdminPasswordSecure" # Use Ansible Vault in production
  
  tasks:
    - name: Ensure firewalld permits IdM services
      ansible.builtin.firewalld:
        service: "{{ item }}"
        state: enabled
        permanent: true
        immediate: true
      loop:
        - freeipa-client
        - ldap
        - ldaps

    - name: Run FreeIPA Client Enrollment
      ansible.builtin.import_role:
        name: freeipa.ansible_freeipa.ipaclient
      vars:
        state: present
        domain: "{{ ipa_domain }}"
        realm: "{{ ipa_realm }}"
        servers:
          - "{{ ipa_server }}"
        principal: "{{ ipa_admin_user }}"
        password: "{{ ipa_admin_password }}"
        mkhomedir: true
        sssd: true
```

### Playbook 3: Sudo & Local Admin Management (`playbooks/enforce-sudoers.yml`)
This playbook configures standard sudo permissions, replacing GPO "Restricted Group" policies:

```yaml
---
- name: Enforce Local Sudoers and Admin Access Control
  hosts: rhel_clients
  become: true
  tasks:
    - name: Ensure sssd-idp is installed for delegated federated authentication
      ansible.builtin.dnf:
        name: sssd-idp
        state: present

    - name: Enforce standardized sudo rule file for enterprise system administrators
      ansible.builtin.copy:
        dest: /etc/sudoers.d/enterprise-admins
        content: |
          # Managed by Ansible. Hand-off local administrative rights.
          # Allow members of the centralized IdM Linux-Admins group full root access
          %linux-admins@linux.company.com ALL=(ALL) ALL
        owner: root
        group: root
        mode: '0440'
        validate: '/usr/sbin/visudo -cf %s'
```

### Playbook 4: Security Hardening & GPO Enforcement (`playbooks/enforce-scap-hardening.yml`)
This playbook replaces Windows baseline GPOs by installing OpenSCAP, the SCAP Security Guide, and continuously remediating host drift against the CIS benchmark:

```yaml
---
- name: Enforce OpenSCAP Compliance and Security Hardening
  hosts: rhel_clients
  become: true
  vars:
    # Target profile: CIS Red Hat Enterprise Linux 9 Benchmark for Level 1 Workstation/Server
    scap_profile: xccdf_org.ssgproject.content_profile_cis
    scap_data_stream: /usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml
    scap_report_dir: /var/log/openscap
    scap_report_name: "{{ inventory_hostname }}-cis-report.html"

  tasks:
    - name: Ensure OpenSCAP scanner and security guides are installed
      ansible.builtin.dnf:
        name:
          - openscap-scanner
          - scap-security-guide
        state: present

    - name: Create directory for security scan reports
      ansible.builtin.file:
        path: "{{ scap_report_dir }}"
        state: directory
        owner: root
        group: root
        mode: '0750'

    - name: Run OpenSCAP remediation and generate compliance report
      ansible.builtin.command: >
        oscap xccdf eval
        --remediate
        --profile {{ scap_profile }}
        --report {{ scap_report_dir }}/{{ scap_report_name }}
        {{ scap_data_stream }}
      register: oscap_scan
      # oscap returns rc 0 if compliant, rc 2 if non-compliant rules were found and remediated.
      failed_when: oscap_scan.rc not in [0, 2]
      changed_when: oscap_scan.rc == 2

    - name: Print SCAP evaluation summary
      ansible.builtin.debug:
        msg: "Compliance scan completed. The HTML report is available at {{ scap_report_dir }}/{{ scap_report_name }}"
```

---

## 4. Trust Monitoring & Drift Auditing

To support the "Distributed Validation & Drift Auditing" tier, utilize the built-in **`ipa-healthcheck`** tool to monitor the health of your cross-forest AD trust.

1.  **Install the Healthcheck packages**:
    ```bash
    dnf install ipa-healthcheck -y
    ```
2.  **Execute Standalone Trust Screening**: Run a targeted check focused strictly on SSSD trust configurations, domain status, active DCs, and SID mapper plugins:
    ```bash
    ipa-healthcheck --source=ipahealthcheck.ipa.trust --failures-only
    ```
    *   **Healthy Output**: The tool will return empty brackets **`[]`** on a fully functioning, compliant system.
    *   **Failed Checks**: It will flag issues such as inactive DCs, missing SID gen plugins, or incorrect `ipa_server_mode` settings in `/etc/sssd/sssd.conf`.

---

## 5. Decommissioning Active Directory (Phase 2)

Once all Windows clients have been successfully converted to Linux, you can completely dismantle the legacy Microsoft stack with **zero technical debt** or remnant configuration files:

1.  **Migrate Final Admins**: Move any remaining administrative or service accounts currently housed in AD directly into Red Hat IdM.
2.  **Remove the Trust**: Execute this command on your primary IdM server to tear down the trust relationship:
    ```bash
    # Terminate the cross-forest trust
    ipa trust-del ad.company.com
    ```
3.  **Remove associated ID Ranges**: Remove the mapped UID/GID range allocated for AD domain users to clean up SSSD's state:
    ```bash
    ipa idrange-del AD.COMPANY.COM_id_range
    systemctl restart sssd
    ```
4.  **Shut Down DNS Zones**: Delete any forward zones pointing to the AD DNS servers.
    ```bash
    # Remove the DNS forward zone
    ipa dnsforwardzone-del ad.company.com
    ```
5.  **Power Down AD**: Safely power down and decommission your Microsoft Active Directory Domain Controllers. 

Because you chose a Cross-Forest Trust model rather than active user synchronization (WinSync), there are no stale synchronization databases to clean up, no residual user metadata tables, and no remnant local DLLs. Your RHEL 9 hosts are left in a pure, lightweight, optimized Linux-native state.

---

## 🔗 Official Documentation References
*   [Red Hat Enterprise Linux 9: Installing Trust Between IdM and AD](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html-single/installing_trust_between_idm_and_ad/index)
*   [Red Hat Enterprise Linux 9: Using Ansible to Install and Manage IdM](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html-single/using_ansible_to_install_and_manage_identity_management/index)
*   [Red Hat Enterprise Linux 9: Using IdM Healthcheck to Monitor your IdM Environment](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html-single/using_idm_healthcheck_to_monitor_your_idm_environment/index)
