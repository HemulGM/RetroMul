unit HW.SH4;

// Hitachi SH-4 (SH7750/SH7091) instruction interpreter: integer and FPU
// instructions, delay slots, exceptions and interrupt acceptance, store
// queues, operand-cache RAM and address translation through the UTLB (with
// translated 4 KiB pages cached until the TLB changes). Decoded blocks are
// cached per virtual PC and execution mode and validated against write
// generations of their 4 KiB code pages (and, translated, their mapping).
// References: Renesas SH-4 Software Manual (REJ09B0318) and SH7750 Series
// Hardware Manual (REJ09B0366). Define DC_CHECKED for range/overflow checks.
{$IFDEF DC_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$EXCESSPRECISION OFF}
{$POINTERMATH ON}

interface

uses
  System.SysUtils, System.Math, Core.Snapshots;

const
  // TSH4TLBPage.Flags: device memory reached through the bus (reads,
  // writes), not accessible in user mode, valid in every address space.
  SH4PageDeviceRead = 1;
  SH4PageDeviceWrite = 2;
  SH4PagePrivileged = 4;
  SH4PageShared = 8;

  // Exception codes (EXPEVT) and vector offsets from VBR.
  SH4ExcTLBMissRead = $040;
  SH4ExcTLBMissWrite = $060;
  SH4ExcInitialWrite = $080;
  SH4ExcTLBProtRead = $0A0;
  SH4ExcTLBProtWrite = $0C0;
  SH4ExcAddressRead = $0E0;
  SH4ExcAddressWrite = $100;
  SH4ExcFPU = $120;
  SH4ExcTrap = $160;
  SH4ExcIllegal = $180;
  SH4ExcSlotIllegal = $1A0;
  SH4ExcFPUDisabled = $800;
  SH4ExcSlotFPUDisabled = $820;

  SH4SRWriteMask = $700083F3;
  SH4FPSCRMask = $003FFFFF;

type
  // Bus callbacks receive physical (29-bit) addresses outside the direct
  // pages. Size is 1, 2, 4 or 8 bytes; values are little-endian.
  TSH4BusRead = function(User: Pointer; Address: Cardinal; Size: Integer): UInt64;
  TSH4BusWrite = procedure(User: Pointer; Address: Cardinal; Value: UInt64; Size: Integer);
  // 32-byte store-queue or similar burst to a physical address.
  TSH4BusBurst = procedure(User: Pointer; Address: Cardinal; Data: PCardinal; Count: Integer);
  // On-chip modules outside the CPU core (P4 0xFF000000.., area 7).
  TSH4OnChipRead = function(User: Pointer; Address: Cardinal; Size: Integer): Cardinal;
  TSH4OnChipWrite = procedure(User: Pointer; Address, Value: Cardinal; Size: Integer);
  // Optional instruction fetch hook for test harnesses (all fetches when set).
  TSH4Fetch = function(User: Pointer; Address: Cardinal): Word;
  // Optional observer of instructions run by steps (diagnostics).
  TSH4StepHook = procedure(User: Pointer; PC: Cardinal);
  // Called for an illegal instruction; True when the owner handled it (HLE
  // firmware entry points) and set PC itself.
  TSH4IllegalHook = function(User: Pointer; Address: Cardinal): Boolean;

  // Physical 64 KiB pages: host memory or nil (callbacks). Gens points to
  // sixteen write-generation counters, one per 4 KiB of the page.
  TSH4PhysicalPages = array[0..8191] of PByte;
  TSH4PhysicalGens = array[0..8191] of PCardinal;
  PSH4PhysicalPages = ^TSH4PhysicalPages;
  PSH4PhysicalGens = ^TSH4PhysicalGens;

  TSH4Bus = record
    User: Pointer;
    Read: TSH4BusRead;
    Write: TSH4BusWrite;
    Burst: TSH4BusBurst;
    OnChipRead: TSH4OnChipRead;
    OnChipWrite: TSH4OnChipWrite;
    OnChipUser: Pointer;
    ReadPages, WritePages: PSH4PhysicalPages;
    Gens: PSH4PhysicalGens;
  end;

  TSH4FPBank = record
    case Integer of
      0: (S: array[0..15] of Single);
      1: (U: array[0..15] of Cardinal);
      2: (D: array[0..7] of Double);
      3: (Q: array[0..7] of UInt64);
  end;

  TSH4TLBEntry = record
    VPN, ASID, PPN, Flags, PTEA: Cardinal; // Flags: V SZ PR C D SH WT (PTEL bits)
  end;

  // Complete architectural state. FR/XF hold FRn at index n xor 1, so that
  // DRn (even n) is the native double D[n div 2]. R0..R7 always hold the
  // active bank; RBank the inactive one (swapped on SR.RB changes).
  TSH4Registers = array[0..15] of Cardinal;

  TSH4State = record
    R: TSH4Registers;
    RBank: array[0..7] of Cardinal;
    FR, XF: TSH4FPBank;
    PC, PR, GBR, VBR, SSR, SPC, SGR, DBR, MACH, MACL, FPUL, FPSCR: Cardinal;
    SR, T: Cardinal; // SR without T; T separately (0/1)
    // Delay slot across Step calls.
    DelaySlot: Boolean;
    DelayTarget: Cardinal;
    // RTE restores SR after its delay slot.
    RTEPending: Boolean;
    RTESR: Cardinal;
    Sleeping: Boolean;
    // CCN.
    PTEH, PTEL, PTEA, TTB, TEA, MMUCR, CCR, TRA, EXPEVT, INTEVT, QACR0, QACR1, BASRA, BASRB: Cardinal;
    SQ: array[0..1, 0..7] of Cardinal;
    UTLB: array[0..63] of TSH4TLBEntry;
    ITLB: array[0..3] of TSH4TLBEntry;
    OCRAM: array[0..8191] of Byte;
  end;

  TSH4Inst = record
    Kind: Byte;
    N, M: Byte;
    Flags: Byte;
    Imm: Cardinal;
    Addr: Cardinal;
  end;
  PSH4Inst = ^TSH4Inst;

  PSH4Block = ^TSH4Block;
  TSH4Block = record
    PC, Mode: Cardinal;
    Count: Integer;
    // Code reached through the UTLB (Translated): its physical address,
    // checked again when translations changed since Epoch. Phys and Epoch
    // fill alignment gaps.
    Phys: Cardinal;
    Insts: PSH4Inst;
    Code: PWord;
    Words: Integer;
    Epoch: Cardinal;
    GenPtr, GenPtr2: PCardinal;
    Gen, Gen2: Cardinal;
    Next: PSH4Block;
    // Recently followed successors (validated by PC, mode and code).
    Link: array[0..1] of PSH4Block;
    Idle, Translated: Boolean;
  end;

  // A 4 KiB page of P0/P3 with a cached translation: host memory for reads
  // and (when allowed) writes, the physical page and its write generation,
  // SH4Page* flags and the address space (PTEH.ASID) it was translated in.
  TSH4TLBPage = record
    Read, Write: PByte;
    Gen: PCardinal;
    Phys: Cardinal;
    Flags, ASID: Byte;
  end;
  PSH4TLBPage = ^TSH4TLBPage;

  // Host memory of the 4 KiB pages of P0, or their cached translations.
  TSH4FastPages = array[0..$7FFFF] of PByte;
  PSH4FastPages = ^TSH4FastPages;
  TSH4FastWrites = array[0..$7FFFF] of PSH4TLBPage;
  PSH4FastWrites = ^TSH4FastWrites;

  TSH4 = class
  private
    const
      BlockBuckets = 16384;
      BlockChunkSize = 1024;
      InstChunkSize = 16384;
      MaxBlockInsts = 128;
      {$IFDEF CPU64BITS}
      MaxBlocks = 65536;
      MaxInstChunks = 96;
      {$ELSE}
      MaxBlocks = 16384;
      MaxInstChunks = 24;
      {$ENDIF}
  private
    FBus: TSH4Bus;
    FFetch: TSH4Fetch;
    FFetchUser: Pointer;
    FStepHook: TSH4StepHook;
    FStepUser: Pointer;
    FIllegalHook: TSH4IllegalHook;
    FIllegalUser: Pointer;
    // Virtual 64 KiB pages for direct access (nil: slow path).
    FReadMap: array[0..65535] of PByte;
    FWriteMap: array[0..65535] of PByte;
    FGenMap: array[0..65535] of PCardinal;
    FZeroGens, FSinkGens: array[0..15] of Cardinal;
    // Pending interrupt from INTC (0: none).
    FIRQLevel: Integer;
    FIRQCode: Cardinal;
    // Set by slow paths; the executing instruction stops without side effects.
    FFault: Boolean;
    // Set by MMIO writes that need the run loop to return to the scheduler.
    FExitRequest: Boolean;
    FHostRoundSaved: TRoundingMode;
    FHostMaskSaved: TArithmeticExceptionMask;
    // Blocks.
    FBlockHead: array[0..BlockBuckets - 1] of PSH4Block;
    FBlockChunks: TArray<TArray<TSH4Block>>;
    FInstChunks: TArray<TArray<TSH4Inst>>;
    FCodeChunks: TArray<TArray<Word>>;
    FBlockCount, FInstChunk, FInstUsed, FCodeChunk, FCodeUsed: Integer;
    FBlocksBuilt: Int64;
    // Instructions of fused operations beyond one each, since the run loop
    // last counted them.
    FFusedExtra: Integer;
    // Wait loops (see IdleCheck): the candidate loop head, iterations seen,
    // probe phase and its starting point, writes logged while probing and a
    // count of accesses that rule a loop out (device memory, exceptions).
    FIdleHead, FIdleRejected: Cardinal;
    // The loop last skipped: probed again at once when reached after an
    // event (until rejected).
    FIdleSkipped: Cardinal;
    FIdleHits, FIdlePhase: Integer;
    FIdleStart: TSH4State;
    FIdleNow0, FIdleCycles: Int64;
    FIdleSide0, FIdleEpoch: Cardinal;
    FIdleCounter: Cardinal;
    // The counter's host memory and write generation (IdleIteration).
    FIdleCounterHost: PByte;
    FIdleCounterGen: PCardinal;
    FJournalOn, FJournalFull: Boolean;
    // Writes while probing: the address written, the host memory and write
    // generation behind it, its physical address (FFFFFFFFh when not one
    // the probe accepts) and the contents before the first write.
    FJournal: array[0..15] of record
      Address: Cardinal;
      Size: Integer;
      Old: UInt64;
      Host: PByte;
      Gen: PCardinal;
      Phys: Cardinal;
    end;
    FJournalCount: Integer;
    FSideEffects: Cardinal;
    // Block execution state shared with the operation handlers.
    FJumped, FExcepted: Boolean;
    FJumpTarget: Cardinal;
    FStop: Byte;
    FBlocksEnabled: Boolean;
    FLenient: Boolean;
    FScratch: array[0..1] of TSH4Inst;
    // Address translation (MMUCR.AT): translated 4 KiB pages of P0 and P3
    // in chunks of 16 MiB allocated when first used, the indexes filled
    // since the last flush, the UTLB entry Translate last matched and a
    // counter bumped whenever translations change.
    FTLBChunks: TArray<TArray<TSH4TLBPage>>;
    FTLBFilled: TArray<Integer>;
    FTLBFilledCount: Integer;
    FTLBOverflow: Boolean;
    FTLBEntry: Integer;
    FTLBEpoch: Cardinal;
    FMapStale: Boolean;
    // The UTLB as Address and Mask = Key per entry (invalid: Mask 0, Key 1),
    // updated with the array, for a quick search.
    FUTLBKey, FUTLBMask: array[0..63] of Cardinal;
    // Physical 64 KiB pages marked by SetVolatile.
    FVolatile: array[0..8191] of Boolean;
    // Readable and writable pages of P0 as TLBPage found them, per processor
    // mode (user, privileged) and only for the current address space, so
    // translated accesses take one look-up; FFastRead and FFastWrite are the
    // current mode's. The entries set since the last clear are listed
    // (Mode shl 31 or Writing shl 30 or page).
    FFastMaps: array[0..1] of TArray<PByte>;
    FFastWriteMaps: array[0..1] of TArray<PSH4TLBPage>;
    FFastRead: PSH4FastPages;
    FFastWrite: PSH4FastWrites;
    FFastFilled: TArray<Cardinal>;
    FFastFilledCount: Integer;
    FFastOverflow: Boolean;
    procedure FastFill(Address: Cardinal; Host: PByte; Page: PSH4TLBPage);
    procedure FastSelect; inline;
    procedure FastClear;
    procedure UpdateUTLBKey(Index: Integer);
    procedure UpdateUTLBKeys;
    procedure AssociativeWrite(Value: Cardinal);
    function TLBIndex(Address: Cardinal): Integer; inline;
    procedure TLBFill(Address, Physical: Cardinal; Writing: Boolean);
    function TLBPage(Address: Cardinal): PSH4TLBPage; inline;
    procedure TLBFlush;
    procedure TLBInvalidate(const E: TSH4TLBEntry);
    // Sets FMapStale when the block's code moved (rather than not mapped now).
    function BlockMapped(B: PSH4Block): Boolean;
    procedure BuildMaps;
    procedure MapPage(Page: Integer);
    function PhysicalPage(Virtual: Cardinal; Writing: Boolean): PByte;
    function SlowRead(Address: Cardinal; Size: Integer): UInt64;
    procedure SlowWrite(Address: Cardinal; Value: UInt64; Size: Integer);
    // Accesses that miss the direct maps while translation pages are cached:
    // translated RAM without the general slow path.
    function TranslatedRead(Address: Cardinal; Size: Integer): UInt64;
    procedure TranslatedWrite(Address: Cardinal; Value: UInt64; Size: Integer);
    // Writes that miss the direct maps: store queues here, the rest through
    // TranslatedWrite or SlowWrite.
    procedure WriteMiss(Address: Cardinal; Value: UInt64; Size: Integer);
    function ReadControl(Address: Cardinal; Size: Integer): Cardinal;
    procedure WriteControl(Address, Value: Cardinal; Size: Integer);
    function Translate(Address: Cardinal; Writing: Boolean; out Physical: Cardinal): Boolean;
    procedure StoreQueueFlush(Address: Cardinal);
    procedure SwapBanks; inline;
    procedure SwapFPBanks; inline;
    procedure SetSRValue(Value: Cardinal);
    procedure SetFPSCRValue(Value: Cardinal);
    procedure ApplyHostRounding;
    function GetSRValue: Cardinal; inline;
    function Mode: Cardinal; inline;
    procedure EnterException(Code, Offset, ReturnPC: Cardinal);
    procedure Fault(Code: Cardinal; const I: TSH4Inst; Slot: Boolean);
    function FetchWord(Address: Cardinal; out Op: Word): Boolean;
    function Decode(Op: Word; Address, AMode: Cardinal; Slot: Boolean; out I: TSH4Inst): Boolean;
    function Execute(Insts: PSH4Inst; Count: Integer; out Next: Cardinal): Integer;
    // Operation handlers (SH4Ops); True stops the block.
    function OpNOP(I: PSH4Inst): Boolean;
    function OpMOV(I: PSH4Inst): Boolean;
    function OpMOVI(I: PSH4Inst): Boolean;
    function OpMOVWPC(I: PSH4Inst): Boolean;
    function OpMOVLPC(I: PSH4Inst): Boolean;
    function OpMOVA(I: PSH4Inst): Boolean;
    function OpMOVBS(I: PSH4Inst): Boolean;
    function OpMOVWS(I: PSH4Inst): Boolean;
    function OpMOVLS(I: PSH4Inst): Boolean;
    function OpMOVBL(I: PSH4Inst): Boolean;
    function OpMOVWL(I: PSH4Inst): Boolean;
    function OpMOVLL(I: PSH4Inst): Boolean;
    function OpMOVBM(I: PSH4Inst): Boolean;
    function OpMOVWM(I: PSH4Inst): Boolean;
    function OpMOVLM(I: PSH4Inst): Boolean;
    function OpMOVBP(I: PSH4Inst): Boolean;
    function OpMOVWP(I: PSH4Inst): Boolean;
    function OpMOVLP(I: PSH4Inst): Boolean;
    function OpMOVBS0(I: PSH4Inst): Boolean;
    function OpMOVWS0(I: PSH4Inst): Boolean;
    function OpMOVLS0(I: PSH4Inst): Boolean;
    function OpMOVBL0(I: PSH4Inst): Boolean;
    function OpMOVWL0(I: PSH4Inst): Boolean;
    function OpMOVLL0(I: PSH4Inst): Boolean;
    function OpMOVBS4(I: PSH4Inst): Boolean;
    function OpMOVWS4(I: PSH4Inst): Boolean;
    function OpMOVLS4(I: PSH4Inst): Boolean;
    function OpMOVBL4(I: PSH4Inst): Boolean;
    function OpMOVWL4(I: PSH4Inst): Boolean;
    function OpMOVLL4(I: PSH4Inst): Boolean;
    function OpMOVBSG(I: PSH4Inst): Boolean;
    function OpMOVWSG(I: PSH4Inst): Boolean;
    function OpMOVLSG(I: PSH4Inst): Boolean;
    function OpMOVBLG(I: PSH4Inst): Boolean;
    function OpMOVWLG(I: PSH4Inst): Boolean;
    function OpMOVLLG(I: PSH4Inst): Boolean;
    function OpMOVT(I: PSH4Inst): Boolean;
    function OpSWAPB(I: PSH4Inst): Boolean;
    function OpSWAPW(I: PSH4Inst): Boolean;
    function OpXTRCT(I: PSH4Inst): Boolean;
    function OpADD(I: PSH4Inst): Boolean;
    function OpADDI(I: PSH4Inst): Boolean;
    function OpADDC(I: PSH4Inst): Boolean;
    function OpADDV(I: PSH4Inst): Boolean;
    function OpCMPEQ(I: PSH4Inst): Boolean;
    function OpCMPEQI(I: PSH4Inst): Boolean;
    function OpCMPHS(I: PSH4Inst): Boolean;
    function OpCMPGE(I: PSH4Inst): Boolean;
    function OpCMPHI(I: PSH4Inst): Boolean;
    function OpCMPGT(I: PSH4Inst): Boolean;
    function OpCMPPZ(I: PSH4Inst): Boolean;
    function OpCMPPL(I: PSH4Inst): Boolean;
    function OpCMPSTR(I: PSH4Inst): Boolean;
    function OpDIV0S(I: PSH4Inst): Boolean;
    function OpDIV0U(I: PSH4Inst): Boolean;
    function OpDIV1(I: PSH4Inst): Boolean;
    function OpROTDIV(I: PSH4Inst): Boolean;
    function OpDMULS(I: PSH4Inst): Boolean;
    function OpDMULU(I: PSH4Inst): Boolean;
    function OpDT(I: PSH4Inst): Boolean;
    function OpEXTSB(I: PSH4Inst): Boolean;
    function OpEXTSW(I: PSH4Inst): Boolean;
    function OpEXTUB(I: PSH4Inst): Boolean;
    function OpEXTUW(I: PSH4Inst): Boolean;
    function OpMACL(I: PSH4Inst): Boolean;
    function OpMACW(I: PSH4Inst): Boolean;
    function OpMULL(I: PSH4Inst): Boolean;
    function OpMULSW(I: PSH4Inst): Boolean;
    function OpMULUW(I: PSH4Inst): Boolean;
    function OpNEG(I: PSH4Inst): Boolean;
    function OpNEGC(I: PSH4Inst): Boolean;
    function OpSUB(I: PSH4Inst): Boolean;
    function OpSUBC(I: PSH4Inst): Boolean;
    function OpSUBV(I: PSH4Inst): Boolean;
    function OpAND(I: PSH4Inst): Boolean;
    function OpANDI(I: PSH4Inst): Boolean;
    function OpANDB(I: PSH4Inst): Boolean;
    function OpNOT(I: PSH4Inst): Boolean;
    function OpOR(I: PSH4Inst): Boolean;
    function OpORI(I: PSH4Inst): Boolean;
    function OpTASB(I: PSH4Inst): Boolean;
    function OpTST(I: PSH4Inst): Boolean;
    function OpTSTI(I: PSH4Inst): Boolean;
    function OpXOR(I: PSH4Inst): Boolean;
    function OpXORI(I: PSH4Inst): Boolean;
    function OpROTL(I: PSH4Inst): Boolean;
    function OpROTR(I: PSH4Inst): Boolean;
    function OpROTCL(I: PSH4Inst): Boolean;
    function OpROTCR(I: PSH4Inst): Boolean;
    function OpSHAD(I: PSH4Inst): Boolean;
    function OpSHLD(I: PSH4Inst): Boolean;
    function OpSHAL(I: PSH4Inst): Boolean;
    function OpSHAR(I: PSH4Inst): Boolean;
    function OpSHLL2(I: PSH4Inst): Boolean;
    function OpSHLL8(I: PSH4Inst): Boolean;
    function OpSHLL16(I: PSH4Inst): Boolean;
    function OpSHLR(I: PSH4Inst): Boolean;
    function OpSHLR2(I: PSH4Inst): Boolean;
    function OpSHLR8(I: PSH4Inst): Boolean;
    function OpSHLR16(I: PSH4Inst): Boolean;
    function OpBF(I: PSH4Inst): Boolean;
    function OpBT(I: PSH4Inst): Boolean;
    function OpBFS(I: PSH4Inst): Boolean;
    function OpBTS(I: PSH4Inst): Boolean;
    function OpBRA(I: PSH4Inst): Boolean;
    function OpBSR(I: PSH4Inst): Boolean;
    function OpBRAF(I: PSH4Inst): Boolean;
    function OpBSRF(I: PSH4Inst): Boolean;
    function OpJMP(I: PSH4Inst): Boolean;
    function OpJSR(I: PSH4Inst): Boolean;
    function OpRTS(I: PSH4Inst): Boolean;
    function OpRTE(I: PSH4Inst): Boolean;
    function OpCLRMAC(I: PSH4Inst): Boolean;
    function OpCLRS(I: PSH4Inst): Boolean;
    function OpCLRT(I: PSH4Inst): Boolean;
    function OpSETS(I: PSH4Inst): Boolean;
    function OpSETT(I: PSH4Inst): Boolean;
    function OpLDTLB(I: PSH4Inst): Boolean;
    function OpMOVCAL(I: PSH4Inst): Boolean;
    function OpPREF(I: PSH4Inst): Boolean;
    function OpSLEEP(I: PSH4Inst): Boolean;
    function OpTRAPA(I: PSH4Inst): Boolean;
    function OpLDCSR(I: PSH4Inst): Boolean;
    function OpLDCGBR(I: PSH4Inst): Boolean;
    function OpLDCVBR(I: PSH4Inst): Boolean;
    function OpLDCSSR(I: PSH4Inst): Boolean;
    function OpLDCSPC(I: PSH4Inst): Boolean;
    function OpLDCDBR(I: PSH4Inst): Boolean;
    function OpLDCBANK(I: PSH4Inst): Boolean;
    function OpLDCMSR(I: PSH4Inst): Boolean;
    function OpLDSMACH(I: PSH4Inst): Boolean;
    function OpLDSMACL(I: PSH4Inst): Boolean;
    function OpLDSPR(I: PSH4Inst): Boolean;
    function OpSTCSR(I: PSH4Inst): Boolean;
    function OpSTCGBR(I: PSH4Inst): Boolean;
    function OpSTCVBR(I: PSH4Inst): Boolean;
    function OpSTCSSR(I: PSH4Inst): Boolean;
    function OpSTCSPC(I: PSH4Inst): Boolean;
    function OpSTCSGR(I: PSH4Inst): Boolean;
    function OpSTCDBR(I: PSH4Inst): Boolean;
    function OpSTCBANK(I: PSH4Inst): Boolean;
    function OpSTCMSR(I: PSH4Inst): Boolean;
    function OpSTSMACH(I: PSH4Inst): Boolean;
    function OpSTSMACL(I: PSH4Inst): Boolean;
    function OpSTSPR(I: PSH4Inst): Boolean;
    function OpLDSFPSCR(I: PSH4Inst): Boolean;
    function OpLDSFPUL(I: PSH4Inst): Boolean;
    function OpSTSFPSCR(I: PSH4Inst): Boolean;
    function OpSTSFPUL(I: PSH4Inst): Boolean;
    function OpFMOV(I: PSH4Inst): Boolean;
    function OpFMOVLD(I: PSH4Inst): Boolean;
    function OpFMOVLD0(I: PSH4Inst): Boolean;
    function OpFMOVLDP(I: PSH4Inst): Boolean;
    function OpFMOVST(I: PSH4Inst): Boolean;
    function OpFMOVST0(I: PSH4Inst): Boolean;
    function OpFMOVSTM(I: PSH4Inst): Boolean;
    function OpFMOVD(I: PSH4Inst): Boolean;
    function OpFMOVDLD(I: PSH4Inst): Boolean;
    function OpFMOVDST(I: PSH4Inst): Boolean;
    function OpFLDI0(I: PSH4Inst): Boolean;
    function OpFLDI1(I: PSH4Inst): Boolean;
    function OpFLDS(I: PSH4Inst): Boolean;
    function OpFSTS(I: PSH4Inst): Boolean;
    function OpFABS(I: PSH4Inst): Boolean;
    function OpFNEG(I: PSH4Inst): Boolean;
    function OpFADD(I: PSH4Inst): Boolean;
    function OpFSUB(I: PSH4Inst): Boolean;
    function OpFMUL(I: PSH4Inst): Boolean;
    function OpFDIV(I: PSH4Inst): Boolean;
    function OpFMAC(I: PSH4Inst): Boolean;
    function OpFSQRT(I: PSH4Inst): Boolean;
    function OpFSRRA(I: PSH4Inst): Boolean;
    function OpFCMPEQ(I: PSH4Inst): Boolean;
    function OpFCMPGT(I: PSH4Inst): Boolean;
    function OpFLOAT(I: PSH4Inst): Boolean;
    function OpFTRC(I: PSH4Inst): Boolean;
    function OpFIPR(I: PSH4Inst): Boolean;
    function OpFTRV(I: PSH4Inst): Boolean;
    function OpFSCA(I: PSH4Inst): Boolean;
    function OpFSCHG(I: PSH4Inst): Boolean;
    function OpFRCHG(I: PSH4Inst): Boolean;
    function OpDABS(I: PSH4Inst): Boolean;
    function OpDNEG(I: PSH4Inst): Boolean;
    function OpDADD(I: PSH4Inst): Boolean;
    function OpDSQRT(I: PSH4Inst): Boolean;
    function OpDCMPEQ(I: PSH4Inst): Boolean;
    function OpDCMPGT(I: PSH4Inst): Boolean;
    function OpDFLOAT(I: PSH4Inst): Boolean;
    function OpDFTRC(I: PSH4Inst): Boolean;
    function OpFCNVSD(I: PSH4Inst): Boolean;
    function OpFCNVDS(I: PSH4Inst): Boolean;
    function OpIllegal(I: PSH4Inst): Boolean;
    procedure Div1(N, M: Integer); inline;
    procedure RotateDivide(const I: TSH4Inst);
    procedure FuseBlock(Insts: PSH4Inst; var Count: Integer);
    procedure ClearBlocks;
    function FindBlock(PC, AMode: Cardinal): PSH4Block;
    function BuildBlock(PC, AMode: Cardinal): PSH4Block;
    function BlockValid(B: PSH4Block): Boolean;
    procedure RunBlocks;
    procedure KeepIdleStart;
    procedure JournalWrite(A: Cardinal; Size: Integer);
    procedure JournalHost(A: Cardinal; Host: PByte; Gen: PCardinal; Phys: Cardinal; Size: Integer);
    function IdleIteration(out Counter: Cardinal; out Delta: Int64): Boolean;
    procedure IdleCheck;
    function Read8(A: Cardinal): Cardinal; inline;
    function Read16(A: Cardinal): Cardinal; inline;
    function Read32(A: Cardinal): Cardinal; inline;
    function Read64(A: Cardinal): UInt64; inline;
    procedure Write8(A, V: Cardinal); inline;
    procedure Write16(A, V: Cardinal); inline;
    procedure Write32(A, V: Cardinal); inline;
    procedure Write64(A: Cardinal; V: UInt64); inline;
  public
    S: TSH4State;
    // Advanced by executed instructions; the run loop stops at Deadline^.
    Now, Deadline: PInt64;
    InstructionsExecuted: Int64;
    // Wait loops run ahead to the next event (on by default; the result is
    // the same either way).
    IdleSkipping: Boolean;
    // Diagnostics: clocks of wait-loop iterations accounted without running them.
    IdleCyclesSkipped: Int64;
    // Diagnostics (not serialized): exceptions taken and the first one.
    ExceptionCount: Int64;
    FirstExceptionPC, FirstExceptionCode, FirstExceptionPR: Cardinal;
    constructor Create(const Bus: TSH4Bus; NowCounter, DeadlineCounter: PInt64);
    procedure Reset;
    // Physical page tables or MMU/OCRAM state changed.
    procedure RemapMemory;
    // One physical 64 KiB page's table entries changed.
    procedure RemapPhysical(Page: Integer);
    // Physical 64 KiB pages whose host memory the bus may withdraw and give
    // back while code runs (RemapPhysical): translated accesses to them
    // always go through the bus, so remapping them leaves cached
    // translations (and so the UTLB accesses that advance MMUCR.URC) alone.
    procedure SetVolatile(Page: Integer);
    procedure InvalidateBlocks;
    procedure SetFetchHook(Fetch: TSH4Fetch; User: Pointer);
    // Called with the PC of each instruction; code then runs by steps.
    procedure SetStepHook(Hook: TSH4StepHook; User: Pointer);
    procedure SetIllegalHook(Hook: TSH4IllegalHook; User: Pointer);
    // Highest pending INTC request: priority level 1..15 and INTEVT code.
    procedure SetInterrupt(Level: Integer; Code: Cardinal);
    procedure RequestExit; inline;
    // Executes until Now^ >= Deadline^ (whole blocks).
    procedure Run;
    // Executes exactly one instruction (a delay slot is a separate step).
    procedure Step;
    // Physical address from a virtual one with the current MMU state (the
    // low 29 bits where nothing maps it).
    function PhysicalAddress(Virtual: Cardinal): Cardinal;
    // For high-level code standing in for the instruction at PC (system
    // calls): the physical address of a virtual one. Where the MMU cannot
    // translate it, the CPU takes the exception that instruction would and
    // the result is False; the handler returns to PC to run it again.
    function TranslateOrFault(Address: Cardinal; Writing: Boolean; out Physical: Cardinal): Boolean;
    // Accesses on behalf of the instruction at PC (1, 2 or 4 bytes); then
    // AccessFaulted is True when one failed and the CPU took its exception.
    function LoadVirtual(Address: Cardinal; Size: Integer): Cardinal;
    procedure StoreVirtual(Address, Value: Cardinal; Size: Integer);
    function AccessFaulted: Boolean;
    procedure SerializeState(Archive: TStateArchive);
    function SRValue: Cardinal;
    procedure SetSR(Value: Cardinal);
    procedure SetFPSCR(Value: Cardinal);
    property BlocksBuilt: Int64 read FBlocksBuilt;
    property BlocksEnabled: Boolean read FBlocksEnabled write FBlocksEnabled;
    // SingleStepTests conventions: no alignment, privilege or FPU-disable
    // exceptions. Never set for emulation.
    property Lenient: Boolean read FLenient write FLenient;
    property IRQLevel: Integer read FIRQLevel;
  end;

