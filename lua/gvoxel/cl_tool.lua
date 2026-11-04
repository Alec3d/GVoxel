-- Menu, reload gesture and overlays. All geometry lives in the scan modules.
local V = GVoxel
if V.CloseScanMenu then
	V.CloseScanMenu(false)
end
local metresConVar = CreateClientConVar("vm_zone_metres", "16", true, false, "Cote du cube analyse, en metres", 16, 32)
local showBounds = CreateClientConVar(
	"vm_show_zone",
	"1",
	true,
	false,
	"Afficher les limites de selection et de la zone analysee",
	0,
	1
)
local showWire =
	CreateClientConVar("vm_show_wireframe", "0", true, false, "Afficher le maillage du releve en fil de fer", 0, 1)
local wireMaterial = CreateMaterial("vm_scan_wire_v1", "UnlitGeneric", {
	["$basetexture"] = "color/white",
	["$wireframe"] = "1",
	["$nocull"] = "1",
})
local menu, gesture = nil, {}
local placementTrace
function V.SelectedMetres()
	local value = metresConVar:GetInt()
	return V.ValidScanSize(value) and value or 16
end

local function activeWeapon()
	local ply = LocalPlayer()
	if not IsValid(ply) then
		return
	end
    if not ply:IsAdmin() then return end
	local weapon = ply:GetActiveWeapon()
	if V.IsVoxelTool(weapon) then
		return weapon
	end
end

V.GetActiveVoxelTool = activeWeapon
local function sendSettings(metres, radius)
	RunConsoleCommand("vm_zone_metres", tostring(metres))
	net.Start("vm_scan_settings")
	net.WriteUInt(metres, 6)
	net.WriteUInt(radius, 7)
	net.SendToServer()
end

function V.CloseScanMenu(save)
	if not IsValid(menu) then
		return
	end
	local frame = menu
	if save then
		sendSettings(frame.VMMetres, math.Round(frame.VMRadius:GetValue()))
	end
	menu = nil
	frame:Remove()
	gesture = {}
end

