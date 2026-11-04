/*
 * CS:GO Retakes: round types + insta plant / insta defuse (CS:GO server pack)
 *
 * Replaces the standard allocator:
 *   - round types: pistol rounds first, then a random eco, half buy or full buy
 *   - !guns: pick your gun for each round type (CT and T), AWP on full buys
 *   - insta plant: the bomb is planted as soon as the round starts
 *   - insta defuse: once every T is dead, a defuse finishes straight away if
 *     there's enough time on the bomb - if not, the bomb goes off straight away
 *
 * GPLv3, like csgo-retakes by splewis which it plugs into.
 */
#include <sourcemod>
#include <sdktools>
#include <cstrike>
#include <clientprefs>
#include "include/retakes.inc"
bool g_PluginTeamSwitch[MAXPLAYERS+1]; // only used by a stock in generic.sp
#include "retakes/generic.sp"

#pragma semicolon 1
#pragma newdecls required

#define PACK_VERSION "1.1.0-20261104"

enum RoundType
{
    Round_Pistol = 0,
    Round_Eco,
    Round_Half,
    Round_Full
};
char g_RoundNames[4][] = { "PISTOL ROUND", "ECO ROUND", "HALF BUY", "FULL BUY" };

enum
{
    CH_FULL_CT = 0, CH_FULL_T,
    CH_HALF_CT, CH_HALF_T,
    CH_ECO_CT, CH_ECO_T,
    CH_PISTOL_CT, CH_PISTOL_T,
    CH_COUNT
};

char g_ChoiceTitle[CH_COUNT][] =
{
    "Full buy - CT rifle", "Full buy - T rifle",
    "Half buy - CT gun", "Half buy - T gun",
    "Eco - CT pistol", "Eco - T pistol",
    "Pistol round - CT pistol (also your pistol on half/full buys)",
    "Pistol round - T pistol (also your pistol on half/full buys)"
};
// "class,Label;class,Label..." - first one is the default
char g_ChoiceOptions[CH_COUNT][] =
{
    "weapon_m4a1,M4A4;weapon_m4a1_silencer,M4A1-S;weapon_aug,AUG",
    "weapon_ak47,AK-47;weapon_sg556,SG 553",
    "weapon_mp9,MP9;weapon_mp7,MP7;weapon_ump45,UMP-45;weapon_famas,FAMAS;weapon_mag7,MAG-7;weapon_ssg08,SSG 08",
    "weapon_mac10,MAC-10;weapon_mp7,MP7;weapon_ump45,UMP-45;weapon_galilar,Galil AR;weapon_sawedoff,Sawed-Off;weapon_ssg08,SSG 08",
    "weapon_fiveseven,Five-SeveN;weapon_deagle,Desert Eagle;weapon_p250,P250;weapon_cz75a,CZ75-Auto",
    "weapon_tec9,Tec-9;weapon_deagle,Desert Eagle;weapon_p250,P250;weapon_cz75a,CZ75-Auto",
    "weapon_usp_silencer,USP-S;weapon_hkp2000,P2000;weapon_p250,P250;weapon_fiveseven,Five-SeveN;weapon_deagle,Desert Eagle",
    "weapon_glock,Glock-18;weapon_p250,P250;weapon_tec9,Tec-9;weapon_deagle,Desert Eagle"
};

char g_Choice[MAXPLAYERS + 1][CH_COUNT][WEAPON_STRING_LENGTH];
bool g_Awp[MAXPLAYERS + 1];
Cookie g_ChoiceCookie[CH_COUNT];
Cookie g_AwpCookie;

ConVar g_cvPistolRounds;
ConVar g_cvEcoChance;
ConVar g_cvHalfChance;
ConVar g_cvFullChance;
ConVar g_cvInstaPlant;
ConVar g_cvInstaDefuse;

RoundType g_RoundType = Round_Pistol;
bool g_DefuseHandled = false;
bool g_ThreatWarned = false;
Handle g_DefuseWatch = null;  // re-checks while a defuse runs (e.g. fire burns out)  // said once per round why a fire/grenade blocks it

public Plugin myinfo =
{
    name = "CS:GO Retakes: round types + insta plant/defuse",
    author = "CS:GO server pack",
    description = "Pistol / eco / half buy / full buy rounds with !guns picks, insta plant and insta defuse",
    version = PACK_VERSION,
    url = "https://github.com/splewis/csgo-retakes"
};

