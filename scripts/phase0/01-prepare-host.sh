#!/usr/bin/env bash
# =============================================================================
# 01-prepare-host.sh  —  Phase 0, Step 2a: prepare the RHEL 9 VM.
#
# Sets host name, /etc/hosts, time service, firewall, SELinux mode and
# installs the samba-ad-dc RPM. Safe to re-run.
#
# Usage:  ./01-prepare-host.sh [--allow-erase]
#   --allow-erase  let dnf remove RHEL packages that conflict with samba-ad-dc
#                  (samba-client-libs, sssd-ad, ...). A domain controller VM
#                  should not run SSSD; use this on a dedicated VM only.
# =============================================================================
set -uo pipefail
. "$(dirname "$0")/lib.sh"
require_root

ALLOW_ERASE=0
[ "${1:-}" = "--allow-erase" ] && ALLOW_ERASE=1

step "1. Operating system"
grep -q 'release 9' /etc/redhat-release 2>/dev/null || die "RHEL 9 (or a rebuild) is required"
info "$(cat /etc/redhat-release)"
if command -v subscription-manager >/dev/null && ! subscription-manager status >/dev/null 2>&1; then
    info "WARNING: system not registered; dnf may not find python3-dns/python3-markdown"
fi
[ "${#DC_HOSTNAME}" -le 15 ] || die "DC_HOSTNAME longer than 15 characters"
[ "${#DOMAIN}" -le 15 ]      || die "DOMAIN longer than 15 characters"

step "2. Network identity"
ip -4 -o addr show | grep -qw "${DC_IP}" || die "${DC_IP} is not configured on any interface; set a static IP first"
hostnamectl set-hostname "${FQDN}"
sed -i "/[[:space:]]${DC_HOSTNAME}\([[:space:]]\|\.\|$\)/d" /etc/hosts
echo "${DC_IP} ${FQDN} ${DC_HOSTNAME}" >> /etc/hosts
check "host name is ${FQDN}" test "$(hostname -f 2>/dev/null || hostname)" = "${FQDN}"
check "${FQDN} resolves to ${DC_IP} locally" bash -c "getent hosts ${FQDN} | grep -qw ${DC_IP}"

step "3. Packages"
DNF_ARGS=(-y install "${SAMBA_RPM}" krb5-workstation bind-utils chrony)
[ "${ALLOW_ERASE}" = 1 ] && DNF_ARGS=(-y --allowerasing install "${SAMBA_RPM}" krb5-workstation bind-utils chrony)
[ -r "${SAMBA_RPM}" ] || die "SAMBA_RPM not found: ${SAMBA_RPM}"
if ! dnf "${DNF_ARGS[@]}"; then
    echo
    echo "dnf failed. If it reported conflicts with samba-client-libs, libwbclient,"
    echo "sssd-ad or similar, re-run with --allow-erase on this dedicated DC VM."
    exit 1
fi
check "samba-ad-dc installed" rpm -q samba-ad-dc
for svc in smb nmb winbind sssd; do
    systemctl list-unit-files "${svc}.service" >/dev/null 2>&1 && systemctl disable --now "${svc}" >/dev/null 2>&1
done

step "4. Time service (Windows clients sync from the DC)"
CHRONY=/etc/chrony.conf
if ! grep -q 'ntpsigndsocket' "${CHRONY}"; then
    cat >> "${CHRONY}" <<EOF

# --- Samba AD DC (Phase 0) ---
bindcmdaddress ${DC_IP}
allow ${DC_IP%.*}.0/24
ntpsigndsocket /var/lib/samba/ntp_signd
EOF
fi
systemctl enable --now chronyd >/dev/null 2>&1
systemctl restart chronyd
check "chronyd running" systemctl is-active chronyd

step "5. Firewall"
if systemctl is-active firewalld >/dev/null 2>&1; then
    firewall-cmd -q --permanent --add-service={dns,kerberos,kpasswd,ldap,ldaps,samba,ntp}
    firewall-cmd -q --permanent --add-port={135/tcp,3268/tcp,3269/tcp,49152-65535/tcp}
    firewall-cmd -q --reload
    check "firewall allows LDAP" bash -c "firewall-cmd --list-services | grep -qw ldap"
else
    info "firewalld not running; skipped"
fi

step "6. SELinux"
if [ "${SELINUX_MODE}" = "permissive" ] && command -v setenforce >/dev/null; then
    setenforce 0 2>/dev/null
    sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
    info "SELinux set to permissive (samba-ad-dc ships no SELinux policy module)"
fi
info "SELinux: $(getenforce 2>/dev/null || echo n/a)"

finish
