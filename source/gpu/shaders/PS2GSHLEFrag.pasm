// Fixed-function destination blend weight is the second source alpha.
{$I PS2GSHLEPush.pasm}

var
  [PushConstant] PC: TPS2HLEPush;
  [Input, Builtin(FragCoord)] FragmentPosition: Single4;
  [Input, Location(0), NoPerspective] VColor: Single4;
  [Input, Location(1), NoPerspective] VSTQ: Single3;
  [Input, Location(2), NoPerspective] VLodFog: Single2;
  [Binding(0, 0)] UTexture: CombinedTexture2D;
  [Binding(0, 1)] NativeTexture: CombinedTexture2D;
  [Output, Location(0), Index(0)] OColor: Single4;
  [Output, Location(0), Index(1)] OFactor: Single4;

{$I PS2GSHLEFragment.pasm}

[Fragment, Vulkan11]
procedure Main;
begin
  var C := Shade;
  var Test := (PC.AlphaTest shr 12) and 3;
  if (Test <> 0) and (AlphaPasses(C.A) <> (Test = 1)) then
    Discard;
  var A := C.A;
  if (PC.Flags and FlagFBA) <> 0 then
    A := A or 128;
  if (PC.Flags and FlagAlpha1) <> 0 then
    A := if A >= 128 then 255 else 0;
  var RGB: Single3 := Single3(C.RGB) / 255.0;
  var Factor: Single := 0.0;
  if (PC.Flags and FlagBlend) <> 0 then
  begin
    var K: Single := if (PC.Blend and (Cardinal(2) shl 6)) <> 0 then
      Single((PC.Blend shr 8) and 255) / 128.0 else Single(C.A) / 128.0;
    if (PC.Blend and (Cardinal(1) shl 17)) <> 0 then
      RGB := RGB * Weight(PC.Blend and 7, K);
    if (PC.Blend and (Cardinal(1) shl 18)) <> 0 then
      Factor := Weight((PC.Blend shr 3) and 7, K);
    if ((PC.Blend and (Cardinal(1) shl 16)) <> 0) and (C.A < 128) then
    begin
      RGB := Single3(C.RGB) / 255.0;
      Factor := 0.0;
    end;
  end;
  OColor := Single4(RGB, Single(A) / 255.0);
  OFactor := Single4(Factor);
end;
