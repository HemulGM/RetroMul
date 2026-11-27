unit INTV.ECS;

interface

uses
  System.SysUtils, System.Classes, Core.Input.Keyboard, Core.Storage,
  Core.Snapshots, HW.Sound.YM2149;

type
  TIntvECSInput = (Keyboard, Controllers, Piano);

  TIntvECS = class
  private
    type
      TSerialMode = (Idle, LoadTape, SaveTape, Print);
  private
    const
      MaximumTapeBytes = 1024 * 1024;
  private
    FROM: array[0..2, 0..$FFF] of Word;
    FRAM: array[0..$7FF] of Byte;
    FPages: array[0..2] of Byte;
    FHasROM: Boolean;
    FPSG: TYM2149F;
    FVolume: array[0..2] of Byte;
    FMatrix: array[0..7] of Byte;
    FControllers: array[0..1] of Byte;
    FInputMode: TIntvECSInput;
    FStorage: IStorage;
    FMediaFolder, FTapeName: string;
    FSerialMode: TSerialMode;
    FSerialControl, FSerialConfig: Byte;
    FIncoming: TBytes;
    FReceivePosition: Integer;
    FOutgoing: TMemoryStream;
    function TapeName(RAMOffset: Integer): string;
    function TapePath: string;
    procedure FinishSerial;
    procedure BeginTape(Mode: TSerialMode);
    function ReadSerial(Address: Word): Word;
    procedure WriteSerial(Address: Word; Value: Byte);
    procedure SerializeSerial(State: TStateArchive);
    function ReadPort(Port: Integer): Byte;
    function ReadMatrix(Lines: Byte; Transposed: Boolean): Byte;
    class function ROMWindow(Address: Word): Integer; static;
  public
    constructor Create(const ROM: TBytes; Clock, SampleRate: Integer; const Storage: IStorage = nil; const MediaFolder: string = '');
    destructor Destroy; override;
    procedure Reset;
    procedure FlushSerial;
    function ReadWord(Address: Word): Word;
    procedure WriteWord(Address, Value: Word);
    procedure SetInput(const Keys: THostKeyboardKeys; FirstController, SecondController: Byte; InputMode: TIntvECSInput);
    procedure Sample(out Left, Right: SmallInt);
    procedure SerializeState(State: TStateArchive);
  end;

implementation

uses
  System.IOUtils, System.UITypes;

const
  PSGRegisters: array[0..15] of Byte = (0, 2, 4, 11, 1, 3, 5, 12, 7, 6, 13, 8, 9, 10, 14, 15);
  // The two shift keys share a contact. Zero entries are unwired.
  KeyboardMatrix: array[0..7, 0..7] of Byte = (
    (vkLeft, $BE, $BA, vkP, vkEscape, vk0, vkReturn, 0),
    ($BC, vkM, vkK, vkI, vk9, vk8, vkO, vkL),
    (vkN, vkB, vkH, vkY, vk7, vk6, vkU, vkJ),
    (vkV, vkC, vkF, vkR, vk5, vk4, vkT, vkG),
    (vkX, vkZ, vkS, vkW, vk3, vk2, vkE, vkD),
    (vkSpace, vkDown, vkUp, vkQ, vk1, vkRight, vkControl, vkA),
    (0, 0, 0, 0, 0, 0, 0, vkShift),
    (0, 0, 0, 0, 0, 0, 0, 0)
  );
  // PC piano layout, beginning with C2. Other keys can be supplied by a
  // frontend with a dedicated piano controller using the same scan matrix.
  PianoKeys: array[0..48] of Byte = (
    vkZ, vkS, vkX, vkD, vkC, vkV, vkG, vkB, vkH, vkN, vkJ, vkM,
    vkQ, vk2, vkW, vk3, vkE, vkR, vk5, vkT, vk6, vkY, vk7, vkU,
    vkI, vk9, vkO, vk0, vkP, $DB, $BB, $DD, $DC, vkReturn, vkBack, vkSpace,
    vkNumpad0, vkNumpad1, vkNumpad2, vkNumpad3, vkNumpad4, vkNumpad5,
    vkNumpad6, vkNumpad7, vkNumpad8, vkNumpad9, vkSubtract, vkAdd, vkDecimal
  );
  ROMPages: array[0..2] of Byte = (1, 0, 1);

