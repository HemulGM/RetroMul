unit PSP.SAS;

interface

uses
  System.SysUtils, System.Generics.Collections, PSP.Memory, PSP.CPU;

type
  TPSPSASVoice = record
    Address, Size, Pitch, Position: Cardinal;
    Loop: Integer;
    PCM, Playing, Paused: Boolean;
    Volume: array[0..3] of Integer;
    Rate, Mode: array[0..3] of Cardinal;
    Sustain, Height: Cardinal;
    Stage, KeyDelay, SampleIndex, History1, History2: Integer;
    Block, LoopBlock, Fraction: Cardinal;
    LoopNext, Ended: Boolean;
    CurrentSample, NextSample: SmallInt;
    Decoded: array[0..27] of SmallInt;
  end;

  TPSPSASCore = class
  private
    ReverbRAM: TArray<SmallInt>;
    ReverbPosition: Integer;
    function ReverbRead(Offset: Integer): Integer;
    procedure ReverbWrite(Offset, Value: Integer);
  public
    Grain, OutputMode, Pause: Cardinal;
    Voices: array[0..31] of TPSPSASVoice;
    ReverbType: Integer;
    Dry, Wet: Boolean;
    EffectLeft, EffectRight, Delay, Feedback: Cardinal;
    procedure SetReverb(Value: Integer);
    procedure Reverb(Left, Right: Integer; out OutLeft, OutRight: Integer);
  end;

  TPSPSAS = class
  private
    FMemory: TPSPMemory;
    FCPU: TPSPCPU;
    FCores: TObjectDictionary<Cardinal, TPSPSASCore>;
    function Sample(var Voice: TPSPSASVoice): SmallInt;
    procedure Envelope(var Voice: TPSPSASVoice);
    procedure Mix(Core: TPSPSASCore; Address: Cardinal; WithMix: Boolean; Left, Right: Integer);
  public
    constructor Create(Memory: TPSPMemory; CPU: TPSPCPU);
    destructor Destroy; override;
    function Handle(NID: Cardinal; out Value: Cardinal): Boolean;
  end;

implementation

uses
  System.Math{$IFDEF PSP_PROFILE}, PSP.Profile{$ENDIF};

// PPSSPP SasReverb.cpp preset data, GPL-2.0-or-later. See PSP.PRX-LICENSE.md.
const
  SASReverbPresets: array[0..8, 0..30] of Integer = (
    (9920, 125, 91, 28032, 21688, -16688, 0, 0, -17792, 22528, 21248, 1238, 819, 1008, 551, 884, 495, 822, 439, 821, 438, 820, 437, 820, 437, 820, 437, 436, 310, 184, 92),
    (8000, 51, 37, 28912, 20392, -17184, 17424, -16144, -25600, 21120, 20160, 996, 795, 932, 687, 882, 614, 796, 605, 604, 398, 559, 309, 466, 183, 399, 181, 180, 128, 76, 38),
    (18496, 177, 127, 28912, 20392, -17184, 17680, -16656, -19264, 21120, 20160, 2308, 1899, 2084, 1631, 1954, 1558, 1900, 1517, 1516, 1070, 1295, 773, 1122, 695, 1071, 613, 612, 434, 256, 128),
    (28640, 227, 169, 28512, 20392, -17184, 17680, -16656, -22912, 22144, 21184, 3579, 2904, 3337, 2620, 3033, 2419, 2905, 2266, 2265, 1513, 2028, 1200, 1775, 978, 1514, 797, 796, 568, 340, 170),
    (44512, 421, 313, 24576, 20480, 19456, -18432, -17408, -16384, 24576, 23552, 5562, 4539, 5314, 4285, 4540, 3521, 4544, 3523, 3520, 2497, 3012, 1985, 2560, 1741, 2498, 1473, 1472, 1050, 628, 314),
    (63168, 829, 561, 32256, 20480, -19456, -20480, 19456, -20480, 24576, 21504, 7894, 6705, 7444, 6203, 7106, 5810, 6706, 5615, 5614, 4181, 4916, 3885, 4598, 3165, 4182, 2785, 2784, 1954, 1124, 562),
    (98368, 3, 3, 32767, 32767, 0, 0, 0, -32512, 0, 0, 8189, 4093, 4105, 9, 0, 0, 4105, 9, 8191, 8191, 8190, 8190, 8190, 8190, 8190, 8190, 4104, 4100, 8, 4),
    (98368, 3, 3, 32767, 32767, 0, 0, 0, 0, 0, 0, 8189, 4093, 4105, 9, 0, 0, 4105, 9, 8191, 8191, 8190, 8190, 8190, 8190, 8190, 8190, 4104, 4100, 8, 4),
    (15360, 23, 19, 28912, 20392, -17184, 17680, -16656, -31488, 24448, 21696, 881, 687, 741, 479, 688, 471, 856, 618, 470, 286, 301, 177, 287, 89, 416, 227, 88, 64, 40, 20));

