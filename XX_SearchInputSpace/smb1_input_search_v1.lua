--
-- SMB1 frame-level input search: replay-from-anchor, branch-and-bound.
-- Setup: load the .fcs savestate at the first controllable frame with the
-- emulator paused, run this script, then unpause.
--

local start_state = savestate.create()
savestate.save(start_state)

emu.speedmode("nothrottle")  -- "maximum" is faster but disables rendering

local MAX_SPEED = 40  -- hard cap in 1/16-px units; requires B held
local PROGRESS_EVERY = 100  -- node evaluations between progress lines

-- x_vel is the exact signed byte (cap detection). x_vel_ub adds the 0x0705
-- accumulator, an unsigned byte, so it is always >= true velocity -- bound
-- input only.
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

-- RTA rules: no L+R. Fast accel is LB, B, RBA. B is held throughout: it sets
-- RunningTimer (the only route to the 40 cap) and keeps the mid frame
-- directionless without being a bare no-input frame.
-- pop_next is LIFO, so the LAST entry is explored FIRST: RB last means the
-- opening dive is all-RB, seeding a confirmed incumbent immediately.
local ALPHABET = { "LBA", "LB", "B", "RBA", "RB" }
local DECODE_TABLE = {
    B    = {B = true},
    LB   = {left  = true, B = true},
    RB   = {right = true, B = true},
    RBA  = {right = true, B = true, A = true},
    LBA  = {left  = true, B = true, A = true},
}

local PIXELS_PER_FRAME_AT_CAP = MAX_SPEED / 16  -- 2.5 px/frame
local PROJECTION_FRAME = 100  -- shared horizon; shifts all scores equally

-- Projected x_pos at PROJECTION_FRAME assuming cap speed from `frame` on.
local function score_at(x_pos, frame)
    return x_pos + (PROJECTION_FRAME - frame) * PIXELS_PER_FRAME_AT_CAP
end

-- Airborne fast-accel profile: FrictionData doubled when facing ~= moving,
-- selected on Player_XSpeedAbsolute < 25. In 1/16-px units.
-- Sound only when accelerating rightward from rest: 416 beats ACCEL_LOW
-- below 25 but needs RunningSpeed (latches at abs >= 28), unreachable on the
-- way up. If a strong branch is pruned unexpectedly, set ACCEL_LOW =
-- ACCEL_HIGH -- unconditionally sound, and isolates this as the cause.
local ACCEL_LOW    = 304 / 256
local ACCEL_HIGH   = 456 / 256
local ACCEL_SWITCH = 25

-- Idealized ramp to cap. Accelerates before moving each frame, the most
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

-- Optimistic bound: free best-case ramp to cap, then score from there.
-- Always <= score_at alone, so it is a strict tightening. Second return is
-- the ramp length, i.e. how many frames of free acceleration were granted.
local function accel_bound(x_pos, x_vel_ub, frame)
    if x_vel_ub >= MAX_SPEED then
        return score_at(x_pos, frame), 0
    end
    local ramp_frames, ramp_px = ramp_to_cap(x_vel_ub)
    return score_at(x_pos + ramp_px, frame + ramp_frames), ramp_frames
end

local CHARS_PER_LINE = 32  -- approximate; tune to your screen
local LINE_HEIGHT = 8

-- Wraps on symbol boundaries. Returns line count for stacking text below.
-- Currently only used by the commented-out overlay in replay().
local function draw_seq(x, y, seq)
    local line, line_num = "", 0
    for i = 1, #seq do
        local piece = (line == "" and seq[i]) or ("," .. seq[i])
        if #line + #piece > CHARS_PER_LINE then
            gui.text(x, y + line_num * LINE_HEIGHT, line)
            line_num = line_num + 1
            line = seq[i]
        else
            line = line .. piece
        end
    end
    if line ~= "" then
        gui.text(x, y + line_num * LINE_HEIGHT, line)
        line_num = line_num + 1
    end
    return line_num
end

-- Incumbent.
local best_score = -math.huge
local best_seq = nil

local function best_score_str()
    return best_score == -math.huge and "none" or string.format("%.3f", best_score)
end

