program PS2GSGpuTest;

{$APPTYPE CONSOLE}
{$POINTERMATH ON}
{$Q-} // Deliberately wrapping pattern used to initialize VRAM.

uses
  System.SysUtils, System.Classes, System.Math, Core.Snapshots, PS2.Types, PS2.GS.Memory, PS2.GS.Raster, PS2.GS.Gpu;

const
  // 16-bit frames: two pixels to a word, each its own invocation's.
  Frames16: array[0..3] of Cardinal = (PSMCT16, PSMCT16S, PSMZ16, PSMZ16S);

procedure Vertex(Raster: TPS2GSRaster; const V: TPS2GSVertex);
begin
  Raster.WriteRegister(GSRegRGBAQ, UInt64(V.R) or (UInt64(V.G) shl 8) or (UInt64(V.B) shl 16) or
    (UInt64(V.A) shl 24) or (UInt64(PCardinal(@V.Q)^) shl 32));
  Raster.WriteRegister(GSRegST, UInt64(PCardinal(@V.S)^) or (UInt64(PCardinal(@V.T)^) shl 32));
  Raster.WriteRegister(GSRegUV, UInt64(V.U) or (UInt64(V.V) shl 16));
  Raster.WriteRegister(GSRegFOG, UInt64(V.F) shl 56);
  Raster.WriteRegister(GSRegXYZ2, UInt64(V.X) or (UInt64(V.Y) shl 16) or (UInt64(V.Z) shl 32));
end;

// (-async: drawing on the raster's own thread, unless the test writes GS
// memory itself between draws: Synchronous.)
procedure EnableVulkan(Raster: TPS2GSRaster; Synchronous: Boolean = False);
begin
  if FindCmdLineSwitch('hybrid') then Raster.Threads := 4;
  Raster.Vulkan := True;
  if FindCmdLineSwitch('async') and not Synchronous then Raster.Async := True;
end;

procedure CheckClutSnapshots;
var
  Clut: array[0..511] of Word;
begin
  var Memory := TPS2GSMemory.Create;
  var GPU := TPS2GSGpu.Create(Memory.Data, @Clut[0]);
  try
    var D := Default(TPS2GSDraw);
    D.FBW := 4; D.FPSM := PSMCT32; D.ZPSM := PSMZ32; D.ZMSK := True; D.ZTST := 1;
    D.TME := True; D.TPSM := PSMT8; D.TBP := 4096; D.TBW := 1; D.TW := 6; D.TH := 6;
    D.Clut32 := True; D.TCC := True; D.TFX := 1; D.FST := True; D.ColClamp := True;
    for var Draw := 0 to 1 do
    begin
      var Color: Cardinal := $80112233;
      if Draw = 1 then Color := $80445566;
      for var I := 0 to 255 do begin Clut[I] := Word(Color); Clut[I+256] := Word(Color shr 16); end;
      var V0 := Default(TPS2GSVertex);
      var V1 := V0;
      V0.X := Draw * 64 * 16; V0.Y := V0.X;
      V1.X := (128 + Draw * 64) * 16; V1.Y := V1.X;
      if not GPU.Sprite(D, V0, V1, Draw * 64, Draw * 64, 128 + Draw * 64, 128 + Draw * 64, 0) then
        raise Exception.Create('CLUT snapshot draw declined');
    end;
    if GPU.Submissions <> 0 then raise Exception.Create('CLUT draws did not share a batch');
    GPU.Sync;
    if (Memory.ReadRaw(PSMCT32, 0, 4, 32, 32) <> $80112233) or
      (Memory.ReadRaw(PSMCT32, 0, 4, 96, 96) <> $80445566) then
      raise Exception.Create('Queued palette was overwritten');
    Writeln('Queued CLUT snapshots: OK');
  finally GPU.Free; Memory.Free; end;
end;

procedure CheckTextureFormats;
const
  Formats: array[0..12] of Cardinal = (PSMCT32, PSMCT24, PSMCT16, PSMCT16S,
    PSMT8, PSMT4, PSMT8H, PSMT4HL, PSMT4HH, PSMZ32, PSMZ24, PSMZ16, PSMZ16S);
  Bases: array[0..6] of Cardinal = (4096, 5120, 5376, 5504, 5568, 5632, 5696);
  PaletteFormats: array[0..2] of Cardinal = (PSMCT32, PSMCT16, PSMCT16S);
var
  V: array[0..2] of TPS2GSVertex;
begin
  var A := TPS2GSRaster.Create;
  var B := TPS2GSRaster.Create;
  try
    EnableVulkan(B);
    if B.VulkanError <> '' then raise Exception.Create(B.VulkanError);
    var Draws := 0;
    for var Format in Formats do
      for var N := 0 to 23 do
      begin
        if N and 1 = 0 then SetRoundMode(rmNearest) else SetRoundMode(rmTruncate);
        A.Reset; B.Reset;
        var PA := PCardinal(A.Memory.Data);
        for var K := 0 to PS2GSMemorySize div 4 - 1 do
          if K mod 31 = 0 then PA[K] := 0
          else PA[K] := Cardinal(K) * 1664525 + Cardinal(N) * 1013904223;
        Move(PA^, B.Memory.Data^, PS2GSMemorySize);
        var IsTriangle := N mod 2 <> 0;
        for var K := 0 to 2 do
        begin
          V[K] := Default(TPS2GSVertex);
          V[K].R := 80 + K * 40; V[K].G := 60 + K * 20; V[K].B := 200 - K * 20;
          V[K].A := 64 + K * 64; V[K].F := 255; V[K].Z := 32;
          V[K].U := 1023 + K * 2049; V[K].V := 4095 - K * 1041;
          V[K].S := 0.125 + K * 0.375; V[K].T := 1.25 - K * 0.375;
        end;
        V[0].Q := 0.125; V[1].Q := 1; V[2].Q := 2;
        V[0].X := 256; V[0].Y := 256;
        V[1].X := 2304; V[1].Y := 256;
        V[2].X := 256; V[2].Y := 2304;
        if not IsTriangle then V[2].X := 2304;
        for var R in TArray<TPS2GSRaster>.Create(A, B) do
        begin
          R.WriteRegister(GSRegFRAME_1, UInt64(4) shl 16);
          R.WriteRegister(GSRegZBUF_1, (UInt64(1) shl 32) or 256);
          R.WriteRegister(GSRegSCISSOR_1, (UInt64(255) shl 16) or (UInt64(255) shl 48));
          R.WriteRegister(GSRegCOLCLAMP, 1);
          R.WriteRegister(GSRegALPHA_1, $44);
          var Prim: UInt64 := 6;
          if IsTriangle then Prim := 3 or 8;
          Prim := Prim or $10;
          if N and 2 <> 0 then Prim := Prim or $100;
          if N and 4 <> 0 then Prim := Prim or $40;
          R.WriteRegister(GSRegPRIM, Prim);
          R.WriteRegister(GSRegCLAMP_1, UInt64(N and 15) or (UInt64(31) shl 4) or
            (UInt64(191) shl 14) or (UInt64(63) shl 24) or (UInt64(255) shl 34));
          R.WriteRegister(GSRegTEXCLUT, 1 or (UInt64(2) shl 6) or (UInt64(3) shl 12));
          R.WriteRegister(GSRegTEXA, 73 or (UInt64(201) shl 32) or (UInt64(N and 1) shl 15));
          R.WriteRegister(GSRegTEX0_1, UInt64(Bases[0]) or (UInt64(1) shl 14) or (UInt64(Format) shl 20) or
            (UInt64(6) shl 26) or (UInt64(6) shl 30) or (UInt64(N and 1) shl 34) or
            (UInt64(N mod 4) shl 35) or (UInt64(12288) shl 37) or
            (UInt64(PaletteFormats[N mod 3]) shl 51) or (UInt64(N and 1) shl 55) or
            (UInt64(N and 31) shl 56) or (UInt64(1) shl 61));
          var KRaw := (N mod 9) * 13 - 16;
          R.WriteRegister(GSRegTEX1_1, UInt64((N shr 1) and 1) or (UInt64(6) shl 2) or
            (UInt64(N and 1) shl 5) or (UInt64(N mod 6) shl 6) or (UInt64(N and 1) shl 19) or
            (UInt64(KRaw and $FFF) shl 32));
          var M1, M2: UInt64;
          M1 := 0; M2 := 0;
          for var L := 0 to 2 do
          begin
            M1 := M1 or ((UInt64(Bases[L+1]) or (UInt64(1) shl 14)) shl (L * 20));
            M2 := M2 or ((UInt64(Bases[L+4]) or (UInt64(1) shl 14)) shl (L * 20));
          end;
          R.WriteRegister(GSRegMIPTBP1_1, M1); R.WriteRegister(GSRegMIPTBP2_1, M2);
          Vertex(R, V[0]);
          if IsTriangle then Vertex(R, V[1]);
          Vertex(R, V[2]);
        end;
        B.Sync;
        if not CompareMem(A.Memory.Data, B.Memory.Data, PS2GSMemorySize) or
          (A.PixelsDrawn <> B.PixelsDrawn) then
          raise Exception.CreateFmt('Texture/mipmap mismatch psm=%x case=%d', [Format, N]);
        Inc(Draws);
        if B.VulkanDraws <> Draws then raise Exception.CreateFmt('Texture fell back psm=%x case=%d', [Format, N]);
      end;
    Writeln('Texture formats=13, CLUT/CSA/CSM/TEXA, mipmaps/filters, sprites/triangles: ', Draws, ' OK');
  finally B.Free; A.Free; end;
