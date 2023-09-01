#pragma semicolon 1
#pragma newdecls required
//For Json
#pragma dynamic 8192 * 4

#include <sourcemod>
#include <discord>
#include <json>
#include <SteamWorks>

#define PLUGIN_NAME		"Cheat Control"
#define PLUGIN_AUTHOR	"Berni, dragonisser"
#define PLUGIN_DESC		"Allows admins to use cheat commands, cheat impulses and cheat cvars, and blocks them for none admins"
#define PLUGIN_VERSION 	"1.6"
#define PLUGIN_URL		"http://forums.alliedmods.net/showthread.php?p=600521"
#define PLUGIN_PREFIX	"[CC]"


/*****************************************************************


					P L U G I N   I N F O


*****************************************************************/

public Plugin myinfo = 
{
  name = PLUGIN_NAME,
  author = PLUGIN_AUTHOR,
  description = PLUGIN_DESC,
  version = PLUGIN_VERSION,
  url = PLUGIN_URL
};



/*****************************************************************


					G L O B A L   V A R S


*****************************************************************/

// ConVar Handles
Handle sv_cheats;
Handle cheatcontrol_version;
Handle cheatcontrol_adminsonly;
Handle cheatcontrol_enablewarnings;
Handle cheatcontrol_maxwarnings;
Handle cheatcontrol_printtoadmins;
Handle cheatcontrol_stripnotifyflag;
Handle cheatcontrol_printtodiscord;

// Others
int playerWarnings[MAXPLAYERS];
bool bDiscordAvailable;
char hostipandport[24];
Handle adt_allowedCommands;
Handle adt_allowedImpulses;

int cheatImpulses[] = {
	50, 51, 52, 76, 81, 82, 83, 101, 102, 103, 106, 107, 108, 195, 196, 197, 200, 202, 203
};

enum MessageType {
	DETECTION = 1,
	KICKED = 2
};



/*****************************************************************


				F O R W A R D   P U B L I C S


*****************************************************************/

public void OnPluginStart() {
	
	// ConVars
	cheatcontrol_version = CreateConVar("cheatcontrol_version", PLUGIN_VERSION, "Cheatcontrol plugin version", FCVAR_DONTRECORD|FCVAR_NOTIFY);
	// Set it to the correct version, in case the plugin gets updated...
	SetConVarString(cheatcontrol_version, PLUGIN_VERSION);

	cheatcontrol_adminsonly			= CreateConVar("cheatcontrol_enable",			"1", 	"Enable/disable this plugin (disabling it enables usage of cheats for everyone)");
	cheatcontrol_enablewarnings		= CreateConVar("cheatcontrol_enablewarnings",	"1",	"Enable the cheatcontrol warning system"										);
	cheatcontrol_maxwarnings		= CreateConVar("cheatcontrol_maxwarnings",		"5",	"Max warnings a player gets after he will be kicked"							);
	cheatcontrol_printtoadmins		= CreateConVar("cheatcontrol_printtoadmins",	"0",	"Set if to forward warning messages to admins or not"							);
	cheatcontrol_stripnotifyflag	= CreateConVar("cheatcontrol_stripnotifyflag",	"1",	"Sets if to strip the notification flag from sv_cheats or not"					);
	cheatcontrol_printtodiscord 	= CreateConVar("cheatcontrol_printtodiscord",	"1",	"Set if to forward warning messages to discord webhook"							);


	// We need to hook this one cvar to react on changes
	HookConVarChange(cheatcontrol_adminsonly, OnConVarChanged_CheatsAdmOnly);
	
	sv_cheats = FindConVar("sv_cheats");
	HookConVarChange(sv_cheats, OnConVarChanged_SvCheats);
	
	// Auto generate config file
	AutoExecConfig();
	
	// Admin Commands
	RegAdminCmd("sm_allowcheatcommand",			Command_AllowCheatCommand,			ADMFLAG_CHEATS,	"Allows a specific cheat comamnd for usage by none-admins");
	RegAdminCmd("sm_disallowcheatcommand",		Command_DisallowCheatCommand,		ADMFLAG_CHEATS,	"Disallows a specific cheat comamnd for usage by none-admins", "");
	RegAdminCmd("sm_cheatcontrol_reloadcfg",	Command_ReloadCfg,					ADMFLAG_CHEATS,	"Reloads the cheat-control config file(s)", "");
	
	
	if (GetConVarBool(cheatcontrol_stripnotifyflag)) {
		// Stripping the nofity flag off sv_cheats
		int cvarCheatsflags = GetConVarFlags(sv_cheats);
		cvarCheatsflags &= ~FCVAR_NOTIFY;
		SetConVarFlags(sv_cheats, cvarCheatsflags);
	}
	
	UpdateClientCheatValue();
	HookCheatCommands();

	adt_allowedCommands = CreateArray(64);
	adt_allowedImpulses = CreateArray();

	if (GetFeatureStatus(FeatureType_Native, "Discord_SendMessage") == FeatureStatus_Available)
	{
		LogMessage("Detected Discord.smx on startup");
		bDiscordAvailable = true;
	}

	char hostport[8];
	GetConVarString(FindConVar("hostport"), hostport, sizeof(hostport));

	int sw_ip[4];
	SteamWorks_GetPublicIP(sw_ip);
	Format(hostipandport, sizeof(hostipandport), "%i.%i.%i.%i:%s", sw_ip[0], sw_ip[1], sw_ip[2], sw_ip[3], hostport);
}

