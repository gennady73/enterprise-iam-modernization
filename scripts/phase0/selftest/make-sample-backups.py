#!/usr/bin/python3
# =============================================================================
# make-sample-backups.py — write three sample `Backup-GPO`-style folders.
#
# Used to dry-run 04-import-gpos.sh / 05-check-gpos.sh before real backups
# are available. Registry.pol files are produced with Samba's own PReg
# (MS-GPREG) encoder, so they are byte-for-byte valid policy files.
#
# Usage: python3 make-sample-backups.py <output_dir>
# =============================================================================
import os
import sys
import uuid

from samba.dcerpc import preg, misc
from samba.ndr import ndr_pack

SAMPLES = [
    {
        'name': 'Phase0 Sample - Kernel Debug Workstation',
        'machine': [
            ('SOFTWARE\\Policies\\Microsoft\\Windows\\DeviceGuard', 'EnableVirtualizationBasedSecurity', misc.REG_DWORD, 0),
            ('SOFTWARE\\Policies\\Microsoft\\Windows Defender\\Exclusions', 'Exclusions_Paths', misc.REG_DWORD, 1),
            ('SOFTWARE\\Policies\\Microsoft\\Windows Defender\\Exclusions\\Paths', 'C:\\src', misc.REG_SZ, '0'),
            ('SOFTWARE\\Policies\\Microsoft\\Windows\\WindowsUpdate\\AU', 'NoAutoRebootWithLoggedOnUsers', misc.REG_DWORD, 1),
            ('SOFTWARE\\Policies\\Microsoft\\Windows\\System', 'LogonScriptPath', misc.REG_EXPAND_SZ, '%SystemRoot%\\dev'),
            ('SOFTWARE\\Policies\\Microsoft\\Windows\\Explorer', 'AllowedPaths', misc.REG_MULTI_SZ, ['C:\\src', 'D:\\symbols']),
            ('SOFTWARE\\Policies\\Microsoft\\Windows\\Explorer', '**del.NoDriveTypeAutoRun', misc.REG_SZ, ' '),
        ],
        'gpttmpl': (
            '[Unicode]\r\nUnicode=yes\r\n'
            '[Privilege Rights]\r\n'
            'SeDebugPrivilege = *S-1-5-32-544,*S-1-5-21-1111111111-2222222222-3333333333-1105\r\n'
            'SeLoadDriverPrivilege = *S-1-5-32-544\r\n'
            '[Version]\r\nsignature="$CHICAGO$"\r\nRevision=1\r\n'),
        'machine_ext': '[{35378EAC-683F-11D2-A89A-00C04FBBCFA2}{D02B1F72-3407-48AE-BA88-E8213C6761F1}]'
                       '[{827D319E-6EAC-11D2-A4EA-00C04F79F83A}{803E14A0-B4FB-11D0-A0D0-00A0C90F574B}]',
        'wmi': 'MSFT_SomFilter.ID="{AB12CD34-0000-4000-8000-000000000001}",Domain="corp.example"',
        'backup_xml': True,
    },
    {
        'name': 'Phase0 Sample - Developer Desktop',
        'user': [
            ('Software\\Policies\\Microsoft\\Windows\\Control Panel\\Desktop', 'ScreenSaveTimeOut', misc.REG_SZ, '1800'),
            ('Software\\Policies\\Microsoft\\Windows\\Explorer', 'DisableSearchBoxSuggestions', misc.REG_DWORD, 1),
        ],
        'backup_xml': False,   # exercises the "derive extensions from files" path
    },
    {
        'name': 'Phase0 Sample - Drive Maps',
        'user_files': {
            'Preferences/Drives/Drives.xml':
                '<?xml version="1.0" encoding="utf-8"?>\r\n'
                '<Drives clsid="{8FDDCC1A-0C3C-43cd-A6B4-71A6DF20DA8C}">'
                '<Drive clsid="{935D1B74-9CB8-4e3c-9914-7DD559B7A417}" name="S:" '
                'uid="{11111111-2222-3333-4444-555555555555}">'
                '<Properties action="U" path="\\\\fs01.corp.example\\src" letter="S"/>'
                '</Drive></Drives>\r\n',
        },
        'user_ext': '[{5794DAFD-BE60-433F-88A2-1A31939AC01F}{2EA1A81B-48E5-45E9-8BB7-A6E3AC170006}]',
        'backup_xml': True,
    },
]


