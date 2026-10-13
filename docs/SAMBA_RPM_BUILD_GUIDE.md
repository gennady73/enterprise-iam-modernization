# 📦 Custom Samba 4 AD DC RPM Builder for RHEL 9

The custom RPM build toolchain, containerized compilation scripts, and UBI 9 verification harness for Samba 4 Active Directory Domain Controllers on RHEL 9 / Rocky Linux 9 have been extracted into a standalone, dedicated GitHub repository:

👉 **[https://github.com/gennady73/samba-rpm-build-rhel9](https://github.com/gennady73/samba-rpm-build-rhel9)**

---

### Key Highlights of the Standalone Repository:
* **RHEL 9 System MIT Kerberos Build**: `./configure --with-system-mitkrb5 --with-experimental-mit-ad-dc`. Samba upstream classifies this mode as experimental and issues no security fixes for it.
* **Self-contained spec**: `rpmbuild -ba` compiles from `Source0`, installs to `/usr/lib64`, ships `samba.service` and tmpfiles, and generates its dependencies automatically. The resulting SRPM rebuilds on its own.
* **UBI 9 Container Toolchain**: `Containerfile.samba-build` and `Containerfile.samba-test`. Credentials come from a registered RHEL host or `podman build --secret`, never from `--build-arg`.
* **Runtime Test Harness**: `scripts/test-samba-rpm.sh` runs `scripts/runtime-gates.sh` in a privileged UBI 9 container: install, packaging checks, provisioning, MIT KDC, Kerberos, LDAP, SMB, DNS, GPO create/backup/restore and BIND 9.16 DLZ.
* **Conflicts with RHEL client packages**: the single `samba-ad-dc` package replaces `samba-client-libs`, `libwbclient`, `python3-samba` and related packages; it cannot be co-installed with them.

For the latest source code, build scripts, release notes, and operational guides, visit:  
🔗 **[gennady73/samba-rpm-build-rhel9](https://github.com/gennady73/samba-rpm-build-rhel9)**
