#!/usr/bin/python3
# =============================================================================
# map_principals.py — called by 06-map-principals.sh.
#
# Replaces source-domain SIDs inside the target domain's GPO files with the
# SIDs of the principals named in the mapping, bumps the version of every
# GPO it changed, and lists source-domain SIDs that are still unmapped.
#
#   --map  file with lines  <source-SID> <target-SID> <target-name>
# =============================================================================
import argparse
import os
import re
import sys

from samba import param
from samba.auth import system_session
from samba.credentials import Credentials, MUST_USE_KERBEROS
from samba.policies import RegistryGroupPolicies
from samba.samdb import SamDB

SID_RE = re.compile(r'S-1-5-21-\d+-\d+-\d+-\d+')
TEXT_EXT = ('.inf', '.xml', '.ini')


def decode(raw):
    if raw.startswith(b'\xff\xfe'):
        return 'utf-16-le', raw[2:].decode('utf-16-le'), b'\xff\xfe'
    if raw.startswith(b'\xef\xbb\xbf'):
        return 'utf-8', raw[3:].decode('utf-8'), b'\xef\xbb\xbf'
    return 'utf-8', raw.decode('utf-8', 'replace'), b''


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--map', required=True)
    ap.add_argument('--sysvol', required=True, help='/var/lib/samba/sysvol/<domain>')
    ap.add_argument('--host', required=True)
    args = ap.parse_args()

    mapping = {}
    for line in open(args.map):
        parts = line.split(None, 2)
        if len(parts) == 3:
            mapping[parts[0]] = (parts[1], parts[2].strip())

    lp = param.LoadParm()
    lp.load_default()
    creds = Credentials()
    creds.guess(lp)
    creds.set_kerberos_state(MUST_USE_KERBEROS)
    url = 'ldap://' + args.host
    samdb = SamDB(url=url, session_info=system_session(), credentials=creds, lp=lp)
    own_sid = str(samdb.get_domain_sid())

    policies = os.path.join(args.sysvol, 'Policies')
    changed = {}            # guid -> (machine_changed, user_changed)
    unmapped = {}           # sid -> set of files
    for guid in sorted(os.listdir(policies)):
        root = os.path.join(policies, guid)
        if not guid.startswith('{') or not os.path.isdir(root):
            continue
        for d, _, files in os.walk(root):
            for f in files:
                if not f.lower().endswith(TEXT_EXT) or f.upper() == 'GPT.INI':
                    continue
                path = os.path.join(d, f)
                raw = open(path, 'rb').read()
                enc, text, bom = decode(raw)
                new = text
                for src, (dst, name) in mapping.items():
                    if src in new:
                        new = new.replace(src, dst)
                        print('  %s %s: %s -> %s (%s)' % (guid, os.path.relpath(path, root), src, dst, name))
                if new != text:
                    with open(path, 'r+b') as fh:          # in place: keeps the file's NT ACL
                        fh.write(bom + new.encode(enc))
                        fh.truncate()
                    side = os.path.relpath(path, root).split(os.sep)[0].lower()
                    m, u = changed.get(guid, (False, False))
                    changed[guid] = (m or side == 'machine', u or side == 'user')
                for sid in set(SID_RE.findall(new)):
                    if not sid.startswith(own_sid + '-'):
                        unmapped.setdefault(sid, set()).add('%s/%s' % (guid, os.path.relpath(path, root)))

    for guid, (m, u) in changed.items():
        RegistryGroupPolicies(guid, lp, creds, samdb, url).increment_gpt_ini(machine_changed=m, user_changed=u)
        print('  version raised: %s' % guid)

    for sid, files in sorted(unmapped.items()):
        print('  UNMAPPED: %s in %s' % (sid, ', '.join(sorted(files))))
    print('  GPOs changed: %d, unmapped source SIDs: %d' % (len(changed), len(unmapped)))
    return 1 if unmapped else 0


if __name__ == '__main__':
    sys.exit(main())
