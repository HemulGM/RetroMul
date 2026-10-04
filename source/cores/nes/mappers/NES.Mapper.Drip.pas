unit NES.Mapper.Drip;

interface

uses
  NES.State, NES.Types, NES.Mapper, NES.Mapper.Banked;

type
  TDripChannel = record
    Buffer: array[0..255] of Byte;
    ReadPos, WritePos, Period, Timer, Volume, Output: Integer;
    Full, Empty: Boolean;
  end;

  PDripChannel = ^TDripChannel;

  TMapperDrip = class(TMapperBanked)
  private
    FChannels: array[0..1] of TDripChannel;
    FAttributes, FNames: array[0..$7FF] of Byte;
    FLow, FCounter, FLastTile, FControl: Integer;
    FEnabled, FPending: Boolean;
    function NameBank(Address: UInt16): Integer;
    procedure WriteAudio(Channel, Reg: Integer; Value: Byte);
  public
    constructor Create(const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
    procedure Reset; override;
    procedure SerializeState(State: TNesStateArchive); override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function PpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function PpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    procedure ClockCpu; override;
    function IrqPending: Boolean; override;
    function ExpansionAudio: Double; override;
  end;

implementation

constructor TMapperDrip.Create(const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
begin
  inherited;
  Reset
end;

procedure TMapperDrip.Reset;
begin
  inherited;
  FLow := 0;
  FCounter := 0;
  FLastTile := 0;
  FControl := 0;
  FEnabled := False;
  FPending := False;
  FRamWritable := False;
  FillChar(FChannels, SizeOf(FChannels), 0);
  for var i := 0 to 1 do
    FChannels[i].Empty := True;
end;

procedure TMapperDrip.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FChannels, SizeOf(FChannels));
  State.Field(FAttributes, SizeOf(FAttributes));
  State.Field(FNames, SizeOf(FNames));
  State.Field(FLow, SizeOf(FLow));
  State.Field(FCounter, SizeOf(FCounter));
  State.Field(FLastTile, SizeOf(FLastTile));
  State.Field(FControl, SizeOf(FControl));
  State.Field(FEnabled, SizeOf(FEnabled));
  State.Field(FPending, SizeOf(FPending));
end;

procedure TMapperDrip.WriteAudio(Channel, Reg: Integer; Value: Byte);
begin
  var C: PDripChannel := @FChannels[Channel];
  case Reg of
    0:
      begin
        FillChar(C.Buffer, SizeOf(C.Buffer), 0);
        C.ReadPos := 0;
        C.WritePos := 0;
        C.Empty := True;
        C.Full := False;
        C.Output := 0;
        C.Timer := C.Period
      end;
    1:
      begin
        if C.ReadPos = C.WritePos then
        begin
          C.Empty := False;
          C.Output := (Integer(Value) - 128) * C.Volume;
          C.Timer := C.Period
        end;
        C.Buffer[C.WritePos] := Value;
        C.WritePos := (C.WritePos + 1) and $FF;
        if C.ReadPos = C.WritePos then
          C.Full := True;
      end;
    2:
      C.Period := (C.Period and $F00) or Value;
    3:
      begin
        C.Period := (C.Period and $FF) or ((Value and 15) shl 8);
        C.Volume := Value shr 4;
        if not C.Empty then
          C.Output := (Integer(C.Buffer[C.ReadPos]) - 128) * C.Volume
      end;
  end;
end;

function TMapperDrip.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if (Address >= $4800) and (Address < $6000) then
  begin
    if Address < $5000 then
      Value := $64
    else
    begin
      var C: PDripChannel := @FChannels[Ord(Address >= $5800)];
      Value := Ord(C.Full) * $80 + Ord(C.Empty) * $40
    end;
    Exit(True);
  end;

  Result := inherited;
end;

function TMapperDrip.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if Address < $8000 then
    Exit(inherited);

  if Address >= $C000 then
    FAttributes[Address and $7FF] := Value
  else
    case Address and 15 of
      0..7:
        WriteAudio((Address shr 2) and 1, Address and 3, Value);
      8:
        FLow := Value;
      9:
        begin
          FCounter := ((Value and $7F) shl 8) or FLow;
          FEnabled := (Value and $80) <> 0;
          FPending := False
        end;
      10:
        begin
          FControl := Value;
          Mirror(Value and 3);
          FRamWritable := (Value and 8) <> 0
        end;
      11:
        Prg16(0, Value and 15);
      12..15:
        Chr2((Address and 15) - 12, Value and 15);
    end;
  Result := True;
end;

function TMapperDrip.NameBank(Address: UInt16): Integer;
begin
  case FMirror of
    TMirrorMode.Vertical:
      Result := (Address shr 10) and 1;
    TMirrorMode.Horizontal:
      Result := (Address shr 11) and 1;
    TMirrorMode.Single1:
      Result := 1;
  else
    Result := 0
  end;
end;

function TMapperDrip.PpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if (Address >= $2000) and (Address < $3F00) then
  begin
    var Bank := NameBank(Address);
    if FPpuRenderingRead then
      if (Address and $3FF) < $3C0 then
        FLastTile := Address and $3FF
      else if (FControl and 4) <> 0 then
      begin
        Value := (FAttributes[Bank * $400 + FLastTile] and 3) * $55;
        Exit(True)
      end;

    Value := FNames[Bank * $400 + (Address and $3FF)];
    Exit(True);
  end;
  Result := inherited;
end;

function TMapperDrip.PpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if (Address >= $2000) and (Address < $3F00) then
  begin
    FNames[NameBank(Address) * $400 + (Address and $3FF)] := Value;
    Exit(True)
  end;

  Result := inherited;
end;

procedure TMapperDrip.ClockCpu;
begin
  if FEnabled and (FCounter > 0) then
  begin
    Dec(FCounter);
    if FCounter = 0 then
    begin
      FEnabled := False;
      FPending := True
    end
  end;
  for var i := 0 to 1 do
  begin
    var C: PDripChannel := @FChannels[i];
    if not C.Empty then
    begin
      C.Timer := (C.Timer - 1) and $FFFF;
      if C.Timer = 0 then
      begin
        C.Timer := C.Period;
        if C.ReadPos = C.WritePos then
          C.Full := False;
        C.ReadPos := (C.ReadPos + 1) and $FF;
        C.Output := (Integer(C.Buffer[C.ReadPos]) - 128) * C.Volume;
        if C.ReadPos = C.WritePos then
          C.Empty := True;
      end;
    end;
  end;
end;

function TMapperDrip.IrqPending: Boolean;
begin
  Result := FPending
end;

function TMapperDrip.ExpansionAudio: Double;
begin
  Result := (FChannels[0].Output + FChannels[1].Output) / 15360.0
end;

end.

