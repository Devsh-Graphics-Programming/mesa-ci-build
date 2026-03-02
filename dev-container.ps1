param(
  [string]$Name = 'mesa-llvmpipe-dev',
  [string]$Image = 'registry.freedesktop.org/mesa/mesa/windows/x86_64_build:20251120-bison--20251120-bison'
)

$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$cacheRoot = Join-Path $root '_container'
$buildHost = Join-Path $cacheRoot 'build'
$depsDebugHost = Join-Path $cacheRoot 'mesa-deps-debug'

New-Item -ItemType Directory -Force -Path $buildHost | Out-Null
New-Item -ItemType Directory -Force -Path $depsDebugHost | Out-Null

$exists = docker ps -a --format "{{.Names}}" | Where-Object { $_ -eq $Name }
if (-not $exists) {
  Write-Host "Creating container $Name"
  $mountRepo = "type=bind,source=$root,target=C:/workspace"
  $mountBuild = "type=bind,source=$buildHost,target=C:/build"
  $mountDepsDebug = "type=bind,source=$depsDebugHost,target=C:/mesa-deps-debug"
  docker run --isolation=process -dit --name $Name --mount $mountRepo --mount $mountBuild --mount $mountDepsDebug -w C:/workspace $Image pwsh -NoProfile -ExecutionPolicy RemoteSigned | Out-Null
} else {
  $running = docker ps --format "{{.Names}}" | Where-Object { $_ -eq $Name }
  if (-not $running) {
    Write-Host "Starting container $Name"
    docker start $Name | Out-Null
  }
}

Write-Host "Container ready: $Name"
