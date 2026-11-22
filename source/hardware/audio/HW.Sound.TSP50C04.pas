unit HW.Sound.TSP50C04;

interface

uses
  Core.Snapshots;

type
  // D6 stream interface used by the Subor TSP50C04 firmware.
  TTsp50C04 = class
  private
    type
      TLpcFrame = packed record
        Energy, Pitch: Integer;
        Coefficients: array[0..9] of Integer;
      end;

      TDeviceState = packed record
        Fifo: array[0..63] of Byte;
        ReadBit, BitCount, CpuPhase, SamplesLeft, PitchPhase: Integer;
        First, Target, Current: TLpcFrame;
        Delay: array[0..9] of Integer;
        Noise: Word;
        Sample: SmallInt;
        Active, Finished: Boolean;
      end;
  private
    FState: TDeviceState;
    FCpuFrequency: Integer;
    function PeekBits(Offset, Count: Integer): Integer;
    function ReadBits(Count: Integer): Integer;
    function ReadFrame: Boolean;
    procedure Interpolate;
    procedure Synthesize;
  public
    procedure Reset;
    procedure SetClock(Frequency: Integer);
    procedure Write(Value: Byte);
    function ReadStatus: Byte;
    procedure Clock; inline;
    function Output: Double; inline;
    procedure SerializeState(State: TStateArchive);
  end;

implementation

uses
  System.Classes, System.Math;

