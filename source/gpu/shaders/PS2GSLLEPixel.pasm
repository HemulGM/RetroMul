// Context references preserve invocation-local cache state through helpers.
function DrawParam(var Ctx: TPS2PixelContext; Field: Cardinal): Cardinal;
begin
  Result := Draws[Ctx.DrawIndex].P[Field];
end;

function LoadFrame(var Ctx: TPS2PixelContext; Address: Cardinal): Cardinal;
begin
  if not Ctx.PixelCache then
    Exit(RAM[Address]);
  if not Ctx.FrameLoaded then
  begin
    Ctx.CachedFrame := RAM[Address];
    Ctx.CachedFA := Address;
    Ctx.FrameLoaded := True;
  end;
  Result := Ctx.CachedFrame;
end;

function LoadFrame16(var Ctx: TPS2PixelContext; Address: Cardinal): Cardinal;
begin
  if not Ctx.PixelCache then
    Exit((RAM[Address shr 1] shr ((Address and 1) * 16)) and $FFFF);
  if not Ctx.FrameLoaded then
  begin
    Ctx.CachedFrame := (RAM[Address shr 1] shr ((Address and 1) * 16)) and $FFFF;
    Ctx.CachedFA := Address;
    Ctx.FrameLoaded := True;
    Ctx.Frame16 := True;
  end;
  Result := Ctx.CachedFrame;
end;

procedure Store16(Address, Value: Cardinal);
begin
  var Shift := (Address and 1) * 16;
  AtomicAnd(RAM[Address shr 1], not (Cardinal($FFFF) shl Shift));
  AtomicOr(RAM[Address shr 1], (Value and $FFFF) shl Shift);
end;

function LoadDepth(var Ctx: TPS2PixelContext; Address: Cardinal): Cardinal;
begin
  if not Ctx.PixelCache then
    Exit(RAM[Address]);
  if not Ctx.DepthLoaded then
  begin
    Ctx.CachedDepth := RAM[Address];
    Ctx.CachedZA := Address;
    Ctx.DepthLoaded := True;
  end;
  Result := Ctx.CachedDepth;
end;

function LoadDepth16(var Ctx: TPS2PixelContext; Address: Cardinal): Cardinal;
begin
  if not Ctx.PixelCache then
    Exit((RAM[Address shr 1] shr ((Address and 1) * 16)) and $FFFF);
  if not Ctx.DepthLoaded then
  begin
    Ctx.CachedDepth := (RAM[Address shr 1] shr ((Address and 1) * 16)) and $FFFF;
    Ctx.CachedZA := Address;
    Ctx.DepthLoaded := True;
    Ctx.Depth16 := True;
  end;
  Result := Ctx.CachedDepth;
end;

procedure StoreFrame(var Ctx: TPS2PixelContext; Address, Value: Cardinal);
begin
  if not Ctx.PixelCache then
  begin
    RAM[Address] := Value;
    Exit;
  end;
  Ctx.CachedFA := Address;
  Ctx.CachedFrame := Value;
  Ctx.FrameLoaded := True;
  Ctx.FrameDirty := True;
end;

procedure StoreFrame16(var Ctx: TPS2PixelContext; Address, Value: Cardinal);
begin
  if not Ctx.PixelCache then
  begin
    Store16(Address, Value);
    Exit;
  end;
  Ctx.CachedFA := Address;
  Ctx.CachedFrame := Value;
  Ctx.FrameLoaded := True;
  Ctx.FrameDirty := True;
  Ctx.Frame16 := True;
end;

procedure StoreDepth(var Ctx: TPS2PixelContext; Address, Value: Cardinal);
begin
  if not Ctx.PixelCache then
  begin
    RAM[Address] := Value;
    Exit;
  end;
  Ctx.CachedZA := Address;
  Ctx.CachedDepth := Value;
  Ctx.DepthLoaded := True;
  Ctx.DepthDirty := True;
end;

procedure StoreDepth16(var Ctx: TPS2PixelContext; Address, Value: Cardinal);
begin
  if not Ctx.PixelCache then
  begin
    Store16(Address, Value);
    Exit;
  end;
  Ctx.CachedZA := Address;
  Ctx.CachedDepth := Value;
  Ctx.DepthLoaded := True;
  Ctx.DepthDirty := True;
  Ctx.Depth16 := True;
