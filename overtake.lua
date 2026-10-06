-- No Hesi style overtake scorer for AssettoServer (CSP online script)
-- 3 minute rounds. Slowing down does not end anything. The combo only
-- resets after COMBO_TIMEOUT_S with no pass, or on a crash.
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
  CLOSE_LATERAL      = 1.8,   -- passes closer than this get a close-pass bonus
  MIN_PASS_SPEED_KMH = 40,    -- you must be at least this fast for a pass to count
  BASE_POINTS        = 100,   -- points per pass (before multiplier)
  CLOSE_BONUS        = 50,    -- extra points for a close pass
  SPEED_BONUS_PER_10 = 5,     -- extra points per 10 km/h above SPEED_BONUS_FROM
  SPEED_BONUS_FROM   = 80,
  MULT_STEP          = 0.25,  -- multiplier added per consecutive pass
  MULT_MAX           = 10.0,
  MAX_CRASHES        = 2,     -- the run ends on this crash (1st crash only resets the combo)
  CRASH_COOLDOWN_S   = 2.0,   -- ignore further contact this long after a crash (one scrape = one crash)
  CRASH_SCORE_LOSS   = 0.0,   -- fraction of round score lost on a non-final crash (0 = none, 0.5 = half)
  PIT_RESET_SAVES_BEST = true, -- true: score is banked toward your best when you return to pits. false: score is thrown away
  TELEPORT_DIST      = 200,   -- a jump bigger than this (m) in one frame counts as a teleport to pits
  -- Discord leaderboard (see worker.js). Leave LEADERBOARD_URL empty to turn it off.
  LEADERBOARD_URL    = 'https://swimteamleaderboard.tajewithehs.workers.dev',    -- your Cloudflare Worker URL
  LEADERBOARD_KEY    = 'k7Qm29xPzr41',    -- same value as SUBMIT_KEY in the Worker
  MIN_SUBMIT_SCORE   = 10000,  -- runs scoring less than this are not sent
  -- Only cars whose folder name contains one of these words count as traffic.
  -- "traffic" matches traffic_* and nohesi_traffic_* cars. Other players
  -- are not counted. Leave the list empty to count every other car.
  TRAFFIC_MODELS     = { "traffic", "mtn_victoria" },
  -- Speedometer
  SHOW_SPEEDO        = true,
  SPEEDO_USE_MPH     = false, -- true: show mph instead of km/h
  SPEEDO_FALLBACK_RPM = 8000, -- used if the car does not report a limiter rpm
}

---------------------------------------------------------------------
-- STATE
---------------------------------------------------------------------
local storage = ac.storage{ bestScore = 0 }

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
end

local function jsonStr(s)
  return (tostring(s or ''):gsub('%c', ' '):gsub('\\', '\\\\'):gsub('"', '\\"'))
end

-- sends the finished run to the leaderboard relay (if configured)
local function submitScore(score)
  if CFG.LEADERBOARD_URL == '' or score < CFG.MIN_SUBMIT_SCORE then return end
  local name = ac.getDriverName(0) or 'Unknown'
  local body = string.format('{"name":"%s","score":%d,"key":"%s"}',
    jsonStr(name), score, jsonStr(CFG.LEADERBOARD_KEY))
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
  local final = math.floor(S.score)
  submitScore(final)
  if final > storage.bestScore then
    storage.bestScore = final
    S.newBest = true
  end
end

local function registerPass(speed, lateral)
  if S.phase == 'idle' then startRound() end

  S.combo = S.combo + 1
  S.mult = math.min(CFG.MULT_MAX, 1.0 + (S.combo - 1) * CFG.MULT_STEP)
  S.comboTimer = CFG.COMBO_TIMEOUT_S

  local pts = CFG.BASE_POINTS
  local close = lateral < CFG.CLOSE_LATERAL
  if close then pts = pts + CFG.CLOSE_BONUS end
  pts = pts + math.max(0, (speed - CFG.SPEED_BONUS_FROM) / 10) * CFG.SPEED_BONUS_PER_10

  local gained = pts * S.mult
  S.score = S.score + gained
  showPopup((close and 'CLOSE PASS  +' or '+') .. math.floor(gained), true)
end

local function fmtTime(t)
  t = math.max(0, math.ceil(t))
  return string.format('%d:%02d', math.floor(t / 60), t % 60)
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

