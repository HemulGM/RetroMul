program PS2GSDataTest;

{$APPTYPE CONSOLE}
{$POINTERMATH ON}
{$Q-} // Deliberately wrapping VRAM/input patterns.

uses
  System.SysUtils, System.Classes, System.Math, Core.Snapshots,
  PS2.Types, PS2.GS, PS2.GS.Memory, PS2.GS.Raster;

const
  Formats: array[0..12] of Integer = (PSMCT32, PSMCT24, PSMCT16, PSMCT16S,
    PSMZ32, PSMZ24, PSMZ16, PSMZ16S, PSMT8, PSMT4, PSMT8H, PSMT4HL, PSMT4HH);

function StateBytes(Raster: TPS2GSRaster): TBytes;
begin
  var S := TMemoryStream.Create;
  try
    var A := TStateArchive.Create(S, False);
    try Raster.SerializeState(A); finally A.Free; end;
    SetLength(Result, S.Size);
    Move(S.Memory^, Result[0], Length(Result));
  finally
    S.Free;
  end;
end;

procedure QueueDraw(Raster: TPS2GSRaster);
begin
  Raster.WriteRegister(GSRegFRAME_1, UInt64(4) shl 16);
  Raster.WriteRegister(GSRegZBUF_1, UInt64(1) shl 32);
  Raster.WriteRegister(GSRegSCISSOR_1, (UInt64(255) shl 16) or (UInt64(255) shl 48));
  Raster.WriteRegister(GSRegPRIM, 6);
  Raster.WriteRegister(GSRegRGBAQ, $80573917);
  Raster.WriteRegister(GSRegXYZ2, 0);
  Raster.WriteRegister(GSRegXYZ2, 128 * 16 or (UInt64(128 * 16) shl 16));
end;

procedure CheckDisplay;
begin
  var GS := TPS2GS.Create;
  try
    GS.Raster.Threads := 4;
    var Memory := GS.Raster.Memory;
    for var Format in Formats do
      for var N := 0 to 3 do
      begin
        GS.Reset;
        var P := PCardinal(Memory.Data);
        for var I := 0 to PS2GSMemorySize div 4 - 1 do P[I] := Cardinal(I) * 1664525 + 1013904223;
        QueueDraw(GS.Raster);
        var W := 67;
        var H := 37;
        var X := N * 681;
        var Y := N * 677;
        var BW := N;
        var BP := Cardinal((N * 508) and $1FF);
        var FB := UInt64(BP) or (UInt64(BW) shl 9) or (UInt64(Format) shl 15) or
          (UInt64(X) shl 32) or (UInt64(Y) shl 43);
        var Display := (UInt64(W - 1) shl 32) or (UInt64(H - 1) shl 44);
        GS.PMODE := UInt64(1 shl (N and 1)) or $20 or (UInt64(128) shl 8);
        if N and 1 = 0 then begin GS.DISPFB1 := FB; GS.DISPLAY1 := Display; end
        else begin GS.DISPFB2 := FB; GS.DISPLAY2 := Display; end;
        GS.Interlaced := N >= 2;
        GS.SMODE2 := 3;
        if GS.Interlaced then H := H div 2;
        GS.BuildFrame; // Must publish the queued draw before scanning VRAM.
        if (GS.FrameWidth <> W) or (GS.FrameHeight <> H) then raise Exception.Create('Display dimensions');
        for var DY := 0 to H - 1 do
          for var DX := 0 to W - 1 do
          begin
            var Pixel := Memory.ReadPixel(Format and $1F, BP * 2048, Cardinal(BW * 64), X + DX, Y + DY);
            var Expected := Cardinal($FF000000) or ((Pixel and $FF) shl 16) or
              (Pixel and $FF00) or ((Pixel shr 16) and $FF);
            if GS.Frame[DY * W + DX] <> Expected then
              raise Exception.CreateFmt('Display mismatch format=%x case=%d pixel=%d,%d', [Format, N, DX, DY]);
          end;
      end;
    GS.DISPLAY1 := UInt64(66) shl 32; GS.PMODE := 1; GS.Interlaced := True; GS.SMODE2 := 3;
    GS.BuildFrame;
    if Length(GS.Frame) <> 0 then raise Exception.Create('Zero-height display');
    Writeln('52 display scans: formats, both circuits, offsets/wrap, zero stride, queued draws: OK');
  finally
    GS.Free;
  end;