function SignedShift(Value: Integer; Count: Cardinal): Integer;
begin
  if Value < 0 then
    Result := not (not Value shr Count)
  else
    Result := Value shr Count;
end;

procedure TPSPSASCore.SetReverb(Value: Integer);
begin
  ReverbType := Value;
  ReverbPosition := 0;
  ReverbRAM := nil;
  if Value >= 0 then
    SetLength(ReverbRAM, SASReverbPresets[Value, 0]);
end;

function TPSPSASCore.ReverbRead(Offset: Integer): Integer;
begin
  var Address := (ReverbPosition + Offset) mod Length(ReverbRAM);
  if Address < 0 then
    Inc(Address, Length(ReverbRAM));
  Result := ReverbRAM[Address];
end;

procedure TPSPSASCore.ReverbWrite(Offset, Value: Integer);
begin
  var Address := (ReverbPosition + Offset) mod Length(ReverbRAM);
  if Address < 0 then
    Inc(Address, Length(ReverbRAM));
  ReverbRAM[Address] := EnsureRange(Value, -32768, 32767);
end;

procedure TPSPSASCore.Reverb(Left, Right: Integer; out OutLeft, OutRight: Integer);
var
  P: array[0..30] of Integer;

  procedure Reflect(Dest, Source, Input: Integer);
  begin
    var Prev := ReverbRead(P[Dest] - 1);
    ReverbWrite(P[Dest], Input + SignedShift(ReverbRead(P[Source]) * P[8], 15) - SignedShift(Prev * P[3], 15) + Prev);
  end;

  function Comb(A, B, C, D: Integer): Integer;
  begin
    Result := (Int64(P[4]) * ReverbRead(P[A]) + Int64(P[5]) * ReverbRead(P[B]) +
      Int64(P[6]) * ReverbRead(P[C]) + Int64(P[7]) * ReverbRead(P[D])) div $8000;
  end;

  function AllPass(Input, Dest, Offset, Gain: Integer): Integer;
  begin
    var delayed := ReverbRead(P[Dest] - P[Offset]);
    ReverbWrite(P[Dest], Input - SignedShift(P[Gain] * delayed, 15));
    Result := delayed + SignedShift(ReverbRead(P[Dest]) * P[Gain], 15);
  end;

begin
  if ReverbType < 0 then
  begin
    OutLeft := Int64(Left) * EffectLeft div $1000;
    OutRight := Int64(Right) * EffectRight div $1000;
    Exit;
  end;
  Move(SASReverbPresets[ReverbType], P, SizeOf(P));
  if ReverbType in [6, 7] then
  begin
    var D16 := Integer(Delay + 1) * 16;
    P[11] := D16 * 2 - P[1];
    P[12] := D16 - P[2];
    P[13] := P[14] + D16;
    P[17] := P[18] + D16;
    P[27] := P[29] + D16;
    P[28] := D16 + P[29] div 2;
    P[8] := -Integer(Feedback shl 8);
  end;
  Reflect(11, 17, SignedShift(Left, 2));
  Reflect(12, 18, SignedShift(Right, 2));
  Reflect(19, 26, SignedShift(Left, 2));
  Reflect(20, 25, SignedShift(Right, 2));
  OutLeft := AllPass(AllPass(Comb(13, 15, 21, 23), 27, 1, 9), 29, 2, 10);
  OutRight := AllPass(AllPass(Comb(14, 16, 22, 24), 28, 1, 9), 30, 2, 10);
  OutLeft := EnsureRange(Int64(OutLeft) * EffectLeft div $800, Int64(-32768), Int64(32767));
  OutRight := EnsureRange(Int64(OutRight) * EffectRight div $800, Int64(-32768), Int64(32767));
  Inc(ReverbPosition);
  if ReverbPosition = Length(ReverbRAM) then
    ReverbPosition := 0;
