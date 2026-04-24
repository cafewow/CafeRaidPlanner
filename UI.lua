local _, CRP = ...

CRP.ui = CRP.ui or {}
local Window = {}
CRP.ui.Window = Window

local RAID_W, RAID_H = 420, 620
local MY_W, MY_H = 360, 320
local ROW_H = 28

-- Upcoming-pulls preview
local UPCOMING_COUNT = 3
local UPCOMING_ROW_H = 20
local UPCOMING_HEADER_H = 18
local UPCOMING_HEIGHT = UPCOMING_HEADER_H + UPCOMING_COUNT * UPCOMING_ROW_H + 8
local UPCOMING_ICON = 16
local UPCOMING_MAX_ICONS = 6

local frame, content
local pendingItemIds = {} -- items whose info was nil; refresh when GET_ITEM_INFO_RECEIVED fires
local assignRowPool = {}
local buildPullPopup, refreshPullPopupRows -- forward decls; defined later in file
local progressLines = {} -- FontString pool for "kills/required mob" rows
local packLine, bossLine, noteBox, pullTitle, pullCounter, prevBtn, nextBtn, emptyMsg
local progressHeader, progressAnchor
local pushBtn, importBtn, modeBtn
local importDialog
local upcomingContainer, upcomingHeader, upcomingRows = nil, nil, {}

local function currentMode()
	return (CRP.db and CRP.db.char and CRP.db.char.viewMode) or "raid"
end

local function isMyView()
	return currentMode() == "my"
end

-- Strip realm suffix from a name like "Gustaf-Gehennas".
local function stripRealm(name)
	if not name or name == "" then
		return name
	end
	return (name:match("^([^-]+)")) or name
end

-- True iff the assignment has enough data to be worth rendering. Blank rows
-- (freshly added but unfilled) are skipped in the current-pull list and the
-- upcoming preview.
local function hasContent(a)
	if not a then
		return false
	end
	if a.kind == "reminder" then
		return a.text ~= nil and a.text ~= ""
	end
	-- spell, item, equip all need a numeric id
	return type(a.id) == "number"
end

-- Assignment filter for My view:
--   - player set:   only if it matches me (case-insensitive, realm-stripped)
--   - player empty: items and reminders always pass (no way to class-filter
--                   a free-text reminder); spells only if I know them.
local function isMyAssignment(a)
	if not a then
		return false
	end
	local player = a.player or ""
	if player ~= "" then
		local me = UnitName("player") or ""
		return stripRealm(player):lower() == stripRealm(me):lower()
	end
	if a.kind == "item" or a.kind == "reminder" or a.kind == "equip" then
		return true
	end
	if a.kind == "spell" and a.id then
		local ok = IsSpellKnown and IsSpellKnown(a.id)
		return ok and true or false
	end
	return false
end

-- Item icon fallback when GetItemInfo hasn't loaded yet.
local ICON_FALLBACK = "Interface\\Icons\\INV_Misc_QuestionMark"
-- Reminder kind uses a generic "note" icon; its body is the reminder text.
local REMINDER_ICON = "Interface\\Icons\\INV_Misc_Note_01"

local function lookupSpell(spellId)
	if not spellId then
		return nil, ICON_FALLBACK
	end
	local name, _, icon = GetSpellInfo(spellId)
	return name, icon or ICON_FALLBACK
end

local function lookupItem(itemId)
	if not itemId then
		return nil, ICON_FALLBACK
	end
	local name, _, _, _, _, _, _, _, _, icon = GetItemInfo(itemId)
	if not name then
		pendingItemIds[itemId] = true
		return nil, ICON_FALLBACK
	end
	return name, icon or ICON_FALLBACK
end

local function resolveAssignment(a)
	if a.kind == "reminder" then
		return a.text or "(reminder)", REMINDER_ICON
	end
	if a.kind == "equip" then
		local name, icon = lookupItem(a.id)
		if name then
			return "Equip: " .. name, icon
		end
		return name, icon
	end
	if a.kind == "item" then
		return lookupItem(a.id)
	end
	return lookupSpell(a.id)
end