implementation

// Guest integer arithmetic wraps modulo 2^32 by definition; DC_CHECKED keeps
// range checks for host indexing.
{$Q-}

const
  SRT = $00000001;
  SRS = $00000002;
  SRQ = $00000100;
  SRM = $00000200;
  SRFD = $00008000;
  SRBL = $10000000;
  SRRB = $20000000;
  SRMD = $40000000;

  FPSCRDN = $00040000;
  FPSCRPR = $00080000;
  FPSCRSZ = $00100000;
  FPSCRFR = $00200000;

  ModeMD = 1;
  ModeFD = 2;
  ModePR = 4;
  ModeSZ = 8;

  // TSH4Inst.Flags
  IFEnd = 1;       // the block ends after this instruction
  IFDelayed = 2;   // delayed branch; the next instruction is its slot
  IFSlot = 4;      // executes in a delay slot

type
  TOp = (
    oIllegal, oSlotIllegal, oFPUDisabled, oSlotFPUDisabled,
    oNOP, oMOV, oMOVI, oMOVWPC, oMOVLPC, oMOVA,
    oMOVBS, oMOVWS, oMOVLS, oMOVBL, oMOVWL, oMOVLL,
    oMOVBM, oMOVWM, oMOVLM, oMOVBP, oMOVWP, oMOVLP,
    oMOVBS0, oMOVWS0, oMOVLS0, oMOVBL0, oMOVWL0, oMOVLL0,
    oMOVBS4, oMOVWS4, oMOVLS4, oMOVBL4, oMOVWL4, oMOVLL4,
    oMOVBSG, oMOVWSG, oMOVLSG, oMOVBLG, oMOVWLG, oMOVLLG,
    oMOVT, oSWAPB, oSWAPW, oXTRCT,
    oADD, oADDI, oADDC, oADDV, oCMPEQ, oCMPEQI, oCMPHS, oCMPGE, oCMPHI, oCMPGT, oCMPPZ, oCMPPL, oCMPSTR,
    oDIV0S, oDIV0U, oDIV1, oDMULS, oDMULU, oDT, oEXTSB, oEXTSW, oEXTUB, oEXTUW,
    oMACL, oMACW, oMULL, oMULSW, oMULUW, oNEG, oNEGC, oSUB, oSUBC, oSUBV,
    oAND, oANDI, oANDB, oNOT, oOR, oORI, oORB, oTASB, oTST, oTSTI, oTSTB, oXOR, oXORI, oXORB,
    oROTL, oROTR, oROTCL, oROTCR, oSHAD, oSHAL, oSHAR, oSHLD, oSHLL, oSHLL2, oSHLL8, oSHLL16,
    oSHLR, oSHLR2, oSHLR8, oSHLR16,
    oBF, oBFS, oBT, oBTS, oBRA, oBRAF, oBSR, oBSRF, oJMP, oJSR, oRTS, oRTE,
    oCLRMAC, oCLRS, oCLRT, oSETS, oSETT, oLDTLB, oMOVCAL, oOCB, oPREF, oSLEEP, oTRAPA,
    oLDCSR, oLDCGBR, oLDCVBR, oLDCSSR, oLDCSPC, oLDCDBR, oLDCBANK,
    oLDCMSR, oLDCMGBR, oLDCMVBR, oLDCMSSR, oLDCMSPC, oLDCMDBR, oLDCMBANK,
    oLDSMACH, oLDSMACL, oLDSPR, oLDSMMACH, oLDSMMACL, oLDSMPR,
    oSTCSR, oSTCGBR, oSTCVBR, oSTCSSR, oSTCSPC, oSTCSGR, oSTCDBR, oSTCBANK,
    oSTCMSR, oSTCMGBR, oSTCMVBR, oSTCMSSR, oSTCMSPC, oSTCMSGR, oSTCMDBR, oSTCMBANK,
    oSTSMACH, oSTSMACL, oSTSPR, oSTSMMACH, oSTSMMACL, oSTSMPR,
    oLDSFPSCR, oLDSFPUL, oLDSMFPSCR, oLDSMFPUL, oSTSFPSCR, oSTSFPUL, oSTSMFPSCR, oSTSMFPUL,
    oFMOV, oFMOVLD, oFMOVLD0, oFMOVLDP, oFMOVST, oFMOVST0, oFMOVSTM,
    oFMOVD, oFMOVDLD, oFMOVDLD0, oFMOVDLDP, oFMOVDST, oFMOVDST0, oFMOVDSTM,
    oFLDI0, oFLDI1, oFLDS, oFSTS, oFABS, oFNEG, oFADD, oFSUB, oFMUL, oFDIV, oFMAC, oFSQRT,
    oFCMPEQ, oFCMPGT, oFLOAT, oFTRC, oFSRRA, oFIPR, oFTRV, oFSCA, oFSCHG, oFRCHG,
    oDABS, oDNEG, oDADD, oDSUB, oDMUL, oDDIV, oDSQRT, oDCMPEQ, oDCMPGT, oDFLOAT, oDFTRC,
    oFCNVSD, oFCNVDS,
    // Fused runs of the division step pairs ROTCL Ra / DIV1 Rm,Rn (in either
    // order) that unrolled divisions consist of: N, M of DIV1, Imm = pairs
    // or Ra shl 16. They run exactly as the single instructions.
    oROTDIV, oDIVROT);

  // Operation handlers: methods of TSH4 called with Self; True stops the
  // block (FStop tells how).
  TSH4OpHandler = function(CPU: TSH4; I: PSH4Inst): Boolean;

const
  StopNone = 0;
  StopLeave = 1; // the instruction completed and the block ends
  StopTrap = 2;  // TRAPA completed; the exception entry set PC

var
  SH4Ops: array[TOp] of TSH4OpHandler;

{ Memory }

function TSH4.PhysicalPage(Virtual: Cardinal; Writing: Boolean): PByte;
begin
  Result := nil;
  if Virtual >= $E0000000 then
    Exit;
  if ((Virtual < $80000000) or (Virtual >= $C0000000)) and ((S.MMUCR and 1) <> 0) then
    Exit;
  var Physical := Virtual and $1FFFFFFF;
  // Area 7 holds on-chip registers; 7C000000..7FFFFFFF the operand-cache RAM.
  if Physical >= $1C000000 then
    Exit;
  if Writing then
    Result := FBus.WritePages[Physical shr 16]
  else
    Result := FBus.ReadPages[Physical shr 16];
end;

procedure TSH4.MapPage(Page: Integer);
begin
  var Virtual := Cardinal(Page) shl 16;
  FReadMap[Page] := PhysicalPage(Virtual, False);
  FWriteMap[Page] := PhysicalPage(Virtual, True);
  FGenMap[Page] := @FSinkGens[0];
  if FReadMap[Page] <> nil then
  begin
    var G := FBus.Gens[(Virtual and $1FFFFFFF) shr 16];
    if G <> nil then
      FGenMap[Page] := G
    else if FWriteMap[Page] = nil then
      FGenMap[Page] := @FZeroGens[0];
  end;
end;

procedure TSH4.BuildMaps;
begin
  for var Page := 0 to 65535 do
    MapPage(Page);
end;

procedure TSH4.RemapMemory;
begin
  BuildMaps;
  if FTLBFilledCount > 0 then
    TLBFlush;
end;

procedure TSH4.RemapPhysical(Page: Integer);
begin
  // The eight virtual 64 KiB pages that alias a physical one.
  for var Top := 0 to 7 do
    MapPage((Top shl 13) or (Page and $1FFF));
  if (FTLBFilledCount > 0) and not FVolatile[Page and $1FFF] then
    TLBFlush;
end;

procedure TSH4.SetVolatile(Page: Integer);
begin
  FVolatile[Page and $1FFF] := True;
  if FTLBFilledCount > 0 then
    TLBFlush;
end;

function TSH4.Read8(A: Cardinal): Cardinal;
begin
  var P := FReadMap[A shr 16];
  if P <> nil then
    Result := (P + (A and $FFFF))^
  else
    if FTLBChunks <> nil then
      Result := Cardinal(TranslatedRead(A, 1))
    else
      Result := Cardinal(SlowRead(A, 1));
end;

function TSH4.Read16(A: Cardinal): Cardinal;
begin
  var P := FReadMap[A shr 16];
  if (P <> nil) and ((A and 1) = 0) then
    Result := PWord(P + (A and $FFFF))^
  else
    if FTLBChunks <> nil then
      Result := Cardinal(TranslatedRead(A, 2))
    else
      Result := Cardinal(SlowRead(A, 2));
end;

function TSH4.Read32(A: Cardinal): Cardinal;
begin
  var P := FReadMap[A shr 16];
  if (P <> nil) and ((A and 3) = 0) then
    Result := PCardinal(P + (A and $FFFF))^
  else
    if FTLBChunks <> nil then
      Result := Cardinal(TranslatedRead(A, 4))
    else
      Result := Cardinal(SlowRead(A, 4));
end;

function TSH4.Read64(A: Cardinal): UInt64;
begin
  var P := FReadMap[A shr 16];
  if (P <> nil) and ((A and 7) = 0) then
    Result := PUInt64(P + (A and $FFFF))^
  else if FTLBChunks <> nil then
    Result := TranslatedRead(A, 8)
  else
    Result := SlowRead(A, 8);
end;

procedure TSH4.Write8(A, V: Cardinal);
begin
  var P := FWriteMap[A shr 16];
  if P <> nil then
  begin
    if FJournalOn then
      JournalWrite(A, 1);
    (P + (A and $FFFF))^ := Byte(V);
    Inc(FGenMap[A shr 16][(A shr 12) and 15]);
  end
  else
    WriteMiss(A, V and $FF, 1);
end;

procedure TSH4.Write16(A, V: Cardinal);
begin
  var P := FWriteMap[A shr 16];
  if (P <> nil) and ((A and 1) = 0) then
  begin
    if FJournalOn then
      JournalWrite(A, 2);
    PWord(P + (A and $FFFF))^ := Word(V);
    Inc(FGenMap[A shr 16][(A shr 12) and 15]);
  end
  else
    WriteMiss(A, V and $FFFF, 2);
end;

procedure TSH4.Write32(A, V: Cardinal);
begin
  var P := FWriteMap[A shr 16];
  if (P <> nil) and ((A and 3) = 0) then
  begin
    if FJournalOn then
      JournalWrite(A, 4);
    PCardinal(P + (A and $FFFF))^ := V;
    Inc(FGenMap[A shr 16][(A shr 12) and 15]);
  end
  else
    WriteMiss(A, V, 4);
end;

procedure TSH4.Write64(A: Cardinal; V: UInt64);
begin
  var P := FWriteMap[A shr 16];
  if (P <> nil) and ((A and 7) = 0) then
  begin
    if FJournalOn then
      JournalWrite(A, 8);
    PUInt64(P + (A and $FFFF))^ := V;
    Inc(FGenMap[A shr 16][(A shr 12) and 15]);
  end
  else
    WriteMiss(A, V, 8);
end;

function TSH4.Translate(Address: Cardinal; Writing: Boolean; out Physical: Cardinal): Boolean;
begin
  // UTLB search (ITLB shares it). Without AT, P0..P3 map to the low 29 bits.
  Result := True;
  FTLBEntry := -1;
  Physical := Address and $1FFFFFFF;
  if ((S.MMUCR and 1) = 0) or ((Address >= $80000000) and (Address < $C0000000)) then
    Exit;
  // URC, the entry LDTLB replaces, advances on every UTLB access and wraps
  // at URB (when set) or 64.
  var URC := ((S.MMUCR shr 10) and 63) + 1;
  var URB := (S.MMUCR shr 18) and 63;
  if (URC = 64) or ((URB > 0) and (URC = URB)) then
    URC := 0;
  S.MMUCR := (S.MMUCR and not Cardinal($FC00)) or (URC shl 10);
  var ASID := S.PTEH and $FF;
  var Shared := (S.MMUCR and $100) <> 0; // SV: single virtual memory
  var Found := -1;
  for var I := 0 to 63 do
  begin
    if (Address and FUTLBMask[I]) <> FUTLBKey[I] then
      Continue;
    var E := S.UTLB[I];
    var Mask := FUTLBMask[I];
    if ((E.Flags and 2) = 0) and not (Shared and ((S.SR and SRMD) <> 0)) and (E.ASID <> ASID) then
      Continue;
    if Found >= 0 then
    begin
      // Multiple hit: treated as a miss (the hardware raises a reset).
      Found := -1;
      Break;
    end;
    Found := I;
    Physical := (E.PPN and Mask) or (Address and not Mask);
  end;
  if Found < 0 then
  begin
    S.TEA := Address;
    S.PTEH := (S.PTEH and $FF) or (Address and $FFFFFC00);
    FFault := True;
    if Writing then
      S.EXPEVT := SH4ExcTLBMissWrite
    else
      S.EXPEVT := SH4ExcTLBMissRead;
    Exit(False);
  end;
  var E := S.UTLB[Found];
  var PR := (E.Flags shr 5) and 3;
  var Privileged := (S.SR and SRMD) <> 0;
  if (not Privileged and (PR < 2)) or (Writing and ((PR and 1) = 0)) then
  begin
    S.TEA := Address;
    S.PTEH := (S.PTEH and $FF) or (Address and $FFFFFC00);
    FFault := True;
    if Writing then
      S.EXPEVT := SH4ExcTLBProtWrite
    else
      S.EXPEVT := SH4ExcTLBProtRead;
    Exit(False);
  end;
  if Writing and ((E.Flags and 4) = 0) then
  begin
    S.TEA := Address;
    S.PTEH := (S.PTEH and $FF) or (Address and $FFFFFC00);
    FFault := True;
    S.EXPEVT := SH4ExcInitialWrite;
    Exit(False);
  end;
  Physical := Physical and $1FFFFFFF;
  FTLBEntry := Found;
end;

procedure TSH4.UpdateUTLBKey(Index: Integer);
begin
  var Flags := S.UTLB[Index].Flags;
  if (Flags and $100) = 0 then
  begin
    FUTLBMask[Index] := 0;
    FUTLBKey[Index] := 1;
    Exit;
  end;
  var Mask: Cardinal;
  case ((Flags shr 6) and 2) or ((Flags shr 4) and 1) of
    0: Mask := $FFFFFC00;
    1: Mask := $FFFFF000;
    2: Mask := $FFFF0000;
  else
    Mask := $FFF00000;
  end;
  FUTLBMask[Index] := Mask;
  FUTLBKey[Index] := S.UTLB[Index].VPN and Mask;
end;

procedure TSH4.UpdateUTLBKeys;
begin
  for var I := 0 to 63 do
    UpdateUTLBKey(I);
end;

procedure TSH4.AssociativeWrite(Value: Cardinal);
begin
  // UTLB address array write with A set: the valid entries that translate
  // the VPN for the ASID in Value (by the usual rules) take its V and D.
  var Shared := ((S.MMUCR and $100) <> 0) and ((S.SR and SRMD) <> 0);
  for var I := 0 to 63 do
  begin
    var E := S.UTLB[I];
    if (E.Flags and $100) = 0 then
      Continue;
    var Mask: Cardinal;
    case ((E.Flags shr 6) and 2) or ((E.Flags shr 4) and 1) of
      0: Mask := $FFFFFC00;
      1: Mask := $FFFFF000;
      2: Mask := $FFFF0000;
    else
      Mask := $FFF00000;
    end;
    if ((E.VPN xor Value) and Mask) <> 0 then
      Continue;
    if ((E.Flags and 2) = 0) and not Shared and (E.ASID <> (Value and $FF)) then
      Continue;
    S.UTLB[I].Flags := (E.Flags and not Cardinal($104)) or (Value and $100) or ((Value shr 7) and 4);
    UpdateUTLBKey(I);
  end;
end;

function TSH4.TLBIndex(Address: Cardinal): Integer;
begin
  // P0 (00000000..7FFFFFFF), then P3 (C0000000..DFFFFFFF); -1 elsewhere.
  if Address < $80000000 then
    Result := Integer(Address shr 12)
  else if (Address >= $C0000000) and (Address < $E0000000) then
    Result := $80000 + Integer((Address - $C0000000) shr 12)
  else
    Result := -1;
end;

procedure TSH4.TLBFill(Address, Physical: Cardinal; Writing: Boolean);
begin
  // After a successful Translate: pages mapped by entries of 4 KiB or more
  // are cached for later accesses of the same kind.
  if FTLBEntry < 0 then
    Exit;
  var Index := TLBIndex(Address);
  if Index < 0 then
    Exit;
  var E := S.UTLB[FTLBEntry];
  if (((E.Flags shr 6) and 2) or ((E.Flags shr 4) and 1)) = 0 then
    Exit;
  var Base := Physical and $1FFFF000;
  var Host: PByte := nil;
  if (Base < $1C000000) and not FVolatile[Base shr 16] then
    if Writing then
      Host := FBus.WritePages[Base shr 16]
    else
      Host := FBus.ReadPages[Base shr 16];
  if FTLBChunks = nil then
  begin
    SetLength(FTLBChunks, $A0);
    SetLength(FTLBFilled, 16384);
  end;
  if FTLBChunks[Index shr 12] = nil then
    SetLength(FTLBChunks[Index shr 12], 4096);
  var Page: PSH4TLBPage := @FTLBChunks[Index shr 12][Index and 4095];
  var ASID := Byte(S.PTEH);
  var Flags: Byte := 0;
  if ((E.Flags shr 5) and 3) < 2 then
    Flags := SH4PagePrivileged;
  if (E.Flags and 2) <> 0 then
    Flags := Flags or SH4PageShared;
  if (Page.Read = nil) and (Page.Write = nil) and (Page.Flags = 0) then
  begin
    if FTLBFilledCount < Length(FTLBFilled) then
    begin
      FTLBFilled[FTLBFilledCount] := Index;
      Inc(FTLBFilledCount);
    end
    else
      FTLBOverflow := True;
  end
  else if (Page.Phys <> Base) or (Page.ASID <> ASID) or
    ((Page.Flags and (SH4PagePrivileged or SH4PageShared)) <> Flags) then
    Page^ := Default(TSH4TLBPage);
  Page.Phys := Base;
  Page.ASID := ASID;
  Page.Flags := Page.Flags or Flags;
  if Host = nil then
  begin
    if Writing then
      Page.Flags := Page.Flags or SH4PageDeviceWrite
    else
      Page.Flags := Page.Flags or SH4PageDeviceRead;
  end
  else if Writing then
  begin
    Page.Write := Host + (Base and $FFFF);
    var G := FBus.Gens[Base shr 16];
    if G <> nil then
      Page.Gen := @G[(Base shr 12) and 15]
    else
      Page.Gen := @FSinkGens[0];
  end
  else
    Page.Read := Host + (Base and $FFFF);
