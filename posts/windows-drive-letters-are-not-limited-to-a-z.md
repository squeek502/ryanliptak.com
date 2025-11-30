On its own, the title of this post is just a true piece of trivia, verifiable with [the built-in `subst` tool](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/subst) (among other methods).

Here's an example creating the drive `+:\` as an alias for a directory at `C:\foo`:

```
subst +: C:\foo
```

The `+:\` drive then works as normal (at least in cmd.exe, this will be discussed more later):

```
> cd /D +:\

+:\> tree .
Folder PATH listing
Volume serial number is 00000001 12AB:23BC
+:\
└───bar
```

However, understanding *why* it's true elucidates a lot about how Windows works under the hood, and turns up a few curious behaviors.

## What is a drive letter, anyway?

The paths that most people are familiar with are [Win32 namespace paths](https://learn.microsoft.com/en-us/windows/win32/fileio/naming-a-file#namespaces), e.g. something like `C:\foo` which is a drive-absolute Win32 path. However, the high-level APIs that take Win32 paths like [`CreateFileW`](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-createfilew) ultimately will convert a path like `C:\foo` into a NT namespace path before calling into a lower level API within `ntdll.dll` like [`NtCreateFile`](https://learn.microsoft.com/en-us/windows/win32/api/winternl/nf-winternl-ntcreatefile).

This can be confirmed with [NtTrace](https://github.com/rogerorr/NtTrace), where a call to `CreateFileW` with `C:\foo` ultimately leads to a call of `NtCreateFile` with `\??\C:\foo`:

```
NtCreateFile( FileHandle=0x40c07ff640 [0xb8], DesiredAccess=SYNCHRONIZE|GENERIC_READ|0x80, ObjectAttributes="\??\C:\foo", IoStatusBlock=0x40c07ff648 [0/1], AllocationSize=null, FileAttributes=0, ShareAccess=7, CreateDisposition=1, CreateOptions=0x4000, EaBuffer=null, EaLength=0 ) => 0
NtClose( Handle=0xb8 ) => 0
```

<aside class="note">

Note: The relevant bit is `ObjectAttributes="\??\C:\foo"`

</aside>

<details class="box-border" style="padding: 1em;">
<summary>Test code, reproduction info</summary>

`createfilew.zig`:

```zig
const std = @import("std");
const windows = std.os.windows;
const L = std.unicode.wtf8ToWtf16LeStringLiteral;

pub extern "kernel32" fn CreateFileW(
    lpFileName: windows.LPCWSTR,
    dwDesiredAccess: windows.DWORD,
    dwShareMode: windows.DWORD,
    lpSecurityAttributes: ?*windows.SECURITY_ATTRIBUTES,
    dwCreationDisposition: windows.DWORD,
    dwFlagsAndAttributes: windows.DWORD,
    hTemplateFile: ?windows.HANDLE,
) callconv(.winapi) windows.HANDLE;

