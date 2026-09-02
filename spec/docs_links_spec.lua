-- The Portuguese documentation is a parallel public surface.  A relative
-- link that falls back into the English tree, or an anchor left behind after
-- translating a heading, strands the reader even though both pages exist.

local ROOTS = { "guide", "sql", "recipes", "reference", "why" }

local function read(path)
  local file = assert(io.open(path, "r"))
  local text = file:read "a"
  file:close()
  return text
end

local function translated_files()
  local found = { "README.pt-BR.md" }
  for _, root in ipairs(ROOTS) do
    local dir = "docs/pt-BR/" .. root
    local pipe = assert(io.popen(("find %s -type f -name '*.md' 2>/dev/null"):format(dir)))
    for path in pipe:lines() do found[#found + 1] = path end
    pipe:close()
  end
  table.sort(found)
  return found
end

local function dirname(path)
  return path:match "^(.*)/[^/]+$" or "."
end

local function normalize(path)
  local parts = {}
  for part in path:gmatch "[^/]+" do
    if part == ".." then
      if #parts > 0 then table.remove(parts) end
    elseif part ~= "." and part ~= "" then
      parts[#parts + 1] = part
    end
  end
  return table.concat(parts, "/")
end

local function exists(path)
  local ok = os.rename(path, path)
  if ok then return true end
  local file = io.open(path, "r")
  if file then file:close(); return true end
  return false
end

local UPPER = {
  ["Á"]="á", ["À"]="à", ["Â"]="â", ["Ã"]="ã", ["Ä"]="ä",
  ["É"]="é", ["Ê"]="ê", ["Í"]="í", ["Ó"]="ó", ["Ô"]="ô",
  ["Õ"]="õ", ["Ö"]="ö", ["Ú"]="ú", ["Ü"]="ü", ["Ç"]="ç",
}

local function slug(text)
  text = text:gsub("%[([^%]]+)%]%([^%)]+%)", "%1")
             :gsub("<[^>]+>", "")
             :gsub("[`*~]", "")
             :lower()
  for upper, lower in pairs(UPPER) do text = text:gsub(upper, lower) end
  text = text:gsub("[!\"#$%%&'()%*+,./:;<=>?@%[%]%^\\{|}]", "")
             :gsub("%s", "-")
  return text
end

local heading_cache = {}
local function headings(path)
  if heading_cache[path] then return heading_cache[path] end
  local ids, seen = {}, {}
  for line in (read(path) .. "\n"):gmatch "([^\n]*)\n" do
    local title = line:match "^#+%s+(.+)%s*$"
    if title then
      local base = slug(title)
      local count = seen[base] or 0
      seen[base] = count + 1
      ids[count == 0 and base or (base .. "-" .. count)] = true
    end
    local explicit = line:match '<a%s+id="([^"]+)"'
    if explicit then ids[explicit] = true end
  end
  heading_cache[path] = ids
  return ids
end

describe("links in the Brazilian Portuguese documentation", function()
  for _, source in ipairs(translated_files()) do
    if source ~= "README.pt-BR.md" then
      it("identifies and links back from " .. source, function()
        local text = read(source)
        local original = source:gsub("^docs/pt%-BR/", "../../")
        assert.is_truthy(text:match("^#%s+[^\n]+"),
          source .. " must start with a level-one heading")
        assert.is_truthy(text:find(
          "[Original em inglês](" .. original .. ")", 1, true),
          source .. " must link to its English original")
      end)
    end

    it("resolve from " .. source, function()
      local text = read(source)
      -- BOUND TO A LOCAL, NOT REASSIGNED. Lua 5.5 makes a generic-for control
      -- variable const, so trimming in place is `attempt to assign to const
      -- variable 'destination'` -- a whole spec file red under 5.5 and green
      -- under 5.4, which is the one difference the 5.5 job exists to catch.
      for raw in text:gmatch "!?%[[^%]]-%]%(([^%)]+)%)" do
        local destination = raw:match "^%s*<?([^%s>]+)>?" or raw
        if not destination:match "^%a[%w+.-]*:"
           and not destination:match "^//" then
          local path, anchor = destination:match "^([^#]*)#?(.*)$"
          local target = path == "" and source
                     or normalize(dirname(source) .. "/" .. path)
          assert.is_true(exists(target),
            source .. " links to a missing path: " .. destination)
          if anchor ~= "" and target:match "%.md$" then
            assert.is_true(headings(target)[anchor] == true,
              source .. " links to a missing anchor: " .. destination)
          end
        end
      end
    end)
  end
end)
