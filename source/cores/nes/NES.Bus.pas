unit NES.Bus;

interface

uses
  NES.State, NES.Types, NES.PPU, NES.Cartridge, NES.Controller, NES.APU,
  NES.Mapper.OneBus, NES.Mapper.Mmc5, NES.Mapper.Fcns, NES.Mapper.SuperGameMega,
  NES.Mapper.CoolGirl, NES.Mapper.Um6578, NES.Mapper.ExtendedMemory,
  NES.FamicomKeyboardDevice, NES.FamicomDataRecorder, NES.MiraclePianoDevice;

type
  TNesBus = class
  private
    FRam: array[0..$1FFF] of UInt8;
    FRamMask: Word;
    FOneBus: TMapperOneBus;
    FFcns: TMapperFcns;
    FSuperGameMega: TMapperSuperGameMega;
    FCoolGirl: TMapperCoolGirl;
    FUm6578: TMapperUm6578;
    FSuborSb2000: TMapperSuborSb2000;
    FDancingExpert: TMapperDancingExpert;
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
    FTapeOnMapper, FCroakyPanel: Boolean;
    FZapper: TZapper;
    FMiraclePiano: TMiraclePianoDevice;
    FFourScoreEnabled: Boolean;
    FDisconnectedPads: Byte;
    FControllerStrobe: Boolean;
    FFamilyTrainer: TFamilyTrainerMode;
    FFamilyTrainerRows: Byte;
    FControllerReadIndex: array[0..1] of Integer;
    FDmaActive: Boolean;
    FDmaDummy: Boolean;
    FDmaAlign: Boolean;
    FDmaPage: UInt8;
    FDmaAddress: UInt8;
    FDmaData: UInt8;
    FDmaHaveData: Boolean;
    FDmaLimit: Word;
    FDmaSourceOffset: Byte;
    FDmaVideoRam: Boolean;
    FCpuCycle: UInt64;
    FDataBus: UInt8;
    FInternalDataBus: UInt8;
    FHaltedCpuAddress: UInt16;
    FCpuAddress: UInt16;
    FTimedIo: Boolean;
    FPendingStrobe: UInt8;
    FStrobeDirty: Boolean;
    FCoinFrames: array[0..1] of Byte;
    FPendingCoins: array[0..1] of Integer;
    function GetHasCoinAcceptor: Boolean;
    function HasVsCoinInputs: Boolean;
    procedure UpdateSuperGameCoin;
    procedure InsertCoin(Player: Integer);
    procedure WriteControllers(Value: UInt8);
    function ReadController(Port: Integer): UInt8;
    function GetInternalRamMask: Word; inline;
    function ReadDevice(Address: UInt16): UInt8;
    function ReadCroakyPanel(Address: UInt16): UInt8;
  public
    property HasCoinAcceptor: Boolean read GetHasCoinAcceptor;
    property MiraclePiano: TMiraclePianoDevice read FMiraclePiano write FMiraclePiano;
    property DataRecorder: TFamicomDataRecorder read FDataRecorder write FDataRecorder;
    property TapeOnMapper: Boolean read FTapeOnMapper write FTapeOnMapper;
    property CroakyPanel: Boolean read FCroakyPanel write FCroakyPanel;
    procedure InsertCoin1;
    procedure InsertCoin2;
    procedure ClockCoinFrame;
    procedure SerializeCoins(State: TNesStateArchive);
    procedure SerializeState(State: TNesStateArchive);
    // Appended to the console snapshot after v4 fields for legacy compatibility.
    procedure SerializeDataBus(State: TNesStateArchive);
    procedure SerializeFamilyTrainer(State: TNesStateArchive);
    constructor Create;
    procedure Reset;
    procedure Connect(Cartridge: TCartridge; Ppu: TPpu; Apu: TApu; Controller1, Controller2: TController; Controller3: TController = nil; Controller4: TController = nil; SuborKeyboard: TSuborKeyboard = nil; FamicomKeyboard: TFamicomKeyboard = nil);
    function CpuRead(Address: UInt16): UInt8;
    function DmaRead(Address: UInt16): UInt8;
    function DmaTransferRead(Address: UInt16): UInt8;
    procedure CpuWrite(Address: UInt16; Value: UInt8);
    function IsDmaActive: Boolean; inline;
    procedure ClockDma(CpuCycleOdd: Boolean);
    function ClockUmDma: Boolean;
    procedure ClockIo; inline;
    function DebugCpuRead(Address: UInt16): UInt8;
    function PeekInternalRam(Address: Word): Byte;
    function PeekAchievementByte(Address: Word; out Value: Byte): Boolean;
    property InternalRamMask: Word read GetInternalRamMask;
    property CpuAddress: UInt16 read FCpuAddress write FCpuAddress;
    property CpuCycle: UInt64 read FCpuCycle write FCpuCycle;
    property DmaWritePending: Boolean read FDmaHaveData;
    property HaltedCpuAddress: UInt16 read FHaltedCpuAddress write FHaltedCpuAddress;
    property TimedIo: Boolean read FTimedIo write FTimedIo;
    property DisconnectedPads: Byte read FDisconnectedPads write FDisconnectedPads;
    property FamilyTrainer: TFamilyTrainerMode read FFamilyTrainer write FFamilyTrainer;
    property FourScoreEnabled: Boolean read FFourScoreEnabled write FFourScoreEnabled;
    property Zapper: TZapper read FZapper write FZapper;
  end;