end;

function TPSPSAS.Sample(var Voice: TPSPSASVoice): SmallInt;
const
  Positive: array[0..15] of Integer = (0, 60, 115, 98, 122, 0, 0, 52, 55, 60, 0, 0, 0, 2, 125, 0);
  Negative: array[0..15] of Integer = (0, 0, 52, 55, 60, 0, 0, 0, 2, 125, 0, 91, 0, 216, 6, 151);
begin
  Result := 0;
  if Voice.Ended or (Voice.Address = 0) then
    Exit;
  if Voice.PCM then
  begin
    if Voice.Position >= Voice.Size then
      if Voice.Loop >= 0 then
        Voice.Position := Voice.Loop
      else
      begin
        Voice.Ended := True;
        Exit;
      end;
    Result := SmallInt(FMemory.Read16(Voice.Address + Voice.Position * 2));
    Inc(Voice.Position);
    Exit;
  end;
  if Voice.SampleIndex = 28 then
  begin
    if Voice.LoopNext then
    begin
      Voice.Block := Voice.LoopBlock;
      Voice.LoopNext := False;
    end;
    if Voice.Block >= Voice.Size div 16 then
    begin
      Voice.Ended := True;
      Exit;
    end;
    var Address := Voice.Address + Voice.Block * 16;
    var Header := FMemory.Read8(Address);
    var Flag := FMemory.Read8(Address + 1);
    if Flag = 7 then
    begin
      Voice.Ended := True;
      Exit;
    end;
    if Flag = 6 then
      Voice.LoopBlock := Voice.Block;
    if (Flag = 3) and (Voice.Loop >= 0) then
      Voice.LoopNext := True;
    var Predictor := Header shr 4;
    for var I := 0 to 27 do
    begin
      var Nibble := (FMemory.Read8(Address + 2 + Cardinal(I div 2)) shr ((I and 1) * 4)) and 15;
      var Value := SignedShift(SmallInt(Nibble shl 12), Header and 15) +
        SignedShift(Voice.History1 * Positive[Predictor] - Voice.History2 * Negative[Predictor], 6);
      Value := EnsureRange(Value, -32768, 32767);
      Voice.History2 := Voice.History1;
      Voice.History1 := Value;
      Voice.Decoded[I] := Value;
    end;
    Inc(Voice.Block);
    Voice.SampleIndex := 0;
  end;
  Result := Voice.Decoded[Voice.SampleIndex];
  Inc(Voice.SampleIndex);
end;

function SimpleEnvelopeRate(N: Cardinal; Exponential: Boolean): Cardinal;
begin
  N := N and $7F;
  if N = $7F then
    Exit(0);
  var Shift := 26;
  if Exponential then
    Shift := 24;
  Result := ((7 - (N and 3)) shl Shift) shr (N shr 2);
  if Result = 0 then
    Result := 1;
end;

procedure TPSPSAS.Envelope(var Voice: TPSPSASVoice);
const
  Maximum = $3FFFFFFF;
begin
  if Voice.KeyDelay > 0 then
  begin
    Dec(Voice.KeyDelay);
    Exit;
  end;
  var Height := Int64(Voice.Height);
  var Rate := Int64(Voice.Rate[Voice.Stage]);
  case Voice.Mode[Voice.Stage] of
    0:
      Inc(Height, Rate);
    1:
      Dec(Height, Rate);
    2:
      if Height <= Maximum * Int64(3) div 4 then
        Inc(Height, Rate)
      else
        Inc(Height, Rate div 4);
    3:
      Height := Height + ((Maximum - Height) * Rate div $100000000) - (Rate + 3) div 4;
    4:
      Height := Height + ((Maximum - Height) * Rate div $100000000) + $4000;
    5:
      Height := Rate;
  end;
  Voice.Height := EnsureRange(Height, Int64(0), Int64(Maximum));
  case Voice.Stage of
    0:
      if Height >= Maximum then
        Voice.Stage := 1;
    1:
      if Height < Int64(Voice.Sustain) then
        Voice.Stage := 2;
    2:
      if Height <= 0 then
        Voice.Stage := 3;
    3:
      if Height <= 0 then
        Voice.Playing := False;
  end;
end;

