unit PS2.IPU;

// Image processing unit: the MPEG macroblock decoder behind DMA channels 4
// (toIPU, the bit stream) and 3 (fromIPU, decoded data). Commands BCLR,
// IDEC, BDEC, VDEC, FDEC, SETIQ, SETVQ, CSC, PACK and SETTH run as resumable
// state machines on the input FIFO (8 quadwords) as data arrives; results
// queue in the output FIFO until DMA or the CPU takes them. A finished
// command raises the IPU interrupt.
// Ported from Play! (Source/ee/IPU.cpp, BSD-2-Clause, Copyright (c)
// Jean-Philip Desjardins) with the MPEG-2 tables of Play! Framework; the IDCT
// is the IEEE 1180 reference transform both use.
// References: EE User's Manual (IPU chapter), ISO/IEC 13818-2.
{$IFDEF PS2_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$POINTERMATH ON}

interface

uses
  System.SysUtils, System.Classes, System.Math, Core.Snapshots, PS2.Types, PS2.Scheduler, PS2.EE.Bus, PS2.DMAC;

type
  // A code table indexed by the next Bits bits of the stream: entries hold
  // (code length shl 24) or value, 0 where no code matches.
  TPS2IPUVLC = record
    Bits: Integer;
    Entries: TArray<Cardinal>;
  end;

  TPS2IPUState = record
    CTRL, Data, Command: Cardinal;
    LastCommand: Integer;
    Busy: Boolean;
    // A delayed command (IDEC) starts here.
    StartAt: Int64;
    TH0, TH1: Cardinal;
    IntraIQ, NonIntraIQ: array[0..63] of Byte;
    VQCLUT: array[0..15] of Word;
    DCPredictor: array[0..2] of Integer;
    // Input FIFO: InSize bytes; the stream is at bit InBit of the first
    // quadword. Bytes past 128 are slack for reads.
    InBuf: array[0..159] of Byte;
    InSize, InBit: Integer;
    // Command progress.
    Phase, Index, MBCount: Integer;
    // Macroblock decoding (BDEC, and IDEC through it).
    BCommand: Cardinal;
    BPhase, CBP, Block, DCTPhase, DCTIndex, DCSize: Integer;
    Blocks: array[0..5, 0..63] of SmallInt;
    // IDEC macroblock fields.
    MBType, QSC, DT: Cardinal;
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
    FMBAI, FMBTypeI, FMBTypeP, FMBTypeB, FMotionCode, FDMVector, FDCSizeLum, FDCSizeChrom, FCBP, FDCT0,
      FDCT1: TPS2IPUVLC;
    function Avail: Integer; inline;
    function Peek(N: Integer): Cardinal; inline;
    procedure Advance(N: Integer);
    procedure AlignByte;
    function PeekTop: Cardinal;
    function PeekVLC(const T: TPS2IPUVLC; out Value: Cardinal; out Len: Integer): Integer;
    function TryVLC(const T: TPS2IPUVLC; out Value: Cardinal): Integer;
    function TryRunLevel(Table1: Boolean; out Run, Level: Integer): Integer;
    function TryFirstCoefficient(out Run, Level: Integer): Integer;
    procedure OutWrite(Data: Pointer; Size: Integer);
    procedure RequestPump;
    procedure Pump;
    procedure Kick;
    procedure StartCommand(Value: Cardinal);
    procedure Execute;
    procedure Finish(Flags: Cardinal; Interrupt: Boolean);
    function StepBDEC(IDEC: Boolean): Integer;
    function StepCoefficients(Intra: Boolean): Integer;
    function StepIDEC: Integer;
    function StepVDEC: Integer;
    function StepFDEC: Integer;
    function StepSETIQ: Integer;
    function StepSETVQ: Integer;
    function StepCSC: Integer;
    function StepPACK: Integer;
    procedure Dequantise(B: PSmallInt; Intra: Boolean; QSC: Integer);
    procedure MacroblockRaw16(Dest: PSmallInt; FieldDCT: Boolean);
    procedure ColorConvert(Raw: PByte; RGB16: Boolean);
    procedure FIFOState(out BP, IFC, FP: Cardinal);
  public
    S: TPS2IPUState;
    // Diagnostics: commands started, macroblocks decoded, bytes output.
    Commands, Macroblocks, OutBytes: Int64;
    CommandCounts: array[0..15] of Int64;
    // Diagnostics: commands other than VDEC/FDEC/BDEC when assigned.
    Trace: TStrings;
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
    // Scheduler event: a delayed command starts, DMA data moves.
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

