Inspired by an [accepted proposal](https://github.com/ziglang/zig/issues/3702) for [Zig](https://ziglang.org/) to include support for compiling Windows resource script (`.rc`) files, I set out on what I thought at the time would be a somewhat straightforward side-project of writing a Windows resource compiler in Zig. I figured that, since there are multiple existing open source projects with similar goals (`windres`, `llvm-rc`--both are cross-platform Windows resource compilers), I could use them as a reference, and that the syntax of `.rc` files didn't look too complicated.

**I was wrong on both counts.**

While the `.rc` syntax *in theory* is not complicated, there are edge cases hiding around every corner, and each of the existing alternative Windows resource compilers handle each edge case very differently from the canonical Microsoft implementation.

With a goal of byte-for-byte-identical-outputs (and possible bug-for-bug compatibility) for my implementation, I had to effectively start from scratch, as even [the Windows documentation couldn't be fully trusted to be accurate](https://github.com/MicrosoftDocs/win32/pulls?q=is%3Apr+author%3Asqueek502). Ultimately, I went with fuzz testing (with `rc.exe` as the source of truth/oracle) as my method of choice for deciphering the behavior of the Windows resource compiler (this is similar to something I did [with Lua](https://www.ryanliptak.com/blog/fuzzing-as-test-case-generator/) a while back).

This process led to two things:

- A high degree of compatibility with the `rc.exe` implementation, including [byte-for-byte identical outputs](https://github.com/squeek502/win32-samples-rc-tests/) for a large corpus of Microsoft-provided sample `.rc` files (~500 files)
- A large list of strange/interesting/baffling behaviors of the Windows resource compiler

My resource compiler implementation, [`resinator`](https://github.com/squeek502/resinator), has now reached relative maturity and has [been merged into the Zig compiler](https://www.ryanliptak.com/blog/zig-is-a-windows-resource-compiler/), so I thought it might be interesting to write about all the weird stuff I found along the way.

<p><aside class="note">

Note: While this list is thorough, it is only indicative of my current understanding of `rc.exe`, which can always be incorrect. Even in the process of writing this article, I found new edge cases and [had to correct my implementation of certain aspects of the compiler](https://github.com/squeek502/resinator/commit/fda2c685e5f59b79816bb0e7186d24b93a8c77b9).

</aside></p>

## Who is this for?

- If you work at Microsoft, consider this a large list of bug reports (in particular, see everything labeled 'miscompilation')
  + If you're [Raymond Chen](https://devblogs.microsoft.com/oldnewthing/author/oldnewthing), then consider this an extension/homage to all the (great, very helpful) blog posts about Windows resources in [The Old New Thing](https://devblogs.microsoft.com/oldnewthing/)
- If you are a contributor to `llvm-rc`, `windres`, or `wrc`, consider this a long list of behaviors to test for (if strict compatibility is a goal)
- If you are none of the above, consider this an entertaining list of bizarre bugs/edge cases

If you have no familiarity with `.rc` files at all, no need to worry--I have tried to organize this post in order to get you up to speed as-you-read. However, if you'd instead like to skip around and check out the strangest bugs/quirks, `Ctrl+F` for 'utterly baffling'.

## A brief intro to resource compilers

`.rc` files (resource definition-script files) are scripts that contain both C/C++ preprocessor commands and resource definitions. We'll ignore the preprocessor for now and focus on resource definitions. One possible resource definition might look like this:

```c
    1    FOO  { "bar" }
// <id> <type> <data>
```

The `1` is the ID of the resource, which can be a number (ordinal) or literal (name). The `FOO` is the type of the resource, and in this case it's a user-defined type with the name `FOO`. The `{ "bar" }` is a block that contains the data of the resource, which in this case is the string literal `"bar"`. Not all resource definitions look exactly like this, but the `<id> <type>` part is fairly common.

Resource compilers take `.rc` files and compile them into binary `.res` files:

<div style="text-align: center; display: grid; grid-gap: 10px; grid-template-columns: repeat(auto-fit, minmax(400px, 1fr));">
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
  <pre style="display: flex; flex-direction: column; justify-content: center; align-items: center; flex-grow: 1; margin-top: 0;">
    <code class="language-none"><span style="outline: 2px solid green">1</span> <span style="outline: 2px solid blue;">RCDATA</span> { <span style="outline: 2px solid red">"abc"</span> }</code>
  </pre>
</div>
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
  <pre style="display: flex; flex-direction: column; justify-content: center; align-items: center; flex-grow: 1; margin-top: 0;">
    <code class="language-none">00 00 00 00 20 00 00 00  .... ...
FF FF 00 00 FF FF 00 00  ........
00 00 00 00 00 00 00 00  ........
00 00 00 00 00 00 00 00  ........
03 00 00 00 20 00 00 00  .... ...
FF FF <span style="outline: 2px solid blue; position:relative; display:inline-block;">0A 00<span class="hexdump-tooltip rcdata">The predefined RCDATA<br/>resource type has ID 0x0A<i></i></span></span> FF FF <span style="outline: 2px solid green;">01 00</span>  ..<span style="outline: 2px solid blue;">..</span>..<span style="outline: 2px solid green;">..</span>
00 00 00 00 30 00 09 04  ....0...
00 00 00 00 00 00 00 00  ........
<span style="outline: 2px solid red;">61 62 63</span> 00              <span style="outline: 2px solid red;">abc</span>.</code>
  </pre>
</div>
</div>
<p style="margin:0; text-align: center;"><i class="caption">A simple <code>.rc</code> file and a hexdump of the relevant part of the resulting <code>.res</code> file</i></p>

The `.res` file can then be handed off to the linker in order to include the resources in the resource table of a PE/COFF binary (`.exe`/`.dll`). The resources in the PE/COFF binary can be used for various things, like:

- Executable icons that show up in Explorer
- Version information that integrates with the Properties window
- Defining dialogs/menus that can be loaded at runtime
- Localization strings
- Embedding arbitrary data
- [etc.](https://learn.microsoft.com/en-us/windows/win32/menurc/resource-definition-statements)

<div style="text-align: center;">
<img style="margin-left:auto; margin-right:auto; display: block;" src="/images/every-rc-exe-bug-quirk-probably/zig-ico.png">
<i class="caption">Both the executable's icon and the version information in the Properties window come from a compiled <code>.rc</code> file</i>
</div>

So, in general, a resource is a blob of data that can be referenced by an ID, plus a type that determines how that data should be interpreted. The resource(s) are embedded into compiled binaries (`.exe`/`.dll`) and can then be loaded at runtime, and/or can be loaded by the operating system for certain Windows-specific integrations.

With that out of the way, we're ready to get into it.

## The list of bugs/quirks

<div class="bug-quirk-box">
<span class="bug-quirk-category">tokenizer quirk</span>

### Special tokenization rules for names/IDs

Here's a resource definition with a user-defined type (i.e. not one of the [predefined resource types](https://learn.microsoft.com/en-us/windows/win32/menurc/resource-definition-statements#resources)) of `FOO`:

```c
1 FOO { "bar" }
```

For user-defined types, the (uppercased) resource type name is written as UTF-16 into the resulting `.res` file, so in this case `FOO` is written as the type of the resource, and the bytes of the string `bar` are written as the resource's data.

So, following from this, let's try wrapping the resource type name in double quotes:

```c
1 "FOO" { "bar" }
```

Intuitively, you might expect that this doesn't change anything (i.e. it'll still get parsed into `FOO`), but in fact the Windows RC compiler will now include the quotes in the user-defined type name. That is, `"FOO"` will be written as the resource type name in the `.res` file, not `FOO`.

This is because both resource IDs and resource types use special tokenization rules--they are basically only terminated by whitespace and nothing else (well, not exactly whitespace, it's actually any ASCII character from `0x05` to `0x20` [inclusive]). As an example:

```c
L"\r\n"123abc error{OutOfMemory}!?u8 { "bar" }
```

<p><aside class="note">Reminder: Resource IDs don't have to be integers</aside></p>

In this case, the ID would be `L"\R\N"123ABC` (uppercased) and the resource type would be `ERROR{OUTOFMEMORY}!?U8` (again, uppercased).

---

I've started with this particular quirk because it is actually demonstrative of the level of `rc.exe`-compatibility of the existing cross-platform resource compiler projects:

- [`windres`](https://ftp.gnu.org/old-gnu/Manuals/binutils-2.12/html_node/binutils_14.html) parses the `"FOO"` resource type as a regular string literal and the resource type name ends up as `FOO` (without the quotes)
- [`llvm-rc`](https://github.com/llvm/llvm-project/tree/56b3222b79632a4bbb36271735556a03b2504791/llvm/tools/llvm-rc) errors with `expected int or identifier, got "FOO"`
- [`wrc`](https://www.winehq.org/docs/wrc) also errors with `syntax error`

<p><aside class="note">

Note: This is the last time I'll be mentioning the behaviors of `windres`/`llvm-rc`/`wrc`, as this simple example is indicative of how much their implementations diverge from `rc.exe` for edge cases. See [win32-samples-rc-tests](https://github.com/squeek502/win32-samples-rc-tests/) for a rough approximation of the (strict) compatibility of the different Windows resource compilers on a more-or-less real-world set of `.rc` files.

From here on out, I'll only be mentioning the behavior of [`resinator`](https://github.com/squeek502/resinator), the resource compiler implementation that was the impetus for the findings in this article.

</aside></p>

#### [`resinator`](https://github.com/squeek502/resinator)'s behavior

`resinator` matches the behavior of `rc.exe` in all known cases.

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">parser bug/quirk</span>

### Non-ASCII digits in number literals

The Windows RC compiler allows non-ASCII digit codepoints within number literals, but the resulting numeric value is arbitrary.

For ASCII digit characters, the standard procedure for calculating the numeric value of an integer literal is the following:

- For each digit, subtract the ASCII value of the zero character (`'0'`) from the ASCII value of the digit to get the numeric value of the digit
- Multiply the numeric value of the digit by the relevant multiple of 10, depending on the place value of the digit
- Sum the result of all the digits

For example, for the integer literal `123`:

<div style="display: grid; grid-gap: 10px; grid-template-columns: repeat(3, 1fr);">
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```language-c style="display: flex; flex-grow: 1; justify-content: center; align-items: center; margin: 0;"
123
```

</div>
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```language-c style="display: flex; flex-grow: 1; justify-content: center; align-items: center; margin: 0;"
'1' - '0' = 1
'2' - '0' = 2
'3' - '0' = 3
```

</div>
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```language-c style="display: flex; flex-grow: 1; justify-content: center; align-items: center; margin: 0;"
 1 * 100 = 100
  2 * 10 =  20
   3 * 1 =   3
⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯
           123
```

</div>
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;"><i class="caption">integer literal</i></div>
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;"><i class="caption">numeric value of each digit</i></div>
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;"><i class="caption">numeric value of the integer literal</i></div>
</div>

So, how about the integer literal `1²3`? The Windows RC compiler accepts it, but the resulting numeric value ends up being 1403.

The problem is that the exact same procedure outlined above is erroneously followed for *all* allowed digit values, so things go haywire for non-ASCII digits since the relationship between the non-ASCII digit's codepoint value and the value of `'0'` is arbitrary:

<div style="display: grid; grid-gap: 10px; grid-template-columns: repeat(3, 1fr);">
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```language-c style="display: flex; flex-grow: 1; justify-content: center; align-items: center; margin: 0;"
1²3
```

</div>
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```language-c style="display: flex; flex-grow: 1; justify-content: center; align-items: center; margin: 0;"
'²' - '0' = 130
```

</div>
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```language-c style="display: flex; flex-grow: 1; justify-content: center; align-items: center; margin: 0;"
 1 * 100 =  100
130 * 10 = 1300
   3 * 1 =    3
⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯
           1403
```

</div>
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;"><i class="caption">integer literal</i></div>
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;"><i class="caption">numeric value of the ² digit</i></div>
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;"><i class="caption">numeric value of the integer literal</i></div>
</div>

This particular bug/quirk is (presumably) due to the use of the [`iswdigit`](https://learn.microsoft.com/en-us/cpp/c-runtime-library/reference/isdigit-iswdigit-isdigit-l-iswdigit-l) function, and the [same sort of bug/quirk exists with special `COM[1-9]` device names](https://googleprojectzero.blogspot.com/2016/02/the-definitive-guide-on-win32-to-nt.html).

#### `resinator`'s behavior

```language-resinatorerror
test.rc:2:3: error: non-ASCII digit characters are not allowed in number literals
 1²3
 ^~~
```

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">parser bug/quirk</span>

### `BEGIN` or `{` as filename

Many resource types can get their data from a file, in which case their resource definition will look something like:

```c
1 ICON "file.ico"
```

Additionally, some resource types (like `ICON`) *must* get their data from a file. When attempting to define an `ICON` resource with a raw data block like so:

```c
1 ICON BEGIN "foo" END
```

<p><aside class="note">

Note: `BEGIN` and `END` are equivalent to `{` and `}` for opening/closing blocks

</aside></p>

and then trying to compile that `ICON`, `rc.exe` has a confusing error:

```
test.rc(1) : error RC2135 : file not found: BEGIN

test.rc(2) : error RC2135 : file not found: END
```

That is, the Windows RC compiler will try to interpret `BEGIN` as a filename, which is extremely likely to fail and (if it succeeds) is almost certainly not what the user intended. It will then move on and continue trying to parse the file as if the first resource definition is `1 ICON BEGIN` and almost certainly hit more errors, since everything afterwards will be misinterpreted just as badly.

This is even worse when using `{` and `}` to open/close the block, as it triggers a separate bug:

```c
1 ICON { "foo" }
```

```
test.rc(1) : error RC2135 : file not found: ICON

test.rc(2) : error RC2135 : file not found: }
```

Somehow, the filename `{` causes `rc.exe` to think the filename token is actually the preceding token, so it's trying to interpret `ICON` as both the resource type *and* the file path of the resource. Who knows what's going on there.

#### `resinator`'s behavior

In `resinator`, trying to use a raw data block with resource types that don't support raw data is an error, noting that if `{` or `BEGIN` is intended as a filename, it should use a quoted string literal.

```language-resinatorerror
test.rc:1:8: error: expected '<filename>', found 'BEGIN' (resource type 'icon' can't use raw data)
1 ICON BEGIN
       ^~~~~
test.rc:1:8: note: if 'BEGIN' is intended to be a filename, it must be specified as a quoted string literal
```

<p><aside class="note">

Note: `windres` takes a different approach and removes this restriction around raw data blocks entirely (i.e. it allows them to be used with any resource type). This is something `resinator` may support in the future, since it doesn't necessarily break compatibility and seems like it opens up a few potential use-cases (for example, `windres` supports `.res` -> `.rc` conversion where the binary data of each resource is written to the `.rc` file via raw data blocks).

</aside></p>

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">parser bug/quirk</span>

### Number expressions as filenames

There are multiple valid ways to specify the filename of a resource:

```c
// Quoted string, reads from the file: bar.txt
1 FOO "bar.txt"

// Unquoted literal, reads from the file: bar.txt
2 FOO bar.txt

// Number literal, reads from the file: 123
3 FOO 123
```

But that's not all, as you can also specify the filename as an arbitrarily complex number expression, like so:

```c
1 FOO (1 | 2)+(2-1 & 0xFF)
```

The entire `(1 | 2)+(2-1 & 0xFF)` expression, spaces and all, is interpreted as the filename of the resource. Want to take a guess as to which file path it tries to read the data from?

Yes, that's right, `0xFF`!

For whatever reason, `rc.exe` will just take the last number literal in the expression and try to read from a file with that name, e.g. `(1+1)` will try to read from the path `1`, and `1+-1` will try to read from the path `-1` (the `-` sign is part of the number literal token in this case).

#### `resinator`'s behavior

In `resinator`, trying to use a number expression as a filename is an error, noting that a quoted string literal should be used instead. Singular number literals are allowed, though (e.g. `-1`).

```language-resinatorerror
test.rc:1:7: error: filename cannot be specified using a number expression, consider using a quoted string instead
1 FOO (1 | 2)+(2-1 & 0xFF)
      ^~~~~~~~~~~~~~~~~~~~
test.rc:1:7: note: the Win32 RC compiler would evaluate this number expression as the filename '0xFF'
```

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">fundamental concept</span>

### The Windows RC compiler 'speaks' UTF-16

`.rc` files are compiled in two distinct steps:

1. First, they are run through a C/C++ preprocessor (`rc.exe` has a preprocessor implementation built-in)
2. The result of the preprocessing step is then compiled into a `.res` file

In addition to [a subset of the normal C/C++ preprocessor directives](https://learn.microsoft.com/en-us/windows/win32/menurc/preprocessor-directives), there is one resource-compiler-specific [`#pragma code_page` directive](https://learn.microsoft.com/en-us/windows/win32/menurc/pragma-directives) that allows changing which code page is active mid-file. This means that `.rc` files can *have a mixture of encodings* within a single file:

```c
#pragma code_page(1252) // 1252 = Windows-1252
1 RCDATA { "This is interpreted as Windows-1252: €" }

#pragma code_page(65001) // 65001 = UTF-8
2 RCDATA { "This is interpreted as UTF-8: €" }
```

If the above example file is saved as [Windows-1252](https://en.wikipedia.org/wiki/Windows-1252), each `€` is encoded as the byte `0x80`, meaning:
- The `€` (`0x80`) in the `RCDATA` with ID `1` will be interpreted as a `€`
- The `€` (`0x80`) in the `RCDATA` with ID `2` will attempt to be interpreted as UTF-8, but `0x80` is an invalid start byte for a UTF-8 sequence, so it will be replaced during preprocessing with the Unicode replacement character (� or `U+FFFD`)

So, if we run the Windows-1252-encoded file through only the `rc.exe` preprocessor (using the undocumented `rc.exe /p` option), the result is a file with the following contents:

```c
#pragma code_page 1252
1 RCDATA { "This is interpreted as Windows-1252: €" }

#pragma code_page 65001
2 RCDATA { "This is interpreted as UTF-8: �" }
```

<p><aside class="note">

Note: In reality, the preprocessor also adds `#line` directives, but those have been omitted for clarity.

</aside></p>

If, instead, the example file is saved as [UTF-8](https://en.wikipedia.org/wiki/UTF-8), each `€` is encoded as the byte sequence `0xE2 0x82 0xAC`, meaning:
- The `€` (`0xE2 0x82 0xAC`) in the `RCDATA` with ID `1` will be interpreted as `â‚¬`
- The `€` (`0xE2 0x82 0xAC`) in the `RCDATA` with ID `2` will be interpreted as `€`

So, if we run the UTF-8-encoded version through the `rc.exe` preprocessor, the result looks like this:

```c
#pragma code_page 1252
1 RCDATA { "This is interpreted as Windows-1252: â‚¬" }

#pragma code_page 65001
2 RCDATA { "This is interpreted as UTF-8: €" }
```

In both of these examples, the result of the `rc.exe` preprocessor is encoded as UTF-16. This is because, in the Windows RC compiler, the relevant code page interpretation is done during preprocessing, and the output of the preprocessor is *always* UTF-16. This, in turn, means that the parser/compiler of the Windows RC compiler *always* ingests UTF-16, as there's no option to skip the preprocessing step.

This will be relevant for future bugs/quirks, so just file this knowledge away for now.

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">fundamental concept</span>

### The entirely undocumented concept of the 'output' code page

As mentioned in [*The Windows RC compiler 'speaks' UTF-16*](#the-windows-rc-compiler-speaks-utf-16), there are `#pragma code_page` preprocessor directives that can modify how each line of the input `.rc` file is interpreted. Additionally, the default code page for a file can also be set via the CLI `/c` option, e.g. `/c65001` to set the default code page to UTF-8.

What was not mentioned, however, is that the code page affects both how the input is interpreted *and* how the output is encoded. Take the following example:

```c
1 RCDATA { "Ó" }
```

<p><aside class="note">

Note: `Ó` is encoded in [Windows-1252](https://en.wikipedia.org/wiki/Windows-1252) as the byte `0xD3`

</aside></p>

When saved as Windows-1252 (the default code page for the Windows RC compiler), the `0xD3` byte in the string will be interpreted as `Ó` and written to the `.res` as its Windows-1252 representation (`0xD3`).

If the same Windows-1252-encoded file is compiled with the default code page set to UTF-8 (`rc.exe /c65001`), then the `0xD3` byte in the `.rc` file will be an invalid UTF-8 byte sequence and get replaced with � during preprocessing, and because the code page is UTF-8, the *output* in the `.res` file will also be encoded as UTF-8, so the bytes `0xEF 0xBF 0xBD` (the UTF-8 sequence for �) will be written.

Things start to get truly bizarre when you add `#pragma code_page` into the mix:

```c
#pragma code_page(1252)
1 RCDATA { "Ó" }
```

When saved as Windows-1252 and compiled with Windows-1252 as the default code page, this will work the same as described above. However, if we compile the same Windows-1252-encoded `.rc` file with the default code page set to UTF-8 (`rc.exe /c65001`), we see something rather strange:

- The input `0xD3` byte is interpreted as `Ó`, as expected since the `#pragma code_page` changed the code page to 1252
- The output in the `.res` is `0xC3 0x93`, the UTF-8 sequence for `Ó`

That is, the `#pragma code_page` changed the *input* code page, but there is a distinct *output* code page that can be out-of-sync with the input code page. In this instance, the input code page for the `1 RCDATA ...` line is Windows-1252, but the output code page is still the default set from the CLI option (in this case, UTF-8).

Even more bizarre, this disjointedness can only occur via the first `#pragma code_page` directive of the file:

```c
#pragma code_page(65001) // which code page this is doesn't matter, it can be anything valid
#pragma code_page(1252)
1 RCDATA { "Ó" }
```

With this, still saved as Windows-1252, the code page from the CLI option no longer matters--even when compiled with `/c65001`, the `0xD3` in the file is both interpreted as Windows-1252 (`Ó`) *and* outputted as Windows-1252 (`0xD3`).

In other words, this is how things seem to work:

- The CLI `/c` option sets both the input and output code pages
- The first `#pragma code_page` in the file *only* sets the input code page, and does not modify the output code page
- Any other `#pragma code_page` directives set *both* the input and output code pages

This behavior is baffling and I've not seen it mentioned anywhere on the internet at any point in time. Even the concept of the code page affecting the encoding of the output is fully undocumented as far as I can tell.

<p><aside class="note">

Note: This behavior does not generally impact wide string literals, e.g. `L"Ó"` is affected by the input code page, but is written to the `.res` file as its UTF-16 LE representation so the output code page is not relevant.

</aside></p>

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">parser bug/quirk</span>

### Non-ASCII accelerator characters

The Windows RC compiler's error hints that this is the intended behavior (`control character out of range [^A - ^Z]`), but it actually allows for a large number of codepoints >= 0x80 to be used. Of those allowed, it treats them as if they were `A-Z` and subtracts `0x40` from the codepoint to convert it to a 'control character', but for arbitrary non-ASCII codepoints that just leads to garbage. The codepoints that are allowed may be based on some sort of Unicode-aware 'is character' function or something, but I couldn't really find a pattern to it. The full list of codepoints that trigger the error can be found [here](https://gist.github.com/squeek502/2e9d0a4728a83eed074ad9785a209fd0).

> In `resinator`, control characters specified as a quoted string with a `^` in an `ACCELERATORS` resource (e.g. `"^C"`) must be in the range of `A-Z` (case insensitive).

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">parser bug/quirk</span>

### FONT parameter inheritance

The `weight` and `italic` parameters of a `FONT` statement get carried over to subsequent `FONT` statements attached to a `DIALOGEX` resource if the subsequent `FONT` statements don't provide those parameters, but `charset` doesn't (it will always have a default of `1` (`DEFAULT_CHARSET`) if not specified).

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">parser bug/quirk</span>

### Escaping quotes

The Windows RC compiler is super permissive in what input it will accept, but in this case it is overly so. For example, if you have `1 RCDATA { "\""BLAH" }` with `#define BLAH 2` elsewhere in the file:

- A preprocessor would treat the `\"` as an escaped quote and parse the part after the `{` as: `"\""`, `BLAH`, `" }`; it would then replace `BLAH` with `2` since it thinks it's outside of a string literal (note: the preprocessor would also normally result in a `missing terminating '"' character` warning since the `" }` string is never closed; in the Windows RC compiler this warning is either not emitted or not shown to the user).
- The RC compiler would then get the resulting `1 RCDATA { "\""2" }` and parse the part after the `{` as: `"\""2"`, `}`, since in `.rc` string literals, `""` is an escaped quote, not `\"`. In the Windows RC compiler, `\"` is a weird special case in which it both treats the `\` as an escape character (in that it doesn't appear in the parsed string), but doesn't actually escape the `"` (note that other invalid escapes like e.g. `\k` end up with both the `\` and `k` in the parsed string).

The fact that `\"` makes it possible for macro expansion to silently happen within what the RC compiler thinks are string literals is enough of a footgun that it makes sense to make it an error instead. Note also that it can lead to really bizarre edge cases/compile errors when, for example, particular control characters follow a `\""` sequence in a string literal.

> In `resinator`, the sequence `\"` within a string literal is an error, noting that `""` should be used to escape quotes within string literals.

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">codepoint handling</span>

### U+0000 Null

The Windows RC compiler behaves very strangely when embedded `NUL` characters are in a `.rc` file. For example, `1 RCDATA { "a<0x00>" }` will give the error "unexpected end of file in string literal", but `1 RCDATA { "<0x00>" }` will "successfully" compile and result in an empty `.res` file (the `RCDATA` resource won't be included at all). Even stranger, whitespace seems to matter in terms of when it will error; if you add a space to the beginning of the `1 RCDATA { "a<0x00>" }` version then it "successfully" compiles but also results in an empty `.res`.

> In `resinator`, embedded `NUL` (`<0x00>`) characters are always illegal anywhere in a `.rc` file.

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">codepoint handling</span>

### U+0004 End of Transmission

The Windows RC compiler seemingly treats 'End of Transmission' (`<0x04>`) characters outside of string literals as a 'skip the next character' instruction when parsing, i.e. `RCDATA<0x04>x` gets parsed as if it were `RCDATA`.

  TODO: Example/expand on this

> In `resinator`, embedded 'End of Transmission' (`<0x04>`) characters are always illegal outside of string literals.

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">codepoint handling</span>

### U+007F Delete

The Windows RC compiler seemingly treats `<0x7F>` characters as a terminator in some capacity. A few examples:
    - `1 RC<0x7F>DATA {}` gets parsed as `1 RC DATA {}`
    - `<0x7F>1 RCDATA {}` "succeeds" but results in an empty `.res` file (no RCDATA resource)
    - `1 RCDATA { "<0x7F>" }` fails with `unexpected end of file in string literal`

> In `resinator`, embedded 'Delete' (`<0x7F>`) characters are always illegal anywhere in a `.rc` file.

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">codepoint handling</span>

### U+001A Substitute

The Windows RC compiler treats `<0x1A>` characters as an 'end of file' maker but it can also lead to (presumed) infinite loops. For example, `1 MENUEX FIXED<0x1A>VERSION` will cause the Win32 implementation to hang, but `1 RCDATA {} <0x1A> 2 RCDATA {}` will succeed but only the `1 RCDATA {}` resource will make it into the `.res`.

> In `resinator`, embedded 'Substitute' (`<0x1A>`) characters are always illegal anywhere in a `.rc` file. Note: The preprocessor treats it as an 'end of file' marker so instead of getting an error it will likely end up as an EOF error. This would change if `resinator` uses a custom preprocessor.

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">codepoint handling</span>

### U+FEFF Byte Order Mark

For the most part, the Windows RC compiler skips over byte order marks (BOM) everywhere, even within string literals, within names, etc [e.g. `RC<U+FEFF>DATA` will compile as if it were `RCDATA`]). However, there are edge cases where a BOM will cause cryptic 'compiler limit : macro definition too big' errors (e.g. `1<U+FEFF>1` as a number literal).

> In `resinator`, the byte order mark (`<U+FEFF>`) is always illegal anywhere in a `.rc` file except the very start.

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">codepoint handling</span>

### U+E000 Private Use Character

This behaves similarly to the byte order mark (it gets skipped/ignored wherever it is), so the same reasoning applies (although `<U+E000>` seems to avoid causing errors like the BOM does).

> In `resinator`, the private use character `<U+E000>` is always illegal anywhere in a `.rc` file.

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">codepoint handling</span>

### U+0900, U+0A00, U+0A0D, U+2000, U+FFFE, U+0D00

The Windows RC compiler will error and/or ignore these codepoints when used outside of string literals, but not always. When used within string literals, the Windows RC compiler will miscompile them (either swap the bytes of the UTF-16 code unit in the `.res`, omit it altogether, or some other strange interaction).

See [Certain codepoints get miscompiled when in string literals](#certain-codepoints-get-miscompiled-when-in-string-literals) for more information about the miscompilation.

> In `resinator`, the codepoints `U+0900`, `U+0A00`, `U+0A0D`, `U+2000`, `U+FFFE`, and `U+0D00` are illegal outside of string literals, and emit a warning if used inside string literals

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">miscompilation</span>

### `STRINGTABLE` semantics bypass

The Windows RC compiler allows the number `6` (i.e. `RT_STRING`) to be specified as a resource type. When this happens, the Windows RC compiler will output a `.res` file with a resource that has the format of a user-defined resource, but with the type `RT_STRING`. The resulting `.res` file is basically always invalid/bogus/unreadable, as `STRINGTABLE`/`RT_STRING` has [a very particular format](https://devblogs.microsoft.com/oldnewthing/20040130-00/?p=40813).

> In `resinator`, using the number `6` as a resource type is an error and will fail to compile.

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">miscompilation</span>

### 'Extra data' in `DIALOG` resources is useless at best

The Windows RC compiler will erroneously add too many padding bytes after the 'extra data' section of a DIALOG control if the data ends on an odd offset. This is a miscompilation that results in the subsequent dialog control not to be DWORD aligned, and will likely cause the dialog to be unusable (due to parse errors during dialog initialization at program runtime).

- As far as I can tell, there is no actual use-case for this extra data on controls in a templated DIALOG, as [the docs](https://learn.microsoft.com/en-us/windows/win32/menurc/common-control-parameters) say that "When a dialog is created, and a control in that dialog which has control-specific data is created, a pointer to that data is passed into the control's window procedure through the lParam of the WM_CREATE message for that control", but `WM_CREATE` is not sent for dialogs (instead only `WM_INITDIALOG` is sent after all of the controls have been created).

> `resinator` will avoid a miscompilation regarding padding bytes after 'extra data' in DIALOG controls, and will emit a warning when it detects that the Windows RC compiler would miscompile

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">miscompilation</span>

### `CONTROL` class specified as a number

The Windows RC compiler will incorrectly encode control classes specified as numbers, seemingly using some behavior that might be left over from the 16-bit RC compiler. As far as I can tell, it will always output an unusable dialog template if a CONTROL's class is specified as a number.

> `resinator` will avoid a miscompilation when a generic CONTROL has its control class specified as a number, and will emit a warning

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">miscompilation, utterly baffling</span>

### Certain codepoints get miscompiled when in string literals

The codepoints `U+0900`, `U+0A00`, `U+0A0D`, `U+2000`, and `U+FFFE` will get compiled with their bytes swapped (i.e. they will be written as big endian even though every other codepoint is written as little endian). Since `U+FFFE` is the byteswapped version of `U+FEFF` (the byte order mark), I'm assuming that might have something to do with that particular quirk, but the others I don't have an explanation for.

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">miscompilation</span>

### Mismatch in length units in `VERSIONINFO` nodes

The data length of a `VERSIONNODE` for strings is counted in UTF-16 code units instead of bytes. This can get especially weird if numbers and strings are intermixed within a `VERSIONNODE`'s data, e.g. `VALUE "key", 1, 2, "ab"` will end up reporting a data length of 7 (2 for each number, 1 for each UTF-16 character, and 1 for the null-terminator of the "ab" string), but the real (as written to the `.res`) length of the data in bytes is 10 (2 for each number, 2 for each UTF-16 character, and 2 for the null-terminator of the "ab" string). This is detailed in [this The Old New Thing post](https://devblogs.microsoft.com/oldnewthing/20061222-00/?p=28623).

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">utterly baffling</span>

### Certain `DLGINCLUDE` filenames break the preprocessor

The following script, when encoded as Windows-1252, will cause the `rc.exe` preprocessor to freak out and output what seems to be garbage. 

```c
1 DLGINCLUDE "\001ýA\001\001\x1aý\xFF"
```

<p><aside class="note">

Note: Certain things about the input can be changed and the bug still reproduces (e.g. the values of the octal escape sequences), but some seemingly innocuous changes can stop the bug from reproducing, like changing the case of the `\x1a` escape sequence to `\x1A`.

</aside></p>

```shellsession
> rc.exe /p test.rc

Preprocessed file created in: test.rcpp
```

In this particular case, it outputs mostly Chinese characters. `test.rcpp` looks like this (note: the `rc.exe` preprocessor outputs UTF-16):

```c
#line 1 "C:\\Users\\Ryan\\Programming\\Zig\\resinator\\tmp\\RCa18588"
#line 1 "test.rc"
#line 1 "test.rc"
‱䱄䥇䍎啌䕄∠ぜ㄰䇽ぜ㄰ぜ㄰硜愱峽䙸≆
```

One possible explanation is that this is somehow triggering a heuristic which is then causing the input to be interpreted as some other code page, but the total loss of the `1 DLGINCLUDE` makes that seem unlikely (since most code pages I'm aware of should still contain the ASCII range). It seems more likely that this is triggering some undefined behavior in the preprocessor, and the Chinese characters are incidental.

The most minimal reproduction I've found is:

```c
1 DLGINCLUDE "â"""
```

which outputs:

```c
#line 1 "C:\\Users\\Ryan\\Programming\\Zig\\resinator\\tmp\\RCa21256"
#line 1 "test.rc"
#line 1 "test.rc"
‱䱄䥇䍎啌䕄∠⋢∢
```

Some commonalities between all the reproductions of this bug I've found so far:
- The byte count of the `.rc` file is even, no reproduction has had a filesize with an odd byte count.
- The number of distinct sequences (a byte, an escaped integer, or an escaped quote) in the filename string has to be small (min: 2, max: 18)

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">utterly baffling</span>

### Certain `DLGINCLUDE` filenames trigger `missing '=' in EXSTYLE=<flags>` errors

```c
1 DLGINCLUDE "\06f\x2\x2b\445q\105[ð\134\x90 ...truncated..."
```

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">miscompilation</span>

### Padding bytes are omitted if a comma is omitted

---

TODO: incorporate anything left out from:

The Windows RC compiler will fail to add padding to get to `DWORD`-alignment before the value and sometimes step on the null-terminator of the `VALUE`'s key string.

> `resinator` will avoid a miscompilation when a `VALUE` within a `VERSIONINFO` has the comma between its key and its first value omitted (but only if the value is a quoted string), and will emit a warning

After the key name of a node within a `VERSIONINFO` resource, the Win32 RC compiler will fail to add padding to get back to `DWORD` alignment if:

- the comma between the key and the first value in a `VALUE` statement is omitted, *and*
- the first value is a quoted string

That is, `VALUE "key" "value"` will miscompile but `VALUE "key", "value"` or `VALUE "key" 1` won't.

---

Version information is specified using key/value pairs within `VERSIONINFO` resources. The value data should always start at a 4-byte boundary, so after the key data is written, a variable number of padding bytes are written to get back to 4-byte alignment:

<div style="text-align: center; display: grid; grid-gap: 10px; grid-template-columns: repeat(2, 1fr);">
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
  <pre style="display: flex; flex-direction: column; justify-content: center; align-items: center; flex-grow: 1; margin-top: 0;">
    <code class="language-none"><span style="opacity: 50%;">1 VERSIONINFO {</span>
  <span>VALUE</span> <span style="background: rgba(255,0,0,.1);">"key"</span>, <span style="background: rgba(0,255,0,.1);">"value"</span>
<span style="opacity: 50%;">}</span></code>
  </pre>
</div>
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
  <pre style="display: flex; flex-direction: column; justify-content: center; align-items: center; flex-grow: 1; margin-top: 0;">
    <code class="language-none"><span style="opacity: 25%;">......</span><span style="background: rgba(255,0,0,.1);">k.e.y...</span><span style="background: rgba(0,0,255,.1); outline: 2px solid blue;">..</span>
<span style="background: rgba(0,255,0,.1);">v.a.l.u.e...</span><span style="opacity: 25%;">....</span></code>
  </pre>
</div>
</div>
<p style="margin:0; text-align: center;"><i class="caption">Two padding bytes are inserted after the <code>key</code> to get back to 4-byte alignment</i></p>

However, if the comma between the key and value is omitted, then for whatever reason the padding bytes are also omitted:

<div style="text-align: center; display: grid; grid-gap: 10px; grid-template-columns: repeat(2, 1fr);">
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
  <pre style="display: flex; flex-direction: column; justify-content: center; align-items: center; flex-grow: 1; margin-top: 0;">
    <code class="language-none"><span style="opacity: 50%;">1 VERSIONINFO {</span>
  <span>VALUE</span> <span style="background: rgba(255,0,0,.1);">"key"</span> <span style="background: rgba(0,255,0,.1);">"value"</span>
<span style="opacity: 50%;">}</span></code>
  </pre>
</div>
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
  <pre style="display: flex; flex-direction: column; justify-content: center; align-items: center; flex-grow: 1; margin-top: 0;">
    <code class="language-none"><span style="opacity: 25%;">......</span><span style="background: rgba(255,0,0,.1);">k.e.y...</span><span style="background: rgba(0,255,0,.1);">v.
a.l.u.e...</span><span style="opacity: 25%;">......</span></code>
  </pre>
</div>
</div>
<p style="margin:0; text-align: center;"><i class="caption">Without the comma between <code>"key"</code> and <code>"value"</code>, the padding bytes are not written</i></p>

The problem here is that consumers of the `VERSIONINFO` resource (e.g. [`VerQueryValue`](https://learn.microsoft.com/en-us/windows/win32/api/winver/nf-winver-verqueryvaluew)) will expect the padding bytes, so it will try to read the value as if the padding bytes were there. For example, with the simple `"key" "value"` example:

```c
VerQueryValueW(verbuf, L"\\key", &querybuf, &querysize);
wprintf(L"%s\n", querybuf);
```

Which will print:

```none
alue
```

The problems don't end there, though--`VERSIONINFO` is compiled into a tree structure, meaning the misreading of one node affects the reading of future nodes. Here's a (simplified) real-world `VERSIONINFO` resource definition from a `.rc` file in [Windows-classic-samples](https://github.com/microsoft/Windows-classic-samples):

```c
VS_VERSION_INFO VERSIONINFO
BEGIN
    BLOCK "StringFileInfo"
    BEGIN
        BLOCK "040904e4"
        BEGIN
            VALUE "CompanyName", "Microsoft"
            VALUE "FileDescription", "AmbientLightAware"
            VALUE "FileVersion", "1.0.0.1"
            VALUE "InternalName", "AmbientLightAware.exe"
            VALUE "LegalCopyright", "(c) Microsoft.  All rights reserved."
            VALUE "OriginalFilename", "AmbientLightAware.exe"
            VALUE "ProductName", "AmbientLightAware"
            VALUE "ProductVersion", "1.0.0.1"
        END
    END
    BLOCK "VarFileInfo"
    BEGIN
        VALUE "Translation", 0x409, 1252
    END
END
```

And here's the Properties window of an `.exe` compiled with and without commas between all the key/value pairs:

<div style="display: grid; grid-gap: 10px; grid-template-columns: repeat(auto-fit, minmax(400px, 1fr));">
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
<img style="margin-left:auto; margin-right:auto; display: block; margin-bottom: 8px; display: flex; flex-direction: column; flex-grow: 1;" src="/images/every-rc-exe-bug-quirk-probably/versioninfo-correct.png">
<i class="caption">Correct version information with commas included...</i>
</div>

<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
<img style="margin-left:auto; margin-right:auto; display: block; margin-bottom: 8px; display: flex; flex-direction: column; flex-grow: 1;" src="/images/every-rc-exe-bug-quirk-probably/versioninfo-broken.png">
<i class="caption">...but completely broken if the commas are omitted</i>
</div>
</div>

#### `resinator`'s behavior

`resinator` avoids the miscompilation (always inserts the necessary padding bytes) and emits a warning.

```resinatorerror
test.rc:2:15: warning: the padding before this quoted string value would be miscompiled by the Win32 RC compiler
  VALUE "key" "value"
              ^~~~~~~
test.rc:2:15: note: to avoid the potential miscompilation, consider adding a comma between the key and the quoted string
```

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">fundamental concept</span>

### Turning off flags with `NOT` expressions

Let's say you wanted to define a dialog resource with a button, but you wanted the button to start invisible. You'd do this with a `NOT` expression in the "style" parameter of the button like so:

<pre><code class="language-c"><span style="opacity: 50%;">1 DIALOGEX 0, 0, 282, 239
{</span>
  PUSHBUTTON <span style="opacity: 50%;">"Cancel",1,129,212,50,14,</span> <span class="token_keyword">NOT</span> WS_VISIBLE
<span style="opacity: 50%;">}</span></code>
</pre>

Since `WS_VISIBLE` is set by default, this will unset it and make the button invisible. If there are any other flags that should be applied, they can be bitwise OR'd like so:

<pre><code class="language-c"><span style="opacity: 50%;">1 DIALOGEX 0, 0, 282, 239
{</span>
  PUSHBUTTON <span style="opacity: 50%;">"Cancel",1,129,212,50,14,</span> <span class="token_keyword">NOT</span> WS_VISIBLE <span class="token_operator">|</span> BS_VCENTER
<span style="opacity: 50%;">}</span></code>
</pre>

`WS_VISIBLE` and `BS_VCENTER` are `#define`s that stem from `WinUser.h` and are just numbers under-the-hood. For simplicity's sake, let's pretend their values are `0x1` for `WS_VISIBLE` and `0x2` for `BS_VCENTER` and then focus on this simplified `NOT` expression:

<pre><code class="language-c"><span class="token_keyword">NOT</span> <span class="token_number">0x1</span> <span class="token_operator">|</span> <span class="token_number">0x2</span></code>
</pre>

Since `WS_VISIBLE` is on by default, the default value of these flags is `0x1`, and so the resulting value is evaluated like this:

<div class="not-eval">

<div><i>operation</i></div>
<div><i>binary representation of the result</i></div>
<div><i>hex representation of the result</i></div>

<div class="not-eval-border"><span><small>Default value:</small> <code>0x1</code></span></div>
<div class="not-eval-code"><pre><code>0000 0001</code></pre></div>
<div class="not-eval-border"><span><code>0x1</code></span></div>

<div class="not-eval-border"><code><span class="token_keyword">NOT</span> <span class="token_number">0x1</span></code></div>
<div class="not-eval-code"><pre><code>0000 000<span class="token_deleted">0</span></code></pre></div>
<div class="not-eval-border"><span><code>0x0</code></span></div>

<div class="not-eval-border"><code><span class="token_operator">|</span> <span class="token_number">0x2</span></code></div>
<div class="not-eval-code"><pre><code>0000 00<span class="token_addition">1</span>0</code></pre></div>
<div class="not-eval-border"><span><code>0x2</code></span></div>

</div>

Ordering matters as well. If we switch the expression to:

<pre><code class="language-c"><span class="token_keyword">NOT</span> <span class="token_number">0x1</span> <span class="token_operator">|</span> <span class="token_number">0x1</span></code>
</pre>

then we end up with `0x1` as the result:

<div class="not-eval">

<div><i>operation</i></div>
<div><i>binary representation of the result</i></div>
<div><i>hex representation of the result</i></div>

<div class="not-eval-border"><span><small>Default value:</small> <code>0x1</code></span></div>
<div class="not-eval-code"><pre><code>0000 0001</code></pre></div>
<div class="not-eval-border"><span><code>0x1</code></span></div>

<div class="not-eval-border"><code><span class="token_keyword">NOT</span> <span class="token_number">0x1</span></code></div>
<div class="not-eval-code"><pre><code>0000 000<span class="token_deleted">0</span></code></pre></div>
<div class="not-eval-border"><span><code>0x0</code></span></div>

<div class="not-eval-border"><code><span class="token_operator">|</span> <span class="token_number">0x1</span></code></div>
<div class="not-eval-code"><pre><code>0000 000<span class="token_addition">1</span></code></pre></div>
<div class="not-eval-border"><span><code>0x1</code></span></div>

</div>

If, instead, the ordering was reversed like so:

<pre><code class="language-c"><span class="token_number">0x1</span> <span class="token_operator">|</span> <span class="token_keyword">NOT</span> <span class="token_number">0x1</span></code>
</pre>

then the value at the end would be `0x0`:

<div class="not-eval">

<div><i>operation</i></div>
<div><i>binary representation of the result</i></div>
<div><i>hex representation of the result</i></div>

<div class="not-eval-border"><span><small>Default value:</small> <code>0x1</code></span></div>
<div class="not-eval-code"><pre><code>0000 0001</code></pre></div>
<div class="not-eval-border"><span><code>0x1</code></span></div>

<div class="not-eval-border"><code><span class="token_number">0x1</span></code></div>
<div class="not-eval-code"><pre><code>0000 0001</code></pre></div>
<div class="not-eval-border"><span><code>0x1</code></span></div>

<div class="not-eval-border"><code><span class="token_operator">|</span> <span class="token_keyword">NOT</span> <span class="token_number">0x1</span></code></div>
<div class="not-eval-code"><pre><code>0000 000<span class="token_deleted">0</span></code></pre></div>
<div class="not-eval-border"><span><code>0x0</code></span></div>

</div>

With these basic examples, `NOT` seems pretty straightforward, however...

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">utterly baffling</span>

### `NOT` is incomprehensible

Practically any deviation outside the simple examples outlined in [*Turning off flags with `NOT` expressions*](#turning-off-flags-with-not-expressions) leads to bizarre and inexplicable results. For example, these expressions are all accepted by the Windows RC compiler:

- `NOT (1 | 2)`
- `NOT () 2`
- `7 NOT NOT 4 NOT 2 NOT NOT 1`

The first one looks like it makes sense, as intuitively the `(1 | 2)` would be evaluated first so in theory it should be equivalent to `NOT 3`. However, if the default value of the flags is `0`, then the expression `NOT (1 | 2)` (somehow) evaluates to `2`, whereas `NOT 3` would evaluate to `0`.

`NOT () 2` seems like it should obviously be a syntax error, but for whatever reason it's accepted by the Windows RC compiler and also evaluates to `2`.

`7 NOT NOT 4 NOT 2 NOT NOT 1` is entirely incomprehensible, and just as incomprehensibly, it *also* results in `2` (if the default value is `0`).

This behavior is so bizarre and obviously incorrect that I didn't even try to understand what's going on here, so your guess is as good as mine on this one.

#### `resinator`'s behavior

`resinator` only accepts `NOT <number>`, anything else is an error:

```resinatorerror
test.rc:2:13: error: expected '<number>', got '('
  STYLE NOT () 2
            ^
```

All 3 of the above examples lead to compile errors in `resinator`.

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">parser bug/quirk</span>

### `NOT` can be used in places it makes no sense

The strangeness of `NOT` doesn't end there, as the Windows RC compiler also allows it to be used in many (but not all) places that a number expression can be used.

As an example, here are `NOT` expressions used in the `x`, `y`, `width`, and `height` arguments of a `DIALOGEX` resource:

```c
1 DIALOGEX NOT 1, NOT 2, NOT 3, NOT 4
{
  // ...
}
```

This doesn't necessarily cause problems, but since `NOT` is only useful in the context of turning off enabled-by-default flags of a bit flag parameter, there's no reason to allow `NOT` expressions outside of that context.

#### `resinator`'s behavior

`resinator` errors if `NOT` expressions are attempted to be used outside of bit flag parameters:

```resinatorerror
test.rc:1:12: error: expected number or number expression; got 'NOT'
1 DIALOGEX NOT 1, NOT 2, NOT 3, NOT 4
           ^~~
```

</div>

<div>

<style scoped>
.bug-quirk-box {
  border: 1px solid rgba(0,0,0,0.25);
  padding: 0.25em 1em;
  margin-bottom: 1.5em;
}
@media (prefers-color-scheme: dark) {
  .bug-quirk-box {
    border-color: rgba(255,255,255,0.25);
  }
}
.bug-quirk-category {
  float: right;
  background: rgba(25,25,100,0.5);
  padding: 0.15em 0.5em;
  margin-top: 0.75em;
  margin-left: 0.5em;
  margin-bottom: 0.1em;
  color: #fff;
  font-size: 90%;
}
@media (prefers-color-scheme: dark) {
  .bug-quirk-category {
    color: rgba(255,255,255,0.75);
  }
}
.hexdump-tooltip {
  position: absolute;
  background: black;
  top:-15px;
  left:50%;
  transform:translate(-50%,-100%);
  z-index: 1;
  padding: 0.5em 1em;
  border: 1px solid #aaa;
}
.hexdump-tooltip.rcdata {
  background: #C6CEEC;
  border: 1px solid blue;
}
@media (prefers-color-scheme: dark) {
.hexdump-tooltip.rcdata {
  background: #05113D;
}
}
.hexdump-tooltip i {
  position:absolute;
  top:100%;
  left:45%;
  margin-left:-15px;
  width:30px;
  height:15px;
  overflow:hidden;
}
.hexdump-tooltip i::after {
  content:'';
  position:absolute;
  width:15px;
  height:15px;
  left:50%;
  transform:translate(-50%,-50%) rotate(45deg);
  background: black;
  border: 1px solid #aaa;
}
.hexdump-tooltip.rcdata i::after {
  background: #C6CEEC;
  border: 1px solid blue;
}
@media (prefers-color-scheme: dark) {
.hexdump-tooltip.rcdata i::after {
  background: #05113D;
}
}
.not-eval {
  display: grid; grid-gap: 10px; grid-template-columns: 1fr 1fr 1fr;
}
.not-eval > *:not(.not-eval-code) {
  justify-content: center; align-items: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;
}
.not-eval-code {
  text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;
}
.not-eval-code pre {
  display: flex; flex-grow: 1; justify-content: center; align-items: center; margin: 0;
}
.not-eval-border {
  border: 1px solid #eee;
}
@media (prefers-color-scheme: dark) {
.not-eval-border {
  border-color: #111;
}
}
</style>

</div>