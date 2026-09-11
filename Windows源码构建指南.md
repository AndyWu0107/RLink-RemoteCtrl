# RLink Windows 源码构建指南

本文面向第一次在全新 Windows 电脑上编译 RLink 的开发者。仓库包含
RLink 的正式源码、CMake 构建系统、界面资源以及运行时使用的 FFmpeg DLL，
但不包含 Qt SDK 和 libwebrtc 的预编译产物。

## 1. 构建目标

构建系统为 CMake + Visual Studio 2022（v143）生成器。`Release` 构建后，
主要产物位于：

```text
x64\Release\RLinkAPP.exe
x64\Release\RLinkUpdater.exe
x64\Release\RemoteCSignalServer.exe
```

`RLinkAPP.exe` 是控制端与被控端共用的客户端，
`RLinkUpdater.exe` 是客户端确认更新后使用的独立更新程序，
`RemoteCSignalServer.exe` 是 WSS 信令服务。

CMake 目标与源码的对应关系：

| 目标 | 类型 | 说明 |
| --- | --- | --- |
| `rlink_core` | 静态库 | 协议 + 会话核心策略 |
| `rlink_auth` | 静态库 | OIDC/OAuth（Qt NetworkAuthorization） |
| `rlink_signaling` | 静态库 | Qt WebSocket 信令客户端 |
| `rlink_webrtc_transport` | 静态库 | libwebrtc 会话 + Windows 采集/编码 |
| `rlink_session_engine` | 静态库 | 进程内会话引擎 |
| `RLinkAPP` | 可执行 | Qt Widgets 客户端 |
| `RemoteCSignalServer` | 可执行 | Qt HTTP/WS 信令服务 |
| `RLinkUpdater` | 可执行 | 独立更新器（不依赖 Qt） |

## 2. 所需环境

建议使用与当前已验证环境一致的版本：

| 组件 | 版本或要求 |
| --- | --- |
| Windows | Windows 10/11 x64 |
| CMake | 3.24 或更高 |
| Visual Studio | Visual Studio 2022 生成工具（或 IDE），含 v143 工具集、MSVC 14.44.x |
| Windows SDK | 10.0.26100.0，或兼容的 Windows 10/11 SDK |
| Qt | Qt 6.11.x，MSVC 2022 64-bit（`msvc2022_64`） |
| WebRTC | 固定 commit `1e2bd46a33bc0a95ff4e032e380f9fcfa2505808` |
| depot_tools | 已验证 revision `3799a497b1e483ab3625b91f9540155e8d311985` |

Qt 安装至少需要能够提供以下模块：

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

CMake 通过 `find_package(Qt6 6.11 REQUIRED ...)` 查找 Qt，MOC/UIC/RCC 由
CMake 的 `AUTOMOC`/`AUTOUIC`/`AUTORCC` 处理，因此不依赖 Visual Studio 的
Qt 扩展。

### 与 WebRTC 的工具链一致性

WebRTC 由 GN 单独编译，其静态库会被链接进 `RLinkAPP.exe`。WebRTC 使用的
MSVC STL 必须与 CMake 构建一致：若 WebRTC 用 14.51、主程序用 14.44 之类的
不同工具集，链接时会出现无法解析的 `__std_*` 符号。

让两侧保持同一工具集。生成 WebRTC 时把 depot_tools 指向 VS2022 生成工具，
使其选用 `14.44.35207`：

```powershell
$env:DEPOT_TOOLS_WIN_TOOLCHAIN = '0'
$env:GYP_MSVS_OVERRIDE_PATH = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools'
```

## 3. 克隆源码

```powershell
git clone --branch release --single-branch `
  https://github.com/dyhwdnmd/RLink-RemoteCtrl.git
cd .\RLink-RemoteCtrl
```

仓库没有必须初始化的 Git submodule。正常编译所需的 FFmpeg 头文件、
运行时 DLL 和许可证已包含在 `third_party\ffmpeg_d3d11va` 中。

## 4. 准备 libwebrtc

libwebrtc 是整个构建中体积最大、耗时最长的外部依赖。不要使用任意版本
的预编译库；WebRTC 的源码、生成头文件、静态库、编译器 ABI 和 CRT
配置必须互相匹配。

先安装并将 `depot_tools` 加入 `PATH`，然后按照 WebRTC 官方 Windows
流程取得源码。以下示例把源码放在 `E:\webrtc_src\src`：

```powershell
New-Item -ItemType Directory -Force E:\webrtc_src
Set-Location E:\webrtc_src
fetch --nohooks webrtc
Set-Location .\src
git checkout 1e2bd46a33bc0a95ff4e032e380f9fcfa2505808
gclient sync -D
```

在 `E:\webrtc_src\src\out\ReleaseMD\args.gn` 写入：

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

`use_dynamic_crt_for_webrtc = true` 用于选择动态 CRT（`/MD`）以匹配 CMake
构建；若 WebRTC 使用 `/MT`，链接时会出现 `LNK2038 RuntimeLibrary` 不匹配。
在较新的 WebRTC 版本中该参数可能已不在 `declare_args()` 中，此时默认即为
`/MD`，该赋值无害。

生成并编译 WebRTC（同时应用第 2 节的 v143 工具链覆盖）：

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

如果 `autoninja`（siso）卡住，可改用普通 ninja：

```powershell
third_party\ninja\ninja.exe -C out\ReleaseMD `
  webrtc `
  builtin_video_decoder_factory `
  builtin_video_encoder_factory `
  api/video:adapted_video_track_source
