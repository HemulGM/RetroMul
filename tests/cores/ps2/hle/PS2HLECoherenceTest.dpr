program PS2HLECoherenceTest;

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.SyncObjs, System.Diagnostics, PS2.GS, PS2.GS.Raster, PS2.GS.Memory,
  RM.Vulkan.TexScale;

const
  Formats: array[0..3] of Cardinal = (PSMCT32, PSMCT24, PSMCT16, PSMCT16S);
  Depths: array[0..3] of Cardinal = (PSMZ32, PSMZ24, PSMZ16, PSMZ16S);

procedure Sprite(GS: TPS2GS; Color, Z: Cardinal);
begin
  GS.WriteRegister(GSRegRGBAQ, Color);
  GS.WriteRegister(GSRegPRIM, 6);
  GS.WriteRegister(GSRegXYZ2, UInt64(Z) shl 32);
  GS.WriteRegister(GSRegXYZ2, 256 or (UInt64(256) shl 16) or (UInt64(Z) shl 32));
end;

procedure Display(GS: TPS2GS; Format: Cardinal);
begin
  GS.Interlaced := False;
  GS.PMODE := 1 or $20 or (UInt64(128) shl 8);
  GS.DISPFB1 := (UInt64(1) shl 9) or (UInt64(Format) shl 15);
  GS.DISPLAY1 := (UInt64(15) shl 32) or (UInt64(15) shl 44);
end;

procedure Check(Scale, Async, FormatIndex: Integer; var Checks: Integer);
begin
  var GS := TPS2GS.Create;
  try
    GS.Raster.ConfigureHLE(Scale, 0, tfXBRZ);
    GS.Raster.Async := Async <> 0;
    GS.Raster.HLE := True;
    if not GS.Raster.HLE then
      raise Exception.Create(GS.Raster.VulkanError);
    var PSM := Formats[FormatIndex];
    var ZPSM := Depths[FormatIndex];
    Display(GS, PSM);
    GS.WriteRegister(GSRegFRAME_1, (UInt64(1) shl 16) or (UInt64(PSM) shl 24));
    GS.WriteRegister(GSRegZBUF_1, $80 or (UInt64(ZPSM and 15) shl 24));
    GS.WriteRegister(GSRegTEST_1, $30000);
    GS.WriteRegister(GSRegSCISSOR_1, (UInt64(15) shl 16) or (UInt64(15) shl 48));
    var Z: Cardinal := $123400;
    if FormatIndex >= 2 then
      Z := $1234;
    Sprite(GS, $80000080, Z);
    GS.BuildFrame;
    var Pixels := GS.Frame;
    if Pixels[(10 * Scale) * GS.FrameWidth + 10 * Scale] <> $FF800000 then
      raise Exception.CreateFmt('Scaled color mismatch scale=%d format=%x', [Scale, PSM]);
    var Memory := GS.Raster.Memory;
    var Expected: Cardinal := $80000080;
    if FormatIndex = 1 then
      Expected := $80
    else if FormatIndex >= 2 then
      Expected := Color32To16(Expected);
    if (Memory.ReadRaw(Integer(PSM), 0, 1, 10, 10) <> Expected) or
      (Memory.ReadRaw(Integer(ZPSM), $1000, 1, 10, 10) <> Z) then
      raise Exception.CreateFmt('Native color/depth resolve mismatch scale=%d format=%x', [Scale, PSM]);
    var Blue: Cardinal := $80FF0000;
    if FormatIndex >= 2 then
      Blue := Color32To16(Blue);
    Memory.WriteRaw(Integer(PSM), 0, 1, 10, 10, Blue);
    GS.BuildFrame;
    Pixels := GS.Frame;
    var ExpectedBlue: Cardinal := $FF0000FF;
    if FormatIndex >= 2 then
      ExpectedBlue := $FF0000F8;
    for var Y := 10 * Scale to 11 * Scale - 1 do
      for var X := 10 * Scale to 11 * Scale - 1 do
        if Pixels[Y * GS.FrameWidth + X] <> ExpectedBlue then
          raise Exception.Create('Display reused a stale high-resolution image after a CPU write');
    Inc(Checks);
    Writeln(Format('scale=%d async=%d format=%x native depth and CPU-write coherence: OK', [Scale, Async, PSM]));
  finally
    GS.Free;
  end;
