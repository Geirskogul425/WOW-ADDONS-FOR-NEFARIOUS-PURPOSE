-- O BLOCK v2.0.4 - WoW Forever (interface 16001)
-- Local files only. Never attempts network access or combat automation.
local addon = CreateFrame("Frame")
local prefix = "|cffff4444O BLOCK|r "
local tracks = {}
for i=1,64 do tracks[i]=string.format("Interface\\AddOns\\OBlock\\Music\\track%02d.mp3",i) end
local session = { encounters=0, tracks=0, seconds=0, longest=0, deaths=0 }
local encounter, current, preview, suppressed, retryAt
local logs = {}
local refresh, buildUI, updateMini, toggleUI, buildMini
local uiReady, uiError
local function initUI()
  if uiReady then return true end
  if uiError then print("O BLOCK UI error: "..uiError); return false end
  local ok, err = pcall(buildUI)
  if not ok then uiError=tostring(err); print("O BLOCK UI error: "..uiError); return false end
  uiReady=true; return true
end
local function log(msg)
  logs[#logs+1]=date("%H:%M:%S").." "..msg
  if #logs>30 then table.remove(logs,1) end
end
local function bump(k,n)
  session[k]=session[k]+n; OBlockDB.stats[k]=OBlockDB.stats[k]+n
end
local function finish(died)
  if not encounter then return end
  local duration=math.max(0,GetTime()-encounter)
  bump("seconds",duration)
  session.longest=math.max(session.longest,duration)
  OBlockDB.stats.longest=math.max(OBlockDB.stats.longest,duration)
  if died then bump("deaths",1) end
  encounter=nil
end
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
local function alert(lines) if OBlockDB.alerts then say(lines[math.random(#lines)]) end end
local function settings()
  if type(OBlockDB) ~= "table" then OBlockDB = {} end
  if OBlockDB.enabled == nil then OBlockDB.enabled = true end
  if OBlockDB.slots == nil then OBlockDB.slots = 8 end
  if OBlockDB.debug == nil then OBlockDB.debug = false end
  if OBlockDB.fade == nil then OBlockDB.fade = 4 end
  if OBlockDB.alerts == nil then OBlockDB.alerts=true end
  if OBlockDB.minimap == nil then OBlockDB.minimap=true end
  OBlockDB.angle=tonumber(OBlockDB.angle) or 220
  OBlockDB.slots=math.max(1,math.min(64,math.floor(tonumber(OBlockDB.slots) or 8)))
  OBlockDB.fade=math.max(0,math.min(15,tonumber(OBlockDB.fade) or 4))
  if type(OBlockDB.stats)~="table" then OBlockDB.stats={} end
  for k in pairs(session) do OBlockDB.stats[k]=tonumber(OBlockDB.stats[k]) or 0 end
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
  current=nil; preview=nil
  log("Playback stopped")
  if not immediate then alert(disengageAlerts) end
  if OBlockDB.debug then say(immediate and "Music stopped." or "Music fading out.") end
end
local function choose()
  local count = math.max(1, math.min(64, tonumber(OBlockDB.slots) or 8))
  local pick = math.random(count)
  if count > 1 and lastTrack and lastTrack <= count then pick=math.random(count-1); if pick>=lastTrack then pick=pick+1 end end
  lastTrack = pick
  return pick
end
local function start(slot, isPreview)
  if playing or (not isPreview and not OBlockDB.enabled) then return end
  slot = slot or choose()
  retryAt=GetTime()+5
  if PlaySoundFile and StopSound then
    local ok, willPlay, handle = pcall(PlaySoundFile, tracks[slot], "Music")
    if ok and willPlay and type(handle) == "number" then
      soundHandle = handle
      playing = true
      if not isPreview then alert(engageAlerts); bump("tracks",1) end
      current=slot; preview=isPreview; log("Playing track "..slot..(isPreview and " (preview)" or ""))
      if OBlockDB.debug then say("Playing track " .. string.format("%02d", slot) .. ".") end
    else
      say("Unable to play track " .. slot .. ". Check MP3 file and Music channel.")
    end
  else
    -- Compatibility fallback: works but does not support fades.
    if PlayMusic then
      PlayMusic(tracks[slot]); playing = true
      if not isPreview then alert(engageAlerts); bump("tracks",1) end
      current=slot; preview=isPreview; log("Playing track "..slot..(isPreview and " (preview)" or ""))
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
  if not OBlockDB.enabled or suppressed or not inOpenWorld() then return end
  if UnitIsDeadOrGhost and UnitIsDeadOrGhost("player") then return end
  if inCombat() and opponentEngagedWithMe() then
    if not encounter then encounter=GetTime(); bump("encounters",1); log("Target-based PvP signal") end
    if preview then stop(true) end
    if not playing and GetTime()>=(retryAt or 0) then start() end
  end
end
addon:RegisterEvent("ADDON_LOADED")
addon:RegisterEvent("PLAYER_LOGIN")
addon:RegisterEvent("PLAYER_REGEN_DISABLED")
addon:RegisterEvent("PLAYER_REGEN_ENABLED")
addon:RegisterEvent("PLAYER_TARGET_CHANGED")
addon:RegisterEvent("UNIT_TARGET")
addon:RegisterEvent("PLAYER_ENTERING_WORLD")
addon:RegisterEvent("PLAYER_DEAD")
addon:RegisterEvent("ZONE_CHANGED_NEW_AREA")
addon:RegisterEvent("PLAYER_LOGOUT")
pcall(addon.RegisterEvent,addon,"UNIT_COMBAT")
addon:SetScript("OnEvent", function(self, event, arg1)
  if event == "UNIT_TARGET" and arg1 ~= "target" then return end
  if event == "ADDON_LOADED" then
    if arg1 ~= "OBlock" then return end
    settings()
    math.randomseed(time())
    say("Loaded. /oblock opens settings.")
  elseif event == "PLAYER_LOGIN" then
    if OBlockDB then buildMini() end
  elseif event == "PLAYER_LOGOUT" then
    finish(false)
  elseif event == "UNIT_COMBAT" then
    if arg1=="player" and OBlockDB and OBlockDB.debug then log("Incoming UNIT_COMBAT: player") end
    -- No attacker identity in UNIT_COMBAT; never trigger from damage alone.
  elseif event == "PLAYER_REGEN_ENABLED" then
    finish(false); suppressed=nil; retryAt=nil
    if not preview then stop(false) end
  elseif event == "PLAYER_DEAD" then
    finish(true); stop(true); suppressed=nil
  elseif event == "PLAYER_ENTERING_WORLD" then
    if OBlockDB then buildMini() end
    finish(false); stop(true); suppressed=nil
  elseif event == "ZONE_CHANGED_NEW_AREA" then
    if not inOpenWorld() then finish(false); stop(true); suppressed=nil end
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
  if not OBlockDB then return end
  nextCheck = nextCheck + elapsed
  if nextCheck >= 0.35 then
    nextCheck = 0
    if not inOpenWorld() then finish(false); stop(true) else evaluate() end
    if not mini and Minimap then buildMini() end
    if uiReady and refresh then refresh() end
  end
end)
SLASH_OBLOCK1 = "/oblock"
SlashCmdList.OBLOCK = function(msg)
  settings()
  local command, value = (msg or ""):lower():match("^(%S*)%s*(.-)%s*$")
  if command == "" or command == "config" then if initUI() then toggleUI() end
  elseif command == "on" then
    OBlockDB.enabled = true; say("Enabled.")
  elseif command == "off" then
    OBlockDB.enabled = false; finish(false); stop(true); say("Disabled.")
  elseif command == "test" then
    if not inOpenWorld() then say("Preview available in open world only."); return end
    if encounter or inCombat() then say("Preview unavailable during combat."); return end
    local n=tonumber(value); if n and (n<1 or n>OBlockDB.slots or n~=math.floor(n)) then say("Invalid track."); return end
    stop(true); start(n,true); say("Test playback. /oblock stop to stop.")
  elseif command == "stop" then
    suppressed=inCombat(); stop(true); say("Stopped.")
  elseif command == "slots" then
    local n = tonumber(value)
    if n and n >= 1 and n <= 64 and n == math.floor(n) then
      OBlockDB.slots = n; say("Using track01 through track" .. string.format("%02d", n) .. ".")
    else say("Usage: /oblock slots 1-64") end
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
    say("World PvP Soundtrack v2.0.4 | Created by Kevon'dre")
  else
    say("Commands: /oblock on | off | test | stop | slots 1-64 | fade 0-15 | status | debug | about")
  end
end

-- Native WoW controls; no external libraries.
local panel, mini, pages, status, statsText, debugText, trackText, checks, sliders
local selected=1
local function label(parent,text,x,y,template)
  local l=parent:CreateFontString(nil,"OVERLAY",template or "GameFontNormal")
  l:SetPoint("TOPLEFT",x,y); l:SetText(text); return l
end
local function button(parent,text,x,y,w,fn)
  local b=CreateFrame("Button",nil,parent,"UIPanelButtonTemplate")
  b:SetSize(w,25); b:SetPoint("TOPLEFT",x,y); b:SetText(text); b:SetScript("OnClick",fn); return b
end
local function command(s) SlashCmdList.OBLOCK(s); if uiReady and refresh then refresh() end end
local function duration(s) return string.format("%dm %02ds",math.floor(s/60),math.floor(s%60)) end
local function statline(name,k,fmt)
  local a,b=session[k],OBlockDB.stats[k]
  if encounter and (k=="seconds" or k=="longest") then
    local t=GetTime()-encounter
    if k=="seconds" then a=a+t; b=b+t else a=math.max(a,t); b=math.max(b,t) end
  end
  return name.."   |cffffffff"..(fmt and fmt(a) or a).."  /  "..(fmt and fmt(b) or b).."|r"
end
updateMini=function()
  if not mini then return end
  local a=math.rad(OBlockDB.angle); local r=(Minimap:GetWidth() or 140)/2+5
  mini:ClearAllPoints(); mini:SetPoint("CENTER",Minimap,"CENTER",math.cos(a)*r,math.sin(a)*r)
  if OBlockDB.minimap then mini:Show() else mini:Hide() end
end
refresh=function()
  if not panel or not panel:IsShown() then return end
  status:SetText((OBlockDB.enabled and "|cff55ff55ENABLED|r" or "|cffff5555DISABLED|r").."   |   "..(current and string.format("Track %02d%s",current,preview and " (preview)" or "") or "Idle"))
  for k,c in pairs(checks) do c:SetChecked(OBlockDB[k]) end
  for k,s in pairs(sliders) do if s:GetValue()~=OBlockDB[k] then s:SetValue(OBlockDB[k]) end end
  selected=math.min(selected,OBlockDB.slots)
  trackText:SetText(string.format("track%02d.mp3  (%d of %d)",selected,selected,OBlockDB.slots))
  statsText:SetText(table.concat({"SESSION / LIFETIME",statline("Times the ops pulled up","encounters"),statline("Combat tracks started","tracks"),statline("Detected encounter time","seconds",duration),statline("Longest encounter","longest",duration),statline("Deaths during encounters","deaths")},"\n\n"))
  local lines={"Open world: "..tostring(inOpenWorld()),"Player combat: "..tostring(inCombat()),"Hostile player target: "..tostring(hostilePlayerTarget()),"Target engagement signal: "..tostring(opponentEngagedWithMe()),"Recent events:"}
  for i=math.max(1,#logs-7),#logs do lines[#lines+1]=logs[i] end
  debugText:SetText(table.concat(lines,"\n"))
end
toggleUI=function() if panel:IsShown() then panel:Hide() else panel:Show(); refresh() end end
buildUI=function()
  panel=CreateFrame("Frame","OBlockSettingsFrame",UIParent)
  panel:Hide(); panel:SetSize(490,448); panel:SetPoint("CENTER"); panel:SetFrameStrata("DIALOG"); panel:SetClampedToScreen(true)
  panel:EnableMouse(true); panel:SetMovable(true); panel:RegisterForDrag("LeftButton")
  panel:SetScript("OnDragStart",function(self) self:StartMoving() end)
  panel:SetScript("OnDragStop",function(self) self:StopMovingOrSizing() end)
  -- Opaque base beneath the native textured background, independent of its alpha.
  local base=panel:CreateTexture(nil,"BACKGROUND"); base:SetPoint("TOPLEFT",8,-8); base:SetPoint("BOTTOMRIGHT",-8,8)
  if base.SetColorTexture then base:SetColorTexture(0.025,0.025,0.025,1) else base:SetTexture(0.025,0.025,0.025,1) end
  local backdrop={bgFile="Interface\\DialogFrame\\UI-DialogBox-Background",edgeFile="Interface\\DialogFrame\\UI-DialogBox-Border",tile=true,tileSize=32,edgeSize=32,insets={left=11,right=12,top=12,bottom=11}}
  local bg=panel:CreateTexture(nil,"BORDER"); bg:SetPoint("TOPLEFT",11,-12); bg:SetPoint("BOTTOMRIGHT",-12,11); bg:SetTexture(backdrop.bgFile)
  if bg.SetHorizTile then bg:SetHorizTile(true); bg:SetVertTile(true) end
  local edge={edgeFile=backdrop.edgeFile,edgeSize=32}
  if panel.SetBackdrop then
    panel:SetBackdrop(edge)
  else
    local frame=CreateFrame("Frame",nil,panel,"BackdropTemplate")
    frame:SetAllPoints(panel); frame:SetFrameLevel(panel:GetFrameLevel()); frame:SetBackdrop(edge); frame:EnableMouse(false)
  end
  local art=panel:CreateTexture(nil,"ARTWORK"); art:SetSize(60,60); art:SetPoint("TOPLEFT",14,-14); art:SetTexture("Interface\\AddOns\\OBlock\\Media\\Icon")
  label(panel,"|cffff4545O BLOCK|r  |cffffd080v2.0.4|r",86,-18,"GameFontNormalLarge")
  label(panel,"World PvP Soundtrack",86,-42)
  status=label(panel,"",86,-60,"GameFontHighlightSmall")
  local close=CreateFrame("Button",nil,panel,"UIPanelCloseButton"); close:SetPoint("TOPRIGHT",-3,-3)
  if UISpecialFrames then table.insert(UISpecialFrames,"OBlockSettingsFrame") end
  pages={}; checks={}; sliders={}
  for i,name in ipairs({"General","Playlist","Statistics","Debug"}) do
    local page=CreateFrame("Frame",nil,panel); page:SetPoint("TOPLEFT",16,-118); page:SetPoint("BOTTOMRIGHT",-16,64); pages[i]=page; page:Hide()
    button(panel,name,14+(i-1)*116,-88,112,function() for j,p in ipairs(pages) do if j==i then p:Show() else p:Hide() end end; refresh() end)
  end
  local function check(page,k,text,y,fn)
    local c=CreateFrame("CheckButton","OBlockCheck"..k,page,"UICheckButtonTemplate"); c:SetPoint("TOPLEFT",0,y); c:SetSize(26,26)
    label(c,text,30,-7); checks[k]=c; c:SetScript("OnClick",function(self) OBlockDB[k]=not not self:GetChecked(); if fn then fn() end; refresh() end)
  end
  local function slider(page,k,text,y,min,max)
    local l=label(page,"",4,y); local s=CreateFrame("Slider","OBlockSlider"..k,page,"OptionsSliderTemplate"); s:SetPoint("TOPLEFT",6,y-28); s:SetSize(320,18); s:SetMinMaxValues(min,max); s:SetValueStep(1)
    if s.SetObeyStepOnDrag then s:SetObeyStepOnDrag(true) end
    sliders[k]=s; s:SetScript("OnValueChanged",function(self,v) OBlockDB[k]=math.floor(v+.5); l:SetText(text..": "..OBlockDB[k]) end); s:SetValue(OBlockDB[k]); l:SetText(text..": "..OBlockDB[k])
  end
  check(pages[1],"enabled","Enable O BLOCK",0,function() if not OBlockDB.enabled then finish(false); stop(true) end end)
  check(pages[1],"alerts","Hype chat alerts",-32)
  check(pages[1],"minimap","Show minimap button",-64,updateMini)
  slider(pages[1],"fade","Combat fade (seconds)",-108,0,15)
  label(pages[1],"Open-world only. Audio uses the game's Music volume.",4,-177,"GameFontHighlightSmall")
  button(pages[1],"Reset icon position",4,-205,155,function() OBlockDB.angle=220; updateMini() end)
  slider(pages[2],"slots","Number of local tracks",-4,1,64)
  trackText=label(pages[2],"",4,-80,"GameFontHighlight")
  button(pages[2],"Previous",4,-110,90,function() selected=math.max(1,selected-1); refresh() end)
  button(pages[2],"Next",100,-110,90,function() selected=math.min(OBlockDB.slots,selected+1); refresh() end)
  button(pages[2],"Play track",196,-110,105,function() command("test "..selected) end)
  button(pages[2],"Random",4,-150,90,function() command("test") end)
  button(pages[2],"Stop",100,-150,90,function() command("stop") end)
  label(pages[2],"Place sequential MP3 files in OBlock/Music.\nPreviews do not count toward combat statistics.",4,-195,"GameFontHighlightSmall")
  statsText=label(pages[3],"",4,-4); statsText:SetJustifyH("LEFT")
  check(pages[4],"debug","Enable debug chat / incoming event logging",0)
  debugText=label(pages[4],"",4,-35,"GameFontHighlightSmall"); debugText:SetJustifyH("LEFT"); debugText:SetWidth(450)
  button(pages[4],"Clear log",4,-211,100,function() logs={}; refresh() end)
  local motto=panel:CreateFontString(nil,"OVERLAY","GameFontNormal"); motto:SetPoint("BOTTOM",0,39); motto:SetJustifyH("CENTER"); motto:SetText("AIN'T NOBODY SAFE TODAY!")
  local credit=panel:CreateFontString(nil,"OVERLAY","GameFontNormal"); credit:SetPoint("BOTTOM",0,18); credit:SetJustifyH("CENTER"); credit:SetText("Developed by Kevon'dre")
  pages[1]:Show(); panel:Hide()
end
buildMini=function()
  if mini then updateMini(); return end
  if Minimap then
    mini=CreateFrame("Button","OBlockMinimapButton",Minimap); mini:SetSize(32,32); mini:SetFrameStrata("MEDIUM"); mini:SetFrameLevel(Minimap:GetFrameLevel()+8)
    local icon=mini:CreateTexture(nil,"ARTWORK"); icon:SetSize(23,23); icon:SetPoint("CENTER"); icon:SetTexture("Interface\\AddOns\\OBlock\\Media\\MinimapIcon")
    local border=mini:CreateTexture(nil,"OVERLAY"); border:SetSize(53,53); border:SetPoint("TOPLEFT"); border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    mini:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    mini:RegisterForClicks("LeftButtonUp","RightButtonUp"); mini:RegisterForDrag("LeftButton")
    mini:SetScript("OnClick",function(self,b) if b=="RightButton" then command(OBlockDB.enabled and "off" or "on") else if initUI() then toggleUI() end end end)
    mini:SetScript("OnDragStart",function(self) self:SetScript("OnUpdate",function() local x,y=GetCursorPosition(); local scale=Minimap:GetEffectiveScale(); local cx,cy=Minimap:GetCenter(); if cx and cy then OBlockDB.angle=math.deg(math.atan2(y/scale-cy,x/scale-cx)); updateMini() end end) end)
    mini:SetScript("OnDragStop",function(self) self:SetScript("OnUpdate",nil) end)
    mini:SetScript("OnEnter",function(self) GameTooltip:SetOwner(self,"ANCHOR_LEFT"); GameTooltip:AddLine("O BLOCK"); GameTooltip:AddLine(OBlockDB.enabled and "Enabled" or "Disabled"); GameTooltip:AddLine(current and string.format("Track %02d",current) or "Idle"); GameTooltip:AddLine("Left: settings / Right: toggle / Drag: move",1,1,1); GameTooltip:Show() end)
    mini:SetScript("OnLeave",function() GameTooltip:Hide() end)
    updateMini()
  end
end
