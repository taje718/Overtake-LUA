-- No Hesi style overtake scorer for AssettoServer (CSP online script)
-- 3 minute rounds. Slowing down does not end anything. The combo only
-- resets after COMBO_TIMEOUT_S with no pass, or on a crash.
--
-- Scoring per pass:
--   (base + speed bonus) x PROXIMITY multiplier x SPEED multiplier
--     PROXIMITY: closer = bigger, up to PROX_MULT_MAX
--     SPEED:     x1.1 at 0 km/h, rising evenly to x4.0 at 300 km/h (186.4 mph).
--                The current value is shown live on the speedometer.
--   + SQUEEZE bonus when several cars are passed within SQUEEZE_WINDOW_S
--     of each other (e.g. threading between two cars). The squeeze bonus
--     grows with the number of cars and how close you were to all of them.
--   all of that is then multiplied by the combo multiplier.
--
-- When the run ends, a CLEAN RUN bonus is added to the final score:
--   no crashes: +50,000 flat, then +50%; 1 crash: +25,000 flat, then +25%;
--   run ended by crashing out: nothing. (The flat points are added first and
--   the percentage is applied to the total including them.)
--
-- Leaderboard: each submitted run includes the car you used and your
-- average speed over the run (AVG MPH). The final score screen shows the
-- average too.
--
-- HUD: click and drag the score panel or the speedometer to move it.
-- Right-click a panel to put it back in its default spot. Positions are
-- remembered between sessions.
-- Speedometer: click the MPH / KM/H switch on the speedometer to change
-- units. It starts on MPH and your choice is remembered between sessions.
--
-- Add to csp_extra_options.ini:
--   [SCRIPT_1]
--   SCRIPT = 'https://your-host/overtake.lua'

---------------------------------------------------------------------
-- CONFIG
---------------------------------------------------------------------
local CFG = {
  ROUND_TIME_S       = 180,   -- round length (3:00)
  RESULT_SHOW_S      = 8,     -- how long the final score screen shows
  COMBO_TIMEOUT_S    = 10,    -- combo resets if no pass within this time
  MAX_PASS_DIST      = 25.0,  -- max total distance (m) for a pass to count
  MAX_LATERAL        = 4.0,   -- max sideways offset (m) for a pass to count
  MIN_PASS_SPEED_KMH = 40,    -- you must be at least this fast for a pass to count
  BASE_POINTS        = 100,   -- points per pass (before multipliers)
  SPEED_BONUS_PER_10 = 5,     -- extra points per 10 km/h above SPEED_BONUS_FROM
  SPEED_BONUS_FROM   = 80,
  -- Speed multiplier (applied to every pass)
  SPEED_MULT_MIN     = 1.1,   -- multiplier at 0 km/h
  SPEED_MULT_MAX     = 4.0,   -- multiplier at SPEED_MULT_FULL_KMH and above
  SPEED_MULT_FULL_KMH = 300,  -- speed (km/h) that earns the max speed multiplier (300 km/h = 186.4 mph)
  -- Proximity multiplier (sideways distance between car centres, in metres)
  PROX_NEAR_LATERAL  = 2.0,   -- at or below this you get the full PROX_MULT_MAX
  PROX_FAR_LATERAL   = 4.0,   -- at or above this the multiplier is x1.0
  PROX_MULT_MAX      = 3.0,   -- points multiplier for a paint-trading pass
  PROX_POPUP_FROM    = 1.5,   -- show "CLOSE PASS" when the proximity mult reaches this
  -- Squeeze bonus (passing several cars within a short time of each other)
  SQUEEZE_WINDOW_S   = 0.3,   -- each extra pass must come within this time of the previous one
  SQUEEZE_BONUS_SCALE = 1.5,  -- scales the whole squeeze bonus (1.0 = original, 1.5 = +50%)
  SQUEEZE_BASE       = 0.5,   -- bonus multiplier added per extra car, even if they were far apart
  SQUEEZE_PROX       = 1.0,   -- extra per extra car at full proximity (scaled by average closeness)
  SQUEEZE_MAX_CARS   = 5,     -- cars beyond this stop adding to the squeeze multiplier
  MULT_STEP          = 0.25,  -- combo multiplier added per consecutive pass
  MULT_MAX           = 10.0,
  MAX_CRASHES        = 2,     -- the run ends on this crash (1st crash only resets the combo)
  CRASH_COOLDOWN_S   = 2.0,   -- ignore further contact this long after a crash (one scrape = one crash)
  CRASH_SCORE_LOSS   = 0.0,   -- fraction of round score lost on a non-final crash (0 = none, 0.5 = half)
  -- Clean run bonus: fraction of your final score added, by number of crashes in the run.
  -- Crash counts that are not listed (and runs that end by crashing out) get no bonus.
  CLEAN_BONUS        = { [0] = 0.5, [1] = 0.25 },
  -- Flat clean run bonus (points), by number of crashes. Added to your score first,
  -- and then the percentage bonus above is applied on top of that total.
  CLEAN_FLAT         = { [0] = 50000, [1] = 25000 },
  PIT_RESET_SAVES_BEST = true, -- true: score is banked toward your best when you return to pits. false: score is thrown away
  TELEPORT_DIST      = 200,   -- a jump bigger than this (m) in one frame counts as a teleport to pits
  -- Discord leaderboard (see worker.js). Leave LEADERBOARD_URL empty to turn it off.
  LEADERBOARD_URL    = 'https://swimteamleaderboard.tajewithehs.workers.dev',    -- your Cloudflare Worker URL
  LEADERBOARD_KEY    = 'k7Qm29xPzr41',    -- same value as SUBMIT_KEY in the Worker
  MIN_SUBMIT_SCORE   = 100000,  -- runs scoring less than this are not sent
  -- Only cars whose folder name contains one of these words count as traffic.
  -- "traffic" matches traffic_* and nohesi_traffic_* cars. Other players
  -- are not counted. Leave the list empty to count every other car.
  TRAFFIC_MODELS     = { "traffic", "mtn_victoria" },
  -- Speedometer
  SHOW_SPEEDO        = true,
  SPEEDO_SCALE       = 1.5,   -- 1.0 = the old size, 1.5 = 50% bigger, 2.0 = double
  SPEEDO_USE_MPH     = true,  -- starting unit: true = mph, false = km/h (the on-screen switch changes it and is remembered)
  SPEEDO_FALLBACK_RPM = 8000, -- used if the car does not report a limiter rpm
  -- HUD
  HUD_DRAG           = true,  -- false: panels cannot be moved (they stay at their default spots)
}

