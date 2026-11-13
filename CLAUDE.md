# BaganatorGamepadNits (repo: wow-forever-baganator-gamepad-nits)

A standalone WoW addon: controller navigation for [Baganator](https://www.curseforge.com/wow/addons/baganator) bags
on **World of Warcraft: Forever** (the native gamepad UI). It began as fixes layered on top of the
[BaganatorGamepad](https://www.curseforge.com/wow/addons/baganator-gamepad) addon, hence the name, and since 0.3.0
(2026-11-13) replaces it: the navigation is implemented here, written from that addon's behaviour (2.1.0; it ships
no licence, so none of its code is copied). **The two must not both be enabled**; a warning is printed when they are.

1. **Navigation.** While a Baganator bag or bank window is open, out of combat: the d-pad moves a gold border between
   item buttons, A picks up/places, X uses or equips (sells at a merchant), B drops a held item or closes, LT/RT
   switch between bag and bank.
2. **Paging between the bag and a Blizzard panel.** With the stock bag and a merchant open, LT focuses the shop and
   RT the bag, each showing a trigger glyph. Same here: while a Blizzard panel has the controller we bind nothing
   but RT, so the panel can be navigated.
3. **A button legend** under the navigated Baganator window, like the footer under the stock bag.
4. **Disarming Baganator's own controller capture** (Baganator 847+). Baganator shows a frame while a bag is open
   that swallows every controller button except Menu and the right stick, so no binding fires, movement stops, and
   two leftover debug prints spam chat; it also binds X to click the first bag slot. 850+ instead registers the bag
   with Blizzard's manager; that is blocked too.
5. **The stock bag's Y "more actions" menu** for the selected item: Destroy, Split Stack, Share in Chat, Feed to Pet
   (hunters). Drawn and navigated by this addon; see below for why Blizzard's menu cannot be used. Nothing is bound
   while a Blizzard popup (the destroy confirmation) is up, so the popup gets A/B.

Written against Baganator 851, Forever client 1.60.1 (Interface 16001, build 70938), 2026-11-13, alongside
GamepadXIV 0.1.13 (see "Other controller addons"). The 0.3.0 rewrite has been walked through against a stubbed WoW
API only (`make test`), not in game; update this line when it is. Sibling of
`wow-forever-questie-gamepad` (QuestieGamepad), which documents the Blizzard gamepad UI in more depth.

## Layout

- `BaganatorGamepadNits/BaganatorGamepadNits.toc` — Interface 16001, `## Dependencies: Baganator`,
  `## SavedVariables: BaganatorGamepadNitsDB` (the event log, nothing else).
- `BaganatorGamepadNits/BaganatorGamepadNits.lua` — all the logic.
- `tests/walkthrough.lua` — the addon loaded into a stubbed WoW API (frames as bags of no-op methods, override
  bindings as a table per owner) and pressed through navigation, shop paging, the Y menu, bag + bank, combat and
  the BaganatorGamepad warning. It checks our logic, not Blizzard's binding priority, secure buttons or Baganator's
  real frames. Extend it when behaviour changes; a new global the addon calls may need a stub.
- `HANDOFF.md` — debugging procedure for the GamepadXIV binding reports: what to run in game, which saved
  variables to read afterwards, how to unstick the UI.
- `Makefile` — `make install` symlinks `BaganatorGamepadNits/` into the AddOns folder found by `find-wow-addons.sh`
  (macOS `/Applications`; on Linux Steam/Proton compatdata incl. Flatpak Steam and SD cards, Faugus, Lutris, Heroic,
  Bottles, `~/.wine`); override with `WOW_ADDONS=`; `make where` prints the folder; `make uninstall`; `make check`
  syntax-checks with `luajit`; `make test` also runs `tests/walkthrough.lua`. `make` and `luajit` come from Homebrew (macOS and the Steam Deck).

## How it attaches (nothing in Baganator is edited)

- **Views**: `UISpecialFrames` entries named `Baganator_*BackpackViewFrame*` / `*BankViewFrame*`, hooked
  OnShow/OnHide, rescanned after the bag toggles (a skin change builds new ones); `Baganator.CallbackRegistry`
  `ViewComplete` for relayouts. Baganator's source may be read to understand its behaviour (its AGENTS.md says not
  to; the owner has waived that for this purpose), but nothing is copied from it.