implementation

uses
  System.Types, NES.Mapper, NES.Mapper.FlameCyclone, NES.DiskSystem,
  NES.Mapper.Nrom, NES.Mapper.Mmc1, NES.Mapper.Mmc3, NES.Mapper.Uxrom,
  NES.Mapper.Cnrom, NES.Mapper.Axrom, NES.Mapper.Banked, NES.Mapper.Discrete,
  NES.Mapper.Vrc;

function TNesBus.HasVsCoinInputs: Boolean;
begin
  Result := (FCartridge <> nil) and ((FCartridge.MapperId = MAPPER_VS_SYSTEM) or (FCartridge.Metadata.ConsoleType = 1));
end;

function TNesBus.GetHasCoinAcceptor: Boolean;
begin
  Result := (FSuperGameMega <> nil) or HasVsCoinInputs;
end;

procedure TNesBus.UpdateSuperGameCoin;
begin
  if FSuperGameMega <> nil then
    FSuperGameMega.SetCoinInput(FCoinFrames[0] > 4);
end;

procedure TNesBus.InsertCoin(Player: Integer);
begin
  if not HasCoinAcceptor then
    Exit;

  if FSuperGameMega <> nil then
    Player := 0;
  if FCoinFrames[Player] = 0 then
    FCoinFrames[Player] := 8
  else if FPendingCoins[Player] < High(Integer) then
    Inc(FPendingCoins[Player]);

  UpdateSuperGameCoin;
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
  // Four active frames and four idle frames separate consecutive coins.
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
  UpdateSuperGameCoin;
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
  if State.Loading then
    UpdateSuperGameCoin;
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
  State.Field(FRam, Integer(FRamMask) + 1);
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
  if FOneBus <> nil then
  begin
    State.Field(FDmaLimit, SizeOf(FDmaLimit));
    State.Field(FDmaSourceOffset, SizeOf(FDmaSourceOffset));
    State.Field(FDmaVideoRam, SizeOf(FDmaVideoRam));
  end;
end;

procedure TNesBus.SerializeFamilyTrainer(State: TNesStateArchive);
begin
  if State.Version >= 40 then
  begin
    State.Field(FFamilyTrainer, SizeOf(FFamilyTrainer));
    State.Field(FFamilyTrainerRows, SizeOf(FFamilyTrainerRows));
    if State.Loading and ((Ord(FFamilyTrainer) > Ord(High(TFamilyTrainerMode))) or
      (FFamilyTrainerRows > 7)) then
      raise ENesException.Create('Invalid Family Trainer snapshot state');
  end
  else if State.Loading then
    FFamilyTrainerRows := 0;
