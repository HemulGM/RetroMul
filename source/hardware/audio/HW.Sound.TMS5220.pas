unit HW.Sound.TMS5220;

interface

uses
  Core.Snapshots;

type
  // PE-LPC synthesis for cartridges that supply the bitstream in four-bit writes.
  TPeLpcSpeech = class
  private
    type
      TFrame = packed record
        Energy, Pitch: Integer;
        Reflection: array[0..9] of Integer;
      end;

      TSpeechState = packed record
        Fifo: array[0..31] of Byte;
        ReadBit, BitCount, ClockPhase, SamplesLeft, PitchPhase: Integer;
        Target, Current: TFrame;
        Delay: array[0..9] of Integer;
        Noise: Word;
        Sample: SmallInt;
      end;
  private
    FState: TSpeechState;
    FCpuFrequency: Integer;
    function PeekBits(Offset, Count: Integer): Integer;
    function ReadBits(Count: Integer): Integer;
    function ReadFrame: Boolean;
    procedure Interpolate(Shift: Integer);
    procedure Synthesize;
  public
    constructor Create;
    procedure Reset;
    procedure SetCpuFrequency(Frequency: Integer);
    function Ready: Boolean; inline;
    procedure WriteNibble(Value: Byte);
    procedure Clock; inline;
    function Output: Double; inline;
    procedure SerializeState(State: TStateArchive);
  end;

implementation

uses
  System.Classes, System.Math;

const
  SampleRate = 8000;
  SamplesPerFrame = 200;
  InterpolationPeriod = 25;
  FifoBits = 128;
  CoefficientWidths: array[0..9] of Byte = (5, 5, 4, 4, 4, 4, 4, 3, 3, 3);
  InterpolationShift: array[0..7] of Byte = (3, 3, 3, 2, 2, 1, 1, 0);

  // TMS5220C parameter ROM values documented by the TI die analysis in
  // mamedev/mame, src/devices/sound/tms5110r.hxx.
  Energy: array[0..15] of Byte =
    (0, 1, 2, 3, 4, 6, 8, 11, 16, 23, 33, 47, 63, 85, 114, 0);
  Pitch: array[0..63] of Byte =
    (0, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29,
    30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 44, 46, 48,
    50, 52, 53, 56, 58, 60, 62, 65, 68, 70, 72, 76, 78, 80, 84, 86,
    91, 94, 98, 101, 105, 109, 114, 118, 122, 127, 132, 137, 142, 148, 153, 159);
  K1: array[0..31] of SmallInt =
    (-501, -498, -497, -495, -493, -491, -488, -482,
    -478, -474, -469, -464, -459, -452, -445, -437,
    -412, -380, -339, -288, -227, -158, -81, -1, 80, 157, 226, 287, 337, 379, 411, 436);
  K2: array[0..31] of SmallInt =
    (-328, -303, -274, -244, -211, -175, -138, -99,
    -59, -18, 24, 64, 105, 143, 180, 215,
    248, 278, 306, 331, 354, 374, 392, 408, 422, 435, 445, 455, 463, 470, 476, 506);
  K3: array[0..15] of SmallInt =
    (-441, -387, -333, -279, -225, -171, -117, -63, -9, 45, 98, 152, 206, 260, 314, 368);
  K4: array[0..15] of SmallInt =
    (-328, -273, -217, -161, -106, -50, 5, 61, 116, 172, 228, 283, 339, 394, 450, 506);
  K5: array[0..15] of SmallInt =
    (-328, -282, -235, -189, -142, -96, -50, -3, 43, 90, 136, 182, 229, 275, 322, 368);
  K6: array[0..15] of SmallInt =
    (-256, -212, -168, -123, -79, -35, 10, 54, 98, 143, 187, 232, 276, 320, 365, 409);
  K7: array[0..15] of SmallInt =
    (-308, -260, -212, -164, -117, -69, -21, 27, 75, 122, 170, 218, 266, 314, 361, 409);
  K8: array[0..7] of SmallInt = (-256, -161, -66, 29, 124, 219, 314, 409);
  K9: array[0..7] of SmallInt = (-256, -176, -96, -15, 65, 146, 226, 307);
  K10: array[0..7] of SmallInt = (-205, -132, -59, 14, 87, 160, 234, 307);
  Coefficients: array[0..9] of PSmallInt = (@K1, @K2, @K3, @K4, @K5, @K6, @K7, @K8, @K9, @K10);
  // The rest of the chirp ROM is zero.
  Chirp: array[0..20] of Byte =
    ($00, $03, $0F, $28, $4C, $6C, $71, $50, $25, $26, $4C, $44,
    $1A, $32, $3B, $13, $37, $1A, $25, $1F, $1D);

