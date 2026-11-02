; NVM_BIOS
; Jaguar CD-ROM Non-volatile backup memory BIOS
; Copyright 1994,1995 Atari Corporation.
; All Rights Reserved
; Version 1.01
;
; Portions Copyright 2022, James Jones
; Released under the CC0-1.0 license.
;
; This is the 2K module that gets loaded from
; the cartridge ROM into Jaguar RAM. The main
; dispatcher is found at the NVM_BIOS entry
; point.
;
; The BIOS supports the following calls:
;
; NVM_Bios(0, char *appname, void *workarea):
;	Initialize BIOS. "appname" is the name of
;	the application (a pointer to a 0 terminated
;	string). "workarea" points to a 16K scratch
;	buffer that NVM_Bios functions can modify
;	as they please (this buffer need not be preserved
;	by the application between NVM_Bios calls).
;	This function must be called before any other
;	NVM_Bios function.
;
; NVM_Bios(1, char *filename, long filesize):
;	Create a file. "filename" is a pointer to a
;	0 terminated string giving the name of the
;	application. "filesize" gives the size of
;	the file (i.e. the amount of memory to
;	allocate) in bytes. Returns a file handle
;	which may be used for read/write/seek requests.
;
; NVM_Bios(2, char *filename):
;	Open a file. "filename" is a pointer to a 0
;	terminated string. Returns a file handle
;	which may be used for read/write/seek requests.
;
; NVM_Bios(3, int handle):
;	Close a file. "handle" is the 16 bit integer
;	returned by a previous Open or Create call.
;
; NVM_Bios(4, char *appname, char *filename):
;	Delete a file. "appname" is a pointer to the
;	name of the application which created the file;
;	"filename" is a pointer to the file's name. Both
;	are 0 terminated strings.
;
; NVM_Bios(5, int handle, void *bufptr, long count):
;	Read data from a file. "handle" is a handle returned
;	by a previous Open or Create call; "bufptr" points
;	to a buffer into which the data read is to be copied;
;	and "count" is the number of bytes to read. Returns
;	the number of bytes actually read (which may be
;	less than "count" if an attempt is made to read past
;	end of file).
;
; NVM_Bios(6, int handle, void *bufptr, long count):
;	Write data to a file. "handle" is a handle returned
;	by a previous Open or Create call; "bufptr" points
;	to a buffer containing the data to write;
;	and "count" is the number of bytes to write. Returns
;	the number of bytes actually written (which may be
;	less than "count" if an attempt is made to write past
;	end of file).
;
; NVM_Bios(7, void *search_buf, long search_flag):
;	Initialize directory search ("Search First").
;	"search_buf" should point to a word aligned 30 byte buffer.
;	If the search is successful, the first 4 bytes of this
;	buffer will be filled in with a long word giving the
;	total size of the file. The next 16 bytes will be filled
;	with a null terminated character string giving the name of 
;	the application that created the file; and the final 10
;	bytes will be filled with a null terminated string consisting
;	of the name the application gave to the file.  These two 
;	strings constitute the appname and filename parameters for
;	the Delete call. "search_flag" specifies whether the search
;	should include all files on the cartridge (if 0), or
;	just those files created by the current application (1).
;
; NVM_Bios(8, void *search_buf):
;	Continue directory search ("Search Next").
;	search_buf is as in Search First.
;
; NVM_Bios(9, int handle, long offset, int flag):
;	Seek to a position in a file. "handle" is
;	a file handle previously returned by Open or
;	Create. "offset" is the either the absolute
;	position in the file (if "flag" is 0) or
;	an offset relative to the current position (if
;	"flag" is 1). Returns the new absolute offset
;	in the file.
;
; NVM_Bios(10, long *totspc, long *freespc):
;	Inquire about cartridge memory. "totspc" points
;	to a long word which will be filled in with
;	the total amount of memory on the cartridge, and
;	"freespc" points to a long word which will be
;	filled in with the amount of free memory on the
;	cartridge. Both numbers are in bytes.
;

MAXOPCODE	=	10
	.include	"nvm.inc"
	.globl	_NVM_Bios

;
; Variable storage area (link this last!)
; For speed and space reasons, all variables
; are referenced off of a global pointer
; (a5)
	.bss
start_bss:
_gl_appname:				; current application name
	.ds.w	APPPACKSIZE
