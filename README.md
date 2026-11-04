# CS:GO Legacy Server Pack

A drag-and-drop pack that turns a **CS:GO Legacy (1.38.8.1) dedicated server on Windows** into a full community/match server. It includes:

- **Metamod and SourceMod**, preconfigured.
- **CS:GO Match**, a match system: ready-up, knife round, pauses, best-of-3 with map veto, every game mode and all 1v1 modes.
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
| PTaH | 1.1.4 | Forces a full update so sticker changes show instantly, and gives the chosen knife directly when the game hands out a default knife |
| CS:GO SteamFix | from FNScence repo | Accepts CS:GO Legacy players whose Steam ticket check fails. Third-party closed source. |
| REST in Pawn | from FNScence repo | Needed by eItems |
| **csgo_match.smx** | custom | Match system and game modes (below) |
| **csgo_loadout.smx** | custom | Skins and loadouts (below) |
| nolobbyreservation.smx | from FNScence repo | Stops "lobby only" reservations that drop internet players right after connecting |
| eItems + eSprays | from FNScence repo | `!spray` graffiti. About 140 MB of spray images in `csgo/materials/decals/eitems`. |
| retakes + retakes_standardallocator | 0.3.4 (splewis) | Retakes mode with `!guns` loadouts. Only runs while Retakes mode is on. |
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
- max players, tickrate and port
- **default game mode** (a numbered menu of all 10 modes) and the **first map** (a menu of that mode's maps marked installed / downloads on start, or type a name; maps that don't suit the mode are refused)
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

This downloads the arena maps listed in each mode's `downloads.txt`, from varq.net or straight from the Steam Workshop (`workshop:<id>` entries). It unpacks them, using 7-Zip if installed, puts them in the mode's folder and skips maps you already have.

---

## CS:GO Match (`csgo_match.smx`)

Commands work with `!` (`!ready`), `.` (`.ready`) or `sm_<command>` from the console.

Commands only work in the modes they belong to; anywhere else they say so. `!help` lists just the commands for the current mode.

| Commands | Work in |
|---|---|
| `!ready` `!pause` `!stop`, side pick, `!start` `!restart` etc. | Competitive 5v5, Wingman 2v2 (and Practice) |
| `!bo3` `!bo1` `!series` `!endseries` | Competitive 5v5 |
| `!duel` `!accept` `!decline` `!forfeit` | 1v1 duels, Multi-1v1 arenas |
| `!guns` `!sitout` `!rank` | Multi-1v1 arenas (`!guns` is also the Retakes loadout menu) |
| `!rtv` `!unrtv` `!rtg` `!unrtg` | every mode, except during a live 5v5 / wingman match or a best of 3 |
| skins, `!gamemode`, `!1v1`, `!map`, `!options`, `!help`, `!status` | everywhere |

### Game modes: `!gamemode` (admins)
Pick a mode, then a map. The server switches 5 seconds later, and the mode survives map changes.

