# BaganatorGamepadNits (repo: wow-forever-baganator-gamepad-nits)

A standalone WoW addon that fixes four things about the [BaganatorGamepad](https://www.curseforge.com/wow/addons/baganator-gamepad)
addon (controller navigation for Baganator bags) on **World of Warcraft: Forever** (the native gamepad UI):

1. **Paging between the bag and a Blizzard panel.** With the stock bag and a merchant open, LT focuses the shop and
   RT the bag, each showing a trigger glyph. BaganatorGamepad instead holds the d-pad and face buttons whenever a
   Baganator window is visible, so a focused Blizzard panel cannot be navigated. This addon restores the stock flow.
2. **A button legend** under the navigated Baganator window, like the footer under the stock bag.
3. **Disarming Baganator's own controller capture** (Baganator 847+). Baganator shows a frame while a bag is open
   that swallows every controller button except Menu and the right stick, so BaganatorGamepad's bindings never
   fire, movement stops, and two leftover debug prints spam chat; it also binds X to click the first bag slot.
4. **The stock bag's Y "more actions" menu** for the selected item: Destroy, Split Stack, Share in Chat, Feed to Pet
   (hunters). Drawn and navigated by this addon; see below for why Blizzard's menu cannot be used. BaganatorGamepad's
   keys are also held back while a Blizzard popup (the destroy confirmation) is up, so the popup gets A/B.

Written against BaganatorGamepad 2.1.0, Baganator 847, Forever client 1.60.1 (Interface 16001), 2026-11-11.
Not yet confirmed in game at the time of writing; update this line when it is. Sibling of
`wow-forever-questie-gamepad` (QuestieGamepad), which documents the Blizzard gamepad UI in more depth.

## Layout

- `BaganatorGamepadNits/BaganatorGamepadNits.toc` — Interface 16001, `## Dependencies: Baganator, BaganatorGamepad`.
- `BaganatorGamepadNits/BaganatorGamepadNits.lua` — all the logic.
- `Makefile` — `make install` symlinks `BaganatorGamepadNits/` into the AddOns folder found by `find-wow-addons.sh`
  (macOS `/Applications`; on Linux Steam/Proton compatdata incl. Flatpak Steam and SD cards, Faugus, Lutris, Heroic,
  Bottles, `~/.wine`); override with `WOW_ADDONS=`; `make where` prints the folder; `make uninstall`; `make check`
  syntax-checks with `luajit`. `make` and `luajit` come from Homebrew (macOS and the Steam Deck).

## How it attaches (nothing in Baganator or BaganatorGamepad is edited)

BaganatorGamepad keeps everything local. What this addon can see of it:

- Its **buttons are global by name**: `BaganatorGamepadNav_<up|down|left|right>`, `BaganatorGamepadPickupButton`,
  `BaganatorGamepadBackButton`, `BaganatorGamepadUseButton`, `BaganatorGamepadSellButton`,
  `BaganatorGamepadPreviousWindow` (LT), `BaganatorGamepadNextWindow` (RT).
- Its **binding owner** is an anonymous frame; we learn it from a `hooksecurefunc("SetOverrideBindingClick")` when it
  binds one of those names, and track whether it believes it is active (last call was a bind, not a
  `ClearOverrideBindings` of that owner).
- Its **selection border** is an anonymous `BackdropTemplate` frame on `UIParent`, strata `TOOLTIP`, border colour
  (1, 0.82, 0); found once with `EnumerateFrames` (at most three attempts). The item button it is anchored to is the
  selected slot; fallback is `GameTooltip:GetOwner()` (it calls the button's OnEnter on selection).
- It **re-asserts its keys** whenever another owner binds one of them (`SetOverrideBinding`/`SetOverrideBindingClick`
  hooks, next frame). Binding one of our commands with our own owner would therefore loop forever. **All our bindings
  are set with its owner frame**, which its hook ignores; each of its `applyBindings` overwrites them and our
  `SetOverrideBindingClick` hook puts them straight back. To make it re-apply on demand we bind one of its keys with
  our own owner and clear it again ("poke").
- Views: the same discovery it uses — `UISpecialFrames` entries named `Baganator_*BackpackViewFrame*` /
  `*BankViewFrame*`, hooked OnShow/OnHide, rescanned after the bag toggles; `Baganator.CallbackRegistry`
  `ViewComplete` for relayouts. BaganatorGamepad's source is the model here. Baganator's source may be read to
  understand its behaviour (its AGENTS.md says not to; the owner has waived that for this purpose), but nothing is
  copied from it.
- **Baganator's gamepad trap** (`ItemViewCommon/GamepadTrap.lua`, 847+): an anonymous `Frame` on `UIParent` with
  `EnableGamePadStick(true)` and `OnGamePadButtonDown/Up` + `OnGamePadStick` scripts, shown from every backpack
  view's `OnShow` and hidden on `OnHide` (and on combat). It only calls `SetPropagateKeyboardInput(true)` for
  `PADFORWARD` and the right stick, so everything else is consumed before bindings. A named
  `BaganatorGamepadClicker` (`InsecureActionButtonTemplate`) gets a non-priority override binding on `PAD3` each
  time the trap arms. Only present when the gamepad UI was on at Baganator's load. We find the frame once with
  `EnumerateFrames` (anonymous, parent `UIParent`, has an `OnGamePadButtonUp` script, stick enabled; up to three
  attempts, at load and `PLAYER_ENTERING_WORLD`), nil its three scripts, `EnableGamePadButton(false)` /
  `EnableGamePadStick(false)`, and clear the clicker's bindings in a `SetOverrideBindingClick` hook. Its
  `FrameGlowTemplate` focus glow on the bag is left alone. `/bgnits` reports `Baganator trap disarmed`.
- **Stock Y menu** (`Blizzard_UIPanels_Game/Mainline/ContainerFrame.lua`, `SetupGamepad`, `itemMoreActions`): a
  `GamepadSharedUtility.CreateMoreActionsPromptedBinding(GAMEPAD_FACE_TOP)` whose entries are Feed to Pet
  (hunters, `C_PetInfo.CanPetEatItem`, `PickupContainerItem` + `C_Item.DropItemOnUnit("pet")`), Bind to Gamepad
  Action Bar (`GamepadActionBarEditFrame:BindItem`), Destroy (`C_Item.ConfirmDeleteItem(itemGUID)`), Share in Chat
  (`ChatFrameUtil.InsertLink` else `OpenChat`), Split Stack (`StackSplitFrame:OpenStackSplitFrame` under
  `FrameControlsManager:SuspendFrame`). Hidden while an item is held or a merchant is open
  (`Gamepad_IsItemUseBlocked`). `PromptedBinding.lua` `CreateMoreActionsMenu` builds it with
  `MenuUtil.CreateContextMenu`; `MenuProxyMixin` (`Blizzard_Menu/Menu.lua`) then registers the menu with the gamepad
  manager, which is why opening a Blizzard menu from addon code is off limits (taint rule). Gamepad popups
  (`Blizzard_StaticPopup/StaticPopupGamepad.lua`) take A/B/X/Y through a `BlockEverything` binding group with no UI
  focus, so `isUIFocused` does not flag them; `StaticPopup_IsAnyDialogShown()` does.

Blizzard side (source: GitHub `Gethe/wow-ui-source`, branch `forever`, sparse-clone `Interface/AddOns/Blizzard_Gamepad*`,
`Blizzard_SharedXML*`, `Blizzard_UIPanels_Game`):

- `GamepadMode.FrameControlsManager` (`Blizzard_GamepadSharedUtility/FrameControlsManager.lua`) keeps `shownFrames`
  (screen-ordered), `focusedFrame`, `isUIFocused`. LT/RT are function bindings to `FocusPreviousFrame`/`FocusNextFrame`,
  active only while the UI is focused. Every refresh calls `ShowLeftJumpHint`/`ShowRightJumpHint`/`ShowFocusJumpHint`
  on the frames (`FocusFramesInterfaceMixin`, `Blizzard_SharedXMLBase/FocusEffects.lua`: just shows the frame's
  `LeftJumpHint`/`RightJumpHint`/`FocusJumpHint` child, templates in `FocusEffectTemplates.xml`, anchored CENTER to the
  frame's BOTTOM, y 4) and fires `EventRegistry` `Gamepad.RefreshFrameFocus`. The stock bag is just another entry in
  `shownFrames`.
- **Taint rule:** never call into the manager (`FrameShown`, `SetUIFocusState`, `ToggleUIFocus`, `RefreshJumpHints`)
  or SmartNavigation from addon code, and never hand them a Baganator frame: `isUIFocused` and friends would become
  tainted and `SetPreferredGamepadInteractTarget` gets blocked in a popup loop. Reading its fields is fine.
- The way out is the binding command **`TOGGLEUIFOCUS`** (`Blizzard_Gamepad/Bindings.xml`, runs
  `GamepadMode.ToggleUIFocus()`): bound to a key with `SetOverrideBinding(owner, true, key, "TOGGLEUIFOCUS")`, the client
  runs it untainted on the key press. Unfocusing drops the panel's focus (BaganatorGamepad gets its keys back);
  focusing picks the manager's `focusedFrame` again.
- The stock footer is `GamepadSharedUtility.CreatePromptedBindingFooter` (bindings + legend). The drawing half is
  public and binding-free: `InputPromptLegends.CreateInputLegend(parent, key)` returns a legend whose
  `RefreshWithPromptedBindings(list)` only needs objects answering `GetInputIconTemplate()`
  (`InputPromptLegends.PromptTemplates.StandardOneIcon`), `GetDisplayKeys()`, `GetFooterBindingLabel()`,
  `IsFooterConditionMet()`, `IsFooterHoldPrompt()` (`InputLegendPromptGroup.lua`). Prompts are laid out in creation
  order, so they are pre-created at load in Blizzard's order (A, X, B). The stock bag's labels are the globals
  `ACTION_LABEL_SELECT`, `CONTEXT_ACTION_LABEL_SELL/EQUIP/USE`, `FRAME_ACTION_CLOSE/BACK` (plain-English fallbacks).
- SmartNavigation hooks global `CreateFrame` and rebuilds the open panel's button groups when a frame is created inside
  it; all our frames hang off `UIParent` (the legend under our own host frame), where that is a no-op.

## Behaviour

State is re-evaluated after every manager refresh, Baganator view show/hide/relayout, BaganatorGamepad binding call,
cursor/bag/merchant/combat event, and on a 0.1 s poll (its d-pad moves are invisible to us).

- **Panel focused** (`isUIFocused`, a Baganator view visible): BaganatorGamepad's bindings are cleared (and cleared
  again after each of its re-applies), its border hidden. If the focused panel is last in `shownFrames` (Blizzard's RT
  does nothing there), our RT glyph (`FrameRightJumpHintTemplate`) sits on the Baganator window and RT runs
  `TOGGLEUIFOCUS`. Otherwise RT stays Blizzard's (paging to the next panel).
- **Bag navigated** (UI unfocused, BaganatorGamepad active, exactly one Baganator view, a panel shown): the panel's own
  `LeftJumpHint` is shown and its `FocusJumpHint` hidden (re-done after each Blizzard refresh; restored when we stop),
  and LT runs `TOGGLEUIFOCUS` instead of BaganatorGamepad's window switch. With two Baganator views (bag + bank) LT/RT
  are left to BaganatorGamepad.
- **Legend**: shown under the navigated view while BaganatorGamepad is active and no panel is focused. A "Select"
  (enabled with an item or a held item), X "Sell" with a merchant open, else "Equip"/"Use" (enabled when the item is),
  B "Close"/"Back" (held item). It mirrors what BaganatorGamepad's keys do; change both together.
- **More actions (Y)**: while the bag is navigated, Y (bound on BaganatorGamepad's owner, re-set after each of its
  re-applies) opens our menu next to the selected item: Feed to Pet (hunters, pet food), Destroy (red), Share in Chat
  (only while a chat edit box is open), Split Stack (stacks over 1). Not offered: Bind to Gamepad Action Bar (opens a
  managed Blizzard frame). Like the stock bag, nothing opens while an item is held or a merchant is shown. The d-pad,
  A, B, X and Y are ours while it is open (on bgOwner); LT/RT stay BaganatorGamepad's and a window switch, panel
  focus, popup or combat closes the menu. A runs the entry and closes; B/Y close. Destroy is `PickupContainerItem` +
  `DeleteCursorItem` in the key's hardware event, so Blizzard's own confirmation popup appears (the client raises
  `DELETE_ITEM_CONFIRM`). Split Stack turns the menu into a stepper: d-pad left/right by 1, up/down by 10, A calls
  `C_Container.SplitContainerItem` (the split lands on the cursor; A on an empty slot places it through
  BaganatorGamepad), B goes back to the bag. A second legend under the menu shows A/B (and the d-pad amount in split
  mode); the bag legend is hidden meanwhile and shows a Y "More Actions" prompt otherwise.
- **Popups**: `StaticPopup_IsAnyDialogShown()` counts as a focused panel for the suppression above, so Blizzard's
  popup bindings are not fought by BaganatorGamepad's re-asserts. No RT hint is shown in that state.
- Nothing is bound in combat; BaganatorGamepad drops out on `PLAYER_REGEN_DISABLED` and so does everything here.
- `/bgnits` prints the state (owner found, active, highlight found, suppressed, trap, Y bound, menu mode, what LT/RT
  are bound to).

## After a BaganatorGamepad or Blizzard update

- `grep -n "CreateFrame(\"Button\", \"BaganatorGamepad\|bindingOwner\|SetBackdropBorderColor\|onForeignBinding" BaganatorGamepad.lua`
  in the installed addon: button names, owner handling and border colour are what this addon keys on.
- Blizzard: `TOGGLEUIFOCUS` still in `Blizzard_Gamepad/Bindings.xml`; `shownFrames`/`focusedFrame`/`isUIFocused` and
  `Gamepad.RefreshFrameFocus` in `FrameControlsManager.lua`; `LeftJumpHint`/`FocusJumpHint` in `FocusEffects.lua`;
  `InputPromptLegends.CreateInputLegend` and `RefreshWithPromptedBindings` in `InputLegendPromptGroup.lua`.
- If BaganatorGamepad grows its own panel paging, legend or Y menu, retire the corresponding part here. If it starts
  binding `PAD4` itself, our Y re-set in the `SetOverrideBindingClick` hook will fight it; drop ours.
- Blizzard: `itemMoreActions` entries in `ContainerFrame.lua` `SetupGamepad` (did the stock menu gain or lose
  entries?), `StaticPopup_IsAnyDialogShown` in `Blizzard_StaticPopup/StaticPopup.lua`, `GAMEPAD_DPAD_HORIZONTAL`
  in `GamepadConstants.lua`.
- Baganator: `grep -n "OnGamePad\|SetPropagateKeyboardInput\|BaganatorGamepadClicker\|print(" ItemViewCommon/GamepadTrap.lua`
  in the installed addon. If the trap frame gains a name or moves off `UIParent`, update `findTrapFrame`; if
  Baganator adds a setting to turn its capture off, or drops it, retire the disarm code.
- Then `make check`, update the version line at the top, `/reload`, test.

## Testing in game

- Controller UI on, Baganator bag open at a merchant. Press Blizzard's focus button or LT: the shop gets the cursor and
  its footer, the bag shows the RT glyph at its bottom centre, d-pad moves in the shop. RT: cursor leaves the shop, the
  bag's gold border is back, the shop shows the LT glyph, our legend appears under the bag. LT again returns to the shop.
- Legend: move over an equippable item (X reads "Equip"), a potion ("Use"), with the merchant open ("Sell"); pick an
  item up (A "Select" stays, B reads "Back"), B clears it.
- Bag + bank open: LT/RT still switch between the two Baganator windows; no LT glyph on a panel.
- Close the merchant while the bag is navigated: LT goes back to BaganatorGamepad's window switch.
- Taint: `/console taintLog 2`, reproduce, then look for `BaganatorGamepadNits` in `Logs/taint.log`. Any "blocked from
  an action only available to the Blizzard UI" popup is a failure.
- `/bgnits` should report owner true, highlight true, and LT/RT bound to `TOGGLEUIFOCUS` in the right state.
- Y menu: navigate to a stack of 5+ potions, press Y: a dark menu appears right of the slot with Destroy (red) and
  Split Stack, a legend under it (A Select, B Back), the bag legend gone. Down/Up moves the highlight. A on Split
  Stack: the menu shows `<  1 / 4  >`; Right twice reads 3, Up clamps to 4, A: the menu closes, the split is on the
  cursor (B label reads Back), A on an empty slot places it. Y again, Destroy, A: Blizzard's confirmation popup
  appears and answers to the controller (BaganatorGamepad's border is hidden while it is up); No restores the bag
  navigation. Y with an item held, or at a merchant, does nothing. Open chat (type nothing), close it with the
  chat box still focused, Y: Share in Chat is listed and A inserts the link. Hunters: Y on pet food lists Feed to Pet.
  `/bgnits` reports `moreBound true, menu false` with the menu closed.
- Baganator 847+: open the bag with the controller. Nothing is printed to chat (no `gpb PAD...`, no stick names),
  the d-pad moves BaganatorGamepad's selection, the left stick still moves the character, and X with the merchant
  focused does not click the first bag slot. `/bgnits` reports `Baganator trap disarmed`.
