-- Walks BaganatorGamepadNits through its main scenarios against a stubbed WoW API: navigation, shop paging, the Y
-- menu, bag + bank, combat, the BaganatorGamepad warning. Run with `make test`. The stubs only model what the addon
-- touches (frames as bags of no-op methods, override bindings as a table per owner); it says nothing about
-- Blizzard's real binding priority, secure buttons or Baganator's real frames.

local realPrint = print
print = function() end -- the addon's chat output
local path = arg[1]
local FM = {}
FM.__index = function(t, k)
	if FM[k] then return FM[k] end
	if k == "GetBagID" or k == "parent" or k == "rect" or k == "id" or k == "name" or k == "CloseButton"
		or k == "LeftJumpHint" or k == "FocusJumpHint" or k == "disableFrameFocusPagingWhenFocused" or k == "SetBackdrop" then return nil end
	return function() end
end
local function newFrame(name, parent)
	local f = setmetatable({ name = name, parent = parent, shown = true, scripts = {}, children = {}, attrs = {} }, FM)
	if parent and parent.children then table.insert(parent.children, f) end
	if name then _G[name] = f end
	return f
end
function FM:GetName() return self.name end
function FM:GetParent() return self.parent end
function FM:Show() if not self.shown then self.shown = true; if self.scripts.OnShow then self.scripts.OnShow(self) end end end
function FM:Hide() if self.shown then self.shown = false; if self.scripts.OnHide then self.scripts.OnHide(self) end end end
function FM:IsShown() return self.shown end
function FM:IsVisible() local f = self; while f do if not f.shown then return false end; f = f.parent end; return true end
function FM:SetScript(k, fn) self.scripts[k] = fn end
function FM:GetScript(k) return self.scripts[k] end
function FM:HookScript(k, fn) local old = self.scripts[k]; self.scripts[k] = function(...) if old then old(...) end; fn(...) end end
function FM:GetChildren() return unpack(self.children) end
function FM:GetScaledRect() if self.rect then return unpack(self.rect) end end
function FM:GetID() return self.id end
function FM:SetAttribute(k, v) self.attrs[k] = v end
function FM:CreateFontString() return newFrame() end
function FM:CreateTexture() return newFrame() end
function FM:GetStringWidth() return 50 end
function FM:Click() if self.scripts.OnClick then self.scripts.OnClick(self) end end
function FM:IsForbidden() return false end
function FM:GetObjectType() return "Frame" end
UIParent = newFrame("UIParent")
function CreateFrame(_, name, parent) return newFrame(name, parent) end
local combatLock = false
function InCombatLockdown() return combatLock end
function hooksecurefunc(a, b, c)
	local t, k, fn = _G, a, b
	if type(a) == "table" then t, k, fn = a, b, c end
	local old = t[k]
	t[k] = function(...) local r = old(...); fn(...); return r end
end
local queue = {}
function RunNextFrame(fn) table.insert(queue, fn) end
function Tick() local q = queue; queue = {}; for _, fn in ipairs(q) do fn() end end
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
date = os.date
GetTime = os.clock
bindings = {}
function SetOverrideBinding(o, _, key, action) bindings[o] = bindings[o] or {}; bindings[o][key] = action end
function SetOverrideBindingClick(o, _, key, btn) bindings[o] = bindings[o] or {}; bindings[o][key] = "CLICK " .. btn end
function ClearOverrideBindings(o) bindings[o] = {} end
function GetBindingAction(key) for _, b in pairs(bindings) do if b[key] then return b[key] end end return "" end
cursor = false
function CursorHasItem() return cursor end
function ClearCursor() cursor = false end
C_Container = {
	GetContainerItemInfo = function(bag, slot) assert(type(bag) == "number"); return { itemID = bag * 100 + slot, stackCount = 5 } end,
	PickupContainerItem = function() cursor = not cursor end,
	UseContainerItem = function(b, s) sold = b .. "/" .. s end,
	GetContainerItemID = function(b, s) return b * 100 + s end,
	GetContainerItemLink = function() return "link" end,
	SplitContainerItem = function(b, s, n) split = n; cursor = true end,
}
C_Item = { IsEquippableItem = function() return false end, IsUsableItem = function() return true end }
C_Timer = { After = function() end }
C_AddOns = { IsAddOnLoaded = function(n) return n == "BaganatorGamepad" and bgLoaded end }
function UnitClass() return "Mage", "MAGE" end
local color = { GetRGB = function() return 1, 1, 1 end }
NORMAL_FONT_COLOR, HIGHLIGHT_FONT_COLOR, RED_FONT_COLOR = color, color, color
GameTooltip = newFrame("GameTooltip")
UISpecialFrames = {}
SlashCmdList = {}
InputUtil = { IsGamepadUIEnabled = function() return true end }
GamepadMode = { FrameControlsManager = { shownFrames = {}, isUIFocused = false } }
local viewComplete
Baganator = { CallbackRegistry = { RegisterCallback = function(_, _, fn) viewComplete = fn end } }
popup = false
function StaticPopup_IsAnyDialogShown() return popup end
function DeleteCursorItem() deleted = true; cursor = false end