---------------------------------------------------------------------
-- STATE
---------------------------------------------------------------------
local storage = ac.storage{ bestScore = 0 }

-- remembered speedometer unit (starts from CFG.SPEEDO_USE_MPH the first time)
local prefs = ac.storage{ useMph = CFG.SPEEDO_USE_MPH }

local S = {
  phase = 'idle',        -- 'idle' (waiting for first pass), 'running', 'finished'
  timeLeft = CFG.ROUND_TIME_S,
  finishTimer = 0,
  score = 0,
  combo = 0,
  mult = 1.0,
  comboTimer = 0,
  popup = '', popupTimer = 0, popupGood = true,
  newBest = false,
  crashes = 0,
  crashCooldown = 0,
  endReason = 'TIME UP',
  cleanPct = 0,          -- clean run bonus applied to the last finished run (0.5 = +50%)
  cleanPts = 0,          -- points that bonus added (flat + percentage)
  cleanFlat = 0,         -- the flat part of the clean run bonus
  cleanCrashes = 0,      -- crashes in the last finished run
  speedSum = 0,          -- sum of speed x time while running (km/h * s), for the average
  runTime = 0,           -- seconds spent running
  avgMph = 0,            -- average speed of the last finished run
  clock = 0,             -- running time, used for the squeeze window
  group = nil,           -- current squeeze group: { n, sumPts, sumProx, paid, lastT }
  prevForward = {},      -- [carIndex] = last forward distance
}

---------------------------------------------------------------------
-- HELPERS
---------------------------------------------------------------------
local function isTraffic(index)
  if #CFG.TRAFFIC_MODELS == 0 then return true end
  local id = ac.getCarID(index) or ''
  for _, m in ipairs(CFG.TRAFFIC_MODELS) do
    if id:find(m, 1, true) then return true end
  end
  return false
end

local function showPopup(text, good)
  S.popup, S.popupGood, S.popupTimer = text, good, 1.8
end

local function resetCombo(reason)
  if S.combo > 0 then showPopup(reason, false) end
  S.combo, S.mult, S.comboTimer = 0, 1.0, 0
end

local function startRound()
  S.phase = 'running'
  S.timeLeft = CFG.ROUND_TIME_S
  S.score, S.combo, S.mult, S.comboTimer = 0, 0, 1.0, 0
  S.newBest = false
  S.crashes, S.crashCooldown = 0, 0
  S.cleanPct, S.cleanPts, S.cleanCrashes, S.cleanFlat = 0, 0, 0, 0
  S.speedSum, S.runTime, S.avgMph = 0, 0, 0
  S.group = nil
end

local function jsonStr(s)
  return (tostring(s or ''):gsub('%c', ' '):gsub('\\', '\\\\'):gsub('"', '\\"'))
end

