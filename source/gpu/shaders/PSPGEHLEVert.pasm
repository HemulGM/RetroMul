// GE vertices are already transformed, lit and clipped. Varyings are linear
// in screen space; the fragment stage performs the texture q division.
{$I PSPGEHLEPush.pasm}

var
  [PushConstant] PC: TGEHLEPush;
  [Input, Location(0)] APos: Single3;
  [Input, Location(1)] AColor: Single4;
  [Input, Location(2)] ASecondary: Single4;
  [Input, Location(3)] ASTQW: Single4;
  [Input, Location(4)] AFog: Single;
  [Input, Location(5)] ABox: Single4;
  [Output, Builtin(Position)] ClipPosition: Single4;
  [Output, Builtin(PointSize)] VertexPointSize: Single;
  [Output, Location(0), NoPerspective] VColor: Single4;
  [Output, Location(1), NoPerspective] VSecondary: Single3;
  [Output, Location(2), NoPerspective] VSTQW: Single4;
  [Output, Location(3), NoPerspective] VFog: Single;
  [Output, Location(4), NoPerspective] VZ: Single;
  [Output, Location(5), Flat] VBox: Single4;

[Vertex, Vulkan11]
procedure Main;
begin
  ClipPosition := Single4(APos.X * PC.NdcScale.X - 1.0,
    APos.Y * PC.NdcScale.Y - 1.0, 0.5, 1.0);
  VertexPointSize := Single((PC.Flags shr 24) and 15);
  VColor := AColor;
  VSecondary := ASecondary.RGB;
  VSTQW := ASTQW;
  VFog := AFog;
  VZ := APos.Z;
  VBox := ABox;
end;
