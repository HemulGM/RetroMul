program PS2HLEColorUploadTest;

// Target colour loaded into the HLE image and resolved back unchanged: every
// frame format, alpha/high bytes, VRAM wrap, resolutions and host rounding
// modes. -require-gpu: fail unless the GPU upload path ran; -all-scales: 1..8x.

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Math, System.Hash, PS2.Types, PS2.GS.Memory, PS2.GS.Raster, PS2.GS.VulkanHLE;

function ValueAt(Index, Format: Cardinal): Cardinal;
begin
  if Format in [PSMCT16, PSMCT16S] then
    Result := Index and $FFFF
  else
    Result := Cardinal((UInt64(Index) * $9E3779B9) and $FFFFFFFF);
end;

function MemoryHash(Memory: TPS2GSMemory): string;
begin
  var H := THashSHA2.Create;
  H.Update(Memory.Data^, PS2GSMemorySize);
  Result := H.HashAsString;
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
    var Before := MemoryHash(Memory);
    HLE := TPS2GSHLE.Create(Memory, @Clut[0], Scale);
    var D := Default(TPS2GSDraw);
    D.FBP := BP;
    D.FBW := BW;
    D.FPSM := Format;
    D.ZBP := $2800;
    D.ZPSM := PSMZ24;
    D.ZMax := $FFFFFF;
    D.ZMSK := True;
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
    // All zero source/resident depth comparisons fail GREATER. Resolve the
    // tracked colour without changing it, including native alpha/high bytes.
    if not HLE.Renderer.Sprite(D, A, B, 0, 0, Width, Height) then
      raise Exception.Create('Colour upload probe was not accepted');
    HLE.Renderer.SyncAll;
    if MemoryHash(Memory) <> Before then
      raise Exception.CreateFmt('Colour upload changed VRAM scale=%d format=%x bp=%x bw=%d',
        [Scale, Format, BP, BW]);
    Inc(Samples, Width * Height);
    var Report := HLE.Renderer.Describe;
    var At := Pos(' cgpu=', Report);
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
          for var Format in [PSMCT32, PSMCT24, PSMCT16, PSMCT16S] do
            for var BP in TArray<Cardinal>.Create($1000, $3FF0) do
              for var BW in [1, 4] do
                CheckCase(Scale, Format, BP, Cardinal(BW), Cases, Samples, Gpu);
      end;
      if FindCmdLineSwitch('require-gpu') and (Gpu = 0) then
        raise Exception.Create('GPU colour upload path was not exercised');
      Writeln(Cases, ' colour upload/readback cases, ', Samples, ' exact samples, GPU uploads=', Gpu,
        ': formats/alpha/exhaustive16/wrap/scaling/four modes: OK');
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
