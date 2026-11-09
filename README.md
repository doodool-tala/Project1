# Game Boy Emulator — Entirely in Assembly Language

A complete Nintendo Game Boy (DMG) emulator written **100% in x86-64 assembly
language** (NASM syntax, assembled with NASM + `ld`). No C, no C++, no libc,
no dynamic libraries, no interpreted code — every instruction is a Linux
syscall issued directly from hand-written assembly.

## Build

```sh
# requires: nasm (https://www.nasm.us), ld (binutils), make
make            # builds ./gameboy
make test       # builds tests/hello.gb and runs it headless, dumping a frame
```

On systems without NASM: download a NASM release tarball and build it from
source (`./autogen.sh` may be skipped with a downloaded release; `make nasm`),
then `PATH=$PWD/nasm-*/:$PATH make`.

## Usage

```sh
./gameboy [--headless] [--frames N] [--dump FILE.ppm] [--serial] [--audio FILE.wav] [--debug] ROM.gb
```

* **Terminal mode (default):** renders the 160×144 screen as ANSI true-color
  half-block characters (U+2580) and reads the keyboard in raw mode.
  Keys: **Arrows / WASD** = D-pad, **Z** = B, **X** = A, **Enter** = Start,
  **Space** = Select, **Esc / Q** = quit.
* `--frames N` — run exactly N frames (implies useful for CI) and exit.
* `--dump FILE.ppm` — write the final frame as a binary PPM image.
* `--serial` — write bytes the game sends to the serial port (SB/SC) to
  stdout. This lets test ROMs (e.g. CPU test suites) print results.
* `--audio FILE.wav` — write 44.1 kHz mono 16-bit WAV audio.
* `--debug` — trace PC:opcode for the first 200 instructions to stdout.

Cartridge RAM (MBC1/3/5) is saved next to the ROM as `ROM.gb.sav` and
re-loaded on the next run.

## What's implemented

* **CPU:** full LR35902 — all primary and CB-prefixed opcodes, flags
  (Z/N/H/C), `ADD SP,e8` / `LD HL,SP+e8` half-carry rules, `DAA`, rotates
  through carry, `BIT/RES/SET`, `PUSH/POP`, `CALL/RET/RST`, `EI` with the
  one-instruction delay, `DI`, `RETI`, and `HALT` wake-up with IME=0/1.
  The boot ROM is skipped: registers start in the documented post-boot
  state (PC=0100, SP=FFFE, AF=01B0, BC=0013, DE=00F8, HL=014D, I/O values
  as left by the boot ROM), so real cartridges boot immediately.
* **PPU:** modes 0–3 with correct dot timing (456 dots/line, 154 lines),
  STAT + LYC coincidence interrupts, LY/LYC, BG with scroll (SCX/SCY),
  both tile-data addressing modes (8000 unsigned / 8800 signed) and both
  tile-map bases (9800/9C00), window layer (WX/WY), sprites (OAM,
  8×8/8×16, flip X/Y, priority, OBP0/OBP1), BGP/OBP palettes, OAM DMA
  (FF46), and the DMG 4-shade palette.
* **Timers:** DIV (FF04, write resets), TIMA/TMA/TAC with falling-edge
  detection on the selected divider bit and overflow interrupt.
* **Interrupts:** VBlank, LCD STAT, Timer, Serial, Joypad with correct
  priority and vector addresses (40/48/50/58/60).
* **Joypad:** P1 (FF00) button/D-pad group selection; key presses raise
  the joypad interrupt. Keyboard input is momentary (visible for one
  frame per key byte); in headless mode keys may also be supplied on
  stdin.
* **Serial:** SB/SC (FF01/FF02) — writes SB to stdout when a transfer starts.
* **APU:** a real 512 Hz frame sequencer (8192 T-cycles per step) clocks
  the four channels: length counters at 256 Hz, sweep at 128 Hz and the
  volume envelope at 64 Hz. Implemented: per-channel length counters with
  reload (0 -> max), freeze/unfreeze, the DMG extra-length-clock quirk,
  DAC gating and trigger effects; sweep with shadow frequency, period-0
  treated as 8, negate-mode flag/quirk and overflow disable; NR52 power
  on/off (registers 0x10-0x25 cleared on power-off, reads masked while
  off, wave RAM preserved, length counters not clocked while off);
  per-register read masks (write-only bits read as 1s); wave-RAM access
  gating while channel 3 plays; duty/wave/noise sample timers. The four
  channels mix to mono 16-bit WAV.