end;

procedure CheckCoverageCounter;
var
  V: array[0..2] of TPS2GSVertex;
begin
  var A := TPS2GSRaster.Create;
  var B := TPS2GSRaster.Create;
  try
    for var R in TArray<TPS2GSRaster>.Create(A, B) do
    begin
      R.WriteRegister(GSRegFRAME_1, UInt64(1) shl 16);
      R.WriteRegister(GSRegZBUF_1, UInt64(1) shl 32);
      R.WriteRegister(GSRegXYOFFSET_1, $8000 or (UInt64($8000) shl 32));
      R.WriteRegister(GSRegTEST_1, $10000); // NEVER depth: count coverage, write nothing
      R.WriteRegister(GSRegPRIM, 3);
    end;
    RandSeed := 61927;
    // (-4: four bands drawing on the raster's own thread.)
    for var Threads in TArray<Integer>.Create(2, 4, 6, -4) do
    begin
      B.Threads := Abs(Threads);
      B.Async := Threads < 0;
      if B.Async <> (Threads < 0) then raise Exception.Create('Async raster unavailable');
      for var N := 0 to 511 do
      begin
        if N and 1 = 0 then SetRoundMode(rmNearest) else SetRoundMode(rmTruncate);
        var X0 := Random(32);
        var X1 := X0 + Random(33);
        var Y0 := Random(32);
        var Y1 := Y0 + Random(33);
        var Scissor := UInt64(X0) or (UInt64(X1) shl 16) or (UInt64(Y0) shl 32) or (UInt64(Y1) shl 48);
        A.WriteRegister(GSRegSCISSOR_1, Scissor);
        B.WriteRegister(GSRegSCISSOR_1, Scissor);
        var Test: UInt64 := $10000;
        if (N and 2) <> 0 then Test := Test or (UInt64(1) shl 17);
        A.WriteRegister(GSRegTEST_1, Test);
        B.WriteRegister(GSRegTEST_1, Test);
        for var K := 0 to 2 do
        begin
          V[K] := Default(TPS2GSVertex);
          V[K].X := $8000 + Random(1536) - 256;
          V[K].Y := $8000 + Random(1536) - 256;
          V[K].Z := Cardinal(Random(MaxInt));
          V[K].R := (N + 17 * K) and 255;
          V[K].G := (N + 91) and 255;
          V[K].B := 173;
          V[K].A := 128;
        end;
        if N mod 8 = 0 then
        begin
          V[1].X := V[0].X + 1; // subpixel-thin, both windings and clipped spans
          V[2].X := V[0].X + 2;
        end;
        if N mod 16 = 0 then V[2] := V[0]; // degenerate
        for var K := 0 to 2 do Vertex(A, V[K]);
        for var K := 0 to 2 do Vertex(B, V[K]);
        if (A.PixelsDrawn <> B.PixelsDrawn) or (A.Primitives <> B.Primitives) then
          raise Exception.CreateFmt('Coverage mismatch threads=%d triangle=%d expected=%d actual=%d',
            [Threads, N, A.PixelsDrawn, B.PixelsDrawn]);
        if N mod 64 = 63 then
        begin
          B.Sync;
          if not CompareMem(A.Memory.Data, B.Memory.Data, PS2GSMemorySize) then
          begin
            var MA := PCardinal(A.Memory.Data);
            var MB := PCardinal(B.Memory.Data);
            var Shown := 0;
            for var I := 0 to PS2GSMemorySize div 4 - 1 do
              if MA[I] <> MB[I] then
              begin
                Writeln(Format('band VRAM %x CPU %.8x threads %.8x', [I, MA[I], MB[I]]));
                Inc(Shown); if Shown = 8 then Break;
              end;
            raise Exception.CreateFmt('Band coverage VRAM mismatch threads=%d triangle=%d', [Threads, N]);
          end;
        end;
      end;
    end;
    B.Sync;
    if not CompareMem(A.Memory.Data, B.Memory.Data, PS2GSMemorySize) then
      raise Exception.Create('Coverage VRAM mismatch');
    Writeln('2048 clipped/subpixel coverage cases, 2/4/6 bands, async: VRAM and exact counters OK');
  finally
    A.Free; B.Free;
  end;
end;

procedure CheckTiledTriangles;
var
  V: array[0..2] of TPS2GSVertex;
begin
  var A := TPS2GSRaster.Create;
  var B := TPS2GSRaster.Create;
  try
    EnableVulkan(B);
    if B.VulkanError <> '' then raise Exception.Create(B.VulkanError);
    for var R in TArray<TPS2GSRaster>.Create(A, B) do
    begin
      R.WriteRegister(GSRegFRAME_1, UInt64(4) shl 16);
      R.WriteRegister(GSRegZBUF_1, UInt64(1) shl 32);
      R.WriteRegister(GSRegTEST_1, $30000);
      R.WriteRegister(GSRegSCISSOR_1, (UInt64(255) shl 16) or (UInt64(255) shl 48));
      R.WriteRegister(GSRegALPHA_1, $64 or (UInt64(80) shl 32));
      R.WriteRegister(GSRegCOLCLAMP, 1);
      R.WriteRegister(GSRegPRIM, 3 or 8 or $40);
    end;
    for var N := 0 to 255 do
    begin
      if N and 1 = 0 then SetRoundMode(rmNearest) else SetRoundMode(rmTruncate);
      for var K := 0 to 2 do
      begin
        V[K] := Default(TPS2GSVertex);
        V[K].R := (N * 17 + K * 71) and 255;
        V[K].G := (N * 31 + K * 53) and 255;
        V[K].B := (N * 43 + K * 37) and 255;
        V[K].A := 64; V[K].Q := 1;
      end;
      V[0].X := 256 + (N and 15); V[0].Y := 256 + (N and 7);
      V[1].X := (200 + (N and 31)) * 16; V[1].Y := 384;
      V[2].X := (48 + (N and 63)) * 16; V[2].Y := (200 + (N and 15)) * 16;
      for var K := 0 to 2 do Vertex(A, V[K]);
      for var K := 0 to 2 do Vertex(B, V[K]);
      if (N = 0) and (B.VulkanRasterizedTriangles = 0) then
      begin
        Writeln('Exact FP64 unavailable: full tile path skipped, fragment fallback retained');
        Exit;
      end;
    end;
    B.Sync;
    if not CompareMem(A.Memory.Data, B.Memory.Data, PS2GSMemorySize) or (A.PixelsDrawn <> B.PixelsDrawn) then
      raise Exception.Create('Ordered tiled triangle batch mismatch');
    // (Clusters of up to 128 draws and 65536 draw-tile entries: these 256
    // triangles of about 800 tiles each take three.)
    if (B.VulkanRasterizedTriangles <> 256) or (B.VulkanTriangleDispatches <> 3) then
      raise Exception.Create('Triangles were not grouped into tile clusters');
    Writeln('256 ordered blended triangles, mixed rounding, 3 tiled clusters: OK');
  finally
    A.Free; B.Free;
  end;
end;

