; Channel 1, 50% duty, full volume, ~440 Hz: 131072/(2048-1750).
BITS 16
%include "gb_macros.inc"
GB_HEADER 0x00,0x00,0x00
main:
    DI
    LDSP 0xFFFE
    LDA 0x80
    LDH_A 0x26                 ; NR52 power on
    LDA 0x77
    LDH_A 0x24                 ; NR50 max volume
    LDA 0x11
    LDH_A 0x25                 ; NR51 channel 1 to both outputs
    LDA 0x80
    LDH_A 0x11                 ; NR11 duty 50%
    LDA 0xF0
    LDH_A 0x12                 ; NR12 volume 15, no envelope
    LDA 0xD6
    LDH_A 0x13                 ; NR13 frequency low
    LDA 0x86
    LDH_A 0x14                 ; NR14 trigger + frequency high 6
.hang:
    JR .hang
%include "gb_routines.inc"
times 0x8000 - ($-$$) db 0x00
