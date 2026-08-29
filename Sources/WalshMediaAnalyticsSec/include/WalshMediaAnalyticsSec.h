#ifndef WALSH_MEDIA_ANALYTICS_SEC_H
#define WALSH_MEDIA_ANALYTICS_SEC_H

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Reads signed `beta-reports-active` from the Mach-O at `path`.
/// iOS does not expose `SecTask.h`; entitlements live in the code signature.
bool WalshMediaExecutableHasBetaReportsActive(const char *path);

/// Parses an entitlements XML/binary plist, or DER bytes containing the key.
bool WalshMediaEntitlementsDataHasBetaReportsActive(const void *bytes, size_t length);

#ifdef __cplusplus
}
#endif

#endif
