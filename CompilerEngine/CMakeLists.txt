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

set_target_properties(XToolCompilerEngine PROPERTIES
  OUTPUT_NAME "XToolCompilerEngine"
  PREFIX "lib"
  POSITION_INDEPENDENT_CODE ON
  MACOSX_RPATH ON
  BUILD_WITH_INSTALL_RPATH ON
  INSTALL_NAME_DIR "@rpath"
  LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/../package"
)
