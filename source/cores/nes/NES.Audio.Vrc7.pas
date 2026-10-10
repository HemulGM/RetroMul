unit NES.Audio.Vrc7;

interface

uses
  NES.State;

type
  TVrc7Patch = record
    TL, FB, EG, ML, AR, DR, SL, RR, KR, KL, AM, PM, WS: Byte;
  end;

  TVrc7Slot = record
    PatchIndex, Output, PreviousOutput: Integer;
    Phase, PhaseOutput: Cardinal;
    Fnum, BlockFnum, Block, Volume, Envelope, Stage: Integer;
    KeyOn, Sustain: Boolean;
    TotalLevel, RateScale, RateHigh, RateLow, Shift, Updates: Integer;
    Waveform: Integer;
  end;

  PVrc7Patch = ^TVrc7Patch;

  PVrc7Slot = ^TVrc7Slot;

  // VRC7 subset of emu2413: six melodic channels, no YM2413 rhythm mode.
  // No pointers in the state: patches and waveforms are addressed by index.
  TVrc7Fm = record
  private
    FRegisters: array[0..$3F] of Byte;
    FPatches: array[0..31] of TVrc7Patch;
    FSlots: array[0..11] of TVrc7Slot;
    FEnvelopeCounter: Word;
    FVibratoPhase, FTremoloPhase: Cardinal;
    FTremolo, FTest: Byte;
    procedure DecodePatch(Index: Integer; const Data: array of Byte);
    procedure CommitSlot(Index: Integer);
    procedure ClockEnvelope(Index: Integer);
    function LinearOutput(Index, Phase: Integer): Integer;
  public
    procedure Reset(PreserveVibrato: Boolean = False);
    procedure ClockReset;
    procedure WriteRegister(Address, Value: Byte);
    function Sample: SmallInt;
    procedure SerializeState(State: TNesStateArchive);
  end;

implementation

uses
  System.Math;

{ Derived from emu2413 v1.5.9, https://github.com/digital-sound-antiques/emu2413
  Copyright (c) 2001-2020 Mitsutaka Okazaki }

const
  EG_ATTACK = 0;
  EG_DECAY = 1;
  EG_SUSTAIN = 2;
  EG_RELEASE = 3;
  EG_DAMP = 4;
  EG_MUTE = 127;
  EG_MAX = 123;
  UPDATE_WS = 1;
  UPDATE_TLL = 2;
  UPDATE_RKS = 4;
  UPDATE_EG = 8;
  UPDATE_ALL = 15;
  Instruments: array[0..15, 0..7] of Byte = (
    ($00, $00, $00, $00, $00, $00, $00, $00),
    ($03, $21, $05, $06, $E8, $81, $42, $27),
    ($13, $41, $14, $0D, $D8, $F6, $23, $12),
    ($11, $11, $08, $08, $FA, $B2, $20, $12),
    ($31, $61, $0C, $07, $A8, $64, $61, $27),
    ($32, $21, $1E, $06, $E1, $76, $01, $28),
    ($02, $01, $06, $00, $A3, $E2, $F4, $F4),
    ($21, $61, $1D, $07, $82, $81, $11, $07),
    ($23, $21, $22, $17, $A2, $72, $01, $17),
    ($35, $11, $25, $00, $40, $73, $72, $01),
    ($B5, $01, $0F, $0F, $A8, $A5, $51, $02),
    ($17, $C1, $24, $07, $F8, $F8, $22, $12),
    ($71, $23, $11, $06, $65, $74, $18, $16),
    ($01, $02, $D3, $05, $C9, $95, $03, $02),
    ($61, $63, $0C, $00, $94, $C0, $33, $F6),
    ($21, $72, $0D, $00, $C1, $D5, $56, $06));
  Multipliers: array[0..15] of Integer = (1, 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 20, 24, 24, 30, 30);
  PitchLfo: array[0..7, 0..7] of ShortInt = (
    (0, 0, 0, 0, 0, 0, 0, 0), (0, 0, 1, 0, 0, 0, -1, 0),
    (0, 1, 2, 1, 0, -1, -2, -1), (0, 1, 3, 1, 0, -1, -3, -1),
    (0, 2, 4, 2, 0, -2, -4, -2), (0, 2, 5, 2, 0, -2, -5, -2),
    (0, 3, 6, 3, 0, -3, -6, -3), (0, 3, 7, 3, 0, -3, -7, -3));
  EnvelopeSteps: array[0..3, 0..7] of Byte = (
    (0, 1, 0, 1, 0, 1, 0, 1), (0, 1, 0, 1, 1, 1, 0, 1),
    (0, 1, 1, 1, 0, 1, 1, 1), (0, 1, 1, 1, 1, 1, 1, 1));
  KeyLevels: array[0..15] of Double = (
    0, 18, 24, 27.75, 30, 32.25, 33.75, 35.25, 36, 37.5, 38.25, 39, 39.75, 40.5, 41.25, 42);