const
  StepWait = 0;
  StepDone = 1;
  StepStart = 2;
  StepError = 3;

  CtrlECD = $00004000;
  CtrlSCD = $00008000;
  CtrlAS = $00100000;
  CtrlIVF = $00200000;
  CtrlQST = $00400000;
  CtrlMP1 = $00800000;
  CtrlRST = $40000000;

  // EE cycles before IDEC starts (games restart DMA after issuing it).
  IDECDelay = 1000;
  InCapacity = 128;
  RunEscape = 102;

  DefaultIntraIQ: array[0..63] of Byte = (
    8, 16, 19, 22, 26, 27, 29, 34, 16, 16, 22, 24, 27, 29, 34, 37,
    19, 22, 26, 27, 29, 34, 34, 38, 22, 22, 26, 27, 29, 34, 37, 40,
    22, 26, 27, 29, 32, 35, 40, 48, 26, 27, 29, 32, 35, 40, 48, 58,
    26, 27, 29, 34, 38, 46, 56, 69, 27, 29, 35, 38, 46, 56, 69, 83);
  DefaultNonIntraIQ: array[0..63] of Byte = (
    16, 17, 18, 19, 20, 21, 22, 23, 17, 18, 19, 20, 21, 22, 23, 24,
    18, 19, 20, 21, 22, 23, 24, 25, 19, 20, 21, 22, 23, 24, 26, 27,
    20, 21, 22, 23, 25, 26, 27, 28, 21, 22, 23, 24, 26, 27, 28, 30,
    22, 23, 24, 26, 27, 28, 30, 31, 23, 24, 25, 27, 28, 30, 31, 33);
  NonLinearQScale: array[0..31] of Byte = (
    0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 12, 14, 16, 18, 20, 22,
    24, 28, 32, 36, 40, 44, 48, 52, 56, 64, 72, 80, 88, 96, 104, 112);
  // Raster position -> scan position.
  ZigZagScan: array[0..63] of Byte = (
    0, 1, 5, 6, 14, 15, 27, 28, 2, 4, 7, 13, 16, 26, 29, 42,
    3, 8, 12, 17, 25, 30, 41, 43, 9, 11, 18, 24, 31, 40, 44, 53,
    10, 19, 23, 32, 39, 45, 52, 54, 20, 22, 33, 38, 46, 51, 55, 60,
    21, 34, 37, 47, 50, 56, 59, 61, 35, 36, 48, 49, 57, 58, 62, 63);
  AlternateScan: array[0..63] of Byte = (
    0, 4, 6, 20, 22, 36, 38, 52, 1, 5, 7, 21, 23, 37, 39, 53,
    2, 8, 19, 24, 34, 40, 50, 54, 3, 9, 18, 25, 35, 41, 51, 55,
    10, 17, 26, 30, 42, 46, 56, 60, 11, 16, 27, 31, 43, 47, 57, 61,
    12, 15, 28, 32, 44, 48, 58, 62, 13, 14, 29, 33, 45, 49, 59, 63);

  // Code tables (code, length, value) and run/level pairs, from Play!.
  MBAITable: array[0..34, 0..2] of Cardinal = (
    ($0001, 1, $00010001), ($0003, 3, $00030002), ($0002, 3, $00030003), ($0003, 4, $00040004),
    ($0002, 4, $00040005), ($0003, 5, $00050006), ($0002, 5, $00050007), ($0007, 7, $00070008),
    ($0006, 7, $00070009), ($000B, 8, $0008000A), ($000A, 8, $0008000B), ($0009, 8, $0008000C),
    ($0008, 8, $0008000D), ($0007, 8, $0008000E), ($0006, 8, $0008000F), ($0017, 10, $000A0010),
    ($0016, 10, $000A0011), ($0015, 10, $000A0012), ($0014, 10, $000A0013), ($0013, 10, $000A0014),
    ($0012, 10, $000A0015), ($0023, 11, $000B0016), ($0022, 11, $000B0017), ($0021, 11, $000B0018),
    ($0020, 11, $000B0019), ($001F, 11, $000B001A), ($001E, 11, $000B001B), ($001D, 11, $000B001C),
    ($001C, 11, $000B001D), ($001B, 11, $000B001E), ($001A, 11, $000B001F), ($0019, 11, $000B0020),
    ($0018, 11, $000B0021), ($000F, 11, $000B0022), ($0008, 11, $000B0023));
  MBTypeITable: array[0..1, 0..2] of Cardinal = (
    ($0001, 1, $00010001), ($0001, 2, $00020011));
  MBTypePTable: array[0..6, 0..2] of Cardinal = (
    ($0001, 1, $0001000A), ($0001, 2, $00020002), ($0001, 3, $00030008), ($0003, 5, $00050001),
    ($0002, 5, $0005001A), ($0001, 5, $00050012), ($0001, 6, $00060011));
  MBTypeBTable: array[0..10, 0..2] of Cardinal = (
    ($0002, 2, $0002000C), ($0003, 2, $0002000E), ($0002, 3, $00030004), ($0003, 3, $00030006),
    ($0002, 4, $00040008), ($0003, 4, $0004000A), ($0003, 5, $00050001), ($0002, 5, $0005001E),
    ($0003, 6, $0006001A), ($0002, 6, $00060016), ($0001, 6, $00060011));
  MotionCodeTable: array[0..32, 0..2] of Cardinal = (
    ($0001, 1, $00010000), ($0002, 3, $00030001), ($0003, 3, $0003FFFF), ($0002, 4, $00040002),
    ($0003, 4, $0004FFFE), ($0002, 5, $00050003), ($0003, 5, $0005FFFD), ($0006, 7, $00070004),
    ($0007, 7, $0007FFFC), ($000A, 8, $00080005), ($000B, 8, $0008FFFB), ($0008, 8, $00080006),
    ($0009, 8, $0008FFFA), ($0006, 8, $00080007), ($0007, 8, $0008FFF9), ($0016, 10, $000A0008),
    ($0017, 10, $000AFFF8), ($0014, 10, $000A0009), ($0015, 10, $000AFFF7), ($0012, 10, $000A000A),
    ($0013, 10, $000AFFF6), ($0022, 11, $000B000B), ($0023, 11, $000BFFF5), ($0020, 11, $000B000C),
    ($0021, 11, $000BFFF4), ($001E, 11, $000B000D), ($001F, 11, $000BFFF3), ($001C, 11, $000B000E),
    ($001D, 11, $000BFFF2), ($001A, 11, $000B000F), ($001B, 11, $000BFFF1), ($0018, 11, $000B0010),
    ($0019, 11, $000BFFF0));
  DMVectorTable: array[0..2, 0..2] of Cardinal = (
    ($0000, 1, $00010000), ($0002, 2, $00020001), ($0003, 2, $0002FFFF));
  DCSizeLumTable: array[0..11, 0..2] of Cardinal = (
    ($0000, 2, $00000001), ($0001, 2, $00000002), ($0004, 3, $00000000), ($0005, 3, $00000003),
    ($0006, 3, $00000004), ($000E, 4, $00000005), ($001E, 5, $00000006), ($003E, 6, $00000007),
    ($007E, 7, $00000008), ($00FE, 8, $00000009), ($01FE, 9, $0000000A), ($01FF, 9, $0000000B));
  DCSizeChromTable: array[0..11, 0..2] of Cardinal = (
    ($0000, 2, $00000000), ($0001, 2, $00000001), ($0002, 2, $00000002), ($0006, 3, $00000003),
    ($000E, 4, $00000004), ($001E, 5, $00000005), ($003E, 6, $00000006), ($007E, 7, $00000007),
    ($00FE, 8, $00000008), ($01FE, 9, $00000009), ($03FE, 10, $0000000A), ($03FF, 10, $0000000B));
  CBPTable: array[0..63, 0..2] of Cardinal = (
    ($0007, 3, $0000003C), ($000D, 4, $00000004), ($000C, 4, $00000008), ($000B, 4, $00000010),
    ($000A, 4, $00000020), ($0013, 5, $0000000C), ($0012, 5, $00000030), ($0011, 5, $00000014),
    ($0010, 5, $00000028), ($000F, 5, $0000001C), ($000E, 5, $0000002C), ($000D, 5, $00000034),
    ($000C, 5, $00000038), ($000B, 5, $00000001), ($000A, 5, $0000003D), ($0009, 5, $00000002),
    ($0008, 5, $0000003E), ($000F, 6, $00000018), ($000E, 6, $00000024), ($000D, 6, $00000003),
    ($000C, 6, $0000003F), ($0017, 7, $00000005), ($0016, 7, $00000009), ($0015, 7, $00000011),
    ($0014, 7, $00000021), ($0013, 7, $00000006), ($0012, 7, $0000000A), ($0011, 7, $00000012),
    ($0010, 7, $00000022), ($001F, 8, $00000007), ($001E, 8, $0000000B), ($001D, 8, $00000013),
    ($001C, 8, $00000023), ($001B, 8, $0000000D), ($001A, 8, $00000031), ($0019, 8, $00000015),
    ($0018, 8, $00000029), ($0017, 8, $0000000E), ($0016, 8, $00000032), ($0015, 8, $00000016),
    ($0014, 8, $0000002A), ($0013, 8, $0000000F), ($0012, 8, $00000033), ($0011, 8, $00000017),
    ($0010, 8, $0000002B), ($000F, 8, $00000019), ($000E, 8, $00000025), ($000D, 8, $0000001A),
    ($000C, 8, $00000026), ($000B, 8, $0000001D), ($000A, 8, $0000002D), ($0009, 8, $00000035),
    ($0008, 8, $00000039), ($0007, 8, $0000001E), ($0006, 8, $0000002E), ($0005, 8, $00000036),
    ($0004, 8, $0000003A), ($0007, 9, $0000001F), ($0006, 9, $0000002F), ($0005, 9, $00000037),
    ($0004, 9, $0000003B), ($0003, 9, $0000001B), ($0002, 9, $00000027), ($0001, 9, $00000000));
  DCT0Table: array[0..111, 0..2] of Cardinal = (
    ($0003, 2, $00000000), ($0003, 3, $00000001), ($0004, 4, $00000002), ($0005, 4, $00000003),
    ($0005, 5, $00000004), ($0007, 5, $00000005), ($0006, 5, $00000006), ($0006, 6, $00000007),
    ($0007, 6, $00000008), ($0005, 6, $00000009), ($0004, 6, $0000000A), ($0001, 6, $0000000F),
    ($0006, 7, $0000000B), ($0004, 7, $0000000C), ($0007, 7, $0000000D), ($0005, 7, $0000000E),
    ($0026, 8, $00000010), ($0021, 8, $00000011), ($0025, 8, $00000012), ($0024, 8, $00000013),
    ($0027, 8, $00000014), ($0023, 8, $00000015), ($0022, 8, $00000016), ($0020, 8, $00000017),
    ($000A, 10, $00000018), ($000C, 10, $00000019), ($000B, 10, $0000001A), ($000F, 10, $0000001B),
    ($0009, 10, $0000001C), ($000E, 10, $0000001D), ($000D, 10, $0000001E), ($0008, 10, $0000001F),
    ($001D, 12, $00000020), ($0018, 12, $00000021), ($0013, 12, $00000022), ($0010, 12, $00000023),
    ($001B, 12, $00000024), ($0014, 12, $00000025), ($001C, 12, $00000026), ($0012, 12, $00000027),
    ($001E, 12, $00000028), ($0015, 12, $00000029), ($0011, 12, $0000002A), ($001F, 12, $0000002B),
    ($001A, 12, $0000002C), ($0019, 12, $0000002D), ($0017, 12, $0000002E), ($0016, 12, $0000002F),
    ($001A, 13, $00000030), ($0019, 13, $00000031), ($0018, 13, $00000032), ($0017, 13, $00000033),
    ($0016, 13, $00000034), ($0015, 13, $00000035), ($0014, 13, $00000036), ($0013, 13, $00000037),
    ($0012, 13, $00000038), ($0011, 13, $00000039), ($0010, 13, $0000003A), ($001F, 13, $0000003B),
    ($001E, 13, $0000003C), ($001D, 13, $0000003D), ($001C, 13, $0000003E), ($001B, 13, $0000003F),
    ($001F, 14, $00000040), ($001E, 14, $00000041), ($001D, 14, $00000042), ($001C, 14, $00000043),
    ($001B, 14, $00000044), ($001A, 14, $00000045), ($0019, 14, $00000046), ($0018, 14, $00000047),
    ($0017, 14, $00000048), ($0016, 14, $00000049), ($0015, 14, $0000004A), ($0014, 14, $0000004B),
    ($0013, 14, $0000004C), ($0012, 14, $0000004D), ($0011, 14, $0000004E), ($0010, 14, $0000004F),
    ($0018, 15, $00000050), ($0017, 15, $00000051), ($0016, 15, $00000052), ($0015, 15, $00000053),
    ($0014, 15, $00000054), ($0013, 15, $00000055), ($0012, 15, $00000056), ($0011, 15, $00000057),
    ($0010, 15, $00000058), ($001F, 15, $00000059), ($001E, 15, $0000005A), ($001D, 15, $0000005B),
    ($001C, 15, $0000005C), ($001B, 15, $0000005D), ($001A, 15, $0000005E), ($0019, 15, $0000005F),
    ($0013, 16, $00000060), ($0012, 16, $00000061), ($0011, 16, $00000062), ($0010, 16, $00000063),
    ($0014, 16, $00000064), ($001A, 16, $00000065), ($0019, 16, $00000066), ($0018, 16, $00000067),
    ($0017, 16, $00000068), ($0016, 16, $00000069), ($0015, 16, $0000006A), ($001F, 16, $0000006B),
    ($001E, 16, $0000006C), ($001D, 16, $0000006D), ($001C, 16, $0000006E), ($001B, 16, $0000006F));
  DCT1Table: array[0..111, 0..2] of Cardinal = (
    ($0002, 2, $00000000), ($0002, 3, $00000001), ($0006, 3, $00000002), ($0007, 4, $00000004),
    ($0005, 5, $00000003), ($0007, 5, $00000005), ($0006, 5, $00000007), ($001C, 5, $0000000B),
    ($001D, 5, $00000010), ($0006, 6, $00000006), ($0007, 6, $00000008), ($0005, 6, $00000011),
    ($0004, 6, $00000018), ($0001, 6, $0000000F), ($0079, 7, $00000012), ($007A, 7, $00000014),
    ($0007, 7, $0000000C), ($0005, 7, $0000000D), ($0078, 7, $0000000E), ($0006, 7, $00000009),
    ($0004, 7, $0000000A), ($007B, 7, $00000020), ($007C, 7, $00000021), ($0026, 8, $00000013),
    ($0021, 8, $00000015), ($0025, 8, $00000016), ($0024, 8, $00000017), ($0027, 8, $00000019),
    ($00FC, 8, $0000001A), ($00FD, 8, $0000001B), ($00FA, 8, $00000030), ($00FB, 8, $00000031),
    ($00FE, 8, $00000032), ($00FF, 8, $00000033), ($0023, 8, $00000022), ($0022, 8, $00000023),
    ($0020, 8, $00000024), ($0004, 9, $0000001C), ($0005, 9, $0000001D), ($0007, 9, $0000001E),
    ($000D, 10, $0000001F), ($000C, 10, $00000025), ($001C, 12, $00000026), ($0012, 12, $00000027),
    ($001E, 12, $00000028), ($0015, 12, $00000029), ($0011, 12, $0000002A), ($001F, 12, $0000002B),
    ($001A, 12, $0000002C), ($0019, 12, $0000002D), ($0017, 12, $0000002E), ($0016, 12, $0000002F),
    ($0016, 13, $00000034), ($0015, 13, $00000035), ($0014, 13, $00000036), ($0013, 13, $00000037),
    ($0012, 13, $00000038), ($0011, 13, $00000039), ($0010, 13, $0000003A), ($001F, 13, $0000003B),
    ($001E, 13, $0000003C), ($001D, 13, $0000003D), ($001C, 13, $0000003E), ($001B, 13, $0000003F),
    ($001F, 14, $00000040), ($001E, 14, $00000041), ($001D, 14, $00000042), ($001C, 14, $00000043),
    ($001B, 14, $00000044), ($001A, 14, $00000045), ($0019, 14, $00000046), ($0018, 14, $00000047),
    ($0017, 14, $00000048), ($0016, 14, $00000049), ($0015, 14, $0000004A), ($0014, 14, $0000004B),
    ($0013, 14, $0000004C), ($0012, 14, $0000004D), ($0011, 14, $0000004E), ($0010, 14, $0000004F),
    ($0018, 15, $00000050), ($0017, 15, $00000051), ($0016, 15, $00000052), ($0015, 15, $00000053),
    ($0014, 15, $00000054), ($0013, 15, $00000055), ($0012, 15, $00000056), ($0011, 15, $00000057),
    ($0010, 15, $00000058), ($001F, 15, $00000059), ($001E, 15, $0000005A), ($001D, 15, $0000005B),
    ($001C, 15, $0000005C), ($001B, 15, $0000005D), ($001A, 15, $0000005E), ($0019, 15, $0000005F),
    ($0013, 16, $00000060), ($0012, 16, $00000061), ($0011, 16, $00000062), ($0010, 16, $00000063),
    ($0014, 16, $00000064), ($001A, 16, $00000065), ($0019, 16, $00000066), ($0018, 16, $00000067),
    ($0017, 16, $00000068), ($0016, 16, $00000069), ($0015, 16, $0000006A), ($001F, 16, $0000006B),
    ($001E, 16, $0000006C), ($001D, 16, $0000006D), ($001C, 16, $0000006E), ($001B, 16, $0000006F));
  DCT0RunLevel: array[0..111, 0..1] of Byte = (
    (0, 1), (1, 1), (0, 2), (2, 1), (0, 3), (3, 1), (4, 1), (1, 2),
    (5, 1), (6, 1), (7, 1), (0, 4), (2, 2), (8, 1), (9, 1), (102, 0),
    (0, 5), (0, 6), (1, 3), (3, 2), (10, 1), (11, 1), (12, 1), (13, 1),
    (0, 7), (1, 4), (2, 3), (4, 2), (5, 2), (14, 1), (15, 1), (16, 1),
    (0, 8), (0, 9), (0, 10), (0, 11), (1, 5), (2, 4), (3, 3), (4, 3),
    (6, 2), (7, 2), (8, 2), (17, 1), (18, 1), (19, 1), (20, 1), (21, 1),
    (0, 12), (0, 13), (0, 14), (0, 15), (1, 6), (1, 7), (2, 5), (3, 4),
    (5, 3), (9, 2), (10, 2), (22, 1), (23, 1), (24, 1), (25, 1), (26, 1),
    (0, 16), (0, 17), (0, 18), (0, 19), (0, 20), (0, 21), (0, 22), (0, 23),
    (0, 24), (0, 25), (0, 26), (0, 27), (0, 28), (0, 29), (0, 30), (0, 31),
    (0, 32), (0, 33), (0, 34), (0, 35), (0, 36), (0, 37), (0, 38), (0, 39),
    (0, 40), (1, 8), (1, 9), (1, 10), (1, 11), (1, 12), (1, 13), (1, 14),
    (1, 15), (1, 16), (1, 17), (1, 18), (6, 3), (11, 2), (12, 2), (13, 2),
    (14, 2), (15, 2), (16, 2), (27, 1), (28, 1), (29, 1), (30, 1), (31, 1));
  DCT1RunLevel: array[0..111, 0..1] of Byte = (
    (0, 1), (1, 1), (0, 2), (2, 1), (0, 3), (3, 1), (4, 1), (1, 2),
    (5, 1), (6, 1), (7, 1), (0, 4), (2, 2), (8, 1), (9, 1), (102, 0),
    (0, 5), (0, 6), (1, 3), (3, 2), (10, 1), (11, 1), (12, 1), (13, 1),
    (0, 7), (1, 4), (2, 3), (4, 2), (5, 2), (14, 1), (15, 1), (16, 1),
    (0, 8), (0, 9), (0, 10), (0, 11), (1, 5), (2, 4), (3, 3), (4, 3),
    (6, 2), (7, 2), (8, 2), (17, 1), (18, 1), (19, 1), (20, 1), (21, 1),
    (0, 12), (0, 13), (0, 14), (0, 15), (1, 6), (1, 7), (2, 5), (3, 4),
    (5, 3), (9, 2), (10, 2), (22, 1), (23, 1), (24, 1), (25, 1), (26, 1),
    (0, 16), (0, 17), (0, 18), (0, 19), (0, 20), (0, 21), (0, 22), (0, 23),
    (0, 24), (0, 25), (0, 26), (0, 27), (0, 28), (0, 29), (0, 30), (0, 31),
    (0, 32), (0, 33), (0, 34), (0, 35), (0, 36), (0, 37), (0, 38), (0, 39),
    (0, 40), (1, 8), (1, 9), (1, 10), (1, 11), (1, 12), (1, 13), (1, 14),
    (1, 15), (1, 16), (1, 17), (1, 18), (6, 3), (11, 2), (12, 2), (13, 2),
    (14, 2), (15, 2), (16, 2), (27, 1), (28, 1), (29, 1), (30, 1), (31, 1));