end;

function TSH4.TLBPage(Address: Cardinal): PSH4TLBPage;
begin
  // The cached translation usable now, if any.
  Result := nil;
  if (FTLBChunks = nil) or ((S.MMUCR and 1) = 0) then
    Exit;
  var Index := TLBIndex(Address);
  if (Index < 0) or (FTLBChunks[Index shr 12] = nil) then
    Exit;
  Result := @FTLBChunks[Index shr 12][Index and 4095];
  // Another address space's translation, or a privileged-only page in user
  // mode (SR.MD, SRMD, clear).
  if (((Result.Flags and SH4PageShared) = 0) and (Result.ASID <> Byte(S.PTEH))) or
    (((Result.Flags and SH4PagePrivileged) <> 0) and ((S.SR and $40000000) = 0)) then
    Result := nil;
end;

procedure TSH4.TLBFlush;
begin
  if FTLBOverflow then
  begin
    for var Chunk in FTLBChunks do
      if Chunk <> nil then
        FillChar(Chunk[0], Length(Chunk) * SizeOf(TSH4TLBPage), 0);
  end
  else
    for var I := 0 to FTLBFilledCount - 1 do
      FTLBChunks[FTLBFilled[I] shr 12][FTLBFilled[I] and 4095] := Default(TSH4TLBPage);
  FTLBFilledCount := 0;
  FTLBOverflow := False;
  FastClear;
  Inc(FTLBEpoch);
end;

procedure TSH4.TLBInvalidate(const E: TSH4TLBEntry);
begin
  // The pages an entry being replaced may have cached (any ASID).
  Inc(FTLBEpoch);
  if (FTLBChunks = nil) or ((E.Flags and $100) = 0) then
    Exit;
  var Size: Cardinal;
  case ((E.Flags shr 6) and 2) or ((E.Flags shr 4) and 1) of
    0: Size := $400;
    1: Size := $1000;
    2: Size := $10000;
  else
    Size := $100000;
  end;
  var First := E.VPN and not (Size - 1);
  var Address := First and $FFFFF000;
  while Address - First < Size do
  begin
    var Index := TLBIndex(Address);
    if (Index >= 0) and (FTLBChunks[Index shr 12] <> nil) then
      FTLBChunks[Index shr 12][Index and 4095] := Default(TSH4TLBPage);
    if (Index >= 0) and (Index < $80000) and (FFastMaps[0] <> nil) then
      for var M := 0 to 1 do
      begin
        FFastMaps[M][Index] := nil;
        FFastWriteMaps[M][Index] := nil;
      end;
    Inc(Address, $1000);
  end;
end;

function TSH4.PhysicalAddress(Virtual: Cardinal): Cardinal;
begin
  if not Translate(Virtual, False, Result) then
  begin
    FFault := False;
    Result := Virtual and $1FFFFFFF;
  end;
end;

function TSH4.TranslateOrFault(Address: Cardinal; Writing: Boolean; out Physical: Cardinal): Boolean;
begin
  // P4 and the operand-cache RAM are not translated.
  if (Address >= $E0000000) or (((Address and $FC000000) = $7C000000) and ((S.CCR and $21) = $21)) then
  begin
    Physical := Address and $1FFFFFFF;
    Exit(True);
  end;
  Result := Translate(Address, Writing, Physical) or not AccessFaulted;
end;

function TSH4.LoadVirtual(Address: Cardinal; Size: Integer): Cardinal;
begin
  case Size of
    1: Result := Read8(Address) and $FF;
    2: Result := Read16(Address) and $FFFF;
  else
    Result := Read32(Address);
  end;
end;

procedure TSH4.StoreVirtual(Address, Value: Cardinal; Size: Integer);
begin
  case Size of
    1: Write8(Address, Value);
    2: Write16(Address, Value);
  else
    Write32(Address, Value);
  end;
end;

function TSH4.AccessFaulted: Boolean;
begin
  Result := FFault;
  if not Result then
    Exit;
  FFault := False;
  // TLB misses have their own vector.
  var Offset: Cardinal := $100;
  if (S.EXPEVT = SH4ExcTLBMissRead) or (S.EXPEVT = SH4ExcTLBMissWrite) then
    Offset := $400;
  EnterException(S.EXPEVT, Offset, S.PC);
end;

function OCRAMOffset(Address, CCR: Cardinal): Integer; inline;
begin
  // Two 4 KiB halves selected by A12 (OIX=0) or A25 (OIX=1).
  if (CCR and $80) <> 0 then
    Result := Integer(((Address shr 13) and $1000) or (Address and $FFF))
  else
    Result := Integer(Address and $1FFF);
end;

function TSH4.TranslatedRead(Address: Cardinal; Size: Integer): UInt64;
begin
  var H: PByte := nil;
  if (FFastRead <> nil) and (Address < $80000000) then
    H := FFastRead[Address shr 12];
  if H = nil then
  begin
    var Page := TLBPage(Address);
    if Page <> nil then
    begin
      H := Page.Read;
      if (H <> nil) and (Address < $80000000) then
        FastFill(Address, H, nil);
    end;
  end;
  if (H <> nil) and ((Address and Cardinal(Size - 1)) = 0) then
  begin
    H := H + (Address and $FFF);
    case Size of
      1: Result := H^;
      2: Result := PWord(H)^;
      4: Result := PCardinal(H)^;
    else
      Result := PUInt64(H)^;
    end;
  end
  else
    Result := SlowRead(Address, Size);
end;

procedure TSH4.FastFill(Address: Cardinal; Host: PByte; Page: PSH4TLBPage);
begin
  // A readable page's host memory, or (Host nil) a writable page.
  if FFastMaps[0] = nil then
  begin
    for var M := 0 to 1 do
    begin
      SetLength(FFastMaps[M], High(TSH4FastPages) + 1);
      SetLength(FFastWriteMaps[M], High(TSH4FastWrites) + 1);
    end;
    SetLength(FFastFilled, 16384);
  end;
  var Mode := (S.SR shr 30) and 1;
  var Index := Address shr 12;
  var Tag := (Mode shl 31) or Index;
  if Host <> nil then
    FFastMaps[Mode][Index] := Host
  else
  begin
    FFastWriteMaps[Mode][Index] := Page;
    Tag := Tag or $40000000;
  end;
  FastSelect;
  if FFastFilledCount < Length(FFastFilled) then
  begin
    FFastFilled[FFastFilledCount] := Tag;
    Inc(FFastFilledCount);
  end
  else
    FFastOverflow := True;
end;

procedure TSH4.FastSelect;
begin
  var Mode := (S.SR shr 30) and 1;
  FFastRead := @FFastMaps[Mode][0];
  FFastWrite := @FFastWriteMaps[Mode][0];
end;

procedure TSH4.FastClear;
begin
  if FFastMaps[0] = nil then
    Exit;
  if FFastOverflow then
    for var M := 0 to 1 do
    begin
      FillChar(FFastMaps[M][0], Length(FFastMaps[M]) * SizeOf(PByte), 0);
      FillChar(FFastWriteMaps[M][0], Length(FFastWriteMaps[M]) * SizeOf(PSH4TLBPage), 0);
    end
  else
    for var I := 0 to FFastFilledCount - 1 do
    begin
      var Tag := FFastFilled[I];
      if (Tag and $40000000) = 0 then
        FFastMaps[Tag shr 31][Tag and $7FFFF] := nil
      else
        FFastWriteMaps[Tag shr 31][Tag and $7FFFF] := nil;
    end;
  FFastFilledCount := 0;
  FFastOverflow := False;
  FastSelect;
end;

procedure TSH4.WriteMiss(Address: Cardinal; Value: UInt64; Size: Integer);
begin
  // As SlowWrite does them: the word of the queue at bit 5, index at bits
  // 4..2 (a 64-bit write fills two).
  if ((Address and $FC000000) = $E0000000) and ((Address and Cardinal(Size - 1)) = 0) and not FLenient then
  begin
    Inc(FSideEffects);
    var Q := (Address shr 5) and 1;
    var Index := (Address shr 2) and 7;
    S.SQ[Q, Index] := Cardinal(Value);
    if Size = 8 then
      S.SQ[Q, (Index + 1) and 7] := Cardinal(Value shr 32);
    Exit;
  end;
  if FTLBChunks <> nil then
    TranslatedWrite(Address, Value, Size)
  else
    SlowWrite(Address, Value, Size);
end;

procedure TSH4.TranslatedWrite(Address: Cardinal; Value: UInt64; Size: Integer);
begin
  var Page: PSH4TLBPage := nil;
  if (FFastWrite <> nil) and (Address < $80000000) then
    Page := FFastWrite[Address shr 12];
  if Page = nil then
  begin
    Page := TLBPage(Address);
    if (Page <> nil) and (Page.Write <> nil) and (Address < $80000000) then
      FastFill(Address, nil, Page);
  end;
  if (Page <> nil) and (Page.Write <> nil) and ((Address and Cardinal(Size - 1)) = 0) then
  begin
    var H := Page.Write + (Address and $FFF);
    if FJournalOn then
      JournalHost(Address, H, Page.Gen, Page.Phys or (Address and $FFF), Size);
    case Size of
      1: H^ := Byte(Value);
      2: PWord(H)^ := Word(Value);
      4: PCardinal(H)^ := Cardinal(Value);
    else
      PUInt64(H)^ := Value;
    end;
    Inc(Page.Gen^);
  end
  else
    SlowWrite(Address, Value, Size);
end;

function TSH4.SlowRead(Address: Cardinal; Size: Integer): UInt64;
begin
  // Translated RAM first: most data accesses of programs using the MMU.
  if FTLBChunks <> nil then
  begin
    var Page := TLBPage(Address);
    if (Page <> nil) and ((Address and Cardinal(Size - 1)) = 0) then
      if Page.Read <> nil then
      begin
        var H := Page.Read + (Address and $FFF);
        case Size of
          1: Result := H^;
          2: Result := PWord(H)^;
          4: Result := PCardinal(H)^;
        else
          Result := PUInt64(H)^;
        end;
        Exit;
      end
      else if (Page.Flags and SH4PageDeviceRead) <> 0 then
      begin
        Inc(FSideEffects);
        var Physical := Page.Phys or (Address and $FFF);
        if Physical >= $1C000000 then
          Exit(ReadControl(Physical or $E0000000, Size));
        Exit(FBus.Read(FBus.User, Physical, Size));
      end;
  end;
  Inc(FSideEffects);
  Result := 0;
  if FLenient then
    Exit(FBus.Read(FBus.User, Address and $1FFFFFFF, Size));
  if (Address and Cardinal(Size - 1)) <> 0 then
  begin
    S.TEA := Address;
    S.EXPEVT := SH4ExcAddressRead;
    FFault := True;
    Exit;
  end;
  if Address >= $E0000000 then
  begin
    if Address < $E4000000 then
    begin
      // Store queues read back their contents.
      var Q := (Address shr 5) and 1;
      var Index := (Address shr 2) and 7;
      if Size = 8 then
        Result := S.SQ[Q, Index] or (UInt64(S.SQ[Q, (Index + 1) and 7]) shl 32)
      else
        Result := S.SQ[Q, Index];
      Exit;
    end;
    if Address >= $F0000000 then
      Exit(ReadControl(Address, Size));
    Exit;
  end;
  if ((Address and $FC000000) = $7C000000) and ((S.CCR and $21) = $21) then
  begin
    var Offset := OCRAMOffset(Address, S.CCR);
    case Size of
      1: Result := S.OCRAM[Offset];
      2: Result := PWord(@S.OCRAM[Offset])^;
      4: Result := PCardinal(@S.OCRAM[Offset])^;
    else
      Result := PUInt64(@S.OCRAM[Offset])^;
    end;
    Exit;
  end;
  var Physical: Cardinal;
  if not Translate(Address, False, Physical) then
    Exit;
  if FTLBEntry >= 0 then
    TLBFill(Address, Physical, False);
  if Physical >= $1C000000 then
    Exit(ReadControl(Physical or $E0000000, Size));
  var P := FBus.ReadPages[Physical shr 16];
  if P <> nil then
  begin
    P := P + (Physical and $FFFF);
    case Size of
      1: Result := P^;
      2: Result := PWord(P)^;
      4: Result := PCardinal(P)^;
    else
      Result := PUInt64(P)^;
    end;
    Exit;
  end;
  Result := FBus.Read(FBus.User, Physical, Size);
end;

procedure TSH4.SlowWrite(Address: Cardinal; Value: UInt64; Size: Integer);
begin
  // Translated RAM first: most data accesses of programs using the MMU.
  if FTLBChunks <> nil then
  begin
    var Page := TLBPage(Address);
    if (Page <> nil) and ((Address and Cardinal(Size - 1)) = 0) then
      if Page.Write <> nil then
      begin
        var H := Page.Write + (Address and $FFF);
        if FJournalOn then
          JournalHost(Address, H, Page.Gen, Page.Phys or (Address and $FFF), Size);
        case Size of
          1: H^ := Byte(Value);
          2: PWord(H)^ := Word(Value);
          4: PCardinal(H)^ := Cardinal(Value);
        else
          PUInt64(H)^ := Value;
        end;
        Inc(Page.Gen^);
        Exit;
      end
      else if (Page.Flags and SH4PageDeviceWrite) <> 0 then
      begin
        Inc(FSideEffects);
        var Physical := Page.Phys or (Address and $FFF);
        if Physical >= $1C000000 then
          WriteControl(Physical or $E0000000, Cardinal(Value), Size)
        else
          FBus.Write(FBus.User, Physical, Value, Size);
        Exit;
      end;
  end;
  Inc(FSideEffects);
  if FLenient then
  begin
    FBus.Write(FBus.User, Address and $1FFFFFFF, Value, Size);
    Exit;
  end;
  if (Address and Cardinal(Size - 1)) <> 0 then
  begin
    S.TEA := Address;
    S.EXPEVT := SH4ExcAddressWrite;
    FFault := True;
    Exit;
  end;
  if Address >= $E0000000 then
  begin
    if Address < $E4000000 then
    begin
      var Q := (Address shr 5) and 1;
      var Index := (Address shr 2) and 7;
      if Size = 8 then
      begin
        S.SQ[Q, Index] := Cardinal(Value);
        S.SQ[Q, (Index + 1) and 7] := Cardinal(Value shr 32);
      end
      else
        S.SQ[Q, Index] := Cardinal(Value);
      Exit;
    end;
    if Address >= $F0000000 then
      WriteControl(Address, Cardinal(Value), Size);
    Exit;
  end;
  if ((Address and $FC000000) = $7C000000) and ((S.CCR and $21) = $21) then
  begin
    var Offset := OCRAMOffset(Address, S.CCR);
    case Size of
      1: S.OCRAM[Offset] := Byte(Value);
      2: PWord(@S.OCRAM[Offset])^ := Word(Value);
      4: PCardinal(@S.OCRAM[Offset])^ := Cardinal(Value);
    else
      PUInt64(@S.OCRAM[Offset])^ := Value;
    end;
    Exit;
  end;
  var Physical: Cardinal;
  if not Translate(Address, True, Physical) then
    Exit;
  if FTLBEntry >= 0 then
    TLBFill(Address, Physical, True);
  if Physical >= $1C000000 then
  begin
    WriteControl(Physical or $E0000000, Cardinal(Value), Size);
    Exit;
  end;
  var P := FBus.WritePages[Physical shr 16];
  if P <> nil then
  begin
    P := P + (Physical and $FFFF);
    case Size of
      1: P^ := Byte(Value);
      2: PWord(P)^ := Word(Value);
      4: PCardinal(P)^ := Cardinal(Value);
    else
      PUInt64(P)^ := Value;
    end;
    var G := FBus.Gens[Physical shr 16];
    if G <> nil then
      Inc(G[(Physical shr 12) and 15]);
    Exit;
  end;
  FBus.Write(FBus.User, Physical, Value, Size);
end;

procedure TSH4.StoreQueueFlush(Address: Cardinal);
begin
  Inc(FSideEffects);
  var Q := (Address shr 5) and 1;
  var Target: Cardinal;
  if (S.MMUCR and 1) <> 0 then
  begin
    if not Translate(Address, True, Target) then
      Exit;
    Target := Target and $1FFFFFE0;
  end
  else
  begin
    var QACR := S.QACR0;
    if Q <> 0 then
      QACR := S.QACR1;
    Target := ((QACR and $1C) shl 24) or (Address and $03FFFFE0);
  end;
  var P := FBus.WritePages[Target shr 16];
  if P <> nil then
  begin
    Move(S.SQ[Q, 0], (P + (Target and $FFFF))^, 32);
    var G := FBus.Gens[Target shr 16];
    if G <> nil then
      Inc(G[(Target shr 12) and 15]);
  end
  else
    FBus.Burst(FBus.User, Target, @S.SQ[Q, 0], 8);
end;

function TSH4.ReadControl(Address: Cardinal; Size: Integer): Cardinal;
begin
  Result := 0;
  case Address shr 24 of
    $F2, $F3:
      begin
        // ITLB address/data arrays.
        var E := S.ITLB[(Address shr 8) and 3];
        if (Address shr 24) = $F2 then
          Result := (E.VPN and $FFFFFC00) or ((E.Flags shr 8) and 1) shl 8 or E.ASID
        else
          Result := (E.PPN and $1FFFFC00) or (E.Flags and $1FF);
      end;
    $F6, $F7:
      begin
        var E := S.UTLB[(Address shr 8) and 63];
        if (Address shr 24) = $F6 then
          Result := (E.VPN and $FFFFFC00) or (((E.Flags shr 2) and 1) shl 9) or (((E.Flags shr 8) and 1) shl 8) or E.ASID
        else if (Address and $00800000) = 0 then
          Result := (E.PPN and $1FFFFC00) or (E.Flags and $1FF)
        else
          Result := E.PTEA;
      end;
    $FF, $1F:
      case Address and $00FFFFFF of
        $000000: Result := S.PTEH;
        $000004: Result := S.PTEL;
        $000008: Result := S.TTB;
        $00000C: Result := S.TEA;
        $000010: Result := S.MMUCR;
        $000014: Result := S.BASRA;
        $000018: Result := S.BASRB;
        $00001C: Result := S.CCR;
        $000020: Result := S.TRA;
        $000024: Result := S.EXPEVT;
        $000028: Result := S.INTEVT;
        $000034: Result := S.PTEA;
        $000038: Result := S.QACR0;
        $00003C: Result := S.QACR1;
      else
        if Assigned(FBus.OnChipRead) then
          Result := FBus.OnChipRead(FBus.OnChipUser, (Address and $00FFFFFF) or $FF000000, Size);
      end;
  end;
  case Size of
    1: Result := Result and $FF;
    2: Result := Result and $FFFF;
  end;
end;

procedure TSH4.WriteControl(Address, Value: Cardinal; Size: Integer);
begin
  case Address shr 24 of
    $F2, $F3:
      begin
        var Index := (Address shr 8) and 3;
        if (Address shr 24) = $F2 then
        begin
          S.ITLB[Index].VPN := Value and $FFFFFC00;
          S.ITLB[Index].ASID := Value and $FF;
          S.ITLB[Index].Flags := (S.ITLB[Index].Flags and not Cardinal($100)) or ((Value and $100));
        end
        else
        begin
          S.ITLB[Index].PPN := Value and $1FFFFC00;
          S.ITLB[Index].Flags := Value and $1FF;
        end;
      end;
    $F6, $F7:
      begin
        var Index := (Address shr 8) and 63;
        if (Address shr 24) = $F6 then
        begin
          // Non-associative write (A bit 7 = 0); associative writes update V/D of the matching entry.
          if (Address and $80) = 0 then
          begin
            S.UTLB[Index].VPN := Value and $FFFFFC00;
            S.UTLB[Index].ASID := Value and $FF;
            S.UTLB[Index].Flags := (S.UTLB[Index].Flags and not Cardinal($104)) or
              (Value and $100) or ((Value shr 7) and 4);
          end
          else
            AssociativeWrite(Value);
        end
        else if (Address and $00800000) = 0 then
        begin
          S.UTLB[Index].PPN := Value and $1FFFFC00;
          S.UTLB[Index].Flags := Value and $1FF;
        end
        else
          S.UTLB[Index].PTEA := Value and $F;
        UpdateUTLBKey(Index);
        TLBFlush;
      end;
    $FF, $1F:
      case Address and $00FFFFFF of
        $000000:
          begin
            // Another address space: cached translations keep theirs (see
            // TLBPage); code blocks check their mapping again.
            if ((S.PTEH xor Value) and $FF) <> 0 then
            begin
              Inc(FTLBEpoch);
              S.PTEH := Value and $FFFFFCFF;
              FastClear;
            end;
            S.PTEH := Value and $FFFFFCFF;
          end;
        $000004: S.PTEL := Value and $1FFFFDFF;
        $000008: S.TTB := Value;
        $00000C: S.TEA := Value;
        $000010:
          begin
            var Old := S.MMUCR;
            S.MMUCR := Value and $FCFCFF05;
            if (Value and 4) <> 0 then
            begin
              // TI: invalidate all TLB entries.
              for var I := 0 to 63 do
                S.UTLB[I].Flags := S.UTLB[I].Flags and not Cardinal($100);
              for var I := 0 to 3 do
                S.ITLB[I].Flags := S.ITLB[I].Flags and not Cardinal($100);
              UpdateUTLBKeys;
            end;
            // TI, AT or SV change what addresses map to.
            if ((Value and 4) <> 0) or (((Old xor S.MMUCR) and $101) <> 0) then
              TLBFlush;
            if ((Old xor S.MMUCR) and 1) <> 0 then
            begin
              BuildMaps;
              InvalidateBlocks;
            end;
          end;
        $000014: S.BASRA := Value and $FF;
        $000018: S.BASRB := Value and $FF;
        $00001C:
          begin
            S.CCR := Value and $000089AF;
            S.CCR := S.CCR and not Cardinal($0808); // ICI/OCI read as 0
          end;
        $000020: S.TRA := Value and $3FC;
        $000024: S.EXPEVT := Value and $FFF;
        $000028: S.INTEVT := Value and $FFF;
        $000034: S.PTEA := Value and $F;
        $000038: S.QACR0 := Value and $1C;
        $00003C: S.QACR1 := Value and $1C;
      else
        if Assigned(FBus.OnChipWrite) then
          FBus.OnChipWrite(FBus.OnChipUser, (Address and $00FFFFFF) or $FF000000, Value, Size);
      end;
  end;
end;

{ Registers }

procedure TSH4.SwapBanks;
begin
  for var I := 0 to 7 do
  begin
    var T := S.R[I];
    S.R[I] := S.RBank[I];
    S.RBank[I] := T;
  end;
end;

procedure TSH4.SwapFPBanks;
begin
  var T := S.FR;
  S.FR := S.XF;
  S.XF := T;
end;

function TSH4.GetSRValue: Cardinal;
begin
  Result := S.SR or S.T;
end;

function TSH4.SRValue: Cardinal;
begin
  Result := GetSRValue;
end;

procedure TSH4.SetSRValue(Value: Cardinal);
begin
  Value := Value and SH4SRWriteMask;
  // RB reads as 0 outside privileged mode (SingleStepTests).
  if (Value and SRMD) = 0 then
    Value := Value and not Cardinal(SRRB);
  // R0..R7 hold bank 1 only while both MD and RB are set.
  var OldBank := (S.SR and (SRMD or SRRB)) = (SRMD or SRRB);
  var NewBank := (Value and (SRMD or SRRB)) = (SRMD or SRRB);
  if OldBank <> NewBank then
    SwapBanks;
  S.T := Value and SRT;
  S.SR := Value and not Cardinal(SRT);
  if FFastRead <> nil then
    FastSelect;
end;

procedure TSH4.SetSR(Value: Cardinal);
begin
  SetSRValue(Value);
end;

procedure TSH4.SetFPSCRValue(Value: Cardinal);
begin
  Value := Value and SH4FPSCRMask;
  if ((S.FPSCR xor Value) and FPSCRFR) <> 0 then
    SwapFPBanks;
  var RoundChanged := ((S.FPSCR xor Value) and 3) <> 0;
  S.FPSCR := Value;
  if RoundChanged then
    ApplyHostRounding;
end;

procedure TSH4.SetFPSCR(Value: Cardinal);
begin
  SetFPSCRValue(Value);
end;

procedure TSH4.ApplyHostRounding;
begin
  if (S.FPSCR and 3) = 1 then
    SetRoundMode(rmTruncate)
  else
    SetRoundMode(rmNearest);
end;