def pol_bytes(entries):
    f = preg.file()
    f.header.signature = 'PReg'
    f.header.version = 1
    out = []
    for key, value, rtype, data in entries:
        e = preg.entry()
        e.keyname = key
        e.valuename = value
        e.type = rtype
        if rtype == misc.REG_DWORD:
            e.data = data
        elif rtype == misc.REG_MULTI_SZ:
            e.data = ('\x00'.join(data) + '\x00\x00').encode('utf-16-le')
        else:
            e.data = data
        out.append(e)
    f.num_entries = len(out)
    f.entries = out
    return ndr_pack(f)


def cdata(tag, value):
    return '<%s><![CDATA[%s]]></%s>' % (tag, value, tag) if value is not None else '<%s/>' % tag


def write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'wb') as fh:
        fh.write(data if isinstance(data, bytes) else data.encode('utf-8'))


def main(outdir):
    for s in SAMPLES:
        backup_id = '{%s}' % str(uuid.uuid4()).upper()
        gpo_id = '{%s}' % str(uuid.uuid4()).upper()
        root = os.path.join(outdir, backup_id)
        gpo = os.path.join(root, 'DomainSysvol', 'GPO')
        if s.get('machine'):
            write(os.path.join(gpo, 'Machine', 'registry.pol'), pol_bytes(s['machine']))
        if s.get('gpttmpl'):
            write(os.path.join(gpo, 'Machine', 'microsoft', 'windows nt', 'SecEdit', 'GptTmpl.inf'),
                  b'\xff\xfe' + s['gpttmpl'].encode('utf-16-le'))
        if s.get('user'):
            write(os.path.join(gpo, 'User', 'registry.pol'), pol_bytes(s['user']))
        for rel, text in s.get('user_files', {}).items():
            write(os.path.join(gpo, 'User', *rel.split('/')), text)
        write(os.path.join(root, 'bkupInfo.xml'),
              '<?xml version="1.0" encoding="utf-8"?><BackupInst xmlns="http://www.microsoft.com/GroupPolicy/GPOOperations/Manifest">'
              + cdata('GPOGuid', gpo_id) + cdata('GPODomain', 'corp.example')
              + cdata('GPODisplayName', s['name']) + cdata('ID', backup_id) + '</BackupInst>')
        if s['backup_xml']:
            write(os.path.join(root, 'Backup.xml'),
                  '<?xml version="1.0" encoding="utf-8"?>'
                  '<GroupPolicyBackupScheme bkp:version="2.0" bkp:type="GroupPolicyBackupTemplate" '
                  'xmlns:bkp="http://www.microsoft.com/GroupPolicy/GPOOperations" '
                  'xmlns="http://www.microsoft.com/GroupPolicy/GPOOperations">'
                  '<GroupPolicyObject><GroupPolicyCoreSettings>'
                  + cdata('ID', gpo_id) + cdata('Domain', 'corp.example')
                  + cdata('DisplayName', s['name'])
                  + cdata('MachineExtensionGuids', s.get('machine_ext'))
                  + cdata('UserExtensionGuids', s.get('user_ext'))
                  + cdata('WMIFilter', s.get('wmi'))
                  + '</GroupPolicyCoreSettings></GroupPolicyObject></GroupPolicyBackupScheme>')
        print('%s  %s' % (backup_id, s['name']))


if __name__ == '__main__':
    if len(sys.argv) != 2:
        sys.exit('usage: make-sample-backups.py <output_dir>')
    main(sys.argv[1])
