#include <sdktools>
#include <dhooks>

#pragma semicolon 1
#pragma newdecls required

public Plugin myinfo =
{
	name = "No-Jump Boost Fix",
	author = "rio",
	description = "Changes StepMove behavior that generates free Z velocity when moving up an incline",
	version = "1.0.0",
	url = "https://github.com/jason-e/no-jump-boost-fix"
};

float NON_JUMP_VELOCITY;

int MOVEDATA_VELOCITY;
int MOVEDATA_OUTSTEPHEIGHT;
int MOVEDATA_ORIGIN;

ConVar g_cvEnabled;

Handle g_hTryPlayerMoveHookPost;

Handle g_hStepMoveHookPre;
Handle g_hStepMoveHookPost;

Address g_pGameMovement;

// StepMove call state
Address g_mv;

bool g_bInStepMove = false;
int g_iTPMCalls = 0;

float g_vecStartPos[3];
float g_flStartStepHeight;

float g_vecDownPos[3];
float g_vecDownVel[3];

float g_vecUpVel[3];

public void OnPluginStart()
{
	g_cvEnabled = CreateConVar("nojump_boost_fix", "1", "Enable NoJump Boost Fix.", FCVAR_NOTIFY, true, 0.0, true, 1.0);

	AutoExecConfig();

	Handle gc = LoadGameConfigFile("nojumpboostfix.games");
	if (gc == null)
	{
		SetFailState("Failed to load nojumpboostfix gamedata");
	}

	char njv[16];
	if (!GameConfGetKeyValue(gc, "NON_JUMP_VELOCITY", njv, sizeof(njv)))
	{
		SetFailState("Failed to get NON_JUMP_VELOCITY");
	}
	NON_JUMP_VELOCITY		 = StringToFloat(njv);

	MOVEDATA_VELOCITY 		 = GetRequiredOffset(gc, "CMoveData::m_vecVelocity");
	MOVEDATA_OUTSTEPHEIGHT 	 = GetRequiredOffset(gc, "CMoveData::m_outStepHeight");
	MOVEDATA_ORIGIN 		 = GetRequiredOffset(gc, "CMoveData::m_vecAbsOrigin");

	StartPrepSDKCall(SDKCall_Static);
	if (!PrepSDKCall_SetFromConf(gc, SDKConf_Signature, "CreateInterface"))
	{
		SetFailState("Failed to get CreateInterface signature");
	}
	PrepSDKCall_AddParameter(SDKType_String, SDKPass_Pointer);
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Pointer, VDECODE_FLAG_ALLOWNULL);
	PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
	Handle CreateInterface = EndPrepSDKCall();
	if (CreateInterface == null)
	{
		SetFailState("Unable to prepare SDKCall for CreateInterface");
	}

	g_pGameMovement = SDKCall(CreateInterface, "GameMovement001", 0);
	if (!g_pGameMovement)
	{
		SetFailState("Failed to get IGameMovement singleton pointer");
	}

	int offset = GetRequiredOffset(gc, "CGameMovement::TryPlayerMove");
	g_hTryPlayerMoveHookPost = DHookCreate(offset, HookType_Raw, ReturnType_Int, ThisPointer_Ignore, DHook_TryPlayerMovePost);
	DHookAddParam(g_hTryPlayerMoveHookPost, HookParamType_VectorPtr);
	DHookAddParam(g_hTryPlayerMoveHookPost, HookParamType_ObjectPtr);
	DHookRaw(g_hTryPlayerMoveHookPost, true, g_pGameMovement);

	offset = GetRequiredOffset(gc, "CGameMovement::StepMove");
	g_hStepMoveHookPre = DHookCreate(offset, HookType_Raw, ReturnType_Void, ThisPointer_Ignore, DHook_StepMovePre);
	DHookAddParam(g_hStepMoveHookPre, HookParamType_VectorPtr);
	DHookAddParam(g_hStepMoveHookPre, HookParamType_ObjectPtr);
	DHookRaw(g_hStepMoveHookPre, false, g_pGameMovement);
	g_hStepMoveHookPost = DHookCreate(offset, HookType_Raw, ReturnType_Void, ThisPointer_Ignore, DHook_StepMovePost);
	DHookAddParam(g_hStepMoveHookPost, HookParamType_VectorPtr);
	DHookAddParam(g_hStepMoveHookPost, HookParamType_ObjectPtr);
	DHookRaw(g_hStepMoveHookPost, true, g_pGameMovement);

	delete CreateInterface;
	delete gc;
}

