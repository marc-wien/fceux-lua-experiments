# 99_ValidationTests

These scripts check that the acceleration bound
(`02_BoundAcceleration/bound1.lua`) holds for the real game, and that each
part of it is needed. The argument has two links, and each has a script:

1. **ROM to model.** `smb1_rom_validation.lua` (FCEUX) checks that
   `smbmodel.lua` computes Mario's horizontal movement exactly as the ROM
   does, for every state and input case the model covers.
2. **Model to bound.** `smb1_model_validation.lua` (any Lua 5.1) checks
   `bound1.lua` against every state and input of the model, up to 60 frames
   ahead.

The ROM suite also checks `bound1.lua` directly on the ROM, during random
play. Both scripts load `bound1.lua` from its own file, so they test the
committed text, not a copy. Each claim prints what it tests, how, and what
it supports, then PASS or FAIL, with the first mismatches in full.

| File | What it is |
|---|---|
| `smbmodel.lua` | The model: one frame of horizontal physics, from SMBDIS.ASM |
| `bound1_harness.lua` | Loads `bound1.lua`; gives the per-frame envelope of its ramp |
| `smb1_rom_validation.lua` | The FCEUX suite, claims R1-R28 |
| `smb1_model_validation.lua` | The model check, claims M1-M11 |
| `OPEN_CLAIMS.md` | Claims not yet confirmed in the ROM, and ideas for tightening |

**Running.**
- *ROM suite:* FCEUX 2.x with the NTSC ROM, and "Allow Left+Right / Up+Down"
  ticked. Power on, then run the script.
  - Everything except R25-R28 should take minutes.
  - R25-R28 run about 8.8 million single frames. Expect hours; the suite
    prints an estimate. Set `exhaustive_stride = 50` for a quick pass first.
  - The suite writes `smb1_rom_validation_log.txt`. Commit it as the record.
- *Model check:* about 40 s in Lua 5.1, about 7 s in LuaJIT. It needs no ROM,
  so it should also run from FCEUX's Lua window (not yet tried). It writes
  `smb1_model_validation_log.txt`.
- Each log starts with a checksum of every file it tested, so it records
  exactly which versions passed.

**The model.** `smbmodel.lua` has the same `step` as the version checked
against the ROM on Oct 10 (committed as 73261d4). Every one of that version's
outputs matches over all 64,896 states, on the ground and in the air, and
every input value. The revision made these changes:
- rewrote the comments;
- dropped an alternative bound and proof potential that were stored there;
- added two outputs: the adder chosen and whether it was applied;
- added `SM.states()`, which lists the state set.

## What the ROM suite confirms

**Setup**
- **R1** The ROM is the known-good NTSC dump: its SHA-1 starts
  `ea343f4e`.
- **R2** Its speed tables match the model's caps and adders:
  - MaxLeftXSpdData D8 E8 F0;
  - MaxRightXSpdData 28 18 10 0C;
  - FrictionData E4 98 D0.
- **R3** The run starts at the first frame of control in 1-1, with the
  expected RAM.
- **R4** FCEUX passes Left+Right and Up+Down to the game.

**Each part of the bound is reached in the ROM.** These are exact sequences.
Each shows a value the bound must allow, so that value can't be lowered.
- **R5** Frame 1 from rest gives 304, because the moving direction starts at
  0. This is the latch rule's rate.
- **R6** A slow backwards speed resets to 0 in one frame (the RTA opening's
  B frame). This is why the ramp starts from max(v, 0).
- **R7** Running caps the speed byte at 40 and keeps the fraction. The latch
  sets at 28.
- **R8** With the latch set, Left+Right below 25 gains 416 a frame on the
  ground, after a first frame at 208.
- **R9** With the latch set, a jump holding Right gains 416 per air frame
  below 25.
- **R10** From 25 up, in the air facing backwards, every frame gains 456 (fast
  accel).
- **R11** The double charge: two 456 frames in a row from rest. This is why
  there are two free frames.
- **R12** At the left edge, a 1/16 px step left leaves Mario 15/16 px further
  right. This is the edge push.
- **R13** Running left into the edge leaves $0700 stale, and the latch is
  read from it.
- **R14** Left+Right into the edge loads a 456 jump at speed 0.
- **R15** The left-edge trap: a state the latch rule would give 304 without
  its speed >= 0 test later gains faster than 304 allows.
- **R16** Down cancels Left/Right on the ground; facing is fixed in the air;
  Left+Right at 11+ walks at 304.

**Inputs, the edge and jumps**
- **R17** For 300 random states, across all 128 combinations of the seven
  buttons, at random RunningTimer and previous-A values, only the inputs the
  model reads matter.
- **R18** The edge clamp, at every subpixel, speed byte -40..15, every
  facing, on the ground and in the air:
  - it puts Mario's pixel on the edge and keeps the subpixel;
  - it zeroes the speed unless exactly Right is held;
  - Mario never ends left of the edge;
  - the clamp never lifts him more than 15/16 px.
- **R19** Every jump from the start lands cleanly, with no side push from the
  floor: A held 1-45 frames, five jump strengths.

**Real play** (3,000 random runs from seven setups)
- **R20** Every frame matches the model, including landings, timers and
  scrolling.
