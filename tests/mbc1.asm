; MBC1: ROM bank select, out-of-range alias, RAM enable, RAM bank mode.
BITS 16
%include "gb_macros.inc"
GB_HEADER 0x03,0x02,0x03       ; MBC1+RAM+BATTERY, 8 ROM banks, 32K RAM
main:
    DI
    LDSP 0xFFFE
    LDA 0x0A
    LD_A16_A 0x0000             ; enable RAM
    LDA 2
    LD_A16_A 0x2000
    LDA_A16 0x4000
    CP_D8 0xA2
    JR_Z .bank2
    LDA 1
    JP fail
.bank2:
    LDA 1
    LD_A16_A 0x2000
    LDA_A16 0x4000
    CP_D8 0xA1
    JR_Z .bank1
    LDA 2
    JP fail
.bank1:
    LDA 9                       ; 8-bank cart: bank 9 aliases bank 1
    LD_A16_A 0x2000
    LDA_A16 0x4000
    CP_D8 0xA1
    JR_Z .alias
    LDA 3
    JP fail
.alias:
    LDA 0x5A
    LD_A16_A 0xA000             ; RAM bank 0
    LDA 1
    LD_A16_A 0x6000             ; MBC1 mode 1
    LDA 1
    LD_A16_A 0x4000             ; RAM bank 1
    LDA 0xA5
    LD_A16_A 0xA000
    LDA_A16 0xA000
    CP_D8 0xA5
    JR_Z .ram1
    LDA 4
    JP fail
.ram1:
    LDA 0
    LD_A16_A 0x4000             ; RAM bank 0
    LDA_A16 0xA000
    CP_D8 0x5A
    JR_Z .ram0
    LDA 5
    JP fail
.ram0:
    LDA 0
    LD_A16_A 0x0000             ; disable RAM
    LDA_A16 0xA000
    CP_D8 0xFF
    JR_Z .disabled
    LDA 6
    JP fail
.disabled:
    LDA 0x0A
    LD_A16_A 0x0000
    LDHL msg_ok
    CALL print_str
.hang:
    JR .hang
%include "gb_routines.inc"
msg_ok: db "MBC1 OK",10,0

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
