--- Turning a socket errno into something an operator can read.
---
--- ## The line somebody reads at three in the morning
---
--- cqueues hands failures back as a bare integer, and every layer above
--- concatenates it into the message it reports. So the one line that matters
--- during an incident -- `akkar.limit`'s degradation warning, whose entire job
--- is to announce that the limits are not being enforced right now -- came out
--- as `detail="redis: 110"`, and an outbound HTTP failure came out as `32`.
--- 110 is ETIMEDOUT and 111 is ECONNREFUSED: "alive and not answering" and
--- "gone" are two different pages with two different responses, and a bare
--- number makes somebody look that up mid-incident.
---
--- ## Why the names are listed rather than discovered
---
--- Two obvious implementations are both wrong, and CI found them in order.
---
--- `errno[110]` -- the reverse lookup -- answers "ETIMEDOUT" on one cqueues
--- build and answers nothing on another. The fallback then renders the
--- platform's `strerror`, which on the CI machine is the unhelpful
--- `"Unknown error: 11"`: a worse line than the number it replaced.
---
--- Inverting the table with `pairs(errno)` fails the same way for a different
--- reason -- a cqueues that serves its constants through `__index` has nothing
--- to iterate, so the inverted table comes out empty.
---
--- What is portable is asking BY NAME: `errno.ETIMEDOUT` is 110 wherever the
--- header said so. Hence the list. It is the set an akkar adapter can actually
--- surface -- socket, connect, read, write -- and a number outside it still
--- reports itself, because the number is what a search of the code or of
--- `errno(3)` matches on.
local errno = require "cqueues.errno"

local M = {}

local NAMES = {
  "EACCES", "EADDRINUSE", "EADDRNOTAVAIL", "EAFNOSUPPORT", "EAGAIN", "EALREADY",
  "EBADF", "ECANCELED", "ECONNABORTED", "ECONNREFUSED", "ECONNRESET",
  "EDESTADDRREQ", "EFAULT", "EHOSTDOWN", "EHOSTUNREACH", "EINPROGRESS",
  "EINTR", "EINVAL", "EIO", "EISCONN", "ELOOP", "EMFILE", "EMSGSIZE",
  "ENAMETOOLONG", "ENETDOWN", "ENETRESET", "ENETUNREACH", "ENFILE", "ENOBUFS",
  "ENOENT", "ENOMEM", "ENOPROTOOPT", "ENOTCONN", "ENOTSOCK", "EOPNOTSUPP",
  "EPERM", "EPIPE", "EPROTO", "EPROTONOSUPPORT", "EPROTOTYPE", "ERANGE",
  "ESHUTDOWN", "ESPIPE", "ETIMEDOUT",
}

--- number -> "ETIMEDOUT", for the errnos above. Built once at load.
M.name_of = {}
for _, name in ipairs(NAMES) do
  local ok, value = pcall(function() return errno[name] end)
  if ok and type(value) == "number" and M.name_of[value] == nil then
    M.name_of[value] = name
  end
end

--- `110` -> `"ETIMEDOUT (Connection timed out)"`. Anything that is not a
--- number -- a message some layer already worded -- is returned untouched, so
--- this is safe to apply at any boundary without checking first.
---
--- The number is kept beside the name deliberately: it is what a search of
--- this codebase, of a log aggregator, or of `errno(3)` will match on.
function M.describe(why)
  if type(why) ~= "number" then return why end
  local name = M.name_of[why]
  local ok, text = pcall(errno.strerror, why)
  text = (ok and type(text) == "string") and text or nil
  if not name then return (text or "errno") .. " (" .. why .. ")" end
  return name .. " (" .. (text or why) .. ")"
end

return M
