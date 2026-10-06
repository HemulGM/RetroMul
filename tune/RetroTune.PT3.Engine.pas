unit RetroTune.PT3.Engine;

{$B-}

interface

uses
  System.SysUtils;

type
  Envelope = record
    wrd: Word;
    function GetLo: Byte;
    function GetHi: Byte;
    procedure SetLo(Value: Byte);
    procedure SetHi(Value: Byte);
    property lo: Byte read GetLo write SetLo;
    property hi: Byte read GetHi write SetHi;
  end;

  Module = record
    Index: TBytes;
    PT3_MusicName: array[0..98] of Byte;
    PT3_TonTableId: Byte;
    PT3_Delay: Byte;
    PT3_NumberOfPositions: Byte;
    PT3_LoopPosition: Byte;
    PT3_PatternsPointer: Word;
    PT3_SamplesPointers: array[0..31] of Word;
    PT3_OrnamentsPointers: array[0..15] of Word;
    PT3_PositionList: array[0..255] of Byte;
  end;

  TPlConsts = record
    RAM: Module;
    Global_Tick_Counter: Cardinal;
    TS: Byte;
    Version: Byte;
    Length: Cardinal;
  end;

  PT3_Channel_Parameters = record
    Address_In_Pattern: Word;
    OrnamentPointer: Word;
    SamplePointer: Word;
    Ton: Word;
    Loop_Ornament_Position: Byte;
    Ornament_Length: Byte;
    Position_In_Ornament: Byte;
    Loop_Sample_Position: Byte;
    Sample_Length: Byte;
    Position_In_Sample: Byte;
    Volume: Byte;
    Number_Of_Notes_To_Skip: Byte;
    Note: Byte;
    Slide_To_Note: Byte;
    Amplitude: Byte;
    Envelope_Enabled: Boolean;
    Enabled: Boolean;
    SimpleGliss: Boolean;
    Current_Amplitude_Sliding: SmallInt;
    Current_Noise_Sliding: SmallInt;
    Current_Envelope_Sliding: SmallInt;
    Ton_Slide_Count: SmallInt;
    Current_OnOff: SmallInt;
    OnOff_Delay: SmallInt;
    OffOn_Delay: SmallInt;
    Ton_Slide_Delay: SmallInt;
    Current_Ton_Sliding: SmallInt;
    Ton_Accumulator: SmallInt;
    Ton_Slide_Step: SmallInt;
    Ton_Delta: SmallInt;
    Note_Skip_Counter: ShortInt;
  end;

  PT3_Parameters = record
    Env_Base: Envelope;
    Cur_Env_Slide: SmallInt;
    Env_Slide_Add: SmallInt;
    Cur_Env_Delay: ShortInt;
    Env_Delay: ShortInt;
    Noise_Base: Byte;
    Delay: Byte;
    AddToNoise: Byte;
    DelayCounter: Byte;
    CurrentPosition: Byte;
  end;

  TPlParams = record
    PT3: PT3_Parameters;
    PT3_: array[0..2] of PT3_Channel_Parameters;
    AY: array[0..13] of Byte;
  end;

  TPT3Registers = array[0..13] of Byte;

  TPT3Engine = class
  private
    FConsts: array[0..2] of TPlConsts;
    FParams: array[0..2] of TPlParams;
    FLooped: array[0..2] of Boolean;
    FForcedTable: Integer;
    FTempMixer: Byte;
    FAddToEnv: SmallInt;
    FChipCount: Integer;
    function GetNoteFreq(j: Byte; ch: Integer): Word;
    procedure PatternInterpreter(var Chan: PT3_Channel_Parameters; ch: Integer);
    procedure ChangeRegisters(var Chan: PT3_Channel_Parameters; ch: Integer);
    procedure PlayTick(ch: Integer);
    procedure RestartMusic(ch: Integer);
  public
    constructor Create(const Data: TBytes);
    procedure Reset;
    procedure Tick;
    function Registers(Chip: Integer): TPT3Registers;
    function Looped: Boolean;
    function Header: TBytes;
    property ChipCount: Integer read FChipCount;
  end;

implementation

function Wrap8(Value: Int64): Byte; inline;
begin
  Result := Byte(Value and $FF);
end;

function Signed8(Value: Int64): ShortInt; inline;
begin
  Result := ShortInt((Value and $7F) - (Value and $80));
end;

function Wrap16(Value: Int64): Word; inline;
begin
  Result := Word(Value and $FFFF);
end;

function Signed16(Value: Int64): SmallInt; inline;
begin
  Result := SmallInt((Value and $7FFF) - (Value and $8000));
end;

function Wrap32(Value: Int64): Cardinal; inline;
begin
  Result := Cardinal(Value and $FFFFFFFF);
end;

function SAR(Value: Integer; Bits: Integer): Integer; inline;
begin
  if Bits = 0 then
    Exit(Value);
  Result := Integer(Cardinal(Value) shr Bits);
  if Value < 0 then
    Result := Result or Integer($FFFFFFFF shl (32 - Bits));
end;

function Choose(Condition: Boolean; A, B: Integer): Integer; inline;
begin
  if Condition then
    Result := A
  else
    Result := B;
end;

function ReadWord(const Data: TBytes; Offset: Int64): Word;
begin
  if (Offset < 0) or (Offset > Length(Data) - 2) then
    raise EArgumentException.Create('Truncated PT3 word');
  Result := Word(Data[Offset]) + Word(Data[Offset + 1]) * 256;
end;

function Envelope.GetLo: Byte;
begin
  Result := wrd and $FF;
end;

function Envelope.GetHi: Byte;
begin
  Result := wrd shr 8;
end;

procedure Envelope.SetLo(Value: Byte);
begin
  wrd := (wrd and $FF00) or Value;
end;

procedure Envelope.SetHi(Value: Byte);
begin
  wrd := (wrd and $FF) or (Word(Value) shl 8);
end;

