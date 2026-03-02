param(
  [string]$ArtifactsRoot = "",
  [int]$VkCubeSeconds = 180,
  [ValidateSet("all","release","debug")][string]$Config = "all"
)

$ErrorActionPreference = "Stop"

function Find-VulkanSdkTool {
  param([Parameter(Mandatory = $true)][string]$Name)

  $candidates = New-Object "System.Collections.Generic.List[string]"
  if (-not [string]::IsNullOrWhiteSpace($env:VULKAN_SDK)) {
    [void]$candidates.Add((Join-Path $env:VULKAN_SDK ("Bin\\{0}.exe" -f $Name)))
  }

  $sdkRoot = "C:\\VulkanSDK"
  if (Test-Path $sdkRoot) {
    foreach ($dir in (Get-ChildItem -Path $sdkRoot -Directory | Sort-Object Name -Descending)) {
      [void]$candidates.Add((Join-Path $dir.FullName ("Bin\\{0}.exe" -f $Name)))
    }
  }

  foreach ($path in $candidates) {
    if (Test-Path $path) { return $path }
  }
  return $null
}

function Require-Command {
  param([Parameter(Mandatory = $true)][string]$Name)
  $cmd = Get-Command $Name -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Path }
  if ($Name -eq "vulkaninfo" -or $Name -eq "vkcube") {
    $sdkTool = Find-VulkanSdkTool -Name $Name
    if ($sdkTool) { return $sdkTool }
  }
  throw "Required command not found: $Name"
}

function Get-MeaningfulErrorLines {
  param([Parameter(Mandatory = $true)][string]$Text)

  return @($Text -split "`r?`n" | Where-Object {
    $_ -match "(?i)\berror\b" -and
    $_ -notmatch "(?i)\berrors?\s*:\s*0\b" -and
    $_ -notmatch "(?i)\bno\s+errors?\b"
  })
}

function Run-Smoke {
  param(
    [Parameter(Mandatory = $true)][string]$Config,
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$LogRoot
  )

  $vulkaninfoPath = Require-Command "vulkaninfo"
  $vkcubePath = Require-Command "vkcube"

  $binDir = Join-Path $Root "bin"
  $icd = Join-Path $Root "share\\vulkan\\icd.d\\lvp_icd.x86_64.json"
  if (-not (Test-Path $icd)) { throw "Missing ICD JSON for ${Config}: $icd" }

  $logDir = Join-Path $LogRoot $Config
  New-Item -ItemType Directory -Force -Path $logDir | Out-Null

  $summaryLog = Join-Path $logDir "vulkaninfo-summary.log"
  $cubeStdout = Join-Path $logDir "vkcube.stdout.log"
  $cubeStderr = Join-Path $logDir "vkcube.stderr.log"

  $prevIcd = $env:VK_ICD_FILENAMES
  $prevDriverFiles = $env:VK_DRIVER_FILES
  $prevPath = $env:PATH
  try {
    $env:VK_ICD_FILENAMES = $icd
    $env:VK_DRIVER_FILES = $icd
    $env:PATH = "$binDir;$env:PATH"

    $oldEap = $ErrorActionPreference
    try {
      $ErrorActionPreference = "Continue"
      $summary = (& $vulkaninfoPath --summary 2>&1 | Out-String)
    }
    finally {
      $ErrorActionPreference = $oldEap
    }
    Set-Content -Path $summaryLog -Value $summary -Encoding UTF8
    if ($LASTEXITCODE -ne 0) { throw "vulkaninfo --summary failed for $Config." }
    if ($summary -notmatch "(?i)llvmpipe") { throw "vulkaninfo summary does not contain llvmpipe for $Config." }

    $summaryErrors = Get-MeaningfulErrorLines -Text $summary
    if ($summaryErrors.Count -gt 0) {
      throw "vulkaninfo summary contains error lines in $summaryLog"
    }

    if (Test-Path $cubeStdout) { Remove-Item $cubeStdout -Force }
    if (Test-Path $cubeStderr) { Remove-Item $cubeStderr -Force }

    $cube = Start-Process -FilePath $vkcubePath -ArgumentList @("--c", "$VkCubeSeconds") -WorkingDirectory $binDir -PassThru -RedirectStandardOutput $cubeStdout -RedirectStandardError $cubeStderr
    if (-not $cube.WaitForExit(($VkCubeSeconds + 30) * 1000)) {
      Stop-Process -Id $cube.Id -Force -ErrorAction SilentlyContinue
      throw "vkcube timeout for $Config."
    }
    if ($cube.ExitCode -ne 0) { throw "vkcube failed with exit code $($cube.ExitCode) for $Config." }

    $cubeText = ""
    if (Test-Path $cubeStdout) { $cubeText += (Get-Content -Raw $cubeStdout) + "`n" }
    if (Test-Path $cubeStderr) { $cubeText += (Get-Content -Raw $cubeStderr) + "`n" }
    $cubeErrors = Get-MeaningfulErrorLines -Text $cubeText
    if ($cubeErrors.Count -gt 0) {
      throw "vkcube logs contain error lines in $logDir"
    }
  }
  finally {
    if ($null -eq $prevIcd) {
      Remove-Item Env:VK_ICD_FILENAMES -ErrorAction SilentlyContinue
    } else {
      $env:VK_ICD_FILENAMES = $prevIcd
    }

    if ($null -eq $prevDriverFiles) {
      Remove-Item Env:VK_DRIVER_FILES -ErrorAction SilentlyContinue
    } else {
      $env:VK_DRIVER_FILES = $prevDriverFiles
    }

    $env:PATH = $prevPath
  }
}

if ([string]::IsNullOrWhiteSpace($ArtifactsRoot)) {
  $ArtifactsRoot = Join-Path $PSScriptRoot "_artifacts"
}

$logRoot = Join-Path $ArtifactsRoot "logs"
New-Item -ItemType Directory -Force -Path $logRoot | Out-Null

if ($Config -eq "all" -or $Config -eq "release") {
  $releaseRoot = Join-Path $ArtifactsRoot "release"
  if (-not (Test-Path $releaseRoot)) { throw "Missing release artifacts: $releaseRoot" }
  Run-Smoke -Config "release" -Root $releaseRoot -LogRoot $logRoot
}

if ($Config -eq "all" -or $Config -eq "debug") {
  $debugRoot = Join-Path $ArtifactsRoot "debug"
  if (-not (Test-Path $debugRoot)) { throw "Missing debug artifacts: $debugRoot" }
  Run-Smoke -Config "debug" -Root $debugRoot -LogRoot $logRoot
}

Write-Host "Smoke tests completed. Logs in $logRoot"