end;

procedure FinishPixelCache(var Ctx: TPS2PixelContext);
begin
  if Ctx.FrameDirty then
    if Ctx.Frame16 then
      Store16(Ctx.CachedFA, Ctx.CachedFrame)
    else
      RAM[Ctx.CachedFA] := Ctx.CachedFrame;
  if Ctx.DepthDirty then
    if Ctx.Depth16 then
      Store16(Ctx.CachedZA, Ctx.CachedDepth)
    else
      RAM[Ctx.CachedZA] := Ctx.CachedDepth;
end;

function Address32(BP, BW, X, Y: Cardinal; Depth: Boolean): Cardinal;
begin
  var Page := (X shr 6) + (Y shr 5) * BW;
  var Block := Blocks[((Y shr 3) and 3) * 8 + ((X shr 3) and 7)] xor
    (if Depth then Cardinal(24) else Cardinal(0));
  var Column := (X and 1) + ((Y and 1) shl 1) + (((X shr 1) and 3) shl 2) +
    (((Y shr 1) and 3) shl 4);
  Result := ((BP shl 6) + (Page shl 11) + (Block shl 6) + Column) and $FFFFF;
end;

function SelectColor(Which: Cardinal; Source, Destination: Integer3): Integer3;
begin
  Result := if Which = 0 then Source else (if Which = 1 then Destination else Integer3(0));
end;

function ClampCoordinate(C: Integer; Size, Mode, Minimum, Maximum: Cardinal): Integer;
begin
  if Mode = 0 then
    Exit(C and Integer(Size - 1));
  if Mode = 1 then
    Exit(if C < 0 then 0 else (if C >= Integer(Size) then Integer(Size) - 1 else C));
  if Mode = 2 then
    Exit(if C < Integer(Minimum) then Integer(Minimum) else
      (if C > Integer(Maximum) then Integer(Maximum) else C));
  Result := (C and Integer(Minimum)) or Integer(Maximum);
end;

function Address16(BP, BW, X, Y, PSM: Cardinal): Cardinal;
begin
  var Page := (X shr 6) + (Y shr 6) * BW;
  var Block := if (PSM = 10) or (PSM = $3A) then
    GSBlock16S[((Y shr 3) and 7) * 4 + ((X shr 4) and 3)] else
    GSBlock16[((Y shr 3) and 7) * 4 + ((X shr 4) and 3)];
  if PSM >= $30 then
    Block := Block xor 24;
  Result := ((BP shl 7) + (Page shl 12) + (Block shl 7) + GSColumn16[(Y and 7) * 16 + (X and 15)]) and $1FFFFF;
end;

function RawTexel(BP, BW, X, Y, PSM: Cardinal): Cardinal;
begin
  if (PSM = 2) or (PSM = 10) or (PSM = $32) or (PSM = $3A) then
  begin
    var Address := Address16(BP, BW, X, Y, PSM);
    Exit((RAM[Address shr 1] shr ((Address and 1) * 16)) and $FFFF);
  end;
  if PSM = $13 then
  begin
    var Page := (X shr 7) + (Y shr 6) * ((BW + 1) shr 1);
    var Block := Blocks[((Y shr 4) and 3) * 8 + ((X shr 4) and 7)];
    var Address := ((BP shl 8) + (Page shl 13) + (Block shl 8) + GSColumn8[(Y and 15) * 16 + (X and 15)]) and $3FFFFF;
    Exit((RAM[Address shr 2] shr ((Address and 3) * 8)) and 255);
  end;
  if PSM = $14 then
  begin
    var Page := (X shr 7) + (Y shr 7) * ((BW + 1) shr 1);
    var Block := GSBlock16[((Y shr 4) and 7) * 4 + ((X shr 5) and 3)];
    var Address := ((BP shl 9) + (Page shl 14) + (Block shl 9) + GSColumn4[(Y and 15) * 32 + (X and 31)]) and $7FFFFF;
    Exit((RAM[Address shr 3] shr ((Address and 7) * 4)) and 15);
  end;
  var T := RAM[Address32(BP, BW, X, Y, (PSM = $30) or (PSM = $31))];
  if PSM = $1B then
    Exit(T shr 24);
  if PSM = $24 then
    Exit((T shr 24) and 15);
  if PSM = $2C then
    Exit(T shr 28);
  Result := T;
