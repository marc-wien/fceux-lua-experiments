-- Upper bound for branch-and-bound pruning of a per-frame input search in SMB1
-- (NES, NTSC), specifically for rightward acceleration *up to max speed*.
--
-- A sequence is scored based on the frame it first reaches max speed, as its x
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
-- Branch and bound: prune using the *min* of a node's bound and its parent's.
-- Each call grants the free frames (below) afresh, even if the path already
-- spent them, so a child's bound can exceed its parent's. Both bound the same
-- continuations, so the smaller one is the tighter bound.

local SCORING_FRAME   = 45             -- frame that scores are projected to
local MAX_SPEED       = 40             -- the speed byte $57 caps at $28
local MAX_SPEED_IN_PX = MAX_SPEED / 16 -- 2.5
local RUN_ACCEL_THRES = 25             -- from here up, RUN_ACCEL every frame
local RUN_ACCEL       = 456 / 256      -- $E4 doubled: the largest accel
local WALK_ACCEL      = 416 / 256      -- $D0 doubled: best below 25 (latched)
local SLOW_WALK_ACCEL = 304 / 256      -- $98 doubled: best below 25 (no latch)
local EDGE_PUSH_PX    = 15 / 16        -- most the left screen edge can push

-- Free frames: the ramp's first frames get RUN_ACCEL at any speed, for bursts
-- a state may already hold. A turnaround (facing away from the motion, then
-- pressing toward it with B on the ground) holds one, at any speed. Holding
-- two needs $57 at 0: the Left+Right double charge (a low-speed skid sets the
-- moving direction to 3, which lasts only while $57 stays 0) and the stale
-- $0700 at the left edge (the edge clamp zeroes $57). No state holds more than
-- two, and they are applied immediately.
local FREE_FRAMES = 2               -- the most any state holds ($57 = 0)
local FREE_FRAMES_IF_MOVING = 1     -- the most with $57 nonzero

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
local function max_position_at_frame(xpos_max_speed, frame_max_speed)
  return xpos_max_speed + (SCORING_FRAME - frame_max_speed) * MAX_SPEED_IN_PX
end

-- True when the RunningSpeed latch ($0703) can't come into play, so
-- SLOW_WALK_ACCEL bounds the ramp below 25. The latch sets on a ground frame
-- with $0700 >= 28; $0700 is |speed|, or a stale value after the edge clamp.
-- Moving right, the ramp is already at RUN_ACCEL from 25, before Mario can
-- reach 28. Moving left, Mario can latch it and then lose that speed at the
-- screen edge, so nodes moving left don't qualify. Turning around to do that
-- from a rightward node costs far more than the latch gains back.
local function qualifies_for_slower_ramp()
  return rb(0x0703) == 0    -- latch clear
     and rb(0x0700) < 25    -- |speed| below 25, even if $0700 is stale
     and rbs(0x0057) >= 0   -- not moving left
end

-- Free frames a state at speed v can hold (see Free frames). v is as
-- get_xvel() returns it, so math.floor(v) is the speed byte $57.
local function free_frames_at(v)
  if math.floor(v) == 0 then return FREE_FRAMES end
  return FREE_FRAMES_IF_MOVING
end

-- Fastest possible ramp from speed v to max speed. Returns the distance (px)
-- covered and the frames taken before the frame that reaches max speed; that
-- frame and every later one are counted at max speed by max_position_at_frame.
-- Free frames come first and the rate never drops as speed rises, so the
-- ramp's speed is never below a real sequence's. Distance uses whole subpixels,
-- since Mario moves by $57 alone.
local function ramp_to_max_speed(xvel, slower_ramp_applies, reduced_burst_frames)
  local walk_accel = slower_ramp_applies and SLOW_WALK_ACCEL or WALK_ACCEL
  local free_frames = reduced_burst_frames and 1 or 2
  -- Negative speed counts as 0: a low-speed skid (|speed| < 11) or the left
  -- screen edge can zero it in one frame.
  local speed = math.max(xvel, 0)
  local distance, frames = 0, 0
  while true do
    local accel = (frames < free_frames or speed >= RUN_ACCEL_THRES) and walk_accel or RUN_ACCEL
    speed = speed + accel
    if speed >= MAX_SPEED then break end    -- counted at max speed instead
    frames = frames + 1
    -- The left edge snaps Mario's pixel but keeps his subpixel, which can leave
    -- him up to EDGE_PUSH_PX ahead of where he started (never past ground he
    -- already covered). Counting the first move as at least that covers it.
    local move = frames == 1 and math.max(move, EDGE_PUSH_PX) or math.floor(speed) / 16
    distance = distance + move
  end
  return distance, frames
end

-- Highest score any continuation of the current state can reach (see the top
-- of the file). Exact for a node already at max speed. Reads RAM, so call it
-- while the emulator holds the node's state. When pruning, take the minimum of
-- this and the parent node's bound (see Branch and bound, at the top).
local function bound_x_position(frame, use_latch_rule, do_burst_check)

  -- Get signed speed bytes
  local vel_byte = rbs(0x0057)
  local velocity = vel_byte + rb(0x0705) / 256
  
  -- Optional latch rule (apply 304 speed? else 416)
  local slower_ramp_applies = use_latch_rule and rb(0x0703) == 0 and rb(0x0700) < 25 and vel_byte >= 0
  
  -- Optional burst check (apply 1 burst frame? else 2)
  local reduced_burst_frames = do_burst_check and vel_byte >= 1
  
  -- Calculate fastest theoretical profile to reach max speed
  local ramp_px, ramp_frames = ramp_to_max_speed(velocity, slower_ramp_applies, reduced_burst_frames)
  
  -- Get current position
  local position = rb(0x006D) * 256 + rb(0x0086) + rb(0x0400) / 256
  
  -- Project bounded position onto specified frame
  return max_position_at_frame(position + ramp_px, frame + ramp_frames)
end
