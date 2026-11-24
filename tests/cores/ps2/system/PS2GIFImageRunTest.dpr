program PS2GIFImageRunTest;

{$APPTYPE CONSOLE}
{$POINTERMATH ON}

uses
  System.SysUtils, System.Classes, System.Math, System.Generics.Collections,
  Core.Snapshots, PS2.Types, PS2.GS, PS2.GS.Raster, PS2.GS.Memory, PS2.GIF;

type
  TProbe = class
    GIF: TPS2GIF;
    Events: TStringList;
    constructor Create(G: TPS2GIF);
    destructor Destroy; override;
    procedure Held(Cycles: Int64);
  end;

var
  TestMode, TestCase: Integer;

constructor TProbe.Create(G: TPS2GIF);
begin
  inherited Create;
  GIF := G;
  Events := TStringList.Create;
  GIF.OnPath3Held := Held;
end;

destructor TProbe.Destroy;
begin
  Events.Free;
  inherited;
end;

procedure TProbe.Held(Cycles: Int64);
begin
  Events.Add(Format('%d,%d', [Cycles, GIF.GSBusyUntil]));
end;

procedure Check(Condition: Boolean; const Message: string);
begin
  if not Condition then
    raise Exception.Create(Message);
end;

function Quad(Lo, Hi: UInt64): TPS2Reg128;
begin
  Result.Lo := Lo;
  Result.Hi := Hi;
end;

function Tag(Loops, Format: Integer; EOP: Boolean): TPS2Reg128;
begin
  Result := Quad(Cardinal(Loops) or (UInt64(Ord(EOP)) shl 15) or
    (UInt64(Format) shl 58) or (UInt64(1) shl 60), $E);
end;

procedure AD(Stream: TList<TPS2Reg128>; Index: Integer; Value: UInt64; EOP: Boolean = False);
begin
  Stream.Add(Tag(1, 0, EOP));
  Stream.Add(Quad(Value, Cardinal(Index)));
end;

function Next(var Seed: Cardinal): Cardinal;
begin
  Seed := Cardinal((UInt64(Seed) * 1664525 + 1013904223) and $FFFFFFFF);
  Result := Seed;
end;

function State(GS: TPS2GS; GIF: TPS2GIF): TBytes;
begin
  GIF.GSBusyUntil;
  var Stream := TMemoryStream.Create;
  try
    var Archive := TStateArchive.Create(Stream, False);
    try
      GS.SerializeState(Archive);
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
const
  Formats: array[0..12] of Integer = (PSMCT32, PSMCT24, PSMCT16, PSMCT16S,
    PSMT8, PSMT4, PSMT8H, PSMT4HL, PSMT4HH, PSMZ32, PSMZ24, PSMZ16, PSMZ16S);
  Chunks: array[0..6] of Integer = (2, 63, 64, 65, 257, 4096, 20003);
var
  GS: array[0..1] of TPS2GS;
  GIF: array[0..1] of TPS2GIF;
  Probe: array[0..1] of TProbe;
  Clock: array[0..1] of Int64;
