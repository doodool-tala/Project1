; Minimal NASM macros that emit LR35902 opcodes for the test cartridges.
; The emulator itself is the only x86-64 code; these ROMs are data.
%macro GB_HEADER 3
    times 0x100 - ($-$$) db 0
    db 0x00,0xC3
    dw main
    times 0x134 - ($-$$) db 0
    db "TESTGB          "
    db 0,0,0,%1,%2,%3,0,0,0,0,0,0
%endmacro

%macro NOP 0
    db 0x00
%endmacro
%macro DI 0
    db 0xF3
%endmacro
%macro EI 0
    db 0xFB
%endmacro
%macro HALT 0
    db 0x76
%endmacro
%macro RET 0
    db 0xC9
%endmacro
%macro RETI 0
    db 0xD9
%endmacro
%macro RET_Z 0
    db 0xC8
%endmacro
%macro RET_NZ 0
    db 0xC0
%endmacro
%macro JP_HL 0
    db 0xE9
%endmacro
%macro SCF 0
    db 0x37
%endmacro
%macro CCF 0
    db 0x3F
%endmacro
%macro CPL 0
    db 0x2F
%endmacro
%macro DAA 0
    db 0x27
%endmacro
%macro RLCA 0
    db 0x07
%endmacro
%macro RRCA 0
    db 0x0F
%endmacro
%macro RLA 0
    db 0x17
%endmacro
%macro RRA 0
    db 0x1F
%endmacro
%macro SLA_B 0
    db 0xCB,0x20
%endmacro
%macro SWAP_A 0
    db 0xCB,0x37
%endmacro
%macro BIT_7_A 0
    db 0xCB,0x7F
%endmacro

%macro LDA 1
    db 0x3E,%1
%endmacro
%macro LDB 1
    db 0x06,%1
%endmacro
%macro LDC 1
    db 0x0E,%1
%endmacro
%macro LDD 1
    db 0x16,%1
%endmacro
%macro LDE 1
    db 0x1E,%1
%endmacro
%macro LDHL 1
    db 0x21
    dw %1
%endmacro
%macro LDBC 1
    db 0x01
    dw %1
%endmacro
%macro LDDE 1
    db 0x11
    dw %1
%endmacro
%macro LDSP 1
    db 0x31
    dw %1
%endmacro
%macro LD_A16_A 1
    db 0xEA
    dw %1
%endmacro
%macro LDA_A16 1
    db 0xFA
    dw %1
%endmacro
%macro LDH_A 1
    db 0xE0,%1
%endmacro
%macro LDH_A_R 1
    db 0xF0,%1
%endmacro
%macro LDA_HL 0
    db 0x7E
%endmacro
%macro LDHL_A 0
    db 0x77
%endmacro
%macro LDI_HL_A 0
    db 0x22
%endmacro
%macro LDA_B 0
    db 0x78
%endmacro
%macro LDA_C 0
    db 0x79
%endmacro
%macro LDA_D 0
    db 0x7A
%endmacro
%macro LDA_E 0
    db 0x7B
%endmacro
%macro LDA_H 0
    db 0x7C
%endmacro
%macro LDA_L 0
    db 0x7D
%endmacro
%macro LDB_A 0
    db 0x47
%endmacro
%macro LD_D_A 0
    db 0x57
%endmacro
%macro LDC_A 0
    db 0x4F
%endmacro
%macro INC_A 0
    db 0x3C
%endmacro
%macro DEC_A 0
    db 0x3D
%endmacro
%macro INC_B 0
    db 0x04
%endmacro
%macro DEC_B 0
    db 0x05
%endmacro
%macro INC_HL 0
    db 0x23
%endmacro
%macro DEC_HL 0
    db 0x2B
%endmacro
%macro DEC_DE 0
    db 0x1B
%endmacro
%macro ADD_HL_SP 0
    db 0x39
%endmacro
%macro ADD_SP 1
    db 0xE8,%1
%endmacro
%macro ADD_D8 1
    db 0xC6,%1
%endmacro
%macro ADC_D8 1
    db 0xCE,%1
%endmacro
%macro SUB_D8 1
    db 0xD6,%1
%endmacro
%macro SBC_D8 1
    db 0xDE,%1
%endmacro
%macro AND_D8 1
    db 0xE6,%1
%endmacro
%macro XOR_D8 1
    db 0xEE,%1
%endmacro
%macro OR_D8 1
    db 0xF6,%1
%endmacro
%macro CP_D8 1
    db 0xFE,%1
%endmacro
%macro CP_C 0
    db 0xB9
%endmacro
%macro CP_B 0
    db 0xB8
%endmacro
%macro PUSH_AF 0
    db 0xF5
%endmacro
%macro POP_AF 0
    db 0xF1
%endmacro
%macro PUSH_BC 0
    db 0xC5
%endmacro
%macro POP_BC 0
    db 0xC1
%endmacro
%macro PUSH_HL 0
    db 0xE5
%endmacro
%macro POP_HL 0
    db 0xE1
%endmacro

%macro JR 1
    db 0x18
    db %1 - $ - 1
%endmacro
%macro JR_NZ 1
    db 0x20
    db %1 - $ - 1
%endmacro
%macro JR_Z 1
    db 0x28
    db %1 - $ - 1
%endmacro
%macro JR_NC 1
    db 0x30
    db %1 - $ - 1
%endmacro
%macro JR_C 1
    db 0x38
    db %1 - $ - 1
%endmacro
%macro JP 1
    db 0xC3
    dw %1
%endmacro
%macro CALL 1
    db 0xCD
    dw %1
%endmacro

; Check the flags register (C after PUSH AF/POP BC) and A.
%macro CHK_F 2
    PUSH_AF
    POP_BC
    LDA %1
    CP_C
    JR_Z %%ok
    LDA %2
    JP fail
%%ok:
    LDA_B
%endmacro
%macro CHK_A 2
    CP_D8 %1
    JR_Z %%ok
    LDA %2
    JP fail
%%ok:
%endmacro
