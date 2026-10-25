-- smbmodel.lua : SMB1 NTSC, small Mario, World 1-1 page 0.
-- w = 256*$57 + $0705 (signed); the speed byte $57 is in 1/16 px per frame.
local SM = {}
local floor, max, min = math.floor, math.max, math.min
local function split(w) local s = floor(w / 256); return s, w - 256 * s end

-- One frame of routine 8 (PlayerCtrlRoutine), horizontal part.
-- In:  w; F=$33; M=$45; A=$0700; R=($0703~=0); ground=($1D==0 at frame start);
--      d = raw joypad & 3 (1 Right, 2 Left); down; other = B, Up or Select held;
--      runok = B held or RunningTimer >= 2 before the frame; jump = A newly pressed;
--      pin = KeepOnscr fires this frame.
-- Out: w', F', M', A', R', move-time w, air, run, LR (after Down); nil if the pin is impossible.
function SM.step(w, F, M, A, R, ground, d, down, other, runok, jump, pin)
  local s, f = split(w)
  local LR = d
  if ground and down and LR ~= 0 then LR = 0 end            -- Down cancels L/R on the ground
  local air = (not ground) or jump                          -- ProcJumping runs before X_Physics
  local run
  if air then run = (A >= 25) else run = (LR == M) and runok end
  local maxR, maxL, adder
  if run then maxR, maxL, adder = 40, -40, 228
  else maxR, maxL = 24, -24; adder = (R or A >= 33) and 208 or 152 end
  if F ~= M then adder = 2 * adder end                      -- asl/rol FrictionAdder
  local Fn, Mn, Rn = F, M, R
  if not air then                                           -- OnGroundStateSub
    if A >= 28 then Rn = true                               -- GetPlayerAnimSpeed
    elseif d ~= 0 or down or other then
      if d == M then Rn = false
      elseif A < 11 then Mn = F; s, f = 0, 0 end            -- ProcSkid
    end
    if LR ~= 0 then Fn = LR end
  end
  local An = A
  if (not air) or LR ~= 0 then                              -- ImposeFriction
    local dir
    if LR == 0 then dir = (s > 0 and -1) or (s < 0 and 1) or 0
    elseif LR % 2 == 1 then dir = 1 else dir = -1 end
    if dir ~= 0 then
      s, f = split(s * 256 + f + dir * adder)
      if dir == 1 and s >= maxR then s = maxR end           -- clamps write $57 only
      if dir == -1 and s < maxL then s = maxL end
    end
    An = (s < 0) and -s or s
  end
  local wmt = s * 256 + f
  if s > 0 then Mn = 1 elseif s < 0 then Mn = 2 end         -- ChkMoveDir
  if pin then
    if s >= 16 then return nil end                          -- moved >= 1 px right of the edge
    if LR ~= 1 then s = 0 end                               -- KeepOnscr
  end
  return s * 256 + f, Fn, Mn, An, Rn, wmt, air, run, LR
end

function SM.phi(w, F, M, A)                                 -- Lemma 3's potential
  local p = (F ~= M) and 40 or 0
  if floor(w / 256) == 0 and ((M == 3 and F ~= 3) or (M == 2 and F == 3 and A >= 25)) then p = p + 40 end
  return p
end

function SM.inv(w, F, M, A, R)                              -- I1, I2, I3/I4, I6, plus the caps
  if w % 4 ~= 0 or w < -10240 or w > 10492 or A > 40 then return false end
  local s = floor(w / 256)
  if s ~= 0 then return A == ((s < 0) and -s or s) and M == ((s > 0) and 1 or 2) end
  return A < 16 or M == 2
end

-- The bound from Part 1 (memoized). Uw(w, k) bounds w after k frames.
local CAP, PMAX, XMAX = 10492, 6396, 6852
local function G(n) return min(456 * n, 416 * n + 80) end
local function H(j) if j == 0 then return 0 end return max(228 * j, 456 * j - 608) end
local uc, dc = {}, {}
function SM.Uw(w, k)
  if k <= 0 then return w end
  local key = w * 128 + k
  if uc[key] then return uc[key] end
  local r
  if w < 0 then r = SM.Uw((w >= -2560) and 416 or 252, k - 1)
  elseif w >= 6400 then r = min(CAP, w + 456 * k)
  else
    r = min(PMAX, w + G(k))
    for n = 1, k do
      local x = w + G(n)
      if x >= 6400 then r = max(r, min(CAP, min(XMAX, x) + H(k - n))) end
    end
  end
  uc[key] = r; return r
end

function SM.Dsix(w, k)                                      -- D(w, k) in 1/16 px
  local key = w * 128 + k
  if dc[key] then return dc[key] end
  local sum = 0
  for i = 1, k do sum = sum + max(0, floor(SM.Uw(w, i) / 256)) end
  local r = sum + max(0, 15 - max(0, floor(SM.Uw(w, 1) / 256)))
  dc[key] = r; return r
end

return SM
