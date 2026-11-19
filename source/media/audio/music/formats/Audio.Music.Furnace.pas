unit Audio.Music.Furnace;

interface

uses
  System.SysUtils, Audio.Types;

function OpenFurnace(const Data: TBytes): IAudioSource;

implementation

uses
  System.Classes, System.Math, System.ZLib, Audio.Binary, Audio.Decoder,
  HW.Sound.YM2149;

type
  TTrackRow = record
    Note: SmallInt;
    Volume: SmallInt;
    Instrument: SmallInt;
    Effects, Params: array[0..7] of SmallInt;
  end;

  TNoteArray = array[0..255] of TTrackRow;

  TPatternArray = array[0..255] of TNoteArray;

  TChannelPatterns = array[0..2] of TPatternArray;

  TFurnaceMacro = record
    Values: TArray<Integer>;
    Len: Integer;
    LoopPos: Integer;
    RelPos: Integer;
    Speed: Integer;
    Delay: Integer;
    Mode: Integer;
    TypeId: Integer;
    ActiveRelease: Boolean;
  end;

  TFurnaceInstrument = record
    VolMacro: TFurnaceMacro;
    ArpMacro: TFurnaceMacro;
    NoiseMacro: TFurnaceMacro;
    WaveMacro: TFurnaceMacro;
    PitchMacro: TFurnaceMacro;
    EnvMacro: TFurnaceMacro;
    EnvPeriodMacro, EnvNumMacro, EnvDenMacro, FixedPeriodMacro: TFurnaceMacro;
  end;

  TMacroState = record
    Pos: Integer;
    Tick: Integer;
    Started: Boolean;
    Released: Boolean;
    Stopped: Boolean;
    LastPos: Integer;
    Val: Integer;
    Had: Boolean;
  end;

  TChannelState = record
    Instrument, PlayingInstrument: Integer;
    Note: Integer;
    Volume256: Integer;
    PitchOffset: Integer;
    EnvNum, EnvDen, Tone, MixerMode, FinePitch: Integer;
    Arp, ArpTick, ArpSpeed, Vibrato, VibratoPhase, VolumeSlide, CutTick: Integer;
    DelayedTick: Integer;
    DelayedRow: TTrackRow;
    SlideRate, SlideTarget: Integer;
    SlideOffset: Double;
    Released, MixerOverride, EnvOverride, EnvEnabled: Boolean;
    VolState, ArpState, NoiseState, WaveState, PitchState, EnvState, EnvPeriodState, EnvNumState, EnvDenState, FixedPeriodState: TMacroState;
  end;

  { TFurnaceDecoder }

  TFurnaceDecoder = class(TAudioMusicSource, IAudioSeekSource)
  private
    FInfo: TAudioInfo;
    FYM: TYM2149F;
    FClockHz: Integer;
    FFormatVer: Integer;
    FTickRate, FInitialTickRate, FTuning: Double;
    FInitialVirtNum, FInitialVirtDen: Integer;
    FHalfClock, FStereo, FAYModel: Boolean;
    FStereoSep: Integer;
    FMasterVolume: Double;
    FFramesLeft: Int64;
    FFinished, FStopPending: Boolean;
    FVisited: array[0..255, 0..255] of Boolean;
    FInitialSpeedsLen: Integer;
    FInitialSpeeds: array[0..15] of Integer;
    FVirtNum: Integer;
    FVirtDen: Integer;
    FOrdersLen: Integer;
    FOrders: TArray<Integer>;
    FNoteTable: TChannelPatterns;
    FPatternLength: Integer;
    FInstruments: TArray<TFurnaceInstrument>;
    FSpeeds: array[0..15] of Integer;
    FSpeedsLen: Integer;
    FSpeedsPos: Integer;
    FGrooves: array[0..254] of array[0..15] of Integer;
    FGrooveLens: array[0..254] of Integer;
    FGrooveCount: Integer;
    FCurrentOrder: Integer;
    FCurrentPatRow: Integer;
    FTickInRow: Integer;
    FSampleAcc: Double;
    FEnvSlide, FEnvSlideFraction: Integer;
    FJumpOrder: Integer;
    FBreakRow: Integer;
    FChanState: array[0..2] of TChannelState;

    function ReadFloatLE(const Data: TBytes; P: Integer): Single; inline;
    procedure BuildSong(const Data: TBytes);
    procedure ParseTrack(const PatData: TBytes; out NoteArray: TNoteArray);
    procedure ParseInstrument(const Data: TBytes; Index: Integer);
    procedure ParseLegacyInstrument(const Data: TBytes; Index: Integer);
    procedure ParseLegacyTrack(const Data: TBytes; Columns: Integer; out Notes: TNoteArray);
    procedure ReadMacroData(const Data: TBytes; var P: Integer; out M: TFurnaceMacro; HeaderLen: Integer);
    procedure ApplyPatternRow(Order, PatRow: Integer);
    procedure ApplyEffect(Ch, Effect, Param: Integer);
    procedure ApplyChannelRow(Ch: Integer; const RowData: TTrackRow);
    procedure CutNote(Ch: Integer);
    function NotePeriod(Note: Int64): Double;
    procedure EndTick;
    function BeginTick: Boolean;
    function CountFrames: Int64;
    procedure ResetPlayback;
    procedure InitChannelState(Ch: Integer);
    procedure TriggerNote(Ch: Integer; Note: Integer; Ins: Integer; Vol: Integer);
    procedure ReleaseNote(Ch: Integer);
    procedure TickMacro(var S: TMacroState; const M: TFurnaceMacro);
    procedure TickMacros;
    procedure ApplyChannel(Ch: Integer);
    function CurrentRowSpeed: Integer;

  public
    constructor Create(const Data: TBytes);
    destructor Destroy; override;
    function GetInfo: TAudioInfo; override;
    procedure SelectTrack(Index: Integer); override;
    function Render(var Samples: array of SmallInt; Frames: Integer): Integer; override;
    function SeekFrame(Frame: Int64; const Cancelled: TFunc<Boolean>): Int64;
  end;

const
  FurnaceMagic = '-Furnace module-';

function ReadByte(const Data: TBytes; var P: Integer): Byte;
begin
  RequireBytes(Data, P, 1);
  Result := Data[P];
  Inc(P);
end;

function ReadString(const Data: TBytes; var P: Integer): string;
var
  Start: Integer;
begin
  Start := P;
  while ReadByte(Data, P) <> 0 do
    ;
  Result := TEncoding.UTF8.GetString(Data, Start, P - Start - 1);
end;

function TFurnaceDecoder.ReadFloatLE(const Data: TBytes; P: Integer): Single;
begin
  var Bits := LE32(Data, P);
  Move(Bits, Result, SizeOf(Result));
end;

function UnpackFurnace(const Input: TBytes): TBytes;
const
  MaxModuleSize = 64 * 1024 * 1024;
var
  Buffer: array[0..16383] of Byte;
  Count: Integer;
