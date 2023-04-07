ryanliptak.com
==============

The source files for [ryanliptak.com](https://ryanliptak.com/).

Uses a custom version of the [Motyl static site generator (the abandoned Lua version)](https://github.com/fcambus/motyl/tree/e23b601e57c3e2649ae386c2d40d86c0e6ea0fe4).

## Building

You'll need to install the following Lua modules and make them available to Lua:
- [luafilesystem](https://github.com/keplerproject/luafilesystem)
- [lustache](https://github.com/Olivine-Labs/lustache)
- [discount](https://github.com/craigbarnes/lua-discount) (if you're on Windows, you can compile it [from here](https://github.com/squeek502/lua-discount))
- (optionally) [sleep](https://github.com/squeek502/sleep) only if you are going to run watch.lua

Once all the dependencies are installed, running:

```
lua build.lua
```

will build everything and put it in the `public/` directory.

## Development

For testing, you can use [one of these](https://gist.github.com/willurd/5720255) to serve the `public/` directory.

To automatically rebuild whenever a file is changed, run:

```
lua watch.lua
```

(you'll need to have the `sleep` module installed, see above)
