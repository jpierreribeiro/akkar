-- Distribution diagnostics only; never consulted on the request path.
local M = {}

function M.read(path)
  local file, err = io.open(path, "r")
  if not file then return nil, err end
  local values = {}
  for line in file:lines() do
    local key, value = line:match("^([A-Z][A-Z0-9_]*)=([^\r\n]+)$")
    if key then values[key] = value end
  end
  file:close()
  return values
end

function M.check(report, path)
  local ok, cq = pcall(require, "cqueues")
  if ok then
    report:ok("substrate", "cqueues identity", tostring(cq.COMMIT or "published rock; no commit") ..
              " from " .. (package.searchpath("cqueues", package.path) or "preloaded"))
  end
  if not path then return end
  local manifest, err = M.read(path)
  if not manifest then
    report:fail("substrate", "cannot read controlled manifest", tostring(err))
    return
  end
  if not ok or not manifest.CQUEUES_COMMIT or cq.COMMIT ~= manifest.CQUEUES_COMMIT then
    report:fail("substrate", "cqueues differs from controlled manifest",
                "rebuild with bin/bootstrap-runtime; do not overlay global rocks")
  end
  local abi = manifest.LUA_VERSION and manifest.LUA_VERSION:match("^(%d+%.%d+)")
  if _VERSION ~= "Lua " .. tostring(abi) then
    report:fail("substrate", "Lua differs from controlled manifest", _VERSION)
  end
  if manifest.OPENSSL_RUNTIME then
    local loaded, ssl = pcall(require, "openssl")
    if not loaded or tostring(ssl.version()) ~= manifest.OPENSSL_RUNTIME then
      report:fail("substrate", "OpenSSL changed since distribution build",
                  "rebuild and repeat the substrate tests")
    end
  end
end
return M
