-- Menu, reload gesture and overlays. All geometry lives in the scan modules.
local V = GVoxel
if V.CloseScanMenu then
	V.CloseScanMenu(false)
end
local metresConVar = CreateClientConVar("vm_zone_metres", "16", true, false, "Cote du cube analyse, en metres", 16, 32)
local useMapBSP = CreateClientConVar("vm_scan_bsp", "1", true, false, "Use compiled map geometry when scanning")
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
local placementTrace, placing
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
function V.IsPlacingZone()
	return placing
end
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

local blue = Color(0, 150, 253)
local orange = Color(253, 151, 12)
local background = Color(14, 22, 32, 247)
local card = Color(29, 44, 59)
local hover = Color(42, 63, 82)
local selected = Color(18, 69, 108)
local muted = Color(174, 195, 211)
local danger, dangerHover = Color(155, 33, 44), Color(190, 42, 52)
local accentText = Color(32, 21, 12)
local flags = {en = "gb", fr = "fr", ru = "ru", es = "es", it = "it", de = "de"}
local addPower = CreateClientConVar("vm_add_power", "100", true, true, "Addition volume percentage", 10, 100)
local lastX, lastY

-- Roboto ships with Garry's Mod. The extended glyph range includes Cyrillic.
local fonts = {
	brand = "GVoxel.MenuBrand",
	action = "GVoxel.MenuAction",
	label = "GVoxel.MenuLabel",
	detail = "GVoxel.MenuDetail",
	status = "GVoxel.ScanTitle",
}
if not V.ToolFontsRegistered then
	for _, font in ipairs({
		{ fonts.brand, 30, 900 },
		{ fonts.action, 18, 700 },
		{ fonts.label, 16, 600 },
		{ fonts.detail, 14, 500 },
		{ fonts.status, 21, 700 },
	}) do
		surface.CreateFont(font[1], {
			font = system.IsLinux() and "Roboto-Regular" or "Roboto",
			size = font[2],
			weight = font[3],
			antialias = true,
			extended = true,
		})
	end
	V.ToolFontsRegistered = true
end

local settingsIcon = Material("icon16/cog.png", "smooth")

local function fitsFont(text, font, fallback, width)
	surface.SetFont(font)
	if surface.GetTextSize(text) <= width then return font end
	return fallback
end

function V.GetAddPower()
	return addPower:GetInt()
end

local function saveableZone()
	local zone = V.GetClientScanState()
	return zone and zone.visualReady and zone or nil
end

function V.OpenZoneSaveOptions(id, name)
	local zone = saveableZone()
	if not activeWeapon() or not zone or (id and zone.region.id ~= id) then return end
	local function save(action)
		if not activeWeapon() or saveableZone() ~= zone then return end
		net.Start("vm_zones_action")
		net.WriteString(action)
		net.WriteUInt(zone.region.id, 16)
		net.WriteString("")
		net.WriteString((name or ""):sub(1, 64))
		net.SendToServer()
	end
	Derma_Query(V.L("Choisir la version de la zone a sauvegarder"), V.L("Sauvegarder la zone"),
		V.L("Avec destructions"), function() save("save") end,
		V.L("Sans destructions"), function() save("save_clean") end,
		V.L("Annuler"))
end

