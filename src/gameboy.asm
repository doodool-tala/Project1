; ============================================================================
;  GameBoy / GameBoy Color (DMG/CGB CPU+PPU) Emulator in PURE x86-64 Assembly
;  Crouton Alpha - no C, no libc, no libraries. Linux syscalls only.
;  Assembles with NASM:  nasm -f elf64 -o gameboy.o src/gameboy.asm && ld -o gameboy gameboy.o
;  Usage: ./gameboy [--headless] [--frames N] [--dump FILE.ppm] [--serial] [--audio FILE.wav] ROM.gb
;  Terminal mode: raw keyboard - Arrows/WASD=D-pad  Z=B  X=A  Enter=Start  Space=Select  Esc=quit
;  Implements: full LR35902 CPU (+CB), PPU (BG/Window/Sprites, STAT, modes 0-3),
;  DIV/TIMA timers, serial, joypad, APU (4ch square/wave/noise -> WAV), MBC1/3/5+RAM, echo RAM, HRAM, DMA.
; ============================================================================
BITS 64
default rel
section .text
global _start

; ---- syscall numbers ----
SYS_read    equ 0
SYS_write   equ 1
SYS_open    equ 2
SYS_close   equ 3
SYS_mmap    equ 9
SYS_mprotect equ 10
SYS_ioctl   equ 16
SYS_lseek   equ 8
SYS_exit    equ 60
SYS_exit_group equ 231
SYS_nanosleep equ 35
SYS_select  equ 23
SYS_fcntl   equ 72
O_RDONLY equ 0
O_WRONLY equ 1
O_RDWR   equ 2
O_CREAT  equ 64
O_TRUNC  equ 512
PROT_RW  equ 3
MAP_PRIV_ANON equ 0x22
TCGETS equ 0x5401
TCSETS equ 0x5402
F_GETFL equ 3
F_SETFL equ 4
O_NONBLOCK equ 2048

%macro SYS1 1
    mov rax,%1
    syscall
%endmacro
%macro SYS3 3
    mov rax,%1
    mov rdi,%2
    mov rsi,%3
    syscall
%endmacro
%macro SYS6 6
    mov rax,%1
    mov rdi,%2
    mov rsi,%3
    mov rdx,%4
    mov r10,%5
    mov r8,%6
    mov r9,%7
    syscall
%endmacro
; Actually SYS6 needs 6 args: num,a,b,c,d,e,f  -- we use SYS6_ variant below
%macro EXIT 1
    mov rdi,%1
    mov rax,SYS_exit
    syscall
%endmacro
%macro PUSHALL 0
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
%endmacro
%macro POPALL 0
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
%endmacro

; ============================================================================
;  BSS - all emulator state
; ============================================================================
section .bss
gb_a:    resb 1
gb_f:    resb 1
gb_b:    resb 1
gb_c:    resb 1
gb_d:    resb 1
gb_e:    resb 1
gb_h:    resb 1
gb_l:    resb 1
gb_sp:   resw 1
gb_pc:   resw 1
ime:     resb 1
ei_delay: resb 1
halted:  resb 1
stop_flag: resb 1
rom_ptr: resq 1
rom_size: resq 1
rom_banks: resd 1
rom_mask:  resd 1      ; rom_banks-1, bank alias mask
mbc_type: resb 1
mbc_family: resb 1        ; 0 ROM-only, 1 MBC1, 3 MBC3, 5 MBC5
mbc_rom_bank: resd 1      ; low 5 bits (mbc1) / full 9 bits (mbc5)
mbc_ram_bank: resd 1
mbc_mode: resb 1          ; MBC1 mode (0/1)
mbc1_hi: resb 1           ; MBC1 2-bit bank/mode register
ram_enable: resb 1        ; MBC1/3/5 external RAM enable
ram_mask: resd 1          ; ram_banks-1
ram_banks: resd 1
vram:    resb 0x2000
wram:    resb 0x2000
extram:  resb 0x20000     ; 16 x 8K MBC RAM banks (MBC5 can select 16)
oam:     resb 0xA0
io:      resb 0x80        ; FF00-FF7F
hram:    resb 0x7F        ; FF80-FFFE
ie_reg:  resb 1
if_reg:  resb 1           ; mirror for convenience, kept in io[0x0F] too
framebuf: resb 160*144*3  ; RGB 24-bit
; PPU
ppu_dot: resw 1
ppu_ly:  resb 1
ppu_mode: resb 1
stat_prev: resb 1
; per-scanline pixel state used by the sprite compositor
bg_line_idx:  resb 160
spr_line_col: resb 160
spr_line_attr: resb 160
spr_line_x:   resb 160
; Timer
div_counter: resd 1
tima_counter: resd 1
prev_tac_bit: resb 1
; Joypad keys (1=pressed)
key_up:    resb 1
key_down:  resb 1
key_left:  resb 1
key_right: resb 1
key_a:     resb 1
key_b:     resb 1
key_start: resb 1
key_select: resb 1
p1_old:    resb 1        ; selected P1 lines before the latest key poll
; CLI / runtime
cli_headless: resb 1
cli_debug: resb 1
debug_count: resq 1
cli_frames:   resq 1
cli_serial:   resb 1
cli_exitres:  resb 1
cli_verdict:  resb 1
rom_fd:    resq 1
dump_path: resq 1
dump_len:  resq 1
audio_fd:  resq 1
audio_enabled: resb 1
audio_buf: resb 16384
audio_buf_len: resq 1
audio_accum: resq 1       ; cycles * 44100 fixed point
audio_bytes: resq 1       ; PCM bytes written (for the RIFF header)
serial_fd: resq 1   ; fd to write serial bytes (1)
saved_termios: resb 64
termios_raw: resb 64
stdin_nonblock: resb 1
frames_done: resq 1
sav_path:  resb 512
sav_len:   resq 1
; APU channel state: 4 channels * 32 bytes
;  0 enabled,1 duty_pos,2 duty,3 timer(32),4 period(32),5 vol,6 env_vol,7 env_dir,
;  8 len_ctr(16),9 freq(16),10 sweep_ctr,11 sweep_time,12 sweep_dir,13 sweep_mask,
;  14 noise_lfsr(16),15 wave_pos,16 frac,17 len_enable,18 env_time,19 env_ctr
apu_ch:  resb 4*32
apu_frame_ctr: resd 1
apu_env_ctr:   resd 1
; misc scratch
scratch: resb 256
outbuf:  resb 65536
readbuf: resb 256

section .data
rom_path_str: dq 0
audio_path_ptr: dq 0
rom_path_len: dq 0
title_buf: times 16 db 0
palette_rgb: db 228,240,222, 136,192,112, 52,104,86, 12,56,36
; 44-byte canonical PCM WAV header; sizes at +4 and +40 are patched on close
align 4
wav_header:
    db "RIFF",0,0,0,0,"WAVE","fmt ",16,0,0,0,1,0,1,0
    dd 44100
    dd 88200
    dw 2,16
    db "data",0,0,0,0
msg_usage: db "Usage: gameboy [--headless] [--frames N] [--dump FILE.ppm] [--serial] [--audio FILE.wav] [--exit-on-result] [--verdict] ROM.gb",10,0
msg_openfail: db "gameboy: cannot open ROM",10,0
msg_badrom: db "gameboy: invalid ROM size (need 32 KiB..8 MiB)",10,0
msg_badpath: db "gameboy: ROM path too long",10,0
msg_readfail: db "gameboy: short read",10,0
msg_verdict: db "VERDICT ",0
msg_noargs: db "gameboy: no ROM given",10,0
msg_loading: db "Loading: ",0
msg_title: db " Title: ",0
msg_mbc: db " MBC type: ",0
msg_newline: db 10,0
msg_booted: db "Booted. Terminal: arrows/WASD D-pad, Z=B X=A Enter=Start Space=Select Esc=quit",10,0
dbg_colon: db ":",0
dbg_nl: db 10,0
esc_hide: db 27,"[?25l",27,"[2J",27,"[H",0
esc_show: db 27,"[?25h",27,"[0m",0
esc_home: db 27,"[H",0
esc_reset: db 27,"[0m",0
block_char: db 0xE2,0x96,0x80   ; U+2580
; opcode tables filled in .rodata section below

section .rodata
; main opcode dispatch table (256 * 8) - filled by labels, assembled as absolute addrs (non-PIE)
align 8
opcode_table:
%assign i 0
%rep 256
    dq op_xx
%assign i i+1
%endrep
; We patch per-opcode below using a second table built in text via macros is complex;
; instead dispatch uses range checks + this table for the "misc" opcodes.
; cb_table
cb_table:
%rep 256
    dq cb_xx
%endrep

section .text
; ---------- utility: strlen(rdi=ptr) -> rax ----------
strlen:
    xor rax,rax
.l: cmp byte [rdi+rax],0
    je .d
    inc rax
    jmp .l
.d: ret
; ---------- write_all(rdi=fd, rsi=buf, rdx=len) ----------
write_all:
    push rbx
    push r12
    push r13
    mov rbx,rdx
    mov r12,rsi
    mov r13,rdi
.w: test rbx,rbx
    jz .d
    mov rax,SYS_write
    mov rdi,r13
    mov rsi,r12
    mov rdx,rbx
    syscall
    cmp rax,0
    jle .d
    add r12,rax
    sub rbx,rax
    jmp .w
.d: pop r13
    pop r12
    pop rbx
    ret
; print rsi=len bytes at rdi to stdout
print_mem:
    push rdi
    push rsi
    push rdx
    mov rdx,rsi
    mov rsi,rdi
    mov rdi,1
    call write_all
    pop rdx
    pop rsi
    pop rdi
    ret
; prints0 rdi
prints0:
    push rdi
    call strlen
    mov rsi,rax
    pop rdi
    push rdi
    ; print_mem expects rdi=ptr rsi=len
    mov rdx,0
    call print_mem
    pop rdi
    ret
; strcmp rdi,rsi -> rax 0 equal
strcmp:
    push rbx
    xor rbx,rbx
.l: mov al,[rdi+rbx]
    mov dl,[rsi+rbx]
    cmp al,dl
    jne .ne
    test al,al
    jz .eq
    inc rbx
    jmp .l
.eq: xor rax,rax
    jmp .d
.ne: mov rax,1
.d: pop rbx
    ret
; parse_uint rdi=ptr -> rax
parse_uint:
    xor rax,rax
.l: mov dl,[rdi]
    cmp dl,'0'
    jb .d
    cmp dl,'9'
    ja .d
    imul rax,rax,10
    movzx rdx,dl
    sub rdx,'0'
    add rax,rdx
    inc rdi
    jmp .l
.d: ret
; hex digit print helpers for debug: print_hex8 al
print_hex8:
    push rax
    push rdi
    push rsi
    push rdx
    mov rdx,rax
    shr al,4
    call print_nib
    mov al,dl
    and al,0x0F
    call print_nib
    pop rdx
    pop rsi
    pop rdi
    pop rax
    ret
print_nib: ; al 0-15
    push rax
    push rdi
    push rsi
    push rdx
    cmp al,10
    jb .d
    add al,'A'-10
    jmp .o
.d: add al,'0'
.o: mov [scratch],al
    mov rdi,scratch
    mov rsi,1
    call print_mem
    pop rdx
    pop rsi
    pop rdi
    pop rax
    ret
print_str_radix: ; rax = unsigned -> stdout decimal
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    xor rcx,rcx
    test rax,rax
    jnz .l
    mov byte [scratch],'0'
    lea rdi,[scratch]
    mov rsi,1
    call print_mem
    jmp .d
.l:
    xor rdx,rdx
    mov rbx,10
    div rbx
    add dl,'0'
    push rdx
    inc rcx
    test rax,rax
    jnz .l
    mov rsi,rcx
    lea rdi,[scratch]
    xor rbx,rbx
.w: pop rax
    mov [rdi+rbx],al
    inc rbx
    cmp rbx,rcx
    jb .w
    mov rsi,rcx
    lea rdi,[scratch]
    call print_mem
.d: pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret
; ---------- _start ----------
_start:
    mov rbp,rsp
    mov rax,[rbp]          ; argc
    cmp rax,2
    jl .noargs
    ; defaults
    mov qword [cli_frames],0
    mov byte [cli_headless],0
    mov byte [cli_serial],0
    mov byte [cli_exitres],0
    mov byte [cli_verdict],0
    mov qword [serial_fd],1
    mov qword [audio_fd],-1
    mov qword [dump_path],0
    mov dword [mbc_rom_bank],1
    mov dword [mbc_ram_bank],0
    mov byte [mbc_mode],0
    mov dword [ram_banks],1
    ; parse args
    xor r13,r13            ; index
    mov r14,1
.parse:
    cmp r14,[rbp]
    jge .parsed
    mov r12,[rbp+r14*8+8]
    mov rdi,r12
    lea rsi,[str_headless]
    call strcmp
    test rax,rax
    jz .set_headless
    mov rdi,r12
    lea rsi,[str_serial]
    call strcmp
    test rax,rax
    jz .set_serial
    mov rdi,r12
    lea rsi,[str_debug]
    call strcmp
    test rax,rax
    jz .set_debug
    mov rdi,r12
    lea rsi,[str_frames]
    call strcmp
    test rax,rax
    jz .opt_frames
    mov rdi,r12
    lea rsi,[str_dump]
    call strcmp
    test rax,rax
    jz .opt_dump
    mov rdi,r12
    lea rsi,[str_audio]
    call strcmp
    test rax,rax
    jz .opt_audio
    mov rdi,r12
    lea rsi,[str_exitres]
    call strcmp
    test rax,rax
    jz .set_exitres
    mov rdi,r12
    lea rsi,[str_verdict]
    call strcmp
    test rax,rax
    jz .set_verdict
    ; else rom path
    mov rax,[rbp+r14*8+8]
    mov [rom_path_str],rax
    call strlen
    cmp rax,500
    ja .badpath
    mov [rom_path_len],rax
    inc r14
    jmp .parse
.set_headless:
    mov byte [cli_headless],1
    inc r14
    jmp .parse
.set_serial:
    mov byte [cli_serial],1
    inc r14
    jmp .parse
.set_debug:
    mov byte [cli_debug],1
    inc r14
    jmp .parse
.set_exitres:
    mov byte [cli_exitres],1
    inc r14
    jmp .parse
.set_verdict:
    mov byte [cli_verdict],1
    inc r14
    jmp .parse
.opt_frames:
    inc r14
    cmp r14,[rbp]
    jge .parsed
    mov rdi,[rbp+r14*8+8]
    call parse_uint
    mov [cli_frames],rax
    inc r14
    jmp .parse
.opt_dump:
    inc r14
    cmp r14,[rbp]
    jge .parsed
    mov rax,[rbp+r14*8+8]
    mov [dump_path],rax
    inc r14
    jmp .parse
.opt_audio:
    inc r14
    cmp r14,[rbp]
    jge .parsed
    mov rax,[rbp+r14*8+8]
    mov [audio_path_ptr],rax
    inc r14
    jmp .parse
.parsed:
    cmp qword [rom_path_str],0
    je .noargs
    ; headless implies serial unless explicitly? keep serial flag as given; dumping sets headless-ish
    ; open ROM
    mov rax,SYS_open
    mov rdi,[rom_path_str]
    mov rsi,O_RDONLY
    xor rdx,rdx
    syscall
    cmp rax,0
    jl .openfail
    mov [rom_fd],rax
    ; lseek end
    mov rax,SYS_lseek
    mov rdi,[rom_fd]
    xor rsi,rsi
    mov rdx,2
    syscall
    cmp rax,0
    jle .openfail
    ; A cartridge is at least two 16 KiB banks and at most 8 MiB.
    ; Rejecting other sizes here keeps every later bank/read access in
    ; the mapping we actually allocated.
    cmp rax,0x8000
    jb .badrom
    cmp rax,0x800000
    ja .badrom
    mov [rom_size],rax
    ; align up to page
    mov rcx,rax
    add rcx,4095
    and rcx,~4095
    ; mmap(NULL, size, PROT_RW, MAP_PRIV_ANON, -1, 0)
    mov rax,SYS_mmap
    xor rdi,rdi
    mov rsi,rcx
    mov rdx,PROT_RW
    mov r10,MAP_PRIV_ANON
    mov r8,-1
    xor r9,r9
    syscall
    cmp rax,-4095
    jae .openfail
    mov [rom_ptr],rax
    ; lseek 0
    mov rax,SYS_lseek
    mov rdi,[rom_fd]
    xor rsi,rsi
    xor rdx,rdx
    syscall
    ; read loop
    mov r12,[rom_ptr]
    mov r13,[rom_size]
.rd: test r13,r13
    jz .rdone
    mov rax,SYS_read
    mov rdi,[rom_fd]
    mov rsi,r12
    mov rdx,r13
    syscall
    cmp rax,0
    jle .rdone
    add r12,rax
    sub r13,rax
    jmp .rd
.rdone:
    test r13,r13
    jnz .shortread
    mov rax,SYS_close
    mov rdi,[rom_fd]
    syscall
    ; if headless forced by --frames without explicit? frames>0 implies headless for CI if not tty? keep explicit flag only
    call init_emulator
    call run_emulator
    call cleanup_and_exit
.noargs:
    lea rdi,[msg_noargs]
    call prints0
    lea rdi,[msg_usage]
    call prints0
    EXIT 1
.openfail:
    lea rdi,[msg_openfail]
    call prints0
    EXIT 1
.badrom:
    lea rdi,[msg_badrom]
    call prints0
    EXIT 1
.badpath:
    lea rdi,[msg_badpath]
    call prints0
    EXIT 1
.shortread:
    mov rax,SYS_close
    mov rdi,[rom_fd]
    syscall
    lea rdi,[msg_readfail]
    call prints0
    EXIT 1
str_headless: db "--headless",0
str_serial:   db "--serial",0
str_debug:    db "--debug",0
str_frames:   db "--frames",0
str_dump:     db "--dump",0
str_audio:    db "--audio",0
str_exitres:  db "--exit-on-result",0
str_verdict:  db "--verdict",0

cleanup_and_exit:
    cmp byte [cli_exitres],0
    je .noframes
    mov rax,SYS_write
    mov edi,2
    lea rsi,[frames_done]
    mov edx,8
    syscall
.noframes:
    ; --verdict: expose the cartridge-RAM result byte for automated suites.
    cmp byte [cli_verdict],0
    je .noverdict
    cmp dword [ram_banks],0
    je .noverdict
    lea rdi,[msg_verdict]
    call prints0
    movzx rax,byte [extram]
    call print_hex8
    lea rdi,[msg_newline]
    call prints0
.noverdict:
    ; save .sav if RAM present
    call save_sav
    ; flush and finalize audio (patch RIFF/data sizes, then close)
    cmp byte [audio_enabled],0
    je .noaudio
    call audio_finalize
.noaudio:
    cmp byte [cli_headless],0
    jne .skip_term
    ; restore terminal
    lea rdi,[esc_show]
    call prints0
    mov rax,SYS_ioctl
    mov rdi,0
    mov rsi,TCSETS
    lea rdx,[saved_termios]
    syscall
.skip_term:
    EXIT 0

