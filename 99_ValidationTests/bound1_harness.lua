-- bound1_harness.lua
-- Variant: loads the bound under test for the validation scripts
--
-- Loads 02_BoundAcceleration/bound1.lua exactly as committed, from its own
-- text rather than a copy, so the checks can't drift from the bound the
-- search scripts paste in. bound1.lua has no `return` (it's written to be
-- pasted), so this file appends one when loading it.
--
-- It also provides the bound's per-frame envelope: the ramp's speed byte
-- and distance after each of k = 1..K frames. bound1.lua only computes the
-- totals (distance and frames to max speed), so the envelope repeats its
-- steps here. H.matches() checks the two agree, and the validation scripts
-- call it at every speed they test, so a change to bound1.lua that the
-- envelope doesn't follow is reported, not missed.

local H = {}

-- What bound1.lua defines and the checks use.
H.EXPORTS = {
  "PROJECT_TO_FRAME", "MAX_SPEED", "PX_PER_FRAME_AT_MAX_SPEED",
  "RUN_ACCEL", "RUN_ACCEL_MIN_SPEED", "WALK_ACCEL", "SLOW_WALK_ACCEL",
  "EDGE_PUSH_PX", "FREE_FRAMES",
  "get_xpos", "get_xvel", "max_position_at_frame",
  "qualifies_for_slower_ramp", "ramp_to_max_speed", "bound_x_position",
}

-- Load the bound file. It reads RAM through `memory`, so in FCEUX it sees
-- the game; elsewhere the caller provides a stand-in `memory` first.
-- Returns the table of bound1's names, or nil and a reason.
function H.load(path)
  local fh = io.open(path, "rb")
  if not fh then return nil, "cannot open " .. path end
  local src = fh:read("*a")
  fh:close()
  local fields = {}
  for _, name in ipairs(H.EXPORTS) do
    fields[#fields + 1] = name .. " = " .. name
  end
  local compile = loadstring or load
  local chunk, err = compile(src .. "\nreturn { "
      .. table.concat(fields, ", ") .. " }", "=" .. path)
  if not chunk then return nil, err end
  local ok, B = pcall(chunk)
  if not ok then return nil, B end
  for _, name in ipairs(H.EXPORTS) do
    if B[name] == nil then return nil, path .. " does not define " .. name end
  end
  B.path = path
  return B
end

-- The envelope: after k frames from speed v (in subpixels per frame, the
-- fraction included), the ramp's speed byte limit byte[k] and distance
-- limit dist[k] in px. It repeats bound1's ramp_to_max_speed step by step:
-- the first FREE_FRAMES frames and every frame from RUN_ACCEL_MIN_SPEED
-- get RUN_ACCEL, the rest the walking rate; each frame accelerates, then
-- moves floor(speed)/16 px; the first move counts at least EDGE_PUSH_PX;
-- the frame that reaches MAX_SPEED and every frame after it moves at
-- PX_PER_FRAME_AT_MAX_SPEED, as bound1's projection counts them.
--
-- opts change one part, for the checks that each part is needed:
--   free_frames     a different number of top-rate frames
--   free_frames_fn  free frames as a function of v (candidate rules)
--   from_raw_speed  ramp from v itself instead of max(v, 0)
--   no_edge         no EDGE_PUSH_PX on the first move
function H.envelope(B, v, slower, K, opts)
  opts = opts or {}
  local walk = B.WALK_ACCEL
  if slower then walk = B.SLOW_WALK_ACCEL end
  local free = B.FREE_FRAMES
  if opts.free_frames then free = opts.free_frames end
  if opts.free_frames_fn then free = opts.free_frames_fn(v) end
  local speed = math.max(v, 0)
  if opts.from_raw_speed then speed = v end
  local cruise = B.PX_PER_FRAME_AT_MAX_SPEED
  local byte, dist = {}, {}
  local d, capped, ramp_frames, ramp_px = 0, false, 0, 0
  for k = 1, K do
    local move
    if capped then
      move = cruise
    else
      local accel = walk
      if k <= free or speed >= B.RUN_ACCEL_MIN_SPEED then
        accel = B.RUN_ACCEL
      end
      speed = speed + accel
      if speed >= B.MAX_SPEED then
        capped, speed, move = true, B.MAX_SPEED, cruise
      else
        move = math.floor(speed) / 16
        if k == 1 and not opts.no_edge then
          move = math.max(move, B.EDGE_PUSH_PX)
        end
        ramp_frames, ramp_px = k, d + move
      end
    end
    d = d + move
    byte[k], dist[k] = math.floor(speed), d
  end
  -- The projected-score offset: how far the bound lets a line from this
  -- state get beyond cruising at full speed from the start. So
  -- bound_x_position equals max_position_at_frame(x, frame) + offset.
  local offset = ramp_px - ramp_frames * cruise
  return { byte = byte, dist = dist, ramp_px = ramp_px,
           ramp_frames = ramp_frames, offset = offset, capped = capped }
end

-- Does the envelope's ramp equal bound1's ramp_to_max_speed at speed v?
-- Returns true, or false and a description.
function H.matches(B, v, slower, env)
  local px, frames = B.ramp_to_max_speed(v, slower)
  if frames == env.ramp_frames and math.abs(px - env.ramp_px) < 1e-9 then
    return true
  end
  return false, string.format("speed %.4f%s: bound1 ramps %.4f px over"
      .. " %d frames, the envelope %.4f px over %d", v,
      slower and " (latch rule)" or "", px, frames, env.ramp_px,
      env.ramp_frames)
end

return H
