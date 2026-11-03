unit A5200.Console;

interface

uses
  System.SysUtils, A5200.Types, A5200.CPU, A5200.Cartridge, A5200.ANTIC,
  A5200.GTIA, A5200.POKEY, A5200.Controller, Core.Emulation.Types,
  Core.Snapshots;

type
  TA5200Console = class
  private
    FCPU: TCPU5200;
    FCartridge: TA5200Cartridge;
    FANTIC: TA5200ANTIC;
    FGTIA: TA5200GTIA;
    FPOKEY: TA5200POKEY;
    FController: TA5200Controller;
    FRAM: array[0..$3FFF] of Byte;
    FBIOS: TBytes;
    FBus: Byte;
    FFrame: TEmulatorFrame;
    FSamples: TArray<SmallInt>;
  public
    constructor Create(const Data, BIOS: TBytes; MapperHint: Integer = -1);
    destructor Destroy; override;
    procedure Reset;
    procedure SetInput(const Input: TEmulatorInput);
    procedure SetKeypad(Port: Integer; Mask: Word);
    function ReadMemory(Address: Word): Byte;
    procedure WriteMemory(Address: Word; Value: Byte);
    procedure RunFrame;
    procedure SerializeState(State: TStateArchive);
    function GetRate: Double;
    property Frame: TEmulatorFrame read FFrame;
    property Samples: TArray<SmallInt> read FSamples;
    property CPU: TCPU5200 read FCPU;
    property Rate: Double read GetRate;
  end;

implementation

uses
  System.Classes, NES.CPU, System.UITypes;

constructor TA5200Console.Create(const Data, BIOS: TBytes; MapperHint: Integer);
begin
  inherited Create;
  if Length(BIOS) <> 2048 then
    raise EReadError.Create('Atari 5200 BIOS must be 2048 bytes');
  FBIOS := Copy(BIOS);
  FCartridge := TA5200Cartridge.Create(Data, MapperHint);
  FController := TA5200Controller.Create;
  FGTIA := TA5200GTIA.Create;
  FPOKEY := TA5200POKEY.Create;
  FANTIC := TA5200ANTIC.Create(ReadMemory);
  FCPU := TCPU5200.Create;
  FCPU.Connect(ReadMemory, WriteMemory);
  FFrame.Width := A5200Width;
  FFrame.Height := A5200Height;
  SetLength(FFrame.Pixels, A5200Width * A5200Height);
  Reset;
end;

destructor TA5200Console.Destroy;
begin
  FCPU.Free;
  FANTIC.Free;
  FPOKEY.Free;
  FGTIA.Free;
  FController.Free;
  FCartridge.Free;
  inherited;
end;

procedure TA5200Console.Reset;
begin
  FillChar(FRAM, SizeOf(FRAM), 0);
  FBus := $FF;
  FCartridge.Reset;
  FGTIA.Reset;
  FANTIC.Reset;
  FPOKEY.Reset;
  FCPU.Reset;
  FFrame.FrameNumber := 0;
  FFrame.Pixels := Copy(FFrame.Pixels);
  for var I := 0 to High(FFrame.Pixels) do
    FFrame.Pixels[I] := $FF000000;
end;

procedure TA5200Console.SetInput(const Input: TEmulatorInput);
begin
  FController.SetInput(Input);
end;

procedure TA5200Console.SetKeypad(Port: Integer; Mask: Word);
begin
  FController.SetKeypad(Port, Mask);
end;

function TA5200Console.ReadMemory(Address: Word): Byte;
begin
  Result := FBus;
  if Address < $4000 then
    Result := FRAM[Address]
  else if Address < $C000 then
    Result := FCartridge.Read(Address)
  else if Address and $F000 = $C000 then
    Result := FGTIA.Read(Address and 31, FController)
  else if Address and $FF00 = $D400 then
    Result := FANTIC.Read(Address and 15)
  else if Address and $F800 = $E800 then
    Result := FPOKEY.Read(Address and 15, FController, FGTIA.ConsoleControl and 3, FGTIA.ConsoleControl and 4 <> 0)
  else if Address >= $F000 then
    // The 2K kernel ROM is selected throughout F000..FFFF; A11 is a mirror.
    Result := FBIOS[Address and $7FF];
  FBus := Result;
end;

procedure TA5200Console.WriteMemory(Address: Word; Value: Byte);
begin
  FBus := Value;
  if Address < $4000 then
    FRAM[Address] := Value
  else if Address < $C000 then
    FCartridge.Access(Address)
  else if Address and $F000 = $C000 then
    FGTIA.Write(Address and 31, Value)
  else if Address and $FF00 = $D400 then
    FANTIC.Write(Address and 15, Value)
  else if Address and $F800 = $E800 then
    FPOKEY.Write(Address and 15, Value, FController);
end;

function TA5200Console.GetRate: Double;
begin
  Result := A5200CPUClock / (A5200CyclesPerLine * A5200LinesPerFrame);
end;

procedure TA5200Console.RunFrame;
begin
  FFrame.Pixels := Copy(FFrame.Pixels);
  FPOKEY.BeginFrame;
  for var Line := 0 to A5200LinesPerFrame - 1 do
  begin
    FANTIC.BeginLine(Line, FGTIA);
    var Pixels := FANTIC.Output;
    for var Cycle := 0 to A5200CyclesPerLine - 1 do
    begin
      if (Cycle = 7) and FANTIC.TakeNMI then
        FCPU.TriggerNmi;
      FCPU.SetIrqLine(FPOKEY.IRQ);
      if not FANTIC.Halted(Cycle) or FCPU.NextCycleIsWrite then
        FCPU.Clock;
      if FCPU.Jammed then
        raise EInvalidOpException.CreateFmt('Atari 5200 CPU jam at %.4x', [FCPU.JamPc]);
      FPOKEY.Clock(FController, FGTIA.ConsoleControl and 3);
      if (Line >= 8) and (Line < 248) then
        for var P := 0 to 3 do
        begin
          var X := Cycle * 4 + P;
          if (X >= 64) and (X < 448) then
            FFrame.Pixels[(Line - 8) * A5200Width + X - 64] := FGTIA.Pixel(X, Pixels[X]);
        end;
    end;
    FANTIC.EndLine;
  end;
  FPOKEY.EndFrame(FSamples);
  Inc(FFrame.FrameNumber);
  FFrame.FramesPerSecond := Rate;
end;

procedure TA5200Console.SerializeState(State: TStateArchive);
begin
  State.Field(FRAM, SizeOf(FRAM));
  State.Field(FBus, SizeOf(FBus));
  State.Field(FFrame.FrameNumber, SizeOf(UInt64));
  FCPU.SerializeState(State);
  FCartridge.SerializeState(State);
  FANTIC.SerializeState(State);
  FGTIA.SerializeState(State);
  FPOKEY.SerializeState(State);
  FFrame.Pixels := Copy(FFrame.Pixels);
  State.Field(FFrame.Pixels[0], Length(FFrame.Pixels) * SizeOf(TAlphaColor));
end;

end.

