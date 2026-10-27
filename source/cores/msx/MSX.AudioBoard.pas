unit MSX.AudioBoard;

interface

uses
  System.SysUtils, System.Classes, System.Math, Core.Snapshots, Core.AudioFilter,
  Yamaha.Sound.Y8950;

type
  TMSXAudioBoard = class
  private
    FChip: TY8950;
    FROM: TBytes;
    FPanasonic: Boolean;
    FBank, FPorts, FDACValue: Byte;
    FWork: array[0..$FFF] of Byte;
    FMIDIControl, FMIDIRX, FMIDITX: Byte;
    FRXReady, FOverrun: Boolean;
    FTXClocks: Integer;
    FTransmitted: TBytes;
    FDC: TPCMDCBlocker;
    function GPIO: Byte;
    function AssignedPort(Port: Byte): Boolean;
  public
    constructor Create(const ROM: TBytes; Panasonic: Boolean; SampleRAM: Integer = 32768);
    destructor Destroy; override;
    procedure Reset;
    procedure ConfigureSampleRAM(Bytes: Integer);
    function ReadMemory(Address: Word): Byte;
    procedure WriteMemory(Address: Word; Value: Byte);
    function ReadPort(Port: Byte): Byte;
    procedure WritePort(Port, Value: Byte);
    procedure AdvanceClocks(Cycles: Integer);
    function Interrupt: Boolean;
    function Sample: SmallInt;
    procedure ReceiveMIDI(Value: Byte);
    function TakeMIDI: TBytes;
    procedure SerializeState(State: TStateArchive);
    property Chip: TY8950 read FChip;
  end;

implementation

constructor TMSXAudioBoard.Create(const ROM: TBytes; Panasonic: Boolean; SampleRAM: Integer);
begin
  inherited Create;
  if (Panasonic and (Length(ROM) <> $20000)) or (not Panasonic and (Length(ROM) <> $8000)) then
    raise EReadError.Create('MSX-AUDIO requires a 128 KiB FS-CA1 or 32 KiB NMS1205 ROM');
  FROM := Copy(ROM);
  FPanasonic := Panasonic;
  FChip := TY8950.Create(SampleRAM);
  FDC.Configure(44100, 20);
  Reset;
end;

destructor TMSXAudioBoard.Destroy;
begin
  FChip.Free;
  inherited;
end;

procedure TMSXAudioBoard.Reset;
begin
  FChip.Reset;
  FBank := 0;
  FPorts := 0;
  FDACValue := 128;
  FDC.Reset;
  FMIDIControl := 0;
  FMIDIRX := 0;
  FMIDITX := 0;
  FRXReady := False;
  FOverrun := False;
  FTXClocks := 0;
  FTransmitted := nil;
  if not FPanasonic then
    FChip.GPIOInput := 8;
end;

procedure TMSXAudioBoard.ConfigureSampleRAM(Bytes: Integer);
begin
  var NewChip := TY8950.Create(Bytes);
  FChip.Free;
  FChip := NewChip;
  if not FPanasonic then
    FChip.GPIOInput := 8;
end;

function TMSXAudioBoard.ReadMemory(Address: Word): Byte;
begin
  Result := $FF;
  if FPanasonic then
  begin
    if (FBank = 0) and (Address and $3FFF >= $3000) then
      Result := FWork[Address and $FFF]
    else
      Result := FROM[Integer(FBank) * $8000 + (Address and $7FFF)];
  end
  else if (Address >= $4000) and (Address < $C000) then
    Result := FROM[Address - $4000];
end;

procedure TMSXAudioBoard.WriteMemory(Address: Word; Value: Byte);
begin
  if not FPanasonic then
    Exit;
  // Datapack Vol.2-4.1: write-only bank and port selectors, with RAM visible on reads.
  case Address and $3FFF of
    $3FFE:
      FBank := Value and 3;
    $3FFF:
      FPorts := Value and 3;
  end;
  if (FBank = 0) and (Address and $3FFF >= $3000) then
    FWork[Address and $FFF] := Value;
end;

function TMSXAudioBoard.GPIO: Byte;
begin
  Result := (FChip.RegisterValue($18) and FChip.RegisterValue($19)) or
    (FChip.GPIOInput and not FChip.RegisterValue($18));
end;

