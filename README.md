# AH Upgrades

A WoW Forever addon that lists gear on the Auction House that is an **upgrade for you**, judged by your
PawnForever stat weights, and sorts it by **value: % upgrade per gold**.

It adds an **Upgrades** tab to the Auction House window, and `/ahu` opens the same list as a window anywhere.

## How it works

- **AH data.** When a full AH scan arrives (ForeverCraftAssistant's Scan button), AH Upgrades reads the same list
  and keeps every gear listing: the cheapest buyout per item, and **per random enchant**: "of the Monkey" and "of the
  Bear" of the same item are two rows, each judged on its own stats.
- **Scan gear.** The list's own button searches the AH for just the weapons and armor you can use, up to your level:
  much quicker than a full scan, and it can run any time. The list fills as it goes: everything is in after the first
  part, then every item with a random enchant is looked up one by one so their real stats count (a few minutes when
  there are hundreds). Which items roll one is learned from the scans: on WoW Forever the browse search doesn't say,
  so a full scan first helps it find them all. Its result replaces the realm's saved listings, as a full scan does;
  stopped early, what it found so far is kept.
- **One slot.** With a slot picked above the list, the button reads "Scan head" (or that slot) and scans only that
  slot: its saved listings are replaced, every other slot's stay as they were.
- **Live prices.** While the Upgrades tab is open and no scan runs, the rows on screen are looked up again, one every
  couple of seconds ("Live" shows next to Scan gear): a new cheapest price is put in, and an item that is gone from the
  AH is taken off the list (only after two look-ups in a row miss it, so one odd answer can't empty the list).
- **No scan yet?** It falls back to the prices ForeverCraftAssistant saved: this realm's, or else the realm of your
  faction with the most prices (shown in the status line). Random-enchant items from that data are judged on their
  base item and marked "+ random".
- **Judging.** Every listing goes through PawnForever exactly like its green bag arrows: your weights, your worn
  gear, the weaker ring/trinket, weapons as a pair, and only what you can use now. When a PawnForever scale is linked
  to an Equipment Manager set, that spec's listings are judged against the set's pieces instead of what you wear.
- **Your bags and bank count too.** A listing must also beat the gear you own, such as a second set for your other
  spec. Each slot is compared with the best item you have, worn, in the bags or in the bank; rings and trinkets with
  the weaker of your best two; a one-hander in the bags only counts when it beats the two-hander you wield, and the
  other way round. Those rows say "over bags" or "over bank", and the status line counts the listings
  skipped as already owned. The bank can only be read while it is open, so each visit records its gear; until the
  first visit, Bagnon's cache of it is used if there is one.

## Using the list

- **Spec buttons** (top right) switch between the two specs PawnForever tracks: your main scale and the second scale
  if you set one, each named in its bag-arrow colour. Every visit to the AH starts on main; the spec you pick stays
  while you flip between Upgrades and Buy / Sell / Auctions.
- **Slot buttons** above the list show how many upgrades each slot has; click one to see only that slot.
- **Columns:** the item, its slot, its **Score** (PawnForever's, for the spec picked), the **Upgrade** over what you
  have ("-" when what you wear there is worth nothing by your weights), the price, and the value (% upgrade per gold).
- **Click a column header** to sort by it, click again to reverse. The Sort button cycles the common sorts.
- **Max gold** hides anything more expensive.
- **Click a row** to search the AH for it (the Buy tab's filters and category are cleared first, so every listing of
  it shows): its auction list opens with the cheapest one of that random enchant picked. The AH search itself only
  knows base names, so it shows the item without "of the Monkey". **Shift-click** to link it in chat.

## Install

Needs **PawnForever**. ForeverCraftAssistant is optional but is what makes the full scan.

- **WowUp:** Get Addons, Install from URL, paste `https://github.com/padmanek/AHUpgrades`.
- **By hand:** download `AHUpgrades-vX.Y.Z.zip` from [Releases](https://github.com/padmanek/AHUpgrades/releases)
  and unzip it into `World of Warcraft\_forever_\Interface\AddOns`.

## Commands

| Command | What it does |
|---|---|
| `/ahu` | Toggles the list (the Upgrades tab at the AH, a window elsewhere) |
| `/ahu status` | How many gear listings this realm's last scan saved, and the bank gear on record |
| `/ahu live` | Says in chat what each live price check does (again to stop); the last 400 are always kept in the saved variables |
| `/ahu debug` | Tab state and the last error |

## License

MIT
