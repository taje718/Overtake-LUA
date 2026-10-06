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
  -- Leave empty to treat every other car as traffic. Otherwise list
  -- substrings of the car folder names used for your traffic cars.
  TRAFFIC_MODELS     = {},
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

local function endRound(reason)
  S.endReason = reason or 'TIME UP'
  S.phase = 'finished'
  S.finishTimer = CFG.RESULT_SHOW_S
  S.combo, S.mult, S.comboTimer = 0, 1.0, 0
  local final = math.floor(S.score)
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
function script.drawUI()
  local uiState = ac.getUI()
  local size = vec2(380, 190)
  local pos = vec2(uiState.windowSize.x / 2 - size.x / 2, 60)

  ui.transparentWindow('nohesiScore', pos, size, function()
    ui.pushDWriteFont('Segoe UI;Weight=Bold')

    if S.phase == 'idle' then
      ui.dwriteText('PASS A CAR TO START', 24, rgbm(1, 1, 1, 1))
      ui.dwriteText(fmtTime(CFG.ROUND_TIME_S) .. ' round   best ' .. storage.bestScore,
        16, rgbm(0.8, 0.9, 1, 1))

    elseif S.phase == 'running' then
      local urgent = S.timeLeft < 20
      ui.dwriteText('TIME  ' .. fmtTime(S.timeLeft), 24,
        urgent and rgbm(1, 0.4, 0.3, 1) or rgbm(1, 1, 1, 1))
      ui.dwriteText('SCORE  ' .. math.floor(S.score), 30, rgbm(1, 1, 1, 1))
      ui.dwriteText(
        string.format('x%.2f   combo %d   crashes %d/%d   best %d',
          S.mult, S.combo, S.crashes, CFG.MAX_CRASHES, storage.bestScore),
        16, rgbm(0.8, 0.9, 1, 1))

      -- combo timer bar
      if S.combo > 0 then
        local frac = math.saturate(S.comboTimer / CFG.COMBO_TIMEOUT_S)
        local y = pos.y + 108
        ui.drawRectFilled(vec2(pos.x, y), vec2(pos.x + size.x * frac, y + 6),
          rgbm(0.2, 0.8, 0.3, 0.9))
      end

      if S.popupTimer > 0 then
        local col = S.popupGood and rgbm(0.4, 1, 0.5, math.saturate(S.popupTimer))
                                or rgbm(1, 0.35, 0.3, math.saturate(S.popupTimer))
        ui.dwriteText(S.popup, 22, col)
      end

    else -- finished
      local crashedOut = S.endReason ~= 'TIME UP'
      ui.dwriteText(S.endReason, 26,
        crashedOut and rgbm(1, 0.35, 0.3, 1) or rgbm(1, 0.8, 0.3, 1))
      ui.dwriteText('FINAL SCORE  ' .. math.floor(S.score), 30, rgbm(1, 1, 1, 1))
      if S.newBest then
        ui.dwriteText('NEW PERSONAL BEST!', 20, rgbm(0.4, 1, 0.5, 1))
      else
        ui.dwriteText('best ' .. storage.bestScore, 16, rgbm(0.8, 0.9, 1, 1))
      end
    end

    ui.popDWriteFont()
  end)
end
