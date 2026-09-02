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

--- The Linux numbers, as a floor.
---
--- CI proved the third trap after the first two were fixed: on the cqueues that
--- job builds, `errno.ETIMEDOUT` does not resolve EITHER -- neither direction of
--- the table is populated -- so asking by name produced the same
--- `Unknown error: 11 (110)` as asking by number. A module that answers nothing
--- cannot be the only source.
---
--- These are the values from `asm-generic/errno.h`, which is where the numbers
--- an akkar adapter sees on Linux come from, and they are ABI: 110 has been
--- ETIMEDOUT for as long as the platform has existed and cannot change without
--- breaking every compiled program on it. macOS numbers its higher errnos
--- differently (60 is its ETIMEDOUT), which is exactly why the module is asked
--- FIRST and this table is only the fallback -- on a cqueues that answers, the
--- platform's own numbering wins; on one that does not, Linux is the right guess
--- for a runtime that deploys on Linux.
local LINUX = {
  [1] = "EPERM", [2] = "ENOENT", [4] = "EINTR", [5] = "EIO", [9] = "EBADF",
  [11] = "EAGAIN", [12] = "ENOMEM", [13] = "EACCES", [14] = "EFAULT",
  [22] = "EINVAL", [23] = "ENFILE", [24] = "EMFILE", [32] = "EPIPE",
  [34] = "ERANGE", [40] = "ELOOP", [36] = "ENAMETOOLONG", [71] = "EPROTO",
  [88] = "ENOTSOCK", [89] = "EDESTADDRREQ", [90] = "EMSGSIZE",
  [91] = "EPROTOTYPE", [92] = "ENOPROTOOPT", [93] = "EPROTONOSUPPORT",
  [95] = "EOPNOTSUPP", [97] = "EAFNOSUPPORT", [98] = "EADDRINUSE",
  [99] = "EADDRNOTAVAIL", [100] = "ENETDOWN", [101] = "ENETUNREACH",
  [102] = "ENETRESET", [103] = "ECONNABORTED", [104] = "ECONNRESET",
  [105] = "ENOBUFS", [106] = "EISCONN", [107] = "ENOTCONN",
  [108] = "ESHUTDOWN", [110] = "ETIMEDOUT", [111] = "ECONNREFUSED",
  [112] = "EHOSTDOWN", [113] = "EHOSTUNREACH", [114] = "EALREADY",
  [115] = "EINPROGRESS", [125] = "ECANCELED",
}

--- number -> "ETIMEDOUT". Built once at load: the module's own constants where
--- it has them, the Linux floor where it has not.
M.name_of = {}
for _, name in ipairs(NAMES) do
  local ok, value = pcall(function() return errno[name] end)
  if ok and type(value) == "number" and M.name_of[value] == nil then
    M.name_of[value] = name
  end
end
for value, name in pairs(LINUX) do
  if M.name_of[value] == nil then M.name_of[value] = name end
end

--- `110` -> `"ETIMEDOUT (Connection timed out)"`. Anything that is not a
--- number -- a message some layer already worded -- is returned untouched, so
--- this is safe to apply at any boundary without checking first.
---
--- The number is kept beside the name deliberately: it is what a search of
--- this codebase, of a log aggregator, or of `errno(3)` will match on.
--- THE NUMBER IS ALWAYS THERE, and that is not decoration.
---
--- An earlier shape rendered `ETIMEDOUT (Connection timed out)` and dropped the
--- number, on the theory that the prose said the same thing. It does not: the
--- number is what a grep of this codebase, of an aggregator, or of `errno(3)`
--- matches on, and the prose is the one part that varies by platform. CI proved
--- it -- where `strerror` answers its useless "Unknown error: 10", that shape
--- became `ETIMEDOUT (Unknown error: 10)`, carrying a WRONG number and losing
--- the right one. So the number is its own field, and the platform's prose is
--- appended only when it is worth reading.
function M.describe(why)
  if type(why) ~= "number" then return why end
  local name = M.name_of[why]
  local ok, text = pcall(errno.strerror, why)
  text = (ok and type(text) == "string") and text or nil
  -- A `strerror` that just spells the number back at us adds nothing, and on
  -- the CI machine it spells a DIFFERENT number. Drop it rather than print it.
  if text and text:lower():find("unknown error", 1, true) then text = nil end

  if name and text then return ("%s %d (%s)"):format(name, why, text) end
  if name             then return ("%s %d"):format(name, why) end
  if text             then return ("%s (%d)"):format(text, why) end
  return ("errno %d"):format(why)
end

return M
