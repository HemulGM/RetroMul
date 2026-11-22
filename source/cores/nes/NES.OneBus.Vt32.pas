unit NES.OneBus.Vt32;

interface

uses
  NES.State, NES.Types;

type
  TVt32 = record
  private
    type
      TSampleChannel = record
        StartAddress, Position: Cardinal;
        Timer, Sample, StepIndex: Integer;
        Volume: Byte;
        Playing, Adpcm, LowNibble: Boolean;
        procedure Start(Address: Cardinal; Compressed: Boolean);
        procedure Stop;
        procedure Clock(const Rom: TByteArray; Period: Integer);
      end;
  private
    FChannels: array[0..1] of TSampleChannel;
    FControl, FSelected, FDmcRate, FAdpcmPeriod: Byte;
    FEncrypted, FEncryptionPending, FNextEncryption: Boolean;
    FOperand: Cardinal;
    FMultiplier, FDivisor: Word;
    FBusy: Byte;
    function SetAddressBits(Value: Byte; Shift: Integer; Mask: Cardinal): Boolean;
  public
    procedure Reset;
    procedure SerializeState(State: TNesStateArchive);
    function ReadRegister(Address: Word; out Value: Byte): Boolean;
    function WriteRegister(Address: Word; Value: Byte; SampleOuterBank: Cardinal): Boolean;
    function DecodeOpcode(Value: Byte): Byte;
    procedure CommitOpcodeMode;
    procedure Clock(const Rom: TByteArray; Region: TNesRegion);
    function Audio: Double;
  end;

implementation

uses
  NES.APU;

const
  ImaStep: array[0..88] of Word = (
    7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31,
    34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143,
    157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544,
    598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878,
    2066, 2272, 2499, 2749, 3024, 3327, 3660, 4028, 4428, 4871, 5358, 5894,
    6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899, 15289, 16818,
    18500, 20350, 22385, 24623, 27086, 29794, 32767);
  ImaDelta: array[0..7] of ShortInt = (-1, -1, -1, -1, 1, 2, 4, 6);

procedure TVt32.TSampleChannel.Start(Address: Cardinal; Compressed: Boolean);
begin
  Position := Address;
  Timer := 0;
  Sample := 0;
  StepIndex := 0;
  LowNibble := False;
  Adpcm := Compressed;
  Playing := True;
end;

procedure TVt32.TSampleChannel.Stop;
begin
  Playing := False;
  Sample := 0;
end;

procedure TVt32.TSampleChannel.Clock(const Rom: TByteArray; Period: Integer);
begin
  if not Playing then
    Exit;
  if Timer > 0 then
  begin
    Dec(Timer);
    Exit;
  end;
  Timer := Period - 1;
  var Index := Position mod Cardinal(Length(Rom));
  var Code := Rom[Index];
  if not Adpcm then
  begin
    if Code = $FF then
      Stop
    else
    begin
      Sample := (Integer(Code) - $80) * 16;
      Position := (Position + 1) and $1FFFFFFF;
    end;
    Exit;
  end;
  if not LowNibble and (Code = 0) and (Rom[(Index + 1) mod Cardinal(Length(Rom))] = $FF) then
  begin
    Stop;
    Exit;
  end;
  if LowNibble then
  begin
    Code := Code and 15;
    Position := (Position + 1) and $1FFFFFFF;
  end
  else
    Code := Code shr 4;
  LowNibble := not LowNibble;

  var Step := ImaStep[StepIndex];
  var Delta := Step shr 3;
  if (Code and 1) <> 0 then
    Inc(Delta, Step shr 2);
  if (Code and 2) <> 0 then
    Inc(Delta, Step shr 1);
  if (Code and 4) <> 0 then
    Inc(Delta, Step);
  if (Code and 8) <> 0 then
    Dec(Sample, Delta)
  else
    Inc(Sample, Delta);
  if Sample < -2048 then
    Sample := -2048
  else if Sample > 2047 then
    Sample := 2047;
  Inc(StepIndex, ImaDelta[Code and 7]);
  if StepIndex < 0 then
    StepIndex := 0
  else if StepIndex > High(ImaStep) then
    StepIndex := High(ImaStep);
end;

procedure TVt32.Reset;
begin
  Self := Default(TVt32);
  for var Index := 0 to High(FChannels) do
    FChannels[Index].Volume := $80;
  FAdpcmPeriod := $6F;
end;

procedure TVt32.SerializeState(State: TNesStateArchive);
begin
  State.Field(FChannels, SizeOf(FChannels));
  State.Field(FControl, SizeOf(FControl));
  State.Field(FSelected, SizeOf(FSelected));
  State.Field(FDmcRate, SizeOf(FDmcRate));
  State.Field(FAdpcmPeriod, SizeOf(FAdpcmPeriod));
  State.Field(FEncrypted, SizeOf(FEncrypted));
  State.Field(FEncryptionPending, SizeOf(FEncryptionPending));
  State.Field(FNextEncryption, SizeOf(FNextEncryption));
  State.Field(FOperand, SizeOf(FOperand));
  State.Field(FMultiplier, SizeOf(FMultiplier));
  State.Field(FDivisor, SizeOf(FDivisor));
  State.Field(FBusy, SizeOf(FBusy));
  if State.Loading then
  begin
    if (FSelected > High(FChannels)) or (FDmcRate > 15) or (FAdpcmPeriod = 0) then
      raise ENesException.Create('Invalid VT32 register state');
    for var Channel in FChannels do
      if (Channel.StepIndex < 0) or (Channel.StepIndex > High(ImaStep)) or
        (Channel.Sample < -2048) or (Channel.Sample > 2047) or
        (Channel.Timer < 0) then
        raise ENesException.Create('Invalid VT32 sample state');
  end;