end;

procedure CheckTransfers;
begin
  var A := TPS2GSRaster.Create;
  var B := TPS2GSRaster.Create;
  try
    var MA := A.Memory;
    var MB := B.Memory;
    var Cases := 0;
    for var Format in Formats do
      for var N := 0 to 9 do
      begin
        B.Threads := 0;
        if N and 1 <> 0 then B.Threads := 4;
        A.Reset; B.Reset;
        var P := PCardinal(MA.Data);
        for var I := 0 to PS2GSMemorySize div 4 - 1 do P[I] := Cardinal(I) * 1664525 + Cardinal(N) * 1013904223;
        Move(MA.Data^, MB.Data^, PS2GSMemorySize);
        var Width := 17 + N * 11;
        var Height := 13 + N * 3;
        if N = 9 then begin Width := 1025; Height := 1025; end; // Run and physical ring rollover.
        var Base := (N * 1819) and $3FFF;
        var BW := N mod 5;
        var X := (N * 679) and $7FF;
        var Y := (N * 677) and $7FF;
        for var R in TArray<TPS2GSRaster>.Create(A, B) do
        begin
          QueueDraw(R);
          R.WriteRegister(GSRegBITBLTBUF, (UInt64(Base) shl 32) or (UInt64(BW) shl 48) or (UInt64(Format) shl 56));
          R.WriteRegister(GSRegTRXPOS, (UInt64(X) shl 32) or (UInt64(Y) shl 48));
          R.WriteRegister(GSRegTRXREG, UInt64(Width) or (UInt64(Height) shl 32));
          R.WriteRegister(GSRegTRXDIR, 0);
        end;
        var Bits := 32;
        case Format of
          PSMCT24, PSMZ24: Bits := 24;
          PSMCT16, PSMCT16S, PSMZ16, PSMZ16S: Bits := 16;
          PSMT8, PSMT8H: Bits := 8;
          PSMT4, PSMT4HL, PSMT4HH: Bits := 4;
        end;
        var Quads := (Width * Height * Bits + 127) div 128 + 1;
        for var I := 0 to Quads - 1 do
        begin
          var Q: TPS2Reg128;
          for var K := 0 to 3 do Q.UW[K] := Cardinal(I * 4 + K) * 1664525 + Cardinal(N) * 1013904223;
          A.WriteRegister(GSRegHWREG, Q.Lo);
          A.WriteRegister(GSRegHWREG, Q.Hi);
          if (N mod 3 = 1) and (I and 7 = 0) then
          begin
            B.WriteRegister(GSRegHWREG, Q.Lo);
            B.WriteRegister(GSRegHWREG, Q.Hi);
          end
          else B.WriteImage(Q);
          if (I = 2) and (N mod 3 = 2) then
          begin
            // A snapshot in the middle must retain the exact bitstream tail.
            A.Regs[GSRegHWREG] := 0; B.Regs[GSRegHWREG] := 0;
            var SA := StateBytes(A);
            var SB := StateBytes(B);
            if (Length(SA) <> Length(SB)) or not CompareMem(@SA[0], @SB[0], Length(SA)) then
              raise Exception.CreateFmt('Partial transfer state format=%x case=%d', [Format, N]);
          end;
        end;
        A.Regs[GSRegHWREG] := 0; B.Regs[GSRegHWREG] := 0; // Compare transport-independent register state.
        var SA := StateBytes(A);
        var SB := StateBytes(B);
        if (Length(SA) <> Length(SB)) or not CompareMem(@SA[0], @SB[0], Length(SA)) or
          not CompareMem(MA.Data, MB.Data, PS2GSMemorySize) or (A.PixelsTransferred <> B.PixelsTransferred) then
          raise Exception.CreateFmt('IMAGE/HWREG transfer mismatch format=%x case=%d', [Format, N]);
        Inc(Cases);
      end;
    Writeln(Cases, ' IMAGE/HWREG transfers: all formats, bit tails, strides/wrap, ring rollover and state: OK');
  finally
    A.Free; B.Free;
  end;
end;

begin
  try
    CheckDisplay;
    CheckTransfers;
  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.
