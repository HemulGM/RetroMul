unit Core.RAR.Types;
{$IFDEF FPC}{$MODE Delphi}{$H+}{$ENDIF}

// Free Pascal port of Unrar
// Unrar by Alexander Roshal
// Port by www.xelitan.com
// License: MIT
// The code cannot be used to recreate RAR compression

//  Shared constants, type definitions and abstract base classes
//  for the Free Pascal unrar decompressor translation.

{$POINTERMATH ON}
{$Q-}{$R-}

interface

// ── PackDef constants ──────────────────────────────────────────────────────
const
  MAX_LZ_MATCH = $1001;
  MAX_INC_LZ_MATCH = MAX_LZ_MATCH + 3;
  MAX3_LZ_MATCH = $101;
  MAX3_INC_LZ_MATCH = MAX3_LZ_MATCH + 3;
  LOW_DIST_REP_COUNT = 16;
  NC = 306;
  DCB = 64;
  DCX = 80;
  LDC = 16;
  RC = 44;
  HUFF_TABLE_SIZEB = NC + DCB + RC + LDC;
  HUFF_TABLE_SIZEX = NC + DCX + RC + LDC;
  BC = 20;
  NC30 = 299;
  DC30 = 60;
  LDC30 = 17;
  RC30 = 28;
  BC30 = 20;
  HUFF_TABLE_SIZE30 = NC30 + DC30 + RC30 + LDC30;
  NC20 = 298;
  DC20 = 48;
  RC20 = 28;
  BC20 = 19;
  MC20 = 257;
  LARGEST_TABLE_SIZE = 306;

// ── Filter type IDs ────────────────────────────────────────────────────────
  FILTER_DELTA = 0;
  FILTER_E8 = 1;
  FILTER_E8E9 = 2;
  FILTER_ARM = 3;
  FILTER_AUDIO = 4;
  FILTER_RGB = 5;
  FILTER_ITANIUM = 6;
  FILTER_TEXT = 7;
  FILTER_NONE = 11;

// ── Unpack control ─────────────────────────────────────────────────────────
  MAX_QUICK_DECODE_BITS = 9;
  MAX_UNPACK_FILTERS = 8192;
  MAX3_UNPACK_FILTERS = 8192;
  MAX3_UNPACK_CHANNELS = 1024;
  MAX_FILTER_BLOCK_SIZE = $400000;
  UNPACK_MAX_WRITE = $400000;
  UNPACK_MAX_DICT = UInt64($10000000000);

// ── VM ─────────────────────────────────────────────────────────────────────
  VM_MEMSIZE = $40000;
  VM_MEMMASK = VM_MEMSIZE - 1;

// ── PPM ────────────────────────────────────────────────────────────────────
  PPM_INT_BITS = 7;
  PPM_PERIOD_BITS = 7;
  PPM_TOT_BITS = PPM_INT_BITS + PPM_PERIOD_BITS;
  PPM_INTERVAL = 1 shl PPM_INT_BITS;
  PPM_BIN_SCALE = 1 shl PPM_TOT_BITS;
  PPM_MAX_FREQ = 124;
  PPM_MAX_O = 64;
  PPM_TOP = LongWord(1 shl 24);
  PPM_BOT = LongWord(1 shl 15);
  PPM_FIXED_UNIT = 12;  // original algorithm's assumed unit size

// ── RAR version codes ──────────────────────────────────────────────────────
  VER_PACK5 = 50;
  VER_PACK7 = 70;

// ── BitInput ───────────────────────────────────────────────────────────────
  BITINPUT_MAX_SIZE = $8000;

// ── Block types (RAR 3.x) ──────────────────────────────────────────────────
  BLOCK_LZ = 0;
  BLOCK_PPM = 1;

// =============================================================================
type

// ── Huffman decode table ───────────────────────────────────────────────────
  TDecodeTable = record
    MaxNum: LongWord;
    DecodeLen: array[0..15] of LongWord;
    DecodePos: array[0..15] of LongWord;
    QuickBits: LongWord;
    QuickLen: array[0..(1 shl MAX_QUICK_DECODE_BITS) - 1] of Byte;
    QuickNum: array[0..(1 shl MAX_QUICK_DECODE_BITS) - 1] of Word;
    DecodeNum: array[0..LARGEST_TABLE_SIZE - 1] of Word;
  end;

  PDecodeTable = ^TDecodeTable;

  TUnpackBlockHeader = record
    BlockSize: Integer;
    BlockBitSize: Integer;
    BlockStart: Integer;
    HeaderSize: Integer;
    LastBlockInFile: Boolean;
    TablePresent: Boolean;
  end;

  TUnpackBlockTables = record
    LD, DD, LDD, RD, BD: TDecodeTable;
  end;

  PUnpackBlockTables = ^TUnpackBlockTables;

  TUnpackFilter = record
    FilterType: Byte;
    Channels: Byte;
    NextWindow: Boolean;
    BlockStart: NativeUInt;
    BlockLength: LongWord;
  end;

  PUnpackFilter = ^TUnpackFilter;

