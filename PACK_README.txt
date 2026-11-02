Casio CS:GO Server Pack (full install)
======================================

Everything a CS:GO server needs, ready to drop in:

  Metamod:Source 1.12     plugin loader
  SourceMod 1.12          plugin platform
  Source Scramble 0.7.1.4 extension used for weapon stickers
  PTaH 1.1.4              extension that redraws stickers as soon as they change

  csgo_match.smx          Match system: ready-up, knife round, side pick,
                          pauses, round restore, demo recording, practice
                          mode, game modes, KZ/Bhop/Surf, all 1v1 modes.
  csgo_loadout.smx        Skins, stickers, knives, gloves, agents, patches
                          and default weapon choices (USP-S, M4A1-S, CZ75...),
                          saved per player.


INSTALL (drag and drop)
-----------------------
1. Stop the server if it's running.

2. Open this zip and drag the "csgo" folder onto your server folder - the
   folder that contains srcds.exe (e.g. C:\csgo-server - Live\).
   When Windows asks, choose "Replace the files in the destination".
   Everything lands in the right place:
       csgo\addons\...                  Metamod, SourceMod, plugins, extensions
       csgo\cfg\...                     SourceMod settings
       csgo\maps\modes\...              a map folder per game mode
       csgo\start_server.bat            the launcher - use this to start
       csgo\start_fastdl.bat            fast map downloads for players
       csgo\download_community_maps.bat KZ/Bhop/Surf/arena map downloader

   Updating a server you already set up? This pack replaces cfg\server.cfg
   with clean defaults and resets cfg\csgo_match\server_settings.cfg, so
   start_server.bat runs its setup again on the next start - have your
   server name and passwords ready. addons\sourcemod\configs\admins.cfg
   in this pack is empty. If you added admins there, keep your own copy when
   Windows asks (or just use the admin password from step 3 instead).
   If an old addons\metamod_x64.vdf is on your server, delete it.

