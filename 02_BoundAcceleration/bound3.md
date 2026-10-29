# bound3: the best Mario could possibly do

`bound3.lua` answers one question about any moment in a search: **what is the best score any
continuation from here could reach?** A score is Mario's x on the frame he first reaches max speed,
carried forward at max speed to frame 45. If even this best case can't beat the best line found so
far, nothing from here can.

It bounds every frame, not just the score: after any number of frames, no line from here has more
speed or has moved farther than bound3's ramp. Every part of the ramp is there for that, each
justified by a game mechanism below, so the bound also holds for any other objective built on speed
or distance, such as x at a fixed frame.

Routine and RAM names below are those of the SMB1 disassembly (SMBDIS.ASM).

## Units and RAM

Speeds are in the game's units: 1/16 px per frame, so max speed 40 is 2.5 px a frame. Rates are in
1/256 of a speed unit per frame, so a rate of 456 adds about 1.8 a frame.

| RAM | Name | Used for |
|---|---|---|
| $57 | Player_X_Speed | the speed byte, signed: the part of the speed that moves Mario |
| $0705 | Player_X_MoveForce | the speed's fraction |
| $33 | PlayerFacingDir | facing: 1 right, 2 left, 3 after Left+Right |
| $45 | Player_MovingDir | moving direction: 1 right, 2 left |
| $0700 | Player_XSpeedAbsolute | the size of the speed byte, as last written |
| $0703 | RunningSpeed | the run latch |
| $6D, $86, $0400 | Player_PageLoc, Player_X_Position, its subpixel | Mario's x |
| $071A, $071C | ScreenLeft_PageLoc, ScreenLeft_X_Pos | the left edge of the screen |

## The rule

From Mario's current speed, bound3 plays out the fastest ramp the game could ever allow, then holds
max speed:

1. A negative speed counts as 0.
2. The first 2 frames gain 456 each, at any speed (the "free frames").
3. After that, below speed 25 it gains 416 a frame; from 25 up, 456 a frame.
4. Each frame moves Mario speed ÷ 16 px, counting whole speed units only. The first frame moves at
   least 15/16 px.
5. At 40 he's at max speed, and runs at 2.5 px a frame from then on.

Each call assumes any stored bursts are still there, so a child's bound can come out higher than
its parent's. Use the smaller of the two.

## Why each part is safe

**How Mario moves.**

- **No frame adds more than 456:** the run rate $E4 (228), doubled. The game doubles the rate while
  Mario faces away from his motion, which is what fast accel uses.
- **Max speed is 40** ($28), and only the speed byte $57 moves Mario: speed ÷ 16 px, whole units.
  The fraction never moves him.
- **From 25 up, 456 every frame:** in the air the run rate applies once $0700 is 25 ($19) or more,
  and facing only changes on the ground, so a Mario facing back keeps the doubled rate every air
  frame.

**Below 25: 416, not 304.** Apart from a stored burst, the best below 25 is a walk rate, doubled.
It's tempting to take that as $98 doubled (304), but the walk rate is $D0 (208, doubled 416) once
the run latch RunningSpeed is set, or $0700 is 33 or more. Without reading more RAM, any frame
could be latched, so the bound must allow 416 to stay sound. (`use_latch_rule` reads it.)

**Free frames: stored bursts.** A burst is facing that differs from the moving direction, kept for
the next frame:

- **A turnaround** stores 1, at any speed: press back on the ground, then forward with B.
- **Left+Right** can store 2, at speed 0. Left+Right sets facing to 3, a slow-speed skid (ProcSkid)
  can copy that 3 into the moving direction, and it stays there while the speed byte is 0. For
  example, Left+Right, B, Right, Left+Right+B, Right+B gains 456 twice in a row.
- **The left edge** can store 2, at speed 0: its clamp (KeepOnscr) zeroes the speed byte but leaves
  $0700, which the air still reads as running speed.

No state holds more than two: both two-burst setups need speed 0, and a ground frame that runs
toward the motion turns facing to match it, using a burst up. The rates never drop as speed rises,
so taking the free frames first is the best order.