constructor TIntvECS.Create(const ROM: TBytes; Clock, SampleRate: Integer; const Storage: IStorage; const MediaFolder: string);
begin
  inherited Create;
  FStorage := Storage;
  FMediaFolder := MediaFolder;
  FOutgoing := TMemoryStream.Create;
  if Length(ROM) <> 0 then
  begin
    if Length(ROM) <> $6000 then
      raise EReadError.Create('Intellivision ECS ROM must contain 24576 bytes');
    for var Window := 0 to 2 do
      for var Offset := 0 to $FFF do
      begin
        var Index := (Window * $1000 + Offset) * 2;
        FROM[Window, Offset] := (ROM[Index] shl 8) or ROM[Index + 1];
      end;
    FHasROM := True;
  end;
  FPSG := TYM2149F.Create(Clock, SampleRate);
  FPSG.AYModel := True;
  FPSG.OnPortRead := ReadPort;
  for var Channel := 0 to 2 do
    FPSG.SetPan(Channel, 0.5, 0.5);
  Reset;
end;

destructor TIntvECS.Destroy;
begin
  FPSG.Free;
  FOutgoing.Free;
  inherited;
end;

procedure TIntvECS.Reset;
begin
  FinishSerial;
  FSerialControl := 0;
  FSerialConfig := 0;
  FillChar(FRAM, SizeOf(FRAM), 0);
  FillChar(FPages, SizeOf(FPages), 0);
  FillChar(FVolume, SizeOf(FVolume), 0);
  FillChar(FMatrix, SizeOf(FMatrix), 0);
  FillChar(FControllers, SizeOf(FControllers), $FF);
  FPSG.Reset;
  for var Channel := 0 to 2 do
    FPSG.SetEnvelopeShift(Channel, 0);
end;

class function TIntvECS.ROMWindow(Address: Word): Integer;
begin
  case Address shr 12 of
    $2:
      Result := 0;
    $7:
      Result := 1;
    $E:
      Result := 2;
  else
    Result := -1;
  end;
end;

function TIntvECS.ReadWord(Address: Word): Word;
begin
  case Address of
    $00E0..$00E3:
      Exit(ReadSerial(Address));
    $00F0..$00FF:
      if (Address >= $FB) and (Address <= $FD) then
        Exit(FVolume[Address - $FB])
      else
        Exit(FPSG.ReadRegister(PSGRegisters[Address - $F0]));
    $4000..$47FF:
      Exit(FRAM[Address - $4000]);
  end;
  var Window := ROMWindow(Address);
  if FHasROM and (Window >= 0) and (FPages[Window] = ROMPages[Window]) then
    Exit(FROM[Window, Address and $FFF]);
  Result := $FFFF;
end;

procedure TIntvECS.WriteWord(Address, Value: Word);
begin
  case Address of
    $00E0..$00E3:
      WriteSerial(Address, Byte(Value));
    $00F0..$00FF:
      if (Address >= $FB) and (Address <= $FD) then
      begin
        var Channel := Address - $FB;
        var Mode := (Value shr 4) and 3;
        FVolume[Channel] := Value and $3F;
        if Mode = 0 then
          FPSG.WriteRegister(8 + Channel, Value and 15)
        else
        begin
          FPSG.SetEnvelopeShift(Channel, 3 - Mode);
          FPSG.WriteRegister(8 + Channel, $10);
        end;
      end
      else
        FPSG.WriteRegister(PSGRegisters[Address - $F0], Byte(Value));
    $4000..$47FF:
      FRAM[Address - $4000] := Byte(Value);
    $2FFF, $7FFF, $EFFF:
      if Value and $FFF0 = ((Address and $F000) or $A50) then
        FPages[ROMWindow(Address)] := Value and $F;
  end;
end;

function TIntvECS.TapeName(RAMOffset: Integer): string;
begin
  Result := '';
  for var Index := 0 to 3 do
  begin
    var Code := FRAM[RAMOffset + Index];
    if (Code <= 32) or (Code >= 127) then
      Break;
    var Character := Char(Code);
    if not CharInSet(Character, ['0'..'9', 'a'..'z', 'A'..'Z']) then
      Character := '_';
    Result := Result + UpCase(Character);
  end;
end;

function TIntvECS.TapePath: string;
begin
  Result := TPath.Combine(FMediaFolder, 'tape-' + FTapeName + '.ecs');
end;

