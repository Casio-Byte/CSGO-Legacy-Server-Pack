/*
 * CS:GO Match — match management for CS:GO servers
 *
 *  Warmup + ready system  ->  knife round  ->  stay/switch  ->  live match
 *  Pauses (tactical / tech / native timeouts), .stop round restore,
 *  SourceTV demo recording, practice mode.
 *
 *  Commands work in chat with a "!" prefix (!ready) or "." prefix (.ready),
 *  and from console as sm_<command>.
 *
 *  Requires SourceMod 1.10+ on a CS:GO server.
 *  Default configs are written to cfg/csgo_match/ on first load.
 */

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <cstrike>
#include <clientprefs>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "1.8.0-20261103"
#define PREFIX " \x01[\x04Match\x01] "
#define CFG_DIR "cfg/csgo_match"

public Plugin myinfo =
{
	name        = "CS:GO Match",
	author      = "CS:GO Match",
	description = "Ready system, knife round, pauses, round restore, demos and practice mode for CS:GO",
	version     = PLUGIN_VERSION,
	url         = ""
};

enum MatchState
{
	State_None = 0,
	State_Warmup,
	State_Knife,
	State_SideSelect,
	State_Live,
	State_Practice,
	State_Duel,
	State_Arena
};

MatchState g_State = State_None;

/* Best-of-3 series with map veto (team votes) */
#define SERIES_TEAM_A 0          // the team on CT when the veto started
#define SERIES_TEAM_B 1
#define VETO_MAX_POOL 7
#define VETO_BAN  0
#define VETO_PICK 1
ConVar    g_cvSeries;
ConVar    g_cvVetoTime;
bool      g_SeriesActive = false;    // maps are decided, series in progress
bool      g_VetoRunning = false;
StringMap g_SeriesRoster = null;     // player key -> SERIES_TEAM_A / SERIES_TEAM_B
char      g_SeriesName[2][64];
char      g_SeriesMaps[3][PLATFORM_MAX_PATH];
char      g_SeriesMapNote[3][48];    // "picked by X" / "decider"
int       g_SeriesResult[3];         // -1 not played, 0/1 winner, 2 draw
int       g_SeriesWins[2];
int       g_SeriesMapIndex = 0;
ArrayList g_VetoPool = null;         // map paths still in the pool
int       g_VetoSeqTeam[16];
int       g_VetoSeqAction[16];
int       g_VetoSeqLen = 0;
int       g_VetoStep = 0;
int       g_VetoSerial = 0;
int       g_VetoVote[MAXPLAYERS + 1];
Handle    g_VetoTimer = null;
int       g_VetoPicks = 0;
bool      g_SeriesShowLast = false;  // a finished series' results are still shown by !series

/* 1v1 duel state */
#define DUEL_WEAPONS 11
char g_DuelWepCls[DUEL_WEAPONS][] =
{
	"weapon_ak47", "weapon_m4a1", "weapon_m4a1_silencer", "weapon_awp", "weapon_ssg08",
	"weapon_deagle", "weapon_usp_silencer", "weapon_glock", "weapon_p250", "random", "knife"
};
char g_DuelWepName[DUEL_WEAPONS][] =
{
	"AK-47", "M4A4", "M4A1-S", "AWP", "SSG 08",
	"Desert Eagle", "USP-S", "Glock-18", "P250", "Random each round", "Knives only"
};

ConVar g_cvDuelActive;
ConVar g_cvCompActive;
ConVar g_cvAdminPass;
ConVar g_cvMapDownloads;
ConVar g_cvMaxDownloadMB;
int    g_LoginFails[MAXPLAYERS + 1];
float  g_LoginLockUntil[MAXPLAYERS + 1];
int    g_LoginTick[MAXPLAYERS + 1];   // stops one chat message logging in twice
int    g_DuelA = 0;            // userid, plays T
int    g_DuelB = 0;            // userid, plays CT
int    g_DuelScoreA = 0;
int    g_DuelScoreB = 0;
int    g_DuelTarget = 10;
int    g_DuelWeapon = 0;       // index into g_DuelWep*
bool   g_DuelHs = false;       // headshots only
int    g_DuelRoundWeapon = 0;  // weapon for the current round (differs when "random")
bool   g_DuelRoundOver = false;
int    g_DuelSerial = 0;       // bumps on every reset so stale timers are ignored
bool   g_DuelPlaced = false;   // first round has been set up

// Challenge being set up / waiting for an answer
int    g_ChalFrom = 0;         // userid of challenger
int    g_ChalTo = 0;           // userid of challenged player
int    g_ChalWeapon = 0;
int    g_ChalTarget = 10;
bool   g_ChalHs = false;
Handle g_ChalTimer = null;
int    g_PickOpponent[MAXPLAYERS + 1];
int    g_PickWeapon[MAXPLAYERS + 1];
int    g_PickTarget[MAXPLAYERS + 1];
bool   g_PickHs[MAXPLAYERS + 1];

bool   g_Ready[MAXPLAYERS + 1];
bool   g_KnifeEnabled = true;
bool   g_KnifeActive  = false;
int    g_KnifeWinner  = 0;
Handle g_SideTimer    = null;

bool g_Paused      = false;

bool g_UnpauseReq[4];
int  g_TacPauses[4];
bool g_StopReq[4];

bool g_Recording = false;
char g_BackupPrefix[64];
bool g_LateLoad = false;

ConVar g_cvReadyRequired;
ConVar g_cvKnifeDefault;
ConVar g_cvSideTime;
ConVar g_cvDemoEnabled;
ConVar g_cvDemoPrefix;
ConVar g_cvMaxPauses;
ConVar g_cvBothUnpause;
ConVar g_cvStopEnabled;
ConVar g_cvMaxRounds;
ConVar g_cvOvertime;
ConVar g_cvFriendlyFire;

bool g_PracticeNext = false;   // set by !gamemode / !prac so practice survives a map change

/* 1v1 match / Multi-1v1 arenas */
bool  g_OneVOneNext = false;     // 1v1 ready-up match (survives map changes)
bool  g_ArenaNext = false;       // Multi-1v1 arenas (survives map changes)

/* !map */
#define MAPCAT_ALL      -3
#define MAPCAT_WORKSHOP -2
#define MAPCAT_ROOT     -1   // csgo/maps/ itself; 0+ = a mode folder (g_GmFolder index)

enum struct MapEntry
{
	char path[PLATFORM_MAX_PATH];   // what changelevel needs, e.g. modes/arena/am_walterv2
	char name[96];                  // what players see, e.g. am_walterv2
	int cat;
}

int g_MapPickGm[MAXPLAYERS + 1] = { -1, ... };   // >= 0: picking a map for !gamemode
int g_MapListCat[MAXPLAYERS + 1];
char g_MapPickPath[MAXPLAYERS + 1][PLATFORM_MAX_PATH];

#define MAX_ARENAS     32
#define MAX_SPAWNS     128
#define ARENA_CLUSTER  600.0

enum
{
	Round_Rifle = 0,
	Round_Pistol,
	Round_Awp
};

char g_RoundTypeName[3][] = { "Rifle", "Pistol", "AWP" };

char g_ArenaRifles[][]     = { "weapon_ak47", "weapon_m4a1", "weapon_m4a1_silencer", "weapon_galilar", "weapon_famas", "weapon_sg556", "weapon_aug" };
char g_ArenaRifleNames[][] = { "AK-47", "M4A4", "M4A1-S", "Galil AR", "FAMAS", "SG 553", "AUG" };
char g_ArenaPistols[][]     = { "weapon_usp_silencer", "weapon_hkp2000", "weapon_glock", "weapon_p250", "weapon_deagle", "weapon_cz75a", "weapon_fiveseven", "weapon_tec9", "weapon_elite" };
char g_ArenaPistolNames[][] = { "USP-S", "P2000", "Glock-18", "P250", "Desert Eagle", "CZ75-Auto", "Five-SeveN", "Tec-9", "Dual Berettas" };

Cookie g_CookieRifle;
Cookie g_CookiePistol;
Cookie g_CookieAwp;
int  g_PrefRifle[MAXPLAYERS + 1];
int  g_PrefPistol[MAXPLAYERS + 1];
bool g_PrefAwp[MAXPLAYERS + 1] = { true, ... };
bool g_SitOut[MAXPLAYERS + 1];

int   g_ArenaCount = 0;
float g_ArenaTPos[MAX_ARENAS][3];
float g_ArenaTAng[MAX_ARENAS][3];
float g_ArenaCTPos[MAX_ARENAS][3];
float g_ArenaCTAng[MAX_ARENAS][3];

ArrayList g_ArenaRank;                 // userids, best first
int  g_ArenaP[MAX_ARENAS][2];          // userids fighting this round (T, CT)
int  g_ArenaWinner[MAX_ARENAS];        // userid, 0 = undecided
int  g_ArenaType[MAX_ARENAS];
int  g_ArenasInUse = 0;
bool g_ArenaRoundLive = false;
int  g_ArenaSerial = 0;
ArrayList g_ArenaWaiting;              // userids sitting this round out (odd one)

// Commands registered as sm_<name> so "!name" works too. ".name" works for everything in Dispatch().
char g_RegisteredCmds[][] =
{
	"ready", "r", "rdy", "unready", "ur", "notready",
	"pause", "tech", "unpause", "tac", "stop",
	"stay", "switch", "swap", "t", "ct",
	"help", "status", "matchstatus",
	"start", "forcestart", "restart", "endmatch", "reset", "knifetoggle", "forceready",
	"forceunpause", "fup", "team1", "team2", "restore", "readyrequired",
	"prac", "exitprac", "clear", "spawn", "god",
	"duel", "1v1", "accept", "decline", "forfeit", "ff", "endduel",
	"gamemode", "mode", "modes", "options", "settings",
	"guns", "sitout", "rank", "maps", "changemap",
	"bo3", "bo1", "veto", "series", "maps3", "endseries", "cancelseries"
};

/* ------------------------------------------------------------------ */
/*  Default config files (written once, never overwritten)            */
/* ------------------------------------------------------------------ */

char g_CfgWarmup[][] =
{
	"sv_cheats 0",
	"sv_infinite_ammo 0",
	"sv_grenade_trajectory 0",
	"sv_showimpacts 0",
	"mp_buy_anywhere 0",
	"mp_respawn_on_death_ct 0",
	"mp_respawn_on_death_t 0",
	"mp_ct_default_secondary \"weapon_hkp2000\"",
	"mp_t_default_secondary \"weapon_glock\"",
	"mp_ct_default_primary \"\"",
	"mp_t_default_primary \"\"",
	"mp_give_player_c4 1",
	"mp_maxmoney 16000",
	"mp_startmoney 16000",
	"mp_do_warmup_period 1",
	"mp_warmuptime 9999",
	"mp_warmup_pausetimer 1",
	"mp_autokick 0",
	"mp_autoteambalance 0",
	"mp_limitteams 0",
	"mp_match_end_restart 0",
	"mp_match_end_changelevel 0",
	"bot_kick"
};

char g_CfgKnife[][] =
{
	"mp_ct_default_secondary \"\"",
	"mp_t_default_secondary \"\"",
	"mp_ct_default_primary \"\"",
	"mp_t_default_primary \"\"",
	"mp_give_player_c4 0",
	"mp_startmoney 0",
	"mp_maxmoney 0",
	"mp_free_armor 1",
	"mp_freezetime 5",
	"mp_roundtime 1.92",
	"mp_roundtime_defuse 1.92",
	"mp_friendlyfire 0",
	"mp_respawn_on_death_ct 0",
	"mp_respawn_on_death_t 0",
	"mp_buy_anywhere 0",
	"sv_cheats 0"
};

char g_CfgLive[][] =
{
	"// Standard 5v5. Set mp_maxrounds 24 for MR12.",
	"sv_cheats 0",
	"sv_infinite_ammo 0",
	"sv_grenade_trajectory 0",
	"sv_showimpacts 0",
	"bot_quota 0",
	"bot_kick",
	"mp_ct_default_secondary \"weapon_hkp2000\"",
	"mp_t_default_secondary \"weapon_glock\"",
	"mp_ct_default_primary \"\"",
	"mp_t_default_primary \"\"",
	"mp_give_player_c4 1",
	"mp_startmoney 800",
	"mp_maxmoney 16000",
	"mp_free_armor 0",
	"mp_maxrounds 30",
	"mp_halftime 1",
	"mp_match_can_clinch 1",
	"mp_overtime_enable 1",
	"mp_overtime_maxrounds 6",
	"mp_overtime_startmoney 10000",
	"mp_roundtime 1.92",
	"mp_roundtime_defuse 1.92",
	"mp_freezetime 15",
	"mp_buytime 20",
	"mp_buy_anywhere 0",
	"mp_c4timer 40",
	"mp_friendlyfire 1",
	"mp_death_drop_gun 1",
	"mp_solid_teammates 1",
	"mp_respawn_on_death_ct 0",
	"mp_respawn_on_death_t 0",
	"mp_autokick 0",
	"mp_autoteambalance 0",
	"mp_limitteams 0",
	"mp_team_timeout_max 4",
	"mp_team_timeout_time 30",
	"mp_backup_round_auto 1",
	"mp_match_end_restart 0",
	"mp_match_end_changelevel 0",
	"mp_warmup_pausetimer 0",
	"spec_freeze_time 2"
};

char g_CfgDuel[][] =
{
	"// 1v1 aim duel. Rounds never end on their own; the plugin handles kills and respawns.",
	"sv_cheats 0",
	"bot_quota 0",
	"bot_kick",
	"mp_ignore_round_win_conditions 1",
	"mp_roundtime 60",
	"mp_roundtime_defuse 60",
	"mp_roundtime_hostage 60",
	"mp_freezetime 0",
	"mp_buytime 0",
	"mp_buy_anywhere 0",
	"mp_startmoney 0",
	"mp_maxmoney 0",
	"mp_free_armor 0",
	"mp_respawn_on_death_ct 0",
	"mp_respawn_on_death_t 0",
	"mp_death_drop_gun 0",
	"mp_death_drop_grenade 0",
	"mp_death_drop_defuser 0",
	"mp_give_player_c4 0",
	"mp_ct_default_secondary \"\"",
	"mp_t_default_secondary \"\"",
	"mp_ct_default_primary \"\"",
	"mp_t_default_primary \"\"",
	"mp_weapons_allow_map_placed 0",
	"mp_autoteambalance 0",
	"mp_limitteams 0",
	"mp_friendlyfire 0",
	"mp_solid_teammates 1",
	"mp_randomspawn 0",
	"mp_respawn_immunitytime 0",
	"mp_halftime 0",
	"mp_maxrounds 999",   // 0 would end the game after one round
	"mp_timelimit 0",
	"mp_warmup_pausetimer 0"
};

char g_CfgWingman[][] =
{
	"// Wingman 2v2 — runs after live.cfg when the server is in Wingman mode.",
	"mp_maxrounds 16",
	"mp_roundtime 1.5",
	"mp_roundtime_defuse 1.5",
	"mp_freezetime 10",
	"mp_buytime 15",
	"mp_halftime 1",
	"mp_overtime_enable 1",
	"mp_overtime_maxrounds 6",
	"mp_overtime_startmoney 10000",
	"mp_team_timeout_max 2",
	"mp_c4timer 40"
};




char g_Cfg1v1[][] =
{
	"// 1v1 match — runs after live.cfg when the server is in 1v1 match mode.",
	"mp_maxrounds 30",
	"mp_roundtime 1.5",
	"mp_roundtime_defuse 1.5",
	"mp_freezetime 5",
	"mp_buytime 10",
	"mp_c4timer 35",
	"mp_halftime 1",
	"mp_overtime_enable 1",
	"mp_overtime_maxrounds 6",
	"mp_team_timeout_max 1",
	"mp_friendlyfire 0"
};

char g_CfgArena[][] =
{
	"// Multi-1v1 arenas. The plugin ends rounds itself when every arena is decided.",
	"sv_cheats 0",
	"bot_quota 0",
	"bot_kick",
	"mp_ignore_round_win_conditions 1",
	"mp_roundtime 5",
	"mp_roundtime_defuse 5",
	"mp_roundtime_hostage 5",
	"mp_freezetime 2",
	"mp_round_restart_delay 3",
	"mp_buytime 0",
	"mp_buy_anywhere 0",
	"mp_startmoney 0",
	"mp_maxmoney 0",
	"mp_free_armor 0",
	"mp_respawn_on_death_ct 0",
	"mp_respawn_on_death_t 0",
	"mp_death_drop_gun 0",
	"mp_death_drop_grenade 0",
	"mp_give_player_c4 0",
	"mp_ct_default_secondary \"\"",
	"mp_t_default_secondary \"\"",
	"mp_ct_default_primary \"\"",
	"mp_t_default_primary \"\"",
	"mp_weapons_allow_map_placed 0",
	"mp_autoteambalance 0",
	"mp_limitteams 0",
	"mp_friendlyfire 0",
	"mp_halftime 0",
	"mp_maxrounds 999",   // 0 would end the game after one round
	"mp_timelimit 0",
	"mp_warmup_pausetimer 0"
};

char g_CfgPrac[][] =
{
	"sv_cheats 1",
	"sv_infinite_ammo 1",
	"sv_grenade_trajectory 1",
	"sv_grenade_trajectory_time 10",
	"sv_showimpacts 1",
	"sv_showimpacts_time 10",
	"mp_buy_anywhere 1",
	"mp_buytime 99999",
	"mp_maxmoney 60000",
	"mp_startmoney 60000",
	"mp_freezetime 0",
	"mp_roundtime 60",
	"mp_roundtime_defuse 60",
	"mp_respawn_on_death_ct 1",
	"mp_respawn_on_death_t 1",
	"mp_limitteams 0",
	"mp_autoteambalance 0",
	"mp_friendlyfire 0",
	"mp_ct_default_secondary \"weapon_hkp2000\"",
	"mp_t_default_secondary \"weapon_glock\"",
	"mp_give_player_c4 1",
	"bot_kick"
};

/* ------------------------------------------------------------------ */
/*  Plugin lifecycle                                                  */
/* ------------------------------------------------------------------ */

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	if (GetEngineVersion() != Engine_CSGO)
	{
		strcopy(error, err_max, "CS:GO Match only supports CS:GO.");
		return APLRes_Failure;
	}
	g_LateLoad = late;
	return APLRes_Success;
}

public void OnPluginStart()
{
	g_cvReadyRequired = CreateConVar("match_minimum_ready_required", "10", "Players that must be ready to start the match (0 = everyone on a team)", _, true, 0.0, true, 64.0);
	g_cvKnifeDefault  = CreateConVar("match_knife_enabled_default", "1", "Play a knife round for sides by default", _, true, 0.0, true, 1.0);
	g_cvSideTime      = CreateConVar("match_side_select_time", "60", "Seconds the knife winners get to pick a side before it defaults to stay", _, true, 10.0);
	g_cvDemoEnabled   = CreateConVar("match_demo_recording_enabled", "1", "Record a SourceTV demo of each match (needs tv_enable 1)", _, true, 0.0, true, 1.0);
	g_cvDemoPrefix    = CreateConVar("match_demo_name_prefix", "match", "Prefix for demo file names");
	g_cvMaxPauses     = CreateConVar("match_max_tactical_pauses", "0", "Tactical .pause uses per team per match (0 = unlimited; .tech is never limited)", _, true, 0.0);
	g_cvBothUnpause   = CreateConVar("match_both_teams_unpause_required", "1", "Both teams must type .unpause to resume", _, true, 0.0, true, 1.0);
	g_cvStopEnabled   = CreateConVar("match_stop_command_enabled", "1", "Allow .stop (both teams) to restore the current round", _, true, 0.0, true, 1.0);
	g_cvAdminPass     = CreateConVar("match_admin_password", "", "Password for /login (admin without needing a SteamID, e.g. in LAN mode). Empty = /login is off.", FCVAR_PROTECTED);
	RegConsoleCmd("sm_login", Cmd_Login);
	RegConsoleCmd("sm_logout", Cmd_Logout);
	g_cvMapDownloads  = CreateConVar("match_allow_map_downloads", "1", "Let players download maps they don't have from the server (sets sv_allowdownload 1 every map).", _, true, 0.0, true, 1.0);
	g_cvMaxDownloadMB = CreateConVar("match_max_download_mb", "150", "Largest map file (MB) the server will send to players (sets net_maxfilesize; the game caps it at its own maximum).", _, true, 16.0, true, 1024.0);
	g_cvMaxRounds     = CreateConVar("match_max_rounds", "0", "Rounds in a match (30 = MR15, 24 = MR12, 16 = short/wingman; 0 = use live.cfg)", _, true, 0.0, true, 60.0);
	g_cvOvertime      = CreateConVar("match_overtime", "-1", "Overtime: 1 = on, 0 = off, -1 = use live.cfg", _, true, -1.0, true, 1.0);
	g_cvFriendlyFire  = CreateConVar("match_friendlyfire", "-1", "Friendly fire in matches: 1 = on, 0 = off, -1 = use live.cfg", _, true, -1.0, true, 1.0);
	g_cvSeries        = CreateConVar("match_series_maps", "1", "Competitive 5v5: 1 = single map, 3 = best of 3 with a map veto (teams vote to ban/pick)", _, true, 1.0, true, 3.0);
	g_cvVetoTime      = CreateConVar("match_veto_time", "25", "Seconds a team gets to vote on each map ban/pick", _, true, 10.0, true, 120.0);
	CreateConVar("csgo_match_version", PLUGIN_VERSION, "CS:GO Match version", FCVAR_NOTIFY | FCVAR_DONTRECORD);
	LogMessage("CS:GO Match %s loaded", PLUGIN_VERSION);
	PrintToServer("[Match] CS:GO Match %s loaded", PLUGIN_VERSION);

	AutoExecConfig(true, "csgo_match");

	char name[64];
	for (int i = 0; i < sizeof(g_RegisteredCmds); i++)
	{
		Format(name, sizeof(name), "sm_%s", g_RegisteredCmds[i]);
		RegConsoleCmd(name, Command_Generic);
	}

	HookEvent("round_start", Event_RoundStart);
	HookEvent("round_end", Event_RoundEnd);
	HookEvent("round_freeze_end", Event_RoundFreezeEnd);
	HookEvent("player_spawn", Event_PlayerSpawn);
	HookEvent("cs_win_panel_match", Event_MatchEnd);
	HookEvent("announce_phase_end", Event_PhaseEnd);
	HookEvent("player_death", Event_DuelDeath);
	HookEvent("player_team", Event_DuelTeam);
	HookEvent("player_team", Event_SeriesTeam);
	g_SeriesRoster = new StringMap();
	g_VetoPool = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));
	for (int i = 0; i < 3; i++)
		g_SeriesResult[i] = -1;
	AddCommandListener(Listener_JoinTeam, "jointeam");
	AddCommandListener(Listener_Map, "sm_map");   // our !map replaces SourceMod's
	g_CookieRifle  = RegClientCookie("match_arena_rifle", "Multi-1v1: preferred rifle", CookieAccess_Private);
	g_CookiePistol = RegClientCookie("match_arena_pistol", "Multi-1v1: preferred pistol", CookieAccess_Private);
	g_CookieAwp    = RegClientCookie("match_arena_awp", "Multi-1v1: AWP rounds", CookieAccess_Private);
	g_ArenaRank = new ArrayList();
	g_cvCompActive = CreateConVar("match_competitive_active", "0", "Set by the plugin while a match, knife round, duel or arena round is on (read-only). Other plugins use it to block things like third person.", FCVAR_DONTRECORD);
	CreateTimer(0.5, Timer_SyncCompFlag, _, TIMER_REPEAT);
	g_cvDuelActive = CreateConVar("match_duel_active", "0", "Set by the plugin while a 1v1 duel is running (read-only)", FCVAR_DONTRECORD);

	WriteDefaultConfigs();
	CreateModeFolders();

	CreateTimer(30.0, Timer_Remind, _, TIMER_REPEAT);
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i))
			OnClientPutInServer(i);
	}

	if (g_LateLoad)
	{
		g_KnifeEnabled = g_cvKnifeDefault.BoolValue;
		StartWarmup();
	}
}

public void OnConfigsExecuted()
{
	// Server name, passwords and LAN/internet from start_server.bat's first-run setup.
	if (FileExists("cfg/csgo_match/server_settings.cfg"))
		ServerCommand("exec csgo_match/server_settings.cfg");
	ApplyDownloadSettings();
	// No end-of-match map vote in any mode - the plugin (or !map / !gamemode)
	// decides what comes next.
	ServerCommand("mp_endmatch_votenextmap 0");
	LoadSavedOptions();
	g_KnifeEnabled = g_cvKnifeDefault.BoolValue;
	ApplyModeOnMapStart();
}

