--
-- SMB1 frame-level input search
-- ============================================================================
-- Finds fast input sequences from a fixed starting frame, under RTA rules
-- (no L+R). Three phases, each covering the previous one's weakness:
--
--   A. Frame-by-frame with dedup, out to HANDOFF_FRAME. Early on, different
--      button sequences converge on identical game states in huge numbers, so
--      this is where dedup pays: keeping one of each collapses the work.
--      Past ~frame 14 states start diverging again and it stops paying.
--
--   B. Greedy rollouts from every surviving state: repeatedly take the
--      best-looking next input until max speed. Phase A finds the setups but
--      never reaches an outcome; rollouts cash them in, producing the first
--      real result and, with it, a bar worth pruning against. Nothing is
--      scripted -- a rollout only ever plays inputs from the alphabet.
--
--   C. Best-first over what Phase A left, now with that bar. Expands the
--      most promising state first, and stops for good once the best remaining
--      cannot beat the incumbent.
--
-- Setup: load the .fcs savestate at the first controllable frame with the
-- emulator paused, run this script, then unpause.
--

-- === Anchor =================================================================

-- FCEUX defers a Lua savestate write to the next frame boundary, so saving and
-- immediately reading back gives the PREVIOUS state. Advance once to force the
-- commit; the wasted frame is discarded by the load. This applies everywhere
-- below: never load a state saved since the last frame advance.
local start_state = savestate.create()
savestate.save(start_state)
emu.frameadvance()
savestate.load(start_state)

emu.speedmode("nothrottle")  -- all non-"normal" modes behave the same here

local MAX_SPEED = 40      -- hard speed cap in 1/16-px units; requires B held
local HANDOFF_FRAME = 12  -- where dedup stops paying and best-first takes over
local MAX_DEPTH = 60      -- frames; must exceed the frame a cap is reachable

-- Guards. Each stops cleanly and reports rather than dying mid-run.
-- MAX_FRONTIER and MAX_EXPANSIONS END the proof if they fire: unexpanded
-- states remain, so the answer is "best found", not "proved". MAX_SEEN does
-- not -- dedup simply stops firing, which costs work but discards nothing.
local MAX_FRONTIER = 200000   -- best-first nodes held (each keeps a savestate)
local MAX_EXPANSIONS = 5e6    -- best-first expansions before giving up
local MAX_SEEN = 1500000      -- dedup keys held in Phase C (~3GB at 2KB each)

local ROLLOUT_VARIANTS = 2    -- greedy completions per state, differing on ties
local REPLAY_BEST = true      -- replay the winner at normal speed when done


-- === Measurement ============================================================

-- x_vel is the exact signed byte, for cap detection where an equality test
-- must not be perturbed. x_vel_ub adds the 0x0705 accumulator, an unsigned
-- byte, so it is always >= true velocity -- safe for the bound, which must
-- never understate a branch.
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
    local x_pos, x_vel = measure_state()
    emu.print(string.format("Anchor: x_pos=%.4f x_vel=%d", x_pos, x_vel))
end


-- === Input alphabet =========================================================

-- No L+R. The documented fast-accel pattern is LB, B, RBA. B is on every
-- symbol: it sets RunningTimer, the only route to the 40 cap, and lets the
-- middle frame be directionless without being a bare no-input frame.
local ALPHABET = { "LBA", "LB", "B", "RBA", "RB" }

local BUTTONS = { "up", "down", "left", "right", "A", "B", "select", "start" }

-- Every button must be explicitly true or false. FCEUX reads an omitted key as
-- "leave to the user", not "released", which would let buttons carry over.
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


-- === Scoring and bound ======================================================

local PIXELS_PER_FRAME_AT_CAP = MAX_SPEED / 16  -- 2.5 px/frame
local PROJECTION_FRAME = 45

-- Where a sequence would be at PROJECTION_FRAME running at cap speed from
-- `frame` on. The horizon is shared, so it shifts all scores equally and never
-- changes their ranking. At cap the score is invariant -- one more frame adds
-- exactly 2.5px and costs exactly one frame -- which is why a capped sequence
-- can stop early, and why scores tie so often.
local function score_at(x_pos, frame)
    return x_pos + (PROJECTION_FRAME - frame) * PIXELS_PER_FRAME_AT_CAP
