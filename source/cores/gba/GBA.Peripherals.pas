unit GBA.Peripherals;

// Cartridge GPIO, S-3511A RTC and the documented Boktai/Yoshi/Wario sensors.
// Hardware protocol: https://mgba-emu.github.io/gbatek/#gbacartioportgpio

{$IF Defined(ANDROID) and Defined(CPUARM64) and not Defined(RETROMUL_GBA_NO_NATIVE_QUIET)}
{$DEFINE RETROMUL_GBA_NATIVE_QUIET}
{$ENDIF}

interface

uses
  System.SysUtils, System.Classes, System.Math, System.DateUtils, Core.Snapshots;

type
  TGBAHardware = class
  private
    FRTC, FTilt, FSolar, FGyro, FRumble: Boolean;
    FData, FDirection, FEnable, FStatus, FPrevious, FCommand: Byte;
    FBits, FLength, FOutBits, FOutputBit, FSolarCount, FLight, FGyroBit: Integer;
    FInput, FOutput: UInt64;
    FDate: TDateTime;
    FClocks: Integer;
    FX, FY, FSampleX, FSampleY, FRotation, FSampleRotation: Integer;
    FLatched: Boolean;
    FMotorClocks, FMotorLevelClocks: UInt64;
    FIRQPending: Boolean;
    procedure AdvanceRTC(Cycles: Integer);
    procedure RTCCommand;
    procedure RTCWriteData;
    function RTCDate(IncludeDate: Boolean): UInt64;
    procedure WritePins(Value: Byte);
  public
    {$IFDEF RETROMUL_GBA_NATIVE_QUIET}
    function NativeQuietIRQOffset: Integer;
    {$ENDIF}
    constructor Create(const Code: AnsiString; HasRTC: Boolean);
    procedure Reset;
    procedure Tick(Cycles: Integer); inline;
    function ReadGPIO(Address: Cardinal; out Value: Byte): Boolean;
    procedure WriteGPIO(Address: Cardinal; Value: Byte);
    function ReadTilt(Address: Cardinal; out Value: Byte): Boolean;
    function WriteTilt(Address: Cardinal; Value: Byte): Boolean;
    procedure SetMotion(X, Y, Rotation: Double);
    procedure SetSolar(Level: Integer);
    function TakeIRQ: Boolean; inline;
    function RumbleLevel: Byte; inline;
    function TakeRumbleLevel: Byte;
    function RTCBattery: TBytes;
    procedure LoadRTCBattery(const Data: TBytes);
    procedure SerializeState(State: TStateArchive);
    property HasRTC: Boolean read FRTC;
    property IRQPending: Boolean read FIRQPending;
    property HasTilt: Boolean read FTilt;
    property HasGyro: Boolean read FGyro;
    property HasSolar: Boolean read FSolar;
    property HasRumble: Boolean read FRumble;
  end;

implementation
{$IFDEF RETROMUL_GBA_NATIVE_QUIET}
function TGBAHardware.NativeQuietIRQOffset: Integer;
begin
  Result := Integer(NativeUInt(@FIRQPending)-NativeUInt(Self));
end;
{$ENDIF}

function BCD(Value: Integer): Byte;
begin
  Result := Byte((Value div 10) * 16 + Value mod 10);
end;

function Decimal(Value: Byte): Integer;
begin
  Result := (Value shr 4) * 10 + (Value and 15);
end;

constructor TGBAHardware.Create(const Code: AnsiString; HasRTC: Boolean);
begin
  inherited Create;
  FSolar := (Copy(Code, 1, 3) = 'U3I') or (Copy(Code, 1, 3) = 'U32') or (Copy(Code, 1, 3) = 'U33');
  FTilt := (Copy(Code, 1, 3) = 'KYG') or (Code = 'KHPJ');
  FGyro := Copy(Code, 1, 3) = 'RZW';
  FRumble := FGyro or (Copy(Code, 1, 3) = 'V49');
  FRTC := HasRTC or FSolar;
  FDate := Now;
  FStatus := $40;
  FLight := 128;
  FX := $392;
  FY := $3A0;
  FRotation := $6C0;
  Reset;
end;

procedure TGBAHardware.Reset;
begin
  FData := 0;
  FDirection := 0;
  FEnable := 0;
  FPrevious := 0;
  FCommand := 0;
  FBits := 0;
  FLength := 0;
  FOutBits := 0;
  FOutputBit := 1;
  FInput := 0;
  FOutput := 0;
  FIRQPending := False;
  FSolarCount := 0;
  FGyroBit := 0;
  FLatched := False;
  FSampleX := $392;
  FSampleY := $3A0;
  FLatched := True;
