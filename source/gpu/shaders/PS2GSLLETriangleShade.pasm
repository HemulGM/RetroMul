// Phase A: one group per draw/tile entry, with two unconditional barriers.
{$I PS2GSLLETriangleInputs.pasm}

  [Shared] CoveredBits: TPS2CoveredBits;

{$I PS2GSLLEPixel.pasm}
{$I PS2GSLLETriangleMath.pasm}

[Vulkan11, StrictFloat, LocalSize(8, 8, 1)]
procedure Main;
begin
  var LI := LocalInvocationIndex;
  var E := WorkgroupID.Y * 32768 + WorkgroupID.X;
  if LI < 2 then
    CoveredBits[LI] := 0;
  Barrier;
  var Valid := E < PC.Count;
  var Covered := False;
  var Z: Cardinal := 0;
  var RGBA: Cardinal := 0;
  var Ctx := Default(TPS2PixelContext);
  if Valid then
  begin
    var Entry := Tiles[PC.EntryBase + E];
    var Tile := Entry and $FFFF;
    Ctx.DrawIndex := PC.Slot + (Entry shr 16);
    var XY := Integer2(PC.X0, PC.Y0) + Integer2(Integer((Tile mod PC.Width) * 8),
      Integer((Tile div PC.Width) * 8)) + Integer2(LocalInvocationID.XY);
    var W0: Double;
    var W1: Double;
    var W2: Double;
    Covered := Cover(Ctx, XY, Z, W0, W1, W2);
    if Covered then
      RGBA := CoveredColor(Ctx, XY, W0, W1, W2);
  end;
  if Covered then
    AtomicOr(CoveredBits[LI shr 5], Cardinal(1) shl (LI and 31));
  Barrier;
  if Valid then
  begin
    var R := PC.ResultBase + E;
    if Covered then
    begin
      Results[R * 128 + LI * 2] := Z;
      Results[R * 128 + LI * 2 + 1] := RGBA;
    end;
    if LI < 2 then
      Results[PC.MaskBase + R * 2 + LI] := CoveredBits[LI];
  end;
end;
