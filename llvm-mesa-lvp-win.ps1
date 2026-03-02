[CmdletBinding()]
param(
    [string]$Root = "",
    [string]$MesaRepo = "https://gitlab.freedesktop.org/mesa/mesa.git",
    [string]$MesaBranch = "main",
    [string]$MesaRef = "c46902660461b38150133d43719a456926ec5dfb",
    [string]$LlvmVersion = "19.1.7",
    [string]$SpirvLlvmTranslatorVersion = "19.1.10",
    [string]$VulkanSdkVersion = "1.4.304.0",
    [ValidateSet("debug", "release")][string[]]$Configs = @("debug", "release"),
    [int]$Jobs = 0,
    [int]$MesaTestJobs = 32,
    [string]$DepsRoot = "",
    [string]$DepsPrefixRelease = "",
    [string]$DepsPrefixDebug = "",
    [string[]]$ExtraMesonArgs = @(),
    [string]$VcVarsVerLlvm = "14.29",
    [string]$VcVarsVerMesa = "14",
    [string]$VCToolsVersionMesa = "",
    [string]$WinFlexBisonVersion = "2.5.24",
    [string]$MesonVersion = "1.9.1",
    [switch]$SkipMesaTests,
    [switch]$SkipDeps,
    [switch]$SkipLlvm,
    [switch]$SkipLibclc,
    [switch]$SkipSmoke,
    [switch]$CopyLlvmDlls,
    [switch]$PruneLlvmObjAfterBuild,
    [switch]$Clean
)

$ErrorActionPreference = "Stop"
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}
$env:PYTHONUTF8 = 1
$script:MesonPython = $null

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [Parameter()][string[]]$Args = @(),
        [Parameter()][string]$Step = ""
    )

    if ([string]::IsNullOrWhiteSpace($Step)) { $Step = $Exe }
    Write-Host (">> {0} {1}" -f $Exe, ($Args -join " ")) -ForegroundColor DarkGray
    $oldEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & $Exe @Args 2>&1 | Out-Host
    }
    finally {
        $ErrorActionPreference = $oldEap
    }
    if ($LASTEXITCODE -ne 0) {
        throw "$Step failed with exit code $LASTEXITCODE."
    }
}

function Require-Command {
    param([Parameter(Mandatory = $true)][string]$Name)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $cmd) { throw "Required command not found: $Name" }
    return $cmd.Path
}

function Get-MesonCommand {
    if ($script:MesonPython -and (Test-Path $script:MesonPython)) {
        return @{
            Exe = $script:MesonPython
            Prefix = @("-m", "mesonbuild.mesonmain")
        }
    }
    $mesonCmd = Get-Command "meson" -ErrorAction SilentlyContinue
    if ($mesonCmd) {
        return @{
            Exe = $mesonCmd.Source
            Prefix = @()
        }
    }
    return @{
        Exe = "py"
        Prefix = @("-3", "-m", "mesonbuild.mesonmain")
    }
}

function Ensure-Meson {
    param(
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter()][string]$ToolsDir = ""
    )

    if ([string]::IsNullOrWhiteSpace($ToolsDir)) {
        $ToolsDir = Join-Path $PSScriptRoot "tools"
    }
    New-Item -ItemType Directory -Force -Path $ToolsDir | Out-Null

    $venv = Join-Path $ToolsDir ("meson-" + $Version)
    $python = Join-Path $venv "Scripts\\python.exe"
    if (Test-Path $python) { return $python }

    Invoke-Checked -Exe "py" -Args @("-3", "-m", "venv", $venv) -Step "meson venv"
    Invoke-Checked -Exe $python -Args @("-m", "pip", "install", "--upgrade", "pip") -Step "meson pip upgrade"
    Invoke-Checked -Exe $python -Args @("-m", "pip", "install", "meson==$Version", "mako", "packaging", "pyyaml", "numpy<2.0") -Step "meson pip deps"
    return $python
}

function Get-PkgConfigExe {
    $candidates = @(
        "$env:LOCALAPPDATA\\Microsoft\\WinGet\\Packages\\bloodrock.pkg-config-lite_Microsoft.Winget.Source_*\\pkg-config-lite-*\\bin\\pkg-config.exe",
        "$env:ProgramFiles\\pkg-config-lite\\bin\\pkg-config.exe",
        "$env:ProgramFiles(x86)\\pkg-config-lite\\bin\\pkg-config.exe"
    )

    foreach ($pattern in $candidates) {
        $found = Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    return $null
}

function Get-WinFlexPath {
    param([Parameter(Mandatory = $true)][string]$RequiredVersion)

    $candidates = New-Object "System.Collections.Generic.List[string]"
    $cmd = Get-Command "win_flex" -ErrorAction SilentlyContinue
    if ($cmd) { [void]$candidates.Add($cmd.Path) }

    $wingetRoot = Join-Path $env:LOCALAPPDATA "Microsoft\\WinGet\\Packages"
    if (Test-Path $wingetRoot) {
        foreach ($dir in Get-ChildItem -Path $wingetRoot -Directory -ErrorAction SilentlyContinue) {
            if ($dir.Name -like "WinFlexBison.win_flex_bison_*") {
                $exe = Join-Path $dir.FullName "win_flex.exe"
                if (Test-Path $exe) { [void]$candidates.Add($exe) }
            }
        }
    }

    foreach ($exe in $candidates | Select-Object -Unique) {
        if (-not (Test-Path $exe)) { continue }
        $verLine = & $exe --version 2>&1 | Select-Object -First 1
        if ($verLine -match [Regex]::Escape($RequiredVersion)) {
            return $exe
        }
    }

    return $null
}

function Ensure-WinFlexBison {
    param(
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter()][string]$ToolsDir = ""
    )

    if ([string]::IsNullOrWhiteSpace($ToolsDir)) {
        $ToolsDir = Join-Path $PSScriptRoot "tools"
    }
    New-Item -ItemType Directory -Force -Path $ToolsDir | Out-Null

    $root = Join-Path $ToolsDir ("win_flex_bison-" + $Version)
    $exe = Join-Path $root "win_flex.exe"
    if (Test-Path $exe) { return $exe }

    $zip = Join-Path $ToolsDir ("win_flex_bison-" + $Version + ".zip")
    if (-not (Test-Path $zip)) {
        $url = "https://github.com/lexxmark/winflexbison/releases/download/v$Version/win_flex_bison-$Version.zip"
        Invoke-WebRequest -Uri $url -OutFile $zip
    }

    New-Item -ItemType Directory -Force -Path $root | Out-Null
    Expand-Archive -Path $zip -DestinationPath $root -Force
    if (-not (Test-Path $exe)) { throw "win_flex.exe missing after extracting $zip" }
    return $exe
}

