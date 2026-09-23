# 📦 Custom Samba 4 AD DC RPM Builder for RHEL 9

The custom RPM build toolchain, containerized compilation scripts, and UBI 9 verification harness for Samba 4 Active Directory Domain Controllers on RHEL 9 / Rocky Linux 9 have been extracted into a standalone, dedicated GitHub repository:

👉 **[https://github.com/gennady73/samba-rpm-build-rhel9](https://github.com/gennady73/samba-rpm-build-rhel9)**

---

### Key Highlights of the Standalone Repository:
* **RHEL 9 System MIT Kerberos Integration**: Complete build configurations (`./configure --with-system-mitkrb5 --with-experimental-mit-ad-dc`) tailored specifically for Red Hat Enterprise Linux 9 and derivatives.
* **Pre-Built RPM Binaries**: Includes pre-compiled `samba-ad-dc-4.24.7-1.el9.x86_64.rpm` under the `/rpm` directory for instant testing and evaluation.
* **UBI 9 Container Toolchain**: Clean build and test containers (`Containerfile.samba-build` & `Containerfile.samba-test`) supporting Red Hat Subscription Manager (`--build-arg RH_USER` / `--build-arg RH_PASS`).
* **Automated Smoke Test Harness**: `scripts/test-samba-rpm.sh` featuring GNU-style `--argname=value` CLI options, built-in `--help`, and container isolation bypass flags (`--privileged --tmpfs /var/lib/samba`) for zero-panic domain provisioning.

For the latest source code, build scripts, release notes, and operational guides, visit:  
🔗 **[gennady73/samba-rpm-build-rhel9](https://github.com/gennady73/samba-rpm-build-rhel9)**
