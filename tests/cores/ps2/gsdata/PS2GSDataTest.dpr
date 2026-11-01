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

const
  AsyncText: array[Boolean] of string = ('', ', async');

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

// (Async: the raster drawing on its own thread; the display waits only for
// what writes its pages.)
procedure CheckDisplay(Async: Boolean);
begin
  var GS := TPS2GS.Create;
  try
    GS.Raster.Threads := 4;
    GS.Raster.Async := Async;
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
    Writeln('52 display scans: formats, both circuits, offsets/wrap, zero stride, queued draws', AsyncText[Async], ': OK');
  finally
    GS.Free;
  end;
end;

function ReferenceFrame(GS: TPS2GS): TArray<Cardinal>;
type
  TCircuit = record
    FB: UInt64;
    W, H, X, Y, Mag: Integer;
  end;
var
  C: array[0..1] of TCircuit;

  function Pixel(Memory: TPS2GSMemory; Index, X, Y: Integer): Cardinal;
  begin
    var FB := C[Index].FB;
    Result := Memory.ReadPixel(Integer((FB shr 15) and $1F), Cardinal(FB and $1FF) * 2048,
      Cardinal((FB shr 9) and $3F) * 64, Integer((FB shr 32) and $7FF) + X,
      Integer((FB shr 43) and $7FF) + Y);
  end;

begin
  var En1 := GS.PMODE and 1 <> 0;
  var En2 := GS.PMODE and 2 <> 0;
  if not En1 and not En2 then
  begin
    SetLength(Result, Length(GS.Frame));
    Exit;
  end;
  for var I := 0 to 1 do
  begin
    C[I] := Default(TCircuit);
    C[I].Mag := 1;
    if GS.PMODE and (UInt64(1) shl I) = 0 then Continue;
    var Display := GS.DISPLAY1;
    C[I].FB := GS.DISPFB1;
    if I = 1 then begin Display := GS.DISPLAY2; C[I].FB := GS.DISPFB2; end;
    C[I].Mag := Integer((Display shr 23) and 15) + 1;
    C[I].W := EnsureRange((Integer((Display shr 32) and $FFF) + 1) div C[I].Mag, 1, 1024);
    C[I].H := EnsureRange((Integer((Display shr 44) and $7FF) + 1) div
      (Integer((Display shr 27) and 3) + 1), 1, 1024);
    if GS.Interlaced and (GS.SMODE2 and 3 = 3) then C[I].H := C[I].H div 2;
    C[I].X := Integer(Display and $FFF) div C[I].Mag;
    C[I].Y := Integer((Display shr 12) and $7FF);
  end;
  var W := Max(C[0].W, C[1].W);
  var H := Max(C[0].H, C[1].H);
  if (GS.FrameWidth <> W) or (GS.FrameHeight <> H) then raise Exception.Create('Composition dimensions');
  if En1 and En2 then
  begin
    var X := Min(C[0].X, C[1].X);
    var Y := Min(C[0].Y, C[1].Y);
    for var I := 0 to 1 do begin Dec(C[I].X, X); Dec(C[I].Y, Y); end;
  end
  else
    for var I := 0 to 1 do begin C[I].X := 0; C[I].Y := 0; end;
  SetLength(Result, W * H);
  var Memory := GS.Raster.Memory;
  var BG := Cardinal(GS.BGCOLOR and $FFFFFF);
  BG := $FF000000 or ((BG and $FF) shl 16) or (BG and $FF00) or ((BG shr 16) and $FF);
  for var Y := 0 to H - 1 do
    for var X := 0 to W - 1 do
    begin
      var Back := BG;
      var SX := X - C[1].X;
      var SY := Y - C[1].Y;
      if En2 and (GS.PMODE and $80 = 0) and (SX >= 0) and (SY >= 0) and
        (SX < C[1].W) and (SY < C[1].H) then Back := Pixel(Memory, 1, SX, SY);
      var Color := Back;
      SX := X - C[0].X;
      SY := Y - C[0].Y;
      if En1 and (SX >= 0) and (SY >= 0) and (SX < C[0].W) and (SY < C[0].H) then
      begin
        var Front := Pixel(Memory, 0, SX, SY);
        var A := Integer((GS.PMODE shr 8) and $FF);
        if GS.PMODE and $20 = 0 then A := Integer(Front shr 24);
        if A >= 128 then Color := Front
        else
        begin
          Color := 0;
          for var Channel := 0 to 2 do
          begin
            var Shift := Channel * 8;
            var V := (Integer((Front shr Shift) and $FF) * A +
              Integer((Back shr Shift) and $FF) * (128 - A)) shr 7;
            Color := Color or (Cardinal(V) shl Shift);
          end;
        end;
      end;
      Result[Y * W + X] := $FF000000 or ((Color and $FF) shl 16) or
        (Color and $FF00) or ((Color shr 16) and $FF);
    end;
