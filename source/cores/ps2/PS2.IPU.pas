unit PS2.IPU;

// Image processing unit: the MPEG-1/MPEG-2 macroblock decoder behind DMA
// channels 4 (toIPU, the bit stream) and 3 (fromIPU, decoded data).
// The decoding follows ISO/IEC 13818-2 (and 11172-2 for MPEG-1 streams):
// macroblock syntax, the VLC tables of Annex B, inverse scan, inverse
// quantisation with mismatch control (MPEG-1 oddification) and the IDCT
// (a separable fixed-point transform written for this unit). Colour space
// conversion uses the ITU-R BT.601 equations for studio-range YCbCr.
// The commands (BCLR, IDEC, BDEC, VDEC, FDEC, SETIQ, SETVQ, CSC, PACK,
// SETTH), registers and FIFOs follow the IPU documentation (ps2tek) and the
// way ps2sdk's libmpeg drives the unit. Commands run as data arrives and may
// stop at any syntax element when the input FIFO (8 quadwords plus a
// 2-quadword decode buffer) runs dry; results queue in the output FIFO until
// DMA or the CPU takes them. Finished commands raise the IPU interrupt.
{$IFDEF PS2_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$POINTERMATH ON}

interface

uses
  System.SysUtils, System.Classes, System.Math, Core.Snapshots, PS2.Types,
  PS2.Scheduler, PS2.EE.Bus, PS2.DMAC;

type
  // A prefix code indexed by the next Bits bits of the stream: each entry is
  // (code length shl 24) or value; 0 where no code starts.
  TPS2IPUCode = record
    Bits: Integer;
    Entries: TArray<Cardinal>;
  end;

  TPS2IPUState = record
    CTRL, Data, Command: Cardinal;
    // Data holds an FDEC/VDEC result (until then IPU_CMD shows the stream).
    DataValid: Boolean;
    Busy: Boolean;
    TH0, TH1: Cardinal;
    // Quantiser matrices in raster order.
    IntraW, NonIntraW: array[0..63] of Byte;
    VQCLUT: array[0..15] of Word;
    DCPred: array[0..2] of Integer;
    // Input: Size bytes (whole quadwords); the stream is at bit Bit of the
    // first quadword. Bytes past the capacity are slack for reads.
    Buf: array[0..175] of Byte;
    Size, Bit: Integer;
    // Command progress.
    Step, Index, MBCount: Integer;
    // The macroblock in progress (BDEC, IDEC).
    MBStep, MBType, QScaleCode, DCTType, CBP, Block, Coef, DCSize: Integer;
    MBIntra, MBResetDC, MBFieldDCT: Boolean;
    Blocks: array[0..5, 0..63] of SmallInt;
    // CSC/PACK input macroblock.
    Raw: array[0..1023] of Byte;
  end;

  TPS2IPU = class(TPS2Device)
  private
    FScheduler: TPS2Scheduler;
    FDMAC: TPS2DMAC;
    FOnInterrupt: TProc;
    FOut: TBytes;
    FOutHead, FOutSize: Integer;
    FPumping, FAgain: Boolean;
    FAddrInc, FTypeI, FTypeP, FTypeB, FTypeD, FMotion, FDMV, FDCLum, FDCChrom, FPattern, FCoefB14, FCoefB15: TPS2IPUCode;
    // Bit stream.
    function Avail: Integer; inline;
    function Peek(N: Integer): Cardinal; inline;
    procedure Skip(N: Integer);
    function TryRead(N: Integer; out V: Cardinal): Boolean;
    function PeekTop: Cardinal;
    function ZerosAhead(N: Integer): Integer;
    function Lookup(const T: TPS2IPUCode; out Value: Cardinal; out Len: Integer): Integer;
    function Decode(const T: TPS2IPUCode; out Value: Cardinal): Integer;
    function DecodeCoefficient(First: Boolean; out Run, Level: Integer; out EndOfBlock: Boolean): Integer;
    // Commands.
    procedure StartCommand(Value: Cardinal);
    procedure Execute;
    procedure Finish(Flags: Cardinal);
    function RunMacroblock: Integer;
    function RunBlock: Integer;
    procedure ReconstructBlock(B: Integer);
    procedure MacroblockRaw16(Dest: PSmallInt);
    function RunBDEC: Integer;
    function RunIDEC: Integer;
    function RunVDEC: Integer;
    function RunFDEC: Integer;
    function RunSETIQ: Integer;
    function RunSETVQ: Integer;
    function RunCSC: Integer;
    function RunPACK: Integer;
    procedure ConvertColour(Raw: PByte; RGB16, Signed: Boolean);
    // Data flow.
    procedure OutWrite(Data: Pointer; Size: Integer);
    procedure RequestPump;
    procedure Pump;
    procedure FIFOState(out BP, IFC, FP: Cardinal);
  public
    S: TPS2IPUState;
    // Diagnostics: commands started, macroblocks decoded, bytes output.
    Commands, Macroblocks, OutBytes: Int64;
    CommandCounts: array[0..15] of Int64;
    // Diagnostics: commands other than VDEC/FDEC/BDEC when assigned (all
    // of them, the latest kept, with TraceAll).
    Trace: TStrings;
    TraceAll: Boolean;
    // Diagnostics (with Trace): the last input bytes, their total and the
    // stream bit where the current command started; an error dumps the
    // command's input.
    InHistory: TBytes;
    InTotal, CommandStartBit: Int64;
    constructor Create(Scheduler: TPS2Scheduler; DMAC: TPS2DMAC);
    procedure Reset;
    function Read(Address: Cardinal; Size: Integer): UInt64; override;
    procedure Write(Address: Cardinal; Value: UInt64; Size: Integer); override;
    procedure WriteFIFO(Address: Cardinal; const Value: TPS2Reg128); override;
    procedure ReadFIFO(Address: Cardinal; out Value: TPS2Reg128); override;
    // DMA: quadwords into the input FIFO / out of the output FIFO (how many
    // moved; fewer stalls the channel).
    function TakeInput(Data: PByte; Count: Integer): Integer;
    function GiveOutput(Data: PByte; Count: Integer): Integer;
    // Scheduler event: the command goes on with the data DMA brought.
    procedure Event;
    procedure SerializeState(State: TStateArchive);
    property OnInterrupt: TProc read FOnInterrupt write FOnInterrupt;
  end;

  TPS2IPUPort = class(TPS2DMAPort)
  private
    FIPU: TPS2IPU;
  public
    constructor Create(IPU: TPS2IPU);
    function Push(Channel: Integer; Data: PByte; Count: Integer): Integer; override;
    function Pull(Channel: Integer; Data: PByte; Count: Integer): Integer; override;
  end;

implementation

type
  // A code from Annex B: its bits (MSB first) and its value.
  TCodeDef = record
    Code: string;
    Value: Integer;
  end;

