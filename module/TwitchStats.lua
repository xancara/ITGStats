-- TwitchStats.lua -- drop-in Simply Love module streaming live session stats to the
-- ITG Stats Twitch extension backend.
--
-- For use with ITGStats extension v0.1.0 on Twitch
--
-- Install: copy into Themes/Simply Love/Modules/, put your key in Save/TwitchStats.ini
-- (copy it from the extension config page), and add the stats host to
-- HttpAllowHosts in Save/Preferences.ini. Full guide: docs/INSTALL-STREAMER.md.
--
-- Requires ITGmania >= 1.2.0 and Simply Love >= 5.8.1.
-- 

local MODULE_VERSION = "0.1.1"
local PROTOCOL_VERSION = 1
local INI_PATH = "Save/TwitchStats.ini"
local PROGRESS_MIN_INTERVAL = 2.0 -- seconds
local MAX_QUEUE = 50 -- 
local MAX_QUEUED_DETAILS = 5 -- 

-- ------------------------------------------------------------------------
-- state (locals only; modules must not pollute the global namespace

local config = nil -- { apiKey, url, sendProgress, shareProfileNames }
local initialized = false
local dormant = false

local ws = nil
local connected = false
local authFailures = 0
local lastOpenClock = nil -- when the socket last opened (rapid-cycle detection)
local quickFails = 0 -- consecutive closes within seconds of opening
local queue = {} -- { {t=<type>, body=<encoded frame>} ... }

local QUICK_FAIL_WINDOW = 5 -- seconds: a close this soon after open counts as a failure
local QUICK_FAIL_LIMIT = 10 -- consecutive quick failures before going dormant

local session = nil -- { id, startClock, playersKey, play, restartTotals }
local current = nil -- per-play state, see OnGameplayStart
local prevScreen, curScreen = "", ""
local lastProgressClock = -math.huge

local statusActor = nil -- BitmapText indicator on ScreenSelectMusic (set in InitCommand)

-- ------------------------------------------------------------------------
-- small helpers

local function Log(text)
	Trace("[TwitchStats] " .. tostring(text))
end

local function Announce(text)
	SCREENMAN:SystemMessage("TwitchStats: " .. tostring(text))
end

-- Every entry point is wrapped so a stats/network problem can never crash a screen.
local function Safely(fn)
	local ok, err = pcall(fn)
	if not ok then
		Log("error: " .. tostring(err))
	end
end

-- ITGmania Lua has no os library; the only clock is monotonic seconds since app
-- start. Envelope ts is therefore monotonic.
local function Clock()
	return GetTimeSinceStart()
end

local function Round(value, places)
	local mult = 10 ^ (places or 0)
	if value >= 0 then
		return math.floor(value * mult + 0.5) / mult
	end
	return math.ceil(value * mult - 0.5) / mult
end

local function Truncate(s, max)
	s = tostring(s or "")
	if #s > max then
		return s:sub(1, max)
	end
	return s
end

local function PlayerEnum(pn)
	return (pn == "P1") and PLAYER_1 or PLAYER_2
end

-- "P1"/"P2" for each joined side (pattern: SL-OnlineHelpers GetMachineState)
local function JoinedPlayers()
	local list = {}
	for _, player in ipairs(GAMESTATE:GetHumanPlayers()) do
		list[#list + 1] = ToEnumShortString(player)
	end
	return list
end

-- ------------------------------------------------------------------------
-- on-screen connection indicator (song wheel only): green = connected,
-- yellow = connecting/retrying (native backoff), red = dormant. Opt-in via the hidden
-- ini Debug flag -- hidden by default (and always when no ini exists) so a healthy
-- install adds no song-wheel clutter; turn it on only to troubleshoot the connection.

local STATUS_COLORS = {
	connected = { 0.25, 0.9, 0.45, 0.85 },
	connecting = { 1.0, 0.8, 0.25, 0.85 },
	off = { 1.0, 0.4, 0.4, 0.85 },
}

local function StatusState()
	if dormant then
		return "off", "TwitchStats: off"
	end
	if connected then
		return "connected", "TwitchStats: connected"
	end
	return "connecting", "TwitchStats: connecting..."
end

local function UpdateStatus()
	if not statusActor then
		return
	end
	-- Indicator is opt-in via the hidden ini Debug flag (config.debug); hidden otherwise
	-- so a working install shows no extra UI on the song wheel.
	if not config or not config.debug or curScreen ~= "ScreenSelectMusic" then
		statusActor:visible(false)
		return
	end
	local state, text = StatusState()
	local c = STATUS_COLORS[state]
	statusActor:visible(true)
	statusActor:settext(text)
	statusActor:diffuse(c[1], c[2], c[3], c[4])
end

-- songId: first 16 hex chars of SHA-256 over
-- pack \n title \n stepstype \n difficulty (untruncated, lowercased enums).
-- SHA256String returns the raw 32-byte digest, not hex -- BinaryToHex
-- (engine global, lowercase output) makes it printable.
local function ChartSongId(song, steps)
	local input = (song:GetGroupName() or "")
		.. "\n" .. (song:GetDisplayMainTitle() or "")
		.. "\n" .. ToEnumShortString(steps:GetStepsType()):lower()
		.. "\n" .. ToEnumShortString(steps:GetDifficulty()):lower()
	return BinaryToHex(CRYPTMAN:SHA256String(input)):sub(1, 16)
end

-- ------------------------------------------------------------------------
-- config (IniFile.ReadFile from _fallback; values are type-coerced, so
-- SendProgress=1 arrives as the number 1)

local function LoadConfig()
	if type(IniFile) ~= "table" or type(IniFile.ReadFile) ~= "function" then
		return nil, "theme is missing the IniFile helper (unsupported install)"
	end
	local ini = IniFile.ReadFile(INI_PATH)
	local section = type(ini) == "table" and ini.TwitchStats or nil
	if type(section) ~= "table" then
		return nil, "no " .. INI_PATH .. " found. Download one from the extension config page on Twitch."
	end
	if type(section.ApiKey) ~= "string" or section.ApiKey == ""
		or type(section.Url) ~= "string" or section.Url == "" then
		return nil, INI_PATH .. " is missing ApiKey or Url. Re-download it from the extension config page."
	end
	return {
		apiKey = section.ApiKey,
		url = section.Url,
		sendProgress = (section.SendProgress == 1 or section.SendProgress == true),
		shareProfileNames = (section.ShareProfileNames == 1 or section.ShareProfileNames == true),
		-- Hidden, hand-added flag (the config page never writes it): shows the song-wheel
		-- connection indicator. Absent/false => hidden, so a healthy install adds no UI.
		-- Accept either case since it's typed by hand; IniFile coerces true/1 for us.
		debug = (section.Debug == 1 or section.Debug == true
			or section.debug == 1 or section.debug == true),
	}
end

local function Init()
	if initialized then
		return
	end
	initialized = true
	local cfg, err = LoadConfig()
	if not cfg then
		dormant = true
		Announce(err)
		Log("dormant: " .. err)
		return
	end
	config = cfg
end

-- ------------------------------------------------------------------------
-- outbound queue + send

local function QueuePush(msgType, body)
	queue[#queue + 1] = { t = msgType, body = body }

	-- keep only the newest MAX_QUEUED_DETAILS song_detail messages
	local details = 0
	for i = #queue, 1, -1 do
		if queue[i].t == "song_detail" then
			details = details + 1
			if details > MAX_QUEUED_DETAILS then
				table.remove(queue, i)
			end
		end
	end

	-- bounded queue: drop oldest progress first, then oldest anything
	while #queue > MAX_QUEUE do
		local idx = 1
		for i = 1, #queue do
			if queue[i].t == "progress" then
				idx = i
				break
			end
		end
		table.remove(queue, idx)
	end
end

local function Encode(msgType, data)
	return JsonEncode({ v = PROTOCOL_VERSION, type = msgType, ts = math.floor(Clock()), data = data }, true)
end

local function Emit(msgType, data)
	if dormant or not config then
		return
	end
	local body = Encode(msgType, data)
	if connected and ws then
		if ws:Send(body) then
			return
		end
		connected = false -- failed send: treat as disconnected, queue it
	end
	QueuePush(msgType, body)
end

-- ------------------------------------------------------------------------
-- session lifecycle

local function ProfileNames(players)
	if not config.shareProfileNames then
		return nil
	end
	local names = nil
	for _, pn in ipairs(players) do
		local player = PlayerEnum(pn)
		-- pattern: (ScreenEvaluation Storage.lua:28-32)
		if PROFILEMAN:IsPersistentProfile(player) then
			local profile = PROFILEMAN:GetProfile(player)
			local name = profile and profile:GetDisplayName()
			if type(name) == "string" and name ~= "" then
				names = names or {}
				names[pn] = Truncate(name, 32)
			end
		end
	end
	return names
end

local function PlayersKey(players, names)
	local key = table.concat(players, ",")
	if names then
		for _, pn in ipairs(players) do
			key = key .. ";" .. pn .. "=" .. (names[pn] or "")
		end
	end
	return key
end

local function SessionStartData()
	local players = JoinedPlayers()
	local names = ProfileNames(players)
	session.playersKey = PlayersKey(players, names)
	local data = { sessionId = session.id, players = players }
	if names then
		data.profileNames = names
	end
	return data
end

local function StartSession()
	session = {
		id = CRYPTMAN:GenerateRandomUUID(),
		startClock = Clock(),
		playersKey = "",
		play = 0,
		restartTotals = {},
	}
	current = nil
	Emit("session_start", SessionStartData())
end

local function SyncPlayers()
	if not session then
		return
	end
	local players = JoinedPlayers()
	if #players == 0 then
		return
	end
	-- Key includes profile names so a profile switch on the same pads (new card
	-- on P2 etc.) also announces -- the overlay groups scores per profile.
	local names = ProfileNames(players)
	local key = PlayersKey(players, names)
	if key ~= session.playersKey then
		session.playersKey = key
		local data = { players = players }
		if names then
			data.profileNames = names
		end
		Emit("players_changed", data)
	end
end

local function EmitSummary()
	if not session then
		return
	end
	local per = {}
	local any = false
	for pn, total in pairs(session.restartTotals) do
		per[pn] = { totalRestarts = total }
		any = true
	end
	for _, pn in ipairs(JoinedPlayers()) do
		if not per[pn] then
			per[pn] = { totalRestarts = 0 }
			any = true
		end
	end
	if not any then
		per.P1 = { totalRestarts = 0 } -- schema requires at least one player
	end
	Emit("session_summary", {
		durationSec = math.floor(Clock() - session.startClock + 0.5),
		perPlayer = per,
	})
end

local function EndSession(reason)
	if not session then
		return
	end
	EmitSummary()
	Emit("session_end", { reason = reason })
	session, current = nil, nil
end

-- ------------------------------------------------------------------------
-- connection (NETWORK:WebSocket; reconnection/backoff is native via
-- automaticReconnect; close *reason strings* are the contract -- the binding does
-- not expose close codes to Lua)

local function GoDormant(message, quiet)
	if dormant then
		return
	end
	dormant = true
	connected = false
	if ws then
		ws:Close() -- stops native auto-reconnection
		ws = nil
	end
	if not quiet then
		Announce(message)
	end
	Log("dormant: " .. tostring(message))
	UpdateStatus()
end

local DORMANT_REASONS = {
	["invalid key"] = "API key rejected. Generate new TwitchStats.ini from the extension config page.",
	["key revoked"] = "API key was revoked. Generate a new key on the extension config page.",
	["key rotated"] = "API key was rotated. Update Save/TwitchStats.ini with the new key.",
	["unsupported protocol version"] = "this module version is too old. Download the latest TwitchStats.lua.",
}

local function OnSocketMessage(msg)
	if dormant then
		return
	end
	local kind = ToEnumShortString(msg.type)

	if kind == "Open" then
		connected = true
		authFailures = 0
		lastOpenClock = Clock()
		-- hello first, then a fresh session_start, then the queued backlog
		ws:Send(Encode("hello", {
			apiKey = config.apiKey,
			slVersion = tostring(GetThemeVersion()),
			itgVersion = tostring(ProductVersion()),
			moduleVersion = MODULE_VERSION,
		}))
		if session then
			ws:Send(Encode("session_start", SessionStartData()))
		end
		local pending = queue
		queue = {}
		for _, item in ipairs(pending) do
			if not (connected and ws and ws:Send(item.body)) then
				QueuePush(item.t, item.body)
			end
		end

	elseif kind == "Close" then
		connected = false
		local reason = tostring(msg.reason or "")
		if reason == "superseded by newer connection" then
			-- another machine took over this channel: stop quietly
			GoDormant("superseded by a newer connection", true)
		elseif DORMANT_REASONS[reason] then
			authFailures = authFailures + 1
			if authFailures >= 3 or reason == "unsupported protocol version" then
				GoDormant(DORMANT_REASONS[reason])
			end
		elseif lastOpenClock and (Clock() - lastOpenClock) < QUICK_FAIL_WINDOW then
			-- Close reason strings can be stripped by proxies in production, 
			-- so reason-based dormancy alone is not enough.
			-- A connection that the server accepts and then drops within seconds, many
			-- times in a row, is a rejection loop -- stop hammering the server.
			quickFails = quickFails + 1
			if quickFails >= QUICK_FAIL_LIMIT then
				GoDormant("the stats server keeps rejecting the connection. Re-copy TwitchStats.ini from the extension config page, then restart ITGmania.")
			end
		else
			quickFails = 0 -- the connection lived a while: genuine drop, let it retry
		end
		-- other closes: native automaticReconnect retries with backoff

	elseif kind == "Error" then
		connected = false
		local reason = tostring(msg.reason or "")
		-- blocked by the HttpAllowHosts allowlist: actionable + dormant
		if reason:find("not allowed", 1, true) then
			GoDormant("ITGmania blocked the connection. Add the stats server host to HttpAllowHosts in Save/Preferences.ini.")
		end
	end
	-- "Message" frames from the EBS are ignored in protocol v1
	UpdateStatus()
end

local function EnsureConnected()
	if dormant or ws ~= nil or not config then
		return
	end
	if type(NETWORK) ~= "userdata" and type(NETWORK) ~= "table" then
		GoDormant("this ITGmania build has no NETWORK API (need ITGmania 1.2+).")
		return
	end
	ws = NETWORK:WebSocket{
		url = config.url,
		pingInterval = 15, -- lobby client pattern
		automaticReconnect = true,
		onMessage = function(msg)
			Safely(function()
				OnSocketMessage(msg)
			end)
		end,
	}
	-- nil return = URL not allow-listed; the Error callback may have
	-- already gone dormant with the actionable message -- this is the backstop.
	if ws == nil then
		GoDormant("ITGmania blocked the connection. Add the stats server host to HttpAllowHosts in Save/Preferences.ini.")
	end
end

-- ------------------------------------------------------------------------
-- gameplay: song_start / song_restart (restart heuristic)

local function OnGameplayStart()
	Init()
	if dormant or not config then
		return
	end
	-- course mode and demonstration/attract never record
	if GAMESTATE:IsCourseMode() or GAMESTATE:IsDemonstration() then
		return
	end
	EnsureConnected()
	if not session then
		StartSession()
	else
		SyncPlayers()
	end

	local song = GAMESTATE:GetCurrentSong()
	if not song then
		return
	end

	local players = JoinedPlayers()
	local perPlayer, charts, songIds = {}, {}, {}
	local topSongId = nil
	for _, pn in ipairs(players) do
		local steps = GAMESTATE:GetCurrentSteps(PlayerEnum(pn))
		if steps then
			local id = ChartSongId(song, steps)
			local entry = {
				songId = id,
				stepsType = ToEnumShortString(steps:GetStepsType()):lower(),
				difficulty = ToEnumShortString(steps:GetDifficulty()):lower(),
				meter = steps:GetMeter(),
			}
			-- GrooveStats v3 chart hash when SL has parsed one
			local hash = SL[pn] and SL[pn].Streams and SL[pn].Streams.Hash
			if type(hash) == "string" and hash ~= "" then
				entry.chartHash = hash
			end
			perPlayer[pn] = entry
			charts[pn] = steps
			songIds[pn] = id
			topSongId = topSongId or id
		end
	end
	if topSongId == nil then
		return
	end

	-- Restart rule: a restart is only an *in-gameplay* retry (Ctrl+R during
	-- ScreenGameplay), which happens BEFORE the play finishes — so the current play is
	-- the same chart and is ~not yet completed~. A replay launched from the
	-- evaluation screen happens AFTER the play finished (OnEvaluation set
	-- current.completed), so it is a fresh play of the same song (new play number), as
	-- is a manual re-pick from the music wheel. Completion state is used rather than
	-- screen-transition flags because ITGmania fires ModuleCommand a frame late
	-- (queuecommand), making the screen flags unreliable for this distinction.
	local isRestart = current ~= nil
		and current.topSongId == topSongId
		and not current.completed

	local rate = (SL.Global.ActiveModifiers and SL.Global.ActiveModifiers.MusicRate) or 1.0

	if isRestart then
		current.restartCount = current.restartCount + 1
		for _, pn in ipairs(players) do
			session.restartTotals[pn] = (session.restartTotals[pn] or 0) + 1
		end
		Emit("song_restart", { songId = topSongId, restartCount = current.restartCount })
	else
		session.play = session.play + 1
		current = { play = session.play, topSongId = topSongId, restartCount = 0 }
		Emit("song_start", {
			play = current.play,
			songId = topSongId,
			title = Truncate(song:GetDisplayMainTitle(), 80),
			artist = Truncate(song:GetDisplayArtist(), 80),
			pack = Truncate(song:GetGroupName(), 80),
			rate = rate,
			perPlayer = perPlayer,
		})
	end

	-- per-play capture (fresh on every attempt; SL recreates its stage storage on
	-- each ScreenGameplay load)
	current.song = song
	current.rate = rate
	current.charts = charts
	current.songIds = songIds
	current.completed = false
	current.storage = {}
	current.progress = {}
	for _, pn in ipairs(players) do
		if SL[pn] and SL[pn].Stages and SL.Global.Stages then
			current.storage[pn] = SL[pn].Stages.Stats[SL.Global.Stages.PlayedThisGame + 1]
		end
		current.progress[pn] = { W0 = 0, W1 = 0, W2 = 0, W3 = 0, W4 = 0, W5 = 0, Miss = 0, notesHit = 0 }
	end
end

-- ------------------------------------------------------------------------
-- live progress from engine Judgment broadcasts (optional per ini)

local function ProgressJudgments(counts)
	return {
		W0 = counts.W0, W1 = counts.W1, W2 = counts.W2, W3 = counts.W3,
		W4 = counts.W4, W5 = counts.W5, Miss = counts.Miss,
	}
end

-- Live progress score. When a player has Simply Love's "Display EX Score" enabled
-- (SL[pn].ActiveModifiers.ShowExScore), the score on their gameplay screen is the running
-- EX percent (CalculateExScore reads the same ex_counts SL tracks every judgment), so the
-- live feed must match it -- otherwise the overlay shows a different number than the one on
-- the streamer's screen. The setting is per-player, so each side resolves independently;
-- fall back to the ITG percent (GetPercentDancePoints x100) when EX doesn't apply. EX is
-- unavailable in Casual mode (CalculateExScore returns 0 there), so force the ITG percent.
-- NOTE: v1 does NOT tag which scoring system a progress score uses -- the EBS/overlay still
-- treat it as a plain percent, and a completed row reverts to the ITG song_complete.score.
-- Marking EX vs ITG (and labelling it in the overlay) is staged for v0.2.0; see
-- docs/deferred-work.md.
local function ProgressScore(pn, pss)
	if SL.Global.GameMode ~= "Casual" then
		local mods = SL[pn] and SL[pn].ActiveModifiers
		if mods and mods.ShowExScore then
			local ok, ex = pcall(CalculateExScore, PlayerEnum(pn))
			if ok and type(ex) == "number" then
				return Round(ex, 2)
			end
		end
	end
	return Round(pss:GetPercentDancePoints() * 100, 2)
end

local function OnJudgment(params)
	if dormant or not config or not config.sendProgress then
		return
	end
	if not session or not current or current.completed then
		return
	end
	-- module actors hear every broadcast on every screen: gate hard
	if curScreen ~= "ScreenGameplay" then
		return
	end
	if not params or not params.Player or not params.TapNoteScore then
		return
	end
	if params.HoldNoteScore then
		return -- hold judgments don't carry tap offsets
	end

	local tns = ToEnumShortString(params.TapNoteScore)
	local pn = ToEnumShortString(params.Player)
	local p = current.progress[pn]
	if not p then
		return
	end

	if tns == "Miss" then
		p.Miss = p.Miss + 1
	elseif p[tns] ~= nil then
		-- FA+ split via SL's own helper when available
		if tns == "W1" and SL.Global.GameMode == "ITG"
			and type(IsW0Judgment) == "function" and IsW0Judgment(params, params.Player) then
			p.W0 = p.W0 + 1
		else
			p[tns] = p[tns] + 1
		end
		p.notesHit = p.notesHit + 1
	else
		return -- mines, checkpoints, etc.
	end

	if connected and (Clock() - lastProgressClock) >= PROGRESS_MIN_INTERVAL then
		lastProgressClock = Clock()
		local per = {}
		for ppn, counts in pairs(current.progress) do
			local pss = STATSMAN:GetCurStageStats():GetPlayerStageStats(PlayerEnum(ppn))
			per[ppn] = {
				score = ProgressScore(ppn, pss),
				notesHit = counts.notesHit,
				judgments = ProgressJudgments(counts),
			}
		end
		Emit("progress", { songId = current.topSongId, perPlayer = per })
	end
end

-- ------------------------------------------------------------------------
-- evaluation: song_complete + song_detail

local function CompleteFor(pn, pss)
	local player = PlayerEnum(pn)
	local mode = SL.Global.GameMode
	local out = {
		score = Round(pss:GetPercentDancePoints() * 100, 2),
		grade = ToEnumShortString(pss:GetGrade()),
		failed = pss:GetFailed() and true or false,
	}

	if mode == "Casual" then
		-- SL's helpers must not be used in Casual: raw engine counts only
		local j = {}
		for _, w in ipairs({ "W1", "W2", "W3", "W4", "W5", "Miss" }) do
			j[w] = pss:GetTapNoteScores("TapNoteScore_" .. w)
		end
		out.judgments = j
		local steps = current.charts[pn]
		local actual = pss:GetRadarActual()
		local possible = steps and steps:GetRadarValues(player)
		local minesTotal = possible and possible:GetValue("RadarCategory_Mines") or 0
		out.holdsHeld = actual:GetValue("RadarCategory_Holds")
		out.holdsTotal = possible and possible:GetValue("RadarCategory_Holds") or 0
		out.rollsHeld = actual:GetValue("RadarCategory_Rolls")
		out.rollsTotal = possible and possible:GetValue("RadarCategory_Rolls") or 0
		out.minesHit = math.max(0, minesTotal - actual:GetValue("RadarCategory_Mines"))
		out.minesTotal = minesTotal
		out.notesTotal = possible and possible:GetValue("RadarCategory_TapsAndHolds") or 0
		-- notesHit = judged non-miss rows. On a fail-out the unjudged remainder is
		-- neither hit nor missed -- totals minus misses would overcount hits.
		out.notesHit = (j.W1 or 0) + (j.W2 or 0) + (j.W3 or 0) + (j.W4 or 0) + (j.W5 or 0)
		return out
	end

	-- ITG / FA+ modes: counts + totals via SL's helper
	local counts = GetExJudgmentCounts(player)
	local j
	if mode == "ITG" then
		j = { W1 = counts.W1 or 0, W2 = counts.W2 or 0, W3 = counts.W3 or 0, Miss = counts.Miss or 0 }
		if counts.W0 ~= nil then j.W0 = counts.W0 end
		if counts.W4 ~= nil then j.W4 = counts.W4 end
		if counts.W5 ~= nil then j.W5 = counts.W5 end
		-- Blue/white Fantastic split: current SL returns W0 from GetExJudgmentCounts,
		-- but some builds omit it -- then counts.W1 is the *combined* Fantastic and the
		-- FA+/Fan split silently collapses. ex_counts.W0_total is tracked unconditionally
		-- in ITG mode, so fall back to it and rebalance the white count
		-- against the engine's combined Fantastic total (TapNoteScore_W1).
		if j.W0 == nil then
			local storage = current.storage[pn]
			local w0 = storage and storage.ex_counts and storage.ex_counts.W0_total
			if type(w0) == "number" then
				local fa = pss:GetTapNoteScores("TapNoteScore_W1")
				j.W0 = w0
				j.W1 = math.max(0, fa - w0)
			end
		end
	else
		-- FA+ mode: the engine's W1 *is* the FA+ window; shift raw counts down one
		-- (GetExJudgmentCounts only splits W0/W1 in ITG mode -- SL-Helpers.lua:650).
		j = {
			W0 = pss:GetTapNoteScores("TapNoteScore_W1"),
			W1 = pss:GetTapNoteScores("TapNoteScore_W2"),
			W2 = pss:GetTapNoteScores("TapNoteScore_W3"),
			W3 = pss:GetTapNoteScores("TapNoteScore_W4"),
			W4 = pss:GetTapNoteScores("TapNoteScore_W5"),
			Miss = pss:GetTapNoteScores("TapNoteScore_Miss"),
		}
	end
	out.judgments = j
	out.exScore = Round((CalculateExScore(player)) or 0, 2)
	out.holdsHeld = counts.Holds or 0
	out.holdsTotal = counts.totalHolds or 0
	out.rollsHeld = counts.Rolls or 0
	out.rollsTotal = counts.totalRolls or 0
	out.minesHit = counts.Mines or 0
	out.minesTotal = counts.totalMines or 0
	out.notesTotal = counts.totalSteps or 0
	-- notesHit = judged non-miss rows; on a fail-out the unjudged remainder is
	-- neither hit nor missed (totals minus misses would overcount hits).
	out.notesHit = (j.W0 or 0) + (j.W1 or 0) + (j.W2 or 0) + (j.W3 or 0) + (j.W4 or 0) + (j.W5 or 0)
	return out
end

local ZERO_EARLY = { W0 = 0, W1 = 0, W2 = 0, W3 = 0, W4 = 0, W5 = 0 }

local function DetailFor(pn, pss)
	local storage = current.storage[pn] or {}
	local out = {}

	-- offsets: SL sequential_offsets {musicSecond, offsetSeconds|"Miss"};
	-- a miss is the 1-element entry [timeCs] -- JsonEncode cannot emit null in arrays
	local offsets = {}
	if type(storage.sequential_offsets) == "table" then
		for _, entry in ipairs(storage.sequential_offsets) do
			local timeCs = math.floor((entry[1] or 0) * 100 + 0.5)
			local off = entry[2]
			if off == "Miss" then
				offsets[#offsets + 1] = { timeCs }
			elseif type(off) == "number" then
				offsets[#offsets + 1] = { timeCs, Round(off * 1000, 0) }
			end
		end
	end
	out.offsets = offsets

	-- per-column judgments: SL column_judgments
	local columns = {}
	if type(storage.column_judgments) == "table" then
		for _, c in ipairs(storage.column_judgments) do
			columns[#columns + 1] = {
				W0 = c.W0 or 0, W1 = c.W1 or 0, W2 = c.W2 or 0, W3 = c.W3 or 0,
				W4 = c.W4 or 0, W5 = c.W5 or 0, Miss = c.Miss or 0,
				MissBecauseHeld = c.MissBecauseHeld or 0,
				Early = c.Early and {
					W0 = c.Early.W0 or 0, W1 = c.Early.W1 or 0, W2 = c.Early.W2 or 0,
					W3 = c.Early.W3 or 0, W4 = c.Early.W4 or 0, W5 = c.Early.W5 or 0,
				} or ZERO_EARLY,
			}
		end
	end
	if #columns == 0 then
		columns[1] = { W0 = 0, W1 = 0, W2 = 0, W3 = 0, W4 = 0, W5 = 0, Miss = 0,
			MissBecauseHeld = 0, Early = ZERO_EARLY }
	end
	out.columns = columns

	-- life line: engine binding, 100 samples
	local song = current.song
	local lastSecond = (song and song:GetLastSecond()) or 0
	local life = {}
	local ok, record = pcall(function()
		return pss:GetLifeRecord(lastSecond, 100)
	end)
	if ok and type(record) == "table" then
		for _, v in ipairs(record) do
			life[#life + 1] = Round(math.max(0, math.min(1, v or 0)), 2)
		end
	end
	out.lifeRecord = life

	-- density graph: SL chart parser output
	local streams = SL[pn] and SL[pn].Streams
	local nps = {}
	if streams and type(streams.NPSperMeasure) == "table" then
		for _, v in ipairs(streams.NPSperMeasure) do
			nps[#nps + 1] = Round(math.max(0, v or 0), 1)
		end
	end
	out.npsPerMeasure = nps
	out.peakNps = Round(math.max(0, (streams and streams.PeakNPS) or 0), 1)

	-- graph alignment + fail point (Graphs.lua math, TrackFailTime storage)
	local steps = current.charts[pn]
	local firstSecond = 0
	if steps then
		local okTd, td = pcall(function()
			return steps:GetTimingData()
		end)
		if okTd and td then
			firstSecond = math.min(td:GetElapsedTimeFromBeat(0), 0)
		end
	end
	local meta = {
		firstSecond = Round(firstSecond, 1),
		chartStartSecond = Round((song and song:GetFirstSecond()) or 0, 1),
		lastSecond = Round(lastSecond, 1),
		totalSeconds = Round(math.max(0, storage.TotalSeconds or lastSecond), 1),
	}
	if type(storage.DeathSecond) == "number" then
		meta.deathSecond = Round(math.max(0, storage.DeathSecond), 1)
	end
	out.graphMeta = meta

	-- stream breakdown: level 0 first, escalate minimization until it fits
	-- the 256-char protocol budget (mirrors the eval screen's fit-to-width loop)
	if type(GenerateBreakdownText) == "function" then
		local okBd, text = pcall(function()
			for level = 0, 3 do
				local t = GenerateBreakdownText(pn, level)
				if type(t) == "string" and #t <= 256 then
					return t
				end
			end
			return nil
		end)
		if okBd and type(text) == "string" and text ~= "" and text ~= "Not available!" then
			out.breakdown = text
		end
	end

	-- modifier list, e.g. "C980, 55% Mini, Overhead"
	if type(GetPlayerOptionsString) == "function" then
		local okMods, modsText = pcall(function()
			return GetPlayerOptionsString(PlayerEnum(pn))
		end)
		if okMods and type(modsText) == "string" and modsText ~= "" then
			out.mods = Truncate(modsText, 120)
		end
	end

	return out
end

local function OnEvaluation()
	if dormant or not config or not session or not current or current.completed then
		return
	end
	if GAMESTATE:IsCourseMode() then
		return
	end
	current.completed = true

	local isCasual = (SL.Global.GameMode == "Casual")
	local perComplete, perDetail = {}, {}
	local haveComplete, haveDetail = false, false
	for _, pn in ipairs(JoinedPlayers()) do
		if current.songIds[pn] then
			local pss = STATSMAN:GetCurStageStats():GetPlayerStageStats(PlayerEnum(pn))
			if pss then
				perComplete[pn] = CompleteFor(pn, pss)
				haveComplete = true
				if not isCasual then
					perDetail[pn] = DetailFor(pn, pss)
					haveDetail = true
				end
			end
		end
	end
	if not haveComplete then
		return
	end

	Emit("song_complete", { play = current.play, songId = current.topSongId, perPlayer = perComplete })
	if haveDetail then
		Emit("song_detail", { play = current.play, songId = current.topSongId, perPlayer = perDetail })
	end
	EmitSummary()
end

-- ------------------------------------------------------------------------
-- screen tracking + session end (the lobby's disconnect screens)

local END_SCREENS = {
	ScreenTitleMenu = true,
	ScreenGameOver = true,
	ScreenNameEntryTraditional = true,
	ScreenOptionsService = true,
}

local function OnScreenChanged()
	local screen = SCREENMAN:GetTopScreen()
	local name = screen and screen:GetName() or ""
	if name == curScreen then
		return
	end
	prevScreen, curScreen = curScreen, name

	-- Escaping out of gameplay without reaching evaluation abandons the play:
	-- tell the EBS so the row doesn't stay "playing" forever.
	-- Restarts don't trip this (gameplay→gameplay keeps the same screen name).
	if prevScreen == "ScreenGameplay" and name ~= "ScreenEvaluationStage"
		and session and current and not current.completed then
		current.completed = true
		Emit("song_abort", { play = current.play, songId = current.topSongId })
	end

	if session and END_SCREENS[name] then
		EndSession("screen")
	end
	UpdateStatus()
end

-- ------------------------------------------------------------------------
-- module actors (loader contract: table of ScreenName → Actor; actors live
-- in ScreenSystemLayer and ModuleCommand fires on entry to the named screen)

local t = {}

t["ScreenSelectMusic"] = Def.ActorFrame{
	ModuleCommand = function(self)
		Safely(function()
			Init()
			if dormant or not config or GAMESTATE:IsDemonstration() then
				UpdateStatus()
				return
			end
			EnsureConnected()
			if not session then
				StartSession()
			else
				SyncPlayers()
			end
			UpdateStatus()
		end)
	end,
	-- broadcast: fires on every screen change, on every screen
	ScreenChangedMessageCommand = function(self)
		Safely(OnScreenChanged)
	end,
	-- ScreenSystemLayer teardown = game exit / theme change: best-effort goodbye
	OffCommand = function(self)
		Safely(function()
			if session then
				EndSession("shutdown")
			end
			if ws then
				ws:Close()
				ws = nil
			end
			connected = false
		end)
	end,

	-- The connection indicator. Lives in ScreenSystemLayer (drawn above every
	-- screen) so UpdateStatus() keeps it hidden everywhere except the song
	-- wheel, and only when the hidden ini Debug flag is set. Adjust xy/zoom here if
	-- it collides with another theme element.
	Def.BitmapText{
		Font = "Common Normal",
		InitCommand = function(self)
			statusActor = self
			self:xy(SCREEN_LEFT + 14, SCREEN_TOP + 44)
			self:zoom(0.65)
			self:halign(0)
			self:shadowlength(0.4)
			self:visible(false)
			Safely(UpdateStatus)
		end,
	},
}

t["ScreenGameplay"] = Def.Actor{
	ModuleCommand = function(self)
		Safely(OnGameplayStart)
	end,
	JudgmentMessageCommand = function(self, params)
		Safely(function()
			OnJudgment(params)
		end)
	end,
}

t["ScreenEvaluationStage"] = Def.Actor{
	ModuleCommand = function(self)
		Safely(OnEvaluation)
	end,
}

return t