int GetRequiredOffset(Handle gc, const char[] key)
{
	int offset = GameConfGetOffset(gc, key);
	if (offset == -1) SetFailState("Failed to get %s offset", key);

	return offset;
}

any GetMoveData(int offset)
{
	return LoadFromAddress(g_mv + view_as<Address>(offset), NumberType_Int32);
}

void GetMoveDataVector(int offset, float vector[3])
{
	for (int i = 0; i < 3; i++)
	{
		vector[i] = GetMoveData(offset + i*4);
	}
}

void SetMoveData(int offset, any value)
{
	StoreToAddress(g_mv + view_as<Address>(offset), value, NumberType_Int32);
}

void SetMoveDataVector(int offset, const float vector[3])
{
	for (int i = 0; i < 3; i++)
	{
		SetMoveData(offset + i*4, vector[i]);
	}
}

public MRESReturn DHook_StepMovePre(Handle hParams)
{
	if (!g_cvEnabled.BoolValue)
		return MRES_Ignored;

	g_bInStepMove = true;
	g_iTPMCalls = 0;
	g_mv = view_as<Address>(LoadFromAddress(g_pGameMovement+view_as<Address>(0x8), NumberType_Int32));

	GetMoveDataVector(MOVEDATA_ORIGIN, g_vecStartPos);
	g_flStartStepHeight = view_as<float>(GetMoveData(MOVEDATA_OUTSTEPHEIGHT));

	return MRES_Handled;
}

public MRESReturn DHook_TryPlayerMovePost(Handle hReturn, Handle hParams)
{
	if (!g_bInStepMove)
		return MRES_Ignored;

	if (!g_cvEnabled.BoolValue)
		return MRES_Ignored;

	g_iTPMCalls++;

	switch (g_iTPMCalls)
	{
		case 1:
		{
			// This was the call for the "down" move.
			GetMoveDataVector(MOVEDATA_ORIGIN, g_vecDownPos);
			GetMoveDataVector(MOVEDATA_VELOCITY, g_vecDownVel);
		}
		case 2:
		{
			// This was the call for the "up" move.
			// At this time, the origin doesn't include the step down, but we don't need it anyway.
			GetMoveDataVector(MOVEDATA_VELOCITY, g_vecUpVel);
		}
		default:
		{
			SetFailState("TryPlayerMove ran more than two times in one StepMove call?");
		}
	}

	return MRES_Handled;
}

public MRESReturn DHook_StepMovePost(Handle hParams)
{
	g_bInStepMove = false;

	if (!g_cvEnabled.BoolValue)
		return MRES_Ignored;

	float vecFinalPos[3];
	GetMoveDataVector(MOVEDATA_ORIGIN, vecFinalPos);

	if (g_iTPMCalls == 2 && GetVectorDistance(vecFinalPos, g_vecDownPos, true) != 0.0)
	{
		// StepMove chose the "up" result, which means it also used just the Z-velocity
		// from the "down" result. We don't want to do that because it can lead to the
		// player getting to keep all of their horizontal velocity, but also getting some
		// Z-velocity for free. Instead, we want to use one entire result or the other.

		if (g_vecDownVel[2] > NON_JUMP_VELOCITY)
		{
			// In this case, the "down" result gave the player enough Z-velocity to start sliding up.
			// The "up" result went farther, but we actually really want to keep the "down" result's
			// Z-velocity because sliding is the more important outcome -- so use the "down" result.
			SetMoveDataVector(MOVEDATA_ORIGIN, g_vecDownPos);
			SetMoveDataVector(MOVEDATA_VELOCITY, g_vecDownVel);

			float flStepDist = g_vecDownPos[2] - g_vecStartPos[2];
			if (flStepDist > 0.0)
			{
				SetMoveData(MOVEDATA_OUTSTEPHEIGHT, g_flStartStepHeight + flStepDist);
			}
		}
		else
		{
			// The "up" result is fine, but use the "up" result's actual velocity without combining it.
			// Doing this probably doesn't matter because we know the "down" Z-velocity is not more than
			// NON_JUMP_VELOCITY, which means the player will still be on the ground after CategorizePostion
			// and their Z-velocity will be reset to zero -- but let's do this anyway to be totally sure.
			SetMoveDataVector(MOVEDATA_VELOCITY, g_vecUpVel);
		}
	}

	return MRES_Handled;
}
