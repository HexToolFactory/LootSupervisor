-- Loot Supervisor: logs boss kills (items, winners), currency drops per boss, shows a loot reminder after a kill and whispers group
-- members who have not looted a currency boss after a delay (default 15 s).

local ADDON_NAME = ...
local PREFIX = "LootSup"
local VERSION = "0.3.1"
local KILL_WINDOW = 180 -- seconds a kill stays open for loot and whispers
local HINT_TIME = 120 -- seconds the reminder stays up after a kill
local TARGET_HINT_TIME = 20 -- seconds for a reminder raised by targeting a corpse
local SEND_RETRY = 60 -- seconds a blocked message is retried

local DB
local DEFAULTS = { whisper = "all", hint = "known", delay = 15 }

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
local function addRoll(it, name, kind, roll)
	local key = norm(name)
	if not key then
		return
	end
	it.rolls = it.rolls or {}
	for _, r in ipairs(it.rolls) do
		if sameName(norm(r.name), key) then
			r.kind = kind or r.kind
			r.roll = roll or r.roll
			return
		end
	end
	it.rolls[#it.rolls + 1] = { name = name, kind = kind, roll = roll }
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
		it.roll = plain(winner.roll)
		it.how = "roll"
	end
	if type(info.rollInfos) == "table" then
		for _, r in ipairs(info.rollInfos) do
			if type(r) == "table" then
				local name = plain(r.playerName)
				if name then
					addRoll(it, name, ROLL_STATE[plain(r.state)] or "?", plain(r.roll))
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
local function knownCurs(e)
	local curs = {}
	for cid, c in pairs(e and e.cur or {}) do
		curs[cid] = c.last or true
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
			if k.enc and next(k.npcs) == nil and now() - k.t <= 60 then
				if (name and k.name and norm(name) == norm(k.name)) or isBossCorpse(c.guid) then
					k.npcs[c.npc] = true
					DB.links[c.npc] = k.key
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
		cid = e and next(e.cur)
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
	local t = now()
	-- whispers
	for _, k in ipairs(kills) do
		if not k.whisperDone and t - k.t >= DB.delay then
			local e = DB.bosses[k.key]
			local known = k.hasCur or (not k.selfLooted and hasCur(e))
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
				k.npcs[id] = true
				DB.links[id] = key
			end
		end
	end
	for npc, link in pairs(DB.links) do
		if link == key then
			k.npcs[npc] = true
		end
	end
	applyRecent(k)
	if DB.hint == "all" or (DB.hint == "known" and hasCur(e)) then
		showHint(k, e.name, knownCurs(e))
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
		DB.diag = DB.diag or {}
		DB.diag.encounters = DB.diag.encounters or {}
		DB.diag.history = DB.diag.history or {}
		dedupeLog()
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
	if event == "ENCOUNTER_END" then
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
		hello(false)
	end
end)

---------------------------------------------------------------------------------------------------------
-- /lsup
---------------------------------------------------------------------------------------------------------

local function list()
	local rows = {}
	for key, e in pairs(DB.bosses) do
		if hasCur(e) then
			for cid, d in pairs(e.cur) do
				rows[#rows + 1] = string.format(
					"%s: %dx %s in %d/%d kills",
					e.name or key,
					d.total,
					currencyName(cid),
					d.drops,
					math.max(e.kills, e.loots, d.drops)
				)
			end
		end
	end
	table.sort(rows)
	if #rows == 0 then
		say("no currency drops logged yet.")
		return
	end
	for _, row in ipairs(rows) do
		say(row)
	end
end

-- "Need: Anna Berg 87, Bob Stone 45 | Greed: Cid 12 | Pass: 3": highest roll first, many passes as a count
local ROLL_ORDER = { "Need", "Need (off)", "Greed", "Transmog", "Disenchant", "Pass", "No roll", "?" }
local function rollsText(rolls)
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
					names[#names + 1] = r.name .. (r.roll and (" " .. r.roll) or "")
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

SLASH_LOOTSUPERVISOR1 = "/lsup"
SLASH_LOOTSUPERVISOR2 = "/lootsupervisor"
SlashCmdList.LOOTSUPERVISOR = function(input)
	local cmd, arg = (input or ""):lower():match("^%s*(%S*)%s*(.-)%s*$")
	if cmd == "" or cmd == "list" then
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
		say("/lsup - drops per boss")
		say("/lsup log [n|boss] - kills, items, winners")
		say("/lsup whisper all|addon|off (now " .. DB.whisper .. ")")
		say("/lsup hint known|all|off (now " .. DB.hint .. ")")
		say("/lsup delay <s> (now " .. DB.delay .. ")")
		say("/lsup test - show the reminder")
	end
end

-- test hook
LootSupervisor_Internal = { kills = kills, addonUsers = addonUsers, tick = tick }
