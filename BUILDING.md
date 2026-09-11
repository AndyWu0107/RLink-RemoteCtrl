# Building RLink on Windows

This guide is intended for developers building RLink for the first time on a
clean Windows machine. The repository contains the production source code, the
CMake build system, UI assets, FFmpeg headers, and runtime DLLs. It does not
include the Qt SDK or prebuilt libwebrtc artifacts.

## 1. Build targets

The build system is CMake with a Visual Studio 2022 (v143) generator. A
`Release` build produces the main executables under:

```text
x64\Release\RLinkAPP.exe
x64\Release\RLinkUpdater.exe
x64\Release\RemoteCSignalServer.exe
```

`RLinkAPP.exe` is the shared controller/controlled-side client.
`RLinkUpdater.exe` is the standalone updater used by installed clients.
`RemoteCSignalServer.exe` is the WSS signaling server.

CMake targets map to the sources as follows:

| Target | Kind | Notes |
| --- | --- | --- |
| `rlink_core` | static lib | protocols + core session policy |
| `rlink_auth` | static lib | OIDC/OAuth (Qt NetworkAuthorization) |
| `rlink_signaling` | static lib | Qt WebSocket signaling client |
| `rlink_webrtc_transport` | static lib | libwebrtc session + Windows capture/encode |
| `rlink_session_engine` | static lib | in-process session engine |
| `RLinkAPP` | exe | Qt Widgets client |
| `RemoteCSignalServer` | exe | Qt HTTP/WS signaling server |
| `RLinkUpdater` | exe | standalone updater (no Qt) |

## 2. Prerequisites

Use the versions from the currently verified environment when possible:

| Component | Version or requirement |
| --- | --- |
| Windows | Windows 10/11 x64 |
| CMake | 3.24 or newer |
| Visual Studio | Visual Studio 2022 Build Tools (or IDE) with the v143 toolset, MSVC 14.44.x |
| Windows SDK | 10.0.26100.0 or a compatible Windows 10/11 SDK |
| Qt | Qt 6.11.x, MSVC 2022 64-bit (`msvc2022_64`) |
| WebRTC | Pinned commit `1e2bd46a33bc0a95ff4e032e380f9fcfa2505808` |
| depot_tools | Verified revision `3799a497b1e483ab3625b91f9540155e8d311985` |

The Qt installation must provide at least these modules:

```text
Qt Core
Qt GUI
Qt Widgets
Qt Network
Qt WebSockets
Qt Network Authorization
Qt HTTP Server
Qt SQL
Qt SVG
```

CMake locates Qt through `find_package(Qt6 6.11 REQUIRED ...)`. MOC, UIC, and
RCC are handled by CMake (`AUTOMOC`/`AUTOUIC`/`AUTORCC`), so the Qt Visual
Studio extension is not required.

### Toolchain consistency with WebRTC

WebRTC is compiled separately with GN, and its static libraries are linked into
`RLinkAPP.exe`. The MSVC STL used by WebRTC must match the one used by the CMake
build. If WebRTC is built with a different toolset (for example MSVC 14.51 while
the app uses 14.44), linking fails with unresolved `__std_*` symbols.

Keep both sides on the same toolset. When generating WebRTC, point depot_tools
at the VS2022 Build Tools installation so that WebRTC picks `14.44.35207`:

```powershell
$env:DEPOT_TOOLS_WIN_TOOLCHAIN = '0'
$env:GYP_MSVS_OVERRIDE_PATH = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools'
```

## 3. Clone the source code

```powershell
git clone --branch release --single-branch `
  https://github.com/dyhwdnmd/RLink-RemoteCtrl.git
