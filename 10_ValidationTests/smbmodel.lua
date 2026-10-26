-- smbmodel.lua
-- Variant: reference model, one frame of Mario's horizontal physics
--
-- One frame of Mario's left-right movement in Super Mario Bros. (NTSC), as
-- the game's code computes it, written from the SMBDIS.ASM disassembly in
-- References/. Names in CamelCase below are its labels.
--
-- Scope: small Mario, on land (not water), in normal play (the player
-- control routine, GameEngineSubroutine = 8), with no wall, block,
-- platform or vine touching him. The 1-1 opening is such a place.
--
-- How this file is used:
--   smb1_rom_validation.lua  checks it against the real ROM in FCEUX
--   smb1_model_validation.lua  uses it to check the acceleration bound
--
-- Units. The model holds Mario's speed as one signed number,
--   speed = 256 * $57 + $0705
-- where $57 (Player_X_Speed) is the speed byte, in subpixels (1/16 px) per
-- frame, and $0705 (Player_X_MoveForce) is its fraction. So 256 is one
-- subpixel per frame, and an acceleration of 456 adds 456/256 of a
-- subpixel per frame, each frame. Only the speed byte moves Mario: each
-- frame his position changes by speed byte / 16 px.
--
-- What the model does not simulate. Instead of simulating these, it takes
-- them as inputs, so a caller can try every case:
--   - whether the frame starts on the ground, and whether a jump starts
--     (vertical motion is not modeled);
--   - whether RunningTimer still allows running without B;
--   - whether the left screen edge clamps Mario this frame (his position
--     is not modeled).

local SM = {}
local floor = math.floor

SM.SPEED_MIN = -40 * 256         -- -10240: full speed left, fraction 0
SM.SPEED_MAX = 40 * 256 + 252    -- 10492: full speed right, top fraction
SM.FRACTION_STEP = 4             -- every adder is a multiple of 4

-- FrictionData: the adders (accelerations) the game chooses from.
local RUN_ADD = 0xE4             -- 228: running
local WALK_ADD = 0x98            -- 152: walking
local WALK_ADD_FAST = 0xD0       -- 208: walking with the latch set
-- MaxRightXSpdData / MaxLeftXSpdData: the speed caps on land.
local RUN_CAP = 0x28             -- 40
local WALK_CAP = 0x18            -- 24

-- Split speed into the signed speed byte and the fraction (0-255).
local function split(speed)
  local byte = floor(speed / 256)
  return byte, speed - 256 * byte
end
SM.split = split