public void OnPluginStart()
{
    char name[48];
    for (int i = 0; i < CH_COUNT; i++)
    {
        Format(name, sizeof(name), "retakes_pack_choice_%d", i);
        g_ChoiceCookie[i] = new Cookie(name, "", CookieAccess_Private);
    }
    g_AwpCookie = new Cookie("retakes_pack_awp", "", CookieAccess_Private);

    g_cvPistolRounds = CreateConVar("sm_retakes_pistol_rounds", "5", "Pistol rounds at the start of each map", _, true, 0.0);
    g_cvEcoChance    = CreateConVar("sm_retakes_eco_chance", "15", "After the pistol rounds: weight of an eco round", _, true, 0.0);
    g_cvHalfChance   = CreateConVar("sm_retakes_halfbuy_chance", "25", "After the pistol rounds: weight of a half buy round", _, true, 0.0);
    g_cvFullChance   = CreateConVar("sm_retakes_fullbuy_chance", "60", "After the pistol rounds: weight of a full buy round", _, true, 0.0);
    g_cvInstaPlant   = CreateConVar("sm_retakes_instaplant", "1", "1 = the bomb is planted as soon as the round starts", _, true, 0.0, true, 1.0);
    g_cvInstaDefuse  = CreateConVar("sm_retakes_instadefuse", "1", "1 = with every T dead, a defuse finishes at once (or the bomb goes off at once if there's no time)", _, true, 0.0, true, 1.0);
    CreateConVar("sm_retakes_pack_version", PACK_VERSION, "Retakes round types version", FCVAR_NOTIFY | FCVAR_DONTRECORD);
    AutoExecConfig(true, "retakes_pack", "sourcemod/retakes");

    HookEvent("round_freeze_end", Event_FreezeEnd);
    HookEvent("bomb_begindefuse", Event_BeginDefuse);
    HookEvent("player_death", Event_PlayerDeath);
    HookEvent("round_start", Event_RoundStart);

    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientConnected(i))
            OnClientConnected(i);
        if (IsClientInGame(i) && AreClientCookiesCached(i))
            OnClientCookiesCached(i);
    }
}

// The standard allocator would hand out guns too - switch it off for good.
public void OnAllPluginsLoaded()
{
    char path[PLATFORM_MAX_PATH], dest[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof(path), "plugins/retakes_standardallocator.smx");
    if (!FileExists(path))
        return;
    BuildPath(Path_SM, dest, sizeof(dest), "plugins/disabled/retakes_standardallocator.smx");
    if (FileExists(dest))
        DeleteFile(dest);
    if (RenameFile(dest, path))
        LogMessage("Moved retakes_standardallocator.smx to plugins/disabled (this plugin replaces it).");
    ServerCommand("sm plugins unload retakes_standardallocator");
}

public void OnClientConnected(int client)
{
    char opt[WEAPON_STRING_LENGTH];
    for (int i = 0; i < CH_COUNT; i++)
    {
        DefaultChoice(i, opt, sizeof(opt));
        strcopy(g_Choice[client][i], WEAPON_STRING_LENGTH, opt);
    }
    g_Awp[client] = false;
}

public void OnClientCookiesCached(int client)
{
    if (IsFakeClient(client))
        return;
    char value[WEAPON_STRING_LENGTH];
    for (int i = 0; i < CH_COUNT; i++)
    {
        g_ChoiceCookie[i].Get(client, value, sizeof(value));
        if (IsValidChoice(i, value))
            strcopy(g_Choice[client][i], WEAPON_STRING_LENGTH, value);
    }
    g_AwpCookie.Get(client, value, sizeof(value));
    g_Awp[client] = StrEqual(value, "1");
}

/* ---------- choices ---------- */

int GetOptions(int cat, char opts[8][2][WEAPON_STRING_LENGTH])
{
    char parts[8][64];
    int n = ExplodeString(g_ChoiceOptions[cat], ";", parts, sizeof(parts), sizeof(parts[]));
    for (int i = 0; i < n; i++)
    {
        char kv[2][WEAPON_STRING_LENGTH];
        ExplodeString(parts[i], ",", kv, sizeof(kv), sizeof(kv[]));
        strcopy(opts[i][0], WEAPON_STRING_LENGTH, kv[0]);
        strcopy(opts[i][1], WEAPON_STRING_LENGTH, kv[1]);
    }
    return n;
}

