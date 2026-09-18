--
-- SMB1 frame-level input search: branch-and-bound over frame inputs.
-- Setup: load the .fcs savestate at the first controllable frame with the
-- emulator paused, run this script, then unpause.
--
-- EXPERIMENT (option D, DFS only): nodes carry an emulator state, so a child
-- costs one frame instead of replaying its whole prefix. Input strings stay
-- the ground truth and every result is re-derived from the anchor at the end
-- to confirm the state chain did not drift. To revert: drop step_node /
-- parent_state / own_state / current_state and call replay(node_seq(node)).
--

-- FCEUX does not commit a Lua savestate until a frame boundary passes, so the
-- anchor must be settled before anything reads it. Save, advance once to force
-- the commit, then load it back -- the wasted frame is discarded by the load.
local start_state = savestate.create()
savestate.save(start_state)
emu.frameadvance()
savestate.load(start_state)

emu.speedmode("maximum")  -- "maximum" is faster but disables rendering

local MAX_SPEED = 40        -- hard cap in 1/16-px units; requires B held
local PROGRESS_EVERY = 1000  -- node evaluations between progress lines


-- === Measurement ===========================================================

-- x_vel is the exact signed byte, used for cap detection. x_vel_ub adds the
-- 0x0705 accumulator, an unsigned byte, so it is always >= true velocity --
-- valid as a bound input without depending on how that register is read.
local function measure_state()
    local page  = memory.readbyte(0x006D)
    local pixel = memory.readbyte(0x0086)
    local sub   = memory.readbyte(0x0400)
    local x_pos = page * 256 + pixel + (sub / 256)
    local x_vel = memory.readbytesigned(0x0057)
    local x_vel_ub = x_vel + memory.readbyte(0x0705) / 256
    return x_pos, x_vel, x_vel_ub
end

do
    savestate.load(start_state)
    local x_pos, x_vel = measure_state()
    emu.print(string.format("Anchor check: x_pos=%.4f x_vel=%d", x_pos, x_vel))
end


-- === Input alphabet ========================================================

-- RTA rules: no L+R. Fast accel is LB, B, RBA. B is held throughout: it sets
-- RunningTimer, the only route to the 40 cap, and keeps the middle frame
-- directionless without being a bare no-input frame.
-- pop_next is LIFO, so the LAST entry is explored FIRST. RB last means the
-- opening dive is all-RB, which seeds a confirmed incumbent immediately.
local ALPHABET = { "LBA", "LB", "B", "RBA", "RB" }

local BUTTONS = { "up", "down", "left", "right", "A", "B", "select", "start" }

-- Every button must be explicitly true or false. FCEUX treats a nil/omitted
-- key as "leave this button to the user", NOT as released -- so a partial
-- table lets unmanaged buttons carry over and makes the input string a lie.
local function make_input(held)
    local t = {}
    for _, b in ipairs(BUTTONS) do t[b] = false end
    for _, b in ipairs(held) do t[b] = true end
    return t
end

local DECODE_TABLE = {
    B    = make_input{"B"},
    LB   = make_input{"left", "B"},
    RB   = make_input{"right", "B"},
    RBA  = make_input{"right", "B", "A"},
    LBA  = make_input{"left", "B", "A"},
}


-- === Scoring and bound =====================================================

local PIXELS_PER_FRAME_AT_CAP = MAX_SPEED / 16  -- 2.5 px/frame
local PROJECTION_FRAME = 45  -- shared horizon; shifts all scores equally

-- Projected x_pos at PROJECTION_FRAME assuming cap speed from `frame` on.
local function score_at(x_pos, frame)
    return x_pos + (PROJECTION_FRAME - frame) * PIXELS_PER_FRAME_AT_CAP
end

-- Airborne fast-accel profile: FrictionData doubled when facing ~= moving,
-- selected on Player_XSpeedAbsolute < 25. In 1/16-px units.
--
-- The abs() switch makes the bound non-monotone below -25, where a node can
-- bound lower than its own successor. Pruning assumes a parent's bound caps
-- every descendant, so that would be unsound. Audited: monotone and exact
-- for v >= -24.5, failing only at v <= -25. This search is not expected past
-- about -5, so the model holds with ~5x margin; BOUND_SAFE_MIN_VEL checks
-- that at runtime. If it ever warns, set ACCEL_LOW = ACCEL_HIGH, which is
-- sound at every velocity.
local ACCEL_LOW    = 304 / 256
local ACCEL_HIGH   = 456 / 256
local ACCEL_SWITCH = 25
local BOUND_SAFE_MIN_VEL = -24

