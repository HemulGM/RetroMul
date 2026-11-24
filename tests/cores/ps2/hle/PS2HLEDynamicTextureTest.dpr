program PS2HLEDynamicTextureTest;

{$APPTYPE CONSOLE}

uses
  System.SysUtils, PS2.GS, PS2.GS.Raster, PS2.GS.Memory, RM.Vulkan.TexScale;

procedure Check(Async: Integer; Filter: TTexScaleFilter);
begin
  var GS := TPS2GS.Create;
  try
    var Source: array[0..63] of Cardinal;
    var Memory := GS.Raster.Memory;
    for var Y := 0 to 7 do
      for var X := 0 to 7 do
      begin
        var C: Cardinal := $80000000;
        if X >= Y then
          C := $80FFFFFF;
        Source[Y * 8 + X] := C;
        Memory.WriteRaw(PSMCT32, $100, 1, Cardinal(X), Cardinal(Y), C);
      end;
    GS.Raster.ConfigureHLE(2, 2, Filter);
    GS.Raster.Async := Async <> 0;
    GS.Raster.HLE := True;
    if not GS.Raster.HLE then
      raise Exception.Create(GS.Raster.VulkanError);
    GS.Interlaced := False;
    GS.PMODE := 1 or $20 or (UInt64(128) shl 8);
    GS.DISPFB1 := UInt64(1) shl 9;
    GS.DISPLAY1 := (UInt64(7) shl 32) or (UInt64(7) shl 44);
    GS.WriteRegister(GSRegFRAME_1, UInt64(1) shl 16);
    GS.WriteRegister(GSRegZBUF_1, UInt64(1) shl 32);
    GS.WriteRegister(GSRegSCISSOR_1, (UInt64(7) shl 16) or (UInt64(7) shl 48));
    GS.WriteRegister(GSRegXYOFFSET_1, $8000 or (UInt64($8000) shl 32));
    GS.WriteRegister(GSRegTEX0_1, $100 or (UInt64(1) shl 14) or (UInt64(3) shl 26) or
      (UInt64(3) shl 30) or (UInt64(1) shl 34) or (UInt64(1) shl 35));
    GS.WriteRegister(GSRegRGBAQ, $80808080);
    for var Frame := 0 to 3 do
    begin
      Memory := GS.Raster.Memory;
      Source[1] := $80000000 or Cardinal(Frame * 60);
      Memory.WriteRaw(PSMCT32, $100, 1, 1, 0, Source[1]);
      GS.WriteRegister(GSRegPRIM, $116);
      GS.WriteRegister(GSRegUV, 1 or (UInt64(1) shl 16));
      GS.WriteRegister(GSRegXYZ2, $7FF8 or (UInt64($7FF8) shl 16));
      GS.WriteRegister(GSRegUV, 129 or (UInt64(129) shl 16));
      GS.WriteRegister(GSRegXYZ2, $8078 or (UInt64($8078) shl 16));
      GS.BuildFrame;
      var Pixels := GS.Frame;
      if Frame = 3 then
        for var Y := 0 to 15 do
          for var X := 0 to 15 do
          begin
            var C := Source[(Y div 2) * 8 + X div 2];
            var Expected := $FF000000 or ((C and $FF) shl 16) or (C and $FF00) or ((C shr 16) and $FF);
            if Pixels[Y * 16 + X] <> Expected then
              raise Exception.Create('Frequently changing texture remained scaled or stale');
          end;
    end;
    var Report := GS.Raster.HLEReport;
    if Pos(' scaled=2 ', Report) = 0 then
      raise Exception.Create('Unexpected dynamic texture scaling count: ' + Report);
    Writeln(Format('async=%d filter=%s: dynamic texture becomes native, pixels current: OK',
      [Async, TexScaleFilterName(Filter)]));
  finally
    GS.Free;
  end;
end;

begin
  try
    for var Async := 0 to 1 do
      for var Filter := Low(TTexScaleFilter) to High(TTexScaleFilter) do
        Check(Async, Filter);
  except
    on E: Exception do
    begin
      Writeln('FAIL: ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