void DefaultChoice(int cat, char[] out, int maxlen)
{
    char opts[8][2][WEAPON_STRING_LENGTH];
    GetOptions(cat, opts);
    strcopy(out, maxlen, opts[0][0]);
}

bool IsValidChoice(int cat, const char[] value)
{
    if (value[0] == '\0')
        return false;
    char opts[8][2][WEAPON_STRING_LENGTH];
    int n = GetOptions(cat, opts);
    for (int i = 0; i < n; i++)
    {
        if (StrEqual(opts[i][0], value))
            return true;
    }
    return false;
}

void ChoiceLabel(int cat, const char[] value, char[] out, int maxlen)
{
    char opts[8][2][WEAPON_STRING_LENGTH];
    int n = GetOptions(cat, opts);
    for (int i = 0; i < n; i++)
    {
        if (StrEqual(opts[i][0], value))
        {
            strcopy(out, maxlen, opts[i][1]);
            return;
        }
    }
    strcopy(out, maxlen, value);
}

/* ---------- !guns ---------- */

public void Retakes_OnGunsCommand(int client)
{
    ShowGunsMenu(client);
}

void ShowGunsMenu(int client)
{
    char line[128], ct[32], t[32];
    Menu menu = new Menu(Handler_Guns);
    menu.SetTitle("Retakes guns\nRound types: pistol, eco, half buy, full buy");
    char names[4][] = { "Full buy", "Half buy", "Eco", "Pistol round" };
    for (int r = 0; r < 4; r++)
    {
        int catCT = r * 2, catT = r * 2 + 1;
        ChoiceLabel(catCT, g_Choice[client][catCT], ct, sizeof(ct));
        ChoiceLabel(catT, g_Choice[client][catT], t, sizeof(t));
        Format(line, sizeof(line), "%s - CT: %s / T: %s", names[r], ct, t);
        char info[4];
        IntToString(catCT, info, sizeof(info));
        menu.AddItem(info, line);
    }
    Format(line, sizeof(line), "AWP on full buys: %s", g_Awp[client] ? "Yes" : "No");
    menu.AddItem("awp", line);
    menu.Display(client, MENU_TIME_FOREVER);
}

public int Handler_Guns(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_End)
    {
        delete menu;
    }
    else if (action == MenuAction_Select)
    {
        char info[8];
        menu.GetItem(item, info, sizeof(info));
        if (StrEqual(info, "awp"))
        {
            g_Awp[client] = !g_Awp[client];
            g_AwpCookie.Set(client, g_Awp[client] ? "1" : "0");
            ShowGunsMenu(client);
            return 0;
        }
        ShowChoiceMenu(client, StringToInt(info));
    }
    return 0;
}

void ShowChoiceMenu(int client, int cat)
{
    char opts[8][2][WEAPON_STRING_LENGTH], info[48], line[64];
    int n = GetOptions(cat, opts);
    Menu menu = new Menu(Handler_Choice);
    menu.SetTitle("%s", g_ChoiceTitle[cat]);
    for (int i = 0; i < n; i++)
    {
        Format(info, sizeof(info), "%d:%s", cat, opts[i][0]);
        if (StrEqual(g_Choice[client][cat], opts[i][0]))
            Format(line, sizeof(line), "%s [current]", opts[i][1]);
        else
            strcopy(line, sizeof(line), opts[i][1]);
        menu.AddItem(info, line);
    }
    menu.ExitBackButton = true;
    menu.Display(client, MENU_TIME_FOREVER);
}

public int Handler_Choice(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_End)
    {
        delete menu;
    }
    else if (action == MenuAction_Cancel && item == MenuCancel_ExitBack)
    {
        ShowGunsMenu(client);
    }
    else if (action == MenuAction_Select)
    {
        char info[48];
        menu.GetItem(item, info, sizeof(info));
        int colon = FindCharInString(info, ':');
        if (colon == -1)
            return 0;
        info[colon] = '\0';
        int cat = StringToInt(info);
        if (cat < 0 || cat >= CH_COUNT || !IsValidChoice(cat, info[colon + 1]))
            return 0;
        strcopy(g_Choice[client][cat], WEAPON_STRING_LENGTH, info[colon + 1]);
        g_ChoiceCookie[cat].Set(client, info[colon + 1]);
        // CT pick -> T pick of the same round type, then back to the overview.
        if (cat % 2 == 0)
            ShowChoiceMenu(client, cat + 1);
        else
            ShowGunsMenu(client);
    }
    return 0;
}

