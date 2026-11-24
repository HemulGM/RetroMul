program PS2HLEChangedRowsTest;

// PS2HLEChangedRows against per-band expectations: changed, unchanged,
// alternating and tail bands, run limits, VRAM wrap and forced reload masks.

{$APPTYPE CONSOLE}
{$POINTERMATH ON}

uses
  System.SysUtils, PS2.Types, PS2.GS.Memory, PS2.GS.VulkanHLE;

procedure Check;
const
  Bases: array[0..3] of Cardinal = (0, 4096, $300000, PS2GSMemorySize - 128);
  Strides: array[0..5] of Integer = (256, 512, 1024, 2048, 4096, 8192);
begin
  var Memory := TPS2GSMemory.Create;
  var Cases := 0;
  try
    for var At := 0 to PS2GSMemorySize - 1 do
      Memory.Data[At] := Byte((At xor (At shr 7) xor (At shr 16)) and $FF);
    for var Base in Bases do
      for var RowBytes in Strides do
        for var PageRows in [32, 64] do
          for var Pages in [1, 2, 3, 7, 14] do
            for var Tail in [0, 16] do
            begin
              var Height := Pages * PageRows - Tail;
              var Bytes := Pages * PageRows * RowBytes;
              if Bytes > PS2GSMemorySize then
                Continue;
              for var Pattern := 0 to 7 do
              begin
                var Shadow: TBytes;
                SetLength(Shadow, Bytes);
                for var At := 0 to Bytes - 1 do
                  Shadow[At] := Memory.Data[(Base + Cardinal(At)) and (PS2GSMemorySize - 1)];
                var Changed: array of Boolean;
                SetLength(Changed, Pages);
                for var P := 0 to Pages - 1 do
                begin
                  Changed[P] := (Pattern = 1) or ((Pattern = 2) and (P = 0)) or
                    ((Pattern = 3) and (P = Pages - 1)) or
                    ((Pattern = 4) and Odd(P)) or ((Pattern = 5) and not Odd(P)) or
                    ((Pattern = 6) and (P mod 3 = 1)) or ((Pattern = 7) and (P = Pages div 2));
                  if Changed[P] then
                  begin
                    var At := (Base + Cardinal((P * PageRows + PageRows - 1) * RowBytes + RowBytes - 1)) and
                      (PS2GSMemorySize - 1);
                    Memory.Data[At] := Memory.Data[At] xor $55;
                  end;
                end;
                for var MaxPages in [1, 2, 3, 7] do
                begin
                  var MaxRows := MaxPages * PageRows + 7;
                  var Covered: TArray<Boolean>;
                  SetLength(Covered, Height);
                  FillChar(Covered[0], Height, 0);
                  var Y := 0;
                  while Y < Height do
                  begin
                    var Before := Y;
                    var N := PS2HLEChangedRows(Memory, Base, Cardinal(RowBytes), Height,
                      PageRows, MaxRows, Shadow, Y);
                    if (Y < Before) or (N < 0) or (N > MaxRows) or (Y + N > Height) or
                      ((Y < Height) and (N = 0)) then
                      raise Exception.Create('Invalid changed-row span');
                    for var Row := Y to Y + N - 1 do
                      Covered[Row] := True;
                    Inc(Y, N);
                  end;
                  for var Row := 0 to Height - 1 do
                    if Covered[Row] <> Changed[Row div PageRows] then
                      raise Exception.CreateFmt('Changed-row coverage mismatch base=%x stride=%d page=%d height=%d pattern=%d row=%d',
                        [Base, RowBytes, PageRows, Height, Pattern, Row]);
                  Inc(Cases);
                end;
              end;
            end;
    Writeln(Cases, ' page-row spans, unchanged/alternating/tail bands and VRAM wrap: OK');
    Memory.Clear;
    var Shadow: TBytes;
    SetLength(Shadow, 2048 * 256);
    FillChar(Shadow[0], Length(Shadow), 0);
    var ForcedCases := 0;
    for var PageRows in [32, 64] do
      for var MaxPages in [1, 3] do
        for var Bit := 0 to 65 do
        begin
          var Mask: UInt64 := 0;
          if Bit = 65 then
            Mask := High(UInt64)
          else if Bit > 0 then
            Mask := UInt64(1) shl (Bit - 1);
          var Y := 0;
          var Covered: UInt64 := 0;
          while Y < 2048 do
          begin
            var N := PS2HLEChangedRows(Memory, PS2GSMemorySize - 256, 256, 2048,
              PageRows, PageRows * MaxPages, Shadow, Y, Mask);
            if (N = 0) and (Y < 2048) then
              raise Exception.Create('Forced row span made no progress');
            for var Row := Y to Y + N - 1 do
              Covered := Covered or (UInt64(1) shl (Row div PageRows));
            Inc(Y, N);
          end;
          var Expected := Mask;
          if PageRows = 64 then
            Expected := Expected and $FFFFFFFF;
          if Covered <> Expected then
            raise Exception.Create('Forced non-canonical depth bands were skipped');
          Inc(ForcedCases);
        end;
    Writeln(ForcedCases, ' forced depth-normalization spans including bit 63: OK');
  finally
    Memory.Free;
  end;
end;

begin
  try
    Check;
  except
    on E: Exception do
    begin
      Writeln('FAIL: ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