begin
  RequireBytes(Input, 0, 2);
  if Input[0] = Ord('-') then
    Exit(Input);
  if ((Input[0] and $0F) <> 8) or ((Input[0] shr 4) > 7) or
    (((Integer(Input[0]) shl 8) or Input[1]) mod 31 <> 0) then
    raise EArgumentException.Create('Furnace: invalid zlib header');
  var Source := TBytesStream.Create(Input);
  try
    var Inflater := TZDecompressionStream.Create(Source);
    try
      var Output := TBytesStream.Create(nil);
      try
        repeat
          Count := Inflater.Read(Buffer, SizeOf(Buffer));
          if Output.Size + Count > MaxModuleSize then
            raise EArgumentException.Create('Furnace: decompressed module exceeds 64 MiB');
          Output.WriteBuffer(Buffer, Count);
        until Count = 0;
        Result := Copy(Output.Bytes, 0, Integer(Output.Size));
      finally
        Output.Free;
      end;
    finally
      Inflater.Free;
    end;
  finally
    Source.Free;
  end;
end;

procedure TFurnaceDecoder.ReadMacroData(const Data: TBytes; var P: Integer; out M: TFurnaceMacro; HeaderLen: Integer);
const
  Width: array[0..3] of Integer = (1, 1, 2, 4);
var
  Flags, Encoding, I: Integer;
begin
  if HeaderLen < 8 then
    raise EArgumentException.Create('Furnace: invalid macro header length');
  RequireBytes(Data, P, HeaderLen - 1);
  M := Default(TFurnaceMacro);
  M.Len := Data[P];
  M.LoopPos := Data[P + 1];
  M.RelPos := Data[P + 2];
  M.Mode := Data[P + 3];
  Flags := Data[P + 4];
  M.TypeId := (Flags shr 1) and 3;
  M.ActiveRelease := (FFormatVer >= 182) and ((Flags and 8) <> 0);
  M.Delay := Data[P + 5];
  M.Speed := Max(1, Integer(Data[P + 6]));
  Inc(P, HeaderLen - 1);
  Encoding := Flags shr 6;
  RequireBytes(Data, P, M.Len * Width[Encoding]);
  SetLength(M.Values, M.Len);
  for I := 0 to M.Len - 1 do
  begin
    case Encoding of
      0:
        M.Values[I] := Data[P];
      1:
        M.Values[I] := ShortInt(Data[P]);
      2:
        M.Values[I] := SmallInt(LE16(Data, P));
      3:
        M.Values[I] := Integer(LE32(Data, P));
    end;
    Inc(P, Width[Encoding]);
  end;
end;

procedure TFurnaceDecoder.ParseInstrument(const Data: TBytes; Index: Integer);
var
  P, FeatureLen, MacroPos, HeaderLen: Integer;
  Code: Word;
  Feature: TBytes;
  Ins: TFurnaceInstrument;
  Dummy: TFurnaceMacro;
begin
  RequireBytes(Data, 0, 4);
  Ins := Default(TFurnaceInstrument);
  P := 4;
  while P < Length(Data) do
  begin
    Code := LE16(Data, P);
    Inc(P, 2);
    if Code = $4E45 then
      Break; // EN
    FeatureLen := LE16(Data, P);
    Inc(P, 2);
    RequireBytes(Data, P, FeatureLen);
    if Code = $414D then // MA
    begin
      Feature := Copy(Data, P, FeatureLen);
      HeaderLen := LE16(Feature, 0);
      MacroPos := 2;
      while MacroPos < Length(Feature) do
        case ReadByte(Feature, MacroPos) of
          0:
            ReadMacroData(Feature, MacroPos, Ins.VolMacro, HeaderLen);
          1:
            ReadMacroData(Feature, MacroPos, Ins.ArpMacro, HeaderLen);
          2:
            ReadMacroData(Feature, MacroPos, Ins.NoiseMacro, HeaderLen);
          3:
            ReadMacroData(Feature, MacroPos, Ins.WaveMacro, HeaderLen);
          4:
            ReadMacroData(Feature, MacroPos, Ins.PitchMacro, HeaderLen);
          6:
            ReadMacroData(Feature, MacroPos, Ins.EnvMacro, HeaderLen);
          7:
            ReadMacroData(Feature, MacroPos, Ins.EnvNumMacro, HeaderLen);
          8:
            ReadMacroData(Feature, MacroPos, Ins.EnvDenMacro, HeaderLen);
          15:
            ReadMacroData(Feature, MacroPos, Ins.FixedPeriodMacro, HeaderLen);
          16:
            ReadMacroData(Feature, MacroPos, Ins.EnvPeriodMacro, HeaderLen);
          255:
            Break;
        else
          ReadMacroData(Feature, MacroPos, Dummy, HeaderLen);
        end;
    end;
    Inc(P, FeatureLen);
  end;
  FInstruments[Index] := Ins;
end;

procedure TFurnaceDecoder.ParseLegacyInstrument(const Data: TBytes; Index: Integer);
var
  Macro: array[0..11] of TFurnaceMacro;
  OpLength: array[0..47] of Integer;
  I, J, P, InstrumentVersion: Integer;
  FixedArp: Boolean;
  Ins: TFurnaceInstrument;

  function ReadInt: Integer;
  begin
    Result := Integer(LE32(Data, P));
    Inc(P, 4);
  end;

  function ReadLength: Integer;
  begin
    Result := ReadInt;
    if not InRange(Result, 0, 255) then
      raise EArgumentException.Create('Furnace: invalid legacy macro length');
  end;

  procedure ReadValues(First, Last: Integer);
  begin
    for var K := First to Last do
    begin
      SetLength(Macro[K].Values, Macro[K].Len);
      for var V := 0 to Macro[K].Len - 1 do
        Macro[K].Values[V] := ReadInt;
    end;
  end;

