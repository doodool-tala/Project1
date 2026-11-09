#!/usr/bin/env bash
# Runs the public Blargg singles that this emulator has been tested against.
# ROMs are downloaded by tests/fetch_blargg.sh and are not part of this repo.
set -u
cd "$(dirname "$0")/.."

GB=./gameboy
R=tests/roms/gb-test-roms-master
fails=0
total=0

ok()  { printf '  PASS  %s\n' "$1"; total=$((total + 1)); }
bad() { printf '  FAIL  %s%s\n' "$1" "${2:+: $2}"; total=$((total + 1)); fails=$((fails + 1)); }

if [ ! -d "$R" ]; then
    echo "Blargg ROMs missing; run 'make fetch-blargg' first." >&2
    exit 2
fi

printf '\n== cpu_instrs singles ==\n'
for f in "$R"/cpu_instrs/individual/*.gb; do
    [ -e "$f" ] || continue
    rm -f "$f.sav"
    out=$(timeout 120 "$GB" --headless --frames 5000 --serial "$f" 2>&1 || true)
    if grep -q "Passed" <<<"$out" && ! grep -q "Failed" <<<"$out"; then
        ok "$(basename "$f")"
    else
        bad "$(basename "$f")" "$(tr '\n' ' ' <<<"$out" | tail -c 160)"
    fi
done

printf '\n== mem_timing singles ==\n'
for f in "$R"/mem_timing/individual/*.gb; do
    [ -e "$f" ] || continue
    rm -f "$f.sav"
    out=$(timeout 120 "$GB" --headless --frames 5000 --serial "$f" 2>&1 || true)
    if grep -q "Passed" <<<"$out" && ! grep -q "Failed" <<<"$out"; then
        ok "$(basename "$f")"
    else
        bad "$(basename "$f")" "$(tr '\n' ' ' <<<"$out" | tail -c 160)"
    fi
done

printf '\n== mem_timing-2 singles ==\n'
for f in "$R"/mem_timing-2/rom_singles/*.gb; do
    [ -e "$f" ] || continue
    rm -f "$f.sav"
    out=$(timeout 120 "$GB" --headless --exit-on-result --verdict "$f" 2>/dev/null || true)
    if grep -q "VERDICT 00" <<<"$out"; then
        ok "$(basename "$f")"
    else
        bad "$(basename "$f")" "$(tr '\n' ' ' <<<"$out" | tail -c 160)"
    fi
done

printf '\n== dmg_sound singles (RAM verdict) ==\n'
for f in "$R"/dmg_sound/rom_singles/*.gb; do
    [ -e "$f" ] || continue
    rm -f "$f.sav"
    out=$(timeout 120 "$GB" --headless --exit-on-result --verdict "$f" 2>/dev/null || true)
    if grep -q "VERDICT 00" <<<"$out"; then
        ok "$(basename "$f")"
    else
        bad "$(basename "$f")" "$(tr '\n' ' ' <<<"$out" | tail -c 160)"
    fi
done

printf '\n== instr_timing ==\n'
if [ -f "$R/instr_timing/instr_timing.gb" ]; then
    f="$R/instr_timing/instr_timing.gb"
    rm -f "$f.sav"
    out=$(timeout 120 "$GB" --headless --frames 5000 --serial "$f" 2>&1 || true)
    if grep -q "Passed" <<<"$out" && ! grep -q "Failed" <<<"$out"; then
        ok "$(basename "$f")"
    else
        bad "$(basename "$f")" "$(tr '\n' ' ' <<<"$out" | tail -c 160)"
    fi
fi

printf '\n'
if [ "$fails" -ne 0 ]; then
    printf 'Blargg: %d/%d passed\n' "$((total - fails))" "$total"
    exit 1
fi
printf 'Blargg: all %d available singles passed.\n' "$total"
