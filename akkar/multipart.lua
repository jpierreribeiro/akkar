--[[
akkar.multipart — parses `multipart/form-data`, the only way a browser sends
a file.

**A limitation to state before the code, not after it:** the body is buffered
in memory, bounded by `body_limit`.  A 200 MB upload needs `body_limit` set to
200 MB, and then 200 MB of RSS per concurrent upload.  Streaming parts to disk
as they arrive is a different feature with a different shape, and pretending
otherwise would be the framework lying about what it does.

For form fields and images -- the common case -- buffering is the right call
and the code stays small enough to read.

A parsed body looks like an ordinary table, so validation and handlers do not
learn a new shape:

    req.body.title                -- a plain field, a string
    req.body.avatar.filename      -- a file part
    req.body.avatar.content_type
    req.body.avatar.data
]]

local M = {}

--- Pulls the boundary out of a Content-Type header.
--- RFC 2046 allows it to be quoted, and browsers differ on whether it is.
function M.boundary(content_type)
  if not content_type then return nil end
  local quoted = content_type:match 'boundary="([^"]+)"'
  if quoted then return quoted end
  return content_type:match "boundary=([^;%s]+)"
end

-- Content-Disposition: form-data; name="avatar"; filename="cat.png"
local function disposition(header)
  local name = header:match 'name="([^"]*)"' or header:match "name=([^;%s]+)"
  local filename = header:match 'filename="([^"]*)"' or header:match "filename=([^;%s]+)"
  return name, filename
end

local function parse_headers(block)
  local out = {}
  for line in block:gmatch "[^\r\n]+" do
    local key, value = line:match "^([^:]+):%s*(.*)$"
    if key then out[key:lower()] = value end
  end
  return out
end

--- Parses a multipart body.
--- Returns (fields, nil) or (nil, message).
function M.parse(body, boundary)
  if not boundary or boundary == "" then
    return nil, "multipart body has no boundary"
  end

  local delimiter = "--" .. boundary
  local fields = {}
  local found = false

  -- Walk delimiter to delimiter.  `plain` find, because a boundary is chosen
  -- by the client and may contain characters Lua patterns treat as magic.
  local position = body:find(delimiter, 1, true)
  if not position then return nil, "multipart body has no opening boundary" end
  position = position + #delimiter

  while true do
    -- `--` right after the delimiter marks the end of the body.
    if body:sub(position, position + 1) == "--" then break end

    -- Skip the CRLF that follows the delimiter.
    local start = body:find("\r\n", position, true)
    if not start then break end
    start = start + 2

    local header_end = body:find("\r\n\r\n", start, true)
    if not header_end then return nil, "multipart part has no header block" end

    local headers = parse_headers(body:sub(start, header_end - 1))
    local content_start = header_end + 4

    local next_delimiter = body:find(delimiter, content_start, true)
    if not next_delimiter then return nil, "multipart part is not terminated" end

    -- The CRLF before the delimiter belongs to the framing, not the content.
    local content = body:sub(content_start, next_delimiter - 1):gsub("\r\n$", "")

    local name, filename = disposition(headers["content-disposition"] or "")
    if name then
      found = true
      if filename then
        fields[name] = {
          filename = filename,
          content_type = headers["content-type"] or "application/octet-stream",
          data = content,
          size = #content,
        }
      else
        fields[name] = content
      end
    end

    position = next_delimiter + #delimiter
  end

  if not found then return nil, "multipart body contained no named parts" end
  return fields
end

return M