public void OnConfigsExecuted() {
	ReadAllowedCommands();
}

public void OnRebuildAdminCache(AdminCachePart part) {
	UpdateClientCheatValue();
}

public void OnClientPutInServer(int client) {
	// Don't send the value to fake clients
	if (IsFakeClient(client)) {
		return;
	}

	if (GetConVarBool(sv_cheats) && GetConVarBool(cheatcontrol_adminsonly)) {
		SendConVarValue(client, sv_cheats, "0");
	}
}

public void OnClientPostAdminCheck(int client) {
	// Don't send the value to fake clients
	if (IsFakeClient(client)) {
		return;
	}

	if (CanClientCheat(client) || !GetConVarBool(cheatcontrol_adminsonly)) {
		SendConVarValue(client, sv_cheats, "1");
	}
}

public Action OnCheatCommand(int client, const char[] command, int argc) {
	
	if (CanClientCheat(client)) {	
		return Plugin_Continue;
	}
	
	char buf[64];
	int size = GetArraySize(adt_allowedCommands);
	for (int i = 0; i < size; ++i) {
		GetArrayString(adt_allowedCommands, i, buf, sizeof(buf));
		
		if (StrEqual(buf, command, false)) {
			return Plugin_Continue;
		}
	}
	
	int maxWarnings = GetConVarInt(cheatcontrol_maxwarnings);

	if (GetConVarBool(cheatcontrol_enablewarnings)) {
		playerWarnings[client]++;

		if (playerWarnings[client] >= maxWarnings) {
			playerWarnings[client] = maxWarnings;
			KickClient(client, "[Cheat-Control] Permission denied to command %s - max. number of warnings reached", command);
			if (GetConVarBool(cheatcontrol_printtodiscord)) {
				CheatControlNotify(client, KICKED, "%N tried to execute cheat-command: '%s' - max. number of warnings reached - Kicked", client, command, playerWarnings[client], maxWarnings);
			}
			return Plugin_Handled;
		} else {
			PrintToChat(client,"\x04[Cheat-Control] \x01Permission denied to command %s - \x04%d\x01/\x04%d \x01warnings", command, playerWarnings[client], maxWarnings);
			
			if (GetConVarBool(cheatcontrol_printtodiscord)) {
				CheatControlNotify(client, DETECTION, "%N tried to execute cheat-command: '%s' - %i/%i warnings", client, command, playerWarnings[client], maxWarnings);
			}

			if (GetConVarBool(cheatcontrol_printtoadmins)) {
				PrintToChatAdmins("\x04[Cheat-Control] \x01Player %N tried to execute cheat-command: %s - \x04%d\x01/\x04%d \x01warnings", client, command, playerWarnings[client], maxWarnings);
			}
		}
	}
	return Plugin_Handled;
}

public Action OnPlayerRunCmd(int client, int& buttons, int& impulse, float vel[3], float angles[3], int& weapon) {

	if (!CanClientUseImpulse(client, impulse)) {
		impulse = 0;
		return Plugin_Changed;
	}

	return Plugin_Continue;
}

/****************************************************************


			C A L L B A C K   F U N C T I O N S


****************************************************************/