function TSH4.Mode: Cardinal;
begin
  // ModeMD (SR bit 30), ModeFD (SR bit 15), ModePR and ModeSZ (FPSCR bits 19, 20).
  Result := ((S.SR shr 30) and ModeMD) or ((S.SR shr 14) and ModeFD) or ((S.FPSCR shr 17) and (ModePR or ModeSZ));
end;

procedure TSH4.EnterException(Code, Offset, ReturnPC: Cardinal);
begin
  Inc(FSideEffects);
  if Offset <> $600 then
  begin
    if ExceptionCount = 0 then
    begin
      FirstExceptionPC := ReturnPC;
      FirstExceptionCode := Code;
      FirstExceptionPR := S.PR;
    end;
    Inc(ExceptionCount);
  end;
  S.SPC := ReturnPC;
  S.SSR := GetSRValue;
  S.SGR := S.R[15];
  SetSRValue(GetSRValue or SRMD or SRRB or SRBL);
  S.PC := S.VBR + Offset;
  S.DelaySlot := False;
  S.RTEPending := False;
  S.Sleeping := False;
end;

procedure TSH4.Fault(Code: Cardinal; const I: TSH4Inst; Slot: Boolean);
begin
  // The faulting instruction (or the branch owning a delay slot) restarts.
  var At := I.Addr;
  if Slot then
    At := At - 2;
  S.EXPEVT := Code;
  var Offset: Cardinal := $100;
  if (Code = SH4ExcTLBMissRead) or (Code = SH4ExcTLBMissWrite) then
    Offset := $400;
  EnterException(Code, Offset, At);
end;

{ Decoder }

function SignExtend8(V: Cardinal): Cardinal; inline;
begin
  Result := Cardinal(Integer(ShortInt(Byte(V))));
end;

function SignExtend12(V: Cardinal): Cardinal; inline;
begin
  V := V and $FFF;
  if (V and $800) <> 0 then
    Result := V or $FFFFF000
  else
    Result := V;
end;

function SignExtend16(V: Cardinal): Cardinal; inline;
begin
  Result := Cardinal(Integer(SmallInt(Word(V))));
end;

function TSH4.Decode(Op: Word; Address, AMode: Cardinal; Slot: Boolean; out I: TSH4Inst): Boolean;
var
  K: TOp;
  N, M: Integer;
  Imm: Cardinal;
  Privileged, FPU, Branch, Delayed, Ends: Boolean;
  PR, SZ: Boolean;
begin
  N := (Op shr 8) and 15;
  M := (Op shr 4) and 15;
  Imm := 0;
  K := oIllegal;
  Privileged := False;
  FPU := False;
  Branch := False;
  Delayed := False;
  Ends := False;
  PR := (AMode and ModePR) <> 0;
  SZ := (AMode and ModeSZ) <> 0;
  case Op shr 12 of
    0:
      case Op and $F of
        2:
          if (M and 8) <> 0 then
          begin
            K := oSTCBANK;
            M := M and 7;
            Privileged := True;
          end
          else
            case M of
              0: begin K := oSTCSR; Privileged := True; end;
              1: K := oSTCGBR;
              2: begin K := oSTCVBR; Privileged := True; end;
              3: begin K := oSTCSSR; Privileged := True; end;
              4: begin K := oSTCSPC; Privileged := True; end;
            end;
        3:
          case M of
            0: begin K := oBSRF; Branch := True; Delayed := True; end;
            2: begin K := oBRAF; Branch := True; Delayed := True; end;
            8: K := oPREF;
            9, 10, 11: K := oOCB;
            12: K := oMOVCAL;
          end;
        4: K := oMOVBS0;
        5: K := oMOVWS0;
        6: K := oMOVLS0;
        7: K := oMULL;
        8:
          case Op of
            $0008: K := oCLRT;
            $0018: K := oSETT;
            $0028: K := oCLRMAC;
            $0038: begin K := oLDTLB; Privileged := True; Ends := True; end;
            $0048: K := oCLRS;
            $0058: K := oSETS;
          end;
        9:
          if Op = $0009 then
            K := oNOP
          else if Op = $0019 then
            K := oDIV0U
          else if M = 2 then
            K := oMOVT;
        10:
          case M of
            0: K := oSTSMACH;
            1: K := oSTSMACL;
            2: K := oSTSPR;
            3: begin K := oSTCSGR; Privileged := True; end;
            5: begin K := oSTSFPUL; FPU := True; end;
            6: begin K := oSTSFPSCR; FPU := True; end;
            15: begin K := oSTCDBR; Privileged := True; end;
          end;
        11:
          case Op of
            $000B: begin K := oRTS; Branch := True; Delayed := True; end;
            $001B: begin K := oSLEEP; Privileged := True; Ends := True; end;
            $002B: begin K := oRTE; Privileged := True; Branch := True; Delayed := True; end;
          end;
        12: K := oMOVBL0;
        13: K := oMOVWL0;
        14: K := oMOVLL0;
        15: K := oMACL;
      end;
    1:
      begin
        K := oMOVLS4;
        Imm := (Op and 15) * 4;
      end;
    2:
      case Op and 15 of
        0: K := oMOVBS;
        1: K := oMOVWS;
        2: K := oMOVLS;
        4: K := oMOVBM;
        5: K := oMOVWM;
        6: K := oMOVLM;
        7: K := oDIV0S;
        8: K := oTST;
        9: K := oAND;
        10: K := oXOR;
        11: K := oOR;
        12: K := oCMPSTR;
        13: K := oXTRCT;
        14: K := oMULUW;
        15: K := oMULSW;
      end;
    3:
      case Op and 15 of
        0: K := oCMPEQ;
        2: K := oCMPHS;
        3: K := oCMPGE;
        4: K := oDIV1;
        5: K := oDMULU;
        6: K := oCMPHI;
        7: K := oCMPGT;
        8: K := oSUB;
        10: K := oSUBC;
        11: K := oSUBV;
        12: K := oADD;
        13: K := oDMULS;
        14: K := oADDC;
        15: K := oADDV;
      end;
    4:
      case Op and 15 of
        0:
          case M of
            0: K := oSHLL;
            1: K := oDT;
            2: K := oSHAL;
          end;
        1:
          case M of
            0: K := oSHLR;
            1: K := oCMPPZ;
            2: K := oSHAR;
          end;
        2:
          case M of
            0: K := oSTSMMACH;
            1: K := oSTSMMACL;
            2: K := oSTSMPR;
            3: begin K := oSTCMSGR; Privileged := True; end;
            5: begin K := oSTSMFPUL; FPU := True; end;
            6: begin K := oSTSMFPSCR; FPU := True; end;
            15: begin K := oSTCMDBR; Privileged := True; end;
          end;
        3:
          if (M and 8) <> 0 then
          begin
            K := oSTCMBANK;
            M := M and 7;
            Privileged := True;
          end
          else
            case M of
              0: begin K := oSTCMSR; Privileged := True; end;
              1: K := oSTCMGBR;
              2: begin K := oSTCMVBR; Privileged := True; end;
              3: begin K := oSTCMSSR; Privileged := True; end;
              4: begin K := oSTCMSPC; Privileged := True; end;
            end;
        4:
          case M of
            0: K := oROTL;
            2: K := oROTCL;
          end;
        5:
          case M of
            0: K := oROTR;
            1: K := oCMPPL;
            2: K := oROTCR;
          end;
        6:
          case M of
            0: K := oLDSMMACH;
            1: K := oLDSMMACL;
            2: K := oLDSMPR;
            5: begin K := oLDSMFPUL; FPU := True; end;
            6: begin K := oLDSMFPSCR; FPU := True; Ends := True; end;
            15: begin K := oLDCMDBR; Privileged := True; end;
          end;
        7:
          if (M and 8) <> 0 then
          begin
            K := oLDCMBANK;
            M := M and 7;
            Privileged := True;
          end
          else
            case M of
              0: begin K := oLDCMSR; Privileged := True; Ends := True; end;
              1: K := oLDCMGBR;
              2: begin K := oLDCMVBR; Privileged := True; end;
              3: begin K := oLDCMSSR; Privileged := True; end;
              4: begin K := oLDCMSPC; Privileged := True; end;
            end;
        8:
          case M of
            0: K := oSHLL2;
            1: K := oSHLL8;
            2: K := oSHLL16;
          end;
        9:
          case M of
            0: K := oSHLR2;
            1: K := oSHLR8;
            2: K := oSHLR16;
          end;
        10:
          case M of
            0: K := oLDSMACH;
            1: K := oLDSMACL;
            2: K := oLDSPR;
            5: begin K := oLDSFPUL; FPU := True; end;
            6: begin K := oLDSFPSCR; FPU := True; Ends := True; end;
            15: begin K := oLDCDBR; Privileged := True; end;
          end;
        11:
          case M of
            0: begin K := oJSR; Branch := True; Delayed := True; end;
            1: K := oTASB;
            2: begin K := oJMP; Branch := True; Delayed := True; end;
          end;
        12: K := oSHAD;
        13: K := oSHLD;
        14:
          if (M and 8) <> 0 then
          begin
            K := oLDCBANK;
            M := M and 7;
            Privileged := True;
          end
          else
            case M of
              0: begin K := oLDCSR; Privileged := True; Ends := True; end;
              1: K := oLDCGBR;
              2: begin K := oLDCVBR; Privileged := True; end;
              3: begin K := oLDCSSR; Privileged := True; end;
              4: begin K := oLDCSPC; Privileged := True; end;
            end;
        15: K := oMACW;
      end;
    5:
      begin
        K := oMOVLL4;
        Imm := (Op and 15) * 4;
      end;
    6:
      case Op and 15 of
        0: K := oMOVBL;
        1: K := oMOVWL;
        2: K := oMOVLL;
        3: K := oMOV;
        4: K := oMOVBP;
        5: K := oMOVWP;
        6: K := oMOVLP;
        7: K := oNOT;
        8: K := oSWAPB;
        9: K := oSWAPW;
        10: K := oNEGC;
        11: K := oNEG;
        12: K := oEXTUB;
        13: K := oEXTUW;
        14: K := oEXTSB;
        15: K := oEXTSW;
      end;
    7:
      begin
        K := oADDI;
        Imm := SignExtend8(Op);
      end;
    8:
      case N of
        0: begin K := oMOVBS4; Imm := Op and 15; end;
        1: begin K := oMOVWS4; Imm := (Op and 15) * 2; end;
        4: begin K := oMOVBL4; Imm := Op and 15; end;
        5: begin K := oMOVWL4; Imm := (Op and 15) * 2; end;
        8: begin K := oCMPEQI; Imm := SignExtend8(Op); end;
        9, 11, 13, 15:
          begin
            case N of
              9: K := oBT;
              11: K := oBF;
              13: K := oBTS;
            else
              K := oBFS;
            end;
            Branch := True;
            Delayed := N >= 13;
            Ends := not Delayed;
            Imm := Address + 4 + SignExtend8(Op) * 2;
          end;
      end;
    9:
      begin
        K := oMOVWPC;
        Imm := Address + 4 + (Op and $FF) * 2;
      end;
    10, 11:
      begin
        if (Op shr 12) = 10 then
          K := oBRA
        else
          K := oBSR;
        Branch := True;
        Delayed := True;
        Imm := Address + 4 + SignExtend12(Op) * 2;
      end;
    12:
      case N of
        0: begin K := oMOVBSG; Imm := Op and $FF; end;
        1: begin K := oMOVWSG; Imm := (Op and $FF) * 2; end;
        2: begin K := oMOVLSG; Imm := (Op and $FF) * 4; end;
        3: begin K := oTRAPA; Imm := Op and $FF; Branch := True; Ends := True; end;
        4: begin K := oMOVBLG; Imm := Op and $FF; end;
        5: begin K := oMOVWLG; Imm := (Op and $FF) * 2; end;
        6: begin K := oMOVLLG; Imm := (Op and $FF) * 4; end;
        7: begin K := oMOVA; Imm := (Address and $FFFFFFFC) + 4 + (Op and $FF) * 4; end;
        8: begin K := oTSTI; Imm := Op and $FF; end;
        9: begin K := oANDI; Imm := Op and $FF; end;
        10: begin K := oXORI; Imm := Op and $FF; end;
        11: begin K := oORI; Imm := Op and $FF; end;
        12: begin K := oTSTB; Imm := Op and $FF; end;
        13: begin K := oANDB; Imm := Op and $FF; end;
        14: begin K := oXORB; Imm := Op and $FF; end;
        15: begin K := oORB; Imm := Op and $FF; end;
      end;
    13:
      begin
        K := oMOVLPC;
        Imm := (Address and $FFFFFFFC) + 4 + (Op and $FF) * 4;
      end;
    14:
      begin
        K := oMOVI;
        Imm := SignExtend8(Op);
      end;
    15:
      begin
        FPU := True;
        case Op and 15 of
          0..5:
            begin
              if PR then
              begin
                case Op and 15 of
                  0: K := oDADD;
                  1: K := oDSUB;
                  2: K := oDMUL;
                  3: K := oDDIV;
                  4: K := oDCMPEQ;
                else
                  K := oDCMPGT;
                end;
                N := N and 14;
                M := M and 14;
              end
              else
              begin
                case Op and 15 of
                  0: K := oFADD;
                  1: K := oFSUB;
                  2: K := oFMUL;
                  3: K := oFDIV;
                  4: K := oFCMPEQ;
                else
                  K := oFCMPGT;
                end;
                N := N xor 1;
                M := M xor 1;
              end;
            end;
          6:
            if SZ then
              K := oFMOVDLD0
            else
            begin
              K := oFMOVLD0;
              N := N xor 1;
            end;
          7:
            if SZ then
              K := oFMOVDST0
            else
            begin
              K := oFMOVST0;
              M := M xor 1;
            end;
          8:
            if SZ then
              K := oFMOVDLD
            else
            begin
              K := oFMOVLD;
              N := N xor 1;
            end;
          9:
            if SZ then
              K := oFMOVDLDP
            else
            begin
              K := oFMOVLDP;
              N := N xor 1;
            end;
          10:
            if SZ then
              K := oFMOVDST
            else
            begin
              K := oFMOVST;
              M := M xor 1;
            end;
          11:
            if SZ then
              K := oFMOVDSTM
            else
            begin
              K := oFMOVSTM;
              M := M xor 1;
            end;
          12:
            if SZ then
              K := oFMOVD
            else
            begin
              K := oFMOV;
              N := N xor 1;
              M := M xor 1;
            end;
          13:
            case M of
              0: begin K := oFSTS; N := N xor 1; end;
              1: begin K := oFLDS; N := N xor 1; end;
              2:
                if PR then
                begin
                  K := oDFLOAT;
                  N := N and 14;
                end
                else
                begin
                  K := oFLOAT;
                  N := N xor 1;
                end;
              3:
                if PR then
                begin
                  K := oDFTRC;
                  N := N and 14;
                end
                else
                begin
                  K := oFTRC;
                  N := N xor 1;
                end;
              4:
                if PR then
                begin
                  K := oDNEG;
                  N := N and 14;
                end
                else
                begin
                  K := oFNEG;
                  N := N xor 1;
                end;
              5:
                if PR then
                begin
                  K := oDABS;
                  N := N and 14;
                end
                else
                begin
                  K := oFABS;
                  N := N xor 1;
                end;
              6:
                if PR then
                begin
                  K := oDSQRT;
                  N := N and 14;
                end
                else
                begin
                  K := oFSQRT;
                  N := N xor 1;
                end;
              7: begin K := oFSRRA; N := N xor 1; end;
              8: begin K := oFLDI0; N := N xor 1; end;
              9: begin K := oFLDI1; N := N xor 1; end;
              // Defined only for PR=1; PR=0 leaves state unchanged (SingleStepTests).
              10:
                if PR then
                begin
                  K := oFCNVSD;
                  N := N and 14;
                end
                else
                  K := oNOP;
              11:
                if PR then
                begin
                  K := oFCNVDS;
                  N := N and 14;
                end
                else
                  K := oNOP;
              14:
                begin
                  K := oFIPR;
                  N := ((Op shr 10) and 3) * 4;
                  M := ((Op shr 8) and 3) * 4;
                end;
              15:
                if (Op and $0300) = $0100 then
                begin
                  K := oFTRV;
                  N := ((Op shr 10) and 3) * 4;
                end
                else if (Op and $0100) = 0 then
                begin
                  K := oFSCA;
                  N := N and 14;
                end
                else if Op = $F3FD then
                begin
                  K := oFSCHG;
                  Ends := True;
                end
                else if Op = $FBFD then
                begin
                  K := oFRCHG;
                  Ends := True;
                end;
            end;
          14:
            begin
              K := oFMAC;
              N := N xor 1;
              M := M xor 1;
            end;
        end;
      end;
  end;

  if (K <> oIllegal) and Privileged and ((AMode and ModeMD) = 0) and not FLenient then
    K := oIllegal;
  if (K <> oIllegal) and FPU and ((AMode and ModeFD) <> 0) and not FLenient then
  begin
    if Slot then
      K := oSlotFPUDisabled
    else
      K := oFPUDisabled;
  end;
  if Slot and ((K = oIllegal) or Branch) then
    K := oSlotIllegal;
  if K in [oIllegal, oSlotIllegal, oFPUDisabled, oSlotFPUDisabled] then
  begin
    Delayed := False;
    Ends := True;
  end;
  I.Kind := Ord(K);
  I.N := N;
  I.M := M;
  I.Imm := Imm;
  I.Addr := Address;
  I.Flags := 0;
  if Ends then
    I.Flags := I.Flags or IFEnd;
  if Delayed then
    I.Flags := I.Flags or IFDelayed;
  if Slot then
    I.Flags := I.Flags or IFSlot;
  Result := Delayed;
end;

{ FPU helpers }

function IsNaNBits(V: Cardinal): Boolean; inline;
begin
  Result := ((V and $7F800000) = $7F800000) and ((V and $007FFFFF) <> 0);
end;

function IsNaN64(V: UInt64): Boolean; inline;
begin
  Result := ((V and $7FF0000000000000) = $7FF0000000000000) and ((V and $000FFFFFFFFFFFFF) <> 0);
end;

function FlushBits(V: Cardinal): Cardinal; inline;
begin
  if (V and $7F800000) = 0 then
    Result := V and $80000000
  else
    Result := V;
end;

function FlushSingle(V: Single): Single; inline;
begin
  if (PCardinal(@V)^ and $7F800000) = 0 then
    PCardinal(@Result)^ := PCardinal(@V)^ and $80000000
  else
    Result := V;
end;

function SingleBits(V: Single): Cardinal; inline;
begin
  Result := PCardinal(@V)^;
end;

function BitsSingle(V: Cardinal): Single; inline;
begin
  Result := PSingle(@V)^;
end;

// Separate calls round every intermediate to single precision on x87 too.
function SingleProduct(A, B: Single): Single;
begin
  Result := A * B;
end;

// A*B is exact in double precision; the sum rounds once to double, then to single.
function FusedSingle(A, B, C: Single): Single;
begin
  Result := Double(A) * Double(B) + Double(C);
end;

function FlushDouble(V: Double): Double; inline;
begin
  if (PUInt64(@V)^ and $7FF0000000000000) = 0 then
    PUInt64(@Result)^ := PUInt64(@V)^ and $8000000000000000
  else
    Result := V;
end;

function RoundToSingle(V: Double): Single; inline;
begin
  Result := V;
end;

function SingleToInt(V: Single): Cardinal;
begin
  // FTRC: truncation; out of range and NaN saturate.
  var Bits := SingleBits(V);
  if IsNaNBits(Bits) then
    Exit($80000000);
  if V >= 2147483648.0 then
    Exit($7FFFFFFF);
  if V <= -2147483648.0 then
    Exit($80000000);
  Result := Cardinal(Integer(Trunc(V)));
end;

function DoubleToInt(V: Double): Cardinal;
begin
  var Bits := PUInt64(@V)^;
  if IsNaN64(Bits) then
    Exit($80000000);
  if V >= 2147483648.0 then
    Exit($7FFFFFFF);
  if V <= -2147483648.0 then
    Exit($80000000);
  Result := Cardinal(Integer(Trunc(V)));
end;

function Sar32(V: Cardinal; Count: Integer): Cardinal; inline;
begin
  if (V and $80000000) <> 0 then
    Result := not ((not V) shr Count)
  else
    Result := V shr Count;
end;

function SwapHalves(V: UInt64): UInt64; inline;
begin
  Result := (V shr 32) or (V shl 32);
end;

{ Executor }

procedure TSH4.Div1(N, M: Integer);
begin
  var OldQ := (S.SR shr 8) and 1;
  var MM := (S.SR shr 9) and 1;
  var Q := S.R[N] shr 31;
  var A := (S.R[N] shl 1) or S.T;
  // DIV1 Rn,Rn divides by the shifted value (SingleStepTests).
  var Divisor := S.R[M];
  if N = M then
    Divisor := A;
  var Tmp0 := A;
  var Tmp1: Cardinal;
  if OldQ = MM then
  begin
    A := A - Divisor;
    Tmp1 := Cardinal(Ord(A > Tmp0));
  end
  else
  begin
    A := A + Divisor;
    Tmp1 := Cardinal(Ord(A < Tmp0));
  end;
  // The manual's case table for old Q / M reduces to Q xor carry xor M.
  Q := Q xor Tmp1 xor MM;
  S.R[N] := A;
  S.SR := (S.SR and not Cardinal(SRQ)) or (Q shl 8);
  S.T := Cardinal(Ord(Q = MM));
end;

procedure TSH4.RotateDivide(const I: TSH4Inst);
begin
  var Pairs := Integer(I.Imm and $FFFF);
  var Ra := Integer(I.Imm shr 16);
  for var K := 1 to Pairs do
  begin
    if TOp(I.Kind) = oDIVROT then
      Div1(I.N, I.M);
    var V := S.R[Ra];
    S.R[Ra] := (V shl 1) or S.T;
    S.T := V shr 31;
    if TOp(I.Kind) = oROTDIV then
      Div1(I.N, I.M);
  end;
  Inc(FFusedExtra, Pairs * 2 - 1);
end;

procedure TSH4.FuseBlock(Insts: PSH4Inst; var Count: Integer);

  function Plain(const I: TSH4Inst): Boolean; inline;
  begin
    Result := (I.Flags and (IFEnd or IFDelayed or IFSlot)) = 0;
  end;

begin
  // ROTCL / DIV1 pairs with the same registers become one operation.
  var Output := 0;
  var K := 0;
  while K < Count do
  begin
    var Pairs := 0;
    var First := oNOP;
    if (K + 1 < Count) and Plain(Insts[K]) and Plain(Insts[K + 1]) then
    begin
      First := TOp(Insts[K].Kind);
      var Second := TOp(Insts[K + 1].Kind);
      if ((First = oROTCL) and (Second = oDIV1)) or ((First = oDIV1) and (Second = oROTCL)) then
      begin
        Pairs := 1;
        while (K + Pairs * 2 + 1 < Count) and Plain(Insts[K + Pairs * 2]) and Plain(Insts[K + Pairs * 2 + 1]) and
          (Insts[K + Pairs * 2].Kind = Insts[K].Kind) and (Insts[K + Pairs * 2].N = Insts[K].N) and
          (Insts[K + Pairs * 2].M = Insts[K].M) and (Insts[K + Pairs * 2 + 1].Kind = Insts[K + 1].Kind) and
          (Insts[K + Pairs * 2 + 1].N = Insts[K + 1].N) and (Insts[K + Pairs * 2 + 1].M = Insts[K + 1].M) do
          Inc(Pairs);
      end;
    end;
    if Pairs >= 2 then
    begin
      var Rotate := Insts[K];
      var Divide := Insts[K + 1];
      var Fused := Rotate;
      Fused.Kind := Ord(oROTDIV);
      if First = oDIV1 then
      begin
        Rotate := Insts[K + 1];
        Divide := Insts[K];
        Fused.Kind := Ord(oDIVROT);
      end;
      Fused.N := Divide.N;
      Fused.M := Divide.M;
      Fused.Imm := Cardinal(Pairs) or (Cardinal(Rotate.N) shl 16);
      Insts[Output] := Fused;
      Inc(K, Pairs * 2);
    end
    else
    begin
      Insts[Output] := Insts[K];
      Inc(K);
    end;
    Inc(Output);
  end;
  Count := Output;
end;

function TSH4.OpNOP(I: PSH4Inst): Boolean;
begin
  Result := False;
  ;
end;

function TSH4.OpMOV(I: PSH4Inst): Boolean;
var
  N, M: Integer;
begin
  Result := False;
  N := I.N;
  M := I.M;
  S.R[N] := S.R[M];
end;

function TSH4.OpMOVI(I: PSH4Inst): Boolean;
var
  N: Integer;
begin
  Result := False;
  N := I.N;
  S.R[N] := I.Imm;
end;

function TSH4.OpMOVWPC(I: PSH4Inst): Boolean;
var
  N: Integer;
  V: Cardinal;
begin
  N := I.N;
  V := Read16(I.Imm);
  if FFault then Exit(True);
  S.R[N] := SignExtend16(V);
  Result := FFault;
end;

