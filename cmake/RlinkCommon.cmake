# Common interface target and helper for shared compile settings.
#
# Mirrors build/RemoteProcessCommon.props (release-only, /MD, C++20, UTF-8,
# warnings-as-info level 3, SDL checks).

add_library(rlink_project INTERFACE)

# Project sources include headers as "src/..." relative to the repository root.
target_include_directories(rlink_project INTERFACE "${CMAKE_SOURCE_DIR}")
target_compile_features(rlink_project INTERFACE cxx_std_20)

if(MSVC)
  target_compile_options(rlink_project INTERFACE
    /utf-8 /Zc:__cplusplus /permissive- /MP /W3 /sdl /Zi)
  target_compile_definitions(rlink_project INTERFACE
    _UNICODE UNICODE NOMINMAX WIN32_LEAN_AND_MEAN)
  target_link_options(rlink_project INTERFACE /DEBUG)
endif()

# rlink_apply_common(<target>): apply the shared settings above.
function(rlink_apply_common target)
  target_link_libraries(${target} PRIVATE rlink_project)
endfunction()
