program PS2HLETextureScaleTest;

{$APPTYPE CONSOLE}

uses
  System.SysUtils, PS2.GS, PS2.GS.Raster, PS2.GS.Memory, RM.Vulkan.TexScale;

const
  Size = 8;
  TextureBase = $100;

procedure Vertex(GS: TPS2GS; X, Y: Integer);
begin
  GS.WriteRegister(GSRegXYZ2, UInt64(Cardinal(X + $8000)) or (UInt64(Cardinal(Y + $8000)) shl 16));
end;

procedure Check(Resolution, Factor, Async: Integer; Filter: TTexScaleFilter; var Checks: Integer);
begin
  var GS := TPS2GS.Create;
  try
    var Source: TArray<Cardinal>;
    SetLength(Source, Size * Size);
    var Memory := GS.Raster.Memory;
    for var Y := 0 to Size - 1 do
      for var X := 0 to Size - 1 do
      begin
        var C := $80000000 or Cardinal(20 + X * 4 + Y * 3) or
          (Cardinal(60 + X * 3) shl 8) or (Cardinal(80 + Y * 5) shl 16);
        if (X >= Y) and (X < 7) then
          C := $801428F0;
        Source[Y * Size + X] := C;
        Memory.WriteRaw(PSMCT32, TextureBase, 1, Cardinal(X), Cardinal(Y), C);
      end;
    var Expected: TArray<Cardinal>;
    SetLength(Expected, Size * Size * Factor * Factor);
    ScaleTexture(@Source[0], Size, Size, Factor, @Expected[0], Filter);
    GS.Raster.ConfigureHLE(Resolution, Factor, Filter);
    GS.Raster.Async := Async <> 0;
    GS.Raster.HLE := True;
    if not GS.Raster.HLE then
      raise Exception.Create(GS.Raster.VulkanError);
    GS.Interlaced := False;
    GS.PMODE := 1 or $20 or (UInt64(128) shl 8);
    GS.DISPFB1 := UInt64(1) shl 9;
    GS.DISPLAY1 := (UInt64(Size - 1) shl 32) or (UInt64(Size - 1) shl 44);
    GS.WriteRegister(GSRegFRAME_1, UInt64(1) shl 16);
    GS.WriteRegister(GSRegZBUF_1, UInt64(1) shl 32);
    GS.WriteRegister(GSRegSCISSOR_1, (UInt64(Size - 1) shl 16) or (UInt64(Size - 1) shl 48));
    GS.WriteRegister(GSRegXYOFFSET_1, $8000 or (UInt64($8000) shl 32));
    GS.WriteRegister(GSRegTEST_1, 0);
    GS.WriteRegister(GSRegTEX0_1, TextureBase or (UInt64(1) shl 14) or (UInt64(3) shl 26) or
      (UInt64(3) shl 30) or (UInt64(1) shl 34) or (UInt64(1) shl 35));
    GS.WriteRegister(GSRegRGBAQ, $80808080);
    GS.WriteRegister(GSRegPRIM, $116);
    // Avoid nearest-sampling ties: HLE interpolators use host FP32.
    GS.WriteRegister(GSRegUV, 1 or (UInt64(1) shl 16));
    Vertex(GS, -8, -8);
    GS.WriteRegister(GSRegUV, (Size * 16 + 1) or (UInt64(Size * 16 + 1) shl 16));
    Vertex(GS, Size * 16 - 8, Size * 16 - 8);
    GS.BuildFrame;
    var Pixels := GS.Frame;
    var Changed := 0;
    for var Y := 0 to Size * Resolution - 1 do
      for var X := 0 to Size * Resolution - 1 do
      begin
        var SX := ((2 * X + 1) * 8 + Resolution) * Factor div (16 * Resolution);
        var SY := ((2 * Y + 1) * 8 + Resolution) * Factor div (16 * Resolution);
        var C := Expected[SY * Size * Factor + SX];
        var Color := $FF000000 or ((C and $FF) shl 16) or (C and $FF00) or ((C shr 16) and $FF);
        var Actual := Pixels[Y * GS.FrameWidth + X];
        if Actual <> Color then
          raise Exception.CreateFmt('Texture res=%d factor=%d async=%d filter=%s xy=%d,%d got %.8x expected %.8x',
            [Resolution, Factor, Async, TexScaleFilterName(Filter), X, Y, Actual, Color]);
        var Native := Source[(Y div Resolution) * Size + X div Resolution];
        if (C and $FFFFFF) <> (Native and $FFFFFF) then
          Inc(Changed);
      end;
    if Changed = 0 then
      raise Exception.Create('Texture scaling did not affect the rendered image');
    for var Y := 0 to Size - 1 do
      for var X := 0 to Size - 1 do
        if Memory.ReadRaw(PSMCT32, TextureBase, 1, Cardinal(X), Cardinal(Y)) <> Source[Y * Size + X] then
          raise Exception.Create('Texture scaling overwrote guest texture memory');
    Writeln(Format('res=%d factor=%d async=%d filter=%s changed=%d: OK',
      [Resolution, Factor, Async, TexScaleFilterName(Filter), Changed]));
    Inc(Checks);
  finally
    GS.Free;
  end;
end;

begin
  try
    var Checks := 0;
    for var Async := 0 to 1 do
      for var Filter := Low(TTexScaleFilter) to High(TTexScaleFilter) do
      begin
        for var Factor := 2 to TexScaleMax do
          Check(Factor, Factor, Async, Filter, Checks);
        Check(3, 6, Async, Filter, Checks);
        Check(4, 3, Async, Filter, Checks);
      end;
    Writeln('PS2 HLE shared texture filters: ', Checks, ' GPU/CPU reference cases: OK');
  except
    on E: Exception do
    begin
      Writeln('FAIL: ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