const
  // Results of a command step.
  RunWait = 0;
  RunDone = 1;
  RunStartCode = 2;
  RunError = 3;
  CtrlECD = $00004000;
  CtrlSCD = $00008000;
  CtrlAS = $00100000;
  CtrlIVF = $00200000;
  CtrlQST = $00400000;
  CtrlMP1 = $00800000;
  CtrlRST = $40000000;

  // Input FIFO (8 quadwords) and decode buffer (2 quadwords), in bytes.
  InCapacity = 160;

  // DCT coefficient code values: run shl 8 or level; or one of these.
  CoefEscape = $10000;
  CoefEOB = $20000;

  // Scan position -> raster position (ISO/IEC 13818-2 figures 7-2, 7-3).
  ZigZag: array[0..63] of Byte = (
    0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5,
    12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63);
  Alternate: array[0..63] of Byte = (
    0, 8, 16, 24, 1, 9, 2, 10, 17, 25, 32, 40, 48, 56, 57, 49,
    41, 33, 26, 18, 3, 11, 4, 12, 19, 27, 34, 42, 50, 58, 35, 43,
    51, 59, 20, 28, 5, 13, 6, 14, 21, 29, 36, 44, 52, 60, 37, 45,
    53, 61, 22, 30, 7, 15, 23, 31, 38, 46, 54, 62, 39, 47, 55, 63);

  // Default intra quantiser matrix, raster order (6.3.11); the default
  // non-intra matrix is 16 everywhere.
  DefaultIntra: array[0..63] of Byte = (
    8, 16, 19, 22, 26, 27, 29, 34,
    16, 16, 22, 24, 27, 29, 34, 37,
    19, 22, 26, 27, 29, 34, 34, 38,
    22, 22, 26, 27, 29, 34, 37, 40,
    22, 26, 27, 29, 32, 35, 40, 48,
    26, 27, 29, 32, 35, 40, 48, 58,
    26, 27, 29, 34, 38, 46, 56, 69,
    27, 29, 35, 38, 46, 56, 69, 83);

  // quantiser_scale for q_scale_type 1 (table 7-6).
  NonLinearScale: array[0..31] of Byte = (
    0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 12, 14, 16, 18, 20, 22,
    24, 28, 32, 36, 40, 44, 48, 52, 56, 64, 72, 80, 88, 96, 104, 112);

  // ISO/IEC 13818-2 Annex B. Sign bits that follow a code are not part of it.

  // B.1 macroblock_address_increment; 34 = stuffing (MPEG-1), 35 = escape.
  AddrIncCodes: array[0..34] of TCodeDef = (
    (Code: '1'; Value: 1), (Code: '011'; Value: 2), (Code: '010'; Value: 3), (Code: '0011'; Value: 4),
    (Code: '0010'; Value: 5), (Code: '00011'; Value: 6), (Code: '00010'; Value: 7), (Code: '0000111'; Value: 8),
    (Code: '0000110'; Value: 9), (Code: '00001011'; Value: 10), (Code: '00001010'; Value: 11),
    (Code: '00001001'; Value: 12), (Code: '00001000'; Value: 13), (Code: '00000111'; Value: 14),
    (Code: '00000110'; Value: 15), (Code: '0000010111'; Value: 16), (Code: '0000010110'; Value: 17),
    (Code: '0000010101'; Value: 18), (Code: '0000010100'; Value: 19), (Code: '0000010011'; Value: 20),
    (Code: '0000010010'; Value: 21), (Code: '00000100011'; Value: 22), (Code: '00000100010'; Value: 23),
    (Code: '00000100001'; Value: 24), (Code: '00000100000'; Value: 25), (Code: '00000011111'; Value: 26),
    (Code: '00000011110'; Value: 27), (Code: '00000011101'; Value: 28), (Code: '00000011100'; Value: 29),
    (Code: '00000011011'; Value: 30), (Code: '00000011010'; Value: 31), (Code: '00000011001'; Value: 32),
    (Code: '00000011000'; Value: 33), (Code: '00000001111'; Value: 34), (Code: '00000001000'; Value: 35));

  // B.2-B.4 macroblock_type: quant 10h, motion forward 8, motion backward 4,
  // pattern 2, intra 1. D pictures (MPEG-1) have intra macroblocks only.
  TypeICodes: array[0..1] of TCodeDef = ((Code: '1'; Value: $01), (Code: '01'; Value: $11));
  TypePCodes: array[0..6] of TCodeDef = (
    (Code: '1'; Value: $0A), (Code: '01'; Value: $02), (Code: '001'; Value: $08), (Code: '00011'; Value: $01),
    (Code: '00010'; Value: $1A), (Code: '00001'; Value: $12), (Code: '000001'; Value: $11));
  TypeBCodes: array[0..10] of TCodeDef = (
    (Code: '10'; Value: $0C), (Code: '11'; Value: $0E), (Code: '010'; Value: $04), (Code: '011'; Value: $06),
    (Code: '0010'; Value: $08), (Code: '0011'; Value: $0A), (Code: '00011'; Value: $01),
    (Code: '00010'; Value: $1E), (Code: '000011'; Value: $1A), (Code: '000010'; Value: $16),
    (Code: '000001'; Value: $11));
  TypeDCodes: array[0..0] of TCodeDef = ((Code: '1'; Value: $01));

  // B.9 coded_block_pattern.
  PatternCodes: array[0..63] of TCodeDef = (
    (Code: '111'; Value: 60), (Code: '1101'; Value: 4), (Code: '1100'; Value: 8), (Code: '1011'; Value: 16),
    (Code: '1010'; Value: 32), (Code: '10011'; Value: 12), (Code: '10010'; Value: 48), (Code: '10001'; Value: 20),
    (Code: '10000'; Value: 40), (Code: '01111'; Value: 28), (Code: '01110'; Value: 44), (Code: '01101'; Value: 52),
    (Code: '01100'; Value: 56), (Code: '01011'; Value: 1), (Code: '01010'; Value: 61), (Code: '01001'; Value: 2),
    (Code: '01000'; Value: 62), (Code: '001111'; Value: 24), (Code: '001110'; Value: 36), (Code: '001101'; Value: 3),
    (Code: '001100'; Value: 63), (Code: '0010111'; Value: 5), (Code: '0010110'; Value: 9),
    (Code: '0010101'; Value: 17), (Code: '0010100'; Value: 33), (Code: '0010011'; Value: 6),
    (Code: '0010010'; Value: 10), (Code: '0010001'; Value: 18), (Code: '0010000'; Value: 34),
    (Code: '00011111'; Value: 7), (Code: '00011110'; Value: 11), (Code: '00011101'; Value: 19),
    (Code: '00011100'; Value: 35), (Code: '00011011'; Value: 13), (Code: '00011010'; Value: 49),
    (Code: '00011001'; Value: 21), (Code: '00011000'; Value: 41), (Code: '00010111'; Value: 14),
    (Code: '00010110'; Value: 50), (Code: '00010101'; Value: 22), (Code: '00010100'; Value: 42),
    (Code: '00010011'; Value: 15), (Code: '00010010'; Value: 51), (Code: '00010001'; Value: 23),
    (Code: '00010000'; Value: 43), (Code: '00001111'; Value: 25), (Code: '00001110'; Value: 37),
    (Code: '00001101'; Value: 26), (Code: '00001100'; Value: 38), (Code: '00001011'; Value: 29),
    (Code: '00001010'; Value: 45), (Code: '00001001'; Value: 53), (Code: '00001000'; Value: 57),
    (Code: '00000111'; Value: 30), (Code: '00000110'; Value: 46), (Code: '00000101'; Value: 54),
    (Code: '00000100'; Value: 58), (Code: '000000111'; Value: 31), (Code: '000000110'; Value: 47),
    (Code: '000000101'; Value: 55), (Code: '000000100'; Value: 59), (Code: '000000011'; Value: 27),
    (Code: '000000010'; Value: 39), (Code: '000000001'; Value: 0));

  // B.10 motion_code magnitudes 0..16; a sign bit (1 = negative) follows
  // every code but the one for 0.
  MotionCodes: array[0..16] of string = (
    '1', '01', '001', '0001', '000011', '0000101', '0000100', '0000011', '000001011', '000001010',
    '000001001', '0000010001', '0000010000', '0000001111', '0000001110', '0000001101', '0000001100');

  // B.11 dmvector.
  DMVCodes: array[0..2] of TCodeDef = ((Code: '0'; Value: 0), (Code: '10'; Value: 1), (Code: '11'; Value: -1));

  // B.12/B.13 dct_dc_size_luminance / dct_dc_size_chrominance.
  DCLumCodes: array[0..11] of TCodeDef = (
    (Code: '100'; Value: 0), (Code: '00'; Value: 1), (Code: '01'; Value: 2), (Code: '101'; Value: 3),
    (Code: '110'; Value: 4), (Code: '1110'; Value: 5), (Code: '11110'; Value: 6), (Code: '111110'; Value: 7),
    (Code: '1111110'; Value: 8), (Code: '11111110'; Value: 9), (Code: '111111110'; Value: 10),
    (Code: '111111111'; Value: 11));
  DCChromCodes: array[0..11] of TCodeDef = (
    (Code: '00'; Value: 0), (Code: '01'; Value: 1), (Code: '10'; Value: 2), (Code: '110'; Value: 3),
    (Code: '1110'; Value: 4), (Code: '11110'; Value: 5), (Code: '111110'; Value: 6), (Code: '1111110'; Value: 7),
    (Code: '11111110'; Value: 8), (Code: '111111110'; Value: 9), (Code: '1111111110'; Value: 10),
    (Code: '1111111111'; Value: 11));

  // B.14/B.15 dct_coefficients: value = run shl 8 or level (a sign bit
  // follows), CoefEOB or CoefEscape. In B.14 the first coefficient of a
  // non-intra block uses '1s' for run 0, level 1 (handled in code).
  // Codes of 14 bits and more are common to both tables.
  CoefCommonCodes: array[0..36] of TCodeDef = (
    (Code: '00000000011111'; Value: 16), (Code: '00000000011110'; Value: 17), (Code: '00000000011101'; Value: 18),
    (Code: '00000000011100'; Value: 19), (Code: '00000000011011'; Value: 20), (Code: '00000000011010'; Value: 21),
    (Code: '00000000011001'; Value: 22), (Code: '00000000011000'; Value: 23), (Code: '00000000010111'; Value: 24),
    (Code: '00000000010110'; Value: 25), (Code: '00000000010101'; Value: 26), (Code: '00000000010100'; Value: 27),
    (Code: '00000000010011'; Value: 28), (Code: '00000000010010'; Value: 29), (Code: '00000000010001'; Value: 30),
    (Code: '00000000010000'; Value: 31),
    (Code: '000000000011000'; Value: 32), (Code: '000000000010111'; Value: 33), (Code: '000000000010110'; Value: 34),
    (Code: '000000000010101'; Value: 35), (Code: '000000000010100'; Value: 36), (Code: '000000000010011'; Value: 37),
    (Code: '000000000010010'; Value: 38), (Code: '000000000010001'; Value: 39), (Code: '000000000010000'; Value: 40),
    (Code: '000000000011111'; Value: $108), (Code: '000000000011110'; Value: $109),
    (Code: '000000000011101'; Value: $10A), (Code: '000000000011100'; Value: $10B),
    (Code: '000000000011011'; Value: $10C), (Code: '000000000011010'; Value: $10D),
    (Code: '000000000011001'; Value: $10E),
    (Code: '0000000000010011'; Value: $10F), (Code: '0000000000010010'; Value: $110),
    (Code: '0000000000010001'; Value: $111), (Code: '0000000000010000'; Value: $112),
    (Code: '0000000000010100'; Value: $603));
  CoefCommonCodes2: array[0..10] of TCodeDef = (
    (Code: '0000000000011010'; Value: $B02), (Code: '0000000000011001'; Value: $C02),
    (Code: '0000000000011000'; Value: $D02), (Code: '0000000000010111'; Value: $E02),
    (Code: '0000000000010110'; Value: $F02), (Code: '0000000000010101'; Value: $1002),
    (Code: '0000000000011111'; Value: $1B01), (Code: '0000000000011110'; Value: $1C01),
    (Code: '0000000000011101'; Value: $1D01), (Code: '0000000000011100'; Value: $1E01),
    (Code: '0000000000011011'; Value: $1F01));
  CoefB14Codes: array[0..64] of TCodeDef = (
    (Code: '10'; Value: CoefEOB), (Code: '11'; Value: $001), (Code: '011'; Value: $101), (Code: '0100'; Value: $002),
    (Code: '0101'; Value: $201), (Code: '00101'; Value: $003), (Code: '00111'; Value: $301),
    (Code: '00110'; Value: $401), (Code: '000110'; Value: $102), (Code: '000111'; Value: $501),
    (Code: '000101'; Value: $601), (Code: '000100'; Value: $701), (Code: '0000110'; Value: $004),
    (Code: '0000100'; Value: $202), (Code: '0000111'; Value: $801), (Code: '0000101'; Value: $901),
    (Code: '000001'; Value: CoefEscape),
    (Code: '00100110'; Value: $005), (Code: '00100001'; Value: $006), (Code: '00100101'; Value: $103),
    (Code: '00100100'; Value: $302), (Code: '00100111'; Value: $A01), (Code: '00100011'; Value: $B01),
    (Code: '00100010'; Value: $C01), (Code: '00100000'; Value: $D01),
    (Code: '0000001010'; Value: $007), (Code: '0000001100'; Value: $104), (Code: '0000001011'; Value: $203),
    (Code: '0000001111'; Value: $402), (Code: '0000001001'; Value: $502), (Code: '0000001110'; Value: $E01),
    (Code: '0000001101'; Value: $F01), (Code: '0000001000'; Value: $1001),
    (Code: '000000011101'; Value: $008), (Code: '000000011000'; Value: $009), (Code: '000000010011'; Value: $00A),
    (Code: '000000010000'; Value: $00B), (Code: '000000011011'; Value: $105), (Code: '000000010100'; Value: $204),
    (Code: '000000011100'; Value: $303), (Code: '000000010010'; Value: $403), (Code: '000000011110'; Value: $602),
    (Code: '000000010101'; Value: $702), (Code: '000000010001'; Value: $802), (Code: '000000011111'; Value: $1101),
    (Code: '000000011010'; Value: $1201), (Code: '000000011001'; Value: $1301), (Code: '000000010111'; Value: $1401),
    (Code: '000000010110'; Value: $1501),
    (Code: '0000000011010'; Value: $00C), (Code: '0000000011001'; Value: $00D), (Code: '0000000011000'; Value: $00E),
    (Code: '0000000010111'; Value: $00F), (Code: '0000000010110'; Value: $106), (Code: '0000000010101'; Value: $107),
    (Code: '0000000010100'; Value: $205), (Code: '0000000010011'; Value: $304), (Code: '0000000010010'; Value: $503),
    (Code: '0000000010001'; Value: $902), (Code: '0000000010000'; Value: $A02), (Code: '0000000011111'; Value: $1601),
    (Code: '0000000011110'; Value: $1701), (Code: '0000000011101'; Value: $1801), (Code: '0000000011100'; Value: $1901),
    (Code: '0000000011011'; Value: $1A01));
  CoefB15Codes: array[0..60] of TCodeDef = (
    (Code: '0110'; Value: CoefEOB), (Code: '10'; Value: $001), (Code: '010'; Value: $101), (Code: '110'; Value: $002),
    (Code: '00101'; Value: $201), (Code: '0111'; Value: $003), (Code: '00111'; Value: $301),
    (Code: '000110'; Value: $401), (Code: '00110'; Value: $102), (Code: '000111'; Value: $501),
    (Code: '0000110'; Value: $601), (Code: '0000100'; Value: $701), (Code: '11100'; Value: $004),
    (Code: '0000111'; Value: $202), (Code: '0000101'; Value: $801), (Code: '1111000'; Value: $901),
    (Code: '000001'; Value: CoefEscape),
    (Code: '11101'; Value: $005), (Code: '000101'; Value: $006), (Code: '1111001'; Value: $103),
    (Code: '00100110'; Value: $302), (Code: '1111010'; Value: $A01), (Code: '00100001'; Value: $B01),
    (Code: '00100101'; Value: $C01), (Code: '00100100'; Value: $D01), (Code: '000100'; Value: $007),
    (Code: '00100111'; Value: $104), (Code: '11111100'; Value: $203), (Code: '11111101'; Value: $402),
    (Code: '000000100'; Value: $502), (Code: '000000101'; Value: $E01), (Code: '000000111'; Value: $F01),
    (Code: '0000001101'; Value: $1001), (Code: '1111011'; Value: $008), (Code: '1111100'; Value: $009),
    (Code: '00100011'; Value: $00A), (Code: '00100010'; Value: $00B), (Code: '00100000'; Value: $105),
    (Code: '0000001100'; Value: $204), (Code: '000000011100'; Value: $303), (Code: '000000010010'; Value: $403),
    (Code: '000000011110'; Value: $602), (Code: '000000010101'; Value: $702), (Code: '000000010001'; Value: $802),
    (Code: '000000011111'; Value: $1101), (Code: '000000011010'; Value: $1201), (Code: '000000011001'; Value: $1301),
    (Code: '000000010111'; Value: $1401), (Code: '000000010110'; Value: $1501),
    (Code: '11111010'; Value: $00C), (Code: '11111011'; Value: $00D), (Code: '11111110'; Value: $00E),
    (Code: '11111111'; Value: $00F), (Code: '0000000010110'; Value: $106), (Code: '0000000010101'; Value: $107),
    (Code: '0000000010100'; Value: $205), (Code: '0000000010011'; Value: $304), (Code: '0000000010010'; Value: $503),
    (Code: '0000000010001'; Value: $902), (Code: '0000000010000'; Value: $A02), (Code: '0000000011111'; Value: $1601));
  CoefB15Codes2: array[0..3] of TCodeDef = (
    (Code: '0000000011110'; Value: $1701), (Code: '0000000011101'; Value: $1801),
    (Code: '0000000011100'; Value: $1901), (Code: '0000000011011'; Value: $1A01));

