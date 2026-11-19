unit Audio.Music.Tracker.Amiga.XM;

interface

uses
  System.SysUtils, System.Math, System.Generics.Collections, Core.AudioFilter;

type
  TEnvPoint = record
    X, Y: Integer;
  end;

  TXMSample = record
    Name: string;
    Data: TArray<SmallInt>;
    Length, LoopStart, LoopLength: Cardinal;
    Volume, Panning, RelativeNote: Integer;
    Finetune: Integer;
    Is16Bit: Boolean;
    LoopType: Integer;
  end;

  TXMInstrument = record
    Name: string;
    SampleOfNote: array[0..95] of Integer;
    VolEnv, PanEnv: TArray<TEnvPoint>;
    VolEnvPoints, PanEnvPoints: Integer;
    VolSusPoint, VolLoopStart, VolLoopEnd: Integer;
    PanSusPoint, PanLoopStart, PanLoopEnd: Integer;
    VolEnvOn, VolSusOn, VolLoopOn: Boolean;
    PanEnvOn, PanSusOn, PanLoopOn: Boolean;
    VibratoType, VibratoSweep, VibratoDepth, VibratoRate: Integer;
    VolumeFadeOut: Integer;
    NumSamples: Integer;
    FirstSampleIdx: Integer;
  end;

  TXMCell = record
    Note, Instrument: Integer;
    Volume: Integer;
    Effect, Param: Integer;
  end;

  TXMPattern = record
    Rows: Integer;
    Cells: TArray<TXMCell>;
  end;

  TXMVoice = record
    SampleIdx, InstrumentIdx, Note, Volume, Panning: Integer;
    Finetune: Integer;
    Period, TargetPeriod: Double;
    PortaUpSpeed, PortaDownSpeed, TonePortaSpeed: Integer;
    Position, SampleStep: Double;
    CurAmp: Double;
    PingPongDir: Integer;
    Active, KeyOff, Fading: Boolean;
    VibratoPhase, VibratoSpeed, VibratoDepth, VibratoWave: Integer;
    VibratoOffset: Double;
    TremoloPhase, TremoloSpeed, TremoloDepth, TremoloWave: Integer;
    TremoloOffset: Integer;
    ArpOffset: Integer;
    AutoVibTicks: Integer;
    AutoVibOffset: Double;
    VolSlideMem, GlobalVolSlideMem, PanSlideMem, Glissando: Integer;
    PortamentoActive: Boolean;
    VolEnvPos, PanEnvPos: Integer;
    VolEnvVal: Double;
    PanEnvVal: Integer;
    FadeVol: Double;
    FadeDec: Integer;
    RetrigCount, TremorMem, TremorPos, OffsetMem: Integer;
    DelayTicks, LoopRow, LoopCount: Integer;
    DelayCell: TXMCell;
  end;

  { TXM }

  TXM = class
  private
    FTitle: string;
    FChannels, FInitialSpeed, FInitialTempo: Integer;
    FLinearPeriods: Boolean;
    FOrders: TArray<Integer>;
    FPatterns: TArray<TXMPattern>;
    FSamples: TArray<TXMSample>;
    FInstruments: TArray<TXMInstrument>;
    FVoices: TArray<TXMVoice>;
    FOrder, FRow, FTick, FSpeed, FTempo: Integer;
    FGlobalVolume: Integer;
    FTempoFraction: Double;
    FSamplesLeft: Integer;
    FEnded: Boolean;
    FVisited: TDictionary<string, Byte>;
    FJumpPending, FBreakPending: Boolean;
    FJumpOrder, FJumpRow, FBreakRow: Integer;
    FPatternDelay: Integer;
    FInDelayRow: Boolean;
    FLoopJumpPending: Boolean;
    FFilter: array[0..1] of TPCMLowPass;
    FDC: array[0..1] of TPCMDCBlocker;
    FLastL, FLastR: SmallInt;
    FSampleRate: Integer;
    FMixGain: Double;
    FMasterVolume: Double;
    FAmigaFilter: Boolean;
    FStrictSampleMap: Boolean;
    FRampMs: Double;
    FRampStep: Double;

    procedure LoadXM(const Data: TBytes);
    function PatternRows(Pat: Integer): Integer;
    function CellAt(Pat, Row, Ch: Integer): TXMCell;
    procedure BeginRow;
    procedure ApplyVolumeColumn(Ch: Integer; const Cell: TXMCell; Tick: Integer);
    procedure ApplyEffectRow(Ch: Integer; const Cell: TXMCell);
    procedure ApplyTick(Ch, Tick: Integer; const Cell: TXMCell);
    procedure TriggerNote(Ch: Integer; const Cell: TXMCell);
    procedure ResetEnvelopes(Ch: Integer);
    procedure ReleaseVoice(Ch: Integer);
    procedure AdvanceEnvelopes(Ch: Integer);
    procedure AdvanceRow;
    procedure AdvanceVoice(var Voice: TXMVoice; const S: TXMSample);
    procedure MixFrame;
    function NextTick: Boolean;
    function EnvInterp(const E: TArray<TEnvPoint>; Pos: Integer): Integer;
    function NoteToPeriod(Note16: Double): Double;
    function PeriodToFreq(P: Double): Double;
    function VoiceFrequency(const V: TXMVoice): Double;
    function MixVoiceSample(const S: TXMSample; Pos: Double): Double;
  public
    constructor Create(const Data: TBytes);
    destructor Destroy; override;
    procedure Reset;
    function FrameCount: Int64;
    function Skip(Frames: Integer): Integer;
    function Sample(out Left, Right: SmallInt): Boolean;
    property Title: string read FTitle;
    property Channels: Integer read FChannels;
    property LinearPeriods: Boolean read FLinearPeriods;
    property MasterVolume: Double read FMasterVolume write FMasterVolume;
    property AmigaFilter: Boolean read FAmigaFilter write FAmigaFilter;
    property StrictSampleMap: Boolean read FStrictSampleMap write FStrictSampleMap;
    property RampMs: Double read FRampMs write FRampMs;
    property OrderIndex: Integer read FOrder;
    property RowIndex: Integer read FRow;
    property SampleRate: Integer read FSampleRate;
  end;

implementation

uses
  Audio.Binary;

const
  FX_ARPEGGIO = $00;
  FX_PORTA_UP = $01;
  FX_PORTA_DOWN = $02;
  FX_TONE_PORTA = $03;
  FX_VIBRATO = $04;
  FX_TONE_PORTA_VOLSLIDE = $05;
  FX_VIBRATO_VOLSLIDE = $06;
  FX_TREMOLO = $07;
  FX_PAN = $08;
  FX_OFFSET = $09;
  FX_VOLSLIDE = $0A;
  FX_JUMP = $0B;
  FX_SETVOL = $0C;
  FX_BREAK = $0D;
  FX_EXTRA = $0E;
  FX_SPEED = $0F;
  FX_GLOBALVOL = $10;
  FX_GLOBALVOLSLIDE = $11;
  FX_KEYOFF = $14;
  FX_ENVPOS = $15;
  FX_PANSLIDE = $19;
  FX_RETRIG = $1B;
  FX_TREMOR = $1D;
  FX_EXTRAFINE = $21;
  FV_SETVOL = $1;
  FV_VOLDOWN = $6;
  FV_VOLUP = $7;
  FV_FINEDOWN = $8;
  FV_FINEUP = $9;
  FV_VIBSPEED = $A;
  FV_VIBRATO = $B;
  FV_PAN = $C;
  FV_PANLEFT = $D;
  FV_PANRIGHT = $E;
  FV_TONEPORTA = $F;
  XM_REF_NOTE = 49;
  XM_REF_FREQ = 8363.0;
  Sine: array[0..63] of Integer = (
    0, 24, 49, 74, 97, 120, 141, 161, 180, 197, 212, 224, 235, 244, 250, 253,
    255, 253, 250, 244, 235, 224, 212, 197, 180, 161, 141, 120, 97, 74, 49, 24,
    0, -24, -49, -74, -97, -120, -141, -161, -180, -197, -212, -224, -235, -244, -250, -253,
    -255, -253, -250, -244, -235, -224, -212, -197, -180, -161, -141, -120, -97, -74, -49, -24);

