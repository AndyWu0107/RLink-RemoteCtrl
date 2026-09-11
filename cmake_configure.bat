@echo off
setlocal EnableExtensions

rem ===========================================================================
rem  RemoteC CMake configure helper (Windows x64, VS2022 v143, Qt 6.11+).
rem
rem  Override any of these by defining the environment variable first:
rem    RLINK_QT_DIR        Qt 6.11+ msvc2022_64 kit
rem    RLINK_WEBRTC_SRC    WebRTC source checkout (built separately with GN)
rem    RLINK_WEBRTC_OUT    WebRTC GN out dir (ReleaseMD)
rem    RLINK_BUILD_DIR     CMake binary directory
rem    RLINK_WIN_SDK       Windows SDK version (default 10.0.26100.0)
rem
rem  Extra arguments are forwarded to CMake (e.g. -DCMAKE_...=...).
rem
rem  This configures only; build with:
rem    cmake --build "%RLINK_BUILD_DIR%" --config Release -- /m
rem ===========================================================================

if not defined RLINK_QT_DIR     set "RLINK_QT_DIR=D:\Qt6\6.11.2\msvc2022_64"
if not defined RLINK_WEBRTC_SRC set "RLINK_WEBRTC_SRC=D:\webrtc_src\src"
if not defined RLINK_WEBRTC_OUT set "RLINK_WEBRTC_OUT=D:\webrtc_src\src\out\ReleaseMD"
if not defined RLINK_BUILD_DIR  set "RLINK_BUILD_DIR=%~dp0build-cmake\v143"
if not defined RLINK_WIN_SDK    set "RLINK_WIN_SDK=10.0.26100.0"
if not defined RLINK_OUTPUT_DIR set "RLINK_OUTPUT_DIR=%~dp0x64"

rem --- locate cmake ----------------------------------------------------------
where cmake >nul 2>nul
if errorlevel 1 (
  echo [ERROR] cmake was not found on PATH.
  exit /b 1
)

rem --- sanity checks ---------------------------------------------------------
if not exist "%RLINK_QT_DIR%\lib\cmake\Qt6\Qt6Config.cmake" (
  echo [ERROR] Qt6 CMake package not found:
  echo         %RLINK_QT_DIR%\lib\cmake\Qt6\Qt6Config.cmake
  echo         Set RLINK_QT_DIR to a Qt 6.11+ msvc2022_64 kit.
  exit /b 1
)

if not exist "%RLINK_WEBRTC_OUT%\obj\webrtc.lib" (
  echo [ERROR] WebRTC static library not found:
  echo         %RLINK_WEBRTC_OUT%\obj\webrtc.lib
  echo         Build WebRTC with GN first or set RLINK_WEBRTC_OUT.
  exit /b 1
)

echo [configure] source      = %~dp0
echo [configure] build dir   = %RLINK_BUILD_DIR%
echo [configure] Qt          = %RLINK_QT_DIR%
echo [configure] WebRTC src  = %RLINK_WEBRTC_SRC%
echo [configure] WebRTC out  = %RLINK_WEBRTC_OUT%
echo [configure] SDK version = %RLINK_WIN_SDK%
echo [configure] output dir  = %RLINK_OUTPUT_DIR%
echo.

cmake -S "%~dp0." -B "%RLINK_BUILD_DIR%" ^
      -G "Visual Studio 17 2022" -A x64 -T v143 ^
      -DCMAKE_SYSTEM_VERSION=%RLINK_WIN_SDK% ^
      -DRLINK_QT_DIR="%RLINK_QT_DIR%" ^
      -DRLINK_WEBRTC_SRC="%RLINK_WEBRTC_SRC%" ^
      -DRLINK_WEBRTC_OUT="%RLINK_WEBRTC_OUT%" ^
      -DRLINK_OUTPUT_DIR="%RLINK_OUTPUT_DIR%" %*

if errorlevel 1 (
  echo.
  echo [ERROR] CMake configure failed.
  exit /b 1
)

echo.
echo [configure] done. Build with:
echo   cmake --build "%RLINK_BUILD_DIR%" --config Release -- /m
exit /b 0
