unit NES.OneBus.Vt369Audio;

interface

uses
  NES.CPU, NES.State, NES.Types, NES.OneBus.Vt369Io;

type
  TVt369Audio = class
  private
    FCpu: TCpu6502;
    FRom: TByteArray;
    FFirmware: TArray<Byte>;
    FRam: array[0..$1FFF] of Byte;
    FRelativeBase: Cardinal;
    FPanelIo: TVt369Io;
    FTimerPeriod: Word;
    FTimerRemaining: Integer;
    FTimerControl: Byte;
    FRunning, FIrqPending: Boolean;
    FAdderAddress, FAdpcmAddress: Word;
    FAdderResult, FAdpcmResult: Integer;
    FDacLatch: array[0..1] of Word;
    FDacValue: array[0..1] of Integer;
    function CpuRead(Address: Word): Byte;
    procedure CpuWrite(Address: Word; Value: Byte);
    function ReadSoundRom(Address: Cardinal): Byte;
    function ReadSignedWord(Address: Integer): Integer;
    procedure DecodeAdpcmPacket;
  public
    constructor Create(const Rom: TByteArray; const Firmware: TArray<Byte>);
    destructor Destroy; override;
    procedure Reset;
    procedure SerializeState(State: TNesStateArchive);
    procedure Control(Value: Byte);
    procedure ConnectPanelIo(PanelIo: TVt369Io);
    procedure Clock(Ticks: Integer);
    function Sample: Double;
    function ReadShared(Address: Word): Byte;
    procedure WriteShared(Address: Word; Value: Byte);
    function ReadFirmware(Address: Word; out Value: Byte): Boolean;
    property RelativeBase: Cardinal read FRelativeBase write FRelativeBase;
    property Cpu: TCpu6502 read FCpu;
  end;

implementation

const
  // Measured magnitudes for the VT369 packet header's four-bit quantizer.
  Steps: array[0..15, 0..15] of ShortInt = (
    (0, 14, 28, 42, 56, 70, 84, 97, -111, -97, -84, -70, -56, -42, -28, -14),
    (0, 13, 26, 39, 52, 65, 78, 91, -104, -91, -78, -65, -52, -39, -26, -13),
    (0, 11, 21, 32, 43, 54, 64, 75, -86, -75, -64, -54, -43, -32, -21, -11),
    (0, 9, 18, 27, 35, 44, 53, 62, -71, -62, -53, -44, -35, -27, -18, -9),
    (0, 7, 13, 20, 27, 34, 40, 47, -54, -47, -40, -34, -27, -20, -13, -7),
    (0, 6, 11, 17, 22, 28, 33, 39, -44, -39, -33, -28, -22, -17, -11, -6),
    (0, 5, 9, 14, 18, 23, 27, 32, -36, -32, -27, -23, -18, -14, -9, -5),
    (0, 4, 8, 11, 15, 19, 23, 26, -30, -26, -23, -19, -15, -11, -8, -4),
    (0, 3, 6, 9, 12, 15, 17, 20, -23, -20, -17, -15, -12, -9, -6, -3),
    (0, 2, 5, 7, 10, 12, 14, 17, -19, -17, -14, -12, -10, -7, -5, -2),
    (0, 2, 4, 6, 8, 10, 12, 14, -16, -14, -12, -10, -8, -6, -4, -2),
    (0, 2, 3, 5, 6, 8, 10, 11, -13, -11, -10, -8, -6, -5, -3, -2),
    (0, 1, 2, 4, 5, 6, 7, 9, -10, -9, -7, -6, -5, -4, -2, -1),
    (0, 1, 2, 3, 4, 5, 6, 7, -8, -7, -6, -5, -4, -3, -2, -1),
    (0, 1, 2, 3, 3, 4, 5, 6, -7, -6, -5, -4, -3, -3, -2, -1),
    (0, 1, 1, 2, 3, 4, 4, 5, -6, -5, -4, -4, -3, -2, -1, -1));

constructor TVt369Audio.Create(const Rom: TByteArray; const Firmware: TArray<Byte>);
begin
  inherited Create;
  FRom := Rom;
  FFirmware := Firmware;
  FCpu := TCpu6502.Create;
  FCpu.Connect(CpuRead, CpuWrite);
  FCpu.SoundDataRead := ReadSoundRom;
  Reset;