public void OnMapEnd()
{
	g_VetoTimer = null;     // killed by TIMER_FLAG_NO_MAPCHANGE
	if (g_VetoRunning)
		CancelSeries("");   // map changed mid-veto
	DuelCleanup();
	StopDemo();
	g_SideTimer = null; // killed by TIMER_FLAG_NO_MAPCHANGE
	g_State = State_None;
}

bool g_JoinHandled[MAXPLAYERS + 1];

public void OnClientPostAdminCheck(int client)
{
	HandleJoin(client);
}

void HandleJoin(int client)
{
	if (g_JoinHandled[client] || IsFakeClient(client))
		return;
	g_JoinHandled[client] = true;

	g_LoginFails[client] = 0;
	g_LoginLockUntil[client] = 0.0;
	CheckRememberedAdmin(client);

	if (g_State == State_Arena)
		ArenaOnJoin(client);
	SeriesOnJoin(client);
}

public void OnClientPutInServer(int client)
{
	g_JoinHandled[client] = false;
	SDKHook(client, SDKHook_TraceAttack, Hook_DuelTraceAttack);
	// In LAN mode / -insecure the admin check may never run; don't wait for it.
	if (!IsFakeClient(client))
		CreateTimer(4.0, Timer_JoinFallback, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_JoinFallback(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (client > 0 && IsClientInGame(client))
		HandleJoin(client);
	return Plugin_Stop;
}

public void OnClientDisconnect(int client)
{
	g_Ready[client] = false;
	ArenaOnDisconnect(client);
	DuelOnDisconnect(client);
	g_VetoVote[client] = -1;
	if (g_VetoRunning)
		RequestFrame(Frame_VetoCheckDone, g_VetoSerial);
}

/* ------------------------------------------------------------------ */
/*  Command routing                                                   */
/* ------------------------------------------------------------------ */

public Action Command_Generic(int client, int args)
{
	char name[64], arg[160];
	GetCmdArg(0, name, sizeof(name));
	GetCmdArgString(arg, sizeof(arg));
	TrimString(arg);
	// strip "sm_"
	Dispatch(client, name[3], arg);
	return Plugin_Handled;
}

public void OnClientSayCommand_Post(int client, const char[] command, const char[] sArgs)
{
	if (client <= 0 || sArgs[0] != '.')
		return;

	char text[192], cmd[32], arg[160];
	strcopy(text, sizeof(text), sArgs[1]);
	TrimString(text);

	int idx = BreakString(text, cmd, sizeof(cmd));
	if (idx != -1)
		strcopy(arg, sizeof(arg), text[idx]);
	else
		arg[0] = '\0';

	TrimString(arg);
	Dispatch(client, cmd, arg);
}

bool Is(const char[] a, const char[] b)
{
	return StrEqual(a, b, false);
}

void Dispatch(int client, const char[] cmd, const char[] arg)
{
	// players
	if (Is(cmd, "ready") || Is(cmd, "r") || Is(cmd, "rdy"))         Cmd_Ready(client, true);
	else if (Is(cmd, "unready") || Is(cmd, "ur") || Is(cmd, "notready")) Cmd_Ready(client, false);
	else if (Is(cmd, "pause"))                                           Cmd_Pause(client, false);
	else if (Is(cmd, "tech"))                                            Cmd_Pause(client, true);
	else if (Is(cmd, "unpause"))                                         Cmd_Unpause(client);
	else if (Is(cmd, "tac"))                                             Cmd_Tac(client);
	else if (Is(cmd, "stay"))                                            Cmd_Side(client, 0);
	else if (Is(cmd, "switch") || Is(cmd, "swap"))                       Cmd_Side(client, 1);
	else if (Is(cmd, "t"))                                               Cmd_Side(client, CS_TEAM_T);
	else if (Is(cmd, "ct"))                                              Cmd_Side(client, CS_TEAM_CT);
	else if (Is(cmd, "stop"))                                            Cmd_Stop(client);
	else if (Is(cmd, "help"))                                            Cmd_Help(client);
	else if (Is(cmd, "status") || Is(cmd, "matchstatus"))                Cmd_Status(client);
	// admins
	else if (Is(cmd, "start") || Is(cmd, "forcestart"))                  Cmd_ForceStart(client);
	else if (Is(cmd, "restart") || Is(cmd, "endmatch") || Is(cmd, "reset")) Cmd_Restart(client);
	else if (Is(cmd, "knife") || Is(cmd, "knifetoggle"))                                         Cmd_Knife(client);
	else if (Is(cmd, "forceready"))                                      Cmd_ForceReady(client);
	else if (Is(cmd, "forceunpause") || Is(cmd, "fup"))                  Cmd_ForceUnpause(client);
	else if (Is(cmd, "team1"))                                           Cmd_TeamName(client, 1, arg);
	else if (Is(cmd, "team2"))                                           Cmd_TeamName(client, 2, arg);
	else if (Is(cmd, "restore"))                                         Cmd_Restore(client, arg);
	else if (Is(cmd, "readyrequired"))                                   Cmd_ReadyRequired(client, arg);
	else if (Is(cmd, "prac"))                                            Cmd_Prac(client);
	else if (Is(cmd, "exitprac"))                                        Cmd_ExitPrac(client);
	// practice
	else if (Is(cmd, "clear"))                                           Cmd_Clear(client);
	else if (Is(cmd, "spawn"))                                           Cmd_Spawn(client, arg);
	else if (Is(cmd, "god"))                                             Cmd_God(client);
	// 1v1 aim duel
	else if (Is(cmd, "duel"))                                            Cmd_Duel(client, arg);
	else if (Is(cmd, "1v1"))                                             Cmd_OneVOneMenu(client, arg);
	else if (Is(cmd, "guns"))                                            Cmd_ArenaGuns(client);
	else if (Is(cmd, "map") || Is(cmd, "maps") || Is(cmd, "changemap"))  Cmd_MapChange(client, arg);
	else if (Is(cmd, "sitout"))                                          Cmd_SitOut(client);
	else if (Is(cmd, "rank"))                                            Cmd_ArenaRank(client);
	else if (Is(cmd, "accept"))                                          Cmd_DuelAnswer(client, true);
	else if (Is(cmd, "decline"))                                         Cmd_DuelAnswer(client, false);
	else if (Is(cmd, "forfeit") || Is(cmd, "endduel") || Is(cmd, "ff"))  Cmd_EndDuel(client);
	// game modes / options
	else if (Is(cmd, "gamemode") || Is(cmd, "mode") || Is(cmd, "modes"))  Cmd_GameMode(client);
	else if (Is(cmd, "options") || Is(cmd, "settings"))                  Cmd_Options(client);
	// best of 3
	else if (Is(cmd, "series") || Is(cmd, "maps3"))                      Cmd_Series(client);
	else if (Is(cmd, "bo3") || Is(cmd, "veto"))                          Cmd_Bo3(client);
	else if (Is(cmd, "bo1"))                                             Cmd_Bo1(client);
	else if (Is(cmd, "endseries") || Is(cmd, "cancelseries"))            Cmd_EndSeries(client);
}

/* ------------------------------------------------------------------ */
/*  Match flow                                                        */
/* ------------------------------------------------------------------ */

void ResetMatch()
{
	g_State = State_None;
	for (int i = 0; i <= MaxClients; i++)
		g_Ready[i] = false;

	g_KnifeActive = false;
	g_KnifeWinner = 0;
	delete g_SideTimer;

	g_Paused = false;
	for (int t = 0; t < 4; t++)
	{
		g_UnpauseReq[t] = false;
		g_TacPauses[t] = 0;
		g_StopReq[t] = false;
	}
}

void StartWarmup()
{
	DuelCleanup();
	ResetMatch();
	StopDemo();
	g_State = State_Warmup;

	ServerCommand("exec csgo_match/warmup.cfg");
	// No time or round limit can end the match during warmup, and the plugin
	// handles map changes itself (no end-of-match map vote).
	ServerCommand("mp_timelimit 0");
	ServerCommand("mp_endmatch_votenextmap 0");
	ServerCommand("mp_match_end_changelevel 0");
	ServerCommand("mp_match_end_restart 0");
	ServerCommand("mp_unpause_match");
	ServerCommand("mp_warmup_start");

	Announce("Warmup. Type \x04!ready\x01 when you're ready. \x04!help\x01 lists commands.");
}

void StartMatch()
{
	if (g_VetoRunning)
		return;
	// Best of 3: vote on the maps first (players are already ready).
	if (WantSeries() && !g_SeriesActive && StartVeto())
		return;
	SeriesApplyTeamNames();
	if (g_KnifeEnabled)
		StartKnife();
	else
		StartLive();
}

void StartKnife()
{
	g_State = State_Knife;
	g_KnifeActive = false;

	ServerCommand("mp_unpause_match");
	ServerCommand("mp_warmup_end");
	ServerCommand("exec csgo_match/knife.cfg");
	ServerCommand("mp_restartgame 1");

	Announce("\x02KNIFE ROUND\x01 — the winners choose their side.");
}

void StartLive()
{
	g_State = State_Live;
	g_Paused = false;
	for (int t = 0; t < 4; t++)
	{
		g_UnpauseReq[t] = false;
		g_TacPauses[t] = 0;
		g_StopReq[t] = false;
	}

	char stamp[32];
	FormatTime(stamp, sizeof(stamp), "%Y%m%d_%H%M%S");
	Format(g_BackupPrefix, sizeof(g_BackupPrefix), "match_%s", stamp);

	ServerCommand("mp_unpause_match");
	ServerCommand("mp_warmup_end");
	ServerCommand("exec csgo_match/live.cfg");
	if (IsWingman())
		ServerCommand("exec csgo_match/wingman.cfg");
	if (g_OneVOneNext)
		ServerCommand("exec csgo_match/1v1.cfg");
	if (g_cvMaxRounds.IntValue > 0)
		ServerCommand("mp_maxrounds %d", g_cvMaxRounds.IntValue);
	if (g_cvOvertime.IntValue >= 0)
		ServerCommand("mp_overtime_enable %d", g_cvOvertime.IntValue);
	if (g_cvFriendlyFire.IntValue >= 0)
		ServerCommand("mp_friendlyfire %d", g_cvFriendlyFire.IntValue);
	ServerCommand("mp_backup_round_file \"%s\"", g_BackupPrefix);
	// Only mp_maxrounds ends a match; the plugin handles what comes next.
	ServerCommand("mp_timelimit 0");
	ServerCommand("mp_endmatch_votenextmap 0");
	ServerCommand("mp_match_end_changelevel 0");
	ServerCommand("mp_match_end_restart 0");
	ServerCommand("mp_restartgame 3");

	StartDemo(stamp);
	CreateTimer(4.5, Timer_LiveMessage, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_LiveMessage(Handle timer)
{
	if (g_State == State_Live)
	{
		SeriesApplyTeamNames(); // after any knife-round side swap
		for (int i = 0; i < 3; i++)
			Announce("\x04LIVE! LIVE! LIVE!\x01");
		if (g_SeriesActive)
			Announce("Best of 3 — map %d: \x04%s\x01 | %s %d - %d %s", g_SeriesMapIndex + 1, g_SeriesMaps[g_SeriesMapIndex],
				g_SeriesName[SERIES_TEAM_A], g_SeriesWins[SERIES_TEAM_A], g_SeriesWins[SERIES_TEAM_B], g_SeriesName[SERIES_TEAM_B]);
		Announce("GL HF! \x04!pause\x01 / \x04!tech\x01 / \x04!tac\x01 / \x04!stop\x01 available.");
	}
	return Plugin_Stop;
}

void CheckReady()
{
	if (g_State != State_Warmup)
		return;

	int ready;
	int total = CountPlayers(ready);
	if (total > 0 && ready >= RequiredReady(total))
	{
		if (WantSeries() && !g_SeriesActive)
			Announce("Everyone's ready — starting the map vote!");
		else
			Announce("Everyone's ready — starting the match!");
		StartMatch();
	}
}

int CountPlayers(int &ready)
{
	ready = 0;
	int total = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || IsFakeClient(i))
			continue;
		int team = GetClientTeam(i);
		if (team != CS_TEAM_T && team != CS_TEAM_CT)
			continue;
		total++;
		if (g_Ready[i])
			ready++;
	}
	return total;
}

int RequiredReady(int total)
{
	if (g_OneVOneNext)
		return 2;
	int r = g_cvReadyRequired.IntValue;
	if (r <= 0)
		return total;
	if (IsWingman() && r > 4)
		r = 4;
	return r;
}

/* ------------------------------------------------------------------ */
/*  Player commands                                                   */
/* ------------------------------------------------------------------ */

void Cmd_Ready(int client, bool ready)
{
	if (!CheckInGame(client))
		return;
	if (g_State != State_Warmup)
	{
		if (g_State == State_None && !IsMatchMode())
		{
			char mode[32];
			GetModeName(mode, sizeof(mode));
			Reply(client, "The server is in %s mode — no ready-up needed. Admins can switch with \x04!gamemode\x01.", mode);
		}
		else
		{
			Reply(client, "Ready status only matters during warmup.");
		}
		return;
	}
	if (!IsOnPlayingTeam(client))
	{
		Reply(client, "Join a team first.");
		return;
	}
	if (g_Ready[client] == ready)
	{
		if (ready)
			Reply(client, "You're already ready.");
		else
			Reply(client, "You're already marked as not ready.");
		return;
	}

	g_Ready[client] = ready;

	int r;
	int total = CountPlayers(r);
	if (ready)
		Announce("%N is \x04ready\x01 (%d/%d)", client, r, RequiredReady(total));
	else
		Announce("%N is \x02not ready\x01 (%d/%d)", client, r, RequiredReady(total));

	if (ready)
		CheckReady();
}

void Cmd_Side(int client, int mode) // 0 = stay, 1 = switch, CS_TEAM_T / CS_TEAM_CT = pick that side
{
	if (!CheckInGame(client))
		return;
	if (g_State != State_SideSelect)
	{
		Reply(client, "There's no side to pick right now.");
		return;
	}
	if (GetClientTeam(client) != g_KnifeWinner)
	{
		Reply(client, "Only the team that won the knife round can choose.");
		return;
	}

	bool swap;
	if (mode == 0)
		swap = false;
	else if (mode == 1)
		swap = true;
	else
		swap = (mode != g_KnifeWinner);

	if (swap)
		Announce("%N chose to \x04switch\x01 sides.", client);
	else
		Announce("%N chose to \x04stay\x01.", client);

	ApplySide(swap);
}

void ApplySide(bool swap)
{
	delete g_SideTimer;
	if (swap)
		ServerCommand("mp_swapteams");
	StartLive();
}

public Action Timer_SideTimeout(Handle timer)
{
	g_SideTimer = null;
	if (g_State == State_SideSelect)
	{
		Announce("No side was picked in time — teams \x04stay\x01.");
		ApplySide(false);
	}
	return Plugin_Stop;
}

void Cmd_Pause(int client, bool tech)
{
	if (!CheckInGame(client))
		return;
	if (g_State != State_Live)
	{
		Reply(client, "You can only pause during a live match.");
		return;
	}
	if (!IsOnPlayingTeam(client))
	{
		Reply(client, "Spectators can't pause.");
		return;
	}
	if (g_Paused)
	{
		Reply(client, "The match is already paused.");
		return;
	}

	int team = GetClientTeam(client);
	if (!tech)
	{
		int max = g_cvMaxPauses.IntValue;
		if (max > 0 && g_TacPauses[team] >= max)
		{
			Reply(client, "Your team has no tactical pauses left (%d/%d used). Use \x04!tech\x01 for technical issues.", g_TacPauses[team], max);
			return;
		}
		g_TacPauses[team]++;
	}

	g_Paused = true;
	g_UnpauseReq[CS_TEAM_T] = false;
	g_UnpauseReq[CS_TEAM_CT] = false;

	ServerCommand("mp_pause_match");

	if (tech)
		Announce("%N called a \x02technical\x01 pause. It starts at the next freezetime. Both teams type \x04!unpause\x01 to resume.", client);
	else
		Announce("%N called a \x09tactical\x01 pause. It starts at the next freezetime. Both teams type \x04!unpause\x01 to resume.", client);
}

void Cmd_Unpause(int client)
{
	if (!CheckInGame(client))
		return;
	if (!g_Paused)
	{
		Reply(client, "The match isn't paused.");
		return;
	}
	if (!IsOnPlayingTeam(client))
	{
		Reply(client, "Spectators can't unpause.");
		return;
	}

	if (!g_cvBothUnpause.BoolValue)
	{
		Announce("%N unpaused the match.", client);
		DoUnpause();
		return;
	}

	int team = GetClientTeam(client);
	if (g_UnpauseReq[team])
	{
		Reply(client, "Your team is already ready — waiting for the other team.");
		return;
	}

	g_UnpauseReq[team] = true;
	if (g_UnpauseReq[OtherTeam(team)])
	{
		Announce("Both teams are ready — unpausing!");
		DoUnpause();
	}
	else if (team == CS_TEAM_T)
	{
		Announce("\x09T\x01 side is ready to unpause. Waiting for \x0BCT\x01 to type \x04!unpause\x01.");
	}
	else
	{
		Announce("\x0BCT\x01 side is ready to unpause. Waiting for \x09T\x01 to type \x04!unpause\x01.");
	}
}

void DoUnpause()
{
	ServerCommand("mp_unpause_match");
	g_Paused = false;
	g_UnpauseReq[CS_TEAM_T] = false;
	g_UnpauseReq[CS_TEAM_CT] = false;
}

void Cmd_Tac(int client)
{
	if (!CheckInGame(client))
		return;
	if (g_State != State_Live)
	{
		Reply(client, "Timeouts are only available during a live match.");
		return;
	}
	int team = GetClientTeam(client);
	if (team == CS_TEAM_T)
		ServerCommand("timeout_terrorist_start");
	else if (team == CS_TEAM_CT)
		ServerCommand("timeout_ct_start");
	else
	{
		Reply(client, "Spectators can't call timeouts.");
		return;
	}
	Announce("%N called a tactical timeout (starts at freezetime).", client);
}

void Cmd_Stop(int client)
{
	if (!CheckInGame(client))
		return;
	if (!g_cvStopEnabled.BoolValue)
	{
		Reply(client, "!stop is disabled on this server.");
		return;
	}
	if (g_State != State_Live)
	{
		Reply(client, "!stop only works during a live match.");
		return;
	}
	if (!IsOnPlayingTeam(client))
	{
		Reply(client, "Spectators can't use !stop.");
		return;
	}

	int team = GetClientTeam(client);
	if (g_StopReq[team])
	{
		Reply(client, "Your team already asked — waiting for the other team to type \x04!stop\x01.");
		return;
	}

	g_StopReq[team] = true;
	if (!g_StopReq[OtherTeam(team)])
	{
		Announce("%N wants to restart this round. The other team must type \x04!stop\x01 to confirm.", client);
		return;
	}

	RestoreLastRound();
}

void RestoreLastRound()
{
	char file[PLATFORM_MAX_PATH];
	ConVar cv = FindConVar("mp_backup_round_file_last");
	if (cv != null)
		cv.GetString(file, sizeof(file));

	if (file[0] == '\0')
	{
		Announce("No round backup exists yet — can't restore.");
		g_StopReq[CS_TEAM_T] = false;
		g_StopReq[CS_TEAM_CT] = false;
		return;
	}
	RestoreFile(file);
}

void RestoreFile(const char[] file)
{
	ServerCommand("mp_backup_restore_load_file \"%s\"", file);
	ServerCommand("mp_pause_match");

	g_Paused = true;
	g_UnpauseReq[CS_TEAM_T] = false;
	g_UnpauseReq[CS_TEAM_CT] = false;
	g_StopReq[CS_TEAM_T] = false;
	g_StopReq[CS_TEAM_CT] = false;

	Announce("Round restored (%s). Match is paused — both teams type \x04!unpause\x01 when set.", file);
}

void Cmd_Help(int client)
{
	Reply(client, "\x04Players:\x01 !ready !unready !pause !tech !unpause !tac !stop !status");
	Reply(client, "\x04Knife winners:\x01 !stay !switch !t !ct");
	if (IsAdmin(client))
	{
		Reply(client, "\x04Admin:\x01 !start !restart !knifetoggle !forceready !fup !team1 <name> !team2 <name>");
		Reply(client, "\x04Admin:\x01 !readyrequired <n> !restore <n> !prac !exitprac");
	}
	Reply(client, "\x04Practice:\x01 !spawn <n> !clear !god");
	Reply(client, "\x04 1v1:\x01 !1v1 (all 1v1 modes) !duel [name] !accept !decline !forfeit");
	if (g_State == State_Arena)
		Reply(client, "\x04Arenas:\x01 !guns !sitout !rank");
	if (IsAdmin(client))
		Reply(client, "\x04Modes:\x01 !gamemode (all game modes)  !options (match settings)");
	else
		Reply(client, "\x04Modes:\x01 !gamemode shows the current mode");
	if (IsAdmin(client))
		Reply(client, "\x04Best of 3:\x01 !bo3 (turn on) !bo1 (single map) !series (maps + score) !endseries");
	else
		Reply(client, "\x04Best of 3:\x01 !series shows the maps and score");
	Reply(client, "Every command also works with a dot, e.g. .ready");
}

void Cmd_Status(int client)
{
	int ready;
	int total = CountPlayers(ready);
	char state[32];
	switch (g_State)
	{
		case State_Warmup:     strcopy(state, sizeof(state), "Warmup");
		case State_Knife:      strcopy(state, sizeof(state), "Knife round");
		case State_SideSelect: strcopy(state, sizeof(state), "Side selection");
		case State_Live:       strcopy(state, sizeof(state), "Live");
		case State_Practice:   strcopy(state, sizeof(state), "Practice");
		case State_Duel:       strcopy(state, sizeof(state), "1v1 duel");
		default:               strcopy(state, sizeof(state), "Idle");
	}

	char knife[8], paused[8];
	if (g_KnifeEnabled)
		strcopy(knife, sizeof(knife), "on");
	else
		strcopy(knife, sizeof(knife), "off");
	if (g_Paused)
		strcopy(paused, sizeof(paused), "yes");
	else
		strcopy(paused, sizeof(paused), "no");

	char mode[32];
	GetModeName(mode, sizeof(mode));
	Reply(client, "Mode: \x04%s\x01 | State: \x04%s\x01 | Ready: %d/%d | Knife: %s | Paused: %s",
		mode, state, ready, RequiredReady(total), knife, paused);
	if (g_VetoRunning)
		Reply(client, "Best of 3: map vote in progress.");
	else if (g_SeriesActive)
		Cmd_Series(client);
	else if (WantSeries())
		Reply(client, "Best of 3 is on — the map vote starts when everyone is ready.");
}

/* ------------------------------------------------------------------ */
/*  Admin commands                                                    */
/* ------------------------------------------------------------------ */

void Cmd_ForceStart(int client)
{
	if (!RequireAdmin(client))
		return;
	if (g_State != State_Warmup)
	{
		Reply(client, "The match can only be force-started from warmup.");
		return;
	}
	Announce("%N force-started the match.", client);
	StartMatch();
}

void Cmd_Restart(int client)
{
	if (!RequireAdmin(client))
		return;
	Announce("%N reset the match — back to warmup.", client);
	StartWarmup();
}

void Cmd_Knife(int client)
{
	if (!RequireAdmin(client))
		return;
	if (g_State != State_Warmup)
	{
		Reply(client, "Change the knife setting during warmup.");
		return;
	}
	g_KnifeEnabled = !g_KnifeEnabled;
	if (g_KnifeEnabled)
		Announce("Knife round \x04enabled\x01.");
	else
		Announce("Knife round \x02disabled\x01 — teams keep their current sides.");
}

void Cmd_ForceReady(int client)
{
	if (!RequireAdmin(client))
		return;
	if (g_State != State_Warmup)
	{
		Reply(client, "Only available during warmup.");
		return;
	}
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i) && IsOnPlayingTeam(i))
			g_Ready[i] = true;
	}
	Announce("%N marked everyone ready.", client);
	StartMatch();
}

void Cmd_ForceUnpause(int client)
{
	if (!RequireAdmin(client))
		return;
	Announce("%N force-unpaused the match.", client);
	DoUnpause();
}

void Cmd_TeamName(int client, int which, const char[] arg)
{
	if (!RequireAdmin(client))
		return;

	char name[64];
	strcopy(name, sizeof(name), arg);
	ReplaceString(name, sizeof(name), "\"", "'");
	ReplaceString(name, sizeof(name), ";", "");
	TrimString(name);

	if (name[0] == '\0')
	{
		Reply(client, "Usage: !team%d <name>", which);
		return;
	}

	ServerCommand("mp_teamname_%d \"%s\"", which, name);
	Announce("Team %d is now \x04%s\x01.", which, name);
}

