Heap allocation failure is something that is hard or impossible to account for in every case in most programming languages. There are either hidden memory allocations that can't be handled, or it's seen as too inconvenient to handle *every* possible allocation failure so the possibility is ignored.

For example, when concatenating two strings with the `+` operator (where there is an implicit allocation that's needed to store the result of the concatenation):

- In garbage collected languages like JavaScript, the possible failure of the hidden allocation can't be handled by the user
- In languages with exceptions like C++, it's possible to catch e.g. `std::bad_alloc`, but it's easy to ignore or mishandle (or not be aware of the possibility of allocation failure in every case)

Even in C, where the return of `malloc` can be checked against `NULL` to detect allocation failure, it's pretty common to see unchecked `malloc` calls in C code (and C compilers let you ignore the possibility of allocation failure without complaint).

<p><aside class="note">

Note: The above is a (possibly bad) paraphrase of [the intro to this talk](https://www.youtube.com/watch?v=Z4oYSByyRak), so I recommend watching that if you'd like more detail.

</aside></p>

## Zig and allocation failure

One of the unique features of [Zig](https://ziglang.org/) is that it ["cares about allocation failure"](https://youtu.be/Z4oYSByyRak?t=774). That is:

- Allocation is explicit---there is no global allocator and no hidden memory allocations
- All allocations have the possibility of returning `error.OutOfMemory`
- Errors must be handled in some way by the caller---it's a compile error to ignore a possible error

Together, these conditions make it so that the code you naturally write in Zig will include handling of `OutOfMemory` errors. However, because actually running into `OutOfMemory` organically is rare, it's not easy to be sure that you're handling the error correctly in all cases. Additionally, because there are many functions that have `OutOfMemory` as their only possible error, the error handling of those function calls are not exercised in a typical test environment.

## A strategy for testing `OutOfMemory` errors

Luckily, though, allocators in Zig also have some unique properties that lend themselves to potential remedies:

- Allocators are a purely "userland" concept; the language itself has no understanding or knowledge of them
- Any function that may need to allocate gets passed an allocator as a parameter (this is only a convention, but it's followed across the standard library)

The first point means that it's easy/normal to write custom allocators, while the second means that it's easy/normal to swap out allocators during tests. In order to help test `OutOfMemory` errors, Zig's standard library contains `std.testing.FailingAllocator`, which will artificially induce an `OutOfMemory` error once it hits its user-defined number of allocations. Here's a simple example:

```language-zig
test {
	// Create an allocator that will fail on the 0th allocation
	var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, 0);
	// Try to allocate 8 bytes
	var allocation = failing_allocator.allocator().alloc(u8, 8);
	// Confirm that the allocation failed and gave OutOfMemory
	try std.testing.expectError(error.OutOfMemory, allocation);
}
```

This `FailingAllocator` lays the groundwork for a strategy that allows inducing `OutOfMemory` for *all* allocations within a chunk of code. The strategy goes like this:

1. Run the code once and keep track of the total number of allocations that happen within it.
2. Then, iterate and run the code X more times, incrementing the failing index each iteration (where X is the total number of allocations determined previously).

As long as the number of memory allocations is deterministic, this strategy works, and is the strategy that the [Zig parser tests](https://github.com/ziglang/zig/blob/911c839e97194eb270389b03d4d364659c46a5ac/lib/std/zig/parser_test.zig#L5462-L5508) have employed for years ([since 2017](https://github.com/ziglang/zig/commit/ed4d94a5d54bc49b3661d602301a5ec926abef61)) to ensure that the parser handles memory allocation failures without introducing memory leaks (interestingly enough, the implementation of this strategy for the Zig parser tests also happens to be the reason that `FailingAllocator` was created).

Recently, I went ahead and turned the strategy used by the Zig parser tests into something more re-usable---[`std.testing.checkAllAllocationFailures`](https://github.com/ziglang/zig/pull/10586)---which will be available in the next release of Zig (`0.10.0`), or can be used now in [the latest `master` version of Zig](https://ziglang.org/download/#release-master).

## How to use `checkAllAllocationFailures`

<p><aside class="note">

Note: I've created a [repository with runnable versions of all the steps outlined in this article](https://github.com/squeek502/zig-checkAllAllocationFailures-example) if you want to follow along

</aside></p>

Here's some code that parses a newline-separated list of `key=value` pairs, e.g.

```language-text
something=other
equals=equals
```

and returns it as a `std.BufMap`:

```language-zig
const std = @import("std");

pub fn parse(allocator: std.mem.Allocator, stream_source: *std.io.StreamSource) !std.BufMap {
    var map = std.BufMap.init(allocator);
    errdefer map.deinit();

    const reader = stream_source.reader();
    const end_pos = try stream_source.getEndPos();
    while ((try stream_source.getPos()) < end_pos) {
        var key = try reader.readUntilDelimiterAlloc(allocator, '=', std.math.maxInt(usize));
        var value = (try reader.readUntilDelimiterOrEofAlloc(allocator, '\n', std.math.maxInt(usize))) orelse return error.EndOfStream;

        try map.putMove(key, value);
    }

    return map;
}
```

There are some problems lurking in the function that you might be able to spot, but we'll get to them later. Here's a simple test case that passes just fine:

```language-zig
test {
    const data =
        \\foo=bar
        \\baz=qux
    ;
    var stream_source = std.io.StreamSource{ .const_buffer = std.io.fixedBufferStream(data) };
    var parsed = try parse(std.testing.allocator, &stream_source);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 2), parsed.count());
    try std.testing.expectEqualStrings("bar", parsed.get("foo").?);
    try std.testing.expectEqualStrings("qux", parsed.get("baz").?);
}
```

In order to be able to use `checkAllAllocationFailures` for this test, we'll need to make some changes to it. For reference, here's the signature of `std.testing.checkAllAllocationFailures` along with a small portion of its doc comment:

```language-zig
/// The provided `test_fn` must have a `std.mem.Allocator` as its first argument,
/// and must have a return type of `!void`. Any extra arguments of `test_fn` can
/// be provided via the `extra_args` tuple.
pub fn checkAllAllocationFailures(
    backing_allocator: std.mem.Allocator,
    comptime test_fn: anytype,
    extra_args: anytype,
) !void
```

So, we'll need to move our test code into an appropriately constructed function that we can provide to `checkAllAllocationFailures`:

- It will need a return type of `!void`.
- It will take an allocator as its first argument.
- It will need parameters for any relevant inputs (in this case, the `StreamSource`).
- We'll need to pass the expected values into the function, since we'll need to do any validation within the function instead of within the test block.

In this case, this ends up looking something like this:

```language-zig
fn parseTest(allocator: std.mem.Allocator, stream_source: *std.io.StreamSource, expected: std.BufMap) !void {
    var parsed = try parse(allocator, stream_source);
    defer parsed.deinit();

    try std.testing.expectEqual(expected.count(), parsed.count());
    var expected_it = expected.iterator();
    while (expected_it.next()) |expected_entry| {
        const actual_value = parsed.get(expected_entry.key_ptr.*).?;
        try std.testing.expectEqualStrings(expected_entry.value_ptr.*, actual_value);
    }
}
```

with a test block like so:

```language-zig
test {
    const data =
        \\foo=bar
        \\baz=qux
    ;
    var stream_source = std.io.StreamSource{ .const_buffer = std.io.fixedBufferStream(data) };
    var expected = expected: {
        var map = std.BufMap.init(std.testing.allocator);
        errdefer map.deinit();
        try map.put("foo", "bar");
        try map.put("baz", "qux");
        break :expected map;
    };
    defer expected.deinit();

    try parseTest(std.testing.allocator, &stream_source, expected);
}
```

This still passes just fine. Now let's replace the direct `parseTest` call with a `checkAllAllocationFailures` call:

- For the backing allocator, we can still use the `std.testing.allocator`
- To provide the extra parameters that `parseTest` needs to be called with, we can use an [anonymous list literal/tuple](https://ziglang.org/documentation/master/#Anonymous-List-Literals) (the types within the tuple are checked at compile-time to ensure they match the signature of the `test_fn`)

```language-diff
-     try parseTest(std.testing.allocator, &stream_source, expected);
+     try std.testing.checkAllAllocationFailures(
+         std.testing.allocator,
+         parseTest,
+         .{ &stream_source, expected },
+     );
```

<p><aside class="note">

Using `std.testing.allocator` as the backing allocator will also allow `checkAllAllocationFailures` to detect double frees, invalid frees, etc. that happen as a result of allocation failure. On its own (e.g. with a `FixedBufferAllocator` as the backing allocator), `checkAllAllocationFailures` will only be able to find memory leaks.

</aside></p>

Before running this, though, we'll need to make one last change to the `parseTest` function. Since `checkAllAllocationFailures` will now be calling `parseTest` multiple times (one initial call and then another for each induced allocation failure), we need to make sure that any relevant state is reset at the start of every call. From the `checkAllAllocationsFailures` doc comment:

```language-zig
/// Any relevant state shared between runs of `test_fn` *must* be reset within `test_fn`.
```

In this case, the cursor of the `StreamSource` needs to be reset, as otherwise, after the first run, the cursor will remain at the end of the stream and the next run will immediately fail with `EndOfStream` (instead of the induced `OutOfMemory` that we'd expect). To fix this, we need to add this to the beginning of `parseTest`:

```language-zig
    try stream_source.seekTo(0);
```

Now when we run the test, it will induce allocation failures and report any problems it finds. Here are the results from the first run (heavily truncated to only include the relevant portions of the stack traces):

```language-zigstacktrace
fail_index: 1/5
allocated bytes: 8
freed bytes: 5
allocations: 1
deallocations: 0
allocation that was made to fail:
src/main.zig:12:61: 0x20f2b6 in parse (test)
        var value = (try reader.readUntilDelimiterOrEofAlloc(allocator, '\n', std.math.maxInt(usize))) orelse return error.EndOfStream;
                                                            ^
src/main.zig:24:27: 0x20edc9 in parseTest (test)
    var parsed = try parse(allocator, stream_source);
                          ^

Test [1/1] test ""... FAIL (MemoryLeakDetected)
zig/lib/std/testing.zig:713:21: 0x20a5d8 in std.testing.checkAllAllocationFailures (test)
                    return error.MemoryLeakDetected;
                    ^
src/main.zig:50:5: 0x209ac1 in test "" (test)
    try std.testing.checkAllAllocationFailures(
    ^

[gpa] (err): memory address 0x7fda4c422000 leaked:
src/main.zig:10:53: 0x20f139 in parse (test)
        var key = try reader.readUntilDelimiterAlloc(allocator, '=', std.math.maxInt(usize));
                                                    ^
src/main.zig:24:27: 0x20ece9 in parseTest (test)
    var parsed = try parse(allocator, stream_source);
                          ^
```

From this, we can see a few things (starting from the top):

- It printed some info from the `FailingAllocator` including a stack trace of the allocation that was made to fail (note: the stack trace reporting part [was only recently merged](https://github.com/ziglang/zig/pull/11919)).
- The test failed with `error.MemoryLeakDetected` returned from `checkAllAllocationFailures`.
- And finally, the `std.testing.allocator` that we passed as the backing allocator to `checkAllAllocationFailures` printed the memory address of the leaked allocation along with a stack trace of where the leaked memory was allocated.

In particular, this is the problematic code:

```language-zig
var key = try reader.readUntilDelimiterAlloc(allocator, '=', std.math.maxInt(usize));
var value = (try reader.readUntilDelimiterOrEofAlloc(allocator, '\n', std.math.maxInt(usize))) orelse return error.EndOfStream;

try map.putMove(key, value);
```

That is, we're leaking the allocation for `key` when the allocation for `value` fails. This wasn't a problem before the introduction of `checkAllAllocationFailures` because normally (if all the allocations in the test succeed), the `map.putMove` would take ownership of the allocated memory of both `key` and `value` and then they'd get cleaned up along with the `BufMap` later on.

The simplest fix here would be to put in an [`errdefer`](https://ziglang.org/documentation/master/#errdefer) that will free `key` (`errdefer` instead of `defer` so that it runs only if the `value` allocation fails or the `putMove` call fails) like so:

```language-diff
  var key = try reader.readUntilDelimiterAlloc(allocator, '=', std.math.maxInt(usize));
+ errdefer allocator.free(key);
```

If you happen to be thinking that we'll need the same fix for `value`, you'd be correct. However, for the sake of completeness let's try running the test again with only the `errdefer` for `key` added. Here's the result:

```language-zigstacktrace
fail_index: 2/5
allocated bytes: 16
freed bytes: 13
allocations: 2
deallocations: 1
allocation that was made to fail:
src/main.zig:15:24: 0x20f3ed in parse (test)
        try map.putMove(key, value);
                       ^

Test [1/1] test ""... FAIL (MemoryLeakDetected)
zig/lib/std/testing.zig:714:21: 0x20a6b3 in std.testing.checkAllAllocationFailures (test)
                    return error.MemoryLeakDetected;
                    ^
src/main.zig:50:5: 0x209b81 in test "" (test)
    try std.testing.checkAllAllocationFailures(
    ^

[gpa] (err): memory address 0x7f6ff57de008 leaked:
src/main.zig:12:61: 0x20f2b6 in parse (test)
        var value = (try reader.readUntilDelimiterOrEofAlloc(allocator, '\n', std.math.maxInt(usize))) orelse return error.EndOfStream;
                                                            ^
src/main.zig:24:27: 0x20edc9 in parseTest (test)
    var parsed = try parse(allocator, stream_source);
                          ^
```

It is similar to before, but now we can see that `value` is being leaked when the `map.putMove` call fails. Now let's put in the `errdefer` for value:

```language-diff
  var value = (try reader.readUntilDelimiterOrEofAlloc(allocator, '\n', std.math.maxInt(usize))) orelse return error.EndOfStream;
+ errdefer allocator.free(value);
```

And run the test again:

```language-zigstacktrace
All 1 tests passed.
```

With this, we can be reasonably confident that if any of the allocations that occur within the test fail, we handle the `OutOfMemory` error without introducing more problems.

## Making its usage conditional

We might not always want to run our test code N+1 times (where N is the number of allocations that occur within the test). Luckily, once a `checkAllAllocationFailures`-compatible function is written, it's easy to switch between using it with `checkAllAllocationFailures` and calling it directly:

```language-zig
const check_allocation_failures = true;

test {
	// (omitted, same as previous example)

    if (check_allocation_failures) {
    	try std.testing.checkAllAllocationFailures(std.testing.allocator, parseTest, .{ &stream_source, expected });
    } else {
        try parseTest(testing.allocator, &stream_source, expected);
    }
}
```

### Integrating with `build.zig`

To make this nicer, we can make the `check_allocation_failures` constant an option within `build.zig` so that we can disable it by doing something like `zig build test -Dcheck-allocation-failures=false`.

```language-zig
pub fn build(b: *std.build.Builder) void {
    // ...

    // Create the test step
    const main_tests = b.addTest("src/main.zig");

    // Create the command line option (with a default of true)
    const check_allocation_failures = b.option(bool, "check-allocation-failures", "Run tests with checkAllAllocationFailures (default: true)") orelse true;
    
    // Create the option using the value gotten from the command line
    const test_options = b.addOptions();
    test_options.addOption(bool, "check_allocation_failures", check_allocation_failures);

    // Add the options as "test_options" to the main_tests step
    // Our option can then be accessed via `@import("test_options").check_allocation_failures`
    main_tests.addOptions("test_options", test_options);

    // ...
}
```

which then can be used like so:

```language-zig
test {
    // ...

    if (@import("test_options").check_allocation_failures) {
        try std.testing.checkAllAllocationFailures(std.testing.allocator, parseTest, .{ &stream_source, expected });
    } else {
        try parseTest(std.testing.allocator, &stream_source, expected);
    }
}
```

## Caveat about non-deterministic memory usage

Earlier, I said that:

> As long as the number of memory allocations is deterministic, this strategy works

However, it turns out that the code we've been testing can actually have non-deterministic memory usage of a sort (at least with the implementation of `std.BufMap` as of this article's writing). For example, if we use the following input for our `parse` function:

```language-text
foo=bar
baz=dup
a=b
b=c
c=d
d=e
baz=qux
```

then when running with `checkAllAllocationFailures`, we hit a scenario in which:

- Entries into the `BufMap` are inserted for `foo`, `baz`, `a`, `b`, `c`, and `d` successfully
- It just so happens that the `BufMap` would need to grow to be able to insert another entry
- `try map.putMove(key, value)` is called for `baz=qux`, but the allocation for trying to grow the map is made to fail by `checkAllAllocationFailures`
- The internals of `std.BufMap.putMove` can recover from `OutOfMemory` if the key that is trying to be inserted is found in the map, which is the case here (the `baz` key was inserted previously, so it can return that previous entry)
- Because there was an existing entry, `putMove` succeeds and therefore `OutOfMemory` is *not* returned

This means that, although an `OutOfMemory` error was induced, our `parseTest` call will succeed, which triggers `checkAllAllocationFailures` to return `error.NondeterministicMemoryUsage` and fail the test, as it assumes that all calls of the function with an induced allocation failure will have a return of `error.OutOfMemory`.

<p><aside class="note">

Note: After a bit of benchmarking, the current strategy of `std.BufMap.putMove` (to always try growing first, and then recovering from `OutOfMemory` if it gets hit) seems to be faster than the reverse (doing a key lookup first, and only trying to grow if the key is not already found [which would make it have a deterministic number of memory allocations]). This is just based on some naive attempts at implementing the reverse strategy, though.

</aside></p>

This is something of a false positive in terms of non-determinism, though, as the above scenario is still deterministic, but the `OutOfMemory` in one particular case is handled without bubbling up the error.

Since we know that this is a false-positive, we can ignore `error.NondeterministicMemoryUsage` by catching it like so:

```language-zig
std.testing.checkAllAllocationFailures(
    std.testing.allocator,
    parseTest,
    .{ &stream_source, expected },
) catch |err| switch (err) {
    error.NondeterministicMemoryUsage => {},
    else => |e| return e,
};
```

This should generally be avoided, though, as treating `error.NondeterministicMemoryUsage` as a bug by default makes sense. Unless you know that part of the code you're testing has `OutOfMemory` recovery in place somewhere (like `std.BufMap.putMove`), then it's generally a good idea to ensure that the code under test doesn't erroneously/unexpectedly 'swallow' `OutOfMemory` errors.

<p><aside class="note">

There is a [recently merged pull request](https://github.com/ziglang/zig/pull/11919) that adds a possible `error.SwallowedOutOfMemoryError` return from `checkAllAllocationFailures` that is triggered when `FailingAllocator` does induce `OutOfMemory`, but it doesn't get returned by `test_fn`. With this new error, it:

- makes this caveat more understandable/obvious
- allows the caller to ignore *only* the `error.SwallowedOutOfMemoryError` case while continuing to treat `error.NondeterministicMemoryUsage` as an error

</aside></p>

If your code's memory allocation is truly non-deterministic in the sense that subsequent runs could have *more* points of allocation than the initial run, then ignoring the `error.NondeterministicMemoryUsage` is inadvisable, as the strategy used by `checkAllAllocationFailures` would no longer be guaranteed to provide full coverage of all possible points of allocation failure.

<p><aside class="note">

Fun fact: I ran into this caveat via fuzz testing while writing the section that follows. I was not previously aware of this `std.BufMap.putMove` behavior or that it could trigger `error.NondeterministicMemoryUsage` in `checkAllAllocationFailures`.

</aside></p>

## Integrating with fuzz testing

For projects where fuzz testing makes sense, it's possible to use `checkAllAllocationFailures` alongside fuzz testing to find bugs related to `OutOfMemory` error handling that are not (yet) covered by your test cases.

<p><aside class="note">

See [Fuzzing Zig Code Using AFL++](https://www.ryanliptak.com/blog/fuzzing-zig-code/) for more information about the fuzzing setup used here

</aside></p>

For this, we'll need to create a modified version of our `parseTest` function from before where:

- It no longer needs to take `expected`, as we don't have that information for fuzzed inputs
- We want to ignore any errors besides `OutOfMemory` when calling `parse`, since we want to allow invalid inputs

```language-zig
fn parseTest(allocator: std.mem.Allocator, stream_source: *std.io.StreamSource) !void {
    try stream_source.seekTo(0);

    if (parse(allocator, stream_source)) |*parsed| {
        parsed.deinit();
    } else |err| {
        switch (err) {
            // We only want to return the error if it's OutOfMemory
            error.OutOfMemory => return error.OutOfMemory,
            // Any other error is fine since not all inputs will be valid
            else => {},
        }
    }
}
```

And then we'll need a fuzzing-compatible main which looks something like this (again, see [here](https://www.ryanliptak.com/blog/fuzzing-zig-code/) for more info):

```language-zig
const std = @import("std");
const parse = @import("main.zig").parse;

pub export fn main() void {
    zigMain() catch unreachable;
}

pub fn zigMain() !void {
    // Set up a GeneralPurposeAllocator so that we can also catch double-frees, etc
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == false);
    const allocator = gpa.allocator();

    // Get the fuzzed input form stdin and create a StreamSource with it so we can
    // pass that to parseTest via checkAllAllocationFailures
    const stdin = std.io.getStdIn();
    const data = try stdin.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(data);
    var stream_source = std.io.StreamSource{ .buffer = std.io.fixedBufferStream(data) };

    // Call checkAllAllocationFailures, but ignore error.NondeterministicMemoryUsage
    // (normally you wouldn't ignore NondeterministicMemoryUsage, but it's necessary in our
    // case because we use `std.BufMap.putMove` which has an OutOfMemory recovery strategy)
    std.testing.checkAllAllocationFailures(allocator, parseTest, .{&stream_source}) catch |err| switch (err) {
        error.NondeterministicMemoryUsage => {},
        else => |e| return e,
    };
}
```

The simple `parse` function used as an example in this post is not very exciting in terms of fuzzing, unfortunately. Besides the `error.NondeterministicMemoryUsage` caveat, there's nothing more to be found once we've added in the `errdefer`'s mentioned previously (and the version without the `errdefer`'s would trigger a crash with any reasonable seed input, so `afl-fuzz` would refuse to fuzz until that is fixed). In more complex projects, though, fuzzing can be very helpful in finding novel `OutOfMemory`-related bugs.

<p><aside class="note">

See also the ["Fuzzing to find memory bugs after allocation failure" section of this article](https://www.ryanliptak.com/blog/improving-fuzz-testing-with-zig-allocators/) for an alternate strategy that only checks one allocation failure per input. This would allow more inputs to be checked per second, but each input would not be as thoroughly checked. Still not quite sure which strategy would lead to the best results in terms of fuzz testing, but the thoroughness of the `checkAllAllocationFailures` version seems like it might win out.

</aside></p>

## How it's been used so far

A [code search on GitHub for `checkAllAllocationFailures`](https://github.com/search?q=checkAllAllocationFailures&type=code) comes up with a few projects that have already started using it:

- [Vexu/arocc](https://github.com/Vexu/arocc)
  + Plenty of bugs were found and fixed in [the pull request that added integration](https://github.com/Vexu/arocc/pull/276), but there are still some remaining allocation-failure-induced leaks to work out.

- [squeek502/audiometa](https://github.com/squeek502/audiometa) (my project)
  + All the relevant bugs were found and fixed via [the fuzzing strategy laid out in this article](https://www.ryanliptak.com/blog/improving-fuzz-testing-with-zig-allocators/); `checkAllAllocationFailures` is now [used to ensure nothing regresses](https://github.com/squeek502/audiometa/blob/a4018fc5c350f0dd8e3fc1e5d61faa9032f06087/test/parse_tests.zig#L33-L37).

- [chwayne/zss](https://github.com/chwayne/zss)
  + From the message of [the commit that added integration](https://github.com/chwayne/zss/commit/ca78804ebc8282db51a089c3c626a97994b22f63):
  > "It already helped to find a dangling pointer error!"

## Room for improvement

It seems possible that this strategy could be integrated into the test runner itself, which would remove having to manually add integration on a test-by-test basis. A similar type of integration is already included for leak checking via `std.testing.allocator`, as [the test runner initializes and `deinit`s a new `GeneralPurposeAllocator` for you for each test](https://github.com/ziglang/zig/blob/08459ff1c21d546c55e2ae954126e121ee88972e/lib/test_runner.zig#L50-L55) and [reports the results](https://github.com/ziglang/zig/blob/08459ff1c21d546c55e2ae954126e121ee88972e/lib/test_runner.zig#L109-L111).

If this is done for checking allocation failures, then that'd allow anyone to run all their tests (presumably only when a command line flag is set) with the `checkAllAllocationFailures` strategy (given they use `std.testing.allocator`, although that might depend on the implementation).
