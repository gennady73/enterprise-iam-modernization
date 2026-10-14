# =============================================================================
# Phase0.psm1 - helpers shared by the Phase 0 Windows scripts.
# Compatible with Windows PowerShell 5.1 and PowerShell 7.
# =============================================================================
Set-StrictMode -Version 2.0

function Read-Phase0Pol {
    <#
      Parses a Registry.pol file (MS-GPREG "PReg" format) and returns one
      object per entry: Key, ValueName, Type, Data (decoded).
    #>
    param([Parameter(Mandatory)][string]$Path)
    $b = [System.IO.File]::ReadAllBytes($Path)
    if ($b.Length -lt 8 -or [System.Text.Encoding]::ASCII.GetString($b, 0, 4) -ne 'PReg') {
        throw "$Path is not a PReg file"
    }
    $i = 8
    $u = [System.Text.Encoding]::Unicode
    $readStr = {
        $start = $script:i
        while ($script:i + 1 -lt $b.Length -and -not ($b[$script:i] -eq 0 -and $b[$script:i + 1] -eq 0)) { $script:i += 2 }
        $s = $u.GetString($b, $start, $script:i - $start)
        $script:i += 2
        $s
    }
    $script:i = $i
    $out = New-Object System.Collections.Generic.List[object]
    while ($script:i + 2 -le $b.Length) {
        if ($u.GetString($b, $script:i, 2) -ne '[') { break }
        $script:i += 2
        $key = & $readStr
        $script:i += 2                                   # ';'
        $name = & $readStr
        $script:i += 2                                   # ';'
        $type = [BitConverter]::ToUInt32($b, $script:i); $script:i += 4
        $script:i += 2                                   # ';'
        $size = [BitConverter]::ToUInt32($b, $script:i); $script:i += 4
        $script:i += 2                                   # ';'
        $raw = New-Object byte[] $size
        if ($size -gt 0) { [Array]::Copy($b, $script:i, $raw, 0, $size) }
        $script:i += $size
        $script:i += 2                                   # ']'
        switch ($type) {
            1 { $data = $u.GetString($raw).TrimEnd([char]0) }                      # REG_SZ
            2 { $data = $u.GetString($raw).TrimEnd([char]0) }                      # REG_EXPAND_SZ
            4 { $data = if ($size -ge 4) { [BitConverter]::ToUInt32($raw, 0) } else { $null } }
            7 { $data = @($u.GetString($raw).TrimEnd([char]0).Split([char]0) | Where-Object { $_ -ne '' }) }
            11 { $data = if ($size -ge 8) { [BitConverter]::ToUInt64($raw, 0) } else { $null } }
            default { $data = $raw }
        }
        $out.Add([pscustomobject]@{ Key = $key; ValueName = $name; Type = [int]$type; Data = $data })
    }
    return , $out.ToArray()
}

function Get-Phase0BackupInfo {
    <# Name and GPO id of one Backup-GPO folder ({BackupId}). #>
    param([Parameter(Mandatory)][string]$BackupFolder)
    $info = Join-Path $BackupFolder 'bkupInfo.xml'
    $name = $null; $gpo = $null
    if (Test-Path $info) {
        $t = Get-Content -Raw -LiteralPath $info
        if ($t -match '<GPODisplayName>\s*<!\[CDATA\[(.*?)\]\]>') { $name = $Matches[1] }
        if ($t -match '<GPOGuid>\s*<!\[CDATA\[(.*?)\]\]>') { $gpo = $Matches[1] }
    }
    [pscustomobject]@{
        Name       = $name
        SourceGuid = $gpo
        MachinePol = Join-Path $BackupFolder 'DomainSysvol\GPO\Machine\registry.pol'
        UserPol    = Join-Path $BackupFolder 'DomainSysvol\GPO\User\registry.pol'
    }
}

function Test-Phase0PolEntries {
    <#
      Compares Registry.pol entries with what a client actually holds.
      -Getter is a scriptblock (Key, ValueName) -> @{Exists=$bool; Value=...}
      so the logic can be tested without a Windows registry.
      Returns one result object per checked entry.
    #>
    param(
        [Parameter(Mandatory)][object[]]$Entries,
        [Parameter(Mandatory)][scriptblock]$Getter
    )
    foreach ($e in $Entries) {
        $name = $e.ValueName
        if ($name -eq '' -or $name -like '**delvals*' -or $name -like '**DeleteValues*' -or
            $name -like '**DeleteKeys*' -or $name -like '**SecureKey*' -or $name -like '**soft.*') {
            continue                                        # key-level markers: not a value to compare
        }
        if ($name -like '**del.*') {
            $target = $name.Substring(6)
            $a = & $Getter $e.Key $target
            [pscustomobject]@{ Key = $e.Key; ValueName = $target; Expected = '(absent)';
                Actual = $(if ($a.Exists) { $a.Value } else { '(absent)' }); Ok = (-not $a.Exists) }
            continue
        }
        $a = & $Getter $e.Key $name
        $ok = $false
        if ($a.Exists) {
            if ($e.Type -eq 7) {
                $ok = (@($a.Value) -join "`n") -eq (@($e.Data) -join "`n")
            } elseif ($e.Type -in 1, 2) {
                $ok = ([string]$a.Value).TrimEnd([char]0) -eq [string]$e.Data
            } elseif ($e.Type -in 4, 11) {
                $ok = [uint64]$a.Value -eq [uint64]$e.Data
            } else {
                $ok = ([BitConverter]::ToString([byte[]]$a.Value)) -eq ([BitConverter]::ToString([byte[]]$e.Data))
            }
        }
        [pscustomobject]@{ Key = $e.Key; ValueName = $name; Expected = $e.Data;
            Actual = $(if ($a.Exists) { $a.Value } else { '(absent)' }); Ok = $ok }
    }
}

function New-Phase0RegistryGetter {
    <# Real-registry getter. -Hive 'HKLM' or a user SID (reads HKEY_USERS\<SID>). #>
    param([Parameter(Mandatory)][string]$Hive)
    $root = if ($Hive -eq 'HKLM') { [Microsoft.Win32.Registry]::LocalMachine }
            else { [Microsoft.Win32.Registry]::Users.OpenSubKey($Hive) }
    return {
        param($Key, $ValueName)
        if (-not $root) { return @{ Exists = $false; Value = $null } }
        $k = $root.OpenSubKey($Key)
        if (-not $k -or ($k.GetValueNames() -notcontains $ValueName)) { return @{ Exists = $false; Value = $null } }
        @{ Exists = $true; Value = $k.GetValue($ValueName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) }
    }.GetNewClosure()
}

Export-ModuleMember -Function Read-Phase0Pol, Get-Phase0BackupInfo, Test-Phase0PolEntries, New-Phase0RegistryGetter