var
  SineTable: array[0..1, 0..1023] of Word;
  ExpTable: array[0..255] of Word;
  LevelTable: array[0..127, 0..63, 0..3] of Word;
  AmplitudeLfo: array[0..209] of Byte;

// Delphi's shr is logical even for signed operands. OPLL needs arithmetic shifts.
function Sar(Value, Bits: Integer): Integer; inline;
begin
  if Value < 0 then
    Result := -((-(Value + 1)) shr Bits) - 1
  else
    Result := Value shr Bits;
end;

procedure InitializeTables;
begin
  for var I := 0 to 255 do
  begin
    ExpTable[I] := Floor((Power(2, I / 256.0) - 1) * 1024 + 0.5);
    SineTable[0, I] := Floor(-Log2(Sin((I + 0.5) * Pi / 512)) * 256 + 0.5);
    SineTable[0, 511 - I] := SineTable[0, I];
  end;
  for var I := 0 to 511 do
  begin
    SineTable[0, 512 + I] := $8000 or SineTable[0, I];
    SineTable[1, I] := SineTable[0, I];
    SineTable[1, 512 + I] := $FFF;
  end;
  for var Block := 0 to 7 do
    for var Fnum := 0 to 15 do
      for var Level := 0 to 63 do
        for var Scale := 0 to 3 do
        begin
          var Extra := 0;
          if Scale <> 0 then
          begin
            var Attenuation := Trunc(KeyLevels[Fnum] - 6 * (7 - Block));
            if Attenuation > 0 then
              Extra := Trunc((Attenuation shr (3 - Scale)) / 0.375);
          end;
          LevelTable[Block * 16 + Fnum, Level, Scale] := Level * 2 + Extra;
        end;
  // Verified OPLL tremolo: 8 samples per step, a 3-sample peak, 7-sample tail.
  for var I := 0 to 103 do
    AmplitudeLfo[I] := I div 8;
  for var I := 104 to 106 do
    AmplitudeLfo[I] := 13;
  for var I := 107 to 202 do
    AmplitudeLfo[I] := 12 - (I - 107) div 8;
  for var I := 203 to 209 do
    AmplitudeLfo[I] := 0;
end;

procedure TVrc7Fm.DecodePatch(Index: Integer; const Data: array of Byte);
begin
  for var Op := 0 to 1 do
  begin
    var P: PVrc7Patch := @FPatches[Index * 2 + Op];
    P.AM := (Data[Op] shr 7) and 1;
    P.PM := (Data[Op] shr 6) and 1;
    P.EG := (Data[Op] shr 5) and 1;
    P.KR := (Data[Op] shr 4) and 1;
    P.ML := Data[Op] and 15;
    P.KL := Data[2 + Op] shr 6;
    P.TL := 0;
    P.FB := 0;
    if Op = 0 then
    begin
      P.TL := Data[2] and 63;
      P.FB := Data[3] and 7;
    end;
    P.WS := (Data[3] shr (3 + Op)) and 1;
    P.AR := Data[4 + Op] shr 4;
    P.DR := Data[4 + Op] and 15;
    P.SL := Data[6 + Op] shr 4;
    P.RR := Data[6 + Op] and 15;
  end;
end;