public void OnConVarChanged_CheatsAdmOnly(Handle convar, const char[] oldValue, const char[] newValue) {
	UpdateClientCheatValue();
}

public void OnConVarChanged_SvCheats(Handle convar, const char[] oldValue, const char[] newValue) {
	UpdateClientCheatValue();
}

public Action Command_AllowCheatCommand(int client, int args) {
	if (args == 1) {

		char arg1[32];
		char toks[2][32];
		
		GetCmdArg(1, arg1, sizeof(arg1));
		
		ExplodeString(arg1, " ", toks, 2, sizeof(toks[]));
		if (strcmp(toks[0], "impulse", false) == 0) {
			
			int impulse = StringToInt(toks[1]);
			
			int size = GetArraySize(adt_allowedImpulses);
			for (int i = 0; i < size; ++i) {
				if (impulse == GetArrayCell(adt_allowedImpulses, i)) {
					ReplyToCommand(client, "\x04[Cheat-Control] \x01Impulse %d is already allowed !", impulse);
					return Plugin_Handled;
				}
			}
			
			PushArrayCell(adt_allowedImpulses, impulse);
			ReplyToCommand(client, "\x04[Cheat-Control] \x01Impulse %d has been allowed !", impulse);
		}
		else {
			char buf[64];
			int size = GetArraySize(adt_allowedCommands);
			for (int i = 0; i < size; ++i) {
				GetArrayString(adt_allowedCommands,i, buf, sizeof(buf));
				
				if (StrEqual(buf, arg1, false)) {
					ReplyToCommand(client, "\x04[Cheat-Control] \x01Command %s is already allowed !", arg1);
					return Plugin_Handled;
				}
			}
			
			PushArrayString(adt_allowedCommands, arg1);
			ReplyToCommand(client, "\x04[Cheat-Control] \x01Command %s has been allowed !", arg1);
		}
	}
	else {
		char arg0[32];
		GetCmdArg(0, arg0, 32);
		ReplyToCommand(client, "\x04[Cheat-Control] \x01 Usage: %s <command>", arg0);
	}
	
	return Plugin_Handled;
}

public Action Command_DisallowCheatCommand(int client, int args) {
	if (args == 1) {

		char arg1[32]; 
		char toks[2][32];
		
		GetCmdArg(1, arg1, sizeof(arg1));
		ExplodeString(arg1, " ", toks, 2, sizeof(toks[]));
		
		if (strcmp(toks[0], "impulse", false) == 0) {
			
			int impulse = StringToInt(toks[1]);
			
			int size = GetArraySize(adt_allowedImpulses);
			for (int i = 0; i < size; ++i) {
				if (impulse == GetArrayCell(adt_allowedImpulses, i)) {
					RemoveFromArray(adt_allowedImpulses, i);
					ReplyToCommand(client, "\x04[Cheat-Control] \x01Impulse %d has been disallowed !", impulse);
					
					return Plugin_Handled;
				}
			}
			
			ReplyToCommand(client, "\x04[Cheat-Control] \x01Impulse %d is not in the list of allowed impulses !", impulse);
		}
		else {			
			char buf[64];
			int size = GetArraySize(adt_allowedCommands);
			for (int i = 0; i < size; ++i) {
				GetArrayString(adt_allowedCommands,i, buf, sizeof(buf));
				
				if (StrEqual(buf, arg1, false)) {
					RemoveFromArray(adt_allowedCommands, i);
					ReplyToCommand(client, "\x04[Cheat-Control] \x01Command %s has been disallowed !", arg1);
					
					return Plugin_Handled;
				}
			}
			
			ReplyToCommand(client, "\x04[Cheat-Control] \x01Command %s is not in the list of allowed commands !", arg1);
		}
	}
	else {
		char arg0[32];
		GetCmdArg(0, arg0, 32);
		ReplyToCommand(client, "\x04[Cheat-Control] \x01Usage: %s <command>", arg0);
	}
	
	return Plugin_Handled;
}

public Action Command_ReloadCfg(int client, int args) {
	if (ReadAllowedCommands()) {
		ReplyToCommand(client, "The \x04[Cheat-Control] \x01config files have been reloaded !");
	}
	else {
		ReplyToCommand(client, "Unable to reload the \x04[Cheat-Control] \x01config file !");
	}
	return Plugin_Handled;
}