; save .sav next to ROM : rompath + ".sav"
save_sav:
    cmp dword [ram_banks],0
    je .d
    ; build path in sav_path
    lea rdi,[sav_path]
    mov rsi,[rom_path_str]
    mov rcx,[rom_path_len]
    cmp rcx,500
    ja .d
    mov rdx,0
.cp: cmp rdx,rcx
    jge .cpd
    mov al,[rsi+rdx]
    mov [rdi+rdx],al
    inc rdx
    jmp .cp
.cpd: mov byte [rdi+rcx],'.'
    mov byte [rdi+rcx+1],'s'
    mov byte [rdi+rcx+2],'a'
    mov byte [rdi+rcx+3],'v'
    mov byte [rdi+rcx+4],0
    mov rax,SYS_open
    lea rdi,[sav_path]
    mov rsi,O_WRONLY|O_CREAT|O_TRUNC
    mov rdx,0644o
    syscall
    cmp rax,0
    jl .d
    mov r12,rax
    mov r13,0
    mov r14d,[ram_banks]
    imul r14,0x2000
    lea rsi,[extram]
    mov rdx,r14
    mov rdi,r12
    call write_all
    mov rax,SYS_close
    mov rdi,r12
    syscall
.d: ret
load_sav:
    cmp dword [ram_banks],0
    je .d
    lea rdi,[sav_path]
    mov rsi,[rom_path_str]
    mov rcx,[rom_path_len]
    cmp rcx,500
    ja .d
    mov rdx,0
.cp: cmp rdx,rcx
    jge .cpd
    mov al,[rsi+rdx]
    mov [rdi+rdx],al
    inc rdx
    jmp .cp
.cpd: mov byte [rdi+rcx],'.'
    mov byte [rdi+rcx+1],'s'
    mov byte [rdi+rcx+2],'a'
    mov byte [rdi+rcx+3],'v'
    mov byte [rdi+rcx+4],0
    mov rax,SYS_open
    lea rdi,[sav_path]
    mov rsi,O_RDONLY
    xor rdx,rdx
    syscall
    cmp rax,0
    jl .d
    mov r12,rax
    mov r13,0
    mov r14d,[ram_banks]
    imul r14,0x2000
.rd: test r14,r14
    jz .rc
    mov rax,SYS_read
    mov rdi,r12
    lea rsi,[extram]
    add rsi,r13
    mov rdx,r14
    syscall
    cmp rax,0
    jle .rc
    add r13,rax
    sub r14,rax
    jmp .rd
.rc: mov rax,SYS_close
    mov rdi,r12
    syscall
.d: ret

; ---------- init ----------
init_emulator:
    push rbx
    push r12
    push r13
    push r14
    push r15
    ; parse header at rom_ptr+0x134 title, 0x147 mbc, 0x148 banks, 0x149 ram
    mov rsi,[rom_ptr]
    mov al,[rsi+0x147]
    mov [mbc_type],al
    ; Cartridge families, not individual type bytes: 0x01-0x03 are MBC1,
    ; 0x0F-0x13 are MBC3 (so 0x11/0x12 are NOT MBC1), 0x19-0x1E MBC5.
    xor ecx,ecx
    mov dl,al
    cmp dl,0x01
    jb .fam_done
    cmp dl,0x03
    jbe .fam1
    cmp dl,0x0F
    jb .fam_done
    cmp dl,0x13
    jbe .fam3
    cmp dl,0x19
    jb .fam_done
    cmp dl,0x1E
    jbe .fam5
    jmp .fam_done
.fam1: mov ecx,1
    jmp .fam_done
.fam3: mov ecx,3
    jmp .fam_done
.fam5: mov ecx,5
.fam_done:
    mov [mbc_family],cl
    ; ROM size code 0..8 means 2..512 banks. Clamp the header claim to the
    ; real file size so a malformed or truncated header can never index
    ; past the mapping.
    movzx eax,byte [rsi+0x148]
    cmp eax,8
    jbe .rom_code_ok
    mov eax,8
.rom_code_ok:
    mov ecx,eax
    mov eax,2
    shl eax,cl
    mov rdx,[rom_size]
    shr rdx,14
    cmp rdx,2
    jae .actual_banks
    mov rdx,2
.actual_banks:
    cmp rax,rdx
    jbe .banks_ok
    mov rax,rdx
.banks_ok:
    mov [rom_banks],eax
    dec eax
    mov [rom_mask],eax
    ; RAM size: 00 none, 01 2K, 02 8K, 03 32K, 04 128K, 05 64K.
    mov al,[rsi+0x149]
    xor ecx,ecx
    cmp al,1
    je .ram1
    cmp al,2
    je .ram1
    cmp al,3
    je .ram4
    cmp al,4
    je .ram16
    cmp al,5
    je .ram8
    jmp .ramdone
.ram1: mov ecx,1
    jmp .ramdone
.ram4: mov ecx,4
    jmp .ramdone
.ram8: mov ecx,8
    jmp .ramdone
.ram16: mov ecx,16
.ramdone:
    mov [ram_banks],ecx
    test ecx,ecx
    jz .rammask_done
    dec ecx
.rammask_done:
    mov [ram_mask],ecx
    mov dword [mbc_rom_bank],1
    mov dword [mbc_ram_bank],0
    mov byte [mbc_mode],0
    mov byte [mbc1_hi],0
    mov byte [ram_enable],0
    ; post-boot registers (Pan Docs)
    mov byte [gb_a],0x01
    mov byte [gb_f],0xB0
    mov byte [gb_b],0x00
    mov byte [gb_c],0x13
    mov byte [gb_d],0x00
    mov byte [gb_e],0xF8
    mov byte [gb_h],0x01
    mov byte [gb_l],0x4D
    mov word [gb_sp],0xFFFE
    mov word [gb_pc],0x0100
    mov byte [ime],1
    mov byte [ei_delay],0
    mov byte [halted],0
    mov byte [stop_flag],0
    mov word [ppu_dot],0
    mov byte [ppu_ly],0
    mov byte [ppu_mode],2
    mov dword [div_counter],0xABCD
    mov dword [tima_counter],0
    mov byte [prev_tac_bit],0
    ; IO post-boot values
    lea rdi,[io]
    mov rcx,0x80
    xor rax,rax
.z: mov [rdi+rcx-1],al
    loop .z
    ; SF etc
    mov byte [io+0x05],0x00   ; TIMA
    mov byte [io+0x06],0x00   ; TMA
    mov byte [io+0x07],0xF8   ; TAC
    mov byte [io+0x0F],0xE1   ; IF (bits)
    mov byte [io+0x10],0x80
    mov byte [io+0x11],0xBF
    mov byte [io+0x12],0xF3
    mov byte [io+0x14],0xBF
    mov byte [io+0x16],0x3F
    mov byte [io+0x17],0x00
    mov byte [io+0x19],0xBF
    mov byte [io+0x1A],0x7F
    mov byte [io+0x1B],0xFF
    mov byte [io+0x1C],0x9F
    mov byte [io+0x1E],0xBF
    mov byte [io+0x20],0xFF
    mov byte [io+0x21],0x00
    mov byte [io+0x22],0x00
    mov byte [io+0x23],0xBF
    mov byte [io+0x24],0x77
    mov byte [io+0x25],0xF3
    mov byte [io+0x26],0xF1
    mov byte [io+0x2F],0xFF
    mov byte [io+0x30],0
    mov byte [io+0x40],0x91   ; LCDC
    mov byte [io+0x42],0x00   ; SCY
    mov byte [io+0x43],0x00   ; SCX
    mov byte [io+0x45],0x00   ; LYC
    mov byte [io+0x47],0xFC   ; BGP
    mov byte [io+0x48],0xFF   ; OBP0
    mov byte [io+0x49],0xFF   ; OBP1
    mov byte [io+0x4A],0x00   ; WY
    mov byte [io+0x4B],0x00   ; WX
    mov byte [ie_reg],0x00
    ; HRAM zero (bss already)
    ; APU channels init
    lea rdi,[apu_ch]
    mov rcx,4*32
    xor rax,rax
.az: mov [rdi+rcx-1],al
    loop .az
    ; noise lfsr seed
    mov word [apu_ch+1*32+14],0x7FFF
    mov word [apu_ch+2*32+14],0x7FFF
    mov word [apu_ch+3*32+14],0x7FFF
    call apu_init
    ; audio file if requested
    cmp qword [audio_path_ptr],0
    je .noaudio_init
    mov rax,SYS_open
    mov rdi,[audio_path_ptr]
    mov rsi,O_WRONLY|O_CREAT|O_TRUNC
    mov rdx,0644o
    syscall
    cmp rax,0
    jl .noaudio_init
    mov [audio_fd],rax
    mov byte [audio_enabled],1
    ; write WAV header placeholder (data size patched on close in headless? keep 0x7FFFFFFF-ish; we write header with large)
    call audio_write_header
.noaudio_init:
    call load_sav
    ; banner if not headless and not serial-only
    cmp byte [cli_headless],0
    jne .done
    lea rdi,[msg_loading]
    call prints0
    mov rdi,[rom_path_str]
    mov rsi,[rom_path_len]
    call print_mem
    lea rdi,[msg_title]
    call prints0
    mov rsi,[rom_ptr]
    add rsi,0x134
    mov rdi,rsi
    ; print up to 16 non-zero title chars
    push rbx
    xor rbx,rbx
.tl: cmp rbx,16
    jge .td
    cmp byte [rsi+rbx],0
    je .td
    mov al,[rsi+rbx]
    mov [scratch+rbx],al
    inc rbx
    jmp .tl
.td: mov byte [scratch+rbx],0
    mov rdi,scratch
    call prints0
    pop rbx
    lea rdi,[msg_mbc]
    call prints0
    movzx rax,byte [mbc_type]
    call print_str_radix
    lea rdi,[msg_newline]
    call prints0
.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

audio_write_header:
    push rbx
    push r12
    ; Reserve 44 bytes; the real RIFF/data sizes are patched by
    ; audio_finalize after all PCM has been written.
    mov qword [audio_bytes],0
    mov dword [wav_header+4],0
    mov dword [wav_header+40],0
    mov rdi,[audio_fd]
    lea rsi,[wav_header]
    mov rdx,44
    call write_all
    pop r12
    pop rbx
    ret

; ---------- memory read: rdi=addr(0-FFFF) -> al ----------
read_mem:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    cmp di,0x8000
    jb .rom
    cmp di,0xA000
    jb .vram_r
    cmp di,0xC000
    jb .extram_r
    cmp di,0xE000
    jb .wram_r
    cmp di,0xFE00
    jb .echo_r
    cmp di,0xFEA0
    jb .oam_r
    cmp di,0xFF00
    jb .unmapped
    cmp di,0xFF80
    jb .io_r
    cmp di,0xFFFF
    jb .hram_r
    ; FFFF IE
    movzx rax,byte [ie_reg]
    jmp .out
.rom:
    movzx rax,di
    cmp di,0x4000
    jb .rom0
    mov rbx,[rom_ptr]
    mov ecx,1
    cmp byte [mbc_family],1
    je .mbc1bank
    cmp byte [mbc_family],3
    je .mbc3bank
    cmp byte [mbc_family],5
    je .mbc5bank
    jmp .rom_banked
.mbc1bank:
    ; MBC1 zero-to-one substitution applies to the 5-bit register, then
    ; mode 1 adds the 2-bit high register.
    mov ecx,[mbc_rom_bank]
    and ecx,0x1F
    jnz .mbc1_low_ok
    mov ecx,1
.mbc1_low_ok:
    cmp byte [mbc_mode],0
    je .rom_banked
    movzx edx,byte [mbc1_hi]
    shl edx,5
    or ecx,edx
    jmp .rom_banked
.mbc3bank:
    mov ecx,[mbc_rom_bank]
    and ecx,0x7F
    jnz .rom_banked
    mov ecx,1
    jmp .rom_banked
.mbc5bank:
    ; MBC5 has a 9-bit bank register and bank 0 is legal.
    mov ecx,[mbc_rom_bank]
    and ecx,0x1FF
.rom_banked:
    ; Aliasing by the real ROM size (header claim already clamped).
    and ecx,[rom_mask]
    shl rcx,14
    add rbx,rcx
    mov al,[rbx+rax-0x4000]
    movzx rax,al
    jmp .out
.rom0:
    mov rbx,[rom_ptr]
    ; MBC1 mode 1 maps the 0x0000-0x3FFF window with the high register.
    cmp byte [mbc_family],1
    jne .rom0_bank0
    cmp byte [mbc_mode],0
    je .rom0_bank0
    movzx ecx,byte [mbc1_hi]
    shl ecx,5
    test ecx,ecx
    jz .rom0_bank0
    and ecx,[rom_mask]
    shl rcx,14
    add rbx,rcx
    mov al,[rbx+rax]
    movzx rax,al
    jmp .out
.rom0_bank0:
    mov al,[rbx+rax]
    movzx rax,al
    jmp .out
.vram_r:
    lea rbx,[vram]
    movzx rax,di
    sub rax,0x8000
    mov al,[rbx+rax]
    movzx rax,al
    jmp .out
.extram_r:
    cmp byte [ram_enable],0
    je .zero
    cmp dword [ram_banks],0
    je .zero
    ; MBC3 RTC registers 0x08-0x0C are a stub, but must not alias RAM.
    cmp byte [mbc_family],3
    jne .extram_r_bank
    cmp dword [mbc_ram_bank],8
    jb .extram_r_bank
    mov al,0xFF
    movzx rax,al
    jmp .out
.extram_r_bank:
    lea rbx,[extram]
    mov ecx,[mbc_ram_bank]
    ; MBC1: in mode 1 the 2-bit high register selects the RAM bank;
    ; in mode 0 RAM bank 0 is always selected.
    cmp byte [mbc_family],1
    jne .extram_r_select
    xor ecx,ecx
    cmp byte [mbc_mode],0
    je .extram_r_select
    movzx ecx,byte [mbc1_hi]
.extram_r_select:
    and ecx,[ram_mask]
    movzx rax,di
    sub rax,0xA000
    shl rcx,13
    add rbx,rcx
    mov al,[rbx+rax]
    movzx rax,al
    jmp .out
.wram_r:
    lea rbx,[wram]
    movzx rax,di
    sub rax,0xC000
    mov al,[rbx+rax]
    movzx rax,al
    jmp .out
.echo_r:
    lea rbx,[wram]
    movzx rax,di
    sub rax,0xE000
    mov al,[rbx+rax]
    movzx rax,al
    jmp .out
.oam_r:
    lea rbx,[oam]
    movzx rax,di
    sub rax,0xFE00
    mov al,[rbx+rax]
    movzx rax,al
    jmp .out
.io_r:
    movzx rax,di
    sub rax,0xFF00
    cmp rax,0x10
    jb .io_r_plain
    cmp rax,0x40
    jb .io_r_apu
.io_r_plain:
    lea rbx,[io]
    cmp rax,0x40
    je .dma_r
    cmp rax,0x00
    je .p1_r
    cmp rax,0x04
    je .div_r
    cmp rax,0x0F
    je .if_r
    mov al,[rbx+rax]
    movzx rax,al
    jmp .out
.if_r:
    mov al,[rbx+0x0F]
    and al,0x1F
    or al,0xE0
    movzx rax,al
    jmp .out
.dma_r:
    mov al,0xFF
    movzx rax,al
    jmp .out
.p1_r:
    call read_p1
    movzx rax,al
    jmp .out
.div_r:
    mov eax,[div_counter]
    shr eax,8
    movzx rax,al
    jmp .out
.io_r_apu:
    mov rdi,rax
    call apu_io_read
    jmp .out
.hram_r:
    lea rbx,[hram]
    movzx rax,di
    sub rax,0xFF80
    mov al,[rbx+rax]
    movzx rax,al
    jmp .out
.unmapped:
.zero: mov al,0xFF
    movzx rax,al
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret
read_p1: ; -> al (bit6/5 select, low nibble: 1=pressed -> 0)
    xor rax,rax
    mov al,[io+0x00]
    and al,0x30
    mov ah,0x0F
    ; dpad group if bit4=0
    test al,0x10
    jnz .skip_dpad
    test byte [key_right],1
    jz .nr
    and ah,~0x01
.nr: test byte [key_left],1
    jz .nl
    and ah,~0x02
.nl: test byte [key_up],1
    jz .nu
    and ah,~0x04
.nu: test byte [key_down],1
    jz .nd
    and ah,~0x08
.nd:
.skip_dpad:
    test al,0x20
    jnz .skip_btn
    ; Button group: bit0=A, bit1=B, bit2=Select, bit3=Start.
    test byte [key_a],1
    jz .na
    and ah,~0x01
.na: test byte [key_b],1
    jz .nb
    and ah,~0x02
.nb: test byte [key_select],1
    jz .nse
    and ah,~0x04
.nse: test byte [key_start],1
    jz .ns
    and ah,~0x08
.ns:
.skip_btn:
    or al,ah
    or al,0xC0
    ret

; ---------- memory write: rdi=addr, rsi=value(low byte) ----------
write_mem:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    movzx rdx,si
    cmp di,0x8000
    jb .rom_w
    cmp di,0xA000
    jb .vram_w
    cmp di,0xC000
    jb .extram_w
    cmp di,0xE000
    jb .wram_w
    cmp di,0xFE00
    jb .echo_w
    cmp di,0xFEA0
    jb .oam_w
    cmp di,0xFF00
    jb .out
    cmp di,0xFF80
    jb .io_w
    cmp di,0xFFFF
    jb .hram_w
    mov [ie_reg],dl
    jmp .out
.rom_w:
    ; MBC control register ranges: 0000-1FFF RAM enable, 2000-3FFF ROM
    ; bank, 4000-5FFF high/RAM bank, 6000-7FFF mode/latch.
    cmp di,0x2000
    jb .mbc_enable_w
    cmp di,0x4000
    jb .mbc_rombank_w
    cmp di,0x6000
    jb .mbc_hi_w
    cmp di,0x8000
    jb .mbc_extra_w
    jmp .out
.mbc_enable_w:
    cmp byte [mbc_family],0
    je .out
    mov eax,edx
    and eax,0x0F
    cmp eax,0x0A
    sete al
    movzx eax,al
    mov [ram_enable],al
    jmp .out
.mbc_rombank_w:
    cmp byte [mbc_family],1
    je .mbc1_rom
    cmp byte [mbc_family],3
    je .mbc3_rom
    cmp byte [mbc_family],5
    je .mbc5_rom
    jmp .out
.mbc1_rom:
    mov eax,edx
    and eax,0x1F
    mov [mbc_rom_bank],eax
    jmp .out
.mbc3_rom:
    mov eax,edx
    and eax,0x7F
    jnz .mbc3_rom_store
    mov eax,1
.mbc3_rom_store:
    mov [mbc_rom_bank],eax
    jmp .out
.mbc5_rom:
    ; 2000-2FFF is the low 8 bits, 3000-3FFF is bit 8. Bank 0 is legal.
    cmp di,0x3000
    jb .mbc5_rom_low
    movzx ecx,dl
    and ecx,1
    shl ecx,8
    and dword [mbc_rom_bank],0xFF
    or dword [mbc_rom_bank],ecx
    jmp .out