-- sends the finished run to the leaderboard relay (if configured)
-- fields: name, score, key, car (display name), carId (folder name), avgMph
local function submitScore(score, avgMph)
  if CFG.LEADERBOARD_URL == '' or score < CFG.MIN_SUBMIT_SCORE then return end
  local name = ac.getDriverName(0) or 'Unknown'
  local carId = ac.getCarID(0) or ''
  local carName = carId
  local okName, n = pcall(ac.getCarName, 0)
  if okName and n and n ~= '' then carName = n end
  local body = string.format('{"name":"%s","score":%d,"key":"%s","car":"%s","carId":"%s","avgMph":%.1f}',
    jsonStr(name), score, jsonStr(CFG.LEADERBOARD_KEY),
    jsonStr(carName), jsonStr(carId), avgMph or 0)
  local ok, e = pcall(function()
    web.post(CFG.LEADERBOARD_URL, { ['Content-Type'] = 'application/json' }, body,
      function(err, response)
        if err then ac.log('leaderboard error: ' .. tostring(err)) end
      end)
  end)
  if not ok then ac.log('leaderboard failed: ' .. tostring(e)) end
end

local function endRound(reason)
  S.endReason = reason or 'TIME UP'
  S.phase = 'finished'
  S.finishTimer = CFG.RESULT_SHOW_S
  S.combo, S.mult, S.comboTimer = 0, 1.0, 0
  S.group = nil

  -- clean run bonus: the fewer times you hit something, the more score you keep.
  -- Runs that ended because you crashed out get nothing.
  local crashedOut = (S.endReason == 'CRASHED OUT')
  local pct = crashedOut and 0 or (CFG.CLEAN_BONUS[S.crashes] or 0)
  local flat = crashedOut and 0 or (CFG.CLEAN_FLAT[S.crashes] or 0)
  S.cleanPct = pct
  S.cleanFlat = flat
  S.cleanCrashes = S.crashes
  -- flat bonus goes in first, then the percentage applies to the total
  S.cleanPts = flat + math.floor((S.score + flat) * pct)
  S.score = S.score + S.cleanPts

  -- average speed over the run (time-weighted), in mph
  local avgKmh = S.runTime > 0 and (S.speedSum / S.runTime) or 0
  S.avgMph = avgKmh * 0.621371

  local final = math.floor(S.score)
  submitScore(final, S.avgMph)
  if final > storage.bestScore then
    storage.bestScore = final
    S.newBest = true
  end
end

-- 0 (far, at the edge of the proximity range) .. 1 (as close as it gets)
local function proximityFactor(lateral)
  local span = math.max(0.01, CFG.PROX_FAR_LATERAL - CFG.PROX_NEAR_LATERAL)
  return math.saturate((CFG.PROX_FAR_LATERAL - lateral) / span)
end

-- x1.1 at 0 km/h, rising in a straight line to x4.0 at 300 km/h (186.4 mph)
local function speedMultiplier(speedKmh)
  local t = math.saturate(speedKmh / math.max(1, CFG.SPEED_MULT_FULL_KMH))
  return CFG.SPEED_MULT_MIN + (CFG.SPEED_MULT_MAX - CFG.SPEED_MULT_MIN) * t
end

local function registerPass(speed, lateral)
  if S.phase == 'idle' then startRound() end

  S.combo = S.combo + 1
  S.mult = math.min(CFG.MULT_MAX, 1.0 + (S.combo - 1) * CFG.MULT_STEP)
  S.comboTimer = CFG.COMBO_TIMEOUT_S

  -- base points + speed bonus, scaled by how close the pass was and how fast you were going
  local base = CFG.BASE_POINTS
    + math.max(0, (speed - CFG.SPEED_BONUS_FROM) / 10) * CFG.SPEED_BONUS_PER_10
  local prox = proximityFactor(lateral)
  local proxMult = 1.0 + (CFG.PROX_MULT_MAX - 1.0) * prox
  local speedMult = speedMultiplier(speed)
  local passPts = base * proxMult * speedMult

  -- squeeze group: passes that follow each other within SQUEEZE_WINDOW_S
  local g = S.group
  if g and (S.clock - g.lastT) <= CFG.SQUEEZE_WINDOW_S then
    g.n = g.n + 1
    g.sumPts = g.sumPts + passPts
    g.sumProx = g.sumProx + prox
  else
    g = { n = 1, sumPts = passPts, sumProx = prox, paid = 0 }
    S.group = g
  end
  g.lastT = S.clock

  -- the group's bonus is paid out in steps as each extra car is passed
  local squeezePay = 0
  if g.n >= 2 then
    local cars = math.min(g.n, CFG.SQUEEZE_MAX_CARS)
    local avgProx = g.sumProx / g.n
    local squeezeMult = 1.0 + (cars - 1) * (CFG.SQUEEZE_BASE + CFG.SQUEEZE_PROX * avgProx)
    squeezePay = math.max(0, g.sumPts * (squeezeMult - 1.0) * CFG.SQUEEZE_BONUS_SCALE - g.paid)
    g.paid = g.paid + squeezePay
  end

  local gained = (passPts + squeezePay) * S.mult
  S.score = S.score + gained

  if g.n >= 2 then
    showPopup(string.format('SQUEEZE x%d  +%d', g.n, math.floor(gained)), true)
  elseif proxMult >= CFG.PROX_POPUP_FROM then
    showPopup('CLOSE PASS  +' .. math.floor(gained), true)
  else
    showPopup('+' .. math.floor(gained), true)
  end
