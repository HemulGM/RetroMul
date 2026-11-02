unit WS.Cartridge;

interface

uses
  System.SysUtils, System.Classes, System.DateUtils, Core.Snapshots, WS.EEPROM;

type
  TWSCartridge = class
  private
    FROM, FRAM: TBytes;
    FInitialSRAM: TBytes;
    FEEPROM: TWSEEPROM;
    FBanks: array[0..$15] of Byte;
    FColor, FVertical, FRTC, FDirty: Boolean;
    FRTCData: array[0..15] of Byte;
    FRTCCommand, FRTCIndex, FRTCBuffer: Byte;
    FRTCPendingWrite: Boolean;
    FRTCPhase: Integer;
    FClock: TDateTime;
    function GetRAMOffset(Address: Cardinal): Cardinal;
    procedure RTCCommand(Value: Byte);
    function RTCRead: Byte;
    procedure RTCWrite(Value: Byte);
    procedure UpdateClock;
  public
    constructor Create(const Data: TBytes);
    destructor Destroy; override;
    class function Recognize(const Data: TBytes): Boolean; static;
    procedure Reset;
    function ReadByte(Address: Cardinal): Byte;
    procedure WriteByte(Address: Cardinal; Value: Byte);
    function ReadPort(Port: Byte): Byte;
    procedure WritePort(Port, Value: Byte; ColorMode: Boolean);
    procedure Tick(Cycles: Integer);
    function Backup: TBytes;
    procedure LoadBackup(const Data: TBytes);
    function BackupDirty: Boolean;
    function IRQ: Boolean;
    procedure SerializeState(State: TStateArchive);
    property Color: Boolean read FColor;
    property Vertical: Boolean read FVertical;
    property ROM: TBytes read FROM;
  end;

implementation

{$Q-}{$R-}

class function TWSCartridge.Recognize(const Data: TBytes): Boolean;
begin
  Result := (Length(Data) >= $10000) and (Length(Data) <= $1000000) and
    (Length(Data) and $FFFF = 0);
  if not Result then
    Exit;
  var N := Length(Data);
  Result := (Data[N - 16] = $EA) and (Data[N - 9] in [0, 1]) and
    (Data[N - 6] <= 9) and (Data[N - 3] <= 1);
end;

constructor TWSCartridge.Create(const Data: TBytes);
begin
  inherited Create;
  if not Recognize(Data) then
    raise EReadError.Create('Invalid WonderSwan cartridge header or size');
  var Size := $10000;
  while Size < Length(Data) do
    Size := Size shl 1;
  SetLength(FROM, Size);
  FillChar(FROM[0], Size, $FF);
  Move(Data[0], FROM[Size - Length(Data)], Length(Data));
  var N := Length(Data);
  FColor := Data[N - 9] <> 0;
  FVertical := Data[N - 4] and 1 <> 0;
  FRTC := Data[N - 3] <> 0;
  Size := 0;
  case Data[N - 5] of
    $01:
      Size := $2000;
    $02:
      Size := $8000;
    $03:
      Size := $20000;
    $04:
      Size := $40000;
    $05:
      Size := $80000;
    $10:
      FEEPROM := TWSEEPROM.Create(128);
    $20:
      FEEPROM := TWSEEPROM.Create(2048);
    $50:
      FEEPROM := TWSEEPROM.Create(1024);
  end;
  SetLength(FRAM, Size);
  if Size > 0 then
    FillChar(FRAM[0], Size, $FF);
  if (Size = $2000) and (Data[N - 10] = $16) and (Data[N - 8] = $02) then
    if SnapshotIdentity(Data) = '7180a30de6aa08ff7af4286fa97ce558112e6387a8317c0691b20bb2ea65ed0a' then
    begin
      // This release accepts uniform empty SRAM as a valid redundant save.
      // Its recovery routine only copies the second record over the first.
      // Use exactly the two records created by the game's own $2000:0718
      // initialization routine. Existing nonempty battery data takes priority.
      Move(Data[$09B9], FRAM[0], $CE);
      Move(Data[$09B9], FRAM[$CE], $CE);
      FInitialSRAM := Copy(FRAM);
    end;
  FClock := Now;
  FRTCData[7] := $C0;
  UpdateClock;
  Reset;
