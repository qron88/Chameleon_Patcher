<#
.SYNOPSIS
  Runs the Pester suites in this folder and exits with the number of failed tests.

.DESCRIPTION
  Both suites use Pester 3.4 syntax ("Should Be"), the version that ships with Windows PowerShell
  5.1, so nothing has to be installed. Pester 5 changed the assertion syntax, so a newer Pester is
  deliberately not loaded even if one is installed.

  The suites build their own tiny driver packages, certificates and catalogs in %TEMP%; nothing
  touches a certificate store, the real Drivers\ folder or the network. Run before every commit
  that touches Scripts\ - about five seconds.

.EXAMPLE
  .\Tests\Run.ps1
#>
[CmdletBinding()]
param([switch]$Quiet)

$ErrorActionPreference = 'Stop'

$pester = Get-Module -ListAvailable Pester | Where-Object { $_.Version -ge [version]'3.4' -and $_.Version -lt [version]'5.0' } |
    Sort-Object Version -Descending | Select-Object -First 1
if (-not $pester) { throw "Pester 3.4 - 4.x not found. Windows PowerShell 5.1 ships Pester 3.4.0; the suites do not run under Pester 5." }
Import-Module $pester.Path -Force

$params = @{ Path = $PSScriptRoot; PassThru = $true }
if ($Quiet) { $params['Quiet'] = $true }
$result = Invoke-Pester @params

Write-Host ""
Write-Host ("Pester {0}: {1} passed, {2} failed." -f $pester.Version, $result.PassedCount, $result.FailedCount) -ForegroundColor $(if ($result.FailedCount) { 'Red' } else { 'Green' })
exit $result.FailedCount
