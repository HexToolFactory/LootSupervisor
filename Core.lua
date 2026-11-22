-- Loot Supervisor: logs boss kills (items, winners), currency drops per boss, shows a loot reminder after a kill and whispers group
-- members who have not looted a currency boss after a delay (default 15 s).

local ADDON_NAME = ...
local PREFIX = "LootSup"
local VERSION = "0.5.0"
local KILL_WINDOW = 180 -- seconds a kill stays open for loot and whispers
local HINT_TIME = 120 -- seconds the reminder stays up after a kill
local TARGET_HINT_TIME = 20 -- seconds for a reminder raised by targeting a corpse
local SEND_RETRY = 60 -- seconds a blocked message is retried

local DB
local onTick -- set by the log window
-- whisper "addon": Forever shows no other player's currency loot in chat, so only addon users can be known to have looted
local DEFAULTS = { whisper = "addon", hint = "known", delay = 15 }

local function say(msg)
	print("|cffffd100Loot Supervisor|r: " .. msg)
end

-- secret values (restricted maps, encounters) are never compared or stored
local function plain(v)
	if v == nil then
		return nil
	end
	if issecretvalue and issecretvalue(v) then
		return nil
	end
	return v
end

local function now()
	return GetTime()
end

-- names: Forever names have first name + surname, senders may carry a realm; compare without spaces,
-- dashes and case, one key may extend the other (realm suffix)
local function norm(name)
	name = plain(name)
	if type(name) ~= "string" or name == "" then
		return nil
	end
	return (name:gsub("[%s%-']", ""):lower())
end