function EffectWave(Phase, Wave: Integer): Integer;
begin
  Phase := Phase and 63;
  case Wave and 3 of
    0:
      Result := Sine[Phase];
    1:
      Result := (Phase and 31) * 8;
  else
    Result := 255;
  end;
  if (Wave and 3) <> 0 then
    if Phase >= 32 then
      if (Wave and 3) = 1 then
        Dec(Result, 255)
      else
        Result := -Result;
end;

function Wrap8(V: Integer): Integer; inline;
begin
  Result := ((V + 128) and $FF) - 128;
end;

function Wrap16(V: Integer): Integer; inline;
begin
  Result := ((V + 32768) and $FFFF) - 32768;
end;

constructor TXM.Create(const Data: TBytes);
begin
  inherited Create;
  FSampleRate := 44100;
  FVisited := TDictionary<string, Byte>.Create;
  FFilter[0].Configure(FSampleRate, 3275);
  FFilter[0].Reset;
  FFilter[1].Configure(FSampleRate, 3275);
  FFilter[1].Reset;
  FDC[0].Configure(FSampleRate, 5);
  FDC[0].Reset;
  FDC[1].Configure(FSampleRate, 5);
  FDC[1].Reset;
  FAmigaFilter := False;
  FStrictSampleMap := True;
  FRampMs := 1.0;
  FMasterVolume := 1.0;
  LoadXM(Data);
  Reset;
end;

destructor TXM.Destroy;
begin
  FVisited.Free;
  inherited;
end;

procedure TXM.Reset;
var
  C: Integer;
begin
  SetLength(FVoices, FChannels);
  for C := 0 to High(FVoices) do
  begin
    FVoices[C] := Default(TXMVoice);
    FVoices[C].Panning := 128;
    FVoices[C].FadeVol := 1.0;
    FVoices[C].VolEnvVal := 1.0;
    FVoices[C].PanEnvVal := 32;
    FVoices[C].PingPongDir := 1;
    FVoices[C].SampleIdx := -1;
    FVoices[C].InstrumentIdx := -1;
  end;
  FVisited.Clear;
  FOrder := 0;
  FRow := 0;
  FTick := 0;
  FSpeed := EnsureRange(FInitialSpeed, 1, 255);
  FTempo := EnsureRange(FInitialTempo, 32, 255);
  FGlobalVolume := 64;
  FTempoFraction := 0;
  FSamplesLeft := 0;
  FEnded := False;
  FJumpPending := False;
  FBreakPending := False;
  FJumpOrder := 0;
  FJumpRow := 0;
  FBreakRow := 0;
  FPatternDelay := 0;
  FInDelayRow := False;
  FLoopJumpPending := False;
  FMixGain := Min(1.0, 1.6 / Sqrt(Max(1, FChannels)));
  if FRampMs > 0 then
    FRampStep := 1.0 / (FRampMs * 0.001 * FSampleRate)
  else
    FRampStep := 1.0;
  FFilter[0].Reset;
  FFilter[1].Reset;
  FDC[0].Reset;
  FDC[1].Reset;
end;

procedure TXM.LoadXM(const Data: TBytes);
var
  HeaderSize, SongLen, PatCount, InsCount, N, i, j, k: Integer;
  P, Start, PH, Rows, PackedSize, DataStart, InstEnd: Integer;
  InstSize, SampleHeaderSize, PatternEnd: Integer;
  NS, B, Mask: Integer;
  C: TXMCell;
  Acc, SmpVal: Integer;
  VolPts, PanPts: TArray<TEnvPoint>;
  NVol, NPan, Sus, LSp, LEp, VType, PType, FadeVal: Integer;
  PSus, PLSp, PLEp: Integer;
  RawLen, RawLoopStart, RawLoopLen: Int64;
  BytesPerSample: Integer;

  function IBS(Off: Integer): Integer;
  begin
    if (Off >= Start) and (Off < InstEnd) then
      Result := Data[Off]
    else
      Result := 0;
  end;

  function IWS(Off: Integer): Integer;
  begin
    if (Off >= Start) and (Off + 1 < InstEnd) then
      Result := LE16(Data, Off)
    else
      Result := 0;
  end;

  function PatternByte: Byte;
  begin
    if P >= PatternEnd then
      raise EArgumentException.Create('XM: truncated pattern cell');
    Result := Data[P];
    Inc(P);
  end;