function TMSXAudioBoard.AssignedPort(Port: Byte): Boolean;
begin
  if not FPanasonic then
    Result := Port and $FE = $C0
  else
    Result := ((Port and $FE = $C0) and (FPorts and 1 <> 0)) or
      ((Port and $FE = $C2) and (FPorts and 2 <> 0));
end;

function TMSXAudioBoard.ReadPort(Port: Byte): Byte;
begin
  Result := $FF;
  if AssignedPort(Port) then
    Exit(FChip.ReadPort(Port and 1));
  if not FPanasonic and (Port and $E6 = 4) then
    if Port and 1 = 0 then
    begin
      Result := Ord(FRXReady) or (Ord(FTXClocks = 0) shl 1) or (Ord(FOverrun) shl 5);
      if (FRXReady and (FMIDIControl and $80 <> 0)) or
        ((FTXClocks = 0) and (FMIDIControl and $60 = $20)) then
        Result := Result or $80;
    end
    else
    begin
      Result := FMIDIRX;
      FRXReady := False;
      FOverrun := False;
    end;
end;

procedure TMSXAudioBoard.WritePort(Port, Value: Byte);
begin
  if AssignedPort(Port) then
    FChip.WritePort(Port and 1, Value);
  if not FPanasonic then
  begin
    // The Music Module decodes DAC/MIDI ports incompletely; mirrors overlap.
    if Port and $E8 = 8 then
      FDACValue := Value;
    if Port and $E6 = 0 then
      if Port and 1 = 0 then
      begin
        FMIDIControl := Value;
        if Value and 3 = 3 then
        begin
          FRXReady := False;
          FOverrun := False;
          FTXClocks := 0;
        end;
      end
      else
      begin
        FMIDITX := Value;
        FTXClocks := 1146;
      end;
  end;
end;

procedure TMSXAudioBoard.AdvanceClocks(Cycles: Integer);
begin
  FChip.AdvanceClocks(Cycles);
  if FTXClocks > 0 then
  begin
    Dec(FTXClocks, Cycles);
    if FTXClocks <= 0 then
    begin
      FTXClocks := 0;
      if Length(FTransmitted) < 65536 then
        FTransmitted := FTransmitted + TBytes.Create(FMIDITX);
    end;
  end;
end;

procedure TMSXAudioBoard.ReceiveMIDI(Value: Byte);
begin
  if FRXReady then
    FOverrun := True
  else
  begin
    FMIDIRX := Value;
    FRXReady := True;
  end;
end;

function TMSXAudioBoard.TakeMIDI: TBytes;
begin
  Result := FTransmitted;
  FTransmitted := nil;
end;

function TMSXAudioBoard.Interrupt: Boolean;
begin
  Result := FChip.Interrupt;
  if not FPanasonic then
    Result := Result or (ReadPort(4) and $80 <> 0);
end;

function TMSXAudioBoard.Sample: SmallInt;
begin
  // Datapack table 7.44: IO3 selects the analogue FM/PCM filter. It is
  // not a digital mute: AUDIO BASIC leaves it high during PCM playback.
  var V := Integer(FChip.Sample);
  var DAC := 0;
  if not FPanasonic and (GPIO and 1 <> 0) then
    DAC := (Integer(FDACValue) - 128) * 128;
  Result := EnsureRange(V + Round(FDC.Process(DAC)), -32768, 32767);
end;

procedure TMSXAudioBoard.SerializeState(State: TStateArchive);
begin
  State.Field(FBank, 1);
  State.Field(FPorts, 1);
  State.Field(FDACValue, 1);
  State.Field(FWork, SizeOf(FWork));
  State.Field(FMIDIControl, 1);
  State.Field(FMIDIRX, 1);
  State.Field(FMIDITX, 1);
  State.Field(FRXReady, SizeOf(FRXReady));
  State.Field(FOverrun, SizeOf(FOverrun));
  State.Field(FTXClocks, SizeOf(FTXClocks));
  var N := Length(FTransmitted);
  State.Field(N, SizeOf(N));
  if (N < 0) or (N > 65536) then
    raise EReadError.Create('Invalid MIDI output state');
  if State.Loading then
    SetLength(FTransmitted, N);
  if N > 0 then
    State.Field(FTransmitted[0], N);
  State.Field(FDC, SizeOf(FDC));
  FChip.SerializeState(State);
  if State.Loading and ((FBank > 3) or (FPorts > 3) or (FTXClocks < 0) or (FTXClocks > 1146)) then
    raise EReadError.Create('Invalid MSX-AUDIO board state');
end;

end.