end

-- Fastest acceleration the game can produce: FrictionData doubled (applied
-- when PlayerFacingDir ~= Player_MovingDir), selected on
-- Player_XSpeedAbsolute < 25, converted to 1/16-px units.
--
-- The abs() switch makes the bound non-monotone below -25, where a state can
-- bound lower than its own successor. Audited sound for v >= -24.5; runs reach
-- about -9. BOUND_SAFE_MIN_VEL checks rather than trusts -- if it warns, set
-- ACCEL_LOW = ACCEL_HIGH, sound everywhere and merely looser.
local ACCEL_LOW    = 304 / 256
local ACCEL_HIGH   = 456 / 256
local ACCEL_SWITCH = 25
local BOUND_SAFE_MIN_VEL = -24

-- Accelerates before moving each frame: the most generous legal ordering, so
-- displacement is never understated.
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

-- Optimistic ceiling: grant a free best-case ramp to cap, then score from
-- there. Erring generous is required -- a bound that could understate would
-- let pruning discard the true best.
--
-- It is also non-increasing along a lineage: a child never bounds above its
-- parent. Phase C relies on that for its stopping test, and it is why
-- best-first alone would not dive (hence Phase B).
local function accel_bound(x_pos, x_vel_ub, frame)
    if x_vel_ub >= MAX_SPEED then
        return score_at(x_pos, frame)
    end
    local ramp_frames, ramp_px = ramp_to_cap(x_vel_ub)
    return score_at(x_pos + ramp_px, frame + ramp_frames)
end


-- === Nodes ==================================================================

-- A node holds its own symbol plus a parent link, so creating one is O(1).
-- The sequence is rebuilt only where needed: results and verification.
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


-- === Priority queue (Phase C) ===============================================

-- Max-heap on bound. Ties break toward greater depth: scores tie constantly,
-- and without that the queue spreads sideways and behaves like Phase A again.
local function better(a, b)
    if a.bound ~= b.bound then return a.bound > b.bound end
    return a.depth > b.depth
end