/*****************************************************************


				P L U G I N   F U N C T I O N S


*****************************************************************/

bool IsCheatImpulse(int impulse) {
	
	for (int i = 0; i < sizeof(cheatImpulses); i++) {
		
		if (cheatImpulses[i] == impulse) {
			
			return true;
		}
	}
	
	return false;
}

bool CanClientUseImpulse(int client, int impulse) {
	
	bool isCheat = IsCheatImpulse(impulse);
	
	if (!isCheat) {
		return true;
	}
	
	if (CanClientCheat(client)) {
		return true;
	}
	
	// 	Artifact of hl2 sp
	if (impulse == 50) {
		return false;
	}
	
	int size = GetArraySize(adt_allowedImpulses);
	for (int i = 0; i < size; ++i) {
		if (impulse == GetArrayCell(adt_allowedImpulses, i)) {
			return true;
		}
	}
	
	int maxWarnings = GetConVarInt(cheatcontrol_maxwarnings);
	
	if (GetConVarBool(cheatcontrol_enablewarnings)) {
		playerWarnings[client]++;
		if (playerWarnings[client] >= maxWarnings) {
			playerWarnings[client] = maxWarnings;
			KickClient(client, "[Cheat-Control] Permission denied to impulse %d - max. number of warnings reached", impulse);
			if (GetConVarBool(cheatcontrol_printtoadmins)) {
				CheatControlNotify(client, KICKED, "%N tried to execute cheat-impulse: '%d' - max. number of warnings reached - Kicked", client, impulse);
			}
			return false;
		} else {
			PrintToChat(client,"\x04[Cheat-Control] \x01Permission denied to impulse %d - \x04%d\x01/\x04%d \x01warnings", impulse, playerWarnings[client], maxWarnings);
			
			if (GetConVarBool(cheatcontrol_printtodiscord)) {
				CheatControlNotify(client, DETECTION, "%N tried to execute cheat-impulse: '%d' - %i/%i warnings", client, impulse, playerWarnings[client], maxWarnings);
			}

			if (GetConVarBool(cheatcontrol_printtoadmins)) {
				PrintToChatAdmins("\x04[Cheat-Control] \x01Player %N tried to execute cheat-impulse: %d - \x04%d\x01/\x04%d \x01warnings", client, impulse, playerWarnings[client], maxWarnings);
			}
		}
	}
	

	
	return false;
}


// Wrapper function for easier handling of console and fake clients
bool HasAccess(int client, AdminFlag flag=Admin_Generic) {
	if (client == 0 || IsFakeClient(client)) {
		return true;
	}
	
	AdminId aid = GetUserAdmin(client);
	if (aid != INVALID_ADMIN_ID && GetAdminFlag(aid, flag)) {
		return true;
	}
	
	return false;
}

bool CanClientCheat(int client) {
	if (!GetConVarBool(cheatcontrol_adminsonly)) {
		return true;
	}
	
	if (HasAccess(client, Admin_Cheats)) {
		return true;
	}
	
	return false;
}

void HookCheatCommands() {
	
	char name[64];
	Handle cvar;
	bool isCommand;
	int flags;
	
	cvar = FindFirstConCommand(name, sizeof(name), isCommand, flags);
	if (cvar ==INVALID_HANDLE) {
		SetFailState("Could not load cvar list");
	}
	
	do {
		if (!isCommand || !(flags & FCVAR_CHEAT)) {
			continue;
		}
		
		AddCommandListener(OnCheatCommand, name);
		
	} while (FindNextConCommand(cvar, name, sizeof(name), isCommand, flags));
	
	CloseHandle(cvar);


	
	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), "configs/cheat-control/block-commands.ini");
	
	Handle file = OpenFile(path, "r");
	
	if (file == INVALID_HANDLE) {
		return;
	}
	
	char line[1024];
	
	while (!IsEndOfFile(file)) {
		if (!ReadFileLine(file, line, sizeof(line))) {
			break;
		}
		
		ReplaceString(line, sizeof(line), "\r", "");
		ReplaceString(line, sizeof(line), "\n", "");
		
		int pos;
		if ((pos = StrContains(line, "//")) != -1) {
			line[pos] = '\0';
		}
		
		TrimString(line);
		
		if (StrEqual(line, "") || StrEqual(line, "\n") || StrEqual(line, "\r\n") || strncmp(line, "//", 2) == 0) {
			continue;
		}
		
		AddCommandListener(OnCheatCommand, line);
	}
	
	CloseHandle(file);
}

