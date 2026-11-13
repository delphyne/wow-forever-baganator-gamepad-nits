# BaganatorGamepadNits

Controller navigation for [Baganator](https://www.curseforge.com/wow/addons/baganator) bag and bank windows on
**World of Warcraft: Forever**, for players using the game's built-in controller UI.

Baganator replaces the stock bags, but the stock bags are the ones the controller UI knows how to drive. This addon
makes a Baganator window behave like the stock bag does on a controller:

- **Move around the bag with the d-pad.** A gold border marks the selected item and its tooltip is shown.
- **Pick up, use, equip, sell and close** with the face buttons.
- **Page between the bag and a Blizzard window** (a merchant, mainly) with the triggers, with the same trigger
  glyphs the stock bag shows.
- **A button legend** under the bag that says what each button does right now.
- **A "More Actions" menu** on Y: Destroy, Split Stack, Share in Chat, Feed to Pet.
- **Stops Baganator's own controller handling** from swallowing your buttons while a bag is open.

It works while a Baganator bag or bank window is open and you are out of combat. In combat every button goes back
to what it normally does.

> **Status:** version 0.3.0 has been tested against a simulated game API but not yet confirmed in game.

## Requirements

- World of Warcraft: Forever with the controller UI switched on.
- [Baganator](https://www.curseforge.com/wow/addons/baganator).
- **Do not enable the BaganatorGamepad addon alongside this one.** This addon began as fixes for it (hence the
  name) and now replaces it; the two fight over the same buttons. A red warning appears in chat if both are on.

## Installing

Copy the `BaganatorGamepadNits` folder into your `Interface/AddOns` folder and restart the game.

From a checkout of this repository, `make install` links the folder into the AddOns folder it finds
(`make where` shows which one; pass `WOW_ADDONS=/path/to/Interface/AddOns` if it finds the wrong one or none).

## Buttons

This document uses the Xbox names: A is the bottom face button, B the right, X the left, Y the top; LT and RT are
the triggers. In game nothing is tied to those names. The addon works by button position, and the legend and
trigger glyphs it shows are the game's own, so they follow whatever controller the game has detected: on a
PlayStation pad you see Cross/Circle/Square/Triangle and L2/R2, on a Switch pad its letters.

If you would rather see a different set of labels than the game picks for your controller (Xbox letters on a
Switch-style pad, say), [PadLabels](https://github.com/delphyne/wow-forever-pad-labels) changes the glyphs without
changing what any button does.

### In the bag

| Button | What it does |
| --- | --- |
| D-pad | Moves the gold border to the nearest item in that direction. It stops at the edge of the window. |
| A | Picks up the selected item. With an item already held, places it on the selected slot (swapping if the slot is full). |
| X | Uses the selected item, or equips it if it is gear. With a merchant open, sells it. |
| Y | Opens the More Actions menu for the selected item. Does nothing while you hold an item or a merchant is open. |
| B | Closes the bag (and the bank). With an item held, puts it back instead. |
| LT | With a Blizzard window open next to the bag (a merchant, say): moves the controller to that window. With the bag and bank both open: switches to the other one. |
| RT | With the bag and bank both open: switches to the other one. |

When LT will take you to a Blizzard window, that window shows the LT glyph at its bottom edge.

### In a Blizzard window, with the bag open

Once the controller is on the merchant (or any other Blizzard window), every button belongs to that window, exactly
as without this addon. The one addition:

| Button | What it does |
| --- | --- |
| RT | Returns to the bag. The bag shows the RT glyph at its bottom edge while this is available. |

If more Blizzard windows are open to the right of the focused one, RT goes to the next of those first, as usual.

### More Actions menu (Y)

The menu lists only what applies to the selected item.

| Entry | When it is listed | What it does |
| --- | --- | --- |
| Feed to Pet | Hunters, on food the pet can eat | Feeds the item to your pet. |
| Destroy | Always (unless the item is locked) | Asks for the game's usual confirmation, then destroys the item. |
| Share in Chat | While a chat input box is open | Inserts a link to the item into what you are typing. |
| Split Stack | Stacks of 2 or more | Lets you choose an amount to split off. |

| Button | What it does |
| --- | --- |
| D-pad up / down | Moves the highlight between entries. |
| A | Runs the highlighted entry. |
| B or Y | Closes the menu. |
| LT / RT | Same as in the bag; the menu closes. |

### Split Stack

| Button | What it does |
| --- | --- |
| D-pad left / right | One fewer / one more. |
| D-pad up / down | Ten more / ten fewer. |
| A | Splits off that many. They end up held on the cursor; move to an empty slot and press A to place them. |
| B or Y | Cancels. |

### Confirmation popups

While one of the game's popups is up (the Destroy confirmation, for example), this addon lets go of every button so
the popup can be answered with the controller as usual. The bag navigation returns when the popup closes.

## Commands

| Command | What it does |
| --- | --- |
| `/bgnits` | Prints the addon's current state and what the buttons are bound to. |
| `/bgnits log` | Prints the last 60 things the addon did, with times. Useful in a bug report. |

## Troubleshooting

- **The d-pad does nothing in the bag, or two borders fight.** Check that BaganatorGamepad is disabled.
- **Nothing happens in combat.** That is intended; the game does not allow button bindings to change during combat,
  so the addon gives the buttons back when a fight starts and takes them again afterwards.
- **Something else is wrong.** Run `/bgnits` and `/bgnits log` before reloading and include the output in your
  report. [`HANDOFF.md`](HANDOFF.md) has the full procedure.
