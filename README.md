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
  the joypad interrupt.
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
* CPU flag behaviour was verified against a 25-case serial test ROM
  (ADD/ADC/SUB/SBC, AND/XOR/OR/CP, INC, ADD HL, RLCA/RRCA/RLA, SLA, SWAP,
  BIT, DAA, PUSH/POP, CALL, (HL±), ADD SP / LD HL,SP+e8) — all cases pass.

## Known limitations

* APU: no cycle-exact sweep/envelope/frame-sequencer timing, no stereo.
* MBC1 in mode-1 high-bit ROM banking, and MBC3 RTC, are stubs.
* A cartridge with CGB double-speed mode, or the `STOP` instruction, will
  run at DMG speed only (STOP is treated as a short pause).
* The terminal renderer is RLE-compressed but bandwidth-heavy on busy
  screens; use `--dump` for screenshots or `--headless` for batch runs.