begin
  if Length(Data) < 80 then
    raise Exception.Create('XM: too short');
  if TEncoding.ASCII.GetString(Data, 0, 17) <> 'Extended Module: ' then
    raise Exception.Create('XM: invalid signature');

  FTitle := TextField(Data, 17, 20);
  if (Data[37] <> $1A) or (LE16(Data, 58) <> $0104) then
    raise EArgumentException.Create('XM: expected FastTracker II format 1.04');
  if (LE32(Data, 60) < 20) or (LE32(Data, 60) > Cardinal(Length(Data) - 60)) then
    raise EArgumentException.Create('XM: invalid song header size');
  HeaderSize := Integer(LE32(Data, 60));
  SongLen := LE16(Data, 64);
  if (SongLen < 1) or (SongLen > 256) or (SongLen > HeaderSize - 20) then
    raise EArgumentException.Create('XM: invalid order list');
  FChannels := LE16(Data, 68);
  PatCount := LE16(Data, 70);
  InsCount := LE16(Data, 72);
  if (PatCount > 256) or (InsCount > 255) then
    raise EArgumentException.Create('XM: invalid pattern or instrument count');
  FLinearPeriods := (LE16(Data, 74) and 1) <> 0;
  FInitialSpeed := LE16(Data, 76);
  FInitialTempo := LE16(Data, 78);
  if (FChannels < 1) or (FChannels > 64) then
    raise Exception.Create('XM: invalid channel count');
  if FInitialSpeed = 0 then
    FInitialSpeed := 6;
  if FInitialTempo = 0 then
    FInitialTempo := 125;

  SetLength(FOrders, SongLen);
  for i := 0 to SongLen - 1 do
    FOrders[i] := Data[80 + i];

  SetLength(FPatterns, PatCount);
  P := 60 + HeaderSize;
  for i := 0 to PatCount - 1 do
  begin
    Start := P;
    if (Length(Data) - Start < 9) or (LE32(Data, Start) < 9) or
      (LE32(Data, Start) > Cardinal(Length(Data) - Start)) or (Data[Start + 4] <> 0) then
      raise EArgumentException.Create('XM: invalid pattern header');
    PH := Integer(LE32(Data, Start));
    Rows := LE16(Data, Start + 5);
    if (Rows < 1) or (Rows > 256) then
      raise EArgumentException.Create('XM: invalid pattern row count');
    PackedSize := LE16(Data, Start + 7);
    FPatterns[i].Rows := Rows;
    SetLength(FPatterns[i].Cells, Rows * FChannels);
    for j := 0 to High(FPatterns[i].Cells) do
      FPatterns[i].Cells[j] := Default(TXMCell);
    DataStart := Start + PH;
    if PackedSize > Length(Data) - DataStart then
      raise EArgumentException.Create('XM: truncated pattern data');
    PatternEnd := DataStart + PackedSize;
    P := DataStart;
    if PackedSize = 0 then
      Continue;
    for j := 0 to Rows - 1 do
      for k := 0 to FChannels - 1 do
      begin
        C := Default(TXMCell);
        B := PatternByte;
        if (B and $80) <> 0 then
        begin
          Mask := B;
          if (Mask and 1) <> 0 then
            C.Note := PatternByte;
          if (Mask and 2) <> 0 then
            C.Instrument := PatternByte;
          if (Mask and 4) <> 0 then
            C.Volume := PatternByte;
          if (Mask and 8) <> 0 then
            C.Effect := PatternByte;
          if (Mask and 16) <> 0 then
            C.Param := PatternByte;
        end
        else
        begin
          C.Note := B;
          C.Instrument := PatternByte;
          C.Volume := PatternByte;
          C.Effect := PatternByte;
          C.Param := PatternByte;
        end;
        if C.Note = 97 then
          C.Note := 255;
        if (C.Note <> 255) and ((C.Note < 1) or (C.Note > 96)) then
          C.Note := 0;
        FPatterns[i].Cells[j * FChannels + k] := C;
      end;
    if P <> PatternEnd then
      raise EArgumentException.Create('XM: invalid packed pattern size');
  end;

  SetLength(FInstruments, InsCount);
  SetLength(FSamples, 0);

  for i := 0 to InsCount - 1 do
  begin
    Start := P;
    if (Length(Data) - Start < 29) or (LE32(Data, Start) < 29) or
      (LE32(Data, Start) > Cardinal(Length(Data) - Start)) then
      raise EArgumentException.Create('XM: invalid instrument header');
    InstSize := Integer(LE32(Data, Start));
    InstEnd := Start + InstSize;
    FInstruments[i] := Default(TXMInstrument);
    FInstruments[i].Name := TextField(Data, Start + 4, 22);
    NS := IWS(Start + 27);
    if NS > 256 then
      raise EArgumentException.Create('XM: invalid instrument sample count');
    FInstruments[i].NumSamples := NS;
    FInstruments[i].FirstSampleIdx := Length(FSamples);
    for j := 0 to 95 do
      FInstruments[i].SampleOfNote[j] := -1;

    if NS = 0 then
    begin
      P := InstEnd;
      Continue;
    end;

    if InstSize < 241 then
      raise EArgumentException.Create('XM: truncated sampled instrument header');
    if (LE32(Data, Start + 29) < 40) or
      (LE32(Data, Start + 29) > Cardinal((Length(Data) - InstEnd) div NS)) then
      raise EArgumentException.Create('XM: invalid sample header size');
    SampleHeaderSize := Integer(LE32(Data, Start + 29));

    for j := 0 to 95 do
    begin
      B := IBS(Start + 33 + j);
      if B < NS then
        FInstruments[i].SampleOfNote[j] := Length(FSamples) + B;
    end;

    SetLength(VolPts, 12);
    SetLength(PanPts, 12);
    for j := 0 to 11 do
    begin
      VolPts[j].X := IWS(Start + 129 + j * 4);
      VolPts[j].Y := EnsureRange(IWS(Start + 131 + j * 4), 0, 64);
      PanPts[j].X := IWS(Start + 177 + j * 4);
      PanPts[j].Y := EnsureRange(IWS(Start + 179 + j * 4), 0, 64);
    end;

    NVol := Min(IBS(Start + 225), 12);
    NPan := Min(IBS(Start + 226), 12);
    Sus := IBS(Start + 227);
    LSp := IBS(Start + 228);
    LEp := IBS(Start + 229);
    PSus := IBS(Start + 230);
    PLSp := IBS(Start + 231);
    PLEp := IBS(Start + 232);
    VType := IBS(Start + 233);
    PType := IBS(Start + 234);
    FadeVal := IWS(Start + 239);

    with FInstruments[i] do
    begin
      VolEnv := Copy(VolPts, 0, NVol);
      PanEnv := Copy(PanPts, 0, NPan);
      VolEnvPoints := NVol;
      PanEnvPoints := NPan;
      VolEnvOn := ((VType and 1) <> 0) and (NVol > 0);
      VolSusOn := (VType and 2) <> 0;
      VolLoopOn := (VType and 4) <> 0;
      PanEnvOn := ((PType and 1) <> 0) and (NPan > 0);
      PanSusOn := (PType and 2) <> 0;
      PanLoopOn := (PType and 4) <> 0;
      VolSusPoint := EnsureRange(Sus, 0, Max(0, NVol - 1));
      VolLoopStart := EnsureRange(LSp, 0, Max(0, NVol - 1));
      VolLoopEnd := EnsureRange(LEp, 0, Max(0, NVol - 1));
      PanSusPoint := EnsureRange(PSus, 0, Max(0, NPan - 1));
      PanLoopStart := EnsureRange(PLSp, 0, Max(0, NPan - 1));
      PanLoopEnd := EnsureRange(PLEp, 0, Max(0, NPan - 1));
      if VolLoopEnd < VolLoopStart then
        VolLoopOn := False;
      if PanLoopEnd < PanLoopStart then
        PanLoopOn := False;
      VolumeFadeOut := FadeVal;
      VibratoType := IBS(Start + 235) and 3;
      VibratoSweep := IBS(Start + 236);
      VibratoDepth := IBS(Start + 237);
      VibratoRate := IBS(Start + 238);
    end;

    P := InstEnd;

    N := Length(FSamples);
    SetLength(FSamples, N + NS);

    for j := 0 to NS - 1 do
    begin
      RawLen := LE32(Data, P);
      RawLoopStart := LE32(Data, P + 4);
      RawLoopLen := LE32(Data, P + 8);
      FSamples[N + j] := Default(TXMSample);
      FSamples[N + j].Volume := EnsureRange(Data[P + 12], 0, 64);
      FSamples[N + j].Finetune := Wrap8(Data[P + 13]);
      B := Data[P + 14];
      if ((B and $20) <> 0) or (Data[P + 17] = $AD) then
        raise ENotSupportedException.Create('XM: stereo or ADPCM samples are unsupported');
      FSamples[N + j].Is16Bit := (B and $10) <> 0;
      FSamples[N + j].LoopType := B and 3;
      FSamples[N + j].Panning := Data[P + 15];
      FSamples[N + j].RelativeNote := Wrap8(Data[P + 16]);
      FSamples[N + j].Name := TextField(Data, P + 18, 22);

      if FSamples[N + j].Is16Bit then
      begin
        if Odd(RawLen) then
          raise EArgumentException.Create('XM: odd 16-bit sample byte length');
        RawLen := RawLen div 2;
        RawLoopStart := RawLoopStart div 2;
        RawLoopLen := RawLoopLen div 2;
      end;
      FSamples[N + j].Length := RawLen;
      if RawLoopStart > RawLen then
        RawLoopStart := RawLen;
      if RawLoopStart + RawLoopLen > RawLen then
        RawLoopLen := Max(0, RawLen - RawLoopStart);
      if (FSamples[N + j].LoopType = 0) or (RawLoopLen <= 0) then
      begin
        FSamples[N + j].LoopType := 0;
        RawLoopStart := 0;
        RawLoopLen := 0;
      end;
      FSamples[N + j].LoopStart := RawLoopStart;
      FSamples[N + j].LoopLength := RawLoopLen;
      Inc(P, SampleHeaderSize);
    end;

    for j := 0 to NS - 1 do
    begin
      Acc := 0;
      if FSamples[N + j].Is16Bit then
        BytesPerSample := 2
      else
        BytesPerSample := 1;
      if FSamples[N + j].Length > Cardinal((Length(Data) - P) div BytesPerSample) then
        raise EArgumentException.Create('XM: truncated sample data');
      SetLength(FSamples[N + j].Data, FSamples[N + j].Length);
      for k := 0 to High(FSamples[N + j].Data) do
      begin
        if FSamples[N + j].Is16Bit then
        begin
          SmpVal := Wrap16(Data[P] or (Data[P + 1] shl 8));
          Acc := Wrap16(Acc + SmpVal);
          FSamples[N + j].Data[k] := Acc;
        end
        else
        begin
          Acc := Wrap8(Acc + Wrap8(Data[P]));
          FSamples[N + j].Data[k] := Acc shl 8;
        end;
        Inc(P, BytesPerSample);
      end;
    end;
  end;
