<#
.SYNOPSIS
Build the Windows x64 installer and zip of Templar Wallet on any Windows 10/11 PC.

.DESCRIPTION
    Double-click scripts\build_windows.cmd, or:
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build_windows.ps1 [-Yes]

Output in dist\:
    TemplarWallet-<version>-windows-x64-setup.exe   installer wizard (unsigned)
    TemplarWallet-<version>-windows-x64.zip         the same app without installer
    SHA256SUMS-windows-x64.txt                      checksums of both
    BUILD-INFO-windows-x64.txt                      source check and toolchain
    build-windows-x64.log                           everything printed, for failures

Checks for these and offers to install what is missing (winget, one UAC
prompt each):
    Visual Studio 2022 Build Tools: C++ workload + C++ CMake tools
    Git
    Inno Setup 6.3 or newer (7 works too)
Downloads into its own folder, without touching PATH:
    Flutter (pinned below), SHA-256 verified
    Rust (pinned below, MSVC) through rustup; rustup itself is installed
    under %USERPROFILE%\.cargo if it is not there yet
Needs Developer Mode (or an elevated prompt): Flutter links plugins with
symlinks. The script opens the Settings page when it is off.

The same steps as the windows job of .github/workflows/release.yml, which
publishes these files under version-less names. See docs\build\HELPER_BUILDS.md.

This file must stay plain ASCII: Windows PowerShell 5.1 reads a script
without a byte-order mark in the ANSI code page, and a UTF-8 dash or quote
turns into characters that break string parsing.

.PARAMETER Yes
Install missing prerequisites without asking.
#>
[CmdletBinding()]
param([switch]$Yes)

# Keep in step with scripts/build_linux.sh and with FLUTTER_VERSION and
# RUST_TOOLCHAIN in .github/workflows/ci.yml and release.yml.
$FlutterVersion = '3.44.1'
# releases_windows.json on storage.googleapis.com/flutter_infra_release
$FlutterSha256  = '1e83bc8c032ea7f11a41a8f5e2853f7793ebcddacb5268cb0d3409023932091e'
$RustToolchain  = '1.95.0'
$Label          = 'windows-x64'

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$script:LogWriter = $null

# ---------------------------------------------------------------- output ----

function Add-LogLine([string]$Text) {
    if ($script:LogWriter) { $script:LogWriter.WriteLine($Text); $script:LogWriter.Flush() }
}

function Write-Say([string]$Text, [string]$Color = 'Gray') {
    Write-Host $Text -ForegroundColor $Color
    Add-LogLine $Text
}

function Write-Step([string]$Text) {
    Write-Say ''
    Write-Say "== $Text" 'Cyan'
}

# Runs a native program, echoing and logging every line of stdout and stderr,
# and throws on a non-zero exit code. Stderr is merged in PowerShell rather
# than by the program: under $ErrorActionPreference = 'Stop', Windows
# PowerShell 5.1 turns the first stderr line of a redirected native command
# into a terminating error, and cargo and flutter write progress there.
function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [string[]]$Arguments = @(),
        [string]$WorkDir = '',
        [switch]$AllowFail
    )
    Add-LogLine ('> ' + $Exe + ' ' + ($Arguments -join ' '))
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    if ($WorkDir) { Push-Location -LiteralPath $WorkDir }
    try {
        & $Exe @Arguments 2>&1 | ForEach-Object {
            $line = "$_"
            Write-Host $line
            Add-LogLine $line
        }
        $code = $LASTEXITCODE
    }
    finally {
        if ($WorkDir) { Pop-Location }
        $ErrorActionPreference = $saved
    }
    if ($code -ne 0 -and -not $AllowFail) {
        throw "$([IO.Path]::GetFileName($Exe)) failed with exit code $code"
    }
    return $code
}

