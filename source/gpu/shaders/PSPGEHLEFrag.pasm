// Fixed-function blend path. Colour, alpha and depth tests remain GE arithmetic.
{$I PSPGEHLEPush.pasm}

var
  [PushConstant] PC: TGEHLEPush;
  [Input, Location(0), NoPerspective] VColor: Single4;
  [Input, Location(1), NoPerspective] VSecondary: Single3;
  [Input, Location(2), NoPerspective] VSTQW: Single4;
  [Input, Location(3), NoPerspective] VFog: Single;
  [Input, Location(4), NoPerspective] VZ: Single;
  [Input, Location(5), Flat] VBox: Single4;
  [Input, Builtin(FragCoord)] Pixel: Single4;
  [Output, Location(0)] OColor: Single4;
  [Output, Builtin(FragDepth)] ODepth: Single;
  [Binding(0, 0)] UTexture: CombinedTexture2D;

{$I PSPGEHLEFragment.pasm}

[Fragment, Vulkan11]
procedure Main;
begin
  var ZR: Single;
  var C := Shade(ZR, False);
  ODepth := Clamp(ZR, 0.0, 65535.0) * (1.0 / 65536.0);
  OColor := Single4(C) / 255.0;
end;