- **Item buttons**: every visible descendant of the current view that has a `GetBagID` method and whose centre lies
  inside the view's `GetScaledRect` (`collectItems`). That includes Baganator's bag-slot buttons, which can be
  selected (tooltip) but are not items. Collected with their screen positions on a layout pass only (view
  show/hide, `ViewComplete`, bank opened, entering the world, navigation switching on), never on the poll. The d-pad
  goes to the nearest button within 45 degrees of the direction (`nearest`); no wrapping. Selection survives a
  relayout by button, then by the window's last button, then by position (`reselect`).
- **Selection**: our gold border (`BaganatorGamepadNits_Highlight`, `BackdropTemplate`, strata `TOOLTIP`) anchored
  to the button, and the button's own `OnEnter` (the item tooltip) / `OnLeave`, run through `securecallfunction` so
  an error in Baganator's handler does not end our state pass (`display`).
- **Bindings**: priority override bindings on one frame, `BaganatorGamepadNits_Owner`, to our named buttons
  `BaganatorGamepadNits_<Nav_up|Nav_down|Nav_left|Nav_right|Pickup|Back|Use|Sell|PreviousWindow|NextWindow|More|
  Menu_<dir>|MenuSelect|MenuBack|Noop>`, plus the command `TOGGLEUIFOCUS`. Each state pass builds the whole table
  (`wantBindings`) and `applyBindings` clears the owner and binds it all again only when it differs from `applied`,
  so `applied` is the whole truth and a key the state does not call for is not ours. Every plain button runs
  `applyState()` after its click. `Use` is a `SecureActionButtonTemplate` of type `item` whose `item` attribute
  (`"<bag> <slot>"`) is written on selection, out of combat; `Sell` is a plain button calling
  `C_Container.UseContainerItem` (the secure item action never sells).
- **Re-assert**: Blizzard's gamepad UI re-applies its own override bindings whenever its binding stack changes. Hooks
  on `SetOverrideBinding`/`SetOverrideBindingClick` notice another owner binding a key we hold and bind ours again
  next frame (`onForeignBinding`; `/bgnits` counts them).
- **BaganatorGamepad enabled as well**: detected with `C_AddOns.IsAddOnLoaded` (its `ADDON_LOADED`, and
  `PLAYER_ENTERING_WORLD`); a red chat warning at login and on every `/bgnits`, and a log line. It re-asserts the
  same keys, so our re-assert ignores bindings to its `BaganatorGamepad*` buttons rather than trade the keys back
  and forth every frame. Nothing else is done about it: navigation is broken until one of the two is disabled.
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
- **Baganator's native controller navigation** (850+, replaces the trap; `ItemViewCommon/Gamepad.lua`
  `AnnounceShow` and `BankView.lua` `OnShow`): each bag/bank show defers
  `GamepadMode.FrameControlsManager:FrameShown(view)` with `C_Timer.After(0, ...)`, which would make the window a
  focused managed panel (`isUIFocused` true, so we would stay suppressed) and write manager state from
  addon code. No setting, private functions. We `hooksecurefunc(C_Timer, "After")`, and for zero-delay callbacks
  whose `debugstack` names one of those two files, `setfenv` the callback to an environment whose
  `GamepadMode.FrameControlsManager` is a stub (everything else falls through to `_G`). `/bgnits` reports
  `Baganator native nav blocked <n>` (counts up once per bag open). Baganator's customise dialog
  (`CustomiseDialog/Main.lua`) announces itself through the same `AnnounceShow`; a stack naming `CustomiseDialog` is
  left alone, so the dialog stays a focusable panel. Its `SmartNavigation_Add*JumpNavigationOverride` /
  `SetTargetButtonForFrame` calls are not intercepted. If Baganator moves the call, drops the timer, or adds a
  setting, revisit: `grep -rn "FrameControlsManager\|IsGamepadInUse" Baganator`.
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
  runs it untainted on the key press. Unfocusing drops the panel's focus (the next state pass binds the bag's keys again);
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