local function drawScoreHud()
  local uiState = ac.getUI()
  local W, H = 460, 250                       -- panel size
  local winW, winH = W + MARGIN * 2, H + 20   -- window size (extra room)
  local pos = vec2(uiState.windowSize.x / 2 - winW / 2, 50)

  ui.transparentWindow('nohesiScore', pos, vec2(winW, winH), function()
    ui.pushDWriteFont('Segoe UI;Weight=Bold')

    local o = ui.getCursor() + vec2(MARGIN, 0)
    local left, right, cx = 30, W - 30, W / 2
    local ar, ag, ab = 0.55, 0.85, 1.0   -- accent colour
    local panelH = 100

    if S.phase == 'running' then
      ar, ag, ab = multRGB(S.mult)
      panelH = 126
    elseif S.phase == 'finished' then
      if S.endReason == 'TIME UP' then ar, ag, ab = 1.0, 0.8, 0.3
      else ar, ag, ab = 1.0, 0.35, 0.3 end
      panelH = 132
    end

    local accent = rgbm(ar, ag, ab, 1)

    -- panel
    ui.drawRectFilled(o + vec2(10, 0), o + vec2(W - 10, panelH),
      rgbm(0.04, 0.05, 0.08, 0.78), 14, ui.CornerFlags.All)
    ui.drawRect(o + vec2(10, 0), o + vec2(W - 10, panelH),
      rgbm(ar, ag, ab, 0.85), 14, ui.CornerFlags.All, 2)

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
      if S.newBest then
        textCenter('NEW PERSONAL BEST!', 17, o.x + cx, o.y + 104, rgbm(0.4, 1, 0.5, 1))
      else
        textCenter('BEST ' .. storage.bestScore, 17, o.x + cx, o.y + 104, GREY)
      end
    end

    ui.popDWriteFont()
  end)
end

local function drawSpeedo()
  local player = ac.getCar(0)
  if not player then return end

  local uiState = ac.getUI()
  local W, H = 340, 130                       -- panel size
  local winW, winH = W + MARGIN * 2, H + 20
  local pos = vec2(uiState.windowSize.x - winW - 20, uiState.windowSize.y - winH - 40)

  local speed = player.speedKmh
  local unit = 'KM/H'
  if CFG.SPEEDO_USE_MPH then speed, unit = speed * 0.621371, 'MPH' end

  local rpm = player.rpm or 0
  local maxRpm = player.rpmLimiter
  if not maxRpm or maxRpm < 1000 then maxRpm = CFG.SPEEDO_FALLBACK_RPM end
  local frac = math.saturate(rpm / maxRpm)

  local gear = player.gear or 0
  local gearText = gear < 0 and 'R' or (gear == 0 and 'N' or tostring(gear))

  ui.transparentWindow('nohesiSpeedo', pos, vec2(winW, winH), function()
    ui.pushDWriteFont('Segoe UI;Weight=Bold')

    local o = ui.getCursor() + vec2(MARGIN, 0)
    local hot = frac > 0.92
    local accent = hot and rgbm(1, 0.3, 0.25, 1) or rgbm(0.55, 0.85, 1, 1)

    ui.drawRectFilled(o + vec2(10, 0), o + vec2(W - 10, H),
      rgbm(0.04, 0.05, 0.08, 0.78), 14, ui.CornerFlags.All)
    ui.drawRect(o + vec2(10, 0), o + vec2(W - 10, H),
      rgbm(accent.r, accent.g, accent.b, 0.85), 14, ui.CornerFlags.All, 2)

    -- speed (left)
    ui.dwriteDrawText('SPEED', 12, o + vec2(30, 8), GREY)
    ui.dwriteDrawText(tostring(math.floor(speed + 0.5)), 52, o + vec2(30, 20), WHITE)
    ui.dwriteDrawText(unit, 14, o + vec2(30, 76), GREY)

    -- gear (right)
    textRight('GEAR', 12, o.x + W - 30, o.y + 8, GREY)
    textRight(gearText, 52, o.x + W - 30, o.y + 20, accent)

    -- rpm text (centre)
    textCenter(string.format('%d RPM', math.floor(rpm + 0.5)), 16, o.x + W / 2, o.y + 54, GREY)

    -- segmented rpm bar
    local segs = 30
    local bx, bw, by = o.x + 30, W - 60, o.y + 100
    local segW = bw / segs
    for i = 0, segs - 1 do
      local t = (i + 1) / segs
      local lit = t <= frac + 0.0001
      local col
      if t > 0.85 then col = rgbm(1, 0.3, 0.25, lit and 1 or 0.18)
      elseif t > 0.65 then col = rgbm(1, 0.85, 0.2, lit and 1 or 0.18)
      else col = rgbm(0.55, 0.85, 1, lit and 1 or 0.18) end
      ui.drawRectFilled(vec2(bx + i * segW, by), vec2(bx + (i + 1) * segW - 3, by + 12),
        col, 2, ui.CornerFlags.All)
    end

    ui.popDWriteFont()
  end)
end

function script.drawUI()
  drawScoreHud()
  if CFG.SHOW_SPEEDO then drawSpeedo() end
end