pub fn main() !void {
    const path = L("C:\\foo");
    const dir_handle = CreateFileW(
        path,
        windows.GENERIC_READ,
        windows.FILE_SHARE_DELETE | windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE,
        null,
        windows.OPEN_EXISTING,
        windows.FILE_FLAG_BACKUP_SEMANTICS | windows.FILE_FLAG_OVERLAPPED,
        null,
    );
    if (dir_handle == windows.INVALID_HANDLE_VALUE) return error.FailedToOpenDir;
    defer windows.CloseHandle(dir_handle);
}
```

Built with:

```
zig build-exe createfilew.zig
```

To run with NtTrace:

```
nttrace createfilew.exe > createfilew.log
```

</details>

That `\??\C:\foo` is a [NT namespace path](https://learn.microsoft.com/en-us/windows/win32/fileio/naming-a-file#nt-namespaces), which is what `NtCreateFile` expects. To understand this path, though, we need to talk about the Object Manager, which is responsible for handling NT paths.

### The Object Manager

<aside class="note">

Note: I'm mostly going to be paraphrasing [this excellent explanation of NT paths](https://chrisdenton.github.io/omnipath/NT.html), so make sure to read that if you want more details.

</aside>

The Object Manager is responsible for keeping track of named objects, which we can explore using [the WinObj tool](https://learn.microsoft.com/en-us/sysinternals/downloads/winobj). The `\??` part of the `\??\C:\foo` path is actually a special virtual folder within the Object Manager that combines the `\GLOBAL??` folder and a per-user `DosDevices` folder together.

For me, the object `C:` is within `\GLOBAL??`, and is actually a symbolic link to `\Device\HarddiskVolume4`:

<div style="text-align: center;">
<img style="margin-left:auto; margin-right:auto; display: block;" src="/images/windows-drive-letters-are-not-limited-to-a-z/cdrive.png">
</div>

So, `\??\C:\foo` ultimately resolves to `\Device\HarddiskVolume4\foo`, and then it's up to the actual device to deal with the `foo` part of the path.

The important thing here, though, is that `\??\C:\foo` is just *one way* of referring to the device path `\Device\HarddiskVolume4\foo`. For example, volumes will also get a named object created using their GUID with the format `Volume{18123456-abcd-efab-cdef-1234abcdabcd}` that is also a symlink to something like `\Device\HarddiskVolume4`, so a path like `\??\Volume{18123456-abcd-efab-cdef-1234abcdabcd}\foo` is effectively equivalent to `\??\C:\foo`.

<aside class="note">

Note: `\GLOBAL??` contains an object called `Global` that is itself a symlink to `\GLOBAL??`, so `\??\GLOBAL\GLOBAL\C:\foo` (and any combination thereof) also resolves to `\Device\HarddiskVolume4\foo`

</aside>

All this is to say that there's nothing innately special about the named object `C:`; the Object Manager treats it just like any other symbolic link and resolves it accordingly.

### So, what *is* a drive letter, really?

How I see it, drive letters are essentially just a convention borne out of the conversion of a Win32 path into a NT path. In particular, that would be down to the implementation of [`RtlDosPathNameToNtPathName_U`](https://learn.microsoft.com/en-us/windows/win32/devnotes/rtldospathnametontpathname_u_withstatus).

In other words, since `RtlDosPathNameToNtPathName_U` converts `C:\foo` to `\??\C:\foo`, then an object named `C:` will behave like a drive letter. To give an example of what I mean by that: in an alternate universe, `RtlDosPathNameToNtPathName_U` could convert the path `FOO:\bar` to `\??\FOO:\bar` and then `FOO:` could behave like a drive letter.

So, getting back to the title, how does `RtlDosPathNameToNtPathName_U` treat something like `+:\foo`? Well, exactly the same as `C:\foo`:

```
> paths.exe C:\foo
path type: .DriveAbsolute
  nt path: \??\C:\foo

> paths.exe +:\foo
path type: .DriveAbsolute
  nt path: \??\+:\foo
```

<details class="box-border" style="padding: 1em;">
<summary>Test program code</summary>

`paths.zig`:

```zig
const std = @import("std");
const windows = std.os.windows;

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try std.process.argsAlloc(arena);
    if (args.len <= 1) return error.ExpectedArg;

    const path = try std.unicode.wtf8ToWtf16LeAllocZ(arena, args[1]);

    const path_type = RtlDetermineDosPathNameType_U(path);
    std.debug.print("path type: {}\n", .{path_type});
    const nt_path = try RtlDosPathNameToNtPathName_U(path);
    std.debug.print("  nt path: {f}\n", .{std.unicode.fmtUtf16Le(nt_path.span())});
}

const RTL_PATH_TYPE = enum(c_int) {
    Unknown,
    UncAbsolute,
    DriveAbsolute,
    DriveRelative,
    Rooted,
    Relative,
    LocalDevice,
    RootLocalDevice,
};

pub extern "ntdll" fn RtlDetermineDosPathNameType_U(
    Path: [*:0]const u16,
) callconv(.winapi) RTL_PATH_TYPE;