procedure CheckHybridRenderers;
begin
  var Baseline: TBytes;
  // Modes 4 and 5: 4 bands with the GPU, or only the raster's thread, drawing
  // on the raster's own thread.
  for var Mode := 0 to 5 do
  begin
    var R := TPS2GSRaster.Create;
    try
      if Mode in [1..4] then
      begin
        R.Threads := Min(Mode, 2) * 2;
        R.Vulkan := True;
        if R.VulkanError <> '' then raise Exception.Create(R.VulkanError);
        if R.Threads <> Min(Mode, 2) * 2 then raise Exception.Create('Vulkan discarded fallback workers');
      end;
      if Mode >= 4 then
      begin
        R.Async := True;
        if not R.Async or (R.VulkanError <> '') then raise Exception.Create('Async raster unavailable');
      end;
      R.WriteRegister(GSRegSCISSOR_1, (UInt64(255) shl 16) or (UInt64(255) shl 48));
      R.WriteRegister(GSRegZBUF_1, UInt64(1) shl 32);
      R.WriteRegister(GSRegCOLCLAMP, 1);
      R.WriteRegister(GSRegALPHA_1, $44);
      for var N := 0 to 63 do
      begin
        if N and 1 = 0 then SetRoundMode(rmNearest) else SetRoundMode(rmTruncate);
        var CPU := N mod 4 in [1, 2];
        var Frame := UInt64(4) shl 16;
        if CPU then Frame := Frame or 256 or (UInt64(PSMCT16) shl 24);
        // Half of the untextured 16-bit sprites go to the GPU; the others,
        // to a depth format the GPU does not draw, to the CPU workers.
        if N mod 8 = 1 then Frame := (Frame and not (UInt64($3F) shl 24)) or (UInt64(PSMZ32) shl 24);
        R.WriteRegister(GSRegFRAME_1, Frame);
        var Prim: UInt64 := 6;
        if N mod 4 = 2 then Prim := Prim or $110; // CPU self-reading 16-bit sprite, solo worker.
        if N mod 4 = 3 then Prim := 3 or $110; // GPU triangle consumes CPU targets/palettes.
        if N and 4 <> 0 then Prim := Prim or $40;
        R.WriteRegister(GSRegPRIM, Prim);
        var Tex0 := UInt64(8192) or (UInt64(4) shl 14) or (UInt64(PSMCT16) shl 20) or
          (UInt64(7) shl 26) or (UInt64(7) shl 30) or (UInt64(1) shl 35);
        if N mod 8 = 3 then
        begin
          Tex0 := UInt64(4096) or (UInt64(2) shl 14) or (UInt64(PSMT8) shl 20) or
            (UInt64(7) shl 26) or (UInt64(7) shl 30) or (UInt64(1) shl 35) or
            (UInt64(8192) shl 37) or (UInt64(PSMCT16) shl 51) or (UInt64(1) shl 61);
        end;
        R.WriteRegister(GSRegTEX0_1, Tex0);
        R.WriteRegister(GSRegTEXA, 67 or (UInt64(199) shl 32));
        var V := Default(TPS2GSVertex);
        V.Q := 1; V.A := 128; V.R := (N * 19) and 255; V.G := (N * 37) and 255; V.B := (N * 71) and 255;
        V.X := 16 * 16; V.Y := 16 * 16; Vertex(R, V);
        V.X := 144 * 16; V.U := 127 * 16;
        if N mod 4 <> 3 then V.Y := 144 * 16;
        Vertex(R, V);
        if N mod 4 = 3 then begin V.X := 16 * 16; V.Y := 144 * 16; V.V := 127 * 16; Vertex(R, V); end;
        if N mod 16 = 0 then
        begin
          // A queued CPU copy must first see the deferred GPU target.
          R.WriteRegister(GSRegBITBLTBUF, (UInt64(4) shl 16) or
            (UInt64(12288) shl 32) or (UInt64(4) shl 48));
          R.WriteRegister(GSRegTRXPOS, 0);
          R.WriteRegister(GSRegTRXREG, 128 or (UInt64(128) shl 32));
          R.WriteRegister(GSRegTRXDIR, 2);
        end;
        if N mod 16 = 8 then
        begin
          R.WriteRegister(GSRegBITBLTBUF, (UInt64(4096) shl 32) or (UInt64(2) shl 48));
          R.WriteRegister(GSRegTRXPOS, 0);
          R.WriteRegister(GSRegTRXREG, 2 or (UInt64(1) shl 32));
          R.WriteRegister(GSRegTRXDIR, 0);
          R.WriteRegister(GSRegHWREG, UInt64($12345678) * Cardinal(N + 1));
        end;
        if N mod 16 = 10 then
        begin
          R.WriteRegister(GSRegBITBLTBUF, (UInt64(4096) shl 32) or (UInt64(2) shl 48));
          R.WriteRegister(GSRegTRXPOS, UInt64(16) shl 32);
          R.WriteRegister(GSRegTRXREG, 4 or (UInt64(1) shl 32));
          R.WriteRegister(GSRegTRXDIR, 0);
          var Image := Default(TPS2Reg128);
          for var K := 0 to 3 do Image.UW[K] := Cardinal($81234567) + Cardinal(N * 17 + K * 31);
          R.WriteImage(Image); // Chunked upload follows a queued CPU fallback.
        end;
      end;
      var Stream := TMemoryStream.Create;
      try
        var Archive := TStateArchive.Create(Stream, False);
        try R.SerializeState(Archive); finally Archive.Free; end;
        var Bytes: TBytes;
        SetLength(Bytes, Stream.Size);
        Move(Stream.Memory^, Bytes[0], Length(Bytes));
        if Mode = 0 then Baseline := Bytes
        else if (Length(Bytes) <> Length(Baseline)) or not CompareMem(@Bytes[0], @Baseline[0], Length(Bytes)) then
          raise Exception.CreateFmt('Hybrid fallback snapshot mismatch mode=%d', [Mode]);
      finally
        Stream.Free;
      end;
      if (Mode in [1..4]) and (R.VulkanDraws <> 40) then raise Exception.Create('Hybrid draw did not reach GPU');
    finally
      R.Free;
    end;
  end;
  Writeln('GPU / 2/4/6-band / async fallback ordering, feedback, palettes, transfers and snapshots: OK');
end;

procedure CheckPageBarriers;
begin
  var Memory := TPS2GSMemory.Create;
  var GPU := TPS2GSGpu.Create(Memory.Data);
  try
    var D := Default(TPS2GSDraw);
    D.FBW := 4; D.ZPSM := PSMZ32; D.ZMSK := True; D.ZTST := 1;
    D.TME := True; D.TPSM := PSMCT32; D.TBP := 4096; D.TBW := 1;
    D.TW := 6; D.TH := 6; D.TFX := 1; D.FST := True; D.ColClamp := True;
    var V0 := Default(TPS2GSVertex);
    var V1 := V0;
    V1.X := 1024; V1.Y := 1024;
    if not GPU.Sprite(D, V0, V1, 0, 0, 64, 64, 0) then raise Exception.Create('Page probe declined');
    GPU.ReadPages(128, 129); // GPU reads only: concurrent CPU reads are safe.
    GPU.WritePages(300, 300);
    if not GPU.Pending or (GPU.Submissions <> 0) then raise Exception.Create('Unrelated page drained GPU');
    GPU.WritePages(640, 641); // Wrapped aliases of the sampled texture.
    if GPU.Pending or (GPU.Submissions <> 1) then raise Exception.Create('Texture write hazard missed');
    if not GPU.Sprite(D, V0, V1, 0, 0, 64, 64, 0) then raise Exception.Create('Second page probe declined');
    GPU.ReadPages(512, 512); // Wrapped alias of the colour target.
    if GPU.Pending or (GPU.Submissions <> 2) then raise Exception.Create('Target read hazard missed');
    if not GPU.Sprite(D, V0, V1, 0, 0, 64, 64, 0) then raise Exception.Create('Third page probe declined');
    GPU.WritePages(4, 4);
    if GPU.Pending or (GPU.Submissions <> 3) then raise Exception.Create('Target write hazard missed');
    Writeln('Selective read/write page barriers and wrapped aliases: OK');
  finally
    GPU.Free; Memory.Free;
  end;
end;