procedure TVrc7Fm.Reset(PreserveVibrato: Boolean);
begin
  var Vibrato := FVibratoPhase;
  FillChar(Self, SizeOf(Self), 0);
  if PreserveVibrato then
    FVibratoPhase := Vibrato;
  for var I := 0 to 15 do
    DecodePatch(I, Instruments[I]);
  for var I := 0 to 11 do
  begin
    FSlots[I].PatchIndex := I and 1;
    FSlots[I].Stage := EG_RELEASE;
    FSlots[I].Envelope := EG_MUTE;
    FSlots[I].Updates := UPDATE_ALL;
  end;
end;

procedure TVrc7Fm.WriteRegister(Address, Value: Byte);
begin
  // The unused OPLL channels and rhythm registers do not exist on VRC7.
  if not ((Address <= 7) or (Address = $0F) or
    ((Address >= $10) and (Address <= $15)) or
    ((Address >= $20) and (Address <= $25)) or
    ((Address >= $30) and (Address <= $35))) then
    Exit;
  FRegisters[Address] := Value;
  if Address <= 7 then
  begin
    DecodePatch(0, FRegisters);
    var Flags: Integer;
    case Address of
      0, 1:
        Flags := UPDATE_RKS or UPDATE_EG;
      2:
        Flags := UPDATE_TLL;
      3:
        Flags := UPDATE_WS;
    else
      Flags := UPDATE_EG;
    end;
    for var Ch := 0 to 5 do
      if FRegisters[$30 + Ch] shr 4 = 0 then
      begin
        if Address = 3 then
        begin
          FSlots[Ch * 2].Updates := FSlots[Ch * 2].Updates or UPDATE_WS;
          FSlots[Ch * 2 + 1].Updates := FSlots[Ch * 2 + 1].Updates or UPDATE_WS or UPDATE_TLL;
        end
        else
        begin
          var Index := Ch * 2 + (Address and 1);
          FSlots[Index].Updates := FSlots[Index].Updates or Flags;
        end;
      end;
  end
  else if Address = $0F then
    FTest := Value and 15
  else
  begin
    var Ch := Address and 15;
    for var Op := 0 to 1 do
    begin
      var S: PVrc7Slot := @FSlots[Ch * 2 + Op];
      case Address and $F0 of
        $10, $20:
          begin
            S.Fnum := FRegisters[$10 + Ch] or ((FRegisters[$20 + Ch] and 1) shl 8);
            S.Block := (FRegisters[$20 + Ch] shr 1) and 7;
            S.BlockFnum := (S.Block shl 9) or S.Fnum;
            S.Updates := S.Updates or UPDATE_EG or UPDATE_RKS or UPDATE_TLL;
            if Address >= $20 then
            begin
              if Op = 1 then
                S.Sustain := (Value and $20) <> 0;
              var Key := (Value and $10) <> 0;
              if S.KeyOn <> Key then
              begin
                S.KeyOn := Key;
                if Key then
                  S.Stage := EG_DAMP
                else if Op = 1 then
                  S.Stage := EG_RELEASE;
              end;
            end;
          end;
        $30:
          begin
            S.PatchIndex := (Value shr 4) * 2 + Op;
            if Op = 1 then
              S.Volume := (Value and 15) shl 2;
            S.Updates := UPDATE_ALL;
          end;
      end;
    end;
  end;
end;

procedure TVrc7Fm.ClockReset;
begin
  // While E000:6 is held, only the vibrato LFO continues to run.
  FVibratoPhase := (FVibratoPhase + 1) and $1FFF;
end;