end;

function TXM.PatternRows(Pat: Integer): Integer;
begin
  if (Pat >= 0) and (Pat < Length(FPatterns)) and (FPatterns[Pat].Rows > 0) then
    Result := FPatterns[Pat].Rows
  else
    Result := 64;
end;

function TXM.CellAt(Pat, Row, Ch: Integer): TXMCell;
begin
  if (Pat >= 0) and (Pat < Length(FPatterns)) and
    (Row >= 0) and (Row < FPatterns[Pat].Rows) and
    (Ch >= 0) and (Ch < FChannels) then
    Result := FPatterns[Pat].Cells[Row * FChannels + Ch]
  else
    Result := Default(TXMCell);
end;

function TXM.NoteToPeriod(Note16: Double): Double;
begin
  if FLinearPeriods then
    Result := 7680.0 - 4.0 * Note16
  else
    Result := 32.0 * 856.0 * Power(2.0, -Note16 / (12.0 * 16.0));
end;

function TXM.PeriodToFreq(P: Double): Double;
begin
  if FLinearPeriods then
  begin
    if P < 1 then
      P := 1;
    Result := XM_REF_FREQ * Power(2.0, (4608.0 - P) / 768.0);
  end
  else
  begin
    if P < 1 then
      P := 1;
    Result := XM_REF_FREQ * 1712.0 / P;
  end;
  if Result > 1000000.0 then
    Result := 1000000.0;
end;

function TXM.VoiceFrequency(const V: TXMVoice): Double;
var
  P: Double;
begin
  P := V.Period;
  if V.PortamentoActive and (V.Glissando <> 0) then
    if FLinearPeriods then
      P := Round(P / 64.0) * 64.0
    else
      P := NoteToPeriod(16.0 * Round(12.0 * Log2((32.0 * 856.0) / Max(1.0, P))));
  P := P - V.VibratoOffset - V.AutoVibOffset;
  if V.ArpOffset <> 0 then
  begin
    if FLinearPeriods then
      P := P - V.ArpOffset * 64.0
    else
      P := P * Power(2.0, -V.ArpOffset / 12.0);
  end;
  Result := PeriodToFreq(P);
end;

function TXM.EnvInterp(const E: TArray<TEnvPoint>; Pos: Integer): Integer;
var
  k: Integer;
begin
  if Length(E) = 0 then
    Exit(64);
  if Pos <= E[0].X then
    Exit(E[0].Y);
  for k := 0 to High(E) - 1 do
    if Pos < E[k + 1].X then
    begin
      if E[k + 1].X = E[k].X then
        Exit(E[k + 1].Y);
      Exit(E[k].Y + (E[k + 1].Y - E[k].Y) * (Pos - E[k].X) div (E[k + 1].X - E[k].X));
    end;
  Result := E[High(E)].Y;
end;

procedure TXM.ResetEnvelopes(Ch: Integer);
var
  V: ^TXMVoice;
begin
  V := @FVoices[Ch];
  V^.VolEnvPos := 0;
  V^.PanEnvPos := 0;
  V^.VolEnvVal := 1.0;
  V^.PanEnvVal := 32;
  V^.FadeVol := 1.0;
  V^.Fading := False;
  V^.KeyOff := False;
  V^.AutoVibTicks := 0;
  V^.AutoVibOffset := 0;
end;

procedure TXM.ReleaseVoice(Ch: Integer);
var
  Instrument: Integer;
begin
  Instrument := FVoices[Ch].InstrumentIdx;
  FVoices[Ch].KeyOff := True;
  FVoices[Ch].Fading := True;
  if not InRange(Instrument, 0, High(FInstruments)) or
    not FInstruments[Instrument].VolEnvOn then
    FVoices[Ch].Volume := 0;
end;

procedure TXM.TriggerNote(Ch: Integer; const Cell: TXMCell);
var
  V: ^TXMVoice;
  II, SI, NN: Integer;
  KeepVolume, Porta: Boolean;
  S: ^TXMSample;
begin
  V := @FVoices[Ch];

  if Cell.Note = 255 then
  begin
    ReleaseVoice(Ch);
    Exit;
  end;

  II := V^.InstrumentIdx;
  if Cell.Instrument > 0 then
  begin
    if Cell.Instrument > Length(FInstruments) then
    begin
      V^.Active := False;
      Exit;
    end;
    II := Cell.Instrument - 1;
    V^.InstrumentIdx := II;
  end;

  if Cell.Note = 0 then
  begin
    if (Cell.Instrument > 0) and (II >= 0) and (II < Length(FInstruments)) and
      (FInstruments[II].NumSamples = 0) then
    begin
      V^.Active := False;
      Exit;
    end;
    if (Cell.Instrument > 0) and (II >= 0) and (II < Length(FInstruments)) and
      (FInstruments[II].NumSamples > 0) then
    begin
      SI := FInstruments[II].FirstSampleIdx;
      if (V^.Note >= 1) and (V^.Note <= 96) and
        (FInstruments[II].SampleOfNote[V^.Note - 1] >= 0) then
        SI := FInstruments[II].SampleOfNote[V^.Note - 1];
      V^.InstrumentIdx := II;
      if (SI >= 0) and (SI < Length(FSamples)) then
      begin
        V^.Volume := FSamples[SI].Volume;
        V^.Panning := FSamples[SI].Panning;
        V^.FadeDec := FInstruments[II].VolumeFadeOut;
      end;
      ResetEnvelopes(Ch);
    end;
    Exit;
  end;

  NN := Cell.Note;
  SI := -1;
  if (II >= 0) and (II < Length(FInstruments)) then
    SI := FInstruments[II].SampleOfNote[NN - 1];
  if SI < 0 then
  begin
    if FStrictSampleMap then
    begin
      V^.Active := False;

      Exit;
    end;
    if (II >= 0) and (II < Length(FInstruments)) and
      (FInstruments[II].NumSamples > 0) then
      SI := FInstruments[II].FirstSampleIdx;
  end;
  if (SI < 0) or (SI >= Length(FSamples)) or (FSamples[SI].Length = 0) then
  begin
    V^.Active := False;
    Exit;
  end;
  S := @FSamples[SI];

  Porta := (V^.SampleIdx >= 0) and
    ((Cell.Effect = FX_TONE_PORTA) or (Cell.Effect = FX_TONE_PORTA_VOLSLIDE) or
    ((Cell.Volume shr 4) = FV_TONEPORTA));
  if Porta then
  begin
    V^.TargetPeriod := NoteToPeriod(16.0 * (NN + S^.RelativeNote - 1) + V^.Finetune / 8.0);
    if Cell.Instrument > 0 then
    begin
      V^.InstrumentIdx := II;
      V^.Volume := S^.Volume;
      V^.FadeDec := FInstruments[II].VolumeFadeOut;
      ResetEnvelopes(Ch);
    end;
    Exit;
  end;

  KeepVolume := (Cell.Instrument = 0) and V^.Active and (V^.SampleIdx >= 0);

  V^.InstrumentIdx := II;
  V^.SampleIdx := SI;
  V^.Note := NN;
  V^.Finetune := S^.Finetune;
  V^.Period := NoteToPeriod(16.0 * (NN + S^.RelativeNote - 1) + S^.Finetune / 8.0);
  V^.TargetPeriod := V^.Period;
  V^.Position := 0;
  V^.CurAmp := 0;
  V^.PingPongDir := 1;
  V^.Active := True;
  if not KeepVolume then
    V^.Volume := S^.Volume;
  V^.Panning := S^.Panning;
  V^.TremoloOffset := 0;
  V^.VibratoOffset := 0;
  if (V^.VibratoWave and 4) = 0 then
    V^.VibratoPhase := 0;
  if (V^.TremoloWave and 4) = 0 then
    V^.TremoloPhase := 0;
  V^.ArpOffset := 0;
  V^.TremorPos := 0;
  if (II >= 0) and (II < Length(FInstruments)) then
    V^.FadeDec := FInstruments[II].VolumeFadeOut;
  ResetEnvelopes(Ch);
