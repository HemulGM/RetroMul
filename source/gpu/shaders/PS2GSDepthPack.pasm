type
  TPack = record
    X0, Y0, W, H, Pitch, RowShift, FirstPage, Offset, TableBase, Scale, Bits, FlagAt: Cardinal;
  end;
var
  [Binding(0, 0), ReadOnly]
  Map: array of Cardinal;
  [Binding(0, 1)]
  Dst: array of Cardinal;
  [Binding(0, 2)]
  Src: CombinedTexture2D;
  [PushConstant]
  PC: TPack;

function ReadZ(X, Y: Cardinal): Cardinal;
begin
  var Center := PC.Scale div 2;
  var P := Integer2(Integer((PC.X0 + X) * PC.Scale + Center), Integer((PC.Y0 + Y) * PC.Scale + Center));
  var Raw := SingleToBits(TexelFetch(Src, P, 0).R);
  var Cap := $FFFFFFFF shr (Cardinal(32) - PC.Bits);
  if Raw = 0 then
    Exit(0);
  if Raw = $3F800000 then
    Exit(Cap);
  if (Raw < $00800000) or (Raw > $3F800000) then
  begin
    AtomicOr(Dst[PC.FlagAt], Cardinal(1));
    Exit(0);
  end;
  var M := (Raw and $007FFFFF) or $00800000;
  var Right := 150 - Integer(PC.Bits) - Integer(Raw shr 23);
  if Right <= 0 then
    Exit(M shl Cardinal(-Right));
  if Right > 24 then
    Exit(0);
  Result := Min(((M shr Cardinal(Right - 1)) + Cardinal(1)) shr 1, Cap);
end;

[Vulkan11, LocalSize(8, 8, 1)]
procedure Main;
begin
  var Q := GlobalInvocationID.XY;
  var Small := PC.RowShift = 6;
  var X := Q.X;
  if Small then
    X := (Q.X and 7) + ((Q.X shr 3) shl 4);
  if (X >= PC.W) or (Q.Y >= PC.H) then
    Exit;
  var C := ReadZ(X, Q.Y);
  if Small then
    C := C or (ReadZ(X + 8, Q.Y) shl 16);
  var GX := X + PC.X0;
  var GY := Q.Y + PC.Y0;
  var Page := (GY shr PC.RowShift) * PC.Pitch + (GX shr 6) - PC.FirstPage;
  var At := Map[PC.TableBase + ((GY and ((Cardinal(1) shl PC.RowShift) - Cardinal(1))) shl 6) + (GX and 63)];
  Dst[PC.Offset + (Page shl 11) + At] := C;
end;