begin
  Ins := Default(TFurnaceInstrument);
  InstrumentVersion := LE16(Data, 0);
  if not InRange(InstrumentVersion, 48, 126) then
    raise ENotSupportedException.Create('Furnace: unsupported legacy instrument');
  P := 4;
  ReadString(Data, P);
  // The legacy instrument includes FM, Game Boy, C64 and Amiga data for all chip types.
  Inc(P, 8 + 4 * 32 + 4 + 24 + 16);
  for I := 0 to 7 do
    Macro[I].Len := ReadLength;
  for I := 0 to 7 do
    Macro[I].LoopPos := ReadInt;
  FixedArp := (ReadByte(Data, P) <> 0) and (InstrumentVersion < 112);
  Inc(P, 3);
  ReadValues(0, 7);

  for I := 8 to 11 do
    Macro[I].Len := ReadLength;
  for I := 8 to 11 do
    Macro[I].LoopPos := ReadInt;
  for I := 0 to 11 do
  begin
    J := ReadByte(Data, P);
    Macro[I].TypeId := 0;
    if InstrumentVersion >= 120 then
      Macro[I].TypeId := (J shr 1) and 3;
  end;
  ReadValues(8, 11);
  for I := 0 to 3 do
  begin
    for J := 0 to 11 do
      OpLength[I * 12 + J] := ReadLength;
    Inc(P, 12 * 4 + 12);
  end;
  for I := 0 to High(OpLength) do
    Inc(P, OpLength[I]);
  for I := 0 to High(Macro) do
  begin
    Macro[I].RelPos := ReadInt;
    if not InRange(Macro[I].RelPos, 0, 255) then
      Macro[I].RelPos := 255;
    if not InRange(Macro[I].LoopPos, 0, 255) then
      Macro[I].LoopPos := 255;
    Macro[I].Speed := 1;
    Macro[I].ActiveRelease := False;
    Macro[I].Delay := 0;
    Macro[I].Mode := 0;
  end;
  if FixedArp then
    for I := 0 to Macro[1].Len - 1 do
      Macro[1].Values[I] := Macro[1].Values[I] xor $40000000;
  Ins.VolMacro := Macro[0];
  Ins.ArpMacro := Macro[1];
  Ins.NoiseMacro := Macro[2];
  Ins.WaveMacro := Macro[3];
  Ins.PitchMacro := Macro[4];
  Ins.EnvMacro := Macro[6];
  Ins.EnvNumMacro := Macro[7];
  Ins.EnvDenMacro := Macro[8];
  FInstruments[Index] := Ins;
end;

procedure TFurnaceDecoder.ParseLegacyTrack(const Data: TBytes; Columns: Integer; out Notes: TNoteArray);
var
  P, Row, I, Note, Octave: Integer;

  function ReadShort: SmallInt;
  begin
    Result := SmallInt(LE16(Data, P));
    Inc(P, 2);
  end;

begin
  FillChar(Notes, SizeOf(Notes), $FF);
  P := 8;
  RequireBytes(Data, P, FPatternLength * (4 + Columns * 2) * 2);
  for Row := 0 to FPatternLength - 1 do
  begin
    Note := ReadShort;
    Octave := ShortInt(Byte(ReadShort));
    case Note of
      0..12:
        if (Note <> 0) or (Octave <> 0) then
          Notes[Row].Note := EnsureRange(60 + Octave * 12 + Note, 0, 179);
      100..102:
        Notes[Row].Note := Note + 80;
    end;
    Notes[Row].Instrument := ReadShort;
    Notes[Row].Volume := ReadShort;
    for I := 0 to Columns - 1 do
    begin
      Notes[Row].Effects[I] := ReadShort;
      Notes[Row].Params[I] := ReadShort;
    end;
  end;
end;

procedure TFurnaceDecoder.BuildSong(const Data: TBytes);
const
  AYClock: array[0..15] of Integer = (1789773, 1773448, 1750000, 2000000,
    1500000, 1000000, 894886, 1662608, 831304, 1108405, 2097152, 3579545,
    3600000, 1250000, 1536000, 1996800);
var
  Raw, Info, Block: TBytes;
  P, I, J, Count, InstrumentCount, PatternCount, WaveCount, SampleCount: Integer;
  InstrumentTable, PatternTable, Channel, Pattern, TimeBase, Offset: Integer;
  Columns: array[0..2] of Integer;
  ChipType, ClockSel: Integer;
  Address: Cardinal;
  FlagOffset: Cardinal;
  Flags: TStringList;

  function BlockAt(Address: Cardinal; const ID: string): TBytes;
  begin
    if Address > Cardinal(Length(Raw)) then
      raise EArgumentException.Create('Furnace: block offset outside the module');
    var Index := Integer(Address);
    RequireBytes(Raw, Index, 8);
    if TEncoding.ASCII.GetString(Raw, Index, 4) <> ID then
      raise EArgumentException.CreateFmt('Furnace: expected block %s', [ID]);
    var Size := LE32(Raw, Index + 4);
    if (Size = 0) and (FFormatVer < 100) then
      Size := Cardinal(Length(Raw) - Index - 8);
    if Size > Cardinal(Length(Raw) - Index - 8) then
      raise EArgumentException.Create('Furnace: block size outside the module');
    Result := Copy(Raw, Index + 8, Integer(Size));
  end;

  procedure Skip(Count: Integer);
  begin
    RequireBytes(Info, P, Count);
    Inc(P, Count);
  end;

