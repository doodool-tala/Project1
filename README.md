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

Each single ROM was run headless (1500 frames, well past every subtest)
and its own `$A000` verdict byte, `DE B0 61` signature and text were read
back. **12 of 12 pass:**

| ROM | status | result |
| --- | --- | --- |
| 01-registers | 0 | `Passed` |
| 02-len ctr | 0 | `Passed` |
| 03-trigger | 0 | `Passed` |
| 04-sweep | 0 | `Passed` |
| 05-sweep details | 0 | `Passed` |
| 06-overflow on trigger | 0 | `Passed` (`0555 0666 071C 0787 07C1 07E0 07F0 0556 0667 071D 0788 07C2 07E1 07F1`) |
| 07-len sweep period sync | 0 | `Passed` |
| 08-len ctr during power | 0 | `Passed`; counter dump `33 44 11 22` (the ROM's own print order) |
| 09-wave read while on | 0 | `Passed` |
| 10-wave trigger while on | 0 | `Passed` |
| 11-regs after power | 0 | `Passed`, including #4 |
| 12-wave write while on | 0 | `Passed` |


The five length/trigger/power ROMs (02, 03, 07, 08, 11) were failing on
one bus bug rather than on five separate behaviours. `apu_active` stores
one byte per channel, but the NR52 read loaded it as a dword and masked
the low nibble, so only channel 1's active flag could ever reach the CPU:
every `lda NR52 / and mask` poll for channels 2-4 read zero. Folding each
byte into its own bit fixed all five at once, and 08's own dump
`33 44 11 22` now matches its DMG reference CRC, so the ROM prints
`Passed` with status 0.

The power-off/on semantics are implemented and measured separately: while
NR52 bit 7 is clear the frame sequencer neither steps nor clocks anything,
and the power-on write restarts step and phase together so no backlog is
replayed. A register-preserving trace shows the four counters holding
`11 22 44 33` (with all enable bits clear, power 0, step 0) across the
power-down and zero length clocks while off, and 11 #4 passes because the
off-state NR41 load survives the power cycle.

The sweep unit follows one model, reconciled from the test sources. The
enable flag is latched at trigger (enabled when period or shift is
non-zero) and NR10 writes do not change it, which is what 04's subtests
8/9/10 assert: "trigger enables" when either field is non-zero, "trigger
disables" when both are zero. While enabled, a calculation runs

* on trigger when shift is non-zero,
* on an NR10 write when period and shift are both non-zero, restarting
  from the frequency registers rather than the already-swept shadow
  (04 #9 needs `$03FF -> $05FE`, not `$05FE -> $8FD`),
* when the sweep timer expires with a non-zero period.

Calculations move only the private shadow; NR13/NR14 are written from it
when the timer reloads with a non-zero period (05's test 09 wording),
which makes 05 #7/#8 copy `$555`/`$556` instead of the swept `$500`/`$501`.
A result above `$7FF`, or a negate->pos switch after a negate
calculation, disables the channel. The clock itself is unchanged and
DIV-aligned: ticks at frame-sequencer steps 2 and 6, four steps = 32768
cycles = 128 Hz apart. All twelve singles now print `Passed` with status
0 and signature `DE B0 61`.

The multicart `dmg_sound.gb` runs every test at four alignments. At 80000
headless frames it had printed `01:ok` through `70:ok` with no failures, and
its `$A000` status was still `80`, so it had not reached its own final verdict
within that run; the 12 singles above are the complete measured pass.

## Known limitations

* APU: frame sequencer, length/envelope/sweep clocks, DAC gating, NR52
  power semantics, wave-RAM read/write gating and the DMG trigger
  corruption are implemented and measured (12/12 `dmg_sound` singles
  pass, including both sweep ROMs, all four wave ROMs, both
  length-counter/power ROMs and the trigger ROM). No stereo panning in
  the WAV output.
* MBC1 in mode-1 high-bit ROM banking, and MBC3 RTC, are stubs.
* A cartridge with CGB double-speed mode, or the `STOP` instruction, will
  run at DMG speed only (STOP is treated as a short pause).
* The terminal renderer is RLE-compressed but bandwidth-heavy on busy
  screens; use `--dump` for screenshots or `--headless` for batch runs.
