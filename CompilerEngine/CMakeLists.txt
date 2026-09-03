# This directory is configured as an LLVM external project after Swift.
# Building the final dylib inside the same CMake graph lets CMake carry the
# complete Swift/Clang/LLVM static dependency closure into one iOS library.

if(NOT TARGET swiftFrontendTool)
  message(FATAL_ERROR "XToolCompilerEngine requires the Swift swiftFrontendTool target")
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

# Linux-hosted CMake's iOS platform configuration does not populate
# CMAKE_SHARED_LIBRARY_RUNTIME_C_FLAG. Asking CMake itself for an @rpath install
# name therefore fails during generation. Build the dylib without CMake-managed
# runtime paths and let the bootstrap script set the final Mach-O install name
# with llvm-install-name-tool after linking.
set_target_properties(XToolCompilerEngine PROPERTIES
  OUTPUT_NAME "XToolCompilerEngine"
  PREFIX "lib"
  POSITION_INDEPENDENT_CODE ON
  BUILD_WITH_INSTALL_RPATH OFF
  SKIP_BUILD_RPATH TRUE
  INSTALL_RPATH ""
  LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/../package"
)