-- A reusable assignment row.
local function makeAssignRow(parent)
	local row = CreateFrame("Frame", nil, parent)
	row:SetHeight(ROW_H)

	local icon = row:CreateTexture(nil, "ARTWORK")
	icon:SetSize(22, 22)
	icon:SetPoint("LEFT", 4, 0)
	icon:SetTexture(ICON_FALLBACK)
	row.icon = icon

	local name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	name:SetPoint("LEFT", icon, "RIGHT", 8, 0)
	name:SetWidth(140)
	name:SetJustifyH("LEFT")
	row.name = name

	local note = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	note:SetPoint("LEFT", name, "RIGHT", 6, 0)
	note:SetPoint("RIGHT", row, "RIGHT", -4, 0)
	note:SetJustifyH("LEFT")
	note:SetTextColor(0.8, 0.8, 0.8)
	row.note = note

	return row
end

local MIN_W, MIN_H = 280, 200
local MAX_W, MAX_H = 1200, 1200

local function savePosition()
	if not frame then
		return
	end
	local point, _, relPoint, x, y = frame:GetPoint()
	CRP.db.char.window.position = { point = point, relPoint = relPoint, x = x, y = y }
end

local function saveSize()
	if not frame then
		return
	end
	local w, h = frame:GetSize()
	local key = isMyView() and "mySize" or "raidSize"
	CRP.db.char.window[key] = { w = math.floor(w), h = math.floor(h) }
end

local function restorePosition()
	if not frame then
		return
	end
	local pos = CRP.db.char.window.position
	frame:ClearAllPoints()
	if pos and pos.point then
		frame:SetPoint(pos.point, UIParent, pos.relPoint or pos.point, pos.x or 0, pos.y or 0)
	else
		frame:SetPoint("CENTER")
	end
end

