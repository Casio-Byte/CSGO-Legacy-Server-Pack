# CS:GO Legacy Server Pack

A drag-and-drop pack that turns a **CS:GO Legacy (1.38.8.1) dedicated server on Windows** into a full community/match server. It includes:

- **Metamod and SourceMod**, preconfigured.
- **CS:GO Match**, a match system: ready-up, knife round, pauses, best-of-3 with map veto, every game mode, KZ/Bhop/Surf and all 1v1 modes.
- **CS:GO Loadout**, a skin system: skins, stickers, knives, gloves, agents, patches and default-weapon picks, saved per player.
- **Helpers**: a first-run setup wizard, a crash-restarting launcher, FastDL map downloads, a community map downloader, and the internet-play fixes from [FNScence/CSGO-Legacy-Server](https://github.com/FNScence/CSGO-Legacy-Server).

> CS:GO is no longer supported by Valve. This pack targets the `csgo_legacy` server build (app 740), 32-bit Windows `srcds.exe`.

---

## Contents

| Path | What it is |
|---|---|
| `csgo/` | The pack. Drag this folder onto your server folder (the one with `srcds.exe`). |
| `PACK_README.txt` | The in-pack manual (same content as `csgo/README_server_pack.txt`). |
| `plugin-src/` | Source code of the two custom plugins (`csgo_match.sp`, `csgo_loadout.sp`). |
| `LICENSE` | GPLv3. SourceMod plugins must be GPL-compatible. |

### Components

| Component | Version | Role |
|---|---|---|
| Metamod:Source | 1.12 (32-bit only) | Plugin loader. `metamod_x64.vdf` is left out on purpose because it breaks the 32-bit server. |
| SourceMod | 1.12.0.7259 | Plugin platform |
| Source Scramble | 0.7.1.4 | Memory access for weapon stickers. 0.8.x is too new for this server. |
| PTaH | 1.1.4 | Forces a full update so sticker changes show instantly |
| CS:GO SteamFix | from FNScence repo | Accepts CS:GO Legacy players whose Steam ticket check fails. Third-party closed source. |
| REST in Pawn | from FNScence repo | Needed by eItems |
| **csgo_match.smx** | custom | Match system and game modes (below) |
| **csgo_loadout.smx** | custom | Skins and loadouts (below) |
| nolobbyreservation.smx | from FNScence repo | Stops "lobby only" reservations that drop internet players right after connecting |
| eItems + eSprays | from FNScence repo | `!spray` graffiti. About 140 MB of spray images in `csgo/materials/decals/eitems`. |
| pugsetup, weapons, gloves | from FNScence repo | **Disabled** (`plugins/disabled`) because they clash with CS:GO Match and CS:GO Loadout |

---

## Install

1. Stop the server.
2. Drag `csgo/` onto the server folder (for example `C:\csgo-server\`) and choose **Replace**.
3. Run `csgo\start_server.bat`. The first run starts the **setup wizard** (see below).
4. In game, type `/login <admin password>` in chat to become admin.

Check it's running from the server console:

```
meta version        -> Metamod
sm version          -> SourceMod
sm exts list        -> Source Scramble, PTaH, CS:GO SteamFix, REST in Pawn
sm plugins list     -> CS:GO Match, CS:GO Loadout, eSprays, eItems, NoLobbyReservation
```

Updating an existing server: the pack ships a clean `cfg/server.cfg` and an empty `cfg/csgo_match/server_settings.cfg`, so the wizard runs again. Have your server name and passwords ready.

---

## Launcher and setup wizard: `start_server.bat`

The first run (or `start_server.bat setup`) asks for:

- server name, join password, RCON password (left empty, a random one is generated) and admin password (for `/login`)
- max players, tickrate, port and starting map
- **network**: `1` LAN / virtual LAN (Tailscale, ZeroTier) or `2` Internet (asks for a login token, App ID 730)
- the address players download maps from. In Internet mode your public IP is filled in automatically.
- auto-download community maps, run FastDL, auto-restart on crash

It writes three files, all ignored by git and private:

| File | Holds |
|---|---|
| `csgo/launcher_settings.cmd` | launch options and login token |
| `csgo/cfg/csgo_match/server_settings.cfg` | hostname, `sv_password`, `rcon_password`, `match_admin_password`, `sv_lan` |
| `csgo/cfg/csgo_match/fastdl.cfg` | `sv_downloadurl` |

The wizard **owns** those settings. If `server.cfg` or `autoexec.cfg` also sets any of them, the wizard comments those lines out. An old `sv_lan 1` there is what causes *"This game server restricts clients to connect from internal local area network only"*. In Internet mode it also adds a Windows Firewall rule for the game port.

On every start the launcher:
1. downloads missing community maps
2. starts FastDL minimized
3. runs `srcds.exe` and restarts it if it crashes
4. stops FastDL when the server stops

## Internet play

1. Run `start_server.bat setup`, choose **2**, enter a login token and check the public IP.
2. On your router, forward **UDP 27015** (game) and **TCP 27020** (FastDL). Don't forward TCP 27015, which is RCON.
3. "Server out of date" console warnings are expected.
4. SteamFix and NoLobbyReservation are already included. The console should show `[steamfix] engine patched!`.
5. Test from outside your network, for example a phone hotspot. Many routers can't connect to their own public IP (no NAT loopback).

SteamFix means SteamIDs aren't verified, so keep a join password and use `/login` for admin. The alternative with no patches is a virtual LAN (Tailscale or ZeroTier) in setup option 1.

## FastDL: `start_fastdl.bat`

CS:GO's built-in download is too slow for big maps, so the pack runs a small PowerShell HTTP server on **TCP 27020**:

- It only serves `maps`, `materials`, `models`, `sound`, `particles` and `resource`, and only map/content file types.
- Path traversal is blocked.
- The first run asks for admin once, to add the URL reservation and firewall rule.

## Uninstall: `uninstall_server_pack.bat`

This puts the server back to plain CS:GO. It removes:
- Metamod and SourceMod, including all plugins, extensions, player loadouts and logs
- the pack's cfgs
- `GameModes_Server.txt`
- the spray images
- the launcher scripts and their settings
- optionally, the firewall rules and port permission

Close the server before running it. It lists everything and asks first. By default it **moves** the files to `csgo/_server_pack_backup_<date>` so you can undo it; choosing delete removes them for good. Community maps are kept unless you choose otherwise. You can also choose to **keep `start_server.bat`** (with FastDL and the map downloader). The server then still starts the same way, with the same name, passwords and LAN/internet setting, but as plain CS:GO with no plugins; `server.cfg` is set to load your settings. The game, `steam.inf`, the map cycle files and the official maps are never touched.

## Community maps: `download_community_maps.bat`

This downloads the KZ, Bhop, Surf, arena and Aim Botz maps listed in each mode's `downloads.txt`, from varq.net or straight from the Steam Workshop (`workshop:<id>` entries). It unpacks them, using 7-Zip if installed, puts them in the mode's folder and skips maps you already have.

---

## CS:GO Match (`csgo_match.smx`)

Commands work with `!` (`!ready`), `.` (`.ready`) or `sm_<command>` from the console.

### Game modes: `!gamemode` (admins)
Pick a mode, then a map. The server switches 5 seconds later, and the mode survives map changes.

| Mode | Notes |
|---|---|
| Competitive 5v5 | ready-up match flow, optional **best of 3** |
| Wingman 2v2 | ready-up, `wingman.cfg` |
| Casual / Deathmatch / Arms Race / Demolition | the game's own rules |
| Practice | grenade trajectories, infinite ammo, `!spawn` `!clear` `!god` |
| KZ / Bhop / Surf | movement physics per mode, checkpoints, speedometer |
| 1v1 match | ready-up 1v1, one player per side |
| Multi-1v1 arenas | arena ladder on `am_` / `1v1_` maps |
| Aim Botz (solo training) | `training_aim_csgo2`: the map's buttons control the bots. Infinite ammo, buy anywhere, no round end. `!aimbotz` jumps straight to it. |

Each mode has a map folder, `csgo/maps/modes/<mode>/`, with a `maplist.txt` of standard maps. `!map` lists every map on the server (A-Z, per mode folder, workshop) and replaces SourceMod's `!map`.

### Match flow
Warmup → `!ready` → (map vote if best of 3) → knife round → winners `!stay` / `!switch` / `!t` / `!ct` → **LIVE**

| Players | Admins |
|---|---|
| `!ready` `!unready` | `!start` `!forceready` `!restart` |
| `!pause` `!tech` `!unpause` `!tac` | `!fup` (force unpause) |
| `!stop` (both teams: replay the round) | `!restore <n>` (round backup) |
| `!status` `!help` | `!team1 <name>` `!team2 <name>` `!readyrequired <n>` |
| | `!knifetoggle` `!prac` `!exitprac` |

Also included: SourceTV demo recording per match and round backups.

### Best of 3 with map veto
- Turn it on with `!bo3` or `!options` → "5v5 series". `!bo1` turns it off.
- After everyone is ready, CT and T become **Team A** and **Team B**. Each team votes in a menu on its turn: **ban, ban, pick, pick**, then bans down to the **decider**. The map pool is the first 7 installed maps in `maps/modes/competitive/maplist.txt`.
- Most votes wins. A tie or no votes picks at random. The vote time is set in `!options` (default 25 s).
- The next map loads automatically 20 s after each map. The first team to win 2 maps wins.
- Teams are kept together across maps and reconnects, and new players joining a side join that team.
- `!series` shows the maps, who picked them and the score. `!endseries` (admin) cancels the series.

### `!options` (admins, saved)
- series (single map or best of 3) and vote time
- knife round
- players needed to start
- match length (MR15, MR12, 16 rounds)
- overtime and friendly fire
- tactical pauses per team
- whether both teams must unpause
- `!stop` on/off
- demo recording
- side-pick time

### Aim Botz: solo aim training
- `!aimbotz` (`!aim`, `!training`) or `!gamemode` → **Aim Botz (solo training)**. It opens the map picker for `maps/modes/aimbotz/`.
- The map's own buttons add bots and set them up. The mode adds infinite ammo, buy anywhere, $60k, instant respawn and no round end.
- It sets `sv_allow_point_servercommand always` so the map's buttons can run bot commands on a dedicated server. That setting is reverted when you switch mode.
- Settings: `cfg/csgo_match/aimbotz.cfg`.
- Map: `download_community_maps.bat` downloads it straight from the Steam Workshop (id 243702660) through Steam's public file API. If that fails, copy `csgo/maps/workshop/243702660/training_aim_csgo2.bsp` from a CS:GO Legacy client subscribed to the Workshop map.

### KZ / Bhop / Surf
`!r` `!cp` `!tp` `!pcp` `!ncp` `!speed` `!hide` `!noclip`. Instant respawn, no collisions or player damage. These modes have no run timers.

**Surf auto-restart:** falling off sends you back to the start, like `!r`. Once you finish a stage, a fall takes you back to the start of the last stage you reached; "Stage N reached" shows each time you get to a new one. The plugin works out stages from the map's own teleports: landing somewhere new counts as the next stage, landing somewhere you've been counts as a fall. Spawns and `!r` also clear the stage markers maps put on players, so a fresh start really is the start. Turn it off with `match_surf_auto_restart 0`.

### 1v1
- `!1v1` opens a menu with every 1v1 mode.
- **Aim duel**: `!duel [name]`, pick a weapon and kills to win, then `!accept` / `!decline` / `!forfeit`.
- **Arenas**: `!guns` `!sitout` `!rank`.

### Admin
- `/login <password>` gives full admin and remembers that PC. `/logout` undoes it.
- Three wrong passwords lock that player out for 1 minute.
- `admins.cfg` SteamID entries also work, but only when SteamIDs can be verified.

### Cross-plugin flags
- `match_competitive_active` blocks third person during matches.
- `match_duel_active` stops loadout weapon swaps during duels.

---

## CS:GO Loadout (`csgo_loadout.smx`)

| Command | |
|---|---|
| `!ws` `!loadout` `!skins` | main menu |
| `!presets` `!sets` | **preset loadouts**: equip a full high-tier set in one click. Each has a knife, gloves and skins with colour-matched sticker crafts (see below). |
| `!knife` `!gloves` `!agents` `!patches` (3 slots) `!stickers` | |
| `!slots` | default weapons: USP-S/P2000, M4A1-S/M4A4, CZ75 vs Five-SeveN/Tec-9, R8/Deagle, MP5-SD/MP7. New players are asked on first spawn. |
| `!3rd` | third person to view your agent (blocked in live matches) |
| `!gen <weapon> <skin> [pattern] [wear] [sticker wear...]` | gen-code |

**Preset sets** (`addons/sourcemod/configs/csgo_loadout_presets.cfg`, editable). The first sticker craft goes on rifles and the AWP, the second on pistols:

| Set | Knife | Gloves | Highlights | Sticker crafts |
|---|---|---|---|---|
| Ruby Inferno | Karambit Doppler (Ruby) | Driver Crimson Weave | AK Bloodsport, M4A4 Howl, AWP Wildfire | 4x Howling Dawn / 4x Seeing Red (Foil) |
| Sapphire Frost | Butterfly Doppler (Sapphire) | Sport Superconductor | AK Vulcan, M4A1-S Icarus Fell, USP Orion | 4x Blue Snowflake (Foil) / 4x Snowfall (Glitter) |
| Emerald Toxin | Bayonet Gamma Doppler (Emerald) | Hydra Emerald | AK Fire Serpent, AWP Containment Breach, Glock Emerald | 4x Toxic (Foil) / 4x Toxic Flow (Holo) |
| Golden Lore | M9 Bayonet Lore | Sport Bronze Morph | AWP Dragon Lore, AK Gold Arabesque, Deagle Golden Koi | 4x Crown (Foil) / 4x Gold Web (Foil) |
| Candy Fade | Skeleton Fade | Specialist Fade | AWP Fade, Glock Fade, AK Neon Revolution | 4x Cotton Candy Flow (Holo) / 4x Unicorn (Holo) |
| Printstream | Talon Doppler (Black Pearl) | Driver Snow Leopard | M4A1-S, USP-S and Deagle Printstream, Neo-Noir | 4x Infinite Diamond (Holo) / 4x Snowfall (Glitter) |
| Neon Dream | Stiletto Doppler (Phase 2) | Sport Vice | AWP Fever Dream, AK Neon Rider, M4A4 Cyber Security | 4x Ultraviolet Poison Frog (Foil) / 4x Doppler Poison Frog (Foil) |
| Blue Gem | Karambit Case Hardened #387 | Hydra Case Hardened | AK Case Hardened #661, Five-SeveN CH #278 | 4x Blue Gem (Glitter) / 4x All-Stars Blue (Holo) |
| Asiimov Orange | Huntsman Tiger Tooth | Hand Wraps CAUTION! | AK, M4A4 and AWP Asiimov, M4A1-S Chantico's Fire | 4x Phoenix Reborn (Foil) / 4x All-Stars Orange (Holo) |

Each set skins **all 34 guns** (pistols, SMGs, rifles, snipers, shotguns and machine guns) in the set's colours. The table shows the headline skins. Equipping a set keeps your StatTrak and name tags, and the menu shows every item before you equip.

- Skins, wear, pattern, StatTrak, name tag and **stickers** (with wear) on any weapon or knife.
- **Doppler / Gamma Doppler phases** are named: Ruby, Sapphire, Black Pearl, Phase 1-4 and Emerald.
- The full loadout is applied as soon as it loads, even mid-round after a map change.
- Saved per player in `addons/sourcemod/data/csgo_loadout/<STEAM_0_x_y or ip_x_x_x_x>.cfg`.
- Item data is read from the server's `items_game.txt`. Names come from `csgo_english.txt` (copy it from the game's `csgo/resource` folder for proper names).
- `core.cfg` needs `FollowCSGOServerGuidelines "no"` and `SteamAuthstringValidation "no"` (both preset).

---

## Building the plugins

The plugins use SourcePawn 1.11+ and the SourceMod 1.12 includes:

```
spcomp csgo_match.sp   -o csgo_match.smx
spcomp csgo_loadout.sp -o csgo_loadout.smx
```

Compiled `.smx` files are already in `csgo/addons/sourcemod/plugins/`.

## Credits

- SourceMod, Metamod:Source (AlliedModders), Source Scramble (nosoop) and PTaH (komashchenko).
- Skin and glove handling follows kgns' *Weapons & Knives* and *Gloves*. The sticker method and gamedata come from quasemago's *CS:GO Weapon Stickers* (GPLv3).
- [FNScence/CSGO-Legacy-Server](https://github.com/FNScence/CSGO-Legacy-Server): SteamFix (by E0n3x), NoLobbyReservation, eItems/eSprays, pugsetup, ESL configs.
- Community maps: varq.net.
