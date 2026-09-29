unit NES.Bus;

interface

uses
  NES.State, NES.Types, NES.PPU, NES.Cartridge, NES.Controller, NES.APU;

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
    procedure WriteControllers(Value: UInt8);
    function ReadController(Port: Integer): UInt8;
  public
    procedure SerializeState(State: TNesStateArchive);
    constructor Create;
    procedure Reset;
    procedure Connect(Cartridge: TCartridge; Ppu: TPpu; Apu: TApu; Controller1, Controller2: TController; Controller3: TController = nil; Controller4: TController = nil; SuborKeyboard: TSuborKeyboard = nil);
    function CpuRead(Address: UInt16): UInt8;
    procedure CpuWrite(Address: UInt16; Value: UInt8);
    function IsDmaActive: Boolean;
    procedure ClockDma(CpuCycleOdd: Boolean);
    function DebugCpuRead(Address: UInt16): UInt8;
    property CpuCycle: UInt64 read FCpuCycle write FCpuCycle;
    property DmaWritePending: Boolean read FDmaHaveData;
    property FourScoreEnabled: Boolean read FFourScoreEnabled write FFourScoreEnabled;
  end;

implementation

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

procedure TNesBus.Connect(Cartridge: TCartridge; Ppu: TPpu; Apu: TApu; Controller1, Controller2, Controller3, Controller4: TController; SuborKeyboard: TSuborKeyboard);
begin
  FCartridge := Cartridge;
  FPpu := Ppu;
  FApu := Apu;
  FController1 := Controller1;
  FController2 := Controller2;
  FController3 := Controller3;
  FController4 := Controller4;
  FSuborKeyboard := SuborKeyboard;
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
  if Address < $2000 then
    Exit(FRam[Address and $07FF]);
  if Address < $4000 then
    Exit(FPpu.CpuRead($2000 or (Address and 7)));

  case Address of
    $4015:
      Exit(FApu.CpuReadStatus);
    $4016:
      Exit(ReadController(0));
    $4017:
      begin
        Result := ReadController(1);
        if FSuborKeyboard <> nil then
          Result := Result or FSuborKeyboard.Read;
        Exit;
      end;
  end;

  var Value: UInt8;
  if (FCartridge <> nil) and (FCartridge.Mapper <> nil) and FCartridge.Mapper.CpuRead(Address, Value) then
    Exit(Value);
  Result := 0;
end;

procedure TNesBus.CpuWrite(Address: UInt16; Value: UInt8);
begin
  if (FCartridge <> nil) and (FCartridge.Mapper <> nil) then
    FCartridge.Mapper.ClockCpuWrite;
  if Address < $2000 then
  begin
    FRam[Address and $07FF] := Value;
    Exit;
  end;
  if Address < $4000 then
  begin
    FPpu.CpuWrite($2000 or (Address and 7), Value);
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
        WriteControllers(Value);
        if FSuborKeyboard <> nil then
          FSuborKeyboard.Write(Value);
        if (FCartridge <> nil) and (FCartridge.Mapper <> nil) then
          FCartridge.Mapper.CpuWriteTimed(Address, Value, FCpuCycle);
        Exit;
      end;
  end;

  if (FCartridge <> nil) and (FCartridge.Mapper <> nil) and FCartridge.Mapper.CpuWriteTimed(Address, Value, FCpuCycle) then
    Exit;
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
    FDmaData := CpuRead((UInt16(FDmaPage) shl 8) or FDmaAddress);
    FDmaHaveData := True;
  end
  else if FDmaHaveData then
  begin
    FDmaHaveData := False;
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
  if (FController1 <> nil) and (FController2 <> nil) then
  begin
    WriteControllers(1);
    WriteControllers(0);
  end;
end;

function TNesBus.DebugCpuRead(Address: UInt16): UInt8;
begin
  Result := CpuRead(Address);
end;

end.

