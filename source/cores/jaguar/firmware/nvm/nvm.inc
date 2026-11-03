; NVM BIOS assembly language include file
; generated automatically from nvm.h
; *** DO NOT EDIT ***

; To change something here, change it in nvm.h and
; remake (the makefile dependencies should take care
; of the rest.
; For documentation & comments, see nvm.h.

APPPACKSIZE  = 5
FILEPACKSIZE = 3
APPNAMELEN   = 15
FILENAMELEN  = 9
DIRENTRYSIZE = 18
NUMFILES     = 3
CHKSUMOFFSET = 0
VERSOFFSET   = 2
USEDSPACEOFFSET = 3
FATOFFSET    = 0
FIRSTFATBLOCK = 0
REAL_FATOFFSET  = 8
BLOCKSIZE    = 512
LOG2_BLOCKSIZE = 9
FATBLOCKS    = 1
DIROFFSET    = 512
DIRBLOCKS    = 7
TOTALBLOCKS  = 256
NUMDIRENTRIES = 199
FIRSTDATABLOCK = 8
FIRSTDIRBLOCK = 1
DATAOFFSET   = 4096
DATABLOCKS   = 248

FAT_FREE     = 0
FAT_END      = 1
FAT_EMPTYFILE = 2

ENOINIT = -1
ENOSPC  = -2
EFILNF  = -3
EINVFN  = -4
ERANGE  = -5
ENFILES = -6
EIHNDL  = -7
