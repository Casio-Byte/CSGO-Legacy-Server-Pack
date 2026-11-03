/*
 * CS:GO Loadout — all-in-one skin plugin for CS:GO (SourceMod 1.11+)
 *
 *  Weapon skins (paint, wear, pattern, StatTrak, name tag), stickers,
 *  knives, gloves, agents and agent patches — all from in-game menus.
 *  Every player's loadout is saved to its own file:
 *      addons/sourcemod/data/csgo_loadout/<steamid>.cfg
 *
 *  Item data (skins, stickers, agents, patches) is read from the server's own
 *  scripts/items/items_game.txt at startup, so it always matches the game.
 *
 *  Chat commands: !ws  !loadout  !presets  !knife  !gloves  !agents  !patches  !stickers  !gen
 *
 *  Requirements
 *    - SourceMod 1.11+ with FollowCSGOServerGuidelines set to "no" in
 *      addons/sourcemod/configs/core.cfg (needed for knives and skins)
 *    - Stickers only: gamedata/csgo_loadout.games.txt, and on Windows servers
 *      the Source Scramble extension (github.com/nosoop/SMExt-SourceScramble)
 *
 *  Credits: weapon/glove prop handling follows kgns' Weapons & Knives and Gloves
 *  plugins; the sticker attribute method and gamedata come from quasemago's
 *  CS:GO Weapon Stickers. All GPLv3.
 */

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <cstrike>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "1.4.0-20261103"
#define PREFIX " \x01[\x04Loadout\x01] "
#define MAX_STICKER_SLOTS 4
#define MAX_PATCH_SLOTS 3   // agents have three patch spots
#define MAX_SEARCH_RESULTS 250
#define NAME_LEN 64

/* ------------------------------------------------------------------ */
/*  Optional Source Scramble natives (only used for stickers on        */
/*  Windows). Declared inline so the plugin compiles without extra     */
/*  include files.                                                     */
/* ------------------------------------------------------------------ */

methodmap MemoryBlock < Handle
{
	public native MemoryBlock(int size);
	property Address Address
	{
		public native get();
	}
}

public Extension __ext_sourcescramble =
{
	name = "Source Scramble",
	file = "sourcescramble.ext",
	autoload = 1,
	required = 0,
};

/* Optional PTaH extension: forces a client full update so new stickers show
   straight away (the same thing the original Weapon Stickers plugin does). */
native void PTaH_ForceFullUpdate(int client);

public Extension __ext_PTaH =
{
	name = "PTaH",
	file = "PTaH.ext",
	autoload = 1,
	required = 0,
};

public Plugin myinfo =
{
	name        = "CS:GO Loadout",
	author      = "CS:GO Loadout",
	description = "Skins, stickers, knives, gloves, agents and patches from in-game menus",
	version     = PLUGIN_VERSION,
	url         = ""
};

/* ------------------------------------------------------------------ */
/*  Types                                                             */
/* ------------------------------------------------------------------ */

enum
{
	Cat_Pistol = 0,
	Cat_Rifle,
	Cat_SMG,
	Cat_Heavy,
	Cat_Knife
};

enum struct WeaponInfo
{
	int def;
	char cls[40];
	char name[32];
	int cat;
}

enum struct GloveInfo
{
	int def;
	char name[32];
	char prefix[48];
}

enum struct NamedId
{
	int id;
	char name[NAME_LEN];
}

enum struct AgentInfo
{
	int def;
	int team;
	char name[NAME_LEN];
	char model[PLATFORM_MAX_PATH];
}

enum struct WeaponSkin
{
	int paint;
	float wear;
	int seed;
	int stattrak;            // -1 = off, otherwise kill count
	char nametag[33];
	int sticker[MAX_STICKER_SLOTS];
	float stickerWear[MAX_STICKER_SLOTS];
}

// Loadout slots: game default weapon -> alternative the player can pick instead.
enum
{
	Slot_USP = 0,
	Slot_M4A1S,
	Slot_CT_CZ,
	Slot_T_CZ,
	Slot_R8,
	Slot_MP5,
	SLOT_COUNT
};

int g_SlotDefault[SLOT_COUNT] = { 32, 16, 3, 30, 1, 33 };   // P2000, M4A4, Five-SeveN, Tec-9, Deagle, MP7
int g_SlotAlt[SLOT_COUNT]     = { 61, 60, 63, 63, 64, 23 }; // USP-S, M4A1-S, CZ75, CZ75, R8, MP5-SD
int g_SlotTeam[SLOT_COUNT]    = { 0, 0, 3, 2, 0, 0 };       // 0 = both teams, 2 = T, 3 = CT
char g_SlotTitle[SLOT_COUNT][] = { "CT starting pistol", "CT rifle", "CT pistol", "T pistol", "Heavy pistol", "SMG" };

enum InputMode
{
	Input_None = 0,
	Input_SkinSearch,
	Input_Wear,
	Input_Seed,
	Input_NameTag,
	Input_StickerSearch,
	Input_StickerId,
	Input_StickerWear,
	Input_PatchSearch,
	Input_PatchId,
	Input_GloveWear,
	Input_GloveSeed
};

/* ------------------------------------------------------------------ */
/*  Item data                                                         */
/* ------------------------------------------------------------------ */

ArrayList g_Weapons;          // WeaponInfo
ArrayList g_Gloves;           // GloveInfo
ArrayList g_Stickers;         // NamedId, sorted by name
ArrayList g_Patches;          // NamedId, sorted by name
ArrayList g_Agents;           // AgentInfo, sorted by name

StringMap g_Loc;              // lowercase localisation token -> text
StringMap g_PaintByName;      // paint kit internal name -> id
StringMap g_PaintDisplay;     // "id" -> display name
StringMap g_KitDisplay;       // "id" -> sticker/patch display name
StringMap g_ItemSkins;        // item prefix (weapon class / glove name) -> ArrayList of paint ids
StringMap g_SkinSeen;         // "prefix|id" dedupe

bool g_ItemsLoaded = false;

/* ------------------------------------------------------------------ */
/*  Player data                                                       */
/* ------------------------------------------------------------------ */

StringMap g_Skins[MAXPLAYERS + 1];        // "def" -> WeaponSkin
KeyValues g_Presets = null;               // configs/csgo_loadout_presets.cfg
int   g_Knife[MAXPLAYERS + 1];
int   g_GloveDef[MAXPLAYERS + 1];
int   g_GlovePaint[MAXPLAYERS + 1];
float g_GloveWear[MAXPLAYERS + 1];
int   g_GloveSeed[MAXPLAYERS + 1];
int   g_AgentT[MAXPLAYERS + 1];
int   g_AgentCT[MAXPLAYERS + 1];
int   g_Patch[MAXPLAYERS + 1][MAX_PATCH_SLOTS];
bool  g_ThirdPerson[MAXPLAYERS + 1];
Handle g_PreviewTimer[MAXPLAYERS + 1];
char  g_FileKey[MAXPLAYERS + 1][64];
bool  g_Loaded[MAXPLAYERS + 1];

bool  g_SlotAltOn[MAXPLAYERS + 1][SLOT_COUNT];  // true = use the alternative weapon
bool  g_SlotsSet[MAXPLAYERS + 1];               // player has confirmed their choices
bool  g_SlotsPrompted[MAXPLAYERS + 1];          // prompt shown this connection
float g_LastBuyTime[MAXPLAYERS + 1];
char  g_LastBuyAlias[MAXPLAYERS + 1][32];

InputMode g_Input[MAXPLAYERS + 1];
int   g_MenuDef[MAXPLAYERS + 1];
int   g_MenuSlot[MAXPLAYERS + 1];
int   g_MenuCat[MAXPLAYERS + 1];
int   g_MenuTeam[MAXPLAYERS + 1];
float g_LastKnifeGive[MAXPLAYERS + 1];   // start of the current retry window (engine time)
int   g_KnifeTries[MAXPLAYERS + 1];
bool  g_KnifeWarned = false;

int g_EntOwner[2049];         // userid whose skin is on this weapon (0 = none)

/* ------------------------------------------------------------------ */
/*  Sticker internals                                                 */
/* ------------------------------------------------------------------ */

bool    g_StickersReady = false;
bool    g_IsWindows = false;
Handle  g_SDKAddAttribute;
Handle  g_SDKGenerateAttribute;
Handle  g_SDKGetAttrDefByName;
Address g_pItemSystem = Address_Null;
Address g_pItemSchema = Address_Null;
int     g_OffDynamicAttrs = -1;
int     g_OffAttrRead = -1;
int     g_OffAttrCount = -1;
int     g_OffEconItem = -1;

bool g_PatchesReady = false;

/* ================================================================== */
/*  Plugin lifecycle                                                  */
/* ================================================================== */

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	if (GetEngineVersion() != Engine_CSGO)
	{
		strcopy(error, err_max, "CS:GO Loadout only supports CS:GO.");
		return APLRes_Failure;
	}
	MarkNativeAsOptional("MemoryBlock.MemoryBlock");
	MarkNativeAsOptional("MemoryBlock.Address.get");
	MarkNativeAsOptional("PTaH_ForceFullUpdate");
	return APLRes_Success;
}

public void OnPluginStart()
{
	CreateConVar("csgo_loadout_version", PLUGIN_VERSION, "CS:GO Loadout version", FCVAR_NOTIFY | FCVAR_DONTRECORD);

	RegConsoleCmd("sm_ws", Cmd_Main);
	RegConsoleCmd("sm_loadout", Cmd_Main);
	RegConsoleCmd("sm_skins", Cmd_Main);
	RegConsoleCmd("sm_knife", Cmd_Knife);
	RegConsoleCmd("sm_presets", Cmd_Presets);
	RegConsoleCmd("sm_sets", Cmd_Presets);
	RegConsoleCmd("sm_gloves", Cmd_Gloves);
	RegConsoleCmd("sm_agents", Cmd_Agents);
	RegConsoleCmd("sm_agent", Cmd_Agents);
	RegConsoleCmd("sm_patches", Cmd_Patches);
	RegConsoleCmd("sm_stickers", Cmd_Stickers);
	RegConsoleCmd("sm_3rd", Cmd_ThirdPerson);
	RegAdminCmd("sm_loadout_debug", Cmd_LoadoutDebug, ADMFLAG_GENERIC, "Show what skin data the loadout plugin loaded");
	RegConsoleCmd("sm_thirdperson", Cmd_ThirdPerson);
	RegConsoleCmd("sm_preview", Cmd_ThirdPerson);
	RegConsoleCmd("sm_gen", Cmd_Gen);
	RegConsoleCmd("sm_slots", Cmd_Slots);
	RegConsoleCmd("sm_defaults", Cmd_Slots);

	AddCommandListener(Listener_Say, "say");
	AddCommandListener(Listener_Say, "say_team");

	HookEvent("player_spawn", Event_PlayerSpawn);
	HookEvent("player_death", Event_PlayerDeath);

	char dir[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, dir, sizeof(dir), "data/csgo_loadout");
	if (!DirExists(dir))
		CreateDirectory(dir, 511);

	SetupWeaponTable();
	InitItemData();
	LoadStickerSDK();
	g_PatchesReady = (FindSendPropInfo("CCSPlayer", "m_vecPlayerPatchEconIndices") > 0);
	if (!g_PatchesReady)
		LogMessage("Agent patches are unavailable on this server build (m_vecPlayerPatchEconIndices not found).");

	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i))
		{
			OnClientConnected(i);
			OnClientPutInServer(i);
			if (IsClientAuthorized(i))
				OnClientPostAdminCheck(i);
		}
	}
}

public void OnMapStart()
{
	LoadPresets();
	PrecacheAgents();
}

public void OnClientConnected(int client)
{
	ResetPlayer(client);
}

