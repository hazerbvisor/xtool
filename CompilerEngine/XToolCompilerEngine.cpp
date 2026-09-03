#include "XToolCompilerEngine.h"

#include "swift/FrontendTool/FrontendTool.h"
#include "llvm/ADT/ArrayRef.h"

#ifndef XTOOL_COMPILER_ENGINE_VERSION
#define XTOOL_COMPILER_ENGINE_VERSION "swift-frontend-engine"
#endif

extern "C" int32_t xtool_swift_frontend_run(
    int32_t argc,
    const char *const *argv
) {
    if (argc < 0 || (argc > 0 && argv == nullptr)) {
        return 64;
    }

    llvm::ArrayRef<const char *> arguments(argv, static_cast<size_t>(argc));
    return static_cast<int32_t>(
        swift::performFrontend(arguments, "xtool-mobile", nullptr, nullptr)
    );
}

extern "C" const char *xtool_compiler_engine_version(void) {
    return XTOOL_COMPILER_ENGINE_VERSION;
}