end;

destructor TWSCartridge.Destroy;
begin
  FEEPROM.Free;
  inherited;
end;

procedure TWSCartridge.Reset;
begin
  FillChar(FBanks, SizeOf(FBanks), 0);
  FBanks[0] := $FF;
  FBanks[1] := $FF;
  FBanks[2] := $FF;
  FBanks[3] := $FF;
  FRTCCommand := 0;
  FRTCIndex := 0;
  FRTCPhase := 0;
  FRTCBuffer := $FF;
  FRTCPendingWrite := False;
  if FEEPROM <> nil then
    FEEPROM.Reset;
end;

function TWSCartridge.GetRAMOffset(Address: Cardinal): Cardinal;
begin
  Result := ((Cardinal(FBanks[1]) or (Cardinal(FBanks[$11]) shl 8)) shl 16) or (Address and $FFFF);
end;

function TWSCartridge.ReadByte(Address: Cardinal): Byte;
var
  Offset: Cardinal;
begin
  Result := $FF;
  if Address shr 16 = 1 then
  begin
    if Length(FRAM) > 0 then
      Result := FRAM[GetRAMOffset(Address) and (Length(FRAM) - 1)];
    Exit;
  end;
  case Address shr 16 of
    2:
      Offset := ((Cardinal(FBanks[2]) or (Cardinal(FBanks[$13]) shl 8)) shl 16) or (Address and $FFFF);
    3:
      Offset := ((Cardinal(FBanks[3]) or (Cardinal(FBanks[$15]) shl 8)) shl 16) or (Address and $FFFF);
  else
    Offset := (Cardinal(FBanks[0]) shl 20) or Address;
  end;
  Result := FROM[Offset and (Length(FROM) - 1)];
end;

procedure TWSCartridge.WriteByte(Address: Cardinal; Value: Byte);
begin
  if (Address shr 16 <> 1) or (Length(FRAM) = 0) then
    Exit;
  var Offset := GetRAMOffset(Address) and (Length(FRAM) - 1);
  if FRAM[Offset] <> Value then
  begin
    FRAM[Offset] := Value;
    FDirty := True;
  end;
end;

function TWSCartridge.ReadPort(Port: Byte): Byte;
begin
  Result := $FF;
  case Port of
    $C0..$C3:
      Result := FBanks[Port - $C0];
    $C4..$C8:
      if FEEPROM <> nil then
        Result := FEEPROM.ReadPort(Port - $C4);
    $CA:
      if FRTC then
        Result := $80 or FRTCCommand;
    $CB:
      if FRTC then
        Result := RTCRead;
    $CC..$D5:
      Result := FBanks[Port - $C0];
  end;
end;

procedure TWSCartridge.WritePort(Port, Value: Byte; ColorMode: Boolean);
begin
  case Port of
    $C0..$C3:
      FBanks[Port - $C0] := Value;
    $C4..$C8:
      if FEEPROM <> nil then
        FEEPROM.WritePort(Port - $C4, Value, ColorMode);
    $CA:
      if FRTC then
        RTCCommand(Value);
    $CB:
      if FRTC then
        RTCWrite(Value);
    $CC..$D5:
      begin
        FBanks[Port - $C0] := Value;
        case Port of
          $CF:
            FBanks[0] := Value;
          $D0:
            FBanks[1] := Value;
          $D2:
            FBanks[2] := Value;
          $D4:
            FBanks[3] := Value;
        end;
      end;
  end;
end;

function BCD(N: Integer): Byte;
begin
  Result := (N div 10) * 16 + N mod 10;
end;

function UnBCD(N: Byte): Integer;
begin
  Result := (N shr 4) * 10 + (N and 15);
end;