end

local function fmtTime(t)
  t = math.max(0, math.ceil(t))
  return string.format('%d:%02d', math.floor(t / 60), t % 60)
end

-- text for the clean run line on the final score screen
local function cleanText()
  if S.cleanPts > 0 then
    local label = (S.cleanCrashes == 0) and 'CLEAN RUN' or (S.cleanCrashes .. ' HIT')
    local parts = {}
    if S.cleanFlat > 0 then parts[#parts + 1] = '+' .. S.cleanFlat end
    if S.cleanPct > 0 then parts[#parts + 1] = string.format('+%d%%', math.floor(S.cleanPct * 100 + 0.5)) end
    return label .. '  ' .. table.concat(parts, ' ') .. '  (+' .. S.cleanPts .. ')'
  end
  return 'NO CLEAN BONUS'
end

---------------------------------------------------------------------
-- UPDATE
---------------------------------------------------------------------
local wasColliding = false
local lastPos = nil

function script.update(dt)
  local player = ac.getCar(0)
  if not player then return end

  S.popupTimer = math.max(0, S.popupTimer - dt)
  S.clock = S.clock + dt

  -- running average speed (time-weighted) for the leaderboard / result screen
  if S.phase == 'running' then
    S.speedSum = S.speedSum + player.speedKmh * dt
    S.runTime = S.runTime + dt
  end

  -- round timer / result screen
  if S.phase == 'running' then
    S.timeLeft = S.timeLeft - dt
    if S.timeLeft <= 0 then endRound() end
  elseif S.phase == 'finished' then
    S.finishTimer = S.finishTimer - dt
    if S.finishTimer <= 0 then
      S.phase = 'idle'
      S.timeLeft = CFG.ROUND_TIME_S
      S.score = 0
    end
  end

  -- returning to the pits (or teleporting there) resets the run
  local inPit = player.isInPit or player.isInPitlane
  local teleported = lastPos ~= nil and player.position:distance(lastPos) > CFG.TELEPORT_DIST
  lastPos = player.position:clone()
  if S.phase == 'running' and (inPit or teleported) then
    if CFG.PIT_RESET_SAVES_BEST then
      endRound('BACK TO PITS')
    else
      S.phase = 'idle'
      S.timeLeft = CFG.ROUND_TIME_S
      S.score, S.combo, S.mult, S.comboTimer = 0, 0, 1.0, 0
      S.crashes, S.crashCooldown = 0, 0
      S.group = nil
    end
    S.prevForward = {}
  elseif teleported then
    S.prevForward = {}
  end

  -- crash: 1st resets the combo, reaching MAX_CRASHES ends the run
  S.crashCooldown = math.max(0, S.crashCooldown - dt)
  local colliding = (player.collisionDepth or 0) > 0
  if colliding and not wasColliding and S.phase == 'running' and S.crashCooldown <= 0 then
    S.crashes = S.crashes + 1
    S.crashCooldown = CFG.CRASH_COOLDOWN_S
    if S.crashes >= CFG.MAX_CRASHES then
      endRound('CRASHED OUT')
    else
      if CFG.CRASH_SCORE_LOSS > 0 then
        S.score = S.score * (1 - CFG.CRASH_SCORE_LOSS)
      end
      S.combo = math.max(S.combo, 1)  -- make sure the popup shows
      resetCombo('CRASH  ' .. S.crashes .. '/' .. CFG.MAX_CRASHES)
    end
  end
  wasColliding = colliding

  -- combo timeout (no passes for COMBO_TIMEOUT_S)
  if S.phase == 'running' and S.combo > 0 then
    S.comboTimer = S.comboTimer - dt
    if S.comboTimer <= 0 then resetCombo('COMBO LOST') end
  end

  -- pass detection
  local speed = player.speedKmh
  local look, side = player.look, player.side
  local count = ac.getSim().carsCount
  for i = 1, count - 1 do
    local other = ac.getCar(i)
    if other and other.isConnected and isTraffic(i) then
      local rel = other.position - player.position
      local forward = rel:dot(look)
      local lateral = math.abs(rel:dot(side))
      local prev = S.prevForward[i]

      -- crossed from ahead (+) to behind (-) of the player, and we are the
      -- faster car (stops traffic passing you while you sit still)
      if prev and prev > 0 and forward <= 0
         and S.phase ~= 'finished'
         and math.abs(prev) + math.abs(forward) < CFG.MAX_PASS_DIST
         and lateral < CFG.MAX_LATERAL
         and speed >= CFG.MIN_PASS_SPEED_KMH
         and speed > other.speedKmh then
        registerPass(speed, lateral)
      end
      S.prevForward[i] = forward
    end
  end
end

---------------------------------------------------------------------
-- UI
---------------------------------------------------------------------
local function lerp(a, b, t) return a + (b - a) * t end

-- multiplier colour: ice blue -> yellow -> red as the multiplier climbs
local function multRGB(m)
  local t = math.saturate((m - 1) / (CFG.MULT_MAX - 1))
  if t < 0.5 then
    local k = t / 0.5
    return lerp(0.55, 1.0, k), lerp(0.85, 0.85, k), lerp(1.0, 0.2, k)
  else
    local k = (t - 0.5) / 0.5
    return 1.0, lerp(0.85, 0.3, k), lerp(0.2, 0.15, k)
  end
end

local function textCenter(text, size, cx, y, col)
  local w = ui.measureDWriteText(text, size).x
  ui.dwriteDrawText(text, size, vec2(cx - w / 2, y), col)
end

local function textRight(text, size, rx, y, col)
  local w = ui.measureDWriteText(text, size).x
  ui.dwriteDrawText(text, size, vec2(rx - w, y), col)
end

local GREY = rgbm(0.65, 0.7, 0.78, 1)
local WHITE = rgbm(1, 1, 1, 1)

-- The window is wider than the panel (MARGIN on each side) so nothing
-- near the edges gets clipped by the window bounds.
local MARGIN = 30

---------------------------------------------------------------------
-- HUD LAYOUT + DRAGGING
---------------------------------------------------------------------
local NOPOS = -99999
local layout = ac.storage{ scoreX = NOPOS, scoreY = NOPOS, speedoX = NOPOS, speedoY = NOPOS }

-- positions the player has dragged the panels to (window top-left corner)
local livePos = {}
if layout.scoreX ~= NOPOS then livePos.score = vec2(layout.scoreX, layout.scoreY) end
if layout.speedoX ~= NOPOS then livePos.speedo = vec2(layout.speedoX, layout.speedoY) end

local SCORE_W, SCORE_H = 460, 250   -- score panel size (the window is a bit bigger)

local function speedoPanelSize()
  local k = CFG.SPEEDO_SCALE
  return 340 * k, 176 * k
end

local function scorePanelH()
  if S.phase == 'running' then return 126 end
  if S.phase == 'finished' then return 176 end
  return 100
end

local function winSizeOf(key)
  if key == 'score' then
    return vec2(SCORE_W + MARGIN * 2, SCORE_H + 20)
  end
  local w, h = speedoPanelSize()
  return vec2(w + MARGIN * 2, h + 20)
end

local function defaultPos(key)
  local scr = ac.getUI().windowSize
  local ws = winSizeOf(key)
  if key == 'score' then
    return vec2(scr.x / 2 - ws.x / 2, 50)
  end
  return vec2(scr.x - ws.x - 20, scr.y - ws.y - 40)
end

-- keeps a panel on screen
local function clampPos(p, ws)
  local scr = ac.getUI().windowSize
  local x = math.max(-MARGIN, math.min(p.x, scr.x - ws.x + MARGIN))
  local y = math.max(0, math.min(p.y, scr.y - ws.y))
  return vec2(x, y)
end

local function getPos(key)
  local p = livePos[key] or defaultPos(key)
  return clampPos(p, winSizeOf(key))
end

-- the visible panel (what you click on to drag), in screen coordinates
local function panelRect(key)
  local pos = getPos(key)
  local w, h
  if key == 'score' then w, h = SCORE_W, scorePanelH()
  else w, h = speedoPanelSize() end
  return pos + vec2(MARGIN + 10, 0), pos + vec2(MARGIN + w - 10, h)
end

local function inRect(p, a, b)
  return p.x >= a.x and p.x <= b.x and p.y >= a.y and p.y <= b.y
end

-- The MPH / KM/H switch on the speedometer. Layout is relative to the
-- panel's top-left corner: x, y, width of each half, height.
local function unitSwitchLayout()
  local k = CFG.SPEEDO_SCALE
  return 26 * k, 73 * k, 46 * k, 22 * k
end

-- the switch in screen coordinates (for clicking)
local function unitSwitchRect()
  local x, y, segW, h = unitSwitchLayout()
  local o = getPos('speedo') + vec2(MARGIN, 0)
  return o + vec2(x, y), o + vec2(x + segW * 2, y + h)
end

local dragging = nil          -- { key = 'score'|'speedo', grab = vec2 }
local mouseWasDown = false
local rightWasDown = false
local dragErrorLogged = false

local function handleHudInput()
  local down = ui.mouseDown(ui.MouseButton.Left)
  local rdown = ui.mouseDown(ui.MouseButton.Right)
  local mp = ui.mousePos()
  local keys = { 'speedo', 'score' }

  -- left press: first check the MPH / KM/H switch, otherwise start dragging a panel
  if down and not mouseWasDown and not dragging then
    local onSwitch = false
    if CFG.SHOW_SPEEDO then
      local a, b = unitSwitchRect()
      if inRect(mp, a, b) then
        prefs.useMph = not prefs.useMph
        onSwitch = true
      end
    end
    if not onSwitch then
      for _, key in ipairs(keys) do
        if key ~= 'speedo' or CFG.SHOW_SPEEDO then
          local a, b = panelRect(key)
          if inRect(mp, a, b) then
            dragging = { key = key, grab = mp - getPos(key) }
            break
          end
        end
      end
    end
  end

  -- right click on a panel: put it back in its default spot
  if rdown and not rightWasDown then
    for _, key in ipairs(keys) do
      local a, b = panelRect(key)
      if inRect(mp, a, b) then
        livePos[key] = nil
        layout[key .. 'X'] = NOPOS
        layout[key .. 'Y'] = NOPOS
        break
      end
    end
  end

  if dragging then
    if down then
      livePos[dragging.key] = clampPos(mp - dragging.grab, winSizeOf(dragging.key))
    else
      local p = livePos[dragging.key]
      if p then
        layout[dragging.key .. 'X'] = p.x
        layout[dragging.key .. 'Y'] = p.y
      end
      dragging = nil
    end
  end

  mouseWasDown, rightWasDown = down, rdown
end

---------------------------------------------------------------------
-- SCORE HUD
---------------------------------------------------------------------
local function drawScoreHud()
  local W = SCORE_W
  local pos = getPos('score')

  ui.transparentWindow('nohesiScore', pos, winSizeOf('score'), function()
    ui.pushDWriteFont('Segoe UI;Weight=Bold')

    local o = ui.getCursor() + vec2(MARGIN, 0)
    local left, right, cx = 30, W - 30, W / 2
    local ar, ag, ab = 0.55, 0.85, 1.0   -- accent colour
    local panelH = scorePanelH()

    if S.phase == 'running' then
      ar, ag, ab = multRGB(S.mult)
    elseif S.phase == 'finished' then
      if S.endReason == 'TIME UP' then ar, ag, ab = 1.0, 0.8, 0.3
      else ar, ag, ab = 1.0, 0.35, 0.3 end
    end

    local accent = rgbm(ar, ag, ab, 1)

    -- panel
    ui.drawRectFilled(o + vec2(10, 0), o + vec2(W - 10, panelH),
      rgbm(0.04, 0.05, 0.08, 0.78), 14, ui.CornerFlags.All)
    ui.drawRect(o + vec2(10, 0), o + vec2(W - 10, panelH),
      rgbm(ar, ag, ab, 0.85), 14, ui.CornerFlags.All, 2)

    -- white outline while the panel is being dragged
    if dragging and dragging.key == 'score' then
      ui.drawRect(o + vec2(6, -4), o + vec2(W - 6, panelH + 4),
        rgbm(1, 1, 1, 0.55), 16, ui.CornerFlags.All, 1)
    end

    if S.phase == 'idle' then
      textCenter('PASS A CAR TO START', 26, o.x + cx, o.y + 20, WHITE)
      textCenter(fmtTime(CFG.ROUND_TIME_S) .. ' ROUND     BEST ' .. storage.bestScore,
        16, o.x + cx, o.y + 62, GREY)

    elseif S.phase == 'running' then
      local urgent = S.timeLeft < 20

      -- left: time
      ui.dwriteDrawText('TIME', 12, o + vec2(left, 9), GREY)
      ui.dwriteDrawText(fmtTime(S.timeLeft), 30, o + vec2(left, 23),
        urgent and rgbm(1, 0.4, 0.3, 1) or WHITE)

      -- right: best
      textRight('BEST', 12, o.x + right, o.y + 9, GREY)
      textRight(tostring(storage.bestScore), 30, o.x + right, o.y + 23, WHITE)

      -- centre: score
      textCenter('SCORE', 12, o.x + cx, o.y + 7, GREY)
      textCenter(tostring(math.floor(S.score)), 44, o.x + cx, o.y + 17, WHITE)

      -- bottom row: combo / multiplier / crashes
      ui.dwriteDrawText('COMBO ' .. S.combo, 16, o + vec2(left, 78), GREY)
      textCenter(string.format('x%.2f', S.mult), 30, o.x + cx, o.y + 70, accent)
      textRight('CRASH ' .. S.crashes .. '/' .. CFG.MAX_CRASHES, 16, o.x + right, o.y + 78,
        S.crashes > 0 and rgbm(1, 0.4, 0.35, 1) or GREY)

      -- combo timer bar
      local barL, barR, barY = o.x + left, o.x + right, o.y + 112
      ui.drawRectFilled(vec2(barL, barY), vec2(barR, barY + 6),
        rgbm(1, 1, 1, 0.12), 3, ui.CornerFlags.All)
      if S.combo > 0 then
        local frac = math.saturate(S.comboTimer / CFG.COMBO_TIMEOUT_S)
        if frac > 0.01 then
          ui.drawRectFilled(vec2(barL, barY), vec2(barL + (barR - barL) * frac, barY + 6),
            rgbm(ar, ag, ab, 0.95), 3, ui.CornerFlags.All)
        end
      end

      -- popup under the panel
      if S.popupTimer > 0 then
        local a = math.saturate(S.popupTimer)
        local drift = (1 - S.popupTimer / 1.8) * 14
        local col = S.popupGood and rgbm(0.4, 1, 0.5, a) or rgbm(1, 0.35, 0.3, a)
        textCenter(S.popup, 28, o.x + cx, o.y + panelH + 8 + drift, col)
      end

    else -- finished
      textCenter(S.endReason, 22, o.x + cx, o.y + 8, accent)
      textCenter('FINAL SCORE', 12, o.x + cx, o.y + 36, GREY)
      textCenter(tostring(math.floor(S.score)), 44, o.x + cx, o.y + 48, WHITE)

      -- average speed over the run
      textCenter(string.format('AVG %d MPH', math.floor(S.avgMph + 0.5)), 16,
        o.x + cx, o.y + 106, WHITE)

      -- clean run bonus line
      textCenter(cleanText(), 16, o.x + cx, o.y + 128,
        S.cleanPts > 0 and rgbm(0.4, 1, 0.5, 1) or GREY)

      if S.newBest then
        textCenter('NEW PERSONAL BEST!', 17, o.x + cx, o.y + 150, rgbm(0.4, 1, 0.5, 1))
      else
        textCenter('BEST ' .. storage.bestScore, 17, o.x + cx, o.y + 150, GREY)
      end
    end

    ui.popDWriteFont()
  end)
end

---------------------------------------------------------------------
-- SPEEDOMETER
---------------------------------------------------------------------
local function drawSpeedo()
  local player = ac.getCar(0)
  if not player then return end

  local k = CFG.SPEEDO_SCALE
  local W, H = speedoPanelSize()
  local pos = getPos('speedo')

  local useMph = prefs.useMph
  local speed = player.speedKmh
  if useMph then speed = speed * 0.621371 end

  local rpm = player.rpm or 0
  local maxRpm = player.rpmLimiter
  if not maxRpm or maxRpm < 1000 then maxRpm = CFG.SPEEDO_FALLBACK_RPM end
  local frac = math.saturate(rpm / maxRpm)

  local gear = player.gear or 0
  local gearText = gear < 0 and 'R' or (gear == 0 and 'N' or tostring(gear))

  ui.transparentWindow('nohesiSpeedo', pos, winSizeOf('speedo'), function()
    ui.pushDWriteFont('Segoe UI;Weight=Bold')

    local o = ui.getCursor() + vec2(MARGIN, 0)
    local hot = frac > 0.92
    local accent = hot and rgbm(1, 0.3, 0.25, 1) or rgbm(0.55, 0.85, 1, 1)

    ui.drawRectFilled(o + vec2(10, 0), o + vec2(W - 10, H),
      rgbm(0.04, 0.05, 0.08, 0.78), 14 * k, ui.CornerFlags.All)
    ui.drawRect(o + vec2(10, 0), o + vec2(W - 10, H),
      rgbm(accent.r, accent.g, accent.b, 0.85), 14 * k, ui.CornerFlags.All, 2)

    -- white outline while the panel is being dragged
    if dragging and dragging.key == 'speedo' then
      ui.drawRect(o + vec2(6, -4), o + vec2(W - 6, H + 4),
        rgbm(1, 1, 1, 0.55), 16 * k, ui.CornerFlags.All, 1)
    end

    -- speed (left)
    ui.dwriteDrawText('SPEED', 12 * k, o + vec2(30 * k, 8 * k), GREY)
    ui.dwriteDrawText(tostring(math.floor(speed + 0.5)), 52 * k, o + vec2(30 * k, 20 * k), WHITE)

    -- MPH / KM/H switch (click it to change units)
    do
      local sx, sy, segW, sh = unitSwitchLayout()
      local x0, y0 = o.x + sx, o.y + sy
      local hover = false
      local okMouse, mp = pcall(ui.mousePos)
      if okMouse and mp then
        hover = inRect(mp, vec2(x0, y0), vec2(x0 + segW * 2, y0 + sh))
      end
      ui.drawRectFilled(vec2(x0, y0), vec2(x0 + segW * 2, y0 + sh),
        rgbm(1, 1, 1, hover and 0.16 or 0.08), 6 * k, ui.CornerFlags.All)
      local activeX = useMph and x0 or (x0 + segW)
      ui.drawRectFilled(vec2(activeX, y0), vec2(activeX + segW, y0 + sh),
        rgbm(accent.r, accent.g, accent.b, 0.9), 6 * k, ui.CornerFlags.All)
      local dark = rgbm(0.04, 0.05, 0.08, 1)
      textCenter('MPH', 13 * k, x0 + segW / 2, y0 + 3 * k, useMph and dark or GREY)
      textCenter('KM/H', 13 * k, x0 + segW * 1.5, y0 + 3 * k, useMph and GREY or dark)
    end

    -- gear (right)
    textRight('GEAR', 12 * k, o.x + W - 30 * k, o.y + 8 * k, GREY)
    textRight(gearText, 52 * k, o.x + W - 30 * k, o.y + 20 * k, accent)

    -- rpm text (centre)
    textCenter(string.format('%d RPM', math.floor(rpm + 0.5)), 16 * k, o.x + W / 2, o.y + 54 * k, GREY)

    -- segmented rpm bar
    local segs = 30
    local bx, bw, by = o.x + 30 * k, W - 60 * k, o.y + 100 * k
    local segW = bw / segs
    for i = 0, segs - 1 do
      local t = (i + 1) / segs
      local lit = t <= frac + 0.0001
      local col
      if t > 0.85 then col = rgbm(1, 0.3, 0.25, lit and 1 or 0.18)
      elseif t > 0.65 then col = rgbm(1, 0.85, 0.2, lit and 1 or 0.18)
      else col = rgbm(0.55, 0.85, 1, lit and 1 or 0.18) end
      ui.drawRectFilled(vec2(bx + i * segW, by), vec2(bx + (i + 1) * segW - 3 * k, by + 12 * k),
        col, 2 * k, ui.CornerFlags.All)
    end

    -- SPEED MULTIPLIER indicator (what every pass is multiplied by right now)
    do
      local sm = speedMultiplier(player.speedKmh)
      local t = math.saturate((sm - CFG.SPEED_MULT_MIN) / math.max(0.01, CFG.SPEED_MULT_MAX - CFG.SPEED_MULT_MIN))
      local mcol
      if t >= 0.999 then mcol = rgbm(1, 0.3, 0.25, 1)          -- maxed out
      elseif t > 0.66 then mcol = rgbm(1, 0.6, 0.15, 1)
      elseif t > 0.33 then mcol = rgbm(1, 0.85, 0.2, 1)
      else mcol = rgbm(0.55, 0.85, 1, 1) end

      ui.dwriteDrawText('SPEED MULT', 12 * k, o.x + 30 * k, o.y + 124 * k, GREY)
      textRight(string.format('x%.2f', sm) .. (t >= 0.999 and ' MAX' or ''),
        26 * k, o.x + W - 30 * k, o.y + 118 * k, mcol)

      -- continuous bar, filled according to speed (0 -> 300 km/h)
      local mx, mw, my = o.x + 30 * k, W - 60 * k, o.y + 152 * k
      ui.drawRectFilled(vec2(mx, my), vec2(mx + mw, my + 10 * k),
        rgbm(1, 1, 1, 0.12), 3 * k, ui.CornerFlags.All)
      if t > 0.001 then
        ui.drawRectFilled(vec2(mx, my), vec2(mx + mw * t, my + 10 * k),
          mcol, 3 * k, ui.CornerFlags.All)
      end
    end

    ui.popDWriteFont()
  end)
end

function script.drawUI()
  if CFG.HUD_DRAG then
    local ok, err = pcall(handleHudInput)
    if not ok then
      -- if the mouse API misbehaves, just turn dragging off instead of breaking the HUD
      if not dragErrorLogged then
        dragErrorLogged = true
        ac.log('HUD dragging disabled: ' .. tostring(err))
      end
      CFG.HUD_DRAG = false
      dragging = nil
    end
  end
  drawScoreHud()
  if CFG.SHOW_SPEEDO then drawSpeedo() end
end