local function heap_push(h, node)
    h[#h + 1] = node
    local i = #h
    while i > 1 do
        local p = math.floor(i / 2)
        if better(h[i], h[p]) then h[i], h[p] = h[p], h[i]; i = p else break end
    end
end

local function heap_pop(h)
    local n = #h
    if n == 0 then return nil end
    local top = h[1]
    h[1] = h[n]; h[n] = nil; n = n - 1
    local i = 1
    while true do
        local l, r, b = 2 * i, 2 * i + 1, i
        if l <= n and better(h[l], h[b]) then b = l end
        if r <= n and better(h[r], h[b]) then b = r end
        if b == i then break end
        h[i], h[b] = h[b], h[i]
        i = b
    end
    return top
end


-- === Replay (ground truth) ==================================================

-- A pure function of the input string, depending on no saved state. Used to
-- verify results at the end; the search itself does not call it.
local function replay(seq)
    savestate.load(start_state)
    local x_pos, x_vel, x_vel_ub = measure_state()
    for i = 1, #seq do
        joypad.set(1, DECODE_TABLE[seq[i]])
        emu.frameadvance()
        x_pos, x_vel, x_vel_ub = measure_state()
    end
    return x_pos, x_vel, x_vel_ub
end


-- === Shared state ===========================================================

local best_score = -math.huge
local best_seq = nil
local results = {}
local frames_stepped = 0

local function best_score_str()
    return best_score == -math.huge and "none" or string.format("%.3f", best_score)
end

-- Checks velocity stays where the bound is monotone. Warns once.
local min_vel_seen = math.huge
local vel_warned = false

local function check_vel(x_vel)
    if x_vel < min_vel_seen then
        min_vel_seen = x_vel
        if x_vel < BOUND_SAFE_MIN_VEL and not vel_warned then
            vel_warned = true
            emu.print(string.format("WARNING x_vel=%d below %d: bound may be"
                .. " non-monotone. Set ACCEL_LOW = ACCEL_HIGH.",
                x_vel, BOUND_SAFE_MIN_VEL))
        end
    end
end

-- Records a confirmed outcome and raises the bar if it is better.
local function record(seq, depth, x_pos, x_vel, x_vel_ub, bound, tag)
    results[#results + 1] = { seq = seq, depth = depth, x_pos = x_pos,
        x_vel = x_vel, x_vel_ub = x_vel_ub, capped = true }
    if bound > best_score then
        best_score = bound
        best_seq = seq
        emu.print(string.format("BEST (%s) d=%d score=%.3f | %s",
            tag, depth, bound, table.concat(seq, ",")))
    end
end


-- === Incumbent seed =========================================================

-- Phase A cannot prune until something confirms a score, and its own first
-- terminal is 40-odd frames away -- so without a seed it runs unpruned and
-- keeps far more states than it needs to.
--
-- Holding RB to the cap is a real outcome, so it is a legitimate bar, and it
-- contains none of the tech: it is the trivial "just run right" line. Because
-- the bound is optimistic, seeding cannot discard anything that would beat it
-- -- a sequence reaching 99 bounds at or above 99 at every prefix. So this
-- buys memory without touching what is discoverable.
local function seed_incumbent()
    savestate.load(start_state)
    local x_pos, x_vel = measure_state()
    local frame = 0
    while x_vel ~= MAX_SPEED and frame < 300 do
        joypad.set(1, DECODE_TABLE["RB"])
        emu.frameadvance()
        frames_stepped = frames_stepped + 1
        x_pos, x_vel = measure_state()
        frame = frame + 1
    end
    if x_vel ~= MAX_SPEED then return nil, frame end
    return score_at(x_pos, frame), frame
end


-- === Phase A: frame-by-frame with dedup =====================================

local function phase_a(handoff)
    local level = { { depth = 0, sym = nil, parent = nil, state = start_state } }

    for depth = 0, handoff - 1 do
        local seen, next_level = {}, {}
        local pruned, dupes = 0, 0

        for _, node in ipairs(level) do
            for _, sym in ipairs(ALPHABET) do
                savestate.load(node.state)
                joypad.set(1, DECODE_TABLE[sym])
                emu.frameadvance()
                frames_stepped = frames_stepped + 1

                local x_pos, x_vel, x_vel_ub = measure_state()
                local key = memory.readbyterange(0, 0x800)  -- all 2KB of RAM

                if seen[key] then
                    -- Same state, same length, same future.
                    dupes = dupes + 1
                else
                    seen[key] = true
                    check_vel(x_vel)
                    local child = { depth = depth + 1, sym = sym, parent = node }
                    child.bound = accel_bound(x_pos, x_vel_ub, child.depth)

                    if child.bound <= best_score then
                        pruned = pruned + 1
                    elseif x_vel == MAX_SPEED then
                        record(node_seq(child), child.depth, x_pos, x_vel,
                            x_vel_ub, child.bound, "A")
                    else
                        child.state = savestate.create()
                        savestate.save(child.state)
                        next_level[#next_level + 1] = child
                    end
                end
            end
        end

        emu.frameadvance()  -- commit the savestates above before any is loaded
        for _, node in ipairs(level) do node.state = nil end
        collectgarbage()

        emu.print(string.format("frame %d: kept=%d pruned=%d duplicates=%d best=%s",
            depth + 1, #next_level, pruned, dupes, best_score_str()))

        level = next_level
        if #level == 0 then break end
    end

    return level
end


-- === Phase B: greedy rollouts ===============================================

-- From one state, repeatedly take the highest-bound next input until max speed
-- or the horizon. Every input comes from the alphabet, so whatever this finds
-- was found by the search, not supplied to it.
--
-- take_last flips how ties are broken. Scores tie constantly, so without this
-- every rollout from a state would follow the identical line; running both
-- variants explores genuinely different completions for little extra cost.
--
-- Costs ~7 frames per step: five to try each input, one to redo the winner,
-- one to commit its savestate.
local function rollout(node, max_depth, take_last)
    local cur, tmp = node.state, savestate.create()
    local depth, seq = node.depth, node_seq(node)

    while depth < max_depth do
        local pick, pick_bound = nil, -math.huge
        for _, sym in ipairs(ALPHABET) do
            savestate.load(cur)
            joypad.set(1, DECODE_TABLE[sym])
            emu.frameadvance()
            frames_stepped = frames_stepped + 1
            local x_pos, x_vel, x_vel_ub = measure_state()
            check_vel(x_vel)
            local b = accel_bound(x_pos, x_vel_ub, depth + 1)
            if b > pick_bound or (take_last and b == pick_bound) then
                pick, pick_bound = sym, b
            end
        end

        savestate.load(cur)
        joypad.set(1, DECODE_TABLE[pick])
        emu.frameadvance()
        frames_stepped = frames_stepped + 1
        depth = depth + 1
        seq[#seq + 1] = pick

        local x_pos, x_vel, x_vel_ub = measure_state()
        check_vel(x_vel)
        if x_vel == MAX_SPEED then
            -- Recomputed here rather than reused from the evaluation pass, so
            -- the score and the state it describes come from one execution.
            return seq, depth, x_pos, x_vel, x_vel_ub,
                accel_bound(x_pos, x_vel_ub, depth)
        end

        savestate.save(tmp)
        emu.frameadvance()  -- commit before the next iteration loads it
        frames_stepped = frames_stepped + 1
        cur = tmp
    end
    return nil
end

local function phase_b(frontier, max_depth)
    -- Best-bounded first, so the bar rises early and the skip below fires on
    -- most of the tail. Ordering only -- every state is still considered.
    table.sort(frontier, function(a, b) return a.bound > b.bound end)

    local reached, skipped = 0, 0
    for i, node in ipairs(frontier) do
        -- The bound caps everything reachable from this state, so if it cannot
        -- beat the incumbent no completion from here can either.
        if node.bound <= best_score then
            skipped = skipped + 1
        else
            for v = 1, ROLLOUT_VARIANTS do
                local seq, depth, x_pos, x_vel, x_vel_ub, bound =
                    rollout(node, max_depth, v > 1)
                if seq then
                    reached = reached + 1
                    record(seq, depth, x_pos, x_vel, x_vel_ub, bound, "B")
                end
            end
        end
        if i % 1000 == 0 then
            collectgarbage()
            emu.print(string.format("rollouts %d/%d capped=%d skipped=%d best=%s",
                i, #frontier, reached, skipped, best_score_str()))
        end
    end
    collectgarbage()
    emu.print(string.format("phase B: %d completions reached max speed,"
        .. " %d of %d states skipped as hopeless, best=%s",
        reached, skipped, #frontier, best_score_str()))
end


-- === Phase C: best-first ====================================================

local function phase_c(frontier, max_depth)
    local heap = {}
    for _, node in ipairs(frontier) do heap_push(heap, node) end

    -- Keyed on RAM alone, not (depth, RAM): SMB keeps frame counters in RAM,
    -- so depth is already baked into the key. The stored depth handles the
    -- case where the same state is reached again in fewer frames.
    local seen, seen_count, seen_full = {}, 0, false
    local expansions, pruned, dupes, stopped = 0, 0, 0, nil
    local horizon_dropped = 0

    while true do
        local node = heap_pop(heap)
        if node == nil then stopped = "frontier exhausted"; break end

        -- The heap top holds the highest bound of anything left, so if it
        -- cannot beat the incumbent then nothing can. This is the payoff of
        -- ordering by bound, and Phase A has no equivalent.
        if node.bound <= best_score then
            stopped = "proved: nothing remaining can beat the incumbent"
            break
        end
        if expansions >= MAX_EXPANSIONS then
            stopped = "expansion budget reached"; break
        end
        if #heap >= MAX_FRONTIER then
            stopped = "frontier cap reached"; break
        end

        expansions = expansions + 1
        for _, sym in ipairs(ALPHABET) do
            savestate.load(node.state)
            joypad.set(1, DECODE_TABLE[sym])
            emu.frameadvance()
            frames_stepped = frames_stepped + 1

            local x_pos, x_vel, x_vel_ub = measure_state()
            local depth = node.depth + 1
            local key = memory.readbyterange(0, 0x800)
            local prev = seen[key]

            if prev and prev <= depth then
                dupes = dupes + 1
            else
                if not seen_full then
                    seen[key] = depth
                    seen_count = seen_count + 1
                    if seen_count >= MAX_SEEN then
                        seen_full = true
                        emu.print("dedup table full: deduplication stops here."
                            .. " Sound -- more work, nothing discarded.")
                    end
                end
                check_vel(x_vel)
                local bound = accel_bound(x_pos, x_vel_ub, depth)
                if bound <= best_score then
                    pruned = pruned + 1
                elseif x_vel == MAX_SPEED then
                    record(node_seq({ depth = depth, sym = sym, parent = node }),
                        depth, x_pos, x_vel, x_vel_ub, bound, "C")
                elseif depth < max_depth then
                    local child = { depth = depth, sym = sym, parent = node,
                        bound = bound }
                    child.state = savestate.create()
                    savestate.save(child.state)
                    heap_push(heap, child)
                else
                    -- Hit the horizon without capping: not a confirmed result,
                    -- but counted so a binding MAX_DEPTH is visible.
                    horizon_dropped = horizon_dropped + 1
                end
            end
        end
        emu.frameadvance()  -- commit children before any can be popped
        node.state = nil

        if expansions % 2000 == 0 then
            collectgarbage()
            emu.print(string.format("expansions=%d heap=%d pruned=%d dupes=%d best=%s",
                expansions, #heap, pruned, dupes, best_score_str()))
        end
    end

    emu.print(string.format("phase C: %s", stopped))
    emu.print(string.format("  expansions=%d heap=%d pruned=%d dupes=%d"
        .. " horizon_dropped=%d seen=%d",
        expansions, #heap, pruned, dupes, horizon_dropped, seen_count))
end


-- === Run ====================================================================

local seed, seed_frames = seed_incumbent()
if seed then
    best_score = seed
    emu.print(string.format("seed: all-RB caps at frame %d, score=%.3f",
        seed_frames, seed))
else
    emu.print("seed: all-RB never capped; Phase A runs unpruned")
end

local frontier = phase_a(HANDOFF_FRAME)
emu.print(string.format("handoff at frame %d with %d states", HANDOFF_FRAME, #frontier))

phase_b(frontier, MAX_DEPTH)
phase_c(frontier, MAX_DEPTH)

emu.print(string.format("frames stepped=%d min_vel=%d results=%d best=%s",
    frames_stepped, min_vel_seen, #results, best_score_str()))
if best_seq then
    emu.print("best sequence: " .. table.concat(best_seq, ","))
end

-- Re-derive every result from the anchor. Input strings are the ground truth;
-- this catches any drift in the saved states.
local mismatches = 0
for _, r in ipairs(results) do
    local vx, vv = replay(r.seq)
    if vx ~= r.x_pos or vv ~= r.x_vel then
        mismatches = mismatches + 1
        emu.print(string.format("MISMATCH %s: search (%.4f,%d) vs replay (%.4f,%d)",
            table.concat(r.seq, ","), r.x_pos, r.x_vel, vx, vv))
    end
end
emu.print(string.format("verification: %d results, %d mismatches", #results, mismatches))

if REPLAY_BEST and best_seq then
    emu.print("replaying the best sequence at normal speed")
    emu.speedmode("normal")
    replay(best_seq)
end

local REPORT_TOP = 20
table.sort(results, function(a, b)
    return accel_bound(a.x_pos, a.x_vel_ub, a.depth)
         > accel_bound(b.x_pos, b.x_vel_ub, b.depth)
end)
emu.print(string.format("results=%d, showing top %d", #results, REPORT_TOP))
for i = 1, math.min(REPORT_TOP, #results) do
    local r = results[i]
    emu.print(string.format("%2d. score=%.3f d=%-3d x=%.3f v=%-4d %s",
        i, accel_bound(r.x_pos, r.x_vel_ub, r.depth), r.depth, r.x_pos, r.x_vel,
        table.concat(r.seq, ",")))
end