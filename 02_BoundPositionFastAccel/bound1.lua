-- Upper bound for branch-and-bound pruning of a per-frame input search in SMB1
-- (NES, NTSC), for rightward acceleration *to max speed*.
--
-- A sequence is scored on the frame it first reaches max speed, as its x
-- projected to PROJECT_TO_FRAME at max speed (2.5 px/frame). bound_x_position()
-- is the highest score any continuation of the current state can reach: the
-- fastest possible ramp to max speed, then max speed from there on.
--
-- Scope:
--   * Comparing sequences that reach max speed by PROJECT_TO_FRAME (45 here).
--     Only then is a score Mario's real x at that frame. Pruning stays valid
--     either way, since PROJECT_TO_FRAME shifts every score equally.
--   * World 1-1 from the first frame of control: small Mario, ground area, and
--     no walls, enemies, platforms or springs within reach. The first solid
--     object is the ? block at x = 256; Mario can't pass about x = 165 in ~50
--     frames.
--
-- Branch and bound: prune on the minimum of a node's bound and its parent's.
-- Each call grants the free frames (below) afresh, even if the path already
-- spent them, so a child's bound can exceed its parent's. Both bound the same
-- continuations, so the smaller one is the true bound.

local PROJECT_TO_FRAME = 45 -- frame scores are projected to (see Scope)
local MAX_SPEED = 40 -- the speed byte $57 caps at $28
local PX_PER_FRAME_AT_MAX_SPEED = MAX_SPEED / 16 -- 2.5
local RUN_ACCEL = 0x1C8 / 256 -- $E4 doubled: the largest per-frame acceleration
local RUN_ACCEL_MIN_SPEED = 25 -- from here up, RUN_ACCEL every frame (airborne)
local WALK_ACCEL = 0x1A0 / 256 -- $D0 doubled: best below 25 (latch set)
local SLOW_WALK_ACCEL = 0x130 / 256 -- $98 doubled: best below 25 (latch clear)
local EDGE_PUSH_PX = 15 / 16 -- most the left screen edge can lift Mario

-- Free frames: the ramp's first two frames get RUN_ACCEL at any speed. A
-- turnaround (facing away from the motion, then pressing toward it with B on
-- the ground) leaves one free frame. A Left+Right double charge (a low-speed
-- skid sets the moving direction to 3, then facing turns away) leaves two. No
-- state holds more than two, and taking them first is the most generous order.
local FREE_FRAMES = 2

local rb, rbs = memory.readbyte, memory.readbytesigned

-- x in px: page, pixel, and the $0400 subpixel.
local function get_xpos()
  return rb(0x006D) * 256 + rb(0x0086) + rb(0x0400) / 256
end

-- Speed in 1/16 px per frame: signed $57 plus the $0705 fraction.
local function get_xvel()
  return rbs(0x0057) + rb(0x0705) / 256
end

-- x_pos carried from `frame` to PROJECT_TO_FRAME at max speed.
local function max_position_at_frame(x_pos, frame)
  return x_pos + (PROJECT_TO_FRAME - frame) * PX_PER_FRAME_AT_MAX_SPEED
end

-- True when the RunningSpeed latch ($0703) can't come into play, so
-- SLOW_WALK_ACCEL bounds the ramp below 25. The latch sets on a ground frame at
-- |speed| >= 28. Moving right, the ramp is already at RUN_ACCEL from 25, before
-- Mario can reach 28. Moving left, Mario can latch it and then lose that speed
-- at the screen edge, so nodes moving left don't qualify. Turning around to do
-- that from a rightward node costs far more than the latch gains back.
local function qualifies_for_slower_ramp()
  return rb(0x0703) == 0 -- latch clear
     and rb(0x0700) < 25 -- |speed| below 25, even if $0700 is stale
     and rbs(0x0057) >= 0 -- not moving left
end

-- Fastest possible ramp from speed v to max speed. Returns the distance (px)
-- covered and the frames taken before the frame that reaches max speed; that
-- frame and every later one are counted at max speed by max_position_at_frame.
-- Free frames come first and the rate never drops as speed rises, so the
-- ramp's speed is never below a real sequence's. Distance uses whole subpixels,
-- since Mario moves by $57 alone.
local function ramp_to_max_speed(v, slower)
  local walk_accel = WALK_ACCEL
  if slower then walk_accel = SLOW_WALK_ACCEL end
  -- Negative speed counts as 0: a low-speed skid (|speed| < 11) or the left
  -- screen edge can zero it in one frame.
  local speed = math.max(v, 0)
  local distance, frames = 0, 0
  while true do
    local accel = walk_accel
    if frames < FREE_FRAMES or speed >= RUN_ACCEL_MIN_SPEED then
      accel = RUN_ACCEL
    end
    speed = speed + accel
    if speed >= MAX_SPEED then break end -- counted at max speed instead
    frames = frames + 1
    local move = math.floor(speed) / 16
    -- The left edge snaps Mario's pixel but keeps his subpixel, which can leave
    -- him up to EDGE_PUSH_PX ahead of where he started (never past ground he
    -- already covered). Counting the first move as at least that covers it.
    if frames == 1 then move = math.max(move, EDGE_PUSH_PX) end
    distance = distance + move
  end
  return distance, frames
end

-- Highest score any continuation of the current state can reach (see the top
-- of the file). Exact for a node already at max speed. Reads RAM, so call it
-- while the emulator holds the node's state. When pruning, take the minimum of
-- this and the parent node's bound (see Branch and bound, at the top).
local function bound_x_position(frame, use_0x703_rule)
  local slower = use_0x703_rule and qualifies_for_slower_ramp()
  local ramp_px, ramp_frames = ramp_to_max_speed(get_xvel(), slower)
  return max_position_at_frame(get_xpos() + ramp_px, frame + ramp_frames)
end