end;

constructor TNesBus.Create;
begin
  inherited Create;
  FRamMask := $07FF;
  FDmaLimit := 256;
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
  FFamilyTrainerRows := Value and 7;
  if FFcns <> nil then
  begin
    var Joypad: Byte := 0;
    for var Button := Low(TNesButton) to High(TNesButton) do
      if FController1.IsButtonPressed(Button) then
        Joypad := Joypad or Byte(1 shl Ord(Button));
    FFcns.WriteExpansionPad(Value, Joypad);
  end;
  if (FZapper <> nil) and FZapper.Enabled and FZapper.VsMode then
    FZapper.WriteVs(Value, FPpu.GetZapperMask^);
  if (FOneBus <> nil) and (FOneBus.Senario <> nil) then
    FController1.Write(Value, FOneBus.Senario.PenButton)
  else
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
  begin
    if (FDisconnectedPads and (1 shl Port)) <> 0 then
      Exit(0);
    Exit(Primary.Read);
  end;
  if FControllerStrobe then
  begin
    if (FDisconnectedPads and (1 shl Port)) <> 0 then
      Exit(0);
    Exit(Primary.Read and 1);
  end;

  var Index := FControllerReadIndex[Port];
  if Index < 8 then
    Result := (Primary.Read and 1) * Ord((FDisconnectedPads and (1 shl Port)) = 0)
  else if Index < 16 then
  begin
    if Extra <> nil then
      Result := (Extra.Read and 1) * Ord((FDisconnectedPads and (1 shl (Port + 2))) = 0)
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
  FCpuAddress := Address;
  if ((Address = $4032) or (Address = $E445)) and (FCartridge <> nil) then
  begin
    var Disk := FCartridge.DiskSystem;
    if Disk <> nil then
      if Address = $4032 then
        Disk.ObserveDiskStatusRead
      else
        Disk.CheckBiosDiskRequest;
  end;
  Result := ReadDevice(Address);
  FInternalDataBus := Result;
  // $4015 is internal to the CPU; it does not drive the external bus.
  if Address <> $4015 then
  begin
    FDataBus := Result;
    if FFcns <> nil then
      FFcns.ObserveCpuRead(Result);
  end;
end;

function TNesBus.DmaRead(Address: UInt16): UInt8;
begin
  FCpuAddress := Address;
  // DMA drives the external bus without replacing the CPU's internal latch.
  Result := ReadDevice(Address);
  if Address <> $4015 then
  begin
    FDataBus := Result;
    if FFcns <> nil then
      FFcns.ObserveCpuRead(Result);
  end;
end;

function TNesBus.DmaTransferRead(Address: UInt16): UInt8;
begin
  FCpuAddress := Address;
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

function TNesBus.ReadCroakyPanel(Address: UInt16): UInt8;
begin
  if (FController1 = nil) or ((FDisconnectedPads and 1) <> 0) then
    Exit(0);
  if Address = $4016 then
  begin
    Result := Ord(FController1.IsButtonPressed(TNesButton.Start) or
      FController1.IsButtonPressed(TNesButton.A)) or
      (Ord(FController1.IsButtonPressed(TNesButton.Select) or
        FController1.IsButtonPressed(TNesButton.B)) shl 1);
  end
  else
    Result := (Ord(FController1.IsButtonPressed(TNesButton.Up)) shl 1) or
      (Ord(FController1.IsButtonPressed(TNesButton.Left)) shl 2) or
      (Ord(FController1.IsButtonPressed(TNesButton.Down)) shl 3) or
      (Ord(FController1.IsButtonPressed(TNesButton.Right)) shl 4);
end;

