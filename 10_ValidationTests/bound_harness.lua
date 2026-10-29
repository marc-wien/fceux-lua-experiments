-- bound_harness.lua
-- Variant: loads the bound under test for the validation scripts
--
-- Loads a bound file (02_BoundAcceleration/bound1.lua, bound2.lua or bound3.lua) exactly as
-- committed, from its own text rather than a copy, so the checks can't drift from the bound the
-- search scripts paste in. The bound files have no `return` (they're written to be pasted), so
-- this file appends one when loading them.
--
-- It also provides the bound's per-frame envelope: the ramp's speed byte and distance after each
-- of k = 1..K frames. The bound only computes the totals (distance and frames to max speed), so
-- the envelope repeats its steps here. H.matches() checks the two agree, and the validation
-- scripts call it at every speed they test, so a change to the bound that the envelope doesn't
-- follow is reported, not missed.

local H = {}

-- What the checks use. Each entry lists the names a bound file may give it: the later bounds' name
-- first (the name the checks use), then bound1.lua's.
H.NAMES = {
  { "SCORING_FRAME", "PROJECT_TO_FRAME" },
  { "MAX_SPEED" },
  { "MAX_SPEED_IN_PX", "PX_PER_FRAME_AT_MAX_SPEED" },
  { "RUN_ACCEL" },
  { "RUN_ACCEL_THRES", "RUN_ACCEL_MIN_SPEED" },
  { "WALK_ACCEL" }, { "SLOW_WALK_ACCEL" }, { "EDGE_PUSH_PX" },
  { "FREE_FRAMES" }, { "max_position_at_frame" },
  { "qualifies_for_slower_ramp" }, { "ramp_to_max_speed" },
  { "bound_x_position" },
}

-- Names only some bounds have:
--   - bound1.lua and bound2.lua read RAM in get_xpos and get_xvel, and their test
--     (qualifies_for_slower_ramp) reads it itself.
--   - bound3.lua reads RAM once, in read_node, and its tests take that node. Loading wraps them so
--     the checks call every bound's tests the same way, with no arguments: B.get_xpos(),
--     B.get_xvel(), B.qualifies_for_slower_ramp(), B.already_turned(), B.holds_no_burst() and
--     B.clear_of_left_edge() each read the node first.
--   - bound2.lua's burst check (do_burst_check): a state with $57 nonzero gets
--     FREE_FRAMES_IF_MOVING free frames. B.has_burst_check.
--   - bound3.lua's facing rule (use_facing_rule): FORWARD_ACCEL, TURN_DECEL, BEST_CROSSING and its
--     two tests. B.has_facing_rule.
--   - bound3.lua's edge position (use_edge_position): clear_of_left_edge. B.has_edge_position.
H.OPTIONAL = { "get_xpos", "get_xvel", "read_node", "FREE_FRAMES_IF_MOVING", "FORWARD_ACCEL",
               "TURN_DECEL", "BEST_CROSSING", "already_turned", "holds_no_burst",
               "clear_of_left_edge" }

-- Load the bound file. It reads RAM through `memory`, so in FCEUX it sees the game; elsewhere the
-- caller provides a stand-in `memory` first. Returns the table of the bound's names, or nil and a
-- reason.
function H.load(path)
  local fh = io.open(path, "rb")
  if not fh then return nil, "cannot open " .. path end
  local src = fh:read("*a")
  fh:close()
  local fields = {}
  for _, names in ipairs(H.NAMES) do
    for _, name in ipairs(names) do
      fields[#fields + 1] = name .. " = " .. name
    end
  end
  for _, name in ipairs(H.OPTIONAL) do
    fields[#fields + 1] = name .. " = " .. name
  end
  local compile = loadstring or load
  local chunk, err = compile(src .. "\nreturn { "
      .. table.concat(fields, ", ") .. " }", "=" .. path)
  if not chunk then return nil, err end
  local ok, found = pcall(chunk)
  if not ok then return nil, found end
  local B = { path = path }
  for _, names in ipairs(H.NAMES) do
    for _, name in ipairs(names) do
      if B[names[1]] == nil then B[names[1]] = found[name] end
    end
    if B[names[1]] == nil then
      return nil, path .. " does not define " .. table.concat(names, " or ")
    end
  end
  for _, name in ipairs(H.OPTIONAL) do B[name] = found[name] end
  -- bound3.lua's node-based tests, wrapped to read the node first.
  B.reads_node = (found.read_node ~= nil)
  if B.reads_node then
    local read = found.read_node
    B.get_xpos = function() return read().x end
    B.get_xvel = function() return read().speed end
    for _, name in ipairs({ "qualifies_for_slower_ramp", "already_turned",
                            "holds_no_burst", "clear_of_left_edge" }) do
      local test = found[name]
      if test then B[name] = function() return test(read()) end end
    end
  elseif not (B.get_xpos and B.get_xvel) then
    return nil, path .. " defines neither read_node nor get_xpos and get_xvel"
  end
  B.has_burst_check = (B.FREE_FRAMES_IF_MOVING ~= nil)
  B.has_facing_rule = (B.FORWARD_ACCEL ~= nil and B.TURN_DECEL ~= nil
      and B.BEST_CROSSING ~= nil and B.already_turned ~= nil and B.holds_no_burst ~= nil)
  B.has_edge_position = (B.clear_of_left_edge ~= nil)
  return B
end

-- The facing rule's two tests, from the speed, facing and moving direction given rather than from
-- RAM (M6 and R42 check bound3.lua's already_turned and holds_no_burst against these). v is the
-- speed, fraction included, so floor(v) is the speed byte $57.
function H.facing_tests(B, v, facing, moving)
  local byte = math.floor(v)
  local turned = byte >= B.RUN_ACCEL_THRES and facing ~= moving
  local no_burst = byte ~= 0 and facing == moving
  return turned, no_burst
end

-- The envelope: after k frames from speed v (in subpixels per frame, the fraction included), the
-- ramp's speed byte limit byte[k] and distance limit dist[k] in px. It repeats the bound's
-- ramp_to_max_speed step by step: the free frames (FREE_FRAMES, or with the burst check
-- FREE_FRAMES_IF_MOVING when $57 is nonzero) and every frame from RUN_ACCEL_THRES get RUN_ACCEL,
-- the rest the walking rate; each frame accelerates, then moves floor(speed)/16 px; the first move
-- counts at least EDGE_PUSH_PX; the frame that reaches MAX_SPEED and every frame after it moves at
-- MAX_SPEED_IN_PX, as the bound's projection counts them.
--
-- With the facing rule (opts.facing_rule, plus opts.facing and opts.moving, the state's $33 and
-- $45): a state moving and facing its motion gets no free frames; from RUN_ACCEL_THRES up, unless
-- already turned, the speed is the larger of two branches, forward (FORWARD_ACCEL a frame, not
-- below BEST_CROSSING) and turned (TURN_DECEL on the first frame from RUN_ACCEL_THRES, then
-- RUN_ACCEL). With opts.clear_of_edge (bound3.lua's use_edge_position, when Mario is clear of the
-- left edge), no edge push.
--
-- opts:
--   burst_check     the burst check: one free frame when $57 is nonzero
--   facing_rule, facing, moving, clear_of_edge   as above
-- and, to change one part for the checks that each part is needed:
--   free_frames     a different number of top-rate frames
--   free_frames_fn  free frames as a function of v (candidate rules)
--   from_raw_speed  ramp from v itself instead of max(v, 0)
--   no_edge         no EDGE_PUSH_PX on the first move
--   no_floor        facing rule without BEST_CROSSING under the forward branch
--   no_turn_branch  facing rule without the turned branch
--   no_turned_case  facing rule without RUN_ACCEL for a state already turned
function H.envelope(B, v, slower, K, opts)
  opts = opts or {}
  local walk = B.WALK_ACCEL
  if slower then walk = B.SLOW_WALK_ACCEL end
  local free = B.FREE_FRAMES
  if opts.burst_check and math.floor(v) ~= 0 then
    free = B.FREE_FRAMES_IF_MOVING or 1
  end
  local two_branches, turned_now = false, false
  if opts.facing_rule then
    local no_burst
    turned_now, no_burst = H.facing_tests(B, v, opts.facing, opts.moving)
    if opts.no_turned_case then turned_now = false end
    if no_burst then free = 0 end
    two_branches = not turned_now
  end
  if opts.free_frames then free = opts.free_frames end
  if opts.free_frames_fn then free = opts.free_frames_fn(v) end
  local speed = math.max(v, 0)
  if opts.from_raw_speed then speed = v end
  local turned = nil
  local cruise = B.MAX_SPEED_IN_PX
  local edge_push = not (opts.no_edge or opts.clear_of_edge)
  local byte, dist = {}, {}
  local d, capped, ramp_frames, ramp_px = 0, false, 0, 0
  for k = 1, K do
    local move
    if capped then
      move = cruise
    else
      local before = speed
      if k <= free then
        speed = speed + B.RUN_ACCEL
      elseif speed < B.RUN_ACCEL_THRES then
        speed = speed + walk
      elseif two_branches then
        speed = speed + B.FORWARD_ACCEL
        if not opts.no_floor then speed = math.max(speed, B.BEST_CROSSING) end
      else
        speed = speed + B.RUN_ACCEL
      end
      speed = math.min(speed, B.MAX_SPEED)
      if two_branches and not opts.no_turn_branch then
        if turned then
          turned = math.min(turned + B.RUN_ACCEL, B.MAX_SPEED)
        elseif k > free and before >= B.RUN_ACCEL_THRES then
          turned = before - B.TURN_DECEL
        end
      end
      local top = math.max(speed, turned or speed)
      if top >= B.MAX_SPEED then
        capped, speed, move = true, B.MAX_SPEED, cruise
      else
        move = math.floor(top) / 16
        if k == 1 and edge_push then
          move = math.max(move, B.EDGE_PUSH_PX)
        end
        ramp_frames, ramp_px = k, d + move
      end
      byte[k] = math.floor(capped and B.MAX_SPEED or top)
    end
    d = d + move
    if capped then byte[k] = B.MAX_SPEED end
    dist[k] = d
  end
  -- The projected-score offset: how far the bound lets a line from this state get beyond cruising
  -- at full speed from the start. So bound_x_position equals max_position_at_frame(x, frame) +
  -- offset.
  local offset = ramp_px - ramp_frames * cruise
  return { byte = byte, dist = dist, ramp_px = ramp_px, ramp_frames = ramp_frames, offset = offset,
           capped = capped }
end

-- Does the envelope's ramp equal the bound's ramp_to_max_speed at speed v, with the latch rule
-- (slower), the burst check (burst) and, for bound3.lua, fopts (facing_rule, facing, moving,
-- clear_of_edge) as given? The two must project the same, so the comparison is distance beyond
-- cruising at max speed. bound1.lua's ramp stops before the frame that reaches max speed and the
-- later bounds' include it, so its frames may be one more. bound3.lua's ramp takes what the
-- options decide (the walking rate, the free frames, the facing rule's branches, the edge push),
-- so this works them out from fopts the way bound_x_position does, independently of it; M6 checks
-- that bound_x_position decides the same. Returns true, or false and a description.
function H.matches(B, v, slower, env, burst, fopts)
  fopts = fopts or {}
  local reduced = burst and math.floor(v) ~= 0
  local px, frames
  if B.reads_node then
    local walk = slower and B.SLOW_WALK_ACCEL or B.WALK_ACCEL
    local free = reduced and B.FREE_FRAMES_IF_MOVING or B.FREE_FRAMES
    local turned, no_burst = false, false
    if fopts.facing_rule then
      turned, no_burst = H.facing_tests(B, v, fopts.facing, fopts.moving)
    end
    if no_burst then free = 0 end
    px, frames = B.ramp_to_max_speed(v, walk, free,
        (fopts.facing_rule and not turned) and true or false,
        not fopts.clear_of_edge)
  else
    px, frames = B.ramp_to_max_speed(v, slower, reduced)
  end
  local offset = px - frames * B.MAX_SPEED_IN_PX
  if math.abs(offset - env.offset) < 1e-9 and (frames == env.ramp_frames
      or frames == env.ramp_frames + 1) then
    return true
  end
  return false, string.format("speed %.4f%s%s%s%s: the bound ramps %.4f px"
      .. " over %d frames, the envelope %.4f px over %d", v,
      slower and ", latch rule" or "", burst and ", burst check" or "",
      fopts.facing_rule and string.format(", facing rule (facing %d,"
          .. " moving %d)", fopts.facing, fopts.moving) or "",
      fopts.clear_of_edge and ", clear of the edge" or "", px, frames,
      env.ramp_px, env.ramp_frames)
end

return H
