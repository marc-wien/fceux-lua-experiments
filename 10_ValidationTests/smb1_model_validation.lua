-- smb1_model_validation.lua
-- Variant: exhaustive check of the acceleration bound against the model
--
-- Checks the bound in BOUND_FILE (02_BoundAcceleration/bound3.lua, with every combination of its
-- options; bound1.lua and bound2.lua also load) against every state and input of smbmodel.lua, up
-- to K frames ahead. smb1_rom_validation.lua checks the model against the ROM; this file checks
-- the bound against the model. Together they carry the bound's claims to the game (see README.md).
-- The model has no positions, so for bound3.lua's edge position option it checks only the moves
-- (Mario's distance with no edge push); that the edge can't add to them once he is clear of it is
-- the ROM suite's R41.
--
-- Runs in Lua 5.1 or LuaJIT: a few minutes in plain Lua 5.1, well under a minute in LuaJIT. It
-- needs no ROM, so it should also run from FCEUX's Lua window (not yet tried there). Keep this
-- file next to smbmodel.lua and bound_harness.lua. Each claim prints what it checks and how, then
-- PASS or FAIL; a summary ends the run, and LOG_FILE gets a copy.
--
-- What "every state and input" means here: every state in the model's set (SM.in_set), each
-- starting on the ground or in the air, and on every frame after it any input, either ground or
-- air (the model doesn't track height, so it lets any frame be a takeoff or a landing), with or
-- without the left screen edge clamping Mario (his position isn't tracked either). Allowing more
-- than the game allows can only raise what the model finds, so a bound that holds here holds for
-- the game, if the model's one-frame rules match the ROM.

-- === Settings ===================================================================================

local K = 60                -- frames ahead checked from every state
local BOUND_FILE = "../02_BoundAcceleration/bound3.lua"
local BOUND2_FILE = "../02_BoundAcceleration/bound2.lua"  -- M12 compares
                            -- BOUND_FILE with this, its options off
local ABLATIONS = true      -- also check that each part of the bound is needed
local SHOW = 3              -- examples printed per failed check
local LOG_FILE = "smb1_model_validation_log.txt"   -- nil for no log

-- === Files ======================================================================================

local here = ""
if debug and debug.getinfo then
  here = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or ""
end

-- The bound reads RAM through `memory`. Outside FCEUX there is none, so give it one that reads
-- this table; inside FCEUX, use the same stand-in so the check reads the model's states, not the
-- game's.
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
-- bound2.lua, for M12: only when BOUND_FILE is a later bound with options.
local B2
if B and BOUND2_FILE and BOUND2_FILE ~= BOUND_FILE
   and (B.has_facing_rule or B.has_edge_position) then
  B2 = H.load(here .. BOUND2_FILE)
end
memory = real_memory
local BOUND_NAME = BOUND_FILE:match("([^/\\]+)%.lua$") or BOUND_FILE

local floor, max, min = math.floor, math.max, math.min

-- Adler-32 of a file's text with carriage returns removed, so a log names the exact files it
-- tested whatever the line endings. To check one:
-- python -c "import zlib;print('%08x' % zlib.adler32(open('F','rb').read() .replace(b'\r', b'')))"
local function checksum(path)
  local fh = io.open(path, "rb")
  if not fh then return "missing" end
  local text = (fh:read("*a"):gsub("\r", ""))
  fh:close()
  local a, b = 1, 0
  for i = 1, #text do
    a = (a + text:byte(i)) % 65521
    b = (b + a) % 65521
  end
  return string.format("%08x", b * 65536 + a)
end

-- === Reporting ==================================================================================

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
  for _, line in ipairs(how or {}) do
    if line ~= "" then R.say("      " .. line) end
  end
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
R.say("Files tested (Adler-32 of each file's text, line endings ignored):")
for _, f in ipairs({ "smb1_model_validation.lua", "smbmodel.lua",
                     "bound_harness.lua", BOUND_FILE, B2 and BOUND2_FILE }) do
  if f then R.say(string.format("  %s  %s", checksum(here .. f), here .. f)) end
end
R.say(string.format("Horizon: every k = 1..%d frames from every state", K))

-- === M1. The bound file =========================================================================

local c = R.claim("M1", BOUND_NAME .. ".lua loads, and this check's copy of its ramp matches it", {
  "Loads the bound file's own text and runs it. Then, at every starting",
  "speed from -40 to +41 in steps of 1/256, for both walking rates, and",
  "with and without each option the bound has (the burst check; the facing",
  "rule, facing the motion or away from it; clear of the left edge), checks",
  "that the envelope used below (speed and distance after each frame)",
  "projects exactly as the bound's ramp_to_max_speed does.",
})
if not B then
  R.check(c, false, function() return tostring(load_err) end)
  R.done(c)
  R.say("Cannot continue without the bound file.")
  return
end
-- The options. The burst check (do_burst_check): one free frame when $57 is nonzero. The facing
-- rule (use_facing_rule): see bound3.lua. Edge position (use_edge_position): no edge push when
-- Mario is clear of the left edge.
local BURSTS = B.has_burst_check and { false, true } or { false }
local FACINGS = B.has_facing_rule and { false, true } or { false }
local EDGES = B.has_edge_position and { false, true } or { false }
-- For the facing rule, facing the motion (1, 1) and away from it (2, 1).
local SIDES = { { 1, 1 }, { 2, 1 } }
for i = -40 * 256, 41 * 256 do
  local v = i / 256
  for _, slower in ipairs({ false, true }) do
    for _, burst in ipairs(BURSTS) do
      for _, facing in ipairs(FACINGS) do
        for si = 1, facing and #SIDES or 1 do
          for _, clear in ipairs(EDGES) do
            local fopts = { facing_rule = facing, facing = SIDES[si][1],
                            moving = SIDES[si][2], clear_of_edge = clear }
            local env = H.envelope(B, v, slower, K, { burst_check = burst,
                facing_rule = facing, facing = SIDES[si][1],
                moving = SIDES[si][2], clear_of_edge = clear })
            local ok, why = H.matches(B, v, slower, env, burst, fopts)
            if ok and env.capped then c.n = c.n + 1
            else R.check(c, false, function()
              return why or "ramp never reaches max speed"
            end) end
          end
        end
      end
    end
  end
end
R.done(c, nil, string.format("constants: run %.4f, walk %.4f / %.4f below"
    .. " %d, cap %d, free frames %d%s, edge %.4f px, projected to frame %d",
    B.RUN_ACCEL * 256, B.WALK_ACCEL * 256, B.SLOW_WALK_ACCEL * 256,
    B.RUN_ACCEL_THRES, B.MAX_SPEED, B.FREE_FRAMES,
    B.has_burst_check and string.format(" (%d with the burst check, $57"
        .. " nonzero)", B.FREE_FRAMES_IF_MOVING) or "", B.EDGE_PUSH_PX,
    B.SCORING_FRAME)
    .. (B.has_facing_rule and string.format("; facing rule: forward %.4f,"
        .. " turn -%.4f, floor %.4f", B.FORWARD_ACCEL * 256,
        B.TURN_DECEL * 256, B.BEST_CROSSING) or ""))

-- === The state set and one-frame facts ==========================================================

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
  "that moved Mario, are at most 456 above max(start speed, 0), in the",
  "model's units (1/256 subpixel per frame). 456 is $E4 doubled, the",
  "largest adder.",
})
local c_cap = R.claim("M4", "The speed byte never leaves -40..+40", {
  "For every transition, the speed byte at the end of the frame and the",
  "one that moved Mario stay within the caps ($28).",
})
local c_cross = R.claim("M5", "Speed 25 is reached from below only on the ground, running", {
  "For every transition from a speed byte of 24 or less to 25 or more:",
  "it is a ground frame using the running rules. In the air below 25,",
  "Mario is held to the walking cap of 24.",
})

-- Transitions, deduplicated by (next state, move speed), for the k-frame search below.
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

-- === The bound against every line, k = 1..K =====================================================

-- A model state in fake RAM, for the bound's own code to read: speed, facing, moving direction,
-- $0700 and the latch, with Mario x px right of a left screen edge at 0 (x = 0: on the edge, so
-- use_edge_position changes nothing; the model has no positions).
local function load_state(st, x)
  local byte, frac = SM.split(st[1])
  x = x or 0
  FAKE_RAM[0x0057] = byte % 256
  FAKE_RAM[0x0705] = frac
  FAKE_RAM[0x0033], FAKE_RAM[0x0045] = st[2], st[3]
  FAKE_RAM[0x0700] = st[4]
  FAKE_RAM[0x0703] = st[5] and 28 or 0
  FAKE_RAM[0x006D], FAKE_RAM[0x0086], FAKE_RAM[0x0400] = 0, x, 0
  FAKE_RAM[0x071A], FAKE_RAM[0x071C] = 0, 0
end
local qualifies, bound_offset = {}, {}
local cruise = B.SCORING_FRAME * B.MAX_SPEED_IN_PX
for b = 1, nb do
  load_state(states[b])
  qualifies[b] = B.qualifies_for_slower_ramp() and true or false
  -- The bound's own projected position from x at frame 0, less x and cruising at full speed from
  -- the start: the most it allows above cruising. Without edge position, Mario is on the left edge
  -- (x = 0); with it, 100 px clear. Indexed [use_latch_rule][do_burst_check]
  -- [use_facing_rule][use_edge_position].
  bound_offset[b] = {}
  for _, rule in ipairs({ false, true }) do
    bound_offset[b][rule] = {}
    for _, burst in ipairs({ false, true }) do
      bound_offset[b][rule][burst] = {}
      for _, facing in ipairs(FACINGS) do
        bound_offset[b][rule][burst][facing] = {}
        for _, edge in ipairs(EDGES) do
          local x = edge and 100 or 0
          load_state(states[b], x)
          bound_offset[b][rule][burst][facing][edge] = B.bound_x_position(0,
              rule, burst, facing, edge) - x - cruise
        end
      end
    end
  end
end

-- Bounds to check. Each gives, for a state, whether it applies there and with which walking rate,
-- plus the envelope options; `facing` adds the facing rule, read from the state; `edge` is edge
-- position, for a state with Mario clear of the left edge.
local function always() return false end
local function by_rule(b) if qualifies[b] then return true end return nil end
local function no_sign(b)
  local st = states[b]
  if (not st[5]) and st[4] < 25 then return true end
  return nil
end

local BURST = { burst_check = true }
local variants = {}
-- The main forms: speed only and the latch rule, with and without each option. The burst check, if
-- the bound doesn't have it, is checked as a candidate.
for _, edge in ipairs({ false, true }) do
  for _, facing in ipairs({ false, true }) do
    for _, burst in ipairs({ false, true }) do
      for _, rule in ipairs({ false, true }) do
        local main = (not burst or B.has_burst_check) and (not facing or B.has_facing_rule)
            and (not edge or B.has_edge_position)
        if main or not (facing or edge) then
          variants[#variants + 1] = {
            name = (rule and "latch rule (304 where it applies)" or "speed only (416 below 25)")
                .. (burst and ", with the burst check" or "")
                .. (facing and ", with the facing rule" or "")
                .. (edge and ", with edge position (clear of the edge)" or ""),
            rate = rule and by_rule or always, opts = burst and BURST or nil,
            burst = burst, facing = facing, edge = edge,
            group = main and "main" or "candidate" }
        end
      end
    end
  end
end
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
  if B.has_burst_check then
    abl[#abl + 1] = { name = "burst check with no free frames when $57 is"
        .. " nonzero", rate = always, opts = { free_frames_fn = function(v)
          if floor(v) == 0 then return B.FREE_FRAMES end
          return 0
        end } }
    abl[#abl + 1] = { name = "burst check, latch rule without the speed"
        .. " >= 0 test", rate = no_sign, opts = BURST }
  end
  if B.has_facing_rule then
    abl[#abl + 1] = { name = "facing rule without the floor (BEST_CROSSING)",
        rate = always, facing = true, opts = { no_floor = true } }
    abl[#abl + 1] = { name = "facing rule without the turned branch",
        rate = always, facing = true, opts = { no_turn_branch = true } }
    abl[#abl + 1] = { name = "facing rule without the already-turned case",
        rate = always, facing = true, opts = { no_turned_case = true } }
  end
  for _, v in ipairs(abl) do
    v.group = "ablation"
    variants[#variants + 1] = v
  end
end
local cands = {
  { name = "latch rule with one free frame", rate = by_rule,
    opts = { free_frames = 1 } },
  { name = "no free frames and no edge push, speed only",
    rate = always, opts = { free_frames = 0, no_edge = true } },
  { name = "no free frames, no edge push, latch rule without the speed >= 0 test",
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

-- A variant's envelope at state b, and its walking rate there (nil: the variant doesn't apply).
-- Cached by what the envelope depends on.
local function envelope_for(v, b)
  local slower = v.rate(b)
  if slower == nil then return nil end
  local st = states[b]
  local w = st[1]
  local ck = w * 2 + (slower and 1 or 0)
  local opts = v.opts
  if v.facing or v.edge then
    opts = { clear_of_edge = v.edge }
    if v.facing then
      local turned, no_burst = H.facing_tests(B, w / 256, st[2], st[3])
      ck = (ck * 2 + (turned and 1 or 0)) * 2 + (no_burst and 1 or 0)
      opts.facing_rule, opts.facing, opts.moving = true, st[2], st[3]
    end
    for name, value in pairs(v.opts or {}) do opts[name] = value end
  end
  local env = v.cache[ck]
  if not env then
    env = H.envelope(B, w / 256, slower, K, opts)
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
  return string.format("%.4f", 40 + B.SCORING_FRAME * B.MAX_SPEED_IN_PX
      + env.offset)
end
-- The main variant with the latch rule, burst check, facing rule and edge position as given.
local function find_variant(rule, burst, facing, edge)
  for _, v in ipairs(variants) do
    if v.group == "main" and (v.rate == by_rule) == rule
       and (v.burst or false) == burst and (v.facing or false) == facing
       and (v.edge or false) == (edge or false) then
      return v
    end
  end
  return { env = {} }
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

-- For each k: the most any k-frame line reaches from each state, by dynamic programming over the
-- transitions. Per state (on the ground or in the air): the highest speed byte at the end of frame
-- k or moving Mario on it (Wend, Wmt), the farthest distance in 1/16 px (Sum), and the farthest
-- distance among lines at full speed after frame k (SumC, for the score check). Distances count
-- each frame's move, speed byte / 16 px, moves left as 0. Where Mario may be on the left edge, the
-- first frame may add the edge push (15/16 px) instead of its move, since the model allows the
-- edge clamp anywhere (dist, Best). Clear of the edge, the edge can't add to his moves (R41), so
-- edge position is checked against the moves alone (dist_clear, BestClear).
local Wend, Wmt, Sum, SumC, Best, BestClear = {}, {}, {}, {}, {}, {}
for b = 1, nb do
  local at_cap = floor(states[b][1] / 256) >= 40
  for g = 0, 1 do
    local id = 2 * b + g
    Wend[id], Sum[id] = states[b][1], 0
    SumC[id] = at_cap and 0 or -1e9
    Best[id] = at_cap and 0 or -1e9
    BestClear[id] = at_cap and 0 or -1e9
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
      if bSC > -1e8 and bSC - 40 * k > BestClear[id] then
        BestClear[id] = bSC - 40 * k
      end
      local byte = floor(max(bW, bM) / 256)
      local dist, dist_clear = bD / 16, bS / 16
      for vi = 1, nvar do
        local v = variants[vi]
        local env = v.env[b]
        if env then
          local lb, ld = env.byte[k], env.dist[k]
          local rs, rd = v.res.speed, v.res.dist
          local d = v.edge and dist_clear or dist
          if byte > lb or lb - byte < rs.worst then
            note(rs, b, g, k, byte, lb)
          end
          if d > ld + 1e-9 or ld - d < rd.worst then
            note(rd, b, g, k, d, ld)
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
    for _, v in ipairs(variants) do
      local got = (v.edge and BestClear or Best)[2 * b + g] / 16
      local env, slower = envelope_for(v, b)
      if env and got > -1e7 then
        local lim = env.offset
        if v.group == "main" then
          lim = bound_offset[b][slower][v.burst or false][v.facing or false]
              [v.edge or false]
        end
        note(v.res.score, b, g, 0, got, lim)
      end
    end
  end
end

-- The envelope's offsets equal the bound's own bound_x_position.
local c_off = R.claim("M6", BOUND_NAME .. "'s bound_x_position equals the envelope's projection", {
  "At every state, the bound's own bound_x_position (read from fake RAM),",
  "less cruising at full speed, equals the envelope's offset: for both",
  "rates, and with and without each option the bound has. With the facing",
  "rule, the bound's own RAM tests (already_turned, holds_no_burst) must",
  "also agree with the harness's. Mario is put on the left edge and 100 px",
  "clear of it, so the edge position option is checked both ways: no",
  "change on the edge, no edge push clear of it.",
})
local m6_cache = {}
for b = 1, nb do
  local st = states[b]
  local w = st[1]
  local turned, no_burst = H.facing_tests(B, w / 256, st[2], st[3])
  if B.has_facing_rule then
    load_state(st)
    R.check(c_off, (B.already_turned() and true or false) == turned
        and (B.holds_no_burst() and true or false) == no_burst, function()
      return state_text(st, true) .. ": the bound's facing tests differ from the harness's"
    end)
  end
  for _, x in ipairs(B.has_edge_position and { 0, 100 } or { 0 }) do
    load_state(st, x)
    for _, slower in ipairs({ false, true }) do
      local use = slower and qualifies[b]
      for _, burst in ipairs(BURSTS) do
        for _, facing in ipairs(FACINGS) do
          for _, edge in ipairs(EDGES) do
            local clear = edge and x > 0
            local ck = ((((w + 10240) * 2 + (use and 1 or 0)) * 2
                + (burst and 1 or 0)) * 2 + (facing and 1 or 0)) * 4
                + (facing and ((turned and 2 or 0) + (no_burst and 1 or 0)) or 0)
            ck = ck * 2 + (clear and 1 or 0)
            local off = m6_cache[ck]
            if not off then
              off = H.envelope(B, w / 256, use, K, { burst_check = burst,
                  facing_rule = facing, facing = st[2], moving = st[3],
                  clear_of_edge = clear }).offset
              m6_cache[ck] = off
            end
            local lim = B.bound_x_position(0, slower, burst, facing, edge)
                - x - cruise
            R.check(c_off, math.abs(off - lim) < 1e-9, function()
              return state_text(st, true) .. string.format(" at x %d,%s%s%s%s:"
                  .. " %s %.4f, envelope %.4f", x,
                  slower and " latch rule" or " speed only",
                  burst and ", burst check" or "",
                  facing and ", facing rule" or "",
                  edge and ", edge position" or "", BOUND_NAME, lim, off)
            end)
          end
        end
      end
    end
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

local c_main = R.claim("M7", BOUND_NAME .. " holds frame by frame, from every state", {
  "For every state and every k up to the horizon, no line of k frames",
  "ends with a higher speed byte than the ramp's after k frames (speed),",
  "or moves farther than the ramp does in k frames (distance).",
  "Speed only: 416 below 25. Latch rule: 304 below 25, at the states",
  "where qualifies_for_slower_ramp() is true (" .. (function()
        local n = 0
        for b = 1, nb do if qualifies[b] then n = n + 1 end end
        return 2 * n
      end)() .. " of " .. 2 * nb .. ").",
  B.has_burst_check and "With the burst check: one free frame where $57 is"
      .. " nonzero." or "This bound has no burst check (see M10).",
  B.has_facing_rule and "With the facing rule: from 25 up, 228 a frame or a"
      .. " turnaround, and no free frames" or "This bound has no facing rule.",
  B.has_facing_rule and "for a state moving and facing its motion (see bound3.lua)." or "",
  B.has_edge_position and "With edge position, for Mario clear of the left"
      .. " edge: no 15/16 px allowance," or "",
  B.has_edge_position and "and distance counts his moves alone (R41 shows"
      .. " the edge can't add to them)." or "",
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

local c_score = R.claim("M8", BOUND_NAME .. " holds for projected scores", {
  "For every state: no line that reaches full speed within the horizon",
  "scores more than the bound's bound_x_position allows. A line's score is",
  "its position projected to SCORING_FRAME at full speed; the check",
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
  local c_need = R.claim("M9", "Each part of " .. BOUND_NAME .. " is needed", {
    "Each variant removes or loosens one part. A part is needed if some",
    "state beats the variant: frame by frame (speed or distance after k",
    "frames, the bound's per-frame claim) or by projected score (what",
    "pruning uses). Both are shown, with each variant's ceiling at the",
    "1-1 start (x 40, speed 0, frame 0) for comparison. " .. BOUND_NAME .. "'s:",
    "speed only " .. start_ceiling(find_variant(false, false, false))
        .. ", latch rule " .. start_ceiling(find_variant(true, false, false))
        .. (B.has_facing_rule and ("; with the facing rule "
            .. start_ceiling(find_variant(false, false, true)) .. " and "
            .. start_ceiling(find_variant(true, false, true))) or ""),
    B.has_edge_position and ("with edge position too "
        .. start_ceiling(find_variant(false, false, true, true)) .. " and "
        .. start_ceiling(find_variant(true, false, true, true)) .. ".") or "",
    "(With or without a burst check: $57 is 0 at the start.)",
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

local how = { "Possible changes, checked like M7 and M8:" }
if not B.has_burst_check then
  how[#how + 1] = "  the burst check: one free frame when $57 is nonzero (bound2.lua's"
  how[#how + 1] = "  do_burst_check);"
end
how[#how + 1] = "  one free frame wherever the latch rule applies (R17 shows a line it"
how[#how + 1] = "  misses frame by frame);"
how[#how + 1] = "  a score-only bound without the parts M9 finds unneeded for scores."
how[#how + 1] = "A candidate that holds only by score would still be sound for"
how[#how + 1] = "pruning, but not frame by frame."
local c_cand = R.claim("M10", "Candidates (information only, not part of "
    .. BOUND_NAME .. ")", how)
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

local c_best = R.claim("M11", "Reference: the farthest the model allows from the 1-1 start", {
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

-- === M12. bound3.lua with its options off is bound2.lua =========================================

if B2 then
  local c_eq = R.claim("M12", BOUND_NAME .. " with its new options off equals "
      .. (BOUND2_FILE:match("([^/\\]+)%.lua$") or BOUND2_FILE), {
    "At every state, on the left edge and 100 px clear of it, for both rates",
    "and with and without the burst check: bound_x_position with the facing",
    "rule and edge position off (and left out) equals bound2.lua's. So every",
    "claim about bound2.lua, here and in the ROM suite, holds for it too.",
  })
  for b = 1, nb do
    for _, x in ipairs({ 0, 100 }) do
      load_state(states[b], x)
      for _, slower in ipairs({ false, true }) do
        for _, burst in ipairs({ false, true }) do
          local want = B2.bound_x_position(0, slower, burst)
          local got1 = B.bound_x_position(0, slower, burst)
          local got2 = B.bound_x_position(0, slower, burst, false, false)
          R.check(c_eq, math.abs(got1 - want) < 1e-9 and math.abs(got2 - want) < 1e-9, function()
            return state_text(states[b], true) .. string.format(" at x %d:"
                .. " %.4f and %.4f, bound2 %.4f", x, got1, got2, want)
          end)
        end
      end
    end
  end
  R.done(c_eq)
end

-- === Summary ====================================================================================

R.say("")
R.say("Summary")
local all_ok = true
for _, cl in ipairs(R.list) do
  R.say(string.format("  %-4s %-8s %s", cl.id, cl.status or "?", cl.title))
  if cl.status == "FAIL" and cl.id ~= "M10" then all_ok = false end
end
R.say(all_ok and "ALL CLAIMS HOLD (M10 and M11 are information only)" or "SOME CLAIMS FAILED")
if R.out then R.out:close() end
