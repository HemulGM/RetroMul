program PS2VIFReadbackTest;

{$APPTYPE CONSOLE}
{$POINTERMATH ON}

uses
  System.SysUtils, System.Classes, System.Math, Core.Snapshots, PS2.Types,
  PS2.Console, PS2.DMAC, PS2.GS.Memory, PS2.GS.Raster;

var
  CaseName: string;

procedure Check(Condition: Boolean; const Message: string);
begin
  if not Condition then
    raise Exception.Create(CaseName + ': ' + Message);
end;

function PixelBits(PSM: Integer): Integer;
begin
  case PSM of
    PSMCT32, PSMZ32:
      Result := 32;
    PSMCT24, PSMZ24:
      Result := 24;
    PSMCT16, PSMCT16S, PSMZ16, PSMZ16S:
      Result := 16;
    PSMT8, PSMT8H:
      Result := 8;
    PSMT4, PSMT4HL, PSMT4HH:
      Result := 4;
  else
    raise Exception.Create('Unexpected test pixel format');
  end;
end;

function Prepare(C: TPS2Console; PSM: Integer; BP, BW: Cardinal; X, Y, Width, Height: Integer): TBytes;
begin
  var Bits := PixelBits(PSM);
  var Mask := Cardinal((UInt64(1) shl Bits) - 1);
  SetLength(Result, ((Width * Height * Bits + 127) div 128) * 16);
  FillChar(Result[0], Length(Result), 0);
  var Memory := C.GS.Raster.Memory;
  for var I := 0 to Width * Height - 1 do
  begin
    var Value := Cardinal((UInt64(Cardinal(I)) * $9E3779B1 + $7351ABCD) and Mask);
    Memory.WriteRaw(PSM, BP, BW, Cardinal((X + I mod Width) and $7FF),
      Cardinal((Y + I div Width) and $7FF), Value);
    // Pack individual bits independently of the GS word accumulator.
    for var Bit := 0 to Bits - 1 do
      if (Value and (Cardinal(1) shl Bit)) <> 0 then
      begin
        var At := I * Bits + Bit;
        Result[At shr 3] := Result[At shr 3] or Byte(1 shl (At and 7));
      end;
  end;
  C.GS.BUSDIR := 1;
  C.GS.WriteRegister(GSRegBITBLTBUF, BP or (UInt64(BW) shl 16) or (UInt64(PSM) shl 24));
  C.GS.WriteRegister(GSRegTRXPOS, Cardinal(X) or (UInt64(Cardinal(Y)) shl 16));
  C.GS.WriteRegister(GSRegTRXREG, Cardinal(Width) or (UInt64(Cardinal(Height)) shl 32));
  C.GS.WriteRegister(GSRegTRXDIR, 1);
end;

procedure CheckPull(C: TPS2Console; const Expected: TBytes);
const
  Chunks: array[0..4] of Integer = (1, 3, 7, 2, 11);
begin
  var Actual: TBytes;
  SetLength(Actual, Length(Expected) + 11 * 16);
  FillChar(Actual[0], Length(Actual), $A5);
  Check(C.VIF1Port.Pull(DMAVIF1, nil, 0) = 0, 'Zero-length read consumed data');
  var At := 0;
  var Chunk := 0;
  while At < Length(Expected) div 16 do
  begin
    var Requested := Chunks[Chunk mod Length(Chunks)];
    var Taken := C.VIF1Port.Pull(DMAVIF1, @Actual[At * 16], Requested);
    Check(Taken = Min(Requested, Length(Expected) div 16 - At), 'Incorrect partial read count');
    Inc(At, Taken);
    Inc(Chunk);
  end;
  for var I := 0 to High(Expected) do
    if Actual[I] <> Expected[I] then
      Check(False, Format('Readback byte %d: %.2x expected %.2x', [I, Actual[I], Expected[I]]));
  Check(C.VIF1Port.Pull(DMAVIF1, @Actual[Length(Expected)], 1) = 0, 'Empty read fabricated data');
  for var I := Length(Expected) to High(Actual) do
    Check(Actual[I] = $A5, 'Readback overwrote an unreturned quadword');
end;

procedure CheckFormats(C: TPS2Console);
const
  Formats: array[0..12] of Integer = (PSMCT32, PSMCT24, PSMCT16, PSMCT16S,
    PSMT8, PSMT4, PSMT8H, PSMT4HL, PSMT4HH, PSMZ32, PSMZ24, PSMZ16, PSMZ16S);
