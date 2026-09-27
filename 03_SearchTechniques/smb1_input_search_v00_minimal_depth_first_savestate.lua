--
-- === SMB1 Per-Frame Input Sequence Depth-First Search Demo ===
-- Variant: savestates, minimal
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
-- so keep both if you adapt this. This is the minimal variant: the full
-- version's diagnostics are removed, and the search is identical.
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

-- === Replay =================================================================

-- Plays a sequence from the anchor and returns the final state. Here it only
-- verifies results: it depends on no saved state except the anchor.
local function replay(seq)
    savestate.load(anchor)
    local x_pos, x_vel, x_vel_ub = measure()

    for i = 1, #seq do
        joypad.set(1, INPUT[seq[i]])
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
    local x_pos, x_vel, x_vel_ub = measure()

    if node.depth > 0 then
        joypad.set(1, INPUT[node.seq[node.depth]])
        emu.frameadvance()
        x_pos, x_vel, x_vel_ub = measure()
        check_speed(x_vel)
    end
    return x_pos, x_vel, x_vel_ub
end

-- === Search =================================================================

local frontier = {}
push_node(frontier, { seq = {}, depth = 0, from = anchor })

while true do
    local node = pop_next(frontier)
    if node == nil then break end

    local x_pos, x_vel, x_vel_ub = step(node)
    local ceiling = bound(x_pos, x_vel_ub, node.depth)

    if ceiling <= best_score then
        -- Cannot beat the incumbent even at best case; <= also drops ties.
        -- Pruning is simply not expanding: this subtree is never visited.
    elseif x_vel == MAX_SPEED then
        -- At cap the ceiling IS the achieved score, not an estimate. Capped
        -- nodes are terminal, so no ancestor can already have capped.
        verify(node, x_pos, x_vel)
        best_score, best_seq = ceiling, node.seq
        emu.print(string.format("| *BEST* | s=%.3f, d=%d | %s",
            ceiling, node.depth, table.concat(node.seq, ",")))
    elseif node.depth < MAX_DEPTH then
        local state = save_state()
        for _, sym in ipairs(ALPHABET) do
            local child = copy_seq(node.seq)
            child[#child + 1] = sym
            push_node(frontier, { seq = child, depth = node.depth + 1,
                from = state })
        end
    end
end

-- Only reached if the tree is exhausted, which at useful depths it is not.
emu.print("    done: search exhausted")
if best_seq then
    -- A node's depth is its string length, so #best_seq is the cap frame.
    emu.print(string.format("| *BEST* | s=%.3f, d=%d | %s",
        best_score, #best_seq, table.concat(best_seq, ",")))
end