.mbc5_rom_low:
    movzx ecx,dl
    and dword [mbc_rom_bank],0x100
    or dword [mbc_rom_bank],ecx
    jmp .out
.mbc_hi_w:
    cmp byte [mbc_family],1
    je .mbc1_hi_w
    cmp byte [mbc_family],3
    je .mbc3_hi_w
    cmp byte [mbc_family],5
    je .mbc5_hi_w
    jmp .out
.mbc1_hi_w:
    mov eax,edx
    and eax,3
    mov [mbc1_hi],al
    jmp .out
.mbc3_hi_w:
    movzx eax,dl
    cmp eax,0x08
    jb .mbc3_ram_sel
    cmp eax,0x0C
    ja .out
    mov [mbc_ram_bank],eax     ; RTC selector, stubbed
    jmp .out
.mbc3_ram_sel:
    and eax,3
    mov [mbc_ram_bank],eax
    jmp .out
.mbc5_hi_w:
    movzx eax,dl
    and eax,0x0F
    mov [mbc_ram_bank],eax
    jmp .out
.mbc_extra_w:
    cmp byte [mbc_family],1
    jne .out                    ; MBC3 latch / MBC5 unused here
    mov eax,edx
    and eax,1
    mov [mbc_mode],al
    jmp .out
.vram_w:
    lea rbx,[vram]
    movzx rax,di
    sub rax,0x8000
    mov [rbx+rax],dl
    jmp .out
.extram_w:
    cmp byte [ram_enable],0
    je .out
    cmp dword [ram_banks],0
    je .out
    cmp byte [mbc_family],3
    jne .extram_w_bank
    cmp dword [mbc_ram_bank],8
    jae .out                   ; RTC register write (stub)
.extram_w_bank:
    lea rbx,[extram]
    mov ecx,[mbc_ram_bank]
    cmp byte [mbc_family],1
    jne .extram_w_select
    xor ecx,ecx
    cmp byte [mbc_mode],0
    je .extram_w_select
    movzx ecx,byte [mbc1_hi]
.extram_w_select:
    and ecx,[ram_mask]
    movzx rax,di
    sub rax,0xA000
    shl rcx,13
    add rbx,rcx
    mov [rbx+rax],dl
    jmp .out
.wram_w:
    lea rbx,[wram]
    movzx rax,di
    sub rax,0xC000
    mov [rbx+rax],dl
    jmp .out
.echo_w:
    lea rbx,[wram]
    movzx rax,di
    sub rax,0xE000
    mov [rbx+rax],dl
    jmp .out
.oam_w:
    lea rbx,[oam]
    movzx rax,di
    sub rax,0xFE00
    mov [rbx+rax],dl
    jmp .out
.io_w:
    movzx rax,di
    sub rax,0xFF00
    cmp rax,0x10
    jb .io_nonapu
    cmp rax,0x40
    jb .io_apu_w
.io_nonapu:
    lea rbx,[io]
    mov [rbx+rax],dl
    cmp rax,0x04
    je .div_w
    cmp rax,0x0F
    je .if_w
    cmp rax,0x02
    je .serial_w
    cmp rax,0x46
    je .dma_w
    cmp rax,0x40
    je .lcdc_w
    cmp rax,0x00
    je .p1_w
    jmp .out
.io_apu_w:
    call apu_io_write
    jmp .out
.div_w:
    mov dword [div_counter],0
    mov byte [prev_tac_bit],0
    jmp .out
.if_w:
    and byte [rbx+0x0F],0x1F
    mov al,[rbx+0x0F]
    mov [if_reg],al
    jmp .out
.p1_w:
    ; P1 is a raw register; joypad IRQs are raised on a 1->0 line edge by
    ; poll_input, where key state actually changes.
    jmp .out
.lcdc_w:
    ; turning LCD off resets LY/mode
    test dl,0x80
    jnz .out
    mov byte [ppu_ly],0
    mov word [ppu_dot],0
    mov byte [ppu_mode],0
    jmp .out
.serial_w:
    test dl,0x80
    jz .out
    cmp byte [cli_serial],0
    je .out
    ; output SB byte
    push rdi
    push rsi
    push rdx
    mov al,[io+0x01]
    mov [scratch],al
    mov rdi,1
    lea rsi,[scratch]
    mov rdx,1
    call write_all
    pop rdx
    pop rsi
    pop rdi
    ; clear transfer bit
    and byte [io+0x02],0x7F
    jmp .out
.dma_w:
    ; copy 160 bytes from rdx*0x100 to OAM
    push r12
    push r13
    movzx r12,dl
    shl r12,8
    lea r13,[oam]
    mov ecx,160
.dm: push rcx
    mov rdi,r12
    inc r12
    call read_mem
    mov [r13],al
    inc r13
    pop rcx
    loop .dm
    pop r13
    pop r12
    jmp .out
.hram_w:
    lea rbx,[hram]
    movzx rax,di
    sub rax,0xFF80
    mov [rbx+rax],dl
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; request interrupt: rdi = bitmask (1=VBL,2=LCD,4=TIMER,8=SERIAL,16=JOY)
request_irq:
    mov al,dil
    and al,0x1F
    or [io+0x0F],al
    ret

; ---------- PPU / Timer stepping ----------
; step_system(rdi=cycles)
step_system:
    push rbx
    push r12
    push r13
    push r14
    mov r12,rdi
    call step_timer
    mov rdi,r12
    call step_ppu
    mov rdi,r12
    call apu_step
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; do_prestep(edi=T-cycles): advance system before a memory access so the
; access lands on its correct intra-instruction cycle. Accumulates into
; prestep_done so cpu_finish_step only steps the remainder.
; Preserves all registers.
do_prestep:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    add [prestep_done],edi
    call step_system
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret
step_timer:
    push rbx
    push rcx
    push r8
    push r9
    push r10
    mov r8d,[div_counter]       ; old counter
    mov r10d,edi                ; delta T-cycles (instr_cycles are T-cycles)
    add r8d,edi
    mov [div_counter],r8d       ; new counter in r8d
    mov al,[io+0x07]
    test al,0x04
    jz .disabled
    movzx rcx,al
    and ecx,3
    cmp ecx,0
    je .p9
    cmp ecx,1
    je .p3
    cmp ecx,2
    je .p5
    mov r9d,256               ; freq 03 -> bit7, period 256 T
    jmp .edges
.p9: mov r9d,1024              ; freq 00 -> bit9, period 1024 T
    jmp .edges
.p3: mov r9d,16                ; freq 01 -> bit3, period 16 T
    jmp .edges
.p5: mov r9d,64                ; freq 02 -> bit5, period 64 T
.edges:
    ; falling edges = floor(new/P) - floor(old/P), old = new - delta
    mov eax,r8d
    xor edx,edx
    div r9d                   ; eax = new/P, edx = new%P
    mov ecx,eax               ; new/P
    mov eax,r8d
    sub eax,r10d              ; old counter
    xor edx,edx
    div r9d                   ; eax = old/P
    sub ecx,eax               ; ecx = number of falling edges
    test ecx,ecx
    jz .updprev
    js .updprev               ; negative (should not happen): ignore
    ; apply ticks one by one: TIMA++, overflow -> reload TMA + IRQ
.tickloop:
    inc byte [io+0x05]
    jnz .tickcont
    mov al,[io+0x06]
    mov [io+0x05],al
    push rdi
    mov rdi,4
    call request_irq
    pop rdi
.tickcont:
    dec ecx
    jnz .tickloop
.updprev:
    ; update current input level (selected bit & enable) for TAC-write edge
    mov eax,r8d
    mov edx,eax
    ; selected bit value: bit = (counter >> b) & 1 where period P=2^(b+1) -> b=log2(P)-1
    ; derive shift from P: 16->3, 64->5, 256->7, 1024->9
    cmp r9d,16
    je .s3
    cmp r9d,64
    je .s5
    cmp r9d,256
    je .s7
    shr edx,9
    jmp .sdone
.s3: shr edx,3
    jmp .sdone
.s5: shr edx,5
    jmp .sdone
.s7: shr edx,7
.sdone:
    and edx,1
    mov [prev_tac_bit],dl
    jmp .out2
.disabled:
    mov byte [prev_tac_bit],0
.out2:
    pop r10
    pop r9
    pop r8
    pop rcx
    pop rbx
    ret

step_ppu:
    push rbx
    push rcx
    push rdx
    push r12
    push r13
    push r14
    ; if LCD off
    test byte [io+0x40],0x80
    jz .lcd_off
    movzx eax,word [ppu_dot]
    add eax,edi
    mov r12d,eax
    mov r13b,[ppu_mode]
    ; advance lines
.adv:
    cmp r12d,456
    jb .modeset
    sub r12d,456
    inc byte [ppu_ly]
    cmp byte [ppu_ly],144
    jne .notvbl
    mov rdi,1
    call request_irq
.notvbl:
    cmp byte [ppu_ly],154
    jb .adv
    mov byte [ppu_ly],0
    jmp .adv
.modeset:
    mov [ppu_dot],r12w
    movzx eax,byte [ppu_ly]
    cmp al,144
    jae .mode1
    cmp r12d,80
    jb .mode2
    cmp r12d,252
    jb .mode3
    mov byte [ppu_mode],0
    jmp .statupd
.mode1:
    mov byte [ppu_mode],1
    jmp .statupd
.mode2:
    mov byte [ppu_mode],2
    jmp .statupd
.mode3:
    mov byte [ppu_mode],3
    ; render when entering mode3
    cmp r13b,3
    je .statupd
    movzx rdi,byte [ppu_ly]
    call render_scanline
    jmp .statupd
.statupd:
    mov al,[ppu_ly]
    mov [io+0x44],al
    ; LYC coincidence compares LY, not the STAT register (which also
    ; contains mode bits), and feeds both STAT bit 2 and source bit 6.
    xor r8d,r8d
    cmp al,[io+0x45]
    jne .noco
    mov r8d,1
.noco:
    and byte [io+0x41],0xFB
    mov al,r8b
    shl al,2
    or [io+0x41],al
    mov al,[ppu_mode]
    and byte [io+0x41],0xFC
    or [io+0x41],al
    ; STAT sources: bit3 mode0, bit4 mode1, bit5 mode2, bit6 LYC.
    xor edx,edx
    mov al,[io+0x41]
    test al,0x08
    jz .s0
    cmp byte [ppu_mode],0
    jne .s0
    mov edx,1
.s0: test al,0x10
    jz .s1
    cmp byte [ppu_mode],1
    jne .s1
    mov edx,1
.s1: test al,0x20
    jz .s2
    cmp byte [ppu_mode],2
    jne .s2
    mov edx,1
.s2: test al,0x40
    jz .s3
    test r8d,r8d
    jz .s3
    mov edx,1
.s3:
    cmp byte [stat_prev],0
    jne .statdone
    test edx,edx
    jz .statdone
    mov rdi,2
    call request_irq
.statdone:
    mov [stat_prev],dl
    jmp .out
.lcd_off:
    mov byte [ppu_mode],0
    and byte [io+0x41],0xFC
    and byte [io+0x41],0xFB
    mov byte [stat_prev],0
.out:
    pop r14
    pop r13
    pop r12
    pop rdx
    pop rcx
    pop rbx
    ret

; ---------- render scanline: rdi = LY ----------
; ---------- render scanline: rdi = LY ----------
; BG/window and sprites are composited per pixel. Tile rows use the real
; interleaved 2-byte format and the signed tile base is 0x9000 (vram+0x1000).
render_scanline:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    mov r12,rdi
    lea rdi,[bg_line_idx]
    xor eax,eax
    mov ecx,160
    rep stosb
    test byte [io+0x40],0x80
    jz .fill
    test byte [io+0x40],0x01
    jz .fill
    xor r13,r13
.bgx:
    cmp r13,160
    jge .sprites
    xor r14,r14
    xor r15,r15
    mov ebx,0x1800
    ; Window: enabled, LY>=WY, WX in 7..166, and X >= WX-7.
    test byte [io+0x40],0x20
    jz .bg_layer
    movzx rax,byte [io+0x4A]
    cmp r12,rax
    jb .bg_layer
    movzx rax,byte [io+0x4B]
    cmp eax,7
    jb .bg_layer
    cmp eax,166
    ja .bg_layer
    sub eax,7
    cmp r13,rax
    jb .bg_layer
    mov r15,r13
    sub r15,rax
    mov r14,r12
    movzx rcx,byte [io+0x4A]
    sub r14,rcx
    test byte [io+0x40],0x40
    jz .gettile
    mov ebx,0x1C00
    jmp .gettile
.bg_layer:
    movzx rax,byte [io+0x43]
    add rax,r13
    mov r15,rax
    movzx rax,byte [io+0x42]
    add rax,r12
    mov r14,rax
    test byte [io+0x40],0x08
    jz .gettile
    mov ebx,0x1C00
.gettile:
    and r15,255
    and r14,255
    mov rax,r14
    shr rax,3
    shl rax,5
    mov rcx,r15
    shr rcx,3
    add rax,rcx
    add rax,rbx
    lea rsi,[vram]
    movzx ebx,byte [rsi+rax]
    test byte [io+0x40],0x10
    jnz .t_unsigned
    movsx rbx,bl
    shl rbx,4
    lea rax,[vram+0x1000]
    add rax,rbx
    jmp .t_addr
.t_unsigned:
    shl rbx,4
    lea rax,[vram]
    add rax,rbx
.t_addr:
    and r14,7
    lea rax,[rax+r14*2]
    movzx edx,byte [rax]
    movzx ebx,byte [rax+1]
    mov rcx,r15
    and ecx,7
    mov esi,7
    sub esi,ecx
    mov ecx,esi
    shr edx,cl
    and edx,1
    shr ebx,cl
    and ebx,1
    shl ebx,1
    or edx,ebx
    lea rsi,[bg_line_idx]
    mov [rsi+r13],dl
    movzx eax,byte [io+0x47]
    mov ecx,edx
    shl ecx,1
    shr eax,cl
    and eax,3
    call set_pixel_from_indextmp
    inc r13
    jmp .bgx
.fill:
    xor r13,r13
.fb:
    cmp r13,160
    jge .sprites
    mov byte [bg_line_idx+r13],0
    xor eax,eax
    call set_pixel_from_indextmp
    inc r13
    jmp .fb
.sprites:
    test byte [io+0x40],0x02
    jz .done
    lea rdi,[spr_line_col]
    xor eax,eax
    mov ecx,160
    rep stosb
    lea rdi,[spr_line_x]
    mov al,0xFF
    mov ecx,160
    rep stosb
    xor r14,r14
.spr_loop:
    cmp r14,40
    jge .composite
    mov rax,r14
    shl rax,2
    lea rsi,[oam]
    movzx ecx,byte [rsi+rax]     ; OAM Y
    movzx edx,byte [rsi+rax+1]   ; OAM X
    movzx ebx,byte [rsi+rax+2]   ; tile
    movzx r15d,byte [rsi+rax+3]  ; attributes
    mov r8,8
    test byte [io+0x40],0x04     ; LCDC bit2: 8x16 sprites
    jz .spr_h
    mov r8,16
.spr_h:
    sub ecx,16
    mov rax,r12
    sub rax,rcx
    cmp rax,0
    jl .next_spr
    cmp rax,r8
    jae .next_spr
    test r15b,0x40               ; Y flip
    jz .spr_row
    mov rcx,r8
    dec rcx
    sub rcx,rax
    mov rax,rcx
.spr_row:
    cmp r8,16
    jne .spr_row8
    and ebx,0xFE
    mov rcx,rax
    shr rcx,3
    add ebx,ecx
.spr_row8:
    and rax,7
    shl rbx,4
    lea rsi,[vram]
    add rsi,rbx
    lea rsi,[rsi+rax*2]
    movzx r10d,byte [rsi]
    movzx r11d,byte [rsi+1]
    sub edx,8
    xor r9,r9
.spix:
    cmp r9,8
    jge .next_spr
    lea rdi,[rdx+r9]
    cmp rdi,0
    jl .spix_next
    cmp rdi,160
    jge .spix_next
    mov ecx,7
    sub ecx,r9d
    test r15b,0x20               ; X flip
    jz .spr_bit
    mov ecx,r9d
.spr_bit:
    mov eax,r10d
    shr eax,cl
    and eax,1
    mov ebx,r11d
    shr ebx,cl
    and ebx,1
    shl ebx,1
    or eax,ebx
    test eax,eax
    jz .spix_next
    lea rsi,[spr_line_col]
    cmp byte [rsi+rdi],0
    je .spr_take
    lea rsi,[spr_line_x]
    movzx ebx,byte [rsi+rdi]
    cmp edx,ebx                  ; lower OAM X wins; ties keep lower index
    jae .spix_next
.spr_take:
    lea rsi,[spr_line_col]
    mov [rsi+rdi],al
    lea rsi,[spr_line_attr]
    mov [rsi+rdi],r15b
    lea rsi,[spr_line_x]
    mov [rsi+rdi],dl
.spix_next:
    inc r9
    jmp .spix
.next_spr:
    inc r14
    jmp .spr_loop
.composite:
    xor r13,r13
.comp:
    cmp r13,160
    jge .done
    lea rsi,[spr_line_col]
    movzx edx,byte [rsi+r13]
    test edx,edx
    jz .comp_next
    lea rsi,[spr_line_attr]
    movzx eax,byte [rsi+r13]
    test al,0x80                 ; OAM priority bit: hide on BG color != 0
    jz .comp_draw
    lea rsi,[bg_line_idx]
    cmp byte [rsi+r13],0
    jne .comp_next
.comp_draw:
    test al,0x10
    jz .comp_pal0
    movzx esi,byte [io+0x49]
    jmp .comp_pal
.comp_pal0:
    movzx esi,byte [io+0x48]
.comp_pal:
    mov ecx,edx
    shl ecx,1
    shr esi,cl
    and esi,3
    mov eax,esi
    call set_pixel_from_indextmp
.comp_next:
    inc r13
    jmp .comp
.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; set pixel: r13=x, r12=ly, eax=color index 0-3 (BGP already applied for BG; for generic use eax directly)
set_pixel_from_indextmp:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    cmp r13,160
    jae .d
    cmp r12,144
    jae .d
    and eax,3
    lea rsi,[palette_rgb]
    imul rax,3
    add rax,rsi
    ; framebuf offset = (ly*160+x)*3
    mov rbx,r12
    imul rbx,160
    add rbx,r13
    imul rbx,3
    lea rsi,[framebuf]
    add rsi,rbx
    mov dl,[rax]
    mov [rsi],dl
    mov dl,[rax+1]
    mov [rsi+1],dl
    mov dl,[rax+2]
    mov [rsi+2],dl
.d: pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

