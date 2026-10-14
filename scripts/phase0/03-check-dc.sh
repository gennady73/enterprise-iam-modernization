#!/usr/bin/env bash
# =============================================================================
# 03-check-dc.sh  —  Phase 0 health gate. All checks must pass before
# joining workstations or importing GPOs. Read-only; safe to re-run.
# =============================================================================
set -uo pipefail
. "$(dirname "$0")/lib.sh"
require_root
ensure_ticket

srv() {   # srv <name> : SRV lookup through the system resolver
    python3 -c "import dns.resolver,sys; dns.resolver.resolve(sys.argv[1], 'SRV')" "$1"
}

step "smb.conf"
CONF=/etc/samba/smb.conf
check "testparm loads ${CONF} without errors" testparm -s --suppress-prompt "${CONF}"
check "server role is active directory domain controller" \
    bash -c "testparm -s --parameter-name='server role' ${CONF} 2>/dev/null | grep -qi 'active directory domain controller'"
check "realm = ${REALM}" bash -c "testparm -s --parameter-name=realm ${CONF} 2>/dev/null | grep -qix '${REALM}'"
check "${DC_IP} is the first interface (kpasswd/464)" \
    bash -c "testparm -s --parameter-name=interfaces ${CONF} 2>/dev/null | awk '{print \$1}' | grep -qx '${DC_IP}'"
# Member-server settings break a DC. Report any that were added by hand.
BAD="$(grep -inE '^[[:space:]]*(security|passdb backend|idmap config|winbind (use default domain|enum users|enum groups|refresh tickets)|kerberos method|dedicated keytab file)[[:space:]]*=' "${CONF}")"
[ -z "${BAD}" ] || info "member-server lines found: ${BAD}"
check "no member-server settings in ${CONF}" test -z "${BAD}"
check "[sysvol] and [netlogon] shares defined" bash -c "grep -q '^\[sysvol\]' ${CONF} && grep -q '^\[netlogon\]' ${CONF}"

step "Services"
check "samba running"               pgrep -x samba
check "MIT krb5kdc running"         pgrep -x krb5kdc
for p in 53 88 135 389 445 464 636 3268; do
    check "TCP ${p} open on ${DC_IP}" bash -c "exec 3<>/dev/tcp/${DC_IP}/${p}"
done

step "DNS (via this host's resolver)"
check "${FQDN} -> ${DC_IP}"                bash -c "getent ahostsv4 ${FQDN} | grep -qw ${DC_IP}"
check "_ldap._tcp.dc._msdcs SRV"           srv "_ldap._tcp.dc._msdcs.${DNSDOMAIN}"
check "_kerberos._tcp SRV"                 srv "_kerberos._tcp.${DNSDOMAIN}"
check "_gc._tcp SRV"                       srv "_gc._tcp.${DNSDOMAIN}"

step "Kerberos, LDAP, SMB"
check "valid Kerberos ticket"              klist -s
check "LDAP over Kerberos"                 samba-tool user show Administrator -H "${LDAP_URL}" ${KRB}
check "SMB sysvol share"                   bash -c "smbclient //${FQDN}/sysvol ${KRB} -c 'ls ${DNSDOMAIN}/Policies/*' | grep -q 31B2F340"
check "SMB netlogon share"                 smbclient "//${FQDN}/netlogon" ${KRB} -c 'ls'

step "Directory and SysVol health"
check "dbcheck --cross-ncs (0 errors)"     samba-tool dbcheck --cross-ncs
check "ntacl sysvolcheck"                  samba-tool ntacl sysvolcheck
check "Default Domain Policy present"      bash -c "samba-tool gpo listall -H ${LDAP_URL} ${KRB} | grep -q 'Default Domain Policy'"

finish
