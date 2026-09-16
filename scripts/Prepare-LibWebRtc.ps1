# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 dyhwdnmd (https://github.com/dyhwdnmd)
<#
.SYNOPSIS
Prepares the pinned libwebrtc static libraries used by the RLink CMake build.

.DESCRIPTION
Checks out the WebRTC revision pinned in BUILDING.md, syncs every DEPS
dependency to that revision, forces the dynamic CRT, writes the GN args and
builds the static libraries that RLinkAPP links against.

The revision is enforced by putting it in the `src` solution URL in .gclient
(`.../src.git@<commit>`), not by a bare `git checkout`: this gclient ignores a
separate `"revision"` key in .gclient, and when the solution URL carries no
revision it tracks `origin/main`, which silently undoes a manual checkout on the
next sync. The sync is performed in a single pass and the resulting HEAD is
verified against the pinned commit.

WebRTC also requires `core.autocrlf=false` (Git for Windows installs with
`core.autocrlf=true` at system scope, which rewrites byte-exact text files) and
long path support. Those are injected for this process tree only through the
GIT_CONFIG_COUNT environment mechanism, so the developer's global git
configuration is left untouched.

The pinned WebRTC revision has no GN argument for the dynamic CRT: its
build/config/win/BUILD.gn default_crt config selects /MT, which cannot link
against RLink (Qt uses /MD). This script therefore patches default_crt to use
:dynamic_crt (=> /MD for Release, /MDd for Debug) before running gn gen. The
patch is idempotent, but it lives in the WebRTC checkout and can be overwritten
by a gclient sync that updates the `build` dependency: re-run this script after
such a sync.

.PARAMETER Root
Directory that contains (or will contain) the WebRTC `src` checkout. Defaults to
the parent of $env:RLINK_WEBRTC_SRC when set.

.PARAMETER DepotTools
depot_tools checkout. Defaults to $env:RLINK_DEPOT_TOOLS, then to the directory
of gclient.bat on PATH.

.PARAMETER MsvsPath
Visual Studio 2022 installation root used for GYP_MSVS_OVERRIDE_PATH, so WebRTC
uses the same MSVC STL as the CMake/Qt build (see BUILDING.md section 2).
Defaults to $env:GYP_MSVS_OVERRIDE_PATH, then to the path reported by vswhere.

.PARAMETER Configurations
Which GN output trees to build: Release (out\ReleaseMD), Debug (out\DebugMD) or
both. Default: both.

.PARAMETER SkipFetch
Skip the pinned checkout/sync and only re-patch, gn gen and build an existing
checkout. The existing HEAD is reported but not changed.

.PARAMETER SkipBuild
Patch and write args.gn only; do not run gn gen or ninja.

.EXAMPLE
.\scripts\Prepare-LibWebRtc.ps1 -Root D:\dev\webrtc_src -DepotTools D:\dev\depot_tools

.EXAMPLE
.\scripts\Prepare-LibWebRtc.ps1 -SkipFetch -Configurations Release
#>
[CmdletBinding()]
param(
    [string]$Root,
    [string]$DepotTools,
    [string]$MsvsPath,
    [ValidateSet('Release', 'Debug')]
    [string[]]$Configurations = @('Release', 'Debug'),
    [switch]$SkipFetch,
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'

$WebRtcCommit = '1e2bd46a33bc0a95ff4e032e380f9fcfa2505808'
$WebRtcUrl = 'https://webrtc.googlesource.com/src.git'

$OutByConfig = @{
    Release = 'out\ReleaseMD'
    Debug   = 'out\DebugMD'
}

function Write-Step([string]$Message) {
    Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message)
}

function Invoke-Native([string]$Name, [scriptblock]$Command) {
    Write-Step $Name
    & $Command
    if ($LASTEXITCODE -ne 0) {
        throw "$Name failed with exit code $LASTEXITCODE."
    }
}