function SignedShift(Value, Bits: Integer): Integer; inline;
begin
  Result := ((Value + $1000000) shr Bits) - ($1000000 shr Bits);
end;

function WrapFilter(Value: Integer): Integer; inline;
begin
  Result := ((Value + $4000) and $7FFF) - $4000;
end;

constructor TPeLpcSpeech.Create;
begin
  inherited;
  FCpuFrequency := 1789773;
  Reset;
end;

procedure TPeLpcSpeech.Reset;
begin
  FState := Default(TSpeechState);
  FState.Noise := $1FFF;
end;

procedure TPeLpcSpeech.SetCpuFrequency(Frequency: Integer);
begin
  if FCpuFrequency <> Frequency then
  begin
    FCpuFrequency := Frequency;
    FState.ClockPhase := 0;
  end;
end;

function TPeLpcSpeech.Ready: Boolean;
begin
  Result := FState.BitCount <= FifoBits - 4;
end;

procedure TPeLpcSpeech.WriteNibble(Value: Byte);
begin
  if Ready then
  begin
    var Slot := ((FState.ReadBit + FState.BitCount) and (FifoBits - 1)) shr 2;
    FState.Fifo[Slot] := Value and $0F;
    Inc(FState.BitCount, 4);
  end;
end;

function TPeLpcSpeech.PeekBits(Offset, Count: Integer): Integer;
begin
  Result := 0;
  for var Index := 0 to Count - 1 do
  begin
    var Bit := (FState.ReadBit + Offset + Index) and (FifoBits - 1);
    Result := (Result shl 1) or ((FState.Fifo[Bit shr 2] shr (Bit and 3)) and 1);
  end;
end;

function TPeLpcSpeech.ReadBits(Count: Integer): Integer;
begin
  Result := PeekBits(0, Count);
  FState.ReadBit := (FState.ReadBit + Count) and (FifoBits - 1);
  Dec(FState.BitCount, Count);
end;

function TPeLpcSpeech.ReadFrame: Boolean;
begin
  Result := False;
  if FState.BitCount < 4 then
    Exit;

  var EnergyCode := PeekBits(0, 4);
  if EnergyCode = 15 then
  begin
    Reset;
    Exit;
  end;

  var FrameBits := 4;
  var CoefficientCount := 0;
  if EnergyCode <> 0 then
  begin
    if FState.BitCount < 11 then
      Exit;
    FrameBits := 11;
    if PeekBits(4, 1) = 0 then
      if PeekBits(5, 6) = 0 then
      begin
        FrameBits := 29;
        CoefficientCount := 4;
      end
      else
      begin
        FrameBits := 50;
        CoefficientCount := 10;
      end;
  end;
  // A frame can straddle multiple writes, so wait until it can be read whole.
  if FState.BitCount < FrameBits then
    Exit;

  FState.Target.Energy := Energy[ReadBits(4)];
  FState.Target.Pitch := 0;
  if EnergyCode <> 0 then
  begin
    ReadBits(1);
    FState.Target.Pitch := Pitch[ReadBits(6)];
    for var Index := 0 to CoefficientCount - 1 do
    begin
      var Code := ReadBits(CoefficientWidths[Index]);
      FState.Target.Reflection[Index] := PSmallInt(NativeUInt(Coefficients[Index]) + NativeUInt(Code) * SizeOf(SmallInt))^;
    end;
  end;
  if (FState.Current.Pitch = 0) <> (FState.Target.Pitch = 0) then
  begin
    FState.PitchPhase := 0;
    FState.Current.Pitch := FState.Target.Pitch;
  end;
  FState.SamplesLeft := SamplesPerFrame;
  Result := True;
end;