```

编译完成后，至少确认以下文件存在：

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

如果修改了 WebRTC commit 或 GN 参数，应删除旧输出目录后重新生成，不能
把不同版本产生的头文件与 `.lib` 混用。

## 5. 配置本机路径

RLink 不会把本机路径提交到 Git。CMake 构建读取三个环境变量：

| 变量 | 含义 |
| --- | --- |
| `RLINK_QT_DIR` | Qt 6.11+ `msvc2022_64` 套件（需含 `lib\cmake\Qt6`） |
| `RLINK_WEBRTC_SRC` | WebRTC 源码目录 |
| `RLINK_WEBRTC_OUT` | WebRTC 的 GN 输出目录（`out\ReleaseMD`） |

在当前终端临时设置，或设为用户级持久变量：

```powershell
$env:RLINK_QT_DIR     = 'E:\Qt6\6.11.1\msvc2022_64'
$env:RLINK_WEBRTC_SRC = 'E:\webrtc_src\src'
$env:RLINK_WEBRTC_OUT = 'E:\webrtc_src\src\out\ReleaseMD'
```

在 Windows 上也可以放进一个被 Git 忽略的本地文件。复制模板：

```bat
copy cmake\local.bat.example cmake\local.bat
```

然后编辑 `cmake\local.bat`：

```bat
set "RLINK_QT_DIR=E:\Qt6\6.11.1\msvc2022_64"
set "RLINK_WEBRTC_SRC=E:\webrtc_src\src"
set "RLINK_WEBRTC_OUT=E:\webrtc_src\src\out\ReleaseMD"
```

`cmake_configure.bat` 会在该文件存在时自动加载它。`cmake\local.bat` 已被
`.gitignore` 排除，不要在其中写入 Logto 密钥、服务器证书或其他凭证。

## 6. 配置与编译

在仓库根目录，可以运行辅助脚本：

```powershell
.\cmake_configure.bat
cmake --build --preset windows-msvc-x64-v143-release -- /m
```

也可以直接使用 CMake 预设：

```powershell
cmake --preset windows-msvc-x64-v143
cmake --build --preset windows-msvc-x64-v143-release -- /m
```

`cmake --preset windows-msvc-x64-v143` 会在 `out\build\windows-msvc-x64-v143` 下生成
`Visual Studio 17 2022`、x64、工具集 `v143` 的工程。构建过程会把 Qt、
FFmpeg 和平台插件复制到 `x64\Release`。

如果修改了环境变量而 CMake 缓存仍是旧值，用 `--fresh` 重新配置：

```powershell
cmake --preset windows-msvc-x64-v143 --fresh
```

成功后检查：

```powershell
Test-Path .\x64\Release\RLinkAPP.exe
Test-Path .\x64\Release\RLinkUpdater.exe
Test-Path .\x64\Release\RemoteCSignalServer.exe
Test-Path .\x64\Release\platforms\qwindows.dll
Test-Path .\x64\Release\avcodec-62.dll
```

全部返回 `True` 表示主要程序和运行时文件已经生成。

## 7. 常见问题

### CMake 报 “Missing dependency locations”

`RLINK_QT_DIR`、`RLINK_WEBRTC_SRC` 或 `RLINK_WEBRTC_OUT` 为空。按第 5 节设置
环境变量或创建 `cmake\local.bat` 后重新配置。

### 找不到 Qt6Config.cmake

`RLINK_QT_DIR` 必须指向 `msvc2022_64` 根目录，而不是 Qt 安装器根目录。该
目录下必须存在 `lib\cmake\Qt6`、`include`、`lib`、`bin` 和 `plugins`。
Qt 6.8 及更早版本不满足要求：代码使用了 Qt 6.11 引入的 NetworkAuth API。

### WebRTC static libraries were not found

`RLINK_WEBRTC_OUT` 必须指向 GN 输出目录（例如 `out\ReleaseMD`），CMake 会在
其下查找 `obj\webrtc.lib`。

### LNK2038：RuntimeLibrary 不匹配

构建固定使用 `/MD`。按第 4 节用动态 CRT 重新生成 WebRTC。

### 链接 RLinkAPP 时出现无法解析的 `__std_*` 符号（LNK2001）

WebRTC 与主程序使用了不同的 MSVC STL 版本。用与主程序相同的工具集重新生成
WebRTC（`GYP_MSVS_OVERRIDE_PATH` 指向 VS2022 生成工具，即 MSVC
14.44.35207），然后重新构建。

### 找不到 builtin_video_* 或 adapted_video_track_source

这些实现不保证全部包含在聚合 `webrtc.lib` 中。重新执行第 4 节列出的
`autoninja` 命令，不要只构建单个 `webrtc` 目标。

### 构建后程序启动时提示缺少 DLL

请构建完整的 CMake 工程（所有目标），不要只构建单个目标；构建后的部署步骤
会复制 Qt 运行时与插件，并拷贝
`third_party\ffmpeg_d3d11va\prefix\bin` 中的运行时 DLL。

## 8. 编译成功与可连接运行的区别

完成以上步骤即可生成客户端和信令服务，但实际登录、WSS 信令和远程连接
还依赖部署环境中的 Logto 配置、TLS 证书、服务端密钥和可访问的信令地址。
这些运行凭证不会提交到源码仓库。部署信令服务前请检查
`scripts\New-PublicSignalingDeployment.ps1`、
`scripts\Set-LogtoM2MSecret.ps1` 和
`scripts\Start-PublicSignalingServer.ps1`，不要把生产密钥写入 Git。

首次修改依赖或工具链后，建议至少执行一次双机冒烟测试：登录、创建/加入
房间、验证码连接、我的设备连接、屏幕共享、键鼠控制、剪贴板和文件传输。