end;

procedure CheckCircuits(Scale, Async: Integer; var Checks: Integer);
begin
  var GS := TPS2GS.Create;
  try
    GS.Raster.ConfigureHLE(Scale, 0, tfXBRZ);
    GS.Raster.Async := Async <> 0;
    GS.Raster.HLE := True;
    if not GS.Raster.HLE then
      raise Exception.Create(GS.Raster.VulkanError);
    Display(GS, PSMCT32);
    GS.WriteRegister(GSRegZBUF_1, UInt64(1) shl 32);
    GS.WriteRegister(GSRegSCISSOR_1, (UInt64(15) shl 16) or (UInt64(15) shl 48));
    GS.WriteRegister(GSRegFRAME_1, UInt64(1) shl 16);
    Sprite(GS, $80000080, 0);
    GS.WriteRegister(GSRegFRAME_1, $20 or (UInt64(1) shl 16));
    Sprite(GS, $80800000, 0);
    GS.DISPFB2 := $20 or (UInt64(1) shl 9);
    GS.DISPLAY2 := GS.DISPLAY1;
    GS.PMODE := 3 or $20 or (UInt64(64) shl 8);
    GS.BuildFrame;
    var Pixels := GS.Frame;
    if Pixels[(8 * Scale) * GS.FrameWidth + 8 * Scale] <> $FF400040 then
      raise Exception.Create('Scaled dual-circuit composition mismatch');
    Inc(Checks);
  finally
    GS.Free;
  end;
end;

procedure CheckTransitions(var Checks: Integer);
begin
  var GS := TPS2GS.Create;
  var Callbacks: Int64 := 0;
  try
    Display(GS, PSMCT32);
    GS.Raster.Async := True;
    GS.OnFrame := procedure(const Pixels: TArray<Cardinal>; W, H: Integer; Number: Int64)
      begin
        var Scale := 1;
        if (Number >= 5) and (Number <= 8) then
          Scale := 2
        else if Number = 13 then
          Scale := 4;
        if (W <> 16 * Scale) or (H <> 16 * Scale) or
          (GS.NativeFrameWidth <> 16) or (GS.NativeFrameHeight <> 16) then
          raise Exception.Create('Frame metadata changed while its callback was running');
        TInterlocked.Increment(Callbacks);
      end;
    GS.WriteRegister(GSRegFRAME_1, UInt64(1) shl 16);
    GS.WriteRegister(GSRegZBUF_1, UInt64(1) shl 32);
    GS.WriteRegister(GSRegSCISSOR_1, (UInt64(15) shl 16) or (UInt64(15) shl 48));
    for var Number := 1 to 13 do
    begin
      var Scale := 1;
      if (Number >= 5) and (Number <= 8) then
        Scale := 2
      else if Number = 13 then
        Scale := 4;
      GS.Raster.ConfigureHLE(Scale, 0, tfXBRZ);
      GS.Raster.HLE := Number >= 5;
      GS.FrameNumber := Number;
      Sprite(GS, $80000080, 0);
      GS.BuildFrame;
    end;
    var Pixels := GS.Frame;
    var Watch := TStopwatch.StartNew;
    while (TInterlocked.Read(Callbacks) < 13) and (Watch.ElapsedMilliseconds < 5000) do
      Sleep(1);
    if (Length(Pixels) <> 64 * 64) or (TInterlocked.Read(Callbacks) <> 13) then
      raise Exception.Create('Renderer transition lost a callback or deadlocked');
    Inc(Checks);
  finally
    GS.Free;
  end;
end;

begin
  try
    var Checks := 0;
    for var Async := 0 to 1 do
      for var Scale in [1, 2, 3, 4, 8] do
      begin
        for var FormatIndex := 0 to High(Formats) do
          Check(Scale, Async, FormatIndex, Checks);
        CheckCircuits(Scale, Async, Checks);
      end;
    CheckTransitions(Checks);
    Writeln('PS2 HLE scaled coherence: ', Checks, ' color/depth/CPU writes/dual-circuit cases: OK');
  except
    on E: Exception do
    begin
      Writeln('FAIL: ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