procedure CheckTransferBarriers;
const
  Bases: array[0..6] of Cardinal = (8192, 0, 0, $3FFF, 0, 0, 4096);
  Strides: array[0..6] of Cardinal = (0, 0, 1, 1, 4, 4, 0);
  Xs: array[0..6] of Integer = (0, 0, 256, 64, 2047, 0, 0);
  Ys: array[0..6] of Integer = (64, 64, 0, 0, 0, 2047, 64);
begin
  var A := TPS2GSRaster.Create;
  var B := TPS2GSRaster.Create;
  try
    EnableVulkan(B);
    if B.VulkanError <> '' then raise Exception.Create(B.VulkanError);
    var MA := A.Memory;
    var MB := B.Memory;
    for var N := 0 to High(Bases) do
    begin
      A.Reset; B.Reset;
      var Before := B.VulkanSubmissions;
      for var R in TArray<TPS2GSRaster>.Create(A, B) do
      begin
        R.WriteRegister(GSRegFRAME_1, UInt64(4) shl 16);
        R.WriteRegister(GSRegZBUF_1, UInt64(1) shl 32);
        R.WriteRegister(GSRegSCISSOR_1, (UInt64(255) shl 16) or (UInt64(255) shl 48));
        R.WriteRegister(GSRegCOLCLAMP, 1);
        R.WriteRegister(GSRegTEX0_1, 4096 or (UInt64(1) shl 14) or (UInt64(6) shl 26) or
          (UInt64(6) shl 30) or (UInt64(1) shl 35));
        var Prim: UInt64 := 6;
        if N = 6 then Prim := Prim or $110;
        R.WriteRegister(GSRegPRIM, Prim);
        var V := Default(TPS2GSVertex);
        V.Q := 1; V.R := 71; V.G := 93; V.B := 117; V.A := 128;
        Vertex(R, V);
        V.X := 128 * 16; V.Y := 128 * 16;
        Vertex(R, V);
        R.WriteRegister(GSRegBITBLTBUF, (UInt64(Bases[N]) shl 32) or (UInt64(Strides[N]) shl 48));
        R.WriteRegister(GSRegTRXPOS, (UInt64(Xs[N]) shl 32) or (UInt64(Ys[N]) shl 48));
        R.WriteRegister(GSRegTRXREG, 2 or (UInt64(2) shl 32));
        R.WriteRegister(GSRegTRXDIR, 0);
        R.WriteRegister(GSRegHWREG, $8123456789ABCDEF);
        R.WriteRegister(GSRegHWREG, $FEDCBA9876543210);
      end;
      var Expected := Before + 1;
      if N = 0 then Expected := Before;
      if B.VulkanSubmissions <> Expected then
        raise Exception.CreateFmt('Transfer barrier mismatch case=%d', [N]);
      B.Sync;
      if not CompareMem(MA.Data, MB.Data, PS2GSMemorySize) or (A.PixelsTransferred <> B.PixelsTransferred) then
        raise Exception.CreateFmt('Wrapped/zero-stride transfer mismatch case=%d', [N]);
    end;
    Writeln('Zero/undersized transfer strides, texture hazards, VRAM/coordinate wrap: OK');
  finally
    A.Free; B.Free;
  end;
end;

procedure CheckTransferRevision;
begin
  var A := TPS2GSRaster.Create;
  var B := TPS2GSRaster.Create;
  try
    EnableVulkan(B);
    if B.VulkanError <> '' then raise Exception.Create(B.VulkanError);
    for var R in TArray<TPS2GSRaster>.Create(A, B) do
    begin
      R.WriteRegister(GSRegFRAME_1, UInt64(4) shl 16);
      R.WriteRegister(GSRegZBUF_1, UInt64(1) shl 32);
      R.WriteRegister(GSRegSCISSOR_1, (UInt64(255) shl 16) or (UInt64(255) shl 48));
      R.WriteRegister(GSRegCOLCLAMP, 1);
      R.WriteRegister(GSRegPRIM, 6 or $110);
      R.WriteRegister(GSRegTEX0_1, 4096 or (UInt64(1) shl 14) or (UInt64(6) shl 26) or
        (UInt64(6) shl 30) or (UInt64(1) shl 35));
      var V := Default(TPS2GSVertex);
      V.Q := 1; V.A := 128;
      Vertex(R, V); V.X := 128 * 16; V.Y := 128 * 16; Vertex(R, V);
      R.WriteRegister(GSRegBITBLTBUF, (UInt64(8192) shl 32) or (UInt64(1) shl 48));
      R.WriteRegister(GSRegTRXPOS, 0);
      R.WriteRegister(GSRegTRXREG, 4 or (UInt64(1) shl 32));
      R.WriteRegister(GSRegTRXDIR, 0);
      R.WriteRegister(GSRegHWREG, $8123456789ABCDEF); // No GPU consumer of these pages yet.
    end;
    if B.VulkanSubmissions <> 0 then raise Exception.Create('Unrelated partial transfer drained GPU');
    for var R in TArray<TPS2GSRaster>.Create(A, B) do
    begin
      R.WriteRegister(GSRegTEX0_1, 8192 or (UInt64(1) shl 14) or (UInt64(6) shl 26) or
        (UInt64(6) shl 30) or (UInt64(1) shl 35));
      var V := Default(TPS2GSVertex);
      V.Q := 1; V.A := 128; V.U := 32; // Reads pixel 2 before the next HWREG changes it.
      Vertex(R, V); V.X := 128 * 16; V.Y := 128 * 16; Vertex(R, V);
      R.WriteRegister(GSRegHWREG, $FEDCBA9876543210);
    end;
    if B.VulkanSubmissions <> 1 then raise Exception.Create('Transfer revision did not invalidate cached barrier');
    B.Sync;
    if not CompareMem(A.Memory.Data, B.Memory.Data, PS2GSMemorySize) then
      raise Exception.Create('Partial transfer / newly sampled texture mismatch');
    Writeln('GPU revision invalidates partial-transfer barrier cache: OK');
  finally
    A.Free; B.Free;
  end;
end;

procedure CheckPaletteBarriers;
begin
  var A := TPS2GSRaster.Create;
  var B := TPS2GSRaster.Create;
  try
    EnableVulkan(B);
    if B.VulkanError <> '' then raise Exception.Create(B.VulkanError);
    var MA := A.Memory;
    var MB := B.Memory;
    for var N := 0 to 3 do
    begin
      A.Reset; B.Reset;
      var Before := B.VulkanSubmissions;
      for var R in TArray<TPS2GSRaster>.Create(A, B) do
      begin
        R.WriteRegister(GSRegFRAME_1, UInt64(4) shl 16);
        R.WriteRegister(GSRegZBUF_1, UInt64(1) shl 32);
        R.WriteRegister(GSRegSCISSOR_1, (UInt64(255) shl 16) or (UInt64(255) shl 48));
        R.WriteRegister(GSRegCOLCLAMP, 1);
        R.WriteRegister(GSRegPRIM, 6);
        var V := Default(TPS2GSVertex);
        V.Q := 1; V.R := 31; V.G := 79; V.B := 113; V.A := 128;
        Vertex(R, V); V.X := 128 * 16; V.Y := 128 * 16; Vertex(R, V);
        var CBP := 0;
        var TexClut: UInt64 := UInt64(64) shl 12; // Zero stride aliases the first page.
        if N = 1 then begin CBP := $3FFF; TexClut := 1 or (UInt64(32) shl 12); end;
        if N = 2 then CBP := $3FFF;
        if N = 3 then CBP := 12288;
        R.WriteRegister(GSRegTEXCLUT, TexClut);
        var Tex0 := UInt64(4096) or (UInt64(1) shl 14) or (UInt64(PSMT8) shl 20) or
          (UInt64(6) shl 26) or (UInt64(6) shl 30) or (UInt64(1) shl 35) or
          (UInt64(CBP) shl 37) or (UInt64(1) shl 61);
        if N <> 2 then Tex0 := Tex0 or (UInt64(1) shl 55);
        R.WriteRegister(GSRegTEX0_1, Tex0);
      end;
      var Expected := Before + 1;
      if N = 3 then Expected := Before;
      if B.VulkanSubmissions <> Expected then
        raise Exception.CreateFmt('Palette barrier mismatch case=%d', [N]);
      for var R in TArray<TPS2GSRaster>.Create(A, B) do
      begin
        R.WriteRegister(GSRegFRAME_1, 256 or (UInt64(4) shl 16));
        R.WriteRegister(GSRegPRIM, 6 or $110);
        var V := Default(TPS2GSVertex);
        V.Q := 1; V.A := 128;
        Vertex(R, V); V.X := 128 * 16; V.Y := 128 * 16; Vertex(R, V);
      end;
      B.Sync;
      if not CompareMem(MA.Data, MB.Data, PS2GSMemorySize) then
        raise Exception.CreateFmt('Zero-stride/wrapped palette mismatch case=%d', [N]);
    end;
    Writeln('CSM1/CSM2 palette barriers, zero stride and wrapped VRAM: OK');
  finally
    A.Free; B.Free;
  end;
