unit RetroTune.SoundFont;

interface

uses
  System.SysUtils, System.Generics.Collections;

type
  TSFZone = record
    Value: array[0..60] of Integer;
    Present: array[0..60] of Boolean;
  end;

  TSFRegion = record
    Bank, Preset, KeyLow, KeyHigh, VelLow, VelHigh: Integer;
    Start, Finish, LoopStart, LoopEnd, Rate, Root, Correction: Integer;
    Gen: TSFZone;
  end;

  ISoundFont = interface
    ['{58BA70D6-AFD3-49B0-A04E-5401C4B742D2}']
    function Regions: TArray<TSFRegion>;
    function Samples: TArray<SmallInt>;
    function Name: string;
  end;

  TSoundFont = class(TInterfacedObject, ISoundFont)
  private
    FRegions: TArray<TSFRegion>;
    FSamples: TArray<SmallInt>;
    FName: string;
  public
    constructor Create(const Data: TBytes);
    function Regions: TArray<TSFRegion>;
    function Samples: TArray<SmallInt>;
    function Name: string;
  end;

  TSFChannel = record
    Preset, BankMSB, BankLSB, Volume, Expression, Pan, Bend, Modulation: Integer;
    RPNMSB, RPNLSB, DataMSB, DataLSB: Integer;
    PitchRange, Tuning: Double;
    Sustain: Boolean;
  end;

  TSFVoice = record
    Active, Held, Sustained, Released: Boolean;
    Channel, Key, Velocity, Region, Stage, StageRemaining: Integer;
    Age: Int64;
    Position, Step, BaseStep, Gain, Left, Right, Envelope, EnvStep: Double;
    LFOPhase, VibPhase: Double;
    DelaySamples, AttackSamples, HoldSamples, DecaySamples, ReleaseSamples: Integer;
    SustainLevel: Double;
    ModStage, ModRemaining, ModDelay, ModAttack, ModHold, ModDecay, ModRelease: Integer;
    Clock: Int64;
    UpdateCounter, LFODelay, VibDelay: Integer;
    ModEnvelope, ModStep, ModSustain, LFOIncrement, VibIncrement: Double;
    PitchStep, ModGain, B0, B1, B2, A1, A2, Z1, Z2: Double;
  end;

  PSFVoice = ^TSFVoice;

  PSFRegion = ^TSFRegion;

  TSoundFontSynth = class
  private
    FBank: ISoundFont;
    FRegions: TArray<TSFRegion>;
    FSamples: TArray<SmallInt>;
    FVoices: array[0..255] of TSFVoice;
    FChannels: array[0..15] of TSFChannel;
    FAge: Int64;
    procedure StartStage(var V: TSFVoice; Stage: Integer);
    procedure StartModStage(var V: TSFVoice; Stage: Integer);
    procedure ReleaseVoice(var V: TSFVoice);
    procedure UpdateVoice(var V: TSFVoice);
    procedure UpdateChannel(Channel: Integer);
    procedure NoteOn(Channel, Key, Velocity: Integer);
    procedure NoteOff(Channel, Key: Integer);
    procedure Control(Channel, Number, Value: Integer);
  public
    constructor Create(const Bank: ISoundFont);
    procedure Reset;
    procedure Message(Status, A, B: Byte);
    procedure ReleaseAll;
    procedure Sample(out Left, Right: SmallInt);
  end;

implementation

uses
  System.Math, RetroTune.Binary;

function Signed16(V: Word): Integer;
begin
  Result := V;
  if Result >= 32768 then
    Dec(Result, 65536);
end;

function TimeSamples(TC: Integer): Integer;
begin
  if TC <= -32768 then
    Exit(0);
  Result := Round(44100 * Power(2, EnsureRange(TC, -12000, 8000) / 1200));
end;