procedure TPSPSAS.Mix(Core: TPSPSASCore; Address: Cardinal; WithMix: Boolean; Left, Right: Integer);
begin
  {$IFDEF PSP_PROFILE}
  var ProfileStarted := PSPProfileStart;{$ENDIF}
  var Channels: Cardinal := 2;
  if Core.OutputMode = 1 then
    Channels := 4;
  if not FMemory.IsValid(Address, Core.Grain * Channels * 2) then
    raise EPSPInstruction.Create('PSP: invalid SAS output buffer');
  var Accum: TArray<Integer>;
  SetLength(Accum, Core.Grain * Channels);
  var Send: TArray<Integer>;
  SetLength(Send, Core.Grain * 2);
  if WithMix then
    for var I := 0 to Integer(Core.Grain) - 1 do
    begin
      Accum[I * Integer(Channels)] := Integer(SmallInt(FMemory.Read16(Address + Cardinal(I) * Channels * 2))) * Int64(Left) div $1000;
      Accum[I * Integer(Channels) + 1] := Integer(SmallInt(FMemory.Read16(Address + Cardinal(I) * Channels * 2 + 2))) * Int64(Right) div $1000;
    end;
  for var Index := 0 to 31 do
  begin
    var Voice: ^TPSPSASVoice;
    Voice := @Core.Voices[Index];
    if not Voice.Playing or Voice.Paused then
      Continue;
    for var I := 0 to Integer(Core.Grain) - 1 do
    begin
      if not Voice.Playing then
        Break;
      if Voice.KeyDelay > 0 then
      begin
        Envelope(Voice^);
        Continue;
      end;
      var Value := Integer(Voice.CurrentSample) +
        SignedShift((Integer(Voice.NextSample) - Voice.CurrentSample) * Integer(Voice.Fraction), 12);
      Value := (Int64(Value) * Voice.Height) div $40000000;
      for var C := 0 to Integer(Channels) - 1 do
        if Core.Dry or (C >= 2) then
          Inc(Accum[I * Integer(Channels) + C], Int64(Value) * Voice.Volume[C] div $1000);
      Inc(Send[I * 2], Int64(Value) * Voice.Volume[2] div $1000);
      Inc(Send[I * 2 + 1], Int64(Value) * Voice.Volume[3] div $1000);
      Envelope(Voice^);
      Inc(Voice.Fraction, Voice.Pitch);
      while Voice.Fraction >= $1000 do
      begin
        Dec(Voice.Fraction, $1000);
        Voice.CurrentSample := Voice.NextSample;
        Voice.NextSample := Sample(Voice^);
      end;
      if Voice.Ended then
      begin
        Voice.Playing := False;
        Voice.Height := 0;
      end;
    end;
  end;
  if Core.Wet and (Channels = 2) then
    for var I := 0 to Integer(Core.Grain div 2) - 1 do
    begin
      var L, R: Integer;
      Core.Reverb(EnsureRange(Send[I * 4], -32768, 32767), EnsureRange(Send[I * 4 + 1], -32768, 32767), L, R);
      Inc(Accum[I * 4], L);
      Inc(Accum[I * 4 + 1], R);
      if Core.ReverbType < 0 then
      begin
        Inc(Accum[I * 4 + 2], L);
        Inc(Accum[I * 4 + 3], R);
      end;
    end;
  for var I := 0 to High(Accum) do
    FMemory.Write16(Address + Cardinal(I) * 2, Word(SmallInt(EnsureRange(Accum[I], -32768, 32767))));
  {$IFDEF PSP_PROFILE}  PSPProfileEnd(TPSPProfilePart.SAS, ProfileStarted);{$ENDIF}
end;

constructor TPSPSAS.Create(Memory: TPSPMemory; CPU: TPSPCPU);
begin
  inherited Create;
  FMemory := Memory;
  FCPU := CPU;
  FCores := TObjectDictionary<Cardinal, TPSPSASCore>.Create([doOwnsValues]);
end;

destructor TPSPSAS.Destroy;
begin
  FCores.Free;
  inherited;
end;

