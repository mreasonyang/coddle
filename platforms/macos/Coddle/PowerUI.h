// Coddle — PowerUI interop bridge (Objective-C).
//
// Independent implementation written for Coddle. It uses only *interface facts*
// observed on macOS 27 (26A428): the private framework path, the class name, and
// the selector signatures needed for interop. No third-party source is copied.
// The framework is loaded dynamically; nothing is linked at build time.
//
// Contract: every function returns 0 on success, -1 on failure. On failure the
// optional *err is set to a malloc'd UTF-8 string the caller must free with
// coddle_powerui_free().

#ifndef CODDLE_POWERUI_H
#define CODDLE_POWERUI_H

#ifdef __cplusplus
extern "C" {
#endif

/// 1 if a manual charge limit (MCL) is supported on this Mac, else 0.
int coddle_powerui_supported(void);

/// Fill `limits[0..max)` with the accepted upper limits (ascending). Sets *count.
int coddle_powerui_available_limits(int *limits, int max, int *count, char **err);

/// Read the configured limit and whether it is currently enforced.
/// A disabled limit reads as 100 with enabled = 0.
int coddle_powerui_get(int *limit, int *enabled, char **err);

/// Enable the limit at `limit` (must be one of the available limits; 100 disables).
int coddle_powerui_set(int limit, char **err);

/// Turn the limit off (PowerUIAgent remembers the last value).
int coddle_powerui_disable(char **err);

/// 1 only when the native temporary-limit API is available.
int coddle_powerui_temporary_full_supported(void);

/// Temporarily disable the charge limit. Never falls back to permanent disable.
int coddle_powerui_charge_to_full_now(char **err);

/// Free a string returned via an err out-parameter.
void coddle_powerui_free(char *p);

#ifdef __cplusplus
}
#endif

#endif // CODDLE_POWERUI_H
