-- Upper bound for branch-and-bound pruning of a per-frame input search in SMB1 (NES, NTSC),
-- specifically for rightward acceleration *up to max speed*.
--
-- A sequence is scored from the frame it first reaches max speed: its x there, projected to
-- SCORING_FRAME at max speed. bound_x_position() is the highest score any continuation of the
-- current state can reach: the fastest possible ramp to max speed, then max speed from there on.
--
-- Scope:
--   * Sequences that reach max speed by SCORING_FRAME (45 here). Only then is a score Mario's real
--     x at that frame; pruning stays valid either way, as SCORING_FRAME shifts all scores equally.
--   * World 1-1 from the first frame of control: small Mario in the ground area, with no walls,
--     enemies, platforms or springs within reach. The first solid object is the ? block at
--     x = 256; at 2.5 px per frame from x = 40, Mario stays short of x = 165 for 50 frames.
--
-- Branch and bound: prune on the *min* of a node's bound and its parent's. Each call grants the
-- free frames (below) afresh, even if the path already spent them, so a child's bound can exceed
-- its parent's. Both bound the same continuations, so the smaller one is the tighter bound.
--
-- Units: x in px; speeds in units of the speed byte $57 (1/16 px per frame), fraction included.
-- Accelerations are FrictionData bytes, doubled: PlayerPhysicsSub doubles them while facing
-- differs from the moving direction. RAM names and routines are SMBDIS.ASM's
-- (References/SMBDIS.ASM.txt). 10_ValidationTests checks each rule here against a model of the
-- game, and the model against the ROM.

local SCORING_FRAME   = 45             -- frame that scores are projected to
local MAX_SPEED       = 40             -- running cap of $57: MaxRightXSpdData $28
local MAX_SPEED_IN_PX = MAX_SPEED / 16 -- 2.5 px per frame
local RUN_ACCEL_THRES = 25             -- RUN_ACCEL every frame from here (in air, $0700 >= $19)
local RUN_ACCEL       = 456 / 256      -- $E4 doubled: the largest
local WALK_ACCEL      = 416 / 256      -- $D0 doubled: most below 25 (latch set or $0700 >= $21)
local SLOW_WALK_ACCEL = 304 / 256      -- $98 doubled: most below 25 (latch clear, $0700 < $21)
local EDGE_PUSH_PX    = 15 / 16        -- most the left-edge clamp (KeepOnscr) pushes Mario ahead

-- Free frames: the ramp's first frames get RUN_ACCEL at any speed, for bursts a state may already
-- hold. A turnaround (facing opposite the moving direction, then B plus that direction on the
-- ground) holds one, at any speed. Two need $57 = 0: the Left+Right double charge (ProcSkid copies
-- facing 3 into the moving direction, and ChkMoveDir resets it once $57 is nonzero) and the stale
-- $0700 at the left edge (KeepOnscr zeroes $57 but not $0700). Counting one when $57 is nonzero
-- rests on that argument, so it's optional (do_burst_check).
local FREE_FRAMES           = 2        -- the most any state holds ($57 = 0)
local FREE_FRAMES_IF_MOVING = 1        -- the most with $57 nonzero

local rb, rbs = memory.readbyte, memory.readbytesigned

-- x in px: Player_PageLoc, Player_X_Position, and the subpixel SprObject_X_MoveForce.
local function get_xpos()
  return rb(0x006D) * 256 + rb(0x0086) + rb(0x0400) / 256
end

-- Speed: signed Player_X_Speed ($57) plus the Player_X_MoveForce fraction, as the game's 16-bit
-- two's complement (References/Handling_Signed_Velocity_Claude.md). Its floor is $57.
local function get_xvel()
  return rbs(0x0057) + rb(0x0705) / 256
end

-- A position reached at max speed on frame_max_speed, carried to SCORING_FRAME at max speed.
local function max_position_at_frame(xpos_max_speed, frame_max_speed)
  return xpos_max_speed + (SCORING_FRAME - frame_max_speed) * MAX_SPEED_IN_PX
end

-- True when the RunningSpeed latch ($0703) can't come into play, so SLOW_WALK_ACCEL bounds the
-- ramp below 25. GetPlayerAnimSpeed sets the latch on a ground frame with $0700 >= $1C (28), and
-- $0700 is |speed| unless KeepOnscr left it stale. Moving right, the ramp is at RUN_ACCEL from 25,
-- before Mario can reach 28. Moving left, he can set the latch and then lose that speed at the
-- left edge, so those nodes don't qualify. Turning around to do that from a rightward node costs
-- far more than the latch gains back.
local function qualifies_for_slower_ramp()
  return rb(0x0703) == 0    -- latch clear
     and rb(0x0700) < 25    -- |speed| below 25, and too low to set the latch even if stale
     and rbs(0x0057) >= 0   -- not moving left
end

-- Fastest possible ramp from speed xvel to max speed. Returns the distance (px) and the frames up
-- to and including the frame that reaches max speed; max_position_at_frame counts every frame
-- after it. Free frames come first and the rate never drops as speed rises, so the ramp's speed is
-- never below a real sequence's.
local function ramp_to_max_speed(xvel, slower_ramp_applies, reduced_burst_frames)
  local walk_accel = slower_ramp_applies and SLOW_WALK_ACCEL or WALK_ACCEL
  local free_frames = reduced_burst_frames and FREE_FRAMES_IF_MOVING or FREE_FRAMES
  -- Negative speed counts as 0: ProcSkid (at |speed| < 11) or KeepOnscr can zero it in one frame.
  local speed = math.max(xvel, 0)
  local distance, frames = 0, 0
  while speed < MAX_SPEED do
    frames = frames + 1
    local run = frames <= free_frames or speed >= RUN_ACCEL_THRES
    speed = math.min(speed + (run and RUN_ACCEL or walk_accel), MAX_SPEED)
    -- MoveObjectHorizontally moves Mario by $57 / 16 px; the fraction never moves him.
    local move = math.floor(speed) / 16
    -- KeepOnscr snaps Mario's pixel to the left edge but keeps his subpixel. That can leave him up
    -- to EDGE_PUSH_PX ahead of where he started, and later clamps never carry him past ground he
    -- already covered, so counting the first move as at least EDGE_PUSH_PX covers it.
    if frames == 1 then move = math.max(move, EDGE_PUSH_PX) end
    distance = distance + move
  end
  return distance, frames
end

-- Highest score any continuation of the current state can reach (see the top of the file); exact
-- for a node already at max speed. Reads RAM, so call it while the emulator holds the node's
-- state. frame is the node's frame, counted as SCORING_FRAME is. Prune on the min of this and the
-- parent's bound (see Branch and bound).
--   use_latch_rule  SLOW_WALK_ACCEL below 25 when qualifies_for_slower_ramp()
--   do_burst_check  FREE_FRAMES_IF_MOVING when $57 is nonzero
local function bound_x_position(frame, use_latch_rule, do_burst_check)
  local xvel = get_xvel()
  local slower_ramp_applies = use_latch_rule and qualifies_for_slower_ramp()
  local reduced_burst_frames = do_burst_check and math.floor(xvel) ~= 0
  local ramp_px, ramp_frames = ramp_to_max_speed(xvel, slower_ramp_applies, reduced_burst_frames)
  return max_position_at_frame(get_xpos() + ramp_px, frame + ramp_frames)
end