fn RtlDosPathNameToNtPathName_U(path: [:0]const u16) !windows.PathSpace {
    var out: windows.UNICODE_STRING = undefined;
    const rc = windows.ntdll.RtlDosPathNameToNtPathName_U(path, &out, null, null);
    if (rc != windows.TRUE) return error.BadPathName;
    defer windows.ntdll.RtlFreeUnicodeString(&out);

    var path_space: windows.PathSpace = undefined;
    const out_path = out.Buffer.?[0 .. out.Length / 2];
    @memcpy(path_space.data[0..out_path.len], out_path);
    path_space.len = out.Length / 2;
    path_space.data[path_space.len] = 0;

    return path_space;
}
```

</details>

Therefore, if an object with the name `+:` is within the virtual folder `\??`, we can expect the Win32 path `+:\` to behave like any other drive-absolute path, which is exactly what we see.

<aside class="note">

Note: When using `subst` like in the example at the start of the post, that `+:` object is created in the per-user `DosDevices` folder mentioned earlier:

<div style="text-align: center; margin-bottom: 1rem;">
<img style="margin-left:auto; margin-right:auto; display: block;" src="/images/windows-drive-letters-are-not-limited-to-a-z/dosdevices.png">
</div>

</aside>

## Some exploration of the implications

This section only focuses on a few things that were relevant to what I was working on. I encourage others to investigate the implications of this further if they feel so inclined.

### `explorer.exe` doesn't play ball

Drives with a drive-letter other than A-Z do not appear in File Explorer, and cannot be navigated to in File Explorer.

<div style="text-align: center;">
<img style="margin-left:auto; margin-right:auto; display: block;" src="/images/windows-drive-letters-are-not-limited-to-a-z/explorer.png">
<i class="caption">Error when attempting to navigate to <code>+:\</code> in File Explorer</i>
</div>

For the "do not appear" part, my guess as to what's happening is that `explorer.exe` is walking `\??` and looking specifically for objects named `A:` through `Z:`. For the "cannot be navigated to" part, that's a bit more mysterious, but my guess is that `explorer.exe` has a lot of special logic around handling paths typed into the location bar, and part of that restricts drive letters to `A`-`Z` (i.e. it's short-circuiting before it ever tries to actually open the path).

### PowerShell doesn't, either

PowerShell seems to reject non-`A`-`Z` drives as well:

```
PS C:\> cd +:\
cd : Cannot find drive. A drive with the name '+' does not exist.
At line:1 char:1
+ cd +:\
+ ~~~~~~
    + CategoryInfo          : ObjectNotFound: (+:String) [Set-Location], DriveNotFoundException
    + FullyQualifiedErrorId : DriveNotFound,Microsoft.PowerShell.Commands.SetLocationCommand
```

### Non-ASCII drive letters

Drive letters don't have to be within the ASCII range at all; they can also be non-ASCII characters.

```
> subst €: C:\foo

> cd /D €:\

€:\> tree .
Folder PATH listing
Volume serial number is 000000DE 12AB:23BC
€:\
└───bar
```

Non-ASCII drive letters are even case-insensitive like `A`-`Z` are:

```
> subst Λ: C:\foo

> cd /D λ:\

λ:\> tree .
Folder PATH listing
Volume serial number is 000000DE 12AB:23BC
λ:\
└───bar
```

However, drive-letters cannot be *arbitrary* Unicode graphemes or even arbitrary code points; they are restricted to a single [WTF-16](https://wtf-8.codeberg.page/#motivation) code unit (a `u16`, so <= `U+FFFF`). The tool that we've been using so far (`subst.exe`) errors with `Invalid parameter` if you try to use a drive letter with a code point larger than `U+FFFF`, but you can get around that by going through the `MountPointManager` directly:

<div style="text-align: center; margin-bottom: 1rem;">
<img style="margin-left:auto; margin-right:auto; display: block;" src="/images/windows-drive-letters-are-not-limited-to-a-z/u24b62drive.png">
</div>

<details class="box-border" style="padding: 1em;">
<summary>Code used to create the <code>𤭢:</code> symlink</summary>

```zig
const std = @import("std");
const windows = std.os.windows;
const L = std.unicode.wtf8ToWtf16LeStringLiteral;

const MOUNTMGR_CREATE_POINT_INPUT = extern struct {
    SymbolicLinkNameOffset: windows.USHORT,
    SymbolicLinkNameLength: windows.USHORT,
    DeviceNameOffset: windows.USHORT,
    DeviceNameLength: windows.USHORT,
};