procedure TPeLpcSpeech.Interpolate(Shift: Integer);
begin
  Inc(FState.Current.Energy, SignedShift(FState.Target.Energy - FState.Current.Energy, Shift));
  Inc(FState.Current.Pitch, SignedShift(FState.Target.Pitch - FState.Current.Pitch, Shift));
  for var Index := 0 to High(FState.Current.Reflection) do
  begin
    var Coefficient := FState.Target.Reflection[Index];
    if (Index >= 4) and (FState.Target.Pitch = 0) then
      Coefficient := 0;
    Inc(FState.Current.Reflection[Index], SignedShift(Coefficient - FState.Current.Reflection[Index], Shift));
  end;
end;

procedure TPeLpcSpeech.Synthesize;
begin
  if (FState.SamplesLeft = 0) and not ReadFrame then
  begin
    FState.Sample := 0;
    Exit;
  end;
  if (FState.SamplesLeft mod InterpolationPeriod) = 0 then
    Interpolate(InterpolationShift[(SamplesPerFrame - FState.SamplesLeft) div InterpolationPeriod]);

  var Excitation := 0;
  if FState.Current.Pitch = 0 then
    Excitation := 64 - ((FState.Noise and 1) shl 7)
  else if FState.PitchPhase <= High(Chirp) then
    Excitation := Chirp[FState.PitchPhase];
  Inc(FState.PitchPhase);
  if FState.PitchPhase >= FState.Current.Pitch then
    FState.PitchPhase := 0;

  for var Tick := 1 to 20 do
  begin
    var Noise := FState.Noise;
    var Feedback := ((Noise shr 12) xor (Noise shr 3) xor (Noise shr 2) xor Noise) and 1;
    FState.Noise := ((Noise shl 1) or Feedback) and $1FFF;
  end;

  var forward := SignedShift(Excitation * FState.Current.Energy, 3);
  for var Index := High(FState.Delay) downto 0 do
  begin
    var K := FState.Current.Reflection[Index];
    forward := WrapFilter(forward - SignedShift(K * FState.Delay[Index], 9));
    if Index < High(FState.Delay) then
      FState.Delay[Index + 1] := WrapFilter(FState.Delay[Index] + SignedShift(K * forward, 9));
  end;
  FState.Delay[0] := forward;
  FState.Sample := EnsureRange(forward, -2048, 2047);
  Dec(FState.SamplesLeft);
end;

procedure TPeLpcSpeech.Clock;
begin
  if (FState.SamplesLeft <> 0) or (FState.BitCount <> 0) or (FState.Sample <> 0) then
  begin
    Inc(FState.ClockPhase, SampleRate);
    if FState.ClockPhase >= FCpuFrequency then
    begin
      Dec(FState.ClockPhase, FCpuFrequency);
      Synthesize;
    end;
  end;
end;

function TPeLpcSpeech.Output: Double;
begin
  Result := FState.Sample * (1.0 / 8192.0);
end;

procedure TPeLpcSpeech.SerializeState(State: TStateArchive);
begin
  State.Field(FState, SizeOf(FState));
  if not State.Loading then
    Exit;

  if (Cardinal(FState.ReadBit) >= FifoBits) or (Cardinal(FState.BitCount) > FifoBits) or
    (((FState.ReadBit + FState.BitCount) and 3) <> 0) or
    (Cardinal(FState.ClockPhase) >= Cardinal(FCpuFrequency)) or
    (Cardinal(FState.SamplesLeft) > SamplesPerFrame) or
    (Cardinal(FState.PitchPhase) > High(Byte)) or (FState.Noise > $1FFF) or
    (FState.Sample < -2048) or (FState.Sample > 2047) or
    (Cardinal(FState.Current.Pitch) > High(Byte)) or (Cardinal(FState.Target.Pitch) > High(Byte)) or
    (Cardinal(FState.Current.Energy) > 114) or (Cardinal(FState.Target.Energy) > 114) then
    raise EReadError.Create('Invalid PE-LPC speech state');
  for var Index := 0 to High(FState.Delay) do
    if (FState.Delay[Index] < -16384) or (FState.Delay[Index] > 16383) or
      (FState.Current.Reflection[Index] < -512) or (FState.Current.Reflection[Index] > 511) or
      (FState.Target.Reflection[Index] < -512) or (FState.Target.Reflection[Index] > 511) then
      raise EReadError.Create('Invalid PE-LPC filter state');
end;

end.

