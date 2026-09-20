--
-- SMB1 frame-level input search
-- ============================================================================
-- Finds fast input sequences from a fixed starting frame. Three phases:
--
--   A. Frame-by-frame with full-RAM dedup. Early on, different button
--      sequences land on identical game states in huge numbers; keeping one of
--      each collapses the work. Past ~frame 14 states diverge again and it
--      stops paying, so this hands off.
--
--   B. Hold RB to the cap from every surviving state. Phase A finds setups but
--      never reaches an outcome; this cashes them in cheaply to get a first
--      real bar worth pruning against. Deliberately dumb -- the discriminating
--      work is the prefix Phase A built, not the completion.
--
--   C. Best-first over what Phase A left, with that bar. Expands the most
--      promising state first, and stops for good once the best remaining
--      cannot beat the incumbent.
--
-- Setup: load the .fcs savestate at the first controllable frame with the
-- emulator paused, run this script, then unpause.
--

-- === Knobs ==================================================================

-- "powerset" : all 16 combinations of L, R, B, A (includes L+R)
-- "no_lr"    : the 12 that never press L and R together
-- "maru"     : the 5-symbol RTA set, B held on every frame
local ALPHABET_MODE = "no_lr"

local HANDOFF_FRAME = 5    -- ceiling on Phase A; may stop earlier (see below)
local MAX_LEVEL_STATES = 60000  -- if a Phase A level exceeds this, hand off now
local MAX_DEPTH = 60        -- frames; must exceed the frame a cap is reachable

-- Guards. MAX_FRONTIER and MAX_EXPANSIONS END the proof if they fire:
-- unexpanded states remain, so the answer is "best found", not "proved".
-- MAX_SEEN does not -- dedup simply stops firing, costing work, discarding
-- nothing.
local MAX_FRONTIER = 200000
local MAX_EXPANSIONS = 5e6
local MAX_SEEN = 1500000

-- Heads-up display. Drawing must happen every frame to stay visible, so the
-- per-frame path only issues gui calls against precomputed values; anything
-- expensive (histogram, sparkline) is recomputed on HUD_REFRESH events.
local SHOW_HUD = true
local SHOW_HISTOGRAM = true   -- ~20 extra gui.box calls per frame
local SHOW_SPARKLINE = true   -- frontier-size trace; ~40 gui.line calls per frame
local HUD_REFRESH = 2000      -- events between expensive HUD recomputes
local PROGRESS_EVERY = 2000   -- events between console progress lines


-- === Anchor =================================================================

-- FCEUX does not commit a Lua savestate until a frame boundary passes, so
-- saving and immediately reading back gives the PREVIOUS state. Advance once
-- to force the commit; the wasted frame is discarded by the load. This applies
-- everywhere below: never load a state saved since the last frame advance.
local start_state = savestate.create()
savestate.save(start_state)
emu.frameadvance()
savestate.load(start_state)

emu.speedmode("nothrottle")  -- all non-"normal" modes behave the same here

local MAX_SPEED = 40  -- hard speed cap in 1/16-px units; requires B held


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

-- Symbols name the buttons held: direction, then B, then A. "-" is no input.
-- Order is load-bearing: pop_next and Phase A both explore the LAST entry
-- first, so RB goes last to make the opening line "just run right".
local ALPHABETS = {
    powerset = { "-", "A", "B", "BA", "L", "LA", "LB", "LBA",
                 "LR", "LRA", "LRB", "LRBA", "R", "RA", "RBA", "RB" },
    no_lr    = { "-", "A", "B", "BA", "L", "LA", "LB", "LBA",
                 "R", "RA", "RBA", "RB" },
    maru     = { "LBA", "LB", "B", "RBA", "RB" },
}

local ALPHABET = ALPHABETS[ALPHABET_MODE]
assert(ALPHABET, "unknown ALPHABET_MODE: " .. tostring(ALPHABET_MODE))

local BUTTONS = { "up", "down", "left", "right", "A", "B", "select", "start" }

-- Every button must be explicitly true or false. FCEUX reads an omitted key as
-- "leave to the user", not "released", which would let buttons carry over.
local function make_input(name)
    local t = {}
    for _, b in ipairs(BUTTONS) do t[b] = false end
    if name:find("L") then t.left  = true end
    if name:find("R") then t.right = true end
    if name:find("B") then t.B     = true end
    if name:find("A") then t.A     = true end
    return t
