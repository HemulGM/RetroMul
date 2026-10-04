unit NES.Bus;

interface

uses
  NES.State, NES.Types, NES.PPU, NES.Cartridge, NES.Controller, NES.APU,
  NES.FamicomKeyboardDevice, NES.FamicomDataRecorder, NES.MiraclePianoDevice;

type
  TNesBus = class
  private
    FRam: array[0..$07FF] of UInt8;
    FCartridge: TCartridge;
    FPpu: TPpu;
    FApu: TApu;
    FController1: TController;
    FController2: TController;
    FController3: TController;
    FController4: TController;
    FSuborKeyboard: TSuborKeyboard;
    FFamicomKeyboard: TFamicomKeyboard;
    FDataRecorder: TFamicomDataRecorder;
    FZapper: TZapper;
    FMiraclePiano: TMiraclePianoDevice;
    FFourScoreEnabled: Boolean;
    FControllerStrobe: Boolean;
    FControllerReadIndex: array[0..1] of Integer;
    FDmaActive: Boolean;
    FDmaDummy: Boolean;
    FDmaAlign: Boolean;
    FDmaPage: UInt8;
    FDmaAddress: UInt8;
    FDmaData: UInt8;
    FDmaHaveData: Boolean;
    FCpuCycle: UInt64;
    FDataBus: UInt8;
    FInternalDataBus: UInt8;
    FHaltedCpuAddress: UInt16;
    FTimedIo: Boolean;
    FPendingStrobe: UInt8;
    FStrobeDirty: Boolean;
    FCoinFrames: array[0..1] of Byte;
    FPendingCoins: array[0..1] of Integer;
    function GetHasCoinAcceptor: Boolean;
    procedure InsertCoin(Player: Integer);
    procedure WriteControllers(Value: UInt8);
    function ReadController(Port: Integer): UInt8;
    function ReadDevice(Address: UInt16): UInt8;
  public
    property HasCoinAcceptor: Boolean read GetHasCoinAcceptor;
    property MiraclePiano: TMiraclePianoDevice read FMiraclePiano write FMiraclePiano;
    property DataRecorder: TFamicomDataRecorder read FDataRecorder write FDataRecorder;
    procedure InsertCoin1;
    procedure InsertCoin2;
    procedure ClockCoinFrame;
    procedure SerializeCoins(State: TNesStateArchive);
    procedure SerializeState(State: TNesStateArchive);
    // Appended to the console snapshot after v4 fields for legacy compatibility.
    procedure SerializeDataBus(State: TNesStateArchive);
    constructor Create;
    procedure Reset;
    procedure Connect(Cartridge: TCartridge; Ppu: TPpu; Apu: TApu; Controller1, Controller2: TController; Controller3: TController = nil; Controller4: TController = nil; SuborKeyboard: TSuborKeyboard = nil; FamicomKeyboard: TFamicomKeyboard = nil);
    function CpuRead(Address: UInt16): UInt8;
    function DmaRead(Address: UInt16): UInt8;
    function DmaTransferRead(Address: UInt16): UInt8;
    procedure CpuWrite(Address: UInt16; Value: UInt8);
    function IsDmaActive: Boolean;
    procedure ClockDma(CpuCycleOdd: Boolean);
    procedure ClockIo;
    function DebugCpuRead(Address: UInt16): UInt8;
    property CpuCycle: UInt64 read FCpuCycle write FCpuCycle;
    property DmaWritePending: Boolean read FDmaHaveData;
    property HaltedCpuAddress: UInt16 read FHaltedCpuAddress write FHaltedCpuAddress;
    property TimedIo: Boolean read FTimedIo write FTimedIo;
    property FourScoreEnabled: Boolean read FFourScoreEnabled write FFourScoreEnabled;
    property Zapper: TZapper read FZapper write FZapper;
  end;

implementation

uses
  NES.Mapper;

function TNesBus.GetHasCoinAcceptor: Boolean;
begin
  Result := (FCartridge <> nil) and ((FCartridge.MapperId = MAPPER_VS_SYSTEM) or (FCartridge.Metadata.ConsoleType = 1));
end;

procedure TNesBus.InsertCoin(Player: Integer);
begin
  if not HasCoinAcceptor then
    Exit;

  if FCoinFrames[Player] = 0 then
    FCoinFrames[Player] := 8
  else if FPendingCoins[Player] < High(Integer) then
    Inc(FPendingCoins[Player]);
end;

procedure TNesBus.InsertCoin1;
begin
  InsertCoin(0);
end;

procedure TNesBus.InsertCoin2;
begin
  InsertCoin(1);
end;

