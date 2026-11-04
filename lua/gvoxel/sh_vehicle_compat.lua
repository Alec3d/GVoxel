-- Family-level trace adapters for vehicles and projectiles. Change only their
-- Lua methods; never replace util traces globally or edit Workshop files.
local V = GVoxel
if V.ReleaseVehicleAdapters then
	V.ReleaseVehicleAdapters()
end
local installed, functions = {}, setmetatable({}, { __mode = "k" })
local traceWrappers = setmetatable({}, { __mode = "k" })
local entryWrappers = setmetatable({}, { __mode = "k" })
-- Scripted entities copy class methods on spawn. A copy of an old entry can
-- outlive the class replacement during Lua refresh; unwrap it on next patch.
V.VehicleAdapterOrigins = V.VehicleAdapterOrigins or setmetatable({}, { __mode = "k" })
local origins = V.VehicleAdapterOrigins
local context, contextEntity, missileImpact
local function glideProjectile(ent)
	if not ent or not ent.GetClass then
		return false
	end
	local class = ent:GetClass()
	return class == "glide_projectile" or class == "glide_missile"
end
local function projectile(ent)
	return glideProjectile(ent) or (V.IsVoxelProjectile and V.IsVoxelProjectile(ent))
end
function V.GetGlideMissileVoxelImpact(projectile)
	if contextEntity == projectile then
		return missileImpact
	end
end
local nativeLine, nativeHull = util.TraceLine, util.TraceHull
local entryPoints = {
	Think = true,
	PhysicsSimulate = true,
	RunAI = true,
	AIThink = true,
	CalcView = true,
	CalcVehicleView = true,
	WheelOnGround = true,
	DoPhysics = true,
	PhysicsOnGround = true,
	GetEyeTrace = true,
	GetTraceData = true,
	Touch = true,
	StartTouch = true,
	PhysicsCollide = true,
	PhysicsUpdate = true,
}
local function family(ent)
	if ent.IsGlideVehicle == true then
		return "Glide"
	end
	if ent.LVS == true then
		return "LVS"
	end
	if ent.GetClass and ent:GetClass() == "gmod_sent_vehicle_fphysics_base" then
		return "Simfphys"
	end
	if ent.IsVehicle and ent:IsVehicle() then
		return "HL2"
	end
end
V.VoxelVehicleFamily = family
function V.GetVoxelVehicleRoot(ent)
	local seen = {}
	for _ = 1, 12 do
		if not IsValid(ent) or seen[ent] or (ent.IsPlayer and ent:IsPlayer()) then
			return
		end
		seen[ent] = true
		if IsValid(ent.VMVehicleRoot) then
			return ent.VMVehicleRoot
		end
		local parent = ent.GetParent and ent:GetParent()
		local kind = family(ent)
		if kind and (kind ~= "HL2" or not IsValid(parent)) then
			return ent
		end
		if glideProjectile(ent) and ent.GetOwner then
			local owner = ent:GetOwner()
			if IsValid(owner) and owner.IsGlideVehicle == true then
				ent = owner
			else
				return
			end
		else
			local getBase = ent.GetBase or ent.GetBaseEnt
			if getBase then
				local base = getBase(ent)
				if IsValid(base) and base ~= ent then
					ent = base
				else
					ent = parent
				end
			else
				ent = parent
			end
		end
	end
end
local function region(projectile)
	local r = SERVER and V.GetServerScanRegion and V.GetServerScanRegion()
		or CLIENT and V.GetClientScanRegion and V.GetClientScanRegion()
	if r and (r.revision > 0 or projectile) and r.vehicleExterior then
		return r
	end
end
local function trace(original, data)
	if MASK_WATER and data.mask == MASK_WATER then
		return original(data)
	end
	local r = context and region(contextEntity and projectile(contextEntity))
	if not r then
		return original(data)
	end
	local hit = V.TraceVehicleTerrain(r, data, original)
	if
		SERVER
		and contextEntity
		and contextEntity:GetClass() == "glide_missile"
		and type(data.filter) == "table"
		and data.filter[1] == contextEntity
	then
		missileImpact = hit.Hit and not hit.HitSky and hit.HitTexture == "gvoxel" and hit.HitPos or nil
	end
	return hit
end
local function pack(...)
	return { n = select("#", ...), ... }