end;

function ClutWord(var Ctx: TPS2PixelContext; Index: Cardinal): Cardinal;
begin
  Result := (DrawParam(Ctx, 128 + (Index shr 1)) shr ((Index and 1) * 16)) and $FFFF;
end;

function Expand16(var Ctx: TPS2PixelContext; T: Cardinal): Cardinal;
begin
  var A := if (T and $8000) <> 0 then DrawParam(Ctx, 51) else
    (if (DrawParam(Ctx, 46) <> 0) and ((T and $7FFF) = 0) then Cardinal(0) else DrawParam(Ctx, 45));
  Result := ((T and 31) shl 3) or (((T shr 5) and 31) shl 11) or
    (((T shr 10) and 31) shl 19) or (A shl 24);
end;

function ReadTexel(var Ctx: TPS2PixelContext; U, V: Integer; Level: Cardinal): Cardinal4;
begin
  var W := Max(Cardinal(1), DrawParam(Ctx, 35) shr Level);
  var H := Max(Cardinal(1), DrawParam(Ctx, 36) shr Level);
  var MinU := if DrawParam(Ctx, 37) = 3 then DrawParam(Ctx, 39) else DrawParam(Ctx, 39) shr Level;
  var MaxU := if DrawParam(Ctx, 37) = 3 then DrawParam(Ctx, 40) else DrawParam(Ctx, 40) shr Level;
  var MinV := if DrawParam(Ctx, 38) = 3 then DrawParam(Ctx, 41) else DrawParam(Ctx, 41) shr Level;
  var MaxV := if DrawParam(Ctx, 38) = 3 then DrawParam(Ctx, 42) else DrawParam(Ctx, 42) shr Level;
  U := ClampCoordinate(U, W, DrawParam(Ctx, 37), MinU, MaxU);
  V := ClampCoordinate(V, H, DrawParam(Ctx, 38), MinV, MaxV);
  var PSM := DrawParam(Ctx, 34);
  var T := RawTexel(DrawParam(Ctx, 64 + Level), DrawParam(Ctx, 71 + Level), Cardinal(U), Cardinal(V), PSM);
  if (PSM = 1) or (PSM = $31) then
  begin
    var A := if (DrawParam(Ctx, 46) <> 0) and ((T and $FFFFFF) = 0) then Cardinal(0) else DrawParam(Ctx, 45);
    T := (T and $FFFFFF) or (A shl 24);
  end
  else if (PSM = 2) or (PSM = 10) or (PSM = $32) or (PSM = $3A) then
    T := Expand16(Ctx, T)
  else if (PSM = $13) or (PSM = $14) or (PSM = $1B) or (PSM = $24) or (PSM = $2C) then
  begin
    var Index := T + DrawParam(Ctx, 50);
    if DrawParam(Ctx, 49) <> 0 then
    begin
      Index := Index and 255;
      T := ClutWord(Ctx, Index) or (ClutWord(Ctx, Index + 256) shl 16);
    end
    else
      T := Expand16(Ctx, ClutWord(Ctx, Index and 511));
  end;
  Result := Cardinal4(T and 255, (T shr 8) and 255, (T shr 16) and 255, T shr 24);
end;

function SampleTexLevel(var Ctx: TPS2PixelContext; U, V: Integer; Level: Cardinal; Linear: Boolean): Cardinal4;
begin
  U := ArithmeticShiftRight(U, Level);
  V := ArithmeticShiftRight(V, Level);
  if not Linear then
    Exit(ReadTexel(Ctx, ArithmeticShiftRight(U, 4), ArithmeticShiftRight(V, 4), Level));
  Dec(U, 8);
  Dec(V, 8);
  var FU := Cardinal(U and 15);
  var FV := Cardinal(V and 15);
  var U0 := ArithmeticShiftRight(U, 4);
  var V0 := ArithmeticShiftRight(V, 4);
  var Top := ReadTexel(Ctx, U0, V0, Level) * (16 - FU) + ReadTexel(Ctx, U0 + 1, V0, Level) * FU;
  var Bottom := ReadTexel(Ctx, U0, V0 + 1, Level) * (16 - FU) + ReadTexel(Ctx, U0 + 1, V0 + 1, Level) * FU;
  Result := (Top * (16 - FV) + Bottom * FV) shr 8;
