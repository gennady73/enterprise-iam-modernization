<#
.SYNOPSIS
  Phase 0, Step 1: export the GPOs under test from the source (dev/production) AD.

.DESCRIPTION
  Run on a machine with RSAT Group Policy Management, as a user who can read
  the GPOs. Writes, under -Path:
    {BackupId}\...                Backup-GPO output, one folder per GPO
    reports\<name>.html / .xml    Get-GPOReport per GPO (baseline for Step 4)
    manifest.csv                  name, GPO id, backup id, links, WMI filter
  Nothing in the source domain is changed.

.EXAMPLE
  .\Export-Phase0Gpos.ps1 -Name 'Dev Workstation Baseline','Kernel Debug' -Path C:\GPO_Backups
.EXAMPLE
  .\Export-Phase0Gpos.ps1 -All -Path C:\GPO_Backups
#>
[CmdletBinding(DefaultParameterSetName = 'Named')]
param(
    [Parameter(ParameterSetName = 'Named', Mandatory)][string[]]$Name,
    [Parameter(ParameterSetName = 'All', Mandatory)][switch]$All,
    [string]$Path = 'C:\GPO_Backups'
)
$ErrorActionPreference = 'Stop'
Import-Module GroupPolicy

New-Item -ItemType Directory -Force -Path $Path, (Join-Path $Path 'reports') | Out-Null
$gpos = if ($All) { Get-GPO -All } else { $Name | ForEach-Object { Get-GPO -Name $_ } }

$rows = foreach ($g in $gpos) {
    Write-Host "Exporting '$($g.DisplayName)'"
    $bk = Backup-GPO -Guid $g.Id -Path $Path -Comment 'Phase 0 export'
    $safe = ($g.DisplayName -replace '[\\/:*?"<>|]', '_')
    Get-GPOReport -Guid $g.Id -ReportType Html -Path (Join-Path $Path "reports\$safe.html")
    Get-GPOReport -Guid $g.Id -ReportType Xml  -Path (Join-Path $Path "reports\$safe.xml")
    [xml]$x = Get-GPOReport -Guid $g.Id -ReportType Xml
    $links = @($x.GPO.LinksTo | ForEach-Object { $_.SOMPath }) -join '; '
    [pscustomobject]@{
        Name      = $g.DisplayName
        GpoId     = "{$($g.Id)}"
        BackupId  = "{$($bk.Id)}"
        LinkedTo  = $links
        WmiFilter = $(if ($g.WmiFilter) { $g.WmiFilter.Name } else { '' })
        Status    = $g.GpoStatus
    }
}
$rows | Export-Csv -NoTypeInformation -Path (Join-Path $Path 'manifest.csv')
$rows | Format-Table Name, BackupId, LinkedTo, WmiFilter -AutoSize

Write-Host ""
Write-Host "Exported $(@($rows).Count) GPO(s) to $Path."
Write-Host "Next: copy the folder to the Samba VM, for example:"
Write-Host "  scp -r `"$Path`" root@<samba-vm>:/root/"
