{$I PS2GSLLETables.pasm}
type
  TPush = record
    BP, BW, Format, X0, Y0, W, H, PaletteAt, TA0, TA1, AEM: Cardinal;
  end;
var
  [Binding(0, 0), ReadOnly]
  RAM: array of Cardinal;
  [Binding(0, 1), ReadOnly]
  Colors: array of Cardinal;
  [Binding(0, 2), WriteOnly]
  OutputImage: Image2D_RGBA8;
  [PushConstant]
  PC: TPush;
function Address32(BP, BW, X, Y: Cardinal; Depth: Boolean): Cardinal;
begin
  var Page := (X shr 6) + (Y shr 5) * BW;
  var Block :=
    Blocks[((Y shr 3) and 3) * 8 + ((X shr 3) and 7)]
      xor (if Depth then Cardinal(24)
      else
        Cardinal(0));
  var Column := (X and 1) + ((Y and 1) shl 1) + (((X shr 1) and 3) shl 2) + (((Y shr 1) and 3) shl 4);
  Result := ((BP shl 6) + (Page shl 11) + (Block shl 6) + Column) and $FFFFF;
end;

function Address16(BP, BW, X, Y, PSM: Cardinal): Cardinal;
begin
  var Page := (X shr 6) + (Y shr 6) * BW;
  var Block :=
    if (PSM = 10) or (PSM = $3A) then
      GSBlock16S[((Y shr 3) and 7) * 4 + ((X shr 4) and 3)]
    else
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

[Vulkan11, LocalSize(8, 8, 1)]
procedure Main;
begin
  var Q := GlobalInvocationID.XY;
  if (Q.X >= PC.W) or (Q.Y >= PC.H) then
    Exit;
  var V := RawTexel(PC.BP, PC.BW, Q.X + PC.X0, Q.Y + PC.Y0, PC.Format);
  if (PC.Format = 2) or (PC.Format = 10) or (PC.Format = $32) or (PC.Format = $3A) then
  begin
    var Alpha :=
      if (V and $8000) <> 0 then
        PC.TA1
      else
        (if (PC.AEM <> 0) and ((V and $7FFF) = 0) then Cardinal(0)
      else
        PC.TA0);
    V := ((V and 31) shl 3) or (((V shr 5) and 31) shl 11) or (((V shr 10) and 31) shl 19) or (Alpha shl 24);
  end
  else if (PC.Format = 1) or (PC.Format = $31) then
  begin
    V := V and $FFFFFF;
    if (V <> 0) or (PC.AEM = 0) then
      V := V or (PC.TA0 shl 24);
  end
  else if (PC.Format = $13) or (PC.Format = $14) or (PC.Format = $1B) or (PC.Format = $24) or (PC.Format = $2C) then
    V := Colors[PC.PaletteAt + V];
  var RGBA :=
    Single4(Single(V and 255), Single((V shr 8) and 255), Single((V shr 16) and 255), Single(V shr 24)) / 255.0;
  ImageStore(OutputImage, Integer2(Integer(Q.X), Integer(Q.Y)), RGBA);
end;
