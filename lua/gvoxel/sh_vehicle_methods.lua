-- Rebuild only a framework method whose cached trace needs a substitute.
-- Garry's Mod intentionally removes debug.setupvalue/upvaluejoin. Read the
-- mounted Lua source instead; never execute a whole Workshop file or mutate
-- its closed-over variables. Shared tables/vectors retain their identity.
local V = GVoxel
local function tokens(source)
	local out, i, n = {}, 1, #source
	local function longEnd(at)
		local eq = source:match("^%[(=*)%[", at)
		if not eq then
			return
		end
		local _, last = source:find("]" .. eq .. "]", at + 2 + #eq, true)
		return last and last + 1 or n + 1
	end
	while i <= n do
		local c = source:sub(i, i)
		local two = source:sub(i, i + 1)
		if c:match("%s") then
			i = i + 1
		elseif two == "--" or two == "//" then
			local finish = two == "--" and longEnd(i + 2)
			i = finish or ((source:find("\n", i + 2, true) or n) + 1)
		elseif two == "/*" then
			local _, last = source:find("*/", i + 2, true)
			i = last and last + 1 or n + 1
		elseif c == '"' or c == "'" then
			local quote = c
			i = i + 1
			while i <= n do
				c = source:sub(i, i)
				i = i + 1
				if c == "\\" then
					i = i + 1
				elseif c == quote then
					break
				end
			end
		elseif c == "[" and longEnd(i) then
			i = longEnd(i)
		else
			local first = i
			if c:match("[%a_]") then
				i = i + 1
				while source:sub(i, i):match("[%w_]") do
					i = i + 1
				end
			elseif two == "==" or two == "~=" or two == "!=" or two == "<=" or two == ">=" then
				i = i + 2
			else
				i = i + 1
			end
			out[#out + 1] = { value = source:sub(first, i - 1), first = first, last = i - 1 }
		end
	end
	return out
end
local function methodSource(fn)
	if not debug or not debug.getinfo or not debug.getupvalue then
		return nil, "debug read API unavailable"
	end
	local info = debug.getinfo(fn, "S")
	if not info or info.what ~= "Lua" or not info.linedefined or info.linedefined < 1 then
		return nil, "not a Lua source method"
	end
	if not file or not file.Read then
		return nil, "mounted Lua source API unavailable"
	end
	local path = (info.source or ""):gsub("^@", ""):gsub("\\", "/")
	if path:find("[\r\n]") then
		return nil, "function has no mounted source path"
	end
	path = path:match("/lua/(.+)$") or path:gsub("^lua/", "")
	local source = file.Read(path, "LUA")
	if not source then
		return nil, "Lua source unavailable: " .. path
	end
	source = source:gsub("\r", "")
	local first, last, line = 1, #source, 1
	while line < info.linedefined do
		local newline = source:find("\n", first, true)
		if not newline then
			return nil, "source lines no longer match method: " .. path
		end
		first = newline + 1
		line = line + 1
	end
	last = first
	while line <= info.lastlinedefined do
		local newline = source:find("\n", last, true)
		if not newline then
			last = #source + 1
			break
		end
		last = newline + 1
		line = line + 1
	end
	return source:sub(first, last - 1), path, info, source
end
local function writesCapture(ts, names, start)
	local written = {}
	for i = start, #ts do
		local name = ts[i].value
		local prev = ts[i - 1] and ts[i - 1].value
		if names[name] and prev ~= "." and prev ~= ":" then
			local after = ts[i + 1] and ts[i + 1].value
			if after == "=" or (prev == "function" and after == "(") then
				written[name] = true
			end
			if
				(after == "+" or after == "-" or after == "*" or after == "/" or after == "%" or after == "^")
				and ts[i + 2]
				and ts[i + 2].value == "="
			then
				written[name] = true
			end
			-- A conservative check for capture,a,b = ... . Reject unusual
			-- declarations rather than silently split a shared mutable cell.
			if after == "," then
				local j = i + 1
				while ts[j] and ts[j].value == "," do
					j = j + 1
					if not ts[j] or not ts[j].value:match("^[%a_][%w_]*$") then
						break
					end
					j = j + 1
					while ts[j] do
						if ts[j].value == "." and ts[j + 1] and ts[j + 1].value:match("^[%a_][%w_]*$") then
							j = j + 2
						elseif ts[j].value == "[" then
							local depth = 1
							j = j + 1
							while ts[j] and depth > 0 do
								if ts[j].value == "[" then
									depth = depth + 1
								elseif ts[j].value == "]" then
									depth = depth - 1
								end
								j = j + 1
							end
							if depth > 0 then
								break
							end
						else
							break
						end
					end
				end
				if ts[j] and ts[j].value == "=" then
					written[name] = true
				end
			end
		end
	end
	return written
end
local function describe(fn)
	local source, path, info, fullSource = methodSource(fn)
	if not source then
		return nil, path
	end
	local ts = tokens(source)
	local firstLine = source:find("\n", 1, true) or (#source + 1)
	local declarations = 0
	for _, t in ipairs(ts) do
		if t.first >= firstLine then
			break
		end
		if t.value == "function" then
			declarations = declarations + 1
		end
	end
	-- debug line ranges cannot distinguish an inner and outer closure when
	-- both start on this line. Refuse rather than substitute the wrong body.
	if declarations ~= 1 then
		return nil, "ambiguous method source boundary: " .. path
	end
	local at
	for i, t in ipairs(ts) do
		if t.value == "function" then
			at = i
			break
		end
	end
	if not at then
		return nil, "method declaration unavailable: " .. path
	end
	local p = at + 1
	local colon = false
	while ts[p] and ts[p].value ~= "(" do
		local word = ts[p].value
		if word == ":" then
			colon = true
		elseif word ~= "." and not word:match("^[%a_][%w_]*$") then
			return nil, "unsupported method declaration: " .. path
		end
		p = p + 1
	end
	if not ts[p] then
		return nil, "method parameters unavailable: " .. path
	end
	local close = p + 1
	while ts[close] and ts[close].value ~= ")" do
		close = close + 1
	end
	if not ts[close] or not ts[#ts] or ts[#ts].value ~= "end" then
		return nil, "unsupported method source boundary: " .. path
	end
	return {
		fn = fn,
		source = source,
		path = path,
		info = info,
		fullSource = fullSource,
		ts = ts,
		p = p,
		close = close,
		colon = colon,
		names = {},
		captures = {},
	}
end
local function readCaptures(node)
	for i = 1, 255 do
		local name, value = debug.getupvalue(node.fn, i)
		if not name then
			break
		end
		if not name:match("^[%a_][%w_]*$") then
			return nil, "unnamed captured variable: " .. node.path
		end
		node.names[name] = true
		node.captures[#node.captures + 1] = { name = name, value = value }
	end
	node.written = writesCapture(node.ts, node.names, node.close + 1)
	return true
end
local function expression(node)
	local params = node.source:sub(node.ts[node.p].last + 1, node.ts[node.close].first - 1)
	if node.colon then
		params = "self" .. (params:match("%S") and "," .. params or "")
	end
	return "function(" .. params .. ")" .. node.source:sub(node.ts[node.close].last + 1, node.ts[#node.ts].last)
end
local function substitute(substitutions, name, value)
	local replacement = value ~= nil and substitutions and substitutions[value] or nil
	if replacement == nil and substitutions and substitutions.resolve then
		local resolved, changed = substitutions.resolve(name, value)
		if changed then
			replacement = resolved
		end
	end
	if replacement ~= nil then
		return replacement
	end
	return value
end
local function compile(code, path, env, captures)
	if not CompileString then
		return nil, "Lua source compiler unavailable"
	end
	local compiled = CompileString(table.concat(code, "\n"), "GVoxel vehicle adapter: " .. path, false)
	if type(compiled) ~= "function" then
		return nil, "method compilation failed: " .. tostring(compiled)
	end
	setfenv(compiled, env)
	local ok, clone, list = pcall(compiled, captures)
	if not ok or type(clone) ~= "function" then
		return nil, "method factory failed: " .. tostring(clone)
	end
	return clone, list
end
-- With no upvalue identity/mutation API, a copied scalar cell is safe only
-- for a closed group of temporary variables reset at every entry. Resolve
-- file-scope declarations, rather than assuming equal nil/number values mean
-- the same lexical variable. Other scopes remain unsupported for this case.
local function fileBindings(source)
	local ts = tokens(source)
	local bindings, owners, declarations, functions = {}, {}, {}, {}
	local stack, depth, top = {}, 0, nil
	local line, at = 1, 1
	for i, t in ipairs(ts) do
		local _, newlines = source:sub(at, t.first - 1):gsub("\n", "")
		line = line + newlines
		at = t.first
		local word = t.value
		owners[i] = top
		if word == "local" and #stack == 0 then
			local j = i + 1
			if ts[j] and ts[j].value == "function" then
				j = j + 1
			end
			while ts[j] and ts[j].value:match("^[%a_][%w_]*$") do
				local name = ts[j].value
				bindings[name] = ts[j].first
				declarations[j] = true
				j = j + 1
				if not ts[j] or ts[j].value ~= "," then
					break
				end
				j = j + 1
			end
		end
		if word == "function" then
			if depth == 0 then
				local visible = {}
				for name, id in pairs(bindings) do
					visible[name] = id
				end
				top = { line = line, first = t.first, bindings = visible }
				if functions[line] ~= nil then
					functions[line] = false
				else
					functions[line] = top
				end
			end
			stack[#stack + 1] = { kind = "function", owner = top }
			depth = depth + 1
			owners[i] = top
		elseif word == "if" or word == "for" or word == "while" or word == "repeat" then
			stack[#stack + 1] = { kind = word, pending = word == "for" or word == "while" }
		elseif word == "do" then
			local last = stack[#stack]
			if last and last.pending then
				last.pending = nil
			else
				stack[#stack + 1] = { kind = "do" }
			end
		elseif word == "end" or word == "until" then
			local last = table.remove(stack)
			if last and last.kind == "function" then
				depth = depth - 1
				if depth == 0 then
					top = nil
				end
			end
		end
	end
	return ts, owners, declarations, functions
end
local binary = {
	["+"] = true,
	["-"] = true,
	["*"] = true,
	["/"] = true,
	["%"] = true,
	["^"] = true,
	["."] = true,
	["and"] = true,
	["or"] = true,
	["="] = true,
	[","] = true,
	["<"] = true,
	[">"] = true,
	["=="] = true,
	["~="] = true,
	["!="] = true,
	["<="] = true,
	[">="] = true,
}
local function prefixAssignments(node, scratch)
	local ts = node.ts
	local initialized, required, helperUses = {}, {}, {}
	local helpers = {}
	for _, capture in ipairs(node.captures) do
		if node.graph[capture.value] then
			helpers[capture.name] = node.graph[capture.value]
		end
	end
	local function reads(first, last)
		for i = first, last do
			local name = ts[i].value
			local prev = ts[i - 1] and ts[i - 1].value
			if node.names[name] and prev ~= "." and prev ~= ":" then
				if scratch[name] and not initialized[name] then
					required[name] = true
				end
				if helpers[name] then
					local ready = {}
					for key in pairs(initialized) do
						ready[key] = true
					end
					helperUses[#helperUses + 1] = { node = helpers[name], ready = ready }
				end
			end
		end
	end
	local cursor = node.close + 1
	while ts[cursor] do
		if ts[cursor].value == ";" then
			cursor = cursor + 1
		end
		local lhs, j = {}, cursor
		while ts[j] and node.names[ts[j].value] do
			lhs[#lhs + 1] = ts[j].value
			j = j + 1
			if not ts[j] or ts[j].value ~= "," then
				break
			end
			j = j + 1
		end
		if #lhs == 0 or not ts[j] or ts[j].value ~= "=" then
			break
		end
		local first = j + 1
		local parens, brackets, braces = 0, 0, 0
		j = first
		while ts[j] do
			local word = ts[j].value
			if parens == 0 and brackets == 0 and braces == 0 then
				if word == ";" or word == "end" then
					break
				end
				local previous = ts[j - 1]
				if
					j > first
					and node.source:sub(previous.last + 1, ts[j].first - 1):find("\n", 1, true)
					and not binary[previous.value]
					and not binary[word]
				then
					break
				end
			end
			if word == "(" then
				parens = parens + 1
			elseif word == ")" then
				parens = parens - 1
			elseif word == "[" then
				brackets = brackets + 1
			elseif word == "]" then
				brackets = brackets - 1
			elseif word == "{" then
				braces = braces + 1
			elseif word == "}" then
				braces = braces - 1
			end
			j = j + 1
		end
		reads(first, j - 1)
		for _, name in ipairs(lhs) do
			initialized[name] = true
		end
		cursor = j
	end
	for name in pairs(node.written) do
		if not initialized[name] then
			return nil,
				"shared captured variable is reassigned before an unconditional reset: "
					.. name
					.. " ("
					.. node.path
					.. ")"
		end
	end
	reads(cursor, #ts)
	node.required, node.helperUses = required, helperUses
	return true
end
local function cloneTemporaryGroup(root, substitutions)
	local graph, nodes = {}, {}
	local function collect(node)
		graph[node.fn] = node
		nodes[#nodes + 1] = node
		node.graph = graph
		for _, capture in ipairs(node.captures) do
			local value = capture.value
			if type(value) == "function" and not graph[value] then
				local info = debug.getinfo(value, "S")
				if info and info.what == "Lua" and info.source == root.info.source then
					local child, reason = describe(value)
					if not child then
						return nil, reason
					end
					local ok, err = readCaptures(child)
					if not ok then
						return nil, err
					end
					ok, err = collect(child)
					if not ok then
						return nil, err
					end
				end
			end
		end
		return true
	end
	local ok, reason = collect(root)
	if not ok then
		return nil, reason
	end
	local scratch = {}
	for _, node in ipairs(nodes) do
		for name in pairs(node.written) do
			scratch[name] = true
		end
	end
	local sourceTokens, owners, declarations, functions = fileBindings(root.fullSource)
	local captures, byName, bindings, memberPositions = {}, {}, {}, {}
	for _, node in ipairs(nodes) do
		local declaration = functions[node.info.linedefined]
		if not declaration then
			return nil, "ambiguous shared capture scope: " .. node.path
		end
		memberPositions[declaration.first] = true
		for _, row in ipairs(node.captures) do
			local existing = byName[row.name]
			local binding = declaration.bindings[row.name]
			if existing and (existing.value ~= row.value or bindings[row.name] ~= binding) then
				return nil, "ambiguous shared capture binding: " .. row.name .. " (" .. node.path .. ")"
			end
			if scratch[row.name] and not binding then
				return nil, "unsupported shared capture scope: " .. row.name .. " (" .. node.path .. ")"
			end
			if not existing then
				captures[#captures + 1] = row
				byName[row.name] = row
				bindings[row.name] = binding
				row.index = #captures
			end
		end
	end
	-- Every source reference to a reset cell must belong to this group. A
	-- persistent observer/writer in another method must keep its native cell.
	for i, t in ipairs(sourceTokens) do
		local name = t.value
		if scratch[name] and not declarations[i] then
			local owner = owners[i]
			local prev = sourceTokens[i - 1] and sourceTokens[i - 1].value
			if
				owner
				and owner.bindings[name] == bindings[name]
				and not memberPositions[owner.first]
				and prev ~= "."
				and prev ~= ":"
			then
				return nil,
					"shared captured variable is reassigned outside the temporary helper group: "
						.. name
						.. " ("
						.. root.path
						.. ")"
			end
		end
	end
	for _, node in ipairs(nodes) do
		ok, reason = prefixAssignments(node, scratch)
		if not ok then
			return nil, reason
		end
	end
	-- Propagate helper entry requirements until stable (also handles cycles).
	local changed = true
	while changed do
		changed = false
		for _, node in ipairs(nodes) do
			for _, use in ipairs(node.helperUses) do
				for name in pairs(use.node.required) do
					if not use.ready[name] and not node.required[name] then
						node.required[name] = true
						changed = true
					end
				end
			end
		end
	end
	for name in pairs(root.required) do
		return nil,
			"shared captured variable is reassigned without reset before use: " .. name .. " (" .. root.path .. ")"
	end
	local slot = "__vm_vehicle_group"
	while root.fullSource:find(slot, 1, true) do
		slot = slot .. "_"
	end
	local code = { "local " .. slot .. "=..." }
	for _, row in ipairs(captures) do
		code[#code + 1] = "local " .. row.name .. "=" .. slot .. "[" .. row.index .. "]"
	end
	for index, node in ipairs(nodes) do
		node.symbol = slot .. "_fn" .. index
		code[#code + 1] = "local " .. node.symbol
	end
	for _, node in ipairs(nodes) do
		code[#code + 1] = node.symbol .. "=" .. expression(node)
	end
	for _, row in ipairs(captures) do
		if graph[row.value] then
			code[#code + 1] = row.name .. "=" .. graph[row.value].symbol
		end
	end
	local returned = {}
	local values = {}
	for _, row in ipairs(captures) do
		values[row.index] = substitute(substitutions, row.name, row.value)
	end
	for _, node in ipairs(nodes) do
		returned[#returned + 1] = node.symbol
	end
	code[#code + 1] = "return " .. root.symbol .. ",{" .. table.concat(returned, ",") .. "}"
	local clone, list = compile(code, root.path, getfenv(root.fn), values)
	if not clone then
		return nil, list
	end
	for index, node in ipairs(nodes) do
		setfenv(list[index], getfenv(node.fn))
	end
	return clone
end
function V.CloneVehicleTraceMethod(fn, substitutions)
	local node, reason = describe(fn)
	if not node then
		return nil, reason
	end
	local ok, err = readCaptures(node)
	if not ok then
		return nil, err
	end
	if next(node.written) then
		return cloneTemporaryGroup(node, substitutions)
	end
	local captures = {}
	for i, row in ipairs(node.captures) do
		captures[i] = substitute(substitutions, row.name, row.value)
	end
	local slot = "__vm_vehicle_captures"
	while node.names[slot] or node.source:find(slot, 1, true) do
		slot = slot .. "_"
	end
	local code = { "local " .. slot .. "=..." }
	for i, row in ipairs(node.captures) do
		code[#code + 1] = "local " .. row.name .. "=" .. slot .. "[" .. i .. "]"
	end
	code[#code + 1] = "return " .. expression(node)
	local env = getfenv(fn)
	local clone, message = compile(code, node.path, env, captures)
	if not clone then
		return nil, message
	end
	setfenv(clone, env)
	return clone
end