constructor TSoundFont.Create(const Data: TBytes);
var
  Tables: TDictionary<string, TBytes>;
  List: TList<TSFRegion>;

  function Tag(P: Integer): string;
  begin
    RequireBytes(Data, P, 4);
    Result := TEncoding.ASCII.GetString(Data, P, 4);
  end;

  procedure Chunks(Start, Finish: Integer; const Parent: string; Depth: Integer);
  begin
    if Depth > 3 then
      raise EArgumentException.Create('Invalid SoundFont nesting');
    var P := Start;
    while P < Finish do
    begin
      RequireBytes(Data, P, 8);
      if Finish - P < 8 then
        raise EArgumentException.Create('Truncated SoundFont chunk');
      var ID := Tag(P);
      var N := LE32(Data, P + 4);
      Inc(P, 8);
      if N > Cardinal(Finish - P) then
        raise EArgumentException.Create('Truncated SoundFont chunk');
      if ID = 'LIST' then
      begin
        if N < 4 then
          raise EArgumentException.Create('Invalid SoundFont LIST');
        Chunks(P + 4, P + Integer(N), Tag(P), Depth + 1);
      end
      else if ((Parent = 'sdta') and (ID = 'smpl')) or
        ((Parent = 'pdta') and (ID <> 'pmod') and (ID <> 'imod')) then
      begin
        if Tables.ContainsKey(ID) then
          raise EArgumentException.Create('Duplicate SoundFont table');
        Tables.Add(ID, Copy(Data, P, Integer(N)));
      end
      else if (Parent = 'INFO') and (ID = 'INAM') then
        FName := TextField(Data, P, Integer(N));
      Inc(P, Integer(N));
      if N and 1 <> 0 then
        Inc(P);
      if P > Finish then
        raise EArgumentException.Create('Invalid SoundFont padding');
    end;
  end;

  function Table(const ID: string; Size: Integer): TBytes;
  begin
    if not Tables.TryGetValue(ID, Result) or (Length(Result) < Size) or
      (Length(Result) mod Size <> 0) then
      raise EArgumentException.Create('Invalid SoundFont ' + ID + ' table');
  end;

  function Zone(const Bags, Gens: TBytes; Index: Integer): TSFZone;
  begin
    Result := Default(TSFZone);
    var First := LE16(Bags, Index * 4);
    var Last := LE16(Bags, (Index + 1) * 4);
    if (First > Last) or (Last > Length(Gens) div 4) then
      raise EArgumentException.Create('Invalid SoundFont generator range');
    for var I := First to Last - 1 do
    begin
      var Op := LE16(Gens, I * 4);
      if Op > 60 then
        Continue;
      Result.Present[Op] := True;
      var V := LE16(Gens, I * 4 + 2);
      if Op in [41, 43, 44, 46, 47, 53, 54, 56, 57, 58] then
        Result.Value[Op] := V
      else
        Result.Value[Op] := Signed16(V);
    end;
  end;

  function Overlay(const Global, local: TSFZone): TSFZone;
  begin
    Result := Global;
    for var I := 0 to 60 do
      if local.Present[I] then
      begin
        Result.Value[I] := local.Value[I];
        Result.Present[I] := True;
      end;
  end;

  procedure AddRegion(const PZone, IZone: TSFZone; const Headers: TBytes; Bank, Preset: Integer);
  begin
    var G := IZone;
    // Instrument defaults; preset generators add to the instrument values.
    if not G.Present[8] then
      G.Value[8] := 13500;
    if not G.Present[56] then
      G.Value[56] := 100;
    for var Op := 21 to 40 do
      if (Op in [21, 23, 25, 26, 27, 28, 30, 33, 34, 35, 36, 38]) and not G.Present[Op] then
        G.Value[Op] := -12000;
    for var Op := 0 to 60 do
      if PZone.Present[Op] and not (Op in [41, 43, 44, 46, 47, 53, 54, 56, 57, 58]) then
        Inc(G.Value[Op], PZone.Value[Op]);
    if (Abs(G.Value[51]) > 120) or (Abs(G.Value[52]) > 1200) or
      (G.Value[56] < 0) or (G.Value[56] > 1200) then
      raise EArgumentException.Create('Invalid SoundFont tuning');
    var R := Default(TSFRegion);
    R.Bank := Bank;
    R.Preset := Preset;
    R.Gen := G;
    R.KeyLow := 0;
    R.KeyHigh := 127;
    R.VelLow := 0;
    R.VelHigh := 127;
    for var ZIndex := 0 to 1 do
    begin
      var Z := PZone;
      if ZIndex = 1 then
        Z := IZone;
      if Z.Present[43] then
      begin
        R.KeyLow := Max(R.KeyLow, Z.Value[43] and 255);
        R.KeyHigh := Min(R.KeyHigh, Z.Value[43] shr 8);
      end;
      if Z.Present[44] then
      begin
        R.VelLow := Max(R.VelLow, Z.Value[44] and 255);
        R.VelHigh := Min(R.VelHigh, Z.Value[44] shr 8);
      end;
    end;
    var S := IZone.Value[53] * 46;
    if (S < 0) or (S + 46 >= Length(Headers)) then
      raise EArgumentException.Create('Invalid SoundFont sample index');
    if not ((LE16(Headers, S + 44) and $7FFF) in [1, 2, 4, 8]) then
      raise EArgumentException.Create('Compressed or unknown SoundFont sample type');
    if LE16(Headers, S + 44) and $8000 <> 0 then
      raise EArgumentException.Create('ROM SoundFonts are unsupported');
    var A := Int64(LE32(Headers, S + 20)) + G.Value[0] + Int64(G.Value[4]) * 32768;
    var B := Int64(LE32(Headers, S + 24)) + G.Value[1] + Int64(G.Value[12]) * 32768;
    var LS := Int64(LE32(Headers, S + 28)) + G.Value[2] + Int64(G.Value[45]) * 32768;
    var LE := Int64(LE32(Headers, S + 32)) + G.Value[3] + Int64(G.Value[50]) * 32768;
    if (A < 0) or (B <= A) or (B > Length(FSamples)) then
      raise EArgumentException.Create('Invalid SoundFont sample bounds');
    R.Start := A;
    R.Finish := B;
    if G.Value[54] and 1 <> 0 then
    begin
      if (LS < 0) or (LE > B) or (LE - LS < 2) then
        raise EArgumentException.CreateFmt('Invalid SoundFont sample loop %s: %d..%d, sample %d..%d', [TextField(Headers, S, 20), LS, LE, A, B]);
      R.LoopStart := LS;
      R.LoopEnd := LE;
    end;
    var Rate := LE32(Headers, S + 36);
    if (Rate < 400) or (Rate > 384000) then
      raise EArgumentException.Create('Invalid SoundFont sample rate');
    R.Rate := Rate;
    R.Root := Headers[S + 40];
    if R.Root > 127 then
      R.Root := 60;
    if G.Present[58] and (G.Value[58] <= 127) then
      R.Root := G.Value[58];
    R.Correction := Headers[S + 41];
    if R.Correction > 127 then
      Dec(R.Correction, 256);
    if (R.KeyLow <= R.KeyHigh) and (R.VelLow <= R.VelHigh) then
      List.Add(R);
    if List.Count > 100000 then
      raise EArgumentException.Create('SoundFont has too many regions');
  end;