const
  SampleRate = 10000;
  SamplesPerFrame = 200;
  FifoBits = 512;
  Fraction = 32768;
  // D6 parameter formats and tables are specified in TI SPSS011D, chapter 6
  // and Appendix B. These Q15 values match the Subor firmware's D6 profile.
  EnergyTable: array[0..15] of SmallInt = (
    $0000, $0100, $0200, $0300, $0400, $0500, $0700, $0B00,
    $1100, $1A00, $2900, $3F00, $5500, $7000, $7F00, $0000);
  PitchTable: array[0..127] of SmallInt = (
    $0000, $0100, $0104, $0108, $0110, $0114, $0118, $011C,
    $0124, $0128, $012C, $0134, $0138, $0140, $0144, $014C,
    $0150, $0158, $015C, $0164, $016C, $0170, $0178, $0180,
    $0184, $018C, $0194, $019C, $01A4, $01AC, $01B4, $01BC,
    $01C4, $01CC, $01D4, $01DC, $01E4, $01F0, $01F8, $0200,
    $020C, $0214, $021C, $0228, $0230, $023C, $0248, $0250,
    $025C, $0268, $0274, $0280, $028C, $0298, $02A4, $02B0,
    $02BC, $02C8, $02D4, $02E4, $02F0, $0300, $030C, $031C,
    $0328, $0338, $0348, $0358, $0368, $0378, $0388, $0398,
    $03A8, $03BC, $03CC, $03DC, $03F0, $0404, $0414, $0428,
    $043C, $0450, $0464, $0478, $0490, $04A4, $04BC, $04D0,
    $04E8, $0500, $0514, $052C, $0548, $0560, $0578, $0594,
    $05AC, $05C8, $05E4, $0600, $061C, $0638, $0654, $0674,
    $0690, $06B0, $06D0, $06F0, $0710, $0734, $0754, $0778,
    $079C, $07C0, $07E4, $0808, $082C, $0854, $087C, $08A4,
    $08CC, $08F8, $0920, $094C, $0978, $09A4, $09D0, $0A00);
  ExcitationTable: array[0..159] of SmallInt = (
    $00A2, $00AF, $00BA, $00C2, $00C7, $00C9, $00CA, $00C6,
    $00C2, $00BC, $00B5, $00AD, $00A5, $009E, $009A, $0095,
    $0095, $0098, $009F, $00A8, $00B8, $00CA, $00E3, $00FE,
    $011F, $0141, $0169, $0191, $01BD, $01E8, $0216, $0240,
    $026C, $0292, $02B9, $02D9, $02F8, $030F, $0325, $0332,
    $033F, $0343, $0347, $0345, $0345, $033F, $033D, $033A,
    $033D, $0341, $034E, $035F, $037B, $03A0, $03D2, $040D,
    $0457, $04AD, $0511, $0582, $0600, $068A, $071F, $07BD,
    $0864, $0911, $09C1, $0A74, $0B26, $0BD5, $0C7F, $0D20,
    $0DB7, $0E40, $0EBB, $0F24, $0F7A, $0FBC, $0FE9, $0FFF,
    $0FFF, $0FE9, $0FBC, $0F7A, $0F24, $0EBB, $0E40, $0DB7,
    $0D20, $0C7F, $0BD5, $0B26, $0A74, $09C1, $0911, $0864,
    $07BD, $071F, $068A, $0600, $0582, $0511, $04AD, $0457,
    $040D, $03D2, $03A0, $037B, $035F, $034E, $0341, $033D,
    $033A, $033D, $033F, $0345, $0345, $0347, $0343, $033F,
    $0332, $0325, $030F, $02F8, $02D9, $02B9, $0292, $026C,
    $0240, $0216, $01E8, $01BD, $0191, $0169, $0141, $011F,
    $00FE, $00E3, $00CA, $00B8, $00A8, $009F, $0098, $0095,
    $0095, $009A, $009E, $00A5, $00AD, $00B5, $00BC, $00C2,
    $00C6, $00CA, $00C9, $00C7, $00C2, $00BA, $00AF, $00A2);
  K1Table: array[0..63] of SmallInt = (
    -$7F00, -$7DC0, -$7CC0, -$7B80, -$7A40, -$7900, -$77C0, -$7640,
    -$74C0, -$7340, -$71C0, -$7000, -$6E40, -$6C80, -$6A80, -$68C0,
    -$6680, -$6480, -$6280, -$6040, -$5E00, -$5BC0, -$5940, -$56C0,
    -$5480, -$5200, -$4F40, -$4C80, -$49C0, -$4700, -$4400, -$40C0,
    -$3DC0, -$3A80, -$3740, -$33C0, -$3040, -$2C80, -$2880, -$24C0,
    -$20C0, -$1C80, -$1840, -$1400, -$0FC0, -$0B40, -$0640, -$0140,
    $0440, $09C0, $0F40, $1580, $1C80, $2380, $2AC0, $3280,
    $3A80, $42C0, $4B80, $5400, $5C40, $6500, $6E00, $7880);
  K2Table: array[0..63] of SmallInt = (
    -$7600, -$6800, -$5C40, -$5240, -$4B80, -$4580, -$4000, -$3B00,
    -$3640, -$31C0, -$2D40, -$2940, -$2540, -$2180, -$1E00, -$1A40,
    -$16C0, -$1340, -$1000, -$0CC0, -$0980, -$0640, -$0300, $0000,
    $0340, $0640, $0940, $0C40, $0F40, $1280, $1580, $1880,
    $1B80, $1E80, $2180, $24C0, $27C0, $2AC0, $2DC0, $30C0,
    $3400, $3700, $3A40, $3D00, $4000, $4300, $4600, $4900,
    $4C00, $4F40, $5240, $5540, $5840, $5B40, $5E00, $6100,
    $63C0, $6680, $6940, $6C00, $6F00, $7200, $7640, $7C00);
  K3Table: array[0..31] of SmallInt = (
    -$7500, -$6600, -$5E00, -$5700, -$5100, -$4B00, -$4500, -$4000,
    -$3B00, -$3600, -$3100, -$2C00, -$2700, -$2200, -$1E00, -$1900,
    -$1400, -$0F00, -$0A00, -$0500, $0100, $0700, $0D00, $1400,
    $1A00, $2200, $2900, $3200, $3B00, $4500, $5300, $6D00);
  K4Table: array[0..31] of SmallInt = (
    -$6C00, -$5000, -$3E00, -$3500, -$2D00, -$2700, -$2100, -$1B00,
    -$1600, -$1100, -$0C00, -$0700, -$0200, $0300, $0700, $0C00,
    $1100, $1500, $1A00, $1F00, $2400, $2900, $2E00, $3300,
    $3800, $3E00, $4400, $4B00, $5300, $5A00, $6400, $7400);
  K5Table: array[0..15] of SmallInt = (
    -$5D00, -$3B00, -$2C00, -$2000, -$1600, -$0D00, -$0400, $0400,
    $0C00, $1500, $1E00, $2700, $3100, $3D00, $4C00, $6600);
  K6Table: array[0..15] of SmallInt = (
    -$5600, -$2900, -$1900, -$0E00, -$0400, $0500, $0D00, $1400,
    $1C00, $2400, $2D00, $3600, $4000, $4A00, $5500, $6A00);
  K7Table: array[0..15] of SmallInt = (
    -$5D00, -$3800, -$2900, -$1D00, -$1300, -$0B00, -$0300, $0500,
    $0D00, $1400, $1D00, $2600, $3100, $3C00, $4B00, $6700);
  K8Table: array[0..7] of SmallInt = (
    -$3B00, -$1C00, -$0A00, $0500, $1400, $2700, $3E00, $5800);
  K9Table: array[0..7] of SmallInt = (
    -$4700, -$2400, -$1400, -$0700, $0400, $1000, $1F00, $4500);
  K10Table: array[0..7] of SmallInt = (
    -$3D00, -$1A00, -$0D00, -$0300, $0600, $1100, $1E00, $4300);
  CoefficientWidths: array[0..9] of Byte = (6, 6, 5, 5, 4, 4, 4, 3, 3, 3);
  CoefficientTables: array[0..9] of PSmallInt = (
    @K1Table[0], @K2Table[0], @K3Table[0], @K4Table[0], @K5Table[0],
    @K6Table[0], @K7Table[0], @K8Table[0], @K9Table[0], @K10Table[0]);

