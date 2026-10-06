unit RetroTune.ZXTracker.Engine;

interface

uses
  System.SysUtils;

const
  ST1MaxPat = 64;

type
  TZXTrackerKind = (tkSTC, tkASC, tkSTP, tkPSC, tkFTC, tkPT1, tkPT2, tkSQT, tkGTR, tkPSM);

  TZXTrackerRegisters = array[0..13] of Byte;

  TST1Smp = packed record
    Vl, Ns: array[0..31] of byte;
    Tn: array[0..31] of word;
    LPos, LLen: byte;
  end;

  TST1Pos = packed record
    PNum, PTrans: byte;
  end;

  TST1Orn = array[0..31] of shortint;

  TST11PatLn = array[0..2] of packed record
    Nt, ESNum, EONum: byte;
  end;

  TST1Pat = array[0..63] of TST11PatLn;

  TSTCPat = packed record
    Num: byte;
    Ofs: array[0..2] of word;
  end;

  ModTypes = packed record
    case Integer of
      0:
        (Index: array[0..65536] of byte);
      1:
        (ST_Delay: byte;
        ST_PositionsPointer, ST_OrnamentsPointer, ST_PatternsPointer: word;
        ST_Name: array[0..17] of AnsiChar;
        ST_Size: word);
      2:
        (ASC1_Delay, ASC1_LoopingPosition: byte;
        ASC1_PatternsPointers, ASC1_SamplesPointers, ASC1_OrnamentsPointers: word;
        ASC1_Number_Of_Positions: byte;
        ASC1_Positions: array[0..65535 - 9] of byte);
      3:
        (ASC0_Delay: byte;
        ASC0_PatternsPointers, ASC0_SamplesPointers, ASC0_OrnamentsPointers: word;
        ASC0_Number_Of_Positions: byte;
        ASC0_Positions: array[0..65535 - 8] of byte);
      4:
        (STP_Delay: byte;
        STP_PositionsPointer, STP_PatternsPointer, STP_OrnamentsPointer, STP_SamplesPointer: word;
        STP_Init_Id: byte);
      5:
        (PT2_Delay: byte;
        PT2_NumberOfPositions: byte;
        PT2_LoopPosition: byte;
        PT2_SamplesPointers: array[0..31] of word;
        PT2_OrnamentsPointers: array[0..15] of word;
        PT2_PatternsPointer: word;
        PT2_MusicName: array[0..29] of AnsiChar;
        PT2_PositionList: array[0..65535 - 131] of byte);
      6:
        (PT3_MusicName: array[0..$62] of AnsiChar;
        PT3_TonTableId: byte;
        PT3_Delay: byte;
        PT3_NumberOfPositions: byte;
        PT3_LoopPosition: byte;
        PT3_PatternsPointer: word;
        PT3_SamplesPointers: array[0..31] of word;
        PT3_OrnamentsPointers: array[0..15] of word;
        PT3_PositionList: array[0..65535 - 201] of byte);
      7:
        (PSC_MusicName: array[0..68] of AnsiChar;
        PSC_UnknownPointer: word;
        PSC_PatternsPointer: word;
        PSC_Delay: byte;
        PSC_OrnamentsPointer: word;
        PSC_SamplesPointers: array[0..31] of word);
      8:
        (FTC_MusicName: array[0..68] of AnsiChar;
        FTC_Delay: byte;
        FTC_Loop_Position: byte;
        FTC_Slack: integer;
        FTC_PatternsPointer: word;
        FTC_Slack2: array[0..4] of byte;
        FTC_SamplesPointers: array[0..31] of word;
        FTC_OrnamentsPointers: array[0..32] of word;
        FTC_Positions: array[0..(65536 - $d4) div 2 - 1] of packed record
          Pattern: byte;
          Transposition: shortint;
        end);
      9:
        (PT1_Delay: byte;
        PT1_NumberOfPositions: byte;
        PT1_LoopPosition: byte;
        PT1_SamplesPointers: array[0..15] of word;
        PT1_OrnamentsPointers: array[0..15] of word;
        PT1_PatternsPointer: word;
        PT1_MusicName: array[0..29] of AnsiChar;
        PT1_PositionList: array[0..65535 - 99] of byte);
      10:
        (FLS_PositionsPointer: word;
        FLS_OrnamentsPointer: word;
        FLS_SamplesPointer: word;
        FLS_PatternsPointers: array[1..(65536 - 6) div 6] of packed record
          PatternA, PatternB, PatternC: word;
        end);
      11:
        (SQT_Size, SQT_SamplesPointer, SQT_OrnamentsPointer, SQT_PatternsPointer, SQT_PositionsPointer, SQT_LoopPointer: word);
      12:
        (GTR_Delay: byte;
        GTR_ID: array[0..3] of AnsiChar;
        GTR_Address: word;
        GTR_Name: array[0..31] of AnsiChar;
        GTR_SamplesPointers: array[0..14] of word;
        GTR_OrnamentsPointers: array[0..15] of word;
        GTR_PatternsPointers: array[0..31] of packed record
          PatternA, PatternB, PatternC: word;
        end;
        GTR_NumberOfPositions: byte;
        GTR_LoopPosition: byte;
        GTR_Positions: array[0..65536 - 295 - 1] of byte);
      13:
        (PSM_PositionsPointer: word;
        PSM_SamplesPointer: word;
        PSM_OrnamentsPointer: word;
        PSM_PatternsPointer: word;
        PSM_Remark: array[0..65535 - 8] of byte);
      14:
        (ST1_Smp: array[1..15] of TST1Smp;
        ST1_Pos: array[0..255] of TST1Pos;
        ST1_PosLen: byte;
        ST1_Orn: array[0..16] of TST1Orn;
        ST1_Del, ST1_PatLen: byte;
        ST1_Pat: array[0..64] of TST1Pat);
      16:
        (ST3_Delay: byte;
        ST3_PositionsPointer, ST3_SamplesPointer, ST3_OrnamentsPointer, ST3_PatternsPointer: word;
        ST3_Title: array[1..55] of AnsiChar);
  end;

  STC_Channel_Parameters = record
    Address_In_Pattern, SamplePointer, OrnamentPointer, Ton: word;
    Amplitude, Note, Position_In_Sample, Number_Of_Notes_To_Skip: byte;
    Sample_Tik_Counter, Note_Skip_Counter: shortint;
    Envelope_Enabled: boolean;
  end;

  STC_Parameters = record
    DelayCounter, Transposition, CurrentPosition: byte;
  end;

  ASC_Channel_Parameters = record
    Initial_Point_In_Sample, Point_In_Sample, Loop_Point_In_Sample, Initial_Point_In_Ornament, Point_In_Ornament, Loop_Point_In_Ornament, Address_In_Pattern, Ton, Ton_Deviation: word;
    Note, Addition_To_Note, Number_Of_Notes_To_Skip, Initial_Noise, Current_Noise, Volume, Ton_Sliding_Counter, Amplitude, Amplitude_Delay, Amplitude_Delay_Counter: byte;
    Current_Ton_Sliding, Substruction_for_Ton_Sliding: smallint;
    Note_Skip_Counter, Addition_To_Amplitude: shortint;
    Envelope_Enabled, Sound_Enabled, Sample_Finished, Break_Sample_Loop, Break_Ornament_Loop: boolean;
  end;

  ASC_Parameters = record
    Delay, DelayCounter, CurrentPosition: byte;
  end;

  STP_Channel_Parameters = record
    OrnamentPointer, SamplePointer, Address_In_Pattern, Ton: word;
    Position_In_Ornament, Loop_Ornament_Position, Ornament_Length, Position_In_Sample, Loop_Sample_Position, Sample_Length, Volume, Number_Of_Notes_To_Skip, Note, Amplitude: byte;
    Current_Ton_Sliding: smallint;
    Envelope_Enabled, Enabled: boolean;
    Glissade, Note_Skip_Counter: shortint
  end;

  STP_Parameters = record
    DelayCounter, CurrentPosition, Transposition: byte;
  end;

  PSC_Channel_Parameters = record
    Address_In_Pattern, OrnamentPointer, SamplePointer, Ton: word;
    Current_Ton_Sliding, Ton_Accumulator, Addition_To_Ton: smallint;
    Initial_Volume, Note_Skip_Counter: shortint;
    Note, Volume, Amplitude, Volume_Counter, Volume_Counter1, Volume_Counter_Init, Noise_Accumulator, Position_In_Sample, Loop_Sample_Position, Position_In_Ornament, Loop_Ornament_Position: byte;
    Enabled, Ornament_Enabled, Envelope_Enabled, Gliss, Ton_Slide_Enabled, Break_Sample_Loop, Break_Ornament_Loop, Volume_Inc: boolean;
  end;

  PSC_Parameters = record
    Delay, DelayCounter, Lines_Counter, Noise_Base, Positions_Pointer: word;
  end;

  FTC_Channel_Parameters = record
    Address_In_Pattern, OrnamentPointer, SamplePointer, Envelope_Accumulator, Envelope, Ton: word;
    Ornament_Length, Loop_Ornament_Position, Position_In_Ornament, Sample_Length, Loop_Sample_Position, Position_In_Sample, Sample_Noise_Accumulator, Noise_Accumulator, Note_Accumulator, Ton_Slide_Direction, Volume, Noise, Amplitude, Previous_Note, Note: byte;
    Note_Skip_Counter, Volume_Slide: shortint;
    Addition_To_Ton, Ton_Slide_Step, Ton_Slide_Step1, Current_Ton_Sliding, Ton_Accumulator: smallint;
    Envelope_Enabled, Sample_Enabled: boolean;
  end;

  FTC_Parameters = record
    Delay, DelayCounter, Transposition, CurrentPosition, EnvT, Retrig: byte;
  end;

  PT1_Channel_Parameters = record
    Address_In_Pattern, OrnamentPointer, SamplePointer, Ton: word;
    Number_Of_Notes_To_Skip, Volume, Loop_Sample_Position, Position_In_Sample, Sample_Length, Amplitude, Note: byte;
    Note_Skip_Counter: shortint;
    Envelope_Enabled, Enabled: boolean;
  end;

  PT1_Parameters = record
    Delay, DelayCounter, CurrentPosition: byte;
  end;

  PT2_Channel_Parameters = record
    Address_In_Pattern, OrnamentPointer, SamplePointer, Ton: word;
    Loop_Ornament_Position, Ornament_Length, Position_In_Ornament, Loop_Sample_Position, Sample_Length, Position_In_Sample, Volume, Number_Of_Notes_To_Skip, Note, Slide_To_Note, Amplitude: byte;
    Current_Ton_Sliding, Ton_Delta: smallint;
    GlissType: integer;
    Envelope_Enabled, Enabled: boolean;
    Glissade, Addition_To_Noise, Note_Skip_Counter: shortint
  end;

  PT2_Parameters = record
    DelayCounter, Delay, CurrentPosition: byte;
  end;

  SQT_Channel_Parameters = record
    Address_In_Pattern, SamplePointer, Point_In_Sample, OrnamentPointer, Point_In_Ornament, Ton, ix27: word;
    Volume, Amplitude, Note, ix21: byte;
    Ton_Slide_Step, Current_Ton_Sliding: smallint;
    Sample_Tik_Counter, Ornament_Tik_Counter, Transposit: shortint;
    Enabled, Envelope_Enabled, Ornament_Enabled, Gliss, MixNoise, MixTon, b4ix0, b6ix0, b7ix0: boolean;
  end;

  SQT_Parameters = record
    Delay, DelayCounter, Lines_Counter: byte;
    Positions_Pointer: word;
  end;

  GTR_Channel_Parameters = record
    SamplePointer, OrnamentPointer, Address_In_Pattern, Ton: word;
    Position_In_Sample, Loop_Sample_Position, Sample_Length, Position_In_Ornament, Loop_Ornament_Position, Ornament_Length, Volume, Note, Amplitude: byte;
    Note_Skip_Counter: shortint;
    Envelope_Enabled, Enabled: boolean;
  end;

  GTR_Parameters = record
    DelayCounter, CurrentPosition: byte;
  end;

  PSM_Channel_Parameters = record
    Address_In_Pattern, RetAddress, DivShift, Ton: word;
    Number_Of_Notes_To_Skip, Note_Skip_Counter, Amplitude, RetCnt, Vol, VolCnt, LoopCnt, Orn, EnvType, EnvDiv, Samp: byte;
    OrnTick, SmpTick, Note: shortint;
  end;

  PSM_Parameters = record
    Delay, DelayCounter: byte;
    CurrentPosition: byte;
    Transposition: shortint;
    Finished: boolean;
  end;

  TTrackerState = record
    STC: STC_Parameters;
    STC_A, STC_B, STC_C: STC_Channel_Parameters;
    ASC: ASC_Parameters;
    ASC_A, ASC_B, ASC_C: ASC_Channel_Parameters;
    STP: STP_Parameters;
    STP_A, STP_B, STP_C: STP_Channel_Parameters;
    PSC: PSC_Parameters;
    PSC_A, PSC_B, PSC_C: PSC_Channel_Parameters;
    FTC: FTC_Parameters;
    FTC_A, FTC_B, FTC_C: FTC_Channel_Parameters;
    PT1: PT1_Parameters;
    PT1_A, PT1_B, PT1_C: PT1_Channel_Parameters;
    PT2: PT2_Parameters;
    PT2_A, PT2_B, PT2_C: PT2_Channel_Parameters;
    SQT: SQT_Parameters;
    SQT_A, SQT_B, SQT_C: SQT_Channel_Parameters;
    GTR: GTR_Parameters;
    GTR_A, GTR_B, GTR_C: GTR_Channel_Parameters;
    PSM: PSM_Parameters;
    PSM_A, PSM_B, PSM_C: PSM_Channel_Parameters;
  end;

  TTrackerMemory = class
  private
    FSize, FBudget: Integer;
    FAllowTail: Boolean;
    function GetByte(Address: Integer): Byte;
    procedure PutByte(Address: Integer; Value: Byte);
  public
    Header: ModTypes;
    procedure Load(const Data: TBytes);
    function READ16(Address: Integer): Word;
    property Index[Address: Integer]: Byte read GetByte write PutByte;
    procedure BeginFrame;
    property AllowTail: Boolean read FAllowTail write FAllowTail;
  end;

  TTrackerAY = packed record
    case Integer of
      0:
        (Index: TZXTrackerRegisters);
      1:
        (TonA, TonB, TonC: Word;
        Noise, Mixer, AmpA, AmpB, AmpC: Byte;
        Envelope: Word;
        Shape: Byte);
  end;

  TZXTrackerEngine = class
  private
    RAM: TTrackerMemory;
    FInitial: TBytes;
    FKind: TZXTrackerKind;
    PlParams: TTrackerState;
    RegisterAY: TTrackerAY;
    FTick: Integer;
    FVersion, FEnvelopeShape: Integer;
    FToneRestart: array[0..2] of Boolean;
    FLooped: Boolean;
    function READ16(Address: Integer): Word;
    function MarkLoop(Value: Integer): Integer;
    procedure SetEnvelopeRegister(Value: Integer);
    procedure SetMixerRegister(Value: Integer);
    procedure SetAmplA(Value: Integer);
    procedure SetAmplB(Value: Integer);
    procedure SetAmplC(Value: Integer);
    procedure STC_Get_Registers;
    procedure ASC_Get_Registers;
    procedure STP_Get_Registers;
    procedure PSC_Get_Registers;
    procedure FTC_Get_Registers;
    procedure PT1_Get_Registers;
    procedure PT2_Get_Registers;
    procedure SQT_Get_Registers;
    procedure GTR_Get_Registers;
    procedure PSM_Get_Registers;
  public
    constructor Create(const Data: TBytes; Kind: TZXTrackerKind);
    destructor Destroy; override;
    procedure Reset;
    procedure Tick;
    function Registers: TZXTrackerRegisters;
    function ToneRestart(Channel: Integer): Boolean;
    property Looped: Boolean read FLooped;
  end;

function NormalizeZXTracker(const Data: TBytes; const FormatName: string; out Kind: TZXTrackerKind): TBytes;

implementation

uses
  RetroTune.Binary;

const
  ASM_Table: array[0..$55] of word =
    ($edc, $e07, $d3e, $c80, $bcc, $b22, $a82, $9ec, $95c, $8d6, $858, $7e0, $76e, $704, $69f,
    $640, $5e6, $591, $541, $4f6, $4ae, $46b, $42c, $3f0, $3b7, $382, $34f, $320, $2f3, $2c8,
    $2a1, $27b, $257, $236, $216, $1f8, $1dc, $1c1, $1a8, $190, $179, $164, $150, $13d, $12c,
    $11b, $10b, $fc, $ee, $e0, $d4, $c8, $bd, $b2, $a8, $9f, $96, $8d, $85, $7e, $77, $70, $6a,
    $64, $5e, $59, $54, $50, $4b, $47, $43, $3f, $3c, $38, $35, $32, $2f, $2d, $2a, $28, $26, $24,
    $22, $20, $1e, $1c);
  ST_Table: array[0..95] of word =
    ($ef8, $e10, $d60, $c80, $bd8, $b28, $a88, $9f0, $960, $8e0, $858, $7e0, $77c, $708, $6b0,
    $640, $5ec, $594, $544, $4f8, $4b0, $470, $42c, $3f0, $3be, $384, $358, $320, $2f6, $2ca,
    $2a2, $27c, $258, $238, $216, $1f8, $1df, $1c2, $1ac, $190, $17b, $165, $151, $13e, $12c,
    $11c, $10b, $fc, $ef, $e1, $d6, $c8, $bd, $b2, $a8, $9f, $96, $8e, $85, $7e, $77, $70, $6b,
    $64, $5e, $59, $54, $4f, $4b, $47, $42, $3f, $3b, $38, $35, $32, $2f, $2c, $2a, $27, $25, $23,
    $21, $1f, $1d, $1c, $1a, $19, $17, $16, $15, $13, $12, $11, $10, $f);
  SQT_Table: array[0..$5f] of word =
    ($d5d, $c9c, $be7, $b3c, $a9b, $a02, $973, $8eb, $86b, $7f2, $780, $714, $6ae, $64e,
    $5f4, $59e, $54f, $501, $4b9, $475, $435, $3f9, $3c0, $38a, $357, $327, $2fa, $2cf, $2a7,
    $281, $25d, $23b, $21b, $1fc, $1e0, $1c5, $1ac, $194, $17d, $168, $153, $140, $12e, $11d,
    $10d, $fe, $f0, $e2, $d6, $ca, $be, $b4, $aa, $a0, $97, $8f, $87, $7f, $78, $71, $6b, $65, $5f,
    $5a, $55, $50, $4c, $47, $43, $40, $3c, $39, $35, $32, $30, $2d, $2a, $28, $26, $24, $22, $20,
    $1e, $1c, $1b, $19, $18, $16, $15, $14, $13, $12, $11, $10, $f, $e);
  PSM_Table: array[0..95] of word =
    ($D3D, $C7F, $BCB, $B22, $A82, $9EB, $95D, $8D6, $857, $7DF, $76E, $703,
    $69F, $63F, $5E6, $591, $541, $4F6, $4AE, $46B, $42C, $3F0, $3B7, $382,
    $34F, $320, $2F3, $2C8, $2A1, $27B, $257, $236, $216, $1F8, $1DC, $1C1,
    $1A8, $190, $179, $164, $150, $13D, $12C, $11B, $10B, $0FC, $0EE, $0E0,
    $0D4, $0C8, $0BD, $0B2, $0A8, $09F, $096, $08D, $085, $07E, $077, $070,
    $06A, $064, $05E, $059, $054, $04F, $04B, $047, $043, $03F, $03B, $038,
    $035, $032, $02F, $02D, $02A, $028, $025, $023, $021, $01F, $01E, $01C,
    $01A, $019, $018, $016, $015, $014, $013, $012, $011, $010, $00F, $00E);
  PT3NoteTable_ST: array[0..95] of word = (
    $0EF8, $0E10, $0D60, $0C80, $0BD8, $0B28, $0A88, $09F0, $0960, $08E0, $0858, $07E0,
    $077C, $0708, $06B0, $0640, $05EC, $0594, $0544, $04F8, $04B0, $0470, $042C, $03FD,
    $03BE, $0384, $0358, $0320, $02F6, $02CA, $02A2, $027C, $0258, $0238, $0216, $01F8,
    $01DF, $01C2, $01AC, $0190, $017B, $0165, $0151, $013E, $012C, $011C, $010A, $00FC,
    $00EF, $00E1, $00D6, $00C8, $00BD, $00B2, $00A8, $009F, $0096, $008E, $0085, $007E,
    $0077, $0070, $006B, $0064, $005E, $0059, $0054, $004F, $004B, $0047, $0042, $003F,
    $003B, $0038, $0035, $0032, $002F, $002C, $002A, $0027, $0025, $0023, $0021, $001F,
    $001D, $001C, $001A, $0019, $0017, $0016, $0015, $0013, $0012, $0011, $0010, $000F);
  st1nts: array[1..7] of Integer = (9, 11, 0, 2, 4, 5, 7);
  FTCNoteTable2: array[0..95] of word =
    ($0D10, $0C58, $0BA0, $0B00, $0A60, $09C8, $0940, $08B8, $0840, $07C0, $0750, $06F0,
    $0688, $062C, $05D0, $0580, $0530, $04E4, $04A0, $045C, $0420, $03E0, $03A8, $0378,
    $0344, $0316, $02E8, $02C0, $0298, $0272, $0250, $022E, $0210, $01F0, $01D4, $01BC,
    $01A2, $018B, $0174, $0160, $014C, $0139, $0128, $0117, $0108, $00F8, $00EA, $00DE,
    $00D1, $00C5, $00BA, $00B0, $00A6, $009C, $0094, $008B, $0084, $007C, $0075, $006F,
    $0068, $0062, $005D, $0058, $0053, $004E, $004A, $0045, $0042, $003E, $003A, $0037,
    $0034, $0031, $002E, $002C, $0029, $0027, $0025, $0022, $0021, $001F, $001D, $001B,
    $001A, $0018, $0017, $0016, $0014, $0013, $0012, $0011, $0010, $000F, $000E, $000D);

