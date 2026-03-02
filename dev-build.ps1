param(
  [ValidateSet('release','debug')][string]$Config = 'release',
  [string]$Name = 'mesa-llvmpipe-dev'
)

$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$artifacts = Join-Path $root '_artifacts'
$logRoot = Join-Path $artifacts 'logs'
New-Item -ItemType Directory -Force -Path $logRoot | Out-Null

& "$root\\dev-container.ps1" -Name $Name

Write-Host "Building in container $Name ($Config)"
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logFile = Join-Path $logRoot ("build-{0}-{1}.log" -f $Config, $stamp)
$containerLog = "C:\workspace\_artifacts\logs\build-$Config-$stamp.log"
$cmd = "C:\workspace\container\build.ps1 -Config $Config -SkipMesaTestsForDebug *> `"$containerLog`""
docker exec $Name pwsh -NoProfile -ExecutionPolicy RemoteSigned -Command $cmd
if ($LASTEXITCODE -ne 0) { throw "container build failed with exit code $LASTEXITCODE" }

Write-Host "Exporting artifacts to $artifacts"
docker exec $Name pwsh -NoProfile -ExecutionPolicy RemoteSigned -File C:\workspace\container\export.ps1 -OutDir C:\workspace\_artifacts -Config $Config
if ($LASTEXITCODE -ne 0) { throw "container export failed with exit code $LASTEXITCODE" }