begin
  for var PSM in Formats do
  begin
    CaseName := Format('Format %.2x small', [PSM]);
    CheckPull(C, Prepare(C, PSM, $100, 2, 3, 2, 5, 3));
    CaseName := Format('Format %.2x wrapped', [PSM]);
    CheckPull(C, Prepare(C, PSM, $3F80, 4, 63, 31, 65, 17));
  end;
  CaseName := 'FFX 2E00';
  CheckPull(C, Prepare(C, PSMCT32, $2E00, 4, 0, 0, 256, 256));
  CaseName := 'FFX 3200';
  CheckPull(C, Prepare(C, PSMCT32, $3200, 4, 0, 0, 256, 256));
end;

procedure CheckDMA(C: TPS2Console);
const
  Destination = $1FF0;
begin
  C.DMAC.Reset;
  var Expected := Prepare(C, PSMCT32, $100, 1, 0, 0, 8, 1);
  FillChar((C.Bus.RAM + Destination - 16)^, 96, $A5);
  var Generation := C.Bus.RAMGenerations[Destination shr 12];
  C.DMAC.Write($E000, 1);
  C.DMAC.Write($9010, Destination);
  C.DMAC.Write($9020, 4);
  C.DMAC.Write($9000, CHCRSTR);
  Check(C.DMAC.Ch[DMAVIF1].MADR = Destination + 32, 'Partial DMA MADR mismatch');
  Check(C.DMAC.Ch[DMAVIF1].QWC = 2, 'Partial DMA QWC mismatch');
  Check(not C.DMAC.Ch[DMAVIF1].Finishing, 'Partial DMA completed early');
  Check(CompareMem(C.Bus.RAM + Destination, @Expected[0], 32), 'DMA payload mismatch');
  Check(C.Bus.RAM[Destination - 1] = $A5, 'DMA wrote before the destination');
  Check(C.Bus.RAM[Destination + 32] = $A5, 'DMA zero-filled missing data');
  Check(C.Bus.RAMGenerations[Destination shr 12] <> Generation, 'DMA did not mark RAM written');
  var EmptyGeneration := C.Bus.RAMGenerations[(Destination + 32) shr 12];
  C.DMAC.Resume(DMAVIF1);
  Check(C.DMAC.Ch[DMAVIF1].QWC = 2, 'An empty retry consumed data');
  Check(C.Bus.RAMGenerations[(Destination + 32) shr 12] = EmptyGeneration, 'An empty DMA invalidated RAM');
  var Tail := Prepare(C, PSMCT32, $180, 1, 0, 0, 8, 1);
  C.DMAC.Resume(DMAVIF1);
  Check(C.DMAC.Ch[DMAVIF1].MADR = Destination + 64, 'Completed DMA MADR mismatch');
  Check(C.DMAC.Ch[DMAVIF1].QWC = 0, 'Completed DMA QWC mismatch');
  Check(CompareMem(C.Bus.RAM + Destination + 32, @Tail[0], 32), 'Resumed DMA payload mismatch');
  Check(C.Bus.RAM[Destination + 64] = $A5, 'DMA wrote past the destination');
  Check(C.DMAC.Moved[DMAVIF1] = 4, 'Reverse DMA bus accounting mismatch');
  Check(C.DMAC.Ch[DMAVIF1].Finishing, 'Reverse DMA did not wait for bus time');
  var DoneAt := C.DMAC.Ch[DMAVIF1].DoneAt;
  C.Scheduler.Now := DoneAt - 1;
  C.DMAC.Event;
  Check((C.DMAC.Ch[DMAVIF1].CHCR and CHCRSTR) <> 0, 'Reverse DMA ended before bus time');
  C.Scheduler.Now := DoneAt;
  C.DMAC.Event;
  Check((C.DMAC.Ch[DMAVIF1].CHCR and CHCRSTR) = 0, 'Reverse DMA did not clear STR');
  Check((C.DMAC.STAT and (1 shl DMAVIF1)) <> 0, 'Reverse DMA did not signal completion');
  C.DMAC.Reset;
  var FirstGeneration := C.Bus.RAMGenerations[0];
  var LastGeneration := C.Bus.RAMGenerations[8191];
  C.DMAC.Write($E000, 1);
  C.DMAC.Write($9010, 0);
  C.DMAC.Write($9020, 1);
  C.DMAC.Write($9000, CHCRSTR);
  Check((C.DMAC.Ch[DMAVIF1].QWC = 1) and (C.DMAC.Ch[DMAVIF1].MADR = 0), 'An empty DMA moved RAM');
  Check((C.Bus.RAMGenerations[0] = FirstGeneration) and (C.Bus.RAMGenerations[8191] = LastGeneration),
    'An empty DMA at address zero invalidated RAM');
  C.DMAC.Reset;
