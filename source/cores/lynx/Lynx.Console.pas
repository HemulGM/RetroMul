unit Lynx.Console;

interface

uses
  System.SysUtils, System.UITypes, Lynx.Types, Lynx.Cartridge, Lynx.Mikey,
  Lynx.Suzy, HW.W65C02, Core.Emulation.Types, Core.Snapshots;

type
  TLynxConsole = class
  private
    FRAM: TLynxRAM;
    FBIOS: TBytes;
    FCartridge: TLynxCartridge;
    FCPU: TW65C02;
    FMikey: TLynxMikey;
    FSuzy: TLynxSuzy;
    FMap: Byte;
    FTime: Int64;
    FFrames: UInt64;
    FCPUSleep, FPowerOff: Boolean;
    FExtraTicks: Integer;
    FRotation: Integer;
    FRotatedPixels: TArray<TAlphaColor>;
    function EffectiveRotation: Integer;
    function GetPixels: TArray<TAlphaColor>;
    function GetSamples: TArray<SmallInt>;
    function GetSampleFrames: Integer;
    procedure Advance(Ticks: Integer);
  public
    constructor Create(const ROM, BIOS: TBytes);
    destructor Destroy; override;
    procedure Reset;
    function ReadByte(Address: Word): Byte;
    procedure WriteByte(Address: Word; Value: Byte);
    function Step: Integer;
    procedure RunFrame;
    procedure SetInput(const Buttons: TEmulatorButtons);
    function FramesPerSecond: Double;
    function FrameWidth: Integer;
    function FrameHeight: Integer;
    procedure SerializeState(State: TStateArchive);
    property CPU: TW65C02 read FCPU;
    property Mikey: TLynxMikey read FMikey;
    property Suzy: TLynxSuzy read FSuzy;
    property Cartridge: TLynxCartridge read FCartridge;
    property MasterTicks: Int64 read FTime;
    property FrameNumber: UInt64 read FFrames;
    property Pixels: TArray<TAlphaColor> read GetPixels;
    property Samples: TArray<SmallInt> read GetSamples;
    property SampleFrames: Integer read GetSampleFrames;
    // -1 follows cartridge metadata; 0 landscape, 1 left, 2 right.
    property Rotation: Integer read FRotation write FRotation;
  end;

implementation

uses
  System.Classes, System.Math;

constructor TLynxConsole.Create(const ROM, BIOS: TBytes);
begin
  inherited Create;
  if Length(BIOS) <> 512 then
    raise EReadError.Create('Lynx BIOS must contain exactly 512 bytes');
  FBIOS := Copy(BIOS);
  FRotation := -1;
  FCartridge := TLynxCartridge.Create(ROM);
  FMikey := TLynxMikey.Create(@FRAM);
  FSuzy := TLynxSuzy.Create(@FRAM, FCartridge);
  FCPU := TW65C02.Create(ReadByte, WriteByte);
  Reset;
end;

destructor TLynxConsole.Destroy;
begin
  FCPU.Free;
  FSuzy.Free;
  FMikey.Free;
  FCartridge.Free;
  inherited;
end;

procedure TLynxConsole.Reset;
begin
  FillChar(FRAM, SizeOf(FRAM), 0);
  FMap := 0;
  FTime := 0;
  FFrames := 0;
  FExtraTicks := 0;
  FCPUSleep := False;
  FPowerOff := False;
  FCartridge.Reset;
  FMikey.Reset;
  FSuzy.Reset;
  FCPU.Reset;
  if Length(FCartridge.BootData) <> 0 then
  begin
    // BS93 objects arrive through a running development loader. Supply its
    // standard 60 Hz display timing rather than the power-on timer state.
    FMikey.Write($00, $9E);
    FMikey.Write($01, $18);
    FMikey.Write($02, $9E);
    FMikey.Write($08, $68);
    FMikey.Write($09, $1F);
    FMikey.Write($0A, $68);
    FMikey.Write($92, $0D);
    FMikey.Write($93, $29);
    Move(FCartridge.BootData[0], FRAM[FCartridge.LoadAddress], Length(FCartridge.BootData));
    FCPU.PC := FCartridge.LoadAddress;
  end;
end;

function TLynxConsole.ReadByte(Address: Word): Byte;
begin
  if Address < $FC00 then
    Exit(FRAM[Address]);
  if (Address < $FD00) and (FMap and 1 = 0) then
  begin
    Inc(FExtraTicks, 5);
    Exit(FSuzy.Read(Address and 255));
  end;
  if (Address >= $FD00) and (Address < $FE00) and (FMap and 2 = 0) then
  begin
    Result := FMikey.Read(Address and 255);
    if (Address = $FD8B) and (FMikey.Read($8A) and $10 = 0) then
      Result := (Result and $EF) or (Ord(FCartridge.Audin) shl 4);
    Exit;
  end;
  if Address = $FFF9 then
    Exit(FMap);
  if ((Address >= $FE00) and (Address < $FFF8) and (FMap and 4 = 0)) or
    ((Address >= $FFFA) and (FMap and 8 = 0)) then
    Exit(FBIOS[Address and $1FF]);
  Result := FRAM[Address];
end;