function Import-VsDevEnvironment {
    param(
        [Parameter(Mandatory = $true)][string]$StateDir,
        [Parameter()][string]$VcVarsVer = "",
        [Parameter()][string]$VsInstallPath = "",
        [Parameter()][string]$VCToolsVersion = ""
    )

    if ([string]::IsNullOrWhiteSpace($VsInstallPath)) {
        $candidates = @(
            "C:\\BuildTools",
            "${env:ProgramFiles}\\Microsoft Visual Studio\\2022\\BuildTools",
            "${env:ProgramFiles}\\Microsoft Visual Studio\\2022\\Community"
        )
        foreach ($candidate in $candidates) {
            if (Test-Path (Join-Path $candidate "Common7\\Tools\\VsDevCmd.bat")) {
                $VsInstallPath = $candidate
                break
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($VsInstallPath)) {
        $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\\Installer\\vswhere.exe"
        if (-not (Test-Path $vswhere)) { throw "vswhere not found at $vswhere" }

        $VsInstallPath = (& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($VsInstallPath)) { throw "Visual Studio C++ x64 tools not found." }
    }

    $vsDevCmd = Join-Path $VsInstallPath "Common7\\Tools\\VsDevCmd.bat"
    if (-not (Test-Path $vsDevCmd)) { throw "VsDevCmd.bat not found: $vsDevCmd" }

    $captureCmd = Join-Path $StateDir "capture_vs_env.cmd"
    $envDump = Join-Path $StateDir "vs_env.txt"
    $stderrDump = Join-Path $StateDir "vs_env.stderr.txt"

    $vcvarsArg = ""
    if (-not [string]::IsNullOrWhiteSpace($VcVarsVer)) {
        $vcvarsArg = "-vcvars_ver=$VcVarsVer"
    }

    $vcToolsLine = ""
    if (-not [string]::IsNullOrWhiteSpace($VCToolsVersion)) {
        $vcToolsLine = "set VCToolsVersion=$VCToolsVersion"
    }

@"
@echo off
$vcToolsLine
call "$vsDevCmd" -no_logo -arch=x64 -host_arch=x64 $vcvarsArg
if errorlevel 1 exit /b %errorlevel%
set
"@ | Set-Content -Path $captureCmd -Encoding ASCII

    $proc = Start-Process -FilePath "cmd.exe" -ArgumentList @("/d", "/c", "`"$captureCmd`"") -NoNewWindow -Wait -PassThru -RedirectStandardOutput $envDump -RedirectStandardError $stderrDump
    if ($proc.ExitCode -ne 0) {
        if (Test-Path $stderrDump) { Get-Content $stderrDump | Out-Host }
        throw "VsDevCmd failed with exit code $($proc.ExitCode)."
    }

    foreach ($line in Get-Content $envDump) {
        $idx = $line.IndexOf("=")
        if ($idx -le 0) { continue }
        $name = $line.Substring(0, $idx)
        $value = $line.Substring($idx + 1)
        Set-Item -Path "Env:$name" -Value $value
    }

    Remove-Item $captureCmd, $envDump, $stderrDump -ErrorAction SilentlyContinue
}

function Ensure-LlvmBootstrap {
    param(
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][string]$BootstrapDir,
        [Parameter(Mandatory = $true)][string]$DownloadDir
    )

    $existingClang = Get-ChildItem -Path $BootstrapDir -Recurse -Filter "clang-cl.exe" -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($existingClang) {
        return (Split-Path -Parent (Split-Path -Parent $existingClang.FullName))
    }

    New-Item -ItemType Directory -Force -Path $DownloadDir | Out-Null
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $BootstrapDir) | Out-Null

    $headers = @{
        "User-Agent" = "llvmpipebuildwindows"
        "Accept" = "application/vnd.github+json"
    }
    $releaseApi = "https://api.github.com/repos/llvm/llvm-project/releases/tags/llvmorg-$Version"
    $release = Invoke-RestMethod -Uri $releaseApi -Headers $headers

    $asset = $release.assets | Where-Object { $_.name -match "^clang\+llvm-$([Regex]::Escape($Version))-x86_64-pc-windows-msvc\.tar\.xz$" } | Select-Object -First 1
    if (-not $asset) {
        $asset = $release.assets | Where-Object { $_.name -match "^LLVM-$([Regex]::Escape($Version))-win64\.(exe|zip)$" } | Select-Object -First 1
    }
    if (-not $asset) {
        $asset = $release.assets | Where-Object { $_.name -match "(x86_64-pc-windows-msvc\.tar\.xz|win64\.(exe|zip))$" } | Select-Object -First 1
    }
    if (-not $asset) { throw "Could not find LLVM win64 release asset for $Version." }

    $assetPath = Join-Path $DownloadDir $asset.name
    if (-not (Test-Path $assetPath)) {
        Write-Host "Downloading $($asset.name)" -ForegroundColor Cyan
        Invoke-WebRequest -Uri $asset.browser_download_url -Headers $headers -OutFile $assetPath
    }

    if (Test-Path $BootstrapDir) { Remove-Item -Recurse -Force $BootstrapDir }
    New-Item -ItemType Directory -Force -Path $BootstrapDir | Out-Null

    if ($asset.name.ToLowerInvariant().EndsWith(".zip")) {
        Expand-Archive -Path $assetPath -DestinationPath $BootstrapDir -Force
        $clang = Get-ChildItem -Path $BootstrapDir -Recurse -Filter "clang-cl.exe" -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $clang) { throw "clang-cl.exe not found after extracting $assetPath" }
        return (Split-Path -Parent (Split-Path -Parent $clang.FullName))
    }

    if ($asset.name.ToLowerInvariant().EndsWith(".tar.xz")) {
        Invoke-Checked -Exe "tar" -Args @("-xf", $assetPath, "-C", $BootstrapDir) -Step "extract $($asset.name)"
        $clang = Get-ChildItem -Path $BootstrapDir -Recurse -Filter "clang-cl.exe" -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $clang) { throw "clang-cl.exe not found after extracting $assetPath" }
        return (Split-Path -Parent (Split-Path -Parent $clang.FullName))
    }

    $installerArgs = @("/S", "/D=$BootstrapDir")
    $proc = Start-Process -FilePath $assetPath -ArgumentList $installerArgs -Wait -PassThru
    if ($proc.ExitCode -ne 0) { throw "LLVM installer failed with exit code $($proc.ExitCode)." }
    $clangPath = Get-ChildItem -Path $BootstrapDir -Recurse -Filter "clang-cl.exe" -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $clangPath) { throw "clang-cl.exe not found in $BootstrapDir" }
    return (Split-Path -Parent (Split-Path -Parent $clangPath.FullName))
}

function Ensure-LlvmSource {
    param(
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][string]$LlvmSrcDir
    )

    $tag = "llvmorg-$Version"
    if (-not (Test-Path $LlvmSrcDir)) {
        Invoke-Checked -Exe "git" -Args @("clone", "--branch", $tag, "--depth", "1", "https://github.com/llvm/llvm-project.git", $LlvmSrcDir) -Step "llvm clone"
        return
    }

    Invoke-Checked -Exe "git" -Args @("-C", $LlvmSrcDir, "fetch", "origin", "--tags") -Step "llvm fetch"
    Invoke-Checked -Exe "git" -Args @("-C", $LlvmSrcDir, "checkout", "--detach", $tag) -Step "llvm checkout $tag"
}

function Ensure-SpirvLlvmTranslator {
    param(
        [Parameter(Mandatory = $true)][string]$LlvmSrcDir,
        [Parameter(Mandatory = $true)][string]$Version
    )

    $dst = Join-Path $LlvmSrcDir "llvm\\projects\\SPIRV-LLVM-Translator"
    $tag = "v$Version"
    if (-not (Test-Path $dst)) {
        Invoke-Checked -Exe "git" -Args @("clone", "-b", $tag, "--depth", "1", "https://github.com/KhronosGroup/SPIRV-LLVM-Translator", $dst) -Step "spirv-llvm-translator clone"
        return
    }

    Invoke-Checked -Exe "git" -Args @("-C", $dst, "fetch", "origin", "--tags") -Step "spirv-llvm-translator fetch"
    Invoke-Checked -Exe "git" -Args @("-C", $dst, "checkout", "--detach", $tag) -Step "spirv-llvm-translator checkout $tag"
}

function Ensure-CiDeps {
    param(
        [Parameter(Mandatory = $true)][string[]]$DepsInstallDirs,
        [Parameter(Mandatory = $true)][string]$DepsWorkDir,
        [Parameter(Mandatory = $true)][string]$VulkanSdkVersion,
        [Parameter(Mandatory = $true)][int]$Jobs,
        [Parameter()][switch]$Clean
    )

    if ($Clean) {
        if (Test-Path $DepsWorkDir) { Remove-Item -Recurse -Force $DepsWorkDir }
        if (Test-Path $DepsInstallDir) { Remove-Item -Recurse -Force $DepsInstallDir }
    }

    New-Item -ItemType Directory -Force -Path $DepsInstallDir, $DepsWorkDir | Out-Null
    $meson = Get-MesonCommand
    $pkgConfigExe = Get-PkgConfigExe
    $prevPath = $env:PATH
    $prevPkg = $env:PKG_CONFIG
    if ($pkgConfigExe) {
        $env:PATH = (Split-Path $pkgConfigExe) + ";" + $env:PATH
        $env:PKG_CONFIG = $pkgConfigExe
    }

    try {
        $dxInclude = Join-Path $DepsInstallDir "include\\directx\\directxconfig.h"
        if (-not (Test-Path $dxInclude)) {
            $dxDir = Join-Path $DepsWorkDir "DirectX-Headers"
            if (-not (Test-Path $dxDir)) {
                Invoke-Checked -Exe "git" -Args @("clone", "-b", "v1.618.1", "--depth=1", "https://github.com/microsoft/DirectX-Headers", $dxDir) -Step "DirectX-Headers clone"
            }
            $dxBuild = Join-Path $dxDir "build"
            New-Item -ItemType Directory -Force -Path $dxBuild | Out-Null
            Invoke-Checked -Exe $meson.Exe -Args ($meson.Prefix + @("setup", $dxBuild, $dxDir, "--backend=ninja", "-Dprefix=$DepsInstallDir", "--buildtype=release", "-Db_vscrt=mt")) -Step "DirectX-Headers setup"
            Invoke-Checked -Exe "ninja" -Args @("-C", $dxBuild, "-j", $Jobs, "install") -Step "DirectX-Headers install"
        }

    $zlibLib = Join-Path $DepsInstallDir "lib\\zlib.lib"
    if (-not (Test-Path $zlibLib)) {
        $zlibDir = Join-Path $DepsWorkDir "zlib"
        if (-not (Test-Path $zlibDir)) {
            Invoke-Checked -Exe "git" -Args @("clone", "-b", "v1.3.1", "--depth=1", "https://github.com/madler/zlib", $zlibDir) -Step "zlib clone"
            $zlibWrap = Join-Path $DepsWorkDir "zlib.zip"
            Invoke-WebRequest -Uri "https://wrapdb.mesonbuild.com/v2/zlib_1.3.1-1/get_patch" -OutFile $zlibWrap
            Expand-Archive -Path $zlibWrap -DestinationPath $zlibDir -Force
            $zlibSub = Join-Path $zlibDir "zlib-1.3.1"
            if (Test-Path $zlibSub) {
                & robocopy $zlibSub $zlibDir /E | Out-Null
                if ($LASTEXITCODE -ge 8) { throw "zlib wrap copy failed with exit code $LASTEXITCODE" }
                Remove-Item -Recurse -Force $zlibSub
            }
        }
        $zlibBuild = Join-Path $zlibDir "build"
        New-Item -ItemType Directory -Force -Path $zlibBuild | Out-Null
        Invoke-Checked -Exe $meson.Exe -Args ($meson.Prefix + @("setup", $zlibBuild, $zlibDir, "--backend=ninja", "-Dprefix=$DepsInstallDir", "--default-library=static", "--buildtype=release", "-Db_vscrt=mt")) -Step "zlib setup"
        Invoke-Checked -Exe "ninja" -Args @("-C", $zlibBuild, "-j", $Jobs, "install") -Step "zlib install"
    }

    $spvLib = Join-Path $DepsInstallDir "lib\\SPIRV-Tools.lib"
    if (-not (Test-Path $spvLib)) {
        $spvDir = Join-Path $DepsWorkDir "SPIRV-Tools"
        $tag = "vulkan-sdk-$VulkanSdkVersion"
        if (-not (Test-Path $spvDir)) {
            Invoke-Checked -Exe "git" -Args @("clone", "-b", $tag, "--depth=1", "https://github.com/KhronosGroup/SPIRV-Tools", $spvDir) -Step "SPIRV-Tools clone"
            $spvHeaders = Join-Path $spvDir "external\\SPIRV-Headers"
            Invoke-Checked -Exe "git" -Args @("clone", "-b", $tag, "--depth=1", "https://github.com/KhronosGroup/SPIRV-Headers", $spvHeaders) -Step "SPIRV-Headers clone"
        }
        $spvBuild = Join-Path $spvDir "build"
        New-Item -ItemType Directory -Force -Path $spvBuild | Out-Null
        Invoke-Checked -Exe "cmake" -Args @(
            "-S", $spvDir,
            "-B", $spvBuild,
            "-G", "Ninja",
            "-DCMAKE_BUILD_TYPE=Release",
            "-DCMAKE_POLICY_DEFAULT_CMP0091=NEW",
            "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded",
            "-DCMAKE_INSTALL_PREFIX=$DepsInstallDir"
        ) -Step "SPIRV-Tools configure"
        Invoke-Checked -Exe "ninja" -Args @("-C", $spvBuild, "-j", $Jobs, "install") -Step "SPIRV-Tools install"
    }

    $libvaLib = Join-Path $DepsInstallDir "lib\\va.lib"
    if (-not (Test-Path $libvaLib)) {
        $libvaDir = Join-Path $DepsWorkDir "libva"
        if (-not (Test-Path $libvaDir)) {
            Invoke-Checked -Exe "git" -Args @("clone", "https://github.com/intel/libva.git", $libvaDir) -Step "libva clone"
            Invoke-Checked -Exe "git" -Args @("-C", $libvaDir, "checkout", "2.21.0") -Step "libva checkout 2.21.0"
        }
        $libvaBuild = Join-Path $libvaDir "builddir"
        New-Item -ItemType Directory -Force -Path $libvaBuild | Out-Null
        Invoke-Checked -Exe $meson.Exe -Args ($meson.Prefix + @("setup", $libvaBuild, $libvaDir, "-Dprefix=$DepsInstallDir")) -Step "libva setup"
        Invoke-Checked -Exe "ninja" -Args @("-C", $libvaBuild, "-j", $Jobs, "install") -Step "libva install"
    }

        $libvaUtils = Join-Path $DepsInstallDir "bin\\vainfo.exe"
        if (-not (Test-Path $libvaUtils)) {
            $libvaUtilsDir = Join-Path $DepsWorkDir "libva-utils"
            if (-not (Test-Path $libvaUtilsDir)) {
                Invoke-Checked -Exe "git" -Args @("clone", "https://github.com/intel/libva-utils.git", $libvaUtilsDir) -Step "libva-utils clone"
                Invoke-Checked -Exe "git" -Args @("-C", $libvaUtilsDir, "checkout", "2.21.0") -Step "libva-utils checkout 2.21.0"
            }
            $libvaUtilsBuild = Join-Path $libvaUtilsDir "builddir"
            New-Item -ItemType Directory -Force -Path $libvaUtilsBuild | Out-Null
            Invoke-Checked -Exe $meson.Exe -Args ($meson.Prefix + @("setup", $libvaUtilsBuild, $libvaUtilsDir, "-Dprefix=$DepsInstallDir", "--pkg-config-path=$DepsInstallDir\\lib\\pkgconfig;$DepsInstallDir\\share\\pkgconfig")) -Step "libva-utils setup"
            Invoke-Checked -Exe "ninja" -Args @("-C", $libvaUtilsBuild, "-j", $Jobs, "install") -Step "libva-utils install"
        }
    }
    finally {
        if ($null -eq $prevPkg) { Remove-Item Env:PKG_CONFIG -ErrorAction SilentlyContinue } else { $env:PKG_CONFIG = $prevPkg }
        $env:PATH = $prevPath
    }
}

function Ensure-SpirvTools {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("debug", "release")][string]$Config,
        [Parameter(Mandatory = $true)][string]$DepsInstallDir,
        [Parameter(Mandatory = $true)][string]$DepsWorkDir,
        [Parameter(Mandatory = $true)][string]$VulkanSdkVersion,
        [Parameter(Mandatory = $true)][int]$Jobs,
        [Parameter()][switch]$Clean
    )

    $spvLib = Join-Path $DepsInstallDir "lib\\SPIRV-Tools.lib"
    if (Test-Path $spvLib) { return }

    if ($Clean) {
        $spvDir = Join-Path $DepsWorkDir "SPIRV-Tools"
        if (Test-Path $spvDir) { Remove-Item -Recurse -Force $spvDir }
    }

    $spvDir = Join-Path $DepsWorkDir "SPIRV-Tools"
    $tag = "vulkan-sdk-$VulkanSdkVersion"
    if (-not (Test-Path $spvDir)) {
        Invoke-Checked -Exe "git" -Args @("clone", "-b", $tag, "--depth=1", "https://github.com/KhronosGroup/SPIRV-Tools", $spvDir) -Step "SPIRV-Tools clone"
        $spvHeaders = Join-Path $spvDir "external\\SPIRV-Headers"
        Invoke-Checked -Exe "git" -Args @("clone", "-b", $tag, "--depth=1", "https://github.com/KhronosGroup/SPIRV-Headers", $spvHeaders) -Step "SPIRV-Headers clone"
    }

    $spvBuild = Join-Path $spvDir ("build-" + $Config)
    New-Item -ItemType Directory -Force -Path $spvBuild | Out-Null

    $cmakeConfig = if ($Config -eq "debug") { "Debug" } else { "Release" }
    $runtime = if ($Config -eq "debug") { "MultiThreadedDebug" } else { "MultiThreaded" }

    Invoke-Checked -Exe "cmake" -Args @(
        "-S", $spvDir,
        "-B", $spvBuild,
        "-G", "Ninja",
        "-DCMAKE_BUILD_TYPE=$cmakeConfig",
        "-DCMAKE_POLICY_DEFAULT_CMP0091=NEW",
        "-DCMAKE_MSVC_RUNTIME_LIBRARY=$runtime",
        "-DCMAKE_INSTALL_PREFIX=$DepsInstallDir"
    ) -Step "SPIRV-Tools configure ($cmakeConfig)"
    Invoke-Checked -Exe "ninja" -Args @("-C", $spvBuild, "-j", $Jobs, "install") -Step "SPIRV-Tools install ($cmakeConfig)"
}

function Ensure-MesaSource {
    param(
        [Parameter(Mandatory = $true)][string]$MesaSrcDir,
        [Parameter(Mandatory = $true)][string]$MesaRepo,
        [Parameter(Mandatory = $true)][string]$MesaBranch,
        [Parameter()][string]$MesaRef = ""
    )

    if (-not (Test-Path $MesaSrcDir)) {
        Invoke-Checked -Exe "git" -Args @("clone", $MesaRepo, $MesaSrcDir) -Step "mesa clone"
    }

    $origin = (& git -C $MesaSrcDir remote get-url origin 2>$null | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($origin)) {
        throw "Mesa remote origin is missing in $MesaSrcDir"
    }
    if (-not $origin.Equals($MesaRepo, [StringComparison]::OrdinalIgnoreCase)) {
        Invoke-Checked -Exe "git" -Args @("-C", $MesaSrcDir, "remote", "set-url", "origin", $MesaRepo) -Step "mesa set remote"
    }

    $mesaGitDir = Join-Path $MesaSrcDir ".git"
    if (Test-Path $mesaGitDir) {
        $lock = Join-Path $mesaGitDir "index.lock"
        if (Test-Path $lock) { Remove-Item -Force $lock }
        & git -C $MesaSrcDir reset --hard | Out-Null
        & git -C $MesaSrcDir clean -fdx | Out-Null
    }

    Invoke-Checked -Exe "git" -Args @("-C", $MesaSrcDir, "fetch", "origin", "--tags") -Step "mesa fetch"

    if (-not [string]::IsNullOrWhiteSpace($MesaRef)) {
        $resolved = $MesaRef.Trim()
        & git -C $MesaSrcDir cat-file -e "$resolved`^{commit}" 2>$null
        if ($LASTEXITCODE -ne 0) {
            & git -C $MesaSrcDir fetch origin $resolved --tags 2>$null
            & git -C $MesaSrcDir cat-file -e "$resolved`^{commit}" 2>$null
            if ($LASTEXITCODE -ne 0) {
                throw "Mesa ref '$resolved' is not available."
            }
        }
        Invoke-Checked -Exe "git" -Args @("-C", $MesaSrcDir, "checkout", "--detach", $resolved) -Step "mesa checkout $resolved"
        return
    }

    try {
        Invoke-Checked -Exe "git" -Args @("-C", $MesaSrcDir, "checkout", $MesaBranch) -Step "mesa checkout $MesaBranch"
    }
    catch {
        Invoke-Checked -Exe "git" -Args @("-C", $MesaSrcDir, "checkout", "-B", $MesaBranch, "origin/$MesaBranch") -Step "mesa create branch $MesaBranch"
    }
    Invoke-Checked -Exe "git" -Args @("-C", $MesaSrcDir, "pull", "--ff-only", "origin", $MesaBranch) -Step "mesa pull $MesaBranch"
}

function Build-Llvm {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("debug", "release")][string]$Config,
        [Parameter(Mandatory = $true)][string]$LlvmSrcDir,
        [Parameter(Mandatory = $true)][string]$BuildDir,
        [Parameter(Mandatory = $true)][string]$InstallDir,
        [Parameter(Mandatory = $true)][int]$Jobs,
        [Parameter()][switch]$Clean,
        [Parameter()][switch]$PruneLlvmObjAfterBuild
    )

    $cmakeConfig = if ($Config -eq "debug") { "Debug" } else { "Release" }
    $runtime = if ($Config -eq "debug") { "MultiThreadedDebug" } else { "MultiThreaded" }
    if ($Clean -and (Test-Path $BuildDir)) { Remove-Item -Recurse -Force $BuildDir }
    New-Item -ItemType Directory -Force -Path $BuildDir, $InstallDir | Out-Null

    $cfgArgs = @(
        "-S", (Join-Path $LlvmSrcDir "llvm"),
        "-B", $BuildDir,
        "-G", "Ninja",
        "-DCMAKE_BUILD_TYPE=$cmakeConfig",
        "-DCMAKE_MSVC_RUNTIME_LIBRARY=$runtime",
        "-DCMAKE_PREFIX_PATH=$InstallDir",
        "-DCMAKE_INSTALL_PREFIX=$InstallDir",
        "-DCMAKE_CXX_FLAGS=/utf-8",
        "-DLLVM_ENABLE_PROJECTS=clang",
        "-DLLVM_TARGETS_TO_BUILD=AMDGPU;X86",
        "-DLLVM_OPTIMIZED_TABLEGEN=TRUE",
        "-DLLVM_ENABLE_ASSERTIONS=TRUE",
        "-DLLVM_INCLUDE_UTILS=OFF",
        "-DLLVM_INCLUDE_RUNTIMES=OFF",
        "-DLLVM_INCLUDE_TESTS=OFF",
        "-DLLVM_INCLUDE_EXAMPLES=OFF",
        "-DLLVM_INCLUDE_GO_TESTS=OFF",
        "-DLLVM_INCLUDE_BENCHMARKS=OFF",
        "-DLLVM_BUILD_LLVM_C_DYLIB=OFF",
        "-DLLVM_ENABLE_DIA_SDK=OFF",
        "-DCLANG_BUILD_TOOLS=ON",
        "-DLLVM_SPIRV_INCLUDE_TESTS=OFF",
        "-DLLVM_ENABLE_ZLIB=OFF",
        "-Wno-dev"
    )

    Invoke-Checked -Exe "cmake" -Args $cfgArgs -Step "llvm configure ($cmakeConfig)"
    if ($PruneLlvmObjAfterBuild -and $Config -eq "debug") {
        Invoke-Checked -Exe "ninja" -Args @("-C", $BuildDir, "-j", $Jobs) -Step "llvm build ($cmakeConfig)"
        Write-Host "Pruning LLVM object files" -ForegroundColor DarkGray
        Get-ChildItem -Path $BuildDir -Include *.obj,*.pch -Recurse -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        Invoke-Checked -Exe "ninja" -Args @("-C", $BuildDir, "-j", $Jobs, "install") -Step "llvm install ($cmakeConfig)"
    }
    else {
        Invoke-Checked -Exe "ninja" -Args @("-C", $BuildDir, "-j", $Jobs, "install") -Step "llvm build+install ($cmakeConfig)"
    }

    $llvmConfig = Join-Path $InstallDir "bin\llvm-config.exe"
    if (-not (Test-Path $llvmConfig)) { throw "Missing llvm-config.exe: $llvmConfig" }

    return @{
        Config = $Config
        CMakeConfig = $cmakeConfig
        Runtime = $runtime
        BuildDir = $BuildDir
        InstallDir = $InstallDir
        LlvmConfig = $llvmConfig
    }
}