public void OnClientPutInServer(int client)
{
	SDKHook(client, SDKHook_WeaponEquip, Hook_WeaponEquip);
	// In LAN mode / -insecure, Steam may never confirm the player, so the admin
	// check below never runs. Load the loadout anyway after a few seconds.
	if (!IsFakeClient(client))
		CreateTimer(4.0, Timer_LoadFallback, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_LoadFallback(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (client > 0 && IsClientInGame(client) && !g_Loaded[client])
	{
		BuildFileKey(client);
		LoadPlayer(client);
		ApplyLoadoutNow(client);
	}
	return Plugin_Stop;
}

public void OnClientPostAdminCheck(int client)
{
	if (IsFakeClient(client) || g_Loaded[client])
		return;
	BuildFileKey(client);
	LoadPlayer(client);
	ApplyLoadoutNow(client);
}

// After a map change players often spawn before their loadout has loaded, and
// keep the default knife/gloves/skins until they die. Fix the live player now.
void ApplyLoadoutNow(int client)
{
	if (!IsValidHuman(client) || !IsPlayerAlive(client))
		return;
	int userid = GetClientUserId(client);
	if (g_GloveDef[client] != 0 && g_GlovePaint[client] != 0)
		SetEntPropString(client, Prop_Send, "m_szArmsModel", "");
	CreateTimer(0.1, Timer_ApplyPlayer, userid, TIMER_FLAG_NO_MAPCHANGE);
	CreateTimer(0.2, Timer_ApplyHeld, userid, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_ApplyHeld(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (!IsValidHuman(client) || !IsPlayerAlive(client) || !g_Loaded[client])
		return Plugin_Stop;

	// Collect first: refreshing a weapon changes m_hMyWeapons.
	int defs[64], count = 0;
	bool knifeNeeded = false;
	int size = GetEntPropArraySize(client, Prop_Send, "m_hMyWeapons");
	for (int i = 0; i < size && count < sizeof(defs); i++)
	{
		int wep = GetEntPropEnt(client, Prop_Send, "m_hMyWeapons", i);
		if (wep == -1 || !IsValidEntity(wep))
			continue;
		if (wep < sizeof(g_EntOwner) && g_EntOwner[wep] != 0)
			continue; // already skinned, or picked up from someone else
		int def = GetEntProp(wep, Prop_Send, "m_iItemDefinitionIndex");
		if (IsKnifeDef(def))
		{
			if (g_Knife[client] != 0 || HasSkinFor(client, def))
				knifeNeeded = true;
			continue;
		}
		if (HasSkinFor(client, def) || FindSwapSlot(client, def) != -1)
			defs[count++] = def;
	}

	for (int i = 0; i < count; i++)
		RefreshWeapon(client, defs[i]);
	if (knifeNeeded)
		RefreshWeapon(client, 42);

	// The default arms were already drawn before the loadout loaded, so custom
	// gloves would sit on top of them. A full update makes the game redraw the
	// view model with only the custom gloves.
	if (g_GloveDef[client] != 0 && g_GlovePaint[client] != 0)
		ForceViewRefresh(client, 0.3);
	return Plugin_Stop;
}

void ForceViewRefresh(int client, float delay)
{
	if (GetFeatureStatus(FeatureType_Native, "PTaH_ForceFullUpdate") == FeatureStatus_Available)
		CreateTimer(delay, Timer_FullUpdate, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

bool HasSkinFor(int client, int def)
{
	char key[16];
	WeaponSkin s;
	IntToString(def, key, sizeof(key));
	return g_Skins[client] != null && g_Skins[client].GetArray(key, s, sizeof(s));
}

public void OnClientDisconnect(int client)
{
	delete g_PreviewTimer[client];
	g_ThirdPerson[client] = false;
	ResetPlayer(client);
}

public void OnEntityCreated(int entity, const char[] classname)
{
	if (entity > 0 && entity < sizeof(g_EntOwner))
		g_EntOwner[entity] = 0;
}

void ResetPlayer(int client)
{
	delete g_Skins[client];
	g_Skins[client] = new StringMap();
	g_Knife[client] = 0;
	g_GloveDef[client] = 0;
	g_GlovePaint[client] = 0;
	g_GloveWear[client] = 0.0001;
	g_GloveSeed[client] = 0;
	g_AgentT[client] = 0;
	g_AgentCT[client] = 0;
	for (int i = 0; i < MAX_PATCH_SLOTS; i++)
		g_Patch[client][i] = 0;
	g_FileKey[client][0] = '\0';
	g_Loaded[client] = false;
	for (int i = 0; i < SLOT_COUNT; i++)
		g_SlotAltOn[client][i] = false;
	g_SlotsSet[client] = false;
	g_SlotsPrompted[client] = false;
	g_LastBuyTime[client] = 0.0;
	g_LastBuyAlias[client][0] = '\0';
	g_Input[client] = Input_None;
	g_LastKnifeGive[client] = 0.0;
	g_KnifeTries[client] = 0;
}

/* ================================================================== */
/*  Static weapon table                                               */
/* ================================================================== */

void AddWeapon(int def, const char[] cls, const char[] name, int cat)
{
	WeaponInfo w;
	w.def = def;
	strcopy(w.cls, sizeof(w.cls), cls);
	strcopy(w.name, sizeof(w.name), name);
	w.cat = cat;
	g_Weapons.PushArray(w);
}

void AddGlove(int def, const char[] name, const char[] prefix)
{
	GloveInfo g;
	g.def = def;
	strcopy(g.name, sizeof(g.name), name);
	strcopy(g.prefix, sizeof(g.prefix), prefix);
	g_Gloves.PushArray(g);
}

void SetupWeaponTable()
{
	g_Weapons = new ArrayList(sizeof(WeaponInfo));
	g_Gloves = new ArrayList(sizeof(GloveInfo));

	AddWeapon(4,  "weapon_glock",          "Glock-18",       Cat_Pistol);
	AddWeapon(32, "weapon_hkp2000",        "P2000",          Cat_Pistol);
	AddWeapon(61, "weapon_usp_silencer",   "USP-S",          Cat_Pistol);
	AddWeapon(2,  "weapon_elite",          "Dual Berettas",  Cat_Pistol);
	AddWeapon(36, "weapon_p250",           "P250",           Cat_Pistol);
	AddWeapon(30, "weapon_tec9",           "Tec-9",          Cat_Pistol);
	AddWeapon(3,  "weapon_fiveseven",      "Five-SeveN",     Cat_Pistol);
	AddWeapon(63, "weapon_cz75a",          "CZ75-Auto",      Cat_Pistol);
	AddWeapon(1,  "weapon_deagle",         "Desert Eagle",   Cat_Pistol);
	AddWeapon(64, "weapon_revolver",       "R8 Revolver",    Cat_Pistol);

	AddWeapon(7,  "weapon_ak47",           "AK-47",          Cat_Rifle);
	AddWeapon(16, "weapon_m4a1",           "M4A4",           Cat_Rifle);
	AddWeapon(60, "weapon_m4a1_silencer",  "M4A1-S",         Cat_Rifle);
	AddWeapon(9,  "weapon_awp",            "AWP",            Cat_Rifle);
	AddWeapon(13, "weapon_galilar",        "Galil AR",       Cat_Rifle);
	AddWeapon(10, "weapon_famas",          "FAMAS",          Cat_Rifle);
	AddWeapon(39, "weapon_sg556",          "SG 553",         Cat_Rifle);
	AddWeapon(8,  "weapon_aug",            "AUG",            Cat_Rifle);
	AddWeapon(40, "weapon_ssg08",          "SSG 08",         Cat_Rifle);
	AddWeapon(38, "weapon_scar20",         "SCAR-20",        Cat_Rifle);
	AddWeapon(11, "weapon_g3sg1",          "G3SG1",          Cat_Rifle);

	AddWeapon(34, "weapon_mp9",            "MP9",            Cat_SMG);
	AddWeapon(17, "weapon_mac10",          "MAC-10",         Cat_SMG);
	AddWeapon(33, "weapon_mp7",            "MP7",            Cat_SMG);
	AddWeapon(23, "weapon_mp5sd",          "MP5-SD",         Cat_SMG);
	AddWeapon(24, "weapon_ump45",          "UMP-45",         Cat_SMG);
	AddWeapon(19, "weapon_p90",            "P90",            Cat_SMG);
	AddWeapon(26, "weapon_bizon",          "PP-Bizon",       Cat_SMG);

	AddWeapon(35, "weapon_nova",           "Nova",           Cat_Heavy);
	AddWeapon(25, "weapon_xm1014",         "XM1014",         Cat_Heavy);
	AddWeapon(27, "weapon_mag7",           "MAG-7",          Cat_Heavy);
	AddWeapon(29, "weapon_sawedoff",       "Sawed-Off",      Cat_Heavy);
	AddWeapon(14, "weapon_m249",           "M249",           Cat_Heavy);
	AddWeapon(28, "weapon_negev",          "Negev",          Cat_Heavy);

	AddWeapon(500, "weapon_bayonet",               "Bayonet",         Cat_Knife);
	AddWeapon(503, "weapon_knife_css",             "Classic Knife",   Cat_Knife);
	AddWeapon(505, "weapon_knife_flip",            "Flip Knife",      Cat_Knife);
	AddWeapon(506, "weapon_knife_gut",             "Gut Knife",       Cat_Knife);
	AddWeapon(507, "weapon_knife_karambit",        "Karambit",        Cat_Knife);
	AddWeapon(508, "weapon_knife_m9_bayonet",      "M9 Bayonet",      Cat_Knife);
	AddWeapon(509, "weapon_knife_tactical",        "Huntsman Knife",  Cat_Knife);
	AddWeapon(512, "weapon_knife_falchion",        "Falchion Knife",  Cat_Knife);
	AddWeapon(514, "weapon_knife_survival_bowie",  "Bowie Knife",     Cat_Knife);
	AddWeapon(515, "weapon_knife_butterfly",       "Butterfly Knife", Cat_Knife);
	AddWeapon(516, "weapon_knife_push",            "Shadow Daggers",  Cat_Knife);
	AddWeapon(517, "weapon_knife_cord",            "Paracord Knife",  Cat_Knife);
	AddWeapon(518, "weapon_knife_canis",           "Survival Knife",  Cat_Knife);
	AddWeapon(519, "weapon_knife_ursus",           "Ursus Knife",     Cat_Knife);
	AddWeapon(520, "weapon_knife_gypsy_jackknife", "Navaja Knife",    Cat_Knife);
	AddWeapon(521, "weapon_knife_outdoor",         "Nomad Knife",     Cat_Knife);
	AddWeapon(522, "weapon_knife_stiletto",        "Stiletto Knife",  Cat_Knife);
	AddWeapon(523, "weapon_knife_widowmaker",      "Talon Knife",     Cat_Knife);
	AddWeapon(525, "weapon_knife_skeleton",        "Skeleton Knife",  Cat_Knife);

	// Prefixes are refreshed from items_game.txt if it says otherwise.
	AddGlove(5027, "Bloodhound Gloves",  "studded_bloodhound_gloves");
	AddGlove(5030, "Sport Gloves",       "sporty_gloves");
	AddGlove(5031, "Driver Gloves",      "slick_gloves");
	AddGlove(5032, "Hand Wraps",         "leather_handwraps");
	AddGlove(5033, "Moto Gloves",        "motorcycle_gloves");
	AddGlove(5034, "Specialist Gloves",  "specialist_gloves");
	AddGlove(5035, "Hydra Gloves",       "studded_hydra_gloves");
	AddGlove(4725, "Broken Fang Gloves", "brokenfang_gloves");
}

bool GetWeaponByDef(int def, WeaponInfo w)
{
	for (int i = 0; i < g_Weapons.Length; i++)
	{
		g_Weapons.GetArray(i, w);
		if (w.def == def)
			return true;
	}
	return false;
}

bool GetGloveByDef(int def, GloveInfo g)
{
	for (int i = 0; i < g_Gloves.Length; i++)
	{
		g_Gloves.GetArray(i, g);
		if (g.def == def)
			return true;
	}
	return false;
}

bool IsKnifeDef(int def)
{
	return def == 42 || def == 59 || (def >= 500 && def <= 525);
}

bool IsDefaultKnife(int def)
{
	return def == 42 || def == 59;
}

/* ================================================================== */
/*  Item data loading (items_game.txt + localisation)                 */
/* ================================================================== */

// Startup is split across OnPluginStart and OnAllPluginsLoaded so each part
// stays well inside SourceMod's script time limit.
void InitItemData()
{
	g_Loc = new StringMap();
	g_PaintByName = new StringMap();
	g_PaintDisplay = new StringMap();
	g_KitDisplay = new StringMap();
	g_ItemSkins = new StringMap();
	g_SkinSeen = new StringMap();
	g_Stickers = new ArrayList(sizeof(NamedId));
	g_Patches = new ArrayList(sizeof(NamedId));
	g_Agents = new ArrayList(sizeof(AgentInfo));

	if (!LoadLocalization())
		LogMessage("resource/csgo_english.txt not found — skin and sticker names will show internal names. Copy it from your game's csgo/resource folder to the server's csgo/resource folder to fix this.");
}

public void OnAllPluginsLoaded()
{
	if (!g_ItemsLoaded)
		LoadItems(); // agents are precached in OnMapStart
	HookCompActive();
}

void LoadItems()
{
	KeyValues kv = new KeyValues("items_game");
	if (!kv.ImportFromFile("scripts/items/items_game.txt"))
	{
		LogError("Could not read scripts/items/items_game.txt — skins are unavailable.");
		delete kv;
		return;
	}

	char section[64];

	// Pass 1: paint kits, sticker kits, items.
	if (kv.GotoFirstSubKey())
	{
		do
		{
			kv.GetSectionName(section, sizeof(section));
			if (StrEqual(section, "paint_kits"))
				ParsePaintKits(kv);
			else if (StrEqual(section, "sticker_kits"))
				ParseStickerKits(kv);
			else if (StrEqual(section, "items"))
				ParseItems(kv);
		}
		while (kv.GotoNextKey());
		kv.GoBack();
	}

	// Pass 2: which paint kits belong to which weapon (needs pass 1 data).
	if (kv.GotoFirstSubKey())
	{
		do
		{
			kv.GetSectionName(section, sizeof(section));
			if (StrEqual(section, "alternate_icons2") && kv.JumpToKey("weapon_icons"))
			{
				ParseWeaponIcons(kv);
				kv.GoBack();
			}
		}
		while (kv.GotoNextKey());
		kv.GoBack();
	}
	delete kv;

	SortSkinLists();
	SortADTArrayCustom(g_Stickers, Sort_NamedId);
	SortADTArrayCustom(g_Patches, Sort_NamedId);
	SortADTArrayCustom(g_Agents, Sort_Agent);

	delete g_SkinSeen;
	g_SkinSeen = new StringMap();
	delete g_Loc; // names are resolved now; free the big table
	g_Loc = new StringMap();

	g_ItemsLoaded = true;
	LogMessage("Loaded %d paint kits, %d stickers, %d patches, %d agents.",
		g_PaintByName.Size, g_Stickers.Length, g_Patches.Length, g_Agents.Length);
}

void ParsePaintKits(KeyValues kv)
{
	char section[16], name[NAME_LEN], tag[128], display[NAME_LEN];
	if (!kv.GotoFirstSubKey())
		return;
	do
	{
		kv.GetSectionName(section, sizeof(section));
		int id = StringToInt(section);
		if (id <= 0)
			continue;

		kv.GetString("name", name, sizeof(name));
		if (name[0] == '\0')
			continue;
		kv.GetString("description_tag", tag, sizeof(tag));

		if (!Localize(tag, display, sizeof(display)))
			strcopy(display, sizeof(display), name);

		StringToLowerInPlace(name);
		AddDopplerPhase(name, display, sizeof(display));
		g_PaintByName.SetValue(name, id);
		g_PaintDisplay.SetString(section, display);
	}
	while (kv.GotoNextKey());
	kv.GoBack();
}

// Doppler / Gamma Doppler phases all share one name in the game files, so
// add the phase from the internal name: "Doppler (Ruby)", "Gamma Doppler (Emerald)".
void AddDopplerPhase(const char[] name, char[] display, int maxlen)
{
	if (StrContains(name, "marbleized") == -1 && StrContains(name, "doppler_phase") == -1)
		return;

	char phase[16];
	if (StrContains(name, "ruby") != -1)            strcopy(phase, sizeof(phase), "Ruby");
	else if (StrContains(name, "sapphire") != -1)   strcopy(phase, sizeof(phase), "Sapphire");
	else if (StrContains(name, "blackpearl") != -1) strcopy(phase, sizeof(phase), "Black Pearl");
	else if (StrContains(name, "emerald") != -1)    strcopy(phase, sizeof(phase), "Emerald");
	else
	{
		int p = StrContains(name, "phase");
		if (p == -1 || name[p + 5] < '1' || name[p + 5] > '4')
			return;
		Format(phase, sizeof(phase), "Phase %c", name[p + 5]);
	}
	Format(display, maxlen, "%s (%s)", display, phase);
}

void ParseStickerKits(KeyValues kv)
{
	char section[16], name[NAME_LEN], itemName[128];
	NamedId kit;
	if (!kv.GotoFirstSubKey())
		return;
	do
	{
		kv.GetSectionName(section, sizeof(section));
		int id = StringToInt(section);
		if (id <= 0)
			continue;

		kv.GetString("item_name", itemName, sizeof(itemName));
		bool isSticker = (StrContains(itemName, "#StickerKit_", false) == 0);
		bool isPatch = (StrContains(itemName, "#PatchKit_", false) == 0);
		if (!isSticker && !isPatch)
			continue;

		kv.GetString("name", name, sizeof(name));
		kit.id = id;
		if (!Localize(itemName, kit.name, sizeof(kit.name)))
			strcopy(kit.name, sizeof(kit.name), name);

		g_KitDisplay.SetString(section, kit.name);
		if (isSticker)
			g_Stickers.PushArray(kit);
		else
			g_Patches.PushArray(kit);
	}
	while (kv.GotoNextKey());
	kv.GoBack();
}

void ParseItems(KeyValues kv)
{
	char section[16], name[64], prefab[64], itemName[128];
	AgentInfo agent;
	GloveInfo glove;

	if (!kv.GotoFirstSubKey())
		return;
	do
	{
		kv.GetSectionName(section, sizeof(section));
		int def = StringToInt(section);
		if (def <= 0)
			continue;

		kv.GetString("name", name, sizeof(name));
		kv.GetString("prefab", prefab, sizeof(prefab));

		// Glove internal names (used to match glove skins).
		for (int i = 0; i < g_Gloves.Length; i++)
		{
			g_Gloves.GetArray(i, glove);
			if (glove.def == def && name[0] != '\0')
			{
				strcopy(glove.prefix, sizeof(glove.prefix), name);
				g_Gloves.SetArray(i, glove);
			}
		}

		// Agents.
		if (StrEqual(prefab, "customplayertradable"))
		{
			kv.GetString("model_player", agent.model, sizeof(agent.model));
			if (agent.model[0] == '\0')
				continue;

			agent.team = 0;
			if (kv.JumpToKey("used_by_classes"))
			{
				if (kv.GetNum("terrorists", 0) == 1)
					agent.team = CS_TEAM_T;
				else if (kv.GetNum("counter-terrorists", 0) == 1)
					agent.team = CS_TEAM_CT;
				kv.GoBack();
			}
			if (agent.team == 0)
				continue;

			agent.def = def;
			kv.GetString("item_name", itemName, sizeof(itemName));
			if (!Localize(itemName, agent.name, sizeof(agent.name)))
				strcopy(agent.name, sizeof(agent.name), name);
			g_Agents.PushArray(agent);
		}
	}
	while (kv.GotoNextKey());
	kv.GoBack();
}

void ParseWeaponIcons(KeyValues kv)
{
	char path[PLATFORM_MAX_PATH];
	if (!kv.GotoFirstSubKey())
		return;
	do
	{
		kv.GetString("icon_path", path, sizeof(path));
		AddIconPath(path);
	}
	while (kv.GotoNextKey());
	kv.GoBack();
}

int g_IconPaths = 0;      // weapon_icons entries seen
int g_IconMatched = 0;    // ...that matched a weapon/glove + paint kit

void AddIconPath(char[] path)
{
	g_IconPaths++;
	static const char base[] = "econ/default_generated/";
	if (StrContains(path, base, false) != 0)
		return;

	int len = strlen(path);
	if (len < 7 || !StrEqual(path[len - 6], "_light", false))
		return;
	path[len - 6] = '\0';

	char rest[PLATFORM_MAX_PATH];
	strcopy(rest, sizeof(rest), path[sizeof(base) - 1]);
	StringToLowerInPlace(rest);

	char prefix[48];
	WeaponInfo w;
	GloveInfo g;

	for (int i = 0; i < g_Weapons.Length; i++)
	{
		g_Weapons.GetArray(i, w);
		if (TryMatchIcon(rest, w.cls))
			return;
	}
	for (int i = 0; i < g_Gloves.Length; i++)
	{
		g_Gloves.GetArray(i, g);
		strcopy(prefix, sizeof(prefix), g.prefix);
		if (TryMatchIcon(rest, prefix))
			return;
	}
}

bool TryMatchIcon(const char[] rest, const char[] prefix)
{
	int plen = strlen(prefix);
	if (plen == 0 || strncmp(rest, prefix, plen, false) != 0 || rest[plen] != '_')
		return false;

	int id;
	if (!g_PaintByName.GetValue(rest[plen + 1], id))
		return false;
	g_IconMatched++;

	char seenKey[96];
	Format(seenKey, sizeof(seenKey), "%s|%d", prefix, id);
	int dummy;
	if (g_SkinSeen.GetValue(seenKey, dummy))
		return true;
	g_SkinSeen.SetValue(seenKey, 1);

	ArrayList list;
	if (!g_ItemSkins.GetValue(prefix, list))
	{
		list = new ArrayList();
		g_ItemSkins.SetValue(prefix, list);
	}
	list.Push(id);
	return true;
}

void SortSkinLists()
{
	StringMapSnapshot snap = g_ItemSkins.Snapshot();
	char key[64];
	ArrayList list;
	for (int i = 0; i < snap.Length; i++)
	{
		snap.GetKey(i, key, sizeof(key));
		if (g_ItemSkins.GetValue(key, list))
			SortADTArrayCustom(list, Sort_PaintId);
	}
	delete snap;
}

int Sort_PaintId(int index1, int index2, Handle array, Handle hndl)
{
	ArrayList list = view_as<ArrayList>(array);
	char a[NAME_LEN], b[NAME_LEN];
	GetPaintName(list.Get(index1), a, sizeof(a));
	GetPaintName(list.Get(index2), b, sizeof(b));
	return strcmp(a, b, false);
}

int Sort_NamedId(int index1, int index2, Handle array, Handle hndl)
{
	ArrayList list = view_as<ArrayList>(array);
	NamedId a, b;
	list.GetArray(index1, a);
	list.GetArray(index2, b);
	return strcmp(a.name, b.name, false);
}

int Sort_Agent(int index1, int index2, Handle array, Handle hndl)
{
	ArrayList list = view_as<ArrayList>(array);
	AgentInfo a, b;
	list.GetArray(index1, a);
	list.GetArray(index2, b);
	return strcmp(a.name, b.name, false);
}

void PrecacheAgents()
{
	if (g_Agents == null)
		return;
	AgentInfo a;
	for (int i = 0; i < g_Agents.Length; i++)
	{
		g_Agents.GetArray(i, a);
		PrecacheModel(a.model, true);
	}
}

/* ---------- Localisation (csgo_english.txt is UTF-16LE) ---------- */

void GetNameCachePath(char[] path, int maxlen)
{
	BuildPath(Path_SM, path, maxlen, "data/csgo_loadout/_names_cache.txt");
}

bool LoadLocalization()
{
	// Fast path: names extracted on a previous start.
	char cachePath[PLATFORM_MAX_PATH];
	GetNameCachePath(cachePath, sizeof(cachePath));
	if (FileExists(cachePath))
	{
		KeyValues cache = new KeyValues("names");
		if (cache.ImportFromFile(cachePath) && cache.GotoFirstSubKey(false))
		{
			char key[128], value[NAME_LEN];
			do
			{
				cache.GetSectionName(key, sizeof(key));
				cache.GetString(NULL_STRING, value, sizeof(value));
				g_Loc.SetString(key, value);
			}
			while (cache.GotoNextKey(false));
		}
		delete cache;
		if (g_Loc.Size > 0)
			return true;
	}

	File f = OpenFile("resource/csgo_english.txt", "rb", true);
	if (f == null)
		return false;

	// Read 4 bytes per cell (bulk read) = two UTF-16 characters per cell.
	int buf[8192];
	char line[1024];
	int len = 0;
	int read;
	bool first = true;

	while ((read = f.Read(buf, sizeof(buf), 4)) > 0)
	{
		for (int i = 0; i < read; i++)
		{
			int cell = buf[i];
			for (int half = 0; half < 2; half++)
			{
				int c = (half == 0) ? (cell & 0xFFFF) : ((cell >> 16) & 0xFFFF);
				if (first)
				{
					first = false;
					if (c == 0xFEFF)
						continue;
				}
				if (c == '\n')
				{
					line[len] = '\0';
					ParseLocLine(line);
					len = 0;
				}
				else if (c == '\r' || c == 0)
				{
					// skip
				}
				else if (c < 0x80)
				{
					if (len < sizeof(line) - 1)
						line[len++] = c;
				}
				else if (c < 0x800)
				{
					if (len < sizeof(line) - 2)
					{
						line[len++] = 0xC0 | (c >> 6);
						line[len++] = 0x80 | (c & 0x3F);
					}
				}
				else if (len < sizeof(line) - 3)
				{
					line[len++] = 0xE0 | (c >> 12);
					line[len++] = 0x80 | ((c >> 6) & 0x3F);
					line[len++] = 0x80 | (c & 0x3F);
				}
			}
		}
	}
	delete f;

	if (g_Loc.Size == 0)
		return false;

	// Save just the names we need, so later starts skip this step.
	KeyValues out = new KeyValues("names");
	StringMapSnapshot snap = g_Loc.Snapshot();
	char key[128], value[NAME_LEN];
	for (int i = 0; i < snap.Length; i++)
	{
		snap.GetKey(i, key, sizeof(key));
		if (g_Loc.GetString(key, value, sizeof(value)))
			out.SetString(key, value);
	}
	delete snap;
	out.ExportToFile(cachePath);
	delete out;
	return true;
}

int ReadQuoted(const char[] line, int pos, char[] out, int maxlen)
{
	// Skips to the next quote, copies until the closing quote. Returns position after it, or -1.
	while (line[pos] != '\0' && line[pos] != '"')
		pos++;
	if (line[pos] != '"')
		return -1;
	pos++;

	int o = 0;
	while (line[pos] != '\0' && line[pos] != '"')
	{
		if (line[pos] == '\\' && line[pos + 1] != '\0')
		{
			pos++;
		}
		if (o < maxlen - 1)
			out[o++] = line[pos];
		pos++;
	}
	out[o] = '\0';
	if (line[pos] != '"')
		return -1;
	return pos + 1;
}

void ParseLocLine(const char[] line)
{
	char key[128], value[NAME_LEN];
	int pos = ReadQuoted(line, 0, key, sizeof(key));
	if (pos == -1)
		return;

	StringToLowerInPlace(key);
	if (StrContains(key, "paintkit_") != 0 && StrContains(key, "stickerkit_") != 0
		&& StrContains(key, "patchkit_") != 0 && StrContains(key, "csgo_customplayer_") != 0)
		return;
	if (StrContains(key, "desc") != -1)
		return; // long descriptions aren't needed

	if (ReadQuoted(line, pos, value, sizeof(value)) == -1)
		return;
	g_Loc.SetString(key, value);
}

bool Localize(const char[] token, char[] out, int maxlen)
{
	if (token[0] == '\0')
		return false;
	char key[128];
	strcopy(key, sizeof(key), token[token[0] == '#' ? 1 : 0]);
	StringToLowerInPlace(key);
	if (!g_Loc.GetString(key, out, maxlen))
		return false;
	return out[0] != '\0';
}

/* ---------- Name helpers ---------- */

void GetPaintName(int id, char[] out, int maxlen)
{
	char key[16];
	IntToString(id, key, sizeof(key));
	if (id == 0 || !g_PaintDisplay.GetString(key, out, maxlen))
		strcopy(out, maxlen, id == 0 ? "Default" : "Unknown");
}

void GetKitName(int id, char[] out, int maxlen)
{
	char key[16];
	IntToString(id, key, sizeof(key));
	if (id == 0)
		strcopy(out, maxlen, "None");
	else if (!g_KitDisplay.GetString(key, out, maxlen))
		Format(out, maxlen, "#%d", id);
}

void GetAgentName(int def, char[] out, int maxlen)
{
	strcopy(out, maxlen, "Default");
	if (def == 0)
		return;
	AgentInfo a;
	for (int i = 0; i < g_Agents.Length; i++)
	{
		g_Agents.GetArray(i, a);
		if (a.def == def)
		{
			strcopy(out, maxlen, a.name);
			return;
		}
	}
}

bool GetAgentByDef(int def, AgentInfo a)
{
	for (int i = 0; i < g_Agents.Length; i++)
	{
		g_Agents.GetArray(i, a);
		if (a.def == def)
			return true;
	}
	return false;
}

void WearName(float wear, char[] out, int maxlen)
{
	if (wear < 0.07)
		strcopy(out, maxlen, "Factory New");
	else if (wear < 0.15)
		strcopy(out, maxlen, "Minimal Wear");
	else if (wear < 0.38)
		strcopy(out, maxlen, "Field-Tested");
	else if (wear < 0.45)
		strcopy(out, maxlen, "Well-Worn");
	else
		strcopy(out, maxlen, "Battle-Scarred");
}

ArrayList GetSkinList(const char[] prefix)
{
	ArrayList list;
	if (g_ItemSkins.GetValue(prefix, list))
		return list;
	return null;
}

void StringToLowerInPlace(char[] s)
{
	for (int i = 0; s[i] != '\0'; i++)
		s[i] = CharToLower(s[i]);
}

public Action Cmd_LoadoutDebug(int client, int args)
{
	ReplyToCommand(client, "[Loadout] items loaded: %s | paint kits: %d | stickers: %d | patches: %d | agents: %d",
		g_ItemsLoaded ? "yes" : "NO", g_PaintByName.Size, g_Stickers.Length, g_Patches.Length, g_Agents.Length);
	ReplyToCommand(client, "[Loadout] weapon_icons entries: %d, matched: %d", g_IconPaths, g_IconMatched);

	char line[256];
	GloveInfo g;
	for (int i = 0; i < g_Gloves.Length; i++)
	{
		g_Gloves.GetArray(i, g);
		ArrayList list = GetSkinList(g.prefix);
		ReplyToCommand(client, "[Loadout] %s (%d, %s): %d skins", g.name, g.def, g.prefix, list != null ? list.Length : 0);
	}

	// Weapons: list the counts compactly.
	WeaponInfo w;
	line[0] = '\0';
	for (int i = 0; i < g_Weapons.Length; i++)
	{
		g_Weapons.GetArray(i, w);
		ArrayList list = GetSkinList(w.cls);
		char part[48];
		Format(part, sizeof(part), "%s=%d ", w.cls[7], list != null ? list.Length : 0);
		if (strlen(line) + strlen(part) >= sizeof(line) - 1)
		{
			ReplyToCommand(client, "[Loadout] %s", line);
			line[0] = '\0';
		}
		StrCat(line, sizeof(line), part);
	}
	if (line[0] != '\0')
		ReplyToCommand(client, "[Loadout] %s", line);
	return Plugin_Handled;
}

/* ================================================================== */
/*  Player loadout storage — one file per player                      */
/* ================================================================== */

void InitSkin(WeaponSkin s)
{
	s.paint = 0;
	s.wear = 0.0001;
	s.seed = 0;
	s.stattrak = -1;
	s.nametag[0] = '\0';
	for (int i = 0; i < MAX_STICKER_SLOTS; i++)
	{
		s.sticker[i] = 0;
		s.stickerWear[i] = 0.0;
	}
}

bool IsEmptySkin(WeaponSkin s)
{
	if (s.paint != 0 || s.stattrak >= 0 || s.nametag[0] != '\0')
		return false;
	for (int i = 0; i < MAX_STICKER_SLOTS; i++)
	{
		if (s.sticker[i] != 0)
			return false;
	}
	return true;
}

// Re-gives the weapon, then makes the client redraw it so new stickers show.
// Without PTaH the game only redraws stickers on the next spawn.
void RefreshStickers(int client, int def)
{
	RefreshWeapon(client, def);
	if (!IsValidHuman(client))
		return;
	if (GetFeatureStatus(FeatureType_Native, "PTaH_ForceFullUpdate") == FeatureStatus_Available)
	{
		CreateTimer(0.2, Timer_FullUpdate, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
	}
	else
	{
		static bool warned = false;
		if (!warned)
		{
			warned = true;
			LogMessage("PTaH extension not loaded — sticker changes show after the player respawns. Install PTaH to update them straight away.");
		}
		PrintToChat(client, "%sSticker saved — it shows on your weapon after you respawn.", PREFIX);
	}
}

public Action Timer_FullUpdate(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (IsValidHuman(client))
		PTaH_ForceFullUpdate(client);
	return Plugin_Stop;
}

bool HasStickers(WeaponSkin s)
{
	for (int i = 0; i < MAX_STICKER_SLOTS; i++)
	{
		if (s.sticker[i] != 0)
			return true;
	}
	return false;
}

void GetSkin(int client, int def, WeaponSkin s)
{
	char key[16];
	IntToString(def, key, sizeof(key));
	if (g_Skins[client] == null || !g_Skins[client].GetArray(key, s, sizeof(s)))
		InitSkin(s);
}

void SetSkin(int client, int def, WeaponSkin s)
{
	char key[16];
	IntToString(def, key, sizeof(key));
	if (IsEmptySkin(s))
		g_Skins[client].Remove(key);
	else
		g_Skins[client].SetArray(key, s, sizeof(s));
	SavePlayer(client);
}

void BuildFileKey(int client)
{
	char auth[64];
	if (GetClientAuthId(client, AuthId_Steam2, auth, sizeof(auth), false)
		&& StrContains(auth, "STEAM_ID", false) == -1 && !StrEqual(auth, "BOT"))
	{
		// STEAM_0 and STEAM_1 are the same account.
		if (strncmp(auth, "STEAM_1", 7) == 0)
			auth[6] = '0';
		ReplaceString(auth, sizeof(auth), ":", "_");
		strcopy(g_FileKey[client], sizeof(g_FileKey[]), auth);
	}
	else
	{
		// LAN mode without a verified SteamID: fall back to the player's IP.
		char ip[32];
		GetClientIP(client, ip, sizeof(ip));
		ReplaceString(ip, sizeof(ip), ".", "_");
		Format(g_FileKey[client], sizeof(g_FileKey[]), "ip_%s", ip);
	}
}

void GetPlayerFile(int client, char[] path, int maxlen)
{
	BuildPath(Path_SM, path, maxlen, "data/csgo_loadout/%s.cfg", g_FileKey[client]);
}

void LoadPlayer(int client)
{
	g_Loaded[client] = true;

	char path[PLATFORM_MAX_PATH];
	GetPlayerFile(client, path, sizeof(path));
	if (!FileExists(path) && strncmp(g_FileKey[client], "STEAM_", 6) == 0)
	{
		// Saved earlier under the player's IP (LAN mode before Steam confirmed
		// them): load that file; it's saved under the SteamID from now on.
		char ip[32];
		GetClientIP(client, ip, sizeof(ip));
		ReplaceString(ip, sizeof(ip), ".", "_");
		BuildPath(Path_SM, path, sizeof(path), "data/csgo_loadout/ip_%s.cfg", ip);
	}
	if (!FileExists(path))
		return;

	KeyValues kv = new KeyValues("loadout");
	if (!kv.ImportFromFile(path))
	{
		LogError("Could not read %s", path);
		delete kv;
		return;
	}

	g_Knife[client] = kv.GetNum("knife", 0);
	g_AgentT[client] = kv.GetNum("agent_t", 0);
	g_AgentCT[client] = kv.GetNum("agent_ct", 0);

	if (kv.JumpToKey("gloves"))
	{
		g_GloveDef[client] = kv.GetNum("def", 0);
		g_GlovePaint[client] = kv.GetNum("paint", 0);
		g_GloveWear[client] = kv.GetFloat("wear", 0.0001);
		g_GloveSeed[client] = kv.GetNum("seed", 0);
		kv.GoBack();
	}

	char key[32];
	if (kv.JumpToKey("slots"))
	{
		g_SlotsSet[client] = (kv.GetNum("set", 0) == 1);
		for (int i = 0; i < SLOT_COUNT; i++)
		{
			IntToString(i, key, sizeof(key));
			g_SlotAltOn[client][i] = (kv.GetNum(key, 0) == 1);
		}
		kv.GoBack();
	}

	if (kv.JumpToKey("patches"))
	{
		for (int i = 0; i < MAX_PATCH_SLOTS; i++)
		{
			IntToString(i, key, sizeof(key));
			g_Patch[client][i] = kv.GetNum(key, 0);
		}
		kv.GoBack();
	}

	if (kv.JumpToKey("weapons"))
	{
		if (kv.GotoFirstSubKey())
		{
			char section[16];
			WeaponSkin s;
			do
			{
				kv.GetSectionName(section, sizeof(section));
				InitSkin(s);
				s.paint = kv.GetNum("paint", 0);
				s.wear = kv.GetFloat("wear", 0.0001);
				s.seed = kv.GetNum("seed", 0);
				s.stattrak = kv.GetNum("stattrak", -1);
				kv.GetString("nametag", s.nametag, sizeof(s.nametag));
				for (int i = 0; i < MAX_STICKER_SLOTS; i++)
				{
					Format(key, sizeof(key), "sticker%d", i);
					s.sticker[i] = kv.GetNum(key, 0);
					Format(key, sizeof(key), "sticker%d_wear", i);
					s.stickerWear[i] = kv.GetFloat(key, 0.0);
				}
				if (!IsEmptySkin(s))
					g_Skins[client].SetArray(section, s, sizeof(s));
			}
			while (kv.GotoNextKey());
			kv.GoBack();
		}
		kv.GoBack();
	}
	delete kv;
}

void SavePlayer(int client)
{
	if (!g_Loaded[client] || g_FileKey[client][0] == '\0')
		return;

	KeyValues kv = new KeyValues("loadout");
	char name[MAX_NAME_LENGTH], key[32];
	GetClientName(client, name, sizeof(name));
	kv.SetString("player", name);
	kv.SetString("id", g_FileKey[client]);
	kv.SetNum("knife", g_Knife[client]);
	kv.SetNum("agent_t", g_AgentT[client]);
	kv.SetNum("agent_ct", g_AgentCT[client]);

	kv.JumpToKey("gloves", true);
	kv.SetNum("def", g_GloveDef[client]);
	kv.SetNum("paint", g_GlovePaint[client]);
	kv.SetFloat("wear", g_GloveWear[client]);
	kv.SetNum("seed", g_GloveSeed[client]);
	kv.GoBack();

	kv.JumpToKey("slots", true);
	kv.SetNum("set", g_SlotsSet[client] ? 1 : 0);
	for (int i = 0; i < SLOT_COUNT; i++)
	{
		IntToString(i, key, sizeof(key));
		kv.SetNum(key, g_SlotAltOn[client][i] ? 1 : 0);
	}
	kv.GoBack();

	kv.JumpToKey("patches", true);
	for (int i = 0; i < MAX_PATCH_SLOTS; i++)
	{
		IntToString(i, key, sizeof(key));
		kv.SetNum(key, g_Patch[client][i]);
	}
	kv.GoBack();

	kv.JumpToKey("weapons", true);
	StringMapSnapshot snap = g_Skins[client].Snapshot();
	char section[16];
	WeaponSkin s;
	for (int i = 0; i < snap.Length; i++)
	{
		snap.GetKey(i, section, sizeof(section));
		if (!g_Skins[client].GetArray(section, s, sizeof(s)) || IsEmptySkin(s))
			continue;

		kv.JumpToKey(section, true);
		kv.SetNum("paint", s.paint);
		kv.SetFloat("wear", s.wear);
		kv.SetNum("seed", s.seed);
		kv.SetNum("stattrak", s.stattrak);
		kv.SetString("nametag", s.nametag);
		for (int j = 0; j < MAX_STICKER_SLOTS; j++)
		{
			Format(key, sizeof(key), "sticker%d", j);
			kv.SetNum(key, s.sticker[j]);
			Format(key, sizeof(key), "sticker%d_wear", j);
			kv.SetFloat(key, s.stickerWear[j]);
		}
		kv.GoBack();
	}
	delete snap;
	kv.GoBack();

	kv.Rewind();
	char path[PLATFORM_MAX_PATH];
	GetPlayerFile(client, path, sizeof(path));
	if (!kv.ExportToFile(path))
		LogError("Could not save %s", path);
	delete kv;
}

/* ================================================================== */
/*  Applying skins                                                    */
/* ================================================================== */

bool IsValidHuman(int client)
{
	return client > 0 && client <= MaxClients && IsClientInGame(client) && !IsFakeClient(client);
}

public Action Hook_WeaponEquip(int client, int weapon)
{
	if (!IsValidHuman(client) || !g_Loaded[client] || !IsValidEntity(weapon))
		return Plugin_Continue;

	int def = GetEntProp(weapon, Prop_Send, "m_iItemDefinitionIndex");

	// Loadout slots: swap a new default weapon (e.g. P2000) for the player's pick (USP-S).
	int slot = FindSwapSlot(client, def);
	if (slot != -1 && !IsDuelRunning() && IsFreshWeapon(client, weapon))
	{
		int refund = 0;
		if (GetGameTime() - g_LastBuyTime[client] < 0.5)
			refund = GetSlotPriceDifference(client, slot);
		g_LastBuyTime[client] = 0.0;

		DataPack pack = new DataPack();
		pack.WriteCell(GetClientUserId(client));
		pack.WriteCell(EntIndexToEntRef(weapon));
		pack.WriteCell(g_SlotAlt[slot]);
		pack.WriteCell(refund);
		RequestFrame(Frame_SwapWeapon, pack);
		g_EntOwner[weapon] = -1; // mark so it isn't skinned before the swap
		return Plugin_Continue;
	}

	// Swap the default knife for the chosen one on the next frame.
	if (IsDefaultKnife(def) && g_Knife[client] != 0)
	{
		RequestFrame(Frame_ReplaceKnife, GetClientUserId(client));
		return Plugin_Continue;
	}

	ApplyWeaponSkin(client, weapon, def);
	return Plugin_Continue;
}

void ApplyWeaponSkin(int client, int weapon, int def)
{
	if (weapon <= 0 || weapon >= sizeof(g_EntOwner))
		return;

	int userid = GetClientUserId(client);
	if (g_EntOwner[weapon] != 0)
		return; // already skinned (by this player or someone else who dropped it)

	WeaponSkin s;
	GetSkin(client, def, s);
	if (IsEmptySkin(s))
		return;

	static int IDHigh = 16384;
	SetEntProp(weapon, Prop_Send, "m_iItemIDLow", -1);
	SetEntProp(weapon, Prop_Send, "m_iItemIDHigh", IDHigh++);

	if (s.paint != 0)
	{
		float wear = s.wear;
		if (wear < 0.000001)
			wear = 0.000001;
		else if (wear > 0.999999)
			wear = 0.999999;
		SetEntProp(weapon, Prop_Send, "m_nFallbackPaintKit", s.paint);
		SetEntPropFloat(weapon, Prop_Send, "m_flFallbackWear", wear);
		SetEntProp(weapon, Prop_Send, "m_nFallbackSeed", s.seed);
	}

	bool knife = IsKnifeDef(def);
	SetEntProp(weapon, Prop_Send, "m_nFallbackStatTrak", s.stattrak >= 0 ? s.stattrak : -1);
	if (knife)
		SetEntProp(weapon, Prop_Send, "m_iEntityQuality", 3);
	else
		SetEntProp(weapon, Prop_Send, "m_iEntityQuality", s.stattrak >= 0 ? 9 : 0);

	if (s.nametag[0] != '\0')
		SetEntDataString(weapon, FindSendPropInfo("CBaseAttributableItem", "m_szCustomName"), s.nametag, 128);

	SetEntProp(weapon, Prop_Send, "m_iAccountID", GetSteamAccountID(client, false));
	SetEntPropEnt(weapon, Prop_Send, "m_hOwnerEntity", client);
	SetEntPropEnt(weapon, Prop_Send, "m_hPrevOwner", -1);

	if (!knife && HasStickers(s))
		ApplyStickers(weapon, s);

	g_EntOwner[weapon] = userid;
}

/* ---------- Loadout slots (USP-S, M4A1-S, CZ75, R8, MP5-SD) ---------- */

// The match plugin sets this during a 1v1 duel, where both players must get
// exactly the weapon that was agreed on.
bool IsDuelRunning()
{
	static ConVar cv = null;
	if (cv == null)
		cv = FindConVar("match_duel_active");
	return cv != null && cv.BoolValue;
}

int FindSwapSlot(int client, int def)
{
	int team = GetClientTeam(client);
	for (int i = 0; i < SLOT_COUNT; i++)
	{
		if (g_SlotDefault[i] != def || !g_SlotAltOn[client][i])
			continue;
		if (g_SlotTeam[i] != 0 && g_SlotTeam[i] != team)
			continue;
		return i;
	}
	return -1;
}

// A weapon that was just bought or handed out, not one picked up from someone else.
bool IsFreshWeapon(int client, int weapon)
{
	if (weapon <= 0 || weapon >= sizeof(g_EntOwner) || g_EntOwner[weapon] != 0)
		return false;
	int prev = GetEntPropEnt(weapon, Prop_Send, "m_hPrevOwner");
	return prev == -1 || prev == client;
}

public Action CS_OnBuyCommand(int client, const char[] weapon)
{
	if (client > 0 && client <= MaxClients)
	{
		g_LastBuyTime[client] = GetGameTime();
		strcopy(g_LastBuyAlias[client], sizeof(g_LastBuyAlias[]), weapon);
	}
	return Plugin_Continue;
}

int GetDefPrice(int client, int def)
{
	WeaponInfo w;
	if (!GetWeaponByDef(def, w))
		return 0;
	CSWeaponID id = CS_AliasToWeaponID(w.cls[7]); // strip "weapon_"
	if (id == CSWeapon_NONE)
		return 0;
	return CS_GetWeaponPrice(client, id);
}

// Money to give back (or take, if negative) when a bought default is swapped.
int GetSlotPriceDifference(int client, int slot)
{
	return GetDefPrice(client, g_SlotDefault[slot]) - GetDefPrice(client, g_SlotAlt[slot]);
}

public void Frame_SwapWeapon(DataPack pack)
{
	pack.Reset();
	int client = GetClientOfUserId(pack.ReadCell());
	int weapon = EntRefToEntIndex(pack.ReadCell());
	int altDef = pack.ReadCell();
	int refund = pack.ReadCell();
	delete pack;

	if (!IsValidHuman(client) || !IsPlayerAlive(client) || weapon == INVALID_ENT_REFERENCE)
		return;
	if (GetEntPropEnt(weapon, Prop_Send, "m_hOwnerEntity") != client)
		return;

	SwapToAlt(client, weapon, altDef);

	if (refund != 0)
	{
		int money = GetEntProp(client, Prop_Send, "m_iAccount") + refund;
		SetEntProp(client, Prop_Send, "m_iAccount", money < 0 ? 0 : money);
	}
}

void SwapToAlt(int client, int weapon, int altDef)
{
	WeaponInfo w;
	if (!GetWeaponByDef(altDef, w))
		return;

	bool wasActive = (GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon") == weapon);
	RemovePlayerItem(client, weapon);
	AcceptEntityInput(weapon, "KillHierarchy");

	int newWep = GivePlayerItem(client, w.cls);
	if (newWep != -1 && wasActive)
		FakeClientCommandEx(client, "use %s", w.cls);
}

// After changing choices, swap anything the player is holding right now.
void SwapHeldWeapons(int client)
{
	if (!IsValidHuman(client) || !IsPlayerAlive(client))
		return;

	int size = GetEntPropArraySize(client, Prop_Send, "m_hMyWeapons");
	for (int i = 0; i < size; i++)
	{
		int wep = GetEntPropEnt(client, Prop_Send, "m_hMyWeapons", i);
		if (wep == -1 || !IsValidEntity(wep))
			continue;
		int def = GetEntProp(wep, Prop_Send, "m_iItemDefinitionIndex");
		int team = GetClientTeam(client);

		for (int s = 0; s < SLOT_COUNT; s++)
		{
			if (g_SlotTeam[s] != 0 && g_SlotTeam[s] != team)
				continue;

			int want = g_SlotAltOn[client][s] ? g_SlotAlt[s] : g_SlotDefault[s];
			int other = g_SlotAltOn[client][s] ? g_SlotDefault[s] : g_SlotAlt[s];
			if (def == other && (g_EntOwner[wep] == 0 || g_EntOwner[wep] == GetClientUserId(client)))
			{
				SwapToAlt(client, wep, want);
				break;
			}
		}
	}
}

public void Frame_ReplaceKnife(int userid)
{
	int client = GetClientOfUserId(userid);
	if (!IsValidHuman(client) || !IsPlayerAlive(client) || g_Knife[client] == 0)
		return;
	GiveChosenKnife(client);
}

void GiveChosenKnife(int client)
{
	WeaponInfo w;
	if (!GetWeaponByDef(g_Knife[client], w))
		return;

	RemoveKnives(client, g_Knife[client]);
	if (FindKnife(client) != -1)
		return; // chosen knife already in hand

	// Guard against loops if the game keeps refusing the knife (core.cfg
	// guidelines on): at most 4 tries in 5 seconds. Engine time, because game
	// time restarts on every map.
	float now = GetEngineTime();
	if (now - g_LastKnifeGive[client] > 5.0)
	{
		g_LastKnifeGive[client] = now;
		g_KnifeTries[client] = 0;
	}
	if (++g_KnifeTries[client] > 4)
	{
		if (!g_KnifeWarned)
		{
			g_KnifeWarned = true;
			LogError("Knife swap failed. Set \"FollowCSGOServerGuidelines\" \"no\" in addons/sourcemod/configs/core.cfg and restart the server.");
		}
		return;
	}

	int knife = GivePlayerItem(client, w.cls);
	if (knife != -1 && GetEntPropEnt(knife, Prop_Send, "m_hOwnerEntity") != client)
		EquipPlayerWeapon(client, knife);

	// A round restart right after a map change can strip the new knife again;
	// check it stuck.
	CreateTimer(0.6, Timer_CheckKnife, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_CheckKnife(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (!IsValidHuman(client) || !IsPlayerAlive(client) || !g_Loaded[client] || g_Knife[client] == 0)
		return Plugin_Stop;
	if (IsDuelRunning())
		return Plugin_Stop;
	int knife = FindKnife(client);
	if (knife == -1 || GetEntProp(knife, Prop_Send, "m_iItemDefinitionIndex") != g_Knife[client])
		GiveChosenKnife(client);
	return Plugin_Stop;
}

int FindKnife(int client)
{
	int size = GetEntPropArraySize(client, Prop_Send, "m_hMyWeapons");
	for (int i = 0; i < size; i++)
	{
		int wep = GetEntPropEnt(client, Prop_Send, "m_hMyWeapons", i);
		if (wep != -1 && IsValidEntity(wep) && IsKnifeDef(GetEntProp(wep, Prop_Send, "m_iItemDefinitionIndex")))
			return wep;
	}
	return -1;
}

void RemoveKnives(int client, int keepDef)
{
	int size = GetEntPropArraySize(client, Prop_Send, "m_hMyWeapons");
	for (int i = 0; i < size; i++)
	{
		int wep = GetEntPropEnt(client, Prop_Send, "m_hMyWeapons", i);
		if (wep == -1 || !IsValidEntity(wep))
			continue;
		int def = GetEntProp(wep, Prop_Send, "m_iItemDefinitionIndex");
		if (IsKnifeDef(def) && def != keepDef)
		{
			RemovePlayerItem(client, wep);
			AcceptEntityInput(wep, "KillHierarchy");
		}
	}
}

// Re-gives a weapon so the new look shows immediately.
void RefreshWeapon(int client, int def)
{
	if (!IsValidHuman(client) || !IsPlayerAlive(client))
		return;

	bool isKnife = IsKnifeDef(def);
	int size = GetEntPropArraySize(client, Prop_Send, "m_hMyWeapons");
	int active = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");

	for (int i = 0; i < size; i++)
	{
		int wep = GetEntPropEnt(client, Prop_Send, "m_hMyWeapons", i);
		if (wep == -1 || !IsValidEntity(wep))
			continue;

		int wdef = GetEntProp(wep, Prop_Send, "m_iItemDefinitionIndex");
		if (isKnife ? !IsKnifeDef(wdef) : (wdef != def))
			continue;

		// Only refresh our own weapon, not one picked up from a teammate.
		if (g_EntOwner[wep] != 0 && g_EntOwner[wep] != GetClientUserId(client))
			return;

		bool wasActive = (wep == active);

		if (isKnife)
		{
			RemovePlayerItem(client, wep);
			AcceptEntityInput(wep, "KillHierarchy");
			g_LastKnifeGive[client] = 0.0;
			g_KnifeTries[client] = 0;
			if (g_Knife[client] != 0)
				GiveChosenKnife(client);
			else
				GivePlayerItem(client, "weapon_knife");
			if (wasActive)
				FakeClientCommandEx(client, "use weapon_knife");
			return;
		}

		WeaponInfo w;
		if (!GetWeaponByDef(def, w))
			return;

		int ammoOffset = FindDataMapInfo(client, "m_iAmmo") + (GetEntProp(wep, Prop_Data, "m_iPrimaryAmmoType") * 4);
		int ammo = GetEntData(client, ammoOffset);
		int clip = GetEntProp(wep, Prop_Send, "m_iClip1");
		int reserve = GetEntProp(wep, Prop_Send, "m_iPrimaryReserveAmmoCount");

		RemovePlayerItem(client, wep);
		AcceptEntityInput(wep, "KillHierarchy");

		int newWep = GivePlayerItem(client, w.cls);
		if (newWep != -1)
		{
			SetEntProp(newWep, Prop_Send, "m_iClip1", clip);
			SetEntProp(newWep, Prop_Send, "m_iPrimaryReserveAmmoCount", reserve);
			DataPack pack;
			CreateDataTimer(0.1, Timer_RestoreAmmo, pack, TIMER_FLAG_NO_MAPCHANGE);
			pack.WriteCell(GetClientUserId(client));
			pack.WriteCell(ammoOffset);
			pack.WriteCell(ammo);
			if (wasActive)
				FakeClientCommandEx(client, "use %s", w.cls);
		}
		return;
	}
}

public Action Timer_RestoreAmmo(Handle timer, DataPack pack)
{
	pack.Reset();
	int client = GetClientOfUserId(pack.ReadCell());
	int offset = pack.ReadCell();
	int ammo = pack.ReadCell();
	if (client > 0 && IsClientInGame(client))
		SetEntData(client, offset, ammo, 4, true);
	return Plugin_Stop;
}

/* ---------- Gloves / agents / patches ---------- */

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	int userid = event.GetInt("userid");
	int client = GetClientOfUserId(userid);
	if (!IsValidHuman(client))
		return;

	if (g_ThirdPerson[client])
		SetThirdPerson(client, false);

	// Drop the default arms straight away so they never draw under custom gloves.
	if (g_Loaded[client] && g_GloveDef[client] != 0 && g_GlovePaint[client] != 0)
		SetEntPropString(client, Prop_Send, "m_szArmsModel", "");

	CreateTimer(0.1, Timer_ApplyPlayer, userid, TIMER_FLAG_NO_MAPCHANGE);
	CreateTimer(1.0, Timer_CheckKnife, userid, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_ApplyPlayer(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (!IsValidHuman(client) || !IsPlayerAlive(client) || !g_Loaded[client])
		return Plugin_Stop;

	ApplyAgent(client);
	ApplyPatches(client);
	ApplyGloves(client, true); // true = redraw the first-person view

	// First time on the server: ask which default weapons they want.
	if (!g_SlotsSet[client] && !g_SlotsPrompted[client] && g_ItemsLoaded)
	{
		g_SlotsPrompted[client] = true;
		PrintToChat(client, "%sPick your default weapons (USP-S or P2000, M4A1-S or M4A4...). Change them later with \x04!slots\x01.", PREFIX);
		ShowSlotsMenu(client);
	}
	return Plugin_Stop;
}

/* ---------- Third person (preview your agent, patches and gloves) ---------- */

ConVar g_cvCompActive = null;

// Never during a match, knife round, duel or arena round. Without the match
// plugin: never in a live competitive/wingman game (warmup is fine).
bool ThirdPersonAllowed()
{
	if (g_cvCompActive == null)
		g_cvCompActive = FindConVar("match_competitive_active");
	if (g_cvCompActive != null)
		return !g_cvCompActive.BoolValue;

	if (GameRules_GetProp("m_bWarmupPeriod"))
		return true;
	ConVar type = FindConVar("game_type");
	ConVar mode = FindConVar("game_mode");
	if (type != null && mode != null && type.IntValue == 0 && (mode.IntValue == 1 || mode.IntValue == 2))
		return false;
	return true;
}

void HookCompActive()
{
	g_cvCompActive = FindConVar("match_competitive_active");
	if (g_cvCompActive != null)
		g_cvCompActive.AddChangeHook(OnCompActiveChanged);
}

// Match just went live: put everyone back in first person.
public void OnCompActiveChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	if (StringToInt(newValue) == 0)
		return;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && g_ThirdPerson[i])
		{
			delete g_PreviewTimer[i];
			if (IsPlayerAlive(i))
				SetThirdPerson(i, false);
			else
				g_ThirdPerson[i] = false;
		}
	}
}

void SetThirdPerson(int client, bool on)
{
	g_ThirdPerson[client] = on;
	if (on)
	{
		SetEntPropEnt(client, Prop_Send, "m_hObserverTarget", 0);
		SetEntProp(client, Prop_Send, "m_iObserverMode", 1);
		SetEntProp(client, Prop_Send, "m_bDrawViewmodel", 0);
		SetEntProp(client, Prop_Send, "m_iFOV", 100);
	}
	else
	{
		SetEntPropEnt(client, Prop_Send, "m_hObserverTarget", -1);
		SetEntProp(client, Prop_Send, "m_iObserverMode", 0);
		SetEntProp(client, Prop_Send, "m_bDrawViewmodel", 1);
		SetEntProp(client, Prop_Send, "m_iFOV", GetEntProp(client, Prop_Send, "m_iDefaultFOV"));
	}
}

// Short third-person look after changing agent / patches / gloves.
void ShowPreview(int client, float seconds)
{
	if (!IsValidHuman(client) || !IsPlayerAlive(client) || !ThirdPersonAllowed())
		return;
	delete g_PreviewTimer[client];
	if (!g_ThirdPerson[client])
	{
		SetThirdPerson(client, true);
		g_PreviewTimer[client] = CreateTimer(seconds, Timer_EndPreview, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
		PrintHintText(client, "Preview — back to first person in %.0f s\n!3rd to stay in third person", seconds);
	}
}

public Action Timer_EndPreview(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (client > 0)
	{
		g_PreviewTimer[client] = null;
		if (IsClientInGame(client) && IsPlayerAlive(client) && g_ThirdPerson[client])
			SetThirdPerson(client, false);
	}
	return Plugin_Stop;
}

public Action Cmd_ThirdPerson(int client, int args)
{
	if (!IsValidHuman(client))
		return Plugin_Handled;
	if (!IsPlayerAlive(client))
	{
		PrintToChat(client, "%sYou need to be alive.", PREFIX);
		return Plugin_Handled;
	}
	if (!g_ThirdPerson[client] && !ThirdPersonAllowed())
	{
		PrintToChat(client, "%sThird person is off during matches, duels and arena rounds. Use it in warmup.", PREFIX);
		return Plugin_Handled;
	}
	delete g_PreviewTimer[client];
	SetThirdPerson(client, !g_ThirdPerson[client]);
	PrintToChat(client, "%s%s person view. Type \x04!3rd\x01 to switch back.", PREFIX, g_ThirdPerson[client] ? "Third" : "First");
	return Plugin_Handled;
}

void ApplyAgent(int client)
{
	int team = GetClientTeam(client);
	int def = (team == CS_TEAM_T) ? g_AgentT[client] : (team == CS_TEAM_CT ? g_AgentCT[client] : 0);
	if (def == 0)
		return;

	AgentInfo a;
	if (!GetAgentByDef(def, a) || a.team != team)
		return;
	if (!IsModelPrecached(a.model))
		return;
	SetEntityModel(client, a.model);
}

void ApplyPatches(int client)
{
	if (!g_PatchesReady)
		return;
	int size = GetEntPropArraySize(client, Prop_Send, "m_vecPlayerPatchEconIndices");
	for (int i = 0; i < size; i++)
		SetEntProp(client, Prop_Send, "m_vecPlayerPatchEconIndices", i < MAX_PATCH_SLOTS ? g_Patch[client][i] : 0, _, i);
}

void ApplyGloves(int client, bool refreshView)
{
	if (g_GloveDef[client] == 0 || g_GlovePaint[client] == 0)
		return;

	int active = -1;
	if (refreshView)
	{
		active = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
		if (active != -1)
			SetEntPropEnt(client, Prop_Send, "m_hActiveWeapon", -1);
	}

	int old = GetEntPropEnt(client, Prop_Send, "m_hMyWearables");
	if (old != -1 && IsValidEntity(old))
		AcceptEntityInput(old, "KillHierarchy");

	char arms[2];
	GetEntPropString(client, Prop_Send, "m_szArmsModel", arms, sizeof(arms));
	if (arms[0] != '\0')
		SetEntPropString(client, Prop_Send, "m_szArmsModel", "");

	int ent = CreateEntityByName("wearable_item");
	if (ent != -1)
	{
		float wear = g_GloveWear[client];
		if (wear < 0.000001)
			wear = 0.000001;
		else if (wear > 0.999999)
			wear = 0.999999;

		SetEntProp(ent, Prop_Send, "m_iItemIDLow", -1);
		SetEntProp(ent, Prop_Send, "m_iItemDefinitionIndex", g_GloveDef[client]);
		SetEntProp(ent, Prop_Send, "m_nFallbackPaintKit", g_GlovePaint[client]);
		SetEntPropFloat(ent, Prop_Send, "m_flFallbackWear", wear);
		SetEntProp(ent, Prop_Send, "m_nFallbackSeed", g_GloveSeed[client]);
		SetEntPropEnt(ent, Prop_Data, "m_hOwnerEntity", client);
		SetEntPropEnt(ent, Prop_Data, "m_hParent", client);
		SetEntPropEnt(ent, Prop_Data, "m_hMoveParent", client);
		SetEntProp(ent, Prop_Send, "m_bInitialized", 1);
		DispatchSpawn(ent);
		SetEntPropEnt(client, Prop_Send, "m_hMyWearables", ent);
		SetEntProp(client, Prop_Send, "m_nBody", 1);
	}

	if (active != -1)
	{
		DataPack pack;
		CreateDataTimer(0.1, Timer_RestoreActive, pack, TIMER_FLAG_NO_MAPCHANGE);
		pack.WriteCell(GetClientUserId(client));
		pack.WriteCell(EntIndexToEntRef(active));
	}
}

public Action Timer_RestoreActive(Handle timer, DataPack pack)
{
	pack.Reset();
	int client = GetClientOfUserId(pack.ReadCell());
	int weapon = EntRefToEntIndex(pack.ReadCell());
	if (client > 0 && IsClientInGame(client) && IsPlayerAlive(client) && weapon != INVALID_ENT_REFERENCE)
		SetEntPropEnt(client, Prop_Send, "m_hActiveWeapon", weapon);
	return Plugin_Stop;
}

/* ---------- StatTrak ---------- */

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	int attacker = GetClientOfUserId(event.GetInt("attacker"));
	int victim = GetClientOfUserId(event.GetInt("userid"));
	if (!IsValidHuman(attacker) || attacker == victim || !IsPlayerAlive(attacker))
		return;

	int wep = GetEntPropEnt(attacker, Prop_Send, "m_hActiveWeapon");
	if (wep <= 0 || wep >= sizeof(g_EntOwner) || g_EntOwner[wep] != GetClientUserId(attacker))
		return;

	char evWeapon[64], cls[64];
	event.GetString("weapon", evWeapon, sizeof(evWeapon));
	GetEdictClassname(wep, cls, sizeof(cls));
	int def = GetEntProp(wep, Prop_Send, "m_iItemDefinitionIndex");
	bool knife = IsKnifeDef(def);

	// Make sure the kill was actually with the weapon in hand (not a grenade).
	if (knife)
	{
		if (StrContains(evWeapon, "knife") == -1 && StrContains(evWeapon, "bayonet") == -1)
			return;
	}
	else if (evWeapon[0] == '\0' || StrContains(cls, evWeapon) == -1)
	{
		return;
	}

	WeaponSkin s;
	GetSkin(attacker, def, s);
	if (s.stattrak < 0)
		return;

	s.stattrak++;
	SetEntProp(wep, Prop_Send, "m_nFallbackStatTrak", s.stattrak);
	SetSkin(attacker, def, s);
}

/* ================================================================== */
/*  Stickers (memory-level, adapted from quasemago's Weapon Stickers) */
/* ================================================================== */

void LoadStickerSDK()
{
	char gdPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, gdPath, sizeof(gdPath), "gamedata/csgo_loadout.games.txt");
	if (!FileExists(gdPath))
	{
		LogMessage("gamedata/csgo_loadout.games.txt missing — stickers disabled.");
		return;
	}

	GameData conf = new GameData("csgo_loadout.games");
	if (conf == null)
	{
		LogMessage("gamedata/csgo_loadout.games.txt missing — stickers disabled.");
		return;
	}

	g_IsWindows = (conf.GetOffset("ServerPlatform") == 1);

	if (g_IsWindows && GetFeatureStatus(FeatureType_Native, "MemoryBlock.MemoryBlock") != FeatureStatus_Available)
	{
		LogMessage("Source Scramble extension not loaded — stickers disabled on Windows. Install it to enable stickers.");
		delete conf;
		return;
	}

	StartPrepSDKCall(SDKCall_Static);
	if (!PrepSDKCall_SetFromConf(conf, SDKConf_Signature, "ItemSystem"))
	{
		LogError("Sticker gamedata: ItemSystem signature not found — stickers disabled.");
		delete conf;
		return;
	}
	PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
	Handle itemSystemCall = EndPrepSDKCall();
	if (itemSystemCall == null)
	{
		LogError("Sticker gamedata: ItemSystem call failed — stickers disabled.");
		delete conf;
		return;
	}
	g_pItemSystem = SDKCall(itemSystemCall);
	delete itemSystemCall;
	if (g_pItemSystem == Address_Null)
	{
		LogError("Sticker gamedata: ItemSystem returned null — stickers disabled.");
		delete conf;
		return;
	}
	g_pItemSchema = g_pItemSystem + view_as<Address>(4);

	StartPrepSDKCall(SDKCall_Raw);
	if (!PrepSDKCall_SetFromConf(conf, SDKConf_Signature, "CAttributeList::AddAttribute"))
	{
		LogError("Sticker gamedata: CAttributeList::AddAttribute not found — stickers disabled.");
		delete conf;
		return;
	}
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
	if (g_IsWindows)
	{
		PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
		PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
	}
	g_SDKAddAttribute = EndPrepSDKCall();

	if (!g_IsWindows)
	{
		StartPrepSDKCall(SDKCall_Raw);
		if (PrepSDKCall_SetFromConf(conf, SDKConf_Signature, "CEconItemSystem::GenerateAttribute"))
		{
			PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
			PrepSDKCall_AddParameter(SDKType_Float, SDKPass_Plain);
			PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
			g_SDKGenerateAttribute = EndPrepSDKCall();
		}
	}

	StartPrepSDKCall(SDKCall_Raw);
	if (PrepSDKCall_SetFromConf(conf, SDKConf_Signature, "CEconItemSchema::GetAttributeDefinitionByName"))
	{
		PrepSDKCall_AddParameter(SDKType_String, SDKPass_Pointer);
		PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
		g_SDKGetAttrDefByName = EndPrepSDKCall();
	}

	g_OffDynamicAttrs = conf.GetOffset("m_NetworkedDynamicAttributesForDemos");
	g_OffAttrRead = conf.GetOffset("CAttributeList_Read");
	g_OffAttrCount = conf.GetOffset("CAttributeList_Count");
	delete conf;

	g_OffEconItem = FindSendPropInfo("CBaseCombatWeapon", "m_Item");

	if (g_SDKAddAttribute == null || g_SDKGetAttrDefByName == null
		|| (!g_IsWindows && g_SDKGenerateAttribute == null)
		|| g_OffDynamicAttrs == -1 || g_OffAttrRead == -1 || g_OffAttrCount == -1 || g_OffEconItem < 1)
	{
		LogError("Sticker gamedata is incomplete or out of date — stickers disabled.");
		return;
	}

	g_StickersReady = true;
}

void ApplyStickers(int weapon, WeaponSkin s)
{
	if (!g_StickersReady)
		return;

	Address pWeapon = GetEntityAddress(weapon);
	if (pWeapon == Address_Null)
		return;
	Address pItem = pWeapon + view_as<Address>(g_OffEconItem);

	for (int i = 0; i < MAX_STICKER_SLOTS; i++)
	{
		if (s.sticker[i] == 0)
			continue;
		SetItemAttribute(pItem, s.sticker[i], "sticker slot %d id", i);
		SetItemAttribute(pItem, view_as<int>(s.stickerWear[i]), "sticker slot %d wear", i);
	}
}

bool SetItemAttribute(Address pItem, int value, const char[] format, any ...)
{
	char attr[64];
	VFormat(attr, sizeof(attr), format, 4);

	Address pAttrDef = SDKCall(g_SDKGetAttrDefByName, g_pItemSchema, attr);
	if (pAttrDef == Address_Null)
		return false;

	Address pList = pItem + view_as<Address>(g_OffDynamicAttrs);
	int attrDef = LoadFromAddress(pAttrDef + view_as<Address>(0x8), NumberType_Int16);
	int count = LoadFromAddress(pList + view_as<Address>(g_OffAttrCount), NumberType_Int32);
	Address pData = view_as<Address>(LoadFromAddress(pList + view_as<Address>(g_OffAttrRead), NumberType_Int32));

	// Update existing attribute if present.
	for (int i = 0; i < count; i++)
	{
		Address pAttr = pData + view_as<Address>(i * 24);
		if (LoadFromAddress(pAttr + view_as<Address>(0x4), NumberType_Int16) == attrDef)
		{
			StoreToAddress(pAttr + view_as<Address>(0x8), value, NumberType_Int32);
			return true;
		}
	}

	if (g_IsWindows)
	{
		MemoryBlock block = new MemoryBlock(24);
		Address pAttr = block.Address;
		if (!IsValidAddress(pAttr))
		{
			delete block;
			return false;
		}
		StoreToAddress(pAttr + view_as<Address>(0x4), attrDef, NumberType_Int16);
		StoreToAddress(pAttr + view_as<Address>(0x8), value, NumberType_Int32);
		StoreToAddress(pAttr + view_as<Address>(0xC), value, NumberType_Int32);
		StoreToAddress(pAttr + view_as<Address>(0x10), 0, NumberType_Int32);
		StoreToAddress(pAttr + view_as<Address>(0x14), 0, NumberType_Int8);
		SDKCall(g_SDKAddAttribute, pList, view_as<Address>(LoadFromAddress(pItem + view_as<Address>(0xAC), NumberType_Int32)), pAttr);
		delete block;
		return true;
	}

	Address pNew = SDKCall(g_SDKGenerateAttribute, g_pItemSystem, attrDef, view_as<float>(value));
	if (!IsValidAddress(pNew))
		return false;
	SDKCall(g_SDKAddAttribute, pList, pNew);
	return true;
}

bool IsValidAddress(Address addr)
{
	if (addr == Address_Null)
		return false;
	// Unsigned compare against 0x10000.
	int a = view_as<int>(addr);
	if (a < 0)
		return true;
	return a >= 0x10000;
}

/* ================================================================== */
/*  Commands                                                          */
/* ================================================================== */

bool CheckReady(int client)
{
	if (!IsValidHuman(client))
	{
		if (client == 0)
			ReplyToCommand(client, "[Loadout] This command is for players in-game.");
		return false;
	}
	if (!g_ItemsLoaded)
	{
		PrintToChat(client, "%sItem data failed to load — check the server error log.", PREFIX);
		return false;
	}
	if (!g_Loaded[client])
	{
		PrintToChat(client, "%sYour loadout is still loading, try again in a moment.", PREFIX);
		return false;
	}
	return true;
}

public Action Cmd_Main(int client, int args)
{
	if (CheckReady(client))
		ShowMainMenu(client);
	return Plugin_Handled;
}

public Action Cmd_Knife(int client, int args)
{
	if (CheckReady(client))
		ShowKnifeMenu(client);
	return Plugin_Handled;
}

public Action Cmd_Gloves(int client, int args)
{
	if (CheckReady(client))
		ShowGloveMenu(client);
	return Plugin_Handled;
}

public Action Cmd_Agents(int client, int args)
{
	if (CheckReady(client))
		ShowAgentTeamMenu(client);
	return Plugin_Handled;
}

public Action Cmd_Patches(int client, int args)
{
	if (CheckReady(client))
		ShowPatchMenu(client);
	return Plugin_Handled;
}

public Action Cmd_Stickers(int client, int args)
{
	if (!CheckReady(client))
		return Plugin_Handled;

	int wep = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	if (IsPlayerAlive(client) && wep != -1)
	{
		int def = GetEntProp(wep, Prop_Send, "m_iItemDefinitionIndex");
		WeaponInfo w;
		if (GetWeaponByDef(def, w) && w.cat != Cat_Knife)
		{
			ShowStickerMenu(client, def);
			return Plugin_Handled;
		}
	}
	ShowCategoryMenu(client);
	return Plugin_Handled;
}

// !gen <defindex> <paintkit> <pattern> <wear> [sticker1 wear1 ... sticker4 wear4]
public Action Cmd_Gen(int client, int args)
{
	if (!CheckReady(client))
		return Plugin_Handled;
	if (args < 2)
	{
		PrintToChat(client, "%sUsage: !gen <weapon id> <skin id> [pattern] [wear] [sticker wear ...]", PREFIX);
		return Plugin_Handled;
	}

	char arg[32];
	GetCmdArg(1, arg, sizeof(arg));
	int def = StringToInt(arg);
	GetCmdArg(2, arg, sizeof(arg));
	int paint = StringToInt(arg);
	int seed = 0;
	float wear = 0.0001;
	if (args >= 3)
	{
		GetCmdArg(3, arg, sizeof(arg));
		seed = StringToInt(arg);
	}
	if (args >= 4)
	{
		GetCmdArg(4, arg, sizeof(arg));
		wear = StringToFloat(arg);
	}
	if (seed < 0 || seed > 1000)
		seed = 0;
	if (wear <= 0.0 || wear > 1.0)
		wear = 0.0001;

	GloveInfo g;
	if (GetGloveByDef(def, g))
	{
		g_GloveDef[client] = def;
		g_GlovePaint[client] = paint;
		g_GloveWear[client] = wear;
		g_GloveSeed[client] = seed;
		SavePlayer(client);
		if (IsPlayerAlive(client))
			ApplyGloves(client, true);
		PrintToChat(client, "%sGloves set.", PREFIX);
		return Plugin_Handled;
	}

	WeaponInfo w;
	if (!GetWeaponByDef(def, w))
	{
		PrintToChat(client, "%sUnknown weapon id %d.", PREFIX, def);
		return Plugin_Handled;
	}

	WeaponSkin s;
	GetSkin(client, def, s);
	s.paint = paint;
	s.seed = seed;
	s.wear = wear;

	if (w.cat != Cat_Knife)
	{
		for (int i = 0; i < MAX_STICKER_SLOTS; i++)
		{
			int argId = 5 + i * 2;
			if (args < argId)
				break;
			GetCmdArg(argId, arg, sizeof(arg));
			s.sticker[i] = StringToInt(arg);
			s.stickerWear[i] = 0.0;
			if (args >= argId + 1)
			{
				GetCmdArg(argId + 1, arg, sizeof(arg));
				s.stickerWear[i] = StringToFloat(arg);
			}
		}
	}
	else
	{
		g_Knife[client] = def;
	}

	SetSkin(client, def, s);
	if (HasStickers(s))
		RefreshStickers(client, def);
	else
		RefreshWeapon(client, def);

	char skinName[NAME_LEN];
	GetPaintName(paint, skinName, sizeof(skinName));
	PrintToChat(client, "%s%s | %s applied.", PREFIX, w.name, skinName);
	return Plugin_Handled;
}

/* ================================================================== */
/*  Chat input                                                        */
/* ================================================================== */

void AskInput(int client, InputMode mode, const char[] prompt)
{
	g_Input[client] = mode;
	PrintToChat(client, "%s%s \x08(type \x04cancel\x08 to cancel)", PREFIX, prompt);
}

public Action Listener_Say(int client, const char[] command, int argc)
{
	if (!IsValidHuman(client) || g_Input[client] == Input_None)
		return Plugin_Continue;

	char text[128];
	GetCmdArgString(text, sizeof(text));
	StripQuotes(text);
	TrimString(text);

	InputMode mode = g_Input[client];
	g_Input[client] = Input_None;

	if (StrEqual(text, "cancel", false) || StrEqual(text, "!cancel", false))
	{
		PrintToChat(client, "%sCancelled.", PREFIX);
		ReturnFromInput(client, mode);
		return Plugin_Handled;
	}

	int def = g_MenuDef[client];
	int slot = g_MenuSlot[client];
	WeaponSkin s;

	switch (mode)
	{
		case Input_SkinSearch:
		{
			ShowSkinList(client, def, text);
		}
		case Input_Wear:
		{
			float wear = StringToFloat(text);
			if (wear < 0.0 || wear > 1.0)
			{
				PrintToChat(client, "%sWear must be between 0 and 1.", PREFIX);
			}
			else
			{
				GetSkin(client, def, s);
				s.wear = wear;
				SetSkin(client, def, s);
				RefreshWeapon(client, def);
			}
			ShowWeaponMenu(client, def);
		}
		case Input_Seed:
		{
			int seed = StringToInt(text);
			if (!IsNumeric(text) || seed < 0 || seed > 1000)
			{
				PrintToChat(client, "%sPattern must be a number from 0 to 1000.", PREFIX);
			}
			else
			{
				GetSkin(client, def, s);
				s.seed = seed;
				SetSkin(client, def, s);
				RefreshWeapon(client, def);
			}
			ShowWeaponMenu(client, def);
		}
		case Input_NameTag:
		{
			GetSkin(client, def, s);
			ReplaceString(text, sizeof(text), "\"", "'");
			ReplaceString(text, sizeof(text), ";", "");
			strcopy(s.nametag, sizeof(s.nametag), text);
			SetSkin(client, def, s);
			RefreshWeapon(client, def);
			PrintToChat(client, "%sName tag set to \"%s\".", PREFIX, s.nametag);
			ShowWeaponMenu(client, def);
		}
		case Input_StickerSearch:
		{
			ShowKitResults(client, g_Stickers, text, false);
		}
		case Input_StickerId:
		{
			int id = StringToInt(text);
			char kitName[NAME_LEN], key[16];
			IntToString(id, key, sizeof(key));
			if (!g_KitDisplay.GetString(key, kitName, sizeof(kitName)))
			{
				PrintToChat(client, "%sNo sticker with id %s.", PREFIX, text);
				ShowStickerSlotMenu(client, def, slot);
			}
			else
			{
				SetSticker(client, def, slot, id);
			}
		}
		case Input_StickerWear:
		{
			float wear = StringToFloat(text);
			if (wear < 0.0 || wear > 1.0)
			{
				PrintToChat(client, "%sWear must be between 0 and 1.", PREFIX);
			}
			else
			{
				GetSkin(client, def, s);
				s.stickerWear[slot] = wear;
				SetSkin(client, def, s);
				RefreshStickers(client, def);
			}
			ShowStickerSlotMenu(client, def, slot);
		}
		case Input_PatchSearch:
		{
			ShowKitResults(client, g_Patches, text, true);
		}
		case Input_PatchId:
		{
			int id = StringToInt(text);
			char kitName[NAME_LEN], key[16];
			IntToString(id, key, sizeof(key));
			if (!g_KitDisplay.GetString(key, kitName, sizeof(kitName)))
				PrintToChat(client, "%sNo patch with id %s.", PREFIX, text);
			else
				SetPatch(client, slot, id);
			ShowPatchMenu(client);
		}
		case Input_GloveWear:
		{
			float wear = StringToFloat(text);
			if (wear < 0.0 || wear > 1.0)
			{
				PrintToChat(client, "%sWear must be between 0 and 1.", PREFIX);
			}
			else
			{
				g_GloveWear[client] = wear;
				SavePlayer(client);
				if (IsPlayerAlive(client))
					ApplyGloves(client, true);
			}
			ShowGloveMenu(client);
		}
		case Input_GloveSeed:
		{
			int seed = StringToInt(text);
			if (!IsNumeric(text) || seed < 0 || seed > 1000)
			{
				PrintToChat(client, "%sPattern must be a number from 0 to 1000.", PREFIX);
			}
			else
			{
				g_GloveSeed[client] = seed;
				SavePlayer(client);
				if (IsPlayerAlive(client))
					ApplyGloves(client, true);
			}
			ShowGloveMenu(client);
		}
	}
	return Plugin_Handled;
}

void ReturnFromInput(int client, InputMode mode)
{
	switch (mode)
	{
		case Input_StickerSearch, Input_StickerId, Input_StickerWear:
			ShowStickerSlotMenu(client, g_MenuDef[client], g_MenuSlot[client]);
		case Input_PatchSearch, Input_PatchId:
			ShowPatchMenu(client);
		case Input_GloveWear, Input_GloveSeed:
			ShowGloveMenu(client);
		default:
			ShowWeaponMenu(client, g_MenuDef[client]);
	}
}

bool IsNumeric(const char[] s)
{
	if (s[0] == '\0')
		return false;
	for (int i = 0; s[i] != '\0'; i++)
	{
		if (!IsCharNumeric(s[i]))
			return false;
	}
	return true;
}

/* ================================================================== */
/*  Menus                                                             */
/* ================================================================== */

void ShowMainMenu(int client)
{
	Menu menu = new Menu(Handler_Main);
	menu.SetTitle("CS:GO Loadout");

	char line[128], knifeName[32] = "Default";
	WeaponInfo w;
	if (g_Knife[client] != 0 && GetWeaponByDef(g_Knife[client], w))
		strcopy(knifeName, sizeof(knifeName), w.name);

	char gloveName[48] = "Default";
	GloveInfo g;
	if (g_GloveDef[client] != 0 && GetGloveByDef(g_GloveDef[client], g))
	{
		char paint[NAME_LEN];
		GetPaintName(g_GlovePaint[client], paint, sizeof(paint));
		Format(gloveName, sizeof(gloveName), "%s | %s", g.name, paint);
	}

	menu.AddItem("presets", "Preset loadouts (quick equip a full set)");
	menu.AddItem("slots", "Default weapons (USP-S, M4A1-S, CZ75...)");
	menu.AddItem("skins", "Weapon skins & stickers");
	Format(line, sizeof(line), "Knife: %s", knifeName);
	menu.AddItem("knife", line);
	Format(line, sizeof(line), "Gloves: %s", gloveName);
	menu.AddItem("gloves", line);
	menu.AddItem("agents", "Agents");
	menu.AddItem("patches", "Agent patches", g_PatchesReady ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
	menu.AddItem("reset", "Reset entire loadout");
	menu.Display(client, MENU_TIME_FOREVER);
}

public int Handler_Main(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_End)
	{
		delete menu;
	}
	else if (action == MenuAction_Select)
	{
		char info[16];
		menu.GetItem(item, info, sizeof(info));
		if (StrEqual(info, "presets"))
			ShowPresetMenu(client);
		else if (StrEqual(info, "slots"))
			ShowSlotsMenu(client);
		else if (StrEqual(info, "skins"))
			ShowCategoryMenu(client);
		else if (StrEqual(info, "knife"))
			ShowKnifeMenu(client);
		else if (StrEqual(info, "gloves"))
			ShowGloveMenu(client);
		else if (StrEqual(info, "agents"))
			ShowAgentTeamMenu(client);
		else if (StrEqual(info, "patches"))
			ShowPatchMenu(client);
		else if (StrEqual(info, "reset"))
			ShowResetConfirm(client);
	}
	return 0;
}

void ShowResetConfirm(int client)
{
	Menu menu = new Menu(Handler_Reset);
	menu.SetTitle("Reset your whole loadout?\nThis removes every skin, sticker, knife, glove, agent and patch.");
	menu.AddItem("yes", "Yes, reset everything");
	menu.AddItem("no", "No, go back");
	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int Handler_Reset(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_End)
	{
		delete menu;
	}
	else if (action == MenuAction_Select)
	{
		char info[8];
		menu.GetItem(item, info, sizeof(info));
		if (StrEqual(info, "yes"))
		{
			char key[64];
			strcopy(key, sizeof(key), g_FileKey[client]);
			ResetPlayer(client);
			strcopy(g_FileKey[client], sizeof(g_FileKey[]), key);
			g_Loaded[client] = true;
			SavePlayer(client);
			PrintToChat(client, "%sLoadout reset. Changes show fully next round.", PREFIX);
		}
		ShowMainMenu(client);
	}
	else if (action == MenuAction_Cancel && item == MenuCancel_ExitBack)
	{
		ShowMainMenu(client);
	}
	return 0;
}

/* ---------- Default weapons (loadout slots) ---------- */

public Action Cmd_Slots(int client, int args)
{
	if (CheckReady(client))
		ShowSlotsMenu(client);
	return Plugin_Handled;
}

void ShowSlotsMenu(int client)
{
	Menu menu = new Menu(Handler_Slots);
	menu.SetTitle("Default weapons\nPick an option to switch it, then Save.");

	WeaponInfo def, alt;
	char info[8], line[96];
	for (int i = 0; i < SLOT_COUNT; i++)
	{
		GetWeaponByDef(g_SlotDefault[i], def);
		GetWeaponByDef(g_SlotAlt[i], alt);
		IntToString(i, info, sizeof(info));
		if (g_SlotAltOn[client][i])
			Format(line, sizeof(line), "%s: %s  (or %s)", g_SlotTitle[i], alt.name, def.name);
		else
			Format(line, sizeof(line), "%s: %s  (or %s)", g_SlotTitle[i], def.name, alt.name);
		menu.AddItem(info, line);
	}
	menu.AddItem("save", "Save");
	menu.ExitBackButton = g_SlotsSet[client];
	menu.Display(client, MENU_TIME_FOREVER);
}

public int Handler_Slots(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_End)
	{
		delete menu;
	}
	else if (action == MenuAction_Select)
	{
		char info[8];
		menu.GetItem(item, info, sizeof(info));
		if (StrEqual(info, "save"))
		{
			g_SlotsSet[client] = true;
			SavePlayer(client);
			SwapHeldWeapons(client);
			PrintToChat(client, "%sDefault weapons saved. Change them any time with \x04!slots\x01.", PREFIX);
			return 0;
		}
		int slot = StringToInt(info);
		g_SlotAltOn[client][slot] = !g_SlotAltOn[client][slot];
		ShowSlotsMenu(client);
	}
	else if (action == MenuAction_Cancel && item == MenuCancel_ExitBack)
	{
		ShowMainMenu(client);
	}
	return 0;
}

/* ---------- Weapon skins ---------- */

void ShowCategoryMenu(int client)
{
	Menu menu = new Menu(Handler_Category);
	menu.SetTitle("Weapon skins");
	menu.AddItem("0", "Pistols");
	menu.AddItem("1", "Rifles");
	menu.AddItem("2", "SMGs");
	menu.AddItem("3", "Heavy");
	menu.AddItem("4", "Knife skins");
	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int Handler_Category(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_End)
	{
		delete menu;
	}
	else if (action == MenuAction_Select)
	{
		char info[8];
		menu.GetItem(item, info, sizeof(info));
		ShowWeaponList(client, StringToInt(info));
	}
	else if (action == MenuAction_Cancel && item == MenuCancel_ExitBack)
	{
		ShowMainMenu(client);
	}
	return 0;
}

void ShowWeaponList(int client, int cat)
{
	g_MenuCat[client] = cat;
	Menu menu = new Menu(Handler_WeaponList);
	menu.SetTitle("Choose a weapon");

	WeaponInfo w;
	WeaponSkin s;
	char info[16], line[96], paint[NAME_LEN];
	for (int i = 0; i < g_Weapons.Length; i++)
	{
		g_Weapons.GetArray(i, w);
		if (w.cat != cat)
			continue;
		GetSkin(client, w.def, s);
		IntToString(w.def, info, sizeof(info));
		if (s.paint != 0)
		{
			GetPaintName(s.paint, paint, sizeof(paint));
			Format(line, sizeof(line), "%s | %s", w.name, paint);
		}
		else
		{
			strcopy(line, sizeof(line), w.name);
		}
		menu.AddItem(info, line);
	}
	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int Handler_WeaponList(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_End)
	{
		delete menu;
	}
	else if (action == MenuAction_Select)
	{
		char info[16];
		menu.GetItem(item, info, sizeof(info));
		ShowWeaponMenu(client, StringToInt(info));
	}
	else if (action == MenuAction_Cancel && item == MenuCancel_ExitBack)
	{
		ShowCategoryMenu(client);
	}
	return 0;
}

void ShowWeaponMenu(int client, int def)
{
	WeaponInfo w;
	if (!GetWeaponByDef(def, w))
		return;
	g_MenuDef[client] = def;
	g_MenuCat[client] = w.cat;

	WeaponSkin s;
	GetSkin(client, def, s);

	char paint[NAME_LEN], wearName[24], title[256], line[96];
	GetPaintName(s.paint, paint, sizeof(paint));
	WearName(s.wear, wearName, sizeof(wearName));

	Format(title, sizeof(title), "%s | %s\nWear: %.4f (%s)  Pattern: %d", w.name, paint, s.wear, wearName, s.seed);
	if (s.stattrak >= 0)
		Format(title, sizeof(title), "%s\nStatTrak: %d kills", title, s.stattrak);
	if (s.nametag[0] != '\0')
		Format(title, sizeof(title), "%s\nName tag: \"%s\"", title, s.nametag);

	Menu menu = new Menu(Handler_WeaponMenu);
	menu.SetTitle(title);
	menu.AddItem("skin", "Change skin");
	Format(line, sizeof(line), "Wear: %.4f", s.wear);
	menu.AddItem("wear", line);
	Format(line, sizeof(line), "Pattern: %d", s.seed);
	menu.AddItem("seed", line);
	menu.AddItem("stattrak", s.stattrak >= 0 ? "StatTrak: On" : "StatTrak: Off");
	menu.AddItem("nametag", s.nametag[0] != '\0' ? "Name tag: change / remove" : "Name tag: add");
	if (w.cat != Cat_Knife)
		menu.AddItem("stickers", g_StickersReady ? "Stickers" : "Stickers (unavailable)", g_StickersReady ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
	menu.AddItem("reset", "Reset this weapon");
	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int Handler_WeaponMenu(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_End)
	{
		delete menu;
		return 0;
	}
	if (action == MenuAction_Cancel)
	{
		if (item == MenuCancel_ExitBack)
		{
			if (g_MenuCat[client] == Cat_Knife && g_Knife[client] == g_MenuDef[client])
				ShowKnifeMenu(client);
			else
				ShowWeaponList(client, g_MenuCat[client]);
		}
		return 0;
	}
	if (action != MenuAction_Select)
		return 0;

	int def = g_MenuDef[client];
	char info[16];
	menu.GetItem(item, info, sizeof(info));
	WeaponSkin s;

	if (StrEqual(info, "skin"))
	{
		ShowSkinList(client, def, "");
	}
	else if (StrEqual(info, "wear"))
	{
		ShowWearMenu(client);
	}
	else if (StrEqual(info, "seed"))
	{
		AskInput(client, Input_Seed, "Type a pattern number (0-1000) in chat.");
	}
	else if (StrEqual(info, "stattrak"))
	{
		GetSkin(client, def, s);
		s.stattrak = (s.stattrak >= 0) ? -1 : 0;
		SetSkin(client, def, s);
		RefreshWeapon(client, def);
		ShowWeaponMenu(client, def);
	}
	else if (StrEqual(info, "nametag"))
	{
		GetSkin(client, def, s);
		if (s.nametag[0] != '\0')
		{
			s.nametag[0] = '\0';
			SetSkin(client, def, s);
			RefreshWeapon(client, def);
			PrintToChat(client, "%sName tag removed. Choose it again to add a new one.", PREFIX);
			ShowWeaponMenu(client, def);
		}
		else
		{
			AskInput(client, Input_NameTag, "Type the name tag in chat (max 32 characters).");
		}
	}
	else if (StrEqual(info, "stickers"))
	{
		ShowStickerMenu(client, def);
	}
	else if (StrEqual(info, "reset"))
	{
		InitSkin(s);
		SetSkin(client, def, s);
		RefreshWeapon(client, def);
		ShowWeaponMenu(client, def);
	}
	return 0;
}

void ShowSkinList(int client, int def, const char[] filter)
{
	WeaponInfo w;
	if (!GetWeaponByDef(def, w))
		return;
	g_MenuDef[client] = def;

	WeaponSkin s;
	GetSkin(client, def, s);

	Menu menu = new Menu(Handler_SkinList);
	if (filter[0] != '\0')
		menu.SetTitle("%s skins matching \"%s\"", w.name, filter);
	else
		menu.SetTitle("%s skins", w.name);

	menu.AddItem("search", "Search by name...");
	menu.AddItem("0", s.paint == 0 ? "Default (no skin) [current]" : "Default (no skin)");

	ArrayList list = GetSkinList(w.cls);
	int shown = 0;
	if (list != null)
	{
		char info[16], name[NAME_LEN], line[96];
		for (int i = 0; i < list.Length; i++)
		{
			int id = list.Get(i);
			GetPaintName(id, name, sizeof(name));
			if (filter[0] != '\0' && StrContains(name, filter, false) == -1)
				continue;
			IntToString(id, info, sizeof(info));
			if (id == s.paint)
				Format(line, sizeof(line), "%s [current]", name);
			else
				strcopy(line, sizeof(line), name);
			menu.AddItem(info, line);
			shown++;
		}
	}
	if (shown == 0)
		menu.AddItem("none", "No skins found", ITEMDRAW_DISABLED);

	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int Handler_SkinList(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_End)
	{
		delete menu;
	}
	else if (action == MenuAction_Select)
	{
		char info[16];
		menu.GetItem(item, info, sizeof(info));
		if (StrEqual(info, "search"))
		{
			AskInput(client, Input_SkinSearch, "Type part of the skin name in chat.");
			return 0;
		}

		int def = g_MenuDef[client];
		WeaponSkin s;
		GetSkin(client, def, s);
		s.paint = StringToInt(info);
		SetSkin(client, def, s);
		RefreshWeapon(client, def);
		ShowWeaponMenu(client, def);
	}
	else if (action == MenuAction_Cancel && item == MenuCancel_ExitBack)
	{
		ShowWeaponMenu(client, g_MenuDef[client]);
	}
	return 0;
}

void ShowWearMenu(int client)
{
	Menu menu = new Menu(Handler_Wear);
	menu.SetTitle("Wear (0 = perfect, 1 = most worn)");
	menu.AddItem("0.0001", "Factory New (0.00)");
	menu.AddItem("0.07", "Minimal Wear (0.07)");
	menu.AddItem("0.15", "Field-Tested (0.15)");
	menu.AddItem("0.38", "Well-Worn (0.38)");
	menu.AddItem("0.45", "Battle-Scarred (0.45)");
	menu.AddItem("0.9999", "Maximum (1.00)");
	menu.AddItem("custom", "Type an exact value...");
	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int Handler_Wear(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_End)
	{
		delete menu;
	}
	else if (action == MenuAction_Select)
	{
		char info[16];
		menu.GetItem(item, info, sizeof(info));
		if (StrEqual(info, "custom"))
		{
			AskInput(client, Input_Wear, "Type a wear value between 0 and 1 (e.g. 0.0123) in chat.");
			return 0;
		}
		int def = g_MenuDef[client];
		WeaponSkin s;
		GetSkin(client, def, s);
		s.wear = StringToFloat(info);
		SetSkin(client, def, s);
		RefreshWeapon(client, def);
		ShowWeaponMenu(client, def);
	}
	else if (action == MenuAction_Cancel && item == MenuCancel_ExitBack)
	{
		ShowWeaponMenu(client, g_MenuDef[client]);
	}
	return 0;
}

/* ---------- Stickers ---------- */

void ShowStickerMenu(int client, int def)
{
	WeaponInfo w;
	if (!GetWeaponByDef(def, w))
		return;
	g_MenuDef[client] = def;

	if (!g_StickersReady)
	{
		PrintToChat(client, "%sStickers aren't available on this server (see the server log).", PREFIX);
		ShowWeaponMenu(client, def);
		return;
	}

	WeaponSkin s;
	GetSkin(client, def, s);

	Menu menu = new Menu(Handler_StickerMenu);
	menu.SetTitle("%s stickers", w.name);
	char info[8], line[96], name[NAME_LEN];
	for (int i = 0; i < MAX_STICKER_SLOTS; i++)
	{
		GetKitName(s.sticker[i], name, sizeof(name));
		IntToString(i, info, sizeof(info));
		Format(line, sizeof(line), "Slot %d: %s", i + 1, name);
		menu.AddItem(info, line);
	}
	menu.AddItem("clear", "Remove all stickers");
	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int Handler_StickerMenu(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_End)
	{
		delete menu;
	}
	else if (action == MenuAction_Select)
	{
		char info[8];
		menu.GetItem(item, info, sizeof(info));
		int def = g_MenuDef[client];
		if (StrEqual(info, "clear"))
		{
			WeaponSkin s;
			GetSkin(client, def, s);
			for (int i = 0; i < MAX_STICKER_SLOTS; i++)
			{
				s.sticker[i] = 0;
				s.stickerWear[i] = 0.0;
			}
			SetSkin(client, def, s);
			RefreshStickers(client, def);
			ShowStickerMenu(client, def);
			return 0;
		}
		ShowStickerSlotMenu(client, def, StringToInt(info));
	}
	else if (action == MenuAction_Cancel && item == MenuCancel_ExitBack)
	{
		ShowWeaponMenu(client, g_MenuDef[client]);
	}
	return 0;
}

void ShowStickerSlotMenu(int client, int def, int slot)
{
	g_MenuDef[client] = def;
	g_MenuSlot[client] = slot;

	WeaponSkin s;
	GetSkin(client, def, s);

	char name[NAME_LEN], line[96];
	GetKitName(s.sticker[slot], name, sizeof(name));

	Menu menu = new Menu(Handler_StickerSlot);
	menu.SetTitle("Sticker slot %d\nCurrent: %s\nWear: %.2f", slot + 1, name, s.stickerWear[slot]);
	menu.AddItem("search", "Choose sticker (search by name)");
	menu.AddItem("id", "Enter sticker ID");
	Format(line, sizeof(line), "Wear: %.2f", s.stickerWear[slot]);
	menu.AddItem("wear", line);
	menu.AddItem("all", "Copy to all 4 slots (4x)", s.sticker[slot] != 0 ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
	menu.AddItem("remove", "Remove", s.sticker[slot] != 0 ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int Handler_StickerSlot(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_End)
	{
		delete menu;
	}
	else if (action == MenuAction_Select)
	{
		char info[16];
		menu.GetItem(item, info, sizeof(info));
		int def = g_MenuDef[client];
		int slot = g_MenuSlot[client];
		WeaponSkin s;

		if (StrEqual(info, "search"))
		{
			AskInput(client, Input_StickerSearch, "Type part of the sticker name in chat (e.g. \"titan holo\").");
		}
		else if (StrEqual(info, "id"))
		{
			AskInput(client, Input_StickerId, "Type the sticker ID number in chat.");
		}
		else if (StrEqual(info, "wear"))
		{
			AskInput(client, Input_StickerWear, "Type sticker wear between 0 (new) and 1 (scraped) in chat.");
		}
		else if (StrEqual(info, "all"))
		{
			GetSkin(client, def, s);
			for (int i = 0; i < MAX_STICKER_SLOTS; i++)
			{
				s.sticker[i] = s.sticker[slot];
				s.stickerWear[i] = s.stickerWear[slot];
			}
			SetSkin(client, def, s);
			RefreshStickers(client, def);
			ShowStickerMenu(client, def);
		}
		else if (StrEqual(info, "remove"))
		{
			GetSkin(client, def, s);
			s.sticker[slot] = 0;
			s.stickerWear[slot] = 0.0;
			SetSkin(client, def, s);
			RefreshStickers(client, def);
			ShowStickerMenu(client, def);
		}
	}
	else if (action == MenuAction_Cancel && item == MenuCancel_ExitBack)
	{
		ShowStickerMenu(client, g_MenuDef[client]);
	}
	return 0;
}

void SetSticker(int client, int def, int slot, int id)
{
	WeaponSkin s;
	GetSkin(client, def, s);
	s.sticker[slot] = id;
	SetSkin(client, def, s);
	RefreshStickers(client, def);

	char name[NAME_LEN];
	GetKitName(id, name, sizeof(name));
	PrintToChat(client, "%sSlot %d: %s", PREFIX, slot + 1, name);
	ShowStickerMenu(client, def);
}

void ShowKitResults(int client, ArrayList list, const char[] filter, bool patches)
{
	Menu menu = new Menu(patches ? Handler_PatchResults : Handler_StickerResults);
	menu.SetTitle("%s matching \"%s\"", patches ? "Patches" : "Stickers", filter);

	NamedId kit;
	char info[16];
	int found = 0;
	for (int i = 0; i < list.Length; i++)
	{
		list.GetArray(i, kit);
		if (StrContains(kit.name, filter, false) == -1)
			continue;
		if (found >= MAX_SEARCH_RESULTS)
		{
			PrintToChat(client, "%sShowing the first %d matches — be more specific to narrow it down.", PREFIX, MAX_SEARCH_RESULTS);
			break;
		}
		IntToString(kit.id, info, sizeof(info));
		menu.AddItem(info, kit.name);
		found++;
	}
	if (found == 0)
		menu.AddItem("none", "Nothing found", ITEMDRAW_DISABLED);

	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int Handler_StickerResults(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_End)
	{
		delete menu;
	}
	else if (action == MenuAction_Select)
	{
		char info[16];
		menu.GetItem(item, info, sizeof(info));
		SetSticker(client, g_MenuDef[client], g_MenuSlot[client], StringToInt(info));
	}
	else if (action == MenuAction_Cancel && item == MenuCancel_ExitBack)
	{
		ShowStickerSlotMenu(client, g_MenuDef[client], g_MenuSlot[client]);
	}
	return 0;
}

/* ---------- Knife ---------- */

void ShowKnifeMenu(int client)
{
	Menu menu = new Menu(Handler_Knife);
	WeaponInfo w;
	char current[32] = "Default";
	if (g_Knife[client] != 0 && GetWeaponByDef(g_Knife[client], w))
		strcopy(current, sizeof(current), w.name);
	menu.SetTitle("Knife\nCurrent: %s", current);

	if (g_Knife[client] != 0)
		menu.AddItem("skin", "Skin for this knife...");
	menu.AddItem("0", g_Knife[client] == 0 ? "Default knife [current]" : "Default knife");

	char info[16], line[64];
	for (int i = 0; i < g_Weapons.Length; i++)
	{
		g_Weapons.GetArray(i, w);
		if (w.cat != Cat_Knife)
			continue;
		IntToString(w.def, info, sizeof(info));
		if (w.def == g_Knife[client])
			Format(line, sizeof(line), "%s [current]", w.name);
		else
			strcopy(line, sizeof(line), w.name);
		menu.AddItem(info, line);
	}
	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int Handler_Knife(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_End)
	{
		delete menu;
	}
	else if (action == MenuAction_Select)
	{
		char info[16];
		menu.GetItem(item, info, sizeof(info));
		if (StrEqual(info, "skin"))
		{
			ShowWeaponMenu(client, g_Knife[client]);
			return 0;
		}
		g_Knife[client] = StringToInt(info);
		SavePlayer(client);
		RefreshWeapon(client, 42);
		ShowKnifeMenu(client);
	}
	else if (action == MenuAction_Cancel && item == MenuCancel_ExitBack)
	{
		ShowMainMenu(client);
	}
	return 0;
}

/* ---------- Gloves ---------- */

void ShowGloveMenu(int client)
{
	Menu menu = new Menu(Handler_GloveMenu);
	char current[NAME_LEN + 32] = "Default", paint[NAME_LEN], wearName[24], line[64];
	GloveInfo g;
	if (g_GloveDef[client] != 0 && GetGloveByDef(g_GloveDef[client], g))
	{
		GetPaintName(g_GlovePaint[client], paint, sizeof(paint));
		Format(current, sizeof(current), "%s | %s", g.name, paint);
	}
	WearName(g_GloveWear[client], wearName, sizeof(wearName));
	menu.SetTitle("Gloves\nCurrent: %s", current);

	menu.AddItem("choose", "Choose gloves");
	bool has = (g_GloveDef[client] != 0);
	Format(line, sizeof(line), "Wear: %.4f (%s)", g_GloveWear[client], wearName);
	menu.AddItem("wear", line, has ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
	Format(line, sizeof(line), "Pattern: %d", g_GloveSeed[client]);
	menu.AddItem("seed", line, has ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
	menu.AddItem("remove", "Remove gloves", has ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int Handler_GloveMenu(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_End)
	{
		delete menu;
	}
	else if (action == MenuAction_Select)
	{
		char info[16];
		menu.GetItem(item, info, sizeof(info));
		if (StrEqual(info, "choose"))
		{
			ShowGloveTypes(client);
		}
		else if (StrEqual(info, "wear"))
		{
			AskInput(client, Input_GloveWear, "Type a glove wear value between 0 and 1 in chat.");
		}
		else if (StrEqual(info, "seed"))
		{
			AskInput(client, Input_GloveSeed, "Type a glove pattern number (0-1000) in chat.");
		}
		else if (StrEqual(info, "remove"))
		{
			g_GloveDef[client] = 0;
			g_GlovePaint[client] = 0;
			SavePlayer(client);
			PrintToChat(client, "%sGloves removed — your default gloves come back next round.", PREFIX);
			ShowGloveMenu(client);
		}
	}
	else if (action == MenuAction_Cancel && item == MenuCancel_ExitBack)
	{
		ShowMainMenu(client);
	}
	return 0;
}

void ShowGloveTypes(int client)
{
	Menu menu = new Menu(Handler_GloveTypes);
	menu.SetTitle("Choose gloves");
	GloveInfo g;
	char info[16];
	for (int i = 0; i < g_Gloves.Length; i++)
	{
		g_Gloves.GetArray(i, g);
		ArrayList list = GetSkinList(g.prefix);
		IntToString(g.def, info, sizeof(info));
		menu.AddItem(info, g.name, (list != null && list.Length > 0) ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
	}
	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int Handler_GloveTypes(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_End)
	{
		delete menu;
	}
	else if (action == MenuAction_Select)
	{
		char info[16];
		menu.GetItem(item, info, sizeof(info));
		ShowGloveSkins(client, StringToInt(info));
	}
	else if (action == MenuAction_Cancel && item == MenuCancel_ExitBack)
	{
		ShowGloveMenu(client);
	}
	return 0;
}

void ShowGloveSkins(int client, int def)
{
	GloveInfo g;
	if (!GetGloveByDef(def, g))
		return;
	g_MenuDef[client] = def;

	Menu menu = new Menu(Handler_GloveSkins);
	menu.SetTitle("%s", g.name);
	ArrayList list = GetSkinList(g.prefix);
	char info[16], name[NAME_LEN], line[96];
	if (list != null)
	{
		for (int i = 0; i < list.Length; i++)
		{
			int id = list.Get(i);
			GetPaintName(id, name, sizeof(name));
			IntToString(id, info, sizeof(info));
			if (def == g_GloveDef[client] && id == g_GlovePaint[client])
				Format(line, sizeof(line), "%s [current]", name);
			else
				strcopy(line, sizeof(line), name);
			menu.AddItem(info, line);
		}
	}
	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int Handler_GloveSkins(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_End)
	{
		delete menu;
	}
	else if (action == MenuAction_Select)
	{
		char info[16];
		menu.GetItem(item, info, sizeof(info));
		g_GloveDef[client] = g_MenuDef[client];
		g_GlovePaint[client] = StringToInt(info);
		SavePlayer(client);
		if (IsPlayerAlive(client))
		{
			ApplyGloves(client, true);
			ShowPreview(client, 3.0);
		}
		ShowGloveMenu(client);
	}
	else if (action == MenuAction_Cancel && item == MenuCancel_ExitBack)
	{
		ShowGloveTypes(client);
	}
	return 0;
}

/* ---------- Agents ---------- */

void ShowAgentTeamMenu(int client)
{
	char tName[NAME_LEN], ctName[NAME_LEN], line[96];
	GetAgentName(g_AgentT[client], tName, sizeof(tName));
	GetAgentName(g_AgentCT[client], ctName, sizeof(ctName));

	Menu menu = new Menu(Handler_AgentTeam);
	menu.SetTitle("Agents\n(applied when you spawn)");
	Format(line, sizeof(line), "T agent: %s", tName);
	menu.AddItem("2", line);
	Format(line, sizeof(line), "CT agent: %s", ctName);
	menu.AddItem("3", line);
	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int Handler_AgentTeam(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_End)
	{
		delete menu;
	}
	else if (action == MenuAction_Select)
	{
		char info[8];
		menu.GetItem(item, info, sizeof(info));
		ShowAgentList(client, StringToInt(info));
	}
	else if (action == MenuAction_Cancel && item == MenuCancel_ExitBack)
	{
		ShowMainMenu(client);
	}
	return 0;
}

void ShowAgentList(int client, int team)
{
	g_MenuTeam[client] = team;
	int current = (team == CS_TEAM_T) ? g_AgentT[client] : g_AgentCT[client];

	Menu menu = new Menu(Handler_AgentList);
	menu.SetTitle(team == CS_TEAM_T ? "T agents" : "CT agents");
	menu.AddItem("0", current == 0 ? "Default [current]" : "Default");

	AgentInfo a;
	char info[16], line[96];
	for (int i = 0; i < g_Agents.Length; i++)
	{
		g_Agents.GetArray(i, a);
		if (a.team != team)
			continue;
		IntToString(a.def, info, sizeof(info));
		if (a.def == current)
			Format(line, sizeof(line), "%s [current]", a.name);
		else
			strcopy(line, sizeof(line), a.name);
		menu.AddItem(info, line);
	}
	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int Handler_AgentList(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_End)
	{
		delete menu;
	}
	else if (action == MenuAction_Select)
	{
		char info[16];
		menu.GetItem(item, info, sizeof(info));
		int def = StringToInt(info);
		if (g_MenuTeam[client] == CS_TEAM_T)
			g_AgentT[client] = def;
		else
			g_AgentCT[client] = def;
		SavePlayer(client);

		if (IsPlayerAlive(client) && GetClientTeam(client) == g_MenuTeam[client])
		{
			if (def != 0)
			{
				ApplyAgent(client);
				ApplyPatches(client);
				ShowPreview(client, 4.0);
			}
			else
			{
				PrintToChat(client, "%sAgent cleared — the default model comes back next time you spawn.", PREFIX);
			}
		}
		else
		{
			PrintToChat(client, "%sAgent saved — it shows when you next spawn on that team.", PREFIX);
		}
		ShowAgentTeamMenu(client);
	}
	else if (action == MenuAction_Cancel && item == MenuCancel_ExitBack)
	{
		ShowAgentTeamMenu(client);
	}
	return 0;
}

/* ---------- Patches ---------- */

void ShowPatchMenu(int client)
{
	if (!g_PatchesReady)
	{
		PrintToChat(client, "%sAgent patches aren't supported on this server build.", PREFIX);
		return;
	}

	Menu menu = new Menu(Handler_PatchMenu);
	menu.SetTitle("Agent patches\n(3 spots; only show on agents, not default models)");
	char info[8], line[96], name[NAME_LEN];
	for (int i = 0; i < MAX_PATCH_SLOTS; i++)
	{
		GetKitName(g_Patch[client][i], name, sizeof(name));
		IntToString(i, info, sizeof(info));
		Format(line, sizeof(line), "Patch %d: %s", i + 1, name);
		menu.AddItem(info, line);
	}
	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int Handler_PatchMenu(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_End)
	{
		delete menu;
	}
	else if (action == MenuAction_Select)
	{
		char info[8];
		menu.GetItem(item, info, sizeof(info));
		g_MenuSlot[client] = StringToInt(info);
		ShowPatchSlotMenu(client);
	}
	else if (action == MenuAction_Cancel && item == MenuCancel_ExitBack)
	{
		ShowMainMenu(client);
	}
	return 0;
}

void ShowPatchSlotMenu(int client)
{
	int slot = g_MenuSlot[client];
	char name[NAME_LEN];
	GetKitName(g_Patch[client][slot], name, sizeof(name));

	Menu menu = new Menu(Handler_PatchSlot);
	menu.SetTitle("Patch slot %d\nCurrent: %s", slot + 1, name);
	menu.AddItem("search", "Choose patch (search by name)");
	menu.AddItem("browse", "Browse all patches");
	menu.AddItem("id", "Enter patch ID");
	menu.AddItem("remove", "Remove", g_Patch[client][slot] != 0 ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int Handler_PatchSlot(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_End)
	{
		delete menu;
	}
	else if (action == MenuAction_Select)
	{
		char info[16];
		menu.GetItem(item, info, sizeof(info));
		if (StrEqual(info, "search"))
			AskInput(client, Input_PatchSearch, "Type part of the patch name in chat.");
		else if (StrEqual(info, "browse"))
			ShowKitResults(client, g_Patches, "", true);
		else if (StrEqual(info, "id"))
			AskInput(client, Input_PatchId, "Type the patch ID number in chat.");
		else if (StrEqual(info, "remove"))
		{
			SetPatch(client, g_MenuSlot[client], 0);
			ShowPatchMenu(client);
		}
	}
	else if (action == MenuAction_Cancel && item == MenuCancel_ExitBack)
	{
		ShowPatchMenu(client);
	}
	return 0;
}

public int Handler_PatchResults(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_End)
	{
		delete menu;
	}
	else if (action == MenuAction_Select)
	{
		char info[16];
		menu.GetItem(item, info, sizeof(info));
		SetPatch(client, g_MenuSlot[client], StringToInt(info));
		ShowPatchMenu(client);
	}
	else if (action == MenuAction_Cancel && item == MenuCancel_ExitBack)
	{
		ShowPatchSlotMenu(client);
	}
	return 0;
}

void SetPatch(int client, int slot, int id)
{
	g_Patch[client][slot] = id;
	SavePlayer(client);
	if (IsPlayerAlive(client))
	{
		ApplyPatches(client);
		ShowPreview(client, 4.0);
	}
}


/* ---------- Preset loadouts ---------- */

void LoadPresets()
{
	delete g_Presets;
	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), "configs/csgo_loadout_presets.cfg");
	if (!FileExists(path))
		return;
	g_Presets = new KeyValues("Presets");
	if (!g_Presets.ImportFromFile(path))
	{
		LogError("Could not read %s", path);
		delete g_Presets;
	}
}

public Action Cmd_Presets(int client, int args)
{
	if (CheckReady(client))
		ShowPresetMenu(client);
	return Plugin_Handled;
}

void ShowPresetMenu(int client)
{
	Menu menu = new Menu(Handler_PresetList);
	menu.SetTitle("Preset loadouts\nKnife, gloves and skins with matching sticker crafts");
	char name[64], desc[128], line[200];
	int count = 0;
	if (g_Presets != null)
	{
		g_Presets.Rewind();
		if (g_Presets.GotoFirstSubKey())
		{
			do
			{
				g_Presets.GetSectionName(name, sizeof(name));
				g_Presets.GetString("description", desc, sizeof(desc));
				if (desc[0] != '\0')
					Format(line, sizeof(line), "%s\n   %s", name, desc);
				else
					strcopy(line, sizeof(line), name);
				menu.AddItem(name, line);
				count++;
			}
			while (g_Presets.GotoNextKey());
		}
		g_Presets.Rewind();
	}
	if (count == 0)
		menu.AddItem("", "No presets (configs/csgo_loadout_presets.cfg missing)", ITEMDRAW_DISABLED);
	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int Handler_PresetList(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_End)
		delete menu;
	else if (action == MenuAction_Select)
	{
		char name[64];
		menu.GetItem(item, name, sizeof(name));
		ShowPresetDetail(client, name);
	}
	else if (action == MenuAction_Cancel && item == MenuCancel_ExitBack)
		ShowMainMenu(client);
	return 0;
}

bool JumpToPreset(const char[] name)
{
	if (g_Presets == null)
		return false;
	g_Presets.Rewind();
	return g_Presets.JumpToKey(name);
}

void ShowPresetDetail(int client, const char[] name)
{
	if (!JumpToPreset(name))
	{
		ShowPresetMenu(client);
		return;
	}
	Menu menu = new Menu(Handler_PresetDetail);
	menu.SetTitle("%s", name);
	menu.AddItem(name, "EQUIP THIS SET");

	char line[128], paint[NAME_LEN];
	WeaponInfo w;
	GloveInfo g;
	int def = g_Presets.GetNum("knife", 0);
	if (def != 0 && GetWeaponByDef(def, w))
	{
		GetPaintName(g_Presets.GetNum("knife_paint", 0), paint, sizeof(paint));
		Format(line, sizeof(line), "%s | %s", w.name, paint);
		menu.AddItem("", line, ITEMDRAW_DISABLED);
	}
	def = g_Presets.GetNum("glove", 0);
	if (def != 0 && GetGloveByDef(def, g))
	{
		GetPaintName(g_Presets.GetNum("glove_paint", 0), paint, sizeof(paint));
		Format(line, sizeof(line), "%s | %s", g.name, paint);
		menu.AddItem("", line, ITEMDRAW_DISABLED);
	}
	if (g_Presets.JumpToKey("weapons") && g_Presets.GotoFirstSubKey())
	{
		char section[16];
		do
		{
			g_Presets.GetSectionName(section, sizeof(section));
			if (!GetWeaponByDef(StringToInt(section), w))
				continue;
			GetPaintName(g_Presets.GetNum("paint", 0), paint, sizeof(paint));
			Format(line, sizeof(line), "%s | %s", w.name, paint);
			menu.AddItem("", line, ITEMDRAW_DISABLED);
		}
		while (g_Presets.GotoNextKey());
	}
	g_Presets.Rewind();
	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int Handler_PresetDetail(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_End)
		delete menu;
	else if (action == MenuAction_Select)
	{
		char name[64];
		menu.GetItem(item, name, sizeof(name));
		if (name[0] != '\0')
			ApplyPreset(client, name);
		ShowPresetMenu(client);
	}
	else if (action == MenuAction_Cancel && item == MenuCancel_ExitBack)
		ShowPresetMenu(client);
	return 0;
}

void ApplyPreset(int client, const char[] name)
{
	if (!CheckReady(client) || !JumpToPreset(name))
		return;

	WeaponSkin s;
	char key[16], list[64], parts[MAX_STICKER_SLOTS][12];
	int defs[64], count = 0;
	bool stickers = false;

	// Knife
	int knife = g_Presets.GetNum("knife", 0);
	WeaponInfo w;
	if (knife != 0 && GetWeaponByDef(knife, w))
	{
		g_Knife[client] = knife;
		GetSkin(client, knife, s);
		s.paint = g_Presets.GetNum("knife_paint", 0);
		s.seed = g_Presets.GetNum("knife_seed", 0);
		s.wear = 0.0001;
		IntToString(knife, key, sizeof(key));
		g_Skins[client].SetArray(key, s, sizeof(s));
	}

	// Gloves
	int glove = g_Presets.GetNum("glove", 0);
	GloveInfo g;
	if (glove != 0 && GetGloveByDef(glove, g))
	{
		g_GloveDef[client] = glove;
		g_GlovePaint[client] = g_Presets.GetNum("glove_paint", 0);
		g_GloveWear[client] = 0.0001;
		g_GloveSeed[client] = 0;
	}

	// Weapons + sticker crafts (keeps the player's StatTrak and name tags)
	if (g_Presets.JumpToKey("weapons") && g_Presets.GotoFirstSubKey())
	{
		do
		{
			g_Presets.GetSectionName(key, sizeof(key));
			int def = StringToInt(key);
			if (!GetWeaponByDef(def, w))
				continue;
			GetSkin(client, def, s);
			s.paint = g_Presets.GetNum("paint", 0);
			s.seed = g_Presets.GetNum("seed", 0);
			s.wear = 0.0001;
			g_Presets.GetString("stickers", list, sizeof(list));
			for (int i = 0; i < MAX_STICKER_SLOTS; i++)
			{
				parts[i][0] = '\0';
				s.sticker[i] = 0;
				s.stickerWear[i] = 0.0;
			}
			int n = ExplodeString(list, " ", parts, sizeof(parts), sizeof(parts[]));
			for (int i = 0; i < n && i < MAX_STICKER_SLOTS; i++)
			{
				s.sticker[i] = StringToInt(parts[i]);
				if (s.sticker[i] != 0)
					stickers = true;
			}
			g_Skins[client].SetArray(key, s, sizeof(s));
			if (count < sizeof(defs))
				defs[count++] = def;
		}
		while (g_Presets.GotoNextKey());
	}
	g_Presets.Rewind();
	SavePlayer(client);

	PrintToChat(client, "%sEquipped \x04%s\x01 — knife, gloves and %d weapon skins with sticker crafts.", PREFIX, name, count);
	if (!IsPlayerAlive(client))
		return;

	// Redraw what the player is holding now.
	int size = GetEntPropArraySize(client, Prop_Send, "m_hMyWeapons");
	int held[64], heldCount = 0;
	for (int i = 0; i < size && heldCount < sizeof(held); i++)
	{
		int wep = GetEntPropEnt(client, Prop_Send, "m_hMyWeapons", i);
		if (wep == -1 || !IsValidEntity(wep))
			continue;
		int wdef = GetEntProp(wep, Prop_Send, "m_iItemDefinitionIndex");
		if (IsKnifeDef(wdef))
			continue;
		for (int j = 0; j < count; j++)
		{
			if (defs[j] == wdef)
			{
				held[heldCount++] = wdef;
				break;
			}
		}
	}
	for (int i = 0; i < heldCount; i++)
		RefreshWeapon(client, held[i]);
	if (knife != 0)
		RefreshWeapon(client, 42);
	ApplyGloves(client, true);
	// Redraw the view: new gloves over old arms, and the new sticker crafts.
	if (glove != 0 || (stickers && heldCount > 0))
		ForceViewRefresh(client, 0.3);
	ShowPreview(client, 3.0);
}