begin
  Raw := UnpackFurnace(Data);
  RequireBytes(Raw, 0, 32);
  if TEncoding.ASCII.GetString(Raw, 0, 16) <> FurnaceMagic then
    raise EArgumentException.Create('Furnace: invalid module signature');
  FFormatVer := LE16(Raw, 16);
  if (FFormatVer < 48) or (FFormatVer > 239) then
    raise ENotSupportedException.CreateFmt('Furnace: unsupported module version %d', [FFormatVer]);

  Info := BlockAt(LE32(Raw, 20), 'INFO');
  RequireBytes(Info, 0, 248);
  if (Info[24] <> $80) or (Info[25] <> 0) then
    raise ENotSupportedException.Create('Furnace: expected a single AY-3-8910 system');
  TimeBase := Info[0] + 1;
  FInitialTickRate := ReadFloatLE(Info, 4);
  if IsNan(FInitialTickRate) or IsInfinite(FInitialTickRate) or
    (FInitialTickRate < 1) or (FInitialTickRate > 1000) then
    raise EArgumentException.Create('Furnace: invalid tick rate');
  FPatternLength := LE16(Info, 8);
  FOrdersLen := LE16(Info, 10);
  if (FPatternLength < 1) or (FPatternLength > 256) or
    (FOrdersLen < 1) or (FOrdersLen > 256) then
    raise EArgumentException.Create('Furnace: invalid pattern or order length');
  InstrumentCount := LE16(Info, 14);
  WaveCount := LE16(Info, 16);
  SampleCount := LE16(Info, 18);
  if (InstrumentCount > 256) or (LE32(Info, 20) > Cardinal(Length(Info) div 4)) then
    raise EArgumentException.Create('Furnace: invalid instrument or pattern count');
  PatternCount := Integer(LE32(Info, 20));
  FlagOffset := LE32(Info, 120);
  P := 248;
  FInfo.Title := ReadString(Info, P);
  FInfo.Artist := ReadString(Info, P);
  FTuning := ReadFloatLE(Info, P);
  if IsNan(FTuning) or IsInfinite(FTuning) or (FTuning < 1) or (FTuning > 2000) then
    FTuning := 440;
  Skip(24);

  InstrumentTable := P;
  Skip(4 * (InstrumentCount + WaveCount + SampleCount));
  PatternTable := P;
  Skip(PatternCount * 4);
  SetLength(FOrders, 3 * FOrdersLen);
  for I := 0 to 2 do
    for J := 0 to FOrdersLen - 1 do
      FOrders[J * 3 + I] := ReadByte(Info, P);
  for I := 0 to 2 do
  begin
    Columns[I] := ReadByte(Info, P);
    if (Columns[I] < 1) or (Columns[I] > 8) then
      raise EArgumentException.Create('Furnace: invalid effect column count');
  end;
  if FFormatVer >= 39 then
  begin
    Skip(6);
    for I := 0 to 6 do
      ReadString(Info, P);
  end;
  FMasterVolume := 2;
  if FFormatVer >= 59 then
  begin
    FMasterVolume := ReadFloatLE(Info, P);
    if IsNan(FMasterVolume) or IsInfinite(FMasterVolume) then
      FMasterVolume := 1;
    FMasterVolume := EnsureRange(FMasterVolume, 0.0, 4.0);
    Skip(4);
  end;
  if FFormatVer >= 70 then
    Skip(28);
  FInitialVirtNum := 1;
  FInitialVirtDen := 1;
  if FFormatVer >= 96 then
  begin
    FInitialVirtNum := Max(1, Integer(LE16(Info, P)));
    FInitialVirtDen := Max(1, Integer(LE16(Info, P + 2)));
  end;
  if FFormatVer >= 70 then
    Skip(4);
  FInitialSpeedsLen := 2;
  FInitialSpeeds[0] := Max(1, Integer(Info[1])) * TimeBase;
  FInitialSpeeds[1] := Max(1, Integer(Info[2])) * TimeBase;
  if FFormatVer >= 139 then
  begin
    ReadString(Info, P);
    ReadString(Info, P);
    Count := ReadByte(Info, P);
    Skip(3 + 4 * Count);
    for I := 0 to 5 do
      ReadString(Info, P);
    Skip(12);
    if LE32(Info, P) > Cardinal((Length(Info) - P - 13) div 4) then
      raise EArgumentException.Create('Furnace: invalid patchbay');
    Count := Integer(LE32(Info, P));
    Skip(13 + Count * 4);

    FInitialSpeedsLen := ReadByte(Info, P);
    if (FInitialSpeedsLen < 1) or (FInitialSpeedsLen > 16) then
      raise EArgumentException.Create('Furnace: invalid speed pattern');
    for I := 0 to High(FInitialSpeeds) do
      FInitialSpeeds[I] := Max(1, Integer(ReadByte(Info, P))) * TimeBase;
    FGrooveCount := ReadByte(Info, P);
    for I := 0 to FGrooveCount - 1 do
    begin
      FGrooveLens[I] := ReadByte(Info, P);
      if (FGrooveLens[I] < 1) or (FGrooveLens[I] > 16) then
        raise EArgumentException.Create('Furnace: invalid groove length');
      for J := 0 to 15 do
        FGrooves[I][J] := Max(1, Integer(ReadByte(Info, P)));
    end;
  end;

  FClockHz := AYClock[0];
  ChipType := 0;
  if FFormatVer < 119 then
  begin
    ClockSel := FlagOffset and $0F;
    FClockHz := AYClock[ClockSel];
    ChipType := (FlagOffset shr 4) and 3;
    FHalfClock := (ChipType = 2) or ((ChipType = 1) and ((FlagOffset and $80) <> 0));
    FStereo := (FlagOffset and $40) <> 0;
    FStereoSep := (FlagOffset shr 8) and $FF;
  end
  else if FlagOffset <> 0 then
  begin
    Block := BlockAt(FlagOffset, 'FLAG');
    Offset := 0;
    Flags := TStringList.Create;
    try
      Flags.Text := ReadString(Block, Offset);
      I := StrToIntDef(Flags.Values['clockSel'], 0);
      if InRange(I, Low(AYClock), High(AYClock)) then
        FClockHz := AYClock[I];
      I := StrToIntDef(Flags.Values['customClock'], 0);
      if I = 0 then
        I := StrToIntDef(Flags.Values['clock'], 0);
      if InRange(I, 100000, 8000000) then
        FClockHz := I;
      ChipType := StrToIntDef(Flags.Values['chipType'], 0);
      FHalfClock := (ChipType = 2) or ((ChipType = 1) and SameText(Flags.Values['halfClock'], 'true'));
      FStereo := SameText(Flags.Values['stereo'], 'true');
      FStereoSep := EnsureRange(StrToIntDef(Flags.Values['stereoSep'], 0), 0, 255);
    finally
      Flags.Free;
    end;
  end;

  if not InRange(ChipType, 0, 2) then
    raise ENotSupportedException.Create('Furnace: unsupported AY chip variant');
  FAYModel := ChipType = 0;

  SetLength(FInstruments, InstrumentCount);
  for I := 0 to InstrumentCount - 1 do
  begin
    Address := LE32(Info, InstrumentTable + I * 4);
    RequireBytes(Raw, Integer(Address), 4);
    if TEncoding.ASCII.GetString(Raw, Integer(Address), 4) = 'INST' then
      ParseLegacyInstrument(BlockAt(Address, 'INST'), I)
    else
      ParseInstrument(BlockAt(Address, 'INS2'), I);
  end;

  FillChar(FNoteTable, SizeOf(FNoteTable), $FF);
  for I := 0 to PatternCount - 1 do
  begin
    Address := LE32(Info, PatternTable + I * 4);
    RequireBytes(Raw, Integer(Address), 4);
    if TEncoding.ASCII.GetString(Raw, Integer(Address), 4) = 'PATR' then
    begin
      Block := BlockAt(Address, 'PATR');
      RequireBytes(Block, 0, 8);
      if (FFormatVer >= 95) and (LE16(Block, 4) <> 0) then
        Continue;
      Channel := LE16(Block, 0);
      Pattern := LE16(Block, 2);
      if (Channel > 2) or (Pattern > 255) then
        raise EArgumentException.Create('Furnace: invalid pattern index');
      ParseLegacyTrack(Block, Columns[Channel], FNoteTable[Channel][Pattern]);
    end
    else
    begin
      Block := BlockAt(Address, 'PATN');
      RequireBytes(Block, 0, 5);
      if Block[0] <> 0 then
        Continue;
      Channel := Block[1];
      Pattern := LE16(Block, 2);
      if (Channel > 2) or (Pattern > 255) then
        raise EArgumentException.Create('Furnace: invalid pattern index');
      Offset := 4;
      ReadString(Block, Offset);
      ParseTrack(Copy(Block, Offset, Length(Block) - Offset), FNoteTable[Channel][Pattern]);
    end;
  end;
end;

procedure TFurnaceDecoder.ParseTrack(const PatData: TBytes; out NoteArray: TNoteArray);
var
  P, Row, I, Flags, Mask: Integer;
