-- Upper bound for branch-and-bound pruning of a per-frame input search in SMB1 (NES, NTSC),
-- specifically for rightward acceleration *up to max speed*.
--
-- bound3 is bound2 with two more options, each off by default; with both off it gives exactly
-- bound2's bound. Each option reads more RAM and rests on one more fact about the game:
--   use_facing_rule    456 needs Mario facing away from his motion. From speed 25 up, facing the
--                      way he moves, he gains 228 until a turnaround frame; and moving while
--                      facing the way he moves, he holds no free frames (see Facing rule)
--   use_edge_position  the left-edge push can only help while Mario is within 15/16 px of the left
--                      edge (see Edge position)
-- 10_ValidationTests checks every combination of the four options.
--
-- A sequence is scored from the frame it first reaches max speed: its x there, projected to
-- SCORING_FRAME at max speed. bound_x_position() is the highest score any continuation of the
-- current state can reach: the fastest possible ramp to max speed, then max speed from there on.
--
-- The ramp bounds every frame, not just the score: after any number of frames, no line from the
-- current state has a higher speed byte than the ramp, or has moved farther. Every part of the
-- ramp is there for that, each justified by a game mechanism, so the bound holds for any objective
-- built on speed or distance, such as x at a fixed frame.
--
-- Scope:
--   * Sequences that reach max speed by SCORING_FRAME (45 here). Only then is a score Mario's real
--     x at that frame; pruning stays valid either way, as SCORING_FRAME shifts all scores equally.
--   * World 1-1 from the first frame of control: small Mario in the ground area, with no walls,
--     enemies, platforms or springs within reach. The first solid object is the ? block at x =
--     256; at 2.5 px per frame from x = 40, Mario stays short of x = 165 for 50 frames.
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

-- === Constants ==================================================================================

local SCORING_FRAME   = 45              -- frame that scores are projected to
local MAX_SPEED       = 40              -- running cap of $57: MaxRightXSpdData $28
local MAX_SPEED_IN_PX = MAX_SPEED / 16  -- 2.5 px per frame
local RUN_ACCEL_THRES = 25              -- RUN_ACCEL every frame from here (in air, $0700 >= $19)
local RUN_ACCEL       = 456 / 256       -- $E4 doubled: the largest
local WALK_ACCEL      = 416 / 256       -- $D0 doubled: most below 25 (latch set or $0700 >= $21)
local SLOW_WALK_ACCEL = 304 / 256       -- $98 doubled: most below 25 (latch clear, $0700 < $21)
local EDGE_PUSH_PX    = 15 / 16         -- most the left-edge clamp (KeepOnscr) pushes Mario ahead

-- Free frames: the ramp's first frames get RUN_ACCEL at any speed, for bursts a state may already
-- hold. A turnaround (facing opposite the moving direction, then B plus that direction on the
-- ground) holds one, at any speed. Two need $57 = 0: the Left+Right double charge (ProcSkid copies
-- facing 3 into the moving direction, and ChkMoveDir resets it once $57 is nonzero) and the stale
-- $0700 at the left edge (KeepOnscr zeroes $57 but not $0700). The latch rule needs both too: the
-- double charge starts from a state it accepts. Counting one when $57 is nonzero rests on that
-- argument, so it's optional (do_burst_check).
local FREE_FRAMES           = 2        -- the most any state holds ($57 = 0)
local FREE_FRAMES_IF_MOVING = 1        -- the most with $57 nonzero

-- Facing rule (use_facing_rule). From 25 up, RUN_ACCEL needs facing ($33) to differ from the
-- moving direction ($45). Speed 25 is first reached on a ground frame running toward the motion
-- (in the air below 25 the walking cap of 24 holds), and that frame turns facing to match the
-- motion. Facing changes only on the ground, and only to a direction pressed: pressing back is a
-- turnaround, slowing Mario by at least TURN_DECEL; Left+Right drops him to the walking cap of 24.
-- So from 25 up the ramp has two branches, and its speed each frame is the larger:
--   forward  FORWARD_ACCEL a frame. Not below BEST_CROSSING either: a line just under 25 can still
--            spend a held burst on the frame it reaches 25, and the bound must allow that to any
--            speed a line could be at instead. Without this the bound fails frame by frame,
--            because the best rate would drop as speed rises.
--   turned   TURN_DECEL on the first frame from 25, then RUN_ACCEL every frame (in the air facing
--            back, as in fast accel). Turning on a later frame does no better than this.
-- A node already from 25 up and facing away from its motion (already_turned) is in the second
-- branch already: RUN_ACCEL every frame, as in bound2. The same fact gives the second part of the
-- rule, at any speed: a free frame is a held burst, a doubled adder, so a node moving ($57
-- nonzero) and facing the way it moves holds none (holds_no_burst). The two bursts that need $57 =
-- 0 don't apply. To double an adder it must first change facing, which the walking rate below 25
-- covers: Left+Right (152 or 208, not doubled) then a 456 burst is no more than two frames of
-- SLOW_WALK_ACCEL or WALK_ACCEL.
local FORWARD_ACCEL = 228 / 256                     -- $E4 not doubled: facing the motion
local TURN_DECEL    = 152 / 256                     -- $98 not doubled: the least a turn loses
local BEST_CROSSING = RUN_ACCEL_THRES + RUN_ACCEL   -- above any speed reached from below 25