end;

procedure CheckClusterDependencies;
begin
  var A := TPS2GSRaster.Create;
  var B := TPS2GSRaster.Create;
  try
    EnableVulkan(B);
    if B.VulkanError <> '' then raise Exception.Create(B.VulkanError);
    var MA := A.Memory;
    var MB := B.Memory;
    for var DepthCase := 0 to 1 do
    begin
      A.Reset; B.Reset;
      var Before := B.VulkanTriangleDispatches;
      var Count := 3;
      if DepthCase <> 0 then Count := 2;
      for var N := 0 to Count - 1 do
        for var R in TArray<TPS2GSRaster>.Create(A, B) do
        begin
          var Target := 0;
          var Texture := 8192;
          if N = 1 then begin Target := 8192; Texture := 0; end;
          if DepthCase <> 0 then Target := 0;
          R.WriteRegister(GSRegFRAME_1, UInt64(Target div 32) or (UInt64(4) shl 16));
          var ZBuf := UInt64(2) or (UInt64(1) shl 32);
          if (DepthCase <> 0) and (N = 0) then ZBuf := 2;
          R.WriteRegister(GSRegZBUF_1, ZBuf);
          R.WriteRegister(GSRegSCISSOR_1, (UInt64(255) shl 16) or (UInt64(255) shl 48));
          R.WriteRegister(GSRegCOLCLAMP, 1);
          var Prim: UInt64 := 3;
          if (DepthCase = 0) and (N > 0) then Prim := Prim or $110;
          R.WriteRegister(GSRegPRIM, Prim);
          R.WriteRegister(GSRegTEX0_1, UInt64(Texture) or (UInt64(4) shl 14) or
            (UInt64(8) shl 26) or (UInt64(8) shl 30) or (UInt64(1) shl 35));
          var V := Default(TPS2GSVertex);
          V.Q := 1; V.R := 37; V.G := 61; V.B := 107; V.A := 128; V.Z := 100;
          V.U := 16 * 16; V.V := 16 * 16;
          Vertex(R, V);
          var Height := 128;
          if (DepthCase <> 0) and (N = 0) then Height := 16;
          V.X := 64 * 16; Vertex(R, V); V.X := 0; V.Y := Height * 16; Vertex(R, V);
        end;
      B.Sync;
      if not CompareMem(MA.Data, MB.Data, PS2GSMemorySize) or (A.PixelsDrawn <> B.PixelsDrawn) then
        raise Exception.CreateFmt('Cluster dependency mismatch depth=%d', [DepthCase]);
      if (B.VulkanRasterizedTriangles > 0) and (B.VulkanTriangleDispatches <> Before + Count) then
        raise Exception.CreateFmt('Dependent triangles shared a cluster depth=%d', [DepthCase]);
    end;
    Writeln('Texture dependency, layout and mixed-depth union cluster breaks: OK');
  finally
    A.Free; B.Free;
  end;
end;

procedure CheckNativeArenas;
begin
  var A := TPS2GSRaster.Create;
  var B := TPS2GSRaster.Create;
  try
    EnableVulkan(B, True);
    if B.VulkanError <> '' then raise Exception.Create(B.VulkanError);
    var MA := A.Memory;
    var MB := B.Memory;
    for var Large := 0 to 1 do
    begin
      A.Reset; B.Reset;
      var Before := B.VulkanSubmissions;
      var BeforeTriangles := B.VulkanRasterizedTriangles;
      var Count := 2065;
      if Large <> 0 then Count := 260;
      for var R in TArray<TPS2GSRaster>.Create(A, B) do
      begin
        R.WriteRegister(GSRegFRAME_1, UInt64(16) shl 16);
        R.WriteRegister(GSRegZBUF_1, UInt64(1) shl 32);
        R.WriteRegister(GSRegSCISSOR_1, (UInt64(1023) shl 16) or (UInt64(511) shl 48));
        R.WriteRegister(GSRegCOLCLAMP, 0);
        R.WriteRegister(GSRegALPHA_1, $68 or (UInt64(128) shl 32)); // Add each palette snapshot, wrapping.
        R.WriteRegister(GSRegPRIM, 3 or $150);
      end;
      for var N := 0 to Count - 1 do
      begin
        var Color := Cardinal($80000000) or Cardinal((N * 71) and 255) or
          (Cardinal((N * 37) and 255) shl 8) or (Cardinal((N * 19) and 255) shl 16);
        MA.WriteRaw(PSMCT32, 12288, 1, 0, 0, Color);
        MB.WriteRaw(PSMCT32, 12288, 1, 0, 0, Color);
        for var R in TArray<TPS2GSRaster>.Create(A, B) do
        begin
          var Format := 0;
          if Large <> 0 then Format := (N div 2) and 1; // Two snapshots per cluster.
          R.WriteRegister(GSRegFRAME_1, (UInt64(16) shl 16) or (UInt64(Format) shl 24));
          R.WriteRegister(GSRegTEX0_1, 8192 or (UInt64(1) shl 14) or (UInt64(PSMT8) shl 20) or
            (UInt64(6) shl 26) or (UInt64(6) shl 30) or (UInt64(1) shl 35) or
            (UInt64(12288) shl 37) or (UInt64(1) shl 61));
          var V := Default(TPS2GSVertex);
          V.Q := 1; V.A := 128;
          if Large = 0 then
          begin
            V.X := (N and 31) * 32; V.Y := ((N shr 5) and 31) * 32;
            Vertex(R, V); Inc(V.X, 32); Vertex(R, V); Dec(V.X, 32); Inc(V.Y, 32); Vertex(R, V);
          end
          else
          begin
            // A thin diagonal has huge tile bounds but little pixel work.
            Vertex(R, V); V.X := 1024 * 16; V.Y := 512 * 16; Vertex(R, V);
            Dec(V.X, 16); Vertex(R, V);
          end;
        end;
        if (N = 0) and (B.VulkanRasterizedTriangles = BeforeTriangles) then
        begin
          Writeln('Exact FP64 unavailable: native arena tests skipped');
          Exit;
        end;
      end;
      B.Sync;
      if not CompareMem(MA.Data, MB.Data, PS2GSMemorySize) or (A.PixelsDrawn <> B.PixelsDrawn) then
        raise Exception.CreateFmt('Native arena/CLUT preservation mismatch large=%d', [Large]);
      if (B.VulkanRasterizedTriangles <> BeforeTriangles + Count) or
        (B.VulkanSubmissions < Before + 2) then
        raise Exception.CreateFmt('Native arena was not refilled large=%d', [Large]);
    end;
    Writeln('2048-slot reuse and 16 MiB tile refill preserve ordered CLUT snapshots: OK');
  finally
    A.Free; B.Free;
  end;
end;

procedure CheckFragmentRollover;
begin
  var A := TPS2GSMemory.Create;
  var B := TPS2GSMemory.Create;
  var GPU := TPS2GSGpu.Create(B.Data);
  try
    var D := Default(TPS2GSDraw);
    D.FBW := 10; D.FPSM := PSMCT32; D.ZPSM := PSMZ32; D.ZMSK := True; D.ZTST := 1;
    D.ColClamp := True;
    if not GPU.BeginTriangle(D, 0, 0, 640, 480) then raise Exception.Create('Fragment probe declined');
    for var N := 0 to 69999 do
    begin
      var X := N mod 640; var Y := N div 640;
      var R := N and 255; var G := (N shr 3) and 255; var Blue := (N shr 7) and 255;
      GPU.Fragment(X, Y, 0, R, G, Blue, 128, 0, 0, 0, 0);
      A.WriteRaw(PSMCT32, 0, 10, Cardinal(X), Cardinal(Y), Cardinal(R or (G shl 8) or (Blue shl 16)) or $80000000);
    end;
    GPU.EndTriangle;
    GPU.Sync;
    if not CompareMem(A.Data, B.Data, PS2GSMemorySize) or (GPU.Submissions < 2) then
      raise Exception.Create('Prepared fragment arena rollover mismatch');
    Writeln('70000 prepared fragments and arena rollover: OK');
  finally
    GPU.Free; A.Free; B.Free;
  end;
