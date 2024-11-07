- `7 NOT NOT 4 NOT 2 NOT NOT 1` is a valid expression
- `०००` is a number that gets parsed into the decimal value 65130
- A < 1 MiB icon file can get compiled into 127 TiB of data

The above is just a small sampling of a few of the strange behaviors of the Windows RC compiler (`rc.exe`). All of the above bugs/quirks, and many, many more, will be detailed and explained (to the best of my ability) in this post.

<p><aside class="note">

Note: If you have no familiarity with `rc.exe`, `.rc` files, or even Windows development at all, no need to worry&mdash;I have tried to organize this post such that it will get you up to speed as-you-read.

</aside></p>

## Context

Inspired by an [accepted proposal](https://github.com/ziglang/zig/issues/3702) for [Zig](https://ziglang.org/) to include support for compiling Windows resource script (`.rc`) files, I set out on what I thought at the time would be a somewhat straightforward side-project of writing a Windows resource compiler in Zig. Microsoft's RC compiler (`rc.exe`) is closed source, but alternative implementations are nothing new&mdash;there are multiple existing projects that tackle the same goal of an open source and cross-platform Windows resource compiler (in particular, `windres` and `llvm-rc`). I figured that I could use them as a reference, and that the syntax of `.rc` files didn't look too complicated.

**I was wrong on both counts.**

While the `.rc` syntax *in theory* is not complicated, there are edge cases hiding around every corner, and each of the existing alternative Windows resource compilers handle each edge case very differently from the canonical Microsoft implementation.

With a goal of byte-for-byte-identical-outputs (and possible bug-for-bug compatibility) for my implementation, I had to effectively start from scratch, as even [the Windows documentation couldn't be fully trusted to be accurate](https://github.com/MicrosoftDocs/win32/pulls?q=is%3Apr+author%3Asqueek502). Ultimately, I went with fuzz testing (with `rc.exe` as the source of truth/oracle) as my method of choice for deciphering the behavior of the Windows resource compiler (this approach is similar to something I did [with Lua](https://www.ryanliptak.com/blog/fuzzing-as-test-case-generator/) a while back).

This process led to a few things:

- A completely clean-room implementation of a Windows resource compiler (not even any decompilation of `rc.exe` involved in the process)
- A high degree of compatibility with the `rc.exe` implementation, including [byte-for-byte identical outputs](https://github.com/squeek502/win32-samples-rc-tests/) for a sizable corpus of Microsoft-provided sample `.rc` files (~500 files)
- A large list of strange/interesting/baffling behaviors of the Windows resource compiler

My resource compiler implementation, [`resinator`](https://github.com/squeek502/resinator), has now reached relative maturity and has [been merged into the Zig compiler](https://www.ryanliptak.com/blog/zig-is-a-windows-resource-compiler/) (but is also maintained as a standalone project), so I thought it might be interesting to write about all the weird stuff I found along the way.

<p><aside class="note">

Note: While this list is thorough, it is only indicative of my current understanding of `rc.exe`, which can always be incorrect. Even in the process of writing this article, I found new edge cases and had to correct my implementation of certain aspects of the compiler.

</aside></p>

## Who is this article for?

- If you work at Microsoft, consider this a large list of bug reports (of particular note, see everything labeled 'miscompilation')
  + If you're [Raymond Chen](https://devblogs.microsoft.com/oldnewthing/author/oldnewthing), then consider this an extension of/homage to all the (fantastic, very helpful) blog posts about Windows resources in [The Old New Thing](https://devblogs.microsoft.com/oldnewthing/)
- If you are a contributor to `llvm-rc`, `windres`, or `wrc`, consider this a long list of behaviors to test for (if strict compatibility is a goal)
- If you are someone that managed to [endure the bad audio of this talk I gave about my resource compiler](https://www.youtube.com/watch?v=RZczLb_uI9E) and wanted more, consider this an extension of that talk
- If you are none of the above, consider this an entertaining list of bizarre bugs/edge cases
  + If you'd like to skip around and check out the strangest bugs/quirks, `Ctrl+F` for 'utterly baffling'

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

<p><aside class="note">

Note: `rc.exe` has been around since the earliest versions of Windows (the old 16-bit `rc.exe` has the copyright years 1985-1992). The RC compiler was updated for the 32-bit Windows NT in the early 90's, and (as far as I can tell) has been mostly untouched since. So, it's worth keeping in mind that `rc.exe` is very likely made up, in large part, of code written 30+ years ago.

</aside></p>

An additional bit of context worth knowing is that `.rc` files were/are very often generated by Visual Studio rather than manually written-by-hand, which could explain why many of the bugs/quirks detailed here have gone undetected/unfixed for so long (i.e. the Visual Studio generator just so happened not to trigger these edge cases).

With that out of the way, we're ready to get into it.

## The list of bugs/quirks

<div class="bug-quirk-box">
<span class="bug-quirk-category">tokenizer quirk</span>

### Special tokenization rules for names/IDs

Here's a resource definition with a user-defined type of `FOO` ("user-defined" means that it's not one of the [predefined resource types](https://learn.microsoft.com/en-us/windows/win32/menurc/resource-definition-statements#resources)):

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
 ^~
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

For whatever reason, `rc.exe` will just take the last number literal in the expression and try to read from a file with that name, e.g. `(1+2)` will try to read from the path `2`, and `1+-1` will try to read from the path `-1` (the `-` sign is part of the number literal token, this will be detailed later in ["*Unary operators are an illusion*"](#unary-operators-are-an-illusion)).

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

Strangely, `rc.exe` will treat `FOO` as both the type of the resource *and* as a filename (similar to what we saw earlier in ["*`BEGIN` or `{` as filename*"](#begin-or-as-filename)). If you create a file with the name `FOO` it will then *successfully compile*, and the `.res` will have a resource with type `FOO` and its data will be that of the file `FOO`.

#### `resinator`'s behavior

`resinator` does not match the `rc.exe` behavior and instead always errors on this type of incomplete resource definition at the end of a file:

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

Then `rc.exe` *will always successfully compile it*, and it won't try to read from the file `FOO`. That is, a single dangling literal at the end of a file is fully allowed, and it is just treated as if it doesn't exist (there's no corresponding resource in the resulting `.res` file).

<p><aside class="note">

Note: There are a few particular dangling literals that do cause an error: `LANGUAGE`, `VERSION`, `CHARACTERISTICS`, and `STRINGTABLE`. This is because those keywords can be the beginning of a top-level declaration (e.g. valid usage of `CHARACTERISTICS` is `CHARACTERISTICS <number>`, so `CHARACTERISTICS` with no number afterwards triggers `error RC2140 : CHARACTERISTICS not a number`)

</aside></p>

It also turns out that there are three `.rc` files in [Windows-classic-samples](https://github.com/microsoft/Windows-classic-samples) that (accidentally, presumably) rely on this behavior ([1](https://github.com/microsoft/Windows-classic-samples/blob/a47da3d4551b74bb8cc1f4c7447445ac594afb44/Samples/CredentialProvider/cpp/resources.rc), [2](https://github.com/microsoft/Windows-classic-samples/blob/a47da3d4551b74bb8cc1f4c7447445ac594afb44/Samples/Win7Samples/security/credentialproviders/sampleallcontrolscredentialprovider/resources.rc), [3](https://github.com/microsoft/Windows-classic-samples/blob/a47da3d4551b74bb8cc1f4c7447445ac594afb44/Samples/Win7Samples/security/credentialproviders/samplewrapexistingcredentialprovider/resources.rc)), so in order to fully pass [win32-samples-rc-tests](https://github.com/squeek502/win32-samples-rc-tests/), it is necessary to allow a dangling literal at the end of a file.

#### `resinator`'s behavior

`resinator` allows a single dangling literal at the end of a file, but emits a warning:

```resinatorerror
test.rc:5:1: warning: dangling literal at end-of-file; this is not a problem, but it is likely a mistake
FOO
^~~
```

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
      <td><b>MENU</b> <i>menuname</i></td>
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

However, this is not what actually occurs, as for some reason, the `MENU` statement has different rules around inferring the type of the `id`. For the `MENU` statement, whenever the first character is a number, then the whole `id` is interpreted as a number no matter what.

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

This `CreateDialogParamW` call will fail with `The specified resource name cannot be found in the image file` because, when loading the dialog, it will attempt to look for a menu resource with an integer ID of `2899`.

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

The `id` of the `MENUEX` resource would be compiled as `ABC`, but the `DIALOGEX` would write the `id` of its menu as `abc`. This ends up not mattering, though, because it appears that `LoadMenu` uses a case-insensitive lookup.

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

### L is not allowed there

Like in C, an integer literal can be suffixed with `L` to signify that it is a 'long' integer literal. In the case of the Windows RC compiler, integer literals are typically 16 bits wide, and suffixing an integer literal with `L` will instead make it 32 bits wide.

<div class="short-rc-and-result">
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

<pre class="hexdump" style="display: flex; flex-direction: column; justify-content: center; align-items: center; flex-grow: 1; margin-top: 0;">
  <code class="language-c">1<span class="token_ansi_c_whitespace token_whitespace"> </span><span class="token_identifier">RCDATA</span><span class="token_ansi_c_whitespace token_whitespace"> </span><span class="token_punctuation">{</span><span class="token_ansi_c_whitespace token_whitespace"> </span><span style="padding: 0 3px;" class="o1d o-clr1">1</span><span class="token_punctuation">,</span><span class="token_ansi_c_whitespace token_whitespace"> </span><span style="padding: 0 3px;" class="o1d o-clr2">2L</span><span class="token_ansi_c_whitespace token_whitespace"> </span><span class="token_punctuation">}</span><span class="token_ansi_c_whitespace token_whitespace">
</span></code>
</pre>

</div>
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

<pre class="hexdump" style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0;">
  <code class="language-none"><span class="o1d o-clr1">01 00</span> <span class="o1d o-clr2">02 00 00 00</span></code>
</pre>

</div>
</div>
<p style="margin:0; text-align: center;"><i class="caption">An <code>RCDATA</code> resource definition and a hexdump of the resulting data in the <code>.res</code> file</i></p>

However, outside of raw data blocks like the `RCDATA` example above, the `L` suffix is typically meaningless, as it has no bearing on the size of the integer used. For example, `DIALOG` resources have `x`, `y`, `width`, and `height` parameters, and they are each encoded in the data as a `u16` regardless of the integer literal used. If the value would overflow a `u16`, then the value is truncated back down to a `u16`, meaning in the following example all 4 parameters after `DIALOG` get compiled down to `1` as a `u16`:

```rc
1 DIALOG 1, 1L, 65537, 65537L {}
```
<p style="margin:0; text-align: center;"><i class="caption">The maximum value of a <code>u16</code> is 65535</i></p>

A few particular parameters, though, fully disallow integer literals with the `L` suffix from being used:

- Any of the four parameters of the `FILEVERSION` statement of a `VERSIONINFO` resource
- Any of the four parameters of the `PRODUCTVERSION` statement of a `VERSIONINFO` resource
- Any of the two parameters of a `LANGUAGE` statement

<div class="short-rc-and-result">
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```rc style="display: flex; flex-direction: column; justify-content: center; flex-grow: 1; margin-top: 0;"
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

```rc style="display: flex; flex-direction: column; justify-content: center; flex-grow: 1; margin-top: 0;"
1 VERSIONINFO
  FILEVERSION 1L, 2, 3, 4
BEGIN
  // ...
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
<span class="bug-quirk-category">parser bug/quirk</span>

### Unary operators are an illusion

Typically, unary `+`, `-`, etc. operators are just that&mdash;operators; they are separate tokens that act on other tokens (number literals, variables, etc). However, in the Windows RC compiler, they are not real operators.

#### Unary `-`

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

#### Unary `~`

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

#### Unary `+`

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
<span class="bug-quirk-category">miscompilation</span>

### Your fate will be determined by a comma

Version information is specified using key/value pairs within `VERSIONINFO` resources. In the compiled `.res` file, the value data should always start at a 4-byte boundary, so after the key data is written, a variable number of padding bytes are written to get back to 4-byte alignment:

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
<span class="bug-quirk-category">miscompilation</span>

### Mismatch in length units in `VERSIONINFO` nodes

A `VALUE` within a `VERSIONINFO` resource is specified using this syntax:

```rc
VALUE <name>, <value(s)>
```

The `value(s)` can be specified as either number literals or quoted string literals, like so:

```rc
1 VERSIONINFO {
  VALUE "numbers", 123, 456
  VALUE "strings", "foo", "bar"
}
```

Each `VALUE` is compiled into a structure that contains the length of its value data, but the unit used for the length varies:

- For strings, the string data is written as UTF-16, and the length is given in UTF-16 code units (2 bytes per code unit)
- For numbers, the numbers are written either as `u16` or `u32` (depending on the presence of an `L` suffix), and the length is given in bytes

So, for the above example, the `"numbers"` value would be compiled into a node with:

- "Binary" data, meaning the length is given in bytes
- A length of `4`, since each number literal is compiled as a `u16`
- Data bytes of <code class="hexdump"><span class="o1d o-clr3">7B 00</span></code> <code class="hexdump"><span class="o1d o-clr4">C8 01</span></code>, where <code class="hexdump"><span class="o1d o-clr3">7B 00</span></code> is `123` and <code class="hexdump"><span class="o1d o-clr4">C8 01</span></code> is `456` (as little-endian `u16`)

and the `"strings"` value would be compiled into a node with:

- "String" data, meaning the length is given in UTF-16 code units
- A length of `8`, since each string is 3 UTF-16 code units plus a `NUL`-terminator
- Data bytes of <code class="hexdump"><span class="o1d o-clr1">66 00 6F 00 6F 00 00 00</span> <span class="o1d o-clr2">62 00 61 00 72 00 00 00</span></code>, where <code class="hexdump"><span class="o1d o-clr1">66 00 6F 00 6F 00 00 00</span></code> is `"foo"` and <code class="hexdump"><span class="o1d o-clr2">62 00 61 00 72 00 00 00</span></code> is `"bar"` (both as `NUL`-terminated little-endian UTF-16)

This is a bit bizarre, but when separated out like this it works fine. The problem is that there is nothing stopping you from mixing strings and numbers in one value, in which case the Windows RC compiler freaks out and writes the type as "binary" (meaning the length should be interpreted as a byte count), but the length as a mixture of byte count and UTF-16 code unit count. For example, with this resource:

```rc
1 VERSIONINFO {
  VALUE "something", "foo", 123
}
```

Its value's data will get compiled into these bytes: <code class="hexdump"><span class="o1d o-clr1">66 00 6F 00 6F 00 00 00</span> <span class="o1d o-clr3">7B 00</span></code>, where <code class="hexdump"><span class="o1d o-clr1">66 00 6F 00 6F 00 00 00</span></code> is `"foo"` (as `NUL`-terminated little-endian UTF-16) and <code class="hexdump"><span class="o1d o-clr3">7B 00</span></code> is `123` (as a little-endian `u16`). This makes for a total of 10 bytes (8 for `"foo"`, 2 for `123`), but the Windows RC compiler erroneously reports the value's data length as 6 (4 for `"foo"` [counted as UTF-16 code units], and 2 for `123` [counted as bytes]).

This miscompilation has similar results as those detailed in ["*Your fate will be determined by a comma*"](#your-fate-will-be-determined-by-a-comma):
- The full data of the value will not be read by a parser
- Due to the tree structure of `VERSIONINFO` resource data, this has knock-on effects on all following nodes, meaning the entire resource will be mangled

<p><aside class="note">

Note: There is a [The Old New Thing post](https://devblogs.microsoft.com/oldnewthing/20061222-00/?p=28623) that mentions this bug/quirk, check it out if you want some additional details

</aside></p>

#### The return of the meaningful comma

Before, I said that string values were compiled as `NUL`-terminated UTF-16 strings, but this is only the case when either:
- It is the last data element of a `VALUE`, or
- There is a comma separating it from the element after it

So, this:

```rc
1 VERSIONINFO {
  VALUE "strings", "foo", "bar"
}
```

will be compiled with a `NUL` terminator after both `foo` and `bar`, but this:

```rc
1 VERSIONINFO {
  VALUE "strings", "foo" "bar"
}
```

will be compiled only with a `NUL` terminator after `bar`. This is also similar to ["*Your fate will be determined by a comma*"](#your-fate-will-be-determined-by-a-comma), but unlike that comma quirk, I don't consider this one a miscompilation because the result is not invalid/mangled, and there is a possible use-case for this behavior (concatenating two or more string literals together). However, this behavior is not mentioned in the documentation, so it's unclear if it's actually intended.

#### `resinator`'s behavior

`resinator` avoids the length-related miscompilation and emits a warning:

```resinatorerror
test.rc:2:22: warning: the byte count of this value would be miscompiled by the Win32 RC compiler
  VALUE "something", "foo", 123
                     ^~~~~~~~~~
test.rc:2:22: note: to avoid the potential miscompilation, do not mix numbers and strings within a value
```

but matches the "meaningful comma" behavior of the Windows RC compiler.

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

`WS_VISIBLE` and `BS_VCENTER` are just numbers under-the-hood. For simplicity's sake, let's pretend their values are `0x1` for `WS_VISIBLE` and `0x2` for `BS_VCENTER` and then focus on this simplified `NOT` expression:

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
<span class="bug-quirk-category">miscompilation, crash</span>

### No one has thought about `FONT` resources for decades

As far as I can tell, the `FONT` resource has exactly one purpose: creating `.fon` files, which are resource-only `.dll`s (i.e. a `.dll` with resources, but no entry point) renamed to have a `.fon` extension. Such `.fon` files contain a collection of fonts in the obsolete `.fnt` font format.

The `.fon` format is mostly obsolete, but is still supported in modern Windows, and Windows *still* ships with some `.fon` files included:

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
<span class="bug-quirk-category">fundamental concept</span>

### The involvement of a C/C++ preprocessor

In the intro, I said:

> `.rc` files are scripts that contain both **C/C++ preprocessor commands** and resource definitions.

So far, I've only focused on resource definitions, but the involvement of the C/C++ preprocessor cannot be ignored. From the [About Resource Files](https://learn.microsoft.com/en-us/windows/win32/menurc/about-resource-files) documentation:

> The syntax and semantics for the RC preprocessor are similar to those of the Microsoft C/C++ compiler. However, RC supports a subset of the preprocessor directives, defines, and pragmas in a script.

The primary use-case for this is two-fold:

- Inclusion of C/C++ headers within a `.rc` file to pull in constants, e.g. `#include <windows.h>` to allow usage of [window style constants](https://learn.microsoft.com/en-us/windows/win32/winmsg/window-styles) like `WS_VISIBLE`, `WS_BORDER`, etc.
- Being able to share a `.h` file between your `.rc` file and your C/C++ source files, where the `.h` file contains things like the IDs of various resources.

Here's some snippets that demonstrate both use-cases:

```c
// in resource.h
#define DIALOG_ID 123
#define BUTTON_ID 234
```
```rc
// in resource.rc
#include <windows.h>
#include "resource.h"

// DIALOG_ID comes from resource.h
DIALOG_ID DIALOGEX 0, 0, 282, 239
  // These style constants come from windows.h
  STYLE DS_SETFONT | DS_MODALFRAME | DS_CENTER | WS_POPUP | WS_CAPTION | WS_SYSMENU
  CAPTION "Dialog"
{
  // BUTTON_ID comes from resource.h
  PUSHBUTTON "Button", BUTTON_ID, 129, 182, 50, 14
}
```
```c
// in main.c
#include <windows.h>
#include "resource.h"

// ...
  // DIALOG_ID comes from resource.h
  HWND result = CreateDialogParamW(hInst, MAKEINTRESOURCEW(DIALOG_ID), hwnd, DialogProc, (LPARAM)NULL);
// ...

// ...
  // BUTTON_ID comes from resource.h
  HWND button = GetDlgItem(hwnd, BUTTON_ID);
// ...
```

With this setup, changing `DIALOG_ID`/`BUTTON_ID` in `resource.h` affects both `resource.rc` and `main.c`, so they are always kept in sync.

<p><aside class="note">

Note: Knowing all of the particularities of the resource-compiler-flavored-preprocessor isn't important for now. If you're curious, see the docs for [Predefined Macros](https://learn.microsoft.com/en-us/windows/win32/menurc/predefined-macros), [Preprocessor Directives](https://learn.microsoft.com/en-us/windows/win32/menurc/preprocessor-directives), [Preprocessor Operators](https://learn.microsoft.com/en-us/windows/win32/menurc/preprocessor-operators), and [Pragma Directives](https://learn.microsoft.com/en-us/windows/win32/menurc/pragma-directives) for the documented capabilties of the Windows RC compiler's preprocessor.

</aside></p>

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">preprocessor bug/quirk, parser bug/quirk</span>

### Multiline strings don't behave as expected/documented

Within the [`STRINGTABLE` resource documentation](https://learn.microsoft.com/en-us/windows/win32/menurc/stringtable-resource) we see this statement:

> The string [...] must occupy a single line in the source file (unless a '&bsol;' is used as a line continuation).

<p><aside class="note">

Note: While this documentation is for `STRINGTABLE`, I believe it actually applies to string literals in `.rc` files generally. In other words, the bugs/quirks described below apply to all resource types.

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

So the value of `my_string` would be `Line 1 Line 2` (well, not really, since `char *my_string = ` doesn't have a meaning in `.rc` files, but you get the idea). This divergence in behavior from C has practical consequences: in [this `.rc` file](https://github.com/microsoft/Windows-classic-samples/blob/main/Samples/Win7Samples/winui/shell/appshellintegration/NonDefaultDropMenuVerb/NonDefaultDropMenuVerb.rc) from one of the [Windows-classic-samples](https://github.com/microsoft/Windows-classic-samples) example programs, we see the following, which takes advantage of the `rc.exe`-preprocessor-specific-whitespace-collapsing behavior:

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
<span class="bug-quirk-category">parser bug/quirk, utterly baffling</span>

### Escaping quotes is fraught

Again from the [`STRINGTABLE` resource docs](https://learn.microsoft.com/en-us/windows/win32/menurc/stringtable-resource):

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
<span class="bug-quirk-category">fundamental concept</span>

### The Windows RC compiler 'speaks' UTF-16

As mentioned before, `.rc` files are compiled in two distinct steps:

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

So, if we run the Windows-1252-encoded file through only the `rc.exe` preprocessor (using the [undocumented `rc.exe /p` option](#p-okay-i-ll-only-preprocess-but-you-re-not-going-to-like-it)), the result is a file with the following contents:

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
<span class="bug-quirk-category">preprocessor bug/quirk</span>

### Extreme `#pragma code_page` values

As seen above, the resource-compiler-specific preprocessor directive `#pragma code_page` can be used to alter the current [code page](https://en.wikipedia.org/wiki/Code_page) mid-file. It's used like so:

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

I don't have an explanation for this behavior, especially with regards to why only certian extreme values induce an error at all.

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
<span class="bug-quirk-category">preprocessor/parser bug/quirk</span>

### Escaping in wide string literals

In regular string literals, invalid escape sequences get compiled into their literal characters. For example:

<pre><code class="language-rc"><span class="token_identifier">1</span> <span class="token_keyword">RCDATA</span> <span class="token_punctuation">{</span>
   <span class="token_string">"abc\k"</span>  <span class="token_function">────►</span>  <span class="token_function token_unrepresentable" title="Compiled data">abc\k</span>
<span class="token_punctuation">}</span></code></pre>

However, for reasons unknown, invalid escape characters within wide string literals disappear from the compiled result entirely:

<pre><code class="language-rc"><span class="token_identifier">1</span> <span class="token_keyword">RCDATA</span> <span class="token_punctuation">{</span>
  L<span class="token_string">"abc\k"</span>  <span class="token_function">────►</span>  <span class="token_function token_unrepresentable" title="Compiled data (UTF-16)">a.b.c.</span>
<span class="token_punctuation">}</span></code></pre>

On its own, this is just an inexplicable quirk, but when combined with other quirks, it gets elevated to the level of a (potential) bug.

#### In combination with tab characters

As detailed in ["*The column of a tab character matters*"](#the-column-of-a-tab-character-matters), an embedded tab character gets converted to a variable number of spaces depending on which column it's at in the file. This happens during preprocesing, which means that by the time a string literal is parsed, the tab character will have been replaced with space character(s). This, in turn, means that "escaping" an embedded tab character will actually end up escaping a space character.

Here's an example where the tab character (denoted by <code><span class="token_unrepresentable" title="Horizontal Tab (\t)">────</span></code>) will get converted to 6 space characters:

<pre><code class="language-rc"><span class="token_identifier">1</span><span class="token_rc_whitespace token_whitespace"> </span><span class="token_keyword">RCDATA</span><span class="token_rc_whitespace token_whitespace"> </span><span class="token_punctuation">{</span>
L<span class="token_string">"\</span><span class="token_unrepresentable" title="Horizontal Tab (\t)">────</span><span class="token_string">"</span>
<span class="token_punctuation">}</span></code></pre>

And here's what that example looks like after preprocessing (note that the escape sequence now applies to a single space character).

<pre><code class="language-rc hexdump"><span class="token_identifier">1</span><span class="token_rc_whitespace token_whitespace"> </span><span class="token_keyword">RCDATA</span><span class="token_rc_whitespace token_whitespace"> </span><span class="token_punctuation">{</span>
L<span class="token_string">"</span><span class="o1d o-clr1"><span class="token_string">\</span><span class="token_unrepresentable" title="Space">·</span></span><span class="token_unrepresentable" title="Space">·</span><span class="token_unrepresentable" title="Space">·</span><span class="token_unrepresentable" title="Space">·</span><span class="token_unrepresentable" title="Space">·</span><span class="token_unrepresentable" title="Space">·</span><span class="token_string">"</span>
<span class="token_punctuation">}</span></code></pre>

With the quirk around invalid escape sequences in wide string literals, this means that the "escaped space" gets skipped over/ignored when parsing the string, meaning that the compiled data in this case will have 5 space characters instead of 6.

#### In combination with codepoints represented by a surrogate pair

As detailed in ["*The Windows RC compiler 'speaks' UTF-16*"](#the-windows-rc-compiler-speaks-utf-16), the output of the Windows RC preprocessor is always encoded as UTF-16. In UTF-16, codepoints >= `U+10000` are encoded as a surrogate pair (two `u16` code units). For example, the codepoint for 𐐷 (`U+10437`) is encoded in UTF-16 as <code><span class="token_unrepresentable" title="UTF-16 encoding of 𐐷 (U+10437)">&lt;0xD801&gt;&lt;0xDC37&gt;</span></code>.

So, let's say we have this `.rc` file:

```rc
#pragma code_page(65001)
1 RCDATA {
  L"\𐐷"
}
```

The file is encoded as UTF-8, meaning the 𐐷 is encoded as 4 bytes like so:

<pre><code class="language-rc"><span class="token_preprocessor">#pragma</span><span class="token_rc_whitespace token_whitespace"> </span><span class="token_identifier">code_page</span><span class="token_punctuation">(</span><span class="token_identifier">65001</span><span class="token_punctuation">)</span><span class="token_rc_whitespace token_whitespace">
</span><span class="token_identifier">1</span><span class="token_rc_whitespace token_whitespace"> </span><span class="token_keyword">RCDATA</span><span class="token_rc_whitespace token_whitespace"> </span><span class="token_punctuation">{</span><span class="token_rc_whitespace token_whitespace">
  </span><span class="token_identifier">L</span><span class="token_string">"\<span class="token_unrepresentable" title="UTF-8 encoding of 𐐷 (U+10437)">&lt;0xF0&gt;&lt;0x90&gt;&lt;0x90&gt;&lt;0xB7&gt;</span>"</span><span class="token_rc_whitespace token_whitespace">
</span><span class="token_punctuation">}</span><span class="token_rc_whitespace token_whitespace">
</span></code></pre>

When run through the Windows RC preprocessor, it parses the file successfully and outputs the correct UTF-16 encoding of the 𐐷 codepoint (remember that the Windows RC preprocessor always outputs UTF-16):

```rc
1 RCDATA {
L"\𐐷"
}
```

However, the Windows RC *parser* does not seem to be aware of surrogate pairs, and therefore treats the escape sequence as only pertaining to the first `u16` surrogate code unit (the "high surrogate"):

<pre><code class="language-rc hexdump"><span class="token_identifier">1</span><span class="token_rc_whitespace token_whitespace"> </span><span class="token_keyword">RCDATA</span><span class="token_rc_whitespace token_whitespace"> </span><span class="token_punctuation">{</span><span class="token_rc_whitespace token_whitespace">
</span><span class="token_identifier">L</span><span class="token_string">"</span><span class="o1d o-clr1"><span class="token_string">\</span><span class="token_unrepresentable" title="UTF-16 high surrogate encoding of 𐐷 (U+10437)">&lt;0xD801&gt;</span></span><span class="token_unrepresentable" title="UTF-16 low surrogate encoding of 𐐷 (U+10437)">&lt;0xDC37&gt;</span><span class="token_string">"</span><span class="token_rc_whitespace token_whitespace">
</span><span class="token_punctuation">}</span><span class="token_rc_whitespace token_whitespace">
</span></code></pre>

This means that the <code><span class="token_string">&bsol;</span><span class="token_unrepresentable" title="UTF-16 high surrogate encoding of 𐐷 (U+10437)">&lt;0xD801&gt;</span></code> is treated as an invalid escape sequence and skipped, and only <code><span class="token_unrepresentable" title="UTF-16 low surrogate encoding of 𐐷 (U+10437)">&lt;0xDC37&gt;</span></code> makes it into the compiled resource data. This will essentially always end up being invalid UTF-16, since an unpaired surrogate code unit is ill-formed (the only way it wouldn't end up as ill-formed is if an intentionally unpaired high surrogate code unit was included before the escape sequence, e.g. `L"\xD801\𐐷"`).

<p><aside class="note">

Note: This lack of surrogate-pair-awareness is actually quite common in Windows, since much of Windows' Unicode support predates UTF-16. Here's [one resource that provides some context](http://simonsapin.github.io/wtf-8/#motivation).

</aside></p>

#### `resinator`'s behavior

`resinator` currently attempts to match the Windows RC compiler's behavior exactly, and [emulates the interaction between the preprocessor and wide string escape sequences in its string parser](https://github.com/squeek502/resinator/blob/9a6e50b0c0859e0dee5fd1871d93329e0e1194ef/src/literals.zig#L298-L356).

The reasoning for emulating the Windows RC compiler for escaped tabs/escaped surrogate pairs seems rather dubious, though, so this may change in the future.

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">miscompilation</span>

### `STRINGTABLE` semantics bypass

The [`STRINGTABLE` resource](https://learn.microsoft.com/en-us/windows/win32/menurc/stringtable-resource) is intended for embedding string data, which can then be loaded at runtime with [`LoadString`](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-loadstringw). A `STRINGTABLE` resource definition looks something like this:

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

The `"Hello"` and `"Goodbye"` strings will be grouped together into one resource, and the `"Hm"` will be put into another. Each group is written as a series of 16 length integers (one for each string within the group), and each length is immediately followed by a UTF-16 encoded string of that length (if the length is non-zero). So, for example, the first group contains the strings with IDs 0-15, meaning, for the `.rc` file above, the first group would be compiled as:

<pre class="hexdump"><code><span class="o1d o-clr3 infotip" title="Length of string ID 0">05 00</span> <span class="bg-clr3 o1s o-clr3">48 00 65 00 6C 00</span>  <span class="o1d o-clr3">..</span><span class="bg-clr3 o1s o-clr3">H.e.l.</span>
<span class="bg-clr3 o1s o-clr3">6C 00 6F 00</span> <span class="o1d o-clr4 infotip" title="Length of string ID 1">07 00</span> <span class="bg-clr4 o1s o-clr4">47 00</span>  <span class="bg-clr3 o1s o-clr3">l.o.</span><span class="o1d o-clr4">..</span><span class="bg-clr4 o1s o-clr4">G.</span>
<span class="bg-clr4 o1s o-clr4">6F 00 6F 00 64 00 62 00</span>  <span class="bg-clr4 o1s o-clr4">o.o.d.b.</span>
<span class="bg-clr4 o1s o-clr4">79 00 65 00</span> <span style="opacity:0.5"><span class="o1d o-clr5 infotip" title="Length of string ID 2">00 00</span> <span class="o1d o-clr1 infotip" title="Length of string ID 3">00 00</span></span>  <span class="bg-clr4 o1s o-clr4">y.e.</span><span style="opacity:0.5"><span class="o1d o-clr5">..</span><span class="o1d o-clr1">..</span>
<span class="o1d o-clr2 infotip" title="Length of string ID 4">00 00</span> <span class="o1d o-clr3 infotip" title="Length of string ID 5">00 00</span> <span class="o1d o-clr4 infotip" title="Length of string ID 6">00 00</span> <span class="o1d o-clr5 infotip" title="Length of string ID 7">00 00</span>  <span class="o1d o-clr2">..</span><span class="o1d o-clr3">..</span><span class="o1d o-clr4">..</span><span class="o1d o-clr5">..</span>
<span class="o1d o-clr1 infotip" title="Length of string ID 8">00 00</span> <span class="o1d o-clr2 infotip" title="Length of string ID 9">00 00</span> <span class="o1d o-clr3 infotip" title="Length of string ID 10">00 00</span> <span class="o1d o-clr4 infotip" title="Length of string ID 11">00 00</span>  <span class="o1d o-clr1">..</span><span class="o1d o-clr2">..</span><span class="o1d o-clr3">..</span><span class="o1d o-clr4">..</span>
<span class="o1d o-clr5 infotip" title="Length of string ID 12">00 00</span> <span class="o1d o-clr1 infotip" title="Length of string ID 13">00 00</span> <span class="o1d o-clr2 infotip" title="Length of string ID 14">00 00</span> <span class="o1d o-clr3 infotip" title="Length of string ID 15">00 00</span>  <span class="o1d o-clr5">..</span><span class="o1d o-clr1">..</span><span class="o1d o-clr2">..</span><span class="o1d o-clr3">..</span></span>
</code></pre>

Internally, `STRINGTABLE` resources get compiled as the integer resource type `RT_STRING`, which is 6. The ID of the resource is based on the grouping, so strings with IDs 0-15 go into a `RT_STRING` resource with ID 1, 16-31 go into a resource with ID 2, etc.

The above is all well and good, but what happens if you *manually* define a resource with the `RT_STRING` type of 6? The Windows RC compiler has no qualms with that at all, and compiles it similarly to a user-defined resource, so the data of the resource below will be 3 bytes long, containing `foo`:

```rc
1 6 {
  "foo"
}
```

In the compiled resource, though, the resource type and ID are indistinguishable from a properly defined `STRINGTABLE`. This means that compiling the above resource and then trying to use `LoadString` will *succeed*, even though the resource's data does not conform at all to the intended structure of a `RT_STRING` resource:

```c
UINT string_id = 0;
WCHAR buf[1024];
int len = LoadStringW(NULL, string_id, buf, 1024);
if (len != 0) {
    printf("len: %d\n", len);
    wprintf(L"%s\n", buf);
}
```

That code will output:

```
len: 1023
o
```

Let's think about what's going on here. We compiled a resource with three bytes of data: `foo`. We have no real control over what follows that data in the compiled binary, so we can think about how this resource is interpreted by `LoadString` like this:

<pre class="hexdump"><code><span class="o1d o-clr3 infotip" title="Length of string ID 0">66 6F</span> <span class="bg-clr3 o1s o-clr3">6F ?? ?? ?? ?? ??</span>  <span class="o1d o-clr3">fo</span><span class="bg-clr3 o1s o-clr3">o?????</span>
<span class="bg-clr3 o1s o-clr3">?? ?? ?? ?? ?? ?? ?? ??</span>  <span class="bg-clr3 o1s o-clr3">????????</span>
<span style="opacity:0.5"><span class="bg-clr3 o1s o-clr3">          ...          </span>  <span class="bg-clr3 o1s o-clr3">   ...  </span></span></code></pre>

The first two bytes, `66 6F`, are treated as a little-endian `u16` containing the length of the string that follows it. `66 6F` as a little-endian `u16` is 28518, so `LoadString` thinks that the string with ID `0` is 28 thousand UTF-16 code units long. All of the `??` bytes are those that happen to follow the resource data&mdash;they could in theory be anything. So, `LoadString` will erroneously attempt to read this gargantuan string into `buf`, but since we only provided a buffer of 1024, it only fills up to that size and stops.

In the actual compiled binary of my test program, the bytes following `foo` happen to look like this:

<pre class="hexdump"><code><span class="o1d o-clr3 infotip" title="Length of string ID 0">66 6F</span> <span class="bg-clr3 o1s o-clr3">6F 00 00 00 00 00</span>  <span class="o1d o-clr3">fo</span><span class="bg-clr3 o1s o-clr3">o.....</span>
<span class="bg-clr3 o1s o-clr3">3C 3F 78 6D 6C 20 76 65</span>  <span class="bg-clr3 o1s o-clr3">&lt;?xml ve</span>
<span style="opacity:0.5"><span class="bg-clr3 o1s o-clr3">          ...          </span>  <span class="bg-clr3 o1s o-clr3">   ...  </span></span></code></pre>

This means that the last `o` in `foo` happens to be followed by `00`, and `6F 00` is interpreted as a UTF-16 `o` character, and that happens to be followed by `00 00` which is treated as a `NUL` terminator by `wprintf`. This explains the `o` we got earlier from `wprintf(L"%s\n", buf);`. However, if we print the full 1023 `wchar`'s of the buf like so:

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

Note: My first impression is that this crash is a bug in `LoadString`, in that it probably should be doing some bounds checking to avoid attempting to read past the end of the resource data. However, resources get compiled into a different (tree) structure when linked into a PE/COFF binary, and that format is not something I'm familiar with ([yet](https://github.com/squeek502/resinator/issues/7)), so there may be something I'm missing about why bounds checking is seemingly not occuring.

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
- This bug/quirk is specific to the `style` parameter of `CONTROL` statements. In non-generic controls, the `style` parameter is optional and comes after the `h` parameter, but it does not exhibit this behavior

</aside></p>

The extra token can be many things (string, number, `=`, etc), but not *anything*. For example, if the extra token is `;`, then it will error with `expected numerical dialog constant`.

#### `CONTROL`: "Okay, I see that expression, but I don't understand it"

Instead of a single extra token in the `style` parameter of a `CONTROL`, it's also possible to sneak an extra number expression in there like so:

<pre style="margin-top: 3em; overflow: visible; white-space: pre-wrap;"><code class="language-c" style="white-space: inherit;"><span style="opacity:50%;">CONTROL, "text", 1, BUTTON,</span> <span style="outline:2px dotted blue; position:relative; display:inline-block;"><span class="token_identifier">BS_CHECKBOX</span> <span class="token_operator">|</span> <span class="token_identifier">WS_TABSTOP</span> <span class="token_punctuation">(</span>7<span class="token_operator">+</span>8<span class="token_punctuation">)</span><span class="hexdump-tooltip rcdata">style<i></i></span></span><span style="opacity: 50%;">, 2, 3, 4, 5</span></code></pre>

In this case, the Windows RC compiler no longer ignores the expression, but still behaves strangely. Instead of the entire `(7+8)` expression being treated as the `x` parameter like one might expect, in this case *only the* `8` in the expression is treated as the `x` parameter, so it ends up interpreted like this:

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
<span class="bug-quirk-category">miscompilation</span>

### That's odd, I thought you needed more padding

In `DIALOGEX` resources, a control statement is documented to have the following syntax:

> ```
> control [[text,]] id, x, y, width, height[[, style[[, extended-style]]]][, helpId]
> [{ data-element-1 [, data-element-2 [,  . . . ]]}]
> ```

For now, we can ignore everything except the `[{ data-element-1 [, data-element-2 [,  . . . ]]}]` part, which is documented like so:

> *controlData*
>
> Control-specific data for the control. When a dialog is created, and a control in that dialog which has control-specific data is created, a pointer to that data is passed into the control's window procedure through the lParam of the WM_CREATE message for that control.

Here's an example, where the string `"foo"` is the control data:

<pre><code class="language-rc"><span style="opacity: 50%;">1 DIALOGEX 0, 0, 282, 239 {</span>
  PUSHBUTTON <span style="opacity: 50%;">"Cancel",1,129,212,50,14</span> <span class="token_punctuation">{</span> <span class="token_string">"foo"</span> <span class="token_punctuation">}</span>
<span style="opacity: 50%;">}</span></code>
</pre>

After a very long time of having no idea how to retrieve this data from a Win32 program, I finally figured it out while writing this article. As far as I know, the `WM_CREATE` event can only be received for custom controls or by [superclassing](https://learn.microsoft.com/en-us/windows/win32/winmsg/about-window-procedures#winproc_superclassing) a predefined control.

<p><aside class="note">

Note: I'm going to gloss over exactly what that means. See [here](https://github.com/squeek502/win32-resource-tests/tree/master/dialog) for details and a complete example.

</aside></p>

So, let's say in our program we register a class named `CustomControl`. We can then use it in a `DIALOGEX` resource like this:

<pre><code class="language-rc"><span style="opacity: 50%;">1 DIALOGEX 0, 0, 282, 239 {</span>
  <span class="token_keyword">CONTROL</span> <span style="opacity: 50%;">"text", 901,</span> <span class="token_string">"CustomControl"</span><span style="opacity: 50%;">, 0, 129,212,50,14</span> <span class="token_punctuation">{</span> <span class="token_string">"foo"</span> <span class="token_punctuation">}</span>
<span style="opacity: 50%;">}</span></code>
</pre>

The control data (`"foo"`) will get compiled as <code class="hexdump"><span class="o1d o-clr3">03 00</span></code> <code class="hexdump"><span class="o1d o-clr4">66 6F 6F</span></code>, where <code class="hexdump"><span class="o1d o-clr3">03 00</span></code> is the length of the control data in bytes (3 as a little-endian `u16`) and <code class="hexdump"><span class="o1d o-clr4">66 6F 6F</span></code> are the bytes of `foo`.

If we load this dialog, then our custom control's `WNDPROC` callback will receive a `WM_CREATE` event where the `LPARAM` parameter is a pointer to a `CREATESTRUCT` and `((CREATESTRUCT*)lParam)->lpCreateParams` will be a pointer to the control data (if any exists). So, in our case, the `lpCreateParams` pointer points to memory that looks the same as the bytes shown above: a `u16` length first, and the specified number of bytes following it. If we handle the event like this:

```c
// ...
    case WM_CREATE:
      if (lParam) {
        CREATESTRUCT* create_params = (CREATESTRUCT*)lParam;
        const BYTE* data = create_params->lpCreateParams;
        if (data) {
          WORD len = *((WORD*)data);
          printf("control data len: %d\n", len);
          for (WORD i = 0; i < len; i++) {
              printf("%02X ", data[2 + i]);
          }
          printf("\n");
        }
      }
      break;
// ...
```

then we get this output (with some additional printing of the callback parameters):

```
CustomProc hwnd: 00000000022C0A8A msg: WM_CREATE wParam: 0000000000000000 lParam: 000000D7624FE730
control data len: 3
66 6F 6F
```

Nice! Now let's try to add a second `CONTROL`:

<pre><code class="language-rc"><span style="opacity: 50%;">1 DIALOGEX 0, 0, 282, 239 {</span>
  <span class="token_keyword">CONTROL</span> <span style="opacity: 50%;">"text", 901,</span> <span class="token_string">"CustomControl"</span><span style="opacity: 50%;">, 0, 129,212,50,14</span> <span class="token_punctuation">{</span> <span class="token_string">"foo"</span> <span class="token_punctuation">}</span>
  <span class="token_keyword">CONTROL</span> <span style="opacity: 50%;">"text", 902,</span> <span class="token_string">"CustomControl"</span><span style="opacity: 50%;">, 0, 189,212,50,14</span> <span class="token_punctuation">{</span> <span class="token_string">"bar"</span> <span class="token_punctuation">}</span>
<span style="opacity: 50%;">}</span></code>
</pre>

With this, the `CreateDialogParamW` call starts failing with:

```
Cannot find window class.
```

Why would that be? Well, it turns out that the Windows RC compiler miscompiles the padding bytes following a control if its control data has an odd number of bytes. This is similar to what's described in ["*Your fate will be determined by a comma*"](#your-fate-will-be-determined-by-a-comma), but in the opposite direction: instead of adding too few padding bytes, the Windows RC compiler in this case will add *too many*.

Each control within a dialog resource is expected to be 4-byte aligned (meaning its memory starts at an offset that is a multiple of 4). So, if the bytes at the end of one control looks like this, where the dotted boxes represent 4-byte boundaries:

<pre class="hexdump" style="display: flex; flex-direction: column; justify-content: center; align-items: center; flex-grow: 1; margin-top: 0;">
  <code class="language-none"><span class="o1o o-clr2" style="display: inline-block; line-height: 2rem;"><span style="background: rgba(255,0,0,.1);">....</span></span><span class="o1o o-clr2" style="display: inline-block; line-height: 2rem;"><span style="background: rgba(255,0,0,.1);">....</span></span><span class="o1o o-clr2" style="display: inline-block; line-height: 2rem;"><span style="background: rgba(255,0,0,.1);">foo</span>&nbsp;</span><span class="o1o o-clr2" style="display: inline-block; line-height: 2rem;">&nbsp;&nbsp;&nbsp;&nbsp;</span><span class="o1o o-clr2" style="display: inline-block; line-height: 2rem;">&nbsp;&nbsp;&nbsp;&nbsp;</span></code>
</pre>

then we only need one byte of padding after `foo` to ensure the next control is 4-byte aligned:

<pre class="hexdump" style="display: flex; flex-direction: column; justify-content: center; align-items: center; flex-grow: 1; margin-top: 0;">
  <code class="language-none"><span class="o1o o-clr2" style="display: inline-block; line-height: 2rem;"><span style="background: rgba(255,0,0,.1);">....</span></span><span class="o1o o-clr2" style="display: inline-block; line-height: 2rem;"><span style="background: rgba(255,0,0,.1);">....</span></span><span class="o1o o-clr2" style="display: inline-block; line-height: 2rem;"><span style="background: rgba(255,0,0,.1);">foo</span><span style="background: rgba(0,0,255,.33);">.</span></span><span class="o1o o-clr2" style="display: inline-block; line-height: 2rem;"><span style="background: rgba(0,255,0,.1);">....</span></span><span class="o1o o-clr2" style="display: inline-block; line-height: 2rem;"><span style="background: rgba(0,255,0,.1);">....</span></span></code>
</pre>

However, the Windows RC compiler erroneously inserts two additional padding bytes in this case, meaning the control afterwards is misaligned by two bytes:

<pre class="hexdump" style="display: flex; flex-direction: column; justify-content: center; align-items: center; flex-grow: 1; margin-top: 0;">
  <code class="language-none"><span class="o1o o-clr2" style="display: inline-block; line-height: 2rem;"><span style="background: rgba(255,0,0,.1);">....</span></span><span class="o1o o-clr2" style="display: inline-block; line-height: 2rem;"><span style="background: rgba(255,0,0,.1);">....</span></span><span class="o1o o-clr2" style="display: inline-block; line-height: 2rem;"><span style="background: rgba(255,0,0,.1);">foo</span><span style="background: rgba(0,0,255,.33);">.</span></span><span class="o1o o-clr2" style="display: inline-block; line-height: 2rem;"><span style="background: rgba(0,0,255,.33);">..</span><span style="background: rgba(0,255,0,.1);">..</span></span><span class="o1o o-clr2" style="display: inline-block; line-height: 2rem;"><span style="background: rgba(0,255,0,.1);">....</span></span></code>
</pre>

This causes every field of the misaligned control to be misread, leading to a malformed dialog that can't be loaded. As mentioned, this is only the case with odd control data byte counts; if we add or remove a byte from the control data, then this miscompilation does not happen and the correct amount of padding is written. Here's what it looks like if `"foo"` is changed to `"fo"`:

<pre class="hexdump" style="display: flex; flex-direction: column; justify-content: center; align-items: center; flex-grow: 1; margin-top: 0;">
  <code class="language-none"><span class="o1o o-clr2" style="display: inline-block; line-height: 2rem;"><span style="background: rgba(255,0,0,.1);">....</span></span><span class="o1o o-clr2" style="display: inline-block; line-height: 2rem;"><span style="background: rgba(255,0,0,.1);">....</span></span><span class="o1o o-clr2" style="display: inline-block; line-height: 2rem;"><span style="background: rgba(255,0,0,.1);">fo</span><span style="background: rgba(0,0,255,.33);">..</span></span><span class="o1o o-clr2" style="display: inline-block; line-height: 2rem;"><span style="background: rgba(0,255,0,.1);">....</span></span><span class="o1o o-clr2" style="display: inline-block; line-height: 2rem;"><span style="background: rgba(0,255,0,.1);">....</span></span></code>
</pre>

<p><aside class="note">

Note: This miscompilation only occurs for the padding between controls within a dialog. For the last control within a dialog, its control data can have an odd number of bytes with no ill-effects.

</aside></p>

This is a miscompilation that seems very easy to accidentally hit, but it has gone undetected/unfixed for so long presumably because this 'control data' syntax is *very* seldom used. For example, there's not a single usage of this feature anywhere within [Windows-classic-samples](https://github.com/microsoft/Windows-classic-samples).

#### `resinator`'s behavior

`resinator` will avoid the miscompilation and will emit a warning when it detects that the Windows RC compiler would miscompile:

```resinatorerror
test.rc:3:3: warning: the padding before this control would be miscompiled by the Win32 RC compiler (it would insert 2 extra bytes of padding)
  CONTROL "text", 902, "CustomControl", 1, 189,212,50,14,2,3 { "bar" }
  ^~~~~~~
test.rc:3:3: note: to avoid the potential miscompilation, consider adding one more byte to the control data of the control preceding this one
```

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">miscompilation, utterly baffling</span>

### `CONTROL` class specified as a number

A generic `CONTROL` within a `DIALOG`/`DIALOGEX` resource is specified like this:

<pre class="annotated-code"><code class="language-c" style="white-space: inherit;"><span class="annotation"><span class="desc">class<i></i></span><span class="subject"><span class="token_keyword">CONTROL</span></span></span><span class="token_punctuation">,</span> <span class="token_string">"foo"</span><span class="token_punctuation">,</span> 1<span class="token_punctuation">,</span> <span class="annotation"><span class="desc">class name<i></i></span><span class="subject"><span class="token_keyword">BUTTON</span></span></span><span class="token_punctuation">,</span> <span class="token_identifier">1</span><span class="token_punctuation">,</span> 2<span class="token_punctuation">,</span> 3<span class="token_punctuation">,</span> 4<span class="token_punctuation">,</span> 5</code></pre>

The `class name` can be a string literal (`"CustomControlClass"`) or one of `BUTTON`, `EDIT`, `STATIC`, `LISTBOX`, `SCROLLBAR`, or `COMBOBOX`. Internally, those unquoted literals are just predefined values that compile down to numeric integers:

```
BUTTON    ──► 0x80
EDIT      ──► 0x81
STATIC    ──► 0x82
LISTBOX   ──► 0x83
SCROLLBAR ──► 0x84
COMBOBOX  ──► 0x85
```

There's plenty of precedence within the Windows RC compiler that you can swap out a predefined type for its underlying integer and get the same result, and indeed the Windows RC compiler does not complain if you try to do so in this case:

<pre class="annotated-code"><code class="language-c" style="white-space: inherit;"><span class="token_keyword">CONTROL</span><span class="token_punctuation">,</span> <span class="token_string">"foo"</span><span class="token_punctuation">,</span> 1<span class="token_punctuation">,</span> <span class="annotation"><span class="desc">class name<i></i></span><span class="subject"><span class="token_identifier">0x80</span></span></span><span class="token_punctuation">,</span> <span class="token_identifier">1</span><span class="token_punctuation">,</span> 2<span class="token_punctuation">,</span> 3<span class="token_punctuation">,</span> 4<span class="token_punctuation">,</span> 5</code></pre>

Before we look at what happens, though, we need to understand how values that can be either a string or a number get compiled. For such values, if it is a string, it is always compiled as `NUL`-terminated UTF-16:

```
66 00 6F 00 6F 00 00 00  f.o.o...
```

If such a value is a number, then it's compiled as a pair of `u16` values: `0xFFFF` and then the actual number value following that, where the `0xFFFF` acts as a indicator that the ambiguous string/number value is a number. So, if the number is `0x80`, it would get compiled into:

```
FF FF 80 00  ....
```

The above (`FF FF 80 00`) is what `BUTTON` gets compiled into, since `BUTTON` gets translated to the integer `0x80` under-the-hood. However, getting back to this example:

<pre class="annotated-code"><code class="language-c" style="white-space: inherit;"><span class="token_keyword">CONTROL</span><span class="token_punctuation">,</span> <span class="token_string">"foo"</span><span class="token_punctuation">,</span> 1<span class="token_punctuation">,</span> <span class="annotation"><span class="desc">class name<i></i></span><span class="subject"><span class="token_identifier">0x80</span></span></span><span class="token_punctuation">,</span> <span class="token_identifier">1</span><span class="token_punctuation">,</span> 2<span class="token_punctuation">,</span> 3<span class="token_punctuation">,</span> 4<span class="token_punctuation">,</span> 5</code></pre>

We should expect the `0x80` also gets compiled into `FF FF 80 00`, but instead the Windows RC compiler compiles it into:

```
80 FF 00 00
```

As far as I can tell, the behavior here is to:

- Truncate the value to a `u8`
- If the truncated value is >= `0x80`, add `0xFF00` and write the result as a little-endian `u32`
- If the truncated value is < `0x80` but not zero, write the value as a little-endian `u32`
- If the truncated value is zero, write zero as a `u16`

Some examples:

```
 0x00 ──► 00 00
 0x01 ──► 01 00 00 00
 0x7F ──► 7F 00 00 00
 0x80 ──► 80 FF 00 00
 0xFF ──► FF FF 00 00
0x100 ──► 00 00
0x101 ──► 01 00 00 00
0x17F ──► 7F 00 00 00
0x180 ──► 80 FF 00 00
0x1FF ──► FF FF 00 00
      etc
```

I only have the faintest idea of what could be going on here. My guess is that this is some sort of half-baked leftover behavior from the 16-bit resource compiler that never got properly updated in the move to the 32-bit compiler, since in the 16-bit version of `rc.exe`, numbers were compiled as `FF <number as u8>` instead of `FF FF <number as u16>`. However, the results we see don't fully match what we'd expect if that were the case&mdash;instead of `FF 80`, we get `80 FF`, so I don't think this explanation holds up.

<p><aside class="note">

Note also that the `0x80` cutoff is also the cutoff for to the ASCII range, so that might also be relevant (but I don't think there's any legitimate reason for it to be).

</aside></p>

#### `resinator`'s behavior

`resinator` will avoid the miscompilation and will emit a warning:

```resinatorerror
test.rc:2:22: warning: the control class of this CONTROL would be miscompiled by the Win32 RC compiler
  CONTROL, "foo", 1, 0x80, 1, 2, 3, 4, 5
                     ^~~~
test.rc:2:22: note: to avoid the potential miscompilation, consider specifying the control class using a string (BUTTON, EDIT, etc) instead of a number
```

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">compiler bug/quirk</span>

### `CONTROL` class specified as a string literal

I said in ["*`CONTROL` class specified as a number*"](#control-class-specified-as-a-number) that `class name` can be specified as a particular set of unquoted identifiers (`BUTTON`, `EDIT`, `STATIC`, etc). I left out that it's also possible to specify them as quoted string literals&mdash;these are equivalent to the unquoted `BUTTON` class name:

<pre><code class="language-rc"><span style="opacity:0.5">CONTROL, "foo", 1, </span><span class="token_string">"BUTTON"</span><span style="opacity:0.5">, 1, 2, 3, 4, 5</span>
<span style="opacity:0.5">CONTROL, "foo", 1, </span>L<span class="token_string">"BUTTON"</span><span style="opacity:0.5">, 1, 2, 3, 4, 5</span></code></pre>

Additionally, this equivalence is determined *after* parsing, so *these* are also equivalent, since `\x42` parses to the ASCII character `B`:

<pre><code class="language-rc"><span style="opacity:0.5">CONTROL, "foo", 1, </span><span class="token_string">"\x42UTTON"</span><span style="opacity:0.5">, 1, 2, 3, 4, 5</span>
<span style="opacity:0.5">CONTROL, "foo", 1, </span>L<span class="token_string">"\x42UTTON"</span><span style="opacity:0.5">, 1, 2, 3, 4, 5</span></code></pre>

All of the above examples get treated the same as the unquoted literal `BUTTON`, which gets compiled to `FF FF 80 00` as mentioned in the previous section.

#### A string masquerading as a number

For class name strings that do not parse into one of the predefined classes (`BUTTON`, `EDIT`, `STATIC`, etc), the class name typically gets written as `NUL`-terminated UTF-16. For example:

<div class="gets-parsed-as">
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
<div style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0;">

```rc
"abc"
```

</div>
</div>
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
<div style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0; justify-content: center; align-items: center; text-align:center;">gets compiled to:</div>
</div>
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
<div style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0;">

```
61 00 62 00 63 00 00 00   a.b.c...
```

</div>
</div>
</div>

However, if you use an `L` prefixed string that starts with a `\xFFFF` escape, then the value is written as if it were a number (i.e. the value is always 32-bits long and has the format `FF FF <number as u16>`). Here's an example:

<div class="gets-parsed-as">
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
<div style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0;">

```rc
L"\xFFFFzzzzzzzz"
```

</div>
</div>
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
<div style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0; justify-content: center; align-items: center; text-align:center;">gets compiled to:</div>
</div>
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
<div style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0;">

```
FF FF 7A 00   ..z.
```

</div>
</div>
</div>

All but the first `z` drop out, as seemingly the first character value after the `\xFFFF` escape is written as a `u16`. Here's another example using a 4-digit hex escape after the `\xFFFF`:

<div class="gets-parsed-as">
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
<div style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0;">

```rc
L"\xFFFF\xABCD"
```

</div>
</div>
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
<div style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0; justify-content: center; align-items: center; text-align:center;">gets compiled to:</div>
</div>
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
<div style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0;">

```
FF FF CD AB   ....
```

</div>
</div>
</div>

<p><aside class="note">

Note: Remember that numbers are compiled as [little-endian](https://en.wikipedia.org/wiki/Endianness), so the `CD AB` sequence reflects that, and is not another bug/quirk of its own.

</aside></p>

So, with this bug/quirk, this:

<div class="gets-parsed-as">
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
<div style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0;">

```rc
L"\xFFFF\x80"
```

</div>
</div>
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
<div style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0; justify-content: center; align-items: center; text-align:center;">gets compiled to:</div>
</div>
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">
<div style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0;">

```
FF FF 80 00   ....
```

</div>
</div>
</div>

which is *indistinguisable* from the compiled form of the class name specified as either an unquoted literal (`BUTTON`) or quoted string (`"BUTTON"`). I want to say that this edge case is so specific that it has to have been intentional, but I'm not sure I can rule out the idea that some very strange confluence of quirks is coming together to produce this behavior unintentionally.

#### `resinator`'s behavior

`resinator` matches the behavior of the Windows RC compiler for the `"BUTTON"`/`"\x42UTTON"` examples, but the `L"\xFFFF..."` edge case [has not yet been decided on](https://github.com/squeek502/resinator/issues/13) as of now.

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
// error RC2176 : old DIB in png.cur; pass it through SDKPAINT
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

Because a `.ico`/`.cur` can contain up to 65535 images, and each image within can report its size as up to 2 GiB (more on this in the next bug/quirk), this means that a small (< 1 MiB) maliciously constructed `.ico`/`.cur` could cause the Windows RC compiler to attempt to write up to 127 TiB of data to the `.res` file.

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

The 2 GiB limit comes from the fact that the Windows RC compiler actually interprets this field as a *signed* integer, so if you try to define an image with a size larger than 2 GiB, it'll get interpreted as negative. We can somewhat confirm this by compiling with the verbose flag (`/v`):

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

But that's not all; take this, for example, where we define an `RCDATA` resource using a raw data block:

```rc
1 RCDATA { 1, ), ), ), 2 }
```

This should very clearly be a syntax error, but it's actually accepted by the Windows RC compiler. What does the RC compiler do, you ask? Well, it just skips right over all the `)`, of course, and the data of this resource ends up as:

<pre class="hexdump" style="display: flex; flex-direction: column; justify-content: center; align-items: center; flex-grow: 1; margin-top: 0;">
  <code class="language-none"><span style="font-family:sans-serif; font-style:italic">the 1 (u16 little endian) &rarr;</span> <span class="o1d o-clr1">01 00</span> <span class="o1d o-clr2">02 00</span> <span style="font-family:sans-serif; font-style:italic">&larr; the 2 (u16 little endian)</span></code>
</pre>

I said 'skip' because that's truly what seems to happen. For example, for resource definitions that take positional parameters like so:

<pre><code class="language-none"><span style="opacity: 50%;">1 DIALOGEX 1, 2, 3, 4 {</span>
  <span class="token_comment">//        &lt;text&gt; &lt;id&gt; &lt;x&gt; &lt;y&gt; &lt;w&gt; &lt;h&gt; &lt;style&gt;</span>
  <span class="token_keyword">CHECKBOX</span>  <span class="token_string">"test"</span>,  1,  2,  3,  4,  5,  6
<span style="opacity: 50%;">}</span></code>
</pre>

If you replace the `<id>` parameter of `1` with `)`, then all the parameters shift over and they get interpreted like this instead:

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

Instead, `(` was bestowed a different power, which we'll see next.

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

In the above case, the parameters are interpreted as if the `(` characters don't exist, e.g. they compile to the values `1`, `2`, `3`, and `4`.

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

### General comma-related inconsistencies

The rules around commas within statements can be one of the following depending on the context:

- Exactly one comma
- Zero or one comma
- Zero or any number of commas

And these rules can be mixed and matched within statements. I've tried to codify my understanding of the rules around commas in a [test `.rc` file I wrote](https://github.com/squeek502/resinator/blob/9a6e50b0c0859e0dee5fd1871d93329e0e1194ef/test/data/reference.rc). Here's an example statement that contains all 3 rules:

```rc
AUTO3STATE,, "mytext",, 900,, 1/*,*/ 2/*,*/ 3/*,*/ 4, 3 | NOT 1L, NOT 1 | 3L
```
<p style="margin:0; text-align: center;"><i class="caption"><code>,,</code> indicates "zero or any number of commas", <code><span class="token_comment">/*,*/</span></code> indicates "zero or one comma", and <code>,</code> indicates "exactly 1 comma"</i></p>

#### Empty parameters

In most places where parameters cannot have any number of commas separating them, `,,` will lead to a compile error. For example:

<div class="short-rc-and-result">
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```rc style="display: flex; flex-direction: column; justify-content: center; flex-grow: 1; margin-top: 0;"
1 ACCELERATORS {
  "^b",, 1
}
```

</div>
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```none style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0; justify-content: center;"
test.rc(2) : error RC2107 : expected numeric command value
```

</div>
</div>

However, there are a few places where empty parameters are accepted, and therefore `,,` is not a compile error, e.g. in the `MENUITEM` of a `MENUEX` resource:

```rc
1 MENUEX {
  // The three statements below are equivalent
  MENUITEM "foo", 0, 0, 0,
  MENUITEM "foo", /*id*/, /*type*/, /*state*/,
  MENUITEM "foo",,,,
  // The parameters are optional, so this is also equivalent
  MENUITEM "foo"
}
```

Adding one more comma will cause a compile error:

<div class="short-rc-and-result">
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```rc style="display: flex; flex-direction: column; justify-content: center; flex-grow: 1; margin-top: 0;"
1 MENUEX {
  MENUITEM "foo",,,,,
}
```

</div>
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```none style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0; justify-content: center;"
test.rc(2) : error RC2235 : too many arguments supplied
```

</div>
</div>

#### Italic is singled out

`DIALOGEX` resources can specify a font to use using a `FONT` optional statement like so:

```rc
1 DIALOGEX 1, 2, 3, 4
  FONT 16, "Foo"
{
  // ...
}
```

The full syntax of the `FONT` statement in this context is:

<pre class="annotated-code"><code class="language-rc" style="white-space: inherit;"><span class="token_keyword">FONT</span> <span class="annotation"><span class="desc">pointsize<i></i></span><span class="subject"><span class="token_identifier">16</span></span></span><span class="token_punctuation">,</span> <span class="annotation"><span class="desc">typeface<i></i></span><span class="subject"><span class="token_string">"Foo"</span></span></span><span class="token_punctuation">,</span> <span class="annotation"><span class="desc">weight<i></i></span><span class="subject"><span class="token_identifier">1</span></span></span><span class="token_punctuation">,</span> <span class="annotation"><span class="desc">italic<i></i></span><span class="subject"><span class="token_identifier">2</span></span></span><span class="token_punctuation">,</span> <span class="annotation"><span class="desc">charset<i></i></span><span class="subject"><span class="token_identifier">3</span></span></span></code></pre>
<p style="margin:0; text-align: center;"><i class="caption"><code>weight</code>, <code>italic</code>, and <code>charset</code> are optional</i></p>

For whatever reason, while `weight` and `charset` can be empty parameters, `italic` seemingly cannot, since this fails:

<div class="short-rc-and-result">
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```rc style="display: flex; flex-direction: column; justify-content: center; flex-grow: 1; margin-top: 0;"
1 DIALOGEX 1, 2, 3, 4
  FONT 16, "Foo", /*weight*/, /*italic*/, /*charset*/
{
  // ...
}
```

</div>
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```none style="display: flex; flex-direction: column; flex-grow: 1; margin-top: 0; justify-content: center;"
test.rc(2) : error RC2112 : BEGIN expected in dialog

test.rc(6) : error RC2135 : file not found: }
```

</div>
</div>

but this succeeds:

```rc
1 DIALOGEX 1, 2, 3, 4
  FONT 16, "Foo", /*weight*/, 0, /*charset*/
{
  // ...
}
```

Due to the strangeness of the error, I'm assuming that this `italic`-parameter-specific-behavior is unintended.

#### Further weirdness

<p><aside class="note">
  
Note: This is not really comma-related, this is just a tangentially-related side note

</aside></p>

Continuing on with the `FONT` statement of `DIALOGEX` resources: as we saw in ["*If you're not last, you're irrelevant*"](#if-you-re-not-last-you-re-irrelevant), if there are duplicate statements of the same type, all but the last one is ignored:

```rc
1 DIALOGEX 1, 2, 3, 4
  FONT 16, "Foo", 1, 2, 3 // Ignored
  FONT 32, "Bar", 4, 5, 6
{
  // ...
}
```

In the above example, the values-as-compiled will all come from this `FONT` statement:

```rc
  FONT 32, "Bar", 4, 5, 6
```

However, given that the `weight`, `italic`, and `charset` parameters are optional, if you don't specify them, then their values from the previous `FONT` statement(s) *do* actually carry over, with the exception of the `charset` parameter:

```rc
1 DIALOGEX 1, 2, 3, 4
  FONT 16, "Foo", 1, 2, 3
  FONT 32, "Bar"
{
  // ...
}
```

With the above, the `FONT` statement that ends up being compiled will effectively be:

```rc
  FONT 32, "Bar", 1, 2, 1
```

where the last `1` is the `charset` parameter's default value (`DEFAULT_CHARSET`) rather than the `3` we might expect from the duplicate `FONT` statement.

#### `resinator`'s behavior

`resinator` matches the Windows RC compiler behavior, but has better error messages/additonal warnings where appropriate:

```resinatorerror
test.rc:2:21: error: expected number or number expression; got ','
  FONT 16, "Foo", , ,
                    ^
test.rc:2:21: note: this line originated from line 2 of file 'test.rc'
  FONT 16, "Foo", /*weight*/, /*italic*/, /*charset*/
```

```resinatorerror
test.rc:2:3: warning: this statement was ignored; when multiple statements of the same type are specified, only the last takes precedence
  FONT 16, "Foo", 1, 2, 3
  ^~~~~~~~~~~~~~~~~~~~~~~
```

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">parser bug/quirk</span>

### `NUL` in filenames

If a filename evaluates to a string that contains a `NUL` (`0x00`) character, the Windows RC compiler treats it as a terminator. For example,

```rc
1 RCDATA "hello\x00world"
```

will try to read from the file `hello`. This is understandable considering how C handles strings, but doesn't exactly seem like desirable behavior since it happens silently.

#### `resinator`'s behavior

Any evaluated filename string containing a `NUL` is an error:

```resinatorerror
test.rc:1:10: error: evaluated filename contains a disallowed codepoint: <U+0000>
1 RCDATA "hello\x00world"
         ^~~~~~~~~~~~~~~~
```

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

will error, and with the `/v` flag (meaning 'verbose') set, `rc.exe` will output:

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

Ideally, a warning would be emitted in cases where the Windows RC compiler would error, but detecting when that would be the case is not something I'm capable of doing currently due to my lack of understanding of this bug/quirk.

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">parser bug/quirk</span>

### All operators have equal precedence

In the Windows RC compiler, all operators have equal precedence, which is not the case in C. This means that there is a mismatch between the precedence used by the preprocessor (C/C++ operator precedence) and the precedence used by the compiler.

Instead of detailing this bug/quirk, though, I'm just going to link to Raymond Chen's excellent description (complete with the potential consequences):

<div class="box-bg box-border" style="padding: 0.5rem 1.5rem;">

[What is the expression language used by the Resource Compiler for non-preprocessor expressions? - The Old New Thing](https://devblogs.microsoft.com/oldnewthing/20230313-00/?p=107928)

</div>

#### `resinator`'s behavior

`resinator` matches the behavior of the Windows RC compiler with regards to operator precedence (i.e. it also contains an operator-precedence-mismatch between the preprocessor and the compiler)

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
<span class="bug-quirk-category">undocumented, cli bug/quirk</span>

### Undocumented/strange command-line options

#### `/sl`: Maximum string length, with a twist

From the help text of the Windows RC compiler (`rc.exe /?`):

```
/sl      Specify the resource string length limit in percentage
```

No further information is given, and the [CLI documentation](https://learn.microsoft.com/en-us/windows/win32/menurc/using-rc-the-rc-command-line-) doesn't even mention the option. It turns out that the `/sl` option expects a number between 1 and 100:


<div class="short-rc-and-result">
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```none style="display: flex; flex-direction: column; justify-content: center; flex-grow: 1; margin-top: 0;"
rc.exe /sl foo test.rc
```

</div>
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```none style="display: flex; flex-direction: column; flex-grow: 1; justify-content: center; margin-top: 0; white-space: pre-wrap;"
fatal error RC1235: invalid option - string length limit percentage should be between 1 and 100 inclusive
```

</div>
</div>

What this option controls is the maximum number of characters within a string literal. For example, 4098 `a` characters within a string literal will fail with `string literal too long`:

<pre><code class="language-rc">1 <span class="token_keyword">RCDATA</span> <span class="token_punctuation">{</span> <span class="token_string">"aaaa</span><span class="token_unrepresentable" title="4090 'a' characters omitted">&lt;...&gt;</span><span class="token_string">aaaa"</span> <span class="token_punctuation">}</span></code></pre>

So, what are the actual limits here? What does 100% of the maximum string literal length limit get you?

- The default maximum string literal length (if `/sl` is not specified) is 4097; it will error if there are 4098 characters in a string literal.
- If `/sl 50` is specified, the maximum string literal length becomes 4096 rather than 4097. There is no `/sl` setting that's equivalent to the default string literal length limit, since the option is limited to whole numbers.
- If `/sl 100` is specified, the maximum length of a string literal becomes 8192.
- If `/sl 33` is set, the maximum string literal length becomes 2703 (`8192 * 0.33 = 2,703.36`). 2704 characters will error with `string literal too long`.
- If `/sl 15` is set, the maximum string literal length becomes 1228 (`8192 * 0.15 = 1,228.8`). 1229 characters will error with `string literal too long`.

And to top it all off, `rc.exe` will crash if `/sl 100` is set and there is a string literal with exactly 8193 characters in it. If one more character is added to the string literal, it errors with 'string literal too long'.

<p><aside class="note">

Note: I'm using the term "character" here for lack of a more precise term. In reality, the Windows RC compiler likely uses something like UTF-16 code unit count, but not in an easily understandable way. For example, even though the default limit is 4097, if you have more than 4094 € codepoints (1 UTF-16 code unit each) or more than 2048 𐐷 codepoints (2 UTF-16 code units each) in a string literal, the Windows RC compiler will error with `string literal too long`.

</aside></p>

##### `resinator`'s behavior

`resinator` uses codepoint count as the limiting factor and avoids the crash when `/sl 100` is set.

```resinatorerror
string-literal-8193.rc:2:2: error: string literal too long (max is currently 8192 characters)
 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa<...truncated...>
 ^~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
```

#### `/a`: The unknown

`/a` seems to be a recognized option but it's unclear what it does and the option is totally undocumented (and also was not an option in the 16-bit version of the compiler from what I can tell). I was unable to find anything that it affects about the output of `rc.exe`.

#### `resinator`'s behavior

```resinatorerror
<cli>: warning: option /a has no effect (it is undocumented and its function is unknown in the Win32 RC compiler)
 ... /a ...
     ~^
```

#### `/?c` and friends: LCX/LCE hidden options

Either one of `/?c` or `/hc` will add a normally hidden 'Comments extracting switches:' section to the help menu, with `/t` and `/t`-prefixed options dealing with `.LCX` and `.LCE` files.

```none
Comments extracting switches:
   /t           Generate .LCX output file
   /tp:<prefix> Extract only comments starting with <prefix>
   /tm          Do not save mnemonics into the output file
   /tc          Do not save comments into the output file
   /tw          Display warning if custom resources does not have LCX file
   /te          Treat all warnings as errors
   /ti          Save source file information for each resource
   /ta          Extract data for all resources
   /tn          Rename .LCE file
```

I can find zero info about any of this online. A generated `.LCE` file seems to be an XML file with some info about the comments and resources in the `.rc` file(s).

##### `resinator`'s behavior

```resinatorerror
<cli>: error: the /t option is unsupported
 ... /t ...
     ~^
```

(and similar errors for all of the other related options)

#### `/p`: Okay, I'll only preprocess, but you're not going to like it

The undocumented `/p` option will output the preprocessed version of the `.rc` file to `<filename>.rcpp` instead of outputting a `.res` file (i.e. it will only run the preprocessor). However, there are two slightly strange things about this option:

- There doesn't appear to be any way to control the name of the `.rcpp` file (`/fo` does not affect it)
- `rc.exe` will always exit with exit code 1 when the `/p` option is used, even on success

##### `resinator`'s behavior

`resinator` recognizes the `/p` option, but (1) it allows `/fo` to control the file name of the preprocessed output file, and (2) it exits with 0 on success.

#### `/s`: What's HWB?

The option `/s <unknown>` will insert a bunch of resources with name `HWB` into the `.res`. I can't find any info on this except a note [on this page](https://learn.microsoft.com/en-us/cpp/windows/how-to-create-a-resource-script-file?view=msvc-170) saying that `HWB` is a resource name that is reserved by Visual Studio. The option seems to need a value but the value doesn't seem to have any affect on the `.res` contents and it seems to accept any value without complaint.

##### `resinator`'s behavior

```resinatorerror
<cli>: error: the /s option is unsupported
 ... /s ...
     ~^
```

#### `/z`: Mysterious font substitution

The undocumented `/z` option almost always errors with 
```
fatal error RC1212: invalid option - /z argument missing substitute font name
```

To avoid this error, a value with `/` in it seems to do the trick (e.g. `rc.exe /z foo/bar test.rc`), but it's still unclear to me what purpose (if any) this option has. The title of ["*No one has thought about `FONT` resources for decades*"](#no-one-has-thought-about-font-resources-for-decades) is probably relevant here, too.

##### `resinator`'s behavior

```resinatorerror
<cli>: error: the /z option is unsupported
 ... /z ...
     ~^
```

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">undocumented</span>

### Undocumented resource types

Most predefined resource types have some level of documentation [here](https://learn.microsoft.com/en-us/windows/win32/menurc/resource-definition-statements) (or are at least listed), but there are a few that are recognized but not documented.

#### `DLGINCLUDE`

The tiny bit of available documentation I could find for `DLGINCLUDE` comes from [Microsoft KB Archive/91697](https://www.betaarchive.com/wiki/index.php/Microsoft_KB_Archive/91697):

> The dialog editor needs a way to know what include file is associated with a resource file that it opens. Rather than prompt the user for the name of the include file, the name of the include file is embedded in the resource file in most cases. 

Here's an example from [`sdkdiff.rc` in Windows-classic-samples](https://github.com/microsoft/Windows-classic-samples/blob/be3df303c13bcf5526250a2e1659e8add8d2e35d/Samples/Win7Samples/begin/sdkdiff/sdkdiff.rc#L281):

```
1 DLGINCLUDE "wdiffrc.h"
```

Further details from [Microsoft KB Archive/91697](https://www.betaarchive.com/wiki/index.php/Microsoft_KB_Archive/91697):

> In the Win32 SDK, changes were made so that this resource has its own resource type; it was changed from an RCDATA-type resource with the special name, DLGINCLUDE, to a DLGINCLUDE resource type whose name can be specified.

So, in the 16-bit Windows RC compiler, a DLGINCLUDE would have looked something like this:

```rc
DLGINCLUDE RCDATA DISCARDABLE
BEGIN
    "GUTILSRC.H\0"
END
```

<p><aside class="note">

Note: Coincidentally, this second example of the deprecated syntax comes from the [exact same `.rc` file as the first example](https://github.com/microsoft/Windows-classic-samples/blob/be3df303c13bcf5526250a2e1659e8add8d2e35d/Samples/Win7Samples/begin/sdkdiff/sdkdiff.rc#L417-L420).

</aside></p>

`DLGINCLUDE` resources get compiled into the `.res`, but subsequently get ignored by `cvtres.exe` (the tool that turns the `.res` into a COFF object file) and therefore do not make it into the final linked binary. So, in practical terms, `DLGINCLUDE` is entirely meaningless outside of the Visual Studio dialog editor GUI as far as I know.

#### `DLGINIT`

The purpose of this resource seems like it could be similar to `controlData` in `DIALOGEX` resources (as detailed in ["*That's odd, I thought you needed more padding*"](#that-s-odd-i-thought-you-needed-more-padding))&mdash;that is, it is used to specify control-specific data that is loaded/utilized when initializing a particular control within a dialog.

Here's an example from [`bits_ie.rc` of Windows-classic-samples](https://github.com/microsoft/Windows-classic-samples/blob/main/Samples/Win7Samples/web/bits/bits_ie/bits_ie.rc):

```rc
IDD_DIALOG DLGINIT
BEGIN
    IDC_PRIORITY, 0x403, 11, 0
0x6f46, 0x6572, 0x7267, 0x756f, 0x646e, "\000" 
    IDC_PRIORITY, 0x403, 5, 0
0x6948, 0x6867, "\000" 
    IDC_PRIORITY, 0x403, 7, 0
0x6f4e, 0x6d72, 0x6c61, "\000" 
    IDC_PRIORITY, 0x403, 4, 0
0x6f4c, 0x0077, 
    0
END
```

The resource itself is compiled the same way an `RCDATA` or User-defined resource would be when using a raw data block, so each number is compiled as a 16-bit little-endian integer. The expected structure of the data seems to be dependent on the type of control it's for (in this case, `IDC_PRIORITY` is the ID for a `COMBOBOX` control). In the above example, the format seems to be something like:

```rc
    <control id>, <language id>, <data length in bytes>, <unknown>
<data ...>
```

The particular format is not very relevant, though, as it is (1) also entirely undocumented, and (2) generated by the Visual Studio dialog editor.

It is worth noting, though, that the `<data ...>` parts of the above example, when written as little-endian `u16` integers, correspond to the bytes for the ASCII string `Foreground`, `High`, `Normal`, and `Low`. These strings can also be seen in the Properties window of the dialog editor in Visual Studio (and the dialog editor is almost certainly how the `DLGINIT` was generated in the first place):

<div style="text-align: center;">
<img style="margin-left:auto; margin-right:auto; display: block;" src="/images/every-rc-exe-bug-quirk-probably/dlginit-properties-window.png">
<p style="margin-top: .5em;"><i class="caption">The <code>Data</code> section of Combo-box Controls in Visual Studio corresponds to the <code>DLGINIT</code> data</i></p>
</div>

While it would make sense for these strings to be used to populate the initial options in the combo box, I couldn't actually get modifications to the `DLGINIT` to affect anything in the compiled program in my testing. I'm guessing that's due to a mistake on my part, though; my knowledge of the Visual Studio GUI side of `.rc` files is essentially zero.

#### `TOOLBAR`

The undocumented `TOOLBAR` resource seems to be used in combination with [`CreateToolbarEx`](https://learn.microsoft.com/en-us/windows/win32/api/commctrl/nf-commctrl-createtoolbarex) to create a toolbar of buttons from a bitmap. Here's the syntax:

```rc
<id> TOOLBAR <button width> <button height> {
  // Any number of
  BUTTON <id>
  // or
  SEPARATOR
  // statements
}
```

This resource is used in a few different `.rc` files within [Windows-classic-samples](https://github.com/Microsoft/Windows-classic-samples). Here's one example from [`VCExplore.Rc`](https://github.com/microsoft/Windows-classic-samples/blob/7af17c73750469ed2b5732a49e5cb26cbb716094/Samples/Win7Samples/com/administration/explore.vc/VCExplore.Rc#L410-L431):

```rc
IDR_TOOLBAR_MAIN TOOLBAR DISCARDABLE  16, 15
BEGIN
    BUTTON      ID_TBTN_CONNECT
    SEPARATOR
    BUTTON      ID_TBTN_REFRESH
    SEPARATOR
    BUTTON      ID_TBTN_NEW
    BUTTON      ID_TBTN_SAVE
    BUTTON      ID_TBTN_DELETE
    SEPARATOR
    BUTTON      ID_TBTN_START_APP
    BUTTON      ID_TBTN_STOP_APP
    BUTTON      ID_TBTN_INSTALL_APP
    BUTTON      ID_TBTN_EXPORT_APP
    SEPARATOR
    BUTTON      ID_TBTN_INSTALL_COMPONENT
    BUTTON      ID_TBTN_IMPORT_COMPONENT
    SEPARATOR
    BUTTON      ID_TBTN_UTILITY
    SEPARATOR
    BUTTON      ID_TBTN_ABOUT
END
```

Additionally, a `BITMAP` resource is defined with the same ID as the toolbar:

```rc
IDR_TOOLBAR_MAIN        BITMAP  DISCARDABLE     "res\\toolbar1.bmp"
```

<div style="text-align: center; padding: 1rem; margin-bottom: 1rem;" class="box-bg box-border">
<img style="margin-left:auto; margin-right:auto; display: block; margin-top: 0.5rem;" src="/images/every-rc-exe-bug-quirk-probably/toolbar1.png">
<p style="margin-top: .5em; margin-bottom: 0;"><i class="caption">The example toolbar bitmap, each icon is 16x15</i></p>
</div>

With the `TOOLBAR` and `BITMAP` resources together, and with a `CreateToolbarEx` call as mentioned above, we get a functional toolbar that looks like this:

<div style="text-align: center;">
<img style="margin-left:auto; margin-right:auto; display: block;" src="/images/every-rc-exe-bug-quirk-probably/toolbar-gui.png">
<p style="margin-top: .5em;"><i class="caption">The toolbar as displayed in the GUI; note the gaps between some of the buttons (the gaps were specified in the <code>.rc</code> file)</i></p>
</div>

#### `resinator`'s behavior

`resinator` supports these undocumented resource types, and attempts to match the behavior of the Windows RC compiler exactly.

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">utterly baffling</span>

### Certain `DLGINCLUDE` filenames break the preprocessor

<p><aside class="note">

Note: See ["*Undocumented resource types*"](#dlginclude) for details on the `DLGINCLUDE` resource

</aside></p>

The following script, when encoded as Windows-1252, will cause the `rc.exe` preprocessor to freak out and output what seems to be garbage:

```rc
1 DLGINCLUDE "\001ýA\001\001\x1aý\xFF"
```

<p><aside class="note">

Note: Certain things about the input can be changed and the bug still reproduces (e.g. the values of the octal escape sequences), but some seemingly innocuous changes can stop the bug from reproducing, like changing the case of the `\x1a` escape sequence to `\x1A`.

</aside></p>

If we run this through the preprocessor like so:

```shellsession
> rc.exe /p test.rc

Preprocessed file created in: test.rcpp
```

Then, in this particular case, it outputs mostly CJK characters and `test.rcpp` ends up looking like this:

```c
#line 1 "C:\\Users\\Ryan\\Programming\\Zig\\resinator\\tmp\\RCa18588"
#line 1 "test.rc"
#line 1 "test.rc"
‱䱄䥇䍎啌䕄∠ぜ㄰䇽ぜ㄰ぜ㄰硜愱峽䙸≆
```

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

<p><aside class="note">

Note: If you happen to have worked extensively with text encodings before, there's a chance you might already have an idea of why the output might look like this.

</aside></p>

As mentioned in ["*The Windows RC compiler 'speaks' UTF-16*"](#the-windows-rc-compiler-speaks-utf-16), the result of the preprocessor is always encoded as UTF-16, and the above is the result of interpreting the preprocessed file as UTF-16. If, instead, we interpret the preprocessed file as UTF-8 (or ASCII), we would see something like this instead:

<pre><code class="language-c"><span class="token_default">#<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span></span><span class="token_identifier">l</span><span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span><span class="token_identifier">i</span><span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span><span class="token_identifier">n</span><span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span><span class="token_identifier">e</span><span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span><span class="token_ansi_c_whitespace token_whitespace"> </span><span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span><span class="token_number">1</span><span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span><span class="token_ansi_c_whitespace token_whitespace"> </span><span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span><span class="token_string">"<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>C<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>:<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>\<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>\<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>U<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>s<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>e<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>r<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>s<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>\<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>\<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>R<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>y<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>a<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>n<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>\<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>\<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>P<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>r<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>o<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>g<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>r<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>a<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>m<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>m<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>i<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>n<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>g<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>\<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>\<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>Z<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>i<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>g<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>\<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>\<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>r<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>e<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>s<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>i<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>n<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>a<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>t<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>o<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>r<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>\<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>\<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>t<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>m<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>p<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>\<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>\<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>R<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>C<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>a<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>2<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>2<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>9<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>4<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>0<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>"</span><span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span><span class="token_ansi_c_whitespace token_whitespace">
</span><span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span><span class="token_ansi_c_whitespace token_whitespace">
</span><span class="token_default"><span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>#<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span></span><span class="token_identifier">l</span><span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span><span class="token_identifier">i</span><span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span><span class="token_identifier">n</span><span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span><span class="token_identifier">e</span><span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span><span class="token_ansi_c_whitespace token_whitespace"> </span><span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span><span class="token_number">1</span><span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span><span class="token_ansi_c_whitespace token_whitespace"> </span><span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span><span class="token_string">"<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>t<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>e<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>s<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>t<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>.<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>r<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>c<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>"</span><span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span><span class="token_ansi_c_whitespace token_whitespace">
</span><span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span><span class="token_ansi_c_whitespace token_whitespace">
</span><span class="token_default"><span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>#<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span></span><span class="token_identifier">l</span><span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span><span class="token_identifier">i</span><span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span><span class="token_identifier">n</span><span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span><span class="token_identifier">e</span><span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span><span class="token_ansi_c_whitespace token_whitespace"> </span><span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span><span class="token_number">1</span><span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span><span class="token_ansi_c_whitespace token_whitespace"> </span><span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span><span class="token_string">"<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>t<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>e<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>s<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>t<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>.<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>r<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>c<span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span>"</span><span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span><span class="token_ansi_c_whitespace token_whitespace">
</span><span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span><span class="token_ansi_c_whitespace token_whitespace">
</span><span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span><span class="token_number">1</span><span class="token_ansi_c_whitespace token_whitespace"> </span><span class="token_identifier">DLGINCLUDE</span><span class="token_ansi_c_whitespace token_whitespace"> </span><span class="token_string">"?"""</span><span class="token_ansi_c_whitespace token_whitespace">
</span><span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span><span class="token_ansi_c_whitespace token_whitespace">
</span><span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span><span class="token_ansi_c_whitespace token_whitespace">
</span></code></pre>

With this interpretation, we can see that `1 DLGINCLUDE "â"""` actually *did* get emitted by the preprocessor (albeit with `â` replaced by `?`), but it was emitted as a single-byte-encoding (e.g. ASCII) while the rest of the file was emitted as UTF-16 (hence all the <code><span class="token_unrepresentable" title="NUL">&lt;0x00&gt;</span></code> bytes). The file mixing encodings like this means that it is completely unusable, but at least we know a little bit about what's going on. As to *why* or *how* this bug could manifest, that is *completely* unknowable. I can't even hazard a guess as to why certain `DLGINCLUDE` string literals would cause the preprocessor to output parts of the file with a single-byte-encoding.

Some commonalities between all the reproductions of this bug I've found so far:
- The byte count of the `.rc` file is even, no reproduction has had a filesize with an odd byte count.
- The number of distinct sequences (a byte, an escaped integer, or an escaped quote) in the filename string has to be small (min: 2, max: 18)

<p><aside class="note">

Here's a `.zip` file containing a bunch of files that reproduce this bug: [dlginclude_breaks_the_preprocessor.zip](https://www.ryanliptak.com/misc/dlginclude_breaks_the_preprocessor.zip)

</aside></p>

#### `resinator`'s behavior

`resinator` avoids this bug and handles the affected strings the same way that other `DLGINCLUDE` strings are handled by the Windows RC compiler

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">utterly baffling</span>

### Certain `DLGINCLUDE` filenames trigger `missing '=' in EXSTYLE=<flags>` errors

<p><aside class="note">

Note: See ["*Undocumented resource types*"](#dlginclude) for details on the `DLGINCLUDE` resource

</aside></p>

Certain strings, when used with the `DLGINCLUDE` resource, will cause a seemingly entirely disconnected error. Here's one example (truncated, the full reproduction is just a longer sequence of random characters/escapes):

<pre><code class="language-rc"><span class="token_identifier">1</span><span class="token_rc_whitespace token_whitespace"> </span><span class="token_keyword">DLGINCLUDE</span><span class="token_rc_whitespace token_whitespace"> </span><span class="token_string">"\06f\x2\x2b\445q\105[ð\134\x90<span class="token_unrepresentable" title="about 230 more characters/escape sequences not shown"><...truncated...></span>"</span><span class="token_rc_whitespace token_whitespace">
</span></code></pre>

If we try to compile this, we get this error:

```
test.rc(2) : error RC2136 : missing '=' in EXSTYLE=<flags>
```

Not only do I not know why this error would ever be triggered for `DLGINCLUDE` (`EXSTYLE` is specific to `DIALOG`/`DIALOGEX`), I'm not even sure what this error means or how it could be triggered *normally*, since [`EXSTYLE` doesn't use the syntax `EXSTYLE=<flags>` at all](https://learn.microsoft.com/en-us/windows/win32/menurc/exstyle-statement). If we actually try to use the `EXSTYLE=<flags>` syntax, it gives us an error, so this is not a case of an error message for an undocumented feature:

<div class="short-rc-and-result">
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```rc style="display: flex; flex-direction: column; justify-content: center; flex-grow: 1; margin-top: 0;"
1 DIALOG 1, 2, 3, 4
  EXSTYLE=1
{
  // ...
}
```

</div>
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```none style="display: flex; flex-direction: column; justify-content: center; flex-grow: 1; margin-top: 0;"
test.rc(2) : error RC2112 : BEGIN expected in dialog

test.rc(4) : error RC2135 : file not found: END
```

</div>
</div>

I have two possible theories of what might be going on here:

1. The error is intended but the error message is wrong, i.e. it's using some internal code for an error message that never got its message updated accordingly
2. There's a lot of undefined behavior being invoked here, and it just so happens that some random (normally impossible?) error is the result

I'm leaning more towards option 2, since there's no obvious reason why the strings that reproduce the error would cause any error at all. One point against it, though, is that I've found quite a few different reproductions that all trigger the same error&mdash;the only real commonality in the reproductions is that they all have around 240 to 250 distinct characters/escape sequences within the `DLGINCLUDE` string literal.

<p><aside class="note">

Here's a `.zip` file containing a bunch of files that reproduce this bug: [dlginclude_missing_equal_in_exstyle.zip](https://www.ryanliptak.com/misc/dlginclude_missing_equal_in_exstyle.zip)

</aside></p>

#### `resinator`'s behavior

`resinator` avoids the error and handles the affected strings the same way that other `DLGINCLUDE` strings are handled by the Windows RC compiler

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">undocumented</span>

### Various other undocumented/misdocumented things

#### Predefined macros

The [documentation](https://learn.microsoft.com/en-us/windows/win32/menurc/predefined-macros) only mentions `RC_INVOKED`, but `_WIN32` is also defined by default by the Windows RC compiler. For example, this successfully compiles and the `.res` contains the `RCDATA` resource.

```rc
#ifdef _WIN32
1 RCDATA { "hello" }
#endif
```

#### Dialog controls

In the ["Edit Control Statements"](https://learn.microsoft.com/en-us/windows/win32/menurc/dialogex-resource#edit-control-statements) documentation:

- `BEDIT` is listed, but is unrecognized by the Windows RC compiler and will error with `undefined keyword or key name: BEDIT` if you attempt to use it
- `HEDIT` and `IEDIT` are listed and are recognized, but have no further documentation

In the ["GROUPBOX control"](https://learn.microsoft.com/en-us/windows/win32/menurc/groupbox-control) documentation, it says:

> The GROUPBOX statement, which you can use only in a DIALOGEX statement, defines the text, identifier, dimensions, and attributes of a control window.

However, the "can use only in a `DIALOGEX` statement" (meaning it's not allowed in a `DIALOG` resource) is not actually true, since this compiles successfully:

```rc
1 DIALOG 0, 0, 640, 480 {
  GROUPBOX "text", 1, 2, 3, 4, 5
}
```

In the ["Button Control Statements"](https://learn.microsoft.com/en-us/windows/win32/menurc/dialogex-resource#button-control-statements) documentation, `USERBUTTON` is listed (and is recognized by the Windows RC compiler), but contains no further documentation.

#### `HTML` can use a raw data block, too

In the [`RCDATA`](https://learn.microsoft.com/en-us/windows/win32/menurc/rcdata-resource) and [User-defined resource documentation](https://learn.microsoft.com/en-us/windows/win32/menurc/user-defined-resource), it mentions that they can use raw data blocks:

> The data can have any format and can be defined [...] as a series of numbers and strings (if the raw-data block is specified).

The [`HTML` resource documentation](https://learn.microsoft.com/en-us/windows/win32/menurc/html-resource) does not mention raw data blocks, even though it, too, can use them:

```rc
1 HTML { "foo" }
```

#### `GRAYED` and `INACTIVE`

In both the [`MENUITEM`](https://learn.microsoft.com/en-us/windows/win32/menurc/menuitem-statement#optionlist) and [`POPUP`](https://learn.microsoft.com/en-us/windows/win32/menurc/popup-resource#optionlist) documentation:

<blockquote>
<table style="width: 100%; text-align: left;">
  <thead>
    <tr>
      <th>Option</th>
      <th>Description</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td><b>GRAYED</b></td>
      <td>[...]. This option cannot be used with the <b>INACTIVE</b> option.</td>
    </tr>
    <tr>
      <td><b>INACTIVE</b></td>
      <td>[...]. This option cannot be used with the <b>GRAYED</b> option.</td>
    </tr>
  </tbody>
</table>
</blockquote>

However, there is no warning or error if they *are* used together:

```rc
1 MENU {
  POPUP "bar", GRAYED, INACTIVE {
    MENUITEM "foo", 1, GRAYED, INACTIVE
  }
}
```

It's not clear to me why the documentation says that they cannot be used together, and I haven't (yet) put in the effort to investigate if there are any practical consequences of doing so.

#### Semicolon comments

From the [Comments documentation](https://learn.microsoft.com/en-us/windows/win32/menurc/comments):

> RC supports C-style syntax for both single-line comments and block comments. Single-line comments begin with two forward slashes (//) and run to the end of the line.

What's not mentioned is that a semicolon (`;`) is treated roughly the same as `//`:

```rc
; this is treated as a comment
1 RCDATA { "foo" } ; this is also treated as a comment
```

There is one difference, though, and that's how each is treated within a resource ID/type. As mentioned in ["*Special tokenization rules for names/IDs*"](#special-tokenization-rules-for-names-ids), resource ID/type tokens are basically only terminated by whitespace. However, `//` within an ID/type is treated as the start of a comment, so this, for example, errors:

<div class="short-rc-and-result">
<div style="text-align: center; display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```rc style="display: flex; flex-direction: column; justify-content: center; flex-grow: 1; margin-top: 0;"
1 RC//DATA { "foo" }
```

</div>
<div style="display: flex; flex-direction: column; flex-basis: 100%; flex: 1;">

```none style="display: flex; flex-direction: column; flex-grow: 1; justify-content: center; margin-top: 0;"
test.rc(2) : error RC2135 : file not found: RC
```

</div>
</div>
<p style="text-align: center; margin-top: 0;"><i class="caption">See <a href="#incomplete-resource-at-eof">"Incomplete resource at EOF"</a> for an explanation of the error</i></p>

This is not the case for semicolons, though, where the following example compiles into a resource with the type `RC;DATA`:

```rc
1 RC;DATA { "foo" }
```

We can be reasonably sure that the semicolon comment is an intentional feature due to its presence in [a file within Windows-classic-samples](https://github.com/microsoft/Windows-classic-samples/blob/7af17c73750469ed2b5732a49e5cb26cbb716094/Samples/Win7Samples/netds/winsock/ipxchat/IpxChat.Rc):

```rc
; Version stamping information:

VS_VERSION_INFO VERSIONINFO
...

; String table

STRINGTABLE
...
```

but it is wholly undocumented.

#### `BLOCK` statements support values, too

As detailed in ["*Mismatch in length units in `VERSIONINFO` nodes*"](#mismatch-in-length-units-in-versioninfo-nodes), `VALUE` statements within `VERSIONINFO` resources are specified like so:

```rc
VALUE <name>, <value(s)>
```

Some examples:

```rc
1 VERSIONINFO {
  VALUE "numbers", 123, 456
  VALUE "strings", "foo", "bar"
}
```

There are also `BLOCK` statements, which themselves can contain `BLOCK`/`VALUE` statements:

```rc
1 VERSIONINFO {
  BLOCK "foo" {
    VALUE "child", "of", "foo"
    BLOCK "bar" {
      VALUE "nested", "value"
    }
  }
}
```

What is not mentioned anywhere that I've seen, though, is that `BLOCK` statements can also have `<value(s)>` after their name parameter like so:


```rc
1 VERSIONINFO {
  BLOCK "foo", "bar", "baz" {
    // ...
  }
}
```

<p><aside class="note">

Note: In the `.res` output, the `<value(s)>` of a `BLOCK` get compiled identically to how they would if they were part of a `VALUE` statement.

</aside></p>

In practice, this capability is almost entirely irrelevant. Even though `VERSIONINFO` allows you to specify any arbitrary tree structure that you'd like, consumers of the `VERSIONINFO` resource expect a [very particular structure](https://learn.microsoft.com/en-us/windows/win32/menurc/versioninfo-resource#examples) with certain `BLOCK` names. In fact, it's understandable that this is left out of the documentation, since the `VERSIONINFO` documentation doesn't document `BLOCK`/`VALUE` statements in general, but rather only [StringFileInfo BLOCK](https://learn.microsoft.com/en-us/windows/win32/menurc/stringfileinfo-block) and [VarFileInfo BLOCK](https://learn.microsoft.com/en-us/windows/win32/menurc/varfileinfo-block), specifically.

#### `resinator`'s behavior

For all of the undocumented things detailed in this section, `resinator` attempts to match the behavior of the Windows RC compiler 1:1 (or, as closely as my current understanding of the Windows RC compiler's behavior allows).

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">parser bug/quirk, miscompilation</span>

### Non-ASCII accelerator characters

The [`ACCELERATORS`](https://learn.microsoft.com/en-us/windows/win32/menurc/accelerators-resource) resource can be used to essentially define hotkeys for a program. In the message loop of a Win32 program, the `TranslateAccelerator` function can be used to automatically turn the relevant keystrokes into `WM_COMMAND` messages with the associated `idvalue` as the parameter (meaning it can be handled like any other message coming from a menu, button, etc).

Simplified example from [Using Keyboard Accelerators](https://learn.microsoft.com/en-us/windows/win32/menurc/using-keyboard-accelerators):

```rc
1 ACCELERATORS {
  "B", 300, CONTROL, VIRTKEY
}
```

This associates the key combination `Ctrl + B` with the ID `300` which can then be handled in Win32 message loop processing code like this:

```c
// ...
        case WM_COMMAND: 
            switch (LOWORD(wParam)) 
            {
                case 300:
// ...
```

There are also a number of ways to specify the keys for an accelerator, but the relevant form here is specifying "control characters" using a string literal with a `^` character, e.g. `"^B"`.

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
<span class="bug-quirk-category">fundamental concept</span>

### The entirely undocumented concept of the 'output' code page

As mentioned in ["*The Windows RC compiler 'speaks' UTF-16*"](#the-windows-rc-compiler-speaks-utf-16), there are `#pragma code_page` preprocessor directives that can modify how each line of the input `.rc` file is interpreted. Additionally, the default code page for a file can also be set via the CLI `/c` option, e.g. `/c65001` to set the default code page to UTF-8.

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

Even more bizarrely, this disjointedness can *only* occur when a `#pragma code_page` is the first 'thing' in the file:

```rc
// For example, a comment before the #pragma code_page avoids the input/output code page desync
#pragma code_page(1252)
1 RCDATA { "Ó" }
```

With this, still saved as Windows-1252, the code page from the CLI option no longer matters&mdash;even when compiled with `/c65001`, the `0xD3` in the file is both interpreted as Windows-1252 (`Ó`) *and* outputted as Windows-1252 (`0xD3`).

I used the nebulous term 'thing' because the rules for what stops the disjoint code page phenomenon is equally nebulous. Here's what I currently know can come before the first `#pragma code_page` while still causing the input/output code page desync:

- Any whitespace
- A non-`code_page` pragma directive (e.g. `#pragma foo`)
- An `#include` that includes a file with a `.h` or `.c` extension ([the contents of those files are ignored after preprocessing](https://learn.microsoft.com/en-us/windows/win32/menurc/preprocessor-directives))
- A `code_page` pragma with an invalid code page, but only if the `/w` CLI option is set which turns invalid code page pragmas into warnings instead of errors

I have a feeling this list is incomplete, though, as I only recently figured out that it's not an inherent bug/quirk of the first `#pragma code_page` in the file. Here's a file containing all of the above elements:

```rc
#include "empty.h"
    #pragma code_page(123456789)
#pragma foo

#pragma code_page(1252)
1 RCDATA { "Ó" }
```

When compiled with `rc.exe /c65001 /w`, the above still exhibits the input/output code page desync (i.e. the `Ó` is interpreted as Windows-1252 but compiled into UTF-8).

So, to summarize, this is how things seem to work:

- The CLI `/c` option sets both the input and output code pages
- If the first `#pragma code_page` in the file is also the first 'thing' in the file, then it *only* sets the input code page, and does not modify the output code page
- Any other `#pragma code_page` directives set *both* the input and output code pages

This behavior is baffling and I've not seen it mentioned anywhere on the internet at any point in time. Even the concept of the code page affecting the encoding of the output is fully undocumented as far as I can tell.

<p><aside class="note">

Note: This behavior does not generally impact wide string literals, e.g. `L"Ó"` is affected by the input code page, but is always written to the `.res` file as its UTF-16 LE representation so the output code page is not relevant.

</aside></p>

#### `resinator`'s behavior

`resinator` emulates the behavior of the Windows RC compiler, but emits a warning:

```resinatorerror
test.rc:1:1: warning: #pragma code_page as the first thing in the .rc script can cause the input and output code pages to become out-of-sync
#pragma code_page ( 1252 )
^~~~~~~~~~~~~~~~~~~~~~~~~~
test.rc:1:1: note: this line originated from line 1 of file 'test.rc'
#pragma code_page(1252)

test.rc:1:1: note: to avoid unexpected behavior, add a comment (or anything else) above the #pragma code_page line
```

It's possible that `resinator` will not emulate the input/output code page desync in the future, but still emit a warning about the Windows RC compiler behavior when the situation is detected.

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">preprocessor bug/quirk</span>

### That's not whitespace, *this* is whitespace

As touched on in ["*The collapse of whitespace is imminent*"](#the-collapse-of-whitespace-is-imminent), the preprocessor trims whitespace. What wasn't mentioned explicitly, though, is that this whitespace trimming happens for every line in the file (and it only trims leading whitespace). So, for example, if you run this simple example through the preprocessor:

```rc
1 RCDATA {
    "this was indented"
}
```

it becomes this after preprocessing:

```rc
1 RCDATA {
"this was indented"
}
```

Additionally, as briefly mentioned in ["*Special tokenization rules for names/IDs*"](#special-tokenization-rules-for-names-ids), the Windows RC compiler treats any ASCII character from `0x05` to `0x20` (inclusive) as whitespace for the purpose of tokenization. However, it turns out that this is *not* the set of characters that the *preprocessor* treats as whitespace.

To determine what the preprocessor considers to be whitespace, we can take advantage of its whitespace collapsing behavior. For example, if we run the following script through the preprocessor, we will see that it does not get collapsed, so therefore we know the preprocessor does not consider <code><span class="token_unrepresentable" title="U+0005 Enquiry">&lt;0x05&gt;</span></code> to be whitespace:

<pre><code class="language-rc"><span class="token_identifier">1</span><span class="token_rc_whitespace token_whitespace"> </span><span class="token_keyword">RCDATA</span><span class="token_rc_whitespace token_whitespace"> </span><span class="token_punctuation">{</span>
<span class="token_unrepresentable" title="U+0005 Enquiry">&lt;0x05&gt;</span>   <span class="token_string">"this was indented"</span><span class="token_rc_whitespace token_whitespace">
</span><span class="token_punctuation">}</span><span class="token_rc_whitespace token_whitespace">
</span></code></pre>

<p><aside class="note">

Note: This will still compile just fine, though, as <code><span class="token_unrepresentable" title="U+0005 Enquiry">&lt;0x05&gt;</span></code> *is* considered to be whitespace by the tokenizer/parser, so the file will still end up being parsed into the same result.

</aside></p>

If we iterate over every codepoint and check if they get collapsed, we can figure out exactly what the preprocessor sees as whitespace. These are the results:

<ul class="collapsing-list">
<li>U+0009 Horizontal Tab (<code>\t</code>)</li>
<li>U+000A Line Feed (<code>\n</code>)</li>
<li>U+000B Vertical Tab</li>
<li>U+000C Form Feed</li>
<li>U+000D Carriage Return (<code>\r</code>)</li>
<li>U+0020 Space</li>
<li>U+00A0 No-Break Space</li>
<li>U+1680 Ogham Space Mark</li>
<li>U+180E Mongolian Vowel Separator</li>
<li>U+2000 En Quad</li>
<li>U+2001 Em Quad</li>
<li>U+2002 En Space</li>
<li>U+2003 Em Space</li>
<li>U+2004 Three-Per-Em Space</li>
<li>U+2005 Four-Per-Em Space</li>
<li>U+2006 Six-Per-Em Space</li>
<li>U+2007 Figure Space</li>
<li>U+2008 Punctuation Space</li>
<li>U+2009 Thin Space</li>
<li>U+200A Hair Space</li>
<li>U+2028 Line Separator</li>
<li>U+2029 Paragraph Separator</li>
<li>U+202F Narrow No-Break Space</li>
<li>U+205F Medium Mathematical Space</li>
<li>U+3000 Ideographic Space</li>
</ul>

This list *almost* matches exactly with the Windows implementation of [`iswspace`](https://learn.microsoft.com/en-us/cpp/c-runtime-library/reference/isspace-iswspace-isspace-l-iswspace-l), but `iswspace` returns `true` for [U+0085 Next Line](https://codepoints.net/U+0085) while the `rc.exe` preprocessor does not consider U+0085 to be whitespace. So, while I consider the `rc.exe` preprocessor using `iswspace` to be the most likely explanation for its whitespace handling, I don't have a reason for why U+0085 in particular is excluded.

In terms of practical consequences of this mismatch in whitespace characters between the preprocessor and the parser, I don't have much. This is mostly just another entry in the general "things you would expect some consistency on" category. The only thing I was able to come up with is related to the previous ["*The entirely undocumented concept of the 'output' code page*"](#the-entirely-undocumented-concept-of-the-output-code-page) section, since the trimming of whitespace-that-only-the-preprocessor-considers-to-be-whitespace means that this example will exhibit the input/output code page desync:

<pre><code class="language-rc"><span class="token_unrepresentable" title="U+00A0 No-Break Space">&lt;U+00A0&gt;</span><span class="token_unrepresentable" title="U+1680 Ogham Space Mark">&lt;U+1680&gt;</span><span class="token_unrepresentable" title="U+180E Mongolian Vowel Separator">&lt;U+180E&gt;</span>
<span class="token_preprocessor">#pragma</span><span class="token_rc_whitespace token_whitespace"> </span><span class="token_identifier">code_page</span><span class="token_punctuation">(</span><span class="token_identifier">1252</span><span class="token_punctuation">)</span><span class="token_rc_whitespace token_whitespace">
</span><span class="token_identifier">1</span><span class="token_rc_whitespace token_whitespace"> </span><span class="token_keyword">RCDATA</span><span class="token_rc_whitespace token_whitespace"> </span><span class="token_punctuation">{</span><span class="token_rc_whitespace token_whitespace"> </span><span class="token_string">"Ó"</span><span class="token_rc_whitespace token_whitespace"> </span><span class="token_punctuation">}</span><span class="token_rc_whitespace token_whitespace">
</span></code></pre>

#### `resinator`'s behavior

`resinator` does not currently handle this very well. There's some support for [handling `U+00A0` (No-Break Space)](https://github.com/squeek502/resinator/blob/a2a8f61fbdabdc2339a3a36ab1ce44b73e682177/src/lex.zig#L286-L291) at the start of a line in the tokenizer due to a previously incomplete understanding of this bug/quirk, but I'm currently in the process of considering how this should best be handled.

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">parser bug/quirk, utterly baffling</span>

### String literals that are forced to be 'wide'

There are two types of string literals in `.rc` files. For lack of better terminology, I'm going to call them normal (`"foo"`) and wide (`L"foo"`, note the `L` prefix). In the context of raw data blocks, this difference is meaningful with regards to the compiled result, since normal string literals are encoded using the current output code page (see ["*The entirely undocumented concept of the 'output' code page*"](#the-entirely-undocumented-concept-of-the-output-code-page)), while wide string literals are encoded as UTF-16:

<pre class="hexdump"><code class="language-rc"><span class="token_identifier">1</span><span class="token_rc_whitespace token_whitespace"> </span><span class="token_keyword">RCDATA</span><span class="token_rc_whitespace token_whitespace"> </span><span class="token_punctuation">{</span><span class="token_rc_whitespace token_whitespace">
  </span><span class="token_string">"foo"</span><span class="token_punctuation">,</span>  <span class="token_function">────►</span>  <span class="infotip o1o o-clr1" title="Hexdump of the compiled result of &quot;foo&quot;">66 6F 6F  foo</span>
  <span class="token_identifier">L</span><span class="token_string">"foo"</span>  <span class="token_function">────►</span>  <span class="infotip o1o o-clr2" title="Hexdump of the compiled result of L&quot;foo&quot;">66 00 6F 00 6F 00  f.o.o.</span>
<span class="token_punctuation">}</span><span class="token_rc_whitespace token_whitespace">
</span></code></pre>

However, in other contexts, the result is *always* encoded as UTF-16, and, in that case, there are some special (and strange) rules for how strings are parsed/handled. The full list of contexts in which this occurs is not super relevant (see the [usages of `parseQuotedStringAsWideString`](https://github.com/search?q=repo%3Asqueek502%2Fresinator%20parseQuotedStringAsWideString&type=code) in `resinator` if you're curious), so we'll focus on just one: `STRINGTABLE` strings. Within a `STRINGTABLE`, both `"foo"` and `L"foo"` will get compiled to the same result (encoded as UTF-16):

<pre class="hexdump"><code class="language-rc"><span class="token_keyword">STRINGTABLE</span><span class="token_rc_whitespace token_whitespace"> </span><span class="token_punctuation">{</span>
  1 <span class="token_string">"foo"</span>   <span class="token_function">────►</span>  <span class="infotip o1o o-clr1" title="Hexdump of the compiled result of &quot;foo&quot;">66 00 6F 00 6F 00  f.o.o.</span>
  2 <span class="token_identifier">L</span><span class="token_string">"foo"</span>  <span class="token_function">────►</span>  <span class="infotip o1o o-clr2" title="Hexdump of the compiled result of L&quot;foo&quot;">66 00 6F 00 6F 00  f.o.o.</span>
<span class="token_punctuation">}</span><span class="token_rc_whitespace token_whitespace">
</span></code></pre>

We can also ignore `L` prefixed strings (wide strings) from here on out, since they aren't actually any different in this context than any other. The bug/quirk in question only manifests for "normal" strings that are parsed/compiled into UTF-16, so for the sake of clarity, I'm going to call such strings "forced-wide" strings. For all other strings except "forced-wide" strings, integer escape sequences (e.g. `\x80` [hexadecimal] or `\123` [octal]) are handled as you might expect&mdash;the number they encode is directly emitted, so e.g. the sequence `\x80` always gets compiled into the integer value `0x80`, and then either written as a `u8` or a `u16` as seen here:

<pre class="hexdump"><code class="language-rc"><span class="token_identifier">1</span><span class="token_rc_whitespace token_whitespace"> </span><span class="token_keyword">RCDATA</span><span class="token_rc_whitespace token_whitespace"> </span><span class="token_punctuation">{</span><span class="token_rc_whitespace token_whitespace">
  </span><span class="token_string">"\x80"</span><span class="token_punctuation">,</span>    <span class="token_function">────►</span>  <span class="infotip o1o o-clr1" title="Hexdump of the compiled result of &quot;\x80&quot;">80</span>
  <span class="token_identifier">L</span><span class="token_string">"\x80"</span>    <span class="token_function">────►</span>  <span class="infotip o1o o-clr2" title="Hexdump of the compiled result of L&quot;\x80&quot;">80 00</span>
<span class="token_punctuation">}</span>

<span class="token_keyword">STRINGTABLE</span><span class="token_rc_whitespace token_whitespace"> </span><span class="token_punctuation">{</span>
  1 <span class="token_identifier">L</span><span class="token_string">"\x80"</span>  <span class="token_function">────►</span>  <span class="infotip o1o o-clr3" title="Hexdump of the compiled result of L&quot;\x80&quot;">80 00</span>
<span class="token_punctuation">}</span></code></pre>

However, for "forced-wide" strings, this is not the case:

<pre class="hexdump"><code class="language-rc"><span class="token_keyword">STRINGTABLE</span><span class="token_rc_whitespace token_whitespace"> </span><span class="token_punctuation">{</span>
  1 <span class="token_string">"\x80"</span>  <span class="token_function">────►</span>  <span class="infotip o1o o-clr3" title="Hexdump of the compiled result of &quot;\x80&quot;">AC 20</span>
<span class="token_punctuation">}</span></code></pre>

Why is the result `AC 20`? Well, for these "forced-wide" strings, the escape sequence is parsed, *then that value is re-interpreted using the current code page*, and then the *resulting codepoint* is written as UTF-16. In the above example, the current code page is [Windows-1252](https://en.wikipedia.org/wiki/Windows-1252) (the default), so this is what's going on:

- `\x80` parsed into an integer is `0x80`
- `0x80` interpreted as Windows-1252 is `€`
- `€` has the codepoint value `U+20AC`
- `U+20AC` encoded as little-endian UTF-16 is `AC 20`

This means that if we use a different code page, then the compiled result will also be different. If we use `rc.exe /c65001` to set the code page to UTF-8, then this is what we get:

<pre class="hexdump"><code class="language-rc"><span class="token_keyword">STRINGTABLE</span><span class="token_rc_whitespace token_whitespace"> </span><span class="token_punctuation">{</span>
  1 <span class="token_string">"\x80"</span>  <span class="token_function">────►</span>  <span class="infotip o1o o-clr3" title="Hexdump of the compiled result of &quot;\x80&quot;">FD FF</span>
<span class="token_punctuation">}</span></code></pre>

`FD FF` is the little-endian UTF-16 encoding of the codepoint [`U+FFFD`](https://codepoints.net/U+FFFD) (� aka the Replacement Character). The explanation for this result is a bit more involved, so let's take a brief detour...

It is possible for string literals within `.rc` files to contain byte sequences that are considered invalid within their code page. The easiest way to demonstrate this is with UTF-8, where there are many ways to construct invalid sequences. One such way is just to include a byte that can never be part of a valid UTF-8 sequence, like <code><span class="token_unrepresentable" title="0xFF is never valid in UTF-8">&lt;0xFF&gt;</span></code>. If we do so, this is the result:

<pre class="hexdump"><code class="language-rc"><span class="token_identifier">1</span><span class="token_rc_whitespace token_whitespace"> </span><span class="token_keyword">RCDATA</span><span class="token_rc_whitespace token_whitespace"> </span><span class="token_punctuation">{</span><span class="token_rc_whitespace token_whitespace">
  </span><span class="token_string">"<span class="token_unrepresentable" title="0xFF is never valid in UTF-8">&lt;0xFF&gt;</span>"</span><span class="token_punctuation">,</span>  <span class="token_function">────►</span>  <span class="infotip o1o o-clr1" title="Hexdump of the compiled result of &quot;&lt;0xFF&gt;&quot;">EF BF BD</span>
  <span class="token_identifier">L</span><span class="token_string">"<span class="token_unrepresentable" title="0xFF is never valid in UTF-8">&lt;0xFF&gt;</span>"</span>  <span class="token_function">────►</span>  <span class="infotip o1o o-clr2" title="Hexdump of the compiled result of L&quot;&lt;0xFF&gt;&quot;">FD FF</span>
<span class="token_punctuation">}</span></code></pre>
<p style="margin:0; text-align: center;"><i class="caption">Compiled using the UTF-8 code page via <code>rc.exe /c65001</code></i></p>

`EF BF BD` is [`U+FFFD`](https://codepoints.net/U+FFFD) (�) encoded as UTF-8, and (as mentioned before), `FD FF` is the little-endian UTF-16 encoding of the same codepoint. So, when encountering an invalid sequence within a string literal, the Windows RC compiler converts it to the Unicode Replacement Character and then encodes that as whatever encoding should be emitted in that context.

<p><aside class="note">

Note: Invalid sequences can span multiple bytes, e.g. <code><span class="token_unrepresentable" title="Valid start byte of a 3-byte sequence">&lt;0xE1&gt;</span><span class="token_unrepresentable" title="Valid continuation byte">&lt;0xA0&gt;</span></code> will get compiled into one `�`, while <code><span class="token_unrepresentable" title="Valid start byte of a 2-byte sequence">&lt;0xC5&gt;</span><span class="token_unrepresentable" title="Invalid byte, unused in UTF-8">&lt;0xFF&gt;</span></code> will be treated as two invalid sequences and get compiled into `��`. The algorithm for this is similar to what's detailed in ["U+FFFD Substitution of Maximal Subparts" from the Unicode Standard](https://www.unicode.org/versions/Unicode16.0.0/core-spec/chapter-3/#G66453), but it is not entirely the same.

It's possible that the differences to the Unicode algorithm should be included in this article as their own bug/quirk, but I've made the choice to omit those details.

</aside></p>

Okay, so getting back to the bug/quirk at hand, we now know that invalid sequences are converted to `�`, which is encoded as `FD FF`. We also know that `FD FF` is what we get after compiling the escaped integer `\x80` within a "forced-wide" string when using the UTF-8 code page. Further, we know that escaped integers in "forced-wide" strings are re-interpreted using the current code page.

In UTF-8, the byte value `0x80` is a continuation byte, so it makes sense that, when re-interpreted as UTF-8, it is considered an invalid sequence. However, that's actually irrelevant; parsed integer sequences seem to be re-interpreted in isolation, so *any* value between `0x80` and `0xFF` is treated as an invalid sequence, as those values can only be valid within a multi-byte UTF-8 sequence. This can be confirmed by attempting to construct a valid multi-byte UTF-8 sequence using an integer escape as at least one of the bytes, but seeing nothing but � in the result:

<pre class="hexdump"><code class="language-rc"><span class="token_keyword">STRINGTABLE</span><span class="token_rc_whitespace token_whitespace"> </span><span class="token_punctuation">{</span>
  1 <span class="token_string">"\xE2\x82\xAC"</span>      <span class="token_function">────►</span>  <span class="infotip o1o o-clr3" title="Hexdump of the compiled result of L&quot;\xE2\x82\xAC&quot;">FD FF FD FF FD FF</span>
  2 <span class="token_string">"\xE2<span class="token_unrepresentable" title="Second byte of € encoded as UTF-8">&lt;0x82&gt;</span><span class="token_unrepresentable" title="Third byte of € encoded as UTF-8">&lt;0xAC&gt;</span>"</span>  <span class="token_function">────►</span>  <span class="infotip o1o o-clr3" title="Hexdump of the compiled result of L&quot;\xE2&lt;0x82&gt;&lt;0xAC&gt;&quot;">FD FF FD FF FD FF</span>
<span class="token_punctuation">}</span></code></pre>
<p style="margin:0; text-align: center;"><i class="caption"><code>E2 82 AC</code> is the UTF-8 encoding of € (<a href="https://codepoints.net/U+20AC"><code>U+20AC</code></a>)</i></p>

An extra wrinkle comes when dealing with octal escapes. `0xFF` in octal is `0o377`, which means that octal escape sequences need to accept 3 digits in order to specify all possible values of a `u8`. However, this also means that octal escape sequences can encode values above the maximum `u8` value, e.g. `\777` (the maximum escaped octal integer) represents the value 511 in decimal or `0x1FF` in hexadecimal. This is handled by the Windows RC compiler by truncating the value down to a `u8`, so e.g. `\777` gets parsed into `0x1FF` but then gets truncated down to `0xFF` before then going through the steps mentioned before.

Here's an example where three different escaped integers end up compiling down to the same result, with the last one only being equal after truncation:

<pre class="hexdump"><code class="language-rc"><span class="token_keyword">STRINGTABLE</span><span class="token_rc_whitespace token_whitespace"> </span><span class="token_punctuation">{</span>
  1 <span class="token_string">"\x80"</span>  <span class="token_function">────►</span> <span class="o1o o-clr1">0x80</span> <span class="token_function">─►</span> <span class="o1o o-clr1">€</span> <span class="token_function">─►</span> <span class="o1o o-clr1">AC 20</span>
  2 <span class="token_string">"\200"</span>  <span class="token_function">────►</span> <span class="o1o o-clr2">0x80</span> <span class="token_function">─►</span> <span class="o1o o-clr2">€</span> <span class="token_function">─►</span> <span class="o1o o-clr2">AC 20</span>
  3 <span class="token_string">"\600"</span>  <span class="token_function">────►</span> <span class="o1o o-clr3">0x180</span> <span class="token_function">─►</span> <span class="o1o o-clr3">0x80</span> <span class="token_function">─►</span> <span class="o1o o-clr3">€</span> <span class="token_function">─►</span> <span class="o1o o-clr3">AC 20</span>
<span class="token_punctuation">}</span></code></pre>
<p style="margin:0; text-align: center;"><i class="caption">Compiled using the Windows-1252 code page, so <code>0x80</code> is re-interpreted as € (<code>U+20AC</code>)</i></p>

<p><aside class="note">

Note: Wide string literals can specify up to 4 hex digits and 6 octal digits in their escaped integers:

<pre class="hexdump"><code class="language-rc"><span class="token_identifier">1</span><span class="token_rc_whitespace token_whitespace"> </span><span class="token_keyword">RCDATA</span><span class="token_rc_whitespace token_whitespace"> </span><span class="token_punctuation">{</span><span class="token_rc_whitespace token_whitespace">
   </span><span class="token_string">"<span class="o1o o-clr1 infotip" title="Escaped hex can only be 2 digits in normal string literals">\xAB</span>CDEF"</span><span class="token_punctuation">,</span>
  <span class="token_identifier">L</span><span class="token_string">"<span class="o1o o-clr2 infotip" title="Escaped hex can be 4 digits in wide string literals">\xABCD</span>EF"</span>
<span class="token_punctuation">}</span><span class="token_rc_whitespace token_whitespace">
</span></code></pre>

"Forced-wide" strings still use the limits of "normal" strings, though, so only 2 hex digits / 3 octal digits are accepted.

</aside></p>

Finally, things get a little more bizarre when combined with ["*The entirely undocumented concept of the 'output' code page*"](#the-entirely-undocumented-concept-of-the-output-code-page), as it turns out the re-interpretation of the escaped integers in "forced-wide" strings actually uses *the output code page*, not the input code page.

#### Why?

This one is truly baffling to me. If this behavior is intentional, I don't understand the use-case *at all*. It effectively means that it's impossible to use escaped integers to specify certain values, and it also means that which values those are depends on the current code page. For example, if the code page is Windows-1252, it's impossible to use escaped integers for the values `0x80`, `0x82`-`0x8C`, `0x8E`, `0x91`-`0x9C`, and `0x9E`-`0x9F` (each of these is mapped to a codepoint with a different value). If the code page is UTF-8, then it's impossible to use escaped integers for any of the values from `0x80`-`0xFF` (all of these are treated as part of a invalid UTF-8 sequence and converted to �). This limitation seemingly defeats the entire purpose of escaped integer sequences.

This leads me to believe this is a bug, and even then, it's a *very* strange bug. There is absolutely no reason I can conceive of for the *result of a parsed integer escape* to be *accidentally* re-interpreted as if it were encoded as the current code page.

#### `resinator`'s behavior

`resinator` currently matches the behavior of the Windows RC compiler exactly for "forced-wide" strings. However, using an escaped integer in a "forced-wide" string is likely to become a warning in the future.

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

Let's back up a bit and talk in a bit more detail about [UTF-16](https://en.wikipedia.org/wiki/UTF-16) and [endianness](https://en.wikipedia.org/wiki/Endianness). Since UTF-16 uses 2 bytes per code unit, it can be encoded either as little-endian (least-significant byte first) or big-endian (most-significant byte first).

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

`U+FFFF` works the exact same way as `U+FFFE`&mdash;it, too, causes all non-ACII codepoints in the file to be byteswapped&mdash;and I have no clue as to why that would be since `U+FFFF` has no apparent relationship to a BOM. My only guess is an errant `>= 0xFFFE` check on a `u16` value.

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

<pre><code class="language-resinatorerror"><span class="token_diagnostic token_bold">test.rc:1:12:</span><span class="token_warning token_bold"> warning:</span><span class="token_diagnostic token_bold"> codepoint U+0900 within a string literal would be miscompiled by the Win32 RC compiler (it would get treated as U+0009)
</span><span class="token_default">1 RCDATA { "ऀ਀਍ഀ&#x2000;" }
</span><span class="token_selector">           ^~~~~~~
</span><span class="token_default"></span></code></pre>
<pre><code class="language-resinatorerror"><span class="token_diagnostic token_bold">test.rc:1:12:</span><span class="token_warning token_bold"> warning:</span><span class="token_diagnostic token_bold"> codepoint U+FFFF within a string literal would cause the entire file to be miscompiled by the Win32 RC compiler
</span><span class="token_default">1 RCDATA { "&#xFFFF;" }
</span><span class="token_selector">           ^~~
</span><span class="token_default"></span><span class="token_diagnostic token_bold">test.rc:1:12:</span><span class="token_note token_bold"> note:</span><span class="token_diagnostic token_bold"> the presence of this codepoint causes all non-ASCII codepoints to be byteswapped by the Win32 RC preprocessor
</span><span class="token_default"></span></code></pre>

</div>

<div class="bug-quirk-box">
<span class="bug-quirk-category">preprocessor bug/quirk</span>

### The sad state of the lonely forward slash

If a line consists of nothing but a `/` character, then the `/` is ignored entirely (note: the line can have any amount of whitespace preceding the `/`, but nothing after the `/`). The following example compiles just fine:

```rc
/
1 RCDATA {
  /
  /
}
/
```

and is effectively equivalent to

```rc
1 RCDATA {}
```

This seems to be a bug/quirk of the preprocessor of `rc.exe`; if we use `rc.exe /p` to only run the preprocessor, we see this output:

```rc

1 RCDATA {


}


```

It is very like that this is a bug/quirk in the code responsible for parsing and removing comments. In fact, it's pretty easy to understand how such a bug could come about if we think about a state machine that parses and removes comments. In such a state machine, once you see a `/` character, there are three relevant possibilities:
- It is not part of a comment, in which case it should be emitted
- It is the start of a line comment (`//`)
- It is the start of a multiline comment (`/*`)

So, for a parser that removes comments, it makes sense to hold off on emitting the `/` until we determine whether or not it's part of a comment. My guess is that the in-between state is not being handled fully correctly, and so instead of emitting the `/` when it is followed immediately by a line break, it is accidentally being treated as if it is part of a comment.

<p><aside class="note">

Fun fact: While writing this article, I realized that I [had a very similar bug in my implementation](https://github.com/squeek502/resinator/commit/369b4e0c1039431afe04820399076dc245dd5515).

</aside></p>

#### `resinator`'s behavior

`resinator` does not currently attempt to emulate the behavior of the Windows RC compiler, so `/` is treated as any other character would be and the file is parsed accordingly. In the case of the above example, it ends up erroring with:

```resinatorerror
test.rc:6:2: error: expected quoted string literal or unquoted literal; got '<eof>'
/
 ^
```

What `resinator` *should* do in this instance [is an open question](https://github.com/squeek502/resinator/issues/14).

</div>

## Conclusion

Well, that's all I've got. There's a few things I left out due to them being too insignificant, or because I have forgotten about some weird behavior I added support for at some point, or because I'm not (yet) aware of some bugs/quirks of the Windows RC compiler. If you got this far, thanks for reading. Like [`resinator`](https://github.com/squeek502/resinator) itself, this ended up taking a lot more effort than I initially anticipated.

If there's anything to take away from this article, I hope it'd be something about the usefulness of fuzzing (or adjacent techniques) in exposing obscure bugs/behaviors. If you have written software that lends itself to fuzz testing in any way, I highly encourage you to consider trying it out. On `resinator`'s end, there's still a lot left to explore in terms of fuzz testing. I'm not fully happy with my current approach, and there are aspects of `resinator` that I know are not being properly fuzz tested yet.

I've just [released an initial version of `resinator` as a standalone program](https://github.com/squeek502/resinator/releases) if you'd like to try it out. If you're a Zig user, see [this post](https://www.ryanliptak.com/blog/zig-is-a-windows-resource-compiler/) for details on how to use the version of `resinator` included in the Zig compiler. My next steps will be [adding support for converting `.res` files to  COFF object files](https://github.com/squeek502/resinator/issues/7) in order for Zig to be able to [use its self-hosted linker for Windows resources](https://github.com/ziglang/zig/issues/17751). As always, I'm expecting this COFF object file stuff to be pretty straightforward to implement, but the precedence is definitely not in my favor for that assumption holding.

<div>

<style scoped>
table, th, td {
  border: 1px solid #eee;
  border-collapse: collapse;
}
@media (prefers-color-scheme: dark) {
  table, th, td {
    border-color: #111;
  }
}
th, td {
  padding: 0.25rem 0.5rem;
}

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

.collapsing-list {
  column-count: 1;
}
@media only screen and (min-width: 700px) {
  .collapsing-list {
    column-count: 2;
  }
}
@media only screen and (min-width: 1024px) {
  .collapsing-list {
    column-count: 3;
  }
}


pre > code { white-space: inherit !important; }
pre code .inblock { position:relative; display:inline-block; }

.hexdump .infotip { cursor: help; }
.hexdump .o1o { outline: 1px dotted; }
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
.hexdump .o-clr4 { outline-color: rgba(0,170,0); }
.hexdump .bg-clr4 { background: rgba(0,170,0,.1); }
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