end;

procedure CheckComposition(Async: Boolean);
const
  Colors: array[0..4] of Integer = (PSMCT32, PSMCT24, PSMCT16, PSMCT16S, $1F);
  Alphas: array[0..5] of Integer = (0, 1, 127, 128, 129, 255);

  function Display(W, H, X, Y, MH, MV: Integer): UInt64;
  begin
    Result := UInt64(X) or (UInt64(Y) shl 12) or (UInt64(MH - 1) shl 23) or
      (UInt64(MV - 1) shl 27) or (UInt64(W * MH - 1) shl 32) or (UInt64(H * MV - 1) shl 44);
  end;

begin
  var GS := TPS2GS.Create;
  try
    GS.Raster.Threads := 4;
    GS.Raster.Async := Async;
    var Memory := GS.Raster.Memory;
    for var N := 0 to 511 do
    begin
      GS.Reset;
      var P := PCardinal(Memory.Data);
      for var I := 0 to PS2GSMemorySize div 4 - 1 do P[I] := Cardinal(I) * 1664525 + Cardinal(N) * 1013904223;
      QueueDraw(GS.Raster);
      GS.PMODE := UInt64(N and 3) or (UInt64((N shr 2) and 1) shl 5) or
        (UInt64((N shr 3) and 1) shl 7) or (UInt64(Alphas[(N shr 4) mod Length(Alphas)]) shl 8);
      GS.BGCOLOR := $2468AC;
      GS.Interlaced := N and 64 <> 0;
      GS.SMODE2 := UInt64(N shr 7) and 3;
      var W1 := 39 + (N and 31);
      var H1 := 17 + ((N shr 3) and 15);
      var W2 := W1;
      var H2 := H1;
      if N and 32 <> 0 then begin Inc(W2, 7); Dec(H2, 5); end;
      GS.DISPLAY1 := Display(W1, H1, 36 + N mod 5, 29, 1 + N mod 3, 1 + N mod 2);
      GS.DISPLAY2 := Display(W2, H2, 31 + N mod 7, 27 + N mod 5, 1 + N mod 4, 1 + N mod 3);
      GS.DISPFB1 := UInt64((N * 508) and $1FF) or (UInt64(N mod 5) shl 9) or
        (UInt64(Colors[N mod Length(Colors)]) shl 15) or
        (UInt64((N * 681) and $7FF) shl 32) or (UInt64((N * 677) and $7FF) shl 43);
      GS.DISPFB2 := GS.DISPFB1;
      if N and 16 <> 0 then GS.DISPFB2 := GS.DISPFB1 xor 3 xor (UInt64(1) shl 43);
      GS.BuildFrame;
      var Expected := ReferenceFrame(GS);
      if (Length(Expected) <> Length(GS.Frame)) or
        ((Length(Expected) > 0) and not CompareMem(@Expected[0], @GS.Frame[0], Length(Expected) * 4)) then
        raise Exception.CreateFmt('Dual-circuit composition mismatch case=%d', [N]);
    end;
    Writeln('512 scalar dual-circuit comparisons: shared/distinct surfaces, offsets, magnification, alpha and background', AsyncText[Async], ': OK');
  finally
    GS.Free;
  end;
end;

procedure CheckDisplayRows;
const
  Xs: array[0..9] of Integer = (-3, -1, 0, 1, 63, 64, 127, 2047, 2048, 3070);
  Counts: array[0..7] of Integer = (0, 1, 3, 63, 64, 65, 129, 1031);
  Sentinel = Cardinal($DA1937C5);
var
  Actual: array[0..1032] of Cardinal;
begin
  var Memory := TPS2GSMemory.Create;
  try
    var P := PCardinal(Memory.Data);
    for var I := 0 to PS2GSMemorySize div 4 - 1 do P[I] := Cardinal(I) * 1664525 + 1013904223;
    for var Format in Formats do
      for var N := 0 to 127 do
      begin
        var FBP := Cardinal((N * 2093) and $FFFFF);
        var FBW := Cardinal((N mod 7) * 64 + (N and 31));
        var X := Xs[N mod Length(Xs)];
        var Y := N * 17 - 3;
        var Count := Counts[N mod Length(Counts)];
        for var K := 0 to High(Actual) do Actual[K] := Sentinel;
        Memory.ReadDisplayRow(Format, FBP, FBW, X, Y, @Actual[1], Count);
        Memory.ReadDisplayRow(Format, FBP, FBW, X, Y, nil, 0);
        for var K := 0 to Count - 1 do
          if Actual[K + 1] <> Memory.ReadPixel(Format, FBP, FBW, X + K, Y) then
            raise Exception.CreateFmt('Display row mismatch format=%x case=%d pixel=%d', [Format, N, K]);
        if (Actual[0] <> Sentinel) or (Actual[Count + 1] <> Sentinel) then
          raise Exception.CreateFmt('Display row overrun format=%x case=%d', [Format, N]);
      end;
    Writeln('1664 scalar/display-row comparisons: colour/depth formats, negative/large coordinates, strides and VRAM wrap: OK');
  finally
    Memory.Free;
  end;
