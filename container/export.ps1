param(
  [string]$OutDir = 'C:\out',
  [ValidateSet('release','debug')][string]$Config = ''
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Config)) {
  $Config = $env:BUILD_CONFIG
}
if ([string]::IsNullOrWhiteSpace($Config)) {
  throw 'BUILD_CONFIG is required.'
}

$src = "C:\artifacts\$Config"
if (-not (Test-Path $src)) { throw "Missing artifacts: $src" }

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$dst = Join-Path $OutDir $Config
New-Item -ItemType Directory -Force -Path $dst | Out-Null

& robocopy $src $dst /E /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy failed with exit code $LASTEXITCODE" }