procedure AddCodes(var T: TPS2IPUCode; const Defs: array of TCodeDef);
begin
  for var D in Defs do
  begin
    var Len := Length(D.Code);
    var Code: Cardinal := 0;
    for var K := 1 to Len do
      Code := (Code shl 1) or Cardinal(Ord(D.Code[K] = '1'));
    var Shift := T.Bits - Len;
    var Entry := (Cardinal(Len) shl 24) or (Cardinal(D.Value) and $FFFFFF);
    for var K := Integer(Code shl Shift) to Integer(((Code + 1) shl Shift) - 1) do
      T.Entries[K] := Entry;
  end;
end;

procedure InitCode(var T: TPS2IPUCode; Bits: Integer);
begin
  T.Bits := Bits;
  SetLength(T.Entries, 1 shl Bits);
  FillChar(T.Entries[0], Length(T.Entries) * SizeOf(Cardinal), 0);
end;

// Arithmetic shift right (floor division by 2^N).
function Sar(V: Integer; N: Integer): Integer; inline;
begin
  if V >= 0 then
    Result := V shr N
  else
    Result := -((-V + (1 shl N) - 1) shr N);
end;

{ IDCT }

// 2-D inverse DCT of an 8x8 raster block (ISO/IEC 13818-2 annex A):
// two 1-D passes, each split into even and odd halves. Cosines are scaled by
// 2^13; the row pass keeps 3 fraction bits for the column pass.
const
  IC1 = 8035; // cos(1 pi/16) * 8192
  IC2 = 7568;
  IC3 = 6811;
  IC4 = 5793;
  IC5 = 4551;
  IC6 = 3135;
  IC7 = 1598;

