<#
.SYNOPSIS
  Rollback for Move-WorkstationToSamba.ps1: return the workstation to its
  source domain (e.g. mydomain.com).

.DESCRIPTION
  Run elevated. Reads C:\Phase0_Rollback\state.json written by
  Move-WorkstationToSamba.ps1. Two passes, with a restart in between:

  Pass 1 (computer is in the Samba domain): leaves it to workgroup PHASE0
         (disables the Samba computer account when -SambaCredential is given).
  Pass 2 (computer is in a workgroup; log on with the local admin): restores
         the original DNS servers and rejoins the source domain.

  Users get their original domain profiles back on the next logon.

.EXAMPLE
  .\Restore-WorkstationDomain.ps1          # run once per pass
#>
param(
    [string]$RollbackPath = 'C:\Phase0_Rollback',
    [System.Management.Automation.PSCredential]$SambaCredential,
    [switch]$NoRestart
)
$ErrorActionPreference = 'Stop'
$stateFile = Join-Path $RollbackPath 'state.json'
if (-not (Test-Path $stateFile)) { throw "$stateFile not found; it is written by Move-WorkstationToSamba.ps1 pass 1." }
$state = Get-Content -Raw $stateFile | ConvertFrom-Json

$cs = Get-CimInstance Win32_ComputerSystem
$current = if ($cs.PartOfDomain) { $cs.Domain } else { $null }

if ($current -and $current -ieq $state.SourceDomain) {
    Write-Host "Already a member of $($state.SourceDomain). Nothing to do."
    return
}

if ($current) {
    Write-Host "Pass 1: leaving $current"
    $p = @{ WorkgroupName = 'PHASE0'; Force = $true }
    if ($SambaCredential) { $p.UnjoinDomainCredential = $SambaCredential }
    Remove-Computer @p
    Write-Host "After the restart, log on with the local admin and run this script again."
    if (-not $NoRestart) { Restart-Computer -Force }
    return
}

Write-Host "Pass 2: restoring DNS and joining $($state.SourceDomain)"
$ifIndex = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Sort-Object RouteMetric | Select-Object -First 1).InterfaceIndex
if (@($state.DnsServers).Count -gt 0) {
    Set-DnsClientServerAddress -InterfaceIndex $ifIndex -ServerAddresses @($state.DnsServers)
} else {
    Set-DnsClientServerAddress -InterfaceIndex $ifIndex -ResetServerAddresses
}
Clear-DnsClientCache
Resolve-DnsName "_ldap._tcp.dc._msdcs.$($state.SourceDomain)" -Type SRV -DnsOnly | Out-Null
$cred = Get-Credential -Message "Account allowed to join computers to $($state.SourceDomain)"
Add-Computer -DomainName $state.SourceDomain -Credential $cred -Force
Write-Host "Rejoined $($state.SourceDomain)."
if (-not $NoRestart) { Restart-Computer -Force }