One function, `applyState`, derives everything from what is on screen. It runs (next frame) after every manager
refresh, Baganator view show/hide/relayout, foreign binding of one of our keys, cursor/bag/merchant/combat event,
directly after each of our button clicks, and on a 0.1 s poll while a view is open (a Blizzard popup going up or
away has no event we listen to).

- **States**: `active` = controller UI on, a Baganator view visible, out of combat. `suppressed` = active and
  (`isUIFocused` or `StaticPopup_IsAnyDialogShown()`). `navigated` = active and not suppressed. `/bgnits` prints all
  three.
- **Navigated**: the border and tooltip are on the selected button; d-pad, A (`Pickup`), B (`Back`), X (`Use`, or
  `Sell` with `MerchantFrame` shown), Y (`More`), LT (`PreviousWindow`) and RT (`NextWindow`) are bound. With one
  Baganator view the window switch does nothing; the triggers are bound all the same (as BaganatorGamepad did). With
  exactly one view and a Blizzard panel shown but unfocused, the panel's own `LeftJumpHint` is shown and its
  `FocusJumpHint` hidden (re-done after each Blizzard refresh; restored when we stop), and LT runs `TOGGLEUIFOCUS`
  instead. With two views (bag + bank) LT/RT switch between them and there is no hint.
- **Suppressed**: nothing is bound and the border and tooltip are taken down, so the panel or popup has every key.
  If a panel is focused and last in `shownFrames` (Blizzard's RT does nothing there), our RT glyph
  (`FrameRightJumpHintTemplate`) sits on the Baganator window and RT runs `TOGGLEUIFOCUS`; otherwise RT stays
  Blizzard's (paging to the next panel). No RT hint for a popup alone (`lastFocusedPanel` requires `isUIFocused`:
  `TOGGLEUIFOCUS` would focus a panel, not leave it).
- **Legend**: shown under the current view while navigated and the menu is closed. A "Select" (enabled with an item
  or a held item), X "Sell" with a merchant open, else "Equip"/"Use" (enabled when the item is), Y "More Actions",
  B "Close"/"Back" (held item). It describes what the buttons above do; change both together.
- **More actions (Y)**: opens our menu next to the selected item: Feed to Pet (hunters, pet food), Destroy (red),
  Share in Chat (only while a chat edit box is open), Split Stack (stacks over 1). Not offered: Bind to Gamepad
  Action Bar (opens a managed Blizzard frame). Like the stock bag, nothing opens while an item is held or a merchant
  is shown. While it is open the d-pad, A, B, X and Y are bound to the menu's buttons; LT/RT keep their bag meaning
  and a window switch, panel focus, popup or combat closes the menu (the state pass sees the selection or state
  change). A runs the entry and closes; B/Y close. Destroy is `PickupContainerItem` + `DeleteCursorItem` in the key's
  hardware event, so Blizzard's own confirmation popup appears (the client raises `DELETE_ITEM_CONFIRM`, which also
  triggers a state pass). Split Stack turns the menu into a stepper: d-pad left/right by 1, up/down by 10, A calls
  `C_Container.SplitContainerItem` (the split lands on the cursor; A on an empty slot places it), B goes back to the
  bag. A second legend under the menu shows A/B (and the d-pad amount in split mode).
- **Combat**: `PLAYER_REGEN_DISABLED` runs `applyState` synchronously, the last moment bindings can change, and
  everything is cleared; nothing is bound until `PLAYER_REGEN_ENABLED`, when the selection comes back.