-- Edge position (use_edge_position). KeepOnscr puts Mario's pixel on the left edge when his move
-- would take him to it or past it, and keeps his subpixel (at most 15/16 px). The edge never moves
-- left, and moves right only while Mario is 80 px or more clear of it: ScrollHandler scrolls only
-- from screen x $50, by no more than he moved. So no line ends farther right than max(x, edge +
-- EDGE_PUSH_PX) plus the moves its speeds make; once x is at least edge + EDGE_PUSH_PX, the edge
-- push adds nothing. None of this depends on where the edge is.

-- === RAM ========================================================================================

local rb, rbs = memory.readbyte, memory.readbytesigned

-- The RAM the bound reads, each byte once. Call it while the emulator holds the node's state.
--   x           Player_PageLoc, Player_X_Position, and the subpixel SprObject_X_MoveForce (px)
--   speed_byte  Player_X_Speed ($57), signed: the part of the speed that moves Mario
--   speed       $57 plus the Player_X_MoveForce fraction ($0705), as the game's 16-bit two's
--               complement (References/Handling_Signed_Velocity_Claude.md)
--   facing      PlayerFacingDir ($33): 1 right, 2 left, 3 after Left+Right
--   moving      Player_MovingDir ($45): 1 right, 2 left
--   abs_speed   Player_XSpeedAbsolute ($0700): |speed byte|, unless KeepOnscr left it stale
--   latch       RunningSpeed ($0703): nonzero once set
--   left_edge   ScreenLeft_PageLoc and ScreenLeft_X_Pos (px)
local function read_node()
  local speed_byte = rbs(0x0057)
  return {
    x          = rb(0x006D) * 256 + rb(0x0086) + rb(0x0400) / 256,
    speed_byte = speed_byte,
    speed      = speed_byte + rb(0x0705) / 256,
    facing     = rb(0x0033),
    moving     = rb(0x0045),
    abs_speed  = rb(0x0700),
    latch      = rb(0x0703),
    left_edge  = rb(0x071A) * 256 + rb(0x071C),
  }
end

-- === When each option applies ===================================================================

-- use_latch_rule: true when the RunningSpeed latch can't come into play, so SLOW_WALK_ACCEL bounds
-- the ramp below 25. GetPlayerAnimSpeed sets the latch on a ground frame with $0700 >= $1C (28).
-- Moving right, the ramp is at RUN_ACCEL from 25, before Mario can reach 28. Moving left, he can
-- set the latch and then lose that speed at the left edge, so those nodes don't qualify. Turning
-- around to do that from a rightward node costs far more than the latch gains back.
local function qualifies_for_slower_ramp(node)
  return node.latch == 0        -- latch clear
     and node.abs_speed < 25    -- |speed| below 25, and too low to set the latch even if stale
     and node.speed_byte >= 0   -- not moving left
end

-- use_facing_rule: from 25 up and facing away from the motion, so RUN_ACCEL every frame.
local function already_turned(node)
  return node.speed_byte >= RUN_ACCEL_THRES and node.facing ~= node.moving
end

-- use_facing_rule: moving and facing the way it moves, so no free frames.
local function holds_no_burst(node)
  return node.speed_byte ~= 0 and node.facing == node.moving
end

-- use_edge_position: far enough right of the left edge that the edge push can't help.
local function clear_of_left_edge(node)
  return node.x >= node.left_edge + EDGE_PUSH_PX
end

-- === The ramp ===================================================================================