end;

procedure CheckTriangles;
const
  Registers: array[0..13] of Integer = (GSRegFRAME_1, GSRegZBUF_1, GSRegTEST_1, GSRegALPHA_1,
    GSRegPABE, GSRegFBA_1, GSRegCOLCLAMP, GSRegFOGCOL, GSRegSCISSOR_1, GSRegPRIM,
    GSRegTEX0_1, GSRegTEX1_1, GSRegCLAMP_1, GSRegTEXA);
var
  V: array[0..2] of TPS2GSVertex;
begin
  var A := TPS2GSRaster.Create;
  var B := TPS2GSRaster.Create;
  try
    EnableVulkan(B);
    if B.VulkanError <> '' then raise Exception.Create(B.VulkanError);
    RandSeed := 8173;
    for var N := 0 to 255 do
    begin
      if N and 1 = 0 then SetRoundMode(rmNearest) else SetRoundMode(rmTruncate);
      A.Reset; B.Reset;
      var PA := PCardinal(A.Memory.Data);
      for var K := 0 to PS2GSMemorySize div 4 - 1 do PA[K] := Cardinal(K) * 1664525 + Cardinal(N) * 1013904223;
      Move(PA^, B.Memory.Data^, PS2GSMemorySize);
      var D := Default(TPS2GSDraw);
      D.FBW := 4; D.FPSM := Cardinal(N and 1);
      if N mod 3 = 2 then D.FPSM := Frames16[(N div 3) and 3];
      D.ZBP := 8192; D.ZPSM := PSMZ32 + Cardinal((N shr 1) and 1);
      D.ZMSK := Random(2) <> 0;
      D.ATE := Random(2) <> 0; D.ATST := N and 7;
      D.AREF := Random(256); D.AFAIL := (N shr 3) and 3;
      D.DATE := Random(2) <> 0; D.DATM := Random(2) <> 0;
      D.ZTST := (N shr 5) and 3;
      D.ABE := Random(2) <> 0; D.FGE := Random(2) <> 0;
      D.IIP := Random(2) <> 0;
      D.BlendA := Random(4); D.BlendB := Random(4); D.BlendC := Random(4); D.BlendD := Random(4);
      D.BlendFix := Random(256); D.PABE := Random(2) <> 0; D.FBA := Random(2) <> 0;
      D.ColClamp := Random(2) <> 0; D.FBMSK := Cardinal(Random(MaxInt));
      if N mod 3 = 0 then D.FBMSK := 0;
      D.FogR := Random(256); D.FogG := Random(256); D.FogB := Random(256);
      D.TME := N mod 3 <> 0; D.TPSM := Cardinal(N and 1);
      D.TCC := Random(2) <> 0; D.TFX := N mod 4; D.FST := N and 2 = 0;
      D.Linear := Random(2) <> 0; D.TA0 := Random(256); D.AEM := Random(2) <> 0;
      for var K := 0 to 2 do
      begin
        V[K] := Default(TPS2GSVertex);
        V[K].R := Random(256); V[K].G := Random(256); V[K].B := Random(256); V[K].A := Random(256);
        V[K].F := Random(256); V[K].Z := Cardinal(Random(MaxInt));
        V[K].U := Random(8192); V[K].V := Random(8192);
        V[K].S := Random * 3; V[K].T := Random * 3; V[K].Q := 0.25 + Random * 2;
        // Negative Q (and S/T of either sign) take the same path.
        if N mod 5 = 2 then
        begin
          V[K].Q := -V[K].Q; V[K].S := V[K].S - 1.5; V[K].T := 1.5 - V[K].T;
        end;
      end;
      V[0].X := (8 + Random(16)) * 16 + Random(16); V[0].Y := (8 + Random(16)) * 16 + Random(16);
      V[1].X := (216 + Random(16)) * 16 + Random(16); V[1].Y := (16 + Random(16)) * 16 + Random(16);
      V[2].X := (64 + Random(64)) * 16 + Random(16); V[2].Y := (216 + Random(16)) * 16 + Random(16);
      D.SX0 := 16; D.SY0 := 16; D.SX1 := 223; D.SY1 := 223;
      if N = 255 then
      begin
        // More than 65536 fragments: rollover inside one primitive must
        // preserve both the parameter slot and order of earlier chunks.
        D.FBW := 10; D.SX0 := 0; D.SY0 := 0; D.SX1 := 639; D.SY1 := 479;
        D.TME := False;
        V[0].X := 0; V[0].Y := 0;
        V[1].X := 640 * 16; V[1].Y := 0;
        V[2].X := 0; V[2].Y := 480 * 16;
      end;
      if N and 4 <> 0 then
      begin
        var Temp := V[0]; V[0] := V[1]; V[1] := Temp;
      end;
      // A texture past the end of VRAM continues at its start (frame moved
      // off those pages).
      var TBP: UInt64 := 4096;
      var FramePage: UInt64 := 0;
      if (N mod 8 = 6) and (N <> 255) then
      begin
        TBP := 16384 - 64;
        FramePage := 64;
      end;
      A.WriteRegister(GSRegFRAME_1, FramePage or (UInt64(D.FBW) shl 16) or (UInt64(D.FPSM) shl 24) or (UInt64(D.FBMSK) shl 32));
      A.WriteRegister(GSRegZBUF_1, UInt64(D.ZBP div 32) or (UInt64(D.ZPSM and 15) shl 24) or (UInt64(Ord(D.ZMSK)) shl 32));
      A.WriteRegister(GSRegTEST_1, UInt64(Ord(D.ATE)) or (UInt64(D.ATST) shl 1) or
        (UInt64(D.AREF) shl 4) or (UInt64(D.AFAIL) shl 12) or (UInt64(Ord(D.DATE)) shl 14) or
        (UInt64(Ord(D.DATM)) shl 15) or $10000 or (UInt64(D.ZTST) shl 17));
      A.WriteRegister(GSRegALPHA_1, UInt64(D.BlendA) or (UInt64(D.BlendB) shl 2) or
        (UInt64(D.BlendC) shl 4) or (UInt64(D.BlendD) shl 6) or (UInt64(D.BlendFix) shl 32));
      A.WriteRegister(GSRegPABE, Ord(D.PABE)); A.WriteRegister(GSRegFBA_1, Ord(D.FBA));
      A.WriteRegister(GSRegCOLCLAMP, Ord(D.ColClamp));
      A.WriteRegister(GSRegFOGCOL, UInt64(D.FogR) or (UInt64(D.FogG) shl 8) or (UInt64(D.FogB) shl 16));
      A.WriteRegister(GSRegSCISSOR_1, UInt64(D.SX0) or (UInt64(D.SX1) shl 16) or
        (UInt64(D.SY0) shl 32) or (UInt64(D.SY1) shl 48));
      A.WriteRegister(GSRegPRIM, 3 or (UInt64(Ord(D.ABE)) shl 6) or (UInt64(Ord(D.FGE)) shl 5) or
        (UInt64(Ord(D.TME)) shl 4) or (UInt64(Ord(D.IIP)) shl 3) or (UInt64(Ord(D.FST)) shl 8));
      A.WriteRegister(GSRegTEX0_1, TBP or (UInt64(2) shl 14) or (UInt64(D.TPSM) shl 20) or
        (UInt64(7) shl 26) or (UInt64(7) shl 30) or (UInt64(Ord(D.TCC)) shl 34) or (UInt64(D.TFX) shl 35));
      A.WriteRegister(GSRegTEX1_1, UInt64(Ord(D.Linear)) * $60);
      A.WriteRegister(GSRegCLAMP_1, UInt64(Random(16)) or (UInt64(Random(128)) shl 4) or
        (UInt64(128 + Random(128)) shl 14) or (UInt64(Random(128)) shl 24) or (UInt64(128 + Random(128)) shl 34));
      A.WriteRegister(GSRegTEXA, UInt64(D.TA0) or (UInt64(Ord(D.AEM)) shl 15));
      for var Reg in Registers do B.WriteRegister(Reg, A.Regs[Reg]);
      for var K := 0 to 2 do Vertex(A, V[K]);
      for var K := 0 to 2 do Vertex(B, V[K]);
      B.Sync;
      if not CompareMem(A.Memory.Data, B.Memory.Data, PS2GSMemorySize) or
          (A.PixelsDrawn <> B.PixelsDrawn) or (A.Primitives <> B.Primitives) then
      begin
        var MA := PCardinal(A.Memory.Data);
        var MB := PCardinal(B.Memory.Data);
        var Shown := 0;
        for var I := 0 to PS2GSMemorySize div 4 - 1 do
          if MA[I] <> MB[I] then
          begin
            Writeln(Format('VRAM %.6x CPU %.8x GPU %.8x', [I, MA[I], MB[I]]));
            Inc(Shown); if Shown = 12 then Break;
          end;
        Writeln(Format('round %d iip %d ztst %d ate %d atst %d aref %d afail %d pixels %d/%d',
          [Ord(GetRoundMode), Ord(D.IIP), D.ZTST, Ord(D.ATE), D.ATST, D.AREF, D.AFAIL, A.PixelsDrawn, B.PixelsDrawn]));
        for var I := 0 to 2 do
          Writeln(Format('v%d %d,%d z=%x rgba=%d,%d,%d,%d', [I,V[I].X,V[I].Y,V[I].Z,V[I].R,V[I].G,V[I].B,V[I].A]));
        raise Exception.CreateFmt('Triangle mismatch %d', [N]);
      end;
      if B.VulkanTriangles <> N + 1 then raise Exception.CreateFmt('Triangle fell back %d', [N]);
    end;
    Writeln('Triangles=256, fragment rollover, both windings and rounding modes: OK');
    Writeln('Full GPU coverage/interpolation triangles=', B.VulkanRasterizedTriangles);
  finally
    B.Free;
    A.Free;
  end;