bool ReadAllowedCommands() {
	ClearArray(adt_allowedCommands);
	ClearArray(adt_allowedImpulses);
	
	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), "configs/cheat-control/allowed-commands.ini");
	
	Handle file = OpenFile(path, "r");
	
	if (file == INVALID_HANDLE) {
		return false;
	}
	
	char line[1024];
	char toks[2][32];
	
	while (!IsEndOfFile(file)) {

		if (!ReadFileLine(file, line, sizeof(line))) {
			break;
		}
		
		ReplaceString(line, sizeof(line), "\r", "");
		ReplaceString(line, sizeof(line), "\n", "");
		
		int pos;
		if ((pos = StrContains(line, "//")) != -1) {
			line[pos] = '\0';
		}
		
		TrimString(line);

		if (StrEqual(line, "") || StrEqual(line, "\n") || StrEqual(line, "\r\n")) {
			continue;
		}

		ExplodeString(line, " ", toks, 2, sizeof(toks[]));

		if (StrEqual(toks[0], "impulse", false)) {
			int impulse = StringToInt(toks[1]);
			PushArrayCell(adt_allowedImpulses, impulse);
		}
		else {
			PushArrayString(adt_allowedCommands, line);
		}
	}
	
	CloseHandle(file);
	
	return true;
}

void UpdateClientCheatValue() {

	char canCheat[2];

	for (int client = 1; client <= MaxClients; ++client) {
		
		if (IsClientInGame(client) && !IsFakeClient(client)) {
			IntToString(CanClientCheat(client), canCheat, sizeof(canCheat));
			SendConVarValue(client, sv_cheats, canCheat);
		}
	}
}

void PrintToChatAdmins(char[] format, any...) {
	char buffer[192];
	
	VFormat(buffer, sizeof(buffer), format, 2);
	
	for (int client = 1; client <= MaxClients; ++client) {
		
		if (IsClientInGame(client) && !IsFakeClient(client)) {
			AdminId aid = GetUserAdmin(client);
			
			if (aid != INVALID_ADMIN_ID && GetAdminFlag(aid, Admin_Generic)) {
				PrintToChat(client, buffer);
				
			}
		}
		
	}
	
	LogMessage(buffer);
}

void SendMessageToDiscord(char[] message)
{
	static char webhook[8] = "cheat-control";
	Discord_SendMessage(webhook, message);
}