void Cmd_ReadyRequired(int client, const char[] arg)
{
	if (!RequireAdmin(client))
		return;
	if (arg[0] == '\0')
	{
		Reply(client, "Ready required: %d (0 = everyone). Usage: !readyrequired <n>", g_cvReadyRequired.IntValue);
		return;
	}
	int n = StringToInt(arg);
	if (n < 0)
		n = 0;
	g_cvReadyRequired.IntValue = n;
	if (n == 0)
		Announce("Ready requirement set to \x04everyone on a team\x01.");
	else
		Announce("Ready requirement set to \x04%d\x01 players.", n);
	CheckReady();
}

void Cmd_Restore(int client, const char[] arg)
{
	if (!RequireAdmin(client))
		return;
	if (g_State != State_Live)
	{
		Reply(client, "Restoring only works during a live match.");
		return;
	}
	if (arg[0] == '\0')
	{
		Reply(client, "Usage: !restore <n> — loads <prefix>_round<nn>.txt (round00 = start of the first round).");
		return;
	}

	char prefix[64];
	if (g_BackupPrefix[0] != '\0')
		strcopy(prefix, sizeof(prefix), g_BackupPrefix);
	else
	{
		ConVar cv = FindConVar("mp_backup_round_file");
		if (cv != null)
			cv.GetString(prefix, sizeof(prefix));
	}

	char file[PLATFORM_MAX_PATH];
	Format(file, sizeof(file), "%s_round%02d.txt", prefix, StringToInt(arg));
	if (!FileExists(file))
	{
		Reply(client, "Backup %s not found.", file);
		return;
	}
	RestoreFile(file);
}

void Cmd_Prac(int client)
{
	if (!RequireAdmin(client))
		return;
	if (g_State == State_Live || g_State == State_Knife || g_State == State_SideSelect || g_State == State_Duel)
	{
		Reply(client, "A match or duel is running. Use \x04!restart\x01 first.");
		return;
	}
	g_PracticeNext = true;
	EnterPractice();
}

void EnterPractice()
{
	ResetMatch();
	StopDemo();
	g_State = State_Practice;

	ServerCommand("mp_unpause_match");
	ServerCommand("mp_warmup_end");
	ServerCommand("exec csgo_match/prac.cfg");
	NoGameEnd();
	ServerCommand("mp_restartgame 1");

	Announce("\x04Practice mode\x01 on. !spawn <n>, !clear, !god — !exitprac to leave.");
}

void Cmd_ExitPrac(int client)
{
	if (!RequireAdmin(client))
		return;
	if (g_State != State_Practice)
	{
		Reply(client, "Practice mode isn't on.");
		return;
	}
	Announce("Practice mode off.");
	g_PracticeNext = false;
	ReturnToMode();
}

/* ------------------------------------------------------------------ */
/*  Practice commands                                                 */
/* ------------------------------------------------------------------ */

void Cmd_Clear(int client)
{
	if (!RequirePractice(client))
		return;

	char classes[][] =
	{
		"smokegrenade_projectile", "molotov_projectile", "incgrenade_projectile",
		"inferno", "decoy_projectile", "flashbang_projectile", "hegrenade_projectile"
	};

	int removed = 0;
	for (int c = 0; c < sizeof(classes); c++)
	{
		int ent = -1;
		while ((ent = FindEntityByClassname(ent, classes[c])) != -1)
		{
			AcceptEntityInput(ent, "Kill");
			removed++;
		}
	}
	Announce("%N cleared %d grenade(s).", client, removed);
}

void Cmd_Spawn(int client, const char[] arg)
{
	if (!RequirePractice(client) || !CheckInGame(client))
		return;
	if (!IsPlayerAlive(client) || !IsOnPlayingTeam(client))
	{
		Reply(client, "You need to be alive on a team.");
		return;
	}

	char cls[48];
	if (GetClientTeam(client) == CS_TEAM_T)
		strcopy(cls, sizeof(cls), "info_player_terrorist");
	else
		strcopy(cls, sizeof(cls), "info_player_counterterrorist");

	int want = StringToInt(arg);
	int ent = -1, count = 0, target = -1;
	while ((ent = FindEntityByClassname(ent, cls)) != -1)
	{
		count++;
		if (count == want)
			target = ent;
	}

	if (target == -1)
	{
		Reply(client, "Usage: !spawn <1-%d>", count);
		return;
	}

	float pos[3], ang[3], vel[3];
	GetEntPropVector(target, Prop_Data, "m_vecOrigin", pos);
	GetEntPropVector(target, Prop_Data, "m_angRotation", ang);
	TeleportEntity(client, pos, ang, vel);
	Reply(client, "Teleported to spawn %d/%d.", want, count);
}

void Cmd_God(int client)
{
	if (!RequirePractice(client) || !CheckInGame(client))
		return;
	if (!IsPlayerAlive(client))
	{
		Reply(client, "You need to be alive.");
		return;
	}
	if (GetEntProp(client, Prop_Data, "m_takedamage") == 2)
	{
		SetEntProp(client, Prop_Data, "m_takedamage", 0);
		Reply(client, "God mode \x04on\x01.");
	}
	else
	{
		SetEntProp(client, Prop_Data, "m_takedamage", 2);
		Reply(client, "God mode \x02off\x01.");
	}
}

/* ------------------------------------------------------------------ */
/*  Events                                                            */
/* ------------------------------------------------------------------ */

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	if (g_State == State_Duel)
		CreateTimer(0.3, Timer_DuelRoundStart, _, TIMER_FLAG_NO_MAPCHANGE);
	if (g_State == State_Arena)
		ArenaRoundStart();

	g_StopReq[CS_TEAM_T] = false;
	g_StopReq[CS_TEAM_CT] = false;
}

public void Event_RoundFreezeEnd(Event event, const char[] name, bool dontBroadcast)
{
	if (g_State == State_Knife)
		g_KnifeActive = true;
}

public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
	if (g_State != State_Knife || !g_KnifeActive)
		return;

	g_KnifeActive = false;
	int winner = event.GetInt("winner");

	if (winner != CS_TEAM_T && winner != CS_TEAM_CT)
	{
		Announce("The knife round was a draw — replaying it.");
		ServerCommand("mp_restartgame 3");
		return;
	}

	g_KnifeWinner = winner;
	g_State = State_SideSelect;
	ServerCommand("mp_pause_match");

	int secs = g_cvSideTime.IntValue;
	if (winner == CS_TEAM_T)
		Announce("\x09Terrorists\x01 won the knife round! Type \x04!stay\x01 or \x04!switch\x01 (%ds).", secs);
	else
		Announce("\x0BCounter-Terrorists\x01 won the knife round! Type \x04!stay\x01 or \x04!switch\x01 (%ds).", secs);

	delete g_SideTimer;
	g_SideTimer = CreateTimer(float(secs), Timer_SideTimeout, _, TIMER_FLAG_NO_MAPCHANGE);
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	if (g_State != State_Knife)
		return;
	int userid = event.GetInt("userid");
	CreateTimer(0.1, Timer_StripToKnife, userid, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_StripToKnife(Handle timer, any userid)
{
	int client = GetClientOfUserId(userid);
	if (client == 0 || !IsClientInGame(client) || !IsPlayerAlive(client) || g_State != State_Knife)
		return Plugin_Stop;

	int slots[4] = { 0, 1, 3, 4 }; // primary, secondary, grenades, C4 — keep slot 2 (knife)
	for (int s = 0; s < sizeof(slots); s++)
	{
		int w;
		int guard = 0;
		while ((w = GetPlayerWeaponSlot(client, slots[s])) != -1 && guard++ < 10)
		{
			RemovePlayerItem(client, w);
			AcceptEntityInput(w, "Kill");
		}
	}

	if (GetPlayerWeaponSlot(client, 2) == -1)
		GivePlayerItem(client, "weapon_knife");

	return Plugin_Stop;
}

public void Event_MatchEnd(Event event, const char[] name, bool dontBroadcast)
{
	if (g_State != State_Live)
	{
		// The game ended the match by itself outside a live match (e.g. a time or
		// round limit from another config kicking in when a second player joins).
		// Log why and go back to warmup instead of sitting on the map vote.
		if (g_State == State_Warmup || g_State == State_Knife || g_State == State_SideSelect
			|| (g_State == State_None && IsMatchMode()))
		{
			LogMessage("Unexpected match end in state %d: mp_timelimit=%d mp_maxrounds=%d game_type=%d game_mode=%d players=%d",
				g_State, GetCvarInt("mp_timelimit"), GetCvarInt("mp_maxrounds"), GetCvarInt("game_type"),
				GetCvarInt("game_mode"), GetClientCount(true));
			CreateTimer(3.0, Timer_RecoverWarmup, _, TIMER_FLAG_NO_MAPCHANGE);
		}
		else if (g_State == State_Practice || g_State == State_Arena
			|| g_State == State_Duel)
		{
			LogMessage("Unexpected game end in practice-type mode (state %d): mp_timelimit=%d mp_maxrounds=%d mp_winlimit=%d game_type=%d game_mode=%d",
				g_State, GetCvarInt("mp_timelimit"), GetCvarInt("mp_maxrounds"), GetCvarInt("mp_winlimit"),
				GetCvarInt("game_type"), GetCvarInt("game_mode"));
			CreateTimer(3.0, Timer_RecoverPractice, _, TIMER_FLAG_NO_MAPCHANGE);
		}
		return;
	}

	g_State = State_None;
	g_Paused = false;
	CreateTimer(10.0, Timer_StopDemo, _, TIMER_FLAG_NO_MAPCHANGE);
	if (g_SeriesActive)
	{
		SeriesOnMatchEnd();
		return;
	}
	Announce("Match over — GG! Change map or type \x04!restart\x01 for a new match.");
}

// Practice-type modes never end the game by themselves. (mp_maxrounds 0 is NOT
// "no limit" in CS:GO - the game ends after the first round - so older configs
// written with 0 are overridden here.)
void NoGameEnd()
{
	ServerCommand("mp_maxrounds 999");
	ServerCommand("mp_timelimit 0");
	ServerCommand("mp_winlimit 0");
	ServerCommand("mp_match_can_clinch 0");
	ServerCommand("mp_endmatch_votenextmap 0");
	ServerCommand("mp_match_end_changelevel 0");
	ServerCommand("mp_match_end_restart 0");
}

public Action Timer_RecoverPractice(Handle timer)
{
	if (g_State == State_Live)
		return Plugin_Stop;
	Announce("The game tried to end — restarting it.");
	NoGameEnd();
	ServerCommand("mp_restartgame 1");
	return Plugin_Stop;
}

public Action Timer_RecoverWarmup(Handle timer)
{
	if (g_State == State_Live || g_State == State_Duel || g_State == State_Arena || g_State == State_Practice)
		return Plugin_Stop;
	Announce("The game tried to end the match before it started — back to warmup.");
	ServerCommand("mp_restartgame 1");
	StartWarmup();
	return Plugin_Stop;
}

public Action Timer_StopDemo(Handle timer)
{
	StopDemo();
	return Plugin_Stop;
}

public void Event_PhaseEnd(Event event, const char[] name, bool dontBroadcast)
{
	// Halftime / overtime side swap: pause counters follow the teams, not the sides.
	if (g_State != State_Live)
		return;
	int tmp = g_TacPauses[CS_TEAM_T];
	g_TacPauses[CS_TEAM_T] = g_TacPauses[CS_TEAM_CT];
	g_TacPauses[CS_TEAM_CT] = tmp;
}

/* ------------------------------------------------------------------ */
/*  1v1 aim duel                                                      */
/* ------------------------------------------------------------------ */

bool CanStartDuel(int client)
{
	if (g_State == State_Duel)
	{
		Reply(client, "A duel is already running.");
		return false;
	}
	if (g_State == State_Live || g_State == State_Knife || g_State == State_SideSelect)
	{
		Reply(client, "A match is running. Duels can only start in warmup.");
		return false;
	}
	if (g_State == State_Arena)
	{
		Reply(client, "The server is running 1v1 arenas — you're already dueling!");
		return false;
	}
	return true;
}

void Cmd_Duel(int client, const char[] arg)
{
	if (!CheckInGame(client) || !CanStartDuel(client))
		return;
	if (g_ChalTo != 0)
	{
		Reply(client, "Another challenge is waiting for an answer — try again in a moment.");
		return;
	}

	// Order: gun -> rounds -> headshots only -> opponent.
	g_PickOpponent[client] = 0;
	if (arg[0] != '\0')
	{
		int target = FindDuelTarget(client, arg);
		if (target <= 0)
			return;
		g_PickOpponent[client] = GetClientUserId(target); // opponent already chosen
	}
	ShowDuelWeaponMenu(client);
}

int FindDuelTarget(int client, const char[] name)
{
	int found = 0, count = 0;
	char buf[MAX_NAME_LENGTH];
	for (int i = 1; i <= MaxClients; i++)
	{
		if (i == client || !IsClientInGame(i) || IsFakeClient(i))
			continue;
		GetClientName(i, buf, sizeof(buf));
		if (StrContains(buf, name, false) != -1)
		{
			found = i;
			count++;
		}
	}
	if (count == 0)
		Reply(client, "No player matching \"%s\".", name);
	else if (count > 1)
		Reply(client, "More than one player matches \"%s\" — be more specific, or type !duel for a list.", name);
	return count == 1 ? found : 0;
}

void ShowDuelOpponentMenu(int client)
{
	Menu menu = new Menu(Handler_DuelOpponent);
	menu.SetTitle("1v1 duel — step 4 of 4: choose your opponent\n%s, first to %d%s", g_DuelWepName[g_PickWeapon[client]],
		g_PickTarget[client], g_PickHs[client] ? ", headshots only" : "");
	char info[16], name[MAX_NAME_LENGTH];
	int count = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (i == client || !IsClientInGame(i) || IsFakeClient(i))
			continue;
		IntToString(GetClientUserId(i), info, sizeof(info));
		GetClientName(i, name, sizeof(name));
		menu.AddItem(info, name);
		count++;
	}
	if (count == 0)
	{
		delete menu;
		Reply(client, "Nobody else is on the server to duel.");
		return;
	}
	menu.ExitBackButton = true;
	menu.Display(client, 60);
}

public int Handler_DuelOpponent(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_End)
	{
		delete menu;
	}
	else if (action == MenuAction_Select)
	{
		char info[16];
		menu.GetItem(item, info, sizeof(info));
		g_PickOpponent[client] = StringToInt(info);
		SendChallenge(client, GetClientOfUserId(g_PickOpponent[client]), g_PickWeapon[client], g_PickTarget[client], g_PickHs[client]);
	}
	else if (action == MenuAction_Cancel && item == MenuCancel_ExitBack)
	{
		ShowDuelHsMenu(client);
	}
	return 0;
}

void ShowDuelWeaponMenu(int client)
{
	Menu menu = new Menu(Handler_DuelWeapon);
	menu.SetTitle("1v1 duel — step 1 of 4: gun");
	char info[8];
	for (int i = 0; i < DUEL_WEAPONS; i++)
	{
		IntToString(i, info, sizeof(info));
		menu.AddItem(info, g_DuelWepName[i]);
	}
	menu.ExitBackButton = true;
	menu.Display(client, 60);
}

public int Handler_DuelWeapon(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_End)
	{
		delete menu;
	}
	else if (action == MenuAction_Select)
	{
		char info[8];
		menu.GetItem(item, info, sizeof(info));
		g_PickWeapon[client] = StringToInt(info);
		ShowDuelTargetMenu(client);
	}
	else if (action == MenuAction_Cancel && item == MenuCancel_ExitBack)
	{
		Cmd_OneVOneMenu(client, "");
	}
	return 0;
}

void ShowDuelTargetMenu(int client)
{
	Menu menu = new Menu(Handler_DuelTarget);
	menu.SetTitle("1v1 duel — step 2 of 4: rounds\n%s — first to how many kills?", g_DuelWepName[g_PickWeapon[client]]);
	menu.AddItem("30", "First to 30");
	menu.AddItem("50", "First to 50");
	menu.AddItem("100", "First to 100");
	menu.ExitBackButton = true;
	menu.Display(client, 60);
}

public int Handler_DuelTarget(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_End)
	{
		delete menu;
	}
	else if (action == MenuAction_Select)
	{
		char info[8];
		menu.GetItem(item, info, sizeof(info));
		g_PickTarget[client] = StringToInt(info);
		ShowDuelHsMenu(client);
	}
	else if (action == MenuAction_Cancel && item == MenuCancel_ExitBack)
	{
		ShowDuelWeaponMenu(client);
	}
	return 0;
}

void ShowDuelHsMenu(int client)
{
	bool knives = StrEqual(g_DuelWepCls[g_PickWeapon[client]], "knife");
	Menu menu = new Menu(Handler_DuelHs);
	menu.SetTitle("1v1 duel — step 3 of 4: headshots only?\n%s, first to %d", g_DuelWepName[g_PickWeapon[client]], g_PickTarget[client]);
	menu.AddItem("0", "Normal — every hit counts");
	menu.AddItem("1", knives ? "Headshots only (not with knives)" : "Headshots only", knives ? ITEMDRAW_DISABLED : ITEMDRAW_DEFAULT);
	menu.ExitBackButton = true;
	menu.Display(client, 60);
}

public int Handler_DuelHs(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_End)
	{
		delete menu;
	}
	else if (action == MenuAction_Select)
	{
		char info[8];
		menu.GetItem(item, info, sizeof(info));
		g_PickHs[client] = StrEqual(info, "1");
		int opp = GetClientOfUserId(g_PickOpponent[client]);
		if (opp > 0 && IsClientInGame(opp))
			SendChallenge(client, opp, g_PickWeapon[client], g_PickTarget[client], g_PickHs[client]);
		else
			ShowDuelOpponentMenu(client);
	}
	else if (action == MenuAction_Cancel && item == MenuCancel_ExitBack)
	{
		ShowDuelTargetMenu(client);
	}
	return 0;
}

void SendChallenge(int from, int to, int weapon, int target, bool hs)
{
	if (!CanStartDuel(from))
		return;
	if (to <= 0 || !IsClientInGame(to))
	{
		Reply(from, "That player has left.");
		return;
	}
	if (g_ChalTo != 0)
	{
		Reply(from, "Another challenge is waiting for an answer — try again in a moment.");
		return;
	}

	g_ChalFrom = GetClientUserId(from);
	g_ChalTo = GetClientUserId(to);
	g_ChalWeapon = weapon;
	g_ChalTarget = target;
	g_ChalHs = hs;
	delete g_ChalTimer;
	g_ChalTimer = CreateTimer(30.0, Timer_ChallengeExpire, _, TIMER_FLAG_NO_MAPCHANGE);

	Announce("%N challenged %N to a 1v1: \x04%s\x01, first to \x04%d\x01%s.", from, to, g_DuelWepName[weapon], target, hs ? ", \x02headshots only\x01" : "");
	PrintToChat(to, "%sType \x04!accept\x01 or \x04!decline\x01 (30 seconds).", PREFIX);

	Menu menu = new Menu(Handler_DuelAnswer);
	menu.SetTitle("%N challenges you to a 1v1\n%s, first to %d kills%s", from, g_DuelWepName[weapon], target, hs ? "\nHeadshots only" : "");
	menu.AddItem("yes", "Accept");
	menu.AddItem("no", "Decline");
	menu.ExitButton = false;
	menu.Display(to, 30);
}

public int Handler_DuelAnswer(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_End)
	{
		delete menu;
	}
	else if (action == MenuAction_Select)
	{
		char info[8];
		menu.GetItem(item, info, sizeof(info));
		Cmd_DuelAnswer(client, StrEqual(info, "yes"));
	}
	return 0;
}

public Action Timer_ChallengeExpire(Handle timer)
{
	g_ChalTimer = null;
	if (g_ChalTo != 0)
	{
		Announce("The 1v1 challenge expired.");
		ClearChallenge();
	}
	return Plugin_Stop;
}

void ClearChallenge()
{
	g_ChalFrom = 0;
	g_ChalTo = 0;
	delete g_ChalTimer;
}

void Cmd_DuelAnswer(int client, bool accept)
{
	if (!CheckInGame(client))
		return;
	if (g_ChalTo == 0 || GetClientOfUserId(g_ChalTo) != client)
	{
		Reply(client, "Nobody has challenged you.");
		return;
	}

	int from = GetClientOfUserId(g_ChalFrom);
	if (!accept)
	{
		Announce("%N declined the 1v1.", client);
		ClearChallenge();
		return;
	}
	if (from <= 0 || !IsClientInGame(from))
	{
		Reply(client, "The player who challenged you has left.");
		ClearChallenge();
		return;
	}
	if (!CanStartDuel(client))
	{
		ClearChallenge();
		return;
	}

	int weapon = g_ChalWeapon, target = g_ChalTarget;
	bool hs = g_ChalHs;
	ClearChallenge();
	StartDuel(from, client, weapon, target, hs);
}

