# Game Boy (DMG) Emulator in x86-64 Assembly

A Nintendo Game Boy emulator written in **100% x86-64 assembly** (NASM + `ld`).
The emulator contains no C, no libc, and no interpreted code; every runtime
operation goes through Linux syscalls issued from hand-written assembly.

`frame_preview.png` is the deterministic frame produced by `tests/hello.gb`
(240 frames, SHA-256 `6d6829cc88b0856f2f15addcf9879ea591ac26f16795347209cccc6e30050b82`).

## Build

Requires NASM, binutils (`ld`), make, and for the test target bash plus
`ffmpeg`/`ffprobe`.

```sh
make            # builds ./gameboy
make test       # builds ROMs and runs deterministic assertions
make clean
```

## Usage

```sh
./gameboy [--headless] [--frames N] [--dump FILE.ppm] [--serial]
          [--audio FILE.wav] [--debug] [--exit-on-result] [--verdict] ROM.gb
```

* **Terminal mode:** 160×144 screen as ANSI true-colour half blocks. Keys:
  Arrows/WASD = D-pad, Z = B, X = A, Enter = Start, Space = Select,
  Esc/Q = quit.
* `--headless` — no terminal rendering.
* `--frames N` — run exactly N frames and exit (CI-friendly).
* `--dump FILE.ppm` — write the final frame as a binary PPM.
* `--serial` — write SB bytes to stdout when a serial transfer starts.
* `--audio FILE.wav` — write 44.1 kHz mono 16-bit PCM WAV.
* `--debug` — trace the first 200 PC:opcode pairs.
* `--exit-on-result` — stop when the cartridge writes the Blargg
  `$A000` signature (`DE B0 61`) and a final status, save `ROM.gb.sav`,
  and print the executed frame count as 8 little-endian bytes on stderr.
* `--verdict` — print `VERDICT xx` (the `$A000` status byte) at exit.
  Used by the `dmg_sound` test driver.

Cartridge RAM is saved as `ROM.gb.sav` (MBC1/3/5, when the header declares
RAM) and loaded at startup. Paths longer than 500 bytes and ROM images outside
32 KiB–8 MiB are rejected before any cartridge access.

## Implemented

* **CPU:** LR35902 primary and CB opcodes, flags, `DAA`, rotates, `BIT/RES/SET`,
  `PUSH/POP`, `CALL/RET/RST`, `EI` delay, `DI`, `RETI`, `HALT` wake-up,
  `ADD SP,e8` / `LD HL,SP+e8` half-carry rules. The boot ROM is skipped and
  the documented post-boot register state is installed.
* **PPU:** modes 0–3 with 456 dots/line and 154 lines, STAT mode and LYC
  coincidence interrupts, LY/LYC, BG and window layers, SCX/SCY, both tile-map
  bases, both tile-data addressing modes (0x8000 unsigned and 0x9000 signed),
  interleaved 2-byte tile rows, WX-7 window origin, OAM sprites (8×8/8×16,
  X/Y flips, OBP0/OBP1, BG priority and lower-X priority), OAM DMA, and the
  DMG four-shade palette. Rendering happens once per scanline at mode-3 entry.
* **APU:** 512 Hz frame sequencer, four channels, length counters, sweep,
  envelope, wave RAM and DMG wave read/write gating, NR52 power semantics,
  per-register read masks, mono 16-bit WAV. Channel timers advance per
  emulated T-cycle and a 4,194,304:44,100 accumulator emits samples at the
  correct average rate; samples are byte-identical across runs.
* **Cartridges:** ROM-only, MBC1 (ROM/RAM banking, mode 0/1), MBC3 (ROM/RAM
  banking; RTC registers are accepted but stubbed), MBC5 (9-bit ROM bank,
  4-bit RAM bank), RAM enable, RAM bank bounds, ROM-bank aliasing by real ROM
  size, and `.sav` persistence.
* **Other:** DIV/TIMA/TMA/TAC timer with falling-edge detection, VBlank/STAT/
  Timer/Serial/Joypad interrupts with individual IF clearing, P1 selection and
  A/B/Select/Start + D-pad mapping, serial SB/SC, echo RAM, HRAM, and OAM DMA.