end;

procedure TXM.BeginRow;
var
  Key: string;
  Pat, C: Integer;
  Cell: TXMCell;
  V: ^TXMVoice;
  HasVib: Boolean;
begin
  if FOrder >= Length(FOrders) then
  begin
    FEnded := True;
    Exit;
  end;
  if FOrder < 0 then
    FOrder := 0;

  // Include each channel's finite E6x state so repeated rows inside a loop still play.
  SetLength(Key, FChannels + 2);
  Key[1] := Char(FOrder);
  Key[2] := Char(FRow);
  for C := 0 to FChannels - 1 do
    Key[C + 3] := Char((FVoices[C].LoopRow shl 4) or FVoices[C].LoopCount);
  if FVisited.ContainsKey(Key) then
  begin
    FEnded := True;
    Exit;
  end;
  FVisited.Add(Key, 0);

  Pat := FOrders[FOrder];

  FJumpPending := False;
  FBreakPending := False;
  FLoopJumpPending := False;

  for C := 0 to FChannels - 1 do
  begin
    Cell := CellAt(Pat, FRow, C);
    V := @FVoices[C];
    V^.ArpOffset := 0;
    V^.PortamentoActive := (Cell.Effect in [FX_TONE_PORTA, FX_TONE_PORTA_VOLSLIDE]) or
      ((Cell.Volume shr 4) = FV_TONEPORTA);

    if not (Cell.Effect in [FX_TREMOLO, FX_TREMOR]) then
      V^.TremoloOffset := 0;
    HasVib := (Cell.Effect = FX_VIBRATO) or (Cell.Effect = FX_VIBRATO_VOLSLIDE) or
      ((Cell.Volume shr 4) = FV_VIBRATO);
    if not HasVib then
      V^.VibratoOffset := 0;

    if (Cell.Effect = FX_EXTRA) and ((Cell.Param shr 4) = $D) and
      ((Cell.Param and 15) > 0) and (Cell.Note <> 0) then
    begin
      V^.DelayCell := Cell;
      V^.DelayTicks := Cell.Param and 15;
    end
    else
    begin
      V^.DelayTicks := 0;
      TriggerNote(C, Cell);
      ApplyVolumeColumn(C, Cell, 0);
    end;
    ApplyEffectRow(C, Cell);
  end;
end;

procedure TXM.ApplyVolumeColumn(Ch: Integer; const Cell: TXMCell; Tick: Integer);
var
  V: ^TXMVoice;
  VC, Hi, Lo: Integer;
begin
  V := @FVoices[Ch];
  VC := Cell.Volume;
  if VC = 0 then
    Exit;
  if (VC >= $10) and (VC <= $50) then
  begin
    if Tick = 0 then
    begin
      V^.Volume := VC - $10;
      V^.TremoloOffset := 0;
    end;
    Exit;
  end;
  Hi := VC shr 4;
  Lo := VC and 15;

  case Hi of
    FV_VOLDOWN:
      if Tick > 0 then
      begin
        V^.Volume := Max(0, V^.Volume - Lo);
        V^.TremoloOffset := 0;
      end;
    FV_VOLUP:
      if Tick > 0 then
      begin
        V^.Volume := Min(64, V^.Volume + Lo);
        V^.TremoloOffset := 0;
      end;
    FV_FINEDOWN:
      if Tick = 0 then
      begin
        V^.Volume := Max(0, V^.Volume - Lo);
        V^.TremoloOffset := 0;
      end;
    FV_FINEUP:
      if Tick = 0 then
      begin
        V^.Volume := Min(64, V^.Volume + Lo);
        V^.TremoloOffset := 0;
      end;
    FV_VIBSPEED:
      if (Tick = 0) and (Lo <> 0) then
        V^.VibratoSpeed := Lo;
    FV_VIBRATO:
      begin
        if (Tick = 0) and (Lo <> 0) then
          V^.VibratoDepth := Lo;
        if Tick > 0 then
        begin
          V^.VibratoOffset := -EffectWave(V^.VibratoPhase, V^.VibratoWave) * V^.VibratoDepth / 32.0;
          Inc(V^.VibratoPhase, V^.VibratoSpeed);
        end;
      end;
    FV_PAN:
      if Tick = 0 then
        V^.Panning := EnsureRange(Lo * 17, 0, 255);
    FV_PANLEFT:
      if Tick > 0 then
        V^.Panning := Max(0, V^.Panning - Lo);
    FV_PANRIGHT:
      if Tick > 0 then
        V^.Panning := Min(255, V^.Panning + Lo);
    FV_TONEPORTA:
      begin
        if (Tick = 0) and (Lo <> 0) then
          V^.TonePortaSpeed := Lo shl 4;
        if Tick > 0 then
        begin
          if V^.Period < V^.TargetPeriod then
            V^.Period := Min(V^.TargetPeriod, V^.Period + 4.0 * V^.TonePortaSpeed)
          else
            V^.Period := Max(V^.TargetPeriod, V^.Period - 4.0 * V^.TonePortaSpeed);
        end;
      end;
  end;
end;

procedure TXM.ApplyEffectRow(Ch: Integer; const Cell: TXMCell);
var
  V: ^TXMVoice;
  P, Hi, Lo, Sub: Integer;
  S: ^TXMSample;