var
  // IEEE 1180 reference IDCT basis: C[frequency, time].
  IDCTBasis: array[0..7, 0..7] of Double;

procedure InitIDCT;
begin
  for var F := 0 to 7 do
  begin
    var Scale: Double := 0.5;
    if F = 0 then
      Scale := Sqrt(0.125);
    for var T := 0 to 7 do
      IDCTBasis[F, T] := Scale * Cos((Pi / 8.0) * F * (T + 0.5));
  end;
end;

// Rows, then columns, rounding to nearest; all-zero rows are skipped (their
// terms add nothing).
procedure IDCT(B: PSmallInt);
var
  Tmp: array[0..63] of Double;
  Used: array[0..7] of Boolean;
begin
  for var I := 0 to 7 do
  begin
    var Row := B + I * 8;
    var Any := False;
    for var K := 0 to 7 do
      if Row[K] <> 0 then
        Any := True;
    Used[I] := Any;
    if not Any then
      Continue;
    for var J := 0 to 7 do
    begin
      var P: Double := 0.0;
      for var K := 0 to 7 do
        if Row[K] <> 0 then
          P := P + IDCTBasis[K, J] * Row[K];
      Tmp[I * 8 + J] := P;
    end;
  end;
  for var J := 0 to 7 do
    for var I := 0 to 7 do
    begin
      var P: Double := 0.0;
      for var K := 0 to 7 do
        if Used[K] then
          P := P + IDCTBasis[K, I] * Tmp[K * 8 + J];
      var V := Floor(P + 0.5);
      if V > 32767 then
        V := 32767
      else if V < -32768 then
        V := -32768;
      B[I * 8 + J] := SmallInt(V);
    end;
