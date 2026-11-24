// Ordered integer GS blending, with the original early depth/stencil tests.
{$I PS2GSHLEPush.pasm}

var
  [PushConstant]
  PC: TPS2HLEPush;
  [Input, Location(0), NoPerspective]
  VColor: Single4;
  [Input, Location(1), NoPerspective]
  VSTQ: Single3;
  [Input, Location(2), NoPerspective]
  VLodFog: Single2;
  [Binding(0, 0)]
  UTexture: CombinedTexture2D;
  [Input, Builtin(FragCoord)]
  FragmentPosition: Single4;
  [Binding(1, 0), Coherent]
  UTarget: Image2D_RGBA8;

// Shared GS texture, fog and alpha-test arithmetic for both fragment paths.
function TextureScale: Integer;
begin
  Result := Max(1, Integer((PC.Texa shr 16) and 15));
end;

function WrapCoord(C, Size: Integer; Mode: Cardinal; MinC, MaxC: Integer): Integer;
begin
  if Mode = 0 then
    Exit(C and (Size - 1));
  if Mode = 1 then
    Exit(Clamp(C, 0, Size - 1));
  if Mode = 2 then
    Exit(
      if C < MinC then
        MinC
      else
        (if C > MaxC then MaxC
      else
        C)
    );
  Result := (C and MinC) or MaxC;
end;

function WrapScaled(C, Size: Integer; Mode: Cardinal; MinC, MaxC, Scale: Integer): Integer;
begin
  if Scale = 1 then
    Exit(WrapCoord(C, Size, Mode, MinC, MaxC));
  if Mode = 0 then
  begin
    var Extent := Size * Scale;
    Exit(((C mod Extent) + Extent) mod Extent);
  end;
  if Mode = 1 then
    Exit(Clamp(C, 0, Size * Scale - 1));
  if Mode = 2 then
  begin
    var Minimum := MinC * Scale;
    var Maximum := (MaxC + 1) * Scale - 1;
    Exit(
      if C < Minimum then
        Minimum
      else
        (if C > Maximum then Maximum
      else
        C)
    );
  end;
  var Native := C div Scale;
  if (C < 0) and (C mod Scale <> 0) then
    Dec(Native);
  Result := ((Native and MinC) or MaxC) * Scale + C - Native * Scale;
end;

function Texel(P: Integer2; Level: Integer): Integer4;
begin
  var Offset: Integer2 :=
    Integer2(ArithmeticShiftRight(Integer(PC.TexOffset shl 16), 16), ArithmeticShiftRight(Integer(PC.TexOffset), 16))
      * TextureScale;
  if (PC.Flags and FlagTarget) = 0 then
  begin
    var Size := TextureSize(UTexture, Level);
    Exit(Integer4(RoundFloat(TexelFetch(UTexture, Clamp(P + Offset, Integer2(0), Size - 1), Level) * 255.0)));
  end;
  var Size := TextureSize(UTexture, 0);
  P := P + Offset;
  var T: Integer4 := Integer4(RoundFloat(TexelFetch(UTexture, Clamp(P, Integer2(0), Size - 1), 0) * 255.0));
  var Format := (PC.Tex shr 19) and 3;
  if Format = 0 then
    Exit(T);
  var AEM := (PC.Tex and (Cardinal(1) shl 21)) <> 0;
  var TA0 := Integer(PC.Texa and 255);
  var TA1 := Integer((PC.Texa shr 8) and 255);
  if Format = 2 then
  begin
    var HighAlpha := T.A >= 128;
    T.RGB := T.RGB and Integer3($F8);
    T.A :=
      if HighAlpha then
        TA1
      else
        (if AEM and (T.R = 0) and (T.G = 0) and (T.B = 0) then 0
      else
        TA0);
  end
  else
    T.A :=
      if AEM and (T.R = 0) and (T.G = 0) and (T.B = 0) then
        0
      else
        TA0;
  Result := T;
end;