function Get-WebRtcArgs([bool]$IsDebug) {
    $isDebugValue = if ($IsDebug) { 'true' } else { 'false' }
    # Debug must match Qt's debug DLLs, which use the MSVC default
    # _ITERATOR_DEBUG_LEVEL=2; enabling iterator debugging stops WebRTC from
    # defining _HAS_ITERATOR_DEBUGGING=0 (see build/config/BUILD.gn).
    $iteratorDebugging = $isDebugValue
    return @(
        "is_debug = $isDebugValue",
        "enable_iterator_debugging = $iteratorDebugging",
        'target_cpu = "x64"',
        'rtc_include_tests = false',
        'use_custom_libcxx = false',
        'use_lld = false',
        'proprietary_codecs = true',
        'ffmpeg_branding = "Chrome"'
    )
}

# --- resolve inputs ---------------------------------------------------------
if (-not $Root -and $env:RLINK_WEBRTC_SRC) {
    $Root = Split-Path -Parent $env:RLINK_WEBRTC_SRC
}
if (-not $Root) {
    throw "Specify -Root (the directory that contains the WebRTC 'src' checkout) or set RLINK_WEBRTC_SRC."
}

if (-not $DepotTools -and $env:RLINK_DEPOT_TOOLS) {
    $DepotTools = $env:RLINK_DEPOT_TOOLS
}
if (-not $DepotTools) {
    $gclient = Get-Command gclient.bat -ErrorAction SilentlyContinue
    if ($gclient) {
        $DepotTools = Split-Path -Parent $gclient.Source
    }
}
if (-not $DepotTools -or -not (Test-Path -LiteralPath (Join-Path $DepotTools 'gclient.bat'))) {
    throw "depot_tools not found. Pass -DepotTools or set RLINK_DEPOT_TOOLS, or add it to PATH."
}

$Root = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Root)
$DepotTools = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($DepotTools)
$Src = Join-Path $Root 'src'
$GclientFile = Join-Path $Root '.gclient'

# depot_tools must be first on PATH and must not update itself off the pinned revision.
$env:PATH = "$DepotTools;$env:PATH"
$env:DEPOT_TOOLS_UPDATE = '0'
$env:DEPOT_TOOLS_WIN_TOOLCHAIN = '0'

# --- toolchain: pin GYP_MSVS_OVERRIDE_PATH to the local VS2022 install -------
# Without this, gn falls back to its own detection and may pick a different
# MSVC than the CMake/Qt build, which surfaces as unresolved __std_* symbols.
if (-not $MsvsPath -and $env:GYP_MSVS_OVERRIDE_PATH) {
    $MsvsPath = $env:GYP_MSVS_OVERRIDE_PATH
}
if (-not $MsvsPath) {
    $programFilesX86 = ${env:ProgramFiles(x86)}
    if ($programFilesX86) {
        $vswhere = Join-Path $programFilesX86 'Microsoft Visual Studio\Installer\vswhere.exe'
        if (Test-Path -LiteralPath $vswhere) {
            $vsArgs = @(
                '-latest', '-products', '*',
                '-requires', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
                '-property', 'installationPath'
            )
            $detected = @(& $vswhere @vsArgs) | Select-Object -First 1
            if ($detected) {
                $MsvsPath = $detected.Trim()
            }
        }
    }
}
if (-not $MsvsPath -or -not (Test-Path -LiteralPath $MsvsPath)) {
    throw "Visual Studio 2022 with the C++ toolset was not found. Pass -MsvsPath or set GYP_MSVS_OVERRIDE_PATH (see BUILDING.md section 2)."
}
$env:GYP_MSVS_OVERRIDE_PATH = $MsvsPath

# --- git settings WebRTC needs, scoped to this process tree -----------------
# Injected via GIT_CONFIG_COUNT so the user's global git config is not modified.
# (git config --global core.autocrlf false would work too, but it changes every
# repository on the machine.)
$gitSettings = @(
    @{ Key = 'core.autocrlf';    Value = 'false' },
    @{ Key = 'core.filemode';    Value = 'false' },
    @{ Key = 'core.fscache';     Value = 'true' },
    @{ Key = 'core.preloadindex'; Value = 'true' },
    @{ Key = 'core.longpaths';   Value = 'true' }
)
$env:GIT_CONFIG_COUNT = [string]$gitSettings.Count
for ($i = 0; $i -lt $gitSettings.Count; $i++) {
    Set-Item -Path ("Env:GIT_CONFIG_KEY_{0}" -f $i) -Value $gitSettings[$i].Key
    Set-Item -Path ("Env:GIT_CONFIG_VALUE_{0}" -f $i) -Value $gitSettings[$i].Value
}