begin
  FillChar(NoteArray, SizeOf(NoteArray), $FF);
  P := 0;
  Row := 0;
  while Row < FPatternLength do
  begin
    Flags := ReadByte(PatData, P);
    if Flags = $FF then
      Break;
    if (Flags and $80) <> 0 then
    begin
      Inc(Row, (Flags and $7F) + 2);
      Continue;
    end;
    Mask := (Flags shr 3) and 3;
    if (Flags and $20) <> 0 then
      Mask := Mask or ReadByte(PatData, P);
    if (Flags and $40) <> 0 then
      Mask := Mask or (Integer(ReadByte(PatData, P)) shl 8);
    if (Flags and 1) <> 0 then
      NoteArray[Row].Note := ReadByte(PatData, P);
    if (Flags and 2) <> 0 then
      NoteArray[Row].Instrument := ReadByte(PatData, P);
    if (Flags and 4) <> 0 then
      NoteArray[Row].Volume := ReadByte(PatData, P);
    for I := 0 to 7 do
    begin
      if (Mask and (1 shl (2 * I))) <> 0 then
        NoteArray[Row].Effects[I] := ReadByte(PatData, P);
      if (Mask and (2 shl (2 * I))) <> 0 then
        NoteArray[Row].Params[I] := ReadByte(PatData, P);
    end;
    Inc(Row);
  end;
end;

procedure TFurnaceDecoder.InitChannelState(Ch: Integer);
begin
  FChanState[Ch] := Default(TChannelState);
  FChanState[Ch].Instrument := -1;
  FChanState[Ch].PlayingInstrument := -1;
  FChanState[Ch].Note := -1;
  FChanState[Ch].Volume256 := 15 * 256;
  FChanState[Ch].Tone := -1;
  FChanState[Ch].SlideTarget := -1;
  FChanState[Ch].ArpSpeed := 1;
  FChanState[Ch].CutTick := -1;
  FChanState[Ch].DelayedTick := -1;
end;

procedure TFurnaceDecoder.TriggerNote(Ch, Note, Ins, Vol: Integer);
begin
  var Voice: ^TChannelState := @FChanState[Ch];
  Voice^.Note := Note;
  Voice^.PlayingInstrument := Ins;
  Voice^.Volume256 := Vol;
  Voice^.Released := False;
  Voice^.VolState := Default(TMacroState);
  Voice^.ArpState := Default(TMacroState);
  Voice^.NoiseState := Default(TMacroState);
  Voice^.WaveState := Default(TMacroState);
  Voice^.PitchState := Default(TMacroState);
  Voice^.EnvState := Default(TMacroState);
  Voice^.EnvPeriodState := Default(TMacroState);
  Voice^.EnvNumState := Default(TMacroState);
  Voice^.EnvDenState := Default(TMacroState);
  Voice^.FixedPeriodState := Default(TMacroState);
  Voice^.PitchOffset := 0;
  Voice^.SlideOffset := 0;
  Voice^.SlideTarget := -1;
  Voice^.ArpTick := 0;
end;

procedure TFurnaceDecoder.CutNote(Ch: Integer);
begin
  FChanState[Ch].Note := -1;
  FYM.WriteRegister(8 + Ch, 0);
  FYM.WriteRegister(7, FYM.ReadRegister(7) or (1 shl Ch) or (1 shl (Ch + 3)));
end;

function TFurnaceDecoder.NotePeriod(Note: Int64): Double;
var
  Clock: Integer;
begin
  Clock := FClockHz;
  if FHalfClock then
    Clock := Clock div 2;
  Note := EnsureRange(Note, Int64(0), Int64(179));
  Result := Clock / (16 * FTuning * Power(2.0, (Note - 117) / 12));
end;

procedure TFurnaceDecoder.ReleaseNote(Ch: Integer);
begin
  FChanState[Ch].Released := True;
end;

procedure TFurnaceDecoder.TickMacro(var S: TMacroState; const M: TFurnaceMacro);
var
  First: Boolean;
  Phase, Rate, Sustain: Integer;
  Level: Int64;
begin
  S.Had := False;
  if (M.Len = 0) or S.Stopped then
    Exit;
  First := not S.Started;
  if S.Released and (M.TypeId = 0) and M.ActiveRelease and
    (S.Pos < M.RelPos) and (M.RelPos < M.Len) then
  begin
    S.Tick := 0;
    S.Pos := M.RelPos;
  end;
  if S.Released and (M.TypeId = 1) and (S.LastPos < 3) then
  begin
    S.Tick := 0;
    S.LastPos := 3;
  end;
  if S.Tick > 0 then
  begin
    Dec(S.Tick);
    Exit;
  end;
  S.Started := True;
  if First and (M.Delay > 0) then
    S.Tick := M.Delay
  else
    S.Tick := M.Speed - 1;

  case M.TypeId of
    0:
      begin
        S.Val := M.Values[S.Pos];
        Inc(S.Pos);
        if not S.Released and (S.Pos > M.RelPos) then
        begin
          if (M.LoopPos < M.Len) and (M.LoopPos < M.RelPos) then
            S.Pos := M.LoopPos
          else
            Dec(S.Pos);
        end;
        if S.Pos >= M.Len then
        begin
          if (M.LoopPos < M.Len) and ((M.LoopPos >= M.RelPos) or (M.RelPos >= M.Len)) then
            S.Pos := M.LoopPos
          else
            S.Stopped := True;
        end;
      end;
    1:
      begin
        if M.Len < 9 then
        begin
          S.Stopped := True;
          S.Started := False;
          Exit;
        end;
        case S.LastPos of
          0:
            begin
              S.Pos := Min(255, S.Pos + EnsureRange(M.Values[2], 0, 255));
              if S.Pos = 255 then
              begin
                S.LastPos := 1;
                S.Tick := EnsureRange(M.Values[3], 0, 255);
              end;
            end;
          1:
            begin
              Sustain := EnsureRange(M.Values[5], 0, 255);
              S.Pos := Max(Sustain, S.Pos - EnsureRange(M.Values[4], 0, 255));
              if S.Pos = Sustain then
              begin
                S.LastPos := 2;
                S.Tick := EnsureRange(M.Values[6], 0, 255);
              end;
            end;
          2, 3:
            begin
              S.Pos := Max(0, S.Pos - EnsureRange(M.Values[S.LastPos + 5], 0, 255));
              if S.Pos = 0 then
                S.Stopped := True;
            end;
        end;
        Level := M.Values[0] + (Int64(S.Pos) * (Int64(M.Values[1]) - M.Values[0])) div 256;
        S.Val := Integer(Level);
      end;
    2:
      begin
        if M.Len < 5 then
        begin
          S.Stopped := True;
          S.Started := False;
          Exit;
        end;
        if First then
          S.Pos := M.Values[4] and 1023;
        Rate := M.Values[2] and 1023;
        S.Pos := (S.Pos + Rate) and 1023;
        Phase := S.Pos;
        case M.Values[3] and 3 of
          0:
            if Phase < 512 then
              Phase := Phase * 2
            else
              Phase := (1023 - Phase) * 2;
          2:
            if Phase < 512 then
              Phase := 0
            else
              Phase := 1024;
        end;
        Level := M.Values[0] + (Int64(Phase) * (Int64(M.Values[1]) - M.Values[0])) div 1024;
        S.Val := Integer(Level);
      end;
  else
    S.Stopped := True;
    S.Started := False;
    Exit;
  end;
  S.Had := True;
