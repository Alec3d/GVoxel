local V = GVoxel
local extraOwners = V.MeshExtraOwners or setmetatable({}, { __mode = "k" })
V.MeshExtraOwners = extraOwners

function V.RetainMesh(mesh)
	if not mesh or not mesh:IsValid() then
		return
	end
	extraOwners[mesh] = (extraOwners[mesh] or 0) + 1
	return mesh
end

-- Native meshes outlive Lua references and may already have been released.
-- Clear ownership before releasing: cancellation and refresh can overlap.
function V.ReleaseMesh(mesh)
	if not mesh then
		return
	end
	local owners = extraOwners[mesh]
	if owners then
		extraOwners[mesh] = owners > 1 and owners - 1 or nil
	elseif mesh:IsValid() then
		mesh:Destroy()
	end
end

function V.ReleaseChunkMeshes(chunk)
	if not chunk then
		return
	end
	local batches, mesh = chunk.batches, chunk.mesh
	chunk.batches = nil
	chunk.mesh = nil
	for _, batch in ipairs(batches or {}) do
		local object = batch.mesh
		local flashMesh = batch.flashMesh
		batch.mesh, batch.flashMesh = nil, nil
		V.ReleaseMesh(flashMesh)
		if mesh == object then
			mesh = nil
		end
		V.ReleaseMesh(object)
	end
	-- chunk.mesh is normally an alias, not another owner of the first batch.
	V.ReleaseMesh(mesh)
end

function V.DrawMesh(mesh)
	if not mesh or not mesh:IsValid() then
		return false
	end
	mesh:Draw()
	return true
end