function U8(Value: Int64): Byte; overload;
begin
  Result := Value and $FF;
end;

function U8(Value: Boolean): Byte; overload;
begin
  Result := Ord(Value);
end;

function U16(Value: Int64): Word; overload;
begin
  Result := Value and $FFFF;
end;

function U16(Value: Boolean): Word; overload;
begin
  Result := Ord(Value);
end;

function S8(Value: Int64): ShortInt;
begin
  var N := Integer(Value and $FF);
  if N >= $80 then
    Dec(N, $100);
  Result := N;
end;

function S16(Value: Int64): SmallInt;
begin
  var N := Integer(Value and $FFFF);
  if N >= $8000 then
    Dec(N, $10000);
  Result := N;
end;

procedure IncU8(var Value: byte; Delta: Int64 = 1);
begin
  Value := U8(Int64(Value) + Delta);
end;

procedure DecU8(var Value: byte; Delta: Int64 = 1);
begin
  Value := U8(Int64(Value) - Delta);
end;

procedure IncU16(var Value: word; Delta: Int64 = 1);
begin
  Value := U16(Int64(Value) + Delta);
end;

procedure DecU16(var Value: word; Delta: Int64 = 1);
begin
  Value := U16(Int64(Value) - Delta);
end;

procedure IncS8(var Value: shortint; Delta: Int64 = 1);
begin
  Value := S8(Int64(Value) + Delta);
end;

procedure DecS8(var Value: shortint; Delta: Int64 = 1);
begin
  Value := S8(Int64(Value) - Delta);
end;

procedure IncS16(var Value: smallint; Delta: Int64 = 1);
begin
  Value := S16(Int64(Value) + Delta);
end;

procedure DecS16(var Value: smallint; Delta: Int64 = 1);
begin
  Value := S16(Int64(Value) - Delta);
end;

function ModuleWord(const M: ModTypes; Address: Integer): Word;
begin
  if (Address < 0) or (Address > 65534) then
    raise EArgumentException.Create('Invalid tracker word address');
  Result := Integer(M.Index[Address]) + Integer(M.Index[Address + 1]) * 256;
end;

procedure ModulePutWord(var M: ModTypes; Address: Integer; Value: Integer);
begin
  if (Address < 0) or (Address > 65534) or (Value < 0) or (Value > 65535) then
    raise EArgumentException.Create('Invalid tracker relocated pointer');
  M.Index[Address] := Value and 255;
  M.Index[Address + 1] := Value shr 8;
end;

function ST12STC(var m: ModTypes; msize: integer): boolean;
var
  Pats: array of AnsiString;

  function AddPat(const pat: AnsiString): integer;
  var
    l, i: integer;
  begin
    Result := 0;
    l := Length(Pats);
    for i := 0 to l - 1 do
      if Pats[i] <> pat then
        Inc(Result, Length(Pats[i]))
      else
        exit;
    SetLength(Pats, l + 1);
    Pats[l] := pat;
  end;

var
  pat: AnsiString;
  empty: integer;

  function CalcEmpty(i, j, c: integer): integer;
  var
    n, newempty: integer;
  begin
    newempty := 0;
    for n := j + 1 to m.ST1_PatLen - 1 do
      if m.ST1_Pat[i][n][c].Nt and $F0 = 0 then
        Inc(newempty)
      else
        break;
    if newempty <> empty then
    begin
      empty := newempty;
      pat := pat + AnsiChar(161 + empty);
    end;
    Result := empty;
  end;

var
  mc: ModTypes;
  CPats: array[0..ST1MaxPat] of TSTCPat;
  NPats, NPatsE, NPatsU, i, ir, j, c, n, o, Note, Octave, Diez, sam, orn, et, ep: integer;
  SmpUsed: array[1..15] of boolean;
  OrnUsed: array[0..15] of boolean;
  PatExists, PatUsed: array[0..ST1MaxPat] of boolean;
