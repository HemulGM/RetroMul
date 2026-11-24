program PS2HLEDepthRowTest;

{$APPTYPE CONSOLE}
{$POINTERMATH ON}

uses
  System.SysUtils, System.Math, PS2.Types, PS2.GS.Memory, PS2.GS.VulkanHLE;

function RangeOf(Format: Cardinal): Double;
begin
  case Format of
    PSMZ24:
      Result := 16777216.0;
    PSMZ16, PSMZ16S:
      Result := 65536.0;
  else
    Result := 4294967296.0;
  end;
end;

procedure Reference(Memory: TPS2GSMemory; const A: TPS2GSAddressing; Format: Cardinal;
  Y, X, Count: Integer; D24: Boolean; Target: PCardinal);
begin
  var RB := A.RowBase(Cardinal(Y));
  var RO := A.RowOffsets(Cardinal(Y));
  var Range: Double := RangeOf(Format);
  for var I := 0 to Count - 1 do
  begin
    var F: Double := Memory.ReadAt(Integer(Format), A.InRow(RB, RO, Cardinal(X + I))) / Range;
    if D24 then
      Target[I] := Min(Cardinal(Round(F * 16777215)), 16777215)
    else
      PSingle(@Target[I])^ := F;
  end;
end;

procedure Run;
const
  Bases: array[0..3] of Cardinal = (0, 1, $3FF0, $3FFF);
  Widths: array[0..2] of Cardinal = (1, 8, 31);
  Rows: array[0..5] of Integer = (0, 31, 32, 63, 64, 895);
  Starts: array[0..4] of Integer = (0, 1, 63, 64, 511);
  Counts: array[0..6] of Integer = (0, 1, 2, 3, 63, 65, 512);