function Build-Libclc {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("debug", "release")][string]$Config,
        [Parameter(Mandatory = $true)][string]$LlvmSrcDir,
        [Parameter(Mandatory = $true)][string]$BuildDir,
        [Parameter(Mandatory = $true)][string]$InstallDir,
        [Parameter(Mandatory = $true)][int]$Jobs,
        [Parameter()][switch]$Clean
    )

    $cmakeConfig = if ($Config -eq "debug") { "Debug" } else { "Release" }
    $runtime = if ($Config -eq "debug") { "MultiThreadedDebug" } else { "MultiThreaded" }

    if ($Clean -and (Test-Path $BuildDir)) { Remove-Item -Recurse -Force $BuildDir }
    New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null

    $cfgArgs = @(
        "-S", (Join-Path $LlvmSrcDir "libclc"),
        "-B", $BuildDir,
        "-G", "Ninja",
        "-DCMAKE_BUILD_TYPE=$cmakeConfig",
        "-DCMAKE_CXX_FLAGS=-m64",
        "-DCMAKE_POLICY_DEFAULT_CMP0091=NEW",
        "-DCMAKE_MSVC_RUNTIME_LIBRARY=$runtime",
        "-DCMAKE_INSTALL_PREFIX=$InstallDir",
        "-DLIBCLC_TARGETS_TO_BUILD=spirv-mesa3d-;spirv64-mesa3d-"
    )

    Invoke-Checked -Exe "cmake" -Args $cfgArgs -Step "libclc configure ($cmakeConfig)"
    Invoke-Checked -Exe "ninja" -Args @("-C", $BuildDir, "-j", $Jobs, "install") -Step "libclc build+install ($cmakeConfig)"
}

