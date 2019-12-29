To learn more about both [Lua](https://lua.org) and [Zig](https://ziglang.org), I've started [writing a Lua 5.1 implementation in Zig](https://github.com/squeek502/zua) beginning with the lexer (i.e. separating a source file into tokens). Lua's lexer, however, does not have any test cases and the lexing API is not easily separated from the Lua parser. So, when writing test cases for a new, compatible implementation, it's hard to be certain you've covered all the edge cases. This is especially true for Lua, since any 8-bit value is technically a valid character in `.lua` source files (embedded `NUL`, other control characters, you name it).

After writing some obvious test cases based on my reading of the Lua lexer's source code, I decided to try using fuzz testing to find any edge cases that I wasn't accounting for, and ended up with both some surprising and not-so-surprising results.

## The setup

[`libFuzzer`](https://llvm.org/docs/LibFuzzer.html) uses various techniques to generate a random set of inputs that maximizes the code coverage of the fuzz-tested code. After fuzzing for a while, I then took those generated inputs and ran them back through the Lua lexer, generating corresponding output files that consist of a list of the lexed tokens and the resulting error, if any. For example:

- **Input:** `local hello = "world"` &rarr; **Output:** `local <name> = <string> <eof>`
- **Input:** `local hello = "world` &rarr; **Output:** `local <name> =` `[string "fuzz"]:1: unfinished string near '"world'`

With these pairs of input/output files, I can simply make my lexer implementation [generate similar output](https://github.com/squeek502/zua/blob/4f6c1f5c3c54d71dd08bf19573f51054f672b566/src/lex.zig#L143-L191), and then [compare that with Lua's for each input file](https://github.com/squeek502/zua/blob/4f6c1f5c3c54d71dd08bf19573f51054f672b566/test/fuzz_lex.zig#L74). Any discrepancies (different tokens, different errors, errors at different locations, etc) is then an opportunity to figure out what's happening, write a minimal reproduction test case, and fix it. Once all of the discrepancies are ironed out, we can be reasonably sure that our implementation is compatible with the reference implementation.

See [squeek502/fuzzing-lua](https://github.com/squeek502/fuzzing-lua) for the full Lua lexer fuzzing implementation.

## The not-so-surprising results

- [I wasn't treating vertical tabs and form feed characters as whitespace](https://github.com/squeek502/zua/commit/93c596aba4582d54deced8deeabc9a6720bbfde4#diff-d43adccfb2a05ccb10a8d0568315e9edL249-R283)
- [I had a typo in the `elseif` keyword definition](https://github.com/squeek502/zua/commit/a54fca85b4c21e92dbcbefc83eeba0d5995a74f0)
- [I wasn't handling escaped newline characters correctly](https://github.com/squeek502/zua/commit/93c596aba4582d54deced8deeabc9a6720bbfde4#diff-d43adccfb2a05ccb10a8d0568315e9edL313) (and [again](https://github.com/squeek502/zua/commit/1c3165b6795e604acd4c01c44bea428c2d07d2ae))
- [I was wrong about when 'invalid long string delimiter' errors occurred](https://github.com/squeek502/zua/commit/93c596aba4582d54deced8deeabc9a6720bbfde4#diff-d43adccfb2a05ccb10a8d0568315e9edL363-R423)
- [I didn't properly port number lexing (Lua 5.1's lexer erroneously consumes underscores when lexing numbers)](https://github.com/squeek502/zua/commit/384d66dc054de2540735327d37df8e1adbe8a614)

## The surprising results

The above changes could have been caught without fuzzing (given enough scrutiny/time), but there was one additional edge case that likely would not have been caught without fuzz testing due to how rarely it affects normal source code. It turns out that the Lua 5.1 lexer has a bug in its `check_next` function. That is, when it is looking ahead at the next character and checking that it is within some set of expected characters, it accidentally accepts `'\0'` / `NUL` characters as well (due to its unchecked use of [`strchr`](http://man7.org/linux/man-pages/man3/strchr.3.html) which has been fixed for Lua 5.2+). Luckily, `check_next` is only used in a few places in the Lua 5.1 lexer:

- When checking for the second/third `.` characters in concat (`..`) and ellipsis (`...`) tokens
- When checking for `e`/`E` exponent markers in number tokens
- When checking for `-`/`+` to denote exponent signed-ness in number tokens

This means that Lua's lexer will tokenize the following such that (where <code><span class="nul-char">0</span></code> is the `NUL` character):

- <code>.<span class="nul-char">0</span></code> will lex to `..`
- <code>..<span class="nul-char">0</span></code> will lex to `...`
- <code>1.5<span class="nul-char">0</span>-1</code> will lex to `1.5` (internally, the lexer's state will 'think' the token is `1.5e-1`, but the finished token's string will be treated as `NUL`-terminated when converting from string to double).

This behavior can be verified by doing the following:

```language-shellsession
$ printf 'print("con".\0"cat")' > concat.lua
$ lua51 concat.lua
concat
$ lua53 concat.lua
lua53: concat.lua:1: ')' expected near '.'
```

Because `.lua` source files rarely actually have embedded `NUL`s--especially outside of string literals--very few people have likely ever run into this particular edge case, but if absolute compatibility with a reference implementation is a goal, then such edge cases have to be taken into account. That's not a goal for my project, but it's still illustrative of the depth of the test cases that fuzzing can bubble up, and it has allowed me to make `check_next`-bug compatibility [an option in my implementation](https://github.com/squeek502/zua/blob/128b308feca8d1f2bb91861a95cbca3bf3a8f9fe/src/lex.zig#L26-L40).

## Links

- [Full set of changes/fixes made due to fuzzing](https://github.com/squeek502/zua/compare/53eb2ae3c2cd0882f5468d02225e0fd29b5b673a...0795892fd02e55b5e413ad01f47898c961261010)
- [Code for fuzzing the Lua lexer](https://github.com/squeek502/fuzzing-lua)
- [My Lua 5.1 implementation in Zig](https://github.com/squeek502/zua)

<div><style scoped>
.nul-char {
	/*background-color: #aa3333;
	color: white;*/
	color: #666666;
	border: 1px dotted black;
	padding: 1px 2px;
	margin: 0 2px;
}
</style></div>