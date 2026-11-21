-- luacheck for a WoW: Forever addon. Run from this folder (tools\lua.ps1 does): the generated globals list
-- lives in the scaffolding root; standalone (CI in this repo) falls back to a short list.
std = "lua51"
max_line_length = 140
codes = true
ignore = {
	"212/self", -- unused self
	"212/_.*", -- unused args named _x
	"211/_.*", -- unused locals named _x (GetLootSlotInfo's skipped returns)
}

local ok, wow = pcall(dofile, "../../tools/luacheck-wow-globals.lua")
if ok and type(wow) == "table" then
	read_globals = {}
	for _, g in ipairs(wow.read_globals) do
		if g ~= "SlashCmdList" then
			read_globals[#read_globals + 1] = g
		end
	end
else
	-- CI in this repo runs standalone: every global the addon touches must be here.
	read_globals = {
		"CreateFrame", "C_AddOns", "C_Spell", "GetBuildInfo", "WOW_PROJECT_ID", "issecretvalue", "date", "time",
		"GetTimePreciseSec", "GetNetStats", "IsInInstance", "UnitGUID", "UnitName", "UnitLevel", "UnitClassification",
		"UnitIsDead", "GetRealZoneText", "GetNumLootItems", "GetLootSlotType", "GetLootSlotInfo", "GetLootSlotLink",
		"GetLootSourceInfo", "GetMoney", "Enum", "IsPlayerMoving", "GetUnitSpeed", "IsFalling",
		"C_CVar", "IsModifiedClick", "CheckInteractDistance", "C_Map", "GetSubZoneText",
	}
end
-- FrameXML globals and GlobalStrings the generated list doesn't carry (it is built from the C API lists).
for _, g in ipairs({
	"DEFAULT_CHAT_FRAME", "UIParent", "GameFontHighlight",
	"SPELL_FAILED_TARGET_NO_POCKETS", "ERR_ALREADY_PICKPOCKETED", "SPELL_FAILED_TARGET_AFFECTING_COMBAT",
	"SPELL_FAILED_OUT_OF_RANGE", "ERR_OUT_OF_RANGE", "SPELL_FAILED_ONLY_STEALTHED", "SPELL_FAILED_NOT_BEHIND",
	"SPELL_FAILED_UNIT_NOT_INFRONT",
}) do
	read_globals[#read_globals + 1] = g
end

globals = { "PocketLog", "PocketLogDB", "SLASH_POCKETLOG1", "SlashCmdList" }

files["tests/"] = { std = "+busted", globals = { "PocketLog", "PocketLogDB", "_G", "PocketLogClassifyCases", "PocketLogWaits" } }
exclude_files = { ".luacheckrc", ".release/" }