end;

procedure TGBAHardware.Tick(Cycles: Integer);
begin
  Inc(FMotorClocks, Cycles);
  if FRumble then
    Inc(FMotorLevelClocks, UInt64(RumbleLevel) * UInt64(Cycles));
  if FRTC then
    AdvanceRTC(Cycles);
end;

procedure TGBAHardware.AdvanceRTC(Cycles: Integer);
begin
  Inc(FClocks, Cycles);
  while FClocks >= 16777216 do
  begin
    Dec(FClocks, 16777216);
    FDate := IncSecond(FDate);
    if (FStatus and 8 <> 0) and (SecondOf(FDate) mod 30 = 0) then
      FIRQPending := True;
  end;
end;

function TGBAHardware.RTCDate(IncludeDate: Boolean): UInt64;
begin
  var Y, M, D, H, N, S, MS: Word;
  DecodeDate(FDate, Y, M, D);
  DecodeTime(FDate, H, N, S, MS);
  var Hour := BCD(H);
  if FStatus and $40 = 0 then
    Hour := BCD(H mod 12);
  if (FStatus and $40 = 0) and (H >= 12) then
    Hour := Hour or $80;
  Result := UInt64(Hour) or (UInt64(BCD(N)) shl 8) or (UInt64(BCD(S)) shl 16);
  if IncludeDate then
    Result := (Result shl 32) or UInt64(BCD(Y mod 100)) or
      (UInt64(BCD(M)) shl 8) or (UInt64(BCD(D)) shl 16) or (UInt64(DayOfWeek(FDate) - 1) shl 24);
end;

procedure TGBAHardware.RTCCommand;
begin
  if FCommand and $F0 <> $60 then
  begin
    var Reverse: Byte := 0;
    for var I := 0 to 7 do
      Reverse := Byte((Reverse shl 1) or ((FCommand shr I) and 1));
    FCommand := Reverse;
  end;
  FLength := 0;
  FInput := 0;
  FBits := 0;
  if FCommand and $F0 <> $60 then
  begin
    FCommand := 0;
    Exit;
  end;

  case (FCommand shr 1) and 7 of
    0:
      begin
        FStatus := 0;
        FDate := EncodeDate(2000, 1, 1);
      end;
    1:
      begin
        FLength := 8;
        FOutput := FStatus;
        if FCommand and 1 <> 0 then
          FStatus := FStatus and $7F;
      end;
    2:
      begin
        FLength := 56;
        FOutput := RTCDate(True);
      end;
    3:
      begin
        FLength := 24;
        FOutput := RTCDate(False);
      end;
    4:
      FIRQPending := True;
    5, 6, 7:
      begin
        FLength := 8;
        FOutput := $FF;
      end;
  end;
  if FCommand and 1 <> 0 then
    FOutBits := FLength;
end;

procedure TGBAHardware.RTCWriteData;
begin
  if (FCommand shr 1) and 7 = 1 then
  begin
    FStatus := Byte(FInput and $6A);
    Exit;
  end;

  if not (((FCommand shr 1) and 7) in [2, 3]) then
    Exit;

  var Y, M, D, H, N, S, MS: Word;
  DecodeDate(FDate, Y, M, D);
  DecodeTime(FDate, H, N, S, MS);

  var V := FInput;
  if (FCommand shr 1) and 7 = 2 then
  begin
    Y := Word(2000 + Decimal(Byte(V and 255)));
    M := Word(EnsureRange(Decimal(Byte((V shr 8) and 255)), 1, 12));
    D := Word(EnsureRange(Decimal(Byte((V shr 16) and 255)), 1, 31));
    V := V shr 32;
  end;

  H := Word(EnsureRange(Decimal(Byte(V and $3F)), 0, 23));
  if FStatus and $40 = 0 then
    H := Word(H mod 12 + 12 * Ord(V and $80 <> 0));

  N := Word(EnsureRange(Decimal(Byte((V shr 8) and $7F)), 0, 59));
  S := Word(EnsureRange(Decimal(Byte((V shr 16) and $7F)), 0, 59));

  var DatePart: TDateTime;
  while not TryEncodeDate(Y, M, D, DatePart) do
    Dec(D);

  FDate := DatePart + EncodeTime(H, N, S, 0);
  FClocks := 0;
end;

