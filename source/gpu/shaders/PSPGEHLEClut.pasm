// Read a scaled render target through the CLUT index transform on the GPU.
type
  TClutPush = record
    Size: Integer2;
    Scale: Integer;
    Format, TexelBytes, PixelBytes, Shift, Mask, Base, Add: Cardinal;
  end;

var
  [Binding(0, 0)] UColor: CombinedTexture2D;
  [Binding(0, 1)] UClut: CombinedTexture2D;
  [Binding(0, 2), WriteOnly] UOut: Image2D_RGBA8;
  [PushConstant] PC: TClutPush;

function Encode(C: Cardinal4): Cardinal;
begin
  if PC.Format = 0 then
    Exit((C.R shr 3) or ((C.G shr 2) shl 5) or ((C.B shr 3) shl 11));
  if PC.Format = 1 then
    Exit((C.R shr 3) or ((C.G shr 3) shl 5) or ((C.B shr 3) shl 10) or
      (if C.A >= 128 then $8000 else 0));
  if PC.Format = 2 then
    Exit((C.R shr 4) or ((C.G shr 4) shl 4) or ((C.B shr 4) shl 8) or ((C.A shr 4) shl 12));
  Result := C.R or (C.G shl 8) or (C.B shl 16) or (C.A shl 24);
end;

[Vulkan11, LocalSize(8, 8, 1)]
procedure Main;
begin
  var P := Integer2(GlobalInvocationID.XY);
  if (P.X >= PC.Size.X) or (P.Y >= PC.Size.Y) then
    Exit;
  var S := PC.Scale;
  var B := Cardinal(P.X div S) * PC.TexelBytes;
  var PX := Integer(B div PC.PixelBytes);
  var Part := B mod PC.PixelBytes;
  var X := PX * S + (Integer(Part) * S + (P.X mod S) * Integer(PC.TexelBytes)) div Integer(PC.PixelBytes);
  var C := Cardinal4(RoundFloat(TexelFetch(UColor, Integer2(X, P.Y), 0) * 255.0));
  var V := Encode(C) shr (Part * 8);
  if PC.TexelBytes < 4 then
    V := V and ((Cardinal(1) shl (PC.TexelBytes * 8)) - 1);
  var I := ((((V shr PC.Shift) and PC.Mask) or PC.Base) + PC.Add) and 511;
  ImageStore(UOut, P, TexelFetch(UClut, Integer2(Integer(I), 0), 0));
end;
