# 10_ValidationTests

These scripts check that the acceleration bound
(`02_BoundAcceleration/bound2.lua`) holds for the real game, and that each
part of it is needed. `bound2.lua` is `bound1.lua` with one option added,
the burst check (`do_burst_check`: one free frame when $57 is nonzero);
with it off, the two give the same bound. The argument has two links, and
each has a script:

1. **ROM to model.** `smb1_rom_validation.lua` (FCEUX) checks that
   `smbmodel.lua` computes Mario's horizontal movement exactly as the ROM
   does, for every state and input case the model covers.
2. **Model to bound.** `smb1_model_validation.lua` (any Lua 5.1) checks
   the bound against every state and input of the model, up to 60 frames
   ahead, with and without the burst check.

The ROM suite also checks the bound directly on the ROM, during random
play. Both scripts load the bound from its own file, so they test the
committed text, not a copy. They test `bound2.lua` by default; set
`BOUND_FILE` (model check) or `CFG.bound_file` (ROM suite) to
`../02_BoundAcceleration/bound1.lua` to test that file instead. Each claim
prints what it tests, how, and what it supports, then PASS or FAIL, with the
first mismatches in full.

| File | What it is |
|---|---|
| `smbmodel.lua` | The model: one frame of horizontal physics, from SMBDIS.ASM |
| `bound_harness.lua` | Loads `bound1.lua` or `bound2.lua`; gives the per-frame envelope of its ramp |
| `smb1_rom_validation.lua` | The FCEUX suite, claims R1-R38 |
| `smb1_model_validation.lua` | The model check, claims M1-M11 |
| `OPEN_CLAIMS.md` | Claims not yet confirmed in the ROM, and ideas for tightening |

**Running.**
- *ROM suite:* FCEUX 2.x with the NTSC ROM, and "Allow Left+Right / Up+Down"
  ticked. Power on, then run the script.
  - Everything except R35-R38 should take minutes. R34 runs about 137,000
    single frames; set `background_stride` higher for a quicker pass.
  - R35-R38 run about 8.8 million single frames. Expect hours; the suite
    prints an estimate. Set `exhaustive_stride = 50` for a quick pass first.
  - The suite writes `smb1_rom_validation_log.txt`. Commit it as the record.
- *Model check:* about 50 s in Lua 5.1, about 10 s in LuaJIT. It needs no ROM,
  so it should also run from FCEUX's Lua window (not yet tried). It writes
  `smb1_model_validation_log.txt`.
- Each log starts with a checksum of every file it tested, so it records
  exactly which versions passed.

**The model.** Nothing here vouches for `smbmodel.lua` except the ROM
suite: R29 and R35-R38 compare it with the ROM frame by frame, and R34 over
other backgrounds.

## How to read the ROM suite's log

The log is meant to be read without the code. It opens with the checksum of
every file tested and a short legend, then one block per claim, then a
summary.

**A claim's block.** The first line gives the claim's id, the behavior it
states, and its kind in brackets. Then come what it tests, the wrong idea it
rules out (for some claims) and what it supports. Then the evidence: the
inputs (button letters, `x5` for repeats) and the values the game produced,
each marked `ok` or `GOT` with what came back. The last line is the verdict.
For example:

```
R11  From rest, two 456 frames in a row (the double charge)  [sequence]
      Tests: Left+Right, B, Right, Left+Right+B, Right+B. ...
    double charge: LR, B, R, LRB, RB
      frame  4 LRB  expect speed 02:60 (2.375), moving 1, facing 3, adder 456: ok
      frame  5 RB   expect speed 04:28 (4.156), moving 1, facing 1, adder 456: ok
      -> R11 PASS (5 checks, 0 failed)
```

R29-R33 and R35-R38 run in one loop each, so their verdicts print together
after their descriptions.

**Kinds** say how a behavior is shown, and so how far a PASS goes:
- **setup:** the ROM, the start state and the controller are as assumed.
- **sequence:** exact inputs from the start of 1-1. The behavior happens in
  real play, on that line.