-- Idealized ramp to cap, accelerating before moving each frame -- the most
-- generous legal ordering, so displacement is never understated.
local function ramp_to_cap(x_vel)
    local v, frames, disp_units = x_vel, 0, 0
    while v < MAX_SPEED and frames < 1000 do
        local a = (math.abs(v) < ACCEL_SWITCH) and ACCEL_LOW or ACCEL_HIGH
        v = math.min(v + a, MAX_SPEED)
        disp_units = disp_units + v
        frames = frames + 1
    end
    return frames, disp_units / 16
end

-- Optimistic: grants a free best-case ramp to cap, then scores from there.
-- Always <= score_at alone, so it is a strict tightening.
local function accel_bound(x_pos, x_vel_ub, frame)
    if x_vel_ub >= MAX_SPEED then
        return score_at(x_pos, frame)
    end
    local ramp_frames, ramp_px = ramp_to_cap(x_vel_ub)
    return score_at(x_pos + ramp_px, frame + ramp_frames)
end


-- === Node machinery ========================================================

-- A node stores only its last symbol and a parent link, so a push is O(1)
-- rather than copying an O(depth) array. The sequence is rebuilt only where
-- needed: progress lines, BEST, results, verification.
local function node_seq(node)
    local out, n = {}, 0
    while node and node.sym do
        n = n + 1
        out[n] = node.sym
        node = node.parent
    end
    for i = 1, math.floor(n / 2) do
        out[i], out[n + 1 - i] = out[n + 1 - i], out[i]
    end
    return out
end

