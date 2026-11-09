; MBC5: 9-bit ROM bank, 4-bit RAM bank, bank 0 legal.
BITS 16
%include "gb_macros.inc"
GB_HEADER 0x1B,0x02,0x03       ; MBC5+RAM+BATTERY, 8 ROM banks, 32K RAM
main:
    DI
    LDSP 0xFFFE
    LDA 0x0A
    LD_A16_A 0x0000
    LDA 5
    LD_A16_A 0x2000
    LDA_A16 0x4000
    CP_D8 0xA5
    JR_Z .bank5
    LDA 1
    JP fail
.bank5:
    LDA 5
    LD_A16_A 0x2000
    LDA 1
    LD_A16_A 0x3000             ; bank 0x105 aliases bank 5 in an 8-bank ROM
    LDA_A16 0x4000
    CP_D8 0xA5
    JR_Z .bank9
    LDA 2
    JP fail
.bank9:
    LDA 0
    LD_A16_A 0x3000
    LDA 1
    LD_A16_A 0x2000
    LDA_A16 0x4000
    CP_D8 0xA1
    JR_Z .bank1
    LDA 3
    JP fail
.bank1:
    LDA 0x33
    LD_A16_A 0xA000
    LDA 1
    LD_A16_A 0x4000
    LDA 0x44
    LD_A16_A 0xA000
    LDA_A16 0xA000
    CP_D8 0x44
    JR_Z .ram1
    LDA 4
    JP fail
.ram1:
    LDA 0x0F
    LD_A16_A 0x4000             ; RAM bank 15 aliases bank 3
    LDA 0x55
    LD_A16_A 0xA000
    LDA_A16 0xA000
    CP_D8 0x55
    JR_Z .ram15
    LDA 5
    JP fail
.ram15:
    LDA 0
    LD_A16_A 0x4000
    LDA_A16 0xA000
    CP_D8 0x33
    JR_Z .ram0
    LDA 6
    JP fail
.ram0:
    LDHL msg_ok
    CALL print_str
.hang:
    JR .hang
%include "gb_routines.inc"
msg_ok: db "MBC5 OK",10,0

times 0x4000 - ($-$$) db 0xFF
db 0xA1
times 0x8000 - ($-$$) db 0xFF
db 0xA2
times 0xC000 - ($-$$) db 0xFF
db 0xA3
times 0x10000 - ($-$$) db 0xFF
db 0xA4
times 0x14000 - ($-$$) db 0xFF
db 0xA5
times 0x18000 - ($-$$) db 0xFF
db 0xA6
times 0x1C000 - ($-$$) db 0xFF
db 0xA7
times 0x20000 - ($-$$) db 0xFF