void StartDuel(int a, int b, int weapon, int target, bool hs)
{
	ResetMatch();
	StopDemo();
	g_State = State_Duel;
	g_cvDuelActive.BoolValue = true;

	g_DuelA = GetClientUserId(a);
	g_DuelB = GetClientUserId(b);
	g_DuelScoreA = 0;
	g_DuelScoreB = 0;
	g_DuelWeapon = weapon;
	g_DuelTarget = target;
	g_DuelHs = hs && !StrEqual(g_DuelWepCls[weapon], "knife");
	g_DuelRoundOver = true;   // team changes below kill players; don't count those
	g_DuelPlaced = false;

	ServerCommand("mp_unpause_match");
	ServerCommand("mp_warmup_end");
	ServerCommand("exec csgo_match/duel.cfg");
	NoGameEnd();
	ServerCommand("mp_restartgame 1");

	// Everyone else watches.
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || i == a || i == b)
			continue;
		if (GetClientTeam(i) == CS_TEAM_T || GetClientTeam(i) == CS_TEAM_CT)
			ChangeClientTeam(i, CS_TEAM_SPECTATOR);
	}
	if (GetClientTeam(a) != CS_TEAM_T)
		ChangeClientTeam(a, CS_TEAM_T);
	if (GetClientTeam(b) != CS_TEAM_CT)
		ChangeClientTeam(b, CS_TEAM_CT);

	Announce("\x04 1v1:\x01 %N vs %N — %s, first to %d. Good luck!", a, b, g_DuelWepName[weapon], target);
	// The restart above starts a fresh round (see Event_RoundStart); this is a fallback.
	CreateTimer(4.0, Timer_DuelFirstRound, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_DuelFirstRound(Handle timer)
{
	if (g_State == State_Duel && !g_DuelPlaced)
		DuelNewRound();
	return Plugin_Stop;
}

bool GetDuelists(int &a, int &b)
{
	a = GetClientOfUserId(g_DuelA);
	b = GetClientOfUserId(g_DuelB);
	return a > 0 && b > 0 && IsClientInGame(a) && IsClientInGame(b);
}

bool IsDuelist(int client)
{
	if (g_State != State_Duel || client <= 0)
		return false;
	int userid = GetClientUserId(client);
	return userid == g_DuelA || userid == g_DuelB;
}

void DuelNewRound()
{
	int a, b;
	if (!GetDuelists(a, b))
	{
		EndDuel("A duelist left — duel cancelled.");
		return;
	}

	g_DuelRoundOver = false;
	g_DuelPlaced = true;
	g_DuelSerial++;
	UpdateDuelScore();

	if (StrEqual(g_DuelWepCls[g_DuelWeapon], "random"))
		g_DuelRoundWeapon = GetRandomInt(0, DUEL_WEAPONS - 3); // any real gun
	else
		g_DuelRoundWeapon = g_DuelWeapon;

	if (!IsPlayerAlive(a))
		CS_RespawnPlayer(a);
	if (!IsPlayerAlive(b))
		CS_RespawnPlayer(b);

	// Give the spawn a moment to finish before placing and arming players.
	CreateTimer(0.2, Timer_DuelPlace, g_DuelSerial, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_DuelPlace(Handle timer, int serial)
{
	if (g_State != State_Duel || serial != g_DuelSerial)
		return Plugin_Stop;

	int a, b;
	if (!GetDuelists(a, b))
	{
		EndDuel("A duelist left — duel cancelled.");
		return Plugin_Stop;
	}
	if (!IsPlayerAlive(a) || !IsPlayerAlive(b))
	{
		DuelNewRound();
		return Plugin_Stop;
	}

	float posA[3], posB[3];
	PickDuelSpots(posA, posB);

	float dir[3], angA[3], angB[3], zero[3];
	SubtractVectors(posB, posA, dir);
	GetVectorAngles(dir, angA);
	angA[0] = 0.0;
	angB[1] = angA[1] + 180.0;

	TeleportEntity(a, posA, angA, zero);
	TeleportEntity(b, posB, angB, zero);

	ArmDuelist(a);
	ArmDuelist(b);

	if (g_DuelWeapon != g_DuelRoundWeapon)
		PrintToChatAll("%sThis round: \x04%s", PREFIX, g_DuelWepName[g_DuelRoundWeapon]);

	// Short freeze so both players start at the same time.
	FreezeDuelist(a, true);
	FreezeDuelist(b, true);
	CreateTimer(1.0, Timer_DuelGo, serial, TIMER_FLAG_NO_MAPCHANGE);
	return Plugin_Stop;
}

public Action Timer_DuelGo(Handle timer, int serial)
{
	if (g_State != State_Duel || serial != g_DuelSerial)
		return Plugin_Stop;
	int a, b;
	if (GetDuelists(a, b))
	{
		FreezeDuelist(a, false);
		FreezeDuelist(b, false);
		PrintCenterText(a, "FIGHT!");
		PrintCenterText(b, "FIGHT!");
	}
	return Plugin_Stop;
}

void FreezeDuelist(int client, bool freeze)
{
	if (!IsClientInGame(client) || !IsPlayerAlive(client))
		return;
	SetEntityMoveType(client, freeze ? MOVETYPE_NONE : MOVETYPE_WALK);
	if (freeze)
		SetEntPropFloat(client, Prop_Send, "m_flNextAttack", GetGameTime() + 1.0);
}

void ArmDuelist(int client)
{
	// Strip everything.
	int size = GetEntPropArraySize(client, Prop_Send, "m_hMyWeapons");
	for (int i = 0; i < size; i++)
	{
		int wep = GetEntPropEnt(client, Prop_Send, "m_hMyWeapons", i);
		if (wep != -1 && IsValidEntity(wep))
		{
			RemovePlayerItem(client, wep);
			AcceptEntityInput(wep, "KillHierarchy");
		}
	}

	SetEntityHealth(client, 100);
	SetEntProp(client, Prop_Send, "m_ArmorValue", 100);
	SetEntProp(client, Prop_Send, "m_bHasHelmet", 1);

	GivePlayerItem(client, "weapon_knife");
	if (!StrEqual(g_DuelWepCls[g_DuelRoundWeapon], "knife"))
	{
		GivePlayerItem(client, g_DuelWepCls[g_DuelRoundWeapon]);
		FakeClientCommandEx(client, "use %s", g_DuelWepCls[g_DuelRoundWeapon]);
	}
	else
	{
		FakeClientCommandEx(client, "use weapon_knife");
	}
}

/* Picks two spots that can see each other, using the map's deathmatch
   spawns when it has them, otherwise the normal team spawns. */
void PickDuelSpots(float posA[3], float posB[3])
{
	ArrayList spots = new ArrayList(3);
	CollectSpots(spots, "info_deathmatch_spawn");
	if (spots.Length < 2)
	{
		CollectSpots(spots, "info_player_terrorist");
		CollectSpots(spots, "info_player_counterterrorist");
	}

	if (spots.Length < 2)
	{
		// Shouldn't happen on a real map; fall back to the duelists' own spawns.
		int a, b;
		GetDuelists(a, b);
		GetClientAbsOrigin(a, posA);
		GetClientAbsOrigin(b, posB);
		delete spots;
		return;
	}

	float p1[3], p2[3];
	bool found = false;
	int bestI = 0, bestJ = 1;

	for (int attempt = 0; attempt < 300 && !found; attempt++)
	{
		int i = GetRandomInt(0, spots.Length - 1);
		int j = GetRandomInt(0, spots.Length - 1);
		if (i == j)
			continue;
		spots.GetArray(i, p1);
		spots.GetArray(j, p2);

		float dist = GetVectorDistance(p1, p2);
		if (dist < 350.0 || dist > 2000.0)
			continue;
		if (!CanSee(p1, p2))
			continue;

		bestI = i;
		bestJ = j;
		found = true;
	}

	if (!found)
	{
		// No visible pair — use any two spots that aren't on top of each other.
		for (int attempt = 0; attempt < 100; attempt++)
		{
			bestI = GetRandomInt(0, spots.Length - 1);
			bestJ = GetRandomInt(0, spots.Length - 1);
			if (bestI == bestJ)
				continue;
			spots.GetArray(bestI, p1);
			spots.GetArray(bestJ, p2);
			if (GetVectorDistance(p1, p2) > 300.0)
				break;
		}
	}

	spots.GetArray(bestI, posA);
	spots.GetArray(bestJ, posB);
	delete spots;
}

void CollectSpots(ArrayList list, const char[] cls)
{
	int ent = -1;
	float pos[3];
	while ((ent = FindEntityByClassname(ent, cls)) != -1)
	{
		GetEntPropVector(ent, Prop_Data, "m_vecOrigin", pos);
		list.PushArray(pos);
	}
}

bool CanSee(const float a[3], const float b[3])
{
	float eyeA[3], eyeB[3];
	eyeA = a;
	eyeB = b;
	eyeA[2] += 64.0;
	eyeB[2] += 64.0;
	Handle tr = TR_TraceRayFilterEx(eyeA, eyeB, MASK_VISIBLE, RayType_EndPoint, TraceFilter_NoPlayers);
	bool hit = TR_DidHit(tr);
	delete tr;
	return !hit;
}

public bool TraceFilter_NoPlayers(int entity, int contentsMask)
{
	return entity > MaxClients;
}

public void Event_DuelDeath(Event event, const char[] name, bool dontBroadcast)
{
	if (g_State == State_Arena)
	{
		ArenaOnDeath(event.GetInt("userid"));
		return;
	}
	if (g_State != State_Duel || g_DuelRoundOver)
		return;

	int victim = event.GetInt("userid");
	if (victim != g_DuelA && victim != g_DuelB)
		return;

	g_DuelRoundOver = true;

	// Any death (including suicide or falling) gives the point to the other duelist.
	if (victim == g_DuelA)
		g_DuelScoreB++;
	else
		g_DuelScoreA++;

	UpdateDuelScore();

	int a, b;
	if (!GetDuelists(a, b))
		return;

	if (g_DuelScoreA >= g_DuelTarget || g_DuelScoreB >= g_DuelTarget)
	{
		int winner = (g_DuelScoreA >= g_DuelTarget) ? a : b;
		int loser = (winner == a) ? b : a;
		Announce("\x04%N\x01 wins the 1v1 against %N, \x04%d - %d\x01! GG", winner, loser,
			winner == a ? g_DuelScoreA : g_DuelScoreB, winner == a ? g_DuelScoreB : g_DuelScoreA);
		CreateTimer(4.0, Timer_DuelFinished, g_DuelSerial, TIMER_FLAG_NO_MAPCHANGE);
		return;
	}

	CreateTimer(1.5, Timer_DuelNextRound, g_DuelSerial, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_DuelRoundStart(Handle timer)
{
	if (g_State == State_Duel)
		DuelNewRound();
	return Plugin_Stop;
}

public Action Timer_DuelNextRound(Handle timer, int serial)
{
	if (g_State == State_Duel && serial == g_DuelSerial)
		DuelNewRound();
	return Plugin_Stop;
}

public Action Timer_DuelFinished(Handle timer, int serial)
{
	if (g_State == State_Duel && serial == g_DuelSerial)
		EndDuel("");
	return Plugin_Stop;
}

void UpdateDuelScore()
{
	int a, b;
	if (!GetDuelists(a, b))
		return;

	CS_SetTeamScore(CS_TEAM_T, g_DuelScoreA);
	SetTeamScore(CS_TEAM_T, g_DuelScoreA);
	CS_SetTeamScore(CS_TEAM_CT, g_DuelScoreB);
	SetTeamScore(CS_TEAM_CT, g_DuelScoreB);

	PrintHintTextToAll("%N  %d - %d  %N\nFirst to %d%s", a, g_DuelScoreA, g_DuelScoreB, b, g_DuelTarget, g_DuelHs ? " · headshots only" : "");
}

void Cmd_EndDuel(int client)
{
	if (g_State != State_Duel)
	{
		Reply(client, "No duel is running.");
		return;
	}
	if (client != 0 && !IsDuelist(client) && !IsAdmin(client))
	{
		Reply(client, "Only the duelists or an admin can end the duel.");
		return;
	}

	if (IsDuelist(client))
	{
		int a, b;
		GetDuelists(a, b);
		int other = (client == a) ? b : a;
		if (other > 0)
			Announce("%N forfeited — \x04%N\x01 wins the 1v1.", client, other);
		EndDuel("");
	}
	else
	{
		EndDuel("An admin ended the duel.");
	}
}

void EndDuel(const char[] reason)
{
	if (g_State != State_Duel)
		return;
	if (reason[0] != '\0')
		Announce("%s", reason);
	if (IsMatchMode())
	{
		StartWarmup(); // runs DuelCleanup()
		Announce("Back to warmup. Spectators can join a team again.");
	}
	else
	{
		DuelCleanup();
		Announce("Duel over — reloading the map for the current game mode.");
		ReturnToMode();
	}
}

void DuelCleanup()
{
	ClearChallenge();
	if (g_cvDuelActive != null)
		g_cvDuelActive.BoolValue = false;

	int a = GetClientOfUserId(g_DuelA);
	int b = GetClientOfUserId(g_DuelB);
	if (a > 0 && IsClientInGame(a) && IsPlayerAlive(a))
		SetEntityMoveType(a, MOVETYPE_WALK);
	if (b > 0 && IsClientInGame(b) && IsPlayerAlive(b))
		SetEntityMoveType(b, MOVETYPE_WALK);

	g_DuelA = 0;
	g_DuelB = 0;
	g_DuelSerial++;

	if (g_State == State_Duel)
	{
		g_State = State_None;
		CS_SetTeamScore(CS_TEAM_T, 0);
		SetTeamScore(CS_TEAM_T, 0);
		CS_SetTeamScore(CS_TEAM_CT, 0);
		SetTeamScore(CS_TEAM_CT, 0);
		// Undo duel-only settings that warmup.cfg doesn't set itself.
		ServerCommand("mp_ignore_round_win_conditions 0");
		ServerCommand("mp_roundtime 1.92");
		ServerCommand("mp_roundtime_defuse 1.92");
		ServerCommand("mp_roundtime_hostage 1.92");
		ServerCommand("mp_freezetime 15");
		ServerCommand("mp_buytime 20");
		ServerCommand("mp_respawn_immunitytime 4");
		ServerCommand("mp_death_drop_gun 1");
		ServerCommand("mp_death_drop_grenade 2");
		ServerCommand("mp_death_drop_defuser 1");
		ServerCommand("mp_maxrounds 30");
		ServerCommand("mp_halftime 1");
	}
}

void DuelOnDisconnect(int client)
{
	if (!IsClientInGame(client))
		return;
	int userid = GetClientUserId(client);

	if (g_ChalTo != 0 && (userid == g_ChalFrom || userid == g_ChalTo))
	{
		Announce("The 1v1 challenge was cancelled (player left).");
		ClearChallenge();
	}
	if (IsDuelist(client))
	{
		Announce("%N left — duel cancelled.", client);
		// Defer so we don't change teams/state mid-disconnect.
		RequestFrame(Frame_EndDuelAfterLeave, g_DuelSerial);
	}
}

public void Frame_EndDuelAfterLeave(int serial)
{
	if (g_State == State_Duel)
		EndDuel("");
}

public Action Listener_JoinTeam(int client, const char[] command, int argc)
{
	if (client <= 0 || !IsClientInGame(client))
		return Plugin_Continue;
	if (g_State == State_Arena)
		return ArenaJoinTeam(client);
	if (g_OneVOneNext && g_State != State_Duel)
		return OneVOneJoinTeam(client);
	if (g_State != State_Duel)
		return SeriesJoinTeam(client);

	char arg[8];
	GetCmdArg(1, arg, sizeof(arg));
	int team = StringToInt(arg);

	if (IsDuelist(client))
	{
		PrintToChat(client, "%sYou're in a duel. Type \x04!forfeit\x01 to leave it.", PREFIX);
		return Plugin_Handled;
	}
	if (team != CS_TEAM_SPECTATOR)
	{
		PrintToChat(client, "%sA 1v1 duel is running — you can spectate until it ends.", PREFIX);
		if (GetClientTeam(client) != CS_TEAM_SPECTATOR)
			ChangeClientTeam(client, CS_TEAM_SPECTATOR);
		return Plugin_Handled;
	}
	return Plugin_Continue;
}

public void Event_DuelTeam(Event event, const char[] name, bool dontBroadcast)
{
	if (g_State != State_Duel || event.GetBool("disconnect"))
		return;
	int client = GetClientOfUserId(event.GetInt("userid"));
	int team = event.GetInt("team");
	if (client <= 0 || IsDuelist(client) || IsFakeClient(client))
		return;
	if (team == CS_TEAM_T || team == CS_TEAM_CT)
		RequestFrame(Frame_MoveToSpec, GetClientUserId(client));
}

public void Frame_MoveToSpec(int userid)
{
	int client = GetClientOfUserId(userid);
	if (client > 0 && IsClientInGame(client) && g_State == State_Duel && !IsDuelist(client)
		&& GetClientTeam(client) != CS_TEAM_SPECTATOR)
	{
		ChangeClientTeam(client, CS_TEAM_SPECTATOR);
	}
}

/* ------------------------------------------------------------------ */
/*  Game modes (!gamemode) and match options (!options)                */
/* ------------------------------------------------------------------ */

enum
{
	GM_Competitive = 0,
	GM_Wingman,
	GM_Casual,
	GM_Deathmatch,
	GM_ArmsRace,
	GM_Demolition,
	GM_Practice,
	GM_1v1Match,
	GM_Arena,
	GM_COUNT
};

char g_GmName[GM_COUNT][] = { "Competitive 5v5", "Wingman 2v2", "Casual", "Deathmatch", "Arms Race", "Demolition", "Practice", "1v1 match", "Multi-1v1 arenas" };
int  g_GmType[GM_COUNT]   = { 0, 0, 0, 1, 1, 1, 0, 0, 0 };
int  g_GmMode[GM_COUNT]   = { 1, 2, 0, 2, 0, 1, 1, 1, 0 };
// Each mode has its own map folder: csgo/maps/modes/<folder>/
// Standard maps written to maps/modes/<folder>/maplist.txt if that file is missing.
char g_GmDefaultMaps[GM_COUNT][] =
{
	"de_dust2 de_mirage de_inferno de_nuke de_overpass de_vertigo de_ancient de_anubis",
	"de_shortdust de_shortnuke de_lake gd_rialto de_inferno de_overpass",
	"de_dust2 cs_office cs_italy de_mirage",
	"de_dust2 de_mirage de_inferno cs_office",
	"ar_baggage ar_shoots ar_monastery ar_pool_day",
	"de_lake de_safehouse de_bank de_shortnuke",
	"de_mirage de_inferno de_dust2 de_nuke de_ancient",
	"de_shortdust de_lake de_shortnuke gd_rialto",
	"am_inferno_banana_dolnma am_walterv2"
};
char g_GmFolder[GM_COUNT][] = { "competitive", "wingman", "casual", "deathmatch", "armsrace", "demolition", "practice", "1v1", "arena" };

char g_MapPool[][] =
{
	"de_dust2", "de_mirage", "de_inferno", "de_nuke", "de_overpass", "de_vertigo",
	"de_ancient", "de_anubis", "de_train", "de_cache", "de_cbble", "cs_office", "cs_italy"
};
char g_WingmanMaps[][] = { "de_shortdust", "de_shortnuke", "de_lake", "gd_rialto", "de_overpass", "de_vertigo", "de_inferno", "de_train", "gd_cbble" };
char g_ArmsRaceMaps[][] = { "ar_baggage", "ar_shoots", "ar_monastery", "ar_dizzy", "ar_lunacy" };
char g_DemolitionMaps[][] = { "de_lake", "de_safehouse", "de_shortdust", "de_shortnuke", "de_bank", "de_stmarc", "de_sugarcane" };

int  g_PickMode[MAXPLAYERS + 1];
int  g_SwitchMode = -1;
char g_SwitchMap[PLATFORM_MAX_PATH];

int GetCvarInt(const char[] name)
{
	ConVar cv = FindConVar(name);
	return cv != null ? cv.IntValue : 0;
}

int CurrentMode()
{
	if (g_State == State_Practice || g_PracticeNext)
		return GM_Practice;
	if (g_ArenaNext)
		return GM_Arena;
	if (g_OneVOneNext)
		return GM_1v1Match;
	int type = GetCvarInt("game_type");
	int mode = GetCvarInt("game_mode");
	for (int i = 0; i < GM_Practice; i++)
	{
		if (g_GmType[i] == type && g_GmMode[i] == mode)
			return i;
	}
	return -1; // something else (e.g. Weapons Expert, custom)
}

void GetModeName(char[] out, int maxlen)
{
	int m = CurrentMode();
	if (m >= 0)
		strcopy(out, maxlen, g_GmName[m]);
	else
		Format(out, maxlen, "Custom (game_type %d, game_mode %d)", GetCvarInt("game_type"), GetCvarInt("game_mode"));
}

bool IsWingman()
{
	return GetCvarInt("game_type") == 0 && GetCvarInt("game_mode") == 2;
}

// Modes where the ready-up / knife / live match flow runs.
bool IsMatchMode()
{
	if (g_ArenaNext)
		return false;
	if (GetCvarInt("game_type") != 0)
		return false;
	int mode = GetCvarInt("game_mode");
	return mode == 1 || mode == 2;
}

void ApplyModeOnMapStart()
{
	SeriesOnMapStart();
	if (g_PracticeNext)
	{
		EnterPractice();
		return;
	}
	if (g_ArenaNext)
	{
		EnterArena();
		return;
	}
	if (IsMatchMode())
	{
		StartWarmup();
		return;
	}

	// Casual / Deathmatch / Arms Race / Demolition: let the game run its own mode.
	// When a game ends, restart it on the same map instead of a map vote.
	ServerCommand("mp_endmatch_votenextmap 0");
	ServerCommand("mp_match_end_changelevel 0");
	ServerCommand("mp_match_end_restart 1");
	DuelCleanup();
	ResetMatch();
	StopDemo();
	g_State = State_None;
	CreateTimer(5.0, Timer_ModeAnnounce, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_ModeAnnounce(Handle timer)
{
	char mode[32];
	GetModeName(mode, sizeof(mode));
	Announce("Game mode: \x04%s\x01. Admins can change it with \x04!gamemode\x01.", mode);
	return Plugin_Stop;
}

// Leave practice/duel and go back to whatever the server's mode is.
void ReturnToMode()
{
	if (IsMatchMode())
	{
		StartWarmup();
		return;
	}
	char map[PLATFORM_MAX_PATH];
	GetCurrentMap(map, sizeof(map));
	ForceChangeLevel(map, "Returning to game mode");
}

/* ---------- !gamemode ---------- */

void Cmd_GameMode(int client)
{
	if (!CheckInGame(client))
	{
		char mode[32];
		GetModeName(mode, sizeof(mode));
		Reply(client, "Current game mode: %s", mode);
		return;
	}
	if (!IsAdmin(client))
	{
		char mode[32];
		GetModeName(mode, sizeof(mode));
		Reply(client, "Current game mode: \x04%s\x01. Only admins can change it.", mode);
		return;
	}
	ShowGameModeMenu(client);
}

void ShowGameModeMenu(int client)
{
	char mode[32], map[64], line[96], info[8];
	GetModeName(mode, sizeof(mode));
	GetCurrentMap(map, sizeof(map));

	Menu menu = new Menu(Handler_GameMode);
	menu.SetTitle("Game mode\nNow: %s on %s", mode, map);

	int current = CurrentMode();
	for (int i = 0; i < GM_COUNT; i++)
	{
		IntToString(i, info, sizeof(info));
		if (i == current)
			Format(line, sizeof(line), "%s [current]", g_GmName[i]);
		else
			strcopy(line, sizeof(line), g_GmName[i]);
		if (i == GM_Competitive || i == GM_Wingman)
			StrCat(line, sizeof(line), " (ready-up match)");
		menu.AddItem(info, line);
	}
	menu.AddItem("options", "Match options...");
	menu.Display(client, MENU_TIME_FOREVER);
}

public int Handler_GameMode(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_End)
	{
		delete menu;
	}
	else if (action == MenuAction_Select)
	{
		char info[16];
		menu.GetItem(item, info, sizeof(info));
		if (StrEqual(info, "options"))
		{
			ShowOptionsMenu(client);
			return 0;
		}
		g_PickMode[client] = StringToInt(info);
		ShowModeMapMenu(client);
	}
	return 0;
}

void AddMapItem(Menu menu, const char[] map, StringMap seen)
{
	int dummy;
	char path[PLATFORM_MAX_PATH];
	if (seen.GetValue(map, dummy) || !ResolveMap(map, path, sizeof(path)))
		return;
	seen.SetValue(map, 1);
	menu.AddItem(path, map);
}

void ShowModeMapMenu(int client)
{
	int gm = g_PickMode[client];
	char current[PLATFORM_MAX_PATH], line[96];
	GetCurrentMap(current, sizeof(current));

	Menu menu = new Menu(Handler_ModeMap);
	menu.SetTitle("%s — choose a map", g_GmName[gm]);

	char currentName[PLATFORM_MAX_PATH];
	GetMapDisplayName(current, currentName, sizeof(currentName));
	bool mapSpecific = (gm == GM_Arena);
	char folderPrefix[PLATFORM_MAX_PATH];
	Format(folderPrefix, sizeof(folderPrefix), "modes/%s/", g_GmFolder[gm]);
	if (!mapSpecific || HasMovePrefix(currentName, gm) || StrContains(current, folderPrefix, false) == 0)
	{
		Format(line, sizeof(line), "Stay on %s", currentName);
		menu.AddItem(current, line);
	}

	StringMap seen = new StringMap();
	seen.SetValue(currentName, 1);

	// The mode's own map folder comes first, then its standard maps.
	int folderMaps = AddFolderMaps(menu, gm, seen);
	folderMaps += AddStandardMaps(menu, gm, seen);

	if (gm == GM_Wingman || gm == GM_1v1Match)
	{
		for (int i = 0; i < sizeof(g_WingmanMaps); i++)
			AddMapItem(menu, g_WingmanMaps[i], seen);
	}
	else if (gm == GM_ArmsRace)
	{
		for (int i = 0; i < sizeof(g_ArmsRaceMaps); i++)
			AddMapItem(menu, g_ArmsRaceMaps[i], seen);
	}
	else if (gm == GM_Demolition)
	{
		for (int i = 0; i < sizeof(g_DemolitionMaps); i++)
			AddMapItem(menu, g_DemolitionMaps[i], seen);
	}

	if (gm == GM_Arena)
	{
		// Only maps made for the mode; normal maps make no sense here.
		int found = folderMaps + AddPrefixedMaps(menu, gm, seen);
		if (found == 0)
		{
			PrintToChat(client, "%sNo %s maps found. Put .bsp files in \x04csgo\\maps\\modes\\%s\x01 and open this menu again.", PREFIX, g_GmName[gm], g_GmFolder[gm]);
		}
	}
	else
	{
		for (int i = 0; i < sizeof(g_MapPool); i++)
			AddMapItem(menu, g_MapPool[i], seen);
	}
	menu.AddItem("#all", "All maps on the server...");
	AddMissingStandardMaps(menu, gm, seen);
	delete seen;

	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int Handler_ModeMap(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_End)
	{
		delete menu;
	}
	else if (action == MenuAction_Select)
	{
		char map[PLATFORM_MAX_PATH];
		menu.GetItem(item, map, sizeof(map));
		if (StrEqual(map, "#all"))
		{
			g_MapPickGm[client] = g_PickMode[client];
			ShowAllMapsList(client, MAPCAT_ALL);
			return 0;
		}
		SwitchGameMode(client, g_PickMode[client], map);
	}
	else if (action == MenuAction_Cancel && item == MenuCancel_ExitBack)
	{
		ShowGameModeMenu(client);
	}
	return 0;
}

void SwitchGameMode(int client, int gm, const char[] map)
{
	if (g_State == State_Live || g_State == State_Knife || g_State == State_SideSelect)
		Announce("\x02The current match will be abandoned.");
	if (g_SeriesActive || g_VetoRunning)
		CancelSeries("The best-of-3 series was cancelled (game mode change).");

	g_SwitchMode = gm;
	strcopy(g_SwitchMap, sizeof(g_SwitchMap), map);
	Announce("%N is switching to \x04%s\x01 on \x04%s\x01 in 5 seconds...", client, g_GmName[gm], map);
	CreateTimer(5.0, Timer_SwitchMode, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_SwitchMode(Handle timer)
{
	int gm = g_SwitchMode;
	g_SwitchMode = -1;
	if (gm < 0 || gm >= GM_COUNT)
		return Plugin_Stop;
	char target[PLATFORM_MAX_PATH];
	if (!ResolveMap(g_SwitchMap, target, sizeof(target)))
	{
		Announce("\x02Can't switch: map %s isn't installed on the server.\x01 Nothing was changed.", g_SwitchMap);
		return Plugin_Stop;
	}
	strcopy(g_SwitchMap, sizeof(g_SwitchMap), target);

	g_PracticeNext = (gm == GM_Practice);
	if (g_ArenaNext && gm != GM_Arena)
		ResetMovementCvars();
	g_OneVOneNext = (gm == GM_1v1Match);
	g_ArenaNext = (gm == GM_Arena);
	if (g_cvDuelActive != null)
		g_cvDuelActive.BoolValue = false;
	ServerCommand("game_type %d", g_GmType[gm]);
	ServerCommand("game_mode %d", g_GmMode[gm]);
	ServerCommand("changelevel %s", g_SwitchMap);
	return Plugin_Stop;
}

/* ---------- !options ---------- */

void Cmd_Options(int client)
{
	if (!CheckInGame(client) || !RequireAdmin(client))
		return;
	ShowOptionsMenu(client);
}

void ShowOptionsMenu(int client)
{
	char line[96];
	Menu menu = new Menu(Handler_Options);
	menu.SetTitle("Match options\n(saved automatically, used for every match)");

	if (g_cvSeries.IntValue == 3)
		strcopy(line, sizeof(line), "5v5 series: Best of 3 (map veto)");
	else
		strcopy(line, sizeof(line), "5v5 series: Single map");
	menu.AddItem("series", line);
	if (g_cvSeries.IntValue == 3)
	{
		Format(line, sizeof(line), "Map vote time: %d seconds per ban/pick", g_cvVetoTime.IntValue);
		menu.AddItem("vetotime", line);
	}

	Format(line, sizeof(line), "Knife round: %s", g_KnifeEnabled ? "On" : "Off");
	menu.AddItem("knife", line);

	int ready = g_cvReadyRequired.IntValue;
	if (ready <= 0)
		Format(line, sizeof(line), "Players needed to start: Everyone on a team");
	else
		Format(line, sizeof(line), "Players needed to start: %d", ready);
	menu.AddItem("ready", line);

	int rounds = g_cvMaxRounds.IntValue;
	if (rounds == 30)
		strcopy(line, sizeof(line), "Match length: MR15 (30 rounds)");
	else if (rounds == 24)
		strcopy(line, sizeof(line), "Match length: MR12 (24 rounds)");
	else if (rounds > 0)
		Format(line, sizeof(line), "Match length: %d rounds", rounds);
	else
		strcopy(line, sizeof(line), "Match length: from live.cfg / wingman.cfg");
	menu.AddItem("rounds", line);

	TriState("Overtime", g_cvOvertime.IntValue, line, sizeof(line));
	menu.AddItem("overtime", line);
	TriState("Friendly fire", g_cvFriendlyFire.IntValue, line, sizeof(line));
	menu.AddItem("ff", line);

	int pauses = g_cvMaxPauses.IntValue;
	if (pauses <= 0)
		strcopy(line, sizeof(line), "Tactical pauses per team: Unlimited");
	else
		Format(line, sizeof(line), "Tactical pauses per team: %d", pauses);
	menu.AddItem("pauses", line);

	Format(line, sizeof(line), "Unpause needs both teams: %s", g_cvBothUnpause.BoolValue ? "Yes" : "No");
	menu.AddItem("unpause", line);
	Format(line, sizeof(line), "!stop round restore: %s", g_cvStopEnabled.BoolValue ? "On" : "Off");
	menu.AddItem("stop", line);
	Format(line, sizeof(line), "Demo recording: %s", g_cvDemoEnabled.BoolValue ? "On" : "Off");
	menu.AddItem("demo", line);
	Format(line, sizeof(line), "Side pick time: %d seconds", g_cvSideTime.IntValue);
	menu.AddItem("side", line);
	menu.AddItem("reset", "Reset all options to defaults");

	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

void TriState(const char[] label, int value, char[] buf, int maxlen)
{
	if (value == 1)
		Format(buf, maxlen, "%s: On", label);
	else if (value == 0)
		Format(buf, maxlen, "%s: Off", label);
	else
		Format(buf, maxlen, "%s: from live.cfg", label);
}

int NextInList(int value, const int[] list, int count)
{
	for (int i = 0; i < count; i++)
	{
		if (list[i] == value)
			return list[(i + 1) % count];
	}
	return list[0];
}

public int Handler_Options(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_End)
	{
		delete menu;
		return 0;
	}
	if (action == MenuAction_Cancel)
	{
		if (item == MenuCancel_ExitBack)
			ShowGameModeMenu(client);
		return 0;
	}
	if (action != MenuAction_Select)
		return 0;

	char info[16];
	menu.GetItem(item, info, sizeof(info));

	static const int readyList[] = { 0, 2, 4, 6, 8, 10 };
	static const int roundList[] = { 0, 30, 24, 16 };
	static const int triList[]   = { -1, 1, 0 };
	static const int pauseList[] = { 0, 1, 2, 3, 4 };
	static const int sideList[]  = { 30, 60, 90, 120 };

	static const int vetoTimeList[] = { 15, 25, 40, 60 };

	if (StrEqual(info, "series"))
	{
		g_cvSeries.IntValue = (g_cvSeries.IntValue == 3) ? 1 : 3;
		if (g_SeriesActive || g_VetoRunning)
			Reply(client, "The series that's running carries on. Type \x04!endseries\x01 to stop it.");
	}
	else if (StrEqual(info, "vetotime"))
		g_cvVetoTime.IntValue = NextInList(g_cvVetoTime.IntValue, vetoTimeList, sizeof(vetoTimeList));
	else if (StrEqual(info, "knife"))
	{
		g_KnifeEnabled = !g_KnifeEnabled;
		g_cvKnifeDefault.BoolValue = g_KnifeEnabled;
	}
	else if (StrEqual(info, "ready"))
	{
		g_cvReadyRequired.IntValue = NextInList(g_cvReadyRequired.IntValue, readyList, sizeof(readyList));
		CheckReady();
	}
	else if (StrEqual(info, "rounds"))
		g_cvMaxRounds.IntValue = NextInList(g_cvMaxRounds.IntValue, roundList, sizeof(roundList));
	else if (StrEqual(info, "overtime"))
		g_cvOvertime.IntValue = NextInList(g_cvOvertime.IntValue, triList, sizeof(triList));
	else if (StrEqual(info, "ff"))
		g_cvFriendlyFire.IntValue = NextInList(g_cvFriendlyFire.IntValue, triList, sizeof(triList));
	else if (StrEqual(info, "pauses"))
		g_cvMaxPauses.IntValue = NextInList(g_cvMaxPauses.IntValue, pauseList, sizeof(pauseList));
	else if (StrEqual(info, "unpause"))
		g_cvBothUnpause.BoolValue = !g_cvBothUnpause.BoolValue;
	else if (StrEqual(info, "stop"))
		g_cvStopEnabled.BoolValue = !g_cvStopEnabled.BoolValue;
	else if (StrEqual(info, "demo"))
		g_cvDemoEnabled.BoolValue = !g_cvDemoEnabled.BoolValue;
	else if (StrEqual(info, "side"))
		g_cvSideTime.IntValue = NextInList(g_cvSideTime.IntValue, sideList, sizeof(sideList));
	else if (StrEqual(info, "reset"))
	{
		ConVar list[12];
		int n = GetOptionCvars(list);
		for (int i = 0; i < n; i++)
			list[i].RestoreDefault();
		g_KnifeEnabled = g_cvKnifeDefault.BoolValue;
		Reply(client, "Match options reset to defaults.");
	}

	SaveOptions();
	if (g_State == State_Live || g_State == State_Knife || g_State == State_SideSelect)
		Reply(client, "Saved. Match length, overtime and friendly fire apply from the next match.");
	ShowOptionsMenu(client);
	return 0;
}

int GetOptionCvars(ConVar list[12])
{
	list[0] = g_cvKnifeDefault;
	list[1] = g_cvReadyRequired;
	list[2] = g_cvMaxRounds;
	list[3] = g_cvOvertime;
	list[4] = g_cvFriendlyFire;
	list[5] = g_cvMaxPauses;
	list[6] = g_cvBothUnpause;
	list[7] = g_cvStopEnabled;
	list[8] = g_cvDemoEnabled;
	list[9] = g_cvSideTime;
	list[10] = g_cvSeries;
	list[11] = g_cvVetoTime;
	return 12;
}

void GetOptionsPath(char[] path, int maxlen)
{
	BuildPath(Path_SM, path, maxlen, "data/csgo_match_options.txt");
}

void SaveOptions()
{
	KeyValues kv = new KeyValues("options");
	ConVar list[12];
	char name[64], value[64];
	int n = GetOptionCvars(list);
	for (int i = 0; i < n; i++)
	{
		list[i].GetName(name, sizeof(name));
		list[i].GetString(value, sizeof(value));
		kv.SetString(name, value);
	}
	char path[PLATFORM_MAX_PATH];
	GetOptionsPath(path, sizeof(path));
	kv.ExportToFile(path);
	delete kv;
}

// Values picked in !options win over cfg/sourcemod/csgo_match.cfg.
void LoadSavedOptions()
{
	char path[PLATFORM_MAX_PATH];
	GetOptionsPath(path, sizeof(path));
	if (!FileExists(path))
		return;

	KeyValues kv = new KeyValues("options");
	if (kv.ImportFromFile(path))
	{
		ConVar list[12];
		char name[64], value[64];
		int n = GetOptionCvars(list);
		for (int i = 0; i < n; i++)
		{
			list[i].GetName(name, sizeof(name));
			kv.GetString(name, value, sizeof(value), "");
			if (value[0] != '\0')
				list[i].SetString(value);
		}
	}
	delete kv;
}

/* ------------------------------------------------------------------ */
/*  Map lists per mode                                                */
/* ------------------------------------------------------------------ */

void GetMovePrefixes(int gm, char prefixes[4][16], int &count)
{
	count = 0;
	if (gm == GM_Arena)
	{
		strcopy(prefixes[count++], 16, "am_");
		strcopy(prefixes[count++], 16, "1v1_");
	}

}

bool HasMovePrefix(const char[] name, int gm)
{
	char prefixes[4][16];
	int count;
	GetMovePrefixes(gm, prefixes, count);
	for (int i = 0; i < count; i++)
	{
		if (StrContains(name, prefixes[i], false) == 0)
			return true;
	}
	return false;
}

// Adds every installed map for the mode (maps\ and maps\workshop\<id>\). Returns how many.
int AddPrefixedMaps(Menu menu, int gm, StringMap seen)
{
	int found = 0;
	char name[PLATFORM_MAX_PATH];
	FileType type;

	DirectoryListing dir = OpenDirectory("maps", true);
	if (dir == null)
		return 0;

	while (dir.GetNext(name, sizeof(name), type))
	{
		if (type == FileType_File)
		{
			int len = strlen(name);
			if (len > 4 && StrEqual(name[len - 4], ".bsp", false) && HasMovePrefix(name, gm))
			{
				name[len - 4] = '\0';
				found += TryAddMap(menu, name, seen);
			}
		}
		else if (type == FileType_Directory && StrEqual(name, "workshop", false))
		{
			found += AddWorkshopMaps(menu, gm, seen);
		}
	}
	delete dir;
	return found;
}

int AddWorkshopMaps(Menu menu, int gm, StringMap seen)
{
	int found = 0;
	char id[64], file[PLATFORM_MAX_PATH], path[PLATFORM_MAX_PATH], map[PLATFORM_MAX_PATH];
	FileType type;

	DirectoryListing ws = OpenDirectory("maps/workshop", true);
	if (ws == null)
		return 0;
	while (ws.GetNext(id, sizeof(id), type))
	{
		if (type != FileType_Directory || id[0] == '.')
			continue;
		Format(path, sizeof(path), "maps/workshop/%s", id);
		DirectoryListing inner = OpenDirectory(path, true);
		if (inner == null)
			continue;
		while (inner.GetNext(file, sizeof(file), type))
		{
			int len = strlen(file);
			if (type == FileType_File && len > 4 && StrEqual(file[len - 4], ".bsp", false) && HasMovePrefix(file, gm))
			{
				file[len - 4] = '\0';
				Format(map, sizeof(map), "workshop/%s/%s", id, file);
				found += TryAddMap(menu, map, seen);
			}
		}
		delete inner;
	}
	delete ws;
	return found;
}

int TryAddMap(Menu menu, const char[] map, StringMap seen)
{
	// Show "am_walterv2" rather than "workshop/123/am_walterv2" or "modes/arena/am_walterv2".
	char display[PLATFORM_MAX_PATH];
	int slash = FindCharInString(map, '/', true);
	strcopy(display, sizeof(display), map[slash + 1]);

	int dummy;
	if (seen.GetValue(display, dummy))
		return 0;
	seen.SetValue(display, 1);
	menu.AddItem(map, display);
	return 1;
}

void CreateModeFolders()
{
	char path[PLATFORM_MAX_PATH];
	if (!DirExists("maps/modes"))
		CreateDirectory("maps/modes", 511);
	for (int i = 0; i < GM_COUNT; i++)
	{
		Format(path, sizeof(path), "maps/modes/%s", g_GmFolder[i]);
		if (!DirExists(path))
			CreateDirectory(path, 511);
		WriteDefaultMapList(i);
	}
}

void WriteDefaultMapList(int gm)
{
	char path[PLATFORM_MAX_PATH];
	Format(path, sizeof(path), "maps/modes/%s/maplist.txt", g_GmFolder[gm]);
	if (FileExists(path))
		return;

	File f = OpenFile(path, "w");
	if (f == null)
		return;
	f.WriteLine("// Standard maps for %s - one map name per line.", g_GmName[gm]);
	f.WriteLine("// Installed maps are listed at the top of the !gamemode map menu;");
	f.WriteLine("// missing ones are shown greyed out as (not installed).");
	f.WriteLine("// Edit freely. Lines starting with // are ignored.");

	char maps[16][PLATFORM_MAX_PATH];
	int n = ExplodeString(g_GmDefaultMaps[gm], " ", maps, sizeof(maps), sizeof(maps[]));
	for (int i = 0; i < n; i++)
	{
		if (maps[i][0] != '\0')
			f.WriteLine("%s", maps[i]);
	}
	delete f;
}

// Reads maps/modes/<folder>/maplist.txt into `list` (map names, in file order).
void ReadModeMapList(int gm, ArrayList list)
{
	char path[PLATFORM_MAX_PATH], line[PLATFORM_MAX_PATH];
	Format(path, sizeof(path), "maps/modes/%s/maplist.txt", g_GmFolder[gm]);
	File f = OpenFile(path, "r", true);
	if (f == null)
		return;
	while (f.ReadLine(line, sizeof(line)))
	{
		TrimString(line);
		if (line[0] == '\0' || (line[0] == '/' && line[1] == '/'))
			continue;
		int len = strlen(line);
		if (len > 4 && StrEqual(line[len - 4], ".bsp", false))
			line[len - 4] = '\0';
		list.PushString(line);
	}
	delete f;
}

// IsMapValid() on CS:GO also accepts fuzzy matches (a missing map can resolve
// to a different one), so only accept a real match: an exact map, or a
// resolved name whose map name is the same (e.g. a workshop path).
// Finds the exact map and gives the path changelevel needs. A bare name of a
// workshop map ("am_walterv2") becomes "workshop/<id>/am_walterv2",
// because changelevel with only the bare name lets the game guess (de_train).
bool ResolveMap(const char[] map, char[] out, int maxlen)
{
	char found[PLATFORM_MAX_PATH];
	FindMapResult r = FindMap(map, found, sizeof(found));
	if (r == FindMap_Found)
	{
		strcopy(out, maxlen, map);
		return true;
	}
	if (r == FindMap_FuzzyMatch || r == FindMap_NonCanonical)
	{
		char a[PLATFORM_MAX_PATH], b[PLATFORM_MAX_PATH];
		MapShortName(map, a, sizeof(a));
		MapShortName(found, b, sizeof(b));
		if (StrEqual(a, b, false) && !StrEqual(map, found, false) && StrContains(found, "/") != -1)
		{
			strcopy(out, maxlen, found);
			return true;
		}
	}

	// Look in maps/workshop/<id>/ ourselves for a bare map name.
	if (StrContains(map, "/") == -1)
	{
		char id[64], file[PLATFORM_MAX_PATH];
		FileType type;
		DirectoryListing ws = OpenDirectory("maps/workshop", true);
		if (ws != null)
		{
			while (ws.GetNext(id, sizeof(id), type))
			{
				if (type != FileType_Directory || id[0] == '.')
					continue;
				Format(file, sizeof(file), "maps/workshop/%s/%s.bsp", id, map);
				if (FileExists(file, true))
				{
					Format(out, maxlen, "workshop/%s/%s", id, map);
					delete ws;
					return true;
				}
			}
			delete ws;
		}
	}
	return false;
}

bool MapInstalled(int gm, const char[] name, char[] mapPath, int maxlen)
{
	// In the mode's folder, or anywhere the game can find it (maps\, workshop).
	char inFolder[PLATFORM_MAX_PATH];
	Format(inFolder, sizeof(inFolder), "modes/%s/%s", g_GmFolder[gm], name);
	if (ResolveMap(inFolder, mapPath, maxlen))
		return true;
	return ResolveMap(name, mapPath, maxlen);
}

// Standard maps (maplist.txt) that are installed. Returns how many were added.
int AddStandardMaps(Menu menu, int gm, StringMap seen)
{
	ArrayList list = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));
	ReadModeMapList(gm, list);
	char name[PLATFORM_MAX_PATH], path[PLATFORM_MAX_PATH];
	int found = 0;
	for (int i = 0; i < list.Length; i++)
	{
		list.GetString(i, name, sizeof(name));
		if (MapInstalled(gm, name, path, sizeof(path)))
			found += TryAddMap(menu, path, seen);
	}
	delete list;
	return found;
}

// Standard maps that aren't installed, greyed out so admins know what to get.
void AddMissingStandardMaps(Menu menu, int gm, StringMap seen)
{
	ArrayList list = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));
	ReadModeMapList(gm, list);
	char name[PLATFORM_MAX_PATH], path[PLATFORM_MAX_PATH], line[PLATFORM_MAX_PATH + 32];
	int dummy;
	for (int i = 0; i < list.Length; i++)
	{
		list.GetString(i, name, sizeof(name));
		if (seen.GetValue(name, dummy) || MapInstalled(gm, name, path, sizeof(path)))
			continue;
		seen.SetValue(name, 1);
		Format(line, sizeof(line), "%s (not installed)", name);
		menu.AddItem("", line, ITEMDRAW_DISABLED);
	}
	delete list;
}

// Every .bsp in csgo/maps/modes/<folder>/ for this mode. Returns how many were added.
int AddFolderMaps(Menu menu, int gm, StringMap seen)
{
	char dirPath[PLATFORM_MAX_PATH], file[PLATFORM_MAX_PATH], map[PLATFORM_MAX_PATH];
	Format(dirPath, sizeof(dirPath), "maps/modes/%s", g_GmFolder[gm]);

	DirectoryListing dir = OpenDirectory(dirPath, true);
	if (dir == null)
		return 0;

	ArrayList names = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));
	FileType type;
	while (dir.GetNext(file, sizeof(file), type))
	{
		int len = strlen(file);
		if (type == FileType_File && len > 4 && StrEqual(file[len - 4], ".bsp", false))
		{
			file[len - 4] = '\0';
			names.PushString(file);
		}
	}
	delete dir;

	names.Sort(Sort_Ascending, Sort_String);
	int found = 0;
	for (int i = 0; i < names.Length; i++)
	{
		names.GetString(i, file, sizeof(file));
		Format(map, sizeof(map), "modes/%s/%s", g_GmFolder[gm], file);
		found += TryAddMap(menu, map, seen);
	}
	delete names;
	return found;
}


/* ------------------------------------------------------------------ */
/*  !1v1 menu — every 1v1 mode in one place                           */
/* ------------------------------------------------------------------ */

void Cmd_OneVOneMenu(int client, const char[] arg)
{
	if (!CheckInGame(client))
		return;
	if (arg[0] != '\0')
	{
		Cmd_Duel(client, arg); // "!1v1 name" still challenges directly
		return;
	}

	char mode[32];
	GetModeName(mode, sizeof(mode));
	bool admin = IsAdmin(client);

	Menu menu = new Menu(Handler_OneVOne);
	menu.SetTitle("1v1 modes\nNow: %s", mode);
	menu.AddItem("duel", "!duel — pick gun, rounds, headshots only, then an opponent");
	menu.AddItem("match", admin ? "1v1 match — ready-up MR15, one per side" : "1v1 match (admins switch modes)", admin ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
	menu.AddItem("arena", admin ? "Multi-1v1 arenas — ladder on am_ maps" : "Multi-1v1 arenas (admins switch modes)", admin ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
	if (g_State == State_Arena)
		menu.AddItem("guns", "Arena guns (!guns)");
	menu.Display(client, MENU_TIME_FOREVER);
}

public int Handler_OneVOne(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_End)
	{
		delete menu;
	}
	else if (action == MenuAction_Select)
	{
		char info[16];
		menu.GetItem(item, info, sizeof(info));
		if (StrEqual(info, "duel"))
			Cmd_Duel(client, "");
		else if (StrEqual(info, "guns"))
			ShowArenaGunsMenu(client);
		else if (IsAdmin(client))
		{
			g_PickMode[client] = StrEqual(info, "match") ? GM_1v1Match : GM_Arena;
			ShowModeMapMenu(client);
		}
	}
	return 0;
}

// Undo the arena settings when switching to another mode.
void ResetMovementCvars()
{
	ServerCommand("mp_ignore_round_win_conditions 0");
	ServerCommand("mp_respawn_on_death_ct 0");
	ServerCommand("mp_respawn_on_death_t 0");
	ServerCommand("mp_respawn_immunitytime 4");
	ServerCommand("mp_solid_teammates 1");
	ServerCommand("mp_buy_anywhere 0");
	ServerCommand("mp_buytime 20");
	ServerCommand("mp_ct_default_secondary \"weapon_hkp2000\"");
	ServerCommand("mp_t_default_secondary \"weapon_glock\"");
}

/* ------------------------------------------------------------------ */
/*  1v1 match: one human per side                                     */
/* ------------------------------------------------------------------ */

int CountHumansOnTeam(int team, int except)
{
	int n = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (i != except && IsClientInGame(i) && !IsFakeClient(i) && GetClientTeam(i) == team)
			n++;
	}
	return n;
}

Action OneVOneJoinTeam(int client)
{
	char arg[8];
	GetCmdArg(1, arg, sizeof(arg));
	int team = StringToInt(arg);

	if (team == CS_TEAM_T || team == CS_TEAM_CT)
	{
		if (CountHumansOnTeam(team, client) >= 1)
		{
			int other = (team == CS_TEAM_T) ? CS_TEAM_CT : CS_TEAM_T;
			if (CountHumansOnTeam(other, client) == 0 && GetClientTeam(client) != other)
			{
				PrintToChat(client, "%s1v1 match: that side is taken — putting you on the other side.", PREFIX);
				ChangeClientTeam(client, other);
			}
			else
			{
				PrintToChat(client, "%s1v1 match: both sides are taken — you can spectate.", PREFIX);
			}
			return Plugin_Handled;
		}
	}
	else if (team == 0)
	{
		// Auto-select: pick the empty side, or spectate.
		if (CountHumansOnTeam(CS_TEAM_T, client) == 0)
			ChangeClientTeam(client, CS_TEAM_T);
		else if (CountHumansOnTeam(CS_TEAM_CT, client) == 0)
			ChangeClientTeam(client, CS_TEAM_CT);
		else
			ChangeClientTeam(client, CS_TEAM_SPECTATOR);
		return Plugin_Handled;
	}
	return Plugin_Continue;
}

/* ------------------------------------------------------------------ */
/*  Multi-1v1 arenas                                                  */
/* ------------------------------------------------------------------ */


public void OnClientCookiesCached(int client)
{
	char buf[8];
	g_CookieRifle.Get(client, buf, sizeof(buf));
	g_PrefRifle[client] = buf[0] ? StringToInt(buf) : 0;
	g_CookiePistol.Get(client, buf, sizeof(buf));
	g_PrefPistol[client] = buf[0] ? StringToInt(buf) : 0;
	g_CookieAwp.Get(client, buf, sizeof(buf));
	g_PrefAwp[client] = buf[0] ? (StringToInt(buf) != 0) : true;

	if (g_PrefRifle[client] < 0 || g_PrefRifle[client] >= sizeof(g_ArenaRifles))
		g_PrefRifle[client] = 0;
	if (g_PrefPistol[client] < 0 || g_PrefPistol[client] >= sizeof(g_ArenaPistols))
		g_PrefPistol[client] = 0;
}

void SavePrefs(int client)
{
	if (!AreClientCookiesCached(client))
		return;
	char buf[8];
	IntToString(g_PrefRifle[client], buf, sizeof(buf));
	g_CookieRifle.Set(client, buf);
	IntToString(g_PrefPistol[client], buf, sizeof(buf));
	g_CookiePistol.Set(client, buf);
	g_CookieAwp.Set(client, g_PrefAwp[client] ? "1" : "0");
}

/* ---------- Arena detection ---------- */

int CollectSpawnPoints(const char[] cls, float pos[MAX_SPAWNS][3], float ang[MAX_SPAWNS][3])
{
	int n = 0, ent = -1;
	while ((ent = FindEntityByClassname(ent, cls)) != -1 && n < MAX_SPAWNS)
	{
		GetEntPropVector(ent, Prop_Data, "m_vecOrigin", pos[n]);
		GetEntPropVector(ent, Prop_Data, "m_angRotation", ang[n]);
		n++;
	}
	return n;
}

// Groups spawns that are close together. Returns the number of groups;
// group[i] is the group of spawn i.
int ClusterSpawns(float pos[MAX_SPAWNS][3], int n, int group[MAX_SPAWNS])
{
	for (int i = 0; i < n; i++)
		group[i] = -1;

	int groups = 0;
	int stack[MAX_SPAWNS];
	for (int i = 0; i < n; i++)
	{
		if (group[i] != -1)
			continue;
		int top = 0;
		stack[top++] = i;
		group[i] = groups;
		while (top > 0)
		{
			int cur = stack[--top];
			for (int j = 0; j < n; j++)
			{
				if (group[j] == -1 && GetVectorDistance(pos[cur], pos[j]) <= ARENA_CLUSTER)
				{
					group[j] = groups;
					stack[top++] = j;
				}
			}
		}
		groups++;
	}
	return groups;
}

void FindArenas()
{
	float tPos[MAX_SPAWNS][3], tAng[MAX_SPAWNS][3], ctPos[MAX_SPAWNS][3], ctAng[MAX_SPAWNS][3];
	int tGroup[MAX_SPAWNS], ctGroup[MAX_SPAWNS];

	int nT = CollectSpawnPoints("info_player_terrorist", tPos, tAng);
	int nCT = CollectSpawnPoints("info_player_counterterrorist", ctPos, ctAng);
	g_ArenaCount = 0;
	if (nT == 0 || nCT == 0)
		return;

	int gT = ClusterSpawns(tPos, nT, tGroup);
	int gCT = ClusterSpawns(ctPos, nCT, ctGroup);

	// First spawn of each group stands for the group.
	int tFirst[MAX_SPAWNS], ctFirst[MAX_SPAWNS];
	for (int g = 0; g < gT; g++)
		tFirst[g] = -1;
	for (int g = 0; g < gCT; g++)
		ctFirst[g] = -1;
	for (int i = 0; i < nT; i++)
		if (tFirst[tGroup[i]] == -1)
			tFirst[tGroup[i]] = i;
	for (int i = 0; i < nCT; i++)
		if (ctFirst[ctGroup[i]] == -1)
			ctFirst[ctGroup[i]] = i;

	// Pair each T group with the nearest unused CT group.
	bool usedCT[MAX_SPAWNS];
	for (int g = 0; g < gT && g_ArenaCount < MAX_ARENAS; g++)
	{
		int ti = tFirst[g];
		int best = -1;
		float bestDist = 999999.0;
		for (int h = 0; h < gCT; h++)
		{
			if (usedCT[h])
				continue;
			float d = GetVectorDistance(tPos[ti], ctPos[ctFirst[h]]);
			if (d < bestDist)
			{
				bestDist = d;
				best = h;
			}
		}
		if (best == -1)
			break;
		usedCT[best] = true;
		int ci = ctFirst[best];
		int a = g_ArenaCount++;
		g_ArenaTPos[a] = tPos[ti];
		g_ArenaTAng[a] = tAng[ti];
		g_ArenaCTPos[a] = ctPos[ci];
		g_ArenaCTAng[a] = ctAng[ci];
	}
}

/* ---------- Mode on/off ---------- */

void EnterArena()
{
	DuelCleanup();
	ResetMatch();
	StopDemo();
	g_State = State_Arena;
	g_cvDuelActive.BoolValue = true; // loadout plugin: don't swap the weapons we hand out

	FindArenas();
	g_ArenaRank.Clear();
	g_ArenasInUse = 0;
	g_ArenaRoundLive = false;
	delete g_ArenaWaiting;
	g_ArenaWaiting = new ArrayList();
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i))
			g_ArenaRank.Push(GetClientUserId(i));
	}

	ServerCommand("mp_unpause_match");
	ServerCommand("mp_warmup_end");
	ServerCommand("exec csgo_match/arena.cfg");
	NoGameEnd();
	ServerCommand("mp_restartgame 1");

	if (g_ArenaCount == 0)
		LogError("Multi-1v1: this map has no T/CT spawn pairs.");
	CreateTimer(3.0, Timer_ArenaAnnounce, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_ArenaAnnounce(Handle timer)
{
	if (g_State == State_Arena)
		Announce("\x04Multi-1v1 arenas\x01: %d arena(s) on this map. Win to move up, lose to move down. \x04!guns\x01 pick weapons, \x04!sitout\x01 take a break, \x04!rank\x01 your arena.", g_ArenaCount);
	return Plugin_Stop;
}

/* ---------- Joining / leaving ---------- */

bool IsInRank(int userid)
{
	return g_ArenaRank.FindValue(userid) != -1;
}

void ArenaOnJoin(int client)
{
	int userid = GetClientUserId(client);
	if (!IsInRank(userid))
		g_ArenaRank.Push(userid);
	g_SitOut[client] = false;
	PrintToChat(client, "%sYou'll be put in an arena next round.", PREFIX);
	ArenaKickoffIfWaiting();
}

void ArenaOnDisconnect(int client)
{
	if (!IsClientInGame(client))
		return;
	int userid = GetClientUserId(client);
	g_SitOut[client] = false;
	g_PrefAwp[client] = true;
	g_PrefRifle[client] = 0;
	g_PrefPistol[client] = 0;

	if (g_State != State_Arena)
		return;

	// Leaving mid-fight hands the arena to the opponent.
	for (int a = 0; a < g_ArenasInUse; a++)
	{
		if (g_ArenaWinner[a] != 0)
			continue;
		if (g_ArenaP[a][0] == userid)
			ArenaDecide(a, g_ArenaP[a][1]);
		else if (g_ArenaP[a][1] == userid)
			ArenaDecide(a, g_ArenaP[a][0]);
	}
	int idx = g_ArenaRank.FindValue(userid);
	if (idx != -1)
		g_ArenaRank.Erase(idx);
}

// With fewer than two players the round never ends; start one as soon as a pair exists.
void ArenaKickoffIfWaiting()
{
	if (g_State != State_Arena || g_ArenasInUse > 0)
		return;
	if (CountArenaPlayers() >= 2)
		CS_TerminateRound(1.0, CSRoundEnd_Draw, true);
}

int CountArenaPlayers()
{
	int n = 0;
	for (int i = 0; i < g_ArenaRank.Length; i++)
	{
		int c = GetClientOfUserId(g_ArenaRank.Get(i));
		if (c > 0 && IsClientInGame(c) && !g_SitOut[c])
			n++;
	}
	return n;
}

Action ArenaJoinTeam(int client)
{
	char arg[8];
	GetCmdArg(1, arg, sizeof(arg));
	int team = StringToInt(arg);

	if (team == CS_TEAM_SPECTATOR)
	{
		if (!g_SitOut[client])
		{
			g_SitOut[client] = true;
			PrintToChat(client, "%sYou're sitting out. Join T or CT (or type \x04!sitout\x01) to play again.", PREFIX);
		}
		return Plugin_Continue; // let them spectate
	}

	// Teams are handed out by the plugin every round.
	int userid = GetClientUserId(client);
	if (!IsInRank(userid))
		g_ArenaRank.Push(userid);
	if (g_SitOut[client])
		g_SitOut[client] = false;
	PrintToChat(client, "%sYou'll be put in an arena next round.", PREFIX);
	ArenaKickoffIfWaiting();
	return Plugin_Handled;
}

void Cmd_SitOut(int client)
{
	if (!CheckInGame(client))
		return;
	if (g_State != State_Arena)
	{
		Reply(client, "!sitout only works in Multi-1v1 arena mode.");
		return;
	}
	g_SitOut[client] = !g_SitOut[client];
	if (g_SitOut[client])
	{
		Reply(client, "You'll sit out from the next round. Type \x04!sitout\x01 again to play.");
	}
	else
	{
		int userid = GetClientUserId(client);
		if (!IsInRank(userid))
			g_ArenaRank.Push(userid);
		Reply(client, "You're back in — you'll play from the next round.");
		ArenaKickoffIfWaiting();
	}
}

void Cmd_ArenaRank(int client)
{
	if (!CheckInGame(client))
		return;
	if (g_State != State_Arena)
	{
		Reply(client, "!rank only works in Multi-1v1 arena mode.");
		return;
	}
	int userid = GetClientUserId(client);
	for (int a = 0; a < g_ArenasInUse; a++)
	{
		if (g_ArenaP[a][0] == userid || g_ArenaP[a][1] == userid)
		{
			Reply(client, "You're in arena \x04%d\x01 of %d.", a + 1, g_ArenasInUse);
			return;
		}
	}
	int idx = g_ArenaRank.FindValue(userid);
	if (idx == -1)
		Reply(client, "You're not in the ladder yet — you'll join next round.");
	else
		Reply(client, "You're waiting for a free arena (place %d in the queue).", idx + 1);
}

/* ---------- Guns ---------- */

void Cmd_ArenaGuns(int client)
{
	if (!CheckInGame(client))
		return;
	ShowArenaGunsMenu(client);
}

void ShowArenaGunsMenu(int client)
{
	char line[64];
	Menu menu = new Menu(Handler_ArenaGuns);
	menu.SetTitle("Arena guns\n(used in Multi-1v1 rounds)");
	Format(line, sizeof(line), "Rifle: %s", g_ArenaRifleNames[g_PrefRifle[client]]);
	menu.AddItem("rifle", line);
	Format(line, sizeof(line), "Pistol: %s", g_ArenaPistolNames[g_PrefPistol[client]]);
	menu.AddItem("pistol", line);
	Format(line, sizeof(line), "AWP rounds: %s", g_PrefAwp[client] ? "Yes" : "No");
	menu.AddItem("awp", line);
	menu.Display(client, MENU_TIME_FOREVER);
}

public int Handler_ArenaGuns(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_End)
	{
		delete menu;
	}
	else if (action == MenuAction_Select)
	{
		char info[16];
		menu.GetItem(item, info, sizeof(info));
		if (StrEqual(info, "rifle"))
			g_PrefRifle[client] = (g_PrefRifle[client] + 1) % sizeof(g_ArenaRifles);
		else if (StrEqual(info, "pistol"))
			g_PrefPistol[client] = (g_PrefPistol[client] + 1) % sizeof(g_ArenaPistols);
		else if (StrEqual(info, "awp"))
			g_PrefAwp[client] = !g_PrefAwp[client];
		SavePrefs(client);
		ShowArenaGunsMenu(client);
	}
	return 0;
}