local function push_node(frontier, node)
    frontier[#frontier + 1] = node
end

-- LIFO. Best-first needs a heap here, and would also break the per-node
-- state design, since the frontier stops being path-shaped.
local function pop_next(frontier)
    local n = #frontier
    if n == 0 then return nil end
    local node = frontier[n]
    frontier[n] = nil
    return node
end


-- === Execution =============================================================

local frames_stepped = 0
local loads_done, loads_skipped = 0, 0
local current_state = nil  -- where the emulator sits, so a dive can skip a load

-- One frame from the parent's state. The search's hot path.
local function step_node(node)
    if node.parent_state == current_state then
        loads_skipped = loads_skipped + 1
    else
        savestate.load(node.parent_state)
        loads_done = loads_done + 1
    end
    current_state = nil  -- about to advance a frame
    if node.sym == nil then
        return measure_state()  -- root: the anchor itself, no frame advanced
    end
    joypad.set(1, DECODE_TABLE[node.sym])
    emu.frameadvance()
    frames_stepped = frames_stepped + 1
    return measure_state()
end

-- Full replay from the anchor: a pure function of the input string. Ground
-- truth for the end-of-run verification, not used by the search.
local function replay(seq)
    savestate.load(start_state)
    current_state = nil
    local x_pos, x_vel, x_vel_ub = measure_state()
    for i = 1, #seq do
        joypad.set(1, DECODE_TABLE[seq[i]])
        emu.frameadvance()
        x_pos, x_vel, x_vel_ub = measure_state()
    end
    return x_pos, x_vel, x_vel_ub
end


-- === Search state ==========================================================

local best_score = -math.huge

local function best_score_str()
    return best_score == -math.huge and "none" or string.format("%.3f", best_score)
end

-- Guards the bound's validity domain. Warns once.
local min_vel_seen = math.huge
local vel_warned = false

local function check_vel(x_vel, node)
    if x_vel < min_vel_seen then
        min_vel_seen = x_vel
        if x_vel < BOUND_SAFE_MIN_VEL and not vel_warned then
            vel_warned = true
            emu.print(string.format(
                "WARNING x_vel=%d below %d: bound may be non-monotone here."
                .. " Set ACCEL_LOW = ACCEL_HIGH. | %s",
                x_vel, BOUND_SAFE_MIN_VEL, table.concat(node_seq(node), ",")))
        end
    end
end


-- === Search ================================================================

local function search(max_depth)
    local frontier = {}
    local results = {}
    push_node(frontier, { depth = 0, sym = nil, parent = nil, parent_state = start_state })

    best_score = -math.huge
    frames_stepped, loads_done, loads_skipped = 0, 0, 0
    current_state = nil
    local pruned_count, capped_count, evaluated, skipped_replays = 0, 0, 0, 0
    local frames_if_full_replay = 0

    while true do
        local node = pop_next(frontier)
        if node == nil then break end

        -- inherited_bound is the parent's bound, an upper bound on every
        -- descendant. The incumbent may have risen while this node waited,
        -- so check before paying for a step.
        if node.inherited_bound and node.inherited_bound <= best_score then
            pruned_count = pruned_count + 1
            skipped_replays = skipped_replays + 1
        else
            local x_pos, x_vel, x_vel_ub = step_node(node)
            evaluated = evaluated + 1
            frames_if_full_replay = frames_if_full_replay + node.depth
            check_vel(x_vel, node)

            if evaluated % PROGRESS_EVERY == 0 then
                emu.print(string.format("[%d] pruned=%d skipped=%d capped=%d best=%s | d=%d %s",
                    evaluated, pruned_count, skipped_replays, capped_count,
                    best_score_str(), node.depth, table.concat(node_seq(node), ",")))
            end

            local bound = accel_bound(x_pos, x_vel_ub, node.depth)
            -- <= keeps one representative of a tie: a tie cannot beat the
            -- incumbent, so dropping it cannot lose the true best.
            local dominated = bound <= best_score
            -- Nodes that hit the cap are terminal, so no ancestor capped and
            -- a cap seen here is necessarily this node's own frame.
            local reached_cap = (x_vel == MAX_SPEED)

            -- Only confirmed cap events raise the incumbent; a bound is
            -- optimistic and must never promote itself.
            if reached_cap and not dominated then
                emu.print(string.format("BEST d=%d score=%.3f | %s",
                    node.depth, bound, table.concat(node_seq(node), ",")))
                best_score = bound
            end

            if dominated then
                pruned_count = pruned_count + 1
            elseif reached_cap then
                capped_count = capped_count + 1
                results[#results + 1] = { seq = node_seq(node), depth = node.depth,
                    x_pos = x_pos, x_vel = x_vel, capped = true }
            elseif node.depth == max_depth then
                results[#results + 1] = { seq = node_seq(node), depth = node.depth,
                    x_pos = x_pos, x_vel = x_vel, capped = false }
            else
                -- Only expanding nodes keep a state, so terminal and pruned
                -- nodes cost nothing extra.
                local own_state = savestate.create()
                savestate.save(own_state)
                current_state = own_state  -- next pop is this node's last child
                for _, sym in ipairs(ALPHABET) do
                    push_node(frontier, {
                        depth = node.depth + 1,
                        sym = sym,
                        parent = node,
                        parent_state = own_state,
                        inherited_bound = bound,
                    })
                end
            end
        end
    end

    emu.print(string.format("evaluated=%d pruned=%d (skipped=%d) capped=%d min_vel=%d",
        evaluated, pruned_count, skipped_replays, capped_count, min_vel_seen))
    emu.print(string.format("frames stepped=%d vs %d from anchor (%.1fx)",
        frames_stepped, frames_if_full_replay,
        frames_if_full_replay / math.max(frames_stepped, 1)))
    emu.print(string.format("state loads=%d skipped=%d (%.0f%% avoided)",
        loads_done, loads_skipped,
        100 * loads_skipped / math.max(loads_done + loads_skipped, 1)))

    return results
end


-- === Run ===================================================================

local results = search(50)

-- Re-derive every result from the anchor. Catches drift in the state chain.
local mismatches = 0
for _, r in ipairs(results) do
    local vx, vv = replay(r.seq)
    if vx ~= r.x_pos or vv ~= r.x_vel then
        mismatches = mismatches + 1
        emu.print(string.format("MISMATCH %s: chained (%.4f,%d) vs replay (%.4f,%d)",
            table.concat(r.seq, ","), r.x_pos, r.x_vel, vx, vv))
    end
end
emu.print(string.format("verification: %d results, %d mismatches", #results, mismatches))

-- Top results only. Printing every leaf floods the console and can hang it.
local REPORT_TOP = 20

table.sort(results, function(a, b)
    return score_at(a.x_pos, a.depth) > score_at(b.x_pos, b.depth)
end)

emu.print(string.format("results=%d, showing top %d", #results, REPORT_TOP))
for i = 1, math.min(REPORT_TOP, #results) do
    local r = results[i]
    emu.print(string.format("%2d. score=%.3f d=%-3d x=%.3f v=%-4d %s %s",
        i, score_at(r.x_pos, r.depth), r.depth, r.x_pos, r.x_vel,
        r.capped and "CAPPED" or "      ", table.concat(r.seq, ",")))
end