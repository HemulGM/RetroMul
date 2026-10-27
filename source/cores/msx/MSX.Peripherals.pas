unit MSX.Peripherals;

interface

uses
  System.SysUtils, System.Classes, System.Math, Core.Snapshots;

type
  TMSXMouse = class
  private
    FPendingX, FPendingY, FPhase, FIdle: Integer;
    FX, FY, FButtons: Byte;
    FStrobe: Boolean;
  public
    constructor Create;
    procedure Reset;
    procedure Move(DX, DY: Integer; Buttons: Byte);
    procedure Advance(Cycles: Integer);
    procedure WriteStrobe(High: Boolean);
    function Read: Byte;
    procedure SerializeState(State: TStateArchive);
  end;

  TMSXKanji = class
  private
    FROM: TBytes;
    FAddresses: array[0..1] of Integer;
  public
    procedure Load(const Data: TBytes);
    procedure Reset;
    procedure WritePort(Port, Value: Byte);
    function ReadPort(Port: Byte): Byte;
    procedure SerializeState(State: TStateArchive);
    function Identity: string;
  end;

implementation

constructor TMSXMouse.Create;
begin
  inherited;
  Reset;
end;

procedure TMSXMouse.Reset;
begin
  FPendingX := 0;
  FPendingY := 0;
  FX := 0;
  FY := 0;
  FButtons := 0;
  FPhase := 7;
  FIdle := 5370;
  FStrobe := False;
end;

procedure TMSXMouse.Move(DX, DY: Integer; Buttons: Byte);
begin
  // Host right/down is positive; the MSX packet uses left/up positive.
  FPendingX := EnsureRange(Int64(FPendingX) - DX, -$100000, $100000);
  FPendingY := EnsureRange(Int64(FPendingY) - DY, -$100000, $100000);
  FButtons := Buttons and 3;
end;

procedure TMSXMouse.Advance(Cycles: Integer);
begin
  FIdle := Min(5370, Int64(FIdle) + Cycles);
end;

procedure TMSXMouse.WriteStrobe(High: Boolean);
begin
  if High = FStrobe then
    Exit;
  if FIdle >= 5370 then
    FPhase := 7;
  FIdle := 0;
  FStrobe := High;
  if High <> ((FPhase and 1) <> 0) then
    Exit;
  FPhase := (FPhase + 1) and 7;
  if FPhase = 0 then
  begin
    // Match the original mouse's 8-bit counter wrap, not emulator-only
    // saturation. The alternate packet is zero for BIOS trackball detection.
    FX := FPendingX and 255;
    FY := FPendingY and 255;
    FPendingX := 0;
    FPendingY := 0;
  end
  else if FPhase = 4 then
  begin
    FX := 0;
    FY := 0;
  end;
end;

function TMSXMouse.Read: Byte;
begin
  case FPhase and 3 of
    0:
      Result := FX shr 4;
    1:
      Result := FX and 15;
    2:
      Result := FY shr 4;
  else
    Result := FY and 15;
  end;
  Result := Result or $30;
  if FButtons and 1 <> 0 then
    Result := Result and $EF;
  if FButtons and 2 <> 0 then
    Result := Result and $DF;
end;

procedure TMSXMouse.SerializeState(State: TStateArchive);
begin
  State.Field(FPendingX, SizeOf(FPendingX));
  State.Field(FPendingY, SizeOf(FPendingY));
  State.Field(FPhase, SizeOf(FPhase));
  State.Field(FIdle, SizeOf(FIdle));
  State.Field(FX, SizeOf(FX));
  State.Field(FY, SizeOf(FY));
  State.Field(FButtons, SizeOf(FButtons));
  State.Field(FStrobe, SizeOf(FStrobe));
  if State.Loading and ((FPhase < 0) or (FPhase > 7) or (FIdle < 0) or (FIdle > 5370) or
    (Abs(Int64(FPendingX)) > $100000) or (Abs(Int64(FPendingY)) > $100000) or (FButtons > 3)) then
    raise EReadError.Create('Invalid MSX mouse state');
end;

procedure TMSXKanji.Load(const Data: TBytes);
begin
  if (Length(Data) <> 0) and (Length(Data) <> $20000) and (Length(Data) <> $40000) then
    raise EReadError.Create('MSX Kanji ROM must be 128 or 256 KiB');
  FROM := Copy(Data);
  Reset;
end;

procedure TMSXKanji.Reset;
begin
  FillChar(FAddresses, SizeOf(FAddresses), 0);
end;

procedure TMSXKanji.WritePort(Port, Value: Byte);
begin
  var Bank := (Port shr 1) and 1;
  var A := FAddresses[Bank];
  if Port and 1 = 0 then
    A := (A and $1F800) or (Integer(Value and $3F) shl 5)
  else
    A := (A and $7E0) or (Integer(Value and $3F) shl 11);
  FAddresses[Bank] := A and $1FFE0;
end;

function TMSXKanji.ReadPort(Port: Byte): Byte;
begin
  Result := $FF;
  if Port and 1 = 0 then
    Exit;
  var Bank := (Port shr 1) and 1;
  var A := FAddresses[Bank];
  if A + Bank * $20000 < Length(FROM) then
    Result := FROM[A + Bank * $20000];
  FAddresses[Bank] := (A and $1FFE0) or ((A + 1) and 31);
end;

procedure TMSXKanji.SerializeState(State: TStateArchive);
begin
  var Identity := TEncoding.ASCII.GetBytes(SnapshotIdentity(FROM));
  var Saved := Copy(Identity);
  State.Field(Saved[0], Length(Saved));
  if State.Loading and not CompareMem(@Saved[0], @Identity[0], Length(Saved)) then
    raise EReadError.Create('MSX Kanji ROM differs');
  State.Field(FAddresses, SizeOf(FAddresses));
  if State.Loading then
    for var A in FAddresses do
      if (A < 0) or (A > $1FFFF) then
        raise EReadError.Create('Invalid MSX Kanji address');
end;

function TMSXKanji.Identity: string;
begin
  Result := SnapshotIdentity(FROM);
end;

end.