procedure TNesBus.ClockCoinFrame;
begin
  // Four frames high, then four low so consecutive coins have separate edges.
  for var Player := 0 to 1 do
  begin
    if FCoinFrames[Player] > 0 then
      Dec(FCoinFrames[Player]);
    if (FCoinFrames[Player] = 0) and (FPendingCoins[Player] > 0) then
    begin
      Dec(FPendingCoins[Player]);
      FCoinFrames[Player] := 8;
    end;
  end;
end;

procedure TNesBus.SerializeCoins(State: TNesStateArchive);
begin
  if State.Version >= 11 then
  begin
    State.Field(FCoinFrames, SizeOf(FCoinFrames));
    State.Field(FPendingCoins, SizeOf(FPendingCoins));
    if State.Loading then
      for var Player := 0 to 1 do
        if (FCoinFrames[Player] > 8) or (FPendingCoins[Player] < 0) then
          raise ENesException.Create('Invalid coin input state');
  end
  else if State.Loading then
  begin
    FillChar(FCoinFrames, SizeOf(FCoinFrames), 0);
    FillChar(FPendingCoins, SizeOf(FPendingCoins), 0);
  end;
end;

procedure TNesBus.SerializeDataBus(State: TNesStateArchive);
begin
  if State.Version >= 5 then
    State.Field(FDataBus, SizeOf(FDataBus))
  else if State.Loading then
    FDataBus := 0;
  if State.Version >= 9 then
    State.Field(FInternalDataBus, SizeOf(FInternalDataBus))
  else if State.Loading then
    FInternalDataBus := FDataBus;
  if State.Version >= 10 then
  begin
    State.Field(FPendingStrobe, SizeOf(FPendingStrobe));
    State.Field(FStrobeDirty, SizeOf(FStrobeDirty));
  end
  else if State.Loading then
  begin
    FPendingStrobe := 0;
    FStrobeDirty := False;
  end;
end;

procedure TNesBus.SerializeState(State: TNesStateArchive);
begin
  State.Field(FRam, SizeOf(FRam));
  State.Field(FFourScoreEnabled, SizeOf(FFourScoreEnabled));
  State.Field(FControllerStrobe, SizeOf(FControllerStrobe));
  State.Field(FControllerReadIndex, SizeOf(FControllerReadIndex));
  if FSuborKeyboard <> nil then
    FSuborKeyboard.SerializeState(State);
  State.Field(FDmaActive, SizeOf(FDmaActive));
  State.Field(FDmaDummy, SizeOf(FDmaDummy));
  State.Field(FDmaAlign, SizeOf(FDmaAlign));
  State.Field(FDmaPage, SizeOf(FDmaPage));
  State.Field(FDmaAddress, SizeOf(FDmaAddress));
  State.Field(FDmaData, SizeOf(FDmaData));
  State.Field(FDmaHaveData, SizeOf(FDmaHaveData));
  State.Field(FCpuCycle, SizeOf(FCpuCycle));
end;

constructor TNesBus.Create;
begin
  inherited Create;
  for var i := Low(FRam) to High(FRam) do
    FRam[i] := 0;
  FDmaActive := False;
  FDmaDummy := True;
  FDmaAlign := False;
  FDmaPage := 0;
  FDmaAddress := 0;
  FDmaData := 0;
end;

procedure TNesBus.Connect(Cartridge: TCartridge; Ppu: TPpu; Apu: TApu; Controller1, Controller2, Controller3, Controller4: TController; SuborKeyboard: TSuborKeyboard; FamicomKeyboard: TFamicomKeyboard);
begin
  FCartridge := Cartridge;
  FPpu := Ppu;
  FApu := Apu;
  FController1 := Controller1;
  FController2 := Controller2;
  FController3 := Controller3;
  FController4 := Controller4;
  FSuborKeyboard := SuborKeyboard;
  FFamicomKeyboard := FamicomKeyboard;
end;

procedure TNesBus.WriteControllers(Value: UInt8);
begin
  if FControllerStrobe or ((Value and 1) <> 0) then
  begin
    FControllerReadIndex[0] := 0;
    FControllerReadIndex[1] := 0;
  end;
  FControllerStrobe := (Value and 1) <> 0;
  FController1.Write(Value);
  FController2.Write(Value);
  if FController3 <> nil then
    FController3.Write(Value);
  if FController4 <> nil then
    FController4.Write(Value);
end;

procedure TNesBus.ClockIo;
begin
  // Sample the output latch on the GET-to-PUT transition, before the next
  // CPU write. A pulse wholly between sampling edges is invisible.
  if FTimedIo and FStrobeDirty and ((FCpuCycle and 1) = 0) then
  begin
    WriteControllers(FPendingStrobe);
    FStrobeDirty := False;
  end;
end;