function Build-Mesa {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("debug", "release")][string]$Config,
        [Parameter(Mandatory = $true)][string]$MesaSrcDir,
        [Parameter(Mandatory = $true)][string]$BuildDir,
        [Parameter(Mandatory = $true)][string]$InstallDir,
        [Parameter(Mandatory = $true)][string[]]$DepsInstallDirs,
        [Parameter(Mandatory = $true)][int]$Jobs,
        [Parameter(Mandatory = $true)][int]$MesaTestJobs,
        [Parameter()][string[]]$ExtraMesonArgs = @(),
        [Parameter()][switch]$SkipMesaTests,
        [Parameter()][switch]$Clean
    )

    $mesaBuildType = if ($Config -eq "debug") { "debug" } else { "release" }
    $vscrt = if ($Config -eq "debug") { "mtd" } else { "mt" }
    $env:VULKAN_SDK_VERSION = $VulkanSdkVersion

    if ($Clean -and (Test-Path $BuildDir)) { Remove-Item -Recurse -Force $BuildDir }
    if ($Clean -and (Test-Path $InstallDir)) { Remove-Item -Recurse -Force $InstallDir }
    New-Item -ItemType Directory -Force -Path $BuildDir, $InstallDir | Out-Null

    Write-Output "*" > (Join-Path $BuildDir ".gitignore")
    Write-Output "*" > (Join-Path $InstallDir ".gitignore")

    $depsList = @($DepsInstallDirs | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    if ($depsList.Count -eq 0) { throw "DepsInstallDirs is empty for $Config." }
    $cmakePrefix = ($depsList -join ";")
    $pkgPaths = New-Object "System.Collections.Generic.List[string]"
    foreach ($dep in $depsList) {
        [void]$pkgPaths.Add((Join-Path $dep "lib\\pkgconfig"))
        [void]$pkgPaths.Add((Join-Path $dep "share\\pkgconfig"))
    }
    $pkgConfigPath = (@($pkgPaths | Select-Object -Unique) -join ";")

    $setupOptions = @(
        "--default-library=shared",
        "--buildtype=$mesaBuildType",
        "--wrap-mode=nodownload",
        "-Db_ndebug=false",
        "-Db_vscrt=$vscrt",
        "--cmake-prefix-path=$cmakePrefix",
        "--pkg-config-path=$pkgConfigPath",
        "--prefix=$InstallDir",
        "-Dllvm=enabled",
        "-Dshared-llvm=disabled",
        "-Dvulkan-drivers=swrast,amd,microsoft-experimental",
        "-Dgallium-drivers=llvmpipe,softpipe,d3d12,zink,virgl",
        "-Dgallium-va=enabled",
        "-Dgallium-d3d10umd=true",
        "-Dgallium-mediafoundation=enabled",
        "-Dvideo-codecs=all",
        "-Dmediafoundation-codecs=all",
        "-Dmediafoundation-store-dll=false",
        "-Dgallium-mediafoundation-test=false",
        "-Dgles1=enabled",
        "-Dgles2=enabled",
        "-Dgallium-rusticl=false",
        "-Dmicrosoft-clc=enabled",
        "-Dstatic-libclc=all",
        "-Dspirv-to-dxil=true",
        "-Dbuild-tests=true",
        "-Dwerror=true",
        "-Dwarning_level=2"
    )
    if ($ExtraMesonArgs.Count -gt 0) {
        $setupOptions += $ExtraMesonArgs
    }

    $setupArgs = @("setup")
    if (Test-Path (Join-Path $BuildDir "meson-private\\coredata.dat")) {
        $setupArgs += @("--reconfigure", "--clearcache")
        $setupArgs += $setupOptions
        $setupArgs += @($BuildDir, $MesaSrcDir)
    }
    else {
        $setupArgs += $setupOptions
        $setupArgs += @($BuildDir, $MesaSrcDir)
    }

    $flexExe = $null
    if (-not [string]::IsNullOrWhiteSpace($WinFlexBisonVersion)) {
        $flexExe = Get-WinFlexPath -RequiredVersion $WinFlexBisonVersion
        if (-not $flexExe) {
            $flexExe = Ensure-WinFlexBison -Version $WinFlexBisonVersion -ToolsDir $toolsDir
        }
        if (-not $flexExe) { throw "win_flex $WinFlexBisonVersion not found. Install WinFlexBison.win_flex_bison $WinFlexBisonVersion or set -WinFlexBisonVersion ''." }
    }

    $meson = Get-MesonCommand
    $pkgConfigExe = Get-PkgConfigExe
    $prevPath = $env:PATH
    $prevPkg = $env:PKG_CONFIG
    if ($flexExe) {
        $env:PATH = (Split-Path $flexExe) + ";" + $env:PATH
    }
    if ($pkgConfigExe) {
        $env:PATH = (Split-Path $pkgConfigExe) + ";" + $env:PATH
        $env:PKG_CONFIG = $pkgConfigExe
    }
    try {
        Invoke-Checked -Exe $meson.Exe -Args ($meson.Prefix + $setupArgs) -Step "mesa setup ($Config)"
        Invoke-Checked -Exe $meson.Exe -Args ($meson.Prefix + @("install", "-C", $BuildDir)) -Step "mesa install ($Config)"
        if (-not $SkipMesaTests) {
            Invoke-Checked -Exe $meson.Exe -Args ($meson.Prefix + @("test", "-C", $BuildDir, "--num-processes", $MesaTestJobs, "--print-errorlogs")) -Step "mesa test ($Config)"
        }
    }
    finally {
        if ($null -eq $prevPkg) { Remove-Item Env:PKG_CONFIG -ErrorAction SilentlyContinue } else { $env:PKG_CONFIG = $prevPkg }
        $env:PATH = $prevPath
    }

    Copy-Item (Join-Path $MesaSrcDir ".gitlab-ci\\windows\\piglit_run.ps1") -Destination $InstallDir -ErrorAction SilentlyContinue
    Copy-Item (Join-Path $MesaSrcDir ".gitlab-ci\\windows\\spirv2dxil_check.ps1") -Destination $InstallDir -ErrorAction SilentlyContinue
    Copy-Item (Join-Path $MesaSrcDir ".gitlab-ci\\windows\\spirv2dxil_run.ps1") -Destination $InstallDir -ErrorAction SilentlyContinue
    Copy-Item (Join-Path $MesaSrcDir ".gitlab-ci\\windows\\deqp_runner_run.ps1") -Destination $InstallDir -ErrorAction SilentlyContinue
    Copy-Item (Join-Path $MesaSrcDir ".gitlab-ci\\windows\\vainfo_run.ps1") -Destination $InstallDir -ErrorAction SilentlyContinue

    Push-Location $MesaSrcDir
    try {
        Get-ChildItem -Recurse -Filter "ci" | Get-ChildItem -Include "*.txt","*.toml" | Copy-Item -Destination $InstallDir -ErrorAction SilentlyContinue
    }
    finally {
        Pop-Location
    }

    $driver = Join-Path $BuildDir "src\\gallium\\targets\\lavapipe\\vulkan_lvp.dll"
    $icd = Join-Path $BuildDir "src\\gallium\\targets\\lavapipe\\lvp_devenv_icd.x86_64.json"
    if (-not (Test-Path $driver)) { throw "Missing Mesa driver: $driver" }
    if (-not (Test-Path $icd)) { throw "Missing Mesa ICD JSON: $icd" }

    return @{
        Config = $Config
        BuildDir = $BuildDir
        InstallDir = $InstallDir
        Driver = $driver
        Icd = $icd
        Vscrt = $vscrt
    }
}