function TSH4.OpMOVLPC(I: PSH4Inst): Boolean;
var
  N: Integer;
  V: Cardinal;
begin
  N := I.N;
  V := Read32(I.Imm);
  if FFault then Exit(True);
  S.R[N] := V;
  Result := FFault;
end;

function TSH4.OpMOVA(I: PSH4Inst): Boolean;
begin
  Result := False;
  S.R[0] := I.Imm;
end;

function TSH4.OpMOVBS(I: PSH4Inst): Boolean;
var
  N, M: Integer;
begin
  N := I.N;
  M := I.M;
  Write8(S.R[N], S.R[M]);
  Result := FFault;
end;

function TSH4.OpMOVWS(I: PSH4Inst): Boolean;
var
  N, M: Integer;
begin
  N := I.N;
  M := I.M;
  Write16(S.R[N], S.R[M]);
  Result := FFault;
end;

function TSH4.OpMOVLS(I: PSH4Inst): Boolean;
var
  N, M: Integer;
begin
  N := I.N;
  M := I.M;
  Write32(S.R[N], S.R[M]);
  Result := FFault;
end;

function TSH4.OpMOVBL(I: PSH4Inst): Boolean;
var
  N, M: Integer;
  V: Cardinal;
begin
  N := I.N;
  M := I.M;
  V := Read8(S.R[M]);
  if FFault then Exit(True);
  S.R[N] := SignExtend8(V);
  Result := FFault;
end;

function TSH4.OpMOVWL(I: PSH4Inst): Boolean;
var
  N, M: Integer;
  V: Cardinal;
begin
  N := I.N;
  M := I.M;
  V := Read16(S.R[M]);
  if FFault then Exit(True);
  S.R[N] := SignExtend16(V);
  Result := FFault;
end;

function TSH4.OpMOVLL(I: PSH4Inst): Boolean;
var
  N, M: Integer;
  V: Cardinal;
begin
  N := I.N;
  M := I.M;
  V := Read32(S.R[M]);
  if FFault then Exit(True);
  S.R[N] := V;
  Result := FFault;
end;

function TSH4.OpMOVBM(I: PSH4Inst): Boolean;
var
  N, M: Integer;
  A: Cardinal;
begin
  N := I.N;
  M := I.M;
  A := S.R[N] - 1;
  Write8(A, S.R[M]);
  if FFault then Exit(True);
  S.R[N] := A;
  Result := FFault;
end;

function TSH4.OpMOVWM(I: PSH4Inst): Boolean;
var
  N, M: Integer;
  A: Cardinal;
begin
  N := I.N;
  M := I.M;
  A := S.R[N] - 2;
  Write16(A, S.R[M]);
  if FFault then Exit(True);
  S.R[N] := A;
  Result := FFault;
end;

function TSH4.OpMOVLM(I: PSH4Inst): Boolean;
var
  N, M: Integer;
  A: Cardinal;
begin
  N := I.N;
  M := I.M;
  A := S.R[N] - 4;
  Write32(A, S.R[M]);
  if FFault then Exit(True);
  S.R[N] := A;
  Result := FFault;
end;

function TSH4.OpMOVBP(I: PSH4Inst): Boolean;
var
  N, M: Integer;
  V: Cardinal;
begin
  N := I.N;
  M := I.M;
  V := Read8(S.R[M]);
  if FFault then Exit(True);
  if N <> M then
    S.R[M] := S.R[M] + 1;
  S.R[N] := SignExtend8(V);
  Result := FFault;
end;

function TSH4.OpMOVWP(I: PSH4Inst): Boolean;
var
  N, M: Integer;
  V: Cardinal;
begin
  N := I.N;
  M := I.M;
  V := Read16(S.R[M]);
  if FFault then Exit(True);
  if N <> M then
    S.R[M] := S.R[M] + 2;
  S.R[N] := SignExtend16(V);
  Result := FFault;
end;

function TSH4.OpMOVLP(I: PSH4Inst): Boolean;
var
  N, M: Integer;
  V: Cardinal;
begin
  N := I.N;
  M := I.M;
  V := Read32(S.R[M]);
  if FFault then Exit(True);
  if N <> M then
    S.R[M] := S.R[M] + 4;
  S.R[N] := V;
  Result := FFault;
end;

function TSH4.OpMOVBS0(I: PSH4Inst): Boolean;
var
  N, M: Integer;
begin
  N := I.N;
  M := I.M;
  Write8(S.R[N] + S.R[0], S.R[M]);
  Result := FFault;
end;

function TSH4.OpMOVWS0(I: PSH4Inst): Boolean;
var
  N, M: Integer;
begin
  N := I.N;
  M := I.M;
  Write16(S.R[N] + S.R[0], S.R[M]);
  Result := FFault;
end;

function TSH4.OpMOVLS0(I: PSH4Inst): Boolean;
var
  N, M: Integer;
begin
  N := I.N;
  M := I.M;
  Write32(S.R[N] + S.R[0], S.R[M]);
  Result := FFault;
end;

function TSH4.OpMOVBL0(I: PSH4Inst): Boolean;
var
  N, M: Integer;
  V: Cardinal;
begin
  N := I.N;
  M := I.M;
  V := Read8(S.R[M] + S.R[0]);
  if FFault then Exit(True);
  S.R[N] := SignExtend8(V);
  Result := FFault;
end;

function TSH4.OpMOVWL0(I: PSH4Inst): Boolean;
var
  N, M: Integer;
  V: Cardinal;
begin
  N := I.N;
  M := I.M;
  V := Read16(S.R[M] + S.R[0]);
  if FFault then Exit(True);
  S.R[N] := SignExtend16(V);
  Result := FFault;
end;

function TSH4.OpMOVLL0(I: PSH4Inst): Boolean;
var
  N, M: Integer;
  V: Cardinal;
begin
  N := I.N;
  M := I.M;
  V := Read32(S.R[M] + S.R[0]);
  if FFault then Exit(True);
  S.R[N] := V;
  Result := FFault;
end;

function TSH4.OpMOVBS4(I: PSH4Inst): Boolean;
var
  M: Integer;
begin
  M := I.M;
  Write8(S.R[M] + I.Imm, S.R[0]);
  Result := FFault;
end;

function TSH4.OpMOVWS4(I: PSH4Inst): Boolean;
var
  M: Integer;
begin
  M := I.M;
  Write16(S.R[M] + I.Imm, S.R[0]);
  Result := FFault;
end;

function TSH4.OpMOVLS4(I: PSH4Inst): Boolean;
var
  N, M: Integer;
begin
  N := I.N;
  M := I.M;
  Write32(S.R[N] + I.Imm, S.R[M]);
  Result := FFault;
end;

function TSH4.OpMOVBL4(I: PSH4Inst): Boolean;
var
  M: Integer;
  V: Cardinal;
begin
  M := I.M;
  V := Read8(S.R[M] + I.Imm);
  if FFault then Exit(True);
  S.R[0] := SignExtend8(V);
  Result := FFault;
end;

function TSH4.OpMOVWL4(I: PSH4Inst): Boolean;
var
  M: Integer;
  V: Cardinal;
begin
  M := I.M;
  V := Read16(S.R[M] + I.Imm);
  if FFault then Exit(True);
  S.R[0] := SignExtend16(V);
  Result := FFault;
end;

function TSH4.OpMOVLL4(I: PSH4Inst): Boolean;
var
  N, M: Integer;
  V: Cardinal;
begin
  N := I.N;
  M := I.M;
  V := Read32(S.R[M] + I.Imm);
  if FFault then Exit(True);
  S.R[N] := V;
  Result := FFault;
end;

function TSH4.OpMOVBSG(I: PSH4Inst): Boolean;
begin
  Write8(S.GBR + I.Imm, S.R[0]);
  Result := FFault;
end;

function TSH4.OpMOVWSG(I: PSH4Inst): Boolean;
begin
  Write16(S.GBR + I.Imm, S.R[0]);
  Result := FFault;
end;

function TSH4.OpMOVLSG(I: PSH4Inst): Boolean;
begin
  Write32(S.GBR + I.Imm, S.R[0]);
  Result := FFault;
end;

function TSH4.OpMOVBLG(I: PSH4Inst): Boolean;
var
  V: Cardinal;
begin
  V := Read8(S.GBR + I.Imm);
  if FFault then Exit(True);
  S.R[0] := SignExtend8(V);
  Result := FFault;
end;

function TSH4.OpMOVWLG(I: PSH4Inst): Boolean;
var
  V: Cardinal;
begin
  V := Read16(S.GBR + I.Imm);
  if FFault then Exit(True);
  S.R[0] := SignExtend16(V);
  Result := FFault;
end;

function TSH4.OpMOVLLG(I: PSH4Inst): Boolean;
var
  V: Cardinal;
begin
  V := Read32(S.GBR + I.Imm);
  if FFault then Exit(True);
  S.R[0] := V;
  Result := FFault;
end;

function TSH4.OpMOVT(I: PSH4Inst): Boolean;
var
  N: Integer;
begin
  Result := False;
  N := I.N;
  S.R[N] := S.T;
end;

function TSH4.OpSWAPB(I: PSH4Inst): Boolean;
var
  N, M: Integer;
  V: Cardinal;
begin
  Result := False;
  N := I.N;
  M := I.M;
  V := S.R[M];
  S.R[N] := (V and $FFFF0000) or ((V and $FF) shl 8) or ((V shr 8) and $FF);
end;

function TSH4.OpSWAPW(I: PSH4Inst): Boolean;
var
  N, M: Integer;
  V: Cardinal;
begin
  Result := False;
  N := I.N;
  M := I.M;
  V := S.R[M];
  S.R[N] := (V shl 16) or (V shr 16);
end;

function TSH4.OpXTRCT(I: PSH4Inst): Boolean;
var
  N, M: Integer;
begin
  Result := False;
  N := I.N;
  M := I.M;
  S.R[N] := (S.R[N] shr 16) or (S.R[M] shl 16);
end;

function TSH4.OpADD(I: PSH4Inst): Boolean;
var
  N, M: Integer;
begin
  Result := False;
  N := I.N;
  M := I.M;
  S.R[N] := S.R[N] + S.R[M];
end;

function TSH4.OpADDI(I: PSH4Inst): Boolean;
var
  N: Integer;
begin
  Result := False;
  N := I.N;
  S.R[N] := S.R[N] + I.Imm;
end;

function TSH4.OpADDC(I: PSH4Inst): Boolean;
var
  N, M: Integer;
  A, B, V: Cardinal;
begin
  Result := False;
  N := I.N;
  M := I.M;
  A := S.R[N];
  B := A + S.R[M];
  V := B + S.T;
  S.T := Cardinal(Ord((A > B) or (B > V)));
  S.R[N] := V;
end;

function TSH4.OpADDV(I: PSH4Inst): Boolean;
var
  N, M: Integer;
  A, B, V: Cardinal;
begin
  Result := False;
  N := I.N;
  M := I.M;
  A := S.R[N];
  B := S.R[M];
  V := A + B;
  S.T := ((not (A xor B)) and (A xor V)) shr 31;
  S.R[N] := V;
end;

function TSH4.OpCMPEQ(I: PSH4Inst): Boolean;
var
  N, M: Integer;
begin
  Result := False;
  N := I.N;
  M := I.M;
  S.T := Cardinal(Ord(S.R[N] = S.R[M]));
end;

function TSH4.OpCMPEQI(I: PSH4Inst): Boolean;
begin
  Result := False;
  S.T := Cardinal(Ord(S.R[0] = I.Imm));
end;

function TSH4.OpCMPHS(I: PSH4Inst): Boolean;
var
  N, M: Integer;
begin
  Result := False;
  N := I.N;
  M := I.M;
  S.T := Cardinal(Ord(S.R[N] >= S.R[M]));
end;

function TSH4.OpCMPGE(I: PSH4Inst): Boolean;
var
  N, M: Integer;
begin
  Result := False;
  N := I.N;
  M := I.M;
  S.T := Cardinal(Ord(Integer(S.R[N]) >= Integer(S.R[M])));
end;

function TSH4.OpCMPHI(I: PSH4Inst): Boolean;
var
  N, M: Integer;
begin
  Result := False;
  N := I.N;
  M := I.M;
  S.T := Cardinal(Ord(S.R[N] > S.R[M]));
end;

function TSH4.OpCMPGT(I: PSH4Inst): Boolean;
var
  N, M: Integer;
begin
  Result := False;
  N := I.N;
  M := I.M;
  S.T := Cardinal(Ord(Integer(S.R[N]) > Integer(S.R[M])));
end;

function TSH4.OpCMPPZ(I: PSH4Inst): Boolean;
var
  N: Integer;
begin
  Result := False;
  N := I.N;
  S.T := Cardinal(Ord(Integer(S.R[N]) >= 0));
end;

function TSH4.OpCMPPL(I: PSH4Inst): Boolean;
var
  N: Integer;
begin
  Result := False;
  N := I.N;
  S.T := Cardinal(Ord(Integer(S.R[N]) > 0));
end;

function TSH4.OpCMPSTR(I: PSH4Inst): Boolean;
var
  N, M: Integer;
  V: Cardinal;
begin
  Result := False;
  N := I.N;
  M := I.M;
  V := S.R[N] xor S.R[M];
  S.T := Cardinal(Ord(((V and $FF) = 0) or ((V and $FF00) = 0) or
    ((V and $FF0000) = 0) or ((V and $FF000000) = 0)));
end;

function TSH4.OpDIV0S(I: PSH4Inst): Boolean;
var
  N, M: Integer;
begin
  Result := False;
  N := I.N;
  M := I.M;
  var Q := S.R[N] shr 31;
  var MM := S.R[M] shr 31;
  S.SR := (S.SR and not Cardinal(SRQ or SRM)) or (Q shl 8) or (MM shl 9);
  S.T := Q xor MM;
end;

function TSH4.OpDIV0U(I: PSH4Inst): Boolean;
begin
  Result := False;
  S.SR := S.SR and not Cardinal(SRQ or SRM);
  S.T := 0;
end;

function TSH4.OpDIV1(I: PSH4Inst): Boolean;
var
  N, M: Integer;
begin
  Result := False;
  N := I.N;
  M := I.M;
  Div1(N, M);
end;

function TSH4.OpROTDIV(I: PSH4Inst): Boolean;
begin
  Result := False;
  RotateDivide(I^);
end;

function TSH4.OpDMULS(I: PSH4Inst): Boolean;
var
  N, M: Integer;
  P64: Int64;
begin
  Result := False;
  N := I.N;
  M := I.M;
  P64 := Int64(Integer(S.R[N])) * Int64(Integer(S.R[M]));
  S.MACH := Cardinal(UInt64(P64) shr 32);
  S.MACL := Cardinal(P64);
end;

function TSH4.OpDMULU(I: PSH4Inst): Boolean;
var
  N, M: Integer;
  V64: UInt64;
begin
  Result := False;
  N := I.N;
  M := I.M;
  V64 := UInt64(S.R[N]) * UInt64(S.R[M]);
  S.MACH := Cardinal(V64 shr 32);
  S.MACL := Cardinal(V64);
end;

function TSH4.OpDT(I: PSH4Inst): Boolean;
var
  N: Integer;
  V: Cardinal;
begin
  Result := False;
  N := I.N;
  V := S.R[N] - 1;
  S.R[N] := V;
  S.T := Cardinal(Ord(V = 0));
end;

function TSH4.OpEXTSB(I: PSH4Inst): Boolean;
var
  N, M: Integer;
begin
  Result := False;
  N := I.N;
  M := I.M;
  S.R[N] := SignExtend8(S.R[M]);
end;

function TSH4.OpEXTSW(I: PSH4Inst): Boolean;
var
  N, M: Integer;
begin
  Result := False;
  N := I.N;
  M := I.M;
  S.R[N] := SignExtend16(S.R[M]);
end;

function TSH4.OpEXTUB(I: PSH4Inst): Boolean;
var
  N, M: Integer;
begin
  Result := False;
  N := I.N;
  M := I.M;
  S.R[N] := S.R[M] and $FF;
end;

function TSH4.OpEXTUW(I: PSH4Inst): Boolean;
var
  N, M: Integer;
begin
  Result := False;
  N := I.N;
  M := I.M;
  S.R[N] := S.R[M] and $FFFF;
end;

function TSH4.OpMACL(I: PSH4Inst): Boolean;
var
  N, M: Integer;
  A, B: Cardinal;
  P64: Int64;
begin
  N := I.N;
  M := I.M;
  A := Read32(S.R[N]);
  if FFault then Exit(True);
  B := Read32(S.R[M] + Cardinal(Ord(N = M)) * 4);
  if FFault then Exit(True);
  S.R[N] := S.R[N] + 4;
  S.R[M] := S.R[M] + 4;
  P64 := Int64(Integer(A)) * Int64(Integer(B));
  P64 := Int64((UInt64(S.MACH) shl 32) or S.MACL) + P64;
  if (S.SR and SRS) <> 0 then
  begin
    if P64 > Int64($00007FFFFFFFFFFF) then
      P64 := $00007FFFFFFFFFFF
    else if P64 < -Int64($0000800000000000) then
      P64 := -Int64($0000800000000000);
  end;
  S.MACH := Cardinal(UInt64(P64) shr 32);
  S.MACL := Cardinal(P64);
  Result := FFault;
end;

function TSH4.OpMACW(I: PSH4Inst): Boolean;
var
  N, M: Integer;
  A, B: Cardinal;
  P64: Int64;
begin
  N := I.N;
  M := I.M;
  A := Read16(S.R[N]);
  if FFault then Exit(True);
  B := Read16(S.R[M] + Cardinal(Ord(N = M)) * 2);
  if FFault then Exit(True);
  S.R[N] := S.R[N] + 2;
  S.R[M] := S.R[M] + 2;
  var Product := Integer(SmallInt(Word(A))) * Integer(SmallInt(Word(B)));
  if (S.SR and SRS) <> 0 then
  begin
    P64 := Int64(Integer(S.MACL)) + Product;
    if P64 > MaxInt then
      S.MACL := $7FFFFFFF
    else if P64 < -Int64(2147483648) then
      S.MACL := $80000000
    else
      S.MACL := Cardinal(Integer(P64));
  end
  else
  begin
    P64 := Int64((UInt64(S.MACH) shl 32) or S.MACL) + Product;
    S.MACH := Cardinal(UInt64(P64) shr 32);
    S.MACL := Cardinal(P64);
  end;
  Result := FFault;
end;

function TSH4.OpMULL(I: PSH4Inst): Boolean;
var
  N, M: Integer;
begin
  Result := False;
  N := I.N;
  M := I.M;
  S.MACL := S.R[N] * S.R[M];
end;

function TSH4.OpMULSW(I: PSH4Inst): Boolean;
var
  N, M: Integer;
begin
  Result := False;
  N := I.N;
  M := I.M;
  S.MACL := Cardinal(Integer(SmallInt(Word(S.R[N]))) * Integer(SmallInt(Word(S.R[M]))));
end;

function TSH4.OpMULUW(I: PSH4Inst): Boolean;
var
  N, M: Integer;
begin
  Result := False;
  N := I.N;
  M := I.M;
  S.MACL := (S.R[N] and $FFFF) * (S.R[M] and $FFFF);
end;

function TSH4.OpNEG(I: PSH4Inst): Boolean;
var
  N, M: Integer;
begin
  Result := False;
  N := I.N;
  M := I.M;
  S.R[N] := 0 - S.R[M];
end;

function TSH4.OpNEGC(I: PSH4Inst): Boolean;
var
  N, M: Integer;
  A, V: Cardinal;
begin
  Result := False;
  N := I.N;
  M := I.M;
  A := 0 - S.R[M];
  V := A - S.T;
  S.T := Cardinal(Ord((A <> 0) or (A < V)));
  S.R[N] := V;
end;

function TSH4.OpSUB(I: PSH4Inst): Boolean;
var
  N, M: Integer;
begin
  Result := False;
  N := I.N;
  M := I.M;
  S.R[N] := S.R[N] - S.R[M];
end;

function TSH4.OpSUBC(I: PSH4Inst): Boolean;
var
  N, M: Integer;
  A, B, V: Cardinal;
begin
  Result := False;
  N := I.N;
  M := I.M;
  A := S.R[N];
  B := A - S.R[M];
  V := B - S.T;
  S.T := Cardinal(Ord((A < B) or (B < V)));
  S.R[N] := V;
end;

function TSH4.OpSUBV(I: PSH4Inst): Boolean;
var
  N, M: Integer;
  A, B, V: Cardinal;
begin
  Result := False;
  N := I.N;
  M := I.M;
  A := S.R[N];
  B := S.R[M];
  V := A - B;
  S.T := ((A xor B) and (A xor V)) shr 31;
  S.R[N] := V;
end;

function TSH4.OpAND(I: PSH4Inst): Boolean;
var
  N, M: Integer;
begin
  Result := False;
  N := I.N;
  M := I.M;
  S.R[N] := S.R[N] and S.R[M];
end;

function TSH4.OpANDI(I: PSH4Inst): Boolean;
begin
  Result := False;
  S.R[0] := S.R[0] and I.Imm;
end;

function TSH4.OpANDB(I: PSH4Inst): Boolean;
var
  A, V: Cardinal;
begin
  A := S.GBR + S.R[0];
  V := Read8(A);
  if FFault then Exit(True);
  case TOp(I.Kind) of
    oANDB: Write8(A, V and I.Imm);
    oORB: Write8(A, V or I.Imm);
    oXORB: Write8(A, V xor I.Imm);
  else
    S.T := Cardinal(Ord((V and I.Imm) = 0));
  end;
  Result := FFault;
end;

function TSH4.OpNOT(I: PSH4Inst): Boolean;
var
  N, M: Integer;
begin
  Result := False;
  N := I.N;
  M := I.M;
  S.R[N] := not S.R[M];
end;

function TSH4.OpOR(I: PSH4Inst): Boolean;
var
  N, M: Integer;
begin
  Result := False;
  N := I.N;
  M := I.M;
  S.R[N] := S.R[N] or S.R[M];
end;

function TSH4.OpORI(I: PSH4Inst): Boolean;
begin
  Result := False;
  S.R[0] := S.R[0] or I.Imm;
end;

function TSH4.OpTASB(I: PSH4Inst): Boolean;
var
  N: Integer;
  A, V: Cardinal;
begin
  N := I.N;
  A := S.R[N];
  V := Read8(A);
  if FFault then Exit(True);
  Write8(A, V or $80);
  if FFault then Exit(True);
  S.T := Cardinal(Ord(V = 0));
  Result := FFault;
end;

function TSH4.OpTST(I: PSH4Inst): Boolean;
var
  N, M: Integer;
begin
  Result := False;
  N := I.N;
  M := I.M;
  S.T := Cardinal(Ord((S.R[N] and S.R[M]) = 0));
end;

function TSH4.OpTSTI(I: PSH4Inst): Boolean;
begin
  Result := False;
  S.T := Cardinal(Ord((S.R[0] and I.Imm) = 0));
end;

function TSH4.OpXOR(I: PSH4Inst): Boolean;
var
  N, M: Integer;
begin
  Result := False;
  N := I.N;
  M := I.M;
  S.R[N] := S.R[N] xor S.R[M];
end;

function TSH4.OpXORI(I: PSH4Inst): Boolean;
begin
  Result := False;
  S.R[0] := S.R[0] xor I.Imm;
end;

function TSH4.OpROTL(I: PSH4Inst): Boolean;
var
  N: Integer;
  V: Cardinal;
begin
  Result := False;
  N := I.N;
  V := S.R[N];
  S.T := V shr 31;
  S.R[N] := (V shl 1) or S.T;
end;

function TSH4.OpROTR(I: PSH4Inst): Boolean;
var
  N: Integer;
  V: Cardinal;
begin
  Result := False;
  N := I.N;
  V := S.R[N];
  S.T := V and 1;
  S.R[N] := (V shr 1) or (S.T shl 31);
end;

function TSH4.OpROTCL(I: PSH4Inst): Boolean;
var
  N: Integer;
  V: Cardinal;
begin
  Result := False;
  N := I.N;
  V := S.R[N];
  S.R[N] := (V shl 1) or S.T;
  S.T := V shr 31;
end;

function TSH4.OpROTCR(I: PSH4Inst): Boolean;
var
  N: Integer;
  V: Cardinal;
begin
  Result := False;
  N := I.N;
  V := S.R[N];
  S.R[N] := (V shr 1) or (S.T shl 31);
  S.T := V and 1;
end;

function TSH4.OpSHAD(I: PSH4Inst): Boolean;
var
  N, M: Integer;
  B, V: Cardinal;
begin
  Result := False;
  N := I.N;
  M := I.M;
  B := S.R[M];
  V := S.R[N];
  if Integer(B) >= 0 then
    S.R[N] := V shl (B and 31)
  else if (B and 31) = 0 then
    S.R[N] := Sar32(V, 31)
  else
    S.R[N] := Sar32(V, ((not B) and 31) + 1);
end;

