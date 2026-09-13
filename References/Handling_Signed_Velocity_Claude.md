## Summary

`get_xvel_smooth()` and `get_yvel_smooth()` (and any function copying this pattern) contain a sign-handling bug that shifts the reported "smooth" velocity by **exactly -1.0** whenever the coarse `Speed` byte is negative and the subspeed byte is nonzero (i.e. almost always). The fix is to delete the sign branch entirely.

## The bug

```lua
if xvel1 < 0 then
    xvel2 = -AND(256 - xvel2, 0xFF)
end
xvel = xvel1 + xvel2/256
```

This is a hex-display convention (sign+magnitude formatting for humans, as used in the original overlay script's on-screen "Speed: -1.D0" text) that has been repurposed into arithmetic, where it doesn't belong.

## Why it's wrong: the counter-example

Per [SMBpedia's Movement page](https://simplistic6502.github.io/smb1_tll/smbpedia_movement.html), a speed of `-0xD0` is stored as byte pair `FF 30` (Speed=`0xFF`, MoveForce=`0x30`), the two's-complement 16-bit encoding of `-208`. Decoding it two ways:

- **16-bit combine:** `0xFF30` as signed 16-bit = `-208`; `-208/256 = -0.8125`.
- **Direct decomposition:** `readbytesigned(0xFF) + readbyte(0x30)/256 = -1 + 0.1875 = -0.8125`. ✓ matches.

Both give **-0.8125**, with no sign correction needed — this identity holds generally for *any* signed-high-byte/unsigned-low-byte pair (proof: for `B_s < 128`, `WS = B_s·256+F`; for `B_s ≥ 128`, `WS = (B_s-256)·256+F`; both reduce to `WS/256 = S + F/256`).

Run the **same bytes** through the script's formula:
```
xvel2 = -AND(256-48, 0xFF) = -208
xvel  = -1 + (-208/256) = -1.8125
```
That's off by **-1.0** from the documented value. This isn't a rounding quirk — it happens for every nonzero `F` when `S<0` (derivable directly: `xvel = (S-1) + F/256` for `F=1..255`).

## Why it's wrong: the disassembly

`ImposeFriction` (SMBDIS.ASM, `nwoeanhinnogaehr/smb-assembler:smbdis.asm` ~L6238–6270) shows how the game itself writes this byte pair:

```asm
LeftFrict: lda Player_X_MoveForce
           clc
           adc FrictionAdderLow      ; add to low byte
           sta Player_X_MoveForce
           lda Player_X_Speed
           adc FrictionAdderHigh     ; carry from above propagates here — no clc in between
           sta Player_X_Speed
```

Note there's no `clc` between the two `adc`s — the carry out of the low-byte add is deliberately fed into the high-byte add. That's ordinary 16-bit addition split across two bytes, with the CPU's carry flag doing all the sign bookkeeping. There is no instruction here (or anywhere else `MoveForce` is touched) that inspects the sign of `Speed` and negates or two's-complements `MoveForce` on that basis. The engine never treats these as independent sign+magnitude quantities — it treats them as one 16-bit two's-complement accumulator. Reading them back should mirror that: `S + F/256`, unconditionally.

## Fix

```lua
local function get_xvel_smooth()
	local xvel1 = memory.readbytesigned(ram_Player_X_Speed)
	local xvel2 = memory.readbyte(ram_Player_X_MoveForce)  -- unsigned, no correction
	local xvel = xvel1 + xvel2/256
	if xvel > 40 then xvel = 40
	elseif xvel < -40 then xvel = -40 end
	return xvel
end
```

Same change applies to `get_yvel_smooth` (`Player_Y_Speed`/`Player_Y_MoveForce`).



Source: https://claude.ai/share/91733d95-12e5-46f5-b120-e794083eb3ab
