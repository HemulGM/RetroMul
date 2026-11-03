program PS2HLETransferTest;

// Pure CPU comparisons with the former renderer loops; no Vulkan device.
{$APPTYPE CONSOLE}
{$POINTERMATH ON}

uses
  System.SysUtils, System.Diagnostics, PS2.Types,
  PS2.GS.Memory, PS2.GS.VulkanHLE;

type
  TRow = array[0..2055] of Cardinal;

var
  Seed: Cardinal = $5978AC31;

function Next: Cardinal;
begin
  Seed := Seed xor (Seed shl 13);
  Seed := Seed xor (Seed shr 17);
  Seed := Seed xor (Seed shl 5);
  Result := Seed;
end;

procedure LoadReference(Memory: TPS2GSMemory; const A: TPS2GSAddressing;
  Format: Cardinal; Y, X, Count: Integer; Target: PCardinal);
begin
  var RB := A.RowBase(Cardinal(Y));
  var RO := A.RowOffsets(Cardinal(Y));
  var Words := PCardinal(Memory.Data);
  var Halves := PWord(Memory.Data);
  case Format of
    PSMCT32, PSMZ32:
      for var Col := X to X + Count - 1 do
      begin
        Target^ := Words[A.InRow(RB, RO, Cardinal(Col))];
        Inc(Target);
      end;
    PSMCT24, PSMZ24:
      for var Col := X to X + Count - 1 do
      begin
        Target^ := (Words[A.InRow(RB, RO, Cardinal(Col))] and $FFFFFF) or $80000000;
        Inc(Target);
      end;
  else
    for var Col := X to X + Count - 1 do
    begin
      var V: Cardinal := Halves[A.InRow(RB, RO, Cardinal(Col))];
      var C := ((V and $1F) shl 3) or (((V shr 5) and $1F) shl 11) or (((V shr 10) and $1F) shl 19);
      if (V and $8000) <> 0 then C := C or $FF000000;
      Target^ := C;
      Inc(Target);
    end;
  end;
end;

procedure StoreReference(Memory: TPS2GSMemory; const A: TPS2GSAddressing;
  Format: Cardinal; Y, X, Count: Integer; Source: PCardinal);
begin
  var RB := A.RowBase(Cardinal(Y));
  var RO := A.RowOffsets(Cardinal(Y));
  var Words := PCardinal(Memory.Data);
  var Halves := PWord(Memory.Data);
  case Format of
    PSMCT32, PSMZ32:
      for var Col := X to X + Count - 1 do
      begin
        Words[A.InRow(RB, RO, Cardinal(Col))] := Source^;
        Inc(Source);
      end;
    PSMCT24, PSMZ24:
      for var Col := X to X + Count - 1 do
      begin
        var At := A.InRow(RB, RO, Cardinal(Col));
        Words[At] := (Words[At] and $FF000000) or (Source^ and $FFFFFF);
        Inc(Source);
      end;
  else
    for var Col := X to X + Count - 1 do
    begin
      Halves[A.InRow(RB, RO, Cardinal(Col))] := Word(Color32To16(Source^));
      Inc(Source);
    end;
  end;
end;

procedure CheckPairs;
var
  A: TPS2GSAddressing;