cd .\RLink-RemoteCtrl
```

There are no required Git submodules. The FFmpeg headers, runtime DLLs, and
licenses required by a normal build are already stored under
`third_party\ffmpeg_d3d11va`.

## 4. Prepare libwebrtc

libwebrtc is the largest and most time-consuming external dependency. Do not
use an arbitrary prebuilt version. The WebRTC source, generated headers,
static libraries, compiler ABI, and CRT configuration must match.

Install `depot_tools`, add it to `PATH`, and obtain the WebRTC source through
the official Windows workflow. The following example uses
`E:\webrtc_src\src`:

```powershell
New-Item -ItemType Directory -Force E:\webrtc_src
Set-Location E:\webrtc_src
fetch --nohooks webrtc
Set-Location .\src
git checkout 1e2bd46a33bc0a95ff4e032e380f9fcfa2505808
gclient sync -D
```

Create `E:\webrtc_src\src\out\ReleaseMD\args.gn` with:

```gn
is_debug = false
target_cpu = "x64"
rtc_include_tests = false
use_custom_libcxx = false
use_lld = false
use_dynamic_crt_for_webrtc = true
proprietary_codecs = true
ffmpeg_branding = "Chrome"
```

`use_dynamic_crt_for_webrtc = true` selects the dynamic CRT (`/MD`) to match
the CMake build; a `/MT` WebRTC library produces an `LNK2038 RuntimeLibrary`
mismatch at link time. On current WebRTC revisions this argument may not exist
in `declare_args()`; in that case the default is already `/MD`, and the value is
harmless.

Generate and build WebRTC (using the v143 toolchain override from section 2):

```powershell
Set-Location E:\webrtc_src\src
$env:DEPOT_TOOLS_WIN_TOOLCHAIN = '0'
$env:GYP_MSVS_OVERRIDE_PATH = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools'

gn gen out\ReleaseMD
autoninja -C out\ReleaseMD `
  webrtc `
  builtin_video_decoder_factory `
  builtin_video_encoder_factory `
  api/video:adapted_video_track_source
```

If `autoninja` (siso) stalls, run plain `ninja` instead:

```powershell
third_party\ninja\ninja.exe -C out\ReleaseMD `
  webrtc `
  builtin_video_decoder_factory `
  builtin_video_encoder_factory `
  api/video:adapted_video_track_source
