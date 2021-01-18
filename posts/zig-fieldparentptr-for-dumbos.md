Zig's [current 'interface' pattern](https://www.nmichaels.org/zig/interfaces.html) relies on a builtin called `@fieldParentPtr`, which is described in [the Zig documentation](https://ziglang.org/documentation/0.7.1/#fieldParentPtr) like so:

> ```language-zig
> @fieldParentPtr(comptime ParentType: type, comptime field_name: []const u8, field_ptr: *T) *ParentType
> ```
>
> Given a pointer to a field, returns the base pointer of a struct.

For whatever reason, I had a hard time grasping what this actually meant, so I tried to implement the same functionality without the builtin, which finally helped me understand it:

```language-zig
const instance = Struct{};
// Get a pointer to the field of an instance of Struct
const field_ptr = &instance.field;
// Convert the pointer to an integer so that we can manipulate it
const field_ptr_int = @ptrToInt(field_ptr);
// Get the byte offset of the field from the start of its struct
const field_offset = @byteOffsetOf(Struct, "field");
// Subtract the offset to get a pointer to the start of the 'parent' struct
const parent_ptr_int = field_ptr_int - field_offset;
// Convert the integer to a pointer to the 'parent' struct
const parent_ptr = @intToPtr(*Struct, parent_ptr_int);

std.debug.assert(parent_ptr == &instance);
```

That is, given a pointer to a field, `@fieldParentPtr` will coerce it into a pointer to its containing struct, provided that you are able to give it both the correct type for the containing struct and the correct name of the field (if either of those are wrong, you're just going to end up with a pointer to random memory).

---

Here's a more complete test file:

```language-zig
const std = @import("std");

pub const Struct = struct {
    foo: u32 = 0,
    field: u32 = 1,
};

pub fn main() !void {
    var a = Struct{};
    const from_builtin: *Struct = @fieldParentPtr(Struct, "field", &a.field);
    const from_function: *Struct = myFieldParentPtr(Struct, "field", &a.field);

    std.debug.assert(&a == from_builtin);
    std.debug.assert(from_builtin == from_function);
    std.debug.print("{*} == {*}\n", .{ from_builtin, from_function });
}

fn myFieldParentPtr(comptime ParentType: type, comptime field_name: []const u8, field_ptr: anytype) *ParentType {
    comptime std.debug.assert(@typeInfo(@TypeOf(field_ptr)) == .Pointer);

    const field_ptr_int = @ptrToInt(field_ptr);
    const field_offset = @byteOffsetOf(ParentType, field_name);
    const parent_ptr_int = field_ptr_int - field_offset;
    return @intToPtr(*ParentType, parent_ptr_int);
}
```