end

local DECODE_TABLE = {}
for _, name in ipairs(ALPHABET) do DECODE_TABLE[name] = make_input(name) end

emu.print(string.format("alphabet: %s (%d symbols)", ALPHABET_MODE, #ALPHABET))


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
-- bound lower than its own successor. Audited sound for v >= -24.5; runs so
-- far reach about -5. BOUND_SAFE_MIN_VEL checks rather than trusts.
--
-- Setting ACCEL_LOW = ACCEL_HIGH is sound at every velocity but much looser:
-- measured ~5% of nodes pruned instead of ~33%, which was enough to make a
-- run non-terminating. Only reach for it if the warning below fires.
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
-- let pruning discard the true best. It is also non-increasing along a
-- lineage, which is what Phase C's stopping test relies on.
local function accel_bound(x_pos, x_vel_ub, frame)
    if x_vel_ub >= MAX_SPEED then
        return score_at(x_pos, frame)
    end
    local ramp_frames, ramp_px = ramp_to_cap(x_vel_ub)
    return score_at(x_pos + ramp_px, frame + ramp_frames)
end


-- === Heads-up display =======================================================

-- Plain numbers and prebuilt strings; the draw path never formats or walks
-- data structures.
local hud = {
    phase = "", stats = "",
    bar1 = { frac = 0, label = "", col = "#40C040" },
    bar2 = { frac = 0, label = "", col = "#C04040" },
    hist = {}, hist_max = 1,
    spark = {}, spark_max = 1,
}

local BAR_X, BAR_W, BAR_H = 4, 108, 5
local HIST_X, HIST_Y, HIST_H, HIST_BUCKETS = 4, 64, 28, 20
local SPARK_X, SPARK_Y, SPARK_H, SPARK_N = 4, 100, 18, 40

local function draw_bar(y, bar)
    local f = bar.frac
    if f < 0 then f = 0 elseif f > 1 then f = 1 end
    gui.box(BAR_X, y, BAR_X + BAR_W, y + BAR_H, "#101010", "#808080")
    local fill = math.floor(BAR_W * f)
    if fill > 1 then
        gui.box(BAR_X + 1, y + 1, BAR_X + fill, y + BAR_H - 1, bar.col, bar.col)
    end
    gui.text(BAR_X + BAR_W + 6, y - 1, bar.label)
end

local function draw_hud()
    if not SHOW_HUD then return end
    gui.text(4, 32, hud.phase)
    draw_bar(42, hud.bar1)
    draw_bar(50, hud.bar2)
    gui.text(4, 56, hud.stats)

    if SHOW_HISTOGRAM and #hud.hist > 0 then
        local w = math.floor(BAR_W / HIST_BUCKETS)
        for i = 1, #hud.hist do
            local h = math.floor(HIST_H * hud.hist[i] / hud.hist_max)
            if h > 0 then
                local x = HIST_X + (i - 1) * w
                gui.box(x, HIST_Y + HIST_H - h, x + w - 1, HIST_Y + HIST_H,
                    "#4060C0", "#4060C0")
            end
        end
        gui.text(HIST_X + BAR_W + 6, HIST_Y + HIST_H - 8, "depth")
    end

    if SHOW_SPARKLINE and #hud.spark > 1 then
        local prev
        for i = 1, #hud.spark do
            local y = SPARK_Y + SPARK_H
                    - math.floor(SPARK_H * hud.spark[i] / hud.spark_max)
            local x = SPARK_X + (i - 1) * 2
            if prev then gui.line(x - 2, prev, x, y, "#C0C040") end
            prev = y
        end
        gui.text(SPARK_X + BAR_W + 6, SPARK_Y, "frontier")
    end
end

local function spark_push(v)
    hud.spark[#hud.spark + 1] = v
    if #hud.spark > SPARK_N then table.remove(hud.spark, 1) end
    local m = 1
    for _, x in ipairs(hud.spark) do if x > m then m = x end end
    hud.spark_max = m
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
        x_vel = x_vel, x_vel_ub = x_vel_ub }
    if bound > best_score then
        best_score = bound
        best_seq = seq
        emu.print(string.format("BEST (%s) d=%d score=%.3f | %s",
            tag, depth, bound, table.concat(seq, ",")))
    end
end


-- === Phase A: frame-by-frame with dedup =====================================

local function phase_a()
    local level = { { depth = 0, sym = nil, parent = nil, state = start_state } }

    for depth = 0, HANDOFF_FRAME - 1 do
        local seen, next_level = {}, {}
        local pruned, dupes = 0, 0
        local total = #level

        hud.phase = string.format("PHASE A  frame %d/%d", depth + 1, HANDOFF_FRAME)
        hud.bar1.col, hud.bar2.col = "#40C040", "#C08040"

        for i, node in ipairs(level) do
            -- Cheap per-node HUD update; strings only, no structure walks.
            hud.bar1.frac = i / total
            hud.bar1.label = string.format("%d/%d", i, total)
            hud.bar2.frac = #next_level / MAX_LEVEL_STATES
            hud.bar2.label = string.format("%d/%d", #next_level, MAX_LEVEL_STATES)
            hud.stats = string.format("kept %d  dup %d  prune %d  best %s",
                #next_level, dupes, pruned, best_score_str())

            if i % PROGRESS_EVERY == 0 then
                emu.print(string.format("  frame %d: %d/%d kept=%d dup=%d prune=%d",
                    depth + 1, i, total, #next_level, dupes, pruned))
                spark_push(#next_level)
            end

            for _, sym in ipairs(ALPHABET) do
                savestate.load(node.state)
                joypad.set(1, DECODE_TABLE[sym])
                draw_hud()
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

        -- A wide alphabet can outrun dedup. Handing off early with a big
        -- frontier beats exploding here, so HANDOFF_FRAME is a ceiling.
        if #level > MAX_LEVEL_STATES then
            emu.print(string.format("level exceeds %d states; handing off early",
                MAX_LEVEL_STATES))
            break
        end
    end

    return level
end


-- === Phase B: hold RB to the cap ============================================

-- One fixed completion per state, no branching and no savestate churn: load
-- once, then just keep advancing. About 35 frames per state instead of the
-- ~600 a full greedy sweep costs, and in practice greedy only ever
-- rediscovered "hold right" anyway -- the discriminating work is the prefix.
local function rollout(node)
    savestate.load(node.state)
    local seq, depth = node_seq(node), node.depth

    while depth < MAX_DEPTH do
        joypad.set(1, DECODE_TABLE["RB"])
        draw_hud()
        emu.frameadvance()
        frames_stepped = frames_stepped + 1
        depth = depth + 1
        seq[#seq + 1] = "RB"

        local x_pos, x_vel, x_vel_ub = measure_state()
        check_vel(x_vel)
        if x_vel == MAX_SPEED then
            return seq, depth, x_pos, x_vel, x_vel_ub,
                accel_bound(x_pos, x_vel_ub, depth)
        end
    end
    return nil
end

local function phase_b(frontier)
    -- Best-bounded first, so the bar rises early and the skip below fires on
    -- most of the tail. Ordering only -- every state is still considered.
    table.sort(frontier, function(a, b) return a.bound > b.bound end)

    local reached, skipped = 0, 0
    hud.phase = "PHASE B  rollouts"
    hud.bar1.col, hud.bar2.col = "#40C040", "#8080C0"
    hud.hist = {}
    for i, node in ipairs(frontier) do
        -- The bound caps everything reachable from this state, so if it cannot
        -- beat the incumbent no completion from here can either.
        if node.bound <= best_score then
            skipped = skipped + 1
        else
            hud.bar1.frac = i / #frontier
            hud.bar1.label = string.format("%d/%d", i, #frontier)
            hud.bar2.frac = skipped / math.max(i, 1)
            hud.bar2.label = string.format("%d skipped", skipped)
            hud.stats = string.format("capped %d  best %s", reached, best_score_str())
            local seq, depth, x_pos, x_vel, x_vel_ub, bound = rollout(node)
            if seq then
                reached = reached + 1
                record(seq, depth, x_pos, x_vel, x_vel_ub, bound, "B")
            end
        end
        if i % 5000 == 0 then
            collectgarbage()
            emu.print(string.format("rollouts %d/%d capped=%d skipped=%d best=%s",
                i, #frontier, reached, skipped, best_score_str()))
        end
    end
    collectgarbage()
    emu.print(string.format("phase B: %d reached max speed, %d of %d skipped,"
        .. " best=%s", reached, skipped, #frontier, best_score_str()))
end


-- === Phase C: best-first ====================================================

local function phase_c(frontier)
    local heap = {}
    for _, node in ipairs(frontier) do heap_push(heap, node) end

    -- Keyed on RAM alone, not (depth, RAM): SMB keeps frame counters in RAM,
    -- so depth is already baked in. The stored depth covers the case where the
    -- same state is reached again in fewer frames.
    local seen, seen_count, seen_full = {}, 0, false
    local expansions, pruned, dupes, horizon, stopped = 0, 0, 0, 0, nil

    hud.phase = "PHASE C  best-first"
    hud.bar1.col, hud.bar2.col = "#40C040", "#C04040"
    hud.hist, hud.spark = {}, {}

    -- The heap top holds the highest bound left, and a child never bounds
    -- above its parent, so that top only falls. Phase C ends when it reaches
    -- the incumbent -- which makes the gap between them a real progress
    -- measure, not a guess. It races the frontier filling up.
    local start_top = heap[1] and heap[1].bound or 0

    local function refresh_hud()
        local top = heap[1] and heap[1].bound or best_score
        local span = start_top - best_score
        hud.bar1.frac = span > 0 and (start_top - top) / span or 1
        hud.bar1.label = string.format("%.1f>%.1f", top, best_score)
        hud.bar2.frac = #heap / MAX_FRONTIER
        hud.bar2.label = string.format("%dk/%dk",
            math.floor(#heap / 1000), math.floor(MAX_FRONTIER / 1000))
        hud.stats = string.format("exp %d  prune %d  dup %d",
            expansions, pruned, dupes)

        if SHOW_HISTOGRAM then
            local buckets, m = {}, 1
            for i = 1, HIST_BUCKETS do buckets[i] = 0 end
            for i = 1, #heap do
                local b = math.floor(heap[i].depth / MAX_DEPTH * HIST_BUCKETS) + 1
                if b < 1 then b = 1 elseif b > HIST_BUCKETS then b = HIST_BUCKETS end
                buckets[b] = buckets[b] + 1
                if buckets[b] > m then m = buckets[b] end
            end
            hud.hist, hud.hist_max = buckets, m
        end
        spark_push(#heap)
    end
    refresh_hud()

    while true do
        local node = heap_pop(heap)
        if node == nil then stopped = "frontier exhausted"; break end

        -- The heap top holds the highest bound of anything left, so if it
        -- cannot beat the incumbent then nothing can. This is the payoff of
        -- ordering by bound; Phase A has no equivalent.
        if node.bound <= best_score then
            stopped = "proved: nothing remaining can beat the incumbent"; break
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
            draw_hud()
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
                elseif depth < MAX_DEPTH then
                    local child = { depth = depth, sym = sym, parent = node,
                        bound = bound }
                    child.state = savestate.create()
                    savestate.save(child.state)
                    heap_push(heap, child)
                else
                    horizon = horizon + 1
                end
            end
        end
        emu.frameadvance()  -- commit children before any can be popped
        node.state = nil

        if expansions % HUD_REFRESH == 0 then refresh_hud() end
        if expansions % PROGRESS_EVERY == 0 then
            collectgarbage()
            emu.print(string.format("expansions=%d heap=%d pruned=%d dupes=%d best=%s",
                expansions, #heap, pruned, dupes, best_score_str()))
        end
    end

    emu.print(string.format("phase C: %s", stopped))
    emu.print(string.format("  expansions=%d heap=%d pruned=%d dupes=%d"
        .. " horizon=%d seen=%d", expansions, #heap, pruned, dupes,
        horizon, seen_count))
end


-- === Run ====================================================================

local frontier = phase_a()
emu.print(string.format("handoff with %d states", #frontier))

phase_b(frontier)
phase_c(frontier)

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

local REPORT_TOP = 20
table.sort(results, function(a, b)
    return accel_bound(a.x_pos, a.x_vel_ub, a.depth)
         > accel_bound(b.x_pos, b.x_vel_ub, b.depth)
end)
emu.print(string.format("results=%d, showing top %d", #results, REPORT_TOP))
for i = 1, math.min(REPORT_TOP, #results) do
    local r = results[i]
    emu.print(string.format("%2d. score=%.3f d=%-3d x=%.3f v=%-4d %s",
        i, accel_bound(r.x_pos, r.x_vel_ub, r.depth), r.depth, r.x_pos,
        r.x_vel, table.concat(r.seq, ",")))
end