# Debugging handoff: BaganatorGamepadNits

Where things stand on 2026-11-13 and how to debug the next report. Background and mechanisms are in `CLAUDE.md`
("Other controller addons" and "Trigger audit"); this file is the procedure.

## Current state

- `main` at the commit that adds this file: trigger audit, `slotOf` nil-bag-ID fix, event log saved to disk.
  Nothing in it is confirmed in game yet (see the version line at the top of `CLAUDE.md`).
- Open problem: with GamepadXIV 0.1.13 loaded, after using the Baganator bag the gamepad UI twice ended up with
  Forever's panel-navigation bindings (`CLICK InputFunctionBindingButton_<key>`) left on the d-pad, L1 and RT with
  nothing open. Pulling a trigger then prints "No interface frame to focus" and the GamepadXIV crossbar is dead.
- The evidence so far (GamepadXIV's own error log) blames taint from GamepadXIV and QuestieTrace in the chat-focus
  path (Back → `OPENCHAT`), not this addon. Unresolved: whether the second failure happens with this addon disabled,
  and whether it was in or just after combat.

## Unstick without a reload

Out of combat, focus and unfocus any Blizzard window: open the map, character sheet or stock settings, then close it
with B or Escape. That runs Forever's binding stack cleanly and drops the stale overrides. `/reload` also works.

## When it breaks again, in this order

1. Do not reload yet. In chat, run and screenshot or copy:
   - `/bgnits` — one-line state: owner/active/suppressed, `wantLeft`/`rightBound`, UI focused, panel count and
     names, focused frame, popup/merchant/cursor, selected slot, and what Y, LT and RT are bound to right now.
   - `/bgnits log` — the last 60 events with wall-clock times: every LT/RT/Y set or clear, suppression changes with
     the manager's `isUIFocused`/panel count, BaganatorGamepad owner found/bound/cleared, menu open/close, combat
     enter/leave, merchant open/close, and any `ADDON_ACTION_BLOCKED`/`FORBIDDEN` naming this addon. A
     `stale PADLTRIGGER cleared` / `stale PADRTRIGGER cleared` line means the trigger audit fired; it should never.
   - `/gxiv debug` — GamepadXIV's view of the bindings (`GetBindingAction(key, true)` for the d-pad, L1, left stick,
     RT). `CLICK InputFunctionBindingButton_*` with no panel shown is the stuck state.
   - `/gxiv status` and `/gxiv log` — GamepadXIV's own state and its Back-cycle play log.
2. Note: were you in combat or just out of it? Was chat opened with Back while the bag was open? Was a merchant,
   bank or mail open? Did a Blizzard popup appear?
3. `/reload` (or log out). Everything above is now on disk; nothing needs to be copied from chat.
4. Read the saved variables (replace account, realm and character):
   `WTF/Account/<account>/<realm>/<character>/SavedVariables/`
   - `BaganatorGamepadNits.lua` — `BaganatorGamepadNitsDB.log` is this session's ring (order it by `logCount`:
     entry `i` is `log[(i - 1) % 60 + 1]` for `i` from `logCount - 59` to `logCount`); `previous`/`previousCount`
     are the session before, so one reload too many does not lose the report.
   - `GamepadXIV.lua` — `GamepadXIVDB.errorLog` (every Lua error from any addon, with stacks, via
     `seterrorhandler`; `ADDON_ACTION_BLOCKED` entries carry its taint scan naming the tainted field and addon),
     `debugLog` (the `/gxiv debug` snapshots), `playLog` (the `/gxiv log` lines).
   Grep for `BaganatorGamepadNits` in the error log. Any stack with our file in it is ours to fix; a stack with
   only Blizzard, GamepadXIV, Questie or Baganator frames is not.
5. For taint questions, `/console taintLog 2` before reproducing, then `Logs/taint.log` in the game folder; look
   for `BaganatorGamepadNits`. Any "blocked from an action only available to the Blizzard UI" popup is a failure
   of whichever addon the popup names.
6. To settle blame for the stuck-bindings problem: reproduce once with BaganatorGamepadNits disabled in the addon
   list. If it still happens it is GamepadXIV or Forever; `/gxiv priority on` is GamepadXIV's own remedy for losing
   to Forever's bindings. If it stops, send both saved logs from a session where it did happen.

## Reading the two logs together

- Our log and GamepadXIV's logs both use `date("%H:%M:%S")` wall-clock times; line them up by time.
- In our log, `suppressed true (focused ..., panels n)` followed by no `suppressed false` while a Blizzard panel
  closed means the manager's unfocus never reached us (or never happened). Pair it with GamepadXIV's
  `ADDON_ACTION_BLOCKED` entries at the same time: a blocked `SetOverrideBinding*` in `InputBindingManager` or a
  skipped `SmartNavigation:OnHide` is what leaves `InputFunctionBindingButton_*` behind.
- `LT -> TOGGLEUIFOCUS` or `RT -> TOGGLEUIFOCUS` in `/bgnits` with `panels 0` is our bug (the audit should have
  cleared it). `LT -> CLICK BaganatorGamepadPreviousWindow` with the bag closed is BaganatorGamepad's owner not
  cleared; `LT -> CLICK InputFunctionBindingButton_PADLTRIGGER` with `panels 0` is Forever's stack left active.

## Where the code is

- Log ring and saved variable: `note()`, `attachSavedLog()` near the top of `BaganatorGamepadNits/BaganatorGamepadNits.lua`.
- Trigger audit: `dropToggleFocus`, `leftFocusTarget`, the end of `applyState`, and the
  `SetOverrideBindingClick` hook.
- Event frame (combat, merchant, `ADDON_ACTION_*`): the `RegisterEvent` loop near the bottom; `/bgnits` is the
  last block in the file.
- Blizzard references (Forever 1.60.1 source, `Gethe/wow-ui-source` branch `forever`):
  `Blizzard_GamepadSharedUtility/FrameControlsManager.lua` (`SetUIFocusState`, `ERROR_NO_FRAME_TO_FOCUS`),
  `Blizzard_GamepadSharedUtility/InputBindingStack/InputBindingManager.lua`,
  `Blizzard_GamepadSmartNavigation/SmartNavigation.lua` (`EnsureIsSecure`, `OnHide`, `DeactivateBinding`).
- `make check` syntax-checks; `make install` symlinks into the AddOns folder; `/reload` picks up Lua changes, a
  toc change (new saved variable) needs a full client restart (the toc is read at launch; `/reload` and relog keep the old one). Until then the
  log is still printed by `/bgnits log` but not saved.