end;

procedure InverseScan(B: PSmallInt; Alternate: Boolean);
var
  T: array[0..63] of SmallInt;
begin
  Move(B^, T, SizeOf(T));
  if Alternate then
    for var I := 0 to 63 do
      B[I] := T[AlternateScan[I]]
  else
    for var I := 0 to 63 do
      B[I] := T[ZigZagScan[I]];
end;

procedure BuildVLC(var T: TPS2IPUVLC; Codes: PCardinal; Count: Integer);
begin
  T.Bits := 0;
  for var I := 0 to Count - 1 do
    T.Bits := Max(T.Bits, Integer(Codes[I * 3 + 1]));
  SetLength(T.Entries, 1 shl T.Bits);
  FillChar(T.Entries[0], Length(T.Entries) * SizeOf(Cardinal), 0);
  for var I := 0 to Count - 1 do
  begin
    var Code := Codes[I * 3];
    var Len := Integer(Codes[I * 3 + 1]);
    var Shift := T.Bits - Len;
    var Entry := (Cardinal(Len) shl 24) or (Codes[I * 3 + 2] and $FFFFFF);
    for var K := Integer(Code shl Shift) to Integer(((Code + 1) shl Shift) - 1) do
      T.Entries[K] := Entry;
  end;
end;

{ TPS2IPU }

constructor TPS2IPU.Create(Scheduler: TPS2Scheduler; DMAC: TPS2DMAC);
begin
  inherited Create;
  FScheduler := Scheduler;
  FDMAC := DMAC;
  if IDCTBasis[0, 0] = 0 then
    InitIDCT;
  BuildVLC(FMBAI, @MBAITable[0, 0], Length(MBAITable));
  BuildVLC(FMBTypeI, @MBTypeITable[0, 0], Length(MBTypeITable));
  BuildVLC(FMBTypeP, @MBTypePTable[0, 0], Length(MBTypePTable));
  BuildVLC(FMBTypeB, @MBTypeBTable[0, 0], Length(MBTypeBTable));
  BuildVLC(FMotionCode, @MotionCodeTable[0, 0], Length(MotionCodeTable));
  BuildVLC(FDMVector, @DMVectorTable[0, 0], Length(DMVectorTable));
  BuildVLC(FDCSizeLum, @DCSizeLumTable[0, 0], Length(DCSizeLumTable));
  BuildVLC(FDCSizeChrom, @DCSizeChromTable[0, 0], Length(DCSizeChromTable));
  BuildVLC(FCBP, @CBPTable[0, 0], Length(CBPTable));
  BuildVLC(FDCT0, @DCT0Table[0, 0], Length(DCT0Table));
  BuildVLC(FDCT1, @DCT1Table[0, 0], Length(DCT1Table));
  Reset;