local function sameName(a, b)
	if not a or not b then
		return false
	end
	return a == b or a:sub(1, #b) == b or b:sub(1, #a) == a
end

local function inSet(set, key)
	if not key then
		return false
	end
	if set[key] then
		return true
	end
	for k in pairs(set) do
		if sameName(k, key) then
			return true
		end
	end
	return false
end

local function myName()
	return norm(GetUnitName("player", true))
end

local function npcIdOf(guid)
	guid = plain(guid)
	if type(guid) ~= "string" then
		return nil
	end
	local kind, id = guid:match("^(%a+)%-[^-]+%-[^-]+%-[^-]+%-[^-]+%-(%d+)")
	if kind ~= "Creature" and kind ~= "Vehicle" then
		return nil
	end
	return tonumber(id)
end

---------------------------------------------------------------------------------------------------------
-- saved data: bosses[key] = { name, kills, loots, cur = { [currencyID] = { drops, total } } }
-- key "e<encounterID>" for encounter bosses, "n<npcID>" for other creatures; links[npcID] = encounter key
---------------------------------------------------------------------------------------------------------

local function entry(key, name)
	local e = DB.bosses[key]
	if not e then
		e = { kills = 0, loots = 0, cur = {} }
		DB.bosses[key] = e
	end
	if name and not e.name then
		e.name = name
	end
	return e
end

local function hasCur(e)
	return e ~= nil and next(e.cur) ~= nil
end

local function currencyName(cid)
	local c = DB.currencies[cid]
	return c and c.name or ("currency " .. tostring(cid))
end

-- the unit on a corpse guid, if one of the usual tokens points at it
local function unitOfGuid(guid)
	if not guid then
		return nil
	end
	for _, unit in ipairs({ "target", "mouseover", "softinteract" }) do
		if plain(UnitGUID(unit)) == guid then
			return unit
		end
	end
	return nil
end

---------------------------------------------------------------------------------------------------------
-- kill log: DB.log[i] = { time, date, boss, enc, zone, corpse, items = { { link, id, winner, roll, how, key } },
-- cur = { [currencyID] = amount you got } }
---------------------------------------------------------------------------------------------------------

local LOG_MAX = 500
local LOG_WINDOW = 600 -- seconds a kill takes item lines from chat and loot history

local function itemIdOf(link)
	return type(link) == "string" and tonumber(link:match("item:(%d+)")) or nil
end

local QUALITY_BY_COLOR = {
	ff9d9d9d = 0,
	ffffffff = 1,
	ff1eff00 = 2,
	ff0070dd = 3,
	ffa335ee = 4,
	ffff8000 = 5,
}

local function qualityOf(link)
	local id = itemIdOf(link)
	if id and C_Item and C_Item.GetItemQualityByID then
		local ok, q = pcall(C_Item.GetItemQualityByID, id)
		q = ok and plain(q)
		if type(q) == "number" then
			return q
		end
	end
	local color = link:match("|c(%x%x%x%x%x%x%x%x)")
	return color and QUALITY_BY_COLOR[color:lower()] or 0
end

local function instanceName()
	local name = GetInstanceInfo and plain((GetInstanceInfo()))
	if type(name) ~= "string" or name == "" then
		name = GetRealZoneText and plain(GetRealZoneText()) or nil
	end
	return name
end

local function logKill(boss, encounterID)
	local rec = {
		time = time(),
		date = date("%Y-%m-%d %H:%M"),
		boss = boss,
		enc = encounterID,
		zone = instanceName(),
		items = {},
		cur = {},
	}
	DB.log[#DB.log + 1] = rec
	while #DB.log > LOG_MAX do
		table.remove(DB.log, 1)
	end
	return rec
end

-- the newest logged kill still taking loot (of this encounter, if given)
local function openRec(encounterID)
	local t = time()
	for i = #DB.log, 1, -1 do
		local rec = DB.log[i]
		if t - rec.time > LOG_WINDOW then
			return nil
		end
		if encounterID == nil or rec.enc == encounterID then
			return rec
		end
	end
	return nil
end

-- items seen in the boss loot window: { [link] = slots }
local function corpseItems(rec, links)
	for link, slots in pairs(links) do
		local id = itemIdOf(link)
		if id then
			local have = 0
			for _, it in ipairs(rec.items) do
				if it.id == id then
					have = have + 1
				end
			end
			for _ = have + 1, slots do
				rec.items[#rec.items + 1] = { link = link, id = id }
			end
		end
	end
	rec.corpse = true
end

-- 0.3.0 copied resent roll history into new entries: drop rolls logged twice (same group, key and item
-- within 6 h) and entries that end up empty
local function dedupeLog()
	local seen = {}
	local removed = 0
	for _, rec in ipairs(DB.log) do
		if rec.enc then
			local keep, had = {}, #rec.items
			for _, it in ipairs(rec.items) do
				local k = it.key and (rec.enc .. ":" .. it.key .. ":" .. tostring(it.id))
				if k and seen[k] and rec.time - seen[k] <= 6 * 3600 then
					removed = removed + 1
				else
					if k then
						seen[k] = rec.time
					end
					keep[#keep + 1] = it
				end
			end
			rec.items = keep
			rec.emptied = had > 0 and #keep == 0 and next(rec.cur) == nil or nil
		end
	end
	for i = #DB.log, 1, -1 do
		if DB.log[i].emptied then
			table.remove(DB.log, i)
		end
	end
	return removed
end

-- own loot windows of this session, so a kill logged only from the roll history (no boss event, or one
-- without its creature IDs) still gets the corpse's items and your currency
local recentCorpses = {} -- { items = { [link] = slots }, cur, ids = { [itemID] = true }, t, recs = { [rec] = true } }

local function giveCorpse(rec, corpse)
	if corpse.recs[rec] then
		return
	end
	corpse.recs[rec] = true
	corpseItems(rec, corpse.items)
	for cid, amount in pairs(corpse.cur) do
		rec.cur[cid] = (rec.cur[cid] or 0) + amount
	end
end

-- a rolled item of this record that we saw in one of our loot windows: that window was this kill
local function attachCorpses(rec, itemID)
	local t = now()
	for i = #recentCorpses, 1, -1 do
		local corpse = recentCorpses[i]
		if t - corpse.t > LOG_WINDOW then
			break
		end
		if corpse.ids[itemID] then
			giveCorpse(rec, corpse)
		end
	end
end

-- a loot window: remembered, and given to a logged kill whose roll history already holds one of its items
local function rememberCorpse(c, ownerRec)
	local ids = {}
	for link in pairs(c.items or {}) do
		local id = itemIdOf(link)
		if id then
			ids[id] = true
		end
	end
	local corpse = { items = c.items or {}, cur = c.cur or {}, ids = ids, t = now(), recs = {} }
	if ownerRec then
		corpse.recs[ownerRec] = true
	end
	recentCorpses[#recentCorpses + 1] = corpse
	while #recentCorpses > 20 do
		table.remove(recentCorpses, 1)
	end
	if ownerRec then
		return
	end
	local t = time()
	for i = #DB.log, 1, -1 do
		local rec = DB.log[i]
		if t - rec.time > LOG_WINDOW then
			break
		end
		for _, it in ipairs(rec.items) do
			if it.key and ids[it.id] then
				giveCorpse(rec, corpse)
				break
			end
		end
	end
end

-- Enum.EncounterLootDropRollState
local ROLL_STATE = { [0] = "Need", [1] = "Need (off)", [2] = "Transmog", [3] = "Greed", [4] = "No roll", [5] = "Pass" }

-- one player's roll on an item, replaced when the same player shows up again
local function addRoll(it, name, kind, roll, class)
	local key = norm(name)
	if not key then
		return
	end
	it.rolls = it.rolls or {}
	for _, r in ipairs(it.rolls) do
		if sameName(norm(r.name), key) then
			r.kind = kind or r.kind
			r.roll = roll or r.roll
			r.class = class or r.class
			return
		end
	end
	it.rolls[#it.rolls + 1] = { name = name, kind = kind, roll = roll, class = class }
end

-- one drop of the game's loot history (rolls): item, winner, every roll
local function historyDrop(rec, info)
	local link = plain(info.itemHyperlink)
	local id = itemIdOf(link)
	if not id then
		return
	end
	local key = plain(info.lootListKey)
	local it
	for _, e in ipairs(rec.items) do
		if key and e.key == key then
			it = e
			break
		end
	end
	if not it then
		for _, e in ipairs(rec.items) do
			if e.id == id and not e.key then
				it = e
				break
			end
		end
	end
	if not it then
		it = { id = id }
		rec.items[#rec.items + 1] = it
	end
	it.link, it.key = link, key
	local winner = info.winner
	if plain(info.allPassed) == true then
		it.winner, it.how = "all passed", "roll"
	elseif type(winner) == "table" then
		it.winner = plain(winner.playerName) or it.winner
		it.winnerClass = plain(winner.playerClass) or it.winnerClass
		it.roll = plain(winner.roll)
		it.how = "roll"
	end
	if type(info.rollInfos) == "table" then
		for _, r in ipairs(info.rollInfos) do
			if type(r) == "table" then
				local name = plain(r.playerName)
				if name then
					addRoll(it, name, ROLL_STATE[plain(r.state)] or "?", plain(r.roll), plain(r.playerClass))
				end
			end
		end
	end
	attachCorpses(rec, id)
end

-- the item entry a chat line is about; a new one only for rare+ items when the boss loot was not seen
local function chatEntry(rec, link)
	local id = itemIdOf(link)
	if not id then
		return nil
	end
	for _, e in ipairs(rec.items) do
		if e.id == id then
			return e
		end
	end
	if rec.corpse or qualityOf(link) < 3 then
		return nil
	end
	local e = { link = link, id = id }
	rec.items[#rec.items + 1] = e
	return e
end

-- a "Need Roll - 87 for [item] by X" / "X passed on: [item]" chat line
local function chatRoll(rec, link, who, kind, roll)
	local it = chatEntry(rec, link)
	if it then
		addRoll(it, who, kind, roll)
	end
end

-- a "won" / "receives loot" chat line; items not seen on the boss only when rare or better
local function chatItem(rec, link, who, how)
	local id = itemIdOf(link)
	if not id then
		return
	end
	local whoKey = norm(who)
	for _, e in ipairs(rec.items) do
		if e.id == id and e.winner and sameName(norm(e.winner), whoKey) then
			return -- known already (loot history or an earlier line)
		end
	end
	for _, e in ipairs(rec.items) do
		if e.id == id and not e.winner then
			e.winner, e.how = who, e.how or how
			for _, r in ipairs(e.rolls or {}) do
				if sameName(norm(r.name), whoKey) then
					e.roll = r.roll
				end
			end
			return
		end
	end
	if rec.corpse or qualityOf(link) < 3 then
		return -- not on the boss: trash loot
	end
	rec.items[#rec.items + 1] = { link = link, id = id, winner = who, how = how }
end

-- the client's own loot line formats (localized), turned into patterns with argument order
local function fmtPattern(fmt)
	if type(fmt) ~= "string" then
		return nil
	end
	local order, n = {}, 0
	local p = fmt:gsub("%%(%d?)%$?([sd])", function(pos, kind)
		n = n + 1
		order[#order + 1] = tonumber(pos) or n
		return kind == "d" and "\001" or "\002"
	end)
	p = p:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")
	p = p:gsub("\001", "(%%d+)"):gsub("\002", "(.+)")
	if p:sub(-2) == "%." then
		p = p:sub(1, -3) .. "%.?" -- "You receive loot: [x]" arrives without the final period
	end
	return "^" .. p .. "$", order
end

-- { global, English fallback, about you, how, fields in argument order, roll kind }
local LOOT_LINES = {
	{ "LOOT_ROLL_ROLLED_NEED_ROLE_BONUS", "Need Roll - %d for %s by %s + Role Bonus", false, "roll", { "roll", "item", "who" }, "Need" },
	{ "LOOT_ROLL_ROLLED_NEED", "Need Roll - %d for %s by %s", false, "roll", { "roll", "item", "who" }, "Need" },
	{ "LOOT_ROLL_ROLLED_GREED", "Greed Roll - %d for %s by %s", false, "roll", { "roll", "item", "who" }, "Greed" },
	{ "LOOT_ROLL_ROLLED_DE", "Disenchant Roll - %d for %s by %s", false, "roll", { "roll", "item", "who" }, "Disenchant" },
	{ "LOOT_ROLL_PASSED_SELF", "You passed on: %s", true, "roll", { "item" }, "Pass" },
	{ "LOOT_ROLL_PASSED", "%s passed on: %s", false, "roll", { "who", "item" }, "Pass" },
	{ "LOOT_ROLL_YOU_WON", "You won: %s", true, "roll", { "item" } },
	{ "LOOT_ROLL_WON", "%s won: %s", false, "roll", { "who", "item" } },
	{ "LOOT_ITEM_SELF_MULTIPLE", "You receive loot: %sx%d.", true, "loot", { "item", "n" } },
	{ "LOOT_ITEM_SELF", "You receive loot: %s.", true, "loot", { "item" } },
	{ "LOOT_ITEM_MULTIPLE", "%s receives loot: %sx%d.", false, "loot", { "who", "item", "n" } },
	{ "LOOT_ITEM", "%s receives loot: %s.", false, "loot", { "who", "item" } },
}
local lootPatterns

local function parseLootLine(text)
	if not lootPatterns then
		lootPatterns = {}
		for _, def in ipairs(LOOT_LINES) do
			local pattern, order = fmtPattern(_G[def[1]] or def[2])
			if pattern then
				lootPatterns[#lootPatterns + 1] =
					{ pattern = pattern, order = order, self = def[3], how = def[4], fields = def[5], kind = def[6] }
			end
		end
	end
	for _, lp in ipairs(lootPatterns) do
		local caps = { text:match(lp.pattern) }
		if #caps > 0 then
			local out = { how = lp.how, kind = lp.kind }
			for j, value in ipairs(caps) do
				local field = lp.fields[lp.order[j] or j]
				if field then
					out[field] = value
				end
			end
			if lp.self then
				out.who = GetUnitName("player", true)
			end
			return out
		end
	end
	return nil
end

---------------------------------------------------------------------------------------------------------
-- addon messages: H = hello (has the addon), L = looted these kill keys
---------------------------------------------------------------------------------------------------------

local addonUsers = {} -- norm name -> time
local outbox = {} -- { msg, t } addon messages waiting for a send window
local lastHello = -100

local function groupChannel()
	if LE_PARTY_CATEGORY_INSTANCE and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
		return "INSTANCE_CHAT"
	end
	if IsInRaid() then
		return "RAID"
	end
	if IsInGroup() then
		return "PARTY"
	end
	return nil
end

-- returns true when the message left (0 / true), false when it should be retried
local function sendRaw(msg)
	local channel = groupChannel()
	if not channel then
		return true -- nobody to tell
	end
	local ok, result = pcall(C_ChatInfo.SendAddonMessage, PREFIX, msg, channel)
	if not ok then
		return false
	end
	result = plain(result)
	return result == nil or result == true or result == 0
end

local function send(msg)
	if not sendRaw(msg) then
		outbox[#outbox + 1] = { msg = msg, t = now() }
	end
end

local function hello(force)
	if not IsInGroup() then
		return
	end
	if not force and now() - lastHello < 15 then
		return
	end
	lastHello = now()
	send("H:" .. VERSION)
end

---------------------------------------------------------------------------------------------------------
-- kills
---------------------------------------------------------------------------------------------------------

local kills = {} -- active kills, newest last
local recentLoots = {} -- kill key -> { [norm sender] = time } from L messages (may arrive before our kill)
local seenGuids = {} -- corpses already recorded this session

local function killKeys(k)
	local keys = { k.key }
	for npc in pairs(k.npcs) do
		keys[#keys + 1] = "n" .. npc
	end
	return keys
end

local function applyRecent(k)
	for _, key in ipairs(killKeys(k)) do
		for who, t in pairs(recentLoots[key] or {}) do
			if t >= k.t - 5 then
				k.looted[who] = true
			end
		end
	end
end

local function newKill(key, name, encounterID)
	local k = {
		key = key,
		name = name,
		enc = encounterID,
		npcs = {},
		t = now(),
		looted = {},
		cur = {},
		selfLooted = false,
		hasCur = false,
		whisperDone = false,
		rec = logKill(name, encounterID),
	}
	kills[#kills + 1] = k
	return k
end

-- a creature belongs to an encounter: link it and fold what was saved under the creature into the boss
local function linkNpc(npc, key)
	if not npc or not key then
		return
	end
	DB.links[npc] = key
	local old = DB.bosses["n" .. npc]
	if not old or key == "n" .. npc then
		return
	end
	local e = entry(key, old.name)
	e.loots = e.loots + (old.loots or 0)
	for cid, d in pairs(old.cur or {}) do
		local t = e.cur[cid] or { drops = 0, total = 0 }
		e.cur[cid] = t
		t.drops = t.drops + (d.drops or 0)
		t.total = t.total + (d.total or 0)
		t.last = d.last or t.last
	end
	e.kills = math.max(e.kills, e.loots)
	DB.bosses["n" .. npc] = nil
end

-- the boss creature of an encounter from DungeonJournal's data, when it is loaded:
-- encounter ID -> boss name (RUNLOG_ENCOUNTERS), boss name -> npcID (DB[dungeon].bosses)
local function djBossNpc(encounterID, name)
	local ns = _G.ForeverDungeonJournal_NS
	if type(ns) ~= "table" or type(ns.DB) ~= "table" then
		return nil
	end
	local names, dungeon = {}, nil
	local known = type(ns.RUNLOG_ENCOUNTERS) == "table" and encounterID and ns.RUNLOG_ENCOUNTERS[encounterID]
	if type(known) == "table" then
		dungeon = known[1]
		if type(known[2]) == "string" then
			names[known[2]:lower()] = true
		end
	end
	if type(name) == "string" then
		names[name:lower()] = true
	end
	local found
	for dname, d in pairs(ns.DB) do
		if type(d) == "table" and type(d.bosses) == "table" then
			for _, b in ipairs(d.bosses) do
				if type(b) == "table" and type(b.npcID) == "number" then
					local hit = type(b.name) == "string" and names[b.name:lower()]
					for _, alias in ipairs(type(b.aliases) == "table" and b.aliases or {}) do
						hit = hit or (type(alias) == "string" and names[alias:lower()])
					end
					if hit then
						if dname == dungeon then
							return b.npcID
						end
						found = found or b.npcID
					end
				end
			end
		end
	end
	return found
end

-- bosses that drop a Tarnished Undermine Real (once a day each): the Season of Discovery lists of 2024
-- (Blizzard Watch) plus the Forever dungeon Blackmaw Hold, where every boss dropped one (kill log, 2026-11-20)
local REAL = 3469
local REAL_BOSSES = {}
for _, name in ipairs({
	-- Dire Maul
	"Pusillin", "Lethtendris", "Hydrospawn", "Zevrim Thornhoof", "Alzzin the Wildshaper", "King Gordok",
	"Tendris Warpwood", "Magister Kalendris", "Illyanna Ravenoak", "Immol'thar", "Prince Tortheldrin",
	-- Blackrock Depths
	"Fineous Darkvire", "Bael'gar", "Lord Incendius", "Hurley Blackbreath", "Phalanx", "General Angerforge",
	"Golem Lord Argelmach", "Ambassador Flamelash", "Magmus", "Emperor Dagran Thaurissan", "Emperor Thaurissan",
	-- Blackrock Spire
	"Highlord Omokk", "Shadow Hunter Vosh'gajin", "War Master Voone", "Mother Smolderweb", "Urok Doomhowl",
	"Gizrul the Slavener", "Halycon", "Overlord Wyrmthalak", "Pyroguard Emberseer", "Warchief Rend Blackhand",
	"The Beast", "General Drakkisath",
	-- Scholomance
	"Marduk Blackpool", "Vectus", "Doctor Theolen Krastinov", "Instructor Malicia", "Lorekeeper Polkelt",
	"Lord Alexei Barov", "The Ravenian", "Lady Illucia Barov", "Kirtonos the Herald", "Kirtonos",
	"Darkmaster Gandling", "Jandice Barov", "Rattlegore", "Ras Frostwhisper", "Ras Frostwhisperer",
	-- Stratholme
	"Ezra Grimm", "The Unforgiven", "Postmaster Malown", "Timmy the Cruel", "Malor the Zealous",
	"Cannon Master Willey", "Archivist Galford", "Grand Crusader Dathrohan", "Balnazzar", "Magistrate Barthilas",
	"Nerub'enkan", "Maleki the Pallid", "Baroness Anastari", "Ramstein the Gorger", "Baron Rivendare",
	-- Blackmaw Hold (Forever)
	"Impaan the Imprisoner", "Bonesnout the Unbroken", "Withermaw", "Unbound Spirit", "Elder Shaman Bloodmane",
	"Blackmaw Behemoth", "Varrox Bleakhoof",
	-- world and raid bosses
	"Azuregos", "Lord Kazzak", "Onyxia",
	"Lucifron", "Magmadar", "Gehennas", "Garr", "Shazzrah", "Baron Geddon", "Golemagg the Incinerator",
	"Sulfuron Harbinger", "Majordomo Executus", "Ragnaros",
	"Razorgore the Untamed", "Vaelastrasz the Corrupt", "Broodlord Lashlayer", "Firemaw", "Ebonroc", "Flamegor",
	"Chromaggus", "Nefarian",
	"High Priestess Jeklik", "High Priest Venoxis", "High Priestess Mar'li", "High Priest Thekal",
	"High Priestess Arlokk", "Hakkar", "Bloodlord Mandokir", "Jin'do the Hexxer", "Gahz'ranka", "Gri'lek",
	"Hazza'rah", "Renataki", "Wushoolay",
}) do
	REAL_BOSSES[name:lower()] = true
end
-- encounter IDs seen dropping one on Forever: any client language
local REAL_ENCOUNTERS = {}
for _, id in ipairs({
	343, 344, 345, 346, 2792, -- Dire Maul East
	2801, 2802, 2803, 2804, 2805, 2806, 2807, 2808, 2810, 2811, 2812, -- Scholomance
	472, 474, 475, 476, 477, 478, 479, 480, 481, 482, 483, 484, 2797, -- Stratholme
	3062, 3063, 3068, 3069, -- Upper Blackrock Spire
	3315, 3316, 3322, 3323, 3327, 3334, 3336, -- Blackmaw Hold
}) do
	REAL_ENCOUNTERS[id] = true
end

-- creatures in the boss frames during an encounter (boss1..boss5), if the game sets them
local engaged = {}
local function noteBossUnits()
	for i = 1, 5 do
		local npc = npcIdOf(UnitGUID and plain(UnitGUID("boss" .. i)))
		if npc then
			engaged[npc] = true
		end
	end
end

-- does this encounter drop a Real: its ID, its name, or its English name from DungeonJournal's ID list
local function dropsReal(encounterID, name)
	if encounterID and REAL_ENCOUNTERS[encounterID] then
		return true
	end
	if type(name) == "string" and REAL_BOSSES[name:lower()] then
		return true
	end
	local ns = _G.ForeverDungeonJournal_NS
	local known = type(ns) == "table" and type(ns.RUNLOG_ENCOUNTERS) == "table" and encounterID and ns.RUNLOG_ENCOUNTERS[encounterID]
	return type(known) == "table" and type(known[2]) == "string" and REAL_BOSSES[known[2]:lower()] == true
end

-- start of the current game day (daily reset); without the API: 20 h back
local function dayStart()
	if C_DateAndTime and C_DateAndTime.GetSecondsUntilDailyReset then
		local ok, left = pcall(C_DateAndTime.GetSecondsUntilDailyReset)
		left = ok and plain(left)
		if type(left) == "number" then
			return time() + left - 86400
		end
	end
	return time() - 20 * 3600
end

-- you got this boss's Real already today: it drops once a day
local function realToday(key)
	local t = key and DB.realGot and DB.realGot[key]
	return t ~= nil and t >= dayStart()
end

-- the Real's name and icon, before one was ever looted
local function knowReal()
	local meta = DB.currencies[REAL] or {}
	if not meta.name and C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo then
		local ok, info = pcall(C_CurrencyInfo.GetCurrencyInfo, REAL)
		if ok and type(info) == "table" then
			meta.name = plain(info.name)
			meta.icon = plain(info.iconFileID)
		end
	end
	meta.name = meta.name or "Tarnished Undermine Real"
	DB.currencies[REAL] = meta
end

-- known encounters learn their creature from DungeonJournal (repairs data saved under the creature)
local function linkKnownEncounters()
	for key, e in pairs(DB.bosses) do
		local enc = tonumber(key:match("^e(%d+)$"))
		if enc then
			local npc = djBossNpc(enc, e.name)
			if npc and not DB.links[npc] then
				linkNpc(npc, key)
			end
		end
	end
end

local function killsOfNpc(npc)
	local found = {}
	for _, k in ipairs(kills) do
		if npc and k.npcs[npc] then
			found[#found + 1] = k
		end
	end
	return found
end

---------------------------------------------------------------------------------------------------------
-- reminder frame
---------------------------------------------------------------------------------------------------------

local hint
local hintOwner, hintUntil

local function hideHint()
	hintOwner, hintUntil = nil, nil
	if hint then
		hint:Hide()
	end
end

local function buildHint()
	local f = CreateFrame("Frame", "LootSupervisorHint", UIParent)
	f:SetSize(300, 64)
	f:SetFrameStrata("HIGH")
	f:SetClampedToScreen(true)
	local p = DB.pos
	if p then
		f:SetPoint(p[1], UIParent, p[2], p[3], p[4])
	else
		f:SetPoint("TOP", UIParent, "TOP", 0, -150)
	end
	f.bg = f:CreateTexture(nil, "BACKGROUND")
	f.bg:SetAllPoints()
	f.bg:SetColorTexture(0, 0, 0, 0.65)
	f.icon = f:CreateTexture(nil, "ARTWORK")
	f.icon:SetSize(40, 40)
	f.icon:SetPoint("LEFT", f, "LEFT", 12, 0)
	f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	f.title:SetPoint("TOPLEFT", f.icon, "TOPRIGHT", 10, -2)
	f.sub = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	f.sub:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -4)
	f.arrow = f:CreateTexture(nil, "OVERLAY")
	f.arrow:SetSize(48, 48)
	f.arrow:SetTexture("Interface\\Buttons\\UI-MicroStream-Yellow")
	f.arrow:SetPoint("TOP", f, "BOTTOM", 0, 0)
	f:EnableMouse(true)
	f:SetMovable(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, relPoint, x, y = self:GetPoint(1)
		DB.pos = { point, relPoint, x, y }
	end)
	f:SetScript("OnMouseUp", function(_, button)
		if button == "RightButton" then
			hideHint()
		end
	end)
	f:SetScript("OnUpdate", function(self, elapsed)
		self.clock = (self.clock or 0) + elapsed
		self.arrow:SetPoint("TOP", self, "BOTTOM", 0, -math.abs(math.sin(self.clock * 4)) * 12)
	end)
	f:Hide()
	return f
end

-- curs: { [currencyID] = amount or true }
local function showHint(owner, name, curs, duration)
	hint = hint or buildHint()
	local cid, amount = next(curs)
	local c = cid and DB.currencies[cid]
	hint.icon:SetTexture(c and c.icon or "Interface\\Icons\\INV_Misc_Coin_02")
	hint.title:SetText("Loot " .. (name or "the boss"))
	if cid then
		local count = type(amount) == "number" and (amount .. "x ") or ""
		local more = next(curs, cid) and " +more" or ""
		hint.sub:SetText(count .. currencyName(cid) .. more)
	else
		hint.sub:SetText("Currency possible")
	end
	hintOwner, hintUntil = owner, now() + (duration or HINT_TIME)
	hint:Show()
	if PlaySound and SOUNDKIT and SOUNDKIT.RAID_WARNING then
		pcall(PlaySound, SOUNDKIT.RAID_WARNING)
	end
end

-- currency amounts this boss gave last time, for the reminder text
local function knownCurs(e, expect)
	local curs = {}
	for cid, c in pairs(e and e.cur or {}) do
		curs[cid] = c.last or true
	end
	for cid in pairs(expect or {}) do
		curs[cid] = curs[cid] or true
	end
	return curs
end

---------------------------------------------------------------------------------------------------------
-- loot
---------------------------------------------------------------------------------------------------------

local function corpseName(guid)
	local unit = unitOfGuid(guid)
	return unit and plain(UnitName(unit)) or nil
end

local function isBossCorpse(guid)
	local unit = unitOfGuid(guid)
	if not unit then
		return false
	end
	local class = plain(UnitClassification(unit))
	local level = plain(UnitLevel(unit))
	return class == "worldboss" or level == -1
end

-- one corpse of the loot window: { guid, npc, cur = { [cid] = amount } }
local function recordCorpse(c)
	local hasCurrency = next(c.cur) ~= nil
	local matching = killsOfNpc(c.npc)
	local name = c.guid and corpseName(c.guid)

	-- link a fresh encounter kill without boss list to the corpse named like it, or to a boss corpse
	if #matching == 0 and c.npc then
		for i = #kills, 1, -1 do
			local k = kills[i]
			if k.enc and next(k.npcs) == nil and now() - k.t <= 300 then
				if (name and k.name and norm(name) == norm(k.name)) or isBossCorpse(c.guid) then
					k.npcs[c.npc] = true
					linkNpc(c.npc, k.key)
					matching = { k }
				end
				break
			end
		end
	end
	-- no source readable: the newest open kill owns the window
	if not c.npc and #kills > 0 then
		matching = { kills[#kills] }
	end
	-- a skull/world boss without encounter event still counts as a kill while grouped
	if #matching == 0 and c.npc and hasCurrency and IsInGroup() and isBossCorpse(c.guid) then
		local k = newKill("n" .. c.npc, name, nil)
		k.npcs[c.npc] = true
		applyRecent(k)
		matching = { k }
	end

	-- data
	local first = not (c.guid and seenGuids[c.guid])
	if c.guid then
		seenGuids[c.guid] = true
	end
	local key = c.npc and (DB.links[c.npc] or ("n" .. c.npc)) or (matching[1] and matching[1].key)
	if first and key and (hasCurrency or DB.bosses[key] or #matching > 0) then
		local e = entry(key, name or (matching[1] and matching[1].name))
		e.loots = e.loots + 1
		if not key:find("^e") then
			e.kills = e.loots
		end
		for cid, amount in pairs(c.cur) do
			local d = e.cur[cid] or { drops = 0, total = 0 }
			e.cur[cid] = d
			d.drops = d.drops + 1
			d.total = d.total + amount
			d.last = amount
		end
	end
	-- the day's Real from this boss is taken
	if c.cur[REAL] then
		DB.realGot[key or ""] = time()
		for _, k in ipairs(matching) do
			DB.realGot[k.key] = time()
		end
		DB.realGot[""] = nil
	end

	-- kills and reminder
	local keys = {}
	for _, k in ipairs(matching) do
		k.selfLooted = true
		if hasCurrency then
			k.hasCur = true
			for cid, amount in pairs(c.cur) do
				k.cur[cid] = amount
			end
		end
		if first and k.rec then
			corpseItems(k.rec, c.items or {})
			for cid, amount in pairs(c.cur) do
				k.rec.cur[cid] = (k.rec.cur[cid] or 0) + amount
			end
		end
		keys[#keys + 1] = k.key
		if hintOwner == k then
			hideHint()
		end
	end
	if hintOwner and c.guid and hintOwner.guid == c.guid then
		hideHint()
	end
	if first and c.npc and (next(c.items or {}) or hasCurrency) then
		rememberCorpse(c, matching[1] and matching[1].rec)
	end
	if c.npc then
		keys[#keys + 1] = "n" .. c.npc
	end
	if #keys > 0 and (#matching > 0 or hasCurrency) then
		send("L:" .. table.concat(keys, ","))
	end
end

local function onLootOpened()
	local count = plain(GetNumLootItems()) or 0
	local corpses, order, loose, looseItems = {}, {}, {}, {}
	for slot = 1, count do
		local cid, amount, itemLink
		local slotType = plain(GetLootSlotType(slot))
		if slotType == 1 then -- Enum.LootSlotType.Item
			itemLink = plain(GetLootSlotLink(slot))
			if not itemIdOf(itemLink) then
				itemLink = nil
			end
		end
		if slotType == 3 then -- Enum.LootSlotType.Currency
			local link = plain(GetLootSlotLink(slot))
			local texture, name, quantity, id4 = GetLootSlotInfo(slot)
			cid = (type(link) == "string" and tonumber(link:match("currency:(%d+)"))) or plain(id4)
			amount = plain(quantity) or 1
			if cid then
				local meta = DB.currencies[cid] or {}
				meta.name = plain(name) or meta.name
				meta.icon = plain(texture) or meta.icon
				DB.currencies[cid] = meta
			end
		end
		local sources = { GetLootSourceInfo(slot) }
		local placed = false
		for i = 1, #sources, 2 do
			local guid = plain(sources[i])
			local npc = npcIdOf(guid)
			if npc then
				local c = corpses[guid]
				if not c then
					c = { guid = guid, npc = npc, cur = {}, items = {} }
					corpses[guid] = c
					order[#order + 1] = c
				end
				if cid then
					local part = plain(sources[i + 1])
					c.cur[cid] = (c.cur[cid] or 0) + ((#sources > 2 and type(part) == "number") and part or amount)
				end
				if itemLink then
					c.items[itemLink] = (c.items[itemLink] or 0) + 1
				end
				placed = true
			elseif guid then
				placed = true -- a chest, a node, an item: not a corpse
			end
		end
		if not placed and cid then
			loose[cid] = (loose[cid] or 0) + amount
		end
		if not placed and itemLink then
			looseItems[itemLink] = (looseItems[itemLink] or 0) + 1
		end
	end
	for _, c in ipairs(order) do
		recordCorpse(c)
	end
	if next(loose) or (next(looseItems) and #kills > 0) then
		recordCorpse({ cur = loose, items = looseItems })
	end
end

---------------------------------------------------------------------------------------------------------
-- whispers
---------------------------------------------------------------------------------------------------------

local whisperQueue = {} -- { target, msg, t }

local function groupUnits()
	local units = {}
	if IsInRaid() then
		for i = 1, GetNumGroupMembers() do
			units[#units + 1] = "raid" .. i
		end
	else
		for i = 1, GetNumSubgroupMembers() do
			units[#units + 1] = "party" .. i
		end
	end
	return units
end

-- class of every group member, so names in the log can be class-colored later (chat rolls carry no class)
local function rememberClasses()
	DB.classes = DB.classes or {}
	local units = groupUnits()
	units[#units + 1] = "player"
	for _, unit in ipairs(units) do
		local name = GetUnitName and plain(GetUnitName(unit, true))
		local class = UnitClass and plain(select(2, UnitClass(unit)))
		local key = norm(name)
		if key and type(class) == "string" then
			DB.classes[key] = class
		end
	end
end

-- among group members with the addon (and me) only the first name alphabetically whispers
local function iAmSender(members)
	local me = myName()
	for _, m in ipairs(members) do
		if inSet(addonUsers, m.key) and m.key < me and plain(UnitIsConnected(m.unit)) ~= false then
			return false
		end
	end
	return true
end

local function chatLocked()
	if C_ChatInfo and C_ChatInfo.InChatMessagingLockdown then
		local ok, locked = pcall(C_ChatInfo.InChatMessagingLockdown)
		return ok and locked == true
	end
	return false
end

local function flushWhispers()
	if #whisperQueue == 0 or chatLocked() then
		return
	end
	local sendChat = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
	local queue = whisperQueue
	whisperQueue = {}
	for _, w in ipairs(queue) do
		local ok = pcall(sendChat, w.msg, "WHISPER", nil, w.target)
		if not ok and now() - w.t < SEND_RETRY then
			whisperQueue[#whisperQueue + 1] = w
		end
	end
end

local function whisperPass(k)
	if not IsInGroup() or DB.whisper == "off" then
		return
	end
	local members = {}
	for _, unit in ipairs(groupUnits()) do
		if not UnitIsUnit(unit, "player") then
			local full = plain(GetUnitName(unit, true))
			local key = norm(full)
			if key then
				members[#members + 1] = { unit = unit, full = full, key = key }
			end
		end
	end
	if not iAmSender(members) then
		return
	end
	local cid = next(k.cur)
	if not cid then
		local e = DB.bosses[k.key]
		cid = e and next(e.cur) or next(k.expect or {})
	end
	local what = cid and currencyName(cid) or "currency"
	local msg = string.format("[Loot Supervisor] Loot %s: %s is waiting for you.", k.name or "the boss", what)
	local told = {}
	for _, m in ipairs(members) do
		local online = plain(UnitIsConnected(m.unit))
		if online ~= false and not inSet(k.looted, m.key) then
			if DB.whisper == "all" or inSet(addonUsers, m.key) then
				whisperQueue[#whisperQueue + 1] = { target = m.full, msg = msg, t = now() }
				told[#told + 1] = m.full
			end
		end
	end
	if #told > 0 then
		say("whispered " .. table.concat(told, ", ") .. " (" .. (k.name or "boss") .. ")")
	end
	flushWhispers()
end

---------------------------------------------------------------------------------------------------------
-- clock
---------------------------------------------------------------------------------------------------------

local function tick()
	if onTick then
		onTick()
	end
	local t = now()
	-- whispers
	for _, k in ipairs(kills) do
		if not k.whisperDone and t - k.t >= DB.delay then
			local e = DB.bosses[k.key]
			local known = k.hasCur or (not k.selfLooted and (hasCur(e) or k.expect))
			if known then
				k.whisperDone = true
				whisperPass(k)
			elseif k.selfLooted or t - k.t > KILL_WINDOW then
				k.whisperDone = true -- we looted and got no currency: nothing to tell
			end
		end
	end
	-- drop old kills
	for i = #kills, 1, -1 do
		if t - kills[i].t > KILL_WINDOW then
			if hintOwner == kills[i] then
				hideHint()
			end
			table.remove(kills, i)
		end
	end
	for key, who in pairs(recentLoots) do
		for name, at in pairs(who) do
			if t - at > KILL_WINDOW then
				who[name] = nil
			end
		end
		if next(who) == nil then
			recentLoots[key] = nil
		end
	end
	-- reminder timeout
	if hintUntil and t > hintUntil then
		hideHint()
	end
	-- blocked messages
	if #outbox > 0 then
		local box = outbox
		outbox = {}
		for _, m in ipairs(box) do
			if not sendRaw(m.msg) and t - m.t < SEND_RETRY then
				outbox[#outbox + 1] = m
			end
		end
	end
	flushWhispers()
end

---------------------------------------------------------------------------------------------------------
-- events
---------------------------------------------------------------------------------------------------------

local function onEncounterEnd(encounterID, encounterName, _, _, success, units)
	encounterID = plain(encounterID)
	success = plain(success)
	-- diagnostics: does this boss send the event, and does it name its creatures?
	local unitIds = {}
	if type(units) == "table" and not (issecretvalue and issecretvalue(units)) then
		for _, u in ipairs(units) do
			unitIds[#unitIds + 1] = type(u) == "table" and plain(u.creatureID) or "?"
		end
	end
	local diag = DB.diag.encounters
	diag[#diag + 1] = {
		at = date("%Y-%m-%d %H:%M:%S"),
		id = encounterID,
		name = plain(encounterName),
		success = success,
		units = table.concat(unitIds, ","),
		zone = instanceName(),
	}
	while #diag > 30 do
		table.remove(diag, 1)
	end
	if not encounterID or not (success == 1 or success == true) then
		return
	end
	local key = "e" .. encounterID
	local e = entry(key, plain(encounterName))
	e.kills = e.kills + 1
	local k = newKill(key, e.name, encounterID)
	if type(units) == "table" and not (issecretvalue and issecretvalue(units)) then
		for _, u in ipairs(units) do
			local id = type(u) == "table" and plain(u.creatureID)
			if id then
				linkNpc(id, key)
			end
		end
	end
	-- no creature IDs in the event (Forever dungeons): boss frames of the fight, then DungeonJournal's data
	noteBossUnits()
	for npc in pairs(engaged) do
		linkNpc(npc, key)
	end
	engaged = {}
	if realToday(key) then
		k.realDone = true -- your Real from this boss is looted already today
	elseif dropsReal(encounterID, e.name) then
		knowReal()
		k.expect = { [REAL] = true }
	end
	local djNpc = djBossNpc(encounterID, e.name)
	if djNpc and not DB.links[djNpc] then
		linkNpc(djNpc, key)
	end
	e = DB.bosses[key]
	for npc, link in pairs(DB.links) do
		if link == key then
			k.npcs[npc] = true
		end
	end
	applyRecent(k)
	if not k.realDone and (DB.hint == "all" or (DB.hint == "known" and (hasCur(e) or k.expect))) then
		showHint(k, e.name, knownCurs(e, k.expect))
	end
end

-- a dead, lootable corpse of a known currency dropper under the target or mouse
local function checkCorpse(unit)
	if DB.hint == "off" or not plain(UnitIsDead(unit)) then
		return
	end
	local guid = plain(UnitGUID(unit))
	local npc = npcIdOf(guid)
	if not npc or seenGuids[guid] then
		return
	end
	local e = DB.bosses[DB.links[npc] or ("n" .. npc)]
	if not hasCur(e) then
		return
	end
	local ok, lootable = pcall(CanLootUnit, guid)
	if not ok or plain(lootable) ~= true then
		return
	end
	if hintOwner and hintOwner.guid == guid then
		return
	end
	if hintOwner and not hintOwner.guid then
		return -- an encounter reminder is up already
	end
	showHint({ guid = guid }, e.name or plain(UnitName(unit)), knownCurs(e), TARGET_HINT_TIME)
end

local function onAddonMessage(prefix, text, _, sender)
	if plain(prefix) ~= PREFIX then
		return
	end
	text, sender = plain(text), norm(sender)
	if not text or not sender or sameName(sender, myName()) then
		return
	end
	local isNew = not inSet(addonUsers, sender)
	addonUsers[sender] = now()
	local kind, body = text:match("^(%a):(.*)$")
	if kind == "H" then
		if isNew then
			hello(true)
		end
	elseif kind == "L" then
		local t = now()
		for key in body:gmatch("[^,]+") do
			recentLoots[key] = recentLoots[key] or {}
			recentLoots[key][sender] = t
			local npc = tonumber(key:match("^n(%d+)$"))
			for _, k in ipairs(kills) do
				if k.key == key or (npc and k.npcs[npc]) then
					k.looted[sender] = true
				end
			end
		end
	end
end

-- a group member's currency loot line in chat (wording unknown: any currency link + a member's name)
local function onLootChat(text, playerName, _, _, playerName2)
	text = plain(text)
	if type(text) ~= "string" then
		return
	end
	local cid = tonumber(text:match("currency:(%d+)"))
	if not cid or #kills == 0 then
		return
	end
	local me = myName()
	local who
	for _, name in ipairs({ playerName, playerName2 }) do
		local key = norm(name)
		if key and not sameName(key, me) then
			who = key
			break
		end
	end
	if not who then
		local flat = norm(text) or ""
		local best = 0
		for _, unit in ipairs(groupUnits()) do
			if not UnitIsUnit(unit, "player") then
				local key = norm(GetUnitName(unit, true))
				for _, n in ipairs({ key, norm(GetUnitName(unit, false)) }) do
					if n and #n > best and flat:find(n, 1, true) then
						who, best = key, #n
					end
				end
			end
		end
	end
	if not who then
		return -- our own line: the loot window covers it
	end
	local amount = tonumber(text:match("|h|r%s*x(%d+)")) or tonumber(text:match("x(%d+)%.?$")) or 1
	local k = kills[#kills]
	k.looted[who] = true
	k.hasCur = true
	k.cur[cid] = k.cur[cid] or amount
end

-- "won" / "receives loot" lines with an item: who got which item of the newest open kill
local function onItemChat(text)
	text = plain(text)
	if type(text) ~= "string" or not text:find("item:", 1, true) then
		return
	end
	local rec = openRec(nil)
	if not rec then
		return
	end
	local line = parseLootLine(text)
	if line and line.item and line.who then
		if line.kind then
			chatRoll(rec, line.item, line.who, line.kind, tonumber(line.roll))
		else
			chatItem(rec, line.item, line.who, line.how)
		end
	end
end

-- the game's roll history: one drop or the whole encounter
local function historyRec(encounterID)
	local rec = openRec(encounterID)
	if rec then
		return rec
	end
	local ok, info = pcall(C_LootHistory.GetInfoForEncounter, encounterID)
	local name = ok and type(info) == "table" and plain(info.encounterName) or nil
	if not name then
		return nil
	end
	return logKill(name, encounterID) -- rolls after a /reload or of a kill we did not see end
end

-- the record already holding this drop: the game resends its whole roll history (trash rolls stay in
-- one "Miscellaneous" group all session), so a drop is found again by its key, wherever it was logged
local function keyRec(encounterID, info)
	local key, id = plain(info.lootListKey), itemIdOf(plain(info.itemHyperlink))
	if not (key and id) then
		return nil
	end
	local t = time()
	for i = #DB.log, 1, -1 do
		local rec = DB.log[i]
		if t - rec.time > 6 * 3600 then
			return nil
		end
		if rec.enc == encounterID then
			for _, it in ipairs(rec.items) do
				if it.key == key and it.id == id then
					return rec
				end
			end
		end
	end
	return nil
end

local function noteHistory(encounterID)
	local list = DB.diag.history
	if list[#list] ~= encounterID then
		list[#list + 1] = encounterID
		while #list > 20 do
			table.remove(list, 1)
		end
	end
end

local function onHistoryDrop(encounterID, lootListKey)
	encounterID, lootListKey = plain(encounterID), plain(lootListKey)
	if not (encounterID and lootListKey and C_LootHistory and C_LootHistory.GetSortedInfoForDrop) then
		return
	end
	local ok, info = pcall(C_LootHistory.GetSortedInfoForDrop, encounterID, lootListKey)
	if not ok or type(info) ~= "table" then
		return
	end
	noteHistory(encounterID)
	local rec = keyRec(encounterID, info) or historyRec(encounterID)
	if rec then
		historyDrop(rec, info)
	end
end

local function onHistoryEncounter(encounterID)
	encounterID = plain(encounterID)
	if not (encounterID and C_LootHistory and C_LootHistory.GetSortedDropsForEncounter) then
		return
	end
	local ok, drops = pcall(C_LootHistory.GetSortedDropsForEncounter, encounterID)
	if not ok or type(drops) ~= "table" then
		return
	end
	noteHistory(encounterID)
	local open
	for _, info in ipairs(drops) do
		if type(info) == "table" then
			local rec = keyRec(encounterID, info)
			if not rec then
				open = open or historyRec(encounterID)
				rec = open
			end
			if rec then
				historyDrop(rec, info)
			end
		end
	end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("GROUP_ROSTER_UPDATE")
frame:RegisterEvent("ENCOUNTER_END")
frame:RegisterEvent("ENCOUNTER_START")
frame:RegisterEvent("INSTANCE_ENCOUNTER_ENGAGE_UNIT")
frame:RegisterEvent("LOOT_OPENED")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:RegisterEvent("CHAT_MSG_CURRENCY")
frame:RegisterEvent("CHAT_MSG_LOOT")
frame:RegisterEvent("LOOT_HISTORY_UPDATE_DROP")
frame:RegisterEvent("LOOT_HISTORY_UPDATE_ENCOUNTER")
frame:RegisterEvent("PLAYER_TARGET_CHANGED")
frame:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
frame:SetScript("OnEvent", function(_, event, ...)
	if event == "ADDON_LOADED" then
		if ... ~= ADDON_NAME then
			return
		end
		LootSupervisorDB = LootSupervisorDB or {}
		DB = LootSupervisorDB
		DB.bosses = DB.bosses or {}
		DB.currencies = DB.currencies or {}
		DB.links = DB.links or {}
		DB.log = DB.log or {}
		DB.classes = DB.classes or {}
		-- when you last got each boss's Real; filled from the kill log the first time
		if not DB.realGot then
			DB.realGot = {}
			for _, r in ipairs(DB.log) do
				if r.enc and r.cur[3469] then
					DB.realGot["e" .. r.enc] = r.time
				end
			end
		end
		DB.diag = DB.diag or {}
		DB.diag.encounters = DB.diag.encounters or {}
		DB.diag.history = DB.diag.history or {}
		dedupeLog()
		-- 0.4.1: the old default "all" whispered members who had looted; move it to "addon" once
		if not DB.whisperV2 then
			if DB.whisper == "all" then
				DB.whisper = "addon"
			end
			DB.whisperV2 = true
		end
		for k, v in pairs(DEFAULTS) do
			if DB[k] == nil then
				DB[k] = v
			end
		end
		C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
		C_Timer.NewTicker(1, tick)
		return
	end
	if not DB then
		return
	end
	if event == "ENCOUNTER_START" then
		engaged = {}
		noteBossUnits()
	elseif event == "INSTANCE_ENCOUNTER_ENGAGE_UNIT" then
		noteBossUnits()
	elseif event == "ENCOUNTER_END" then
		onEncounterEnd(...)
	elseif event == "LOOT_OPENED" then
		onLootOpened()
	elseif event == "CHAT_MSG_ADDON" then
		onAddonMessage(...)
	elseif event == "CHAT_MSG_CURRENCY" then
		onLootChat(...)
	elseif event == "CHAT_MSG_LOOT" then
		onLootChat(...)
		onItemChat(...)
	elseif event == "LOOT_HISTORY_UPDATE_DROP" then
		onHistoryDrop(...)
	elseif event == "LOOT_HISTORY_UPDATE_ENCOUNTER" then
		onHistoryEncounter(...)
	elseif event == "PLAYER_TARGET_CHANGED" then
		checkCorpse("target")
	elseif event == "UPDATE_MOUSEOVER_UNIT" then
		checkCorpse("mouseover")
	elseif event == "PLAYER_ENTERING_WORLD" or event == "GROUP_ROSTER_UPDATE" then
		if event == "PLAYER_ENTERING_WORLD" then
			linkKnownEncounters()
		end
		hello(false)
		rememberClasses()
	end
end)

---------------------------------------------------------------------------------------------------------
-- /lsup
---------------------------------------------------------------------------------------------------------

-- one row per boss and currency, sorted by boss
local function currencyRows()
	local rows = {}
	for key, e in pairs(DB.bosses) do
		if hasCur(e) then
			for cid, d in pairs(e.cur) do
				rows[#rows + 1] = {
					boss = e.name or key,
					cid = cid,
					total = d.total,
					drops = d.drops,
					kills = math.max(e.kills, e.loots, d.drops),
				}
			end
		end
	end
	table.sort(rows, function(a, b)
		if a.boss ~= b.boss then
			return a.boss < b.boss
		end
		return tostring(a.cid) < tostring(b.cid)
	end)
	return rows
end

local function list()
	local rows = currencyRows()
	if #rows == 0 then
		say("no currency drops logged yet.")
		return
	end
	for _, r in ipairs(rows) do
		say(string.format("%s: %dx %s in %d/%d kills", r.boss, r.total, currencyName(r.cid), r.drops, r.kills))
	end
end

-- a player name in its class color, when the class is known
local function classColored(name, class)
	class = class or (DB.classes and DB.classes[norm(name) or ""])
	local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
	if c and c.colorStr then
		return "|c" .. c.colorStr .. name .. "|r"
	end
	return name
end

-- "Need: Anna Berg 87, Bob Stone 45 | Greed: Cid 12 | Pass: 3": highest roll first, many passes as a count
local ROLL_ORDER = { "Need", "Need (off)", "Greed", "Transmog", "Disenchant", "Pass", "No roll", "?" }
local function rollsText(rolls, colored)
	if not rolls or #rolls == 0 then
		return nil
	end
	local groups = {}
	for _, r in ipairs(rolls) do
		local kind = r.kind or "?"
		groups[kind] = groups[kind] or {}
		table.insert(groups[kind], r)
	end
	local parts = {}
	for _, kind in ipairs(ROLL_ORDER) do
		local list = groups[kind]
		if list then
			table.sort(list, function(a, b)
				return (a.roll or -1) > (b.roll or -1)
			end)
			local names = {}
			if (kind == "Pass" or kind == "No roll") and #list > 3 then
				names[1] = tostring(#list)
			else
				for _, r in ipairs(list) do
					local name = colored and classColored(r.name, r.class) or r.name
					names[#names + 1] = name .. (r.roll and (" " .. r.roll) or "")
				end
			end
			parts[#parts + 1] = kind .. ": " .. table.concat(names, ", ")
		end
	end
	return table.concat(parts, " | ")
end

-- newest kills first: date, boss, place; one line per item with who got it and the rolls; your currency
local function showLog(count, filter)
	local shown = 0
	for i = #DB.log, 1, -1 do
		local r = DB.log[i]
		if not filter or (r.boss and r.boss:lower():find(filter, 1, true)) then
			shown = shown + 1
			say(r.date .. " |cffffffff" .. (r.boss or "?") .. "|r" .. (r.zone and (" - " .. r.zone) or ""))
			for _, it in ipairs(r.items) do
				local who = "?"
				if it.winner then
					who = it.winner .. (it.roll and (" (" .. it.roll .. ")") or "")
				end
				print("   " .. (it.link or ("item:" .. it.id)) .. " > " .. who)
				local rolls = rollsText(it.rolls)
				if rolls then
					print("      " .. rolls)
				end
			end
			for cid, amount in pairs(r.cur) do
				print("   " .. amount .. "x " .. currencyName(cid) .. " > you")
			end
			if #r.items == 0 and next(r.cur) == nil then
				print("   no loot seen")
			end
			if shown >= count then
				break
			end
		end
	end
	if shown == 0 then
		say(filter and ("no kill of '" .. filter .. "' logged.") or "no kills logged yet.")
	end
end

---------------------------------------------------------------------------------------------------------
-- log window, in the look of DungeonJournal (rock frame, gold title strip, brown parchment panels,
-- dungeon art and colors from DungeonJournal when it is loaded)
---------------------------------------------------------------------------------------------------------

local RUN_GAP = 2 * 3600 -- kills in the same zone less than 2 h apart are one activity
local WHITE = "Interface\\Buttons\\WHITE8X8"
local EDGE = "Interface\\Tooltips\\UI-Tooltip-Border"
local SKULL = "Interface\\TargetingFrame\\UI-TargetingFrame-Skull"
local QUESTION = "Interface\\Icons\\INV_Misc_QuestionMark"

-- DungeonJournal's default palette (its "Hall of Thanes" theme)
local BASE_THEME = {
	border = { 0.52, 0.36, 0.16, 1 },
	header = { 0.26, 0.18, 0.09, 0.94 },
	row = { 0.14, 0.09, 0.045, 0.92 },
	rowSelected = { 0.36, 0.22, 0.08, 0.95 },
	lootRow = { 0.17, 0.11, 0.06, 0.94 },
	title = { 1.00, 0.80, 0.34 },
	text = { 0.93, 0.84, 0.66 },
	muted = { 0.82, 0.74, 0.60 },
}

local ui -- built on first open

local function djTable(name)
	local ns = _G.ForeverDungeonJournal_NS
	local t = type(ns) == "table" and ns[name]
	return type(t) == "table" and t or nil
end

-- DungeonJournal key for a zone: exact, else its first wing ("Dire Maul" -> "Dire Maul: East")
local function djKey(t, zone)
	if not t or type(zone) ~= "string" then
		return nil
	end
	if t[zone] ~= nil then
		return zone
	end
	local best
	for k in pairs(t) do
		if type(k) == "string" and k:sub(1, #zone + 1) == zone .. ":" and (not best or k < best) then
			best = k
		end
	end
	return best
end

local function themeOf(zone)
	local themes = djTable("THEMES")
	local key = djKey(themes, zone)
	return key and themes[key] or BASE_THEME
end

local function color(theme, field)
	local c = theme[field] or BASE_THEME[field]
	return c[1], c[2], c[3], c[4] or 1
end

local function artOf(zone)
	local arts = djTable("DUNGEON_HOME_ART")
	local key = djKey(arts, zone)
	if not key then
		return nil
	end
	local coords = djTable("DUNGEON_HOME_TEXCOORD")
	return arts[key], coords and coords[key]
end

-- DungeonJournal's own fonts when it is loaded, else the stock ones
local function font(name)
	return _G["ForeverDJ_" .. name] and ("ForeverDJ_" .. name) or name
end

local function itemIcon(id)
	local icon
	if C_Item and C_Item.GetItemIconByID then
		local ok, v = pcall(C_Item.GetItemIconByID, id)
		icon = ok and plain(v) or nil
	end
	if not icon and GetItemIcon then
		local ok, v = pcall(GetItemIcon, id)
		icon = ok and plain(v) or nil
	end
	return icon or QUESTION
end

local function currencyIcon(cid)
	if C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo then
		local ok, info = pcall(C_CurrencyInfo.GetCurrencyInfo, cid)
		if ok and type(info) == "table" and plain(info.iconFileID) then
			return plain(info.iconFileID)
		end
	end
	return QUESTION
end

local function linkName(link)
	return type(link) == "string" and link:match("%[(.-)%]") or nil
end

-- consecutive kills in one zone, less than RUN_GAP apart; newest activity first, kills in kill order
local function activities()
	local acts, cur, last = {}, nil, nil
	for _, r in ipairs(DB.log) do
		local t = r.time or 0
		if not cur or r.zone ~= cur.zone or t - last > RUN_GAP then
			cur = { zone = r.zone, first = t, recs = {} }
			cur.key = t .. ":" .. tostring(r.zone)
			acts[#acts + 1] = cur
		end
		cur.recs[#cur.recs + 1] = r
		cur.last = t
		last = t
	end
	local out = {}
	for i = #acts, 1, -1 do
		out[#out + 1] = acts[i]
	end
	return out
end

local function has(s, q)
	return type(s) == "string" and s:lower():find(q, 1, true) ~= nil
end

-- an item matches by its name, its winner or anyone who rolled on it
local function itemMatches(it, q)
	if has(linkName(it.link), q) or has(it.winner, q) then
		return true
	end
	for _, roll in ipairs(it.rolls or {}) do
		if has(roll.name, q) then
			return true
		end
	end
	return false
end

-- search: boss, zone, item names, winners, roll names, currency names
local function recMatches(r, q)
	if has(r.boss, q) or has(r.zone, q) or has(r.date, q) then
		return true
	end
	for _, it in ipairs(r.items) do
		if itemMatches(it, q) then
			return true
		end
	end
	for cid in pairs(r.cur) do
		if has(currencyName(cid), q) then
			return true
		end
	end
	return false
end

local function bestIcon(r)
	local best, bestQ
	for _, it in ipairs(r.items) do
		local q = qualityOf(it.link) or 0
		if not bestQ or q > bestQ then
			best, bestQ = it, q
		end
	end
	if best then
		return itemIcon(best.id)
	end
	local cid = next(r.cur)
	return cid and currencyIcon(cid) or SKULL
end

local function backdrop(f, bg, edge, size, inset)
	f:SetBackdrop({
		bgFile = bg,
		edgeFile = edge,
		tile = true,
		tileSize = 16,
		edgeSize = size,
		insets = { left = inset, right = inset, top = inset, bottom = inset },
	})
end

local function parchment(f, alpha)
	local t = f:CreateTexture(nil, "BACKGROUND", nil, -2)
	t:SetPoint("TOPLEFT", 3, -3)
	t:SetPoint("BOTTOMRIGHT", -3, 3)
	t:SetTexture("Interface\\QuestFrame\\QuestBG")
	t:SetVertexColor(1, 0.94, 0.82)
	t:SetAlpha(alpha)
	return t
end

local function panel(parent, bg, border)
	local p = CreateFrame("Frame", nil, parent, "BackdropTemplate")
	backdrop(p, WHITE, EDGE, 12, 3)
	p:SetBackdropColor(bg[1], bg[2], bg[3], 0.94)
	p:SetBackdropBorderColor(border[1], border[2], border[3], 1)
	parchment(p, 0.13)
	return p
end

local function line(parent, r, g, b, a)
	local t = parent:CreateTexture(nil, "ARTWORK")
	t:SetTexture(WHITE)
	t:SetColorTexture(r, g, b, a)
	t:SetHeight(1)
	return t
end

local function scroller(parent, name, width)
	local s = CreateFrame("ScrollFrame", name, parent, "UIPanelScrollFrameTemplate")
	local c = CreateFrame("Frame", nil, s)
	c:SetSize(width, 1)
	s:SetScrollChild(c)
	return s, c
end

local function textHeight(fs, fallback)
	local h = fs:GetStringHeight()
	return (type(h) == "number" and h > 0) and h or fallback
end

local function insertLink(link)
	local insert = (ChatFrameUtil and ChatFrameUtil.InsertLink) or ChatEdit_InsertLink
	if insert and link then
		insert(link)
	end
end

local refreshWindow

---------------------------------------------------------------------------------------------------------
-- rows
---------------------------------------------------------------------------------------------------------

local function rowButton(parent, w, h)
	local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
	b:SetSize(w, h)
	backdrop(b, WHITE, EDGE, 10, 2)
	b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	return b
end

-- activity card: dungeon art, zone, date, kill count; click folds it
local function makeActivityRow(parent)
	local b = rowButton(parent, 292, 50)
	b.art = b:CreateTexture(nil, "BACKGROUND", nil, 1)
	b.art:SetPoint("TOPLEFT", 3, -3)
	b.art:SetPoint("BOTTOMRIGHT", -3, 3)
	b.art:SetAlpha(0.55)
	b.shade = b:CreateTexture(nil, "BACKGROUND", nil, 2)
	b.shade:SetPoint("TOPLEFT", 3, -3)
	b.shade:SetPoint("BOTTOMRIGHT", -3, 3)
	b.shade:SetColorTexture(0, 0, 0, 0.35)
	b.fold = b:CreateTexture(nil, "ARTWORK")
	b.fold:SetSize(14, 14)
	b.fold:SetPoint("LEFT", 9, 0)
	b.zone = b:CreateFontString(nil, "OVERLAY", font("GameFontNormal"))
	b.zone:SetPoint("TOPLEFT", 30, -9)
	b.zone:SetPoint("RIGHT", -10, 0)
	b.zone:SetJustifyH("LEFT")
	b.zone:SetWordWrap(false)
	b.sub = b:CreateFontString(nil, "OVERLAY", font("GameFontHighlightSmall"))
	b.sub:SetPoint("TOPLEFT", b.zone, "BOTTOMLEFT", 0, -5)
	b.sub:SetPoint("RIGHT", -10, 0)
	b.sub:SetJustifyH("LEFT")
	b.sub:SetWordWrap(false)
	b:SetScript("OnClick", function(self)
		ui.open[self.key] = not ui.open[self.key]
		refreshWindow()
	end)
	b:SetScript("OnEnter", function(self)
		self.shade:SetColorTexture(0, 0, 0, 0.15)
	end)
	b:SetScript("OnLeave", function(self)
		self.shade:SetColorTexture(0, 0, 0, 0.35)
	end)
	return b
end

-- one kill: best item icon, boss, time and item count
local function makeKillRow(parent)
	local b = rowButton(parent, 280, 38)
	b.icon = b:CreateTexture(nil, "ARTWORK")
	b.icon:SetSize(28, 28)
	b.icon:SetPoint("LEFT", 6, 0)
	b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	b.name = b:CreateFontString(nil, "OVERLAY", font("GameFontNormal"))
	b.name:SetPoint("TOPLEFT", b.icon, "TOPRIGHT", 9, -1)
	b.name:SetPoint("RIGHT", -52, 0)
	b.name:SetJustifyH("LEFT")
	b.name:SetWordWrap(false)
	b.sub = b:CreateFontString(nil, "OVERLAY", font("GameFontHighlightSmall"))
	b.sub:SetPoint("TOPLEFT", b.name, "BOTTOMLEFT", 0, -3)
	b.sub:SetPoint("RIGHT", -10, 0)
	b.sub:SetJustifyH("LEFT")
	b.sub:SetWordWrap(false)
	b.time = b:CreateFontString(nil, "OVERLAY", font("GameFontHighlightSmall"))
	b.time:SetPoint("TOPRIGHT", -9, -7)
	b:SetScript("OnClick", function(self)
		ui.selected = self.rec
		refreshWindow()
	end)
	b:SetScript("OnEnter", function(self)
		self:SetBackdropColor(color(self.theme, "rowSelected"))
	end)
	b:SetScript("OnLeave", function(self)
		self:SetBackdropColor(color(self.theme, self.rec == ui.selected and "rowSelected" or "row"))
	end)
	return b
end

-- one item or currency in the details: icon, name, winner, rolls
local function makeLootRow(parent)
	local b = rowButton(parent, 412, 52)
	b.icon = b:CreateTexture(nil, "ARTWORK")
	b.icon:SetSize(36, 36)
	b.icon:SetPoint("TOPLEFT", 8, -8)
	b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	b.name = b:CreateFontString(nil, "OVERLAY", font("GameFontNormal"))
	b.name:SetPoint("TOPLEFT", b.icon, "TOPRIGHT", 10, -1)
	b.name:SetPoint("RIGHT", -10, 0)
	b.name:SetJustifyH("LEFT")
	b.name:SetWordWrap(false)
	b.winner = b:CreateFontString(nil, "OVERLAY", font("GameFontHighlightSmall"))
	b.winner:SetPoint("TOPLEFT", b.name, "BOTTOMLEFT", 0, -4)
	b.winner:SetPoint("RIGHT", -10, 0)
	b.winner:SetJustifyH("LEFT")
	b.winner:SetWordWrap(false)
	b.rolls = b:CreateFontString(nil, "OVERLAY", font("GameFontHighlightSmall"))
	b.rolls:SetPoint("TOPLEFT", b.winner, "BOTTOMLEFT", 0, -4)
	b.rolls:SetWidth(344)
	b.rolls:SetJustifyH("LEFT")
	b.rolls:SetWordWrap(true)
	b:SetScript("OnEnter", function(self)
		self:SetBackdropColor(color(self.theme, "rowSelected"))
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		if self.link then
			GameTooltip:SetHyperlink(self.link)
		elseif self.cid and GameTooltip.SetCurrencyByID then
			GameTooltip:SetCurrencyByID(self.cid)
		end
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", function(self)
		self:SetBackdropColor(color(self.theme, "lootRow"))
		GameTooltip:Hide()
	end)
	b:SetScript("OnClick", function(self)
		if IsModifiedClick and IsModifiedClick("CHATLINK") then
			insertLink(self.link)
		end
	end)
	return b
end

local function pooled(pool, make, parent, i)
	local b = pool[i]
	if not b then
		b = make(parent)
		pool[i] = b
	end
	b:Show()
	return b
end

local function hideFrom(pool, n)
	for i = n, #pool do
		pool[i]:Hide()
	end
end

local function styleRow(b, theme, field)
	b.theme = theme
	b:SetBackdropColor(color(theme, field))
	b:SetBackdropBorderColor(color(theme, "border"))
end

---------------------------------------------------------------------------------------------------------
-- filling the window
---------------------------------------------------------------------------------------------------------

local function fillList(acts, query)
	local y, nAct, nKill = 0, 0, 0
	ui.shownList = {}
	if query and not (ui.selected and recMatches(ui.selected, query)) then
		ui.selected = nil
		for _, act in ipairs(acts) do
			for i = #act.recs, 1, -1 do
				if recMatches(act.recs[i], query) then
					ui.selected = act.recs[i]
					break
				end
			end
			if ui.selected then
				break
			end
		end
	end
	for i, act in ipairs(acts) do
		local recs = act.recs
		if query then
			recs = {}
			for _, r in ipairs(act.recs) do
				if recMatches(r, query) then
					recs[#recs + 1] = r
				end
			end
		end
		if #recs > 0 then
			if ui.reveal then
				for _, r in ipairs(act.recs) do
					if r == ui.reveal then
						ui.open[act.key] = true
					end
				end
			end
			if ui.open[act.key] == nil then
				ui.open[act.key] = (i == 1)
			end
			local open = query ~= nil or ui.open[act.key]
			local theme = themeOf(act.zone)
			nAct = nAct + 1
			local h = pooled(ui.actRows, makeActivityRow, ui.listChild, nAct)
			h.key = act.key
			styleRow(h, theme, "header")
			local art, coords = artOf(act.zone)
			if art then
				h.art:SetTexture(art)
				if coords then
					h.art:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
				end
				h.art:Show()
			else
				h.art:Hide()
			end
			h.fold:SetTexture(open and "Interface\\Buttons\\UI-MinusButton-Up" or "Interface\\Buttons\\UI-PlusButton-Up")
			h.zone:SetText(act.zone or "Unknown place")
			h.zone:SetTextColor(color(theme, "title"))
			local first = act.recs[1]
			local span = ""
			if act.last - act.first >= 60 then
				span = "-" .. date("%H:%M", act.last)
			end
			h.sub:SetText((first.date or "?") .. span .. "  |  " .. #act.recs .. (#act.recs == 1 and " kill" or " kills"))
			h.sub:SetTextColor(color(theme, "text"))
			h:ClearAllPoints()
			h:SetPoint("TOPLEFT", 0, -y)
			y = y + 54
			ui.shownList[#ui.shownList + 1] = { kind = "activity", zone = act.zone, open = open }
			if open then
				for _, r in ipairs(recs) do
					nKill = nKill + 1
					local k = pooled(ui.killRows, makeKillRow, ui.listChild, nKill)
					k.rec = r
					styleRow(k, theme, r == ui.selected and "rowSelected" or "row")
					k.icon:SetTexture(bestIcon(r))
					k.name:SetText(r.boss or "?")
					k.name:SetTextColor(color(theme, "title"))
					local parts = {}
					if #r.items > 0 then
						parts[#parts + 1] = #r.items .. (#r.items == 1 and " item" or " items")
					end
					for cid, amount in pairs(r.cur) do
						parts[#parts + 1] = amount .. "x " .. currencyName(cid)
					end
					k.sub:SetText(#parts > 0 and table.concat(parts, ", ") or "no loot seen")
					k.sub:SetTextColor(color(theme, "muted"))
					k.time:SetText(r.time and date("%H:%M", r.time) or "")
					k.time:SetTextColor(color(theme, "muted"))
					k:ClearAllPoints()
					k:SetPoint("TOPLEFT", 12, -y)
					y = y + 41
					ui.shownList[#ui.shownList + 1] = { kind = "kill", boss = r.boss }
				end
			end
			y = y + 4
		end
	end
	ui.reveal = nil
	hideFrom(ui.actRows, nAct + 1)
	hideFrom(ui.killRows, nKill + 1)
	ui.listChild:SetHeight(math.max(1, y))
	ui.empty:SetShown(nAct == 0)
	ui.empty:SetText(query and "No kill matches." or "No kills logged yet.")
end

local function fillDetails()
	local r = ui.selected
	local d = ui.details
	ui.detailLines = {}
	if not r then
		d.boss:SetText("Loot Supervisor")
		d.sub:SetText("Pick a kill on the left.")
		d.stats:SetText("")
		d.art:Hide()
		hideFrom(ui.lootRows, 1)
		d.none:Hide()
		return
	end
	local theme = themeOf(r.zone)
	d.boss:SetText(r.boss or "?")
	d.boss:SetTextColor(color(theme, "title"))
	d.sub:SetText((r.zone or "Unknown place") .. "  |  " .. (r.date or "?"))
	d.sub:SetTextColor(color(theme, "text"))
	local nCur = 0
	for _ in pairs(r.cur) do
		nCur = nCur + 1
	end
	d.stats:SetText(#r.items .. (#r.items == 1 and " item" or " items") .. (nCur > 0 and ("  |  " .. nCur .. " currency") or ""))
	d.stats:SetTextColor(color(theme, "muted"))
	local art, coords = artOf(r.zone)
	if art then
		d.art:SetTexture(art)
		if coords then
			d.art:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
		end
		d.art:Show()
	else
		d.art:Hide()
	end

	-- searching an item or player: only the items that match (all of them when boss or place matches)
	local q = ui.query
	local items = r.items
	if q and not (has(r.boss, q) or has(r.zone, q) or has(r.date, q)) then
		items = {}
		for _, it in ipairs(r.items) do
			if itemMatches(it, q) then
				items[#items + 1] = it
			end
		end
		d.stats:SetText(#items .. " of " .. #r.items .. " items match '" .. q .. "'")
	end

	local y, n = 0, 0
	local function place(b, h)
		b:SetHeight(h)
		b:ClearAllPoints()
		b:SetPoint("TOPLEFT", 0, -y)
		y = y + h + 4
	end
	for _, it in ipairs(items) do
		n = n + 1
		local b = pooled(ui.lootRows, makeLootRow, ui.detailChild, n)
		styleRow(b, theme, "lootRow")
		b.link, b.cid = it.link or ("item:" .. it.id), nil
		b.icon:SetTexture(itemIcon(it.id))
		b.name:SetText(it.link or ("item " .. it.id))
		b.name:SetTextColor(color(theme, "title"))
		local who
		if it.winner == "all passed" then
			who = "All passed"
		elseif it.winner then
			who = "Won by " .. classColored(it.winner, it.winnerClass) .. (it.roll and ("  (" .. it.roll .. ")") or "")
		else
			who = "Winner not seen"
		end
		b.winner:SetText(who)
		b.winner:SetTextColor(color(theme, "text"))
		local rolls = rollsText(it.rolls, true)
		b.rolls:SetText(rolls or "")
		b.rolls:SetTextColor(color(theme, "muted"))
		local h = 8 + 14 + 4 + textHeight(b.winner, 12)
		if rolls then
			h = h + 4 + textHeight(b.rolls, 12)
		end
		place(b, math.max(52, h + 8))
		ui.detailLines[#ui.detailLines + 1] = (linkName(it.link) or tostring(it.id)) .. " > " .. who .. (rolls and (" ; " .. rolls) or "")
	end
	local cids = {}
	for cid in pairs(r.cur) do
		if items == r.items or has(currencyName(cid), q) then
			cids[#cids + 1] = cid
		end
	end
	table.sort(cids, function(a, b)
		return tostring(a) < tostring(b)
	end)
	for _, cid in ipairs(cids) do
		n = n + 1
		local b = pooled(ui.lootRows, makeLootRow, ui.detailChild, n)
		styleRow(b, theme, "lootRow")
		b.link, b.cid = nil, cid
		b.icon:SetTexture(currencyIcon(cid))
		b.name:SetText(r.cur[cid] .. "x " .. currencyName(cid))
		b.name:SetTextColor(color(theme, "title"))
		b.winner:SetText("Looted by you")
		b.winner:SetTextColor(color(theme, "text"))
		b.rolls:SetText("")
		place(b, 52)
		ui.detailLines[#ui.detailLines + 1] = r.cur[cid] .. "x " .. currencyName(cid)
	end
	hideFrom(ui.lootRows, n + 1)
	d.none:SetShown(n == 0)
	ui.detailChild:SetHeight(math.max(1, y))
end

---------------------------------------------------------------------------------------------------------
-- sortable tables: Items (every drop) and Currency (per boss); click a header to sort, again to reverse
---------------------------------------------------------------------------------------------------------

local ROW_H = 22
local TABLE_ROWS = 16
local SORT_ARROW = "Interface\\Buttons\\UI-SortArrow"

local ITEM_COLUMNS = {
	{ key = "time", title = "Date", width = 100 },
	{ key = "zone", title = "Instance", width = 130, asc = true },
	{ key = "boss", title = "Boss", width = 126, asc = true },
	{ key = "item", title = "Item", width = 222, asc = true, icon = true },
	{ key = "winner", title = "Winner", width = 118, asc = true },
	{ key = "roll", title = "Roll", width = 66 },
}

local CURRENCY_COLUMNS = {
	{ key = "boss", title = "Boss", width = 220, asc = true },
	{ key = "currency", title = "Currency", width = 250, asc = true, icon = true },
	{ key = "total", title = "Amount", width = 80 },
	{ key = "drops", title = "Drops", width = 70 },
	{ key = "kills", title = "Kills", width = 70 },
	{ key = "rate", title = "Rate", width = 72 },
}

local function lower(s)
	return type(s) == "string" and s:lower() or nil
end

-- the winner's own roll entry (for the roll kind)
local function winnerRoll(it)
	local key = it.winner and norm(it.winner)
	if not key then
		return nil
	end
	for _, r in ipairs(it.rolls or {}) do
		if sameName(norm(r.name), key) then
			return r
		end
	end
	return nil
end

-- one entry per item and per currency of every kill, filtered by the search
local function itemEntries(q)
	local out = {}
	for _, r in ipairs(DB.log) do
		local placeHit = q and (has(r.boss, q) or has(r.zone, q) or has(r.date, q))
		for _, it in ipairs(r.items) do
			if not q or placeHit or itemMatches(it, q) then
				local name = linkName(it.link) or ("item " .. it.id)
				local wr = winnerRoll(it)
				local roll = it.roll or (wr and wr.roll)
				local who, rollText = "", ""
				if it.winner == "all passed" then
					who = "All passed"
				elseif it.winner then
					who = classColored(it.winner, it.winnerClass or (wr and wr.class))
					rollText = ((wr and wr.kind) and (wr.kind .. " ") or "") .. (roll and tostring(roll) or "")
				end
				out[#out + 1] = {
					sort = {
						time = r.time or 0,
						zone = lower(r.zone),
						boss = lower(r.boss),
						item = name:lower(),
						winner = lower(it.winner),
						roll = roll,
					},
					cells = { r.date or "", r.zone or "", r.boss or "", it.link or name, who, rollText },
					icon = itemIcon(it.id),
					link = it.link or ("item:" .. it.id),
					rec = r,
				}
			end
		end
		for cid, amount in pairs(r.cur) do
			local name = currencyName(cid)
			if not q or placeHit or has(name, q) then
				out[#out + 1] = {
					sort = { time = r.time or 0, zone = lower(r.zone), boss = lower(r.boss), item = name:lower(), winner = "you" },
					cells = { r.date or "", r.zone or "", r.boss or "", amount .. "x " .. name, "You", "" },
					icon = currencyIcon(cid),
					cid = cid,
					rec = r,
				}
			end
		end
	end
	return out
end

local function currencyEntries(q)
	local out = {}
	for _, c in ipairs(currencyRows()) do
		local name = currencyName(c.cid)
		if not q or has(c.boss, q) or has(name, q) then
			local rate = c.kills > 0 and c.drops / c.kills or 0
			out[#out + 1] = {
				sort = {
					boss = c.boss:lower(),
					currency = name:lower(),
					total = c.total,
					drops = c.drops,
					kills = c.kills,
					rate = rate,
				},
				cells = { c.boss, name, tostring(c.total), tostring(c.drops), tostring(c.kills), math.floor(rate * 100 + 0.5) .. "%" },
				icon = currencyIcon(c.cid),
				cid = c.cid,
			}
		end
	end
	return out
end

-- missing values last; equal values keep the log order (newest first)
local function sortEntries(list, key, asc)
	for i, e in ipairs(list) do
		e.tie = i
	end
	table.sort(list, function(a, b)
		local x, y = a.sort[key], b.sort[key]
		if x == y then
			return a.tie > b.tie
		end
		if x == nil then
			return false
		end
		if y == nil then
			return true
		end
		if asc then
			return x < y
		end
		return x > y
	end)
end

local function makeTable(parent, name, columns, defaultKey)
	local t = { columns = columns, sortKey = defaultKey, asc = false, heads = {}, rows = {}, data = {} }
	t.frame = CreateFrame("Frame", nil, parent)
	t.frame:SetAllPoints(parent)

	local x = 0
	for i, col in ipairs(columns) do
		local h = CreateFrame("Button", nil, t.frame)
		h:SetSize(col.width, 20)
		h:SetPoint("TOPLEFT", 10 + x, -38)
		h.text = h:CreateFontString(nil, "OVERLAY", font("GameFontNormalSmall"))
		h.text:SetPoint("LEFT", 6, 0)
		h.text:SetText(col.title)
		h.arrow = h:CreateTexture(nil, "ARTWORK")
		h.arrow:SetSize(9, 8)
		h.arrow:SetPoint("LEFT", h.text, "RIGHT", 3, -1)
		h.arrow:SetTexture(SORT_ARROW)
		local hl = h:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints(h)
		hl:SetColorTexture(1, 0.82, 0.3, 0.12)
		h:SetScript("OnClick", function()
			if t.sortKey == col.key then
				t.asc = not t.asc
			else
				t.sortKey, t.asc = col.key, col.asc or false
			end
			local bar = _G[name .. "ScrollBar"] or t.scroll.ScrollBar
			if type(bar) == "table" and bar.SetValue then
				bar:SetValue(0)
			end
			t.scroll.offset = 0
			refreshWindow()
		end)
		t.heads[i] = h
		x = x + col.width
	end
	local under = line(t.frame, 0.68, 0.52, 0.20, 0.55)
	under:SetPoint("TOPLEFT", 10, -59)
	under:SetPoint("TOPRIGHT", -28, -59)

	t.scroll = CreateFrame("ScrollFrame", name, t.frame, "FauxScrollFrameTemplate")
	t.scroll:SetPoint("TOPLEFT", 10, -62)
	t.scroll:SetPoint("BOTTOMRIGHT", -28, 10)
	t.scroll:SetScript("OnVerticalScroll", function(self, offset)
		FauxScrollFrame_OnVerticalScroll(self, offset, ROW_H, t.draw)
	end)

	for i = 1, TABLE_ROWS do
		local row = CreateFrame("Button", nil, t.frame)
		row:SetSize(x, ROW_H)
		row:SetPoint("TOPLEFT", 10, -62 - (i - 1) * ROW_H)
		row:RegisterForClicks("LeftButtonUp")
		row.bg = row:CreateTexture(nil, "BACKGROUND")
		row.bg:SetAllPoints(row)
		row.bg:SetColorTexture(0, 0, 0, i % 2 == 0 and 0.2 or 0.07)
		local hl = row:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints(row)
		hl:SetColorTexture(1, 0.82, 0.3, 0.14)
		row.cells = {}
		local cx = 0
		for c, col in ipairs(columns) do
			local fs = row:CreateFontString(nil, "OVERLAY", font("GameFontHighlightSmall"))
			local pad = 6
			if col.icon then
				row.icon = row:CreateTexture(nil, "ARTWORK")
				row.icon:SetSize(16, 16)
				row.icon:SetPoint("LEFT", cx + 4, 0)
				row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
				pad = 24
			end
			fs:SetPoint("LEFT", cx + pad, 0)
			fs:SetWidth(col.width - pad - 4)
			fs:SetJustifyH("LEFT")
			fs:SetWordWrap(false)
			fs:SetTextColor(0.93, 0.84, 0.66)
			row.cells[c] = fs
			cx = cx + col.width
		end
		row:SetScript("OnEnter", function(self)
			local e = self.entry
			if not e then
				return
			end
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			if e.link then
				GameTooltip:SetHyperlink(e.link)
			elseif e.cid and GameTooltip.SetCurrencyByID then
				GameTooltip:SetCurrencyByID(e.cid)
			end
			if e.rec then
				GameTooltip:AddLine("Click: show this kill", 0.6, 0.6, 0.6)
			end
			GameTooltip:Show()
		end)
		row:SetScript("OnLeave", function()
			GameTooltip:Hide()
		end)
		row:SetScript("OnClick", function(self)
			local e = self.entry
			if not e then
				return
			end
			if IsModifiedClick and IsModifiedClick("CHATLINK") then
				insertLink(e.link)
			elseif e.rec then
				ui.mode = "log"
				ui.selected = e.rec
				ui.reveal = e.rec
				refreshWindow()
			end
		end)
		t.rows[i] = row
	end
	t.empty = t.frame:CreateFontString(nil, "OVERLAY", font("GameFontHighlight"))
	t.empty:SetPoint("TOP", 0, -90)

	t.draw = function()
		local offset = FauxScrollFrame_GetOffset(t.scroll)
		FauxScrollFrame_Update(t.scroll, #t.data, TABLE_ROWS, ROW_H)
		for i, row in ipairs(t.rows) do
			local e = t.data[offset + i]
			row.entry = e
			if e then
				for c, fs in ipairs(row.cells) do
					fs:SetText(e.cells[c] or "")
				end
				if row.icon then
					row.icon:SetTexture(e.icon or QUESTION)
				end
				row:Show()
			else
				row:Hide()
			end
		end
		for i, col in ipairs(columns) do
			local arrow = t.heads[i].arrow
			arrow:SetShown(col.key == t.sortKey)
			if t.asc then
				arrow:SetTexCoord(0, 0.5625, 1, 0)
			else
				arrow:SetTexCoord(0, 0.5625, 0, 1)
			end
		end
	end

	t.setData = function(data)
		sortEntries(data, t.sortKey, t.asc)
		t.data = data
		t.lines = {}
		for i, e in ipairs(data) do
			t.lines[i] = table.concat(e.cells, " | ")
		end
		local maxOffset = math.max(0, #data - TABLE_ROWS)
		if FauxScrollFrame_GetOffset(t.scroll) > maxOffset then
			t.scroll.offset = maxOffset
		end
		t.draw()
	end
	return t
end

-- what the window shows, to skip rebuilding when nothing changed
local function logSignature()
	local parts = { #DB.log, ui.mode, ui.query or "" }
	for i = math.max(1, #DB.log - 2), #DB.log do
		local r = DB.log[i]
		local rolls = 0
		for _, it in ipairs(r.items) do
			rolls = rolls + #(it.rolls or {}) + (it.winner and 1 or 0)
		end
		local cur = 0
		for _, v in pairs(r.cur) do
			cur = cur + v
		end
		parts[#parts + 1] = #r.items .. "/" .. rolls .. "/" .. cur
	end
	return table.concat(parts, ":")
end

refreshWindow = function()
	if not ui then
		return
	end
	local q = ui.query
	ui.logTab:SetEnabled(ui.mode ~= "log")
	ui.itemTab:SetEnabled(ui.mode ~= "items")
	ui.curTab:SetEnabled(ui.mode ~= "currency")
	if ui.mode == "items" or ui.mode == "currency" then
		local items = ui.mode == "items"
		ui.logPanels:Hide()
		ui.tablePanel:Show()
		ui.itemTable.frame:SetShown(items)
		ui.curTable.frame:SetShown(not items)
		ui.tableTitle:SetText(items and "All drops" or "Currency per boss")
		local t = items and ui.itemTable or ui.curTable
		t.setData(items and itemEntries(q) or currencyEntries(q))
		t.empty:SetShown(#t.data == 0)
		t.empty:SetText(q and "Nothing matches." or (items and "No drops logged yet." or "No currency drops logged yet."))
		local n = #t.data
		ui.count:SetText(n .. (items and (n == 1 and " drop" or " drops") or (n == 1 and " row" or " rows")))
	else
		ui.tablePanel:Hide()
		ui.logPanels:Show()
		if ui.selected == nil and #DB.log > 0 then
			ui.selected = DB.log[#DB.log]
		end
		local acts = activities()
		fillList(acts, q)
		fillDetails()
		ui.count:SetText(#DB.log .. (#DB.log == 1 and " kill" or " kills") .. "  |  " .. #acts .. (#acts == 1 and " activity" or " activities"))
	end
	ui.sig = logSignature()
end

---------------------------------------------------------------------------------------------------------
-- frame
---------------------------------------------------------------------------------------------------------

local function tabButton(parent, text, x)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b:SetSize(110, 24)
	b:SetPoint("TOPLEFT", x, -52)
	b:SetText(text)
	return b
end

local function buildWindow()
	ui = { open = {}, actRows = {}, killRows = {}, lootRows = {}, mode = "log" }
	local f = CreateFrame("Frame", "LootSupervisorFrame", UIParent, "BackdropTemplate")
	ui.frame = f
	f:SetSize(860, 560)
	f:SetPoint("CENTER", 0, 10)
	f:SetFrameStrata("DIALOG")
	f:SetClampedToScreen(true)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", function(self)
		self:StartMoving()
	end)
	f:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
	end)
	backdrop(f, "Interface\\FrameGeneral\\UI-Background-Rock", "Interface\\DialogFrame\\UI-DialogBox-Border", 24, 6)
	f:SetBackdropColor(0.045, 0.042, 0.037, 0.99)

	-- gold title strip
	local strip = f:CreateTexture(nil, "BACKGROUND")
	strip:SetTexture(WHITE)
	strip:SetColorTexture(0.14, 0.10, 0.055, 0.96)
	strip:SetPoint("TOPLEFT", 12, -10)
	strip:SetPoint("TOPRIGHT", -12, -10)
	strip:SetHeight(34)
	local l1 = line(f, 0.68, 0.52, 0.20, 0.65)
	l1:SetPoint("TOPLEFT", strip, "TOPLEFT")
	l1:SetPoint("TOPRIGHT", strip, "TOPRIGHT")
	local l2 = line(f, 0.68, 0.52, 0.20, 0.45)
	l2:SetPoint("BOTTOMLEFT", strip, "BOTTOMLEFT")
	l2:SetPoint("BOTTOMRIGHT", strip, "BOTTOMRIGHT")
	local title = f:CreateFontString(nil, "OVERLAY", font("GameFontNormalLarge"))
	title:SetPoint("TOP", 0, -18)
	title:SetText("Loot Supervisor")
	title:SetTextColor(0.96, 0.79, 0.25)
	local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -3, -3)

	-- tabs, count, search
	ui.logTab = tabButton(f, "Kill Log", 22)
	ui.itemTab = tabButton(f, "Items", 136)
	ui.curTab = tabButton(f, "Currency", 250)
	ui.itemTab:SetScript("OnClick", function()
		ui.mode = "items"
		refreshWindow()
	end)
	ui.logTab:SetScript("OnClick", function()
		ui.mode = "log"
		refreshWindow()
	end)
	ui.curTab:SetScript("OnClick", function()
		ui.mode = "currency"
		refreshWindow()
	end)
	ui.count = f:CreateFontString(nil, "OVERLAY", font("GameFontHighlightSmall"))
	ui.count:SetPoint("LEFT", ui.curTab, "RIGHT", 14, 0)
	ui.count:SetTextColor(0.82, 0.74, 0.60)

	local search = CreateFrame("EditBox", nil, f, "BackdropTemplate")
	ui.search = search
	search:SetSize(240, 24)
	search:SetPoint("TOPRIGHT", -24, -52)
	search:SetAutoFocus(false)
	search:SetFontObject(font("GameFontHighlight"))
	search:SetTextInsets(8, 22, 0, 0)
	backdrop(search, WHITE, EDGE, 10, 3)
	search:SetBackdropColor(0.08, 0.06, 0.035, 0.92)
	search:SetBackdropBorderColor(0.52, 0.36, 0.16, 1)
	local hint = search:CreateFontString(nil, "OVERLAY", font("GameFontDisableSmall"))
	hint:SetPoint("LEFT", 9, 0)
	hint:SetText("Search player or item")
	local clear = CreateFrame("Button", nil, search, "UIPanelCloseButton")
	clear:SetSize(20, 20)
	clear:SetPoint("RIGHT", -1, 0)
	clear:Hide()
	clear:SetScript("OnClick", function()
		search:SetText("")
		search:ClearFocus()
	end)
	search:SetScript("OnTextChanged", function(self)
		local text = (self:GetText() or ""):lower():match("^%s*(.-)%s*$")
		ui.query = text ~= "" and text or nil
		hint:SetShown(ui.query == nil)
		clear:SetShown(ui.query ~= nil)
		refreshWindow()
	end)
	search:SetScript("OnEscapePressed", search.ClearFocus)
	search:SetScript("OnEnterPressed", search.ClearFocus)

	-- content area
	local content = CreateFrame("Frame", nil, f, "BackdropTemplate")
	content:SetPoint("TOPLEFT", 18, -84)
	content:SetPoint("BOTTOMRIGHT", -18, 18)
	backdrop(content, WHITE, EDGE, 14, 4)
	content:SetBackdropColor(0.17, 0.12, 0.07, 0.96)
	content:SetBackdropBorderColor(0.47, 0.34, 0.16, 1)
	parchment(content, 0.18)

	ui.logPanels = CreateFrame("Frame", nil, content)
	ui.logPanels:SetAllPoints(content)

	-- left: activities with their kills
	local left = panel(ui.logPanels, { 0.19, 0.13, 0.07 }, { 0.39, 0.24, 0.08 })
	left:SetPoint("TOPLEFT", 12, -12)
	left:SetPoint("BOTTOMLEFT", 12, 12)
	left:SetWidth(334)
	local leftTitle = left:CreateFontString(nil, "OVERLAY", font("GameFontNormalLarge"))
	leftTitle:SetPoint("TOPLEFT", 12, -10)
	leftTitle:SetText("Activities")
	leftTitle:SetTextColor(0.96, 0.79, 0.25)
	local listScroll
	listScroll, ui.listChild = scroller(left, "LootSupervisorListScroll", 294)
	listScroll:SetPoint("TOPLEFT", 10, -38)
	listScroll:SetPoint("BOTTOMRIGHT", -28, 10)
	ui.empty = left:CreateFontString(nil, "OVERLAY", font("GameFontHighlight"))
	ui.empty:SetPoint("TOP", 0, -60)

	-- right: the picked kill
	local right = panel(ui.logPanels, { 0.21, 0.15, 0.08 }, { 0.42, 0.27, 0.10 })
	right:SetPoint("TOPLEFT", left, "TOPRIGHT", 12, 0)
	right:SetPoint("BOTTOMRIGHT", -12, 12)
	local d = {}
	ui.details = d
	d.art = right:CreateTexture(nil, "BACKGROUND", nil, -1)
	d.art:SetPoint("TOPLEFT", 4, -4)
	d.art:SetPoint("TOPRIGHT", -4, -4)
	d.art:SetHeight(92)
	d.art:SetAlpha(0.4)
	d.boss = right:CreateFontString(nil, "OVERLAY", font("GameFontNormalHuge"))
	d.boss:SetPoint("TOPLEFT", 16, -16)
	d.boss:SetPoint("RIGHT", -16, 0)
	d.boss:SetJustifyH("LEFT")
	d.boss:SetWordWrap(false)
	d.sub = right:CreateFontString(nil, "OVERLAY", font("GameFontHighlight"))
	d.sub:SetPoint("TOPLEFT", d.boss, "BOTTOMLEFT", 0, -8)
	d.sub:SetPoint("RIGHT", -16, 0)
	d.sub:SetJustifyH("LEFT")
	d.stats = right:CreateFontString(nil, "OVERLAY", font("GameFontHighlightSmall"))
	d.stats:SetPoint("TOPLEFT", d.sub, "BOTTOMLEFT", 0, -6)
	local divider = line(right, 0.48, 0.34, 0.16, 0.75)
	divider:SetPoint("TOPLEFT", 12, -98)
	divider:SetPoint("TOPRIGHT", -12, -98)
	local detailScroll
	detailScroll, ui.detailChild = scroller(right, "LootSupervisorDetailScroll", 412)
	detailScroll:SetPoint("TOPLEFT", 10, -106)
	detailScroll:SetPoint("BOTTOMRIGHT", -28, 10)
	d.none = right:CreateFontString(nil, "OVERLAY", font("GameFontHighlight"))
	d.none:SetPoint("TOP", 0, -130)
	d.none:SetText("No loot seen for this kill.")

	-- Items and Currency tabs: one full-width panel with a sortable table each
	ui.tablePanel = panel(content, { 0.19, 0.13, 0.07 }, { 0.39, 0.24, 0.08 })
	ui.tablePanel:SetPoint("TOPLEFT", 12, -12)
	ui.tablePanel:SetPoint("BOTTOMRIGHT", -12, 12)
	ui.tableTitle = ui.tablePanel:CreateFontString(nil, "OVERLAY", font("GameFontNormalLarge"))
	ui.tableTitle:SetPoint("TOPLEFT", 12, -10)
	ui.tableTitle:SetTextColor(0.96, 0.79, 0.25)
	local sortHint = ui.tablePanel:CreateFontString(nil, "OVERLAY", font("GameFontHighlightSmall"))
	sortHint:SetPoint("TOPRIGHT", -32, -14)
	sortHint:SetText("Click a column to sort")
	sortHint:SetTextColor(0.82, 0.74, 0.60)
	ui.itemTable = makeTable(ui.tablePanel, "LootSupervisorItemTable", ITEM_COLUMNS, "time")
	ui.curTable = makeTable(ui.tablePanel, "LootSupervisorCurrencyTable", CURRENCY_COLUMNS, "total")
	ui.tablePanel:Hide()

	f:SetScript("OnShow", refreshWindow)
	f:Hide()
end

local function toggleWindow(mode)
	if not ui then
		buildWindow()
	end
	if mode then
		ui.mode = mode
	end
	if ui.frame:IsShown() and not mode then
		ui.frame:Hide()
	else
		ui.frame:Show()
		refreshWindow()
	end
end

-- called from the 1 s ticker: new kills and rolls show up while the window is open
local function windowTick()
	if ui and ui.frame:IsShown() and logSignature() ~= ui.sig then
		refreshWindow()
	end
end

onTick = windowTick

function LootSupervisor_OnAddonCompartmentClick()
	toggleWindow()
end

SLASH_LOOTSUPERVISOR1 = "/lsup"
SLASH_LOOTSUPERVISOR2 = "/lootsupervisor"
SlashCmdList.LOOTSUPERVISOR = function(input)
	local cmd, arg = (input or ""):lower():match("^%s*(%S*)%s*(.-)%s*$")
	if cmd == "" or cmd == "window" then
		toggleWindow()
	elseif cmd == "list" or cmd == "currency" then
		list()
	elseif cmd == "log" then
		local n = tonumber(arg)
		showLog(n or (arg == "" and 5 or 20), (not n and arg ~= "") and arg or nil)
	elseif cmd == "whisper" and (arg == "all" or arg == "addon" or arg == "off") then
		DB.whisper = arg
		say("whisper: " .. arg)
	elseif cmd == "hint" and (arg == "known" or arg == "all" or arg == "off") then
		DB.hint = arg
		say("reminder: " .. arg)
	elseif cmd == "delay" and tonumber(arg) then
		DB.delay = math.max(5, math.min(120, tonumber(arg)))
		say("whisper delay: " .. DB.delay .. " s")
	elseif cmd == "test" then
		local cid = next(DB.currencies)
		showHint({ test = true }, "Test Boss", cid and { [cid] = 2 } or {}, 15)
		say("reminder shown. Drag to move, right-click to close.")
	else
		say("/lsup - log window")
		say("/lsup currency - drops per boss")
		say("/lsup log [n|boss] - kills in chat")
		say("/lsup whisper addon|all|off (now " .. DB.whisper .. ")")
		say("/lsup hint known|all|off (now " .. DB.hint .. ")")
		say("/lsup delay <s> (now " .. DB.delay .. ")")
		say("/lsup test - show the reminder")
	end
end

-- test hook
LootSupervisor_Internal = {
	kills = kills,
	addonUsers = addonUsers,
	tick = tick,
	activities = activities,
	toggleWindow = toggleWindow,
	ui = function()
		return ui
	end,
}