end
local function wrappedEntry(adapted, original)
	local wrapper = function(self, ...)
		-- Inherited methods can nest. Only the outer vehicle entry needs a
		-- protected call, to restore context even when another addon errors.
		if context or not region(projectile(self)) then
			return adapted(self, ...)
		end
		local root = V.GetVoxelVehicleRoot(self) or (projectile(self) and self)
		if not root then
			return adapted(self, ...)
		end
		context = root
		contextEntity = self
		missileImpact = nil
		local result = pack(pcall(adapted, self, ...))
		context = nil
		contextEntity = nil
		missileImpact = nil
		if not result[1] then
			error(result[2], 0)
		end
		return unpack(result, 2, result.n)
	end
	entryWrappers[wrapper] = true
	origins[wrapper] = original
	return wrapper
end
local proxies = setmetatable({}, { __mode = "k" })
local utilProxy = setmetatable({
	TraceLine = function(data)
		return trace(nativeLine, data)
	end,
	TraceHull = function(data)
		return trace(nativeHull, data)
	end,
}, { __index = util })
local function traceReplacement(name, value)
	if
		type(value) == "function"
		and not traceWrappers[value]
		and (value == nativeLine or value == nativeHull or name == "TraceLine" or name == "TraceHull")
	then
		local wrapper = function(data)
			return trace(value, data)
		end
		traceWrappers[wrapper] = true
		return wrapper, true
	end
	if value == util then
		return utilProxy, true
	end
end
local warned = {}
local function unsupported(info, reason)
	local name = tostring(info.source) .. ":" .. tostring(info.linedefined)
	if warned[name] then
		return
	end
	warned[name] = true
	if ErrorNoHalt then
		ErrorNoHalt("[GVoxel] Sonde vehicule non adaptee " .. name .. " : " .. tostring(reason) .. "\n")
	end
end
local function waterOnly(fn)
	if not MASK_WATER then
		return false
	end
	local found = false
	for i = 1, 128 do
		local name, value = debug.getupvalue(fn, i)
		if not name then
			break
		end
		if type(value) == "table" and rawget(value, "mask") ~= nil then
			if value.mask ~= MASK_WATER then
				return false
			end
			found = true
		end
	end
	return found
end
local function adapt(fn, visited)
	if functions[fn] then
		return functions[fn].adapted
	end
	if visited[fn] then
		return fn
	end
	visited[fn] = true
	local info = debug.getinfo(fn, "S")
	if not info or info.what ~= "Lua" then
		return fn
	end
	local env = getfenv(fn)
	-- Buoyancy asks for the native water surface, not solid terrain. Keeping
	-- the original closure also preserves its shared force/mass scratch cells.
	if waterOnly(fn) then
		functions[fn] = { env = env, adapted = fn }
		return fn
	end
	local proxy = proxies[env]
	if not proxy then
		proxy = setmetatable({ util = utilProxy }, { __index = env, __newindex = env })
		proxies[env] = proxy
	end
	local substitutions = {}
	for i = 1, 128 do
		local name, value = debug.getupvalue(fn, i)
		if not name then
			break
		end
		local replacement, changed = traceReplacement(name, value)
		if changed then
			substitutions[value] = replacement
		elseif type(value) == "function" then
			local source = debug.getinfo(value, "S")
			-- Only local helpers from the same vehicle source, not arbitrary
			-- engine/library functions captured by that method.
			if source and source.source == info.source then
				local helper = adapt(value, visited)
				if helper ~= value then
					substitutions[value] = helper
				end
			end
		end
	end
	local adapted = fn
	if next(substitutions) then
		-- A temporary shared-cell group rebuilds private helper closures as
		-- well. Their trace captures may not be captures of this entry method.
		substitutions.resolve = traceReplacement
		local clone, reason
		if V.CloneVehicleTraceMethod then
			clone, reason = V.CloneVehicleTraceMethod(fn, substitutions)
		end
		if clone then
			adapted = clone
			origins[clone] = fn
		else
			unsupported(info, reason or "reconstruction de methode indisponible")
		end
	end
	-- GMod removes debug.setupvalue/upvaluejoin. A source clone receives its
	-- captured trace explicitly; the original closure and its cells stay intact.
	setfenv(adapted, proxy)
	functions[fn] = { env = env, proxy = proxy, adapted = adapted }
	return adapted