function TNesBus.ReadDevice(Address: UInt16): UInt8;
begin
  if (FCoolGirl <> nil) and FCoolGirl.ReadResetInstruction(Result) then
    Exit;
  if (Address = $4011) and (FCartridge <> nil) and (FCartridge.Mapper <> nil) then
    if FCartridge.Mapper.CpuReadOpenBus(Address, FDataBus, Result) then
      Exit;
  if Address < $2000 then
  begin
    if (FOneBus <> nil) and FOneBus.FirmwareMapped(Address, Result) then
      Exit;
    Exit(FRam[Address and GetInternalRamMask]);
  end;
  if Address < $4000 then
  begin
    if (Address >= $3000) and (FOneBus <> nil) and FOneBus.HasVt369 then
      Exit(FPpu.ReadVt369NameTable(Address));
    Result := FPpu.CpuRead(Address);
    if (Address = $2002) and ((Result and $80) <> 0) and
      (FCartridge <> nil) and (FCartridge.Mapper <> nil) then
      FCartridge.Mapper.CpuIoRead(Address, Result);
    Exit;
  end;

  if FCroakyPanel and ((Address = $4016) or (Address = $4017)) then
    Exit(ReadCroakyPanel(Address));

  case Address of
    $4015:
      Exit((FApu.CpuReadStatus and $DF) or (FInternalDataBus and $20));
    $4016:
      begin
        if (FDancingExpert <> nil) and FDancingExpert.CpuRead(Address, Result) then
          Exit;
        if (FMiraclePiano <> nil) and FMiraclePiano.Connected then
          Exit(FMiraclePiano.Read or (FDataBus and $E0));
        if (FZapper <> nil) and FZapper.Enabled and FZapper.VsMode then
          Result := FZapper.ReadVs(FPpu.GetZapperMask^)
        else
          Result := ReadController(0);
        if FFcns <> nil then
          Result := Result or FFcns.ReadExpansionPad(FController1.IsButtonPressed(TNesButton.A));
        Result := (Result and $1F) or (FDataBus and $E0);
        if FDataRecorder <> nil then
        begin
          if not FTapeOnMapper then
            Result := Result or FDataRecorder.Read
          else if (FSuborKeyboard <> nil) and (FSuborKeyboard.Model = TNesKeyboardModel.Dongda) then
          begin
            var TapeSignal := FDataRecorder.Read;
            Result := Result or TapeSignal or (TapeSignal shl 1);
          end;
        end;
        if FCoolGirl <> nil then
          FCoolGirl.ObserveController(Result);
        if (FUm6578 <> nil) and (FUm6578.Expansion = $2F) then
          Result := (Result and $FC) or FUm6578.ReadGun;
        if (FOneBus <> nil) and (FOneBus.Senario <> nil) then
          Result := FOneBus.Senario.ReadController(Result);
        // VS coin slots are independent live inputs on $4016 bits 5 and 6.
        if HasVsCoinInputs then
        begin
          Result := Result and $1F;
          if FCoinFrames[0] > 4 then
            Result := Result or $20;
          if FCoinFrames[1] > 4 then
            Result := Result or $40;
        end;
        Exit;
      end;
    $4026:
      if (FUm6578 <> nil) and (FUm6578.Expansion = $38) and (FController1 <> nil) then
      begin
        var Pad: Byte := 0;
        for var Button := Low(TNesButton) to High(TNesButton) do
          if FController1.IsButtonPressed(Button) then
            Pad := Pad or (1 shl Ord(Button));
        if FUm6578.ReadBandaiPad(Pad, Result) then
          Exit;
      end;
    $4017:
      begin
        if (FDancingExpert <> nil) and FDancingExpert.CpuRead(Address, Result) then
          Exit;
        if (FMiraclePiano <> nil) and FMiraclePiano.Connected then
          FMiraclePiano.ReadOtherPort;
        // Zapper replaces port 2, including Power Pad/Four Score/keyboard.
        // Parallel inputs are live and independent of $4016 strobes.
        if (FZapper <> nil) and FZapper.Enabled and not FZapper.VsMode then
          Exit((FZapper.Read(FPpu.GetZapperMask^) and $1F) or (FDataBus and $E0));
        // Vs. hardware drives the DIP-switch lines; default switches are off.
        // NES open bus on D5-D7 must not become random Vs. DIP settings.
        if HasVsCoinInputs then
          Exit(ReadController(1) and 1);
        Result := ReadController(1);
        if FFamilyTrainer <> TFamilyTrainerMode.ftDisconnected then
          Exit((Result and 1) or FController2.ReadFamilyTrainer(FFamilyTrainerRows, FFamilyTrainer) or
            (FDataBus and $E0));
        var DrivenBits: Byte := $1F;
        if FSuborKeyboard <> nil then
        begin
          Result := Result or FSuborKeyboard.Read;
          if FSuborKeyboard.Connected and (FSuborKeyboard.Model = TNesKeyboardModel.Sonic) then
          begin
            DrivenBits := $5F;
            if FDataRecorder <> nil then
              Result := Result or (FDataRecorder.Read shl 1);
          end;
        end;
        if FFamicomKeyboard <> nil then
          Result := Result or FFamicomKeyboard.Read;
        Result := (Result and DrivenBits) or (FDataBus and not DrivenBits);
        if FOneBus <> nil then
          Result := FOneBus.Controller2Input(Result);
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
  FCpuAddress := Address;
  FDataBus := Value;
  FInternalDataBus := Value;
  if FFcns <> nil then
    FFcns.ObserveCpuWrite(Address, Value);
  if (FCartridge <> nil) and (FCartridge.Mapper <> nil) then
    FCartridge.Mapper.ClockCpuWrite;
  if Address < $2000 then
  begin
    var FirmwareByte: Byte;
    if (FOneBus <> nil) and FOneBus.FirmwareMapped(Address, FirmwareByte) then
      Exit;
    FRam[Address and GetInternalRamMask] := Value;
    if (FCartridge <> nil) and (FCartridge.Mapper <> nil) then
      FCartridge.Mapper.CpuRamWrite(Address and $7FF, Value);
    Exit;
  end;
  if Address < $4000 then
  begin
    if (Address >= $3000) and (FOneBus <> nil) and FOneBus.HasVt369 then
    begin
      FPpu.WriteVt369NameTable(Address, Value);
      Exit;
    end;
    FPpu.CpuWrite(Address, Value);
    if (FCartridge <> nil) and (FCartridge.Mapper <> nil) then
      FCartridge.Mapper.CpuIoWrite(Address, Value);
    Exit;
  end;

  case Address of
    $5000..$57FF:
      if (FOneBus <> nil) and FOneBus.HasVt369 then
      begin
        FPpu.WriteVt369Palette(Address, Value);
        Exit;
      end;
    $5800..$5FFF:
      if (FOneBus <> nil) and FOneBus.HasVt369 then
      begin
        FPpu.WriteVt369Oam(Address and $1FF, Value);
        Exit;
      end;
    $4000..$4013, $4015, $4017:
      begin
        if (FOneBus = nil) or not (FOneBus.HasVt32 or FOneBus.HasVt369) or
          not FOneBus.CpuWrite(Address, Value) then
          FApu.CpuWrite(Address, Value);
        Exit;
      end;
    $4201:
      if (FOneBus <> nil) and FOneBus.HasVt369 then
      begin
        for var Index := 0 to $1FF do
          FPpu.WriteVt369Oam(Index, DmaRead((Integer(Value) * 256 + Index) and $FFFF));
        FPpu.SelectVt389Oam;
        Exit;
      end;
    $4014:
      begin
        if (FCartridge <> nil) and (FCartridge.Mapper is TMapperMmc5) then
          FCartridge.Mapper.CpuIoWrite(Address, Value);
        if (FOneBus <> nil) and FOneBus.HasVt369 and FOneBus.FastCpu then
        begin
          var Control := FOneBus.DmaControl;
          var Count := 1 shl ((Control shr 1) and 7);
          if Count = 1 then
            Count := 256;
          var Source := (Integer(Value) shl 8) or FOneBus.DmaSourceLow;
          for var Index := 0 to Count - 1 do
          begin
            var Data := DmaRead((Source + Index) and $FFFF);
            if (Control and 1) <> 0 then
              FPpu.WriteVt369DmaVram(Data)
            else
              FPpu.CpuWrite($2004, Data);
          end;
          Exit;
        end;
        FDmaPage := Value;
        FDmaAddress := 0;
        if FOneBus <> nil then
        begin
          var Control := FOneBus.DmaControl;
          FDmaLimit := 1 shl ((Control shr 1) and 7);
          if FDmaLimit = 1 then
            FDmaLimit := 256;
          FDmaSourceOffset := FOneBus.DmaSourceLow;
          FDmaVideoRam := (Control and 1) <> 0;
        end;
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
        begin
          if not FTapeOnMapper then
            FDataRecorder.Write(Value)
          else if (FSuborKeyboard <> nil) and
            (FSuborKeyboard.Model in [TNesKeyboardModel.Dongda, TNesKeyboardModel.Sonic]) then
            FDataRecorder.Write(4 or ((Value shr 1) and 1));
        end;
        if (FUm6578 <> nil) and FUm6578.GunStrobeDue then
        begin
          var Pixel := TPoint.Create(-1, -1);
          if (FZapper <> nil) and FZapper.Enabled and Assigned(FZapper.OnReadPosition) then
            Pixel := FZapper.OnReadPosition();
          FUm6578.LatchGun(Pixel.X, Pixel.Y, (FZapper <> nil) and FZapper.TriggerPressed,
            (FController1 <> nil) and FController1.IsButtonPressed(TNesButton.B));
        end;
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

