#!/usr/bin/env bash
# =============================================================================
# 04-import-gpos.sh  —  Phase 0, Step 3: import Windows Backup-GPO output.
#
# For every {BackupID} folder in GPO_BACKUP_DIR: creates a GPO with the
# original display name, uploads its DomainSysvol/GPO content, sets the
# client-side extension names, bumps the version and links it to TARGET_OU.
# Prints REVIEW lines for anything tied to the source domain.
#
# Usage:  ./04-import-gpos.sh [backup_dir]
# GPOs whose name already exists in the sandbox are skipped (re-runnable).
# =============================================================================
set -uo pipefail
. "$(dirname "$0")/lib.sh"
require_root
ensure_ticket

DIR="${1:-${GPO_BACKUP_DIR}}"
[ -d "${DIR}" ] || die "backup folder ${DIR} not found"
OU_DN="${TARGET_OU},${BASEDN}"

step "1. Target OU ${OU_DN}"
if ! samba-tool ou list -H "${LDAP_URL}" ${KRB} 2>/dev/null | grep -qxF "${TARGET_OU}"; then
    samba-tool ou add "${OU_DN}" -H "${LDAP_URL}" ${KRB} >/dev/null || die "cannot create ${OU_DN}"
    info "created"
fi

EXISTING="$(samba-tool gpo listall -H "${LDAP_URL}" ${KRB} 2>/dev/null)"
IMPORTED=0; SKIPPED=0
step "2. Import"
for B in "${DIR}"/\{*\}; do
    [ -d "${B}/DomainSysvol/GPO" ] || continue
    NAME="$(PYTHONPATH="${PHASE0_DIR}" python3 -c 'import sys, gpo_import; print(gpo_import.backup_meta(sys.argv[1])["name"] or "")' "${B}")"
    [ -n "${NAME}" ] || NAME="Imported $(basename "${B}")"
    echo
    echo "-- ${NAME}  ($(basename "${B}"))"
    if grep -qxF "display name : ${NAME}" <<< "${EXISTING}"; then
        info "already exists, skipped"; SKIPPED=$((SKIPPED + 1)); continue
    fi
    GUID="$(samba-tool gpo create "${NAME}" -H "${LDAP_URL}" ${KRB} 2>/dev/null | grep -o '{[0-9A-Fa-f-]*}')"
    if [ -z "${GUID}" ]; then fail "create GPO '${NAME}'"; continue; fi
    info "created ${GUID}"
    if python3 "${PHASE0_DIR}/gpo_import.py" --backup "${B}" --gpo "${GUID}" --host "${FQDN}"; then
        if samba-tool gpo setlink "${OU_DN}" "${GUID}" -H "${LDAP_URL}" ${KRB} >/dev/null 2>&1; then
            pass "imported and linked '${NAME}'"; IMPORTED=$((IMPORTED + 1))
        else
            fail "link '${NAME}' to ${OU_DN}"
        fi
    else
        fail "import content of '${NAME}'"
    fi
done

step "3. SysVol ACLs"
samba-tool ntacl sysvolreset && check "ntacl sysvolcheck" samba-tool ntacl sysvolcheck

step "4. Summary"
info "imported: ${IMPORTED}, skipped: ${SKIPPED}"
info "Next: map SIDs with 06-map-principals.sh, resolve other REVIEW lines, then run 05-check-gpos.sh"
finish
