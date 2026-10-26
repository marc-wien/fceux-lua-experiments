# Open claims

These are claims about the bound, its scope and the searches that aren't
confirmed in the ROM yet, plus ideas for tightening the bound. Each row says:
- what confirming or adopting the claim would change;
- how strong the evidence is now;
- what test would move it forward.

**Evidence levels**
- **ROM:** confirmed in FCEUX on the real ROM.
- **Model:** checked exhaustively in `smbmodel.lua`, by
  `smb1_model_validation.lua`.
- **Argued:** reasoned from the code or the design, not checked
  mechanically.
- **None:** an idea, not yet examined.

**Keeping it current.** When a run changes a row's evidence, update the row
with the date and the claim that settled it (R1-R28, M1-M11). When a claim
is settled either way, move it to Settled.

Status as of 2026-10-25. The ROM suite has not run on the ROM yet. Rows
marked "once run" move when it passes.

## Tightening the bound

Ceilings are at the 1-1 start (x 40, speed 0, frame 0). bound1's are
123.9375 speed only and 115.6875 with the latch rule.

| Claim | What it changes | Evidence now | Next step |
|---|---|---|---|
| One free frame when $57 >= 1 (the line commented out in `bound1.lua`) | Tighter for states moving right at speeds 1-24; no change at the start | Model: holds frame by frame and by score (M10) | R24, once run; then decide |
| No free frames, if the bound only needs to hold by score | Start ceiling 123.5 | Model: holds by score; broken frame by frame (M9) | Decide whether the frame-by-frame claim matters; if not, add the variant to R23 |
| No edge push, by score only | Start ceiling 123.0625 | Model: as above (M9). Dropping both this and the free frames fails, at 64 states | As above |
| The latch rule on by default | Start ceiling 115.6875 | Model (M7, M8). ROM: random play on Oct 16, with bound0's unrounded distance | R23, once run; then choose the 03 scripts' default |
| A tighter rule from 25 up: +228 a frame until a turnaround frame unlocks 456 | About 1 px tighter (122.875 at the start), but harder to explain | Model: checked Oct 10, in the model now in `smbmodel.lua`, with a separate checker | Add it as a variant in M10 |
| Jump timing in the model: Mario can't land on just any frame | Tighter where a line needs a jump, such as the latched 416 in the air | None | Check the vertical physics against the ROM first |

## Scope

| Claim | What it changes | Evidence now | Next step |
|---|---|---|---|
| 8-4's stair risers push Mario at most 1 px, so a flat +1 px covers them | Lets the bound run on 8-4 | Argued | Add the riser positions to the model and check there, then on the ROM |
| Landings never push Mario sideways on 8-4's stairs or other levels, as in the 1-1 opening | 8-4 and other levels | ROM for the 1-1 opening only (Oct 10; R19 and R22 once run) | The same jump sweep on 8-4's stairs |
| Moving platforms; detecting death in lava | 8-4 | None | When the 8-4 work starts |

## Validation gaps

| Claim | What it changes | Evidence now | Next step |
|---|---|---|---|
| Every button combination acts like its input case, at every state | Removes an assumption under R25-R28 | ROM, sampled: 300 states x 128 combinations (R17, once run) | An exhaustive R17, about 16.6M frames |
| RAM that R25-R28 don't write (other timers, the frame counter) doesn't affect horizontal physics | Same | Argued; R20 sees many values in real play | Rerun R25 from a few other start frames |
| Away from the edge, the subpixel doesn't matter | R25-R28 use subpixel 0 | R18 covers every subpixel at the edge, R20 real subpixels in play (once run) | Only if R20 shows a gap |
| No line longer than 60 frames beats the bound | M7 and M8 stop at k = 60 | Argued: the 1-1 searches stop by frame 50 | Raise K in the model check if a search goes longer |
| The model's best line from the start (71.8125 px in 45 frames, x 111.8125) plays on the ROM | If it does, the 1-1 optimum for 45 frames, L+R included, is known without a search | None | Extract the line from the model check and replay it in FCEUX |

## Searches

| Claim | What it changes | Evidence now | Next step |
|---|---|---|---|
| Full-RAM dedup is sound: two nodes with the same RAM have the same futures | Every dedup result | Argued: assumes the console's other state (CPU registers, PPU) doesn't matter at frame boundaries | Replay a sample of merged pairs and compare their futures |
| Taking the minimum with the parent's ceiling is sound | All pruning | Argued: both ceilings bound the same future lines | None needed |
| Every 03 script carries `bound1.lua`'s text exactly | Every result under bound1 | Not yet: bound1 isn't in the 03 scripts | Once it is, add a check that compares each script's bound section with `bound1.lua` |
| The 1-1 results found under the old bound still hold | The published results | ROM: the RTA result, 103.813, reran under bound0 on Oct 17. The L+R result, 110.563, hasn't been rerun | Rerun both under bound1 |

## Settled

| Claim | Evidence |
|---|---|
| Two free frames are needed and enough, frame by frame | Model (M7, M9). ROM: the double charge (Oct 10), and R11 once run |
| Below 25, the latch allows 416 | ROM (Oct 10); R8 and R9 once run |
| Only the speed byte moves Mario | ROM: random play (Oct 10); R27 exhaustively, once run |
| The latch rule needs its speed >= 0 test, frame by frame | Model (M9). ROM: the left-edge trap (Oct 16), and R15 once run |
| The ramp must start from max(v, 0), by score too | Model (M9). ROM: the skid reset (Oct 10), and R6 from a negative speed once run |