-- Fastest possible ramp from speed to max speed. Returns the distance (px) and the frames up to
-- and including the frame that reaches max speed; max_position_at_frame counts every frame after
-- it. Free frames come first; that is the best order because the rate never drops as speed rises
-- (with the facing rule, BEST_CROSSING keeps it so). The ramp's speed is never below a real
-- sequence's.
--   walk_accel             the rate below 25: WALK_ACCEL, or SLOW_WALK_ACCEL (latch rule)
--   free_frames            frames of RUN_ACCEL first, at any speed
--   faces_forward_from_25  the facing rule's two branches from 25 up; false: RUN_ACCEL from 25
--   edge_push              count the first move as at least EDGE_PUSH_PX
local function ramp_to_max_speed(speed, walk_accel, free_frames, faces_forward_from_25, edge_push)
  -- Negative speed counts as 0: ProcSkid (at |speed| < 11) or KeepOnscr can zero it in one frame.
  speed = math.max(speed, 0)    -- with the facing rule, the forward branch
  local turned = nil            -- the turned branch, once it starts
  local distance, frames = 0, 0
  while speed < MAX_SPEED and not (turned and turned >= MAX_SPEED) do
    frames = frames + 1
    local before = speed
    if frames <= free_frames then
      speed = speed + RUN_ACCEL
    elseif speed < RUN_ACCEL_THRES then
      speed = speed + walk_accel
    elseif faces_forward_from_25 then
      speed = math.max(speed + FORWARD_ACCEL, BEST_CROSSING)
    else
      speed = speed + RUN_ACCEL
    end
    speed = math.min(speed, MAX_SPEED)
    if faces_forward_from_25 then
      if turned then
        turned = math.min(turned + RUN_ACCEL, MAX_SPEED)
      elseif frames > free_frames and before >= RUN_ACCEL_THRES then
        turned = before - TURN_DECEL
      end
    end
    local top = math.max(speed, turned or 0)
    -- MoveObjectHorizontally moves Mario by $57 / 16 px; the fraction never moves him.
    local move = math.floor(top) / 16
    -- KeepOnscr snaps Mario's pixel to the left edge but keeps his subpixel. That can leave him up
    -- to EDGE_PUSH_PX ahead of where he started, and later clamps never carry him past ground he
    -- already covered, so counting the first move as at least EDGE_PUSH_PX covers it.
    if frames == 1 and edge_push then move = math.max(move, EDGE_PUSH_PX) end
    distance = distance + move
  end
  return distance, frames
end

-- A position reached at max speed on frame_max_speed, carried to SCORING_FRAME at max speed.
local function max_position_at_frame(xpos_max_speed, frame_max_speed)
  return xpos_max_speed + (SCORING_FRAME - frame_max_speed) * MAX_SPEED_IN_PX
end

-- === The bound ==================================================================================

-- Highest score any continuation of the current state can reach (see the top of the file); exact
-- for a node already at max speed. Reads RAM, so call it while the emulator holds the node's
-- state. frame is the node's frame, counted as SCORING_FRAME is. Prune on the min of this and the
-- parent's bound (see Branch and bound).
--   use_latch_rule     SLOW_WALK_ACCEL below 25 when qualifies_for_slower_ramp()
--   do_burst_check     FREE_FRAMES_IF_MOVING when $57 is nonzero
--   use_facing_rule    no free frames when holds_no_burst(); from 25 up, the forward and turned
--                      branches unless already_turned() (see Facing rule)
--   use_edge_position  no edge push when clear_of_left_edge()
local function bound_x_position(frame, use_latch_rule, do_burst_check, use_facing_rule,
                                use_edge_position)
  local node = read_node()
  local walk_accel = WALK_ACCEL
  if use_latch_rule and qualifies_for_slower_ramp(node) then walk_accel = SLOW_WALK_ACCEL end
  local free_frames = FREE_FRAMES
  if do_burst_check and node.speed_byte ~= 0 then free_frames = FREE_FRAMES_IF_MOVING end
  if use_facing_rule and holds_no_burst(node) then free_frames = 0 end
  local faces_forward_from_25 = use_facing_rule and not already_turned(node)
  local edge_push = not (use_edge_position and clear_of_left_edge(node))
  local ramp_px, ramp_frames = ramp_to_max_speed(node.speed, walk_accel, free_frames,
                                                 faces_forward_from_25, edge_push)
  return max_position_at_frame(node.x + ramp_px, frame + ramp_frames)
end