const
  PT3VolumeTable_33_34: array[0..15] of array[0..15] of Byte = (
    (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0),
    (0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1),
    (0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2),
    (0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3),
    (0, 0, 0, 0, 1, 1, 1, 2, 2, 2, 3, 3, 3, 4, 4, 4),
    (0, 0, 0, 1, 1, 1, 2, 2, 3, 3, 3, 4, 4, 4, 5, 5),
    (0, 0, 0, 1, 1, 2, 2, 3, 3, 3, 4, 4, 5, 5, 6, 6),
    (0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7),
    (0, 0, 1, 1, 2, 2, 3, 3, 4, 5, 5, 6, 6, 7, 7, 8),
    (0, 0, 1, 1, 2, 3, 3, 4, 5, 5, 6, 6, 7, 8, 8, 9),
    (0, 0, 1, 2, 2, 3, 4, 4, 5, 6, 6, 7, 8, 8, 9, 10),
    (0, 0, 1, 2, 3, 3, 4, 5, 6, 6, 7, 8, 9, 9, 10, 11),
    (0, 0, 1, 2, 3, 4, 4, 5, 6, 7, 8, 8, 9, 11, 11, 12),
    (0, 0, 1, 2, 3, 4, 5, 6, 7, 7, 8, 9, 10, 11, 12, 13),
    (0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14),
    (0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15));
  PT3VolumeTable_35: array[0..15] of array[0..15] of Byte = (
    (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0),
    (0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1),
    (0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2),
    (0, 0, 0, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 3, 3, 3),
    (0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4),
    (0, 0, 1, 1, 1, 2, 2, 2, 3, 3, 3, 4, 4, 4, 5, 5),
    (0, 0, 1, 1, 2, 2, 2, 3, 3, 4, 4, 4, 5, 5, 6, 6),
    (0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7),
    (0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8),
    (0, 1, 1, 2, 2, 3, 4, 4, 5, 5, 6, 7, 7, 8, 8, 9),
    (0, 1, 1, 2, 3, 3, 4, 5, 5, 6, 7, 7, 8, 9, 9, 10),
    (0, 1, 1, 2, 3, 4, 4, 5, 6, 7, 7, 8, 9, 10, 10, 11),
    (0, 1, 2, 2, 3, 4, 5, 6, 6, 7, 8, 9, 10, 10, 11, 12),
    (0, 1, 2, 3, 3, 4, 5, 6, 7, 8, 9, 10, 10, 11, 12, 13),
    (0, 1, 2, 3, 4, 5, 6, 7, 7, 8, 9, 10, 11, 12, 13, 14),
    (0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15));
  PT3NoteTable_PT_33_34r: array[0..95] of Word = (
    $C21, $B73, $ACE, $A33, $9A0, $916, $893, $818,
    $7A4, $736, $6CE, $66D, $610, $5B9, $567, $519,
    $4D0, $48B, $449, $40C, $3D2, $39B, $367, $336,
    $308, $2DC, $2B3, $28C, $268, $245, $224, $206,
    $1E9, $1CD, $1B3, $19B, $184, $16E, $159, $146,
    $134, $122, $112, $103, $0F4, $0E6, $0D9, $0CD,
    $0C2, $0B7, $0AC, $0A3, $09A, $091, $089, $081,
    $07A, $073, $06C, $066, $061, $05B, $056, $051,
    $04D, $048, $044, $040, $03D, $039, $036, $033,
    $030, $02D, $02B, $028, $026, $024, $022, $020,
    $01E, $01C, $01B, $019, $018, $016, $015, $014,
    $013, $012, $011, $010, $00F, $00E, $00D, $00C);
  PT3NoteTable_PT_34_35: array[0..95] of Word = (
    $C22, $B73, $ACF, $A33, $9A1, $917, $894, $819,
    $7A4, $737, $6CF, $66D, $611, $5BA, $567, $51A,
    $4D0, $48B, $44A, $40C, $3D2, $39B, $367, $337,
    $308, $2DD, $2B4, $28D, $268, $246, $225, $206,
    $1E9, $1CE, $1B4, $19B, $184, $16E, $15A, $146,
    $134, $123, $112, $103, $0F5, $0E7, $0DA, $0CE,
    $0C2, $0B7, $0AD, $0A3, $09A, $091, $089, $082,
    $07A, $073, $06D, $067, $061, $05C, $056, $052,
    $04D, $049, $045, $041, $03D, $03A, $036, $033,
    $031, $02E, $02B, $029, $027, $024, $022, $020,
    $01F, $01D, $01B, $01A, $018, $017, $016, $014,
    $013, $012, $011, $010, $00F, $00E, $00D, $00C);
  PT3NoteTable_ST: array[0..95] of Word = (
    $EF8, $E10, $D60, $C80, $BD8, $B28, $A88, $9F0,
    $960, $8E0, $858, $7E0, $77C, $708, $6B0, $640,
    $5EC, $594, $544, $4F8, $4B0, $470, $42C, $3FD,
    $3BE, $384, $358, $320, $2F6, $2CA, $2A2, $27C,
    $258, $238, $216, $1F8, $1DF, $1C2, $1AC, $190,
    $17B, $165, $151, $13E, $12C, $11C, $10A, $0FC,
    $0EF, $0E1, $0D6, $0C8, $0BD, $0B2, $0A8, $09F,
    $096, $08E, $085, $07E, $077, $070, $06B, $064,
    $05E, $059, $054, $04F, $04B, $047, $042, $03F,
    $03B, $038, $035, $032, $02F, $02C, $02A, $027,
    $025, $023, $021, $01F, $01D, $01C, $01A, $019,
    $017, $016, $015, $013, $012, $011, $010, $00F);
  PT3NoteTable_ASM_34r: array[0..95] of Word = (
    $D3E, $C80, $BCC, $B22, $A82, $9EC, $95C, $8D6,
    $858, $7E0, $76E, $704, $69F, $640, $5E6, $591,
    $541, $4F6, $4AE, $46B, $42C, $3F0, $3B7, $382,
    $34F, $320, $2F3, $2C8, $2A1, $27B, $257, $236,
    $216, $1F8, $1DC, $1C1, $1A8, $190, $179, $164,
    $150, $13D, $12C, $11B, $10B, $0FC, $0EE, $0E0,
    $0D4, $0C8, $0BD, $0B2, $0A8, $09F, $096, $08D,
    $085, $07E, $077, $070, $06A, $064, $05E, $059,
    $054, $050, $04B, $047, $043, $03F, $03C, $038,
    $035, $032, $02F, $02D, $02A, $028, $026, $024,
    $022, $020, $01E, $01D, $01B, $01A, $019, $018,
    $015, $014, $013, $012, $011, $010, $00F, $00E);
  PT3NoteTable_ASM_34_35: array[0..95] of Word = (
    $D10, $C55, $BA4, $AFC, $A5F, $9CA, $93D, $8B8,
    $83B, $7C5, $755, $6EC, $688, $62A, $5D2, $57E,
    $52F, $4E5, $49E, $45C, $41D, $3E2, $3AB, $376,
    $344, $315, $2E9, $2BF, $298, $272, $24F, $22E,
    $20F, $1F1, $1D5, $1BB, $1A2, $18B, $174, $160,
    $14C, $139, $128, $117, $107, $0F9, $0EB, $0DD,
    $0D1, $0C5, $0BA, $0B0, $0A6, $09D, $094, $08C,
    $084, $07C, $075, $06F, $069, $063, $05D, $058,
    $053, $04E, $04A, $046, $042, $03E, $03B, $037,
    $034, $031, $02F, $02C, $029, $027, $025, $023,
    $021, $01F, $01D, $01C, $01A, $019, $017, $016,
    $015, $014, $012, $011, $010, $00F, $00E, $00D);
  PT3NoteTable_REAL_34r: array[0..95] of Word = (
    $CDA, $C22, $B73, $ACF, $A33, $9A1, $917, $894,
    $819, $7A4, $737, $6CF, $66D, $611, $5BA, $567,
    $51A, $4D0, $48B, $44A, $40C, $3D2, $39B, $367,
    $337, $308, $2DD, $2B4, $28D, $268, $246, $225,
    $206, $1E9, $1CE, $1B4, $19B, $184, $16E, $15A,
    $146, $134, $123, $113, $103, $0F5, $0E7, $0DA,
    $0CE, $0C2, $0B7, $0AD, $0A3, $09A, $091, $089,
    $082, $07A, $073, $06D, $067, $061, $05C, $056,
    $052, $04D, $049, $045, $041, $03D, $03A, $036,
    $033, $031, $02E, $02B, $029, $027, $024, $022,
    $020, $01F, $01D, $01B, $01A, $018, $017, $016,
    $014, $013, $012, $011, $010, $00F, $00E, $00D);
  PT3NoteTable_REAL_34_35: array[0..95] of Word = (
    $CDA, $C22, $B73, $ACF, $A33, $9A1, $917, $894,
    $819, $7A4, $737, $6CF, $66D, $611, $5BA, $567,
    $51A, $4D0, $48B, $44A, $40C, $3D2, $39B, $367,
    $337, $308, $2DD, $2B4, $28D, $268, $246, $225,
    $206, $1E9, $1CE, $1B4, $19B, $184, $16E, $15A,
    $146, $134, $123, $112, $103, $0F5, $0E7, $0DA,
    $0CE, $0C2, $0B7, $0AD, $0A3, $09A, $091, $089,
    $082, $07A, $073, $06D, $067, $061, $05C, $056,
    $052, $04D, $049, $045, $041, $03D, $03A, $036,
    $033, $031, $02E, $02B, $029, $027, $024, $022,
    $020, $01F, $01D, $01B, $01A, $018, $017, $016,
    $014, $013, $012, $011, $010, $00F, $00E, $00D);

