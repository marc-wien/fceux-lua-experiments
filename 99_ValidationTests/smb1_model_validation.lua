-- smb1_model_validation.lua
-- Variant: exhaustive check of the acceleration bound against the model
--
-- Checks 02_BoundAcceleration/bound1.lua against every state and input of
-- smbmodel.lua, up to K frames ahead. smb1_rom_validation.lua checks the
-- model against the ROM; this file checks the bound against the model.
-- Together they carry the bound's claims to the game (see README.md).
--
-- Runs in any Lua 5.1 (FCEUX's Lua console included, no ROM needed) or
-- LuaJIT: about 15 seconds in LuaJIT, a few minutes in plain Lua. Keep this
-- file next to smbmodel.lua and bound_harness.lua. Each claim prints what
-- it checks and how, then PASS or FAIL; a summary ends the run.
--
-- What "every state and input" means here: every state in the model's set
-- (SM.in_set), each starting on the ground or in the air, and on every
-- frame after it any input, either ground or air (the model doesn't track
-- height, so it lets any frame be a takeoff or a landing), with or without
-- the left screen edge clamping Mario (his position isn't tracked either).
-- Allowing more than the game allows can only raise what the model finds,
-- so a bound that holds here holds for the game, if the model's one-frame
-- rules match the ROM.

-- === Settings ===============================================================

local K = 60                -- frames ahead checked from every state
local BOUND_FILE = "../02_BoundAcceleration/bound1.lua"
local ABLATIONS = true      -- also check that each part of the bound is needed
local SHOW = 3              -- examples printed per failed check
local LOG_FILE = "smb1_model_validation_log.txt"   -- nil for no log

-- === Files ==================================================================

local here = ""
if debug and debug.getinfo then
  here = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or ""
end

-- bound1.lua reads RAM through `memory`. Outside FCEUX there is none, so
-- give it one that reads this table; inside FCEUX, use the same stand-in so
-- the check reads the model's states, not the game's.
local FAKE_RAM = {}
local real_memory = memory
memory = {
  readbyte = function(a) return FAKE_RAM[a] or 0 end,
  readbytesigned = function(a)
    local b = FAKE_RAM[a] or 0
    if b >= 128 then return b - 256 end
    return b
  end,
}

local SM = dofile(here .. "smbmodel.lua")
local H = dofile(here .. "bound_harness.lua")
local B, load_err = H.load(here .. BOUND_FILE)
memory = real_memory

local floor, max, min = math.floor, math.max, math.min

-- === Reporting ==============================================================

local R = { list = {}, out = nil }
if LOG_FILE then R.out = io.open(here .. LOG_FILE, "w") end

function R.say(s)
  print(s)
  if R.out then R.out:write(s, "\n"); R.out:flush() end
end

function R.claim(id, title, how)
  local c = { id = id, title = title, n = 0, bad = 0, shown = 0 }
  R.list[#R.list + 1] = c
  R.say("")
  R.say(id .. "  " .. title)
  for _, line in ipairs(how or {}) do R.say("      " .. line) end
  return c
end

function R.check(c, ok, why)
  c.n = c.n + 1
  if ok then return true end
  c.bad = c.bad + 1
  if c.shown < SHOW then
    c.shown = c.shown + 1
    R.say("      " .. c.id .. " FAILED: " .. why())
  end
  return false
end

function R.done(c, status, note)
  c.status = status or ((c.bad == 0) and "PASS" or "FAIL")
  R.say(string.format("      -> %s %s (%d checks, %d failed)%s", c.id,
      c.status, c.n, c.bad, note and ("  " .. note) or ""))
end

local function speed_text(w)            -- e.g. "01:30 (1.188)"
  local byte, frac = SM.split(w)
  return string.format("%02X:%02X (%.3f)", byte % 256, frac, w / 256)
end

local function state_text(st, ground)
  return string.format("speed %s, facing %d, moving %d, $0700 %d, latch %s,"
      .. " %s", speed_text(st[1]), st[2], st[3], st[4],
      st[5] and "set" or "clear", ground and "on the ground" or "in the air")
end

R.say("SMB1 acceleration bound: exhaustive check against the model")
R.say(string.format("Model: %ssmbmodel.lua   Bound: %s%s", here, here,
    BOUND_FILE))
R.say(string.format("Horizon: every k = 1..%d frames from every state", K))

-- === M1. The bound file =====================================================

local c = R.claim("M1", "bound1.lua loads, and this check's copy of its ramp"
    .. " matches it", {
  "Loads the bound file's own text and runs it. Then, at every starting",
  "speed from -40 to +41 in steps of 1/256, for both walking rates, checks",
  "that the envelope used below (speed and distance after each frame)",
  "ramps exactly as bound1's ramp_to_max_speed does.",
})
if not B then
  R.check(c, false, function() return tostring(load_err) end)
  R.done(c)
  R.say("Cannot continue without the bound file.")
  return
end
for i = -40 * 256, 41 * 256 do
  local v = i / 256
  for _, slower in ipairs({ false, true }) do
    local env = H.envelope(B, v, slower, K)
    local ok, why = H.matches(B, v, slower, env)
    if ok and env.capped then c.n = c.n + 1
    else R.check(c, false, function()
      return why or "ramp never reaches max speed"
    end) end
  end
end
R.done(c, nil, string.format("constants: run %.4f, walk %.4f / %.4f below"
    .. " %d, cap %d, free frames %d, edge %.4f px, projected to frame %d",
    B.RUN_ACCEL * 256, B.WALK_ACCEL * 256, B.SLOW_WALK_ACCEL * 256,
    B.RUN_ACCEL_MIN_SPEED, B.MAX_SPEED, B.FREE_FRAMES, B.EDGE_PUSH_PX,
    B.PROJECT_TO_FRAME))

-- === The state set and one-frame facts ======================================

local states = SM.states()
local nb = #states
local index = {}
local function key(w, F, M, A, R_)
  return ((((w + 10240) * 4 + F) * 4 + M) * 41 + A) * 2 + (R_ and 1 or 0)
end
for b, st in ipairs(states) do
  index[key(st[1], st[2], st[3], st[4], st[5])] = b
end

local c_set = R.claim("M2", "The model's state set is closed", {
  string.format("%d states (each on the ground or in the air). From each,", nb),
  "every input (Left/Right 0-3, Down, another non-A button, B-or-timer,",
  "jump, edge clamp) gives a next state that is also in the set.",
})
local c_add = R.claim("M3", "No frame adds more than 456 to max(speed, 0)", {
  "For every transition: the speed at the end of the frame, and the speed",
  "that moved Mario, are at most max(start speed, 0) + 456/256 subpixels.",
  "456 is $E4 doubled, the largest adder.",
})
local c_cap = R.claim("M4", "The speed byte never leaves -40..+40", {
  "For every transition, the speed byte at the end of the frame and the",
  "one that moved Mario stay within the caps ($28).",
})
local c_cross = R.claim("M5", "Speed 25 is reached from below only on the"
    .. " ground, running", {
  "For every transition from a speed byte of 24 or less to 25 or more:",
  "it is a ground frame using the running rules. So in the air below 25",
  "the walking rates apply, which is why the bound's top rate only starts",
  "at RUN_ACCEL_MIN_SPEED once Mario is in the air.",
})

-- Transitions, deduplicated by (next state, move speed), for the search.
local succ, wmts, t_first, t_last, nt = {}, {}, {}, {}, 0
for b = 1, nb do
  local st = states[b]
  local w, F, M, A, Lt = st[1], st[2], st[3], st[4], st[5]
  local byte = floor(w / 256)
  for g = 0, 1 do
    local ground, id, seen = (g == 1), 2 * b + g, {}
    t_first[id] = nt + 1
    for d = 0, 3 do for dn = 0, 1 do for ot = 0, 1 do for ro = 0, 1 do
    for jp = 0, 1 do for pn = 0, 1 do
      -- in the air only Left/Right and the edge matter to the model
      if ground or dn + ot + ro + jp == 0 then
        local w2, F2, M2, A2, R2, wmt, air, run = SM.step(w, F, M, A, Lt,
            ground, d, dn == 1, ot == 1, ro == 1, jp == 1, pn == 1)
        if w2 then
          local b2 = index[key(w2, F2, M2, A2, R2)]
          if b2 then c_set.n = c_set.n + 1 else R.check(c_set, false, function()
            return state_text(st, ground) .. string.format(" -> speed %s,"
                .. " facing %d, moving %d, $0700 %d", speed_text(w2), F2, M2,
                A2)
          end) end
          local top = max(w2, wmt)
          if top <= max(w, 0) + 456 then c_add.n = c_add.n + 1
          else R.check(c_add, false, function()
            return state_text(st, ground) .. " -> " .. speed_text(top)
          end) end
          local hi, lo = floor(top / 256), floor(min(w2, wmt) / 256)
          if hi <= 40 and lo >= -40 then c_cap.n = c_cap.n + 1
          else R.check(c_cap, false, function()
            return state_text(st, ground) .. " -> " .. speed_text(top)
          end) end
          if byte <= 24 and hi >= 25 then
            if ground and not air and run then c_cross.n = c_cross.n + 1
            else R.check(c_cross, false, function()
              return state_text(st, ground) .. " -> " .. speed_text(top)
            end) end
          end
          if b2 then
            local k2 = b2 * 32768 + (wmt + 10240)
            if not seen[k2] then
              seen[k2] = true
              nt = nt + 1
              succ[nt], wmts[nt] = b2, wmt
            end
          end
        end
      end
    end end end end end end
    t_last[id] = nt
  end
end
R.done(c_set, nil, string.format("%d distinct transitions", nt))
R.done(c_add)
R.done(c_cap)
R.done(c_cross)

-- === The bound against every line, k = 1..K =================================

-- bound1's latch-rule test, run on its own code with the state in fake RAM.
local function load_state(st)
  local byte, frac = SM.split(st[1])
  FAKE_RAM[0x0057] = byte % 256
  FAKE_RAM[0x0705] = frac
  FAKE_RAM[0x0700] = st[4]
  FAKE_RAM[0x0703] = st[5] and 28 or 0
  FAKE_RAM[0x006D], FAKE_RAM[0x0086], FAKE_RAM[0x0400] = 0, 0, 0
end
local qualifies, bound_offset = {}, {}
for b = 1, nb do
  load_state(states[b])
  qualifies[b] = B.qualifies_for_slower_ramp() and true or false
  -- bound1's own projected position from x = 0 at frame 0, less cruising
  -- at full speed from the start: the most it allows above cruising.
  local cruise = B.PROJECT_TO_FRAME * B.PX_PER_FRAME_AT_MAX_SPEED
  bound_offset[b] = {
    [false] = B.bound_x_position(0, false) - cruise,
    [true] = B.bound_x_position(0, true) - cruise,
  }
end

-- Bounds to check. Each gives, for a state, whether it applies there and
-- with which walking rate, plus the envelope options.
local function always() return false end
local function by_rule(b) if qualifies[b] then return true end return nil end
local function no_sign(b)
  local st = states[b]
  if (not st[5]) and st[4] < 25 then return true end
  return nil
end
local function cand_ff(v) if floor(v) >= 1 then return 1 end return 2 end

local variants = {
  { name = "bound1, speed only (416 below 25)", rate = always,
    group = "main" },
  { name = "bound1, latch rule (304 where it applies)", rate = by_rule,
    group = "main" },
}
if ABLATIONS then
  local abl = {
    { name = "no free frames", rate = always, opts = { free_frames = 0 } },
    { name = "one free frame", rate = always, opts = { free_frames = 1 } },
    { name = "304 below 25 at every state (no latch test)",
      rate = function() return true end },
    { name = "latch rule without the speed >= 0 test", rate = no_sign },
    { name = "ramp from the raw speed, not max(speed, 0)", rate = always,
      opts = { from_raw_speed = true } },
    { name = "no edge push on the first move", rate = always,
      opts = { no_edge = true } },
  }
  for _, v in ipairs(abl) do
    v.group = "ablation"
    variants[#variants + 1] = v
  end
end
local cands = {
  { name = "one free frame when $57 >= 1, speed only",
    rate = always, opts = { free_frames_fn = cand_ff } },
  { name = "one free frame when $57 >= 1, latch rule",
    rate = by_rule, opts = { free_frames_fn = cand_ff } },
  { name = "no free frames and no edge push, speed only",
    rate = always, opts = { free_frames = 0, no_edge = true } },
  { name = "no free frames, no edge push, latch rule without the speed"
      .. " >= 0 test",
    rate = no_sign, opts = { free_frames = 0, no_edge = true } },
}
for _, v in ipairs(cands) do
  v.group = "candidate"
  variants[#variants + 1] = v
end

for _, v in ipairs(variants) do
  v.cache = {}
  v.res = {
    speed = { bad = 0, worst = 1e9 }, dist = { bad = 0, worst = 1e9 },
    score = { bad = 0, worst = 1e9 },
  }
end

local function envelope_for(v, b)
  local slower = v.rate(b)
  if slower == nil then return nil end
  local w = states[b][1]
  local ck = w * 2 + (slower and 1 or 0)
  local env = v.cache[ck]
  if not env then
    env = H.envelope(B, w / 256, slower, K, v.opts)
    v.cache[ck] = env
  end
  return env, slower
end
for _, v in ipairs(variants) do
  v.env = {}
  for b = 1, nb do v.env[b] = envelope_for(v, b) or false end
end
local nvar = #variants
local b_start = index[key(0, 1, 0, 0, false)]
local function start_ceiling(v)
  local env = v.env[b_start]
  if not env then return "n/a" end
  return string.format("%.4f", 40 + B.PROJECT_TO_FRAME
      * B.PX_PER_FRAME_AT_MAX_SPEED + env.offset)
end

local function note(r, b, g, k, got, lim)
  local margin = lim - got
  if margin < r.worst then
    r.worst = margin
    r.at = { b = b, g = g, k = k, got = got, lim = lim }
  end
  if got > lim + 1e-9 then
    r.bad = r.bad + 1
    if not r.first then
      r.first = { b = b, g = g, k = k, got = got, lim = lim }
    end
  end
end

-- For each k: the most any k-frame line reaches from each state, by
-- dynamic programming over the transitions. Per state (on the ground or in
-- the air): the highest speed byte at the end of frame k or moving Mario
-- on it (Wend, Wmt), the farthest distance in 1/16 px (Sum), and the
-- farthest distance among lines at full speed after frame k (SumC, for the
-- score check). The first frame may add the edge push (15/16 px) instead
-- of its move, since the model allows the edge clamp anywhere.
local Wend, Wmt, Sum, SumC, Best = {}, {}, {}, {}, {}
for b = 1, nb do
  local at_cap = floor(states[b][1] / 256) >= 40
  for g = 0, 1 do
    local id = 2 * b + g
    Wend[id], Sum[id] = states[b][1], 0
    SumC[id] = at_cap and 0 or -1e9
    Best[id] = at_cap and 0 or -1e9
  end
end
local id_start = 2 * index[key(0, 1, 0, 0, false)] + 1
local start_best = {}

for k = 1, K do
  local Wb, Mb, Sb, SbC = {}, {}, {}, {}
  for b = 1, nb do                 -- the next frame may start on ground or air
    Wb[b] = max(Wend[2 * b], Wend[2 * b + 1])
    Sb[b] = max(Sum[2 * b], Sum[2 * b + 1])
    SbC[b] = max(SumC[2 * b], SumC[2 * b + 1])
    if k > 1 then Mb[b] = max(Wmt[2 * b], Wmt[2 * b + 1]) end
  end
  local nW, nM, nS, nSC = {}, {}, {}, {}
  for b = 1, nb do
    for g = 0, 1 do
      local id = 2 * b + g
      local bW, bM, bS, bD, bSC, bDC = -1e9, -1e9, -1e9, -1e9, -1e9, -1e9
      for t = t_first[id], t_last[id] do
        local b2, wm = succ[t], wmts[t]
        local sp = max(0, floor(wm / 256))
        if Wb[b2] > bW then bW = Wb[b2] end
        local mv = (k == 1) and wm or Mb[b2]
        if mv > bM then bM = mv end
        if sp + Sb[b2] > bS then bS = sp + Sb[b2] end
        if max(15, sp) + Sb[b2] > bD then bD = max(15, sp) + Sb[b2] end
        if SbC[b2] > -1e8 then
          if sp + SbC[b2] > bSC then bSC = sp + SbC[b2] end
          if max(15, sp) + SbC[b2] > bDC then bDC = max(15, sp) + SbC[b2] end
        end
      end
      nW[id], nM[id], nS[id], nSC[id] = bW, bM, bS, bSC
      if bDC > -1e8 and bDC - 40 * k > Best[id] then Best[id] = bDC - 40 * k end
      local byte, dist = floor(max(bW, bM) / 256), bD / 16
      for vi = 1, nvar do
        local v = variants[vi]
        local env = v.env[b]
        if env then
          local lb, ld = env.byte[k], env.dist[k]
          local rs, rd = v.res.speed, v.res.dist
          if byte > lb or lb - byte < rs.worst then
            note(rs, b, g, k, byte, lb)
          end
          if dist > ld + 1e-9 or ld - dist < rd.worst then
            note(rd, b, g, k, dist, ld)
          end
        end
      end
    end
  end
  Wend, Wmt, Sum, SumC = nW, nM, nS, nSC
  if k == 45 or k == 50 then start_best[k] = Sum[id_start] / 16 end
end

-- Score level: the best line at full speed, against the bound's offset.
for b = 1, nb do
  for g = 0, 1 do
    local got = Best[2 * b + g] / 16
    if got > -1e7 then
      for _, v in ipairs(variants) do
        local env, slower = envelope_for(v, b)
        if env then
          local lim = env.offset
          if v.group == "main" then lim = bound_offset[b][slower] end
          note(v.res.score, b, g, 0, got, lim)
        end
      end
    end
  end
end

-- The envelope's offsets equal bound1's own bound_x_position.
local c_off = R.claim("M6", "bound1's bound_x_position equals the envelope's"
    .. " projection", {
  "At every state, bound1's own bound_x_position (read from fake RAM), less",
  "cruising at full speed, equals the envelope's offset, for both rates.",
})
for b = 1, nb do
  for _, slower in ipairs({ false, true }) do
    local use = slower and qualifies[b]
    local env = H.envelope(B, states[b][1] / 256, use, K)
    R.check(c_off, math.abs(env.offset - bound_offset[b][slower]) < 1e-9,
      function()
        return state_text(states[b], true) .. string.format(": bound1 %.4f,"
            .. " envelope %.4f", bound_offset[b][slower], env.offset)
      end)
  end
end
R.done(c_off)

local function where(at)
  if not at then return "" end
  local txt = state_text(states[at.b], at.g == 1)
  if at.k > 0 then txt = txt .. string.format(", %d frames on", at.k) end
  return txt .. string.format(": line %.4f, bound %.4f", at.got, at.lim)
end

local function report(c, v, which, unit)
  local r = v.res[which]
  c.n = c.n + 1
  if r.bad > 0 then
    c.bad = c.bad + 1
    R.say(string.format("      %s: %d (state, k) pairs beaten; first: %s",
        which, r.bad, where(r.first)))
  else
    R.say(string.format("      %s: holds; closest %.4f %s below the bound,"
        .. " at %s", which, r.worst, unit, where(r.at)))
  end
end

local c_main = R.claim("M7", "bound1 holds frame by frame, from every state", {
  "For every state and every k up to the horizon, no line of k frames",
  "ends with a higher speed byte than the ramp's after k frames (speed),",
  "or moves farther than the ramp does in k frames (distance).",
  "Speed only: 416 below 25. Latch rule: 304 below 25, at the states",
  "where bound1's qualifies_for_slower_ramp() is true (" ..
      (function()
        local n = 0
        for b = 1, nb do if qualifies[b] then n = n + 1 end end
        return 2 * n
      end)() .. " of " .. 2 * nb .. ").",
  "A closest margin of 0 means some line reaches the bound exactly.",
})
for _, v in ipairs(variants) do
  if v.group == "main" then
    R.say("    " .. v.name)
    report(c_main, v, "speed", "speed bytes")
    report(c_main, v, "dist", "px")
  end
end
R.done(c_main)

local c_score = R.claim("M8", "bound1 holds for projected scores", {
  "For every state: no line that reaches full speed within the horizon",
  "scores more than bound1's bound_x_position allows. A line's score is",
  "its position projected to PROJECT_TO_FRAME at full speed; the check",
  "compares how far each line gets beyond cruising at full speed.",
})
for _, v in ipairs(variants) do
  if v.group == "main" then
    R.say("    " .. v.name)
    report(c_score, v, "score", "px")
  end
end
R.done(c_score)

if ABLATIONS then
  local c_need = R.claim("M9", "Each part of bound1 is needed", {
    "Each variant removes or loosens one part. A part is needed if some",
    "state beats the variant: frame by frame (speed or distance after k",
    "frames, the bound's per-frame claim) or by projected score (what",
    "pruning uses). Both are shown, with each variant's ceiling at the",
    "1-1 start (x 40, speed 0, frame 0) for comparison.",
    "bound1's ceilings at the start: speed only " .. start_ceiling(variants[1])
        .. ", latch rule " .. start_ceiling(variants[2]) .. ".",
  })
  for _, v in ipairs(variants) do
    if v.group == "ablation" then
      local rs, rd, rc = v.res.speed, v.res.dist, v.res.score
      local frame_need, score_need = rs.bad + rd.bad > 0, rc.bad > 0
      c_need.n = c_need.n + 1
      if not (frame_need or score_need) then c_need.bad = c_need.bad + 1 end
      R.say("    " .. v.name)
      R.say(string.format("      frame by frame: %s (speed %d, distance %d"
          .. " pairs beaten); scores: %s (%d states); ceiling at the start"
          .. " %s", frame_need and "needed" or "not needed", rs.bad, rd.bad,
          score_need and "needed" or "not needed", rc.bad, start_ceiling(v)))
      local ex = rc.first or rs.first or rd.first
      if ex then R.say("      e.g. " .. where(ex)) end
    end
  end
  R.done(c_need)
end

local c_cand = R.claim("M10", "Candidates (information only, not bound1)", {
  "Possible changes, checked like M7 and M8: the rule commented out in",
  "bound1.lua's ramp, and a score-only bound without the parts M9 finds",
  "unneeded for scores. A candidate that holds only by score would",
  "still be sound for pruning, but not frame by frame.",
})
for _, v in ipairs(variants) do
  if v.group == "candidate" then
    local rs, rd, rc = v.res.speed, v.res.dist, v.res.score
    c_cand.n = c_cand.n + 1
    R.say("    " .. v.name)
    R.say(string.format("      frame by frame: %s; scores: %s; ceiling at"
        .. " the start %s", (rs.bad + rd.bad == 0) and "holds" or
        string.format("beaten (%d pairs)", rs.bad + rd.bad),
        (rc.bad == 0) and string.format("holds (closest %.4f px)", rc.worst)
        or string.format("beaten (%d states)", rc.bad), start_ceiling(v)))
    local ex = rc.first or rs.first or rd.first
    if ex then R.say("      e.g. " .. where(ex)) end
  end
end
R.done(c_cand, "INFO")

local c_best = R.claim("M11", "Reference: the farthest the model allows from"
    .. " the 1-1 start", {
  "From the start state (speed 0, facing right, moving direction 0, on",
  "the ground), the farthest any line gets. The model allows more than the",
  "game, so no real line from the start can do better, if the model is",
  "faithful and the line stays in scope.",
})
c_best.n = 1
R.say(string.format("      45 frames: %.4f px (x %.4f at frame 45)",
    start_best[45], 40 + start_best[45]))
R.say(string.format("      50 frames: %.4f px", start_best[50]))
R.done(c_best, "INFO")

-- === Summary ================================================================

R.say("")
R.say("Summary")
local all_ok = true
for _, cl in ipairs(R.list) do
  R.say(string.format("  %-4s %-8s %s", cl.id, cl.status or "?", cl.title))
  if cl.status == "FAIL" and cl.id ~= "M10" then all_ok = false end
end
R.say(all_ok and "ALL CLAIMS HOLD (M10 and M11 are information only)"
    or "SOME CLAIMS FAILED")
if R.out then R.out:close() end