procedure TGBAHardware.WritePins(Value: Byte);
begin
  Value := Value and FDirection;
  var NewSession := (FPrevious and 4 = 0) and (Value and 4 <> 0);
  if FRTC then
  begin
    if (FPrevious and 4 = 0) and (Value and 4 <> 0) then
    begin
      FBits := 0;
      FCommand := 0;
      FLength := 0;
      FOutBits := 0;
      FInput := 0;
      FOutputBit := 1;
    end;

    if Value and 4 <> 0 then
    begin
      if (FPrevious and 1 = 0) and (Value and 1 <> 0) and not NewSession and (FDirection and 2 <> 0) then
      begin
        if FLength = 0 then
        begin
          FCommand := Byte(((Integer(FCommand) shl 1) or ((FPrevious shr 1) and 1)) and 255);
          Inc(FBits);
          if FBits = 8 then
            RTCCommand;
        end
        else if (FCommand and 1 = 0) and (FBits < FLength) then
        begin
          FInput := FInput or (UInt64((FPrevious shr 1) and 1) shl FBits);
          Inc(FBits);
          if FBits = FLength then
            RTCWriteData;
        end;
      end;
      if (FPrevious and 1 <> 0) and (Value and 1 = 0) and (FDirection and 2 = 0) then
      begin
        FOutputBit := 1;
        if FOutBits > 0 then
        begin
          FOutputBit := Integer(FOutput and 1);
          FOutput := FOutput shr 1;
          Dec(FOutBits);
        end;
      end;
    end;
  end;

  if FSolar then
    if Value and 2 <> 0 then
      FSolarCount := 0
    else if (FPrevious and 1 = 0) and (Value and 1 <> 0) then
      FSolarCount := (FSolarCount + 1) and $FFF;

  if FGyro then
  begin
    if (FPrevious and 1 = 0) and (Value and 1 <> 0) then
    begin
      FSampleRotation := FRotation;
      FGyroBit := 15;
    end
    else if (FPrevious and 2 <> 0) and (Value and 2 = 0) then
      Dec(FGyroBit);
  end;

  FPrevious := Value;
  FData := Value;
end;

function TGBAHardware.ReadGPIO(Address: Cardinal; out Value: Byte): Boolean;
begin
  Result := (FRTC or FSolar or FGyro or FRumble) and (Address >= $080000C4) and (Address <= $080000C9) and (FEnable <> 0);
  Value := 0;
  if not Result then
    Exit;

  case Address of
    $080000C4:
      begin
        var Inputs := 0;
        if FRTC then
          Inputs := FOutputBit shl 1;
        if FSolar and (FSolarCount >= ($E8 - FLight * $E8 div 255)) then
          Inputs := Inputs or 8;
        if FGyro and (FGyroBit >= 0) and (FGyroBit < 12) then
          Inputs := Inputs or (((FSampleRotation shr FGyroBit) and 1) shl 2);
        Value := Byte((FData and FDirection) or (Inputs and not FDirection));
      end;
    $080000C6:
      Value := FDirection;
    $080000C8:
      Value := FEnable;
  end;
end;

procedure TGBAHardware.WriteGPIO(Address: Cardinal; Value: Byte);
begin
  if not (FRTC or FSolar or FGyro or FRumble) then
    Exit;

  case Address of
    $080000C4:
      WritePins(Value);
    $080000C6:
      begin
        FDirection := Value and 15;
        FData := FData and FDirection;
      end;
    $080000C8:
      FEnable := Value and 1;
  end;
end;

function TGBAHardware.ReadTilt(Address: Cardinal; out Value: Byte): Boolean;
begin
  Result := FTilt and (Address and $FF8000 = $008000);
  Value := 0;
  if not Result then
    Exit;

  case Address and $F00 of
    $200:
      Value := Byte(FSampleX and 255);
    $300:
      Value := Byte((FSampleX shr 8) and 15) or (Byte(Ord(FLatched)) * $80);
    $400:
      Value := Byte(FSampleY and 255);
    $500:
      Value := Byte((FSampleY shr 8) and 15);
  end;
end;

function TGBAHardware.WriteTilt(Address: Cardinal; Value: Byte): Boolean;
begin
  Result := FTilt and (Address and $FF8000 = $008000);
  if not Result then
    Exit;

  case Address and $F00 of
    0:
      if Value = $55 then
        FLatched := False;
    $100:
      if (Value = $AA) and not FLatched then
      begin
        FSampleX := FX;
        FSampleY := FY;
        FLatched := True;
      end;
  end;
end;