# OS long path support is machine-wide and cannot be changed without elevation.
$longPaths = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled -ErrorAction SilentlyContinue).LongPathsEnabled
if ($longPaths -ne 1) {
    Write-Warning ('Windows long path support (LongPathsEnabled) is off; relying on ' +
        'git core.longpaths=true. Enable it from an elevated shell if a checkout ' +
        'fails with path-too-long errors.')
}

Write-Step "WebRTC src : $Src"
Write-Step "depot_tools: $DepotTools"
Write-Step "MSVC       : $MsvsPath"
Write-Step "configs    : $($Configurations -join ', ')"

# --- bootstrap the depot_tools wrappers if necessary ------------------------
if (-not (Test-Path -LiteralPath (Join-Path $DepotTools 'git.bat'))) {
    Invoke-Native 'bootstrap depot_tools (win_tools.bat)' {
        & (Join-Path $DepotTools 'bootstrap\win_tools.bat')
    }
}

# --- pin the `src` solution and sync it in one pass -------------------------
if (-not $SkipFetch) {
    New-Item -ItemType Directory -Force -Path $Root | Out-Null

    $pinnedUrl = "$WebRtcUrl@$WebRtcCommit"
    if (-not (Test-Path -LiteralPath $GclientFile)) {
        Write-Step "Writing pinned .gclient ($pinnedUrl)"
        $spec = (@(
                'solutions = [',
                '  {',
                '    "name": "src",',
                ('    "url": "{0}",' -f $pinnedUrl),
                '    "deps_file": "DEPS",',
                '    "custom_deps": {},',
                '  },',
                ']'
            ) -join "`r`n") + "`r`n"
        [System.IO.File]::WriteAllText($GclientFile, $spec, (New-Object System.Text.UTF8Encoding($false)))
    }
    else {
        # Reuse an existing .gclient (for example one written by `fetch`), but
        # force the revision into the src solution URL so the sync cannot drift
        # back to origin/main. Only the URL line is touched; other keys stay.
        $content = [System.IO.File]::ReadAllText($GclientFile)
        $pattern = '"url"\s*:\s*"' + [regex]::Escape($WebRtcUrl) + '(?:@[^"]*)?"'
        if ($content -match $pattern) {
            $updated = [regex]::Replace($content, $pattern, ('"url": "{0}"' -f $pinnedUrl))
            if ($updated -ne $content) {
                [System.IO.File]::WriteAllText($GclientFile, $updated, (New-Object System.Text.UTF8Encoding($false)))
                Write-Step "Pinned the src revision in $GclientFile"
            }
        }
        else {
            Write-Warning "Could not find the WebRTC src URL in $GclientFile; relying on --revision for this sync."
        }
    }

    # One pass: gclient clones/checks out src@<pin> and syncs the DEPS of that
    # exact revision. --revision is kept as a second lock in case an existing
    # .gclient could not be rewritten above.
    Invoke-Native "gclient sync -D (src@$WebRtcCommit)" {
        Push-Location $Root
        try {
            & gclient sync -D --with_branch_heads --revision "src@$WebRtcCommit"
        }
        finally { Pop-Location }
    }

    if (-not (Test-Path -LiteralPath (Join-Path $Src '.git'))) {
        throw "gclient sync finished but $Src\.git does not exist."
    }
    $head = (& git -C $Src rev-parse HEAD).Trim()
    if ($head -ne $WebRtcCommit) {
        throw "WebRTC checkout is at $head, expected $WebRtcCommit. The pinned revision was not applied."
    }
    Write-Step "WebRTC src pinned at $head"
}
else {
    Write-Step 'Skipping checkout/sync (-SkipFetch).'
    if (Test-Path -LiteralPath (Join-Path $Src '.git')) {
        $head = (& git -C $Src rev-parse HEAD).Trim()
        if ($head -ne $WebRtcCommit) {
            Write-Warning "Existing WebRTC checkout is at $head, not the pinned $WebRtcCommit."
        }
        else {
            Write-Step "Existing WebRTC checkout is at the pinned revision."
        }
    }
}

