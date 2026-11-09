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
* **APU:** 4 channels — two square waves with duty/volume, wave channel
  (FF30–FF3F wave RAM), noise channel (LFSR), channel triggers (NRx4),
  mixed to WAV (envelope/length/sweep sequencer is approximate).
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

  Multicart `cpu_instrs.gb`
  (`8c5e12f41e0ba5bb…56fcf2`) prints `01:ok …` progressively over
  serial; extended runs record tens of thousands of subtests logged
  `ok` with zero failures (61,524+ subtests and counting in the
  longest run, still progressing when the frame cap was reached).
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

## Known limitations

* APU: no cycle-exact sweep/envelope/frame-sequencer timing, no stereo.
* MBC1 in mode-1 high-bit ROM banking, and MBC3 RTC, are stubs.
* A cartridge with CGB double-speed mode, or the `STOP` instruction, will
  run at DMG speed only (STOP is treated as a short pause).
* The terminal renderer is RLE-compressed but bandwidth-heavy on busy
  screens; use `--dump` for screenshots or `--headless` for batch runs.
