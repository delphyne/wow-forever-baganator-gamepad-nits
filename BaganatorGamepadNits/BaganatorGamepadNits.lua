-- BaganatorGamepadNits: two fixes layered on top of BaganatorGamepad for World of Warcraft: Forever's native
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

local VIEW_PATTERNS = { "BackpackViewFrame", "BankViewFrame" }
local KEYS = {
	lt = GAMEPAD_TRIGGER_LEFT or "PADLTRIGGER",
	rt = GAMEPAD_TRIGGER_RIGHT or "PADRTRIGGER",
	pickup = GAMEPAD_FACE_BOTTOM or "PAD1",
	back = GAMEPAD_FACE_RIGHT or "PAD2",
	use = GAMEPAD_FACE_LEFT or "PAD3",
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
local hintedFrame -- Blizzard panel currently showing our LT hint
local clearingOurselves = false
local rebindingOurselves = false
local pending = false

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
local function lastFocusedPanel()
	local m = manager()
	local frames = m and m.shownFrames
	if not frames or #frames == 0 then return end
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
		if frame:GetObjectType() == "Frame" and not frame:GetName() and frame:GetParent() == UIParent
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

local function highlightTarget()
	local border = highlight()
	if not border then return end
	local _, relativeTo = border:GetPoint(1)
	if relativeTo and relativeTo.GetBagID and relativeTo:IsVisible() and viewOf(relativeTo) then return relativeTo end
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
		if owner and owner.GetBagID and owner:IsVisible() and viewOf(owner) then return owner end
	end
end

local function selectedItemID()
	local button = selectedButton()
	if not button then return end
	local info = C_Container.GetContainerItemInfo(button:GetBagID(), button:GetID())
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
	SetOverrideBinding(bgOwner, true, KEYS.rt, on and TOGGLE_UI_FOCUS or nil)
	rightBound = on
end

local function setLeft(on)
	if not canBind() then return end
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
	if lastFocusedPanel() then setRight(true) end
end

-- Make BaganatorGamepad re-apply its bindings next frame: it does so when a foreign owner binds one of its keys.
local function pokeBaganatorGamepad()
	if InCombatLockdown() then return end
	SetOverrideBindingClick(ownOwner, true, KEYS.rt, noopButton:GetName())
	ClearOverrideBindings(ownOwner)
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
-- State

local function applyState()
	local views = visibleViews()
	local ui = gamepadUI()
	local m = manager()
	local anyView = ui and #views > 0

	local wantSuppress = anyView and m.isUIFocused or false
	if wantSuppress ~= suppressed then
		suppressed = wantSuppress
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

	-- Shop focused: RT hint on the Baganator window, RT hands the keys to BaganatorGamepad.
	local panel = suppressed and lastFocusedPanel() or nil
	showRightHint(panel and current or nil)
	if suppressed and bgActive and (panel ~= nil) ~= rightBound then setRight(panel ~= nil) end

	-- Baganator window navigated: LT hint on the panel, LT focuses it. Left alone when two Baganator windows are
	-- open, where BaganatorGamepad uses LT/RT to switch between them.
	local focusTarget = (anyView and not suppressed and bgActive and #views == 1) and unfocusedPanel() or nil
	setLeftHint(focusTarget)
	local newWantLeft = focusTarget ~= nil
	if newWantLeft ~= wantLeft then
		wantLeft = newWantLeft
		if bgActive then setLeft(wantLeft) end
	end

	refreshLegend((anyView and bgActive and not suppressed) and current or nil)
end

local function schedule()
	if pending then return end
	pending = true
	RunNextFrame(function()
		pending = false
		applyState()
	end)
end

-- BaganatorGamepad binding its named buttons: learn its owner, and re-apply our changes on top of its.
hooksecurefunc("SetOverrideBindingClick", function(owner, _, _, button)
	if rebindingOurselves or type(button) ~= "string" or not button:find("^BaganatorGamepad")
		or button:find("^BaganatorGamepadNits") then
		return
	end
	bgOwner = owner
	bgActive = true
	if InCombatLockdown() then return schedule() end
	if suppressed then
		clearingOurselves = true
		ClearOverrideBindings(owner)
		clearingOurselves = false
		rightBound = false
		if lastFocusedPanel() then setRight(true) end
	elseif button == PREVIOUS_WINDOW_BUTTON and wantLeft then
		SetOverrideBinding(owner, true, KEYS.lt, TOGGLE_UI_FOCUS)
	end
	schedule()
end)

hooksecurefunc("ClearOverrideBindings", function(owner)
	if owner ~= nil and owner == bgOwner and not clearingOurselves then
		bgActive = false
		rightBound = false
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
SlashCmdList.BAGANATORGAMEPADNITS = function()
	local m = manager()
	print("BaganatorGamepadNits: gamepad UI " .. tostring(gamepadUI()) .. ", views " .. #visibleViews()
		.. ", BaganatorGamepad owner " .. tostring(bgOwner ~= nil) .. " active " .. tostring(bgActive)
		.. ", highlight " .. tostring(bgHighlight ~= nil) .. ", suppressed " .. tostring(suppressed)
		.. ", wantLeft " .. tostring(wantLeft) .. ", rightBound " .. tostring(rightBound)
		.. ", legend " .. tostring(legend ~= nil) .. ", UI focused " .. tostring(m and m.isUIFocused)
		.. ", panels " .. tostring(m and m.shownFrames and #m.shownFrames))
	print("  LT -> " .. tostring(GetBindingByKey(KEYS.lt)) .. ", RT -> " .. tostring(GetBindingByKey(KEYS.rt)))
end
