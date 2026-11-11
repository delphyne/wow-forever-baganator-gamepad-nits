# BaganatorGamepadNits (repo: wow-forever-baganator-gamepad-nits)

A standalone WoW addon that fixes two things about the [BaganatorGamepad](https://www.curseforge.com/wow/addons/baganator-gamepad)
addon (controller navigation for Baganator bags) on **World of Warcraft: Forever** (the native gamepad UI):

1. **Paging between the bag and a Blizzard panel.** With the stock bag and a merchant open, LT focuses the shop and
   RT the bag, each showing a trigger glyph. BaganatorGamepad instead holds the d-pad and face buttons whenever a
   Baganator window is visible, so a focused Blizzard panel cannot be navigated. This addon restores the stock flow.
2. **A button legend** under the navigated Baganator window, like the footer under the stock bag.

Written against BaganatorGamepad 2.1.0, Baganator 846, Forever client 1.60.1 (Interface 16001), 2026-11-11.
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
  `ViewComplete` for relayouts. Do not read Baganator's own source (its AGENTS.md forbids it); BaganatorGamepad's
  source is fine and is the model here.

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
- Nothing is bound in combat; BaganatorGamepad drops out on `PLAYER_REGEN_DISABLED` and so does everything here.
- `/bgnits` prints the state (owner found, active, highlight found, suppressed, what LT/RT are bound to).

## After a BaganatorGamepad or Blizzard update

- `grep -n "CreateFrame(\"Button\", \"BaganatorGamepad\|bindingOwner\|SetBackdropBorderColor\|onForeignBinding" BaganatorGamepad.lua`
  in the installed addon: button names, owner handling and border colour are what this addon keys on.
- Blizzard: `TOGGLEUIFOCUS` still in `Blizzard_Gamepad/Bindings.xml`; `shownFrames`/`focusedFrame`/`isUIFocused` and
  `Gamepad.RefreshFrameFocus` in `FrameControlsManager.lua`; `LeftJumpHint`/`FocusJumpHint` in `FocusEffects.lua`;
  `InputPromptLegends.CreateInputLegend` and `RefreshWithPromptedBindings` in `InputLegendPromptGroup.lua`.
- If BaganatorGamepad grows its own panel paging or legend, retire the corresponding half here.
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
