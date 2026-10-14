#!/usr/bin/env bash
# =============================================================================
# 06-map-principals.sh  —  Phase 0, Step 3b: users, groups and SID mapping.
#
# Reads principals.csv (see principals.csv.example). For each row it creates
# the user or group in the new domain (if missing) and adds members. Rows
# with a source_sid also rewrite that source-domain SID, wherever it appears
# in imported GPO files (security settings, preferences), to the new
# principal's SID, and raise the version of each GPO it changed: the same
# job a GPMC migration table does. Safe to re-run.
#
# Usage:  ./06-map-principals.sh [principals.csv]
# Exit code: failed checks; unmapped source-domain SIDs count as a failure.
# =============================================================================
set -uo pipefail
. "$(dirname "$0")/lib.sh"
require_root
ensure_ticket

CSV="${1:-${PHASE0_DIR}/principals.csv}"
[ -r "${CSV}" ] || die "${CSV} not found (copy principals.csv.example)"
H=(-H "${LDAP_URL}" ${KRB})
MAP="$(mktemp)"; trap 'rm -f "${MAP}"' EXIT

sid_of() { python3 - "$1" "${LDAP_URL}" <<'EOF'
import sys
from samba import param
from samba.auth import system_session
from samba.credentials import Credentials, MUST_USE_KERBEROS
from samba.samdb import SamDB
from samba.dcerpc import security
from samba.ndr import ndr_unpack
lp = param.LoadParm(); lp.load_default()
c = Credentials(); c.guess(lp); c.set_kerberos_state(MUST_USE_KERBEROS)
db = SamDB(url=sys.argv[2], session_info=system_session(), credentials=c, lp=lp)
r = db.search(base=db.domain_dn(), expression='(sAMAccountName=%s)' % sys.argv[1], attrs=['objectSid'])
print(ndr_unpack(security.dom_sid, r[0]['objectSid'][0]) if len(r) == 1 else '')
EOF
}

step "1. Users and groups from ${CSV}"
# kind,name,source_sid,members,password
while IFS=, read -r kind name source_sid members password; do
    kind="${kind//[[:space:]]/}"
    [[ -z "${kind}" || "${kind}" == \#* || "${kind}" == kind ]] && continue
    case "${kind}" in
        user)
            if [ -n "$(sid_of "${name}")" ]; then info "user ${name} exists"
            else
                [ -n "${password}" ] || password="P0$(openssl rand -base64 12 | tr -d '/+=')!"
                if samba-tool user create "${name}" "${password}" "${H[@]}" >/dev/null 2>&1; then
                    pass "user ${name} created (password: ${password})"
                else fail "create user ${name}"; fi
            fi ;;
        group)
            if [ -n "$(sid_of "${name}")" ]; then info "group ${name} exists"
            elif samba-tool group add "${name}" "${H[@]}" >/dev/null 2>&1; then pass "group ${name} created"
            else fail "create group ${name}"; fi
            if [ -n "${members}" ]; then
                IFS=';' read -ra M <<< "${members}"
                samba-tool group addmembers "${name}" "$(IFS=,; echo "${M[*]}")" "${H[@]}" >/dev/null 2>&1 \
                    && info "members of ${name}: ${members}" || info "members of ${name} unchanged (already present or missing users)"
            fi ;;
        *) fail "unknown kind '${kind}' for ${name}"; continue ;;
    esac
    if [ -n "${source_sid// /}" ]; then
        new="$(sid_of "${name}")"
        if [ -n "${new}" ]; then echo "${source_sid// /} ${new} ${name}" >> "${MAP}"
        else fail "no SID for ${name}"; fi
    fi
done < <(tr -d '\r' < "${CSV}")

step "2. Rewrite source-domain SIDs in GPO files"
if python3 "${PHASE0_DIR}/map_principals.py" --map "${MAP}" --sysvol "${SYSVOL}" --host "${FQDN}"; then
    pass "no source-domain SIDs left in GPO files"
else
    fail "source-domain SIDs left (UNMAPPED lines above): add rows to ${CSV} or remove the settings"
fi
samba-tool ntacl sysvolreset >/dev/null 2>&1
check "ntacl sysvolcheck" samba-tool ntacl sysvolcheck

finish