/* ---------- Rounds ---------- */

void ArenaRoundStart()
{
	g_ArenaSerial++;
	CreateTimer(0.1, Timer_ArenaSetup, g_ArenaSerial, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_ArenaSetup(Handle timer, int serial)
{
	if (g_State != State_Arena || serial != g_ArenaSerial)
		return Plugin_Stop;

	// Clean up the ladder and add anyone who isn't in it yet.
	for (int i = g_ArenaRank.Length - 1; i >= 0; i--)
	{
		if (GetClientOfUserId(g_ArenaRank.Get(i)) == 0)
			g_ArenaRank.Erase(i);
	}
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i) && !IsInRank(GetClientUserId(i)))
			g_ArenaRank.Push(GetClientUserId(i));
	}

	ArrayList players = new ArrayList();
	for (int i = 0; i < g_ArenaRank.Length; i++)
	{
		int c = GetClientOfUserId(g_ArenaRank.Get(i));
		if (c > 0 && !g_SitOut[c])
			players.Push(g_ArenaRank.Get(i));
	}

	int arenas = players.Length / 2;
	if (arenas > g_ArenaCount)
		arenas = g_ArenaCount;
	g_ArenasInUse = arenas;
	g_ArenaWaiting.Clear();

	if (arenas == 0)
	{
		g_ArenaRoundLive = false;
		// Not enough players: let whoever is here run around.
		if (players.Length == 1)
		{
			int c = GetClientOfUserId(players.Get(0));
			if (GetClientTeam(c) != CS_TEAM_T && GetClientTeam(c) != CS_TEAM_CT)
				CS_SwitchTeam(c, CS_TEAM_T);
			if (!IsPlayerAlive(c))
				CS_RespawnPlayer(c);
			PrintHintText(c, "Waiting for another player...");
		}
		else if (g_ArenaCount == 0)
		{
			Announce("This map has no arenas. Pick an am_ map with \x04!gamemode\x01.");
		}
		delete players;
		MoveSitoutsToSpec();
		return Plugin_Stop;
	}

	for (int a = 0; a < arenas; a++)
	{
		g_ArenaP[a][0] = players.Get(a * 2);
		g_ArenaP[a][1] = players.Get(a * 2 + 1);
		g_ArenaWinner[a] = 0;

		int c1 = GetClientOfUserId(g_ArenaP[a][0]);
		int c2 = GetClientOfUserId(g_ArenaP[a][1]);
		if (GetClientTeam(c1) != CS_TEAM_T)
			CS_SwitchTeam(c1, CS_TEAM_T);
		if (GetClientTeam(c2) != CS_TEAM_CT)
			CS_SwitchTeam(c2, CS_TEAM_CT);
		if (!IsPlayerAlive(c1))
			CS_RespawnPlayer(c1);
		if (!IsPlayerAlive(c2))
			CS_RespawnPlayer(c2);

		// Round type: AWP only if both want it.
		int types = (g_PrefAwp[c1] && g_PrefAwp[c2]) ? 3 : 2;
		g_ArenaType[a] = GetRandomInt(0, types - 1);
	}

	// Leftovers (odd player out, or more players than arenas) watch this round.
	for (int i = arenas * 2; i < players.Length; i++)
	{
		g_ArenaWaiting.Push(players.Get(i));
		int c = GetClientOfUserId(players.Get(i));
		if (GetClientTeam(c) != CS_TEAM_SPECTATOR)
			ChangeClientTeam(c, CS_TEAM_SPECTATOR);
		PrintToChat(c, "%sNo free arena this round — you're next in line.", PREFIX);
	}
	delete players;
	MoveSitoutsToSpec();

	g_ArenaRoundLive = true;
	CreateTimer(0.1, Timer_ArenaPlace, serial, TIMER_FLAG_NO_MAPCHANGE);
	return Plugin_Stop;
}

