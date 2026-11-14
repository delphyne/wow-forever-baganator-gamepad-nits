-- BaganatorGamepadNits: controller navigation for Baganator's bag and bank windows on World of Warcraft: Forever's
-- native controller UI. Baganator is not edited; CLAUDE.md explains how this attaches to it and to Blizzard's UI.
--
-- Until 0.3.0 this sat on top of the BaganatorGamepad addon and worked around it from outside. It now does that
-- addon's job itself (written from its behaviour, not its code) and must not run alongside it; a warning is printed
-- when both are loaded.
--
-- 1. Navigation. While a Baganator window is open (out of combat) the d-pad moves a gold border between the item
--    buttons, A picks up or places, X uses/equips or sells at a merchant, B drops a held item or closes, and LT/RT
--    switch between the bag and the bank. All of it is override bindings to our own buttons on one owner frame.
-- 2. Paging between a Baganator window and a Blizzard panel (the merchant, mainly), like the stock bag does.
--    While a Blizzard panel has controller focus we bind nothing but RT, the Baganator window shows Blizzard's RT
--    jump hint, and RT drops the panel's focus. While the Baganator window is navigated, the panel shows the LT
--    jump hint and LT focuses it again. Both triggers run Blizzard's TOGGLEUIFOCUS binding command through an
--    override binding, so the client executes it untainted; this addon never calls into FrameControlsManager.
-- 3. A button legend under the navigated Baganator window, built from Blizzard's own input legend widgets, so it
--    matches the footer under the stock bag: A select, X sell/equip/use, Y more actions, B close/back.
-- 4. Baganator 847 grew its own controller capture that swallows every button while a bag is open, and 850 its own
--    registration with Blizzard's manager; both are kept out (see the two "Baganator's ..." sections below).
-- 5. The stock bag's Y "more actions" menu for the selected item (Destroy, Split Stack, Share in Chat, Feed to
--    Pet), as our own frame and bindings (see "More actions" below). Nothing is bound while a Blizzard popup (the
--    destroy confirmation, say) is up, so the popup gets A/B.

local ADDON_NAME = ...
local OTHER_ADDON = "BaganatorGamepad" -- what this replaces; the two would fight over the same keys
local PREFIX = "BaganatorGamepadNits_"
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
local ALL_KEYS = {}
for _, key in pairs(KEYS) do table.insert(ALL_KEYS, key) end
table.sort(ALL_KEYS)
local DIRECTIONS = { up = { 0, 1 }, down = { 0, -1 }, left = { -1, 0 }, right = { 1, 0 } }
local TOGGLE_UI_FOCUS = "TOGGLEUIFOCUS"
local POLL_INTERVAL = 0.1

local hooked = {} -- Baganator view frames we watch
local items = {} -- { frame, x, y } for every item button of currentView, as of the last layout pass
local itemsDirty = true -- the window was shown, hidden or laid out again; collect the buttons afresh
local selected -- the entry of `items` under the border
local currentView -- the d-pad moves inside this window; LT/RT switch windows
local lastSelected = setmetatable({}, { __mode = "k" }) -- window -> { frame, x, y } of its last selection, to come back to
local active = false -- a Baganator window is open, controller UI on, out of combat
local suppressed = false -- active, but a Blizzard panel or popup has the controller; we bind (almost) nothing
local navigated = false -- active and not suppressed: our keys are bound, the border is shown
local combat = InCombatLockdown()
local conflict = false -- BaganatorGamepad is loaded too
local enteredWorld = false
local hintedFrame -- Blizzard panel currently showing our LT hint
local pending = false
local applyState -- defined under "State"; every button below re-evaluates it after its click

