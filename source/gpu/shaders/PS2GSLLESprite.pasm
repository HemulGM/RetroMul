// Sprites and host-prepared triangle fragments, one invocation per pixel.
{$I PS2GSLLETypes.pasm}
{$I PS2GSLLETables.pasm}

var
  [Binding(0, 0)] RAM: array of Cardinal;
  [Binding(0, 1), ReadOnly] Draws: array of TPS2Draw;
  [Binding(0, 2), ReadOnly] Coordinates: array of Integer;
  [Binding(0, 3), ReadOnly] Fragments: array of Cardinal;
  [PushConstant] PC: TPS2SpritePush;

{$I PS2GSLLEPixel.pasm}

[Vulkan11, LocalSize(8, 8, 1)]
procedure Main;
begin
  var Ctx := Default(TPS2PixelContext);
  Ctx.DrawIndex := PC.Slot;
  var XY: Integer2;
  var Base: Cardinal := 0;
  if PC.Mode = 0 then
  begin
    XY := Integer2(PC.X0, PC.Y0) + Integer2(GlobalInvocationID.XY);
    if (XY.X >= PC.X1) or (XY.Y >= PC.Y1) then
      Exit;
  end
  else
  begin
    var Index := WorkgroupID.X * 64 + LocalInvocationIndex;
    if Index >= Cardinal(PC.Y0) then
      Exit;
    Base := (Cardinal(PC.X0) + Index) * 11;
    XY := Integer2(Integer(Fragments[Base]), Integer(Fragments[Base + 1]));
  end;
  var C := if PC.Mode = 0 then Integer3(Integer(DrawParam(Ctx, 26)), Integer(DrawParam(Ctx, 27)), Integer(DrawParam(Ctx, 28))) else
    Integer3(Integer(Fragments[Base + 3]), Integer(Fragments[Base + 4]), Integer(Fragments[Base + 5]));
  var A := Integer(if PC.Mode = 0 then DrawParam(Ctx, 29) else Fragments[Base + 6]);
  var F := Integer(if PC.Mode = 0 then DrawParam(Ctx, 30) else Fragments[Base + 7]);
  var Z := if PC.Mode = 0 then DrawParam(Ctx, 31) else Fragments[Base + 2];
  var U := 0;
  var V := 0;
  var Mip: Cardinal := 0;
  if DrawParam(Ctx, 47) <> 0 then
  begin
    U := if PC.Mode = 0 then Coordinates[PC.Slot * 4096 + Cardinal(XY.X - PC.X0)] else Integer(Fragments[Base + 8]);
    V := if PC.Mode = 0 then Coordinates[PC.Slot * 4096 + 2048 + Cardinal(XY.Y - PC.Y0)] else Integer(Fragments[Base + 9]);
    Mip := if PC.Mode = 0 then DrawParam(Ctx, 52) else Fragments[Base + 10];
  end;
  ShadePixel(Ctx, XY, Z, C, A, F, U, V, Mip);
end;
