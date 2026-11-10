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

local blue = Color(39, 153, 240)
local orange = Color(255, 151, 62)
local background = Color(18, 25, 32, 250)
local card = Color(43, 61, 75)
local hover = Color(57, 80, 99)
local accentText = Color(32, 21, 12)
local flags = {en = "gb", fr = "fr", ru = "ru", es = "es", it = "it", de = "de"}
local addPower = CreateClientConVar("vm_add_power", "100", true, true, "Addition volume percentage", 10, 100)
local lastX, lastY

function V.GetAddPower()
	return addPower:GetInt()
end

function V.OpenScanMenu()
	local weapon = activeWeapon()
	if not weapon or IsValid(menu) then return end

	local frame = vgui.Create("DFrame")
	menu = frame
	frame:SetSize(math.min(470, ScrW() - 16), 388)
	frame:SetPos(math.Clamp(lastX or ScrW() - frame:GetWide() - 24, 0, ScrW() - frame:GetWide()),
		math.Clamp(lastY or 90, 0, math.max(0, ScrH() - frame:GetTall())))
	frame:SetTitle("")
	frame:SetDeleteOnClose(true)
	frame:MakePopup()
	frame:SetKeyboardInputEnabled(false)
	frame.VMMetres = V.SelectedMetres()
	frame.Paint = function(_, w, h)
		draw.RoundedBox(9, 0, 0, w, h, background)
		draw.SimpleText("GVoxel", "Trebuchet24", 15, 12, blue)
		surface.SetDrawColor(orange)
		surface.DrawRect(14, 43, w - 28, 2)
	end
	frame.OnRemove = function()
		lastX, lastY = frame:GetPos()
		if menu == frame then menu = nil end
		gesture = {}
	end
	frame.OnClose = function()
		sendSettings(frame.VMMetres, math.Round(frame.VMRadius:GetValue()))
	end

	for i, option in ipairs(V.LanguageOptions) do
		local flag = vgui.Create("DImageButton", frame)
		flag:SetImage("flags16/" .. flags[option[1]] .. ".png")
		flag:SetSize(20, 16)
		flag:SetPos(frame:GetWide() - 46 - (6 - i) * 24, 16)
		flag:SetTooltip(option[2])
		flag.DoClick = function() RunConsoleCommand("gvoxel_language", option[1]) end
	end

	local content = vgui.Create("DPanel", frame)
	content:Dock(FILL)
	content:DockMargin(8, 26, 8, 5)
	content:SetPaintBackground(false)

	local function button(parent, label, action, accent)
		local control = vgui.Create("DButton", parent)
		control:SetText("")
		control.Paint = function(self, w, h)
			draw.RoundedBox(5, 0, 0, w, h, accent and orange or (self:IsHovered() and hover or card))
			draw.SimpleText(label(), "Trebuchet18", w / 2, h / 2,
				accent and accentText or color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		end
		control.DoClick = action
		return control
	end

	local create = button(content, function() return V.L("Nouvelle zone") end, function()
		local function startPlacement()
			RunConsoleCommand("vm_give")
			if V.CustomBlockEnabled() then V.ResetCustomBlockSelection() end
			V.CloseScanMenu(true)
		end
		if V.GetClientScanState() then
			Derma_Query(V.L("Une seule zone est autorisee. Retirer la zone actuelle avant d'en creer une autre."),
				"GVoxel", V.L("Retirer la zone active"), function()
					net.Start("vm_scan_cancel")
					net.SendToServer()
					startPlacement()
				end, V.L("Annuler"))
			return
		end
		startPlacement()
	end, true)
	create:Dock(TOP)
	create:SetTall(34)

	local choices = vgui.Create("DPanel", content)
	choices:Dock(TOP)
	choices:DockMargin(0, 8, 0, 0)
	choices:SetTall(31)
	choices:SetPaintBackground(false)
	for _, size in ipairs(V.ScanSizes) do
		local option = button(choices, function()
			return (not V.CustomBlockEnabled() and frame.VMMetres == size and "✓ " or "") .. size .. " m"
		end, function()
			frame.VMMetres = size
			RunConsoleCommand("vm_custom_block", "0")
		end)
		option:Dock(LEFT)
		option:DockMargin(0, 0, 5, 0)
		option:SetWide(70)
	end
	local custom = button(choices, function()
		return (V.CustomBlockEnabled() and "✓ " or "") .. V.L("Boite sur mesure")
	end, function() RunConsoleCommand("vm_custom_block", "1") end)
	custom:Dock(FILL)

	local points = vgui.Create("DPanel", content)
	points:Dock(TOP)
	points:DockMargin(0, 6, 0, 0)
	points:SetTall(28)
	points:SetPaintBackground(false)
	local undo = button(points, function() return V.L("Retirer le dernier point") end, V.UndoCustomBlockSelection)
	undo:Dock(LEFT)
	undo:SetWide(math.floor((frame:GetWide() - 26) / 2))
	button(points, function() return V.L("Recommencer la boite") end, V.ResetCustomBlockSelection):Dock(FILL)

	local function slider(label, minimum, maximum, value)
		local control = vgui.Create("DNumSlider", content)
		control:Dock(TOP)
		control:SetTall(39)
		control:SetText(V.L(label))
		control.Label:SetTextColor(color_white)
		control:SetMinMax(minimum, maximum)
		control:SetDecimals(0)
		control:SetValue(value)
		return control
	end
	frame.VMRadius = slider("Rayon de l'outil (unites)", 24, 80, math.max(24, weapon:GetBrushRadius()))
	local power = slider("Volume d'ajout (%)", 10, 100, addPower:GetInt())
	power.OnValueChanged = function(_, value)
		local rounded = math.Round(value)
		if rounded ~= addPower:GetInt() then RunConsoleCommand("vm_add_power", tostring(rounded)) end
	end

	local footer = vgui.Create("DPanel", content)
	footer:Dock(BOTTOM)
	footer:SetTall(30)
	footer:SetPaintBackground(false)
	local saved = button(footer, function() return V.L("Zones sauvegardees") end, function()
		V.CloseScanMenu(true)
		V.OpenSavedZones()
	end)
	local view = button(footer, function() return "⚙" end, function()
		local options = DermaMenu()
		for _, setting in ipairs({
			{"Afficher les limites des zones", "vm_show_zone"},
			{"Afficher le releve en fil de fer", "vm_show_wireframe"},
			{"Afficher le viseur de creusement", "vm_show_cursor"},
			{"Remplacer visuellement le BSP", "vm_replace_visual"},
		}) do
			local enabled = GetConVar(setting[2]):GetBool()
			options:AddOption((enabled and "✓ " or "") .. V.L(setting[1]), function()
				RunConsoleCommand(setting[2], enabled and "0" or "1")
			end)
		end
		options:Open()
	end)
	view:SetTooltip(V.L("Afficher les limites des zones"))
	view:Dock(RIGHT)
	view:SetWide(34)
	view:DockMargin(5, 0, 0, 0)
	saved:Dock(FILL)
	local help = vgui.Create("DLabel", content)
	help:Dock(FILL)
	help:SetWrap(true)
	help:SetTextColor(color_white)
	help:SetText(V.L("Commandes GVoxel"))
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

local shortcutDown = false
hook.Add("Think", "GVoxel.ReloadGesture", function()
	local weapon = activeWeapon()
	local allowed = weapon
		and LocalPlayer():Alive()
		and not IsValid(menu)
		and not gui.IsGameUIVisible()
		and not gui.IsConsoleVisible()
		and not vgui.CursorVisible()
	local shortcut = input.IsKeyDown(KEY_H)
		and (input.IsKeyDown(KEY_LCONTROL) or input.IsKeyDown(KEY_RCONTROL))
	if shortcut and not shortcutDown then
		if IsValid(menu) then
			V.CloseScanMenu(true)
		elseif allowed and not IsValid(vgui.GetKeyboardFocus()) then
			V.OpenScanMenu()
			allowed = false
		end
	end
	shortcutDown = shortcut
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
	elseif scan.densityReady and scan.built < scan.chunkCount then
		text = string.format(V.L("Preparation du terrain : %d / %d blocs"), scan.built, scan.chunkCount)
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
        menu.VMRadius:SetValue(radius)
    end
end)