procedure InverseDCT(B: PSmallInt);
var
  T: array[0..63] of Integer;
begin
  for var R := 0 to 7 do
  begin
    var X := B + R * 8;
    var P := PInteger(@T[R * 8]);
    if (X[1] = 0) and (X[2] = 0) and (X[3] = 0) and (X[4] = 0) and (X[5] = 0) and (X[6] = 0) and (X[7] = 0) then
    begin
      // DC only: X0 cos(pi/4) / 2, with 3 fraction bits.
      var V := Sar(X[0] * IC4 + (1 shl 10), 11);
      for var K := 0 to 7 do
        P[K] := V;
      Continue;
    end;
    var A0 := (X[0] + X[4]) * IC4;
    var A1 := (X[0] - X[4]) * IC4;
    var A2 := X[2] * IC2 + X[6] * IC6;
    var A3 := X[2] * IC6 - X[6] * IC2;
    var E0 := A0 + A2;
    var E3 := A0 - A2;
    var E1 := A1 + A3;
    var E2 := A1 - A3;
    var O0 := X[1] * IC1 + X[3] * IC3 + X[5] * IC5 + X[7] * IC7;
    var O1 := X[1] * IC3 - X[3] * IC7 - X[5] * IC1 - X[7] * IC5;
    var O2 := X[1] * IC5 - X[3] * IC1 + X[5] * IC7 + X[7] * IC3;
    var O3 := X[1] * IC7 - X[3] * IC5 + X[5] * IC3 - X[7] * IC1;
    // (E +- O) / 2 at 2^13 -> 3 fraction bits.
    P[0] := Sar(E0 + O0 + (1 shl 10), 11);
    P[7] := Sar(E0 - O0 + (1 shl 10), 11);
    P[1] := Sar(E1 + O1 + (1 shl 10), 11);
    P[6] := Sar(E1 - O1 + (1 shl 10), 11);
    P[2] := Sar(E2 + O2 + (1 shl 10), 11);
    P[5] := Sar(E2 - O2 + (1 shl 10), 11);
    P[3] := Sar(E3 + O3 + (1 shl 10), 11);
    P[4] := Sar(E3 - O3 + (1 shl 10), 11);
  end;
  for var C := 0 to 7 do
  begin
    var X0 := Int64(T[C]);
    var X1 := Int64(T[8 + C]);
    var X2 := Int64(T[16 + C]);
    var X3 := Int64(T[24 + C]);
    var X4 := Int64(T[32 + C]);
    var X5 := Int64(T[40 + C]);
    var X6 := Int64(T[48 + C]);
    var X7 := Int64(T[56 + C]);
    var A0 := (X0 + X4) * IC4;
    var A1 := (X0 - X4) * IC4;
    var A2 := X2 * IC2 + X6 * IC6;
    var A3 := X2 * IC6 - X6 * IC2;
    var E0 := A0 + A2;
    var E3 := A0 - A2;
    var E1 := A1 + A3;
    var E2 := A1 - A3;
    var O0 := X1 * IC1 + X3 * IC3 + X5 * IC5 + X7 * IC7;
    var O1 := X1 * IC3 - X3 * IC7 - X5 * IC1 - X7 * IC5;
    var O2 := X1 * IC5 - X3 * IC1 + X5 * IC7 + X7 * IC3;
    var O3 := X1 * IC7 - X3 * IC5 + X5 * IC3 - X7 * IC1;
    // (E +- O) / 2 at 2^(13+3) -> integer, rounded to nearest.
    var Outs: array[0..7] of Int64;
    Outs[0] := E0 + O0;
    Outs[7] := E0 - O0;
    Outs[1] := E1 + O1;
    Outs[6] := E1 - O1;
    Outs[2] := E2 + O2;
    Outs[5] := E2 - O2;
    Outs[3] := E3 + O3;
    Outs[4] := E3 - O3;
    for var K := 0 to 7 do
    begin
      var V := Outs[K] + (Int64(1) shl 16);
      if V >= 0 then
        V := V shr 17
      else
        V := -((-V + (Int64(1) shl 17) - 1) shr 17);
      if V > 32767 then
        V := 32767
      else if V < -32768 then
        V := -32768;
      B[K * 8 + C] := SmallInt(V);
    end;
  end;
end;

{ TPS2IPU }

constructor TPS2IPU.Create(Scheduler: TPS2Scheduler; DMAC: TPS2DMAC);
begin
  inherited Create;
  FScheduler := Scheduler;
  FDMAC := DMAC;
  InitCode(FAddrInc, 11);
  AddCodes(FAddrInc, AddrIncCodes);
  InitCode(FTypeI, 2);
  AddCodes(FTypeI, TypeICodes);
  InitCode(FTypeP, 6);
  AddCodes(FTypeP, TypePCodes);
  InitCode(FTypeB, 6);
  AddCodes(FTypeB, TypeBCodes);
  InitCode(FTypeD, 1);
  AddCodes(FTypeD, TypeDCodes);
  InitCode(FPattern, 9);
  AddCodes(FPattern, PatternCodes);
  InitCode(FMotion, 11);
  var M: array[0..32] of TCodeDef;
  M[0].Code := MotionCodes[0];
  M[0].Value := 0;
  for var K := 1 to 16 do
  begin
    M[K * 2 - 1].Code := MotionCodes[K] + '0';
    M[K * 2 - 1].Value := K;
    M[K * 2].Code := MotionCodes[K] + '1';
    M[K * 2].Value := -K;
  end;
  AddCodes(FMotion, M);
  InitCode(FDMV, 2);
  AddCodes(FDMV, DMVCodes);
  InitCode(FDCLum, 9);
  AddCodes(FDCLum, DCLumCodes);
  InitCode(FDCChrom, 10);
  AddCodes(FDCChrom, DCChromCodes);
  InitCode(FCoefB14, 16);
  AddCodes(FCoefB14, CoefB14Codes);
  AddCodes(FCoefB14, CoefCommonCodes);
  AddCodes(FCoefB14, CoefCommonCodes2);
  InitCode(FCoefB15, 16);
  AddCodes(FCoefB15, CoefB15Codes);
  AddCodes(FCoefB15, CoefB15Codes2);
  AddCodes(FCoefB15, CoefCommonCodes);
  AddCodes(FCoefB15, CoefCommonCodes2);
  Reset;
end;

procedure TPS2IPU.Reset;
begin
  S := Default(TPS2IPUState);
  Move(DefaultIntra, S.IntraW, 64);
  FillChar(S.NonIntraW, 64, 16);
  FOutHead := 0;
  FOutSize := 0;
  FPumping := False;
  FAgain := False;
  FScheduler.Cancel(TPS2Event.IPU);
end;

{ Bit stream }

function TPS2IPU.Avail: Integer;
begin
  Result := S.Size * 8 - S.Bit;
  if Result < 0 then
    Result := 0;
end;

// The next N (1..32) bits, most significant first; N <= Avail.
function TPS2IPU.Peek(N: Integer): Cardinal;
begin
  var P := PByte(@S.Buf[S.Bit shr 3]);
  var V := (UInt64(P[0]) shl 32) or (UInt64(P[1]) shl 24) or (UInt64(P[2]) shl 16) or (UInt64(P[3]) shl 8) or P[4];
  Result := Cardinal((V shr (40 - (S.Bit and 7) - N)) and ((UInt64(1) shl N) - 1));
end;

// N <= Avail; quadwords fully read leave the buffer.
procedure TPS2IPU.Skip(N: Integer);
begin
  Inc(S.Bit, N);
  while (S.Bit >= 128) and (S.Size >= 16) do
  begin
    Move(S.Buf[16], S.Buf[0], S.Size - 16);
    Dec(S.Size, 16);
    Dec(S.Bit, 128);
  end;
