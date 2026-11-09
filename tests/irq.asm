; Tests that servicing Timer clears only IF bit 2 (VBlank IF must survive),
; then enables the LYC STAT source and counts two coincidences.
BITS 16
%include "gb_macros.inc"
org 0
times 0x40 - ($-$$) db 0
JP irq_vblank
times 0x48 - ($-$$) db 0
JP irq_stat
times 0x50 - ($-$$) db 0
JP irq_timer
times 0x100 - ($-$$) db 0
db 0x00,0xC3
dw main
times 0x134 - ($-$$) db 0
db "TESTGB          "
db 0,0,0,0x00,0x00,0x00,0,0,0,0,0,0

main:
    DI
    LDSP 0xFFFE
    ; Timer has priority over nothing else; put VBlank IF (bit0) in the
    ; pending set but leave IE bit0 disabled. Servicing Timer must not
    ; clear it.
    LDA 0x04
    LDH_A 0xFF                 ; IE = Timer
    LDA 0x05
    LDH_A 0x0F                 ; IF = VBlank | Timer
    EI
    NOP
    NOP
    NOP
    ; LYC=100, STAT source bit6, IE=STAT
    LDA 100
    LDH_A 0x45
    LDA 0x40
    LDH_A 0x41
    LDA 0x02
    LDH_A 0xFF
    LDA 0x00
    LDH_A 0x0F
    LDB 0
    EI
.wait_lyc:
    LDA_B
    CP_D8 2
    JR_C .wait_lyc
    DI
    LDA 0x00
    LDH_A 0xFF
    LDH_A 0x0F
    LDHL msg_lyc
    CALL print_str
.hang:
    JR .hang

irq_vblank:
    RETI

irq_stat:
    PUSH_AF
    INC_B
    POP_AF
    RETI

irq_timer:
    PUSH_AF
    LDH_A_R 0x0F
    AND_D8 0x01
    CP_D8 0x01
    JR_Z .ok
    LDA 1
    JP fail
.ok:
    LDHL msg_irq
    CALL print_str
    LDA 0x00
    LDH_A 0xFF
    LDH_A 0x0F
    POP_AF
    RETI

%include "gb_routines.inc"
msg_irq: db "IRQ OK",10,0
msg_lyc: db "LYC OK",10,0
times 0x8000 - ($-$$) db 0x00