## Deterministic tests

`make test` builds ten NASM-authored Game Boy test cartridges and asserts every
result. It exits non-zero on any failed check:

* CPU flag/instruction self-test (`CPU OK`, no `FAIL`).
* MBC1, MBC3 and MBC5 ROM/RAM banking, RAM enable, bank bounds and aliasing.
* MBC1 `.sav` contents in two RAM banks and a two-run save/load round trip.
* Joypad P1 mapping for A, B, Select, Start and all four D-pad directions.
* Timer interrupt flag preservation and STAT/LYC interrupts.
* PPU golden frame hash `e6f79d132215aa8978a2b12573db4cd5c67d335d1e0b7ec9a10bbfa817977d6d`,
  determinism, and a WX=15 window-origin pixel assertion.
* Hello cartridge serial `OK` and golden frame hash
  `6d6829cc88b0856f2f15addcf9879ea591ac26f16795347209cccc6e30050b82`.
* WAV via `ffprobe`: `pcm_s16le`, 44100 Hz, mono, 16-bit, 1.004558 s for
  60 frames, RIFF/data sizes equal the file, deterministic bytes, and
  884 zero crossings in 1.004558 s (≈440 Hz).
* Rejection of missing ROMs, ROMs below 32 KiB, and over-long paths.

The PPU test ROM specifically covers signed 0x9000 tile data, a negative tile
index (0x80 → 0x8800), interleaved tile rows, a WX=15 window, SCX/SCY,
8×8 sprite X/Y placement, X/Y flips, and both BG-priority and lower-X sprite
priority.

## Blargg results

These are measured results, not claims. ROMs are fetched from the public
`retrio/gb-test-roms` archive (not committed):

```sh
make fetch-blargg
make test-blargg
```

Run on 2026-11-09 against this tree:

| Suite | Result |
| --- | --- |
| `cpu_instrs` singles (11) | **11/11 Passed** |
| `mem_timing` singles (3) | **3/3 Passed** |
| `mem_timing-2` singles (3) | **3/3 Passed** |
| `dmg_sound` singles (12) | **12/12 Passed** (VERDICT 00) |
| `instr_timing` (1) | **1/1 Passed** |
| `oam_bug` singles (8) | **2/8 Passed** — OAM-bug behaviour is not emulated |
| `interrupt_time` | **no result**: produced neither serial output nor an `$A000` verdict |
| multicarts / `cgb_sound` | not part of the automated run; CGB mode is not implemented |

The automated Blargg job covers 30 singles (cpu_instrs, mem_timing,
mem_timing-2, dmg_sound, instr_timing) and requires every one to report
`Passed`/`VERDICT 00`. The `oam_bug` failures and the unsupported CGB suite are
reported here rather than counted as passes.

## CI

`.github/workflows/ci.yml` has two Ubuntu 24.04 jobs:

1. `deterministic` — installs NASM/binutils/ffmpeg, runs `make`, then
   `make test`.
2. `blargg` — builds, downloads the public Blargg ROMs, and runs
   `make test-blargg`.

## Known limitations

* MBC3 RTC is a stub (register select is accepted; no clock data). MBC2,
  MBC6, MBC7, HuC1/HuC3 and camera controllers are not implemented.
* MBC1 mode-1 high-bit ROM banking and MBC5 9-bit banking are implemented;
  non-power-of-two ROM bank counts are aliased with a bit mask rather than
  reproducing every exotic PCB's wiring.
* PPU access restrictions during modes 0–3 and OAM-bug corruption are not
  emulated; the `oam_bug` failures above follow from that.
* Rendering is per scanline at mode-3 entry; mid-scanline register changes and
  the exact mode-3 fetch schedule are not modelled.
* No CGB double-speed, CGB palettes, or stereo APU output. `STOP` is a short
  pause. Serial transfers complete immediately.
* No RTC persistence; only cartridge RAM is saved.
* The terminal renderer is bandwidth-heavy on busy screens; prefer `--dump`.
