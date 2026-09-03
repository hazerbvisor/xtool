# This directory is configured as an LLVM external project after Swift.
# Building the final dylib inside the same CMake graph lets CMake carry the
# complete Swift/Clang/LLVM static dependency closure into one iOS library.

if(NOT TARGET swiftFrontendTool)
  message(FATAL_ERROR "XToolCompilerEngine requires the Swift swiftFrontendTool target")
endif()

# We configure the iOS target from a Linux host. LLVM's generic host options
# treat CMAKE_SYSTEM_NAME=iOS as non-Darwin in a few places, which can leak the
# ELF-only -Wl,-z,defs flag into shared-library links. Strip that flag only in
# this external-project directory; all of the Swift/Clang/LLVM dependencies we
# consume here are already-built static archives.
if(CMAKE_SYSTEM_NAME STREQUAL "iOS" AND CMAKE_HOST_SYSTEM_NAME STREQUAL "Linux")
  string(REPLACE "-Wl,-z,defs" "" CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS}")
endif()

add_library(XToolCompilerEngine SHARED
  XToolCompilerEngine.cpp
)

target_include_directories(XToolCompilerEngine PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
  "${LLVM_EXTERNAL_SWIFT_SOURCE_DIR}/include"
  "${LLVM_MAIN_INCLUDE_DIR}"
  "${LLVM_BINARY_DIR}/include"
)

target_compile_features(XToolCompilerEngine PRIVATE cxx_std_17)
target_compile_definitions(XToolCompilerEngine PRIVATE
  XTOOL_COMPILER_ENGINE_VERSION="swift-6.3.2-RELEASE"
)

target_link_libraries(XToolCompilerEngine PRIVATE
  swiftFrontendTool
)

# The Linux Swift/Clang driver otherwise falls back to /usr/bin/ld even for an
# Apple target. -fuse-ld=lld makes Clang select its Mach-O linker (ld64.lld)
# from the Swift toolchain for this final iOS dylib link.
if(CMAKE_SYSTEM_NAME STREQUAL "iOS" AND CMAKE_HOST_SYSTEM_NAME STREQUAL "Linux")
  target_link_options(XToolCompilerEngine PRIVATE "-fuse-ld=lld")
endif()

# Linux-hosted CMake's iOS platform configuration does not populate
# CMAKE_SHARED_LIBRARY_RUNTIME_C_FLAG. Asking CMake itself for an @rpath install
# name therefore fails during generation. Build the dylib without CMake-managed
# runtime paths and let the bootstrap script set the final Mach-O install name
# with llvm-install-name-tool after linking.
set_target_properties(XToolCompilerEngine PROPERTIES
  OUTPUT_NAME "XToolCompilerEngine"
  PREFIX "lib"
  POSITION_INDEPENDENT_CODE ON
  MACOSX_RPATH OFF
  BUILD_WITH_INSTALL_RPATH OFF
  SKIP_BUILD_RPATH TRUE
  INSTALL_RPATH ""
  LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/../package"
)