end;

procedure TFurnaceDecoder.TickMacros;
var
  Ch: Integer;
  Voice: ^TChannelState;
  Ins: TFurnaceInstrument;

  procedure Step(var State: TMacroState; const Macro: TFurnaceMacro);
  begin
    State.Released := Voice^.Released;
    TickMacro(State, Macro);
  end;

begin
  for Ch := 0 to 2 do
  begin
    Voice := @FChanState[Ch];
    if Voice^.DelayedTick >= 0 then
    begin
      if Voice^.DelayedTick = 0 then
        ApplyChannelRow(Ch, Voice^.DelayedRow);
      Dec(Voice^.DelayedTick);
    end;
    if Voice^.CutTick >= 0 then
    begin
      if Voice^.CutTick = 0 then
        CutNote(Ch);
      Dec(Voice^.CutTick);
    end;
    if Voice^.Note < 0 then
      Continue;

    if FTickInRow > 0 then
    begin
      Voice^.Volume256 := EnsureRange(Voice^.Volume256 + Voice^.VolumeSlide, 0, 15 * 256);
      if Voice^.SlideTarget >= 0 then
      begin
        var Target := NotePeriod(Voice^.SlideTarget) - NotePeriod(Voice^.Note);
        if Voice^.SlideOffset < Target then
          Voice^.SlideOffset := Min(Target, Voice^.SlideOffset + Voice^.SlideRate)
        else
          Voice^.SlideOffset := Max(Target, Voice^.SlideOffset - Voice^.SlideRate);
        if Voice^.SlideOffset = Target then
        begin
          Voice^.Note := Voice^.SlideTarget;
          Voice^.SlideTarget := -1;
          Voice^.SlideOffset := 0;
          Voice^.SlideRate := 0;
        end;
      end
      else
        Voice^.SlideOffset := EnsureRange(Voice^.SlideOffset + Voice^.SlideRate, -262144.0, 4095.0);
    end;

    if InRange(Voice^.PlayingInstrument, 0, High(FInstruments)) then
    begin
      Ins := FInstruments[Voice^.PlayingInstrument];
      Step(Voice^.VolState, Ins.VolMacro);
      Step(Voice^.ArpState, Ins.ArpMacro);
      Step(Voice^.NoiseState, Ins.NoiseMacro);
      Step(Voice^.WaveState, Ins.WaveMacro);
      Step(Voice^.PitchState, Ins.PitchMacro);
      Step(Voice^.EnvState, Ins.EnvMacro);
      Step(Voice^.EnvPeriodState, Ins.EnvPeriodMacro);
      Step(Voice^.EnvNumState, Ins.EnvNumMacro);
      Step(Voice^.EnvDenState, Ins.EnvDenMacro);
      Step(Voice^.FixedPeriodState, Ins.FixedPeriodMacro);
      if Voice^.PitchState.Had then
        if Ins.PitchMacro.Mode = 0 then
          Voice^.PitchOffset := Voice^.PitchState.Val
        else
          Voice^.PitchOffset := Integer(EnsureRange(Int64(Voice^.PitchOffset) + Voice^.PitchState.Val,
              Int64(-32768), Int64(32767)));
    end;
    ApplyChannel(Ch);
    Voice^.ArpTick := (Voice^.ArpTick + 1) mod (Voice^.ArpSpeed * 3);
    Voice^.VibratoPhase := (Voice^.VibratoPhase + (Voice^.Vibrato shr 4)) and 63;
  end;

  Inc(FEnvSlideFraction, FEnvSlide);
  if Abs(FEnvSlideFraction) >= 8 then
  begin
    var Period := FYM.ReadRegister(11) or (Integer(FYM.ReadRegister(12)) shl 8);
    Period := EnsureRange(Period + FEnvSlideFraction div 8, 0, 65535);
    FEnvSlideFraction := FEnvSlideFraction mod 8;
    FYM.WriteRegister(11, Period and $FF);
    FYM.WriteRegister(12, Period shr 8);
  end;
end;

procedure TFurnaceDecoder.ApplyChannel(Ch: Integer);
var
  Voice: ^TChannelState;
  Vol, Tone, Wave, EnvPeriod, Mixer: Integer;
  Pitch: Double;
  Note: Int64;
  Arp: Cardinal;
begin
  Voice := @FChanState[Ch];
  Vol := Voice^.Volume256 shr 8;
  if Voice^.VolState.Started then
    Vol := Max(0, Vol + EnsureRange(Voice^.VolState.Val, 0, 15) - 15);
  Note := Voice^.Note;
  if Voice^.ArpState.Started then
  begin
    Arp := Cardinal(Voice^.ArpState.Val);
    if ((Arp xor (Arp shl 1)) and $80000000) <> 0 then
      Note := Int64(Integer(Arp xor $40000000)) + 60
    else
      Inc(Note, Integer(Arp));
  end;
  case Voice^.ArpTick div Voice^.ArpSpeed of
    1:
      Inc(Note, Voice^.Arp shr 4);
    2:
      Inc(Note, Voice^.Arp and 15);
  end;
  if Voice^.WaveState.Had then
  begin
    Voice^.MixerMode := Voice^.WaveState.Val and 7;
    Voice^.MixerOverride := True;
    Voice^.EnvOverride := False;
  end;
  Wave := 1;
  if Voice^.MixerOverride then
    Wave := Voice^.MixerMode;
  if Voice^.EnvOverride then
  begin
    Wave := Wave and not 4;
    if Voice^.EnvEnabled then
      Wave := Wave or 4;
  end;
  if Voice^.NoiseState.Had then
    FYM.WriteRegister(6, (31 - (Voice^.NoiseState.Val and $1F)));

  Pitch := (Voice^.FinePitch / 128) +
    Sin(Voice^.VibratoPhase * (2 * Pi / 64)) * (Voice^.Vibrato and 15) / 15;
  Tone := EnsureRange(Round(NotePeriod(Note) * Power(2.0, -Pitch / 12) +
      Voice^.SlideOffset - Voice^.PitchOffset / 2), 1, 4095);
  if Voice^.FixedPeriodState.Started and (Voice^.FixedPeriodState.Val > 0) then
    Tone := Min(4095, Voice^.FixedPeriodState.Val);
  FYM.WriteRegister(Ch * 2, Tone and $FF);
  FYM.WriteRegister(Ch * 2 + 1, Tone shr 8);

  Mixer := FYM.ReadRegister(7) or (1 shl Ch) or (1 shl (Ch + 3));
  if (Wave and 1) <> 0 then
    Mixer := Mixer and not (1 shl Ch);
  if (Wave and 2) <> 0 then
    Mixer := Mixer and not (1 shl (Ch + 3));
  FYM.WriteRegister(7, Mixer);

  if Voice^.EnvNumState.Had then
  begin
    Voice^.EnvNum := EnsureRange(Voice^.EnvNumState.Val, 0, 65535);
    if not Voice^.EnvDenState.Started then
      Voice^.EnvDen := 1;
  end;
  if Voice^.EnvDenState.Had then
  begin
    Voice^.EnvDen := EnsureRange(Voice^.EnvDenState.Val, 0, 65535);
    if not Voice^.EnvNumState.Started then
      Voice^.EnvNum := 1;
  end;
  EnvPeriod := -1;
  if Voice^.EnvPeriodState.Had then
    EnvPeriod := EnsureRange(Voice^.EnvPeriodState.Val, 0, 65535);
  if (Voice^.EnvNum > 0) and (Voice^.EnvDen > 0) and
    ((Tone <> Voice^.Tone) or Voice^.EnvNumState.Had or Voice^.EnvDenState.Had) then
    EnvPeriod := Integer((Int64(Tone) * Voice^.EnvDen div Voice^.EnvNum) shr 4);
  Voice^.Tone := Tone;
  if EnvPeriod >= 0 then
  begin
    FYM.WriteRegister(11, EnvPeriod and $FF);
    FYM.WriteRegister(12, (EnvPeriod shr 8) and $FF);
  end;
  if Voice^.EnvState.Had then
    FYM.WriteRegister(13, Voice^.EnvState.Val and $0F);
  if (Wave and 4) <> 0 then
    Vol := Vol or $10;
  FYM.WriteRegister(8 + Ch, Vol);
