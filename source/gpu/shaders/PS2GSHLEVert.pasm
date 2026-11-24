// GS screen-space vertices and linearly interpolated attributes.
{$I PS2GSHLEPush.pasm}

var
  [PushConstant] PC: TPS2HLEPush;
  [Input, Location(0)] APos: Single3;
  [Input, Location(1)] AColor: Single4;
  [Input, Location(2)] ASTQ: Single3;
  [Input, Location(3)] ALodFog: Single2;
  [Output, Builtin(Position)] ClipPosition: Single4;
  [Output, Location(0), NoPerspective] VColor: Single4;
  [Output, Location(1), NoPerspective] VSTQ: Single3;
  [Output, Location(2), NoPerspective] VLodFog: Single2;

[Vertex, Vulkan11]
procedure Main;
begin
  ClipPosition := Single4(APos.X * PC.NdcScale.X - 1.0,
    APos.Y * PC.NdcScale.Y - 1.0, APos.Z, 1.0);
  VColor := AColor;
  VSTQ := ASTQ;
  VLodFog := ALodFog;
end;
