; First run: "SAVE WRITE" after storing 5A. Second run: "SAVE OK".
BITS 16
%include "gb_macros.inc"
GB_HEADER 0x03,0x00,0x03       ; MBC1+RAM+BATTERY, 2 ROM banks, 32K RAM
main:
    DI
    LDSP 0xFFFE
    LDA 0x0A
    LD_A16_A 0x0000
    LDA_A16 0xA000
    CP_D8 0x5A
    JR_Z .found
    LDA 0x5A
    LD_A16_A 0xA000
    LDHL msg_write
    CALL print_str
    JR .hang
.found:
    LDHL msg_ok
    CALL print_str
.hang:
    JR .hang
%include "gb_routines.inc"
msg_ok:    db "SAVE OK",10,0
msg_write: db "SAVE WRITE",10,0
times 0x8000 - ($-$$) db 0x00