# Stdout of a quick query, or $null when the program fails or is missing.
function Get-NativeOutput([string]$Exe, [string[]]$Arguments = @()) {
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $Exe @Arguments 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        return $out
    }
    catch { return $null }
    finally { $ErrorActionPreference = $saved }
}

# ------------------------------------------------------ pure helpers ----
# No Windows-only calls below this line until "prerequisites": these are the
# parts that can be exercised with pwsh on any OS.

function Join-Parts([string[]]$Parts) {
    return [IO.Path]::Combine([string[]]$Parts)
}

function Get-AppVersion([string]$Root) {
    $pubspec = Join-Parts @($Root, 'src', 'templar_wallet', 'pubspec.yaml')
    foreach ($line in [IO.File]::ReadAllLines($pubspec)) {
        if ($line -match '^version:\s*([^+\s]+)') { return $Matches[1] }
    }
    throw "No version line in $pubspec"
}

function Get-SourceDescription([string]$Root) {
    $info = Join-Parts @($Root, 'SOURCE-INFO.txt')
    if (Test-Path -LiteralPath $info) {
        $commit = ''; $branch = ''
        foreach ($line in [IO.File]::ReadAllLines($info)) {
            if ($line -match '^commit:\s*(.+)$') { $commit = $Matches[1].Trim() }
            if ($line -match '^branch:\s*(.+)$') { $branch = $Matches[1].Trim() }
        }
        return "bundle $commit (branch $branch)"
    }
    if ((Test-Path -LiteralPath (Join-Parts @($Root, '.git'))) -and (Get-Command git -ErrorAction SilentlyContinue)) {
        $sha = Get-NativeOutput 'git' @('-C', $Root, 'rev-parse', '--short=12', 'HEAD')
        $status = Get-NativeOutput 'git' @('-C', $Root, 'status', '--porcelain')
        $dirty = ''
        if ($status) { $dirty = ' + uncommitted changes' }
        return "git $sha$dirty"
    }
    return 'unknown (no SOURCE-INFO.txt, not a git checkout)'
}

# Compares every file against SOURCE-MANIFEST.sha256 (written on the Mac by
# scripts/pack_source.sh) and returns the one-line verdict for BUILD-INFO.
function Test-SourceManifest([string]$Root) {
    $manifest = Join-Parts @($Root, 'SOURCE-MANIFEST.sha256')
    if (-not (Test-Path -LiteralPath $manifest)) {
        return 'not checked (no SOURCE-MANIFEST.sha256)'
    }
    $sep = [string][IO.Path]::DirectorySeparatorChar
    $total = 0
    $bad = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in [IO.File]::ReadAllLines($manifest)) {
        if ($line -notmatch '^([0-9a-f]{64}) [ *](.+)$') { continue }
        $total++
        $expected = $Matches[1]
        $rel = $Matches[2]
        $path = Join-Parts @($Root, $rel.Replace('/', $sep))
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $bad.Add($rel); continue }
        $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $expected) { $bad.Add($rel) }
    }
    if ($bad.Count -eq 0) {
        return "unmodified ($total files match SOURCE-MANIFEST.sha256)"
    }
    $first = ($bad | Select-Object -First 5) -join ' '
    return "MODIFIED: $($bad.Count) of $total files differ or are missing: $first"
}

# sha256sum format with LF line ends, so `shasum -a 256 -c` on the Mac and
# `sha256sum -c` on Linux both accept the file as it arrives.
function Write-Checksums([string]$Dir, [string[]]$Names, [string]$OutFile) {
    $lines = foreach ($name in $Names) {
        $hash = (Get-FileHash -LiteralPath (Join-Parts @($Dir, $name)) -Algorithm SHA256).Hash.ToLowerInvariant()
        "$hash  $name"
    }
    [IO.File]::WriteAllText($OutFile, (($lines -join "`n") + "`n"))
}

