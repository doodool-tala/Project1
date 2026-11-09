; Shared serial/debug routines for the test cartridges.
; Include after the cartridge's main code; all entry points are labels.

; A = character, transferred immediately by this emulator.
serial_put:
    LDH_A 0x01
    LDA 0x81
    LDH_A 0x02
    RET

; HL = zero-terminated string.
print_str:
    LDA_HL
    OR_D8 0
    RET_Z
    CALL serial_put
    INC_HL
    JP print_str

; A = byte, two uppercase hex digits.
print_hex:
    PUSH_AF
    SWAP_A
    CALL print_nib
    POP_AF
print_nib:
    AND_D8 0x0F
    CP_D8 10
    JR_C .digit
    ADD_D8 'A'-10
    JR .emit
.digit:
    ADD_D8 '0'
.emit:
    JP serial_put

print_nl:
    LDA 10
    JP serial_put

; A = failure code.
fail:
    PUSH_AF
    LDHL msg_fail
    CALL print_str
    POP_AF
    CALL print_hex
    CALL print_nl
.hang:
    JR .hang

wait_vblank:
    LDH_A_R 0x44
    CP_D8 144
    JR_NZ wait_vblank
    RET

wait_leave_vblank:
    LDH_A_R 0x44
    CP_D8 144
    JR_Z wait_leave_vblank
    RET

msg_fail: db "FAIL ",0
