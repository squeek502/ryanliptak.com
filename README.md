ryanliptak.com
==============

The source files for [ryanliptak.com](https://ryanliptak.com/).

Uses a modified version of the [abandoned Lua version of the Motyl static site generator](https://github.com/fcambus/motyl/tree/e23b601e57c3e2649ae386c2d40d86c0e6ea0fe4) (see [Changes to Motyl](#changes-to-motyl)).

## Building

You'll need to install the following Lua modules and make them available to Lua:
- [luafilesystem](https://github.com/keplerproject/luafilesystem)
- [lustache](https://github.com/Olivine-Labs/lustache)
- [yaml](https://luarocks.org/modules/gaspard/yaml)
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

## Changes to Motyl

The provided [motyl.lua](lua/motyl.lua) has been customized in the following ways:
- Swapped `lunamark` out for `discount`
- Swapped `lyaml` out for `yaml`
- Added support for `.html` posts/pages that don't get run through the markdown parser
- Added support for 'featured' posts. If a post's yaml has `featured: true`, then it will get added to the `site.featured` list