procedure TGBAHardware.SetMotion(X, Y, Rotation: Double);
begin
  if IsNan(X) or IsInfinite(X) then
    X := 0;
  if IsNan(Y) or IsInfinite(Y) then
    Y := 0;
  if IsNan(Rotation) or IsInfinite(Rotation) then
    Rotation := 0;

  FX := EnsureRange($392 - Round(EnsureRange(X, -2.0, 2.0) * 230), 0, 4095);
  FY := EnsureRange($3A0 + Round(EnsureRange(Y, -2.0, 2.0) * 230), 0, 4095);
  FRotation := EnsureRange($6C0 + Round(EnsureRange(Rotation, -2.0, 2.0) * 250), 0, 4095);
end;

procedure TGBAHardware.SetSolar(Level: Integer);
begin
  FLight := EnsureRange(Level, 0, 255);
end;

function TGBAHardware.TakeIRQ: Boolean;
begin
  Result := FIRQPending;
  FIRQPending := False;
end;

function TGBAHardware.RumbleLevel: Byte;
begin
  Result := 0;
  if FRumble and (FDirection and FData and 8 <> 0) then
    Result := 255;
end;

function TGBAHardware.TakeRumbleLevel: Byte;
begin
  Result := RumbleLevel;
  if FMotorClocks > 0 then
    Result := Byte((FMotorLevelClocks + FMotorClocks div 2) div FMotorClocks);
  FMotorClocks := 0;
  FMotorLevelClocks := 0;
end;

function TGBAHardware.RTCBattery: TBytes;
begin
  Result := nil;
  if not FRTC then
    Exit;

  SetLength(Result, 17);
  Move(FDate, Result[0], 8);

  // Explicit Double storage: Win32 can infer an Extended temporary for Now.
  var Host: TDateTime;
  Host := Now;
  Move(Host, Result[8], 8);
  Result[16] := FStatus;
end;

procedure TGBAHardware.LoadRTCBattery(const Data: TBytes);
begin
  if not FRTC then
    Exit;

  if not (Length(Data) in [16, 17]) then
    raise EReadError.Create('Invalid GBA RTC battery size');

  var Date, Host: TDateTime;
  Move(Data[0], Date, 8);
  Move(Data[8], Host, 8);
  if IsNan(Date) or IsInfinite(Date) or IsNan(Host) or IsInfinite(Host) or
    (Date < EncodeDate(1900, 1, 1)) or (Date > EncodeDate(2100, 1, 1)) or
    (Host < EncodeDate(1900, 1, 1)) or (Host > EncodeDate(2200, 1, 1)) then
    raise EReadError.CreateFmt('Invalid GBA RTC battery (%g, %g)', [Date, Host]);

  FDate := Min(EncodeDate(2100, 1, 1), Date + Max(0.0, Now - Host));
  FClocks := 0;
  if Length(Data) = 17 then
    FStatus := Data[16] and $6A;
end;

procedure TGBAHardware.SerializeState(State: TStateArchive);
begin
  State.Field(FData, SizeOf(FData));
  State.Field(FDirection, SizeOf(FDirection));
  State.Field(FEnable, SizeOf(FEnable));
  State.Field(FStatus, SizeOf(FStatus));
  State.Field(FPrevious, SizeOf(FPrevious));
  State.Field(FCommand, SizeOf(FCommand));
  State.Field(FBits, SizeOf(FBits));
  State.Field(FLength, SizeOf(FLength));
  State.Field(FOutBits, SizeOf(FOutBits));
  State.Field(FOutputBit, SizeOf(FOutputBit));
  State.Field(FInput, SizeOf(FInput));
  State.Field(FOutput, SizeOf(FOutput));
  State.Field(FDate, SizeOf(FDate));
  State.Field(FClocks, SizeOf(FClocks));
  State.Field(FSolarCount, SizeOf(FSolarCount));
  State.Field(FLight, SizeOf(FLight));
  State.Field(FGyroBit, SizeOf(FGyroBit));
  State.Field(FSampleX, SizeOf(FSampleX));
  State.Field(FSampleY, SizeOf(FSampleY));
  State.Field(FSampleRotation, SizeOf(FSampleRotation));
  State.Field(FLatched, SizeOf(FLatched));
  State.Field(FIRQPending, SizeOf(FIRQPending));

  if State.Loading then
    if (FDirection > 15) or (FEnable > 1) or (FBits < 0) or (FBits > 56) or (FOutBits < 0) or (FOutBits > 56) or
      (FClocks < 0) or (FClocks >= 16777216) or IsNan(FDate) or IsInfinite(FDate) then
      raise EReadError.Create('Invalid GBA GPIO state');
end;

end.