void MoveSitoutsToSpec()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i) && g_SitOut[i] && GetClientTeam(i) != CS_TEAM_SPECTATOR)
			ChangeClientTeam(i, CS_TEAM_SPECTATOR);
	}
}

public Action Timer_ArenaPlace(Handle timer, int serial)
{
	if (g_State != State_Arena || serial != g_ArenaSerial)
		return Plugin_Stop;

	float zero[3];
	for (int a = 0; a < g_ArenasInUse; a++)
	{
		int c1 = GetClientOfUserId(g_ArenaP[a][0]);
		int c2 = GetClientOfUserId(g_ArenaP[a][1]);
		if (c1 > 0 && IsPlayerAlive(c1))
		{
			TeleportEntity(c1, g_ArenaTPos[a], g_ArenaTAng[a], zero);
			ArmArenaPlayer(c1, g_ArenaType[a]);
		}
		if (c2 > 0 && IsPlayerAlive(c2))
		{
			TeleportEntity(c2, g_ArenaCTPos[a], g_ArenaCTAng[a], zero);
			ArmArenaPlayer(c2, g_ArenaType[a]);
		}
		if (c1 > 0 && c2 > 0)
		{
			PrintHintText(c1, "Arena %d / %d — %s round\nvs %N", a + 1, g_ArenasInUse, g_RoundTypeName[g_ArenaType[a]], c2);
			PrintHintText(c2, "Arena %d / %d — %s round\nvs %N", a + 1, g_ArenasInUse, g_RoundTypeName[g_ArenaType[a]], c1);
		}
	}

	// Rounds that drag on are decided on health.
	ConVar freeze = FindConVar("mp_freezetime");
	float limit = 60.0 + (freeze != null ? freeze.FloatValue : 0.0);
	CreateTimer(limit, Timer_ArenaTimeout, serial, TIMER_FLAG_NO_MAPCHANGE);
	return Plugin_Stop;
}

void ArmArenaPlayer(int client, int type)
{
	int size = GetEntPropArraySize(client, Prop_Send, "m_hMyWeapons");
	for (int i = 0; i < size; i++)
	{
		int wep = GetEntPropEnt(client, Prop_Send, "m_hMyWeapons", i);
		if (wep != -1 && IsValidEntity(wep))
		{
			RemovePlayerItem(client, wep);
			AcceptEntityInput(wep, "KillHierarchy");
		}
	}

	SetEntityHealth(client, 100);
	SetEntProp(client, Prop_Send, "m_ArmorValue", 100);
	SetEntProp(client, Prop_Send, "m_bHasHelmet", type == Round_Pistol ? 0 : 1);

	GivePlayerItem(client, "weapon_knife");
	GivePlayerItem(client, g_ArenaPistols[g_PrefPistol[client]]);
	if (type == Round_Rifle)
	{
		GivePlayerItem(client, g_ArenaRifles[g_PrefRifle[client]]);
		FakeClientCommandEx(client, "use %s", g_ArenaRifles[g_PrefRifle[client]]);
	}
	else if (type == Round_Awp)
	{
		GivePlayerItem(client, "weapon_awp");
		FakeClientCommandEx(client, "use weapon_awp");
	}
	else
	{
		FakeClientCommandEx(client, "use %s", g_ArenaPistols[g_PrefPistol[client]]);
	}
}

void ArenaOnDeath(int victimUserid)
{
	if (g_State != State_Arena || !g_ArenaRoundLive)
		return;
	for (int a = 0; a < g_ArenasInUse; a++)
	{
		if (g_ArenaWinner[a] != 0)
			continue;
		if (g_ArenaP[a][0] == victimUserid)
			ArenaDecide(a, g_ArenaP[a][1]);
		else if (g_ArenaP[a][1] == victimUserid)
			ArenaDecide(a, g_ArenaP[a][0]);
	}
}

void ArenaDecide(int a, int winnerUserid)
{
	if (g_ArenaWinner[a] != 0)
		return;
	g_ArenaWinner[a] = winnerUserid;

	for (int i = 0; i < g_ArenasInUse; i++)
	{
		if (g_ArenaWinner[i] == 0)
			return; // still fighting somewhere
	}
	ArenaEndRound();
}

public Action Timer_ArenaTimeout(Handle timer, int serial)
{
	if (g_State != State_Arena || serial != g_ArenaSerial || !g_ArenaRoundLive)
		return Plugin_Stop;

	for (int a = 0; a < g_ArenasInUse; a++)
	{
		if (g_ArenaWinner[a] != 0)
			continue;
		int c1 = GetClientOfUserId(g_ArenaP[a][0]);
		int c2 = GetClientOfUserId(g_ArenaP[a][1]);
		int h1 = (c1 > 0 && IsPlayerAlive(c1)) ? GetClientHealth(c1) : 0;
		int h2 = (c2 > 0 && IsPlayerAlive(c2)) ? GetClientHealth(c2) : 0;
		int winner;
		if (h1 != h2)
			winner = (h1 > h2) ? g_ArenaP[a][0] : g_ArenaP[a][1];
		else
			winner = g_ArenaP[a][GetRandomInt(0, 1)];
		if (c1 > 0)
			PrintToChat(c1, "%sTime's up in arena %d — decided on health.", PREFIX, a + 1);
		if (c2 > 0)
			PrintToChat(c2, "%sTime's up in arena %d — decided on health.", PREFIX, a + 1);
		g_ArenaWinner[a] = winner;
	}
	ArenaEndRound();
	return Plugin_Stop;
}

void ArenaEndRound()
{
	if (!g_ArenaRoundLive)
		return;
	g_ArenaRoundLive = false;

	int n = g_ArenasInUse;
	int winners[MAX_ARENAS], losers[MAX_ARENAS];
	for (int a = 0; a < n; a++)
	{
		winners[a] = g_ArenaWinner[a];
		losers[a] = (g_ArenaWinner[a] == g_ArenaP[a][0]) ? g_ArenaP[a][1] : g_ArenaP[a][0];
	}

	// Winners move up one arena, losers move down one:
	// [W1, W2, L1, W3, L2, ..., Wn, L(n-1)] + waiting players + [Ln] + everyone else
	ArrayList next = new ArrayList();
	next.Push(winners[0]);
	for (int a = 1; a < n; a++)
	{
		next.Push(winners[a]);
		next.Push(losers[a - 1]);
	}
	for (int i = 0; i < g_ArenaWaiting.Length; i++)
		next.Push(g_ArenaWaiting.Get(i));
	next.Push(losers[n - 1]);
	for (int i = 0; i < g_ArenaRank.Length; i++)
	{
		int uid = g_ArenaRank.Get(i);
		if (next.FindValue(uid) == -1)
			next.Push(uid);
	}

	delete g_ArenaRank;
	g_ArenaRank = next;

	for (int a = 0; a < n; a++)
	{
		int w = GetClientOfUserId(winners[a]);
		int l = GetClientOfUserId(losers[a]);
		if (w > 0)
			PrintToChat(w, "%sYou won arena %d%s.", PREFIX, a + 1, a > 0 ? " — moving up" : " — staying on top");
		if (l > 0)
			PrintToChat(l, "%sYou lost arena %d%s.", PREFIX, a + 1, a < n - 1 ? " — moving down" : "");
	}

	CS_TerminateRound(3.0, CSRoundEnd_Draw, true);
}

public Action Timer_SyncCompFlag(Handle timer)
{
	bool on = (g_State == State_Live || g_State == State_Knife || g_State == State_SideSelect
		|| g_State == State_Duel || g_State == State_Arena);
	if (g_cvCompActive.BoolValue != on)
		g_cvCompActive.BoolValue = on;
	return Plugin_Continue;
}

/* ------------------------------------------------------------------ */
/*  /login — admin by password (works in LAN mode, no SteamID needed)  */
/* ------------------------------------------------------------------ */

// SteamID when the server can see it, otherwise the player's IP.
void GetLoginKey(int client, char[] key, int maxlen)
{
	char auth[64];
	if (GetClientAuthId(client, AuthId_Steam2, auth, sizeof(auth), false)
		&& StrContains(auth, "STEAM_ID", false) == -1 && !StrEqual(auth, "BOT"))
	{
		if (strncmp(auth, "STEAM_1", 7) == 0)
			auth[6] = '0';
		strcopy(key, maxlen, auth);
		return;
	}
	char ip[32];
	GetClientIP(client, ip, sizeof(ip));
	Format(key, maxlen, "ip_%s", ip);
}

void GetAdminListPath(char[] path, int maxlen)
{
	BuildPath(Path_SM, path, maxlen, "data/csgo_match_admins.txt");
}

void GrantLoginAdmin(int client)
{
	SetUserFlagBits(client, GetUserFlagBits(client) | ADMFLAG_ROOT);
}

void CheckRememberedAdmin(int client)
{
	char path[PLATFORM_MAX_PATH], key[64], name[MAX_NAME_LENGTH];
	GetAdminListPath(path, sizeof(path));
	if (!FileExists(path))
		return;
	GetLoginKey(client, key, sizeof(key));

	KeyValues kv = new KeyValues("admins");
	if (kv.ImportFromFile(path))
	{
		kv.GetString(key, name, sizeof(name), "");
		if (name[0] != '\0')
		{
			GrantLoginAdmin(client);
			PrintToChat(client, "%sWelcome back — you're logged in as admin. (\x04/logout\x01 to stop)", PREFIX);
		}
	}
	delete kv;
}

void SetRemembered(int client, bool remember)
{
	char path[PLATFORM_MAX_PATH], key[64], name[MAX_NAME_LENGTH];
	GetAdminListPath(path, sizeof(path));
	GetLoginKey(client, key, sizeof(key));
	GetClientName(client, name, sizeof(name));

	KeyValues kv = new KeyValues("admins");
	kv.ImportFromFile(path);
	if (remember)
		kv.SetString(key, name);
	else
		kv.DeleteKey(key);
	kv.Rewind();
	kv.ExportToFile(path);
	delete kv;
}