end;

function TPS2IPU.TryRead(N: Integer; out V: Cardinal): Boolean;
begin
  V := 0;
  if Avail < N then
    Exit(False);
  if N > 0 then
  begin
    V := Peek(N);
    Skip(N);
  end;
  Result := True;
end;

// The next 32 bits, zero filled when fewer are there.
function TPS2IPU.PeekTop: Cardinal;
begin
  var N := Min(32, Avail);
  if N = 0 then
    Exit(0);
  Result := Peek(N) shl (32 - N);
end;

// 1 when the next N (<= 32) bits are zero, 0 when they are not, -1 when
// the bits there are zero but too few.
function TPS2IPU.ZerosAhead(N: Integer): Integer;
begin
  var A := Min(Avail, N);
  if (A > 0) and (Peek(A) <> 0) then
    Exit(0);
  if A < N then
    Exit(-1);
  Result := 1;
end;

function TPS2IPU.Lookup(const T: TPS2IPUCode; out Value: Cardinal; out Len: Integer): Integer;
begin
  Value := 0;
  Len := 0;
  var A := Avail;
  if A = 0 then
    Exit(RunWait);
  var Bits: Cardinal;
  if A >= T.Bits then
    Bits := Peek(T.Bits)
  else
    Bits := Peek(A) shl (T.Bits - A);
  var E := T.Entries[Bits];
  if E = 0 then
  begin
    // No code starts here (or it may, given more bits).
    if A >= T.Bits then
      Exit(RunError);
    Exit(RunWait);
  end;
  Len := Integer(E shr 24);
  if Len > A then
    Exit(RunWait);
  Value := E and $FFFFFF;
  Result := RunDone;
end;

function TPS2IPU.Decode(const T: TPS2IPUCode; out Value: Cardinal): Integer;
begin
  var Len: Integer;
  Result := Lookup(T, Value, Len);
  if Result = RunDone then
    Skip(Len);
end;

// One dct_coefficient of the current block (7.2.2.3): a run/level pair,
// an escape (6-bit run, 12-bit level; MPEG-1: 8 or 16-bit level) or the end
// of block. Nothing is consumed unless the whole element is there.
function TPS2IPU.DecodeCoefficient(First: Boolean; out Run, Level: Integer; out EndOfBlock: Boolean): Integer;
begin
  Run := 0;
  Level := 0;
  EndOfBlock := False;
  var B15 := S.MBIntra and ((S.CTRL and CtrlIVF) <> 0);
  if First and not B15 then
  begin
    // First coefficient of a non-intra block: '1s' is run 0, level 1.
    if Avail < 1 then
      Exit(RunWait);
    if Peek(1) = 1 then
    begin
      if Avail < 2 then
        Exit(RunWait);
      Level := 1;
      if (Peek(2) and 1) <> 0 then
        Level := -1;
      Skip(2);
      Exit(RunDone);
    end;
  end;
  var V: Cardinal;
  var Len: Integer;
  if B15 then
    Result := Lookup(FCoefB15, V, Len)
  else
    Result := Lookup(FCoefB14, V, Len);
  if Result <> RunDone then
    Exit;
  if V = CoefEOB then
  begin
    Skip(Len);
    EndOfBlock := True;
    Exit(RunDone);
  end;
  if V = CoefEscape then
  begin
    if (S.CTRL and CtrlMP1) = 0 then
    begin
      if Avail < Len + 18 then
        Exit(RunWait);
      var X := Peek(Len + 18);
      Run := Integer((X shr 12) and $3F);
      Level := Integer(X and $FFF);
      if Level >= $800 then
        Dec(Level, $1000);
      if (Level = 0) or (Level = -2048) then
        Exit(RunError);
      Skip(Len + 18);
    end
    else
    begin
      if Avail < Len + 14 then
        Exit(RunWait);
      var X := Peek(Len + 14);
      Run := Integer((X shr 8) and $3F);
      var L := Integer(X and $FF);
      var Total := Len + 14;
      if (L = 0) or (L = $80) then
      begin
        // 16-bit forms: 0 then 128..255, or 80h then -256..-129.
        if Avail < Len + 22 then
          Exit(RunWait);
        var L2 := Integer(Peek(Len + 22) and $FF);
        if L = 0 then
          Level := L2
        else
          Level := L2 - 256;
        Total := Len + 22;
      end
      else if L > $80 then
        Level := L - 256
      else
        Level := L;
      Skip(Total);
    end;
    Exit(RunDone);
  end;
  if Avail < Len + 1 then
    Exit(RunWait);
  Run := Integer(V shr 8);
  Level := Integer(V and $FF);
  if (Peek(Len + 1) and 1) <> 0 then
    Level := -Level;
  Skip(Len + 1);
end;

{ Macroblocks }

// The coefficients of block S.Block into S.Blocks (scan order): the DC
// differential of intra blocks, then run/level pairs up to end of block.
function TPS2IPU.RunBlock: Integer;
begin
  var B := PSmallInt(@S.Blocks[S.Block, 0]);
  if S.MBIntra and (S.Coef = 0) then
  begin
    if S.DCSize < 0 then
    begin
      var V: Cardinal;
      if S.Block < 4 then
        Result := Decode(FDCLum, V)
      else
        Result := Decode(FDCChrom, V);
      if Result <> RunDone then
        Exit;
      S.DCSize := Integer(V);
    end;
    var Diff := 0;
    if S.DCSize > 0 then
    begin
      var V: Cardinal;
      if not TryRead(S.DCSize, V) then
        Exit(RunWait);
      Diff := Integer(V);
      // A leading 0 marks a negative difference.
      if (V shr (S.DCSize - 1)) = 0 then
        Diff := Diff - (1 shl S.DCSize) + 1;
    end;
    var Ch := 0;
    if S.Block >= 4 then
      Ch := S.Block - 3;
    S.DCPred[Ch] := S.DCPred[Ch] + Diff;
    B[0] := SmallInt(EnsureRange(S.DCPred[Ch], -32768, 32767));
    S.Coef := 1;
  end;
  while True do
  begin
    var Run, Level: Integer;
    var EOB: Boolean;
    Result := DecodeCoefficient(not S.MBIntra and (S.Coef = 0), Run, Level, EOB);
    if Result <> RunDone then
      Exit;
    if EOB then
      Exit(RunDone);
    S.Coef := S.Coef + Run;
    if S.Coef > 63 then
      Exit(RunError);
    B[S.Coef] := SmallInt(Level);
    Inc(S.Coef);
  end;
end;

// Inverse scan, inverse quantisation, IDCT of block B (7.3, 7.4, annex A).
procedure TPS2IPU.ReconstructBlock(B: Integer);
var
  F: array[0..63] of Integer;
begin
  var QF := PSmallInt(@S.Blocks[B, 0]);
  var Scan := PByte(@ZigZag);
  if (S.CTRL and CtrlAS) <> 0 then
    Scan := PByte(@Alternate);
  FillChar(F, SizeOf(F), 0);
  for var N := 0 to 63 do
    F[Scan[N]] := QF[N];
  var Scale: Integer;
  if (S.CTRL and CtrlQST) <> 0 then
    Scale := NonLinearScale[S.QScaleCode and 31]
  else
    Scale := 2 * (S.QScaleCode and 31);
  var MPEG1 := (S.CTRL and CtrlMP1) <> 0;
  var W := PByte(@S.NonIntraW);
  if S.MBIntra then
    W := PByte(@S.IntraW);
  var Sum := 0;
  for var K := 0 to 63 do
  begin
    var V := F[K];
    if S.MBIntra and (K = 0) then
      V := V * (8 shr ((S.CTRL shr 16) and 3))
    else if V <> 0 then
    begin
      if S.MBIntra then
        V := (V * W[K] * Scale * 2) div 32
      else if V > 0 then
        V := ((2 * V + 1) * W[K] * Scale) div 32
      else
        V := ((2 * V - 1) * W[K] * Scale) div 32;
      // MPEG-1: reconstructed values are odd.
      if MPEG1 and (V <> 0) and not Odd(V) then
        if V > 0 then
          Dec(V)
        else
          Inc(V);
    end;
    V := EnsureRange(V, -2048, 2047);
    F[K] := V;
    Inc(Sum, V);
  end;
  // MPEG-2 mismatch control: an even sum toggles the last coefficient.
  if not MPEG1 and not Odd(Sum) then
    F[63] := F[63] xor 1;
  for var K := 0 to 63 do
    QF[K] := SmallInt(F[K]);
  InverseDCT(QF);
