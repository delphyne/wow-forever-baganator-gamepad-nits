-- BaganatorGamepadNits: fixes layered on top of BaganatorGamepad for World of Warcraft: Forever's native
-- controller UI. Neither Baganator nor BaganatorGamepad is edited; CLAUDE.md explains how this attaches to them.
--
-- 1. Paging between a Baganator window and a Blizzard panel (the merchant, mainly), like the stock bag does.
--    While a Blizzard panel has controller focus, BaganatorGamepad's override bindings are held back so the panel
--    can be navigated, the Baganator window shows Blizzard's RT jump hint, and RT drops the panel's focus, which
--    hands the keys back to BaganatorGamepad. While the Baganator window is navigated, the panel shows the LT
--    jump hint and LT focuses it again. Both triggers run Blizzard's TOGGLEUIFOCUS binding command through an
--    override binding, so the client executes it untainted; this addon never calls into FrameControlsManager.
-- 2. A button legend under the navigated Baganator window, built from Blizzard's own input legend widgets, so it
--    matches the footer under the stock bag: A select, X sell/equip/use, B close/back.
-- 3. Baganator 847 grew its own controller capture that swallows every button while a bag is open, so nothing
--    reaches BaganatorGamepad; it is disarmed here (see "Baganator's own controller capture" below).
-- 4. The stock bag's Y "more actions" menu for the selected item (Destroy, Split Stack, Share in Chat, Feed to
--    Pet), as our own frame and bindings (see "More actions" below), and BaganatorGamepad's keys held back while
--    a Blizzard popup (the destroy confirmation, say) is up so the popup gets A/B.

local VIEW_PATTERNS = { "BackpackViewFrame", "BankViewFrame" }
local KEYS = {
	lt = GAMEPAD_TRIGGER_LEFT or "PADLTRIGGER",
	rt = GAMEPAD_TRIGGER_RIGHT or "PADRTRIGGER",
	pickup = GAMEPAD_FACE_BOTTOM or "PAD1",
	back = GAMEPAD_FACE_RIGHT or "PAD2",
	use = GAMEPAD_FACE_LEFT or "PAD3",
	more = GAMEPAD_FACE_TOP or "PAD4",
	up = GAMEPAD_DPAD_TOP or "PADDUP",
	down = GAMEPAD_DPAD_BOTTOM or "PADDDOWN",
	left = GAMEPAD_DPAD_LEFT or "PADDLEFT",
	right = GAMEPAD_DPAD_RIGHT or "PADDRIGHT",
}
local TOGGLE_UI_FOCUS = "TOGGLEUIFOCUS"
local PREVIOUS_WINDOW_BUTTON = "BaganatorGamepadPreviousWindow" -- BaganatorGamepad's own LT target
local POLL_INTERVAL = 0.1

local hooked = {} -- Baganator view frames we watch
local bgOwner -- BaganatorGamepad's binding owner frame, learnt from its first SetOverrideBindingClick
local bgActive = false -- BaganatorGamepad believes it holds the keys
local bgHighlight -- its gold selection border (an anonymous frame), found by EnumerateFrames
local bgHighlightSearched = 0
local suppressed = false -- a Blizzard panel has focus; BaganatorGamepad's keys are held back
local wantLeft = false -- LT should run TOGGLEUIFOCUS instead of BaganatorGamepad's window switch
local rightBound = false -- RT currently runs TOGGLEUIFOCUS (set on bgOwner)
local moreBound = false -- Y currently opens our more-actions menu (set on bgOwner)
local hintedFrame -- Blizzard panel currently showing our LT hint
local clearingOurselves = false
local rebindingOurselves = false
local pending = false

-- A short log of what was bound and why, for "/bgnits log": binding fights with other controller addons (GamepadXIV,
-- say) are hard to see after the fact, and a TOGGLEUIFOCUS press with no panel shown only prints Blizzard's
-- "No interface frame to focus".
local LOG_SIZE = 40
local log, logCount = {}, 0
local function note(...)
	local parts = {}
	for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
	logCount = logCount + 1
	log[(logCount - 1) % LOG_SIZE + 1] = ("%.1f %s"):format(GetTime(), table.concat(parts, " "))
end

local ownOwner = CreateFrame("Frame", "BaganatorGamepadNits_Owner", UIParent)
local noopButton = CreateFrame("Button", "BaganatorGamepadNits_Noop", UIParent)

local function manager()
	return GamepadMode and GamepadMode.FrameControlsManager
end

local function gamepadUI()
	return InputUtil and InputUtil.IsGamepadUIEnabled() and manager() ~= nil
end

local function center(frame)
	local l, b, w, h = frame:GetScaledRect()
	if l then return l + w / 2, b + h / 2 end
end

local function visibleViews()
	local views = {}
	for view in pairs(hooked) do
		if view:IsVisible() then table.insert(views, view) end
	end
	table.sort(views, function(a, b) return (center(a) or 0) < (center(b) or 0) end)
	return views
end

local function viewOf(frame)
	while frame do
		if hooked[frame] then return frame end
		frame = frame:GetParent()
	end
end

