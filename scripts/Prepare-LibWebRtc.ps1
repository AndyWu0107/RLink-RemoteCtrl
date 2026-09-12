# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 dyhwdnmd (https://github.com/dyhwdnmd)
<#
.SYNOPSIS
Prepares the pinned libwebrtc static libraries used by the RLink CMake build.

.DESCRIPTION
Fetches/updates the WebRTC checkout at the revision pinned in BUILDING.md,
forces the dynamic CRT, writes the GN args and builds the static libraries that
RLinkAPP links against.

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

.PARAMETER Configurations
Which GN output trees to build: Release (out\ReleaseMD), Debug (out\DebugMD) or
both. Default: both.

.PARAMETER SkipFetch
Skip fetch/gclient sync and only re-patch, gn gen and build an existing checkout.

.PARAMETER SkipBuild
Patch and write args.gn only; do not run gn gen or ninja.

.EXAMPLE
.\scripts\Prepare-LibWebRtc.ps1 -Root D:\dev\libs\webrtc_src -DepotTools D:\dev\libs\depot_tools

.EXAMPLE
.\scripts\Prepare-LibWebRtc.ps1 -SkipFetch -Configurations Release
#>
[CmdletBinding()]
param(
    [string]$Root,
    [string]$DepotTools,
    [ValidateSet('Release', 'Debug')]
    [string[]]$Configurations = @('Release', 'Debug'),
    [switch]$SkipFetch,
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'

$WebRtcCommit = '1e2bd46a33bc0a95ff4e032e380f9fcfa2505808'

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

# depot_tools must be first on PATH and must not update itself off the pinned revision.
$env:PATH = "$DepotTools;$env:PATH"
$env:DEPOT_TOOLS_UPDATE = '0'
$env:DEPOT_TOOLS_WIN_TOOLCHAIN = '0'

Write-Step "WebRTC src : $Src"
Write-Step "depot_tools: $DepotTools"
Write-Step "configs    : $($Configurations -join ', ')"

# --- bootstrap the depot_tools wrappers if necessary ------------------------
if (-not (Test-Path -LiteralPath (Join-Path $DepotTools 'git.bat'))) {
    Invoke-Native 'bootstrap depot_tools (win_tools.bat)' {
        & (Join-Path $DepotTools 'bootstrap\win_tools.bat')
    }
}

# --- fetch / sync the pinned WebRTC checkout --------------------------------
if (-not $SkipFetch) {
    New-Item -ItemType Directory -Force -Path $Root | Out-Null

    if (-not (Test-Path -LiteralPath (Join-Path $Src '.git'))) {
        if (Test-Path -LiteralPath (Join-Path $Root '.gclient')) {
            Invoke-Native 'gclient sync (initial checkout)' {
                Push-Location $Root
                try { & gclient sync --nohooks --with_branch_heads } finally { Pop-Location }
            }
        }
        else {
            Invoke-Native 'fetch --nohooks webrtc' {
                Push-Location $Root
                try { & fetch --nohooks webrtc } finally { Pop-Location }
            }
        }
    }

    Invoke-Native "git checkout $WebRtcCommit" {
        Push-Location $Src
        try {
            & git fetch origin
            if ($LASTEXITCODE -ne 0) { return }
            & git checkout $WebRtcCommit
        }
        finally { Pop-Location }
    }

    Invoke-Native 'gclient sync -D' {
        Push-Location $Src
        try { & gclient sync -D } finally { Pop-Location }
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
