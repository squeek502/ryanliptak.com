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

If you have no familiarity with `.rc` files at all, no need to worry&mdash;I have tried to organize this post such that it will get you up to speed as-you-read. However, if you'd instead like to skip around and check out the strangest bugs/quirks, `Ctrl+F` for 'utterly baffling'.

## A brief intro to resource compilers

`.rc` files (resource definition-script files) are scripts that contain both C/C++ preprocessor commands and resource definitions. We'll ignore the preprocessor for now and focus on resource definitions. One possible resource definition might look like this:

<pre class="annotated-code"><code class="language-c" style="white-space: inherit;"><span class="annotation"><span class="desc">id<i></i></span><span class="subject"><span class="token_identifier">1</span></span></span> <span class="annotation"><span class="desc">type<i></i></span><span class="subject"><span class="token_identifier">FOO</span></span></span> <span class="token_punctuation">{</span> <span class="annotation"><span class="desc">data<i></i></span><span class="subject"><span class="token_string">"bar"</span></span></span> <span class="token_punctuation">}</span></code></pre>

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

```rc
1 FOO { "bar" }
```

For user-defined types, the (uppercased) resource type name is written as UTF-16 into the resulting `.res` file, so in this case `FOO` is written as the type of the resource, and the bytes of the string `bar` are written as the resource's data.

So, following from this, let's try wrapping the resource type name in double quotes:

```rc
1 "FOO" { "bar" }
```

Intuitively, you might expect that this doesn't change anything (i.e. it'll still get parsed into `FOO`), but in fact the Windows RC compiler will now include the quotes in the user-defined type name. That is, `"FOO"` will be written as the resource type name in the `.res` file, not `FOO`.

