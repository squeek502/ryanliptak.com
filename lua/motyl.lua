#!/usr/bin/env lua
--[[
###############################################################################
#                                                                             #
# Motyl                                                                       #
# Copyright (c) 2016-2018, Frederic Cambus                                    #
# https://github.com/fcambus/motyl                                            #
#                                                                             #
# Created: 2016-02-16                                                         #
# Last Updated: 2018-01-08                                                    #
#                                                                             #
# Motyl is released under the BSD 2-Clause license.                           #
# See LICENSE file for details.                                               #
#                                                                             #
###############################################################################
]]--

local lfs = require "lfs"
local yaml = require "yaml"
-- don't load dates as numbers
yaml.configure("load_numeric_scalars", false)
--local lunamark = require "lunamark"
local discount = require "discount"
local lustache = require "lustache"

-- Read data from file
local function readFile(path)
	local file = assert(io.open(path, "rb"))

	local data = file:read "*all"
	file:close()

	return data
end

-- Write data to file
local function writeFile(path, data)
	local file = assert(io.open(path, "wb"))

	file:write(data)
	file:close()
end

-- Load YAML from file
local function loadYAML(path)
	return yaml.load(readFile(path))
end

-- Load and process Markdown file
local function loadMD(path)
	--local writer = lunamark.writer.html.new()
	--local parse = lunamark.reader.markdown.new(writer, { fenced_code_blocks = true })
	return assert(discount.compile(readFile(path), "fencedcode")).body
end

-- Render a mustache template
local function renderTemplate(template, data, templates)
	return lustache:render(template, data, templates)
end

-- Sorting function to sort posts by date
local function sortDates(a,b)
	return a.date > b.date
end

-- Display status message
local function status(message)
	print("[" .. os.date("%X") .. "] " .. message)
end

-- Loading configuration
local data = {}
data.version = "Motyl 1.00"
data.updated = os.date("%Y-%m-%dT%XZ")
data.site = loadYAML("motyl.conf")
data.site.feed = {}
data.site.posts = {}
data.site.categories = {}
data.site.featured = {}

-- Loading templates
local templates = {
	categories = readFile("themes/templates/categories.mustache"),
	header = readFile("themes/templates/header.mustache"),
	atom = readFile("themes/templates/atom.mustache"),
	pages = readFile("themes/templates/page.mustache"),
	posts = readFile("themes/templates/post.mustache"),
	footer = readFile("themes/templates/footer.mustache")
}

local function render(directory)
	for file in lfs.dir(directory) do
		if file ~= "." and file ~= ".." then
			local extension = file:match "[^.]+$"

			if extension == "md" or extension == "html" then
				local path = file:match "(.*)%.[^.]+$"
				data.page = loadYAML(directory .. "/" .. path .. ".yaml")
				local html = extension == "md" and loadMD(directory .. "/" .. file) or readFile(directory .. "/" .. file)
				data.page.content = lustache:render(html, data)
				if data.page.url == nil then
					data.page.url = path .. "/"
				end

				status("Rendering " .. data.page.url)

				if directory == "posts" then
					local year, month, day, hour, min = data.page.date:match("(%d+)%-(%d+)%-(%d+) (%d+)%:(%d+)")
					data.page.datetime = os.date("%Y-%m-%dT%XZ", os.time{year=year, month=month, day=day, hour=hour, min=min})

					table.insert(data.site.posts, data.page)

					data.page.categoryDisplay = {}

					-- Populate category table
					for _, category in ipairs(data.page.categories) do
						if not data.site.categories[category] then
							data.site.categories[category] = {}
						end

						table.insert(data.site.categories[category], data.page)
						table.insert(data.page.categoryDisplay, { category = category, url = data.site.categoryMap[category]})
					end

					if data.page.featured then
						table.insert(data.site.featured, data.page)
					end
				end

				lfs.mkdir("public/" .. data.page.url)
				writeFile("public/" .. data.page.url .. "index.html", renderTemplate(templates[directory], data, templates))

				data.page = {}
			end
		end
	end
end

-- Render posts
lfs.mkdir("public")
render("posts")

-- Sort post archives
table.sort(data.site.posts, sortDates)

-- Renger pages
render("pages")

-- Feed
for loop=1, data.site.feedItems do
	data.site.feed[loop] = data.site.posts[loop]
end

writeFile("public/atom.xml", renderTemplate(templates.atom, data, templates))
status("Rendering atom.xml")
data.page = {}

-- Categories
lfs.mkdir("public/categories")

for category in pairs(data.site.categories) do
	local categoryURL = data.site.categoryMap[category] .. "/"

	table.sort(data.site.categories[category], sortDates)

	data.page.title = category
	data.page.url = "categories/" .. categoryURL
	data.site.posts = data.site.categories[category]

	lfs.mkdir("public/categories/" .. categoryURL)
	writeFile("public/categories/" .. categoryURL .. "index.html", renderTemplate(templates.categories, data, templates))
	status("Rendering " .. categoryURL)
end
