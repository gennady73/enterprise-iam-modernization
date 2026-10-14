# Phase 0 scripts — sandbox Samba AD DC and GPO Go/No-Go

Procedure: [SAMBA_AD_DC_IMPLEMENTATION_GUIDE.md, Phase 0](../../docs/SAMBA_AD_DC_IMPLEMENTATION_GUIDE.md#phase-0-the-isolated-poc--complex-gpo-validation-gate-mandatory-gono-go).

| File | Runs on | Step | Does |
| :--- | :--- | :--- | :--- |
| `windows/Export-Phase0Gpos.ps1` | admin PC in the source AD | 1 | `Backup-GPO` + per-GPO reports + manifest |
| `phase0.env.example` | Samba VM | 2 | settings; copy to `phase0.env` |
| `01-prepare-host.sh` | Samba VM | 2 | host name, chrony, firewall, SELinux, installs `samba-ad-dc` |
| `02-provision-dc.sh` | Samba VM | 2 | provisions the new domain (generates `smb.conf`), starts samba, runs `03` |
| `03-check-dc.sh` | Samba VM | 2 | DC health gate incl. `smb.conf` checks (read-only) |
| `04-import-gpos.sh` + `gpo_import.py` | Samba VM | 3 | imports `Backup-GPO` folders, links them to `TARGET_OU` |
| `principals.csv.example` | Samba VM | 3 | users/groups for the new domain + source-SID mapping |
| `06-map-principals.sh` + `map_principals.py` | Samba VM | 3 | creates them; rewrites source-domain SIDs in GPO files |
| `05-check-gpos.sh` | Samba VM | 3 | GPO consistency gate (read-only) |
| `windows/Move-WorkstationToSamba.ps1` | workstation | 4 | leaves the source domain (pass 1), joins the Samba domain (pass 2) |
| `windows/Restore-WorkstationDomain.ps1` | workstation | rollback | returns the workstation to the source domain |
| `windows/Test-Phase0Workstation.ps1` + `Phase0.psm1` | test workstation | 4 | Go/No-Go: RSoP, registry values, extensions, event logs |
| `selftest/make-sample-backups.py` | Samba VM | — | writes three sample `Backup-GPO` folders for a dry run |

All shell scripts print `[PASS]`/`[FAIL]` lines and exit with the number of failed checks.

## Dry run before real backups

On the Samba VM, after Step 2:

```bash
python3 selftest/make-sample-backups.py /root/sample_backups
./04-import-gpos.sh /root/sample_backups     # expect 3 imported and REVIEW lines for a SID, a UNC path, a WMI filter
./05-check-gpos.sh                           # expect all checks passed
# remove the samples before Step 4, so they do not apply to the test workstation:
. ./phase0.env; H="-H ldap://${DC_HOSTNAME}.${REALM,,} --use-kerberos=required"; kinit administrator
for g in $(samba-tool gpo listall $H | awk '/^GPO/{g=$3} /display name : Phase0 Sample/{print g}'); do samba-tool gpo del "$g" $H; done
```