function TPT3Engine.GetNoteFreq(j: Byte; ch: Integer): Word;
begin
  if (FForcedTable >= 0) then
  begin
    case FForcedTable of
      0:
        begin
          Exit(PT3NoteTable_PT_33_34r[j]);
        end;
      1:
        begin
          Exit(PT3NoteTable_PT_34_35[j]);
        end;
      2:
        begin
          Exit(PT3NoteTable_ST[j]);
        end;
      3:
        begin
          Exit(PT3NoteTable_ASM_34r[j]);
        end;
      4:
        begin
          Exit(PT3NoteTable_ASM_34_35[j]);
        end;
      5:
        begin
          Exit(PT3NoteTable_REAL_34r[j]);
        end;
    else
      begin
        Exit(PT3NoteTable_REAL_34_35[j]);
      end;
    end;
  end
  else
  begin
    case FConsts[ch].RAM.PT3_TonTableId of
      0:
        begin
          if (FConsts[ch].Version <= 3) then
          begin
            Exit(PT3NoteTable_PT_33_34r[j]);
          end
          else
          begin
            Exit(PT3NoteTable_PT_34_35[j]);
          end;
        end;
      1:
        begin
          Exit(PT3NoteTable_ST[j]);
        end;
      2:
        begin
          if (FConsts[ch].Version <= 3) then
          begin
            Exit(PT3NoteTable_ASM_34r[j]);
          end
          else
          begin
            Exit(PT3NoteTable_ASM_34_35[j]);
          end;
        end;
    else
      begin
        if (FConsts[ch].Version <= 3) then
        begin
          Exit(PT3NoteTable_REAL_34r[j]);
        end
        else
        begin
          Exit(PT3NoteTable_REAL_34_35[j]);
        end;
      end;
    end;
  end;
  Exit(0);
end;

procedure TPT3Engine.PatternInterpreter(var Chan: PT3_Channel_Parameters; ch: Integer);
var
  idx: TBytes;
  quit: Boolean;
  Flag1: Byte;
  Flag2: Byte;
  Flag3: Byte;
  Flag4: Byte;
  Flag5: Byte;
  Flag8: Byte;
  Flag9: Byte;
  counter: Byte;
  b: Byte;
  PrNote: Integer;
  PrSliding: Integer;
  op: Byte;
  SideEffect0: Word;
  SideEffect1: Word;
  SideEffect2: Word;
  SideEffect3: Word;
  SideEffect4: Word;
  SideEffect5: Word;
  SideEffect6: Word;
  SideEffect7: Word;
  SideEffect8: Word;
  SideEffect9: Word;
  SideEffect10: Word;
  SideEffect11: Word;
  SideEffect12: Word;
  SideEffect13: Word;
  SideEffect14: Word;
  SideEffect15: Word;
  SideEffect16: Word;
  SideEffect17: Word;
  SideEffect18: Word;
  SideEffect19: Word;
  SideEffect20: Byte;
  SideEffect21: Byte;
  SideEffect22: Byte;
  SideEffect23: Byte;
  SideEffect24: Byte;
  SideEffect25: Byte;
  SideEffect26: Byte;
  SideEffect27: Word;
  SideEffect28: Word;
  SideEffect29: Word;
  SideEffect30: Word;
  SideEffect31: Word;
  SideEffect32: Word;
  SideEffect33: Word;
  SideEffect34: Word;
  CommandCount: Integer;