function Copy-LlvmRuntimeDlls {
    param(
        [Parameter(Mandatory = $true)][string]$LlvmInstallDir,
        [Parameter(Mandatory = $true)][string]$DriverDir
    )

    $binDir = Join-Path $LlvmInstallDir "bin"
    if (-not (Test-Path $binDir)) { return @() }

    $copied = New-Object "System.Collections.Generic.List[string]"
    foreach ($dll in Get-ChildItem -Path $binDir -Filter "LLVM*.dll" -File -ErrorAction SilentlyContinue) {
        Copy-Item -Path $dll.FullName -Destination (Join-Path $DriverDir $dll.Name) -Force
        [void]$copied.Add($dll.Name)
    }
    return $copied
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
        [Parameter(Mandatory = $true)][hashtable]$MesaResult,
        [Parameter(Mandatory = $true)][hashtable]$LlvmResult,
        [Parameter(Mandatory = $true)][string]$LogRoot
    )

    $vulkaninfoPath = Require-Command "vulkaninfo"
    $vkcubePath = Require-Command "vkcube"

    $logDir = Join-Path $LogRoot ("{0}" -f $MesaResult.Config)
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null

    $summaryLog = Join-Path $logDir "vulkaninfo-summary.log"
    $cubeStdout = Join-Path $logDir "vkcube.stdout.log"
    $cubeStderr = Join-Path $logDir "vkcube.stderr.log"

    $driverDir = Split-Path -Parent $MesaResult.Driver
    $llvmBinDir = Join-Path $LlvmResult.InstallDir "bin"

    $prevIcd = $env:VK_ICD_FILENAMES
    $prevDriverFiles = $env:VK_DRIVER_FILES
    $prevPath = $env:PATH

    try {
        $env:VK_ICD_FILENAMES = $MesaResult.Icd
        $env:VK_DRIVER_FILES = $MesaResult.Icd
        $env:PATH = "$driverDir;$llvmBinDir;$env:PATH"

        $oldEap = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            $summary = (& $vulkaninfoPath --summary 2>&1 | Out-String)
        }
        finally {
            $ErrorActionPreference = $oldEap
        }
        Set-Content -Path $summaryLog -Value $summary -Encoding UTF8
        if ($LASTEXITCODE -ne 0) { throw "vulkaninfo --summary failed for $($MesaResult.Config)." }
        if ($summary -notmatch "(?i)llvmpipe") { throw "vulkaninfo summary does not contain llvmpipe for $($MesaResult.Config)." }

        $summaryErrors = Get-MeaningfulErrorLines -Text $summary
        if ($summaryErrors.Count -gt 0) {
            throw "vulkaninfo summary contains error lines in $summaryLog"
        }

        if (Test-Path $cubeStdout) { Remove-Item $cubeStdout -Force }
        if (Test-Path $cubeStderr) { Remove-Item $cubeStderr -Force }

        $cube = Start-Process -FilePath $vkcubePath -ArgumentList @("--c", "180") -WorkingDirectory $driverDir -PassThru -RedirectStandardOutput $cubeStdout -RedirectStandardError $cubeStderr
        if (-not $cube.WaitForExit(90000)) {
            Stop-Process -Id $cube.Id -Force -ErrorAction SilentlyContinue
            throw "vkcube timeout for $($MesaResult.Config)."
        }
        if ($cube.ExitCode -ne 0) { throw "vkcube failed with exit code $($cube.ExitCode) for $($MesaResult.Config)." }

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
        }
        else {
            $env:VK_ICD_FILENAMES = $prevIcd
        }

        if ($null -eq $prevDriverFiles) {
            Remove-Item Env:VK_DRIVER_FILES -ErrorAction SilentlyContinue
        }
        else {
            $env:VK_DRIVER_FILES = $prevDriverFiles
        }

        $env:PATH = $prevPath
    }

    return @{
        LogDir = $logDir
        SummaryLog = $summaryLog
        VkCubeStdoutLog = $cubeStdout
        VkCubeStderrLog = $cubeStderr
    }
}