function V.OpenScanMenu()
	local weapon = activeWeapon()
	if not weapon or IsValid(menu) then
		return
	end
	local frame = vgui.Create("DFrame")
	menu = frame
	frame:SetSize(580, 620)
	frame:Center()
	frame:SetTitle(V.L("GVoxel — dimensions de la zone"))
	frame:SetDeleteOnClose(true)
	frame:MakePopup()
	frame.VMMetres = V.SelectedMetres()
	frame.OnClose = function()
		sendSettings(frame.VMMetres, math.Round(frame.VMRadius:GetValue()))
		gesture = {}
	end

	local title = vgui.Create("DLabel", frame)
	title:SetPos(18, 38)
	title:SetSize(544, 45)
	title:SetText(V.L("Relache R pour utiliser ce menu.\nR court lance l'analyse de la selection."))
	local choices = {}
	for i, metres in ipairs(V.ScanSizes) do
		local button = vgui.Create("DButton", frame)
		button:SetPos(18 + (i - 1) * 277, 91)
		button:SetSize(267, 48)
		choices[metres] = button
		local function refresh()
			for size, b in pairs(choices) do
				b:SetText(
					(size == frame.VMMetres and V.L("[ Selectionne ] ") or "")
						.. size
						.. " x "
						.. size
						.. " x "
						.. size
						.. " m"
				)
			end
		end
		frame.VMRefreshSizes = refresh
		button.DoClick = function()
			frame.VMMetres = metres
			RunConsoleCommand("vm_custom_block", "0")
			refresh()
		end
		refresh()
	end
	local custom = vgui.Create("DCheckBoxLabel", frame)
	custom:SetPos(18, 149)
	custom:SetSize(544, 23)
	custom:SetText(V.L("Custom block — boite rectangulaire a 4 points"))
	custom:SetConVar("vm_custom_block")
	local help = vgui.Create("DLabel", frame)
	help:SetPos(18, 178)
	help:SetSize(544, 72)
	help:SetWrap(true)
	help:SetText(
		V.L("Molette : depart, largeur X, longueur Y, hauteur.\nPuis molette : deplacer / verrouiller. R : analyser.\nDimensions ajustees a la grille ; maximum 32 m par axe.")
	)
	local undo = vgui.Create("DButton", frame)
	undo:SetPos(18, 254)
	undo:SetSize(267, 27)
	undo:SetText(V.L("Retirer le dernier point"))
	undo.DoClick = function()
		V.UndoCustomBlockSelection()
	end
	local reset = vgui.Create("DButton", frame)
	reset:SetPos(295, 254)
	reset:SetSize(267, 27)
	reset:SetText(V.L("Recommencer la boite"))
	reset.DoClick = function()
		V.ResetCustomBlockSelection()
	end
	local slider = vgui.Create("DNumSlider", frame)
	slider:SetPos(18, 290)
	slider:SetSize(544, 46)
	slider:SetText(V.L("Rayon de l'outil (unites)"))
	slider:SetMin(24)
	slider:SetMax(80)
	slider:SetDecimals(0)
	slider:SetValue(math.max(24, weapon:GetBrushRadius()))
	frame.VMRadius = slider
	for i, option in ipairs({
		{ V.L("Afficher les limites des zones"), "vm_show_zone" },
		{ V.L("Afficher le releve en fil de fer"), "vm_show_wireframe" },
		{ V.L("Afficher le viseur de creusement"), "vm_show_cursor" },
		{ V.L("Remplacer visuellement le BSP"), "vm_replace_visual" },
	}) do
		local check = vgui.Create("DCheckBoxLabel", frame)
		check:SetPos(18, 346 + (i - 1) * 27)
		check:SetSize(544, 23)
		check:SetText(option[1])
		check:SetConVar(option[2])
	end
	local info = vgui.Create("DLabel", frame)
	info:SetPos(18, 461)
	info:SetSize(544, 78)
	info:SetWrap(true)
	info:SetText(
		V.L("Une zone partagee par serveur. Gauche : creuser ; droite : ajouter. Les modifications attendent la preparation des collisions et des clients.")
	)
	local cancel = vgui.Create("DButton", frame)
	cancel:SetPos(18, 560)
	cancel:SetSize(260, 42)
	cancel:SetText(V.L("Annuler / effacer le releve"))
	cancel.DoClick = function()
		net.Start("vm_scan_cancel")
		net.SendToServer()
	end
	local close = vgui.Create("DButton", frame)
	close:SetPos(290, 560)
	close:SetSize(272, 42)
	close:SetText(V.L("Enregistrer et fermer"))
	close.DoClick = function()
		V.CloseScanMenu(true)
	end
end

local function requestScan()
	if V.CustomBlockEnabled() then
		local low, high = V.CustomBlockScanBounds()
		if not low then
			LocalPlayer():ChatPrint("[GVoxel] " .. V.L(high))
			return
		end
		net.Start("vm_scan_custom")
		net.WriteVector(low)
		net.WriteVector(high)
		net.SendToServer()
		return
	end
	net.Start("vm_scan_request")
	net.WriteUInt(V.SelectedMetres(), 6)
	net.SendToServer()
end
concommand.Add("vm_scan", requestScan)
concommand.Add("vm_menu", function()
	V.OpenScanMenu()
end)

hook.Add("Think", "GVoxel.ReloadGesture", function()
	local weapon = activeWeapon()
	local allowed = weapon
		and LocalPlayer():Alive()
		and not IsValid(menu)
		and not gui.IsGameUIVisible()
		and not gui.IsConsoleVisible()
		and not vgui.CursorVisible()
	local down = weapon and LocalPlayer():KeyDown(IN_RELOAD) or false
	local action = V.ReloadGesture(gesture, down, RealTime(), allowed)
	if action == "menu" then
		V.OpenScanMenu()
	elseif action == "tap" then
		requestScan()
	end
	if IsValid(menu) and not weapon then
		V.CloseScanMenu(false)
	end
end)

