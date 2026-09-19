#import "PrivateHeaderKitRawDumpRuntimeObjC.h"
#include <cxxabi.h>
#include <cstdlib>
#include <cstring>

NSString *PHKDemangleCXXName(const char *name) {
    // Mach-O adds an underscore before the Itanium ABI's _Z prefix.
    if (std::strncmp(name, "__Z", 3) == 0) { ++name; }
    char *demangled = abi::__cxa_demangle(name, nullptr, nullptr, nullptr);
    if (!demangled) { return nil; }
    NSString *result = [NSString stringWithUTF8String:demangled];
    std::free(demangled);
    return result;
}