This is because both resource IDs and resource types use special tokenization rules&mdash;they are basically only terminated by whitespace and nothing else (well, not exactly whitespace, it's actually any ASCII character from `0x05` to `0x20` [inclusive]). As an example:

<pre><code class="language-c"><span class="token_identifer">L"\r\n"123abc</span><span class="token_ansi_c_whitespace token_whitespace"> </span><span class="token_identifier">error{OutOfMemory}!?u8</span><span class="token_ansi_c_whitespace token_whitespace"> </span><span class="token_punctuation">{</span><span class="token_ansi_c_whitespace token_whitespace"> </span><span class="token_string">"bar"</span><span class="token_ansi_c_whitespace token_whitespace"> </span><span class="token_punctuation">}</span><span class="token_ansi_c_whitespace token_whitespace">
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

```rc style="display: flex; flex-grow: 1; justify-content: center; align-items: center; margin: 0;"
123
```

</div>
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```c style="display: flex; flex-grow: 1; justify-content: center; align-items: center; margin: 0;"
'1' - '0' = 1
'2' - '0' = 2
'3' - '0' = 3
```

</div>
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```c style="display: flex; flex-grow: 1; justify-content: center; align-items: center; margin: 0;"
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

```rc style="display: flex; flex-grow: 1; justify-content: center; align-items: center; margin: 0;"
1²3
```

</div>
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```c style="display: flex; flex-grow: 1; justify-content: center; align-items: center; margin: 0;"
'²' - '0' = 130
```

</div>
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```c style="display: flex; flex-grow: 1; justify-content: center; align-items: center; margin: 0;"
 1 * 100 =  100
130 * 10 = 1300
   3 * 1 =    3
⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯
           1403
```

</div>
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;"><i class="caption">integer literal</i></div>
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;"><i class="caption">numeric value of the ² "digit"</i></div>
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;"><i class="caption">numeric value of the integer literal</i></div>
</div>

In other words, the `²` is treated as a base-10 "digit" with the value 130 (and `³` would be a base-10 "digit" with the value 131, `၅` ([`U+1045`](https://www.compart.com/en/unicode/U+1045)) would be a base-10 "digit" with the value 4117, etc).

This particular bug/quirk is (presumably) due to the use of the [`iswdigit`](https://learn.microsoft.com/en-us/cpp/c-runtime-library/reference/isdigit-iswdigit-isdigit-l-iswdigit-l) function, and the [same sort of bug/quirk exists with special `COM[1-9]` device names](https://googleprojectzero.blogspot.com/2016/02/the-definitive-guide-on-win32-to-nt.html).

#### `resinator`'s behavior

```resinatorerror
test.rc:2:3: error: non-ASCII digit characters are not allowed in number literals
 1²3
 ^~~
```

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">parser bug/quirk</span>

### `BEGIN` or `{` as filename

Many resource types can get their data from a file, in which case their resource definition will look something like:

```rc
1 ICON "file.ico"
```

Additionally, some resource types (like `ICON`) *must* get their data from a file. When attempting to define an `ICON` resource with a raw data block like so:

```rc
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

```rc
1 ICON { "foo" }
```

```
test.rc(1) : error RC2135 : file not found: ICON

test.rc(2) : error RC2135 : file not found: }
```

Somehow, the filename `{` causes `rc.exe` to think the filename token is actually the preceding token, so it's trying to interpret `ICON` as both the resource type *and* the file path of the resource. Who knows what's going on there.

#### `resinator`'s behavior

In `resinator`, trying to use a raw data block with resource types that don't support raw data is an error, noting that if `{` or `BEGIN` is intended as a filename, it should use a quoted string literal.

```resinatorerror
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

```rc
// Quoted string, reads from the file: bar.txt
1 FOO "bar.txt"

// Unquoted literal, reads from the file: bar.txt
2 FOO bar.txt

// Number literal, reads from the file: 123
3 FOO 123
```

But that's not all, as you can also specify the filename as an arbitrarily complex number expression, like so:

```rc
1 FOO (1 | 2)+(2-1 & 0xFF)
```

The entire `(1 | 2)+(2-1 & 0xFF)` expression, spaces and all, is interpreted as the filename of the resource. Want to take a guess as to which file path it tries to read the data from?

Yes, that's right, `0xFF`!

For whatever reason, `rc.exe` will just take the last number literal in the expression and try to read from a file with that name, e.g. `(1+1)` will try to read from the path `1`, and `1+-1` will try to read from the path `-1` (the `-` sign is part of the number literal token, see ["*Unary operators are an illusion*"](#unary-operators-are-an-illusion)).

#### `resinator`'s behavior

In `resinator`, trying to use a number expression as a filename is an error, noting that a quoted string literal should be used instead. Singular number literals are allowed, though (e.g. `-1`).

```resinatorerror
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

```rc
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

```resinatorerror
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

```rc
// A complete resource definition
1 FOO { "bar" }

// An incomplete resource definition
FOO
```

Then `rc.exe` *will always successfully compile it* (and it won't try to read from the file `FOO`). That is, a single dangling literal at the end of a file is fully allowed, and it is just treated as if it doesn't exist (there's no corresponding resource in the resulting `.res` file).

It also turns out that there are three `.rc` files in [Windows-classic-samples](https://github.com/microsoft/Windows-classic-samples) that rely on this behavior ([1](https://github.com/microsoft/Windows-classic-samples/blob/a47da3d4551b74bb8cc1f4c7447445ac594afb44/Samples/CredentialProvider/cpp/resources.rc), [2](https://github.com/microsoft/Windows-classic-samples/blob/a47da3d4551b74bb8cc1f4c7447445ac594afb44/Samples/Win7Samples/security/credentialproviders/sampleallcontrolscredentialprovider/resources.rc), [3](https://github.com/microsoft/Windows-classic-samples/blob/a47da3d4551b74bb8cc1f4c7447445ac594afb44/Samples/Win7Samples/security/credentialproviders/samplewrapexistingcredentialprovider/resources.rc)), so in order to fully pass [win32-samples-rc-tests](https://github.com/squeek502/win32-samples-rc-tests/), it is necessary to allow a dangling literal at the end of a file.

#### `resinator`'s behavior

`resinator` allows a single dangling literal at the end of a file, but emits a warning:

```resinatorerror
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

```rc
#pragma code_page(1252) // 1252 = Windows-1252
1 RCDATA { "This is interpreted as Windows-1252: €" }

#pragma code_page(65001) // 65001 = UTF-8
2 RCDATA { "This is interpreted as UTF-8: €" }
```

If the above example file is saved as [Windows-1252](https://en.wikipedia.org/wiki/Windows-1252), each `€` is encoded as the byte `0x80`, meaning:
- The `€` (`0x80`) in the `RCDATA` with ID `1` will be interpreted as a `€`
- The `€` (`0x80`) in the `RCDATA` with ID `2` will attempt to be interpreted as UTF-8, but `0x80` is an invalid start byte for a UTF-8 sequence, so it will be replaced during preprocessing with the Unicode replacement character (� or `U+FFFD`)

So, if we run the Windows-1252-encoded file through only the `rc.exe` preprocessor (using the undocumented `rc.exe /p` option), the result is a file with the following contents:

```rc
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

```rc
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

```rc
1 RCDATA { "Ó" }
```

<p><aside class="note">

Note: `Ó` is encoded in [Windows-1252](https://en.wikipedia.org/wiki/Windows-1252) as the byte `0xD3`

</aside></p>

When saved as Windows-1252 (the default code page for the Windows RC compiler), the `0xD3` byte in the string will be interpreted as `Ó` and written to the `.res` as its Windows-1252 representation (`0xD3`).

If the same Windows-1252-encoded file is compiled with the default code page set to UTF-8 (`rc.exe /c65001`), then the `0xD3` byte in the `.rc` file will be an invalid UTF-8 byte sequence and get replaced with � during preprocessing, and because the code page is UTF-8, the *output* in the `.res` file will also be encoded as UTF-8, so the bytes `0xEF 0xBF 0xBD` (the UTF-8 sequence for �) will be written.

This is all pretty reasonable, but things start to get truly bizarre when you add `#pragma code_page` into the mix:

```rc
#pragma code_page(1252)
1 RCDATA { "Ó" }
```

When saved as Windows-1252 and compiled with Windows-1252 as the default code page, this will work the same as described above. However, if we compile the same Windows-1252-encoded `.rc` file with the default code page set to UTF-8 (`rc.exe /c65001`), we see something rather strange:

- The input `0xD3` byte is interpreted as `Ó`, as expected since the `#pragma code_page` changed the code page to 1252
- The output in the `.res` is `0xC3 0x93`, the UTF-8 sequence for `Ó` (instead of the expected `0xD3` which is the Windows-1252 encoding of `Ó`)

That is, the `#pragma code_page` changed the *input* code page, but there is a distinct *output* code page that can be out-of-sync with the input code page. In this instance, the input code page for the `1 RCDATA ...` line is Windows-1252, but the output code page is still the default set from the CLI option (in this case, UTF-8).

Even more bizarre, this disjointedness can only occur via the first `#pragma code_page` directive of the file:

```rc
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
<span class="bug-quirk-category">parser bug/quirk, miscompilation</span>

### Non-ASCII accelerator characters

The [`ACCELERATORS`](https://learn.microsoft.com/en-us/windows/win32/menurc/accelerators-resource) resource can be used to essentially define hotkeys for a program. In the message loop, the `TranslateAccelerator` function can be used to automatically turn the relevant keystrokes into `WM_COMMAND` messages with the associated `idvalue` as the parameter (meaning it can be handled like any other message coming from a menu, button, etc).

Simplified example from [Using Keyboard Accelerators](https://learn.microsoft.com/en-us/windows/win32/menurc/using-keyboard-accelerators):

```rc
1 ACCELERATORS {
  "B", 300, CONTROL, VIRTKEY
}
```

This associates the key combination `Ctrl + B` with the ID `300` which can then be handled in the message loop processing code like this:

```c
// ...
        case WM_COMMAND: 
            switch (LOWORD(wParam)) 
            {
                case 300:
// ...
```

There are also a number of ways to specify the keys for an accelerator, but the one relevant here is specifying "control characters" using a string literal with a `^` character, e.g. `"^B"`.

<p><aside class="note">

Note: There *is* a difference between how `"^B", 300` and `"B", 300, CONTROL, VIRTKEY` are compiled, but in practical terms they seem roughly equivalent (both are triggered by `Ctrl + B` on my keyboard). I'm not familiar enough with the accelerator Win32 APIs to know how exactly they differ or when one should be used over the other.

</aside></p>

When specifying a control character using `^` with an ASCII character that is outside of the range of `A-Z` (case insensitive), the Windows RC compiler will give the following error:

<div class="short-rc-and-result">
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```rc style="display: flex; flex-direction: column; justify-content: center; flex-grow: 1; margin-top: 0;"
1 ACCELERATORS {
  "^!", 300
}
```

</div>
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```none style="display: flex; flex-direction: column; flex-grow: 1; justify-content: center; margin-top: 0;"
test.rc(2) : error RC2154 : control character out of range [^A - ^Z]
```

</div>
</div>

However, contrary to what the error implies, many (but not all) non-ASCII characters outside the `A-Z` range are actually accepted. For example, this is *not* an error (when the file is encoded as UTF-8):

```rc
#pragma code_page(65001)
1 ACCELERATORS {
  "^Ξ", 300
}
```

<p><aside class="note">

My guess is that the allowed codepoints outside the `A-Z` range are due to an inadvertent use of the `iswalpha` function or similar (see [here](https://gist.github.com/squeek502/2e9d0a4728a83eed074ad9785a209fd0) for a list of every non-ASCII codepoint that triggers the `control character out of range` error in the Windows RC compiler).

</aside></p>

When evaluating these `^` strings, the final 'control character' value is determined by subtracting `0x40` from the ASCII uppercased value of the character following the `^`, so in the case of `^b` that would look like:

<div style="display: grid; grid-gap: 10px; grid-template-columns: repeat(3, 1fr);">
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```c style="display: flex; flex-grow: 1; justify-content: center; align-items: center; margin: 0;"
b (0x62)
```

</div>
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```c style="display: flex; flex-grow: 1; justify-content: center; align-items: center; margin: 0;"
B (0x42)
```

</div>
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```c style="display: flex; flex-grow: 1; justify-content: center; align-items: center; margin: 0;"
0x42 - 0x40 = 0x02
```

</div>
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;"><i class="caption">character (hex value)</i></div>
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;"><i class="caption">uppercased (hex value)</i></div>
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;"><i class="caption">control character value</i></div>
</div>

The same process is used for any allowed codepoints outside the `A-Z` range, but the uppercasing is only done for ASCII values, so in the example above with `Ξ` (the codepoint `U+039E`; Greek Capital Letter Xi), the value is calculated like this:

<div style="display: grid; grid-gap: 10px; grid-template-columns: repeat(2, 1fr);">
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```c style="display: flex; flex-grow: 1; justify-content: center; align-items: center; margin: 0;"
Ξ (0x039E)
```

</div>
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```c style="display: flex; flex-grow: 1; justify-content: center; align-items: center; margin: 0;"
0x039E - 0x40 = 0x035E
```

</div>
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;"><i class="caption">codepoint (hex value)</i></div>
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;"><i class="caption">control character value</i></div>
</div>

I believe this is a bogus value, since the final value of a control character is meant to be in the range of `0x01` (`^A`) through `0x1A` (`^Z`), which are treated specially. My assumption is that a value of `0x035E` would just be treated as the Unicode codepoint `U+035E` (Combining Double Macron), but I'm unsure exactly how I would go about testing this assumption since all aspects of the interaction between accelerators and non-ASCII key values are still fully opaque to me.

#### `resinator`'s behavior

In `resinator`, control characters specified as a quoted string with a `^` in an `ACCELERATORS` resource (e.g. `"^C"`) must be in the range of `A-Z` (case insensitive).

```resinatorerror
test.rc:3:3: error: invalid accelerator key '"^Ξ"': ControlCharacterOutOfRange
  "^Ξ", 1
  ^~~~~
```

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">utterly baffling, miscompilation</span>

### Codepoint misbehavior/miscompilation

There are a few different ASCII control characters/Unicode codepoints that cause strange behavior in the Windows RC compiler if they are put certain places in a `.rc` file. Each case is sufficiently different that they might warrant their own section, but I'm just going to lump them together into one section here.

#### U+0000 Null

The Windows RC compiler behaves very strangely when embedded `NUL` (`<0x00>`) characters are in a `.rc` file. Some examples with regards to string literals:

<div class="short-rc-and-result">

<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
  <pre style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0; justify-content: center;"><code class="language-rc" style="white-space: inherit;">1 <span class="token_keyword">RCDATA</span> <span class="token_punctuation">{</span> <span class="token_string">"a</span><span class="token_unrepresentable" title="'NUL' control character">&lt;0x00&gt;</span><span class="token_string">"</span> <span class="token_punctuation">}</span></code></pre>
</div>
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
<div style="display: flex; flex-direction: column; flex-grow: 1; padding: 0.5em; justify-content: center; margin: 0.5em 0; margin-top: 0;"><div>will error with <code>unexpected end of file in string literal</code></div></div></div>

<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
  <pre style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0; justify-content: center;"><code class="language-rc" style="white-space: inherit;">1 <span class="token_keyword">RCDATA</span> <span class="token_punctuation">{</span> <span class="token_string">"</span><span class="token_unrepresentable" title="'NUL' control character">&lt;0x00&gt;</span><span class="token_string">"</span> <span class="token_punctuation">}</span></code></pre>
</div>
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
<div style="display: flex; flex-direction: column; flex-grow: 1; padding: 0.5em; justify-content: center; margin: 0.5em 0; margin-top: 0;"><div>"succeeds" but results in an empty <code>.res</code> file (no <code>RCDATA</code> resource)</div></div></div>

</div>

Even stranger is that the character count of the file seems to matter in some fashion for these examples. The first example has an odd character count, so it errors, but add one more character (or any odd number of characters; doesn't matter what/where they are, can even be whitespace) and it will not error. The second example has an even character count, so adding another character (again, anywhere) would induce the `unexpected end of file in string literal` error.

#### U+0004 End of Transmission

The Windows RC compiler seemingly treats 'End of Transmission' (`<0x04>`) characters outside of string literals as a 'skip the next character' instruction when parsing. This means that:

<div class="gets-parsed-as">
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
<div style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0;">
  <pre><code class="language-rc" style="white-space: inherit;">1 RCDATA<span class="token_unrepresentable" title="'End of Transmission' control character">&lt;0x04&gt;</span>! <span class="token_punctuation">{</span> <span class="token_string">"foo"</span> <span class="token_punctuation">}</span></code></pre>
</div>
</div>
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
<div style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0; justify-content: center; align-items: center; text-align:center;">gets treated as if it were:</div>
</div>
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
<div style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0;">

```rc
1 RCDATA { "foo" }
```

</div>
</div>
</div>

while

<div class="gets-parsed-as">
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
<div style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0;">
  <pre><code class="language-rc" style="white-space: inherit;">1 RCDATA<span class="token_unrepresentable" title="'End of Transmission' control character">&lt;0x04&gt;</span>!?! <span class="token_punctuation">{</span> <span class="token_string">"foo"</span> <span class="token_punctuation">}</span></code></pre>
</div>
</div>
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
<div style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0; justify-content: center; align-items: center;">gets treated as if it were:</div>
</div>
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
<div style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0;">
  <pre><code class="language-rc" style="white-space: inherit;">1 RCDATA?! <span class="token_punctuation">{</span> <span class="token_string">"foo"</span> <span class="token_punctuation">}</span></code></pre>
</div>
</div>
</div>

#### U+007F Delete

The Windows RC compiler seemingly treats 'Delete' (`<0x7F>`) characters as a terminator in some capacity. A few examples:

<div class="short-rc-and-result">

<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
  <pre style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0; justify-content: center;"><code class="language-rc" style="white-space: inherit;">1 RC<span class="token_unrepresentable" title="'Delete' control character">&lt;0x7F&gt;</span>DATA <span class="token_punctuation">{</span><span class="token_punctuation">}</span></code></pre>
</div>
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
<div style="display: flex; flex-direction: column; flex-grow: 1; padding: 0.5em; justify-content: center; margin: 0.5em 0; margin-top: 0;"><div>gets parsed as <code>1 RC DATA {}</code>, leading to the compile error <code>file not found: DATA</code></div></div></div>

<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
  <pre style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0; justify-content: center;"><code class="language-rc" style="white-space: inherit;"><span class="token_unrepresentable" title="'Delete' control character">&lt;0x7F&gt;</span>1 <span class="token_keyword">RCDATA</span> <span class="token_punctuation">{</span><span class="token_punctuation">}</span></code></pre>
</div>
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
<div style="display: flex; flex-direction: column; flex-grow: 1; padding: 0.5em; justify-content: center; margin: 0.5em 0; margin-top: 0;"><div>"succeeds" but results in an empty <code>.res</code> file (no <code>RCDATA</code> resource)</div></div></div>

<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
  <pre style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0; justify-content: center;"><code class="language-rc" style="white-space: inherit;">1 <span class="token_keyword">RCDATA</span> <span class="token_punctuation">{</span> <span class="token_string">"</span><span class="token_unrepresentable" title="'Delete' control character">&lt;0x7F&gt;</span><span class="token_string">"</span> <span class="token_punctuation">}</span></code></pre>
</div>
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
<div style="display: flex; flex-direction: column; flex-grow: 1; padding: 0.5em; justify-content: center; margin: 0.5em 0; margin-top: 0;"><div>fails with <code>unexpected end of file in string literal</code></div></div></div>

</div>

#### U+001A Substitute

The Windows RC compiler treats 'Substitute' (`<0x1A>`) characters as an 'end of file' marker:

<div class="short-rc-and-result">

<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
  <pre style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0; justify-content: center;"><code class="language-rc" style="white-space: inherit;">1 <span class="token_keyword">RCDATA</span> <span class="token_punctuation">{</span><span class="token_punctuation">}</span>
<span class="token_unrepresentable" title="'Substitute' control character">&lt;0x1A&gt;</span>
2 <span class="token_keyword">RCDATA</span> <span class="token_punctuation">{</span><span class="token_punctuation">}</span></code></pre>
</div>
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
<div style="display: flex; flex-direction: column; flex-grow: 1; padding: 0.5em; justify-content: center; margin: 0.5em 0; margin-top: 0;"><div>Only the <code>1 RCDATA {}</code> resource makes it into the <code>.res</code>, everything after the <code>&lt;0x1A&gt;</code> is ignored</div></div></div>

</div>

but use of the `<0x1A>` character can also lead to a (presumed) infinite loop in certain scenarios, like this one:

<pre><code class="language-rc" style="white-space: inherit;">1 <span class="token_keyword">MENUEX</span> <span class="token_keyword">FIXED</span><span class="token_unrepresentable" title="'Substitute' control character">&lt;0x1A&gt;</span><span class="token_keyword">VERSION</span></code></pre>

<p><aside class="note">

Note: C preprocessors also typically treat `<0x1A>` as EOF when they are outside of string literals.

</aside></p>

#### U+0900, U+0A00, U+0A0D, U+0D00, U+2000

The Windows RC compiler will error and/or ignore these codepoints when used outside of string literals, but not always. When used within string literals, the Windows RC compiler will miscompile them in some very bizarre ways.

<p><aside class="note">

Note: In the following example, the string contains the codepoints in this order:

<pre><code class="language-rc"><span class="token_string">"</span><span class="token_unrepresentable" title="Devanagari Sign Inverted Candrabindu">&lt;U+0900&gt;</span><span class="token_unrepresentable" title="<reserved>">&lt;U+0A00&gt;</span><span class="token_unrepresentable" title="<reserved>">&lt;U+0A0D&gt;</span><span class="token_unrepresentable" title="Malayalam Sign Combining Anusvara Above">&lt;U+0D00&gt;</span><span class="token_unrepresentable" title="En Quad">&lt;U+2000&gt;</span><span class="token_string">"</span></code></pre>

</aside></p>

<div class="short-rc-and-result">
  
  <div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```rc style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0; justify-content: center;"
1 RCDATA { "ऀ਀਍ഀ " }
```

  </div>

  <div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
    <div style="display: flex; flex-direction: column; flex-grow: 1; padding: 0.5em; justify-content: center; margin: 0.5em 0; margin-top: 0;"><div>Encoded as UTF-8 and compiled with <code>rc /c65001 test.rc</code>, meaning both the input and output code pages are UTF-8 (see <a href="#the-entirely-undocumented-concept-of-the-output-code-page">"<i>The entirely undocumented concept of the 'output' code page</i>"</a>)</div></div>
  </div>

</div>

The expected result is the resource's data to contain the UTF-8 encoding of each codepoint, one after another, but that is not at all what we get:

<pre><code class="language-none">Expected bytes: <span class="token_unrepresentable" title="UTF-8 encoding of U+0900">E0 A4 80</span> <span class="token_unrepresentable" title="UTF-8 encoding of U+0A00">E0 A8 80</span> <span class="token_unrepresentable" title="UTF-8 encoding of U+0A0D">E0 A8 8D</span> <span class="token_unrepresentable" title="UTF-8 encoding of U+0D00">E0 B4 80</span> <span class="token_unrepresentable" title="UTF-8 encoding of U+2000">E2 80 80</span>

  Actual bytes: <span class="token_unrepresentable" title="Horizontal Tab (\t)">09</span> <span class="token_unrepresentable" title="Space">20</span> <span class="token_unrepresentable" title="New Line (\n)">0A</span> <span class="token_unrepresentable" title="Space">20</span> <span class="token_unrepresentable" title="New Line (\n)">0A</span> <span class="token_unrepresentable" title="Space">20</span></code></pre>

These are effectively the transformations that are being made in this case:

<pre><code class="language-rc"><span class="token_unrepresentable" title="Devanagari Sign Inverted Candrabindu">&lt;U+0900&gt;</span>  <span class="token_function">────►</span>  <span class="token_unrepresentable" title="Horizontal Tab (\t)">09</span>
<span class="token_unrepresentable" title="<reserved>">&lt;U+0A00&gt;</span>  <span class="token_function">────►</span>  <span class="token_unrepresentable" title="Space">20</span> <span class="token_unrepresentable" title="New Line (\n)">0A</span>
<span class="token_unrepresentable" title="<reserved>">&lt;U+0A0D&gt;</span>  <span class="token_function">────►</span>  <span class="token_unrepresentable" title="Space">20</span> <span class="token_unrepresentable" title="New Line (\n)">0A</span>
<span class="token_unrepresentable" title="Malayalam Sign Combining Anusvara Above">&lt;U+0D00&gt;</span>  <span class="token_function">────►</span>  &lt;omitted entirely&gt;
<span class="token_unrepresentable" title="En Quad">&lt;U+2000&gt;</span>  <span class="token_function">────►</span>  <span class="token_unrepresentable" title="Space">20</span></code></pre>

It turns out that all the codepoints have been turned into some combination of whitespace characters: `<0x09>` is `\t`, `<0x20>` is `<space>`, and `<0x0A>` is `\n`. My guess as to what's going on here is that there's some whitespace detection code going seriously haywire, in combination with some sort of endianness heuristic. If we run the example through the preprocessor only (`rc.exe /p /c65001 test.rc`), we can see that things have already gone wrong (note: I've emphasized some whitespace characters):

<pre><code class="language-rc"><span class="token_preprocessor">#line</span><span class="token_rc_whitespace token_whitespace"> </span><span class="token_identifier">1</span><span class="token_rc_whitespace token_whitespace"> </span><span class="token_string">"test.rc"</span><span class="token_rc_whitespace token_whitespace">
</span><span class="token_identifier">1</span><span class="token_rc_whitespace token_whitespace"> </span><span class="token_keyword">RCDATA</span><span class="token_rc_whitespace token_whitespace"> </span><span class="token_punctuation">{</span><span class="token_rc_whitespace token_whitespace"> </span><span class="token_string">"</span><span class="token_unrepresentable" title="Horizontal Tab (\t)">────</span>

<span class="token_unrepresentable" title="Space">·</span><span class="token_string">"</span><span class="token_rc_whitespace token_whitespace"> </span><span class="token_punctuation">}</span><span class="token_rc_whitespace token_whitespace">
</span></code></pre>

There's quite few bugs/quirks interacting here, so I'll do my best to explain.

As detailed in ["*The Windows RC compiler 'speaks' UTF-16*"](#the-windows-rc-compiler-speaks-utf-16), the preprocessor always outputs UTF-16, which means that the preprocessor will interpret the bytes of the file using the current code page and then write them back out as UTF-16. So, with that in mind, let's think about `U+0900`, which erroneously gets transformed to the character `<0x09>` (`\t`):

- In the `.rc` file, `U+0900` is encoded as UTF-8, meaning the bytes in the file are `E0 A4 80`
- The preprocessor will decode those bytes into the codepoint `0x0900` (since we set the code page to UTF-8)

While [integer endianness](https://en.wikipedia.org/wiki/Endianness) is irrelevant for UTF-8, it *is* relevant for UTF-16, since a code unit (`u16`) is 2 bytes wide. It seems possible that, because the Windows RC compiler is so UTF-16-centric, it has some heuristic to infer the endianness of a file, and that heuristic is being triggered for certain whitespace characters. That is, it might be that the Windows RC compiler sees the decoded `0x0900` codepoint and thinks it might be a byteswapped `0x0009`, and therefore *treats it as* `0x0009` (which is a tab character).

This sort of thing would explain some of the changes we see to the preprocessed file:

- `U+0900` could be confused for a byteswapped `<0x09>` (`\t`)
- `U+0A00` could be confused for a byteswapped `<0x0A>` (`\n`)
- `U+2000` could be confused for a byteswapped `<0x20>` (`<space>`)

For `U+0A0D` and `U+0D00`, we need another piece of information: carriage returns (`<0x0D>`, `\r`) are completely ignored by the preprocessor (i.e. <code>RC<span class="token_unrepresentable" title="Carriage Return (\r)">&lt;0x0D&gt;</span>DATA</code> gets interpreted as `RCDATA`). With this in mind:

- `U+0A0D`, ignoring the `0D` part, could be confused for a byteswapped `<0x0A>` (`\n`)
- `U+0D00` could be confused for a byteswapped `<0x0D>` (`\r`), and therefore is ignored

<p><aside class="note">

Note: If this theory is true, then this endianness heuristic is being invoked in an inappropriate step along the preprocessing path, since it's acting on the *decoded codepoint* which no longer has any relationship to the encoding of the file. In other words, the UTF-8 encoding cannot be confused for these whitespace characters&mdash;only the decoded codepoint can be, but the decoded codepoint is an integer with native endianness so there's no longer any reason for an endianness heuristic.

</aside></p>

Now that we have a theory about what might be going wrong in the preprocessor, we can examine the preprocessed version of the example:

<pre><code class="language-rc"><span class="token_preprocessor">#line</span><span class="token_rc_whitespace token_whitespace"> </span><span class="token_identifier">1</span><span class="token_rc_whitespace token_whitespace"> </span><span class="token_string">"test.rc"</span><span class="token_rc_whitespace token_whitespace">
</span><span class="token_identifier">1</span><span class="token_rc_whitespace token_whitespace"> </span><span class="token_keyword">RCDATA</span><span class="token_rc_whitespace token_whitespace"> </span><span class="token_punctuation">{</span><span class="token_rc_whitespace token_whitespace"> </span><span class="token_string">"<span class="token_unrepresentable" title="Horizontal Tab (\t)">────</span>

<span class="token_unrepresentable" title="Space">·</span>"</span><span class="token_rc_whitespace token_whitespace"> </span><span class="token_punctuation">}</span><span class="token_rc_whitespace token_whitespace">
</span></code></pre>

From ["*Multiline strings don't behave as expected/documented*"](#multiline-strings-don-t-behave-as-expected-documented), we know that this string literal&mdash;contrary to the documentation&mdash;is an accepted multiline string literal, and we also know that whitespace in these undocumented string literals is typically collapsed, so the two newlines and the trailing space should become one <code><span class="token_unrepresentable" title="Space">20</span></code> <code><span class="token_unrepresentable" title="New Line (\n)">0A</span></code> sequence. In fact, if we take the output of the preprocessor and copy it into a new file and compile *that*, we get a completely different result that's more in line with what we expect:

<div class="short-rc-and-result">
  
  <div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```rc style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0; justify-content: center;"
1 RCDATA { "	

 " }
```

  </div>

  <div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

<pre style="display: flex; flex-direction: column; flex-grow: 1; padding: 0.5em; justify-content: center; margin: 0.5em 0; margin-top: 0;"><code class="language-none">Compiled data: <span class="token_unrepresentable" title="Space">20</span> <span class="token_unrepresentable" title="Space">20</span> <span class="token_unrepresentable" title="Space">20</span> <span class="token_unrepresentable" title="Space">20</span> <span class="token_unrepresentable" title="Space">20</span> <span class="token_unrepresentable" title="New Line (\n)">0A</span></code></pre>
  </div>

</div>

As detailed in ["*The column of a tab character matters*"](#the-column-of-a-tab-character-matters), an embedded tab character gets converted to a variable number of spaces depending on which column it's at in the file. It just so happens that it gets converted to 4 spaces in this case, and the remaining <code><span class="token_unrepresentable" title="Space">20</span></code> <code><span class="token_unrepresentable" title="New Line (\n)">0A</span></code> is the collapsed whitespace following the tab character.

However, what we actually see when compiling the `1 RCDATA { "ऀ਀਍ഀ " }` example is:

<pre><code class="language-none"><span class="token_unrepresentable" title="Horizontal Tab (\t)">09</span> <span class="token_unrepresentable" title="Space">20</span> <span class="token_unrepresentable" title="New Line (\n)">0A</span> <span class="token_unrepresentable" title="Space">20</span> <span class="token_unrepresentable" title="New Line (\n)">0A</span> <span class="token_unrepresentable" title="Space">20</span></code></pre>

where these transformations are occurring:

<pre><code class="language-rc"><span class="token_unrepresentable" title="Devanagari Sign Inverted Candrabindu">&lt;U+0900&gt;</span>  <span class="token_function">────►</span>  <span class="token_unrepresentable" title="Horizontal Tab (\t)">09</span>
<span class="token_unrepresentable" title="<reserved>">&lt;U+0A00&gt;</span>  <span class="token_function">────►</span>  <span class="token_unrepresentable" title="Space">20</span> <span class="token_unrepresentable" title="New Line (\n)">0A</span>
<span class="token_unrepresentable" title="<reserved>">&lt;U+0A0D&gt;</span>  <span class="token_function">────►</span>  <span class="token_unrepresentable" title="Space">20</span> <span class="token_unrepresentable" title="New Line (\n)">0A</span>
<span class="token_unrepresentable" title="Malayalam Sign Combining Anusvara Above">&lt;U+0D00&gt;</span>  <span class="token_function">────►</span>  &lt;omitted entirely&gt;
<span class="token_unrepresentable" title="En Quad">&lt;U+2000&gt;</span>  <span class="token_function">────►</span>  <span class="token_unrepresentable" title="Space">20</span></code></pre>

So it seems that something about when this bug/quirk takes place in the compiler pipeline affects how the preprocessor/compiler treats the input/output.

- Normally, an embedded tab character will get converted to spaces during compilation, but even though the Windows RC compiler seems to *think* `<U+0900>` is an embedded tab character, it gets compiled into `<0x09>` rather than converted to space characters.
- Normally, an undocumented-but-accepted multiline string literal has its whitespace collapsed, but even though the Windows RC compiler seems to *think* `<U+0A00>` and `<U+0A0D>` are new lines and `<U+2000>` is a space, it doesn't collapse them.

So, to summarize, these codepoints likely confuse the Windows RC compiler into thinking they are whitespace, and the compiler treats them as the whitespace character in some ways, but introduces novel behavior for those characters in other ways. In any case, this is a miscompilation, because these codepoints have no *real* relationship to the whitespace characters the Windows RC compiler mistakes them for.

#### U+FEFF Byte Order Mark

For the most part, the Windows RC compiler skips over `<U+FEFF>` ([byte-order mark or BOM](https://codepoints.net/U+FEFF)) everywhere, even within string literals, within names, etc. (e.g. `RC<U+FEFF>DATA` will compile as if it were `RCDATA`). However, there are edge cases where a BOM will cause cryptic and unexplained errors, like this:

<div class="short-rc-and-result">

<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
  <pre style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0; justify-content: center;"><code class="language-rc" style="white-space: inherit;"><span class="token_preprocessor">#pragma</span><span class="token_rc_whitespace token_whitespace"> </span><span class="token_identifier">code_page</span><span class="token_punctuation">(</span><span class="token_identifier">65001</span><span class="token_punctuation">)</span>
1 <span class="token_keyword">RCDATA</span> <span class="token_punctuation">{</span> 1<span class="token_unrepresentable" title="'Byte-Order Mark' Unicode codepoint">&lt;U+FEFF&gt;</span>1 <span class="token_punctuation">}</span></code></pre>
</div>
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```none style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0; justify-content: center;"
test.rc(2) : fatal error RC1011: compiler limit : '1 }
': macro definition too big
```

</div>

</div>

#### U+E000 Private Use Character

This behaves similarly to the byte-order mark (it gets skipped/ignored wherever it is), although `<U+E000>` seems to avoid causing errors like the BOM does.

#### U+FFFE, U+FFFF Noncharacter

The behavior of these codepoints on their own is strange, but it's not the most interesting part about them, so it's up to you if you want to expand this:

<details class="box-border" style="padding: 1em; padding-bottom: 0;">
<summary style="margin-bottom: 1em;">Behavior of U+FFFE and U+FFFF on their own</summary>

<div class="box-border" style="padding: 1em; padding-bottom: 0; margin-bottom: 1em;">

<div class="short-rc-and-result">
  
  <div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
  <pre style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0; justify-content: center;"><code class="language-rc" style="white-space: inherit;">1 <span class="token_keyword">RCDATA</span> <span class="token_punctuation">{</span> <span class="token_string">"</span><span class="token_unrepresentable" title="'Noncharacter' Unicode codepoint">&lt;U+FFFE&gt;</span><span class="token_string">"</span> <span class="token_punctuation">}</span></code></pre>
  </div>

  <div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
    <div style="display: flex; flex-direction: column; flex-grow: 1; padding: 0.5em; justify-content: center; margin: 0.5em 0; margin-top: 0;"><div>Encoded as UTF-8 and compiled with <code>rc /c65001 test.rc</code>, meaning both the input and output code pages are UTF-8 (see <a href="#the-entirely-undocumented-concept-of-the-output-code-page">"<i>The entirely undocumented concept of the 'output' code page</i>"</a>)</div></div>
  </div>

</div>

<pre><code class="language-none">Expected bytes: <span class="token_unrepresentable" title="UTF-8 encoding of U+FFFE">EF BF BE</span>

  Actual bytes: <span class="token_unrepresentable" title="UTF-8 encoding of U+FFFD Replacement Character (�)">EF BF BD</span> <span class="token_unrepresentable" title="UTF-8 encoding of U+FFFD Replacement Character (�)">EF BF BD</span> (UTF-8 encoding of �, twice)</code></pre>

`U+FFFF` behaves the same way.

</div>

<div class="box-border" style="padding: 1em; padding-bottom: 0; margin-bottom: 1em;">

<div class="short-rc-and-result">
  
  <div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
  <pre style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0; justify-content: center;"><code class="language-rc" style="white-space: inherit;">1 <span class="token_keyword">RCDATA</span> <span class="token_punctuation">{</span> <span class="token_string">L"</span><span class="token_unrepresentable" title="'Noncharacter' Unicode codepoint">&lt;U+FFFE&gt;</span><span class="token_string">"</span> <span class="token_punctuation">}</span></code></pre>
  </div>

  <div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
    <div style="display: flex; flex-direction: column; flex-grow: 1; padding: 0.5em; justify-content: center; margin: 0.5em 0; margin-top: 0;"><div>Encoded as UTF-8 and compiled with <code>rc /c65001 test.rc</code>, meaning both the input and output code pages are UTF-8 (see <a href="#the-entirely-undocumented-concept-of-the-output-code-page">"<i>The entirely undocumented concept of the 'output' code page</i>"</a>)</div></div>
  </div>

</div>

<pre><code class="language-none">Expected bytes: <span class="token_unrepresentable" title="UTF-16 LE encoding of U+FFFE">FE FF</span>

  Actual bytes: <span class="token_unrepresentable" title="UTF-16 LE encoding of U+FFFD Replacement Character (�)">FD FF</span> <span class="token_unrepresentable" title="UTF-16 LE encoding of U+FFFD Replacement Character (�)">FD FF</span> (UTF-16 LE encoding of �, twice)</code></pre>

`U+FFFF` behaves the same way.

</div>

<div class="box-border" style="padding: 1em; padding-bottom: 0; margin-bottom: 1em;">

<div class="short-rc-and-result">
  
  <div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
  <pre style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0; justify-content: center;"><code class="language-rc" style="white-space: inherit;"><span class="token_preprocessor">#pragma</span><span class="token_rc_whitespace token_whitespace"> </span><span class="token_identifier">code_page</span><span class="token_punctuation">(</span><span class="token_identifier">65001</span><span class="token_punctuation">)</span>
1 <span class="token_keyword">RCDATA</span> <span class="token_punctuation">{</span> <span class="token_string">"</span><span class="token_unrepresentable" title="'Noncharacter' Unicode codepoint">&lt;U+FFFE&gt;</span><span class="token_string">"</span> <span class="token_punctuation">}</span></code></pre>
  </div>

  <div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
    <div style="display: flex; flex-direction: column; flex-grow: 1; padding: 0.5em; justify-content: center; margin: 0.5em 0; margin-top: 0;"><div>Encoded as UTF-8 and compiled with <code>rc test.rc</code>, meaning the input code page is UTF-8, but the output code page is Windows-1252 (see <a href="#the-entirely-undocumented-concept-of-the-output-code-page">"<i>The entirely undocumented concept of the 'output' code page</i>"</a>)</div></div>
  </div>

</div>

<pre><code class="language-none">Expected bytes: <span class="token_unrepresentable" title="Windows-1252 encoding of '?'">3F</span>

  Actual bytes: <span class="token_unrepresentable" title="Windows-1252 encoding of Latin Small Letter Y with Diaeresis (ÿ)">FE</span> <span class="token_unrepresentable" title="Windows-1252 encoding of Latin Small Letter Thorn (þ)">FF</span></code></pre>

`U+FFFF` behaves the same way, but would get compiled to `FF FF`.

</div>

<div class="box-border" style="padding: 1em; padding-bottom: 0; margin-bottom: 1em;">

<div class="short-rc-and-result">
  
  <div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
  <pre style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0; justify-content: center;"><code class="language-rc" style="white-space: inherit;"><span class="token_preprocessor">#pragma</span><span class="token_rc_whitespace token_whitespace"> </span><span class="token_identifier">code_page</span><span class="token_punctuation">(</span><span class="token_identifier">65001</span><span class="token_punctuation">)</span>
1 <span class="token_keyword">RCDATA</span> <span class="token_punctuation">{</span> <span class="token_string">L"</span><span class="token_unrepresentable" title="'Noncharacter' Unicode codepoint">&lt;U+FFFE&gt;</span><span class="token_string">"</span> <span class="token_punctuation">}</span></code></pre>
  </div>

  <div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
    <div style="display: flex; flex-direction: column; flex-grow: 1; padding: 0.5em; justify-content: center; margin: 0.5em 0; margin-top: 0;"><div>Encoded as UTF-8 and compiled with <code>rc test.rc</code>, meaning the input code page is UTF-8, but the output code page is Windows-1252 (see <a href="#the-entirely-undocumented-concept-of-the-output-code-page">"<i>The entirely undocumented concept of the 'output' code page</i>"</a>)</div></div>
  </div>

</div>

<pre><code class="language-none">Expected bytes: <span class="token_unrepresentable" title="UTF-16 LE encoding of U+FFFE">FE FF</span>

  Actual bytes: <span class="token_unrepresentable" title="UTF-16 LE encoding of U+00FF Latin Small Letter Y with Diaeresis (ÿ)">FE 00</span> <span class="token_unrepresentable" title="UTF-16 LE encoding of U+00FE Latin Small Letter Thorn (þ)">FF 00</span></code></pre>


`U+FFFF` behaves the same way, but would get compiled to `FF 00 FF 00`.

</div>

</details>

The *interesting* part about `U+FFFE` and `U+FFFF` is that their presence affects how *every non-ASCII codepoint in the file* is interpreted/compiled. That is, if either one appears anywhere in a file, it affects the interpretation of the entire file. Let's start with this example and try to understand what might be happening with the `䄀` characters in the `RCD䄀T䄀` resource type:

<div class="short-rc-and-result">
  
  <div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
  <pre style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0; justify-content: center;"><code class="language-rc" style="white-space: inherit;">1 RCD䄀T䄀 <span class="token_punctuation">{</span> <span class="token_string">"</span><span class="token_unrepresentable" title="'Noncharacter' Unicode codepoint">&lt;U+FFFE&gt;</span><span class="token_string">"</span> <span class="token_punctuation">}</span></code></pre>
  </div>

  <div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
    <div style="display: flex; flex-direction: column; flex-grow: 1; padding: 0.5em; justify-content: center; margin: 0.5em 0; margin-top: 0;"><div>Encoded as UTF-8 and compiled with <code>rc /c65001 test.rc</code>, meaning both the input and output code pages are UTF-8 (see <a href="#the-entirely-undocumented-concept-of-the-output-code-page">"<i>The entirely undocumented concept of the 'output' code page</i>"</a>)</div></div>
  </div>

</div>

If we run this through the preprocessor only (`rc /c65001 /p test.rc`), then it ends up as:

```rc
1 RCDATA { "��" }
```

The interpretation of the `<U+FFFE>` codepoint itself is the same as described above, but we can also see that the following transformation is occurring for the `䄀` codepoint:

<pre><code class="language-rc"><span class="token_unrepresentable" title="CJK Unified Ideograph-4100">&lt;U+4100&gt;</span> <span class="token_punctuation">(</span>䄀<span class="token_punctuation">)</span>  <span class="token_function">────►</span>  <span class="token_unrepresentable" title="Latin Capital Letter A">&lt;U+0041&gt;</span> <span class="token_punctuation">(</span>A<span class="token_punctuation">)</span></code></pre>

And this transformation is not an illusion. If you compile this example `.rc` file, it will get compiled as the predefined `RCDATA` resource type. So, what's going on here?

Let's back up a bit and talk about [UTF-16](https://en.wikipedia.org/wiki/UTF-16) and [endianness](https://en.wikipedia.org/wiki/Endianness). Since UTF-16 uses 2 bytes per code unit, it can be encoded either as little-endian (least-significant byte first) or big-endian (most-significant byte first).

<div class="short-rc-and-result">
  
  <div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
    <div class="box-bg" style="display: flex; flex-direction: column; flex-grow: 1; padding: 0.5em; justify-content: center; margin: 0.5em 0; margin-top: 0;"><div>Codepoints:</div></div>
  </div>

  <div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
<pre style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0; justify-content: center;"><code class="language-none"><span class="token_unrepresentable" title="Latin Capital Letter A">&lt;U+0041&gt;</span> <span class="token_unrepresentable" title="Meetei Mayek Letter Huk">&lt;U+ABCD&gt;</span> <span class="token_unrepresentable" title="CJK Unified Ideograph-4100">&lt;U+4100&gt;</span></code></pre>
  </div>

  <div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
    <div class="box-bg" style="display: flex; flex-direction: column; flex-grow: 1; padding: 0.5em; justify-content: center; margin: 0.5em 0; margin-top: 0;"><div>Little-Endian UTF-16:</div></div>
  </div>

  <div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
<pre style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0; justify-content: center;"><code class="language-none"><span class="token_unrepresentable" title="Latin Capital Letter A">41 00</span> <span class="token_unrepresentable" title="Meetei Mayek Letter Huk">CD AB</span> <span class="token_unrepresentable" title="CJK Unified Ideograph-4100">00 41</span></code></pre>
  </div>

  <div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
    <div class="box-bg" style="display: flex; flex-direction: column; flex-grow: 1; padding: 0.5em; justify-content: center; margin: 0.5em 0; margin-top: 0;"><div>Big-Endian UTF-16:</div></div>
  </div>

  <div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
<pre style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0; justify-content: center;"><code class="language-none"><span class="token_unrepresentable" title="Latin Capital Letter A">00 41</span> <span class="token_unrepresentable" title="Meetei Mayek Letter Huk">AB CD</span> <span class="token_unrepresentable" title="CJK Unified Ideograph-4100">41 00</span></code></pre>
  </div>

</div>

In many cases, the endianness of the encoding can be inferred, but in order to make it unambiguous, a [byte-order mark](https://en.wikipedia.org/wiki/Byte_order_mark) (BOM) can be included (usually at the start of a file). The codepoint of the BOM is [`U+FEFF`](https://codepoints.net/U+FEFF), so that's either encoded as `FF FE` for little-endian or `FE FF` for big-endian.

<p><aside class="note">

Note: The Windows RC compiler writes UTF-16 as little-endian, and its preprocessor always outputs UTF-16 (see [*The Windows RC compiler 'speaks' UTF-16*](#the-windows-rc-compiler-speaks-utf-16))

</aside></p>

With this in mind, consider how one might handle a big-endian UTF-16 byte-order mark in a file when starting with the assumption that the file is little-endian.

<div class="short-rc-and-result">
  
  <div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
    <div class="box-bg" style="display: flex; flex-direction: column; flex-grow: 1; padding: 0.5em; justify-content: center; margin: 0.5em 0; margin-top: 0;"><div>Big-endian UTF-16 encoded byte-order mark:</div></div>
  </div>

  <div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
<pre style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0; justify-content: center;"><code class="language-none"><span class="token_unrepresentable" title="Big-endian UTF-16 encoding of U+FEFF (BOM)">FE FF</span></code></pre>
  </div>

  <div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
    <div class="box-bg" style="display: flex; flex-direction: column; flex-grow: 1; padding: 0.5em; justify-content: center; margin: 0.5em 0; margin-top: 0;"><div>Decoded codepoint, assuming little-endian:</div></div>
  </div>

  <div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
<pre style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0; justify-content: center;"><code class="language-none"><span class="token_unrepresentable" title="Noncharacter">&lt;U+FFFE&gt;</span></code></pre>
  </div>

</div>

So, starting with the assumption that a file is little-endian, treating the decoded codepoint `<U+FFFE>` as a trigger for switching to interpreting the file as big-endian can make sense. However, it *only* makes sense when you are working with an encoding where endianness matters (e.g. UTF-16 or UTF-32). It appears, though, that the Windows RC compiler is using this *"`<U+FFFE>`? Oh, the file is big-endian and I should byteswap every codepoint"* heuristic even when it's dealing with UTF-8, which doesn't make any sense&mdash;endianness is irrelevant for UTF-8, since its code units are a single byte.

As mentioned in [`U+0900`, `U+0A00`, etc](#u-0900-u-0a00-u-0a0d-u-0d00-u-2000), this endianness handling is likely happening in the wrong phase of the compiler pipeline; it's acting on already-decoded codepoints rather than affecting how the bytes of the file are decoded.

If I had to guess as to what's going on here, it would be something like:

- The preprocessor decodes all codepoints, and internally assumes little-endian in some fashion
- If the preprocessor ever encounters the decoded codepoint `<U+FFFE>`, it assumes it must be a byteswapped byte-order mark, indicating that the file is encoded as big-endian, and sets some internal 'big-endian' flag
- When writing the result after preprocessing, that 'big-endian' flag is used to determine whether or not to byteswap every codepoint in the file before writing it (except ASCII codepoints for some reason)

This would explain the behavior with `䄀` we saw earlier, where this `.rc` file:

<pre style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0; justify-content: center;"><code class="language-rc" style="white-space: inherit;">1 RCD䄀T䄀 <span class="token_punctuation">{</span> <span class="token_string">"</span><span class="token_unrepresentable" title="'Noncharacter' Unicode codepoint">&lt;U+FFFE&gt;</span><span class="token_string">"</span> <span class="token_punctuation">}</span></code></pre>

gets preprocessed into:

```rc
1 RCDATA { "��" }
```

which means the following (byteswapping) transformation occurred, even to the `䄀` characters preceding the `<U+FFFE>`:

<pre><code class="language-rc"><span class="token_unrepresentable" title="CJK Unified Ideograph-4100">&lt;U+4100&gt;</span> <span class="token_punctuation">(</span>䄀<span class="token_punctuation">)</span>  <span class="token_function">────►</span>  <span class="token_unrepresentable" title="Latin Capital Letter A">&lt;U+0041&gt;</span> <span class="token_punctuation">(</span>A<span class="token_punctuation">)</span></code></pre>

##### Wait, what about `U+FFFF`?

`U+FFFF` works the exact same way as `U+FFFE`&mdash;it, too, causes all non-ACII codepoints in the file to be byteswapped&mdash;and I have no clue as to why that would be.

#### `resinator`'s behavior

Any codepoints that cause misbehaviors are either a compile error:

```resinatorerror
test.rc:1:9: error: character '\x04' is not allowed outside of string literals
1 RCDATA�!?! { "foo" }
        ^
```
```resinatorerror
test.rc:1:1: error: character '\x7F' is not allowed
�1 RCDATA {}
^
```

or the miscompilation is avoided and a warning is emitted:

```resinatorerror
test.rc:1:12: warning: codepoint U+0900 within a string literal would be miscompiled by the Win32 RC compiler (it would get treated as U+0009)
1 RCDATA { "ऀ਀਍ഀ " }
           ^~~~~~~
```
```resinatorerror
test.rc:1:12: warning: codepoint U+FFFF within a string literal would cause the entire file to be miscompiled by the Win32 RC compiler
1 RCDATA { "￿" }
           ^~~
test.rc:1:12: note: the presence of this codepoint causes all non-ASCII codepoints to be byteswapped by the Win32 RC preprocessor
```

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">parser bug/quirk</span>

### The column of a tab character matters

Literal tab characters (`U+009`) within an `.rc` file get transformed by the preprocessor into a variable number of spaces (1-8), depending on the column of the tab character in the source file. This means that whitespace can affect the output of the compiler. Here's a few examples, where <code><span class="token_unrepresentable" title="Horizontal Tab (\t)">────</span></code> denotes a tab character:

<div class="tab-gets-compiled-to">
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
<div style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0;">
  <pre><code class="language-rc"><span class="token_identifier">1</span><span class="token_rc_whitespace token_whitespace"> </span><span class="token_keyword">RCDATA</span><span class="token_rc_whitespace token_whitespace"> </span><span class="token_punctuation">{</span>
<span class="token_string">"</span><span class="token_unrepresentable" title="Horizontal Tab (\t)">────</span><span class="token_string">"</span>
<span class="token_punctuation">}</span></code></pre>
</div>
</div>
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
<div style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0; justify-content: center; align-items: center; text-align:center;">the tab gets compiled to 7 spaces:</div>
</div>
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
  <pre style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0; justify-content: center;"><code class="language-none"><span class="token_unrepresentable" title="Space">·</span><span class="token_unrepresentable" title="Space">·</span><span class="token_unrepresentable" title="Space">·</span><span class="token_unrepresentable" title="Space">·</span><span class="token_unrepresentable" title="Space">·</span><span class="token_unrepresentable" title="Space">·</span><span class="token_unrepresentable" title="Space">·</span></code></pre>
</div>
</div>

<div class="tab-gets-compiled-to">
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
<div style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0;">
  <pre><code class="language-rc"><span class="token_identifier">1</span><span class="token_rc_whitespace token_whitespace"> </span><span class="token_keyword">RCDATA</span><span class="token_rc_whitespace token_whitespace"> </span><span class="token_punctuation">{</span>
   <span class="token_string">"</span><span class="token_unrepresentable" title="Horizontal Tab (\t)">────</span><span class="token_string">"</span>
<span class="token_punctuation">}</span></code></pre>
</div>
</div>
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
<div style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0; justify-content: center; align-items: center; text-align:center;">the tab gets compiled to 4 spaces:</div>
</div>
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
  <pre style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0; justify-content: center;"><code class="language-none"><span class="token_unrepresentable" title="Space">·</span><span class="token_unrepresentable" title="Space">·</span><span class="token_unrepresentable" title="Space">·</span><span class="token_unrepresentable" title="Space">·</span></code></pre>
</div>
</div>

<div class="tab-gets-compiled-to">
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
<div style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0;">
  <pre><code class="language-rc"><span class="token_identifier">1</span><span class="token_rc_whitespace token_whitespace"> </span><span class="token_keyword">RCDATA</span><span class="token_rc_whitespace token_whitespace"> </span><span class="token_punctuation">{</span>
      <span class="token_string">"</span><span class="token_unrepresentable" title="Horizontal Tab (\t)">────</span><span class="token_string">"</span>
<span class="token_punctuation">}</span></code></pre>
</div>
</div>
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
<div style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0; justify-content: center; align-items: center; text-align:center;">the tab gets compiled to 1 space:</div>
</div>
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
  <pre style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0; justify-content: center;"><code class="language-none"><span class="token_unrepresentable" title="Space">·</span></code></pre>
</div>
</div>

#### `resinator`'s behavior

`resinator` matches the Win32 RC compiler behavior, but emits a warning

```resinatorerror
test.rc:2:4: warning: the tab character(s) in this string will be converted into a variable number of spaces (determined by the column of the tab character in the .rc file)
   " "
   ^~~
test.rc:2:4: note: to include the tab character itself in a string, the escape sequence \t should be used
```

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">miscompilation</span>

### `STRINGTABLE` semantics bypass

The [`STRINGTABLE`](https://learn.microsoft.com/en-us/windows/win32/menurc/stringtable-resource) is intended for embedding string data, which can then be loaded at runtime with [`LoadString`](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-loadstringw). A `STRINGTABLE` resource definition looks something like this:

```rc
STRINGTABLE {
  0, "Hello"
  1, "Goodbye"
}
```

Notice that there is no `id` before the `STRINGTABLE` resource type. This is because all strings within `STRINGTABLE` resources are bundled together in groups of 16 based on their ID and language (we can ignore the language part for now, though). So, if we have this example `.rc` file:

```rc
STRINGTABLE {
  1, "Goodbye"
}

STRINGTABLE {
  0, "Hello"
  23, "Hm"
}
```

The `"Hello"` and `"Goodbye"` strings will be grouped together into one resource, and the `"Hm"` will be put into another. Each group is written as a series of 16 length integers (one for each string within the group), and each length is immediately followed by a UTF-16 encoded string of that length (if the length is non-zero). So, for example, the first group contains the strings with IDs 0-15, so, in the above example, the first group would be compiled as:

<pre class="hexdump"><code><span class="o1d o-clr3 infotip" title="Length of string ID 0">05 00</span> <span class="bg-clr3 o1s o-clr3">48 00 65 00 6C 00</span>  <span class="o1d o-clr3">..</span><span class="bg-clr3 o1s o-clr3">H.e.l.</span>
<span class="bg-clr3 o1s o-clr3">6C 00 6F 00</span> <span class="o1d o-clr4 infotip" title="Length of string ID 1">07 00</span> <span class="bg-clr4 o1s o-clr4">47 00</span>  <span class="bg-clr3 o1s o-clr3">l.o.</span><span class="o1d o-clr4">..</span><span class="bg-clr4 o1s o-clr4">G.</span>
<span class="bg-clr4 o1s o-clr4">6F 00 6F 00 64 00 62 00</span>  <span class="bg-clr4 o1s o-clr4">o.o.d.b.</span>
<span class="bg-clr4 o1s o-clr4">79 00 65 00</span> <span style="opacity:0.5"><span class="o1d o-clr5 infotip" title="Length of string ID 2">00 00</span> <span class="o1d o-clr1 infotip" title="Length of string ID 3">00 00</span></span>  <span class="bg-clr4 o1s o-clr4">y.e.</span><span style="opacity:0.5"><span class="o1d o-clr5">..</span><span class="o1d o-clr1">..</span>
<span class="o1d o-clr2 infotip" title="Length of string ID 4">00 00</span> <span class="o1d o-clr3 infotip" title="Length of string ID 5">00 00</span> <span class="o1d o-clr4 infotip" title="Length of string ID 6">00 00</span> <span class="o1d o-clr5 infotip" title="Length of string ID 7">00 00</span>  <span class="o1d o-clr2">..</span><span class="o1d o-clr3">..</span><span class="o1d o-clr4">..</span><span class="o1d o-clr5">..</span>
<span class="o1d o-clr1 infotip" title="Length of string ID 8">00 00</span> <span class="o1d o-clr2 infotip" title="Length of string ID 9">00 00</span> <span class="o1d o-clr3 infotip" title="Length of string ID 10">00 00</span> <span class="o1d o-clr4 infotip" title="Length of string ID 11">00 00</span>  <span class="o1d o-clr1">..</span><span class="o1d o-clr2">..</span><span class="o1d o-clr3">..</span><span class="o1d o-clr4">..</span>
<span class="o1d o-clr5 infotip" title="Length of string ID 12">00 00</span> <span class="o1d o-clr1 infotip" title="Length of string ID 13">00 00</span> <span class="o1d o-clr2 infotip" title="Length of string ID 14">00 00</span> <span class="o1d o-clr3 infotip" title="Length of string ID 15">00 00</span>  <span class="o1d o-clr5">..</span><span class="o1d o-clr1">..</span><span class="o1d o-clr2">..</span><span class="o1d o-clr3">..</span></span>
</code></pre>

Internally, `STRINGTABLE` resources get compiled as the integer resource type `RT_STRING`, which is 6. The ID of the resource is based on the grouping, so strings with IDs 0-15 go into a `RT_STRING` resource with ID 1, 16-31 go into a resource with ID 2, etc.

The above is all well and good, but what happens if you *manually* define a resource with the `RT_STRING` type of 6? The Windows RC compiler has no qualms with that at all, and compiles it similarly to a user-defined resource:

```rc
1 6 {
  "foo"
}
```

When compiled, though, the resource type and ID are indistinguishable from a properly defined `STRINGTABLE`. This means that compiling the above resource and then trying to use `LoadString` will *succeed*, even though the resource's data does not conform at all to the intended structure of a `RT_STRING` resource:

```c
UINT string_id = 0;
WCHAR buf[1024];
int len = LoadStringW(NULL, string_id, buf, 1024);
if (len != 0) {
    printf("len: %d\n", len);
    wprintf(L"%s\n", buf);
}
```

will output:

```
len: 1023
o
```

Let's think about what's going on here. We compiled a resource with three bytes of data: `foo`. We have no real control over what follows that data in the compiled binary, so we can think about how this resource is interpreted by `LoadString` like this:

<pre class="hexdump"><code><span class="o1d o-clr3 infotip" title="Length of string ID 0">66 6F</span> <span class="bg-clr3 o1s o-clr3">6F ?? ?? ?? ?? ??</span>  <span class="o1d o-clr3">fo</span><span class="bg-clr3 o1s o-clr3">o?????</span>
<span class="bg-clr3 o1s o-clr3">?? ?? ?? ?? ?? ?? ?? ??</span>  <span class="bg-clr3 o1s o-clr3">????????</span>
<span style="opacity:0.5"><span class="bg-clr3 o1s o-clr3">          ...          </span>  <span class="bg-clr3 o1s o-clr3">   ...  </span></span></code></pre>

The first two bytes, `66 6F`, are treated as a little-endian `u16` containing the length of the string that follows it. `66 6F` as a little-endian `u16` is 28518, so `LoadString` thinks that the string with ID `0` is 28 thousand UTF-16 code units long. All of the `??` bytes are those that happen to follow the resource data&mdash;they could in theory be anything. So, `LoadString` will erroneously attempt to read this gargantuan string into `buf`, but since we only provided a buffer of 1024, it only fills up to that size and stops.

In the actual compiled binary, the bytes following `foo` happen to look like this:

<pre class="hexdump"><code><span class="o1d o-clr3 infotip" title="Length of string ID 0">66 6F</span> <span class="bg-clr3 o1s o-clr3">6F 00 00 00 00 00</span>  <span class="o1d o-clr3">fo</span><span class="bg-clr3 o1s o-clr3">o.....</span>
<span class="bg-clr3 o1s o-clr3">3C 3F 78 6D 6C 20 76 65</span>  <span class="bg-clr3 o1s o-clr3">&lt;?xml ve</span>
<span style="opacity:0.5"><span class="bg-clr3 o1s o-clr3">          ...          </span>  <span class="bg-clr3 o1s o-clr3">   ...  </span></span></code></pre>

This means that the last `o` in `foo` happens to be followed by `00`, and `6F 00` is interpreted as a UTF-16 `o` character, and that happens to be followed by `00 00` which is treated as a `NUL` terminator by `wprintf`. This explains the `o` we got earlier from `wprintf(L"%s\n", buf);`. However, if we print the full 1023 bytes of the buf like so:

```c
for (int i = 0; i < len; i++) {
    const char* bytes = &buf[i];
    printf("%d: %02X %02X\n", i, bytes[0], bytes[1]);
}
```

Then it shows more clearly that `LoadString` did indeed read past our resource data and started loading bytes from totally unrelated areas of the compiled binary (note that these bytes match the hexdump above):

```
0: 6F 00
1: 00 00
2: 00 00
3: 3C 3F
4: 78 6D
5: 6C 20
6: 76 65
...
```

If we then modify our program to try to load a string with an ID of 1, then the `LoadStringW` call will crash within `RtlLoadString` (and it would do the same for any ID from 1-15):

```
Exception thrown at 0x00007FFA63623C88 (ntdll.dll) in stringtabletest.exe: 0xC0000005: Access violation reading location 0x00007FF7A80A2F6E.

  ntdll.dll!RtlLoadString()
  KernelBase.dll!LoadStringBaseExW()
  user32.dll!LoadStringW()
> stringtabletest.exe!main(...)
```

This is because, in order to load a string with ID 1, the bytes of the string with ID 0 need to be skipped past. That is, `LoadString` will determine that the string with ID 0 has a length of 28 thousand, and then try to skip ahead in the file *56 thousand bytes* (since the length is in UTF-16 code units), which in our case is well past the end of the file.

<p><aside class="note">

Note: Resources get compiled into a tree structure when linked into a PE/COFF binary, and that format is not something I'm familiar with ([yet](https://github.com/squeek502/resinator/issues/7)). My first impression, though, is that this seems like a bug in `LoadString`; if possible, it probably should be doing some bounds checking to avoid attempting to read past the end of the resource data.

</aside></p>

#### `resinator`'s behavior

```resinatorerror
test.rc:1:3: error: the number 6 (RT_STRING) cannot be used as a resource type
1 6 {
  ^
test.rc:1:3: note: using RT_STRING directly likely results in an invalid .res file, use a STRINGTABLE instead
```

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">miscompilation</span>

### 'Extra data' in `DIALOG` resources is useless at best

In `DIALOGEX` resources, a control statement is documented to have the following syntax:

> ```
> control [[text,]] id, x, y, width, height[[, style[[, extended-style]]]][, helpId]
> [{ data-element-1 [, data-element-2 [,  . . . ]]}]
> ```

For now, we can ignore everything except the `[{ data-element-1 [, data-element-2 [,  . . . ]]}]` part, which is documented like so:

> *controlData*
>
> Control-specific data for the control. When a dialog is created, and a control in that dialog which has control-specific data is created, a pointer to that data is passed into the control's window procedure through the lParam of the WM_CREATE message for that control.

After a very long time of having no idea how to retrieve this data, I finally figured it out while writing this article. As far as I know, the `WM_CREATE` event can only be received for custom controls

---

subclassing doesn't work, bypasses WM_CREATE
superclassing does work
custom controls work

https://learn.microsoft.com/en-us/windows/win32/winmsg/about-window-procedures?redirectedfrom=MSDN#winproc_superclassing

---

Here's an example, where the string `"foo"` is the control data:

<pre><code class="language-rc"><span style="opacity: 50%;">1 DIALOGEX 0, 0, 282, 239
{</span>
  PUSHBUTTON <span style="opacity: 50%;">"Cancel",1,129,212,50,14</span> <span class="token_punctuation">{</span> <span class="token_string">"foo"</span> <span class="token_punctuation">}</span>
<span style="opacity: 50%;">}</span></code>
</pre>

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
<span class="bug-quirk-category">miscompilation</span>

### Mismatch in length units in `VERSIONINFO` nodes

The data length of a `VERSIONNODE` for strings is counted in UTF-16 code units instead of bytes. This can get especially weird if numbers and strings are intermixed within a `VERSIONNODE`'s data, e.g. `VALUE "key", 1, 2, "ab"` will end up reporting a data length of 7 (2 for each number, 1 for each UTF-16 character, and 1 for the null-terminator of the "ab" string), but the real (as written to the `.res`) length of the data in bytes is 10 (2 for each number, 2 for each UTF-16 character, and 2 for the null-terminator of the "ab" string). This is detailed in [this The Old New Thing post](https://devblogs.microsoft.com/oldnewthing/20061222-00/?p=28623).

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">utterly baffling</span>

### Certain `DLGINCLUDE` filenames break the preprocessor

The following script, when encoded as Windows-1252, will cause the `rc.exe` preprocessor to freak out and output what seems to be garbage. 

```rc
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

```rc
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

```rc
1 DLGINCLUDE "\06f\x2\x2b\445q\105[ð\134\x90 ...truncated..."
```

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">miscompilation</span>

### Your fate will be determined by a comma

Version information is specified using key/value pairs within `VERSIONINFO` resources. The value data should always start at a 4-byte boundary, so after the key data is written, a variable number of padding bytes are written to get back to 4-byte alignment:

<div style="text-align: center; display: grid; grid-gap: 10px; grid-template-columns: repeat(2, 1fr);">
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
  <pre style="display: flex; flex-direction: column; justify-content: center; align-items: center; flex-grow: 1; margin-top: 0;">
    <code class="language-none"><span style="opacity: 50%;">1 VERSIONINFO {</span>
  <span class="token_keyword">VALUE</span> <span style="background: rgba(255,0,0,.1);">"key"</span>, <span style="background: rgba(0,255,0,.1);">"value"</span>
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
  <span class="token_keyword">VALUE</span> <span style="background: rgba(255,0,0,.1);">"key"</span> <span style="background: rgba(0,255,0,.1);">"value"</span>
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

Plus, depending on the length of the key string, it can end up being even worse, since the value could end up being written over the top of the null terminator of the key. Here's an example:

<div style="text-align: center; display: grid; grid-gap: 10px; grid-template-columns: repeat(2, 1fr);">
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
  <pre style="display: flex; flex-direction: column; justify-content: center; align-items: center; flex-grow: 1; margin-top: 0;">
    <code class="language-none"><span style="opacity: 50%;">1 VERSIONINFO {</span>
  <span class="token_keyword">VALUE</span> <span style="background: rgba(255,0,0,.1);">"ke"</span> <span style="background: rgba(0,255,0,.1);">"value"</span>
<span style="opacity: 50%;">}</span></code>
  </pre>
</div>
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
  <pre style="display: flex; flex-direction: column; justify-content: center; align-items: center; flex-grow: 1; margin-top: 0;">
    <code class="language-none"><span style="opacity: 25%;">......</span><span style="background: rgba(255,0,0,.1);">k.e.</span><span style="background: rgba(0,255,0,.1);">v.a.l.
u.e...</span><span style="opacity: 25%;">..........</span></code>
  </pre>
</div>
</div>

And the problems don't end there&mdash;`VERSIONINFO` is compiled into a tree structure, meaning the misreading of one node affects the reading of future nodes. Here's a (simplified) real-world `VERSIONINFO` resource definition from a random `.rc` file in [Windows-classic-samples](https://github.com/microsoft/Windows-classic-samples):

```rc
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

and here's the Properties window of an `.exe` compiled with and without commas between all the key/value pairs:

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

<p><aside class="note">

Note: This miscompilation will only occur when:

- the comma between the key and the first value in a `VALUE` statement is omitted, *and*
- the first value is a quoted string

That is, `VALUE "key" "value"` will miscompile but `VALUE "key", "value"` or `VALUE "key" 1` won't.

</aside></p>

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
  PUSHBUTTON <span style="opacity: 50%;">"Cancel",1,129,212,50,14,</span> <span class="token_operator">NOT</span> WS_VISIBLE
<span style="opacity: 50%;">}</span></code>
</pre>

Since `WS_VISIBLE` is set by default, this will unset it and make the button invisible. If there are any other flags that should be applied, they can be bitwise OR'd like so:

<pre><code class="language-c"><span style="opacity: 50%;">1 DIALOGEX 0, 0, 282, 239
{</span>
  PUSHBUTTON <span style="opacity: 50%;">"Cancel",1,129,212,50,14,</span> <span class="token_operator">NOT</span> WS_VISIBLE <span class="token_operator">|</span> BS_VCENTER
<span style="opacity: 50%;">}</span></code>
</pre>

`WS_VISIBLE` and `BS_VCENTER` are `#define`s that stem from `WinUser.h` and are just numbers under-the-hood. For simplicity's sake, let's pretend their values are `0x1` for `WS_VISIBLE` and `0x2` for `BS_VCENTER` and then focus on this simplified `NOT` expression:

<pre><code class="language-c"><span class="token_operator">NOT</span> 0x1 <span class="token_operator">|</span> 0x2</code>
</pre>

Since `WS_VISIBLE` is on by default, the default value of these flags is `0x1`, and so the resulting value is evaluated like this:

<div class="not-eval">

<div><i>operation</i></div>
<div><i>binary representation of the result</i></div>
<div><i>hex representation of the result</i></div>

<div class="not-eval-border"><span><small>Default value:</small> <code>0x1</code></span></div>
<div class="not-eval-code"><pre><code>0000 0001</code></pre></div>
<div class="not-eval-border"><span><code>0x1</code></span></div>

<div class="not-eval-border"><code><span class="token_operator">NOT</span> 0x1</code></div>
<div class="not-eval-code"><pre><code>0000 000<span class="token_deleted">0</span></code></pre></div>
<div class="not-eval-border"><span><code>0x0</code></span></div>

<div class="not-eval-border"><code><span class="token_operator">|</span> 0x2</code></div>
<div class="not-eval-code"><pre><code>0000 00<span class="token_addition">1</span>0</code></pre></div>
<div class="not-eval-border"><span><code>0x2</code></span></div>

</div>

Ordering matters as well. If we switch the expression to:

```rc
NOT 0x1 | 0x1
```

then we end up with `0x1` as the result:

<div class="not-eval">

<div><i>operation</i></div>
<div><i>binary representation of the result</i></div>
<div><i>hex representation of the result</i></div>

<div class="not-eval-border"><span><small>Default value:</small> <code>0x1</code></span></div>
<div class="not-eval-code"><pre><code>0000 0001</code></pre></div>
<div class="not-eval-border"><span><code>0x1</code></span></div>

<div class="not-eval-border"><code><span class="token_operator">NOT</span> 0x1</code></div>
<div class="not-eval-code"><pre><code>0000 000<span class="token_deleted">0</span></code></pre></div>
<div class="not-eval-border"><span><code>0x0</code></span></div>

<div class="not-eval-border"><code><span class="token_operator">|</span> 0x1</code></div>
<div class="not-eval-code"><pre><code>0000 000<span class="token_addition">1</span></code></pre></div>
<div class="not-eval-border"><span><code>0x1</code></span></div>

</div>

If, instead, the ordering was reversed like so:

```rc
0x1 | NOT 0x1
```

then the value at the end would be `0x0`:

<div class="not-eval">

<div><i>operation</i></div>
<div><i>binary representation of the result</i></div>
<div><i>hex representation of the result</i></div>

<div class="not-eval-border"><span><small>Default value:</small> <code>0x1</code></span></div>
<div class="not-eval-code"><pre><code>0000 0001</code></pre></div>
<div class="not-eval-border"><span><code>0x1</code></span></div>

<div class="not-eval-border"><code>0x1</code></div>
<div class="not-eval-code"><pre><code>0000 0001</code></pre></div>
<div class="not-eval-border"><span><code>0x1</code></span></div>

<div class="not-eval-border"><code><span class="token_operator">|</span> <span class="token_operator">NOT</span> 0x1</code></div>
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

```rc
1 DIALOGEX NOT 1, NOT 2, NOT 3, NOT 4
{
  // ...
}
```

This doesn't necessarily cause problems, but since `NOT` is only useful in the context of turning off enabled-by-default flags of a bit flag parameter, there's no reason to allow `NOT` expressions outside of that context.

However, there *is* an extra bit of weirdness involved here, since certain `NOT` expressions cause errors in some places but not others. For example, the expression `1 | NOT 2` is an error if it's used in the `type` parameter of a `MENUEX`'s `MENUITEM`, but `NOT 2 | 1` is totally accepted.

```rc
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

```rc
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

```rc
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

```rc
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

```rc
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

```rc style="display: flex; flex-direction: column; justify-content: center; align-items: center; flex-grow: 1; margin-top: 0;"
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

```rc style="display: flex; flex-direction: column; justify-content: center; align-items: center; flex-grow: 1; margin-top: 0;"
#pragma code_page(4295032296)
```

</div>
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```none style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0;"
fatal error RC22105: MultiByteToWideChar failed.
```

</div>
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```rc style="display: flex; flex-direction: column; justify-content: center; align-items: center; flex-grow: 1; margin-top: 0;"
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

```rc style="display: flex; flex-direction: column; justify-content: center; align-items: center; flex-grow: 1; margin-top: 0;"
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

```rc
1 RCDATA { 1, ), ), ), 2 }
```

This should very clearly be a syntax error, but it's actually accepted by the Windows RC compiler. What does the RC compiler do, you ask? Well, it just skips right over all the `)`, of course, and the data of this resource ends up as:

<pre style="display: flex; flex-direction: column; justify-content: center; align-items: center; flex-grow: 1; margin-top: 0;">
  <code class="language-none"><span style="font-family:sans-serif; font-style:italic">the 1 (u16 little endian) &rarr;</span> <span style="outline: 1px dashed red;">01 00</span> <span style="outline: 1px dashed orange;">02 00</span> <span style="font-family:sans-serif; font-style:italic">&larr; the 2 (u16 little endian)</span></code>
</pre>

I said 'skip' because that's truly what seems to happen. For example, for resource definitions that take positional parameters like so:

<pre><code class="language-none"><span style="opacity: 50%;">1 DIALOGEX 1, 2, 3, 4 {</span>
  <span class="token_comment">//        &lt;text&gt; &lt;id&gt; &lt;x&gt; &lt;y&gt; &lt;w&gt; &lt;h&gt; &lt;style&gt;</span>
  <span class="token_keyword">CHECKBOX</span>  <span class="token_string">"test"</span>,  1,  2,  3,  4,  5,  6
<span style="opacity: 50%;">}</span></code>
</pre>

If you replace the `<id>` parameter (`1`) with `)`, then all the parameters shift over and they get interpreted like this instead:

<pre><code class="language-none"><span style="opacity: 50%;">1 DIALOGEX 1, 2, 3, 4 {</span>
  <span class="token_comment">//        &lt;text&gt;     &lt;id&gt; &lt;x&gt; &lt;y&gt; &lt;w&gt; &lt;h&gt;</span>
  <span class="token_keyword">CHECKBOX</span>  <span class="token_string">"test"</span>,  <span class="token_punctuation">)</span>,  2,  3,  4,  5,  6
<span style="opacity: 50%;">}</span></code>
</pre>

Note also that all of this is only true of the *close parenthesis*. The open parenthesis was not deemed worthy of the same power:

<div class="short-rc-and-result">
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```rc style="display: flex; flex-direction: column; justify-content: center; align-items: center; flex-grow: 1; margin-top: 0;"
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

```rc
1 DIALOGEX 1(, (2, (3(, ((((4(((( {}
```

And in the above case, the parameters are interpreted as if the `(` characters don't exist, e.g. they compile to the values `1`, `2`, `3`, and `4`.

This power of `(` does not have infinite reach, though&mdash;in other places a `(` leads to an mismatched parentheses error as you might expect:

<div class="short-rc-and-result">
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```rc style="display: flex; flex-direction: column; justify-content: center; align-items: center; flex-grow: 1; margin-top: 0;"
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

```rc
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

```rc style="display: flex; flex-direction: column; justify-content: center; align-items: center; flex-grow: 1; margin-top: 0;"
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

```rc style="display: flex; flex-direction: column; justify-content: center; align-items: center; flex-grow: 1; margin-top: 0;"
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

```rc
1 FOO { 1-- }
```

evaluates to `1-0` and results in `1` being written to the resource's data, while:

```rc
1 FOO { "str" - 1 }
```

looks like a string literal minus 1, but it's actually interpreted as 3 separate raw data values (`str`, `-` [which evaluates to 0], and `1`), since commas between data values in a raw data block are optional.

Additionally, it means that otherwise valid looking expressions may not actually be considered valid:

<div class="short-rc-and-result">
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```rc style="display: flex; flex-direction: column; justify-content: center; align-items: center; flex-grow: 1; margin-top: 0;"
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

```rc style="display: flex; flex-direction: column; justify-content: center; align-items: center; flex-grow: 1; margin-top: 0;"
1 FOO { ~ }
```

</div>
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
<div class="box-border" style="display: flex; flex-direction: column; flex-grow: 1; padding: 1em; margin: 0.5em 0; margin-top: 0;"><div>Data is a <code>u16</code> with the value <code>0xFFFF</code></div></div>
</div>
</div>

And `~L` (to turn the integer into a `u32`) is valid in the same way that `-L` would be valid:

<div class="short-rc-and-result">
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```rc style="display: flex; flex-direction: column; justify-content: center; align-items: center; flex-grow: 1; margin-top: 0;"
1 FOO { ~L }
```

</div>
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
<div class="box-border" style="display: flex; flex-direction: column; flex-grow: 1; padding: 1em; margin: 0.5em 0; margin-top: 0;"><div>Data is a <code>u32</code> with the value <code>0xFFFFFFFF</code></div></div>
</div>
</div>


---

The unary `+` is almost entirely a hallucination; it can be used in some places, but not others, without any discernible rhyme or reason.

This is valid (and the parameters evaluate to `1`, `2`, `3`, `4` as expected):

```rc
1 DIALOG +1, +2, +3, +4 {}
```

but this is an error:

<div class="short-rc-and-result">
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```rc style="display: flex; flex-direction: column; justify-content: center; align-items: center; flex-grow: 1; margin-top: 0;"
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

```rc style="display: flex; flex-direction: column; justify-content: center; align-items: center; flex-grow: 1; margin-top: 0;"
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

<pre class="annotated-code"><code class="language-c" style="white-space: inherit;"><span class="annotation"><span class="desc">class<i></i></span><span class="subject"><span class="token_keyword">CHECKBOX</span></span></span><span class="token_punctuation">,</span> <span class="annotation"><span class="desc">text<i></i></span><span class="subject"><span class="token_string">"foo"</span></span></span><span class="token_punctuation">,</span> <span class="annotation"><span class="desc">id<i></i></span><span class="subject">1</span></span><span class="token_punctuation">,</span> <span class="annotation"><span class="desc">x<i></i></span><span class="subject">2</span></span><span class="token_punctuation">,</span> <span class="annotation"><span class="desc">y<i></i></span><span class="subject">3</span></span><span class="token_punctuation">,</span> <span class="annotation"><span class="desc">w<i></i></span><span class="subject">4</span></span><span class="token_punctuation">,</span> <span class="annotation"><span class="desc">h<i></i></span><span class="subject">5</span></span></code></pre>

<pre class="annotated-code"><code class="language-c" style="white-space: inherit;"><span class="annotation"><span class="desc">class<i></i></span><span class="subject"><span class="token_keyword">CONTROL</span></span></span><span class="token_punctuation">,</span> <span class="token_string">"foo"</span><span class="token_punctuation">,</span> 1<span class="token_punctuation">,</span> <span class="annotation"><span class="desc">class name<i></i></span><span class="subject"><span class="token_keyword">BUTTON</span></span></span><span class="token_punctuation">,</span> <span class="annotation"><span class="desc">style<i></i></span><span class="subject"><span class="token_identifier">BS_CHECKBOX</span> <span class="token_operator">|</span> <span class="token_identifier">WS_TABSTOP</span></span></span><span class="token_punctuation">,</span> 2<span class="token_punctuation">,</span> 3<span class="token_punctuation">,</span> 4<span class="token_punctuation">,</span> 5</code></pre>

There is something bizarre about the "style" parameter of a generic control statement, though. For whatever reason, it allows an extra token within it and will act as if it doesn't exist.

<pre style="margin-top: 3em; overflow: visible; white-space: pre-wrap;"><code class="language-c" style="white-space: inherit;"><span style="opacity:50%;">CONTROL, "text", 1, BUTTON,</span> <span style="outline:2px dotted blue; position:relative; display:inline-block;"><span class="token_identifier">BS_CHECKBOX</span> <span class="token_operator">|</span> <span class="token_identifier">WS_TABSTOP</span> <span class="token_string">"why is this allowed"</span><span class="hexdump-tooltip rcdata">style<i></i></span></span><span style="opacity: 50%;">, 2, 3, 4, 5</span></code></pre>

The `"why is this allowed"` string is completely ignored, and this `CONTROL` will be compiled exactly the same as the previous `CONTROL` statement shown above.

<p><aside class="note">

- This bug/quirk requires there to be no comma before the extra token. In the above example, if there is a comma between the `BS_CHECKBOX | WS_TABSTOP` and the `"why is this allowed"`, then it will (properly) error with `expected numerical dialog constant`
- This bug/quirk is specific to the `style` parameter of `CONTROL` statements. In non-generic controls, the style parameter is optional and comes after the `h` parameter, but it does not exhibit this behavior

</aside></p>

The extra token can be many things (string, number, `=`, etc), but not *anything*. For example, if the extra token is `;`, then it will error with `expected numerical dialog constant`.

#### `CONTROL`: "Okay, I see that expression, but I don't understand it"

Instead of a single extra token in the `style` parameter of a `CONTROL`, it's also possible to sneak an extra number expression in there like so:

<pre style="margin-top: 3em; overflow: visible; white-space: pre-wrap;"><code class="language-c" style="white-space: inherit;"><span style="opacity:50%;">CONTROL, "text", 1, BUTTON,</span> <span style="outline:2px dotted blue; position:relative; display:inline-block;"><span class="token_identifier">BS_CHECKBOX</span> <span class="token_operator">|</span> <span class="token_identifier">WS_TABSTOP</span> <span class="token_punctuation">(</span>7<span class="token_operator">+</span>8<span class="token_punctuation">)</span><span class="hexdump-tooltip rcdata">style<i></i></span></span><span style="opacity: 50%;">, 2, 3, 4, 5</span></code></pre>

In this case, the Windows RC compiler no longer ignores the expression, but still behaves strangely. Instead of the entire `(7+8)` expression being treated as the `x` parameter like you might expect, in this case *only the* `8` in the expression is treated as the `x` parameter, so it ends up interpreted like this:

<pre class="annotated-code"><code class="language-c" style="white-space: inherit;"><span style="opacity:50%;">CONTROL, "text", 1, BUTTON,</span> <span class="annotation"><span class="desc">style<i></i></span><span class="subject"><span class="token_identifier">BS_CHECKBOX</span> <span class="token_operator">|</span> <span class="token_identifier">WS_TABSTOP</span></span></span> <span style="opacity:50%;">(7+</span><span class="annotation"><span class="desc">x<i></i></span><span class="subject">8</span></span><span style="opacity:50%;">)</span><span class="token_punctuation">,</span> <span class="annotation"><span class="desc">y<i></i></span><span class="subject">2</span></span><span class="token_punctuation">,</span> <span class="annotation"><span class="desc">w<i></i></span><span class="subject">3</span></span><span class="token_punctuation">,</span> <span class="annotation"><span class="desc">h<i></i></span><span class="subject">4</span></span><span class="token_punctuation">,</span> <span class="annotation"><span class="desc">exstyle<i></i></span><span class="subject">5</span></span></code></pre>

My guess is that the similarity between this number-expression-related-behavior and ["*Number expressions as filenames*"](#number-expressions-as-filenames) is not a coincidence, but beyond that I couldn't tell you what's going on here.

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
  <code class="language-c">1<span class="token_ansi_c_whitespace token_whitespace"> </span><span class="token_identifier">RCDATA</span><span class="token_ansi_c_whitespace token_whitespace"> </span><span class="token_punctuation">{</span><span class="token_ansi_c_whitespace token_whitespace"> </span><span style="outline: 1px dashed red; padding: 0 3px;">1</span><span class="token_punctuation">,</span><span class="token_ansi_c_whitespace token_whitespace"> </span><span style="outline: 1px dashed orange; padding: 0 3px;">2L</span><span class="token_ansi_c_whitespace token_whitespace"> </span><span class="token_punctuation">}</span><span class="token_ansi_c_whitespace token_whitespace">
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

```rc
1 DIALOG 1, 1L, 65537, 65537L {}
```

A few particular parameters, though, fully disallow integer literals with the `L` suffix from being used:

- Any of the four parameters of the `FILEVERSION` statement of a `VERSIONINFO` resource
- Any of the four parameters of the `PRODUCTVERSION` statement of a `VERSIONINFO` resource
- Any of the two parameters of a `LANGUAGE` statement

<div class="short-rc-and-result">
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```rc style="display: flex; flex-direction: column; justify-content: center; align-items: center; flex-grow: 1; margin-top: 0;"
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

```rc style="display: flex; flex-direction: column; justify-content: center; align-items: center; flex-grow: 1; margin-top: 0;"
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

```rc
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

Getting back to resource compilation, `FONT` resources within `.rc` files are collected and compiled into the following resources:

- A `RT_FONT` resource for each `FONT`, where the data is the verbatim file contents of the `.fnt` file
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

I'm still not quite sure what the best course of action is here. I've [written up what I see as the possibilities here](https://squeek502.github.io/resinator/windows/resources/font.html#so-really-what-should-go-in-the-fontdir), and for now I've gone with what I'm calling the "semi-compatibility while avoiding the sharp edges" approach:

> Do something similar enough to the Win32 compiler in the common case, but avoid emulating the buggy behavior where it makes sense. That would look like a `FONTDIRENTRY` with the following format:
>
> - The first 148 bytes from the file verbatim, with no interpretation whatsoever, followed by two `NUL` bytes (corresponding to 'device name' and 'face name' both being zero length strings)
>
> This would allow the `FONTDIR` to match byte-for-byte with the Win32 RC compiler in the common case (since very often the misinterpreted `dfDevice`/`dfFace` will be `0` or point somewhere outside the bounds of the file and therefore will be written as a zero-length string anyway), and only differ in the case where the Win32 RC compiler writes some bogus string(s) to the `szDeviceName`/`szFaceName`.
>
> This also enables the use-case of non-`.FNT` files without any loose ends.

In short: write the new/undocumented `FONTDIRENTRY` format, but avoid the crashes, avoid the negative integer-related errors, and always write `szDeviceName` and `szFaceName` as 0-length.

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">parser bug/quirk, utterly baffling</span>

### Subtracting zero can lead to bizarre results

This compiles:

```rc
1 DIALOGEX 1, 2, 3, 4 - 0 {}
```

This doesn't:

<div class="short-rc-and-result">
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```rc style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0;"
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

```rc
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

<pre class="annotated-code"><code class="language-c" style="white-space: inherit;"><span class="annotation"><span class="desc">id<i></i></span><span class="subject">+5</span></span> <span class="annotation"><span class="desc">type<i></i></span><span class="subject"><span class="token_identifier">{}</span></span></span> <span class="annotation"><span class="desc">filename<i></i></span><span class="subject"><span class="token_string">hello</span></span></span></code></pre>

So, somehow, the subtraction of the zero caused the `BEGIN expected in dialog` error, and then the Windows RC compiler immediately restarted its parser state and began parsing a new resource definition from scratch. This doesn't give much insight into why subtracting zero causes an error in the first place, but I thought it was a slightly interesting additional wrinkle.

#### `resinator`'s behavior

`resinator` does not treat subtracting zero as special, and therefore never errors on any expressions that subtract zero.

Ideally, a warning would be emitted in cases where the Windows RC compiler would error, but detecting when that would be the case is not something I'm capable of doing currently.

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">preprocessor bug/quirk, parser bug/quirk</span>

### Multiline strings don't behave as expected/documented

Within the [`STRINGTABLE` resource documentation](https://learn.microsoft.com/en-us/windows/win32/menurc/stringtable-resource) we see this statement:

> The string [...] must occupy a single line in the source file (unless a '&bsol;' is used as a line continuation).

<p><aside class="note">

Note: While this documentation is for `STRINGTABLE`, it actually applies to string literals in `.rc` files generally. In other words, there's nothing special about how `STRINGTABLE` handles string literals, and the bugs/quirks described below apply to all resource types.

</aside></p>

This is similar to the rules around C strings:

<div class="short-rc-and-result">
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```c style="display: flex; flex-direction: column; justify-content: center; flex-grow: 1; margin-top: 0;"
char *my_string = "Line 1
Line 2";
```

</div>
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```resinatorerror style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0;"
multilinestring.c:1:19: error: missing terminating '"' character
char *my_string = "Line 1
                  ^
```

</div>
</div>

<p style="margin-top: 0; text-align: center;"><i class="caption">Splitting a string across multiple lines without using <code>&bsol;</code> is an error in C</i></p>

<div class="short-rc-and-result">
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```c style="display: flex; flex-direction: column; justify-content: center; flex-grow: 1; margin-top: 0;"
char *my_string = "Line 1 \
Line 2";
```

</div>
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
<p style="margin-top: 0; margin-bottom: .5em;"><code>printf("%s\n", my_string);</code> results in:</p>

```none style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0;"
Line 1 Line 2
```

</div>
</div>

And yet, contrary to the documentation, splitting a string across multiple lines without `\` continuations *is not an error* in the Windows RC compiler. Here's an example:

```rc
1 RCDATA {

"foo
bar"

}
```

This will successfully compile, and the data of the `RCDATA` resource will end up as

<pre style="overflow: visible; padding-top: 3.5em; padding-bottom: 3.5em;"><code class="language-none"><span class="token_string">66 6F 6F</span> <span style="outline: 2px dotted orange;">20</span> <span style="outline: 2px dotted red;">0A</span> <span class="token_string">62 61 72</span>   <span class="token_string">foo</span><span style="outline: 2px dotted orange; position:relative; display:inline-block;"> <span class="hexdump-tooltip below">space<i></i></span></span><span style="outline: 2px dotted red; position:relative; display:inline-block;">.<span class="hexdump-tooltip">\n<i></i></span></span><span class="token_string">bar</span></code></pre>

I'm not sure why this is allowed, and I also don't have an explanation for why a space character sneaks into the resulting data out of nowhere. It's also worth noting that whitespace is collapsed in these should-be-invalid multiline strings. For example, this:

```rc
"foo

    bar"
```

will get compiled into exactly the same data as above (with only a space and a newline between `foo` and `bar`).

</aside></p>

But, this on its own is only a minor nuisance from the perspective of implementing a resource compiler&mdash;it is undocumented behavior, but it's pretty easy to account for. The real problems start when someone actually uses `\` as intended.

#### The collapse of whitespace is imminent

C pop quiz: what will get printed in this example (i.e. what will `my_string` evaluate to)?

```c
char *my_string = "Line 1 \
                   Line 2";

#include <stdio.h>

int main() {
  printf("%s\n", my_string);
  return 0;
}
```

Let's compile it with a few different compilers to find out:

```shellsession
> zig run multilinestring.c -lc
Line 1                    Line 2

> clang multilinestring.c
> a.exe
Line 1                    Line 2

> cl.exe multilinestring.c
> multilinestring.exe
Line 1                    Line 2
```

That is, the whitespace preceding "Line 2" is included in the string literal.

<p><aside class="note">

Note: In most C compiler implementations, the `\` is processed and removed during the preprocessing step. For example, here's the result when running the input through the `clang` preprocessor:

```shellsession
> clang -E -xc multilinestring.c
# 1 "multilinestring.c" 2
char *my_string = "Line 1                    Line 2";
```

Something odd, though, is that this is not how the MSVC compiler works. When running its preprocessor, we end up with this:

```shellsession
> cl.exe /E multilinestring.c
#line 1 "multilinestring.c"
char *my_string = "Line 1 \
                   Line 2";
```

so in the MSVC implementation, it's up to the C parser to handle the `\`. This is not fully relevant to the Windows RC compiler, but it was surprising to me.

</aside></p>

However, the Windows RC compiler behaves differently here. If we pass the same example through *its* preprocessor, we end up with:

```c
#line 1 "multilinestring.c"
char *my_string = "Line 1 \
Line 2";
```

1. The `\` remains (similar to the MSVC compiler, see the note above)
2. The whitespace before "Line 2" is removed

So the value of `my_string` would be `Line 1 Line 2` (well, not really, since `char *my_string = ` doesn't have a meaning in `.rc` files, but you get the idea). This divergence in behavior from C has practical consequences. In [this `.rc` file](https://github.com/microsoft/Windows-classic-samples/blob/main/Samples/Win7Samples/winui/shell/appshellintegration/NonDefaultDropMenuVerb/NonDefaultDropMenuVerb.rc) from one of the [Windows-classic-samples](https://github.com/microsoft/Windows-classic-samples) example programs, we see the following, which takes advantage of the `rc.exe`-preprocessor-specific-whitespace-collapsing behavior:

```rc
STRINGTABLE 
BEGIN
    // ...
    IDS_MESSAGETEMPLATEFS   "The drop target is %s.\n\
                            %d files/directories in HDROP\n\
                            The path to the first object is\n\
                            \t%s."
    // ...
END
```

Plus, in certain circumstances, this difference between `rc.exe` and C (like [other differences to C](#all-operators-have-equal-precedence)) can lead to bugs. This is a rather contrived example, but here's one way things could go wrong:

```c
// In foo.h
#define FOO_TEXT "foo \
                  bar"
#define IDC_BUTTON_FOO 1001
```
```rc
// In foo.rc
#include "foo.h"

1 DIALOGEX 0, 0, 275, 280
BEGIN
    PUSHBUTTON FOO_TEXT, IDC_BUTTON_FOO, 7, 73, 93, 14
END
```
```c
// In main.c
#include "foo.h"

// ...
    HWND hFooBtn = GetDlgItem(hDlg, IDC_BUTTON_FOO);
    // Let's say the button text was changed while it was hovered
    // and now we want to set it back to the default
    SendMessage(hFooBtn, WM_SETTEXT, 0, (LPARAM) _T(FOO_TEXT));
// ...
```

In this example, the button defined in the `DIALOGEX` would start with the text `foo bar`, since that is the value that the Windows RC compiler resolves `FOO_TEXT` to be, but the `SendMessage` call would then set the text to <code>foo&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;bar</code>, since that's what the C compiler resolves `FOO_TEXT` to be.

#### `resinator`'s behavior

`resinator` uses the [Aro preprocessor](https://github.com/Vexu/arocc), which means it acts like a C compiler. In the future, `resinator` will likely fork Aro ([mostly to support UTF-16 encoded files](https://github.com/squeek502/resinator/issues/5)), which could allow matching the behavior of `rc.exe` in this case as well.

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">parser bug/quirk</span>

### All operators have equal precedence

TODO

https://devblogs.microsoft.com/oldnewthing/20230313-00/?p=107928

#### `resinator`'s behavior

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">parser bug/quirk, utterly baffling</span>

### Escaping quotes is fraught

From the [`STRINGTABLE` resource docs](https://learn.microsoft.com/en-us/windows/win32/menurc/stringtable-resource):

> To embed quotes in the string, use the following sequence: `""`. For example, `"""Line three"""` defines a string that is displayed as follows:
> ```
> "Line three"
> ```

This is different from C, where `\"` is used to escape quotes within a string literal, so in C to get `"Line three"` you'd do `"\"Line three\""`.

<p><aside class="note">

Note: I have no idea why the method for quote escaping would differ from C. The only thing I can think of is that it would allow for the use of `\` within string literals in order to make specifying paths in string literals more convenient, but that can't be true because in e.g.

```c
"some\new\path"
```

the `\n` gets parsed into `0x0A`.

</aside></p>

This difference, though, can lead to some really bizarre results, since the preprocessor *still uses the C escaping rules*. Take this simple example:

```none
"\""BLAH"
```

Here's how that is seen from the perspective of the preprocessor:

<pre class="annotated-code"><code class="language-c" style="white-space: inherit;"><span class="annotation"><span class="desc">string<i></i></span><span class="subject"><span class="token_string">"\""</span></span></span><span class="annotation"><span class="desc">identifier<i></i></span><span class="subject"><span class="token_identifier">BLAH</span></span></span><span class="annotation"><span class="desc">string (unfinished)<i></i></span><span class="subject"><span class="token_string">"</span></span></span></code></pre>

And from the perspective of the compiler:

<pre class="annotated-code"><code class="language-c" style="white-space: inherit;"><span class="annotation"><span class="desc">string<i></i></span><span class="subject"><span class="token_string">"\""BLAH"</span></span></span></code></pre>

So, following from this, say you had this `.rc` file:

```rc
#define BLAH "hello"

1 RCDATA { "\""BLAH" }
```

Since we know the preprocessor sees `BLAH` as an identifier and we've done `#define BLAH "hello"`, it will replace `BLAH` with `"hello"`, leading to this result:

```rc
1 RCDATA { "\"""hello"" }
```

which would now be parsed by the compiler as:

<pre class="annotated-code"><code class="language-c" style="white-space: inherit;"><span class="annotation"><span class="desc">string<i></i></span><span class="subject"><span class="token_string">"\"""</span></span></span><span class="annotation"><span class="desc">identifier<i></i></span><span class="subject"><span class="token_identifier">hello</span></span></span><span class="annotation"><span class="desc">string<i></i></span><span class="subject"><span class="token_string">""</span></span></span></span></span></span></code></pre>

and lead to a compile error:

```
test.rc(3) : error RC2104 : undefined keyword or key name: hello
```

This is just one example, but the general disagreement around escaped quotes between the preprocessor and the compiler can lead to some really unexpected error messages.

#### Wait, but what actually happens to the backslash?

Backing up a bit, I said that the compiler sees `"\""BLAH"` as one string literal token, so:

<pre class="annotated-code"><code class="language-c" style="white-space: inherit;">1 <span class="token_keyword">RCDATA</span> <span class="token_punctuation">{</span> <span class="annotation"><span class="desc">string<i></i></span><span class="subject"><span class="token_string" style="outline: 2px dotted rgba(150,150,150,0.5)">"\""BLAH"</span></span></span> <span class="token_punctuation">}</span></code></pre>

If we compile this, then the data of this `RCDATA` resource ends up as:

```
"BLAH
```

That is, the `\` fully drops out and the `""` is treated as an escaped quote. This seems to some sort of special case, as this behavior is not present for other unrecognized escape sequences, e.g. `"\k"` will end up as `\k` when compiled, and `"\"` will end up as `\`.


#### `resinator`'s behavior

Using `\"` within string literals is always an error, since (as mentioned) it can lead to things like unexpected macro expansions and hard-to-understand errors when the preprocessor and the compiler disagree.

```resinatorerror
test.rc:1:13: error: escaping quotes with \" is not allowed (use "" instead)
1 RCDATA { "\""BLAH" }
            ^~
```

This may change if it turns out `\"` is commonly used in the wild, but that seems unlikely to be the case.

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">parser bug/quirk</span>

### That's not *my* `\a`

The Windows RC compiler supports some (but not all) [C escape sequences](https://en.wikipedia.org/wiki/Escape_sequences_in_C) within string literals.

<div class="grid-max-2-col">
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
<div class="box-border box-bg" style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0;">

<p style="margin-bottom:0; text-align: center;">Supported</p>

- `\a`
- `\n`
- `\r`
- `\t`
- `\nnn` (or `\nnnnnnn` in wide literals)
- `\xhh` (or `\xhhhh` in wide literals)

<aside style="padding: 0 2em; opacity: 0.75; text-align:center;">

(side note: In the Windows RC compiler, `\a` and `\t` are case-insensitive, while `\n` and `\r` are case-sensitive)

</aside>

</div>
</div>
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
<div class="box-border box-bg" style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0;">

<p style="margin-bottom:0; text-align: center;">Unsupported</p>

- `\b`
- `\e`
- `\f`
- `\v`
- `\'`
- `\"` (see ["*Escaping quotes is fraught*"](#escaping-quotes-is-fraught))
- `\?`
- `\uhhhh`
- `\Uhhhhhhhh`

</div>
</div>
</div>

All of the supported escape sequences behave similarly to how they do in C, with the exception of `\a`. In C, `\a` is translated to the hex value `0x07` (aka the "Alert (Beep, Bell)" control character), while the Windows RC compiler translates `\a` to `0x08` (aka the "Backspace" control character).

On first glance, this seems like a bug, but there may be some historical reason for this that I'm missing the context for.

#### `resinator`'s behavior

`resinator` matches the behavior of the Windows RC compiler, translating `\a` to `0x08`.

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">parser bug/quirk, miscompilation</span>

### Yes, that `MENU` over there (vague gesturing)

As established in the intro, resource definitions typically have an `id`, like so:

<pre class="annotated-code"><code class="language-c" style="white-space: inherit;"><span class="annotation"><span class="desc">id<i></i></span><span class="subject">1</span></span> <span class="token_identifier">FOO</span> <span class="token_punctuation">{</span> <span class="token_string">"bar"</span> <span class="token_punctuation">}</span></code></pre>

The `id` can be either a number ("ordinal") or a string ("name"), and the type of the `id` is inferred by its contents. This mostly works as you'd expect:

- If the `id` is all digits, then it's a number/ordinal
- If the `id` is all letters, then it's a string/name
- If the `id` is a mix of digits and letters, then it's a string/name

Here's a few examples:

<pre><code class="language-none"> 123    ───►  Ordinal: <span class="token_number">123</span>
 ABC    ───►  Name: <span class="token_string">ABC</span>
123ABC  ───►  Name: <span class="token_string">123ABC</span></code></pre>

This is relevant, because when defining `DIALOG`/`DIALOGEX` resources, there is an optional `MENU` statement that can specify the `id` of a separately defined `MENU`/`MENUEX` resource to use. From [the `DIALOGEX` docs](https://learn.microsoft.com/en-us/windows/win32/menurc/dialogex-resource):

<blockquote>
<table style="width: 100%; text-align: left;">
  <thead>
    <tr>
      <th>Statement</th>
      <th>Description</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td><b>MENU</b> <i>menuname</i></code></td>
      <td>Menu to be used. This value is either the name of the menu or its integer identifier.</td>
    </tr>
  </tbody>
</table>
</blockquote>

Here's an example of that in action, where the `DIALOGEX` is attempting to specify that the `MENUEX` with the `id` of `1ABC` should be used:

<pre><code class="language-c" style="display:block;"><span class="token_identifier" style="outline: 2px dotted orange;">1ABC</span> <span class="token_keyword">MENUEX</span>  <span class="token_function">◄╍╍╍╍╍╍╍╍╍╍╍╍╍╍┓</span>
<span style="opacity: 50%;">{</span>                           <span class="token_function">┇</span>
<span style="opacity: 50%;">  // ...</span>                    <span class="token_function">┇</span>
<span style="opacity: 50%;">}</span>                           <span class="token_function">┇</span>
                            <span class="token_function">┇</span>
<span style="opacity: 50%;">1 DIALOGEX 0, 0, 640, 480</span>   <span class="token_function">┇</span>
  <span class="token_keyword">MENU</span> <span class="token_identifier" style="outline: 2px dotted orange;">1ABC</span>  <span class="token_function">╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍┛</span>
<span style="opacity: 50%;">{
  // ...
}</span></code></pre>

However, this is not what actually occurs, as for some reason, the `MENU` statement has different rules around inferring the type of the `id`&mdash;for the `MENU` statement, whenever the first character is a number, then the whole `id` is interpreted as a number no matter what.

The value of this "number" is determined using the same bogus methodology detailed in ["*Non-ASCII digits in number literals*"](#non-ascii-digits-in-number-literals), so in the case of `1ABC`, the value works out to 2899:

<div style="display: grid; grid-gap: 10px; grid-template-columns: repeat(3, 1fr);">
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```none style="display: flex; flex-grow: 1; justify-content: center; align-items: center; margin: 0;"
1ABC
```

</div>
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```c style="display: flex; flex-grow: 1; justify-content: center; align-items: center; margin: 0;"
'1' - '0' = 1
'A' - '0' = 17
'B' - '0' = 18
'C' - '0' = 19
```

</div>
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```c style="display: flex; flex-grow: 1; justify-content: center; align-items: center; margin: 0;"
 1 * 1000 = 1000
 17 * 100 = 1700
  18 * 10 =  180
   19 * 1 =   19
⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯
            2899
```

</div>
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;"><i class="caption">"numeric" id</i></div>
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;"><i class="caption">numeric value of each "digit"</i></div>
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;"><i class="caption">numeric value of the id</i></div>
</div>

Unlike ["*Non-ASCII digits in number literals*"](#non-ascii-digits-in-number-literals), though, it's now also possible to include characters in a "number" literal that have a *lower* ASCII value than the `'0'` character, meaning that attempting to get the numeric value for such a 'digit' will induce wrapping `u16` overflow:

<div style="display: grid; grid-gap: 10px; grid-template-columns: repeat(3, 1fr);">
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```none style="display: flex; flex-grow: 1; justify-content: center; align-items: center; margin: 0;"
1!
```

</div>
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

<pre style="display: flex; flex-grow: 1; justify-content: center; align-items: center; margin: 0;"><code class="language-c"><span class="token_string">'1'</span><span class="token_ansi_c_whitespace token_whitespace"> </span><span class="token_operator">-</span><span class="token_ansi_c_whitespace token_whitespace"> </span><span class="token_string">'0'</span><span class="token_ansi_c_whitespace token_whitespace"> </span><span class="token_operator">=</span><span class="token_ansi_c_whitespace token_whitespace"> </span><span class="token_number">1</span><span class="token_ansi_c_whitespace token_whitespace">
</span><span class="token_string">'!'</span><span class="token_ansi_c_whitespace token_whitespace"> </span><span class="token_operator">-</span><span class="token_ansi_c_whitespace token_whitespace"> </span><span class="token_string">'0'</span><span class="token_ansi_c_whitespace token_whitespace"> </span><span class="token_operator">=</span><span class="token_ansi_c_whitespace token_whitespace"> </span><span class="token_warning">-15</span><span class="token_ansi_c_whitespace token_whitespace">
      </span><span class="token_warning">-15</span><span class="token_ansi_c_whitespace token_whitespace"> </span><span class="token_operator">=</span><span class="token_ansi_c_whitespace token_whitespace"> </span><span class="token_number">65521</span><span class="token_ansi_c_whitespace token_whitespace">
</span></code></pre>

</div>
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```c style="display: flex; flex-grow: 1; justify-content: center; align-items: center; margin: 0;"
    1 * 10 =    10
 65521 * 1 = 65521
⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯
             65531
```

</div>
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;"><i class="caption">"numeric" id</i></div>
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;"><i class="caption">numeric value of each "digit"</i></div>
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;"><i class="caption">numeric value of the id</i></div>
</div>

#### This is always a miscompilation

In the following example using the same `1ABC` ID as above:

```rc
// In foo.rc
1ABC MENU
BEGIN
  POPUP "Menu from .rc"
  BEGIN
    MENUITEM "Open File", 1
  END
END

1 DIALOGEX 0, 0, 275, 280
  CAPTION "Dialog from .rc"
  MENU 1ABC
BEGIN
END
```

```c
// In main.c
// ...
    HWND result = CreateDialogParamW(g_hInst, MAKEINTRESOURCE(1), hwnd, DialogProc, (LPARAM)NULL);
// ...
```

This `CreateDialogParamW` call will fail with `The specified resource name cannot be found in the image file` because when loading the dialog, it will attempt to look for a menu resource with an integer ID of `2899`.

If we add such a `MENU` to the `.rc` file:

```rc
2899 MENU
BEGIN
  POPUP "Wrong menu from .rc"
  BEGIN
    MENUITEM "Destroy File", 1
  END
END
```

then the dialog will successfully load with this new menu, but it's pretty obvious this is *not* what was intended:

<div style="text-align: center;">
<img style="margin-left:auto; margin-right:auto; display: block;" src="/images/every-rc-exe-bug-quirk-probably/rc-wrong-menu.png">
<i class="caption">The misinterpretation of the ID can (at best) lead to an unexpected menu being loaded</i>
</div>

#### A related, but inconsequential, inconsistency

As mentioned in ["*Special tokenization rules for names/IDs*"](#special-tokenization-rules-for-names-ids), when the `id` of a resource is a string/name, it is uppercased before being written to the `.res` file. This uppercasing is *not* done for the `MENU` statement of a `DIALOG`/`DIALOGEX` resource, so in this example:

<pre><code class="language-c" style="display:block;"><span class="token_identifier">abc</span> <span class="token_keyword">MENUEX</span>
<span style="opacity: 50%;">{</span>
<span style="opacity: 50%;">  // ...</span>
<span style="opacity: 50%;">}</span>

<span style="opacity: 50%;">1 DIALOGEX 0, 0, 640, 480</span>
  <span class="token_keyword">MENU</span> <span class="token_identifier">abc</span>
<span style="opacity: 50%;">{
  // ...
}</span></code></pre>

The `id` of the `MENUEX` resource would be compiled as `ABC`, but the `DIALOGEX` would write the `id` of its menu as `abc`. This ends up not mattering, though, because it appears that `LoadMenu` does a case-insensitive lookup for string IDs.

#### `resinator`'s behavior

`resinator` avoids the miscompilation and treats the `id` parameter of `MENU` statements in `DIALOG`/`DIALOGEX` resources exactly the same as the `id` of `MENU` resources.

```resinatorerror
test.rc:3:8: warning: the id of this menu would be miscompiled by the Win32 RC compiler
  MENU 1ABC
       ^~~~
test.rc:3:8: note: the Win32 RC compiler would evaluate the id as the ordinal/number value 2899

test.rc:3:8: note: to avoid the potential miscompilation, the first character of the id should not be a digit
```

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">parser bug/quirk</span>

### If you're not last, you're irrelevant

Many resource types have optional statements that can be specified between the resource type and the beginning of its body, e.g.

```rc
1 ACCELERATORS
  LANGUAGE 0x09, 0x01
  CHARACTERISTICS 0x1234
  VERSION 1
{
  // ...
}
```

Specifying multiple statements of the same type within a single resource definition is allowed, and the last occurrence of each statement type is the one that takes precedence, so the following would compile to the exact same `.res` as the example above:

```rc
1 ACCELERATORS
  CHARACTERISTICS 1
  LANGUAGE 0xFF, 0xFF
  LANGUAGE 0x09, 0x01
  CHARACTERISTICS 999
  CHARACTERISTICS 0x1234
  VERSION 999
  VERSION 1
{
  // ...
}
```

This is not necessarily a problem on its own (although I think it should at least be a warning), but it can inadvertently lead to some bizarre behavior, as we'll see in the next bug/quirk.


#### `resinator`'s behavior

`resinator` matches the Windows RC compiler behavior, but emits a warning for each ignored statement:

```resinatorerror
test.rc:2:3: warning: this statement was ignored; when multiple statements of the same type are specified, only the last takes precedence
  CHARACTERISTICS 1
  ^~~~~~~~~~~~~~~~~
test.rc:3:3: warning: this statement was ignored; when multiple statements of the same type are specified, only the last takes precedence
  LANGUAGE 0xFF, 0xFF
  ^~~~~~~~~~~~~~~~~~~
test.rc:5:3: warning: this statement was ignored; when multiple statements of the same type are specified, only the last takes precedence
  CHARACTERISTICS 999
  ^~~~~~~~~~~~~~~~~~~
test.rc:7:3: warning: this statement was ignored; when multiple statements of the same type are specified, only the last takes precedence
  VERSION 999
  ^~~~~~~~~~~
```

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">parser bug/quirk, miscompilation</span>

### Once a number, always a number

The behavior described in ["*Yes, that `MENU` over there (vague gesturing)*"](#yes-that-menu-over-there-vague-gesturing) can also be induced in both `CLASS` and `MENU` statements of `DIALOG`/`DIALOGEX` resources via redundant statements. As seen in ["*If you're not last, you're irrelevant*"](#if-you-re-not-last-you-re-irrelevant), multiple statements of the same type are allowed to be specified without much issue, but in the case of `CLASS` and `MENU`, if any of the duplicate statements are interpreted as a number, then the value of last statement of its type (the only one that matters) *is always interpreted as a number no matter what it contains*.

<pre><code class="language-c" style="display:block;"><span style="opacity: 50%;">1 DIALOGEX 0, 0, 640, 480</span>
  <span class="token_keyword">MENU</span> <span class="token_identifier">123</span> <span class="token_comment">// ignored, but causes the string below to be evaluated as a number</span>
  <span class="token_keyword">MENU</span> <span class="token_identifier">IM_A_STRING_I_SWEAR</span>  <span class="token_function">────►</span>  <span class="token_function">8360</span>
  <span class="token_keyword">CLASS</span> <span class="token_identifier">123</span> <span class="token_comment">// ignored, but causes the string below to be evaluated as a number</span>
  <span class="token_keyword">CLASS</span> <span class="token_string">"Seriously, I'm a string"</span>  <span class="token_function">────►</span>  <span class="token_function">55127</span>
<span style="opacity: 50%;">{
  // ...
}</span></code></pre>

The algorithm for coercing the strings to a number is the same as the one outlined in ["*Yes, that `MENU` over there (vague gesturing)*"](#yes-that-menu-over-there-vague-gesturing), and, for the same reasons discussed there, this too is always a miscompilation.

#### `resinator`'s behavior

`resinator` avoids the miscompilation and emits warnings:

```resinatorerror
test.rc:2:3: warning: this statement was ignored; when multiple statements of the same type are specified, only the last takes precedence
  MENU 123
  ^~~~~~~~
test.rc:4:3: warning: this statement was ignored; when multiple statements of the same type are specified, only the last takes precedence
  CLASS 123
  ^~~~~~~~~
test.rc:5:9: warning: this class would be miscompiled by the Win32 RC compiler
  CLASS "Seriously, I'm a string"
        ^~~~~~~~~~~~~~~~~~~~~~~~~
test.rc:5:9: note: the Win32 RC compiler would evaluate it as the ordinal/number value 55127

test.rc:5:9: note: to avoid the potential miscompilation, only specify one class per dialog resource

test.rc:3:8: warning: the id of this menu would be miscompiled by the Win32 RC compiler
  MENU IM_A_STRING_I_SWEAR
       ^~~~~~~~~~~~~~~~~~~
test.rc:3:8: note: the Win32 RC compiler would evaluate the id as the ordinal/number value 8360

test.rc:3:8: note: to avoid the potential miscompilation, only specify one menu per dialog resource
```

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">parser bug/quirk</span>

### FONT parameter inheritance

The `weight` and `italic` parameters of a `FONT` statement get carried over to subsequent `FONT` statements attached to a `DIALOGEX` resource if the subsequent `FONT` statements don't provide those parameters, but `charset` doesn't (it will always have a default of `1` (`DEFAULT_CHARSET`) if not specified).

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

.token_unrepresentable {
  color: #9a6e3a;
  background: hsla(0, 0%, 0%, .1);
  border: 1px dotted hsla(0, 0%, 0%, .3);
  cursor: help;
}
@media (prefers-color-scheme: dark) {
.token_unrepresentable {
  color: #B68A55;
  background: hsla(0, 0%, 100%, .1);
  border-color: hsla(0, 0%, 100%, .3);
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

.box-border {
  border: 1px solid #eee;
}
@media (prefers-color-scheme: dark) {
.box-border {
  border-color: #111;
}
}
.box-bg {
  background: rgba(100,100,100,0.05);
}
@media (prefers-color-scheme: dark) {
.box-bg {
  background: rgba(50,50,50,0.2);
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

.gets-parsed-as {
  display: grid;
  grid-template-columns: repeat(1, 1fr);
  grid-gap: 10px;
}
@media only screen and (min-width: 800px) {
  .gets-parsed-as {
    display: grid;
    grid-template-columns: 1fr 0.5fr 1fr;
    grid-gap: 10px;
  }
}

.tab-gets-compiled-to {
  display: grid;
  grid-template-columns: repeat(1, 1fr);
  grid-gap: 10px;
}
@media only screen and (min-width: 800px) {
  .tab-gets-compiled-to {
    display: grid;
    grid-template-columns: 1fr 1fr 1fr;
    grid-gap: 10px;
  }
}

pre code .inblock { position:relative; display:inline-block; }

.hexdump .infotip { cursor: help; }
.hexdump .o1d { outline: 1px dashed; }
.hexdump .o2d { outline: 2px dashed; }
.hexdump .o1s { outline: 1px solid; }
.hexdump .o2s { outline: 2px solid; }
.hexdump .o-clr1 { outline-color: rgba(255,0,0); }
.hexdump .bg-clr1 { background: rgba(255,0,0,.1); }
.hexdump .o-clr2 { outline-color: rgba(0,0,255); }
.hexdump .bg-clr2 { background: rgba(0,0,255,.1); }
.hexdump .o-clr3 { outline-color: rgba(150,0,255); }
.hexdump .bg-clr3 { background: rgba(150,0,255,.1); }
.hexdump .o-clr4 { outline-color: rgba(0,255,0); }
.hexdump .bg-clr4 { background: rgba(0,255,0,.1); }
.hexdump .o-clr5 { outline-color: rgba(124,70,0); }
.hexdump .bg-clr5 { background: rgba(124,70,0,.1); } 
@media (prefers-color-scheme: dark) {
.hexdump .o-clr2 { outline-color: rgba(100,170,255); }
.hexdump .bg-clr2 { background: rgba(100,170,255,.1); }
.hexdump .o-clr4 { outline-color: rgba(0,150,0); }
.hexdump .bg-clr4 { background: rgba(0,220,0,.1); }
.hexdump .o-clr5 { outline-color: rgba(255,216,0); }
.hexdump .bg-clr5 { background: rgba(255,216,0,.1); }
}
</style>

</div>