end;

procedure CheckRows;
const
  Xs: array[0..5] of Cardinal = (0, 1, 15, 127, 128, 2047);
  Counts: array[0..3] of Integer = (1, 17, 129, 2053);
var
  Values: array[0..2052] of Cardinal;
begin
  var A := TPS2GSMemory.Create;
  var B := TPS2GSMemory.Create;
  try
    var P := PCardinal(A.Data);
    for var I := 0 to PS2GSMemorySize div 4 - 1 do P[I] := Cardinal(I) * 1664525 + 1013904223;
    Move(A.Data^, B.Data^, PS2GSMemorySize);
    for var Format in TArray<Integer>.Create(PSMT8, PSMT4) do
      for var N := 0 to 127 do
      begin
        var BP := Cardinal(1 + N * 127);
        if N and 1 <> 0 then BP := $3FFF;
        var BW := Cardinal(N mod 5);
        var X := Xs[N mod Length(Xs)];
        var Y := Cardinal(N * 17) and $7FF;
        var Count := Counts[N mod Length(Counts)];
        for var K := 0 to Count - 1 do Values[K] := Cardinal(K) * 1664525 + Cardinal(N) * 1013904223;
        for var K := 0 to Count - 1 do A.WriteRaw(Format, BP, BW, (X + Cardinal(K)) and $7FF, Y, Values[K]);
        B.WriteRow(Format, BP, BW, X, Y, @Values[0], Count);
        B.WriteRow(Format, BP, BW, X, Y, nil, 0);
        if not CompareMem(A.Data, B.Data, PS2GSMemorySize) then
          raise Exception.CreateFmt('Indexed row mismatch format=%x case=%d', [Format, N]);
      end;
    Writeln('256 indexed rows: every row phase, page/coordinate/VRAM wrap and masked nibble neighbours: OK');
  finally
    A.Free; B.Free;
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
        // (Cases 2, 3, 6, 7: drawing on B's own thread.)
        B.Async := N and 2 <> 0;
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
        if N and 1 <> 0 then
          for var R in TArray<TPS2GSRaster>.Create(A, B) do
            R.WriteRegister(GSRegHWREG, $FEDCBA9876543210); // Half-quad prefix crosses a run inside IMAGE.
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

// Software sprites sampling one texture level take their texels' addresses
// from column and row parts (SpriteTexels): the same pixels as the general
// sampler, for every texture format, clamp mode, filter and LOD setting.
procedure CheckSpriteTexels;
type
  TWrite = record
    Reg: Integer;
    Value: UInt64;
  end;