hook.Add("Think", "GVoxel.PlacementPreview", function()
	local weapon = activeWeapon()
	if not weapon or not showBounds:GetBool() or V.CustomBlockEnabled() then
		placementTrace = nil
		return
	end
	local ply = LocalPlayer()
	local pos, dir = ply:GetShootPos(), ply:GetAimVector()
	if placementTrace and placementTrace.start == pos and placementTrace.direction == dir then
		return
	end
	placementTrace = V.Trace(ply, 2048)
	placementTrace.start = pos
	placementTrace.direction = dir
end)
hook.Add("PostDrawTranslucentRenderables", "GVoxel.SelectionCube", function(depth, _, sky3D)
	local scan = V.GetClientScanState()
	if depth or sky3D or V.MaskInSkybox or V.RenderingReplacement or V.ComposingTerrain or not activeWeapon() then
		return
	end
	V.DrawCustomBlockPreview()
	if showBounds:GetBool() then
		-- Placement uses the original BSP, exactly like the server scan.
		-- A long voxel DDA here is both incorrect inside a hole and costly.
		local tr = placementTrace or {}
		if not V.CustomBlockEnabled() and tr.HitWorld and not tr.HitSky then
			local half = V.SelectedMetres() * V.UnitsPerMetre / 2
			render.DrawWireframeBox(
				V.SnapScanPosition(tr.HitPos),
				angle_zero,
				Vector(-half, -half, -half),
				Vector(half, half, half),
				Color(95, 190, 255),
				true
			)
		end
		if scan then
			local r = scan.region
			render.DrawWireframeBox(r.origin, angle_zero, Vector(), V.RegionSize(r), Color(255, 185, 65), true)
		end
	end
	if not showWire:GetBool() or not scan then
		return
	end
	render.SetMaterial(wireMaterial)
	local r = scan.region
	local frustum = V.ViewFrustum(render.GetViewSetup(true), ScrW(), ScrH())
	for _, chunk in pairs(r.chunks) do
		if chunk.mesh and V.BoundsInView(frustum, chunk.low, chunk.high) then
			cam.PushModelMatrix(chunk.transform)
			if chunk.batches then
				for _, batch in ipairs(chunk.batches) do
					V.DrawMesh(batch.mesh)
				end
			else
				V.DrawMesh(chunk.mesh)
			end
			cam.PopModelMatrix()
		end
	end
end)

hook.Add("HUDPaint", "GVoxel.ScanStatus", function()
	local scan = V.GetClientScanState()
	if not scan or not activeWeapon() then
		return
	end
	local text
	if scan.phase == 0 then
		text = string.format(V.L("Analyse de la zone : %d %%"), scan.ratio * 100)
	elseif scan.built < 64 then
		text = string.format(V.L("Preparation du terrain : %d / 64 blocs"), scan.built)
	elseif scan.phase ~= 2 then
		text = V.L("Reception du terrain...")
	elseif not scan.visualReady then
		text = string.format(
			V.L("Capture des textures du sol : %d / %d"),
			scan.region.surfaceFinished or 0,
			#(scan.region.surfaceList or {})
		)
	else
		text = string.format(
			V.L("Analyse terminee — %.1f s — %d rayons | %s — terrain voxel praticable"),
			scan.elapsed,
			scan.rays,
			V.VisualReplacementEnabled() and V.L("Rendu voxel actif") or V.L("Rendu voxel desactive")
		)
	end
	draw.SimpleTextOutlined(
		text,
		"Trebuchet18",
		ScrW() / 2,
		ScrH() - 180,
		Color(255, 195, 85),
		TEXT_ALIGN_CENTER,
		TEXT_ALIGN_CENTER,
		1,
		color_black
	)
end)

-- Reopen with the current settings so all labels update without losing a draft.
hook.Add("GVoxel.LanguageChanged", "GVoxel.ScanMenuLanguage", function()
    if not IsValid(menu) then return end
    local metres, radius = menu.VMMetres, menu.VMRadius:GetValue()
    V.CloseScanMenu(false)
    V.OpenScanMenu()
    if IsValid(menu) then
        menu.VMMetres = metres
        menu.VMRefreshSizes()
        menu.VMRadius:SetValue(radius)
    end
end)