begin
  CommandCount := 0;
  idx := FConsts[ch].RAM.Index;
  Flag1 := Wrap8(0);
  Flag2 := Wrap8(0);
  Flag3 := Wrap8(0);
  Flag4 := Wrap8(0);
  Flag5 := Wrap8(0);
  Flag8 := Wrap8(0);
  Flag9 := Wrap8(0);
  Wrap8(0);
  PrNote := Chan.Note;
  PrSliding := Chan.Current_Ton_Sliding;
  quit := False;
  counter := Wrap8(0);
  while (not quit) do
  begin
    Inc(CommandCount);
    if CommandCount > 1024 then
      raise EArgumentException.Create('PT3 row has no terminator');
    op := Wrap8(idx[Chan.Address_In_Pattern]);
    if (op >= $f0) then
    begin
      Chan.OrnamentPointer := Wrap16(FConsts[ch].RAM.PT3_OrnamentsPointers[(Int64(op) - Int64($f0))]);
      SideEffect0 := Chan.OrnamentPointer;
      Chan.OrnamentPointer := Wrap16((Chan.OrnamentPointer + 1));
      Chan.Loop_Ornament_Position := Wrap8(idx[SideEffect0]);
      SideEffect1 := Chan.OrnamentPointer;
      Chan.OrnamentPointer := Wrap16((Chan.OrnamentPointer + 1));
      Chan.Ornament_Length := Wrap8(idx[SideEffect1]);
      Chan.Position_In_Ornament := Wrap8(0);
      Chan.Address_In_Pattern := Wrap16((Chan.Address_In_Pattern + 1));
      SideEffect2 := Chan.Address_In_Pattern;
      Chan.SamplePointer := Wrap16(FConsts[ch].RAM.PT3_SamplesPointers[(idx[SideEffect2] div 2)]);
      SideEffect3 := Chan.SamplePointer;
      Chan.SamplePointer := Wrap16((Chan.SamplePointer + 1));
      Chan.Loop_Sample_Position := Wrap8(idx[SideEffect3]);
      SideEffect4 := Chan.SamplePointer;
      Chan.SamplePointer := Wrap16((Chan.SamplePointer + 1));
      Chan.Sample_Length := Wrap8(idx[SideEffect4]);
      Chan.Envelope_Enabled := False;
    end
    else
    begin
      if (op >= $d1) then
      begin
        Chan.SamplePointer := Wrap16(FConsts[ch].RAM.PT3_SamplesPointers[(Int64(op) - Int64($d0))]);
        SideEffect5 := Chan.SamplePointer;
        Chan.SamplePointer := Wrap16((Chan.SamplePointer + 1));
        Chan.Loop_Sample_Position := Wrap8(idx[SideEffect5]);
        SideEffect6 := Chan.SamplePointer;
        Chan.SamplePointer := Wrap16((Chan.SamplePointer + 1));
        Chan.Sample_Length := Wrap8(idx[SideEffect6]);
      end
      else
      begin
        if (op = $d0) then
        begin
          quit := True;
        end
        else
        begin
          if (op >= $c1) then
          begin
            Chan.Volume := Wrap8((Int64(op) - Int64($c0)));
          end
          else
          begin
            if (op = $c0) then
            begin
              Chan.Position_In_Sample := Wrap8(0);
              Chan.Current_Amplitude_Sliding := Signed16(0);
              Chan.Current_Noise_Sliding := Signed16(0);
              Chan.Current_Envelope_Sliding := Signed16(0);
              Chan.Position_In_Ornament := Wrap8(0);
              Chan.Ton_Slide_Count := Signed16(0);
              Chan.Current_Ton_Sliding := Signed16(0);
              Chan.Ton_Accumulator := Signed16(0);
              Chan.Current_OnOff := Signed16(0);
              Chan.Enabled := False;
              quit := True;
            end
            else
            begin
              if (op >= $b2) then
              begin
                Chan.Envelope_Enabled := True;
                FParams[ch].AY[13] := Wrap8((Int64(op) - Int64($b1)));
                Chan.Address_In_Pattern := Wrap16((Chan.Address_In_Pattern + 1));
                SideEffect7 := Chan.Address_In_Pattern;
                FParams[ch].PT3.Env_Base.hi := Wrap8(idx[SideEffect7]);
                Chan.Address_In_Pattern := Wrap16((Chan.Address_In_Pattern + 1));
                SideEffect8 := Chan.Address_In_Pattern;
                FParams[ch].PT3.Env_Base.lo := Wrap8(idx[SideEffect8]);
                Chan.Position_In_Ornament := Wrap8(0);
                FParams[ch].PT3.Cur_Env_Slide := Signed16(0);
                FParams[ch].PT3.Cur_Env_Delay := Signed8(0);
              end
              else
              begin
                if (op = $b1) then
                begin
                  Chan.Address_In_Pattern := Wrap16((Chan.Address_In_Pattern + 1));
                  SideEffect9 := Chan.Address_In_Pattern;
                  Chan.Number_Of_Notes_To_Skip := Wrap8(idx[SideEffect9]);
                end
                else
                begin
                  if (op = $b0) then
                  begin
                    Chan.Envelope_Enabled := False;
                    Chan.Position_In_Ornament := Wrap8(0);
                  end
                  else
                  begin
                    if (op >= $50) then
                    begin
                      Chan.Note := Wrap8((Int64(op) - Int64($50)));
                      Chan.Position_In_Sample := Wrap8(0);
                      Chan.Current_Amplitude_Sliding := Signed16(0);
                      Chan.Current_Noise_Sliding := Signed16(0);
                      Chan.Current_Envelope_Sliding := Signed16(0);
                      Chan.Position_In_Ornament := Wrap8(0);
                      Chan.Ton_Slide_Count := Signed16(0);
                      Chan.Current_Ton_Sliding := Signed16(0);
                      Chan.Ton_Accumulator := Signed16(0);
                      Chan.Current_OnOff := Signed16(0);
                      Chan.Enabled := True;
                      quit := True;
                    end
                    else
                    begin
                      if (op >= $40) then
                      begin
                        Chan.OrnamentPointer := Wrap16(FConsts[ch].RAM.PT3_OrnamentsPointers[(Int64(op) - Int64($40))]);
                        SideEffect10 := Chan.OrnamentPointer;
                        Chan.OrnamentPointer := Wrap16((Chan.OrnamentPointer + 1));
                        Chan.Loop_Ornament_Position := Wrap8(idx[SideEffect10]);
                        SideEffect11 := Chan.OrnamentPointer;
                        Chan.OrnamentPointer := Wrap16((Chan.OrnamentPointer + 1));
                        Chan.Ornament_Length := Wrap8(idx[SideEffect11]);
                        Chan.Position_In_Ornament := Wrap8(0);
                      end
                      else
                      begin
                        if (op >= $20) then
                        begin
                          FParams[ch].PT3.Noise_Base := Wrap8((Int64(op) - Int64($20)));
                        end
                        else
                        begin
                          if (op >= $11) then
                          begin
                            FParams[ch].AY[13] := Wrap8((Int64(op) - Int64($10)));
                            Chan.Address_In_Pattern := Wrap16((Chan.Address_In_Pattern + 1));
                            SideEffect12 := Chan.Address_In_Pattern;
                            FParams[ch].PT3.Env_Base.hi := Wrap8(idx[SideEffect12]);
                            Chan.Address_In_Pattern := Wrap16((Chan.Address_In_Pattern + 1));
                            SideEffect13 := Chan.Address_In_Pattern;
                            FParams[ch].PT3.Env_Base.lo := Wrap8(idx[SideEffect13]);
                            FParams[ch].PT3.Cur_Env_Slide := Signed16(0);
                            FParams[ch].PT3.Cur_Env_Delay := Signed8(0);
                            Chan.Envelope_Enabled := True;
                            Chan.Address_In_Pattern := Wrap16((Chan.Address_In_Pattern + 1));
                            SideEffect14 := Chan.Address_In_Pattern;
                            Chan.SamplePointer := Wrap16(FConsts[ch].RAM.PT3_SamplesPointers[(idx[SideEffect14] div 2)]);
                            SideEffect15 := Chan.SamplePointer;
                            Chan.SamplePointer := Wrap16((Chan.SamplePointer + 1));
                            Chan.Loop_Sample_Position := Wrap8(idx[SideEffect15]);
                            SideEffect16 := Chan.SamplePointer;
                            Chan.SamplePointer := Wrap16((Chan.SamplePointer + 1));
                            Chan.Sample_Length := Wrap8(idx[SideEffect16]);
                            Chan.Position_In_Ornament := Wrap8(0);
                          end
                          else
                          begin
                            if (op = $10) then
                            begin
                              Chan.Envelope_Enabled := False;
                              Chan.Address_In_Pattern := Wrap16((Chan.Address_In_Pattern + 1));
                              SideEffect17 := Chan.Address_In_Pattern;
                              Chan.SamplePointer := Wrap16(FConsts[ch].RAM.PT3_SamplesPointers[(idx[SideEffect17] div 2)]);
                              SideEffect18 := Chan.SamplePointer;
                              Chan.SamplePointer := Wrap16((Chan.SamplePointer + 1));
                              Chan.Loop_Sample_Position := Wrap8(idx[SideEffect18]);
                              SideEffect19 := Chan.SamplePointer;
                              Chan.SamplePointer := Wrap16((Chan.SamplePointer + 1));
                              Chan.Sample_Length := Wrap8(idx[SideEffect19]);
                              Chan.Position_In_Ornament := Wrap8(0);
                            end
                            else
                            begin
                              if (op = 9) then
                              begin
                                counter := Wrap8((counter + 1));
                                SideEffect20 := counter;
                                Flag9 := Wrap8(SideEffect20);
                              end
                              else
                              begin
                                if (op = 8) then
                                begin
                                  counter := Wrap8((counter + 1));
                                  SideEffect21 := counter;
                                  Flag8 := Wrap8(SideEffect21);
                                end
                                else
                                begin
                                  if (op = 5) then
                                  begin
                                    counter := Wrap8((counter + 1));
                                    SideEffect22 := counter;
                                    Flag5 := Wrap8(SideEffect22);
                                  end
                                  else
                                  begin
                                    if (op = 4) then
                                    begin
                                      counter := Wrap8((counter + 1));
                                      SideEffect23 := counter;
                                      Flag4 := Wrap8(SideEffect23);
                                    end
                                    else
                                    begin
                                      if (op = 3) then
                                      begin
                                        counter := Wrap8((counter + 1));
                                        SideEffect24 := counter;
                                        Flag3 := Wrap8(SideEffect24);
                                      end
                                      else
                                      begin
                                        if (op = 2) then
                                        begin
                                          counter := Wrap8((counter + 1));
                                          SideEffect25 := counter;
                                          Flag2 := Wrap8(SideEffect25);
                                        end
                                        else
                                        begin
                                          if (op = 1) then
                                          begin
                                            counter := Wrap8((counter + 1));
                                            SideEffect26 := counter;
                                            Flag1 := Wrap8(SideEffect26);
                                          end;
                                        end;
                                      end;
                                    end;
                                  end;
                                end;
                              end;
                            end;
                          end;
                        end;
                      end;
                    end;
                  end;
                end;
              end;
            end;
          end;
        end;
      end;
    end;
    Chan.Address_In_Pattern := Wrap16((Chan.Address_In_Pattern + 1));
  end;
  while (counter > 0) do
  begin
    if (counter = Flag1) then
    begin
      SideEffect27 := Chan.Address_In_Pattern;
      Chan.Address_In_Pattern := Wrap16((Chan.Address_In_Pattern + 1));
      Chan.Ton_Slide_Delay := Signed16(idx[SideEffect27]);
      Chan.Ton_Slide_Count := Signed16(Chan.Ton_Slide_Delay);
      Chan.Ton_Slide_Step := Signed16(ReadWord(idx, Chan.Address_In_Pattern));
      Chan.SimpleGliss := True;
      Chan.Current_OnOff := Signed16(0);
      if ((Chan.Ton_Slide_Count = 0) and (FConsts[ch].Version >= 7)) then
      begin
        Chan.Ton_Slide_Count := Signed16((Chan.Ton_Slide_Count + 1));
      end;
      Chan.Address_In_Pattern := Wrap16((Chan.Address_In_Pattern + 2));
    end
    else
    begin
      if (counter = Flag2) then
      begin
        Chan.SimpleGliss := False;
        Chan.Current_OnOff := Signed16(0);
        SideEffect28 := Chan.Address_In_Pattern;
        Chan.Address_In_Pattern := Wrap16((Chan.Address_In_Pattern + 1));
        Chan.Ton_Slide_Delay := Signed16(idx[SideEffect28]);
        Chan.Ton_Slide_Count := Signed16(Chan.Ton_Slide_Delay);
        Chan.Ton_Slide_Step := Signed16(abs(Signed16(ReadWord(idx, (Int64(Chan.Address_In_Pattern) + Int64(2))))));
        Chan.Ton_Delta := Signed16((Int64(GetNoteFreq(Wrap8(Chan.Note), ch)) - Int64(GetNoteFreq(Wrap8(PrNote), ch))));
        Chan.Slide_To_Note := Wrap8(Chan.Note);
        Chan.Note := Wrap8(PrNote);
        if (FConsts[ch].Version >= 6) then
        begin
          Chan.Current_Ton_Sliding := Signed16(PrSliding);
        end;
        if ((Int64(Chan.Ton_Delta) - Int64(Chan.Current_Ton_Sliding)) < 0) then
        begin
          Chan.Ton_Slide_Step := Signed16((-Int64(Chan.Ton_Slide_Step)));
        end;
        Chan.Address_In_Pattern := Wrap16((Chan.Address_In_Pattern + 4));
      end
      else
      begin
        if (counter = Flag3) then
        begin
          SideEffect29 := Chan.Address_In_Pattern;
          Chan.Address_In_Pattern := Wrap16((Chan.Address_In_Pattern + 1));
          Chan.Position_In_Sample := Wrap8(idx[SideEffect29]);
        end
        else
        begin
          if (counter = Flag4) then
          begin
            SideEffect30 := Chan.Address_In_Pattern;
            Chan.Address_In_Pattern := Wrap16((Chan.Address_In_Pattern + 1));
            Chan.Position_In_Ornament := Wrap8(idx[SideEffect30]);
          end
          else
          begin
            if (counter = Flag5) then
            begin
              SideEffect31 := Chan.Address_In_Pattern;
              Chan.Address_In_Pattern := Wrap16((Chan.Address_In_Pattern + 1));
              Chan.OnOff_Delay := Signed16(idx[SideEffect31]);
              SideEffect32 := Chan.Address_In_Pattern;
              Chan.Address_In_Pattern := Wrap16((Chan.Address_In_Pattern + 1));
              Chan.OffOn_Delay := Signed16(idx[SideEffect32]);
              Chan.Current_OnOff := Signed16(Chan.OnOff_Delay);
              Chan.Ton_Slide_Count := Signed16(0);
              Chan.Current_Ton_Sliding := Signed16(0);
            end
            else
            begin
              if (counter = Flag8) then
              begin
                SideEffect33 := Chan.Address_In_Pattern;
                Chan.Address_In_Pattern := Wrap16((Chan.Address_In_Pattern + 1));
                FParams[ch].PT3.Env_Delay := Signed8(idx[SideEffect33]);
                FParams[ch].PT3.Cur_Env_Delay := Signed8(FParams[ch].PT3.Env_Delay);
                FParams[ch].PT3.Env_Slide_Add := Signed16(ReadWord(idx, Chan.Address_In_Pattern));
                Chan.Address_In_Pattern := Wrap16((Chan.Address_In_Pattern + 2));
              end
              else
              begin
                if (counter = Flag9) then
                begin
                  SideEffect34 := Chan.Address_In_Pattern;
                  Chan.Address_In_Pattern := Wrap16((Chan.Address_In_Pattern + 1));
                  b := Wrap8(idx[SideEffect34]);
                  FParams[ch].PT3.Delay := Wrap8(b);
                  if (False and (FConsts[(Int64(ch) + Int64(1))].TS <> $20)) then
                  begin
                    FParams[ch].PT3.Delay := Wrap8(b);
                    FParams[ch].PT3.DelayCounter := Wrap8(b);
                    FParams[(Int64(ch) + Int64(1))].PT3.Delay := Wrap8(b);
                  end;
                end;
              end;
            end;
          end;
        end;
      end;
    end;
    counter := Wrap8((counter + -1));
  end;
  Chan.Note_Skip_Counter := Signed8(Chan.Number_Of_Notes_To_Skip);