begin
  V := @FVoices[Ch];
  P := Cell.Param;
  Hi := P shr 4;
  Lo := P and 15;

  if P <> 0 then
  begin
    case Cell.Effect of
      FX_PORTA_UP:
        V^.PortaUpSpeed := P;
      FX_PORTA_DOWN:
        V^.PortaDownSpeed := P;
      FX_TONE_PORTA:
        V^.TonePortaSpeed := P;
      FX_TONE_PORTA_VOLSLIDE, FX_VIBRATO_VOLSLIDE:
        V^.VolSlideMem := P;
      FX_VOLSLIDE:
        V^.VolSlideMem := P;
      FX_GLOBALVOLSLIDE:
        V^.GlobalVolSlideMem := P;
      FX_PANSLIDE:
        V^.PanSlideMem := P;
      FX_RETRIG:
        V^.RetrigCount := P;
      FX_TREMOR:
        V^.TremorMem := P;
      FX_OFFSET:
        V^.OffsetMem := P;
    end;
  end;

  case Cell.Effect of
    FX_PAN:
      V^.Panning := EnsureRange(P, 0, 255);
    FX_OFFSET:
      begin
        if Cell.Note <> 0 then
        begin
          V^.Position := V^.OffsetMem * 256.0;
          if (V^.SampleIdx >= 0) and (V^.SampleIdx < Length(FSamples)) then
          begin
            S := @FSamples[V^.SampleIdx];
            if V^.Position >= S^.Length then
              V^.Active := False;
          end;
        end;
      end;
    FX_SETVOL:
      begin
        V^.Volume := EnsureRange(P, 0, 64);
        V^.TremoloOffset := 0;
      end;
    FX_SPEED:
      begin
        if P = 0 then
          FEnded := True
        else if P < $20 then
          FSpeed := P
        else
          FTempo := P;
      end;
    FX_GLOBALVOL:
      FGlobalVolume := EnsureRange(P, 0, 64);
    FX_JUMP:
      begin
        FJumpPending := True;
        FLoopJumpPending := False;
        FJumpOrder := P;
        FJumpRow := 0;
      end;
    FX_BREAK:
      begin
        FBreakPending := True;
        FBreakRow := EnsureRange(Hi * 10 + Lo, 0, 255);
      end;
    FX_KEYOFF:
      if P = 0 then
        ReleaseVoice(Ch);
    FX_ENVPOS:
      begin
        V^.VolEnvPos := P;
        V^.PanEnvPos := P;
      end;
    FX_EXTRAFINE:
      begin
        if Hi = 1 then
          V^.Period := Max(1, V^.Period - Lo)
        else if Hi = 2 then
          V^.Period := V^.Period + Lo;
      end;
    FX_EXTRA:
      begin
        Sub := Hi;
        case Sub of
          1:
            V^.Period := Max(1, V^.Period - 4.0 * Lo);
          2:
            V^.Period := V^.Period + 4.0 * Lo;
          3:
            V^.Glissando := Lo;
          4:
            V^.VibratoWave := Lo and 7;
          5:
            begin
              if Lo >= 8 then
                V^.Finetune := (Lo - 16) * 16
              else
                V^.Finetune := Lo * 16;
              if (V^.SampleIdx >= 0) and (V^.SampleIdx < Length(FSamples)) then
                V^.Period := NoteToPeriod(16.0 * (V^.Note + FSamples[V^.SampleIdx].RelativeNote - 1)
                  + V^.Finetune / 8.0);
            end;
          6:
            begin
              if Lo = 0 then
                V^.LoopRow := FRow
              else
              begin
                if V^.LoopCount = 0 then
                  V^.LoopCount := Lo
                else
                  Dec(V^.LoopCount);
                if V^.LoopCount > 0 then
                begin
                  FJumpPending := True;
                  FJumpOrder := FOrder;
                  FJumpRow := V^.LoopRow;
                  FLoopJumpPending := True;
                end
                else if Lo > 0 then
                  V^.LoopCount := 0;
              end;
            end;
          7:
            V^.TremoloWave := Lo and 7;
          8:
            V^.Panning := EnsureRange(Lo * 17, 0, 255);
          $A:
            V^.Volume := Min(64, V^.Volume + Lo);
          $B:
            V^.Volume := Max(0, V^.Volume - Lo);
          $C:
            if Lo = 0 then
            begin
              V^.Volume := 0;
              V^.Active := False;
            end;
          $E:
            FPatternDelay := Lo;
        end;
      end;
  end;
end;

procedure TXM.ApplyTick(Ch, Tick: Integer; const Cell: TXMCell);
var
  V: ^TXMVoice;
  P, Hi, Lo, A, B, Interval: Integer;
  DoVib, DoTrem, DoPorta, DoSlide: Boolean;
  SlideParam: Integer;