_alt_appname:
	.ds.w	APPPACKSIZE		; alternate application name (for deleting another app's files)
_gl_filename:				; usually: current file name
	.ds.w	FILEPACKSIZE

FHANDLESIZ	=	6
_file_handle:				; table of info for open files; for each file
	.ds.b	FHANDLESIZ*NUMFILES	; we have startblock(2 bytes) and current offset(4 bytes)

_scratchbuf:				; pointer to the user's 16K scratch buffer
	.ds.l	1
_cache_sector:				; index of currently cached sector
	.ds.w	1

_search_location:			; current location for search first/next
	.ds.w	1

_search_flags:				; search flags: 0 = all apps, 1 = only current app
	.ds.w	1

_cur_d:					; current directory entry during directory operations
_cur_d_startblock:			; starting block for file
	.ds.b	1
_cur_d_numblocks:			; number of blocks in file
	.ds.b	1
	.even
_cur_d_appname:				; name of application that created file
	.ds.w	APPPACKSIZE
_cur_d_filename:			; name of file
	.ds.w	FILEPACKSIZE

;
; equates for dereferencing variables
; relative to start_bss 
;
gl_appname	=	_gl_appname-start_bss
gl_filename	=	_gl_filename-start_bss
file_handle	=	_file_handle-start_bss
scratchbuf	=	_scratchbuf-start_bss
search_location	=	_search_location-start_bss
search_flags	=	_search_flags-start_bss
cache_sector	=	_cache_sector-start_bss
cur_d		=	_cur_d-start_bss
cur_d_startblock	=	_cur_d_startblock-start_bss
cur_d_numblocks	=	_cur_d_numblocks-start_bss
cur_d_appname	=	_cur_d_appname-start_bss
cur_d_filename	=	_cur_d_filename-start_bss
alt_appname	=	_alt_appname-start_bss

.macro ld_appn areg
	.assert gl_appname = $0
	movea.l	a5,\{areg}		; lea gl_appname(a5),<addr reg>
.endm

.macro ld_fato areg
	.assert FATOFFSET = $0
	suba.l	\{areg},\{areg}		; lea FATOFFSET.w,<addr reg>
.endm

	.text
;
; we must start with a magic cookie, followed by a
; dispatcher
;
	.dc.l	'_NVM'		; magic cookie
;------------------------------------------------------------
; main entry point and dispatcher
; All the functions expect the following things to be true:
; a5 points to start_bss
; a6 points to a stack frame, so 8(a6) points to the function
; 	opcode and 10(a6) points to the remaining arguments
; d7 contains the opcode for the current function
;
_NVM_Bios:
	link	a6,#0			; save a6 on the stack
	movem.l	d1-d7/a0-a5,-(sp)	; save registers
	lea	start_bss.w,a5	; initialize base register
	move.w	8(a6),d7		; get opcode
	bne.b	.notinit		; if it's not the "initialize" opcode
;
; Initialize
;
	move.l	10(a6),a0		; get application name
	ld_appn	a1			; lea gl_appname(a5),a1
	moveq.l	#APPPACKSIZE,d0
	bsr	ascii2pack		; convert ASCII to packed form
	move.l	14(a6),scratchbuf(a5)	; get pointer to scratch buffer
	move.w	#-1,cache_sector(a5)	; mark cache as empty
	moveq.l	#NUMFILES-1,d7		; zero out the file_handle array
	moveq.l	#0,d0
	lea	file_handle(a5),a0
.iloop:
	move.w	d0,(a0)+		; zero start block
	move.l	d0,(a0)+		; zero offset
	dbra	d7,.iloop
;
; Now: check the cartridge for a valid first block
;
; get the checksum for the block
	bsr	calc_chksum
	move.w	d0,d2
;
; here d2 == checksum
;
	suba.l	a0,a0			; set a0 = 0
	bsr	Getbyte
	move.w	d0,d3			; save first byte of checksum in high byte of d3
	asl	#8,d3
	addq.l	#1,a0			; set a0 = 1
	bsr	Getbyte
	or.w	d0,d3
	cmp.w	d2,d3			; compare checksums
	beq.b	.cok			; if equal, everything is OK
;
; if the checksum doesn't make sense, re-initialize the cartridge by erasing directories and FATs
;
	moveq.l	#0,d0
	movea.l	d0,a0
	move.l	#(DIRBLOCKS+FATBLOCKS)*BLOCKSIZE,d7
.eloop:
	bsr	Putbyte			; write a 0
	addq.l	#1,a0			; move to the next byte
	subq.l	#1,d7
	bne.b	.eloop
.cok:
	moveq.l	#0,d0
	bra	return			; and return (d0 still equals 0)

;
; dispatcher for all other functions
;
.notinit:
	tst.l	scratchbuf(a5)		; make sure Initialize has been called
	bne.b	.initcalled
	moveq.l	#ENOINIT,d0		; nope: error
	bra	return
.initcalled:
	move.w	d7,d0
	subq.w	#1,d0			; use (opcode-1) as a table index
	cmp.w	#MAXOPCODE,d0		; is the opcode in range
	bmi.b	.opok
	moveq.l	#EINVFN,d0		; no: illegal request
	bra	return
.opok:
	add.w	d0,d0			; convert opcode to a word index
.here:
	move.w	.table-.here-2(pc,d0.w),d0
	jmp	2(pc,d0.w)
.table:					; dispatch table
	.dc.w	create-.table
	.dc.w	open-.table
	.dc.w	close-.table
	.dc.w	delete-.table
	.dc.w	read-.table
	.dc.w	write-.table
	.dc.w	sfirst-.table
	.dc.w	snext-.table
	.dc.w	seek-.table
	.dc.w	inquire-.table
;
; here's where all the functions come back
;
return:
	bsr	FLUSH			; make sure we flushed any cached data
	movem.l	(sp)+, d1-d7/a0-a5
	unlk	a6
	rts
;
; The top level functions:
; All the functions expect the following things to be true:
; a5 points to start_bss
; a6 points to a stack frame, so 8(a6) points to the function
; 	opcode and 10(a6) points to the remaining arguments
; d7 contains the opcode for the current function
;
; top level functions can destroy any registers they want to (except a5);
;
; NVM_create( char *filename, long size )
;
;
; utility routine: unpack file name (passed in a0) into gl_filename,
; and return with a0=gl_appname, a1 = gl_filename
;
packname:
	lea	gl_filename(a5),a1
	moveq.l	#FILEPACKSIZE,d0
	bsr	ascii2pack
	ld_appn	a0			; lea gl_appname(a5),a0
	lea	gl_filename(a5),a1	; load a0=gl_appname, a1=gl_filename
	rts

create:
	bsr	Gethandle
	tst.l	d0
	bmi.b	return
	move.l	d0,d7			; save file handle
	move.l	10(a6),a0		; get the file name
	bsr	packname		; pack it into gl_filename
;
; now a0 = gl_appname, a1 = gl_filename
;
; delete any existing file with the same name
;
	bsr	DeleteFile
;
; see if there are any free directory entries
;
	moveq.l	#0,d2			; initialize directory number to 0
.loop:
	move.w	d2,d0
	lea	cur_d(a5),a0
	bsr	FetchDir		; get next directory entry
	tst.b	cur_d_startblock(a5)	; is this entry free?
	beq.b	.dirOK
	addq.w	#1,d2
	cmp.w	#NUMDIRENTRIES,d2	; have we reached the end?
	bne.b	.loop
; an error: no free directory entries found
.enospc:
	moveq.l	#ENOSPC,d0
	bra	return
.dirOK:
	move.l	14(a6),d5		; get the file size
	add.l	#BLOCKSIZE-1,d5		; round up to nearest block size
	moveq.l	#LOG2_BLOCKSIZE,d0
	lsr.l	d0,d5			; convert to size in blocks
	move.l	d5,d0
	bsr	AllocBlocks		; allocate that many blocks
	tst.l	d0
	bmi.b	.enospc			; not enough room left
	move.b	d0,cur_d_startblock(a5)	; save the starting block
	move.w	d0,d6			; save starting block
	move.b	d5,cur_d_numblocks(a5)	; save the number of blocks
	; copy over the names
	lea	cur_d_appname(a5),a1
	ld_appn	a0			; lea gl_appname(a5),a0
	moveq.l	#APPPACKSIZE-1,d0
.anamelp:
	move.w	(a0)+,(a1)+
	dbra	d0,.anamelp

	lea	cur_d_filename(a5),a1
	lea	gl_filename(a5),a0
	moveq.l	#FILEPACKSIZE-1,d0
.fnamelp:
	move.w	(a0)+,(a1)+
	dbra	d0,.fnamelp

	move.w	d2,d0			; d2 has the directory number in it
	lea	cur_d(a5),a0
	bsr	PutDir

	bsr	set_chksum		; re-calculate the checksum for the starting block

	move.l	d7,d0			; retrieve the file handle
	move.l	d6,d1			; and the starting block
;
; utility routine: set up a file handle for open() or create()
; entered with d0.l = file handle, d1 = file starting block
; returns to dispatcher
;
sethandle:
	move.l	d0,d2
	mulu	#FHANDLESIZ,d2		; index into file_handle array
	lea	file_handle(a5,d2.l),a0
	move.w	d1,(a0)+		; set starting block
	clr.l	(a0)			; clear file offset
	bra	return			; return to

;
; NVM_Open(char *filename)
;
open:
	bsr	Gethandle
	tst.l	d0
	bmi	return
	move.l	d0,d6
	move.l	10(a6),a0		; get the file name
	bsr	packname		; pack it into gl_filename
; now a0 = gl_appname, a1 = gl_filename
;
; find the directory entry
	bsr	FindFile
	tst.l	d0			; was the entry found?
	bmi	return
	move.l	d6,d0			; get file handle into d0
	clr.w	d1
	move.b	cur_d_startblock(a5),d1
	bra.b	sethandle		; set up file handle and return to caller

;
; NVM_close(int handle)
;
close:
	move.w	10(a6),d0		; get the file handle
	mulu	#FHANDLESIZ,d0		; convert to an index
	add.l	#file_handle,d0		; into the file_handle array
	clr.w	0(a5,d0.l)		; clear starting block (so we know this is closed)
	clr.l	2(a5,d0.l)		; clear file offset
	moveq.l	#0,d0			; return 0
	bra	return

;
; NVM_delete(char *appname, char *filename)
;
delete:
	move.l	14(a6),a0		; get the file name
	lea	gl_filename(a5),a3	; file name
	lea	alt_appname(a5),a4	; alternate application name

	move.l	a3,a1			; a3 = gl_filename, the packed address for the file name
	moveq.l	#FILEPACKSIZE,d0
	bsr	ascii2pack		; pack the file name

	move.l	10(a6),a2		; get the application name
	ld_appn	a0			; lea gl_appname(a5),a0
	moveq.l	#0,d0
	cmpa.l	d0,a2			; if passed in application name is NULL, use the current application name
	beq.b	.usedefault
	move.l	a2,a0			; a2 = application name (in ASCII) passed by user
	move.l	a4,a1			; pack the application name
	moveq.l	#APPPACKSIZE,d0
	bsr	ascii2pack
	move.l	a4,a0			; a4 = alt_appname, packed application name
.usedefault:
	move.l	a3,a1			; a3 = gl_filename
	bsr	DeleteFile
	bsr	set_chksum
	bra	return
;
; NVM_Seek(int handle, long offset, int flag)
;
seek:
	move.w	10(a6),d2		; get file handle
	move.l	12(a6),d3		; get file offset
	move.w	16(a6),d4		; get flag for Seek
	mulu	#FHANDLESIZ,d2		; convert file handle to index
	lea	file_handle(a5,d2.w),a2	; point to file handle structure
	tst.w	(a2)			; is the file open?
	beq.b	eihndl			; no: return an error
	cmp.w	#1,d4			; is the offset relative?
	bne.b	.not1
	add.l	2(a2),d3		; if yes: add in current position
	bra.b	.doit
.not1:
	cmp.w	#0,d4			; otherwise, is the flag 0?
	bne	einvfn			; if not, it's invalid
.doit:
	move.w	(a2),d0			; get starting block of file
	move.l	d3,a0			; get offset in file
	bsr	file_offset
	tst.l	d0			; did an error occur
	bmi	return			; yes: return the error
	move.l	d3,d0			; no: return the offset
	move.l	d3,2(a2)		; and update the file offset
	bra	return
eihndl:
	moveq.l	#EIHNDL,d0
	bra	return
einvfn:
	moveq.l	#EINVFN,d0
	bra	return

;
; NVM_read(int handle, char *buf, long size)
; NVM_write(int handle, char *buf, long size)
; These can share much of the same code, except for the
; final i/o operation.
; register usage: d2: starting block of file
;		  d3: offset into file
;		  d4: count of bytes we should read/write
;		  d5: count of bytes actually read or written so far
;		  d6: count of bytes left in the current block
;		  a2: points to file handle structure
;		  a3: points to data buffer
read:
write:
	move.w	10(a6),d0		; get handle
	mulu	#FHANDLESIZ,d0		; make it an index
	lea	file_handle(a5,d0.w),a2	; point to buffer
	move.w	(a2),d2			; get starting block for file
	beq	eihndl			; if this is 0, file handle isn't valid
	move.l	2(a2),d3		; get current offset in file
	move.l	12(a6),a3		; get buffer address
	move.l	16(a6),d4		; set limit
	moveq.l	#0,d5			; initialize bytes done
	moveq.l	#0,d6			; initialize bytes left in block
.loop:
	cmp.l	d4,d5			; compare bytes done to limit
	bge.b	.endloop
	addq.l	#1,a0			; increment destination address
	subq.w	#1,d6			; are there more bytes to write in this block?
	bge.b	.a0isok			; if not, we must recalculate a0
	move.w	d2,d0			; file starting block
	move.l	d3,a0			; offset in file
	bsr	file_offset		; convert file offset to NVRAM address
	tst.l	d0
	bmi.b	.endloop		; if an error occured, abort
	move.l	d0,a0			; set up NVRAM address for I/O
	not.w	d0
	and.w	#(BLOCKSIZE-1),d0	; get number of bytes left in block
	move.w	d0,d6
.a0isok:
	addq.l	#1,d3			; update offset in file
	addq.l	#1,d5			; and count of bytes done (in anticipation of the i/o below)
	cmp.w	#6,d7			; is this a write operation?
	beq.b	.write
.read:
	bsr	Getbyte
	move.b	d0,(a3)+		; copy the byte to user space
	bra.b	.loop
.write:
	move.b	(a3)+,d0		; get next byte to write
	bsr	Putbyte
	bra.b	.loop
.endloop:
	move.l	d3,2(a2)		; update file offset
	move.l	d5,d0			; return bytes done
	bra	return

;
; NVM_Sfirst(char *sbuf, long flags)
;
sfirst:
	move.l	14(a6),d0		; get search flags
	beq.b	.argok			; a 0 flag is fine
	cmp.w	#1,d0			; so is a 1 flag (should do a cmp.l, but cmp.w saves 2 bytes, and only the low word is interesting)
	bne	einvfn			; any other flag is illegal
.argok:
	move.l	d0,search_flags(a5)	; store the search flags
	clr.w	search_location(a5)	; and initialize the search
;
; FALL THROUGH to snext
;
; NVM_Snext(char *sbuf)
;
snext:
	move.l	10(a6),a4		; get the address of the search buffer
.sloop:
	move.w	search_location(a5),d3
	cmp.w	#NUMDIRENTRIES,d3	; have we run out of directory entries?
	bpl	.notfound
	move.w	d3,d0			; get next directory entry
	addq.w	#1,d3
	move.w	d3,search_location(a5)
	lea	cur_d(a5),a0
	bsr	FetchDir
	tst.b	cur_d_startblock(a5)		; is this a valid directory entry?
	beq.b	.sloop			; no: keep searching
	tst.w	search_flags(a5)	; are we searching for all files?
	beq.b	.found			; yes: we found a valid entry
	lea	cur_d_appname(a5),a0	; otherwise, check to see if this file was created
	ld_appn	a1			; lea gl_appname(a5),a1
	moveq.l	#APPPACKSIZE,d0
	bsr	matchpack
	tst.w	d0			; if not, keep looping
	beq.b	.sloop
.found:
	moveq.l	#0,d0			; zero out the file size
	moveq.l	#LOG2_BLOCKSIZE,d1
	move.b	cur_d_numblocks(a5),d0
	lsl.l	d1,d0			; multiply number of blocks by block size
	move.l	d0,(a4)+		; store file size
	move.l	a4,a1			; unpack the application name
	lea	cur_d_appname(a5),a0
	move.w	#APPPACKSIZE,d0
	bsr	pack2ascii
	lea	APPNAMELEN+1(a4),a1	; move to the file name part of the structure
	lea	cur_d_filename(a5),a0
	move.w	#FILEPACKSIZE,d0
	bsr	pack2ascii		; unpack the file name
	moveq.l	#0,d0			; return EOK
	bra	return
.notfound:
	moveq.l	#EFILNF,d0
	bra	return

inquire:
	move.l	10(a6),a2		; address for total space
	move.l	14(a6),a3		; address for free space
	move.l	#DATABLOCKS*BLOCKSIZE,(a2)	; total space on disk
	lea	USEDSPACEOFFSET.w,a0	; get used space on disk
	bsr	Getbyte
	move.w	#DATABLOCKS,d1		; total space
	sub.b	d0,d1			; minus used space
	mulu	#BLOCKSIZE,d1
	move.l	d1,(a3)			; equals free space
	moveq.l	#0,d0
	bra	return
;
; Various utility functions
; All of these expect parameters in d0-d1/a0-a1, and preserve d2-d7/a2-a7
; (except where otherwise noted)
;

;
; Gethandle: get a directory handle, if any is free; otherwise return ENFILES
;
Gethandle:
	moveq.l	#0,d0
	lea	file_handle(a5),a0	; point to file handles array
.loop:
	tst.w	(a0)			; check starting block
	beq.b	.ret			; if it's 0, this handle is free
	addq.l	#FHANDLESIZ,a0		; move to next file handle offset
	addq.w	#1,d0
	cmp.w	#NUMFILES,d0		; have we reached the end?
	bne.b	.loop
	moveq.l	#ENFILES,d0
.ret:
	rts

;
; calculate the checksum for the first block
;
calc_chksum:
	moveq.l	#0,d2			; d2 = checksum
	move.w	#BLOCKSIZE-2,d7		; checksum the first block, except for the checksum byte
	lea	2,a0			; (address 2 in NVRAM space)
.cloop:
	bsr	Getbyte
	add.w	d0,d2
	addq.l	#1,a0
	subq.w	#1,d7
	bne	.cloop
;
; here d2 == checksum: return it
;
	move.l	d2,d0
	rts
;
; set a new checksum for the starting block
;
set_chksum:
	bsr	calc_chksum		; get the checksum
	lsr.l	#8,d0			; get high byte
	suba.l	a0,a0			; set a0 = 0
	bsr	Putbyte			; write high byte
	addq.l	#1,a0			; set a0 = 1
	move.l	d2,d0
	bsr	Putbyte			; write low byte
	rts
;
; the character set we allow; we can fit 3 characters into
; a 16 bit word if we restrict ourselves to a 40 character
; set (40*40*40 = 64000 fits in 16 bits)

MAXCHAR		=	39
charset:
	dc.b	"ABCDEFGHIJKLMNOPQRSTUVWXYZ"
	dc.b	"0123456789"
	dc.b	":'. "

	.even
;
; ascii2pack: convert an ASCII string into its packed representation
; Parameters:
; 	a0	pointer to ASCII string
;	a1	pointer to packed data
;	d0.w	number of words to pack (must be > 0)
; Internal variables:
;	d1.w	current character (ASCII)
;	d2.w	flag: 1 if end of string seen, 0 otherwise
;	d3.w	current character (fivebit form)
;	d4.w	packed word of characters
;	d5.w	MAXCHAR+1
;	a2	pointer to character set table

ascii2pack:
	movem.l	d2-d5/a2,-(sp)
	clr.w	d2			; clear "end of string" flag
	clr.w	d1			; clear upper byte of ASCII character
	lea	charset(pc),a2
	moveq.l	#MAXCHAR+1,d5
.aloop:
	moveq.l	#0,d4			; clear out current word
	move.b	(a0)+,d1		; fetch next ASCII character
	bsr	fivebit			; convert to 5 bits
	add	d3,d4			; put it into the word
	move.b	(a0)+,d1		; convert to ASCII
	bsr	fivebit
	mulu	d5,d4			; "shift" word
	add	d3,d4			; add new fivebit character
	move.b	(a0)+,d1		; get third ASCII char
	bsr	fivebit
	mulu	d5,d4			; "shift" word
	add	d3,d4			; add new fivebit character
	move.w	d4,(a1)+

	subq.w	#1,d0
	bgt.b	.aloop

	movem.l	(sp)+,d2-d5/a2
	rts
;
; Internal subroutine for ascii2pack: converts 1 letter into
; its internal form
;
fivebit:
	tst.w	d1			; check current character
	bne.b	.nonzero		; is it zero?
	moveq.l	#1,d2			; yes: mark end of string
.nonzero:
	tst.w	d2			; has end of string been seen?
	beq.b	.noteos			; no: keep going
	moveq.l	#MAXCHAR,d3		; default character (space)
	rts
.noteos:
	cmp.w	#'z',d1			; if character is 'a' to 'z', return 0-25
	bhi.b	.notlowcase
	move.w	d1,d3
	sub.w	#'a',d3
	bmi.b	.notlowcase
	rts
.notlowcase:
	moveq.l	#0,d3			; set up for loop
.floop:
	cmp.b	0(a2,d3.w),d1		; have we found the ASCII character yet?
	beq.b	.ret			; yes: return it
	addq.w	#1,d3			; no: check next character
	cmp.w	#MAXCHAR,d3		; if we reach the last character, use that
	bne.b	.floop			; no matter what the ASCII was.
.ret:
	rts

;
; pack2ascii: convert a packed string into its ASCII representation
; Parameters:
;	a0	pointer to packed data
; 	a1	pointer to ASCII string
;	d0.w	number of words to unpack (must be > 0)
; Internal register usage:
;	d1.b	ASCII character
;	d2.w	packed word
;	d5.w	MAXCHAR+1
;	a2	pointer to character set table
;
pack2ascii:
	movem.l	d2-d6/a2,-(sp)
	moveq.l	#MAXCHAR+1,d5
	lea	charset(pc),a2
	addq.l	#3,a1			; Start just past the 3rd character and
.loop:					; use pre-decrement to count back down
	clr.b	(a1)			; zero-terminate the string
	moveq.l	#0,d2			; clear upper bits of packed word
	move.w	(a0)+,d2		; fetch next word
	divu	d5,d2
	swap	d2			; get remainder into low word
	move.b	0(a2,d2.w),-(a1)	; get third ASCII character
	clr.w	d2
	swap	d2			; get quotient back into low word
	divu	d5,d2			; divide to get next character
	swap	d2			; get remainder
	move.b	0(a2,d2.w),-(a1)	; get second ASCII character
	swap	d2
	move.b	0(a2,d2.w),-(a1)
	addq.l	#6,a1			; Point to byte after next 3 characters
	subq.w	#1,d0			; have we finished all packed characters?
	bgt.b	.loop
.ret:
	; String was zero-terminated above to start every loop iteration. done.
	movem.l	(sp)+,d2-d6/a2
	rts
;
; matchpack: see if two packed strings match
; returns 1 if they do, 0 if they don't
; Parameters:
;	a0	pointer to first packed strings
; 	a1	pointer to ASCII string
;	d0.w	number of words to compare (must be > 0)
; Internal register usage:
;	d1.w	word to check

matchpack:
	move.w	(a0)+,d1
	cmp.w	(a1)+,d1
	beq.b	.stillmatch
	clr.w	d0			; some words don't match: return 0
	rts
.stillmatch:
	subq.w	#1,d0
	bgt.b	matchpack
	moveq	#1,d0			; all words match
	rts

;
; FetchDir: read a directory entry into a buffer
; Parameters:
;	d0.w	directory number
;	a0.l	buffer
; Internal register usage:
;	a0.l	address in NVRAM
;	a2.l	buffer address
;	d2.l	loop counter

FetchDir:
	movem.l	d2/a2,-(sp)
	mulu	#DIRENTRYSIZE,d0		; calculate address of this directory entry
	add.w	#DIROFFSET,d0
	move.l	a0,a2			; set up buffer address
	move.l	d0,a0			; set byte address for GETBYTE
	move.w	#DIRENTRYSIZE-1,d2	; set loop counter
.loop:
	bsr	Getbyte
	move.b	d0,(a2)+
	addq.l	#1,a0
	dbra	d2,.loop

	movem.l	(sp)+,d2/a2
	rts

;
; PutDir: copy a buffer into a directory entry
; Parameters:
;	d0.w	directory number
;	a0.l	buffer
; Internal register usage:
;	a0.l	address in NVRAM
;	a2.l	buffer address
;	d2.l	loop counter

PutDir:
	movem.l	d2/a2,-(sp)
	mulu	#DIRENTRYSIZE,d0		; calculate address of this directory entry
	add.l	#DIROFFSET,d0
	move.l	a0,a2			; set up buffer address
	move.l	d0,a0			; set byte address for PUTBYTE
	move.w	#DIRENTRYSIZE-1,d2	; set loop counter
.loop:
	move.b	(a2)+,d0
	bsr	Putbyte
	addq.l	#1,a0
	dbra	d2,.loop

	movem.l	(sp)+,d2/a2
	rts
;
; AllocBlocks: allocate blocks from the FAT.
; Returns the first block allocated on success, or a
; (long) negative error code.
;
; Parameters:
;	d0.w	number of blocks to allocate
; Internal register usage:
;	d1.w	scratch register
;	d2.w	number of blocks to allocate
;	d3.w	first block allocated
;	d4.w	last block we allocated so far
;	d5.w	current block number
;	a2.l	FATOFFSET

AllocBlocks:
	movem.l	d2-d5/a2,-(sp)
	tst.w	d0			; special case empty files
	bne.b	.notempty
	moveq.l	#FAT_EMPTYFILE,d0
	bra.b	.ret
.notempty:
	move.w	d0,d2			; save number of blocks to allocate
; see if there's enough room
	lea	USEDSPACEOFFSET.w,a0
	bsr	Getbyte			; get number of blocks already in use
	add.w	d2,d0			; add number of blocks we're going to allocate
	cmp.w	#DATABLOCKS,d0		; see if there's room
	ble.b	.spaceok
	moveq.l	#ENOSPC,d0		; no there isn't
	bra.b	.ret
.spaceok:
	bsr	Putbyte			; update USEDSPACE byte (a0 and d0 are still set up correctly!)
	moveq.l	#0,d3			; initialize first block allocated
	moveq.l	#0,d4			; initialize previous block allocated
	moveq.l	#FIRSTDATABLOCK,d5	; initialize current block
	ld_fato	a2			; lea FATOFFSET.w,a2
.loop:
	cmp.w	#TOTALBLOCKS,d5		; have we reached the last block
	beq.b	.rangeerror		; yes (this should NEVER happen!!!)
	lea	0(a2,d5.w),a0		; get the FAT block corresponding to the current block
	bsr	Getbyte
	cmp.b	#FAT_FREE,d0		; is this block free?
	bne.b	.nomatch
	; if the block was free, then update the FAT entry for the previous block
	tst.w	d4			; was there a previous block?
	beq.b	.noprev		; if so, do special things
	lea	0(a2,d4.w),a0		; get FAT address of previous block
	move.w	d5,d0
	bsr	Putbyte			; write current block into it
	bra.b	.updateprev
.noprev:
	move.w	d5,d3			; if there was no "previous block", then this is the first block
.updateprev:
	move.w	d5,d4			; update the "previous block"
	subq.w	#1,d2			; one less block remains to allocate
.nomatch:
	addq.w	#1,d5			; move to next block
	tst.w	d2			; any blocks left to allocate?
	bne.b	.loop			; yes: keep looping
	moveq.l	#0,d0
	lea	0(a2,d4.w),a0		; get FAT address of last block
	move.w	#FAT_END,d0		; mark it as last block
	bsr	Putbyte
	move.l	d3,d0			; return first block allocated
.ret:
	movem.l	(sp)+,d2-d5/a2
	rts
.rangeerror:
	moveq.l	#ERANGE,d0
	bra.b	.ret

;
; FreeBlocks: free previously allocated FAT blocks
;
; Parameters:
;	d0.w	starting block of FAT chain for file
; Internal register usage:
;	d1.w	scratch register
;	a2.w	FATOFFSET
;	d2.w	current block number
;	d3.w	(unused)
;	d4.w	number of blocks used in the file system

FreeBlocks:
	movem.l	d2-d4/a2,-(sp)
	move.w	d0,d2
	ld_fato	a2			; lea FATOFFSET.w,a2
	lea	USEDSPACEOFFSET.w,a0		; get the number of blocks currently used on the cart
	bsr	Getbyte
	move.w	d0,d4
.loop:
	tst.w	d4				; sanity check: are there still used blocks?
	beq.b	.endloop 
	cmp.w	#FAT_EMPTYFILE,d2		; is this FAT entry free, empty, or the end of a chain?
	ble.b	.endloop			; if so, break
	lea	0(a2,d2.w),a0			; get FAT entry for current file
	bsr	Getbyte
	move.w	d0,d2				; update current block number
	moveq.l	#FAT_FREE,d0			; mark FAT entry as free
	bsr	Putbyte				; a0 still points at previous FAT entry
	subq.w	#1,d4				; decrement number of blocks used
	bra.b	.loop
.endloop:
	move.w	d4,d0				; update the number of blocks in use
	lea	USEDSPACEOFFSET.w,a0
	bsr	Putbyte
.ret:
	movem.l	(sp)+,d2-d4/a2
	rts
;
; FindFile: find which directory block (if any)
; belongs to a file name. If the directory block
; is found, it is copied into the "cur_d"
; static variable.
; Returns: directory block in d0.l
; Parameters:
;	a0.l	file's application name
;	a1.l	file's file name
; Internal register usage:
;	a2.l	copy of appname
;	a3.l	copy of filename
;	d2.w	loop counter

FindFile:
	movem.l	d2/a2-a3,-(sp)
	move.l	a0,a2			; save appname
	move.l	a1,a3			; save filename
	moveq.l	#0,d2			; initialize counter
.loop:
	move.w	d2,d0			; directory number
	lea	cur_d(a5),a0		; buffer for FetchDir to fill
	bsr	FetchDir
	tst.w	cur_d_startblock(a5)	; check for deleted directory entries (startblock is set to 0 for these)
	beq.b	.notfound
	lea	cur_d_appname(a5),a0	; see if the application names match
	move.l	a2,a1
	moveq.l	#APPPACKSIZE,d0
	bsr	matchpack
	tst.w	d0
	beq.b	.notfound
	lea	cur_d_filename(a5),a0		; see if the file names match
	move.l	a3,a1
	moveq.l	#FILEPACKSIZE,d0
	bsr	matchpack
	tst.w	d0
	beq.b	.notfound
	; everything matches: we found the right directory entry!
	move.l	d2,d0
	bra.b	.ret
.notfound:
	addq.w	#1,d2			; move to next directory entry
	cmp.w	#NUMDIRENTRIES,d2	; have we reached the end?
	bne.b	.loop			; no: keep going
	moveq.l	#EFILNF,d0		; yes: the file isn't found
.ret:
	movem.l	(sp)+,d2/a2-a3
	rts

;
; DeleteFile: delete a file from the directory
; Returns 0 on success, or EFILNF if file is not found
;
; Parameters:
;	a0.l	file's application name
;	a1.l	file's file name
; Internal register usage:

DeleteFile:
	bsr	FindFile		; parameters are set up OK already
	tst.l	d0			; is the file found?
	bmi.b	.ret			; file not found or error: return the error
;
; mark the file as deleted by putting 0 in for starting block and number of
; blocks in the directory entry; these are the first 2 bytes in the directory
; entry, so we can easily find it in NVRAM
;
	mulu	#DIRENTRYSIZE,d0		; find address in NVRAM
	add.w	#DIROFFSET,d0
	move.l	d0,a0
	moveq.l	#0,d0
	bsr	Putbyte			; write 0 into the first byte
	addq.l	#1,a0
	moveq.l	#0,d0
	bsr	Putbyte			; and write 0 into the second byte
;
; now free the FAT chain associated with the file
;
	clr.w	d0
	move.b	cur_d_startblock(a5),d0
	bsr	FreeBlocks
	moveq.l	#0,d0			; return 0 for success
.ret:
	rts

;
; file_offset: convert a byte offset in a file to an absolute
; address in NVRAM
; Parameters:
;	d0.w	starting block of file
;	a0.l	offset in file
; Internal register usage:
;	a2.l	FATOFFSET
;	d2.w	current block in file
;	d3.l	current offset in file
;	d4.l	BLOCKSIZE
; Returns:
;	d0.l	offset in NVRAM
;
file_offset:
	movem.l	d2-d4/a2,-(sp)
	move.l	#BLOCKSIZE,d4
	move.w	d0,d2			; set initial block
	ld_fato	a2			; lea FATOFFSET.w,a2
	move.l	a0,d3			; set file offset
	bmi.b	.erange			; negative offsets are an error
.loop:
	cmp.l	d4,d3			; while file offset >= BLOCKSIZE?
	blt.b	.done
	cmp.w	#FAT_EMPTYFILE,d2	; is the block one of FAT_FREE|FAT_END|FAT_EMPTYFILE?
	bmi.b	.erange			; if so, report a range error
					; (BUG: offset 0 on a 0 length file reports ERANGE)
	lea	0(a2,d2.w),a0		; get the FAT byte at FATOFFSET+block
	bsr	Getbyte
	move.w	d0,d2			; save the new block number
	sub.l	d4,d3			; reduce offset size
	bra.b	.loop
.done:
	cmp.w	#FAT_EMPTYFILE,d2	; is the block one of FAT_FREE|FAT_END|FAT_EMPTYFILE?
	bmi.b	.erange			; if so, report a range error

	moveq.l	#0,d0
	move.w	d2,d0			; get block number
	moveq.l	#LOG2_BLOCKSIZE,d2	; multiply by block size
	lsl.l	d2,d0
	add.l	d3,d0			; add offset
	bra.b	.ret
.erange:
	moveq.l	#ERANGE,d0
.ret:
	movem.l	(sp)+,d2-d4/a2
	rts
;
;****************************************************************
;* Here is where you should put the routines that talk directly *
;* to the hardware. These are probably the only things that	*
;* will have to change if the hardware does. There are 3	*
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
