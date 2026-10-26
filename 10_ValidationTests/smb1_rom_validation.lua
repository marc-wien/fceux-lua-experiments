-- smb1_rom_validation.lua
-- Variant: ROM validation suite (FCEUX)
--
-- Checks, on the real ROM, the game behavior that the acceleration bound
-- (02_BoundAcceleration/bound2.lua, or bound1.lua) and its model
-- (smbmodel.lua) rely on.
-- Each claim prints what it tests, how, and what it supports, then PASS or
-- FAIL, with the first mismatches in full. README.md lists the claims and
-- what they add up to.
--
-- How to run
--   1. FCEUX 2.x with the NTSC Super Mario Bros. ROM. In Config > Input,
--      tick "Allow Left+Right / Up+Down" (claim R4 checks it).
--   2. Keep this file next to smbmodel.lua and bound_harness.lua, with the
--      bound file where CFG.bound_file points (bound2.lua in the repo).
--   3. Power on (or reset) with no movie or savestate loaded, then run this
--      script. It finds the first frame of control in 1-1 by itself.
--   4. Minimize the window to speed it up. Output goes to the Lua console
--      and to CFG.log_file, next to this file.
-- Runtime: every section but the exhaustive one should take minutes. The
-- exhaustive one runs about 8.8 million single frames, so expect hours; it
-- prints an estimate as it goes. Try CFG.exhaustive_stride = 50 first for a
-- quick pass.
--
-- Reading the output: button letters are R Right, L Left, U Up, D Down, A,
-- B, S Select; "-" means no buttons. Speeds print as speed byte:fraction
-- in hex, then subpixels per frame in decimal: 01:30 (1.188). Positions
-- print in px.

-- === Settings ===============================================================

local CFG = {
  sections = {
    setup = true,         -- R1-R4    the ROM, the start state, the controller
    witnesses = true,     -- R5-R16   exact sequences for each part of the bound
    gotchas = true,       -- R29-R37  shortcuts and readings that fail, shown
    buttons = true,       -- R17      every combination of the 7 buttons
    edge = true,          -- R18      the left screen edge, at every subpixel
    jumps = true,         -- R19      every jump from the start lands cleanly
    play = true,          -- R20-R24  random play, in lockstep with the model
    backgrounds = true,   -- R38      sampled states over other RAM backgrounds
    exhaustive = true,    -- R25-R28  every model state, every input case
  },
  background_stride = 97, -- R38 checks every 97th state (about 670)
  exhaustive_stride = 1,  -- 1: every state; 50: a quick pass
  exhaustive_first = 1,   -- to resume a stopped run, start at this state
  exhaustive_last = nil,  -- nil: through the last state
  button_states = 300,    -- random states, each with all 128 combinations
  play_runs = 3000,
  play_frames = 80,
  K = 60,                 -- frames ahead the bound is checked over
  seed = 20261025,
  show = 5,               -- mismatches printed in full per claim
  progress_seconds = 60,
  bound_file = "../02_BoundAcceleration/bound2.lua",
  log_file = "smb1_rom_validation_log.txt",
}

-- === Files ==================================================================

local here = ""
if debug and debug.getinfo then
  here = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or ""
end
local SM = dofile(here .. "smbmodel.lua")
local H = dofile(here .. "bound_harness.lua")
local B, bound_err = H.load(here .. CFG.bound_file)
local BOUND_NAME = CFG.bound_file:match("([^/\\]+)%.lua$") or CFG.bound_file
local floor, max, min = math.floor, math.max, math.min
math.randomseed(CFG.seed)

-- Adler-32 of a file's text with carriage returns removed, so a log names
-- the exact files it tested whatever the line endings. To check one:
-- python -c "import zlib;print('%08x' % zlib.adler32(open('F','rb').read()
-- .replace(b'\r', b'')))"
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

-- === Reporting ==============================================================

local R = { list = {} }
if CFG.log_file then R.out = io.open(here .. CFG.log_file, "w") end

function R.say(s)
  print(s)
  if R.out then R.out:write(s, "\n"); R.out:flush() end
end