begin
  V := @FVoices[Ch];
  P := Cell.Param;
  Hi := P shr 4;
  Lo := P and 15;

  if (V^.DelayTicks > 0) and (Tick = V^.DelayTicks) then
  begin
    TriggerNote(Ch, V^.DelayCell);
    ApplyVolumeColumn(Ch, V^.DelayCell, 0);
    V^.DelayTicks := 0;
  end;

  if Tick = 0 then
    Exit;

  ApplyVolumeColumn(Ch, Cell, Tick);

  DoVib := False;
  DoTrem := False;
  DoPorta := False;
  DoSlide := False;
  SlideParam := 0;

  case Cell.Effect of
    FX_ARPEGGIO:
      begin
        if P <> 0 then
        begin
          case Tick mod 3 of
            1:
              V^.ArpOffset := Hi;
            2:
              V^.ArpOffset := Lo;
          else
            V^.ArpOffset := 0;
          end;
        end
        else
          V^.ArpOffset := 0;
      end;
    FX_PORTA_UP:
      V^.Period := Max(1, V^.Period - 4.0 * V^.PortaUpSpeed);
    FX_PORTA_DOWN:
      V^.Period := V^.Period + 4.0 * V^.PortaDownSpeed;
    FX_TONE_PORTA:
      DoPorta := True;
    FX_VIBRATO:
      begin
        if Hi <> 0 then
          V^.VibratoSpeed := Hi;
        if Lo <> 0 then
          V^.VibratoDepth := Lo;
        DoVib := True;
      end;
    FX_TONE_PORTA_VOLSLIDE:
      begin
        DoPorta := True;
        DoSlide := True;
        SlideParam := V^.VolSlideMem;
      end;
    FX_VIBRATO_VOLSLIDE:
      begin
        DoVib := True;
        DoSlide := True;
        SlideParam := V^.VolSlideMem;
      end;
    FX_TREMOLO:
      begin
        if Hi <> 0 then
          V^.TremoloSpeed := Hi;
        if Lo <> 0 then
          V^.TremoloDepth := Lo;
        DoTrem := True;
      end;
    FX_VOLSLIDE:
      begin
        DoSlide := True;
        SlideParam := V^.VolSlideMem;
      end;
    FX_GLOBALVOLSLIDE:
      begin
        Hi := V^.GlobalVolSlideMem shr 4;
        Lo := V^.GlobalVolSlideMem and 15;
        if Hi > 0 then
          FGlobalVolume := Min(64, FGlobalVolume + Hi)
        else if Lo > 0 then
          FGlobalVolume := Max(0, FGlobalVolume - Lo);
      end;
    FX_PANSLIDE:
      begin
        Hi := V^.PanSlideMem shr 4;
        Lo := V^.PanSlideMem and 15;
        if Hi > 0 then
          V^.Panning := Min(255, V^.Panning + Hi)
        else if Lo > 0 then
          V^.Panning := Max(0, V^.Panning - Lo);
      end;
    FX_KEYOFF:
      if Tick = (P and 31) then
        ReleaseVoice(Ch);
    FX_RETRIG:
      begin
        Interval := V^.RetrigCount and 15;
        if (Interval > 0) and (Tick mod Interval = 0) then
        begin
          V^.Position := 0;
          V^.PingPongDir := 1;
          if V^.SampleIdx >= 0 then
            V^.Active := True;
          case V^.RetrigCount shr 4 of
            1:
              V^.Volume := Max(0, V^.Volume - 1);
            2:
              V^.Volume := Max(0, V^.Volume - 2);
            3:
              V^.Volume := Max(0, V^.Volume - 4);
            4:
              V^.Volume := Max(0, V^.Volume - 8);
            5:
              V^.Volume := Max(0, V^.Volume - 16);
            6:
              V^.Volume := (V^.Volume * 2) div 3;
            7:
              V^.Volume := V^.Volume div 2;
            9:
              V^.Volume := Min(64, V^.Volume + 1);
            10:
              V^.Volume := Min(64, V^.Volume + 2);
            11:
              V^.Volume := Min(64, V^.Volume + 4);
            12:
              V^.Volume := Min(64, V^.Volume + 8);
            13:
              V^.Volume := Min(64, V^.Volume + 16);
            14:
              V^.Volume := Min(64, (V^.Volume * 3) div 2);
            15:
              V^.Volume := Min(64, V^.Volume * 2);
          end;
        end;
      end;
    FX_TREMOR:
      begin
        A := (V^.TremorMem shr 4) + 1;
        B := (V^.TremorMem and 15) + 1;
        if V^.TremorPos < A then
          V^.TremoloOffset := 0
        else
          V^.TremoloOffset := -64;
        Inc(V^.TremorPos);
        if V^.TremorPos >= A + B then
          V^.TremorPos := 0;
      end;
    FX_EXTRA:
      begin
        case Hi of
          9:
            begin
              if (Lo > 0) and (Tick mod Lo = 0) then
              begin
                V^.Position := 0;
                V^.PingPongDir := 1;
                if V^.SampleIdx >= 0 then
                  V^.Active := True;
              end;
            end;
          $C:
            if Tick = Lo then
              V^.Volume := 0;
        end;
      end;
  end;

  if DoPorta then
  begin
    if V^.Period < V^.TargetPeriod then
      V^.Period := Min(V^.TargetPeriod, V^.Period + 4.0 * V^.TonePortaSpeed)
    else
      V^.Period := Max(V^.TargetPeriod, V^.Period - 4.0 * V^.TonePortaSpeed);
  end;

  if DoVib then
  begin
    V^.VibratoOffset := -EffectWave(V^.VibratoPhase, V^.VibratoWave) * V^.VibratoDepth / 32.0;
    Inc(V^.VibratoPhase, V^.VibratoSpeed);
  end;

  if DoTrem then
  begin
    V^.TremoloOffset := Round(EffectWave(V^.TremoloPhase, V^.TremoloWave) * V^.TremoloDepth / 64.0);
    Inc(V^.TremoloPhase, V^.TremoloSpeed);
  end;

  if DoSlide then
  begin
    A := SlideParam shr 4;
    B := SlideParam and 15;
    if A > 0 then
      V^.Volume := Min(64, V^.Volume + A)
    else if B > 0 then
      V^.Volume := Max(0, V^.Volume - B);
    V^.TremoloOffset := 0;
  end;
end;

procedure TXM.AdvanceEnvelopes(Ch: Integer);
var
  V: ^TXMVoice;
  Ins: ^TXMInstrument;
  D: Double;
  Phase: Integer;
begin
  V := @FVoices[Ch];
  if (V^.InstrumentIdx < 0) or (V^.InstrumentIdx >= Length(FInstruments)) then
  begin
    V^.VolEnvVal := 1.0;
    V^.PanEnvVal := 32;
    Exit;
  end;
  Ins := @FInstruments[V^.InstrumentIdx];

  if Ins^.VibratoDepth > 0 then
  begin
    Phase := (V^.AutoVibTicks * Ins^.VibratoRate) and 255;
    case Ins^.VibratoType of
      1:
        if Phase < 128 then
          D := -255
        else
          D := 255;
      2:
        D := 255 - 2 * Phase;
      3:
        D := 2 * Phase - 255;
    else
      D := -Sine[Phase shr 2];
    end;
    D := D * Ins^.VibratoDepth / 256.0;
    if (Ins^.VibratoSweep > 0) and (V^.AutoVibTicks < Ins^.VibratoSweep) then
      D := D * V^.AutoVibTicks / Ins^.VibratoSweep;
    V^.AutoVibOffset := D;
    Inc(V^.AutoVibTicks);
  end
  else
    V^.AutoVibOffset := 0;

  if Ins^.VolEnvOn and (Ins^.VolEnvPoints > 0) then
  begin
    V^.VolEnvVal := EnvInterp(Ins^.VolEnv, V^.VolEnvPos) / 64.0;
    if (not V^.KeyOff) and Ins^.VolSusOn and
      (V^.VolEnvPos = Ins^.VolEnv[Ins^.VolSusPoint].X) then
    begin
    end
    else
    begin
      Inc(V^.VolEnvPos);
      if Ins^.VolLoopOn and (V^.VolEnvPos > Ins^.VolEnv[Ins^.VolLoopEnd].X) then
        V^.VolEnvPos := Ins^.VolEnv[Ins^.VolLoopStart].X;
      if V^.VolEnvPos >= Ins^.VolEnv[Ins^.VolEnvPoints - 1].X then
      begin
        V^.VolEnvPos := Ins^.VolEnv[Ins^.VolEnvPoints - 1].X;
      end;
    end;
  end
  else
    V^.VolEnvVal := 1.0;

  if Ins^.PanEnvOn and (Ins^.PanEnvPoints > 0) then
  begin
    V^.PanEnvVal := EnvInterp(Ins^.PanEnv, V^.PanEnvPos);
    if (not V^.KeyOff) and Ins^.PanSusOn and
      (V^.PanEnvPos = Ins^.PanEnv[Ins^.PanSusPoint].X) then
    begin
    end
    else
    begin
      Inc(V^.PanEnvPos);
      if Ins^.PanLoopOn and (V^.PanEnvPos > Ins^.PanEnv[Ins^.PanLoopEnd].X) then
        V^.PanEnvPos := Ins^.PanEnv[Ins^.PanLoopStart].X;
      if V^.PanEnvPos >= Ins^.PanEnv[Ins^.PanEnvPoints - 1].X then
        V^.PanEnvPos := Ins^.PanEnv[Ins^.PanEnvPoints - 1].X;
    end;
  end
  else
    V^.PanEnvVal := 32;

  if V^.Fading then
  begin
    V^.FadeVol := V^.FadeVol - V^.FadeDec / 65536.0;
    if V^.FadeVol <= 0 then
    begin
      V^.FadeVol := 0;
      V^.Active := False;
    end;
  end;

  if V^.KeyOff and (V^.VolEnvVal * V^.FadeVol <= 0.0001) then
    V^.Active := False;
end;

procedure TXM.AdvanceRow;
var
  Pat, Rows, PreviousOrder, C: Integer;