end;

// The current macroblock: coded block pattern, then its six blocks.
function TPS2IPU.RunMacroblock: Integer;
begin
  while True do
    case S.MBStep of
      0:
        begin
          if S.MBIntra then
            S.CBP := 63
          else
          begin
            var V: Cardinal;
            Result := Decode(FPattern, V);
            if Result <> RunDone then
              Exit;
            S.CBP := Integer(V);
          end;
          S.CTRL := (S.CTRL and not Cardinal($3F00)) or (Cardinal(S.CBP) shl 8);
          if S.MBResetDC then
          begin
            // 2^(7 + intra_dc_precision).
            var DC := 128 shl ((S.CTRL shr 16) and 3);
            S.DCPred[0] := DC;
            S.DCPred[1] := DC;
            S.DCPred[2] := DC;
          end;
          S.Block := 0;
          S.MBStep := 1;
        end;
      1:
        begin
          FillChar(S.Blocks[S.Block, 0], SizeOf(S.Blocks[0]), 0);
          if (S.CBP and (32 shr S.Block)) <> 0 then
          begin
            S.Coef := 0;
            S.DCSize := -1;
            S.MBStep := 2;
          end
          else
            S.MBStep := 3;
        end;
      2:
        begin
          Result := RunBlock;
          if Result <> RunDone then
            Exit;
          ReconstructBlock(S.Block);
          S.MBStep := 3;
        end;
      3:
        begin
          Inc(S.Block);
          if S.Block = 6 then
          begin
            S.MBStep := 4;
            Inc(Macroblocks);
          end
          else
            S.MBStep := 1;
        end;
    else
      Exit(RunDone);
    end;
end;

// RAW16 macroblock: luminance as 16x16 rows (field DCT: blocks 0/1 hold the
// even lines, 2/3 the odd ones), then Cb and Cr 8x8.
procedure TPS2IPU.MacroblockRaw16(Dest: PSmallInt);
begin
  for var Y := 0 to 15 do
    for var X := 0 to 15 do
    begin
      var Blk, Row: Integer;
      if S.MBFieldDCT then
      begin
        Blk := (Y and 1) * 2 + X shr 3;
        Row := Y shr 1;
      end
      else
      begin
        Blk := (Y shr 3) * 2 + X shr 3;
        Row := Y and 7;
      end;
      Dest[Y * 16 + X] := S.Blocks[Blk, Row * 8 + (X and 7)];
    end;
  Move(S.Blocks[4, 0], Dest[256], 128);
  Move(S.Blocks[5, 0], Dest[320], 128);
end;

// YCbCr 4:2:0 RAW8 (256 Y, 64 Cb, 64 Cr) to RGBA, BT.601 studio range; alpha
// 0 under TH0, 40h under TH1, else 80h (all of R, G, B below).
procedure TPS2IPU.ConvertColour(Raw: PByte; RGB16, Signed: Boolean);
var
  Pixels: array[0..255] of Cardinal;
  Half: array[0..255] of Word;
begin
  var TH0 := Integer(S.TH0 and $1FF);
  var TH1 := Integer(S.TH1 and $1FF);
  for var Y := 0 to 15 do
    for var X := 0 to 15 do
    begin
      var C := (Y shr 1) * 8 + (X shr 1);
      var L := 298 * (Integer(Raw[Y * 16 + X]) - 16) + 128;
      var Cb := Integer(Raw[256 + C]) - 128;
      var Cr := Integer(Raw[320 + C]) - 128;
      var R := EnsureRange(Sar(L + 409 * Cr, 8), 0, 255);
      var G := EnsureRange(Sar(L - 100 * Cb - 208 * Cr, 8), 0, 255);
      var B := EnsureRange(Sar(L + 516 * Cb, 8), 0, 255);
      var A: Cardinal := $80;
      if (R < TH0) and (G < TH0) and (B < TH0) then
        A := 0
      else if (R < TH1) and (G < TH1) and (B < TH1) then
        A := $40;
      if Signed then
      begin
        R := (R - 128) and $FF;
        G := (G - 128) and $FF;
        B := (B - 128) and $FF;
      end;
      Pixels[Y * 16 + X] := (A shl 24) or (Cardinal(B) shl 16) or (Cardinal(G) shl 8) or Cardinal(R);
    end;
  if RGB16 then
  begin
    for var K := 0 to 255 do
    begin
      var P := Pixels[K];
      Half[K] := Word(((P and $FF) shr 3) or (((P shr 8) and $F8) shl 2) or (((P shr 16) and $F8) shl 7) or
          (Cardinal(Ord((P shr 24) <> 0)) shl 15));
    end;
    OutWrite(@Half[0], SizeOf(Half));
  end
  else
    OutWrite(@Pixels[0], SizeOf(Pixels));
end;

{ Commands }

// BDEC: one macroblock (FB, QSC, DT, DCR, MBI from the command) as RAW16.
function TPS2IPU.RunBDEC: Integer;
var
  Raw: array[0..383] of SmallInt;
begin
  var Cmd := S.Command;
  while True do
    case S.Step of
      0:
        begin
          var V: Cardinal;
          if not TryRead(Integer(Cmd and $3F), V) then
            Exit(RunWait);
          S.MBIntra := (Cmd and $08000000) <> 0;
          S.MBResetDC := (Cmd and $04000000) <> 0;
          S.MBFieldDCT := (Cmd and $02000000) <> 0;
          S.QScaleCode := Integer((Cmd shr 16) and $1F);
          S.MBStep := 0;
          S.Step := 1;
        end;
      1:
        begin
          Result := RunMacroblock;
          if Result <> RunDone then
            Exit;
          MacroblockRaw16(@Raw[0]);
          OutWrite(@Raw[0], SizeOf(Raw));
          S.Step := 2;
        end;
    else
      begin
        // A start code next ends the slice (next_start_code: byte aligned).
        case ZerosAhead(23) of
          -1:
            Exit(RunWait);
          1:
            begin
              Skip(Min((8 - (S.Bit and 7)) and 7, Avail));
              Exit(RunStartCode);
            end;
        end;
        Exit(RunDone);
      end;
    end;
end;

// IDEC: the macroblocks of an intra slice, from the first macroblock_type
// (the caller read the slice header and the first address increment) to the
// next start code, each converted to RGB.
function TPS2IPU.RunIDEC: Integer;
var
  Raw16: array[0..383] of SmallInt;
  Raw8: array[0..383] of Byte;
begin
  var Cmd := S.Command;
  while True do
    case S.Step of
      0:
        begin
          var V: Cardinal;
          if not TryRead(Integer(Cmd and $3F), V) then
            Exit(RunWait);
          S.QScaleCode := Integer((Cmd shr 16) and $1F);
          S.MBCount := 0;
          S.MBResetDC := True;
          S.Step := 1;
        end;
      1:
        begin
          var V: Cardinal;
          Result := Decode(FTypeI, V);
          if Result <> RunDone then
            Exit;
          S.MBType := Integer(V);
          S.Step := 2;
        end;
      2:
        begin
          S.DCTType := 0;
          if (Cmd and $01000000) <> 0 then
          begin
            var V: Cardinal;
            if not TryRead(1, V) then
              Exit(RunWait);
            S.DCTType := Integer(V);
          end;
          S.Step := 3;
        end;
      3:
        begin
          if (S.MBType and $10) <> 0 then
          begin
            var V: Cardinal;
            if not TryRead(5, V) then
              Exit(RunWait);
            S.QScaleCode := Integer(V);
          end;
          S.MBIntra := True;
          S.MBFieldDCT := S.DCTType <> 0;
          S.MBStep := 0;
          S.Step := 4;
        end;
      4:
        begin
          Result := RunMacroblock;
          if Result <> RunDone then
            Exit;
          MacroblockRaw16(@Raw16[0]);
          for var K := 0 to 383 do
            Raw8[K] := Byte(EnsureRange(Integer(Raw16[K]), 0, 255));
          ConvertColour(@Raw8[0], (Cmd and $08000000) <> 0, (Cmd and $02000000) <> 0);
          Inc(S.MBCount);
          S.MBResetDC := False;
          S.Step := 5;
        end;
      5:
        begin
          // The next macroblock once this one has left the output FIFO.
          if FOutSize > 0 then
            Exit(RunWait);
          S.Step := 6;
        end;
      6:
        case ZerosAhead(23) of
          -1:
            Exit(RunWait);
          1:
            begin
              Skip(Min((8 - (S.Bit and 7)) and 7, Avail));
              Exit(RunStartCode);
            end;
        else
          S.Step := 7;
        end;
    else
      begin
        // macroblock_address_increment: stuffing and escapes, then 1 (skipped
        // macroblocks reset the DC predictors).
        var V: Cardinal;
        Result := Decode(FAddrInc, V);
        if Result <> RunDone then
          Exit;
        case V of
          34:
            ;
          35:
            S.MBResetDC := True;
        else
          begin
            if V > 1 then
              S.MBResetDC := True;
            S.Step := 1;
          end;
        end;
      end;
    end;
