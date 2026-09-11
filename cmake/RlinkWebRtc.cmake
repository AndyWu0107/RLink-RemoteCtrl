# Prebuilt Google WebRTC (built with GN). CMake consumes the artifacts; GN stays
# the build system for WebRTC itself.
#
# The static libraries under <out>/obj must have been produced with a toolchain
# whose STL matches the consuming targets (v143 / MSVC 14.44.35207). Mixing the
# 14.51 STL with 14.44 produces unresolved __std_* symbols at link time.

if(NOT EXISTS "${RLINK_WEBRTC_OUT}/obj/webrtc.lib")
  message(FATAL_ERROR
    "WebRTC static libraries were not found at:\n"
    "  ${RLINK_WEBRTC_OUT}/obj/webrtc.lib\n"
    "Build WebRTC first (see BUILDING.md) or point RLINK_WEBRTC_OUT at an existing "
    "GN output directory.")
endif()

add_library(rlink_webrtc INTERFACE)

target_include_directories(rlink_webrtc INTERFACE
  "${RLINK_WEBRTC_SRC}"
  "${RLINK_WEBRTC_SRC}/third_party/abseil-cpp"
  "${RLINK_WEBRTC_OUT}/gen"
  "${RLINK_WEBRTC_SRC}/third_party/libyuv/include")

target_compile_definitions(rlink_webrtc INTERFACE
  WEBRTC_WIN RTC_ENABLE_WIN_WGC NOMINMAX WIN32_LEAN_AND_MEAN)

# Extra optimization switches used by the WebRTC-consuming projects.
# /wd4068 4146 4996 mirrors DisableSpecificWarnings in RemoteProcessCommon.props
# (WebRTC headers trigger these; /sdl would otherwise promote them to errors).
if(MSVC)
  target_compile_options(rlink_webrtc INTERFACE /Zo /Gy /Oi /wd4068 /wd4146 /wd4996)
endif()

target_link_libraries(rlink_webrtc INTERFACE
  "${RLINK_WEBRTC_OUT}/obj/webrtc.lib"
  "${RLINK_WEBRTC_OUT}/obj/api/video/adapted_video_track_source.lib"
  "${RLINK_WEBRTC_OUT}/obj/api/video_codecs/builtin_video_decoder_factory.lib"
  "${RLINK_WEBRTC_OUT}/obj/api/video_codecs/builtin_video_encoder_factory.lib"
  "${RLINK_WEBRTC_OUT}/obj/api/video_codecs/rtc_software_fallback_wrappers.lib"
  "${RLINK_WEBRTC_OUT}/obj/media/rtc_internal_video_codecs.lib"
  "${RLINK_WEBRTC_OUT}/obj/media/rtc_simulcast_encoder_adapter.lib"
  d3d11 d3d10 dxgi dwmapi shcore
  mf mfplat mfuuid
  ole32 ws2_32 winmm secur32 crypt32 bcrypt iphlpapi
  dmoguids msdmo wmcodecdspuuid strmiids)