procedure TVrc7Fm.CommitSlot(Index: Integer);
begin
  var S: PVrc7Slot := @FSlots[Index];
  var P: PVrc7Patch := @FPatches[S.PatchIndex];
  if (S.Updates and UPDATE_WS) <> 0 then
    S.Waveform := P.WS;
  if (S.Updates and UPDATE_TLL) <> 0 then
  begin
    var Level := S.Volume;
    if (Index and 1) = 0 then
      Level := P.TL;
    S.TotalLevel := LevelTable[S.BlockFnum shr 5, Level, P.KL];
  end;
  if (S.Updates and UPDATE_RKS) <> 0 then
    if P.KR <> 0 then
      S.RateScale := S.Block * 2 + (S.Fnum shr 8)
    else
      S.RateScale := S.Block shr 1;
  if (S.Updates and (UPDATE_RKS or UPDATE_EG)) <> 0 then
  begin
    var Rate := 0;
    if ((Index and 1) <> 0) or S.KeyOn then
      case S.Stage of
        EG_ATTACK:
          Rate := P.AR;
        EG_DECAY:
          Rate := P.DR;
        EG_SUSTAIN:
          if P.EG = 0 then
            Rate := P.RR;
        EG_RELEASE:
          if S.Sustain then
            Rate := 5
          else if P.EG <> 0 then
            Rate := P.RR
          else
            Rate := 7;
        EG_DAMP:
          Rate := 12;
      end;
    if Rate = 0 then
    begin
      S.Shift := 0;
      S.RateHigh := 0;
      S.RateLow := 0;
      // Keep the update pending, as emu2413 does for a stopped envelope.
      Exit;
    end;
    S.RateHigh := Min(15, Rate + (S.RateScale shr 2));
    S.RateLow := S.RateScale and 3;
    if S.Stage = EG_ATTACK then
      if S.RateHigh < 12 then
        S.Shift := 13 - S.RateHigh
      else
        S.Shift := 0
    else
      S.Shift := Max(0, 13 - S.RateHigh);
  end;
  S.Updates := 0;
end;

procedure TVrc7Fm.ClockEnvelope(Index: Integer);
begin
  var S: PVrc7Slot := @FSlots[Index];
  var P: PVrc7Patch := @FPatches[S.PatchIndex];
  var Mask := (1 shl S.Shift) - 1;
  var Step := 0;
  if S.Stage = EG_ATTACK then
  begin
    if (S.Envelope > 0) and (S.RateHigh > 0) and
      ((FEnvelopeCounter and Mask and not 3) = 0) then
    begin
      case S.RateHigh of
        12, 13, 14:
          Step := 16 - S.RateHigh - EnvelopeSteps[S.RateLow, (FEnvelopeCounter and 12) shr 1];
        0, 15:
          Step := 0;
      else
        if EnvelopeSteps[S.RateLow, (FEnvelopeCounter shr S.Shift) and 7] <> 0 then
          Step := 4;
      end;
      if Step > 0 then
        S.Envelope := Max(0, S.Envelope - (S.Envelope shr Step) - 1);
    end;
  end
  else if (S.RateHigh > 0) and ((FEnvelopeCounter and Mask) = 0) then
  begin
    case S.RateHigh of
      13:
        Step := EnvelopeSteps[S.RateLow, ((FEnvelopeCounter and 12) shr 1) or (FEnvelopeCounter and 1)];
      14:
        Step := EnvelopeSteps[S.RateLow, (FEnvelopeCounter and 12) shr 1] + 1;
      15:
        Step := 2;
    else
      Step := EnvelopeSteps[S.RateLow, (FEnvelopeCounter shr S.Shift) and 7];
    end;
    S.Envelope := Min(EG_MUTE, S.Envelope + Step);
  end;
  case S.Stage of
    EG_DAMP:
      if (S.Envelope >= EG_MAX) and ((FEnvelopeCounter and Mask) = 0) then
      begin
        if Min(15, P.AR + (S.RateScale shr 2)) = 15 then
        begin
          S.Stage := EG_DECAY;
          S.Envelope := 0
        end
        else
          S.Stage := EG_ATTACK;
        S.Updates := S.Updates or UPDATE_EG;
        if (Index and 1) <> 0 then
        begin
          S.Phase := 0;
          FSlots[Index - 1].Phase := 0
        end;
      end;
    EG_ATTACK:
      if S.Envelope = 0 then
      begin
        S.Stage := EG_DECAY;
        S.Updates := S.Updates or UPDATE_EG
      end;
    EG_DECAY:
      if S.Envelope shr 3 = P.SL then
      begin
        S.Stage := EG_SUSTAIN;
        S.Updates := S.Updates or UPDATE_EG
      end;
  end;
end;