function TNesBus.ClockUmDma: Boolean;
var
  Source, Destination: Word;
  ToCpu: Boolean;
  Data: Byte;
begin
  Result := FUm6578.DmaTransfer(FPpu.UmVramAvailable, Source, Destination, ToCpu, Data);
  if not Result then
    Exit;
  if (Source and $8000) = 0 then
    Data := DmaRead(Source);
  if ToCpu then
    CpuWrite(Destination, Data)
  else
    FUm6578.PpuWrite(Destination, Data);
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
    FDmaData := DmaTransferRead((UInt16(FDmaPage) shl 8) or FDmaSourceOffset or FDmaAddress);
    FDmaHaveData := True;
  end
  else if FDmaHaveData then
  begin
    FDmaHaveData := False;
    FDataBus := FDmaData;
    FInternalDataBus := FDmaData;
    if FDmaVideoRam then
    begin
      FCpuAddress := $2007;
      FPpu.CpuWrite(FCpuAddress, FDmaData);
    end
    else
    begin
      FCpuAddress := $2004;
      FPpu.WriteOamDma(FDmaAddress, FDmaData);
    end;
    FDmaAddress := (FDmaAddress + 1) and $FF;
    if (FDmaAddress = 0) or (FDmaAddress = FDmaLimit) then
    begin
      FDmaActive := False;
      FDmaDummy := True;
      FDmaAlign := False;
    end;
  end;
