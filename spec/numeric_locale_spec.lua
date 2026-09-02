--[[
Every number akkar renders keeps a `.` for its decimal point.

WHAT THE DEFECT WAS. Lua has no number formatting of its own: `%f`, `%g` and
`tostring` all go through C's `printf`, which writes whatever character
LC_NUMERIC names. Under a comma locale -- pt_BR, de_DE, fr_FR, and most of the
world's -- `string.format("%.6f", 0.013427)` is `0,013427`, and six emitters in
`akkar/metrics.lua` plus one in `akkar/log.lua` built their output from exactly
that. (Five of the six -- see the uptime case below, which corrects the
audit.) The scrape then reads

    akkar_request_duration_seconds_sum{method="GET",route="/x"} 0,013427

which is not a sample. Prometheus does not drop the metric and keep the rest;
it rejects the text, so the SCRAPE fails and every series the process publishes
goes stale together. That disproportion -- one comma, no numbers at all -- is
why this was worth fixing rather than filing.

HOW REACHABLE IT WAS, STATED HONESTLY. Lua never calls `setlocale`, so a Lua
process starts at "C" and stays there, and akkar's dependency stack was checked
and does not move it. That is a real guard and it was verified. It is also a
guard held by ABSENCE rather than by anything akkar controls: `os.setlocale` is
in the standard library, a C extension may call `setlocale(3)` in its
initialiser, and the application is not akkar's code. The laptop this was
written on has `LC_NUMERIC=pt_BR.UTF-8` exported already; the distance from
there to a dead scrape is one call anywhere in the process.

So: latent, but latent behind somebody else's guard, with a blast radius of
every metric and a repair of three lines. Fixed.

WHY THE FIX CANNOT SHOW UP IN THE OUTPUT. It has to be a no-op under "C", or it
would be a change to the exposition format rather than a repair -- `le="0.01"`
must stay `le="0.01"` and not become `le="0.010000"`, because Prometheus treats
those as different label values and every existing bucket series would break at
the version boundary. The first case below pins byte-identical output under
"C"; the rest set the locale and demand the same bytes back.

RUNS ANYWHERE. A machine without a comma locale installed cannot exercise this,
so the locale-setting cases report `pending` rather than passing quietly on an
instrument that measured nothing. On this laptop `pt_BR.utf8` is present.

PROVED TO FAIL. With `decimal` reduced to `return rendered`, this file reports
4 failures under pt_BR.UTF-8 -- the whole scrape differing under the
two locales, `le="0,01"`, `akkar_uptime_seconds 1,5` and a `duration_s` that
arrived at the log store quoted as a string -- and still passes every "C"
case, which is the point: the old code was correct on the machine that wrote
it.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar = require "akkar"

--- A locale on this machine whose decimal point is not `.`, or nil.
local COMMA_LOCALE = (function()
  local was = os.setlocale(nil, "numeric")
  for _, name in ipairs { "pt_BR.UTF-8", "pt_BR.utf8", "de_DE.UTF-8",
                          "de_DE.utf8", "fr_FR.UTF-8", "fr_FR.utf8" } do
    if os.setlocale(name, "numeric") then
      local comma = string.format("%.1f", 0.5) ~= "0.5"
      os.setlocale(was, "numeric")
      if comma then return name end
    end
  end
  os.setlocale(was, "numeric")
  return nil
end)()

--- Runs `body` with LC_NUMERIC set to a comma locale, and puts it back
--- whatever happens -- a spec that leaves the locale moved would hand its
--- failure to whichever file busted loads next.
local function under_comma_locale(body)
  local was = os.setlocale(nil, "numeric")
  local ok, err = pcall(function()
    assert(os.setlocale(COMMA_LOCALE, "numeric"), "could not set the locale")
    assert(string.format("%.1f", 0.5) ~= "0.5", "the locale did not take")
    body()
  end)
  os.setlocale(was, "numeric")
  if not ok then error(err, 0) end
end

--- A registry with one of everything that renders a number.
local function populated()
  local registry = akkar.metrics.new()
  registry:observe("GET", "/x", 200, 0.013427)
  registry:counter("orders_total", 1, { { "kind", "retail" } })
  registry:gauge("queue_depth", 2.5)
  return registry
end

describe("the Prometheus scrape", function()
  it("is byte-identical to what it rendered before, under C", function()
    -- THE CASE THAT SAYS THE REPAIR IS A REPAIR. `decimal` substitutes the
    -- separator for `.`, and under "C" the separator already IS `.`, so every
    -- line must come back unchanged. The literals below are what the emitters
    -- produced before the change.
    local was = os.setlocale(nil, "numeric")
    assert.equal("C", was, "this case needs the default locale")

    local text = populated():render()
    assert.is_truthy(text:match 'akkar_request_duration_seconds_sum{method="GET",route="/x"} 0%.013427',
                     "the histogram sum changed shape:\n" .. text)
    assert.is_truthy(text:match 'le="0%.005"', "a bucket edge changed shape")
    assert.is_truthy(text:match 'le="0%.01"',  "a bucket edge gained digits")
    assert.is_truthy(text:match 'le="1"',      "an integral edge grew a point")
    assert.is_truthy(text:match "akkar_uptime_seconds [%d%.e%-+]+\n")
    assert.is_truthy(text:match 'orders_total{kind="retail"} 1\n',
                     "a counter changed shape")
    assert.is_truthy(text:match "queue_depth 2%.5\n", "a gauge changed shape")
  end)

  it("renders the same bytes under a comma locale", function()
    if not COMMA_LOCALE then
      pending "no locale with a comma decimal point installed on this machine"
      return
    end
    -- The strongest form of the assertion available: not "it parses", but
    -- "it is the same text". Rendered twice from the same registry, so the
    -- only difference between the two runs is LC_NUMERIC.
    local registry = populated()
    local under_c = registry:render()
    local under_comma
    under_comma_locale(function() under_comma = registry:render() end)

    -- Uptime moves between the two renders, so it is compared as a shape
    -- rather than as bytes; everything else must be identical.
    local function without_uptime(text)
      return (text:gsub("akkar_uptime_seconds [^\n]*", "akkar_uptime_seconds"))
    end
    assert.equal(without_uptime(under_c), without_uptime(under_comma))
  end)

  it("emits no comma where a sample expects a number", function()
    if not COMMA_LOCALE then
      pending "no locale with a comma decimal point installed on this machine"
      return
    end
    under_comma_locale(function()
      local text = populated():render()
      -- Every non-comment, non-blank line is `name{labels} value`. The value
      -- is checked with `tonumber` under a locale-independent reading: Lua's
      -- own `tonumber` follows LC_NUMERIC too, so `0,013427` would parse HERE
      -- and fail in Prometheus. Matching the digits is the honest test.
      local checked = 0
      for line in text:gmatch "[^\n]+" do
        if line ~= "" and line:sub(1, 1) ~= "#" then
          local value = line:match "([^%s]+)$"
          checked = checked + 1
          assert.is_truthy(value:match "^[%-+]?[%d%.]+[eE]?[%-+]?%d*$" or value == "+Inf",
            ("not a parseable sample: %q"):format(line))
        end
        -- A label value is a number too where the label is `le`.
        local edge = line:match 'le="([^"]+)"'
        if edge then
          assert.is_truthy(edge:match "^[%d%.]+$" or edge == "+Inf",
            ("not a parseable bucket edge: %q"):format(line))
        end
      end
      assert.is_true(checked > 10, "the scrape rendered almost nothing")
    end)
  end)

  it("keeps a fractional uptime numeric", function()
    if not COMMA_LOCALE then
      pending "no locale with a comma decimal point installed on this machine"
      return
    end
    -- A CORRECTION TO THE AUDIT, recorded rather than quietly fixed. The
    -- uptime emitter was listed with the other five, and on the code as it
    -- stands it cannot break: `time.now()` answers whole unix seconds as a Lua
    -- INTEGER, so `time.now() - started` is an integer, and `tostring` on an
    -- integer is `%d`, which no locale touches. Written as a case reading a
    -- fresh registry, this asserted nothing at all -- it passed with the
    -- repair removed.
    --
    -- It is still routed through `decimal`, because the guard there is the
    -- integer type of a clock in another module and this is what it costs to
    -- stop depending on that. `started` is pushed back by a fraction here so
    -- that the emitter renders the float it would render the day `time.now()
    -- grows a decimal, and this case fails with the repair removed.
    local registry = akkar.metrics.new()
    local time = require "akkar.time"
    registry.started = time.now() - 1.5
    under_comma_locale(function()
      local value = registry:render():match "\nakkar_uptime_seconds ([^\n]+)"
      assert.is_truthy(value, "no uptime sample")
      assert.is_falsy(value:find ",", ("uptime carried a comma: %q"):format(value))
    end)
  end)
end)

describe("a log line", function()
  local function line_for(value)
    local written
    local log = akkar.log.new { level = "info", sink = function(text) written = text end }
    log:info("measured", { duration_s = value })
    return written
  end

  it("writes a float with a point under C", function()
    assert.is_truthy(line_for(0.013427):match "duration_s=0%.013427",
                     line_for(0.013427))
    -- An integral float still renders bare, which is the behaviour
    -- `akkar/log.lua` documents and this change must not touch.
    assert.is_truthy(line_for(2.0):match "duration_s=2%f[%s\0]")
    assert.is_truthy(line_for(7):match "duration_s=7%f[%s\0]")
  end)

  it("writes a float with a point under a comma locale", function()
    if not COMMA_LOCALE then
      pending "no locale with a comma decimal point installed on this machine"
      return
    end
    under_comma_locale(function()
      local written = line_for(0.013427)
      assert.is_truthy(written:match "duration_s=0%.013427",
        ("a log field stopped being numeric: %s"):format(written))
    end)
  end)

  it("leaves inf and nan alone, which carry no separator", function()
    -- `decimal` skips anything with no digit in it, which is what keeps it
    -- from turning `nan` into `...`. Worth a case because the substitution is
    -- otherwise indiscriminate.
    assert.is_truthy(line_for(math.huge):match "duration_s=inf")
    assert.is_truthy(line_for(-math.huge):match "duration_s=%-inf")
    assert.is_truthy(line_for(0 / 0):match "duration_s=%-?nan")
  end)
end)