3. Double-click csgo\start_server.bat. The first time it asks a few
   questions and saves the answers:
       server name, join password, RCON password, admin password,
       max players, tickrate, port, starting map,
       LAN / virtual LAN or internet (+ login token for internet),
       the address players download maps from (your public IP for
       internet - it's filled in for you), auto-download maps, FastDL,
       auto-restart
   Press Enter to keep the value in [brackets] - it picks up your current
   values. The setup owns these settings: if server.cfg or autoexec.cfg
   also sets the name, a password, sv_lan or the download address, it
   comments those lines out so they can't override your answers (an old
   "sv_lan 1" in server.cfg is what makes internet players get "restricts
   clients to internal local area network only"). After that, start_server.bat just starts everything:
   downloads missing maps, starts FastDL, starts the server and restarts it
   if it crashes. FastDL asks for admin rights once, the very first time.
   Change your answers later with:  start_server.bat setup

4. In game: /login <admin password> in chat to become admin.

Check it's all running (type in the server window):
    meta version          Metamod is running
    sm version            SourceMod is running
    sm exts list          Source Scramble, PTaH, CS:GO SteamFix and REST in Pawn
    sm plugins list       CS:GO Match, CS:GO Loadout, eSprays, eItems and
                          NoLobbyReservation listed

Optional:
  - Copy csgo_english.txt from your game's csgo\resource folder into the
    server's csgo\resource folder for proper skin/sticker names.
  - Internet: see "INTERNET" below.

Already set up in this pack (no need to do these yourself):
  - core.cfg has "FollowCSGOServerGuidelines" "no" (needed for knives/skins).
  - core.cfg has "SteamAuthstringValidation" "no", so players aren't left
    waiting for Steam to confirm them (it never does in LAN mode) - without
    this, loadouts and admin don't load.
  - Only the 32-bit Metamod loader (addons\metamod.vdf) is included - CS:GO's
    server is 32-bit.
  - admins.cfg is empty, so the pack is safe to share.
  - cfg\server.cfg has general defaults only (rates, downloads, GOTV for
    demos, logging). cfg\csgo_match\server_settings.cfg and fastdl.cfg
    are empty until the setup fills them in.

Files the launcher creates (keep them private - they hold your passwords):
  csgo\launcher_settings.cmd               launch options + login token
  csgo\cfg\csgo_match\server_settings.cfg  name, passwords, LAN/internet
                                           (loaded by the match plugin
                                           every map, after server.cfg)
  csgo\cfg\csgo_match\fastdl.cfg          map download address


INTERNET
--------
CS:GO is no longer supported by Valve, so internet play takes a few steps.
A virtual LAN (Tailscale, ZeroTier) avoids all of them: pick LAN in the
setup and friends connect to your virtual-LAN IP.

  1. start_server.bat setup -> choose 2 (Internet), enter a login token
     (steamcommunity.com/dev/managegameservers, App ID 730) and check the
     public IP it found. It adds a Windows Firewall rule for the game port
     (asks for admin).
  2. On your router forward UDP 27015 (game) and TCP 27020 (map downloads)
     to the server PC. Don't forward TCP 27015 (RCON).
  3. "Server out of date" warnings in the console are expected - ignore.
  4. Steam's ticket check refuses CS:GO Legacy players, so this pack
     includes the CS:GO SteamFix extension (by E0n3x, from the
     FNScence/CSGO-Legacy-Server GitHub repo, commit 6d85b52):
       addons\sourcemod\extensions\csgo_steamfix.ext.dll  (+ .autoload)
       sha256 17c5d14ae141d20b25b8931983f98647bae6ccdf527698101c3e217b0ef071d2
     It loads by itself and patches the server in memory to accept players
     whose Steam ticket check fails. The console shows
     "[steamfix] engine patched!" and "sm exts list" lists CS:GO SteamFix.
     It's a third-party closed-source DLL - delete both files if you don't
     want it (LAN mode doesn't need it). Because SteamIDs aren't verified
     with it, keep a join password and use /login for admin.
  5. Test from outside your network (e.g. a phone hotspot): connecting to
     your own public IP from inside your home network often fails because
     many routers don't support that ("NAT loopback").


FROM THE CS:GO LEGACY SERVER REPO (FNScence/CSGO-Legacy-Server)
---------------------------------------------------------------
Everything from that repo is in this pack. Where it overlapped with this
pack's own plugins, this pack's version is kept (SourceMod 1.12 core,
Metamod, core.cfg, admins.cfg, server.cfg) so nothing that already works
changes. Added and switched on:
  nolobbyreservation.smx  stops the server only accepting players from a
                          game lobby - without it players can be dropped
                          straight after connecting over the internet
  csgo_steamfix           Steam ticket fix for CS:GO Legacy players (see
                          INTERNET)
  eSprays + eItems        !spray - graffiti sprays. The spray images are in
                          csgo\materials\decals\eitems (about 140 MB);
                          players download them on joining, via FastDL.
                          Turn that off with "DownloadSprays": false in
                          addons\sourcemod\configs\eItems.json.
                          Settings: cfg\sourcemod\eSprays.cfg
  REST in Pawn extension  needed by eItems
  steam.inf, GameModes_Server.txt, mapcycle.txt, maplist.txt
  cfg\esl*.cfg, solo.cfg, setup.cfg   ESL rule configs and a solo/test
                          config (run with "exec solo" etc.)
  Its useful server settings (GOTV delay, no autokick, alltalk at
  warmup/half) are in cfg\server.cfg.

Included but switched OFF (in addons\sourcemod\plugins\disabled),
because they clash with this pack's own plugins:
  pugsetup + addons       same job as CS:GO Match (!ready etc.)
  weapons.smx, gloves.smx same job as CS:GO Loadout (!ws, !knife, !gloves)
  To use one instead, move it up into the plugins folder and move this
  pack's matching plugin (csgo_match.smx / csgo_loadout.smx) into
  disabled - never run both.

Not included: the repo's maps and graffiti package is a Google Drive
download, not part of the repo - get it from the link in the repo's README
if you want those maps. Its start.bat is replaced by start_server.bat.

MAP FOLDERS
-----------
Every game mode has its own map folder. Put .bsp files (plus .nav files if
the map has them) in the folder for the mode, and they appear at the top of
the map menu when that mode is picked in !gamemode or !1v1:

  csgo\maps\modes\competitive\    Competitive 5v5
  csgo\maps\modes\wingman\        Wingman 2v2
  csgo\maps\modes\casual\         Casual
  csgo\maps\modes\deathmatch\     Deathmatch
  csgo\maps\modes\armsrace\       Arms Race
  csgo\maps\modes\demolition\     Demolition
  csgo\maps\modes\practice\       Practice
  csgo\maps\modes\kz\             KZ (climb)
  csgo\maps\modes\bhop\           Bhop
  csgo\maps\modes\surf\           Surf
  csgo\maps\modes\1v1\            1v1 match
  csgo\maps\modes\arena\          Multi-1v1 arenas
  csgo\maps\modes\aimbotz\        Aim Botz (solo training)

Each folder also has a maplist.txt of standard maps for that mode. Installed
ones are listed near the top of the menu; missing ones are shown greyed out
as "(not installed)" so you know what to get. Edit maplist.txt to change it.

  Competitive  de_dust2 de_mirage de_inferno de_nuke de_overpass de_vertigo
               de_ancient de_anubis
  Wingman      de_shortdust de_shortnuke de_lake gd_rialto de_inferno
               de_overpass
  Casual       de_dust2 cs_office cs_italy de_mirage
  Deathmatch   de_dust2 de_mirage de_inferno cs_office
  Arms Race    ar_baggage ar_shoots ar_monastery ar_pool_day
  Demolition   de_lake de_safehouse de_bank de_shortnuke
  Practice     de_mirage de_inferno de_dust2 de_nuke de_ancient
  1v1 match    de_shortdust de_lake de_shortnuke gd_rialto
  KZ           kz_experiment kz_exps_cursedjourney           (community)
  Bhop         bhop_xof bhop_skyruins bhop_zygos             (community)
  Surf         surf_utopia_v3 surf_mesa_revo_go surf_mai_redone_csgo
                                                             (community)
  Arenas       am_inferno_banana_dolnma am_walterv2          (community)
  Aim Botz     training_aim_csgo2                            (community)

The official maps are already installed with the server. The community
maps (KZ, Bhop, Surf, arenas) don't come with CS:GO and aren't included in
this pack. To get them:

  download_community_maps.bat
    Put it in your csgo folder (it comes with this pack, next to "maps")
    and double-click it. For every map in the KZ, Bhop, Surf and arena
    downloads.txt files it finds the CS:GO version on varq.net, downloads it,
    unpacks it and puts the .bsp (and .nav, materials etc.) in the right
    place. Maps you already have are skipped, so it's safe to run again.
    Anything it can't get is listed at the end with a link.
    The standard community maps above were picked because varq.net hosts
    a download for them. To add more, put a line in the mode's
    downloads.txt: the map name, then (if different) the last part of its
    varq.net page address - or workshop:<id> to download it straight from
    the Steam Workshop. Only pages with a download file work.
    Most downloads are .rar files: install 7-Zip (7-zip.org) first for the
    most reliable unpacking - without it the script uses Windows' built-in
    tar, which handles .rar on Windows 11 but may not on Windows 10.

PLAYERS GETTING THE MAPS
  CS:GO's built-in download is too slow for big maps (it times out and
  starts again), so use FastDL:

  start_server.bat  (recommended - starts FastDL with the server)
    Each time, it first downloads any community maps
    that are missing (AUTO_DOWNLOAD_MAPS=1 - maps you have are skipped, so
    this is quick), then starts FastDL in a minimized window, starts
    srcds.exe, restarts the server if it crashes (AUTO_RESTART=1), and
    stops FastDL when the server is done.

  start_fastdl.bat
    The FastDL web server itself (start_server.bat runs it for you, or run
    it on its own). The very first run asks for admin rights once to open
    port 27020 in Windows Firewall. The download address comes from the
    setup (cfg\csgo_match\fastdl.cfg). After that it runs without admin. Players who
    don't have a map download it quickly from this PC.
    Only map content is shared (maps, materials, models, sound, particles,
    resource folders) - not configs or anything else.
    Friends over the internet: forward TCP port 27020 on your router (the
    setup already put your public IP in fastdl.cfg).

  Without FastDL you can copy the server's csgo\maps\modes folder into each
  player's game folder (...\Counter-Strike Global Offensive\csgo\maps\modes),
  keeping the same sub-folders.

  Or by hand: download the CS:GO versions (e.g. from GameBanana or varq.net)
  and drop the .bsp into the mode's folder. The Steam Workshop now mostly
  has CS2 versions, which don't work in CS:GO.

The folders come with this pack and the plugin creates any that are missing
(plus a default maplist.txt). No restart needed after adding maps.


WHAT GETS CREATED AUTOMATICALLY
-------------------------------
  cfg\csgo_match\warmup.cfg / knife.cfg / live.cfg / prac.cfg / duel.cfg
  cfg\csgo_match\wingman.cfg                                    (2v2 settings)
  cfg\csgo_match\kz.cfg / bhop.cfg / surf.cfg                   (movement physics)
  cfg\csgo_match\1v1.cfg / arena.cfg                            (1v1 modes)
  cfg\sourcemod\csgo_match.cfg                                 (match settings)
  addons\sourcemod\data\csgo_loadout\<steamid>.cfg             (one per player)
  addons\sourcemod\data\csgo_match_options.txt                 (!options choices)


CHAT COMMANDS
-------------
Every command works with "!" (e.g. !ready). Match commands also work
with "." (e.g. .ready). From the console, use sm_<command>.

Game modes (admins)
  !gamemode  (!mode)    menu with every mode. Pick one, then a map, and the
                        server switches 5 seconds later:
                          Competitive 5v5   ready-up match (knife, pauses...)
                          Wingman 2v2       ready-up match, uses wingman.cfg
                          Casual
                          Deathmatch
                          Arms Race
                          Demolition
                          Practice          practice mode on the chosen map
                          KZ (climb)        kz_ / kzpro_ / bkz_ / xc_ maps
                          Bhop              bhop_ maps (auto-bhop on)
                          Surf              surf_ maps
                          1v1 match         ready-up 1v1, one player per side
                          Multi-1v1 arenas  arena ladder on am_ / 1v1_ maps
                          Aim Botz          solo aim training (below)
                          1v1 aim duel      challenge a player
                          Match options     opens !options
                        The map menu also has "All maps on the server...".
                        The map menu lists, in order: the current map, the
                        mode's own map folder (see MAP FOLDERS), then other
                        suitable maps installed on the server. For KZ, Bhop,
                        Surf and arenas the maps folder (and maps\workshop)
                        is also scanned for maps with those name prefixes.
                        Everyone else can type !gamemode to see the mode.
  !map                  change map - menu with every map on the server:
                          All maps A-Z
                          Main maps folder (csgo\maps)
                          one entry per mode folder that has maps
                          Workshop maps
                        Picking a map from a mode's folder while the server
                        is in another mode asks whether to switch mode too.
  !map <name>           change straight to a map; short names work
                        (!map am_walterv2 finds modes/arena/am_walterv2)
                        Replaces SourceMod's own !map, which only knows the
                        mapcycle maps.
  !options  (!settings) match options menu - click an option to change it:
                          5v5 series: single map or best of 3
                          map vote time (best of 3)
                          knife round on/off
                          players needed to start (everyone, 2, 4, 6, 8, 10)
                          match length (MR15, MR12, 16 rounds, or live.cfg)
                          overtime on/off
                          friendly fire on/off
                          tactical pauses per team (unlimited, 1-4)
                          unpause needs both teams
                          !stop round restore on/off
                          demo recording on/off
                          side pick time (30-120 s)
                          reset all to defaults
                        Choices are saved and override csgo_match.cfg.

  The chosen mode stays across map changes. Restarting the server goes back
  to the mode in your launch line (+game_type 0 +game_mode 1 = Competitive).
  In Casual, Deathmatch, Arms Race and Demolition the game runs its own
  rules; the ready-up commands only apply in Competitive and Wingman.

KZ / Bhop / Surf (anyone, while the server is in one of these modes)
  !r  (!respawn)        back to the start
  !cp  (!checkpoint)    save a checkpoint (keeps your last 20)
  !tp  (!teleport)      go to your current checkpoint
  !pcp / !ncp           previous / next checkpoint
  !speed                speedometer on/off (on by default; spectators see
                        the speed of the player they're watching)
  !hide                 hide/show other players
  !noclip  (!nc)        fly through walls (practice)

  Players respawn instantly, pass through each other and can't hurt each
  other. Map damage (falling into kill zones) still works.
  Physics per mode (edit freely):
    cfg\csgo_match\kz.cfg      airaccelerate 100, no auto-bhop, no stamina
    cfg\csgo_match\bhop.cfg    airaccelerate 1000, auto-bhop, no stamina
    cfg\csgo_match\surf.cfg    airaccelerate 150, auto-bhop, no stamina
  These modes don't include run timers or leaderboards. Those need a
  dedicated plugin such as GOKZ (KZ), SurfTimer (surf) or shavit's bhop
  timer.

Match - players
  !ready  (!r)          mark yourself ready in warmup
  !unready  (!ur)       undo ready
  !pause                tactical pause (starts at next freezetime)
  !tech                 technical pause
  !unpause              both teams must type it to resume
  !tac                  built-in tactical timeout
  !stop                 both teams type it to replay the current round
  !status               match state and ready count
  !help                 list commands in chat

Match - knife round winners
  !stay  !switch  !t  !ct

Match - admins
  !start                force-start the match from warmup
  !restart              reset back to warmup
  !knifetoggle          turn the knife round on/off (or .knife)
  !forceready           mark everyone ready and start
  !fup                  force unpause
  !team1 <name>         set team 1 name
  !team2 <name>         set team 2 name
  !readyrequired <n>    players needed to start (0 = everyone)
  !restore <n>          load round backup <n>
  !prac / !exitprac     practice mode on/off

Best of 3 (Competitive 5v5)
  Turn it on with !bo3 or in !options ("5v5 series"). !bo1 goes back to
  single maps. Then:
    1. Everyone readies up in warmup as usual (!ready).
    2. Map vote: whoever is CT is one team, T the other. On its turn each
       team gets a menu and votes - ban, ban, pick, pick, then bans until
       one map is left (the decider). Most votes wins; a tie or no votes
       picks at random. Time per vote: !options (default 25 s).
    3. The server goes to map 1. Ready up again on each map. The knife
       round (if on) decides sides each map.
    4. After each map the score is shown and the next map loads by itself
       after 20 s. First team to 2 maps wins.
  Teams stay together: players who reconnect or pick the wrong side are
  put back with their team. Someone new who joins a side joins that team.
  Team names come from !team1/!team2 if set before the vote, otherwise
  "Team <first player's name>".
  The map pool is maps\modes\competitive\maplist.txt - the first 7
  installed maps in that file (at least 3 needed).
  !series               maps, who picked them, and the score (anyone)
  !endseries            admins: stop the series
  Changing map or game mode yourself mid-series also ends it.

Aim Botz - solo aim training
  !aimbotz  (!aim, !training)  admins: switch to Aim Botz (map picker), or
                        pick "Aim Botz (solo training)" in !gamemode.
  Uses the Aim Botz - Training map (training_aim_csgo2). The map's own
  buttons add the bots and change their settings. The mode adds infinite
  ammo, buy anywhere, $60k, instant respawn and no round end, and lets the
  map's buttons run bot commands (sv_allow_point_servercommand always).
  Settings: cfg\csgo_match\aimbotz.cfg. Leave with !gamemode.
  Getting the map: download_community_maps.bat downloads it straight from
  the Steam Workshop (Workshop id 243702660). If that fails, subscribe to "Aim Botz - Training" (Workshop id 243702660) on a
  PC with CS:GO Legacy, start the game once, then copy
  csgo\maps\workshop\243702660\training_aim_csgo2.bsp into the server's
  csgo\maps\modes\aimbotz folder.

Match - practice mode
  !spawn <n>  !clear  !god

1v1 MODES
  !1v1                  menu with every 1v1 mode:
                          Aim duel          anyone can challenge (below)
                          1v1 match         admins: switch the server to a
                                            ready-up 1v1 match
                          Multi-1v1 arenas  admins: switch the server to the
                                            arena ladder
  !1v1 <name>           same as !duel <name>

1v1 match (server mode, set with !1v1 or !gamemode)
  Normal ready-up match flow (!ready, knife round, pauses, !stop...) with
  one player per side - extra players spectate. Needs 2 ready players.
  Settings: cfg\csgo_match\1v1.cfg (MR15, 1:30 rounds, 5 s freeze), run
  after live.cfg. Match length / overtime from !options still apply.

Multi-1v1 arenas (server mode, set with !1v1 or !gamemode)
  Everyone is paired off into the map's arenas each round. Win and you move
  up an arena, lose and you move down; arena 1 is the top. With an odd
  number of players (or more players than arenas) the extra player sits out
  one round and goes in next. Each arena gets a random Rifle, Pistol or AWP
  round (AWP only if both players allow it). If a fight lasts 60 seconds it
  is decided on health.
  Arena maps: am_ and 1v1_ maps on the server (scanned automatically). On a
  normal map there is just one arena.
  !guns                 choose your rifle, pistol and whether you want AWP
                        rounds (saved for next time)
  !sitout               take a break / come back
  !rank                 which arena you're in
  Settings: cfg\csgo_match\arena.cfg

Aim duel (anyone, from warmup)
  !duel                 challenge someone: pick opponent, weapon
                        (AK, M4A4, M4A1-S, AWP, SSG, Deagle, USP-S, Glock,
                        P250, random each round, or knives) and kills to win
  !duel <name>          challenge a player directly by name
  !accept / !decline    answer a challenge (30 seconds)
  !forfeit  (!ff)       give up (the other player wins)
  !endduel              admins: stop a duel

  Both players spawn facing each other at random spots around the map,
  freeze for 1 second, then fight. Every kill resets both with full HP and
  armour. Score shows on the scoreboard and on screen. Everyone else is
  moved to spectator for the duel and can rejoin afterwards.
  Duel settings: cfg\csgo_match\duel.cfg

Loadout
  !ws  (!loadout, !skins)   main menu
  !presets  (!sets)         preset loadouts - equip a full high-tier set in
                            one click: knife, gloves and a matching skin for
                            every gun (all 34), with colour-matched sticker
                            crafts. 9 sets: Ruby
                            Inferno, Sapphire Frost, Emerald Toxin, Golden
                            Lore, Candy Fade, Printstream, Neon Dream, Blue
                            Gem, Asiimov Orange. Also first in the !ws menu.
                            Edit or add sets in
                            addons\sourcemod\configs\csgo_loadout_presets.cfg
  !slots  (!defaults)       default weapons: USP-S/P2000, M4A1-S/M4A4,
                            CZ75 vs Five-SeveN/Tec-9, R8/Deagle, MP5-SD/MP7
                            (new players are asked on first spawn)
  !knife  !gloves  !agents  !stickers
  !patches                  agent patches - 3 spots, like in the game
  !3rd  (!thirdperson)      third-person view on/off, to look at your agent
                            (choosing an agent, patch or gloves also shows a
                            short third-person preview; agent changes now
                            apply straight away if you're on that team)
                            Third person is blocked during live matches,
                            knife rounds, duels and arena rounds, and anyone
                            using it is put back in first person when a match
                            goes live. It works in warmup and casual modes.
                            (changing stickers redraws your weapon with a
                            short stutter - that's normal)
  !gen <weapon id> <skin id> [pattern] [wear] [sticker wear ...]

  When a menu asks you to type something, type it in chat
  ("cancel" backs out).

  Note: !knife is the loadout knife menu. The admin knife-round toggle
  is !knifetoggle (or .knife) so the two don't clash.


MATCH SETTINGS (cfg\sourcemod\csgo_match.cfg)
---------------------------------------------
  match_minimum_ready_required        (0 = everyone on a team)
  match_knife_enabled_default
  match_side_select_time
  match_max_tactical_pauses           (0 = unlimited)
  match_both_teams_unpause_required
  match_stop_command_enabled
  match_demo_recording_enabled
  match_demo_name_prefix
  match_max_rounds                    (0 = use live.cfg)
  match_overtime                      (-1 = use live.cfg)
  match_friendlyfire                  (-1 = use live.cfg)
  match_allow_map_downloads           (1 = players download missing maps;
                                       also loads cfg\csgo_match\fastdl.cfg)
  match_max_download_mb               (largest map sent to players, MB)
  match_admin_password                (for /login; empty = off)


ADMIN ACCESS
------------
Admin commands need the "b" or "z" flag. Two ways to get it:

1. Password login (works in LAN mode, where SteamIDs can't be checked)
   Add this line to the bottom of csgo\cfg\sourcemod\csgo_match.cfg and
   restart the server (pick your own password):
       match_admin_password "your-admin-password"
   Then in game type in chat:   /login your-admin-password
   (the / keeps it out of chat - !login and .login are hidden too)
   You get full admin, and that PC is remembered so you're logged in
   automatically next time. /logout forgets it. Three wrong passwords lock
   that player out of /login for a minute. Remembered admins are kept in
   addons\sourcemod\data\csgo_match_admins.txt (delete a line to remove one).

2. SteamID in admins.cfg (only works when the server can check SteamIDs,
   i.e. sv_lan 0 with a working login token)
   Add an entry to addons\sourcemod\configs\admins.cfg inside Admins { },
   then run sm_reloadadmins in the server console.


Credits: skin/glove handling follows kgns' Weapons & Knives and Gloves;
sticker method and gamedata from quasemago's CS:GO Weapon Stickers (GPLv3).
