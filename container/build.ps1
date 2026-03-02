param(
  [ValidateSet('release','debug')][string]$Config = 'release',
  [switch]$SkipMesaTestsForDebug
)

$ErrorActionPreference = 'Stop'

$scriptPath = 'C:\build\llvm-mesa-lvp-win.ps1'
if (-not (Test-Path $scriptPath)) {
  $alt = Join-Path $PSScriptRoot '..\llvm-mesa-lvp-win.ps1'
  if (Test-Path $alt) {
    $scriptPath = $alt
  } else {
    throw "Missing build script: $scriptPath"
  }
}

function Add-PathIfExists {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (Test-Path $Path) { $env:PATH = "$Path;$env:PATH" }
}

if ($env:LOCALAPPDATA) {
  Add-PathIfExists "$env:LOCALAPPDATA\Microsoft\WinGet\Links"
  Add-PathIfExists "$env:LOCALAPPDATA\Programs\Python\Python313\Scripts"
  Add-PathIfExists "$env:LOCALAPPDATA\Programs\Python\Python313"
}
Add-PathIfExists "$env:ProgramFiles\Git\cmd"
Add-PathIfExists "$env:ProgramFiles\CMake\bin"
Add-PathIfExists "$env:ProgramFiles\Ninja"
Add-PathIfExists "C:\Ninja"
Add-PathIfExists "C:\CMake\bin"
Add-PathIfExists "C:\Git\cmd"

$root = 'C:\build\work'
$outRoot = 'C:\artifacts'
$depsRelease = 'C:\mesa-deps'
$depsDebug = 'C:\mesa-deps-debug'

$mesaRepo = 'https://gitlab.freedesktop.org/mesa/mesa.git'
$mesaRef = 'c46902660461b38150133d43719a456926ec5dfb'
$llvmVersion = '19.1.7'
$spirvTranslatorVersion = '19.1.10'
$vulkanSdkVersion = '1.4.304.0'

New-Item -ItemType Directory -Force -Path $root | Out-Null
New-Item -ItemType Directory -Force -Path $outRoot | Out-Null

$common = @{
  Root = $root
  MesaRepo = $mesaRepo
  MesaRef = $mesaRef
  LlvmVersion = $llvmVersion
  SpirvLlvmTranslatorVersion = $spirvTranslatorVersion
  VulkanSdkVersion = $vulkanSdkVersion
  DepsPrefixRelease = $depsRelease
  DepsPrefixDebug = $depsDebug
  MesonVersion = ''
  VCToolsVersionMesa = ''
  Jobs = 0
  SkipSmoke = $true
  SkipDeps = $true
}

if ($env:MESA_PRUNE_LLVM_OBJ -and $env:MESA_PRUNE_LLVM_OBJ -ne '0') {
  $common.PruneLlvmObjAfterBuild = $true
}

if ($Config -eq 'release') {
  & $scriptPath @common -Configs release -SkipLlvm -SkipLibclc -SkipMesaTests
} else {
  if ($SkipMesaTestsForDebug) {
    & $scriptPath @common -Configs debug -SkipMesaTests
  } else {
    & $scriptPath @common -Configs debug
  }
}

$targetOut = Join-Path $outRoot $Config
New-Item -ItemType Directory -Force -Path $targetOut | Out-Null
Copy-Item -Recurse -Force (Join-Path $root "$Config\_install\*") $targetOut
if ($Config -eq 'debug') {
  $llvmPdbRoot = Join-Path $targetOut 'llvm-pdb'
  New-Item -ItemType Directory -Force -Path $llvmPdbRoot | Out-Null
  if (Test-Path C:\build\work\debug\llvm-build) {
    & robocopy C:\build\work\debug\llvm-build $llvmPdbRoot *.pdb /S /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy llvm pdb failed with exit code $LASTEXITCODE" }
  }
}