begin
  var SavedRound := GetRoundMode;
  var Memory := TPS2GSMemory.Create;
  var Other := TPS2GSMemory.Create;
  try
    var Words := PCardinal(Memory.Data);
    for var I := 0 to PS2GSMemorySize div 4 - 1 do
      Words[I] := Cardinal((UInt64(Cardinal(I)) * $9E3779B9) and $FFFFFFFF) xor $A37C195B;
    var Seed: TBytes;
    SetLength(Seed, PS2GSMemorySize);
    Move(Memory.Data^, Seed[0], Length(Seed));
    var A: TPS2GSAddressing;
    var Expected, Actual: array[0..513] of Cardinal;
    var Checks := 0;
    for var Mode := Low(TRoundingMode) to High(TRoundingMode) do
    begin
      SetRoundMode(Mode);
      for var Format in [PSMZ32, PSMZ24, PSMZ16, PSMZ16S] do
        for var D24 in [False, True] do
          for var BP in Bases do
            for var BW in Widths do
            begin
              A.Init(Format, BP, BW);
              for var Y in Rows do
                for var X in Starts do
                  for var Count in Counts do
                  begin
                    FillChar(Expected, SizeOf(Expected), $A5);
                    FillChar(Actual, SizeOf(Actual), $A5);
                    Reference(Memory, A, Format, Y, X, Count, D24, @Expected[1]);
                    PS2HLELoadDepthRow(Memory, A, Format, Y, X, Count, D24, @Actual[1]);
                    if not CompareMem(@Expected[0], @Actual[0], SizeOf(Expected)) then
                      raise Exception.CreateFmt('Depth row mode=%d format=%x d24=%d base=%x width=%d y=%d x=%d count=%d',
                        [Ord(Mode), Format, Ord(D24), BP, BW, Y, X, Count]);
                    Inc(Checks);
                  end;
            end;
    end;
    if not CompareMem(Memory.Data, @Seed[0], Length(Seed)) then
      raise Exception.Create('Depth upload changed source VRAM');
    // Every 16-bit depth value, including normalization and D24 rounding edges.
    for var Mode := Low(TRoundingMode) to High(TRoundingMode) do
    begin
      SetRoundMode(Mode);
      for var Format in [PSMZ16, PSMZ16S] do
      begin
        A.Init(Format, 0, 8);
        for var Block := 0 to 127 do
        begin
          for var X := 0 to 511 do
            Memory.WriteAt(Format, A.Addr(Cardinal(X), 0), Cardinal(Block * 512 + X));
          for var D24 in [False, True] do
          begin
            Reference(Memory, A, Format, 0, 0, 512, D24, @Expected[0]);
            PS2HLELoadDepthRow(Memory, A, Format, 0, 0, 512, D24, @Actual[0]);
            if not CompareMem(@Expected[0], @Actual[0], 512 * 4) then
              raise Exception.Create('Exhaustive 16-bit depth conversion mismatch');
            Inc(Checks);
          end;
        end;
      end;
    end;
    // Unsigned conversion and Single rounding near every binary exponent edge.
    for var Mode := Low(TRoundingMode) to High(TRoundingMode) do
    begin
      SetRoundMode(Mode);
      for var Format in [PSMZ32, PSMZ24] do
      begin
        A.Init(Format, 0, 8);
        for var Exponent := 0 to 32 do
          for var Block := 0 to 1 do
          begin
            for var X := 0 to 511 do
            begin
              var Value: Int64 := (Int64(1) shl Exponent) + Block * 512 + X - 512;
              Value := EnsureRange(Value, Int64(0), Int64($FFFFFFFF));
              Memory.WriteAt(Format, A.Addr(Cardinal(X), 0), Cardinal(Value));
            end;
            Reference(Memory, A, Format, 0, 0, 512, False, @Expected[0]);
            PS2HLELoadDepthRow(Memory, A, Format, 0, 0, 512, False, @Actual[0]);
            if not CompareMem(@Expected[0], @Actual[0], 512 * 4) then
              raise Exception.Create('Depth conversion exponent-edge mismatch');
            Inc(Checks);
          end;
      end;
    end;
    // Preserve scalar read/write ordering for a synthetic aliased target.
    for var Mode := Low(TRoundingMode) to High(TRoundingMode) do
    begin
      SetRoundMode(Mode);
      for var Format in [PSMZ32, PSMZ24, PSMZ16, PSMZ16S] do
        for var D24 in [False, True] do
          for var Offset in [0, 4, 12] do
          begin
            Move(Seed[0], Memory.Data^, Length(Seed));
            Move(Seed[0], Other.Data^, Length(Seed));
            A.Init(Format, 0, 1);
            Reference(Memory, A, Format, 0, 0, 65, D24, PCardinal(Memory.Data + Offset));
            PS2HLELoadDepthRow(Other, A, Format, 0, 0, 65, D24, PCardinal(Other.Data + Offset));
            if not CompareMem(Memory.Data, Other.Data, PS2GSMemorySize) then
              raise Exception.Create('Aliased depth conversion order changed');
            Inc(Checks);
          end;
    end;
    {$IF DEFINED(CPUX64) AND DEFINED(MSWINDOWS)}
    // Pixel zero is written before pixel one's unmasked precision exception.
    var SavedControl := GetMXCSR;
    try
      SetRoundMode(rmNearest);
      A.Init(PSMZ32, 0, 1);
      Memory.WriteAt(PSMZ32, A.Addr(0, 0), 0);
      Memory.WriteAt(PSMZ32, A.Addr(1, 0), $80000001);
      FillChar(Expected, SizeOf(Expected), $A5);
      FillChar(Actual, SizeOf(Actual), $A5);
      var ReferenceTrapped := False;
      var ActualTrapped := False;
      try
        SetMXCSR((GetMXCSR and not Cardinal($103F)));
        Reference(Memory, A, PSMZ32, 0, 0, 2, False, @Expected[0]);
      except
        on E: Exception do
        begin
          SetMXCSR(SavedControl);
          ReferenceTrapped := True;
        end;
      end;
      SetMXCSR(SavedControl);
      SetRoundMode(rmNearest);
      try
        SetMXCSR((GetMXCSR and not Cardinal($103F)));
        PS2HLELoadDepthRow(Memory, A, PSMZ32, 0, 0, 2, False, @Actual[0]);
      except
        on E: Exception do
        begin
          SetMXCSR(SavedControl);
          ActualTrapped := True;
        end;
      end;
      SetMXCSR(SavedControl);
      if not ReferenceTrapped or not ActualTrapped or (Expected[0] <> 0) or
        (Expected[1] <> $A5A5A5A5) or not CompareMem(@Expected[0], @Actual[0], SizeOf(Expected)) then
        raise Exception.Create('Depth conversion precision-trap write order changed');
      Inc(Checks);
    finally
      SetMXCSR(SavedControl);
    end;
    {$ENDIF}
    Writeln('HLE depth rows: ', Checks, ' rounding/formats/wrap/bounds/exhaustive/alias/trap cases: OK');
  finally
    SetRoundMode(SavedRound);
    Other.Free;
    Memory.Free;
  end;
end;

begin
  try
    Run;
  except
    on E: Exception do
    begin
      Writeln('FAIL: ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