procedure TLynxConsole.WriteByte(Address: Word; Value: Byte);
begin
  if (Address >= $FC00) and (Address < $FD00) and (FMap and 1 = 0) then
    FSuzy.Write(Address and 255, Value)
  else if (Address >= $FD00) and (Address < $FE00) and (FMap and 2 = 0) then
  begin
    FMikey.Write(Address and 255, Value);
    case Address of
      $FD87:
        begin
          FCartridge.AddressStrobe(Value and 1 <> 0);
          FPowerOff := Value and 2 = 0;
        end;
      $FD8A, $FD8B:
        begin
          FCartridge.AddressData(FMikey.Read($8B) and 2 <> 0);
          FCartridge.SetAudin((FMikey.Read($8A) and $10 = 0) or (FMikey.Read($8B) and $10 <> 0));
        end;
      $FD91:
        begin
          FSuzy.BeginSprites;
          FCPUSleep := FSuzy.SpriteTicks > 0;
        end;
    end;
  end
  else if Address = $FFF9 then
    FMap := Value
  else
    FRAM[Address] := Value;
end;

procedure TLynxConsole.Advance(Ticks: Integer);
begin
  Inc(FTime, Ticks);
  FMikey.Advance(Ticks);
  FSuzy.Advance(Ticks);
  if (FSuzy.SpriteTicks = 0) or (FMikey.IRQ <> 0) then
    FCPUSleep := False;
end;

function TLynxConsole.Step: Integer;
begin
  if FPowerOff or FCPUSleep then
    Result := 16
  else
  begin
    FExtraTicks := 0;
    var Cycles := 0;
    if FMikey.IRQ <> 0 then
      Cycles := FCPU.Interrupt;
    if Cycles = 0 then
      Cycles := FCPU.Step;
    Result := Cycles * 5 + FExtraTicks;
  end;
  Advance(Result);
end;

procedure TLynxConsole.RunFrame;
begin
  FMikey.BeginAudioFrame;
  var Frame := FMikey.FrameNumber;
  var Limit := FTime + Round(LynxMasterClock / EnsureRange(FramesPerSecond, 10.0, 200.0));
  repeat
    Step;
  until (FMikey.FrameNumber <> Frame) or (FTime >= Limit);
  Inc(FFrames);
end;

procedure TLynxConsole.SetInput(const Buttons: TEmulatorButtons);
const
  Directions: array[0..3] of TEmulatorButton = (TEmulatorButton.Up, TEmulatorButton.Right, TEmulatorButton.Down, TEmulatorButton.Left);
begin
  var Mapped := Buttons - [TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left, TEmulatorButton.Right];
  var Turn := 0;
  if EffectiveRotation = 1 then
    Turn := 1
  else if EffectiveRotation = 2 then
    Turn := 3;
  for var I := 0 to 3 do
    if Directions[I] in Buttons then
      Include(Mapped, Directions[(I + Turn) and 3]);
  var Joystick := 0;
  if TEmulatorButton.Up in Mapped then
    Joystick := Joystick or $40;
  if TEmulatorButton.Down in Mapped then
    Joystick := Joystick or $80;
  if TEmulatorButton.Left in Mapped then
    Joystick := Joystick or $10;
  if TEmulatorButton.Right in Mapped then
    Joystick := Joystick or $20;
  if TEmulatorButton.A in Buttons then
    Joystick := Joystick or 1;
  if TEmulatorButton.B in Buttons then
    Joystick := Joystick or 2;
  if TEmulatorButton.Select in Buttons then
    Joystick := Joystick or 8;
  if TEmulatorButton.C in Buttons then
    Joystick := Joystick or 4;
  FSuzy.SetInput(Joystick, Ord(TEmulatorButton.Start in Buttons));
end;

function TLynxConsole.EffectiveRotation: Integer;
begin
  Result := FRotation;
  if Result < 0 then
    Result := FCartridge.Rotation;
  if not (Result in [1, 2]) then
    Result := 0;
end;

function TLynxConsole.GetPixels: TArray<TAlphaColor>;
begin
  var Turn := EffectiveRotation;
  if Turn = 0 then
    Exit(FMikey.Pixels);
  SetLength(FRotatedPixels, LynxWidth * LynxHeight);
  for var Y := 0 to LynxHeight - 1 do
    for var X := 0 to LynxWidth - 1 do
      if Turn = 1 then
        FRotatedPixels[(LynxWidth - 1 - X) * LynxHeight + Y] := FMikey.Pixels[Y * LynxWidth + X]
      else
        FRotatedPixels[X * LynxHeight + LynxHeight - 1 - Y] := FMikey.Pixels[Y * LynxWidth + X];
  Result := FRotatedPixels;
end;

function TLynxConsole.GetSamples: TArray<SmallInt>;
begin
  Result := FMikey.Samples;
end;

function TLynxConsole.GetSampleFrames: Integer;
begin
  Result := FMikey.SampleFrames;
end;

function TLynxConsole.FramesPerSecond: Double;
begin
  Result := FMikey.FramesPerSecond;
end;

function TLynxConsole.FrameWidth: Integer;
begin
  if EffectiveRotation = 0 then
    Result := LynxWidth
  else
    Result := LynxHeight;
end;

function TLynxConsole.FrameHeight: Integer;
begin
  if EffectiveRotation = 0 then
    Result := LynxHeight
  else
    Result := LynxWidth;
end;

procedure TLynxConsole.SerializeState(State: TStateArchive);
begin
  State.Field(FRAM, SizeOf(FRAM));
  State.Field(FMap, SizeOf(FMap));
  State.Field(FTime, SizeOf(FTime));
  State.Field(FFrames, SizeOf(FFrames));
  State.Field(FCPUSleep, SizeOf(FCPUSleep));
  State.Field(FPowerOff, SizeOf(FPowerOff));
  FCPU.SerializeState(State);
  FCartridge.SerializeState(State);
  FMikey.SerializeState(State);
  FSuzy.SerializeState(State);
end;

end.

