-- Upper bound on Mario's x-position, for branch-and-bound pruning of a per-frame
-- input search in SMB (NES, NTSC). Valid only for World 1-1 from the first frame of
-- control: small Mario, ground area, player control routine running, and no walls,
-- enemies, platforms or springs within reach (the first solid object is the ? block
-- at x = 256, and Mario can't pass about x = 165 in ~50 frames).

local PROJECT_TO_FRAME = 0 -- target frame; 0 gives a frame-normalized score
local MAX_SPEED = 40 -- $57 never exceeds $28
local PX_PER_FRAME_AT_MAX_SPEED = MAX_SPEED / 16 -- 2.5
local RUN_ACCEL_MIN_SPEED = 25 -- airborne $E4 needs $0700 >= $19; below, bursts only
local RUN_ACCEL = 0x1C8 / 256 -- $E4 x2: largest gain ImposeFriction applies in a frame
local WALK_ACCEL = 0x1A0 / 256 -- $D0 x2: best sustained gain below 25
local SLOW_WALK_ACCEL = 0x130 / 256 -- $98 x2: same, while RunningSpeed can't latch
local EDGE_PUSH_PX = 15 / 16 -- most the left-edge clamp can lift Mario ($0400 <= $F0)

-- RUN_ACCEL frames a state can bank below 25 ("credits"), never more than two:
--   one while facing ($33) ~= moving dir ($45), including the start, where $45 = 0;
--   two after a double charge (a skid sets moving dir 3, then facing turns away);
--   one for a stale $0700 >= 25 left by an edge clamp.
-- Front-loading two is safe: in 1/256 units, max(v, 0) + (456 - s) * credits grows by
-- at most s per frame (s = walk accel in use), averaged over skid setups and clamps.
local BURSTS = 2

local rb, rbs = memory.readbyte, memory.readbytesigned

-- x in px: page, pixel, and the $0400 subpixel.
local function get_xpos()
  return rb(0x006D) * 256 + rb(0x0086) + rb(0x0400) / 256
end

-- Speed in 1/16 px per frame: signed $57 plus the $0705 fraction.
local function get_xvel()
  return rbs(0x0057) + rb(0x0705) / 256
end

-- x_pos projected from `frame` to PROJECT_TO_FRAME at max speed.
-- If PROJECT_TO_FRAME < frame, this subtracts max-speed travel instead of adding it.
local function max_position_at_frame(x_pos, frame)
  return x_pos + (PROJECT_TO_FRAME - frame) * PX_PER_FRAME_AT_MAX_SPEED
end

-- True when RunningSpeed ($0703) can't latch in time to matter, so SLOW_WALK_ACCEL
-- bounds the ramp below 25. The latch sets on a ground frame with $0700 >= 28.
-- Moving right, the bound passes 28 first and is at RUN_ACCEL from 25 on. Moving
-- left, Mario can latch it and then lose the speed at the screen edge, hence the
-- sign test. A node moving right could still turn around and do that, but reaching
-- speed -28 takes 16+ frames (40 px at max speed), and the latch gains back ~8 px.
local function qualifies_for_slower_ramp()
  return rb(0x0703) == 0 -- RunningSpeed clear
     and rb(0x0700) < 25 -- |speed| < 25, maybe stale: no stale latch, $D0, or air burst
     and rbs(0x0057) >= 0 -- not moving left
end

-- Fastest possible ramp from speed v up to max speed.
-- Returns the distance (px) covered while below max speed, and how many frames that took.
-- Its speed stays >= any real speed every frame: bursts come first, and the step only
-- grows with speed. Distance floors speed, since only $57 moves Mario.
local function ramp_to_max_speed(v, slower)
  local walk_accel = slower and SLOW_WALK_ACCEL or WALK_ACCEL
  -- No negative speed beats 0: a skid ($0700 < 11) clears $57 and $0705 before that
  -- frame's accel, and the edge clamp clears $57 after it (unless Right alone is
  -- held), leaving speed < 1.
  local speed = math.max(v, 0)
  local distance, frames = 0, 0
  while true do
    local accel = (frames < BURSTS or speed >= RUN_ACCEL_MIN_SPEED) and RUN_ACCEL or walk_accel
    speed = speed + accel
    if speed >= MAX_SPEED then break end -- this frame already moves at max speed
    frames = frames + 1
    local move = math.floor(speed) / 16
    -- A clamp can't put Mario more than EDGE_PUSH_PX past his start or past ground he
    -- already covered (scrolling keeps the edge 80+ px behind him), and later frames
    -- are covered by their own moves. A first frame that reaches max speed already
    -- moves 2.5 px, so it needs no edge term.
    if frames == 1 then move = math.max(move, EDGE_PUSH_PX) end
    distance = distance + move
  end
  return distance, frames
end

-- Upper bound on x at PROJECT_TO_FRAME when that's at least a full ramp away; for any
-- PROJECT_TO_FRAME, a score that ranks nodes consistently. Exact for a node already at
-- max speed. Reads RAM, so call it with the emulator at the node's state.
local function bound_x_position(frame, use_0x703_rule)
  local slower = use_0x703_rule and qualifies_for_slower_ramp()
  local ramp_px, ramp_frames = ramp_to_max_speed(get_xvel(), slower)
  return max_position_at_frame(get_xpos() + ramp_px, frame + ramp_frames)
end