function Get-ConfigDepsPrefixes {
    param([Parameter(Mandatory = $true)][string]$Config)

    $primary = ""
    if ($Config -eq "release" -and -not [string]::IsNullOrWhiteSpace($DepsPrefixRelease)) {
        $primary = $DepsPrefixRelease
    }
    elseif ($Config -eq "debug" -and -not [string]::IsNullOrWhiteSpace($DepsPrefixDebug)) {
        $primary = $DepsPrefixDebug
    }
    else {
        $primary = Join-Path $DepsRoot $Config
    }

    $all = New-Object "System.Collections.Generic.List[string]"
    [void]$all.Add($primary)
    if ($Config -eq "debug" -and -not [string]::IsNullOrWhiteSpace($DepsPrefixRelease)) {
        [void]$all.Add($DepsPrefixRelease)
    }

    return @{
        Primary = $primary
        All = @($all | Select-Object -Unique)
    }
}

function Get-ExistingLlvmResult {
    param(
        [Parameter(Mandatory = $true)][string]$Config,
        [Parameter(Mandatory = $true)][string]$InstallDir
    )

    $cmakeConfig = if ($Config -eq "debug") { "Debug" } else { "Release" }
    $runtime = if ($Config -eq "debug") { "MultiThreadedDebug" } else { "MultiThreaded" }
    $llvmConfig = Join-Path $InstallDir "bin\\llvm-config.exe"
    if (-not (Test-Path $llvmConfig)) { throw "Missing llvm-config.exe: $llvmConfig" }

    return @{
        Config = $Config
        CMakeConfig = $cmakeConfig
        Runtime = $runtime
        BuildDir = "(skipped)"
        InstallDir = $InstallDir
        LlvmConfig = $llvmConfig
    }
}

