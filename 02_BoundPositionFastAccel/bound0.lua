local MAX_SPEED = 40          -- x speed cap while running, in 1/16 px/frame
local PX_PER_FRAME_AT_CAP = MAX_SPEED / 16
local PROJECTION_FRAME = 45   -- score = projected x-position at this frame

-- Fastest acceleration the game allows, in speed units per frame. Each is
-- a FrictionData entry, doubled when facing ~= moving direction.
local ACCEL_RUN  = 456 / 256  -- $E4 x2: running, or airborne at 25+
local ACCEL_SLOW = 416 / 256  -- $D0 x2: below 25, RunningSpeed latch set
local ACCEL_SWITCH = 25       -- speed where the top rate opens up
local FREE_FRAMES = 2         -- top-rate bursts a state can hold in reserve
local EDGE_PX = 15 / 16       -- most the left screen edge can lift Mario

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

-- Optional (USE_RAM_RULE): read RAM to use 304 below 25. 416 needs the
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

-- The slow rate for the state the emulator holds right now: slow_rate()
-- with USE_RAM_RULE, otherwise always ACCEL_SLOW (speed alone).
local function current_slow_rate()
    return USE_RAM_RULE and slow_rate() or ACCEL_SLOW
end