-- ZoneTrack: keep the default quest tracker showing the quests whose map area
-- (C_QuestLog.GetQuestsOnMap) is in the zone you're standing in, sort it by distance,
-- and point the quest arrow at the nearest one.
local ADDON = ...

local DEFAULTS = {
  enabled          = true,
  keepPins         = true,  -- quests you track by hand stay tracked everywhere
  turnIns          = true,  -- track this zone's finished quests where the map shows them
  finishedAnywhere = true,  -- also track finished quests from every zone, below this zone's
  skipHandOffs     = true,  -- ...except ones with no item/spell reward and no real objectives
  nearestFirst     = false, -- tracker full: false = quest log order, true = nearest first
  autoSort         = true,  -- sort the tracker nearest-first when the arrow moves / zone / accept / turn-in
  resortEvery      = false, -- ...also after every quest-log update (kill, loot, objective)
  autoArrow        = true,  -- point the quest arrow at the nearest tracked quest
  showButton       = true,
  debug            = false, -- chat log of every decision
}

local S, C            -- account settings, per-character state
local expect = {}     -- [questID] = true/false: watch changes we caused
local suppressed = {} -- [questID] = true: you untracked it in this zone; leave it until the zone changes
local autoMark = {}       -- [questID] = true: the game acted on this quest this frame (accept, progress, turn-in)
local pendingWatch = {}   -- [questID] = true: watch changes we didn't make, classified next frame
local pendingSuper        -- arrow target we didn't set, classified next frame
local extras = {}     -- [questID] = true: finished quests from other zones we track
local lastZone
local orderGaveUp = false -- a reorder didn't stick; cleared on zone change / button
local pending = false
local afterCombat = false
local sortWanted = true   -- re-sort by distance on the next pass (arrow moved, zone, accept, turn-in)

local arrowPaused = false -- you picked an arrow target yourself; cleared on zone change / button
local expectSuper         -- quest we just pointed the arrow at
local reordering = false  -- inside applyOrder: arrow changes there are ours
local moving = false
local tickGen = 0

local openSettings, updateButton

local function dbg(...)
  if S and S.debug then print("|cff66ccffZoneTrack|r", ...) end
end

local function title(q)
  local i = C_QuestLog.GetLogIndexForQuestID(q)
  local info = i and C_QuestLog.GetInfo(i)
  return (info and info.title or "?") .. " (" .. tostring(q) .. ")"
end

local function isWatched(q)
  return C_QuestLog.GetQuestWatchType(q) ~= nil
end

local function isInside(q)
  if not (C_Minimap and C_Minimap.IsInsideQuestBlob) then return false end
  local inside = C_Minimap.IsInsideQuestBlob(q)
  if issecretvalue and issecretvalue(inside) then return false end
  return inside and true or false
end

-- 0 when you stand inside the quest's highlighted area (C_Minimap.IsInsideQuestBlob),
-- otherwise the client's own distance in yards to the middle of its nearest area.
local function dist(q)
  if isInside(q) then return 0 end
  local dsq, onContinent = C_QuestLog.GetDistanceSqToQuest(q)
  if issecretvalue and (issecretvalue(dsq) or issecretvalue(onContinent)) then return nil end
  if dsq and onContinent then return math.sqrt(dsq) end
end