| Mode | Notes |
|---|---|
| Competitive 5v5 | ready-up match flow, optional **best of 3** |
| Wingman 2v2 | ready-up, `wingman.cfg` |
| Casual / Arms Race / Demolition | the game's own rules |
| Deathmatch | **free-for-all**, built on Casual (instant respawn, 2 s spawn protection, one endless round; the game's own DM mode left bots standing still), no bonus weapons; everyone, bots included, can only hold knife, AK-47 and Deagle (other guns are refused or removed), no buy menu (`match_dm_loadout`); bots on Expert |
| Practice | grenade trajectories, infinite ammo, `!spawn` `!clear` `!god` |
| 1v1 duels | a lobby on Workshop aim maps: one endless respawn round (no warmup) where everyone can `!duel` each other. No ready-up or match commands. |
| Multi-1v1 arenas | many 1v1s at once on one `am_` map. Players are shuffled into new pairs every round (or a ladder). `!duel` pairs get their own arena. |
| Retakes | bomb planted on a random site every round, CTs retake it. Standard retakes allocator: `!guns` picks the CT rifle (M4A4 / M4A1-S / AUG), the T rifle (AK-47 / SG 553) and whether you want the AWP (one per team). Every round is a full buy with armour, a random grenade and kits; `!loadout` pistol picks and skins still apply. Spawns included for 24 maps; admins add more with `!edit`. No warmup. |

**No warmup in any mode.** 5v5 / wingman before `!ready` and the 1v1 lobby use a normal endless round with respawns instead (no WARMUP timer); every other mode starts straight away.

In every mode there's no team-select screen after a map loads: players are put on the smaller team automatically, and **M** still opens the menu to switch (`match_skip_team_menu 0` to turn this off).

**Maps only go with the modes they're made for:**
- `am_` maps: Multi-1v1 arenas
- `aim_`, `awp_` and `1v1_` maps: 1v1 duels
- `ar_` maps: Arms Race
- normal maps (`de_`, `cs_`, `gd_` …): Competitive, Wingman, Casual, Deathmatch, Demolition and Practice
- Retakes: bomb maps that have retakes spawns (`addons/sourcemod/configs/retakes/<map>.cfg`)
- `kz_`, `bhop_` and `surf_` maps: no mode

A map in a mode's own folder always counts for that mode. The map menus only list maps that fit, and `!map` on a map that doesn't suit the current mode asks which fitting mode to switch to.

Each mode has a map folder, `csgo/maps/modes/<mode>/`, with a `maplist.txt` of standard maps. The game only loads maps reliably from `csgo/maps` itself, so `start_server.bat` copies mode-folder maps there before each start (never overwriting existing maps; listed in `maps/modes/copied_to_maps.txt`, removed by the uninstaller), and the plugin copies a newly added one when it's picked. `!map` lists every map on the server (A-Z, per mode folder, workshop) and replaces SourceMod's `!map`.

### Rock the vote: `!rtv`
Type `!rtv` (or just `rtv`). When 60% of players have (`match_rtv_ratio`), everyone votes between up to 6 maps of the current mode and "Stay"; the winner loads in the same mode. Works in every mode, but **never during a live 5v5 or wingman match** (knife round and side pick included) or a best of 3. Before `!ready` is fine. Opens 30 s after a map loads; after a "stay" result the next vote can start 3 minutes later. `match_rtv_enabled 0` turns it off.

### Rock the gamemode: `!rtg`
Type `!rtg` (or `rock the gamemode`). Same 60% and same rules as `!rtv`. Two votes follow: first the game mode (every other mode that has a map to play, up to 8, plus "Stay"), then the map, **only maps made for the winning mode** (plus "Keep <current map>" if it suits). The server then switches like `!gamemode` does.

### Match flow
Waiting round (no warmup: respawns, no bomb, never ends) → `!ready` → (map vote if best of 3) → knife round → winners `!stay` / `!switch` / `!t` / `!ct` → **LIVE**

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
- arena pairing (shuffle every round, or ladder)
- players needed to start
- match length (MR15, MR12, 16 rounds)
- overtime and friendly fire
- tactical pauses per team
- whether both teams must unpause
- `!stop` on/off
- demo recording
- side-pick time

### 1v1
- `!1v1` opens a menu with every 1v1 mode.
- **Duel**: `!duel`, also in the `!1v1` menu. You set it up in four steps:
  1. **opponent**: a list of everyone on the server
  2. **gun**: AK, M4A4, M4A1-S, AWP, SSG, Deagle, USP-S, Glock, P250, random each round, or knives
  3. **rounds**: first to 30, 50 or 100 kills
  4. **headshots only**, or normal

  The challenge is then sent. `!duel <name>` skips step 1. Your opponent answers with `!accept` / `!decline`, and either player can `!forfeit`. In headshots-only duels, hits anywhere but the head do no damage.
- **Arenas**: `!guns` `!sitout` `!rank`.
  - Every arena on the map runs its own 1v1 each round.
  - Players are **shuffled** into new random pairs every round. `!options` → "Arena pairing" switches to a ladder instead (win to move up).
  - `!duel` works in arena mode: the two duelists get their own arena each round with their gun, rounds and headshots-only settings until someone wins or forfeits. Everyone else keeps shuffling, and up to 8 duels can run at once.
- **Maps** (all downloaded straight from the Steam Workshop by `download_community_maps.bat`):
  - 1v1 duels: aim_redline, aim_map, aim_map_pro, awp_lego_2, aim_pillars, awp_india_csgo, aim_biove_texture, aim_crashz_dust_1on1, aim_map_usp_s, aim_dust_go
  - Arenas: am_must2, am_dust2, am_texture2, am_aztec2, am_grass2, am_warehouse2, am_water, am_trainyard, am_skybound, am_crashz_dust, am_inferno_banana_dolnma

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

**Preset sets** (`addons/sourcemod/configs/csgo_loadout_presets.cfg`, editable). The first sticker craft goes on rifles, SMGs, heavies and snipers, the second on pistols:

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

`csgo_loadout.sp` needs `PTaH.inc` (in `csgo/addons/sourcemod/scripting/include/`). Add it with `-i csgo/addons/sourcemod/scripting/include`.

Compiled `.smx` files are already in `csgo/addons/sourcemod/plugins/`.

## Credits

- SourceMod, Metamod:Source (AlliedModders), Source Scramble (nosoop) and PTaH (komashchenko).
- Skin and glove handling follows kgns' *Weapons & Knives* and *Gloves*. The sticker method and gamedata come from quasemago's *CS:GO Weapon Stickers* (GPLv3).
- [FNScence/CSGO-Legacy-Server](https://github.com/FNScence/CSGO-Legacy-Server): SteamFix (by E0n3x), NoLobbyReservation, eItems/eSprays, pugsetup, ESL configs.
- Retakes: [splewis/csgo-retakes](https://github.com/splewis/csgo-retakes) 0.3.4 with the standard allocator (GPLv3). Source in `csgo/addons/sourcemod/scripting/retakes_source/`. It's patched to start switched off (the match plugin turns it on in Retakes mode).
- Community maps: varq.net.