begin
  inherited Create;
  RequireBytes(Data, 0, 12);
  if (Tag(0) <> 'RIFF') or (Tag(8) <> 'sfbk') or
    (Int64(LE32(Data, 4)) + 8 <> Length(Data)) then
    raise EArgumentException.Create('Expected a RIFF SoundFont2 file');
  Tables := TDictionary<string, TBytes>.Create;
  List := TList<TSFRegion>.Create;
  try
    Chunks(12, Length(Data), '', 0);
    var SampleData := Table('smpl', 2);
    SetLength(FSamples, Length(SampleData) div 2);
    for var I := 0 to High(FSamples) do
      FSamples[I] := Signed16(LE16(SampleData, I * 2));
    Tables.Remove('smpl');
    var PH := Table('phdr', 38);
    var PB := Table('pbag', 4);
    var PG := Table('pgen', 4);
    var IH := Table('inst', 22);
    var IB := Table('ibag', 4);
    var IG := Table('igen', 4);
    var SH := Table('shdr', 46);
    for var P := 0 to Length(PH) div 38 - 2 do
    begin
      var First := LE16(PH, P * 38 + 24);
      var Last := LE16(PH, (P + 1) * 38 + 24);
      if (First > Last) or (Last >= Length(PB) div 4) then
        raise EArgumentException.Create('Invalid SoundFont preset bags');
      var GlobalP := Default(TSFZone);
      for var B := First to Last - 1 do
      begin
        var LocalP := Zone(PB, PG, B);
        if not LocalP.Present[41] then
        begin
          if B <> First then
            raise EArgumentException.Create('Misplaced SoundFont global preset');
          GlobalP := LocalP;
          Continue;
        end;
        var PZ := Overlay(GlobalP, LocalP);
        var Inst := PZ.Value[41];
        if Inst + 1 >= Length(IH) div 22 then
          raise EArgumentException.Create('Invalid SoundFont instrument');
        var IFirst := LE16(IH, Inst * 22 + 20);
        var ILast := LE16(IH, (Inst + 1) * 22 + 20);
        if (IFirst > ILast) or (ILast >= Length(IB) div 4) then
          raise EArgumentException.Create('Invalid SoundFont instrument bags');
        var GlobalI := Default(TSFZone);
        for var J := IFirst to ILast - 1 do
        begin
          var LocalI := Zone(IB, IG, J);
          if not LocalI.Present[53] then
          begin
            if J <> IFirst then
              raise EArgumentException.Create('Misplaced SoundFont global instrument');
            GlobalI := LocalI;
            Continue;
          end;
          AddRegion(PZ, Overlay(GlobalI, LocalI), SH, LE16(PH, P * 38 + 22), LE16(PH, P * 38 + 20));
        end;
      end;
    end;
    if List.Count = 0 then
      raise EArgumentException.Create('SoundFont contains no playable presets');
    FRegions := List.ToArray;
    if FName = '' then
      FName := 'SoundFont2';
  finally
    List.Free;
    Tables.Free;
  end;