/* ---------- round types and allocation ---------- */

RoundType PickRoundType()
{
    if (Retakes_GetRetakeRoundsPlayed() < g_cvPistolRounds.IntValue)
        return Round_Pistol;
    int eco = g_cvEcoChance.IntValue, half = g_cvHalfChance.IntValue, full = g_cvFullChance.IntValue;
    int total = eco + half + full;
    if (total <= 0)
        return Round_Full;
    int r = GetRandomInt(1, total);
    if (r <= eco)
        return Round_Eco;
    if (r <= eco + half)
        return Round_Half;
    return Round_Full;
}

// count random grenades from the team's pool (no duplicates)
void RandomNades(int team, int count, char nades[NADE_STRING_LENGTH])
{
    char pool[8];
    strcopy(pool, sizeof(pool), team == CS_TEAM_T ? "sfhm" : "sfhi");
    nades[0] = '\0';
    int len = strlen(pool);
    for (int i = 0; i < count && len > 0; i++)
    {
        int r = GetRandomInt(0, len - 1);
        int n = strlen(nades);
        nades[n] = pool[r];
        nades[n + 1] = '\0';
        for (int j = r; j < len; j++)
            pool[j] = pool[j + 1];
        len--;
    }
}

public void Retakes_OnWeaponsAllocated(ArrayList tPlayers, ArrayList ctPlayers, Bombsite bombsite)
{
    g_RoundType = PickRoundType();
    AllocateTeam(tPlayers, CS_TEAM_T);
    AllocateTeam(ctPlayers, CS_TEAM_CT);
    CreateTimer(0.5, Timer_AnnounceRound, _, TIMER_FLAG_NO_MAPCHANGE);
}

void AllocateTeam(ArrayList players, int team)
{
    bool isT = team == CS_TEAM_T;
    int off = isT ? 1 : 0;

    // One AWP per team on full buys, for a random player who wants one.
    int awper = -1;
    if (g_RoundType == Round_Full)
    {
        ArrayList want = new ArrayList();
        for (int i = 0; i < players.Length; i++)
        {
            int c = players.Get(i);
            if (g_Awp[c])
                want.Push(c);
        }
        if (want.Length > 0)
            awper = want.Get(GetRandomInt(0, want.Length - 1));
        delete want;
    }

    char primary[WEAPON_STRING_LENGTH], secondary[WEAPON_STRING_LENGTH], nades[NADE_STRING_LENGTH];
    for (int i = 0; i < players.Length; i++)
    {
        int client = players.Get(i);
        int kevlar = 100;
        bool helmet = true;
        bool kit = !isT;
        primary[0] = '\0';
        strcopy(secondary, sizeof(secondary), g_Choice[client][CH_PISTOL_CT + off]);

        switch (g_RoundType)
        {
            case Round_Pistol:
            {
                helmet = false;
                RandomNades(team, GetRandomInt(0, 1), nades);
            }
            case Round_Eco:
            {
                strcopy(secondary, sizeof(secondary), g_Choice[client][CH_ECO_CT + off]);
                helmet = false;
                RandomNades(team, 1, nades);
            }
            case Round_Half:
            {
                strcopy(primary, sizeof(primary), g_Choice[client][CH_HALF_CT + off]);
                RandomNades(team, GetRandomInt(1, 2), nades);
            }
            case Round_Full:
            {
                if (client == awper)
                    strcopy(primary, sizeof(primary), "weapon_awp");
                else
                    strcopy(primary, sizeof(primary), g_Choice[client][CH_FULL_CT + off]);
                RandomNades(team, 2, nades);
            }
        }
        Retakes_SetPlayerInfo(client, primary, secondary, nades, 100, kevlar, helmet, kit);
    }
}

public Action Timer_AnnounceRound(Handle timer)
{
    if (!Retakes_Enabled())
        return Plugin_Stop;
    int played = Retakes_GetRetakeRoundsPlayed();
    if (g_RoundType == Round_Pistol && g_cvPistolRounds.IntValue > 0)
        Retakes_MessageToAll("{GREEN}%s{NORMAL} (%d of %d) - type {GREEN}!guns{NORMAL} to pick your weapons.", g_RoundNames[g_RoundType], played + 1, g_cvPistolRounds.IntValue);
    else
        Retakes_MessageToAll("{GREEN}%s{NORMAL} - type {GREEN}!guns{NORMAL} to pick your weapons.", g_RoundNames[g_RoundType]);
    PrintCenterTextAll("%s", g_RoundNames[g_RoundType]);
    return Plugin_Stop;
}