end;

procedure TNesBus.Reset;
begin
  FOneBus := nil;
  FFcns := nil;
  if (FCartridge <> nil) and (FCartridge.Mapper is TMapperFcns) then
    FFcns := TMapperFcns(FCartridge.Mapper);
  FSuperGameMega := nil;
  FCoolGirl := nil;
  if (FCartridge <> nil) and (FCartridge.Mapper is TMapperCoolGirl) then
    FCoolGirl := TMapperCoolGirl(FCartridge.Mapper);
  FRamMask := $07FF;
  FUm6578 := nil;
  FSuborSb2000 := nil;
  FDancingExpert := nil;
  if (FCartridge <> nil) and (FCartridge.Mapper is TMapperFlameCyclone) then
    TMapperFlameCyclone(FCartridge.Mapper).ConnectCpu(CpuRead, CpuWrite);
  if (FCartridge <> nil) and (FCartridge.Mapper is TMapperDancingExpert) then
  begin
    FDancingExpert := TMapperDancingExpert(FCartridge.Mapper);
    FDancingExpert.ConnectPanel(FController1);
  end;
  if (FCartridge <> nil) and (FCartridge.Mapper is TMapperUm6578) then
  begin
    FUm6578 := TMapperUm6578(FCartridge.Mapper);
    if FUm6578 is TMapperSuborSb2000 then
      FSuborSb2000 := TMapperSuborSb2000(FUm6578);
    FRamMask := $1FFF;
  end;
  if (FCartridge <> nil) and (FCartridge.Mapper is TMapperOneBus) then
  begin
    FOneBus := TMapperOneBus(FCartridge.Mapper);
    if FOneBus.HasVt369 then
      FRamMask := $1FFF
    else if FOneBus.Has4KiBRam then
      FRamMask := $0FFF;
  end
  else if (FCartridge <> nil) and (FCartridge.Mapper is TMapperSuperGameMega) then
  begin
    FSuperGameMega := TMapperSuperGameMega(FCartridge.Mapper);
    FRamMask := $0FFF;
  end;
  FDmaLimit := 256;
  FDmaSourceOffset := 0;
  FDmaVideoRam := False;
  FillChar(FCoinFrames, SizeOf(FCoinFrames), 0);
  FillChar(FPendingCoins, SizeOf(FPendingCoins), 0);
  UpdateSuperGameCoin;
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