* **Cartridge controllers:** ROM-only, MBC1 (ROM/RAM banking + mode),
  MBC3 (ROM/RAM banking; RTC registers accepted), MBC5, external RAM
  banking, echo RAM (E000–FDFF), HRAM, and .sav persistence.

## Tests

* `tests/hello.asm` — a Game Boy assembly test cartridge (checkerboard BG,
  scrolling tile map, one DMA sprite, serial `OK` print). Build it with
  `nasm -f bin tests/hello.asm` and run:
  `./gameboy --headless --frames 240 --serial --dump frame.ppm tests/hello.gb`
  Expected: serial prints `OK`, and the dumped frame contains exactly the
  four DMG palette colours with the checker pattern and sprite visible.
  Frame hash (240 frames, this build):
  `42d4f7d8150df80bd806ae838828130b7a060ac1802431b43be5d4e09415b4ea`.
* CPU flag behaviour was verified against a 25-case serial test ROM
  (ADD/ADC/SUB/SBC, AND/XOR/OR/CP, INC, ADD HL, RLCA/RRCA/RLA, SLA, SWAP,
  BIT, DAA, PUSH/POP, CALL, (HL±), ADD SP / LD HL,SP+e8) — all cases pass.
* **Blargg `cpu_instrs` singles — all 11 report `Passed`**
  (`./gameboy --headless --frames 60000 --serial ROM.gb`). ROMs are from
  the public archive.org Blargg test-ROM set (repo does not contain ROMs):

  | ROM | SHA-256 (first 16) | Result |
  | --- | --- | --- |
  | 01-special.gb | fe61349cbaee10cc | Passed |
  | 02-interrupts.gb | fb90b0d2b9501910 | Passed |
  | 03-op sp,hl.gb | ca553e606d9b9c86 | Passed |
  | 04-op r,imm.gb | 7686aa7a39ef3d25 | Passed |
  | 05-op rp.gb | d504adfa0a4c4793 | Passed |
  | 06-ld r,r.gb | 17ada54b0b9c1a33 | Passed |
  | 07-jr,jp,call,ret,rst.gb | ab31d3daaaa3a98b | Passed |
  | 08-misc instrs.gb | 974a71fe4c67f70f | Passed |
  | 09-op r,r.gb | b28e1be5cd95f22b | Passed |
  | 10-bit ops.gb | 7f5b8e488c6988b5 | Passed |
  | 11-op a,(hl).gb | 0ec0cf9fda3f00be | Passed |

  Multicart `cpu_instrs.gb` (`8c5e12f41e0ba5bb…56fcf2`) runs the whole
  suite as **256 subtests per pass and then repeats**. Runs were
  verified pass-by-pass from the serial log:
  * a 12M-frame run logged **240 complete passes** (61,524 `ok`
    results, **0 failures**), every pass identical;
  * a fresh 300k-frame run from the committed tree logged **10
    complete passes** (2,670 `ok`, 0 failures), pass 1 byte-identical
    to pass 2.

  So one full suite pass covers all 256 subtests, and the ROM keeps
  looping it; the emulator reproduces that indefinitely with no
  failures.
* **Blargg `mem_timing` — all 3 singles and the multicart report
  `Passed`** (read/write/modify memory-access cycle timing, verified
  via the cartridge-RAM verdict at $A000, status 0). ROMs are from the
  same public archive.org set:

  | ROM | SHA-256 (first 16) | Result |
  | --- | --- | --- |
  | 01-read_timing.gb | d9c6e86b7008fdae | Passed |
  | 02-write_timing.gb | 9188e5d9cf9dfc9e | Passed |
  | 03-modify_timing.gb | 818256ab477bb8fb | Passed |
  | mem_timing.gb (multicart) | ab9daf4c51f417c4 | 01:ok 02:ok 03:ok Passed |
* **Input:** in headless mode the emulator also reads key bytes from
  stdin (`w`=Up, `s`=Down, `a`=Left, `d`=Right, `z`=B, `x`=A,
  `Enter`=Start, `Space`=Select; keys are momentary per frame). Verified
  with a P1-reading test cartridge: no input → prints `N`; piped `x`
  (A button) → prints `Y` (549× in 600 frames); piped `z` (B) → prints
  `Y` on a B-button variant of the same cartridge (549×), and `x` on
  that variant still prints `N`. Real frames of `mem_timing` and
  `cpu_instrs` render their test screens in the four DMG colours.

## dmg_sound (APU) results

Each single ROM was run headless (2200 frames, well past every subtest)
and its own `$A000` verdict byte, `DE B0 61` signature and text were read
back. **5 of 12 pass:**

