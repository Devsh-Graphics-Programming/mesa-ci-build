param(
  [ValidateSet('release','debug')][string]$Config = 'release',
  [string]$Name = 'mesa-llvmpipe-dev'
)

$ErrorActionPreference = 'Stop'

& "$PSScriptRoot\\dev-build.ps1" -Config $Config -Name $Name
& "$PSScriptRoot\\smoke-host.ps1" -Config $Config
