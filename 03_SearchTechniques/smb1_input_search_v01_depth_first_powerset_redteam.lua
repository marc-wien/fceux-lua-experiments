--
-- === SMB1 Acceleration-Bound Red Team: Search From Fixed Setups ===
-- Variant: savestates, RAM dedup, power-set inputs, setups aimed at each
-- part of the bound
--
-- The input searches prune with an acceleration bound whose parts each come
-- from a finding about the game's code: ramping from max(v, 0), two free
-- frames, 416 below speed 25, the 15/16 px edge term, and for the RAM rule,
-- 304 where slow_rate() allows it. A plain search rarely reaches the states
-- those findings are about, so this script goes there on purpose. Each
-- setup plays a fixed line from the 1-1 start into one mechanism, then
-- searches every input for a few frames after it. Every state on the way is
-- checked against the ramp from every earlier state: does any line beat it?
--
-- Each setup also carries a control: the bound with the part that setup
-- targets taken out. Beating the control shows the setup really reached the
-- mechanism; a setup that never beats its control proves nothing.
--
-- The search after each setup is exhaustive, not sampled. A branch is
-- dropped only when even the top rate every frame (456, the flat bound)
-- could not carry any line past a ramp from the setup's states within the
-- window. Dedup is exact here for the same reason: that question depends
-- only on the state, not on the path to it.
--
-- To understand the method, read in this order:
--   Ramps            what a ramp claims, the ramps under test, the controls
--   Setups           the fixed lines, and what each is aimed at
--   Search           play a setup, check it, then search the window after it
--   Checks           the comparison made at every state
-- Settings through Measurement, Score and bound, Frontier and Step are the
-- same as in the search scripts; Score and bound is the code under test.
--
-- Setup: with ALLOW_LR on (the default here), enable "Allow Left+Right /
-- Up+Down" in FCEUX's input settings first. Load FCS savestate file with
-- emulator paused, then run this, then unpause. Every setup starts from that
-- state, which must be the 1-1 start.
--

-- === Settings ===============================================================

-- Search
local PROJECTION_FRAME = 45   -- used only by score(), so that Score and bound
                              -- stays the same as in the search scripts
local ALLOW_LR = true         -- allow Left+Right pressed together. Setups
                              -- C and F need it; without it they are skipped
local ALLOW_UD = false        -- allow Up+Down pressed together
local RUN = "ALL"             -- one setup's letter, or "ALL"
local MAX_NODES = 5000000     -- nodes searched after any one setup line.
                              -- Past it, that search is reported as not
                              -- exhaustive

-- Memory
local GC_EVERY = 100000       -- savestates created between full collections;
                              -- lower it if memory climbs on long runs. With a
                              -- big dedup table this also matters: left alone,
                              -- Lua waits for memory to double before it
                              -- collects, which here could mean gigabytes of
                              -- garbage. Do not raise it much.
local MAX_SEEN = 11000000     -- states remembered for dedup in one window,
                              -- about 2.15 KB each (~24 GB at the cap): sized
                              -- for a 32 GB machine with little else running.
                              -- Hitting it only stops dedup from growing.
                              -- Lower it if memory nears the limit.

-- Reporting
local PROGRESS_EVERY = 100000 -- nodes between console progress lines
local SHOW_FIRST = 3          -- beating lines printed per ramp per setup

-- === Game constants =========================================================

local MAX_SPEED = 40          -- x speed cap while running, in 1/16 px/frame
local PX_PER_FRAME_AT_CAP = MAX_SPEED / 16

-- Fastest acceleration the game allows, in speed units per frame. Each is
-- a FrictionData entry, doubled when facing ~= moving direction.
local ACCEL_RUN  = 456 / 256  -- $E4 x2: running, or airborne at 25+
local ACCEL_SLOW = 416 / 256  -- $D0 x2: below 25, RunningSpeed latch set
local ACCEL_SWITCH = 25       -- speed where the top rate opens up
local FREE_FRAMES = 2         -- top-rate bursts a state can hold in reserve
local EDGE_PX = 15 / 16       -- most the left screen edge can lift Mario

-- === Anchor =================================================================

-- A Lua savestate is not committed until a frame boundary passes: saving and
-- reading straight back returns the PREVIOUS state. Advance once to commit;
-- the load discards that frame.
local anchor = savestate.create()
savestate.save(anchor)
emu.frameadvance()
savestate.load(anchor)

emu.speedmode("nothrottle")   -- all non-"normal" modes behave the same here

-- === Inputs =================================================================

