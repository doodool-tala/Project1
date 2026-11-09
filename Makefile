NASM ?= nasm
LD ?= ld

TEST_ROMS = tests/hello.gb tests/cpu.gb tests/ppu.gb tests/mbc1.gb \
            tests/mbc3.gb tests/mbc5.gb tests/input.gb tests/irq.gb \
            tests/audio.gb tests/save.gb

all: gameboy

gameboy: src/gameboy.asm
	$(NASM) -f elf64 -o gameboy.o src/gameboy.asm
	$(LD) -o gameboy gameboy.o
	strip gameboy 2>/dev/null || true

tests/%.gb: tests/%.asm tests/gb_macros.inc tests/gb_routines.inc
	$(NASM) -f bin -i tests/ -o $@ $<

test: gameboy $(TEST_ROMS)
	bash tests/run_tests.sh

fetch-blargg:
	bash tests/fetch_blargg.sh

test-blargg: gameboy
	bash tests/fetch_blargg.sh
	bash tests/run_blargg.sh

clean:
	rm -f gameboy gameboy.o tests/*.gb tests/*.sav /tmp/frame.ppm

.PHONY: all test test-blargg fetch-blargg clean