end;

function TSoundFont.Regions: TArray<TSFRegion>;
begin
  Result := FRegions;
end;

function TSoundFont.Samples: TArray<SmallInt>;
begin
  Result := FSamples;
end;

function TSoundFont.Name: string;
begin
  Result := FName;
end;

constructor TSoundFontSynth.Create(const Bank: ISoundFont);
begin
  inherited Create;
  FBank := Bank;
  FRegions := Bank.Regions;
  FSamples := Bank.Samples;
  Reset;
end;

procedure TSoundFontSynth.Reset;
begin
  for var I := 0 to High(FVoices) do
    FVoices[I] := Default(TSFVoice);
  FAge := 0;
  for var I := 0 to 15 do
  begin
    FChannels[I] := Default(TSFChannel);
    FChannels[I].Volume := 100;
    FChannels[I].Expression := 127;
    FChannels[I].Pan := 64;
    FChannels[I].Bend := 8192;
    FChannels[I].PitchRange := 2;
    FChannels[I].RPNMSB := 127;
    FChannels[I].RPNLSB := 127;
  end;
end;

procedure TSoundFontSynth.StartStage(var V: TSFVoice; Stage: Integer);
begin
  V.Stage := Stage;
  case Stage of
    0:
      begin
        V.StageRemaining := V.DelaySamples;
        V.Envelope := 0;
        V.EnvStep := 0;
      end;
    1:
      begin
        V.StageRemaining := V.AttackSamples;
        V.Envelope := 0;
        V.EnvStep := 1 / Max(1, V.AttackSamples);
      end;
    2:
      begin
        V.StageRemaining := V.HoldSamples;
        V.Envelope := 1;
        V.EnvStep := 0;
      end;
    3:
      begin
        V.StageRemaining := V.DecaySamples;
        V.Envelope := 1;
        V.EnvStep := Power(Max(0.00001, V.SustainLevel), 1 / Max(1, V.DecaySamples));
      end;
    4:
      begin
        V.StageRemaining := MaxInt;
        V.Envelope := V.SustainLevel;
        V.EnvStep := 0;
      end;
    5:
      begin
        V.StageRemaining := V.ReleaseSamples;
        V.EnvStep := -V.Envelope / Max(1, V.ReleaseSamples);
      end;
  else
    V.Active := False;
  end;
  if (Stage < 4) and (V.StageRemaining = 0) then
    StartStage(V, Stage + 1);