end;

destructor TVt369Audio.Destroy;
begin
  FCpu.Free;
  inherited;
end;

procedure TVt369Audio.Reset;
begin
  FillChar(FRam, SizeOf(FRam), 0);
  FillChar(FDacLatch, SizeOf(FDacLatch), 0);
  FillChar(FDacValue, SizeOf(FDacValue), 0);
  FRunning := False;
  FIrqPending := False;
  FTimerPeriod := 0;
  FTimerControl := 0;
  FTimerRemaining := $10000;
  FAdderAddress := 0;
  FAdpcmAddress := 0;
  FAdderResult := 0;
  FAdpcmResult := 0;
  FCpu.Reset;
end;

procedure TVt369Audio.SerializeState(State: TNesStateArchive);
begin
  State.Field(FRam, SizeOf(FRam));
  State.Field(FDacLatch, SizeOf(FDacLatch));
  State.Field(FDacValue, SizeOf(FDacValue));
  State.Field(FRunning, SizeOf(FRunning));
  State.Field(FIrqPending, SizeOf(FIrqPending));
  State.Field(FTimerPeriod, SizeOf(FTimerPeriod));
  State.Field(FTimerControl, SizeOf(FTimerControl));
  State.Field(FTimerRemaining, SizeOf(FTimerRemaining));
  State.Field(FAdderAddress, SizeOf(FAdderAddress));
  State.Field(FAdpcmAddress, SizeOf(FAdpcmAddress));
  State.Field(FAdderResult, SizeOf(FAdderResult));
  State.Field(FAdpcmResult, SizeOf(FAdpcmResult));
  FCpu.SerializeState(State);
end;

procedure TVt369Audio.ConnectPanelIo(PanelIo: TVt369Io);
begin
  FPanelIo := PanelIo;
end;

procedure TVt369Audio.Control(Value: Byte);
begin
  var Enable := Value = $0D;
  if Enable and (not FRunning or (FPanelIo <> nil)) then
  begin
    FIrqPending := False;
    FCpu.Reset;
  end;
  FRunning := Enable;
end;

procedure TVt369Audio.Clock(Ticks: Integer);
begin
  if not FRunning then
    Exit;
  for var Tick := 1 to Ticks do
  begin
    if (FTimerControl and 1) <> 0 then
    begin
      Dec(FTimerRemaining);
      if FTimerRemaining = 0 then
      begin
        FTimerRemaining := $10000 - Integer(FTimerPeriod);
        FIrqPending := (FTimerControl and 2) <> 0;
      end;
    end;
    FCpu.SetIrqLine(FIrqPending);
    FCpu.Clock;
  end;
end;

function TVt369Audio.Sample: Double;
begin
  Result := 0;
  if FRunning then
    Result := (FDacValue[0] + FDacValue[1]) / 65536.0;
end;

function TVt369Audio.ReadShared(Address: Word): Byte;
begin
  Result := FRam[$1800 or (Address and $7FF)];
end;

procedure TVt369Audio.WriteShared(Address: Word; Value: Byte);
begin
  FRam[$1800 or (Address and $7FF)] := Value;
end;

function TVt369Audio.ReadFirmware(Address: Word; out Value: Byte): Boolean;
begin
  Result := Length(FFirmware) = $1000;
  if Result then
    Value := FFirmware[Address and $FFF];
end;

function TVt369Audio.ReadSoundRom(Address: Cardinal): Byte;
begin
  Result := FRom[(FRelativeBase + Address) mod Cardinal(Length(FRom))];
end;

function TVt369Audio.ReadSignedWord(Address: Integer): Integer;
begin
  Result := FRam[Address and $1FFF] or (Word(FRam[(Address + 1) and $1FFF]) shl 8);
  if Result >= $8000 then
    Dec(Result, $10000);
end;

