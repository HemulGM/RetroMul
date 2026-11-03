unit Jaguar.Blitter;

interface

uses
  Jaguar.RISC, Core.Snapshots;

type
  TJaguarBlitter = class
  private
    FRead: TJaguarRead;
    FWrite: TJaguarWrite;
    FRegs: array[0..63] of Cardinal;
    FBusy: Boolean;
    function PixelAddress(Base, Flags: Cardinal; X, Y: Integer; out Shift, Bits: Integer): Cardinal;
    function ReadPixel(Base, Flags: Cardinal; X, Y: Integer): Cardinal;
    procedure WritePixel(Base, Flags: Cardinal; X, Y: Integer; Value: Cardinal);
    procedure Execute;
  public
    constructor Create(Reader: TJaguarRead; Writer: TJaguarWrite);
    procedure Reset;
    function Read(Offset: Cardinal): Cardinal;
    function RegisterValue(Offset: Cardinal): Cardinal;
    procedure Write(Offset, Value: Cardinal; Start: Boolean = True);
    procedure SerializeState(State: TStateArchive);
  end;

implementation

uses
  System.Math;

{$Q-}{$R-}

constructor TJaguarBlitter.Create(Reader: TJaguarRead; Writer: TJaguarWrite);
begin
  inherited Create;
  FRead := Reader;
  FWrite := Writer;
  Reset;
end;

procedure TJaguarBlitter.Reset;
begin
  FillChar(FRegs, SizeOf(FRegs), 0);
  FBusy := False;
end;

function TJaguarBlitter.Read(Offset: Cardinal): Cardinal;
begin
  Result := FRegs[(Offset shr 2) and 63];
  // Status readback is separate from the command latch. When complete,
  // the inner and outer state machines are idle as well as the bus.
  // JTRM B_CMD status: IDLE=bit 0, inner IDLE=bit 2, outer IDLE=bit 11.
  if Offset and $FC = $38 then
    if FBusy then
      Result := 0
    else
      Result := $805;
end;

function TJaguarBlitter.RegisterValue(Offset: Cardinal): Cardinal;
begin
  Result := FRegs[(Offset shr 2) and 63];
end;

procedure TJaguarBlitter.Write(Offset, Value: Cardinal; Start: Boolean);
begin
  FRegs[(Offset shr 2) and 63] := Value;
  // B_CMD bit 7 is SRCENX (extra source phrase), not a stop bit. The
  // pixel path already obtains the source pixels across phrase boundaries.
  if Start and (Offset and $FC = $38) and not FBusy then
    Execute;
end;

function TJaguarBlitter.PixelAddress(Base, Flags: Cardinal; X, Y: Integer; out Shift, Bits: Integer): Cardinal;
const
  Pitch: array[0..3] of Integer = (1, 2, 4, 3);
begin
  Bits := 1 shl ((Flags shr 3) and 7);
  if Bits > 32 then
    Bits := 32;
  var Width := ((4 or ((Flags shr 9) and 3)) shl ((Flags shr 11) and 15)) shr 2;
  var BitAddress := Cardinal(Y * Integer(Width) + X) * Cardinal(Bits);
  Result := (Base and Cardinal($FFFFF8)) + (BitAddress div 64) * Cardinal(8 * Pitch[Flags and 3]) + ((BitAddress and 63) div 8);
  Shift := 8 - Bits - Integer(BitAddress and 7);
end;

function TJaguarBlitter.ReadPixel(Base, Flags: Cardinal; X, Y: Integer): Cardinal;
begin
  var Shift, Bits: Integer;
  var Address := PixelAddress(Base, Flags, X, Y, Shift, Bits);
  if Bits < 8 then
    Result := (FRead(Address, 1) shr Shift) and ((1 shl Bits) - 1)
  else
    Result := FRead(Address, Bits div 8);
end;

procedure TJaguarBlitter.WritePixel(Base, Flags: Cardinal; X, Y: Integer; Value: Cardinal);
begin
  var Shift, Bits: Integer;
  var Address := PixelAddress(Base, Flags, X, Y, Shift, Bits);
  if Bits < 8 then
  begin
    var Mask := Cardinal((1 shl Bits) - 1) shl Shift;
    FWrite(Address, (FRead(Address, 1) and not Mask) or ((Value shl Shift) and Mask), 1);
  end
  else
    FWrite(Address, Value, Bits div 8);
end;

