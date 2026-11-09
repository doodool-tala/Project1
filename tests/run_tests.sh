#!/usr/bin/env bash
# Deterministic emulator checks. Any failed assertion exits non-zero.
set -u
cd "$(dirname "$0")/.."

GB=./gameboy
TMP=$(mktemp -d)
fails=0
trap 'rm -rf "$TMP"; rm -f tests/*.sav' EXIT

HELLO_HASH=6d6829cc88b0856f2f15addcf9879ea591ac26f16795347209cccc6e30050b82
PPU_HASH=e6f79d132215aa8978a2b12573db4cd5c67d335d1e0b7ec9a10bbfa817977d6d

ok()   { printf '  ok    %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; fails=$((fails + 1)); }
section() { printf '\n== %s ==\n' "$1"; }
contains() { if grep -q -- "$2" <<<"$3"; then ok "$1"; else bad "$1" "missing '$2' in: $(tr '\n' ' ' <<<"$3" | head -c 240)"; fi; }
not_contains() { if grep -q -- "$2" <<<"$3"; then bad "$1" "unexpected '$2' in: $(tr '\n' ' ' <<<"$3" | head -c 240)"; else ok "$1"; fi; }

section "CPU"
out=$(timeout 60 "$GB" --headless --frames 120 --serial tests/cpu.gb 2>&1 || true)
contains "CPU instruction/flag ROM" "CPU OK" "$out"
not_contains "CPU ROM reports no failure" "FAIL" "$out"

section "Cartridge controllers"
for name in mbc1 mbc3 mbc5; do
    rm -f "tests/$name.gb.sav"
    out=$(timeout 60 "$GB" --headless --frames 120 --serial "tests/$name.gb" 2>&1 || true)
    contains "$name banking/RAM ROM" "$(echo "$name" | tr '[:lower:]' '[:upper:]') OK" "$out"
done
if [ "$(stat -c %s tests/mbc1.gb.sav 2>/dev/null || echo 0)" = 32768 ] && \
   [ "$(od -An -tx1 -j0 -N1 tests/mbc1.gb.sav 2>/dev/null | tr -d ' \n')" = 5a ] && \
   [ "$(od -An -tx1 -j8192 -N1 tests/mbc1.gb.sav 2>/dev/null | tr -d ' \n')" = a5 ]; then
    ok "MBC1 .sav has both RAM banks"
else
    bad "MBC1 .sav contents" "expected 32 KiB, 5a at 0, a5 at 0x2000"
fi

section "Save persistence"
rm -f tests/save.gb.sav
out1=$(timeout 60 "$GB" --headless --frames 20 --serial tests/save.gb 2>&1 || true)
out2=$(timeout 60 "$GB" --headless --frames 20 --serial tests/save.gb 2>&1 || true)
contains "first run writes RAM" "SAVE WRITE" "$out1"
contains "second run loads RAM" "SAVE OK" "$out2"
if [ "$(stat -c %s tests/save.gb.sav 2>/dev/null || echo 0)" = 32768 ]; then
    ok "save file is the declared 32 KiB"
else
    bad "save file size"
fi

section "Joypad"
input_case() {
    local key=$1 expect=$2 label=$3
    local out
    out=$(printf '%s' "$key" | timeout 30 "$GB" --headless --frames 20 --serial tests/input.gb 2>&1 || true)
    out=$(tr -d '\r' <<<"$out")
    if [ "$out" = "$expect" ]; then ok "$label -> $expect"; else bad "$label" "expected '$expect', got '$out'"; fi
}
input_case x "BTN 0E" "A"
input_case z "BTN 0D" "B"
input_case ' ' "BTN 0B" "Select"
input_case $'\r' "BTN 07" "Start"
input_case w "DPAD 0B" "Up"
input_case s "DPAD 07" "Down"
input_case a "DPAD 0D" "Left"
input_case d "DPAD 0E" "Right"

section "Interrupts"
out=$(timeout 60 "$GB" --headless --frames 120 --serial tests/irq.gb 2>&1 || true)
contains "Timer IRQ leaves VBlank IF set" "IRQ OK" "$out"
contains "STAT/LYC interrupts fire" "LYC OK" "$out"

section "PPU"
if timeout 30 "$GB" --headless --frames 4 --dump "$TMP/ppu.ppm" tests/ppu.gb >/dev/null 2>&1; then
    h=$(sha256sum "$TMP/ppu.ppm" | cut -d' ' -f1)
    if [ "$h" = "$PPU_HASH" ]; then ok "PPU golden frame hash"; else bad "PPU golden frame hash" "got $h"; fi
    if [ "$(stat -c %s "$TMP/ppu.ppm")" = 69135 ]; then ok "PPM is 160x144 RGB"; else bad "PPM size"; fi
    # WX=15 means the window's first column is screen x = 8; tile 2 left half
    # maps to DMG palette 1. A raw WX start would paint x=15 instead.
    off=$((15 + (20 * 160 + 8) * 3))
    rgb=$(od -An -tu1 -j"$off" -N3 "$TMP/ppu.ppm" | tr -s ' ' | sed 's/^ //;s/ $//')
    if [ "$rgb" = "136 192 112" ]; then ok "window WX offset (starts at x=8)"; else bad "window WX offset" "got RGB '$rgb'"; fi
    timeout 30 "$GB" --headless --frames 4 --dump "$TMP/ppu2.ppm" tests/ppu.gb >/dev/null 2>&1 || true
    if cmp -s "$TMP/ppu.ppm" "$TMP/ppu2.ppm"; then ok "PPU frame is deterministic"; else bad "PPU frame determinism"; fi
else
    bad "PPU ROM run"
fi

section "Hello cartridge"
if timeout 30 "$GB" --headless --frames 240 --serial --dump "$TMP/hello.ppm" tests/hello.gb >"$TMP/hello.out" 2>&1; then
    contains "hello serial OK" "OK" "$(cat "$TMP/hello.out")"
    h=$(sha256sum "$TMP/hello.ppm" | cut -d' ' -f1)
    if [ "$h" = "$HELLO_HASH" ]; then ok "hello golden frame hash"; else bad "hello golden frame hash" "got $h"; fi
else
    bad "hello ROM run"
fi

section "Audio"
if command -v ffprobe >/dev/null 2>&1 && command -v ffmpeg >/dev/null 2>&1; then
    timeout 60 "$GB" --headless --frames 60 --audio "$TMP/a1.wav" tests/audio.gb >/dev/null 2>&1 || true
    timeout 60 "$GB" --headless --frames 60 --audio "$TMP/a2.wav" tests/audio.gb >/dev/null 2>&1 || true
    if [ -s "$TMP/a1.wav" ]; then ok "WAV written"; else bad "WAV written"; fi
    if cmp -s "$TMP/a1.wav" "$TMP/a2.wav"; then ok "WAV is deterministic"; else bad "WAV determinism"; fi
    meta=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name,sample_rate,channels,bits_per_sample -of csv=p=0 "$TMP/a1.wav" 2>/dev/null || true)
    if [ "$meta" = "pcm_s16le,44100,1,16" ]; then ok "ffprobe stream metadata"; else bad "ffprobe stream metadata" "got '$meta'"; fi
    dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$TMP/a1.wav" 2>/dev/null || echo 0)
    if awk -v d="$dur" 'BEGIN{exit !(d >= 0.99 && d <= 1.02)}'; then ok "WAV duration 60 frames ($dur s)"; else bad "WAV duration" "$dur"; fi
    fsz=$(stat -c %s "$TMP/a1.wav")
    riff=$(od -An -tu4 -j4 -N4 "$TMP/a1.wav" | tr -d ' ')
    data=$(od -An -tu4 -j40 -N4 "$TMP/a1.wav" | tr -d ' ')
    if [ $((riff + 8)) -eq "$fsz" ] && [ $((data + 44)) -eq "$fsz" ]; then ok "RIFF/data sizes match file"; else bad "RIFF/data sizes" "riff=$riff data=$data file=$fsz"; fi
    zc=$(ffmpeg -hide_banner -nostats -i "$TMP/a1.wav" -af astats=metadata=1:reset=0 -f null - 2>&1 | sed -n 's/.*Zero crossings: \([0-9][0-9]*\).*/\1/p' | head -n1)
    if awk -v z="$zc" 'BEGIN{exit !(z >= 850 && z <= 920)}'; then ok "440 Hz square (zero crossings $zc)"; else bad "440 Hz frequency" "zero crossings '$zc'"; fi
else
    bad "ffprobe/ffmpeg available" "install ffmpeg to verify WAVs"
fi

section "Input validation"
if "$GB" --headless >/dev/null 2>&1; then bad "no ROM argument is rejected"; else ok "no ROM argument is rejected"; fi
head -c 4096 /dev/zero > "$TMP/short.gb"
if "$GB" --headless --frames 1 "$TMP/short.gb" >/dev/null 2>&1; then bad "short ROM is rejected"; else ok "short ROM is rejected"; fi
longarg="/$(printf 'a%.0s' {1..600})"
out=$("$GB" --headless --frames 1 "$longarg" 2>&1 || true)
contains "over-long ROM path is rejected" "path too long" "$out"

printf '\n'
if [ "$fails" -ne 0 ]; then
    printf '%d check(s) failed\n' "$fails"
    exit 1
fi
printf 'All deterministic checks passed.\n'