function SampleTexLevel(Level: Integer; UV: Integer2; Linear: Boolean): Integer4;
begin
  var W := Max(1, ArithmeticShiftRight(1 shl Integer((PC.Tex shr 24) and 15), Level));
  var H := Max(1, ArithmeticShiftRight(1 shl Integer(PC.Tex shr 28), Level));
  var WMS := (PC.Tex shr 3) and 3;
  var WMT := (PC.Tex shr 5) and 3;
  var MinU := Integer(PC.ClampU and $3FF);
  var MaxU := Integer((PC.ClampU shr 16) and $3FF);
  var MinV := Integer(PC.ClampV and $3FF);
  var MaxV := Integer((PC.ClampV shr 16) and $3FF);
  if WMS <> 3 then
  begin
    MinU := ArithmeticShiftRight(MinU, Level);
    MaxU := ArithmeticShiftRight(MaxU, Level);
  end;
  if WMT <> 3 then
  begin
    MinV := ArithmeticShiftRight(MinV, Level);
    MaxV := ArithmeticShiftRight(MaxV, Level);
  end;
  UV := ArithmeticShiftRight(UV, Level);
  var Scale := TextureScale;
  if not Linear then
    Exit(
      Texel(
        Integer2(
          WrapScaled(ArithmeticShiftRight(UV.X, 4), W, WMS, MinU, MaxU, Scale),
          WrapScaled(ArithmeticShiftRight(UV.Y, 4), H, WMT, MinV, MaxV, Scale)
        ),
        Level
      )
    );
  var U0 := ArithmeticShiftRight(UV.X - 8, 4);
  var V0 := ArithmeticShiftRight(UV.Y - 8, 4);
  var FU := (UV.X - 8) and 15;
  var FV := (UV.Y - 8) and 15;
  var CU0 := WrapScaled(U0, W, WMS, MinU, MaxU, Scale);
  var CU1 := WrapScaled(U0 + 1, W, WMS, MinU, MaxU, Scale);
  var CV0 := WrapScaled(V0, H, WMT, MinV, MaxV, Scale);
  var CV1 := WrapScaled(V0 + 1, H, WMT, MinV, MaxV, Scale);
  var Top := Texel(Integer2(CU0, CV0), Level) * (16 - FU) + Texel(Integer2(CU1, CV0), Level) * FU;
  var Bottom := Texel(Integer2(CU0, CV1), Level) * (16 - FU) + Texel(Integer2(CU1, CV1), Level) * FU;
  Result := ArithmeticShiftRight(Top * (16 - FV) + Bottom * FV, 8);
end;

function SampleTexture(UV: Integer2; LodQ: Single): Integer4;
begin
  var MagLinear := (PC.Tex and 128) <> 0;
  if (PC.Tex and (Cardinal(1) shl 17)) = 0 then
    Exit(SampleTexLevel(0, UV, MagLinear));
  var Lod: Single := PC.LodK;
  if (PC.Tex and (Cardinal(1) shl 14)) = 0 then
    Lod := Lod + -Log2(Max(Abs(LodQ), 1e-30)) * Single(1 shl Integer((PC.Tex shr 15) and 3));
  if Lod < 0.0 then
    Exit(SampleTexLevel(0, UV, MagLinear));
  var MMin := Integer((PC.Tex shr 8) and 7);
  var MXL := Integer((PC.Tex shr 11) and 7);
  var Bilinear := (MMin = 1) or (MMin = 4) or (MMin = 5);
  if (MMin <= 1) or (MXL = 0) then
    Exit(SampleTexLevel(0, UV, Bilinear));
  if (MMin = 2) or (MMin = 4) then
    Exit(SampleTexLevel(Min(Integer(Lod + 0.5), MXL), UV, Bilinear));
  var L0 := Integer(Lod);
  if L0 >= MXL then
    Exit(SampleTexLevel(MXL, UV, Bilinear));
  var Fraction := Integer(RoundFloat((Lod - Single(L0)) * 16.0));
  var A := SampleTexLevel(L0, UV, Bilinear);
  if Fraction <= 0 then
    Exit(A);
  Result := ArithmeticShiftRight(A * (16 - Fraction) + SampleTexLevel(L0 + 1, UV, Bilinear) * Fraction, 4);
end;

function Weight(Code: Cardinal; C: Single): Single;
begin
  if Code = 0 then
    Exit(0.0);
  if Code = 1 then
    Exit(1.0);
  if Code = 2 then
    Exit(C);
  if Code = 3 then
    Exit(Max(1.0 - C, 0.0));
  Result := 1.0 + C;
end;

function AlphaPasses(A: Integer): Boolean;
begin
  var Reference := Integer(PC.AlphaTest and 255);
  case (PC.AlphaTest shr 8) and 7 of
    0: Exit(False);
    1: Exit(True);
    2: Exit(A < Reference);
    3: Exit(A <= Reference);
    4: Exit(A = Reference);
    5: Exit(A >= Reference);
    6: Exit(A > Reference);
  end;
  Result := A <> Reference;
end;

