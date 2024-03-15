package.path = "./lua/?.lua;" .. package.path

local fsutil = require('fsutil')
local lfs = require('lfs')

local function motyl()
  -- lustache saves state, need to force a reload
  package.loaded["lustache"] = nil
  -- force a re-load
  package.loaded["motyl"] = nil
  -- force a re-load
  package.loaded["cmarkutil"] = nil
  require('motyl')
end

print("Running motyl")
motyl()

print("Copying assets and static files")
fsutil.copy("themes/fonts", "public/fonts")
fsutil.copy("themes/scripts", "public/scripts")
print("Concatting stylesheets")
local css = {}
for file in lfs.dir("themes/styles") do
  if file ~= "." and file ~= ".." then
    table.insert(css, "themes/styles/" .. file)
  end
end
table.sort(css)
for i,filename in ipairs(css) do
  print("  " .. filename)
  css[i] = fsutil.read(filename)
end
fsutil.mkdir("public/styles")
fsutil.write("public/styles/style.css", table.concat(css, "\n"))
fsutil.copy("static", "public")

print("Done")