function TNesBus.ReadController(Port: Integer): UInt8;
begin
  var Primary, Extra: TController;
  if Port = 0 then
  begin
    Primary := FController1;
    Extra := FController3;
  end
  else
  begin
    Primary := FController2;
    Extra := FController4;
  end;
  if not FFourScoreEnabled then
    Exit(Primary.Read);
  if FControllerStrobe then
    Exit(Primary.Read and 1);

  var Index := FControllerReadIndex[Port];
  if Index < 8 then
    Result := Primary.Read and 1
  else if Index < 16 then
  begin
    if Extra <> nil then
      Result := Extra.Read and 1
    else
      Result := 0;
  end
  else if Index < 24 then
    // Signatures $10/$20 are sent MSB first (reads 20/19 respectively).
    Result := (($10 shl Port) shr (23 - Index)) and 1
  else
    Exit(1);

  Inc(FControllerReadIndex[Port]);
end;

function TNesBus.CpuRead(Address: UInt16): UInt8;
begin
  Result := ReadDevice(Address);
  FInternalDataBus := Result;
  // $4015 is internal to the CPU; it does not drive the external bus.
  if Address <> $4015 then
    FDataBus := Result;
end;

function TNesBus.DmaRead(Address: UInt16): UInt8;
begin
  // DMA drives the external bus without replacing the CPU's internal latch.
  Result := ReadDevice(Address);
  if Address <> $4015 then
    FDataBus := Result;
end;

function TNesBus.DmaTransferRead(Address: UInt16): UInt8;
begin
  // The CPU's held address enables the internal I/O decoder; DMA supplies
  // the low five address bits. External memory remains selected in parallel.
  if (FHaltedCpuAddress and $FFE0) <> $4000 then
  begin
    if (Address >= $4015) and (Address <= $4017) then
      Exit(FDataBus);
    Exit(DmaRead(Address));
  end;

  var RegisterAddress: UInt16 := $4000 or (Address and $1F);
  if RegisterAddress = $4015 then
  begin
    Result := ReadDevice($4015);
    FInternalDataBus := Result;
    if Address <> RegisterAddress then
      DmaRead(Address);
  end
  else if (RegisterAddress = $4016) or (RegisterAddress = $4017) then
  begin
    var ControllerValue := DmaRead(RegisterAddress);
    Result := ControllerValue;
    if Address <> RegisterAddress then
    begin
      var ExternalValue := DmaRead(Address);
      Result := (ExternalValue and $E0) or (ControllerValue and ExternalValue and $1F);
      FDataBus := (ExternalValue and $E0) or (ControllerValue and $1F);
    end;
  end
  else
    Result := DmaRead(Address);
end;

function TNesBus.ReadDevice(Address: UInt16): UInt8;
begin
  if (Address = $4011) and (FCartridge <> nil) and (FCartridge.Mapper <> nil) then
    if FCartridge.Mapper.CpuReadOpenBus(Address, FDataBus, Result) then
      Exit;
  if Address < $2000 then
    Exit(FRam[Address and $07FF]);
  if Address < $4000 then
    Exit(FPpu.CpuRead($2000 or (Address and 7)));

  case Address of
    $4015:
      Exit((FApu.CpuReadStatus and $DF) or (FInternalDataBus and $20));
    $4016:
      begin
        if (FMiraclePiano <> nil) and FMiraclePiano.Connected then
          Exit(FMiraclePiano.Read or (FDataBus and $E0));
        Result := (ReadController(0) and $1F) or (FDataBus and $E0);
        if FDataRecorder <> nil then
          Result := Result or FDataRecorder.Read;
        // VS coin slots are independent live inputs on $4016 bits 5 and 6.
        if HasCoinAcceptor then
        begin
          Result := Result and $1F;
          if FCoinFrames[0] > 4 then
            Result := Result or $20;
          if FCoinFrames[1] > 4 then
            Result := Result or $40;
        end;
        Exit;
      end;
    $4017:
      begin
        if (FMiraclePiano <> nil) and FMiraclePiano.Connected then
          FMiraclePiano.ReadOtherPort;
        // Zapper replaces port 2, including Power Pad/Four Score/keyboard.
        // Parallel inputs are live and independent of $4016 strobes.
        if (FZapper <> nil) and FZapper.Enabled then
          Exit((FZapper.Read(FPpu.GetZapperMask^) and $1F) or (FDataBus and $E0));
        Result := ReadController(1);
        if FSuborKeyboard <> nil then
          Result := Result or FSuborKeyboard.Read;
        if FFamicomKeyboard <> nil then
          Result := Result or FFamicomKeyboard.Read;
        Result := (Result and $1F) or (FDataBus and $E0);
        Exit;
      end;
  end;

  var Value: UInt8;
  if (FCartridge <> nil) and (FCartridge.Mapper <> nil) and FCartridge.Mapper.CpuReadOpenBus(Address, FDataBus, Value) then
    Exit(Value);

  Result := FDataBus;
