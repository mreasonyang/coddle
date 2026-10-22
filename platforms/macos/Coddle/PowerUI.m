// Coddle — PowerUI interop bridge (see PowerUI.h).
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#include <stdlib.h>
#include <string.h>

#include "PowerUI.h"

static const char *kPowerUIPath =
    "/System/Library/PrivateFrameworks/PowerUI.framework/Versions/A/PowerUI";

// Informal interface declaration of the private PowerUISmartChargeClient.
// Declaring it here gives the compiler the exact call signatures so it emits
// correct objc_msgSend calls. We never link the framework; the class is looked
// up dynamically and every selector is guarded with respondsToSelector:.
@interface PowerUISmartChargeClient : NSObject
- (instancetype)initWithClientName:(NSString *)name;
- (BOOL)isMCLSupported;
- (unsigned char)getMCLLimitWithError:(NSError **)error;
- (unsigned long long)isMCLCurrentlyEnabled:(NSError **)error;
- (NSArray<NSNumber *> *)availableChargeLimitsWithError:(NSError **)error;
- (BOOL)setMCLLimit:(unsigned char)limit error:(NSError **)error;
- (BOOL)disableMCL:(NSError **)error;
- (BOOL)temporarilyDisableMCL:(NSError **)error;
- (BOOL)temporarilyEnableCharging:(NSError **)error;
@end

static PowerUISmartChargeClient *gClient = nil;

#ifdef CODDLE_POWERUI_TESTING
// Supplied only by the isolated bridge fixture. Production always resolves
// the private framework below; no runtime override is exposed to the app.
extern Class coddle_powerui_test_client_class(void);
#endif

static void set_err(char **err, NSString *msg) {
    if (err == NULL) {
        return;
    }
    const char *cstr = (msg != nil) ? [msg UTF8String] : NULL;
    *err = strdup(cstr ? cstr : "unknown PowerUI error");
}

static void set_ns_err(char **err, NSError *e, NSString *fallback) {
    set_err(err, e != nil ? [e localizedDescription] : fallback);
}

static PowerUISmartChargeClient *client(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Exceptions must not unwind through dispatch_once: besides aborting
        // on some runtimes, that can leave future callers waiting forever.
        @try {
#ifdef CODDLE_POWERUI_TESTING
            Class cls = coddle_powerui_test_client_class();
#else
            if (dlopen(kPowerUIPath, RTLD_NOW) == NULL) {
                return;
            }
            Class cls = NSClassFromString(@"PowerUISmartChargeClient");
#endif
            if (cls == Nil) {
                return;
            }
            if (![cls instancesRespondToSelector:@selector(initWithClientName:)]) {
                return;
            }
            id inst = [[cls alloc] initWithClientName:@"coddle"];
            if (inst == nil || ![inst respondsToSelector:@selector(isMCLSupported)] ||
                ![inst respondsToSelector:@selector(getMCLLimitWithError:)] ||
                ![inst respondsToSelector:@selector(isMCLCurrentlyEnabled:)] ||
                ![inst respondsToSelector:@selector(availableChargeLimitsWithError:)] ||
                ![inst respondsToSelector:@selector(setMCLLimit:error:)] ||
                ![inst respondsToSelector:@selector(disableMCL:)]) {
                return;
            }
            gClient = inst;
        } @catch (NSException *ex) {
            // Complete the once token normally and consistently report the
            // bridge unavailable after any private API initialization failure.
            gClient = nil;
        }
    });
    return gClient;
}

int coddle_powerui_supported(void) {
    @autoreleasepool {
        @try {
            PowerUISmartChargeClient *c = client();
            if (c == nil) {
                return 0;
            }
            return [c isMCLSupported] ? 1 : 0;
        } @catch (NSException *ex) {
            return 0;
        }
    }
}