//Thanks to sapphonie | StAC-tf2
//https://github.com/sapphonie/StAC-tf2/blob/master/scripting/stac/stac_stocks.sp#L682
void CheatControlNotify(int client, MessageType messageType, char[] message, any...) {

	char buffer[192];
	VFormat(buffer, sizeof(buffer), message, 4);

	if(!bDiscordAvailable) {
		LogMessage(buffer);
		return;
	}

	static char output[8192 * 2];
	output[0] = 0x0;

	JSON_Object spacerField = new JSON_Object();
	spacerField.SetString("name",   " ");
	spacerField.SetString("value",  " ");
	spacerField.SetBool  ("inline", false);

	JSON_Object spacerCpy1;
	if (client)
	{
		spacerCpy1 = spacerField.DeepCopy();
	}

	JSON_Object spacerCpy2 = spacerField.DeepCopy();
	JSON_Object spacerCpy3 = spacerField.DeepCopy();
	JSON_Object spacerCpy4 = spacerField.DeepCopy();
	JSON_Object spacerCpy5 = spacerField.DeepCopy();

	json_cleanup_and_delete(spacerField);

	JSON_Object nameField;
	JSON_Object steamIDfield;
	if (client)
	{
		char ClName[64];
		GetClientName(client, ClName, sizeof(ClName));
		Discord_EscapeString(ClName, sizeof(ClName));
		json_escape_string(ClName, sizeof(ClName));

		nameField = new JSON_Object();
		nameField.SetString("name", "Player");
		nameField.SetString("value", ClName);
		nameField.SetBool("inline", true);

		char steamid[64];
		GetClientAuthId(client, AuthId_Steam2, steamid, sizeof(steamid));

		char steamidlink[96];

		if (GetClientAuthId(client, AuthId_Steam2, steamid, sizeof(steamid)))
		{
			PrintToServer("steamid: %s", steamid);
			Format(steamidlink, sizeof(steamidlink), "[%s](https://steamid.io/lookup/%s)", steamid, steamid);
		}
		else
		{
			steamidlink = "N/A";
		}

		steamIDfield = new JSON_Object();
		steamIDfield.SetString("name", "SteamID");
		steamIDfield.SetString("value", steamidlink);
		steamIDfield.SetBool  ("inline", true);
	}

	JSON_Object detectOrMsgfield = new JSON_Object();
	switch(messageType) {
		case DETECTION:
		{
			detectOrMsgfield.SetString("name", "Detection");
		}
		case KICKED:
		{
			detectOrMsgfield.SetString("name", "Kicked");
		}
		default:
		{
			detectOrMsgfield.SetString("name", "Message");
		}
	}

	detectOrMsgfield.SetString("value", buffer);
	detectOrMsgfield.SetBool("inline", true);

	char hostname[256];
	GetConVarString(FindConVar("hostname"), hostname, sizeof(hostname));

	JSON_Object hostname_field = new JSON_Object();
	hostname_field.SetString("name", "Hostname");
	hostname_field.SetString("value", hostname);
	hostname_field.SetBool  ("inline", true);

	JSON_Object serverip_field = new JSON_Object();
	serverip_field.SetString("name", "Server IP");
	serverip_field.SetString("value", hostipandport);
	serverip_field.SetBool  ("inline", true);

	int unixTimestamp = GetTime();
	char discordTimestamp[512];

	Format
	(
		discordTimestamp,
		sizeof(discordTimestamp),
		"\
		<t:%i:T> on <t:%i:D>\n\
		<t:%i:R>\
		",
		unixTimestamp,
		unixTimestamp,
		unixTimestamp
	);

	JSON_Object discordtimestamp_field = new JSON_Object();
	discordtimestamp_field.SetString("name", "Discord Timestamp");
	discordtimestamp_field.SetString("value", discordTimestamp);
	discordtimestamp_field.SetBool  ("inline", true);

	JSON_Object unixtimestamp_field = new JSON_Object();
	unixtimestamp_field.SetString("name", "Unix Timestamp");
	unixtimestamp_field.SetInt   ("value", unixTimestamp);
	unixtimestamp_field.SetBool  ("inline", true);

	JSON_Array fieldArray = new JSON_Array();
	if (client)
	{
		fieldArray.PushObject(nameField);
		fieldArray.PushObject(steamIDfield);
		fieldArray.PushObject(spacerCpy1);
	}
	fieldArray.PushObject(detectOrMsgfield);
	fieldArray.PushObject(spacerCpy2);
	fieldArray.PushObject(hostname_field);
	fieldArray.PushObject(serverip_field);
	fieldArray.PushObject(spacerCpy3);
	fieldArray.PushObject(spacerCpy4);
	fieldArray.PushObject(spacerCpy5);
	fieldArray.PushObject(discordtimestamp_field);
	fieldArray.PushObject(unixtimestamp_field);

	JSON_Object embedsFields = new JSON_Object();

	embedsFields.SetObject("fields", fieldArray);
	char notifType[64];

	switch(messageType) {
		case DETECTION:
		{
			Format(notifType, sizeof(notifType), "Cheat-Control v%s %s", PLUGIN_VERSION, "Client Detection");
		}
		case KICKED:
		{
			Format(notifType, sizeof(notifType), "Cheat-Control v%s %s", PLUGIN_VERSION, "Client Kicked");
		}
		default:
		{
			Format(notifType, sizeof(notifType), "Cheat-Control v%s %s", PLUGIN_VERSION, "Server Message");
		}
	}

	static int color = 0xFF69B4;
	embedsFields.SetString  ("title",       notifType);
	embedsFields.SetInt     ("color",       color);

	JSON_Array finalArr = new JSON_Array();

	finalArr.PushObject(embedsFields);

	JSON_Object rootEmbeds = new JSON_Object();
	rootEmbeds.SetObject("embeds", finalArr);
	rootEmbeds.SetString("avatar_url", "");
	rootEmbeds.Encode(output, sizeof(output));

	json_cleanup_and_delete(rootEmbeds);
	PrintToServer(output);
	SendMessageToDiscord(output);

	return;
}