-- A 3x2 bag and a 2x1 bank
local function makeView(name, x0, cols, rows, bag)
	local v = newFrame(name, UIParent)
	v.rect = { x0, 0, cols * 40, rows * 40 + 40 }
	local n = 0
	for r = 1, rows do for c = 1, cols do
		n = n + 1
		local holder = newFrame(nil, v)
		local b = newFrame(nil, holder)
		b.rect = { x0 + (c - 1) * 40, (rows - r) * 40, 40, 40 }
		b.id = n
		b.GetBagID = function() return bag end
		b.scripts.OnEnter = function(self) tip = self end
		b.scripts.OnLeave = function() tip = nil end
	end end
	v.shown = false
	table.insert(UISpecialFrames, name)
	return v
end
local bag = makeView("Baganator_SingleViewBackpackViewFrameblizzard", 500, 3, 2, 0)
local bank = makeView("Baganator_SingleViewBankViewFrameblizzard", 100, 2, 1, -1)

stack = "" -- what debugstack reports to the C_Timer.After hook
function debugstack() return stack end
assert(loadfile(path))("BaganatorGamepadNits")
local ev = _G.BaganatorGamepadNits_Events.scripts.OnEvent
local own = _G.BaganatorGamepadNits_Owner
local function fire(...) ev(nil, ...) end
local function press(key)
	local a = bindings[own] and bindings[own][key]
	assert(a, "nothing bound on " .. key)
	if a == "TOGGLEUIFOCUS" then
		local m = GamepadMode.FrameControlsManager
		m.isUIFocused = not m.isUIFocused
		_G.BaganatorGamepadNits_Events.scripts.OnUpdate(nil, 1) -- stands in for Gamepad.RefreshFrameFocus
		return a
	end
	local btn = _G[a:match("^CLICK (.+)$")]
	if btn.scripts.OnClick then btn.scripts.OnClick(btn) end
	return a
end
local function sel() local hl = _G.BaganatorGamepadNits_Highlight; if hl.shown and tip then return tip.id end end
local function count() local n = 0; for _ in pairs(bindings[own] or {}) do n = n + 1 end return n end
local function eq(a, b, what) if a ~= b then error(("%s: got %s, wanted %s"):format(what, tostring(a), tostring(b)), 2) end end

