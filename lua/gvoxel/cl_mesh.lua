local V = GVoxel

-- Native meshes outlive Lua references and may already have been released.
-- Clear ownership before releasing: cancellation and refresh can overlap.
function V.ReleaseMesh(mesh)
	if mesh and mesh:IsValid() then
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
		batch.mesh = nil
		V.ReleaseMesh(object)
	end
	-- chunk.mesh usually aliases the first batch. IsValid avoids a double free.
	V.ReleaseMesh(mesh)
end

function V.DrawMesh(mesh)
	if not mesh or not mesh:IsValid() then
		return false
	end
	mesh:Draw()
	return true
end