int coddle_powerui_available_limits(int *limits, int max, int *count, char **err) {
    @autoreleasepool {
        if (count == NULL || (limits == NULL && max > 0)) {
            set_err(err, @"Invalid NULL limits or count pointer");
            return -1;
        }
        @try {
            PowerUISmartChargeClient *c = client();
            if (c == nil) {
                set_err(err, @"PowerUI smart charge client is unavailable");
                return -1;
            }
            NSError *e = nil;
            NSArray<NSNumber *> *result = [c availableChargeLimitsWithError:&e];
            if (result == nil || ![result isKindOfClass:[NSArray class]]) {
                set_ns_err(err, e, @"availableChargeLimitsWithError: returned no limits");
                return -1;
            }
            int n = 0;
            for (NSNumber *v in result) {
                if (n >= max) {
                    break;
                }
                if ([v respondsToSelector:@selector(intValue)]) {
                    limits[n++] = [v intValue];
                }
            }
            // Sort ascending per PowerUI.h specification
            for (int i = 0; i < n - 1; i++) {
                for (int j = i + 1; j < n; j++) {
                    if (limits[i] > limits[j]) {
                        int tmp = limits[i];
                        limits[i] = limits[j];
                        limits[j] = tmp;
                    }
                }
            }
            *count = n;
            return 0;
        } @catch (NSException *ex) {
            set_err(err, [ex reason]);
            return -1;
        }
    }
}

int coddle_powerui_get(int *limit, int *enabled, char **err) {
    @autoreleasepool {
        @try {
            PowerUISmartChargeClient *c = client();
            if (c == nil) {
                set_err(err, @"PowerUI smart charge client is unavailable");
                return -1;
            }
            NSError *e = nil;
            unsigned char value = [c getMCLLimitWithError:&e];
            if (e != nil) {
                set_ns_err(err, e, @"getMCLLimitWithError: failed");
                return -1;
            }
            e = nil;
            unsigned long long on = [c isMCLCurrentlyEnabled:&e];
            if (e != nil) {
                set_ns_err(err, e, @"isMCLCurrentlyEnabled: failed");
                return -1;
            }
            if (limit != NULL) {
                *limit = (int)value;
            }
            if (enabled != NULL) {
                *enabled = on != 0 ? 1 : 0;
            }
            return 0;
        } @catch (NSException *ex) {
            set_err(err, [ex reason]);
            return -1;
        }
    }
}

int coddle_powerui_set(int limit, char **err) {
    @autoreleasepool {
        @try {
            PowerUISmartChargeClient *c = client();
            if (c == nil) {
                set_err(err, @"PowerUI smart charge client is unavailable");
                return -1;
            }
            NSError *e = nil;
            BOOL ok = [c setMCLLimit:(unsigned char)limit error:&e];
            if (!ok) {
                set_ns_err(err, e, @"setMCLLimit:error: failed");
                return -1;
            }
            return 0;
        } @catch (NSException *ex) {
            set_err(err, [ex reason]);
            return -1;
        }
    }
}

int coddle_powerui_disable(char **err) {
    @autoreleasepool {
        @try {
            PowerUISmartChargeClient *c = client();
            if (c == nil) {
                set_err(err, @"PowerUI smart charge client is unavailable");
                return -1;
            }
            NSError *e = nil;
            BOOL ok = [c disableMCL:&e];
            if (!ok) {
                set_ns_err(err, e, @"disableMCL: failed");
                return -1;
            }
            return 0;
        } @catch (NSException *ex) {
            set_err(err, [ex reason]);
            return -1;
        }
    }
}

int coddle_powerui_temporary_full_supported(void) {
    @autoreleasepool {
        @try {
            PowerUISmartChargeClient *c = client();
            return c != nil && [c isMCLSupported] &&
                [c respondsToSelector:@selector(temporarilyDisableMCL:)] ? 1 : 0;
        } @catch (NSException *ex) { return 0; }
    }
}

int coddle_powerui_charge_to_full_now(char **err) {
    @autoreleasepool {
        @try {
            PowerUISmartChargeClient *c = client();
            if (c == nil || ![c respondsToSelector:@selector(temporarilyDisableMCL:)]) {
                set_err(err, @"Temporary full charging is unavailable on this system");
                return -1;
            }
            NSError *e = nil;
            if (![c temporarilyDisableMCL:&e]) {
                set_ns_err(err, e, @"temporarilyDisableMCL: failed");
                return -1;
            }
            return 0;
        } @catch (NSException *ex) {
            set_err(err, [ex reason]);
            return -1;
        }
    }
}

void coddle_powerui_free(char *p) {
    free(p);
}
