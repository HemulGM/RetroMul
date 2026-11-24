program PS2GIFOwnedRunTest;

{$APPTYPE CONSOLE}
{$POINTERMATH ON}

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.Hash, System.Generics.Collections,
  Core.Snapshots, PS2.Types, PS2.GIF, PS2.GS, PS2.GS.Raster, PS2.GS.Memory;

type
  TProbe = class
    GS: TPS2GS;
    GIF: TPS2GIF;
    Clock: PInt64;
    MainThread: Cardinal;
    Raised: Boolean;
    Events: TStringList;
    constructor Create(G: TPS2GS; F: TPS2GIF; C: PInt64);
    destructor Destroy; override;
    procedure Interrupt;
    function IsRaised: Boolean;
  end;

constructor TProbe.Create(G: TPS2GS; F: TPS2GIF; C: PInt64);
begin
  inherited Create;
  GS := G;
  GIF := F;
  Clock := C;
  MainThread := GetCurrentThreadId;
  Events := TStringList.Create;
  GS.OnInterrupt := Interrupt;
  GS.InterruptRaised := IsRaised;
end;

destructor TProbe.Destroy;
begin
  Events.Free;
  inherited;
end;

procedure TProbe.Interrupt;
begin
  if GetCurrentThreadId <> MainThread then
    raise Exception.Create('Guest IRQ ran on a consumer thread');
  Raised := True;
  Events.Add(Format('%d,%d,%x,%x', [Clock^, GIF.GSBusyUntil, GS.CSR, GS.SIGLBLID]));
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

function Tag(Loops, Format: Integer; Descriptors: UInt64; EOP: Boolean = False): TPS2Reg128;
begin
  Result := Quad(Cardinal(Loops) or (UInt64(Ord(EOP)) shl 15) or
    (UInt64(Format) shl 58) or (UInt64(1) shl 60), Descriptors);
end;

procedure AD(G: TList<TPS2Reg128>; Index: Integer; Value: UInt64);
begin
  G.Add(Tag(1, 0, $E));
  G.Add(Quad(Value, Cardinal(Index)));
end;

function State(G: TPS2GS; GIF: TPS2GIF): TBytes;
begin
  // Join does not update the busy timeline. Compare its raw pending pixels,
  // before a later MMIO query would bring them up to the new EE time.
  GIF.Join;
  var Stream := TMemoryStream.Create;
  try
    var Archive := TStateArchive.Create(Stream, False);
    try
      G.SerializeState(Archive);
      GIF.SerializeState(Archive);
      GIF.SerializeTimeline(Archive);
    finally
      Archive.Free;
    end;
    SetLength(Result, Stream.Size);
    Move(Stream.Memory^, Result[0], Length(Result));
  finally
    Stream.Free;
  end;
end;

procedure RawCSR(Value: Cardinal);
asm
  .NOFRAME
  mov [rsp + 8], ecx
  ldmxcsr [rsp + 8]
end;

procedure Run;
var
  GS: array[0..1] of TPS2GS;
  GIF: array[0..1] of TPS2GIF;
  Probe: array[0..1] of TProbe;
  Clock: array[0..1] of Int64;
  ReferenceLog: TStringList;