section .bss
instr_cycles: resd 1
prestep_done: resd 1   ; T-cycles already stepped before handler (intra-instruction timing)
; ---- APU state ----
apu_power:      resb 1
apu_fs_step:    resb 1
apu_fs_cyc:     resd 1
apu_wave_flag:  resb 1
apu_active:     resb 4
apu_dac:        resb 4
apu_len:        resw 4
apu_lenen:      resb 4
apu_frozen:     resb 4
apu_vol:        resb 4
apu_envper:     resb 4
apu_envdir:     resb 4
apu_envtimer:   resb 4
apu_freq:       resw 4
apu_timer:      resd 4
apu_dutypos:    resb 4
apu_sweepper:   resb 1
apu_sweepdir:   resb 1
apu_sweepshift: resb 1
apu_sweeptimer: resb 1
apu_sweepenable: resb 1
apu_sweepneg:   resb 1
apu_shadow:     resw 1
apu_lfsr:       resw 1
apu_scratch:    resb 4
apu_entrans:    resb 1
tmp16: resw 1
tmp8: resb 1
section .text
; ---------- register helpers ----------
; get_r(edi=0..7) -> al   0 B 1 C 2 D 3 E 4 H 5 L 6 (HL) 7 A
get_r:
    cmp edi,0
    je .b
    cmp edi,1
    je .c
    cmp edi,2
    je .d
    cmp edi,3
    je .e
    cmp edi,4
    je .h
    cmp edi,5
    je .l
    cmp edi,7
    je .a
    ; (HL)
    push rdi
    push rsi
    movzx rdi,byte [gb_h]
    shl rdi,8
    movzx rax,byte [gb_l]
    or rdi,rax
    call read_mem
    pop rsi
    pop rdi
    ret
.b: mov al,[gb_b]
    ret
.c: mov al,[gb_c]
    ret
.d: mov al,[gb_d]
    ret
.e: mov al,[gb_e]
    ret
.h: mov al,[gb_h]
    ret
.l: mov al,[gb_l]
    ret
.a: mov al,[gb_a]
    ret
; set_r(edi=idx, esi=val)
set_r:
    cmp edi,0
    je .b
    cmp edi,1
    je .c
    cmp edi,2
    je .d
    cmp edi,3
    je .e
    cmp edi,4
    je .h
    cmp edi,5
    je .l
    cmp edi,7
    je .a
    push rdi
    push rsi
    movzx rdi,byte [gb_h]
    shl rdi,8
    movzx rax,byte [gb_l]
    or rdi,rax
    movzx rsi,sil
    call write_mem
    pop rsi
    pop rdi
    ret
.b: mov [gb_b],sil
    ret
.c: mov [gb_c],sil
    ret
.d: mov [gb_d],sil
    ret
.e: mov [gb_e],sil
    ret
.h: mov [gb_h],sil
    ret
.l: mov [gb_l],sil
    ret
.a: mov [gb_a],sil
    ret
; get_rp(edi 0BC 1DE 2HL 3SP) -> ax
get_rp:
    cmp edi,0
    je .bc
    cmp edi,1
    je .de
    cmp edi,2
    je .hl
    mov ax,[gb_sp]
    ret
.bc: mov al,[gb_c]
    mov ah,[gb_b]
    ret
.de: mov al,[gb_e]
    mov ah,[gb_d]
    ret
.hl: mov al,[gb_l]
    mov ah,[gb_h]
    ret
; set_rp(edi, esi=val16)
set_rp:
    cmp edi,0
    je .bc
    cmp edi,1
    je .de
    cmp edi,2
    je .hl
    mov [gb_sp],si
    ret
.bc: mov [gb_c],sil
    mov [gb_b],sil
    shr esi,8
    mov [gb_b],sil
    ret
.de: mov [gb_e],sil
    shr esi,8
    mov [gb_d],sil
    ret
.hl: mov [gb_l],sil
    shr esi,8
    mov [gb_h],sil
    ret
; get_rp2(edi 0BC 1DE 2HL 3AF) -> ax
get_rp2:
    cmp edi,3
    je .af
    jmp get_rp
.af: mov al,[gb_f]
    mov ah,[gb_a]
    ret
set_rp2:
    cmp edi,3
    je .af
    jmp set_rp
.af: mov [gb_f],sil
    and byte [gb_f],0xF0
    shr esi,8
    mov [gb_a],sil
    ret
; fetch8 -> al (advances PC)
fetch8:
    push rdi
    movzx rdi,word [gb_pc]
    call read_mem
    inc word [gb_pc]
    pop rdi
    ret
fetch16:
    call fetch8
    movzx rdx,al
    call fetch8
    mov ah,al
    mov al,dl
    ret
; push16(esi=val) : SP-- high, SP-- low  (GB push: decrement then write high, decrement then low)
push16:
    jmp push16_v2
push16_v2: ; esi=val16
    push rdi
    push rsi
    push rcx
    mov rcx,rsi
    movzx eax,word [gb_sp]
    dec eax
    mov [gb_sp],ax
    mov rdi,rax
    mov rsi,rcx
    shr rsi,8
    call write_mem
    movzx eax,word [gb_sp]
    dec eax
    mov [gb_sp],ax
    mov rdi,rax
    mov rsi,rcx
    and rsi,0xFF
    call write_mem
    pop rcx
    pop rsi
    pop rdi
    ret
pop16: ; -> ax
    push rdi
    push rsi
    movzx rdi,word [gb_sp]
    call read_mem
    movzx rdx,al
    inc word [gb_sp]
    movzx rdi,word [gb_sp]
    call read_mem
    mov ah,al
    mov al,dl
    inc word [gb_sp]
    pop rsi
    pop rdi
    ret
; flags helpers: set NZH C from eax bits? we do inline in ALU funcs
do_cp_a: ; bl=op, cl=borrow - flags only, A preserved
    push rbx
    push rcx
    push rdx
    push r8
    movzx eax,byte [gb_a]
    movzx r8d,bl
    movzx ecx,cl
    mov rdx,rax
    sub eax,r8d
    sub eax,ecx
    mov byte [gb_f],0x40
    cmp eax,0
    jge .nob
    or byte [gb_f],0x10
.nob:
    cmp al,0
    jne .nonz
    or byte [gb_f],0x80
.nonz:
    mov ebx,edx
    and ebx,0x0F
    mov edx,r8d
    and edx,0x0F
    sub ebx,edx
    sub ebx,ecx
    cmp ebx,0
    jge .noh
    or byte [gb_f],0x20
.noh:
    pop r8
    pop rdx
    pop rcx
    pop rbx
    ret
do_add_a: ; bl=operand, cl=carryin
    push rbx
    push rcx
    push rdx
    push r8
    movzx eax,byte [gb_a]
    movzx r8d,bl
    movzx ecx,cl
    mov rdx,rax
    add eax,r8d
    add eax,ecx
    mov [tmp16],ax
    mov byte [gb_f],0
    cmp eax,0x100
    jb .noc
    or byte [gb_f],0x10
.noc:
    cmp al,0
    jne .nonz
    or byte [gb_f],0x80
.nonz:
    mov ebx,edx
    and ebx,0x0F
    mov edx,r8d
    and edx,0x0F
    add ebx,edx
    add ebx,ecx
    cmp ebx,0x10
    jb .noh
    or byte [gb_f],0x20
.noh:
    mov al,[tmp16]
    mov [gb_a],al
    pop r8
    pop rdx
    pop rcx
    pop rbx
    ret
do_sub_a: ; bl=op, cl=borrow
    push rbx
    push rcx
    push rdx
    push r8
    movzx eax,byte [gb_a]
    movzx r8d,bl
    movzx ecx,cl
    mov rdx,rax
    sub eax,r8d
    sub eax,ecx
    mov [tmp16],ax
    mov byte [gb_f],0x40
    cmp eax,0
    jge .nob
    or byte [gb_f],0x10
.nob:
    cmp al,0
    jne .nonz
    or byte [gb_f],0x80
.nonz:
    mov ebx,edx
    and ebx,0x0F
    mov edx,r8d
    and edx,0x0F
    sub ebx,edx
    sub ebx,ecx
    cmp ebx,0
    jge .noh
    or byte [gb_f],0x20
.noh:
    mov al,[tmp16]
    mov [gb_a],al
    pop r8
    pop rdx
    pop rcx
    pop rbx
    ret
inc8:
    push rbx
    push rcx
    mov cl,al
    mov bl,[gb_f]
    and bl,0x10
    inc al
    mov [tmp8],al
    mov byte [gb_f],0
    or [gb_f],bl
    cmp al,0
    jne .nz
    or byte [gb_f],0x80
.nz:
    and cl,0x0F
    cmp cl,0x0F
    jne .noh
    or byte [gb_f],0x20
.noh: mov al,[tmp8]
    pop rcx
    pop rbx
    ret
dec8:
    push rbx
    push rcx
    mov cl,al
    mov bl,[gb_f]
    and bl,0x10
    dec al
    mov [tmp8],al
    mov byte [gb_f],0x40
    or [gb_f],bl
    cmp al,0
    jne .nz
    or byte [gb_f],0x80
.nz:
    and cl,0x0F
    cmp cl,0
    jne .noh
    or byte [gb_f],0x20
.noh: mov al,[tmp8]
    pop rcx
    pop rbx
    ret
add_hl: ; ax=rp value
    push rbx
    push rcx
    push rdx
    push r8
    movzx ecx,ax
    movzx eax,byte [gb_h]
    shl eax,8
    movzx edx,byte [gb_l]
    or eax,edx
    add eax,ecx
    mov r8d,eax
    and r8d,0xFFFF
    mov dl,[gb_f]
    and dl,0x80
    mov [gb_f],dl
    cmp eax,0x10000
    jb .noc
    or byte [gb_f],0x10
.noc:
    movzx ebx,byte [gb_h]
    shl ebx,8
    movzx edx,byte [gb_l]
    or ebx,edx
    and ebx,0x0FFF
    mov edx,ecx
    and edx,0x0FFF
    add ebx,edx
    cmp ebx,0x1000
    jb .noh
    or byte [gb_f],0x20
.noh:
    mov [gb_l],r8b
    shr r8d,8
    mov [gb_h],r8b
    pop r8
    pop rdx
    pop rcx
    pop rbx
    ret
; condition edi=0 NZ,1 Z,2 NC,3 C -> dl=1 if true
cond_true:
    cmp edi,0
    je .nz
    cmp edi,1
    je .z
    cmp edi,2
    je .nc
    ; C
    test byte [gb_f],0x10
    jnz .t
    xor dl,dl
    ret
.t: mov dl,1
    ret
.nz: test byte [gb_f],0x80
    jz .t
    xor dl,dl
    ret
.z: test byte [gb_f],0x80
    jnz .t
    xor dl,dl
    ret
.nc: test byte [gb_f],0x10
    jz .t
    xor dl,dl
    ret

; ---------- interrupts ----------
service_interrupt: ; rdi = irq bit (1,2,4,8,16)
    ; Clear only the bit being serviced. Never touch the other pending flags
    ; (the previous VBlank-clear on every vector lost interrupts).
    push rdi
    mov al,[io+0x0F]
    mov rcx,rdi
    not cl
    and al,cl
    and al,0x1F
    mov [io+0x0F],al
    pop rdi
    mov byte [ime],0
    mov byte [halted],0
    mov byte [ei_delay],0
    ; push PC
    movzx esi,word [gb_pc]
    call push16
    ; vector = 0x40 + bit*8 ; bit index: 1->0x40,2->0x48,4->0x50,8->0x58,16->0x60
    cmp rdi,1
    je .v40
    cmp rdi,2
    je .v48
    cmp rdi,4
    je .v50
    cmp rdi,8
    je .v58
    mov word [gb_pc],0x60
    jmp .d
.v40: mov word [gb_pc],0x40
    jmp .d
.v48: mov word [gb_pc],0x48
    jmp .d
.v50: mov word [gb_pc],0x50
    jmp .d
.v58: mov word [gb_pc],0x58
.d: mov dword [instr_cycles],20
    ret
check_interrupts: ; -> eax: 0 none, else bit serviced; sets instr_cycles if serviced and caller should skip fetch
    xor eax,eax
    cmp byte [ime],0
    je .noime
    mov al,[io+0x0F]
    mov bl,[ie_reg]
    and al,bl
    and al,0x1F
    jz .noime
    test al,1
    jnz .svc1
    test al,2
    jnz .svc2
    test al,4
    jnz .svc4
    test al,8
    jnz .svc8
    test al,16
    jnz .svc16
    xor eax,eax
    ret
.svc1: mov rdi,1
    call service_interrupt
    mov eax,1
    ret
.svc2: mov rdi,2
    call service_interrupt
    mov eax,1
    ret
.svc4: mov rdi,4
    call service_interrupt
    mov eax,1
    ret
.svc8: mov rdi,8
    call service_interrupt
    mov eax,1
    ret
.svc16: mov rdi,16
    call service_interrupt
    mov eax,1
    ret
.noime: xor eax,eax
    ret
pending_interrupt: ; -> al = IE&IF &1F
    mov al,[io+0x0F]
    and al,[ie_reg]
    and al,0x1F
    ret

; ---------- cpu_step: execute 1 instruction, step system, return cycles in eax ----------
cpu_step:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    mov dword [instr_cycles],4
    mov dword [prestep_done],0
    ; halted handling
    cmp byte [halted],0
    je .not_halted
    call pending_interrupt
    test al,al
    jz .halt_sleep
    cmp byte [ime],0
    je .halt_wake_noime
    ; IME=1: service below at interrupt check
    mov byte [halted],0
    jmp .int_check
.halt_wake_noime:
    mov byte [halted],0
    mov dword [instr_cycles],4
    jmp cpu_finish_step
.halt_sleep:
    mov dword [instr_cycles],4
    jmp cpu_finish_step
.not_halted:
.int_check:
    call check_interrupts
    test eax,eax
    jnz cpu_finish_step
    ; fetch opcode
    movzx rdi,word [gb_pc]
    call read_mem
    mov r12d,eax
    inc word [gb_pc]
    cmp byte [cli_debug],0
    je .nodebug
    cmp qword [debug_count],200
    jae .nodebug
    inc qword [debug_count]
    push rax
    push rdi
    push rsi
    push rdx
    movzx rax,word [gb_pc]
    dec rax
    call print_str_radix
    lea rdi,[dbg_colon]
    call prints0
    mov rax,r12
    call print_hex8
    lea rdi,[dbg_nl]
    call prints0
    pop rdx
    pop rsi
    pop rdi
    pop rax
.nodebug:
    ; intra-instruction timing: pre-step for last-cycle memory accesses
    ; (LD (BC/DE/HL±),A / LD A,(BC/DE/HL±) 8T -> 4; LD (HL),d8 / LDH 12T -> 8;
    ; LD (a16),A / LD A,(a16) 16T -> 12). LD r,r and ALU A,r (HL) variants
    ; pre-step inside their blocks below; INC/DEC (HL) split-step in handlers.
    cmp r12d,0x02
    je .pre4
    cmp r12d,0x12
    je .pre4
    cmp r12d,0x22
    je .pre4
    cmp r12d,0x32
    je .pre4
    cmp r12d,0x0A
    je .pre4
    cmp r12d,0x1A
    je .pre4
    cmp r12d,0x2A
    je .pre4
    cmp r12d,0x3A
    je .pre4
    cmp r12d,0xE2
    je .pre4
    cmp r12d,0xF2
    je .pre4
    cmp r12d,0x36
    je .pre8
    cmp r12d,0xE0
    je .pre8
    cmp r12d,0xF0
    je .pre8
    cmp r12d,0xEA
    je .pre12
    cmp r12d,0xFA
    je .pre12
    jmp .pre_done
.pre4:  mov edi,4
    call do_prestep
    jmp .pre_done
.pre8:  mov edi,8
    call do_prestep
    jmp .pre_done
.pre12: mov edi,12
    call do_prestep
.pre_done:
    ; CB prefix
    cmp r12d,0xCB
    je .do_cb
    ; LD r,r'  0x40-0x7F except 0x76
    cmp r12d,0x40
    jb .not_ldr
    cmp r12d,0x80
    jae .not_ldr
    cmp r12d,0x76
    je .not_ldr
    mov r13d,r12d
    shr r13d,3
    and r13d,7
    mov r14d,r12d
    and r14d,7
    cmp r13d,6
    je .ldr_pre
    cmp r14d,6
    je .ldr_pre
    jmp .ldr_nopre
.ldr_pre:
    mov edi,4
    call do_prestep
.ldr_nopre:
    mov rdi,r14
    call get_r
    movzx esi,al
    mov rdi,r13
    call set_r
    mov dword [instr_cycles],4
    cmp r13d,6
    je .ldr8
    cmp r14d,6
    je .ldr8
    jmp cpu_finish_step
.ldr8: mov dword [instr_cycles],8
    jmp cpu_finish_step
.not_ldr:
    ; ALU A,r 0x80-0xBF
    cmp r12d,0x80
    jb .dispatch
    cmp r12d,0xC0
    jae .dispatch
    mov r13d,r12d
    shr r13d,3
    and r13d,7
    mov r14d,r12d
    and r14d,7
    cmp r14d,6
    jne .alu_nopre
    mov edi,4
    call do_prestep
.alu_nopre:
    mov rdi,r14
    call get_r
    mov bl,al
    ; alu op r13: 0 ADD 1 ADC 2 SUB 3 SBC 4 AND 5 XOR 6 OR 7 CP
    cmp r13d,0
    je .alu_add
    cmp r13d,1
    je .alu_adc
    cmp r13d,2
    je .alu_sub
    cmp r13d,3
    je .alu_sbc
    cmp r13d,4
    je .alu_and
    cmp r13d,5
    je .alu_xor
    cmp r13d,6
    je .alu_or
    ; CP
    mov cl,0
    call do_cp_a
    jmp .alu_done
.alu_add: mov cl,0
    call do_add_a
    jmp .alu_done
.alu_adc: mov cl,0
    test byte [gb_f],0x10
    jz .adc0
    mov cl,1
.adc0: call do_add_a
    jmp .alu_done
.alu_sub: mov cl,0
    call do_sub_a
    jmp .alu_done
.alu_sbc: mov cl,0
    test byte [gb_f],0x10
    jz .sbc0
    mov cl,1
.sbc0: call do_sub_a
    jmp .alu_done
.alu_and:
    mov al,[gb_a]
    and al,bl
    mov [gb_a],al
    mov byte [gb_f],0x20
    cmp al,0
    jne .alu_done
    or byte [gb_f],0x80
    jmp .alu_done
.alu_xor:
    mov al,[gb_a]
    xor al,bl
    mov [gb_a],al
    mov byte [gb_f],0
    cmp al,0
    jne .alu_done
    or byte [gb_f],0x80
    jmp .alu_done
.alu_or:
    mov al,[gb_a]
    or al,bl
    mov [gb_a],al
    mov byte [gb_f],0
    cmp al,0
    jne .alu_done
    or byte [gb_f],0x80
.alu_done:
    mov dword [instr_cycles],4
    cmp r14d,6
    je .alu8
    jmp cpu_finish_step
.alu8: mov dword [instr_cycles],8
    jmp cpu_finish_step
