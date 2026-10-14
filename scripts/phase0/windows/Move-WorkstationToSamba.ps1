<#
.SYNOPSIS
  Phase 0, Step 4a: move an existing workstation from the source domain
  (e.g. mydomain.com) to the Samba domain (e.g. mydomain2.com).

.DESCRIPTION
  Run elevated. Two passes, with a restart in between:

  Pass 1 (computer is still in the source domain)
    - checks that the local admin account given by -LocalAdmin exists and is
      enabled (it is the only way in if the join fails);
    - saves rollback data to C:\Phase0_Rollback: source domain, DNS servers,
      BitLocker recovery key(s) — copy that folder off the machine;
    - leaves the source domain to workgroup PHASE0 (the old computer account
      is disabled when -SourceCredential is given), restarts.

  Pass 2 (computer is in a workgroup; log on with the local admin)
    - points DNS at the Samba DC, checks SRV records, ports and clock;
    - joins the Samba domain into -OUPath, restarts.

  Users then log on as NEWDOMAIN\user and get a new Windows profile; the old
  profile stays on disk. Rollback: Restore-WorkstationDomain.ps1.

.EXAMPLE
  # Pass 1 and pass 2 use the same command line:
  .\Move-WorkstationToSamba.ps1 -DomainName mydomain2.com -DcIp 192.168.100.10 `
      -OUPath 'OU=Dev Workstations,DC=mydomain2,DC=com' -LocalAdmin Administrator
#>
param(
    [Parameter(Mandatory)][string]$DomainName,
    [Parameter(Mandatory)][string]$DcIp,
    [Parameter(Mandatory)][string]$OUPath,
    [Parameter(Mandatory)][string]$LocalAdmin,
    [System.Management.Automation.PSCredential]$SourceCredential,
    [string]$RollbackPath = 'C:\Phase0_Rollback',
    [switch]$NoRestart
)
$ErrorActionPreference = 'Stop'
$fail = 0
function Check($what, [scriptblock]$test) {
    try { $ok = [bool](& $test) } catch { $ok = $false }
    if ($ok) { Write-Host "[PASS] $what" } else { Write-Host "[FAIL] $what" -ForegroundColor Red; $script:fail++ }
}
function Restart-IfAllowed($msg) {
    Write-Host $msg
    if (-not $NoRestart) { Restart-Computer -Force } else { Write-Host 'Restart now (-NoRestart was given).' }
}

$cs = Get-CimInstance Win32_ComputerSystem
$current = if ($cs.PartOfDomain) { $cs.Domain } else { $null }

if ($current -and $current -ieq $DomainName) {
    Write-Host "Already a member of $DomainName. Nothing to do."
    return
}

if ($current) {
    # ---------------- Pass 1: leave the source domain ----------------
    Write-Host "Pass 1: leaving $current"
    Check "local account '$LocalAdmin' exists and is enabled" { (Get-LocalUser -Name $LocalAdmin).Enabled }
    Check "'$LocalAdmin' is in the local Administrators group" {
        Get-LocalGroupMember -SID 'S-1-5-32-544' | Where-Object { $_.Name -like "*\$LocalAdmin" -and $_.PrincipalSource -eq 'Local' }
    }
    if ($fail -gt 0) { throw "Fix the local admin account first: after leaving $current it is the only way to log on." }
    $answer = Read-Host "Do you know the password of local account '$LocalAdmin'? (yes/no)"
    if ($answer -ne 'yes') { throw "Set it first: net user $LocalAdmin *" }

    New-Item -ItemType Directory -Force -Path $RollbackPath | Out-Null
    $ifIndex = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Sort-Object RouteMetric | Select-Object -First 1).InterfaceIndex
    [pscustomobject]@{
        ComputerName   = $env:COMPUTERNAME
        SourceDomain   = $current
        InterfaceIndex = $ifIndex
        DnsServers     = @((Get-DnsClientServerAddress -InterfaceIndex $ifIndex -AddressFamily IPv4).ServerAddresses)
        TargetDomain   = $DomainName
        Date           = (Get-Date).ToString('s')
    } | ConvertTo-Json | Set-Content -Encoding UTF8 (Join-Path $RollbackPath 'state.json')
    if (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue) {
        foreach ($v in Get-BitLockerVolume | Where-Object { $_.ProtectionStatus -eq 'On' }) {
            $v.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' } |
                Select-Object @{n = 'Volume'; e = { $v.MountPoint } }, KeyProtectorId, RecoveryPassword |
                Export-Csv -NoTypeInformation -Append (Join-Path $RollbackPath 'bitlocker-recovery.csv')
        }
    }
    Write-Host "Rollback data saved to $RollbackPath - copy it off this machine now."

    $p = @{ WorkgroupName = 'PHASE0'; Force = $true }
    if ($SourceCredential) { $p.UnjoinDomainCredential = $SourceCredential }
    Remove-Computer @p
    Restart-IfAllowed "Left $current. After the restart, log on as .\$LocalAdmin and run this script again."
    return
}

# ---------------- Pass 2: join the Samba domain ----------------
Write-Host "Pass 2: joining $DomainName"
$ifIndex = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Sort-Object RouteMetric | Select-Object -First 1).InterfaceIndex
Set-DnsClientServerAddress -InterfaceIndex $ifIndex -ServerAddresses $DcIp
Clear-DnsClientCache
Write-Host "DNS server set to $DcIp on interface $ifIndex"

Check "SRV _ldap._tcp.dc._msdcs.$DomainName" { Resolve-DnsName "_ldap._tcp.dc._msdcs.$DomainName" -Type SRV -DnsOnly }
Check "SRV _kerberos._tcp.$DomainName"       { Resolve-DnsName "_kerberos._tcp.$DomainName" -Type SRV -DnsOnly }
foreach ($port in 88, 135, 389, 445, 464) {
    Check "TCP $port on $DcIp" { (Test-NetConnection $DcIp -Port $port -WarningAction SilentlyContinue).TcpTestSucceeded }
}
Check "clock within 5 minutes of the DC" {
    $line = w32tm /stripchart /computer:$DcIp /samples:1 /dataonly | Select-String -Pattern '[+-]\d+\.\d+s' | Select-Object -Last 1
    if (-not $line) { return $false }
    [math]::Abs([double](($line.Matches[0].Value) -replace 's', '')) -lt 300
}
if ($fail -gt 0) { throw "$fail pre-check(s) failed; fix them before joining (DNS still points at $DcIp)." }

$cred = Get-Credential -Message "Administrator of $DomainName (e.g. $($DomainName.Split('.')[0].ToUpper())\Administrator)"
Add-Computer -DomainName $DomainName -OUPath $OUPath -Credential $cred -Force
Restart-IfAllowed "Joined $DomainName in $OUPath. After the restart, log on as a $DomainName user."