end;

procedure TPS2IPU.Reset;
begin
  S := Default(TPS2IPUState);
  S.LastCommand := -1;
  Move(DefaultIntraIQ, S.IntraIQ, 64);
  Move(DefaultNonIntraIQ, S.NonIntraIQ, 64);
  FOutHead := 0;
  FOutSize := 0;
  FPumping := False;
  FAgain := False;
  FScheduler.Cancel(TPS2Event.IPU);
end;

{ Input bit stream }

function TPS2IPU.Avail: Integer;
begin
  Result := S.InSize * 8 - S.InBit;
  if Result < 0 then
    Result := 0;
end;

// The next N (1..32) bits, most significant first; N <= Avail.
function TPS2IPU.Peek(N: Integer): Cardinal;
begin
  var P := PByte(@S.InBuf[S.InBit shr 3]);
  var V := (UInt64(P[0]) shl 32) or (UInt64(P[1]) shl 24) or (UInt64(P[2]) shl 16) or (UInt64(P[3]) shl 8) or P[4];
  Result := Cardinal((V shr (40 - (S.InBit and 7) - N)) and ((UInt64(1) shl N) - 1));
end;

// N <= Avail; consumed quadwords leave the FIFO.
procedure TPS2IPU.Advance(N: Integer);
begin
  Inc(S.InBit, N);
  while (S.InBit >= 128) and (S.InSize >= 16) do
  begin
    Move(S.InBuf[16], S.InBuf[0], S.InSize - 16);
    Dec(S.InSize, 16);
    Dec(S.InBit, 128);
  end;
end;

procedure TPS2IPU.AlignByte;
begin
  if (S.InBit and 7) <> 0 then
    Advance(Min(8 - (S.InBit and 7), Avail));
end;

// BSTOP: the next 32 bits (zero filled when fewer are there).
function TPS2IPU.PeekTop: Cardinal;
begin
  var N := Min(32, Avail);
  if N = 0 then
    Exit(0);
  Result := Peek(N) shl (32 - N);
end;

function TPS2IPU.PeekVLC(const T: TPS2IPUVLC; out Value: Cardinal; out Len: Integer): Integer;
begin
  Value := 0;
  Len := 0;
  var A := Avail;
  if A = 0 then
    Exit(StepWait);
  var Bits: Cardinal;
  if A >= T.Bits then
    Bits := Peek(T.Bits)
  else
    Bits := Peek(A) shl (T.Bits - A);
  var E := T.Entries[Bits];
  if E = 0 then
  begin
    if A >= T.Bits then
      Exit(StepError);
    Exit(StepWait);
  end;
  Len := Integer(E shr 24);
  if Len > A then
    Exit(StepWait);
  Value := E and $FFFFFF;
  Result := StepDone;
end;

function TPS2IPU.TryVLC(const T: TPS2IPUVLC; out Value: Cardinal): Integer;
begin
  var Len: Integer;
  Result := PeekVLC(T, Value, Len);
  if Result = StepDone then
    Advance(Len);
end;

{ Macroblock decoding }

// A run/level pair of table B-14 (Table1 False) or B-15 with its sign or
// escape (MPEG-1: 8/16-bit level, MPEG-2: 12-bit level).
function TPS2IPU.TryRunLevel(Table1: Boolean; out Run, Level: Integer): Integer;
begin
  Run := 0;
  Level := 0;
  var Index: Cardinal;
  var Len: Integer;
  if Table1 then
    Result := PeekVLC(FDCT1, Index, Len)
  else
    Result := PeekVLC(FDCT0, Index, Len);
  if Result <> StepDone then
    Exit;
  var R, L: Integer;
  if Table1 then
  begin
    R := DCT1RunLevel[Index, 0];
    L := DCT1RunLevel[Index, 1];
  end
  else
  begin
    R := DCT0RunLevel[Index, 0];
    L := DCT0RunLevel[Index, 1];
  end;
  if R = RunEscape then
  begin
    if (S.CTRL and CtrlMP1) <> 0 then
    begin
      if Avail < Len + 14 then
        Exit(StepWait);
      var X := Peek(Len + 14);
      Run := Integer((X shr 8) and $3F);
      var V := Integer(X and $FF);
      var Total := Len + 14;
      if (V = 0) or (V = 128) then
      begin
        if Avail < Len + 22 then
          Exit(StepWait);
        var X2 := Integer(Peek(Len + 22) and $FF);
        if V = 0 then
          Level := X2
        else
          Level := X2 - 256;
        Total := Len + 22;
      end
      else if V > 128 then
        Level := V - 256
      else
        Level := V;
      Advance(Total);
    end
    else
    begin
      if Avail < Len + 18 then
        Exit(StepWait);
      var X := Peek(Len + 18);
      Run := Integer((X shr 12) and $3F);
      Level := Integer(X and $FFF);
      if (Level and $800) <> 0 then
        Level := Level - $1000;
      Advance(Len + 18);
    end;
  end
  else
  begin
    if Avail < Len + 1 then
      Exit(StepWait);
    Run := R;
    Level := L;
    if (Peek(Len + 1) and 1) <> 0 then
      Level := -L;
    Advance(Len + 1);
  end;
  Result := StepDone;
end;

// The first coefficient of a non-intra block: '1s' is run 0, level 1.
function TPS2IPU.TryFirstCoefficient(out Run, Level: Integer): Integer;
begin
  Run := 0;
  Level := 0;
  if Avail < 1 then
    Exit(StepWait);
  if Peek(1) = 0 then
    Exit(TryRunLevel(False, Run, Level));
  if Avail < 2 then
    Exit(StepWait);
  if (Peek(2) and 1) <> 0 then
    Level := -1
  else
    Level := 1;
  Advance(2);
  Result := StepDone;
end;

// The coefficients of block S.Block in scan order: DC (intra), run/level
// pairs, end of block.
function TPS2IPU.StepCoefficients(Intra: Boolean): Integer;
begin
  var Table1 := Intra and ((S.CTRL and CtrlIVF) <> 0);
  var B := PSmallInt(@S.Blocks[S.Block, 0]);
  while True do
    case S.DCTPhase of
      0:
        if Intra then
          S.DCTPhase := 1
        else
          S.DCTPhase := 3;
      1:
        begin
          var V: Cardinal;
          if S.Block < 4 then
            Result := TryVLC(FDCSizeLum, V)
          else
            Result := TryVLC(FDCSizeChrom, V);
          if Result <> StepDone then
            Exit;
          S.DCSize := Integer(V);
          S.DCTPhase := 2;
        end;
      2:
        begin
          var Diff := 0;
          if S.DCSize > 0 then
          begin
            if Avail < S.DCSize then
              Exit(StepWait);
            Diff := Integer(Peek(S.DCSize));
            Advance(S.DCSize);
            var Half := 1 shl (S.DCSize - 1);
            if Diff < Half then
              Diff := Diff + 1 - 2 * Half;
          end;
          var Ch := 0;
          if S.Block >= 4 then
            Ch := S.Block - 3;
          var DC := SmallInt(S.DCPredictor[Ch] + Diff);
          B[0] := DC;
          S.DCPredictor[Ch] := DC;
          S.DCTIndex := 1;
          S.DCTPhase := 3;
        end;
      3:
        begin
          // End of block: '10' (B-14) or '0110' (B-15), never first.
          var N := 2;
          var Code: Cardinal := 2;
          if Table1 then
          begin
            N := 4;
            Code := 6;
          end;
          if Avail < N then
            Exit(StepWait);
          if (S.DCTIndex <> 0) and (Peek(N) = Code) then
          begin
            Advance(N);
            Exit(StepDone);
          end;
          S.DCTPhase := 4;
        end;
    else
      begin
        var Run, Level: Integer;
        if S.DCTIndex = 0 then
          Result := TryFirstCoefficient(Run, Level)
        else
          Result := TryRunLevel(Table1, Run, Level);
        if Result <> StepDone then
          Exit;
        S.DCTIndex := S.DCTIndex + Run;
        if S.DCTIndex >= 64 then
          Exit(StepError);
        B[S.DCTIndex] := SmallInt(Level);
        Inc(S.DCTIndex);
        S.DCTPhase := 3;
      end;
    end;