function V.OpenScanMenu()
	local weapon = activeWeapon()
	if not weapon or IsValid(menu) then return end

	local frame = vgui.Create("DFrame")
	menu = frame
	frame:SetSize(math.min(480, ScrW() - 16), 510)
	frame:SetPos(math.Clamp(lastX or ScrW() - frame:GetWide() - 24, 0, ScrW() - frame:GetWide()),
		math.Clamp(lastY or 90, 0, math.max(0, ScrH() - frame:GetTall())))
	frame:SetTitle("")
	frame:SetDeleteOnClose(true)
	frame:MakePopup()
	frame:SetKeyboardInputEnabled(false)
	frame.VMMetres = V.SelectedMetres()
	frame.Paint = function(_, w, h)
		draw.RoundedBox(12, 0, 0, w, h, background)
		draw.RoundedBox(4, 16, 13, 4, 25, blue)
		local edge = draw.SimpleText("G", fonts.brand, 29, 9, blue)
		draw.SimpleText("Voxel", fonts.brand, 29 + edge, 9, orange)
		surface.SetDrawColor(card)
		surface.DrawRect(16, 69, w - 32, 1)
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
		flag:SetPos(frame:GetWide() - 36 - (#V.LanguageOptions - i) * 24, 44)
		flag:SetTooltip(option[2])
		flag.DoClick = function() RunConsoleCommand("gvoxel_language", option[1]) end
	end

	local content = vgui.Create("DPanel", frame)
	content:Dock(FILL)
	content:DockMargin(10, 52, 10, 9)
	content:SetPaintBackground(false)

	local function button(parent, label, action, style, isSelected, isAvailable)
		local control = vgui.Create("DButton", parent)
		control:SetText("")
		control.Paint = function(self, w, h)
			local available = not isAvailable or isAvailable()
			local hovered = available and self:IsHovered()
			local active = isSelected and isSelected()
			local fill = hovered and hover or card
			local ink = available and color_white or muted
			if style == "primary" and available then
				fill, ink = hovered and color_white or orange, accentText
			elseif style == "danger" and available then
				fill = hovered and dangerHover or danger
			elseif active then
				fill = selected
			end
			draw.RoundedBox(7, 0, 0, w, h, fill)
			if label then
				local text = label()
				local font = (style == "primary" or style == "danger") and fonts.action or fonts.label
				font = fitsFont(text, font, fonts.detail, w - 10)
				draw.SimpleText(text, font, w / 2, h / 2, ink, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
			else
				surface.SetMaterial(settingsIcon)
				surface.SetDrawColor(ink)
				surface.DrawTexturedRect(math.floor((w - 16) / 2), math.floor((h - 16) / 2), 16, 16)
			end
			if active then
				draw.RoundedBox(2, 7, h - 4, w - 14, 2, blue)
			end
		end
		control.DoClick = function()
			if not isAvailable or isAvailable() then action() end
		end
		return control
	end

	local actions = vgui.Create("DPanel", content)
	actions:Dock(TOP)
	actions:SetTall(44)
	actions:SetPaintBackground(false)
	local create = button(actions, function() return V.L("Creer une nouvelle zone") end, function()
		placing = true
		V.CloseScanMenu(true)
	end, "primary", nil, function() return not V.GetClientScanState() end)
	create:Dock(FILL)

	local function section(label)
		local heading = vgui.Create("DLabel", content)
		heading:Dock(TOP)
		heading:DockMargin(2, 9, 0, 4)
		heading:SetTall(20)
		heading:SetFont(fonts.label)
		heading:SetTextColor(muted)
		heading:SetText(V.L(label))
	end
	section("Dimensions / boite personnalisee")

	local choices = vgui.Create("DPanel", content)
	choices:Dock(TOP)
	choices:SetTall(31)
	choices:SetPaintBackground(false)
	for _, size in ipairs(V.ScanSizes) do
		local option = button(choices, function()
			return size .. " × " .. size .. " m"
		end, function()
			frame.VMMetres = size
			RunConsoleCommand("vm_custom_block", "0")
		end, nil, function() return not V.CustomBlockEnabled() and frame.VMMetres == size end)
		option:Dock(LEFT)
		option:DockMargin(0, 0, 5, 0)
		option:SetWide(79)
	end
	local custom = button(choices, function()
		return V.L("Boite sur mesure")
	end, function() RunConsoleCommand("vm_custom_block", "1") end, nil, V.CustomBlockEnabled)
	custom:Dock(FILL)

	local points = vgui.Create("DPanel", content)
	points:Dock(TOP)
	points:DockMargin(0, 6, 0, 0)
	points:SetTall(28)
	points:SetPaintBackground(false)
	local undo = button(points, function() return V.L("Retirer le dernier point") end, V.UndoCustomBlockSelection, nil, nil, V.CustomBlockEnabled)
	undo:Dock(LEFT)
	undo:SetWide(math.floor((frame:GetWide() - 26) / 2))
	button(points, function() return V.L("Recommencer la boite") end, V.ResetCustomBlockSelection, nil, nil, V.CustomBlockEnabled):Dock(FILL)

	local modes = vgui.Create("DPanel", content)
	modes:Dock(TOP)
	modes:DockMargin(0, 9, 0, 0)
	modes:SetTall(30)
	modes:SetPaintBackground(false)
	local bspMode = button(modes, function()
		local data, done = V.GetBSPGeometry()
		local label = data and "BSP pret" or (done and "BSP indisponible" or "Chargement du BSP")
		return V.L(label)
	end, function()
		RunConsoleCommand("vm_scan_bsp", "1")
		V.PrepareMapBSP()
	end, nil, function() return useMapBSP:GetBool() end)
	bspMode:SetTooltip(V.L("Utiliser la geometrie et les materiaux du BSP"))
	bspMode:Dock(LEFT)
	bspMode:SetWide(math.floor((frame:GetWide() - 24) / 2))
	bspMode:DockMargin(0, 0, 5, 0)
	button(modes, function()
		return V.L("Analyse par rayons")
	end, function() RunConsoleCommand("vm_scan_bsp", "0") end, nil, function() return not useMapBSP:GetBool() end):Dock(FILL)

	local function slider(label, minimum, maximum, value)
		local control = vgui.Create("DNumSlider", content)
		control:Dock(TOP)
		control:SetTall(39)
		control:SetText(V.L(label))
		control.Label:SetFont(fonts.detail)
		control.Label:SetWrap(true)
		control.Label:SetTextColor(color_white)
		control:GetTextArea():SetFont(fonts.label)
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

	local remove = button(content, function() return V.L("Supprimer la zone") end, function()
		local zone = V.GetClientScanState()
		Derma_Query(V.L("Supprimer la zone et sa sauvegarde ?"), "GVoxel", V.L("Supprimer la zone"), function()
			if not activeWeapon() or V.GetClientScanState() ~= zone then return end
			net.Start("vm_zones_action")
			net.WriteString("delete_zone")
			net.WriteUInt(zone and zone.region.id or 0, 16)
			net.WriteString("")
			net.WriteString("")
			net.SendToServer()
			V.CloseScanMenu(true)
		end, V.L("Annuler"))
	end, "danger")
	remove:Dock(BOTTOM)
	remove:SetTall(34)
	remove:DockMargin(0, 6, 0, 0)

	local footer = vgui.Create("DPanel", content)
	footer:Dock(BOTTOM)
	footer:SetTall(30)
	footer:SetPaintBackground(false)
	local save = button(footer, function() return V.L("Sauvegarder la zone") end, function()
		V.OpenZoneSaveOptions()
	end, "primary", nil, saveableZone)
	local view = button(footer, nil, function()
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
	save:Dock(FILL)
	local help = vgui.Create("DLabel", content)
	help:Dock(FILL)
	help:SetWrap(true)
	help:SetFont(fonts.detail)
	help:SetTextColor(muted)
	help:SetText(V.L("Ouvrir et placer une zone"))
end

local function requestScan()
	if not activeWeapon() then return end
	local data, done = V.GetBSPGeometry()
	local byRays = not useMapBSP:GetBool() or (done and not data)
	local suffix = byRays and "_rays" or ""
	if V.CustomBlockEnabled() then
		local low, high = V.CustomBlockScanBounds()
		if not low then
			LocalPlayer():ChatPrint("[GVoxel] " .. V.L(high))
			return
		end
		net.Start("vm_scan_custom" .. suffix)
		net.WriteVector(low)
		net.WriteVector(high)
		net.SendToServer()
		return
	end
	net.Start("vm_scan_request" .. suffix)
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
		if placing and not V.GetClientScanState() then
			requestScan()
		else
			V.OpenScanMenu()
		end
	end
	if not weapon or V.GetClientScanState() then placing = nil end
	if IsValid(menu) and not weapon then
		V.CloseScanMenu(false)
	end
end)

hook.Add("Think", "GVoxel.PlacementPreview", function()
	local weapon = activeWeapon()
	if not weapon or not placing or not showBounds:GetBool() or V.CustomBlockEnabled() then
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
	if not scan then V.DrawCustomBlockPreview() end
	if showBounds:GetBool() then
		-- Placement uses the original BSP, exactly like the server scan.
		-- A long voxel DDA here is both incorrect inside a hole and costly.
		local tr = placementTrace or {}
		if placing and not V.CustomBlockEnabled() and tr.HitWorld and not tr.HitSky then
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
	if not activeWeapon() then return end
	local scan = V.GetClientScanState()
	if not scan and not placing then return end

	local title, detail, ratio
	if not scan then
		title = V.L("Placer la zone")
		detail = V.CustomBlockEnabled() and V.CustomBlockStatus() or V.L("Viser la carte puis appuyer sur R.")
	elseif scan.visualReady then
		title = V.L("Zone prete")
		ratio = 1
	elseif scan.phase == 0 then
		title = string.format(V.L("Analyse de la zone : %d %%"), math.floor(scan.ratio * 100))
		ratio = scan.ratio
	elseif scan.densityReady and scan.built < scan.chunkCount then
		title = V.L("Preparation des blocs")
		ratio = scan.built / scan.chunkCount
	elseif scan.phase ~= 2 then
		title = V.L("Reception du terrain...")
	else
		local done, total = scan.region.surfaceFinished or 0, #(scan.region.surfaceList or {})
		if done < total then
			title = string.format(V.L("Capture des textures du sol : %d / %d"), done, total)
			ratio = done / total
		else
			title = V.L("Finalisation de la zone")
		end
	end

	local width = math.min(460, ScrW() - 32)
	local x, y = (ScrW() - width) / 2, ScrH() - 187
	draw.RoundedBox(10, x, y, width, 74, background)
	local accent = scan and scan.visualReady and blue or orange
	draw.RoundedBox(3, x + 10, y + 12, 3, 17, accent)
	local titleFont = fitsFont(title, fonts.status, fonts.label, width - 38)
	draw.SimpleText(title, titleFont, x + 21, y + 8, color_white)
	if scan then
		local elapsed = ((scan.readyAt or SysTime()) - scan.clientStarted) * 1000
		draw.SimpleText(string.format("%.0f ms", elapsed), fonts.action,
			x + width - 14, y + 34, accent, TEXT_ALIGN_RIGHT)
		if scan.chunkCount > 0 then
			detail = string.format(V.L("%d / %d blocs"), scan.built, scan.chunkCount)
		end
	end
	if detail then
		draw.DrawText(detail, fonts.detail, x + 21, y + 36, muted)
	end
	if scan then
		local track = width - 28
		local length = ratio and track * math.Clamp(ratio, 0, 1) or track / 5
		local offset = ratio and 0 or (track - length) * (0.5 - 0.5 * math.cos(RealTime() * 4))
		draw.RoundedBox(2, x + 14, y + 61, track, 4, card)
		if length >= 1 then
			draw.RoundedBox(2, x + 14 + offset, y + 61, length, 4, accent)
		end
	end
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
