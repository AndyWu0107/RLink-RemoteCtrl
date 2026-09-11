cmake_minimum_required(VERSION 3.24)

project(RLinkRemoteCtrl
  VERSION 0.1.0
  DESCRIPTION "RemoteC remote control suite"
  LANGUAGES CXX)

list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")

# ---------------------------------------------------------------------------
# Local machine paths. These are Git-ignored; copy cmake/RlinkLocal.cmake.example
# to cmake/RlinkLocal.cmake and adjust, or pass -D<VAR>=... on the command line.
# ---------------------------------------------------------------------------
set(RLINK_QT_DIR "D:/Qt6/6.11.2/msvc2022_64" CACHE PATH
    "Qt 6.11+ msvc2022_64 kit directory")
set(RLINK_WEBRTC_SRC "D:/webrtc_src/src" CACHE PATH
    "Google WebRTC source checkout (built separately with GN)")
set(RLINK_WEBRTC_OUT "D:/webrtc_src/src/out/ReleaseMD" CACHE PATH
    "WebRTC GN out directory (Release, dynamic CRT)")
set(RLINK_OUTPUT_DIR "${CMAKE_CURRENT_SOURCE_DIR}/x64" CACHE PATH
    "Root directory for CMake build outputs (matches the MSBuild x64 layout)")
include("${CMAKE_CURRENT_SOURCE_DIR}/cmake/RlinkLocal.cmake" OPTIONAL)

# ---------------------------------------------------------------------------
# Language / runtime settings (match build/RemoteProcessCommon.props)
# ---------------------------------------------------------------------------
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreadedDLL")
set(CMAKE_POSITION_INDEPENDENT_CODE OFF)

if(NOT WIN32)
  message(FATAL_ERROR
    "The CMake build currently targets Windows only. The source tree is being "
    "restructured for cross-platform support; non-Windows builds are not ready yet.")
endif()

# ---------------------------------------------------------------------------
# Qt 6.11+ (6.8 is too old for the NetworkAuth APIs used by RemoteAuth)
# ---------------------------------------------------------------------------
list(APPEND CMAKE_PREFIX_PATH "${RLINK_QT_DIR}")
find_package(Qt6 6.11 REQUIRED COMPONENTS
  Core Gui Widgets Network WebSockets NetworkAuth HttpServer Sql)

# Enables AUTOMOC / AUTOUIC / AUTORCC for every target (per project policy:
# any target touching Qt must have auto moc/uic/rcc enabled).
qt_standard_project_setup()

# ---------------------------------------------------------------------------
# Output layout: x64/<Config>/ - the same directory the MSBuild solution uses
# (build/*.props set OutDir to ..\x64\$(Configuration)\), so the two build
# systems place the binaries, Qt runtime and FFmpeg DLLs side by side.
# ---------------------------------------------------------------------------
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${RLINK_OUTPUT_DIR}/$<CONFIG>")
set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY "${RLINK_OUTPUT_DIR}/$<CONFIG>")
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY "${RLINK_OUTPUT_DIR}/$<CONFIG>")

include("${CMAKE_CURRENT_SOURCE_DIR}/cmake/RlinkCommon.cmake")
include("${CMAKE_CURRENT_SOURCE_DIR}/cmake/RlinkWebRtc.cmake")
include("${CMAKE_CURRENT_SOURCE_DIR}/cmake/RlinkFfmpeg.cmake")
include("${CMAKE_CURRENT_SOURCE_DIR}/cmake/RlinkDeploy.cmake")
include("${CMAKE_CURRENT_SOURCE_DIR}/cmake/targets.cmake")