end;

// Inverse quantisation in scan order with saturation; MPEG-1 makes values
// odd, MPEG-2 applies mismatch control.
procedure TPS2IPU.Dequantise(B: PSmallInt; Intra: Boolean; QSC: Integer);
begin
  var Scale: Integer;
  if (S.CTRL and CtrlQST) = 0 then
    Scale := QSC * 2
  else
    Scale := NonLinearQScale[QSC and 31];
  var MPEG1 := (S.CTRL and CtrlMP1) <> 0;
  var First := 0;
  if Intra then
  begin
    var DC := Integer(B[0]) * (8 shr ((S.CTRL shr 16) and 3));
    B[0] := SmallInt(EnsureRange(DC, -2048, 2047));
    First := 1;
  end;
  for var I := First to 63 do
  begin
    var V := Integer(B[I]);
    if V = 0 then
      Continue;
    if Intra then
      V := (V * S.IntraIQ[I] * Scale * 2) div 32
    else if V > 0 then
      V := ((2 * V + 1) * S.NonIntraIQ[I] * Scale) div 32
    else
      V := ((2 * V - 1) * S.NonIntraIQ[I] * Scale) div 32;
    if MPEG1 and (V <> 0) and not Odd(V) then
      if V > 0 then
        Dec(V)
      else
        Inc(V);
    B[I] := SmallInt(EnsureRange(V, -2048, 2047));
  end;
  if not MPEG1 then
  begin
    var Sum := 0;
    for var I := 0 to 63 do
      Inc(Sum, B[I]);
    if not Odd(Sum) then
      B[63] := B[63] xor 1;
  end;
end;

// The decoded macroblock as RAW16: Y as 16x16 (frame DCT: Y0 Y1 over
// Y2 Y3; field DCT: Y0 Y1 lines interleaved with Y2 Y3), then Cb, Cr.
procedure TPS2IPU.MacroblockRaw16(Dest: PSmallInt; FieldDCT: Boolean);
begin
  var D := Dest;
  if FieldDCT then
    for var I := 0 to 7 do
      for var K := 0 to 3 do
      begin
        Move(S.Blocks[K, I * 8], D^, 16);
        Inc(D, 8);
      end
  else
    for var Half := 0 to 1 do
      for var I := 0 to 7 do
        for var K := 0 to 1 do
        begin
          Move(S.Blocks[Half * 2 + K, I * 8], D^, 16);
          Inc(D, 8);
        end;
  Move(S.Blocks[4, 0], D^, 128);
  Inc(D, 64);
  Move(S.Blocks[5, 0], D^, 128);
end;

// One macroblock from S.BCommand (BDEC fields: FB, QSC, DT, DCR, MBI). For
// IDEC the blocks stay in S.Blocks.
function TPS2IPU.StepBDEC(IDEC: Boolean): Integer;
begin
  var Cmd := S.BCommand;
  var MBI := (Cmd and $08000000) <> 0;
  while True do
    case S.BPhase of
      0:
        begin
          var FB := Integer(Cmd and $3F);
          if Avail < FB then
            Exit(StepWait);
          Advance(FB);
          S.BPhase := 1;
        end;
      1:
        begin
          if MBI then
            S.CBP := $3F
          else
          begin
            var V: Cardinal;
            Result := TryVLC(FCBP, V);
            if Result <> StepDone then
              Exit;
            S.CBP := Integer(V);
          end;
          S.CTRL := (S.CTRL and not Cardinal($3F00)) or (Cardinal(S.CBP) shl 8);
          S.BPhase := 2;
        end;
      2:
        begin
          if (Cmd and $04000000) <> 0 then
          begin
            var DC := 128 shl ((S.CTRL shr 16) and 3);
            S.DCPredictor[0] := DC;
            S.DCPredictor[1] := DC;
            S.DCPredictor[2] := DC;
          end;
          S.Block := 0;
          S.BPhase := 3;
        end;
      3:
        begin
          FillChar(S.Blocks[S.Block, 0], 128, 0);
          if (S.CBP and (1 shl (5 - S.Block))) <> 0 then
          begin
            S.DCTPhase := 0;
            S.DCTIndex := 0;
            S.BPhase := 4;
          end
          else
            S.BPhase := 5;
        end;
      4:
        begin
          Result := StepCoefficients(MBI);
          if Result <> StepDone then
            Exit;
          var B := PSmallInt(@S.Blocks[S.Block, 0]);
          Dequantise(B, MBI, Integer((Cmd shr 16) and $1F));
          InverseScan(B, (S.CTRL and CtrlAS) <> 0);
          IDCT(B);
          S.BPhase := 5;
        end;
      5:
        begin
          Inc(S.Block);
          if S.Block = 6 then
            S.BPhase := 6
          else
            S.BPhase := 3;
        end;
    else
      begin
        Inc(Macroblocks);
        if not IDEC then
        begin
          var Raw: array[0..383] of SmallInt;
          MacroblockRaw16(@Raw[0], (Cmd and $02000000) <> 0);
          OutWrite(@Raw[0], SizeOf(Raw));
          // Eight zero bits next: a start code follows.
          if (Avail >= 8) and (Peek(8) = 0) then
          begin
            AlignByte;
            Exit(StepStart);
          end;
        end;
        Exit(StepDone);
      end;
    end;
end;

// YCbCr 4:2:0 RAW8 (256 Y, 64 Cb, 64 Cr) to RGBA32 or RGBA16 with the
// TH0/TH1 alpha thresholds.
procedure TPS2IPU.ColorConvert(Raw: PByte; RGB16: Boolean);
var
  Pixels: array[0..255] of Cardinal;
  Half: array[0..255] of Word;
