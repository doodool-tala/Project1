; Prints "BTN hh" / "DPAD hh" for the selected group's low nibble.
; Expected: A=0E B=0D Select=0B Start=07, Right=0E Left=0D Up=0B Down=07.
BITS 16
%include "gb_macros.inc"
GB_HEADER 0x00,0x00,0x00
main:
    DI
    LDSP 0xFFFE
.loop:
    CALL wait_vblank
    LDA 0x10
    LDH_A 0x00
    LDH_A_R 0x00
    AND_D8 0x0F
    CP_D8 0x0F
    JR_Z .no_btn
    PUSH_AF
    LDHL msg_btn
    CALL print_str
    POP_AF
    CALL print_hex
    CALL print_nl
.no_btn:
    LDA 0x20
    LDH_A 0x00
    LDH_A_R 0x00
    AND_D8 0x0F
    CP_D8 0x0F
    JR_Z .no_dpad
    PUSH_AF
    LDHL msg_dpad
    CALL print_str
    POP_AF
    CALL print_hex
    CALL print_nl
.no_dpad:
    CALL wait_leave_vblank
    JP .loop
%include "gb_routines.inc"
msg_btn:  db "BTN ",0
msg_dpad: db "DPAD ",0
times 0x8000 - ($-$$) db 0x00