end;

procedure TNesBus.CpuWrite(Address: UInt16; Value: UInt8);
begin
  FDataBus := Value;
  FInternalDataBus := Value;
  if (FCartridge <> nil) and (FCartridge.Mapper <> nil) then
    FCartridge.Mapper.ClockCpuWrite;
  if Address < $2000 then
  begin
    FRam[Address and $07FF] := Value;
    if (FCartridge <> nil) and (FCartridge.Mapper <> nil) then
      FCartridge.Mapper.CpuRamWrite(Address and $7FF, Value);
    Exit;
  end;
  if Address < $4000 then
  begin
    FPpu.CpuWrite($2000 or (Address and 7), Value);
    if (FCartridge <> nil) and (FCartridge.Mapper <> nil) then
      FCartridge.Mapper.CpuIoWrite($2000 or (Address and 7), Value);
    Exit;
  end;

  case Address of
    $4000..$4013, $4015, $4017:
      begin
        FApu.CpuWrite(Address, Value);
        Exit;
      end;
    $4014:
      begin
        FDmaPage := Value;
        FDmaAddress := 0;
        FDmaDummy := True;
        FDmaAlign := False;
        FDmaActive := True;
        FDmaHaveData := False;
        Exit;
      end;
    $4016:
      begin
        if (FMiraclePiano <> nil) and FMiraclePiano.Connected then
          FMiraclePiano.Write(Value, FCpuCycle);
        if FTimedIo then
        begin
          FPendingStrobe := Value;
          FStrobeDirty := True;
        end
        else
          WriteControllers(Value);
        if FSuborKeyboard <> nil then
          FSuborKeyboard.Write(Value);
        if FFamicomKeyboard <> nil then
          FFamicomKeyboard.Write(Value);
        if FDataRecorder <> nil then
          FDataRecorder.Write(Value);
        if (FCartridge <> nil) and (FCartridge.Mapper <> nil) then
          FCartridge.Mapper.CpuWriteTimed(Address, Value, FCpuCycle);
        Exit;
      end;
  end;

  if (FCartridge <> nil) and (FCartridge.Mapper <> nil) and FCartridge.Mapper.CpuWriteTimed(Address, Value, FCpuCycle) then
  begin
    var Dac: Byte;
    if FCartridge.Mapper.ConsumeDacWrite(Dac) then
      FApu.CpuWrite($4011, Dac);
    Exit;
  end;
end;

function TNesBus.IsDmaActive: Boolean;
begin
  Result := FDmaActive;
end;

procedure TNesBus.ClockDma(CpuCycleOdd: Boolean);
begin
  if not FDmaActive then
    Exit;

  if FDmaDummy then
  begin
    FDmaDummy := False;
    FDmaAlign := CpuCycleOdd;
    Exit;
  end;

  if FDmaAlign then
  begin
    FDmaAlign := False;
    Exit;
  end;

  if CpuCycleOdd then
  begin
    FDmaData := DmaTransferRead((UInt16(FDmaPage) shl 8) or FDmaAddress);
    FDmaHaveData := True;
  end
  else if FDmaHaveData then
  begin
    FDmaHaveData := False;
    FDataBus := FDmaData;
    FInternalDataBus := FDmaData;
    FPpu.WriteOamDma(FDmaAddress, FDmaData);
    FDmaAddress := (FDmaAddress + 1) and $FF;
    if FDmaAddress = 0 then
    begin
      FDmaActive := False;
      FDmaDummy := True;
      FDmaAlign := False;
    end;
  end;
end;

procedure TNesBus.Reset;
begin
  FillChar(FCoinFrames, SizeOf(FCoinFrames), 0);
  FillChar(FPendingCoins, SizeOf(FPendingCoins), 0);
  FDataBus := 0;
  FInternalDataBus := 0;
  FPendingStrobe := 0;
  FStrobeDirty := False;
  FDmaActive := False;
  FDmaDummy := True;
  FDmaAlign := False;
  FDmaHaveData := False;
  FCpuCycle := 0;
  FControllerStrobe := False;
  FControllerReadIndex[0] := 0;
  FControllerReadIndex[1] := 0;
  if FSuborKeyboard <> nil then
    FSuborKeyboard.Reset;
  if FFamicomKeyboard <> nil then
    FFamicomKeyboard.Reset;
  if (FController1 <> nil) and (FController2 <> nil) then
  begin
    WriteControllers(1);
    WriteControllers(0);
  end;
end;

function TNesBus.DebugCpuRead(Address: UInt16): UInt8;
begin
  // Inspecting RAM must not drive the emulated CPU data bus.
  if Address < $2000 then
    Exit(FRam[Address and $07FF]);

  Result := CpuRead(Address);
end;

end.

