program PS2GSGpuTest;

{$APPTYPE CONSOLE}
{$POINTERMATH ON}
{$Q-} // Deliberately wrapping pattern used to initialize VRAM.

uses
  System.SysUtils, PS2.Types, PS2.GS.Memory, PS2.GS.Raster, PS2.GS.Gpu;

begin
  try
    var A := TPS2GSRaster.Create;
    var B := TPS2GSMemory.Create;
    var GPU := TPS2GSGpu.Create(B.Data);
    try
      RandSeed := 3917;
      for var N := 0 to 255 do
      begin
        A.Reset;
        var PA := PCardinal(A.Memory.Data);
        for var K := 0 to PS2GSMemorySize div 4 - 1 do
          PA[K] := Cardinal(K) * 1664525 + Cardinal(N) * 1013904223;
        Move(PA^, B.Data^, PS2GSMemorySize);
        var D := Default(TPS2GSDraw);
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
        A.WriteRegister(GSRegPRIM, 6 or (UInt64(Ord(D.ABE)) shl 6) or (UInt64(Ord(D.FGE)) shl 5));
        A.WriteRegister(GSRegRGBAQ, UInt64(V.R) or (UInt64(V.G) shl 8) or (UInt64(V.B) shl 16) or (UInt64(V.A) shl 24));
        A.WriteRegister(GSRegFOG, UInt64(V.F) shl 56);
        A.WriteRegister(GSRegXYZ2, 256 or (UInt64(256) shl 16) or (UInt64(V.Z) shl 32));
        A.WriteRegister(GSRegXYZ2, 2304 or (UInt64(2304) shl 16) or (UInt64(V.Z) shl 32));
        if not GPU.Sprite(D, V, 16, 16, 144, 144) then
          raise Exception.CreateFmt('Unexpected fallback %d', [N]);
        if not CompareMem(A.Memory.Data, B.Data, PS2GSMemorySize) then
        begin
          var PB := PCardinal(B.Data);
          for var K := 0 to PS2GSMemorySize div 4 - 1 do
            if PA[K] <> PB[K] then
              raise Exception.CreateFmt('Mismatch draw=%d word=%x cpu=%x gpu=%x', [N, K, PA[K], PB[K]]);
        end;
        D.TME := True;
        if GPU.Sprite(D, V, 16, 16, 144, 144) then raise Exception.Create('Texture accepted');
        D.TME := False;
        D.ZBP := D.FBP;
        D.ZMSK := False;
        if GPU.Sprite(D, V, 16, 16, 144, 144) then raise Exception.Create('Overlapping surfaces accepted');
        D.ZBP := 8192;
        D.FPSM := PSMCT16;
        if GPU.Sprite(D, V, 16, 16, 144, 144) then raise Exception.Create('Unsupported format accepted');
        if not CompareMem(A.Memory.Data, B.Data, PS2GSMemorySize) then raise Exception.Create('Fallback wrote memory');
      end;
      Writeln('GPU draws=', GPU.Draws, ' mismatches=0');
      // Exercise the public selector as well as direct GPU calls: the
      // raster owns the imported memory while changing execution mode.
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
        A.WriteRegister(GSRegXYZ2, 2048 or (UInt64(2048) shl 16));
        A.Sync;
        if Mode = 0 then Move(A.Memory.Data^, B.Data^, PS2GSMemorySize)
        else if not CompareMem(A.Memory.Data, B.Data, PS2GSMemorySize) then
          raise Exception.CreateFmt('Renderer switch mismatch %d', [Mode]);
        if (Mode = 1) and (A.VulkanDraws <> 1) then raise Exception.Create('GPU selector did not draw');
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