-- SM.step: one frame.
--
-- In, the state at the start of the frame:
--   speed      256 * $57 + $0705 (see Units)
--   facing     $33 PlayerFacingDir: 1 right, 2 left, 3 after Left+Right
--   moving     $45 Player_MovingDir: 1 right, 2 left; 0 or 3 only while
--              the speed byte is 0
--   abs        $0700 Player_XSpeedAbsolute, as the game last wrote it. It
--              can be stale: the left edge can zero the speed byte after
--              it was written.
--   latch      $0703 RunningSpeed is nonzero
--   on_ground  $1D Player_State is 0
-- In, this frame:
--   lr         Left/Right as pressed: 0 none, 1 Right, 2 Left, 3 both
--   down       Down is held
--   other      B, Up or Select is held (a button other than A, Left,
--              Right and Down)
--   run_ok     B is held, or RunningTimer ($0783) is 2 or more before the
--              frame (it counts down once before the game logic runs)
--   jump       A is newly pressed while on the ground
--   pinned     the left screen edge clamps Mario this frame (KeepOnscr)
-- Out, in this order:
--   speed, facing, moving, abs, latch   the state at the end of the frame
--   move_speed  the speed that moved Mario this frame (an edge clamp can
--               zero the speed byte afterwards)
--   airborne    the frame used the air rules (already in the air, or a
--               jump started this frame)
--   running     the running rules applied (cap 40, adder 228)
--   lr_used     Left/Right after Down cancelled them
--   adder       the acceleration chosen, after any doubling
--   applied     whether adder was added or subtracted this frame
-- Returns nil when `pinned` is impossible: the speed byte is 16 or more,
-- so Mario moved at least a pixel to the right of the edge.
function SM.step(speed, facing, moving, abs, latch, on_ground,
                 lr, down, other, run_ok, jump, pinned)
  local byte, frac = split(speed)

  -- On the ground, Down cancels Left/Right for the acceleration and
  -- facing code. The latch and skid checks below read the raw buttons.
  local lr_used = lr
  if on_ground and down and lr_used ~= 0 then lr_used = 0 end

  -- A jump starts before the acceleration is chosen (ProcJumping runs
  -- before X_Physics), so the jump frame already uses the air rules.
  local airborne = (not on_ground) or jump

  -- X_Physics: choose the speed cap and the adder.
  local running
  if airborne then
    running = (abs >= 25)                       -- $0700 >= $19
  else
    running = (lr_used == moving) and run_ok    -- toward the motion
  end
  local cap_right, cap_left, adder
  if running then
    cap_right, cap_left, adder = RUN_CAP, -RUN_CAP, RUN_ADD
  else
    cap_right, cap_left = WALK_CAP, -WALK_CAP
    if latch or abs >= 33 then                  -- latch, or $0700 >= $21
      adder = WALK_ADD_FAST
    else
      adder = WALK_ADD
    end
  end
  -- The adder doubles when Mario faces away from his motion (asl/rol of
  -- FrictionAdderLow/High). This is the basis of fast acceleration.
  if facing ~= moving then adder = 2 * adder end

  local new_facing, new_moving, new_latch = facing, moving, latch
  if not airborne then
    -- GetPlayerAnimSpeed, which runs on ground frames only.
    if abs >= 28 then                           -- $0700 >= $1C
      new_latch = true
    elseif lr ~= 0 or down or other then        -- any button except A
      if lr == moving then
        new_latch = false                       -- pressing toward motion
      elseif abs < 11 then                      -- $0700 < $0B: ProcSkid
        new_moving = facing
        byte, frac = 0, 0                       -- speed reset to zero
      end
    end
    -- Facing follows Left/Right, on the ground only.
    if lr_used ~= 0 then new_facing = lr_used end
  end

  -- ImposeFriction: always on the ground; in the air only while Left or
  -- Right is held.
  local new_abs, applied = abs, false
  if (not airborne) or lr_used ~= 0 then
    local dir
    if lr_used == 0 then
      -- No direction: slow toward zero. The test reads the speed byte
      -- only, so at byte 0 nothing happens, whatever the fraction.
      if byte > 0 then dir = -1 elseif byte < 0 then dir = 1 else dir = 0 end
    elseif lr_used % 2 == 1 then
      dir = 1                                   -- Right, or Left+Right
    else
      dir = -1                                  -- Left
    end
    if dir ~= 0 then
      applied = true
      byte, frac = split(byte * 256 + frac + dir * adder)
      -- The caps rewrite the speed byte only; the fraction is kept.
      if dir == 1 and byte >= cap_right then byte = cap_right end
      if dir == -1 and byte < cap_left then byte = cap_left end
    end
    new_abs = (byte < 0) and -byte or byte      -- SetAbsSpd
  end
  local move_speed = byte * 256 + frac

  -- The moving direction follows the sign of a nonzero speed byte.
  if byte > 0 then new_moving = 1 elseif byte < 0 then new_moving = 2 end

  -- KeepOnscr: at the left edge the game puts Mario back on the edge and
  -- zeroes the speed byte unless exactly Right is held. It keeps the
  -- fraction, $0700 and the moving direction.
  if pinned then
    if byte >= 16 then return nil end
    if lr_used ~= 1 then byte = 0 end
  end

  return byte * 256 + frac, new_facing, new_moving, new_abs, new_latch,
         move_speed, airborne, running, lr_used, adder, applied
end

-- SM.in_set: the states the model covers. smb1_model_validation.lua checks
-- that SM.step never leaves this set; smb1_rom_validation.lua checks that
-- real play never leaves it.
--   - the fraction is a multiple of 4 (every adder is), and the speed lies
--     between SPEED_MIN and SPEED_MAX; abs is at most 40
--   - a nonzero speed byte: abs equals its size, and moving is its sign
--   - speed byte 0: abs is below 16, or Mario is moving left (only a run
--     left into the edge zeroes the byte while abs is that high)
function SM.in_set(speed, facing, moving, abs, latch)
  if speed % 4 ~= 0 or speed < SM.SPEED_MIN or speed > SM.SPEED_MAX
     or abs > 40 then
    return false
  end
  local byte = floor(speed / 256)
  if byte ~= 0 then
    return abs == ((byte < 0) and -byte or byte)
       and moving == ((byte > 0) and 1 or 2)
  end
  return abs < 16 or moving == 2
end

-- SM.states: every state in the set, as a list of
-- {speed, facing, moving, abs, latch}, in a fixed order.
function SM.states()
  local list = {}
  for speed = SM.SPEED_MIN, SM.SPEED_MAX, SM.FRACTION_STEP do
    for facing = 1, 3 do
      for moving = 0, 3 do
        for abs = 0, 40 do
          for l = 0, 1 do
            local latch = (l == 1)
            if SM.in_set(speed, facing, moving, abs, latch) then
              list[#list + 1] = {speed, facing, moving, abs, latch}
            end
          end
        end
      end
    end
  end
  return list
end

return SM