end;

procedure TPT3Engine.ChangeRegisters(var Chan: PT3_Channel_Parameters; ch: Integer);
var
  j: Byte;
  b0: Byte;
  b1: Byte;
  w: SmallInt;
  idx: TBytes;
begin
  idx := FConsts[ch].RAM.Index;
  if Chan.Enabled then
  begin
    if (Chan.Sample_Length = 0) or (Chan.Ornament_Length = 0) or
      (Chan.Loop_Sample_Position >= Chan.Sample_Length) or (Chan.Loop_Ornament_Position >= Chan.Ornament_Length) or
      (Integer(Chan.SamplePointer) + Integer(Chan.Sample_Length) * 4 > Length(idx)) or
      (Integer(Chan.OrnamentPointer) + Integer(Chan.Ornament_Length) > Length(idx)) then
      raise EArgumentException.Create('Invalid PT3 instrument');
    Chan.Ton := Wrap16(ReadWord(idx, (Int64((Int64(Chan.SamplePointer) + Int64((Int64(Chan.Position_In_Sample) * Int64(4))))) + Int64(2))));
    Chan.Ton := Wrap16((Chan.Ton + Chan.Ton_Accumulator));
    b0 := Wrap8(idx[(Int64((Int64(Chan.SamplePointer) + Int64((Int64(Chan.Position_In_Sample) * Int64(4))))) + Int64(0))]);
    b1 := Wrap8(idx[(Int64((Int64(Chan.SamplePointer) + Int64((Int64(Chan.Position_In_Sample) * Int64(4))))) + Int64(1))]);
    if ((b1 and $40) <> 0) then
    begin
      Chan.Ton_Accumulator := Signed16(Chan.Ton);
    end;
    j := Wrap8((Int64(Chan.Note) + Int64(idx[(Int64(Chan.OrnamentPointer) + Int64(Chan.Position_In_Ornament))])));
    if (j >= 128) then
    begin
      j := Wrap8(0);
    end
    else
    begin
      if (j > 95) then
      begin
        j := Wrap8(95);
      end;
    end;
    w := Signed16(GetNoteFreq(Wrap8(j), ch));
    Chan.Ton := Wrap16(((Int64((Int64(Chan.Ton) + Int64(Chan.Current_Ton_Sliding))) + Int64(w)) and $fff));
    if (Chan.Ton_Slide_Count > 0) then
    begin
      Chan.Ton_Slide_Count := Signed16((Chan.Ton_Slide_Count + -1));
      if (Chan.Ton_Slide_Count = 0) then
      begin
        Chan.Current_Ton_Sliding := Signed16((Chan.Current_Ton_Sliding + Chan.Ton_Slide_Step));
        Chan.Ton_Slide_Count := Signed16(Chan.Ton_Slide_Delay);
        if (not Chan.SimpleGliss) then
        begin
          if (((Chan.Ton_Slide_Step < 0) and (Chan.Current_Ton_Sliding <= Chan.Ton_Delta)) or ((Chan.Ton_Slide_Step >= 0) and (Chan.Current_Ton_Sliding >= Chan.Ton_Delta))) then
          begin
            Chan.Note := Wrap8(Chan.Slide_To_Note);
            Chan.Ton_Slide_Count := Signed16(0);
            Chan.Current_Ton_Sliding := Signed16(0);
          end;
        end;
      end;
    end;
    Chan.Amplitude := Wrap8((b1 and 15));
    if ((b0 and $80) <> 0) then
    begin
      if ((b0 and $40) <> 0) then
      begin
        if (Chan.Current_Amplitude_Sliding < 15) then
        begin
          Chan.Current_Amplitude_Sliding := Signed16((Chan.Current_Amplitude_Sliding + 1));
        end;
      end
      else
      begin
        if (Chan.Current_Amplitude_Sliding > (-Int64(15))) then
        begin
          Chan.Current_Amplitude_Sliding := Signed16((Chan.Current_Amplitude_Sliding + -1));
        end;
      end;
    end;
    Chan.Amplitude := Wrap8((Chan.Amplitude + Chan.Current_Amplitude_Sliding));
    if (Chan.Amplitude >= 128) then
    begin
      Chan.Amplitude := Wrap8(0);
    end
    else
    begin
      if (Chan.Amplitude > 15) then
      begin
        Chan.Amplitude := Wrap8(15);
      end;
    end;
    if (FConsts[ch].Version <= 4) then
    begin
      Chan.Amplitude := Wrap8(PT3VolumeTable_33_34[Chan.Volume][Chan.Amplitude]);
    end
    else
    begin
      Chan.Amplitude := Wrap8(PT3VolumeTable_35[Chan.Volume][Chan.Amplitude]);
    end;
    if ((not ((b0 and 1) <> 0)) and Chan.Envelope_Enabled) then
    begin
      Chan.Amplitude := Wrap8((Chan.Amplitude or $10));
    end;
    if ((b1 and $80) <> 0) then
    begin
      if ((b0 and $20) <> 0) then
      begin
        j := Wrap8((Int64((SAR(b0, 1) or $F0)) + Int64(Chan.Current_Envelope_Sliding)));
      end
      else
      begin
        j := Wrap8((Int64((SAR(b0, 1) and $0f)) + Int64(Chan.Current_Envelope_Sliding)));
      end;
      if ((b1 and $20) <> 0) then
      begin
        Chan.Current_Envelope_Sliding := Signed16(Signed8(j));
      end;
      FAddToEnv := Signed16(Signed8((Int64(FAddToEnv) + Int64(Signed8(j)))));
    end
    else
    begin
      FParams[ch].PT3.AddToNoise := Wrap8((Int64(SAR(b0, 1)) + Int64(Chan.Current_Noise_Sliding)));
      if ((b1 and $20) <> 0) then
      begin
        Chan.Current_Noise_Sliding := Signed16(FParams[ch].PT3.AddToNoise);
      end;
    end;
    FTempMixer := Wrap8(((SAR(b1, 1) and $48) or FTempMixer));
    Chan.Position_In_Sample := Wrap8((Chan.Position_In_Sample + 1));
    if (Chan.Position_In_Sample >= Chan.Sample_Length) then
    begin
      Chan.Position_In_Sample := Wrap8(Chan.Loop_Sample_Position);
    end;
    Chan.Position_In_Ornament := Wrap8((Chan.Position_In_Ornament + 1));
    if (Chan.Position_In_Ornament >= Chan.Ornament_Length) then
    begin
      Chan.Position_In_Ornament := Wrap8(Chan.Loop_Ornament_Position);
    end;
  end
  else
  begin
    Chan.Amplitude := Wrap8(0);
  end;
  FTempMixer := Wrap8(SAR(FTempMixer, 1));
  if (Chan.Current_OnOff > 0) then
  begin
    Chan.Current_OnOff := Signed16((Chan.Current_OnOff + -1));
    if (Chan.Current_OnOff = 0) then
    begin
      Chan.Enabled := (not Chan.Enabled);
      if Chan.Enabled then
      begin
        if (Chan.Sample_Length = 0) or (Chan.Ornament_Length = 0) or
          (Chan.Loop_Sample_Position >= Chan.Sample_Length) or (Chan.Loop_Ornament_Position >= Chan.Ornament_Length) or
          (Integer(Chan.SamplePointer) + Integer(Chan.Sample_Length) * 4 > Length(idx)) or
          (Integer(Chan.OrnamentPointer) + Integer(Chan.Ornament_Length) > Length(idx)) then
          raise EArgumentException.Create('Invalid PT3 instrument');
        Chan.Current_OnOff := Signed16(Chan.OnOff_Delay);
      end
      else
      begin
        Chan.Current_OnOff := Signed16(Chan.OffOn_Delay);
      end;
    end;
  end;