// ── RarVM types ────────────────────────────────────────────────────────────
  TVMStandardFilter = (
    VMSF_NONE, VMSF_E8, VMSF_E8E9, VMSF_ITANIUM,
    VMSF_RGB, VMSF_AUDIO, VMSF_DELTA);

  TVM_PreparedProgram = record
    FilterType: TVMStandardFilter;
    InitR: array[0..6] of LongWord;
    FilteredData: PByte;
    FilteredDataSize: LongWord;
  end;

  PVM_PreparedProgram = ^TVM_PreparedProgram;

  TUnpackFilter30 = record
    BlockStart: LongWord;
    BlockLength: LongWord;
    NextWindow: Boolean;
    ParentFilter: LongWord;
    Prg: TVM_PreparedProgram;
  end;

  PUnpackFilter30 = ^TUnpackFilter30;

// ── RAR 2.0 audio variables ────────────────────────────────────────────────
  TAudioVariables = record
    K1, K2, K3, K4, K5: Integer;
    D1, D2, D3, D4: Integer;
    LastDelta: Integer;
    Dif: array[0..10] of LongWord;
    ByteCount: LongWord;
    LastChar: Integer;
  end;

// ── PPM structures (packed to match C++ layout) ────────────────────────────
  PRARPPM_MEM_BLK = ^TRARPPM_MEM_BLK;

  PRARPPM_CONTEXT = ^TRARPPM_CONTEXT;

  PRARPPM_STATE = ^TRARPPM_STATE;

  TRARPPM_STATE = packed record
    Symbol: Byte;
    Freq: Byte;
    Successor: PRARPPM_CONTEXT;
  end;

  // Union: FreqData (SummFreq + Stats) overlaps OneState (Symbol+Freq+Successor)
  TRARPPM_U = packed record
    case Byte of
      0:
        (SummFreq: Word;
        Stats: PRARPPM_STATE);
      1:
        (OneState: TRARPPM_STATE);
  end;

  TRARPPM_CONTEXT = packed record
    NumStats: Word;
    U: TRARPPM_U;
    Suffix: PRARPPM_CONTEXT;
  end;

  TRARPPM_MEM_BLK = packed record
    Stamp: Word;
    NU: Word;
    next: PRARPPM_MEM_BLK;
    prev: PRARPPM_MEM_BLK;
  end;

  TRARPPM_SEE2_CONTEXT = packed record
    Summ: Word;
    Shift: Byte;
    Count: Byte;
  end;

  PRARPPM_SEE2_CONTEXT = ^TRARPPM_SEE2_CONTEXT;

// ── RangeCoder ─────────────────────────────────────────────────────────────
// Forward-declare abstract reader used by RangeCoder so ppm unit
// need not reference the full TUnpack.
  TUnpackBase = class
  public
    function GetChar: Byte; virtual; abstract;
  end;

  TRangeCoderSubRange = record
    LowCount, HighCount, scale: LongWord;
  end;

  TRangeCoder = record
    low, code, range: LongWord;
    SubRange: TRangeCoderSubRange;
    UnpackRead: TUnpackBase;
    procedure InitDecoder(AReader: TUnpackBase);
    function GetCurrentCount: Integer;          {$IFDEF FPC} inline;{$ENDIF}
    function GetCurrentShiftCount(AShift: LongWord): LongWord; {$IFDEF FPC} inline;{$ENDIF}
    procedure Decode;                            {$IFDEF FPC} inline;{$ENDIF}
    function CoderGetChar: Byte;                {$IFDEF FPC} inline;{$ENDIF}
  end;

// ── Abstract I/O ───────────────────────────────────────────────────────────
  TComprDataIO = class
  public
    function UnpRead(Addr: PByte; Count: Integer): Integer; virtual; abstract;
    procedure UnpWrite(Addr: PByte; Count: NativeUInt); virtual; abstract;
  end;

// =============================================================================
implementation

{ TRangeCoder }

procedure TRangeCoder.InitDecoder(AReader: TUnpackBase);
var
  I: Integer;
begin
  UnpackRead := AReader;
  low := 0;
  code := 0;
  range := $FFFFFFFF;
  for I := 0 to 3 do
    code := (code shl 8) or CoderGetChar;
end;

function TRangeCoder.GetCurrentCount: Integer;
begin
  // C++: return (code-low)/(range /= SubRange.scale);
  range := range div SubRange.scale;
  Result := Integer((code - low) div range);
end;

function TRangeCoder.GetCurrentShiftCount(AShift: LongWord): LongWord;
begin
  // C++: return (code-low)/(range >>= SHIFT);
  range := range shr AShift;
  Result := (code - low) div range;
end;

procedure TRangeCoder.Decode;
begin
  // C++: low += range*SubRange.LowCount; range *= HighCount-LowCount;
  Inc(low, range * SubRange.LowCount);
  range := range * (SubRange.HighCount - SubRange.LowCount);
end;

function TRangeCoder.CoderGetChar: Byte;
begin
  Result := UnpackRead.GetChar;
end;

end.

