--
-- === SMB1 Per-Frame Input Sequence Depth-First Search Demo ===
-- Variant: savestates, full diagnostics
--
-- Depth-first branch-and-bound over per-frame inputs, SMB1 in FCEUX.
--
-- A node is an input string plus the savestate its parent left behind. It is
-- evaluated by loading that state and playing one more frame, rather than
-- replaying the whole string. A branch is dropped when even a best-case
-- acceleration profile cannot beat the best result so far. It explores the
-- same tree as the replay version with far fewer emulated frames per node,
-- but at useful depths it still does not finish.
--
-- To understand the method, read in this order:
--   Search           the loop: pop, step, bound, then prune/record/expand
--   Frontier         LIFO pop is what makes it depth-first; a node is a string
--   Step             loads the parent's savestate and plays one more frame
--   Score and bound  when a branch can be dropped, and why that is safe
--   Incumbent        the best confirmed result: the bar every bound must beat
--   Replay           re-derives each new best from the anchor: the input
--                    string, not the savestates, is the ground truth
-- Settings through Measurement are supporting detail -- though Anchor and
-- Inputs each hold an FCEUX gotcha that silently corrupts results if missed,
-- so keep both if you adapt this. Diagnostics is reporting only: the
-- sections above reach it solely through report_* calls, and it can be
-- skipped entirely on a first read.
--
-- Setup: Load FCS savestate file with emulator paused, then run this, then
-- unpause.
--

-- === Settings ===============================================================

-- Search
local PROJECTION_FRAME = 45   -- score = projected x-position at this frame
local MAX_DEPTH = 50          -- longest input string tried. The opening dive
                              -- (the last ALPHABET symbol, every frame) must
                              -- reach the cap within this, or no incumbent ever
                              -- forms and nothing is pruned. RB caps ~frame 45.

-- Memory
local GC_EVERY = 5000         -- savestates created between full collections;
                              -- lower it if memory climbs on long runs

-- Reporting
local SHOW_LIVE = true        -- draw current and best sequences on screen
local PROGRESS_EVERY = 1000   -- nodes between console progress lines
local PRUNE_BAND = 10         -- frames per bucket in the prune-depth summary

-- === Game constants =========================================================

local MAX_SPEED = 40          -- x speed cap, in 1/16 px/frame; needs B held
local PX_PER_FRAME_AT_CAP = MAX_SPEED / 16

-- Fastest acceleration the game can produce, in speed units per frame:
-- FrictionData doubled (facing ~= moving), chosen on |speed| < 25.
local ACCEL_LOW, ACCEL_HIGH, ACCEL_SWITCH = 304 / 256, 456 / 256, 25

-- The bound is only monotone for speed >= -24.5, and pruning relies on that.
-- Checked at runtime rather than assumed.
local BOUND_SAFE_MIN_VEL = -24

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

-- RTA set (no L+R), B held throughout. The stack is LIFO, so the LAST symbol
-- leads every dive. The opening dive has to reach the cap to form the first
-- incumbent. RB last does that by "running right". Nothing prunes before it.
local ALPHABET = { "B", "LBA", "LB", "RBA", "RB" }

-- Every button must be set true OR false: an omitted button means "leave it
-- to the user", not "released".
local BUTTONS = { "up", "down", "left", "right", "A", "B", "select", "start" }

local function make_input(held)
    local t = {}
    for _, b in ipairs(BUTTONS) do t[b] = false end
    for _, b in ipairs(held) do t[b] = true end
    return t
end

local INPUT = {
    B   = make_input{ "B" },
    LB  = make_input{ "left", "B" },
    LBA = make_input{ "left", "B", "A" },
    RB  = make_input{ "right", "B" },
    RBA = make_input{ "right", "B", "A" },
}

-- === Measurement ============================================================

-- x_vel is the exact speed byte, used to detect the cap. x_vel_ub adds the
-- 0x0705 accumulator, an unsigned byte, so it is never below true speed --
-- the bound must never understate a branch.
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
-- That ordering is the most generous, so distance is never understated.
local function ramp_to_cap(v)
    local frames, dist = 0, 0
    while v < MAX_SPEED do
        local accel = math.abs(v) < ACCEL_SWITCH and ACCEL_LOW or ACCEL_HIGH
        v = math.min(v + accel, MAX_SPEED)
        dist = dist + v / 16
        frames = frames + 1
    end
    return frames, dist
end

-- Upper bound on the score any continuation of this state can reach. If it
-- cannot beat the incumbent, nothing below this node can either.
local function bound(x_pos, x_vel_ub, frame)
    if x_vel_ub >= MAX_SPEED then return score(x_pos, frame) end
    local frames, dist = ramp_to_cap(x_vel_ub)
    return score(x_pos + dist, frame + frames)
end

-- Soundness guard, not reporting: warns once if speed leaves the range where
-- the bound is monotone, because pruning would then be unsafe.
local min_vel, vel_warned = math.huge, false