function TSH4.OpSHLD(I: PSH4Inst): Boolean;
var
  N, M: Integer;
  B, V: Cardinal;
begin
  Result := False;
  N := I.N;
  M := I.M;
  B := S.R[M];
  V := S.R[N];
  if Integer(B) >= 0 then
    S.R[N] := V shl (B and 31)
  else if (B and 31) = 0 then
    S.R[N] := 0
  else
    S.R[N] := V shr (((not B) and 31) + 1);
end;

function TSH4.OpSHAL(I: PSH4Inst): Boolean;
var
  N: Integer;
  V: Cardinal;
begin
  Result := False;
  N := I.N;
  V := S.R[N];
  S.T := V shr 31;
  S.R[N] := V shl 1;
end;

function TSH4.OpSHAR(I: PSH4Inst): Boolean;
var
  N: Integer;
  V: Cardinal;
begin
  Result := False;
  N := I.N;
  V := S.R[N];
  S.T := V and 1;
  S.R[N] := Sar32(V, 1);
end;

function TSH4.OpSHLL2(I: PSH4Inst): Boolean;
var
  N: Integer;
begin
  Result := False;
  N := I.N;
  S.R[N] := S.R[N] shl 2;
end;

function TSH4.OpSHLL8(I: PSH4Inst): Boolean;
var
  N: Integer;
begin
  Result := False;
  N := I.N;
  S.R[N] := S.R[N] shl 8;
end;

function TSH4.OpSHLL16(I: PSH4Inst): Boolean;
var
  N: Integer;
begin
  Result := False;
  N := I.N;
  S.R[N] := S.R[N] shl 16;
end;

function TSH4.OpSHLR(I: PSH4Inst): Boolean;
var
  N: Integer;
  V: Cardinal;
begin
  Result := False;
  N := I.N;
  V := S.R[N];
  S.T := V and 1;
  S.R[N] := V shr 1;
end;

function TSH4.OpSHLR2(I: PSH4Inst): Boolean;
var
  N: Integer;
begin
  Result := False;
  N := I.N;
  S.R[N] := S.R[N] shr 2;
end;

function TSH4.OpSHLR8(I: PSH4Inst): Boolean;
var
  N: Integer;
begin
  Result := False;
  N := I.N;
  S.R[N] := S.R[N] shr 8;
end;

function TSH4.OpSHLR16(I: PSH4Inst): Boolean;
var
  N: Integer;
begin
  Result := False;
  N := I.N;
  S.R[N] := S.R[N] shr 16;
end;

function TSH4.OpBF(I: PSH4Inst): Boolean;
begin
  Result := False;
  if S.T = 0 then
  begin
    FJumped := True;
    FJumpTarget := I.Imm;
  end;
end;

function TSH4.OpBT(I: PSH4Inst): Boolean;
begin
  Result := False;
  if S.T <> 0 then
  begin
    FJumped := True;
    FJumpTarget := I.Imm;
  end;
end;

function TSH4.OpBFS(I: PSH4Inst): Boolean;
begin
  Result := False;
  S.DelaySlot := True;
  if S.T = 0 then
    S.DelayTarget := I.Imm
  else
    S.DelayTarget := I.Addr + 4;
end;

function TSH4.OpBTS(I: PSH4Inst): Boolean;
begin
  Result := False;
  S.DelaySlot := True;
  if S.T <> 0 then
    S.DelayTarget := I.Imm
  else
    S.DelayTarget := I.Addr + 4;
end;

function TSH4.OpBRA(I: PSH4Inst): Boolean;
begin
  Result := False;
  S.DelaySlot := True;
  S.DelayTarget := I.Imm;
end;

function TSH4.OpBSR(I: PSH4Inst): Boolean;
begin
  Result := False;
  S.PR := I.Addr + 4;
  S.DelaySlot := True;
  S.DelayTarget := I.Imm;
end;

function TSH4.OpBRAF(I: PSH4Inst): Boolean;
var
  N: Integer;
begin
  Result := False;
  N := I.N;
  S.DelaySlot := True;
  S.DelayTarget := I.Addr + 4 + S.R[N];
end;

function TSH4.OpBSRF(I: PSH4Inst): Boolean;
var
  N: Integer;
begin
  Result := False;
  N := I.N;
  S.DelaySlot := True;
  S.DelayTarget := I.Addr + 4 + S.R[N];
  S.PR := I.Addr + 4;
end;

function TSH4.OpJMP(I: PSH4Inst): Boolean;
var
  N: Integer;
begin
  Result := False;
  N := I.N;
  S.DelaySlot := True;
  S.DelayTarget := S.R[N];
end;

function TSH4.OpJSR(I: PSH4Inst): Boolean;
var
  N: Integer;
begin
  Result := False;
  N := I.N;
  S.DelaySlot := True;
  S.DelayTarget := S.R[N];
  S.PR := I.Addr + 4;
end;

function TSH4.OpRTS(I: PSH4Inst): Boolean;
begin
  Result := False;
  S.DelaySlot := True;
  S.DelayTarget := S.PR;
end;

function TSH4.OpRTE(I: PSH4Inst): Boolean;
begin
  Result := False;
  S.DelaySlot := True;
  S.DelayTarget := S.SPC;
  S.RTEPending := True;
  S.RTESR := S.SSR;
end;

function TSH4.OpCLRMAC(I: PSH4Inst): Boolean;
begin
  Result := False;
  S.MACH := 0;
  S.MACL := 0;
end;

function TSH4.OpCLRS(I: PSH4Inst): Boolean;
begin
  Result := False;
  S.SR := S.SR and not Cardinal(SRS);
end;

function TSH4.OpCLRT(I: PSH4Inst): Boolean;
begin
  Result := False;
  S.T := 0;
end;

function TSH4.OpSETS(I: PSH4Inst): Boolean;
begin
  Result := False;
  S.SR := S.SR or SRS;
end;

function TSH4.OpSETT(I: PSH4Inst): Boolean;
begin
  Result := False;
  S.T := 1;
end;

function TSH4.OpLDTLB(I: PSH4Inst): Boolean;
begin
  Result := False;
  var Index := (S.MMUCR shr 10) and 63;
  // Pages cached from the entry being replaced; code blocks recheck their
  // translation (see BlockMapped).
  TLBInvalidate(S.UTLB[Index]);
  S.UTLB[Index].VPN := S.PTEH and $FFFFFC00;
  S.UTLB[Index].ASID := S.PTEH and $FF;
  S.UTLB[Index].PPN := S.PTEL and $1FFFFC00;
  S.UTLB[Index].Flags := S.PTEL and $1FF;
  S.UTLB[Index].PTEA := S.PTEA and $F;
  UpdateUTLBKey(Index);
end;

function TSH4.OpMOVCAL(I: PSH4Inst): Boolean;
var
  N: Integer;
begin
  N := I.N;
  Write32(S.R[N], S.R[0]);
  Result := FFault;
end;

function TSH4.OpPREF(I: PSH4Inst): Boolean;
var
  N: Integer;
begin
  N := I.N;
  if (S.R[N] and $FC000000) = $E0000000 then
    StoreQueueFlush(S.R[N]);
  Result := FFault;
end;

function TSH4.OpSLEEP(I: PSH4Inst): Boolean;
begin
  Result := False;
  // PC stays on SLEEP; an accepted interrupt returns past it.
  S.Sleeping := True;
  FJumped := True;
  FJumpTarget := I.Addr;
end;

function TSH4.OpTRAPA(I: PSH4Inst): Boolean;
begin
  S.TRA := I.Imm shl 2;
  S.EXPEVT := SH4ExcTrap;
  EnterException(SH4ExcTrap, $100, I.Addr + 2);
  FStop := StopTrap;
  Exit(True);
end;

function TSH4.OpLDCSR(I: PSH4Inst): Boolean;
var
  N: Integer;
begin
  Result := False;
  N := I.N;
  SetSRValue(S.R[N]);
end;

function TSH4.OpLDCGBR(I: PSH4Inst): Boolean;
var
  N: Integer;
begin
  Result := False;
  N := I.N;
  S.GBR := S.R[N];
end;

function TSH4.OpLDCVBR(I: PSH4Inst): Boolean;
var
  N: Integer;
begin
  Result := False;
  N := I.N;
  S.VBR := S.R[N];
end;

function TSH4.OpLDCSSR(I: PSH4Inst): Boolean;
var
  N: Integer;
begin
  Result := False;
  N := I.N;
  S.SSR := S.R[N];
end;

function TSH4.OpLDCSPC(I: PSH4Inst): Boolean;
var
  N: Integer;
begin
  Result := False;
  N := I.N;
  S.SPC := S.R[N];
end;

function TSH4.OpLDCDBR(I: PSH4Inst): Boolean;
var
  N: Integer;
begin
  Result := False;
  N := I.N;
  S.DBR := S.R[N];
end;

function TSH4.OpLDCBANK(I: PSH4Inst): Boolean;
var
  N, M: Integer;
begin
  Result := False;
  N := I.N;
  M := I.M;
  S.RBank[M] := S.R[N];
end;

function TSH4.OpLDCMSR(I: PSH4Inst): Boolean;
var
  N, M: Integer;
  V: Cardinal;
begin
  N := I.N;
  M := I.M;
  V := Read32(S.R[N]);
  if FFault then Exit(True);
  S.R[N] := S.R[N] + 4;
  case TOp(I.Kind) of
    oLDCMSR: SetSRValue(V);
    oLDCMGBR: S.GBR := V;
    oLDCMVBR: S.VBR := V;
    oLDCMSSR: S.SSR := V;
    oLDCMSPC: S.SPC := V;
    oLDCMDBR: S.DBR := V;
    oLDCMBANK: S.RBank[M] := V;
    oLDSMMACH: S.MACH := V;
    oLDSMMACL: S.MACL := V;
    oLDSMPR: S.PR := V;
    oLDSMFPUL: S.FPUL := V;
  else
    begin
      SetFPSCRValue(V);
    end;
  end;
  Result := FFault;
end;

function TSH4.OpLDSMACH(I: PSH4Inst): Boolean;
var
  N: Integer;
begin
  Result := False;
  N := I.N;
  S.MACH := S.R[N];
end;

function TSH4.OpLDSMACL(I: PSH4Inst): Boolean;
var
  N: Integer;
begin
  Result := False;
  N := I.N;
  S.MACL := S.R[N];
end;

function TSH4.OpLDSPR(I: PSH4Inst): Boolean;
var
  N: Integer;
begin
  Result := False;
  N := I.N;
  S.PR := S.R[N];
end;

function TSH4.OpSTCSR(I: PSH4Inst): Boolean;
var
  N: Integer;
begin
  Result := False;
  N := I.N;
  S.R[N] := GetSRValue;
end;

function TSH4.OpSTCGBR(I: PSH4Inst): Boolean;
var
  N: Integer;
begin
  Result := False;
  N := I.N;
  S.R[N] := S.GBR;
end;

function TSH4.OpSTCVBR(I: PSH4Inst): Boolean;
var
  N: Integer;
begin
  Result := False;
  N := I.N;
  S.R[N] := S.VBR;
end;

function TSH4.OpSTCSSR(I: PSH4Inst): Boolean;
var
  N: Integer;
begin
  Result := False;
  N := I.N;
  S.R[N] := S.SSR;
end;

function TSH4.OpSTCSPC(I: PSH4Inst): Boolean;
var
  N: Integer;
begin
  Result := False;
  N := I.N;
  S.R[N] := S.SPC;
end;

function TSH4.OpSTCSGR(I: PSH4Inst): Boolean;
var
  N: Integer;
begin
  Result := False;
  N := I.N;
  S.R[N] := S.SGR;
end;

function TSH4.OpSTCDBR(I: PSH4Inst): Boolean;
var
  N: Integer;
begin
  Result := False;
  N := I.N;
  S.R[N] := S.DBR;
end;

function TSH4.OpSTCBANK(I: PSH4Inst): Boolean;
var
  N, M: Integer;
begin
  Result := False;
  N := I.N;
  M := I.M;
  S.R[N] := S.RBank[M];
end;

function TSH4.OpSTCMSR(I: PSH4Inst): Boolean;
var
  N, M: Integer;
  A, V: Cardinal;
begin
  N := I.N;
  M := I.M;
  case TOp(I.Kind) of
    oSTCMSR: V := GetSRValue;
    oSTCMGBR: V := S.GBR;
    oSTCMVBR: V := S.VBR;
    oSTCMSSR: V := S.SSR;
    oSTCMSPC: V := S.SPC;
    oSTCMSGR: V := S.SGR;
    oSTCMDBR: V := S.DBR;
    oSTCMBANK: V := S.RBank[M];
    oSTSMMACH: V := S.MACH;
    oSTSMMACL: V := S.MACL;
    oSTSMPR: V := S.PR;
    oSTSMFPUL: V := S.FPUL;
  else
    V := S.FPSCR;
  end;
  A := S.R[N] - 4;
  Write32(A, V);
  if FFault then Exit(True);
  S.R[N] := A;
  Result := FFault;
end;

function TSH4.OpSTSMACH(I: PSH4Inst): Boolean;
var
  N: Integer;
begin
  Result := False;
  N := I.N;
  S.R[N] := S.MACH;
end;

function TSH4.OpSTSMACL(I: PSH4Inst): Boolean;
var
  N: Integer;
begin
  Result := False;
  N := I.N;
  S.R[N] := S.MACL;
end;

function TSH4.OpSTSPR(I: PSH4Inst): Boolean;
var
  N: Integer;
begin
  Result := False;
  N := I.N;
  S.R[N] := S.PR;
end;

function TSH4.OpLDSFPSCR(I: PSH4Inst): Boolean;
var
  N: Integer;
begin
  Result := False;
  N := I.N;
  SetFPSCRValue(S.R[N]);
end;

function TSH4.OpLDSFPUL(I: PSH4Inst): Boolean;
var
  N: Integer;
begin
  Result := False;
  N := I.N;
  S.FPUL := S.R[N];
end;

function TSH4.OpSTSFPSCR(I: PSH4Inst): Boolean;
var
  N: Integer;
begin
  Result := False;
  N := I.N;
  S.R[N] := S.FPSCR;
end;

function TSH4.OpSTSFPUL(I: PSH4Inst): Boolean;
var
  N: Integer;
begin
  Result := False;
  N := I.N;
  S.R[N] := S.FPUL;
end;

function TSH4.OpFMOV(I: PSH4Inst): Boolean;
var
  N, M: Integer;
begin
  Result := False;
  N := I.N;
  M := I.M;
  // Single-precision moves; register numbers are pre-xored (see TSH4State).
  S.FR.U[N] := S.FR.U[M];
end;

function TSH4.OpFMOVLD(I: PSH4Inst): Boolean;
var
  N, M: Integer;
  V: Cardinal;
begin
  N := I.N;
  M := I.M;
  V := Read32(S.R[M]);
  if FFault then Exit(True);
  S.FR.U[N] := V;
  Result := FFault;
end;

function TSH4.OpFMOVLD0(I: PSH4Inst): Boolean;
var
  N, M: Integer;
  V: Cardinal;
begin
  N := I.N;
  M := I.M;
  V := Read32(S.R[M] + S.R[0]);
  if FFault then Exit(True);
  S.FR.U[N] := V;
  Result := FFault;
end;

function TSH4.OpFMOVLDP(I: PSH4Inst): Boolean;
var
  N, M: Integer;
  V: Cardinal;
begin
  N := I.N;
  M := I.M;
  V := Read32(S.R[M]);
  if FFault then Exit(True);
  S.R[M] := S.R[M] + 4;
  S.FR.U[N] := V;
  Result := FFault;
end;

function TSH4.OpFMOVST(I: PSH4Inst): Boolean;
var
  N, M: Integer;
begin
  N := I.N;
  M := I.M;
  Write32(S.R[N], S.FR.U[M]);
  Result := FFault;
end;

function TSH4.OpFMOVST0(I: PSH4Inst): Boolean;
var
  N, M: Integer;
begin
  N := I.N;
  M := I.M;
  Write32(S.R[N] + S.R[0], S.FR.U[M]);
  Result := FFault;
end;

function TSH4.OpFMOVSTM(I: PSH4Inst): Boolean;
var
  N, M: Integer;
  A: Cardinal;
begin
  N := I.N;
  M := I.M;
  A := S.R[N] - 4;
  Write32(A, S.FR.U[M]);
  if FFault then Exit(True);
  S.R[N] := A;
  Result := FFault;
end;

function TSH4.OpFMOVD(I: PSH4Inst): Boolean;
var
  N, M: Integer;
  V64: UInt64;
begin
  Result := False;
  N := I.N;
  M := I.M;
  // Pair moves (SZ=1): odd register numbers select XD.
  if (M and 1) = 0 then
    V64 := S.FR.Q[M shr 1]
  else
    V64 := S.XF.Q[M shr 1];
  if (N and 1) = 0 then
    S.FR.Q[N shr 1] := V64
  else
    S.XF.Q[N shr 1] := V64;
end;

function TSH4.OpFMOVDLD(I: PSH4Inst): Boolean;
var
  N, M: Integer;
  A: Cardinal;
  V64: UInt64;
begin
  N := I.N;
  M := I.M;
  A := S.R[M];
  if TOp(I.Kind) = oFMOVDLD0 then
    A := A + S.R[0];
  V64 := Read64(A);
  if FFault then Exit(True);
  if TOp(I.Kind) = oFMOVDLDP then
    S.R[M] := S.R[M] + 8;
  if (N and 1) = 0 then
    S.FR.Q[N shr 1] := SwapHalves(V64)
  else
    S.XF.Q[N shr 1] := SwapHalves(V64);
  Result := FFault;
end;

function TSH4.OpFMOVDST(I: PSH4Inst): Boolean;
var
  N, M: Integer;
  A: Cardinal;
  V64: UInt64;
begin
  N := I.N;
  M := I.M;
  if (M and 1) = 0 then
    V64 := SwapHalves(S.FR.Q[M shr 1])
  else
    V64 := SwapHalves(S.XF.Q[M shr 1]);
  A := S.R[N];
  case TOp(I.Kind) of
    oFMOVDST0: A := A + S.R[0];
    oFMOVDSTM: A := A - 8;
  end;
  Write64(A, V64);
  if FFault then Exit(True);
  if TOp(I.Kind) = oFMOVDSTM then
    S.R[N] := A;
  Result := FFault;
end;

function TSH4.OpFLDI0(I: PSH4Inst): Boolean;
var
  N: Integer;
begin
  Result := False;
  N := I.N;
  S.FR.U[N] := 0;
end;

function TSH4.OpFLDI1(I: PSH4Inst): Boolean;
var
  N: Integer;
begin
  Result := False;
  N := I.N;
  S.FR.U[N] := $3F800000;
end;

function TSH4.OpFLDS(I: PSH4Inst): Boolean;
var
  N: Integer;
begin
  Result := False;
  N := I.N;
  S.FPUL := S.FR.U[N];
end;

function TSH4.OpFSTS(I: PSH4Inst): Boolean;
var
  N: Integer;
begin
  Result := False;
  N := I.N;
  S.FR.U[N] := S.FPUL;
end;

function TSH4.OpFABS(I: PSH4Inst): Boolean;
var
  N: Integer;
begin
  Result := False;
  N := I.N;
  S.FR.U[N] := S.FR.U[N] and $7FFFFFFF;
end;

function TSH4.OpFNEG(I: PSH4Inst): Boolean;
var
  N: Integer;
begin
  Result := False;
  N := I.N;
  S.FR.U[N] := S.FR.U[N] xor $80000000;
end;

// FADD, FSUB, FMUL and FDIV in single precision; with FPSCR.DN denormal
// operands and results are flushed to zero.
function TSH4.OpFADD(I: PSH4Inst): Boolean;
begin
  Result := False;
  var X := S.FR.U[I.N];
  var Y := S.FR.U[I.M];
  if (S.FPSCR and FPSCRDN) = 0 then
    S.FR.S[I.N] := BitsSingle(X) + BitsSingle(Y)
  else
    S.FR.U[I.N] := FlushBits(SingleBits(BitsSingle(FlushBits(X)) + BitsSingle(FlushBits(Y))));
end;

function TSH4.OpFSUB(I: PSH4Inst): Boolean;
begin
  Result := False;
  var X := S.FR.U[I.N];
  var Y := S.FR.U[I.M];
  if (S.FPSCR and FPSCRDN) = 0 then
    S.FR.S[I.N] := BitsSingle(X) - BitsSingle(Y)
  else
    S.FR.U[I.N] := FlushBits(SingleBits(BitsSingle(FlushBits(X)) - BitsSingle(FlushBits(Y))));
end;

function TSH4.OpFMUL(I: PSH4Inst): Boolean;
begin
  Result := False;
  var X := S.FR.U[I.N];
  var Y := S.FR.U[I.M];
  if (S.FPSCR and FPSCRDN) = 0 then
    S.FR.S[I.N] := BitsSingle(X) * BitsSingle(Y)
  else
    S.FR.U[I.N] := FlushBits(SingleBits(BitsSingle(FlushBits(X)) * BitsSingle(FlushBits(Y))));
end;

function TSH4.OpFDIV(I: PSH4Inst): Boolean;
begin
  Result := False;
  var X := S.FR.U[I.N];
  var Y := S.FR.U[I.M];
  if (S.FPSCR and FPSCRDN) = 0 then
    S.FR.S[I.N] := BitsSingle(X) / BitsSingle(Y)
  else
    S.FR.U[I.N] := FlushBits(SingleBits(BitsSingle(FlushBits(X)) / BitsSingle(FlushBits(Y))));
end;

function TSH4.OpFMAC(I: PSH4Inst): Boolean;
var
  N, M: Integer;
  F: Single;
  DV: Double;
  DN: Boolean;
begin
  Result := False;
  N := I.N;
  M := I.M;
  DN := (S.FPSCR and FPSCRDN) <> 0;
  var X := S.FR.S[1];
  var Y := S.FR.S[M];
  var Z := S.FR.S[N];
  if DN then
  begin
    X := FlushSingle(X);
    Y := FlushSingle(Y);
    Z := FlushSingle(Z);
  end;
  DV := Double(X) * Double(Y) + Double(Z);
  F := RoundToSingle(DV);
  if DN then
    F := FlushSingle(F);
  S.FR.S[N] := F;
end;

function TSH4.OpFSQRT(I: PSH4Inst): Boolean;
var
  N: Integer;
  F: Single;
  DN: Boolean;
begin
  Result := False;
  N := I.N;
  DN := (S.FPSCR and FPSCRDN) <> 0;
  F := S.FR.S[N];
  if DN then
    F := FlushSingle(F);
  F := RoundToSingle(Sqrt(Double(F)));
  S.FR.S[N] := F;
end;

function TSH4.OpFSRRA(I: PSH4Inst): Boolean;
var
  N: Integer;
  F: Single;
  DN: Boolean;
begin
  Result := False;
  N := I.N;
  DN := (S.FPSCR and FPSCRDN) <> 0;
  F := S.FR.S[N];
  if DN then
    F := FlushSingle(F);
  F := RoundToSingle(1.0 / Sqrt(Double(F)));
  if DN then
    F := FlushSingle(F);
  S.FR.S[N] := F;
end;

function TSH4.OpFCMPEQ(I: PSH4Inst): Boolean;
var
  N, M: Integer;
begin
  Result := False;
  N := I.N;
  M := I.M;
  if IsNaNBits(S.FR.U[N]) or IsNaNBits(S.FR.U[M]) then
    S.T := 0
  else
    S.T := Cardinal(Ord(S.FR.S[N] = S.FR.S[M]));
end;

function TSH4.OpFCMPGT(I: PSH4Inst): Boolean;
var
  N, M: Integer;
begin
  Result := False;
  N := I.N;
  M := I.M;
  if IsNaNBits(S.FR.U[N]) or IsNaNBits(S.FR.U[M]) then
    S.T := 0
  else
    S.T := Cardinal(Ord(S.FR.S[N] > S.FR.S[M]));
end;

function TSH4.OpFLOAT(I: PSH4Inst): Boolean;
var
  N: Integer;
  F: Single;
begin
  Result := False;
  N := I.N;
  F := Integer(S.FPUL);
  S.FR.S[N] := F;
end;

function TSH4.OpFTRC(I: PSH4Inst): Boolean;
var
  N: Integer;
begin
  Result := False;
  N := I.N;
  S.FPUL := SingleToInt(S.FR.S[N]);
end;

function TSH4.OpFIPR(I: PSH4Inst): Boolean;
var
  N, M: Integer;
  F: Single;
  DN: Boolean;