function TPSPSAS.Handle(NID: Cardinal; out Value: Cardinal): Boolean;
begin
  Result := True;
  Value := 0;
  var A := FCPU.Registers[4];
  var B := FCPU.Registers[5];
  var C := FCPU.Registers[6];
  var D := FCPU.Registers[7];
  var E := FCPU.Registers[8];
  var F := FCPU.Registers[9];
  var G := FCPU.Registers[10];
  var Core: TPSPSASCore;
  if NID = $42778A9F then
  begin
    if (A and 63 <> 0) or not FMemory.IsValid(A, 64) then
      Value := $80420005
    else if (B < $40) or (B > $800) or (B and 31 <> 0) then
      Value := $80420001
    else if (C = 0) or (C > 32) then
      Value := $80420002
    else if D > 1 then
      Value := $80420003
    else if E <> 44100 then
      Value := $80420004
    else
    begin
      Core := TPSPSASCore.Create;
      Core.Grain := B;
      Core.OutputMode := D;
      Core.Dry := True;
      Core.ReverbType := -1;
      for var I := 0 to 31 do
      begin
        Core.Voices[I].Pitch := $1000;
        Core.Voices[I].Loop := -1;
        Core.Voices[I].Mode[1] := 1;
        Core.Voices[I].Mode[2] := 1;
        Core.Voices[I].Mode[3] := 1;
      end;
      FCores.AddOrSetValue(A, Core);
    end;
    Exit;
  end;
  if not FCores.TryGetValue(A, Core) then
  begin
    Value := $80420100;
    Exit;
  end;
  case NID of
    $A3589D81, $50A14DFC:
      Mix(Core, B, NID = $50A14DFC, Integer(C), Integer(D));
    $BD11B7C2:
      Value := Core.Grain;
    $D1E0A01E:
      if (B < $40) or (B > $800) or (B and 31 <> 0) then
        Value := $80420001
      else
        Core.Grain := B;
    $E175EF66:
      Value := Core.OutputMode;
    $E855BF76:
      if B > 1 then
        Value := $80420003
      else
        Core.OutputMode := B;
    $68A46B95:
      for var I := 0 to 31 do
        if not Core.Voices[I].Playing then
          Value := Value or (Cardinal(1) shl I);
    $2C8E6AB3:
      Value := Core.Pause;
    $787D04D5:
      begin
        if C = 0 then
          Core.Pause := Core.Pause and not B
        else
          Core.Pause := Core.Pause or B;
        for var I := 0 to 31 do
          Core.Voices[I].Paused := Core.Pause and (Cardinal(1) shl I) <> 0;
      end;
    $F983B186:
      begin
        Core.Dry := B <> 0;
        Core.Wet := C <> 0;
      end;
    $33D4AB37:
      if (Integer(B) < -1) or (Integer(B) > 8) then
        Value := $80420020
      else
        Core.SetReverb(Integer(B));
    $267A6DD2:
      if B > 127 then
        Value := $80420022
      else if C > 127 then
        Value := $80420021
      else
      begin
        Core.Delay := B;
        Core.Feedback := C;
      end;
    $D5A229C9:
      if (B > $1000) or (C > $1000) then
        Value := $80420023
      else
      begin
        Core.EffectLeft := B;
        Core.EffectRight := C;
      end;
    $07F58C24:
      if not FMemory.IsValid(B, 128) then
        Value := $80420014
      else
        for var I := 0 to 31 do
          FMemory.Write32(B + Cardinal(I) * 4, Core.Voices[I].Height);
    $99944089, $E1CD9561, $440CA7D8, $AD84D37F, $019B25EB, $9EC3676A, $5F9529F6, $74AE582A, $A0CF2FA4, $76F01ACA, $CBCD4F79:
      begin
        if B > 31 then
        begin
          Value := $80420010;
          Exit;
        end;
        var Voice: ^TPSPSASVoice;
        Voice := @Core.Voices[B];
        case NID of
          $99944089, $E1CD9561:
            begin
              if (D = 0) or (D > $1000000) then
              begin
                Value := $80420014;
                Exit;
              end;
              if NID = $99944089 then
              begin
                if (D and 15 <> 0) then
                begin
                  Value := $80420014;
                  Exit;
                end;
                if E > 1 then
                begin
                  Value := $80420015;
                  Exit;
                end;
              end
              else if (D > $10000) or ((Integer(E) >= 0) and (E >= D)) then
              begin
                Value := $8042001A;
                Exit;
              end;
              Voice.Address := C;
              Voice.Size := D;
              Voice.PCM := NID = $E1CD9561;
              Voice.Position := 0;
              Voice.Loop := Integer(E);
              if not Voice.PCM then
                if E = 0 then
                  Voice.Loop := -1
                else
                  Voice.Loop := 0;
            end;
          $440CA7D8:
            if (Abs(Int64(Integer(C))) > $1000) or (Abs(Int64(Integer(D))) > $1000) or
              (Abs(Int64(Integer(E))) > $1000) or (Abs(Int64(Integer(F))) > $1000) then
              Value := $80420018
            else
            begin
              Voice.Volume[0] := Integer(C);
              Voice.Volume[1] := Integer(D);
              Voice.Volume[2] := Integer(E);
              Voice.Volume[3] := Integer(F);
            end;
          $AD84D37F:
            if (C = 0) or (C > $4000) then
              Value := $80420012
            else
              Voice.Pitch := C;
          $019B25EB, $9EC3676A:
            begin
              var Values: array[0..3] of Cardinal;
              Values[0] := D;
              Values[1] := E;
              Values[2] := F;
              Values[3] := G;
              for var I := 0 to 3 do
                if C and (Cardinal(1) shl I) <> 0 then
                  if NID = $019B25EB then
                  begin
                    if Integer(Values[I]) < 0 then
                    begin
                      Value := $80420019;
                      Exit;
                    end;
                  end
                  else if (Values[I] and $7FFFFFFF > 5) or ((I = 0) and (Values[I] and 1 <> 0)) or
                    ((I in [1, 3]) and (Values[I] and 1 = 0)) then
                  begin
                    Value := $80420013;
                    Exit;
                  end;
              for var I := 0 to 3 do
                if C and (Cardinal(1) shl I) <> 0 then
                  if NID = $019B25EB then
                    Voice.Rate[I] := Values[I]
                  else
                    Voice.Mode[I] := Values[I] and $7FFFFFFF;
            end;
          $CBCD4F79:
            begin
              if D and $2000 <> 0 then
              begin
                Value := $80420013;
                Exit;
              end;
              Voice.Rate[0] := SimpleEnvelopeRate(C shr 8, False);
              Voice.Mode[0] := 0;
              if C and $8000 <> 0 then
                Voice.Mode[0] := 2;
              var Decay := (C shr 4) and 15;
              Voice.Rate[1] := $7FFFFFFF;
              if Decay <> 0 then
                Voice.Rate[1] := Cardinal($80000000) shr Decay;
              Voice.Mode[1] := 3;
              Voice.Mode[2] := (D shr 14) and 3;
              Voice.Rate[2] := SimpleEnvelopeRate(D shr 6, Voice.Mode[2] = 3);
              Voice.Mode[3] := 1;
              if D and $20 <> 0 then
                Voice.Mode[3] := 3;
              var Release := D and 31;
              Voice.Rate[3] := 0;
              if Release <> 31 then
                if Voice.Mode[3] = 1 then
                  case Release of
                    30:
                      Voice.Rate[3] := $40000000;
                    29:
                      Voice.Rate[3] := 1;
                  else
                    Voice.Rate[3] := Cardinal($10000000) shr Release;
                  end
                else if Release = 0 then
                  Voice.Rate[3] := $7FFFFFFF
                else
                  Voice.Rate[3] := Cardinal($80000000) shr Release;
              Voice.Sustain := ((C and 15) + 1) shl 26;
            end;
          $5F9529F6:
            Voice.Sustain := C;
          $74AE582A:
            Value := Voice.Height;
          $76F01ACA:
            if Voice.Paused or Voice.Playing then
              Value := $80420016
            else
            begin
              Voice.Playing := True;
              Voice.Position := 0;
              Voice.Height := 0;
              Voice.Stage := 0;
              Voice.KeyDelay := 32;
              Voice.Ended := False;
              Voice.SampleIndex := 28;
              Voice.Block := 0;
              Voice.LoopBlock := 0;
              Voice.LoopNext := False;
              Voice.History1 := 0;
              Voice.History2 := 0;
              Voice.Fraction := 0;
              Voice.CurrentSample := Sample(Voice^);
              Voice.NextSample := Sample(Voice^);
            end;
          $A0CF2FA4:
            if Voice.Paused or not Voice.Playing then
              Value := $80420016
            else
              Voice.Stage := 3;
        end;
      end;
  else
    Result := False;
  end;
end;

end.