function Get-BuildHome {
    if ($env:TEMPLAR_BUILD_HOME) { return $env:TEMPLAR_BUILD_HOME }
    $default = Join-Parts @($env:LOCALAPPDATA, 'templar-build')
    # The Flutter SDK does not build from a path with a space in it, and a
    # user profile named "First Last" puts one in LOCALAPPDATA.
    if ($default.Contains(' ')) { return 'C:\templar-build' }
    return $default
}

# ------------------------------------------------------ prerequisites ----

function Update-SessionPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ';'
}

function Confirm-Install([string]$What) {
    if ($Yes) { return $true }
    Write-Host ''
    $answer = Read-Host "$What is missing. Install it now? [Y/n]"
    return ($answer -eq '' -or $answer -match '^[Yy]')
}

function Install-WithWinget([string]$Id, [string[]]$Extra = @()) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "winget is not available. Install or update 'App Installer' from the Microsoft Store, then run this again."
    }
    $wingetArgs = @('install', '--exact', '--id', $Id, '--source', 'winget',
        '--accept-package-agreements', '--accept-source-agreements') + $Extra
    Add-LogLine ('> winget ' + ($wingetArgs -join ' '))
    # Straight to the console with Out-Host. Left bare, winget's output would
    # become this function's return value -- and the return value of every
    # caller up the chain, so `$iscc = Initialize-InnoSetup` on a clean PC
    # received winget's text plus the ISCC path, and the installer step
    # failed after an hour of building. (Not Invoke-Native: that logs and
    # judges the exit code, which winget does not report reliably.)
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & winget @wingetArgs | Out-Host
    $code = $LASTEXITCODE
    $ErrorActionPreference = $saved
    # The exit code is logged, not trusted: installers report success as 3010
    # (reboot pending) among others. The caller detects the tool again.
    Add-LogLine "winget exit code $code"
    Update-SessionPath
}

$VsComponents = @(
    'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
    'Microsoft.VisualStudio.Component.VC.CMake.Project'
)

function Get-VsWhere {
    $path = Join-Parts @(${env:ProgramFiles(x86)}, 'Microsoft Visual Studio', 'Installer', 'vswhere.exe')
    if (Test-Path -LiteralPath $path) { return $path }
    return $null
}

# Install path of a Visual Studio (any edition, Build Tools included) that has
# MSVC and the C++ CMake tools, or $null.
function Find-VisualStudio {
    $vswhere = Get-VsWhere
    if (-not $vswhere) { return $null }
    $found = Get-NativeOutput $vswhere (@('-products', '*', '-latest', '-requires') + $VsComponents + @('-property', 'installationPath'))
    if ($found) { return (@($found) | Select-Object -First 1) }
    return $null
}

