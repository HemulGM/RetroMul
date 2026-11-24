program PS2GIFDirectTest;

// Whole-stream DIRECT batching against the independent word-feed route.

{$APPTYPE CONSOLE}
{$POINTERMATH ON}
{$Q-}

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.Math, System.SyncObjs,
  System.Generics.Collections, Core.Snapshots, PS2.Types, PS2.VIF, PS2.GIF,
  PS2.GS, PS2.GS.Memory, PS2.GS.Raster;

type
  TMemory = array[0..16383] of Byte;
  TProbe = class
    VIF: TPS2VIF;
    GS: TPS2GS;
    Raised: Boolean;
    ThreadID: Cardinal;
    Clock: PInt64;
    Events: TList<TBytes>;
    constructor Create;
    destructor Destroy; override;
    procedure Interrupt;
    function IsRaised: Boolean;
  end;

function VIFBytes(V: TPS2VIF): TBytes;
begin
  var Stream := TMemoryStream.Create;
  try
    var Archive := TStateArchive.Create(Stream, False);
    try
      V.SerializeState(Archive);
    finally
      Archive.Free;
    end;
    SetLength(Result, Stream.Size);
    Move(Stream.Memory^, Result[0], Length(Result));
  finally
    Stream.Free;
  end;
end;

constructor TProbe.Create;
begin
  inherited;
  Events := TList<TBytes>.Create;
  ThreadID := GetCurrentThreadId;
end;

destructor TProbe.Destroy;
begin
  Events.Free;
  inherited;
end;

procedure TProbe.Interrupt;
begin
  if GetCurrentThreadId <> ThreadID then
    raise Exception.Create('Guest IRQ on GIF consumer thread');
  Raised := True;
  // The word-at-a-time reference reports intermediate VIF progress at a
  // different granularity. Compare guest IRQ time/state here, full VIF
  // staging after every feed piece below. The diagnostic legacy-quad test
  // additionally compares VIF progress at each IRQ.
  var Value: TBytes;
  SetLength(Value, 24);
  Move(Clock^, Value[0], 8);
  Move(GS.CSR, Value[8], 8);
  Move(GS.SIGLBLID, Value[16], 8);
  Events.Add(Value);
end;

function TProbe.IsRaised: Boolean;
begin
  Result := Raised;
end;

function Quad(Lo, Hi: UInt64): TPS2Reg128;
begin
  Result.Lo := Lo;
  Result.Hi := Hi;
end;

function Tag(Loops, Format, Registers: Integer; Descriptors: UInt64): TPS2Reg128;
begin
  Result := Quad(Cardinal(Loops) or $8000 or (UInt64(Format) shl 58) or
    (UInt64(Registers and 15) shl 60), Descriptors);
end;

procedure AD(G: TList<TPS2Reg128>; Index: Cardinal; Value: UInt64);
begin
  G.Add(Tag(1, 0, 1, $E));
  G.Add(Quad(Value, Index));
end;

procedure Setup(GIF: TPS2GIF);
begin
  var G := TList<TPS2Reg128>.Create;
  try
    AD(G, GSRegFRAME_1, UInt64(1) shl 16);
    AD(G, GSRegZBUF_1, UInt64(1) shl 32);
    AD(G, GSRegSCISSOR_1, (UInt64(63) shl 16) or (UInt64(63) shl 48));
    AD(G, GSRegTEST_1, 0);
    AD(G, GSRegPRIM, 0);
    for var Q in G do
      GIF.TransferDirect(Q);
  finally
    G.Free;
  end;
end;

procedure Check;
var
  GS: array[0..1] of TPS2GS;
  GIF: array[0..1] of TPS2GIF;
  V: array[0..1] of TPS2VIF;
  Probe: array[0..1] of TProbe;
  Clock: array[0..1] of Int64;
  Code, Data: array[0..1] of TMemory;
