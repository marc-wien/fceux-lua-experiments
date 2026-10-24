local PROJECT_TO_FRAME          = 1000          -- frame you want the bound for
local MAX_SPEED                 = 40            -- $57 never exceeds $28
local PX_PER_FRAME_AT_MAX_SPEED = MAX_SPEED / 16 -- 2.5
local WALK_MAX                  = 24            -- walking cap; below it, only walk adders sustain
local RUN_ACCEL                 = 0x1C8 / 256   -- $E4 x2: largest per-frame gain the game applies
local WALK_ACCEL                = 0x1A0 / 256   -- $D0 x2: best sustained gain below 24
local SLOW_WALK_ACCEL           = 0x130 / 256   -- $98 x2: same, while RunningSpeed = 0
local EDGE_PUSH_PX              = 15 / 16       -- left-screen-edge clamp, once per window

local rb, rbs = memory.readbyte, memory.readbytesigned

local function get_xpos()
  return rb(0x006D) * 256 + rb(0x0086) + rb(0x0400) / 256
end

local function get_xvel()
  return rbs(0x0057) + rb(0x0705) / 256
end

local function max_position_at_frame(frame)
  return get_xpos() + (PROJECT_TO_FRAME - frame) * PX_PER_FRAME_AT_MAX_SPEED
end

-- RunningSpeed ($0703) unlatched, and nothing that could latch it soon.
local function qualifies_for_slower_ramp()
  return rb(0x0703) == 0           -- RunningSpeed clear
     and rb(0x0700) < 25           -- |speed| < 25, so no stale fast-air burst
     and rbs(0x0057) >= 0          -- not moving left (running left can latch $0703)
end

-- Fastest possible ramp from speed v up to max speed, cut off at frame_limit.
-- Returns the distance (px) covered while below max speed, and how many frames that took.
local function ramp_to_max_speed(v, slower, frame_limit)
  local walk_accel = slower and SLOW_WALK_ACCEL or WALK_ACCEL
  local bursts     = slower and 1 or 2   -- opening frames allowed RUN_ACCEL below 24
  local speed      = math.max(v, 0)      -- negative speed can be zeroed at once
  local distance, frames = 0, 0
  while frames < frame_limit do
    local accel = (frames < bursts or speed >= WALK_MAX) and RUN_ACCEL or walk_accel
    speed = speed + accel
    if speed >= MAX_SPEED then break end -- this frame already moves at max speed
    frames   = frames + 1
    distance = distance + math.floor(speed) / 16
  end
  return distance, frames
end

local function bound_x_position(frame, use_0x703_rule)
  local frames_left = PROJECT_TO_FRAME - frame
  if frames_left <= 0 then return get_xpos() end
  local slower = use_0x703_rule and qualifies_for_slower_ramp()
  local ramp_px, ramp_frames = ramp_to_max_speed(get_xvel(), slower, frames_left)
  return max_position_at_frame(frame + ramp_frames) + ramp_px + EDGE_PUSH_PX
end