begin
  var Saved := GetMXCSR;
  var Compared := 0;
  var IRQs := 0;
  var Signatures := TStringList.Create;
  try
    for var Mode := 0 to 1 do
    begin
      for var I := 0 to 1 do
      begin
        GS[I] := TPS2GS.Create;
        GIF[I] := TPS2GIF.Create(GS[I]);
        Clock[I] := 0;
        GIF[I].Clock := @Clock[I];
        GS[I].Raster.Threads := Mode * 4;
        GS[I].Raster.Async := True;
        GIF[I].Threaded := True;
        Probe[I] := TProbe.Create(GS[I], GIF[I], @Clock[I]);
        GS[I].Write($12001010, $7C00, 8);
      end;
      // Assign after enabling Async. Existing diagnostics keep the reference
      // consumer scalar, without changing its queue or adding a test switch.
      ReferenceLog := TStringList.Create;
      GS[0].Raster.TransferLog := ReferenceLog;
      try
        for var CaseIndex := 0 to 79 do
        begin
          var G := TList<TPS2Reg128>.Create;
          try
            AD(G, GSRegFRAME_1, UInt64(1) shl 16);
            AD(G, GSRegZBUF_1, UInt64(1) shl 32);
            AD(G, GSRegSCISSOR_1, (UInt64(63) shl 16) or (UInt64(63) shl 48));
            AD(G, GSRegTEST_1, 0);
            AD(G, GSRegPRIM, 0);
            AD(G, GSRegRGBAQ, $80402010 or (UInt64($3F800000) shl 32));
            G.Add(Tag(3, 0, 5));
            for var I := 0 to 2 do
              G.Add(Quad(Cardinal(I * 16) or (UInt64(Cardinal(I * 16)) shl 32), 0));
            G.Add(Tag(4, 1, 5));
            for var I := 0 to 1 do
            begin
              var A := Cardinal((I * 2 + 3) * 16);
              var B := A + 16;
              G.Add(Quad(A or (UInt64(A) shl 16), B or (UInt64(B) shl 16)));
            end;
            var PSM := PSMCT32;
            if CaseIndex and 1 <> 0 then
              PSM := PSMCT24;
            AD(G, GSRegBITBLTBUF, (UInt64($3000) shl 32) or (UInt64(4) shl 48) or (UInt64(PSM) shl 56));
            AD(G, GSRegTRXPOS, 0);
            AD(G, GSRegTRXREG, 64 or (UInt64(64) shl 32));
            AD(G, GSRegTRXDIR, 0);
            var Payload := 8 + CaseIndex * 7;
            G.Add(Tag(Payload, 2 + (CaseIndex and 1), 0));
            for var I := 0 to Payload - 1 do
              G.Add(Quad(UInt64(Cardinal(I + 1)) * $1234567, UInt64(Cardinal(I + 7)) * $2468ACE));
            if CaseIndex mod 9 = 0 then
            begin
              AD(G, GSRegSIGNAL, Cardinal(CaseIndex) or (UInt64($FFFFFFFF) shl 32));
              AD(G, GSRegFINISH, 0);
            end;
            // Eight points total; the final vertex completes four pending
            // pixels. Moving its busy update across an entry must be detected.
            G.Add(Tag(1, 0, 5, True));
            G.Add(Quad(112 or (UInt64(112) shl 32), 0));
            var Values := G.ToArray;
            for var I := 0 to 1 do
            begin
              GS[I].Write($12001000, 3, 8);
              Probe[I].Raised := False;
              Probe[I].Events.Clear;
              Clock[I] := Int64(CaseIndex + 1) * 100003;
              if CaseIndex >= 78 then
                Clock[I] := High(Int64) - 16;
              RawCSR((Saved and not Cardinal($E07F)) or $1F80 or (Cardinal(CaseIndex and 3) shl 13));
              if CaseIndex and 2 = 0 then
              begin
                for var K := 0 to High(Values) do
                  GIF[I].TransferDirect(Values[K]);
              end
              else
                GIF[I].KickPacket(PByte(@Values[0]));
            end;
            var A := State(GS[0], GIF[0]);
            var B := State(GS[1], GIF[1]);
            if (Length(A) <> Length(B)) or not CompareMem(@A[0], @B[0], Length(A)) then
            begin
              var Offset := 0;
              while (Offset < Length(A)) and (Offset < Length(B)) and (A[Offset] = B[Offset]) do
                Inc(Offset);
              raise Exception.CreateFmt('Owned state/timeline mismatch: mode %d case %d byte %d (%d/%d bytes)',
                [Mode, CaseIndex, Offset, Length(A), Length(B)]);
            end;
            if Probe[0].Events.Text <> Probe[1].Events.Text then
              raise Exception.Create('Owned IRQ time/state mismatch');
            if (GS[0].Raster.Primitives <> GS[1].Raster.Primitives) or
              (GS[0].Raster.PixelsDrawn <> GS[1].Raster.PixelsDrawn) then
              raise Exception.Create('Owned guest work mismatch');
            Inc(IRQs, Probe[0].Events.Count);
            Inc(Compared);
            var Hash := THashSHA2.Create;
            Hash.Update(A[0], Length(A));
            Hash.Update(B[0], Length(B));
            var Events := TEncoding.UTF8.GetBytes(Probe[0].Events.Text + '|' + Probe[1].Events.Text);
            if Length(Events) > 0 then
              Hash.Update(Events[0], Length(Events));
            Signatures.Add(Format('%d,%d,%s', [Mode, CaseIndex, Hash.HashAsString]));
          finally
            G.Free;
          end;
        end;
      finally
        for var I := 0 to 1 do
        begin
          GIF[I].Join;
          GS[I].Raster.Sync;
          GS[I].Raster.TransferLog := nil;
          GS[I].BeforeAccess := nil;
          GIF[I].Free;
          GS[I].Free;
          Probe[I].Free;
        end;
        ReferenceLog.Free;
      end;
    end;
    if IRQs = 0 then
      raise Exception.Create('Missing IRQ fallback coverage');
    if ParamStr(1) <> '' then
      Signatures.SaveToFile(ParamStr(1), TEncoding.UTF8);
    Writeln('Owned PATH1/PATH2: ', Compared, ' exact per-quad/run GS/GIF/VRAM/timeline comparisons, ',
      IRQs, ' IRQs, diagnostic and counter-wrap fallbacks: OK');
  finally
    Signatures.Free;
    RawCSR(Saved);
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