pub fn main() !void {
    const mgmt_handle = try windows.OpenFile(L("\\??\\MountPointManager"), .{
        .access_mask = windows.SYNCHRONIZE | windows.GENERIC_READ | windows.GENERIC_WRITE,
        .share_access = windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE | windows.FILE_SHARE_DELETE,
        .creation = windows.FILE_OPEN,
    });
    defer windows.CloseHandle(mgmt_handle);

    const volume_name = L("\\Device\\HarddiskVolume4");
    const mount_point = L("\\DosDevices\\𤭢:");

    const buf_size = @sizeOf(MOUNTMGR_CREATE_POINT_INPUT) + windows.MAX_PATH * 2 + windows.MAX_PATH * 2;
    var input_buf: [buf_size]u8 align(@alignOf(MOUNTMGR_CREATE_POINT_INPUT)) = [_]u8{0} ** buf_size;

    var input_struct: *MOUNTMGR_CREATE_POINT_INPUT = @ptrCast(&input_buf[0]);
    input_struct.SymbolicLinkNameOffset = @sizeOf(MOUNTMGR_CREATE_POINT_INPUT);
    input_struct.SymbolicLinkNameLength = mount_point.len * 2;
    input_struct.DeviceNameOffset = input_struct.SymbolicLinkNameOffset + input_struct.SymbolicLinkNameLength;
    input_struct.DeviceNameLength = volume_name.len * 2;

    @memcpy(input_buf[input_struct.SymbolicLinkNameOffset..][0..input_struct.SymbolicLinkNameLength], @as([*]const u8, @ptrCast(mount_point)));
    @memcpy(input_buf[input_struct.DeviceNameOffset..][0..input_struct.DeviceNameLength], @as([*]const u8, @ptrCast(volume_name)));

    const IOCTL_MOUNTMGR_CREATE_POINT = windows.CTL_CODE(windows.MOUNTMGRCONTROLTYPE, 0, .METHOD_BUFFERED, windows.FILE_READ_ACCESS | windows.FILE_WRITE_ACCESS);
    try windows.DeviceIoControl(mgmt_handle, IOCTL_MOUNTMGR_CREATE_POINT, &input_buf, null);
}
```

(the compiled executable must be run as administrator)

</details>

However, having the symlink in place doesn't solve anything on its own:

```
> cd /D 𤭢:\
The filename, directory name, or volume label syntax is incorrect.
```

This is because there's no way to get the drive-absolute Win32 path `𤭢:\` to end up as the relevant NT path. As mentioned earlier, the behavior of `RtlDosPathNameToNtPathName_U` is what matters, and we can verify that it will not convert a drive-absolute path with a drive letter bigger than `U+FFFF` to the relevant NT path:

```
C:\foo> paths.exe 𤭢:\foo
path type: .Relative
  nt path: \??\C:\foo\𤭢:\foo
```

<aside class="note">

Note: This behavior is actually in line with what I'd expect, as Unicode support in Windows predates [UTF-16](https://en.wikipedia.org/wiki/UTF-16), so Windows generally does not handle surrogate pairs and instead operates almost exclusively on WTF-16 code units directly.

So, when checking to see if `𤭢:\` (which is encoded in WTF-16 as `<0xD852><0xDF62><0x003A><0x005C>`) is a drive-absolute path, it will check that `path[1] == ':'` which will fail since `path[1]` is `0xDF62`.

</aside>

### Path classification mismatch

It's very common for path-related functions to be written without the use of system-specific APIs, which means that there's high potential for a mismatch between how `RtlDosPathNameToNtPathName_U` treats a file path and how something like a particular implementation of `path.isAbsolute` treats a file path.

As a random example, Rust only considers paths with `A`-`Z` drive letters as absolute:

```zig
use std::path::Path;

fn main() {
    println!("C:\\ {}", Path::new("C:\\foo").is_absolute());
    println!("+:\\ {}", Path::new("+:\\foo").is_absolute());
    println!("€:\\ {}", Path::new("€:\\foo").is_absolute());
}
```

```
> rustc test.rs