| ROM | status | result |
| --- | --- | --- |
| 01-registers | 0 | `Passed` |
| 06-overflow on trigger | 0 | `Passed` (`0556 0667 071D 0788 07C2 07E1 07F1`) |
| 09-wave read while on | 0 | `Passed` (wave-RAM read gating + fetch phase) |
| 10-wave trigger while on | 0 | `Passed` (DMG trigger corruption offsets) |
| 12-wave write while on | 0 | `Passed` (write/fetch coupling) |
| 02-len ctr | 6 | Failed #6 "Trigger should treat 0 length as maximum" |
| 03-trigger | 2 | Failed #2 "Enabling in second half of length period shouldn't clock length" |
| 04-sweep | 8 | Failed #8 "If shift=0 and period>0, trigger enables" |
| 05-sweep details | 8 | Failed #8 "Subtract mode uses two's complement (upper bound)" |
| 07-len sweep period sync | 2 | Failed #2 "Length period is wrong" |
| 08-len ctr during power | 1 | Failed; lengths read back `00 00 11 00`, CRC `729DFC0C` (DMG expects `11 22 44 33`) |
| 11-regs after power | 4 | Failed #4 "Powering off shouldn't affect NR41" |

The wave family (09/10/12) and the register/trigger-overflow tests
(01/06) now pass. The NRx4 length block was rewritten this pass to
follow Pan Docs in hardware order: a 0 -> 1 length-enable edge clocks
the length once when the next DIV-APU step does not clock length (the
write lands in the first half of the length period) and the counter is
non-zero, disabling the channel if that reaches zero without a trigger;
a trigger then unfreezes a zero counter and reloads it to maximum,
landing on max-1 when the length is enabled by the same write and the
next step does not clock length. That moved 02 from #7 to #6 and 03
from #5 to #2.

The remaining failures are a **phase anchor** problem, measured rather
than assumed. At test 03 #2 the write happens 8256 T-cycles after
`sync_apu`, which blargg calibrates to be the *second* half of the
length period (the first half ends at 8192), so no extra clock must
occur. The frame-sequencer trace logs
`W4 s=05 c=0405 ch=00 v=40 e=00 l=0002`, i.e. the write is only ~65
cycles after a length clock was processed, so the model classifies it
as the first half and clocks it. In other words `sync_apu` unblocks one
length period later here than on hardware, and every derived phase
(03 #2/#3, 02 #6/#7, 07 #2, 11 #4) inherits that offset. The trace also
shows two length decrements between consecutive NR24 writes at the same
sequencer step with no length clock logged between them, so the trigger
path needs the same audit before the anchor can be trusted.

The multicart `dmg_sound.gb` demonstrates that phase dependence directly.
After 9000 headless frames its `$A000` status is still `80` (running) and
the text contains one result per run, with the same test passing at one
alignment and failing at the next three:

```
01:ok 02:07 03:05 04:08 05:ok 06:06 07:05 08:08 09:ok 10:07 11:05 12:08
13:ok 14:07 15:05 16:08 17:ok 18:02 19:05 20:08 21:ok 22:07 23:05 24:08
25:ok 26:07 27:05 28:08 29:ok 30:06 31:05 32:08 ...
```

Every fourth group is `ok`; the others fail at the length/sweep subtests
whose expected value changes with the sub-step phase. That is the same
signature as the singles above and is why the multicart does not reach a
final `Passed` verdict in this build.

## Known limitations

* APU: frame sequencer, length/envelope/sweep clocks, DAC gating, NR52
  power semantics, wave-RAM read/write gating and the DMG trigger
  corruption are implemented and measured (5/12 `dmg_sound` singles
  pass, including the whole wave family). Still wrong: `sync_apu`'s
  exit sits one length period later than hardware, which shifts every
  length-period phase the remaining tests measure; a duplicate length
  decrement between two NR24 writes in the same sequencer step; two
  sweep upper-bound/period-0 edge cases; and the length-counter readback
  during power transitions (`00 00 10 00` instead of `11 22 44 33`).
  No stereo panning in the WAV output.
* MBC1 in mode-1 high-bit ROM banking, and MBC3 RTC, are stubs.
* A cartridge with CGB double-speed mode, or the `STOP` instruction, will
  run at DMG speed only (STOP is treated as a short pause).
* The terminal renderer is RLE-compressed but bandwidth-heavy on busy
  screens; use `--dump` for screenshots or `--headless` for batch runs.