end;

procedure TSoundFontSynth.StartModStage(var V: TSFVoice; Stage: Integer);
begin
  V.ModStage := Stage;
  case Stage of
    0:
      begin
        V.ModRemaining := V.ModDelay;
        V.ModEnvelope := 0;
        V.ModStep := 0;
      end;
    1:
      begin
        V.ModRemaining := V.ModAttack;
        V.ModEnvelope := 0;
        V.ModStep := 1 / Max(1, V.ModAttack);
      end;
    2:
      begin
        V.ModRemaining := V.ModHold;
        V.ModEnvelope := 1;
        V.ModStep := 0;
      end;
    3:
      begin
        V.ModRemaining := V.ModDecay;
        V.ModEnvelope := 1;
        V.ModStep := (V.ModSustain - 1) / Max(1, V.ModDecay);
      end;
    4:
      begin
        V.ModRemaining := MaxInt;
        V.ModEnvelope := V.ModSustain;
        V.ModStep := 0;
      end;
    5:
      begin
        V.ModRemaining := V.ModRelease;
        V.ModStep := -V.ModEnvelope / Max(1, V.ModRelease);
      end;
  else
    V.ModRemaining := MaxInt;
    V.ModEnvelope := 0;
    V.ModStep := 0;
  end;
  if (Stage < 4) and (V.ModRemaining = 0) then
    StartModStage(V, Stage + 1);
end;

procedure TSoundFontSynth.ReleaseVoice(var V: TSFVoice);
begin
  if not V.Active or V.Released then
    Exit;
  V.Released := True;
  V.Sustained := False;
  StartStage(V, 5);
  StartModStage(V, 5);
end;

procedure TSoundFontSynth.UpdateVoice(var V: TSFVoice);
begin
  var C := FChannels[V.Channel];
  var R := FRegions[V.Region];
  V.UpdateCounter := 0;
  V.Step := V.BaseStep * Power(2, (C.Tuning + (C.Bend - 8192) / 8192 * C.PitchRange) / 12);
  var Pan := EnsureRange((C.Pan - 64) / 63 + R.Gen.Value[17] / 500, -1.0, 1.0);
  V.Left := Sqrt((1 - Pan) * 0.5);
  V.Right := Sqrt((1 + Pan) * 0.5);
  V.Gain := Power(C.Volume / 127 * C.Expression / 127, 2) *
    Power(V.Velocity / 127, 2) * Power(10, -EnsureRange(R.Gen.Value[48], 0, 1440) / 200) * 0.5;
end;

procedure TSoundFontSynth.UpdateChannel(Channel: Integer);
begin
  for var I := 0 to High(FVoices) do
    if FVoices[I].Active and (FVoices[I].Channel = Channel) then
      UpdateVoice(FVoices[I]);
end;