-- The Blizzard panel RT would hand off from: the focused one, when it is last in the manager's screen-ordered
-- list, so Blizzard's own RT (focus next frame) has nothing to do there. The stock bag sorts last the same way.
-- Only while the UI is focused: TOGGLEUIFOCUS would otherwise focus the panel instead of leaving it (with only a
-- popup up, say).
local function lastFocusedPanel()
	local m = manager()
	local frames = m and m.shownFrames
	if not frames or #frames == 0 or not m.isUIFocused then return end
	local frame = m.focusedFrame
	if frame and frame == frames[#frames] and frame:IsShown() then return frame end
end

-- The Blizzard panel LT would focus: whatever the manager will focus when the UI is focused again.
local function unfocusedPanel()
	local m = manager()
	if not m or not m.shownFrames or #m.shownFrames == 0 or m.isUIFocused then return end
	local frame = m.focusedFrame
	if frame and frame:IsShown() then return frame end
end

-----------------------------------------------------------------------------------------------------------------
-- BaganatorGamepad's selection

local function findHighlight()
	if not EnumerateFrames then return end
	local frame = EnumerateFrames()
	while frame do
		-- Forbidden frames (Blizzard's own, nameplates) are enumerated too; any other method call on one raises
		-- "blocked from an action only available to the Blizzard UI".
		if not frame:IsForbidden() and frame:GetObjectType() == "Frame" and not frame:GetName() and frame:GetParent() == UIParent
			and frame:GetFrameStrata() == "TOOLTIP" and frame.GetBackdropBorderColor then
			local r, g, b = frame:GetBackdropBorderColor()
			if r and math.abs(r - 1) < 0.01 and math.abs(g - 0.82) < 0.01 and b < 0.01 then
				return frame
			end
		end
		frame = EnumerateFrames(frame)
	end
end

local highlightSearches = 0
local function highlight()
	if not bgHighlight and bgActive and highlightSearches < 3 and GetTime() - bgHighlightSearched > 5 then
		bgHighlightSearched = GetTime()
		highlightSearches = highlightSearches + 1
		bgHighlight = findHighlight()
	end
	return bgHighlight
end

-- The bag and slot of a Baganator item button, or nothing. Baganator's bag-slot and other buttons answer GetBagID
-- too, with nil, and the container API raises an error on that.
local function slotOf(button)
	if not button or not button.GetBagID or not button.GetID then return end
	local ok, bag = pcall(button.GetBagID, button)
	local slot = button:GetID()
	if ok and type(bag) == "number" and type(slot) == "number" then return bag, slot end
end

local function highlightTarget()
	local border = highlight()
	if not border then return end
	local _, relativeTo = border:GetPoint(1)
	if relativeTo and slotOf(relativeTo) and relativeTo:IsVisible() and viewOf(relativeTo) then return relativeTo end
end

-- The item button BaganatorGamepad has selected: the one its border is anchored to, else the one whose tooltip
-- it opened (it calls the button's OnEnter on selection).
local function selectedButton()
	local border = highlight()
	if border and border:IsShown() then
		local target = highlightTarget()
		if target then return target end
	end
	if GameTooltip:IsShown() then
		local owner = GameTooltip:GetOwner()
		if owner and slotOf(owner) and owner:IsVisible() and viewOf(owner) then return owner end
	end
end

local function selectedItemID()
	local button = selectedButton()
	local bag, slot = slotOf(button)
	if not bag then return end
	local info = C_Container.GetContainerItemInfo(bag, slot)
	return info and info.itemID, button
end

-----------------------------------------------------------------------------------------------------------------
-- Bindings. Everything is set on BaganatorGamepad's own owner frame: it re-asserts its keys whenever another owner
-- binds one of them, which would loop forever, but ignores bindings made with its owner. Its next applyBindings
-- overwrites ours, and our SetOverrideBindingClick hook puts them back right after.

local function canBind()
	return bgOwner ~= nil and not InCombatLockdown()
end

local function setRight(on)
	if not canBind() then return end
	note("RT", on and TOGGLE_UI_FOCUS or "cleared")
	SetOverrideBinding(bgOwner, true, KEYS.rt, on and TOGGLE_UI_FOCUS or nil)
	rightBound = on
end

local function setLeft(on)
	if not canBind() then return end
	note("LT", on and TOGGLE_UI_FOCUS or PREVIOUS_WINDOW_BUTTON)
	if on then
		SetOverrideBinding(bgOwner, true, KEYS.lt, TOGGLE_UI_FOCUS)
	else
		rebindingOurselves = true
		SetOverrideBindingClick(bgOwner, true, KEYS.lt, PREVIOUS_WINDOW_BUTTON)
		rebindingOurselves = false
	end
end

-- Hold back BaganatorGamepad's keys while a Blizzard panel is focused; keep RT to come back.
local function releaseBaganatorGamepad()
	if not canBind() then return end
	clearingOurselves = true
	ClearOverrideBindings(bgOwner)
	clearingOurselves = false
	rightBound = false
	moreBound = false
	if lastFocusedPanel() then setRight(true) end
end

-- Make BaganatorGamepad re-apply its bindings next frame: it does so when a foreign owner binds one of its keys.
local function pokeBaganatorGamepad()
	if InCombatLockdown() then return end
	SetOverrideBindingClick(ownOwner, true, KEYS.rt, noopButton:GetName())
	ClearOverrideBindings(ownOwner)
end

-- What a key does right now, override bindings included. (Forever has no global GetBindingByKey, only
-- C_KeyBindings.GetBindingByKey; GetBindingAction with checkOverride is the one that sees override bindings.)
local function boundAction(key)
	return GetBindingAction(key, true)
end

-- A trigger still running TOGGLEUIFOCUS when the state above no longer calls for it (whatever path left it there) is
-- taken back, and BaganatorGamepad asked to put its own window switch on it again.
local function dropToggleFocus(key)
	if not canBind() or boundAction(key) ~= TOGGLE_UI_FOCUS then return end
	note("stale", key, "cleared")
	SetOverrideBinding(bgOwner, true, key, nil)
	if key == KEYS.rt then rightBound = false end
	if bgActive then pokeBaganatorGamepad() end
end

-- The Blizzard panel LT should focus from the navigated Baganator window: one Baganator window open (with two,
-- BaganatorGamepad uses LT/RT to switch between them), BaganatorGamepad holding the keys, and a panel to go to.
local function leftFocusTarget(views)
	views = views or visibleViews()
	if not gamepadUI() or #views ~= 1 or suppressed or not bgActive then return end
	return unfocusedPanel()
end

-----------------------------------------------------------------------------------------------------------------
-- Baganator's own controller capture (Baganator 847+, ItemViewCommon/GamepadTrap.lua). While a bag is open it
-- shows an anonymous frame on UIParent with OnGamePadButtonDown/Up and OnGamePadStick handlers. The frame only
-- propagates the Menu button and the right stick, so every other button (d-pad, A/B/X/Y, left stick) is eaten
-- before any binding, BaganatorGamepad's included, and two leftover debug prints spam chat ("gpb <button>" on
-- each release, the stick name on each right-stick tick). It also override-binds X to BaganatorGamepadClicker,
-- which clicks the first bag slot. Both are disarmed: the frame's scripts are removed and its gamepad input
-- switched off, and the clicker's binding is cleared whenever Baganator sets it. Its focus glow on the bag is
-- left alone. The frame is found once by EnumerateFrames, keyed on the named clicker existing.

local TRAP_CLICKER = "BaganatorGamepadClicker"
local trapFrame
local trapSearches = 0

local function findTrapFrame()
	if not EnumerateFrames then return end
	local frame = EnumerateFrames()
	while frame do
		if not frame:IsForbidden() and frame:GetObjectType() == "Frame" and not frame:GetName() and frame:GetParent() == UIParent
			and frame:GetScript("OnGamePadButtonUp") and frame.IsGamePadStickEnabled and frame:IsGamePadStickEnabled() then
			return frame
		end
		frame = EnumerateFrames(frame)
	end
end

local function disarmTrap()
	local clicker = _G[TRAP_CLICKER]
	if trapFrame or not clicker or trapSearches >= 3 then return end
	trapSearches = trapSearches + 1
	trapFrame = findTrapFrame()
	if not trapFrame then return end
	for _, script in ipairs({ "OnGamePadButtonDown", "OnGamePadButtonUp", "OnGamePadStick" }) do
		trapFrame:SetScript(script, nil)
	end
	if trapFrame.EnableGamePadButton then trapFrame:EnableGamePadButton(false) end
	if trapFrame.EnableGamePadStick then trapFrame:EnableGamePadStick(false) end
	if not InCombatLockdown() then ClearOverrideBindings(clicker) end
end

-- Baganator re-binds X to the clicker every time a bag opens (and after combat); drop it again each time.
hooksecurefunc("SetOverrideBindingClick", function(owner)
	if owner ~= nil and owner == _G[TRAP_CLICKER] and not InCombatLockdown() then ClearOverrideBindings(owner) end
end)

disarmTrap()

-----------------------------------------------------------------------------------------------------------------
-- Baganator's native controller navigation (Baganator 850+, ItemViewCommon/Gamepad.lua and BankView.lua). Each
-- time a bag or bank window shows, Baganator defers GamepadMode.FrameControlsManager:FrameShown(view) by a frame
-- with C_Timer.After(0, ...). That makes the window a managed, focused Blizzard panel: isUIFocused goes true (so
-- we would hold BaganatorGamepad back for good) and the manager's state is written from addon code. There is no
-- setting for it and the functions are private, but the deferred closure passes through C_Timer.After, where a
-- secure hook can see it: closures created in those two files get an environment in which GamepadMode's
-- FrameControlsManager is a stub, so the registration never reaches Blizzard's manager. Nothing of Blizzard's or
-- Baganator's is replaced; every other global still resolves through _G.

local nativeNavBlocked = 0
if C_Timer and C_Timer.After and setfenv and debugstack then
	local stubManager = { FrameShown = function() nativeNavBlocked = nativeNavBlocked + 1 end }
	local stubEnv = setmetatable({
		GamepadMode = setmetatable({ FrameControlsManager = stubManager }, { __index = function(_, k) return GamepadMode and GamepadMode[k] end }),
	}, { __index = _G, __newindex = _G })
	hooksecurefunc(C_Timer, "After", function(seconds, callback)
		if seconds ~= 0 or type(callback) ~= "function" then return end
		local stack = debugstack(2, 6, 0)
		-- Baganator's customise dialog announces itself through the same AnnounceShow; it is no bag, so it keeps its
		-- focus.
		if stack and not stack:find("CustomiseDialog")
			and (stack:find("Baganator[/\\]ItemViewCommon[/\\]Gamepad%.lua") or stack:find("Baganator[/\\]ItemViewCommon[/\\]BankView%.lua")) then
			pcall(setfenv, callback, stubEnv)
		end
	end)
end

-----------------------------------------------------------------------------------------------------------------
-- Jump hints. The RT hint on the Baganator window is our own frame from Blizzard's template. The LT hint on the
-- Blizzard panel is the panel's own LeftJumpHint frame, which FrameControlsManager only ever shows or hides; we show
-- it, and hide the "focus UI" hint Blizzard puts there while the UI is unfocused, after each of its refreshes.

local rightHint
do
	local ok, frame = pcall(CreateFrame, "Frame", "BaganatorGamepadNits_RightHint", UIParent, "FrameRightJumpHintTemplate")
	if ok and frame then
		rightHint = frame
		rightHint:SetFrameStrata("HIGH")
		rightHint:SetFrameLevel(515)
		rightHint:Hide()
	end
end

local function showRightHint(view)
	if not rightHint then return end
	if not view then return rightHint:Hide() end
	rightHint:ClearAllPoints()
	rightHint:SetPoint("CENTER", view, "BOTTOM", 0, 4)
	rightHint:Show()
end

local function restoreBlizzardHints(frame)
	if frame.LeftJumpHint then frame.LeftJumpHint:Hide() end
	local m = manager()
	if frame.FocusJumpHint and m and m.focusedFrame == frame and not m.isUIFocused
		and not frame.disableFrameFocusPagingWhenFocused and frame:IsShown() then
		frame.FocusJumpHint:Show()
	end
end

local function setLeftHint(frame)
	if hintedFrame and hintedFrame ~= frame then
		restoreBlizzardHints(hintedFrame)
		hintedFrame = nil
	end
	if frame and frame.LeftJumpHint then
		frame.LeftJumpHint:Show()
		if frame.FocusJumpHint then frame.FocusJumpHint:Hide() end
		hintedFrame = frame
	end
end

-----------------------------------------------------------------------------------------------------------------
-- Legend. InputPromptLegends draws the footer under every Blizzard panel; it only needs objects that answer the
-- five questions below, so no prompted bindings or binding groups are involved.

local legendHost = CreateFrame("Frame", "BaganatorGamepadNits_Legend", UIParent)
legendHost:SetSize(1, 1)
legendHost:SetPoint("CENTER")
legendHost:SetFrameStrata("HIGH")
local legend, legendSignature
local context = {}

local function label(global, fallback)
	return function() return _G[global] or fallback end
end

local function newPrompt(key, labelFn, enabledFn)
	local prompt = { key = key }
	function prompt:GetInputIconTemplate() return InputPromptLegends.PromptTemplates.StandardOneIcon end
	function prompt:GetDisplayKeys() return { key } end
	function prompt:GetFooterBindingLabel() return labelFn() end
	function prompt:IsFooterConditionMet() return enabledFn() end
	function prompt:IsFooterHoldPrompt() return false end
	return prompt
end

local pick, sell, equip, use, close, back =
	label("ACTION_LABEL_SELECT", "Select"), label("CONTEXT_ACTION_LABEL_SELL", "Sell"),
	label("CONTEXT_ACTION_LABEL_EQUIP", "Equip"), label("CONTEXT_ACTION_LABEL_USE", "Use"),
	label("FRAME_ACTION_CLOSE", "Close"), label("FRAME_ACTION_BACK", "Back")

local prompts = {
	newPrompt(KEYS.pickup, pick, function() return context.itemID ~= nil or context.cursor end),
	newPrompt(KEYS.use, function()
		if context.merchant then return sell() end
		if context.equippable then return equip() end
		return use()
	end, function()
		if not context.itemID or context.cursor then return false end
		if context.merchant then return true end
		return context.equippable or context.usable
	end),
	newPrompt(KEYS.more, label("CONTEXT_ACTION_LABEL_MORE_ACTIONS", "More Actions"), function()
		return context.itemID ~= nil and not context.cursor and not context.merchant
	end),
	newPrompt(KEYS.back, function() return context.cursor and back() or close() end, function() return true end),
}

local function ensureLegend()
	if legend or not InputPromptLegends or not InputPromptLegends.CreateInputLegend then return legend end
	local ok, result = pcall(InputPromptLegends.CreateInputLegend, legendHost, "inputLegend")
	if not ok or not result then return end
	legend = result
	-- The legend lays prompts out in creation order; create them now, in the order Blizzard's footers use.
	for _, prompt in ipairs(prompts) do
		pcall(legend.GetOrCreatePromptFrameUsingTemplateAndInputs, legend, "StandardOneIcon", { prompt.key }, GAMEPAD_PROMPT_DIVIDER_SLASH)
	end
	legend:Hide()
	return legend
end

local function refreshLegend(view)
	if not ensureLegend() then return end
	if not view then
		legend:Hide()
		legendSignature = nil
		return
	end
	local itemID = selectedItemID()
	context.itemID = itemID
	context.cursor = CursorHasItem()
	context.merchant = MerchantFrame and MerchantFrame:IsShown() or false
	context.equippable = itemID and C_Item.IsEquippableItem(itemID) or false
	context.usable = itemID and C_Item.IsUsableItem(itemID) or false
	local signature = table.concat({ tostring(view), tostring(itemID), tostring(context.cursor), tostring(context.merchant),
		tostring(context.equippable), tostring(context.usable) }, "|")
	if signature ~= legendSignature then
		legendSignature = signature
		legend:RefreshWithPromptedBindings(prompts)
		legend:ClearAllPoints()
		legend:SetPoint("TOPLEFT", view, "BOTTOMLEFT", 0, -4)
	end
	legend:Show()
end

-----------------------------------------------------------------------------------------------------------------
-- More actions (Y). The stock bag's Y opens a context menu for the selected item: Feed to Pet (hunters), Bind to
-- Gamepad Action Bar, Destroy, Share in Chat, Split Stack (Blizzard_UIPanels_Game/Mainline/ContainerFrame.lua,
-- SetupGamepad, itemMoreActions). Blizzard builds it with MenuUtil.CreateContextMenu and the gamepad manager then
-- focuses it; opening a Blizzard menu from addon code would taint that path (taint rule in CLAUDE.md), so this is
-- our own frame, navigated with our own bindings on BaganatorGamepad's owner like LT/RT. Entries:
--   Destroy: PickupContainerItem + DeleteCursorItem inside the key's hardware event; the client raises
--     DELETE_ITEM_CONFIRM and Blizzard shows its confirmation popup (C_Item.ConfirmDeleteItem, which the stock
--     bag uses, carries the same restriction flag and is untested from addon code).
--   Split Stack: our own stepper (d-pad left/right 1, up/down 10; A puts the split on the cursor, B cancels), then
--     A on an empty slot places it through BaganatorGamepad. Blizzard's StackSplitFrame is a gamepad-managed frame.
--   Share in Chat: inserts the link into the open chat edit box; only offered while one is open (opening chat from
--     addon code is another managed-frame path).
--   Feed to Pet: hunters, for items the pet can eat.
--   Bind to Gamepad Action Bar is not offered: it opens GamepadActionBarEditFrame, a managed frame.
-- Like the stock bag, the menu is unavailable while an item is held or a merchant is open. Everything here only
-- reads Baganator's item buttons (GetBagID/GetID) and the container API.

local MORE_BUTTON = "BaganatorGamepadNits_More"
local FEED_PET_SPELL_ID = 6991
local SPLIT_BIG_STEP = 10
local MENU_ROW_HEIGHT, MENU_PAD = 22, 8

local menuOpen = false
local menuMode -- "list" or "split"
local menuEntries = {}
local menuIndex = 1
local menuButton -- the Baganator item button the menu was opened on
local splitCount, splitMax = 1, 1

local bagSlot = slotOf

local function containerInfo(button)
	local bag, slot = slotOf(button)
	if bag then return C_Container.GetContainerItemInfo(bag, slot) end
end

local function activeChatEditBox()
	if ChatFrameUtil and ChatFrameUtil.GetActiveWindow then return ChatFrameUtil.GetActiveWindow() end
	if ChatEdit_GetActiveWindow then return ChatEdit_GetActiveWindow() end
end

local function playerIsHunter()
	local class = UnitClassBase and UnitClassBase("player") or select(2, UnitClass("player"))
	return class == "HUNTER"
end

-- The stock menu's entries, in its order, minus "Bind to Gamepad Action Bar".
local menuActions = {
	{
		label = label("CONTEXT_ACTION_LABEL_FEED_TO_PET", "Feed to Pet"),
		condition = function(button)
			if not playerIsHunter() or not (C_PetInfo and C_PetInfo.CanPetEatItem) then return false end
			if C_Spell and C_Spell.IsSpellUsable and not C_Spell.IsSpellUsable(FEED_PET_SPELL_ID) then return false end
			local itemID = C_Container.GetContainerItemID(bagSlot(button))
			return itemID ~= nil and C_PetInfo.CanPetEatItem(itemID) == true
		end,
		func = function(button)
			ClearCursor()
			C_Container.PickupContainerItem(bagSlot(button))
			if CursorHasItem() then
				C_Item.DropItemOnUnit("pet")
				ClearCursor()
			end
		end,
	},
	{
		label = label("CONTEXT_ACTION_LABEL_DESTROY_ITEM", "Destroy"),
		red = true,
		condition = function(button)
			local info = containerInfo(button)
			return info ~= nil and not info.isLocked
		end,
		func = function(button)
			ClearCursor()
			C_Container.PickupContainerItem(bagSlot(button))
			if CursorHasItem() then DeleteCursorItem() end
		end,
	},
	{
		label = label("SHARE_IN_CHAT", "Share in Chat"),
		condition = function(button)
			return activeChatEditBox() ~= nil and C_Container.GetContainerItemLink(bagSlot(button)) ~= nil
		end,
		func = function(button)
			local link = C_Container.GetContainerItemLink(bagSlot(button))
			if not link then return end
			if ChatFrameUtil and ChatFrameUtil.InsertLink then
				ChatFrameUtil.InsertLink(link)
			elseif ChatEdit_InsertLink then
				ChatEdit_InsertLink(link)
			end
		end,
	},
	{
		label = label("CONTEXT_ACTION_LABEL_SPLIT_ITEM_STACK", "Split Stack"),
		condition = function(button)
			local info = containerInfo(button)
			return info ~= nil and not info.isLocked and (info.stackCount or 0) > 1
		end,
		split = true,
	},
}

local menu = CreateFrame("Frame", "BaganatorGamepadNits_Menu", UIParent, BackdropTemplateMixin and "BackdropTemplate")
menu:SetFrameStrata("TOOLTIP")
menu:SetFrameLevel(600)
menu:SetClampedToScreen(true)
if menu.SetBackdrop then
	menu:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
	menu:SetBackdropColor(0.05, 0.05, 0.05, 0.95)
	menu:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
end
menu.rows = {}
menu.selection = menu:CreateTexture(nil, "ARTWORK")
menu.selection:SetColorTexture(1, 0.82, 0, 0.25)
menu.selection:Hide()
menu:Hide()

local function menuRow(i)
	local row = menu.rows[i]
	if not row then
		row = menu:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		row:SetPoint("TOPLEFT", menu, "TOPLEFT", MENU_PAD + 4, -(MENU_PAD + (i - 1) * MENU_ROW_HEIGHT))
		row:SetHeight(MENU_ROW_HEIGHT)
		row:SetJustifyH("LEFT")
		row:SetJustifyV("MIDDLE")
		menu.rows[i] = row
	end
	return row
end

local function layoutMenu()
	local lines = {}
	if menuMode == "split" then
		lines[1] = { text = menuActions[#menuActions].label(), color = NORMAL_FONT_COLOR }
		lines[2] = { text = ("<  %d / %d  >"):format(splitCount, splitMax), color = HIGHLIGHT_FONT_COLOR }
	else
		for i, entry in ipairs(menuEntries) do
			lines[i] = { text = entry.label(), color = entry.red and RED_FONT_COLOR or HIGHLIGHT_FONT_COLOR }
		end
	end
	local width = 0
	for i, line in ipairs(lines) do
		local row = menuRow(i)
		row:SetText(line.text)
		row:SetTextColor(line.color:GetRGB())
		row:Show()
		width = math.max(width, row:GetStringWidth())
	end
	for i = #lines + 1, #menu.rows do menu.rows[i]:Hide() end
	menu:SetSize(width + 2 * (MENU_PAD + 4), #lines * MENU_ROW_HEIGHT + 2 * MENU_PAD)
	if menuMode == "list" and menuEntries[menuIndex] then
		menu.selection:ClearAllPoints()
		menu.selection:SetPoint("TOPLEFT", menu, "TOPLEFT", MENU_PAD / 2, -(MENU_PAD + (menuIndex - 1) * MENU_ROW_HEIGHT))
		menu.selection:SetPoint("RIGHT", menu, "RIGHT", -MENU_PAD / 2, 0)
		menu.selection:SetHeight(MENU_ROW_HEIGHT)
		menu.selection:Show()
	else
		menu.selection:Hide()
	end
end

-- Legend under the menu, same widgets as the bag legend: A select / B back, plus the d-pad amount in split mode.
local menuLegendHost = CreateFrame("Frame", "BaganatorGamepadNits_MenuLegend", UIParent)
menuLegendHost:SetSize(1, 1)
menuLegendHost:SetPoint("CENTER")
menuLegendHost:SetFrameStrata("TOOLTIP")
local menuLegend
local menuPrompts = {
	amount = GAMEPAD_DPAD_HORIZONTAL and newPrompt(GAMEPAD_DPAD_HORIZONTAL, label("FRAME_ACTION_AMOUNT", "Amount"), function() return true end) or nil,
	select = newPrompt(KEYS.pickup, function() return menuMode == "split" and (OKAY or "Okay") or pick() end, function() return true end),
	back = newPrompt(KEYS.back, function() return menuMode == "split" and (CANCEL or "Cancel") or back() end, function() return true end),
}

local function ensureMenuLegend()
	if menuLegend or not InputPromptLegends or not InputPromptLegends.CreateInputLegend then return menuLegend end
	local ok, result = pcall(InputPromptLegends.CreateInputLegend, menuLegendHost, "menuLegend")
	if not ok or not result then return end
	menuLegend = result
	for _, name in ipairs({ "amount", "select", "back" }) do
		local prompt = menuPrompts[name]
		if prompt then
			pcall(menuLegend.GetOrCreatePromptFrameUsingTemplateAndInputs, menuLegend, "StandardOneIcon", { prompt.key }, GAMEPAD_PROMPT_DIVIDER_SLASH)
		end
	end
	menuLegend:Hide()
	return menuLegend
end

local function refreshMenuLegend()
	if not ensureMenuLegend() then return end
	if not menuOpen then return menuLegend:Hide() end
	local list = {}
	if menuMode == "split" and menuPrompts.amount then table.insert(list, menuPrompts.amount) end
	table.insert(list, menuPrompts.select)
	table.insert(list, menuPrompts.back)
	if pcall(menuLegend.RefreshWithPromptedBindings, menuLegend, list) then
		menuLegend:ClearAllPoints()
		menuLegend:SetPoint("TOPLEFT", menu, "BOTTOMLEFT", 0, -4)
		menuLegend:Show()
	end
end

-- While the menu is open the d-pad, A, B, X and Y are ours; LT/RT stay BaganatorGamepad's (a window switch closes
-- the menu). Set on bgOwner, so BaganatorGamepad ignores them; its next re-apply is undone by our hook below.
local function applyMenuBindings()
	if not canBind() or not menuOpen then return end
	local targets = {
		[KEYS.up] = "BaganatorGamepadNits_MenuUp",
		[KEYS.down] = "BaganatorGamepadNits_MenuDown",
		[KEYS.left] = "BaganatorGamepadNits_MenuLeft",
		[KEYS.right] = "BaganatorGamepadNits_MenuRight",
		[KEYS.pickup] = "BaganatorGamepadNits_MenuSelect",
		[KEYS.back] = "BaganatorGamepadNits_MenuBack",
		[KEYS.more] = "BaganatorGamepadNits_MenuBack",
		[KEYS.use] = noopButton:GetName(),
	}
	for key, name in pairs(targets) do SetOverrideBindingClick(bgOwner, true, key, name) end
end

local function setMore(on)
	if not canBind() then return end
	note("Y", on and MORE_BUTTON or "cleared")
	if on then
		SetOverrideBindingClick(bgOwner, true, KEYS.more, MORE_BUTTON)
	else
		SetOverrideBinding(bgOwner, true, KEYS.more, nil)
	end
	moreBound = on
end

local function closeMenu()
	if not menuOpen then return end
	menuOpen, menuMode, menuButton = false, nil, nil
	note("menu closed")
	menu:Hide()
	refreshMenuLegend()
	-- BaganatorGamepad re-applies its keys next frame; our hook puts Y back on top of them.
	if bgActive and not suppressed then pokeBaganatorGamepad() end
end

local function openMenu()
	if menuOpen or not bgActive or suppressed or InCombatLockdown() or CursorHasItem() then return end
	if MerchantFrame and MerchantFrame:IsShown() then return end
	local button = selectedButton()
	if not button or not containerInfo(button) then return end
	wipe(menuEntries)
	for _, action in ipairs(menuActions) do
		if action.condition(button) then table.insert(menuEntries, action) end
	end
	if #menuEntries == 0 then return end
	menuOpen, menuMode, menuButton, menuIndex = true, "list", button, 1
	note("menu opened")
	menu:ClearAllPoints()
	menu:SetPoint("TOPLEFT", button, "TOPRIGHT", 6, 0)
	layoutMenu()
	menu:Show()
	refreshLegend(nil)
	refreshMenuLegend()
	moreBound = false -- Y is the menu's "back" until it closes
	applyMenuBindings()
end

local function openSplit()
	local info = containerInfo(menuButton)
	local count = info and info.stackCount or 0
	if count < 2 then return closeMenu() end
	menuMode = "split"
	splitMax, splitCount = count - 1, 1
	layoutMenu()
	refreshMenuLegend()
end

local function menuMove(delta)
	if not menuOpen then return end
	if menuMode == "split" then
		splitCount = math.max(1, math.min(splitMax, splitCount + delta))
	elseif #menuEntries > 0 then
		menuIndex = ((menuIndex - 1 + delta) % #menuEntries) + 1
	end
	layoutMenu()
end

local function menuDirection(direction)
	if menuMode == "split" then
		menuMove(({ left = -1, right = 1, up = SPLIT_BIG_STEP, down = -SPLIT_BIG_STEP })[direction])
	elseif direction == "up" then
		menuMove(-1)
	elseif direction == "down" then
		menuMove(1)
	end
end

local function menuSelect()
	if not menuOpen or not menuButton then return end
	local button = menuButton
	if menuMode == "split" then
		local bag, slot = bagSlot(button)
		closeMenu()
		ClearCursor()
		C_Container.SplitContainerItem(bag, slot, splitCount)
		return
	end
	local entry = menuEntries[menuIndex]
	if not entry then return end
	if entry.split then return openSplit() end
	closeMenu()
	entry.func(button)
end

-- Key-down, like BaganatorGamepad's buttons, so a press is consumed on the same edge by whichever addon holds it.
local function makeButton(name, onClick)
	local button = CreateFrame("Button", name, UIParent)
	button:RegisterForClicks("AnyDown")
	button:SetScript("OnClick", onClick)
	return button
end
makeButton(MORE_BUTTON, openMenu)
makeButton("BaganatorGamepadNits_MenuUp", function() menuDirection("up") end)
makeButton("BaganatorGamepadNits_MenuDown", function() menuDirection("down") end)
makeButton("BaganatorGamepadNits_MenuLeft", function() menuDirection("left") end)
makeButton("BaganatorGamepadNits_MenuRight", function() menuDirection("right") end)
makeButton("BaganatorGamepadNits_MenuSelect", menuSelect)
makeButton("BaganatorGamepadNits_MenuBack", closeMenu)

local function popupShown()
	return StaticPopup_IsAnyDialogShown ~= nil and StaticPopup_IsAnyDialogShown() == true
end

-----------------------------------------------------------------------------------------------------------------
-- State

local function applyState()
	local views = visibleViews()
	local ui = gamepadUI()
	local m = manager()
	local anyView = ui and #views > 0

	-- Blizzard popups take A/B through a binding group without focusing the UI; hold BaganatorGamepad back for them too.
	local wantSuppress = anyView and (m.isUIFocused or popupShown()) or false
	if wantSuppress ~= suppressed then
		suppressed = wantSuppress
		note("suppressed", suppressed, "UI focused", m and m.isUIFocused, "popup", popupShown(), "panels", m and m.shownFrames and #m.shownFrames)
		if suppressed then
			if bgActive then releaseBaganatorGamepad() end
		else
			if rightBound then setRight(false) end
			rightBound = false
			if bgActive then
				pokeBaganatorGamepad()
				local border = highlight()
				if border and highlightTarget() then border:Show() end
			end
		end
	end
	if suppressed then
		-- BaganatorGamepad re-shows its border on every bag relayout; keep it down while the panel has focus.
		local border = highlight()
		if border and border:IsShown() then border:Hide() end
	end

	local selected = selectedButton()
	local current = selected and viewOf(selected) or views[1]

	if menuOpen and (not bgActive or suppressed or not menuButton or not menuButton:IsVisible()
		or (selected ~= nil and selected ~= menuButton)) then
		closeMenu()
	end
	local wantMore = anyView and bgActive and not suppressed and not menuOpen
	if wantMore ~= moreBound then setMore(wantMore) end

	-- Shop focused: RT hint on the Baganator window, RT hands the keys to BaganatorGamepad.
	local panel = suppressed and lastFocusedPanel() or nil
	showRightHint(panel and current or nil)
	if suppressed and bgActive and (panel ~= nil) ~= rightBound then setRight(panel ~= nil) end

	-- Baganator window navigated: LT hint on the panel, LT focuses it. Left alone when two Baganator windows are
	-- open, where BaganatorGamepad uses LT/RT to switch between them.
	local focusTarget = leftFocusTarget(views)
	setLeftHint(focusTarget)
	local newWantLeft = focusTarget ~= nil
	if newWantLeft ~= wantLeft then
		wantLeft = newWantLeft
		if bgActive then setLeft(wantLeft) end
	end

	-- Neither trigger may keep TOGGLEUIFOCUS beyond the states above: pressed with no panel shown it only prints
	-- Blizzard's "No interface frame to focus", and it hides whatever else the trigger should do (BaganatorGamepad's
	-- window switch, GamepadXIV's crossbar once the bag is closed).
	if not wantLeft then dropToggleFocus(KEYS.lt) end
	if not rightBound then dropToggleFocus(KEYS.rt) end

	refreshLegend((anyView and bgActive and not suppressed and not menuOpen) and current or nil)
end

local function schedule()
	if pending then return end
	pending = true
	RunNextFrame(function()
		pending = false
		applyState()
	end)
end

-- BaganatorGamepad's named buttons. Binding one of them is how its owner frame is recognised; nothing else may count
-- (Baganator 847-849's own BaganatorGamepadClicker shares the prefix).
local BG_BUTTONS = {}
for _, name in ipairs({ "BaganatorGamepadNav_up", "BaganatorGamepadNav_down", "BaganatorGamepadNav_left", "BaganatorGamepadNav_right",
	"BaganatorGamepadPickupButton", "BaganatorGamepadBackButton", "BaganatorGamepadUseButton", "BaganatorGamepadSellButton",
	PREVIOUS_WINDOW_BUTTON, "BaganatorGamepadNextWindow" }) do
	BG_BUTTONS[name] = true
end

-- BaganatorGamepad binding its named buttons: learn its owner, and re-apply our changes on top of its.
hooksecurefunc("SetOverrideBindingClick", function(owner, _, _, button)
	if rebindingOurselves or not BG_BUTTONS[button] then return end
	if bgOwner ~= owner then note("BaganatorGamepad owner", bgOwner and "changed" or "found") end
	if not bgActive then note("BaganatorGamepad bound, suppressed", suppressed) end
	bgOwner = owner
	bgActive = true
	if InCombatLockdown() then return schedule() end
	if suppressed then
		clearingOurselves = true
		ClearOverrideBindings(owner)
		clearingOurselves = false
		rightBound = false
		moreBound = false
		if lastFocusedPanel() then setRight(true) end
	else
		-- Checked afresh, not from the cached wantLeft: the panel may be gone since the last state pass.
		if button == PREVIOUS_WINDOW_BUTTON and wantLeft and leftFocusTarget() then
			SetOverrideBinding(owner, true, KEYS.lt, TOGGLE_UI_FOCUS)
		end
		if menuOpen then
			applyMenuBindings()
		else
			SetOverrideBindingClick(owner, true, KEYS.more, MORE_BUTTON)
			moreBound = true
		end
	end
	schedule()
end)

hooksecurefunc("ClearOverrideBindings", function(owner)
	if owner ~= nil and owner == bgOwner and not clearingOurselves then
		if bgActive then note("BaganatorGamepad cleared its bindings") end
		bgActive = false
		rightBound = false
		moreBound = false
		schedule()
	end
end)

-----------------------------------------------------------------------------------------------------------------
-- Baganator views (the same discovery BaganatorGamepad uses)

local function isView(name)
	if type(name) ~= "string" or not name:find("^Baganator_") then return false end
	for _, pattern in ipairs(VIEW_PATTERNS) do
		if name:find(pattern) then return true end
	end
	return false
end

local function hookView(frame)
	if hooked[frame] then return end
	hooked[frame] = true
	frame:HookScript("OnShow", schedule)
	frame:HookScript("OnHide", schedule)
	if frame:IsVisible() then schedule() end
end

local function scan()
	for _, name in ipairs(UISpecialFrames) do
		local frame = _G[name]
		if frame and isView(name) then hookView(frame) end
	end
end

if Baganator and Baganator.CallbackRegistry then
	Baganator.CallbackRegistry:RegisterCallback("ViewComplete", schedule, "BaganatorGamepadNits")
end

for _, toggle in ipairs({ "ToggleAllBags", "OpenAllBags", "ToggleBackpack", "ToggleBackpack_Combined" }) do
	if _G[toggle] then hooksecurefunc(toggle, function() RunNextFrame(scan) end) end
end

-- FrameControlsManager fires this after every focus change, panel open and panel close.
if EventRegistry then
	pcall(EventRegistry.RegisterCallback, EventRegistry, "Gamepad.RefreshFrameFocus", schedule, ownOwner)
end

local events = CreateFrame("Frame", "BaganatorGamepadNits_Events", UIParent)
for _, event in ipairs({ "PLAYER_ENTERING_WORLD", "BANKFRAME_OPENED", "MERCHANT_SHOW", "MERCHANT_CLOSED",
	"PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "CURSOR_CHANGED", "BAG_UPDATE_DELAYED" }) do
	events:RegisterEvent(event)
end
events:SetScript("OnEvent", function(_, event)
	if event == "PLAYER_ENTERING_WORLD" or event == "BANKFRAME_OPENED" then scan() end
	if event == "PLAYER_ENTERING_WORLD" then disarmTrap() end
	schedule()
end)

-- Selection moves inside BaganatorGamepad are invisible to us (its buttons are clicked by the client); poll.
local elapsed = 0
events:SetScript("OnUpdate", function(_, dt)
	elapsed = elapsed + dt
	if elapsed < POLL_INTERVAL then return end
	elapsed = 0
	if next(hooked) and gamepadUI() then applyState() end
end)

SLASH_BAGANATORGAMEPADNITS1 = "/bgnits"
SlashCmdList.BAGANATORGAMEPADNITS = function(msg)
	if msg and msg:match("^%s*log%s*$") then
		print("BaganatorGamepadNits: last " .. math.min(logCount, LOG_SIZE) .. " of " .. logCount .. " events (seconds since login)")
		for i = math.max(1, logCount - LOG_SIZE + 1), logCount do print("  " .. log[(i - 1) % LOG_SIZE + 1]) end
		return
	end
	local m = manager()
	print("BaganatorGamepadNits: gamepad UI " .. tostring(gamepadUI()) .. ", views " .. #visibleViews()
		.. ", BaganatorGamepad owner " .. tostring(bgOwner ~= nil) .. " active " .. tostring(bgActive)
		.. ", highlight " .. tostring(bgHighlight ~= nil) .. ", suppressed " .. tostring(suppressed)
		.. ", wantLeft " .. tostring(wantLeft) .. ", rightBound " .. tostring(rightBound)
		.. ", legend " .. tostring(legend ~= nil) .. ", UI focused " .. tostring(m and m.isUIFocused)
		.. ", panels " .. tostring(m and m.shownFrames and #m.shownFrames)
		.. ", Baganator trap " .. (_G[TRAP_CLICKER] and (trapFrame and "disarmed" or "NOT FOUND") or "absent")
		.. ", Baganator native nav blocked " .. nativeNavBlocked
		.. ", moreBound " .. tostring(moreBound) .. ", menu " .. tostring(menuOpen and menuMode or false))
	local names = {}
	for i, frame in ipairs(m and m.shownFrames or {}) do
		names[i] = tostring(frame.GetName and frame:GetName() or frame) .. (frame.IsVisible and frame:IsVisible() and "" or " (not visible)")
	end
	local focused = m and m.focusedFrame
	local button = selectedButton()
	local bag, slot = slotOf(button)
	print("  panels: " .. (#names > 0 and table.concat(names, ", ") or "none")
		.. "; focused " .. tostring(focused and (focused.GetName and focused:GetName() or focused))
		.. "; popup " .. tostring(popupShown()) .. ", merchant " .. tostring(MerchantFrame and MerchantFrame:IsShown() or false)
		.. ", cursor item " .. tostring(CursorHasItem())
		.. ", selected slot " .. (bag and (bag .. "/" .. slot) or "none")
		.. ", Y -> " .. tostring(boundAction(KEYS.more)))
	print("  LT -> " .. tostring(boundAction(KEYS.lt)) .. ", RT -> " .. tostring(boundAction(KEYS.rt))
		.. "; /bgnits log for the last binding changes")
end