/* ---------- insta plant ---------- */

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    g_DefuseHandled = false;
    g_ThreatWarned = false;
}

public void Event_FreezeEnd(Event event, const char[] name, bool dontBroadcast)
{
    if (g_cvInstaPlant.BoolValue && Retakes_Live())
        CreateTimer(0.1, Timer_InstaPlant, _, TIMER_FLAG_NO_MAPCHANGE);
}

int FindBomber(int &c4)
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || !IsPlayerAlive(i) || GetClientTeam(i) != CS_TEAM_T)
            continue;
        int w = GetPlayerWeaponSlot(i, 4);
        if (w == -1)
            continue;
        char cls[32];
        GetEntityClassname(w, cls, sizeof(cls));
        if (StrEqual(cls, "weapon_c4"))
        {
            c4 = w;
            return i;
        }
    }
    return -1;
}

public Action Timer_InstaPlant(Handle timer)
{
    if (!Retakes_Live() || FindEntityByClassname(-1, "planted_c4") != -1)
        return Plugin_Stop;
    int c4 = -1;
    int bomber = FindBomber(c4);
    if (bomber == -1)
        return Plugin_Stop;

    float pos[3];
    GetClientAbsOrigin(bomber, pos);
    RemovePlayerItem(bomber, c4);
    AcceptEntityInput(c4, "Kill");

    int bomb = CreateEntityByName("planted_c4");
    if (bomb == -1)
        return Plugin_Stop;
    ConVar cvTimer = FindConVar("mp_c4timer");
    float length = cvTimer != null ? cvTimer.FloatValue : 40.0;

    DispatchSpawn(bomb);
    ActivateEntity(bomb);
    TeleportEntity(bomb, pos, NULL_VECTOR, NULL_VECTOR);
    SetEntProp(bomb, Prop_Send, "m_bBombTicking", 1);
    SetEntProp(bomb, Prop_Send, "m_nBombSite", view_as<int>(Retakes_GetCurrrentBombsite()));
    SetEntPropFloat(bomb, Prop_Send, "m_flTimerLength", length);
    SetEntPropFloat(bomb, Prop_Send, "m_flC4Blow", GetGameTime() + length);
    GameRules_SetProp("m_bBombPlanted", 1);

    Event ev = CreateEvent("bomb_planted");
    if (ev != null)
    {
        ev.SetInt("userid", GetClientUserId(bomber));
        ev.SetInt("site", view_as<int>(Retakes_GetCurrrentBombsite()));
        ev.Fire();
    }
    return Plugin_Stop;
}

/* ---------- insta defuse ---------- */

public void Event_BeginDefuse(Event event, const char[] name, bool dontBroadcast)
{
    if (!Retakes_Enabled())
        return;
    if (!g_cvInstaDefuse.BoolValue)
    {
        Retakes_MessageToAll("Insta defuse is turned off on this server (sm_retakes_instadefuse 0).");
        return;
    }
    // The game sets the defuse countdown after this event: act a moment later.
    // 1 = say in chat why it doesn't happen.
    CreateTimer(0.1, Timer_CheckDefuse, 1, TIMER_FLAG_NO_MAPCHANGE);
    if (g_DefuseWatch == null)
        g_DefuseWatch = CreateTimer(0.5, Timer_DefuseWatch, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_DefuseWatch(Handle timer)
{
    int bomb = FindEntityByClassname(-1, "planted_c4");
    int defuser = bomb != -1 ? GetEntPropEnt(bomb, Prop_Send, "m_hBombDefuser") : -1;
    if (g_DefuseHandled || bomb == -1 || defuser <= 0)
    {
        g_DefuseWatch = null;
        return Plugin_Stop;
    }
    Timer_CheckDefuse(null, 0);
    return Plugin_Continue;
}

public void OnMapEnd()
{
    g_DefuseWatch = null; // TIMER_FLAG_NO_MAPCHANGE kills it
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_cvInstaDefuse.BoolValue || !Retakes_Enabled())
        return;
    // The last T just died while a CT was already defusing (quiet re-check).
    CreateTimer(0.1, Timer_CheckDefuse, 0, TIMER_FLAG_NO_MAPCHANGE);
}

int AliveCount(int team)
{
    int n = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && IsPlayerAlive(i) && GetClientTeam(i) == team)
            n++;
    }
    return n;
}