local function build()
	frame = CreateFrame("Frame", "CafeRaidPlannerWindow", UIParent, "BackdropTemplate")
	frame:SetSize(RAID_W, RAID_H)
	frame:SetPoint("CENTER")
	frame:SetMovable(true)
	frame:SetResizable(true)
	-- SetResizeBounds on recent Classic Era / retail; SetMinResize/SetMaxResize
	-- on older TBC Classic builds. Call whichever exists.
	if frame.SetResizeBounds then
		frame:SetResizeBounds(MIN_W, MIN_H, MAX_W, MAX_H)
	else
		frame:SetMinResize(MIN_W, MIN_H)
		frame:SetMaxResize(MAX_W, MAX_H)
	end
	frame:EnableMouse(true)
	frame:SetFrameStrata("HIGH")
	frame:SetClampedToScreen(true)
	frame:Hide()
	frame:SetBackdrop({
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = true,
		tileSize = 32,
		edgeSize = 32,
		insets = { left = 8, right = 8, top = 8, bottom = 8 },
	})

	-- drag handle
	local title = CreateFrame("Frame", nil, frame)
	title:SetPoint("TOPLEFT", 10, -10)
	title:SetPoint("TOPRIGHT", -10, -10)
	title:SetHeight(24)
	title:EnableMouse(true)
	title:RegisterForDrag("LeftButton")
	title:SetScript("OnDragStart", function()
		frame:StartMoving()
	end)
	title:SetScript("OnDragStop", function()
		frame:StopMovingOrSizing()
		savePosition()
	end)
	local titleText = title:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	titleText:SetPoint("LEFT", 4, 0)
	titleText:SetText("CafeRaidPlanner")

	local closeBtn = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	closeBtn:SetPoint("TOPRIGHT", 0, 2)
	closeBtn:SetScript("OnClick", function()
		frame:Hide()
	end)

	-- nav strip
	local nav = CreateFrame("Frame", nil, frame)
	nav:SetPoint("TOPLEFT", 16, -44)
	nav:SetPoint("TOPRIGHT", -16, -44)
	nav:SetHeight(22)

	prevBtn = CreateFrame("Button", nil, nav, "UIPanelButtonTemplate")
	prevBtn:SetSize(24, 22)
	prevBtn:SetPoint("LEFT")
	prevBtn:SetText("<")
	prevBtn:SetScript("OnClick", function()
		CRP.Plan:Prev()
	end)

	nextBtn = CreateFrame("Button", nil, nav, "UIPanelButtonTemplate")
	nextBtn:SetSize(24, 22)
	nextBtn:SetPoint("LEFT", prevBtn, "RIGHT", 4, 0)
	nextBtn:SetText(">")
	nextBtn:SetScript("OnClick", function()
		CRP.Plan:Next()
	end)

	-- Pull counter is a button that opens a jump-to-pull popup (our own —
	-- EasyMenu isn't available on every client, and it doesn't scroll).
	pullCounter = CreateFrame("Button", nil, nav, "UIPanelButtonTemplate")
	pullCounter:SetSize(170, 15)
	pullCounter:SetPoint("LEFT", nextBtn, "RIGHT", 8, 0)
	pullCounter:SetText("")
	pullCounter:SetScript("OnClick", function(self)
		Window:TogglePullPopup(self)
	end)

	importBtn = CreateFrame("Button", nil, nav, "UIPanelButtonTemplate")
	importBtn:SetSize(70, 22)
	importBtn:SetPoint("RIGHT")
	importBtn:SetText("Import...")
	importBtn:SetScript("OnClick", function()
		Window:ShowImport()
	end)

	-- Push button — visible only when the user could actually push (leads a
	-- group/raid). Wired to the Comms stub for now; real broadcast lands in
	-- phase C without needing to change this callsite.
	pushBtn = CreateFrame("Button", nil, nav, "UIPanelButtonTemplate")
	pushBtn:SetSize(60, 22)
	pushBtn:SetPoint("RIGHT", importBtn, "LEFT", -4, 0)
	pushBtn:SetText("Push")
	pushBtn:SetScript("OnClick", function()
		local ok, err = CRP.Comms:PushPlan()
		if not ok and err then
			print("|cffff8888CRP:|r push: " .. err)
		end
	end)
	pushBtn:SetScript("OnShow", function(self)
		self:SetEnabled(CRP.Comms and CRP.Comms:CanPush() or false)
	end)

	-- View-mode toggle. Parented to `title` (the drag handle), which raised the
	-- button's frame level above the handle so clicks reach it. Text updates
	-- in ApplyMode to reflect the current state.
	modeBtn = CreateFrame("Button", nil, title, "UIPanelButtonTemplate")
	modeBtn:SetSize(90, 20)
	modeBtn:SetPoint("RIGHT", title, "RIGHT", -28, 0)
	modeBtn:SetFrameLevel(title:GetFrameLevel() + 5)
	modeBtn:SetText("My view")
	modeBtn:SetScript("OnClick", function()
		local nextMode = currentMode() == "raid" and "my" or "raid"
		CRP.db.char.viewMode = nextMode
		Window:ApplyMode()
		Window:Refresh()
	end)

	-- pull title
	pullTitle = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	pullTitle:SetPoint("TOPLEFT", 16, -72)
	pullTitle:SetPoint("TOPRIGHT", -16, -72)
	pullTitle:SetJustifyH("LEFT")

	-- boss line
	bossLine = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	bossLine:SetPoint("TOPLEFT", 16, -96)
	bossLine:SetPoint("TOPRIGHT", -16, -96)
	bossLine:SetJustifyH("LEFT")
	bossLine:SetTextColor(1, 0.82, 0)

	-- pack line (aggregated)
	packLine = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	packLine:SetPoint("TOPLEFT", 16, -114)
	packLine:SetPoint("TOPRIGHT", -16, -114)
	packLine:SetJustifyH("LEFT")
	packLine:SetTextColor(0.7, 0.7, 0.7)

	-- progress (per-mob kill counts) — sits above note
	progressHeader = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	progressHeader:SetPoint("TOPLEFT", 16, -138)
	progressHeader:SetJustifyH("LEFT")
	progressHeader:SetText("")

	-- invisible anchor that progress line pool stacks below; note + scroll anchor to it
	progressAnchor = CreateFrame("Frame", nil, frame)
	progressAnchor:SetPoint("TOPLEFT", progressHeader, "BOTTOMLEFT", 0, 0)
	progressAnchor:SetPoint("RIGHT", frame, "RIGHT", -16, 0)
	progressAnchor:SetHeight(1)

	-- note box
	noteBox = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	noteBox:SetPoint("TOPLEFT", progressAnchor, "BOTTOMLEFT", 0, -8)
	noteBox:SetPoint("RIGHT", frame, "RIGHT", -16, 0)
	noteBox:SetJustifyH("LEFT")
	noteBox:SetJustifyV("TOP")
	noteBox:SetWordWrap(true)

	-- Upcoming pulls preview — fixed slab at the bottom. The scroll frame above
	-- ends at its top so they don't overlap.
	upcomingContainer = CreateFrame("Frame", nil, frame)
	upcomingContainer:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 14, 14)
	upcomingContainer:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -14, 14)
	upcomingContainer:SetHeight(UPCOMING_HEIGHT)
	local uSep = upcomingContainer:CreateTexture(nil, "BACKGROUND")
	uSep:SetColorTexture(1, 1, 1, 0.08)
	uSep:SetPoint("TOPLEFT", 0, 1)
	uSep:SetPoint("TOPRIGHT", 0, 1)
	uSep:SetHeight(1)

	upcomingHeader = upcomingContainer:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	upcomingHeader:SetPoint("TOPLEFT", 2, -2)
	upcomingHeader:SetText("Upcoming")

	-- assignments container (scroll)
	local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", noteBox, "BOTTOMLEFT", -4, -24)
	scroll:SetPoint("BOTTOMRIGHT", upcomingContainer, "TOPRIGHT", -18, 4)

	content = CreateFrame("Frame", nil, scroll)
	content:SetSize(1, 1)
	scroll:SetScrollChild(content)
	frame._scroll = scroll

	emptyMsg = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableLarge")
	emptyMsg:SetPoint("CENTER")
	emptyMsg:SetText("No plan imported.\nUse Import… to paste a crp1. string.")
	emptyMsg:SetJustifyH("CENTER")
	emptyMsg:Hide()

	-- Resize grip (bottom-right corner). StartSizing drives the frame resize;
	-- OnSizeChanged below keeps the scroll child width in sync during the drag.
	local grip = CreateFrame("Button", nil, frame)
	grip:SetSize(16, 16)
	grip:SetPoint("BOTTOMRIGHT", -4, 4)
	grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
	grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
	grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
	grip:SetScript("OnMouseDown", function()
		frame:StartSizing("BOTTOMRIGHT")
	end)
	grip:SetScript("OnMouseUp", function()
		frame:StopMovingOrSizing()
		saveSize()
	end)

	frame:SetScript("OnSizeChanged", function()
		if frame._scroll and content then
			content:SetWidth(frame._scroll:GetWidth())
		end
	end)

	buildPullPopup()
