--
-- Manually load the FCS savestate file with the emulator paused, then run this, then unpause
--
local start_state = savestate.create()
savestate.save(start_state)

emu.speedmode("nothrottle")  -- "maximum" is faster but disables rendering

local function measure_state()
    local page  = memory.readbyte(0x006D)
    local pixel = memory.readbyte(0x0086)
    local sub   = memory.readbyte(0x0400)
    local x_pos = page * 256 + pixel + (sub / 256)
    local x_vel = memory.readbytesigned(0x0057)
    return x_pos, x_vel
end

do
    savestate.load(start_state)
    local x_pos, x_vel = measure_state()
    emu.print(string.format("Anchor check: x_pos=%.4f x_vel=%d", x_pos, x_vel))
end

local ALPHABET = { "N", "L", "R", "RA", "RB" }
local DECODE_TABLE = {
    N = {},
    L   = {left  = true},
    R   = {right = true},
    RA  = {right = true, A = true},
    RB  = {right = true, B = true},
}

local CHARS_PER_LINE = 32  -- approximate; tune to your screen
local LINE_HEIGHT = 8

-- Wraps on symbol boundaries so multi-char symbols never split.
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
    end
end

local MAX_SPEED = 40  -- hard cap, requires B held

local function replay(seq)
    savestate.load(start_state)

    local x_pos, x_vel = measure_state()
    local pos_at_max_speed, frame_at_max_speed = nil, nil

    for i = 1, #seq do
        joypad.set(1, DECODE_TABLE[seq[i]])
        draw_seq(4, 40, seq)
        emu.frameadvance()
        x_pos, x_vel = measure_state()

        -- Rightward cap only: the dominance projection assumes the branch is
        -- already closing on the goal, which doesn't hold at -40.
        if pos_at_max_speed == nil and x_vel == MAX_SPEED then
            pos_at_max_speed   = x_pos
            frame_at_max_speed = i
        end
    end

    return {
        final_x_pos        = x_pos,
        final_x_vel        = x_vel,
        pos_at_max_speed   = pos_at_max_speed,
        frame_at_max_speed = frame_at_max_speed,
    }
end

local PIXELS_PER_FRAME_AT_CAP = MAX_SPEED / 16  -- x_vel byte is 1/16 px

-- Frames to reach a fixed future X, minus the shared X/rate term that cancels
-- across branches. Higher = reaches any rightward target sooner.
local function dominance_score(r)
    return r.pos_at_max_speed - r.frame_at_max_speed * PIXELS_PER_FRAME_AT_CAP
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

local function brute_force(max_depth)
    local frontier = {}
    local results = {}
    push_node(frontier, { seq = {}, depth = 0 })

    local best_dominance_score = -math.huge
    local pruned_count = 0

    while true do
        local node = pop_next(frontier)
        if node == nil then break end

        local r = replay(node.seq)

        -- Scored before the leaf/internal split so leaves also raise the
        -- incumbent; under DFS they're where good scores appear first.
        local score = r.pos_at_max_speed and dominance_score(r) or nil
        local dominated = score ~= nil and score < best_dominance_score
        if score ~= nil and not dominated then
            best_dominance_score = score
        end

        if node.depth == max_depth then
            r.seq = node.seq
            results[#results + 1] = r
        elseif dominated then
            pruned_count = pruned_count + 1
            emu.print(string.format("PRUNED seq=%-15s score=%.3f < best=%.3f",
                table.concat(node.seq, ","), score, best_dominance_score))
        else
            for _, sym in ipairs(ALPHABET) do
                local child_seq = copy_seq(node.seq)
                child_seq[#child_seq + 1] = sym
                push_node(frontier, { seq = child_seq, depth = node.depth + 1 })
            end
        end
    end

    return results, pruned_count
end

local results, pruned_count = brute_force(50)

emu.print(string.format("brute_force finished: %d results, %d branches pruned by dominance",
    #results, pruned_count))

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