procedure TIntvECS.FlushSerial;
begin
  if (FOutgoing.Size = 0) or (FStorage = nil) or (FMediaFolder = '') then
    Exit;
  case FSerialMode of
    TSerialMode.SaveTape:
      begin
        FStorage.WriteAtomic(TapePath, FOutgoing);
        FOutgoing.Clear;
      end;
    TSerialMode.Print:
      begin
        var Path := TPath.Combine(FMediaFolder, 'printer.txt');
        var Printer := TMemoryStream.Create;
        try
          if FStorage.Exists(Path) then
          begin
            var Previous := FStorage.OpenRead(Path);
            try
              Printer.CopyFrom(Previous, 0);
            finally
              Previous.Free;
            end;
          end;
          FOutgoing.Position := 0;
          Printer.CopyFrom(FOutgoing, FOutgoing.Size);
          FStorage.WriteAtomic(Path, Printer);
          FOutgoing.Clear;
        finally
          Printer.Free;
        end;
      end;
  end;
end;

procedure TIntvECS.FinishSerial;
begin
  FlushSerial;
  FSerialMode := TSerialMode.Idle;
  FTapeName := '';
  FIncoming := nil;
  FReceivePosition := 0;
  FOutgoing.Clear;
end;

procedure TIntvECS.BeginTape(Mode: TSerialMode);
begin
  FinishSerial;
  FSerialMode := Mode;
  if Mode = TSerialMode.SaveTape then
    FTapeName := TapeName($FA)
  else
  begin
    FTapeName := TapeName($80);
    if (FStorage <> nil) and (FMediaFolder <> '') and FStorage.Exists(TapePath) then
    begin
      var Input := FStorage.OpenRead(TapePath);
      try
        FIncoming := ReadRomData(Input, MaximumTapeBytes);
      finally
        Input.Free;
      end;
    end;
  end;
end;

function TIntvECS.ReadSerial(Address: Word): Word;
begin
  case Address of
    $E0:
      Result := 1 or (Ord(FReceivePosition < Length(FIncoming)) shl 1);
    $E1:
      begin
        Result := 0;
        if FReceivePosition < Length(FIncoming) then
        begin
          Result := FIncoming[FReceivePosition];
          Inc(FReceivePosition);
        end;
      end;
    $E2:
      Result := FSerialConfig;
  else
    Result := $FFFF;
  end;
end;

procedure TIntvECS.WriteSerial(Address: Word; Value: Byte);
begin
  case Address of
    $E0:
      begin
        FSerialControl := Value;
        if (Value = $11) and (FSerialMode = TSerialMode.Print) then
          FlushSerial
        else if (Value = $1D) and (FSerialConfig = $1D) then
          BeginTape(TSerialMode.LoadTape)
        else if (Value = $1D) and (FSerialConfig = $39) then
          BeginTape(TSerialMode.SaveTape)
        else
          FinishSerial;
      end;
    $E1:
      begin
        if (FSerialMode = TSerialMode.Idle) and (FSerialControl = $11) and (FSerialConfig = $23) then
          FSerialMode := TSerialMode.Print;
        if FSerialMode in [TSerialMode.SaveTape, TSerialMode.Print] then
        begin
          if FOutgoing.Size >= MaximumTapeBytes then
            raise EWriteError.Create('Intellivision ECS serial output exceeds the supported size');
          FOutgoing.WriteBuffer(Value, 1);
          if (FSerialMode = TSerialMode.Print) and (Value = 13) then
          begin
            Value := 10;
            FOutgoing.WriteBuffer(Value, 1);
            FlushSerial;
          end;
        end;
      end;
    $E2:
      begin
        if (Value in [$00, $23]) and (FSerialMode = TSerialMode.Print) then
          FlushSerial
        else
          FinishSerial;
        FSerialConfig := Value;
      end;
  end;
end;

procedure TIntvECS.SerializeSerial(State: TStateArchive);

  procedure TransferBytes(var Data: TBytes; Limit: Integer);
  begin
    var Count := Length(Data);
    State.Field(Count, SizeOf(Count));
    if (Count < 0) or (Count > Limit) then
      raise EReadError.Create('Invalid Intellivision ECS serial buffer size');
    if State.Loading then
      SetLength(Data, Count);
    if Count > 0 then
      State.Field(Data[0], Count);
  end;

