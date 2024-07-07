Inspired by an [accepted proposal](https://github.com/ziglang/zig/issues/3702) for [Zig](https://ziglang.org/) to include support for compiling Windows resource script (`.rc`) files, I set out on what I thought at the time would be a somewhat straightforward side-project of writing a Windows resource compiler in Zig. I figured that, since there are multiple existing open source projects with similar goals (`windres`, `llvm-rc`&mdash;both are cross-platform Windows resource compilers), I could use them as a reference, and that the syntax of `.rc` files didn't look too complicated.

**I was wrong on both counts.**

While the `.rc` syntax *in theory* is not complicated, there are edge cases hiding around every corner, and each of the existing alternative Windows resource compilers handle each edge case very differently from the canonical Microsoft implementation.

With a goal of byte-for-byte-identical-outputs (and possible bug-for-bug compatibility) for my implementation, I had to effectively start from scratch, as even [the Windows documentation couldn't be fully trusted to be accurate](https://github.com/MicrosoftDocs/win32/pulls?q=is%3Apr+author%3Asqueek502). Ultimately, I went with fuzz testing (with `rc.exe` as the source of truth/oracle) as my method of choice for deciphering the behavior of the Windows resource compiler (this approach is similar to something I did [with Lua](https://www.ryanliptak.com/blog/fuzzing-as-test-case-generator/) a while back).

This process led to a few things:

- A completely clean-room implementation of a Windows resource compiler (not even any decompilation involved in the process)
- A high degree of compatibility with the `rc.exe` implementation, including [byte-for-byte identical outputs](https://github.com/squeek502/win32-samples-rc-tests/) for a sizable corpus of Microsoft-provided sample `.rc` files (~500 files)
- A large list of strange/interesting/baffling behaviors of the Windows resource compiler

My resource compiler implementation, [`resinator`](https://github.com/squeek502/resinator), has now reached relative maturity and has [been merged into the Zig compiler](https://www.ryanliptak.com/blog/zig-is-a-windows-resource-compiler/) (but is also maintained as a standalone project), so I thought it might be interesting to write about all the weird stuff I found along the way.

<p><aside class="note">

Note: While this list is thorough, it is only indicative of my current understanding of `rc.exe`, which can always be incorrect. Even in the process of writing this article, I found new edge cases and [had to correct my implementation of certain aspects of the compiler](https://github.com/squeek502/resinator/commit/fda2c685e5f59b79816bb0e7186d24b93a8c77b9).

</aside></p>

## Who is this for?

- If you work at Microsoft, consider this a large list of bug reports (of particular note, see everything labeled 'miscompilation')
  + If you're [Raymond Chen](https://devblogs.microsoft.com/oldnewthing/author/oldnewthing), then consider this an extension/homage to all the (fantastic, very helpful) blog posts about Windows resources in [The Old New Thing](https://devblogs.microsoft.com/oldnewthing/)
- If you are a contributor to `llvm-rc`, `windres`, or `wrc`, consider this a long list of behaviors to test for (if strict compatibility is a goal)
- If you are someone that managed to [endure the bad audio of this talk I gave about my resource compiler](https://www.youtube.com/watch?v=RZczLb_uI9E) and wanted more, consider this an extension of that talk
- If you are none of the above, consider this an entertaining list of bizarre bugs/edge cases

If you have no familiarity with `.rc` files at all, no need to worry&mdash;I have tried to organize this post in order to get you up to speed as-you-read. However, if you'd instead like to skip around and check out the strangest bugs/quirks, `Ctrl+F` for 'utterly baffling'.

## A brief intro to resource compilers

`.rc` files (resource definition-script files) are scripts that contain both C/C++ preprocessor commands and resource definitions. We'll ignore the preprocessor for now and focus on resource definitions. One possible resource definition might look like this:

<pre class="annotated-code"><code class="language-c" style="white-space: inherit;"><span class="annotation"><span class="desc">id<i></i></span><span class="subject"><span class="token_number">1</span></span></span> <span class="annotation"><span class="desc">type<i></i></span><span class="subject"><span class="token_identifier">FOO</span></span></span> <span class="token_punctuation">{</span> <span class="annotation"><span class="desc">data<i></i></span><span class="subject"><span class="token_string">"bar"</span></span></span> <span class="token_punctuation">}</span></code></pre>

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

This is because both resource IDs and resource types use special tokenization rules&mdash;they are basically only terminated by whitespace and nothing else (well, not exactly whitespace, it's actually any ASCII character from `0x05` to `0x20` [inclusive]). As an example:

<pre><code class="language-c"><span class="token_tag">L"\r\n"123abc</span><span class="token_ansi_c_whitespace token_whitespace"> </span><span class="token_class-name">error{OutOfMemory}!?u8</span><span class="token_ansi_c_whitespace token_whitespace"> </span><span class="token_punctuation">{</span><span class="token_ansi_c_whitespace token_whitespace"> </span><span class="token_string">"bar"</span><span class="token_ansi_c_whitespace token_whitespace"> </span><span class="token_punctuation">}</span><span class="token_ansi_c_whitespace token_whitespace">
</span></code></pre>

<p><aside class="note">Reminder: Resource IDs don't have to be integers</aside></p>

In this case, the ID would be `L"\R\N"123ABC` (uppercased) and the resource type would be `ERROR{OUTOFMEMORY}!?U8` (again, uppercased).

---

I've started with this particular quirk because it is actually demonstrative of the level of `rc.exe`-compatibility of the existing cross-platform resource compiler projects:

- [`windres`](https://ftp.gnu.org/old-gnu/Manuals/binutils-2.12/html_node/binutils_14.html) parses the `"FOO"` resource type as a regular string literal and the resource type name ends up as `FOO` (without the quotes)
- [`llvm-rc`](https://github.com/llvm/llvm-project/tree/56b3222b79632a4bbb36271735556a03b2504791/llvm/tools/llvm-rc) errors with `expected int or identifier, got "FOO"`
- [`wrc`](https://www.winehq.org/docs/wrc) also errors with `syntax error`

<p><aside class="note">

Note: This is the last time I'll be mentioning the behaviors of `windres`/`llvm-rc`/`wrc`, as this simple example is indicative of how much their implementations diverge from `rc.exe` for edge cases. See [win32-samples-rc-tests](https://github.com/squeek502/win32-samples-rc-tests/) for a rough approximation of the (strict) compatibility of the different Windows resource compilers on a more-or-less real-world set of `.rc` files.

From here on out, I'll only be mentioning the behavior of [`resinator`](https://github.com/squeek502/resinator), my resource compiler implementation that was the impetus for the findings in this article.

</aside></p>

#### [`resinator`](https://github.com/squeek502/resinator)'s behavior

`resinator` matches the resource ID/type tokenization behavior of `rc.exe` in all known cases.

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

The problem is that the exact same procedure outlined above is erroneously followed for *all* allowed digits, so things go haywire for non-ASCII digits since the relationship between the non-ASCII digit's codepoint value and the ASCII value of `'0'` is arbitrary:

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

For whatever reason, `rc.exe` will just take the last number literal in the expression and try to read from a file with that name, e.g. `(1+1)` will try to read from the path `1`, and `1+-1` will try to read from the path `-1` (the `-` sign is [part of the number literal token in this case](#unary-operators-are-an-illusion)).

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
<span class="bug-quirk-category">parser bug/quirk</span>

### Incomplete resource at EOF

The incomplete resource definition in the following example is an error:

```c
// A complete resource definition
1 FOO { "bar" }

// An incomplete resource definition
2 FOO
```

But it's not the error you might be expecting:

```
test.rc(6) : error RC2135 : file not found: FOO
```

Strangely, `rc.exe` in this case will treat `FOO` as both the type of the resource *and* as the filename for the resource's data. If you create a file with the name `FOO` it will *successfully compile*, and the `.res` will have a resource with type `FOO` and its data will be that of the file `FOO`.

#### `resinator`'s behavior

`resinator` does not match the `rc.exe` behavior and instead errors on this type of incomplete resource definition at the end of a file:

```language-resinatorerror
test.rc:5:6: error: expected quoted string literal or unquoted literal; got '<eof>'
2 FOO
     ^
```

However...

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">parser bug/quirk</span>

### Dangling literal at EOF

If we change the previous example to only have one dangling literal for its incomplete resource definition like so:

```c
// A complete resource definition
1 FOO { "bar" }

// An incomplete resource definition
FOO
```

Then `rc.exe` *will always successfully compile it* (and it won't try to read from the file `FOO`). That is, a single dangling literal at the end of a file is fully allowed, and it is just treated as if it doesn't exist (there's no corresponding resource in the resulting `.res` file).

It also turns out that there are three `.rc` files in [Windows-classic-samples](https://github.com/microsoft/Windows-classic-samples) that rely on this behavior ([1](https://github.com/microsoft/Windows-classic-samples/blob/a47da3d4551b74bb8cc1f4c7447445ac594afb44/Samples/CredentialProvider/cpp/resources.rc), [2](https://github.com/microsoft/Windows-classic-samples/blob/a47da3d4551b74bb8cc1f4c7447445ac594afb44/Samples/Win7Samples/security/credentialproviders/sampleallcontrolscredentialprovider/resources.rc), [3](https://github.com/microsoft/Windows-classic-samples/blob/a47da3d4551b74bb8cc1f4c7447445ac594afb44/Samples/Win7Samples/security/credentialproviders/samplewrapexistingcredentialprovider/resources.rc)), so in order to fully pass [win32-samples-rc-tests](https://github.com/squeek502/win32-samples-rc-tests/), it is necessary to allow a dangling literal at the end of a file.

#### `resinator`'s behavior

`resinator` allows a single dangling literal at the end of a file, but emits a warning:

```language-resinatorerror
test.rc:5:1: warning: dangling literal at end-of-file; this is not a problem, but it is likely a mistake
FOO
^~~
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

This is all pretty reasonable, but things start to get truly bizarre when you add `#pragma code_page` into the mix:

```c
#pragma code_page(1252)
1 RCDATA { "Ó" }
```

When saved as Windows-1252 and compiled with Windows-1252 as the default code page, this will work the same as described above. However, if we compile the same Windows-1252-encoded `.rc` file with the default code page set to UTF-8 (`rc.exe /c65001`), we see something rather strange:

- The input `0xD3` byte is interpreted as `Ó`, as expected since the `#pragma code_page` changed the code page to 1252
- The output in the `.res` is `0xC3 0x93`, the UTF-8 sequence for `Ó` (instead of the expected `0xD3` which is the Windows-1252 encoding of `Ó`)

That is, the `#pragma code_page` changed the *input* code page, but there is a distinct *output* code page that can be out-of-sync with the input code page. In this instance, the input code page for the `1 RCDATA ...` line is Windows-1252, but the output code page is still the default set from the CLI option (in this case, UTF-8).

Even more bizarre, this disjointedness can only occur via the first `#pragma code_page` directive of the file:

```c
#pragma code_page(65001) // which code page this is doesn't matter, it can be anything valid
#pragma code_page(1252)
1 RCDATA { "Ó" }
```

With this, still saved as Windows-1252, the code page from the CLI option no longer matters&mdash;even when compiled with `/c65001`, the `0xD3` in the file is both interpreted as Windows-1252 (`Ó`) *and* outputted as Windows-1252 (`0xD3`).

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

The problems don't end there, though&mdash;`VERSIONINFO` is compiled into a tree structure, meaning the misreading of one node affects the reading of future nodes. Here's a (simplified) real-world `VERSIONINFO` resource definition from a `.rc` file in [Windows-classic-samples](https://github.com/microsoft/Windows-classic-samples):

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

However, there *is* an extra bit of weirdness involved here, since certain `NOT` expressions cause errors in some places but not others. For example, the expression `1 | NOT 2` is an error if it's used in the `type` parameter of a `MENUEX`'s `MENUITEM`, but `NOT 2 | 1` is totally accepted.

```c
1 MENUEX {
  // Error: numeric value expected at NOT
  MENUITEM "bar", 101, 1 | NOT 2
  // No error if the NOT is moved to the left of the bitwise OR
  MENUITEM "foo", 100, NOT 2 | 1
}
```

<p><aside class="note">

Note: `1 | NOT 2` is legal in all bit flag parameters (where the use of `NOT` actually makes sense).  

</aside></p>

#### `resinator`'s behavior

`resinator` errors if `NOT` expressions are attempted to be used outside of bit flag parameters:

```resinatorerror
test.rc:1:12: error: expected number or number expression; got 'NOT'
1 DIALOGEX NOT 1, NOT 2, NOT 3, NOT 4
           ^~~
```

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">missing error, miscompilation</span>

### Cursor posing as an icon and vice versa

The `ICON` and `CURSOR` resource types expect a `.ico` file and a `.cur` file, respectively. The format of `.ico` and `.cur` is identical, but there is an 'image type' field that denotes the type of the file (`1` for icon, `2` for cursor).

The Windows RC compiler does not discriminate on what type is used for which resource. If we have `foo.ico` with the 'icon' type, and `foo.cur` with the 'cursor' type, then the Windows RC compiler will happily accept all of the following resources:

```c
1 ICON "foo.ico"
2 ICON "foo.cur"
3 CURSOR "foo.ico"
4 CURSOR "foo.cur"
```

However, the resources with the mismatched types becomes a problem in the resulting `.res` file because `ICON` and `CURSOR` have different formats for their resource data. When the type is 'cursor', a [LOCALHEADER](https://learn.microsoft.com/en-us/windows/win32/menurc/localheader) consisting of two cursor-specific `u16` fields is written at the start of the resource data. This means that:

- An `ICON` resource with a `.cur` file will write those extra cursor-specific fields, but still 'advertise' itself as an `ICON` resource
- A `CURSOR` resource with an `.ico` file will *not* write those cursor-specific fields, but still 'advertise' itself as a `CURSOR` resource
- In both of these cases, attempting to load the resource will always end up with an incorrect/invalid result because the parser will be assuming that those fields exist/don't exist based on the resource type

So, such a mismatch *always* leads to incorrect/invalid resources in the `.res` file.

#### `resinator`'s behavior

`resinator` errors if the resource type (`ICON`/`CURSOR`) doesn't match the type specified in the `.ico`/`.cur` file:

```resinatorerror
test.rc:1:10: error: resource type 'cursor' does not match type 'icon' specified in the file
1 CURSOR "foo.ico"
         ^~~~~~~~~
```

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">unnecessary limitation</span>

### PNG encoded cursors are erroneously rejected

`.ico`/`.cur` files are a 'directory' of multiple icons/cursors, used for different resolutions. Historically, each image was a [device-independent bitmap (DIB)](https://learn.microsoft.com/en-us/windows/win32/gdi/device-independent-bitmaps), but nowadays they can also be encoded as PNG.

The Windows RC compiler is fine with `.ico` files that have PNG encoded images, but for whatever reason rejects `.cur` files with PNG encoded images.

```c
// No error, compiles and loads just fine
1 ICON "png.ico"
// error RC2176 : old DIB in 1x1_png.cur; pass it through SDKPAINT
2 CURSOR "png.cur"
```

This limitation is provably artificial, though. If a `.res` file contains a `CURSOR` resource with PNG encoded image(s), then [`LoadCursor`](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-loadcursorw) works correctly and the cursor displays correctly.

#### `resinator`'s behavior

`resinator` allows PNG encoded cursor images, and warns about the Windows RC compiler behavior:

```resinatorerror
test.rc:2:10: warning: the resource at index 0 of this cursor has the format 'png'; this would be an error in the Win32 RC compiler
2 CURSOR png.cur
         ^~~~~~~
```

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">miscompilation, utterly baffling</span>

### Adversarial icons/cursors can lead to arbitrarily large `.res` files

Each image in a `.ico`/`.cur` file has a corresponding header entry which contains (a)
 the size of the image in bytes, and (b) the offset of the image's data within the file. The Windows RC file fully trusts that this information is accurate; it will never error regardless of how malformed these two pieces of information are.

If the reported size of an image is larger than the size of the `.ico`/`.cur` file itself, the Windows RC compiler will:

- Write however many bytes there are before the end of the file
- Write zeroes for any bytes that are past the end of the file, except
- Once it has written 0x4000 bytes total, it will repeat these steps again and again until it reaches the full reported size

Because a `.ico`/`.cur` can contain up to 65535 images, and each image within can report its size as up to 2 GiB (more on this later), this means that a small (< 1 MiB) maliciously constructed `.ico`/`.cur` could cause the Windows RC compiler to attempt to write up to 127 TiB of data to the `.res` file.

#### `resinator`'s behavior

`resinator` errors if the reported file size of an image is larger than the size of the `.ico`/`.cur` file:

```resinatorerror
test.rc:1:8: error: unable to read icon file 'test.ico': ImpossibleDataSize
1 ICON test.ico
       ^~~~~~~~
```

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">miscompilation, utterly baffling</span>

### Adversarial icons/cursors can lead to _**infinitely large**_ `.res` files

As mentioned in [*Adversarial icons/cursors can lead to arbitrarily large `.res` files*](#adversarial-icons-cursors-can-lead-to-arbitrarily-large-res-files), each image within an icon/cursor can report its size as up to 2 GiB. However, the field for the image size is actually 4 bytes wide, meaning the maximum should technically be 4 GiB.

The 2 GiB limit comes from the fact that the Windows RC compiler actually interprets this field as a *signed* integer, so if you try to define an image with a size larger than 2 GiB, it'll get interpreted as negative. We can confirm this by compiling with the verbose flag (`/v`):

```
Writing ICON:1, lang:0x409, size -6000000
```

When this happens, the Windows RC compiler seemingly enters into an infinite loop when writing the icon data to the `.res` file, meaning it will continue trying to write garbage until (presumably) all the space of the hard drive has been used up.

#### `resinator`'s behavior

`resinator` avoids misinterpreting the image size as signed, and allows images of up to 4 GiB to be specified if the `.ico`/`.cur` file actually is large enough to contain them.

</div>

<div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">miscompilation</span>

### Icon/cursor images with impossibly small sizes lead to bogus `.res` files

Similar to [*Adversarial icons/cursors can lead to arbitrarily large `.res` files*](#adversarial-icons-cursors-can-lead-to-arbitrarily-large-res-files), it's also possible for images to specify their size as impossibly small:

- If the size of an image is reported as zero, then the Windows RC compiler will:
  + Write an arbitrary size for the resource's data
  + Not actually write any bytes to the data section of the resource
- If the size of an image is smaller than the header of the image format, then the Windows RC compiler will:
  + Read the full header for the image, even if it goes past the reported end of the image data
  + Write the reported number of bytes to the `.res` file, which can never be a valid image since it is smaller than the header size of the image format

#### `resinator`'s behavior

`resinator` errors if the reported size of an image within a `.ico`/`.cur` is too small to contain a valid image header:

```resinatorerror
test.rc:1:8: error: unable to read icon file 'test.ico': ImpossibleDataSize
1 ICON test.ico
       ^~~~~~~~
```

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">miscompilation</span>

### Bitmaps with missing bytes in their color table

`BITMAP` resources expect `.bmp` files, which are roughly structured something like this:

<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
  <pre style="display: flex; flex-direction: column; justify-content: center; align-items: center; flex-grow: 1; margin-top: 0;">
    <code class="language-none"><span style="background: rgba(255,0,0,.1);">..BITMAPFILEHEADER..</span>
<span style="background: rgba(0,0,255,.1);">..BITMAPINFOHEADER..</span>
<span style="background: rgba(0,0,255,.1);">....................</span>
<span style="background: rgba(0,255,0,.1);">....color table.....</span>
<span style="background: rgba(0,255,0,.1);">....................</span>
<span style="background: rgba(150,0,255,.1);">....pixel data......</span>
<span style="background: rgba(150,0,255,.1);">....................</span>
<span style="background: rgba(150,0,255,.1);">....................</span></code>
  </pre>
</div>

The color table has a variable number of entries, dictated by either the `biClrUsed` field of the `BITMAPINFOHEADER`, or, if `biClrUsed` is zero, 2<sup>n</sup> where `n` is the number of bits per pixel (`biBitCount`). When the number of bits per pixel is 8 or fewer, this color table is used as a color palette for the pixels in the image:

<div class="bitmapcolors">
  <div class="colortable">
    <div class="colorentry">
      <div class="colori"><span class="textbg">0</span></div>
      <div style="background: rgba(255,0,0,0.1)">179</div>
      <div style="background: rgba(0,255,0,0.1)">127</div>
      <div style="background: rgba(0,0,255,0.1)">46</div>
      <div style="background: rgba(100,100,100,0.1)">-</div>
      <div class="finalcolor" style="background: rgba(179,127,46,0.5);"></div>
    </div>
    <div class="colorentry">
      <div class="colori"><span class="textbg">1</span></div>
      <div style="background: rgba(255,0,0,0.1)">44</div>
      <div style="background: rgba(0,255,0,0.1)">96</div>
      <div style="background: rgba(0,0,255,0.1)">167</div>
      <div style="background: rgba(100,100,100,0.1)">-</div>
      <div class="finalcolor" style="background: rgba(44,96,167,0.5);"></div>
    </div>
    <div class="colorentry">
      <div class="colori"><span class="textbg">2</span></div>
      <div style="background: rgba(255,0,0,0.1)">154</div>
      <div style="background: rgba(0,255,0,0.1)">60</div>
      <div style="background: rgba(0,0,255,0.1)">177</div>
      <div style="background: rgba(100,100,100,0.1)">-</div>
      <div class="finalcolor" style="background: rgba(154,60,177,0.5);"></div>
    </div>
  </div>
  <div class="colorlabels">
    <div>color index</div>
    <div>color rgb</div>
    <div>color</div>
  </div>
</div>

<p style="text-align: center;"><i class="caption">Example color table (above) and some pixel data that references the color table (below)</i></p>


<div class="bitmappixels">
  <div>...</div>
  <div style="background: rgba(44,96,167,0.5);"><span class="textbg">1</span></div>
  <div style="background: rgba(179,127,46,0.5)"><span class="textbg">0</span></div>
  <div style="background: rgba(154,60,177,0.5)"><span class="textbg">2</span></div>
  <div style="background: rgba(179,127,46,0.5)"><span class="textbg">0</span></div>
  <div style="background: rgba(44,96,167,0.5);"><span class="textbg">1</span></div>
  <div>...</div>
</div>

This is relevant because the Windows resource compiler does not just write the bitmap data to the `.res` verbatim. Instead, it strips the `BITMAPFILEHEADER` and will always write the expected number of color table bytes, even if the number of color table bytes in the file doesn't match expectations.

<div style="text-align: center; display: grid; grid-gap: 10px; grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));">
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
  <pre style="display: flex; flex-direction: column; justify-content: center; align-items: center; flex-grow: 1; margin-top: 0;">
    <code class="language-none"><span style="background: rgba(255,0,0,.1);">..BITMAPFILEHEADER..</span>
<span style="background: rgba(0,0,255,.1);">..BITMAPINFOHEADER..</span>
<span style="background: rgba(0,0,255,.1);">....................</span>
<span style="background: rgba(150,0,255,.1);">....pixel data......</span>
<span style="background: rgba(150,0,255,.1);">....................</span>
<span style="background: rgba(150,0,255,.1);">....................</span></code>
  </pre>
</div>
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
  <pre style="display: flex; flex-direction: column; justify-content: center; align-items: center; flex-grow: 1; margin-top: 0;">
    <code class="language-none"><span style="background: rgba(0,0,255,.1);">..BITMAPINFOHEADER..</span>
<span style="background: rgba(0,0,255,.1);">....................</span>
<span style="background: rgba(0,255,0,.1);">....color table.....</span>
<span style="background: rgba(0,255,0,.1);">....................</span>
<span style="background: rgba(150,0,255,.1);">....pixel data......</span>
<span style="background: rgba(150,0,255,.1);">....................</span>
<span style="background: rgba(150,0,255,.1);">....................</span></code>
  </pre>
</div>
</div>
<p style="margin:0; text-align: center;"><i class="caption">A bitmap file that omits the color table even though a color table is expected, and the data written to the <code>.res</code> for that bitmap</i></p>

Typically, a bitmap with a shorter-than-expected color table is considered invalid (or, at least, Windows and Firefox fail to render them), but the Windows RC compiler does not error on such files. Instead, it will completely ignore the bounds of the color table and just read into the following pixel data if necessary, treating it as color data.

<div style="text-align: center; display: grid; grid-gap: 10px; grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));">
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
  <pre style="display: flex; flex-direction: column; justify-content: center; align-items: center; flex-grow: 1; margin-top: 0;">
    <code class="language-none"><span style="background: rgba(255,0,0,.1);">..BITMAPFILEHEADER..</span>
<span style="background: rgba(0,0,255,.1);">..BITMAPINFOHEADER..</span>
<span style="background: rgba(0,0,255,.1);">....................</span>
<div style="outline: 2px dashed rgba(150,0,255,.75);"><span style="background: rgba(150,0,255,.1);">....pixel data......</span>
<span style="background: rgba(150,0,255,.1);">....................</span></div><span style="background: rgba(150,0,255,.1);">....................</span></code>
  </pre>
</div>
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
  <pre style="display: flex; flex-direction: column; justify-content: center; align-items: center; flex-grow: 1; margin-top: 0;">
    <code class="language-none"><span style="background: rgba(0,0,255,.1);">..BITMAPINFOHEADER..</span>
<span style="background: rgba(0,0,255,.1);">....................</span>
<div style="outline: 2px dashed rgba(150,0,255,.75);"><span style="background: rgba(0,255,0,.1);">..."color table"....</span>
<span style="background: rgba(0,255,0,.1);">....................</span></div><span style="background: rgba(150,0,255,.1);">....pixel data......</span>
<span style="background: rgba(150,0,255,.1);">....................</span>
<span style="background: rgba(150,0,255,.1);">....................</span></code>
  </pre>
</div>
</div>
<p style="margin:0; text-align: center;"><i class="caption">When compiled with the Windows RC compiler, the bytes of the color table in the <code>.res</code> will consist of the bytes in the outlined region of the pixel data in the original bitmap file.</i></p>

Further, if it runs out of pixel data to read (i.e. the inferred size of the color table extends beyond the end of the file), it will start filling in the remaining missing color table bytes with zeroes.

<p><aside class="note">

My guess is that this behavior is largely unintentional, and is a byproduct of two things:

- By stripping the `BITMAPFILEHEADER` from the bitmap during resource compilation, the `bfOffBits` field (which contains the offset from the beginning of the file to the pixel data) is not present in the compiled resource
- A bitmap with *more* than the expected number of color table bytes is probably valid ([see `q/pal8offs.bmp` of bmpsuite](https://entropymine.com/jason/bmpsuite/bmpsuite/html/bmpsuite.html))

The first point means that the size of the color table must always match the size given in `BITMAPINFOHEADER`, since the start of the pixel data must be calculated using the size of the color table. The second point means that there is *some* reason not to error out completely when the color table does not match the expected size.

Together, it means that there is some justification for forcing the color table to match the expected size when there is a mismatch.

</aside></p>

#### From invalid to valid

Interestingly, the behavior with regards to smaller-than-expected color tables means that an invalid bitmap compiled as a resource can end up becoming a valid bitmap. For example, if you have a bitmap with 12 actual entries in the color table, but `BITMAPFILEHEADER.biClrUsed` says there are 13, Windows considers that an invalid bitmap and won't render it. If you take that bitmap and compile it as a resource, though:

```c
1 BITMAP "invalid.bmp"
```

The resulting `.res` will pad the color table of the bitmap to get up to the expected number of entries (13 in this case), and therefore the resulting resource will render fine when using `LoadBitmap` to load it.

#### Maliciously constructed bitmaps

The dark side of this bug/quirk is that the Windows RC compiler does not have any limit as to how many missing color palette bytes it allows, and this is even the case when there are possible hard limits available (e.g. a bitmap with 4-bits-per-pixel can only have 2<sup>4</sup> (16) colors, but the Windows RC compiler doesn't mind if a bitmap says it has more than that).

The `biClrUsed` field (which contains the number of color table entries) is a `u32`, meaning a bitmap can specify it contains up to 4.29 billion entries in its color table, where each color entry is 4 bytes long (or 3 bytes for old Windows 2.0 bitmaps). This means that a maliciously constructed bitmap can induce the Windows RC compiler to write up to 16 GiB of color table data when writing its resource, even if the file itself doesn't contain *any* color table at all.

#### `resinator`'s behavior

`resinator` errors if there are any missing palette bytes:

```resinatorerror
test.rc:1:10: error: bitmap has 16 missing color palette bytes
1 BITMAP missing_palette_bytes.bmp
         ^~~~~~~~~~~~~~~~~~~~~~~~~
test.rc:1:10: note: the Win32 RC compiler would erroneously pad out the missing bytes (and the added padding bytes would include 6 bytes of the pixel data)
```

For a maliciously constructed bitmap, that error might look like:

```resinatorerror
test.rc:1:10: error: bitmap has 17179869180 missing color palette bytes
1 BITMAP trust_me.bmp
         ^~~~~~~~~~~~
test.rc:1:10: note: the Win32 RC compiler would erroneously pad out the missing bytes
```

There's also a warning for extra bytes between the color table and the pixel data:

```resinatorerror
test.rc:2:10: warning: bitmap has 4 extra bytes preceding the pixel data which will be ignored
2 BITMAP extra_palette_bytes.bmp
         ^~~~~~~~~~~~~~~~~~~~~~~
```

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">miscompilation</span>

### Bitmaps with BITFIELDS and a color palette

When testing things using the bitmaps from [bmpsuite](https://entropymine.com/jason/bmpsuite/), there is one well-formed `.bmp` file that `rc.exe` and `resinator` handle differently:

> `g/rgb16-565pal.bmp`: A 16-bit image with both a BITFIELDS segment and a palette.

The details aren't too important here, so just know that the file is structured like this:

<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
  <pre style="display: flex; flex-direction: column; justify-content: center; align-items: center; flex-grow: 1; margin-top: 0;">
    <code class="language-none"><span style="background: rgba(255,0,0,.1);">..BITMAPFILEHEADER..</span>
<span style="background: rgba(0,0,255,.1);">..BITMAPINFOHEADER..</span>
<span style="background: rgba(0,0,255,.1);">....................</span>
<span style="background: rgba(255,216,0,.1);">.....bitfields......</span>
<span style="background: rgba(0,255,0,.1);">....color table.....</span>
<span style="background: rgba(0,255,0,.1);">....................</span>
<span style="background: rgba(150,0,255,.1);">....pixel data......</span>
<span style="background: rgba(150,0,255,.1);">....................</span>
<span style="background: rgba(150,0,255,.1);">....................</span></code>
  </pre>
</div>

As mentioned earlier, the `BITMAPFILEHEADER` is dropped when compiling a `BITMAP` resource, but for whatever reason, `rc.exe` also drops the color table when compiling this `.bmp`, so it ends up like this in the compiled `.res`:

<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
  <pre style="display: flex; flex-direction: column; justify-content: center; align-items: center; flex-grow: 1; margin-top: 0;">
    <code class="language-none"><span style="background: rgba(0,0,255,.1);">..BITMAPINFOHEADER..</span>
<span style="background: rgba(0,0,255,.1);">....................</span>
<span style="background: rgba(255,216,0,.1);">.....bitfields......</span>
<span style="background: rgba(150,0,255,.1);">....pixel data......</span>
<span style="background: rgba(150,0,255,.1);">....................</span>
<span style="background: rgba(150,0,255,.1);">....................</span></code>
  </pre>
</div>

Note, though, that within the `BITMAPINFOHEADER`, it still says that there is a color table present (specifically, that there are 256 entries in the color table), so this is likely a miscompilation. One possibility here is that it's not intended to be valid for a `.bmp` to contain *both* color masks *and* a color table, but that seems dubious because Windows renders the original `.bmp` file just fine in Explorer/Photos.

<p><aside class="note">

Note: This particular bitmap structure is potentially unlikely to encounter in the wild, since bitmaps with >= 16-bit depth and a color table seem largely useless (for bit depths >= 16, the color table is only used for "optimizing colors used on palette-based devices")

The available documentation regarding this ([`BITMAPINFOHEADER`](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/ns-wingdi-bitmapinfoheader), [`BITMAPV5HEADER`](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/ns-wingdi-bitmapv5header)) I found to be unclear at best, though.

</aside></p>

#### `resinator`'s behavior

`resinator` does not drop the color table, so in the compiled `.res` the bitmap resource data looks like this:

<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
  <pre style="display: flex; flex-direction: column; justify-content: center; align-items: center; flex-grow: 1; margin-top: 0;">
    <code class="language-none"><span style="background: rgba(0,0,255,.1);">..BITMAPINFOHEADER..</span>
<span style="background: rgba(0,0,255,.1);">....................</span>
<span style="background: rgba(255,216,0,.1);">.....bitfields......</span>
<span style="background: rgba(0,255,0,.1);">....color table.....</span>
<span style="background: rgba(0,255,0,.1);">....................</span>
<span style="background: rgba(150,0,255,.1);">....pixel data......</span>
<span style="background: rgba(150,0,255,.1);">....................</span>
<span style="background: rgba(150,0,255,.1);">....................</span></code>
  </pre>
</div>

and while I think this is correct, it turns out that...

#### `LoadBitmap` mangles both versions anyway

When the compiled resources are loaded with `LoadBitmap` and drawn [using `BitBlt`](http://parallel.vub.ac.be/education/modula2/technology/Win32_tutorial/bitmaps.html), neither the `rc.exe`-compiled version, nor the `resinator`-compiled version are drawn correctly:

<div style="display: grid; grid-gap: 10px; grid-template-columns: repeat(3, 1fr);">
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;"><img style="image-rendering:pixelated; width:100%;" src="/images/every-rc-exe-bug-quirk-probably/bmp-intended.png" /></div>
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;"><img style="image-rendering:pixelated; width:100%;" src="/images/every-rc-exe-bug-quirk-probably/bmp-rc.png" /></div>
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;"><img style="image-rendering:pixelated; width:100%;" src="/images/every-rc-exe-bug-quirk-probably/bmp-resinator.png" /></div>
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;"><i class="caption">intended image</i></div>
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;"><i class="caption">bitmap resource from <code>rc.exe</code></i></div>
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;"><i class="caption">bitmap resource from <code>resinator</code></i></div>
</div>

My guess/hope is that this a bug in `LoadBitmap`, as I believe the `resinator`-compiled resource should be correct/valid.

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">preprocessor bug/quirk</span>

### Extreme `#pragma code_page` values

The resource-compiler-specific preprocessor directive `#pragma code_page` can be used to alter the [code page](https://en.wikipedia.org/wiki/Code_page) used mid-file. It's used like so:

```c
#pragma code_page(1252) // Windows-1252
// ... bytes from now on are interpreted as Windows-1252 ...

#pragma code_page(65001) // UTF-8
// ... bytes from now on are interpreted as UTF-8 ...
```

The list of possible code pages [can be found here](https://learn.microsoft.com/en-us/windows/win32/intl/code-page-identifiers). If you try to use one that is not valid, `rc.exe` will error with:

```
fatal error RC4214: Codepage not valid:  ignored
```

But what happens if you try to use an extremely large code page value (greater or equal to the max of a `u32`)? Most of the time it errors in the same way as above, but occasionally there's a strange / inexplicable error. Here's a selection of a few:

<div class="short-rc-and-result">
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```c style="display: flex; flex-direction: column; justify-content: center; align-items: center; flex-grow: 1; margin-top: 0;"
#pragma code_page(4294967296)
```

</div>
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```none style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0;"
error RC4212: Codepage not integer:  )
fatal error RC1116: RC terminating after preprocessor errors
```

</div>
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```c style="display: flex; flex-direction: column; justify-content: center; align-items: center; flex-grow: 1; margin-top: 0;"
#pragma code_page(4295032296)
```

</div>
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```none style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0;"
fatal error RC22105: MultiByteToWideChar failed.
```

</div>
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```c style="display: flex; flex-direction: column; justify-content: center; align-items: center; flex-grow: 1; margin-top: 0;"
#pragma code_page(4295032297)
```

</div>
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```none style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0;"
test.rc(2) : error RC2177: constant too big
test.rc(2) : error RC4212: Codepage not integer:  4
fatal error RC1116: RC terminating after preprocessor errors
```

</div>
</div>

#### `resinator`'s behavior

`resinator` treats code pages exceeding the max of a `u32` as a fatal error.

```resinatorerror
test.rc:1:1: error: code page too large in #pragma code_page
#pragma code_page ( 4294967296 )
^~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
```

This is a separate error from the one caused by invalid/unsupported code pages:

```resinatorerror
test.rc:1:1: error: invalid or unknown code page in #pragma code_page
#pragma code_page ( 64999 )
^~~~~~~~~~~~~~~~~~~~~~~~~~~
```

```resinatorerror
test.rc:1:1: error: unsupported code page 'utf7 (id=65000)' in #pragma code_page
#pragma code_page ( 65000 )
^~~~~~~~~~~~~~~~~~~~~~~~~~~
```

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">parser bug/quirk, utterly baffling</span>

### The strange power of the lonely close parenthesis

Likely due to some number expression parsing code gone haywire, a single close parenthesis `)` is occasionally treated as a 'valid' expression, with bizarre consequences.

Similar to what was detailed in ["*`BEGIN` or `{` as filename*"](#begin-or-as-filename), using `)` as a filename has the same interaction as `{` where the preceding token is treated as both the resource type and the filename.

<div class="short-rc-and-result">
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```c style="display: flex; flex-direction: column; justify-content: center; align-items: center; flex-grow: 1; margin-top: 0;"
1 RCDATA )
```

</div>
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```none style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0;"
test.rc(2) : error RC2135 : file not found: RCDATA
```

</div>
</div>

But that's not all; take this, for example, where we define a `RCDATA` resource using a raw data block:

```c
1 RCDATA { 1, ), ), ), 2 }
```

This should very clearly be a syntax error, but it's actually accepted by the Windows RC compiler. What does the RC compiler do, you ask? Well, it just skips right over all the `)`, of course, and the data of this resource ends up as:

<pre style="display: flex; flex-direction: column; justify-content: center; align-items: center; flex-grow: 1; margin-top: 0;">
  <code class="language-none"><span style="font-family:sans-serif; font-style:italic">the 1 (u16 little endian) &rarr;</span> <span style="outline: 1px dashed red;">01 00</span> <span style="outline: 1px dashed orange;">02 00</span> <span style="font-family:sans-serif; font-style:italic">&larr; the 2 (u16 little endian)</span></code>
</pre>

I said 'skip' because that's truly what seems to happen. For example, for resource definitions that take positional parameters like so:

<pre><code class="language-none"><span style="opacity: 50%;">1 DIALOGEX 1, 2, 3, 4 {</span>
  <span class="token_comment">//        &lt;text&gt; &lt;id&gt; &lt;x&gt; &lt;y&gt; &lt;w&gt; &lt;h&gt; &lt;style&gt;</span>
  <span>CHECKBOX</span>  <span class="token_string">"test"</span>,  <span class="token_number">1</span>,  <span class="token_number">2</span>,  <span class="token_number">3</span>,  <span class="token_number">4</span>,  <span class="token_number">5</span>,  <span class="token_number">6</span>
<span style="opacity: 50%;">}</span></code>
</pre>

If you replace the `<id>` parameter (`1`) with `)`, then all the parameters shift over and they get interpreted like this instead:

<pre><code class="language-none"><span style="opacity: 50%;">1 DIALOGEX 1, 2, 3, 4 {</span>
  <span class="token_comment">//        &lt;text&gt;     &lt;id&gt; &lt;x&gt; &lt;y&gt; &lt;w&gt; &lt;h&gt;</span>
  <span>CHECKBOX</span>  <span class="token_string">"test"</span>,  <span class="token_punctuation">)</span>,  <span class="token_number">2</span>,  <span class="token_number">3</span>,  <span class="token_number">4</span>,  <span class="token_number">5</span>,  <span class="token_number">6</span>
<span style="opacity: 50%;">}</span></code>
</pre>

Note also that all of this is only true of the *close parenthesis*. The open parenthesis was not deemed worthy of the same power:

<div class="short-rc-and-result">
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```c style="display: flex; flex-direction: column; justify-content: center; align-items: center; flex-grow: 1; margin-top: 0;"
1 RCDATA { 1, (, 2 }
```

</div>
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```none style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0;"
test.rc(1) : error RC2237 : numeric value expected at 1
test.rc(1) : error RC1013 : mismatched parentheses
```

</div>
</div>

Instead, `(` was [bestowed a different power](#the-strange-power-of-the-sociable-open-parenthesis).

#### `resinator`'s behavior

A single close parenthesis is never a valid expression in `resinator`:

```resinatorerror
test.rc:2:20: error: expected number or number expression; got ')'
  CHECKBOX "test", ), 2, 3, 4, 5, 6
                   ^
test.rc:2:20: note: the Win32 RC compiler would accept ')' as a valid expression, but it would be skipped over and potentially lead to unexpected outcomes
```

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">parser bug/quirk, utterly baffling</span>

### The strange power of the sociable open parenthesis

While the [close parenthesis](#the-strange-power-of-the-lonely-close-parenthesis) has a bug/quirk involving being isolated, the open parenthesis has a bug/quirk regarding being snug up against another token.

This is (somehow) allowed:

```c
1 DIALOGEX 1(, (2, (3(, ((((4(((( {}
```

And in the above case, the parameters are interpreted as if the `(` characters don't exist, e.g. they compile to the values `1`, `2`, `3`, and `4`.

This power of `(` does not have infinite reach, though&mdash;in other places a `(` leads to an mismatched parentheses error as you might expect:

<div class="short-rc-and-result">
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```c style="display: flex; flex-direction: column; justify-content: center; align-items: center; flex-grow: 1; margin-top: 0;"
1 RCDATA { 1, (2, 3, 4 }
```

</div>
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```none style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0;"
test.rc(1) : error RC1013 : mismatched parentheses
```

</div>
</div>

There's no chance I'm interested in bug-for-bug compatibility with this behavior, so I haven't investigated it beyond the shallow examples above. I'm sure there are more strange implications of this bug lurking for those willing to dive deeper.

#### `resinator`'s behavior

An unclosed open parenthesis is always an error `resinator`:

```resinatorerror
test.rc:1:14: error: expected number or number expression; got ','
1 DIALOGEX 1(, (2, (3(, ((((4(((( {}
             ^
```

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">parser bug/quirk</span>

### `NUL` in filenames

If a filename evaluates to a string that contains a `NUL` (`0x00`) character, the Windows RC compiler treats it as a terminator. For example,

```c
1 RCDATA "hello\x00world"
```

will try to read from the file `hello`.

#### `resinator`'s behavior

Any evaluated filename string containing a `NUL` is an error:

```resinatorerror
test.rc:1:10: error: evaluated filename contains a disallowed codepoint: <U+0000>
1 RCDATA "hello\x00world"
         ^~~~~~~~~~~~~~~~
```

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">parser bug/quirk</span>

### Unary operators are an illusion

Typically, unary `+`, `-`, etc. operators are just that&mdash;operators; they are separate tokens that act on other tokens (number literals, variables, etc). However, in the Windows RC compiler, they are not real operators.

---

The unary `-` is included as part of a number literal, not as a distinct operator. This behavior can be confirmed in a rather strange way, taking advantage of a separate quirk described in ["*Number expressions as filenames*"](#number-expressions-as-filenames). When a resource's filename is specified as a number expression, the file path it ultimately looks for is the last number literal in the expression, so for example:

<div class="short-rc-and-result">
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```c style="display: flex; flex-direction: column; justify-content: center; align-items: center; flex-grow: 1; margin-top: 0;"
1 FOO (567 + 123)
```

</div>
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```none style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0;"
test.rc(1) : error RC2135 : file not found: 123
```

</div>
</div>

And if we throw in a unary `-` like so, then it gets included as part of the filename:

<div class="short-rc-and-result">
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```c style="display: flex; flex-direction: column; justify-content: center; align-items: center; flex-grow: 1; margin-top: 0;"
1 FOO (567 + -123)
```

</div>
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```none style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0;"
test.rc(1) : error RC2135 : file not found: -123
```

</div>
</div>

This quirk leads to a few unexpected valid patterns, since `-` on its own is also considered a valid number literal (and it resolves to `0`), so:

```c
1 FOO { 1-- }
```

evaluates to `1-0` and results in `1` being written to the resource's data, while:

```c
1 FOO { "str" - 1 }
```

looks like a string literal minus 1, but it's actually interpreted as 3 separate raw data values (`str`, `-` [which evaluates to 0], and `1`), since commas between data values in a raw data block are optional.

Additionally, it means that otherwise valid looking expressions may not actually be considered valid:

<div class="short-rc-and-result">
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```c style="display: flex; flex-direction: column; justify-content: center; align-items: center; flex-grow: 1; margin-top: 0;"
1 FOO { (-(123)) }
```

</div>
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```none style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0;"
test.rc(1) : error RC1013 : mismatched parentheses
```

</div>
</div>

---

The unary NOT (`~`) works exactly the same as the unary `-` and has all the same quirks. For example, a `~` on its own is also a valid number literal:

<div class="short-rc-and-result">
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```c style="display: flex; flex-direction: column; justify-content: center; align-items: center; flex-grow: 1; margin-top: 0;"
1 FOO { ~ }
```

</div>
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```none style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0;"
Data is a u16 with the value 0xFFFF
```

</div>
</div>

And `~L` (to turn the integer into a `u32`) is valid in the same way that `-L` would be valid:

<div class="short-rc-and-result">
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```c style="display: flex; flex-direction: column; justify-content: center; align-items: center; flex-grow: 1; margin-top: 0;"
1 FOO { ~L }
```

</div>
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```none style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0;"
Data is a u32 with the value 0xFFFFFFFF
```

</div>
</div>


---

The unary `+` is almost entirely a hallucination; it can be used in some places, but not others, without any discernible rhyme or reason.

This is valid (and the parameters evaluate to `1`, `2`, `3`, `4` as expected):

```c
1 DIALOG +1, +2, +3, +4 {}
```

but this is an error:

<div class="short-rc-and-result">
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```c style="display: flex; flex-direction: column; justify-content: center; align-items: center; flex-grow: 1; margin-top: 0;"
1 FOO { +123 }
```

</div>
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```none style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0;"
test.rc(1) : error RC2164 : unexpected value in RCDATA
```

</div>
</div>

and so is this:

<div class="short-rc-and-result">
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```c style="display: flex; flex-direction: column; justify-content: center; align-items: center; flex-grow: 1; margin-top: 0;"
1 DIALOG (+1), 2, 3, 4 {}
```

</div>
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```none style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0;"
test.rc(1) : error RC2237 : numeric value expected at DIALOG
```

</div>
</div>

Because the rules around the unary `+` are so opaque, I am unsure if it shares many of the same properties as the unary `-`. I do know, though, that `+` on its own does not seem to be an accepted number literal in any case I've seen so far.

#### `resinator`'s behavior

`resinator` matches the Windows RC compiler's behavior around unary `-`/`~`, but disallows unary `+` entirely:

```resinatorerror
test.rc:1:10: error: expected number or number expression; got '+'
1 DIALOG +1, +2, +3, +4 {}
         ^
test.rc:1:10: note: the Win32 RC compiler may accept '+' as a unary operator here, but it is not supported in this implementation; consider omitting the unary +
```

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">parser bug/quirk, utterly baffling</span>

### `CONTROL`: "I'm just going to pretend I didn't see that"

Within `DIALOG`/`DIALOGEX` resources, there are predefined controls like `PUSHBUTTON`, `CHECKBOX`, etc, which are actually just syntactic sugar for generic `CONTROL` statements with particular default values for the "class name" and "style" parameters.

For example, these two statements are equivalent:

<pre class="annotated-code"><code class="language-c" style="white-space: inherit;"><span class="annotation"><span class="desc">class<i></i></span><span class="subject"><span class="token_identifier">CHECKBOX</span></span></span><span class="token_punctuation">,</span> <span class="annotation"><span class="desc">text<i></i></span><span class="subject"><span class="token_string">"foo"</span></span></span><span class="token_punctuation">,</span> <span class="annotation"><span class="desc">id<i></i></span><span class="subject"><span class="token_number">1</span></span></span><span class="token_punctuation">,</span> <span class="annotation"><span class="desc">x<i></i></span><span class="subject"><span class="token_number">2</span></span></span><span class="token_punctuation">,</span> <span class="annotation"><span class="desc">y<i></i></span><span class="subject"><span class="token_number">3</span></span></span><span class="token_punctuation">,</span> <span class="annotation"><span class="desc">w<i></i></span><span class="subject"><span class="token_number">4</span></span></span><span class="token_punctuation">,</span> <span class="annotation"><span class="desc">h<i></i></span><span class="subject"><span class="token_number">5</span></span></span></code></pre>

<pre class="annotated-code"><code class="language-c" style="white-space: inherit;"><span class="annotation"><span class="desc">class<i></i></span><span class="subject"><span class="token_identifier">CONTROL</span></span></span><span class="token_punctuation">,</span> <span class="token_string">"foo"</span><span class="token_punctuation">,</span> <span class="token_number">1</span><span class="token_punctuation">,</span> <span class="annotation"><span class="desc">class name<i></i></span><span class="subject"><span class="token_identifier">BUTTON</span></span></span><span class="token_punctuation">,</span> <span class="annotation"><span class="desc">style<i></i></span><span class="subject"><span class="token_identifier">BS_CHECKBOX</span> <span class="token_operator">|</span> <span class="token_identifier">WS_TABSTOP</span></span></span><span class="token_punctuation">,</span> <span class="token_number">2</span><span class="token_punctuation">,</span> <span class="token_number">3</span><span class="token_punctuation">,</span> <span class="token_number">4</span><span class="token_punctuation">,</span> <span class="token_number">5</span></code></pre>

There is something bizarre about the "style" parameter of a generic control statement, though. For whatever reason, it allows an extra token within it and will act as if it doesn't exist.

<pre style="margin-top: 3em; overflow: visible; white-space: pre-wrap;"><code class="language-c" style="white-space: inherit;"><span style="opacity:50%;">CONTROL, "text", 1, BUTTON,</span> <span style="outline:2px dotted blue; position:relative; display:inline-block;"><span class="token_identifier">BS_CHECKBOX</span> <span class="token_operator">|</span> <span class="token_identifier">WS_TABSTOP</span> <span class="token_string">"why is this allowed"</span><span class="hexdump-tooltip rcdata">style<i></i></span></span><span style="opacity: 50%;">, 2, 3, 4, 5</span></code></pre>

The `"why is this allowed"` string is completely ignored, and this `CONTROL` will be compiled exactly the same as the previous `CONTROL` statement shown above.

- This bug/quirk requires there to be no comma before the extra token. In the above example, if there is a comma between the `BS_CHECKBOX | WS_TABSTOP` and the `"why is this allowed"`, then it will (properly) error with `expected numerical dialog constant`
- This bug/quirk is specific to the `style` parameter of `CONTROL` statements. In non-generic controls, the style parameter is optional and comes after the `h` parameter, but it does not exhibit this behavior

The extra token can be many things (string, number, `=`, etc), but not *anything*. For example, if the extra token is `;`, then it will error with `expected numerical dialog constant`.

#### `CONTROL`: "Okay, I see that expression, but I don't understand it"

Instead of a single extra token in the `style` parameter of a `CONTROL`, it's also possible to stick an extra number expression in there like so:

<pre style="margin-top: 3em; overflow: visible; white-space: pre-wrap;"><code class="language-c" style="white-space: inherit;"><span style="opacity:50%;">CONTROL, "text", 1, BUTTON,</span> <span style="outline:2px dotted blue; position:relative; display:inline-block;"><span class="token_identifier">BS_CHECKBOX</span> <span class="token_operator">|</span> <span class="token_identifier">WS_TABSTOP</span> <span class="token_punctuation">(</span><span class="token_number">7</span><span class="token_operator">+</span><span class="token_number">8</span><span class="token_punctuation">)</span><span class="hexdump-tooltip rcdata">style<i></i></span></span><span style="opacity: 50%;">, 2, 3, 4, 5</span></code></pre>

In this case, the Windows RC compiler no longer ignores the expression, but still behaves strangely. Instead of the entire `(7+8)` expression being treated as the `x` parameter like you might expect, in this case *only the* `8` in the expression is treated as the `x` parameter, so it ends up interpreted like this:

<pre class="annotated-code"><code class="language-c" style="white-space: inherit;"><span style="opacity:50%;">CONTROL, "text", 1, BUTTON,</span> <span class="annotation"><span class="desc">style<i></i></span><span class="subject"><span class="token_identifier">BS_CHECKBOX</span> <span class="token_operator">|</span> <span class="token_identifier">WS_TABSTOP</span></span></span> <span style="opacity:50%;">(7+</span><span class="annotation"><span class="desc">x<i></i></span><span class="subject"><span class="token_number">8</span></span></span><span style="opacity:50%;">)</span><span class="token_punctuation">,</span> <span class="annotation"><span class="desc">y<i></i></span><span class="subject"><span class="token_number">2</span></span></span><span class="token_punctuation">,</span> <span class="annotation"><span class="desc">w<i></i></span><span class="subject"><span class="token_number">3</span></span></span><span class="token_punctuation">,</span> <span class="annotation"><span class="desc">h<i></i></span><span class="subject"><span class="token_number">4</span></span></span><span class="token_punctuation">,</span> <span class="annotation"><span class="desc">exstyle<i></i></span><span class="subject"><span class="token_number">5</span></span></span></code></pre>

My guess is that the similarity between this number-expression-related-behavior and ["*Number expressions as filenames*"](#number-expressions-as-filenames) is not a coincidence.

#### `resinator`'s behavior

Such extra tokens/expressions are never ignored by `resinator`; they are always treated as the `x` parameter, and a warning is emitted if there is no comma between the `style` and `x` parameters.

```resinatorerror
test.rc:4:57: warning: this token could be erroneously skipped over by the Win32 RC compiler
  CONTROL, "text", 1, BUTTON, 0x00000002L | 0x00010000L "why is this allowed", 2, 3, 4, 5
                                                        ^~~~~~~~~~~~~~~~~~~~~
test.rc:4:57: note: this line originated from line 4 of file 'test.rc'
  CONTROL, "text", 1, BUTTON, BS_CHECKBOX | WS_TABSTOP "why is this allowed", 2, 3, 4, 5

test.rc:4:31: note: to avoid the potential miscompilation, consider adding a comma after the style parameter
  CONTROL, "text", 1, BUTTON, 0x00000002L | 0x00010000L "why is this allowed", 2, 3, 4, 5
                              ^~~~~~~~~~~~~~~~~~~~~~~~~
test.rc:4:57: error: expected number or number expression; got '"why is this allowed"'
  CONTROL, "text", 1, BUTTON, 0x00000002L | 0x00010000L "why is this allowed", 2, 3, 4, 5
                                                        ^~~~~~~~~~~~~~~~~~~~~
```

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">parser bug/quirk</span>

### L is not allowed there

Like in C, an integer literal can be suffixed with `L` to signify that it is a 'long' integer literal. In the case of the Windows RC compiler, integer literals are typically 16 bits wide, and suffixing an integer literal with `L` will instead make it 32 bits wide.

<div class="short-rc-and-result">
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

<pre style="display: flex; flex-direction: column; justify-content: center; align-items: center; flex-grow: 1; margin-top: 0;">
  <code class="language-c"><span class="token_number">1</span><span class="token_ansi_c_whitespace token_whitespace"> </span><span class="token_identifier">RCDATA</span><span class="token_ansi_c_whitespace token_whitespace"> </span><span class="token_punctuation">{</span><span class="token_ansi_c_whitespace token_whitespace"> </span><span class="token_number" style="outline: 1px dashed red; padding: 0 3px;">1</span><span class="token_punctuation">,</span><span class="token_ansi_c_whitespace token_whitespace"> </span><span class="token_number" style="outline: 1px dashed orange; padding: 0 3px;">2L</span><span class="token_ansi_c_whitespace token_whitespace"> </span><span class="token_punctuation">}</span><span class="token_ansi_c_whitespace token_whitespace">
</span></code>
</pre>

</div>
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

<pre style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0;">
  <code class="language-none"><span style="outline: 1px dashed red;">01 00</span> <span style="outline: 1px dashed orange;">02 00 00 00</span></code>
</pre>

</div>
</div>
<p style="margin:0; text-align: center;"><i class="caption">A <code>RCDATA</code> resource definition and a hexdump of the resulting data in the <code>.res</code> file</i></p>

However, outside of raw data blocks like the `RCDATA` example above, the `L` suffix is typically meaningless, as it has no bearing on the size of the integer used. For example, `DIALOG` resources have `x`, `y`, `width`, and `height` parameters, and they are each encoded in the data as a `u16` regardless of the integer literal used. If the value would overflow a `u16`, then the value is truncated back down to a `u16`, meaning in the following example all 4 parameters after `DIALOG` get compiled down to `1` as a `u16`:

```c
1 DIALOG 1, 1L, 65537, 65537L {}
```

A few particular parameters, though, fully disallow integer literals with the `L` suffix from being used:

- Any of the four parameters of the `FILEVERSION` statement of a `VERSIONINFO` resource
- Any of the four parameters of the `PRODUCTVERSION` statement of a `VERSIONINFO` resource
- Any of the two parameters of a `LANGUAGE` statement

<div class="short-rc-and-result">
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```c style="display: flex; flex-direction: column; justify-content: center; align-items: center; flex-grow: 1; margin-top: 0;"
LANGUAGE 1L, 2
```

</div>
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```none style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0;"
test.rc(1) : error RC2145 : PRIMARY LANGUAGE ID too large
```

</div>
</div>

<div class="short-rc-and-result">
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```c style="display: flex; flex-direction: column; justify-content: center; align-items: center; flex-grow: 1; margin-top: 0;"
1 VERSIONINFO
  FILEVERSION 1L, 2, 3, 4
BEGIN
END
```

</div>
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```none style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0; justify-content: center;"
test.rc(2) : error RC2127 : version WORDs separated by commas expected
```

</div>
</div>

It is true that these parameters are limited to `u16`, so using an `L` suffix is likely a mistake, but that is also true of many other parameters for which the Windows RC compiler happily allows `L` suffixed numbers for. It's unclear why these particular parameters are singled out, and even more unclear given the fact that specifying these parameters using an integer literal that would overflow a `u16` does not actually trigger an error (and instead it truncates the values to a `u16`):

```c
1 VERSIONINFO
  FILEVERSION 65537, 65538, 65539, 65540
BEGIN
END
```

The compiled `FILEVERSION` in this case will be `1`, `2`, `3`, `4`:

```
65537 = 0x10001; truncated to u16 = 0x0001
65538 = 0x10002; truncated to u16 = 0x0002
65539 = 0x10003; truncated to u16 = 0x0003
65540 = 0x10004; truncated to u16 = 0x0004
```

#### `resinator`'s behavior

`resinator` allows `L` suffixed integer literals everywhere and truncates the value down to the appropriate number of bits when necessary.

```resinatorerror
test.rc:1:10: warning: this language parameter would be an error in the Win32 RC compiler
LANGUAGE 1L, 2
         ^~
test.rc:1:10: note: to avoid the error, remove any L suffixes from numbers within the parameter
```

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">miscompilation, crash</span>

### No one has thought about `FONT` resources for decades

As far as I can tell, the `FONT` resource has exactly one purpose: creating `.fon` files, which are resource-only `.dll`s (i.e. a `.dll` with resources, but no entry point) renamed to have a `.fon` extension. Such `.fon` files contain a collection of fonts in the obsolete `.fnt` font format.

The `.fon` format is also mostly obsolete, but is still supported in modern Windows, and Windows *still* ships with some `.fon` files included:

<div style="text-align: center;">
<img style="margin-left:auto; margin-right:auto; display: block;" src="/images/every-rc-exe-bug-quirk-probably/windows-10-fon.png">
<p style="margin-top: .5em;"><i class="caption">The <code>Terminal</code> font included in Windows 10 is a <code>.fon</code> file</i></p>
</div>

This `.fon`-related purpose for the `FONT` resource, however, has been irrelevant for decades, and, as far as I can tell, has not worked fully correctly since the 16-bit version of the Windows RC compiler. To understand why, though, we have to understand a little bit about the `.fnt` format.

In version 1 of the `.fnt` format, specified by the [Windows 1.03 SDK from 1986](https://www.os2museum.com/files/docs/win10sdk/windows-1.03-sdk-prgref-1986.pdf), the total size of all the static fields in the header was 117 bytes, with a few fields containing offsets to variable-length data elsewhere in the file. Here's a (truncated) visualization, with some relevant 'offset' fields expanded:

<pre><code class="language-none" style="margin: 0 auto; width: fit-content; display:block;"><span style="background: rgba(0,255,0,.1);">....version....</span>
<span style="background: rgba(0,0,255,.1);">......size.....</span>
<span style="background: rgba(150,0,255,.1);">...copyright...</span>
<span style="background: rgba(0,255,0,.1);">......type.....</span>
<span style="background: rgba(150,150,150,.1);">. . . etc . . .</span>
<span style="background: rgba(150,150,150,.1);">. . . etc . . .</span>
<span style="background: rgba(0,0,255,.1); outline: 2px dotted rgba(50,50,255,1);">.device_offset.</span> ───► <span style="background: rgba(0,0,255,.1); outline: 2px dotted rgba(50,50,255,1);">NUL-terminated device name.</span>
<span style="background: rgba(150,0,255,.1); outline: 2px dotted rgba(150,50,255,1);">..face_offset..</span> ───► <span style="background: rgba(150,0,255,.1); outline: 2px dotted rgba(150,50,255,1);">NUL-terminated font face name.</span>
<span style="background: rgba(0,255,0,.1);">....bits_ptr...</span>
<span style="background: rgba(0,0,255,.1);">..bits_offset..</span></code></pre>

In [version 3 of the `.fnt` format](https://web.archive.org/web/20080115184921/http://support.microsoft.com/kb/65123) (and presumably version 2, but I can't find much info about version 2), all of the fields up to and including `bits_offset` are the same, but there are an additional 31 bytes of new fields, making for a total size of 148 bytes:  

<pre><code class="language-none" style="margin: 0 auto; width: fit-content; display:block;"><span style="opacity: 0.5"><span style="background: rgba(0,255,0,.1);">....version....</span>
<span style="background: rgba(150,150,150,.1);">. . . etc . . .</span>
<span style="background: rgba(150,150,150,.1);">. . . etc . . .</span>
<span style="background: rgba(0,0,255,.1);">.device_offset.</span>
<span style="background: rgba(150,0,255,.1);">..face_offset..</span>
<span style="background: rgba(0,255,0,.1);">....bits_ptr...</span>
<span style="background: rgba(0,0,255,.1);">..bits_offset..</span></span>
<span style="background: rgba(150,0,255,.1);">....reserved...</span> ◄─┐
<span style="background: rgba(0,255,0,.1);">.....flags.....</span> ◄─┤
<span style="background: rgba(0,0,255,.1);">.....aspace....</span> ◄─┤
<span style="background: rgba(150,0,255,.1);">.....bspace....</span> ◄─┼── new fields
<span style="background: rgba(0,255,0,.1);">.....cspace....</span> ◄─┤
<span style="background: rgba(0,0,255,.1);">...color_ptr...</span> ◄─┤
<span style="background: rgba(150,0,255,.1);">...reserved1...</span>   │
<span style="background: rgba(150,0,255,.1);">...............</span> ◄─┘
<span style="background: rgba(150,0,255,.1);">...............</span></code></pre>

Getting back to resource compilation. `FONT` resources within `.rc` files are collected and compiled into the following resources:

- A `RT_FONT` resource for each font, where the data is the verbatim file contents of the `.fnt` file
- A `FONTDIR` resource that contains data about each font, in the format specified by [`FONTGROUPHDR`](https://learn.microsoft.com/en-us/windows/win32/menurc/fontgrouphdr)
  + side note: the string `FONTDIR` is the type of this resource, it doesn't have an associated integer ID like most other Windows-defined resources do

Within the `FONTDIR` resource, there is a [`FONTDIRENTRY`](https://learn.microsoft.com/en-us/windows/win32/menurc/fontdirentry) for each font, containing much of the information in the `.fnt` header. In fact, the data actually matches the version 1 `.fnt` header almost exactly, with only a few differences at the end:

<pre><code class="language-none" style="margin: 0 auto; width: fit-content; display:block;">.fnt version 1      FONTDIRENTRY
<span></span>
<span style="background: rgba(0,255,0,.1);">....version....</span> == <span style="background: rgba(0,255,0,.1);">...dfVersion...</span>
<span style="background: rgba(0,0,255,.1);">......size.....</span> == <span style="background: rgba(0,0,255,.1);">.....dfSize....</span>
<span style="background: rgba(150,0,255,.1);">...copyright...</span> == <span style="background: rgba(150,0,255,.1);">..dfCopyright..</span>
<span style="background: rgba(0,255,0,.1);">......type.....</span> == <span style="background: rgba(0,255,0,.1);">.....dfType....</span>
<span style="background: rgba(150,150,150,.1);">. . . etc . . .</span> == <span style="background: rgba(150,150,150,.1);">. . . etc . . .</span>
<span style="background: rgba(150,150,150,.1);">. . . etc . . .</span> == <span style="background: rgba(150,150,150,.1);">. . . etc . . .</span>
<span style="background: rgba(0,0,255,.1);">.device_offset.</span> == <span style="background: rgba(0,0,255,.1);">....dfDevice...</span>
<span style="background: rgba(150,0,255,.1);">..face_offset..</span> == <span style="background: rgba(150,0,255,.1);">.....dfFace....</span>
<span style="background: rgba(0,255,0,.1);">....bits_ptr...</span> =? <span style="background: rgba(0,255,0,.1);">...dfReserved..</span>
<span style="background: rgba(0,0,255,.1);">..bits_offset..</span>    <span style="background: rgba(255,0,0,.1);">NUL-terminated device name.</span>
                   <span style="background: rgba(255,150,0,.1);">NUL-terminated font face name.</span></code></pre>
<p style="margin:0; text-align: center;"><i class="caption">The formats match, except <code>FONTDIRENTRY</code> does not include <code>bits_offset</code> and instead it has trailing variable-length strings</i></p>

This documented `FONTDIRENTRY` *is* what the obsolete 16-bit version of `rc.exe` outputs: 113 bytes plus two variable-length `NUL`-terminated strings at the end. However, starting with the 32-bit resource compiler, contrary to the documentation, `rc.exe` now outputs `FONTDIRENTRY` as 148 bytes plus the two variable-length `NUL`-terminated strings.

You might notice that this 148 number has come up before; it's the size of the `.fnt` version 3 header. So, starting with the 32-bit `rc.exe`, `FONTDIRENTRY` as-written-by-the-resource-compiler is effectively the first 148 bytes of the `.fnt` file, plus the two strings located at the positions given by the `device_offset` and `face_offset` fields. Or, at least, that's clearly the intention, but this is labeled 'miscompilation' for a reason.

Let's take this example `.fnt` file for instance:

<pre><code class="language-none" style="margin: 0 auto; width: fit-content; display:block;"><span style="background: rgba(0,255,0,.1);">....version....</span>
<span style="background: rgba(150,150,150,.1);">. . . etc . . .</span>
<span style="background: rgba(150,150,150,.1);">. . . etc . . .</span>
<span style="background: rgba(0,0,255,.1); outline: 2px dotted rgba(50,50,255,1);">.device_offset.</span> ───► <span style="background: rgba(0,0,255,.1); outline: 2px dotted rgba(50,50,255,1);">some device.</span>
<span style="background: rgba(150,0,255,.1); outline: 2px dotted rgba(150,50,255,1);">..face_offset..</span> ───► <span style="background: rgba(150,0,255,.1); outline: 2px dotted rgba(150,50,255,1);">some font face.</span>
<span style="background: rgba(150,150,150,.1);">. . . etc . . .</span>
<span style="background: rgba(150,150,150,.1);">. . . etc . . .</span>
<span style="background: rgba(150,0,255,.1);">...reserved1...</span>
<span style="background: rgba(150,0,255,.1);">...............</span>
<span style="background: rgba(150,0,255,.1);">...............</span></code></pre>

When compiled with the old 16-bit Windows RC compiler, `some device` and `some font face` are written as trailing strings in the `FONTDIRENTRY` (as expected), but when compiled with the modern `rc.exe`, both strings get written as 0-length (only a `NUL` terminator). The reason why is rather silly, so let's go through it. Here's the documented `FONTDIRENTRY` format again, this time with some annotations:

<pre><code class="language-none" style="margin: 0 auto; width: fit-content; display:block;">      FONTDIRENTRY
<span></span>
-113 <span style="background: rgba(0,255,0,.1);">...dfVersion...</span> (2 bytes)
-111 <span style="background: rgba(0,0,255,.1);">.....dfSize....</span> (4 bytes)
-107 <span style="background: rgba(150,0,255,.1);">..dfCopyright..</span> (60 bytes)
 -47 <span style="background: rgba(0,255,0,.1);">.....dfType....</span> (2 bytes)
     <span style="background: rgba(150,150,150,.1);">. . . etc . . .</span>
     <span style="background: rgba(150,150,150,.1);">. . . etc . . .</span>
 -12 <span style="background: rgba(0,0,255,.1); outline: 2px dotted rgba(50,50,255,1);">....dfDevice...</span> (4 bytes)
  -8 <span style="background: rgba(150,0,255,.1); outline: 2px dotted rgba(150,50,255,1);">.....dfFace....</span> (4 bytes)
  -4 <span style="background: rgba(0,255,0,.1);">...dfReserved..</span> (4 bytes)</code></pre>
<p style="margin:0; text-align: center;"><i class="caption">The numbers on the left represent the offset from the end of the <code>FONTDIRENTRY</code> data to the start of the field</i></p>

It turns out that the Windows RC compiler uses the offset *from the end of `FONTDIRENTRY`* to get the values of the `dfDevice` and `dfFace` fields. This works fine when those offsets are unchanging, but, as we've seen, the Windows RC compiler now uses an undocumented `FONTDIRENTRY` definition that is is 35 bytes longer, but these hardcoded offsets were never updated accordingly. This means that the Windows RC compiler is actually attempting to read the `dfDevice` and `dfFace` fields from this part of the `.fnt` version 3 header:

<pre><code class="language-none" style="margin: 0 auto; width: fit-content; display:block;">    <span style="background: rgba(0,255,0,.1);">....version....</span>
    <span style="background: rgba(150,150,150,.1);">. . . etc . . .</span>
    <span style="background: rgba(150,150,150,.1);">. . . etc . . .</span>
    <span style="background: rgba(0,0,255,.1);">.device_offset.</span>
    <span style="background: rgba(150,0,255,.1);">..face_offset..</span>
    <span style="background: rgba(150,150,150,.1);">. . . etc . . .</span>
    <span style="background: rgba(150,150,150,.1);">. . . etc . . .</span>
-12 <span style="background: rgba(150,0,255,.1); outline: 2px dotted rgba(255,50,50,1);">...reserved1...</span> ───► <span style="background: rgba(255,0,0,.1); outline: 2px dotted rgba(255,50,50,1);">???</span>
 -8 <span style="background: rgba(150,0,255,.1); outline: 2px dotted rgba(255,150,0,1);">...............</span> ───► <span style="background: rgba(255,150,0,.1); outline: 2px dotted rgba(255,150,0,1);">???</span>
 -4 <span style="background: rgba(150,0,255,.1);">...............</span></code></pre>
<p style="margin:0; text-align: center;"><i class="caption">The Windows RC compiler reads data from the <code>reserved1</code> field and interprets it as <code>dfDevice</code> and <code>dfFace</code></i></p>

Because this bug happens to end up reading data from a reserved field, it's very likely for that data to just contain zeroes, which means it will try to read the `NUL`-terminated strings starting at offset `0` from the start of the file. As a second coincidence, the first field of a `.fnt` file is a `u16` containing the version, and the only versions I'm aware of are:

- Version 1, `0x0100` encoded as little-endian, so the bytes at offset 0 are `00 01`
- Version 2, `0x0200` encoded as little-endian, so the bytes at offset 0 are `00 02`
- Version 3, `0x0300` encoded as little-endian, so the bytes at offset 0 are `00 03`

In all three cases, the first byte is `0x00`, meaning attempting to read a `NUL` terminated string from offset `0` always ends up with a 0-length string for all known/valid `.fnt` versions. So, in practice, the Windows RC compiler almost always writes the trailing `szDeviceName` and `szFaceName` strings as 0-length strings.

<p><aside class="note">

As a final coincidence, the offset here is `-12` and `-8` only because the original `FONTDIRENTRY` definition chose to omit the `bits_offset` field from the `.fnt` version 1 format. If it contained the full `.fnt` version 1 header data, the `dfDevice` offset would have been `-16`, meaning it would have ended up interpreting the `color_ptr` field of the `.fnt` version 3 format as an offset instead, likely leading to more bogus (&gt; 0-length) strings being written to the trailing data (and therefore possibly leading to this bug being found/fixed earlier).

</aside></p>

This behavior can be confirmed by crafting a `.fnt` file with actual offsets to `NUL`-terminated strings within the reserved data field that the Windows RC compiler erroneously reads from:

<pre><code class="language-none" style="margin: 0 auto; width: fit-content; display:block;"><span style="background: rgba(0,255,0,.1);">....version....</span>
<span style="background: rgba(150,150,150,.1);">. . . etc . . .</span>
<span style="background: rgba(150,150,150,.1);">. . . etc . . .</span>
<span style="background: rgba(0,0,255,.1); outline: 2px dotted rgba(50,50,255,1);">.device_offset.</span> ───► <span style="background: rgba(0,0,255,.1); outline: 2px dotted rgba(50,50,255,1);">some device.</span>
<span style="background: rgba(150,0,255,.1); outline: 2px dotted rgba(150,50,255,1);">..face_offset..</span> ───► <span style="background: rgba(150,0,255,.1); outline: 2px dotted rgba(150,50,255,1);">some font face.</span>
<span style="background: rgba(150,150,150,.1);">. . . etc . . .</span>
<span style="background: rgba(150,150,150,.1);">. . . etc . . .</span>
<span style="background: rgba(150,0,255,.1); outline: 2px dotted rgba(255,50,50,1);">...reserved1...</span> ───► <span style="background: rgba(255,0,0,.1); outline: 2px dotted rgba(255,50,50,1);">i dare you to read me.</span>
<span style="background: rgba(150,0,255,.1); outline: 2px dotted rgba(255,150,0,1);">...............</span> ───► <span style="background: rgba(255,150,0,.1); outline: 2px dotted rgba(255,150,0,1);">you wouldn't.</span>
<span style="background: rgba(150,0,255,.1);">...............</span></code></pre>

Compiling such a `FONT` resource, we do indeed see that the strings `i dare you to read me` and `you wouldn't` are written to the `FONTDIRENTRY` for this `FONT` rather than `some device` and `some font face`.

#### Does any of this even matter?

Well, no, not really. The whole concept of the `FONTDIR` containing information about all the `RT_FONT` resources is something of a historical relic, likely only relevant when resources were constrained enough that having an overview of the font data all in once place allowed for optimization opportunities that made a difference.

From what I can tell, though, on modern Windows, the `FONTDIR` resource is ignored entirely:
- Linker implementations will happily link `.res` files that contain `RT_FONT` resources with no `FONTDIR` resource
- Windows will happily load/install `.fon` files that contain `RT_FONT` resources with no `FONTDIR` resource

However, there are a few caveats...

#### Misuse of the `FONT` resource for non-`.fnt` fonts

I'm not sure how prevalent this is, but it can be forgiven that someone might not realize that `FONT` is only intended to be used with a font format that has been obsolete for multiple decades, and try to use the `FONT` resource with a modern font format.

In fact, there is one Microsoft-provided [`Windows-classic-samples`](https://github.com/microsoft/Windows-classic-samples) example program that uses `FONT` resources with `.ttf` files to include custom fonts in a program: [`Win7Samples/multimedia/DirectWrite/CustomFont`](https://github.com/microsoft/Windows-classic-samples/tree/main/Samples/Win7Samples/multimedia/DirectWrite/CustomFont). This is meant to be an example of using [the DirectWrite APIs described here](https://learn.microsoft.com/en-us/windows/win32/directwrite/custom-font-collections), but this is almost certainly a misuse of the `FONT` resource. [Other examples](https://github.com/microsoft/Windows-classic-samples/tree/main/Samples/DirectWriteCustomFontSets), however, use user-defined resource types for including `.ttf` font files, which seems like the correct choice.

When using non-`.fnt` files with the `FONT` resource, the resulting `FONTDIRENTRY` will be made up of garbage, since it effectively just takes the first 148 bytes of the file and stuffs it into the `FONTDIRENTRY` format. An additional complication with this is that the Windows RC compiler will still try to read `NUL`-terminated strings using the offsets from the `dfDevice` and `dfFace` fields (or at least, where it thinks they are). These offset values, in turn, will have much more variance since the format of `.fnt` and `.ttf` are so different.

This means that using `FONT` with `.ttf` files may lead to errors, since...

#### "Negative" offsets lead to errors

For who knows what reason, the `dfDevice` and `dfFace` values are seemingly treated as signed integers, even though they ostensibly contain an offset from the beginning of the `.fnt` file, so a negative value makes no sense. When the sign bit is set in either of these fields, the Windows RC compiler will error with:

```
fatal error RW1023: I/O error seeking in file
```

This means that, for some subset of valid `.ttf` files (or other non-`.fnt` font formats), the Windows RC compiler will fail with this error.

#### Other oddities and crashes

- If the font file is 140 bytes or fewer, the Windows RC compiler seems to default to a `dfFace` of `0` (as the [incorrect] location of the `dfFace` field is past the end of the file).
- If the file is 75 bytes or smaller with no `0x00` bytes, the `FONTDIR` data for it will be 149 bytes (the first `n` being the bytes from the file, then the rest are `0x00` padding bytes). After that, there will be `n` bytes from the file again, and then a final `0x00`.
- If the file is between 76 and 140 bytes long with no `0x00` bytes, the Windows RC compiler will crash.

#### `resinator`'s behavior

I'm still not quite sure what the best course of action is here. I've [written up the possibilities here](https://squeek502.github.io/resinator/windows/resources/font.html#so-really-what-should-go-in-the-fontdir), and for now I've gone with what I'm calling the "semi-compatibility while avoiding the sharp edges" approach:

> Do something similar enough to the Win32 compiler in the common case, but avoid emulating the buggy behavior where it makes sense. That would look like a `FONTDIRENTRY` with the following format:
>
> - The first 148 bytes from the file verbatim, with no interpretation whatsoever, followed by two `NUL` bytes (corresponding to 'device name' and 'face name' both being zero length strings)
>
> This would allow the `FONTDIR` to match byte-for-byte with the Win32 RC compiler in the common case (since very often the misinterpreted `dfDevice`/`dfFace` will be `0` or point somewhere outside the bounds of the file and therefore will be written as a zero-length string anyway), and only differ in the case where the Win32 RC compiler writes some bogus string(s) to the `szDeviceName`/`szFaceName`.
>
> This also enables the use-case of non-`.FNT` files without any loose ends.

In short: write the new/undocumented `FONTDIRENTRY`, but avoid the crashes, avoid the negative integer-related errors, and always write `szDeviceName` and `szFaceName` as 0-length.

</div>

<div>


<div class="bug-quirk-box">
<span class="bug-quirk-category">parser bug/quirk, utterly baffling</span>

### Subtracting zero can lead to bizarre results

This compiles:

```c
1 DIALOGEX 1, 2, 3, 4 - 0 {}
```

This doesn't:

<div class="short-rc-and-result">
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```c style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0;"
1 DIALOGEX 1, 2, 3, 4-0 {}
```

</div>
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```none style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0;"
test.rc(1) : error RC2112 : BEGIN expected in dialog
```

</div>
</div>

I don't have a complete understanding as to why, but it seems to be related to subtracting the value zero within certain contexts.

Resource definitions that compile:

- `1 RCDATA { 4-0 }`
- `1 DIALOGEX 1, 2, 3, 4--0 {}`
- `1 DIALOGEX 1, 2, 3, 4-(0) {}`

Resource definitions that error:

- `1 DIALOGEX 1, 2, 3, 4-0x0 {}`
- `1 DIALOGEX 1, 2, 3, (4-0) {}`

The only additional information I have is that the following:

```c
1 DIALOGEX 1, 2, 3, 10-0x0+5 {} hello
```

will error, and with the `/verbose` flag set, `rc.exe` will output:

```
test.rc.
test.rc(1) : error RC2112 : BEGIN expected in dialog

Writing DIALOG:1,       lang:0x409,     size 0.
test.rc(1) : error RC2135 : file not found: hello

Writing {}:+5,  lang:0x409,     size 0
```

The verbose output gives us a hint that the Windows RC compiler is interpreting the `+5 {} hello` as a new resource definition like so:

<pre class="annotated-code"><code class="language-c" style="white-space: inherit;"><span class="annotation"><span class="desc">id<i></i></span><span class="subject"><span class="token_number">+5</span></span></span> <span class="annotation"><span class="desc">type<i></i></span><span class="subject"><span class="token_identifier">{}</span></span></span> <span class="annotation"><span class="desc">filename<i></i></span><span class="subject"><span class="token_string">hello</span></span></span></code></pre>

So, somehow, the subtraction of the zero caused the `BEGIN expected in dialog` error, and then the Windows RC compiler immediately restarted its parser state and began parsing a new resource definition from scratch. This doesn't give much insight into why subtracting zero causes an error in the first place, but I thought it was a slightly interesting additional wrinkle.

#### `resinator`'s behavior

`resinator` does not treat subtracting zero as special, and therefore never errors on any expressions that subtract zero.

Ideally, a warning would be emitted in cases where the Windows RC compiler would error, but detecting when that would be the case is not something I'm capable of doing currently.

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

pre.annotated-code {
  overflow: visible; white-space: pre-wrap;
  padding-bottom: calc(1em + 10px);
}
pre.annotated-code span {
  display: inline-block;
}
pre.annotated-code .annotation {
  margin-top: 10px;
}
pre.annotated-code .annotation .subject {
  text-align: center;
  display: block;
}
pre.annotated-code .desc {
  position: relative;
  display: block;
  background: #E6E6E6;
  z-index: 1;
  padding: 0.5em 1em;
  margin-bottom: 15px;
  border: 1px solid #aaa;
  white-space: pre;
  text-align: center;
}
@media (prefers-color-scheme: dark) {
pre.annotated-code .desc {
  background: #242424;
  border-color: #5A5A5A;
}
}
pre.annotated-code .desc i {
  position:absolute;
  top:100%;
  left:50%;
  margin-left:-15px;
  width:30px;
  height:15px;
  overflow:hidden;
}
pre.annotated-code .desc i::after {
  content:'';
  position:absolute;
  width:15px;
  height:15px;
  left:50%;
  transform:translate(-50%,-50%) rotate(-45deg);
  background: #E6E6E6;
  border: 1px solid #aaa;
}
@media (prefers-color-scheme: dark) {
pre.annotated-code .desc i::after {
  background: #242424;
  border-color: #5A5A5A;
}
}

.tooltip-hover .hexdump-tooltip {
  display: none;
}
.tooltip-hover:hover .hexdump-tooltip {
  display: block;
}
.hexdump-tooltip {
  position: absolute;
  background: #E6E6E6;
  top:-15px;
  left:50%;
  transform:translate(-50%,-100%);
  z-index: 1;
  padding: 0.5em 1em;
  border: 1px solid #aaa;
  white-space: pre;
}
.hexdump-tooltip.below {
  top: auto;
  bottom: -15px;
  transform:translate(-50%,100%);
}
@media (prefers-color-scheme: dark) {
.hexdump-tooltip {
  background: #242424;
  border-color: #5A5A5A;
}
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
.hexdump-tooltip.below i {
  top:auto;
  bottom:100%;
}
.hexdump-tooltip i::after {
  content:'';
  position:absolute;
  width:15px;
  height:15px;
  left:50%;
  transform:translate(-50%,-50%) rotate(45deg);
  background: #E6E6E6;
  border: 1px solid #aaa;
}
.hexdump-tooltip.below i::after {
  transform:translate(-50%,50%) rotate(-45deg);
}
@media (prefers-color-scheme: dark) {
.hexdump-tooltip i::after {
  background: #242424;
  border-color: #5A5A5A;
}
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

.bitmappixels {
  display: grid; 
  grid-template-columns: repeat(7, 1fr); 
  grid-template-rows: minmax(50px, 1fr);
  gap: 5px 5px;
  text-align: center;
}
.bitmapcolors {
  display: grid; 
  grid-template-columns: 1fr 6fr; 
  grid-template-rows: 1fr; 
  gap: 5px 5px; 
  grid-template-areas: 
    "colorlabels colortable";
  text-align: center;
}
.bitmapcolors .colortable {
  display: grid; 
  grid-template-columns: 1fr 1fr 1fr; 
  grid-template-rows: 1fr; 
  gap: 5px 5px;
  grid-area: colortable; 
}
.bitmapcolors .colorentry {
  display: grid; 
  grid-template-columns: 1fr 1fr 1fr 1fr; 
  grid-template-rows: minmax(50px, 1fr) minmax(50px, 1fr) minmax(50px, 1fr); 
  gap: 5px 5px; 
  grid-template-areas: 
    "colori colori colori colori"
    ". . . ."
    "finalcolor finalcolor finalcolor finalcolor";
}
.bitmapcolors .colori { grid-area: colori; }
.bitmapcolors .finalcolor { grid-area: finalcolor; }
.bitmapcolors .colorlabels {
  display: grid; 
  grid-template-columns: 1fr; 
  grid-template-rows: minmax(50px, 1fr) minmax(50px, 1fr) minmax(50px, 1fr); 
  gap: 5px 5px; 
  grid-template-areas: 
    "."
    "."
    "."; 
  grid-area: colorlabels; 
  font-style: italic;
}

.bitmapcolors .colorlabels > *, .bitmapcolors .colori, .bitmapcolors .colorentry > *, .bitmappixels > * {
  display: grid;
  align-items: center;
  justify-items: center;
}
.bitmapcolors .textbg, .bitmappixels .textbg {
  background: #ddd;
  border-radius: 1em;
  padding: 0 10px;
}
@media (prefers-color-scheme: dark) {
.bitmapcolors .textbg, .bitmappixels .textbg {
  background: #111;
}
}

@media only screen and (min-width: 900px) {
  .short-rc-and-result {
    display: grid;
    grid-template-columns: 1fr 2fr;
    grid-gap: 10px;
  }
}

.grid-max-2-col {
  --grid-layout-gap: 10px;
  --grid-column-count: 2;
  --grid-item--min-width: 300px;

  --gap-count: calc(var(--grid-column-count) - 1);
  --total-gap-width: calc(var(--gap-count) * var(--grid-layout-gap));
  --grid-item--max-width: calc((100% - var(--total-gap-width)) / var(--grid-column-count));

  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(max(var(--grid-item--min-width), var(--grid-item--max-width)), 1fr));
  grid-gap: var(--grid-layout-gap);
}

pre code .inblock { position:relative; display:inline-block; }
</style>

</div>