end

local function packNames(pull)
	local names = {}
	for _, packId in ipairs(pull.packIds or {}) do
		local pack = CRP.Plan:PackById(packId)
		names[#names + 1] = (pack and pack.name) or ("#" .. packId)
	end
	return table.concat(names, ", ")
end

-- Return an ordered list of {npcId, required, killed} for the current pull's mobs.
local function progressEntries(pull)
	local entries = {}
	local reqs = CRP.Plan:MobRequirementsForPull(pull)
	local kills = (CRP.Tracker and CRP.Tracker:Kills()) or {}
	for npcId, need in pairs(reqs) do
		entries[#entries + 1] = { npcId = npcId, need = need, killed = kills[npcId] or 0 }
	end
	table.sort(entries, function(a, b)
		if a.killed ~= b.killed then
			return a.killed > b.killed
		end
		return a.npcId < b.npcId
	end)
	return entries
end

-- Pull a progress line from the pool (lazy create).
local function getProgressLine(i)
	local line = progressLines[i]
	if not line then
		line = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		line:SetPoint("LEFT", progressAnchor, "LEFT", 0, 0)
		line:SetPoint("RIGHT", progressAnchor, "RIGHT", 0, 0)
		line:SetJustifyH("LEFT")
		progressLines[i] = line
	end
	return line
end

-- Upcoming row factory. One row per preview slot; icons pooled inside the row.
local function makeUpcomingRow(parent)
	local row = CreateFrame("Button", nil, parent)
	row:SetHeight(UPCOMING_ROW_H)

	local bg = row:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(1, 1, 1, 0)
	row.bg = bg
	row:SetScript("OnEnter", function(s)
		s.bg:SetColorTexture(1, 1, 1, 0.08)
	end)
	row:SetScript("OnLeave", function(s)
		s.bg:SetColorTexture(1, 1, 1, 0)
	end)

	local num = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	num:SetPoint("LEFT", 2, 0)
	num:SetWidth(22)
	num:SetJustifyH("RIGHT")
	row.num = num

	local name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	name:SetPoint("LEFT", num, "RIGHT", 6, 0)
	name:SetJustifyH("LEFT")
	row.name = name

	row.icons = {}
	return row
end

local function upcomingIcon(row, slot)
	local icon = row.icons[slot]
	if not icon then
		icon = row:CreateTexture(nil, "ARTWORK")
		icon:SetSize(UPCOMING_ICON, UPCOMING_ICON)
		icon:SetPoint("RIGHT", row, "RIGHT", -((slot - 1) * (UPCOMING_ICON + 2)) - 2, 0)
		row.icons[slot] = icon
	end
	return icon
end

local function updateUpcoming(curIdx, pulls, my)
	upcomingContainer:Show()
	for offset = 1, UPCOMING_COUNT do
		local upIdx = curIdx + offset
		local row = upcomingRows[offset]
		if not row then
			row = makeUpcomingRow(upcomingContainer)
			upcomingRows[offset] = row
		end
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", upcomingContainer, "TOPLEFT", 0, -UPCOMING_HEADER_H - (offset - 1) * UPCOMING_ROW_H)
		row:SetPoint("TOPRIGHT", upcomingContainer, "TOPRIGHT", 0, -UPCOMING_HEADER_H - (offset - 1) * UPCOMING_ROW_H)

		local pull = pulls[upIdx]
		if not pull then
			row:Hide()
		else
			row.num:SetText(tostring(upIdx))
			row.name:SetText(pull.name or "")

			local rel = {}
			for _, a in ipairs(pull.assignments or {}) do
				if hasContent(a) and (not my or isMyAssignment(a)) then
					rel[#rel + 1] = a
					if #rel >= UPCOMING_MAX_ICONS then
						break
					end
				end
			end
			for i, a in ipairs(rel) do
				local icon = upcomingIcon(row, i)
				local _, texture = resolveAssignment(a)
				icon:SetTexture(texture)
				icon:Show()
			end
			for i = #rel + 1, #row.icons do
				row.icons[i]:Hide()
			end

			-- Jump-to-pull on click; disabled in My view so a non-RL doesn't
			-- desync their own client (same reasoning as hiding prev/next).
			if my then
				row:SetScript("OnClick", nil)
				row:EnableMouse(false)
			else
				row:EnableMouse(true)
				row:SetScript("OnClick", function()
					CRP.Plan:SetCurrentPullIdx(upIdx)
				end)
			end
			row:Show()
		end
	end
end

-- Show/hide chrome based on the current view mode. Called once after build
-- and again on every toggle.
function Window:ApplyMode()
	if not frame then
		return
	end
	local my = isMyView()
	local saved = my and CRP.db.char.window.mySize or CRP.db.char.window.raidSize
	local w = (saved and saved.w) or (my and MY_W or RAID_W)
	local h = (saved and saved.h) or (my and MY_H or RAID_H)
	frame:SetSize(w, h)
	modeBtn:SetText(my and "Raid view" or "My view")
	-- Controls hidden in My view — they're only relevant to the raid leader.
	-- (prev/next stay hidden too; a non-RL advancing their own client desyncs them.)
	for _, btn in ipairs({ prevBtn, nextBtn, pullCounter, pushBtn, importBtn }) do
		if my then
			btn:Hide()
		else
			btn:Show()
		end
	end
	if my then
		bossLine:Hide()
		packLine:Hide()
		progressHeader:Hide()
		for _, line in ipairs(progressLines) do
			line:Hide()
		end
	else
		bossLine:Show()
		packLine:Show()
		progressHeader:Show()
	end
end

function Window:Refresh()
	if not frame then
		return
	end
	local plan = CRP.Plan:Current()
	local pulls = CRP.Plan:Pulls()
	local my = isMyView()

	if not plan or #pulls == 0 then
		pullCounter:SetText("")
		pullTitle:SetText("")
		bossLine:SetText("")
		packLine:SetText("")
		noteBox:SetText("")
		for _, row in ipairs(assignRowPool) do
			row:Hide()
		end
		for _, row in ipairs(upcomingRows) do
			row:Hide()
		end
		if upcomingContainer then
			upcomingContainer:Hide()
		end
		content:SetHeight(1)
		emptyMsg:Show()
		return
	end
	emptyMsg:Hide()

	local idx = CRP.Plan:CurrentPullIdx()
	local pull = pulls[idx]
	pullCounter:SetText(string.format("Pull %d / %d", idx, #pulls))
	-- In My view the nav strip is hidden, so inline the counter into the title.
	if my then
		pullTitle:SetText(string.format("Pull %d/%d — %s", idx, #pulls, pull.name or ""))
	else
		pullTitle:SetText(pull.name or "")
	end

	-- Re-anchor noteBox explicitly each refresh so sections hidden in My view
	-- don't leave stale chained-anchor positions. In Raid view noteBox sits
	-- below the last progress line; in My view it sits right under pullTitle.
	noteBox:ClearAllPoints()
	noteBox:SetPoint("RIGHT", frame, "RIGHT", -16, 0)

	if not my then
		-- Bosses are packs with a slug/icon under the v3 envelope. Collect any
		-- such pack names in this pull and render them on the boss line.
		local bossNames = {}
		for _, packId in ipairs(pull.packIds or {}) do
			local pack = CRP.Plan:PackById(packId)
			if pack and pack.slug then
				bossNames[#bossNames + 1] = pack.name or pack.slug
			end
		end
		bossLine:SetText(#bossNames > 0 and ("Boss: " .. table.concat(bossNames, ", ")) or "")

		local pn = packNames(pull)
		packLine:SetText(pn ~= "" and ("Packs: " .. pn) or "")

		local entries = progressEntries(pull)
		progressHeader:SetText(#entries == 0 and "" or "Kill progress:")
		local y = -14
		for i, e in ipairs(entries) do
			local line = getProgressLine(i)
			line:ClearAllPoints()
			line:SetPoint("TOPLEFT", progressHeader, "BOTTOMLEFT", 0, y)
			line:SetPoint("RIGHT", frame, "RIGHT", -16, 0)
			local done = e.killed >= e.need
			local color = done and "|cff7fff7f" or "|cffffffff"
			local label = CRP.Plan:NpcName(e.npcId) or ("npc #" .. e.npcId)
			line:SetText(string.format("  %s%d/%d|r  %s", color, e.killed, e.need, label))
			line:Show()
			y = y - 14
		end
		for i = #entries + 1, #progressLines do
			progressLines[i]:Hide()
		end

		-- If there were progress lines, y is (initial -14) - 14*count, pointing
		-- just below the last line. If none, leave a gap below progressHeader.
		local offset = (#entries > 0) and (y - 8) or -8
		noteBox:SetPoint("TOPLEFT", progressHeader, "BOTTOMLEFT", 0, offset)
	else
		noteBox:SetPoint("TOPLEFT", pullTitle, "BOTTOMLEFT", 0, -6)
	end

	noteBox:SetText(pull.note or "")

	-- Filter assignments: skip blank rows, then apply My-view filter.
	local shown = {}
	for _, a in ipairs(pull.assignments or {}) do
		if hasContent(a) and (not my or isMyAssignment(a)) then
			shown[#shown + 1] = a
		end
	end

	for i, a in ipairs(shown) do
		local row = assignRowPool[i]
		if not row then
			row = makeAssignRow(content)
			assignRowPool[i] = row
		end
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -(i - 1) * ROW_H)
		row:SetPoint("RIGHT", content, "RIGHT", 0, 0)

		local name, icon = resolveAssignment(a)
		row.icon:SetTexture(icon)
		row.name:SetText(name or string.format("%s #%d", a.kind or "?", a.id or 0))
		local player = a.player or ""
		-- In My view we don't show the player prefix (it'd always be "me"). Show
		-- only the note, if any.
		if not my and player ~= "" then
			local note = a.note or ""
			if note ~= "" then
				row.note:SetText(string.format("|cffc084fc%s:|r %s", player, note))
			else
				row.note:SetText(string.format("|cffc084fc%s|r", player))
			end
		else
			row.note:SetText(a.note or "")
		end
		row:Show()
	end
	for i = #shown + 1, #assignRowPool do
		assignRowPool[i]:Hide()
	end
	content:SetHeight(math.max(1, #shown * ROW_H))
	content:SetWidth(frame._scroll:GetWidth())

	updateUpcoming(idx, pulls, my)
	refreshPullPopupRows()
end

function Window:Show()
	if not frame then
		build()
		restorePosition()
	end
	self:ApplyMode()
	self:Refresh()
	frame:Show()
end

function Window:Hide()
	if frame then
		frame:Hide()
	end
end

function Window:Toggle()
	if frame and frame:IsShown() then
		self:Hide()
	else
		self:Show()
	end
end

-- GET_ITEM_INFO_RECEIVED handler — refresh if any pending item just loaded.
function Window:OnItemInfoReceived(itemId, ok)
	if ok and pendingItemIds[itemId] then
		pendingItemIds[itemId] = nil
		self:Refresh()
	end
end

-- Scrollable jump-to-pull popup. Created eagerly in build() and refreshed in
-- Window:Refresh so it's always populated and sized before the first click.
local pullPopup, pullPopupRowPool, pullPopupContent, pullPopupScroll
local PULL_POPUP_W, PULL_POPUP_H = 260, 260
local PULL_POPUP_ROW_H = 18

function buildPullPopup()
	pullPopup = CreateFrame("Frame", "CafeRaidPlannerPullPopup", UIParent, "BackdropTemplate")
	pullPopup:SetFrameStrata("TOOLTIP")
	pullPopup:SetSize(PULL_POPUP_W, PULL_POPUP_H)
	pullPopup:SetPoint("CENTER") -- temporary; re-anchored on each show
	pullPopup:EnableMouse(true)
	pullPopup:Hide()
	pullPopup:SetBackdrop({
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true,
		tileSize = 16,
		edgeSize = 12,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})

	pullPopupScroll = CreateFrame("ScrollFrame", nil, pullPopup, "UIPanelScrollFrameTemplate")
	pullPopupScroll:SetPoint("TOPLEFT", 8, -8)
	pullPopupScroll:SetPoint("BOTTOMRIGHT", -28, 8)
	pullPopupContent = CreateFrame("Frame", nil, pullPopupScroll)
	-- Scroll child needs an explicit width or row anchors collapse to 1px.
	-- Popup is fixed-size so scroll width is known at build time.
	pullPopupContent:SetSize(PULL_POPUP_W - 8 - 28, 1)
	pullPopupScroll:SetScrollChild(pullPopupContent)
	pullPopupRowPool = {}

	-- Close on outside click using GLOBAL_MOUSE_DOWN — doesn't consume the click
	-- so the anchor button can still toggle on its own OnClick.
	pullPopup:SetScript("OnShow", function(self)
		self:RegisterEvent("GLOBAL_MOUSE_DOWN")
	end)
	pullPopup:SetScript("OnHide", function(self)
		self:UnregisterEvent("GLOBAL_MOUSE_DOWN")
	end)
	pullPopup:SetScript("OnEvent", function(self, event)
		if
			event == "GLOBAL_MOUSE_DOWN"
			and not self:IsMouseOver()
			and not (pullCounter and pullCounter:IsMouseOver())
		then
			self:Hide()
		end
	end)
end

function refreshPullPopupRows()
	if not pullPopup then
		return
	end
	local pulls = CRP.Plan:Pulls()
	local currentIdx = CRP.Plan:CurrentPullIdx()
	for i, pull in ipairs(pulls) do
		local row = pullPopupRowPool[i]
		if not row then
			row = CreateFrame("Button", nil, pullPopupContent)
			row:SetHeight(PULL_POPUP_ROW_H)
			local bg = row:CreateTexture(nil, "BACKGROUND")
			bg:SetAllPoints()
			bg:SetColorTexture(1, 1, 1, 0)
			row.bg = bg
			local text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			text:SetPoint("LEFT", 6, 0)
			text:SetPoint("RIGHT", -6, 0)
			text:SetJustifyH("LEFT")
			row.text = text
			row:SetScript("OnEnter", function(s)
				s.bg:SetColorTexture(1, 1, 1, 0.12)
			end)
			row:SetScript("OnLeave", function(s)
				s.bg:SetColorTexture(1, 1, 1, 0)
			end)
			row:ClearAllPoints()
			row:SetPoint("TOPLEFT", pullPopupContent, "TOPLEFT", 0, -(i - 1) * PULL_POPUP_ROW_H)
			row:SetPoint("RIGHT", pullPopupContent, "RIGHT", 0, 0)
			pullPopupRowPool[i] = row
		end
		row:SetScript("OnClick", function()
			CRP.Plan:SetCurrentPullIdx(i)
			pullPopup:Hide()
		end)
		local prefix = (i == currentIdx) and "|cffffd54a▶|r " or "   "
		row.text:SetText(string.format("%s%d. %s", prefix, i, pull.name or "Pull"))
		row:Show()
	end
	for i = #pulls + 1, #pullPopupRowPool do
		pullPopupRowPool[i]:Hide()
	end
	pullPopupContent:SetHeight(math.max(1, #pulls * PULL_POPUP_ROW_H))
	-- Recompute scroll range now that content height has changed.
	if pullPopupScroll.UpdateScrollChildRect then
		pullPopupScroll:UpdateScrollChildRect()
	end
	-- One-time layout warmup. WoW's UIPanelScrollFrameTemplate doesn't fully
	-- resolve child layout until its parent has been shown at least once;
	-- without this a first-open popup renders blank until the second click.
	if not pullPopup._warmed then
		pullPopup._warmed = true
		pullPopup:Show()
		pullPopup:Hide()
	end
end

function Window:TogglePullPopup(anchorBtn)
	if not pullPopup then
		return
	end
	if pullPopup:IsShown() then
		pullPopup:Hide()
		return
	end
	-- Refresh here too (not just in Window:Refresh) so the rows are current
	-- regardless of whether Refresh has run since the last plan change.
	refreshPullPopupRows()
	pullPopup:ClearAllPoints()
	pullPopup:SetPoint("TOPLEFT", anchorBtn, "BOTTOMLEFT", 0, -2)
	pullPopup:Show()
end

function Window:ShowImport()
	if not importDialog then
		importDialog = CreateFrame("Frame", "CafeRaidPlannerImport", UIParent, "BackdropTemplate")
		importDialog:SetSize(520, 300)
		importDialog:SetPoint("CENTER")
		importDialog:SetFrameStrata("DIALOG")
		importDialog:EnableMouse(true)
		importDialog:SetMovable(true)
		importDialog:RegisterForDrag("LeftButton")
		importDialog:SetScript("OnDragStart", function(s)
			s:StartMoving()
		end)
		importDialog:SetScript("OnDragStop", function(s)
			s:StopMovingOrSizing()
		end)
		importDialog:SetBackdrop({
			bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
			edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
			tile = true,
			tileSize = 32,
			edgeSize = 32,
			insets = { left = 8, right = 8, top = 8, bottom = 8 },
		})

		local label = importDialog:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		label:SetPoint("TOPLEFT", 16, -16)
		label:SetText("Paste a crp1.… string:")

		local scroll =
			CreateFrame("ScrollFrame", "CafeRaidPlannerImportScroll", importDialog, "InputScrollFrameTemplate")
		scroll:SetPoint("TOPLEFT", 16, -40)
		scroll:SetPoint("BOTTOMRIGHT", -32, 60)
		local edit = scroll.EditBox or _G["CafeRaidPlannerImportScrollEditBox"]
		if edit then
			edit:SetMaxLetters(0)
			edit:SetFontObject("ChatFontSmall")
		end
		importDialog.edit = edit

		local status = importDialog:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		status:SetPoint("BOTTOMLEFT", 16, 34)
		status:SetPoint("BOTTOMRIGHT", -16, 34)
		status:SetJustifyH("LEFT")
		status:SetTextColor(1, 0.4, 0.4)
		importDialog.status = status

		local importBtn = CreateFrame("Button", nil, importDialog, "UIPanelButtonTemplate")
		importBtn:SetSize(100, 22)
		importBtn:SetPoint("BOTTOMLEFT", 16, 8)
		importBtn:SetText("Import")
		importBtn:SetScript("OnClick", function()
			local str = importDialog.edit and importDialog.edit:GetText() or ""
			local env, err = CRP.Share:Decode(str)
			if not env then
				importDialog.status:SetText("Import failed: " .. tostring(err))
				return
			end
			CRP.Plan:Import(env)
			importDialog.status:SetText("")
			importDialog:Hide()
			Window:Refresh()
			print(
				"|cff38c24fCafeRaidPlanner:|r imported plan with "
					.. #(env.preset.pulls or {})
					.. " pulls, "
					.. #(env.packs or {})
					.. " packs."
			)
		end)

		local closeBtn = CreateFrame("Button", nil, importDialog, "UIPanelButtonTemplate")
		closeBtn:SetSize(80, 22)
		closeBtn:SetPoint("BOTTOMRIGHT", -16, 8)
		closeBtn:SetText("Cancel")
		closeBtn:SetScript("OnClick", function()
			importDialog:Hide()
		end)
	end
	if importDialog.edit then
		importDialog.edit:SetText("")
	end
	importDialog.status:SetText("")
	importDialog:Show()
end