bool TryLogin(int client, const char[] pass)
{
	char real[128];
	g_cvAdminPass.GetString(real, sizeof(real));
	if (real[0] == '\0')
	{
		PrintToChat(client, "%sAdmin login is turned off. Set \x04match_admin_password\x01 in cfg\\sourcemod\\csgo_match.cfg.", PREFIX);
		return false;
	}
	if (GetUserFlagBits(client) & ADMFLAG_ROOT)
	{
		PrintToChat(client, "%sYou're already an admin.", PREFIX);
		return true;
	}
	if (GetGameTime() < g_LoginLockUntil[client])
	{
		PrintToChat(client, "%sToo many wrong passwords — wait a minute and try again.", PREFIX);
		return false;
	}
	if (pass[0] == '\0')
	{
		PrintToChat(client, "%sUsage: \x04/login <password>\x01 (the / keeps it out of chat)", PREFIX);
		return false;
	}
	if (!StrEqual(pass, real))
	{
		if (++g_LoginFails[client] >= 3)
		{
			g_LoginFails[client] = 0;
			g_LoginLockUntil[client] = GetGameTime() + 60.0;
		}
		PrintToChat(client, "%sWrong password.", PREFIX);
		LogMessage("Failed admin login from %L", client);
		return false;
	}

	g_LoginFails[client] = 0;
	GrantLoginAdmin(client);
	SetRemembered(client, true);
	PrintToChat(client, "%sLogged in as admin. This PC is remembered — \x04/logout\x01 to forget it.", PREFIX);
	LogMessage("Admin login: %L", client);
	return true;
}

public Action Cmd_Login(int client, int args)
{
	if (client <= 0 || !IsClientInGame(client))
		return Plugin_Handled;
	if (g_LoginTick[client] == GetGameTickCount())
		return Plugin_Handled;
	g_LoginTick[client] = GetGameTickCount();
	char pass[128];
	GetCmdArgString(pass, sizeof(pass));
	StripQuotes(pass);
	TrimString(pass);
	TryLogin(client, pass);
	return Plugin_Handled;
}

public Action Cmd_Logout(int client, int args)
{
	if (client <= 0 || !IsClientInGame(client))
		return Plugin_Handled;
	SetRemembered(client, false);
	SetUserFlagBits(client, 0);
	PrintToChat(client, "%sLogged out. Admins from admins.cfg come back when you reconnect.", PREFIX);
	return Plugin_Handled;
}

// Keep "!login <password>" / ".login <password>" out of public chat.
public Action OnClientSayCommand(int client, const char[] command, const char[] sArgs)
{
	if (client <= 0)
		return Plugin_Continue;
	if ((sArgs[0] == '!' || sArgs[0] == '.') && strncmp(sArgs[1], "login", 5, false) == 0
		&& (sArgs[6] == ' ' || sArgs[6] == '\0'))
	{
		if (g_LoginTick[client] != GetGameTickCount())
		{
			g_LoginTick[client] = GetGameTickCount();
			char pass[128];
			strcopy(pass, sizeof(pass), sArgs[6]);
			TrimString(pass);
			StripQuotes(pass);
			TryLogin(client, pass);
		}
		return Plugin_Stop; // never show the password in chat
	}
	return Plugin_Continue;
}

/* ------------------------------------------------------------------ */
/*  Map downloads (players get maps they're missing from the server)  */
/* ------------------------------------------------------------------ */

void ApplyDownloadSettings()
{
	if (!g_cvMapDownloads.BoolValue)
		return;

	ConVar allow = FindConVar("sv_allowdownload");
	if (allow != null)
		allow.BoolValue = true;

	// FastDL: start_fastdl.bat writes this with the download address.
	if (FileExists("cfg/csgo_match/fastdl.cfg"))
		ServerCommand("exec csgo_match/fastdl.cfg");

	ConVar maxSize = FindConVar("net_maxfilesize");
	if (maxSize != null)
	{
		maxSize.IntValue = g_cvMaxDownloadMB.IntValue; // the game clamps this to its own limit
		if (maxSize.IntValue < g_cvMaxDownloadMB.IntValue)
			LogMessage("Map downloads: net_maxfilesize is capped at %d MB by the game. Bigger maps must be copied to players by hand.", maxSize.IntValue);
	}
}

/* ------------------------------------------------------------------ */
/*  !map — every map on the server                                    */
/* ------------------------------------------------------------------ */


int SortMapEntries(int index1, int index2, Handle array, Handle hndl)
{
	ArrayList list = view_as<ArrayList>(array);
	MapEntry a, b;
	list.GetArray(index1, a);
	list.GetArray(index2, b);
	return strcmp(a.name, b.name, false);
}

void AddMapEntry(ArrayList list, StringMap seen, const char[] path, const char[] name, int cat)
{
	int dummy;
	if (seen.GetValue(name, dummy))
		return;
	seen.SetValue(name, 1);
	MapEntry e;
	strcopy(e.path, sizeof(e.path), path);
	strcopy(e.name, sizeof(e.name), name);
	e.cat = cat;
	list.PushArray(e);
}

// Adds every .bsp directly inside `dir` (a path under csgo/).
void ScanMapDir(ArrayList list, StringMap seen, const char[] dir, const char[] prefix, int cat)
{
	DirectoryListing d = OpenDirectory(dir, true);
	if (d == null)
		return;
	char file[PLATFORM_MAX_PATH], path[PLATFORM_MAX_PATH];
	FileType type;
	while (d.GetNext(file, sizeof(file), type))
	{
		int len = strlen(file);
		if (type != FileType_File || len <= 4 || !StrEqual(file[len - 4], ".bsp", false))
			continue;
		file[len - 4] = '\0';
		Format(path, sizeof(path), "%s%s", prefix, file);
		AddMapEntry(list, seen, path, file, cat);
	}
	delete d;
}

ArrayList BuildMapList()
{
	ArrayList list = new ArrayList(sizeof(MapEntry));
	StringMap seen = new StringMap();
	char dir[PLATFORM_MAX_PATH], prefix[PLATFORM_MAX_PATH];

	// Mode folders first, so a map that's in one is listed under its mode.
	for (int i = 0; i < GM_COUNT; i++)
	{
		Format(dir, sizeof(dir), "maps/modes/%s", g_GmFolder[i]);
		Format(prefix, sizeof(prefix), "modes/%s/", g_GmFolder[i]);
		ScanMapDir(list, seen, dir, prefix, i);
	}
	ScanMapDir(list, seen, "maps", "", MAPCAT_ROOT);

	DirectoryListing ws = OpenDirectory("maps/workshop", true);
	if (ws != null)
	{
		char id[64];
		FileType type;
		while (ws.GetNext(id, sizeof(id), type))
		{
			if (type != FileType_Directory || id[0] == '.')
				continue;
			Format(dir, sizeof(dir), "maps/workshop/%s", id);
			Format(prefix, sizeof(prefix), "workshop/%s/", id);
			ScanMapDir(list, seen, dir, prefix, MAPCAT_WORKSHOP);
		}
		delete ws;
	}
	delete seen;

	SortADTArrayCustom(list, SortMapEntries);
	return list;
}

void Cmd_MapChange(int client, const char[] arg)
{
	if (!IsAdmin(client))
	{
		Reply(client, "Only admins can change the map.");
		return;
	}
	if (arg[0] != '\0')
	{
		ChangeMapByName(client, arg);
		return;
	}
	if (!CheckInGame(client))
		return;
	g_MapPickGm[client] = -1;
	ShowMapCategories(client);
}

// !map is SourceMod's sm_map command; take it over so modes/ and workshop maps work.
public Action Listener_Map(int client, const char[] command, int argc)
{
	char arg[PLATFORM_MAX_PATH];
	if (argc > 0)
		GetCmdArg(1, arg, sizeof(arg));
	if (client == 0 && argc == 0)
	{
		PrintToServer("[Match] Usage: sm_map <map name>  (short names work, e.g. sm_map am_walterv2)");
		return Plugin_Handled;
	}
	Cmd_MapChange(client, arg);
	return Plugin_Handled;
}

void ChangeMapByName(int client, const char[] name)
{
	char path[PLATFORM_MAX_PATH];
	ArrayList list = BuildMapList();
	MapEntry e;
	int found = -1, partial = -1, partialCount = 0;
	for (int i = 0; i < list.Length; i++)
	{
		list.GetArray(i, e);
		if (StrEqual(e.name, name, false) || StrEqual(e.path, name, false))
		{
			found = i;
			break;
		}
		if (StrContains(e.name, name, false) != -1)
		{
			partial = i;
			partialCount++;
		}
	}
	if (found == -1 && partialCount == 1)
		found = partial;

	if (found != -1)
	{
		list.GetArray(found, e);
		strcopy(path, sizeof(path), e.path);
	}
	delete list;

	if (found == -1)
	{
		if (partialCount > 1)
			Reply(client, "%d maps match \"%s\" — type more of the name, or use \x04!map\x01 for the list.", partialCount, name);
		else
			Reply(client, "No map called \"%s\" on the server. Type \x04!map\x01 for the list.", name);
		return;
	}
	ChangeMapOnly(client, path);
}

void ShowMapCategories(int client)
{
	ArrayList list = BuildMapList();
	int counts[GM_COUNT];
	int root = 0, workshop = 0;
	MapEntry e;
	for (int i = 0; i < list.Length; i++)
	{
		list.GetArray(i, e);
		if (e.cat == MAPCAT_ROOT)
			root++;
		else if (e.cat == MAPCAT_WORKSHOP)
			workshop++;
		else if (e.cat >= 0 && e.cat < GM_COUNT)
			counts[e.cat]++;
	}

	char current[PLATFORM_MAX_PATH], currentName[PLATFORM_MAX_PATH], mode[48], line[128], info[16];
	GetCurrentMap(current, sizeof(current));
	GetMapDisplayName(current, currentName, sizeof(currentName));
	GetModeName(mode, sizeof(mode));

	Menu menu = new Menu(Handler_MapCategories);
	menu.SetTitle("Change map\nNow: %s (%s)", currentName, mode);

	Format(line, sizeof(line), "All maps A-Z (%d)", list.Length);
	IntToString(MAPCAT_ALL, info, sizeof(info));
	menu.AddItem(info, line);

	Format(line, sizeof(line), "Main maps folder (%d)", root);
	IntToString(MAPCAT_ROOT, info, sizeof(info));
	menu.AddItem(info, line, root > 0 ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);

	for (int i = 0; i < GM_COUNT; i++)
	{
		if (counts[i] == 0)
			continue;
		Format(line, sizeof(line), "%s maps (%d)", g_GmName[i], counts[i]);
		IntToString(i, info, sizeof(info));
		menu.AddItem(info, line);
	}
	if (workshop > 0)
	{
		Format(line, sizeof(line), "Workshop maps (%d)", workshop);
		IntToString(MAPCAT_WORKSHOP, info, sizeof(info));
		menu.AddItem(info, line);
	}
	delete list;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int Handler_MapCategories(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_End)
	{
		delete menu;
	}
	else if (action == MenuAction_Select)
	{
		char info[16];
		menu.GetItem(item, info, sizeof(info));
		ShowAllMapsList(client, StringToInt(info));
	}
	return 0;
}

void ShowAllMapsList(int client, int cat)
{
	g_MapListCat[client] = cat;
	ArrayList list = BuildMapList();

	char current[PLATFORM_MAX_PATH], line[128];
	GetCurrentMap(current, sizeof(current));

	Menu menu = new Menu(Handler_AllMaps);
	if (g_MapPickGm[client] >= 0)
		menu.SetTitle("%s — any map", g_GmName[g_MapPickGm[client]]);
	else if (cat == MAPCAT_ALL)
		menu.SetTitle("All maps (%d)", list.Length);
	else if (cat == MAPCAT_ROOT)
		menu.SetTitle("Main maps folder");
	else if (cat == MAPCAT_WORKSHOP)
		menu.SetTitle("Workshop maps");
	else
		menu.SetTitle("%s maps", g_GmName[cat]);

	MapEntry e;
	int shown = 0;
	for (int i = 0; i < list.Length; i++)
	{
		list.GetArray(i, e);
		if (cat != MAPCAT_ALL && e.cat != cat)
			continue;

		if (StrEqual(e.path, current, false))
			Format(line, sizeof(line), "%s [current]", e.name);
		else if (cat == MAPCAT_ALL && e.cat >= 0)
			Format(line, sizeof(line), "%s  (%s)", e.name, g_GmName[e.cat]);
		else
			strcopy(line, sizeof(line), e.name);
		menu.AddItem(e.path, line);
		shown++;
	}
	if (shown == 0)
		menu.AddItem("", "No maps here", ITEMDRAW_DISABLED);
	delete list;

	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int Handler_AllMaps(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_End)
	{
		delete menu;
	}
	else if (action == MenuAction_Select)
	{
		char path[PLATFORM_MAX_PATH];
		menu.GetItem(item, path, sizeof(path));

		// Picking a map for !gamemode: switch mode + map together.
		if (g_MapPickGm[client] >= 0)
		{
			int gm = g_MapPickGm[client];
			g_MapPickGm[client] = -1;
			SwitchGameMode(client, gm, path);
			return 0;
		}

		// Map from a mode folder while the server is in another mode: ask.
		int folderMode = ModeOfMapPath(path);
		if (folderMode >= 0 && folderMode != CurrentMode())
		{
			strcopy(g_MapPickPath[client], sizeof(g_MapPickPath[]), path);
			ShowMapModeChoice(client, folderMode);
			return 0;
		}
		ChangeMapOnly(client, path);
	}
	else if (action == MenuAction_Cancel && item == MenuCancel_ExitBack)
	{
		if (g_MapPickGm[client] >= 0)
		{
			g_PickMode[client] = g_MapPickGm[client];
			g_MapPickGm[client] = -1;
			ShowModeMapMenu(client);
		}
		else
		{
			ShowMapCategories(client);
		}
	}
	return 0;
}

int ModeOfMapPath(const char[] path)
{
	if (strncmp(path, "modes/", 6, false) != 0)
		return -1;
	char folder[64];
	strcopy(folder, sizeof(folder), path[6]);
	int slash = FindCharInString(folder, '/');
	if (slash == -1)
		return -1;
	folder[slash] = '\0';
	for (int i = 0; i < GM_COUNT; i++)
	{
		if (StrEqual(g_GmFolder[i], folder, false))
			return i;
	}
	return -1;
}

void ShowMapModeChoice(int client, int gm)
{
	char name[PLATFORM_MAX_PATH], mode[48], line[128], info[16];
	GetMapDisplayName(g_MapPickPath[client], name, sizeof(name));
	GetModeName(mode, sizeof(mode));

	Menu menu = new Menu(Handler_MapModeChoice);
	menu.SetTitle("%s is a %s map.\nThe server is in %s.", name, g_GmName[gm], mode);
	IntToString(gm, info, sizeof(info));
	Format(line, sizeof(line), "Switch to %s on %s", g_GmName[gm], name);
	menu.AddItem(info, line);
	Format(line, sizeof(line), "Just change the map (stay in %s)", mode);
	menu.AddItem("keep", line);
	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int Handler_MapModeChoice(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_End)
	{
		delete menu;
	}
	else if (action == MenuAction_Select)
	{
		char info[16];
		menu.GetItem(item, info, sizeof(info));
		if (StrEqual(info, "keep"))
			ChangeMapOnly(client, g_MapPickPath[client]);
		else
			SwitchGameMode(client, StringToInt(info), g_MapPickPath[client]);
	}
	else if (action == MenuAction_Cancel && item == MenuCancel_ExitBack)
	{
		ShowAllMapsList(client, g_MapListCat[client]);
	}
	return 0;
}

void ChangeMapOnly(int client, const char[] path)
{
	if (g_State == State_Live || g_State == State_Knife || g_State == State_SideSelect)
		Announce("\x02The current match will be abandoned.");

	char name[PLATFORM_MAX_PATH];
	GetMapDisplayName(path, name, sizeof(name));
	strcopy(g_SwitchMap, sizeof(g_SwitchMap), path);
	Announce("%N is changing the map to \x04%s\x01 in 5 seconds...", client, name);
	CreateTimer(5.0, Timer_ChangeMap, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_ChangeMap(Handle timer)
{
	if (g_SwitchMap[0] == '\0')
		return Plugin_Stop;
	char target[PLATFORM_MAX_PATH];
	if (!ResolveMap(g_SwitchMap, target, sizeof(target)))
	{
		Announce("\x02Can't change map: %s isn't installed on the server.", g_SwitchMap);
		return Plugin_Stop;
	}
	ServerCommand("changelevel %s", target);
	return Plugin_Stop;
}

/* ------------------------------------------------------------------ */
/*  Reminders                                                         */
/* ------------------------------------------------------------------ */

public Action Timer_Remind(Handle timer)
{
	if (g_State == State_Warmup)
	{
		int ready;
		int total = CountPlayers(ready);
		int required = RequiredReady(total);
		for (int i = 1; i <= MaxClients; i++)
		{
			if (IsClientInGame(i) && !IsFakeClient(i) && IsOnPlayingTeam(i) && !g_Ready[i])
				PrintToChat(i, "%sYou're \x02not ready\x01. Type \x04!ready\x01 (%d/%d ready).", PREFIX, ready, required);
		}
	}
	else if (g_State == State_SideSelect)
	{
		Announce("Waiting for the knife winners: \x04!stay\x01 or \x04!switch\x01.");
	}
	else if (g_State == State_Live && g_Paused)
	{
		Announce("Match is paused. Both teams type \x04!unpause\x01 to resume.");
	}
	return Plugin_Continue;
}

/* ------------------------------------------------------------------ */
/*  Demos                                                             */
/* ------------------------------------------------------------------ */

void StartDemo(const char[] stamp)
{
	if (!g_cvDemoEnabled.BoolValue)
		return;

	ConVar tv = FindConVar("tv_enable");
	if (tv == null || !tv.BoolValue)
	{
		LogMessage("tv_enable is 0 — no demo recorded. Set tv_enable 1 in server.cfg and change map.");
		return;
	}

	StopDemo();

	char map[PLATFORM_MAX_PATH], prefix[64], demo[PLATFORM_MAX_PATH];
	GetCurrentMap(map, sizeof(map));
	GetMapDisplayName(map, map, sizeof(map));
	ReplaceString(map, sizeof(map), "/", "_");
	g_cvDemoPrefix.GetString(prefix, sizeof(prefix));

	Format(demo, sizeof(demo), "%s_%s_%s", prefix, stamp, map);
	ServerCommand("tv_record \"%s\"", demo);
	g_Recording = true;
	Announce("Recording demo: \x04%s.dem\x01", demo);
}

void StopDemo()
{
	if (!g_Recording)
		return;
	ServerCommand("tv_stoprecord");
	g_Recording = false;
}

/* ------------------------------------------------------------------ */
/*  Helpers                                                           */
/* ------------------------------------------------------------------ */

void WriteDefaultConfigs()
{
	if (!DirExists(CFG_DIR))
		CreateDirectory(CFG_DIR, 511);

	WriteDefaultCfg("warmup.cfg", g_CfgWarmup, sizeof(g_CfgWarmup));
	WriteDefaultCfg("knife.cfg", g_CfgKnife, sizeof(g_CfgKnife));
	WriteDefaultCfg("live.cfg", g_CfgLive, sizeof(g_CfgLive));
	WriteDefaultCfg("prac.cfg", g_CfgPrac, sizeof(g_CfgPrac));
	WriteDefaultCfg("duel.cfg", g_CfgDuel, sizeof(g_CfgDuel));
	WriteDefaultCfg("wingman.cfg", g_CfgWingman, sizeof(g_CfgWingman));
	WriteDefaultCfg("1v1.cfg", g_Cfg1v1, sizeof(g_Cfg1v1));
	WriteDefaultCfg("arena.cfg", g_CfgArena, sizeof(g_CfgArena));
}

void WriteDefaultCfg(const char[] name, const char[][] lines, int count)
{
	char path[PLATFORM_MAX_PATH];
	Format(path, sizeof(path), "%s/%s", CFG_DIR, name);
	if (FileExists(path))
		return;

	File f = OpenFile(path, "w");
	if (f == null)
	{
		LogError("Could not write %s", path);
		return;
	}
	f.WriteLine("// CS:GO Match %s — edit freely; the plugin never overwrites this file.", name);
	for (int i = 0; i < count; i++)
		f.WriteLine("%s", lines[i]);
	delete f;
}

bool IsOnPlayingTeam(int client)
{
	int team = GetClientTeam(client);
	return team == CS_TEAM_T || team == CS_TEAM_CT;
}

int OtherTeam(int team)
{
	return (team == CS_TEAM_T) ? CS_TEAM_CT : CS_TEAM_T;
}

bool IsAdmin(int client)
{
	return client == 0 || CheckCommandAccess(client, "match_admin", ADMFLAG_GENERIC);
}

bool RequireAdmin(int client)
{
	if (IsAdmin(client))
		return true;
	Reply(client, "You need admin access for that.");
	return false;
}

bool RequirePractice(int client)
{
	if (g_State == State_Practice)
		return true;
	Reply(client, "That only works in practice mode (!prac).");
	return false;
}

bool CheckInGame(int client)
{
	if (client > 0 && IsClientInGame(client))
		return true;
	Reply(client, "That command can only be used in-game.");
	return false;
}

void StripColors(char[] buf)
{
	int j = 0;
	for (int i = 0; buf[i] != '\0'; i++)
	{
		if (buf[i] > 0 && buf[i] < 0x11)
			continue;
		buf[j++] = buf[i];
	}
	buf[j] = '\0';
}

void Reply(int client, const char[] fmt, any ...)
{
	char buf[256];
	VFormat(buf, sizeof(buf), fmt, 3);
	if (client == 0)
	{
		StripColors(buf);
		PrintToServer("[Match] %s", buf);
	}
	else if (IsClientInGame(client))
	{
		PrintToChat(client, "%s%s", PREFIX, buf);
	}
}

void Announce(const char[] fmt, any ...)
{
	char buf[256];
	VFormat(buf, sizeof(buf), fmt, 2);
	PrintToChatAll("%s%s", PREFIX, buf);
}

/* ------------------------------------------------------------------ */
/*  Best of 3 — map veto by team vote, then 3 maps                    */
/* ------------------------------------------------------------------ */

bool WantSeries()
{
	return g_cvSeries.IntValue == 3 && CurrentMode() == GM_Competitive && !g_OneVOneNext;
}

void MapShortName(const char[] path, char[] out, int maxlen)
{
	int slash = FindCharInString(path, '/', true);
	strcopy(out, maxlen, path[slash + 1]);
}

bool SameMap(const char[] a, const char[] b)
{
	char x[PLATFORM_MAX_PATH], y[PLATFORM_MAX_PATH];
	MapShortName(a, x, sizeof(x));
	MapShortName(b, y, sizeof(y));
	return StrEqual(x, y, false);
}

int GetSeriesTeam(int client)
{
	char key[64];
	int team;
	GetLoginKey(client, key, sizeof(key));
	if (g_SeriesRoster.GetValue(key, team))
		return team;
	return -1;
}

void SetSeriesTeam(int client, int team)
{
	char key[64];
	GetLoginKey(client, key, sizeof(key));
	g_SeriesRoster.SetValue(key, team);
}

// Side team A starts this map on before any knife round/halftime.
int ExpectedSide(int team)
{
	int sideA = (g_KnifeEnabled || g_SeriesMapIndex % 2 == 0) ? CS_TEAM_CT : CS_TEAM_T;
	return team == SERIES_TEAM_A ? sideA : OtherTeam(sideA);
}

void CountRosterSides(int team, int exclude, int &ct, int &t)
{
	ct = 0;
	t = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (i == exclude || !IsClientInGame(i) || IsFakeClient(i) || GetSeriesTeam(i) != team)
			continue;
		int side = GetClientTeam(i);
		if (side == CS_TEAM_CT)
			ct++;
		else if (side == CS_TEAM_T)
			t++;
	}
}

// Which side (CT/T) a series team is on right now.
int SeriesSideOf(int team, int exclude)
{
	int ct, t;
	CountRosterSides(team, exclude, ct, t);
	if (ct != t)
		return ct > t ? CS_TEAM_CT : CS_TEAM_T;
	CountRosterSides(1 - team, exclude, ct, t);
	if (ct != t)
		return ct > t ? CS_TEAM_T : CS_TEAM_CT;
	return ExpectedSide(team);
}

int SeriesTeamOnSide(int side, int exclude)
{
	return SeriesSideOf(SERIES_TEAM_A, exclude) == side ? SERIES_TEAM_A : SERIES_TEAM_B;
}

void CleanTeamName(char[] name, int maxlen)
{
	ReplaceString(name, maxlen, "\"", "'");
	ReplaceString(name, maxlen, ";", "");
	TrimString(name);
}

void PickSeriesName(int team, int side)
{
	char cvName[16];
	Format(cvName, sizeof(cvName), "mp_teamname_%d", side == CS_TEAM_CT ? 1 : 2);
	ConVar cv = FindConVar(cvName);
	g_SeriesName[team][0] = '\0';
	if (cv != null)
		cv.GetString(g_SeriesName[team], sizeof(g_SeriesName[]));
	CleanTeamName(g_SeriesName[team], sizeof(g_SeriesName[]));
	if (g_SeriesName[team][0] != '\0')
		return;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i) && GetClientTeam(i) == side)
		{
			char player[MAX_NAME_LENGTH];
			GetClientName(i, player, sizeof(player));
			Format(g_SeriesName[team], sizeof(g_SeriesName[]), "Team %s", player);
			CleanTeamName(g_SeriesName[team], sizeof(g_SeriesName[]));
			return;
		}
	}
	strcopy(g_SeriesName[team], sizeof(g_SeriesName[]), team == SERIES_TEAM_A ? "Team A" : "Team B");
}

