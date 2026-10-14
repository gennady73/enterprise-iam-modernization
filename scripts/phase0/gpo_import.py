#!/usr/bin/python3
# =============================================================================
# gpo_import.py — import one Windows `Backup-GPO` folder into a Samba AD DC.
#
# Called by 04-import-gpos.sh. Runs with the Samba Python bindings and a
# Kerberos ticket for a domain admin.
#
# What it does for an existing (empty) GPO <guid>:
#   * uploads every file under <backup>/DomainSysvol/GPO/ into the GPO's
#     SysVol folder over SMB, with the GPO's file-system ACL;
#   * sets gPCMachineExtensionNames / gPCUserExtensionNames from Backup.xml
#     (or derives them from the files present);
#   * bumps the machine/user version in GPT.INI and LDAP so clients refresh;
#   * prints findings that need a human decision (domain SIDs, UNC paths,
#     WMI filter), because Backup-GPO content is tied to the source domain.
# =============================================================================
import argparse
import os
import re
import sys

import ldb
from samba import param
from samba.auth import system_session
from samba.credentials import Credentials, MUST_USE_KERBEROS
from samba.netcmd.gpcommon import create_directory_hier
from samba.policies import RegistryGroupPolicies
from samba.samdb import SamDB

GUID = r'\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}'
EXT_RE = re.compile(r'^(\[(%s)+\])*$' % GUID)

# Client-side extension + admin tool GUID pairs, keyed by a file that proves
# the extension is in use. Used only when Backup.xml cannot be read.
KNOWN_EXTS = [
    ('registry.pol', '[{35378EAC-683F-11D2-A89A-00C04FBBCFA2}{D02B1F72-3407-48AE-BA88-E8213C6761F1}]'),
    ('gpttmpl.inf',  '[{827D319E-6EAC-11D2-A4EA-00C04F79F83A}{803E14A0-B4FB-11D0-A0D0-00A0C90F574B}]'),
    ('scripts.ini',  '[{42B5FAAE-6536-11D2-AE5A-0000F87571E3}{40B6664F-4972-11D1-A7CA-0000F87571E3}]'),
]


def read_text(path):
    raw = open(path, 'rb').read()
    for bom, enc in ((b'\xff\xfe', 'utf-16-le'), (b'\xfe\xff', 'utf-16-be'),
                     (b'\xef\xbb\xbf', 'utf-8-sig')):
        if raw.startswith(bom):
            return raw[len(bom):].decode(enc, 'replace')
    return raw.decode('utf-8', 'replace')


def cdata(xml, tag):
    m = re.search(r'<%s>\s*<!\[CDATA\[(.*?)\]\]>\s*</%s>' % (tag, tag), xml, re.S)
    return m.group(1).strip() if m else None


def backup_meta(backup):
    meta = {'name': None, 'machine_ext': None, 'user_ext': None, 'wmi': None}
    info = os.path.join(backup, 'bkupInfo.xml')
    if os.path.exists(info):
        meta['name'] = cdata(read_text(info), 'GPODisplayName')
    bx = os.path.join(backup, 'Backup.xml')
    if os.path.exists(bx):
        xml = read_text(bx)
        meta['name'] = meta['name'] or cdata(xml, 'DisplayName')
        meta['machine_ext'] = cdata(xml, 'MachineExtensionGuids')
        meta['user_ext'] = cdata(xml, 'UserExtensionGuids')
        meta['wmi'] = cdata(xml, 'WMIFilter')
    return meta


def derive_ext(files, side):
    names = {os.path.basename(f).lower() for f in files if f.split(os.sep)[0].lower() == side}
    return ''.join(ext for marker, ext in KNOWN_EXTS if marker in names)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--backup', required=True)
    ap.add_argument('--gpo', required=True, help='GUID of the target GPO')
    ap.add_argument('--host', required=True, help='DC FQDN')
    args = ap.parse_args()

    src = os.path.join(args.backup, 'DomainSysvol', 'GPO')
    if not os.path.isdir(src):
        print('ERROR: %s has no DomainSysvol/GPO folder' % args.backup)
        return 2
    files = []
    for root, _, names in os.walk(src):
        for n in names:
            files.append(os.path.relpath(os.path.join(root, n), src))
    files.sort()

    lp = param.LoadParm()
    lp.load_default()
    creds = Credentials()
    creds.guess(lp)
    creds.set_kerberos_state(MUST_USE_KERBEROS)
    url = 'ldap://' + args.host
    samdb = SamDB(url=url, session_info=system_session(), credentials=creds, lp=lp)
    reg = RegistryGroupPolicies(args.gpo, lp, creds, samdb, url)

    # 1. Upload files (SysVol is case-insensitive over SMB; keep source names).
    machine = user = False
    for rel in files:
        parts = rel.split(os.sep)
        side = parts[0].lower()
        machine = machine or side == 'machine'
        user = user or side == 'user'
        remote = reg.pol_dir % '\\'.join(parts)
        create_directory_hier(reg.conn, remote.rsplit('\\', 1)[0])
        reg.conn.savefile(remote, open(os.path.join(src, rel), 'rb').read())
        reg.conn.set_acl(remote, reg.fs_sd)
        print('  uploaded %s' % '/'.join(parts))

    # 2. Extension names (decide which client-side extensions run).
    meta = backup_meta(args.backup)
    exts = {
        'gPCMachineExtensionNames': meta['machine_ext'] or derive_ext(files, 'machine'),
        'gPCUserExtensionNames': meta['user_ext'] or derive_ext(files, 'user'),
    }
    m = ldb.Message()
    m.dn = reg.policy_dn
    for attr, value in exts.items():
        value = value.strip()
        if not value:
            continue
        if not EXT_RE.match(value):
            print('  WARNING: ignoring malformed %s: %s' % (attr, value))
            continue
        m[attr] = ldb.MessageElement(value, ldb.FLAG_MOD_REPLACE, attr)
        print('  %s = %s' % (attr, value))
    if len(m) > 0:
        samdb.modify(m)

    # 3. Version bump so clients re-apply the GPO.
    reg.increment_gpt_ini(machine_changed=machine, user_changed=user)

    # 4. Findings that need a human decision.
    sids, uncs = set(), set()
    for rel in files:
        if rel.lower().endswith(('.inf', '.xml', '.ini')):
            text = read_text(os.path.join(src, rel))
            sids.update(re.findall(r'S-1-5-21-\d+-\d+-\d+-\d+', text))
            uncs.update(re.findall(r'\\\\[A-Za-z0-9._-]+\\[^\s"<>]*', text))
    findings = 0
    if meta['wmi']:
        findings += 1
        print('  REVIEW: WMI filter in source GPO (not imported): %s' % meta['wmi'][:120])
    for s in sorted(sids):
        findings += 1
        print('  REVIEW: source-domain SID %s (add it to principals.csv and run 06-map-principals.sh)' % s)
    for u in sorted(uncs):
        findings += 1
        print('  REVIEW: UNC path %s (must be reachable from the new domain)' % u)
    print('  findings: %d' % findings)
    return 0


if __name__ == '__main__':
    sys.exit(main())