begin
  var Cases: Int64 := 0;
  // Every base alignment and page-local swizzle. Width/pages add multiples
  // of 2048 words, so they cannot split an even-x word pair. Also test wraps
  // at all x/y page boundaries with a near-end base and all GS widths.
  for var PSM in [PSMCT32, PSMCT24, PSMZ32, PSMZ24] do
  begin
    for var BP := 0 to $3FFF do
    begin
      A.Init(PSM, BP, 1);
      for var Y := 0 to 31 do
        for var X := 0 to 31 do
        begin
          var At := A.Addr(Cardinal(X * 2), Cardinal(Y));
          if ((At and 1) <> 0) or (A.Addr(Cardinal(X * 2 + 1), Cardinal(Y)) <> At + 1) then
            raise Exception.Create('Even-x word pair is not adjacent');
          Inc(Cases);
        end;
    end;
    for var BW := 0 to 63 do
    begin
      A.Init(PSM, $3FFF, BW);
      for var Y in [0, 31, 32, 63, 64, 255, 2047] do
        for var X := 0 to 1023 do
        begin
          var At := A.Addr(Cardinal(X * 2), Cardinal(Y));
          if ((At and 1) <> 0) or (A.Addr(Cardinal(X * 2 + 1), Cardinal(Y)) <> At + 1) then
            raise Exception.Create('Page/VRAM wrap split a word pair');
          Inc(Cases);
        end;
    end;
  end;
  for var PSM in [PSMCT16, PSMCT16S, PSMZ16, PSMZ16S] do
    for var BP := 0 to $3FFF do
    begin
      A.Init(PSM, BP, 1);
      for var Y := 0 to 63 do
        for var X := 0 to 31 do
        begin
          var At := A.Addr(Cardinal(X * 2), Cardinal(Y));
          if A.Addr(Cardinal(X * 2 + 1), Cardinal(Y)) <> At + 2 then
            raise Exception.Create('Even-x halfword pair is not two halfwords apart');
          Inc(Cases);
        end;
    end;
  Writeln('Even-x color pairs: ', Cases, ' all bases/page swizzles/widths/wrap cases OK');
end;

procedure CheckRows;
const
  Formats: array[0..7] of Cardinal = (PSMCT32, PSMCT24, PSMZ32, PSMZ24,
    PSMCT16, PSMCT16S, PSMZ16, PSMZ16S);
  Starts: array[0..7] of Integer = (0, 1, 0, 1, 63, 64, 511, 2047);
  Counts: array[0..7] of Integer = (0, 1, 2, 2, 3, 65, 513, 1);
var
  A: TPS2GSAddressing;
  Expected, Actual, Source: TRow;
