unit NES.Mapper.Namco;

interface

uses
  NES.State, NES.Types, NES.Mapper, NES.Mapper.Banked;

type
  TMapperNamco = class(TMapperBanked)
  private
    FBoard, FVariant, FSubmapper, FCounter, FProtect, FChrMode, FAudioAddr, FAudioDivider, FChannel: Integer;
    FLegacyHeader, FAutoVariant, FAudioIncrement, FPending, FMute, FNot340: Boolean;
    FPages: array[0..11] of Byte;
    FNameRam: array[0..$7FF] of Byte;
    FAudioRam: array[0..$7F] of Byte;
    FOutput: array[0..7] of Integer;
    procedure Detect(Variant: Integer);
    function PpuOffset(Address: UInt16; out IsName: Boolean): Integer;
    procedure ClockAudio;
  public
    constructor Create(Board: Integer; const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode; Submapper: Integer; LegacyHeader: Boolean);
    procedure Reset; override;
    procedure SerializeState(State: TNesStateArchive); override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function PpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function PpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    procedure ClockCpu; override;
    function IrqPending: Boolean; override;
    function ExpansionAudio: Double; override;
    function GetSaveMemory: TByteArray; override;
    procedure SetSaveMemory(const Data: TByteArray); override;
  end;

implementation

constructor TMapperNamco.Create(Board: Integer; const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode; Submapper: Integer; LegacyHeader: Boolean);
begin
  inherited Create(Prg, Chr, HasChrRam, MirrorMode);
  FBoard := Board;
  FSubmapper := Submapper;
  FLegacyHeader := LegacyHeader;
  Reset;
end;

procedure TMapperNamco.Reset;
begin
  inherited;
  FCounter := 0;
  FProtect := 0;
  FChrMode := 0;
  FAudioAddr := 0;
  FAudioDivider := 0;
  FChannel := 7;
  FPending := False;
  FMute := False;
  FAudioIncrement := False;
  FNot340 := False;
  FVariant := 0;
  FAutoVariant := ((FBoard = MAPPER_NAMCO_163) and FLegacyHeader) or ((FBoard = MAPPER_NAMCO_175_340) and (FSubmapper = 0));
  if FBoard = MAPPER_NAMCO_175_340 then
    if FSubmapper = 1 then
      FVariant := 1
    else if FSubmapper = 2 then
      FVariant := 2
    else
      FVariant := 3;
  FillChar(FOutput, SizeOf(FOutput), 0);
  FillChar(FPages, SizeOf(FPages), 0);
  Prg8(0, 0);
  Prg8(1, 0);
  Prg8(2, 0);
  Prg8(3, -1);
  FRamEnabled := FVariant <= 1;
end;

procedure TMapperNamco.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FVariant, SizeOf(FVariant));
  State.Field(FCounter, SizeOf(FCounter));
  State.Field(FProtect, SizeOf(FProtect));
  State.Field(FChrMode, SizeOf(FChrMode));
  State.Field(FAudioAddr, SizeOf(FAudioAddr));
  State.Field(FAudioDivider, SizeOf(FAudioDivider));
  State.Field(FChannel, SizeOf(FChannel));
  State.Field(FAutoVariant, SizeOf(FAutoVariant));
  State.Field(FNot340, SizeOf(FNot340));
  State.Field(FAudioIncrement, SizeOf(FAudioIncrement));
  State.Field(FPending, SizeOf(FPending));
  State.Field(FMute, SizeOf(FMute));
  State.Field(FPages, SizeOf(FPages));
  State.Field(FNameRam, SizeOf(FNameRam));
  State.Field(FAudioRam, SizeOf(FAudioRam));
  State.Field(FOutput, SizeOf(FOutput));
end;

procedure TMapperNamco.Detect(Variant: Integer);
begin
  if FAutoVariant and (not FNot340 or (Variant <> 2)) then
    FVariant := Variant;
  FRamEnabled := FVariant <= 1;
end;

function TMapperNamco.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  case Address and $F800 of
    $4800:
      begin
        Value := FAudioRam[FAudioAddr];
        if FAudioIncrement and (FAudioAddr < $7F) then
          Inc(FAudioAddr);
        Exit(True)
      end;
    $5000:
      begin
        Value := FCounter and $FF;
        Exit(True)
      end;
    $5800:
      begin
        Value := FCounter shr 8;
        Exit(True)
      end;
  end;
  Result := inherited;
end;