end;

procedure CheckSnapshot(C: TPS2Console);
begin
  var Expected := Prepare(C, PSMCT32, $100, 1, 0, 0, 16, 1);
  var Head: TPS2Reg128;
  Check(C.VIF1Port.Pull(DMAVIF1, @Head, 1) = 1, 'Snapshot prefix read failed');
  var State := TMemoryStream.Create;
  try
    var Archive := TStateArchive.Create(State, False);
    try
      C.SerializeState(Archive);
    finally
      Archive.Free;
    end;
    var First, Second: array[0..2] of TPS2Reg128;
    Check(C.VIF1Port.Pull(DMAVIF1, @First[0], 3) = 3, 'Snapshot first tail read failed');
    State.Position := 0;
    Archive := TStateArchive.Create(State, True);
    try
      C.SerializeState(Archive);
    finally
      Archive.Free;
    end;
    Check(State.Position = State.Size, 'Snapshot did not consume its exact payload');
    Check(C.VIF1Port.Pull(DMAVIF1, @Second[0], 3) = 3, 'Snapshot restored tail read failed');
    Check(CompareMem(@First[0], @Second[0], SizeOf(First)), 'Read cursor did not round-trip');
    Check(CompareMem(@Second[0], @Expected[16], SizeOf(Second)), 'Restored snapshot payload mismatch');
  finally
    State.Free;
  end;
end;

procedure CheckBuffered(C: TPS2Console);
begin
  var Expected := Prepare(C, PSMCT32, $100, 1, 0, 0, 8, 1);
  for var X := 0 to 7 do
    C.GS.Raster.Memory.WriteRaw(PSMCT32, $100, 1, Cardinal(X), 0, 0);
  CheckPull(C, Expected);
  var Value: TPS2Reg128;
  FillChar(Value, SizeOf(Value), $A5);
  Check(C.VIF0Port.Pull(DMAVIF0, @Value, 1) = 0, 'VIF0 accepted reverse DMA');
  for var I := 0 to 15 do
    Check(Value.UB[I] = $A5, 'VIF0 reverse DMA wrote data');
end;

procedure CheckPendingDraw(C: TPS2Console);
const
  Color: Cardinal = $80402010;
begin
  C.GS.WriteRegister(GSRegFRAME_1, 8 or (UInt64(1) shl 16));
  C.GS.WriteRegister(GSRegZBUF_1, UInt64(1) shl 32);
  C.GS.WriteRegister(GSRegXYOFFSET_1, 0);
  C.GS.WriteRegister(GSRegSCISSOR_1, (UInt64(63) shl 16) or (UInt64(63) shl 48));
  C.GS.WriteRegister(GSRegTEST_1, 0);
  C.GS.WriteRegister(GSRegPRIM, 6);
  C.GS.WriteRegister(GSRegRGBAQ, Color or (UInt64($3F800000) shl 32));
  C.GS.WriteRegister(GSRegXYZ2, 0);
  C.GS.WriteRegister(GSRegXYZ2, 128 or (UInt64(128) shl 16));
  C.GS.WriteRegister(GSRegBITBLTBUF, $100 or (UInt64(1) shl 16));
  C.GS.WriteRegister(GSRegTRXPOS, 0);
  C.GS.WriteRegister(GSRegTRXREG, 8 or (UInt64(8) shl 32));
  C.GS.WriteRegister(GSRegTRXDIR, 1);
  var Expected: TBytes;
  SetLength(Expected, 8 * 8 * 4);
  for var I := 0 to 63 do
    PCardinal(@Expected[I * 4])^ := Color;
  CheckPull(C, Expected);
end;

begin
  try
    for var Mode := 0 to 2 do
    begin
      var C := TPS2Console.Create(Default(TPS2ConsoleConfig));
      try
        if Mode > 0 then
          C.GS.Raster.Threads := 4;
        C.GS.Raster.Async := Mode = 2;
        CheckFormats(C);
        CaseName := 'DMA';
        CheckDMA(C);
        CaseName := 'Snapshot';
        CheckSnapshot(C);
        CaseName := 'Buffered';
        CheckBuffered(C);
        CaseName := 'Pending draw';
        CheckPendingDraw(C);
      finally
        C.Free;
      end;
    end;
    Writeln('VIF1 GS readback: formats, partial DMA, bus time, snapshots and pending draws: OK');
  except
    on E: Exception do
    begin
      Writeln('FAIL: ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