function Initialize-VisualStudio {
    $vs = Find-VisualStudio
    if ($vs) { return $vs }
    $vswhere = Get-VsWhere
    $existing = $null
    if ($vswhere) {
        $existing = Get-NativeOutput $vswhere @('-products', '*', '-latest', '-property', 'installationPath')
    }
    if ($existing) {
        $existing = @($existing) | Select-Object -First 1
        if (-not (Confirm-Install "The C++ build tools in Visual Studio at $existing")) {
            throw 'Visual Studio C++ tools are required.'
        }
        Write-Step "adding the C++ workload to $existing"
        $setup = Join-Parts @(${env:ProgramFiles(x86)}, 'Microsoft Visual Studio', 'Installer', 'setup.exe')
        $vsArgs = @('modify', '--installPath', "`"$existing`"", '--passive', '--norestart',
            '--add', 'Microsoft.VisualStudio.Workload.VCTools', '--includeRecommended')
        foreach ($c in $VsComponents) { $vsArgs += @('--add', $c) }
        Start-Process -FilePath $setup -ArgumentList $vsArgs -Verb RunAs -Wait
    }
    else {
        if (-not (Confirm-Install 'Visual Studio 2022 Build Tools (C++, about 7 GB)')) {
            throw 'Visual Studio C++ tools are required.'
        }
        Write-Step 'installing Visual Studio 2022 Build Tools (this takes a while)'
        $override = '--wait --passive --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended'
        foreach ($c in $VsComponents) { $override += " --add $c" }
        Install-WithWinget 'Microsoft.VisualStudio.2022.BuildTools' @('--override', $override)
    }
    $vs = Find-VisualStudio
    if (-not $vs) {
        throw ("Visual Studio still lacks the C++ tools. Open 'Visual Studio Installer', press Modify, " +
            "tick 'Desktop development with C++' and 'C++ CMake tools for Windows', install, then run this again. " +
            "If the installer asked for a restart, restart first.")
    }
    return $vs
}

function Initialize-Git {
    if (Get-Command git -ErrorAction SilentlyContinue) { return }
    if (-not (Confirm-Install 'Git')) { throw 'Git is required (Flutter uses it).' }
    Write-Step 'installing Git'
    Install-WithWinget 'Git.Git'
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw 'Git was installed but is not on PATH yet. Close this window and run the script again.'
    }
}

# The newest ISCC.exe there is, or $null. Inno Setup 6 installs as a 32-bit
# program ("Inno Setup 6" under Program Files (x86)), 7 as a 64-bit one with
# its own folder, and either may sit in a custom folder its uninstall entry
# records; the .iss compiles with 6.3 and newer, 7 included.
function Find-Iscc {
    $found = New-Object 'System.Collections.Generic.List[string]'
    $cmd = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($cmd) { $found.Add($cmd.Path) }
    $roots = @(${env:ProgramFiles(x86)}, $env:ProgramFiles, (Join-Parts @($env:LOCALAPPDATA, 'Programs'))) | Where-Object { $_ }
    foreach ($r in $roots) {
        Get-ChildItem -Path (Join-Parts @($r, 'Inno Setup*')) -Filter 'ISCC.exe' -ErrorAction SilentlyContinue |
            ForEach-Object { $found.Add($_.FullName) }
    }
    $uninstall = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')
    foreach ($key in @(Get-ChildItem -Path $uninstall -ErrorAction SilentlyContinue)) {
        if ($key.PSChildName -notlike 'Inno Setup*_is1') { continue }
        $location = $key.GetValue('InstallLocation')
        if ($location) { $found.Add((Join-Parts @([string]$location, 'ISCC.exe'))) }
    }
    $best = $null
    $bestVersion = $null
    foreach ($exe in $found) {
        if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { continue }
        $info = (Get-Item -LiteralPath $exe).VersionInfo
        $version = New-Object -TypeName System.Version -ArgumentList @($info.FileMajorPart, $info.FileMinorPart, $info.FileBuildPart)
        if ($null -eq $best -or $version -gt $bestVersion) {
            $best = $exe
            $bestVersion = $version
        }
    }
    return $best
}

function Initialize-InnoSetup {
    $iscc = Find-Iscc
    if ($iscc) { return $iscc }
    if (-not (Confirm-Install 'Inno Setup (builds the installer)')) { throw 'Inno Setup is required.' }
    Write-Step 'installing Inno Setup'
    Install-WithWinget 'JRSoftware.InnoSetup'
    $iscc = Find-Iscc
    if (-not $iscc) { throw 'Inno Setup was installed but ISCC.exe was not found. Run the script again.' }
    return $iscc
}

function Test-SymlinkSupport {
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
    $item = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
    if ($item -and ($item.PSObject.Properties.Name -contains 'AllowDevelopmentWithoutDevLicense') -and
        $item.AllowDevelopmentWithoutDevLicense -eq 1) {
        return $true
    }
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Initialize-DeveloperMode {
    for ($i = 0; $i -lt 3; $i++) {
        if (Test-SymlinkSupport) { return }
        Write-Say ''
        Write-Say 'Flutter needs Developer Mode to link plugins (it creates symlinks).' 'Yellow'
        Write-Say 'Opening Settings: switch "Developer Mode" on, confirm, come back here.' 'Yellow'
        Start-Process 'ms-settings:developers'
        [void](Read-Host 'Press Enter once Developer Mode is on')
    }
    if (-not (Test-SymlinkSupport)) {
        throw 'Developer Mode is still off. Turn it on (Settings > System > For developers) or run this from an elevated prompt.'
    }
}

# rustup.exe path; installs rustup without editing PATH if it is missing.
function Initialize-Rust([string]$BuildHome) {
    $cargoHome = $env:CARGO_HOME
    if (-not $cargoHome) { $cargoHome = Join-Parts @($env:USERPROFILE, '.cargo') }
    $rustup = Join-Parts @($cargoHome, 'bin', 'rustup.exe')
    if (-not (Test-Path -LiteralPath $rustup)) {
        $cmd = Get-Command rustup -ErrorAction SilentlyContinue
        if ($cmd) { $rustup = $cmd.Path }
    }
    if (-not (Test-Path -LiteralPath $rustup)) {
        Write-Step 'installing rustup (Rust toolchain manager)'
        New-Item -ItemType Directory -Force -Path $BuildHome | Out-Null
        $init = Join-Parts @($BuildHome, 'rustup-init.exe')
        [void](Invoke-Native -Exe 'curl.exe' -Arguments @('-fsSL', '--retry', '3', '-o', $init,
            'https://static.rust-lang.org/rustup/dist/x86_64-pc-windows-msvc/rustup-init.exe'))
        [void](Invoke-Native -Exe $init -Arguments @('-y', '--no-modify-path', '--profile', 'minimal', '--default-toolchain', 'none'))
        Remove-Item -LiteralPath $init -Force
        $rustup = Join-Parts @($cargoHome, 'bin', 'rustup.exe')
        if (-not (Test-Path -LiteralPath $rustup)) { throw "rustup-init finished but $rustup is missing." }
    }
    $toolchain = "$RustToolchain-x86_64-pc-windows-msvc"
    Write-Step "Rust $toolchain"
    [void](Invoke-Native -Exe $rustup -Arguments @('toolchain', 'install', $toolchain, '--profile', 'minimal', '--no-self-update'))
    return $rustup
}

# flutter.bat of a private, pinned SDK under the build home.
function Initialize-Flutter([string]$BuildHome) {
    $sdk = Join-Parts @($BuildHome, "flutter-$FlutterVersion")
    $bat = Join-Parts @($sdk, 'bin', 'flutter.bat')
    if (Test-Path -LiteralPath $bat) { return $bat }

    New-Item -ItemType Directory -Force -Path $BuildHome | Out-Null
    $zip = Join-Parts @($BuildHome, "flutter_windows_$FlutterVersion-stable.zip")
    $url = "https://storage.googleapis.com/flutter_infra_release/releases/stable/windows/flutter_windows_$FlutterVersion-stable.zip"
    $ok = $false
    if (Test-Path -LiteralPath $zip) {
        $ok = ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant() -eq $FlutterSha256)
    }
    if (-not $ok) {
        Write-Step "downloading Flutter $FlutterVersion (about 1.9 GB)"
        # curl.exe ships with Windows 10 1803+ and is far faster than
        # Invoke-WebRequest. Run directly so its progress bar shows.
        $saved = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        & curl.exe -fL --retry 3 -o $zip $url
        $code = $LASTEXITCODE
        $ErrorActionPreference = $saved
        if ($code -ne 0) { throw "Flutter download failed (curl exit code $code)." }
        $actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $FlutterSha256) {
            Remove-Item -LiteralPath $zip -Force
            throw "Flutter download is corrupt (sha256 $actual). Run the script again."
        }
    }
    Write-Step 'unpacking Flutter (a few minutes; antivirus scanning can make it longer)'
    $tmp = Join-Parts @($BuildHome, 'flutter-unpack')
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    [void](Invoke-Native -Exe 'tar.exe' -Arguments @('-xf', $zip, '-C', $tmp))
    Move-Item -LiteralPath (Join-Parts @($tmp, 'flutter')) -Destination $sdk
    Remove-Item -LiteralPath $tmp -Recurse -Force
    Remove-Item -LiteralPath $zip -Force
    if (-not (Test-Path -LiteralPath $bat)) { throw "Flutter unpacked but $bat is missing." }
    return $bat
}

# -------------------------------------------------------------- build ----

function Invoke-Build {
    $root = Split-Path -Parent $PSScriptRoot
    $dist = Join-Parts @($root, 'dist')
    New-Item -ItemType Directory -Force -Path $dist | Out-Null
    $logPath = Join-Parts @($dist, "build-$Label.log")
    $script:LogWriter = New-Object IO.StreamWriter($logPath, $false, (New-Object Text.UTF8Encoding($false)))

    try {
        Write-Say "Templar Wallet $Label build, $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')), log: $logPath"

        if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
            Write-Say "WARNING: this PC is $($env:PROCESSOR_ARCHITECTURE); the build targets x64 and may fail." 'Yellow'
        }
        if ($root.Contains(' ')) {
            Write-Say "WARNING: the folder path has a space in it ($root). Move it to e.g. C:\src\ if the build fails." 'Yellow'
        }
        elseif ($root.Length -gt 60) {
            Write-Say "WARNING: the folder path is long ($($root.Length) characters). Move it to e.g. C:\src\ if the build fails." 'Yellow'
        }

        $version = Get-AppVersion $root
        $buildHome = Get-BuildHome
        Write-Say "version $version, tools in $buildHome"

        Write-Step 'prerequisites'
        $vs = Initialize-VisualStudio
        Write-Say "Visual Studio: $vs"
        $null = Initialize-Git
        $iscc = Initialize-InnoSetup
        Write-Say "Inno Setup: $iscc"
        Initialize-DeveloperMode
        $rustup = Initialize-Rust $buildHome
        $flutter = Initialize-Flutter $buildHome
        $toolchain = "$RustToolchain-x86_64-pc-windows-msvc"

        Write-Step 'source check'
        $sourceLine = Get-SourceDescription $root
        $checkLine = Test-SourceManifest $root
        Write-Say "source: $sourceLine"
        Write-Say "check:  $checkLine"

        Write-Step 'toolchain'
        $rustVersion = (Get-NativeOutput $rustup @('run', $toolchain, 'rustc', '--version')) -join ' '
        Write-Say $rustVersion
        [void](Invoke-Native -Exe $flutter -Arguments @('config', '--no-analytics'))
        $flutterVersionLine = @(Get-NativeOutput $flutter @('--version')) | Select-Object -First 1
        Write-Say "$flutterVersionLine"

        Write-Step 'Rust engine: cargo build --release -p wallet-ffi'
        [void](Invoke-Native -Exe $rustup -Arguments @('run', $toolchain, 'cargo', 'build', '--release', '--locked', '-p', 'wallet-ffi') -WorkDir $root)
        $dll = Join-Parts @($root, 'target', 'release', 'wallet_ffi.dll')
        if (-not (Test-Path -LiteralPath $dll)) { throw "cargo finished but $dll is missing." }

        Write-Step 'Flutter app: flutter build windows --release'
        $app = Join-Parts @($root, 'src', 'templar_wallet')
        [void](Invoke-Native -Exe $flutter -Arguments @('pub', 'get', '--enforce-lockfile') -WorkDir $app)
        [void](Invoke-Native -Exe $flutter -Arguments @('build', 'windows', '--release') -WorkDir $app)
        $bundle = Join-Parts @($app, 'build', 'windows', 'x64', 'runner', 'Release')
        if (-not (Test-Path -LiteralPath (Join-Parts @($bundle, 'templar_wallet.exe')))) {
            throw "flutter finished but templar_wallet.exe is missing in $bundle."
        }

        Write-Step 'bundle'
        # The Dart loader opens wallet_ffi.dll from the exe directory.
        Copy-Item -LiteralPath $dll -Destination $bundle -Force
        Copy-Item -LiteralPath (Join-Parts @($root, 'docs', 'RELEASE_NOTES.md')) -Destination (Join-Parts @($bundle, 'README.md')) -Force

        $name = "TemplarWallet-$version-$Label"
        $zipName = "$name.zip"
        $setupName = "$name-setup.exe"
        $stage = Join-Parts @($dist, $name)
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
        Copy-Item -LiteralPath $bundle -Destination $stage -Recurse
        $zipPath = Join-Parts @($dist, $zipName)
        if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
        # tar.exe -a writes a standard zip (forward slashes), which
        # Compress-Archive on Windows PowerShell 5.1 does not.
        [void](Invoke-Native -Exe 'tar.exe' -Arguments @('-a', '-c', '-f', $zipPath, '-C', $dist, $name))
        Remove-Item -LiteralPath $stage -Recurse -Force

        Write-Step 'installer (Inno Setup)'
        $iss = Join-Parts @($root, 'packaging', 'windows', 'templar-wallet.iss')
        [void](Invoke-Native -Exe $iscc -Arguments @("/DMyAppVersion=$version", $iss))
        $setupPath = Join-Parts @($dist, $setupName)
        if (-not (Test-Path -LiteralPath $setupPath)) { throw "Inno Setup finished but $setupPath is missing." }

        $sums = Join-Parts @($dist, "SHA256SUMS-$Label.txt")
        Write-Checksums $dist @($setupName, $zipName) $sums
        $info = @(
            "Templar Wallet build ($Label)",
            "version:       $version",
            "source:        $sourceLine",
            "source check:  $checkLine",
            "built:         $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))",
            "build host:    native Windows $([Environment]::OSVersion.Version) ($($env:PROCESSOR_ARCHITECTURE))",
            "rust:          $rustVersion",
            "flutter:       $flutterVersionLine",
            "visual studio: $vs",
            "inno setup:    $iscc",
            'sha256:'
        ) + @([IO.File]::ReadAllLines($sums) | ForEach-Object { "  $_" })
        [IO.File]::WriteAllText((Join-Parts @($dist, "BUILD-INFO-$Label.txt")), (($info -join "`n") + "`n"))

        Write-Step 'done'
        Write-Say "Send back these files from $dist" 'Green'
        foreach ($f in @($setupName, $zipName, "SHA256SUMS-$Label.txt", "BUILD-INFO-$Label.txt")) {
            Write-Say "   $f" 'Green'
        }
        Write-Say 'And paste these lines into a chat message too:' 'Green'
        foreach ($l in [IO.File]::ReadAllLines($sums)) { Write-Say "   $l" }
        Start-Process explorer.exe -ArgumentList "`"$dist`""
        return 0
    }
    catch {
        Write-Say ''
        Write-Say "BUILD FAILED: $($_.Exception.Message)" 'Red'
        Write-Say "Send this file to the person who asked for the build: $logPath" 'Red'
        return 1
    }
    finally {
        if ($script:LogWriter) { $script:LogWriter.Dispose(); $script:LogWriter = $null }
    }
}

# Dot-sourcing (". .\build_windows.ps1") only defines the functions, for tests.
if ($MyInvocation.InvocationName -ne '.') {
    # cargo and flutter print UTF-8. Cosmetic only, so a host that refuses
    # the change (no console attached) is not an error.
    try { [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false) } catch { Add-LogLine 'console encoding unchanged' }
    # The last value is the build's own 0/1; anything a tool printed into the
    # success stream before it must not become the exit code.
    exit [int](@(Invoke-Build)[-1])
}
