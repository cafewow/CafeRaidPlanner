local _, CRP = ...

CRP.ui = CRP.ui or {}
local Window = {}
CRP.ui.Window = Window

-- Sidebar-shaped defaults. Window is laid out as a vertical stack of titled
-- sections inside a single scroll frame, so height is mostly informational —
-- the user can size up or down freely and section content reflows.
local RAID_W, RAID_H = 330, 560
local MY_W, MY_H = 290, 320

-- MIN_W is set so the raid-view nav strip doesn't overlap: prev(24) + gap(4)
-- + next(24) + gap(6) + counter(96) + gap + push(50) + gap(4) + import(62)
-- plus the frame's 16px side margins ≈ 320; tuned to 330.
local MIN_W, MIN_H = 330, 200
local MAX_W, MAX_H = 1200, 1200

-- Section/row metrics
local SECTION_HEADER_H = 20
local SECTION_GAP = 8
local ASSIGN_ROW_H = 22
local PROGRESS_ROW_H = 14
local UPCOMING_ROW_H = 18
local BULLET_GAP = 2

-- Assignment table column widths. Assignee fills remaining space.
local ICON_W = 20
local COL_ABILITY_MIN = 100
local COL_TARGET_MIN = 80
local COL_ASSIGNEE_MIN = 50

local frame, content
local pendingItemIds = {} -- items whose info was nil; refresh when GET_ITEM_INFO_RECEIVED fires
local buildPullPopup, refreshPullPopupRows -- forward decls; defined later in file

-- Header chrome
local pullTitle, pullCounter, packLine, emptyMsg
local prevBtn, nextBtn, pushBtn, importBtn, modeBtn
local importDialog

-- Object pools — every section element is parented to `content` (the scroll
-- child) and re-anchored on each Refresh.
local sectionPool = {}
local bulletPool = {}
local progressPool = {}
local assignPool = {}
local upcomingPool = {}
local tableHeader
local noteParagraphPool = {}

-- Chrome fade: title bar, nav, grip, backdrop, scroll bar, plus the Kill
-- Progress / Upcoming sections all fade out when the mouse leaves the window,
-- so Pull Notes and Assignments float over the game world unobtrusively.
-- Hovering anywhere over the window reveals everything again. Static chrome is
-- registered once in build(); dynamic chrome (kill-progress and upcoming
-- sections) is re-added each Refresh.
local CHROME_FADE_IN_SPEED = 8  -- alpha per second on fade-in (snappy reveal)
local CHROME_FADE_OUT_SPEED = 2 -- slower fade-out so the user has time to react
local chromeRegions = {}
local chromeAlpha = 1
local chromeTarget = 1
-- Click-to-reveal mode (CRP.db.global.revealOnClick): chrome stays hidden on
-- hover alone and only reveals once the user clicks inside the window. `armed`
-- tracks that click; it clears the moment the mouse leaves so the next reveal
-- needs a fresh click. Unused in the default hover mode.
local chromeArmed = false

local function applyChromeAlpha(a)
	chromeAlpha = a
	if frame then
		-- Neutral tint (1,1,1) preserves the dialog texture's own coloring;
		-- only the alpha varies so the texture/border fade in and out cleanly.
		frame:SetBackdropColor(1, 1, 1, a)
		frame:SetBackdropBorderColor(1, 1, 1, a)
	end
	for _, obj in ipairs(chromeRegions) do
		obj:SetAlpha(a)
	end
end

local function resetChrome()
	for i = #chromeRegions, 1, -1 do chromeRegions[i] = nil end
end