local function watchList()
  local t = {}
  for i = 1, C_QuestLog.GetNumQuestWatches() do
    local q = C_QuestLog.GetQuestIDForQuestWatchIndex(i)
    if q then t[#t + 1] = q end
  end
  return t
end

-- A hand-off is a quest with nothing to show for it: no item, no item choice, no spell,
-- and no objectives other than "log" text (talk to / deliver to the next person).
local function isHandOff(q)
  if (GetNumQuestLogRewards(q) or 0) + (GetNumQuestLogChoices(q) or 0) > 0 then return false end
  local sp = C_QuestInfoSystem and C_QuestInfoSystem.GetQuestRewardSpells and C_QuestInfoSystem.GetQuestRewardSpells(q)
  if type(sp) == "table" and #sp > 0 then return false end
  for _, o in ipairs(C_QuestLog.GetQuestObjectives(q) or {}) do
    if o.type ~= "log" then return false end
  end
  return true
end

-- Zone-level map (mapType 3) the player is in; walks up from caves/micro-dungeons.
-- Returns nil while the client only knows the continent (right after login).
local function zoneMap()
  local m = C_Map.GetBestMapForUnit("player")
  local guard = 0
  while m and guard < 10 do
    guard = guard + 1
    local info = C_Map.GetMapInfo(m)
    if not info then return nil end
    if info.mapType == 3 then return m end
    if info.mapType < 3 then return nil end
    m = info.parentMapID
  end
end

-- ---------------------------------------------------------------- arrow

local schedule, classifyPending
local function pointArrow(q)
  if C_SuperTrack.GetSuperTrackedQuestID() == q then return end
  expectSuper = q
  C_SuperTrack.SetSuperTrackedQuestID(q)
  dbg("arrow ->", title(q))
  -- Reflow the tracker to match (refresh waits for combat to end by itself).
  if S.autoSort then
    sortWanted = true
    schedule()
  end
end

-- Point the arrow at the nearest tracked quest. While you move, check again at the
-- earliest moment the nearest quest could change: each distance changes by at most the
-- distance you move, so the runner-up can't overtake before you've covered half the gap.
local function nearestTick(force)
  tickGen = tickGen + 1
  if not S.enabled then return end
  if not force and (not S.autoArrow or arrowPaused) then return end
  if UnitOnTaxi("player") then return end

  local best, dBest = nil, math.huge
  local cur = C_SuperTrack.GetSuperTrackedQuestID()
  local curD
  local ds = {}
  for _, q in ipairs(watchList()) do
    local d = dist(q)
    if d then
      ds[#ds + 1] = d
      if q == cur then curD = d end
      if d < dBest then best, dBest = q, d end
    end
  end
  -- Runner-up = nearest quest that is actually farther. Quests at exactly the same
  -- distance (same area) can never overtake each other, so they don't count.
  local dNext = math.huge
  for _, d in ipairs(ds) do
    if d > dBest and d < dNext then dNext = d end
  end
  -- On a tie (e.g. standing inside two overlapping areas) keep the current target.
  if curD and curD == dBest then best = cur end
  if best then pointArrow(best) end

  -- Inside an area the nearest can only change when you leave it, and leaving fires
  -- PLAYER_INSIDE_QUEST_BLOB_STATE_CHANGED, so no timer is needed then.
  if dBest == 0 then return end

  -- GetUnitSpeed is a secret value while unit stats are restricted (combat); no timer
  -- then. PLAYER_REGEN_ENABLED re-runs this.
  local speed = GetUnitSpeed("player")
  if issecretvalue and issecretvalue(speed) then return end
  speed = speed or 0
  if moving and speed > 0 and dNext < math.huge then
    local delay = (dNext - dBest) / 2 / speed
    local gen = tickGen
    C_Timer.After(delay, function()
      if gen == tickGen then nearestTick() end
    end)
  end
end

-- ---------------------------------------------------------------- tracker order

-- The tracker draws the watch list in order, and the client inserts every new watch at
-- position 1. To reach an order: keep the part at the bottom that already matches,
-- untrack the rest, and re-track it bottom-to-top.
local function applyOrder(want)
  local cur = watchList()
  if #cur ~= #want then return true end
  local keep = 0
  while keep < #cur and cur[#cur - keep] == want[#want - keep] do keep = keep + 1 end
  if keep == #cur then return true end
  -- Untracking the quest the arrow points at clears the arrow; put it back afterwards.
  local arrow = C_SuperTrack.GetSuperTrackedQuestID()
  reordering = true
  for i = 1, #want - keep do
    local q = want[i]
    expect[q] = false
    C_QuestLog.RemoveQuestWatch(q)
  end
  for i = #want - keep, 1, -1 do
    local q = want[i]
    expect[q] = true
    C_QuestLog.AddQuestWatch(q)
    if not isWatched(q) then expect[q] = nil end
  end
  reordering = false
  if arrow and arrow > 0 and isWatched(arrow) and C_SuperTrack.GetSuperTrackedQuestID() ~= arrow then
    expectSuper = arrow
    C_SuperTrack.SetSuperTrackedQuestID(arrow)
    dbg("re-tracking cleared the arrow; put it back on", title(arrow))
  end
  cur = watchList()
  for i = 1, #want do
    if cur[i] ~= want[i] then return false end
  end
  return true
end

-- This zone's quests on top (nearest first when sorting), finished ones from elsewhere below.
local function fixOrder(sortByDistance)
  if orderGaveUp then return end
  local main, fin = {}, {}
  for i, q in ipairs(watchList()) do
    if extras[q] then fin[#fin + 1] = q else main[#main + 1] = { q = q, i = i, d = sortByDistance and dist(q) } end
  end
  if sortByDistance then
    local arrow = C_SuperTrack.GetSuperTrackedQuestID()
    table.sort(main, function(a, b)
      if a.d and b.d and a.d == b.d and (a.q == arrow or b.q == arrow) then return a.q == arrow end
      if a.d and b.d then return a.d < b.d end
      if a.d or b.d then return a.d ~= nil end
      return a.i < b.i
    end)
  end
  local want = {}
  for _, it in ipairs(main) do want[#want + 1] = it.q end
  for _, q in ipairs(fin) do want[#want + 1] = q end
  if not applyOrder(want) then
    orderGaveUp = true
    dbg("couldn't reorder the tracker - not trying again until you change zones or click the button")
  end
end

-- ---------------------------------------------------------------- main pass

local function refresh(forceSort)
  if not S.enabled then return end
  if InCombatLockdown() then afterCombat = true return end
  -- On a flight path, wait for landing (PLAYER_CONTROL_GAINED) instead of re-tracking
  -- at every zone border you fly over.
  if UnitOnTaxi("player") then return end
  local zone = zoneMap()
  if not zone then return end
  if zone ~= lastZone then
    wipe(suppressed)
    lastZone = zone
    orderGaveUp = false
    arrowPaused = false
    sortWanted = true
    local info = C_Map.GetMapInfo(zone)
    dbg("zone:", info and info.name or "?", zone)
  end

  -- Quests with a map area in this zone.
  local wanted, list = {}, {}
  for _, e in ipairs(C_QuestLog.GetQuestsOnMap(zone) or {}) do
    local q = e.questID
    if q and not wanted[q] and not suppressed[q] then
      local idx = C_QuestLog.GetLogIndexForQuestID(q)
      if idx then
        if S.turnIns or not C_QuestLog.IsComplete(q) then
          wanted[q] = true
          list[#list + 1] = { q = q, idx = idx, d = dist(q) }
        end
      end
    end
  end

  -- Who gets in first when the tracker is full.
  if S.nearestFirst then
    table.sort(list, function(a, b)
      if a.d and b.d then return a.d < b.d end
      if a.d or b.d then return a.d ~= nil end
      return a.idx < b.idx
    end)
  else
    table.sort(list, function(a, b) return a.idx < b.idx end)
  end

  -- Finished quests from anywhere, quest log order, after this zone's quests.
  local extraList = {}
  if S.finishedAnywhere then
    local n = C_QuestLog.GetNumQuestLogEntries() or 0
    for i = 1, n do
      local info = C_QuestLog.GetInfo(i)
      local q = info and not info.isHeader and info.questID
      if q and q > 0 and not wanted[q] and not C.dismissed[q] and C_QuestLog.IsComplete(q)
          and not (S.skipHandOffs and isHandOff(q)) then
        wanted[q] = true
        extraList[#extraList + 1] = q
      end
    end
  end

  -- Untrack first so the slots are free.
  for _, q in ipairs(watchList()) do
    if not wanted[q] and not (S.keepPins and C.pins[q]) then
      expect[q] = false
      C_QuestLog.RemoveQuestWatch(q)
      dbg("untrack", title(q))
    end
  end

  -- This zone's quests get free slots before finished ones.
  local max = Constants and Constants.QuestWatchConsts and Constants.QuestWatchConsts.MAX_QUEST_WATCHES
  local free = max and (max - C_QuestLog.GetNumQuestWatches()) or math.huge
  local addZone, addExtra, skipped = {}, {}, 0
  for _, it in ipairs(list) do
    if not isWatched(it.q) then
      if free > 0 then addZone[#addZone + 1] = it.q; free = free - 1 else skipped = skipped + 1 end
    end
  end
  for _, q in ipairs(extraList) do
    if not isWatched(q) then
      if free > 0 then addExtra[#addExtra + 1] = q; free = free - 1 else skipped = skipped + 1 end
    end
  end
  if skipped > 0 then dbg("tracker full (" .. tostring(max) .. "),", skipped, "quests left untracked") end

  local function watch(q, what)
    expect[q] = true
    C_QuestLog.AddQuestWatch(q)
    if isWatched(q) then
      dbg(what, title(q))
    else
      expect[q] = nil
      dbg("tracker refused", title(q), "- watched:", C_QuestLog.GetNumQuestWatches())
    end
  end
  -- New watches go in at the top, so add bottom-to-top.
  for i = #addExtra, 1, -1 do watch(addExtra[i], "track finished") end
  for i = #addZone, 1, -1 do watch(addZone[i], "track") end

  wipe(extras)
  for _, q in ipairs(extraList) do extras[q] = true end

  -- Distance sort only at the moments that call for it; any other pass just keeps
  -- finished quests at the bottom, so the list doesn't reshuffle with every kill/loot.
  fixOrder(forceSort or (S.autoSort and (sortWanted or S.resortEvery)))
  sortWanted = false
  nearestTick()
end

function schedule()
  if pending then return end
  pending = true
  C_Timer.After(0, function()
    pending = false
    classifyPending()
    refresh()
  end)
end

-- Returns true when the change was our own, so it doesn't trigger another refresh.
-- Anything else is classified a frame later (classifyPending): the game's own tracking
-- (auto-track on accept or on progress, untrack on turn-in) arrives around the matching
-- QUEST_ACCEPTED / QUEST_WATCH_UPDATE / QUEST_REMOVED in either order.
local function onWatchChanged(q)
  if not q then return end
  local added = isWatched(q)
  if expect[q] ~= nil and expect[q] == added then
    expect[q] = nil
    return true
  end
  expect[q] = nil
  pendingWatch[q] = true
end

function classifyPending()
  for q in pairs(pendingWatch) do
    if autoMark[q] or not C_QuestLog.GetLogIndexForQuestID(q) then
      -- the game did it (or the quest is gone); ZoneTrack manages it like any other
    elseif isWatched(q) then
      C.pins[q] = true
      suppressed[q] = nil
      dbg("you tracked", title(q), "- kept in every zone")
    elseif extras[q] then
      C.pins[q] = nil
      C.dismissed[q] = true
      dbg("you untracked finished", title(q), "- won't track it again")
    else
      C.pins[q] = nil
      suppressed[q] = true
      dbg("you untracked", title(q), "- left alone until you change zones")
    end
  end
  if pendingSuper then
    -- The game points the arrow at a quest you just accepted; that isn't your pick.
    if not autoMark[pendingSuper] and C_SuperTrack.GetSuperTrackedQuestID() == pendingSuper and S.autoArrow then
      arrowPaused = true
      dbg("you pointed the arrow at", title(pendingSuper), "- auto arrow paused until you change zones or click the button")
    end
    pendingSuper = nil
    if updateButton then updateButton() end
  end
  wipe(pendingWatch)
  wipe(autoMark)
end

local function onSuperTrackChanged()
  local cur = C_SuperTrack.GetSuperTrackedQuestID()
  if reordering then return end
  if expectSuper and cur == expectSuper then
    expectSuper = nil
    return
  end
  expectSuper = nil
  if not cur or cur == 0 then
    -- Arrow target gone (quest untracked/turned in, or cleared outside a reorder):
    -- your pick no longer exists, so auto takes over again.
    dbg("arrow cleared")
    arrowPaused = false
    nearestTick()
    if updateButton then updateButton() end
    return
  end
  pendingSuper = cur
  schedule()
end

-- Button / manual: sort the tracker by distance and point the arrow at the nearest quest now.
local function sortNow()
  orderGaveUp = false
  arrowPaused = false
  if InCombatLockdown() then
    nearestTick(true)
    afterCombat = true
    return
  end
  refresh(true)
  nearestTick(true)
end

-- ---------------------------------------------------------------- button

local button
local function buildButton()
  button = CreateFrame("Button", "ZoneTrackButton", UIParent)
  button:SetSize(32, 32)
  button:SetFrameStrata("MEDIUM")
  button:SetMovable(true)
  button:SetClampedToScreen(true)
  button:RegisterForDrag("LeftButton")
  button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  local icon = button:CreateTexture(nil, "ARTWORK")
  icon:SetAllPoints()
  icon:SetTexture("Interface\\Icons\\INV_Misc_Spyglass_03")
  button:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")

  if S.buttonPos then
    local p = S.buttonPos
    button:SetPoint(p[1], UIParent, p[2], p[3], p[4])
  elseif ObjectiveTrackerFrame then
    button:SetPoint("BOTTOMRIGHT", ObjectiveTrackerFrame, "TOPLEFT")
  else
    button:SetPoint("CENTER")
  end

  button:SetScript("OnDragStart", button.StartMoving)
  button:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local p, _, rp, x, y = self:GetPoint()
    S.buttonPos = { p, rp, x, y }
  end)
  button:SetScript("OnClick", function(self, b)
    if b == "RightButton" then
      if openSettings then openSettings() end
    else
      sortNow()
    end
  end)
  button:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("ZoneTrack")
    GameTooltip:AddLine("Left-click: sort the tracker by distance and point the arrow at the nearest quest", 1, 1, 1, true)
    GameTooltip:AddLine("Right-click: settings", 1, 1, 1)
    GameTooltip:AddLine("Drag: move this button", 1, 1, 1)
    if not S.enabled then
      GameTooltip:AddLine("ZoneTrack is turned off", 1, 0.3, 0.3)
    elseif not S.autoArrow then
      GameTooltip:AddLine("Auto arrow: off", 0.7, 0.7, 0.7)
    elseif arrowPaused then
      GameTooltip:AddLine("Auto arrow: paused (you picked a quest)", 1, 0.8, 0.2)
    else
      GameTooltip:AddLine("Auto arrow: on", 0.3, 1, 0.3)
    end
    GameTooltip:Show()
  end)
  button:SetScript("OnLeave", function() GameTooltip:Hide() end)

  updateButton = function()
    button:SetShown(S.showButton)
    icon:SetDesaturated(not S.enabled)
  end
  updateButton()
end

-- ---------------------------------------------------------------- options

local panel
local function buildPanel()
  panel = CreateFrame("Frame")
  panel.name = "ZoneTrack"
  local controls = {}

  -- The options window gives the page a fixed area, so the content scrolls, and every
  -- row is laid out from measured text: widths follow the page, heights follow the wrap.
  local MARGIN, GAP = 16, 10
  local scroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
  local barWidth = type(scroll.ScrollBar) == "table" and scroll.ScrollBar:GetWidth() or 0
  scroll:SetPoint("TOPLEFT", 0, -4)
  -- The template hangs its scrollbar 6px outside the frame's right edge.
  scroll:SetPoint("BOTTOMRIGHT", -(barWidth + 6 + 4), 4)
  local content = CreateFrame("Frame", nil, scroll)
  content:SetSize(1, 1)
  scroll:SetScrollChild(content)

  -- Scroll cues on an overlay above the rows (the scroll child draws above the scroll
  -- frame's own textures). Not mouse-enabled, so clicks and the wheel reach the rows.
  local edges = CreateFrame("Frame", nil, panel)
  edges:SetAllPoints(scroll)
  edges:SetFrameLevel(scroll:GetFrameLevel() + 10)
  local more = edges:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  more:SetPoint("BOTTOM", edges, "BOTTOM", 0, 2)
  more:SetText("Scroll for more")
  local _, fontSize = more:GetFont()
  local function fade(edge, bottomAlpha, topAlpha)
    local t = edges:CreateTexture(nil, "ARTWORK")
    t:SetPoint(edge .. "LEFT")
    t:SetPoint(edge .. "RIGHT")
    t:SetHeight(math.ceil(fontSize) * 3)
    t:SetColorTexture(1, 1, 1, 1)
    -- VERTICAL: first color = bottom, second = top
    t:SetGradient("VERTICAL", CreateColor(0, 0, 0, bottomAlpha), CreateColor(0, 0, 0, topAlpha))
    return t
  end
  local bottomFade = fade("BOTTOM", 0.9, 0)
  local topFade = fade("TOP", 0, 0.9)
  local function updateEdges()
    local range, at = scroll:GetVerticalScrollRange() or 0, scroll:GetVerticalScroll() or 0
    local below = at < range - 1
    bottomFade:SetShown(below)
    more:SetShown(below)
    topFade:SetShown(at > 1)
    if type(scroll.ScrollBar) == "table" then scroll.ScrollBar:SetShown(range > 1) end
  end
  -- HookScript keeps the template's own handlers.
  scroll:HookScript("OnScrollRangeChanged", updateEdges)
  scroll:HookScript("OnVerticalScroll", updateEdges)

  local rows, prev = {}, nil
  local function newRow(gap)
    local row = CreateFrame("Frame", nil, content)
    if prev then
      row:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -(gap or GAP))
    else
      row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -MARGIN)
    end
    row:SetPoint("RIGHT", content, "RIGHT")
    row:SetHeight(1)
    prev = row
    rows[#rows + 1] = row
    return row
  end

  local function layout()
    local total = MARGIN
    for i, row in ipairs(rows) do
      row:SetHeight(math.max(1, row.measure()))
      total = total + row:GetHeight() + (i > 1 and (row.gap or GAP) or 0)
    end
    content:SetHeight(total + MARGIN)
  end
  scroll:SetScript("OnSizeChanged", function(self, w)
    content:SetWidth(w)
    layout()
  end)

  do
    local row = newRow()
    local head = row:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    head:SetPoint("TOPLEFT", MARGIN, 0)
    head:SetText("ZoneTrack")
    row.measure = function() return head:GetStringHeight() end
  end

  local function check(label, desc, get, set)
    local row = newRow()
    local cb = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", MARGIN, 0)
    local l = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    l:SetPoint("LEFT", cb, "RIGHT", 4, 1)
    l:SetPoint("RIGHT", row, "RIGHT", -MARGIN, 0)
    l:SetJustifyH("LEFT")
    l:SetText(label)
    local d = row:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    d:SetPoint("TOPLEFT", l, "BOTTOMLEFT", 0, -3)
    d:SetPoint("RIGHT", row, "RIGHT", -MARGIN, 0)
    d:SetJustifyH("LEFT")
    d:SetText(desc)
    row.measure = function()
      local cbH = cb:GetHeight()
      return math.max(cbH, cbH / 2 + l:GetStringHeight() / 2 + 3 + d:GetStringHeight())
    end
    cb:SetScript("OnClick", function(self)
      set(self:GetChecked() and true or false)
      if updateButton then updateButton() end
      schedule()
    end)
    cb.sync = function() cb:SetChecked(get()) end
    controls[#controls + 1] = cb
  end
  local function setting(key) return function() return S[key] end, function(v) S[key] = v end end

  check("Enabled",
    "Track the quests that have a highlighted area on this zone's map, and untrack the rest.",
    setting("enabled"))
  check("Keep quests I track by hand",
    "A quest you track yourself stays tracked in every zone. Off: it gets untracked like the rest when it has no area here.",
    setting("keepPins"))
  check("Track this zone's finished quests",
    "When a quest is finished, track it in the zone where you turn it in.",
    setting("turnIns"))
  check("Track finished quests from every zone",
    "Listed below this zone's quests, so you can see what's waiting to be turned in.",
    setting("finishedAnywhere"))
  check("Skip hand-off quests",
    "Finished quests with no item or spell reward and nothing done but talking to someone aren't tracked.",
    setting("skipHandOffs"))
  check("Sort the tracker nearest-first",
    "When the arrow moves to a different quest, you accept or turn in a quest, or you change zones. In combat it waits until the fight ends.",
    setting("autoSort"))
  check("Re-sort after every quest update",
    "Also re-sort after every kill, loot or objective change, not only when the arrow moves. The list moves around more.",
    setting("resortEvery"))
  check("Point the quest arrow at the nearest quest",
    "Rechecks as you move. Picking a quest's arrow yourself pauses this until you change zones or click the button.",
    function() return S.autoArrow end,
    function(v) S.autoArrow = v; arrowPaused = false; nearestTick() end)
  check("Blizzard auto-tracks quests when you accept them",
    "Game setting (autoQuestWatch). Either way, a new quest with no area in this zone gets untracked.",
    function() return GetCVar("autoQuestWatch") == "1" end,
    function(v) SetCVar("autoQuestWatch", v and "1" or "0") end)
  check("Show the ZoneTrack button",
    "Left-click sorts and re-aims the arrow, right-click opens these settings, drag to move it.",
    setting("showButton"))

  do
    local row = newRow()
    local oh = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    oh:SetPoint("TOPLEFT", MARGIN + 4, 0)
    oh:SetPoint("RIGHT", row, "RIGHT", -MARGIN, 0)
    oh:SetJustifyH("LEFT")
    oh:SetText("When the tracker is full, track first:")
    row.measure = function() return oh:GetStringHeight() end
  end
  local function radio(label, val)
    local row = newRow(2)
    row.gap = 2
    local rb = CreateFrame("CheckButton", nil, row, "UIRadioButtonTemplate")
    rb:SetPoint("TOPLEFT", MARGIN + 8, 0)
    local l = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    l:SetPoint("LEFT", rb, "RIGHT", 4, 0)
    l:SetPoint("RIGHT", row, "RIGHT", -MARGIN, 0)
    l:SetJustifyH("LEFT")
    l:SetText(label)
    row.measure = function() return math.max(rb:GetHeight(), l:GetStringHeight()) end
    rb:SetScript("OnClick", function()
      S.nearestFirst = val
      for _, c in ipairs(controls) do c.sync() end
      schedule()
    end)
    rb.sync = function() rb:SetChecked(S.nearestFirst == val) end
    controls[#controls + 1] = rb
  end
  radio("Quest log order", false)
  radio("Nearest quest area", true)

  check("Debug messages in chat",
    "Prints every track, untrack and arrow decision.",
    setting("debug"))

  panel:SetScript("OnShow", function()
    for _, c in ipairs(controls) do c.sync() end
    layout()
    -- Wrapped text reports its final height once it has been drawn at its width.
    C_Timer.After(0, layout)
    updateEdges()
  end)

  if Settings and Settings.RegisterCanvasLayoutCategory then
    local cat = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
    Settings.RegisterAddOnCategory(cat)
    openSettings = function() Settings.OpenToCategory(cat:GetID()) end
  elseif InterfaceOptions_AddCategory then
    InterfaceOptions_AddCategory(panel)
    openSettings = function()
      InterfaceOptionsFrame_OpenToCategory(panel)
      InterfaceOptionsFrame_OpenToCategory(panel)
    end
  end
  SLASH_ZONETRACK1 = "/zonetrack"
  SlashCmdList.ZONETRACK = function(msg)
    if openSettings then openSettings() else print("ZoneTrack: no options window API on this client") end
  end
end

-- ---------------------------------------------------------------- events

local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:SetScript("OnEvent", function(self, ev, a1, a2)
  if ev == "ADDON_LOADED" then
    if a1 ~= ADDON then return end
    self:UnregisterEvent("ADDON_LOADED")
    local firstRun = ZoneTrackSettings == nil
    ZoneTrackSettings = ZoneTrackSettings or {}
    for k, v in pairs(DEFAULTS) do
      if ZoneTrackSettings[k] == nil then ZoneTrackSettings[k] = v end
    end
    S = ZoneTrackSettings
    ZoneTrackChar = ZoneTrackChar or {}
    ZoneTrackChar.pins = ZoneTrackChar.pins or {}
    ZoneTrackChar.dismissed = ZoneTrackChar.dismissed or {}
    C = ZoneTrackChar
    for _, e in ipairs({ "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA", "ZONE_CHANGED",
        "ZONE_CHANGED_INDOORS", "QUEST_ACCEPTED", "QUEST_REMOVED", "QUEST_LOG_UPDATE",
        "QUEST_POI_UPDATE", "QUEST_WATCH_LIST_CHANGED", "SUPER_TRACKING_CHANGED",
        "PLAYER_STARTED_MOVING", "PLAYER_STOPPED_MOVING", "PLAYER_REGEN_ENABLED",
        "PLAYER_INSIDE_QUEST_BLOB_STATE_CHANGED", "PLAYER_MOUNT_DISPLAY_CHANGED",
        "QUEST_WATCH_UPDATE", "PLAYER_CONTROL_GAINED" }) do
      self:RegisterEvent(e)
    end
    buildPanel()
    buildButton()
    if firstRun then
      print("|cff66ccffZoneTrack|r tracks the quests with a highlighted area on your current zone's map, " ..
        "plus finished quests waiting to be turned in, and untracks the rest. Quests you track by hand " ..
        "from now on stay tracked everywhere. Settings: /zonetrack or right-click the spyglass button.")
    end
    -- Blizzard's tracker re-sorts the watch list on zone/map changes; put our order back.
    hooksecurefunc(C_QuestLog, "SortQuestWatches", function()
      if S.enabled then
        sortWanted = true
        schedule()
      end
    end)
    return
  end

  if ev == "QUEST_WATCH_LIST_CHANGED" then
    if onWatchChanged(a1) then return end
  elseif ev == "SUPER_TRACKING_CHANGED" then
    onSuperTrackChanged()
    return
  elseif ev == "QUEST_WATCH_UPDATE" then
    -- Objective progress; Blizzard may auto-track the quest because of it.
    if a1 then autoMark[a1] = true end
  elseif ev == "PLAYER_CONTROL_GAINED" then
    -- Landed from a flight path (refresh skips while on one).
  elseif ev == "PLAYER_INSIDE_QUEST_BLOB_STATE_CHANGED" then
    if S.debug then
      local insideNow = {}
      for _, q in ipairs(watchList()) do
        if isInside(q) then insideNow[#insideNow + 1] = tostring(q) end
      end
      dbg((a2 and "entered" or "left") .. " area of", title(a1),
          "| watched:", tostring(isWatched(a1)),
          "| IsInsideQuestBlob now true for:", #insideNow > 0 and table.concat(insideNow, ",") or "none")
    end
    nearestTick()
    if moving then return end
  elseif ev == "PLAYER_STARTED_MOVING" then
    moving = true
    nearestTick()
    return
  elseif ev == "PLAYER_MOUNT_DISPLAY_CHANGED" then
    -- Speed changed without a new "started moving"; re-time the next check.
    nearestTick()
    return
  elseif ev == "PLAYER_STOPPED_MOVING" then
    moving = false
    nearestTick()
    return
  elseif ev == "PLAYER_REGEN_ENABLED" then
    nearestTick()
    if not afterCombat then return end
    afterCombat = false
  elseif ev == "QUEST_ACCEPTED" then
    sortWanted = true
    local q = a2 or a1
    if q then autoMark[q] = true end
  elseif ev == "QUEST_REMOVED" then
    sortWanted = true
    if a1 then
      autoMark[a1] = true
      C.pins[a1] = nil
      C.dismissed[a1] = nil
      suppressed[a1] = nil
    end
  end
  schedule()
end)