procedure TJaguarBlitter.Execute;
begin
  FBusy := True;
  try
    var Command := FRegs[$38 div 4];
    var Count := Integer(FRegs[$3C div 4] and $FFFF);
    var Lines := Integer(FRegs[$3C div 4] shr 16);
    if Count = 0 then
      Count := 65536;
    if Lines = 0 then
      Lines := 65536;
    // Bound a malformed blit to a finite amount of host work.
    if Int64(Count) * Lines > $1000000 then
      Exit;
    var X1 := Integer(SmallInt(FRegs[3]));
    var Y1 := Integer(SmallInt(FRegs[3] shr 16));
    var X2 := Integer(SmallInt(FRegs[$30 div 4]));
    var Y2 := Integer(SmallInt(FRegs[$30 div 4] shr 16));
    var FX := Integer(FRegs[$18 div 4] and $FFFF);
    var FY := Integer(FRegs[$18 div 4] shr 16);
    var DestinationA2 := Command and $800 <> 0;
    for var Line := 0 to Lines - 1 do
    begin
      for var Pixel := 0 to Count - 1 do
      begin
        var Source := FRegs[$40 div 4];
        var Destination := FRegs[$48 div 4];
        var Pattern := FRegs[$68 div 4];
        var DX := X1;
        var DY := Y1;
        var SX := X2;
        var SY := Y2;
        var DBase := FRegs[0];
        var DFlags := FRegs[1];
        var SBase := FRegs[$24 div 4];
        var SFlags := FRegs[$28 div 4];
        if DestinationA2 then
        begin
          DX := X2;
          DY := Y2;
          SX := X1;
          SY := Y1;
          DBase := FRegs[$24 div 4];
          DFlags := FRegs[$28 div 4];
          SBase := FRegs[0];
          SFlags := FRegs[1];
        end;
        var Bits := 1 shl ((DFlags shr 3) and 7);
        if Bits > 32 then
          Bits := 32;
        if Bits < 32 then
        begin
          var Pattern64 := (UInt64(FRegs[$68 div 4]) shl 32) or FRegs[$6C div 4];
          Pattern := Cardinal(Pattern64 shr (64 - Bits - ((Pixel * Bits) and 63)));
          Pattern := Pattern and ((Cardinal(1) shl Bits) - 1);
          Source := (Source shr (32 - Bits - ((Pixel * Bits) and 31))) and ((Cardinal(1) shl Bits) - 1);
        end;
        if Command and 1 <> 0 then
          Source := ReadPixel(SBase, SFlags, SX, SY);
        if Command and 8 <> 0 then
          Destination := ReadPixel(DBase, DFlags, DX, DY);
        var Value: Cardinal := 0;
        if Command and (1 shl 21) <> 0 then
          Value := Value or (not Source and not Destination);
        if Command and (1 shl 22) <> 0 then
          Value := Value or (not Source and Destination);
        if Command and (1 shl 23) <> 0 then
          Value := Value or (Source and not Destination);
        if Command and (1 shl 24) <> 0 then
          Value := Value or (Source and Destination);
        if Command and $10000 <> 0 then
          Value := Pattern;
        if Command and $20000 <> 0 then
          Value := Cardinal(EnsureRange(Integer(Destination and 255) + Integer(ShortInt(Source and 255)), 0, 255)) or (Destination and $FF00);
        if Command and $40000000 <> 0 then
          Value := (Source and $FF00) or Cardinal(EnsureRange(Integer(Source and 255) + Integer(ShortInt(FRegs[$70 div 4] shr 16)), 0, 255));
        var ShadeIndex := $88 div 4 - (Pixel and 3);
        if Command and $1000 <> 0 then
        begin
          var Intensity := Integer(SmallInt(FRegs[ShadeIndex] shr 16));
          if Command and $4000 = 0 then
            Intensity := EnsureRange(Intensity, 0, 255);
          Value := (Pattern and $FF00) or Cardinal(Intensity and 255);
        end;
        var SourceZ := (FRegs[$58 div 4 + ((Pixel and 3) div 2)] shr (16 - (Pixel and 1) * 16)) and $FFFF;
        var DestinationZ := (FRegs[$50 div 4 + ((Pixel and 3) div 2)] shr (16 - (Pixel and 1) * 16)) and $FFFF;
        var SourceZBase := SBase + ((SFlags shr 6) and 7) * 8;
        var DestinationZBase := DBase + ((DFlags shr 6) and 7) * 8;
        if Command and 3 = 3 then
          SourceZ := ReadPixel(SourceZBase, SFlags, SX, SY);
        if Command and $10 <> 0 then
          DestinationZ := ReadPixel(DestinationZBase, DFlags, DX, DY);
        var Inhibit := False;
        if Command and $40 <> 0 then
          Inhibit := (X1 < 0) or (Y1 < 0) or
            (X1 >= Integer(FRegs[2] and $7FFF)) or (Y1 >= Integer((FRegs[2] shr 16) and $7FFF));
        if Command and $8000000 <> 0 then
          if Command and $2000000 <> 0 then
            Inhibit := Inhibit or (Destination = Pattern)
          else
            Inhibit := Inhibit or (Source = Pattern);
        if Command and $4000000 <> 0 then
          Inhibit := Inhibit or (Source and 1 = 0);
        if (Bits = 16) and (Command and $1C0000 <> 0) then
          Inhibit := Inhibit or
            ((Command and $40000 <> 0) and (SourceZ < DestinationZ)) or
            ((Command and $80000 <> 0) and (SourceZ = DestinationZ)) or
            ((Command and $100000 <> 0) and (SourceZ > DestinationZ));
        if not Inhibit then
          WritePixel(DBase, DFlags, DX, DY, Value);
        if not Inhibit and (Bits = 16) and (Command and $20 <> 0) then
          WritePixel(DestinationZBase, DFlags, DX, DY, SourceZ);
        if Command and $1000 <> 0 then
          Inc(FRegs[ShadeIndex], FRegs[$70 div 4]);
        if Command and $2000 <> 0 then
        begin
          var ZIndex := $98 div 4 - (Pixel and 3);
          Inc(FRegs[ZIndex], FRegs[$74 div 4]);
          var ZWord := (FRegs[ZIndex] shr 16) and $FFFF;
          var WordShift := 16 - (Pixel and 1) * 16;
          var RegisterIndex := $58 div 4 + ((Pixel and 3) div 2);
          FRegs[RegisterIndex] := (FRegs[RegisterIndex] and not (Cardinal($FFFF) shl WordShift)) or (ZWord shl WordShift);
        end;
        // XADD phrase mode advances one pixel here; phrase rounding is done at row end.
        var XAdd1 := (FRegs[1] shr 16) and 3;
        var XAdd2 := (FRegs[$28 div 4] shr 16) and 3;
        if XAdd1 = 3 then
        begin
          Inc(FX, Integer(FRegs[$20 div 4] and $FFFF));
          Inc(FY, Integer(FRegs[$20 div 4] shr 16));
          Inc(X1, Integer(SmallInt(FRegs[$1C div 4])) + (FX shr 16));
          Inc(Y1, Integer(SmallInt(FRegs[$1C div 4] shr 16)) + (FY shr 16));
          FX := FX and $FFFF;
          FY := FY and $FFFF;
        end
        else if XAdd1 <> 2 then
          Inc(X1, 1 - Integer((FRegs[1] shr 18) and 2));
        if XAdd2 <> 2 then
          Inc(X2, 1 - Integer((FRegs[$28 div 4] shr 18) and 2));
        if FRegs[1] and $40000 <> 0 then
          Inc(Y1, 1 - Integer((FRegs[1] shr 19) and 2));
        if FRegs[$28 div 4] and $40000 <> 0 then
          Inc(Y2, 1 - Integer((FRegs[$28 div 4] shr 19) and 2));
        if FRegs[$28 div 4] and $8000 <> 0 then
        begin
          X2 := X2 and Integer(FRegs[$2C div 4] and $FFFF);
          Y2 := Y2 and Integer(FRegs[$2C div 4] shr 16);
        end;
      end;
      if (FRegs[1] shr 16) and 3 = 0 then
      begin
        var PixelsPerPhrase := 64 div (1 shl ((FRegs[1] shr 3) and 7));
        X1 := (X1 + PixelsPerPhrase - 1) and  - PixelsPerPhrase;
      end;
      if (FRegs[$28 div 4] shr 16) and 3 = 0 then
      begin
        var PixelsPerPhrase := 64 div (1 shl ((FRegs[$28 div 4] shr 3) and 7));
        X2 := (X2 + PixelsPerPhrase - 1) and  - PixelsPerPhrase;
      end;
      if Command and $100 <> 0 then
      begin
        Inc(FX, Integer(FRegs[$14 div 4] and $FFFF));
        Inc(FY, Integer(FRegs[$14 div 4] shr 16));
        Inc(X1, FX shr 16);
        Inc(Y1, FY shr 16);
        FX := FX and $FFFF;
        FY := FY and $FFFF;
      end;
      if Command and $200 <> 0 then
      begin
        Inc(X1, SmallInt(FRegs[4]));
        Inc(Y1, SmallInt(FRegs[4] shr 16));
      end;
      if Command and $400 <> 0 then
      begin
        Inc(X2, SmallInt(FRegs[$34 div 4]));
        Inc(Y2, SmallInt(FRegs[$34 div 4] shr 16));
      end;
    end;
    FRegs[3] := (Cardinal(Y1 and $FFFF) shl 16) or Cardinal(X1 and $FFFF);
    FRegs[$30 div 4] := (Cardinal(Y2 and $FFFF) shl 16) or Cardinal(X2 and $FFFF);
    FRegs[$18 div 4] := (Cardinal(FY) shl 16) or Cardinal(FX);
    FRegs[$3C div 4] := 0;
  finally
    FBusy := False;
  end;
end;

procedure TJaguarBlitter.SerializeState(State: TStateArchive);
begin
  State.Field(FRegs, SizeOf(FRegs));
end;

end.