function Shade: Integer4;
begin
  var C: Integer4 := Clamp(Integer4(RoundFloat(VColor * 255.0)), 0, 255);
  if (PC.Flags and FlagTextured) <> 0 then
  begin
    var ST: Single2 := VSTQ.XY;
    var Q: Single := VSTQ.Z;
    if Q <> 1.0 then
      ST :=
        ST
          / (if Q = 0.0 then 1.0
          else
            Q);
    var UV := Integer2(Clamp(ST, Single2(-16777216.0), Single2(16777216.0)) * Single(TextureScale));
    var T := SampleTexture(UV, VLodFog.X);
    var TFX := PC.Tex and 3;
    var TCC := (PC.Tex and 4) <> 0;
    if TFX = 0 then
    begin
      C.RGB := ArithmeticShiftRight(C.RGB * T.RGB, 7);
      if TCC then
        C.A := ArithmeticShiftRight(C.A * T.A, 7);
    end
    else if TFX = 1 then
    begin
      C.RGB := T.RGB;
      if TCC then
        C.A := T.A;
    end
    else
    begin
      C.RGB := ArithmeticShiftRight(C.RGB * T.RGB, 7) + C.A;
      if TCC then
        C.A := if TFX = 2 then T.A + C.A
      else
        T.A;
    end;
    C := Min(C, Integer4(255));
  end;
  if (PC.Flags and FlagFog) <> 0 then
  begin
    var F := Clamp(Integer(RoundFloat(VLodFog.Y)), 0, 255);
    var Fog :=
      Integer3(
        Integer(PC.FogColor and 255),
        Integer((PC.FogColor shr 8) and 255),
        Integer((PC.FogColor shr 16) and 255)
      );
    C.RGB := ArithmeticShiftRight(C.RGB * F + Fog * (255 - F), 8);
  end;
  Result := C;
end;

function BlendInput(Select: Cardinal; Source, Destination: Integer3): Integer3;
begin
  Result :=
    if Select = 0 then
      Source
    else
      (if Select = 1 then Destination
    else
      Integer3(0));
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
      DA :=
        if D.A >= 128 then
          128
        else
          0;
    end
    else if Format = 1 then
      DA := 128;
    var Pass := True;
    if (PixelBits and (Cardinal(1) shl 19)) <> 0 then
      Pass := (DA >= 128) = ((PixelBits and (Cardinal(1) shl 20)) <> 0);
    if Pass then
    begin
      var R := C.RGB;
      if ((PixelBits and (Cardinal(1) shl 16)) <> 0)
        and (((PixelBits and (Cardinal(1) shl 17)) = 0) or (C.A >= 128)) then
      begin
        var CSelect := (PixelBits shr 4) and 3;
        var K :=
          if CSelect = 0 then
            C.A
          else
            (if CSelect = 1 then DA
          else
            Integer((PixelBits shr 8) and 255));
        R :=
          ArithmeticShiftRight(
              (BlendInput(PixelBits and 3, C.RGB, DC) - BlendInput((PixelBits shr 2) and 3, C.RGB, DC)) * K,
              7)
            + BlendInput((PixelBits shr 6) and 3, C.RGB, DC);
      end;
      if (PixelBits and (Cardinal(1) shl 18)) <> 0 then
        R := Clamp(R, 0, 255)
      else
        R := R and Integer3(255);
      var A := C.A;
      if (PixelBits and (Cardinal(1) shl 26)) <> 0 then
        A := A or 128;
      var Color := Cardinal(R.R) or (Cardinal(R.G) shl 8) or (Cardinal(R.B) shl 16) or (Cardinal(A and 255) shl 24);
      var Old := Cardinal(DC.R) or (Cardinal(DC.G) shl 8) or (Cardinal(DC.B) shl 16) or (Cardinal(DA) shl 24);
      var Mask := PC.FBMask;
      if not WriteAlpha then
        Mask := Mask or $FF000000;
      Color := (Color and not Mask) or (Old and Mask);
      var OutputColor :=
        Integer4(
          Integer(Color and 255),
          Integer((Color shr 8) and 255),
          Integer((Color shr 16) and 255),
          Integer(Color shr 24)
        );
      if Format = 2 then
      begin
        OutputColor.RGB := OutputColor.RGB and Integer3($F8);
        OutputColor.A :=
          if OutputColor.A >= 128 then
            255
          else
            0;
      end
      else if Format = 1 then
        OutputColor.A := D.A;
      ImageStore(UTarget, P, Single4(OutputColor) / 255.0);
    end;
  end;
end;
