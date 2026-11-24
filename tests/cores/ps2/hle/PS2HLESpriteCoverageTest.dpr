program PS2HLESpriteCoverageTest;

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Math, PS2.GS, PS2.GS.Raster, PS2.GS.Memory, RM.Vulkan.TexScale;

procedure Vertex(GS: TPS2GS; X, Y: Cardinal);
begin
  GS.WriteRegister(GSRegXYZ2, UInt64(X + $8000) or (UInt64(Y + $8000) shl 16));
end;

procedure Check(Scale, Async, Shape: Integer; var Checks: Integer);
begin
  var GS := TPS2GS.Create;
  try
    var Memory := GS.Raster.Memory;
    for var Y := 0 to 15 do
      for var X := 0 to 15 do
        Memory.WriteRaw(PSMCT32, 0, 1, Cardinal(X), Cardinal(Y), $80FFFFFF);
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
    GS.WriteRegister(GSRegXYOFFSET_1, $8000 or (UInt64($8000) shl 32));
    var X0 := 0;
    var Y0 := 0;
    var X1 := 256;
    var Y1 := 256;
    var SX0 := 0;
    var SY0 := 0;
    var SX1 := 15;
    var SY1 := 15;
    case Shape of
      1:
        begin
          X0 := 4;
          Y0 := 12;
          X1 := 248;
          Y1 := 252;
        end;
      2:
        begin
          X0 := 256;
          Y0 := 256;
          X1 := 0;
          Y1 := 0;
        end;
      3:
        begin
          SX0 := 2;
          SY0 := 3;
          SX1 := 13;
          SY1 := 12;
        end;
    end;
    GS.WriteRegister(GSRegSCISSOR_1, UInt64(SX0) or (UInt64(SX1) shl 16) or
      (UInt64(SY0) shl 32) or (UInt64(SY1) shl 48));
    GS.WriteRegister(GSRegTEST_1, 0);
    GS.WriteRegister(GSRegRGBAQ, $80000000);
    GS.WriteRegister(GSRegPRIM, 6);
    Vertex(GS, Cardinal(X0), Cardinal(Y0));
    Vertex(GS, Cardinal(X1), Cardinal(Y1));
    var Left := Max((Min(X0, X1) + 15) div 16, SX0);
    var Top := Max((Min(Y0, Y1) + 15) div 16, SY0);
    var Right := Min((Max(X0, X1) + 15) div 16, SX1 + 1);
    var Bottom := Min((Max(Y0, Y1) + 15) div 16, SY1 + 1);
    GS.BuildFrame;
    var Pixels := GS.Frame;
    for var Y := 0 to 16 * Scale - 1 do
      for var X := 0 to 16 * Scale - 1 do
      begin
        var Expected: Cardinal := $FFFFFFFF;
        if (X div Scale >= Left) and (X div Scale < Right) and
          (Y div Scale >= Top) and (Y div Scale < Bottom) then
          Expected := $FF000000;
        if Pixels[Y * GS.FrameWidth + X] <> Expected then
          raise Exception.CreateFmt('Sprite coverage scale=%d async=%d shape=%d xy=%d,%d: %.8x expected %.8x',
            [Scale, Async, Shape, X, Y, Pixels[Y * GS.FrameWidth + X], Expected]);
      end;
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
    Writeln('Scaled GS sprite native-pixel coverage: ', Checks, ' clear/fractional/reversed/scissor cases: OK');
  except
    on E: Exception do
    begin
      Writeln('FAIL: ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