begin
  var TotalQuads, TotalRuns, Comparisons, IRQs: Int64;
  TotalQuads := 0;
  TotalRuns := 0;
  Comparisons := 0;
  IRQs := 0;
  var SavedControl := GetMXCSR;
  var SavedRuns := PS2VIFRuns;
  try
    for var Round := 0 to 15 do
    begin
      if FindCmdLineSwitch('trace') then
      begin
        Writeln('round=', Round, ' setup');
        Flush(Output);
      end;
      FillChar(Code, SizeOf(Code), 0);
      FillChar(Data, SizeOf(Data), 0);
      for var X := 0 to 1 do
      begin
        GS[X] := TPS2GS.Create;
        GIF[X] := TPS2GIF.Create(GS[X]);
        Clock[X] := 0;
        GIF[X].Clock := @Clock[X];
        GS[X].Raster.Threads := (Round and 1) * 4;
        GS[X].Raster.Async := Round mod 8 <> 7;
        GIF[X].Threaded := Round mod 8 <> 7;
        V[X] := TPS2VIF.Create(1, nil, GIF[X], @Code[X, 0], @Data[X, 0], 16384, 16384);
        Probe[X] := TProbe.Create;
        Probe[X].VIF := V[X];
        Probe[X].GS := GS[X];
        Probe[X].Clock := @Clock[X];
        GS[X].OnInterrupt := Probe[X].Interrupt;
        GS[X].InterruptRaised := Probe[X].IsRaised;
        GS[X].Write($12001010, $7C00, 8); // SIGNAL/FINISH unmasked.
        V[X].CaptureUnfinished := Round = 14;
        Setup(GIF[X]);
      end;
      try
        RandSeed := 13991 + Round;
        for var Batch := 0 to 23 do
        begin
          if FindCmdLineSwitch('trace') then
          begin
            Writeln('round=', Round, ' batch=', Batch, ' start');
            Flush(Output);
          end;
          var Control := (SavedControl and not Cardinal($E07F)) or $1F80 or
            (Cardinal((Round + Batch) and 3) shl 13);
          if Batch and 1 <> 0 then
            Control := Control or $8040;
          SetMXCSR(Control);
          for var X := 0 to 1 do
          begin
            Probe[X].Raised := False;
            Probe[X].Events.Clear;
            GS[X].Write($12001000, 3, 8);
            V[X].Write($10, 8, 4); // Cancel any completed VIF interrupt stall.
            Clock[X] := Int64(Round * 24 + Batch) * 100003;
          end;
          var G := TList<TPS2Reg128>.Create;
          var Words := TList<Cardinal>.Create;
          try
            // Packed drawing with tag/data and DIRECT-command boundaries unrelated.
            for var I := 0 to 4 + Batch do
            begin
              AD(G, GSRegRGBAQ, UInt64($80432100 + I) or (UInt64($3F800000) shl 32));
              AD(G, GSRegXYZ2, UInt64((I and 31) * 16) or (UInt64((Batch and 31) * 16) shl 16));
              if I = 3 then
                AD(G, GSRegSIGNAL, UInt64(Batch) or (UInt64($FFFFFFFF) shl 32));
              if I = 5 then
                AD(G, GSRegFINISH, 0);
            end;
            // Odd REGLIST register count: ignore the unused high half at its end.
            G.Add(Tag(3, 1, 3, $F51));
            for var I := 0 to 4 do
              G.Add(Quad(UInt64(I) * $00100010, UInt64(I + 1) * $00100010));
            G.Add(Tag(0, 0, 16, $FFFFFFFFFFFFFFFF));
            // Small IMAGE transfer, including an unusual format-3 tag.
            AD(G, GSRegBITBLTBUF, (UInt64(128 + Batch) shl 32) or (UInt64(1) shl 48));
            AD(G, GSRegTRXPOS, 0);
            AD(G, GSRegTRXREG, 8 or (UInt64(4) shl 32));
            AD(G, GSRegTRXDIR, 0);
            G.Add(Tag(8, 2 + (Batch and 1), 1, 0));
            for var I := 0 to 7 do
              G.Add(Quad(UInt64(I) * $13579BDF, UInt64(I + 1) * $2468ACE1));
            if (Round = 0) and (Batch = 12) then
              for var Part := 0 to 9 do
              begin
                G.Add(Tag(30000, 0, 1, $F));
                for var I := 1 to 30000 do
                  G.Add(Quad(I, Part));
              end;
            var At := 0;
            while At < G.Count do
            begin
              var N := Min(G.Count - At, 1 + Random(137));
              if G.Count > 65536 then
                N := Min(G.Count - At, 65536);
              Words.Add(0);
              Words.Add(0);
              Words.Add(0);
              var Cmd := Cardinal($50 + (Batch and 1)) shl 24;
              if (At + N = G.Count) and (Batch mod 7 = 0) then
                Cmd := Cmd or $80000000;
              Words.Add(Cmd or Cardinal(N and $FFFF));
              for var I := 0 to N - 1 do
                for var K := 0 to 3 do
                  Words.Add(G[At + I].UW[K]);
              Inc(At, N);
            end;
            var Stream := Words.ToArray;
            At := 0;
            while At < Length(Stream) do
            begin
              var Piece := Min(Length(Stream) - At, 1 + Random(509));
              var ByQuads := Batch and 1 <> 0;
              if G.Count > 65536 then
                Piece := Length(Stream) - At;
              if ByQuads then
                Piece := Min(Length(Stream) - At, Max(4, (Piece div 4) * 4));
              for var X := 0 to 1 do
              begin
                if FindCmdLineSwitch('trace') and (G.Count > 65536) then
                begin
                  Writeln('large feed variant=', X, ' at=', At, ' words=', Piece);
                  Flush(Output);
                end;
                var PieceControl := Control xor (Cardinal((At shr 8) and 1) shl 13);
                SetMXCSR(PieceControl);
                PS2VIFRuns := X = 1;
                Clock[X] := Int64(Round * 24 + Batch) * 100003 + At div 16;
                var Taken: Integer;
                if ByQuads then
                  Taken := V[X].FeedQuads(@Stream[At], Piece div 4) * 4
                else
                  Taken := V[X].Feed(@Stream[At], Piece);
                if Taken <> Piece then
                  raise Exception.Create('Unexpected held input');
                if FindCmdLineSwitch('trace') and (G.Count > 65536) then
                begin
                  Writeln('large feed done variant=', X);
                  Flush(Output);
                end;
                if GetMXCSR and $FFC0 <> PieceControl and $FFC0 then
                  raise Exception.Create('Producer control changed');
              end;
              var A := VIFBytes(V[0]);
              var B := VIFBytes(V[1]);
              if (Length(A) <> Length(B)) or not CompareMem(@A[0], @B[0], Length(A)) or
                (V[0].Words <> V[1].Words) then
                raise Exception.Create('VIF split-state mismatch');
              Inc(At, Piece);
            end;
            // Interleaved PATH1 must follow all older DIRECT data.
            var Packet: array[0..1] of TPS2Reg128;
            Packet[0] := Tag(1, 0, 1, $E);
            Packet[1] := Quad(Batch, GSRegLABEL);
            for var X := 0 to 1 do
            begin
              GIF[X].KickPacket(@Packet[0]);
              GIF[X].Join;
              GS[X].Raster.Sync;
            end;
            if FindCmdLineSwitch('trace') then
            begin
              Writeln('joined');
              Flush(Output);
            end;
            var MemorySame := CompareMem(GS[0].Raster.Memory.Data, GS[1].Raster.Memory.Data, PS2GSMemorySize);
            var PathsSame := CompareMem(@GIF[0].Path[1], @GIF[1].Path[1], SizeOf(TPS2GIFPathState) * 3);
            var Busy0 := GIF[0].GSBusyUntil;
            var Busy1 := GIF[1].GSBusyUntil;
            if not MemorySame or not PathsSame or (Busy0 <> Busy1) or (GS[0].CSR <> GS[1].CSR) or
              (GS[0].SIGLBLID <> GS[1].SIGLBLID) then
            begin
              Writeln('mismatch memory=', MemorySame, ' paths=', PathsSame, ' busy=', Busy0, '/', Busy1,
                ' CSR=', GS[0].CSR, '/', GS[1].CSR, ' labels=', GS[0].SIGLBLID, '/', GS[1].SIGLBLID,
                ' clock=', Clock[0], '/', Clock[1]);
              for var X := 0 to 1 do
                for var P := 1 to 3 do
                  Writeln('path ', X, '/', P, ' active=', GIF[X].Path[P].Active,
                    ' loop=', GIF[X].Path[P].Loop, '/', GIF[X].Path[P].NLoop, ' reg=', GIF[X].Path[P].Reg,
                    ' format=', GIF[X].Path[P].Flg, ' q=', IntToHex(GIF[X].Path[P].Q, 8));
              Flush(Output);
              raise Exception.CreateFmt('GS/GIF mismatch round=%d batch=%d', [Round, Batch]);
            end;
            if Probe[0].Events.Count <> Probe[1].Events.Count then
              raise Exception.Create('IRQ count mismatch');
            for var I := 0 to Probe[0].Events.Count - 1 do
            begin
              var A := Probe[0].Events[I];
              var B := Probe[1].Events[I];
              if (Length(A) <> Length(B)) or not CompareMem(@A[0], @B[0], Length(A)) then
                raise Exception.CreateFmt('VIF state/word count observed by IRQ differs round=%d batch=%d', [Round, Batch]);
            end;
            Inc(IRQs, Probe[1].Events.Count);
            Inc(TotalQuads, G.Count);
            Inc(Comparisons);
          finally
            Words.Free;
            G.Free;
          end;
        end;
        // Public bulk API must refuse inputs which its queue/GS can mutate.
        if GIF[1].TransferDirectRun(PCardinal(@GIF[1].Path[1]), 2) <> 0 then
          raise Exception.Create('GIF alias accepted');
        if GIF[1].TransferDirectRun(PCardinal(GS[1]), 2) <> 0 then
          raise Exception.Create('GS alias accepted');
        if GIF[1].TransferDirectRun(PCardinal(GS[1].Raster), 2) <> 0 then
          raise Exception.Create('Raster alias accepted');
        if GIF[1].TransferDirectRun(PCardinal(GS[1].Raster.Memory.Data), 2) <> 0 then
          raise Exception.Create('VRAM alias accepted');
        for var X := 0 to 1 do
        begin
          V[X].Reset;
          FillChar(V[X].S.Held, SizeOf(V[X].S.Held), 0);
          var Cmd := Cardinal($50000010);
          V[X].Feed(@Cmd, 1);
          PS2VIFRuns := X = 1;
          if V[X].Feed(@V[X].S.Held[0], 64) <> 64 then
            raise Exception.Create('Aliased VIF input not consumed');
          GIF[X].Join;
        end;
        var A := VIFBytes(V[0]);
        var B := VIFBytes(V[1]);
        if (Length(A) <> Length(B)) or not CompareMem(@A[0], @B[0], Length(A)) then
          raise Exception.Create('Aliased VIF staging state differs');
        // Explicit API coverage without retaining production counters.
        var Empty: array[0..1] of TPS2Reg128;
        FillChar(Empty, SizeOf(Empty), 0);
        GIF[0].TransferDirect(Empty[0]);
        GIF[0].TransferDirect(Empty[1]);
        var Taken := GIF[1].TransferDirectRun(@Empty[0].UW[0], 2);
        if Taken = 0 then
        begin
          GIF[1].TransferDirect(Empty[0]);
          GIF[1].TransferDirect(Empty[1]);
        end
        else
          Inc(TotalRuns);
        GIF[0].Join;
        GIF[1].Join;
        if not CompareMem(@GIF[0].Path[2], @GIF[1].Path[2], SizeOf(TPS2GIFPathState)) then
          raise Exception.Create('Explicit DIRECT prefix left another path state');
      finally
        for var X := 0 to 1 do
        begin
          GIF[X].Join;
          GS[X].Raster.Sync;
          V[X].Free;
          GIF[X].Free;
          GS[X].Free;
          Probe[X].Free;
        end;
      end;
    end;
    if (TotalRuns = 0) or (IRQs = 0) then
      raise Exception.Create('New path/IRQ coverage missing');
    Writeln('quads=', TotalQuads, ' api_prefixes=', TotalRuns, ' comparisons=', Comparisons, ' IRQs=', IRQs,
      ' word/bulk SAME: splits, private state, PACKED/REGLIST/IMAGE, 65536 command, wrap, MXCSR, barriers and PATH1 order');
  finally
    SetMXCSR(SavedControl);
    PS2VIFRuns := SavedRuns;
  end;
end;

begin
  var Done := TEvent.Create(nil, True, False, '');
  var Watchdog := TThread.CreateAnonymousThread(
    procedure
    begin
      var Limit := 180000;
      if FindCmdLineSwitch('short') then
        Limit := 30000;
      if Done.WaitFor(Limit) <> wrSignaled then
      begin
        TerminateProcess(GetCurrentProcess, 2);
      end;
    end);
  Watchdog.FreeOnTerminate := False;
  Watchdog.Start;
  try
    try
      SetExceptionMask(exAllArithmeticExceptions);
      Check;
    except
      on E: Exception do
      begin
        Writeln(E.ClassName, ': ', E.Message);
        ExitCode := 1;
      end;
    end;
  finally
    Done.SetEvent;
    Watchdog.WaitFor;
    Watchdog.Free;
    Done.Free;
  end;
end.