-- Announce a claim: its id, title, and lines saying what it tests, how,
-- and what it supports.
function R.claim(id, title, lines)
  local c = { id = id, title = title, n = 0, bad = 0, shown = 0 }
  R.list[#R.list + 1] = c
  R.say("")
  R.say(id .. "  " .. title)
  for _, line in ipairs(lines or {}) do R.say("      " .. line) end
  return c
end

function R.pass(c) c.n = c.n + 1 end

function R.fail(c, text)
  c.n, c.bad = c.n + 1, c.bad + 1
  if c.shown < CFG.show then
    c.shown = c.shown + 1
    R.say("      " .. c.id .. " MISMATCH: " .. text)
  end
end

function R.check(c, ok, why)
  if ok then c.n = c.n + 1 else R.fail(c, why()) end
  return ok
end

function R.done(c, status, note)
  c.status = status or ((c.n == 0) and "NOT RUN"
      or ((c.bad == 0) and "PASS" or "FAIL"))
  R.say(string.format("      -> %s %s (%d checks, %d failed)%s", c.id,
      c.status, c.n, c.bad, note and ("  " .. note) or ""))
end

function R.skip(id, title, why)
  local c = R.claim(id, title, { why })
  R.done(c, "NOT RUN")
end

-- === Text ===================================================================

local T = {}

function T.speed(w)
  local byte, frac = SM.split(w)
  return string.format("%02X:%02X (%.3f)", byte % 256, frac, w / 256)
end

function T.px(p) return string.format("%.4f px", p / 256) end

function T.keys(k) if k == "" then return "-" end return k end

-- A list of inputs, with repeats folded: "LB x4, B, RBA, RB x22".
function T.line(list, upto)
  local out, i, n = {}, 1, upto or #list
  while i <= n do
    local j = i
    while j < n and list[j + 1] == list[i] do j = j + 1 end
    local k = T.keys(list[i])
    if j > i then k = k .. " x" .. (j - i + 1) end
    out[#out + 1] = k
    i = j + 1
  end
  return table.concat(out, ", ")
end

function T.state(w, facing, moving, abs, latch)
  return string.format("speed %s, facing %d, moving %d, $0700 %d, latch %s",
      T.speed(w), facing, moving, abs, latch and "set" or "clear")
end

-- === The game ===============================================================

local G = {}
local rb, wb = memory.readbyte, memory.writebyte

-- RAM, with SMBDIS.ASM's names.
G.RAM = {
  speed = 0x0057,       -- Player_X_Speed, the speed byte
  frac = 0x0705,        -- Player_X_MoveForce, its fraction
  facing = 0x0033,      -- PlayerFacingDir
  moving = 0x0045,      -- Player_MovingDir
  abs = 0x0700,         -- Player_XSpeedAbsolute
  adder_hi = 0x0701,    -- FrictionAdderHigh
  adder_lo = 0x0702,    -- FrictionAdderLow
  latch = 0x0703,       -- RunningSpeed
  timer = 0x0783,       -- RunningTimer
  prev_ab = 0x000D,     -- PreviousA_B_Buttons
  pad = 0x06FC,         -- SavedJoypadBits
  state = 0x001D,       -- Player_State: 0 on the ground
  y = 0x00CE,           -- Player_Y_Position
  y_speed = 0x009F,     -- Player_Y_Speed
  y_force = 0x0433,     -- Player_Y_MoveForce
  x = 0x0086,           -- Player_X_Position
  page = 0x006D,        -- Player_PageLoc
  sub = 0x0400,         -- SprObject_X_MoveForce, slot 0: the subpixel
  screen_x = 0x071C,    -- ScreenLeft_X_Pos
  screen_page = 0x071A, -- ScreenLeft_PageLoc
  side_timer = 0x0785,  -- SideCollisionTimer
  collision = 0x0490,   -- Player_CollisionBits
  engine = 0x000E,      -- GameEngineSubroutine
  oper_mode = 0x0770,   -- OperMode
  oper_task = 0x0772,   -- OperMode_Task
  size = 0x0754,        -- PlayerSize: 1 small
  area = 0x074E,        -- AreaType: 1 ground
  swim = 0x0704,        -- SwimmingFlag
  scroll_lock = 0x0723, -- ScrollLock
  y_high = 0x00B5,      -- Player_Y_HighPos
  for_scroll = 0x0755,  -- Player_Pos_ForScroll
  enemy_flag = 0x000F,  -- Enemy_Flag, 5 slots: nonzero when active
  enemy_page = 0x006E,  -- Enemy_PageLoc, 5 slots
  enemy_x = 0x0087,     -- Enemy_X_Position, 5 slots
}
local A_ = G.RAM

local function s8(b) if b >= 128 then return b - 256 end return b end

local BUTTON = { R = "right", L = "left", U = "up", D = "down", A = "A",
                 B = "B", S = "select", T = "start" }

-- Hold `keys` for one frame. Every button is set explicitly: FCEUX treats
-- an omitted button as "leave it to the user", not "released".
function G.press(keys)
  local t = { up = false, down = false, left = false, right = false,
              A = false, B = false, select = false, start = false }
  for ch in keys:gmatch(".") do t[BUTTON[ch]] = true end
  joypad.set(1, t)
  emu.frameadvance()
end

function G.speed() return s8(rb(A_.speed)) * 256 + rb(A_.frac) end
function G.pos() return (rb(A_.page) * 256 + rb(A_.x)) * 256 + rb(A_.sub) end
function G.screen() return rb(A_.screen_page) * 256 + rb(A_.screen_x) end

function G.read()
  return {
    w = G.speed(), facing = rb(A_.facing), moving = rb(A_.moving),
    abs = rb(A_.abs), latch = rb(A_.latch) ~= 0,
    adder = rb(A_.adder_hi) * 256 + rb(A_.adder_lo),
    ground = rb(A_.state) == 0, timer = rb(A_.timer),
    prevA = rb(A_.prev_ab) >= 0x80, pos = G.pos(), screen = G.screen(),
  }
end

-- Write a model state into RAM over the start state. opt: ground, pixel
-- (absolute x), sub (subpixel), timer, prevA. In the air, Mario is put at
-- y 100 falling, too high to land in one frame.
function G.put(w, facing, moving, abs, latch, opt)
  local byte, frac = SM.split(w)
  wb(A_.speed, byte % 256); wb(A_.frac, frac)
  wb(A_.facing, facing); wb(A_.moving, moving); wb(A_.abs, abs)
  wb(A_.latch, latch and 28 or 0)
  wb(A_.timer, opt.timer or 0)
  wb(A_.prev_ab, opt.prevA and 0x80 or 0)
  if not opt.ground then
    wb(A_.state, 2); wb(A_.y, 100); wb(A_.y_speed, 0); wb(A_.y_force, 0)
  end
  wb(A_.page, floor(opt.pixel / 256)); wb(A_.x, opt.pixel % 256)
  wb(A_.sub, opt.sub or 0)
end

-- From power-on, reach the frame just before the first frame of control
-- in 1-1 and save it as the start state.
function G.reach_start()
  local n = 0
  while rb(A_.oper_mode) ~= 1 do
    G.press(n % 2 == 0 and "T" or "")
    n = n + 1
    if n > 900 then return false, "the game never started" end
  end
  n = 0
  while not (rb(A_.oper_task) == 3 and rb(A_.engine) == 8) do
    G.press("")
    n = n + 1
    if n > 900 then return false, "never reached the first frame of control" end
  end
  G.S0 = (savestate.object or savestate.create)()
  savestate.save(G.S0)
  emu.frameadvance()    -- FCEUX writes a Lua savestate at a frame boundary
  savestate.load(G.S0)
  emu.speedmode("maximum")
  G.edge = G.screen()   -- the left screen edge at the start, in px
  return true
end

function G.load() savestate.load(G.S0) end

-- === The model, against one frame of the ROM ================================

local M = {}

local function has(keys, ch) return keys:find(ch, 1, true) ~= nil end

-- The model's inputs for a frame of `keys`.
function M.inputs(keys, ground, timer, prevA)
  local lr = (has(keys, "R") and 1 or 0) + (has(keys, "L") and 2 or 0)
  local down = has(keys, "D")
  local other = has(keys, "B") or has(keys, "U") or has(keys, "S")
  local run_ok = has(keys, "B") or timer >= 2
  local jump = ground and has(keys, "A") and not prevA
  return lr, down, other, run_ok, jump
end

-- Compare one frame of the ROM with the model. `before` is the state at
-- the start of the frame (as G.read() returns it), `after` at its end.
-- mode "one" (a single written frame: a frame in the air stays in the
-- air) or "play" (Mario may land). Returns a list of {kind, text}, kinds
-- "state", "adder", "move", "jump"; and what the model said.
function M.compare(before, keys, after, mode)
  local lr, down, other, run_ok, jump = M.inputs(keys, before.ground,
      before.timer, before.prevA)
  local pinned = floor(after.pos / 256) == after.screen
  local w2, F2, M2, A2, L2, wmt, airborne, running, lr_used, adder,
        applied = SM.step(before.w, before.facing, before.moving,
            before.abs, before.latch, before.ground, lr, down, other,
            run_ok, jump, pinned)
  local problems, said = {}, { pinned = pinned, jump = jump }
  local function bad(kind, text) problems[#problems + 1] = { kind, text } end
  if not w2 then
    bad("move", "the ROM left Mario on the edge, but his speed byte would"
        .. " have taken him a pixel or more past it")
    return problems, said
  end
  said.wmt, said.adder, said.applied = wmt, adder, applied
  if w2 ~= after.w or F2 ~= after.facing or M2 ~= after.moving
     or A2 ~= after.abs or L2 ~= after.latch then
    bad("state", "model " .. T.state(w2, F2, M2, A2, L2) .. "; ROM "
        .. T.state(after.w, after.facing, after.moving, after.abs,
            after.latch))
  end
  if applied and adder ~= after.adder then
    bad("adder", string.format("model adds %d, ROM's FrictionAdder is"
        .. " $%04X (%d)", adder, after.adder, after.adder))
  end
  -- Mario moves by the speed byte that left the friction code; at the
  -- left edge, the clamp puts his pixel on the edge, keeping the subpixel.
  local moved = before.pos + 16 * floor(wmt / 256)
  local clamp = floor(moved / 256) <= after.screen
  local expect = moved
  if clamp then expect = after.screen * 256 + moved % 256 end
  if after.pos ~= expect then
    bad("move", "position " .. T.px(after.pos) .. ", expected "
        .. T.px(expect) .. (clamp and " (clamped at the edge)" or ""))
  elseif clamp ~= pinned then
    bad("move", "clamp mismatch at the edge")
  end
  if before.ground and jump and after.ground then
    bad("jump", "a new A press on the ground did not start a jump")
  elseif before.ground and not jump and not after.ground then
    bad("jump", "Mario left the ground without a jump")
  elseif mode == "one" and not before.ground and after.ground then
    bad("jump", "Mario landed in one frame from y 100")
  end
  return problems, said
end

function M.before_text(b, keys)
  return T.state(b.w, b.facing, b.moving, b.abs, b.latch) .. ", "
      .. (b.ground and "ground" or "air") .. string.format(", RunningTimer"
      .. " %d, A %s, x %s, keys %s", b.timer, b.prevA and "held" or "not"
      .. " held", T.px(b.pos), T.keys(keys))
end

-- === R1-R4. Setup ===========================================================

local function sha1(byte_at, n)
  local bitlib = bit
  if not bitlib then
    local ok, lib = pcall(require, "bit")
    if ok then bitlib = lib end
  end
  if not bitlib then return nil end
  local band, bor = bitlib.band, bitlib.bor
  local bxor, bnot = bitlib.bxor, bitlib.bnot
  local rol, tobit = bitlib.rol, bitlib.tobit
  local h = { tobit(0x67452301), tobit(0xEFCDAB89), tobit(0x98BADCFE),
              tobit(0x10325476), tobit(0xC3D2E1F0) }
  local total = n + 9
  while total % 64 ~= 0 do total = total + 1 end
  local function at(i)
    if i < n then return byte_at(i) end
    if i == n then return 0x80 end
    if i < total - 8 then return 0 end
    return floor(n * 8 / 2 ^ ((total - 1 - i) * 8)) % 256
  end
  local w = {}
  for chunk = 0, total - 1, 64 do
    for j = 0, 15 do
      local p = chunk + 4 * j
      w[j] = tobit(at(p) * 16777216 + at(p + 1) * 65536 + at(p + 2) * 256
          + at(p + 3))
    end
    for j = 16, 79 do
      w[j] = rol(bxor(w[j - 3], w[j - 8], w[j - 14], w[j - 16]), 1)
    end
    local a, b, c, d, e = h[1], h[2], h[3], h[4], h[5]
    for j = 0, 79 do
      local f, k
      if j < 20 then f, k = bor(band(b, c), band(bnot(b), d)), 0x5A827999
      elseif j < 40 then f, k = bxor(b, c, d), 0x6ED9EBA1
      elseif j < 60 then
        f, k = bor(band(b, c), band(b, d), band(c, d)), 0x8F1BBCDC
      else f, k = bxor(b, c, d), 0xCA62C1D6 end
      local t = tobit(rol(a, 5) + f + e + k + w[j])
      e, d, c, b, a = d, c, rol(b, 30), a, t
    end
    h[1], h[2], h[3] = tobit(h[1] + a), tobit(h[2] + b), tobit(h[3] + c)
    h[4], h[5] = tobit(h[4] + d), tobit(h[5] + e)
  end
  local hex = ""
  for i = 1, 5 do hex = hex .. bitlib.tohex(h[i], 8) end
  return hex
end

local function section_setup()
  -- R1
  local c = R.claim("R1", "The ROM is the known-good NTSC dump", {
    "Tests: the SHA-1 of the ROM's program and graphics data (no header)",
    "starts ea343f4e: the known-good NTSC dump, which SMBDIS.ASM is",
    "reported to build byte for byte.",
    "Supports: everything; the model was written from that disassembly.",
  })
  local have_rom = rom and rom.readbyte
  if not have_rom then
    R.done(c, "NOT RUN", "this FCEUX has no rom.readbyte")
  else
    local base = 0
    if rom.readbyte(0) == 0x4E and rom.readbyte(1) == 0x45
       and rom.readbyte(2) == 0x53 and rom.readbyte(3) == 0x1A then
      base = 16
      R.say(string.format("      iNES header: %d x 16 KiB program, %d x 8"
          .. " KiB graphics, mapper byte $%02X", rom.readbyte(4),
          rom.readbyte(5), rom.readbyte(6)))
    end
    local hex = sha1(function(i) return rom.readbyte(base + i) end, 40960)
    if not hex then
      R.done(c, "NOT RUN", "no bit library to compute SHA-1")
    else
      R.say("      SHA-1 of the 40 KiB of data: " .. hex)
      R.check(c, hex:sub(1, 8) == "ea343f4e", function()
        return "SHA-1 starts " .. hex:sub(1, 8) .. ", not ea343f4e"
      end)
      R.done(c)
    end
  end

  -- R2
  c = R.claim("R2", "The ROM's speed tables are the ones the model uses", {
    "Tests: the program contains MaxLeftXSpdData D8 E8 F0, then",
    "MaxRightXSpdData 28 18 10 0C, then FrictionData E4 98 D0, as in",
    "SMBDIS.ASM. Read from the ROM file, and from the CPU's view at the",
    "same address.",
    "Supports: the adders 228/152/208 and caps 40/24 in smbmodel.lua.",
  })
  local want = { 0xD8, 0xE8, 0xF0, 0x28, 0x18, 0x10, 0x0C, 0xE4, 0x98, 0xD0 }
  local function find(read, first, last)
    local hits = {}
    for a = first, last - #want + 1 do
      local ok = true
      for i = 1, #want do
        if read(a + i - 1) ~= want[i] then ok = false; break end
      end
      if ok then hits[#hits + 1] = a end
    end
    return hits
  end
  local cpu = find(rb, 0x8000, 0xFFFF)
  local file
  if have_rom then
    local base = (rom.readbyte(0) == 0x4E) and 16 or 0
    file = find(function(a) return rom.readbyte(base + a - 0x8000) end,
        0x8000, 0xFFFF)
  end
  local function where(h) return #h == 1 and string.format("once, at $%04X",
      h[1]) or (#h .. " times") end
  R.say("      CPU view: found " .. where(cpu) .. (file and ("; ROM file:"
      .. " found " .. where(file)) or ""))
  local ok = (#cpu == 1) or (file and #file == 1)
  if ok and file and #cpu == 1 and #file == 1 then ok = cpu[1] == file[1] end
  R.check(c, ok, function()
    return "the tables are not found exactly once, at one address"
  end)
  R.done(c)

  -- R3
  c = R.claim("R3", "The run starts at the first frame of control in 1-1", {
    "Tests: at the start state, RAM reads: speed 00:00, facing right",
    "(1), moving direction 0, $0700 0, latch clear, RunningTimer 0, on",
    "the ground at y 176, x 40 on page 0, subpixel 0; small Mario, ground",
    "area, not swimming, scroll unlocked, screen at 0, no collision.",
    "Supports: every sequence below starts here; the model's start state.",
  })
  G.load()
  local expect = {
    { "speed byte", A_.speed, 0 }, { "fraction", A_.frac, 0 },
    { "facing", A_.facing, 1 }, { "moving", A_.moving, 0 },
    { "$0700", A_.abs, 0 }, { "latch", A_.latch, 0 },
    { "RunningTimer", A_.timer, 0 }, { "Player_State", A_.state, 0 },
    { "y", A_.y, 0xB0 }, { "y high byte", A_.y_high, 1 },
    { "x", A_.x, 0x28 }, { "page", A_.page, 0 }, { "subpixel", A_.sub, 0 },
    { "PlayerSize", A_.size, 1 }, { "AreaType", A_.area, 1 },
    { "SwimmingFlag", A_.swim, 0 }, { "ScrollLock", A_.scroll_lock, 0 },
    { "screen page", A_.screen_page, 0 }, { "screen x", A_.screen_x, 0 },
    { "Player_CollisionBits", A_.collision, 0xFF },
    { "SideCollisionTimer", A_.side_timer, 0 },
    { "GameEngineSubroutine", A_.engine, 8 },
    { "Player_Pos_ForScroll", A_.for_scroll, 0x28 },
  }
  for _, e in ipairs(expect) do
    local got = rb(e[2])
    R.check(c, got == e[3], function()
      return string.format("%s ($%04X) = $%02X, expected $%02X", e[1], e[2],
          got, e[3])
    end)
  end
  R.done(c)

  -- R4
  c = R.claim("R4", "FCEUX passes Left+Right and Up+Down to the game", {
    "Tests: after a frame holding Left+Right, SavedJoypadBits ($06FC) has",
    "both bits; the same for Up+Down.",
    "Supports: every Left+Right result here and in the searches.",
  })
  G.load(); G.press("LR")
  local pad = rb(A_.pad)
  R.check(c, pad % 4 == 3, function()
    return string.format("$06FC = $%02X after Left+Right: tick Allow"
        .. " Left+Right / Up+Down in Config > Input", pad)
  end)
  G.load(); G.press("UD")
  pad = rb(A_.pad)
  R.check(c, floor(pad / 4) % 4 == 3, function()
    return string.format("$06FC = $%02X after Up+Down", pad)
  end)
  R.done(c)
end

-- === R5-R16. Witnesses ======================================================

-- Exact RAM values after chosen frames of an input sequence from the start.
-- Fields: s speed byte, f fraction, M moving, F facing, A $0700, R latch
-- byte, T RunningTimer, fh/fl FrictionAdder high/low, st Player_State.
local function snap()
  return {
    s = rb(A_.speed), f = rb(A_.frac), M = rb(A_.moving), F = rb(A_.facing),
    A = rb(A_.abs), R = rb(A_.latch), T = rb(A_.timer),
    fh = rb(A_.adder_hi), fl = rb(A_.adder_lo), st = rb(A_.state),
  }
end

local ORDER = { "s", "f", "M", "F", "A", "R", "T", "fh", "fl", "st" }
local NAME = { M = "moving", F = "facing", A = "$0700", R = "latch",
               T = "timer", st = "state" }

local function expect_text(e)
  local parts = {}
  if e.s and e.f then
    parts[#parts + 1] = "speed " .. T.speed(s8(e.s) * 256 + e.f)
  elseif e.s then
    parts[#parts + 1] = string.format("speed byte %02X", e.s)
  end
  for _, k in ipairs(ORDER) do
    if NAME[k] and e[k] then
      parts[#parts + 1] = string.format("%s %d", NAME[k], e[k])
    end
  end
  if e.fh and e.fl then
    parts[#parts + 1] = string.format("adder %d", e.fh * 256 + e.fl)
  end
  return table.concat(parts, ", ")
end

local function witness(c, label, inputs, expect)
  R.say("    " .. label .. ": " .. T.line(inputs))
  G.load()
  for i, keys in ipairs(inputs) do
    G.press(keys)
    local e = expect[i]
    if e then
      local g, wrong = snap(), {}
      for _, k in ipairs(ORDER) do
        if e[k] and g[k] ~= e[k] then
          wrong[#wrong + 1] = string.format("%s %d (want %d)", NAME[k] or k,
              g[k], e[k])
        end
      end
      R.say(string.format("      frame %2d %-4s expect %s: %s", i,
          T.keys(keys), expect_text(e), #wrong == 0 and "ok"
          or ("GOT " .. table.concat(wrong, ", "))))
      if #wrong == 0 then R.pass(c) else c.n, c.bad = c.n + 1, c.bad + 1 end
    end
  end
end

local function rep(k, n, l)
  l = l or {}
  for _ = 1, n do l[#l + 1] = k end
  return l
end
local function cat(...)
  local o = {}
  for _, l in ipairs({ ... }) do for _, k in ipairs(l) do o[#o + 1] = k end end
  return o
end

local RTA_LINE = cat({ "LB", "B", "RBA" }, rep("RB", 22), { "LB", "RBA" },
    rep("RB", 7))

local function section_witnesses()
  local c = R.claim("R5", "From rest, frame 1 is doubled: 304, the walking"
      .. " rate the latch rule uses", {
    "Tests: from the start, one frame of Right (or Right+B) gives speed",
    "01:30 = 304 = 152 ($98) doubled, because the moving direction starts",
    "at 0, not 1, so facing right differs from it.",
    "Supports: SLOW_WALK_ACCEL (304) is reached, so it can't be lowered.",
  })
  local B1 = { s = 1, f = 0x30, fh = 1, fl = 0x30, M = 1, F = 1, A = 1, T = 0 }
  witness(c, "Right", { "R" }, { B1 })
  witness(c, "Right+B", { "RB" }, { B1 })
  R.done(c)

  c = R.claim("R6", "A slow backwards speed resets to zero in one frame", {
    "Tests: the RTA opening's first two frames, Left+B then B alone: the",
    "speed goes to FE:D0 (-1.19), then to 00:00 in one frame (ProcSkid:",
    "$0700 below 11, a button other than A held, Left/Right not matching",
    "the moving direction).",
    "Also Left+Right from rest: the reset runs every frame, so the speed",
    "stays at 01:30.",
    "Supports: the ramp starts from max(speed, 0); a slow negative speed",
    "is never worse than standing.",
  })
  witness(c, "RTA opening", { "LB", "B" }, {
    { s = 0xFE, f = 0xD0, M = 2, F = 2, A = 2, fh = 1, fl = 0x30 },
    { s = 0, f = 0, M = 2, F = 2, A = 0 },
  })
  witness(c, "Left+Right from rest", rep("LR", 5),
      rep({ s = 1, f = 0x30, M = 1, F = 3 }, 5))
  R.done(c)

  c = R.claim("R7", "Running caps the speed byte at 40 and keeps the"
      .. " fraction; the latch sets at 28", {
    "Tests: holding Right+B from the start: the latch is clear on frame 32",
    "and set ($1C) on frame 33; the speed byte reaches $28 (40) on frame",
    "45 and stays there while the fraction keeps changing.",
    "Supports: MAX_SPEED (40); the latch threshold the latch rule uses.",
  })
  witness(c, "Right+B", rep("RB", 50), {
    [2] = { s = 2, f = 0x14, fh = 0, fl = 0xE4 }, [32] = { R = 0 },
    [33] = { R = 0x1C }, [44] = { s = 0x27, f = 0x7C },
    [45] = { s = 0x28, f = 0x60 }, [46] = { s = 0x28, f = 0x44 },
    [47] = { s = 0x28, f = 0x28 }, [48] = { s = 0x28, f = 0x0C },
    [49] = { s = 0x28, f = 0xF0 }, [50] = { s = 0x28, f = 0xD4 },
  })
  R.done(c)

  c = R.claim("R8", "With the latch set, Left+Right below 25 gains 416 a"
      .. " frame on the ground", {
    "Tests: Right+B to 28 sets the latch; coasting below 25 keeps it.",
    "Left+Right then adds 208 ($D0) on its first frame, which turns facing",
    "to 3, and 416 (doubled) on every frame after, up to the cap of 24.",
    "Supports: WALK_ACCEL (416) is reached below 25, so the speed-only",
    "bound can't use 304 there.",
  })
  witness(c, "Right+B, coast, Left+Right",
      cat(rep("RB", 32), rep("", 10), rep("LR", 4)), {
    [32] = { s = 0x1C, f = 0xCC, R = 0 },
    [33] = { s = 0x1C, f = 0x34, R = 0x1C, fh = 0, fl = 0x98 },
    [34] = { s = 0x1B, f = 0x64, fl = 0xD0 }, [35] = { s = 0x1A, f = 0x94 },
    [36] = { s = 0x19, f = 0xC4 }, [37] = { s = 0x18, f = 0xF4 },
    [38] = { s = 0x18, f = 0x24 }, [39] = { s = 0x17, f = 0x54 },
    [40] = { s = 0x16, f = 0x84 }, [41] = { s = 0x15, f = 0xB4 },
    [42] = { s = 0x14, f = 0xE4, R = 0x1C },
    [43] = { s = 0x15, f = 0xB4, F = 3, fh = 0, fl = 0xD0, R = 0x1C },
    [44] = { s = 0x17, f = 0x54, fh = 1, fl = 0xA0 },
    [45] = { s = 0x18, f = 0xF4 }, [46] = { s = 0x18, f = 0x94 },
  })
  R.done(c)

  c = R.claim("R9", "With the latch set, a jump holding Right gains 416"
      .. " per air frame below 25", {
    "Tests: run to 28 and one more ground frame (latch set), slow with",
    "Left to 10 or less, one Left+Right frame (speed 01:A0, facing 3,",
    "moving 1), then A+Right: every air frame that ends below the walking",
    "cap (24) adds exactly 416, with FrictionAdder $01A0. JDaster64's",
    "chart has 152 here.",
    "Supports: WALK_ACCEL (416) also applies in the air, holding forward.",
  })
  G.load()
  local n = 0
  while G.speed() < 28 * 256 and n < 80 do G.press("RB"); n = n + 1 end
  G.press("RB")
  R.say(string.format("    Right+B x%d: speed %s, latch $%02X", n + 1,
      T.speed(G.speed()), rb(A_.latch)))
  R.check(c, rb(A_.latch) ~= 0, function() return "latch not set at 28" end)
  local m = 0
  while floor(G.speed() / 256) > 10 and m < 80 do G.press("L"); m = m + 1 end
  R.say(string.format("    Left x%d: speed %s, latch $%02X", m,
      T.speed(G.speed()), rb(A_.latch)))
  R.check(c, rb(A_.latch) ~= 0, function()
    return "pressing Left (against the motion) cleared the latch"
  end)
  G.press("LR")
  local g = G.read()
  R.say("    Left+Right: " .. T.state(g.w, g.facing, g.moving, g.abs, g.latch))
  R.check(c, g.w == 0x1A0 and g.facing == 3 and g.moving == 1 and g.latch,
    function() return "expected speed 01:A0, facing 3, moving 1, latch set" end)
  local gains, air = 0, 0
  for _ = 1, 40 do
    local w0 = G.speed()
    G.press("AR")
    if rb(A_.state) == 0 then break end
    air = air + 1
    local w1 = G.speed()
    if floor(w1 / 256) < 24 then
      local adder = rb(A_.adder_hi) * 256 + rb(A_.adder_lo)
      if R.check(c, w1 - w0 == 416 and adder == 0x1A0, function()
        return string.format("air frame %d: gain %d, adder $%04X", air,
            w1 - w0, adder)
      end) then gains = gains + 1 end
    end
  end
  R.say(string.format("    A+Right: %d air frames gained exactly 416"
      .. " below 24 (expect 10 or more)", gains))
  R.check(c, gains >= 10, function() return "too few air frames" end)
  R.done(c)

  c = R.claim("R10", "From 25 up, in the air facing backwards, every frame"
      .. " gains 456", {
    "Tests: fast accel's second jump. Right+B to 26, one frame of Left",
    "(facing turns left), then A+Right: each air frame adds 456 =",
    "228 ($E4) doubled, to 40, because facing (left) differs from the",
    "moving direction (right), and the air uses $E4 from $0700 = 25.",
    "Supports: RUN_ACCEL (456) and RUN_ACCEL_THRES (25).",
  })
  witness(c, "Right+B, Left, A+Right",
      cat(rep("RB", 29), { "L" }, rep("AR", 9)), {
    [29] = { s = 0x1A, f = 0x20, F = 1 },
    [30] = { s = 0x19, f = 0x88, F = 2, M = 1, fh = 0, fl = 0x98 },
    [31] = { s = 0x1B, f = 0x50, F = 2, st = 1, fh = 1, fl = 0xC8 },
    [32] = { s = 0x1D, f = 0x18, F = 2 }, [33] = { s = 0x1E, f = 0xE0 },
    [34] = { s = 0x20, f = 0xA8 }, [35] = { s = 0x22, f = 0x70 },
    [36] = { s = 0x24, f = 0x38 }, [37] = { s = 0x26, f = 0x00 },
    [38] = { s = 0x27, f = 0xC8 }, [39] = { s = 0x28, f = 0x90, F = 2, st = 1 },
  })
  R.done(c)

  c = R.claim("R11", "From rest, two 456 frames in a row (the double"
      .. " charge)", {
    "Tests: Left+Right, B, Right, Left+Right+B, Right+B. B's skid reset",
    "copies facing 3 into the moving direction; Right then turns facing",
    "right, so facing and moving differ twice: Left+Right+B and Right+B",
    "each run at 228 doubled = 456.",
    "Supports: FREE_FRAMES = 2; one free frame is not enough.",
  })
  witness(c, "double charge", { "LR", "B", "R", "LRB", "RB" }, {
    { s = 1, f = 0x30, M = 1, F = 3 }, { s = 0, f = 0, M = 3, F = 3 },
    { s = 0, f = 0x98, M = 3, F = 1, fh = 0, fl = 0x98 },
    { s = 2, f = 0x60, M = 1, F = 3, fh = 1, fl = 0xC8 },
    { s = 4, f = 0x28, M = 1, F = 1, fh = 1, fl = 0xC8 },
  })
  R.done(c)

  c = R.claim("R12", "At the left edge, a 1/16 px step left leaves Mario"
      .. " 15/16 px further right", {
    "Tests (state written into RAM): Mario on the left edge, subpixel 0,",
    "speed FF:00, facing and moving left; one frame with no buttons. He",
    "moves 1/16 px left, past the edge; the clamp puts his pixel back on",
    "the edge but keeps the subpixel, $F0. Net: +15/16 px, and the speed",
    "byte is zeroed with the fraction kept.",
    "Supports: EDGE_PUSH_PX (15/16) is reached.",
  })
  G.load()
  G.put(-256, 2, 2, 1, false, { ground = true, pixel = G.edge, sub = 0 })
  local p0 = G.pos()
  G.press("")
  g = G.read()
  R.say(string.format("    position %s -> %s (change %+.4f px), speed %s",
      T.px(p0), T.px(g.pos), (g.pos - p0) / 256, T.speed(g.w)))
  R.check(c, g.pos - p0 == 240 and floor(g.w / 256) == 0, function()
    return "expected a change of +0.9375 px and speed byte 0"
  end)
  R.done(c)

  c = R.claim("R13", "Running left into the edge leaves $0700 stale, and"
      .. " the latch is read from it", {
    "Tests: Left+B from the start until the edge clamps Mario. Then the",
    "speed byte is 0 while $0700 still holds the old speed (25 or more),",
    "moving left. On the next ground frame (Right), the game sets the",
    "latch from $0700 as if Mario were still running: the latch byte",
    "equals the stale $0700 (when it is 28 or more). R15 shows the same",
    "thing setting a latch that was clear.",
    "Supports: the latch rule tests $0700 < 25, not the speed byte.",
  })
  G.load()
  n = 0
  while floor(G.pos() / 256) ~= G.screen() and n < 150 do
    G.press("LB"); n = n + 1
  end
  g = G.read()
  R.say(string.format("    Left+B x%d: %s", n, T.state(g.w, g.facing,
      g.moving, g.abs, g.latch)))
  R.check(c, floor(g.w / 256) == 0 and g.abs >= 25 and g.moving == 2,
    function() return "expected speed byte 0, $0700 25 or more, moving 2" end)
  local stale = g.abs
  G.press("R")
  R.say(string.format("    Right: latch byte $%02X, stale $0700 $%02X",
      rb(A_.latch), stale))
  if stale >= 28 then
    R.check(c, rb(A_.latch) == stale, function()
      return string.format("latch byte $%02X, expected $%02X", rb(A_.latch),
          stale)
    end)
  end
  R.done(c)

  c = R.claim("R14", "Left+Right into the edge loads a 456 jump at speed"
      .. " 0", {
    "Tests: Left+B to 3 px from the edge, Left+Right into it: speed byte",
    "0, moving left, facing 3, $0700 25 or more. Then A+Right: the jump",
    "frame adds 456 (the air reads the stale $0700 as running speed, and",
    "facing 3 differs from moving 2); each later air frame uses adder",
    "$01A0 (416) with facing 3; the first ground frame of Right+B adds 456.",
    "Supports: a second way to get two 456 frames from speed 0 (FREE_FRAMES",
    "= 2), through the stale-$0700 state.",
  })
  G.load()
  n = 0
  while floor(G.pos() / 256) - G.screen() > 3 and n < 150 do
    G.press("LB"); n = n + 1
  end
  m = 0
  while floor(G.pos() / 256) ~= G.screen() and m < 30 do
    G.press("LR"); m = m + 1
  end
  g = G.read()
  R.say(string.format("    Left+B x%d, Left+Right x%d: %s", n, m,
      T.state(g.w, g.facing, g.moving, g.abs, g.latch)))
  R.check(c, floor(g.w / 256) == 0 and g.moving == 2 and g.facing == 3
      and g.abs >= 25, function()
    return "expected speed byte 0, moving 2, facing 3, $0700 25 or more"
  end)
  local w0 = g.w
  G.press("AR")
  g = G.read()
  R.say(string.format("    A+Right (jump frame): speed %s, gain %d, adder"
      .. " $%04X, facing %d, moving %d", T.speed(g.w), g.w - w0, g.adder,
      g.facing, g.moving))
  R.check(c, g.w - w0 == 456 and g.adder == 0x1C8 and g.facing == 3
      and g.moving == 1, function()
    return "expected gain 456, adder $01C8, facing 3, moving 1"
  end)
  air = 0
  while not G.read().ground and air < 80 do
    G.press("AR"); air = air + 1
    g = G.read()
    R.check(c, g.adder == 0x1A0 and g.facing == 3, function()
      return string.format("air frame %d: adder $%04X, facing %d", air,
          g.adder, g.facing)
    end)
  end
  w0 = G.speed()
  G.press("RB")
  g = G.read()
  R.say(string.format("    %d air frames at adder $01A0; first ground"
      .. " frame Right+B: gain %d, adder $%04X", air, g.w - w0, g.adder))
  R.check(c, g.w - w0 == 456 and g.adder == 0x1C8, function()
    return "expected gain 456, adder $01C8 on the first ground frame"
  end)
  R.done(c)

  -- R15: the left-edge trap, found by search (the ROM's timing decides
  -- the exact frame counts).
  if not B then
    R.skip("R15", "The left-edge trap", "bound file not loaded: "
        .. tostring(bound_err))
  else
    c = R.claim("R15", "The left-edge trap: why the latch rule tests speed"
        .. " >= 0", {
      "Tests: walk left at the walking cap (latch clear), turn right for",
      "one frame near the edge: that state has latch clear, $0700 < 25",
      "and is moving left. Then run left into the edge (stale $0700 of",
      "28 or more), Left+Right (latch sets at speed 0), and jump holding",
      "Right. Searches nearby frame counts. Shows the speed then exceeds",
      "the 304 ramp from that state, so a rule without the speed test",
      "would break; " .. BOUND_NAME .. " gives that state 416 and must hold.",
      "Supports: qualifies_for_slower_ramp()'s speed >= 0 test.",
    })
    local found = false
    for b = 30, 45 do for a = 0, 2 do for cc = 0, 3 do for e = 2, 5 do
      if not found then
        local line = rep("LB", a)
        rep("L", b, line); rep("LB", cc, line); line[#line + 1] = "R"
        local node = #line
        rep("LB", e, line); line[#line + 1] = "LR"; rep("AR", 24, line)
        G.load()
        for t = 1, node do G.press(line[t]) end
        local v, p = B.get_xvel(), G.pos()
        local qualifies = B.qualifies_for_slower_ramp()
        local nosign = rb(A_.latch) == 0 and rb(A_.abs) < 25
        if nosign and not qualifies and v < 0 then
          local e304 = H.envelope(B, v, true, CFG.K)
          local e416 = H.envelope(B, v, false, CFG.K)
          local beat, held, latch0 = nil, true, nil
          for t = node + 1, #line do
            G.press(line[t])
            local k = t - node
            local s = s8(rb(A_.speed))
            if s == 0 and rb(A_.latch) ~= 0 and not latch0 then latch0 = t end
            if s > e416.byte[k] or (G.pos() - p) / 256 > e416.dist[k] + 1e-9
            then held = false end
            if not beat and s > e304.byte[k] then
              beat = { k = k, s = s, lim = e304.byte[k], t = t }
            end
          end
          if beat then
            found = true
            R.say(string.format("    state after frame %d: speed %.3f,"
                .. " latch clear, $0700 < 25, moving left", node, v))
            R.say(string.format("    latch set at speed 0 on frame %s; %d"
                .. " frames after the state the speed byte is %d, above the"
                .. " 304 ramp's %d", tostring(latch0), beat.k, beat.s,
                beat.lim))
            R.say("    inputs: " .. T.line(line, beat.t))
            R.check(c, held, function()
              return BOUND_NAME .. " (416 from that state) was beaten on this"
                  .. " line"
            end)
          end
        end
      end
    end end end end
    if found then R.done(c)
    else R.done(c, "NOT SHOWN", "trap not reproduced on the searched lines") end
  end

  c = R.claim("R16", "Other rules the model uses", {
    "Tests: Down cancels Left/Right on the ground (Right, then Down+Right",
    "slows: speed 00:98). Facing doesn't change in the air (a jump, then",
    "Left in the air leaves facing 1). Left+Right at 11 or more walks at",
    "304 (152 doubled) instead of resetting.",
    "Supports: smbmodel.lua's input rules.",
  })
  witness(c, "Down cancels", { "R", "DR" },
      { { s = 1, f = 0x30 }, { s = 0, f = 0x98, M = 1, F = 1 } })
  witness(c, "facing in the air", cat({ "AR" }, rep("A", 5), { "AL" }), {
    { s = 1, f = 0x30, M = 1, F = 1, st = 1 }, { s = 1, f = 0x30 },
    { s = 1, f = 0x30 }, { s = 1, f = 0x30 }, { s = 1, f = 0x30 },
    { s = 1, f = 0x30 }, { s = 0, f = 0x98, F = 1, M = 1 },
  })
  witness(c, "Left+Right at 11+", cat(rep("RB", 13), rep("LR", 4)), {
    [13] = { s = 0x0B, f = 0xE0 },
    [14] = { s = 0x0C, f = 0x78, F = 3, fh = 0, fl = 0x98 },
    [15] = { s = 0x0D, f = 0xA8, fh = 1, fl = 0x30 },
    [16] = { s = 0x0E, f = 0xD8 }, [17] = { s = 0x10, f = 0x08 },
  })
  R.done(c)
end

-- === R29-R37. Gotchas =======================================================

-- Each claim shows, on the ROM, a shortcut or reading of the code that looks
-- right and isn't. "Rules out" names the wrong idea.

local function adder_now() return rb(A_.adder_hi) * 256 + rb(A_.adder_lo) end

local function section_gotchas()
  local c, n

  if not B then
    R.skip("R29", "The latch rule needs both free frames", "bound file not"
        .. " loaded: " .. tostring(bound_err))
  else
    c = R.claim("R29", "The latch rule needs both free frames", {
      "Tests: R11's double charge. After Left+Right, B, Right, the state",
      "passes qualifies_for_slower_ramp() (latch clear, $0700 below 25, not",
      "moving left). The next two frames, Left+Right+B and Right+B, each",
      "gain 456, so two frames on, the speed byte is above what the latch",
      "rule's ramp with one free frame allows, and within " .. BOUND_NAME
          .. "'s ramp.",
      "Rules out: one free frame wherever the latch rule applies. That",
      "holds for scores in the model (M10), not frame by frame.",
      "Supports: FREE_FRAMES = 2 under the latch rule as well.",
    })
    G.load()
    for _, keys in ipairs({ "LR", "B", "R" }) do G.press(keys) end
    local v, g = B.get_xvel(), G.read()
    local qualifies = B.qualifies_for_slower_ramp()
    R.say("    after Left+Right, B, Right: " .. T.state(g.w, g.facing,
        g.moving, g.abs, g.latch) .. "; qualifies: " .. tostring(qualifies))
    R.check(c, qualifies, function()
      return "the state doesn't qualify for the latch rule"
    end)
    local one = H.envelope(B, v, true, CFG.K, { free_frames = 1 })
    local own = H.envelope(B, v, true, CFG.K)
    local w0 = G.speed()
    G.press("LRB")
    local w1 = G.speed()
    G.press("RB")
    local w2 = G.speed()
    local s = floor(w2 / 256)
    R.say(string.format("    Left+Right+B: gain %d; Right+B: gain %d; speed"
        .. " byte %d. Ramps two frames on: one free frame %d, %s %d",
        w1 - w0, w2 - w1, s, one.byte[2], BOUND_NAME, own.byte[2]))
    R.check(c, w1 - w0 == 456 and w2 - w1 == 456, function()
      return "expected two gains of 456"
    end)
    R.check(c, s > one.byte[2] and s <= own.byte[2], function()
      return "the speed byte is not above the one-free-frame ramp and"
          .. " within the bound's"
    end)
    R.done(c)
  end

  c = R.claim("R30", "At speed byte 0, the fraction and moving direction 3"
      .. " stay", {
    "Tests: Left+Right, B, Right (speed 00:98, facing 1, moving 3), then 10",
    "frames with no buttons: speed 00:98 and moving direction 3 on every",
    "one. ImposeFriction tests only the speed byte, and ChkMoveDir sets the",
    "moving direction only from a nonzero one. Then Right: ProcSkid copies",
    "facing 1 into the moving direction.",
    "Rules out: friction on the 16-bit speed, and moving direction 3",
    "wearing off by itself.",
    "Supports: smbmodel.lua's friction test; the double charge's setup.",
  })
  local expect = {}
  for i = 3, 13 do expect[i] = { s = 0, f = 0x98, M = 3, F = 1 } end
  expect[14] = { s = 1, f = 0x30, M = 1, F = 1 }
  witness(c, "double charge setup, then no buttons",
      cat({ "LR", "B", "R" }, rep("", 10), { "R" }), expect)
  R.done(c)

  c = R.claim("R31", "Walking caps at 24, even with the latch set", {
    "Tests: Right+B until the latch sets, then Right alone. While",
    "RunningTimer lasts Mario still runs; when it runs out, the cap drops",
    "to 24 and the speed byte snaps to 24 in one frame, with adder $00D0:",
    "the latch picks FrictionData's third entry, but the cap comes from",
    "MaxRightXSpdData's second. It stays at 24 after.",
    "Rules out: taking the cap from the friction index (MaxRightXSpdData's",
    "third entry is 16).",
    "Supports: smbmodel.lua's caps; WALK_ACCEL applies only below 25.",
  })
  G.load()
  n = 0
  while G.speed() < 28 * 256 and n < 80 do G.press("RB"); n = n + 1 end
  G.press("RB")
  local before, snapped = s8(rb(A_.speed)), nil
  for t = 1, 20 do
    G.press("R")
    local s = s8(rb(A_.speed))
    if not snapped and s == 24 and before > 24 then
      snapped = { t = t, from = before, adder = adder_now(),
                  latch = rb(A_.latch) }
    end
    before = s
  end
  if snapped then
    R.say(string.format("    Right+B x%d, then Right: speed byte %d -> 24 on"
        .. " Right frame %d, adder $%04X, latch $%02X; after 20 frames %d",
        n + 1, snapped.from, snapped.t, snapped.adder, snapped.latch, before))
  end
  R.check(c, snapped and snapped.adder == 0xD0 and snapped.latch ~= 0
      and before == 24, function()
    return "expected a one-frame drop to 24 with adder $00D0 and the latch"
        .. " set, staying at 24"
  end)
  R.done(c)

  c = R.claim("R32", "A jump keeps the latch of its last ground frame", {
    "Tests: Right+B from the start, then a jump (A+Right+B) on frame 33",
    "or 34. R7's latch sets on frame 33, from $0700 at that frame's start.",
    "A jump on frame 33 takes off at speed 28 or more with the latch clear,",
    "and it stays clear in the air (GetPlayerAnimSpeed runs only on ground",
    "frames); a jump on frame 34 carries it.",
    "Rules out: the latch following the takeoff speed. Judged from takeoff",
    "speeds the threshold looks like 29, as in JDaster64's chart; it is 28,",
    "one ground frame earlier.",
    "Supports: smbmodel.lua's latch timing; the latch rule's latch test.",
  })
  for _, t in ipairs({ 33, 34 }) do
    G.load()
    for _ = 1, t - 1 do G.press("RB") end
    local w0 = G.speed()
    G.press("ARB")
    local air, latch, kept = rb(A_.state) ~= 0, rb(A_.latch), true
    for _ = 1, 10 do
      G.press("ARB")
      if rb(A_.state) == 0 then break end
      if rb(A_.latch) ~= latch then kept = false end
    end
    R.say(string.format("    jump on frame %d: takeoff speed %s, %s, latch"
        .. " $%02X, %s in the air", t, T.speed(w0), air and "airborne"
        or "STILL ON THE GROUND", latch, kept and "unchanged" or "CHANGED"))
    R.check(c, air and kept and w0 >= 28 * 256
        and (latch ~= 0) == (t == 34), function()
      return string.format("frame %d: expected the latch %s", t,
          t == 34 and "set" or "clear")
    end)
  end
  R.done(c)

  c = R.claim("R33", "From 25 up, running forward adds 228, not 456", {
    "Tests: Right+B from the start: every frame that starts at speed byte",
    "25 or more and ends below the cap adds exactly 228, adder $00E4.",
    "Facing equals the moving direction, so $E4 isn't doubled.",
    "Rules out: 456 every frame from 25 as the game's rate. The bound",
    "allows it as an upper bound; 456 needs facing to differ (R10, R34).",
    "Supports: the tighter rule from 25 up in OPEN_CLAIMS.md.",
  })
  G.load()
  local frames = 0
  for _ = 1, 60 do
    local w0 = G.speed()
    G.press("RB")
    local w1 = G.speed()
    if floor(w0 / 256) >= 25 and floor(w1 / 256) < 40 then
      frames = frames + 1
      R.check(c, w1 - w0 == 228 and adder_now() == 0xE4, function()
        return string.format("from %s: gain %d, adder $%04X", T.speed(w0),
            w1 - w0, adder_now())
      end)
    end
  end
  R.say(string.format("    %d frames from 25 to the cap", frames))
  R.check(c, frames >= 10, function() return "too few frames from 25" end)
  R.done(c)

  c = R.claim("R34", "A turnaround holds one 456 frame, at any speed", {
    "Tests: Right+B to speed bytes 12, 20 and 30, one frame of Left (facing",
    "turns left, the moving direction stays right), then Right+B twice:",
    "the first adds 456 ($E4 doubled: facing differs from the moving",
    "direction), the second only 228 (facing is right again).",
    "Rules out: no free frames for a moving state; the burst check keeps",
    "one.",
    "Supports: FREE_FRAMES_IF_MOVING = 1.",
  })
  for _, target in ipairs({ 12, 20, 30 }) do
    G.load()
    n = 0
    while floor(G.speed() / 256) < target and n < 80 do
      G.press("RB"); n = n + 1
    end
    G.press("L")
    local g = G.read()
    G.press("RB")
    local w1, a1 = G.speed(), adder_now()
    G.press("RB")
    local w2 = G.speed()
    R.say(string.format("    Right+B x%d, Left (%s, facing %d, moving %d),"
        .. " Right+B: %+d (adder $%04X), Right+B: %+d", n, T.speed(g.w),
        g.facing, g.moving, w1 - g.w, a1, w2 - w1))
    R.check(c, g.facing == 2 and g.moving == 1 and w1 - g.w == 456
        and a1 == 0x1C8 and w2 - w1 == 228, function()
      return string.format("speed byte %d: expected Left to leave facing 2,"
          .. " moving 1, then +456 and +228", target)
    end)
  end
  R.done(c)

  -- Written states for R35-R37: on the ground at x 96, facing and moving
  -- right, latch clear unless given, RunningTimer as given.
  local function one_frame(w, abs, latch, timer, keys)
    G.load()
    G.put(w, 1, 1, abs, latch, { ground = true, pixel = 0x60,
                                 timer = timer })
    G.press(keys)
    return G.read()
  end

  c = R.claim("R35", "RunningTimer keeps Mario running only from 2 up", {
    "Tests (states written into RAM): speed 10, facing and moving right,",
    "Right alone, with RunningTimer 2 and 1 before the frame. At 2 the",
    "running rules apply (adder $00E4, +228); at 1 the walking rules do",
    "($0098, +152): the timer counts down before the game logic reads it.",
    "Rules out: any nonzero RunningTimer allowing a run.",
    "Supports: smbmodel.lua's run_ok (B, or RunningTimer 2 or more).",
  })
  for _, e in ipairs({ { timer = 2, adder = 0xE4 }, { timer = 1,
                                                      adder = 0x98 } }) do
    local g = one_frame(10 * 256, 10, false, e.timer, "R")
    R.say(string.format("    RunningTimer %d, Right: speed %s (%+d), adder"
        .. " $%04X", e.timer, T.speed(g.w), g.w - 10 * 256, g.adder))
    R.check(c, g.adder == e.adder and g.w - 10 * 256 == e.adder, function()
      return string.format("RunningTimer %d: expected adder $%04X", e.timer,
          e.adder)
    end)
  end
  R.done(c)

  c = R.claim("R36", "Down hides Left/Right only from the acceleration", {
    "Tests (states written into RAM), on the ground facing and moving",
    "right. Down+Left at speed 5: the skid reset (ProcSkid) still sees",
    "Left and zeroes the speed, though the acceleration sees no direction.",
    "Down+Right at speed 20 with the latch set: the latch clears, since",
    "Right matches the moving direction.",
    "Rules out: Down cancelling Left/Right everywhere on the ground.",
    "Supports: smbmodel.lua's raw buttons for the latch and skid checks.",
  })
  local g = one_frame(5 * 256, 5, false, 0, "DL")
  R.say("    speed 5, Down+Left: " .. T.state(g.w, g.facing, g.moving, g.abs,
      g.latch))
  R.check(c, g.w == 0 and g.moving == 1 and g.facing == 1, function()
    return "expected speed 00:00, facing and moving still right"
  end)
  g = one_frame(20 * 256, 20, true, 0, "DR")
  R.say("    speed 20, latch set, Down+Right: " .. T.state(g.w, g.facing,
      g.moving, g.abs, g.latch))
  R.check(c, not g.latch and floor(g.w / 256) == 19, function()
    return "expected the latch clear and the speed slowing (Right unseen)"
  end)
  R.done(c)

  c = R.claim("R37", "$0700 of 33 or more picks $D0 without the latch", {
    "Tests (states written into RAM): on the ground, latch clear, facing",
    "and moving right, RunningTimer 0, Right alone, at speed 32 and 33.",
    "At 32 the walking adder is $0098; at 33 it is $00D0, as if the latch",
    "were set ($0700 >= $21). Both snap to the walking cap of 24.",
    "Rules out: $D0 only with the latch set.",
    "Supports: smbmodel.lua's adder choice; WALK_ACCEL's conditions.",
  })
  for _, e in ipairs({ { speed = 32, adder = 0x98 }, { speed = 33,
                                                      adder = 0xD0 } }) do
    g = one_frame(e.speed * 256, e.speed, false, 0, "R")
    R.say(string.format("    speed %d, Right: speed %s, adder $%04X", e.speed,
        T.speed(g.w), g.adder))
    R.check(c, g.adder == e.adder and floor(g.w / 256) == 24, function()
      return string.format("speed %d: expected adder $%04X and speed byte 24",
          e.speed, e.adder)
    end)
  end
  R.done(c)
end

-- === R17. Every button combination ==========================================

local BITS = { "R", "L", "U", "D", "A", "B", "S" }

local function section_buttons(states)
  local c = R.claim("R17", "Only the inputs the model distinguishes matter", {
    "Tests: " .. CFG.button_states .. " random states, on the ground and in the"
        .. " air, with",
    "all 128 combinations of R, L, U, D, A, B and Select, at random",
    "RunningTimer 0-10, previous A held or not, 1 in 4 at the left edge.",
    "Each frame must match the model, which reads only: Left/Right",
    "(Down cancels them on the ground), whether a non-A button is held,",
    "whether B is held or RunningTimer is 2 or more, and a new A press on",
    "the ground. So Up and Select act like B for the latch and the skid",
    "but don't run, and only Left/Right matter in the air.",
    "Supports: the input cases R25-R28 use; the bound's input alphabet.",
  })
  for _ = 1, CFG.button_states do
    local st = states[math.random(#states)]
    for g = 1, 2 do
      local ground = (g == 1)
      for combo = 0, 127 do
        local keys = ""
        for i, ch in ipairs(BITS) do
          if floor(combo / 2 ^ (i - 1)) % 2 == 1 then keys = keys .. ch end
        end
        local timer, prevA = math.random(0, 10), math.random() < 0.5
        local px = (math.random() < 0.25) and G.edge or 0x60
        G.load()
        G.put(st[1], st[2], st[3], st[4], st[5],
            { ground = ground, pixel = px, timer = timer, prevA = prevA })
        local before = { w = st[1], facing = st[2], moving = st[3],
                         abs = st[4], latch = st[5], ground = ground,
                         timer = timer, prevA = prevA, pos = px * 256 }
        G.press(keys)
        local problems = M.compare(before, keys, G.read(), "one")
        if #problems == 0 then R.pass(c) else
          R.fail(c, M.before_text(before, keys) .. ": " .. problems[1][2])
        end
      end
    end
  end
  R.done(c)
end

-- === R18. The left edge, every subpixel =====================================

local function section_edge()
  local c = R.claim("R18", "The left edge clamp, at every subpixel", {
    "Tests (states written into RAM): Mario on the left edge, at each",
    "subpixel 0-240 (step 16), each speed byte -40 to +15, each facing, on",
    "the ground and in the air, under -, R, L, LR, RB, LB, B. Each frame",
    "must match the model, and: Mario moves 16 x speed byte (1/256 px);",
    "if that takes his pixel to the edge or past it, the pixel is set to",
    "the edge and the subpixel kept; the speed byte is zeroed unless",
    "exactly Right is held; he never ends left of the edge; and the clamp",
    "never lifts him more than 15/16 px in a frame.",
    "Supports: EDGE_PUSH_PX (15/16) is the most; the model's edge rule.",
  })
  local inputs = { "", "R", "L", "LR", "RB", "LB", "B" }
  local most = -1e9
  for sub = 0, 240, 16 do
    for byte = -40, 15 do
      for facing = 1, 3 do
        local moving = (byte < 0) and 2 or 1
        local abs = (byte < 0) and -byte or byte
        for g = 1, 2 do
          for _, keys in ipairs(inputs) do
            G.load()
            G.put(byte * 256, facing, moving, abs, false,
                { ground = (g == 1), pixel = G.edge, sub = sub })
            local before = { w = byte * 256, facing = facing, moving = moving,
                             abs = abs, latch = false, ground = (g == 1),
                             timer = 0, prevA = false,
                             pos = G.edge * 256 + sub }
            G.press(keys)
            local after = G.read()
            local problems, said = M.compare(before, keys, after, "one")
            local px = floor(after.pos / 256)
            if px < after.screen then
              problems[#problems + 1] = { "edge", "ended left of the edge" }
            end
            if said.pinned then
              local lift = after.pos - before.pos
              if lift > most then most = lift end
              if lift > 240 then
                problems[#problems + 1] = { "edge", "lifted " .. T.px(lift) }
              end
            end
            if #problems == 0 then R.pass(c) else
              R.fail(c, M.before_text(before, keys) .. ": " .. problems[1][2])
            end
          end
        end
      end
    end
  end
  R.done(c, nil, string.format("largest lift seen %s", T.px(most)))
end

-- === R19. Jumps =============================================================

local function section_jumps()
  local c = R.claim("R19", "Every jump from the start lands cleanly", {
    "Tests: from the start, $0700 set to 0, 10, 20, 26 or 30 (it picks the",
    "jump's strength), A held 1 to 45 frames. Each jump leaves the ground,",
    "lands at y 176 on the ground, and never triggers the side push",
    "(SideCollisionTimer 0, Player_CollisionBits $FF).",
    "Supports: in the 1-1 opening the floor never pushes Mario sideways,",
    "so landings don't move him without speed.",
  })
  local fast = 0
  for _, a0 in ipairs({ 0, 10, 20, 26, 30 }) do
    for hold = 1, 45 do
      G.load()
      wb(A_.abs, a0); wb(A_.prev_ab, 0)
      local t, left, clean = 0, false, true
      repeat
        t = t + 1
        G.press(t <= hold and "A" or "")
        if rb(A_.state) ~= 0 then left = true end
        if rb(A_.side_timer) ~= 0 or rb(A_.collision) ~= 0xFF then
          clean = false
        end
        if s8(rb(A_.y_speed)) >= 5 then fast = fast + 1 end
      until (left and rb(A_.state) == 0) or t > 150
      local ok = left and rb(A_.state) == 0 and rb(A_.y) == 176 and clean
      R.check(c, ok, function()
        return string.format("$0700 %d, A x%d: left the ground %s, landed"
            .. " %s at y %d, side push %s", a0, hold, tostring(left),
            tostring(rb(A_.state) == 0), rb(A_.y), clean and "no" or "yes")
      end)
    end
  end
  R.done(c, nil, string.format("%d frames fell at y speed 5+", fast))
end

-- === R20-R24. Real play =====================================================

local MENU = { "RB", "R", "LR", "LRB", "L", "LB", "B", "", "AR", "ARB", "ALR",
               "ALRB", "A", "DR", "D", "AL", "ALB", "U", "DLR", "S", "RS",
               "UR" }
local TURN = { "LR", "LRB", "ALR", "ALRB", "AR", "ARB", "RB", "R", "B", "" }

-- Each setup returns the input for frame t, or nil once its prefix is
-- done; random inputs follow.
local SETUPS = {
  { name = "the start", menu = MENU,
    init = function() end, next = function() return nil end },
  { name = "the RTA opening", menu = MENU,
    init = function(x) x.n = math.random(3, 30) end,
    next = function(x, t) if t <= x.n then return RTA_LINE[t] end end },
  { name = "a run to the latch", menu = MENU,
    init = function(x) x.n = math.random(0, 12) end,
    next = function(x, t)
      if t <= 33 then return "RB" elseif t <= 33 + x.n then return "" end
    end },
  { name = "a double charge", menu = MENU, init = function() end,
    next = function(_, t) return ({ "LR", "B", "R" })[t] end },
  { name = "a run left to the edge", menu = TURN, init = function() end,
    next = function(_, t)
      if t < 70 and floor(G.pos() / 256) - G.screen() > 2 then return "LB" end
    end },
  { name = "Left+Right into the edge", menu = TURN,
    init = function(x) x.phase = 1 end,
    next = function(x, t)
      if t > 75 then return nil end
      local gap = floor(G.pos() / 256) - G.screen()
      if x.phase == 1 and gap > 3 then return "LB" end
      x.phase = 2
      if gap > 0 then return "LR" end
    end },
  { name = "a fast-accel jump", menu = MENU,
    init = function(x) x.n = math.random(1, 9) end,
    next = function(x, t)
      if t <= 29 then return "RB" elseif t == 30 then return "L"
      elseif t <= 30 + x.n then return "AR" end
    end },
}

-- The burst check (bound2.lua's do_burst_check): one free frame when the
-- speed byte is nonzero.
local BURST = { burst_check = true }

-- Is a speed byte s, after moving `moved` px, within the envelope at k?
local function within(env, s, moved, k)
  return s <= env.byte[k] and moved <= env.dist[k] + 1e-9
end

local function section_play()
  local c_lock = R.claim("R20", "Real play matches the model, frame by frame", {
    "Tests: " .. CFG.play_runs .. " runs of " .. CFG.play_frames
        .. " frames. Each starts with one of " .. #SETUPS .. " setups",
    "(the start, the RTA opening, a run to the latch, a double charge, a",
    "run left to the edge, Left+Right into the edge, a fast-accel jump),",
    "then random inputs held 1-8 frames. Every frame, the model is given",
    "the ROM's state, ground status, RunningTimer and previous A, and must",
    "match the ROM's next speed, facing, moving direction, $0700, latch,",
    "adder and position. Landings, timers and scrolling happen as in the",
    "game, which single written frames can't show.",
    "Supports: the model is right along real lines, not just one frame.",
  })
  local c_set = R.claim("R21", "Every state reached is in the model's set", {
    "Tests: after every frame of R20: SM.in_set() holds (fraction a",
    "multiple of 4; $0700 = |speed byte| unless it's 0; moving direction",
    "= sign; at byte 0, $0700 below 16 unless moving left), and the",
    "subpixel is a multiple of 16.",
    "Supports: the model checks cover every state the game reaches.",
  })
  local c_scope = R.claim("R22", "The screen and the scope stay as the bound"
      .. " assumes", {
    "Tests: after every frame of R20: Mario is never left of the screen's",
    "left edge; the edge never moves left; when it moves right, it moves",
    "no more than Mario did that frame and he ends 64 px or more clear of",
    "it; he stays short of the right-edge clamp (239 px); no wall or floor",
    "pushes him (SideCollisionTimer 0, collision bits $FF); no active",
    "enemy comes within 24 px, and he stays short of the first ? block",
    "(x 256); normal play, small Mario.",
    "Supports: the bound's distance rule (the edge never carries Mario",
    "past where his own moves and one 15/16 px clamp could); the scope.",
  })
  local c_bound, c_burst
  if B then
    c_bound = R.claim("R23", BOUND_NAME .. " holds in real play", {
      "Tests: at every frame j of R20, the bound's own functions read the",
      "game's RAM. For every later frame t within " .. CFG.K .. " frames:",
      "the speed byte at t is within the ramp's after t - j frames, and so",
      "is the distance moved; whenever Mario is at full speed at t, his",
      "projected score is within bound_x_position(j). Speed only (416) at",
      "every j; the latch rule (304) where qualifies_for_slower_ramp() is",
      "true. Also checks the envelope matches the bound's ramp at every j.",
      "Supports: the bound itself, on the ROM, along real lines.",
    })
    if B.has_burst_check then
      c_burst = R.claim("R24", BOUND_NAME .. " holds with its burst check", {
        "Tests: as R23, with do_burst_check: one free frame where the speed",
        "byte is nonzero, and the scores from bound_x_position(j, rule,",
        "true).",
        "Supports: the burst check (FREE_FRAMES_IF_MOVING), on the ROM.",
      })
    else
      c_burst = R.claim("R24", "Candidate: the burst check", {
        "Tests: as R23, with one free frame where the speed byte is nonzero",
        "(bound2.lua's do_burst_check).",
        "Information only; not part of " .. BOUND_NAME .. ".",
      })
      c_burst.info = true
    end
  else
    R.skip("R23", BOUND_NAME .. " holds in real play", "bound file not loaded: "
        .. tostring(bound_err))
    R.skip("R24", "The burst check", "bound file not loaded")
  end

  local K, P = CFG.K, (B and B.SCORING_FRAME or 45)
  local most_right, started = 0, os.time()
  local enemy_gap, max_x = nil, 0
  for run = 1, CFG.play_runs do
    local setup = SETUPS[(run - 1) % #SETUPS + 1]
    local ctx, line, hist = {}, {}, {}
    setup.init(ctx)
    G.load()
    -- At frame j: the envelopes and scores the bound allows from here.
    -- e: speed only (416) and, where it qualifies, the latch rule (304);
    -- b: the same with the burst check.
    local function record(j)
      if not B then return end
      local v, slower = B.get_xvel(), B.qualifies_for_slower_ramp()
      local h = { pos = G.pos(), e416 = H.envelope(B, v, false, K),
                  b416 = H.envelope(B, v, false, K, BURST),
                  score416 = B.bound_x_position(j, false),
                  score304 = B.bound_x_position(j, true) }
      if slower then
        h.e304 = H.envelope(B, v, true, K)
        h.b304 = H.envelope(B, v, true, K, BURST)
      end
      local function check(c, burst, which)
        for _, rule in ipairs({ false, true }) do
          local env = h[which .. (rule and "304" or "416")]
          if env then
            local ok, why = H.matches(B, v, rule, env, burst)
            if not ok then
              R.fail(c, "envelope differs from the bound: " .. why)
            end
          end
        end
      end
      check(c_bound, false, "e")
      if B.has_burst_check then
        check(c_burst, true, "b")
        h.bscore416 = B.bound_x_position(j, false, true)
        h.bscore304 = B.bound_x_position(j, true, true)
      else
        -- A candidate: the score its envelope allows, as M6 relates them.
        local base = h.pos / 256 + (P - j) * B.MAX_SPEED_IN_PX
        h.bscore416 = base + h.b416.offset
        h.bscore304 = h.b304 and base + h.b304.offset or h.bscore416
      end
      hist[j] = h
    end
    record(0)
    local keys, hold, in_prefix = "", 0, true
    for t = 1, CFG.play_frames do
      local pre = in_prefix and setup.next(ctx, t)
      if pre then keys = pre else
        in_prefix = false
        if hold == 0 then
          keys = setup.menu[math.random(#setup.menu)]
          hold = math.random(1, 8)
        end
        hold = hold - 1
      end
      line[t] = keys
      local before = G.read()
      G.press(keys)
      local after = G.read()
      local where = string.format("run %d (from %s), frame %d after %s", run,
          setup.name, t, T.line(line))

      local problems = M.compare(before, keys, after, "play")
      if #problems == 0 then R.pass(c_lock) else
        R.fail(c_lock, where .. ": " .. problems[1][2])
      end

      R.check(c_set, SM.in_set(after.w, after.facing, after.moving, after.abs,
          after.latch) and rb(A_.sub) % 16 == 0, function()
        return where .. ": " .. T.state(after.w, after.facing, after.moving,
            after.abs, after.latch) .. string.format(", subpixel $%02X",
            rb(A_.sub))
      end)

      local x, x0 = floor(after.pos / 256), floor(before.pos / 256)
      local adv = after.screen - before.screen
      if x - after.screen > most_right then most_right = x - after.screen end
      local scope = {}
      if x < after.screen then scope[#scope + 1] = "left of the edge" end
      if adv < 0 then scope[#scope + 1] = "the edge moved left" end
      if adv > 0 and (adv > max(0, x - x0) or x - after.screen < 64) then
        scope[#scope + 1] = string.format("the edge moved %d px (Mario %d),"
            .. " leaving him %d px clear", adv, x - x0, x - after.screen)
      end
      if x - after.screen >= 239 then
        scope[#scope + 1] = "at the right clamp"
      end
      if rb(A_.side_timer) ~= 0 or rb(A_.collision) ~= 0xFF then
        scope[#scope + 1] = "a wall or floor pushed Mario"
      end
      if rb(A_.engine) ~= 8 or rb(A_.oper_mode) ~= 1 or rb(A_.size) ~= 1 then
        scope[#scope + 1] = "left normal play as small Mario"
      end
      if x > max_x then max_x = x end
      if x + 16 > 256 then scope[#scope + 1] = "within reach of the ? block" end
      for slot = 0, 4 do
        if rb(A_.enemy_flag + slot) ~= 0 then
          local gap = math.abs(rb(A_.enemy_page + slot) * 256
              + rb(A_.enemy_x + slot) - x)
          if not enemy_gap or gap < enemy_gap then enemy_gap = gap end
          if gap < 24 then
            scope[#scope + 1] = string.format("an enemy %d px away", gap)
          end
        end
      end
      if #scope == 0 then R.pass(c_scope) else
        R.fail(c_scope, where .. ": " .. table.concat(scope, "; "))
        break
      end

      if B then
        local s = s8(rb(A_.speed))
        local capped = s >= B.MAX_SPEED
        local score = after.pos / 256 + (P - t) * B.MAX_SPEED_IN_PX
        for j = max(0, t - K), t - 1 do
          local h, k = hist[j], t - j
          local moved = (after.pos - h.pos) / 256
          local why = {}
          if not within(h.e416, s, moved, k) then
            why[#why + 1] = string.format("speed only: speed byte %d (limit"
                .. " %d), moved %.4f px (limit %.4f)", s, h.e416.byte[k],
                moved, h.e416.dist[k])
          end
          if h.e304 and not within(h.e304, s, moved, k) then
            why[#why + 1] = string.format("latch rule: speed byte %d (limit"
                .. " %d), moved %.4f px (limit %.4f)", s, h.e304.byte[k],
                moved, h.e304.dist[k])
          end
          if capped and score > h.score416 + 1e-9 then
            why[#why + 1] = string.format("score %.4f above speed-only"
                .. " bound %.4f", score, h.score416)
          end
          if capped and score > h.score304 + 1e-9 then
            why[#why + 1] = string.format("score %.4f above latch-rule"
                .. " bound %.4f", score, h.score304)
          end
          if #why == 0 then R.pass(c_bound) else
            R.fail(c_bound, string.format("%s: from frame %d: %s", where, j,
                table.concat(why, "; ")))
          end
          local bwhy = {}
          if not within(h.b416, s, moved, k)
              or (h.b304 and not within(h.b304, s, moved, k)) then
            bwhy[#bwhy + 1] = string.format("speed byte %d, moved %.4f px",
                s, moved)
          end
          if capped and score > min(h.bscore416, h.bscore304) + 1e-9 then
            bwhy[#bwhy + 1] = string.format("score %.4f above %.4f", score,
                min(h.bscore416, h.bscore304))
          end
          if #bwhy == 0 then R.pass(c_burst) else
            R.fail(c_burst, string.format("%s: from frame %d: %s", where, j,
                table.concat(bwhy, "; ")))
          end
        end
        record(t)
      end
    end
    if os.time() - started >= CFG.progress_seconds then
      started = os.time()
      R.say(string.format("      ... %d of %d runs; mismatches so far:"
          .. " lockstep %d, set %d, scope %d%s", run, CFG.play_runs,
          c_lock.bad, c_set.bad, c_scope.bad, c_bound and (", bound "
          .. c_bound.bad) or ""))
    end
  end
  R.done(c_lock)
  R.done(c_set)
  R.done(c_scope, nil, string.format("farthest right of the edge: %d px;"
      .. " farthest x: %d; closest enemy: %s", most_right, max_x,
      enemy_gap and (enemy_gap .. " px") or "none active"))
  if c_bound then
    R.done(c_bound)
    R.done(c_burst, nil, c_burst.info and "(information only)" or nil)
  end
end

-- The input cases for one frame. On the ground: Left/Right; Down or not; the
-- other-button and RunningTimer cases: nothing (timer 0 or 10), Select (a
-- non-A button that isn't B), or B; A newly pressed or not. In the air:
-- Left/Right only (R17 checks the other buttons don't matter there).
local function input_cases()
  local LRS = { "", "R", "L", "LR" }
  local MIDS = {
    { keys = "", timer = 0 }, { keys = "", timer = 10 },
    { keys = "S", timer = 0 }, { keys = "B", timer = 0 },
  }
  local ground_cases, air_cases = {}, {}
  for _, lr in ipairs(LRS) do
    for _, dn in ipairs({ "", "D" }) do
      for _, mid in ipairs(MIDS) do
        for _, a in ipairs({ "", "A" }) do
          ground_cases[#ground_cases + 1] = { keys = lr .. dn .. mid.keys
              .. a, timer = mid.timer }
        end
      end
    end
    air_cases[#air_cases + 1] = { keys = lr, timer = 0 }
  end
  return ground_cases, air_cases
end

-- === R38. The RAM the model ignores =========================================

local function section_backgrounds(states)
  local ground_cases, air_cases = input_cases()
  local stride = CFG.background_stride
  local n_states = floor((#states - 1) / stride) + 1
  local c = R.claim("R38", "One frame doesn't depend on RAM the model"
      .. " ignores", {
    string.format("Tests: R25's comparison for every %dth state (%d), with",
        stride, n_states),
    "all its input cases, written over three other backgrounds instead of",
    "the start: 37 and 113 frames of standing (other frame counter, timers",
    "and random numbers), and a run right and a stop (screen scrolled,",
    "Mario elsewhere). Each 96 px right of the screen's left edge, with a",
    "random subpixel. The next state, adder, move and jump must match the",
    "model.",
    "Rules out: hidden inputs (the frame counter, timers, random numbers,",
    "the screen position, the subpixel away from the edge).",
    "Supports: R25-R28 use one background and subpixel 0.",
  })
  local bgs = {}
  for _, b in ipairs({ { "37 frames standing", rep("", 37) },
                       { "113 frames standing", rep("", 113) },
                       { "a run right and a stop",
                         cat(rep("RB", 40), rep("", 30)) } }) do
    G.load()
    for _, keys in ipairs(b[2]) do G.press(keys) end
    local save = (savestate.object or savestate.create)()
    savestate.save(save)
    emu.frameadvance()    -- FCEUX writes a Lua savestate at a frame boundary
    bgs[#bgs + 1] = { name = b[1], save = save, screen = G.screen() }
  end
  for i = 1, #states, stride do
    local st = states[i]
    for g = 1, 2 do
      local ground = (g == 1)
      for _, cs in ipairs(ground and ground_cases or air_cases) do
        for _, bg in ipairs(bgs) do
          savestate.load(bg.save)
          local px, sub = bg.screen + 0x60, 16 * math.random(0, 15)
          G.put(st[1], st[2], st[3], st[4], st[5],
              { ground = ground, pixel = px, sub = sub, timer = cs.timer })
          local before = { w = st[1], facing = st[2], moving = st[3],
                           abs = st[4], latch = st[5], ground = ground,
                           timer = cs.timer, prevA = false,
                           pos = px * 256 + sub }
          G.press(cs.keys)
          local problems = M.compare(before, cs.keys, G.read(), "one")
          if #problems == 0 then R.pass(c) else
            R.fail(c, string.format("state %d over %s: %s: %s", i, bg.name,
                M.before_text(before, cs.keys), problems[1][2]))
          end
        end
      end
    end
  end
  R.done(c)
end

-- === R25-R28. Exhaustive one-frame comparison ===============================

local function section_exhaustive(states)
  local ground_cases, air_cases = input_cases()
  local first = CFG.exhaustive_first
  local last = CFG.exhaustive_last or #states
  local stride = CFG.exhaustive_stride
  local n_states = floor((last - first) / stride) + 1
  local per_state = 2 * (#ground_cases + #air_cases)

  local how = {
    string.format("Every state in the model's set (%d; this run checks %d:",
        #states, n_states),
    string.format("states %d to %d, every %d), written into RAM over the",
        first, last, stride),
    "start state; then one frame. On the ground: Left/Right none, R, L,",
    "LR; Down or not; no other button (RunningTimer 0 or 10), Select, or",
    "B; A newly pressed or not (" .. #ground_cases .. " cases). In the air",
    "(y 100, falling): Left/Right none, R, L, LR (" .. #air_cases
        .. " cases; R17 checks the",
    "other buttons don't matter there). Each case at x 96 and on the left",
    "edge: " .. per_state .. " frames per state, " .. per_state * n_states
        .. " in all.",
  }
  local c_state = R.claim("R25", "Every state and input case: the next state"
      .. " matches the model", {
    how[1], how[2], how[3], how[4], how[5], how[6], how[7], how[8],
    "Tests: the ROM's speed and fraction, facing, moving direction, $0700",
    "and latch after the frame equal the model's.",
    "Supports: the model checks (smb1_model_validation.lua) describe the",
    "ROM's one-frame behavior over the whole state set.",
  })
  local c_add = R.claim("R26", "... and the acceleration applied matches", {
    "Tests: on every frame of R25 where the model adds or subtracts, the",
    "ROM's FrictionAdder equals the model's: 152, 208 or 228, doubled",
    "exactly when facing differs from the moving direction.",
    "Supports: 456 is the largest acceleration, and 304 and 416 are the",
    "doubled walking rates, as the bound assumes.",
  })
  local c_move = R.claim("R27", "... and Mario moves by the speed byte only", {
    "Tests: on every frame of R25, Mario's position changes by exactly 16",
    "x the speed byte after acceleration (1/256 px units), whatever the",
    "fraction; on the edge, the clamp sets his pixel to the edge and keeps",
    "the subpixel, exactly when his move ends there or past it.",
    "Supports: the bound counts each frame's move as floor(speed) / 16.",
  })
  local c_jump = R.claim("R28", "... and jumps start on the frame A is"
      .. " pressed", {
    "Tests: on every ground frame of R25, Mario leaves the ground exactly",
    "when A is newly pressed, and that frame already uses the air rules",
    "(R25 compares it with the model's air step); air frames stay in air.",
    "Supports: the model's jump timing (ProcJumping before X_Physics).",
  })
  local claim_of = { state = c_state, adder = c_add, move = c_move,
                     jump = c_jump }
  local started, last_note, done = os.time(), os.time(), 0
  for i = first, last, stride do
    local st = states[i]
    for g = 1, 2 do
      local ground = (g == 1)
      for _, cs in ipairs(ground and ground_cases or air_cases) do
        for _, px in ipairs({ 0x60, G.edge }) do
          G.load()
          G.put(st[1], st[2], st[3], st[4], st[5],
              { ground = ground, pixel = px, timer = cs.timer })
          local before = { w = st[1], facing = st[2], moving = st[3],
                           abs = st[4], latch = st[5], ground = ground,
                           timer = cs.timer, prevA = false, pos = px * 256 }
          G.press(cs.keys)
          local problems = M.compare(before, cs.keys, G.read(), "one")
          local hit = {}
          for _, p in ipairs(problems) do
            if not hit[p[1]] then
              hit[p[1]] = true
              R.fail(claim_of[p[1]], string.format("state %d: %s: %s", i,
                  M.before_text(before, cs.keys), p[2]))
            end
          end
          for kind, cl in pairs(claim_of) do
            if not hit[kind] then R.pass(cl) end
          end
        end
      end
    end
    done = done + 1
    if os.time() - last_note >= CFG.progress_seconds then
      last_note = os.time()
      local el = os.time() - started
      local eta = floor(el / done * (n_states - done))
      R.say(string.format("      ... state %d (%d of %d, %.1f%%), %d frames,"
          .. " mismatches %d/%d/%d/%d, elapsed %d:%02d:%02d, about"
          .. " %d:%02d:%02d to go", i, done, n_states, 100 * done / n_states,
          done * per_state, c_state.bad, c_add.bad, c_move.bad, c_jump.bad,
          floor(el / 3600), floor(el / 60) % 60, el % 60, floor(eta / 3600),
          floor(eta / 60) % 60, eta % 60))
    end
  end
  local note = string.format("states %d-%d every %d", first, last, stride)
  R.done(c_state, nil, note)
  R.done(c_add)
  R.done(c_move)
  R.done(c_jump)
end

-- === Run ====================================================================

R.say("SMB1 ROM validation for the acceleration bound")
R.say("Date: " .. os.date("%Y-%m-%d %H:%M"))
R.say("Files tested (Adler-32 of each file's text, line endings ignored):")
for _, f in ipairs({ "smb1_rom_validation.lua", "smbmodel.lua",
                     "bound_harness.lua", CFG.bound_file }) do
  R.say(string.format("  %s  %s", checksum(here .. f), here .. f))
end
if not B then R.say("Bound NOT LOADED: " .. tostring(bound_err)) end
local s = {}
for _, name in ipairs({ "setup", "witnesses", "gotchas", "buttons", "edge",
                        "jumps", "play", "backgrounds", "exhaustive" }) do
  if CFG.sections[name] then s[#s + 1] = name end
end
R.say("Sections: " .. table.concat(s, ", ") .. string.format("; exhaustive"
    .. " stride %d; seed %d", CFG.exhaustive_stride, CFG.seed))

local ok, why = G.reach_start()
if not ok then
  R.say("Could not reach the start of 1-1: " .. why)
  return
end
local states = SM.states()
if CFG.sections.setup then section_setup() end
if CFG.sections.witnesses then section_witnesses() end
if CFG.sections.gotchas then section_gotchas() end
if CFG.sections.buttons then section_buttons(states) end
if CFG.sections.edge then section_edge() end
if CFG.sections.jumps then section_jumps() end
if CFG.sections.play then section_play() end
if CFG.sections.backgrounds then section_backgrounds(states) end
if CFG.sections.exhaustive then section_exhaustive(states) end

R.say("")
R.say("Summary")
local all = true
for _, c in ipairs(R.list) do
  R.say(string.format("  %-4s %-10s %s", c.id, c.status or "?", c.title))
  if c.status == "FAIL" and not c.info then all = false end
end
R.say(all and "NO CLAIM FAILED (NOT RUN and NOT SHOWN are not failures;"
    .. " information-only claims say so)" or "SOME CLAIMS FAILED")
if R.out then R.out:close() end