end;

procedure TPT3Engine.PlayTick(ch: Integer);
var
  i: Integer;
  b: Integer;
  idx: TBytes;
  abc: Integer;
  env: Word;
begin
  idx := FConsts[ch].RAM.Index;
  FParams[ch].AY[13] := Wrap8($ff);
  FParams[ch].PT3.DelayCounter := Wrap8((FParams[ch].PT3.DelayCounter + -1));
  if (FParams[ch].PT3.DelayCounter = 0) then
  begin
    FParams[ch].PT3_[0].Note_Skip_Counter := Signed8((FParams[ch].PT3_[0].Note_Skip_Counter + -1));
    if (FParams[ch].PT3_[0].Note_Skip_Counter = 0) then
    begin
      if (idx[FParams[ch].PT3_[0].Address_In_Pattern] = 0) then
      begin
        FParams[ch].PT3.CurrentPosition := Wrap8((FParams[ch].PT3.CurrentPosition + 1));
        if (FParams[ch].PT3.CurrentPosition = FConsts[ch].RAM.PT3_NumberOfPositions) then
        begin
          FLooped[ch] := True;
          FParams[ch].PT3.CurrentPosition := Wrap8(FConsts[ch].RAM.PT3_LoopPosition);
        end;
        i := FConsts[ch].RAM.PT3_PositionList[FParams[ch].PT3.CurrentPosition];
        b := FConsts[ch].TS;
        if (b <> $20) then
        begin
          i := (Int64((Int64((Int64(b) * Int64(3))) - Int64(3))) - Int64(i));
        end;
        abc := 0;
        while (abc < 3) do
        begin
          FParams[ch].PT3_[abc].Address_In_Pattern := Wrap16(ReadWord(idx, (Int64(FConsts[ch].RAM.PT3_PatternsPointer) + Int64((Int64((Int64(i) + Int64(abc))) * Int64(2))))));
          abc := (abc + 1);
        end;
        FParams[ch].PT3.Noise_Base := Wrap8(0);
      end;
      PatternInterpreter(FParams[ch].PT3_[0], ch);
    end;
    abc := 1;
    while (abc < 3) do
    begin
      FParams[ch].PT3_[abc].Note_Skip_Counter := Signed8((FParams[ch].PT3_[abc].Note_Skip_Counter + -1));
      if (FParams[ch].PT3_[abc].Note_Skip_Counter = 0) then
      begin
        PatternInterpreter(FParams[ch].PT3_[abc], ch);
      end;
      abc := (abc + 1);
    end;
    FParams[ch].PT3.DelayCounter := Wrap8(FParams[ch].PT3.Delay);
  end;
  FAddToEnv := Signed16(0);
  FTempMixer := Wrap8(0);
  ChangeRegisters(FParams[ch].PT3_[0], ch);
  ChangeRegisters(FParams[ch].PT3_[1], ch);
  ChangeRegisters(FParams[ch].PT3_[2], ch);
  FParams[ch].AY[0] := Wrap8((FParams[ch].PT3_[0].Ton and $ff));
  FParams[ch].AY[1] := Wrap8(SAR(FParams[ch].PT3_[0].Ton, 8));
  FParams[ch].AY[2] := Wrap8((FParams[ch].PT3_[1].Ton and $ff));
  FParams[ch].AY[3] := Wrap8(SAR(FParams[ch].PT3_[1].Ton, 8));
  FParams[ch].AY[4] := Wrap8((FParams[ch].PT3_[2].Ton and $ff));
  FParams[ch].AY[5] := Wrap8(SAR(FParams[ch].PT3_[2].Ton, 8));
  FParams[ch].AY[6] := Wrap8(((Int64(FParams[ch].PT3.Noise_Base) + Int64(FParams[ch].PT3.AddToNoise)) and $1f));
  FParams[ch].AY[7] := Wrap8(FTempMixer);
  FParams[ch].AY[8] := Wrap8(FParams[ch].PT3_[0].Amplitude);
  FParams[ch].AY[9] := Wrap8(FParams[ch].PT3_[1].Amplitude);
  FParams[ch].AY[10] := Wrap8(FParams[ch].PT3_[2].Amplitude);
  env := Wrap16((Int64((Int64(FParams[ch].PT3.Env_Base.wrd) + Int64(FAddToEnv))) + Int64(FParams[ch].PT3.Cur_Env_Slide)));
  FParams[ch].AY[11] := Wrap8((env and $ff));
  FParams[ch].AY[12] := Wrap8(SAR(env, 8));
  if (FParams[ch].PT3.Cur_Env_Delay > 0) then
  begin
    FParams[ch].PT3.Cur_Env_Delay := Signed8((FParams[ch].PT3.Cur_Env_Delay + -1));
    if (FParams[ch].PT3.Cur_Env_Delay = 0) then
    begin
      FParams[ch].PT3.Cur_Env_Delay := Signed8(FParams[ch].PT3.Env_Delay);
      FParams[ch].PT3.Cur_Env_Slide := Signed16((FParams[ch].PT3.Cur_Env_Slide + FParams[ch].PT3.Env_Slide_Add));
    end;
  end;
  FConsts[ch].Global_Tick_Counter := Wrap32((FConsts[ch].Global_Tick_Counter + 1));