# --- force the dynamic CRT (/MD or /MDd) ------------------------------------
$buildGn = Join-Path $Src 'build\config\win\BUILD.gn'
if (-not (Test-Path -LiteralPath $buildGn)) {
    throw "Not found: $buildGn. Run without -SkipFetch first (see BUILDING.md section 4)."
}

$content = [System.IO.File]::ReadAllText($buildGn)
$staticPattern = '# Desktop Windows: static CRT\.\s*configs = \[ ":static_crt" \]'

if ($content -match '# Desktop Windows: dynamic CRT') {
    Write-Step 'default_crt already uses the dynamic CRT; skipping patch.'
}
elseif ($content -match $staticPattern) {
    $nl = if ($content.Contains("`r`n")) { "`r`n" } else { "`n" }
    $replacement = '# Desktop Windows: dynamic CRT (/MD; /MDd when is_debug = true) to match' + $nl +
                   '      # the Qt/CMake RLink build.' + $nl +
                   '      configs = [ ":dynamic_crt" ]'
    $patched = [regex]::Replace($content, $staticPattern, $replacement, 1)
    [System.IO.File]::WriteAllText($buildGn, $patched)
    Write-Step "Patched default_crt to :dynamic_crt in $buildGn"
}
else {
    throw "Could not find the default_crt desktop branch in $buildGn. Apply the /MD edit manually (BUILDING.md section 4)."
}

# --- write args.gn and build each requested configuration -------------------
$ninjaExe = Join-Path $Src 'third_party\ninja\ninja.exe'

foreach ($config in $Configurations) {
    $isDebug = ($config -eq 'Debug')
    $outRel = $OutByConfig[$config]
    $outDir = Join-Path $Src $outRel
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null

    $argsGnPath = Join-Path $outDir 'args.gn'
    $argsText = ((Get-WebRtcArgs $isDebug) -join "`r`n") + "`r`n"
    [System.IO.File]::WriteAllText($argsGnPath, $argsText)
    Write-Step "Wrote $argsGnPath"

    if ($SkipBuild) {
        continue
    }

    Invoke-Native "gn gen $outRel" {
        Push-Location $Src
        try { & gn gen $outRel } finally { Pop-Location }
    }

    $buildTargets = @(
        'webrtc',
        'builtin_video_decoder_factory',
        'builtin_video_encoder_factory',
        'api/video:adapted_video_track_source'
    )

    Invoke-Native "build $config ($outRel)" {
        Push-Location $Src
        try {
            if (Test-Path -LiteralPath $ninjaExe) {
                & $ninjaExe -C $outRel @buildTargets
            }
            else {
                & autoninja -C $outRel @buildTargets
            }
        }
        finally { Pop-Location }
    }

    $expected = @(
        'obj\webrtc.lib',
        'obj\api\video\adapted_video_track_source.lib',
        'obj\api\video_codecs\builtin_video_decoder_factory.lib',
        'obj\api\video_codecs\builtin_video_encoder_factory.lib',
        'obj\api\video_codecs\rtc_software_fallback_wrappers.lib',
        'obj\media\rtc_internal_video_codecs.lib',
        'obj\media\rtc_simulcast_encoder_adapter.lib',
        'gen'
    )
    $missing = @($expected | Where-Object { -not (Test-Path -LiteralPath (Join-Path $outDir $_)) })
    if ($missing.Count -gt 0) {
        throw "Build finished but these outputs are missing under ${outDir}: $($missing -join ', ')"
    }
    Write-Step "$config build outputs verified."
}

Write-Step 'Done.'