function TVrc7Fm.LinearOutput(Index, Phase: Integer): Integer;
begin
  var S: PVrc7Slot := @FSlots[Index];
  var Envelope := S.Envelope;
  // Test bit 0 overrides the output; it must not corrupt the running envelope.
  if (FTest and 1) <> 0 then
    Envelope := 0;
  if Envelope > EG_MAX then
    Exit(0);
  var Amplitude := 0;
  if FPatches[S.PatchIndex].AM <> 0 then
    Amplitude := FTremolo;
  var Attenuation := SineTable[S.Waveform, Phase and 1023] +
    (Min(EG_MUTE, Envelope + S.TotalLevel + Amplitude) shl 4);
  var Magnitude: Integer := (ExpTable[(Attenuation and $FF) xor $FF] + 1024) shr ((Attenuation and $7F00) shr 8);
  if (Attenuation and $8000) <> 0 then
    Magnitude := not Magnitude;
  Result := Magnitude * 2;
end;

function TVrc7Fm.Sample: SmallInt;
begin
  if (FTest and 2) <> 0 then
  begin
    FVibratoPhase := 0;
    FTremoloPhase := 0
  end
  else if (FTest and 8) <> 0 then
  begin
    FVibratoPhase := (FVibratoPhase + 1024) and $1FFF;
    FTremoloPhase := (FTremoloPhase + 64) mod (210 * 64);
  end
  else
  begin
    FVibratoPhase := (FVibratoPhase + 1) and $1FFF;
    FTremoloPhase := (FTremoloPhase + 1) mod (210 * 64);
  end;
  FTremolo := AmplitudeLfo[FTremoloPhase shr 6];
  FEnvelopeCounter := (Cardinal(FEnvelopeCounter) + 1) and $FFFF;
  for var I := 0 to 11 do
  begin
    var S: PVrc7Slot := @FSlots[I];
    var P: PVrc7Patch := @FPatches[S.PatchIndex];
    if S.Updates <> 0 then
      CommitSlot(I);
    ClockEnvelope(I);
    if (FTest and 4) <> 0 then
      S.Phase := 0;
    var Pitch := 0;
    if P.PM <> 0 then
      Pitch := PitchLfo[(S.Fnum shr 6) and 7, FVibratoPhase shr 10];
    S.Phase := (S.Phase + Cardinal(((S.Fnum * 2 + Pitch) * Multipliers[P.ML]) shl S.Block shr 2)) and $7FFFF;
    S.PhaseOutput := S.Phase shr 9;
  end;
  var Mix := 0;
  for var Ch := 0 to 5 do
  begin
    var Modulator: PVrc7Slot := @FSlots[Ch * 2];
    var Carrier: PVrc7Slot := @FSlots[Ch * 2 + 1];
    var Feedback := FPatches[Modulator.PatchIndex].FB;
    var Phase := 0;
    if Feedback <> 0 then
      Phase := Sar(Modulator.Output + Modulator.PreviousOutput, 9 - Feedback);
    Modulator.PreviousOutput := Modulator.Output;
    Modulator.Output := LinearOutput(Ch * 2, Integer(Modulator.PhaseOutput) + Phase);
    Carrier.PreviousOutput := Carrier.Output;
    Carrier.Output := LinearOutput(Ch * 2 + 1, Integer(Carrier.PhaseOutput) + 2 * Sar(Modulator.Output, 1));
    Inc(Mix, Sar(-Carrier.Output, 1));
  end;
  Result := Mix;
end;

procedure TVrc7Fm.SerializeState(State: TNesStateArchive);
begin
  State.Field(FRegisters, SizeOf(FRegisters));
  State.Field(FPatches, SizeOf(FPatches));
  State.Field(FSlots, SizeOf(FSlots));
  State.Field(FEnvelopeCounter, SizeOf(FEnvelopeCounter));
  State.Field(FVibratoPhase, SizeOf(FVibratoPhase));
  State.Field(FTremoloPhase, SizeOf(FTremoloPhase));
  State.Field(FTremolo, SizeOf(FTremolo));
  State.Field(FTest, SizeOf(FTest));
end;

initialization
  InitializeTables;

end.