procedure TSoundFontSynth.NoteOn(Channel, Key, Velocity: Integer);
begin
  if Velocity = 0 then
  begin
    NoteOff(Channel, Key);
    Exit;
  end;
  var C := FChannels[Channel];
  var Bank := C.BankMSB * 128 + C.BankLSB;
  if Channel = 9 then
    Bank := 128;
  var Found := False;
  for var R in FRegions do
    if (R.Bank = Bank) and (R.Preset = C.Preset) then
    begin
      Found := True;
      Break;
    end;
  // GS banks commonly use CC0 alone; GM2 variations use CC32.
  if not Found and (Channel <> 9) then
    for var CandidateIndex := 0 to 1 do
    begin
      var Candidate := C.BankMSB;
      if CandidateIndex = 1 then
        Candidate := C.BankLSB;
      for var R in FRegions do
        if (R.Bank = Candidate) and (R.Preset = C.Preset) then
        begin
          Bank := Candidate;
          Found := True;
          Break;
        end;
      if Found then
        Break;
    end;
  var ProgramNumber := C.Preset;
  if not Found then
  begin
    if Channel = 9 then
      ProgramNumber := 0
    else
      Bank := 0;
  end;
  Inc(FAge);
  for var RI := 0 to High(FRegions) do
  begin
    var R := FRegions[RI];
    if (R.Bank <> Bank) or (R.Preset <> ProgramNumber) or
      (Key < R.KeyLow) or (Key > R.KeyHigh) or (Velocity < R.VelLow) or (Velocity > R.VelHigh) then
      Continue;
    var Slot := -1;
    for var I := 0 to High(FVoices) do
    begin
      if FVoices[I].Active and (FVoices[I].Channel = Channel) and
        (R.Gen.Value[57] <> 0) and (FRegions[FVoices[I].Region].Gen.Value[57] = R.Gen.Value[57]) and
        (FVoices[I].Age <> FAge) then
        FVoices[I].Active := False;
      if not FVoices[I].Active then
        Slot := I;
    end;
    if Slot < 0 then
    begin
      Slot := 0;
      for var I := 1 to High(FVoices) do
        if FVoices[I].Age < FVoices[Slot].Age then
          Slot := I;
    end;
    var V := Default(TSFVoice);
    V.Active := True;
    V.Held := True;
    V.Channel := Channel;
    V.Key := Key;
    V.Velocity := Velocity;
    V.Region := RI;
    V.Age := FAge;
    V.Position := R.Start;
    var PitchKey := Key;
    if R.Gen.Present[46] and (R.Gen.Value[46] <= 127) then
      PitchKey := R.Gen.Value[46];
    if R.Gen.Present[47] and (R.Gen.Value[47] <= 127) then
      V.Velocity := R.Gen.Value[47];
    V.BaseStep := R.Rate / 44100 * Power(2, ((PitchKey - R.Root) * R.Gen.Value[56] +
      R.Gen.Value[51] * 100 + R.Gen.Value[52] + R.Correction) / 1200);
    V.DelaySamples := TimeSamples(R.Gen.Value[33]);
    V.AttackSamples := TimeSamples(R.Gen.Value[34]);
    V.HoldSamples := TimeSamples(R.Gen.Value[35] + (60 - PitchKey) * R.Gen.Value[39]);
    V.DecaySamples := TimeSamples(R.Gen.Value[36] + (60 - PitchKey) * R.Gen.Value[40]);
    V.ReleaseSamples := TimeSamples(R.Gen.Value[38]);
    V.SustainLevel := Power(10, -EnsureRange(R.Gen.Value[37], 0, 1440) / 200);
    V.LFODelay := TimeSamples(R.Gen.Value[21]);
    V.VibDelay := TimeSamples(R.Gen.Value[23]);
    V.ModDelay := TimeSamples(R.Gen.Value[25]);
    V.ModAttack := TimeSamples(R.Gen.Value[26]);
    V.ModHold := TimeSamples(R.Gen.Value[27] + (60 - PitchKey) * R.Gen.Value[31]);
    V.ModDecay := TimeSamples(R.Gen.Value[28] + (60 - PitchKey) * R.Gen.Value[32]);
    V.ModRelease := TimeSamples(R.Gen.Value[30]);
    V.ModSustain := 1 - EnsureRange(R.Gen.Value[29], 0, 1000) / 1000;
    V.LFOIncrement := 2 * Pi * 8.176 * Power(2, EnsureRange(R.Gen.Value[22], -16000, 4500) / 1200) / 44100;
    V.VibIncrement := 2 * Pi * 8.176 * Power(2, EnsureRange(R.Gen.Value[24], -16000, 4500) / 1200) / 44100;
    UpdateVoice(V);
    StartStage(V, 0);
    StartModStage(V, 0);
    FVoices[Slot] := V;
  end;
end;

procedure TSoundFontSynth.NoteOff(Channel, Key: Integer);
begin
  // Release the oldest still-held note group, preserving repeated notes.
  var Age := High(Int64);
  for var V in FVoices do
    if V.Active and V.Held and (V.Channel = Channel) and (V.Key = Key) then
      Age := Min(Age, V.Age);
  for var I := 0 to High(FVoices) do
    if FVoices[I].Active and FVoices[I].Held and (FVoices[I].Channel = Channel) and
      (FVoices[I].Key = Key) and (FVoices[I].Age = Age) then
    begin
      FVoices[I].Held := False;
      if FChannels[Channel].Sustain then
        FVoices[I].Sustained := True
      else
        ReleaseVoice(FVoices[I]);
    end;