end;

// VDEC: one symbol; DATA = code length shl 16 or the value (16-bit).
function TPS2IPU.RunVDEC: Integer;
begin
  if S.Step = 0 then
  begin
    var V: Cardinal;
    if not TryRead(Integer(S.Command and $3F), V) then
      Exit(RunWait);
    S.Step := 1;
  end;
  var Value: Cardinal;
  var Len: Integer;
  case (S.Command shr 26) and 3 of
    0:
      Result := Lookup(FAddrInc, Value, Len);
    1:
      case (S.CTRL shr 24) and 7 of
        1:
          Result := Lookup(FTypeI, Value, Len);
        2:
          Result := Lookup(FTypeP, Value, Len);
        3:
          Result := Lookup(FTypeB, Value, Len);
        4:
          Result := Lookup(FTypeD, Value, Len);
      else
        Result := RunError;
      end;
    2:
      Result := Lookup(FMotion, Value, Len);
  else
    Result := Lookup(FDMV, Value, Len);
  end;
  if Result = RunError then
  begin
    S.Data := 0;
    S.DataValid := True;
  end;
  if Result <> RunDone then
    Exit;
  Skip(Len);
  S.Data := (Cardinal(Len) shl 16) or (Value and $FFFF);
  S.DataValid := True;
end;

// FDEC: the next 32 bits after FB, left in the stream.
function TPS2IPU.RunFDEC: Integer;
begin
  if S.Step = 0 then
  begin
    var V: Cardinal;
    if not TryRead(Integer(S.Command and $3F), V) then
      Exit(RunWait);
    S.Step := 1;
  end;
  if Avail < 32 then
    Exit(RunWait);
  S.Data := Peek(32);
  S.DataValid := True;
  Result := RunDone;
end;

// SETIQ: 64 matrix bytes in zigzag order (as in the sequence header).
function TPS2IPU.RunSETIQ: Integer;
begin
  if S.Step = 0 then
  begin
    var V: Cardinal;
    if not TryRead(Integer(S.Command and $3F), V) then
      Exit(RunWait);
    S.Step := 1;
  end;
  while S.Index < 64 do
  begin
    var V: Cardinal;
    if not TryRead(8, V) then
      Exit(RunWait);
    if (S.Command and $08000000) <> 0 then
      S.NonIntraW[ZigZag[S.Index]] := Byte(V)
    else
      S.IntraW[ZigZag[S.Index]] := Byte(V);
    Inc(S.Index);
  end;
  Result := RunDone;
end;

// SETVQ: the 16 RGB16 colours PACK chooses from.
function TPS2IPU.RunSETVQ: Integer;
begin
  while S.Index < 16 do
  begin
    var V: Cardinal;
    if not TryRead(16, V) then
      Exit(RunWait);
    S.VQCLUT[S.Index] := Word(V);
    Inc(S.Index);
  end;
  Result := RunDone;
end;

// CSC: MBC RAW8 macroblocks to RGB, one at a time through the output FIFO.
function TPS2IPU.RunCSC: Integer;
begin
  while True do
  begin
    if S.Step = 1 then
    begin
      if FOutSize > 0 then
        Exit(RunWait);
      S.Step := 0;
    end;
    if S.MBCount = 0 then
      Exit(RunDone);
    while S.Index < 384 do
    begin
      var V: Cardinal;
      if not TryRead(8, V) then
        Exit(RunWait);
      S.Raw[S.Index] := Byte(V);
      Inc(S.Index);
    end;
    ConvertColour(@S.Raw[0], (S.Command and $08000000) <> 0, False);
    Dec(S.MBCount);
    S.Index := 0;
    S.Step := 1;
  end;
end;

// PACK: MBC RGBA32 macroblocks to RGBA16 (OFM) or 4-bit indices of the
// nearest SETVQ colour.
function TPS2IPU.RunPACK: Integer;
var
  Half: array[0..255] of Word;
  Index4: array[0..127] of Byte;
begin
  while True do
  begin
    if S.Step = 1 then
    begin
      if FOutSize > 0 then
        Exit(RunWait);
      S.Step := 0;
    end;
    if S.MBCount = 0 then
      Exit(RunDone);
    while S.Index < 1024 do
    begin
      var V: Cardinal;
      if not TryRead(8, V) then
        Exit(RunWait);
      S.Raw[S.Index] := Byte(V);
      Inc(S.Index);
    end;
    for var K := 0 to 255 do
    begin
      var P := PByte(@S.Raw[K * 4]);
      Half[K] := Word((P[0] shr 3) or (Cardinal(P[1] shr 3) shl 5) or (Cardinal(P[2] shr 3) shl 10) or
          (Cardinal(Ord(P[3] <> 0)) shl 15));
    end;
    if (S.Command and $08000000) <> 0 then
      OutWrite(@Half[0], SizeOf(Half))
    else
    begin
      FillChar(Index4, SizeOf(Index4), 0);
      for var K := 0 to 255 do
      begin
        var Best := 0;
        var BestD := MaxInt;
        for var E := 0 to 15 do
        begin
          var C := S.VQCLUT[E];
          var DR := Integer(Half[K] and 31) - Integer(C and 31);
          var DG := Integer((Half[K] shr 5) and 31) - Integer((C shr 5) and 31);
          var DB := Integer((Half[K] shr 10) and 31) - Integer((C shr 10) and 31);
          var D := DR * DR + DG * DG + DB * DB;
          if D < BestD then
          begin
            BestD := D;
            Best := E;
          end;
        end;
        Index4[K shr 1] := Index4[K shr 1] or Byte(Best shl ((K and 1) * 4));
      end;
      OutWrite(@Index4[0], SizeOf(Index4));
    end;
    Dec(S.MBCount);
    S.Index := 0;
    S.Step := 1;
  end;
end;

procedure TPS2IPU.StartCommand(Value: Cardinal);
begin
  Inc(Commands);
  Inc(CommandCounts[Value shr 28]);
  if Trace <> nil then
    CommandStartBit := (InTotal - S.Size) * 8 + S.Bit;
  if (Trace <> nil) and TraceAll then
  begin
    if Trace.Count >= 100000 then
    begin
      var Keep := TStringList.Create;
      try
        for var K := Trace.Count - 50000 to Trace.Count - 1 do
          Keep.Add(Trace[K]);
        Trace.Assign(Keep);
      finally
        Keep.Free;
      end;
    end;
    Trace.Add(Format('%d cmd=%.8x size=%d bit=%d', [FScheduler.Now, Value, S.Size, S.Bit]));
  end
  else if (Trace <> nil) and not (Value shr 28 in [2, 3, 4]) and (Trace.Count < 100000) then
    if FDMAC <> nil then
      Trace.Add(Format('%d cmd=%.8x ctrl=%.8x d3=%.8x/%x d4=%.8x/%x', [FScheduler.Now, Value, S.CTRL,
            FDMAC.Ch[DMAFromIPU].MADR, FDMAC.Ch[DMAFromIPU].QWC, FDMAC.Ch[DMAToIPU].MADR, FDMAC.Ch[DMAToIPU].QWC]))
    else
      Trace.Add(Format('%d cmd=%.8x', [FScheduler.Now, Value]));
  S.CTRL := S.CTRL and not Cardinal(CtrlECD or CtrlSCD);
  S.Command := Value;
  S.Busy := True;
  S.Step := 0;
  S.Index := 0;
  if (Value shr 28) in [7, 8] then
    S.MBCount := Integer(Value and $7FF);
end;

procedure TPS2IPU.Finish(Flags: Cardinal);
begin
  if (Trace <> nil) and (TraceAll or (Flags = CtrlECD)) then
    Trace.Add(Format('%d done cmd=%.8x flags=%x data=%.8x size=%d bit=%d step=%d mbstep=%d block=%d coef=%d next=%.8x',
        [FScheduler.Now, S.Command, Flags, S.Data, S.Size, S.Bit, S.Step, S.MBStep, S.Block, S.Coef, PeekTop]));
  if (Trace <> nil) and (Flags = CtrlECD) and (InHistory <> nil) then
  begin
    // The command's input from its first bit (offset within the first byte).
    var First := CommandStartBit div 8;
    var Last := Min(InTotal, (InTotal - S.Size) + (S.Bit div 8) + 32);
    var Hex := '';
    for var A := First to Last - 1 do
      if InTotal - A <= Length(InHistory) then
        Hex := Hex + IntToHex(InHistory[A and $FFFF], 2);
    Trace.Add(Format('%d input bit %d: %s', [FScheduler.Now, CommandStartBit mod 8, Hex]));
  end;
  S.Busy := False;
  S.CTRL := S.CTRL or Flags;
  if Assigned(FOnInterrupt) then
    FOnInterrupt();
