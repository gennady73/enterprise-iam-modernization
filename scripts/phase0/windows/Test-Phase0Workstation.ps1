<#
.SYNOPSIS
  Phase 0, Step 4b: the Go/No-Go check on the test workstation.

.DESCRIPTION
  Run elevated on the sandbox-joined workstation AFTER the test user has
  logged on once (so user policy has been processed). For every GPO in
  -BackupPath it checks that:
    1. the GPO is in the computer/user RSoP and not filtered or denied;
    2. every Registry.pol value (Administrative Templates) is present in
       HKLM / the test user's hive with the expected data;
  and for the whole run that:
    3. every client-side extension finished without error;
    4. the GroupPolicy Operational log has no errors or warnings.
  Writes gpresult HTML/XML and results.csv to -OutPath. Exit code = failures.

.EXAMPLE
  .\Test-Phase0Workstation.ps1 -BackupPath C:\GPO_Backups -TestUser 'SANDBOX\devuser'
#>
param(
    [Parameter(Mandatory)][string]$BackupPath,
    [Parameter(Mandatory)][string]$TestUser,
    [string]$OutPath = 'C:\Phase0_Results'
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Phase0.psm1') -Force
New-Item -ItemType Directory -Force -Path $OutPath | Out-Null
$fail = 0
$rows = New-Object System.Collections.Generic.List[object]
function Result($area, $item, $ok, $detail) {
    $rows.Add([pscustomobject]@{ Area = $area; Item = $item; Ok = [bool]$ok; Detail = $detail })
    if ($ok) { Write-Host "[PASS] $area : $item" } else { Write-Host "[FAIL] $area : $item  $detail" -ForegroundColor Red; $script:fail++ }
}

$userSid = (New-Object System.Security.Principal.NTAccount($TestUser)).Translate([System.Security.Principal.SecurityIdentifier]).Value
if (-not (Test-Path "Registry::HKEY_USERS\$userSid")) {
    throw "$TestUser has no loaded profile. Log on as $TestUser first (keep the session open), then re-run."
}

# 1. Refresh computer policy and collect RSoP
$start = Get-Date
gpupdate /target:computer /force /wait:120 | Out-Null
gpresult /scope computer /x (Join-Path $OutPath 'rsop-computer.xml') /f | Out-Null
gpresult /user $TestUser /scope user /x (Join-Path $OutPath 'rsop-user.xml') /f | Out-Null
gpresult /user $TestUser /h (Join-Path $OutPath 'rsop.html') /f | Out-Null
[xml]$rc = Get-Content -Raw (Join-Path $OutPath 'rsop-computer.xml')
[xml]$ru = Get-Content -Raw (Join-Path $OutPath 'rsop-user.xml')

function GpoState([xml]$x, [string]$name) {
    $n = $x.SelectNodes("//*[local-name()='GPO'][*[local-name()='Name']='$name']") | Select-Object -First 1
    if (-not $n) { return 'not in RSoP' }
    $f = { param($tag) ($n.SelectSingleNode("*[local-name()='$tag']")).InnerText }
    if ((& $f 'AccessDenied') -eq 'true') { return 'access denied' }
    if ((& $f 'FilterAllowed') -eq 'false') { return 'WMI filter denied' }
    if ((& $f 'IsValid') -eq 'false') { return 'invalid' }
    return 'applied'
}

# 2. Per-GPO checks
$machineGet = New-Phase0RegistryGetter -Hive 'HKLM'
$userGet = New-Phase0RegistryGetter -Hive $userSid
foreach ($dir in Get-ChildItem -LiteralPath $BackupPath -Directory | Where-Object { $_.Name -match '^\{.*\}$' }) {
    $info = Get-Phase0BackupInfo $dir.FullName
    $gp = $info.Name
    Write-Host ""
    Write-Host "== $gp"
    foreach ($side in @(@{ Pol = $info.MachinePol; Xml = $rc; Get = $machineGet; Label = 'computer' },
                        @{ Pol = $info.UserPol; Xml = $ru; Get = $userGet; Label = 'user' })) {
        if (-not (Test-Path -LiteralPath $side.Pol)) { continue }
        $state = GpoState $side.Xml $gp
        Result "GPO $($side.Label)" $gp ($state -eq 'applied') $state
        $checks = @(Test-Phase0PolEntries -Entries (Read-Phase0Pol $side.Pol) -Getter $side.Get)
        $bad = @($checks | Where-Object { -not $_.Ok })
        Result "registry $($side.Label)" "$gp ($($checks.Count - $bad.Count)/$($checks.Count) values)" ($bad.Count -eq 0) `
            (($bad | ForEach-Object { "$($_.Key)\$($_.ValueName) expected [$($_.Expected -join ',')] got [$($_.Actual -join ',')]" }) -join '; ')
    }
}

# 3. Client-side extension status
Write-Host ""
foreach ($x in @($rc, $ru)) {
    foreach ($ext in $x.SelectNodes("//*[local-name()='ExtensionStatus']")) {
        $nm = ($ext.SelectSingleNode("*[local-name()='Name']")).InnerText
        $err = $ext.SelectSingleNode("*[local-name()='Error']")
        if ($err) { Result 'extension' $nm ($err.InnerText -eq '0') "error $($err.InnerText)" }
    }
}

# 4. Group Policy event logs since this run started
$ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-GroupPolicy/Operational'; Level = 2, 3; StartTime = $start } -ErrorAction SilentlyContinue)
Result 'events' 'GroupPolicy/Operational errors+warnings since gpupdate' ($ev.Count -eq 0) `
    (($ev | Select-Object -First 5 | ForEach-Object { "$($_.Id): $($_.Message.Split("`n")[0])" }) -join ' | ')
$sys = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-GroupPolicy'; Id = 1502; StartTime = $start } -ErrorAction SilentlyContinue)
Result 'events' 'System 1502 (computer policy processed)' ($sys.Count -gt 0) 'no 1502 event after gpupdate'

$rows | Export-Csv -NoTypeInformation -Path (Join-Path $OutPath 'results.csv')
Write-Host ""
if ($fail -eq 0) { Write-Host "GO: all Phase 0 checks passed" -ForegroundColor Green }
else { Write-Host "NO-GO: $fail check(s) failed - see $OutPath\results.csv" -ForegroundColor Red }
exit $fail