- **R21** Every state reached is in the model's state set.
- **R22** The screen and the scope stay as assumed:
  - Mario is never left of the edge;
  - the edge never moves left, and moves right no more than Mario did;
  - Mario never reaches the right-edge clamp;
  - no wall or floor pushes him;
  - play stays normal, with small Mario.
- **R23** bound1 holds, frame by frame and by projected score, for the
  speed-only bound and the latch rule.
- **R24** (information) The same check for the commented-out candidate:
  one free frame when $57 >= 1.

**Every model state and input case, one frame each** (64,896 states, 136
frames each: 68 input cases, each at x 96 and on the edge)
- **R25** The ROM's next speed, facing, moving direction, $0700 and latch
  equal the model's.
- **R26** The adder applied equals the model's: 152, 208 or 228, doubled
  exactly when facing differs from the moving direction.
- **R27** Mario moves exactly 16 x speed byte (1/256 px), so the fraction
  never moves him. The edge clamp applies exactly when his move reaches the
  edge.
- **R28** A jump starts on the frame A is newly pressed, and that frame uses
  the air rules.

## What the model check confirms

- **M1** `bound1.lua` loads, and the envelope's ramp matches its
  `ramp_to_max_speed` at every speed.
- **M2** The state set is closed: no input takes a state outside it.
- **M3** No frame adds more than 456 to max(speed, 0).
- **M4** The speed byte stays within -40..40.
- **M5** Speed 25 is reached from below only on a ground frame, running.
- **M6** `bound_x_position` equals the envelope's projection at every state.
- **M7** bound1 holds frame by frame, for speed and distance, from every
  state, at every k up to 60. This covers the speed-only bound and the latch
  rule.
- **M8** bound1 holds for projected scores, for both rates.
- **M9** Each part is needed. Removing it lets some line beat the bound.
- **M10** (information) Candidates: the commented-out free-frame rule, and
  score-only variants.
- **M11** (information) The farthest the model allows from the 1-1 start.

## What this supports

**Correctness.** Once the ROM suite passes, the argument runs in four
steps:
1. **The model is the ROM.** In every state the game reaches here, one frame
   of the ROM equals one frame of the model:
   - single frames: R25-R28, R17 and R18;
   - along real lines: R20;
   - the game stays inside the model's state set (R21) and in scope (R19,
     R22).
2. **The model can only overstate the game.** In the model check, any frame
   may be a takeoff or a landing, and the edge clamp may come anywhere.
3. **No line in the model beats bound1.** This holds from any state, within
   60 frames, frame by frame and by score (M2-M8). Every ramp reaches full
   speed well within 60 frames.
4. **So bound1 holds for the game in this scope.** R23 also checks it
   directly on the ROM, along sampled lines.

**Tightness.**
- In the model, bound1 is reached exactly. The speed-only bound's closest
  margin is 0 for speed, distance and score. The latch rule's is 0 frame by
  frame and 1.1875 px by score (M7, M8).
- Every rate and allowance in it is reached in the ROM, once R5-R14 pass.
- Each part is needed (M9).

**What it doesn't cover.**
- **Scope:** small Mario in the 1-1 opening; no walls, blocks, platforms,
  vines or water; NTSC.
- **Vertical motion is not modeled,** only over-approximated. Landing depth is
  checked for jumps from the start (R19) and along real play.
- **R25-R28 use one button combination per input case,** with RunningTimer
  0 or 10, A not held the frame before, and the subpixel at 0. R17 samples
  all 128 combinations and every timer value; R18 covers every subpixel at
  the edge; R20 covers real subpixels in play.
- **R20-R24 sample lines rather than enumerate them.** The exhaustive
  argument is the chain above.
- **Positions are not modeled.** The distance argument relies on R22: the
  edge never carries Mario past where his own moves, plus one 15/16 px clamp,
  could take him.

## Results

**Model check, 2026-10-25: all claims hold.**
- **Closest margins:** 0 for speed, distance and score (speed-only bound);
  1.1875 px for the latch rule's score.
- **Ceilings at the 1-1 start:** bound1 gives 123.9375 (speed only) and
  115.6875 (latch rule).
- **What each part is needed for (M9):**
  - **Needed for scores:** the latch's 416 and max(v, 0).
  - **Needed frame by frame only:** the free frames, the edge push and the
    latch rule's speed test. Each one alone can be removed without any score
    beating the bound. Removing both the free frames and the edge push does
    fail, at 64 states.
- **Candidates (M10):** one free frame when $57 >= 1 holds at both levels.
  Its ceiling at the start is unchanged.
- **Reference (M11):** the farthest the model allows from the start is
  71.8125 px in 45 frames, so x 111.8125.

**ROM suite:** not yet run on the ROM. Before committing, the scripts were
tested offline against a stand-in emulator (not in the repo: the model plus
simple vertical motion), with faults injected:
- a latch threshold of 29;
- a 1/16 px extra edge lift;
- movement by the fraction;
- a bound with no free frames.

Each fault failed the claims that test the behavior it changed. R1 fails in
every stand-in run, because the stand-in has no real ROM; the clean run
passed every other claim.

Open and untested claims are listed in `OPEN_CLAIMS.md`.