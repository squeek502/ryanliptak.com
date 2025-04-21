<p><aside class="update"><i>Last updated 2022-05-08</i> (<a href="https://github.com/squeek502/ryanliptak.com/commits/master/posts/improving-fuzz-testing-with-zig-allocators.md">changelog</a>)</aside></p>

After [finding a method for fuzz testing Zig code](https://www.ryanliptak.com/blog/fuzzing-zig-code/) and using it to iron out some possible crashes in [an audio metadata parser](https://github.com/squeek502/audiometa) I'm writing in [Zig](https://ziglang.org/), I have been experimenting with different ways to use fuzz testing to improve my library in other dimensions.

## Fuzzing to optimize worst-case performance

When fuzzing, my library would typically run at around 6000-9000 inputs/sec, but I noticed that every so often it would dip down much lower (into the hundreds per second). Because it was occasional and I was lazy, I didn't think much of it. After refactoring part of the library, though, the slow-downs were no longer rare--the performance had flipped such that hundreds of inputs per second was the norm and thousands was the exception. However, on well-formed (non-fuzzed) inputs, the slowdown didn't seem to manifest, so I wasn't sure what was going on.

Using the [AFL fuzzer](https://github.com/AFLplusplus/AFLplusplus), these slow inputs are usually considered 'timeouts,' but as far as I can tell timeouts are not stored in any accessible way. If they hit a certain threshold of time taken, though, they are considered 'hangs', in which case the inputs *are* made available for easy debugging.

To ensure that slow inputs are classed as hangs instead of timeouts so that they can be debugged, the environment variable `AFL_HANG_TMOUT` can be set (by default, it is set at 1 second, which my library was not triggering). Here's an example of running a fuzzer with a 10ms hang threshold:

```language-shellsession
$ AFL_HANG_TMOUT=10 afl-fuzz -i test/data -o test/fuzz-outputs -- ./zig-out/bin/fuzz
```

With this, I was able to debug some of these slow cases and found that the slowness was coming from allocating extremely large slices of memory for no good reason. What was going on was that, in various metadata headers, the header would have a 'length' field describing the size of some part of the metadata. My library would, in certain cases, take these headers at their word and try to allocate the given length, even if that length was not really feasible, e.g. if the length was larger than the size of the entire input data. Here's an example of what this type of thing looked like (with the appropriate fix in place):

```language-zig
const comment_length = try reader.readIntLittle(u32);

// short circuit for impossible comment lengths to avoid
// giant allocations that we know are impossible to read
const max_remaining_bytes = (try seekable_stream.getEndPos()) - (try seekable_stream.getPos());
if (comment_length > max_remaining_bytes) {
    return error.EndOfStream;
}

// before the above check, this would actually allocate the
// memory, and then readNoEof would fail below with EndOfStream
// once it read to the end of the file
var comment = try allocator.alloc(u8, comment_length);
defer allocator.free(comment);
try reader.readNoEof(comment);
```

This method of using `AFL_HANG_TMOUT` to find hangs can work decently well to find bugs of this nature, but I thought there might be a potentially better way to get at the same problem by taking advantage of how easy it is to use custom allocators in Zig.

### Fuzzing with a custom allocator that fails on too-large allocations

In order to be certain that all bugs of this nature are ironed out, I thought it'd make sense to induce a crash if a suspiciously large allocation were ever attempted. This is possible by writing a custom allocator that wraps another allocator, like so:

```language-zig
/// Allocator that checks that individual allocations never go over
/// a certain size, and panics if they do
const MaxSizeAllocator = struct {
    parent_allocator: Allocator,
    max_alloc_size: usize,

    const Self = @This();

    pub fn init(parent_allocator: Allocator, max_alloc_size: usize) Self {
        return .{
            .parent_allocator = parent_allocator,
            .max_alloc_size = max_alloc_size,
        };
    }

    pub fn allocator(self: *Self) Allocator {
        return Allocator.init(self, alloc, resize, free);
    }

    fn alloc(self: *Self, len: usize, ptr_align: u29, len_align: u29, ra: usize) error{OutOfMemory}![]u8 {
        if (len > self.max_alloc_size) {
            std.debug.print("trying to allocate size: {}\n", .{len});
            @panic("allocation exceeds max alloc size");
        }
        return self.parent_allocator.rawAlloc(len, ptr_align, len_align, ra);
    }

    fn resize(self: *Self, buf: []u8, buf_align: u29, new_len: usize, len_align: u29, ra: usize) ?usize {
        if (new_len > self.max_alloc_size) {
            std.debug.print("trying to resize to size: {}\n", .{new_len});
            @panic("allocation exceeds max alloc size");
        }
        return self.parent_allocator.rawResize(buf, buf_align, new_len, len_align, ra);
    }

    fn free(self: *Self, buf: []u8, buf_align: u29, ret_addr: usize) void {
        return self.parent_allocator.rawFree(buf, buf_align, ret_addr);
    }
};
```

which is then able to be used in the fuzzer implementation:

```language-zig
// default to 4kb minimum just in case we get very small files that need to allocate
// fairly large sizes for things like ArrayList(ID3v2Metadata)
const max_allocation_size = std.math.max(4096, data.len * 10);
var max_size_allocator = MaxSizeAllocator.init(allocator, max_allocation_size);

var metadata = try audiometa.metadata.readAll(max_size_allocator.allocator(), &stream_source);
defer metadata.deinit();
```

As you can see by the `std.math.max(4096, data.len * 10)`, this ended up needing more leeway than I initially thought it would, since it's possible for my particular library to need larger-than-filesize allocations for the storage of the parsed metadata, but it ended up allowing me to iron out all such bugs and greatly improve the worst-case performance of the library. Afterwards, the fuzzer was able to run consistently above 6000 inputs/sec on my machine, without hitting any timeouts at all.

## Fuzzing to find memory bugs after allocation failure

Zig's standard library includes a wrapping allocator called `std.testing.FailingAllocator` that takes an 'allocation index' for which it should induce failure and return `error.OutOfMemory` once the allocation index reaches the given allocation index. Because of this, it can be used to find instances of memory bugs that are only triggered by allocation failure.

Here's a contrived example of this type of bug:

```language-zig
var foo = try allocator.alloc(u8, length);
var bar = try allocator.alloc(u8, length);
```

If both allocations succeed, then there's no issue (presuming that there's something in place to free the allocated memory somewhere else in the code). However, if `foo` is successfully allocated but `bar` fails, then `foo` will be leaked since the second `allocator.alloc` call will return `error.OutOfMemory`. In this instance, the fix could be to use `errdefer` like so:

```language-zig
var foo = try allocator.alloc(u8, length);
errdefer allocator.free(foo);
var bar = try allocator.alloc(u8, length);
errdefer allocator.free(bar);
```

With this, if the allocation of `bar` fails, then the first `errdefer` would run and free `foo` before returning `error.OutOfMemory`, thus fixing the leak.

In real code, these types of bugs can sometimes be non-trivial to find. In order to find them with fuzz testing, we'd need two things:

1. A way to induce OutOfMemory errors. This is what `std.testing.FailingAllocator` provides
2. A way to determine *which* allocation should fail for a given fuzzed input. This needs to be consistent so that it's possible to reproduce any bugs that are found, but also seemingly random such that different inputs exercise different allocation failures

My solution for the second part was to:

- Hash the input data into an integer and use that as the initial FailingAllocator 'allocation index'
- Run the parser with the FailingAllocator once
- If we didn't hit OutOfMemory, then set the FailingAllocator's allocation index to `initial_allocation_index % failing_allocator.index` where `failing_allocator.index` is the allocator's final allocation index after running the parser on the input
- Try running the parser with the FailingAllocator again, knowing we must induce an OutOfMemory error this time

This allows the allocation index to be both consistent *and* seemingly random, in that the allocation index will vary a lot between different inputs, so in theory we should get decent coverage fairly quickly.

<p><aside class="update">

**Note:** While writing this, I realized that it would be possible to run the parser on the input once without the `FailingAllocator`, and then use the resulting 'maximum' allocation index as the upper bound for a loop where you test with a `FailingAllocator` on each possible allocation index (i.e. this would end up being similar to something like [FAINT](https://github.com/misc0110/faint/)). This would be *much* more comprehensive for each input, but would also come at a heavy runtime cost per-input. I'm not familiar enough with the inner-workings of fuzzing to know which strategy would get the best results.

**Update 2021-10-29**: Turns out that Zig's parser tests [use this exact strategy already](https://github.com/ziglang/zig/blob/ee038df7e2782d336e8d7cdb8619c39d85c027bb/lib/std/zig/parser_test.zig#L5306-L5351).

</aside></p>

My fuzzer's main function ended up looking something like:

```language-zig
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
// this will check for leaks at the end of the program
defer std.debug.assert(gpa.deinit() == false);
const gpa_allocator = gpa.allocator();

const stdin = std.io.getStdIn();
const data = try stdin.readToEndAlloc(gpa_allocator, std.math.maxInt(usize));
defer gpa_allocator.free(data);

// use a hash of the data as the initial failing index, this will
// almost certainly be way too large initially but we'll fix that after
// the first iteration
var failing_index: usize = std.hash.CityHash32.hash(data);
var should_have_failed = false;
while (true) : (should_have_failed = true) {
    var failing_allocator = std.testing.FailingAllocator.init(gpa_allocator, failing_index);

    // need to reset the stream_source each time to ensure that we're reading
    // from the start each iteration
    var stream_source = std.io.StreamSource{ .buffer = std.io.fixedBufferStream(data) };

    var metadata = audiometa.metadata.readAll(failing_allocator.allocator(), &stream_source) catch |err| switch (err) {
        // if we hit OutOfMemory, then we can break and check for leaks
        error.OutOfMemory => break,
        else => return err,
    };
    defer metadata.deinit();

    // if there were no allocations at all, then just break
    if (failing_allocator.index == 0) {
        break;
    }
    if (should_have_failed) {
        @panic("OutOfMemory got swallowed somewhere");
    }

    // now that we've run this input once without hitting the fail index,
    // we can treat the current index of the FailingAllocator as an upper bound
    // for the amount of allocations, and use modulo to get a random-ish but
    // predictable index that we know will fail on the second run
    failing_index = failing_index % failing_allocator.index;
}
```

<p><aside class="note">

**Note:** In reality, I further [(conditionally) wrapped](https://github.com/squeek502/audiometa/blob/a9f46daa31756acef58558b3d06a6b9864e3f570/test/fuzz-oom.zig#L32-L45) the `FailingAllocator` in a [custom `StackTraceOnErrorAllocator`](https://github.com/squeek502/audiometa/blob/a9f46daa31756acef58558b3d06a6b9864e3f570/test/fuzz-oom.zig#L69-L108) in order to dump a stack trace at the point of the induced `OutOfMemory` error to make it easier to debug the problems found.

</aside></p>

This ended up working well and found some bugs in my code. Here's an example of one of the bugs it was able to find:

```language-zig
const value_dup = try self.allocator.dupe(u8, value);

const entry_index = self.entries.items.len;
try self.entries.append(self.allocator, Entry{
    .name = indexes_entry.key_ptr.*,
    .value = value_dup,
});
try indexes_entry.value_ptr.append(self.allocator, entry_index);
```

This has the same problem as my contrived example above: if the `try self.entries.append` call fails, then `value_dup` will be leaked. I fixed that by introducing an `errdefer`:

```language-zig
const value_dup = try self.allocator.dupe(u8, value);
errdefer self.allocator.free(value_dup);

const entry_index = self.entries.items.len;
try self.entries.append(self.allocator, Entry{
    .name = indexes_entry.key_ptr.*,
    .value = value_dup,
});
try indexes_entry.value_ptr.append(self.allocator, entry_index);
```

Well, at least I *thought* I fixed it. After running the fuzzer some more, this same code started crashing due to the detection of a double free. That is, if both the `self.allocator.dupe` and the `self.entries.append` calls succeed, but the `indexes_entry.value_ptr.append` at the end fails, then the `errdefer` will run and free `value_dup`, but also `self.entries` would get cleaned up by the caller of the function that this snippet is from. This is a problem because, after the `append`, `self.entries` essentially owns the `value_dup` memory, so during its cleanup, it would try to free the memory of `value_dup` as well. To fix this, I put the `errdefer` inside a block so that it would only get run if *specifically* the `self.entries.append` call failed:

```language-zig
const entry_index = entry_index: {
    const value_dup = try self.allocator.dupe(u8, value);
    errdefer self.allocator.free(value_dup);

    const entry_index = self.entries.items.len;
    try self.entries.append(self.allocator, Entry{
        .name = indexes_entry.key_ptr.*,
        .value = value_dup,
    });
    break :entry_index entry_index;
};
try indexes_entry.value_ptr.append(self.allocator, entry_index);
```

## Wrapping up

I'm sure there are many other ways to take advantage of how easy it is to use custom allocators in Zig that would work well alongside fuzz testing. These are just two uses that I was able to come up with and that I thought were worth detailing.
