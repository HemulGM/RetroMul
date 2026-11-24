// Phase B, or both phases for short clusters: one owner per physical pixel.
{$I PS2GSLLETriangleInputs.pasm}
{$I PS2GSLLEPixel.pasm}
{$I PS2GSLLETriangleMath.pasm}

[Vulkan11, StrictFloat, LocalSize(8, 8, 1)]
procedure Main;
begin
  var LI := LocalInvocationIndex;
  var XY := Integer2(PC.X0, PC.Y0) + Integer2(GlobalInvocationID.XY);
  var Ctx := Default(TPS2PixelContext);
  Ctx.PixelCache := True;
  var Tile := WorkgroupID.Y * NumWorkgroups.X + WorkgroupID.X;
  var First := Tiles[PC.TileBase + Tile * 2];
  var Count := Tiles[PC.TileBase + Tile * 2 + 1];
  var I: Cardinal := 0;
  while I < Count do
  begin
    var E := First + I;
    Inc(I);
    var R := PC.ResultBase + E;
    var Z: Cardinal;
    var RGBA: Cardinal;
    Ctx.DrawIndex := PC.Slot + (Tiles[PC.EntryBase + E] shr 16);
    if PC.Mode = 2 then
    begin
      var W0: Double;
      var W1: Double;
      var W2: Double;
      if not Cover(Ctx, XY, Z, W0, W1, W2) or not DepthPass(Ctx, XY, Z) then
        Continue;
      RGBA := CoveredColor(Ctx, XY, W0, W1, W2);
    end
    else
    begin
      if ((Results[PC.MaskBase + R * 2 + (LI shr 5)] shr (LI and 31)) and 1) = 0 then
        Continue;
      Z := Results[R * 128 + LI * 2];
      if not DepthPass(Ctx, XY, Z) then
        Continue;
      RGBA := Results[R * 128 + LI * 2 + 1];
    end;
    WritePixel(Ctx, XY, Z, Integer3(Integer(RGBA and 255), Integer((RGBA shr 8) and 255),
      Integer((RGBA shr 16) and 255)), Integer(RGBA shr 24));
  end;
  FinishPixelCache(Ctx);
end;
