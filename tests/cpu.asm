; CPU instruction/flag test cartridge. Prints "CPU OK" or "FAIL nn".
BITS 16
%include "gb_macros.inc"
GB_HEADER 0x00,0x00,0x00
main:
    DI
    LDSP 0xFFFE
    ; 1: 0F+01 -> 10, H
    LDA 0x0F
    ADD_D8 0x01
    CHK_F 0x20,1
    CHK_A 0x10,2
    ; 2: FF+01 -> 00, Z H C
    LDA 0xFF
    ADD_D8 0x01
    CHK_F 0xB0,3
    CHK_A 0x00,4
    ; 3: ADC with carry
    SCF
    LDA 0x0F
    ADC_D8 0x00
    CHK_F 0x20,5
    CHK_A 0x10,6
    ; 4: 10-01 -> 0F, N H
    LDA 0x10
    SUB_D8 0x01
    CHK_F 0x60,7
    CHK_A 0x0F,8
    ; 5: 00-00-C -> FF, N H C
    SCF
    LDA 0x00
    SBC_D8 0x00
    CHK_F 0x70,9
    CHK_A 0xFF,10
    ; 6: AND clears to zero, Z H
    LDA 0xAA
    AND_D8 0x00
    CHK_F 0xA0,11
    CHK_A 0x00,12
    ; 7: XOR self, Z
    LDA 0xAA
    XOR_D8 0xAA
    CHK_F 0x80,13
    CHK_A 0x00,14
    ; 8: CP equal, Z N
    LDA 0x10
    CP_D8 0x10
    CHK_F 0xC0,15
    CHK_A 0x10,16
    ; 9: INC 0F -> 10, H
    LDA 0x0F
    INC_A
    CHK_F 0x20,17
    CHK_A 0x10,18
    ; 10: DEC 10 -> 0F, N H
    LDA 0x10
    DEC_A
    CHK_F 0x60,19
    CHK_A 0x0F,20
    ; 11: RLCA of 80 -> 01, C
    LDA 0x80
    RLCA
    CHK_F 0x10,21
    CHK_A 0x01,22
    ; 12: RRCA of 01 -> 80, C
    LDA 0x01
    RRCA
    CHK_F 0x10,23
    CHK_A 0x80,24
    ; 13: RLA through carry of 80 -> 01, C
    SCF
    LDA 0x80
    RLA
    CHK_F 0x10,25
    CHK_A 0x01,26
    ; 14: DAA after 09+01 -> 10
    LDA 0x09
    ADD_D8 0x01
    DAA
    CHK_F 0x00,27
    CHK_A 0x10,28
    ; 15: SLA B of 80 -> 00, Z C (preserve B across the flag check)
    LDB 0x80
    SLA_B
    LDA_B
    LD_D_A
    CHK_F 0x90,29
    LDA_D
    CHK_A 0x00,30
    ; 16: BIT 7,A on 80 -> H only
    LDA 0x80
    BIT_7_A
    CHK_F 0x20,31
    CHK_A 0x80,32
    ; 17: SWAP A of 12 -> 21
    LDA 0x12
    SWAP_A
    CHK_F 0x00,33
    CHK_A 0x21,34
    ; 18: CPL AA -> 55, N H; CPL preserves Z and C, so start with Z=0.
    LDA 0xAA
    CP_D8 0x00
    CPL
    CHK_F 0x60,35
    CHK_A 0x55,36
    ; 19: PUSH/POP AF round trip
    LDA 0x12
    PUSH_AF
    LDA 0x00
    POP_AF
    CHK_A 0x12,37
    ; 20: CALL/RET
    CALL sub_inc
    CHK_A 0x43,38
    ; 21: ADD SP,-1 sets H C and wraps SP
    LDSP 0xFFF8
    ADD_SP 0xFF
    CHK_F 0x30,39
    LDHL 0x0000
    ADD_HL_SP
    LDA_H
    CHK_A 0xFF,40
    LDA_L
    CHK_A 0xF7,41
    ; 22: SCF/CCF carry handling from a known Z=0 flag state
    LDA 0x01
    CP_D8 0x00
    SCF
    CCF
    CHK_F 0x00,42
    ; all good
    LDHL msg_ok
    CALL print_str
.hang:
    JR .hang

sub_inc:
    LDA 0x42
    INC_A
    RET

%include "gb_routines.inc"
msg_ok: db "CPU OK",10,0
times 0x8000 - ($-$$) db 0x00
