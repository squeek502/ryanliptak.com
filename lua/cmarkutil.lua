local cmark = require "cmark"
local fsutil = require "fsutil"
local syntaxhighlight = require "syntaxhighlight"

local function genId(text)
  return text:gsub("%W", "-"):gsub("%-+", "-"):gsub("^%-+", ""):gsub("%-+$", ""):lower()
end

local function consolidateText(node)
  local chunks = {}
  for cur, entering, node_type in cmark.walk(node) do
    if entering then
      local chunk = cmark.node_get_literal(cur)
      if chunk then
        table.insert(chunks, chunk)
      end
    end
  end
  if #chunks == 0 then return nil end
  return table.concat(chunks)
end

local function highlight(contents, syntax)
  if syntax == "c" then syntax = "ansi_c" end
  return syntaxhighlight.highlight_to_html(syntax, contents, {
    bare=true,
    class_prefix="token_",
  })
end

local function process(doc)
  local seen_header_ids = {}
  for cur, entering, node_type in cmark.walk(doc) do
    if entering and node_type == cmark.NODE_CODE_BLOCK then
      local info = cmark.node_get_fence_info(cur)
      info = info and info:gsub("^language%-", "")
      local syntax, pre_attrs = info:match("^([^%s]*)(.*)")
      if syntax and syntax ~= "" then
        local contents = cmark.node_get_literal(cur)
        local highlighted, err = highlight(contents, syntax)

        if highlighted then
          local t = cmark.node_new(cmark.NODE_HTML_BLOCK)
          local markup = string.format("<pre%s><code class=\"language-%s\">%s</code></pre>", pre_attrs, syntax, highlighted)
          cmark.node_set_literal(t, markup)
          cmark.node_replace(cur, t)
          cmark.node_free(cur)
        else
          print("failed to highlight language "..syntax..":\n"..err)
        end
      end
    end
    if entering and node_type == cmark.NODE_HEADING then
      local text = consolidateText(cur)
      if text then
        local generated_id = genId(text)
        local id = generated_id
        local i = 1
        while seen_header_ids[id] do
          i = i + 1
          id = generated_id .. "-" .. i
        end
        local t = cmark.node_new(cmark.NODE_HTML_INLINE)
        cmark.node_set_literal(t, string.format("<a id=\"%s\" href=\"#%s\" class=\"heading-link\">🔗</a>", id, id))
        cmark.node_append_child(cur, t)
        seen_header_ids[id] = true
      end
    end
  end
end

return {
  process = process
}