procedure TTsp50C04.Reset;
begin
  FState := Default(TDeviceState);
  FState.Noise := $FFFF;
end;

procedure TTsp50C04.SetClock(Frequency: Integer);
begin
  FCpuFrequency := Frequency;
  FState.CpuPhase := 0;
end;

procedure TTsp50C04.Write(Value: Byte);
begin
  if not FState.Active then
  begin
    if Value = $0A then
    begin
      Reset;
      FState.Active := True;
    end
    else if Value = $0F then
      FState.Finished := True;
    Exit;
  end;
  if FState.BitCount <= FifoBits - 8 then
  begin
    var WriteByte := ((FState.ReadBit + FState.BitCount) and (FifoBits - 1)) shr 3;
    FState.Fifo[WriteByte] := Value;
    Inc(FState.BitCount, 8);
  end;
end;

function TTsp50C04.ReadStatus: Byte;
begin
  Result := 0;
  if FState.BitCount <= FifoBits - 8 then
    Result := $80;
  if FState.Finished then
    Result := Result or $0F;
end;

function TTsp50C04.PeekBits(Offset, Count: Integer): Integer;
begin
  Result := 0;
  for var I := 0 to Count - 1 do
  begin
    var Bit := (FState.ReadBit + Offset + I) and (FifoBits - 1);
    Result := (Result shl 1) or ((FState.Fifo[Bit shr 3] shr (Bit and 7)) and 1);
  end;
end;

function TTsp50C04.ReadBits(Count: Integer): Integer;
begin
  Result := PeekBits(0, Count);
  FState.ReadBit := (FState.ReadBit + Count) and (FifoBits - 1);
  Dec(FState.BitCount, Count);
end;

function TTsp50C04.ReadFrame: Boolean;
begin
  Result := False;
  if FState.BitCount < 4 then
    Exit;
  var EnergyCode := PeekBits(0, 4);
  if EnergyCode = $0F then
  begin
    FState.Active := False;
    FState.Finished := True;
    FState.ReadBit := 0;
    FState.BitCount := 0;
    FState.Sample := 0;
    Exit;
  end;
  var Needed := 4;
  if EnergyCode <> 0 then
  begin
    if FState.BitCount < 12 then
      Exit;
    Needed := 12;
    if PeekBits(4, 1) = 0 then
      if PeekBits(5, 7) = 0 then
        Needed := 34
      else
        Needed := 55;
  end;
  if FState.BitCount < Needed then
    Exit;

  FState.First := FState.Target;
  FState.Target.Energy := EnergyTable[ReadBits(4)];
  if EnergyCode <> 0 then
  begin
    var RepeatCoefficients := ReadBits(1) <> 0;
    FState.Target.Pitch := PitchTable[ReadBits(7)];
    var Last := 9;
    if FState.Target.Pitch = 0 then
      Last := 3;
    for var I := 0 to Last do
      if not RepeatCoefficients then
        FState.Target.Coefficients[I] :=
          PSmallInt(NativeUInt(CoefficientTables[I]) + NativeUInt(ReadBits(CoefficientWidths[I])) * SizeOf(SmallInt))^;
    for var I := Last + 1 to 9 do
      FState.Target.Coefficients[I] := 0;
  end
  else
    FState.Target := Default(TLpcFrame);

  // Start a voiced or unvoiced onset immediately on a change of excitation.
  if (FState.Target.Energy > 0) and ((FState.First.Pitch = 0) <> (FState.Target.Pitch = 0)) then
    FState.First := FState.Target;
  FState.SamplesLeft := SamplesPerFrame;
  Result := True;
