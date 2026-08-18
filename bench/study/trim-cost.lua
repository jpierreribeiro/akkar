-- The trim, five ways, with `%s` semantics preserved exactly.
--
-- `^%s*(.-)%s*$` is the idiom in seven places in akkar. It measured 54-63
-- ns/byte where a greedy equivalent measured 4.8-17 -- the same shape as the
-- header-parse defect, because it is the same cause: a lazy `(.-)` with an
-- anchored tail re-tries from every position.
--
-- `%s` is [ \t\n\v\f\r], NOT just space and tab. A candidate that trims fewer
-- characters is not faster, it is wrong.
local SIZES = { 20, 100, 1000, 10000 }

local WS = {}
for _, b in ipairs { 32, 9, 10, 11, 12, 13 } do WS[b] = true end

local C = {}

C.current = function(s) return s:match "^%s*(.-)%s*$" end

C.two_gsub = function(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

C.find_pair = function(s)
  local first = s:find "%S"
  if not first then return "" end
  local last = s:find "%s*$"
  return s:sub(first, last - 1)
end

C.greedy_walk = function(s)
  local v = s:match "^%s*(.*)$"
  local last = #v
  while last > 0 and WS[v:byte(last)] do last = last - 1 end
  return last == #v and v or v:sub(1, last)
end

C.both_walk = function(s)
  local n = #s
  local first = 1
  while first <= n and WS[s:byte(first)] do first = first + 1 end
  if first > n then return "" end
  local last = n
  while WS[s:byte(last)] do last = last - 1 end
  return (first == 1 and last == n) and s or s:sub(first, last)
end

-- The one worth shipping: an early exit for a string that needs no trimming
-- at all, which is most of them, and a walk bounded by the whitespace rather
-- than by the length for the rest.
C.fast = function(s)
  local n = #s
  if n == 0 then return s end
  local head, tail = WS[s:byte(1)], WS[s:byte(n)]
  if not head and not tail then return s end        -- nothing to do
  local first = 1
  while first <= n and WS[s:byte(first)] do first = first + 1 end
  if first > n then return "" end
  local last = n
  while WS[s:byte(last)] do last = last - 1 end
  return s:sub(first, last)
end

local ORDER = { "current", "two_gsub", "find_pair", "greedy_walk", "both_walk", "fast" }

-- CORRECTNESS FIRST, over every shape that distinguishes them.
local CASES = {
  "", " ", "   ", "\t", "\n", "\r\n", " \t\n\v\f\r ",
  "a", " a", "a ", " a ", "  a  ",
  "a b", "  a b  ", "a\tb", " a\nb ",
  "\t\n hello world \r\n", "no-whitespace-at-all",
  " " .. ("x"):rep(50) .. " ",
  ("x"):rep(50),
  "  \t  ",
  "x  y",
}
local bad = 0
for _, s in ipairs(CASES) do
  local want = C.current(s)
  for _, name in ipairs(ORDER) do
    local got = C[name](s)
    if got ~= want then
      bad = bad + 1
      print(("DISAGREE %-14s %q -> %q, want %q"):format(name, s, tostring(got), tostring(want)))
    end
  end
end

-- And random, because the list only covers what was thought of.
math.randomseed(20260818)
local ALPHA = { " ", "\t", "\n", "\v", "\f", "\r", "a", "b", "Z", "0", "-", "." }
for _ = 1, 200000 do
  local n = math.random(0, 20)
  local p = {}
  for i = 1, n do p[i] = ALPHA[math.random(#ALPHA)] end
  local s = table.concat(p)
  local want = C.current(s)
  for _, name in ipairs(ORDER) do
    if C[name](s) ~= want then
      bad = bad + 1
      if bad < 8 then print(("DISAGREE(random) %-14s %q"):format(name, s)) end
    end
  end
end
print(bad == 0 and "all candidates agree on every case" or (bad .. " disagreements"))

print()
print(("%-14s %10s %10s %10s %10s"):format("candidate", unpack and "" or "", "", "", ""))
io.write(("%-14s"):format("size"))
for _, n in ipairs(SIZES) do io.write(("%10d"):format(n)) end
print("   (ns/call)")
for _, name in ipairs(ORDER) do
  io.write(("%-14s"):format(name))
  for _, n in ipairs(SIZES) do
    local s = "  \t" .. ("x"):rep(n) .. "\t  "
    local iters = math.max(2000, math.floor(4e7 / n))
    C[name](s)
    local t0 = os.clock()
    for _ = 1, iters do C[name](s) end
    io.write(("%10.0f"):format((os.clock() - t0) / iters * 1e9))
  end
  print()
end