-- Replays a sequence from the anchor. The only savestate use anywhere:
-- branching is over input strings, never over saved engine states.
local function replay(seq)
    savestate.load(start_state)

    local x_pos, x_vel, x_vel_ub = measure_state()
    local pos_at_max_speed, frame_at_max_speed = nil, nil

    for i = 1, #seq do
        joypad.set(1, DECODE_TABLE[seq[i]])

        -- Overlay: state here is after i-1 frames, so score at frame i-1.
        -- local live = accel_bound(x_pos, x_vel_ub, i - 1)
        -- gui.text(4, 32, string.format("score: %.3f", live))
        -- local y = 40 + draw_seq(4, 40, seq) * LINE_HEIGHT + LINE_HEIGHT
        -- gui.text(4, y, "best: " .. best_score_str())
        -- if best_seq then draw_seq(4, y + LINE_HEIGHT, best_seq) end

        emu.frameadvance()
        x_pos, x_vel, x_vel_ub = measure_state()

        -- Rightward cap only: scoring assumes the branch is closing on the
        -- goal, which does not hold at -40.
        if pos_at_max_speed == nil and x_vel == MAX_SPEED then
            pos_at_max_speed   = x_pos
            frame_at_max_speed = i
        end
    end

    return {
        final_x_pos        = x_pos,
        final_x_vel        = x_vel,
        final_x_vel_ub     = x_vel_ub,
        pos_at_max_speed   = pos_at_max_speed,
        frame_at_max_speed = frame_at_max_speed,
    }
end

local function push_node(frontier, node)
    frontier[#frontier + 1] = node
end

-- LIFO for now; swap for a heap pop to get best-first.
local function pop_next(frontier)
    local n = #frontier
    if n == 0 then return nil end
    local node = frontier[n]
    frontier[n] = nil
    return node
end

-- Lua 5.1 in FCEUX: no table.unpack.
local function copy_seq(seq)
    local copy = {}
    for i = 1, #seq do
        copy[i] = seq[i]
    end
    return copy
end

local function search(max_depth)
    local frontier = {}
    local results = {}
    push_node(frontier, { seq = {}, depth = 0 })

    best_score = -math.huge
    best_seq = nil
    local pruned_count, capped_count, evaluated = 0, 0, 0

    while true do
        local node = pop_next(frontier)
        if node == nil then break end

        local r = replay(node.seq)
        evaluated = evaluated + 1

        if evaluated % PROGRESS_EVERY == 0 then
            emu.print(string.format("[%d] pruned=%d capped=%d best=%s | d=%d %s",
                evaluated, pruned_count, capped_count, best_score_str(),
                node.depth, table.concat(node.seq, ",")))
        end

        local bound = accel_bound(r.final_x_pos, r.final_x_vel_ub, node.depth)
        -- <= keeps one representative of a tie: a tie cannot beat the
        -- incumbent, so dropping it cannot lose the true best.
        local dominated = bound <= best_score
        local reached_cap = r.frame_at_max_speed == node.depth

        -- Only confirmed cap events raise the incumbent; a bound is
        -- optimistic and must never promote itself.
        if reached_cap and not dominated then
            emu.print(string.format("BEST d=%d score=%.3f | %s",
                node.depth, bound, table.concat(node.seq, ",")))
            best_score = bound
            best_seq = node.seq
        end

        if dominated then
            pruned_count = pruned_count + 1
        elseif reached_cap then
            -- At cap the remainder is determined by score_at; further frames
            -- cannot reveal anything new.
            capped_count = capped_count + 1
            r.seq = node.seq
            results[#results + 1] = r
        elseif node.depth == max_depth then
            r.seq = node.seq
            results[#results + 1] = r
        else
            for _, sym in ipairs(ALPHABET) do
                local child_seq = copy_seq(node.seq)
                child_seq[#child_seq + 1] = sym
                push_node(frontier, { seq = child_seq, depth = node.depth + 1 })
            end
        end
    end

    emu.print(string.format(
        "nodes evaluated: %d, %d pruned, %d capped (full tree would be %g)",
        evaluated, pruned_count, capped_count,
        ((#ALPHABET) ^ (max_depth + 1) - 1) / (#ALPHABET - 1)))

    return results
end

local results = search(50)

-- Rows mix capped-early and full-depth nodes, so final_x is not on a common
-- horizon; max_speed_pos/@frame are the comparable pair.
for _, r in ipairs(results) do
    emu.print(string.format(
        "seq=%-15s final_x=%.3f final_v=%d  max_speed_pos=%s @frame=%s",
        table.concat(r.seq, ","),
        r.final_x_pos,
        r.final_x_vel,
        r.pos_at_max_speed and string.format("%.3f", r.pos_at_max_speed) or "never",
        r.frame_at_max_speed or "-"
    ))
end