end;

procedure TTsp50C04.Interpolate;

  function Between(A, B, Index: Integer): Integer;
  begin
    Result := A + ((B - A) * Index) div SamplesPerFrame;
  end;

begin
  var Index := SamplesPerFrame - FState.SamplesLeft;
  FState.Current.Energy := Between(FState.First.Energy, FState.Target.Energy, Index);
  FState.Current.Pitch := Between(FState.First.Pitch, FState.Target.Pitch, Index);
  for var I := 0 to 9 do
    FState.Current.Coefficients[I] :=
      Between(FState.First.Coefficients[I], FState.Target.Coefficients[I], Index);
end;

procedure TTsp50C04.Synthesize;
begin
  if (FState.SamplesLeft = 0) and not ReadFrame then
  begin
    FState.Sample := 0;
    Exit;
  end;
  Dec(FState.PitchPhase, 16);
  if (FState.PitchPhase < 0) or (FState.SamplesLeft = SamplesPerFrame) then
  begin
    Interpolate;
    if FState.PitchPhase < 0 then
      FState.PitchPhase := FState.PitchPhase + Max(FState.Current.Pitch, 128);
  end;
  var Excitation := 0;
  if FState.Current.Pitch = 0 then
  begin
    var Feedback := ((FState.Noise shr 11) xor (FState.Noise shr 12)) and 1;
    FState.Noise := ((Integer(FState.Noise) shl 1) or Feedback) and $FFFF;
    Excitation := 2816 * Feedback - 1408;
  end
  else if (FState.PitchPhase >= 0) and (FState.PitchPhase < Length(ExcitationTable)) then
    Excitation := ExcitationTable[FState.PitchPhase];
  var Sample := (8 * Excitation * FState.Current.Energy) div Fraction;
  for var I := 9 downto 0 do
  begin
    var K := FState.Current.Coefficients[I];
    Sample := EnsureRange(Sample - (K * FState.Delay[I]) div Fraction, -32768, 32767);
    if I < 9 then
      FState.Delay[I + 1] := EnsureRange(FState.Delay[I] + (K * Sample) div Fraction, -32768, 32767);
  end;
  FState.Delay[0] := Sample;
  FState.Sample := Sample;
  Dec(FState.SamplesLeft);
end;

procedure TTsp50C04.Clock;
begin
  if FState.Active then
  begin
    Inc(FState.CpuPhase, SampleRate);
    if FState.CpuPhase >= FCpuFrequency then
    begin
      Dec(FState.CpuPhase, FCpuFrequency);
      Synthesize;
    end;
  end;
end;

function TTsp50C04.Output: Double;
begin
  Result := FState.Sample * (1.0 / 131072.0);
end;

procedure TTsp50C04.SerializeState(State: TStateArchive);
begin
  State.Field(FState, SizeOf(FState));
  if State.Loading and ((Cardinal(FState.ReadBit) >= FifoBits) or
    (Cardinal(FState.BitCount) > FifoBits) or ((FState.ReadBit + FState.BitCount) and 7 <> 0) or
    (Cardinal(FState.CpuPhase) >= Cardinal(FCpuFrequency)) or
    (Cardinal(FState.SamplesLeft) > SamplesPerFrame) or
    (Cardinal(FState.PitchPhase) > 8192)) then
    raise EReadError.Create('Invalid TSP50C04 device state');
  if State.Loading then
  begin
    for var I := 0 to 9 do
      if (Abs(Int64(FState.First.Coefficients[I])) > 32768) or
        (Abs(Int64(FState.Target.Coefficients[I])) > 32768) or
        (Abs(Int64(FState.Current.Coefficients[I])) > 32768) or (Abs(Int64(FState.Delay[I])) > 32768) then
        raise EReadError.Create('Invalid TSP50C04 filter state');
    if (Cardinal(FState.First.Pitch) > 8192) or (Cardinal(FState.Target.Pitch) > 8192) or
      (Cardinal(FState.Current.Pitch) > 8192) or (Cardinal(FState.First.Energy) > 32768) or
      (Cardinal(FState.Target.Energy) > 32768) or (Cardinal(FState.Current.Energy) > 32768) then
      raise EReadError.Create('Invalid TSP50C04 frame parameters');
  end;
end;

end.

