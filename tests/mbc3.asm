; MBC3: 7-bit ROM bank (0 -> 1), RAM bank select, RTC selector safety.
BITS 16
%include "gb_macros.inc"
GB_HEADER 0x13,0x01,0x03       ; MBC3+RAM+BATTERY, 4 ROM banks, 32K RAM
main:
    DI
    LDSP 0xFFFE
    LDA 0x0A
    LD_A16_A 0x0000
    LDA 2
    LD_A16_A 0x2000
    LDA_A16 0x4000
    CP_D8 0xA2
    JR_Z .bank2
    LDA 1
    JP fail
.bank2:
    LDA 0
    LD_A16_A 0x2000             ; MBC3 turns bank 0 into bank 1
    LDA_A16 0x4000
    CP_D8 0xA1
    JR_Z .bank0
    LDA 2
    JP fail
.bank0:
    LDA 0x11
    LD_A16_A 0xA000
    LDA 1
    LD_A16_A 0x4000             ; RAM bank 1
    LDA 0x22
    LD_A16_A 0xA000
    LDA_A16 0xA000
    CP_D8 0x22
    JR_Z .ram1
    LDA 3
    JP fail
.ram1:
    LDA 0
    LD_A16_A 0x4000
    LDA_A16 0xA000
    CP_D8 0x11
    JR_Z .ram0
    LDA 4
    JP fail
.ram0:
    LDA 8
    LD_A16_A 0x4000             ; RTC seconds selector (stubbed)
    LDA_A16 0xA000
    CP_D8 0xFF
    JR_Z .rtc
    LDA 5
    JP fail
.rtc:
    LDA 0
    LD_A16_A 0x4000
    LDHL msg_ok
    CALL print_str
.hang:
    JR .hang
%include "gb_routines.inc"
msg_ok: db "MBC3 OK",10,0

times 0x4000 - ($-$$) db 0xFF
db 0xA1
times 0x8000 - ($-$$) db 0xFF
db 0xA2
times 0xC000 - ($-$$) db 0xFF
db 0xA3
times 0x10000 - ($-$$) db 0xFF