end;

function TFurnaceDecoder.CurrentRowSpeed: Integer;
begin
  Result := FSpeeds[FSpeedsPos];
end;

procedure TFurnaceDecoder.ApplyEffect(Ch, Effect, Param: Integer);
var
  I: Integer;
const
  ChannelModes: array[0..7] of Byte = (1, 2, 3, 4, 5, 6, 7, 0);
begin
  Param := EnsureRange(Param, 0, 255);
  case Effect of
    $09:
      if FGrooveCount = 0 then
      begin
        if Param > 0 then
          FSpeeds[0] := Param;
      end
      else if Param < FGrooveCount then
      begin
        FSpeedsLen := FGrooveLens[Param];
        FSpeedsPos := 0;
        for I := 0 to FSpeedsLen - 1 do
          FSpeeds[I] := FGrooves[Param][I];
      end;
    $0F:
      if Param > 0 then
        if (FSpeedsLen = 2) and (FGrooveCount = 0) then
          FSpeeds[1] := Param
        else
          FSpeeds[0] := Param;
    $0B:
      FJumpOrder := Param;
    $0D:
      FBreakRow := Param;
    $20:
      begin
        FChanState[Ch].MixerMode := ChannelModes[Param and 7];
        FChanState[Ch].MixerOverride := True;
        FChanState[Ch].EnvOverride := False;
      end;
    $21:
      FYM.WriteRegister(6, 31 - (Param and $1F));
    $22:
      begin
        FYM.WriteRegister(13, Param shr 4);
        FChanState[Ch].EnvOverride := True;
        FChanState[Ch].EnvEnabled := (Param and 15) <> 0;
      end;
    $23:
      FYM.WriteRegister(11, Param);
    $24:
      FYM.WriteRegister(12, Param);
    $25:
      FEnvSlide := Param;
    $26:
      FEnvSlide := -Param;
    $29:
      begin
        FChanState[Ch].EnvNum := Param shr 4;
        FChanState[Ch].EnvDen := Param and 15;
        FChanState[Ch].Tone := -1;
      end;
    $00:
      FChanState[Ch].Arp := Param;
    $01, $02:
      begin
        FChanState[Ch].SlideTarget := -1;
        if Effect = $01 then
          FChanState[Ch].SlideRate := -Param
        else
          FChanState[Ch].SlideRate := Param;
      end;
    $04:
      FChanState[Ch].Vibrato := Param;
    $0A:
      if (Param and 15) <> 0 then
        FChanState[Ch].VolumeSlide := -(Param and 15) * 64
      else
        FChanState[Ch].VolumeSlide := (Param shr 4) * 64;
    $E0:
      FChanState[Ch].ArpSpeed := Max(1, Param);
    $E1, $E2:
      if FChanState[Ch].Note >= 0 then
      begin
        var Delta := Param and 15;
        if Effect = $E2 then
          Delta := -Delta;
        FChanState[Ch].SlideTarget := EnsureRange(FChanState[Ch].Note + Delta, 0, 179);
        FChanState[Ch].SlideRate := Max(1, Param shr 4);
      end;
    $E5:
      FChanState[Ch].FinePitch := Param - 128;
    $EC:
      if Param > 0 then
        FChanState[Ch].CutTick := Param;
    $C0..$C3:
      FTickRate := Max(1, ((Effect and 3) shl 8) or Param);
    $F0:
      FTickRate := Max(1.0, Param * 0.4);
    $FD:
      if Param <> 0 then
        FVirtNum := Param;
    $FE:
      if Param <> 0 then
        FVirtDen := Param;
    $FF:
      FStopPending := True;
  end;
end;

procedure TFurnaceDecoder.ApplyChannelRow(Ch: Integer; const RowData: TTrackRow);
var
  I, Portamento: Integer;
  Voice: ^TChannelState;
begin
  Voice := @FChanState[Ch];
  Portamento := 0;
  for I := 0 to High(RowData.Effects) do
    case RowData.Effects[I] of
      $03:
        Portamento := Max(0, Integer(RowData.Params[I]));
      $09, $0B, $0D, $0F, $C0..$C3, $ED, $F0, $FD..$FF:
        ;
    else
      if RowData.Effects[I] >= 0 then
        ApplyEffect(Ch, RowData.Effects[I], RowData.Params[I]);
    end;
  if RowData.Instrument >= 0 then
    Voice^.Instrument := RowData.Instrument;
  if RowData.Volume >= 0 then
    Voice^.Volume256 := Min(15, Integer(RowData.Volume)) * 256;

  case RowData.Note of
    0..179:
      if (Portamento > 0) and (Voice^.Note >= 0) then
      begin
        Voice^.SlideTarget := RowData.Note;
        Voice^.SlideRate := Portamento;
      end
      else
        TriggerNote(Ch, RowData.Note, Voice^.Instrument, Voice^.Volume256);
    180:
      CutNote(Ch);
    181, 182:
      ReleaseNote(Ch);
  end;
end;

procedure TFurnaceDecoder.ApplyPatternRow(Order, PatRow: Integer);
var
  Ch, I, Delay: Integer;
  RowData: TTrackRow;
