One of the unique features of [Zig](https://ziglang.org/) is that it ["cares about allocation failure"](https://youtu.be/Z4oYSByyRak?t=774). That is:

- Allocation is explicit---there is no global allocator and no hidden memory allocations
- All allocations have the possibility of returning `error.OutOfMemory`
- Errors must be handled in some way by the caller---it's a compile error to ignore a possible error

Together, these conditions make it so that the code you naturally write in Zig will include handling of `OutOfMemory` errors. However, because actually running into `OutOfMemory` organically is rare, it's not easy to be sure that you're handling the error correctly in all cases. Additionally, because there are many functions that have `OutOfMemory` as their only possible error, the error handling of those function calls are not exercised in a typical test environment.

## A strategy for testing `OutOfMemory` errors

Luckily, though, allocators in Zig also have some unique properties that lend themselves to potential remedies:

- Allocators are a purely userland concept; the compiler itself has no understanding or knowledge of them
- Any function that may need to allocate gets passed an allocator in a parameter (note: this is only a convention, but it's followed across the standard library)

The first point means that it's easy/normal to write custom allocators, while the second means that it's easy/normal to swap out allocators during tests. In order to test `OutOfMemory` errors, Zig's standard library contains `std.testing.FailingAllocator`, which will induce an `OutOfMemory` error once it hits its user-defined number of allocations. Here's a simple example:

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

As long as the number of memory allocations is deterministic, this strategy works, and is the strategy that the [Zig parser tests](https://github.com/ziglang/zig/blob/911c839e97194eb270389b03d4d364659c46a5ac/lib/std/zig/parser_test.zig#L5462-L5508) have employed for years ([since 2017](https://github.com/ziglang/zig/commit/ed4d94a5d54bc49b3661d602301a5ec926abef61)) to ensure that the parser handles memory allocation failures without introducing memory leaks (the implementation of this strategy also happens to be the reason that `FailingAllocator` was created).

Recently, I went ahead and converted the strategy used by the parser tests into a function---[`std.testing.checkAllAllocationFailures`](https://github.com/ziglang/zig/pull/10586)---which will be available in the next release of Zig (`0.10.0`), or can be used now in [the latest `master` version of Zig](https://ziglang.org/download/#release-master).

## How to use `checkAllAllocationFailures`

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

We'll need to make some changes to the test in order to be able to use `checkAllAllocationFailures` with it. Here's the signature of `std.testing.checkAllAllocationFailures` along with a small portion of its doc comment:

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

```language-diff
-     try parseTest(std.testing.allocator, &stream_source, expected);
+     try std.testing.checkAllAllocationFailures(
+         std.testing.allocator,
+         parseTest,
+         .{ &stream_source, expected },
+     );
```

Before running this, though, we'll need to make a change to the `parseTest` function as well. Since `checkAllAllocationFailures` will now be calling `parseTest` multiple times (one initial call and then another for each induced allocation failure), we need to make sure that any relevant state is reset at the start of every call. From the `checkAllAllocationsFailures` doc comment:

```language-zig
/// Any relevant state shared between runs of `test_fn` *must* be reset within `test_fn`.
```

In this case, the cursor of the `StreamSource` needs to be reset, as otherwise, after the first run, the cursor will remain at the end of the stream and the next run will immediately fail with `EndOfStream` (instead of the induced `OutOfMemory` that we expect). To fix this, we need to add this to the beginning of `parseTest`:

```language-zig
    try stream_source.seekTo(0);
```

Now when we run the test, it will induce allocation failures and report any problems it finds. Here are the results (heavily truncated to only include the relevant portions):

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

From this, we can see a few things:

- The test failed with `error.MemoryLeakDetected` returned from `checkAllAllocationFailures`.
- Additionally, before returning, it printed some info from the `FailingAllocator` including a stack trace of the allocation that was made to fail (note: the stack trace reporting part [has not yet been merged](https://github.com/ziglang/zig)).
- And finally, the `std.testing.allocator` that we passed as the backing allocator to `checkAllAllocationFailures` printed the memory address of the leaked allocation along with a stack trace of where it was allocated.

In particular, this is the problematic code:

```language-zig
var key = try reader.readUntilDelimiterAlloc(allocator, '=', std.math.maxInt(usize));
var value = (try reader.readUntilDelimiterOrEofAlloc(allocator, '\n', std.math.maxInt(usize))) orelse return error.EndOfStream;

try map.putMove(key, value);
```

That is, we're leaking the allocation for `key` when the allocation for `value` fails. This wasn't a problem before because normally (without the induced allocation failure), the `map.putMove` would take ownership of the allocations and they'd get cleaned up along with the `BufMap`.

The simple fix here is to put in an [`errdefer`](https://ziglang.org/documentation/master/#errdefer) that will free `key` (but only if the `value` allocation fails or the `putMove` call fails) like so:

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

It is similar to before, but now we can see that `value` is being leaked when the `map.putMove` call fails. Now let's put in that `errdefer` for value:

```language-diff
  var value = (try reader.readUntilDelimiterOrEofAlloc(allocator, '\n', std.math.maxInt(usize))) orelse return error.EndOfStream;
+ errdefer allocator.free(value);
```

And run the test again:

```language-zigstacktrace
All 1 tests passed.
```

## Making its usage conditional

```language-zig
const induce_allocation_failures = true;

test {
	// (omitted, same as previous example)

    if (induce_allocation_failures) {
    	return std.testing.checkAllAllocationFailures(std.testing.allocator, parseTest, .{ &stream_source, expected });
    } else {
        return parseTest(testing.allocator, &stream_source, expected);
    }
}
```

### Integrating with `build.zig`

## Integrating with fuzz testing

## How it's been used so far