end;

procedure TSoundFontSynth.Control(Channel, Number, Value: Integer);
begin
  case Number of
    0:
      FChannels[Channel].BankMSB := Value;
    32:
      FChannels[Channel].BankLSB := Value;
    1:
      FChannels[Channel].Modulation := Value;
    7:
      FChannels[Channel].Volume := Value;
    10:
      FChannels[Channel].Pan := Value;
    11:
      FChannels[Channel].Expression := Value;
    64:
      begin
        FChannels[Channel].Sustain := Value >= 64;
        if Value < 64 then
          for var I := 0 to High(FVoices) do
            if FVoices[I].Active and (FVoices[I].Channel = Channel) and FVoices[I].Sustained then
              ReleaseVoice(FVoices[I]);
      end;
    100:
      FChannels[Channel].RPNLSB := Value;
    101:
      FChannels[Channel].RPNMSB := Value;
    98, 99:
      begin
        FChannels[Channel].RPNMSB := 127;
        FChannels[Channel].RPNLSB := 127;
      end;
    6, 38:
      begin
        if Number = 6 then
          FChannels[Channel].DataMSB := Value
        else
          FChannels[Channel].DataLSB := Value;
        if FChannels[Channel].RPNMSB = 0 then
          case FChannels[Channel].RPNLSB of
            0:
              FChannels[Channel].PitchRange := Min(24.0, FChannels[Channel].DataMSB + FChannels[Channel].DataLSB / 100);
            1:
              FChannels[Channel].Tuning := (FChannels[Channel].DataMSB * 128 + FChannels[Channel].DataLSB - 8192) / 8192;
            2:
              FChannels[Channel].Tuning := FChannels[Channel].DataMSB - 64;
          end;
      end;
    120:
      for var I := 0 to High(FVoices) do
        if FVoices[I].Channel = Channel then
          FVoices[I].Active := False;
    123, 124, 125, 126, 127:
      for var I := 0 to High(FVoices) do
        if FVoices[I].Active and (FVoices[I].Channel = Channel) then
        begin
          FVoices[I].Held := False;
          if FChannels[Channel].Sustain then
            FVoices[I].Sustained := True
          else
            ReleaseVoice(FVoices[I]);
        end;
    121:
      begin
        FChannels[Channel].Expression := 127;
        FChannels[Channel].Bend := 8192;
        FChannels[Channel].Modulation := 0;
        FChannels[Channel].Sustain := False;
        FChannels[Channel].RPNMSB := 127;
        FChannels[Channel].RPNLSB := 127;
        for var I := 0 to High(FVoices) do
          if FVoices[I].Active and (FVoices[I].Channel = Channel) and FVoices[I].Sustained then
            ReleaseVoice(FVoices[I]);
      end;
  end;
  UpdateChannel(Channel);
end;

procedure TSoundFontSynth.Message(Status, A, B: Byte);
begin
  var C := Status and 15;
  case Status and $F0 of
    $80:
      NoteOff(C, A);
    $90:
      NoteOn(C, A, B);
    $B0:
      Control(C, A, B);
    $C0:
      FChannels[C].Preset := A;
    $E0:
      begin
        FChannels[C].Bend := Integer(A) + Integer(B) * 128;
        UpdateChannel(C);
      end;
  end;
end;

procedure TSoundFontSynth.ReleaseAll;
begin
  for var I := 0 to High(FVoices) do
    ReleaseVoice(FVoices[I]);
end;

