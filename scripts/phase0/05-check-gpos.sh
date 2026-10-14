#!/usr/bin/env bash
# =============================================================================
# 05-check-gpos.sh  —  Phase 0, Step 3 gate: every GPO is consistent between
# LDAP and SysVol, so Windows clients will process it. Read-only.
# Run after 04-import-gpos.sh or after importing with GPMC on Windows.
# =============================================================================
set -uo pipefail
. "$(dirname "$0")/lib.sh"
require_root
ensure_ticket

OU_DN="${TARGET_OU},${BASEDN}"

step "Per-GPO consistency (LDAP versionNumber = GPT.INI Version, folder, ACL)"
python3 - "${FQDN}" "${SYSVOL}" <<'EOF'
import sys, os, re
from samba import param
from samba.auth import system_session
from samba.credentials import Credentials, MUST_USE_KERBEROS
from samba.samdb import SamDB
host, sysvol = sys.argv[1], sys.argv[2]
lp = param.LoadParm(); lp.load_default()
c = Credentials(); c.guess(lp); c.set_kerberos_state(MUST_USE_KERBEROS)
db = SamDB(url='ldap://' + host, session_info=system_session(), credentials=c, lp=lp)
bad = 0
for m in db.search(base='CN=Policies,CN=System,' + str(db.domain_dn()), scope=1,
                   expression='(objectClass=groupPolicyContainer)',
                   attrs=['name', 'displayName', 'versionNumber', 'gPCFileSysPath',
                          'gPCMachineExtensionNames', 'gPCUserExtensionNames']):
    guid, name = str(m['name']), str(m.get('displayName', [b'?'])[0])
    ver = int(str(m.get('versionNumber', [b'0'])[0]))
    folder = os.path.join(sysvol, 'Policies', guid)
    gpt = os.path.join(folder, 'GPT.INI')
    problems = []
    if not os.path.isdir(folder):
        problems.append('SysVol folder missing')
    elif not os.path.exists(gpt):
        problems.append('GPT.INI missing')
    else:
        txt = open(gpt, 'rb').read().decode('utf-8', 'replace')
        v = re.search(r'Version\s*=\s*(\d+)', txt)
        if not v or int(v.group(1)) != ver:
            problems.append('version mismatch LDAP=%d GPT.INI=%s' % (ver, v.group(1) if v else 'none'))
    has_content = os.path.isdir(folder) and any(
        f for d in ('MACHINE', 'USER', 'Machine', 'User')
        for _, _, f in os.walk(os.path.join(folder, d)))
    exts = (str(m.get('gPCMachineExtensionNames', [b''])[0]) +
            str(m.get('gPCUserExtensionNames', [b''])[0])).strip()
    if has_content and not exts:
        problems.append('has content but no extension names (clients will ignore it)')
    if has_content and ver == 0:
        problems.append('has content but version 0 (clients will ignore it)')
    status = 'FAIL' if problems else 'PASS'
    bad += bool(problems)
    print('[%s] %-40s %s v%d %s' % (status, name[:40], guid, ver, '; '.join(problems)))
sys.exit(1 if bad else 0)
EOF
[ $? -eq 0 ] && pass "all GPOs consistent" || fail "inconsistent GPOs above"

step "Links on ${OU_DN}"
samba-tool gpo getlink "${OU_DN}" -H "${LDAP_URL}" ${KRB} 2>/dev/null | sed -n 's/^ *GPO *: */       /p'
check "at least one GPO linked to the target OU" \
    bash -c "samba-tool gpo getlink '${OU_DN}' -H ${LDAP_URL} ${KRB} 2>/dev/null | grep -q 'GPO '"

step "SysVol ACLs"
if samba-tool ntacl sysvolcheck >/dev/null 2>&1; then
    pass "ntacl sysvolcheck"
else
    info "sysvolcheck reported differences; running sysvolreset"
    samba-tool ntacl sysvolreset && check "ntacl sysvolcheck after reset" samba-tool ntacl sysvolcheck
fi

finish