end;

function DepthIs16(var Ctx: TPS2PixelContext): Boolean;
begin
  Result := (DrawParam(Ctx, 5) = $32) or (DrawParam(Ctx, 5) = $3A);
end;

function DepthPass(var Ctx: TPS2PixelContext; XY: Integer2; SourceZ: Cardinal): Boolean;
begin
  if DrawParam(Ctx, 12) = 1 then
    Exit(True);
  if DrawParam(Ctx, 12) = 0 then
    Exit(False);
  var Old: Cardinal;
  var Mask: Cardinal;
  if DepthIs16(Ctx) then
  begin
    Mask := $FFFF;
    Old := LoadDepth16(Ctx, Address16(DrawParam(Ctx, 4), DrawParam(Ctx, 1), Cardinal(XY.X), Cardinal(XY.Y), DrawParam(Ctx, 5)));
  end
  else
  begin
    Mask := if DrawParam(Ctx, 5) = $31 then Cardinal($FFFFFF) else Cardinal($FFFFFFFF);
    Old := LoadDepth(Ctx, Address32(DrawParam(Ctx, 4), DrawParam(Ctx, 1), Cardinal(XY.X), Cardinal(XY.Y), True)) and Mask;
  end;
  var Z := Min(SourceZ, Mask);
  Result := not (((DrawParam(Ctx, 12) = 2) and (Z < Old)) or ((DrawParam(Ctx, 12) = 3) and (Z <= Old)));
end;

procedure SourceColor(var Ctx: TPS2PixelContext; var C: Integer3; var A: Integer; F, U, V: Integer; Mip: Cardinal);
begin
  if DrawParam(Ctx, 47) <> 0 then
  begin
    var L0 := Mip and 7;
    var L1 := (Mip shr 3) and 7;
    var Weight := (Mip shr 6) and 31;
    var Linear := (Mip and 2048) <> 0;
    var Tex := SampleTexLevel(Ctx, U, V, L0, Linear);
    if Weight <> 0 then
      Tex := (Tex * (16 - Weight) + SampleTexLevel(Ctx, U, V, L1, Linear) * Weight) shr 4;
    var T := Integer4(Tex);
    case DrawParam(Ctx, 43) of
      0:
        begin
          C := ArithmeticShiftRight(C * T.RGB, 7);
          if DrawParam(Ctx, 44) <> 0 then
            A := ArithmeticShiftRight(A * T.A, 7);
        end;
      1:
        begin
          C := T.RGB;
          if DrawParam(Ctx, 44) <> 0 then
            A := T.A;
        end;
    else
      begin
        C := ArithmeticShiftRight(C * T.RGB, 7) + A;
        if DrawParam(Ctx, 44) <> 0 then
          A := if DrawParam(Ctx, 43) = 2 then T.A + A else T.A;
      end;
    end;
    C := Min(C, Integer3(255));
    A := Min(A, 255);
  end;
  if DrawParam(Ctx, 22) <> 0 then
    C := ArithmeticShiftRight(F * C + (255 - F) * Integer3(Integer(DrawParam(Ctx, 23)),
      Integer(DrawParam(Ctx, 24)), Integer(DrawParam(Ctx, 25))), 8);
end;

function AlphaPass(Func: Cardinal; A, Reference: Integer): Boolean;
begin
  case Func of
    0:
      Exit(False);
    1:
      Exit(True);
    2:
      Exit(A < Reference);
    3:
      Exit(A <= Reference);
    4:
      Exit(A = Reference);
    5:
      Exit(A >= Reference);
    6:
      Exit(A > Reference);
  end;
  Result := A <> Reference;
end;

