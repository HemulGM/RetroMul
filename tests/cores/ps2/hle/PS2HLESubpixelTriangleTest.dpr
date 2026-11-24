program PS2HLESubpixelTriangleTest;

{$APPTYPE CONSOLE}

uses
  System.SysUtils, PS2.GS, PS2.GS.Raster, RM.Vulkan.TexScale;

procedure Vertex(GS: TPS2GS; X, Y: Integer);
begin
  GS.WriteRegister(GSRegXYZ2, UInt64(Cardinal(X + $8000)) or (UInt64(Cardinal(Y + $8000)) shl 16));
end;

procedure Check(Scale, Async, Shape: Integer; var Checks: Integer);
begin
  var GS := TPS2GS.Create;
  try
    GS.Raster.ConfigureHLE(Scale, 0, tfXBRZ);
    GS.Raster.Async := Async <> 0;
    GS.Raster.HLE := True;
    if not GS.Raster.HLE then
      raise Exception.Create(GS.Raster.VulkanError);
    GS.Interlaced := False;
    GS.PMODE := 1 or $20 or (UInt64(128) shl 8);
    GS.DISPFB1 := UInt64(1) shl 9;
    GS.DISPLAY1 := (UInt64(15) shl 32) or (UInt64(15) shl 44);
    GS.WriteRegister(GSRegFRAME_1, UInt64(1) shl 16);
    GS.WriteRegister(GSRegZBUF_1, UInt64(1) shl 32);
    GS.WriteRegister(GSRegSCISSOR_1, (UInt64(15) shl 16) or (UInt64(15) shl 48));
    GS.WriteRegister(GSRegXYOFFSET_1, $8000 or (UInt64($8000) shl 32));
    GS.WriteRegister(GSRegTEST_1, 0);
    GS.WriteRegister(GSRegRGBAQ, $80FFFFFF);
    var X0 := 65;
    var Y0 := 32;
    var X1 := 73;
    var Y1 := 96;
    case Shape of
      1:
        begin
          X0 := 32;
          Y0 := 65;
          X1 := 96;
          Y1 := 73;
        end;
      2:
        begin
          Y0 := 65;
          Y1 := 73;
        end;
    end;
    GS.WriteRegister(GSRegPRIM, 3);
    Vertex(GS, X0, Y0);
    if Shape = 3 then
    begin
      Vertex(GS, X0, Y1);
      Vertex(GS, X1, Y0);
    end
    else
    begin
      Vertex(GS, X1, Y0);
      Vertex(GS, X0, Y1);
    end;
    Vertex(GS, X1, Y0);
    if Shape = 3 then
    begin
      Vertex(GS, X0, Y1);
      Vertex(GS, X1, Y1);
    end
    else
    begin
      Vertex(GS, X1, Y1);
      Vertex(GS, X0, Y1);
    end;
    GS.BuildFrame;
    var Pixels := GS.Frame;
    var Painted := 0;
    for var Y := 0 to 16 * Scale - 1 do
      for var X := 0 to 16 * Scale - 1 do
      begin
        var PX := 8 * (2 * X + 1 - Scale);
        var PY := 8 * (2 * Y + 1 - Scale);
        var Expected: Cardinal := $FF000000;
        if (PX >= X0 * Scale) and (PX < X1 * Scale) and
          (PY >= Y0 * Scale) and (PY < Y1 * Scale) then
        begin
          Expected := $FFFFFFFF;
          Inc(Painted);
        end;
        if Pixels[Y * GS.FrameWidth + X] <> Expected then
          raise Exception.CreateFmt('Subpixel triangle scale=%d async=%d shape=%d xy=%d,%d: %.8x expected %.8x',
            [Scale, Async, Shape, X, Y, Pixels[Y * GS.FrameWidth + X], Expected]);
      end;
    if (Scale > 1) and (Painted = 0) then
      raise Exception.Create('Scaled subpixel triangle test did not cover any samples');
    Inc(Checks);
  finally
    GS.Free;
  end;
end;

begin
  try
    var Checks := 0;
    for var Async := 0 to 1 do
      for var Scale in [1, 2, 3, 4, 6, 8] do
        for var Shape := 0 to 3 do
          Check(Scale, Async, Shape, Checks);
    Writeln('PS2 HLE subpixel triangles: ', Checks, ' native-empty vertical/horizontal/tiny/reversed cases: OK');
  except
    on E: Exception do
    begin
      Writeln('FAIL: ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