```

Verify that at least the following outputs exist:

```text
out\ReleaseMD\obj\webrtc.lib
out\ReleaseMD\obj\api\video\adapted_video_track_source.lib
out\ReleaseMD\obj\api\video_codecs\builtin_video_decoder_factory.lib
out\ReleaseMD\obj\api\video_codecs\builtin_video_encoder_factory.lib
out\ReleaseMD\obj\api\video_codecs\rtc_software_fallback_wrappers.lib
out\ReleaseMD\obj\media\rtc_internal_video_codecs.lib
out\ReleaseMD\obj\media\rtc_simulcast_encoder_adapter.lib
out\ReleaseMD\gen
```

If you change the WebRTC commit or GN arguments, remove the old output
directory and regenerate it. Never mix headers and libraries generated from
different revisions.

## 5. Configure local paths

RLink does not commit machine-specific paths. The CMake build reads three
environment variables:

| Variable | Meaning |
| --- | --- |
| `RLINK_QT_DIR` | Qt 6.11+ `msvc2022_64` kit (must contain `lib\cmake\Qt6`) |
| `RLINK_WEBRTC_SRC` | WebRTC source checkout |
| `RLINK_WEBRTC_OUT` | WebRTC GN output directory (`out\ReleaseMD`) |

Set them for the current shell, or persistently for the user:

```powershell
$env:RLINK_QT_DIR     = 'E:\Qt6\6.11.1\msvc2022_64'
$env:RLINK_WEBRTC_SRC = 'E:\webrtc_src\src'
$env:RLINK_WEBRTC_OUT = 'E:\webrtc_src\src\out\ReleaseMD'
```

On Windows you can instead keep them in a Git-ignored file. Copy the template:

```bat
copy cmake\local.bat.example cmake\local.bat
```

and edit `cmake\local.bat`:

```bat
set "RLINK_QT_DIR=E:\Qt6\6.11.1\msvc2022_64"
set "RLINK_WEBRTC_SRC=E:\webrtc_src\src"
set "RLINK_WEBRTC_OUT=E:\webrtc_src\src\out\ReleaseMD"
```

`cmake_configure.bat` loads `cmake\local.bat` automatically when present.
`cmake\local.bat` is ignored by Git. Do not store Logto secrets, server
certificates, or other credentials in it.

## 6. Configure and build

From the repository root, either run the helper script:

```powershell
.\cmake_configure.bat
cmake --build --preset windows-msvc-x64-v143-release -- /m
```

or use the CMake preset directly:

```powershell
cmake --preset windows-msvc-x64-v143
cmake --build --preset windows-msvc-x64-v143-release -- /m
```

`cmake --preset windows-msvc-x64-v143` configures a `Visual Studio 17 2022` x64 project
with toolset `v143` into `out\build\windows-msvc-x64-v143`. The build copies Qt, FFmpeg, and
platform plugins into `x64\Release`.

If you change an environment variable and the CMake cache is stale, reconfigure
with `--fresh`:

```powershell
cmake --preset windows-msvc-x64-v143 --fresh
```

Verify the main outputs after a successful build:

```powershell
Test-Path .\x64\Release\RLinkAPP.exe
Test-Path .\x64\Release\RLinkUpdater.exe
Test-Path .\x64\Release\RemoteCSignalServer.exe
Test-Path .\x64\Release\platforms\qwindows.dll
Test-Path .\x64\Release\avcodec-62.dll
```

All five commands should return `True`.

## 7. Troubleshooting

### CMake reports "Missing dependency locations"

`RLINK_QT_DIR`, `RLINK_WEBRTC_SRC`, or `RLINK_WEBRTC_OUT` is empty. Set the
environment variables (section 5) or create `cmake\local.bat`, then reconfigure.

### Qt6Config.cmake not found

`RLINK_QT_DIR` must point to the `msvc2022_64` kit root, not the Qt installer
root. The directory must contain `lib\cmake\Qt6`, `include`, `lib`, `bin`, and
`plugins`. Qt 6.8 or older is not sufficient: the code uses NetworkAuth APIs
introduced in Qt 6.11.

### WebRTC static libraries were not found

`RLINK_WEBRTC_OUT` must be the GN output directory (for example
`out\ReleaseMD`). CMake looks for `obj\webrtc.lib` inside it.

### LNK2038: RuntimeLibrary mismatch

The build uses `/MD`. Regenerate WebRTC with dynamic CRT (see section 4).

### LNK2001: unresolved `__std_*` symbols when linking RLinkAPP

WebRTC and the application were built with different MSVC STL versions. Regenerate
WebRTC with the same toolset as the app (`GYP_MSVS_OVERRIDE_PATH` pointing at the
VS2022 Build Tools, i.e. MSVC 14.44.35207), then rebuild.

### builtin_video_* or adapted_video_track_source is missing

These implementations are not guaranteed to be contained in the aggregate
`webrtc.lib`. Run the complete `autoninja` command from section 4 instead of
building only the `webrtc` target.

### The built application reports missing DLLs

Build the full CMake build (all targets) rather than a single target; the
post-build steps deploy the Qt runtime and plugins and copy the runtime DLLs
from `third_party\ffmpeg_d3d11va\prefix\bin`.

## 8. Building versus connecting to deployed services

The steps above produce the client and signaling-server executables. Actual
login, WSS signaling, and remote-control sessions also require deployment-side
Logto configuration, TLS certificates, server secrets, and a reachable
signaling endpoint. These runtime credentials are intentionally excluded from
the source repository. Review `scripts\New-PublicSignalingDeployment.ps1`,
`scripts\Set-LogtoM2MSecret.ps1`, and
`scripts\Start-PublicSignalingServer.ps1` before deploying the signaling
server, and never commit production secrets.

After changing dependencies or the toolchain, perform at least one two-machine
smoke test covering login, room creation/joining, verification-code sessions,
My Devices sessions, screen sharing, keyboard and mouse control, clipboard,
and file transfer.
