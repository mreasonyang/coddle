// Compile this fixture with the production PowerUI.m and CODDLE_POWERUI_TESTING.
// No private framework is loaded; all selectors run against this simulated class.
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include "../PowerUI.h"

static const char *scenario;
static atomic_int providers;
static atomic_int initializers;
static atomic_int concurrentFailures;
static int checks;
static int writes;
static int temporaryWrites;

static BOOL isScenario(const char *value) { return strcmp(scenario, value) == 0; }
static void throwFixture(void) {
    @throw [NSException exceptionWithName:@"FixtureFailure" reason:@"simulated private API failure" userInfo:nil];
}
static void expect(BOOL condition, const char *message) {
    checks++;
    if (!condition) {
        fprintf(stderr, "FAIL: %s (%s)\n", message, scenario);
        exit(1);
    }
}
static void expectError(char *error) {
    expect(error != NULL && strlen(error) > 0, "failure has an owned error message");
    coddle_powerui_free(error);
}

@interface FixtureSmartChargeClient : NSObject
@end
@implementation FixtureSmartChargeClient
+ (BOOL)instancesRespondToSelector:(SEL)selector {
    if (isScenario("class-probe-throw")) throwFixture();
    return [super instancesRespondToSelector:selector];
}
- (instancetype)initWithClientName:(NSString *)name {
    atomic_fetch_add(&initializers, 1);
    if (isScenario("init-throw")) throwFixture();
    return [super init];
}
- (BOOL)respondsToSelector:(SEL)selector {
    if (isScenario("selector-probe-throw")) throwFixture();
    if (selector == @selector(temporarilyDisableMCL:) &&
        !isScenario("temporary-full") && !isScenario("temporary-error") && !isScenario("temporary-throw")) return NO;
    return [super respondsToSelector:selector];
}
- (BOOL)isMCLSupported {
    if (isScenario("method-throw")) throwFixture();
    return YES;
}
- (unsigned char)getMCLLimitWithError:(NSError **)error {
    if (isScenario("method-throw")) throwFixture();
    return 80;
}
- (unsigned long long)isMCLCurrentlyEnabled:(NSError **)error { return 1; }
- (NSArray<NSNumber *> *)availableChargeLimitsWithError:(NSError **)error {
    if (isScenario("method-throw")) throwFixture();
    return @[@100, @80, @90];
}
- (BOOL)setMCLLimit:(unsigned char)limit error:(NSError **)error {
    if (isScenario("method-throw")) throwFixture();
    writes++;
    return YES;
}
- (BOOL)temporarilyDisableMCL:(NSError **)error {
    temporaryWrites++;
    if (isScenario("temporary-throw")) throwFixture();
    if (isScenario("temporary-error")) {
        *error = [NSError errorWithDomain:@"Fixture" code:1 userInfo:@{NSLocalizedDescriptionKey: @"temporary override failed"}];
        return NO;
    }
    return YES;
}
- (BOOL)disableMCL:(NSError **)error {
    if (isScenario("method-throw")) throwFixture();
    writes++;
    return YES;
}
@end

Class coddle_powerui_test_client_class(void) {
    atomic_fetch_add(&providers, 1);
    if (isScenario("provider-throw")) throwFixture();
    if (isScenario("unavailable")) return Nil;
    return [FixtureSmartChargeClient class];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) return 2;
        scenario = argv[1];
        BOOL temporary = isScenario("temporary-full") || isScenario("temporary-error") || isScenario("temporary-throw");
        BOOL normal = isScenario("normal") || temporary;
        int expectedSupport = normal ? 1 : 0;

        // A thrown initialization must finish its once token. Repeated and
        // concurrent calls detect both a process abort and a stuck token.
        expect(coddle_powerui_supported() == expectedSupport, "first capability probe");
        expect(coddle_powerui_supported() == expectedSupport, "repeated capability probe");
        dispatch_apply(32, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t index) {
            if (coddle_powerui_supported() != expectedSupport) {
                atomic_fetch_add(&concurrentFailures, 1);
            }
        });
        expect(atomic_load(&concurrentFailures) == 0, "concurrent capability probes");
        expect(atomic_load(&providers) == 1, "client resolution happens exactly once");
        expect(atomic_load(&initializers) <= 1, "initialization is not retried after failure");

        char *error = NULL;
        int limit = -1, enabled = -1, count = -1, limits[3] = {0};
        int result = coddle_powerui_get(&limit, &enabled, &error);
        expect(result == (normal ? 0 : -1), "read result");
        if (normal) expect(limit == 80 && enabled == 1, "read values");
        else expectError(error);
        error = NULL;
        result = coddle_powerui_available_limits(limits, 3, &count, &error);
        expect(result == (normal ? 0 : -1), "available limits result");
        if (normal) expect(count == 3 && limits[0] == 80 && limits[1] == 90 && limits[2] == 100,
                           "available limits sorted");
        else expectError(error);
        error = NULL;
        expect(coddle_powerui_set(80, &error) == (normal ? 0 : -1), "set result");
        if (!normal) expectError(error);
        error = NULL;
        expect(coddle_powerui_disable(&error) == (normal ? 0 : -1), "disable result");
        if (!normal) expectError(error);
        expect(coddle_powerui_temporary_full_supported() == (temporary ? 1 : 0), "temporary override capability is independent");
        error = NULL;
        int temporaryResult = coddle_powerui_charge_to_full_now(&error);
        expect(temporaryResult == (isScenario("temporary-full") ? 0 : -1), "temporary override result");
        if (!isScenario("temporary-full")) expectError(error);
        expect(temporaryWrites == (temporary ? 1 : 0), "only the supported temporary selector is invoked");
        expect(writes == (normal ? 2 : 0), "unsupported or failed temporary override never disables the limit permanently");
        printf("PASS: %s (%d checks, 32 concurrent probes)\n", scenario, checks);
        return 0;
    }
}