begin
  var M0 := TPS2GSMemory.Create;
  var M1 := TPS2GSMemory.Create;
  try
    for var I := 0 to PS2GSMemorySize div 4 - 1 do PCardinal(M0.Data)[I] := Next;
    var Cases := 0;
    for var PSM in Formats do
      for var BP in TArray<Cardinal>.Create(0, 1, $3F80, $3FFF) do
        for var BW in [0, 1, 8] do
          for var Y in [0, 7, 15, 31, 32, 63, 64, 255] do
            for var Crop := 0 to High(Starts) do
            begin
              A.Init(PSM, BP, BW);
              FillChar(Expected, SizeOf(Expected), $A5);
              Actual := Expected;
              LoadReference(M0, A, PSM, Y, Starts[Crop], Counts[Crop], @Expected[1]);
              PS2HLELoadColorRow(M0, A, PSM, Y, Starts[Crop], Counts[Crop], @Actual[1]);
              if not CompareMem(@Expected, @Actual, SizeOf(Expected)) then
                raise Exception.CreateFmt('Color load mismatch psm=%x bp=%x bw=%d y=%d crop=%d', [PSM, BP, BW, Y, Crop]);
              for var I := 0 to High(Source) do Source[I] := Next;
              Move(M0.Data^, M1.Data^, PS2GSMemorySize);
              StoreReference(M0, A, PSM, Y, Starts[Crop], Counts[Crop], @Source[1]);
              PS2HLEStoreColorRow(M1, A, PSM, Y, Starts[Crop], Counts[Crop], @Source[1]);
              if not CompareMem(M0.Data, M1.Data, PS2GSMemorySize) then
                raise Exception.CreateFmt('Color store mismatch psm=%x bp=%x bw=%d y=%d crop=%d', [PSM, BP, BW, Y, Crop]);
              Inc(Cases);
            end;
    for var I := 0 to 999 do
    begin
      var PSM := Formats[Next mod Length(Formats)];
      A.Init(PSM, Next and $3FFF, Next and 63);
      var X := Integer(Next and 2047);
      var Y := Integer(Next and 2047);
      var N := Integer(Next mod 2049);
      FillChar(Expected, SizeOf(Expected), $39);
      Actual := Expected;
      LoadReference(M0, A, PSM, Y, X, N, @Expected[1]);
      PS2HLELoadColorRow(M0, A, PSM, Y, X, N, @Actual[1]);
      if not CompareMem(@Expected, @Actual, SizeOf(Expected)) then raise Exception.Create('Random row load mismatch');
      Move(M0.Data^, M1.Data^, PS2GSMemorySize);
      StoreReference(M0, A, PSM, Y, X, N, @Source[1]);
      PS2HLEStoreColorRow(M1, A, PSM, Y, X, N, @Source[1]);
      if not CompareMem(M0.Data, M1.Data, PS2GSMemorySize) then raise Exception.Create('Random row store mismatch');
      Inc(Cases);
    end;
    for var PSM in Formats do
      for var X in [0, 1, 63, 64, 511] do
        for var Delta := -2 to 2 do
        begin
          A.Init(PSM, 1, 8);
          var Bytes := 4;
          if PSM in [PSMCT16, PSMCT16S, PSMZ16, PSMZ16S] then Bytes := 2;
          var Offset := Integer(A.Addr(Cardinal(X), 31)) * Bytes + Delta * 4;
          Move(M0.Data^, M1.Data^, PS2GSMemorySize);
          LoadReference(M0, A, PSM, 31, X, 129, PCardinal(M0.Data + Offset));
          PS2HLELoadColorRow(M1, A, PSM, 31, X, 129, PCardinal(M1.Data + Offset));
          if not CompareMem(M0.Data, M1.Data, PS2GSMemorySize) then raise Exception.Create('Aliased row load reordered');
          StoreReference(M0, A, PSM, 31, X, 129, PCardinal(M0.Data + Offset));
          PS2HLEStoreColorRow(M1, A, PSM, 31, X, 129, PCardinal(M1.Data + Offset));
          if not CompareMem(M0.Data, M1.Data, PS2GSMemorySize) then raise Exception.Create('Aliased row store reordered');
          Inc(Cases);
        end;
    Writeln('Color rows: ', Cases, ' formats/crops/pages/wrap/alpha/alias cases OK');
  finally
    M0.Free;
    M1.Free;
  end;
end;

procedure Benchmark;
var
  A: TPS2GSAddressing;
  Row: TRow;
begin
  var Memory := TPS2GSMemory.Create;
  try
    FillChar(Row, SizeOf(Row), $97);
    for var PSM in [PSMCT32, PSMCT24, PSMCT16] do
    begin
      A.Init(PSM, 0, 8);
      for var Store := 0 to 1 do
      begin
        for var Trial := 0 to 3 do
          for var Pass := 0 to 1 do
          begin
            var Optimized := (Pass xor (Trial and 1)) <> 0;
            var Watch := TStopwatch.StartNew;
            for var Repeat_ := 0 to 1999 do
              for var Y := 0 to 255 do
                if Store <> 0 then
                begin
                  if Optimized then PS2HLEStoreColorRow(Memory, A, PSM, Y, 0, 512, @Row)
                  else StoreReference(Memory, A, PSM, Y, 0, 512, @Row);
                end
                else if Optimized then PS2HLELoadColorRow(Memory, A, PSM, Y, 0, 512, @Row)
                else LoadReference(Memory, A, PSM, Y, 0, 512, @Row);
            Writeln('row psm=', PSM, ' store=', Store, ' optimized=', Optimized,
              ' ms=', Watch.Elapsed.TotalMilliseconds:0:2);
          end;
      end;
    end;
  finally
    Memory.Free;
  end;
end;

begin
  try
    if FindCmdLineSwitch('bench') then Benchmark
    else
    begin
      CheckPairs;
      CheckRows;
    end;
  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
