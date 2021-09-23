<aside class="update">*Updated 2021-09-23* ([changelog](https://github.com/squeek502/ryanliptak.com/commits/master/posts/fuzzing-zig-code.md))</aside>

After [using code coverage information and real-world files](https://www.ryanliptak.com/blog/code-coverage-zig-callgrind/) to improve an audio metadata parser I am writing in [Zig](https://ziglang.org/), the next step was to fuzz test it in order to ensure that crashes, memory leaks, etc were ironed out as much as possible.

The problem was that I had no idea how to fuzz Zig code. While Zig uses LLVM and therefore in theory has access to [`libFuzzer`](https://llvm.org/docs/LibFuzzer.html), the necessary integration with [`SanitizerCoverage`](https://clang.llvm.org/docs/SanitizerCoverage.html) has [yet to be implemented](https://github.com/ziglang/zig/issues/5484) (see also [this comment on a closed PR](https://github.com/ziglang/zig/pull/5956#issuecomment-667610012)), so I figured I would try to to find another avenue in the meantime.

## Treating zig code as a black box

I thought I'd look into trying [`afl++`](https://github.com/AFLplusplus/AFLplusplus) which has [support for fuzzing 'black box' binaries](https://github.com/AFLplusplus/AFLplusplus#fuzzing-binary-only-targets), meaning it has modes that are intended to allow fuzzing binaries for which no source code is available. This wouldn't be ideal, but it'd at least be a start. To try this, I wrote a `fuzz.zig` and compiled it as an executable with libc linked (linking libc seemed to be necessary for this to work):

```language-zig
const std = @import("std");
const audiometa = @import("audiometa");

pub fn main() !void {
    // Setup an allocator that will detect leaks/use-after-free/etc
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // this will check for leaks and crash the program if it finds any
    defer std.debug.assert(gpa.deinit() == false);
    const allocator = &gpa.allocator;

    // Read the data from stdin
    const stdin = std.io.getStdIn();
    const data = try stdin.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(data);
    var stream_source = std.io.StreamSource{ .buffer = std.io.fixedBufferStream(data) };

    // Try to parse the data
    var metadata = try audiometa.metadata.readAll(allocator, &stream_source);
    defer metadata.deinit();
}
```

<aside class="note"><p>Note: `afl++` passes the fuzzed data in via `stdin` by default</p></aside>

With this, I tried a few of the black-box options that `afl++` has:

- Binary rewriters were a no-go. I tried [retrowrite](https://github.com/HexHive/retrowrite) and [E9AFL](https://github.com/GJDuck/e9afl) but they both choked on the Zig-compiled binary.
- [QEMU mode](https://github.com/AFLplusplus/AFLplusplus#qemu) (`-Q`) would crash immediately on any input; didn't investigate why this is.
- <mark class="success">[FRIDA mode](https://github.com/AFLplusplus/AFLplusplus#frida) (`-O`) worked without any fiddling required.</mark>

<aside class="note">Note: In FRIDA mode, bugs were marked by `afl++` as 'hangs' rather than 'crashes.' I'm not sure exactly why that is.</aside>

And with that, I was off to the races. There was a *heavy* runtime penalty to running in this mode, but it was able to catch many problems that were subsequently solved:

- I wasn't checking for possible text data size underflows
- I wasn't protecting against out-of-bounds reads when checking UTF-16 BOMs
- A few more data size underflow/index out-of-bounds protections were needed elsewhere
- I wasn't handling malformed extended ID3v2 headers safely
- [There was a bug in the Zig standard library where the `std.unicode` functions that allocated memory would fail to free the memory if they returned an error](https://github.com/ziglang/zig/pull/9776)

Despite the success, I felt that things could be improved.

## Treating zig code as a static library

Normally, `afl++` relies on compiling source code with its own patched compilers in order to instrument the fuzzed binary. This approach wouldn't work for Zig code, but I noticed that `afl++` has a 'LTO ([link time optimization](https://llvm.org/docs/LinkTimeOptimization.html)) mode' that instruments the binary at *link-time* rather than compile-time (with the caveat that the objects must be compiled with LTO enabled). Fortunately, Zig has support for compiling with LTO enabled via the `-flto` flag.

So, my idea was to compile the Zig code as a static library with LTO enabled, and then use the `afl-clang-lto` compiler to compile a normal C program that calls the Zig library. This ended up looking like:

```language-zig
const std = @import("std");
const audiometa = @import("audiometa");

// export the zig function so that it can be called from C
export fn fuzz_zig_main() void {
    // code omitted--it's the same as the previous example,
    // but with the try's swapped out for catch unreachable's
}
```

```language-c
// fuzz_lib.h
void fuzz_zig_main();
```

```language-c
// fuzz.c
#include "fuzz_lib.h"

int main() {
    fuzz_zig_main();
    return 0;
}
```

I was then able to compile the Zig portion as a static library:

- with LTO (passing `-flto` or setting `LibExeObjStep.want_lto = true`)
- with compiler_rt bundled [to avoid `undefined symbol: __zig_probe_stack` linker errors](https://github.com/ziglang/zig/issues/6817) (passing `-fcompiler-rt` or setting `LibExeObjStep.bundle_compiler_rt = true`)

and then compile the C portion via `afl-clang-lto` and link in the Zig portion:

```language-shellsession
$ afl-clang-lto -o fuzz.o -c fuzz.c
$ afl-clang-lto -o fuzz fuzz.o -Lzig-out/lib -laudiometa-fuzz
afl-llvm-lto++3.15a by Marc "vanHauser" Heuse <mh@mh-sec.de>
AUTODICTIONARY: 10 strings found
[+] Instrumented 3426 locations with no collisions (on average 88 collisions would be in afl-gcc/vanilla AFL) (non-hardened mode).
```

This resulting binary could then be fuzzed as normal:

```language-shellsession
$ afl-fuzz -i path/to/inputs -o path/to/outputs -- ./fuzz
```

This *hugely* improved execution speed--it went from around 500/sec to around 9000/sec. This seemed great, but I still thought there were some unnecessary steps involved.

## Skipping the C code

Instead of linking the Zig code with C code, I wondered if it was possible to compile *only* the Zig code and then use `afl-clang-lto` to transform the compiled Zig into an executable, thereby getting the instrumentation without having to compile any C code. It turns out this is very possible if you:

- Export a `callconv(.C)` main symbol (i.e. `export fn main()`) to act as the entry point (without this, `afl-clang-lto` will compain about an `undefined symbol: main`)
- Call your Zig code from the exported main

Here's an example with some contrived and intentionally buggy code:

```language-zig
const std = @import("std");

fn cMain() callconv(.C) void {
    main() catch unreachable;
}

comptime {
    @export(cMain, .{ .name = "main", .linkage = .Strong });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // this will check for leaks and crash the program if it finds any
    defer std.debug.assert(gpa.deinit() == false);
    const allocator = &gpa.allocator;

    const stdin = std.io.getStdIn();
    const data = try stdin.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(data);

    if (data.len == 0) return;

    switch (data[0]) {
        0 => {
            // alloc without free
            _ = try allocator.alloc(u8, 10);
        },
        1 => {
            // returning an error
            return error.BadInput;
        },
        else => {},
    }
}
```

<aside class="note">Note: Zig's error/stack traces don't seem to work right in the `afl`-instrumented binaries, so for debugging purposes it's helpful to compile a second executable with the Zig compiler that can run the crash-inducing outputs to give you relevant stack traces. This example code could be simplified a bit by using `export fn main()` instead of the more verbose `@export`, but using `@export` and `pub fn main()` in the manner shown above allows the same code to be compiled either for fuzzing or for debugging without any modifications.</aside>


To build:

```language-shellsession
$ zig build-lib -static -fcompiler-rt -flto fuzz.zig
$ afl-clang-lto -o fuzz libfuzz.a
```

And then run the fuzzer:

```language-shellsession
$ afl-fuzz -i input -o output -- ./fuzz
```

```language-text
total execs : 113k │ total crashes : 13.5k (2 unique)
```

We can also verify that the resulting crash files trigger the buggy code as expected:

```language-shellsession
$ ./fuzz < 'output/default/crashes/id:000000,sig:06,src:000000,time:2,op:havoc,rep:4'
error(gpa): memory address 0x7ffff7ffb000 leaked: 
$ ./fuzz < 'output/default/crashes/id:000001,sig:06,src:000000,time:8,op:havoc,rep:8'
thread 2903735 panic: attempt to unwrap error: BadInput
```

<aside class="update"><p>Note: An earlier version of this post recommended `zig build-obj` to create a `.o` file instead of a static library, but the `build-obj` method has issues with `undefined symbol: __zig_probe_stack` linker errors in certain situations. The `build-lib` method recommended in the current post has all the same benefits without the potential for those linker errors.</p></aside>

### Integrating with `build.zig`

There are probably better ways to do this, but here's what I was able to come up with:

```language-zig
const std = @import("std");

pub fn build(b: *std.build.Builder) !void {
    // The library
    const fuzz_lib = b.addStaticLibrary("fuzz-lib", "fuzz.zig");
    fuzz_lib.setBuildMode(.Debug);
    fuzz_lib.want_lto = true;
    fuzz_lib.bundle_compiler_rt = true;

    // Setup the output name
    const fuzz_executable_name = "fuzz";
    const fuzz_exe_path = try std.fs.path.join(b.allocator, &.{ b.cache_root, fuzz_executable_name });

    // We want `afl-clang-lto -o path/to/output path/to/library`
    const fuzz_compile = b.addSystemCommand(&.{ "afl-clang-lto", "-o", fuzz_exe_path });
    // Add the path to the library file to afl-clang-lto's args
    fuzz_compile.addArtifactArg(fuzz_lib);

    // Install the cached output to the install 'bin' path
    const fuzz_install = b.addInstallBinFile(.{ .path = fuzz_exe_path }, fuzz_executable_name);

    // Add a top-level step that compiles and installs the fuzz executable
    const fuzz_compile_run = b.step("fuzz", "Build executable for fuzz testing using afl-clang-lto");
    fuzz_compile_run.dependOn(&fuzz_compile.step);
    fuzz_compile_run.dependOn(&fuzz_install.step);
}
```

With this, running

```language-text
zig build fuzz
```

Would build an executable named `fuzz` and put it into the 'bin' install path (`zig-out/bin` by default) that can then be used with `afl-fuzz` (note that the compile step requires `afl-clang-lto` to be installed on the system).

It's also possible with this setup to easily build a second Zig executable (with the same code) for debugging the crashes as mentioned above. To do this, you could add the following to the `build.zig`:

```language-zig
// Compile a companion exe for debugging crashes
const fuzz_debug_exe = b.addExecutable("fuzz-debug", "fuzz.zig");
fuzz_debug_exe.setBuildMode(.Debug);

// Only install fuzz-debug when the fuzz step is run
const install_fuzz_debug_exe = b.addInstallArtifact(fuzz_debug_exe);
fuzz_compile_run.dependOn(&install_fuzz_debug_exe.step);
```

This will build a `fuzz-debug` executable and install it next to the `fuzz` executable. When the fuzzer detects a bug, you can then get a proper stack trace by running the offending input through `fuzz-debug`:

```language-shellsession
$ ./zig-out/bin/fuzz-debug < 'output/default/crashes/id:000000,sig:06,src:000000,time:2,op:havoc,rep:4'
error(gpa): memory address 0x7ffff7ff8000 leaked: 
/home/ryan/Programming/zig/tmp/fuzz/fuzz.zig:25:36: 0x205ec3 in main (fuzz-debug)
            _ = try allocator.alloc(u8, 10);
                                   ^
/home/ryan/Programming/zig/zig/build/lib/zig/std/start.zig:510:37: 0x229a3a in std.start.callMain (fuzz-debug)
            const result = root.main() catch |err| {
                                    ^
...
```

A complete example can be found here:

- [https://github.com/squeek502/zig-fuzzing-example](https://github.com/squeek502/zig-fuzzing-example)

And an example that fuzz tests parts of the Zig standard library can be found here:

- [https://github.com/squeek502/zig-std-lib-fuzzing](https://github.com/squeek502/zig-std-lib-fuzzing)

## Wrapping up

Hopefully the methods detailed here can serve as a stop-gap until Zig gets more fuzzing capabilities built-in. Funnily enough, the slower FRIDA mode I used initially may have caught all of the bugs in my audio metadata parsing library (or at least all of the low-hanging ones), as after the speedups from the static library/object file methods I haven't been able to trigger any more crashes.