end;

procedure TPT3Engine.RestartMusic(ch: Integer);
var
  i: Integer;
  i2: Integer;
  idx: TBytes;
  b: Integer;
  abc: Integer;
begin
  idx := FConsts[ch].RAM.Index;
  FParams[ch].PT3.DelayCounter := Wrap8(1);
  FParams[ch].PT3.Delay := Wrap8(FConsts[ch].RAM.PT3_Delay);
  FParams[ch].PT3.Noise_Base := Wrap8(0);
  FParams[ch].PT3.AddToNoise := Wrap8(0);
  FParams[ch].PT3.Cur_Env_Slide := Signed16(0);
  FParams[ch].PT3.Cur_Env_Delay := Signed8(0);
  FParams[ch].PT3.Env_Base.wrd := Wrap16(0);
  FParams[ch].PT3.CurrentPosition := Wrap8(0);
  i := FConsts[ch].RAM.PT3_PositionList[0];
  i2 := FConsts[ch].RAM.PT3_PatternsPointer;
  b := FConsts[ch].TS;
  if (b <> $20) then
  begin
    i := (Int64((Int64((Int64(b) * Int64(3))) - Int64(3))) - Int64(i));
  end;
  abc := 0;
  while (abc < 3) do
  begin
    FParams[ch].PT3_[abc].Address_In_Pattern := Wrap16(ReadWord(idx, (Int64((Int64(i2) + Int64((Int64(i) * Int64(2))))) + Int64((Int64(abc) * Int64(2))))));
    FParams[ch].PT3_[abc].OrnamentPointer := Wrap16(FConsts[ch].RAM.PT3_OrnamentsPointers[0]);
    FParams[ch].PT3_[abc].Loop_Ornament_Position := Wrap8(idx[FParams[ch].PT3_[abc].OrnamentPointer]);
    FParams[ch].PT3_[abc].OrnamentPointer := Wrap16((FParams[ch].PT3_[abc].OrnamentPointer + 1));
    FParams[ch].PT3_[abc].Ornament_Length := Wrap8(idx[FParams[ch].PT3_[abc].OrnamentPointer]);
    FParams[ch].PT3_[abc].OrnamentPointer := Wrap16((FParams[ch].PT3_[abc].OrnamentPointer + 1));
    FParams[ch].PT3_[abc].SamplePointer := Wrap16(FConsts[ch].RAM.PT3_SamplesPointers[1]);
    FParams[ch].PT3_[abc].Loop_Sample_Position := Wrap8(idx[FParams[ch].PT3_[abc].SamplePointer]);
    FParams[ch].PT3_[abc].SamplePointer := Wrap16((FParams[ch].PT3_[abc].SamplePointer + 1));
    FParams[ch].PT3_[abc].Sample_Length := Wrap8(idx[FParams[ch].PT3_[abc].SamplePointer]);
    FParams[ch].PT3_[abc].SamplePointer := Wrap16((FParams[ch].PT3_[abc].SamplePointer + 1));
    FParams[ch].PT3_[abc].Volume := Wrap8(15);
    FParams[ch].PT3_[abc].Note_Skip_Counter := Signed8(1);
    FParams[ch].PT3_[abc].Enabled := False;
    FParams[ch].PT3_[abc].Envelope_Enabled := False;
    FParams[ch].PT3_[abc].Note := Wrap8(0);
    FParams[ch].PT3_[abc].Ton := Wrap16(0);
    abc := (abc + 1);
  end;
