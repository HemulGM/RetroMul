program PS2HLEDepthUploadTest;

// 24/16-bit depth loaded into the HLE image and resolved back to the same
// integers: every 16-bit value, dense 24-bit values, VRAM wrap, resolutions
// and host rounding modes. Switches as PS2HLEColorUploadTest.

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Math, PS2.Types, PS2.GS.Memory, PS2.GS.Raster, PS2.GS.VulkanHLE;

function ValueAt(Index, Format: Cardinal): Cardinal;
const
  Edges: array[0..15] of Cardinal = (0, 1, 2, 3, $FF, $100, $FFFF, $10000,
    $1FFFF, $20000, $3FFFFF, $400000, $7FFFFF, $800000, $FFFFFE, $FFFFFF);
begin
  if Index < Length(Edges) then
    Result := Edges[Index]
  else
    Result := Cardinal((UInt64(Index) * $9E3779B9) and $FFFFFF);
  if Format <> PSMZ24 then
    Result := Index and $FFFF;
end;

procedure CheckCase(Scale: Integer; Format, BP, BW: Cardinal; var Cases, Samples, Gpu: Integer);
begin
  var Memory := TPS2GSMemory.Create;
  var Clut := Default(TPS2GSClut);
  var HLE: TPS2GSHLE := nil;
  try
    Memory.Clear;
    var Width := Integer(BW * 64);
    var Height := 64;
    if BW = 4 then
      Height := 256;
    for var Y := 0 to Height - 1 do
      for var X := 0 to Width - 1 do
        Memory.WriteRaw(Integer(Format), BP, BW, Cardinal(X), Cardinal(Y),
          ValueAt(Cardinal(Y * Width + X), Format));
    HLE := TPS2GSHLE.Create(Memory, @Clut[0], Scale);
    var D := Default(TPS2GSDraw);
    D.FBP := $1000;
    D.FBW := BW;
    D.FPSM := PSMCT32;
    D.ZBP := BP;
    D.ZPSM := Format;
    D.ZMax := $FFFFFF;
    if Format <> PSMZ24 then
      D.ZMax := $FFFF;
    D.SX1 := Width - 1;
    D.SY1 := Height - 1;
    D.ZTE := True;
    D.ZTST := 3;
    D.ColClamp := True;
    var A := Default(TPS2GSVertex);
    A.Q := 1;
    A.A := 128;
    var B := A;
    B.X := Width * 16;
    B.Y := Height * 16;
    // Zero is never greater than the nonnegative resident depth. No pixel
    // writes, but resolving the tracked depth reads back the uploaded image.
    if not HLE.Renderer.Sprite(D, A, B, 0, 0, Width, Height) then
      raise Exception.Create('Depth upload probe was not accepted');
    HLE.Renderer.SyncAll;
    for var Y := 0 to Height - 1 do
      for var X := 0 to Width - 1 do
      begin
        var Expected := ValueAt(Cardinal(Y * Width + X), Format);
        var Actual := Memory.ReadRaw(Integer(Format), BP, BW, Cardinal(X), Cardinal(Y));
        if Actual <> Expected then
          raise Exception.CreateFmt('Depth upload mismatch scale=%d format=%x bp=%x bw=%d x=%d y=%d expected=%x actual=%x',
            [Scale, Format, BP, BW, X, Y, Expected, Actual]);
        Inc(Samples);
      end;
    var Report := HLE.Renderer.Describe;
    var At := Pos(' zgpu=', Report);
    if At > 0 then
    begin
      Inc(At, 6);
      var Count := '';
      while (At <= Length(Report)) and CharInSet(Report[At], ['0'..'9']) do
      begin
        Count := Count + Report[At];
        Inc(At);
      end;
      Inc(Gpu, StrToIntDef(Count, 0));
    end;
    Inc(Cases);
  finally
    HLE.Free;
    Memory.Free;
  end;
end;

begin
  var Saved := GetRoundMode;
  try
    try
      var Cases := 0;
      var Samples := 0;
      var Gpu := 0;
      var Scales := TArray<Integer>.Create(1, 2);
      if FindCmdLineSwitch('all-scales') then
        Scales := TArray<Integer>.Create(1, 2, 3, 4, 5, 6, 7, 8);
      for var Mode := Low(TRoundingMode) to High(TRoundingMode) do
      begin
        SetRoundMode(Mode);
        for var Scale in Scales do
          for var Format in [PSMZ24, PSMZ16, PSMZ16S] do
            for var BP in TArray<Cardinal>.Create($2000, $3FF0) do
              for var BW in [1, 4] do
                CheckCase(Scale, Format, BP, Cardinal(BW), Cases, Samples, Gpu);
      end;
      if FindCmdLineSwitch('require-gpu') and (Gpu = 0) then
        raise Exception.Create('GPU depth upload path was not exercised');
      Writeln(Cases, ' depth upload/readback cases, ', Samples, ' exact samples, GPU uploads=', Gpu,
        ': exhaustive16/dense24/wrap/scaling/four modes: OK');
    except
      on E: Exception do
      begin
        Writeln('FAIL: ', E.ClassName, ': ', E.Message);
        ExitCode := 1;
      end;
    end;
  finally
    SetRoundMode(Saved);
  end;
end.