begin
  if FPatternDelay > 0 then
  begin
    Dec(FPatternDelay);
    FInDelayRow := True;
    Exit;
  end;
  FInDelayRow := False;

  Pat := FOrders[FOrder];
  Rows := PatternRows(Pat);

  PreviousOrder := FOrder;
  if FJumpPending then
  begin
    FOrder := FJumpOrder;
    FRow := FJumpRow;
    if FBreakPending and not FLoopJumpPending then
      FRow := FBreakRow;
  end
  else if FBreakPending then
  begin
    Inc(FOrder);
    FRow := FBreakRow;
  end
  else
  begin
    Inc(FRow);
    if FRow >= Rows then
    begin
      FRow := 0;
      Inc(FOrder);
    end;
  end;

  FLoopJumpPending := False;
  if FOrder <> PreviousOrder then
    for C := 0 to High(FVoices) do
    begin
      FVoices[C].LoopRow := 0;
      FVoices[C].LoopCount := 0;
    end;

  if FOrder >= Length(FOrders) then
  begin
    FEnded := True;
    Exit;
  end;
  if FOrder < 0 then
    FOrder := 0;
  if FRow >= PatternRows(FOrders[FOrder]) then
    FRow := 0;
end;

function TXM.NextTick: Boolean;
var
  Pat, C: Integer;
  Cell: TXMCell;
begin
  Result := False;
  if FEnded then
    Exit;
  if (FTick = 0) and not FInDelayRow then
  begin
    BeginRow;
    if FEnded then
      Exit;
  end;

  Pat := FOrders[FOrder];
  for C := 0 to FChannels - 1 do
  begin
    Cell := CellAt(Pat, FRow, C);
    ApplyTick(C, FTick, Cell);
    if FVoices[C].Active then
    begin
      AdvanceEnvelopes(C);
      FVoices[C].SampleStep := VoiceFrequency(FVoices[C]) / FSampleRate;
    end;
  end;

  FTempoFraction := FTempoFraction + FSampleRate * 2.5 / FTempo;
  FSamplesLeft := Trunc(FTempoFraction);
  FTempoFraction := FTempoFraction - FSamplesLeft;
  Inc(FTick);

  if FTick >= FSpeed then
  begin
    FTick := 0;
    AdvanceRow;
  end;
  Result := True;
end;

procedure TXM.AdvanceVoice(var Voice: TXMVoice; const S: TXMSample);
var
  Position, LoopEnd, Span, Offset: Double;
begin
  Position := Voice.Position + Voice.SampleStep * Voice.PingPongDir;
  LoopEnd := Integer(S.LoopStart) + Integer(S.LoopLength);
  if S.LoopType = 0 then
  begin
    if Position >= S.Length then
    begin
      Voice.Active := False;
      Position := S.Length;
    end;
  end
  else if S.LoopType = 1 then
  begin
    if Position >= LoopEnd then
    begin
      Offset := Position - S.LoopStart;
      Position := S.LoopStart + Offset - Double(S.LoopLength) * Floor(Offset / S.LoopLength);
    end;
  end
  else if (Position >= LoopEnd - 1) or
    ((Voice.PingPongDir < 0) and (Position < S.LoopStart)) then
  begin
    Span := Integer(S.LoopLength) - 1;
    if Span = 0 then
      Position := S.LoopStart
    else
    begin
      Offset := Position - S.LoopStart;
      if Voice.PingPongDir < 0 then
        Offset := 2 * Span - Offset;
      Offset := Offset - (2 * Span) * Floor(Offset / (2 * Span));
      if Offset < Span then
      begin
        Position := S.LoopStart + Offset;
        Voice.PingPongDir := 1;
      end
      else
      begin
        Position := S.LoopStart + 2 * Span - Offset;
        Voice.PingPongDir := -1;
      end;
    end;
  end;
  Voice.Position := Position;
end;

function TXM.MixVoiceSample(const S: TXMSample; Pos: Double): Double;
var
  At, Nx, Len, LoopEnd: Integer;
  FracVal: Double;
begin
  Len := Integer(S.Length);
  if Len <= 0 then
    Exit(0);
  At := Trunc(Pos);
  if At < 0 then
    At := 0;
  if At >= Len then
    At := Len - 1;
  Nx := At + 1;
  if (S.LoopType <> 0) and (S.LoopLength > 0) then
  begin
    LoopEnd := Integer(S.LoopStart + S.LoopLength);
    if (At < LoopEnd) and (Nx >= LoopEnd) then
      if S.LoopType = 1 then
        Nx := Integer(S.LoopStart)
      else
        Nx := At;
  end;
  if Nx >= Len then
    Nx := Len - 1;
  if Nx < 0 then
    Nx := 0;
  FracVal := Pos - At;
  Result := (S.Data[At] + (S.Data[Nx] - S.Data[At]) * FracVal) / 32768.0;
end;

procedure TXM.MixFrame;
var
  C: Integer;
  V: ^TXMVoice;
  S: ^TXMSample;
  L, R, X, Amp: Double;
  Pan, Vol: Integer;
begin
  L := 0;
  R := 0;
  for C := 0 to FChannels - 1 do
  begin
    V := @FVoices[C];
    if (V^.SampleIdx < 0) or (V^.SampleIdx >= Length(FSamples)) then
    begin
      V^.CurAmp := 0;
      Continue;
    end;
    S := @FSamples[V^.SampleIdx];
    if S^.Length = 0 then
    begin
      V^.Active := False;
      V^.CurAmp := 0;
      Continue;
    end;

    if V^.Active then
    begin
      Vol := EnsureRange(V^.Volume + V^.TremoloOffset, 0, 64);
      Amp := (Vol / 64.0) * V^.VolEnvVal * V^.FadeVol * (FGlobalVolume / 64.0);
    end
    else
    begin
      Amp := 0;
      if V^.CurAmp <= 0.00001 then
      begin
        V^.CurAmp := 0;
        Continue;
      end;
    end;

    if V^.CurAmp < Amp then
      V^.CurAmp := Min(Amp, V^.CurAmp + FRampStep)
    else
      V^.CurAmp := Max(Amp, V^.CurAmp - FRampStep);

    Pan := EnsureRange(V^.Panning +
      ((V^.PanEnvVal - 32) * (128 - Abs(V^.Panning - 128))) div 32, 0, 255);

    X := MixVoiceSample(S^, V^.Position) * V^.CurAmp;
    L := L + X * (255 - Pan) / 255.0;
    R := R + X * Pan / 255.0;

    if V^.Active then
      AdvanceVoice(V^, S^);
  end;

  L := L * FMixGain * FMasterVolume;
  R := R * FMixGain * FMasterVolume;

  if FAmigaFilter then
  begin
    L := FFilter[0].Process(L);
    R := FFilter[1].Process(R);
  end;
  L := FDC[0].Process(L);
  R := FDC[1].Process(R);

  FLastL := EnsureRange(Round(L * 32767), -32768, 32767);
  FLastR := EnsureRange(Round(R * 32767), -32768, 32767);
end;

function TXM.Skip(Frames: Integer): Integer;
var
  Left, Right: SmallInt;
begin
  Result := 0;
  while (Result < Frames) and Sample(Left, Right) do
    Inc(Result);
end;

function TXM.Sample(out Left, Right: SmallInt): Boolean;
begin
  Left := 0;
  Right := 0;
  if (FSamplesLeft = 0) and not NextTick then
    Exit(False);
  MixFrame;
  Left := FLastL;
  Right := FLastR;
  Dec(FSamplesLeft);
  Result := True;
end;

function TXM.FrameCount: Int64;
begin
  Reset;
  try
    Result := 0;
    while NextTick do
      Inc(Result, FSamplesLeft);
  finally
    Reset;
  end;
end;

end.