-- A short log of what was bound and why, for "/bgnits log": binding fights with other controller addons (GamepadXIV,
-- say) are hard to see after the fact, and a TOGGLEUIFOCUS press with no panel shown only prints Blizzard's
-- "No interface frame to focus". The ring lives in the saved variable BaganatorGamepadNitsDB (this session's and the
-- one before, with logCount to put the ring in order), so it can be read from WTF after a /reload.
local LOG_SIZE = 60
local log, logCount = {}, 0
local function note(...)
	local parts = {}
	for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
	logCount = logCount + 1
	log[(logCount - 1) % LOG_SIZE + 1] = ("%s %s"):format(date("%H:%M:%S"), table.concat(parts, " "))
	if BaganatorGamepadNitsDB then BaganatorGamepadNitsDB.logCount = logCount end
end

local function attachSavedLog()
	local old = BaganatorGamepadNitsDB
	BaganatorGamepadNitsDB = { log = log, logCount = logCount, previous = old and old.log, previousCount = old and old.logCount }
end

-- Every override binding of ours is set on this frame, so clearing it gives all the keys back at once.
local owner = CreateFrame("Frame", PREFIX .. "Owner", UIParent)

-- Key-down, so a press is consumed on the same edge whichever of our buttons holds the key.
local function makeButton(name, onClick)
	local button = CreateFrame("Button", PREFIX .. name, UIParent)
	button:RegisterForClicks("AnyDown")
	button:SetScript("OnClick", function()
		if onClick then onClick() end
		applyState()
	end)
	return button
end
makeButton("Noop")

-- Baganator's handlers run through this: an error in one of them is reported without ending our state pass.
local safeCall = securecallfunction or pcall

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

-- Open Baganator windows, left to right, so the triggers page through them in screen order.
local function visibleViews()
	local views = {}
	for view in pairs(hooked) do
		if view:IsVisible() then table.insert(views, view) end
	end
	table.sort(views, function(a, b) return (center(a) or 0) < (center(b) or 0) end)
	return views
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
-- Navigation. The item buttons of the current window are collected with their screen positions after every
-- layout; the d-pad then goes to the nearest button within 45 degrees of the pressed direction. Baganator's
-- category layouts are not a regular grid, so there is no row/column arithmetic and no wrapping at the edges.

-- The bag and slot of a Baganator item button, or nothing. Baganator's bag-slot and other buttons answer GetBagID
-- too, with nil, and the container API raises an error on that.
local function slotOf(button)
	if not button or not button.GetBagID or not button.GetID then return end
	local ok, bag = pcall(button.GetBagID, button)
	local slot = button:GetID()
	if ok and type(bag) == "number" and type(slot) == "number" then return bag, slot end
end