end;

function TVt32.ReadRegister(Address: Word; out Value: Byte): Boolean;
begin
  case Address of
    $4014:
      Value := Ord(FChannels[0].Playing) or (Ord(FChannels[1].Playing) shl 1);
    $4119:
      Value := 0;
    $4130..$4133, $4138..$413B:
      Value := Byte(FOperand shr ((Address and 3) * 8));
    $4134, $413C:
      Value := Byte(FMultiplier);
    $4135, $413D:
      Value := FMultiplier shr 8;
    $4136:
      Value := FBusy;
  else
    Exit(False);
  end;
  Result := True;
end;

function TVt32.SetAddressBits(Value: Byte; Shift: Integer; Mask: Cardinal): Boolean;
begin
  Result := (FControl and $C0) <> 0;
  if Result and not FChannels[FSelected].Playing then
    FChannels[FSelected].StartAddress := (FChannels[FSelected].StartAddress and not (Mask shl Shift)) or
      ((Cardinal(Value) and Mask) shl Shift);
end;

function TVt32.WriteRegister(Address: Word; Value: Byte; SampleOuterBank: Cardinal): Boolean;
begin
  case Address of
    $4010:
      begin
        FDmcRate := Value and 15;
        Exit(False);
      end;
    $4012:
      Exit(SetAddressBits(Value, 6, $FF));
    $4031, $4032:
      begin
        FSelected := Address - $4031;
        FChannels[FSelected].Volume := Value;
        if (Address = $4032) and (Value <> 0) then
          FAdpcmPeriod := Value;
      end;
    $4033:
      begin
        FControl := Value;
        for var Index := 0 to High(FChannels) do
          if (Value and $C0) = 0 then
            FChannels[Index].Stop
          else if (Value and ($10 shr Index)) <> 0 then
          begin
            if not FChannels[Index].Playing then
              FChannels[Index].Start(FChannels[Index].StartAddress or SampleOuterBank, (Value and $40) <> 0);
          end
          else if (Value and $80) <> 0 then
            FChannels[Index].Stop;
      end;
    $4035:
      SetAddressBits(Value, 14, $7F);
    $4036:
      SetAddressBits(Value, 21, $FF);
    $4037, $4038:
      FChannels[Address - $4037].Stop;
    $4039:
      for var Index := 0 to High(FChannels) do
        if (Value and ($10 shr Index)) <> 0 then
          FChannels[Index].Stop;
    $411E:
      if (Value and 5) in [0, 5] then
      begin
        FEncryptionPending := True;
        FNextEncryption := (Value and 5) = 5;
      end;
    $4130..$4133:
      begin
        var Shift := (Address and 3) * 8;
        FOperand := (FOperand and not (Cardinal($FF) shl Shift)) or (Cardinal(Value) shl Shift);
      end;
    $4134:
      FMultiplier := (FMultiplier and $FF00) or Value;
    $4135:
      begin
        FMultiplier := (FMultiplier and $FF) or (Word(Value) shl 8);
        FOperand := (FOperand and $FFFF) * Cardinal(FMultiplier);
        FBusy := 16;
      end;
    $4136:
      FDivisor := (FDivisor and $FF00) or Value;
    $4137:
      begin
        FDivisor := (FDivisor and $FF) or (Word(Value) shl 8);
        if FDivisor <> 0 then
        begin
          FMultiplier := FOperand mod FDivisor;
          FOperand := FOperand div FDivisor;
          FBusy := 32;
        end;
      end;
  else
    Exit(False);
  end;
  Result := True;
end;

function TVt32.DecodeOpcode(Value: Byte): Byte;
begin
  Result := Value;
  if FEncrypted then
    Result := Value xor $A1;
end;

procedure TVt32.CommitOpcodeMode;
begin
  if FEncryptionPending then
  begin
    FEncrypted := FNextEncryption;
    FEncryptionPending := False;
  end;
end;

procedure TVt32.Clock(const Rom: TByteArray; Region: TNesRegion);
begin
  if FBusy <> 0 then
    Dec(FBusy);
  for var Index := 0 to High(FChannels) do
    if FChannels[Index].Playing then
    begin
      var Period := DmcTimerPeriod(Region, FDmcRate);
      if FChannels[Index].Adpcm then
        Period := FAdpcmPeriod;
      FChannels[Index].Clock(Rom, Period);
    end;
end;

function TVt32.Audio: Double;
begin
  Result := (FChannels[0].Sample * FChannels[0].Volume +
    FChannels[1].Sample * FChannels[1].Volume) / 524288.0;
end;

end.

