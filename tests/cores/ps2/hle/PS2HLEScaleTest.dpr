program PS2HLEScaleTest;

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, Core.Snapshots, PS2.GS, PS2.GS.Raster, RM.Vulkan.TexScale;

procedure Vertex(GS: TPS2GS; X, Y: Cardinal);
begin
  GS.WriteRegister(GSRegXYZ2, UInt64(X) or (UInt64(Y) shl 16));
end;

procedure Check(Scale, Async: Integer; var Checks: Integer);
begin
  var GS := TPS2GS.Create;
  try
    GS.Raster.ConfigureHLE(Scale, 0, tfXBRZ);
    GS.Raster.Async := Async <> 0;
    GS.Raster.HLE := True;
    if not GS.Raster.HLE then
      raise Exception.Create(GS.Raster.VulkanError);
    GS.PMODE := 1 or $20 or (UInt64(128) shl 8);
    GS.DISPFB1 := UInt64(1) shl 9;
    GS.DISPLAY1 := (UInt64(15) shl 32) or (UInt64(15) shl 44);
    GS.WriteRegister(GSRegFRAME_1, UInt64(1) shl 16);
    GS.WriteRegister(GSRegZBUF_1, UInt64(1) shl 32);
    GS.WriteRegister(GSRegSCISSOR_1, (UInt64(15) shl 16) or (UInt64(15) shl 48));
    GS.WriteRegister(GSRegTEST_1, 0);
    GS.WriteRegister(GSRegRGBAQ, $800000FF);
    GS.WriteRegister(GSRegPRIM, 3);
    Vertex(GS, 20, 20);
    Vertex(GS, 232, 36);
    Vertex(GS, 44, 224);
    GS.BuildFrame;
    var Pixels := GS.Frame;
    if (GS.FrameWidth <> 16 * Scale) or (GS.FrameHeight <> 16 * Scale) or
      (GS.NativeFrameWidth <> 16) or (GS.NativeFrameHeight <> 16) then
      raise Exception.CreateFmt('Wrong frame size scale=%d async=%d: %dx%d native %dx%d',
        [Scale, Async, GS.FrameWidth, GS.FrameHeight, GS.NativeFrameWidth, GS.NativeFrameHeight]);
    var Detail := False;
    for var Y := 0 to 15 do
      for var X := 0 to 15 do
        for var SY := 0 to Scale - 1 do
          for var SX := 0 to Scale - 1 do
            if Pixels[(Y * Scale + SY) * GS.FrameWidth + X * Scale + SX] <>
              Pixels[Y * Scale * GS.FrameWidth + X * Scale] then
              Detail := True;
    if (Scale > 1) and not Detail then
      raise Exception.Create('Frame was stretched from native pixels instead of rendered at the internal resolution');
    var Stream := TMemoryStream.Create;
    try
      var Archive := TStateArchive.Create(Stream, False);
      try
        GS.SerializeState(Archive);
      finally
        Archive.Free;
      end;
      Writeln(Format('scale=%d async=%d detail=%s pixels=%d state-bytes=%d %s',
        [Scale, Async, BoolToStr(Detail, True), Length(Pixels), Stream.Size, GS.Raster.HLEReport]));
    finally
      Stream.Free;
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
        Check(Scale, Async, Checks);
    Writeln('Real PS2 HLE resolution: ', Checks, ' direct/worker cases: OK');
  except
    on E: Exception do
    begin
      Writeln('FAIL: ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
