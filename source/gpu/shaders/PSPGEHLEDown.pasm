// Read back scaled targets, or mirror stencil into the colour alpha channel.
type
  TDownPush = record
    Origin, Size: Integer2;
    Step: Integer;
    Offset, What, Format: Cardinal;
  end;

var
  [Binding(0, 0)] UColor: CombinedTexture2D;
  [Binding(0, 1)] UDepth: CombinedTexture2D;
  [Binding(0, 2)] UStencil: CombinedTexture2DUInt;
  [Binding(0, 3), WriteOnly] Words: array of Cardinal;
  [Binding(0, 4)] UTarget: Image2D_RGBA8;
  [PushConstant] PC: TDownPush;

function Shown(C: Cardinal3): Cardinal3;
begin
  if PC.Format = 0 then
  begin
    var Q := C shr Cardinal3(3, 2, 3);
    Exit(Cardinal3((Q.R shl 3) or (Q.R shr 2),
      (Q.G shl 2) or (Q.G shr 4), (Q.B shl 3) or (Q.B shr 2)));
  end;
  if PC.Format = 1 then
  begin
    var Q := C shr 3;
    Exit((Q shl 3) or (Q shr 2));
  end;
  if PC.Format = 2 then
    Exit((C shr 4) * 17);
  Result := C;
end;

[Vulkan11, LocalSize(8, 8, 1)]
procedure Main;
begin
  var P := Integer2(GlobalInvocationID.XY);
  if (P.X >= PC.Size.X) or (P.Y >= PC.Size.Y) then
    Exit;
  if PC.What = 4 then
  begin
    var Q := PC.Origin + P;
    var C: Single4 := ImageLoad(UTarget, Q);
    C.A := Single(TexelFetch(UStencil, Q, 0).R and 255) / 255.0;
    ImageStore(UTarget, Q, C);
    Exit;
  end;
  var Src := (PC.Origin + P) * PC.Step + PC.Step div 2;
  var I := PC.Offset + Cardinal(P.Y * PC.Size.X + P.X);
  if PC.What = 1 then
  begin
    var C := Cardinal4(RoundFloat(TexelFetch(UColor, Src, 0) * 255.0));
    var S := TexelFetch(UStencil, Src, 0).R and 255;
    Words[I] := C.R or (C.G shl 8) or (C.B shl 16) or (S shl 24);
  end
  else if PC.What = 2 then
    Words[I] := SingleToBits(TexelFetch(UDepth, Src, 0).R)
  else
  begin
    var C := Shown(Cardinal3(RoundFloat(TexelFetch(UColor, Src, 0).RGB * 255.0)));
    Words[I] := $FF000000 or (C.R shl 16) or (C.G shl 8) or C.B;
  end;
end;
