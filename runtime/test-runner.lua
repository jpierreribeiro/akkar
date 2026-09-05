-- Deliberately bypass LuaRocks' executable wrapper: that wrapper prepends its
-- dependency tree and can silently shadow the controlled native libraries.
local expected = assert(os.getenv("CQUEUES_COMMIT"), "CQUEUES_COMMIT is required")
assert(require("cqueues").COMMIT == expected, "test runner loaded a different cqueues")
require("busted.runner")({ standalone = false })
