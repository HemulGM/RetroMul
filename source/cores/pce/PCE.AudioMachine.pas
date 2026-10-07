unit PCE.AudioMachine;

interface

uses
  System.SysUtils, PCE.CPU, PCE.Sound.HuC6280;

type
  THESAudio = class
  private
    FData, FROM: TBytes;
    FRAM: array[0..32767] of Byte;
    FCPU: THuC6280;
    FPSG: THuC6280PSG;
    FDebt: Double;
    FTimerLoad, FTimerCounter, FVBlank, FIRQMask, FVDCLatch, FVDCControl: Integer;
    FTimerEnabled, FTimerPending, FVDCPending: Boolean;
    function Read(Address: Word): Byte;
    procedure Write(Address: Word; Value: Byte);
    procedure WriteIO(Address: Word; Value: Byte);
    procedure Advance(Cycles: Integer);
  public
    constructor Create(const Data: TBytes);
    destructor Destroy; override;
    procedure Reset(Track: Integer);
    procedure Sample(out Left, Right: SmallInt);
    function DefaultTrack: Integer;
  end;

implementation

uses
  System.Math;

constructor THESAudio.Create(const Data: TBytes);

  function DWord(P: Integer): UInt64;
  begin
    Result := UInt64(Data[P]) + UInt64(Data[P + 1]) * 256 + UInt64(Data[P + 2]) * 65536 + UInt64(Data[P + 3]) * 16777216;
  end;

begin
  inherited Create;
  FData := Copy(Data);
  if (Length(Data) < 32) or (TEncoding.ASCII.GetString(Data, 0, 4) <> 'HESM') or (Data[4] <> 0) then
    raise EArgumentException.Create('Invalid HES header');
  SetLength(FROM, $200000);
  for var I := 0 to High(FROM) do
    FROM[I] := $FF;
  for var I := $F8 * 8192 to $FC * 8192 - 1 do
    FROM[I] := 0;
  var Pos := 16;
  while Pos < Length(Data) do
  begin
    if (Length(Data) - Pos < 16) or (TEncoding.ASCII.GetString(Data, Pos, 4) <> 'DATA') then
      raise EArgumentException.Create('Invalid HES DATA block');
    var Size := DWord(Pos + 4);
    var Address := DWord(Pos + 8);
    if (Size > UInt64(Length(Data) - Pos - 16)) or (Address > UInt64(Length(FROM))) or (Size > UInt64(Length(FROM)) - Address) then
      raise EArgumentException.Create('Truncated HES DATA');
    for var I := 0 to Integer(Size) - 1 do
      FROM[Integer(Address) + I] := Data[Pos + 16 + I];
    Inc(Pos, 16 + Integer(Size));
  end;
  FPSG := THuC6280PSG.Create;
  FCPU := THuC6280.Create(Read, Write, WriteIO);
  Reset(DefaultTrack);
end;

destructor THESAudio.Destroy;
begin
  FCPU.Free;
  FPSG.Free;
  inherited;
end;

function THESAudio.DefaultTrack: Integer;
begin
  Result := FData[5];
end;

procedure THESAudio.Reset(Track: Integer);
begin
  if (Track < 0) or (Track > 255) then
    raise EArgumentOutOfRangeException.Create('HES track');
  for var I := 0 to High(FRAM) do
    FRAM[I] := FROM[$F8 * 8192 + I];
  FPSG.Reset;
  FCPU.Reset(Integer(FData[6]) + Integer(FData[7]) * 256, Track);
  for var I := 0 to 7 do
    FCPU.MPR[I] := FData[8 + I];
  FRAM[$1FE] := $FE;
  FRAM[$1FF] := $1F;
  FDebt := 0;
  FTimerLoad := 128 * 1024 + 1;
  FTimerCounter := FTimerLoad;
  FTimerEnabled := False;
  FTimerPending := False;
  FVDCPending := False;
  FVBlank := 262 * 455;
  FIRQMask := 6;
  FVDCLatch := 0;
  FVDCControl := 0;
end;

function THESAudio.Read(Address: Word): Byte;
begin
  var Bank := FCPU.MPR[Address shr 13];
  var Offset := Address and $1FFF;
  if Bank in [$F8..$FB] then
    Exit(FRAM[(Bank - $F8) * 8192 + Offset]);
  if Bank <> $FF then
    Exit(FROM[Integer(Bank) * 8192 + Offset]);
  case Offset of
    0:
      begin
        Result := Ord(FVDCPending) * $20;
        FVDCPending := False;
      end;
    2, 3:
      Result := 0;
    $C00, $C01:
      Result := Max(0, (FTimerCounter - 1) div 1024) and 127;
    $1402:
      Result := FIRQMask;
    $1403:
      Result := Ord(FTimerPending) * 4 + Ord(FVDCPending) * 2;
  else
    Result := $FF;
  end;
end;

procedure THESAudio.Write(Address: Word; Value: Byte);
begin
  var Bank := FCPU.MPR[Address shr 13];
  var Offset := Address and $1FFF;
  if Bank in [$F8..$FB] then
  begin
    FRAM[(Bank - $F8) * 8192 + Offset] := Value;
    Exit;
  end;
  if Bank <> $FF then
    Exit;
  WriteIO(Offset, Value);
end;

procedure THESAudio.WriteIO(Address: Word; Value: Byte);
begin
  var Offset := Address and $1FFF;
  if (Offset >= $800) and (Offset <= $809) then
  begin
    FPSG.WriteRegister(Offset - $800, Value);
    Exit;
  end;
  case Offset of
    0:
      FVDCLatch := Value and 31;
    2:
      if FVDCLatch = 5 then
        FVDCControl := Value;
    $C00:
      begin
        FTimerLoad := ((Value and 127) + 1) * 1024 + 1;
        FTimerCounter := FTimerLoad;
      end;
    $C01:
      begin
        if not FTimerEnabled and (Value and 1 <> 0) then
          FTimerCounter := FTimerLoad;
        FTimerEnabled := Value and 1 <> 0;
      end;
    $1402:
      FIRQMask := Value;
    $1403:
      begin
        FTimerPending := False;
        if FTimerEnabled then
          FTimerCounter := FTimerLoad;
      end;
  end;
end;

procedure THESAudio.Advance(Cycles: Integer);
begin
  Dec(FVBlank, Cycles);
  while FVBlank <= 0 do
  begin
    Inc(FVBlank, 262 * 455);
    if FVDCControl and 8 <> 0 then
      FVDCPending := True;
  end;
  if FTimerEnabled then
  begin
    Dec(FTimerCounter, Cycles);
    while FTimerCounter <= 0 do
    begin
      Inc(FTimerCounter, FTimerLoad);
      FTimerPending := True;
    end;
  end;
end;

procedure THESAudio.Sample(out Left, Right: SmallInt);
begin
  FDebt := FDebt + 7159090.0 / 44100;
  while FDebt > 0 do
  begin
    var C := 0;
    if FTimerPending and (FIRQMask and 4 = 0) then
      C := FCPU.Interrupt($FFFA)
    else if FVDCPending and (FIRQMask and 2 = 0) then
      C := FCPU.Interrupt($FFF8);
    if C = 0 then
      if FCPU.PC = $1FFF then
        C := 4
      else
        C := FCPU.Step;
    if FCPU.LowSpeed then
      C := C * 4;
    Advance(C);
    FDebt := FDebt - C;
  end;
  FPSG.Sample(Left, Right);
end;

end.