-- Anything visible inside the window that answers GetBagID can be selected (the bag-slot buttons too: selecting one
-- shows its tooltip, and A/X/Y do nothing there). Buttons scrolled or clipped out of the window's rectangle are not.
local function collectItems()
	wipe(items)
	local left, bottom, width, height = currentView:GetScaledRect()
	if not left then return end
	local function visit(...)
		for i = 1, select("#", ...) do
			local child = select(i, ...)
			if child:IsVisible() then
				if child.GetBagID then
					local x, y = center(child)
					if x and x >= left and x <= left + width and y >= bottom and y <= bottom + height then
						items[#items + 1] = { frame = child, x = x, y = y }
					end
				else
					visit(child:GetChildren())
				end
			end
		end
	end
	visit(currentView:GetChildren())
end

local function entryFor(frame)
	if not frame then return end
	for _, entry in ipairs(items) do
		if entry.frame == frame then return entry end
	end
end

-- The entry closest to (x, y); with a direction, only those no more than 45 degrees off it.
local function nearest(x, y, exclude, dx, dy)
	local best, bestDistance
	for _, entry in ipairs(items) do
		if entry ~= exclude then
			local ox, oy = entry.x - x, entry.y - y
			local inCone = true
			if dx then
				local along = ox * dx + oy * dy
				inCone = along > 0 and math.abs(ox * dy - oy * dx) <= along + 0.01
			end
			local distance = ox * ox + oy * oy
			if inCone and (not bestDistance or distance < bestDistance) then best, bestDistance = entry, distance end
		end
	end
	return best
end

local function topLeft()
	local best
	for _, entry in ipairs(items) do
		if not best or entry.y > best.y + 1 or (entry.y >= best.y - 1 and entry.x < best.x) then best = entry end
	end
	return best
end

-- X outside a merchant: a secure "item" action on the selected slot, which equips what can be equipped and uses
-- the rest. Its slot attribute can only be written out of combat, which is when we are bound at all.
local useButton = CreateFrame("Button", PREFIX .. "Use", UIParent, "SecureActionButtonTemplate")
useButton:SetAttribute("type", "item")
useButton:RegisterForClicks("AnyUp", "AnyDown")

local function setSelected(entry)
	selected = entry
	if entry and currentView then lastSelected[currentView] = { frame = entry.frame, x = entry.x, y = entry.y } end
	if not InCombatLockdown() then
		local bag, slot = slotOf(entry and entry.frame)
		useButton:SetAttribute("item", bag and (bag .. " " .. slot) or nil)
	end
end

-- After a layout the place counts, not the button: Baganator pools its item buttons, so the button under the border
-- may now draw a different slot somewhere else (after a sale in a category view it turns into the empty-slot
-- placeholder at the bottom, and the border would ride along). Keep the button only while it still sits where it
-- was, within half a button, else take whatever now sits closest to that spot.
local function recover(remembered)
	if not remembered then return end
	local entry = entryFor(remembered.frame)
	if entry then
		local _, _, w, h = entry.frame:GetScaledRect()
		if math.abs(entry.x - remembered.x) <= (w or 0) / 2 and math.abs(entry.y - remembered.y) <= (h or 0) / 2 then
			return entry
		end
	end
	return nearest(remembered.x, remembered.y)
end

-- After a layout: where the selection was, else where this window's last selection was, else the top left.
local function reselect()
	local old = selected
	collectItems()
	setSelected(recover(old) or recover(lastSelected[currentView]) or topLeft())
end

local function move(direction)
	if not navigated then return end
	if not selected then return setSelected(topLeft()) end
	local d = DIRECTIONS[direction]
	local target = nearest(selected.x, selected.y, selected, d[1], d[2])
	if target then setSelected(target) end
end

local function switchWindow(step)
	local views = visibleViews()
	if not navigated or #views < 2 then return end
	local index = 1
	for i, view in ipairs(views) do
		if view == currentView then index = i end
	end
	currentView = views[(index - 1 + step) % #views + 1]
	selected = nil
	itemsDirty = true
end

-- The item button under the border.
local function selectedButton()
	if selected and selected.frame:IsVisible() then return selected.frame end
end

local function selectedItemID()
	local button = selectedButton()
	local bag, slot = slotOf(button)
	if not bag then return end
	local info = C_Container.GetContainerItemInfo(bag, slot)
	return info and info.itemID, button
end

for direction in pairs(DIRECTIONS) do
	makeButton("Nav_" .. direction, function() move(direction) end)
end
makeButton("PreviousWindow", function() switchWindow(-1) end)
makeButton("NextWindow", function() switchWindow(1) end)

-- A: pick the item up, or with something on the cursor put it down here (swapping).
makeButton("Pickup", function()
	local bag, slot = slotOf(selectedButton())
	if bag then C_Container.PickupContainerItem(bag, slot) end
end)

-- X at a merchant. The secure "item" action never sells; UseContainerItem does, and is not protected.
makeButton("Sell", function()
	local bag, slot = slotOf(selectedButton())
	if bag and MerchantFrame and MerchantFrame:IsShown() then C_Container.UseContainerItem(bag, slot) end
end)

-- B: drop what is held, else close every open Baganator window the way its own close button does.
makeButton("Back", function()
	if CursorHasItem() then return ClearCursor() end
	for _, view in ipairs(visibleViews()) do
		if view.CloseButton then view.CloseButton:Click() else view:Hide() end
	end
end)

-- The gold border around the selected button. Selecting a button also runs its OnEnter, which is what shows the
-- item tooltip; OnLeave takes it down again when the selection moves on or a Blizzard panel takes over.
local highlight = CreateFrame("Frame", PREFIX .. "Highlight", UIParent, BackdropTemplateMixin and "BackdropTemplate")
if highlight.SetBackdrop then
	highlight:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 3 })
	highlight:SetBackdropBorderColor(1, 0.82, 0, 1)
