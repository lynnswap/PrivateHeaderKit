# Decompile a Selected Function

Use symbol search to find a function, then ask Ghidra to decompile that function
from its Mach-O image. This is a separate local operation; normal generation
does not run Ghidra or produce address lists, link stubs, or bulk pseudocode.

## Requirements

- A working local [Ghidra installation](https://github.com/NationalSecurityAgency/ghidra),
  including a native decompiler for your Mac and the Java runtime required by
  that Ghidra version. Set `JAVA_HOME` if its launcher cannot find Java.
- Set `GHIDRA_HOME` to the installation directory, pass `--ghidra-home`, or put
  Ghidra's `analyzeHeadless` command on `PATH`.
- For shared-cache input only, install [ipsw](https://blacktop.github.io/ipsw/) and
  put it on `PATH`, or pass `--ipsw /path/to/ipsw`.

PrivateHeaderKit uses local tools and does not send binaries or assembly to an
LLM service. It does not download or install Ghidra, Java, or ipsw.

## Choose the Image and Symbol

```bash
privateheaderkit search 'Foo::bar' --in ~/PrivateHeaderKit/generated-headers
```

Copy the original `name` from a matching row, not `demangled_name`. Choose the
matching source binary or shared cache for that platform and OS build. Search
lists contain names, not binary code; they cannot be decompiled on their own.

For a standalone Mach-O file:

```bash
privateheaderkit decompile \
  --binary /path/to/Foo.framework/Foo \
  --symbol '__ZN3Foo3barEi' \
  --ghidra-home /path/to/ghidra \
  --output Foo-bar.c
```

For an image stored in a dyld shared cache:

```bash
privateheaderkit decompile \
  --shared-cache /path/to/dyld_shared_cache_arm64e \
  --image /System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation \
  --symbol '_CFAbsoluteTimeGetCurrent' \
  --ghidra-home /path/to/ghidra \
  --output CFAbsoluteTimeGetCurrent.c
```

`--image` is the full logical image path shown by search. The shared cache and
any companion subcache files must be accessible to ipsw. PrivateHeaderKit
extracts just that image into a temporary directory, with cache slide fixups
and available Objective-C symbols, before importing it into Ghidra.

For an Objective-C method whose name begins with `-`, use the equals form:

```bash
privateheaderkit decompile --binary /path/to/Foo \
  --symbol='-[Foo performWork:]' --ghidra-home /path/to/ghidra
```

Omit `--output` to print pseudocode to standard output. An output file must not
already exist; PrivateHeaderKit never overwrites it. For a universal binary,
use `--processor` with the Ghidra language ID
for the intended architecture, such as `AARCH64:LE:64:AppleSilicon`, or supply an
already selected Mach-O slice.

## Results and Failures

Ghidra imports and analyzes the selected image, then emits only the selected
function's pseudocode. Original symbol selection happens before analysis can
rename symbols. Ghidra's imported-name normalization applies to names such as
Objective-C methods with spaces. Multiple matching addresses are reported as
ambiguous; an unknown symbol or a symbol that is not recognized as a function
is an error.

`--timeout` defaults to 120 seconds for image analysis and 120 seconds for the
individual decompilation. If analysis reaches its limit but the function can
still be decompiled, the output notes the incomplete analysis. A failed or
timed-out function decompilation is an error. Tool startup and cache extraction
are outside these stage limits; Control-C cancels the active subprocesses.

Pseudocode includes inferred types, signatures, and control flow. Missing debug
information and compiler optimizations can obscure arguments, return values,
classes, and inlined functions. Treat it as an aid to reading the implementation,
not recovered original source or code ready to compile.

Temporary project, script, extraction, and result files are removed on success,
failure, and cancellation. A cleanup failure reports the remaining directory
and any original operation error. Existing generated headers and symbol lists
are not changed. Ghidra may maintain its own usual user preferences and caches.