local function check_speed(x_vel)
    if x_vel >= min_vel then return end
    min_vel = x_vel
    if x_vel < BOUND_SAFE_MIN_VEL and not vel_warned then
        vel_warned = true
        emu.print(string.format(
            "WARNING speed %d below %d: bound may be unsound. "
            .. "Set ACCEL_LOW = ACCEL_HIGH.", x_vel, BOUND_SAFE_MIN_VEL))
    end
end

-- === Incumbent ==============================================================

-- Best confirmed result so far. Only a sequence that actually reaches the cap
-- may set it; a bound is an estimate and must never promote itself.
local best_score, best_seq = -math.huge, nil

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

-- === Diagnostics ============================================================
-- Reporting only. The search code reaches this section solely through the
-- report_* functions, and nothing here writes to search state, so any of them
-- can be stubbed out without changing results.

-- The order in which alternatives are tried at each depth: LIFO reverses
-- ALPHABET.
local TRY_ORDER = {}
for i = #ALPHABET, 1, -1 do TRY_ORDER[#TRY_ORDER + 1] = ALPHABET[i] end

local CHARS_PER_LINE = 49

local function wrap(seq)
    local lines, line = {}, ""
    for _, s in ipairs(seq) do
        local piece = (line == "" and s) or ("," .. s)
        if #line + #piece > CHARS_PER_LINE then
            lines[#lines + 1] = line
            line = s
        else
            line = line .. piece
        end
    end
    if line ~= "" then lines[#lines + 1] = line end
    return lines
end

-- Where a sequence first leaves the default path (TRY_ORDER[1] every frame).
-- "(init)" means it never does: the opening dive. Both forms are 7 characters
-- wide so the columns they sit in stay aligned.
local function branch_point(seq)
    for i, s in ipairs(seq) do
        if s ~= TRY_ORDER[1] then return string.format("@%02d=%-3s", i, s) end
    end
    return "(init) "
end

-- Live display. Prebuilt once per node / per new best, drawn every frame
-- because gui text lasts one frame. Both headers open with an 8-character
-- label and %7.3f, so scores align at the decimal (given a monospaced font).
local best_lines, best_label, best_branch = {}, "BEST YET = none", ""

local function report_node_start(seq)
    if not SHOW_LIVE then return nil end
    return { lines = wrap(seq), branch = branch_point(seq) }
end

local function report_frame(live, x_pos, x_vel_ub, frame)
    if not live then return end
    local ceiling = bound(x_pos, x_vel_ub, frame)
    local y = 34
    gui.text(4, y, best_label)
    for _, line in ipairs(best_lines) do y = y + 8; gui.text(4, y, line) end
    y = y + 12
    -- "pruned!" can appear before the node is judged. It is still exact: the
    -- ceiling only falls from parent to child, and the incumbent cannot change
    -- mid-node, so this node is certain to be pruned.
    gui.text(4, y, string.format("MAX POSS = %7.3f  %s %-10s", ceiling,
        live.branch, ceiling > best_score and "testing..." or "pruned!"))
    for _, line in ipairs(live.lines) do y = y + 8; gui.text(4, y, line) end
end

-- A prune at depth d removes everything below it, so shallow prunes are worth
-- exponentially more than deep ones. Bucketed by depth to keep it short.
local prunes_by_band = {}

local function report_prune(node)
    local band = math.floor(node.depth / PRUNE_BAND)
    prunes_by_band[band] = (prunes_by_band[band] or 0) + 1
end

local function prune_summary()
    local parts = {}
    for band = 0, math.floor(MAX_DEPTH / PRUNE_BAND) do
        local c = prunes_by_band[band]
        if c then
            parts[#parts + 1] = string.format("%d-%d:%d", band * PRUNE_BAND,
                band * PRUNE_BAND + PRUNE_BAND - 1, c)
        end
    end
    return #parts > 0 and table.concat(parts, "  ") or "none"
end

local function report_best(new_best, node)
    best_lines = wrap(node.seq)
    best_branch = branch_point(node.seq)
    best_label = string.format("BEST YET = %7.3f  %s %-2d frames", new_best,
        best_branch, node.depth)
    emu.print(string.format("| *BEST* | s=%.3f, d=%d | %s",
        new_best, node.depth, table.concat(node.seq, ",")))
end

-- The stack holds, for each depth on the current path, the siblings not yet
-- tried: #ALPHABET - 1 of them until backtracking reaches that depth. The
-- shallowest depth holding fewer is how far up the tree the search has
-- unwound. DFS-specific: best-first has no single current path.
local function unwound(frontier)
    local count, deepest = {}, 0
    for _, n in ipairs(frontier) do
        count[n.depth] = (count[n.depth] or 0) + 1
        if n.depth > deepest then deepest = n.depth end
    end
    for d = 1, deepest do
        local left = count[d] or 0
        if left < #ALPHABET - 1 then return d, #ALPHABET - left end
    end
    return nil
end

-- Alternatives at one depth in try order, current one bracketed: those to its
-- left are exhausted, those to its right are still on the stack.
local function try_status(k)
    local parts = {}
    for i, s in ipairs(TRY_ORDER) do
        parts[i] = (i == k) and ("[" .. s .. "]") or s
    end
    return table.concat(parts, " ")
end

-- Runs before any node is evaluated, so the emulator is still on the anchor.
-- Reading position here is the only check that you paused on the intended
-- frame.
local function report_start()
    local x_pos, x_vel = measure()
    emu.print(string.format("Demo: %s, %d symbols, max depth %d",
        "depth-first with savestates", #ALPHABET, MAX_DEPTH))
    emu.print(string.format("anchor: x_pos=%.4f speed=%d  (1-1 start is"
        .. " 40.0000, 0)", x_pos, x_vel))
end

local function report_progress(evaluated, pruned, frontier)
    local d, k = unwound(frontier)
    local where = " |  still on first dive "
    if d then
        where = string.format(" |  unwound to frame %d,  on %d of %d:  %s ",
            d, k, #ALPHABET, try_status(k))
    end
    emu.print(string.format("    (%d) best=%s %s, frontier=%3d,  pruned=%d ",
        evaluated, best_seq and string.format("%.3f", best_score) or "none",
        best_branch, #frontier, pruned)
        .. where .. " |  prunes by frame:  " .. prune_summary())
end

local function report_done(evaluated, pruned)
    emu.print(string.format("    done: evaluated=%d, pruned=%d, min_speed=%d"
        .. "  |  prunes by frame:  %s", evaluated, pruned, min_vel,
        prune_summary()))
    if best_seq then
        -- A node's depth is its string length, so #best_seq is the cap frame.
        emu.print(string.format("| *BEST* | s=%.3f, d=%d | %s",
            best_score, #best_seq, table.concat(best_seq, ",")))
    end
end

-- === Replay =================================================================

-- Plays a sequence from the anchor and returns the final state. Here it only
-- verifies results: it depends on no saved state except the anchor.
local function replay(seq)
    savestate.load(anchor)
    local live = report_node_start(seq)
    local x_pos, x_vel, x_vel_ub = measure()

    for i = 1, #seq do
        joypad.set(1, INPUT[seq[i]])
        report_frame(live, x_pos, x_vel_ub, i - 1)  -- state before this input
        emu.frameadvance()
        x_pos, x_vel, x_vel_ub = measure()
        check_speed(x_vel)
    end
    return x_pos, x_vel, x_vel_ub
end

-- Savestates are only a shortcut. Before a result may raise the bar, confirm
-- it by replaying its string from the anchor; any disagreement means a saved
-- state drifted, and nothing this run found can be trusted.
local function verify(node, x_pos, x_vel)
    local rx_pos, rx_vel = replay(node.seq)
    if rx_pos ~= x_pos or rx_vel ~= x_vel then
        error(string.format("savestate drift at %s: %.4f, %d by savestate but"
            .. " %.4f, %d by replay", table.concat(node.seq, ","),
            x_pos, x_vel, rx_pos, rx_vel))
    end
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
    local live = report_node_start(node.seq)
    local x_pos, x_vel, x_vel_ub = measure()

    if node.depth > 0 then
        joypad.set(1, INPUT[node.seq[node.depth]])
        report_frame(live, x_pos, x_vel_ub, node.depth - 1)  -- parent's state
        emu.frameadvance()
        x_pos, x_vel, x_vel_ub = measure()
        check_speed(x_vel)
    end
    return x_pos, x_vel, x_vel_ub
end

-- === Search =================================================================

local frontier = {}
push_node(frontier, { seq = {}, depth = 0, from = anchor })
local evaluated, pruned = 0, 0
report_start()

while true do
    local node = pop_next(frontier)
    if node == nil then break end

    local x_pos, x_vel, x_vel_ub = step(node)
    evaluated = evaluated + 1
    local ceiling = bound(x_pos, x_vel_ub, node.depth)

    if ceiling <= best_score then
        -- Cannot beat the incumbent even at best case; <= also drops ties.
        pruned = pruned + 1
        report_prune(node)
    elseif x_vel == MAX_SPEED then
        -- At cap the ceiling IS the achieved score, not an estimate. Capped
        -- nodes are terminal, so no ancestor can already have capped.
        verify(node, x_pos, x_vel)
        best_score, best_seq = ceiling, node.seq
        report_best(ceiling, node)
    elseif node.depth < MAX_DEPTH then
        local state = save_state()
        for _, sym in ipairs(ALPHABET) do
            local child = copy_seq(node.seq)
            child[#child + 1] = sym
            push_node(frontier, { seq = child, depth = node.depth + 1,
                from = state })
        end
    end

    if evaluated % PROGRESS_EVERY == 0 then
        report_progress(evaluated, pruned, frontier)
    end
end

report_done(evaluated, pruned)