begin
  var TH0 := Integer(S.TH0 and $1FF);
  var TH1 := Integer(S.TH1 and $1FF);
  for var Row := 0 to 15 do
    for var Col := 0 to 15 do
    begin
      var C := (Row shr 1) * 8 + (Col shr 1);
      var Y: Single := Raw[Row * 16 + Col];
      var Cb: Single := Integer(Raw[256 + C]) - 128;
      var Cr: Single := Integer(Raw[320 + C]) - 128;
      var R := Trunc(EnsureRange(Y + 1.402 * Cr, 0.0, 255.0));
      var G := Trunc(EnsureRange(Y - 0.34414 * Cb - 0.71414 * Cr, 0.0, 255.0));
      var B := Trunc(EnsureRange(Y + 1.772 * Cb, 0.0, 255.0));
      var A: Cardinal := $80;
      if (R < TH0) and (G < TH0) and (B < TH0) then
        A := 0
      else if (R < TH1) and (G < TH1) and (B < TH1) then
        A := $40;
      Pixels[Row * 16 + Col] := (A shl 24) or (Cardinal(B) shl 16) or (Cardinal(G) shl 8) or Cardinal(R);
    end;
  if RGB16 then
  begin
    for var I := 0 to 255 do
    begin
      var P := Pixels[I];
      Half[I] := Word(((P and $F8) shr 3) or (((P shr 8) and $F8) shl 2) or (((P shr 16) and $F8) shl 7) or
        ((P shr 31) shl 15));
    end;
    OutWrite(@Half[0], SizeOf(Half));
  end
  else
    OutWrite(@Pixels[0], SizeOf(Pixels));
end;

// IDEC: the macroblocks of an intra slice to RGB until a start code.
function TPS2IPU.StepIDEC: Integer;
begin
  var Cmd := S.Command;
  while True do
    case S.Phase of
      0:
        begin
          var FB := Integer(Cmd and $3F);
          if Avail < FB then
            Exit(StepWait);
          Advance(FB);
          S.Phase := 1;
        end;
      1:
        begin
          var V: Cardinal;
          Result := TryVLC(FMBTypeI, V);
          if Result <> StepDone then
            Exit;
          S.MBType := V;
          S.Phase := 2;
        end;
      2:
        begin
          S.DT := 0;
          if (Cmd and $01000000) <> 0 then
          begin
            if Avail < 1 then
              Exit(StepWait);
            S.DT := Peek(1);
            Advance(1);
          end;
          S.Phase := 3;
        end;
      3:
        begin
          if (S.MBType and $10) <> 0 then
          begin
            if Avail < 5 then
              Exit(StepWait);
            S.QSC := Peek(5);
            Advance(5);
          end;
          // The macroblock through BDEC: intra, DC reset at the slice start.
          S.BCommand := $28000000 or (S.QSC shl 16) or (S.DT shl 25);
          if S.MBCount = 0 then
            S.BCommand := S.BCommand or $04000000;
          S.BPhase := 0;
          S.Phase := 4;
        end;
      4:
        begin
          Result := StepBDEC(True);
          if Result <> StepDone then
            Exit;
          Inc(S.MBCount);
          var Raw16: array[0..383] of SmallInt;
          MacroblockRaw16(@Raw16[0], S.DT <> 0);
          for var I := 0 to 383 do
            S.Raw[I] := Byte(EnsureRange(Integer(Raw16[I]), 0, 255));
          ColorConvert(@S.Raw[0], (Cmd and $08000000) <> 0);
          S.Phase := 5;
        end;
      5:
        begin
          // The next macroblock once this one has left.
          if FOutSize > 0 then
            Exit(StepWait);
          S.Phase := 6;
        end;
      6:
        begin
          if Avail < 8 then
            Exit(StepWait);
          if Peek(8) <> 0 then
            S.Phase := 8
          else
          begin
            AlignByte;
            S.Phase := 7;
          end;
        end;
      7:
        begin
          // Zero bytes up to 00 00 01; a stream ending in zeros counts too.
          if Avail < 24 then
            Exit(StepStart);
          var V := Peek(24);
          if V = 1 then
            Exit(StepStart);
          if V <> 0 then
            Exit(StepError);
          Advance(8);
        end;
    else
      begin
        var V: Cardinal;
        Result := TryVLC(FMBAI, V);
        if Result <> StepDone then
          Exit;
        S.Phase := 1;
      end;
    end;
end;

// VDEC: one symbol (address increment, macroblock type, motion code, dual
// prime vector); DATA gets (code length shl 16) or value.
function TPS2IPU.StepVDEC: Integer;
begin
  if S.Phase = 0 then
  begin
    var FB := Integer(S.Command and $3F);
    if Avail < FB then
      Exit(StepWait);
    Advance(FB);
    S.Phase := 1;
  end;
  var V: Cardinal;
  case (S.Command shr 26) and 3 of
    0: Result := TryVLC(FMBAI, V);
    1:
      case (S.CTRL shr 24) and 7 of
        1: Result := TryVLC(FMBTypeI, V);
        2: Result := TryVLC(FMBTypeP, V);
        3: Result := TryVLC(FMBTypeB, V);
      else
        Exit(StepError);
      end;
    2: Result := TryVLC(FMotionCode, V);
  else
    Result := TryVLC(FDMVector, V);
  end;
  if Result = StepDone then
    S.Data := V;
end;

// FDEC: the next 32 bits after FB, not consumed.
function TPS2IPU.StepFDEC: Integer;
begin
  if S.Phase = 0 then
  begin
    var FB := Integer(S.Command and $3F);
    if Avail < FB then
      Exit(StepWait);
    Advance(FB);
    S.Phase := 1;
  end;
  if Avail < 32 then
    Exit(StepWait);
  S.Data := Peek(32);
  Result := StepDone;
end;

function TPS2IPU.StepSETIQ: Integer;
begin
  if S.Phase = 0 then
  begin
    var FB := Integer(S.Command and $3F);
    if Avail < FB then
      Exit(StepWait);
    Advance(FB);
    S.Phase := 1;
  end;
  while S.Index < 64 do
  begin
    if Avail < 8 then
      Exit(StepWait);
    if (S.Command and $08000000) <> 0 then
      S.NonIntraIQ[S.Index] := Byte(Peek(8))
    else
      S.IntraIQ[S.Index] := Byte(Peek(8));
    Advance(8);
    Inc(S.Index);
  end;
  Result := StepDone;
end;

function TPS2IPU.StepSETVQ: Integer;
begin
  if S.Phase = 0 then
  begin
    var FB := Integer(S.Command and $3F);
    if Avail < FB then
      Exit(StepWait);
    Advance(FB);
    S.Phase := 1;
  end;
  while S.Index < 16 do
  begin
    if Avail < 16 then
      Exit(StepWait);
    S.VQCLUT[S.Index] := Word(Peek(16));
    Advance(16);
    Inc(S.Index);
  end;
  Result := StepDone;
end;

// CSC: MBC macroblocks of RAW8 to RGB, each one leaving before the next.
function TPS2IPU.StepCSC: Integer;
begin
  while True do
    case S.Phase of
      0:
        begin
          if S.MBCount = 0 then
            Exit(StepDone);
          S.Index := 0;
          S.Phase := 1;
        end;
      1:
        begin
          while S.Index < 384 do
          begin
            if Avail < 8 then
              Exit(StepWait);
            S.Raw[S.Index] := Byte(Peek(8));
            Advance(8);
            Inc(S.Index);
          end;
          ColorConvert(@S.Raw[0], (S.Command and $08000000) <> 0);
          Dec(S.MBCount);
          S.Phase := 2;
        end;
    else
      begin
        if FOutSize > 0 then
          Exit(StepWait);
        S.Phase := 0;
      end;
    end;
end;

// PACK: MBC macroblocks of RGBA32 to RGBA16 (OFM) or 4-bit indices of the
// nearest VQ CLUT colour.
function TPS2IPU.StepPACK: Integer;
var
  Half: array[0..255] of Word;
  Index4: array[0..127] of Byte;