procedure TWSCartridge.UpdateClock;
begin
  FRTCData[0] := BCD(YearOf(FClock) mod 100);
  FRTCData[1] := BCD(MonthOf(FClock));
  FRTCData[2] := BCD(DayOf(FClock));
  FRTCData[3] := DayOfTheWeek(FClock) mod 7;
  var Hour := HourOf(FClock);
  if FRTCData[7] and $40 <> 0 then
    FRTCData[4] := BCD(Hour)
  else
    FRTCData[4] := BCD(Hour mod 12) or (Ord(Hour >= 12) shl 7);
  FRTCData[5] := BCD(MinuteOf(FClock));
  FRTCData[6] := BCD(SecondOf(FClock));
end;

procedure TWSCartridge.RTCCommand(Value: Byte);
begin
  FRTCCommand := Value and $1F;
  FRTCIndex := 0;
  if FRTCCommand = $10 then
  begin
    FRTCData[7] := $80;
    FClock := EncodeDate(2000, 1, 1);
    UpdateClock;
    FRTCCommand := 0;
  end
  else if FRTCPendingWrite and (FRTCCommand and $11 = $10) then
    RTCWrite(FRTCBuffer);
end;

function TWSCartridge.RTCRead: Byte;
var
  Index, Limit: Integer;
begin
  Result := FRTCBuffer;
  case FRTCCommand of
    $13:
      begin
        Index := 7;
        Limit := 1;
      end;
    $15:
      begin
        Index := FRTCIndex;
        Limit := 7;
      end;
    $17:
      begin
        Index := 4 + FRTCIndex;
        Limit := 3;
      end;
    $19:
      begin
        Index := 8 + FRTCIndex;
        Limit := 2;
      end;
  else
    Exit;
  end;
  Result := FRTCData[Index];
  FRTCBuffer := Result;
  if Index = 7 then
    FRTCData[7] := FRTCData[7] and $7F;
  Inc(FRTCIndex);
  if FRTCIndex >= Limit then
    FRTCCommand := FRTCCommand and $F;
end;

procedure TWSCartridge.RTCWrite(Value: Byte);
var
  Index, Limit: Integer;
  D, T: TDateTime;
begin
  FRTCBuffer := Value;
  FRTCPendingWrite := True;
  case FRTCCommand of
    $12:
      begin
        Index := 7;
        Limit := 1;
      end;
    $14:
      begin
        Index := FRTCIndex;
        Limit := 7;
      end;
    $16:
      begin
        Index := 4 + FRTCIndex;
        Limit := 3;
      end;
    $18:
      begin
        Index := 8 + FRTCIndex;
        Limit := 2;
      end;
  else
    Exit;
  end;
  if Index = 7 then
    Value := (FRTCData[7] and $80) or (Value and $6A);
  FRTCData[Index] := Value;
  FRTCPendingWrite := False;
  Inc(FRTCIndex);
  FDirty := True;
  if FRTCIndex < Limit then
    Exit;
  FRTCCommand := FRTCCommand and $F;
  var Hour := UnBCD(FRTCData[4] and $3F);
  if FRTCData[7] and $40 = 0 then
    Hour := (Hour mod 12) + 12 * Ord(FRTCData[4] and $80 <> 0);
  if TryEncodeDate(2000 + UnBCD(FRTCData[0]), UnBCD(FRTCData[1]), UnBCD(FRTCData[2]), D) and
    TryEncodeTime(Hour, UnBCD(FRTCData[5]), UnBCD(FRTCData[6]), 0, T) then
    FClock := D + T;
end;

procedure TWSCartridge.Tick(Cycles: Integer);
begin
  if FEEPROM <> nil then
    FEEPROM.Tick(Cycles);
  if not FRTC then
    Exit;
  Inc(FRTCPhase, Cycles);
  while FRTCPhase >= 3072000 do
  begin
    Dec(FRTCPhase, 3072000);
    FClock := IncSecond(FClock);
    UpdateClock;
  end;
end;

