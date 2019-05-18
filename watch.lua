package.path = "./lua/?.lua;" .. package.path

local lfs = require('lfs')
local sleep = require('sleep')
local fsutil = require('fsutil')

local CHECK_INTERVAL = 500

local function build()
  local ok, err = xpcall(function ()
    dofile('build.lua')
  end, debug.traceback)
  if not ok then
    print(err)
  end
end

local watch = {
  "motyl.conf",
  "build.lua",
  "pages",
  "posts",
  "lua",
  "static",
  "themes",
}

local function getstate(path, state)
  if fsutil.isdir(path) then
    local numfiles = 0
    for file in lfs.dir(path) do
      if file ~= "." and file ~= ".." then
        getstate(fsutil.pathjoin(path, file), state)
        numfiles = numfiles + 1
      end
    end
    local normpath = fsutil.pathnorm(path)
    state[normpath] = numfiles
  elseif fsutil.isfile(path) then
    local modified = lfs.attributes(path, "modification")
    state[path] = modified
  end
end

local function getwatchstate()
  local state = {}
  for _, path in ipairs(watch) do
    getstate(path, state)
  end
  return state
end

local function keycount(tbl)
  local c = 0
  for _ in pairs(tbl) do
    c = c + 1
  end
  return c
end

local function comparestate(a, b)
  for path, v in pairs(a) do
    if v ~= b[path] then
      return true
    end
  end
  if keycount(a) ~= keycount(b) then
    return true
  end
  return false
end

build()

local last = getwatchstate()
while true do
  local cur = getwatchstate()
  if comparestate(last, cur) then
    print("Something changed, rebuilding")
    build()
  end
  sleep(CHECK_INTERVAL)
  last = cur
end