begin
  if msize > 3009 + ST1MaxPat * 576 then
    exit(False);
  if msize <= 3009 then
    exit(False);
  if (msize - 3009) mod 576 <> 0 then
    exit(False);
  NPats := (msize - 3009) div 576 - 1;
  if NPats > ST1MaxPat then
    exit(False);
  if not (m.ST1_PatLen in [1..64]) then
    exit(False);
  mc.ST_Delay := m.ST1_Del;
  mc.ST_Name := 'SONG BY ST COMPILE';

  for i := 1 to 15 do
  begin
    SmpUsed[i] := False;
    OrnUsed[i] := False;
  end;

  OrnUsed[0] := True;

  for i := 0 to ST1MaxPat do
  begin
    PatUsed[i] := False;
    PatExists[i] := False;
    CPats[i].Num := i + 1;
    CPats[i].Ofs[0] := U16(0);
    CPats[i].Ofs[1] := U16(0);
    CPats[i].Ofs[2] := U16(0);
  end;

  NPatsE := 0;
  NPatsU := 0;
  for i := 0 to 255 do
  begin
    n := m.ST1_Pos[i].PNum;
    if n = 0 then
      exit(False);
    Dec(n);
    if n > ST1MaxPat then
      exit(False);
    if not PatUsed[n] and (i <= m.ST1_PosLen) then
    begin
      Inc(NPatsU);
      PatUsed[n] := True;
    end;
    if not PatExists[n] then
    begin
      Inc(NPatsE);
      PatExists[n] := True;
    end;
  end;
  if NPatsU = 0 then
    exit(False);

  for i := ST1MaxPat downto 0 do
  begin
    if PatUsed[i] then
      break;
    if PatExists[i] then
    begin
      PatExists[i] := False;
      Dec(NPatsE);
    end;
  end;
  if NPatsE - 1 > NPats then
    exit(False);

  ir := -1;
  for i := 0 to ST1MaxPat do
    if PatExists[i] then
    begin
      Inc(ir);
      if PatUsed[i] then
      begin
        for c := 0 to 2 do
        begin
          pat := '';
          empty := -1;
          sam := -1;
          orn := -1;
          et := -1;
          ep := -1;
          j := 0;
          while j < m.ST1_PatLen do
          begin
            begin
              Note := m.ST1_Pat[ir][j][c].Nt shr 4;
              if Note = 0 then
              begin
                Inc(j, CalcEmpty(ir, j, c));
                pat := pat + #$81;
              end
              else
              begin
                CalcEmpty(ir, j, c);
                n := m.ST1_Pat[ir][j][c].ESNum shr 4;
                if (n in [1..15]) and (n <> sam) then
                begin
                  sam := n;
                  pat := pat + AnsiChar($60 + n);
                  SmpUsed[n] := True;
                end;
                n := m.ST1_Pat[ir][j][c].ESNum and 15;
                if n in [7..14] then
                begin
                  if (et <> n) or (ep <> m.ST1_Pat[ir][j][c].EONum) then
                  begin
                    orn := -1;
                    et := n;
                    ep := m.ST1_Pat[ir][j][c].EONum;
                    pat := pat + AnsiChar($80 + n) + AnsiChar(ep);
                  end;
                end
                else if n in [1, 15] then
                begin
                  if n = 1 then
                    o := 0
                  else
                    o := m.ST1_Pat[ir][j][c].EONum and 15;
                  if o <> orn then
                  begin
                    et := -1;
                    ep := -1;
                    orn := o;
                    if (n = 1) and (o = 0) then
                      pat := pat + AnsiChar($82)
                    else
                      pat := pat + AnsiChar($70 + o);
                    OrnUsed[o] := True;
                  end;
                end;
                if Note and 8 = 0 then
                begin
                  Octave := m.ST1_Pat[ir][j][c].Nt and 7;
                  Diez := Ord((m.ST1_Pat[ir][j][c].Nt and 8) <> 0);
                  if (Note in [2, 5]) and (Diez <> 0) then
                    exit(False);
                  Note := st1nts[Note] + Octave * 12 + Diez;
                  if not (Note in [0..$5F]) then
                    exit(False);
                  pat := pat + AnsiChar(Note);
                end
                else
                  pat := pat + #$80;
                Inc(j, empty);
              end;
            end;
            Inc(j);
          end;
          CPats[i].Ofs[c] := U16(AddPat(pat + #$FF));
        end;
      end;
    end;

  n := 27;
  for i := 1 to 15 do
    if SmpUsed[i] then
    begin
      mc.Index[n] := U8(i);
      Inc(n);
      for j := 0 to 31 do
      begin
        mc.Index[n] := U8((m.ST1_Smp[i].Vl[j] and 15) or
            ((m.ST1_Smp[i].Tn[j] and $F00) shr 4));
        Inc(n);
        mc.Index[n] := U8((m.ST1_Smp[i].Ns[j] and $DF) or
            ((m.ST1_Smp[i].Tn[j] and $1000) shr 7));
        Inc(n);
        mc.Index[n] := U8(m.ST1_Smp[i].Tn[j]);
        Inc(n);
      end;
      mc.Index[n] := U8(m.ST1_Smp[i].LPos);
      Inc(n);
      mc.Index[n] := U8(m.ST1_Smp[i].LLen);
      Inc(n);
    end;

  mc.ST_PositionsPointer := n;
  mc.Index[n] := U8(m.ST1_PosLen);
  Inc(n);
  Move(m.ST1_Pos, mc.Index[n], (m.ST1_PosLen + 1) * 2);
  Inc(n, (m.ST1_PosLen + 1) * 2);

  mc.ST_OrnamentsPointer := n;
  for i := 0 to 15 do
    if OrnUsed[i] then
    begin
      mc.Index[n] := U8(i);
      Inc(n);
      for j := 0 to 31 do
      begin
        mc.Index[n] := U8(m.ST1_Orn[i][j]);
        Inc(n);
      end;
    end;

  mc.ST_PatternsPointer := n;
  c := n + NPatsU * SizeOf(TSTCPat) + 1;
  for i := 0 to ST1MaxPat do
    if PatUsed[i] then
    begin
      for j := 0 to 2 do
        IncU16(CPats[i].Ofs[j], c);
      Move(CPats[i], mc.Index[n], SizeOf(TSTCPat));
      Inc(n, SizeOf(TSTCPat));
    end;
  mc.Index[n] := U8(255);
  Inc(n);

  for i := 0 to Length(Pats) - 1 do
  begin
    if n + Length(Pats[i]) > 65536 then
      exit(False);
    Move(Pats[i][1], mc.Index[n], Length(Pats[i]));
    Inc(n, Length(Pats[i]));
  end;

  mc.ST_Size := n;
  Move(mc, m, n);
  Result := True;
end;

function ST32STC(var m: ModTypes; msize: integer): boolean;
var
  mc: ModTypes;
  i, j, num, ptr, ptr2, n, pat, maxpat, patsptr, patsdif, lpbeg, lplen, loadaddr: integer;
  tn: smallint;
  en, ns: byte;
  Id: boolean;
begin
  mc.ST3_Delay := m.ST_Delay;
  mc.ST_Name := 'SONG BY ST COMPILE';
  n := 27;

  i := m.ST3_PositionsPointer - 9;
  if i <= 0 then
    Exit(False);

  Id := False;
  if (i mod 130 <> 0) then
  begin
    if (i < 55) or ((i - 55) mod 130 <> 0) then
      Exit(False);
    Id := True;
  end;

  ptr := m.ST3_SamplesPointer;
  if ptr >= msize - 3 then
    Exit(False);

  num := m.Index[ptr];
  Inc(ptr);
  if ptr + num * 2 > msize then
    Exit(False);

  loadaddr := ModuleWord(m, ptr) - 9;
  if Id then
    Dec(loadaddr, 55);
  if (loadaddr < 0) or (loadaddr + msize > 65536) then
    Exit(False);

  for i := 0 to num - 1 do
  begin
    mc.Index[n] := U8(i);
    Inc(n);
    ptr2 := ModuleWord(m, ptr) - loadaddr;
    Inc(ptr, 2);
    if ptr2 + 2 + 32 * 4 > msize then
      Exit(False);

    lpbeg := m.Index[ptr2];
    Inc(ptr2);
    lplen := m.Index[ptr2] - lpbeg;
    Inc(ptr2);
    for j := 0 to 31 do
    begin
      tn := S16(ModuleWord(m, ptr2));
      Inc(ptr2, 2);
      en := U8(m.Index[ptr2]);
      Inc(ptr2);
      ns := U8(m.Index[ptr2]);
      Inc(ptr2);
      ns := U8((en and $80) or ((en and $10) shl 2) or (ns and $1f));
      if tn > 0 then
        ns := U8(ns or $20)
      else
        tn := S16(-tn);
      mc.Index[n] := U8((en and 15) or (Hi(tn) shl 4));
      Inc(n);
      mc.Index[n] := U8(ns);
      Inc(n);
      mc.Index[n] := U8(Lo(tn));
      Inc(n);
    end;
    mc.Index[n] := U8(lpbeg);
    Inc(n);
    mc.Index[n] := U8(lplen);
    Inc(n);
  end;

  mc.ST_PositionsPointer := n;
  ptr := m.ST3_PositionsPointer;
  if ptr >= msize - 3 then
    Exit(False);

  num := m.Index[ptr] - 1;
  Inc(ptr);
  if ptr + num * 2 > msize then
    Exit(False);

  mc.Index[n] := U8(num);
  Inc(n);
  maxpat := -1;
  for i := 0 to num do
  begin
    if m.Index[ptr + 1] mod 6 <> 0 then
      Exit(False);

    pat := m.Index[ptr + 1] div 6;
    if pat > maxpat then
      maxpat := pat;
    mc.Index[n] := U8(pat);
    mc.Index[n + 1] := U8(m.Index[ptr]);
    Inc(n, 2);
    Inc(ptr, 2);
  end;
  if maxpat < 0 then
    Exit(False);

  mc.ST_OrnamentsPointer := n;
  ptr := m.ST3_OrnamentsPointer;
  if ptr >= msize - 3 then
    Exit(False);

  num := m.Index[ptr];
  Inc(ptr);
  if ptr + num * 2 > msize then
    Exit(False);

  for i := 0 to num - 1 do
  begin
    mc.Index[n] := U8(i);
    Inc(n);
    ptr2 := ModuleWord(m, ptr) - loadaddr;
    Inc(ptr, 2);
    if ptr2 + 32 > msize then
      Exit(False);

    Move(m.Index[ptr2], mc.Index[n], 32);
    Inc(n, 32);
  end;

  patsptr := ptr;

  mc.ST_PatternsPointer := n;
  ptr := m.ST3_PatternsPointer;
  if ptr + maxpat * 6 + 6 > msize then
    Exit(False);

  patsdif := -patsptr + mc.ST_PatternsPointer + maxpat * 7 + 8;
  for i := 0 to maxpat do
  begin
    mc.Index[n] := U8(i);
    Inc(n);
    for j := 0 to 2 do
    begin
      ModulePutWord(mc, n, ModuleWord(m, ptr) + patsdif);
      Inc(n, 2);
      Inc(ptr, 2);
    end;
  end;
  mc.Index[n] := U8(255);
  Inc(n);

  i := m.ST3_PatternsPointer - patsptr - 1;
  if (i <= 0) or (patsptr + i > msize) then
    Exit(False);

  if (patsptr + i < msize) and (m.Index[patsptr + i] = 255) then
    Inc(i);

  Move(m.Index[patsptr], mc.Index[n], i);
  Inc(n, i);

  mc.ST_Size := n;
  Move(mc, m, n);
  Result := True;
end;

function NormalizeZXTracker(const Data: TBytes; const FormatName: string; out Kind: TZXTrackerKind): TBytes;
var
  M: ModTypes;
begin
  if (Length(Data) = 0) or (Length(Data) > 65536) then
    raise EArgumentException.Create('ZX tracker module must fit in 64 KiB');
  M := Default(ModTypes);
  Move(Data[0], M.Index[0], Length(Data));
  var Name := UpperCase(FormatName);
  var Size := Length(Data);
  if (Name = 'ST1') or (Name = 'S') then
  begin
    if not ST12STC(M, Size) then
      raise EArgumentException.Create('Invalid Sound Tracker editor module');
    Size := M.ST_Size;
    Name := 'STC';
  end
  else if Name = 'ST3' then
  begin
    if not ST32STC(M, Size) then
      raise EArgumentException.Create('Invalid Sound Tracker 3 compilation');
    Size := M.ST_Size;
    Name := 'STC';
  end
  else if Name = 'AS0' then
  begin
    RequireBytes(Data, 0, 8);
    if Size >= 65536 then
      raise EArgumentException.Create('AS0 exceeds conversion capacity');
    for var P := Size - 1 downto 1 do
      M.Index[P + 1] := M.Index[P];
    M.Index[1] := 0;
    Inc(Size);
    for var P in [2, 4, 6] do
      ModulePutWord(M, P, Integer(ModuleWord(M, P)) + 1);
    Name := 'ASC';
  end;
  if Name = 'SQT' then
  begin
    RequireBytes(Data, 0, 12);
    var Base := Integer(M.SQT_SamplesPointer) - 10;
    var Positions := Integer(M.SQT_PositionsPointer) - Base;
    var Patterns := Integer(M.SQT_PatternsPointer) - Base;
    if (Base < 0) or (Positions < 12) or (Patterns < 12) then
      raise EArgumentException.Create('Invalid SQ-Tracker relocation');
    var MaxPattern := 0;
    while True do
    begin
      if (Positions < 0) or (Positions >= Size) then
        raise EArgumentException.Create('Missing SQT position terminator');
      if M.Index[Positions] = 0 then
        Break;
      if Positions > Size - 7 then
        raise EArgumentException.Create('Truncated SQT position');
      for var Channel := 0 to 2 do
        if MaxPattern < (M.Index[Positions + Channel * 2] and $7F) then
          MaxPattern := M.Index[Positions + Channel * 2] and $7F;
      Inc(Positions, 7);
    end;
    var TableEnd := Patterns + MaxPattern * 2;
    if TableEnd > Size - 2 then
      raise EArgumentException.Create('Truncated SQT pointer table');
    for var P := 1 to TableEnd div 2 do
      ModulePutWord(M, P * 2, Integer(ModuleWord(M, P * 2)) - Base);
  end
  else if Name = 'GTR' then
  begin
    RequireBytes(Data, 0, 295);
    if (Data[1] <> Ord('G')) or (Data[2] <> Ord('T')) or (Data[3] <> Ord('R')) then
      raise EArgumentException.Create('Invalid Global Tracker signature');
    var Base := M.GTR_Address;
    for var P := 0 to 126 do
      ModulePutWord(M, 39 + P * 2, Integer(ModuleWord(M, 39 + P * 2)) - Base);
    M.GTR_Address := 0;
  end;
  if Name = 'STC' then
    Kind := tkSTC
  else if Name = 'ASC' then
    Kind := tkASC
  else if Name = 'STP' then
    Kind := tkSTP
  else if Name = 'PSC' then
    Kind := tkPSC
  else if Name = 'FTC' then
    Kind := tkFTC
  else if Name = 'PT1' then
    Kind := tkPT1
  else if Name = 'PT2' then
    Kind := tkPT2
  else if Name = 'SQT' then
    Kind := tkSQT
  else if Name = 'GTR' then
    Kind := tkGTR
  else if Name = 'PSM' then
    Kind := tkPSM
  else
    raise EArgumentException.Create('Unknown ZX tracker');
  var Minimum := 8;
  case Kind of
    tkSTC:
      Minimum := 27;
    tkASC:
      Minimum := 10;
    tkSTP:
      Minimum := 10;
    tkPSC:
      Minimum := 140;
    tkFTC:
      Minimum := 214;
    tkPT1:
      Minimum := 100;
    tkPT2:
      Minimum := 132;
    tkSQT:
      Minimum := 12;
    tkGTR:
      Minimum := 296;
  end;
  if (Size < Minimum) or (Size > 65536) then
    raise EArgumentException.Create('Truncated ZX tracker header');
  SetLength(Result, Size);
  Move(M.Index[0], Result[0], Size);
end;

procedure TTrackerMemory.Load(const Data: TBytes);
begin
  Header := Default(ModTypes);
  FSize := Length(Data);
  FBudget := 1000000;
  Move(Data[0], Header.Index[0], FSize);
end;

procedure TTrackerMemory.BeginFrame;
begin
  FBudget := 50000;
end;

function TTrackerMemory.GetByte(Address: Integer): Byte;
begin
  Dec(FBudget);
  if FBudget < 0 then
    raise EArgumentException.Create('ZX tracker command budget exceeded');
  if (Address < 0) or (Address >= FSize) then
  begin
    // GTR uses a synthetic empty sample at the end of its 64 KiB address space.
    if FAllowTail and (Address >= $FFFC) and (Address <= $FFFF) then
      Exit(0);
    raise EArgumentException.CreateFmt('ZX tracker reads outside module at $%x', [Address]);
  end;
  Result := Header.Index[Address];
end;

procedure TTrackerMemory.PutByte(Address: Integer; Value: Byte);
begin
  if (Address < 0) or (Address >= FSize) then
    raise EArgumentException.Create('ZX tracker writes outside module');
  Header.Index[Address] := Value;
end;

function TTrackerMemory.READ16(Address: Integer): Word;
begin
  Result := Integer(GetByte(Address)) + Integer(GetByte(Address + 1)) * 256;
end;

function TZXTrackerEngine.READ16(Address: Integer): Word;
begin
  Result := RAM.READ16(Address);
end;

function TZXTrackerEngine.MarkLoop(Value: Integer): Integer;
begin
  FLooped := True;
  Result := Value;
end;

procedure TZXTrackerEngine.SetEnvelopeRegister(Value: Integer);
begin
  RegisterAY.Shape := U8(Value);
  FEnvelopeShape := Value;
end;

procedure TZXTrackerEngine.SetMixerRegister(Value: Integer);
begin
  RegisterAY.Mixer := U8(Value);
end;

procedure TZXTrackerEngine.SetAmplA(Value: Integer);
begin
  RegisterAY.AmpA := U8(Value);
end;

procedure TZXTrackerEngine.SetAmplB(Value: Integer);
begin
  RegisterAY.AmpB := U8(Value);
end;

procedure TZXTrackerEngine.SetAmplC(Value: Integer);
begin
  RegisterAY.AmpC := U8(Value);
end;

constructor TZXTrackerEngine.Create(const Data: TBytes; Kind: TZXTrackerKind);
begin
  inherited Create;
  FInitial := Copy(Data);
  FKind := Kind;
  FVersion := 7;
  if (Kind = tkPSC) and (Data[8] >= Ord('0')) and (Data[8] <= Ord('9')) then
    FVersion := Data[8] - Ord('0');
  if Kind = tkFTC then
  begin
    FVersion := 0;
    if (Data[67] = Ord('0')) and (Data[68] >= Ord('0')) and (Data[68] <= Ord('9')) then
      FVersion := Data[68] - Ord('0');
  end;
  RAM := TTrackerMemory.Create;
  RAM.AllowTail := Kind in [tkGTR, tkPSM];
  Reset;
end;

destructor TZXTrackerEngine.Destroy;
begin
  RAM.Free;
  inherited;
end;

function TZXTrackerEngine.Registers: TZXTrackerRegisters;
begin
  Result := RegisterAY.Index;
end;

function TZXTrackerEngine.ToneRestart(Channel: Integer): Boolean;
begin
  Result := FToneRestart[Channel];
end;

procedure TZXTrackerEngine.Tick;
begin
  RAM.BeginFrame;
  RegisterAY.Shape := $FF;
  for var Channel := 0 to 2 do
    FToneRestart[Channel] := False;
  case FKind of
    tkSTC:
      STC_Get_Registers;
    tkASC:
      ASC_Get_Registers;
    tkSTP:
      STP_Get_Registers;
    tkPSC:
      PSC_Get_Registers;
    tkFTC:
      FTC_Get_Registers;
    tkPT1:
      PT1_Get_Registers;
    tkPT2:
      PT2_Get_Registers;
    tkSQT:
      SQT_Get_Registers;
    tkGTR:
      GTR_Get_Registers;
    tkPSM:
      PSM_Get_Registers;
  end;
end;

procedure TZXTrackerEngine.Reset;
var
  i: Integer;
  b: Byte;
begin
  RAM.Load(FInitial);
  PlParams := Default(TTrackerState);
  RegisterAY := Default(TTrackerAY);
  FTick := 0;
  FLooped := False;
  FEnvelopeShape := 0;
  for var Channel := 0 to 2 do
    FToneRestart[Channel] := False;
  case FKind of
    tkGTR:
      begin

        with PlParams.GTR, RAM do
        begin
          CurrentPosition := U8(0);
          DelayCounter := U8(1);
          PlParams.GTR_A.Address_In_Pattern := U16(Header.GTR_PatternsPointers[
              Header.GTR_Positions[0] div 6].PatternA);
          PlParams.GTR_B.Address_In_Pattern := U16(Header.GTR_PatternsPointers[
              Header.GTR_Positions[0] div 6].PatternB);
          PlParams.GTR_C.Address_In_Pattern := U16(Header.GTR_PatternsPointers[
              Header.GTR_Positions[0] div 6].PatternC);
        end;

        with PlParams.GTR_A do
        begin
          Envelope_Enabled := False;
          SamplePointer := U16(65536 - 4);
          Position_In_Sample := U8(0);
          Loop_Sample_Position := U8(0);
          Sample_Length := U8(4);
          OrnamentPointer := U16(65536 - 4);
          Position_In_Ornament := U8(0);
          Loop_Ornament_Position := U8(0);
          Ornament_Length := U8(1);

          Note_Skip_Counter := S8(0);
          Enabled := True;
          Ton := U16(0);
          Volume := U8(0)
        end;

        with PlParams.GTR_B do
        begin
          Envelope_Enabled := False;
          SamplePointer := U16(65536 - 4);
          Position_In_Sample := U8(0);
          Loop_Sample_Position := U8(0);
          Sample_Length := U8(4);
          OrnamentPointer := U16(65536 - 4);
          Position_In_Ornament := U8(0);
          Loop_Ornament_Position := U8(0);
          Ornament_Length := U8(1);

          Note_Skip_Counter := S8(0);
          Enabled := True;
          Ton := U16(0);
          Volume := U8(0)
        end;

        with PlParams.GTR_C do
        begin
          Envelope_Enabled := False;
          SamplePointer := U16(65536 - 4);
          Position_In_Sample := U8(0);
          Loop_Sample_Position := U8(0);
          Sample_Length := U8(4);
          OrnamentPointer := U16(65536 - 4);
          Position_In_Ornament := U8(0);
          Loop_Ornament_Position := U8(0);
          Ornament_Length := U8(1);

          Note_Skip_Counter := S8(0);
          Enabled := True;
          Ton := U16(0);
          Volume := U8(0)
        end;
      end;
    tkSTC:
      begin
        with PlParams.STC, RAM do
        begin
          CurrentPosition := U8(0);
          Transposition := U8(Index[Header.ST_PositionsPointer + 2]);
          DelayCounter := U8(1);
        end;

        with RAM do
        begin
          i := 0;
          while Index[Header.ST_PatternsPointer + 7 * i] <>
            Index[Header.ST_PositionsPointer + 1] do
            inc(i);
          PlParams.STC_A.Address_In_Pattern :=
            U16(READ16(Header.ST_PatternsPointer + 7 * i + 1));
          PlParams.STC_B.Address_In_Pattern :=
            U16(READ16(Header.ST_PatternsPointer + 7 * i + 3));
          PlParams.STC_C.Address_In_Pattern :=
            U16(READ16(Header.ST_PatternsPointer + 7 * i + 5));
        end;

        with PlParams.STC_A do
        begin
          Note_Skip_Counter := S8(0);
          Envelope_Enabled := False;
          Number_Of_Notes_To_Skip := U8(0);
          Sample_Tik_Counter := S8(-1);
          Position_In_Sample := U8(0);
          OrnamentPointer := U16(RAM.Header.ST_OrnamentsPointer + 1);
          Ton := U16(0)
        end;

        with PlParams.STC_B do
        begin
          Note_Skip_Counter := S8(0);
          Envelope_Enabled := False;
          Number_Of_Notes_To_Skip := U8(0);
          Sample_Tik_Counter := S8(-1);
          Position_In_Sample := U8(0);
          OrnamentPointer := U16(RAM.Header.ST_OrnamentsPointer + 1);
          Ton := U16(0)
        end;

        with PlParams.STC_C do
        begin
          Note_Skip_Counter := S8(0);
          Envelope_Enabled := False;
          Number_Of_Notes_To_Skip := U8(0);
          Sample_Tik_Counter := S8(-1);
          Position_In_Sample := U8(0);
          OrnamentPointer := U16(RAM.Header.ST_OrnamentsPointer + 1);
          Ton := U16(0)
        end
      end;
    tkASC:
      begin

        with PlParams.ASC_A do
        begin
          Note := U8(0);
          Initial_Noise := U8(0);
          Current_Noise := U8(0);
          Sample_Finished := False;
          Sound_Enabled := False;
          Break_Sample_Loop := False;
          Envelope_Enabled := False;
          Number_Of_Notes_To_Skip := U8(0);
          Addition_To_Amplitude := S8(0);
          Note_Skip_Counter := S8(0);
          Initial_Point_In_Sample := U16(0);
          Initial_Point_In_Ornament := U16(0);
          Point_In_Ornament := U16(0);
          Loop_Point_In_Ornament := U16(0);
          Substruction_for_Ton_Sliding := S16(0);
          Volume := U8(0);
          Point_In_Sample := U16(0);
          Ton_Deviation := U16(0);
          Loop_Point_In_Sample := U16(0);
          Ton_Sliding_Counter := U8(0);
          Amplitude_Delay_Counter := U8(0);
          Amplitude_Delay := U8(0);
          Addition_To_Note := U8(0);
          Current_Ton_Sliding := S16(0);
          Ton := U16(0)
        end;

        with PlParams.ASC_B do
        begin
          Note := U8(0);
          Initial_Noise := U8(0);
          Current_Noise := U8(0);
          Sample_Finished := False;
          Sound_Enabled := False;
          Break_Sample_Loop := False;
          Envelope_Enabled := False;
          Number_Of_Notes_To_Skip := U8(0);
          Addition_To_Amplitude := S8(0);
          Note_Skip_Counter := S8(0);
          Initial_Point_In_Sample := U16(0);
          Initial_Point_In_Ornament := U16(0);
          Point_In_Ornament := U16(0);
          Loop_Point_In_Ornament := U16(0);
          Substruction_for_Ton_Sliding := S16(0);
          Volume := U8(0);
          Point_In_Sample := U16(0);
          Ton_Deviation := U16(0);
          Loop_Point_In_Sample := U16(0);
          Ton_Sliding_Counter := U8(0);
          Amplitude_Delay_Counter := U8(0);
          Amplitude_Delay := U8(0);
          Addition_To_Note := U8(0);
          Current_Ton_Sliding := S16(0);
          Ton := U16(0)
        end;

        with PlParams.ASC_C do
        begin
          Note := U8(0);
          Initial_Noise := U8(0);
          Current_Noise := U8(0);
          Sample_Finished := False;
          Sound_Enabled := False;
          Break_Sample_Loop := False;
          Envelope_Enabled := False;
          Number_Of_Notes_To_Skip := U8(0);
          Addition_To_Amplitude := S8(0);
          Note_Skip_Counter := S8(0);
          Initial_Point_In_Sample := U16(0);
          Initial_Point_In_Ornament := U16(0);
          Point_In_Ornament := U16(0);
          Loop_Point_In_Ornament := U16(0);
          Substruction_for_Ton_Sliding := S16(0);
          Volume := U8(0);
          Point_In_Sample := U16(0);
          Ton_Deviation := U16(0);
          Loop_Point_In_Sample := U16(0);
          Ton_Sliding_Counter := U8(0);
          Amplitude_Delay_Counter := U8(0);
          Amplitude_Delay := U8(0);
          Addition_To_Note := U8(0);
          Current_Ton_Sliding := S16(0);
          Ton := U16(0)
        end;

        with PlParams.ASC, RAM do
        begin
          CurrentPosition := U8(0);
          DelayCounter := U8(1);
          Delay := U8(Header.ASC1_Delay);
          PlParams.ASC_A.Address_In_Pattern :=
            U16(READ16(Header.ASC1_PatternsPointers + 6 * Index[9]) +
            Header.ASC1_PatternsPointers);
          PlParams.ASC_B.Address_In_Pattern :=
            U16(READ16(Header.ASC1_PatternsPointers + 6 * Index[9] + 2) +
            Header.ASC1_PatternsPointers);
          PlParams.ASC_C.Address_In_Pattern :=
            U16(READ16(Header.ASC1_PatternsPointers + 6 * Index[9] + 4) +
            Header.ASC1_PatternsPointers)
        end
      end;
    tkFTC:
      begin
        with PlParams.FTC, RAM do
        begin
          Delay := U8(Header.FTC_Delay);
          DelayCounter := U8(1);
          CurrentPosition := U8(0);
          Transposition := U8(Header.FTC_Positions[0].Transposition);
          PlParams.FTC_A.Address_In_Pattern :=
            U16(READ16(Header.FTC_PatternsPointer + Header.FTC_Positions[0].Pattern * 6));
          PlParams.FTC_B.Address_In_Pattern :=
            U16(READ16(Header.FTC_PatternsPointer + Header.FTC_Positions[0].Pattern * 6 + 2));
          PlParams.FTC_C.Address_In_Pattern :=
            U16(READ16(Header.FTC_PatternsPointer + Header.FTC_Positions[0].Pattern * 6 + 4));
        end;

        with PlParams.FTC_A do
        begin
          OrnamentPointer := U16(RAM.Header.FTC_OrnamentsPointers[0]);
          SamplePointer := U16($52);
          Note_Skip_Counter := S8(0);
          Loop_Ornament_Position := U8(0);
          Position_In_Ornament := U8(0);
          Ornament_Length := U8(1);
          Noise := U8(0);
          Noise_Accumulator := U8(0);
          Note_Accumulator := U8(0);
          Ton_Slide_Step1 := S16(0);
          Sample_Enabled := False;
          Envelope_Enabled := False;
          Volume := U8(15);
          Ton := U16(0)
        end;

        with PlParams.FTC_B do
        begin
          OrnamentPointer := U16(PlParams.FTC_A.OrnamentPointer);
          SamplePointer := U16($52);
          Note_Skip_Counter := S8(0);
          Loop_Ornament_Position := U8(0);
          Position_In_Ornament := U8(0);
          Ornament_Length := U8(1);
          Noise := U8(0);
          Noise_Accumulator := U8(0);
          Note_Accumulator := U8(0);
          Ton_Slide_Step1 := S16(0);
          Sample_Enabled := False;
          Envelope_Enabled := False;
          Volume := U8(15);
          Ton := U16(0)
        end;

        with PlParams.FTC_C do
        begin
          OrnamentPointer := U16(PlParams.FTC_A.OrnamentPointer);
          SamplePointer := U16($52);
          Note_Skip_Counter := S8(0);
          Loop_Ornament_Position := U8(0);
          Position_In_Ornament := U8(0);
          Ornament_Length := U8(1);
          Noise := U8(0);
          Noise_Accumulator := U8(0);
          Note_Accumulator := U8(0);
          Ton_Slide_Step1 := S16(0);
          Sample_Enabled := False;
          Envelope_Enabled := False;
          Volume := U8(15);
          Ton := U16(0)
        end
      end;
    tkSTP:
      begin

        with PlParams.STP, RAM do
        begin
          DelayCounter := U8(1);
          Transposition := U8(Index[Header.STP_PositionsPointer + 3]);
          CurrentPosition := U8(0);
          PlParams.STP_A.Address_In_Pattern :=
            U16(READ16(Header.STP_PatternsPointer + Index[Header.STP_PositionsPointer + 2]));
          PlParams.STP_B.Address_In_Pattern :=
            U16(READ16(Header.STP_PatternsPointer + Index[Header.STP_PositionsPointer + 2] + 2));
          PlParams.STP_C.Address_In_Pattern :=
            U16(READ16(Header.STP_PatternsPointer + Index[Header.STP_PositionsPointer + 2] + 4));
        end;

        with PlParams.STP_A, RAM do
        begin
          SamplePointer := U16(READ16(Header.STP_SamplesPointer));
          Loop_Sample_Position := U8(Index[SamplePointer]);
          IncU16(SamplePointer);
          Sample_Length := U8(Index[SamplePointer]);
          IncU16(SamplePointer);
          PlParams.STP_B.SamplePointer := U16(SamplePointer);
          PlParams.STP_B.Loop_Sample_Position := U8(Loop_Sample_Position);
          PlParams.STP_B.Sample_Length := U8(Sample_Length);
          PlParams.STP_C.SamplePointer := U16(SamplePointer);
          PlParams.STP_C.Loop_Sample_Position := U8(Loop_Sample_Position);
          PlParams.STP_C.Sample_Length := U8(Sample_Length);

          OrnamentPointer := U16(READ16(Header.STP_OrnamentsPointer));
          Loop_Ornament_Position := U8(Index[OrnamentPointer]);
          IncU16(OrnamentPointer);
          Ornament_Length := U8(Index[OrnamentPointer]);
          IncU16(OrnamentPointer);
          PlParams.STP_B.OrnamentPointer := U16(OrnamentPointer);
          PlParams.STP_B.Loop_Ornament_Position := U8(Loop_Ornament_Position);
          PlParams.STP_B.Ornament_Length := U8(Ornament_Length);
          PlParams.STP_C.OrnamentPointer := U16(OrnamentPointer);
          PlParams.STP_C.Loop_Ornament_Position := U8(Loop_Ornament_Position);
          PlParams.STP_C.Ornament_Length := U8(Ornament_Length);

          Envelope_Enabled := False;
          Glissade := S8(0);
          Current_Ton_Sliding := S16(0);
          Enabled := False;
          Number_Of_Notes_To_Skip := U8(0);
          Note_Skip_Counter := S8(0);
          Volume := U8(0);
          Ton := U16(0)
        end;

        with PlParams.STP_B do
        begin
          Envelope_Enabled := False;
          Glissade := S8(0);
          Current_Ton_Sliding := S16(0);
          Enabled := False;
          Number_Of_Notes_To_Skip := U8(0);
          Note_Skip_Counter := S8(0);
          Volume := U8(0);
          Ton := U16(0)
        end;

        with PlParams.STP_C do
        begin
          Envelope_Enabled := False;
          Glissade := S8(0);
          Current_Ton_Sliding := S16(0);
          Enabled := False;
          Number_Of_Notes_To_Skip := U8(0);
          Note_Skip_Counter := S8(0);
          Volume := U8(0);
          Ton := U16(0)
        end
      end;
    tkPSC:
      begin

        with PlParams.PSC, RAM do
        begin
          DelayCounter := U16(1);
          Delay := U16(Header.PSC_Delay);
          Positions_Pointer := U16(Header.PSC_PatternsPointer);
          Lines_Counter := U16(1);
          Noise_Base := U16(0)
        end;

        with PlParams.PSC_A, RAM do
        begin
          SamplePointer := U16(Header.PSC_SamplesPointers[0] + Ord(FVersion > 3) * $4c);
          PlParams.PSC_B.SamplePointer := U16(SamplePointer);
          PlParams.PSC_C.SamplePointer := U16(SamplePointer);
          OrnamentPointer := U16(READ16(Header.PSC_OrnamentsPointer) + Ord(FVersion > 3) * Header.PSC_OrnamentsPointer);
          PlParams.PSC_B.OrnamentPointer := U16(OrnamentPointer);
          PlParams.PSC_C.OrnamentPointer := U16(OrnamentPointer);

          Break_Ornament_Loop := False;
          Ornament_Enabled := False;
          Enabled := False;
          Break_Sample_Loop := False;
          Ton_Slide_Enabled := False;
          Note_Skip_Counter := S8(1);
          Ton := U16(0)
        end;

        with PlParams.PSC_B do
        begin
          Break_Ornament_Loop := False;
          Ornament_Enabled := False;
          Enabled := False;
          Break_Sample_Loop := False;
          Ton_Slide_Enabled := False;
          Note_Skip_Counter := S8(1);
          Ton := U16(0)
        end;

        with PlParams.PSC_C do
        begin
          Break_Ornament_Loop := False;
          Ornament_Enabled := False;
          Enabled := False;
          Break_Sample_Loop := False;
          Ton_Slide_Enabled := False;
          Note_Skip_Counter := S8(1);
          Ton := U16(0)
        end
      end;
    tkPT1:
      begin
        with PlParams.PT1, RAM do
        begin
          DelayCounter := U8(1);
          Delay := U8(Header.PT1_Delay);
          CurrentPosition := U8(0);
          PlParams.PT1_A.Address_In_Pattern := U16(READ16(Header.PT1_PatternsPointer +
              Header.PT1_PositionList[0] * 6));
          PlParams.PT1_B.Address_In_Pattern := U16(READ16(Header.PT1_PatternsPointer +
              Header.PT1_PositionList[0] * 6 + 2));
          PlParams.PT1_C.Address_In_Pattern := U16(READ16(Header.PT1_PatternsPointer +
              Header.PT1_PositionList[0] * 6 + 4))
        end;

        with PlParams.PT1_A do
        begin
          OrnamentPointer := U16(RAM.Header.PT1_OrnamentsPointers[0]);
          Envelope_Enabled := False;
          Position_In_Sample := U8(0);
          Enabled := False;
          Number_Of_Notes_To_Skip := U8(0);
          Note_Skip_Counter := S8(0);
          Volume := U8(15);
          Ton := U16(0)
        end;

        with PlParams.PT1_B do
        begin
          OrnamentPointer := U16(PlParams.PT1_A.OrnamentPointer);
          Envelope_Enabled := False;
          Position_In_Sample := U8(0);
          Enabled := False;
          Number_Of_Notes_To_Skip := U8(0);
          Note_Skip_Counter := S8(0);
          Volume := U8(15);
          Ton := U16(0)
        end;

        with PlParams.PT1_C do
        begin
          OrnamentPointer := U16(PlParams.PT1_A.OrnamentPointer);
          Envelope_Enabled := False;
          Position_In_Sample := U8(0);
          Enabled := False;
          Number_Of_Notes_To_Skip := U8(0);
          Note_Skip_Counter := S8(0);
          Volume := U8(15);
          Ton := U16(0)
        end;
      end;
    tkPT2:
      begin
        with PlParams.PT2, RAM do
        begin
          DelayCounter := U8(1);
          Delay := U8(Header.PT2_Delay);
          CurrentPosition := U8(0);
        end;

        with RAM do
        begin
          PlParams.PT2_A.Address_In_Pattern :=
            U16(READ16(Header.PT2_PatternsPointer +
              Header.PT2_PositionList[0] * 6));
          PlParams.PT2_B.Address_In_Pattern :=
            U16(READ16(Header.PT2_PatternsPointer +
              Header.PT2_PositionList[0] * 6 + 2));
          PlParams.PT2_C.Address_In_Pattern :=
            U16(READ16(Header.PT2_PatternsPointer +
              Header.PT2_PositionList[0] * 6 + 4));
        end;

        with PlParams.PT2_A, RAM do
        begin
          OrnamentPointer := U16(Header.PT2_OrnamentsPointers[0]);
          Ornament_Length := U8(Index[OrnamentPointer]);
          IncU16(OrnamentPointer);
          Loop_Ornament_Position := U8(Index[OrnamentPointer]);
          IncU16(OrnamentPointer);
          Envelope_Enabled := False;
          Position_In_Sample := U8(0);
          Position_In_Ornament := U8(0);
          Addition_To_Noise := S8(0);
          Glissade := S8(0);
          Current_Ton_Sliding := S16(0);
          GlissType := 0;
          Enabled := False;
          Number_Of_Notes_To_Skip := U8(0);
          Note_Skip_Counter := S8(0);
          Volume := U8(15);
          Ton := U16(0)
        end;

        with PlParams.PT2_B do
        begin
          OrnamentPointer := U16(PlParams.PT2_A.OrnamentPointer);
          Loop_Ornament_Position := U8(PlParams.PT2_A.Loop_Ornament_Position);
          Ornament_Length := U8(PlParams.PT2_A.Ornament_Length);
          Envelope_Enabled := False;
          Position_In_Sample := U8(0);
          Position_In_Ornament := U8(0);
          Addition_To_Noise := S8(0);
          Glissade := S8(0);
          Current_Ton_Sliding := S16(0);
          GlissType := 0;
          Enabled := False;
          Number_Of_Notes_To_Skip := U8(0);
          Note_Skip_Counter := S8(0);
          Volume := U8(15);
          Ton := U16(0)
        end;

        with PlParams.PT2_C do
        begin
          OrnamentPointer := U16(PlParams.PT2_A.OrnamentPointer);
          Loop_Ornament_Position := U8(PlParams.PT2_A.Loop_Ornament_Position);
          Ornament_Length := U8(PlParams.PT2_A.Ornament_Length);
          Envelope_Enabled := False;
          Position_In_Sample := U8(0);
          Position_In_Ornament := U8(0);
          Addition_To_Noise := S8(0);
          Glissade := S8(0);
          Current_Ton_Sliding := S16(0);
          GlissType := 0;
          Enabled := False;
          Number_Of_Notes_To_Skip := U8(0);
          Note_Skip_Counter := S8(0);
          Volume := U8(15);
          Ton := U16(0)
        end
      end;
    tkSQT:
      begin
        with PlParams.SQT_A do
        begin
          Ton := U16(0);
          Envelope_Enabled := False;
          Ornament_Enabled := False;
          Gliss := False;
          Enabled := False
        end;
        with PlParams.SQT_B do
        begin
          Ton := U16(0);
          Envelope_Enabled := False;
          Ornament_Enabled := False;
          Gliss := False;
          Enabled := False
        end;
        with PlParams.SQT_C do
        begin
          Ton := U16(0);
          Envelope_Enabled := False;
          Ornament_Enabled := False;
          Gliss := False;
          Enabled := False
        end;

        with PlParams.SQT do
        begin
          DelayCounter := U8(1);
          Delay := U8(1);
          Lines_Counter := U8(1);
          Positions_Pointer := U16(RAM.Header.SQT_PositionsPointer)
        end
      end;
    tkPSM:
      begin
        with PlParams.PSM do
        begin
          CurrentPosition := U8(0);
          Finished := False;
          b := U8(RAM.Index[RAM.Header.PSM_PositionsPointer]);
          Transposition := S8(RAM.Index[RAM.Header.PSM_PositionsPointer + 1] + 48);
          Delay := U8(RAM.Index[RAM.Header.PSM_PatternsPointer + b * 7]);
          PlParams.PSM_A.Address_In_Pattern :=
            U16(READ16(RAM.Header.PSM_PatternsPointer + b * 7 + 1));
          PlParams.PSM_B.Address_In_Pattern :=
            U16(READ16(RAM.Header.PSM_PatternsPointer + b * 7 + 3));
          PlParams.PSM_C.Address_In_Pattern :=
            U16(READ16(RAM.Header.PSM_PatternsPointer + b * 7 + 5));
          PlParams.PSM_A.RetCnt := U8(0);
          PlParams.PSM_B.RetCnt := U8(0);
          PlParams.PSM_C.RetCnt := U8(0);
          PlParams.PSM_A.Note_Skip_Counter := U8(1);
          PlParams.PSM_B.Note_Skip_Counter := U8(1);
          PlParams.PSM_C.Note_Skip_Counter := U8(1);
          PlParams.PSM_A.Note := S8(-128);
          PlParams.PSM_B.Note := S8(-128);
          PlParams.PSM_C.Note := S8(-128);
          DelayCounter := U8(1)
        end;
      end;
  end;
end;

procedure TZXTrackerEngine.STC_Get_Registers;
var
  TempMixer: byte;

  procedure PatternInterpreter(var Chan: STC_Channel_Parameters);
  var
    k: word;
  begin
    with Chan, RAM do
    begin
      repeat
        case Index[Address_In_Pattern] of
          0..$5f:
            begin
              Note := U8(Index[Address_In_Pattern]);
              Sample_Tik_Counter := S8(32);
              Position_In_Sample := U8(0);
              IncU16(Address_In_Pattern);
              break;
            end;
          $60..$6f:
            begin
              k := U16(0);
              while Index[$1b + $63 * k] <> (Index[Address_In_Pattern] - $60) do
                IncU16(k);
              SamplePointer := U16($1c + $63 * k);
            end;
          $70..$7f:
            begin
              k := U16(0);
              while Index[Header.ST_OrnamentsPointer + $21 * k] <>
                (Index[Address_In_Pattern] - $70) do
                IncU16(k);
              OrnamentPointer := U16(Header.ST_OrnamentsPointer + $21 * k + 1);
              Envelope_Enabled := False;
            end;
          $80:
            begin
              Sample_Tik_Counter := S8(-1);
              IncU16(Address_In_Pattern);
              break;
            end;
          $81:
            begin
              IncU16(Address_In_Pattern);
              break;
            end;
          $82:
            begin
              k := U16(0);
              while Index[Header.ST_OrnamentsPointer + $21 * k] <> 0 do
                IncU16(k);
              OrnamentPointer := U16(Header.ST_OrnamentsPointer + $21 * k + 1);
              Envelope_Enabled := False;
            end;
          $83..$8e:
            begin
              SetEnvelopeRegister(Index[Address_In_Pattern] - $80);
              IncU16(Address_In_Pattern);
              RegisterAY.Index[11] := U8(Index[Address_In_Pattern]);
              Envelope_Enabled := True;
              k := U16(0);
              while Index[Header.ST_OrnamentsPointer + $21 * k] <> 0 do
                IncU16(k);
              OrnamentPointer := U16(Header.ST_OrnamentsPointer + $21 * k + 1);
            end
        else
          Number_Of_Notes_To_Skip := U8(Index[Address_In_Pattern] - $a1);
        end;
        IncU16(Address_In_Pattern)
      until False;
      Note_Skip_Counter := S8(Number_Of_Notes_To_Skip);
    end;
  end;

  procedure GetRegisters(var Chan: STC_Channel_Parameters);
  var
    i: word;
    j: byte;
  begin
    with Chan, RAM do
    begin
      if Sample_Tik_Counter >= 0 then
      begin
        DecS8(Sample_Tik_Counter);
        Position_In_Sample := U8((Position_In_Sample + 1) and $1f);
        if Sample_Tik_Counter = 0 then
          if Index[SamplePointer + $60] <> 0 then
          begin
            Position_In_Sample := U8(Index[SamplePointer + $60] and $1f);
            Sample_Tik_Counter := S8(Index[SamplePointer + $61] + 1);
          end
          else
            Sample_Tik_Counter := S8(-1);
      end;
      if Sample_Tik_Counter >= 0 then
      begin
        i := U16(((Position_In_Sample - 1) and $1f) * 3 + SamplePointer);
        if Index[i + 1] and $80 <> 0 then
          TempMixer := U8(TempMixer or 64)
        else
          RegisterAY.Noise := U8(Index[i + 1] and $1f);
        if Index[i + 1] and $40 <> 0 then
          TempMixer := U8(TempMixer or 8);
        Amplitude := U8(Index[i] and 15);
        j := U8(Note + Index[OrnamentPointer + (Position_In_Sample - 1) and $1f] +
          PlParams.STC.Transposition);
        if j > 95 then
          j := U8(95);
        if Index[i + 1] and $20 <> 0 then
          Ton := U16((ST_Table[j] + Index[i + 2] + U16(Index[i] and $f0) shl
            4) and $FFF)
        else
          Ton := U16((ST_Table[j] - Index[i + 2] - U16(Index[i] and $f0) shl
            4) and $FFF);
        if Envelope_Enabled then
          Amplitude := U8(Amplitude or 16);
      end
      else
        Amplitude := U8(0);
    end;
    TempMixer := U8(TempMixer shr 1);
  end;

var
  i: word;
begin

  with PlParams.STC do
  begin
    DecU8(DelayCounter);
    if DelayCounter = 0 then
      with RAM do
      begin
        DelayCounter := U8(Header.ST_delay);
        with PlParams.STC_A do
        begin
          DecS8(Note_Skip_Counter);
          if Note_Skip_Counter < 0 then
          begin
            if Index[Address_In_Pattern] = 255 then
            begin
              if CurrentPosition = Index[Header.ST_PositionsPointer] then
                CurrentPosition := U8(MarkLoop(0))
              else
                IncU8(CurrentPosition);
              Transposition := U8(Index[Header.ST_PositionsPointer + 2 +
                  CurrentPosition * 2]);
              i := U16(0);
              while Index[Header.ST_PatternsPointer + 7 * i] <>
                Index[Header.ST_PositionsPointer + 1 + CurrentPosition * 2] do
                IncU16(i);
              Address_In_Pattern :=
                U16(READ16(Header.ST_PatternsPointer + 7 * i + 1));
              PlParams.STC_B.Address_In_Pattern :=
                U16(READ16(Header.ST_PatternsPointer + 7 * i + 3));
              PlParams.STC_C.Address_In_Pattern :=
                U16(READ16(Header.ST_PatternsPointer + 7 * i + 5));
            end;
            PatternInterpreter(PlParams.STC_A);
          end;
        end;
        with PlParams.STC_B do
        begin
          DecS8(Note_Skip_Counter);
          if Note_Skip_Counter < 0 then
            PatternInterpreter(PlParams.STC_B);
        end;
        with PlParams.STC_C do
        begin
          DecS8(Note_Skip_Counter);
          if Note_Skip_Counter < 0 then
            PatternInterpreter(PlParams.STC_C);
        end;
      end;
  end;

  TempMixer := U8(0);
  GetRegisters(PlParams.STC_A);
  GetRegisters(PlParams.STC_B);
  GetRegisters(PlParams.STC_C);

  SetMixerRegister(TempMixer);

  RegisterAY.TonA := U16(PlParams.STC_A.Ton);
  RegisterAY.TonB := U16(PlParams.STC_B.Ton);
  RegisterAY.TonC := U16(PlParams.STC_C.Ton);

  SetAmplA(PlParams.STC_A.Amplitude);
  SetAmplB(PlParams.STC_B.Amplitude);
  SetAmplC(PlParams.STC_C.Amplitude);

  Inc(FTick);
end;

procedure TZXTrackerEngine.ASC_Get_Registers;
var
  TempMixer: byte;

  procedure PatternInterpreter(var Chan: ASC_Channel_Parameters);
  var
    delta_ton: smallint;
    Initialization_Of_Ornament_Disabled, Initialization_Of_Sample_Disabled: boolean;
  begin
    Initialization_Of_Sample_Disabled := False;
    Initialization_Of_Ornament_Disabled := False;
    with Chan do
    begin
      Ton_Sliding_Counter := U8(0);
      Amplitude_Delay_Counter := U8(0);
      repeat
        with RAM do
          case Index[Address_In_Pattern] of
            0..$55:
              begin
                Note := U8(Index[Address_In_Pattern]);
                IncU16(Address_In_Pattern);
                Current_Noise := U8(Initial_Noise);
                if S8(Ton_Sliding_Counter) <= 0 then
                  Current_Ton_Sliding := S16(0);
                if not Initialization_Of_Sample_Disabled then
                begin
                  Addition_To_Amplitude := S8(0);
                  Ton_Deviation := U16(0);
                  Point_In_Sample := U16(Initial_Point_In_Sample);
                  Sound_Enabled := True;
                  Sample_Finished := False;
                  Break_Sample_Loop := False;
                end;
                if not Initialization_Of_Ornament_Disabled then
                begin
                  Point_In_Ornament := U16(Initial_Point_In_Ornament);
                  Addition_To_Note := U8(0);
                end;
                if Envelope_Enabled then
                begin
                  RegisterAY.Index[11] := U8(Index[Chan.Address_In_Pattern]);
                  IncU16(Address_In_Pattern);
                end;
                break;
              end;
            $56..$5d:
              begin
                IncU16(Address_In_Pattern);
                break;
              end;
            $5e:
              begin
                Break_Sample_Loop := True;
                IncU16(Address_In_Pattern);
                break;
              end;
            $5f:
              begin
                Sound_Enabled := False;
                IncU16(Address_In_Pattern);
                break;
              end;
            $60..$9f:
              Number_Of_Notes_To_Skip := U8(Index[Address_In_Pattern] - $60);
            $a0..$bf:
              Initial_Point_In_Sample :=
                U16(READ16((Index[Address_In_Pattern] - $a0) * 2 +
                  Header.ASC1_SamplesPointers) + Header.ASC1_SamplesPointers);
            $c0..$df:
              Initial_Point_In_Ornament :=
                U16(READ16((Index[Address_In_Pattern] - $c0) * 2 +
                  Header.ASC1_OrnamentsPointers) + Header.ASC1_OrnamentsPointers);
            $e0:
              begin
                Volume := U8(15);
                Envelope_Enabled := True;
              end;
            $e1..$ef:
              begin
                Volume := U8(Index[Address_In_Pattern] - $e0);
                Envelope_Enabled := False;
              end;
            $f0:
              begin
                IncU16(Address_In_Pattern);
                Initial_Noise := U8(Index[Address_In_Pattern]);
              end;
            $f1:
              Initialization_Of_Sample_Disabled := True;
            $f2:
              Initialization_Of_Ornament_Disabled := True;
            $f3:
              begin
                Initialization_Of_Sample_Disabled := True;
                Initialization_Of_Ornament_Disabled := True;
              end;
            $f4:
              begin
                IncU16(Address_In_Pattern);
                PlParams.ASC.Delay := U8(Index[Address_In_Pattern]);
              end;
            $f5:
              begin
                IncU16(Address_In_Pattern);
                Substruction_for_Ton_Sliding :=
                  S16(-S8(Index[Address_In_Pattern]) * 16);
                Ton_Sliding_Counter := U8(255);
              end;
            $f6:
              begin
                IncU16(Address_In_Pattern);
                Substruction_for_Ton_Sliding :=
                  S16(S8(Index[Chan.Address_In_Pattern]) * 16);
                Chan.Ton_Sliding_Counter := U8(255);
              end;
            $f7:
              begin
                IncU16(Address_In_Pattern);
                Initialization_Of_Sample_Disabled := True;
                if Index[Address_In_Pattern + 1] < $56 then
                  delta_ton := S16(ASM_Table[Note] + Current_Ton_Sliding div
                    16 - ASM_Table[Index[Address_In_Pattern + 1]])
                else
                  delta_ton := S16(Current_Ton_Sliding div 16);
                delta_ton := S16(delta_ton shl 4);
                Substruction_for_Ton_Sliding :=
                  S16(-delta_ton div S8(Index[Address_In_Pattern]));
                Current_Ton_Sliding :=
                  S16(delta_ton - delta_ton mod S8(Index[Address_In_Pattern]));
                Ton_Sliding_Counter :=
                  U8(S8(Index[Address_In_Pattern]));
              end;
            $f8:
              SetEnvelopeRegister(8);
            $f9:
              begin
                IncU16(Address_In_Pattern);
                if Index[Address_In_Pattern + 1] < $56 then
                  delta_ton := S16(ASM_Table[Note] -
                    ASM_Table[Index[Address_In_Pattern + 1]])
                else
                  delta_ton := S16(Current_Ton_Sliding div 16);
                delta_ton := S16(delta_ton shl 4);
                Substruction_for_Ton_Sliding :=
                  S16(-delta_ton div S8(Index[Address_In_Pattern]));
                Current_Ton_Sliding :=
                  S16(delta_ton - delta_ton mod S8(Index[Address_In_Pattern]));
                Ton_Sliding_Counter :=
                  U8(S8(Index[Address_In_Pattern]));
              end;
            $fa:
              SetEnvelopeRegister(10);
            $fb:
              begin
                IncU16(Chan.Address_In_Pattern);
                if Index[Chan.Address_In_Pattern] and 32 = 0 then
                begin
                  Amplitude_Delay := U8(Index[Address_In_Pattern] shl 3);
                  Amplitude_Delay_Counter := U8(Amplitude_Delay);
                end
                else
                begin
                  Amplitude_Delay :=
                    U8(((Index[Address_In_Pattern] shl 3) xor $f8) + 9);

                  Amplitude_Delay_Counter := U8(Chan.Amplitude_Delay);
                end;
              end;
            $fc:
              SetEnvelopeRegister(12);
            $fe:
              SetEnvelopeRegister(14);
          end;
        IncU16(Address_In_Pattern);
      until False;
      Note_Skip_Counter := S8(Number_Of_Notes_To_Skip);
    end;
  end;

  procedure GetRegisters(var Chan: ASC_Channel_Parameters);
  var
    j: shortint;
    Sample_Says_OK_for_Envelope: boolean;
  begin
    with Chan, RAM do
    begin
      if Sample_Finished or not Sound_Enabled then
        Amplitude := U8(0)
      else
      begin
        if Amplitude_Delay_Counter <> 0 then
          if Amplitude_Delay_Counter >= 16 then
          begin
            DecU8(Amplitude_Delay_Counter, 8);
            if Addition_To_Amplitude < -15 then
              IncS8(Addition_To_Amplitude)
            else if Addition_To_Amplitude > 15 then
              DecS8(Addition_To_Amplitude);
          end
          else
          begin
            if (Amplitude_Delay_Counter and 1 <> 0) then
            begin
              if Addition_To_Amplitude > -15 then
                DecS8(Addition_To_Amplitude);
            end
            else if Addition_To_Amplitude < 15 then
              IncS8(Addition_To_Amplitude);
            Amplitude_Delay_Counter := U8(Amplitude_Delay);
          end;
        if Index[Point_In_Sample] and 128 <> 0 then
          Loop_Point_In_Sample := U16(Point_In_Sample);
        if Index[Point_In_Sample] and 96 = 32 then
          Sample_Finished := True;
        IncU16(Ton_Deviation, S8(Index[Point_In_Sample + 1]));
        TempMixer := U8(Index[Point_In_Sample + 2] and 9 shl 3 or TempMixer);
        if Index[Point_In_Sample + 2] and 6 = 2 then
          Sample_Says_OK_for_Envelope := True
        else
          Sample_Says_OK_for_Envelope := False;
        if Index[Point_In_Sample + 2] and 6 = 4 then
          if Addition_To_Amplitude > -15 then
            DecS8(Addition_To_Amplitude);
        if Index[Point_In_Sample + 2] and 6 = 6 then
          if Addition_To_Amplitude < 15 then
            IncS8(Addition_To_Amplitude);
        Amplitude := U8(U8(Addition_To_Amplitude) + Index[Point_In_Sample + 2] shr 4);
        if S8(Amplitude) < 0 then
          Amplitude := U8(0)
        else if Amplitude > 15 then
          Amplitude := U8(15);
        Amplitude := U8((Amplitude * (Volume + 1)) shr 4);
        if Sample_Says_OK_for_Envelope and (TempMixer and 64 <> 0) then
          IncU8(RegisterAY.Index[11],
            S8(Index[Point_In_Sample] shl 3) div 8)
        else
          IncU8(Current_Noise, S8(Index[Point_In_Sample] shl 3) div 8);
        IncU16(Point_In_Sample, 3);
        if Index[Point_In_Sample - 3] and 64 <> 0 then
          if not Break_Sample_Loop then
            Point_In_Sample := U16(Loop_Point_In_Sample)
          else if Index[Point_In_Sample - 3] and 32 <> 0 then
            Sample_Finished := True;
        if Index[Point_In_Ornament] and 128 <> 0 then
          Loop_Point_In_Ornament := U16(Point_In_Ornament);
        IncU8(Addition_To_Note, Index[1 + Point_In_Ornament]);
        IncU8(Current_Noise,
          (-S8(Index[Point_In_Ornament] and $10)) or
          Index[Point_In_Ornament]);
        IncU16(Point_In_Ornament, 2);
        if Index[Point_In_Ornament - 2] and 64 <> 0 then
          Point_In_Ornament := U16(Loop_Point_In_Ornament);
        if TempMixer and 64 = 0 then
          RegisterAY.Noise :=
            U8((U8(Current_Ton_Sliding shr 8) + Current_Noise) and $1f);
        j := S8(Note + Addition_To_Note);
        if j < 0 then
          j := S8(0)
        else if j > $55 then
          j := S8($55);
        Ton := U16((ASM_Table[j] + Ton_Deviation +
          U16(Current_Ton_Sliding div 16)) and $fff);
        if Ton_Sliding_Counter <> 0 then
        begin
          if S8(Ton_Sliding_Counter) > 0 then
            DecU8(Ton_Sliding_Counter);
          IncS16(Current_Ton_Sliding, Substruction_for_Ton_Sliding);
        end;
        if Envelope_Enabled and Sample_Says_OK_for_Envelope then
          Amplitude := U8(Amplitude or $10);
      end;
    end;
    TempMixer := U8(TempMixer shr 1);
  end;

begin

  with PlParams.ASC do
  begin
    DecU8(DelayCounter);
    if DelayCounter = 0 then
    begin
      with PlParams.ASC_A do
      begin
        DecS8(Note_Skip_Counter);
        if Note_Skip_Counter < 0 then
          with RAM do
          begin
            if Index[Address_In_Pattern] = 255 then
            begin
              IncU8(CurrentPosition);
              if CurrentPosition >= Header.ASC1_Number_Of_Positions then
                CurrentPosition := U8(MarkLoop(Header.ASC1_LoopingPosition));
              Address_In_Pattern :=
                U16(READ16(Header.ASC1_PatternsPointers + 6 *
                  Index[CurrentPosition + 9]) + Header.ASC1_PatternsPointers);
              PlParams.ASC_B.Address_In_Pattern :=
                U16(READ16(Header.ASC1_PatternsPointers + 6 *
                  Index[CurrentPosition + 9] + 2) + Header.ASC1_PatternsPointers);
              PlParams.ASC_C.Address_In_Pattern :=
                U16(READ16(Header.ASC1_PatternsPointers + 6 *
                  Index[CurrentPosition + 9] + 4) + Header.ASC1_PatternsPointers);
              Initial_Noise := U8(0);
              PlParams.ASC_B.Initial_Noise := U8(0);
              PlParams.ASC_C.Initial_Noise := U8(0);
            end;
            PatternInterpreter(PlParams.ASC_A);
          end;
      end;
      with PlParams.ASC_B do
      begin
        DecS8(Note_Skip_Counter);
        if Note_Skip_Counter < 0 then
          PatternInterpreter(PlParams.ASC_B);
      end;
      with PlParams.ASC_C do
      begin
        DecS8(Note_Skip_Counter);
        if Note_Skip_Counter < 0 then
          PatternInterpreter(PlParams.ASC_C);
      end;
      DelayCounter := U8(Delay);
    end;
  end;

  TempMixer := U8(0);
  GetRegisters(PlParams.ASC_A);
  GetRegisters(PlParams.ASC_B);
  GetRegisters(PlParams.ASC_C);

  SetMixerRegister(TempMixer);

  RegisterAY.TonA := U16(PlParams.ASC_A.Ton);
  RegisterAY.TonB := U16(PlParams.ASC_B.Ton);
  RegisterAY.TonC := U16(PlParams.ASC_C.Ton);

  SetAmplA(PlParams.ASC_A.Amplitude);
  SetAmplB(PlParams.ASC_B.Amplitude);
  SetAmplC(PlParams.ASC_C.Amplitude);

  Inc(FTick);
end;

procedure TZXTrackerEngine.STP_Get_Registers;
var
  TempMixer: byte;

  procedure PatternInterpreter(var Chan: STP_Channel_Parameters);
  var
    quit: boolean;
  begin
    quit := False;
    with Chan, RAM do
    begin
      repeat
        case Index[Address_In_Pattern] of
          1..$60:
            begin
              Note := U8(Index[Address_In_Pattern] - 1);
              Position_In_Sample := U8(0);
              Position_In_Ornament := U8(0);
              Current_Ton_Sliding := S16(0);
              Enabled := True;
              quit := True;
            end;
          $61..$6f:
            begin
              SamplePointer := U16(READ16(Header.STP_SamplesPointer +
                  (Index[Address_In_Pattern] - $61) * 2));
              Loop_Sample_Position := U8(Index[SamplePointer]);
              IncU16(SamplePointer);
              Sample_Length := U8(Index[SamplePointer]);
              IncU16(SamplePointer);
            end;
          $70..$7f:
            begin
              OrnamentPointer :=
                U16(READ16(Header.STP_OrnamentsPointer +
                  (Index[Address_In_Pattern] - $70) * 2));
              Loop_Ornament_Position := U8(Index[OrnamentPointer]);
              IncU16(OrnamentPointer);
              Ornament_Length := U8(Index[OrnamentPointer]);
              IncU16(OrnamentPointer);
              Envelope_Enabled := False;
              Glissade := S8(0);
            end;
          $80..$bf:
            Number_Of_Notes_To_Skip := U8(Index[Address_In_Pattern] - $80);
          $c0..$cf:
            begin
              if Index[Address_In_Pattern] <> $c0 then
              begin
                SetEnvelopeRegister(Index[Address_In_Pattern] - $c0);
                IncU16(Address_In_Pattern);
                RegisterAY.Index[11] := U8(Index[Address_In_Pattern]);
              end;
              Envelope_Enabled := True;
              Loop_Ornament_Position := U8(0);
              Glissade := S8(0);
              Ornament_Length := U8(1);
            end;
          $D0..$DF:
            begin
              Enabled := False;
              quit := True;
            end;
          $e0..$ef:
            quit := True;
          $f0:
            begin
              IncU16(Address_In_Pattern);
              Glissade := S8(Index[Address_In_Pattern]);
            end;
          $f1..$ff:
            Volume := U8(Index[Address_In_Pattern] - $f1);
        end;
        IncU16(Address_In_Pattern)
      until quit;
      Note_Skip_Counter := S8(Number_Of_Notes_To_Skip);
    end;
  end;

  procedure GetRegisters(var Chan: STP_Channel_Parameters);
  var
    j, b0, b1: byte;
  begin
    with Chan, RAM do
    begin
      if Enabled then
      begin
        IncS16(Current_Ton_Sliding, Glissade);
        if Envelope_Enabled then
          j := U8(Note + PlParams.STP.Transposition)
        else
          j := U8(Note + PlParams.STP.Transposition +
            Index[OrnamentPointer + Position_In_Ornament]);
        if j > 95 then
          j := U8(95);
        b0 := U8(Index[SamplePointer + Position_In_Sample * 4]);
        b1 := U8(Index[SamplePointer + Position_In_Sample * 4 + 1]);
        Ton := U16((ST_Table[j] + Current_Ton_Sliding +
          READ16(SamplePointer + Position_In_Sample * 4 + 2)) and $fff);
        Amplitude := U8((b0 and 15) - Volume);
        if S8(Amplitude) < 0 then
          Amplitude := U8(0);
        if ((b1 and 1) <> 0) and Envelope_Enabled then
          Amplitude := U8(Amplitude or 16);
        TempMixer := U8(b0 shr 1 and $48 or TempMixer);
        if S8(b0) >= 0 then
          RegisterAY.Noise := U8((b1 shr 1) and 31);
        IncU8(Position_In_Ornament);
        if Position_In_Ornament >= Ornament_Length then
          Position_In_Ornament := U8(Loop_Ornament_Position);
        IncU8(Position_In_Sample);
        if Position_In_Sample >= Sample_Length then
        begin
          Position_In_Sample := U8(Loop_Sample_Position);
          if S8(Loop_Sample_Position) < 0 then
            Enabled := False;
        end;
      end
      else
      begin
        TempMixer := U8(TempMixer or $48);
        Amplitude := U8(0);
      end;
    end;
    TempMixer := U8(TempMixer shr 1);
  end;

begin

  with PlParams.STP do
  begin
    DecU8(DelayCounter);
    if DelayCounter = 0 then
      with RAM do
      begin
        DelayCounter := U8(Header.STP_Delay);
        with PlParams.STP_A do
        begin
          DecS8(Note_Skip_Counter);
          if Note_Skip_Counter < 0 then
          begin
            if (Index[Address_In_Pattern] = 0) then
            begin
              IncU8(CurrentPosition);
              if CurrentPosition = Index[Header.STP_PositionsPointer] then
                CurrentPosition := U8(MarkLoop(Index[Header.STP_PositionsPointer + 1]));
              Address_In_Pattern :=
                U16(READ16(Header.STP_PatternsPointer +
                  Index[Header.STP_PositionsPointer + 2 + CurrentPosition * 2]));
              PlParams.STP_B.Address_In_Pattern :=
                U16(READ16(Header.STP_PatternsPointer +
                  Index[Header.STP_PositionsPointer + 2 + CurrentPosition * 2] + 2));
              PlParams.STP_C.Address_In_Pattern :=
                U16(READ16(Header.STP_PatternsPointer +
                  Index[Header.STP_PositionsPointer + 2 + CurrentPosition * 2] + 4));
              Transposition := U8(Index[Header.STP_PositionsPointer + 3 +
                  CurrentPosition * 2]);
            end;
            PatternInterpreter(PlParams.STP_A);
          end;
        end;
        with PlParams.STP_B do
        begin
          DecS8(Note_Skip_Counter);
          if Note_Skip_Counter < 0 then
            PatternInterpreter(PlParams.STP_B);
        end;
        with PlParams.STP_C do
        begin
          DecS8(Note_Skip_Counter);
          if Note_Skip_Counter < 0 then
            PatternInterpreter(PlParams.STP_C);
        end;
      end;
  end;

  TempMixer := U8(0);
  GetRegisters(PlParams.STP_A);
  GetRegisters(PlParams.STP_B);
  GetRegisters(PlParams.STP_C);

  SetMixerRegister(TempMixer);

  RegisterAY.TonA := U16(PlParams.STP_A.Ton);
  RegisterAY.TonB := U16(PlParams.STP_B.Ton);
  RegisterAY.TonC := U16(PlParams.STP_C.Ton);

  SetAmplA(PlParams.STP_A.Amplitude);
  SetAmplB(PlParams.STP_B.Amplitude);
  SetAmplC(PlParams.STP_C.Amplitude);

  Inc(FTick);
end;

procedure TZXTrackerEngine.PSC_Get_Registers;
var
  TempMixer: byte;

  procedure PatternInterpreter(var Chan: PSC_Channel_Parameters);
  var
    quit: boolean;
    b1b, b2b, b3b, b4b, b5b, b6b, b7b: boolean;
  begin
    quit := False;
    b1b := False;
    b2b := False;
    b3b := False;
    b4b := False;
    b5b := False;
    b6b := False;
    b7b := False;
    with RAM, Chan do
    begin
      repeat
        case Index[Address_In_Pattern] of
          $c0..$ff:
            begin
              Note_Skip_Counter := S8(Index[Address_In_Pattern] - $bf);
              quit := True;
            end;
          $a0..$bf:
            begin
              OrnamentPointer :=
                U16(READ16(Header.PSC_OrnamentsPointer +
                  (Index[Address_In_Pattern] - $a0) * 2));
              if FVersion > 3 then
                IncU16(OrnamentPointer, Header.PSC_OrnamentsPointer);
            end;
          $7e..$9f:
            if Index[Address_In_Pattern] >= $80 then
            begin
              SamplePointer := U16(Header.PSC_SamplesPointers[Index[Address_In_Pattern] - $80]);
              if FVersion > 3 then
                IncU16(SamplePointer, $4c);
            end;
          $6b:
            begin
              IncU16(Address_In_Pattern);
              Addition_To_Ton := S16(Index[Address_In_Pattern]);
              b5b := True;
            end;
          $6c:
            begin
              IncU16(Address_In_Pattern);
              Addition_To_Ton := S16(-S8(Index[Address_In_Pattern]));
              b5b := True;
            end;
          $6d:
            begin
              b4b := True;
              IncU16(Address_In_Pattern);
              Addition_To_Ton := S16(Index[Address_In_Pattern]);
            end;
          $6e:
            begin
              IncU16(Address_In_Pattern);
              PlParams.PSC.Delay := U16(Index[Address_In_Pattern]);
            end;
          $6f:
            begin
              b1b := True;
              IncU16(Address_In_Pattern);
            end;
          $70:
            begin
              b3b := True;
              IncU16(Address_In_Pattern);
              Volume_Counter1 := U8(Index[Address_In_Pattern]);
            end;
          $71:
            begin
              Break_Ornament_Loop := True;
              IncU16(Address_In_Pattern);
            end;
          $7a:
            begin
              IncU16(Address_In_Pattern);
              if @Chan = @PlParams.PSC_B then
              begin
                SetEnvelopeRegister(Index[Address_In_Pattern] and 15);
                RegisterAY.Envelope :=
                  U16(READ16(Address_In_Pattern + 1));
                IncU16(Address_In_Pattern, 2);
              end;
            end;
          $7b:
            begin
              IncU16(Address_In_Pattern);
              if @Chan = @PlParams.PSC_B then
                PlParams.PSC.Noise_Base := U16(Index[Address_In_Pattern]);
            end;
          $7c:
            begin
              b1b := False;
              b2b := True;
              b3b := False;
              b4b := False;
              b5b := False;
              b6b := False;
              b7b := False;
            end;
          $7d:
            Break_Sample_Loop := True;
          $58..$66:
            begin
              Initial_Volume := S8(Index[Address_In_Pattern] - $57);
              Envelope_Enabled := False;
              b6b := True;
            end;
          $57:
            begin
              Initial_Volume := S8($f);
              Envelope_Enabled := True;
              b6b := True;
            end;
          0..$56:
            begin
              Note := U8(Index[Address_In_Pattern]);
              b6b := True;
              b7b := True;
            end
        else
          IncU16(Address_In_Pattern);
        end;
        IncU16(Address_In_Pattern);
      until quit;
      if b7b then
      begin
        Break_Ornament_Loop := False;
        Ornament_Enabled := True;
        Enabled := True;
        Break_Sample_Loop := False;
        Ton_Slide_Enabled := False;
        Ton_Accumulator := S16(0);
        Current_Ton_Sliding := S16(0);
        Noise_Accumulator := U8(0);
        Volume_Counter := U8(0);
        Position_In_Sample := U8(0);
        Position_In_Ornament := U8(0);
      end;
      if b6b then
        Volume := U8(Initial_Volume);
      if b5b then
      begin
        Gliss := False;
        Ton_Slide_Enabled := True;
      end;
      if b4b then
      begin
        Current_Ton_Sliding := S16(Ton - ASM_Table[Note]);
        Gliss := True;
        if Chan.Current_Ton_Sliding >= 0 then
          Addition_To_Ton := S16(-Addition_To_Ton);
        Ton_Slide_Enabled := True;
      end;
      if b3b then
      begin
        Volume_Counter := U8(Volume_Counter1);
        Volume_Inc := True;
        if Volume_Counter and $40 <> 0 then
        begin
          Volume_Counter := U8(-S8(Volume_Counter or 128));
          Volume_Inc := False;
        end;
        Volume_Counter_Init := U8(Volume_Counter);
      end;
      if b2b then
      begin
        Break_Ornament_Loop := False;
        Ornament_Enabled := False;
        Enabled := False;
        Break_Sample_Loop := False;
        Ton_Slide_Enabled := False;
      end;
      if b1b then
        Ornament_Enabled := False;
    end;
  end;

  procedure GetRegisters(var Chan: PSC_Channel_Parameters);
  var
    j, b: byte;
  begin
    with Chan, RAM do
    begin
      if Enabled then
      begin
        j := U8(Note);
        if Ornament_Enabled then
        begin
          b := U8(Index[OrnamentPointer + Position_In_Ornament * 2]);
          IncU8(Noise_Accumulator, b);
          IncU8(j, Index[OrnamentPointer + Position_In_Ornament * 2 + 1]);
          if S8(j) < 0 then
            IncU8(j, $56);
          if j > $55 then
            DecU8(j, $56);
          if j > $55 then
            j := U8($55);
          if b and 128 = 0 then
            Loop_Ornament_Position := U8(Position_In_Ornament);
          if b and 64 = 0 then
          begin
            if not Break_Ornament_Loop then
              Position_In_Ornament := U8(Loop_Ornament_Position)
            else
            begin
              Break_Ornament_Loop := False;
              if b and 32 = 0 then
                Ornament_Enabled := False;
              IncU8(Position_In_Ornament);
            end;
          end
          else
          begin
            if b and 32 = 0 then
              Ornament_Enabled := False;
            IncU8(Position_In_Ornament);
          end;
        end;
        Note := U8(j);
        Ton := U16(READ16(SamplePointer + Position_In_Sample * 6));
        IncS16(Ton_Accumulator, Ton);
        Ton := U16(ASM_Table[j] + Ton_Accumulator);
        if Ton_Slide_Enabled then
        begin
          IncS16(Current_Ton_Sliding, Addition_To_Ton);
          if Gliss and (((Current_Ton_Sliding < 0) and (Addition_To_Ton <= 0)) or
            ((Current_Ton_Sliding >= 0) and (Addition_To_Ton >= 0))) then
            Ton_Slide_Enabled := False;
          IncU16(Ton, Current_Ton_Sliding);
        end;
        Ton := U16(Ton and $fff);
        b := U8(Index[SamplePointer + Position_In_Sample * 6 + 4]);
        TempMixer := U8(TempMixer or ((b and 9) shl 3));
        j := U8(0);
        if b and 2 <> 0 then
          IncU8(j);
        if b and 4 <> 0 then
          DecU8(j);
        if Volume_Counter > 0 then
        begin
          DecU8(Volume_Counter);
          if Volume_Counter = 0 then
          begin
            if Volume_Inc then
              IncU8(j)
            else
              DecU8(j);
            Volume_Counter := U8(Volume_Counter_Init);
          end;
        end;
        IncU8(Volume, j);
        if S8(Volume) < 0 then
          Volume := U8(0)
        else if Volume > 15 then
          Volume := U8(15);
        Amplitude := U8(((Volume + 1) *
          (Index[SamplePointer + Position_In_Sample * 6 + 3] and 15)) shr 4);
        if Envelope_Enabled and (b and 16 = 0) then
          Amplitude := U8(Amplitude or 16);
        if (Amplitude and 16 <> 0) and (b and 8 <> 0) then
          RegisterAY.Envelope :=
            U16(RegisterAY.Envelope + S8(
              Index[SamplePointer + Position_In_Sample * 6 + 2]))
        else
        begin
          IncU8(Noise_Accumulator,
            Index[SamplePointer + Position_In_Sample * 6 + 2]);
          if b and 8 = 0 then
            RegisterAY.Noise := U8(Noise_Accumulator and 31);
        end;
        if b and 128 = 0 then
          Loop_Sample_Position := U8(Position_In_Sample);
        if b and 64 = 0 then
        begin
          if not Break_Sample_Loop then
            Position_In_Sample := U8(Loop_Sample_Position)
          else
          begin
            Break_Sample_Loop := False;
            if b and 32 = 0 then
              Enabled := False;
            IncU8(Position_In_Sample);
          end;
        end
        else
        begin
          if b and 32 = 0 then
            Enabled := False;
          IncU8(Position_In_Sample);
        end;
      end
      else
        Amplitude := U8(0);
    end;
    TempMixer := U8(TempMixer shr 1);
  end;

begin

  with PlParams.PSC do
  begin
    DecU16(DelayCounter);
    if DelayCounter = 0 then
    begin
      DecU16(Lines_Counter);
      if Lines_Counter = 0 then
        with RAM do
        begin
          if Index[Positions_Pointer + 1] = 255 then
            Positions_Pointer := U16(MarkLoop(READ16(Positions_Pointer + 2)));
          Lines_Counter := U16(Index[Positions_Pointer + 1]);
          PlParams.PSC_A.Address_In_Pattern :=
            U16(READ16(Positions_Pointer + 2));
          PlParams.PSC_B.Address_In_Pattern :=
            U16(READ16(Positions_Pointer + 4));
          PlParams.PSC_C.Address_In_Pattern :=
            U16(READ16(Positions_Pointer + 6));
          IncU16(Positions_Pointer, 8);
          PlParams.PSC_A.Note_Skip_Counter := S8(1);
          PlParams.PSC_B.Note_Skip_Counter := S8(1);
          PlParams.PSC_C.Note_Skip_Counter := S8(1);
        end;
      with PlParams.PSC_A do
      begin
        DecS8(Note_Skip_Counter);
        if Note_Skip_Counter = 0 then
          PatternInterpreter(PlParams.PSC_A);
      end;
      with PlParams.PSC_B do
      begin
        DecS8(Note_Skip_Counter);
        if Note_Skip_Counter = 0 then
          PatternInterpreter(PlParams.PSC_B);
      end;
      with PlParams.PSC_C do
      begin
        DecS8(Note_Skip_Counter);
        if Note_Skip_Counter = 0 then
          PatternInterpreter(PlParams.PSC_C);
      end;
      IncU8(PlParams.PSC_A.Noise_Accumulator, Noise_Base);
      IncU8(PlParams.PSC_B.Noise_Accumulator, Noise_Base);
      IncU8(PlParams.PSC_C.Noise_Accumulator, Noise_Base);
      DelayCounter := U16(Delay);
    end;
  end;

  TempMixer := U8(0);
  GetRegisters(PlParams.PSC_A);
  GetRegisters(PlParams.PSC_B);
  GetRegisters(PlParams.PSC_C);

  SetMixerRegister(TempMixer);

  RegisterAY.TonA := U16(PlParams.PSC_A.Ton);
  RegisterAY.TonB := U16(PlParams.PSC_B.Ton);
  RegisterAY.TonC := U16(PlParams.PSC_C.Ton);

  SetAmplA(PlParams.PSC_A.Amplitude);
  SetAmplB(PlParams.PSC_B.Amplitude);
  SetAmplC(PlParams.PSC_C.Amplitude);

  Inc(FTick);
end;

procedure TZXTrackerEngine.FTC_Get_Registers;

  function GetNoteFreq(j: integer): integer;
  begin
    if FVersion < 7 then
      Result := PT3NoteTable_ST[j]
    else
      case RAM.Header.FTC_MusicName[$32] of
        #2:
          Result := FTCNoteTable2[j];
      else
        Result := ST_Table[j];
      end;
  end;

var
  TempMixer: byte;

  procedure PatternInterpreter(var Chan: FTC_Channel_Parameters; ChanNum: integer);
  var
    quit: boolean;
    ExxAF: shortint;
  begin
    quit := False;
    ExxAF := S8(2);
    with Chan do
    begin
      repeat
        with RAM do
          case Index[Address_In_Pattern] of
            0..$1f:
              begin
                SamplePointer := U16(Header.FTC_SamplesPointers[Index[Address_In_Pattern]]);
                IncU16(SamplePointer);
                Loop_Sample_Position := U8(Index[SamplePointer]);
                IncU16(SamplePointer);
                Sample_Length := U8(Index[SamplePointer] + 1);
                IncU16(SamplePointer);
              end;
            $20..$2f:
              Volume := U8(Index[Address_In_Pattern] - $20);
            $30:
              begin
                Sample_Enabled := False;
                Position_In_Sample := U8(0);
                Sample_Noise_Accumulator := U8(0);
                Volume_Slide := S8(0);
                Noise_Accumulator := U8(0);
                Note_Accumulator := U8(0);
                Position_In_Ornament := U8(0);
                Ton_Accumulator := S16(0);
                Envelope_Accumulator := U16(0);
                if ExxAF > 0 then
                begin
                  Current_Ton_Sliding := S16(0);
                  Ton_Slide_Direction := U8(0);
                end;
                if ExxAF > 1 then
                  Ton_Slide_Step := S16(0);
                Note_Skip_Counter := S8(0);
                quit := True;
              end;
            $31..$3e:
              begin
                PlParams.FTC.EnvT := U8(Index[Address_In_Pattern] - $30);
                Envelope_Enabled := True;
                IncU16(Address_In_Pattern);
                Envelope := U16(READ16(Chan.Address_In_Pattern));
                IncU16(Chan.Address_In_Pattern);
              end;
            $3f:
              Envelope_Enabled := False;
            $40..$5f:
              begin
                Note_Skip_Counter := S8(Index[Address_In_Pattern] - $40);
                ExxAF := S8(1);
                quit := True;
              end;
            $60..$cb:
              begin
                Previous_Note := U8(Note);
                Note := U8(PlParams.FTC.Transposition +
                  Index[Chan.Address_In_Pattern] - $60);
                Sample_Enabled := True;
                Position_In_Sample := U8(0);
                Sample_Noise_Accumulator := U8(0);
                Volume_Slide := S8(0);
                Noise_Accumulator := U8(0);
                Note_Accumulator := U8(0);
                Position_In_Ornament := U8(0);
                Ton_Accumulator := S16(0);
                Envelope_Accumulator := U16(0);
                if ExxAF > 0 then
                begin
                  Current_Ton_Sliding := S16(0);
                  Ton_Slide_Direction := U8(0);
                end;
                if ExxAF > 1 then
                  Ton_Slide_Step := S16(0);
                Note_Skip_Counter := S8(0);
                quit := True;
              end;
            $cc..$ec:
              begin
                OrnamentPointer :=
                  U16(Header.FTC_OrnamentsPointers[Index[Address_In_Pattern] - $cc]);
                IncU16(OrnamentPointer);
                Loop_Ornament_Position := U8(Index[OrnamentPointer]);
                IncU16(OrnamentPointer);
                Ornament_Length := U8(Index[OrnamentPointer] + 1);
                IncU16(OrnamentPointer);
                Position_In_Ornament := U8(0);
                Noise_Accumulator := U8(0);
                Note_Accumulator := U8(0);
              end;
            $ed:
              begin
                ExxAF := S8(1);
                IncU16(Address_In_Pattern);
                Ton_Slide_Step := S16(READ16(Chan.Address_In_Pattern));
                IncU16(Address_In_Pattern);
              end;
            $ee:
              begin
                ExxAF := S8(0);
                IncU16(Address_In_Pattern);
                Ton_Slide_Step1 := S16(Index[Address_In_Pattern]);
              end;
            $ef:
              begin
                IncU16(Address_In_Pattern);
                if (FVersion > 7) and
                  (Index[Address_In_Pattern] = $fe) then
                  PlParams.FTC.Retrig := U8(ChanNum)
                else
                  Noise := U8(Index[Address_In_Pattern]);
              end
          else
            begin
              IncU16(Address_In_Pattern);
              PlParams.FTC.Delay := U8(Index[Address_In_Pattern]);
            end
          end;
        IncU16(Address_In_Pattern);
      until quit;
      if ExxAF = 0 then
      begin
        Current_Ton_Sliding := S16(GetNoteFreq(Previous_Note) - GetNoteFreq(Note));
        if Current_Ton_Sliding < 0 then
        begin
          Ton_Slide_Step := S16(Ton_Slide_Step1);
          Ton_Slide_Direction := U8(1);
        end
        else
        begin
          Ton_Slide_Step := S16(-Ton_Slide_Step1);
          Ton_Slide_Direction := U8(2);
        end;
      end;
    end;
  end;

  procedure GetRegisters(var Chan: FTC_Channel_Parameters);
  var
    j, b: byte;
    k: word;
    Add_To_Note, Add_To_Noise: byte;
  begin
    with Chan, RAM do
    begin
      Add_To_Note := U8(Note_Accumulator + Index[OrnamentPointer +
          Position_In_Ornament * 2 + 1]);
      b := U8(Index[OrnamentPointer + Position_In_Ornament * 2]);
      if b and 64 <> 0 then
        Note_Accumulator := U8(Add_To_Note);
      Add_To_Noise := U8(Noise_Accumulator + b);
      if S8(b) < 0 then
        Noise_Accumulator := U8(Add_To_Noise);
      IncU8(Position_In_Ornament);
      if Position_In_Ornament = Ornament_Length then
        Position_In_Ornament := U8(Loop_Ornament_Position);
      if Sample_Enabled then
      begin
        b := U8(Index[SamplePointer + Position_In_Sample * 5]);
        j := U8(Sample_Noise_Accumulator + b);
        if S8(b) < 0 then
          Sample_Noise_Accumulator := U8(j);
        if b and 64 = 0 then
          RegisterAY.Noise := U8((j + Noise + Add_To_Noise) and 31)
        else
          TempMixer := U8(TempMixer or 64);
        k := U16(Ton_Accumulator + READ16(SamplePointer + Position_In_Sample * 5 + 1));
        b := U8(Index[SamplePointer + Position_In_Sample * 5 + 2]);
        if S8(b) < 0 then
          Ton_Accumulator := S16(k);
        Addition_To_Ton := S16(k);
        if b and 64 <> 0 then
          TempMixer := U8(TempMixer or 8);
        b := U8(Index[SamplePointer + Position_In_Sample * 5 + 3]);
        if b and 32 <> 0 then
          if b and 16 <> 0 then
          begin
            DecS8(Volume_Slide);
            if Volume_Slide < -15 then
              Volume_Slide := S8(-15);
          end
          else
          begin
            IncS8(Volume_Slide);
            if Volume_Slide > 15 then
              Volume_Slide := S8(15);
          end;
        j := U8(Volume_Slide + b and 15);
        if S8(j) < 0 then
          j := U8(0)
        else if j > 15 then
          j := U8(15);
        Amplitude := U8(round((Volume * 17 + U8(Volume > 7)) * j / 256));
        k := U16(Envelope_Accumulator + S8(
            Index[SamplePointer + Position_In_Sample * 5 + 4]));
        if S8(b) < 0 then
          Envelope_Accumulator := U16(k);
        if (b and 64 <> 0) and Envelope_Enabled then
        begin
          RegisterAY.Envelope := U16(Envelope - k);
          Amplitude := U8(Amplitude or 16);
        end;
        IncU8(Position_In_Sample);
        if Position_In_Sample = Sample_Length then
          Position_In_Sample := U8(Loop_Sample_Position);
      end
      else
      begin
        Amplitude := U8(0);
        TempMixer := U8(TempMixer or 72);
      end;
      j := U8(Note + Add_To_Note);
      if j > $5F then
        j := U8($5F);
      Ton := U16(GetNoteFreq(j) + Addition_To_Ton);
      IncS16(Current_Ton_Sliding, Ton_Slide_Step);
      if ((Ton_Slide_Direction = 1) and (Current_Ton_Sliding >= 0)) or
        ((Ton_Slide_Direction = 2) and (Current_Ton_Sliding < 0)) then
      begin
        Current_Ton_Sliding := S16(0);
        Ton_Slide_Step := S16(0);
      end
      else
        IncU16(Ton, Current_Ton_Sliding);
      Ton := U16(Ton and $fff);
    end;
    TempMixer := U8(TempMixer shr 1);
  end;

begin

  with PlParams.FTC do
  begin
    DecU8(DelayCounter);
    if DelayCounter = 0 then
    begin
      with PlParams.FTC_A do
      begin
        DecS8(Note_Skip_Counter);
        if Note_Skip_Counter < 0 then
        begin
          with RAM do
            if Index[Address_In_Pattern] = 255 then
            begin
              IncU8(CurrentPosition);
              if Header.FTC_Positions[CurrentPosition].Pattern = 255 then
                CurrentPosition := U8(MarkLoop(Header.FTC_Loop_Position));
              Transposition := U8(Header.FTC_Positions[CurrentPosition].Transposition);
              Address_In_Pattern :=
                U16(READ16(Header.FTC_PatternsPointer +
                  Header.FTC_Positions[CurrentPosition].Pattern * 6));
              PlParams.FTC_B.Address_In_Pattern :=
                U16(READ16(Header.FTC_PatternsPointer +
                  Header.FTC_Positions[CurrentPosition].Pattern * 6 + 2));
              PlParams.FTC_C.Address_In_Pattern :=
                U16(READ16(Header.FTC_PatternsPointer +
                  Header.FTC_Positions[CurrentPosition].Pattern * 6 + 4));
            end;
          PatternInterpreter(PlParams.FTC_A, 1);
        end;
      end;
      with PlParams.FTC_B do
      begin
        DecS8(Note_Skip_Counter);
        if Note_Skip_Counter < 0 then
          PatternInterpreter(PlParams.FTC_B, 2);
      end;
      with PlParams.FTC_C do
      begin
        DecS8(Note_Skip_Counter);
        if Note_Skip_Counter < 0 then
          PatternInterpreter(PlParams.FTC_C, 3);
      end;
      DelayCounter := U8(Delay);
    end;
  end;

  if PlParams.FTC.Retrig <> 0 then
  begin
    case PlParams.FTC.Retrig of
      1:
        FToneRestart[0] := True;
      2:
        FToneRestart[1] := True;
      3:
        FToneRestart[2] := True;
    end;
  end;

  if (FEnvelopeShape <> PlParams.FTC.EnvT) or
    (PlParams.FTC.Retrig <> 0) then
    SetEnvelopeRegister(PlParams.FTC.EnvT);
  PlParams.FTC.Retrig := U8(0);

  TempMixer := U8(0);
  GetRegisters(PlParams.FTC_A);
  GetRegisters(PlParams.FTC_B);
  GetRegisters(PlParams.FTC_C);

  SetMixerRegister(TempMixer);

  RegisterAY.TonA := U16(PlParams.FTC_A.Ton);
  RegisterAY.TonB := U16(PlParams.FTC_B.Ton);
  RegisterAY.TonC := U16(PlParams.FTC_C.Ton);

  SetAmplA(PlParams.FTC_A.Amplitude);
  SetAmplB(PlParams.FTC_B.Amplitude);
  SetAmplC(PlParams.FTC_C.Amplitude);

  Inc(FTick);
end;

procedure TZXTrackerEngine.PT1_Get_Registers;
var
  TempMixer: integer;

  procedure PatternInterpreter(var Chan: PT1_Channel_Parameters);
  var
    quit: boolean;
  begin
    quit := False;
    with Chan do
    begin
      repeat
        with RAM do
          case Index[Address_In_Pattern] of
            0..$5f:
              begin
                Note := U8(Index[Address_In_Pattern]);
                Enabled := True;
                Position_In_Sample := U8(0);
                quit := True;
              end;
            $60..$6f:
              begin
                SamplePointer := U16(Header.PT1_SamplesPointers[Index[Address_In_Pattern] - $60]);
                Sample_Length := U8(Index[SamplePointer]);
                IncU16(SamplePointer);
                Loop_Sample_Position := U8(Index[SamplePointer]);
                IncU16(SamplePointer);
              end;
            $70..$7f:
              OrnamentPointer :=
                U16(Header.PT1_OrnamentsPointers[Index[Address_In_Pattern] - $70]);
            $80:
              begin
                Enabled := False;
                quit := True;
              end;
            $81:
              Envelope_Enabled := False;
            $82..$8f:
              begin
                Envelope_Enabled := True;
                SetEnvelopeRegister(Index[Address_In_Pattern] - $81);
                IncU16(Address_In_Pattern);
                RegisterAY.Envelope := U16(READ16(Address_In_Pattern));
                IncU16(Address_In_Pattern);
              end;
            $90:
              quit := True;
            $91..$a0:
              PlParams.PT1.Delay := U8(Index[Address_In_Pattern] - $91);
            $a1..$b0:
              Volume := U8(Index[Address_In_Pattern] - $a1);
          else
            Number_Of_Notes_To_Skip := U8(Index[Address_In_Pattern] - $b1);
          end;
        IncU16(Address_In_Pattern)
      until quit;
      Note_Skip_Counter := S8(Number_Of_Notes_To_Skip);
    end;
  end;

  procedure GetRegisters(var Chan: PT1_Channel_Parameters);
  var
    j, b: byte;
  begin
    with Chan do
      if Enabled then
        with RAM do
        begin
          j := U8(Note + Index[OrnamentPointer + Position_In_Sample]);
          if j > 95 then
            j := U8(95);
          b := U8(Index[SamplePointer + Position_In_Sample * 3]);
          Ton := U16(U16(b) shl 4 and $f00 + Index[SamplePointer +
              Position_In_Sample * 3 + 2]);
          Amplitude := U8(round((Volume * 17 + U8(Volume > 7)) * (b and 15) / 256));
          b := U8(Index[SamplePointer + Position_In_Sample * 3 + 1]);
          if b and 32 = 0 then
            Ton := U16(-Ton);
          Ton := U16((Ton + PT3NoteTable_ST[j] + U16(j = 46)) and $fff);
          if Envelope_Enabled then
            Amplitude := U8(Amplitude or 16);
          if S8(b) < 0 then
            TempMixer := TempMixer or 64
          else
            RegisterAY.Noise := U8(b and 31);
          if b and 64 <> 0 then
            TempMixer := TempMixer or 8;
          IncU8(Position_In_Sample);
          if Position_In_Sample = Sample_Length then
            Position_In_Sample := U8(Loop_Sample_Position);
        end
      else
        Amplitude := U8(0);
    TempMixer := TempMixer shr 1;
  end;

begin

  with PlParams.PT1 do
  begin
    DecU8(DelayCounter);
    if DelayCounter = 0 then
    begin
      with PlParams.PT1_A do
      begin
        DecS8(Note_Skip_Counter);
        if Note_Skip_Counter < 0 then
        begin
          with RAM do
            if (Index[Address_In_Pattern] = 255) then
            begin
              IncU8(CurrentPosition);
              if CurrentPosition = Header.PT1_NumberOfPositions then
                CurrentPosition := U8(MarkLoop(Header.PT1_LoopPosition));
              Address_In_Pattern :=
                U16(READ16(Header.PT1_PatternsPointer +
                  Header.PT1_PositionList[CurrentPosition] * 6));
              PlParams.PT1_B.Address_In_Pattern :=
                U16(READ16(Header.PT1_PatternsPointer +
                  Header.PT1_PositionList[CurrentPosition] * 6 + 2));
              PlParams.PT1_C.Address_In_Pattern :=
                U16(READ16(Header.PT1_PatternsPointer +
                  Header.PT1_PositionList[CurrentPosition] * 6 + 4));
            end;
          PatternInterpreter(PlParams.PT1_A);
        end;
      end;
      with PlParams.PT1_B do
      begin
        DecS8(Note_Skip_Counter);
        if Note_Skip_Counter < 0 then
          PatternInterpreter(PlParams.PT1_B);
      end;
      with PlParams.PT1_C do
      begin
        DecS8(Note_Skip_Counter);
        if Note_Skip_Counter < 0 then
          PatternInterpreter(PlParams.PT1_C);
      end;
      DelayCounter := U8(Delay);
    end;
  end;

  TempMixer := 0;
  GetRegisters(PlParams.PT1_A);
  GetRegisters(PlParams.PT1_B);
  GetRegisters(PlParams.PT1_C);

  SetMixerRegister(TempMixer);

  RegisterAY.TonA := U16(PlParams.PT1_A.Ton);
  RegisterAY.TonB := U16(PlParams.PT1_B.Ton);
  RegisterAY.TonC := U16(PlParams.PT1_C.Ton);

  SetAmplA(PlParams.PT1_A.Amplitude);
  SetAmplB(PlParams.PT1_B.Amplitude);
  SetAmplC(PlParams.PT1_C.Amplitude);

  Inc(FTick);
end;

procedure TZXTrackerEngine.PT2_Get_Registers;
var
  TempMixer: byte;

  procedure PatternInterpreter(var Chan: PT2_Channel_Parameters);
  var
    quit, gliss: boolean;
  begin
    quit := False;
    gliss := False;
    with Chan, RAM do
    begin
      repeat
        case Index[Chan.Address_In_Pattern] of
          $e1..$ff:
            begin
              SamplePointer := U16(Header.PT2_SamplesPointers[Index[Address_In_Pattern] - $e0]);
              Sample_Length := U8(Index[SamplePointer]);
              IncU16(SamplePointer);
              Loop_Sample_Position := U8(Index[SamplePointer]);
              IncU16(SamplePointer);
            end;
          $e0:
            begin
              Position_In_Sample := U8(0);
              Position_In_Ornament := U8(0);
              Current_Ton_Sliding := S16(0);
              GlissType := 0;
              Enabled := False;
              quit := True;
            end;
          $80..$df:
            begin
              Position_In_Sample := U8(0);
              Position_In_Ornament := U8(0);
              Current_Ton_Sliding := S16(0);
              if gliss then
              begin
                Slide_To_Note := U8(Index[Address_In_Pattern] - $80);
                if GlissType = 1 then
                  Note := U8(Slide_To_Note);
              end
              else
              begin
                Note := U8(Index[Address_In_Pattern] - $80);
                GlissType := 0;
              end;
              Enabled := True;
              quit := True;
            end;
          $7f:
            Envelope_Enabled := False;
          $71..$7e:
            begin
              Envelope_Enabled := True;
              SetEnvelopeRegister(Index[Address_In_Pattern] - $70);
              IncU16(Address_In_Pattern);
              RegisterAY.Index[11] := U8(Index[Address_In_Pattern]);
              IncU16(Address_In_Pattern);
              RegisterAY.Index[12] := U8(Index[Address_In_Pattern]);
            end;
          $70:
            quit := True;
          $60..$6f:
            begin
              OrnamentPointer := U16(Header.PT2_OrnamentsPointers[Index[Address_In_Pattern] - $60]);
              Ornament_Length := U8(Index[OrnamentPointer]);
              IncU16(OrnamentPointer);
              Loop_Ornament_Position := U8(Index[OrnamentPointer]);
              IncU16(OrnamentPointer);
              Position_In_Ornament := U8(0);
            end;
          $20..$5f:
            Number_Of_Notes_To_Skip := U8(Index[Address_In_Pattern] - $20);
          $10..$1f:
            Volume := U8(Index[Address_In_Pattern] - $10);
          $f:
            begin
              IncU16(Address_In_Pattern);
              PlParams.PT2.Delay := U8(Index[Address_In_Pattern]);
            end;
          $e:
            begin
              IncU16(Address_In_Pattern);
              Glissade := S8(Index[Address_In_Pattern]);
              GlissType := 1;
              gliss := True;
            end;
          $d:
            begin
              IncU16(Address_In_Pattern);
              Glissade := S8(Abs(S8(Index[Address_In_Pattern])));

              IncU16(Address_In_Pattern, 2);

              GlissType := 2;
              gliss := True;
            end;
          $c:
            GlissType := 0
        else
          begin
            IncU16(Address_In_Pattern);
            Addition_To_Noise := S8(Index[Address_In_Pattern]);
          end
        end;
        IncU16(Address_In_Pattern)
      until quit;

      if gliss and (GlissType = 2) then
      begin
        Ton_Delta := S16(Abs(PT3NoteTable_ST[Slide_To_Note] - PT3NoteTable_ST[Note]));
        if Slide_To_Note > Note then
          Glissade := S8(-Glissade);
      end;

      Note_Skip_Counter := S8(Number_Of_Notes_To_Skip);
    end;
  end;

  procedure GetRegisters(var Chan: PT2_Channel_Parameters);
  var
    j, b0, b1: byte;
  begin
    with Chan, RAM do
    begin
      if Enabled then
      begin
        b0 := U8(Index[SamplePointer + Position_In_Sample * 3]);
        b1 := U8(Index[SamplePointer + Position_In_Sample * 3 + 1]);
        Ton := U16(Index[SamplePointer + Position_In_Sample * 3 + 2] +
          U16(b1 and 15) shl 8);
        if b0 and 4 = 0 then
          Ton := U16(-Ton);
        j := U8(Note + Index[OrnamentPointer + Position_In_Ornament]);
        if S8(j) < 0 then
          j := U8(0)
        else if j > 95 then
          j := U8(95);
        Ton := U16((Ton + Current_Ton_Sliding + PT3NoteTable_ST[j]) and $fff);
        if GlissType = 2 then
        begin
          Ton_Delta := S16(Ton_Delta - Abs(Glissade));
          if Ton_Delta < 0 then
          begin
            Note := U8(Slide_To_Note);
            GlissType := 0;
            Current_Ton_Sliding := S16(0);
          end;
        end;
        if GlissType <> 0 then
          IncS16(Current_Ton_Sliding, Glissade);
        Amplitude := U8(round((Volume * 17 + Ord(Volume > 7)) * U8(b1 shr 4) / 256));
        if Envelope_Enabled then
          Amplitude := U8(Amplitude or 16);
        if b0 and 1 <> 0 then
          TempMixer := U8(TempMixer or 64)
        else
          RegisterAY.Noise := U8((b0 shr 3 + U8(Addition_To_Noise)) and 31);
        if b0 and 2 <> 0 then
          TempMixer := U8(TempMixer or 8);
        IncU8(Position_In_Sample);
        if Position_In_Sample = Sample_Length then
          Position_In_Sample := U8(Loop_Sample_Position);
        IncU8(Position_In_Ornament);
        if Position_In_Ornament = Ornament_Length then
          Position_In_Ornament := U8(Loop_Ornament_Position);
      end
      else
        Amplitude := U8(0);
    end;
    TempMixer := U8(TempMixer shr 1);
  end;

begin

  with PlParams.PT2 do
  begin
    DecU8(DelayCounter);
    if DelayCounter = 0 then
    begin
      with PlParams.PT2_A, RAM do
      begin
        DecS8(Note_Skip_Counter);
        if Note_Skip_Counter < 0 then
        begin
          if (Index[Address_In_Pattern] = 0) then
          begin
            IncU8(CurrentPosition);
            if CurrentPosition = Header.PT2_NumberOfPositions then
              CurrentPosition := U8(MarkLoop(Header.PT2_LoopPosition));
            Address_In_Pattern :=
              U16(READ16(Header.PT2_PatternsPointer +
                Header.PT2_PositionList[CurrentPosition] * 6));
            PlParams.PT2_B.Address_In_Pattern :=
              U16(READ16(Header.PT2_PatternsPointer +
                Header.PT2_PositionList[CurrentPosition] * 6 + 2));
            PlParams.PT2_C.Address_In_Pattern :=
              U16(READ16(Header.PT2_PatternsPointer +
                Header.PT2_PositionList[CurrentPosition] * 6 + 4));
          end;
          PatternInterpreter(PlParams.PT2_A);
        end;
      end;
      with PlParams.PT2_B do
      begin
        DecS8(Note_Skip_Counter);
        if Note_Skip_Counter < 0 then
          PatternInterpreter(PlParams.PT2_B);
      end;
      with PlParams.PT2_C do
      begin
        DecS8(Note_Skip_Counter);
        if Note_Skip_Counter < 0 then
          PatternInterpreter(PlParams.PT2_C);
      end;
      DelayCounter := U8(Delay);
    end;
    TempMixer := U8(0);
    GetRegisters(PlParams.PT2_A);
    GetRegisters(PlParams.PT2_B);
    GetRegisters(PlParams.PT2_C);

    SetMixerRegister(TempMixer);

    RegisterAY.TonA := U16(PlParams.PT2_A.Ton);
    RegisterAY.TonB := U16(PlParams.PT2_B.Ton);
    RegisterAY.TonC := U16(PlParams.PT2_C.Ton);

    SetAmplA(PlParams.PT2_A.Amplitude);
    SetAmplB(PlParams.PT2_B.Amplitude);
    SetAmplC(PlParams.PT2_C.Amplitude);

    Inc(FTick);
  end;
end;

procedure TZXTrackerEngine.SQT_Get_Registers;
var
  TempMixer: byte;

  procedure PatternInterpreter(var Chan: SQT_Channel_Parameters);
  var
    Ptr: word;
    Temp: integer;

    procedure Call_LC1D1(a: byte);
    begin
      IncU16(Ptr);
      with Chan do
      begin
        if b6ix0 then
        begin
          Address_In_Pattern := U16(Ptr + 1);
          b6ix0 := False;
        end;
        with RAM do
          case a - 1 of
            0:
              if b4ix0 then
                Volume := U8(Index[Ptr] and 15);
            1:
              if b4ix0 then
                Volume := U8((Volume + Index[Ptr]) and 15);
            2:
              if b4ix0 then
              begin
                PlParams.SQT_A.Volume := U8(Index[Ptr]);
                PlParams.SQT_B.Volume := U8(Index[Ptr]);
                PlParams.SQT_C.Volume := U8(Index[Ptr]);
              end;
            3:
              if b4ix0 then
              begin
                with PlParams.SQT_A do
                  Volume := U8((Volume + Index[Ptr]) and 15);
                with PlParams.SQT_B do
                  Volume := U8((Volume + Index[Ptr]) and 15);
                with PlParams.SQT_C do
                  Volume := U8((Volume + Index[Ptr]) and 15);
              end;
            4:
              if b4ix0 then
                with PlParams.SQT do
                begin
                  DelayCounter := U8(Index[Ptr] and 31);
                  if DelayCounter = 0 then
                    DelayCounter := U8(32);
                  Delay := U8(DelayCounter);
                end;
            5:
              if b4ix0 then
                with PlParams.SQT do
                begin
                  DelayCounter := U8((DelayCounter + Index[Ptr]) and 31);
                  if DelayCounter = 0 then
                    DelayCounter := U8(32);
                  Delay := U8(DelayCounter);
                end;
            6:
              begin
                Current_Ton_Sliding := S16(0);
                gliss := True;
                Ton_Slide_Step := S16(-Index[Ptr]);
              end;
            7:
              begin
                Current_Ton_Sliding := S16(0);
                gliss := True;
                Ton_Slide_Step := S16(Index[Ptr]);
              end
          else
            begin
              Envelope_Enabled := True;
              SetEnvelopeRegister((a - 1) and 15);
              RegisterAY.Index[11] := U8(Index[Ptr]);
            end;
          end;
      end;
    end;

    procedure Call_LC2A8(a: byte);
    begin
      with Chan do
      begin
        Envelope_Enabled := False;
        Ornament_Enabled := False;
        gliss := False;
        Enabled := True;
        with RAM do
          SamplePointer := U16(READ16(a * 2 + Header.SQT_SamplesPointer));
        Point_In_Sample := U16(SamplePointer + 2);
        Sample_Tik_Counter := S8(32);
        MixNoise := True;
        MixTon := True;
      end;
    end;

    procedure Call_LC2D9(a: byte);
    begin
      with Chan do
      begin
        with RAM do
          OrnamentPointer := U16(READ16(a * 2 + Header.SQT_OrnamentsPointer));
        Point_In_Ornament := U16(OrnamentPointer + 2);
        Ornament_Tik_Counter := S8(32);
        Ornament_Enabled := True;
      end;
    end;

    procedure Call_LC283;
    begin
      with RAM do
        case Index[Ptr] of
          0..$7f:
            Call_LC1D1(Index[Ptr]);
          $80..$ff:
            begin
              if Index[Ptr] shr 1 and 31 <> 0 then
                Call_LC2A8(Index[Ptr] shr 1 and 31);
              if Index[Ptr] and 64 <> 0 then
              begin
                Temp := Index[Ptr + 1] shr 4;
                if Index[Ptr] and 1 <> 0 then
                  Temp := Temp or 16;
                if Temp <> 0 then
                  Call_LC2D9(Temp);
                IncU16(Ptr);
                if Index[Ptr] and 15 <> 0 then
                  Call_LC1D1(Index[Ptr] and 15);
              end;
            end
        end;
      IncU16(Ptr);
    end;

    procedure Call_LC191;
    begin
      with Chan do
      begin
        Ptr := U16(ix27);
        b6ix0 := False;
      end;
      with RAM do
        case Index[Ptr] of
          0..$7f:
            begin
              IncU16(Ptr);
              Call_LC283;
            end;
          $80..$ff:
            Call_LC2A8(Index[Ptr] and 31);
        end;
    end;

  begin
    with Chan do
    begin
      if ix21 <> 0 then
      begin
        DecU8(ix21);
        if b7ix0 then
          Call_LC191;
        exit;
      end;
      Ptr := U16(Address_In_Pattern);
      b6ix0 := True;
      b7ix0 := False;
      repeat
        with RAM do
          case Index[Ptr] of
            0..$5f:
              begin
                Note := U8(Index[Ptr]);
                ix27 := U16(Ptr);
                IncU16(Ptr);
                Call_LC283;
                if b6ix0 then
                  Address_In_Pattern := U16(Ptr);
                break;
              end;
            $60..$6e:
              begin
                Call_LC1D1(Index[Ptr] - $60);
                break;
              end;
            $6f..$7f:
              begin
                MixNoise := False;
                MixTon := False;
                Enabled := False;
                if Index[Ptr] <> $6f then
                  Call_LC1D1(Index[Ptr] - $6f)
                else
                  Address_In_Pattern := U16(Ptr + 1);
                break;
              end;
            $80..$bf:
              begin
                Address_In_Pattern := U16(Ptr + 1);
                if Index[Ptr] in [$80..$9f] then
                begin
                  if Index[Ptr] and 16 = 0 then
                    IncU8(Note, Index[Ptr] and 15)
                  else
                    DecU8(Note, Index[Ptr] and 15);
                end
                else
                begin
                  ix21 := U8(Index[Ptr] and 15);
                  if Index[Ptr] and 16 = 0 then
                    break;
                  if ix21 <> 0 then
                    b7ix0 := True;
                end;
                Call_LC191;
                break;
              end;
            $c0..$ff:
              begin
                Address_In_Pattern := U16(Ptr + 1);
                ix27 := U16(Ptr);
                Call_LC2A8(Index[Ptr] and 31);
                break;
              end
          end
      until False;
    end;
  end;

  procedure GetRegisters(var Chan: SQT_Channel_Parameters);
  var
    j, b0, b1: byte;
  begin
    TempMixer := U8(TempMixer shl 1);
    with Chan do
    begin
      if Enabled then
        with RAM do
        begin
          b0 := U8(Index[Point_In_Sample]);
          Amplitude := U8(b0 and 15);
          if Amplitude <> 0 then
          begin
            DecU8(Amplitude, Volume);
            if S8(Amplitude) < 0 then
              Amplitude := U8(0);
          end
          else if Envelope_Enabled then
            Amplitude := U8(16);
          b1 := U8(Index[Point_In_Sample + 1]);
          if b1 and 32 <> 0 then
          begin
            TempMixer := U8(TempMixer or 8);
            RegisterAY.Noise := U8(b0 and $f0 shr 3);
            if S8(b1) < 0 then
              IncU8(RegisterAY.Noise);
          end;
          if b1 and 64 <> 0 then
            TempMixer := U8(TempMixer or 1);
          j := U8(Note);
          if Ornament_Enabled then
          begin
            IncU8(j, Index[Point_In_Ornament]);
            DecS8(Ornament_Tik_Counter);
            if Ornament_Tik_Counter = 0 then
            begin
              if Index[OrnamentPointer] <> 32 then
              begin
                Ornament_Tik_Counter := S8(Index[OrnamentPointer + 1]);
                Point_In_Ornament := U16(OrnamentPointer + 2 + Index[OrnamentPointer]);
              end
              else
              begin
                Ornament_Tik_Counter := S8(Index[SamplePointer + 1]);
                Point_In_Ornament := U16(OrnamentPointer + 2 + Index[SamplePointer]);
              end;
            end
            else
              IncU16(Point_In_Ornament);
          end;
          IncU8(j, Transposit);
          if j > $5F then
            j := U8($5f);
          if b1 and 16 = 0 then
            Ton := U16(SQT_Table[j] - (U16(b1 and 15) shl 8 +
              Index[Point_In_Sample + 2]))
          else
            Ton := U16(SQT_Table[j] + (U16(b1 and 15) shl 8 +
              Index[Point_In_Sample + 2]));
          DecS8(Sample_Tik_Counter);
          if Sample_Tik_Counter = 0 then
          begin
            Sample_Tik_Counter := S8(Index[SamplePointer + 1]);
            if Index[SamplePointer] = 32 then
            begin
              Enabled := False;
              Ornament_Enabled := False;
            end;
            Point_In_Sample := U16(SamplePointer + 2 + Index[SamplePointer] * 3);
          end
          else
            IncU16(Point_In_Sample, 3);
          if gliss then
          begin
            IncU16(Ton, Current_Ton_Sliding);
            IncS16(Current_Ton_Sliding, Ton_Slide_Step);
          end;
          Ton := U16(Ton and $fff);
        end
      else
        Amplitude := U8(0);
    end;
  end;

begin

  with PlParams.SQT do
  begin
    DecU8(DelayCounter);
    if DelayCounter = 0 then
    begin
      DelayCounter := U8(Delay);
      DecU8(Lines_Counter);
      if Lines_Counter = 0 then
        with RAM do
        begin
          if Index[Positions_Pointer] = 0 then
            Positions_Pointer := U16(MarkLoop(Header.SQT_LoopPointer));
          with PlParams.SQT_C do
          begin
            if S8(Index[Positions_Pointer]) < 0 then
              b4ix0 := True
            else
              b4ix0 := False;
            Address_In_Pattern :=
              U16(READ16(U8(Index[Positions_Pointer] * 2) +
                Header.SQT_PatternsPointer));
            Lines_Counter := U8(Index[Address_In_Pattern]);
            IncU16(Address_In_Pattern);
            IncU16(Positions_Pointer);
            Volume := U8(Index[Positions_Pointer] and 15);
            if Index[Positions_Pointer] shr 4 < 9 then
              Transposit := S8(Index[Positions_Pointer] shr 4)
            else
              Transposit := S8(-(Index[Positions_Pointer] shr 4 - 9) - 1);
            IncU16(Positions_Pointer);
            ix21 := U8(0);
          end;

          if Index[Positions_Pointer] = 0 then
            Positions_Pointer := U16(MarkLoop(Header.SQT_LoopPointer));
          with PlParams.SQT_B do
          begin
            if S8(Index[Positions_Pointer]) < 0 then
              b4ix0 := True
            else
              b4ix0 := False;
            Address_In_Pattern :=
              U16(READ16(U8(Index[Positions_Pointer] * 2) +
                Header.SQT_PatternsPointer) + 1);
            IncU16(Positions_Pointer);
            Volume := U8(Index[Positions_Pointer] and 15);
            if Index[Positions_Pointer] shr 4 < 9 then
              Transposit := S8(Index[Positions_Pointer] shr 4)
            else
              Transposit := S8(-(Index[Positions_Pointer] shr 4 - 9) - 1);
            IncU16(Positions_Pointer);
            ix21 := U8(0);
          end;

          if Index[Positions_Pointer] = 0 then
            Positions_Pointer := U16(MarkLoop(Header.SQT_LoopPointer));
          with PlParams.SQT_A do
          begin
            if S8(Index[Positions_Pointer]) < 0 then
              b4ix0 := True
            else
              b4ix0 := False;
            Address_In_Pattern :=
              U16(READ16(U8(Index[Positions_Pointer] * 2) +
                Header.SQT_PatternsPointer) + 1);
            IncU16(Positions_Pointer);
            Volume := U8(Index[Positions_Pointer] and 15);
            if Index[Positions_Pointer] shr 4 < 9 then
              Transposit := S8(Index[Positions_Pointer] shr 4)
            else
              Transposit := S8(-(Index[Positions_Pointer] shr 4 - 9) - 1);
            IncU16(Positions_Pointer);
            ix21 := U8(0);
          end;

          Delay := U8(Index[Positions_Pointer]);
          DelayCounter := U8(Delay);
          IncU16(Positions_Pointer);
        end;
      PatternInterpreter(PlParams.SQT_C);
      PatternInterpreter(PlParams.SQT_B);
      PatternInterpreter(PlParams.SQT_A);
    end;
  end;
  TempMixer := U8(0);
  GetRegisters(PlParams.SQT_C);
  GetRegisters(PlParams.SQT_B);
  GetRegisters(PlParams.SQT_A);
  TempMixer := U8((-(TempMixer + 1)) and $3f);

  with PlParams.SQT_A do
  begin
    if not MixNoise then
      TempMixer := U8(TempMixer or 8);
    if not MixTon then
      TempMixer := U8(TempMixer or 1);
  end;
  with PlParams.SQT_B do
  begin
    if not MixNoise then
      TempMixer := U8(TempMixer or 16);
    if not MixTon then
      TempMixer := U8(TempMixer or 2);
  end;
  with PlParams.SQT_C do
  begin
    if not MixNoise then
      TempMixer := U8(TempMixer or 32);
    if not MixTon then
      TempMixer := U8(TempMixer or 4);
  end;
  SetMixerRegister(TempMixer);

  RegisterAY.TonA := U16(PlParams.SQT_A.Ton);
  RegisterAY.TonB := U16(PlParams.SQT_B.Ton);
  RegisterAY.TonC := U16(PlParams.SQT_C.Ton);

  SetAmplA(PlParams.SQT_A.Amplitude);
  SetAmplB(PlParams.SQT_B.Amplitude);
  SetAmplC(PlParams.SQT_C.Amplitude);

  Inc(FTick);
end;

procedure TZXTrackerEngine.GTR_Get_Registers;
var
  TempMixer: byte;

  procedure PatternInterpreter(var Chan: GTR_Channel_Parameters);
  begin
    with Chan do
    begin
      Note_Skip_Counter := S8(0);
      repeat
        with RAM do
          case Index[Address_In_Pattern] of
            0..$5f:
              begin
                Note := U8(Index[Address_In_Pattern]);
                Position_In_Sample := U8(0);
                Position_In_Ornament := U8(0);
                Enabled := True;
                IncU16(Address_In_Pattern);
                exit;
              end;
            $60..$6f:
              begin
                SamplePointer := U16(Header.GTR_SamplesPointers[Index[Address_In_Pattern] - $60]);
                Loop_Sample_Position := U8(Index[Chan.SamplePointer]);
                IncU16(SamplePointer);
                Sample_Length := U8(Index[SamplePointer]);
                IncU16(SamplePointer);
              end;
            $70..$7F:
              begin
                OrnamentPointer :=
                  U16(Header.GTR_OrnamentsPointers[Index[Address_In_Pattern] - $70]);
                Loop_Ornament_Position := U8(Index[Chan.OrnamentPointer]);
                IncU16(Chan.OrnamentPointer);
                Ornament_Length := U8(Index[Chan.OrnamentPointer]);
                IncU16(OrnamentPointer);
                Position_In_Ornament := U8(0);
                if Header.GTR_ID[3] <> #$10 then
                  Envelope_Enabled := False;
              end;
            $80..$BF:
              Note_Skip_Counter := S8(Index[Address_In_Pattern] - $80);
            $C0..$CF:
              begin
                SetEnvelopeRegister(Index[Address_In_Pattern] - $C0);
                IncU16(Address_In_Pattern);
                RegisterAY.Index[11] := U8(Index[Address_In_Pattern]);
                Envelope_Enabled := True;
              end;
            $D0..$DF:
              begin
                IncU16(Address_In_Pattern);
                exit;
              end;
            $E0:
              begin
                Enabled := False;
                if Header.GTR_ID[3] <> #$10 then
                begin
                  IncU16(Address_In_Pattern);
                  exit;
                end;
              end;
            $E1..$EF:
              Volume := U8(15 - (Index[Address_In_Pattern] - $E0))
          end;
        IncU16(Address_In_Pattern)
      until False;
    end;
  end;

  procedure GetRegisters(var Chan: GTR_Channel_Parameters);
  var
    j, b: byte;
  begin
    with Chan do
    begin
      if Enabled then
        with RAM do
        begin
         // A sample can change on a held note. Bound the retained cursor.
          if (Sample_Length <> 0) and (Position_In_Sample >= Sample_Length) then
            Position_In_Sample := Loop_Sample_Position;
          if (Ornament_Length <> 0) and (Position_In_Ornament >= Ornament_Length) then
            Position_In_Ornament := Loop_Ornament_Position;
          j := U8(Note + Index[OrnamentPointer + Position_In_Ornament]);
          if j > $5f then
            j := U8($5f);
          IncU8(Position_In_Ornament);
          if Position_In_Ornament = Ornament_Length then
            Position_In_Ornament := U8(Loop_Ornament_Position);
          Ton := U16((PT3NoteTable_ST[j] +
            READ16(SamplePointer + Position_In_Sample + 2)) and $FFF);
          b := U8(Index[SamplePointer + Position_In_Sample + 1]);
          RegisterAY.Noise :=
            U8((RegisterAY.Noise or b) and $1F);
          Amplitude := U8(Index[SamplePointer + Position_In_Sample] - Volume);
          if S8(Amplitude) < 0 then
            Amplitude := U8(0);
          Amplitude := U8(Amplitude and $F);
          if S8(b) < 0 then
            if Envelope_Enabled then
              Amplitude := U8(Amplitude or 16);
          if b and 64 <> 0 then
            TempMixer := U8(TempMixer or 64);
          if b and 32 <> 0 then
            TempMixer := U8(TempMixer or 8);
          IncU8(Position_In_Sample, 4);
          if Position_In_Sample = Sample_Length then
            Position_In_Sample := U8(Loop_Sample_Position);
        end
      else
      begin
        Amplitude := U8(0);
        TempMixer := U8(TempMixer or 8 or 64);
      end;
    end;
    TempMixer := U8(TempMixer shr 1);
  end;

begin

  with PlParams.GTR do
  begin
    DecU8(DelayCounter);
    if DelayCounter = 0 then
    begin
      DelayCounter := U8(RAM.Header.GTR_Delay);
      with PlParams.GTR_A do
      begin
        DecS8(Note_Skip_Counter);
        if Note_Skip_Counter < 0 then
        begin
          with RAM do
            while Index[Address_In_Pattern] = 255 do
            begin
              IncU8(CurrentPosition);
              if CurrentPosition = Header.GTR_NumberOfPositions then
                CurrentPosition := U8(MarkLoop(Header.GTR_LoopPosition));
              Address_In_Pattern :=
                U16(Header.GTR_PatternsPointers[Header.GTR_Positions[CurrentPosition] div 6].PatternA);
              PlParams.GTR_B.Address_In_Pattern :=
                U16(Header.GTR_PatternsPointers[Header.GTR_Positions[CurrentPosition] div 6].PatternB);
              PlParams.GTR_C.Address_In_Pattern :=
                U16(Header.GTR_PatternsPointers[Header.GTR_Positions[CurrentPosition] div 6].PatternC);
            end;
          PatternInterpreter(PlParams.GTR_A);
        end;
      end;
      with PlParams.GTR_B do
      begin
        DecS8(Note_Skip_Counter);
        if Note_Skip_Counter < 0 then
          PatternInterpreter(PlParams.GTR_B);
      end;
      with PlParams.GTR_C do
      begin
        DecS8(Note_Skip_Counter);
        if Note_Skip_Counter < 0 then
          PatternInterpreter(PlParams.GTR_C);
      end;
    end;
  end;

  TempMixer := U8(0);
  RegisterAY.Noise := U8(0);
  GetRegisters(PlParams.GTR_A);
  GetRegisters(PlParams.GTR_B);
  GetRegisters(PlParams.GTR_C);

  SetMixerRegister(TempMixer);

  RegisterAY.TonA := U16(PlParams.GTR_A.Ton);
  RegisterAY.TonB := U16(PlParams.GTR_B.Ton);
  RegisterAY.TonC := U16(PlParams.GTR_C.Ton);

  SetAmplA(PlParams.GTR_A.Amplitude);
  SetAmplB(PlParams.GTR_B.Amplitude);
  SetAmplC(PlParams.GTR_C.Amplitude);

  Inc(FTick);
end;

procedure TZXTrackerEngine.PSM_Get_Registers;

  procedure PatternInterpreter(var Chan: PSM_Channel_Parameters);
  var
    PatAddr: word;
    b: byte;
  begin
    with Chan, RAM do
    begin
      PatAddr := U16(Address_In_Pattern);
      if RetCnt <> 0 then
      begin
        DecU8(RetCnt);
        if RetCnt = 0 then
          PatAddr := U16(RetAddress);
      end;
      repeat
        case Index[PatAddr] of
          0..$5F:
            begin
              if Note < 0 then
                Note := S8(PlParams.PSM.Transposition - Index[PatAddr])
              else
                DecS8(Note, Index[PatAddr]);
              if Note < 0 then
                IncS8(Note, 96);
              VolCnt := U8(Vol);
              SmpTick := S8(0);
              DivShift := U16(0);
              LoopCnt := U8(1);
              if OrnTick < 0 then
                OrnTick := S8(OrnTick and $E0)
              else
                OrnTick := S8(OrnTick and $C0);
              if (OrnTick and $40 <> 0) and (orn >= 33) then
              begin
                if EnvType >= $b1 then
                begin
                  SetEnvelopeRegister(EnvType - $b1 + 8);
                  if EnvDiv >= $f1 then
                    RegisterAY.Envelope := U16(U16(EnvDiv and 15) shl 8)
                  else
                    RegisterAY.Envelope := U16(EnvDiv);
                  OrnTick := S8(OrnTick or $40);
                end
                else
                begin
                  b := U8(EnvType - $a1);
                  SetEnvelopeRegister(((b and 3) shl 1) or 8);
                  b := U8((b and 12) * 3 + Note);
                  if b >= 48 then
                  begin
                    DecU8(b, 48);
                    if b >= 48 then
                      DecU8(b, 48);
                  end;
                  RegisterAY.Envelope := U16(PSM_Table[b + 48]);
                end;
              end;
              IncU16(PatAddr);
              break;
            end;
          $60:
            begin
              SmpTick := S8(U8(SmpTick) or 128);
              IncU16(PatAddr);
              break;
            end;
          $61..$6f:
            Samp := U8(Index[PatAddr] - $61);
          $70..$8f:
            begin
              orn := U8(Index[PatAddr] - $70);
              OrnTick := S8(0);
            end;
          $90:
            begin
              IncU16(PatAddr);
              break;
            end;
          $91..$9f:
            Vol := U8(Index[PatAddr] - $90);
          $a0:
            OrnTick := S8(Index[PatAddr]);
          $a1..$b0:
            begin
              orn := U8(33);
              EnvType := U8(Index[PatAddr]);
              OrnTick := S8(OrnTick or $40);
            end;
          $b1..$b7:
            begin
              EnvType := U8(Index[PatAddr]);
              IncU16(PatAddr);
              EnvDiv := U8(Index[PatAddr]);
              SetEnvelopeRegister(EnvType - $b1 + 8);
              if EnvDiv >= $f1 then
                RegisterAY.Envelope := U16(U16(EnvDiv and 15) shl 8)
              else
                RegisterAY.Envelope := U16(EnvDiv);
              OrnTick := S8(OrnTick or $40);
            end;
          $b8..$f8:
            Number_Of_Notes_To_Skip := U8(Index[PatAddr] - $b7);
          $f9:
            begin
              RetAddress := U16(PatAddr + 4);
              RetCnt := U8(Index[U16(PatAddr + 3)]);
              PatAddr := U16(READ16(PatAddr + 1) - 1);
            end;
          $fa..$fb:
            orn := U8(Index[PatAddr] - $fa + 32);
        else
          begin
            IncU16(PatAddr);
            break;
          end
        end;
        IncU16(PatAddr)
      until False;
      Address_In_Pattern := U16(PatAddr);
      Note_Skip_Counter := U8(Number_Of_Notes_To_Skip);
    end;
  end;

var
  TempMixer: byte;

  procedure ChangeRegisters(var Chan: PSM_Channel_Parameters);
  var
    b, b1, b2: byte;
    w, wo, ws: word;
  begin

    with Chan, RAM do
    begin
      b := U8(Note and 127);
      b2 := U8(OrnTick);
     // 32/33 are envelope commands, not entries in the ornament table.
      if orn >= 32 then
        wo := $FFFC
      else
        wo := U16(READ16(Header.PSM_OrnamentsPointer + orn * 2));
      if OrnTick and $60 = 0 then
        IncU8(b, Index[wo + 2 + b2]);
      if S8(b) < 0 then
        b := U8(0)
      else if b > 95 then
        b := U8(95);
      Ton := U16(PSM_Table[b]);

      b2 := U8(SmpTick * 3);
      ws := U16(READ16(Header.PSM_SamplesPointer + Samp * 2));
      b := U8(Index[ws + 2 + b2]);
      b1 := U8(Index[ws + 2 + b2 + 1]);
      b2 := U8(Index[ws + 2 + b2 + 2]);

      w := U16(U16(b1 and 7) shl 8 + b2);
      if b1 and 4 <> 0 then
        w := U16(w or $f800);

      IncU16(DivShift, w);
      IncU16(Ton, DivShift);
      if S16(Ton) < 0 then
        Ton := U16(0)
      else if Ton >= 4096 then
        Ton := U16(4095);

      Amplitude := U8(b and 15);
      if OrnTick and $40 <> 0 then
        Amplitude := U8(Amplitude or 16);
      IncU8(Amplitude, VolCnt - 15);
      if (S8(Amplitude) < 0) or (S8(SmpTick) < 0) then
        Amplitude := U8(0);

      TempMixer := U8(b shr 1 and $48 or TempMixer);
      if S8(SmpTick) < 0 then
        TempMixer := U8(TempMixer or $40);

      if (S8(b) >= 0) and (Amplitude <> 0) then
        RegisterAY.Noise := U8(b1 shr 3);

      b := U8(SmpTick and 31 + 1);
      b1 := U8(Index[ws]);
      b2 := U8(Index[ws + 1]);
      if b > (b1 and 31) then
        if b2 and $e0 = 0 then
          SmpTick := S8(U8(SmpTick) or 128)
        else
        begin
          b := U8(b2 and 31);
          DecU8(LoopCnt);
          if LoopCnt = 0 then
          begin
            LoopCnt := U8(b2 shr 5);
            if b1 and $20 = 0 then
              IncU8(VolCnt, b1 shr 6)
            else
              DecU8(VolCnt, b1 shr 6 + 1);
            if S8(VolCnt) < 0 then
              VolCnt := U8(0)
            else if VolCnt > 15 then
              VolCnt := U8(15);
          end;
        end;
      SmpTick := S8(((b xor U8(SmpTick)) and 31) xor U8(SmpTick));

      b := U8(OrnTick and 31 + 1);
      b1 := U8(Index[wo]);
      b2 := U8(Index[wo + 1]);
      if b > b1 then
      begin
        if S8(b2) < 0 then
          b := U8(b2)
        else
          OrnTick := S8(OrnTick or $20);
      end;
      OrnTick := S8(((b xor U8(OrnTick)) and 31) xor U8(OrnTick));
    end;

    TempMixer := U8(TempMixer shr 1);
  end;

var
  b: byte;
begin

  Inc(FTick);

  SetAmplA(0);
  SetAmplB(0);
  SetAmplC(0);

  with PlParams.PSM do
  begin
    if Finished then
      exit;
    DecU8(DelayCounter);
    if DelayCounter = 0 then
    begin
      with PlParams.PSM_C do
      begin
        DecU8(Note_Skip_Counter);
        if Note_Skip_Counter = 0 then
          with RAM do
          begin
            if Index[Address_In_Pattern] = 255 then
            begin
              IncU8(CurrentPosition);
              b := U8(Index[Header.PSM_PositionsPointer + CurrentPosition * 2]);
              if b = 255 then
              begin
                b := U8(Index[Header.PSM_PositionsPointer + CurrentPosition * 2 + 1]);
                if b = 255 then
                begin
                  Finished := True;
                  FLooped := True;
                  exit;
                end;
                CurrentPosition := U8(MarkLoop(b));
                b := U8(Index[Header.PSM_PositionsPointer + b * 2]);
              end;
              Transposition := S8(Index[Header.PSM_PositionsPointer +
                  CurrentPosition * 2 + 1] + 48);
              Delay := U8(Index[Header.PSM_PatternsPointer + b * 7]);
              PlParams.PSM_A.Address_In_Pattern :=
                U16(READ16(Header.PSM_PatternsPointer + b * 7 + 1));
              PlParams.PSM_B.Address_In_Pattern :=
                U16(READ16(Header.PSM_PatternsPointer + b * 7 + 3));
              Address_In_Pattern :=
                U16(READ16(Header.PSM_PatternsPointer + b * 7 + 5));
              PlParams.PSM_A.RetCnt := U8(0);
              PlParams.PSM_B.RetCnt := U8(0);
              RetCnt := U8(0);
              PlParams.PSM_A.Note_Skip_Counter := U8(1);
              PlParams.PSM_B.Note_Skip_Counter := U8(1);
              PlParams.PSM_A.Note := S8(U8(PlParams.PSM_A.Note) or 128);
              PlParams.PSM_B.Note := S8(U8(PlParams.PSM_B.Note) or 128);
              Note := S8(U8(Note) or 128);
            end;
            PatternInterpreter(PlParams.PSM_C);
          end;
      end;
      with PlParams.PSM_B do
      begin
        DecU8(Note_Skip_Counter);
        if Note_Skip_Counter = 0 then
          PatternInterpreter(PlParams.PSM_B);
      end;
      with PlParams.PSM_A do
      begin
        DecU8(Note_Skip_Counter);
        if Note_Skip_Counter = 0 then
          PatternInterpreter(PlParams.PSM_A);
      end;
      DelayCounter := U8(Delay);
    end;
    TempMixer := U8(0);
    ChangeRegisters(PlParams.PSM_A);
    ChangeRegisters(PlParams.PSM_B);
    ChangeRegisters(PlParams.PSM_C);

    SetMixerRegister(TempMixer);

    RegisterAY.TonA := U16(PlParams.PSM_A.Ton);
    RegisterAY.TonB := U16(PlParams.PSM_B.Ton);
    RegisterAY.TonC := U16(PlParams.PSM_C.Ton);

    SetAmplA(PlParams.PSM_A.Amplitude);
    SetAmplB(PlParams.PSM_B.Amplitude);
    SetAmplC(PlParams.PSM_C.Amplitude);
  end;
end;

end.