> test.exe
C:\ true
+:\ false
€:\ false
```

Whether or not this represents a problem worth fixing is left as an exercise for the reader (I genuinely don't know if it is a problem), but there's a second wrinkle (hinted at previously) involving text encoding that can make something like an `isAbsolute` implementation return different results for the same path. This wrinkle is the reason I looked into this whole thing in the first place, as when I was doing [some work on Zig's path-related functions recently](https://github.com/ziglang/zig/pull/25993) I realized that looking at `path[0]`, `path[1]`, and `path[2]` for a pattern like `C:\` will look at different parts of the path depending on the encoding. That is, for something like `€:\` (which is made up of the code points `<U+20AC><U+003A><U+005C>`):

- Encoded as WTF-16 where `U+20AC` can be encoded as the single `u16` code unit `0x20AC`, that'd mean `path[0]` will be `0x20AC`, `path[1]` will be `0x3A` (`:`), and `path[2]` will be `0x5C` (`\`), which looks like a drive-absolute path
- Encoded as [WTF-8](https://wtf-8.codeberg.page/) where `U+20AC` is encoded as three `u8` code units (`0xE2 0x82 0xAC`), that'd mean `path[0]` will be `0xE2`, `path[1]` will be `0x82`, and `path[2]` will be `0xAC`, meaning it will look nothing like a drive-absolute path

So, to write an implementation that treats paths the same regardless of encoding, [*some* decision has to be made](https://codeberg.org/ziglang/zig/src/commit/bfe3317059131ab552f7583b88d6bc82609d198c/lib/std/os/windows.zig#L2564-L2585):

- If strict compatibility with `RtlDetermineDosPathNameType_U`/`RtlDosPathNameToNtPathName_U` is desired, decode the first code point and check for `<= 0xFFFF` when dealing with WTF-8 (this is the option I went with for the Zig standard library, but I'm not super happy about it)
- If you want to be able to always check `path[0]`/`path[1]`/`path[2]` and don't care about non-ASCII drive letters, check for `path[0] <= 0x7F` regardless of encoding
- If you don't care about anything other than the standard `A`-`Z` drive letters, then check for that explicitly ([this is what Rust does](https://github.com/rust-lang/rust/blob/3ff30e7eafc1da7104c3960187d17939172428ed/library/std/src/sys/path/windows_prefix.rs#L132-L134))

### That's NOT the EURO drive

Something bizarre that I found with this whole thing is that the `kernel32.dll` API [`SetVolumeMountPointW`](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-setvolumemountpointw) has it's own unique quirk when dealing with non-ASCII drive letters. Specifically, this code (attempting to create the drive `€:\`) will succeed:

```zig
const std = @import("std");
const windows = std.os.windows;
const L = std.unicode.wtf8ToWtf16LeStringLiteral;

extern "kernel32" fn SetVolumeMountPointW(
    VolumeMountPoint: windows.LPCWSTR,
    VolumeName: windows.LPCWSTR,
) callconv(.winapi) windows.BOOL;

pub fn main() !void {
    const volume_name = L("\\\\?\\Volume{18123456-abcd-efab-cdef-1234abcdabcd}\\");
    const mount_point = L("€:\\");
    if (SetVolumeMountPointW(mount_point, volume_name) == 0) {
        const err = windows.GetLastError();
        std.debug.print("{any}\n", .{err});
        return error.Failed;
    }
}
```

However, when we look at the Object Manager, the `€:` symlink won't exist... but `¬:` will:

<div style="text-align: center; margin-bottom: 1rem;">
<img style="margin-left:auto; margin-right:auto; display: block;" src="/images/windows-drive-letters-are-not-limited-to-a-z/notdrive.png">
</div>

My time [dealing extensively with Windows quirks](https://www.ryanliptak.com/blog/every-rc-exe-bug-quirk-probably/) made me recognize what might be happening here: `0x20AC` is likely being truncated to `0xAC` by `SetVolumeMountPointW`, and `U+00AC` happens to be `¬`. If that is indeed what's going on, it seems pretty strange to truncate the drive letter instead of reject the path, but it also makes sense that non-ASCII drive letters are an edge case that no one has really thought about at all.

## Wrapping up

I have no idea if anything I wrote about here is novel, although my cursory searches didn't turn up much. The only mention of non-`A`-`Z` drive letters I'm currently aware of is from the article [The Definitive Guide on Win32 to NT Path Conversion](https://googleprojectzero.blogspot.com/2016/02/the-definitive-guide-on-win32-to-nt.html) which says:

> it's natural to assume that drive "letters" can only be A through Z. It turns out the `RtlGetFullPathName_U` API does not enforce this requirement, although the Explorer shell and command prompt almost certainly do. Therefore as long as the second character of a path is a colon, the conversion will treat it as a Drive Absolute or Drive Relative path. Of course if the DosDevices object directory doesn't have an appropriate symbolic link it's not going to do you much good.

Well, it turns out that the command prompt also doesn't enforce the requirement, and I'd guess that there's at least some more weirdness around this quirk that's waiting to be discovered.
