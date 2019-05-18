--[[

Naive implementations of various filesystem functions
Will likely break on any non-trivial inputs

]]--

local lfs = require('lfs')

local function read(path)
  local file = assert(io.open(path, "rb"))
  local data = file:read("*all")
  file:close()
  return data
end

local function write(path, data)
  local file = assert(io.open(path, "wb"))
  file:write(data)
  file:close()
end

-- strip any trailing slashes
local function pathnorm(path)
  local norm = path:gsub("([^\\/])[\\/]+$", "%1")
  return norm
end

local function pathjoin(...)
  local paths = {}
  for _, path in pairs({...}) do
    table.insert(paths, pathnorm(path))
  end
  return table.concat(paths, "/")
end

local function isdir(path)
  return lfs.attributes(path, "mode") == "directory"
end

local function isfile(path)
  return lfs.attributes(path, "mode") == "file"
end

local function exists(path)
  return lfs.attributes(path, "mode") ~= nil
end

local function dirname(path)
  return pathnorm(path):match("(.*)/.*")
end

local function mkdir(path)
  if isdir(path) then return true end
  local parent = dirname(path)
  if parent and not isdir(parent) then
    local ok, err = mkdir(parent)
    if not ok then return ok, err end
  end
  return lfs.mkdir(path)
end

local function copy(src, dest)
  if isdir(src) then
    assert(not isfile(dest), string.format("attempt to copy directory to existing file ('%s' => '%s')", src, dest))
    for file in lfs.dir(src) do
      if file ~= "." and file ~= ".." then
        copy(pathjoin(src, file), pathjoin(dest, file))
      end
    end
    return true
  elseif isfile(src) then
    assert(mkdir(dirname(dest)))
    local contents = read(src)
    write(dest, contents)
    return true
  end
  return nil, string.format("attempt to copy from a non-existent path ('%s')", src)
end

return {
  copy = copy,
  pathjoin = pathjoin,
  pathnorm = pathnorm,
  isdir = isdir,
  isfile = isfile,
  exists = exists,
  mkdir = mkdir,
  dirname = dirname,
  read = read,
  write = write,
}