.dispatch:
    ; misc opcodes via compare chain (r12d = opcode)
    ; macro-like: cmp/je
    cmp r12d,0x00
    je op_nop
    cmp r12d,0x01
    je op_ld_bc
    cmp r12d,0x02
    je op_ld_bc_a
    cmp r12d,0x03
    je op_inc_bc
    cmp r12d,0x04
    je op_inc_r
    cmp r12d,0x05
    je op_dec_r
    cmp r12d,0x06
    je op_ld_r_d8
    cmp r12d,0x07
    je op_rlca
    cmp r12d,0x08
    je op_ld_a16_sp
    cmp r12d,0x09
    je op_add_hl
    cmp r12d,0x0A
    je op_ld_a_bc
    cmp r12d,0x0B
    je op_dec_bc
    cmp r12d,0x0C
    je op_inc_r
    cmp r12d,0x0D
    je op_dec_r
    cmp r12d,0x0E
    je op_ld_r_d8
    cmp r12d,0x0F
    je op_rrca
    cmp r12d,0x10
    je op_stop
    cmp r12d,0x11
    je op_ld_de
    cmp r12d,0x12
    je op_ld_de_a
    cmp r12d,0x13
    je op_inc_de
    cmp r12d,0x14
    je op_inc_r
    cmp r12d,0x15
    je op_dec_r
    cmp r12d,0x16
    je op_ld_r_d8
    cmp r12d,0x17
    je op_rla
    cmp r12d,0x18
    je op_jr
    cmp r12d,0x19
    je op_add_hl
    cmp r12d,0x1A
    je op_ld_a_de
    cmp r12d,0x1B
    je op_dec_de
    cmp r12d,0x1C
    je op_inc_r
    cmp r12d,0x1D
    je op_dec_r
    cmp r12d,0x1E
    je op_ld_r_d8
    cmp r12d,0x1F
    je op_rra
    cmp r12d,0x20
    je op_jr_cc
    cmp r12d,0x21
    je op_ld_hl
    cmp r12d,0x22
    je op_ld_hl_inc_a
    cmp r12d,0x23
    je op_inc_hl
    cmp r12d,0x24
    je op_inc_r
    cmp r12d,0x25
    je op_dec_r
    cmp r12d,0x26
    je op_ld_r_d8
    cmp r12d,0x27
    je op_daa
    cmp r12d,0x28
    je op_jr_cc
    cmp r12d,0x29
    je op_add_hl
    cmp r12d,0x2A
    je op_ld_a_hl_inc
    cmp r12d,0x2B
    je op_dec_hl
    cmp r12d,0x2C
    je op_inc_r
    cmp r12d,0x2D
    je op_dec_r
    cmp r12d,0x2E
    je op_ld_r_d8
    cmp r12d,0x2F
    je op_cpl
    cmp r12d,0x30
    je op_jr_cc
    cmp r12d,0x31
    je op_ld_sp
    cmp r12d,0x32
    je op_ld_hl_dec_a
    cmp r12d,0x33
    je op_inc_sp
    cmp r12d,0x34
    je op_inc_r
    cmp r12d,0x35
    je op_dec_r
    cmp r12d,0x36
    je op_ld_hl_d8
    cmp r12d,0x37
    je op_scf
    cmp r12d,0x38
    je op_jr_cc
    cmp r12d,0x39
    je op_add_hl
    cmp r12d,0x3A
    je op_ld_a_hl_dec
    cmp r12d,0x3B
    je op_dec_sp
    cmp r12d,0x3C
    je op_inc_r
    cmp r12d,0x3D
    je op_dec_r
    cmp r12d,0x3E
    je op_ld_r_d8
    cmp r12d,0x3F
    je op_ccf
    cmp r12d,0xC0
    je op_ret_cc
    cmp r12d,0xC1
    je op_pop_rp
    cmp r12d,0xC2
    je op_jp_cc
    cmp r12d,0xC3
    je op_jp
    cmp r12d,0xC4
    je op_call_cc
    cmp r12d,0xC5
    je op_push_rp
    cmp r12d,0xC6
    je op_alu_d8
    cmp r12d,0xC7
    je op_rst
    cmp r12d,0xC8
    je op_ret_cc
    cmp r12d,0xC9
    je op_ret
    cmp r12d,0xCA
    je op_jp_cc
    cmp r12d,0xCB
    je .do_cb
    cmp r12d,0xCC
    je op_call_cc
    cmp r12d,0xCD
    je op_call
    cmp r12d,0xCE
    je op_alu_d8
    cmp r12d,0xCF
    je op_rst
    cmp r12d,0xD0
    je op_ret_cc
    cmp r12d,0xD1
    je op_pop_rp
    cmp r12d,0xD2
    je op_jp_cc
    cmp r12d,0xD3
    je op_nop
    cmp r12d,0xD4
    je op_call_cc
    cmp r12d,0xD5
    je op_push_rp
    cmp r12d,0xD6
    je op_alu_d8
    cmp r12d,0xD7
    je op_rst
    cmp r12d,0xD8
    je op_ret_cc
    cmp r12d,0xD9
    je op_reti
    cmp r12d,0xDA
    je op_jp_cc
    cmp r12d,0xDB
    je op_nop
    cmp r12d,0xDC
    je op_call_cc
    cmp r12d,0xDD
    je op_nop
    cmp r12d,0xDE
    je op_alu_d8
    cmp r12d,0xDF
    je op_rst
    cmp r12d,0xE0
    je op_ldh_c_a
    cmp r12d,0xE1
    je op_pop_rp
    cmp r12d,0xE2
    je op_ld_c_a
    cmp r12d,0xE3
    je op_nop
    cmp r12d,0xE4
    je op_nop
    cmp r12d,0xE5
    je op_push_rp
    cmp r12d,0xE6
    je op_alu_d8
    cmp r12d,0xE7
    je op_rst
    cmp r12d,0xE8
    je op_add_sp_e8
    cmp r12d,0xE9
    je op_jp_hl
    cmp r12d,0xEA
    je op_ld_a16_a
    cmp r12d,0xEB
    je op_nop
    cmp r12d,0xEC
    je op_nop
    cmp r12d,0xED
    je op_nop
    cmp r12d,0xEE
    je op_alu_d8
    cmp r12d,0xEF
    je op_rst
    cmp r12d,0xF0
    je op_ldh_a_c
    cmp r12d,0xF1
    je op_pop_rp
    cmp r12d,0xF2
    je op_ld_a_c
    cmp r12d,0xF3
    je op_di
    cmp r12d,0xF4
    je op_nop
    cmp r12d,0xF5
    je op_push_rp
    cmp r12d,0xF6
    je op_alu_d8
    cmp r12d,0xF7
    je op_rst
    cmp r12d,0xF8
    je op_ld_hl_sp_e8
    cmp r12d,0xF9
    je op_ld_sp_hl
    cmp r12d,0xFA
    je op_ld_a_a16
    cmp r12d,0xFB
    je op_ei
    cmp r12d,0xFC
    je op_nop
    cmp r12d,0xFD
    je op_nop
    cmp r12d,0xFE
    je op_alu_d8
    cmp r12d,0xFF
    je op_rst
    cmp r12d,0x76
    je op_halt
    ; unknown -> NOP
    jmp op_nop
.do_cb:
    call fetch8
    mov r12d,eax
    ; CB (HL): BIT read at cycle 3 (pre-step 8), modify read at cycle 3
    ; (pre-step 8, mid-step 4 before write inside cb_execute). Reg ops: none.
    mov eax,r12d
    and eax,7
    cmp eax,6
    jne .cb_nopre
    mov edi,8
    call do_prestep
.cb_nopre:
    call cb_execute
    jmp cpu_finish_step
cpu_finish_step:
    ; EI delay countdown (set to 2 by EI, decrements each instruction end)
    cmp byte [ei_delay],0
    je .ei_done
    dec byte [ei_delay]
    jnz .ei_done
    mov byte [ime],1
.ei_done:
    mov eax,[instr_cycles]
    sub eax,dword [prestep_done]
    mov dword [prestep_done],0
    mov rdi,rax
    call step_system
    mov eax,[instr_cycles]
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ---------- misc opcode handlers (r12d=opcode, jmp cpu_finish_step at end) ----------
op_nop:
    mov dword [instr_cycles],4
    jmp cpu_finish_step
op_stop:
    ; STOP: fetch padding byte, halt until joypad - we just advance and continue (games re-sync)
    call fetch8
    mov dword [instr_cycles],4
    jmp cpu_finish_step
op_halt:
    mov byte [halted],1
    mov dword [instr_cycles],4
    jmp cpu_finish_step
op_di:
    mov byte [ime],0
    mov byte [ei_delay],0
    mov dword [instr_cycles],4
    jmp cpu_finish_step
op_ei:
    mov byte [ei_delay],2
    mov dword [instr_cycles],4
    jmp cpu_finish_step
op_reti:
    mov byte [ime],1
    call pop16
    mov [gb_pc],ax
    mov dword [instr_cycles],16
    jmp cpu_finish_step
; generic helpers decoding from r12d
; op_inc_r / op_dec_r / op_ld_r_d8 : target = (op>>3)&7
op_inc_r:
    mov r13d,r12d
    shr r13d,3
    and r13d,7
    cmp r13d,6
    jne .inc_nopre
    ; INC (HL): read at cycle 2 (step 4), write at cycle 3 (step 4 more)
    mov edi,4
    call do_prestep
.inc_nopre:
    mov rdi,r13
    call get_r
    call inc8
    movzx esi,al
    cmp r13d,6
    jne .inc_nopre2
    mov edi,4
    call do_prestep
.inc_nopre2:
    mov rdi,r13
    call set_r
    mov dword [instr_cycles],4
    cmp r13d,6
    jne cpu_finish_step
    mov dword [instr_cycles],12
    jmp cpu_finish_step
op_dec_r:
    mov r13d,r12d
    shr r13d,3
    and r13d,7
    cmp r13d,6
    jne .dec_nopre
    ; DEC (HL): read at cycle 2 (step 4), write at cycle 3 (step 4 more)
    mov edi,4
    call do_prestep
.dec_nopre:
    mov rdi,r13
    call get_r
    call dec8
    movzx esi,al
    cmp r13d,6
    jne .dec_nopre2
    mov edi,4
    call do_prestep
.dec_nopre2:
    mov rdi,r13
    call set_r
    mov dword [instr_cycles],4
    cmp r13d,6
    jne cpu_finish_step
    mov dword [instr_cycles],12
    jmp cpu_finish_step
op_ld_r_d8:
    mov r13d,r12d
    shr r13d,3
    and r13d,7
    call fetch8
    movzx esi,al
    mov rdi,r13
    call set_r
    mov dword [instr_cycles],8
    cmp r13d,6
    jne cpu_finish_step
    mov dword [instr_cycles],12
    jmp cpu_finish_step
op_ld_hl_d8: ; 0x36 LD (HL),d8
    call fetch8
    mov r8b,al
    mov rdi,6
    movzx esi,r8b
    call set_r
    mov dword [instr_cycles],12
    jmp cpu_finish_step
op_ld_bc:
    call fetch16
    movzx esi,ax
    mov rdi,0
    call set_rp
    mov dword [instr_cycles],12
    jmp cpu_finish_step
op_ld_de:
    call fetch16
    movzx esi,ax
    mov rdi,1
    call set_rp
    mov dword [instr_cycles],12
    jmp cpu_finish_step
op_ld_hl:
    call fetch16
    movzx esi,ax
    mov rdi,2
    call set_rp
    mov dword [instr_cycles],12
    jmp cpu_finish_step
op_ld_sp:
    call fetch16
    mov [gb_sp],ax
    mov dword [instr_cycles],12
    jmp cpu_finish_step
op_inc_bc:
    mov rdi,0
    call get_rp
    inc ax
    movzx esi,ax
    mov rdi,0
    call set_rp
    mov dword [instr_cycles],8
    jmp cpu_finish_step
op_inc_de:
    mov rdi,1
    call get_rp
    inc ax
    movzx esi,ax
    mov rdi,1
    call set_rp
    mov dword [instr_cycles],8
    jmp cpu_finish_step
op_inc_hl:
    mov rdi,2
    call get_rp
    inc ax
    movzx esi,ax
    mov rdi,2
    call set_rp
    mov dword [instr_cycles],8
    jmp cpu_finish_step
op_inc_sp:
    inc word [gb_sp]
    mov dword [instr_cycles],8
    jmp cpu_finish_step
op_dec_bc:
    mov rdi,0
    call get_rp
    dec ax
    movzx esi,ax
    mov rdi,0
    call set_rp
    mov dword [instr_cycles],8
    jmp cpu_finish_step
op_dec_de:
    mov rdi,1
    call get_rp
    dec ax
    movzx esi,ax
    mov rdi,1
    call set_rp
    mov dword [instr_cycles],8
    jmp cpu_finish_step
op_dec_hl:
    mov rdi,2
    call get_rp
    dec ax
    movzx esi,ax
    mov rdi,2
    call set_rp
    mov dword [instr_cycles],8
    jmp cpu_finish_step
op_dec_sp:
    dec word [gb_sp]
    mov dword [instr_cycles],8
    jmp cpu_finish_step
op_add_hl: ; rp = (op>>4)&3  0BC 1DE 2HL 3SP
    mov r13d,r12d
    shr r13d,4
    and r13d,3
    cmp r13d,0
    je .rp_bc
    cmp r13d,1
    je .rp_de
    cmp r13d,2
    je .rp_hl
    movzx ecx,word [gb_sp]
    jmp .do_add
.rp_bc:
    movzx ecx,byte [gb_c]
    movzx eax,byte [gb_b]
    shl eax,8
    or eax,ecx
    mov ecx,eax
    jmp .do_add
.rp_de:
    movzx ecx,byte [gb_e]
    movzx eax,byte [gb_d]
    shl eax,8
    or eax,ecx
    mov ecx,eax
    jmp .do_add
.rp_hl:
    movzx ecx,byte [gb_l]
    movzx eax,byte [gb_h]
    shl eax,8
    or eax,ecx
    mov ecx,eax
.do_add:
    movzx eax,byte [gb_h]
    shl eax,8
    movzx edx,byte [gb_l]
    or eax,edx
    add eax,ecx
    mov [tmp16],ax
    mov dl,[gb_f]
    and dl,0x80
    mov [gb_f],dl
    cmp eax,0x10000
    jb .noc
    or byte [gb_f],0x10
.noc:
    movzx ebx,byte [gb_h]
    shl ebx,8
    movzx edx,byte [gb_l]
    or ebx,edx
    and ebx,0x0FFF
    mov edx,ecx
    and edx,0x0FFF
    add ebx,edx
    cmp ebx,0x1000
    jb .noh
    or byte [gb_f],0x20
.noh:
    mov ax,[tmp16]
    mov [gb_l],al
    mov [gb_h],ah
    mov dword [instr_cycles],8
    jmp cpu_finish_step
op_ld_bc_a: ; (BC),A
    mov rdi,0
    call get_rp
    movzx rdi,ax
    movzx rsi,byte [gb_a]
    call write_mem
    mov dword [instr_cycles],8
    jmp cpu_finish_step
op_ld_a_bc:
    mov rdi,0
    call get_rp
    movzx rdi,ax
    call read_mem
    mov [gb_a],al
    mov dword [instr_cycles],8
    jmp cpu_finish_step
op_ld_de_a:
    mov rdi,1
    call get_rp
    movzx rdi,ax
    movzx rsi,byte [gb_a]
    call write_mem
    mov dword [instr_cycles],8
    jmp cpu_finish_step
op_ld_a_de:
    mov rdi,1
    call get_rp
    movzx rdi,ax
    call read_mem
    mov [gb_a],al
    mov dword [instr_cycles],8
    jmp cpu_finish_step
op_ld_hl_inc_a: ; (HL+),A  0x22
    mov rdi,2
    call get_rp
    movzx rdi,ax
    mov r10d,eax
    movzx rsi,byte [gb_a]
    call write_mem
    inc r10w
    movzx esi,r10w
    mov rdi,2
    call set_rp
    mov dword [instr_cycles],8
    jmp cpu_finish_step
op_ld_hl_dec_a: ; (HL-),A 0x32
    mov rdi,2
    call get_rp
    movzx rdi,ax
    mov r10d,eax
    movzx rsi,byte [gb_a]
    call write_mem
    dec r10w
    movzx esi,r10w
    mov rdi,2
    call set_rp
    mov dword [instr_cycles],8
    jmp cpu_finish_step
op_ld_a_hl_dec: ; A,(HL-) 0x3A
    mov rdi,2
    call get_rp
    movzx rdi,ax
    mov r10d,eax
    call read_mem
    mov [gb_a],al
    dec r10w
    movzx esi,r10w
    mov rdi,2
    call set_rp
    mov dword [instr_cycles],8
    jmp cpu_finish_step
op_ld_a_hl_inc: ; A,(HL+) 0x2A
    mov rdi,2
    call get_rp
    movzx rdi,ax
    mov r10d,eax
    call read_mem
    mov [gb_a],al
    inc r10w
    movzx esi,r10w
    mov rdi,2
    call set_rp
    mov dword [instr_cycles],8
    jmp cpu_finish_step
op_ld_a16_sp: ; (a16),SP 0x08  writes lo at a16, hi at a16+1
    call fetch16
    movzx r8d,ax                ; a16
    mov rdi,r8
    movzx rsi,byte [gb_sp]      ; lo byte of SP
    call write_mem
    lea rdi,[r8+1]
    movzx rsi,word [gb_sp]
    shr rsi,8                   ; hi byte of SP
    call write_mem
    mov dword [instr_cycles],20
    jmp cpu_finish_step
op_jr:
    call fetch8
    movsx rax,al
    movzx rcx,word [gb_pc]
    add rax,rcx
    mov [gb_pc],ax
    mov dword [instr_cycles],12
    jmp cpu_finish_step
op_jr_cc: ; cond = (op>>3)&3 : 0NZ 1Z 2NC 3C
    mov r13d,r12d
    shr r13d,3
    and r13d,3
    call fetch8
    mov r10d,eax
    mov rdi,r13
    call cond_true
    test dl,dl
    jz .notaken
    movsx rax,r10b
    add rax,[gb_pc]
    mov [gb_pc],ax
    mov dword [instr_cycles],12
    jmp cpu_finish_step
.notaken:
    mov dword [instr_cycles],8
    jmp cpu_finish_step
op_jp:
    call fetch16
    mov [gb_pc],ax
    mov dword [instr_cycles],16
    jmp cpu_finish_step
op_jp_cc:
    mov r13d,r12d
    shr r13d,3
    and r13d,3
    call fetch16
    mov r10d,eax
    mov rdi,r13
    call cond_true
    test dl,dl
    jz .nt
    mov [gb_pc],r10w
    mov dword [instr_cycles],16
    jmp cpu_finish_step
.nt: mov dword [instr_cycles],12
    jmp cpu_finish_step
op_jp_hl:
    mov rdi,2
    call get_rp
    mov [gb_pc],ax
    mov dword [instr_cycles],4
    jmp cpu_finish_step
op_call:
    call fetch16
    mov r10d,eax
    movzx esi,word [gb_pc]
    call push16
    mov [gb_pc],r10w
    mov dword [instr_cycles],24
    jmp cpu_finish_step
