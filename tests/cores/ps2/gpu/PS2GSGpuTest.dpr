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
        if not GPU.Sprite(D, V0, V, 16, 16, 144, 144) then
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
        if GPU.Sprite(D, V0, V, 16, 16, 144, 144) then raise Exception.Create('Texture feedback accepted');
        D.TME := False;
        D.ZBP := D.FBP;
        D.ZMSK := False;
        if GPU.Sprite(D, V0, V, 16, 16, 144, 144) then raise Exception.Create('Overlapping surfaces accepted');
        D.ZBP := 8192;
        D.FPSM := PSMCT16;
        if GPU.Sprite(D, V0, V, 16, 16, 144, 144) then raise Exception.Create('Unsupported format accepted');
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
  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
