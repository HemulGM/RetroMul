; NVM_BIOS
; Jaguar CD-ROM Non-volatile backup memory BIOS
; Copyright 1994,1995 Atari Corporation.
; All Rights Reserved
; Version 1.01
;
; ROMULATOR version
;
; This is the 2K module that gets loaded from
; the cartridge ROM into Jaguar RAM. The main
; dispatcher is found at the NVM_BIOS entry
; point.
;

	.include	"asmnvm.s"
.if 1
SECTORSIZE   = 16384
LOG2_SECTORSIZE = 14
.else
SECTORSIZE = 128
LOG2_SECTORSIZE = 7
.endif

_NVRAM == $900000

;
;****************************************************************
;* Here are the routines that talk directly to the		*
;* hardware. These are probably the only things that will	*
;* have to change if the hardware does. There are 3		*
;* functions:							*
;*								*
;* Getbyte(long addr): get 1 byte from NVRAM; "addr" is the	*
;*	location of the byte (relative to the start of NVRAM	*
;* Putbyte(char byte, long addr): put 1 byte into NVRAM, at	*
;*	the given address (relative to start of NVRAM).		*
;* FLUSH(): flush any output buffers. Doing single character	*
;*	writes would be prohibitively expensive for most FLASH	*
;*	ROMs, so we buffer output until either a new ROM sector	*
;*	is encountered, or the system call finishes.		*
;****************************************************************
;
; FLUSH: flush the cached sector to NV RAM
; Parameters: none
; Internal register usage:
; Preserves all registers
;
FLUSH:
	movem.l	d0-d7/a0-a4, -(sp)

	cmp.w	#-1, cache_sector(a5)		; check for cache empty
	beq	L2				; if cache is empty, return
	lea	_NVRAM,a2

	moveq.l	#0,d4				; make sure high word of d4 is 0
	move.w	cache_sector(a5), d4		; d4 = starting address within NVRAM
	moveq	#LOG2_SECTORSIZE, d0		
	asl.l	d0, d4
	move.l	scratchbuf(a5), a0		; a0 = source address
	lea	0(a2,d4.l),a1			; a1 = dest address
	move.w	#SECTORSIZE-1, d5		; d5 = sector size/counter for writing
L6:
	move.w	(a0)+, d0			; d0 = the byte to write
	move.w	d0, (a1)+

	moveq	#1,d0				; put in a delay to simulate a real flash rom board
.if 1
	divs	d0,d0
	divs	d0,d0
	divs	d0,d0
	divs	d0,d0
	divs	d0,d0
	divs	d0,d0
	divs	d0,d0
	divs	d0,d0
	divs	d0,d0
.endif

	subq.w	#2,d5
	bpl.b	L6

Lreturn:					; return
	move.w	#-1, cache_sector(a5)			; mark cache as clear
L2:
	movem.l	(sp)+, d0-d7/a0-a4
	rts
;
; Getbyte: fetch a byte from NV RAM
; Parameters:
;	a0.l	offset of the byte to fetch
; Internal register usage:
;	d1.l	sector number or offset
;	a1.l	buffer to use 
; ASSUMPTIONS: 256 < SECTORSIZE < 32768
; Registers destroyed: d0,d1,a1
; NOTE: a0 is preserved, so that it can be used
; in a loop
;
Getbyte:
	moveq.l	#LOG2_SECTORSIZE,d0		; makes sure high byte of d0.w is 0
	move.l	a0,d1
	lsr.l	d0,d1				; calculate the sector number
	cmp.w	cache_sector(a5),d1		; is this the currently cached sector?
	bne.b	.notcached			; if not, go read it directly
	move.l	a0,d1
	and.l	#SECTORSIZE-1,d1		; just use the offset into the buffer
	move.l	scratchbuf(a5),a1
	move.b	0(a1,d1.l),d0
	rts
.notcached:
	lea	_NVRAM,a1
	move.b	0(a1,a0.l),d0
	rts

;
; Putbyte: put a byte into NV RAM
; Parameters:
;	d0.b	byte to put into NV RAM
;	a0.l	address in NV RAM
; Internal register usage:
;	d1.w	sector number
;	d2.w	sector offset
;	d3.l	loop counter
;	a1.l	source address
;	a2.l	scratch buffer address

; Registers destroyed: d1/a1
; NOTE: a0 is preserved, so that it can be
; used in a loop.
; ASSUMPTIONS: 256 < SECTORSIZE < 32768
;
Putbyte:
	movem.l	d2-d3/a2,-(sp)
	move.l	scratchbuf(a5),a2
	move.l	a0,d1
	moveq.l	#LOG2_SECTORSIZE,d2
	lsr.l	d2,d1				; set d1 = sector number
	move.l	a0,d2
	and.l	#(SECTORSIZE-1),d2		; set d2 = sector offset
	cmp.w	cache_sector(a5),d1		; is this the currently cached sector?
	beq.b	.iscached
	movem.l	d0-d1/a0/a2,-(sp)			; push the scratch registers we care about
	bsr	FLUSH				; flush the cache (preserves a0)
	moveq.l	#LOG2_SECTORSIZE,d0
	lsl.l	d0,d1				; make d1 = base of its sector
	move.l	d1,a0				; start reading from the sector base
	; now fill the cache
	move.l	#SECTORSIZE-1,d3
.fill:
	bsr	Getbyte
	move.b	d0,(a2)+
	addq.l	#1,a0
	dbra	d3,.fill

	movem.l	(sp)+,d0-d1/a0/a2		; restore scratch registers
	move.w	d1,cache_sector(a5)		; set the cache sector
.iscached:
	move.b	d0,(a2,d2.l)
	movem.l	(sp)+,d2-d3/a2
	rts

	.end
