#!/usr/bin/env bash
# =============================================================================
# 02-provision-dc.sh  —  Phase 0, Step 2b: create the sandbox domain.
#
# Provisions the domain with Samba internal DNS, starts samba, points this
# host's Kerberos and resolver at the new DC and runs 03-check-dc.sh.
#
# Usage:  ./02-provision-dc.sh            (prompts for the Administrator password)
#         ADMINPASS=... ./02-provision-dc.sh
# Refuses to run if a domain already exists; remove /var/lib/samba/private
# and /etc/samba/smb.conf yourself to start over.
# =============================================================================
set -uo pipefail
. "$(dirname "$0")/lib.sh"
require_root

step "1. Pre-checks"
[ -e /var/lib/samba/private/sam.ldb ] && die "a domain is already provisioned on this host"
command -v samba-tool >/dev/null || die "samba-tool not found; run 01-prepare-host.sh first"
if [ -z "${ADMINPASS:-}" ]; then
    read -rsp "New ${DOMAIN}\\Administrator password: " ADMINPASS; echo
    read -rsp "Repeat: " P2; echo
    [ "${ADMINPASS}" = "${P2}" ] || die "passwords differ"
fi
info "Password needs 8+ characters with upper, lower, digit and symbol."

step "2. Provision ${REALM}"
ts="$(date +%Y%m%d%H%M%S)"
[ -e /etc/samba/smb.conf ] && mv /etc/samba/smb.conf "/etc/samba/smb.conf.pre-phase0.${ts}"
[ -e /etc/krb5.conf ] && cp -p /etc/krb5.conf "/etc/krb5.conf.pre-phase0.${ts}"
# DC_IP must be listed first: with the MIT KDC, kpasswd (464) binds only the
# first interface, and Windows password changes go to the DC IP.
samba-tool domain provision \
    --server-role=dc --use-rfc2307 \
    --dns-backend=SAMBA_INTERNAL \
    --realm="${REALM}" --domain="${DOMAIN}" \
    --host-name="${DC_HOSTNAME}" --host-ip="${DC_IP}" \
    --option="interfaces = ${DC_IP} lo" \
    --option="bind interfaces only = yes" \
    --option="dns forwarder = ${DNS_FORWARDER}" \
    --adminpass="${ADMINPASS}" || die "provisioning failed"
cp /var/lib/samba/private/krb5.conf /etc/krb5.conf
cp /etc/samba/smb.conf "${PHASE0_DIR}/smb.conf.provisioned"
info "Generated /etc/samba/smb.conf (copy: ${PHASE0_DIR}/smb.conf.provisioned):"
sed 's/^/         /' /etc/samba/smb.conf
if [ -d /var/lib/samba/ntp_signd ] && getent group chrony >/dev/null; then
    chgrp chrony /var/lib/samba/ntp_signd && chmod 0750 /var/lib/samba/ntp_signd
fi

step "3. Start samba"
if [ -d /run/systemd/system ]; then
    systemctl enable --now samba || die "systemctl start samba failed; see journalctl -u samba"
else
    /usr/sbin/samba -D       # no systemd (container test)
fi
for _ in $(seq 1 45); do (exec 3<>"/dev/tcp/${DC_IP}/389") 2>/dev/null && break; sleep 2; done

step "4. Resolver -> this DC"
if command -v nmcli >/dev/null && nmcli -t general status >/dev/null 2>&1; then
    CON="$(nmcli -g GENERAL.CONNECTION device show "$(ip -4 -o addr show | awk -v ip="${DC_IP}" '$4 ~ "^"ip"/" {print $2; exit}')")"
    nmcli con mod "${CON}" ipv4.dns "${DC_IP}" ipv4.dns-search "${DNSDOMAIN}" ipv4.ignore-auto-dns yes
    nmcli con up "${CON}" >/dev/null
    info "NetworkManager connection '${CON}' now uses ${DC_IP}"
else
    printf 'search %s\nnameserver %s\n' "${DNSDOMAIN}" "${DC_IP}" > /etc/resolv.conf
fi

echo "${ADMINPASS}" | kinit "administrator@${REALM}" >/dev/null || die "kinit failed"
export ADMINPASS
"$(dirname "$0")/03-check-dc.sh"
