<aside class="note">Note: Most of this is recounting the process by which I arrived at being able to generate code coverage information for Zig code. If you just want to see the end result, check out the [grindcov repository](https://github.com/squeek502/grindcov).</aside>

<aside class="update"><p>**Update 2021-09-13:** Since writing this post, I was made aware of [kcov](https://github.com/SimonKagstrom/kcov) which is a more robust and *much* faster tool that can generate coverage information for Zig binaries. I've written a [follow-up post that describes more generally how coverage tools like kcov can be used with Zig on zig.news](https://zig.news/squeek502/code-coverage-for-zig-1dk1).</p></aside>

---

When writing an [audio metadata (ID3v2, etc) parser](https://github.com/squeek502/audiometa) in [Zig](https://ziglang.org/), I wrote some tests to compare the output of some existing metadata parsers to my parser for all the files in my music directory. Whenever there was a discrepancy, I figured out what was happening and fixed my parser as necessary.

This worked out great, but I was lazy while doing it and didn't create test cases for each new fix that I had to add. After eventually becoming compliant-enough with the output of other metadata parsers, my resulting code still had very few self-contained test cases. I *had* kept a set of files that I knew (at one point or another) triggered some bug in my parser, but I also knew that the set of files was unnecessarily large--there were many files that were only novel to a previous/buggy version of the parser, so they wouldn't all be good tests for the current version.

In order to narrow down the set of files only to those that were truly novel, I had an idea: compare the code coverage of the parser when running the current tests to the coverage of the parser when run with a given file included as a new test--any differences would indicate a file that would be worth adding as a new test case. This would work, but I had no idea how to get coverage information for a Zig-compiled binary.

## The Problem

As far as I can tell, coverage for compiled programs is typically done via the compiler itself (e.g. `gcov/lcov` via `gcc -fprofile-arcs -ftest-coverage`). While the Zig compiler uses LLVM, I'm not sure how feasible it is to use LLVM/Clang's coverage tools with Zig. Instead, we'll probably want something that doesn't rely on compile-time instrumentation.

[Valgrind](https://valgrind.org/) fits the bill, and it conveniently has a [`--tool=callgrind` option](https://valgrind.org/docs/manual/cl-manual.html) that generates all the data necessary for coverage information. As I understand it, instead of adding instrumentation at compile-time, Valgrind essentially re-compiles a binary just before runtime, adding the necessary instrumentation. Using callgrind will output a [`callgrind.out.<pid>` file with information like](https://www.valgrind.org/docs/manual/cl-format.html) (very simplified):

```language-text
fl=file.zig
20 700
```

Where the `20` is the line number of an executed line-of-code in the file `file.zig`, and the `700` is some more information about that execution (not relevant for coverage purposes). Callgrind gives this sort of information for each line executed through the entire runtime of a program.

So, the coverage information is available in there somewhere, but it needs to be parsed to be understandable.

## Finding a Solution

I was somewhat surprised to find that there don't seem to be many `callgrind`-to-coverage tools out there (that I could find at least). However, the [`numpy` Python package](https://github.com/numpy/numpy/) has a [`c_coverage` tool](https://github.com/numpy/numpy/tree/main/tools/c_coverage) that does exactly the generating/parsing of `callgrind.out` files that is necessary to get human readable coverage information. Out-of-the-box, it works decently well for Zig code, too (note: `--pattern` must be specified, since it otherwise defaults to `numpy`):

```language-shellsession
$ zig build-exe main.zig
$ c_coverage_collect.sh ./main
$ c_coverage_report.py --pattern=. --format=text callgrind.out.97155
```
`coverage/main.zig` then would contain (where `> ` indicates a 'covered' line and `! ` indicates an 'uncovered' line):

```language-diff
! const std = @import("std");
! 
> pub fn main() !void {
!     if (true) {
>         std.debug.print("yes\n", .{});
!     } else {
!         std.debug.print("no\n", .{});
!     }
! }
```
<aside class="note"><p>Note: This coverage information might look slightly strange but it *is* correct--the `if` statement isn't executed because it does not make it into the compiled binary (the condition is known at compile-time so it's elided)</p></aside>

## The Next Problem

Now that we can generate coverage information for Zig code, what about doing that for Zig tests? Tests in Zig are more complicated to use with `numpy`'s `c_coverage` tools since:

1. Test binaries in Zig are temporary and only live in `zig-cache`, so we'll need to somehow get the path to the actual test binary.
2. I was running the tests through `zig build`/`build.zig`, so there's another layer of indirection in front of the final test binary.

The first problem I was able to solve with `zig test --enable-cache`, which prints the path to the directory containing the test binary (the actual binary is called `test` and you need to pass it the path to the zig binary to run it):

```language-shellsession
$ zig test test.zig --enable-cache
zig-cache/o/8b367f09929f447e72e4e23e8906c5de
All 1 tests passed.
$ c_coverage_collect.sh zig-cache/o/8b367f09929f447e72e4e23e8906c5de/test zig
$ ls callgrind.out.*
callgrind.out.104014
$ c_coverage_report --pattern=. --format=text callgrind.out.104014
```
`coverage/test.zig` would then contain something like:

```language-diff
! const std = @import("std");
! 
> test "hello world" {
>     try std.testing.expectEqual(1, 1);
! }

```

The second problem I solved in a janky way using `zig build --verbose`, which outputs the commands that are run during `zig build`:

```language-shellsession
$ zig build test --verbose
/home/ryan/Programming/zig/zig/build/zig test /home/ryan/Programming/zig/tmp/test.zig --cache-dir /home/ryan/Programming/zig/tmp/zig-cache --global-cache-dir /home/ryan/.cache/zig --name test
All 1 tests passed.
```

<aside class="note"><p>Note: In this example, there's not much difference in the command from `zig build test --verbose` and the regular `zig test` usage above--it's just more explicit. With a more complicated `build.zig`, though (linking other libraries, adding packages, etc), this command can vary significantly from a naive `zig test` call.</p>

Also, this `--verbose` method is not the only way of doing this. Instead, the Zig command-line options `--test-cmd` and `--test-cmd-bin` can be used to make the coverage data generator be the 'text executor'. This is detailed later in this post.</aside>

## Automating Things

With this in place, I was ready to write a few shell scripts to finally execute my original idea.

To generate the 'before' coverage:

```language-bash
# This is the command gotten from `zig build test --verbose`, with `--enable-cache` appended
# in order to get the path to the directory containing the resulting test executable.
cached_test_dir=`zig test /home/ryan/Programming/zig/audiometa/test/parse_tests.zig --cache-dir /home/ryan/Programming/zig/audiometa/zig-cache --global-cache-dir /home/ryan/.cache/zig --name test --pkg-begin audiometa /home/ryan/Programming/zig/audiometa/src/audiometa.zig --pkg-end --enable-cache 2>/dev/null`

# Collect data via callgrind and output it to 'callgrind.out.before'
c_coverage_collect.sh --callgrind-out-file=callgrind.out.before "${cached_test_dir}/test" zig
# Output coverage results to 'cov-before' directory
c_coverage_report.py -p audiometa/src -f text -d cov-before callgrind.out.before 
```

To simulate adding a new test case and comparing the coverage to see if it would change:

```language-bash
# Run the metadata parsing command-line program on the file and output data to 'callgrind.out.after'
c_coverage_collect.sh --callgrind-out-file=callgrind.out.after ./zig-out/bin/audiometa "$1"
# Output coverage information to 'cov-after', combining the callgrind data of before and after
c_coverage_report.py -p audiometa/src -f text -d cov-after callgrind.out.after callgrind.out.before 

# Compare before and after (I was mostly interested in the id3v2 parser)
cmp --silent cov-before/id3v2.zig cov-after/id3v2.zig || echo "coverage would be changed"
```

With these, I was then able to write a script to loop through all of the potentially interesting files and check for "coverage would be changed" after running it through the coverage change detection script. Any coverage changes could then be converted into a test case, and, at the end of the process, I had a minimal set of tests that exercised all of the edge cases I had previously added support for. Huzzah.

## Formalizing the Solution

From my perspective, `numpy`'s `c_coverage` tool was not quite ideal for a few reasons:

- It's a bit manual/inconvenient being two separate steps
- The 'pattern' argument is a bit weird and seems mostly tailored to numpy
- It has an HTML output that seems to be C-specific (it broke on most .zig files)
- It depends on Python

So, I thought I'd port the idea over to a Zig program that attempts to improve on all of these perceived weaknesses. The result is [grindcov](https://github.com/squeek502/grindcov), which:

- Can perform both the collection and generation of coverage results in one go (and by default deletes the callgrind.out file for you).
- Defaults the `--pattern`-esque argument (in grindcov called `--root`) to the current working directory, meaning that (by default) any files in the cwd or any child directories are included in the results.
- Uses a `.diff` extension for the results so that syntax highlighters have a better chance of highlighting them in a way that is legible.
- Has no Python dependency.

Here's a simple example usage:

```language-shellsession
$ zig build-exe main.zig
$ grindcov -- ./main hello
Results for 1 source files generated in directory 'coverage'
$ ls coverage
main.zig.diff
```

## Using the Solution with Zig

As briefly mentioned in a note before, `zig test` has support for using custom executors via the option `--test-cmd`. Using this can bypass the whole tedious 'finding the real path to the test executable' steps. For example, this:

```language-text
zig test file.zig --test-cmd grindcov --test-cmd -- --test-cmd-bin
```

will end up running something like `grindcov -- zig-cache/path/to/test zig` for you.

<aside class="note"><p>`--test-cmd-bin` is necessary to tell zig to append the test binary path to the executor's arguments</p>

`--test-cmd --` is specified so that grindcov gets the `--` argument before the command to execute, just to ensure that the command and its args are not parsed as flags/options to `grindcov`</aside>

This also allows for easy integration with `build.zig`. Here's one possible implementation:

```language-zig
const coverage = b.option(bool, "test-coverage", "Generate test coverage with grindcov") orelse false;

var tests = b.addTest("test.zig");
if (coverage) {
    tests.setExecCmd(&[_]?[]const u8{
        "grindcov",
        //"--keep-out-file", // any grindcov flags can be specified here
        "--",
        null, // to get zig to use the --test-cmd-bin flag
    });
}

const test_step = b.step("test", "Run all tests");
test_step.dependOn(&tests.step);
```

Test coverage information could then be generated by doing:

```language-shellsession
$ zig build test -Dtest-coverage
Results for 1 source files generated in directory 'coverage'
```

## Improving the Solution

One thing that the callgrind data doesn't provide is information about which lines in a file are executable. If this information were available, the results could be improved by distinguishing between lines that aren't covered and lines that aren't even executable, leading to much more legible/interesting results.

The only way I could come up with to do this is to separately parse the debug information in the binary in order to get a set of all executable lines. There are probably better tools for the job, but I ended up using [`readelf --debug-dump=decodedline`](https://man7.org/linux/man-pages/man1/readelf.1.html) as a child process in order to grab the necessary information. With this in place, the results could now look something like:


```language-diff
  const std = @import("std");
  
> pub fn main() !void {
>     var args_it = std.process.args();
>     std.debug.assert(args_it.skip());
>     const arg = args_it.nextPosix() orelse "goodbye";
  
>     if (std.mem.eql(u8, arg, "hello")) {
>         std.debug.print("hello!\n", .{});
      } else {
!         std.debug.print("goodbye!\n", .{});
      }
  }
```

where only the *real* uncovered line is prefixed with `!`.

This also allows for outputting a useful summary, including "percentage covered" stats:

```language-shellsession
$ grindcov -- ./main hello
Results for 1 source files generated in directory 'coverage'

File                                 Covered LOC Executable LOC Coverage
------------------------------------ ----------- -------------- --------
main.zig                             6           7                85.71%
------------------------------------ ----------- -------------- --------
Total                                6           7                85.71%
```

<aside class="note"><p>Note: There's a big caveat here with the results from Zig binaries: since the Zig compiler only compiles functions that are actually called/referenced, completely unused functions don't contribute to the 'executable lines' total. Because of this, a file with one used function and many unused functions could potentially show up as 100% covered.</p>

In other words, the results are only indicative of the coverage of *used* functions.</aside>

## Further Room For Improvement

I'm sure there's tons. This is my first foray into writing this type of tooling, so it's likely there are better ways to do everything I'm attempting to do here. As for the things I'm aware of:

- Drop the `readelf` dependency in favor of either something that integrates with Callgrind (so there's no separate ELF/DWARF parsing step) or something that uses Zig's ELF/DWARF parsing functions from its standard library.
- Add a `lcov`-compatible `.info` output format, so that `lcov`'s `genhtml` or similar could be used to generate reports.
- Support for following child processes

If you want to help out, the [`grindcov` repository can be found here](https://github.com/squeek502/grindcov).

---

## Addendum: Zig Standard Library Test Coverage

Out of curiosity, and just to see if `grindcov` could do it, I tried running Zig's standard library tests using `grindcov`. This was done in a very hacky way by adding

```language-zig
// coverage
these_tests.setExecCmd(&[_]?[]const u8{
    "grindcov",
    "--",
    null,
});
```

directly inside `addPackageTests` in `test/tests.zig`, and then commenting out all `test_targets` except for `TestTarget{ .single_threaded = true }` (so only a native/debug-mode/non-libc/single-threaded target is tested). The tests were then run (via `grindcov`) with `zig build test-std`.

<aside class="note"><p>Note: There is a heavy runtime cost to running via callgrind. These tests took around 5 seconds to run without callgrind, but when run with callgrind they took around 2 minutes.</p></aside>

As of [commit 0c091feb5a](https://github.com/ziglang/zig/tree/0c091feb5ae52caf1ebf885c0de55b3159207001), these were the coverage results (it's also worth keeping in mind the "completely unused functions don’t contribute to the ‘executable lines’ total" caveat mentioned in a note above):

```language-text
File                                 Covered LOC Executable LOC Coverage
------------------------------------ ----------- -------------- --------
...                                  ...         ...                 ...
------------------------------------ ----------- -------------- --------
Total                                43480       52586            82.68%
```

<details>
<summary>Full file-by-file results (click to expand)</summary>

```language-text
File                                 Covered LOC Executable LOC Coverage
------------------------------------ ----------- -------------- --------
lib/std/x/net/ip.zig                 12          13               92.31%
lib/std/atomic/Atomic.zig            202         203              99.51%
lib/std/io/bit_reader.zig            110         115              95.65%
.../crypto/25519/edwards25519.zig    243         273              89.01%
lib/std/crypto/pcurves/common.zig    107         109              98.17%
lib/std/json/write_stream.zig        127         153              83.01%
lib/std/io/c_writer.zig              2           2               100.00%
lib/std/zig/parse.zig                1890        2054             92.02%
lib/std/os/linux.zig                 320         365              87.67%
lib/std/math/epsilon.zig             6           6               100.00%
lib/std/c/tokenizer.zig              336         483              69.57%
lib/std/zig/string_literal.zig       25          68               36.76%
.../crypto/pcurves/p256/scalar.zig   45          47               95.74%
lib/std/event/rwlock.zig             2           2               100.00%
lib/std/io/test.zig                  104         105              99.05%
lib/std/event/future.zig             2           2               100.00%
lib/std/meta/trait.zig               264         272              97.06%
lib/std/net/test.zig                 50          55               90.91%
lib/std/crypto/pcurves/p256.zig      251         266              94.36%
lib/std/math/log2.zig                99          108              91.67%
lib/std/leb128.zig                   187         188              99.47%
lib/std/math/ceil.zig                89          94               94.68%
lib/std/math/complex/proj.zig        7           9                77.78%
lib/std/io/seekable_stream.zig       0           9                 0.00%
lib/std/math/complex/ldexp.zig       39          40               97.50%
lib/std/math/signbit.zig             35          36               97.22%
lib/std/time.zig                     53          55               96.36%
lib/std/Progress.zig                 108         145              74.48%
lib/std/math/complex/abs.zig         6           7                85.71%
lib/std/math/cbrt.zig                74          79               93.67%
lib/std/atomic.zig                   7           9                77.78%
.../general_purpose_allocator.zig    446         538              82.90%
lib/std/target.zig                   148         540              27.41%
lib/std/math/sin.zig                 59          60               98.33%
lib/std/comptime_string_map.zig      41          44               93.18%
lib/std/net.zig                      603         717              84.10%
lib/std/fmt.zig                      876         918              95.42%
lib/std/math/scalbn.zig              44          45               97.78%
lib/std/math/complex/tan.zig         9           10               90.00%
lib/std/event/loop.zig               6           6               100.00%
lib/std/math/complex/sqrt.zig        47          69               68.12%
lib/std/Thread.zig                   12          13               92.31%
lib/std/math/big.zig                 1           1               100.00%
lib/std/fs.zig                       351         449              78.17%
lib/std/io/fixed_buffer_stream.zig   65          80               81.25%
lib/std/x/os/io.zig                  65          69               94.20%
lib/std/math/complex/asin.zig        12          13               92.31%
lib/std/crypto/aes/aesni.zig         91          125              72.80%
.../crypto/pcurves/p256/p256_64.zig  1488        1489             99.93%
lib/std/crypto/salsa20.zig           261         267              97.75%
lib/std/os/linux/vdso.zig            3           60                5.00%
lib/std/crypto/25519/ed25519.zig     158         161              98.14%
lib/std/unicode.zig                  489         513              95.32%
lib/std/math/acos.zig                73          88               82.95%
.../crypto/25519/ristretto255.zig    76          78               97.44%
lib/std/crypto/pbkdf2.zig            51          53               96.23%
lib/std/crypto/md5.zig               96          106              90.57%
lib/std/json.zig                     1308        1389             94.17%
lib/std/crypto/hkdf.zig              31          33               93.94%
lib/std/hash/cityhash.zig            264         265              99.62%
lib/std/math/asinh.zig               65          66               98.48%
lib/std/fs/get_app_data_dir.zig      6           8                75.00%
lib/std/heap.zig                     252         258              97.67%
lib/std/dwarf.zig                    0           474               0.00%
lib/std/math/complex/asinh.zig       9           10               90.00%
lib/std/valgrind.zig                 11          13               84.62%
lib/std/crypto/modes.zig             16          22               72.73%
lib/std/crypto/25519/curve25519.zig  57          59               96.61%
lib/std/fmt/errol/enum3.zig          0           4                 0.00%
lib/std/crypto/isap.zig              146         158              92.41%
lib/std/math/tanh.zig                74          79               93.67%
lib/std/rand/Gimli.zig               12          14               85.71%
lib/std/zig/system/darwin/macos.zig  80          109              73.39%
lib/std/crypto.zig                   20          21               95.24%
lib/std/math/complex/pow.zig         10          11               90.91%
lib/std/math/atanh.zig               55          56               98.21%
lib/std/buf_set.zig                  34          39               87.18%
lib/std/math/complex/cosh.zig        40          86               46.51%
lib/std/math/modf.zig                109         115              94.78%
lib/std/zig/system.zig               142         329              43.16%
lib/std/math/log.zig                 24          27               88.89%
lib/std/elf.zig                      0           108               0.00%
lib/std/once.zig                     16          17               94.12%
lib/std/std.zig                      2           2               100.00%
lib/std/math/big/rational.zig        395         423              93.38%
lib/std/crypto/blake2.zig            385         396              97.22%
lib/std/compress/deflate.zig         240         262              91.60%
lib/std/start.zig                    44          46               95.65%
lib/std/io/counting_writer.zig       13          14               92.86%
lib/std/build/FmtStep.zig            0           15                0.00%
lib/std/crypto/aes.zig               43          44               97.73%
lib/std/math/complex/tanh.zig        44          65               67.69%
lib/std/crypto/aes_gcm.zig           80          83               96.39%
lib/std/fifo.zig                     233         251              92.83%
.../heap/log_to_writer_allocator.zig 41          44               93.18%
lib/std/bounded_array.zig            164         168              97.62%
lib/std/math/tan.zig                 53          55               96.36%
lib/std/math/isinf.zig               70          71               98.59%
lib/std/zig/c_translation.zig        149         162              91.98%
lib/std/math/fma.zig                 80          103              77.67%
lib/std/mem.zig                      1195        1216             98.27%
lib/std/io/limited_reader.zig        17          18               94.44%
lib/std/os/linux/test.zig            51          58               87.93%
lib/std/math/acosh.zig               39          40               97.50%
lib/std/zig/parser_test.zig          661         684              96.64%
lib/std/x/net/tcp.zig                107         111              96.40%
lib/std/array_list.zig               588         593              99.16%
lib/std/crypto/poly1305.zig          126         128              98.44%
lib/std/math/big/int.zig             991         1043             95.01%
lib/std/math/pow.zig                 116         125              92.80%
lib/std/math/copysign.zig            55          56               98.21%
lib/std/ascii.zig                    108         109              99.08%
lib/std/math/complex/log.zig         9           10               90.00%
lib/std/zig/Ast.zig                  890         1072             83.02%
lib/std/json/test.zig                714         715              99.86%
lib/std/math/isfinite.zig            34          35               97.14%
lib/std/math/complex/exp.zig         52          67               77.61%
lib/std/fs/path.zig                  724         761              95.14%
lib/std/fs/watch.zig                 2           2               100.00%
lib/std/priority_queue.zig           325         329              98.78%
lib/std/math/atan.zig                94          103              91.26%
lib/std/sort.zig                     384         721              53.26%
lib/std/io/stream_source.zig         24          51               47.06%
lib/std/math/trunc.zig               78          79               98.73%
lib/std/x.zig                        2           2               100.00%
lib/std/io/reader.zig                115         133              86.47%
lib/std/child_process.zig            27          196              13.78%
lib/std/process.zig                  163         177              92.09%
lib/std/math/complex/sin.zig         9           10               90.00%
lib/std/math/big/int_test.zig        1032        1033             99.90%
lib/std/crypto/sha2.zig              240         267              89.89%
lib/std/zig/system/linux.zig         103         114              90.35%
lib/std/heap/arena_allocator.zig     58          59               98.31%
lib/std/math/log10.zig               103         112              91.96%
lib/std/rand/Xoshiro256.zig          56          57               98.25%
lib/std/event/channel.zig            4           4               100.00%
lib/std/Thread/Futex.zig             24          26               92.31%
lib/std/math/ilogb.zig               61          72               84.72%
lib/std/math/complex/acosh.zig       8           9                88.89%
lib/std/special/test_runner.zig      39          64               60.94%
lib/std/math/log1p.zig               119         122              97.54%
lib/std/io/counting_reader.zig       15          16               93.75%
lib/std/math/cos.zig                 54          55               98.18%
lib/std/fmt/parse_hex_float.zig      117         136              86.03%
lib/std/io/peek_stream.zig           40          41               97.56%
lib/std/rand.zig                     297         299              99.33%
lib/std/math/round.zig               99          106              93.40%
lib/std/math/powi.zig                103         105              98.10%
lib/std/io.zig                       10          10              100.00%
lib/std/crypto/sha3.zig              145         150              96.67%
lib/std/Thread/AutoResetEvent.zig    37          60               61.67%
lib/std/fmt/errol.zig                349         407              85.75%
lib/std/log.zig                      0           9                 0.00%
lib/std/crypto/aegis.zig             234         250              93.60%
lib/std/hash/adler.zig               51          55               92.73%
lib/std/math/sinh.zig                69          72               95.83%
lib/std/event/batch.zig              39          43               90.70%
lib/std/priority_dequeue.zig         521         525              99.24%
lib/std/x/os/net.zig                 150         156              96.15%
.../pcurves/p256/p256_scalar_64.zig  1661        1662             99.94%
lib/std/math/sqrt.zig                29          31               93.55%
lib/std/math/hypot.zig               88          104              84.62%
lib/std/cstr.zig                     21          24               87.50%
lib/std/math/complex/atan.zig        57          65               87.69%
lib/std/math/floor.zig               118         125              94.40%
lib/std/os/linux/tls.zig             56          68               82.35%
lib/std/os/linux/io_uring.zig        59          721               8.18%
lib/std/os/windows.zig               5           5               100.00%
lib/std/valgrind/memcheck.zig        26          27               96.30%
lib/std/io/bit_writer.zig            87          89               97.75%
lib/std/crypto/aes_ocb.zig           177         205              86.34%
lib/std/zig/render.zig               1415        1483             95.41%
lib/std/io/writer.zig                23          24               95.83%
lib/std/crypto/chacha20.zig          253         262              96.56%
lib/std/compress/gzip.zig            80          91               87.91%
lib/std/x/os/socket.zig              39          41               95.12%
lib/std/hash/fnv.zig                 23          24               95.83%
lib/std/fs/test.zig                  468         485              96.49%
lib/std/bit_set.zig                  485         495              97.98%
lib/std/crypto/sha1.zig              94          105              89.52%
lib/std/math/complex.zig             69          70               98.57%
lib/std/math/atan2.zig               139         160              86.88%
lib/std/crypto/25519/x25519.zig      59          60               98.33%
lib/std/build/RunStep.zig            0           146               0.00%
lib/std/os.zig                       551         1454             37.90%
lib/std/linked_list.zig              182         184              98.91%
lib/std/math/complex/arg.zig         6           7                85.71%
lib/std/crypto/hmac.zig              46          50               92.00%
lib/std/hash/crc.zig                 53          54               98.15%
lib/std/zig/fmt.zig                  39          44               88.64%
lib/std/array_hash_map.zig           749         942              79.51%
lib/std/math.zig                     598         615              97.24%
lib/std/crypto/25519/scalar.zig      613         614              99.84%
lib/std/builtin.zig                  54          83               65.06%
lib/std/crypto/test.zig              9           10               90.00%
lib/std/os/test.zig                  301         305              98.69%
lib/std/meta.zig                     233         244              95.49%
lib/std/math/exp.zig                 90          105              85.71%
lib/std/packed_int_array.zig         40          41               97.56%
lib/std/math/complex/cos.zig         8           9                88.89%
lib/std/crypto/gimli.zig             219         222              98.65%
lib/std/crypto/tlcsprng.zig          24          32               75.00%
lib/std/zig/tokenizer.zig            927         951              97.48%
lib/std/math/nan.zig                 6           6               100.00%
lib/std/multi_array_list.zig         259         272              95.22%
lib/std/math/fabs.zig                55          56               98.21%
lib/std/atomic/stack.zig             51          56               91.07%
lib/std/fs/file.zig                  182         233              78.11%
lib/std/rand/Xoroshiro128.zig        56          60               93.33%
lib/std/Thread/Mutex.zig             24          25               96.00%
lib/std/rand/Pcg.zig                 43          47               91.49%
lib/std/fmt/parse_float.zig          197         202              97.52%
lib/std/crypto/phc_encoding.zig      114         119              95.80%
lib/std/io/buffered_writer.zig       14          17               82.35%
lib/std/math/complex/sinh.zig        40          87               45.98%
lib/std/zig/cross_target.zig         217         345              62.90%
lib/std/hash/murmur.zig              224         225              99.56%
lib/std/base64.zig                   230         244              94.26%
lib/std/io/buffered_reader.zig       36          37               97.30%
lib/std/crypto/scrypt.zig            100         101              99.01%
lib/std/crypto/ghash.zig             161         164              98.17%
lib/std/build/InstallRawStep.zig     31          216              14.35%
lib/std/testing.zig                  79          153              51.63%
lib/std/math/cosh.zig                65          69               94.20%
lib/std/math/ln.zig                  85          94               90.43%
lib/std/wasm.zig                     24          25               96.00%
lib/std/zig/system/x86.zig           141         282              50.00%
lib/std/build/OptionsStep.zig        46          91               50.55%
lib/std/c.zig                        1           1               100.00%
.../testing/failing_allocator.zig    32          33               96.97%
lib/std/hash_map.zig                 729         807              90.33%
lib/std/build.zig                    227         1577             14.39%
lib/std/build/CheckFileStep.zig      0           19                0.00%
lib/std/crypto/siphash.zig           111         112              99.11%
lib/std/x/os/socket_posix.zig        47          85               55.29%
lib/std/Thread/ResetEvent.zig        24          25               96.00%
lib/std/build/WriteFileStep.zig      0           55                0.00%
lib/std/crypto/25519/field.zig       170         172              98.84%
lib/std/zig.zig                      104         195              53.33%
lib/std/debug.zig                    43          340              12.65%
lib/std/hash/wyhash.zig              123         132              93.18%
lib/std/event/wait_group.zig         2           2               100.00%
lib/std/rand/Sfc64.zig               41          45               91.11%
lib/std/os/linux/x86_64.zig          48          50               96.00%
lib/std/mem/Allocator.zig            114         125              91.20%
lib/std/rand/Isaac64.zig             92          96               95.83%
lib/std/hash/auto_hash.zig           135         138              97.83%
lib/std/SemanticVersion.zig          92          97               94.85%
lib/std/event/lock.zig               2           2               100.00%
lib/std/Thread/StaticResetEvent.zig  34          39               87.18%
lib/std/math/frexp.zig               87          92               94.57%
lib/std/math/asin.zig                75          83               90.36%
lib/std/math/inf.zig                 6           6               100.00%
lib/std/build/TranslateCStep.zig     0           46                0.00%
lib/std/zig/system/darwin.zig        1           1               100.00%
lib/std/math/exp2.zig                69          82               84.15%
lib/std/enums.zig                    103         109              94.50%
lib/std/compress.zig                 1           1               100.00%
lib/std/math/complex/conj.zig        4           5                80.00%
lib/std/rand/ziggurat.zig            30          47               63.83%
lib/std/math/isnormal.zig            22          23               95.65%
lib/std/crypto/blake3.zig            214         219              97.72%
lib/std/dynamic_library.zig          13          109              11.93%
lib/std/crypto/utils.zig             112         113              99.12%
lib/std/crypto/bcrypt.zig            235         244              96.31%
lib/std/math/expm1.zig               146         170              85.88%
lib/std/atomic/queue.zig             142         149              95.30%
lib/std/buf_map.zig                  53          57               92.98%
lib/std/event/group.zig              2           2               100.00%
lib/std/hash.zig                     1           1               100.00%
lib/std/math/complex/acos.zig        8           9                88.89%
lib/std/math/isnan.zig               13          14               92.86%
lib/std/compress/zlib.zig            68          71               95.77%
lib/std/crypto/pcurves/tests.zig     66          67               98.51%
lib/std/math/expo2.zig               8           8               100.00%
lib/std/event.zig                    1           1               100.00%
lib/std/math/complex/atanh.zig       9           10               90.00%
------------------------------------ ----------- -------------- --------
Total                                43480       52586            82.68%
```

</details>

And for those interested, here's [a zip file containing the full set of generated `.diff` files that show the line-by-line coverage](https://www.ryanliptak.com/misc/zig-std-lib-coverage-20210910-0c091feb5a.zip).
