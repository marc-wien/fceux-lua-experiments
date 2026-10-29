# Open claims

These are claims about the bound, its scope and the searches that aren't confirmed in the ROM yet,
plus ideas for tightening the bound. Each row says:
- what confirming or adopting the claim would change;
- how strong the evidence is now;
- what test would move it forward.

**Evidence levels**
- **ROM:** confirmed in FCEUX on the real ROM.
- **Model:** checked exhaustively in `smbmodel.lua`, by `smb1_model_validation.lua`.
- **Argued:** reasoned from the code or the design, not checked mechanically.
- **None:** an idea, not yet examined.

**Keeping it current.** Evidence cites only claims these scripts check (R1-R42, M1-M12), so anyone
can rerun it; one-off runs aren't cited. When a run changes a row's evidence, update the row with
the date and the claim that settled it. When a claim is settled either way, move it to Settled.

Status as of 2026-10-27. The ROM suite has not run on the ROM yet. Rows marked "once run" move when
it passes.

## Tightening the bound

Ceilings are at the 1-1 start (x 40, speed 0, frame 0). bound2's are 123.9375 speed only and
115.6875 with the latch rule.

| Claim | What it changes | Evidence now | Next step |
|---|---|---|---|
| The burst check: one free frame when $57 is nonzero (`do_burst_check` in `bound2.lua`) | Tighter for every state with $57 nonzero; no change at the start | Model: holds frame by frame and by score (M7, M8) | R33, once run; then decide whether the searches use it |
| No free frames, if the bound only needs to hold by score | Start ceiling 123.5 | Model: holds by score; broken frame by frame (M9) | Decide whether the frame-by-frame claim matters; if not, add the variant to R32 |
| No edge push, by score only | Start ceiling 123.0625 | Model: as above (M9). Dropping both this and the free frames fails, at 64 states | As above |
| One free frame wherever the latch rule applies, by score only | Latch-rule start ceiling 114.6875 | Model: holds by score (M10, closest 0.5625 px); broken frame by frame (68,992 pairs). R17 shows such a line on the ROM, once run | As the other score-only rows |
| The latch rule on by default | Start ceiling 115.6875 | Model (M7, M8) | R32, once run; then choose the 03 scripts' default |
| The facing rule (`use_facing_rule` in `bound3.lua`): from 25 up, 228 a frame or a turnaround; no free frames for a moving state facing its motion | Start ceilings 122.875 and 114.625 (latch rule); about 1 px tighter on average over all model states | Model: holds frame by frame and by score, each part needed (M7-M9). Its game facts: R21, R36; reached: R39, R40, once run | R42, once run; then decide whether the searches use it |
| Edge position (`use_edge_position` in `bound3.lua`): no edge push once Mario is 15/16 px clear of the left edge | 0.875 px off the start ceilings (122.0 and 113.75 with the facing rule) | Model: his moves stay within the ramp without the allowance (M7, M8). That the edge can't add to them: argued from R27, R30, R31 and R37 | R41 and R42, once run |
| The walking cap of 24 means 25 is first reached on a running frame | Tighter around speeds 20-25 | None. Deferred 2026-10-27: too frame- and path-specific for the gain | None for now |
| A turnaround with the latch set (or $0700 >= 33) loses 208, not 152 | Slightly tighter from 25 up | None. Deferred 2026-10-27: depends on the path | None for now |
| Jump timing in the model: Mario can't land on just any frame | Tighter where a line needs a jump, such as the latched 416 in the air | None | Check the vertical physics against the ROM first |

## Scope

| Claim | What it changes | Evidence now | Next step |
|---|---|---|---|
| 8-4's stair risers push Mario at most 1 px, so a flat +1 px covers them | Lets the bound run on 8-4 | Argued | Add the riser positions to the model and check there, then on the ROM |
| Landings never push Mario sideways on 8-4's stairs or other levels, as in the 1-1 opening | 8-4 and other levels | For the 1-1 opening only: R28 and R31, once run | The same jump sweep on 8-4's stairs |
| Moving platforms; detecting death in lava | 8-4 | None | When the 8-4 work starts |
| The edge facts (R27, R30, R31, R41) hold beyond sampled play from the 1-1 start: everywhere near the edge, and at any edge position in a flat area with no platforms or walls | The edge push and edge position, exhaustively and away from the 1-1 start | Argued from the code: ScrollHandler scrolls only from screen x 80 ($50) and never left; KeepOnscr keeps the subpixel. ROM: R27 sweeps the 1-1 start's edge; R31 and R41 sample play from the start, once run | An exhaustive short sweep from states near the edge. For a new start: R27's sweep at other edge positions, including a page boundary; the start state in the model's set (SM.in_set); R28's jumps on the new floor. With scroll lock on, the right-edge clamp acts as a wall |

## Validation gaps

| Claim | What it changes | Evidence now | Next step |
|---|---|---|---|
| Every button combination acts like its input case, at every state | Removes an assumption under R35-R38 | ROM, sampled: 300 states x 128 combinations (R26, once run) | An exhaustive R26, about 16.6M frames |
| RAM that R35-R38 don't write (other timers, the frame counter, the screen) doesn't affect horizontal physics | Same | Sampled: R34 over three backgrounds, and R29 in real play (once run) | All states in R34, if it finds anything |
| Away from the edge, the subpixel doesn't matter | R35-R38 use subpixel 0 | R34 samples random subpixels, R27 covers every subpixel at the edge, R29 real play (once run) | As above |
| No line longer than 60 frames beats the bound | M7 and M8 stop at k = 60 | Argued: the 1-1 searches stop by frame 50 | Raise K in the model check if a search goes longer |
| The model's best line from the start (71.8125 px in 45 frames, x 111.8125) plays on the ROM | If it does, the 1-1 optimum for 45 frames, L+R included, is known without a search | None | Extract the line from the model check and replay it in FCEUX |

## Searches

| Claim | What it changes | Evidence now | Next step |
|---|---|---|---|
| Full-RAM dedup is sound: two nodes with the same RAM have the same futures | Every dedup result | Argued: assumes the console's other state (CPU registers, PPU) doesn't matter at frame boundaries | Replay a sample of merged pairs and compare their futures |
| Taking the minimum with the parent's ceiling is sound | All pruning | Argued: both ceilings bound the same future lines | None needed |
| Every 03 script carries the bound file's text exactly | Every result under the bound | Not yet: the bound isn't in the 03 scripts | Once it is, add a check that compares each script's bound section with the bound file |
| No line beats the known openings: HappyLee's TAS (110.5625, full speed on frame 32) and, under RTA rules, Maru's (103.8125, frame 34) | The project's goal for the 1-1 start | None: both scores come from playing those runs back (01_CollectKeyTasData), not from a search | An exhausted 03 search under the current bound |

## Settled

| Claim | Evidence |
|---|---|
| Two free frames are needed and enough, frame by frame, with or without the latch rule | Model (M7, M9, M10). ROM: R11, R14 and R17, once run |
| A turnaround holds one free frame at any speed, so the burst check can't drop it | Model (M9). ROM: R22, once run |
| Below 25, the latch allows 416 | Model (M9: needed for scores). ROM: R8 and R9, once run |
| Only the speed byte moves Mario | ROM: R37 exhaustively and R29 in play, once run |
| The latch rule needs its speed >= 0 test, frame by frame (and by score too, with the burst check) | Model (M9). ROM: R15, once run |
| The ramp must start from max(v, 0), by score too | Model (M9). ROM: R6, once run |
| Each part of the facing rule is needed: the floor frame by frame, the turned branch and the already-turned case by score too | Model (M9). ROM: R39, once run |
