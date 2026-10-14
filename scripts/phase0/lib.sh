#!/usr/bin/env bash
# Shared helpers for the Phase 0 scripts. Sourced, not executed.

PHASE0_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHASE0_ENV="${PHASE0_ENV:-${PHASE0_DIR}/phase0.env}"

if [ ! -r "${PHASE0_ENV}" ]; then
    echo "ERROR: ${PHASE0_ENV} not found. Copy phase0.env.example to phase0.env and edit it." >&2
    exit 2
fi
# shellcheck source=/dev/null
. <(tr -d '\r' < "${PHASE0_ENV}")      # tolerate a CRLF copy from Windows

REALM="${REALM^^}"
DNSDOMAIN="${REALM,,}"
FQDN="${DC_HOSTNAME}.${DNSDOMAIN}"
BASEDN="DC=${DNSDOMAIN//./,DC=}"
SYSVOL="/var/lib/samba/sysvol/${DNSDOMAIN}"
LDAP_URL="ldap://${FQDN}"
KRB="--use-kerberos=required"

FAILED=0
step()  { echo; echo "==== $*"; }
pass()  { echo "[PASS] $*"; }
fail()  { echo "[FAIL] $*"; FAILED=$((FAILED + 1)); }
info()  { echo "       $*"; }
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$d"; else fail "$d"; fi; }
die()   { echo "ERROR: $*" >&2; exit 1; }

require_root() { [ "${EUID}" -eq 0 ] || die "run as root"; }

# Obtain a Kerberos ticket for Administrator if none is valid.
ensure_ticket() {
    if klist -s 2>/dev/null; then return 0; fi
    if [ -n "${ADMINPASS:-}" ]; then
        echo "${ADMINPASS}" | kinit "administrator@${REALM}" >/dev/null
    else
        kinit "administrator@${REALM}"
    fi
}

finish() {
    echo
    if [ "${FAILED}" -eq 0 ]; then
        echo "RESULT: all checks passed"
    else
        echo "RESULT: ${FAILED} check(s) failed"
    fi
    exit "${FAILED}"
}