// Scoreboard names follow the teams from map to map.
void SeriesApplyTeamNames()
{
	if (!g_SeriesActive)
		return;
	int sideA = SeriesSideOf(SERIES_TEAM_A, 0);
	int onCT = (sideA == CS_TEAM_CT) ? SERIES_TEAM_A : SERIES_TEAM_B;
	ServerCommand("mp_teamname_1 \"%s\"", g_SeriesName[onCT]);
	ServerCommand("mp_teamname_2 \"%s\"", g_SeriesName[1 - onCT]);
}

void CancelSeries(const char[] message)
{
	g_VetoRunning = false;
	g_SeriesActive = false;
	g_SeriesShowLast = false;
	g_VetoSerial++;
	delete g_VetoTimer;
	g_SeriesRoster.Clear();
	if (message[0] != '\0')
		Announce("%s", message);
}

/* ---------- Veto ---------- */

bool StartVeto()
{
	g_VetoPool.Clear();
	ArrayList names = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));
	ReadModeMapList(GM_Competitive, names);
	char name[PLATFORM_MAX_PATH], path[PLATFORM_MAX_PATH], other[PLATFORM_MAX_PATH];
	for (int i = 0; i < names.Length && g_VetoPool.Length < VETO_MAX_POOL; i++)
	{
		names.GetString(i, name, sizeof(name));
		if (!MapInstalled(GM_Competitive, name, path, sizeof(path)))
			continue;
		bool dupe = false;
		for (int j = 0; j < g_VetoPool.Length && !dupe; j++)
		{
			g_VetoPool.GetString(j, other, sizeof(other));
			dupe = SameMap(other, path);
		}
		if (!dupe)
			g_VetoPool.PushString(path);
	}
	delete names;

	if (g_VetoPool.Length < 3)
	{
		Announce("Best of 3 needs at least 3 installed maps in \x04maps\\modes\\competitive\\maplist.txt\x01 — playing this map only.");
		return false;
	}

	// Teams: whoever is on CT now is team A, T is team B.
	g_SeriesRoster.Clear();
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || IsFakeClient(i))
			continue;
		int side = GetClientTeam(i);
		if (side == CS_TEAM_CT)
			SetSeriesTeam(i, SERIES_TEAM_A);
		else if (side == CS_TEAM_T)
			SetSeriesTeam(i, SERIES_TEAM_B);
	}
	PickSeriesName(SERIES_TEAM_A, CS_TEAM_CT);
	PickSeriesName(SERIES_TEAM_B, CS_TEAM_T);

	// Ban, ban, pick, pick, then ban down to one map: the decider.
	int bans = g_VetoPool.Length - 3;
	int early = bans < 2 ? bans : 2;
	g_VetoSeqLen = 0;
	for (int i = 0; i < early; i++)
		AddVetoStep(i % 2, VETO_BAN);
	AddVetoStep(SERIES_TEAM_A, VETO_PICK);
	AddVetoStep(SERIES_TEAM_B, VETO_PICK);
	for (int i = 0; i < bans - early; i++)
		AddVetoStep(i % 2, VETO_BAN);

	for (int m = 0; m < 3; m++)
	{
		g_SeriesMaps[m][0] = '\0';
		g_SeriesMapNote[m][0] = '\0';
		g_SeriesResult[m] = -1;
	}
	g_SeriesWins[0] = 0;
	g_SeriesWins[1] = 0;
	g_SeriesMapIndex = 0;
	g_VetoPicks = 0;
	g_VetoStep = 0;
	g_SeriesActive = false;
	g_SeriesShowLast = false;
	g_VetoRunning = true;
	g_VetoSerial++;

	Announce("\x04BEST OF 3\x01 — map vote: \x0B%s\x01 vs \x09%s\x01.", g_SeriesName[SERIES_TEAM_A], g_SeriesName[SERIES_TEAM_B]);
	Announce("Each team votes in a menu on its turn: ban, ban, pick, pick, then bans down to the decider.");
	CreateTimer(3.0, Timer_VetoNext, g_VetoSerial, TIMER_FLAG_NO_MAPCHANGE);
	return true;
}

void AddVetoStep(int team, int action)
{
	if (g_VetoSeqLen >= sizeof(g_VetoSeqTeam))
		return;
	g_VetoSeqTeam[g_VetoSeqLen] = team;
	g_VetoSeqAction[g_VetoSeqLen] = action;
	g_VetoSeqLen++;
}

public Action Timer_VetoNext(Handle timer, int serial)
{
	if (g_VetoRunning && serial == g_VetoSerial)
		VetoRunStep();
	return Plugin_Stop;
}

void VetoRunStep()
{
	if (g_VetoStep >= g_VetoSeqLen)
	{
		VetoFinish();
		return;
	}

	g_VetoSerial++;
	for (int i = 0; i <= MaxClients; i++)
		g_VetoVote[i] = -1;

	int team = g_VetoSeqTeam[g_VetoStep];
	bool pick = (g_VetoSeqAction[g_VetoStep] == VETO_PICK);
	int secs = g_cvVetoTime.IntValue;

	char list[256], name[PLATFORM_MAX_PATH], path[PLATFORM_MAX_PATH];
	for (int j = 0; j < g_VetoPool.Length; j++)
	{
		g_VetoPool.GetString(j, path, sizeof(path));
		MapShortName(path, name, sizeof(name));
		Format(list, sizeof(list), "%s%s%s", list, j > 0 ? ", " : "", name);
	}

	if (pick)
		Announce("\x04%s\x01 is voting to \x04PICK\x01 map %d (%ds). Maps left: %s", g_SeriesName[team], g_VetoPicks + 1, secs, list);
	else
		Announce("\x04%s\x01 is voting to \x02BAN\x01 a map (%ds). Maps left: %s", g_SeriesName[team], secs, list);

	int voters = 0;
	char info[16];
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || IsFakeClient(i) || GetSeriesTeam(i) != team)
			continue;
		voters++;
		Menu menu = new Menu(Handler_Veto);
		menu.SetTitle("%s — %s\n%s", g_SeriesName[team], pick ? "PICK a map to play" : "BAN a map",
			"Your team votes. Most votes wins.");
		for (int j = 0; j < g_VetoPool.Length; j++)
		{
			g_VetoPool.GetString(j, path, sizeof(path));
			MapShortName(path, name, sizeof(name));
			Format(info, sizeof(info), "%d:%d", g_VetoSerial, j);
			menu.AddItem(info, name);
		}
		menu.ExitButton = false;
		menu.Display(i, secs);
	}

	if (voters == 0)
	{
		VetoApply(GetRandomInt(0, g_VetoPool.Length - 1), " (no players on that team — random)");
		return;
	}
	delete g_VetoTimer;
	g_VetoTimer = CreateTimer(float(secs), Timer_VetoTimeout, g_VetoSerial, TIMER_FLAG_NO_MAPCHANGE);
}

public int Handler_Veto(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_End)
	{
		delete menu;
	}
	else if (action == MenuAction_Select)
	{
		char info[16], parts[2][8];
		menu.GetItem(item, info, sizeof(info));
		ExplodeString(info, ":", parts, sizeof(parts), sizeof(parts[]));
		int serial = StringToInt(parts[0]);
		int idx = StringToInt(parts[1]);
		if (!g_VetoRunning || serial != g_VetoSerial || idx < 0 || idx >= g_VetoPool.Length)
			return 0;
		int team = g_VetoSeqTeam[g_VetoStep];
		if (GetSeriesTeam(client) != team)
			return 0;

		g_VetoVote[client] = idx;
		char path[PLATFORM_MAX_PATH], name[PLATFORM_MAX_PATH];
		g_VetoPool.GetString(idx, path, sizeof(path));
		MapShortName(path, name, sizeof(name));
		for (int i = 1; i <= MaxClients; i++)
		{
			if (IsClientInGame(i) && !IsFakeClient(i) && GetSeriesTeam(i) == team)
				PrintToChat(i, "%s%N voted \x04%s\x01.", PREFIX, client, name);
		}
		VetoCheckDone();
	}
	return 0;
}

public void Frame_VetoCheckDone(int serial)
{
	if (g_VetoRunning && serial == g_VetoSerial)
		VetoCheckDone();
}

// Everyone on the voting team has voted (or left): don't wait for the timer.
void VetoCheckDone()
{
	if (g_VetoStep >= g_VetoSeqLen)
		return;
	int team = g_VetoSeqTeam[g_VetoStep];
	int voters = 0, voted = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || IsFakeClient(i) || GetSeriesTeam(i) != team)
			continue;
		voters++;
		if (g_VetoVote[i] != -1)
			voted++;
	}
	if (voted == voters)
		VetoResolve();
}

public Action Timer_VetoTimeout(Handle timer, int serial)
{
	g_VetoTimer = null;
	if (g_VetoRunning && serial == g_VetoSerial)
		VetoResolve();
	return Plugin_Stop;
}

void VetoResolve()
{
	delete g_VetoTimer;

	int counts[VETO_MAX_POOL];
	int total = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		int v = g_VetoVote[i];
		if (v >= 0 && v < g_VetoPool.Length && v < VETO_MAX_POOL)
		{
			counts[v]++;
			total++;
		}
	}

	if (total == 0)
	{
		VetoApply(GetRandomInt(0, g_VetoPool.Length - 1), " (no votes — random)");
		return;
	}

	int best = 0;
	for (int j = 0; j < g_VetoPool.Length; j++)
	{
		if (counts[j] > best)
			best = counts[j];
	}
	int tied[VETO_MAX_POOL], n = 0;
	for (int j = 0; j < g_VetoPool.Length; j++)
	{
		if (counts[j] == best)
			tied[n++] = j;
	}
	VetoApply(tied[GetRandomInt(0, n - 1)], n > 1 ? " (tied vote — random of the tied maps)" : "");
}

void VetoApply(int idx, const char[] note)
{
	int team = g_VetoSeqTeam[g_VetoStep];
	bool pick = (g_VetoSeqAction[g_VetoStep] == VETO_PICK);

	char path[PLATFORM_MAX_PATH], name[PLATFORM_MAX_PATH];
	g_VetoPool.GetString(idx, path, sizeof(path));
	MapShortName(path, name, sizeof(name));

	if (pick && g_VetoPicks < 2)
	{
		strcopy(g_SeriesMaps[g_VetoPicks], sizeof(g_SeriesMaps[]), path);
		Format(g_SeriesMapNote[g_VetoPicks], sizeof(g_SeriesMapNote[]), "picked by %s", g_SeriesName[team]);
		g_VetoPicks++;
		Announce("\x04%s\x01 picked \x04%s\x01 — map %d%s", g_SeriesName[team], name, g_VetoPicks, note);
	}
	else
	{
		Announce("\x04%s\x01 banned \x02%s\x01%s", g_SeriesName[team], name, note);
	}

	g_VetoPool.Erase(idx);
	g_VetoStep++;
	g_VetoSerial++; // old menus stop counting
	CreateTimer(2.0, Timer_VetoNext, g_VetoSerial, TIMER_FLAG_NO_MAPCHANGE);
}

void VetoFinish()
{
	if (g_VetoPool.Length > 0)
		g_VetoPool.GetString(0, g_SeriesMaps[2], sizeof(g_SeriesMaps[]));
	strcopy(g_SeriesMapNote[2], sizeof(g_SeriesMapNote[]), "decider");
	g_VetoRunning = false;
	g_SeriesActive = true;
	g_SeriesMapIndex = 0;

	char a[PLATFORM_MAX_PATH], b[PLATFORM_MAX_PATH], c[PLATFORM_MAX_PATH];
	MapShortName(g_SeriesMaps[0], a, sizeof(a));
	MapShortName(g_SeriesMaps[1], b, sizeof(b));
	MapShortName(g_SeriesMaps[2], c, sizeof(c));
	Announce("\x04Maps:\x01 1. \x04%s\x01  2. \x04%s\x01  3. \x04%s\x01 (decider)", a, b, c);

	char current[PLATFORM_MAX_PATH];
	GetCurrentMap(current, sizeof(current));
	if (SameMap(current, g_SeriesMaps[0]))
	{
		Announce("Map 1 is this map — starting in 5 seconds!");
		CreateTimer(5.0, Timer_SeriesStartHere, _, TIMER_FLAG_NO_MAPCHANGE);
	}
	else
	{
		Announce("Changing to \x04%s\x01 in 8 seconds. Type \x04!ready\x01 again there.", a);
		CreateTimer(8.0, Timer_SeriesChangeMap, _, TIMER_FLAG_NO_MAPCHANGE);
	}
}

public Action Timer_SeriesStartHere(Handle timer)
{
	if (g_SeriesActive && g_State == State_Warmup)
		StartMatch();
	return Plugin_Stop;
}

public Action Timer_SeriesChangeMap(Handle timer)
{
	if (g_SeriesActive)
	{
		char target[PLATFORM_MAX_PATH];
		if (ResolveMap(g_SeriesMaps[g_SeriesMapIndex], target, sizeof(target)))
			ForceChangeLevel(target, "Best of 3");
		else
			Announce("\x02Can't load %s - it isn't installed on the server. Use !endseries.", g_SeriesMaps[g_SeriesMapIndex]);
	}
	return Plugin_Stop;
}

/* ---------- Between maps ---------- */

void SeriesOnMapStart()
{
	if (!g_SeriesActive)
		return;
	char current[PLATFORM_MAX_PATH];
	GetCurrentMap(current, sizeof(current));
	if (!SameMap(current, g_SeriesMaps[g_SeriesMapIndex]) || g_PracticeNext
		|| g_ArenaNext || g_OneVOneNext)
	{
		LogMessage("Best-of-3 series cancelled: %s was loaded instead of %s.", current, g_SeriesMaps[g_SeriesMapIndex]);
		CancelSeries("");
		return;
	}
	CreateTimer(10.0, Timer_SeriesAnnounce, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_SeriesAnnounce(Handle timer)
{
	if (g_SeriesActive && g_State == State_Warmup)
	{
		Announce("Best of 3 — \x04map %d of 3\x01. %s \x04%d - %d\x01 %s. Type \x04!ready\x01 to start.",
			g_SeriesMapIndex + 1, g_SeriesName[SERIES_TEAM_A], g_SeriesWins[SERIES_TEAM_A],
			g_SeriesWins[SERIES_TEAM_B], g_SeriesName[SERIES_TEAM_B]);
	}
	return Plugin_Stop;
}

void SeriesOnMatchEnd()
{
	int ct = CS_GetTeamScore(CS_TEAM_CT);
	int t = CS_GetTeamScore(CS_TEAM_T);
	int idx = g_SeriesMapIndex;
	char map[PLATFORM_MAX_PATH];
	MapShortName(g_SeriesMaps[idx], map, sizeof(map));

	if (ct == t)
	{
		g_SeriesResult[idx] = 2;
		Announce("Map %d (\x04%s\x01) was a \x04draw\x01 (%d-%d).", idx + 1, map, ct, t);
	}
	else
	{
		int winSide = ct > t ? CS_TEAM_CT : CS_TEAM_T;
		int winner = SeriesTeamOnSide(winSide, 0);
		g_SeriesResult[idx] = winner;
		g_SeriesWins[winner]++;
		Announce("\x04%s\x01 won map %d (\x04%s\x01) %d-%d.", g_SeriesName[winner], idx + 1, map,
			ct > t ? ct : t, ct > t ? t : ct);
	}
	Announce("Series: %s \x04%d - %d\x01 %s", g_SeriesName[SERIES_TEAM_A], g_SeriesWins[SERIES_TEAM_A],
		g_SeriesWins[SERIES_TEAM_B], g_SeriesName[SERIES_TEAM_B]);

	if (g_SeriesWins[SERIES_TEAM_A] >= 2 || g_SeriesWins[SERIES_TEAM_B] >= 2 || idx >= 2)
	{
		if (g_SeriesWins[SERIES_TEAM_A] != g_SeriesWins[SERIES_TEAM_B])
		{
			int champ = g_SeriesWins[SERIES_TEAM_A] > g_SeriesWins[SERIES_TEAM_B] ? SERIES_TEAM_A : SERIES_TEAM_B;
			Announce("\x04%s WIN THE SERIES %d-%d!\x01 GG!", g_SeriesName[champ], g_SeriesWins[champ], g_SeriesWins[1 - champ]);
		}
		else
		{
			Announce("The series ends level, %d-%d. GG!", g_SeriesWins[0], g_SeriesWins[1]);
		}
		g_SeriesActive = false;
		g_SeriesShowLast = true;
		g_SeriesRoster.Clear();
		Announce("Type \x04!restart\x01 (admin) or change map for a new match.");
		return;
	}

	g_SeriesMapIndex++;
	char next[PLATFORM_MAX_PATH];
	MapShortName(g_SeriesMaps[g_SeriesMapIndex], next, sizeof(next));
	Announce("Next: map %d, \x04%s\x01 — changing in 20 seconds.", g_SeriesMapIndex + 1, next);
	CreateTimer(20.0, Timer_SeriesChangeMap, _, TIMER_FLAG_NO_MAPCHANGE);
}

/* ---------- Keeping teams together ---------- */

void SeriesOnJoin(int client)
{
	if ((g_SeriesActive || g_VetoRunning) && GetSeriesTeam(client) >= 0)
		CreateTimer(1.0, Timer_SeriesPlace, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_SeriesPlace(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (client <= 0 || !IsClientInGame(client) || !(g_SeriesActive || g_VetoRunning))
		return Plugin_Stop;
	int team = GetSeriesTeam(client);
	if (team < 0 || GetClientTeam(client) != CS_TEAM_NONE)
		return Plugin_Stop;
	int side = SeriesSideOf(team, client);
	ChangeClientTeam(client, side);
	PrintToChat(client, "%sYou're with \x04%s\x01 (best of 3) — put on %s.", PREFIX, g_SeriesName[team],
		side == CS_TEAM_CT ? "CT" : "T");
	return Plugin_Stop;
}

Action SeriesJoinTeam(int client)
{
	if (!(g_SeriesActive || g_VetoRunning) || IsFakeClient(client))
		return Plugin_Continue;
	int team = GetSeriesTeam(client);
	if (team < 0)
		return Plugin_Continue; // not in the series yet: free to choose (joins that side's team)

	char arg[8];
	GetCmdArg(1, arg, sizeof(arg));
	int wanted = StringToInt(arg);
	if (wanted == CS_TEAM_SPECTATOR)
		return Plugin_Continue;

	int side = SeriesSideOf(team, client);
	if (wanted == side)
		return Plugin_Continue;
	if (GetClientTeam(client) != side)
		ChangeClientTeam(client, side);
	PrintToChat(client, "%sYou're with \x04%s\x01 for this best of 3 — they're on %s.", PREFIX, g_SeriesName[team],
		side == CS_TEAM_CT ? "CT" : "T");
	return Plugin_Handled;
}

// Someone new (e.g. a sub) joins a side during the series: they join that team.
public void Event_SeriesTeam(Event event, const char[] name, bool dontBroadcast)
{
	if (!(g_SeriesActive || g_VetoRunning) || event.GetBool("disconnect"))
		return;
	int client = GetClientOfUserId(event.GetInt("userid"));
	int side = event.GetInt("team");
	if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client))
		return;
	if ((side != CS_TEAM_T && side != CS_TEAM_CT) || GetSeriesTeam(client) >= 0)
		return;
	int team = SeriesTeamOnSide(side, client);
	SetSeriesTeam(client, team);
	PrintToChat(client, "%sYou've joined \x04%s\x01 for this best of 3.", PREFIX, g_SeriesName[team]);
}

/* ---------- Commands ---------- */

void Cmd_Series(int client)
{
	if (g_VetoRunning)
	{
		Reply(client, "The best-of-3 map vote is running.");
		return;
	}
	if (!g_SeriesActive && !g_SeriesShowLast)
	{
		if (WantSeries())
			Reply(client, "Best of 3 is on — the map vote starts when everyone is \x04!ready\x01.");
		else
			Reply(client, "No best of 3 running. Admins can turn it on with \x04!bo3\x01 (Competitive 5v5).");
		return;
	}

	Reply(client, "%s: %s \x04%d - %d\x01 %s", g_SeriesActive ? "Best of 3" : "Last best of 3",
		g_SeriesName[SERIES_TEAM_A], g_SeriesWins[SERIES_TEAM_A], g_SeriesWins[SERIES_TEAM_B], g_SeriesName[SERIES_TEAM_B]);
	char map[PLATFORM_MAX_PATH], result[96];
	for (int i = 0; i < 3; i++)
	{
		MapShortName(g_SeriesMaps[i], map, sizeof(map));
		int r = g_SeriesResult[i];
		if (r == 0 || r == 1)
			Format(result, sizeof(result), "won by %s", g_SeriesName[r]);
		else if (r == 2)
			strcopy(result, sizeof(result), "draw");
		else if (g_SeriesActive && i == g_SeriesMapIndex)
			strcopy(result, sizeof(result), "playing now");
		else if (g_SeriesActive)
			strcopy(result, sizeof(result), "to play");
		else
			strcopy(result, sizeof(result), "not needed");
		Reply(client, "  %d. \x04%s\x01 (%s) — %s", i + 1, map, g_SeriesMapNote[i], result);
	}
}

void Cmd_Bo3(int client)
{
	if (!RequireAdmin(client))
		return;
	g_cvSeries.IntValue = 3;
	SaveOptions();
	if (CurrentMode() != GM_Competitive)
	{
		Reply(client, "Best of 3 is on, but it only runs in \x04Competitive 5v5\x01 — switch with \x04!gamemode\x01.");
		return;
	}
	if (g_SeriesActive || g_VetoRunning)
	{
		Reply(client, "A best of 3 is already running. \x04!series\x01 shows it.");
		return;
	}
	Announce("\x04Best of 3\x01 is on: when everyone is \x04!ready\x01, each team votes to ban and pick maps.");
	if (g_State == State_Warmup)
		CheckReady();
}

void Cmd_Bo1(int client)
{
	if (!RequireAdmin(client))
		return;
	g_cvSeries.IntValue = 1;
	SaveOptions();
	if (g_SeriesActive || g_VetoRunning)
		Reply(client, "Set to single map from the next match. Type \x04!endseries\x01 to stop the series that's running.");
	else
		Announce("Matches are back to a \x04single map\x01.");
}

void Cmd_EndSeries(int client)
{
	if (!RequireAdmin(client))
		return;
	if (!g_SeriesActive && !g_VetoRunning)
	{
		Reply(client, "No best of 3 is running.");
		return;
	}
	char msg[128];
	if (client > 0)
		Format(msg, sizeof(msg), "%N ended the best-of-3 series.", client);
	else
		strcopy(msg, sizeof(msg), "The best-of-3 series was ended.");
	bool wasVeto = g_VetoRunning;
	CancelSeries(msg);
	if (wasVeto && g_State == State_Warmup)
		Announce("Back to warmup. \x04!ready\x01 starts a new map vote — or an admin can type \x04!bo1\x01 for a single map.");
}


// Headshots-only duels: hits anywhere but the head do nothing.
public Action Hook_DuelTraceAttack(int victim, int &attacker, int &inflictor, float &damage, int &damagetype, int &ammotype, int hitbox, int hitgroup)
{
	if (g_State != State_Duel || !g_DuelHs)
		return Plugin_Continue;
	if (attacker < 1 || attacker > MaxClients || attacker == victim)
		return Plugin_Continue;
	if (hitgroup == 1) // head
		return Plugin_Continue;
	return Plugin_Handled;
}
