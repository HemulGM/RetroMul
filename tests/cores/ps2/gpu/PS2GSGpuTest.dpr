program PS2GSGpuTest;

{$APPTYPE CONSOLE}
{$POINTERMATH ON}
{$Q-} // Deliberately wrapping pattern used to initialize VRAM.

uses
  System.SysUtils, System.Classes, System.Math, Core.Snapshots, PS2.Types, PS2.GS.Memory, PS2.GS.Raster, PS2.GS.Gpu;

procedure Vertex(Raster: TPS2GSRaster; const V: TPS2GSVertex);
begin
  Raster.WriteRegister(GSRegRGBAQ, UInt64(V.R) or (UInt64(V.G) shl 8) or (UInt64(V.B) shl 16) or
    (UInt64(V.A) shl 24) or (UInt64(PCardinal(@V.Q)^) shl 32));
  Raster.WriteRegister(GSRegST, UInt64(PCardinal(@V.S)^) or (UInt64(PCardinal(@V.T)^) shl 32));
  Raster.WriteRegister(GSRegUV, UInt64(V.U) or (UInt64(V.V) shl 16));
  Raster.WriteRegister(GSRegFOG, UInt64(V.F) shl 56);
  Raster.WriteRegister(GSRegXYZ2, UInt64(V.X) or (UInt64(V.Y) shl 16) or (UInt64(V.Z) shl 32));
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
    B.Vulkan := True;
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
    for var Threads in TArray<Integer>.Create(2, 4, 6) do
    begin
      B.Threads := Threads;
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
            raise Exception.CreateFmt('Band coverage VRAM mismatch threads=%d triangle=%d', [Threads, N]);
        end;
      end;
    end;
    B.Sync;
    if not CompareMem(A.Memory.Data, B.Memory.Data, PS2GSMemorySize) then
      raise Exception.Create('Coverage VRAM mismatch');
    Writeln('1536 clipped/subpixel coverage cases, 2/4/6 bands: VRAM and exact counters OK');
  finally
    A.Free; B.Free;
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
    B.Vulkan := True;
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
      A.WriteRegister(GSRegFRAME_1, (UInt64(D.FBW) shl 16) or (UInt64(D.FPSM) shl 24) or (UInt64(D.FBMSK) shl 32));
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
      A.WriteRegister(GSRegTEX0_1, 4096 or (UInt64(2) shl 14) or (UInt64(D.TPSM) shl 20) or
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
        raise Exception.CreateFmt('Triangle mismatch %d', [N]);
      if B.VulkanTriangles <> N + 1 then raise Exception.CreateFmt('Triangle fell back %d', [N]);
    end;
    Writeln('Triangles=256, fragment rollover, both windings and rounding modes: OK');
  finally
    B.Free;
    A.Free;
  end;
end;

begin
  try
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
        D.FPSM := PSMCT16;
        if GPU.Sprite(D, V0, V, 16, 16, 144, 144, 0) then raise Exception.Create('Unsupported format accepted');
        if ((Batch = 0) or (N = 255)) and not CompareMem(A.Memory.Data, B.Data, PS2GSMemorySize) then
          raise Exception.Create('Fallback wrote memory');
      end;
      end;
      if GPU.Submissions <> 516 then raise Exception.Create('Batch capacity/reuse mismatch');
      Writeln('GPU draws=', GPU.Draws, ' submissions=', GPU.Submissions, ' mismatches=0');
      // Exercise the public selector as well as direct GPU calls: the
      // raster owns the imported memory while changing execution mode.
      var Baseline: TBytes;
      for var Mode := 0 to 2 do
      begin
        A.Vulkan := Mode = 1;
        if A.VulkanError <> '' then raise Exception.Create(A.VulkanError);
        if Mode = 2 then A.Threads := 4 else A.Threads := 0;
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
        if (Mode = 1) and (A.VulkanDraws <> 6) then raise Exception.Create('GPU selector did not draw');
      end;
      Writeln('software -> Vulkan -> threaded software: OK');
    finally
      GPU.Free;
      B.Free;
      A.Free;
    end;
    CheckCoverageCounter;
    CheckTriangles;
    CheckTextureFormats;
    CheckClutSnapshots;
  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