begin
  for Ch := 0 to 2 do
  begin
    RowData := FNoteTable[Ch][FOrders[Order * 3 + Ch]][PatRow];
    Delay := 0;
    for I := 0 to High(RowData.Effects) do
      case RowData.Effects[I] of
        $09, $0B, $0D, $0F, $C0..$C3, $F0, $FD..$FF:
          ApplyEffect(Ch, RowData.Effects[I], RowData.Params[I]);
        $ED:
          Delay := Max(0, Integer(RowData.Params[I]));
      end;
    if Delay > 0 then
    begin
      FChanState[Ch].DelayedTick := Delay;
      FChanState[Ch].DelayedRow := RowData;
    end
    else
      ApplyChannelRow(Ch, RowData);
  end;
end;

procedure TFurnaceDecoder.ResetPlayback;
var
  I: Integer;
begin
  FYM.Reset;
  FCurrentOrder := 0;
  FCurrentPatRow := 0;
  FTickInRow := 0;
  FSampleAcc := 0;
  FEnvSlide := 0;
  FEnvSlideFraction := 0;
  FFramesLeft := 0;
  FJumpOrder := -1;
  FBreakRow := -1;
  FSpeedsPos := 0;
  FFinished := False;
  FStopPending := False;
  FTickRate := FInitialTickRate;
  FVirtNum := FInitialVirtNum;
  FVirtDen := FInitialVirtDen;
  FSpeedsLen := FInitialSpeedsLen;
  for I := 0 to High(FSpeeds) do
    FSpeeds[I] := FInitialSpeeds[I];
  FillChar(FVisited, SizeOf(FVisited), 0);
  for I := 0 to 2 do
    InitChannelState(I);
end;

function TFurnaceDecoder.BeginTick: Boolean;
begin
  if FFinished then
    Exit(False);
  if FTickInRow = 0 then
  begin
    if FVisited[FCurrentOrder, FCurrentPatRow] then
    begin
      FFinished := True;
      Exit(False);
    end;
    FVisited[FCurrentOrder, FCurrentPatRow] := True;
    ApplyPatternRow(FCurrentOrder, FCurrentPatRow);
  end;
  FSampleAcc := FSampleAcc + (FInfo.SampleRate / FTickRate) * FVirtDen / FVirtNum;
  FFramesLeft := Trunc(FSampleAcc);
  FSampleAcc := FSampleAcc - FFramesLeft;
  Result := True;
end;

procedure TFurnaceDecoder.EndTick;
begin
  Inc(FTickInRow);
  if FTickInRow < CurrentRowSpeed then
    Exit;
  FTickInRow := 0;
  FSpeedsPos := (FSpeedsPos + 1) mod FSpeedsLen;
  if FStopPending then
    FFinished := True
  else if (FJumpOrder >= 0) or (FBreakRow >= 0) then
  begin
    if FJumpOrder >= 0 then
      FCurrentOrder := FJumpOrder
    else
      Inc(FCurrentOrder);
    FCurrentPatRow := Max(0, FBreakRow);
    if FCurrentPatRow >= FPatternLength then
      FCurrentPatRow := 0;
  end
  else
  begin
    Inc(FCurrentPatRow);
    if FCurrentPatRow >= FPatternLength then
    begin
      FCurrentPatRow := 0;
      Inc(FCurrentOrder);
    end;
  end;
  FFinished := FFinished or (FCurrentOrder >= FOrdersLen);
  FJumpOrder := -1;
  FBreakRow := -1;
end;

function TFurnaceDecoder.CountFrames: Int64;
begin
  ResetPlayback;
  try
    Result := 0;
    while BeginTick do
    begin
      // The row has already applied its tempo effects. Count its remaining ticks at once.
      var Ticks := CurrentRowSpeed - 1;
      FSampleAcc := FSampleAcc + Ticks * (FInfo.SampleRate / FTickRate) * FVirtDen / FVirtNum;
      var Extra := Trunc(FSampleAcc);
      Inc(Result, FFramesLeft + Extra);
      FSampleAcc := FSampleAcc - Extra;
      FTickInRow := Ticks;
      EndTick;
    end;
  finally
    ResetPlayback;
  end;
end;

constructor TFurnaceDecoder.Create(const Data: TBytes);
var
  Center, Side: Double;
begin
  inherited Create;
  FInfo.FormatName := 'Furnace (AY)';
  FInfo.Channels := 2;
  FInfo.SampleRate := 44100;
  FInfo.TrackCount := 1;
  BuildSong(Data);
  FInfo.Details := Format('Furnace v%d / AY @ %d Hz / %d orders',
    [FFormatVer, FClockHz, FOrdersLen]);
  FYM := TYM2149F.Create(FClockHz, FInfo.SampleRate, not FHalfClock);
  FYM.AYModel := FAYModel;
  Center := Min(1.0, 0.7071 * FMasterVolume);
  Side := Center;
  if FStereo then
    Side := Side * (1 - FStereoSep / 255);
  FYM.SetPan(0, Center, Side);
  FYM.SetPan(1, Center, Center);
  FYM.SetPan(2, Side, Center);
  FInfo.TrackDurations := [CountFrames / FInfo.SampleRate];
end;

destructor TFurnaceDecoder.Destroy;
begin
  FYM.Free;
  inherited;
end;

function TFurnaceDecoder.GetInfo: TAudioInfo;
begin
  Result := FInfo;
end;

procedure TFurnaceDecoder.SelectTrack(Index: Integer);
begin
  if Index <> 0 then
    raise EArgumentOutOfRangeException.Create('Furnace track');
  ResetPlayback;
end;

function TFurnaceDecoder.Render(var Samples: array of SmallInt; Frames: Integer): Integer;
var
  Count, I: Integer;
begin
  ValidateRender(Length(Samples), Frames, 2);
  Result := 0;
  while (Result < Frames) and not FFinished do
  begin
    if FFramesLeft = 0 then
    begin
      if not BeginTick then
        Break;
      TickMacros;
    end;
    Count := Integer(Min(FFramesLeft, Int64(Frames - Result)));
    for I := Result to Result + Count - 1 do
      FYM.Sample(Samples[I * 2], Samples[I * 2 + 1]);
    Inc(Result, Count);
    Dec(FFramesLeft, Count);
    if FFramesLeft = 0 then
      EndTick;
  end;
end;

function TFurnaceDecoder.SeekFrame(Frame: Int64; const Cancelled: TFunc<Boolean>): Int64;
var
  Buffer: array[0..8191] of SmallInt;
  Count: Integer;
begin
  if Frame < 0 then
    raise EArgumentOutOfRangeException.Create('Furnace seek frame');
  SelectTrack(0);
  Result := 0;
  while Result < Frame do
  begin
    if Assigned(Cancelled) and Cancelled() then
      Break;
    Count := Render(Buffer, Integer(Min(Frame - Result, Int64(4096))));
    if Count = 0 then
      Break;
    Inc(Result, Count);
  end;
end;

function OpenFurnace(const Data: TBytes): IAudioSource;
begin
  Result := TFurnaceDecoder.Create(Data);
end;

end.

