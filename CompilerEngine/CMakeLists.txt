# This directory is configured as an LLVM external project after Swift.
# Building the final dylib inside the same CMake graph lets CMake carry the
# complete Swift/Clang/LLVM static dependency closure into one iOS library.

if(NOT TARGET swiftFrontendTool)
  message(FATAL_ERROR "XToolCompilerEngine requires the Swift swiftFrontendTool target")
endif()

if(NOT TARGET swiftCompilerModules)
  message(FATAL_ERROR "XToolCompilerEngine requires Swift compiler modules so initializeSwiftModules() matches the real swift-frontend executable")
endif()

if(NOT TARGET clangFrontendTool)
  message(FATAL_ERROR "XToolCompilerEngine requires the Clang clangFrontendTool target")
endif()

if(NOT TARGET lldMachO)
  message(FATAL_ERROR "XToolCompilerEngine requires the LLD lldMachO target. Reconfigure the existing LLVM graph with LLVM_ENABLE_PROJECTS=clang;lld.")
endif()

# We configure the iOS target from a Linux host. LLVM's generic host options
# treat CMAKE_SYSTEM_NAME=iOS as non-Darwin in a few places, which can leak the
# ELF-only -Wl,-z,defs flag into shared-library links. Strip that flag only in
# this external-project directory; all of the Swift/Clang/LLVM dependencies we
# consume here are already-built static archives.
if(CMAKE_SYSTEM_NAME STREQUAL "iOS" AND CMAKE_HOST_SYSTEM_NAME STREQUAL "Linux")
  string(REPLACE "-Wl,-z,defs" "" CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS}")

  # LLVMSupport chooses a few system libraries from CMAKE_HOST_UNIX. During our
  # Linux -> iOS cross-build that can propagate Linux's separate librt into the
  # final Mach-O link. iOS provides the relevant runtime APIs through libSystem
  # and has no standalone librt, so remove only the host-only rt dependency.
  if(TARGET LLVMSupport)
    get_target_property(_xtool_support_link_libs LLVMSupport LINK_LIBRARIES)
    if(_xtool_support_link_libs AND NOT _xtool_support_link_libs STREQUAL "_xtool_support_link_libs-NOTFOUND")
      list(REMOVE_ITEM _xtool_support_link_libs rt)
      set_property(TARGET LLVMSupport PROPERTY LINK_LIBRARIES "${_xtool_support_link_libs}")
    endif()

    get_target_property(_xtool_support_interface_libs LLVMSupport INTERFACE_LINK_LIBRARIES)
    if(_xtool_support_interface_libs AND NOT _xtool_support_interface_libs STREQUAL "_xtool_support_interface_libs-NOTFOUND")
      list(REMOVE_ITEM _xtool_support_interface_libs rt)
      set_property(TARGET LLVMSupport PROPERTY INTERFACE_LINK_LIBRARIES "${_xtool_support_interface_libs}")
    endif()
  endif()
endif()

add_library(XToolCompilerEngine SHARED
  XToolCompilerEngine.cpp
  ImmediateModeStubs.cpp
)

target_include_directories(XToolCompilerEngine PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
  "${LLVM_EXTERNAL_SWIFT_SOURCE_DIR}/include"
  "${LLVM_MAIN_INCLUDE_DIR}"
  "${LLVM_BINARY_DIR}/include"
  "${LLVM_MAIN_SRC_DIR}/../clang/include"
  "${LLVM_BINARY_DIR}/tools/clang/include"
  "${LLVM_MAIN_SRC_DIR}/../lld/include"
  "${LLVM_BINARY_DIR}/tools/lld/include"
)

target_compile_features(XToolCompilerEngine PRIVATE cxx_std_17)

# Keep this overrideable so patch-release frontend experiments can reuse the
# preserved LLVM/Clang/LLD object graph without hardcoding a misleading version
# into the dylib. Existing 6.3.2 builds keep their current value by default.
set(XTOOL_COMPILER_ENGINE_VERSION
  "swift-6.3.2-RELEASE+clang+lld+swiftmodules"
  CACHE STRING
  "Version string reported by the embedded XTool compiler engine"
)
target_compile_definitions(XToolCompilerEngine PRIVATE
  XTOOL_COMPILER_ENGINE_VERSION="${XTOOL_COMPILER_ENGINE_VERSION}"
)

target_link_libraries(XToolCompilerEngine PRIVATE
  swiftFrontendTool
  swiftCompilerModules
  clangFrontendTool
  lldMachO
  lldCommon
)

# `swiftCompilerModules` contains Swift object code. Swift's own host-tool and
# host-library CMake helpers apply these runtime search/link flags whenever a
# shared library has HAS_SWIFT_MODULES. XTool is an external-project target, so
# mirror that step explicitly instead of relying on Mach-O autolink directives
# to find libswiftCore and compatibility libraries by accident.
if(COMMAND _add_swift_runtime_link_flags)
  _add_swift_runtime_link_flags(XToolCompilerEngine "." "")
else()
  message(FATAL_ERROR "Swift runtime link helper is unavailable for XToolCompilerEngine")
endif()

# The Linux Swift/Clang driver otherwise falls back to the host ELF linker. A
# stock Swift Linux ld64.lld is also intentionally blocked from iOS linking by
# a downstream Swift LLVM patch, so the repair script can provide a source-
# matched patched Mach-O linker through this cache variable.
set(XTOOL_MACHO_LINKER "" CACHE FILEPATH "Patched host ld64.lld used for Linux-to-iOS linking")
if(CMAKE_SYSTEM_NAME STREQUAL "iOS" AND CMAKE_HOST_SYSTEM_NAME STREQUAL "Linux")
  if(XTOOL_MACHO_LINKER)
    if(NOT EXISTS "${XTOOL_MACHO_LINKER}")
      message(FATAL_ERROR "XTOOL_MACHO_LINKER does not exist: ${XTOOL_MACHO_LINKER}")
    endif()

    # Linux Clang does not reliably translate Darwin driver options when it is
    # cross-linking to iOS. Point it at the patched Mach-O linker explicitly and
    # forward the required target metadata ourselves so ld64.lld never has to
    # guess the Apple platform, architecture, or SDK root.
    target_link_options(XToolCompilerEngine PRIVATE
      "--ld-path=${XTOOL_MACHO_LINKER}"
      "-Wl,-arch,arm64"
      "-Wl,-platform_version,ios,${CMAKE_OSX_DEPLOYMENT_TARGET},${CMAKE_OSX_DEPLOYMENT_TARGET}"
      "-Wl,-syslibroot,${CMAKE_OSX_SYSROOT}"
    )
  else()
    # Kept only for the initial configure pass. repair-mobile-compiler-linker.sh
    # sets XTOOL_MACHO_LINKER before the final engine link is attempted.
    target_link_options(XToolCompilerEngine PRIVATE "-fuse-ld=lld")
  endif()
endif()

# Linux-hosted CMake's iOS platform configuration does not populate
# CMAKE_SHARED_LIBRARY_RUNTIME_C_FLAG. Asking CMake itself for an @rpath install
# name therefore fails during generation. Build the dylib without CMake-managed
# runtime paths and let the bootstrap script set the final Mach-O install name
# with llvm-install-name-tool after linking. Runtime search directories added
# by Swift's helper above are only needed at link time for the ABI-stable iOS
# Swift runtime, so keep CMake from synthesizing extra bundle-local rpaths.
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