end
local function patchTable(t)
	for key, fn in pairs(t) do
		if type(fn) == "function" then
			if not entryWrappers[fn] then
				fn = origins[fn] or fn
				local adapted = adapt(fn, {})
				if entryPoints[key] then
					local wrapper = wrappedEntry(adapted, fn)
					t[key] = wrapper
					installed[#installed + 1] = setmetatable(
						{ t = t, key = key, original = fn, wrapper = wrapper },
						{ __mode = "v" }
					)
				elseif adapted ~= fn then
					if t[key] ~= adapted then
						t[key] = adapted
						installed[#installed + 1] = setmetatable(
							{ t = t, key = key, original = fn, wrapper = adapted },
							{ __mode = "v" }
						)
					end
				else
					t[key] = fn
				end
			end
		end
	end
end
function V.AdaptVoxelVehicleEntity(ent)
	if debug and debug.getinfo and debug.getupvalue and ent.GetTable then
		patchTable(ent:GetTable())
	end
end
-- A shell can cross the entire cage before the periodic class pass runs.
-- Defer one tick so FireProjectile has installed its owner after Spawn, then
-- adapt the method copy on that entity, even after a late framework refresh.
-- Keep Glide's manual/underwater physics and collision groups untouched.
if SERVER then
	hook.Add("OnEntityCreated", "GVoxel.GlideProjectileTraces", function(ent)
		if not IsValid(ent) or not projectile(ent) then
			return
		end
		timer.Simple(0, function()
			if IsValid(ent) and projectile(ent) then
				V.AdaptVoxelVehicleEntity(ent)
			end
		end)
	end)
end
local componentBases = {
	glide_wheel = true,
	glide_projectile = true,
	glide_missile = true,
	lvs_wheeldrive_wheel = true,
	gmod_sent_vehicle_fphysics_wheel = true,
}
local function frameworkClass(name, t, seen)
	if V.IsVoxelProjectileClass and V.IsVoxelProjectileClass(name, t) then
		return true
	end
	if t.IsGlideVehicle or t.LVS or name == "gmod_sent_vehicle_fphysics_base" or componentBases[name] then
		return true
	end
	if not t.Base or seen[t.Base] then
		return false
	end
	seen[t.Base] = true
	local stored = scripted_ents.GetStored(t.Base)
	return stored and frameworkClass(t.Base, stored.t, seen) or false
end
function V.InstallVehicleAdapters()
	if not scripted_ents or not scripted_ents.GetList or not debug or not debug.getinfo or not debug.getupvalue then
		return
	end
	for i = #installed, 1, -1 do
		if not installed[i].t then
			table.remove(installed, i)
		end
	end
	for name, stored in pairs(scripted_ents.GetList()) do
		local t = stored.t
		if t and frameworkClass(name, t, {}) then
			patchTable(t)
		end
	end
	local r = region(true)
	if r and ents and ents.FindInBox then
		for _, ent in
			ipairs(
				ents.FindInBox(r.origin - Vector(128, 128, 128), r.origin + (V.RegionSize(r) + Vector(128, 128, 128)))
			)
		do
			if V.GetVoxelVehicleRoot(ent) then
				V.AdaptVoxelVehicleEntity(ent)
			end
		end
	end
end
function V.ReleaseVehicleAdapters()
	context = nil
	contextEntity = nil
	missileImpact = nil
	for _, row in ipairs(installed) do
		local t = row.t
		if t and t[row.key] == row.wrapper then
			t[row.key] = row.original
		end
	end
	for _, row in pairs(functions) do
		if getfenv(row.adapted) == row.proxy then
			setfenv(row.adapted, row.env)
		end
	end
	installed, functions = {}, setmetatable({}, { __mode = "k" })
	traceWrappers = setmetatable({}, { __mode = "k" })
	entryWrappers = setmetatable({}, { __mode = "k" })
	proxies = setmetatable({}, { __mode = "k" })
end
local nextInstall = 0
hook.Add("Think", "GVoxel.VehicleAdapters", function()
	if CurTime() < nextInstall then
		return
	end
	nextInstall = CurTime() + 2
	V.InstallVehicleAdapters()
end)