// Is this fire / grenade a T's? (Friendly fire is off in retakes, so a CT's
// own molotov or HE can't hurt the defuser.)
bool ThrownByT(int ent, const char[] prop)
{
    if (!HasEntProp(ent, Prop_Send, prop))
        return true;
    int owner = GetEntPropEnt(ent, Prop_Send, prop);
    if (owner <= 0 || owner > MaxClients || !IsClientInGame(owner))
        return true; // owner left: can't tell, play safe
    return GetClientTeam(owner) == CS_TEAM_T;
}

// A T's fire near the bomb, or a T's grenade still in the air, could still
// kill the defuser. Says which in what[].
bool ThreatLeft(int bomb, char[] what, int maxlen)
{
    float bombPos[3], pos[3];
    GetEntPropVector(bomb, Prop_Send, "m_vecOrigin", bombPos);
    int ent = -1;
    while ((ent = FindEntityByClassname(ent, "inferno")) != -1)
    {
        GetEntPropVector(ent, Prop_Send, "m_vecOrigin", pos);
        if (GetVectorDistance(pos, bombPos) <= 450.0 && ThrownByT(ent, "m_hOwnerEntity"))
        {
            strcopy(what, maxlen, "a T's molotov is still burning near the bomb");
            return true;
        }
    }
    char projectiles[][] = { "molotov_projectile", "hegrenade_projectile" };
    for (int i = 0; i < sizeof(projectiles); i++)
    {
        ent = -1;
        while ((ent = FindEntityByClassname(ent, projectiles[i])) != -1)
        {
            if (ThrownByT(ent, "m_hThrower"))
            {
                strcopy(what, maxlen, i == 0 ? "a T's molotov is still in the air" : "a T's grenade is still in the air");
                return true;
            }
        }
    }
    return false;
}

public Action Timer_CheckDefuse(Handle timer, any explain)
{
    if (g_DefuseHandled)
        return Plugin_Stop;
    if (!Retakes_Live())
    {
        if (explain)
            Retakes_MessageToAll("No insta defuse: it only works in live retake rounds (not in warmup or the spawn editor).");
        return Plugin_Stop;
    }
    int bomb = FindEntityByClassname(-1, "planted_c4");
    if (bomb == -1 || !GetEntProp(bomb, Prop_Send, "m_bBombTicking"))
    {
        if (explain)
            Retakes_MessageToAll("No insta defuse: couldn't find a ticking bomb.");
        return Plugin_Stop;
    }
    int defuser = GetEntPropEnt(bomb, Prop_Send, "m_hBombDefuser");
    if (defuser <= 0 || defuser > MaxClients || !IsClientInGame(defuser) || !IsPlayerAlive(defuser))
        return Plugin_Stop; // stopped defusing already
    int ts = AliveCount(CS_TEAM_T);
    if (ts > 0)
    {
        if (explain)
            Retakes_MessageToAll("No insta defuse yet: {LIGHT_RED}%d T%s still alive{NORMAL}. It happens as soon as the last one dies.", ts, ts == 1 ? " is" : "s are");
        return Plugin_Stop;
    }
    char what[64];
    if (ThreatLeft(bomb, what, sizeof(what)))
    {
        // All Ts are dead here: say it even on the quiet re-check, once a round.
        if (explain || !g_ThreatWarned)
            Retakes_MessageToAll("No insta defuse: %s - defusing normally.", what);
        g_ThreatWarned = true;
        return Plugin_Stop;
    }

    float left = GetEntPropFloat(bomb, Prop_Send, "m_flC4Blow") - GetGameTime();
    float need = GetEntProp(defuser, Prop_Send, "m_bHasDefuser") ? 5.0 : 10.0;
    g_DefuseHandled = true;
    if (left >= need)
    {
        SetEntPropFloat(bomb, Prop_Send, "m_flDefuseCountDown", GetGameTime());
        Retakes_MessageToAll("{GREEN}%N{NORMAL} defused the bomb with {GREEN}%.1f s{NORMAL} to spare.", defuser, left);
    }
    else
    {
        SetEntPropFloat(bomb, Prop_Send, "m_flC4Blow", GetGameTime());
        Retakes_MessageToAll("Not enough time to defuse ({LIGHT_RED}%.1f s{NORMAL} left, needed %.0f s) - the bomb goes off.", left, need);
    }
    return Plugin_Stop;
}