begin
  var A := TPS2GSRaster.Create;
  var B := TPS2GSRaster.Create;
  try
    RandSeed := 6151;
    for var N := 0 to 799 do
    begin
      A.Reset; B.Reset;
      var PA := PCardinal(A.Memory.Data);
      for var K := 0 to PS2GSMemorySize div 4 - 1 do PA[K] := Cardinal(K) * 2654435761 + Cardinal(N) * 40503;
      Move(PA^, B.Memory.Data^, PS2GSMemorySize);
      var Writes: TArray<TWrite>;
      var Add := procedure(Reg: Integer; Value: UInt64)
        begin
          SetLength(Writes, Length(Writes) + 1);
          Writes[High(Writes)].Reg := Reg;
          Writes[High(Writes)].Value := Value;
        end;
      var FPSM: UInt64 := Formats[Random(4)];
      Add(GSRegFRAME_1, UInt64(4 + Random(5)) shl 16 or (FPSM shl 24) or (UInt64(Random(2) * Random(MaxInt)) shl 32));
      Add(GSRegZBUF_1, 256 or (UInt64(Random(3)) shl 24) or (UInt64(Random(2)) shl 32));
      Add(GSRegTEST_1, UInt64(Random(2)) or (UInt64(Random(8)) shl 1) or (UInt64(Random(256)) shl 4) or
        (UInt64(Random(4)) shl 12) or (UInt64(Random(2)) shl 14) or (UInt64(Random(2)) shl 15) or $10000 or
        (UInt64(Random(4)) shl 17));
      Add(GSRegALPHA_1, UInt64(Random(256)) or (UInt64(Random(256)) shl 32));
      Add(GSRegPABE, Random(2));
      Add(GSRegFBA_1, Random(2));
      Add(GSRegCOLCLAMP, Random(2));
      Add(GSRegFOGCOL, Random($1000000));
      Add(GSRegTEXA, UInt64(Random(256)) or (UInt64(Random(2)) shl 15) or (UInt64(Random(256)) shl 32));
      Add(GSRegSCISSOR_1, UInt64(Random(32)) or (UInt64(200 + Random(56)) shl 16) or (UInt64(Random(32)) shl 32) or
        (UInt64(200 + Random(56)) shl 48));
      // The texture past the frame and depth (blocks 4096 on), its CLUT
      // loaded with it; mipmap levels anywhere.
      var TPSM := UInt64(Formats[Random(13)]);
      Add(GSRegTEX0_1, UInt64(4096 + Random(4096)) or (UInt64(1 + Random(10)) shl 14) or (TPSM shl 20) or
        (UInt64(Random(11)) shl 26) or (UInt64(Random(11)) shl 30) or (UInt64(Random(2)) shl 34) or
        (UInt64(Random(4)) shl 35) or (UInt64(8192 + Random(8000)) shl 37) or (UInt64(Random(2) * 2) shl 51) or
        (UInt64(Random(2)) shl 55) or (UInt64(Random(32)) shl 56) or (UInt64(1) shl 61));
      Add(GSRegTEXCLUT, Random($400000));
      Add(GSRegTEX1_1, UInt64(Random(2)) or (UInt64(Random(7)) shl 2) or (UInt64(Random(2)) shl 5) or
        (UInt64(Random(6)) shl 6) or (UInt64(Random(4)) shl 19) or (UInt64(Random(4096)) shl 32));
      Add(GSRegMIPTBP1_1, UInt64(Random(16384)) or (UInt64(Random(8)) shl 14) or (UInt64(Random(16384)) shl 20) or
        (UInt64(Random(8)) shl 34) or (UInt64(Random(16384)) shl 40) or (UInt64(Random(8)) shl 54));
      Add(GSRegMIPTBP2_1, UInt64(Random(16384)) or (UInt64(Random(8)) shl 14) or (UInt64(Random(16384)) shl 20) or
        (UInt64(Random(8)) shl 34) or (UInt64(Random(16384)) shl 40) or (UInt64(Random(8)) shl 54));
      Add(GSRegCLAMP_1, UInt64(Random(4)) or (UInt64(Random(4)) shl 2) or (UInt64(Random(1024)) shl 4) or
        (UInt64(Random(1024)) shl 14) or (UInt64(Random(1024)) shl 24) or (UInt64(Random(1024)) shl 34));
      Add(GSRegPRIM, 6 or $10 or (UInt64(Random(2)) shl 5) or (UInt64(Random(2)) shl 6) or (UInt64(Random(2)) shl 8));
      for var S := 0 to 2 do
        for var K := 0 to 1 do
        begin
          var Q: Single := 0.25 + Random * 3;
          if Random(8) = 0 then Q := -Q;
          var SS: Single := Random * 4 - 1;
          var TT: Single := Random * 4 - 1;
          Add(GSRegRGBAQ, UInt64(Random(MaxInt)) or (UInt64(PCardinal(@Q)^) shl 32));
          Add(GSRegST, UInt64(PCardinal(@SS)^) or (UInt64(PCardinal(@TT)^) shl 32));
          Add(GSRegUV, UInt64(Random($4000)) or (UInt64(Random($4000)) shl 16));
          Add(GSRegFOG, UInt64(Random(256)) shl 56);
          Add(GSRegXYZ2, UInt64(Random(300 * 16)) or (UInt64(Random(300 * 16)) shl 16) or (UInt64(Random(MaxInt)) shl 32));
        end;
      SpriteTexels := True;
      for var W in Writes do A.WriteRegister(W.Reg, W.Value);
      SpriteTexels := False;
      for var W in Writes do B.WriteRegister(W.Reg, W.Value);
      SpriteTexels := True;
      if not CompareMem(A.Memory.Data, B.Memory.Data, PS2GSMemorySize) or (A.PixelsDrawn <> B.PixelsDrawn) then
        raise Exception.CreateFmt('Sprite texels differ, case %d', [N]);
    end;
    Writeln('800 software sprites, all texture formats, clamps, filters and LOD settings: column/row texels OK');
  finally
    A.Free; B.Free;
  end;
end;

begin
  try
    CheckSpriteTexels;
    for var Async := False to True do
    begin
      CheckDisplay(Async);
      CheckComposition(Async);
    end;
    CheckDisplayRows;
    CheckRows;
    CheckTransfers;
  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.