begin
  while True do
    case S.Phase of
      0:
        begin
          if S.MBCount = 0 then
            Exit(StepDone);
          S.Index := 0;
          S.Phase := 1;
        end;
      1:
        begin
          while S.Index < 1024 do
          begin
            if Avail < 8 then
              Exit(StepWait);
            S.Raw[S.Index] := Byte(Peek(8));
            Advance(8);
            Inc(S.Index);
          end;
          for var I := 0 to 255 do
          begin
            var P := PByte(@S.Raw[I * 4]);
            Half[I] := Word((P[0] shr 3) or (Cardinal(P[1] shr 3) shl 5) or (Cardinal(P[2] shr 3) shl 10) or
              (Cardinal(P[3] shr 7) shl 15));
          end;
          if (S.Command and $08000000) <> 0 then
            OutWrite(@Half[0], SizeOf(Half))
          else
          begin
            FillChar(Index4, SizeOf(Index4), 0);
            for var I := 0 to 255 do
            begin
              var Best := 0;
              var BestD := MaxInt;
              for var K := 0 to 15 do
              begin
                var C := S.VQCLUT[K];
                var DR := Integer(Half[I] and 31) - Integer(C and 31);
                var DG := Integer((Half[I] shr 5) and 31) - Integer((C shr 5) and 31);
                var DB := Integer((Half[I] shr 10) and 31) - Integer((C shr 10) and 31);
                var D := DR * DR + DG * DG + DB * DB;
                if D < BestD then
                begin
                  BestD := D;
                  Best := K;
                end;
              end;
              Index4[I shr 1] := Index4[I shr 1] or Byte(Best shl ((I and 1) * 4));
            end;
            OutWrite(@Index4[0], SizeOf(Index4));
          end;
          Dec(S.MBCount);
          S.Phase := 2;
        end;
    else
      begin
        if FOutSize > 0 then
          Exit(StepWait);
        S.Phase := 0;
      end;
    end;
end;

{ Commands }

procedure TPS2IPU.StartCommand(Value: Cardinal);
begin
  Inc(Commands);
  Inc(CommandCounts[Value shr 28]);
  if (Trace <> nil) and not (Value shr 28 in [2, 3, 4]) and (Trace.Count < 100000) then
    if FDMAC <> nil then
      Trace.Add(Format('%d cmd=%.8x ctrl=%.8x d3=%.8x/%x d4=%.8x/%x', [FScheduler.Now, Value, S.CTRL,
        FDMAC.Ch[DMAFromIPU].MADR, FDMAC.Ch[DMAFromIPU].QWC, FDMAC.Ch[DMAToIPU].MADR, FDMAC.Ch[DMAToIPU].QWC]))
    else
      Trace.Add(Format('%d cmd=%.8x', [FScheduler.Now, Value]));
  S.CTRL := S.CTRL and not Cardinal(CtrlECD or CtrlSCD);
  S.Command := Value;
  S.LastCommand := Integer(Value shr 28);
  S.Busy := True;
  S.Phase := 0;
  S.Index := 0;
  S.StartAt := 0;
  case Value shr 28 of
    1:
      begin
        S.MBCount := 0;
        S.QSC := (Value shr 16) and $1F;
        S.DT := 0;
        S.MBType := 0;
        S.StartAt := FScheduler.Now + IDECDelay;
      end;
    2:
      begin
        S.BCommand := Value;
        S.BPhase := 0;
      end;
    7, 8:
      S.MBCount := Integer(Value and $7FF);
  end;
end;

procedure TPS2IPU.Finish(Flags: Cardinal; Interrupt: Boolean);
begin
  S.Busy := False;
  S.CTRL := S.CTRL or Flags;
  if Interrupt and Assigned(FOnInterrupt) then
    FOnInterrupt();
end;

procedure TPS2IPU.Execute;
begin
  if not S.Busy or (S.StartAt > FScheduler.Now) then
    Exit;
  var R: Integer;
  case S.Command shr 28 of
    0:
      begin
        // BCLR: empty input FIFO, the stream starts at bit BP.
        S.InSize := 0;
        S.InBit := Integer(S.Command and $7F);
        R := StepDone;
      end;
    1: R := StepIDEC;
    2: R := StepBDEC(False);
    3: R := StepVDEC;
    4: R := StepFDEC;
    5: R := StepSETIQ;
    6: R := StepSETVQ;
    7: R := StepCSC;
    8: R := StepPACK;
    9:
      begin
        S.TH0 := S.Command and $1FF;
        S.TH1 := (S.Command shr 16) and $1FF;
        R := StepDone;
      end;
  else
    R := StepDone;
  end;
  case R of
    StepDone: Finish(0, True);
    StepStart: Finish(CtrlSCD, True);
    StepError: Finish(CtrlECD, False);
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
  Result := Min(Count, (InCapacity - S.InSize) div 16);
  if Result <= 0 then
    Exit(0);
  Move(Data^, S.InBuf[S.InSize], Result * 16);
  Inc(S.InSize, Result * 16);
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

// Data moved inside a DMA transfer: the IPU goes on once the DMAC is done
// (from the pump loop, or right after through the scheduler).
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
        if S.InSize < InCapacity then
          FDMAC.Resume(DMAToIPU);
        if FOutSize > 0 then
          FDMAC.Resume(DMAFromIPU);
      end;
    until not FAgain;
  finally
    FPumping := False;
  end;
end;

procedure TPS2IPU.Kick;
begin
  Pump;
  if S.Busy and (S.StartAt > FScheduler.Now) then
    FScheduler.Schedule(TPS2Event.IPU, S.StartAt);
end;

procedure TPS2IPU.Event;
begin
  Kick;
end;

{ Registers }

procedure TPS2IPU.FIFOState(out BP, IFC, FP: Cardinal);
begin
  BP := Cardinal(S.InBit) and $7F;
  IFC := Cardinal(S.InSize div 16);
  FP := 0;
  if (BP <> 0) and (IFC <> 0) then
  begin
    FP := 1;
    Dec(IFC);
  end;
end;

function TPS2IPU.Read(Address: Cardinal; Size: Integer): UInt64;
begin
  var BP, IFC, FP: Cardinal;
  var Busy: UInt64 := 0;
  if S.Busy then
    Busy := 1;
  case Address and $FF of
    $00:
      begin
        // DATA: the VDEC/FDEC result, else the stream ahead.
        var D := S.Data;
        if (S.LastCommand <> 3) and (S.LastCommand <> 4) then
          D := PeekTop;
        Result := D;
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
        Result := 0;
        if not S.Busy then
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
        Kick;
      end;
    $10:
      begin
        var V := Cardinal(Value);
        if (V and CtrlRST) <> 0 then
        begin
          S.Busy := False;
          S.LastCommand := -1;
          S.TH0 := 0;
          S.TH1 := 0;
          S.InSize := 0;
          S.InBit := 0;
          FOutHead := 0;
          FOutSize := 0;
        end;
        S.CTRL := (S.CTRL and not Cardinal($3FFF0000)) or (V and $3FFF0000);
        Kick;
      end;
  end;
end;

procedure TPS2IPU.WriteFIFO(Address: Cardinal; const Value: TPS2Reg128);
begin
  if (Address and $F0) <> $10 then
    Exit;
  var V := Value;
  if TakeInput(@V, 1) > 0 then
    Kick;
end;

procedure TPS2IPU.ReadFIFO(Address: Cardinal; out Value: TPS2Reg128);
begin
  Value := Default(TPS2Reg128);
  if (Address and $F0) <> 0 then
    Exit;
  if GiveOutput(@Value, 1) > 0 then
    Kick;
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