**A negative speed counts as 0.** No frame adds more than 456 to the larger of the speed and 0, so
a backward speed never ramps up faster than 0 does.

**The edge push, 15/16 px.** The edge clamp keeps Mario's subpixel, at most 15/16 px, so the edge
can carry him at most 15/16 px past his own moves. It can't catch him from behind: the screen never
scrolls left, and scrolls right (ScrollHandler) only while Mario is 80 px or more ahead. This holds
wherever the edge is.

---

## Options

Each option reads a little more RAM and rests on one more game fact. All are off by default, and
with all of them off, bound3 is bound2.

**`use_latch_rule`: 304 below 25,** when the latch ($0703) is clear, $0700 is under 25 and Mario
isn't moving left. The latch only sets on a ground frame with $0700 of 28 or more
(GetPlayerAnimSpeed), and $0700 under 25 rules out a stale one helping. A rightward Mario passes
25, where the ramp already gains 456, before he could set it. A leftward one can set it and then
lose the speed at the edge, so he's left out.

**`do_burst_check`: 1 free frame when the speed byte isn't 0.** Both two-burst setups need speed 0,
so a moving Mario can store only a turnaround's one.

**`use_facing_rule`:** the doubled rate needs facing to differ from the moving direction.

- **No free frames when moving and facing the motion:** nothing is stored. To double a rate he must
  first change facing, and a Left+Right frame (152 or 208, not doubled) then a 456 frame is no more
  than two walking frames of 304 or 416.
- **From 25 up, 228 forward, or turn.** 25 is first reached on a ground run frame (elsewhere the
  walk cap of 24 holds), and that frame faces him forward: 228 a frame. Turning takes a ground
  frame against the motion, losing at least 152; after it, 456 a frame. The bound takes the better
  path each frame, and 456 every frame if he already faces away.
- **The forward path never drops below 25 + 456:** a line just under 25 can spend a stored burst on
  the frame it reaches 25.

**`use_edge_position`: no 15/16 px allowance** once Mario is 15/16 px or more right of the left
edge. From there the edge can't carry him past his own moves (see the edge push).

## Why it's reasonably tight

Every rate and allowance is reached in the game, so none can be lowered:

| Part | Reached by |
|---|---|
| 456 every frame from 25 | fast accel: face back, then jump holding forward |
| 416 below 25 | run to 28 to set the latch, slow below 25, Left+Right, then jump holding Right |
| 304 below 25 | the first Right from rest: the moving direction starts at 0, so the rate doubles |
| 2 free frames | Left+Right, B, Right, then Left+Right+B and Right+B gain 456 each |
| 1 free frame while moving | turn around at any speed, then Right+B gains 456 |
| negative speed as 0 | Left+B, then B alone: the speed is zeroed (the usual RTA opening) |
| 15/16 px | at the edge with subpixel 0, a 1/16 px step left ends 15/16 px ahead |
| 228 from 25, facing forward | holding Right+B from rest, every frame from 25 to 40 |
| the floor | latched just under 25, Left+Right then Right+B gains 208 + 456 and passes 25 + 228 |
| no free frames when facing forward | from a forward run under 25, Left+Right then Right+B gains 152 + 456, exactly two frames of 304 |

Taking out any one part lets some line beat the bound, and some lines reach it exactly. At the 1-1
start (x 40, speed 0), with the latch rule on:

| Bound | Best score it allows |
|---|---|
| bound2 | 115.6875 |
| + facing rule | 114.625 |
| + edge position | 113.75 |
| HappyLee's TAS (actual) | 110.5625 |

Left out on purpose: rules that depend on the exact path taken, such as the walking cap of 24 just
before 25, a turnaround costing 208 instead of 152, and jump timing. Each would tighten the bound a
little and make it much harder to follow.

## Assumptions

- Small Mario on flat ground, with no walls, stairs, moving platforms, enemies or water.
- The screen scrolls normally. With scroll lock on, the right edge acts as a wall.
- NTSC.
- Scores are exact for lines that reach max speed by frame 45.