end;

procedure TPS2IPU.Execute;
begin
  if not S.Busy then
    Exit;
  var R: Integer;
  case S.Command shr 28 of
    0:
      begin
        // BCLR: empty input; the stream starts at bit BP of the next data.
        S.Size := 0;
        S.Bit := Integer(S.Command and $7F);
        R := RunDone;
      end;
    1:
      R := RunIDEC;
    2:
      R := RunBDEC;
    3:
      R := RunVDEC;
    4:
      R := RunFDEC;
    5:
      R := RunSETIQ;
    6:
      R := RunSETVQ;
    7:
      R := RunCSC;
    8:
      R := RunPACK;
    9:
      begin
        S.TH0 := S.Command and $1FF;
        S.TH1 := (S.Command shr 16) and $1FF;
        R := RunDone;
      end;
  else
    R := RunError;
  end;
  case R of
    RunDone:
      Finish(0);
    RunStartCode:
      Finish(CtrlSCD);
    RunError:
      Finish(CtrlECD);
  end;
end;

{ Data flow }

procedure TPS2IPU.OutWrite(Data: Pointer; Size: Integer);
begin
  if FOutHead > 0 then
  begin
    if FOutSize > 0 then
      Move(FOut[FOutHead], FOut[0], FOutSize);
    FOutHead := 0;
  end;
  if FOutSize + Size > Length(FOut) then
    SetLength(FOut, Max(FOutSize + Size, 2 * Length(FOut)));
  Move(Data^, FOut[FOutSize], Size);
  Inc(FOutSize, Size);
  Inc(OutBytes, Size);
end;

function TPS2IPU.TakeInput(Data: PByte; Count: Integer): Integer;
begin
  Result := Min(Count, (InCapacity - S.Size) div 16);
  if Result <= 0 then
    Exit(0);
  Move(Data^, S.Buf[S.Size], Result * 16);
  Inc(S.Size, Result * 16);
  if Trace <> nil then
  begin
    if InHistory = nil then
      SetLength(InHistory, $10000);
    for var K := 0 to Result * 16 - 1 do
      InHistory[(InTotal + K) and $FFFF] := S.Buf[S.Size - Result * 16 + K];
    Inc(InTotal, Result * 16);
  end;
  RequestPump;
end;

function TPS2IPU.GiveOutput(Data: PByte; Count: Integer): Integer;
begin
  Result := Min(Count, FOutSize div 16);
  if Result <= 0 then
    Exit(0);
  Move(FOut[FOutHead], Data^, Result * 16);
  Inc(FOutHead, Result * 16);
  Dec(FOutSize, Result * 16);
  if FOutSize = 0 then
    FOutHead := 0;
  RequestPump;
end;

// Data moved inside a DMA transfer: the command goes on from the pump loop,
// or right after through the scheduler.
procedure TPS2IPU.RequestPump;
begin
  if FPumping then
    FAgain := True
  else if FScheduler.Due(TPS2Event.IPU) > FScheduler.Now then
    FScheduler.Schedule(TPS2Event.IPU, FScheduler.Now);
end;

// Runs the command while the DMA channels bring input and take output.
procedure TPS2IPU.Pump;
begin
  if FPumping then
  begin
    FAgain := True;
    Exit;
  end;
  FPumping := True;
  try
    repeat
      FAgain := False;
      Execute;
      if FDMAC <> nil then
      begin
        if S.Size < InCapacity then
          FDMAC.Resume(DMAToIPU);
        if FOutSize > 0 then
          FDMAC.Resume(DMAFromIPU);
      end;
    until not FAgain;
  finally
    FPumping := False;
  end;
end;

procedure TPS2IPU.Event;
begin
  Pump;
end;

{ Registers }

// IFC: quadwords in the input FIFO; FP: quadwords in the decode buffer (the
// first two); BP: bit position in the first of them.
procedure TPS2IPU.FIFOState(out BP, IFC, FP: Cardinal);
begin
  var Q := Cardinal(S.Size div 16);
  FP := Min(Q, 2);
  IFC := Q - FP;
  BP := Cardinal(S.Bit) and $7F;
end;

function TPS2IPU.Read(Address: Cardinal; Size: Integer): UInt64;
begin
  var BP, IFC, FP: Cardinal;
  var Busy: UInt64 := Ord(S.Busy);
  case Address and $FF of
    $00:
      begin
        // DATA: the FDEC/VDEC result; before any, the stream ahead.
        if S.DataValid then
          Result := S.Data
        else
          Result := PeekTop;
        if Size = 8 then
          Result := Result or (Busy shl 63);
      end;
    $04:
      Result := Busy shl 31;
    $10:
      begin
        FIFOState(BP, IFC, FP);
        Result := S.CTRL or Cardinal(Busy shl 31) or IFC or (Cardinal(Min(FOutSize div 16, 8)) shl 4);
      end;
    $20:
      begin
        FIFOState(BP, IFC, FP);
        Result := (FP shl 16) or (IFC shl 8) or BP;
      end;
    $30:
      begin
        Result := PeekTop;
        if (Size = 8) and (S.Busy or (Avail < 32)) then
          Result := Result or (UInt64(1) shl 63);
      end;
    $34:
      if S.Busy or (Avail < 32) then
        Result := $80000000
      else
        Result := 0;
  else
    Result := 0;
  end;
end;

procedure TPS2IPU.Write(Address: Cardinal; Value: UInt64; Size: Integer);
begin
  case Address and $FF of
    $00:
      begin
        StartCommand(Cardinal(Value));
        Pump;
      end;
    $10:
      begin
        var V := Cardinal(Value);
        if (V and CtrlRST) <> 0 then
        begin
          // Reset: an executing command ends with an interrupt.
          var WasBusy := S.Busy;
          S.Busy := False;
          S.DataValid := False;
          S.Size := 0;
          S.Bit := 0;
          FOutHead := 0;
          FOutSize := 0;
          if WasBusy and Assigned(FOnInterrupt) then
            FOnInterrupt();
        end;
        S.CTRL := (S.CTRL and not Cardinal($3FFF0000)) or (V and $3FFF0000);
        Pump;
      end;
  end;
end;

procedure TPS2IPU.WriteFIFO(Address: Cardinal; const Value: TPS2Reg128);
begin
  if (Address and $F0) <> $10 then
    Exit;
  var V := Value;
  if TakeInput(@V, 1) > 0 then
    Pump;
end;

procedure TPS2IPU.ReadFIFO(Address: Cardinal; out Value: TPS2Reg128);
begin
  Value := Default(TPS2Reg128);
  if (Address and $F0) <> 0 then
    Exit;
  if GiveOutput(@Value, 1) > 0 then
    Pump;
end;

procedure TPS2IPU.SerializeState(State: TStateArchive);
begin
  State.Field(S, SizeOf(S));
  if not State.Loading and (FOutHead > 0) then
  begin
    if FOutSize > 0 then
      Move(FOut[FOutHead], FOut[0], FOutSize);
    FOutHead := 0;
  end;
  State.Field(FOutSize, SizeOf(FOutSize));
  if State.Loading then
  begin
    if (FOutSize < 0) or (FOutSize > $1000000) then
      raise EPS2Error.Create('PS2 snapshot IPU output');
    FOutHead := 0;
    if Length(FOut) < FOutSize then
      SetLength(FOut, FOutSize);
    FPumping := False;
    FAgain := False;
  end;
  if FOutSize > 0 then
    State.Field(FOut[0], FOutSize);
end;

{ TPS2IPUPort }

constructor TPS2IPUPort.Create(IPU: TPS2IPU);
begin
  inherited Create;
  FIPU := IPU;
end;

function TPS2IPUPort.Push(Channel: Integer; Data: PByte; Count: Integer): Integer;
begin
  Result := FIPU.TakeInput(Data, Count);
end;

function TPS2IPUPort.Pull(Channel: Integer; Data: PByte; Count: Integer): Integer;
begin
  Result := FIPU.GiveOutput(Data, Count);
end;

end.