end
highlight:SetFrameStrata("TOOLTIP")
highlight:Hide()

local displayed -- the button the border and tooltip are on right now
local function runScript(frame, script)
	local handler = frame:GetScript(script)
	if handler then safeCall(handler, frame) end
end

local function display(frame, again)
	if displayed and displayed ~= frame then runScript(displayed, "OnLeave") end
	if not frame then
		displayed = nil
		highlight:Hide()
		return
	end
	if displayed ~= frame or again then
		highlight:ClearAllPoints()
		highlight:SetPoint("TOPLEFT", frame, "TOPLEFT", -3, 3)
		highlight:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 3, -3)
		highlight:Show()
		displayed = frame
		runScript(frame, "OnEnter")
	end
end

-----------------------------------------------------------------------------------------------------------------
-- Baganator's own controller capture (Baganator 847+, ItemViewCommon/GamepadTrap.lua). While a bag is open it
-- shows an anonymous frame on UIParent with OnGamePadButtonDown/Up and OnGamePadStick handlers. The frame only
-- propagates the Menu button and the right stick, so every other button (d-pad, A/B/X/Y, left stick) is eaten
-- before any binding, ours included, and two leftover debug prints spam chat ("gpb <button>" on
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
-- Baganator's native controller navigation (Baganator 850+). Each time a bag or bank window shows, Baganator
-- defers GamepadMode.FrameControlsManager:FrameShown(view) by a frame with C_Timer.After(0, ...). That makes the
-- window a managed, focused Blizzard panel: isUIFocused goes true (so we would stand back from the bag until RT
-- unfocused it) and the manager's state is written from addon code. There is no setting for it and the functions
-- are private, but the deferred closure passes through C_Timer.After, where a secure hook can see it and the call
-- stack names the files it came from. The closure gets an environment in which GamepadMode's FrameControlsManager
-- is a stub, so the registration never reaches Blizzard's manager. Nothing of Blizzard's or Baganator's is
-- replaced; every other global still resolves through _G.
--
-- Where the call comes from, by Baganator version:
--   850-854: AnnounceShow in ItemViewCommon/Gamepad.lua (called from the backpack view's OnShow), and BankView.lua's
--            own C_Timer.After in its OnShow.
--   855+:    AnnounceShow in Core/Gamepad.lua, called from ItemViewCommon/BackpackView.lua and BankView.lua OnShow.
-- Core/Gamepad.lua also announces the customise dialog, Baganator's own popups (Core/Dialogs.lua), the currency
-- panel and the character select; those are real panels and are left to Blizzard, so Core/Gamepad.lua alone is
-- not enough: a view file has to be on the stack too.

local nativeNavBlocked = 0
if C_Timer and C_Timer.After and setfenv and debugstack then
	local stubManager = { FrameShown = function() nativeNavBlocked = nativeNavBlocked + 1 end }
	local stubEnv = setmetatable({
		GamepadMode = setmetatable({ FrameControlsManager = stubManager }, { __index = function(_, k) return GamepadMode and GamepadMode[k] end }),
	}, { __index = _G, __newindex = _G })
	local function isViewAnnounce(stack)
		-- Baganator's customise dialog announces itself through the same AnnounceShow; it is no bag, so it keeps
		-- its focus.
		if stack:find("CustomiseDialog") then return false end
		if stack:find("Baganator[/\\]ItemViewCommon[/\\]Gamepad%.lua") or stack:find("Baganator[/\\]ItemViewCommon[/\\]BankView%.lua") then
			return true -- 850-854 (and 855's bank view, which still goes through BankView.lua)
		end
		return stack:find("Baganator[/\\]Core[/\\]Gamepad%.lua") ~= nil
			and stack:find("Baganator[/\\]ItemViewCommon[/\\]BackpackView%.lua") ~= nil -- 855+
	end
	hooksecurefunc(C_Timer, "After", function(seconds, callback)
		if seconds ~= 0 or type(callback) ~= "function" then return end
		local stack = debugstack(2, 8, 0)
		if stack and isViewAnnounce(stack) then
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
-- our own frame, navigated with our own bindings like everything else here. Entries:
--   Destroy: PickupContainerItem + DeleteCursorItem inside the key's hardware event; the client raises
--     DELETE_ITEM_CONFIRM and Blizzard shows its confirmation popup (C_Item.ConfirmDeleteItem, which the stock
--     bag uses, carries the same restriction flag and is untested from addon code).
--   Split Stack: our own stepper (d-pad left/right 1, up/down 10; A puts the split on the cursor, B cancels), then
--     A on an empty slot places it. Blizzard's StackSplitFrame is a gamepad-managed frame.
--   Share in Chat: inserts the link into the open chat edit box; only offered while one is open (opening chat from
--     addon code is another managed-frame path).
--   Feed to Pet: hunters, for items the pet can eat.
--   Bind to Gamepad Action Bar is not offered: it opens GamepadActionBarEditFrame, a managed frame.
-- Like the stock bag, the menu is unavailable while an item is held or a merchant is open. Everything here only
-- reads Baganator's item buttons (GetBagID/GetID) and the container API.

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

local function closeMenu()
	if not menuOpen then return end
	menuOpen, menuMode, menuButton = false, nil, nil
	note("menu closed")
	menu:Hide()
	refreshMenuLegend()
end

local function openMenu()
	if menuOpen or not navigated or InCombatLockdown() or CursorHasItem() then return end
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
	refreshMenuLegend()
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

makeButton("More", openMenu)
for direction in pairs(DIRECTIONS) do
	makeButton("Menu_" .. direction, function() menuDirection(direction) end)
end
makeButton("MenuSelect", menuSelect)
makeButton("MenuBack", closeMenu)

local function popupShown()
	return StaticPopup_IsAnyDialogShown ~= nil and StaticPopup_IsAnyDialogShown() == true
end

-----------------------------------------------------------------------------------------------------------------
-- Bindings. Each state pass works out what every one of our keys should do and, when that differs from what is
-- applied, clears the owner and binds the lot again. `applied` is therefore the whole truth about our bindings:
-- a key that is not in the wanted table is not bound by us.

local applied = {}
local wanted = {}
local forceBindings = false
local reasserts = 0

local function wantBindings(rightPanel, focusTarget)
	wipe(wanted)
	if rightPanel then
		-- A Blizzard panel has the controller: only the way back to the bag.
		wanted[KEYS.rt] = TOGGLE_UI_FOCUS
	elseif navigated then
		if menuOpen then
			-- The d-pad, A, B, X and Y belong to the menu; LT/RT keep working and close it by changing the state.
			for direction in pairs(DIRECTIONS) do wanted[KEYS[direction]] = PREFIX .. "Menu_" .. direction end
			wanted[KEYS.pickup] = PREFIX .. "MenuSelect"
			wanted[KEYS.back] = PREFIX .. "MenuBack"
			wanted[KEYS.more] = PREFIX .. "MenuBack"
			wanted[KEYS.use] = PREFIX .. "Noop"
		else
			for direction in pairs(DIRECTIONS) do wanted[KEYS[direction]] = PREFIX .. "Nav_" .. direction end
			wanted[KEYS.pickup] = PREFIX .. "Pickup"
			wanted[KEYS.back] = PREFIX .. "Back"
			wanted[KEYS.more] = PREFIX .. "More"
			wanted[KEYS.use] = PREFIX .. ((MerchantFrame and MerchantFrame:IsShown()) and "Sell" or "Use")
		end
		wanted[KEYS.lt] = focusTarget and TOGGLE_UI_FOCUS or (PREFIX .. "PreviousWindow")
		wanted[KEYS.rt] = PREFIX .. "NextWindow"
	end
end

local function applyBindings(reason)
	if InCombatLockdown() then return end
	local changed = false
	for _, key in ipairs(ALL_KEYS) do
		if applied[key] ~= wanted[key] then changed = true end
	end
	if not changed and not forceBindings then return end
	forceBindings = false
	ClearOverrideBindings(owner)
	for _, key in ipairs(ALL_KEYS) do
		local target = wanted[key]
		if target == TOGGLE_UI_FOCUS then
			SetOverrideBinding(owner, true, key, target)
		elseif target then
			SetOverrideBindingClick(owner, true, key, target)
		end
		applied[key] = target
	end
	if changed then
		local function name(key) return wanted[key] and wanted[key]:gsub("^" .. PREFIX, "") or "-" end
		note("bound", reason, "LT", name(KEYS.lt), "RT", name(KEYS.rt), "Y", name(KEYS.more))
	end
end

-----------------------------------------------------------------------------------------------------------------
-- State

function applyState()
	local views = visibleViews()
	local m = manager()

	local wasActive = active
	active = gamepadUI() and #views > 0 and not combat and not InCombatLockdown() or false
	if active ~= wasActive then
		note("navigation", active and "on" or "off")
		itemsDirty = true
	end

	local laidOut = false
	if active then
		if not (currentView and hooked[currentView] and currentView:IsVisible()) then
			currentView = views[1]
			itemsDirty = true
		end
		if selected and not selected.frame:IsVisible() then itemsDirty = true end
		if itemsDirty then
			itemsDirty = false
			reselect()
			laidOut = true
		end
	else
		setSelected(nil)
	end

	-- Blizzard popups take A/B through a binding group without focusing the UI; stand back for them as well.
	local wantSuppress = active and (m.isUIFocused or popupShown()) or false
	if wantSuppress ~= suppressed then
		suppressed = wantSuppress
		note("suppressed", suppressed, "UI focused", m and m.isUIFocused, "popup", popupShown(), "panels", m and m.shownFrames and #m.shownFrames)
	end
	navigated = active and not suppressed

	if menuOpen and (not navigated or not menuButton or not menuButton:IsVisible() or selectedButton() ~= menuButton) then
		closeMenu()
	end

	display(navigated and selectedButton() or nil, laidOut)

	-- Shop focused: RT hint on the Baganator window, RT leaves the shop.
	local panel = suppressed and lastFocusedPanel() or nil
	showRightHint(panel and currentView or nil)

	-- Baganator window navigated: LT hint on the panel, LT focuses it. Not with two Baganator windows open, where
	-- LT/RT switch between them.
	local focusTarget = navigated and #views == 1 and unfocusedPanel() or nil
	setLeftHint(focusTarget)

	wantBindings(panel, focusTarget)
	applyBindings(suppressed and "panel" or (navigated and (menuOpen and "menu" or "bag")) or "off")

	refreshLegend((navigated and not menuOpen) and currentView or nil)
end

local function schedule()
	if pending then return end
	pending = true
	RunNextFrame(function()
		pending = false
		applyState()
	end)
end

-- A Baganator window was shown, hidden or laid out again. Positions are only resolved on the next frame.
local function scheduleLayout()
	itemsDirty = true
	schedule()
end

-- Blizzard's gamepad UI re-applies its own override bindings whenever its binding stack changes. When another owner
-- binds a key we currently hold, bind ours again next frame so they stay on top. GamepadXIV binds from restricted
-- code, which these hooks never see. BaganatorGamepad does the same re-assert for the same keys; if it is loaded
-- too we let it win instead of trading the keys back and forth every frame.
local reassertPending = false
local function onForeignBinding(bindOwner, _, key, target)
	if bindOwner == owner or not key or not applied[key] or reassertPending then return end
	if conflict and type(target) == "string" and target:find("^" .. OTHER_ADDON) and not target:find("^" .. PREFIX) then return end
	reassertPending = true
	RunNextFrame(function()
		reassertPending = false
		reasserts = reasserts + 1
		forceBindings = true
		applyState()
	end)
end
hooksecurefunc("SetOverrideBinding", onForeignBinding)
hooksecurefunc("SetOverrideBindingClick", onForeignBinding)

-----------------------------------------------------------------------------------------------------------------
-- Running next to BaganatorGamepad: both would navigate the same windows with the same keys.

local CONFLICT_WARNING = "|cffff4040BaganatorGamepadNits:|r the BaganatorGamepad addon is also enabled. BaganatorGamepadNits"
	.. " now does its job itself and the two fight over the controller buttons. Disable BaganatorGamepad and /reload."

local function checkConflict()
	local isLoaded = C_AddOns and C_AddOns.IsAddOnLoaded or IsAddOnLoaded
	if conflict or not isLoaded or not isLoaded(OTHER_ADDON) then return end
	conflict = true
	note(OTHER_ADDON, "is loaded too")
	if enteredWorld then print(CONFLICT_WARNING) end
end

-----------------------------------------------------------------------------------------------------------------
-- Baganator views. It creates them per skin and lists each in UISpecialFrames.

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
	frame:HookScript("OnShow", scheduleLayout)
	frame:HookScript("OnHide", scheduleLayout)
	if frame:IsVisible() then scheduleLayout() end
end

local function scan()
	for _, name in ipairs(UISpecialFrames) do
		local frame = _G[name]
		if frame and isView(name) then hookView(frame) end
	end
end

-- Fired after the window shows and after every bag change, once the item buttons are laid out.
if Baganator and Baganator.CallbackRegistry then
	Baganator.CallbackRegistry:RegisterCallback("ViewComplete", scheduleLayout, "BaganatorGamepadNits")
end

-- A skin change builds a new set of views; the next bag toggle picks them up.
for _, toggle in ipairs({ "ToggleAllBags", "OpenAllBags", "ToggleBackpack", "ToggleBackpack_Combined" }) do
	if _G[toggle] then hooksecurefunc(toggle, function() RunNextFrame(scan) end) end
end

-- FrameControlsManager fires this after every focus change, panel open and panel close.
if EventRegistry then
	pcall(EventRegistry.RegisterCallback, EventRegistry, "Gamepad.RefreshFrameFocus", function() schedule() end, owner)
end

local events = CreateFrame("Frame", PREFIX .. "Events", UIParent)
for _, event in ipairs({ "PLAYER_ENTERING_WORLD", "BANKFRAME_OPENED", "MERCHANT_SHOW", "MERCHANT_CLOSED",
	"PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "CURSOR_CHANGED", "BAG_UPDATE_DELAYED", "DELETE_ITEM_CONFIRM",
	"ADDON_LOADED", "ADDON_ACTION_BLOCKED", "ADDON_ACTION_FORBIDDEN" }) do
	pcall(events.RegisterEvent, events, event)
end
events:SetScript("OnEvent", function(_, event, arg1, arg2)
	if event == "ADDON_LOADED" then
		if arg1 == ADDON_NAME then attachSavedLog() end
		if arg1 == OTHER_ADDON then checkConflict() end
		return
	end
	-- A protected call of ours refused by the client: the log must say so, with the function.
	if event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN" then
		if arg1 == ADDON_NAME then note(event, arg2) end
		return
	end
	if event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" or event == "MERCHANT_SHOW" or event == "MERCHANT_CLOSED" then
		note(event)
	end
	if event == "PLAYER_REGEN_DISABLED" then
		-- The last moment bindings can still be changed: give every key back now, not a frame later.
		combat = true
		return applyState()
	end
	if event == "PLAYER_REGEN_ENABLED" then combat = false end
	if event == "PLAYER_ENTERING_WORLD" then
		combat = InCombatLockdown()
		disarmTrap()
		checkConflict()
		if conflict and not enteredWorld then print(CONFLICT_WARNING) end
		enteredWorld = true
	end
	if event == "PLAYER_ENTERING_WORLD" or event == "BANKFRAME_OPENED" then
		scan()
		itemsDirty = true
	end
	schedule()
end)

-- Not everything the state depends on has an event we can listen to (a Blizzard popup going up or away, the
-- selected item becoming usable); while a Baganator window is open, or anything of ours is still bound, look again
-- ten times a second. Layout is not redone here, only on the events above.
local elapsed = 0
events:SetScript("OnUpdate", function(_, dt)
	elapsed = elapsed + dt
	if elapsed < POLL_INTERVAL then return end
	elapsed = 0
	if active or next(applied) then return applyState() end
	if not gamepadUI() then return end
	for view in pairs(hooked) do
		if view:IsVisible() then return applyState() end
	end
end)

SLASH_BAGANATORGAMEPADNITS1 = "/bgnits"
SlashCmdList.BAGANATORGAMEPADNITS = function(msg)
	if msg and msg:match("^%s*log%s*$") then
		print("BaganatorGamepadNits: last " .. math.min(logCount, LOG_SIZE) .. " of " .. logCount .. " events (also saved in BaganatorGamepadNitsDB)")
		for i = math.max(1, logCount - LOG_SIZE + 1), logCount do print("  " .. log[(i - 1) % LOG_SIZE + 1]) end
		return
	end
	if conflict then print(CONFLICT_WARNING) end
	local m = manager()
	print("BaganatorGamepadNits: gamepad UI " .. tostring(gamepadUI()) .. ", views " .. #visibleViews()
		.. ", active " .. tostring(active) .. ", suppressed " .. tostring(suppressed) .. ", navigated " .. tostring(navigated)
		.. ", item buttons " .. #items .. ", combat " .. tostring(combat)
		.. ", legend " .. tostring(legend ~= nil) .. ", UI focused " .. tostring(m and m.isUIFocused)
		.. ", panels " .. tostring(m and m.shownFrames and #m.shownFrames)
		.. ", Baganator trap " .. (_G[TRAP_CLICKER] and (trapFrame and "disarmed" or "NOT FOUND") or "absent")
		.. ", Baganator native nav blocked " .. nativeNavBlocked
		.. ", menu " .. tostring(menuOpen and menuMode or false) .. ", re-asserts " .. reasserts
		.. ", BaganatorGamepad loaded " .. tostring(conflict))
	local names = {}
	for i, frame in ipairs(m and m.shownFrames or {}) do
		names[i] = tostring(frame.GetName and frame:GetName() or frame) .. (frame.IsVisible and frame:IsVisible() and "" or " (not visible)")
	end
	local focused = m and m.focusedFrame
	local bag, slot = slotOf(selectedButton())
	print("  panels: " .. (#names > 0 and table.concat(names, ", ") or "none")
		.. "; focused " .. tostring(focused and (focused.GetName and focused:GetName() or focused))
		.. "; popup " .. tostring(popupShown()) .. ", merchant " .. tostring(MerchantFrame and MerchantFrame:IsShown() or false)
		.. ", cursor item " .. tostring(CursorHasItem())
		.. ", selected slot " .. (bag and (bag .. "/" .. slot) or (selectedButton() and "not an item" or "none")))
	-- What the keys do right now, override bindings included. (Forever has no global GetBindingByKey, only
	-- C_KeyBindings.GetBindingByKey; GetBindingAction with checkOverride is the one that sees override bindings.)
	local actions = {}
	for _, name in ipairs({ "lt", "rt", "pickup", "use", "more", "back", "up" }) do
		actions[#actions + 1] = KEYS[name] .. " -> " .. tostring(GetBindingAction(KEYS[name], true))
	end
	print("  " .. table.concat(actions, ", ") .. "; /bgnits log for the last binding changes")
end