if ($Jobs -le 0) { $Jobs = [Environment]::ProcessorCount }
if ($MesaTestJobs -le 0) { $MesaTestJobs = 32 }
$Configs = @($Configs | ForEach-Object { $_.ToLowerInvariant() } | Select-Object -Unique)
if ($Configs.Count -eq 0) { throw "No build configs selected." }

if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = Join-Path $PSScriptRoot "_run"
}
$Root = [IO.Path]::GetFullPath($Root)
if ([string]::IsNullOrWhiteSpace($DepsRoot)) {
    $DepsRoot = Join-Path $Root "deps"
}

$toolsDir = Join-Path $Root "tools"
$srcDir = Join-Path $Root "src"
$downloadDir = Join-Path $Root "downloads"
$llvmSrcDir = Join-Path $srcDir ("llvm-project-{0}" -f $LlvmVersion)
$mesaSrcDir = Join-Path $srcDir "mesa"

foreach ($p in @($Root, $toolsDir, $srcDir, $downloadDir, $DepsRoot)) {
    New-Item -ItemType Directory -Force -Path $p | Out-Null
}

Require-Command "git" | Out-Null
Require-Command "cmake" | Out-Null
Require-Command "ninja" | Out-Null
Require-Command "py" | Out-Null
if (-not [string]::IsNullOrWhiteSpace($MesonVersion)) {
    $script:MesonPython = Ensure-Meson -Version $MesonVersion -ToolsDir $toolsDir
}
if (-not $SkipSmoke) {
    Require-Command "vulkaninfo" | Out-Null
    Require-Command "vkcube" | Out-Null
}

