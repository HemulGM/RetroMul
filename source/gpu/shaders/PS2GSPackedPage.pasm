type
  TPack = record
    X0, Y0, W, H, Pitch, RowShift, FirstPage, Offset, TableBase, Scale: Cardinal;
  end;
var
  [Binding(0, 0), ReadOnly]
  Map: array of Cardinal;
  [Binding(0, 1), WriteOnly]
  Dst: array of Cardinal;
  [Binding(0, 2), ReadOnly]
  Image: Image2D_RGBA8;
  [PushConstant]
  PC: TPack;

function ReadPixel(X, Y: Cardinal): Cardinal;
begin
  var At := Integer2(Integer(X * PC.Scale + PC.Scale div 2), Integer(Y * PC.Scale + PC.Scale div 2));
  var C := Integer4(RoundFloat(ImageLoad(Image, At) * 255.0));
  Result := Cardinal(C.R) or (Cardinal(C.G) shl 8) or (Cardinal(C.B) shl 16) or (Cardinal(C.A) shl 24);
end;

function Half(C: Cardinal): Cardinal;
begin
  Result := ((C shr 3) and 31) or ((C shr 6) and $3E0) or ((C shr 9) and $7C00) or ((C shr 16) and $8000);
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
  X := X + PC.X0;
  var Y := Q.Y + PC.Y0;
  var Page := (Y shr PC.RowShift) * PC.Pitch + (X shr 6) - PC.FirstPage;
  var LaneOffset := Map[PC.TableBase + ((Y and ((Cardinal(1) shl PC.RowShift) - Cardinal(1))) shl 6) + (X and 63)];
  var C := ReadPixel(X, Y);
  if Small then
    C := Half(C) or (Half(ReadPixel(X + 8, Y)) shl 16);
  Dst[PC.Offset + (Page shl 11) + LaneOffset] := C;
end;
