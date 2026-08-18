--[[
HTTP Header data structure/type

Design criteria:
  - the same header field is allowed more than once
      - must be able to fetch separate occurences (important for some headers e.g. Set-Cookie)
      - optionally available as comma separated list
  - header order should be recoverable

AKKAR: THE SHAPE CHANGED, AND EVERY CHANGE IS MEASURED.

Upstream stores headers as an array of entry TABLES -- one
`setmetatable({name=, value=}, entry_mt)` per header -- plus an index of field
name => array indices. Both halves were paid for on every header of every
request, and this is a JSON runtime where a request carries three headers and
a response carries three more.

  1. `never_index` is gone from every entry. It is HPACK's flag -- "never
     place this in HTTP/2's dynamic table" -- and HTTP/2 went when the
     HTTP/1.1 half of this library was vendored. Carried on every header,
     read by nobody: -432 bytes per request.

  2. `_index[name]` holds an INTEGER while a name has appeared once, and
     promotes to the old `{n=k, ...}` table on the second occurrence. Header
     names overwhelmingly occur once; `set-cookie` is the exception that was
     charging everyone. With the read fast paths below, -1,780 bytes.

  3. The entry table is gone too. `_names` and `_values` are parallel arrays,
     so a header is two array slots rather than a two-key table with a
     metatable. Priced first, 50,000 of each:

         entry table with metatable   125.0 bytes
         two parallel array slots      41.9 bytes

     The entry object was never visible outside this file -- `each()` already
     handed back `name, value`, and nothing anywhere reached into `_data` --
     so this is an internal shape and not an API.

`spec/vendor_headers_spec.lua` tests this structure directly, because the way
these changes fail is quiet: a reader that understands one shape and not the
other drops a `set-cookie` or returns the first of two `via` headers, and a
test that goes through a server never sends either.
]]

local unpack = table.unpack or unpack -- luacheck: ignore 113 143

local headers_methods = {}
local headers_mt = {
	__name = "http.headers";
	__index = headers_methods;
}

local function new_headers()
	return setmetatable({
		_n = 0;
		_names = {};
		_values = {};
		_index = {};
	}, headers_mt)
end

function headers_methods:len()
	return self._n
end
headers_mt.__len = headers_methods.len

function headers_mt:__tostring()
	return string.format("http.headers{%d headers}", self._n)
end

-- Four readers below know both index shapes; there is no fifth, and `has()`
-- needed no change because it only ever asked whether the value was nil.
local function add_to_index(_index, name, i)
	local dex = _index[name]
	if dex == nil then
		_index[name] = i
	elseif type(dex) == "number" then
		-- The second occurrence is where the table finally earns itself.
		_index[name] = {n=2, dex, i}
	else
		local n = dex.n + 1
		dex[n] = i
		dex.n = n
	end
end

local function rebuild_index(self)
	local index = {}
	local names = self._names
	for i=1, self._n do
		add_to_index(index, names[i], i)
	end
	self._index = index
end

function headers_methods:clone()
	local n = self._n
	local names, values = self._names, self._values
	local new_names, new_values, index = {}, {}, {}
	for i=1, n do
		local name = names[i]
		new_names[i] = name
		new_values[i] = values[i]
		add_to_index(index, name, i)
	end
	return setmetatable({
		_n = n;
		_names = new_names;
		_values = new_values;
		_index = index;
	}, headers_mt)
end

function headers_methods:append(name, value)
	local n = self._n + 1
	self._names[n] = name
	self._values[n] = value
	add_to_index(self._index, name, n)
	self._n = n
end

function headers_methods:each()
	local i = 0
	return function(self) -- luacheck: ignore 432
		if i >= self._n then return end
		i = i + 1
		return self._names[i], self._values[i]
	end, self
end
headers_mt.__pairs = headers_methods.each

function headers_methods:has(name)
	local dex = self._index[name]
	return dex ~= nil
end

--- Removes position `i` from both arrays, keeping them in step.
---
--- Two `table.remove` calls where there used to be one, and they must stay
--- together: a name shifted down while its value stayed put would pair every
--- later header with somebody else's value -- and every one of them would
--- still be a string, so nothing would raise.
local function remove_at(self, i)
	table.remove(self._names, i)
	table.remove(self._values, i)
end