if ($SkipLlvm -and -not $SkipLibclc) { $SkipLibclc = $true }
$needsLlvm = (-not $SkipLlvm) -or (-not $SkipLibclc)
if ($needsLlvm) {
    Ensure-LlvmSource -Version $LlvmVersion -LlvmSrcDir $llvmSrcDir
    Ensure-SpirvLlvmTranslator -LlvmSrcDir $llvmSrcDir -Version $SpirvLlvmTranslatorVersion
}
Ensure-MesaSource -MesaSrcDir $mesaSrcDir -MesaRepo $MesaRepo -MesaBranch $MesaBranch -MesaRef $MesaRef

$results = @()
foreach ($cfg in $Configs) {
    $depsInfo = Get-ConfigDepsPrefixes -Config $cfg
    $cfgDepsPrimary = $depsInfo.Primary
    $cfgDepsAll = $depsInfo.All

    $cfgRoot = Join-Path $Root $cfg
    $cfgBuildDir = Join-Path $cfgRoot "_build"
    $cfgInstallDir = Join-Path $cfgRoot "_install"
    $cfgLogsDir = Join-Path $cfgRoot "logs"
    $llvmBuildDir = Join-Path $cfgRoot "llvm-build"
    $libclcBuildDir = Join-Path $cfgRoot "libclc-build"
    $depsWorkDir = Join-Path $cfgRoot "deps-work"

    foreach ($p in @($cfgRoot, $cfgBuildDir, $cfgInstallDir, $cfgLogsDir, $cfgDepsPrimary)) {
        New-Item -ItemType Directory -Force -Path $p | Out-Null
    }
    foreach ($p in $cfgDepsAll) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        New-Item -ItemType Directory -Force -Path $p | Out-Null
    }

    Import-VsDevEnvironment -StateDir $toolsDir -VcVarsVer $VcVarsVerLlvm
    if (-not $SkipDeps) {
        Ensure-CiDeps -DepsInstallDir $cfgDepsPrimary -DepsWorkDir $depsWorkDir -VulkanSdkVersion $VulkanSdkVersion -Jobs $Jobs -Clean:$Clean
    }
    if ($cfg -eq "debug") {
        Ensure-SpirvTools -Config debug -DepsInstallDir $cfgDepsPrimary -DepsWorkDir $depsWorkDir -VulkanSdkVersion $VulkanSdkVersion -Jobs $Jobs -Clean:$Clean
    }

    $llvmResult = $null
    if (-not $SkipLlvm) {
        $pkgBlockDir = Join-Path $toolsDir "pkgconfig-null"
        $pkgBlockExe = Join-Path $pkgBlockDir "pkg-config.bat"
        if (-not (Test-Path $pkgBlockDir)) { New-Item -ItemType Directory -Force -Path $pkgBlockDir | Out-Null }
        if (-not (Test-Path $pkgBlockExe)) { "@echo off`r`nexit /b 1`r`n" | Set-Content -Path $pkgBlockExe -Encoding ASCII }
        $prevPath = $env:PATH
        $prevPkg = $env:PKG_CONFIG
        $env:PATH = "$pkgBlockDir;$env:PATH"
        $env:PKG_CONFIG = $pkgBlockExe
        try {
            $llvmResult = Build-Llvm -Config $cfg -LlvmSrcDir $llvmSrcDir -BuildDir $llvmBuildDir -InstallDir $cfgDepsPrimary -Jobs $Jobs -Clean:$Clean -PruneLlvmObjAfterBuild:$PruneLlvmObjAfterBuild
        }
        finally {
            if ($null -eq $prevPkg) { Remove-Item Env:PKG_CONFIG -ErrorAction SilentlyContinue } else { $env:PKG_CONFIG = $prevPkg }
            $env:PATH = $prevPath
        }
    }
    else {
        $llvmResult = Get-ExistingLlvmResult -Config $cfg -InstallDir $cfgDepsPrimary
    }

    if (-not $SkipLibclc) {
        if ($Clean -and (Test-Path $libclcBuildDir)) { Remove-Item -Recurse -Force $libclcBuildDir }
        Build-Libclc -Config $cfg -LlvmSrcDir $llvmSrcDir -BuildDir $libclcBuildDir -InstallDir $cfgDepsPrimary -Jobs $Jobs -Clean:$Clean
    }

    Import-VsDevEnvironment -StateDir $toolsDir -VcVarsVer $VcVarsVerMesa -VCToolsVersion $VCToolsVersionMesa
    $mesaResult = Build-Mesa -Config $cfg -MesaSrcDir $mesaSrcDir -BuildDir $cfgBuildDir -InstallDir $cfgInstallDir -DepsInstallDirs $cfgDepsAll -Jobs $Jobs -MesaTestJobs $MesaTestJobs -ExtraMesonArgs $ExtraMesonArgs -SkipMesaTests:$SkipMesaTests -Clean:$Clean

    $copiedDlls = @()
    if ($CopyLlvmDlls) {
        $copiedDlls = Copy-LlvmRuntimeDlls -LlvmInstallDir $llvmResult.InstallDir -DriverDir (Split-Path -Parent $mesaResult.Driver)
    }

    $smoke = @{ LogDir = "(skipped)"; SummaryLog = "(skipped)"; VkCubeStdoutLog = "(skipped)"; VkCubeStderrLog = "(skipped)" }
    if (-not $SkipSmoke) {
        $smoke = Run-Smoke -MesaResult $mesaResult -LlvmResult $llvmResult -LogRoot $cfgLogsDir
    }

    $results += [PSCustomObject]@{
        Config = $cfg
        LlvmRuntime = $llvmResult.Runtime
        LlvmBuildDir = $llvmResult.BuildDir
        LlvmInstallDir = $llvmResult.InstallDir
        LlvmConfig = $llvmResult.LlvmConfig
        MesaBuildDir = $mesaResult.BuildDir
        MesaInstallDir = $mesaResult.InstallDir
        Driver = $mesaResult.Driver
        Icd = $mesaResult.Icd
        CopiedLlvmDlls = if ($copiedDlls.Count -gt 0) { $copiedDlls -join ", " } else { "(none)" }
        SmokeLogDir = $smoke.LogDir
        VulkaninfoSummaryLog = $smoke.SummaryLog
        VkCubeStdoutLog = $smoke.VkCubeStdoutLog
        VkCubeStderrLog = $smoke.VkCubeStderrLog
    }
}

Write-Host ""
Write-Host "=== Build Summary ===" -ForegroundColor Green
$results | Format-Table -AutoSize

Write-Host ""
Write-Host "Root: $Root" -ForegroundColor Green
Write-Host "Mesa source: $mesaSrcDir" -ForegroundColor Green
Write-Host "LLVM source: $llvmSrcDir" -ForegroundColor Green
Write-Host "Deps root: $DepsRoot" -ForegroundColor Green
Write-Host "Mesa ref: $MesaRef" -ForegroundColor Green
Write-Host "LLVM version: $LlvmVersion" -ForegroundColor Green
Write-Host "Vulkan SDK version: $VulkanSdkVersion" -ForegroundColor Green