- **written:** a state written into RAM, then exact inputs. It shows the
  game's rule for that state; whether play reaches the state is a separate
  question (R30 checks that every state play reaches is in the model's set).
- **search:** tries nearby input sequences until one shows the behavior.
- **sweep:** every case in the stated range.
- **sampled:** random or every-Nth cases. A PASS means no exception was found
  among them, not that none exists.
- **exhaustive:** every state in the model's set, with every input case.

**Statuses.** PASS: shown. FAIL: contradicted; the first mismatches print in
full, with the state, inputs and values. NOT RUN: skipped (section off, or
the bound file didn't load). NOT SHOWN: a search found no case; not a
failure, but the behavior isn't shown. Claims marked information only are
candidates, and a FAIL there doesn't fail the run.

**The summary** lists every claim as id, status, kind and behavior. When
everything passes, it is the list of behaviors this ROM was shown to have,
each with how it was shown; search the log for an id to find its evidence.
The checksums at the top say exactly which file versions that applies to.

## What the ROM suite confirms

**Setup** (setup)
- **R1** The ROM is the known-good NTSC dump: its SHA-1 starts
  `ea343f4e`.
- **R2** Its speed tables match the model's caps and adders:
  - MaxLeftXSpdData D8 E8 F0;
  - MaxRightXSpdData 28 18 10 0C;
  - FrictionData E4 98 D0.
- **R3** The run starts at the first frame of control in 1-1, with the
  expected RAM.
- **R4** FCEUX passes Left+Right and Up+Down to the game.

**Each part of the bound is reached in the ROM** (sequence; R12 written, R15
search). Each shows a value the bound must allow, so that value can't be
lowered.
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
- **R15** Moving left with the latch clear, Mario can set the latch at the
  edge and then gain faster than 304 allows. This is why the latch rule tests
  speed >= 0.
- **R16** Down cancels Left/Right on the ground; facing is fixed in the air;
  Left+Right at 11+ walks at 304.

**Gotchas: shortcuts and readings that fail** (sequence; R23-R25 written).
Each claim says what it rules out.
- **R17** The latch rule needs both free frames: R11's double charge starts
  from a state the latch rule accepts.
- **R18** At speed byte 0, the fraction and moving direction 3 stay with no
  input, because friction tests only the speed byte.
- **R19** Walking caps at 24 even with the latch set; the cap doesn't follow
  the friction index.
- **R20** A jump keeps the latch of its last ground frame, so a takeoff at
  28.8 can be unlatched. From takeoff speeds the threshold looks like 29.
- **R21** From 25 up, running forward adds 228, not 456.
- **R22** A turnaround holds one 456 frame, at speeds 12, 20 and 30.
- **R23** RunningTimer keeps Mario running only from 2 up: it counts down
  before the game reads it.
- **R24** Down hides Left/Right only from the acceleration: the latch and the
  skid reset still see them.
- **R25** $0700 of 33 or more picks $D0 without the latch.

**Inputs, the edge and jumps** (R26 sampled; R27 and R28 sweep)
- **R26** For 300 random states, across all 128 combinations of the seven
  buttons, at random RunningTimer and previous-A values, only the inputs the
  model reads matter.
- **R27** The edge clamp, at every subpixel, speed byte -40..15, every
  facing, on the ground and in the air:
  - it puts Mario's pixel on the edge and keeps the subpixel;
  - it zeroes the speed unless exactly Right is held;
  - Mario never ends left of the edge;
  - the clamp never lifts him more than 15/16 px.
- **R28** Every jump from the start lands cleanly, with no side push from the
  floor: A held 1-45 frames, five jump strengths.

**Real play** (sampled: 3,000 random runs from seven setups)
- **R29** Every frame matches the model, including landings, timers and
  scrolling.
- **R30** Every state reached is in the model's state set.
- **R31** The screen and the scope stay as assumed:
  - Mario is never left of the edge;
  - the edge never moves left, and moves right no more than Mario did;
  - Mario never reaches the right-edge clamp;
  - no wall or floor pushes him;
  - no enemy comes within 24 px, and he stays short of the first ? block;
  - play stays normal, with small Mario.
- **R32** The bound holds, frame by frame and by projected score, for the
  speed-only bound and the latch rule.
- **R33** The same with the burst check. Information only when the bound
  has none (`bound1.lua`).

**Over other RAM** (sampled: every 97th state, all input cases)
- **R34** R35-R38's comparison over three other backgrounds (other frame
  counter, timers, random numbers and screen position) and random subpixels
  away from the edge.

**Every model state and input case, one frame each** (exhaustive: 64,896
states, 136 frames each: 68 input cases, each at x 96 and on the edge)
- **R35** The ROM's next speed, facing, moving direction, $0700 and latch
  equal the model's.
- **R36** The adder applied equals the model's: 152, 208 or 228, doubled
  exactly when facing differs from the moving direction.
- **R37** Mario moves exactly 16 x speed byte (1/256 px), so the fraction
  never moves him. The edge clamp applies exactly when his move reaches the
  edge.
- **R38** A jump starts on the frame A is newly pressed, and that frame uses
  the air rules.


## What the model check confirms

- **M1** The bound file loads, and the envelope's ramp projects as its
  `ramp_to_max_speed` does at every speed, with and without the burst check.
- **M2** The state set is closed: no input takes a state outside it.
- **M3** No frame adds more than 456 to max(speed, 0).
- **M4** The speed byte stays within -40..40.
- **M5** Speed 25 is reached from below only on a ground frame, running.
- **M6** `bound_x_position` equals the envelope's projection at every state.
- **M7** The bound holds frame by frame, for speed and distance, from every
  state, at every k up to 60. This covers the speed-only bound and the latch
  rule, each with and without the burst check.
- **M8** The bound holds for projected scores, in the same four forms.
- **M9** Each part is needed. Removing it lets some line beat the bound.
- **M10** (information) Candidates: score-only variants, and for
  `bound1.lua` the burst check.
- **M11** (information) The farthest the model allows from the 1-1 start.

## What this supports

**Correctness.** Once the ROM suite passes, the argument runs in four
steps:
1. **The model is the ROM.** In every state the game reaches here, one frame
   of the ROM equals one frame of the model:
   - single frames: R35-R38, R26, R27 and R34;
   - along real lines: R29;
   - the game stays inside the model's state set (R30) and in scope (R28,
     R31).