function TNesBus.GetInternalRamMask: Word;
begin
  if (FSuborSb2000 <> nil) and FSuborSb2000.RamBoot then
    Exit($07FF);
  Result := FRamMask;
end;

function TNesBus.PeekInternalRam(Address: Word): Byte;
begin
  Result := FRam[Address and GetInternalRamMask];
end;

function TNesBus.PeekAchievementByte(Address: Word; out Value: Byte): Boolean;
type
  TMapperRead = function(Address: UInt16; out Value: UInt8): Boolean of object;
begin
  if Address < $2000 then
  begin
    Value := PeekInternalRam(Address);
    Exit(True);
  end;
  if (Address < $4020) or (FCartridge = nil) or (FCartridge.Mapper = nil) then
    Exit(False);

  var Mapper := FCartridge.Mapper;
  if Mapper.CpuPeek(Address, Value) then
    Exit(True);

  // Look at the implementation, since descendants may override CpuRead with side effects.
  var Read: TMapperRead := Mapper.CpuRead;
  var ReadCode := TMethod(Read).Code;
  if (ReadCode = @TMapperNrom.CpuRead) or (ReadCode = @TMapperMmc1.CpuRead) or
    (ReadCode = @TMapperMmc3.CpuRead) or (ReadCode = @TMapperUxrom.CpuRead) or
    (ReadCode = @TMapperCnrom.CpuRead) or (ReadCode = @TMapperAxrom.CpuRead) or
    (ReadCode = @TMapperBanked.CpuRead) or (ReadCode = @TMapperDiscrete.CpuRead) or
    (ReadCode = @TMapperVrc.CpuRead) then
    Exit(Read(Address, Value));
  Result := False;
end;

function TNesBus.DebugCpuRead(Address: UInt16): UInt8;
begin
  // Inspecting RAM must not drive the emulated CPU data bus.
  if Address < $2000 then
  begin
    if (FOneBus <> nil) and FOneBus.FirmwareMapped(Address, Result) then
      Exit;
    Exit(FRam[Address and GetInternalRamMask]);
  end;

  if (FCartridge <> nil) and (FCartridge.Mapper <> nil) and
    FCartridge.Mapper.CpuPeek(Address, Result) then
    Exit;

  if (Address = $2002) and (FCartridge <> nil) and (FCartridge.Mapper is TMapperMmc5) then
    Exit(FPpu.DebugStatus);

  // Debugger inspection is not evidence of a game requesting a new side.
  if ((Address = $4032) or (Address = $E445)) and (FCartridge <> nil) and
    (FCartridge.DiskSystem <> nil) then
    Exit(ReadDevice(Address));
  Result := CpuRead(Address);
end;

end.

