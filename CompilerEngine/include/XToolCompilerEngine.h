#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Stable ABI exposed to XToolMobileCore.
/// argv contains Swift frontend arguments such as `-frontend -c ...`.
int32_t xtool_swift_frontend_run(int32_t argc, const char *const *argv);

/// Human-readable compiler engine build/version string.
const char *xtool_compiler_engine_version(void);

#ifdef __cplusplus
}
#endif