function headers_methods:delete(name)
	local dex = self._index[name]
	if dex then
		if type(dex) == "number" then
			remove_at(self, dex)
			self._n = self._n - 1
		else
			local n = dex.n
			for i=n, 1, -1 do
				remove_at(self, dex[i])
			end
			self._n = self._n - n
		end
		rebuild_index(self)
		return true
	else
		return false
	end
end

function headers_methods:geti(i)
	local name = self._names[i]
	if name == nil then return nil end
	return name, self._values[i]
end

function headers_methods:get_as_sequence(name)
	local dex = self._index[name]
	if dex == nil then return { n = 0; } end
	if type(dex) == "number" then
		return { n = 1; self._values[dex] }
	end
	local values = self._values
	local r = { n = dex.n; }
	for i=1, r.n do
		r[i] = values[dex[i]]
	end
	return r
end

-- AKKAR: `get` and `get_comma_separated` answer the single-occurrence case
-- without building a sequence at all.
--
-- Both used to go through `get_as_sequence` unconditionally, so reading ONE
-- header -- which is what every caller in this library and in akkar does --
-- allocated a table to hold one string and then threw it away. `get_headers`
-- alone reads `content-length`, `transfer-encoding`, `connection` and
-- `expect` on the way through a single request.
--
-- This, not the index, is the larger half of what change 2 was worth: the
-- estimate that preceded it priced the writes, and the cost was in the reads.
function headers_methods:get(name)
	local dex = self._index[name]
	if dex == nil then return end
	if type(dex) == "number" then
		return self._values[dex]
	end
	local r = self:get_as_sequence(name)
	return unpack(r, 1, r.n)
end

function headers_methods:get_comma_separated(name)
	local dex = self._index[name]
	if dex == nil then return nil end
	if type(dex) == "number" then
		return self._values[dex]
	end
	local r = self:get_as_sequence(name)
	if r.n == 0 then
		return nil
	else
		return table.concat(r, ",", 1, r.n)
	end
end

function headers_methods:modifyi(i, value)
	if self._names[i] == nil then error("invalid index") end
	self._values[i] = value
end

function headers_methods:upsert(name, value)
	local dex = self._index[name]
	if dex == nil then
		self:append(name, value)
	elseif type(dex) == "number" then
		self:modifyi(dex, value)
	else
		assert(dex[2] == nil, "Cannot upsert multi-valued field")
		self:modifyi(dex[1], value)
	end
end

local function before(a_name, a_value, b_name, b_value)
	if a_name ~= b_name then
		-- Things with a colon *must* be before others
		local a_is_colon = a_name:sub(1,1) == ":"
		local b_is_colon = b_name:sub(1,1) == ":"
		if a_is_colon and not b_is_colon then
			return true
		elseif not a_is_colon and b_is_colon then
			return false
		else
			return a_name < b_name
		end
	end
	if a_value ~= b_value then
		return a_value < b_value
	end
	-- Same name and same value: the two are indistinguishable, so the order
	-- between them cannot matter. This used to break the tie on
	-- `never_index`, which no longer exists.
	return false
end

--- Sorts by name, then by value, and rebuilds the index.
---
--- PARALLEL ARRAYS CANNOT GO TO `table.sort` DIRECTLY -- it would reorder one
--- and leave the other where it was, pairing every name with somebody else's
--- value. So an array of positions is sorted and the two arrays are permuted
--- through it.
---
--- The order array is built here rather than kept on the object: `sort` runs
--- at most once per outgoing message, and holding a third array on every
--- headers object to save an allocation on a path that rarely runs is exactly
--- the trade this file exists to stop making.
function headers_methods:sort()
	local n = self._n
	local names, values = self._names, self._values
	local order = {}
	for i=1, n do order[i] = i end
	table.sort(order, function(a, b)
		return before(names[a], values[a], names[b], values[b])
	end)
	local new_names, new_values = {}, {}
	for i=1, n do
		local from = order[i]
		new_names[i] = names[from]
		new_values[i] = values[from]
	end
	self._names, self._values = new_names, new_values
	rebuild_index(self)
end

function headers_methods:dump(file, prefix)
	file = file or io.stderr
	prefix = prefix or ""
	for name, value in self:each() do
		assert(file:write(string.format("%s%s: %s\n", prefix, name, value)))
	end
	assert(file:flush())
end

return {
	new = new_headers;
	methods = headers_methods;
	mt = headers_mt;
}