procedure WritePixel(var Ctx: TPS2PixelContext; XY: Integer2; SourceZ: Cardinal; C: Integer3; A: Integer);
begin
  var X := Cardinal(XY.X);
  var Y := Cardinal(XY.Y);
  var WriteFB := True;
  var WriteZ := DrawParam(Ctx, 6) = 0;
  var WriteAlpha := True;
  if not AlphaPass(DrawParam(Ctx, 7), A, Integer(DrawParam(Ctx, 8))) then
    case DrawParam(Ctx, 9) of
      0:
        Exit;
      1:
        WriteZ := False;
      2:
        WriteFB := False;
    else
      begin
        WriteZ := False;
        WriteAlpha := False;
      end;
    end;
  var Z16 := DepthIs16(Ctx);
  var ZA := if Z16 then Address16(DrawParam(Ctx, 4), DrawParam(Ctx, 1), X, Y, DrawParam(Ctx, 5)) else
    Address32(DrawParam(Ctx, 4), DrawParam(Ctx, 1), X, Y, True);
  var ZMask := if Z16 then Cardinal($FFFF) else
    (if DrawParam(Ctx, 5) = $31 then Cardinal($FFFFFF) else Cardinal($FFFFFFFF));
  var Z := Min(SourceZ, ZMask);
  var PSM := DrawParam(Ctx, 2);
  var FB16 := (PSM = 2) or (PSM = 10) or (PSM = $32) or (PSM = $3A);
  var FA := if FB16 then Address16(DrawParam(Ctx, 0), DrawParam(Ctx, 1), X, Y, PSM) else
    Address32(DrawParam(Ctx, 0), DrawParam(Ctx, 1), X, Y, False);
  var Raw := if FB16 then LoadFrame16(Ctx, FA) else LoadFrame(Ctx, FA);
  var Destination := if FB16 then ((Raw and 31) shl 3) or (((Raw shr 5) and 31) shl 11) or
    (((Raw shr 10) and 31) shl 19) or ((Raw shr 15) shl 31) else
    (if PSM = 1 then (Raw and $FFFFFF) or $80000000 else Raw);
  if (DrawParam(Ctx, 10) <> 0) and ((Destination shr 31) <> DrawParam(Ctx, 11)) then
    Exit;
  if (DrawParam(Ctx, 21) <> 0) and ((DrawParam(Ctx, 18) = 0) or (A >= 128)) then
  begin
    var D := Integer3(Integer(Destination and 255), Integer((Destination shr 8) and 255),
      Integer((Destination shr 16) and 255));
    var CA := SelectColor(DrawParam(Ctx, 13), C, D);
    var CB := SelectColor(DrawParam(Ctx, 14), C, D);
    var CD := SelectColor(DrawParam(Ctx, 16), C, D);
    var CC := if DrawParam(Ctx, 15) = 0 then A else
      (if DrawParam(Ctx, 15) = 1 then Integer(Destination shr 24) else Integer(DrawParam(Ctx, 17)));
    C := ArithmeticShiftRight((CA - CB) * CC, 7) + CD;
  end;
  C := if DrawParam(Ctx, 20) <> 0 then Clamp(C, Integer3(0), Integer3(255)) else C and Integer3(255);
  if DrawParam(Ctx, 19) <> 0 then
    A := A or 128;
  if WriteFB then
  begin
    var Color := Cardinal(C.R) or (Cardinal(C.G) shl 8) or (Cardinal(C.B) shl 16) or (Cardinal(A and 255) shl 24);
    var Mask := DrawParam(Ctx, 3) or (if WriteAlpha then Cardinal(0) else Cardinal($FF000000));
    Color := (Color and not Mask) or (Destination and Mask);
    if FB16 then
      StoreFrame16(Ctx, FA, ((Color shr 3) and 31) or (((Color shr 11) and 31) shl 5) or
        (((Color shr 19) and 31) shl 10) or ((Color shr 31) shl 15))
    else
      StoreFrame(Ctx, FA, if PSM = 1 then (Raw and $FF000000) or (Color and $FFFFFF) else Color);
  end;
  if WriteZ and (WriteFB or (DrawParam(Ctx, 9) = 2)) then
    if Z16 then
      StoreDepth16(Ctx, ZA, Z)
    else
      StoreDepth(Ctx, ZA, (LoadDepth(Ctx, ZA) and not ZMask) or (Z and ZMask));
end;

procedure ShadePixel(var Ctx: TPS2PixelContext; XY: Integer2; SourceZ: Cardinal; C: Integer3; A, F, U, V: Integer; Mip: Cardinal);
begin
  if not DepthPass(Ctx, XY, SourceZ) then
    Exit;
  SourceColor(Ctx, C, A, F, U, V, Mip);
  WritePixel(Ctx, XY, SourceZ, C, A);
end;