end;

constructor TPT3Engine.Create(const Data: TBytes);
var
  Sizes: array[0..2] of Integer;
  Offset, Footer, Count, Chip, I, J, P: Integer;
  M: Module;
  Signature: string;
begin
  inherited Create;
  Count := 1;
  Sizes[0] := Length(Data);
  Offset := 0;
  if Length(Data) >= 22 then
  begin
    Footer := Length(Data) - 22;
    Signature := TEncoding.ASCII.GetString(Data, Length(Data) - 4, 4);
    if (Signature = '02TS') or (Signature = '03TS') then
    begin
      if Signature = '02TS' then
      begin
        Count := 2;
        Sizes[0] := ReadWord(Data, Footer + 10);
        Sizes[1] := ReadWord(Data, Footer + 16);
      end
      else
      begin
        Count := 3;
        for I := 0 to 2 do
          Sizes[I] := ReadWord(Data, Footer + 4 + I * 6);
      end;
      J := 0;
      for I := 0 to Count - 1 do
        Inc(J, Sizes[I]);
      if Signature = '02TS' then
        Footer := Length(Data) - 16;
      if J <> Footer then
        raise EArgumentException.Create('Invalid TurboSound module lengths');
    end;
  end;
  FChipCount := Count;
  for Chip := 0 to Count - 1 do
  begin
    if (Sizes[Chip] < 202) or (Sizes[Chip] > 65536) then
      raise EArgumentException.Create('Invalid PT3 module size');
    M := Default(Module);
    M.Index := Copy(Data, Offset, Sizes[Chip]);
    Inc(Offset, Sizes[Chip]);
    Signature := TEncoding.ASCII.GetString(M.Index, 0, 13);
    if (Signature <> 'ProTracker 3.') and (Copy(Signature, 1, 13) <> 'Vortex Tracke') then
      raise EArgumentException.Create('Invalid PT3 signature');
    for I := 0 to 98 do
      M.PT3_MusicName[I] := M.Index[I];
    M.PT3_TonTableId := M.Index[99];
    M.PT3_Delay := M.Index[100];
    M.PT3_LoopPosition := M.Index[102];
    M.PT3_PatternsPointer := ReadWord(M.Index, 103);
    if M.PT3_TonTableId > 3 then
      raise EArgumentException.Create('Invalid PT3 note table');
    I := 0;
    while (201 + I < Length(M.Index)) and (I < 255) and (M.Index[201 + I] <> 255) do
    begin
      M.PT3_PositionList[I] := M.Index[201 + I];
      Inc(I);
    end;
    if (I = 0) or (201 + I >= Length(M.Index)) or (M.Index[201 + I] <> 255) then
      raise EArgumentException.Create('Invalid PT3 position list');
    M.PT3_NumberOfPositions := I;
    if M.PT3_LoopPosition >= I then
      raise EArgumentException.Create('Invalid PT3 loop position');
    for J := 0 to 31 do
      M.PT3_SamplesPointers[J] := ReadWord(M.Index, 105 + J * 2);
    for J := 0 to 15 do
      M.PT3_OrnamentsPointers[J] := ReadWord(M.Index, 169 + J * 2);
    FConsts[Chip].RAM := M;
    FConsts[Chip].Length := Length(M.Index);
    FConsts[Chip].TS := $20;
    FConsts[Chip].Version := 6;
    if (M.Index[13] >= Ord('0')) and (M.Index[13] <= Ord('9')) then
      FConsts[Chip].Version := M.Index[13] - Ord('0');
    for J := 0 to I - 1 do
      for P := 0 to 2 do
        ReadWord(M.Index, M.PT3_PatternsPointer + (Integer(M.PT3_PositionList[J]) + P) * 2);
  end;
  if FConsts[0].RAM.PT3_MusicName[98] <> $20 then
  begin
    if Count <> 1 then
      raise EArgumentException.Create('Nested TurboSound modules are unsupported');
    FChipCount := 2;
    FConsts[1] := FConsts[0];
    FConsts[1].TS := FConsts[0].RAM.PT3_MusicName[98];
  end;
  Reset;
end;

procedure TPT3Engine.Reset;
begin
  FForcedTable := -1;
  FTempMixer := 0;
  FAddToEnv := 0;
  for var Chip := 0 to FChipCount - 1 do
  begin
    FParams[Chip] := Default(TPlParams);
    FLooped[Chip] := False;
    FConsts[Chip].Global_Tick_Counter := 0;
    RestartMusic(Chip);
  end;
end;

procedure TPT3Engine.Tick;
begin
  for var Chip := 0 to FChipCount - 1 do
    PlayTick(Chip);
end;

function TPT3Engine.Registers(Chip: Integer): TPT3Registers;
begin
  if (Chip < 0) or (Chip >= FChipCount) then
    raise EArgumentOutOfRangeException.Create('PT3 chip');
  for var i := 0 to 13 do
    Result[i] := FParams[Chip].AY[i];
end;

function TPT3Engine.Looped: Boolean;
begin
  Result := True;
  for var Chip := 0 to FChipCount - 1 do
    Result := Result and FLooped[Chip];
end;

function TPT3Engine.Header: TBytes;
begin
  Result := Copy(FConsts[0].RAM.Index, 0, 99);
end;

end.