begin
  Result := False;
  N := I.N;
  M := I.M;
  DN := (S.FPSCR and FPSCRDN) <> 0;
  // FIPR/FTRV: a rounded first product, then fused multiply-adds with one
  // rounding each (the order matches SingleStepTests): as SingleProduct and
  // FusedSingle, written out.
  F := S.FR.S[N xor 1] * S.FR.S[M xor 1];
  F := Double(S.FR.S[(N + 1) xor 1]) * Double(S.FR.S[(M + 1) xor 1]) + Double(F);
  F := Double(S.FR.S[(N + 2) xor 1]) * Double(S.FR.S[(M + 2) xor 1]) + Double(F);
  F := Double(S.FR.S[(N + 3) xor 1]) * Double(S.FR.S[(M + 3) xor 1]) + Double(F);
  if DN then
    F := FlushSingle(F);
  S.FR.S[(N + 3) xor 1] := F;
end;

function TSH4.OpFTRV(I: PSH4Inst): Boolean;
var
  N: Integer;
  F: Single;
  DN: Boolean;
begin
  Result := False;
  N := I.N;
  DN := (S.FPSCR and FPSCRDN) <> 0;
  var X0: Double := S.FR.S[N xor 1];
  var X1: Single := S.FR.S[(N + 1) xor 1];
  var X2: Double := S.FR.S[(N + 2) xor 1];
  var X3: Double := S.FR.S[(N + 3) xor 1];
  // As FIPR (SingleProduct, then FusedSingle), per row.
  for var Row := 0 to 3 do
  begin
    F := S.XF.S[(Row + 4) xor 1] * X1;
    F := Double(S.XF.S[Row xor 1]) * X0 + Double(F);
    F := Double(S.XF.S[(Row + 8) xor 1]) * X2 + Double(F);
    F := Double(S.XF.S[(Row + 12) xor 1]) * X3 + Double(F);
    if DN then
      F := FlushSingle(F);
    S.FR.S[(N + Row) xor 1] := F;
  end;
end;

function TSH4.OpFSCA(I: PSH4Inst): Boolean;
var
  N: Integer;
  DV: Double;
begin
  Result := False;
  N := I.N;
  DV := (S.FPUL and $FFFF) * (2 * Pi / 65536);
  S.FR.S[N + 1] := RoundToSingle(Sin(DV));
  S.FR.S[N] := RoundToSingle(Cos(DV));
end;

function TSH4.OpFSCHG(I: PSH4Inst): Boolean;
begin
  Result := False;
  S.FPSCR := S.FPSCR xor FPSCRSZ;
end;

function TSH4.OpFRCHG(I: PSH4Inst): Boolean;
begin
  Result := False;
  S.FPSCR := S.FPSCR xor FPSCRFR;
  SwapFPBanks;
end;

function TSH4.OpDABS(I: PSH4Inst): Boolean;
var
  N: Integer;
begin
  Result := False;
  N := I.N;
  S.FR.Q[N shr 1] := S.FR.Q[N shr 1] and $7FFFFFFFFFFFFFFF;
end;

function TSH4.OpDNEG(I: PSH4Inst): Boolean;
var
  N: Integer;
begin
  Result := False;
  N := I.N;
  S.FR.Q[N shr 1] := S.FR.Q[N shr 1] xor $8000000000000000;
end;

function TSH4.OpDADD(I: PSH4Inst): Boolean;
var
  N, M: Integer;
  DV: Double;
  DN: Boolean;
begin
  Result := False;
  N := I.N;
  M := I.M;
  DN := (S.FPSCR and FPSCRDN) <> 0;
  var X := S.FR.D[N shr 1];
  var Y := S.FR.D[M shr 1];
  if DN then
  begin
    X := FlushDouble(X);
    Y := FlushDouble(Y);
  end;
  case TOp(I.Kind) of
    oDADD: DV := X + Y;
    oDSUB: DV := X - Y;
    oDMUL: DV := X * Y;
  else
    DV := X / Y;
  end;
  if DN then
    DV := FlushDouble(DV);
  S.FR.D[N shr 1] := DV;
end;

function TSH4.OpDSQRT(I: PSH4Inst): Boolean;
var
  N: Integer;
begin
  Result := False;
  N := I.N;
  S.FR.D[N shr 1] := Sqrt(S.FR.D[N shr 1]);
end;

function TSH4.OpDCMPEQ(I: PSH4Inst): Boolean;
var
  N, M: Integer;
begin
  Result := False;
  N := I.N;
  M := I.M;
  if IsNaN64(S.FR.Q[N shr 1]) or IsNaN64(S.FR.Q[M shr 1]) then
    S.T := 0
  else
    S.T := Cardinal(Ord(S.FR.D[N shr 1] = S.FR.D[M shr 1]));
end;

function TSH4.OpDCMPGT(I: PSH4Inst): Boolean;
var
  N, M: Integer;
begin
  Result := False;
  N := I.N;
  M := I.M;
  if IsNaN64(S.FR.Q[N shr 1]) or IsNaN64(S.FR.Q[M shr 1]) then
    S.T := 0
  else
    S.T := Cardinal(Ord(S.FR.D[N shr 1] > S.FR.D[M shr 1]));
end;

function TSH4.OpDFLOAT(I: PSH4Inst): Boolean;
var
  N: Integer;
begin
  Result := False;
  N := I.N;
  S.FR.D[N shr 1] := Integer(S.FPUL);
end;

function TSH4.OpDFTRC(I: PSH4Inst): Boolean;
var
  N: Integer;
begin
  Result := False;
  N := I.N;
  S.FPUL := DoubleToInt(S.FR.D[N shr 1]);
end;

function TSH4.OpFCNVSD(I: PSH4Inst): Boolean;
var
  N: Integer;
begin
  Result := False;
  N := I.N;
  S.FR.D[N shr 1] := BitsSingle(S.FPUL);
end;

function TSH4.OpFCNVDS(I: PSH4Inst): Boolean;
var
  N: Integer;
  F: Single;
  DN: Boolean;
begin
  Result := False;
  N := I.N;
  DN := (S.FPSCR and FPSCRDN) <> 0;
  F := RoundToSingle(S.FR.D[N shr 1]);
  if DN then
    F := FlushSingle(F);
  S.FPUL := SingleBits(F);
end;

function TSH4.OpIllegal(I: PSH4Inst): Boolean;
begin
  if (TOp(I.Kind) = oIllegal) and Assigned(FIllegalHook) then
  begin
    S.PC := I.Addr;
    Inc(FSideEffects);
    if FIllegalHook(FIllegalUser, I.Addr) then
    begin
      FJumped := True;
      FJumpTarget := S.PC;
      FStop := StopLeave;
      Exit(True);
    end;
  end;
  case TOp(I.Kind) of
    oIllegal: S.EXPEVT := SH4ExcIllegal;
    oSlotIllegal: S.EXPEVT := SH4ExcSlotIllegal;
    oFPUDisabled: S.EXPEVT := SH4ExcFPUDisabled;
  else
    S.EXPEVT := SH4ExcSlotFPUDisabled;
  end;
  FExcepted := True;
  Exit(True);
end;

function TSH4.Execute(Insts: PSH4Inst; Count: Integer; out Next: Cardinal): Integer;
var
  I: PSH4Inst;
begin
  Result := 0;
  FJumped := False;
  FExcepted := False;
  I := Insts;
  while Result < Count do
  begin
    if SH4Ops[TOp(I.Kind)](Self, I) then
    begin
      // A fault or exception stops before the instruction; TRAPA and an
      // accepted illegal-instruction hook complete it and leave the block.
      if FStop = StopTrap then
      begin
        FStop := StopNone;
        Inc(Result);
        Next := S.PC;
        Exit;
      end;
      if FStop = StopLeave then
      begin
        FStop := StopNone;
        Inc(Result);
        Inc(I);
      end;
      Break;
    end;
    Inc(Result);
    Inc(I);
  end;

  if FFault or FExcepted then
  begin
    FFault := False;
    Fault(S.EXPEVT, I^, (I.Flags and IFSlot) <> 0);
    Next := S.PC;
    Exit;
  end;

  Dec(I);
  if FJumped then
    Next := FJumpTarget
  else if (I.Flags and IFDelayed) <> 0 then
    Next := I.Addr + 2
  else if S.DelaySlot then
  begin
    Next := S.DelayTarget;
    S.DelaySlot := False;
    if S.RTEPending then
    begin
      S.RTEPending := False;
      SetSRValue(S.RTESR);
    end;
  end
  else if TOp(I.Kind) in [oROTDIV, oDIVROT] then
    // A fused run of division steps ends the block (at a page boundary).
    Next := I.Addr + (I.Imm and $FFFF) * 4
  else
    Next := I.Addr + 2;
end;

{ Blocks }

procedure TSH4.ClearBlocks;
begin
  FillChar(FBlockHead, SizeOf(FBlockHead), 0);
  FBlockCount := 0;
  FInstChunk := 0;
  FInstUsed := 0;
  FCodeChunk := 0;
  FCodeUsed := 0;
end;

procedure TSH4.InvalidateBlocks;
begin
  ClearBlocks;
end;

function TSH4.FetchWord(Address: Cardinal; out Op: Word): Boolean;
begin
  if Assigned(FFetch) then
  begin
    if ((Address and 1) <> 0) and not FLenient then
    begin
      S.TEA := Address;
      S.EXPEVT := SH4ExcAddressRead;
      Exit(False);
    end;
    Op := FFetch(FFetchUser, Address);
    Exit(True);
  end;
  var P := FReadMap[Address shr 16];
  if (P <> nil) and ((Address and 1) = 0) then
  begin
    Op := PWord(P + (Address and $FFFF))^;
    Exit(True);
  end;
  Op := Word(SlowRead(Address, 2));
  Result := not FFault;
  FFault := False;
end;

function TSH4.BlockValid(B: PSH4Block): Boolean;
begin
  if (B.GenPtr^ = B.Gen) and (B.GenPtr2^ = B.Gen2) then
    Exit(True);
  var Code := B.Code;
  if B.Translated then
  begin
    // Within one physical 4 KiB page.
    var P := FBus.ReadPages[B.Phys shr 16];
    if P = nil then
      Exit(False);
    P := P + (B.Phys and $FFFF);
    for var I := 0 to B.Words - 1 do
      if PWord(P + I * 2)^ <> Code[I] then
        Exit(False);
  end
  else
  begin
    var Address := B.PC;
    for var I := 0 to B.Words - 1 do
    begin
      var P := FReadMap[Address shr 16];
      if (P = nil) or (PWord(P + (Address and $FFFF))^ <> Code^) then
        Exit(False);
      Inc(Code);
      Inc(Address, 2);
    end;
  end;
  B.Gen := B.GenPtr^;
  B.Gen2 := B.GenPtr2^;
  Result := True;
end;

function TSH4.BlockMapped(B: PSH4Block): Boolean;
begin
  // Translated code is reused while its virtual address still maps to the
  // physical address it was read from. Code whose page is not mapped now
  // (the fetch takes a TLB miss) is kept for when it is again.
  FMapStale := False;
  if not B.Translated or (B.Epoch = FTLBEpoch) then
    Exit(True);
  Result := False;
  FMapStale := True;
  if (S.MMUCR and 1) = 0 then
    Exit;
  FMapStale := False;
  var Page := TLBPage(B.PC);
  var Phys: Cardinal;
  if (Page <> nil) and (Page.Read <> nil) then
    Phys := Page.Phys or (B.PC and $FFF)
  else
  begin
    if not Translate(B.PC, False, Phys) then
    begin
      FFault := False;
      Exit;
    end;
    TLBFill(B.PC, Phys, False);
  end;
  FMapStale := Phys <> B.Phys;
  if FMapStale then
    Exit;
  B.Epoch := FTLBEpoch;
  Result := True;
end;

function TSH4.FindBlock(PC, AMode: Cardinal): PSH4Block;
begin
  Result := FBlockHead[(PC shr 1) and (BlockBuckets - 1)];
  while Result <> nil do
  begin
    if (Result.PC = PC) and (Result.Mode = AMode) then
    begin
      FMapStale := True;
      if not Result.Translated or BlockMapped(Result) then
      begin
        if BlockValid(Result) then
          Exit;
        FMapStale := True;
      end;
      // Stale code: unlink by marking an impossible mode; rebuilt below.
      if FMapStale then
        Result.Mode := $FFFFFFFF;
      Exit(nil);
    end;
    Result := Result.Next;
  end;
end;

function TSH4.BuildBlock(PC, AMode: Cardinal): PSH4Block;
begin
  Result := nil;
  if (PC and 1) <> 0 then
    Exit;
  // Only code in host memory is cached; device memory runs by steps. With
  // address translation, a block of P0/P3 code stays within one 4 KiB page
  // mapped by an entry of at least that size.
  var Translated := False;
  var CodePage: PByte := nil;
  var Phys: Cardinal := 0;
  if FReadMap[PC shr 16] = nil then
  begin
    if ((S.MMUCR and 1) = 0) or (TLBIndex(PC) < 0) then
      Exit;
    var Page := TLBPage(PC);
    if (Page = nil) or (Page.Read = nil) then
    begin
      var Target: Cardinal;
      if not Translate(PC, False, Target) then
      begin
        // The fetch faults when it runs by steps.
        FFault := False;
        Exit;
      end;
      TLBFill(PC, Target, False);
      Page := TLBPage(PC);
      if (Page = nil) or (Page.Read = nil) then
        Exit;
    end;
    Translated := True;
    CodePage := Page.Read;
    Phys := Page.Phys or (PC and $FFF);
  end;
  if FInstUsed + MaxBlockInsts + 1 > InstChunkSize then
  begin
    Inc(FInstChunk);
    FInstUsed := 0;
  end;
  if FCodeUsed + MaxBlockInsts + 1 > InstChunkSize then
  begin
    Inc(FCodeChunk);
    FCodeUsed := 0;
  end;
  if (FBlockCount >= MaxBlocks) or (FInstChunk >= MaxInstChunks) or (FCodeChunk >= MaxInstChunks) then
    ClearBlocks;
  if FInstChunk >= Length(FInstChunks) then
  begin
    SetLength(FInstChunks, FInstChunk + 1);
    SetLength(FInstChunks[FInstChunk], InstChunkSize);
  end;
  if FCodeChunk >= Length(FCodeChunks) then
  begin
    SetLength(FCodeChunks, FCodeChunk + 1);
    SetLength(FCodeChunks[FCodeChunk], InstChunkSize);
  end;
  var Chunk := FBlockCount div BlockChunkSize;
  if Chunk >= Length(FBlockChunks) then
  begin
    SetLength(FBlockChunks, Chunk + 1);
    SetLength(FBlockChunks[Chunk], BlockChunkSize);
  end;
  var B: PSH4Block := @FBlockChunks[Chunk][FBlockCount mod BlockChunkSize];
  var Insts: PSH4Inst := @FInstChunks[FInstChunk][FInstUsed];
  var Code: PWord := @FCodeChunks[FCodeChunk][FCodeUsed];
  var Count := 0;
  var Address := PC;
  var Slot := False;
  while Count < MaxBlockInsts + 1 do
  begin
    var Op: Word;
    if Translated then
    begin
      if ((Address xor PC) and $FFFFF000) <> 0 then
        Break;
      Op := PWord(CodePage + (Address and $FFF))^;
    end
    else
    begin
      var Page := FReadMap[Address shr 16];
      if Page = nil then
        Break;
      Op := PWord(Page + (Address and $FFFF))^;
    end;
    var Delayed := Decode(Op, Address, AMode, Slot, Insts[Count]);
    Code[Count] := Op;
    Inc(Count);
    Inc(Address, 2);
    if Slot or ((Insts[Count - 1].Flags and IFEnd) <> 0) then
      Break;
    Slot := Delayed;
    if Slot then
      Continue;
    if (Count >= MaxBlockInsts) or ((Address and $FFF) = 0) then
      Break;
  end;
  // A delayed branch whose slot could not be fetched runs by steps.
  if (Count > 0) and ((Insts[Count - 1].Flags and IFDelayed) <> 0) then
    Dec(Count);
  if Count = 0 then
    Exit;
  Inc(FBlockCount);
  Inc(FInstUsed, Count);
  Inc(FCodeUsed, Count);
  Inc(FBlocksBuilt);
  var Ops := Count;
  FuseBlock(Insts, Ops);
  B.PC := PC;
  B.Mode := AMode;
  B.Count := Ops;
  B.Words := Count;
  B.Insts := Insts;
  B.Code := Code;
  B.Translated := Translated;
  B.Phys := Phys;
  B.Epoch := FTLBEpoch;
  if Translated then
  begin
    var G := FBus.Gens[Phys shr 16];
    if G <> nil then
      B.GenPtr := @G[(Phys shr 12) and 15]
    else
      B.GenPtr := @FZeroGens[0];
    B.GenPtr2 := B.GenPtr;
  end
  else
  begin
    B.GenPtr := @FGenMap[PC shr 16][(PC shr 12) and 15];
    var Last := PC + Cardinal(Count - 1) * 2;
    B.GenPtr2 := @FGenMap[Last shr 16][(Last shr 12) and 15];
  end;
  B.Gen := B.GenPtr^;
  B.Gen2 := B.GenPtr2^;
  B.Idle := False;
  B.Link[0] := nil;
  B.Link[1] := nil;
  var Bucket := (PC shr 1) and (BlockBuckets - 1);
  B.Next := FBlockHead[Bucket];
  FBlockHead[Bucket] := B;
  Result := B;
end;

{ Control }

constructor TSH4.Create(const Bus: TSH4Bus; NowCounter, DeadlineCounter: PInt64);
begin
  inherited Create;
  if (Bus.ReadPages = nil) or (Bus.WritePages = nil) or (Bus.Gens = nil) or
    not Assigned(Bus.Read) or not Assigned(Bus.Write) or not Assigned(Bus.Burst) then
    raise EArgumentException.Create('SH-4 requires complete bus tables and callbacks');
  if (NowCounter = nil) or (DeadlineCounter = nil) then
    raise EArgumentException.Create('SH-4 requires time counters');
  FBus := Bus;
  Now := NowCounter;
  Deadline := DeadlineCounter;
  FBlocksEnabled := True;
  IdleSkipping := True;
  Reset;
end;

procedure TSH4.SetStepHook(Hook: TSH4StepHook; User: Pointer);
begin
  FStepHook := Hook;
  FStepUser := User;
  ClearBlocks;
end;

procedure TSH4.SetFetchHook(Fetch: TSH4Fetch; User: Pointer);
begin
  FFetch := Fetch;
  FFetchUser := User;
  ClearBlocks;
end;

procedure TSH4.SetIllegalHook(Hook: TSH4IllegalHook; User: Pointer);
begin
  FIllegalHook := Hook;
  FIllegalUser := User;
end;

procedure TSH4.Reset;
begin
  S := Default(TSH4State);
  S.PC := $A0000000;
  S.SR := $700000F0;
  S.T := 0;
  S.FPSCR := $00040001;
  FIRQLevel := 0;
  FIRQCode := 0;
  FFault := False;
  FExitRequest := False;
  BuildMaps;
  ClearBlocks;
  UpdateUTLBKeys;
  TLBFlush;
end;

procedure TSH4.SetInterrupt(Level: Integer; Code: Cardinal);
begin
  FIRQLevel := Level;
  FIRQCode := Code;
  if Level > Integer((S.SR shr 4) and 15) then
    FExitRequest := True;
end;

procedure TSH4.RequestExit;
begin
  FExitRequest := True;
end;

procedure TSH4.Run;
begin
  FHostMaskSaved := GetExceptionMask;
  FHostRoundSaved := GetRoundMode;
  SetExceptionMask(exAllArithmeticExceptions);
  ApplyHostRounding;
  try
    RunBlocks;
  finally
    ClearExceptions(False);
    SetExceptionMask(FHostMaskSaved);
    SetRoundMode(FHostRoundSaved);
  end;
end;

{ Wait loops }

// Programs wait for an interrupt-driven change by polling memory, often with
// a timeout counter. Such a loop is recognised by observing two iterations:
// no device access, exception or system call; every store writes back the
// value already in memory except a single word that drops by one (the
// timeout); registers come back unchanged but for copies of that word; and
// both iterations take the same time. Until the next scheduler event nothing
// else can change what the loop reads, so further iterations would repeat
// exactly: the clock, the counter and its copies advance by whole iterations
// at once, stopping short of any value the loop could compare the counter
// with. The result equals running the iterations.

procedure TSH4.JournalWrite(A: Cardinal; Size: Integer);
begin
  // Direct-mapped memory: system RAM through P0 (untranslated), P1 or P2.
  var P := FReadMap[A shr 16];
  if P = nil then
  begin
    FJournalFull := True;
    Exit;
  end;
  var Phys := A and $1FFFFFFF;
  if not ((A shr 29) in [0, 4, 5]) then
    Phys := $FFFFFFFF;
  JournalHost(A, P + (A and $FFFF), @FGenMap[A shr 16][(A shr 12) and 15], Phys, Size);
end;

procedure TSH4.JournalHost(A: Cardinal; Host: PByte; Gen: PCardinal; Phys: Cardinal; Size: Integer);
begin
  for var K := 0 to FJournalCount - 1 do
    if FJournal[K].Host = Host then
    begin
      if FJournal[K].Size <> Size then
        FJournalFull := True;
      Exit;
    end;
  if FJournalCount > High(FJournal) then
  begin
    FJournalFull := True;
    Exit;
  end;
  var Old: UInt64;
  case Size of
    1: Old := Host^;
    2: Old := PWord(Host)^;
    4: Old := PCardinal(Host)^;
  else
    Old := PUInt64(Host)^;
  end;
  FJournal[FJournalCount].Address := A;
  FJournal[FJournalCount].Size := Size;
  FJournal[FJournalCount].Old := Old;
  FJournal[FJournalCount].Host := Host;
  FJournal[FJournalCount].Gen := Gen;
  FJournal[FJournalCount].Phys := Phys;
  Inc(FJournalCount);
end;

function TSH4.IdleIteration(out Counter: Cardinal; out Delta: Int64): Boolean;
begin
  Result := False;
  Counter := 0;
  Delta := 0;
  var Cycles := Now^ - FIdleNow0;
  if (FSideEffects <> FIdleSide0) or FJournalFull or (Cycles <= 0) or (Cycles > 512) or S.DelaySlot then
    Exit;
  var OldValue, NewValue: Cardinal;
  OldValue := 0;
  NewValue := 0;
  for var K := 0 to FJournalCount - 1 do
  begin
    var A := FJournal[K].Address;
    // System RAM only.
    if (FJournal[K].Phys < $0C000000) or (FJournal[K].Phys >= $10000000) then
      Exit;
    var P := FJournal[K].Host;
    var Current: UInt64;
    case FJournal[K].Size of
      1: Current := P^;
      2: Current := PWord(P)^;
      4: Current := PCardinal(P)^;
    else
      Current := PUInt64(P)^;
    end;
    if Current = FJournal[K].Old then
      Continue;
    if (FJournal[K].Size <> 4) or (Counter <> 0) or (Cardinal(Current) <> Cardinal(FJournal[K].Old) - 1) then
      Exit;
    Counter := A;
    FIdleCounterHost := P;
    FIdleCounterGen := FJournal[K].Gen;
    OldValue := Cardinal(FJournal[K].Old);
    NewValue := Cardinal(Current);
    Delta := -1;
  end;
  for var I := 0 to 15 do
    if (S.R[I] <> FIdleStart.R[I]) and not ((Counter <> 0) and (FIdleStart.R[I] = OldValue) and (S.R[I] = NewValue)) then
      Exit;
  // The TLB arrays change through P4 writes (side effects) or LDTLB, which
  // moves the translation epoch; the operand-cache RAM through the bus path.
  Result := (FTLBEpoch = FIdleEpoch) and
    CompareMem(@S.RBank, @FIdleStart.RBank, NativeUInt(@S.UTLB) - NativeUInt(@S.RBank));
end;

procedure TSH4.KeepIdleStart;
begin
  // The state up to the TLB arrays (see IdleIteration).
  Move(S, FIdleStart, NativeUInt(@S.UTLB) - NativeUInt(@S));
  FIdleEpoch := FTLBEpoch;
end;