procedure TSoundFontSynth.Sample(out Left, Right: SmallInt);
begin
  var L := 0.0;
  var ROut := 0.0;
  for var I := 0 to High(FVoices) do
  begin
    if not FVoices[I].Active then
      Continue;
    var V: PSFVoice := @FVoices[I];
    var R: PSFRegion := @FRegions[V.Region];
    var Looping := (R.Gen.Value[54] and 1 <> 0) and
      ((R.Gen.Value[54] and 3 <> 3) or not V.Released);
    if Looping and (V.Position >= R.LoopEnd) then
      V.Position := R.LoopStart + Frac((V.Position - R.LoopStart) / (R.LoopEnd - R.LoopStart)) * (R.LoopEnd - R.LoopStart);
    if V.Position >= R.Finish then
    begin
      V.Active := False;
      Continue;
    end;
    var At := Floor(V.Position);
    var Next := Min(At + 1, R.Finish - 1);
    if Looping and (Next >= R.LoopEnd) then
      Next := R.LoopStart;
    var S := FSamples[At] + (FSamples[Next] - FSamples[At]) * Frac(V.Position);
    var C := FChannels[V.Channel];
    if V.Clock >= V.LFODelay then
    begin
      V.LFOPhase := V.LFOPhase + V.LFOIncrement;
      if V.LFOPhase >= 2 * Pi then
        V.LFOPhase := V.LFOPhase - 2 * Pi;
    end;
    if V.Clock >= V.VibDelay then
    begin
      V.VibPhase := V.VibPhase + V.VibIncrement;
      if V.VibPhase >= 2 * Pi then
        V.VibPhase := V.VibPhase - 2 * Pi;
    end;
    if V.UpdateCounter = 0 then
    begin
      var ModLFO := Sin(V.LFOPhase);
      var Cents := ModLFO * R.Gen.Value[5] + V.ModEnvelope * R.Gen.Value[7] +
        Sin(V.VibPhase) * (R.Gen.Value[6] + C.Modulation / 127 * 50);
      V.PitchStep := V.Step * Power(2, EnsureRange(Cents, -24000.0, 24000.0) / 1200);
      V.ModGain := Power(10, EnsureRange(ModLFO * R.Gen.Value[13], -960.0, 960.0) / 200);
      var CutoffCents := EnsureRange(R.Gen.Value[8] + ModLFO * R.Gen.Value[10] + V.ModEnvelope * R.Gen.Value[11], 1500.0, 13500.0);
      var Cutoff := Min(20000.0, 8.176 * Power(2, CutoffCents / 1200));
      var Omega := 2 * Pi * Cutoff / 44100;
      var Q := Sqrt(0.5) * Power(10, EnsureRange(R.Gen.Value[9], 0, 960) / 200);
      var Alpha := Sin(Omega) / (2 * Q);
      var A0 := 1 + Alpha;
      V.B0 := (1 - Cos(Omega)) / (2 * A0);
      V.B1 := 2 * V.B0;
      V.B2 := V.B0;
      V.A1 := -2 * Cos(Omega) / A0;
      V.A2 := (1 - Alpha) / A0;
      V.UpdateCounter := 64;
    end;
    Dec(V.UpdateCounter);
    var Filtered := EnsureRange(V.B0 * S + V.Z1, -1.0E9, 1.0E9);
    V.Z1 := EnsureRange(V.B1 * S - V.A1 * Filtered + V.Z2, -1.0E9, 1.0E9);
    V.Z2 := EnsureRange(V.B2 * S - V.A2 * Filtered, -1.0E9, 1.0E9);
    var G := V.Gain * V.Envelope * V.ModGain;
    L := L + Filtered * G * V.Left;
    ROut := ROut + Filtered * G * V.Right;
    V.Position := V.Position + V.PitchStep;
    Inc(V.Clock);
    V.ModEnvelope := EnsureRange(V.ModEnvelope + V.ModStep, 0.0, 1.0);
    if V.ModStage <> 4 then
    begin
      Dec(V.ModRemaining);
      if V.ModRemaining <= 0 then
        StartModStage(V^, V.ModStage + 1);
    end;
    if V.Stage = 3 then
      V.Envelope := V.Envelope * V.EnvStep
    else
      V.Envelope := Max(0.0, V.Envelope + V.EnvStep);
    if V.Stage <> 4 then
    begin
      Dec(V.StageRemaining);
      if V.StageRemaining <= 0 then
        StartStage(V^, V.Stage + 1);
    end;
  end;
  Left := Round(EnsureRange(L, -32768.0, 32767.0));
  Right := Round(EnsureRange(ROut, -32768.0, 32767.0));
end;

end.