function TMapperNamco.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if (Address >= $6000) and (Address < $8000) then
  begin
    FNot340 := True;
    if FVariant = 2 then
      Detect(3);
    var Enable := (FVariant = 0) and ((FProtect and $40) <> 0) and ((FProtect and (1 shl ((Address - $6000) shr 11))) = 0);
    if FVariant = 1 then
      Enable := (FProtect and 1) <> 0;
    if Enable then
      FPrgRam[Address and $1FFF] := Value;
    Exit(True);
  end;

  case Address and $F800 of
    $4800:
      begin
        Detect(0);
        FAudioRam[FAudioAddr] := Value;
        if FAudioIncrement and (FAudioAddr < $7F) then
          Inc(FAudioAddr)
      end;
    $5000:
      begin
        Detect(0);
        FCounter := (FCounter and $FF00) or Value;
        FPending := False
      end;
    $5800:
      begin
        Detect(0);
        FCounter := (FCounter and $FF) or (Value shl 8);
        FPending := False
      end;
    $8000..$B800:
      FPages[(Address - $8000) shr 11] := Value;
    $C000..$D800:
      begin
        if Address >= $C800 then
          Detect(0)
        else if FVariant <> 0 then
          Detect(1);
        if FVariant = 1 then
          FProtect := Value
        else
          FPages[8 + ((Address - $C000) shr 11)] := Value;
      end;
    $E000:
      begin
        if (Value and $80) <> 0 then
          Detect(2)
        else if ((Value and $40) <> 0) and (FVariant <> 0) then
          Detect(2);
        Prg8(0, Value and $3F);
        if FVariant = 2 then
          case Value shr 6 of
            0:
              Mirror(2);
            1:
              Mirror(0);
            2:
              Mirror(3);
            3:
              Mirror(1)
          end
        else if FVariant = 0 then
          FMute := (Value and $40) <> 0;
      end;
    $E800:
      begin
        Prg8(1, Value and $3F);
        if FVariant = 0 then
          FChrMode := Value and $C0
      end;
    $F000:
      Prg8(2, Value and $3F);
    $F800:
      begin
        Detect(0);
        if FVariant = 0 then
        begin
          FProtect := Value;
          FAudioAddr := Value and $7F;
          FAudioIncrement := (Value and $80) <> 0
        end
      end;
  else
    Exit(False)
  end;

  Result := True;
end;

function TMapperNamco.PpuOffset(Address: UInt16; out IsName: Boolean): Integer;
begin
  var Slot := Address shr 10;
  if Slot >= 12 then
    Dec(Slot, 4);
  var Bank := FPages[Slot];
  IsName := (FVariant = 0) and (Bank >= $E0) and ((Slot >= 8) or ((FChrMode and ($40 shl (Slot shr 2))) = 0));
  if IsName then
    Result := (Bank and 1) * $400 + (Address and $3FF)
  else
    Result := (Bank * $400 + (Address and $3FF)) mod Length(FChrMemory);
end;

function TMapperNamco.PpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  Result := (Address < $2000) or ((FVariant = 0) and (Address < $3F00));
  if not Result then
    Exit;

  var IsName: Boolean;
  var Offset := PpuOffset(Address, IsName);
  if IsName then
    Value := FNameRam[Offset]
  else
    Value := FChrMemory[Offset];
end;

function TMapperNamco.PpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  Result := (Address < $2000) or ((FVariant = 0) and (Address < $3F00));
  if not Result then
    Exit;

  var IsName: Boolean;
  var Offset := PpuOffset(Address, IsName);
  if IsName then
    FNameRam[Offset] := Value
  else if FHasChrRam then
    FChrMemory[Offset] := Value
  else
    Result := False;
end;

procedure TMapperNamco.ClockAudio;
begin
  if FMute then
    Exit;

  Inc(FAudioDivider);
  if FAudioDivider < 15 then
    Exit;

  FAudioDivider := 0;
  var Base := $40 + FChannel * 8;
  var Phase := Integer(FAudioRam[Base + 1]) or (Integer(FAudioRam[Base + 3]) shl 8) or (Integer(FAudioRam[Base + 5]) shl 16);
  var Frequency := Integer(FAudioRam[Base]) or (Integer(FAudioRam[Base + 2]) shl 8) or ((Integer(FAudioRam[Base + 4]) and 3) shl 16);
  Phase := (Phase + Frequency) mod ((256 - (FAudioRam[Base + 4] and $FC)) shl 16);
  var Pos := ((Phase shr 16) + FAudioRam[Base + 6]) and $FF;
  var Wave := (FAudioRam[Pos shr 1] shr ((Pos and 1) * 4)) and 15;
  FOutput[FChannel] := (Wave - 8) * (FAudioRam[Base + 7] and 15);
  FAudioRam[Base + 1] := Phase and $FF;
  FAudioRam[Base + 3] := (Phase shr 8) and $FF;
  FAudioRam[Base + 5] := (Phase shr 16) and $FF;
  Dec(FChannel);
  if FChannel < 7 - ((FAudioRam[$7F] shr 4) and 7) then
    FChannel := 7;
end;

procedure TMapperNamco.ClockCpu;
begin
  if ((FCounter and $8000) <> 0) and ((FCounter and $7FFF) <> $7FFF) then
  begin
    Inc(FCounter);
    if (FCounter and $7FFF) = $7FFF then
      FPending := True
  end;
  if FVariant = 0 then
    ClockAudio;
end;

function TMapperNamco.IrqPending: Boolean;
begin
  Result := FPending
end;

function TMapperNamco.ExpansionAudio: Double;
begin
  Result := 0;
  if (FVariant <> 0) or FMute then
    Exit;

  var Channels := ((FAudioRam[$7F] shr 4) and 7) + 1;
  for var i := 8 - Channels to 7 do
    Result := Result + FOutput[i];
  Result := Result / (Channels * 480.0);
end;

function TMapperNamco.GetSaveMemory: TByteArray;
begin
  Result := inherited;
  if FBoard = MAPPER_NAMCO_163 then
  begin
    SetLength(Result, $2080);
    Move(FAudioRam[0], Result[$2000], $80)
  end;
end;

procedure TMapperNamco.SetSaveMemory(const Data: TByteArray);
begin
  if (FBoard = MAPPER_NAMCO_163) and (Length(Data) = $2080) then
  begin
    Move(Data[0], FPrgRam[0], $2000);
    Move(Data[$2000], FAudioRam[0], $80)
  end
  else
    inherited;
end;

end.