function TWSCartridge.IRQ: Boolean;
begin
  Result := False;
  if not FRTC then
    Exit;
  var Status := FRTCData[7];
  if Status and 8 <> 0 then
  begin
    if Status and 2 <> 0 then
      Result := UnBCD(FRTCData[6]) < 30
    else
      Result := (FRTCData[6] = 0) and (FRTCPhase < 12000);
  end
  else if Status and 2 <> 0 then
  begin
    var Counter := Cardinal(Int64(FRTCPhase) * $10000 div 3072000);
    Result := ((not (Counter shl 1)) and (FRTCData[8] or (Word(FRTCData[9]) shl 8))) <> 0;
  end
  else if Status and $20 <> 0 then
  begin
    var Mask := $BF;
    if Status and $40 <> 0 then
      Mask := $3F;
    Result := (FRTCData[4] and Mask = FRTCData[8] and Mask) and
      (FRTCData[5] and $7F = FRTCData[9] and $7F);
  end;
end;

function TWSCartridge.Backup: TBytes;
begin
  if FEEPROM <> nil then
    Result := FEEPROM.Battery
  else
    Result := Copy(FRAM);
  if FRTC then
  begin
    var N := Length(Result);
    SetLength(Result, N + 32);
    Move(FRTCData, Result[N], 16);
    Move(FClock, Result[N + 16], 8);
    var Timestamp := Now;
    Move(Timestamp, Result[N + 24], 8);
  end;
end;

procedure TWSCartridge.LoadBackup(const Data: TBytes);
begin
  var Size := Length(Backup);
  if Length(Data) <> Size then
    raise EReadError.Create('Invalid WonderSwan cartridge save size');
  if Length(FInitialSRAM) <> 0 then
  begin
    var Blank := (Data[0] = 0) or (Data[0] = $FF);
    for var I := 1 to High(Data) do
      if Data[I] <> Data[0] then
      begin
        Blank := False;
        Break;
      end;
    if Blank then
    begin
      FRAM := Copy(FInitialSRAM);
      FDirty := True;
      Exit;
    end;
  end;
  if FRTC then
    Dec(Size, 32);
  if FEEPROM <> nil then
    FEEPROM.LoadBattery(Copy(Data, 0, Size))
  else if Size > 0 then
    Move(Data[0], FRAM[0], Size);
  if FRTC then
  begin
    Move(Data[Size], FRTCData, 16);
    Move(Data[Size + 16], FClock, 8);
    var Timestamp: TDateTime;
    Move(Data[Size + 24], Timestamp, 8);
    var Current := Now;
    if (Timestamp > 0) and (Timestamp < Current) and (Current - Timestamp < 36525) then
      FClock := FClock + (Current - Timestamp);
    UpdateClock;
  end;
  FDirty := False;
end;

function TWSCartridge.BackupDirty: Boolean;
begin
  Result := FDirty or FRTC or ((FEEPROM <> nil) and FEEPROM.Dirty);
end;

procedure TWSCartridge.SerializeState(State: TStateArchive);
begin
  State.Field(FBanks, SizeOf(FBanks));
  State.Field(FDirty, SizeOf(FDirty));
  if Length(FRAM) > 0 then
    State.Field(FRAM[0], Length(FRAM));
  if FEEPROM <> nil then
    FEEPROM.SerializeState(State);
  State.Field(FRTCData, SizeOf(FRTCData));
  State.Field(FRTCCommand, SizeOf(FRTCCommand));
  State.Field(FRTCBuffer, SizeOf(FRTCBuffer));
  State.Field(FRTCPendingWrite, SizeOf(FRTCPendingWrite));
  State.Field(FRTCIndex, SizeOf(FRTCIndex));
  State.Field(FRTCPhase, SizeOf(FRTCPhase));
  State.Field(FClock, SizeOf(FClock));
  if State.Loading then
  begin
    if (FRTCIndex > 7) or (FRTCPhase < 0) or (FRTCPhase >= 3072000) then
      raise EReadError.Create('Invalid WonderSwan RTC state');
    FDirty := True;
  end;
end;

end.