op_call_cc:
    mov r13d,r12d
    shr r13d,3
    and r13d,3
    call fetch16
    mov r10d,eax
    mov rdi,r13
    call cond_true
    test dl,dl
    jz .nt
    movzx esi,word [gb_pc]
    call push16
    mov [gb_pc],r10w
    mov dword [instr_cycles],24
    jmp cpu_finish_step
.nt: mov dword [instr_cycles],12
    jmp cpu_finish_step
op_ret:
    call pop16
    mov [gb_pc],ax
    mov dword [instr_cycles],16
    jmp cpu_finish_step
op_ret_cc:
    mov r13d,r12d
    shr r13d,3
    and r13d,3
    mov rdi,r13
    call cond_true
    test dl,dl
    jz .nt
    call pop16
    mov [gb_pc],ax
    mov dword [instr_cycles],20
    jmp cpu_finish_step
.nt: mov dword [instr_cycles],8
    jmp cpu_finish_step
op_rst:
    mov r13d,r12d
    and r13d,0x38
    movzx esi,word [gb_pc]
    call push16
    mov [gb_pc],r13w
    mov dword [instr_cycles],16
    jmp cpu_finish_step
op_push_rp: ; rp2 = (op>>4)&3 , AF for 0xF5 etc (3)
    mov r13d,r12d
    shr r13d,4
    and r13d,3
    mov rdi,r13
    call get_rp2
    movzx esi,ax
    call push16
    mov dword [instr_cycles],16
    jmp cpu_finish_step
op_pop_rp:
    mov r13d,r12d
    shr r13d,4
    and r13d,3
    call pop16
    movzx esi,ax
    mov rdi,r13
    call set_rp2
    mov dword [instr_cycles],12
    jmp cpu_finish_step
op_alu_d8: ; op>>3 &7
    mov r13d,r12d
    shr r13d,3
    and r13d,7
    call fetch8
    mov bl,al
    cmp r13d,0
    je .a0
    cmp r13d,1
    je .a1
    cmp r13d,2
    je .a2
    cmp r13d,3
    je .a3
    cmp r13d,4
    je .a4
    cmp r13d,5
    je .a5
    cmp r13d,6
    je .a6
    mov cl,0
    call do_cp_a
    jmp .done
.a0: mov cl,0
    call do_add_a
    jmp .done
.a1: mov cl,0
    test byte [gb_f],0x10
    jz .a1z
    mov cl,1
.a1z: call do_add_a
    jmp .done
.a2: mov cl,0
    call do_sub_a
    jmp .done
.a3: mov cl,0
    test byte [gb_f],0x10
    jz .a3z
    mov cl,1
.a3z: call do_sub_a
    jmp .done
.a4: mov al,[gb_a]
    and al,bl
    mov [gb_a],al
    mov byte [gb_f],0x20
    cmp al,0
    jne .done
    or byte [gb_f],0x80
    jmp .done
.a5: mov al,[gb_a]
    xor al,bl
    mov [gb_a],al
    mov byte [gb_f],0
    cmp al,0
    jne .done
    or byte [gb_f],0x80
    jmp .done
.a6: mov al,[gb_a]
    or al,bl
    mov [gb_a],al
    mov byte [gb_f],0
    cmp al,0
    jne .done
    or byte [gb_f],0x80
.done: mov dword [instr_cycles],8
    jmp cpu_finish_step
op_ldh_c_a: ; (FF00+C),A  0xE0
    call fetch8
    movzx rdi,ax
    add rdi,0xFF00
    movzx rsi,byte [gb_a]
    call write_mem
    mov dword [instr_cycles],12
    jmp cpu_finish_step
op_ldh_a_c: ; A,(FF00+C) 0xF0
    call fetch8
    movzx rdi,ax
    add rdi,0xFF00
    call read_mem
    mov [gb_a],al
    mov dword [instr_cycles],12
    jmp cpu_finish_step
op_ld_c_a: ; (FF00+C reg),A 0xE2 : C reg is gb_c
    movzx rdi,byte [gb_c]
    add rdi,0xFF00
    movzx rsi,byte [gb_a]
    call write_mem
    mov dword [instr_cycles],8
    jmp cpu_finish_step
op_ld_a_c: ; A,(FF00+C) 0xF2
    movzx rdi,byte [gb_c]
    add rdi,0xFF00
    call read_mem
    mov [gb_a],al
    mov dword [instr_cycles],8
    jmp cpu_finish_step
op_ld_a16_a: ; (a16),A 0xEA
    call fetch16
    movzx rdi,ax
    movzx rsi,byte [gb_a]
    call write_mem
    mov dword [instr_cycles],16
    jmp cpu_finish_step
op_ld_a_a16: ; A,(a16) 0xFA
    call fetch16
    movzx rdi,ax
    call read_mem
    mov [gb_a],al
    mov dword [instr_cycles],16
    jmp cpu_finish_step
op_add_sp_e8:
    call fetch8
    movzx r10d,al
    movsx rax,al
    movzx rcx,word [gb_sp]
    add rcx,rax
    mov [tmp16],cx
    mov byte [gb_f],0
    mov edx,[gb_sp]
    and edx,0x0F
    mov r8d,r10d
    and r8d,0x0F
    add edx,r8d
    cmp edx,0x10
    jb .noh
    or byte [gb_f],0x20
.noh:
    mov edx,[gb_sp]
    and edx,0xFF
    mov r8d,r10d
    add edx,r8d
    cmp edx,0x100
    jb .noc
    or byte [gb_f],0x10
.noc:
    mov ax,[tmp16]
    mov [gb_sp],ax
    mov dword [instr_cycles],16
    jmp cpu_finish_step
op_ld_hl_sp_e8:
    call fetch8
    movzx r10d,al
    movsx rax,al
    movzx rcx,word [gb_sp]
    add rcx,rax
    mov [tmp16],cx
    mov byte [gb_f],0
    mov edx,[gb_sp]
    and edx,0x0F
    mov r8d,r10d
    and r8d,0x0F
    add edx,r8d
    cmp edx,0x10
    jb .noh
    or byte [gb_f],0x20
.noh:
    mov edx,[gb_sp]
    and edx,0xFF
    mov r8d,r10d
    add edx,r8d
    cmp edx,0x100
    jb .noc
    or byte [gb_f],0x10
.noc:
    mov ax,[tmp16]
    mov [gb_l],al
    mov [gb_h],ah
    mov dword [instr_cycles],12
    jmp cpu_finish_step
op_ld_sp_hl: ; LD SP,HL 0xF9
    mov rdi,2
    call get_rp
    mov [gb_sp],ax
    mov dword [instr_cycles],8
    jmp cpu_finish_step
; rotates on A
op_rlca:
    mov al,[gb_a]
    mov bl,al
    shl al,1
    shr bl,7
    or al,bl
    mov [gb_a],al
    mov byte [gb_f],0
    test bl,1
    jz cpu_finish_step
    or byte [gb_f],0x10
    mov dword [instr_cycles],4
    jmp cpu_finish_step
op_rrca:
    mov al,[gb_a]
    mov bl,al
    shr al,1
    test bl,1
    jz .nc
    or al,0x80
.nc: mov [gb_a],al
    mov byte [gb_f],0
    test bl,1
    jz .nc2
    or byte [gb_f],0x10
.nc2: mov dword [instr_cycles],4
    jmp cpu_finish_step
op_rla:
    mov al,[gb_a]
    mov bl,al
    shl al,1
    test byte [gb_f],0x10
    jz .nc
    or al,1
.nc: mov [gb_a],al
    mov byte [gb_f],0
    test bl,0x80
    jz .nc2
    or byte [gb_f],0x10
.nc2: mov dword [instr_cycles],4
    jmp cpu_finish_step
op_rra:
    mov al,[gb_a]
    mov bl,al
    shr al,1
    test byte [gb_f],0x10
    jz .nc
    or al,0x80
.nc: mov [gb_a],al
    mov byte [gb_f],0
    test bl,1
    jz .nc2
    or byte [gb_f],0x10
.nc2: mov dword [instr_cycles],4
    jmp cpu_finish_step
op_daa:
    push rbx
    push rcx
    push rdx
    mov al,[gb_a]
    test byte [gb_f],0x40
    jnz op_daa_sub
    ; --- addition path ---
    xor ebx,ebx
    mov dl,al
    and dl,0x0F
    cmp dl,9
    jbe .chk_h
    add ebx,6
.chk_h:
    test byte [gb_f],0x20
    jz .chk_high
    cmp ebx,0
    jne .chk_high
    add ebx,6
.chk_high:
    xor ecx,ecx
    cmp al,0x99
    jbe .chk_c
    mov ecx,1
.chk_c:
    test byte [gb_f],0x10
    jz .apply
    mov ecx,1
.apply:
    test ecx,ecx
    jz .apply2
    add ebx,0x60
.apply2:
    add al,bl
    mov [gb_a],al
    mov byte [gb_f],0
    test ecx,ecx
    jz .nc2
    or byte [gb_f],0x10
.nc2:
    cmp al,0
    jne .done
    or byte [gb_f],0x80
.done:
    pop rdx
    pop rcx
    pop rbx
    mov dword [instr_cycles],4
    jmp cpu_finish_step
op_daa_sub:
    ; --- subtraction path ---
    mov al,[gb_a]
    test byte [gb_f],0x20
    jz .s_noh
    sub al,0x06
.s_noh:
    test byte [gb_f],0x10
    jz .s_noc
    sub al,0x60
.s_noc:
    mov bl,[gb_f]
    and bl,0x10
    mov [gb_a],al
    mov byte [gb_f],0x40
    or [gb_f],bl
    cmp al,0
    jne .s_done
    or byte [gb_f],0x80
.s_done:
    pop rdx
    pop rcx
    pop rbx
    mov dword [instr_cycles],4
    jmp cpu_finish_step
op_cpl:
    xor byte [gb_a],0xFF
    ; N and H set; Z and C are preserved (CPL does not touch them).
    mov al,[gb_f]
    and al,0x90
    or al,0x60
    mov [gb_f],al
    mov dword [instr_cycles],4
    jmp cpu_finish_step
op_scf:
    mov al,[gb_f]
    and al,0x80
    mov byte [gb_f],0x10
    or [gb_f],al
    mov dword [instr_cycles],4
    jmp cpu_finish_step
op_ccf:
    mov al,[gb_f]
    mov bl,al
    and al,0x80
    mov byte [gb_f],0
    or [gb_f],al
    test bl,0x10
    jnz .was_c
    or byte [gb_f],0x10
.was_c:
    mov dword [instr_cycles],4
    jmp cpu_finish_step

; ---------- CB execute: r12d = CB opcode ----------
cb_execute:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    mov r13d,r12d
    and r13d,7
    mov r14d,r12d
    shr r14d,6
    and r14d,3
    mov rdi,r13
    call get_r
    movzx ebx,al
    cmp r14d,0
    je .shifts
    cmp r14d,1
    je .bitop
    cmp r14d,2
    je .resop
    ; SET
    mov eax,r12d
    shr eax,3
    and eax,7
    mov rcx,rax
    mov rdx,1
    shl rdx,cl
    or rbx,rdx
    jmp .store
.shifts:
    mov eax,r12d
    shr eax,3
    and eax,7
    ; 0 RLC 1 RRC 2 RL 3 RR 4 SLA 5 SRA 6 SWAP 7 SRL
    cmp eax,0
    je .rlc
    cmp eax,1
    je .rrc
    cmp eax,2
    je .rl
    cmp eax,3
    je .rr
    cmp eax,4
    je .sla
    cmp eax,5
    je .sra_h
    cmp eax,6
    je .swap
    ; SRL
    mov edx,ebx
    shr ebx,1
    and edx,1
    jmp .flags_shift
.rlc:
    mov edx,ebx
    shl ebx,1
    shr edx,7
    or ebx,edx
    jmp .flags_shift
.rrc:
    mov edx,ebx
    shr ebx,1
    and edx,1
    shl edx,7
    or ebx,edx
    jmp .flags_shift
.rl:
    mov edx,ebx
    shl ebx,1
    test byte [gb_f],0x10
    jz .rl_nc
    or ebx,1
.rl_nc:
    shr edx,7
    jmp .flags_shift
.rr:
    mov edx,ebx
    shr ebx,1
    test byte [gb_f],0x10
    jz .rr_nc
    or ebx,0x80
.rr_nc:
    and edx,1
    jmp .flags_shift
.sla:
    mov edx,ebx
    shl ebx,1
    shr edx,7
    jmp .flags_shift
.sra_h:
    mov r8d,ebx
    mov edx,ebx
    and edx,0x80
    shr ebx,1
    or ebx,edx
    mov edx,r8d
    and edx,1
    jmp .flags_shift
.swap:
    mov edx,ebx
    shr ebx,4
    shl edx,4
    or ebx,edx
    xor edx,edx
    mov byte [gb_f],0
    cmp ebx,0
    jne .swap_done
    or byte [gb_f],0x80
.swap_done:
    jmp .store
.flags_shift:
    and ebx,0xFF
    mov byte [gb_f],0
    cmp ebx,0
    jne .fs_nz
    or byte [gb_f],0x80
.fs_nz:
    test edx,edx
    jz .store
    or byte [gb_f],0x10
    jmp .store
.bitop:
    mov eax,r12d
    shr eax,3
    and eax,7
    mov rcx,rax
    mov edx,ebx
    shr edx,cl
    and edx,1
    mov al,[gb_f]
    and al,0x10
    mov byte [gb_f],0x20
    or [gb_f],al
    test edx,edx
    jnz .bit_done
    or byte [gb_f],0x80
.bit_done:
    jmp .nostore
.resop:
    mov eax,r12d
    shr eax,3
    and eax,7
    mov rcx,rax
    mov rdx,1
    shl rdx,cl
    not dl
    and rbx,rdx
.store:
    cmp r13d,6
    jne .store_nopre
    ; CB modify (HL): write at cycle 4 -> step 4 more before set_r
    mov edi,4
    call do_prestep
.store_nopre:
    mov rdi,r13
    movzx esi,bl
    call set_r