2. **The model can only overstate the game.** In the model check, any frame
   may be a takeoff or a landing, and the edge clamp may come anywhere.
3. **No line in the model beats the bound.** This holds from any state,
   within 60 frames, frame by frame and by score (M2-M8). Every ramp reaches
   full speed well within 60 frames.
4. **So the bound holds for the game in this scope.** R32 and R33 also check
   it directly on the ROM, along sampled lines.

**Tightness.**
- In the model, the bound is reached exactly. The speed-only bound's closest
  margin is 0 for speed, distance and score. The latch rule's is 0 frame by
  frame and 1.1875 px by score (M7, M8). Both are the same with the burst
  check.
- Every rate and allowance in it is reached in the ROM, once R5-R14 and R22
  pass.
- Each part is needed (M9).

**What it doesn't cover.**
- **Scope:** small Mario in the 1-1 opening; no walls, blocks, platforms,
  vines or water; NTSC.
- **Vertical motion is not modeled,** only over-approximated. Landing depth is
  checked for jumps from the start (R28) and along real play.
- **R35-R38 use one button combination per input case,** with RunningTimer
  0 or 10, A not held the frame before, the start's background and the
  subpixel at 0. R26 samples all 128 combinations and every timer value; R27
  covers every subpixel at the edge; R34 samples other backgrounds and
  subpixels; R29 covers real play.
- **R29-R33 sample lines rather than enumerate them.** The exhaustive
  argument is the chain above.
- **Positions are not modeled.** The distance argument relies on R31: the
  edge never carries Mario past where his own moves, plus one 15/16 px clamp,
  could take him.

## Results

**Model check, 2026-10-25: all claims hold,** for `bound2.lua` and for
`bound1.lua`.
- **Closest margins:** 0 for speed, distance and score (speed-only bound);
  1.1875 px for the latch rule's score. The same with the burst check.
- **Ceilings at the 1-1 start:** 123.9375 (speed only) and 115.6875 (latch
  rule). The burst check doesn't change them, since $57 is 0 there.
- **What each part is needed for (M9):**
  - **Needed for scores:** the latch's 416 and max(v, 0).
  - **Needed frame by frame only:** the free frames, the edge push and the
    latch rule's speed test. Each one alone can be removed without any score
    beating the bound. Removing both the free frames and the edge push does
    fail, at 64 states.
  - **With the burst check:** its one free frame when $57 is nonzero is
    needed frame by frame only; the latch rule's speed test becomes needed
    for scores too (12 states).
- **Candidates (M10):** one free frame wherever the latch rule applies holds
  by score (closest 0.5625 px; latch-rule ceiling at the start 114.6875), but
  not frame by frame (68,992 pairs; R17 shows such a line).
- **Reference (M11):** the farthest the model allows from the start is
  71.8125 px in 45 frames, so x 111.8125.

**ROM suite:** not yet run on the ROM. Its log will be the record.

Open and untested claims are listed in `OPEN_CLAIMS.md`.