function TVt369Audio.CpuRead(Address: Word): Byte;
begin
  case Address of
    $0000..$1FFF:
      Result := FRam[Address];
    $2114..$2117:
      if (FPanelIo = nil) or not FPanelIo.Read($4148 or (Address and 3), Result) then
        Result := $FF;
    $2210:
      Result := (FAdderResult shr 8) and $FF;
    $2211:
      Result := FAdderResult and $FF;
    $2402:
      Result := (FAdpcmResult shr 8) and $FF;
    $2403:
      Result := FAdpcmResult and $FF;
    $2404:
      Result := 0;
    $4000..$4FFF:
      if not ReadFirmware(Address, Result) then
        Result := $FF;
    $FFFA..$FFFD:
      Result := FRam[Address and $1FFF];
    $FFFE..$FFFF:
      Result := FRam[$1FF8 or (Address and 1)];
  else
    Result := $FF;
  end;
end;

procedure TVt369Audio.CpuWrite(Address: Word; Value: Byte);
begin
  case Address of
    $0000..$1FFF:
      FRam[Address] := Value;
    $2100:
      FTimerPeriod := (FTimerPeriod and $FF00) or Value;
    $2101:
      FTimerPeriod := (FTimerPeriod and $00FF) or (Word(Value) shl 8);
    $2102:
      begin
        if (Value and 1) <> 0 then
          FTimerRemaining := $10000 - Integer(FTimerPeriod);
        FTimerControl := Value;
        if (Value and 2) = 0 then
          FIrqPending := False;
      end;
    $2103:
      FIrqPending := False;
    $2114..$2117:
      if FPanelIo <> nil then
        FPanelIo.Write($4148 or (Address and 3), Value);
    $2205:
      FAdderAddress := (FAdderAddress and $00FF) or (Word(Value) shl 8);
    $2206:
      begin
        FAdderAddress := (FAdderAddress and $FF00) or Value;
        FAdderResult := ReadSignedWord(FAdderAddress) + ReadSignedWord(FAdderAddress + 2) +
          ReadSignedWord(FAdderAddress + 4) + ReadSignedWord(FAdderAddress + 6);
      end;
    $2400:
      FAdpcmAddress := (FAdpcmAddress and $00FF) or (Word(Value) shl 8);
    $2401:
      begin
        FAdpcmAddress := (FAdpcmAddress and $FF00) or Value;
        DecodeAdpcmPacket;
      end;
    $2800..$2803:
      begin
        var Channel := (Address shr 1) and 1;
        if (Address and 1) = 0 then
          FDacLatch[Channel] := Word(Value) shl 8
        else
        begin
          FDacValue[Channel] := FDacLatch[Channel] or Value;
          if FDacValue[Channel] >= $8000 then
            Dec(FDacValue[Channel], $10000);
        end;
      end;
  end;
end;

procedure TVt369Audio.DecodeAdpcmPacket;
begin
  var Base := FAdpcmAddress and $1FFF;
  var Header := FRam[Base];
  var Data := FRam[(Base + 1) and $1FFF];
  var Volume := FRam[(Base + 2) and $1FFF] and $7F;
  var Previous := ShortInt(FRam[(Base + 3) and $1FFF]);
  var Current := ShortInt(FRam[(Base + 4) and $1FFF]);
  var Position := FRam[(Base + 5) and $1FFF] mod 48;

  var Scale := Integer(Header and 15);
  if Position >= 24 then
    Scale := (Scale - Ord((Header and $40) <> 0) + 2 * Ord((Header and $80) <> 0)) and 15;
  var Delta := Integer(Steps[Scale, (Data shr ((Position and 1) * 4)) and 15]);
  case (Header shr 4) and 3 of
    1:
      Inc(Delta, Current);
    2:
      Inc(Delta, 2 * Current - Previous);
    3:
      begin
        // Signed right shift rounds negative half samples downward.
        var Half := Integer(Previous) div 2;
        if (Previous < 0) and Odd(Previous) then
          Dec(Half);
        Inc(Delta, Current - Half);
      end;
  end;
  var Next := Delta and $FF;
  FRam[(Base + 3) and $1FFF] := Byte(Current);
  FRam[(Base + 4) and $1FFF] := Next;
  FRam[(Base + 5) and $1FFF] := Position + 1;
  if Next >= $80 then
    Dec(Next, $100);
  FAdpcmResult := Next * Volume;
end;

end.