- **No stray `TOGGLEUIFOCUS`**: pressed with no panel shown that command only prints Blizzard's
  `ERROR_NO_FRAME_TO_FOCUS` ("No interface frame to focus", `FrameControlsManager.lua` `SetUIFocusState`), and it
  hides whatever else the trigger should do (GamepadXIV's crossbar once the bag is closed). A trigger carries it only
  while `wantBindings` asks for it; a panel closing fires `Gamepad.RefreshFrameFocus`, and the pass after it rebinds.
  (Before 0.3.0 two addons wrote LT/RT and a separate audit cleared stale ones; with one writer there is none.)
- `/bgnits` prints the state (views, active/suppressed/navigated, item buttons collected, panels, trap, menu mode,
  re-assert count, whether BaganatorGamepad is loaded, selected slot, and what LT/RT/A/X/Y/B/d-pad-up are bound to).
  `/bgnits log` prints the last 60 events (`navigation on/off`, `bound <bag|menu|panel|off> LT .. RT .. Y ..` on each
  change of the binding table, suppression changes with the manager's state, menu open/close, combat and merchant
  events, any `ADDON_ACTION_BLOCKED`/`FORBIDDEN` naming this addon) with wall-clock times. The ring is also the
  saved variable `BaganatorGamepadNitsDB` (`log`, `logCount` to order the ring, `previous`/`previousCount` from the
  session before), written on `/reload` or logout, so a report can be read from
  `WTF/Account/<account>/<realm>/<character>/SavedVariables/BaganatorGamepadNits.lua` after the fact.
- Forever has no global `GetBindingByKey` (only `C_KeyBindings.GetBindingByKey`); a key's current action, override
  bindings included, is `GetBindingAction(key, true)`. Calling the former cost the legend once: the error at the end
  of `applyState` aborted the pass just before `refreshLegend`.
- Item buttons are only trusted through `slotOf` (numeric `GetBagID()` and `GetID()`): Baganator's bag-slot and
  other buttons answer `GetBagID` with nil, and `C_Container.GetContainerItemInfo(nil)` raises an error (19 of them
  in GamepadXIV's error log on 2026-11-12, from the legend refresh).

## Other controller addons

- **GamepadXIV** (`GamepadXIV/Input.lua`, `Snippets.lua`): an FFXIV-style crossbar. A `SecureHandlerStateTemplate`
  driver sets non-priority override bindings on itself from restricted snippets, so our `hooksecurefunc` hooks (the
  re-assert) never see them. L2/R2 are its crossbar modifiers; Back cycles windows by reading
  `shownFrames`/`isUIFocused`/`focusedFrame` (never calling the manager) and clicking Forever's own
  `InputFunctionBindingButton_PADRTRIGGER`, binding `OPENCHAT` with nothing open, or leaving Back to Forever's
  `TOGGLEUIFOCUS` while an unfocused panel is shown. It re-syncs after `InputBindingManager:RemoveSet`/`ClearBindings`,
  because Blizzard writes empty non-priority overrides on `UIParent` when a binding set goes.
- While a Baganator window is open, our priority d-pad, face and LT/RT bindings beat GamepadXIV's, so its crossbar
  is unavailable then (GamepadXIV accepts the same from any focused Blizzard panel). From the navigated bag its Back
  focuses the panel exactly as our LT does. Once the Baganator window closes, the next state pass clears our owner.
- The two reports below were made before 0.3.0, with BaganatorGamepad 2.1.0 doing the navigation and this addon
  binding on its owner frame; "BaganatorGamepad" in them means what is now our own navigation.
- Its `errorLog` (saved variable `GamepadXIVDB`, via `seterrorhandler`) keeps other addons' Lua errors with stacks;
  read it after a test session. Report of 2026-11-12: after RT handed the bag to BaganatorGamepad, GamepadXIV
  "stopped working" and "No interface frame to focus" appeared. That session ran the previous commit (the logged
  stack line numbers), under which Baganator 851 registered the bag as a focused Blizzard panel; the sequence could not
  be reproduced by reading. Hence the trigger audit above and `/bgnits log`; retest on the current version.
- Second report the same evening, on the current version: with the bag closed, `/gxiv debug` (saved as `debugLog`)
  showed the d-pad, L1 and RT bound to `CLICK InputFunctionBindingButton_<key>` with no panel shown, and pulling a
  trigger stuck the UI and printed the message. Those buttons are Blizzard's panel navigation (`InputFunctionBinding`,
  priority overrides on `UIParent`: SmartNavigation's d-pad group, the manager's LT/RT group), so Blizzard's binding
  stack was left active after an unfocus. The way that happens: `SmartNavigation:OnHide` and `DeactivateBinding`
  (`Blizzard_GamepadSmartNavigation/SmartNavigation.lua`, `EnsureIsSecure`) do nothing when `issecure()` is false,
  and `InputBindingManager`'s `SetOverrideBinding*` calls are blocked in combat from tainted code. A panel unfocused
  or hidden under taint, in combat above all, leaves its groups behind, and GamepadXIV's non-priority bindings lose
  to them until a Blizzard panel is focused and unfocused again out of combat (open any window, close it with B or
  Escape), which runs the stack cleanly. The same error log has `ADDON_ACTION_BLOCKED` on `SetOverrideBindingClick`
  (29 times, in the chat-focus path: Back → `OPENCHAT` → `FloatingChatFrame:SetGamepadFocus` → `FrameShown`),
  blamed on GamepadXIV with `ChatFrame1.oldestFadingLineTimestamp (QuestieTrace)` as the tainted value, and
  `BuffFrame` errors "while execution tainted by 'GamepadXIV'". Nothing of ours is in those stacks, and this addon
  writes no Blizzard state: EventRegistry callbacks and `hooksecurefunc` hooks are isolated by `securecallfunction`,
  the hints are Show/Hide on Blizzard's own hint frames, the legend and its prompts are private objects, the
  bindings sit on an owner frame of our own. Chat is itself a managed panel (the edit box gaining focus calls
  `FrameShown` on the chat frame, losing it `FrameHidden`), so Back → chat with the bag open focuses a panel: our RT
  hint appears on the bag and RT unfocuses the chat, as with the stock bag. Under the previous commit Baganator 851
  also wrote a tainted `targetButton` into SmartNavigation's panel info for the bag (`SetTargetButtonForFrame`);
  with `FrameShown` blocked, `GetPanelInfo(frame, true)` finds no panel info and nothing is written. To settle the
  blame: reproduce once with this addon disabled; if it still happens it is GamepadXIV or Forever, and GamepadXIV's
  `/gxiv priority on` is its own remedy for losing to Forever's bindings.

## After a Baganator or Blizzard update

- Baganator: views still listed in `UISpecialFrames` under `Baganator_*BackpackViewFrame*`/`*BankViewFrame*`, still
  with a `CloseButton`; item buttons still answer `GetBagID()`/`GetID()` and have `OnEnter`/`OnLeave` scripts;
  `ViewComplete` still fired on `Baganator.CallbackRegistry`. These are all the navigation keys on.
- Blizzard: `TOGGLEUIFOCUS` still in `Blizzard_Gamepad/Bindings.xml`; `shownFrames`/`focusedFrame`/`isUIFocused`,
  `ERROR_NO_FRAME_TO_FOCUS` in `SetUIFocusState` and `Gamepad.RefreshFrameFocus` in `FrameControlsManager.lua`; `LeftJumpHint`/`FocusJumpHint` in `FocusEffects.lua`;
  `InputPromptLegends.CreateInputLegend` and `RefreshWithPromptedBindings` in `InputLegendPromptGroup.lua`.
- Blizzard: `itemMoreActions` entries in `ContainerFrame.lua` `SetupGamepad` (did the stock menu gain or lose
  entries?), `StaticPopup_IsAnyDialogShown` in `Blizzard_StaticPopup/StaticPopup.lua`, `GAMEPAD_DPAD_HORIZONTAL`
  in `GamepadConstants.lua`.
- Baganator: `grep -n "OnGamePad\|SetPropagateKeyboardInput\|BaganatorGamepadClicker\|print(" ItemViewCommon/GamepadTrap.lua`
  in the installed addon. If the trap frame gains a name or moves off `UIParent`, update `findTrapFrame`; if
  Baganator adds a setting to turn its capture off, or drops it, retire the disarm code.
- BaganatorGamepad is no longer a dependency. If a later version of it covers everything here, this addon can be
  retired; until then its updates do not matter, beyond the warning naming it (`OTHER_ADDON`).
- Then `make test`, update the version line at the top, `/reload`, test.

## Testing in game

- BaganatorGamepad disabled in the addon list (with it enabled, a red warning appears at login and on `/bgnits`).
  Controller UI on, open the bag: a gold border on the top-left item with its tooltip, the d-pad moves it (no
  wrapping at the edges), A picks an item up and places it on another slot, X uses a potion or equips gear, B
  closes. Bag + bank: LT/RT move between the windows and each remembers its last item.
- Controller UI on, Baganator bag open at a merchant. Press Blizzard's focus button or LT: the shop gets the cursor and
  its footer, the bag shows the RT glyph at its bottom centre, d-pad moves in the shop. RT: cursor leaves the shop, the
  bag's gold border is back, the shop shows the LT glyph, our legend appears under the bag. LT again returns to the shop.
- Legend: move over an equippable item (X reads "Equip"), a potion ("Use"), with the merchant open ("Sell"); pick an
  item up (A "Select" stays, B reads "Back"), B clears it.
- Bag + bank open: LT/RT still switch between the two Baganator windows; no LT glyph on a panel.
- Close the merchant while the bag is navigated: LT goes back to the window switch (`/bgnits`: `PreviousWindow`).
- Taint: `/console taintLog 2`, reproduce, then look for `BaganatorGamepadNits` in `Logs/taint.log`. Any "blocked from
  an action only available to the Blizzard UI" popup is a failure.
- `/bgnits` should report active true, navigated true with the bag navigated, and LT/RT bound to `TOGGLEUIFOCUS` in
  the right state.
- Y menu: navigate to a stack of 5+ potions, press Y: a dark menu appears right of the slot with Destroy (red) and
  Split Stack, a legend under it (A Select, B Back), the bag legend gone. Down/Up moves the highlight. A on Split
  Stack: the menu shows `<  1 / 4  >`; Right twice reads 3, Up clamps to 4, A: the menu closes, the split is on the
  cursor (B label reads Back), A on an empty slot places it. Y again, Destroy, A: Blizzard's confirmation popup
  appears and answers to the controller (the gold border is hidden while it is up); No restores the bag
  navigation. Y with an item held, or at a merchant, does nothing. Open chat (type nothing), close it with the
  chat box still focused, Y: Share in Chat is listed and A inserts the link. Hunters: Y on pet food lists Feed to Pet.
  `/bgnits` reports `menu false` and `PAD4` on `BaganatorGamepadNits_More` with the menu closed.
- With GamepadXIV loaded: bag open at a merchant, shop focused, RT, then d-pad in the bag, LT back to the shop, RT,
  B to close the bag, walk away. Holding L2/R2 shows the crossbar again as soon as the bag is closed; Back opens chat
  with nothing open and never shows "No interface frame to focus"; `/bgnits log` ends in `bound off` after the bag closes and
  GamepadXIV's `errorLog` names nothing of ours. Also Back → chat with the bag open (our RT hint on the bag, RT
  closes the chat focus), and the same cycle during combat. If the d-pad or triggers end up on
  `InputFunctionBindingButton_*` with nothing open (`/gxiv debug`), note whether it was in combat, then open and
  close any Blizzard window to unstick it, and read both saved logs.
- Baganator 847+: open the bag with the controller. Nothing is printed to chat (no `gpb PAD...`, no stick names),
  the d-pad moves the selection, the left stick still moves the character, and X with the merchant
  focused does not click the first bag slot. `/bgnits` reports `Baganator trap disarmed`.
