NASM ?= nasm
LD ?= ld
all: gameboy
gameboy: src/gameboy.asm
	$(NASM) -f elf64 -o gameboy.o src/gameboy.asm
	$(LD) -o gameboy gameboy.o
	strip gameboy || true
test: gameboy tests/hello.gb
	./gameboy --headless --frames 240 --dump /tmp/frame.ppm tests/hello.gb
	ls -lh /tmp/frame.ppm
tests/hello.gb: tests/hello.asm
	$(NASM) -f bin -o $@ $<
clean:
	rm -f gameboy gameboy.o tests/hello.gb /tmp/frame.ppm
.PHONY: all test clean
