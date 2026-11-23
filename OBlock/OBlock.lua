-- O BLOCK v1.6 - WoW Forever (interface 16001)
-- Local files only. Never attempts network access or combat automation.
local addon = CreateFrame("Frame")
local prefix = "|cffff4444O BLOCK|r "
local tracks = {
  "Interface\\AddOns\\OBlock\\Music\\track01.mp3",
  "Interface\\AddOns\\OBlock\\Music\\track02.mp3",
  "Interface\\AddOns\\OBlock\\Music\\track03.mp3",
  "Interface\\AddOns\\OBlock\\Music\\track04.mp3",
  "Interface\\AddOns\\OBlock\\Music\\track05.mp3",
  "Interface\\AddOns\\OBlock\\Music\\track06.mp3",
  "Interface\\AddOns\\OBlock\\Music\\track07.mp3",
  "Interface\\AddOns\\OBlock\\Music\\track08.mp3",
}
local playing = false
local soundHandle = nil
local fadingHandles = {}
local lastTrack = nil
local pending = false
local nextCheck = 0
local function say(message) print(prefix .. message) end
local engageAlerts = {
  "THE OPS IS OUT THERE, GET 'EM TWIN!",
  "IT'S UP! HANDLE BUSINESS!",
  "THEY OUTSIDE! STAND ON BUSINESS!",
  "WHO WANT SMOKE?!",
  "AIN'T NOBODY SAFE TODAY!",
}
local disengageAlerts = {
  "HOLD IT DOWN!",
  "WE STILL OUT HERE, TWIN!",
  "STAY READY!",
  "BLOCK SECURED!",
  "KEEP YOUR HEAD ON A SWIVEL!",
}
local function alert(lines) say(lines[math.random(#lines)]) end
local function settings()
  if type(OBlockDB) ~= "table" then OBlockDB = {} end
  if OBlockDB.enabled == nil then OBlockDB.enabled = true end
  if OBlockDB.slots == nil then OBlockDB.slots = 8 end
  if OBlockDB.debug == nil then OBlockDB.debug = false end
  if OBlockDB.fade == nil then OBlockDB.fade = 4 end
end
local function stop(immediate)
  if immediate and StopSound then
    for _, entry in ipairs(fadingHandles) do StopSound(entry.handle) end
    fadingHandles = {}
  end
  if not playing then return end
  if soundHandle and StopSound then
    local fadeMs = immediate and 0 or math.floor((OBlockDB.fade or 4) * 1000)
    if fadeMs > 0 then
      -- Track handles remain active during their native fade. They are not reused.
      StopSound(soundHandle, fadeMs)
      fadingHandles[#fadingHandles + 1] = { handle = soundHandle, remaining = fadeMs / 1000 }
    else
      StopSound(soundHandle)
    end
  elseif StopMusic then
    -- Fallback for clients without handle-based playback.
    StopMusic()
  end
  soundHandle = nil
  playing = false
  if not immediate then alert(disengageAlerts) end
  if OBlockDB.debug then say(immediate and "Music stopped." or "Music fading out.") end
end
local function choose()
  local count = math.max(1, math.min(8, tonumber(OBlockDB.slots) or 8))
  local pick = math.random(count)
  if count > 1 and pick == lastTrack then pick = (pick % count) + 1 end
  lastTrack = pick
  return pick
end
local function start()
  if playing or not OBlockDB.enabled then return end
  local slot = choose()
  if PlaySoundFile and StopSound then
    local ok, willPlay, handle = pcall(PlaySoundFile, tracks[slot], "Music")
    if ok and willPlay and type(handle) == "number" then
      soundHandle = handle
      playing = true
      alert(engageAlerts)
      if OBlockDB.debug then say("Playing track " .. string.format("%02d", slot) .. ".") end
    else
      say("Unable to play track " .. slot .. ". Check MP3 file and Music channel.")
    end
  else
    -- Compatibility fallback: works but does not support fades.
    if PlayMusic then
      PlayMusic(tracks[slot]); playing = true
      alert(engageAlerts)
      if OBlockDB.debug then say("Track " .. slot .. " started (fade unavailable on this client).") end
    else
      say("Audio playback API unavailable on this client.")
    end
  end
end
-- Only play in the open world. Unknown instance types are blocked as a precaution.
local function inOpenWorld()
  if type(IsInInstance) ~= "function" then return false end
  local ok, inside, kind = pcall(IsInInstance)
  return ok and not inside and kind == "none"
end
local function hostilePlayerTarget()
  -- Only start on a visible, targetable enemy PLAYER. Do not inspect secret combat-log values.
  -- UnitIsPlayer and UnitCanAttack may be restricted by the client; fail safely.
  if not UnitExists or not UnitIsPlayer or not UnitCanAttack then return false end
  local ok, result = pcall(function()
    return UnitExists("target") and UnitIsPlayer("target") and UnitCanAttack("player", "target")
  end)
  return ok and result == true
end
local function inCombat()
  if UnitAffectingCombat then
    local ok, value = pcall(UnitAffectingCombat, "player")
    return ok and value == true
  end
  return false
end
-- Conservative PvP signal: hostile player is fighting and currently targets YOU.
-- This is not a combat-log proof of damage; it avoids the common NPC-aggro false positive.
-- We intentionally do not trigger merely because you target a hostile player.
local function opponentEngagedWithMe()
  if not hostilePlayerTarget() then return false end
  if not UnitExists or not UnitIsUnit or not UnitAffectingCombat then return false end
  local ok, result = pcall(function()
    return UnitExists("targettarget")
       and UnitIsUnit("targettarget", "player")
       and UnitAffectingCombat("target")
  end)
  return ok and result == true
end

local function evaluate()
  if not OBlockDB.enabled or playing or not inOpenWorld() then return end
  if inCombat() and opponentEngagedWithMe() then start() end
end
addon:RegisterEvent("ADDON_LOADED")
addon:RegisterEvent("PLAYER_REGEN_DISABLED")
addon:RegisterEvent("PLAYER_REGEN_ENABLED")
addon:RegisterEvent("PLAYER_TARGET_CHANGED")
addon:RegisterEvent("UNIT_TARGET")
addon:RegisterEvent("PLAYER_ENTERING_WORLD")
addon:RegisterEvent("PLAYER_DEAD")
addon:RegisterEvent("ZONE_CHANGED_NEW_AREA")
addon:SetScript("OnEvent", function(self, event, arg1)
  if event == "UNIT_TARGET" and arg1 ~= "target" then return end
  if event == "ADDON_LOADED" then
    if arg1 ~= "OBlock" then return end
    settings()
    math.randomseed(time())
    say("Loaded. /oblock help for commands.")
  elseif event == "PLAYER_REGEN_ENABLED" then
    stop(false)
  elseif event == "PLAYER_DEAD" then
    stop(true)
  elseif event == "PLAYER_ENTERING_WORLD" then
    if playing then stop(true) end
  elseif event == "ZONE_CHANGED_NEW_AREA" then
    if not inOpenWorld() then stop(true) end
  else
    if OBlockDB then evaluate() end
  end
end)
-- Poll target during combat in case a target change event occurs before combat begins.
addon:SetScript("OnUpdate", function(self, elapsed)
  -- Retire bookkeeping for handles already fading on the audio engine.
  for i = #fadingHandles, 1, -1 do
    local entry = fadingHandles[i]
    entry.remaining = entry.remaining - elapsed
    if entry.remaining <= 0 then table.remove(fadingHandles, i) end
  end
  if not OBlockDB or not OBlockDB.enabled or playing then return end
  nextCheck = nextCheck + elapsed
  if nextCheck >= 0.35 then
    nextCheck = 0
    evaluate()
  end
end)
SLASH_OBLOCK1 = "/oblock"
SlashCmdList.OBLOCK = function(msg)
  settings()
  local command, value = (msg or ""):lower():match("^(%S*)%s*(.-)%s*$")
  if command == "on" then
    OBlockDB.enabled = true; say("Enabled.")
  elseif command == "off" then
    OBlockDB.enabled = false; stop(true); say("Disabled.")
  elseif command == "test" then
    stop(true); start(); say("Test playback. /oblock stop to stop.")
  elseif command == "stop" then
    stop(true); say("Stopped.")
  elseif command == "slots" then
    local n = tonumber(value)
    if n and n >= 1 and n <= 8 and n == math.floor(n) then
      OBlockDB.slots = n; say("Using track01 through track" .. string.format("%02d", n) .. ".")
    else say("Usage: /oblock slots 1-8") end
  elseif command == "fade" then
    local n = tonumber(value)
    if n and n >= 0 and n <= 15 then
      OBlockDB.fade = n; say("Combat fade set to " .. n .. " seconds.")
    else say("Usage: /oblock fade 0-15 (seconds)") end
  elseif command == "debug" then
    OBlockDB.debug = not OBlockDB.debug; say("Debug " .. (OBlockDB.debug and "on" or "off") .. ".")
  elseif command == "status" then
    say("Enabled: " .. tostring(OBlockDB.enabled) .. "; slots: " .. tostring(OBlockDB.slots) .. "; playing: " .. tostring(playing) .. "; fade: " .. tostring(OBlockDB.fade) .. "s")
  elseif command == "about" then
    say("World PvP Soundtrack v1.6 | Created by Kevon'dre")
  else
    say("Commands: /oblock on | off | test | stop | slots 1-8 | fade 0-15 | status | debug | about")
  end
end
