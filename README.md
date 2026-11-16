# AH Upgrades

A WoW Forever addon that lists gear on the Auction House that is an **upgrade for you**, judged by your
PawnForever stat weights, and sorts it by **value: % upgrade per gold**.

It adds an **Upgrades** tab to the Auction House window, and `/ahu` opens the same list as a window anywhere.

## How it works

- **AH data.** When a full AH scan arrives (ForeverCraftAssistant's Scan button), AH Upgrades reads the same list
  and keeps every gear listing: the cheapest buyout per item, **random enchants ("of the Bear") included**. It never
  queries the AH itself.
- **No scan yet?** It falls back to the prices ForeverCraftAssistant saved: this realm's, or else the realm of your
  faction with the most prices (shown in the status line). Random-enchant items from that data are judged on their
  base item and marked "+ random".
- **Judging.** Every listing goes through PawnForever exactly like its green bag arrows: your weights, your worn
  gear, the weaker ring/trinket, weapons as a pair, and only what you can use now.

## Using the list

- **Spec buttons** (top right) switch between the two specs PawnForever tracks: your main scale, picked every time
  the list opens, and the second scale if you set one. Each is named in its bag-arrow colour.
- **Slot buttons** above the list show how many upgrades each slot has; click one to see only that slot.
- **Click a column header** to sort by it, click again to reverse. The Sort button cycles the common sorts.
- **Max gold** hides anything more expensive.
- **Click a row** to search the AH for it, **Shift-click** to link it in chat.

## Install

Needs **PawnForever**. ForeverCraftAssistant is optional but is what makes the full scan.

- **WowUp:** Get Addons, Install from URL, paste `https://github.com/padmanek/AHUpgrades`.
- **By hand:** download `AHUpgrades-vX.Y.Z.zip` from [Releases](https://github.com/padmanek/AHUpgrades/releases)
  and unzip it into `World of Warcraft\_forever_\Interface\AddOns`.

## Commands

| Command | What it does |
|---|---|
| `/ahu` | Toggles the list (the Upgrades tab at the AH, a window elsewhere) |
| `/ahu status` | How many gear listings this realm's last scan saved, and when |
| `/ahu debug` | Tab state and the last error |

## License

MIT
