-- Exactly what parsing a request costs in CPU, measured in isolation.
--
-- The end-to-end ablation could not see it: doubling the parse moved the
-- reading by -21, -0.4, +10.7 and -3.5 us against a noise band of about
-- 15 us. That is itself an answer -- parsing is under 5% -- but it is a bound
-- rather than a number, and the decision about a C tokeniser deserves the
-- number.
--
-- So this measures the actual patterns from `h1_connection.lua` against the
-- actual lines a request carries, at a count where the clock is reliable, and
-- multiplies by the calls per request.
local N = 2000000

local function per_call(label, fn)
  fn(); fn()                                  -- warm
  local t0 = os.clock()
  for _ = 1, N do fn() end
  local dt = os.clock() - t0
  local ns = dt / N * 1e9
  print(("%-46s %7.3f s  %8.1f ns/call"):format(label, dt, ns))
  return ns
end

-- The request line, exactly as `read_request_line` parses it.
local REQUEST_LINE = "GET /users/42?limit=10 HTTP/1.1\r\n"
local rl = per_call("request line: match", function()
  return REQUEST_LINE:match "^(%w+) (%S+) HTTP/(1%.[01])\r\n$"
end)

-- A header line, exactly as `read_header` parses it. Two lengths, because the
-- short one is interned and the long one is not, and real traffic has both.
local SHORT = "host: example.com"
local LONG  = "user-agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " ..
              "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

-- THE PATTERN THE CODE ACTUALLY USES, WHICH IS NOT WHAT THIS FILE MEASURED.
--
-- It measured `^([^%s:]+):[ \t]*(.-)[ \t]*$` -- the form `h1_connection.lua`
-- carried until 18 August 2026. A lazy `(.-)` with an anchored tail makes the
-- cost track the string's LENGTH rather than its work, and the 118-byte header
-- read 6,698 ns/call because of it.
--
-- That pattern is gone. `read_header` now matches `(.*)$` and walks back over
-- trailing spaces and tabs in bytes, which took the same header from 6,693 to
-- 1,436 ns -- 4.7x. Measuring the old form here priced a cost that no longer
-- exists, and it did so in the file whose whole purpose is deciding whether to
-- write a C tokeniser. It would have argued for one on 46.6% of CPU that had
-- already been removed in Lua.
--
-- Both halves are timed, because the trailing walk is part of the price.
local function read_header_as_shipped(line)
  local key, val = line:match "^([^%s:]+):[ \t]*(.*)$"
  if key then
    local last = #val
    while last > 0 do
      local c = val:byte(last)
      if c ~= 32 and c ~= 9 then break end
      last = last - 1
    end
    if last ~= #val then val = val:sub(1, last) end
  end
  return key, val
end

local hs = per_call("header line, short (17 B): as shipped", function()
  return read_header_as_shipped(SHORT)
end)
local hl = per_call("header line, long (118 B): as shipped", function()
  return read_header_as_shipped(LONG)
end)

-- `read_header` lowercases the name before it becomes a key.
local lower = per_call("name:lower()", function()
  return ("Content-Length"):lower()
end)

-- And the headers object each parsed line goes into.
local headers = require "akkar.vendor.http.headers"
local h = headers.new()
local append = per_call("headers:append", function()
  if h:len() > 50 then h = headers.new() end
  h:append("content-length", "1234")
end)

print()
-- A benchmark request: request line + 3 short headers.
local bench = rl + 3 * (hs + lower + append)
-- A production-shaped request: request line + 8 headers, half of them long.
local real  = rl + 4 * (hs + lower + append) + 4 * (hl + lower + append)

print(("benchmark request  (1 line + 3 short headers) : %6.2f us"):format(bench / 1000))
print(("production request (1 line + 8 mixed headers) : %6.2f us"):format(real / 1000))
print()
-- THE DENOMINATOR, WITH ITS PROVENANCE, because a share is two numbers and
-- the old one carried only the first. This file divided by a bare `83` that
-- nothing recorded the origin of -- and worse, invited being divided across
-- machines: the numerator above is measured wherever this runs, and 83 was
-- from somewhere else. On this laptop the same parse costs 17.29 us and on the
-- benchmark box 7.87, a factor of 2.2, so mixing the two is not a rounding
-- error.
--
-- The default is what `bench/study/regression.sh` measured on the box at
-- a92177c, browser shape, /ping, 5 alternating repetitions: 20,548 req/s
-- across 2.00 cores, which is 97.3 us of CPU per request. Run this ON the box
-- to compare like with like, or pass the machine's own figure:
--
--     CPU_US=130.1 lua5.4 bench/study/parse-cost.lua    # origin/main's
local CPU_US = tonumber(os.getenv "CPU_US") or 97.3

print(("against %.1f us of CPU per request (see the note above):"):format(CPU_US))
print(("  benchmark shape  : %5.1f%%"):format(bench / 1000 / CPU_US * 100))
print(("  production shape : %5.1f%%"):format(real / 1000 / CPU_US * 100))
print()
print("What a C tokeniser could buy, at most: making the production figure")
print(("ZERO would leave %.1f%% of the CPU, so %.2fx, by Amdahl and nothing else.")
  :format(100 - real / 1000 / CPU_US * 100, 1 / (1 - real / 1000 / CPU_US)))