local function addChrome(obj)
	if obj then chromeRegions[#chromeRegions + 1] = obj end
end

local function currentMode()
	return (CRP.db and CRP.db.char and CRP.db.char.viewMode) or "raid"
end

local function isMyView()
	return currentMode() == "my"
end

-- Realm-suffix stripping lives in CRP.util now (shared with Comms).
local stripRealm = CRP.util.stripRealm

-- True iff the assignment has enough data to be worth rendering. Blank rows
-- (freshly added but unfilled) are skipped in the current-pull list and the
-- upcoming preview.
local function hasContent(a)
	if not a then return false end
	if a.kind == "reminder" then
		return a.text ~= nil and a.text ~= ""
	end
	return type(a.id) == "number"
end

-- IsSpellKnown is rank-specific: an assignment authored against Pummel rank 1
-- returns false for a warrior who only knows rank 2. Fall back to a name-based
-- spellbook lookup — GetSpellInfo(name) returns info iff the player has any
-- rank of that spell, so it's rank-agnostic. Used for both ability spells and
-- kicks (kicks were the trigger: classes typically know one specific rank of
-- their interrupt and the planner can't predict which).
local function knowsSpell(spellId)
	if not spellId then return false end
	if IsSpellKnown and IsSpellKnown(spellId) then return true end
	local name = GetSpellInfo(spellId)
	if not name then return false end
	return GetSpellInfo(name) ~= nil
end

-- Assignment filter for My view:
--   - player set:   only if it matches me (case-insensitive, realm-stripped).
--                   A named player is the most specific target, so role is
--                   ignored in this branch.
--   - player empty: if the assignment targets a role, my role must match; that
--                   gate composes with the class filter below (so a paladin-only
--                   Divine Shield tagged "tank" reaches paladin tanks only).
--                   items and reminders always pass the class filter (no way to
--                   class-filter a free-text reminder); spells/kicks only if I
--                   know them.
-- Exposed on CRP.ui so the combat HUD can apply the same "is this for me?"
-- filter the personal view uses, without duplicating knowsSpell/stripRealm.
function CRP.ui.IsMyAssignment(a)
	if not a then return false end
	local player = a.player or ""
	if player ~= "" then
		local me = UnitName("player") or ""
		return stripRealm(player):lower() == stripRealm(me):lower()
	end
	local role = a.role or ""
	if role ~= "" and not (CRP.Roles and CRP.Roles:Get() == role) then
		return false
	end
	if a.kind == "item" or a.kind == "reminder" or a.kind == "equip" then
		return true
	end
	if (a.kind == "spell" or a.kind == "kick") and a.id then
		return knowsSpell(a.id)
	end
	return false
end

local ICON_FALLBACK = "Interface\\Icons\\INV_Misc_QuestionMark"
local REMINDER_ICON = "Interface\\Icons\\INV_Misc_Note_01"

local function lookupSpell(spellId)
	if not spellId then return nil, ICON_FALLBACK end
	local name, _, icon = GetSpellInfo(spellId)
	return name, icon or ICON_FALLBACK
end

local function lookupItem(itemId)
	if not itemId then return nil, ICON_FALLBACK end
	local name, _, _, _, _, _, _, _, _, icon = GetItemInfo(itemId)
	if not name then
		pendingItemIds[itemId] = true
		return nil, ICON_FALLBACK
	end
	return name, icon or ICON_FALLBACK
end

local MARKER_TEX_INDEX = {
	star = 1, circle = 2, diamond = 3, triangle = 4,
	moon = 5, square = 6, cross = 7, skull = 8,
}
local MARKER_LABEL = {
	star = "Star", circle = "Circle", diamond = "Diamond", triangle = "Triangle",
	moon = "Moon", square = "Square", cross = "Cross", skull = "Skull",
}

-- Display labels for role-targeted assignments (shown in the raid-view assignee
-- cell when no specific player is named).
local ROLE_LABEL = { tank = "Tanks", healer = "Healers", damage = "Damage" }

local function markerInline(markerId)
	local idx = MARKER_TEX_INDEX[markerId]
	if not idx then return MARKER_LABEL[markerId] or markerId end
	return string.format(
		"|TInterface\\TARGETINGFRAME\\UI-RaidTargetingIcon_%d:14:14:0:0|t %s",
		idx, MARKER_LABEL[markerId] or markerId
	)
end

-- Resolve an assignment into the row's three logical cells. Returns
--   icon, ability_text, target_text
-- (target is "" for non-kick assignments). Reminders never reach this — the
-- Refresh dispatcher routes them to the Pull Notes section instead.
local function resolveAssignmentRow(a)
	local icon, ability, target
	if a.kind == "equip" then
		local name, ic = lookupItem(a.id)
		icon = ic
		ability = name and ("Equip: " .. name) or string.format("equip #%d", a.id or 0)
	elseif a.kind == "item" then
		local name, ic = lookupItem(a.id)
		icon = ic
		ability = name or string.format("item #%d", a.id or 0)
	elseif a.kind == "kick" then
		local name, ic = lookupSpell(a.id)
		icon = ic
		ability = name or string.format("spell #%d", a.id or 0)
		if a.targetMarker and a.targetMarker ~= "" then
			target = markerInline(a.targetMarker)
		elseif a.targetNpcId then
			target = (CRP.Plan and CRP.Plan:NpcName(a.targetNpcId))
				or string.format("npc #%d", a.targetNpcId)
		end
	else -- "spell" or unknown
		local name, ic = lookupSpell(a.id)
		icon = ic
		ability = name or string.format("spell #%d", a.id or 0)
	end
	return icon, ability or "", target or ""
end

local function savePosition()
	if not frame then return end
	local point, _, relPoint, x, y = frame:GetPoint()
	CRP.db.char.window.position = { point = point, relPoint = relPoint, x = x, y = y }
end

local function saveSize()
	if not frame then return end
	local w, h = frame:GetSize()
	local key = isMyView() and "mySize" or "raidSize"
	CRP.db.char.window[key] = { w = math.floor(w), h = math.floor(h) }
end

local function restorePosition()
	if not frame then return end
	local pos = CRP.db.char.window.position
	frame:ClearAllPoints()
	if pos and pos.point then
		frame:SetPoint(pos.point, UIParent, pos.relPoint or pos.point, pos.x or 0, pos.y or 0)
	else
		frame:SetPoint("CENTER")
	end
end

-- Section header: a small bar texture + a label. Section content stacks below.
local function getSection(i)
	local s = sectionPool[i]
	if s then return s end
	s = CreateFrame("Frame", nil, content)
	s:SetHeight(SECTION_HEADER_H)
	local bar = s:CreateTexture(nil, "BACKGROUND")
	bar:SetColorTexture(1, 0.82, 0, 0.18)
	bar:SetPoint("BOTTOMLEFT", 0, 0)
	bar:SetPoint("BOTTOMRIGHT", 0, 0)
	bar:SetHeight(1)
	local label = s:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	label:SetPoint("LEFT", 2, 2)
	label:SetTextColor(1, 0.82, 0)
	s.label = label
	sectionPool[i] = s
	return s
end

local function getBullet(i)
	local b = bulletPool[i]
	if b then return b end
	b = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	b:SetJustifyH("LEFT")
	b:SetJustifyV("TOP")
	b:SetWordWrap(true)
	bulletPool[i] = b
	return b
end

local function getNoteParagraph(i)
	local np = noteParagraphPool[i]
	if np then return np end
	np = content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	np:SetJustifyH("LEFT")
	np:SetJustifyV("TOP")
	np:SetWordWrap(true)
	noteParagraphPool[i] = np
	return np
end

local function getProgressRow(i)
	local r = progressPool[i]
	if r then return r end
	r = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	r:SetJustifyH("LEFT")
	r:SetWordWrap(false)
	progressPool[i] = r
	return r
end

local function getTableHeader()
	if tableHeader then return tableHeader end
	local h = CreateFrame("Frame", nil, content)
	h:SetHeight(14)
	local function col(text)
		local fs = h:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		fs:SetJustifyH("LEFT")
		fs:SetWordWrap(false)
		fs:SetTextColor(0.7, 0.7, 0.7)
		fs:SetText(text)
		return fs
	end
	h.ability = col("Ability")
	h.target = col("Target")
	h.assignee = col("Assignee")
	tableHeader = h
	return tableHeader
end

-- A cell is a Frame wrapping a FontString so it can receive mouse events
-- independently of its row. Hovering a cell shows a tooltip with that cell's
-- own content (set per-Refresh into `cell._tip`).
local function cellOnEnter(self)
	if not self._tip or self._tip == "" then return end
	GameTooltip:SetOwner(self, "ANCHOR_TOPRIGHT")
	GameTooltip:SetText(self._tip, 1, 1, 1, 1, true)
	GameTooltip:Show()
end

local function cellOnLeave()
	GameTooltip:Hide()
end

-- Anchor a cell inside its row: left edge to `leftAnchor` (+ offset), top and
-- bottom to the row, fixed width. Used by both the table header and each
-- assignment row to lay out the three columns identically.
local function anchorCell(cell, leftAnchor, leftRel, leftOffset, width)
	cell:ClearAllPoints()
	cell:SetPoint("LEFT", leftAnchor, leftRel, leftOffset, 0)
	cell:SetPoint("TOP", cell:GetParent(), "TOP", 0, 0)
	cell:SetPoint("BOTTOM", cell:GetParent(), "BOTTOM", 0, 0)
	cell:SetWidth(width)
end

local function makeCell(parent)
	local cell = CreateFrame("Frame", nil, parent)
	cell:EnableMouse(true)
	local fs = cell:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	fs:SetPoint("LEFT")
	fs:SetPoint("RIGHT")
	fs:SetJustifyH("LEFT")
	fs:SetJustifyV("MIDDLE")
	fs:SetWordWrap(false)
	cell.fs = fs
	cell:SetScript("OnEnter", cellOnEnter)
	cell:SetScript("OnLeave", cellOnLeave)
	return cell
end

local function getAssignRow(i)
	local row = assignPool[i]
	if row then return row end
	row = CreateFrame("Frame", nil, content)
	row:SetHeight(ASSIGN_ROW_H)

	local icon = row:CreateTexture(nil, "ARTWORK")
	icon:SetSize(ICON_W, ICON_W)
	icon:SetPoint("LEFT", 2, 0)
	row.icon = icon

	row.ability = makeCell(row)
	row.target = makeCell(row)
	row.assignee = makeCell(row)

	assignPool[i] = row
	return row
end

local function getUpcomingRow(i)
	local row = upcomingPool[i]
	if row then return row end
	row = CreateFrame("Button", nil, content)
	row:SetHeight(UPCOMING_ROW_H)
	local bg = row:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(1, 1, 1, 0)
	row.bg = bg
	local num = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	num:SetPoint("LEFT", 4, 0)
	num:SetWidth(22)
	num:SetJustifyH("RIGHT")
	row.num = num
	local name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	name:SetPoint("LEFT", num, "RIGHT", 6, 0)
	name:SetPoint("RIGHT", row, "RIGHT", -4, 0)
	name:SetJustifyH("LEFT")
	name:SetWordWrap(false)
	row.name = name
	row:SetScript("OnEnter", function(s)
		s.bg:SetColorTexture(1, 1, 1, 0.08)
		if s._tip and s._tip ~= "" then
			GameTooltip:SetOwner(s, "ANCHOR_TOPRIGHT")
			GameTooltip:SetText(s._tip, 1, 1, 1, 1, true)
			GameTooltip:Show()
		end
	end)
	row:SetScript("OnLeave", function(s)
		s.bg:SetColorTexture(1, 1, 1, 0)
		GameTooltip:Hide()
	end)
	upcomingPool[i] = row
	return row
end

local function build()
	frame = CreateFrame("Frame", "CafeRaidPlannerWindow", UIParent, "BackdropTemplate")
	frame:SetSize(RAID_W, RAID_H)
	frame:SetPoint("CENTER")
	frame:SetMovable(true)
	frame:SetResizable(true)
	if frame.SetResizeBounds then
		frame:SetResizeBounds(MIN_W, MIN_H, MAX_W, MAX_H)
	else
		frame:SetMinResize(MIN_W, MIN_H)
		frame:SetMaxResize(MAX_W, MAX_H)
	end
	frame:EnableMouse(true)
	-- LOW so default UI panels (character sheet, spellbook, bags — all MEDIUM or
	-- higher) layer on top of the planner instead of being hidden behind it.
	-- The pull popup and import dialog set their own higher strata below.
	frame:SetFrameStrata("LOW")
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

	-- drag handle (title bar)
	local title = CreateFrame("Frame", nil, frame)
	title:SetPoint("TOPLEFT", 10, -10)
	title:SetPoint("TOPRIGHT", -10, -10)
	title:SetHeight(24)
	title:EnableMouse(true)
	title:RegisterForDrag("LeftButton")
	title:SetScript("OnDragStart", function() frame:StartMoving() end)
	title:SetScript("OnDragStop", function()
		frame:StopMovingOrSizing()
		savePosition()
	end)
	local titleText = title:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	titleText:SetPoint("LEFT", 4, 0)
	titleText:SetText("CafeRaidPlanner")

	local closeBtn = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	closeBtn:SetPoint("TOPRIGHT", 0, 2)
	closeBtn:SetScript("OnClick", function() frame:Hide() end)
	-- The drag-handle `title` frame above spans the full top edge with
	-- EnableMouse(true), which would swallow clicks on the close button. Lift
	-- the button above the title's frame level so its hit area wins.
	closeBtn:SetFrameLevel(title:GetFrameLevel() + 5)

	-- Options button — gear-style. Sits left of the view-mode toggle. Parented
	-- to the title bar so its frame level outranks the drag handle.
	local optBtn = CreateFrame("Button", nil, title, "UIPanelButtonTemplate")
	optBtn:SetSize(60, 20)
	optBtn:SetPoint("RIGHT", title, "RIGHT", -124, 0)
	optBtn:SetFrameLevel(title:GetFrameLevel() + 5)
	optBtn:SetText("Options")
	optBtn:SetScript("OnClick", function()
		if CRP.Options then CRP.Options:Show() end
	end)

	-- View-mode toggle (parented to title bar so its frame level sits above the
	-- drag handle and clicks reach it).
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

	-- nav strip (prev/next/counter on the left, push/import on the right). Whole
	-- strip hides in My view.
	local nav = CreateFrame("Frame", nil, frame)
	nav:SetPoint("TOPLEFT", 16, -44)
	nav:SetPoint("TOPRIGHT", -16, -44)
	nav:SetHeight(22)
	frame._nav = nav

	prevBtn = CreateFrame("Button", nil, nav, "UIPanelButtonTemplate")
	prevBtn:SetSize(24, 22)
	prevBtn:SetPoint("LEFT")
	prevBtn:SetText("<")
	prevBtn:SetScript("OnClick", function() CRP.Plan:Prev() end)

	nextBtn = CreateFrame("Button", nil, nav, "UIPanelButtonTemplate")
	nextBtn:SetSize(24, 22)
	nextBtn:SetPoint("LEFT", prevBtn, "RIGHT", 4, 0)
	nextBtn:SetText(">")
	nextBtn:SetScript("OnClick", function() CRP.Plan:Next() end)

	pullCounter = CreateFrame("Button", nil, nav, "UIPanelButtonTemplate")
	pullCounter:SetSize(96, 18)
	pullCounter:SetPoint("LEFT", nextBtn, "RIGHT", 6, 0)
	pullCounter:SetText("")
	pullCounter:SetScript("OnClick", function(self) Window:TogglePullPopup(self) end)

	importBtn = CreateFrame("Button", nil, nav, "UIPanelButtonTemplate")
	importBtn:SetSize(62, 22)
	importBtn:SetPoint("RIGHT")
	importBtn:SetText("Import")
	importBtn:SetScript("OnClick", function() Window:ShowImport() end)

	pushBtn = CreateFrame("Button", nil, nav, "UIPanelButtonTemplate")
	pushBtn:SetSize(50, 22)
	pushBtn:SetPoint("RIGHT", importBtn, "LEFT", -4, 0)
	pushBtn:SetText("Push")
	pushBtn:SetScript("OnClick", function()
		local ok, err = CRP.Comms:PushPlan()
		if not ok and err then print("|cffff8888CRP:|r push: " .. err) end
	end)
	pushBtn:SetScript("OnShow", function(self)
		self:SetEnabled(CRP.Comms and CRP.Comms:CanPush() or false)
	end)

	-- pull title (large)
	pullTitle = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	pullTitle:SetPoint("TOPLEFT", 16, -72)
	pullTitle:SetPoint("TOPRIGHT", -16, -72)
	pullTitle:SetJustifyH("LEFT")
	pullTitle:SetWordWrap(false)

	-- packs subtitle
	packLine = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	packLine:SetPoint("TOPLEFT", pullTitle, "BOTTOMLEFT", 0, -2)
	packLine:SetPoint("TOPRIGHT", pullTitle, "BOTTOMRIGHT", 0, -2)
	packLine:SetJustifyH("LEFT")
	packLine:SetTextColor(0.7, 0.7, 0.7)
	packLine:SetWordWrap(false)

	-- empty-state message (centered)
	emptyMsg = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableLarge")
	emptyMsg:SetPoint("CENTER")
	emptyMsg:SetText("No plan imported.\nUse Import… to paste a crp1. string.")
	emptyMsg:SetJustifyH("CENTER")
	emptyMsg:Hide()

	-- scroll: holds all sections (Pull Notes, Kill Progress, Assignments, Upcoming)
	local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", packLine, "BOTTOMLEFT", -4, -10)
	scroll:SetPoint("BOTTOMRIGHT", -28, 18)

	content = CreateFrame("Frame", nil, scroll)
	content:SetSize(1, 1)
	scroll:SetScrollChild(content)
	frame._scroll = scroll

	local grip = CreateFrame("Button", nil, frame)
	grip:SetSize(16, 16)
	grip:SetPoint("BOTTOMRIGHT", -4, 4)
	grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
	grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
	grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
	grip:SetScript("OnMouseDown", function() frame:StartSizing("BOTTOMRIGHT") end)
	grip:SetScript("OnMouseUp", function()
		frame:StopMovingOrSizing()
		saveSize()
	end)

	-- OnSizeChanged fires many times per frame during a drag. Coalesce them
	-- through a dirty flag consumed in OnUpdate so we run at most one Refresh
	-- per render frame, while still giving the user live column resizing.
	frame:SetScript("OnSizeChanged", function()
		if frame._scroll and content then
			content:SetWidth(frame._scroll:GetWidth())
		end
		frame._refreshDirty = true
	end)
	frame:SetScript("OnUpdate", function(self, dt)
		if self._refreshDirty then
			self._refreshDirty = false
			Window:Refresh()
		end
		-- Hover-fade chrome. IsMouseOver covers all descendants, so child
		-- widgets like the grip and nav buttons count as "still hovering."
		-- The pull-jump popup is parented to UIParent (so it can outlive a
		-- click on its anchor), so we hand-pin chrome to visible while it's
		-- open. The empty-state message is NOT chrome, so it stays visible while
		-- the chrome fades — hovering the window reveals the Import button.
		local sticky = (pullPopup and pullPopup:IsShown())
		local over = self:IsMouseOver()
		local reveal
		if CRP.db and CRP.db.global and CRP.db.global.revealOnClick then
			-- Click-to-reveal: arm on any mouse-button press while over the
			-- window (polled, so it catches clicks even on child widgets that
			-- swallow the event), disarm the instant the cursor leaves.
			if not over then
				chromeArmed = false
			elseif IsMouseButtonDown("LeftButton") or IsMouseButtonDown("RightButton") then
				chromeArmed = true
			end
			reveal = chromeArmed
		else
			reveal = over
		end
		chromeTarget = (reveal or sticky) and 1 or 0
		if chromeAlpha ~= chromeTarget then
			local speed = (chromeTarget > chromeAlpha)
				and CHROME_FADE_IN_SPEED or CHROME_FADE_OUT_SPEED
			local step = (dt or 0) * speed
			if chromeTarget > chromeAlpha then
				applyChromeAlpha(math.min(chromeTarget, chromeAlpha + step))
			else
				applyChromeAlpha(math.max(chromeTarget, chromeAlpha - step))
			end
		end
	end)

	-- Static chrome — everything that should fade with the title bar. The
	-- chrome list itself is rebuilt every Refresh (so dynamic sections can
	-- register themselves), with these statics re-added each time.
	frame._chromeStatic = { title, closeBtn, modeBtn, nav, grip, pullTitle, packLine }
	if frame._scroll and frame._scroll.ScrollBar then
		frame._chromeStatic[#frame._chromeStatic + 1] = frame._scroll.ScrollBar
	end

	buildPullPopup()
end

-- ----- pull display helpers (unchanged) --------------------------------------

local function packNames(pull)
	local names = {}
	for _, packId in ipairs(pull.packIds or {}) do
		local pack = CRP.Plan:PackById(packId)
		names[#names + 1] = (pack and pack.name) or ("#" .. packId)
	end
	return table.concat(names, ", ")
end

local function shortNpcName(name)
	if not name or name == "" then return nil end
	return name:match("(%S+)%s*$") or name
end

local function pullMobSummary(pull)
	if not pull then return "" end
	local counts, order = {}, {}
	for _, packId in ipairs(pull.packIds or {}) do
		local pack = CRP.Plan:PackById(packId)
		if pack and pack.members then
			for _, m in ipairs(pack.members) do
				local short = shortNpcName(CRP.Plan:NpcName(m.npcId)) or ("#" .. m.npcId)
				if not counts[short] then
					counts[short] = 0
					order[#order + 1] = short
				end
				counts[short] = counts[short] + (m.count or 1)
			end
		end
	end
	if #order == 0 then return "" end
	table.sort(order, function(a, b)
		if counts[a] ~= counts[b] then return counts[a] > counts[b] end
		return a < b
	end)
	local parts = {}
	for _, name in ipairs(order) do
		parts[#parts + 1] = counts[name] .. "x " .. name
	end
	return table.concat(parts, ", ")
end

-- Short label for one assignment, for compact summaries. Reuses the row
-- resolver (so equips read "Equip: X", items/spells read their name) and adds
-- reminder text, which the resolver intentionally skips.
local function assignmentShortLabel(a)
	if a.kind == "reminder" then
		return (a.text and a.text ~= "") and a.text or nil
	end
	local _, ability = resolveAssignmentRow(a)
	return (ability and ability ~= "") and ability or nil
end

-- Assignment summary for a pull, analogous to pullMobSummary but for the
-- actions in the step — used so a prep pull (no mobs) isn't blank in Upcoming.
local function pullAssignmentSummary(pull)
	if not (pull and pull.assignments) then return "" end
	local parts = {}
	for _, a in ipairs(pull.assignments) do
		local label = assignmentShortLabel(a)
		if label then parts[#parts + 1] = label end
	end
	return table.concat(parts, ", ")
end

-- Boss name(s) for a pull, or "" for a plain trash pull. Pulls aren't named —
-- callers prefix the position number, so trash pulls read as just "N.".
local function pullDisplayName(pull)
	local bossNames = {}
	for _, pack in ipairs(CRP.Plan:BossPacks(pull)) do
		bossNames[#bossNames + 1] = pack.name or pack.slug
	end
	return table.concat(bossNames, " + ")
end

-- Kill progress rows. Same shape as before: { kind="fixed" | "pool", ... }.
local function progressEntries(pull)
	local slots = CRP.Plan:SlotsForPull(pull)
	if #slots == 0 then return {} end
	local kills = (CRP.Tracker and CRP.Tracker:Kills()) or {}
	local consumed = CRP.Tracker:AssignKillsToSlots(slots, kills)
	local fixedByNpc = {}
	local poolEntries = {}
	for i, s in ipairs(slots) do
		if s.variable then
			local npcIds = {}
			for nid in pairs(s.accepts) do npcIds[#npcIds + 1] = nid end
			table.sort(npcIds)
			poolEntries[#poolEntries + 1] = {
				kind = "pool",
				npcIds = npcIds,
				need = s.count,
				killed = consumed[i],
				sortKey = npcIds[1] or 0,
			}
		else
			local nid
			for n in pairs(s.accepts) do nid = n; break end
			if nid then
				local row = fixedByNpc[nid]
				if not row then
					row = { kind = "fixed", npcId = nid, need = 0, killed = 0 }
					fixedByNpc[nid] = row
				end
				row.need = row.need + s.count
				row.killed = row.killed + consumed[i]
			end
		end
	end
	local entries = {}
	for _, row in pairs(fixedByNpc) do entries[#entries + 1] = row end
	for _, row in ipairs(poolEntries) do entries[#entries + 1] = row end
	table.sort(entries, function(a, b)
		if a.killed ~= b.killed then return a.killed > b.killed end
		local ak = a.kind == "pool" and a.sortKey or a.npcId
		local bk = b.kind == "pool" and b.sortKey or b.npcId
		return ak < bk
	end)
	return entries
end

-- ----- view-mode chrome ------------------------------------------------------

function Window:ApplyMode()
	if not frame then return end
	local my = isMyView()
	local saved = my and CRP.db.char.window.mySize or CRP.db.char.window.raidSize
	local w = (saved and saved.w) or (my and MY_W or RAID_W)
	local h = (saved and saved.h) or (my and MY_H or RAID_H)
	frame:SetSize(w, h)
	modeBtn:SetText(my and "Raid view" or "My view")
	-- Whole nav strip is for raid-leader actions; hide its children in My view.
	for _, btn in ipairs({ prevBtn, nextBtn, pullCounter, pushBtn, importBtn }) do
		if my then btn:Hide() else btn:Show() end
	end
end

-- ----- layout (Refresh) ------------------------------------------------------

-- Truncation helper. After SetText + SetWidth, compare GetStringWidth (the
-- measured text width if it weren't clipped) with GetWidth (the cell width).
-- If text overflows, return true and the caller will surface it in the row
-- tooltip.
local function isTruncated(fs)
	return fs:GetStringWidth() > fs:GetWidth() + 0.5
end

-- A layout `ctx` is the mutable cursor passed through section functions:
--   y:       pixels from content top, grows downward
--   sIdx..:  pool indices (incremented as pooled elements are placed)
--   W:       content width (drives every cell's SetWidth)
--   pull, my, idx, pulls: pull-data shorthand
-- Each section function reads ctx, places its own elements into the `content`
-- frame, and mutates ctx.y / ctx.<pool>Idx. No section needs to know about the
-- others — they compose by appending to the cursor.

local function placeSection(ctx, titleText, chrome)
	ctx.sIdx = ctx.sIdx + 1
	local s = getSection(ctx.sIdx)
	s:ClearAllPoints()
	s:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -ctx.y)
	s:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, -ctx.y)
	s.label:SetText(titleText)
	s:Show()
	if chrome then addChrome(s) end
	ctx.y = ctx.y + SECTION_HEADER_H + 2
end

local function layoutPullNotes(ctx)
	local pull, my, W = ctx.pull, ctx.my, ctx.W
	local noteText = pull.note or ""
	local reminders = {}
	for _, a in ipairs(pull.assignments or {}) do
		if a.kind == "reminder" and hasContent(a) and (not my or CRP.ui.IsMyAssignment(a)) then
			reminders[#reminders + 1] = a
		end
	end
	if noteText == "" and #reminders == 0 then return end

	placeSection(ctx, "Pull Notes")
	if noteText ~= "" then
		ctx.nIdx = ctx.nIdx + 1
		local np = getNoteParagraph(ctx.nIdx)
		np:ClearAllPoints()
		np:SetPoint("TOPLEFT", content, "TOPLEFT", 10, -ctx.y)
		np:SetWidth(W - 14)
		np:SetText(noteText)
		np:Show()
		ctx.y = ctx.y + math.max(14, np:GetStringHeight()) + 4
	end
	for _, r in ipairs(reminders) do
		ctx.bIdx = ctx.bIdx + 1
		local b = getBullet(ctx.bIdx)
		b:ClearAllPoints()
		b:SetPoint("TOPLEFT", content, "TOPLEFT", 10, -ctx.y)
		b:SetWidth(W - 14)
		b:SetText("- " .. (r.text or ""))
		b:Show()
		ctx.y = ctx.y + math.max(12, b:GetStringHeight()) + BULLET_GAP
	end
	ctx.y = ctx.y + SECTION_GAP
end

local function layoutKillProgress(ctx)
	local entries = progressEntries(ctx.pull)
	if #entries == 0 then return end
	placeSection(ctx, "Kill Progress")
	local W = ctx.W
	for _, e in ipairs(entries) do
		ctx.pIdx = ctx.pIdx + 1
		local row = getProgressRow(ctx.pIdx)
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", content, "TOPLEFT", 10, -ctx.y)
		row:SetWidth(W - 14)
		local done = e.killed >= e.need
		local color = done and "|cff7fff7f" or "|cffffffff"
		local label
		if e.kind == "pool" then
			local names = {}
			for _, nid in ipairs(e.npcIds) do
				names[#names + 1] = CRP.Plan:NpcName(nid) or ("#" .. nid)
			end
			label = "pool: " .. table.concat(names, ", ")
		else
			label = CRP.Plan:NpcName(e.npcId) or ("npc #" .. e.npcId)
		end
		row:SetText(string.format("%s%d/%d|r  %s", color, e.killed, e.need, label))
		row:Show()
		ctx.y = ctx.y + PROGRESS_ROW_H
	end
	ctx.y = ctx.y + SECTION_GAP
end

-- Compute (cAbility, cTarget, cAssignee) from content width and view mode.
-- In My view assignee is hidden (cAssignee = 0); its space is folded into the
-- target column. In Raid view extra space splits 15%/25%/60% across the three
-- columns, with deficit-stealing if the window is too narrow for the minimums.
local function computeAssignmentColumns(W, my)
	local pad = 4
	local gap = 6
	if my then
		local avail = W - pad - ICON_W - gap - gap - pad
		local cAbility = COL_ABILITY_MIN
		local extra = avail - cAbility - COL_TARGET_MIN
		if extra > 0 then cAbility = cAbility + math.floor(extra * 0.25) end
		return cAbility, avail - cAbility, 0, pad, gap
	end
	local avail = W - pad - ICON_W - gap - gap - gap - pad
	local cAbility, cTarget = COL_ABILITY_MIN, COL_TARGET_MIN
	local cAssignee = avail - cAbility - cTarget
	if cAssignee < COL_ASSIGNEE_MIN then
		-- Window too narrow: steal from target first, then ability.
		local deficit = COL_ASSIGNEE_MIN - cAssignee
		local takeFromTarget = math.min(deficit, cTarget - 40)
		cTarget = cTarget - takeFromTarget
		deficit = deficit - takeFromTarget
		if deficit > 0 then cAbility = math.max(60, cAbility - deficit) end
		cAssignee = COL_ASSIGNEE_MIN
	else
		local extra = cAssignee - COL_ASSIGNEE_MIN
		local addAbility = math.floor(extra * 0.15)
		local addTarget = math.floor(extra * 0.25)
		cAbility = cAbility + addAbility
		cTarget = cTarget + addTarget
		cAssignee = cAssignee - addAbility - addTarget
	end
	return cAbility, cTarget, cAssignee, pad, gap
end

local function layoutAssignments(ctx)
	local pull, my, W = ctx.pull, ctx.my, ctx.W
	local nonReminder = {}
	for _, a in ipairs(pull.assignments or {}) do
		if a.kind ~= "reminder" and hasContent(a) and (not my or CRP.ui.IsMyAssignment(a)) then
			nonReminder[#nonReminder + 1] = a
		end
	end
	if #nonReminder == 0 then return end

	placeSection(ctx, "Assignments")
	local cAbility, cTarget, cAssignee, pad, gap = computeAssignmentColumns(W, my)

	-- Header row. FontString labels (not Frame-cells); anchorCell isn't a fit
	-- since FontStrings don't have TOP/BOTTOM anchors on their parent the same
	-- way Frame cells do.
	local hRow = getTableHeader()
	hRow:ClearAllPoints()
	hRow:SetPoint("TOPLEFT", content, "TOPLEFT", pad, -ctx.y)
	hRow:SetPoint("TOPRIGHT", content, "TOPRIGHT", -pad, -ctx.y)
	hRow.ability:ClearAllPoints()
	hRow.ability:SetPoint("LEFT", hRow, "LEFT", ICON_W + gap, 0)
	hRow.ability:SetWidth(cAbility)
	hRow.target:ClearAllPoints()
	hRow.target:SetPoint("LEFT", hRow.ability, "RIGHT", gap, 0)
	hRow.target:SetWidth(cTarget)
	if my then
		hRow.assignee:Hide()
	else
		hRow.assignee:ClearAllPoints()
		hRow.assignee:SetPoint("LEFT", hRow.target, "RIGHT", gap, 0)
		hRow.assignee:SetWidth(cAssignee)
		hRow.assignee:Show()
	end
	hRow:Show()
	ctx.y = ctx.y + 14

	for _, a in ipairs(nonReminder) do
		ctx.aIdx = ctx.aIdx + 1
		local row = getAssignRow(ctx.aIdx)
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", content, "TOPLEFT", pad, -ctx.y)
		row:SetPoint("TOPRIGHT", content, "TOPRIGHT", -pad, -ctx.y)

		local icon, ability, target = resolveAssignmentRow(a)
		row.icon:SetTexture(icon or ICON_FALLBACK)

		anchorCell(row.ability, row, "LEFT", ICON_W + gap, cAbility)
		row.ability.fs:SetText(ability)
		row.ability._tip = ability ~= "" and ability or nil

		anchorCell(row.target, row.ability, "RIGHT", gap, cTarget)
		row.target.fs:SetText(target)
		row.target._tip = target ~= "" and target or nil

		local player = a.player or ""
		local role = a.role or ""
		local note = a.note or ""
		if my then
			-- Assignee is hidden in My view. If there's a note, append it to
			-- the ability tooltip so it stays discoverable on hover.
			row.assignee:Hide()
			if note ~= "" then row.ability._tip = ability .. "\n\n" .. note end
		else
			-- Who it's for: a named player (cyan) wins; otherwise the role
			-- label (amber, reads as a group). Combined with the note.
			local who, color
			if player ~= "" then
				who, color = player, "c084fc"
			elseif role ~= "" then
				who, color = ROLE_LABEL[role] or role, "ffd100"
			end
			local assigneeText
			if who and note ~= "" then
				assigneeText = string.format("|cff%s%s:|r %s", color, who, note)
			elseif who then
				assigneeText = string.format("|cff%s%s|r", color, who)
			else
				assigneeText = note
			end
			local tipParts = {}
			if who then
				tipParts[#tipParts + 1] = string.format("|cff%s%s|r", color, who)
			end
			if note ~= "" then tipParts[#tipParts + 1] = note end
			anchorCell(row.assignee, row.target, "RIGHT", gap, cAssignee)
			row.assignee.fs:SetText(assigneeText)
			row.assignee._tip = (#tipParts > 0) and table.concat(tipParts, "\n") or nil
			row.assignee:Show()
		end

		row:Show()
		ctx.y = ctx.y + ASSIGN_ROW_H
	end
	ctx.y = ctx.y + SECTION_GAP
end

local function layoutUpcoming(ctx)
	local idx, pulls = ctx.idx, ctx.pulls
	local previews = {}
	for offset = 1, 3 do
		local up = pulls[idx + offset]
		if up then previews[#previews + 1] = { i = idx + offset, pull = up } end
	end
	if #previews == 0 then return end
	placeSection(ctx, "Upcoming", true)
	for _, p in ipairs(previews) do
		ctx.uIdx = ctx.uIdx + 1
		local row = getUpcomingRow(ctx.uIdx)
		addChrome(row)
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", content, "TOPLEFT", 2, -ctx.y)
		row:SetPoint("TOPRIGHT", content, "TOPRIGHT", -2, -ctx.y)
		row.num:SetText(tostring(p.i))
		-- Mobs if the pull has any; otherwise summarize its actions so prep steps
		-- (no mobs) aren't blank in the preview.
		local summary = pullMobSummary(p.pull)
		if summary == "" then summary = pullAssignmentSummary(p.pull) end
		row.name:SetText(summary)
		row._tip = isTruncated(row.name) and summary or nil
		row:EnableMouse(true)
		row:SetScript("OnClick", function() CRP.Plan:SetCurrentPullIdx(p.i) end)
		row:Show()
		ctx.y = ctx.y + UPCOMING_ROW_H
	end
	ctx.y = ctx.y + SECTION_GAP
end

-- While parked on a prep step, preview the upcoming real pull's notes so the
-- raid leader can read them and start the callout during prep/running. The
-- Upcoming section already lists what's in each pull; this surfaces the next
-- pull's note + reminders (the bits Upcoming doesn't), under a "Next:" header.
-- Skipped when there's no callout material — Upcoming covers the rest.
local function layoutNextPull(ctx)
	if not (CRP.Plan and CRP.Plan:IsPrepPull(ctx.pull)) then return end
	-- First real pull after this (possibly multi-step) prep run.
	local j = ctx.idx + 1
	while ctx.pulls[j] and CRP.Plan:IsPrepPull(ctx.pulls[j]) do j = j + 1 end
	local nextPull = ctx.pulls[j]
	if not nextPull then return end

	local noteText = nextPull.note or ""
	local reminders = {}
	for _, a in ipairs(nextPull.assignments or {}) do
		if a.kind == "reminder" and hasContent(a) and (not ctx.my or CRP.ui.IsMyAssignment(a)) then
			reminders[#reminders + 1] = a
		end
	end
	if noteText == "" and #reminders == 0 then return end

	local name = pullDisplayName(nextPull)
	local title = name ~= "" and name or ("Pull " .. j)
	placeSection(ctx, "Next: " .. title)
	local W = ctx.W

	if noteText ~= "" then
		ctx.nIdx = ctx.nIdx + 1
		local np = getNoteParagraph(ctx.nIdx)
		np:ClearAllPoints()
		np:SetPoint("TOPLEFT", content, "TOPLEFT", 10, -ctx.y)
		np:SetWidth(W - 14)
		np:SetText(noteText)
		np:Show()
		ctx.y = ctx.y + math.max(14, np:GetStringHeight()) + 4
	end
	for _, r in ipairs(reminders) do
		ctx.bIdx = ctx.bIdx + 1
		local b = getBullet(ctx.bIdx)
		b:ClearAllPoints()
		b:SetPoint("TOPLEFT", content, "TOPLEFT", 10, -ctx.y)
		b:SetWidth(W - 14)
		b:SetText("- " .. (r.text or ""))
		b:Show()
		ctx.y = ctx.y + math.max(12, b:GetStringHeight()) + BULLET_GAP
	end
	ctx.y = ctx.y + SECTION_GAP
end

function Window:Refresh()
	if not frame then return end
	local plan = CRP.Plan:Current()
	local pulls = CRP.Plan:Pulls()
	local my = isMyView()

	-- Clear every pool by default; section functions Show only what they use.
	for _, s in ipairs(sectionPool) do s:Hide() end
	for _, b in ipairs(bulletPool) do b:Hide() end
	for _, p in ipairs(progressPool) do p:Hide() end
	for _, r in ipairs(assignPool) do r:Hide() end
	for _, u in ipairs(upcomingPool) do u:Hide() end
	for _, np in ipairs(noteParagraphPool) do np:Hide() end
	if tableHeader then tableHeader:Hide() end

	-- Rebuild chrome list: statics first, then dynamic sections register
	-- themselves during layout below.
	resetChrome()
	if frame._chromeStatic then
		for _, obj in ipairs(frame._chromeStatic) do addChrome(obj) end
	end

	if not plan or #pulls == 0 then
		pullTitle:SetText("")
		packLine:SetText("")
		pullCounter:SetText("")
		content:SetHeight(1)
		emptyMsg:Show()
		return
	end
	emptyMsg:Hide()

	local idx = CRP.Plan:CurrentPullIdx()
	local pull = pulls[idx]
	pullCounter:SetText(string.format("Pull %d / %d", idx, #pulls))

	-- Header text. In My view the nav strip is hidden so we inline the counter
	-- into the title; in Raid view the counter lives in the nav strip. Trash
	-- pulls have no name, so they read by position number alone.
	local name = pullDisplayName(pull)
	if my then
		if name ~= "" then
			pullTitle:SetText(string.format("Pull %d/%d — %s", idx, #pulls, name))
		else
			pullTitle:SetText(string.format("Pull %d/%d", idx, #pulls))
		end
	else
		pullTitle:SetText(name ~= "" and name or string.format("Pull %d", idx))
	end
	local pn = packNames(pull)
	packLine:SetText(pn ~= "" and ("Packs: " .. pn) or "")

	-- Read width from the scroll frame since `content` itself may not yet be
	-- sized this frame.
	local W = frame._scroll and frame._scroll:GetWidth() or RAID_W - 30
	if W < 1 then W = RAID_W - 30 end
	content:SetWidth(W)

	local ctx = {
		y = 0,
		sIdx = 0, bIdx = 0, pIdx = 0, aIdx = 0, uIdx = 0, nIdx = 0,
		W = W,
		pull = pull,
		my = my,
		idx = idx,
		pulls = pulls,
	}
	layoutPullNotes(ctx)
	if not my then layoutKillProgress(ctx) end
	layoutAssignments(ctx)
	layoutNextPull(ctx)
	if not my then layoutUpcoming(ctx) end

	content:SetHeight(math.max(1, ctx.y))
	-- Re-apply current fade alpha so newly added chrome (kill-progress /
	-- upcoming rows) matches the current hover state on the very next frame.
	applyChromeAlpha(chromeAlpha)
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
	if frame then frame:Hide() end
end

function Window:Toggle()
	if frame and frame:IsShown() then
		self:Hide()
	else
		self:Show()
	end
end

function Window:OnItemInfoReceived(itemId, ok)
	if ok and pendingItemIds[itemId] then
		pendingItemIds[itemId] = nil
		self:Refresh()
	end
end

-- ----- pull popup (jump-to-pull menu, unchanged) -----------------------------

local pullPopup, pullPopupRowPool, pullPopupContent, pullPopupScroll
local PULL_POPUP_W, PULL_POPUP_H = 200, 220
local PULL_POPUP_ROW_H = 16

function buildPullPopup()
	pullPopup = CreateFrame("Frame", "CafeRaidPlannerPullPopup", UIParent, "BackdropTemplate")
	pullPopup:SetFrameStrata("TOOLTIP")
	pullPopup:SetSize(PULL_POPUP_W, PULL_POPUP_H)
	pullPopup:SetPoint("CENTER")
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
	pullPopupContent:SetSize(PULL_POPUP_W - 8 - 28, 1)
	pullPopupScroll:SetScrollChild(pullPopupContent)
	pullPopupRowPool = {}

	pullPopup:SetScript("OnShow", function(self) self:RegisterEvent("GLOBAL_MOUSE_DOWN") end)
	pullPopup:SetScript("OnHide", function(self) self:UnregisterEvent("GLOBAL_MOUSE_DOWN") end)
	pullPopup:SetScript("OnEvent", function(self, event)
		if event == "GLOBAL_MOUSE_DOWN"
			and not self:IsMouseOver()
			and not (pullCounter and pullCounter:IsMouseOver()) then
			self:Hide()
		end
	end)
end

function refreshPullPopupRows()
	if not pullPopup then return end
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
			row:SetScript("OnEnter", function(s) s.bg:SetColorTexture(1, 1, 1, 0.12) end)
			row:SetScript("OnLeave", function(s) s.bg:SetColorTexture(1, 1, 1, 0) end)
			row:ClearAllPoints()
			row:SetPoint("TOPLEFT", pullPopupContent, "TOPLEFT", 0, -(i - 1) * PULL_POPUP_ROW_H)
			row:SetPoint("RIGHT", pullPopupContent, "RIGHT", 0, 0)
			pullPopupRowPool[i] = row
		end
		row:SetScript("OnClick", function()
			CRP.Plan:SetCurrentPullIdx(i)
			pullPopup:Hide()
		end)
		local prefix = (i == currentIdx) and "|cffffd54a>|r " or "   "
		local name = pullDisplayName(pull)
		local label = name ~= "" and string.format("%d. %s", i, name) or ("Pull " .. i)
		row.text:SetText(prefix .. label)
		row:Show()
	end
	for i = #pulls + 1, #pullPopupRowPool do pullPopupRowPool[i]:Hide() end
	pullPopupContent:SetHeight(math.max(1, #pulls * PULL_POPUP_ROW_H))
	if pullPopupScroll.UpdateScrollChildRect then pullPopupScroll:UpdateScrollChildRect() end
	if not pullPopup._warmed then
		pullPopup._warmed = true
		pullPopup:Show()
		pullPopup:Hide()
	end
end

function Window:TogglePullPopup(anchorBtn)
	if not pullPopup then return end
	if pullPopup:IsShown() then
		pullPopup:Hide()
		return
	end
	refreshPullPopupRows()
	pullPopup:ClearAllPoints()
	pullPopup:SetPoint("TOPLEFT", anchorBtn, "BOTTOMLEFT", 0, -2)
	pullPopup:Show()
end

-- ----- import dialog (unchanged) --------------------------------------------

function Window:ShowImport()
	if not importDialog then
		importDialog = CreateFrame("Frame", "CafeRaidPlannerImport", UIParent, "BackdropTemplate")
		importDialog:SetSize(520, 300)
		importDialog:SetPoint("CENTER")
		importDialog:SetFrameStrata("DIALOG")
		importDialog:EnableMouse(true)
		importDialog:SetMovable(true)
		importDialog:RegisterForDrag("LeftButton")
		importDialog:SetScript("OnDragStart", function(s) s:StartMoving() end)
		importDialog:SetScript("OnDragStop", function(s) s:StopMovingOrSizing() end)
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

		local scroll = CreateFrame(
			"ScrollFrame", "CafeRaidPlannerImportScroll", importDialog, "InputScrollFrameTemplate")
		scroll:SetPoint("TOPLEFT", 16, -40)
		scroll:SetPoint("BOTTOMRIGHT", -32, 60)
		local edit = scroll.EditBox or _G["CafeRaidPlannerImportScrollEditBox"]
		if edit then
			edit:SetMaxLetters(0)
			edit:SetFontObject("ChatFontSmall")
			-- InputScrollFrameTemplate's EditBox keeps its template default width
			-- unless we sync it to the scroll frame; without this the text
			-- renders in a 1-pixel column and looks like nothing was pasted.
			-- Keep it synced on resize too in case the dialog grows.
			local function syncEditWidth()
				edit:SetWidth(scroll:GetWidth())
			end
			syncEditWidth()
			scroll:HookScript("OnSizeChanged", syncEditWidth)
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
		closeBtn:SetScript("OnClick", function() importDialog:Hide() end)
	end
	if importDialog.edit then importDialog.edit:SetText("") end
	importDialog.status:SetText("")
	importDialog:Show()
end