.nostore:
    ; decide cycles BEFORE popping r13 (pops restore caller's r13)
    ; BIT n,(HL) is 12 T-cycles; CB modifies/rotates (HL) are 16.
    mov eax,8
    cmp r13d,6
    jne .cb_cyc_ok
    mov eax,16
    cmp r14d,1
    jne .cb_cyc_ok
    mov eax,12
.cb_cyc_ok:
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    mov [instr_cycles],eax
.ret:
    ret
cb_xx:
    ret
op_xx:
    ret

; ---------- run loop ----------
run_emulator:
    push rbx
    push r12
    push r13
    push r14
    push r15
    ; terminal setup if not headless
    cmp byte [cli_headless],0
    jne .headless_input
    ; TCGETS
    mov rax,SYS_ioctl
    mov rdi,0
    mov rsi,TCGETS
    lea rdx,[saved_termios]
    syscall
    cmp rax,0
    jne .loop
    ; copy to raw, clear ICANON(0x2) ECHO(0x8) in lflag (offset: termios struct: c_iflag0,c_oflag4,c_cflag8,c_lflag12)
    lea rsi,[saved_termios]
    lea rdi,[termios_raw]
    mov rcx,64
.cpy: mov al,[rsi]
    mov [rdi],al
    inc rsi
    inc rdi
    loop .cpy
    and byte [termios_raw+12],~0x0A
    mov rax,SYS_ioctl
    mov rdi,0
    mov rsi,TCSETS
    lea rdx,[termios_raw]
    syscall
    ; nonblock stdin
    mov rax,SYS_fcntl
    mov rdi,0
    mov rsi,F_GETFL
    syscall
    or rax,O_NONBLOCK
    mov rcx,rax
    mov rax,SYS_fcntl
    mov rdi,0
    mov rsi,F_SETFL
    mov rdx,rcx
    syscall
    mov byte [stdin_nonblock],1
    lea rdi,[esc_hide]
    call prints0
    jmp .loop
.headless_input:
    ; still allow piped stdin input in headless mode (e.g. for tests)
    mov rax,SYS_fcntl
    mov rdi,0
    mov rsi,F_GETFL
    syscall
    cmp rax,0
    jl .loop
    or rax,O_NONBLOCK
    mov rcx,rax
    mov rax,SYS_fcntl
    mov rdi,0
    mov rsi,F_SETFL
    mov rdx,rcx
    syscall
    mov byte [stdin_nonblock],1
.loop:
    ; frame limit
    cmp qword [cli_frames],0
    je .frame_run
    mov rax,[frames_done]
    cmp rax,[cli_frames]
    jae .finished
.frame_run:
    xor r12,r12          ; cycles this frame (r12)
.frame_inner:
    cmp r12,70224
    jge .frame_done
    call cpu_step
    add r12,rax
    jmp .frame_inner
.frame_done:
    inc qword [frames_done]
    ; --exit-on-result: stop as soon as the ROM reports a final result
    ; at $A000 (signature DE B0 61 present, status no longer $80)
    cmp byte [cli_exitres],0
    je .after_result
    cmp dword [ram_banks],0
    je .after_result
    cmp byte [extram+1],0xDE
    jne .after_result
    cmp byte [extram+2],0xB0
    jne .after_result
    cmp byte [extram+3],0x61
    jne .after_result
    cmp byte [extram+0],0x80
    je .after_result
    jmp .finished
.after_result:
    call poll_input
    cmp byte [cli_headless],0
    jne .after_display
    call display_frame
    ; throttle ~16ms
    lea rdi,[timespec_16ms]
    xor rsi,rsi
    mov rax,SYS_nanosleep
    syscall
.after_display:
.check_quit:
    cmp byte [quit_flag_bss],0
    jne .finished
    jmp .loop
.finished:
    cmp qword [dump_path],0
    je .no_dump
    call dump_ppm
.no_dump:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
timespec_16ms: dq 0, 8000000

; ---------- poll keyboard (nonblocking read) ----------
; keys are momentary: cleared each frame, set from bytes read this frame
poll_input:
    ; Snapshot the selected P1 input lines before changing key state, so a
    ; key press can raise the joypad IRQ on its 1->0 edge.
    call read_p1
    and al,0x0F
    mov [p1_old],al
    mov byte [key_up],0
    mov byte [key_down],0
    mov byte [key_left],0
    mov byte [key_right],0
    mov byte [key_a],0
    mov byte [key_b],0
    mov byte [key_start],0
    mov byte [key_select],0
    cmp byte [stdin_nonblock],0
    je .edge
    push rbx
    push rcx
    push rdi
    push rsi
    push rdx
    mov rax,SYS_read
    mov rdi,0
    lea rsi,[readbuf]
    mov rdx,32
    syscall
    cmp rax,0
    jle .out
    mov rcx,rax
    lea rsi,[readbuf]
.i: mov al,[rsi]
    cmp al,27
    je .esc_seq
    cmp al,'w'
    je .kup
    cmp al,'W'
    je .kup
    cmp al,'s'
    je .kdown
    cmp al,'S'
    je .kdown
    cmp al,'a'
    je .kleft
    cmp al,'A'
    je .kleft
    cmp al,'d'
    je .kright
    cmp al,'D'
    je .kright
    cmp al,'z'
    je .kb
    cmp al,'Z'
    je .kb
    cmp al,'x'
    je .ka
    cmp al,'X'
    je .ka
    cmp al,13
    je .kstart
    cmp al,10
    je .kstart
    cmp al,32
    je .kselect
    cmp al,'q'
    je .kquit
    cmp al,'Q'
    je .kquit
    jmp .next
.esc_seq:
    ; could be arrow: ESC [ A/B/C/D ; need next bytes in same read
    cmp rcx,3
    jl .kquit
    mov al,[rsi+2]
    cmp al,'A'
    je .kup
    cmp al,'B'
    je .kdown
    cmp al,'C'
    je .kright
    cmp al,'D'
    je .kleft
    jmp .next
.kquit: mov byte [quit_flag_bss],1
    jmp .next
.kup: mov byte [key_up],1
    jmp .next
.kdown: mov byte [key_down],1
    jmp .next
.kleft: mov byte [key_left],1
    jmp .next
.kright: mov byte [key_right],1
    jmp .next
.ka: mov byte [key_a],1
    jmp .next
.kb: mov byte [key_b],1
    jmp .next
.kstart: mov byte [key_start],1
    jmp .next
.kselect: mov byte [key_select],1
.next:
    inc rsi
    dec rcx
    jnz .i
.out:
    pop rdx
    pop rsi
    pop rdi
    pop rcx
    pop rbx
.edge:
    call read_p1
    and al,0x0F
    mov dl,[p1_old]
    not al
    and dl,al
    jz .d
    mov rdi,16
    call request_irq
.d: ret

; ---------- display frame to terminal (half-block, RLE per row pair) ----------
display_frame:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    lea rdi,[esc_home]
    call prints0
    mov r12,0              ; y pair 0..71 (pixel y = r12*2)
.row:
    cmp r12,72
    jge .done
    mov r13,0              ; x 0..159
    ; we emit per run: track current colors in scratch run state
    ; simpler: emit escape per pixel change using outbuf builder
    mov qword [out_len],0
.col:
    cmp r13,160
    jge .flush_row
    ; top pixel index = r12*2, bottom = +1
    mov rax,r12
    shl rax,1
    imul rax,160
    add rax,r13
    imul rax,3
    lea rsi,[framebuf]
    add rsi,rax
    mov r14d,[rsi]         ; top RGB (3 bytes, 4th garbage? use bytes individually below)
    ; bottom
    mov rax,r12
    shl rax,1
    inc rax
    imul rax,160
    add rax,r13
    imul rax,3
    lea rsi,[framebuf]
    add rsi,rax
    ; compare with previous emitted colors stored in run_top/run_bot
    ; if first pixel or changed, emit ESC[48;2;..m ESC[38;2;..m
    cmp r13,0
    je .emit_col
    ; load colors
    mov rax,r12
    shl rax,1
    imul rax,160
    add rax,r13
    imul rax,3
    lea rsi,[framebuf]
    add rsi,rax
    movzx ebx,byte [rsi]
    movzx ecx,byte [rsi+1]
    movzx edx,byte [rsi+2]
    cmp ebx,[run_bot+0]
    jne .emit_col
    cmp ecx,[run_bot+1]
    jne .emit_col
    cmp edx,[run_bot+2]
    jne .emit_col
    mov rax,r12
    shl rax,1
    imul rax,160
    add rax,r13
    imul rax,3
    lea rsi,[framebuf]
    add rsi,rax
    movzx ebx,byte [rsi]
    movzx ecx,byte [rsi+1]
    movzx edx,byte [rsi+2]
    cmp ebx,[run_top+0]
    jne .emit_col
    cmp ecx,[run_top+1]
    jne .emit_col
    cmp edx,[run_top+2]
    jne .emit_col
    jmp .just_block
.emit_col:
    ; save colors, emit escapes into outbuf
    mov rax,r12
    shl rax,1
    imul rax,160
    add rax,r13
    imul rax,3
    lea rsi,[framebuf]
    add rsi,rax
    movzx ebx,byte [rsi]
    mov [run_top],bl
    movzx ecx,byte [rsi+1]
    mov [run_top+1],cl
    movzx edx,byte [rsi+2]
    mov [run_top+2],dl
    mov rax,r12
    shl rax,1
    inc rax
    imul rax,160
    add rax,r13
    imul rax,3
    lea rsi,[framebuf]
    add rsi,rax
    movzx ebx,byte [rsi]
    mov [run_bot],bl
    movzx ecx,byte [rsi+1]
    mov [run_bot+1],cl
    movzx edx,byte [rsi+2]
    mov [run_bot+2],dl
    ; build ESC[48;2;R;G;Bm ESC[38;2;R;G;Bm into outbuf via append helpers
    ; background = top, foreground = bottom
    mov rdi,outbuf
    add rdi,[out_len]
    mov byte [rdi],27
    mov byte [rdi+1],'['
    mov byte [rdi+2],'4'
    mov byte [rdi+3],'8'
    mov byte [rdi+4],';'
    mov byte [rdi+5],'2'
    mov byte [rdi+6],';'
    add rdi,7
    movzx rax,byte [run_top]
    call append_u8
    mov byte [rdi],';'
    inc rdi
    movzx rax,byte [run_top+1]
    call append_u8
    mov byte [rdi],';'
    inc rdi
    movzx rax,byte [run_top+2]
    call append_u8
    mov byte [rdi],'m'
    inc rdi
    mov qword [out_len],rdi
    sub qword [out_len],outbuf
    ; foreground
    mov rdi,outbuf
    add rdi,[out_len]
    mov byte [rdi],27
    mov byte [rdi+1],'['
    mov byte [rdi+2],'3'
    mov byte [rdi+3],'8'
    mov byte [rdi+4],';'
    mov byte [rdi+5],'2'
    mov byte [rdi+6],';'
    add rdi,7
    movzx rax,byte [run_bot]
    call append_u8
    mov byte [rdi],';'
    inc rdi
    movzx rax,byte [run_bot+1]
    call append_u8
    mov byte [rdi],';'
    inc rdi
    movzx rax,byte [run_bot+2]
    call append_u8
    mov byte [rdi],'m'
    inc rdi
    mov qword [out_len],rdi
    sub qword [out_len],outbuf
.just_block:
    mov rdi,outbuf
    add rdi,[out_len]
    mov byte [rdi],0xE2
    mov byte [rdi+1],0x96
    mov byte [rdi+2],0x80
    add rdi,3
    mov qword [out_len],rdi
    sub qword [out_len],outbuf
    inc r13
    jmp .col
.flush_row:
    mov rdi,1
    lea rsi,[outbuf]
    mov rdx,[out_len]
    call write_all
    lea rdi,[esc_reset]
    call prints0
    lea rdi,[crlf]
    mov rsi,2
    call print_mem
    inc r12
    jmp .row
.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret
crlf: db 13,10
append_u8:
    push rax
    push rcx
    push rdx
    push rbx
    mov rbx,rax
    cmp rax,100
    jb .lt100
    mov rax,rbx
    xor rdx,rdx
    mov rcx,100
    div rcx
    push rdx
    add al,'0'
    mov [rdi],al
    inc rdi
    pop rax
    mov rcx,10
    xor rdx,rdx
    div rcx
    add al,'0'
    mov [rdi],al
    inc rdi
    mov rax,rdx
    add al,'0'
    mov [rdi],al
    inc rdi
    jmp .d
.lt100:
    cmp rax,10
    jb .lt10
    mov rax,rbx
    xor rdx,rdx
    mov rcx,10
    div rcx
    add al,'0'
    mov [rdi],al
    inc rdi
    mov rax,rdx
    add al,'0'
    mov [rdi],al
    inc rdi
    jmp .d
.lt10:
    mov rax,rbx
    add al,'0'
    mov [rdi],al
    inc rdi
.d: pop rbx
    pop rdx
    pop rcx
    pop rax
    ret

; ---------- PPM dump ----------
dump_ppm:
    push rbx
    push r12
    push r13
    mov rax,SYS_open
    mov rdi,[dump_path]
    mov rsi,O_WRONLY|O_CREAT|O_TRUNC
    mov rdx,0644o
    syscall
    cmp rax,0
    jl .d
    mov r12,rax
    mov rdi,r12
    lea rsi,[ppm_hdr]
    mov rdx,15
    call write_all
    mov rdi,r12
    lea rsi,[framebuf]
    mov rdx,160*144*3
    call write_all
    mov rax,SYS_close
    mov rdi,r12
    syscall
.d: pop r13
    pop r12
    pop rbx
    ret
ppm_hdr: db "P6",10,"160 144",10,"255",10

section .bss
out_len: resq 1
run_top: resb 3
run_bot: resb 3
quit_flag_bss: resb 1
section .text
; quit_flag alias: we referenced [quit_flag_bss] in poll/run - it was defined in .text; redirect by equ? Instead patch references via python after.
; ---------- APU ----------
; Register read masks for NR10..NR52: bits that always read as 1.
apu_rdmask:
    db 0x80,0x3F,0x00,0xFF,0xBF
    db 0xFF,0x3F,0x00,0xFF,0xBF
    db 0x7F,0xFF,0x9F,0xFF,0xBF
    db 0xFF,0xFF,0x00,0x00,0xBF
    db 0x00,0x00,0x70
    db 0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF
duty_tbl: db 0x01,0x81,0x87,0x7E

; apu_init: set DMG post-boot APU state from the initial register values
apu_init:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    mov byte [apu_power],1
    mov byte [apu_fs_step],0
    mov byte [apu_wave_flag],0
    ; frame sequencer phase: one step per 13-bit wrap of the DIV counter
    mov eax,[div_counter]
    and eax,0x1FFF
    mov [apu_fs_cyc],eax
    ; post-boot length-enable bits from NR14/NR24/NR34/NR44
    mov al,[io+0x14]
    shr al,6
    and al,1
    mov [apu_lenen+0],al
    mov al,[io+0x19]
    shr al,6
    and al,1
    mov [apu_lenen+1],al
    mov al,[io+0x1E]
    shr al,6
    and al,1
    mov [apu_lenen+2],al
    mov al,[io+0x23]
    shr al,6
    and al,1
    mov [apu_lenen+3],al
    ; length counters: NRx1 load values (max - value)
    movzx eax,byte [io+0x11]
    and eax,0x3F
    mov ecx,64
    sub ecx,eax
    mov [apu_len+0],cx
    movzx eax,byte [io+0x16]
    and eax,0x3F
    mov ecx,64
    sub ecx,eax
    mov [apu_len+2],cx
    movzx eax,byte [io+0x1B]
    mov ecx,256
    sub ecx,eax
    mov [apu_len+4],cx
    movzx eax,byte [io+0x20]
    and eax,0x3F
    mov ecx,64
    sub ecx,eax
    mov [apu_len+6],cx
    ; DACs
    mov al,[io+0x12]
    test al,0xF8
    setnz al
    mov [apu_dac+0],al
    mov al,[io+0x17]
    test al,0xF8
    setnz al
    mov [apu_dac+1],al
    mov al,[io+0x1A]
    shr al,7
    mov [apu_dac+2],al
    mov al,[io+0x21]
    test al,0xF8
    setnz al
    mov [apu_dac+3],al
    ; volumes / envelope config
    mov al,[io+0x12]
    mov dl,al
    shr al,4
    mov [apu_vol+0],al
    mov al,dl
    shr al,3
    and al,1
    mov [apu_envdir+0],al
    mov al,dl
    and al,7
    mov [apu_envper+0],al
    mov al,[io+0x17]
    mov dl,al
    shr al,4
    mov [apu_vol+1],al
    mov al,dl
    shr al,3
    and al,1
    mov [apu_envdir+1],al
    mov al,dl
    and al,7
    mov [apu_envper+1],al
    mov al,[io+0x21]
    mov dl,al
    shr al,4
    mov [apu_vol+3],al
    mov al,dl
    shr al,3
    and al,1
    mov [apu_envdir+3],al
    mov al,dl
    and al,7
    mov [apu_envper+3],al
    ; sweep config from NR10
    mov al,[io+0x10]
    mov dl,al
    shr al,4
    and al,7
    mov [apu_sweepper],al
    mov al,dl
    shr al,3
    and al,1
    mov [apu_sweepdir],al
    mov al,dl
    and al,7
    mov [apu_sweepshift],al
    mov byte [apu_sweepenable],0
    mov byte [apu_sweepneg],0
    ; channel 1 is active after boot (NR52 = $F1)
    mov byte [apu_active+0],1
    mov word [apu_lfsr],0x7FFF
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; apu_io_read: rdi = io offset (0x10..0x3F) -> rax
apu_io_read:
    push rbx
    push rcx
    push rdx
    push rdi
    lea rbx,[io]
    cmp rdi,0x26
    je .nr52
    cmp rdi,0x30
    jae .wave
    cmp rdi,0x27
    jb .normal
    mov eax,0xFF
    jmp .out
.normal:
    movzx eax,byte [rbx+rdi]
    lea rcx,[apu_rdmask]
    movzx edx,byte [rcx+rdi-0x10]
    or eax,edx
    jmp .out
.nr52:
    movzx eax,byte [apu_power]
    shl eax,7
    or eax,0x70
    ; apu_active holds one byte per channel, so fold the four flags into
    ; NR52 bits 0..3 individually (a dword load and low-nibble mask would
    ; expose channel 1 only)
    movzx edx,byte [apu_active+0]
    movzx ecx,byte [apu_active+1]
    shl ecx,1
    or edx,ecx
    movzx ecx,byte [apu_active+2]
    shl ecx,2
    or edx,ecx
    movzx ecx,byte [apu_active+3]
    shl ecx,3
    or edx,ecx
    and edx,0x0F
    or eax,edx
    jmp .out
.wave:
    ; DMG: while ch3 is active only the byte currently being fetched is
    ; visible, and only on the cycle the fetch happens; else $FF.
    cmp byte [apu_active+2],0
    je .wave_plain
    cmp byte [apu_wave_flag],0
    je .wave_ff
    movzx ecx,byte [apu_dutypos+2]
    shr ecx,1
    movzx eax,byte [rbx+rcx+0x30]
    jmp .out
.wave_ff:
    mov eax,0xFF
    jmp .out
.wave_plain:
    movzx eax,byte [rbx+rdi]
.out:
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; apu_io_write: rax = io offset (0x10..0x3F), rdx = value
apu_io_write:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    mov r13,rax
    mov r14b,dl
    cmp r13,0x30
    jae .wave
    cmp r13,0x26
    je .nr52
    cmp byte [apu_power],0
    jne .powered
    ; DMG: while off, NRx1 still loads the length counter (the register
    ; value itself is not stored). Every other register write is ignored.
    cmp r13,0x11
    je .off_len
    cmp r13,0x16
    je .off_len
    cmp r13,0x1B
    je .off_len
    cmp r13,0x20
    jne .done
.off_len:
    mov rax,r13
    sub rax,0x10
    xor edx,edx
    mov ecx,5
    div ecx
    mov r12,rax
    cmp r12d,2
    je .off_len_wave
    movzx eax,r14b
    and eax,0x3F
    mov ecx,64
    sub ecx,eax
    mov [apu_len+r12*2],cx
    jmp .done
.off_len_wave:
    movzx eax,r14b
    mov ecx,256
    sub ecx,eax
    mov [apu_len+r12*2],cx
    jmp .done
.powered:
    ; 0x27-0x2F are unmapped; do not run them through the channel index math.
    cmp r13,0x27
    jb .apu_map
    cmp r13,0x30
    jb .done
.apu_map:
    mov rax,r13
    sub rax,0x10
    xor edx,edx
    mov ecx,5
    div ecx
    mov r12,rax              ; channel 0..3
    mov r15,rdx              ; register index 0..4
    lea rbx,[io]
    mov [rbx+r13],r14b
    cmp r15d,0
    je .reg0
    cmp r15d,1
    je .reg1
    cmp r15d,2
    je .reg2
    cmp r15d,3
    je .reg3
    jmp .reg4
.reg0:
    cmp r12d,0
    jne .reg0_ch3
    ; NR10: sweep period/dir/shift + negate-mode quirk
    mov al,r14b
    shr al,3
    and al,1
    mov dl,[apu_sweepdir]
    mov [apu_sweepdir],al
    test dl,dl
    jz .nr10_store
    test al,al
    jnz .nr10_store
    cmp byte [apu_sweepneg],0
    je .nr10_store
    mov byte [apu_active],0
.nr10_store:
    mov al,r14b
    shr al,4
    and al,7
    mov [apu_sweepper],al
    mov al,r14b
    and al,7
    mov [apu_sweepshift],al
    ; the sweep enable is latched at trigger (period!=0 or shift!=0); an
    ; NR10 write does not change it, so a trigger with period=0 and
    ; shift=0 leaves the unit disabled until the next trigger.
    ; While enabled, a write with shift!=0 recalculates immediately from
    ; the frequency registers, not from the already-swept shadow.
    cmp byte [apu_sweepenable],0
    je .done
    cmp byte [apu_sweepper],0
    je .done
    cmp byte [apu_sweepshift],0
    je .done
    mov ax,[apu_freq]
    mov [apu_shadow],ax
    call apu_sweep_calc
    jmp .done
.reg0_ch3:
    ; NR30: wave DAC
    test r14b,0x80
    jz .nr30_off
    mov byte [apu_dac+2],1
    jmp .done
.nr30_off:
    mov byte [apu_dac+2],0
    mov byte [apu_active+2],0
    jmp .done
.reg1:
    ; length load
    cmp r12d,2
    je .len_wave
    movzx eax,r14b
    and eax,0x3F
    mov ecx,64
    jmp .len_set
.len_wave:
    movzx eax,r14b
    mov ecx,256
.len_set:
    sub ecx,eax
    mov [apu_len+r12*2],cx
    mov byte [apu_frozen+r12],0
    jmp .done
.reg2:
    cmp r12d,2
    je .done                 ; NR32: output level, no DAC change
    mov al,r14b
    test al,0xF8
    jz .dac_off
    mov byte [apu_dac+r12],1
    jmp .done
.dac_off:
    mov byte [apu_dac+r12],0
    mov byte [apu_active+r12],0
    jmp .done
.reg3:
    cmp r12d,3
    je .done                 ; NR43 stored only
    movzx eax,word [apu_freq+r12*2]
    and eax,0x700
    movzx edx,r14b
    or eax,edx
    mov [apu_freq+r12*2],ax
    jmp .done
.reg4:
    cmp r12d,3
    je .reg4_freq_done
    movzx eax,word [apu_freq+r12*2]
    and eax,0xFF
    movzx edx,r14b
    and edx,7
    shl edx,8
    or eax,edx
    mov [apu_freq+r12*2],ax
.reg4_freq_done:
    ; DMG length-enable semantics, in hardware order:
    ;  1. a 0->1 enable edge clocks the length once when the next DIV-APU
    ;     step does not clock length (fs_step odd) and the length is
    ;     non-zero; if that makes it zero and no trigger follows, the
    ;     channel is disabled and the counter frozen;
    ;  2. a trigger then unfreezes a zero length and reloads it to
    ;     maximum, except when the length is enabled by the same write
    ;     and the next step does not clock length, in which case the
    ;     reload lands one short (max-1).
    movzx r15d,byte [apu_lenen+r12]     ; previous enable state
    movzx ebx,word [apu_len+r12*2]      ; previous length
    test r14b,0x40
    jz .reg4_after_en
    test r15d,r15d
    jnz .reg4_after_en
    test ebx,ebx
    jz .reg4_after_en
    test byte [apu_fs_step],1
    jz .reg4_after_en
    dec ebx
    mov [apu_len+r12*2],bx
    test ebx,ebx
    jnz .reg4_after_en
    test r14b,0x80
    jnz .reg4_after_en                 ; trigger unfreezes it instead
    mov byte [apu_active+r12],0
    mov byte [apu_frozen+r12],1
.reg4_after_en:
    test r14b,0x80
    jz .reg4_set_len
    mov rdi,r12
    call apu_trigger
    test ebx,ebx                       ; did the trigger reload a zero?
    jnz .reg4_set_len
    test r14b,0x40
    jz .reg4_set_len
    test byte [apu_fs_step],1
    jz .reg4_set_len
    dec word [apu_len+r12*2]
.reg4_set_len:
    test r14b,0x40
    jz .reg4_dis_len
    mov byte [apu_lenen+r12],1
    jmp .done
.reg4_dis_len:
    mov byte [apu_lenen+r12],0
    jmp .done
.wave:
    ; DMG: while ch3 is active only the byte being fetched is visible, and
    ; only on a fetch cycle; other CPU accesses are ignored.
    cmp byte [apu_active+2],0
    je .wave_store
    cmp byte [apu_wave_flag],0
    je .done
    lea rbx,[io]
    movzx eax,byte [apu_dutypos+2]
    shr eax,1
    mov [rbx+rax+0x30],r14b
    jmp .done
.wave_store:
    lea rbx,[io]
    mov [rbx+r13],r14b
    jmp .done
.nr52:
    test r14b,0x80
    jz .nr52_off
    cmp byte [apu_power],0
    jne .done
    mov byte [apu_power],1
    mov byte [apu_fs_step],0
    mov dword [apu_fs_cyc],0
    jmp .done
.nr52_off:
    cmp byte [apu_power],0
    je .done
    mov byte [apu_power],0
    mov byte [apu_fs_step],0
    mov byte [apu_wave_flag],0
    ; zero NR10..NR51 and all channel state
    lea rbx,[io]
    xor ecx,ecx
.nr52_zero:
    mov byte [rbx+0x10+rcx],0
    inc ecx
    cmp ecx,0x16
    jb .nr52_zero
    mov dword [apu_active],0
    mov dword [apu_dac],0
    mov dword [apu_lenen],0
    mov dword [apu_frozen],0
    mov dword [apu_vol],0
    mov dword [apu_envper],0
    mov dword [apu_envdir],0
    mov dword [apu_envtimer],0
    mov dword [apu_freq+0],0
    mov dword [apu_freq+4],0
    mov dword [apu_timer+0],0
    mov dword [apu_timer+4],0
    mov dword [apu_timer+8],0
    mov dword [apu_timer+12],0
    mov byte [apu_sweepper],0
    mov byte [apu_sweepdir],0
    mov byte [apu_sweepshift],0
    mov byte [apu_sweepenable],0
    mov byte [apu_sweepneg],0
    mov byte [apu_dutypos+0],0
    mov byte [apu_dutypos+1],0
    mov byte [apu_dutypos+2],0
    mov byte [apu_dutypos+3],0
.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; apu_trigger: rdi = channel 0..3
apu_trigger:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13
    mov r12,rdi
    mov r13b,[apu_active+r12]
    ; length: 0 becomes maximum (any extra clock is applied by the
    ; caller's 0->1 enable path, as on hardware)
    movzx eax,word [apu_len+r12*2]
    test eax,eax
    jnz .trig_len_done
    mov ecx,64
    cmp r12d,2
    jne .trig_max
    mov ecx,256
.trig_max:
    mov [apu_len+r12*2],cx
.trig_len_done:
    mov byte [apu_frozen+r12],0
    ; wave: DMG corrupts wave RAM when retriggered while the fetch timer
    ; is 2 cycles from expiring
    cmp r12d,2
    jne .trig_dac
    test r13b,r13b
    jz .trig_dac
    cmp byte [apu_dac+2],0
    je .trig_dac
    cmp dword [apu_timer+8],2
    jne .trig_dac
    call apu_wave_corrupt
.trig_dac:
    ; channel becomes active if its DAC is on
    cmp byte [apu_dac+r12],0
    je .trig_dac_done
    mov byte [apu_active+r12],1
.trig_dac_done:
    ; envelope / volume (square and noise channels only)
    cmp r12d,2
    je .trig_ch3
    mov rax,r12
    imul rax,5
    lea rbx,[io]
    movzx edx,byte [rbx+0x12+rax]
    mov al,dl
    shr al,4
    mov [apu_vol+r12],al
    mov al,dl
    shr al,3
    and al,1
    mov [apu_envdir+r12],al
    mov al,dl
    and al,7
    mov [apu_envper+r12],al
    test al,al
    jnz .trig_envt
    mov al,8
.trig_envt:
    mov [apu_envtimer+r12],al
.trig_ch3:
    call apu_reload_timer
    cmp r12d,2
    jne .trig_sweep
    mov byte [apu_dutypos+2],0
    add dword [apu_timer+8],6
.trig_sweep:
    test r12d,r12d
    jnz .trig_done
    call apu_sweep_trigger
.trig_done:
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; apu_wave_corrupt: DMG wave-RAM corruption on a retrigger while the
; fetch timer is 2 cycles from expiring: the current 4-byte block is
; copied to the start of wave RAM.
apu_wave_corrupt:
    push rbx
    push rcx
    push rdx
    lea rbx,[io+0x30]
    movzx eax,byte [apu_dutypos+2]
    inc eax
    shr eax,1
    and eax,0x0F
    cmp eax,4
    jae .block
    mov dl,[rbx+rax]
    mov [rbx],dl
    jmp .done
.block:
    and eax,0x0C
    mov ecx,[rbx+rax]
    mov [rbx],ecx
.done:
    pop rdx
    pop rcx
    pop rbx
    ret

; apu_reload_timer: r12 = channel; reload its sample timer
apu_reload_timer:
    push rbx
    push rcx
    push rdx
    push rsi
    push rax
    mov rax,r12
    shl rax,2
    lea rbx,[apu_timer]
    cmp r12d,3
    je .noise
    movzx edx,word [apu_freq+r12*2]
    mov ecx,2048
    sub ecx,edx
    cmp r12d,2
    je .wave
    shl ecx,2
    mov [rbx+rax],ecx
    jmp .done
.wave:
    shl ecx,1
    mov [rbx+rax],ecx
    jmp .done
.noise:
    lea rsi,[io]
    movzx ecx,byte [rsi+0x22]
    mov edx,ecx
    and edx,7
    shr ecx,4
    test edx,edx
    jnz .nz
    mov edx,8
    jmp .nz2
.nz:
    shl edx,4
.nz2:
    shl edx,cl
    mov [rbx+rax],edx
.done:
    pop rax
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; apu_sweep_trigger: reload shadow frequency, timer and enable flag, then
; perform the trigger-time calculation
apu_sweep_trigger:
    push rbx
    push rcx
    push rdx
    push rax
    movzx eax,word [apu_freq]
    mov [apu_shadow],ax
    movzx ecx,byte [apu_sweepper]
    test ecx,ecx
    jnz .st_timer
    mov ecx,8
.st_timer:
    mov [apu_sweeptimer],cl
    mov byte [apu_sweepneg],0
    mov al,[apu_sweepper]
    or al,[apu_sweepshift]
    jz .st_off
    mov byte [apu_sweepenable],1
    jmp .st_calc
.st_off:
    mov byte [apu_sweepenable],0
.st_calc:
    cmp byte [apu_sweepshift],0
    je .st_done
    call apu_sweep_calc
.st_done:
    pop rax
    pop rdx
    pop rcx
    pop rbx
    ret

; apu_sweep_calc: compute new frequency; disable channel on overflow
apu_sweep_calc:
    push rbx
    push rcx
    push rdx
    push rsi
    push rax
    movzx eax,word [apu_shadow]
    movzx ecx,byte [apu_sweepshift]
    mov edx,eax
    shr edx,cl
    cmp byte [apu_sweepdir],0
    je .add
    ; negate mode
    sub eax,edx
    mov dl,[apu_sweepneg]
    mov byte [apu_sweepneg],1
    test dl,dl
    jnz .no_ovf
    jmp .check
.add:
    add eax,edx
    mov byte [apu_sweepneg],0
.check:
    cmp eax,0x7FF
    ja .overflow
.no_ovf:
    cmp byte [apu_sweepshift],0
    je .done
    mov [apu_shadow],ax
    jmp .done
.overflow:
    mov byte [apu_active],0
.done:
    pop rax
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; apu_clock_length: 256 Hz length clock
apu_clock_length:
    cmp byte [apu_power],0
    je .off
    push rbx
    push rcx
    push rdx
    push r12
    xor r12d,r12d
.loop:
    cmp byte [apu_lenen+r12],0
    je .next
    cmp byte [apu_frozen+r12],0
    jne .next
    movzx eax,word [apu_len+r12*2]
    test eax,eax
    jz .next
    dec eax
    mov [apu_len+r12*2],ax
    test eax,eax
    jnz .next
    mov byte [apu_active+r12],0
    mov byte [apu_frozen+r12],1
.next:
    inc r12d
    cmp r12d,4
    jb .loop
    pop r12
    pop rdx
    pop rcx
    pop rbx
.off:
    ret

; apu_clock_env: 64 Hz volume envelope clock
apu_clock_env:
    cmp byte [apu_power],0
    je .off
    push rbx
    push rcx
    push rdx
    push r12
    xor r12d,r12d
.loop:
    cmp r12d,2
    je .next
    cmp byte [apu_active+r12],0
    je .next
    cmp byte [apu_envper+r12],0
    je .next
    dec byte [apu_envtimer+r12]
    jnz .next
    mov al,[apu_envper+r12]
    mov [apu_envtimer+r12],al
    cmp byte [apu_envdir+r12],0
    jne .up
    cmp byte [apu_vol+r12],0
    je .next
    dec byte [apu_vol+r12]
    jmp .next
.up:
    cmp byte [apu_vol+r12],15
    jae .next
    inc byte [apu_vol+r12]
.next:
    inc r12d
    cmp r12d,4
    jb .loop
    pop r12
    pop rdx
    pop rcx
    pop rbx
.off:
    ret

; apu_clock_sweep: 128 Hz sweep clock
apu_clock_sweep:
    cmp byte [apu_power],0
    je .ret
    cmp byte [apu_sweepenable],0
    je .ret
    dec byte [apu_sweeptimer]
    jnz .ret
    mov al,[apu_sweepper]
    test al,al
    jnz .reload
    mov al,8
.reload:
    mov [apu_sweeptimer],al
    cmp byte [apu_sweepper],0
    je .ret
    ; the sweep calculation only moves the private shadow value; the
    ; frequency registers are updated when the timer reloads (period != 0)
    mov ax,[apu_shadow]
    mov [apu_freq],ax
    call apu_sweep_calc
.ret:
    ret

; apu_step: rdi = elapsed T-cycles
apu_step:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    mov r14,rdi
    mov byte [apu_wave_flag],0
    cmp byte [apu_power],0
    je .off_done
    ; channel sample timers
    xor r12d,r12d
.tim_loop:
    mov eax,[apu_timer+r12*4]
    test eax,eax
    jz .tim_next
    sub eax,r14d
    cmp eax,0
    jg .tim_store
    cmp r12d,2
    je .tim_wave
    cmp r12d,3
    je .tim_noise
.tim_sq_exp:
    inc byte [apu_dutypos+r12]
    and byte [apu_dutypos+r12],7
    call apu_reload_timer
    mov edx,[apu_timer+r12*4]
    add eax,edx
    cmp eax,0
    jle .tim_sq_exp
    mov [apu_timer+r12*4],eax
    jmp .tim_next
.tim_wave:
    cmp byte [apu_active+2],0
    je .tim_wave_off
    cmp byte [apu_dac+2],0
    je .tim_wave_off
.tim_wave_exp:
    inc byte [apu_dutypos+2]
    and byte [apu_dutypos+2],31
    call apu_reload_timer
    mov edx,[apu_timer+r12*4]
    add eax,edx
    cmp eax,0
    jle .tim_wave_exp
    ; DMG exposes a wave byte only when the access lands exactly on a
    ; fetch boundary; preserve that edge condition from the cycle model.
    cmp eax,edx
    jne .tim_wave_store
    mov byte [apu_wave_flag],1
.tim_wave_store:
    mov [apu_timer+r12*4],eax
    jmp .tim_next
.tim_wave_off:
    mov dword [apu_timer+r12*4],0
    jmp .tim_next
.tim_noise:
.tim_noise_exp:
    movzx ecx,word [apu_lfsr]
    mov edx,ecx
    and edx,1
    shr ecx,1
    xor ecx,edx
    test byte [io+0x22],0x08
    jz .noise_15
    and ecx,0x7F
    jmp .noise_store
.noise_15:
    and ecx,0x7FFF
.noise_store:
    mov [apu_lfsr],cx
    call apu_reload_timer
    mov edx,[apu_timer+r12*4]
    add eax,edx
    cmp eax,0
    jle .tim_noise_exp
    mov [apu_timer+r12*4],eax
    jmp .tim_next
.tim_store:
    mov [apu_timer+r12*4],eax
.tim_next:
    inc r12d
    cmp r12d,4
    jb .tim_loop
.fs_start:
    ; frame sequencer: one step per 13-bit wrap of the DIV counter
    add [apu_fs_cyc],r14d
.fs_loop:
    cmp dword [apu_fs_cyc],8192
    jb .audio_tick
    sub dword [apu_fs_cyc],8192
    mov al,[apu_fs_step]
    cmp al,7
    je .fs_env
    test al,1
    jnz .fs_advance
    call apu_clock_length
    mov al,[apu_fs_step]
    cmp al,2
    je .fs_sweep
    cmp al,6
    je .fs_sweep
    jmp .fs_advance
.fs_sweep:
    call apu_clock_sweep
    jmp .fs_advance
.fs_env:
    call apu_clock_env
    jmp .fs_advance
.fs_advance:
    mov al,[apu_fs_step]
    inc al
    and al,7
    mov [apu_fs_step],al
    jmp .fs_loop
.off_done:
    ; while NR52 bit 7 is clear the frame sequencer neither steps nor
    ; clocks anything; the phase is restarted by the power-on write.
    ; Audio sampling still runs so silence keeps the timeline continuous.
    jmp .audio_tick
.audio_tick:
    cmp byte [audio_enabled],0
    je .epilogue
    mov rax,r14
    imul rax,44100
    add [audio_accum],rax
.audio_loop:
    cmp qword [audio_accum],4194304
    jb .epilogue
    sub qword [audio_accum],4194304
    call audio_emit_sample
    jmp .audio_loop
.epilogue:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; audio_emit_sample: mix the current APU channel state into one 16-bit
; sample. Called from apu_step every time the 4.194304 MHz -> 44.1 kHz
; accumulator crosses a sample boundary, so channel progression is tracked
; per emulated cycle rather than once per video frame.
audio_emit_sample:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    xor r14d,r14d
    xor r13d,r13d
.sq:
    cmp r13d,2
    jge .wavech
    cmp byte [apu_active+r13],0
    je .sq_next
    cmp byte [apu_dac+r13],0
    je .sq_next
    mov rcx,r13
    imul rcx,5
    lea rbx,[io]
    movzx edx,byte [rbx+0x11+rcx]
    shr edx,6
    lea rsi,[duty_tbl]
    movzx edx,byte [rsi+rdx]
    movzx ecx,byte [apu_dutypos+r13]
    shr edx,cl
    movzx eax,byte [apu_vol+r13]
    imul eax,600
    test dl,1
    jz .sq_off
    add r14d,eax
    jmp .sq_next
.sq_off:
    sub r14d,eax
.sq_next:
    inc r13d
    jmp .sq
.wavech:
    cmp byte [apu_active+2],0
    je .noisech
    cmp byte [apu_dac+2],0
    je .noisech
    movzx eax,byte [io+0x1C]
    shr eax,5
    and eax,3
    test eax,eax
    jz .noisech
    movzx edx,byte [apu_dutypos+2]
    shr edx,1
    lea rbx,[io]
    movzx ecx,byte [rbx+0x30+rdx]
    test byte [apu_dutypos+2],1
    jz .w_hi
    and ecx,0x0F
    jmp .w_val
.w_hi:
    shr ecx,4
.w_val:
    cmp eax,1
    je .w_full
    cmp eax,2
    je .w_half
    sar ecx,2
    jmp .w_full
.w_half:
    sar ecx,1
.w_full:
    ; centre the 4-bit nibble (0..15) around zero
    shl ecx,6
    sub ecx,480
    add r14d,ecx
.noisech:
    cmp byte [apu_active+3],0
    je .mix
    cmp byte [apu_dac+3],0
    je .mix
    movzx eax,word [apu_lfsr]
    and eax,1
    jz .n_off
    add r14d,800
    jmp .mix
.n_off:
    sub r14d,800
.mix:
    cmp r14d,32767
    jle .clamp_lo
    mov r14d,32767
.clamp_lo:
    cmp r14d,-32768
    jge .clamp_ok
    mov r14d,-32768
.clamp_ok:
    lea rbx,[audio_buf]
    add rbx,[audio_buf_len]
    mov [rbx],r14w
    add qword [audio_buf_len],2
    cmp qword [audio_buf_len],16000
    jb .done
    call audio_flush
.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

audio_flush:
    push rbx
    push rdi
    push rsi
    push rdx
    cmp qword [audio_buf_len],0
    je .d
    cmp qword [audio_fd],0
    jl .clear
    mov rbx,[audio_buf_len]
    mov rdi,[audio_fd]
    lea rsi,[audio_buf]
    mov rdx,rbx
    call write_all
    add [audio_bytes],rbx
.clear:
    mov qword [audio_buf_len],0
.d: pop rdx
    pop rsi
    pop rdi
    pop rbx
    ret

; audio_finalize: flush PCM, patch the RIFF and data chunk sizes, close.
audio_finalize:
    push rbx
    push rdi
    push rsi
    push rdx
    cmp byte [audio_enabled],0
    je .d
    call audio_flush
    cmp qword [audio_fd],0
    jl .d
    mov eax,[audio_bytes]
    lea ecx,[eax+36]
    mov [wav_header+4],ecx
    mov [wav_header+40],eax
    mov rax,SYS_lseek
    mov rdi,[audio_fd]
    xor rsi,rsi
    xor rdx,rdx
    syscall
    mov rdi,[audio_fd]
    lea rsi,[wav_header]
    mov rdx,44
    call write_all
    mov rax,SYS_close
    mov rdi,[audio_fd]
    syscall
.d: pop rdx
    pop rsi
    pop rdi
    pop rbx
    ret