fire("ADDON_LOADED", "BaganatorGamepadNits")
fire("PLAYER_ENTERING_WORLD"); Tick()
eq(count(), 0, "nothing bound with the bag closed")
bag:Show(); Tick()
eq(count(), 10, "all ten keys bound"); eq(sel(), 1, "top left selected")
press("PADDRIGHT"); eq(sel(), 2, "right")
press("PADDDOWN"); eq(sel(), 5, "down")
press("PADDDOWN"); eq(sel(), 5, "no wrap")
press("PADDLEFT"); press("PADDUP"); eq(sel(), 1, "back to 1")
eq(_G.BaganatorGamepadNits_Use.attrs.item, "0 1", "use attribute")
eq(press("PAD3"), "CLICK BaganatorGamepadNits_Use", "X uses")
eq(press("PADLTRIGGER"), "CLICK BaganatorGamepadNits_PreviousWindow", "LT with no panel"); eq(sel(), 1, "no switch with one view")
-- pick up / drop
press("PAD1"); eq(cursor, true, "picked up"); press("PAD2"); eq(cursor, false, "B drops"); eq(bag.shown, true, "bag stays")
-- merchant: a panel shown, unfocused
local m = GamepadMode.FrameControlsManager
MerchantFrame = newFrame("MerchantFrame", UIParent)
m.shownFrames = { MerchantFrame }; m.focusedFrame = MerchantFrame
fire("MERCHANT_SHOW"); Tick()
eq(bindings[own].PADLTRIGGER, "TOGGLEUIFOCUS", "LT focuses the shop")
eq(press("PAD3"), "CLICK BaganatorGamepadNits_Sell", "X sells"); eq(sold, "0/1", "sold")
-- Baganator relays out after the sale and reuses the pooled buttons: the object under the border now draws another
-- place (in a category view, the empty-slot placeholder). The border stays where the item was.
local function buttonWithID(id) for _, holder in ipairs(bag.children) do if holder.children[1].id == id then return holder.children[1] end end end
local b1, b2 = buttonWithID(1), buttonWithID(2)
b1.rect, b2.rect = b2.rect, b1.rect
viewComplete(); Tick(); eq(sel(), 2, "border stays in place, not on the pooled button")
b1.rect, b2.rect = b2.rect, b1.rect
viewComplete(); Tick(); eq(sel(), 1, "and again when the buttons swap back")
for _, holder in ipairs(bag.children) do local r = holder.children[1].rect; r[1] = r[1] + 5 end
viewComplete(); Tick(); eq(sel(), 1, "a small shift of the whole layout keeps the button")
for _, holder in ipairs(bag.children) do local r = holder.children[1].rect; r[1] = r[1] - 5 end
viewComplete(); Tick(); eq(sel(), 1, "and back")
press("PAD4"); eq(_G.BaganatorGamepadNits_Menu.shown, false, "no menu at a merchant")
press("PADLTRIGGER"); Tick()
eq(count(), 1, "only RT while the shop is focused"); eq(bindings[own].PADRTRIGGER, "TOGGLEUIFOCUS", "RT leaves the shop")
eq(sel(), nil, "border hidden while suppressed")
-- Blizzard takes RT; we take it back
SetOverrideBindingClick(UIParent, true, "PADRTRIGGER", "InputFunctionBindingButton_PADRTRIGGER")
bindings[own] = {}; Tick(); eq(bindings[own].PADRTRIGGER, "TOGGLEUIFOCUS", "re-asserted")
press("PADRTRIGGER"); Tick()
eq(count(), 10, "bag navigated again"); eq(sel(), 1, "border back")
-- merchant closes
MerchantFrame.shown = false; m.shownFrames = {}; m.focusedFrame = nil
fire("MERCHANT_CLOSED"); Tick()
eq(bindings[own].PADLTRIGGER, "CLICK BaganatorGamepadNits_PreviousWindow", "LT back to window switch")
-- Y menu: split
press("PAD4"); eq(_G.BaganatorGamepadNits_Menu.shown, true, "menu open")
eq(bindings[own].PADDUP, "CLICK BaganatorGamepadNits_Menu_up", "menu owns the d-pad")
press("PADDDOWN"); press("PAD1"); press("PADDRIGHT"); press("PADDRIGHT"); press("PADDUP"); press("PAD1")
eq(split, 4, "split amount clamps to 4"); eq(_G.BaganatorGamepadNits_Menu.shown, false, "menu closed")
eq(bindings[own].PADDUP, "CLICK BaganatorGamepadNits_Nav_up", "d-pad back"); cursor = false
-- Y menu: destroy, popup
press("PAD4"); press("PAD1"); eq(deleted, true, "destroyed")
popup = true; fire("DELETE_ITEM_CONFIRM"); Tick(); eq(count(), 0, "nothing bound under a popup")
popup = false; _G.BaganatorGamepadNits_Events.scripts.OnUpdate(nil, 1); eq(count(), 10, "poll notices the popup going")
-- bank
bank:Show(); fire("BANKFRAME_OPENED"); Tick()
press("PADDRIGHT"); eq(sel(), 2, "bag 2")
press("PADRTRIGGER"); eq(tip.GetBagID(), -1, "switched to the bank"); eq(sel(), 1, "bank 1")
press("PADLTRIGGER"); eq(tip.GetBagID(), 0, "back in the bag"); eq(sel(), 2, "remembered")
-- relayout keeps the selection
viewComplete(); Tick(); eq(sel(), 2, "kept after ViewComplete")
-- combat
fire("PLAYER_REGEN_DISABLED"); combatLock = true
eq(count(), 0, "cleared at combat start"); eq(sel(), nil, "no border in combat")
Tick(); combatLock = false; fire("PLAYER_REGEN_ENABLED"); Tick()
eq(count(), 10, "back after combat"); eq(sel(), 2, "selection restored")
-- B closes both
press("PAD2"); eq(bag.shown or bank.shown, false, "closed"); eq(count(), 0, "keys given back"); Tick()
eq(count(), 0, "still nothing bound")
-- Baganator's own hand-off of a view to Blizzard's manager, deferred through C_Timer.After(0, ...): the closure's
-- GamepadMode must be redirected to our stub when the stack shows a bag or bank view announcing itself, and left
-- alone for Baganator's other panels. Each case is a fresh closure, as in Baganator (setfenv is per function).
local handedOff = 0
GamepadMode.FrameControlsManager.FrameShown = function() handedOff = handedOff + 1 end
local function announce() return function() GamepadMode.FrameControlsManager:FrameShown(bag) end end
local function defer(delay, trace) stack = trace; local fn = announce(); C_Timer.After(delay, fn); fn() end
local V = "Interface/AddOns/Baganator/"
defer(0, V .. "Core/Gamepad.lua:32: in function `AnnounceShow'\n" .. V .. "ItemViewCommon/BackpackView.lua:150: in function <...>")
eq(handedOff, 0, "855 bag announce blocked")
defer(0, V .. "Core/Gamepad.lua:32: in function `AnnounceShow'\n" .. V .. "ItemViewCommon/BankView.lua:159: in function <...>")
eq(handedOff, 0, "855 bank announce blocked")
defer(0, V .. "ItemViewCommon/Gamepad.lua:20: in function `AnnounceShow'\n" .. V .. "ItemViewCommon/BackpackView.lua:140: in function <...>")
eq(handedOff, 0, "851 bag announce blocked")
defer(0, V .. "ItemViewCommon/BankView.lua:150: in function <...>")
eq(handedOff, 0, "851 bank announce blocked")
defer(0, V .. "Core/Gamepad.lua:32: in function `AnnounceShow'\n" .. V .. "CustomiseDialog/Main.lua:1259: in function <...>")
eq(handedOff, 1, "customise dialog keeps its focus")
defer(0, V .. "Core/Gamepad.lua:32: in function `AnnounceShow'\n" .. V .. "Core/Dialogs.lua:32: in function <...>")
eq(handedOff, 2, "Baganator popups keep their focus")
defer(0, V .. "ItemViewCommon/CurrencyPanel.lua:14: in function <...>")
eq(handedOff, 3, "the currency panel's own timer is not a view announce")
defer(1, V .. "Core/Gamepad.lua:32: in function `AnnounceShow'\n" .. V .. "ItemViewCommon/BackpackView.lua:150: in function <...>")
eq(handedOff, 4, "only zero-delay timers are looked at")
-- conflict
bgLoaded = true; fire("ADDON_LOADED", "BaganatorGamepad")
local printed = {}
print = function(text) table.insert(printed, text) end
SlashCmdList.BAGANATORGAMEPADNITS(""); SlashCmdList.BAGANATORGAMEPADNITS("log")
eq(printed[1]:find("BaganatorGamepad addon is also enabled", 1, true) ~= nil, true, "/bgnits repeats the warning")
local blocked = false
for _, line in ipairs(printed) do if line:find("native nav blocked 4", 1, true) then blocked = true end end
eq(blocked, true, "/bgnits counts the blocked announces")
eq(printed[#printed]:find("BaganatorGamepad is loaded too", 1, true) ~= nil, true, "the log names the conflict")
realPrint("walk-through ok")