begin
  var Mode := Byte(Ord(FSerialMode));
  State.Field(Mode, SizeOf(Mode));
  State.Field(FSerialControl, SizeOf(FSerialControl));
  State.Field(FSerialConfig, SizeOf(FSerialConfig));
  State.Field(FReceivePosition, SizeOf(FReceivePosition));
  TransferBytes(FIncoming, MaximumTapeBytes);

  var TapeNameBytes := TEncoding.ASCII.GetBytes(FTapeName);
  TransferBytes(TapeNameBytes, 4);
  var Output: TBytes;
  if not State.Loading then
  begin
    SetLength(Output, FOutgoing.Size);
    if Length(Output) > 0 then
      Move(FOutgoing.Memory^, Output[0], Length(Output));
  end;
  TransferBytes(Output, MaximumTapeBytes);

  if State.Loading then
  begin
    if (Mode > Byte(High(TSerialMode))) or (FReceivePosition < 0) or
      (FReceivePosition > Length(FIncoming)) then
      raise EReadError.Create('Invalid Intellivision ECS serial state');
    for var Character in TapeNameBytes do
      if not CharInSet(Char(Character), ['0'..'9', 'A'..'Z', '_']) then
        raise EReadError.Create('Invalid Intellivision ECS cassette name');
    FSerialMode := TSerialMode(Mode);
    FTapeName := TEncoding.ASCII.GetString(TapeNameBytes);
    FOutgoing.Clear;
    if Length(Output) > 0 then
      FOutgoing.WriteBuffer(Output[0], Length(Output));
  end;
end;

function TIntvECS.ReadMatrix(Lines: Byte; Transposed: Boolean): Byte;
begin
  var LowLines: Byte := 0;
  var HighLines: Byte := 0;
  for var Index := 0 to 7 do
  begin
    var Contacts := FMatrix[Index];
    if Transposed then
    begin
      Contacts := 0;
      for var Row := 0 to 7 do
        if FMatrix[Row] and (1 shl Index) <> 0 then
          Contacts := Contacts or (1 shl Row);
    end;
    if Lines and (1 shl Index) = 0 then
      LowLines := LowLines or Contacts
    else
      HighLines := HighLines or Contacts;
  end;
  if FInputMode = TIntvECSInput.Keyboard then
    LowLines := LowLines and not HighLines;
  Result := not LowLines;
end;

function TIntvECS.ReadPort(Port: Integer): Byte;
begin
  if FInputMode = TIntvECSInput.Controllers then
    Exit(FControllers[1 - Port]);
  var OtherPort := 1 - Port;
  if FPSG.ReadRegister(7) and (64 shl OtherPort) = 0 then
    Exit($FF);
  if (Port = 0) and (FInputMode = TIntvECSInput.Piano) then
    Exit($FF); // The piano's diodes make its switches directional.
  Result := ReadMatrix(FPSG.ReadRegister(14 + OtherPort), Port = 0);
end;

procedure TIntvECS.SetInput(const Keys: THostKeyboardKeys; FirstController, SecondController: Byte; InputMode: TIntvECSInput);
begin
  FInputMode := InputMode;
  FControllers[0] := FirstController;
  FControllers[1] := SecondController;
  FillChar(FMatrix, SizeOf(FMatrix), 0);
  if InputMode = TIntvECSInput.Keyboard then
    for var Row := 0 to 7 do
      for var Column := 0 to 7 do
      begin
        var Key := KeyboardMatrix[Row, Column];
        if (Key <> 0) and Keys[Key] then
          FMatrix[Row] := FMatrix[Row] or (1 shl Column);
      end
  else if InputMode = TIntvECSInput.Piano then
    for var Note := 0 to High(PianoKeys) do
      if Keys[PianoKeys[Note]] then
        FMatrix[Note div 8] := FMatrix[Note div 8] or (1 shl (Note mod 8));
end;

procedure TIntvECS.Sample(out Left, Right: SmallInt);
begin
  FPSG.Sample(Left, Right);
end;

procedure TIntvECS.SerializeState(State: TStateArchive);
begin
  State.Field(FRAM, SizeOf(FRAM));
  State.Field(FPages, SizeOf(FPages));
  State.Field(FVolume, SizeOf(FVolume));
  FPSG.SerializeState(State.Field);
  SerializeSerial(State);
  if State.Loading then
    for var Channel := 0 to 2 do
      FPSG.SetEnvelopeShift(Channel, (3 - (FVolume[Channel] shr 4)) and 3);
end;

end.

