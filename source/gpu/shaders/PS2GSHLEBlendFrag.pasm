// Ordered integer GS blending, with the original early depth/stencil tests.
{$I PS2GSHLEPush.pasm}

var
  [PushConstant] PC: TPS2HLEPush;
  [Input, Location(0), NoPerspective] VColor: Single4;
  [Input, Location(1), NoPerspective] VSTQ: Single3;
  [Input, Location(2), NoPerspective] VLodFog: Single2;
  [Binding(0, 0)] UTexture: CombinedTexture2D;
  [Input, Builtin(FragCoord)] FragmentPosition: Single4;
  [Binding(1, 0), Coherent] UTarget: Image2D_RGBA8;

{$I PS2GSHLEFragment.pasm}

function BlendInput(Select: Cardinal; Source, Destination: Integer3): Integer3;
begin
  Result := if Select = 0 then Source else (if Select = 1 then Destination else Integer3(0));
end;

[Fragment, Vulkan11, EarlyFragmentTests, PixelInterlockOrdered]
procedure Main;
begin
  var C := Shade;
  var PixelBits := PC.Pixel;
  var Format := (PixelBits shr 21) and 3;
  var WriteAlpha := True;
  if ((PixelBits and (Cardinal(1) shl 25)) <> 0) and not AlphaPasses(C.A) then
  begin
    var AFail := (PixelBits shr 23) and 3;
    if (AFail = 0) or (AFail = 2) then
      Discard;
    if AFail = 3 then
      WriteAlpha := False;
  end;
  var P := Integer2(FragmentPosition.XY);
  Interlock begin
    var D := Integer4(RoundFloat(ImageLoad(UTarget, P) * 255.0));
    var DC := D.RGB;
    var DA := D.A;
    if Format = 2 then
    begin
      DC := DC and Integer3($F8);
      DA := if D.A >= 128 then 128 else 0;
    end
    else if Format = 1 then
      DA := 128;
    var Pass := True;
    if (PixelBits and (Cardinal(1) shl 19)) <> 0 then
      Pass := (DA >= 128) = ((PixelBits and (Cardinal(1) shl 20)) <> 0);
    if Pass then
    begin
      var R := C.RGB;
      if ((PixelBits and (Cardinal(1) shl 16)) <> 0) and
        (((PixelBits and (Cardinal(1) shl 17)) = 0) or (C.A >= 128)) then
      begin
        var CSelect := (PixelBits shr 4) and 3;
        var K := if CSelect = 0 then C.A else
          (if CSelect = 1 then DA else Integer((PixelBits shr 8) and 255));
        R := ArithmeticShiftRight((BlendInput(PixelBits and 3, C.RGB, DC) -
          BlendInput((PixelBits shr 2) and 3, C.RGB, DC)) * K, 7) +
          BlendInput((PixelBits shr 6) and 3, C.RGB, DC);
      end;
      if (PixelBits and (Cardinal(1) shl 18)) <> 0 then
        R := Clamp(R, 0, 255)
      else
        R := R and Integer3(255);
      var A := C.A;
      if (PixelBits and (Cardinal(1) shl 26)) <> 0 then
        A := A or 128;
      var Color := Cardinal(R.R) or (Cardinal(R.G) shl 8) or (Cardinal(R.B) shl 16) or
        (Cardinal(A and 255) shl 24);
      var Old := Cardinal(DC.R) or (Cardinal(DC.G) shl 8) or (Cardinal(DC.B) shl 16) or
        (Cardinal(DA) shl 24);
      var Mask := PC.FBMask;
      if not WriteAlpha then
        Mask := Mask or $FF000000;
      Color := (Color and not Mask) or (Old and Mask);
      var OutputColor := Integer4(Integer(Color and 255), Integer((Color shr 8) and 255),
        Integer((Color shr 16) and 255), Integer(Color shr 24));
      if Format = 2 then
      begin
        OutputColor.RGB := OutputColor.RGB and Integer3($F8);
        OutputColor.A := if OutputColor.A >= 128 then 255 else 0;
      end
      else if Format = 1 then
        OutputColor.A := D.A;
      ImageStore(UTarget, P, Single4(OutputColor) / 255.0);
    end;
  end;
end;