begin
  var Saved := GetMXCSR;
  var Comparisons := 0;
  var Quads: Int64 := 0;
  try
    for var Mode := 0 to 2 do
    begin
      TestMode := Mode;
      for var I := 0 to 1 do
      begin
        GS[I] := TPS2GS.Create;
        GIF[I] := TPS2GIF.Create(GS[I]);
        Probe[I] := TProbe.Create(GIF[I]);
        Clock[I] := 0;
        GIF[I].Clock := @Clock[I];
        GS[I].Raster.Threads := Ord(Mode > 0) * 4;
        GS[I].Raster.Async := Mode = 2;
      end;
      try
        for var CaseIndex := 0 to 242 do
        begin
          TestCase := CaseIndex;
          var PSM := Formats[CaseIndex mod Length(Formats)];
          var Width := 1 + CaseIndex mod 67;
          var Height := 1 + CaseIndex mod 19;
          var Payload := 1 + CaseIndex * 11;
          if (CaseIndex >= 52) and (CaseIndex <= 56) then
          begin
            PSM := PSMCT32;
            Width := 512;
            Height := 544;
            Payload := 69632;
          end;
          if CaseIndex >= 57 then
          begin
            PSM := PSMCT24;
            if CaseIndex and 1 <> 0 then
              PSM := PSMZ24;
            Width := 1 + (CaseIndex - 57) mod 31;
            Height := 1 + ((CaseIndex - 57) div 31) mod 3;
            Payload := Max(1, (Width * Height * 24 + 127) div 128 + CaseIndex mod 3 - 1);
          end;
          if CaseIndex = 50 then
            Width := 0;
          var G := TList<TPS2Reg128>.Create;
          try
            var Seed: Cardinal := 8123 + Cardinal(CaseIndex);
            AD(G, GSRegBITBLTBUF, (UInt64($3F80) shl 32) or (UInt64(8) shl 48) or (UInt64(PSM) shl 56));
            AD(G, GSRegTRXPOS, (UInt64(CaseIndex mod 16) shl 32) or (UInt64(CaseIndex mod 8) shl 48));
            AD(G, GSRegTRXREG, Cardinal(Width) or (UInt64(Cardinal(Height)) shl 32));
            AD(G, GSRegTRXDIR, 0);
            for var Prefix := 1 to CaseIndex mod 3 do
              AD(G, GSRegHWREG, Next(Seed) or (UInt64(Next(Seed)) shl 32));
            var Left := Payload;
            while Left > 0 do
            begin
              var N := Min(Left, 32767);
              G.Add(Tag(N, 2 + (CaseIndex and 1), N = Left));
              for var I := 0 to N - 1 do
              begin
                var Q: TPS2Reg128;
                for var K := 0 to 3 do
                  Q.UW[K] := Next(Seed);
                G.Add(Q);
              end;
              Dec(Left, N);
            end;
            AD(G, GSRegFINISH, 0, True);
            var Values := G.ToArray;
            for var I := 0 to 1 do
            begin
              Clock[I] := Int64(CaseIndex) * 100003;
              Probe[I].Events.Clear;
              GIF[I].SetPath3Mask(True);
              GIF[I].SetPath3Mask(False);
              RawCSR((Saved and not Cardinal($E07F)) or $1F80 or (Cardinal(CaseIndex and 3) shl 13));
              var At := 0;
              var Piece := 0;
              while At < G.Count do
              begin
                var Count := 1;
                if I = 1 then
                  Count := Min(G.Count - At, Chunks[(Piece + CaseIndex) mod Length(Chunks)]);
                var Taken := GIF[I].Transfer(3, PByte(@Values[At]), Count, True);
                Check((Taken >= 0) and (Taken <= Count), 'Invalid GIF acceptance count');
                Check((Taken > 0) or GIF[I].Path3Held, 'GIF made no progress');
                Inc(At, Taken);
                if GIF[I].Path3Held then
                  GIF[I].ReleasePath3;
                Inc(Piece);
              end;
            end;
            var A := State(GS[0], GIF[0]);
            var B := State(GS[1], GIF[1]);
            Check((Length(A) = Length(B)) and CompareMem(@A[0], @B[0], Length(A)),
              Format('State/VRAM mismatch at mode %d case %d format %.2x', [Mode, CaseIndex, PSM]));
            Check(Probe[0].Events.Text = Probe[1].Events.Text, 'PATH3 burst time mismatch');
            Check((GS[0].Raster.Primitives = GS[1].Raster.Primitives) and
              (GS[0].Raster.PixelsDrawn = GS[1].Raster.PixelsDrawn), 'Guest GS work mismatch');
            Inc(Comparisons);
            Inc(Quads, G.Count);
          finally
            G.Free;
          end;
        end;
      finally
        for var I := 0 to 1 do
        begin
          GIF[I].Join;
          GS[I].Raster.Sync;
          GS[I].BeforeAccess := nil;
          GIF[I].Free;
          GS[I].Free;
          Probe[I].Free;
        end;
      end;
    end;
    Writeln('IMAGE runs: ', Comparisons, ' exact GS/GIF/VRAM comparisons, ', Quads,
      ' quads, all formats, partial/HWREG tails, ring wrap and burst times: OK');
  finally
    RawCSR(Saved);
  end;
end;

procedure CheckAliases;
var
  GS: array[0..1] of TPS2GS;
  GIF: array[0..1] of TPS2GIF;
begin
  for var Kind := 1 to 4 do
  begin
    for var I := 0 to 1 do
    begin
      GS[I] := TPS2GS.Create;
      GIF[I] := TPS2GIF.Create(GS[I]);
      GS[I].Raster.Async := True;
    end;
    try
      var Values: array[0..3] of TPS2Reg128;
      Values[0] := Tag(3, 2, True);
      for var I := 1 to 3 do
        Values[I] := Quad($1122334455667788 + UInt64(I), $8877665544332211 + UInt64(I));
      for var I := 0 to 1 do
      begin
        GS[I].WriteRegister(GSRegBITBLTBUF, (UInt64($100) shl 32) or (UInt64(1) shl 48));
        GS[I].WriteRegister(GSRegTRXPOS, 0);
        GS[I].WriteRegister(GSRegTRXREG, 16 or (UInt64(16) shl 32));
        GS[I].WriteRegister(GSRegTRXDIR, 0);
        var Data: PByte := nil;
        case Kind of
          1:
            Data := GS[I].Raster.Memory.Data + $200000;
          2:
            begin
              Check(SizeOf(Values) <= 2 * SizeOf(TPS2GIFPathState), 'Alias fixture is too large');
              Data := PByte(@GIF[I].Path[1]);
            end;
          3:
            Data := PByte(@GS[I].PMODE);
          4:
            Data := PByte(@GS[I].Raster.Regs[0]);
        end;
        Move(Values, Data^, SizeOf(Values));
        if I = 0 then
        begin
          for var K := 0 to 3 do
            Check(GIF[I].Transfer(3, Data + K * 16, 1) = 1, 'Scalar alias read failed');
        end
        else
          Check(GIF[I].Transfer(3, Data, 4) = 4, 'Run alias read failed');
      end;
      var A := State(GS[0], GIF[0]);
      var B := State(GS[1], GIF[1]);
      Check((Length(A) = Length(B)) and CompareMem(@A[0], @B[0], Length(A)),
        Format('Aliased state/VRAM mismatch: %d', [Kind]));
    finally
      for var I := 0 to 1 do
      begin
        GIF[I].Join;
        GS[I].Raster.Sync;
        GS[I].BeforeAccess := nil;
        GIF[I].Free;
        GS[I].Free;
      end;
    end;
  end;
  Writeln('IMAGE aliases: local memory, GIF paths, GS and raster state: OK');
end;

begin
  try
    Run;
    CheckAliases;
  except
    on E: Exception do
    begin
      Writeln('FAIL mode=', TestMode, ' case=', TestCase, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