end;

begin
  try
    if FindCmdLineSwitch('coverageonly') then
    begin
      for var RepeatIndex := 0 to 99 do CheckCoverageCounter;
      Halt(0);
    end;
    var A := TPS2GSRaster.Create;
    var B := TPS2GSMemory.Create;
    var GPU := TPS2GSGpu.Create(B.Data);
    try
      for var Textured := 0 to 1 do
      for var Batch := 0 to 1 do
      begin
      if Batch = 0 then SetRoundMode(rmNearest) else SetRoundMode(rmTruncate);
      RandSeed := 3917;
      for var N := 0 to 255 do
      begin
        var PA := PCardinal(A.Memory.Data);
        if (Batch = 0) or (N = 0) then
        begin
          A.Reset;
          for var K := 0 to PS2GSMemorySize div 4 - 1 do
            PA[K] := Cardinal(K) * 1664525 + Cardinal(N) * 1013904223;
          Move(PA^, B.Data^, PS2GSMemorySize);
        end;
        var D := Default(TPS2GSDraw);
        D.TME := Textured <> 0;
        D.TBP := 4096;
        D.TBW := 1;
        D.TPSM := Cardinal(N and 1);
        D.TW := 6; D.TH := 7;
        D.FST := N mod 3 <> 0;
        D.TFX := N mod 4;
        D.TCC := Random(2) <> 0;
        D.Linear := Random(2) <> 0;
        D.WMS := Random(4); D.WMT := Random(4);
        D.MINU := Random(128); D.MAXU := Random(256);
        D.MINV := Random(128); D.MAXV := Random(256);
        D.TA0 := Random(256); D.AEM := Random(2) <> 0;
        D.FBW := 4;
        D.FPSM := Cardinal(N and 1);
        if N mod 3 = 2 then D.FPSM := Frames16[(N div 3) and 3];
        D.ZBP := 8192;
        D.ZPSM := PSMZ32 + Cardinal((N shr 1) and 1);
        D.ZMSK := Random(2) <> 0;
        D.ATE := Random(2) <> 0;
        D.ATST := N and 7;
        D.AREF := Random(256);
        D.AFAIL := (N shr 3) and 3;
        D.DATE := Random(2) <> 0;
        D.DATM := Random(2) <> 0;
        D.ZTE := True;
        D.ZTST := (N shr 5) and 3;
        D.BlendA := Random(4); D.BlendB := Random(4);
        D.BlendC := Random(4); D.BlendD := Random(4);
        D.BlendFix := Random(256);
        D.PABE := Random(2) <> 0;
        D.FBA := Random(2) <> 0;
        D.ColClamp := Random(2) <> 0;
        D.ABE := Random(2) <> 0;
        D.FGE := Random(2) <> 0;
        D.FogR := Random(256); D.FogG := Random(256); D.FogB := Random(256);
        D.FBMSK := Cardinal(Random(MaxInt));
        if N mod 3 = 0 then D.FBMSK := 0;
        var V := Default(TPS2GSVertex);
        V.R := Random(256); V.G := Random(256); V.B := Random(256); V.A := Random(256);
        V.F := Random(256); V.Z := Cardinal(Random(MaxInt)) or $80000000;
        V.X := 2304; V.Y := 2304;
        V.U := Random(8192); V.V := Random(8192);
        V.S := Random * 3; V.T := Random * 3; V.Q := 0.5;
        var V0 := V;
        V0.X := 256; V0.Y := 256;
        V0.U := Random(8192); V0.V := Random(8192);
        V0.S := Random * 3; V0.T := Random * 3; V0.Q := 2;
        A.WriteRegister(GSRegTEX0_1, UInt64(D.TBP) or (UInt64(D.TBW) shl 14) or
          (UInt64(D.TPSM) shl 20) or (UInt64(D.TW) shl 26) or (UInt64(D.TH) shl 30) or
          (UInt64(Ord(D.TCC)) shl 34) or (UInt64(D.TFX) shl 35));
        A.WriteRegister(GSRegTEX1_1, UInt64(Ord(D.Linear)) * $60);
        A.WriteRegister(GSRegCLAMP_1, UInt64(D.WMS) or (UInt64(D.WMT) shl 2) or
          (UInt64(D.MINU) shl 4) or (UInt64(D.MAXU) shl 14) or
          (UInt64(D.MINV) shl 24) or (UInt64(D.MAXV) shl 34));
        A.WriteRegister(GSRegTEXA, UInt64(D.TA0) or (UInt64(Ord(D.AEM)) shl 15));
        A.WriteRegister(GSRegFRAME_1, (UInt64(D.FBW) shl 16) or (UInt64(D.FPSM) shl 24) or (UInt64(D.FBMSK) shl 32));
        A.WriteRegister(GSRegZBUF_1, UInt64(D.ZBP div 32) or (UInt64(D.ZPSM and 15) shl 24) or (UInt64(Ord(D.ZMSK)) shl 32));
        A.WriteRegister(GSRegTEST_1, UInt64(Ord(D.ATE)) or (UInt64(D.ATST) shl 1) or
          (UInt64(D.AREF) shl 4) or (UInt64(D.AFAIL) shl 12) or (UInt64(Ord(D.DATE)) shl 14) or
          (UInt64(Ord(D.DATM)) shl 15) or $10000 or (UInt64(D.ZTST) shl 17));
        A.WriteRegister(GSRegALPHA_1, UInt64(D.BlendA) or (UInt64(D.BlendB) shl 2) or
          (UInt64(D.BlendC) shl 4) or (UInt64(D.BlendD) shl 6) or (UInt64(D.BlendFix) shl 32));
        A.WriteRegister(GSRegPABE, Ord(D.PABE));
        A.WriteRegister(GSRegFBA_1, Ord(D.FBA));
        A.WriteRegister(GSRegCOLCLAMP, Ord(D.ColClamp));
        A.WriteRegister(GSRegFOGCOL, UInt64(D.FogR) or (UInt64(D.FogG) shl 8) or (UInt64(D.FogB) shl 16));
        A.WriteRegister(GSRegSCISSOR_1, (UInt64(255) shl 16) or (UInt64(255) shl 48));
        A.WriteRegister(GSRegPRIM, 6 or (UInt64(Ord(D.ABE)) shl 6) or (UInt64(Ord(D.FGE)) shl 5) or
          (UInt64(Ord(D.TME)) shl 4) or (UInt64(Ord(D.FST)) shl 8));
        A.WriteRegister(GSRegRGBAQ, UInt64(V.R) or (UInt64(V.G) shl 8) or (UInt64(V.B) shl 16) or (UInt64(V.A) shl 24));
        A.WriteRegister(GSRegFOG, UInt64(V.F) shl 56);
        Vertex(A, V0);
        Vertex(A, V);
        if not GPU.Sprite(D, V0, V, 16, 16, 144, 144, 0) then
          raise Exception.CreateFmt('Unexpected fallback %d', [N]);
        if (Batch = 0) or (N = 255) then
          GPU.Sync;
        if ((Batch = 0) or (N = 255)) and not CompareMem(A.Memory.Data, B.Data, PS2GSMemorySize) then
        begin
          var PB := PCardinal(B.Data);
          for var K := 0 to PS2GSMemorySize div 4 - 1 do
            if PA[K] <> PB[K] then
              raise Exception.CreateFmt('Mismatch draw=%d word=%x cpu=%x gpu=%x', [N, K, PA[K], PB[K]]);
        end;
        D.TME := True;
        D.TBP := 0;
        if GPU.Sprite(D, V0, V, 16, 16, 144, 144, 0) then raise Exception.Create('Texture feedback accepted');
        D.TME := False;
        D.ZBP := D.FBP;
        D.ZMSK := False;
        if GPU.Sprite(D, V0, V, 16, 16, 144, 144, 0) then raise Exception.Create('Overlapping surfaces accepted');
        D.ZBP := 8192;
        D.FPSM := PSMZ32;
        if GPU.Sprite(D, V0, V, 16, 16, 144, 144, 0) then raise Exception.Create('Unsupported format accepted');
        if ((Batch = 0) or (N = 255)) and not CompareMem(A.Memory.Data, B.Data, PS2GSMemorySize) then
          raise Exception.Create('Fallback wrote memory');
      end;
      end;
      if GPU.Submissions <> 514 then raise Exception.Create('Batch grouping mismatch');
      Writeln('GPU draws=', GPU.Draws, ' submissions=', GPU.Submissions, ' mismatches=0');
      // Exercise the public selector as well as direct GPU calls: the
      // raster owns the imported memory while changing execution mode.
      var Baseline: TBytes;
      for var Mode := 0 to 3 do
      begin
        A.Vulkan := Mode in [1, 3];
        if A.VulkanError <> '' then raise Exception.Create(A.VulkanError);
        if Mode in [2, 3] then A.Threads := 4 else A.Threads := 0;
        A.Reset;
        A.WriteRegister(GSRegFRAME_1, UInt64(4) shl 16);
        A.WriteRegister(GSRegZBUF_1, UInt64(1) shl 32);
        A.WriteRegister(GSRegSCISSOR_1, (UInt64(255) shl 16) or (UInt64(255) shl 48));
        A.WriteRegister(GSRegPRIM, 6);
        A.WriteRegister(GSRegRGBAQ, $80402010);
        A.WriteRegister(GSRegXYZ2, 0);
        A.WriteRegister(GSRegXYZ2, 4096 or (UInt64(4096) shl 16));
        // Software point after a queued GPU draw.
        A.WriteRegister(GSRegPRIM, 0);
        A.WriteRegister(GSRegRGBAQ, $80808080);
        A.WriteRegister(GSRegXYZ2, 3840 or (UInt64(3840) shl 16));
        A.WriteRegister(GSRegPRIM, 6);
        A.WriteRegister(GSRegXYZ2, 1024 or (UInt64(1024) shl 16));
        A.WriteRegister(GSRegXYZ2, 3072 or (UInt64(3072) shl 16));
        // CPU host-to-local transfer must follow the second GPU sprite.
        A.WriteRegister(GSRegBITBLTBUF, UInt64(4) shl 48);
        A.WriteRegister(GSRegTRXPOS, (UInt64(168) shl 32) or (UInt64(168) shl 48));
        A.WriteRegister(GSRegTRXREG, 1 or (UInt64(1) shl 32));
        A.WriteRegister(GSRegTRXDIR, 0);
        A.WriteRegister(GSRegHWREG, $AABBCCDD);
        // A CLUT load from the next sprite's target reads before an explicit
        // Sync. Compare serialized CLUT bytes as well as VRAM below.
        A.WriteRegister(GSRegRGBAQ, $80706050);
        A.WriteRegister(GSRegXYZ2, 0);
        A.WriteRegister(GSRegXYZ2, 2048 or (UInt64(2048) shl 16));
        A.WriteRegister(GSRegTEX0_1, (UInt64(PSMT8) shl 20) or (UInt64(1) shl 61));
        // A snapshot must also drain a still-pending draw. Keep the point
        // and transfer outside this rectangle so their ordering stays visible.
        A.WriteRegister(GSRegRGBAQ, $80605040);
        A.WriteRegister(GSRegXYZ2, 0);
        A.WriteRegister(GSRegXYZ2, 2048 or (UInt64(2048) shl 16));
        // Render to an off-screen surface, then sample it without a host
        // read or Sync in between. The inter-dispatch barrier owns ordering.
        A.WriteRegister(GSRegFRAME_1, 128 or (UInt64(4) shl 16));
        A.WriteRegister(GSRegRGBAQ, $80906030);
        A.WriteRegister(GSRegXYZ2, 0);
        A.WriteRegister(GSRegXYZ2, 2048 or (UInt64(2048) shl 16));
        A.WriteRegister(GSRegFRAME_1, UInt64(4) shl 16);
        A.WriteRegister(GSRegTEX0_1, 4096 or (UInt64(4) shl 14) or (UInt64(7) shl 26) or
          (UInt64(7) shl 30) or (UInt64(1) shl 34) or (UInt64(1) shl 35));
        A.WriteRegister(GSRegPRIM, $116); // Textured UV sprite, no blending.
        A.WriteRegister(GSRegUV, 0);
        A.WriteRegister(GSRegXYZ2, 0);
        A.WriteRegister(GSRegUV, 2048 or (UInt64(2048) shl 16));
        A.WriteRegister(GSRegXYZ2, 2048 or (UInt64(2048) shl 16));
        var Stream := TMemoryStream.Create;
        try
          var Archive := TStateArchive.Create(Stream, False);
          try A.SerializeState(Archive); finally Archive.Free; end;
          var Bytes: TBytes;
          SetLength(Bytes, Stream.Size);
          Move(Stream.Memory^, Bytes[0], Length(Bytes));
          if Mode = 0 then Baseline := Bytes
          else if (Length(Bytes) <> Length(Baseline)) or not CompareMem(@Bytes[0], @Baseline[0], Length(Bytes)) then
            raise Exception.CreateFmt('Renderer state mismatch %d', [Mode]);
        finally
          Stream.Free;
        end;
        if Mode = 0 then Move(A.Memory.Data^, B.Data^, PS2GSMemorySize)
        else if not CompareMem(A.Memory.Data, B.Data, PS2GSMemorySize) then
          raise Exception.CreateFmt('Renderer switch mismatch %d', [Mode]);
        if (Mode in [1, 3]) and (A.VulkanDraws <> 6) then raise Exception.Create('GPU selector did not draw');
      end;
      Writeln('software -> Vulkan -> threaded software: OK');
    finally
      GPU.Free;
      B.Free;
      A.Free;
    end;
    CheckCoverageCounter;
    // Clustered draws in two passes for every cluster, in one for every
    // cluster, then as chosen by the tiles' draws.
    for var TwoPhase in [1, MaxInt, 8] do
    begin
      PS2GSTwoPhaseDraws := TwoPhase;
      Writeln('-- clusters in two passes from ', TwoPhase, ' draws in a tile');
      CheckTiledTriangles;
      CheckHybridRenderers;
      CheckClusterDependencies;
      CheckNativeArenas;
      CheckTriangles;
      CheckTextureFormats;
    end;
    CheckPageBarriers;
    CheckTransferBarriers;
    CheckTransferRevision;
    CheckPaletteBarriers;
    CheckFragmentRollover;
    CheckClutSnapshots;
  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