procedure TSH4.IdleCheck;
begin
  if Now^ = FIdleNow0 then
    Exit;
  var Counter: Cardinal;
  var Delta: Int64;
  if not IdleIteration(Counter, Delta) or ((FIdlePhase = 2) and
    ((Now^ - FIdleNow0 <> FIdleCycles) or (Counter <> FIdleCounter))) then
  begin
    FIdleRejected := FIdleHead;
    if FIdleSkipped = FIdleHead then
      FIdleSkipped := 0;
    FIdlePhase := 0;
    FIdleHits := 0;
    FJournalOn := False;
    Exit;
  end;
  if FIdlePhase = 1 then
  begin
    // A second iteration must repeat the first.
    FIdlePhase := 2;
    FIdleCycles := Now^ - FIdleNow0;
    FIdleCounter := Counter;
    KeepIdleStart;
    FIdleNow0 := Now^;
    FIdleSide0 := FSideEffects;
    FJournalCount := 0;
    FJournalFull := False;
    Exit;
  end;
  FIdlePhase := 0;
  FIdleHits := 0;
  FJournalOn := False;
  // Whole iterations up to the next event, leaving the last ones to run.
  var Iterations := (Deadline^ - Now^) div FIdleCycles - 1;
  var Copies: Cardinal := 0;
  var Value: Cardinal := 0;
  if Counter <> 0 then
  begin
    Value := PCardinal(FIdleCounterHost)^;
    for var I := 0 to 15 do
      if (S.R[I] = Value) and (FIdleStart.R[I] = Value + 1) then
        Copies := Copies or (Cardinal(1) shl I);
    // Stop before the counter reaches 1, or any value a register holds.
    if Value < 3 then
      Exit;
    Iterations := Min(Iterations, Int64(Value) - 2);
    for var I := 0 to 15 do
      if ((Copies shr I) and 1 = 0) and (S.R[I] < Value) and (Int64(Value) - S.R[I] <= Iterations) then
        Iterations := Int64(Value) - S.R[I] - 1;
    for var I := 0 to 7 do
      if (S.RBank[I] < Value) and (Int64(Value) - S.RBank[I] <= Iterations) then
        Iterations := Int64(Value) - S.RBank[I] - 1;
  end;
  if Iterations <= 0 then
    Exit;
  FIdleSkipped := FIdleHead;
  Inc(Now^, Iterations * FIdleCycles);
  Inc(InstructionsExecuted, Iterations * FIdleCycles);
  Inc(IdleCyclesSkipped, Iterations * FIdleCycles);
  if Counter <> 0 then
  begin
    var NewValue := Value - Cardinal(Iterations);
    PCardinal(FIdleCounterHost)^ := NewValue;
    Inc(FIdleCounterGen^, Cardinal(Iterations));
    for var I := 0 to 15 do
      if (Copies shr I) and 1 <> 0 then
        S.R[I] := NewValue;
  end;
end;

procedure TSH4.RunBlocks;
var
  Prev, B: PSH4Block;
  Next: Cardinal;
  Count: Integer;
begin
  // Kept apart from Run's exception frame so its variables stay in registers.
  FExitRequest := False;
  Prev := nil;
  // A probe never spans scheduler events (they may change memory).
  FIdlePhase := 0;
  FIdleHits := 0;
  FJournalOn := False;
  while Now^ < Deadline^ do
  begin
    if (FIdlePhase <> 0) and (S.PC = FIdleHead) then
      IdleCheck;
    if (FIRQLevel > Integer((S.SR shr 4) and 15)) and ((S.SR and SRBL) = 0) and not S.DelaySlot then
    begin
      S.INTEVT := FIRQCode;
      if S.Sleeping then
        S.PC := S.PC + 2;
      EnterException(0, $600, S.PC);
      Inc(Now^);
    end;
    if S.Sleeping then
    begin
      Now^ := Deadline^;
      Break;
    end;
    B := nil;
    if FBlocksEnabled and not S.DelaySlot and not Assigned(FFetch) and not Assigned(FStepHook) then
    begin
      var AMode := Mode;
      // The previous block remembers its last two successors.
      if Prev <> nil then
      begin
        B := Prev.Link[0];
        if (B = nil) or (B.PC <> S.PC) or (B.Mode <> AMode) then
        begin
          B := Prev.Link[1];
          if (B <> nil) and ((B.PC <> S.PC) or (B.Mode <> AMode)) then
            B := nil;
        end;
        if (B <> nil) and ((B.GenPtr^ <> B.Gen) or (B.GenPtr2^ <> B.Gen2)) and not BlockValid(B) then
          B := nil;
        if (B <> nil) and B.Translated and (B.Epoch <> FTLBEpoch) and not BlockMapped(B) then
          B := nil;
      end;
      if B = nil then
      begin
        B := FindBlock(S.PC, AMode);
        if B = nil then
          B := BuildBlock(S.PC, AMode);
        if (Prev <> nil) and (B <> nil) then
        begin
          Prev.Link[1] := Prev.Link[0];
          Prev.Link[0] := B;
        end;
      end;
    end;
    if B <> nil then
    begin
      Count := Execute(B.Insts, B.Count, Next) + FFusedExtra;
      FFusedExtra := 0;
      S.PC := Next;
      Inc(InstructionsExecuted, Count);
      if Count = 0 then
        Count := 1;
      Inc(Now^, Count);
      // A short backward branch closes a loop; one entered often enough is
      // probed as a possible wait loop.
      var Last := B.PC + Cardinal(B.Words) * 2;
      if (Next < Last) and (Last - Next <= 256) and (FIdlePhase = 0) then
      begin
        if Next <> FIdleHead then
        begin
          FIdleHead := Next;
          FIdleHits := 0;
        end
        else
        begin
          Inc(FIdleHits);
          if ((FIdleHits >= 16) or (Next = FIdleSkipped)) and IdleSkipping and (Next <> FIdleRejected) and
            not S.DelaySlot then
          begin
            FIdlePhase := 1;
            KeepIdleStart;
            FIdleNow0 := Now^;
            FIdleSide0 := FSideEffects;
            FJournalCount := 0;
            FJournalFull := False;
            FJournalOn := True;
          end;
        end;
      end;
    end
    else
      Step;
    Prev := B;
    if FExitRequest then
    begin
      FExitRequest := False;
      Break;
    end;
  end;
end;

procedure TSH4.Step;
begin
  Inc(FSideEffects);
  var SavedMask := GetExceptionMask;
  var SavedRound := GetRoundMode;
  SetExceptionMask(exAllArithmeticExceptions);
  ApplyHostRounding;
  try
    if (FIRQLevel > Integer((S.SR shr 4) and 15)) and ((S.SR and SRBL) = 0) and not S.DelaySlot then
    begin
      S.INTEVT := FIRQCode;
      if S.Sleeping then
        S.PC := S.PC + 2;
      EnterException(0, $600, S.PC);
    end;
    Inc(Now^);
    if S.Sleeping then
      Exit;
    if Assigned(FStepHook) then
      FStepHook(FStepUser, S.PC);
    var Op: Word;
    var Slot := S.DelaySlot;
    if not FetchWord(S.PC, Op) then
    begin
      FScratch[0].Addr := S.PC;
      FScratch[0].Flags := 0;
      if Slot then
        FScratch[0].Flags := IFSlot;
      Fault(S.EXPEVT, FScratch[0], Slot);
      Exit;
    end;
    Decode(Op, S.PC, Mode, Slot, FScratch[0]);
    var Next: Cardinal;
    var Count := Execute(@FScratch[0], 1, Next);
    S.PC := Next;
    Inc(InstructionsExecuted, Count);
  finally
    ClearExceptions(False);
    SetExceptionMask(SavedMask);
    SetRoundMode(SavedRound);
  end;
end;

procedure TSH4.SerializeState(Archive: TStateArchive);
begin
  Archive.Field(S, SizeOf(S));
  if Archive.Loading then
  begin
    S.T := S.T and 1;
    S.SR := S.SR and SH4SRWriteMask and not Cardinal(SRT);
    S.FPSCR := S.FPSCR and SH4FPSCRMask;
    FFault := False;
    BuildMaps;
    ClearBlocks;
    UpdateUTLBKeys;
    TLBFlush;
  end;
end;

procedure InitOps;
begin
  for var K := Low(TOp) to High(TOp) do
    @SH4Ops[K] := @TSH4.OpNOP;
  @SH4Ops[oADD] := @TSH4.OpADD;
  @SH4Ops[oADDC] := @TSH4.OpADDC;
  @SH4Ops[oADDI] := @TSH4.OpADDI;
  @SH4Ops[oADDV] := @TSH4.OpADDV;
  @SH4Ops[oAND] := @TSH4.OpAND;
  @SH4Ops[oANDB] := @TSH4.OpANDB;
  @SH4Ops[oANDI] := @TSH4.OpANDI;
  @SH4Ops[oBF] := @TSH4.OpBF;
  @SH4Ops[oBFS] := @TSH4.OpBFS;
  @SH4Ops[oBRA] := @TSH4.OpBRA;
  @SH4Ops[oBRAF] := @TSH4.OpBRAF;
  @SH4Ops[oBSR] := @TSH4.OpBSR;
  @SH4Ops[oBSRF] := @TSH4.OpBSRF;
  @SH4Ops[oBT] := @TSH4.OpBT;
  @SH4Ops[oBTS] := @TSH4.OpBTS;
  @SH4Ops[oCLRMAC] := @TSH4.OpCLRMAC;
  @SH4Ops[oCLRS] := @TSH4.OpCLRS;
  @SH4Ops[oCLRT] := @TSH4.OpCLRT;
  @SH4Ops[oCMPEQ] := @TSH4.OpCMPEQ;
  @SH4Ops[oCMPEQI] := @TSH4.OpCMPEQI;
  @SH4Ops[oCMPGE] := @TSH4.OpCMPGE;
  @SH4Ops[oCMPGT] := @TSH4.OpCMPGT;
  @SH4Ops[oCMPHI] := @TSH4.OpCMPHI;
  @SH4Ops[oCMPHS] := @TSH4.OpCMPHS;
  @SH4Ops[oCMPPL] := @TSH4.OpCMPPL;
  @SH4Ops[oCMPPZ] := @TSH4.OpCMPPZ;
  @SH4Ops[oCMPSTR] := @TSH4.OpCMPSTR;
  @SH4Ops[oDABS] := @TSH4.OpDABS;
  @SH4Ops[oDADD] := @TSH4.OpDADD;
  @SH4Ops[oDCMPEQ] := @TSH4.OpDCMPEQ;
  @SH4Ops[oDCMPGT] := @TSH4.OpDCMPGT;
  @SH4Ops[oDDIV] := @TSH4.OpDADD;
  @SH4Ops[oDFLOAT] := @TSH4.OpDFLOAT;
  @SH4Ops[oDFTRC] := @TSH4.OpDFTRC;
  @SH4Ops[oDIV0S] := @TSH4.OpDIV0S;
  @SH4Ops[oDIV0U] := @TSH4.OpDIV0U;
  @SH4Ops[oDIV1] := @TSH4.OpDIV1;
  @SH4Ops[oDIVROT] := @TSH4.OpROTDIV;
  @SH4Ops[oDMUL] := @TSH4.OpDADD;
  @SH4Ops[oDMULS] := @TSH4.OpDMULS;
  @SH4Ops[oDMULU] := @TSH4.OpDMULU;
  @SH4Ops[oDNEG] := @TSH4.OpDNEG;
  @SH4Ops[oDSQRT] := @TSH4.OpDSQRT;
  @SH4Ops[oDSUB] := @TSH4.OpDADD;
  @SH4Ops[oDT] := @TSH4.OpDT;
  @SH4Ops[oEXTSB] := @TSH4.OpEXTSB;
  @SH4Ops[oEXTSW] := @TSH4.OpEXTSW;
  @SH4Ops[oEXTUB] := @TSH4.OpEXTUB;
  @SH4Ops[oEXTUW] := @TSH4.OpEXTUW;
  @SH4Ops[oFABS] := @TSH4.OpFABS;
  @SH4Ops[oFADD] := @TSH4.OpFADD;
  @SH4Ops[oFCMPEQ] := @TSH4.OpFCMPEQ;
  @SH4Ops[oFCMPGT] := @TSH4.OpFCMPGT;
  @SH4Ops[oFCNVDS] := @TSH4.OpFCNVDS;
  @SH4Ops[oFCNVSD] := @TSH4.OpFCNVSD;
  @SH4Ops[oFDIV] := @TSH4.OpFDIV;
  @SH4Ops[oFIPR] := @TSH4.OpFIPR;
  @SH4Ops[oFLDI0] := @TSH4.OpFLDI0;
  @SH4Ops[oFLDI1] := @TSH4.OpFLDI1;
  @SH4Ops[oFLDS] := @TSH4.OpFLDS;
  @SH4Ops[oFLOAT] := @TSH4.OpFLOAT;
  @SH4Ops[oFMAC] := @TSH4.OpFMAC;
  @SH4Ops[oFMOV] := @TSH4.OpFMOV;
  @SH4Ops[oFMOVD] := @TSH4.OpFMOVD;
  @SH4Ops[oFMOVDLD] := @TSH4.OpFMOVDLD;
  @SH4Ops[oFMOVDLD0] := @TSH4.OpFMOVDLD;
  @SH4Ops[oFMOVDLDP] := @TSH4.OpFMOVDLD;
  @SH4Ops[oFMOVDST] := @TSH4.OpFMOVDST;
  @SH4Ops[oFMOVDST0] := @TSH4.OpFMOVDST;
  @SH4Ops[oFMOVDSTM] := @TSH4.OpFMOVDST;
  @SH4Ops[oFMOVLD] := @TSH4.OpFMOVLD;
  @SH4Ops[oFMOVLD0] := @TSH4.OpFMOVLD0;
  @SH4Ops[oFMOVLDP] := @TSH4.OpFMOVLDP;
  @SH4Ops[oFMOVST] := @TSH4.OpFMOVST;
  @SH4Ops[oFMOVST0] := @TSH4.OpFMOVST0;
  @SH4Ops[oFMOVSTM] := @TSH4.OpFMOVSTM;
  @SH4Ops[oFMUL] := @TSH4.OpFMUL;
  @SH4Ops[oFNEG] := @TSH4.OpFNEG;
  @SH4Ops[oFPUDisabled] := @TSH4.OpIllegal;
  @SH4Ops[oFRCHG] := @TSH4.OpFRCHG;
  @SH4Ops[oFSCA] := @TSH4.OpFSCA;
  @SH4Ops[oFSCHG] := @TSH4.OpFSCHG;
  @SH4Ops[oFSQRT] := @TSH4.OpFSQRT;
  @SH4Ops[oFSRRA] := @TSH4.OpFSRRA;
  @SH4Ops[oFSTS] := @TSH4.OpFSTS;
  @SH4Ops[oFSUB] := @TSH4.OpFSUB;
  @SH4Ops[oFTRC] := @TSH4.OpFTRC;
  @SH4Ops[oFTRV] := @TSH4.OpFTRV;
  @SH4Ops[oIllegal] := @TSH4.OpIllegal;
  @SH4Ops[oJMP] := @TSH4.OpJMP;
  @SH4Ops[oJSR] := @TSH4.OpJSR;
  @SH4Ops[oLDCBANK] := @TSH4.OpLDCBANK;
  @SH4Ops[oLDCDBR] := @TSH4.OpLDCDBR;
  @SH4Ops[oLDCGBR] := @TSH4.OpLDCGBR;
  @SH4Ops[oLDCMBANK] := @TSH4.OpLDCMSR;
  @SH4Ops[oLDCMDBR] := @TSH4.OpLDCMSR;
  @SH4Ops[oLDCMGBR] := @TSH4.OpLDCMSR;
  @SH4Ops[oLDCMSPC] := @TSH4.OpLDCMSR;
  @SH4Ops[oLDCMSR] := @TSH4.OpLDCMSR;
  @SH4Ops[oLDCMSSR] := @TSH4.OpLDCMSR;
  @SH4Ops[oLDCMVBR] := @TSH4.OpLDCMSR;
  @SH4Ops[oLDCSPC] := @TSH4.OpLDCSPC;
  @SH4Ops[oLDCSR] := @TSH4.OpLDCSR;
  @SH4Ops[oLDCSSR] := @TSH4.OpLDCSSR;
  @SH4Ops[oLDCVBR] := @TSH4.OpLDCVBR;
  @SH4Ops[oLDSFPSCR] := @TSH4.OpLDSFPSCR;
  @SH4Ops[oLDSFPUL] := @TSH4.OpLDSFPUL;
  @SH4Ops[oLDSMACH] := @TSH4.OpLDSMACH;
  @SH4Ops[oLDSMACL] := @TSH4.OpLDSMACL;
  @SH4Ops[oLDSMFPSCR] := @TSH4.OpLDCMSR;
  @SH4Ops[oLDSMFPUL] := @TSH4.OpLDCMSR;
  @SH4Ops[oLDSMMACH] := @TSH4.OpLDCMSR;
  @SH4Ops[oLDSMMACL] := @TSH4.OpLDCMSR;
  @SH4Ops[oLDSMPR] := @TSH4.OpLDCMSR;
  @SH4Ops[oLDSPR] := @TSH4.OpLDSPR;
  @SH4Ops[oLDTLB] := @TSH4.OpLDTLB;
  @SH4Ops[oMACL] := @TSH4.OpMACL;
  @SH4Ops[oMACW] := @TSH4.OpMACW;
  @SH4Ops[oMOV] := @TSH4.OpMOV;
  @SH4Ops[oMOVA] := @TSH4.OpMOVA;
  @SH4Ops[oMOVBL] := @TSH4.OpMOVBL;
  @SH4Ops[oMOVBL0] := @TSH4.OpMOVBL0;
  @SH4Ops[oMOVBL4] := @TSH4.OpMOVBL4;
  @SH4Ops[oMOVBLG] := @TSH4.OpMOVBLG;
  @SH4Ops[oMOVBM] := @TSH4.OpMOVBM;
  @SH4Ops[oMOVBP] := @TSH4.OpMOVBP;
  @SH4Ops[oMOVBS] := @TSH4.OpMOVBS;
  @SH4Ops[oMOVBS0] := @TSH4.OpMOVBS0;
  @SH4Ops[oMOVBS4] := @TSH4.OpMOVBS4;
  @SH4Ops[oMOVBSG] := @TSH4.OpMOVBSG;
  @SH4Ops[oMOVCAL] := @TSH4.OpMOVCAL;
  @SH4Ops[oMOVI] := @TSH4.OpMOVI;
  @SH4Ops[oMOVLL] := @TSH4.OpMOVLL;
  @SH4Ops[oMOVLL0] := @TSH4.OpMOVLL0;
  @SH4Ops[oMOVLL4] := @TSH4.OpMOVLL4;
  @SH4Ops[oMOVLLG] := @TSH4.OpMOVLLG;
  @SH4Ops[oMOVLM] := @TSH4.OpMOVLM;
  @SH4Ops[oMOVLP] := @TSH4.OpMOVLP;
  @SH4Ops[oMOVLPC] := @TSH4.OpMOVLPC;
  @SH4Ops[oMOVLS] := @TSH4.OpMOVLS;
  @SH4Ops[oMOVLS0] := @TSH4.OpMOVLS0;
  @SH4Ops[oMOVLS4] := @TSH4.OpMOVLS4;
  @SH4Ops[oMOVLSG] := @TSH4.OpMOVLSG;
  @SH4Ops[oMOVT] := @TSH4.OpMOVT;
  @SH4Ops[oMOVWL] := @TSH4.OpMOVWL;
  @SH4Ops[oMOVWL0] := @TSH4.OpMOVWL0;
  @SH4Ops[oMOVWL4] := @TSH4.OpMOVWL4;
  @SH4Ops[oMOVWLG] := @TSH4.OpMOVWLG;
  @SH4Ops[oMOVWM] := @TSH4.OpMOVWM;
  @SH4Ops[oMOVWP] := @TSH4.OpMOVWP;
  @SH4Ops[oMOVWPC] := @TSH4.OpMOVWPC;
  @SH4Ops[oMOVWS] := @TSH4.OpMOVWS;
  @SH4Ops[oMOVWS0] := @TSH4.OpMOVWS0;
  @SH4Ops[oMOVWS4] := @TSH4.OpMOVWS4;
  @SH4Ops[oMOVWSG] := @TSH4.OpMOVWSG;
  @SH4Ops[oMULL] := @TSH4.OpMULL;
  @SH4Ops[oMULSW] := @TSH4.OpMULSW;
  @SH4Ops[oMULUW] := @TSH4.OpMULUW;
  @SH4Ops[oNEG] := @TSH4.OpNEG;
  @SH4Ops[oNEGC] := @TSH4.OpNEGC;
  @SH4Ops[oNOT] := @TSH4.OpNOT;
  @SH4Ops[oOR] := @TSH4.OpOR;
  @SH4Ops[oORB] := @TSH4.OpANDB;
  @SH4Ops[oORI] := @TSH4.OpORI;
  @SH4Ops[oPREF] := @TSH4.OpPREF;
  @SH4Ops[oROTCL] := @TSH4.OpROTCL;
  @SH4Ops[oROTCR] := @TSH4.OpROTCR;
  @SH4Ops[oROTDIV] := @TSH4.OpROTDIV;
  @SH4Ops[oROTL] := @TSH4.OpROTL;
  @SH4Ops[oROTR] := @TSH4.OpROTR;
  @SH4Ops[oRTE] := @TSH4.OpRTE;
  @SH4Ops[oRTS] := @TSH4.OpRTS;
  @SH4Ops[oSETS] := @TSH4.OpSETS;
  @SH4Ops[oSETT] := @TSH4.OpSETT;
  @SH4Ops[oSHAD] := @TSH4.OpSHAD;
  @SH4Ops[oSHAL] := @TSH4.OpSHAL;
  @SH4Ops[oSHAR] := @TSH4.OpSHAR;
  @SH4Ops[oSHLD] := @TSH4.OpSHLD;
  @SH4Ops[oSHLL] := @TSH4.OpSHAL;
  @SH4Ops[oSHLL16] := @TSH4.OpSHLL16;
  @SH4Ops[oSHLL2] := @TSH4.OpSHLL2;
  @SH4Ops[oSHLL8] := @TSH4.OpSHLL8;
  @SH4Ops[oSHLR] := @TSH4.OpSHLR;
  @SH4Ops[oSHLR16] := @TSH4.OpSHLR16;
  @SH4Ops[oSHLR2] := @TSH4.OpSHLR2;
  @SH4Ops[oSHLR8] := @TSH4.OpSHLR8;
  @SH4Ops[oSLEEP] := @TSH4.OpSLEEP;
  @SH4Ops[oSTCBANK] := @TSH4.OpSTCBANK;
  @SH4Ops[oSTCDBR] := @TSH4.OpSTCDBR;
  @SH4Ops[oSTCGBR] := @TSH4.OpSTCGBR;
  @SH4Ops[oSTCMBANK] := @TSH4.OpSTCMSR;
  @SH4Ops[oSTCMDBR] := @TSH4.OpSTCMSR;
  @SH4Ops[oSTCMGBR] := @TSH4.OpSTCMSR;
  @SH4Ops[oSTCMSGR] := @TSH4.OpSTCMSR;
  @SH4Ops[oSTCMSPC] := @TSH4.OpSTCMSR;
  @SH4Ops[oSTCMSR] := @TSH4.OpSTCMSR;
  @SH4Ops[oSTCMSSR] := @TSH4.OpSTCMSR;
  @SH4Ops[oSTCMVBR] := @TSH4.OpSTCMSR;
  @SH4Ops[oSTCSGR] := @TSH4.OpSTCSGR;
  @SH4Ops[oSTCSPC] := @TSH4.OpSTCSPC;
  @SH4Ops[oSTCSR] := @TSH4.OpSTCSR;
  @SH4Ops[oSTCSSR] := @TSH4.OpSTCSSR;
  @SH4Ops[oSTCVBR] := @TSH4.OpSTCVBR;
  @SH4Ops[oSTSFPSCR] := @TSH4.OpSTSFPSCR;
  @SH4Ops[oSTSFPUL] := @TSH4.OpSTSFPUL;
  @SH4Ops[oSTSMACH] := @TSH4.OpSTSMACH;
  @SH4Ops[oSTSMACL] := @TSH4.OpSTSMACL;
  @SH4Ops[oSTSMFPSCR] := @TSH4.OpSTCMSR;
  @SH4Ops[oSTSMFPUL] := @TSH4.OpSTCMSR;
  @SH4Ops[oSTSMMACH] := @TSH4.OpSTCMSR;
  @SH4Ops[oSTSMMACL] := @TSH4.OpSTCMSR;
  @SH4Ops[oSTSMPR] := @TSH4.OpSTCMSR;
  @SH4Ops[oSTSPR] := @TSH4.OpSTSPR;
  @SH4Ops[oSUB] := @TSH4.OpSUB;
  @SH4Ops[oSUBC] := @TSH4.OpSUBC;
  @SH4Ops[oSUBV] := @TSH4.OpSUBV;
  @SH4Ops[oSWAPB] := @TSH4.OpSWAPB;
  @SH4Ops[oSWAPW] := @TSH4.OpSWAPW;
  @SH4Ops[oSlotFPUDisabled] := @TSH4.OpIllegal;
  @SH4Ops[oSlotIllegal] := @TSH4.OpIllegal;
  @SH4Ops[oTASB] := @TSH4.OpTASB;
  @SH4Ops[oTRAPA] := @TSH4.OpTRAPA;
  @SH4Ops[oTST] := @TSH4.OpTST;
  @SH4Ops[oTSTB] := @TSH4.OpANDB;
  @SH4Ops[oTSTI] := @TSH4.OpTSTI;
  @SH4Ops[oXOR] := @TSH4.OpXOR;
  @SH4Ops[oXORB] := @TSH4.OpANDB;
  @SH4Ops[oXORI] := @TSH4.OpXORI;
  @SH4Ops[oXTRCT] := @TSH4.OpXTRCT;
end;

initialization
  InitOps;

end.
