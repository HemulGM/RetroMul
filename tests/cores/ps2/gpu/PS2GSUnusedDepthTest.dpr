program PS2GSUnusedDepthTest;

{$APPTYPE CONSOLE}
{$POINTERMATH ON}

uses
  System.SysUtils, PS2.Types, PS2.GS.Raster, PS2.GS.Memory;

procedure Vertex(Raster: TPS2GSRaster; X, Y, U, V: Cardinal);
begin
  Raster.WriteRegister(GSRegUV, UInt64(U) or (UInt64(V) shl 16));
  Raster.WriteRegister(GSRegXYZ2, UInt64(X) or (UInt64(Y) shl 16) or (UInt64($FFFFFFFF) shl 32));
end;

function Draw(GPU: Boolean; DepthFormat, Shape, AlphaMode, Async: Integer; UsedDepth, FastRows: Boolean;
  out Accepted: Int64): TBytes;
begin
  var SavedRows := SpriteRows;
  SpriteRows := FastRows;
  var Raster := TPS2GSRaster.Create;
  try
    var Memory := Raster.Memory;
    var Data := PCardinal(Memory.Data);
    for var I := 0 to PS2GSMemorySize div 4 - 1 do
      Data[I] := Cardinal((UInt64(Cardinal(I)) * $9E3779B9) and $FFFFFFFF) xor $81527A39;
    for var Y := 0 to 63 do
      for var X := 0 to 63 do
      begin
        var Color := Cardinal(16 + X * 2) or (Cardinal(32 + Y * 2) shl 8) or $00200000;
        if (X and 8) <> 0 then
          Color := Color or $80000000;
        Memory.WriteRaw(PSMCT32, $1000, 1, Cardinal(X), Cardinal(Y), Color);
      end;
    Raster.Async := Async <> 0;
    Raster.Vulkan := GPU;
    if GPU and not Raster.Vulkan then
      raise Exception.Create(Raster.VulkanError);
    Raster.WriteRegister(GSRegFRAME_1, UInt64(2) shl 16);
    var ZBuffer := $100 or (UInt64(DepthFormat) shl 24);
    if not UsedDepth then
      ZBuffer := ZBuffer or (UInt64(1) shl 32);
    Raster.WriteRegister(GSRegZBUF_1, ZBuffer);
    Raster.WriteRegister(GSRegSCISSOR_1, (UInt64(127) shl 16) or (UInt64(127) shl 48));
    var Test: UInt64 := $30000;
    if AlphaMode = 1 then
      Test := $60000;
    if AlphaMode > 0 then
      Test := Test or 1 or (UInt64(6) shl 1) or (UInt64(64) shl 4) or
        (UInt64(AlphaMode + 1) shl 12);
    Raster.WriteRegister(GSRegTEST_1, Test);
    Raster.WriteRegister(GSRegALPHA_1, $44);
    Raster.WriteRegister(GSRegRGBAQ, $80808080);
    Raster.WriteRegister(GSRegTEX0_1, $1000 or (UInt64(1) shl 14) or (UInt64(6) shl 26) or
      (UInt64(6) shl 30) or (UInt64(1) shl 34));
    if Shape = 0 then
    begin
      var Primitive: UInt64 := $116;
      if AlphaMode <> 0 then
        Primitive := Primitive or $40;
      Raster.WriteRegister(GSRegPRIM, Primitive);
      Vertex(Raster, 0, 0, 0, 0);
      Vertex(Raster, 1024, 1024, 1024, 1024);
    end
    else
    begin
      var Primitive: UInt64 := $113;
      if AlphaMode <> 0 then
        Primitive := Primitive or $40;
      Raster.WriteRegister(GSRegPRIM, Primitive);
      Vertex(Raster, 0, 0, 0, 0);
      Vertex(Raster, 1024, 0, 1024, 0);
      Vertex(Raster, 0, 1024, 0, 1024);
    end;
    Memory := Raster.Memory;
    Accepted := 0;
    if GPU then
      Accepted := Raster.VulkanDraws;
    SetLength(Result, PS2GSMemorySize);
    Move(Memory.Data^, Result[0], Length(Result));
  finally
    Raster.Free;
    SpriteRows := SavedRows;
  end;
end;

procedure Check(DepthFormat, Shape, AlphaMode, Async: Integer; UsedDepth: Boolean; var Checks: Integer);
begin
  var Ignore, Accepted: Int64;
  var Reference := Draw(False, DepthFormat, Shape, AlphaMode, Async, UsedDepth, False, Ignore);
  var RowResult := Draw(False, DepthFormat, Shape, AlphaMode, Async, UsedDepth, True, Ignore);
  if not CompareMem(@Reference[0], @RowResult[0], Length(Reference)) then
    raise Exception.Create('Unused-depth sprite row/scalar mismatch');
  var Actual := Draw(True, DepthFormat, Shape, AlphaMode, Async, UsedDepth, True, Accepted);
  if not CompareMem(@Reference[0], @Actual[0], Length(Reference)) then
    raise Exception.CreateFmt('VRAM mismatch depth=%x shape=%d alpha=%d async=%d used=%d',
      [DepthFormat, Shape, AlphaMode, Async, Ord(UsedDepth)]);
  if not UsedDepth and (Accepted = 0) then
    raise Exception.CreateFmt('Unused depth rejected depth=%x shape=%d alpha=%d async=%d',
      [DepthFormat, Shape, AlphaMode, Async]);
  if UsedDepth and (DepthFormat in [2, 10]) and (Accepted <> 0) then
    raise Exception.Create('Used 16-bit depth must retain the exact software path');
  Inc(Checks);
end;

begin
  try
    var Checks := 0;
    for var DepthFormat in [2, 10, 0, 1] do
      for var Async := 0 to 1 do
        for var Shape := 0 to 1 do
          for var AlphaMode := 0 to 2 do
            Check(DepthFormat, Shape, AlphaMode, Async, False, Checks);
    for var DepthFormat in [2, 10] do
      for var Shape := 0 to 1 do
        Check(DepthFormat, Shape, 0, 0, True, Checks);
    Writeln('Unused GS depth: ', Checks, ' full-VRAM software/GPU and used-depth guard cases: OK');
  except
    on E: Exception do
    begin
      Writeln('FAIL: ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