-- Every combination of the six gameplay buttons; select and start are left
-- out. An original pad cannot press opposite directions together, so RTA
-- rules exclude them unless the settings above allow them.
--
-- Symbols name the buttons held, in the order U D L R B A; "-" is no input.
-- They are built in the order they should be TRIED at each depth, plainest
-- first, then reversed, because the stack pops the last symbol pushed. Two
-- things follow. The opening dive is "just run right" (RB), which reaches the
-- cap and forms the first incumbent. And since dedup keeps whichever twin is
-- found first, a result uses an unusual input only where no plainer choice
-- would have reached the same state.
local ALPHABET = {}
do
    local try_first = {}
    for _, v in ipairs{ "", "D", "U", "UD" } do
        for _, h in ipairs{ "R", "", "L", "LR" } do
            for _, b in ipairs{ "B", "" } do
                for _, a in ipairs{ "", "A" } do
                    if (ALLOW_UD or v ~= "UD") and (ALLOW_LR or h ~= "LR") then
                        local name = v .. h .. b .. a
                        try_first[#try_first + 1] = name ~= "" and name or "-"
                    end
                end
            end
        end
    end
    for i = #try_first, 1, -1 do ALPHABET[#ALPHABET + 1] = try_first[i] end
end

-- Every button must be set true OR false: an omitted button means "leave it
-- to the user", not "released".
local BUTTONS = { "up", "down", "left", "right", "A", "B", "select", "start" }

local function make_input(held)
    local t = {}
    for _, b in ipairs(BUTTONS) do t[b] = false end
    for _, b in ipairs(held) do t[b] = true end
    return t
end

local BUTTON_OF = { U = "up", D = "down", L = "left", R = "right",
                    B = "B", A = "A" }

local INPUT = {}
for _, name in ipairs(ALPHABET) do
    local held = {}
    for letter in name:gmatch("%u") do held[#held + 1] = BUTTON_OF[letter] end
    INPUT[name] = make_input(held)
end

-- === Measurement ============================================================

-- x_vel is the exact speed byte, used to detect the cap. x_vel_ub adds the
-- 0x0705 fraction, giving the full 16-bit speed. Mario moves by the byte
-- alone, so x_vel_ub is never below the speed that moves him -- the bound
-- must never understate a branch.
local function measure()
    local x_pos = memory.readbyte(0x006D) * 256      -- page
                + memory.readbyte(0x0086)            -- pixel
                + memory.readbyte(0x0400) / 256      -- subpixel
    local x_vel = memory.readbytesigned(0x0057)
    local x_vel_ub = x_vel + memory.readbyte(0x0705) / 256
    return x_pos, x_vel, x_vel_ub
end

-- === Score and bound ========================================================

-- Projected x-position at PROJECTION_FRAME, running at cap speed from `frame`.
-- Exact for a sequence already at cap; the horizon shifts every score equally.
local function score(x_pos, frame)
    return x_pos + (PROJECTION_FRAME - frame) * PX_PER_FRAME_AT_CAP
end

-- Best-case ramp to cap from speed v: accelerate, then move, each frame.
--   max(v, 0): the game can zero a negative speed at once (skid reset,
--     screen edge), and no negative speed beats 0.
--   FREE_FRAMES: a state can hold two bursts in reserve (double charge),
--     so the first two frames get the top rate at any speed.
--   EDGE_PX: the left edge can lift Mario up to 15/16 px with no speed,
--     so the first move counts at least that much.
local function ramp_to_cap(v, accel_slow)
    v = math.max(v, 0)
    local frames, dist = 0, 0
    while v < MAX_SPEED do
        frames = frames + 1
        local top = frames <= FREE_FRAMES or v >= ACCEL_SWITCH
        v = math.min(v + (top and ACCEL_RUN or accel_slow), MAX_SPEED)
        dist = dist + (frames == 1 and math.max(v / 16, EDGE_PX) or v / 16)
    end
    return frames, dist
end

-- Upper bound on the score any continuation of this state can reach. If it
-- cannot beat the incumbent, nothing below this node can either.
local function bound(x_pos, x_vel_ub, frame, accel_slow)
    if x_vel_ub >= MAX_SPEED then return score(x_pos, frame) end
    local frames, dist = ramp_to_cap(x_vel_ub, accel_slow or ACCEL_SLOW)
    return score(x_pos + dist, frame + frames)
end

-- The RAM rule: read RAM to use 304 below 25. 416 needs the
-- RunningSpeed latch, which only sets at |speed| >= 28. Moving right, the
-- ramp is at the top rate by then; moving left, a run into the screen edge
-- can latch it at speed 0 -- hence the speed >= 0 test. Checked in two
-- models and against the ROM in random play.
local ACCEL_WALK = 304 / 256  -- $98 x2: below 25, latch clear
local function slow_rate()
    local latch_clear = memory.readbyte(0x0703) == 0     -- RunningSpeed
    local abs_low = memory.readbyte(0x0700) < 25         -- can be stale
    local not_left = memory.readbytesigned(0x0057) >= 0
    return (latch_clear and abs_low and not_left) and ACCEL_WALK or ACCEL_SLOW
end

-- === Ramps ==================================================================

-- A ramp is the best case from one state: Mario's speed and distance after
-- each of the next k frames. The bound claims no line from that state ever
-- beats it: k frames on, the speed byte is at most the ramp's speed rounded
-- down, and Mario has moved at most the ramp's distance. Distance alone is
-- not enough: a line that capped sooner than the ramp would gain 2.5 px a
-- frame on it from then on, which the speed check catches. The full 16-bit
-- speed is compared too; the bound's own argument claims that as well, and
-- it is the only check the double charge can beat.
--
-- Under test, built as ramp_to_cap builds them:
--   top     456 every frame: the flat bound. The pruning below relies on it
--   slow    416 below 25 after two free frames: the speed-only bound
--   walk    304 below 25: the RAM rule, from states where slow_rate() gives
--           304
-- Controls, each the bound with one part taken out, and what beats it:
--   raw     ramps from the raw speed, not max(v, 0)       skid reset
--   free0   no free frames                                one-frame burst
--   free1   one free frame                                double charge
--   noedge  no 15/16 px edge term                         screen-edge pin
--   latch   304 below 25 everywhere, latch or not         RunningSpeed latch
--   nosign  the RAM rule without its speed >= 0 test      left-edge trap
local RAMPS = {
    { name = "top",    slow = ACCEL_RUN,  free = FREE_FRAMES, edge = EDGE_PX,
      tested = true },
    { name = "slow",   slow = ACCEL_SLOW, free = FREE_FRAMES, edge = EDGE_PX,
      tested = true },
    { name = "walk",   slow = ACCEL_WALK, free = FREE_FRAMES, edge = EDGE_PX,
      tested = true, where = "rule" },
    { name = "raw",    slow = ACCEL_SLOW, free = FREE_FRAMES, edge = EDGE_PX,
      raw = true },
    { name = "free0",  slow = ACCEL_SLOW, free = 0,           edge = EDGE_PX },
    { name = "free1",  slow = ACCEL_SLOW, free = 1,           edge = EDGE_PX },
    { name = "noedge", slow = ACCEL_SLOW, free = FREE_FRAMES, edge = 0 },
    { name = "latch",  slow = ACCEL_WALK, free = FREE_FRAMES, edge = EDGE_PX },
    { name = "nosign", slow = ACCEL_WALK, free = FREE_FRAMES, edge = EDGE_PX,
      where = "nosign" },
}
local RAMP = {}
for _, spec in ipairs(RAMPS) do RAMP[spec.name] = spec end

-- The ramp's speed and distance after each of k = 1..frames frames, as
-- ramp_to_cap computes them; past the cap, 2.5 px per frame.
local function ramp_table(v, spec, frames)
    if not spec.raw then v = math.max(v, 0) end
    local speed, dist, d = {}, {}, 0
    for f = 1, frames do
        if v < MAX_SPEED then
            local top = f <= spec.free or v >= ACCEL_SWITCH
            v = math.min(v + (top and ACCEL_RUN or spec.slow), MAX_SPEED)
            d = d + (f == 1 and math.max(v / 16, spec.edge) or v / 16)
        else
            d = d + PX_PER_FRAME_AT_CAP
        end
        speed[f], dist[f] = v, d
    end
    return { speed = speed, dist = dist }
end

-- The checks must test the bound the searches use. Before anything runs,
-- confirm that each ramp under test caps on the same frame as ramp_to_cap,
-- having moved the same distance, at every speed in steps of 1/16.
for i = -41 * 16, MAX_SPEED * 16 - 1 do
    local v = i / 16
    for _, spec in ipairs(RAMPS) do
        if spec.tested then
            local frames, dist = ramp_to_cap(v, spec.slow)
            local r = ramp_table(v, spec, frames)
            assert(r.speed[frames] == MAX_SPEED
                and (frames == 1 or r.speed[frames - 1] < MAX_SPEED)
                and math.abs(r.dist[frames] - dist) < 1e-9,
                "ramp_table disagrees with ramp_to_cap at speed " .. v)
        end
    end
end

-- Whether a ramp applies from the state the emulator holds now. The RAM
-- rule's ramps exist only where it would give 304: "rule" is slow_rate()
-- itself, "nosign" the same test without speed >= 0.
local function applies(spec)
    if spec.where == "rule" then return slow_rate() == ACCEL_WALK end
    if spec.where == "nosign" then
        return memory.readbyte(0x0703) == 0 and memory.readbyte(0x0700) < 25
    end
    return true
end

-- === Setups =================================================================

-- Each setup is a fixed line from the 1-1 start, or a family of nearby
-- lines in case the ROM's timing differs from the model's by a frame; a
-- window of frames searched after it; and the control it should beat. The
-- lines come from the bound's write-up, the earlier red-team experiments and
-- run 4's model. The pivot is the state at the end of a line, and `pivot`
-- says what it should look like, as a check that the line did its job.
--
-- Only setup states anchor the pruning (see may_beat), so a line has to end
-- just before the frame that does the damage: the window finds that frame,
-- but cannot rely on a state it reaches itself.
local function rep(sym, n, line)
    line = line or {}
    for _ = 1, n do line[#line + 1] = sym end
    return line
end

local function join(...)
    local line = {}
    for _, part in ipairs({ ... }) do
        for _, sym in ipairs(part) do line[#line + 1] = sym end
    end
    return line
end

local rb = memory.readbyte
local function speed_byte() return memory.readbytesigned(0x0057) end

local SETUPS = {
    -- A skid reset: a grounded frame holding a non-A button whose Left/Right
    -- differs from the moving direction zeroes a speed byte of -1 to -10.
    -- From -9.2, speed jumps to 0 in one frame: ramps must start at max(v, 0).
    { id = "A", name = "skid reset", control = "raw", window = 3,
      lines = { rep("LB", 10) },
      pivot = function()
          local s = speed_byte()
          return s >= -10 and s <= -1, "speed byte -1 to -10"
      end },

    -- B one-frame burst: facing away from the moving direction, pressing it
    -- with B runs doubled, 456, at any speed below 25. Run right, turn to
    -- face left for one frame, and let the search find the burst.
    { id = "B", name = "one-frame burst", control = "free0", window = 2,
      lines = {},
      pivot = function()
          local s = speed_byte()
          return rb(0x0033) == 2 and rb(0x0045) == 1 and s > 0 and s < 25,
              "facing left, moving right, speed byte 1 to 24"
      end },

    -- C double charge: after Left+Right then B, the moving direction can be
    -- 3, and stays 3 while the speed byte is 0. Then Left+Right+B and Right+B
    -- are both doubled: two 456 frames in a row, the reason for two free
    -- frames. The gain shows in the 16-bit speed (4.156 against 4.000).
    { id = "C", name = "double charge", control = "free1", window = 3,
      lines = { { "LR", "B", "R" } },
      pivot = function()
          return rb(0x0045) == 3 and speed_byte() == 0,
              "moving direction 3, speed byte 0"
      end },

    -- D RunningSpeed latch: reaching 28 on the ground sets the latch, which
    -- keeps the slow branch at 208, 416 doubled, below 25. Latch, skid back
    -- to 11, then let the search find Left+Right at 416.
    { id = "D", name = "RunningSpeed latch", control = "latch", window = 6,
      lines = { join(rep("RB", 33), rep("L", 12)) },
      pivot = function()
          local s = speed_byte()
          return rb(0x0703) ~= 0 and s >= 11 and s < 25,
              "latch set, speed byte 11 to 24"
      end },

    -- E screen edge: at the left edge the game resets x to the edge's whole
    -- pixel but keeps the subpixel, so a step left from that whole pixel
    -- ends 15/16 px ahead. Held Left creeps along the pinned pixel 1/16 px at
    -- a time; the lines stop at each point of the creep, and the search
    -- finds the step that crosses the pixel.
    { id = "E", name = "screen-edge pin", control = "noedge", window = 2,
      lines = {},
      pivot = function()
          return rb(0x006D) == 0 and rb(0x0086) == 0,
              "pinned at the left edge (pixel 0)"
      end },

    -- F left-edge trap: walk left at the walking cap so the latch stays
    -- clear, turn right for a frame near the edge, then run left so |speed|
    -- first reaches 28 on the frame the edge pins Mario. That leaves $0700
    -- at 28 with speed 0; Left+Right then sets the latch, and a jump holding
    -- Right gains 416 a frame. Without its speed >= 0 test, the RAM rule
    -- would allow only 304 from the turn. Run 4's model found the line;
    -- nearby timings are tried in case the ROM differs by a frame, as in
    -- smb_ram_rule_check.lua.
    { id = "F", name = "left-edge trap", control = "nosign", window = 0,
      lines = {} },

    -- G the RTA best line (103.813 at frame 34, best-first and depth-first
    -- proofs): no mechanism aimed at, no control. Every ramp under test must
    -- hold along it.
    { id = "G", name = "RTA best line", window = 0,
      lines = { join({ "LB", "B", "RBA" }, rep("RB", 22), { "LB", "RBA" },
                     rep("RB", 7)) } },
}

-- The families: B turns after every run-up from 18 to 26 frames, E stops at
-- every point of the creep along the pinned pixel, and F tries the timings
-- smb_ram_rule_check.lua tries.
do
    local burst, edge, trap = SETUPS[2], SETUPS[5], SETUPS[6]
    for n = 18, 26 do
        burst.lines[#burst.lines + 1] = join(rep("RB", n), { "LB" })
    end
    for n = 60, 75 do edge.lines[#edge.lines + 1] = rep("L", n) end
    for b = 30, 45 do for a = 0, 2 do for c = 0, 3 do for e = 2, 5 do
        trap.lines[#trap.lines + 1] = join(rep("LB", a), rep("L", b),
            rep("LB", c), { "R" }, rep("LB", e), { "LR" }, rep("RA", 24))
    end end end end
end

-- === Frontier ===============================================================

-- The order in which nodes leave the frontier decides how the tree is walked.
-- A stack (last in, first out) walks it depth-first. Push and pop are kept as
-- their own functions so a later best-first demo has one obvious place to
-- change how nodes are ordered.
local function push_node(frontier, node)
    frontier[#frontier + 1] = node
end

local function pop_next(frontier)
    local n = #frontier
    if n == 0 then return nil end
    local node = frontier[n]
    frontier[n] = nil
    return node
end

-- Each child gets its own copy of its parent's input string, then one more
-- symbol. (Lua 5.1 has no table.unpack.)
local function copy_seq(seq)
    local c = {}
    for i = 1, #seq do c[i] = seq[i] end
    return c
end

-- === Step ===================================================================

-- Saves the current state for this node's children. Like the anchor, it must
-- be committed by a frame boundary before anything loads it, so advance one
-- frame; every later load discards it.
local saves = 0

local function save_state()
    local state = savestate.create()
    savestate.save(state)
    emu.frameadvance()
    saves = saves + 1
    -- Savestates may hold emulator snapshots outside the Lua heap, where the
    -- collector does not count them, so collect now and then on long runs.
    if saves % GC_EVERY == 0 then collectgarbage() end
    return state
end

-- Loads the state this node's parent left behind and plays only the node's
-- own input: one frame, however deep the node is.
local function step(node)
    savestate.load(node.from)
    joypad.set(1, INPUT[node.seq[#node.seq]])
    emu.frameadvance()
    return measure()
end

-- Plays a setup line and then a searched string from the anchor. Used only
-- to confirm a failure: it depends on no saved state except the anchor.
local function replay(line, seq)
    savestate.load(anchor)
    for _, sym in ipairs(line) do
        joypad.set(1, INPUT[sym])
        emu.frameadvance()
    end
    for _, sym in ipairs(seq) do
        joypad.set(1, INPUT[sym])
        emu.frameadvance()
    end
    return measure()
end

-- === Dedup ==================================================================

-- Two nodes at the same frame with identical RAM are the same game state.
-- Here that makes the skip exact, not just safe: whether a line can still
-- beat a ramp from the setup's states depends only on the state, so a twin's
-- subtree holds nothing its first copy's did not. (Ramps from states inside
-- the window are checked too, as extra coverage, and those checks a twin
-- does skip.) Like the search scripts, this assumes SMB1's future depends
-- only on its 2 KB of RAM at a frame boundary. The table starts empty for
-- each window.
local seen, seen_count = {}, 0

local function forget_seen()
    seen, seen_count = {}, 0
end

-- True if an identical state was already expanded in this window;
-- otherwise remembers this one, which is about to be.
local function explored_before(depth)
    local key = depth .. ":" .. memory.readbyterange(0, 0x800)
    if seen[key] then return true end
    if seen_count < MAX_SEEN then
        seen[key] = true
        seen_count = seen_count + 1
    end
    return false
end

-- === Diagnostics ============================================================
-- Reporting only. Nothing here writes to search state.

-- "RB x33, L x12": a line in runs, for headers.
local function runs_text(line)
    local parts, i = {}, 1
    while i <= #line do
        local j = i
        while j < #line and line[j + 1] == line[i] do j = j + 1 end
        parts[#parts + 1] = (j > i) and string.format("%s x%d", line[i],
            j - i + 1) or line[i]
        i = j + 1
    end
    return table.concat(parts, ", ")
end

-- A full input string: the setup line, then "|", then what was searched.
local function inputs_text(line, upto, seq)
    local text = table.concat(line, ",", 1, upto)
    if seq and #seq > 0 then text = text .. " | " .. table.concat(seq, ",") end
    return text
end

local function report_start()
    local x_pos, x_vel = measure()
    emu.print(string.format("Red team: fixed setups, power set%s%s, %d symbols",
        ALLOW_LR and "" or ", no L+R", ALLOW_UD and "" or ", no U+D",
        #ALPHABET))
    emu.print(string.format("anchor: x_pos=%.4f speed=%d  (1-1 start is"
        .. " 40.0000, 0)", x_pos, x_vel))
end

local function report_setup_start(setup)
    local what = #setup.lines == 1
        and string.format("%s (%d frames)", runs_text(setup.lines[1]),
            #setup.lines[1])
        or string.format("%d lines", #setup.lines)
    emu.print(string.format("== %s %s: %s, then %d searched%s", setup.id,
        setup.name, what, setup.window,
        setup.control and (" | control: " .. setup.control) or ""))
end

local function report_skipped(setup, sym)
    emu.print(string.format("== %s %s: skipped, it needs %s, which this"
        .. " alphabet lacks (ALLOW_LR?)", setup.id, setup.name, sym))
end

local function report_pivot(ok, what, depth, x_pos, x_vel_ub)
    emu.print(string.format("  pivot @%d: x %.3f, speed %.3f, latch %d,"
        .. " $0700 %d, facing %d, moving %d -- %s (%s)", depth, x_pos,
        x_vel_ub, memory.readbyte(0x0703), memory.readbyte(0x0700),
        memory.readbyte(0x0033), memory.readbyte(0x0045),
        ok and "as expected" or "NOT AS EXPECTED", what))
end

-- A line beat a ramp. Printed in full the first SHOW_FIRST times per ramp
-- per setup. "@12 +5" means 5 frames after the state at frame 12.
local function report_beat(tally, spec, what, from, k, got, limit, text)
    local shown = tally.shown[spec.name] or 0
    if shown >= SHOW_FIRST then return end
    tally.shown[spec.name] = shown + 1
    emu.print(string.format("  %s %s %s: @%d +%d: %.4f > %.4f | %s",
        spec.tested and "FAIL" or "beat", spec.name, what, from, k, got,
        limit, text))
end

local function report_progress(setup, nodes, tally, frontier)
    emu.print(string.format("  (%.1fM) %s | frnt:%d, prun:%.1fM, dup:%.1fM,"
        .. " chk:%.1fM", nodes / 1000000, setup.id, #frontier,
        tally.pruned / 1000000, tally.dupes / 1000000,
        tally.checks / 1000000))
end

-- Margin: how far short of a ramp's distance the closest line stayed.
local function margin_text(m)
    return m == math.huge and "-" or string.format("%.3f", m)
end

-- Returns whether the setup reached its control (nil if it has none).
local function report_setup_done(setup, tally)
    emu.print(string.format("  lines %d, nodes %d (%s), prun %d, dup %d,"
        .. " out of scope %d, checks %d", #setup.lines, tally.nodes,
        tally.exhaustive and "exhaustive" or "NOT exhaustive: MAX_NODES",
        tally.pruned, tally.dupes, tally.out_of_scope, tally.checks))
    if tally.pivots > 1 then
        emu.print(string.format("  pivots as expected: %d of %d (%s)",
            tally.pivots_ok, tally.pivots, select(2, setup.pivot())))
    end
    local parts = {}
    for _, spec in ipairs(RAMPS) do
        if spec.tested then
            parts[#parts + 1] = string.format("%s %d (16-bit %d, margin %s)",
                spec.name, tally.fails[spec.name] or 0,
                tally.fails16[spec.name] or 0,
                margin_text(tally.margin[spec.name] or math.huge))
        end
    end
    emu.print("  under test, fails: " .. table.concat(parts, ", "))
    if not setup.control then return nil end
    local beats = tally.beats[setup.control] or 0
    emu.print(string.format("  control %s: beaten %d times -- %s",
        setup.control, beats, beats > 0 and "REACHED"
        or "NOT REACHED: this setup proves nothing"))
    return beats > 0
end

local function report_summary(totals)
    emu.print(string.format("== all: %d setups, %d checks; under test %d"
        .. " fails (16-bit speed: %d); controls reached %d of %d",
        totals.setups, totals.checks, totals.fails, totals.fails16,
        totals.reached, totals.aimed))
    if totals.fails > 0 then
        emu.print("FAIL: a line beat a ramp under test (lines above)")
    elseif totals.reached < totals.aimed then
        emu.print("INCONCLUSIVE: some setup never reached its control")
    else
        emu.print("PASS" .. (totals.fails16 > 0 and " on speed byte and"
            .. " distance; the 16-bit speed claim was beaten (lines above)"
            or ""))
    end
end

-- === Checks =================================================================

-- The 1-1 opening the bound is scoped to: no wall push, normal play, small
-- Mario. Labels as in SMBDIS.ASM.
local function in_scope()
    return rb(0x0785) == 0                    -- SideCollisionTimer
       and rb(0x0490) == 0xFF                 -- Player_CollisionBits
       and rb(0x000E) == 8                    -- GameEngineSubroutine
       and rb(0x0754) == 1                    -- PlayerSize: small
end

-- One state's position and the ramps from its speed that apply there, out
-- to `frames` frames. Built while the emulator holds that state, since
-- applies() reads RAM.
local function make_record(depth, x_pos, x_vel_ub, frames)
    local rec = { depth = depth, x = x_pos, ramps = {} }
    for _, spec in ipairs(RAMPS) do
        if applies(spec) then
            rec.ramps[spec.name] = ramp_table(x_vel_ub, spec, frames)
        end
    end
    return rec
end

local function new_tally()
    return { checks = 0, nodes = 0, pruned = 0, dupes = 0, out_of_scope = 0,
             pivots = 0, pivots_ok = 0, exhaustive = true, fails = {},
             fails16 = {}, beats = {}, margin = {}, shown = {} }
end

-- Compares the state at `depth` with one earlier record, for every ramp it
-- holds. Returns true if a ramp under test was beaten on speed byte or
-- distance.
local function check_one(tally, rec, depth, x_pos, x_vel, x_vel_ub, text)
    local k = depth - rec.depth
    local moved = x_pos - rec.x
    local speed16 = math.min(x_vel_ub, MAX_SPEED)  -- the byte is capped at
                                                   -- 40; its fraction is not
    local failed = false
    for _, spec in ipairs(RAMPS) do
        local r = rec.ramps[spec.name]
        if r then
            tally.checks = tally.checks + 1
            local lim_s, lim_d = math.floor(r.speed[k]), r.dist[k]
            local what, got, limit
            if x_vel > lim_s then
                what, got, limit = "speed byte", x_vel, lim_s
            elseif moved > lim_d then
                what, got, limit = "distance", moved, lim_d
            elseif speed16 > r.speed[k] then
                what, got, limit = "16-bit speed", speed16, r.speed[k]
            end
            if spec.tested then
                local m = lim_d - moved
                if m < (tally.margin[spec.name] or math.huge) then
                    tally.margin[spec.name] = m
                end
            end
            if what then
                local count = spec.tested and (what == "16-bit speed"
                    and tally.fails16 or tally.fails) or tally.beats
                count[spec.name] = (count[spec.name] or 0) + 1
                report_beat(tally, spec, what, rec.depth, k, got, limit,
                    text())
                if spec.tested and what ~= "16-bit speed" then
                    failed = true
                end
            end
        end
    end
    return failed
end

-- Compares a state with every setup state and every searched ancestor.
local function check_state(tally, recs, up, depth, x_pos, x_vel, x_vel_ub,
                           text)
    local failed = false
    for _, rec in ipairs(recs) do
        if check_one(tally, rec, depth, x_pos, x_vel, x_vel_ub, text) then
            failed = true
        end
    end
    while up do
        if check_one(tally, up, depth, x_pos, x_vel, x_vel_ub, text) then
            failed = true
        end
        up = up.up
    end
    return failed
end

-- Could any line from this state still beat one of the named ramps from a
-- setup state within `left` frames? The top rate from here bounds every
-- such line (the flat bound, checked in the model), so if even it stays
-- inside each ramp, nothing below this node can beat one.
local function may_beat(recs, names, depth, x_pos, x_vel_ub, left)
    local top = ramp_table(x_vel_ub, RAMP.top, left)
    for _, rec in ipairs(recs) do
        local k = depth - rec.depth
        for _, name in ipairs(names) do
            local r = rec.ramps[name]
            if r then
                for j = 1, left do
                    if top.speed[j] > r.speed[k + j]
                       or x_pos + top.dist[j] > rec.x + r.dist[k + j] then
                        return true
                    end
                end
            end
        end
    end
    return false
end

-- A failure of a ramp under test is only believed once a replay from the
-- anchor reproduces the state; a mismatch means a savestate drifted.
local function confirm(line, seq, x_pos, x_vel)
    local rx_pos, rx_vel = replay(line, seq)
    if rx_pos ~= x_pos or rx_vel ~= x_vel then
        error(string.format("savestate drift at %s: %.4f, %d by savestate"
            .. " but %.4f, %d by replay", inputs_text(line, #line, seq),
            x_pos, x_vel, rx_pos, rx_vel))
    end
    emu.print("    (confirmed by replay from the anchor)")
end

-- === Search =================================================================

-- Plays one setup line from the anchor, checking each state against every
-- earlier one, then searches every input for `window` frames after it.
local function run_line(setup, line, tally, show_pivot)
    savestate.load(anchor)
    local frames = #line + setup.window
    local x_pos, x_vel, x_vel_ub = measure()
    local recs = { make_record(0, x_pos, x_vel_ub, frames) }
    for t = 1, #line do
        joypad.set(1, INPUT[line[t]])
        emu.frameadvance()
        x_pos, x_vel, x_vel_ub = measure()
        if not in_scope() then
            tally.out_of_scope = tally.out_of_scope + 1
            return
        end
        local text = function() return inputs_text(line, t) end
        if check_state(tally, recs, nil, t, x_pos, x_vel, x_vel_ub, text) then
            local played = {}
            for i = 1, t do played[i] = line[i] end
            confirm(played, {}, x_pos, x_vel)
            return                    -- replay moved the emulator on
        end
        recs[#recs + 1] = make_record(t, x_pos, x_vel_ub, frames - t)
    end
    if setup.pivot then
        local ok, what = setup.pivot()
        tally.pivots = tally.pivots + 1
        if ok then tally.pivots_ok = tally.pivots_ok + 1 end
        if show_pivot then report_pivot(ok, what, #line, x_pos, x_vel_ub) end
    end
    if setup.window == 0 then return end

    -- The window: depth-first over every input, dropping a branch once no
    -- line below it could beat a ramp under test, or the control, from any
    -- setup state.
    local names = { setup.control }
    for _, spec in ipairs(RAMPS) do
        if spec.tested then names[#names + 1] = spec.name end
    end
    forget_seen()
    local root = save_state()
    local frontier = {}
    for _, sym in ipairs(ALPHABET) do
        push_node(frontier, { seq = { sym }, depth = #line + 1, from = root })
    end
    local nodes = 0
    while true do
        local node = pop_next(frontier)
        if node == nil then break end
        if nodes >= MAX_NODES then
            tally.exhaustive = false
            break
        end
        nodes = nodes + 1
        x_pos, x_vel, x_vel_ub = step(node)
        if not in_scope() then
            tally.out_of_scope = tally.out_of_scope + 1
        else
            local text = function()
                return inputs_text(line, #line, node.seq)
            end
            if check_state(tally, recs, node.up, node.depth, x_pos, x_vel,
                           x_vel_ub, text) then
                confirm(line, node.seq, x_pos, x_vel)
                break                 -- replay moved the emulator on
            end
            local left = frames - node.depth
            if left > 0 then
                if not may_beat(recs, names, node.depth, x_pos, x_vel_ub,
                                left) then
                    tally.pruned = tally.pruned + 1
                elseif explored_before(node.depth) then
                    tally.dupes = tally.dupes + 1
                else
                    -- Both read RAM, so they come before save_state moves on.
                    local rec = make_record(node.depth, x_pos, x_vel_ub, left)
                    rec.up = node.up
                    local state = save_state()
                    for _, sym in ipairs(ALPHABET) do
                        local child = copy_seq(node.seq)
                        child[#child + 1] = sym
                        push_node(frontier, { seq = child,
                            depth = node.depth + 1, from = state, up = rec })
                    end
                end
            end
        end
        if nodes % PROGRESS_EVERY == 0 then
            report_progress(setup, nodes, tally, frontier)
        end
    end
    tally.nodes = tally.nodes + nodes
end

local totals = { setups = 0, checks = 0, fails = 0, fails16 = 0,
                 reached = 0, aimed = 0 }
report_start()

for _, setup in ipairs(SETUPS) do
    if RUN == "ALL" or RUN == setup.id then
        local missing
        for _, line in ipairs(setup.lines) do
            for _, sym in ipairs(line) do
                if not INPUT[sym] then missing = missing or sym end
            end
        end
        if missing then
            report_skipped(setup, missing)
        else
            report_setup_start(setup)
            local tally = new_tally()
            for i, line in ipairs(setup.lines) do
                run_line(setup, line, tally, i == 1 and #setup.lines == 1)
            end
            local reached = report_setup_done(setup, tally)
            totals.setups = totals.setups + 1
            totals.checks = totals.checks + tally.checks
            for _, n in pairs(tally.fails) do
                totals.fails = totals.fails + n
            end
            for _, n in pairs(tally.fails16) do
                totals.fails16 = totals.fails16 + n
            end
            if reached ~= nil then
                totals.aimed = totals.aimed + 1
                if reached then totals.reached = totals.reached + 1 end
            end
        end
    end
end

report_summary(totals)
