unit RetroTune.Digital.Module;

interface

uses
  System.SysUtils, ZX.Sound.DAC;

type
  TDigitalKind = (dkCHI, dkDMM, dkDST, dkSQD, dkSTR, dkET1, dkPDT);

  TDigitalCell = record
    Note, Sample, Volume, Offset, Slide, Ornament: Integer;
    RawNote, RawParam, RawEffect: Byte;
    class function Empty: TDigitalCell; static;
  end;

  TDigitalRow = record
    Cells: array[0..3] of TDigitalCell;
    Tempo: Integer;
  end;

  TDigitalOrnament = record
    Notes: TArray<Integer>;
    Loop: Integer;
  end;

  TDigitalModule = record
    Kind: TDigitalKind;
    Title, Version: string;
    Channels, Tempo: Integer;
    BaseRate: Integer;
    SlideScale: Double;
    Samples: TArray<TZXDACSample>;
    Rows: TArray<TDigitalRow>;
    Ornaments: array[0..11] of TDigitalOrnament;
    Mixins: array[0..63] of TDigitalCell;
    MixPeriods: array[0..63] of Integer;
  end;

function ParseDigitalModule(const Data: TBytes; Kind: TDigitalKind): TDigitalModule;

function DetectDigitalModule(const Data: TBytes): TDigitalKind;

implementation

uses
  System.Math, System.Generics.Collections, RetroTune.Binary;

class function TDigitalCell.Empty: TDigitalCell;
begin
  Result := Default(TDigitalCell);
  Result.Note := -1;
  Result.Sample := -1;
  Result.Volume := -1;
  Result.Offset := -1;
  Result.Ornament := -1;
end;

function DetectDigitalModule(const Data: TBytes): TDigitalKind;
begin
  if (Length(Data) >= 8) and (TEncoding.ASCII.GetString(Data, 0, 5) = 'CHIPv') then
    Exit(dkCHI);
  if Length(Data) = $1B800 then
    Exit(dkET1);
  if Length(Data) = $18300 then
    Exit(dkPDT);
  raise EArgumentException.Create('Unknown Extreme/ProDigiTracker module');
end;

function ParseDigitalModule(const Data: TBytes; Kind: TDigitalKind): TDigitalModule;
const
  AYLevels: array[0..15] of Integer = (0, $340, $4C0, $6F2, $A44, $F13, $1510, $227E, $289F, $414E, $5B21, $7258, $905E, $B550, $D7A0, $FFFF);
  ETOffsets: array[0..7] of Integer = (0, $4200, 0, $7C00, $BC00, 0, $FC00, $13C00);
  DSTOffsets: array[0..7] of Integer = ($200, $7200, 0, $B200, $F200, 0, $13200, $17200);
  DMMBanks: array[0..5] of Integer = (0, 1, 3, 4, 6, 7);
  Pages: array[0..7] of Integer = (0, 0, 0, 1, 2, 0, 3, 4);
var
  List: TList<TDigitalRow>;
  Used: array[0..15] of Boolean;
  Order: TArray<Integer>;
  Row: TDigitalRow;
  PatternBase, PatternSize, PatternRows, PosBase, PosCount, MaxPatterns, SampleBase: Integer;
  NewET, Compiled: Boolean;

  procedure Need(B: Boolean; const S: string);
  begin
    if not B then
      raise EArgumentException.Create('Digital tracker: ' + S);
  end;

  function B(P: Integer): Integer;
  begin
    RequireBytes(Data, P, 1);
    Result := Data[P];
  end;

  function W(P: Integer): Integer;
  begin
    Result := LE16(Data, P);
  end;

  procedure Sample(I, Start, Size, Loop, Mode: Integer; Terminator: Integer = -1);
  begin
    RequireBytes(Data, Start, Size);
    if Terminator >= 0 then
    begin
      var N := 0;
      while (N < Size) and (Data[Start + N] <> Terminator) do
        Inc(N);
      Size := N;
    end;
    var Count := Size;
    if Mode = 2 then
      Count := Count * 2;
    SetLength(Result.Samples[I].PCM, Count);
    Result.Samples[I].Loop := EnsureRange(Loop, 0, Count);
    for var J := 0 to Count - 1 do
    begin
      var V: Integer;
      if Mode = 2 then
      begin
        V := B(Start + J div 2);
        if Odd(J) then
          V := V shr 4;
      end
      else
        V := B(Start + J);
      if Mode = 0 then
        V := (V - 128) * 256
      else
        V := AYLevels[V and 15] div 2;
      Result.Samples[I].PCM[J] := V;
    end;
  end;

  function DMMCell(P: Integer): TDigitalCell;
  begin
    Result := TDigitalCell.Empty;
    Result.RawNote := B(P);
    Result.RawParam := B(P + 1);
    Result.RawEffect := B(P + 2);
    var N := B(P);
    var V := B(P + 1);
    if N < 62 then
    begin
      if N = 61 then
        Result.Note := -2
      else if N <> 0 then
        Result.Note := N - 1;
      if V shr 4 <> 0 then
        Result.Sample := V shr 4;
      if V and 15 <> 0 then
        Result.Volume := V and 15;
    end;
  end;

begin
  FillChar(Used, SizeOf(Used), 0);
  Result := Default(TDigitalModule);
  Result.Kind := Kind;
  Result.Channels := 4;
  SetLength(Result.Samples, 16);
  PatternRows := 64;
  PatternSize := 512;
  MaxPatterns := 32;
  PatternBase := 512;
  PosBase := 0;
  PosCount := 0;
  NewET := False;
  Compiled := False;
  case Kind of
    dkCHI:
      begin
        RequireBytes(Data, 0, 512);
        Need(TEncoding.ASCII.GetString(Data, 0, 5) = 'CHIPv', 'CHI signature');
        Result.Title := TextField(Data, 8, 32);
        Result.Tempo := B(40);
        PosCount := B(41) + 1;
        PosBase := 256;
        MaxPatterns := 31;
        Result.BaseRate := 3500000 * 72 * 4 div 890 div 256;
        Result.SlideScale := 32.7 / 72;
      end;
    dkDMM:
      begin
        RequireBytes(Data, 0, $15E);
        Result.Channels := 3;
        Result.Tempo := B($40);
        PosBase := $0E;
        PosCount := B($43);
        PatternRows := B($0C);
        Need((PatternRows > 0) and (PatternRows <= 64), 'DMM pattern length');
        PatternBase := $15E;
        PatternSize := PatternRows * 9;
        MaxPatterns := 24;
        Result.BaseRate := 3500000 * 44 div 356 div 256;
        Result.SlideScale := 32.7 / 44;
        for var I := 0 to 63 do
        begin
          Result.Mixins[I] := DMMCell($45 + I * 4);
          Result.MixPeriods[I] := B($48 + I * 4);
        end;
      end;
    dkDST:
      begin
        RequireBytes(Data, 0, $1B200);
        Result.Channels := 3;
        Result.Title := TextField(Data, $66, 28);
        Result.Tempo := B($64);
        PosBase := 1;
        PosCount := B($65);
        PatternBase := $4200;
        PatternSize := 384;
        for var I := $C8 to $FF do
          Compiled := Compiled or (B(I) <> 0);
        if Compiled then
          RequireBytes(Data, 0, $1C200);
      end;
    dkSQD:
      begin
        RequireBytes(Data, 0, $4400);
        Result.Title := TextField(Data, $100, 32);
        Result.Tempo := B($210);
        PosBase := $1A0;
        PosCount := B($212) + 1;
        PatternBase := $400;
        Result.BaseRate := 3500000 * 44 div 346 div 256;
      end;
    dkSTR:
      begin
        RequireBytes(Data, 0, $19A0);
        Result.Channels := 3;
        Result.Title := TextField(Data, $C1, 10);
        Result.Tempo := B(0);
        PosBase := 1;
        Need((B($CB) > 0) and (B($CB) <= 128) and not Odd(B($CB)), 'STR positions');
        PosCount := B($CB) div 2;
        PatternBase := $CC;
        PatternSize := 385;
        MaxPatterns := 16;
        Result.BaseRate := 3500000 * 22 div 345 div 256;
      end;
    dkET1:
      begin
        RequireBytes(Data, 0, $1B800);
        Result.Title := TextField(Data, 3, 30);
        Result.Tempo := B(1);
        PosBase := $22;
        PosCount := Max(1, B(2));
        for var P := $200 to $41FF do
          if ((P - $200) mod 2 = 0) and (B(P) shr 6 = 3) then
            NewET := True;
        Result.BaseRate := 3500000 * 95 div 450 div 256;
        Result.Version := '1.31';
        if NewET then
        begin
          Result.BaseRate := 3500000 * 80 div 374 div 256;
          Result.Version := '1.32–1.41';
        end;
        Result.SlideScale := 32.7 / 80;
      end;
    dkPDT:
      begin
        RequireBytes(Data, 0, $18300);
        Result.Title := TextField(Data, $CC, 32);
        Result.Tempo := B($EC);
        PosBase := $200;
        PosCount := B($EF);
        PatternBase := $300;
        Result.BaseRate := 3500000 * 46 div 374 div 256;
        for var I := 1 to 11 do
        begin
          var Count := B($B0 + (I - 1) * 2 + 1);
          var Loop := B($B0 + (I - 1) * 2);
          Need((Count <= 16) and (Loop <= Count), 'PDT ornament');
          SetLength(Result.Ornaments[I].Notes, Count);
          Result.Ornaments[I].Loop := Loop;
          for var J := 0 to Count - 1 do
          begin
            var V := B((I - 1) * 16 + J);
            if V >= 128 then
              Dec(V, 256);
            Result.Ornaments[I].Notes[J] := V div 2;
          end;
        end;
      end;
  end;
  Need((Result.Tempo > 0) and (Result.Tempo <= 255), 'tempo');
  Need((PosCount > 0) and (PosCount <= 256), 'position count');
  if Kind in [dkDST, dkDMM, dkET1, dkSQD] then
    Need(PosCount <= 100, 'position count');
  if Kind = dkDMM then
    Need(PosCount <= 50, 'DMM positions');
  SetLength(Order, PosCount);
  for var I := 0 to PosCount - 1 do
  begin
    Order[I] := B(PosBase + I);
    if Kind = dkSTR then
      Dec(Order[I]);
    Need((Order[I] >= 0) and (Order[I] < MaxPatterns), 'pattern index');
  end;
  List := TList<TDigitalRow>.Create;
  try
    for var Pattern in Order do
    begin
      var Rows := PatternRows;
      if Kind = dkET1 then
      begin
        Rows := B($86 + Pattern);
        Need((Rows > 0) and (Rows <= 64), 'ET pattern rows');
      end;
      for var R := 0 to Rows - 1 do
      begin
        Row := Default(TDigitalRow);
        for var C := 0 to 3 do
          Row.Cells[C] := TDigitalCell.Empty;
        var At := PatternBase + Pattern * PatternSize;
        RequireBytes(Data, At, PatternSize);
        var Finished := False;
        var IncludeEnd := True;
        for var C := 0 to Result.Channels - 1 do
        begin
          var N, V: Integer;
          case Kind of
            dkCHI:
              begin
                N := B(At + R * 4 + C);
                V := B(At + 256 + R * 4 + C);
              end;
            dkSTR:
              begin
                N := B(At + R * 6 + C);
                V := B(At + R * 6 + C + 3);
              end;
            dkDST:
              begin
                N := B(At + R * 6 + C * 2);
                V := B(At + R * 6 + C * 2 + 1);
              end;
            dkDMM:
              begin
                Row.Cells[C] := DMMCell(At + R * 9 + C * 3);
                if Row.Cells[C].RawNote = 62 then
                  Row.Tempo := Row.Cells[C].RawParam;
                Continue;
              end;
          else
            N := B(At + R * 8 + C * 2);
            V := B(At + R * 8 + C * 2 + 1);
          end;
          case Kind of
            dkCHI:
              begin
                if N shr 2 = 63 then
                  Row.Cells[C].Note := -2
                else if N shr 2 > 0 then
                begin
                  Row.Cells[C].Note := (N shr 2) - 1;
                  Row.Cells[C].Sample := V shr 4;
                end;
                case N and 3 of
                  0:
                    if V and 15 <> 0 then
                      Row.Cells[C].Offset := (V and 15) * 512;
                  1:
                    Row.Cells[C].Slide := -2 * (V and 15);
                  2:
                    Row.Cells[C].Slide := 2 * (V and 15);
                  3:
                    begin
                      if C = 0 then
                        Row.Tempo := V and 15;
                      if C = 3 then
                        Finished := True;
                    end;
                end;
              end;
            dkDST:
              begin
                if N = $80 then
                  Row.Cells[C].Note := -2
                else if N = $81 then
                  Row.Tempo := V
                else if N = $82 then
                  Finished := True
                else if N <> 0 then
                begin
                  Need(N < 128, 'DST note');
                  Row.Cells[C].Note := N - 1;
                  Row.Cells[C].Sample := V;
                end;
              end;
            dkSTR:
              begin
                if N = 255 then
                begin
                  Finished := True;
                  IncludeEnd := False;
                end
                else if N <> 0 then
                  Row.Cells[C].Note := N - 1;
                if V = $10 then
                  Row.Cells[C].Note := -2
                else if (V >= $25) and (V < $35) then
                  Row.Cells[C].Sample := V - $25;
              end;
            dkET1:
              begin
                Row.Cells[C].RawNote := N;
                Row.Cells[C].RawParam := V;
                if (N and 63) > 0 then
                begin
                  Need((N and 63) <= 48, 'ET note');
                  Row.Cells[C].Note := (N and 63) - 1;
                  Row.Cells[C].Sample := V and 15;
                end;
                case N shr 6 of
                  1:
                    if NewET then
                    begin
                      Row.Cells[C].Slide := V shr 4;
                      if Row.Cells[C].Slide > 8 then
                        Row.Cells[C].Slide := 8 - Row.Cells[C].Slide;
                      Row.Cells[C].Slide := Row.Cells[C].Slide * 2;
                    end
                    else
                      Row.Cells[C].Volume := V shr 4;
                  2:
                    Row.Tempo := V shr 4;
                  3:
                    Row.Cells[C].Note := -2;
                end;
              end;
            dkSQD:
              begin
                case N of
                  0:
                    ;
                  61:
                    Row.Cells[C].Note := -2;
                  62:
                    Row.Tempo := V;
                  63:
                    begin
                      Finished := True;
                      IncludeEnd := True;
                      Break;
                    end;
                  64:
                    begin
                      Row.Cells[C].RawNote := 64;
                      Row.Cells[C].RawParam := V;
                    end;
                else
                  Row.Cells[C].Note := (N and 63) - 1;
                  Row.Cells[C].Sample := V and 15;
                  Row.Cells[C].Volume := V shr 4;
                  Row.Cells[C].Slide := N shr 6;
                  if Row.Cells[C].Slide = 1 then
                    Row.Cells[C].Slide := -1
                  else if Row.Cells[C].Slide > 1 then
                    Row.Cells[C].Slide := 1;
                end;
              end;
            dkPDT:
              begin
                if N and 63 <> 0 then
                begin
                  Row.Cells[C].Note := (N and 63) - 1;
                  Row.Cells[C].Sample := V shr 4;
                end;
                case N shr 6 of
                  1:
                    Row.Tempo := V and 15;
                  0:
                    case V and 15 of
                      13:
                        begin
                          Finished := True;
                          IncludeEnd := False;
                        end;
                      14:
                        Row.Cells[C].Note := -2;
                      12:
                        Row.Cells[C].Sample := -1;
                      0:
                        if N and 63 <> 0 then
                          Row.Cells[C].Ornament := 0;
                      15:
                        Row.Cells[C].Ornament := 0;
                    else
                      Row.Cells[C].Ornament := V and 15;
                    end;
                end;
              end;
          end;
        end;
        if IncludeEnd then
        begin
          for var C := 0 to 3 do
            if Row.Cells[C].Sample >= 0 then
            begin
              Need(Row.Cells[C].Sample < 16, 'sample index');
              Used[Row.Cells[C].Sample] := True;
            end;
          List.Add(Row);
        end;
        if Finished then
          Break;
      end;
    end;
    Result.Rows := List.ToArray;
  finally
    List.Free;
  end;
  Need(Length(Result.Rows) > 0, 'empty song');
  // Sample addresses are converted to checked array offsets; no native pointers.
  case Kind of
    dkCHI:
      begin
        SampleBase := 512 + (MaxIntValue(Order) + 1) * 512;
        for var I := 0 to 15 do
        begin
          var Len := W(45 + I * 4);
          if Used[I] then
            Sample(I, SampleBase, Min(Len, Max(0, Length(Data) - SampleBase)), W(43 + I * 4), 0);
          Inc(SampleBase, (Len + 255) div 256 * 256);
        end;
      end;
    dkSTR:
      for var I := 0 to 15 do
        if Used[I] then
        begin
          var Addr := B($18DC + I * 2) * 256;
          var Len := B($18DD + I * 2) * 128;
          if (Addr >= $8C00) and (Addr + Len <= $FA00) then
            Sample(I, Addr - $7260, Min(Len, Max(0, Length(Data) - (Addr - $7260))), Len, 0, 0);
        end;
    dkET1:
      for var I := 0 to 15 do
        if Used[I] then
        begin
          var P := $100 + I * 16;
          var Addr := W(P);
          var Pg := B(P + 4) and 7;
          var Base := $C000;
          if Pg = 7 then
            Base := $8400;
          var Len := B(P + 6) * 256;
          if (ETOffsets[Pg] <> 0) and (Addr >= Base) and (Len > 0) and (Addr + Len <= 65536) then
            Sample(I, ETOffsets[Pg] + Addr - Base, Len, Max(0, W(P + 2) - Addr), 0, 0);
        end;
    dkPDT:
      for var I := 0 to 15 do
        if Used[I] then
        begin
          var P := $100 + I * 16;
          var Pg := B(P + 14);
          var Addr := W(P + 8);
          var Len := W(P + 10);
          if (Pg in [1, 3, 4, 6, 7]) and (Addr >= $C000) and (Len > 0) then
          begin
            var Start := $4300 + Pages[Pg] * $4000 + Addr - $C000;
            RequireBytes(Data, Start, Len);
            while (Len > 1) and (B(Start + Len - 1) = 0) do
              Dec(Len);
            Sample(I, Start, Len, Max(0, W(P + 12) - Addr), 0);
          end;
        end;
    dkSQD:
      begin
        var Offs: array[0..7] of Integer;
        var Sizes: array[0..7] of Integer;
        for var I := 0 to 7 do
        begin
          Offs[I] := 0;
          Sizes[I] := 0;
        end;
        var At := $4400;
        for var I := 0 to 7 do
        begin
          var P := $C0 + I * 4;
          var Len := B(P + 3) * 256;
          RequireBytes(Data, At, Len);
          Offs[B(P + 2) and 7] := At;
          Sizes[B(P + 2) and 7] := Len;
          Inc(At, Len);
        end;
        for var I := 0 to 15 do
          if Used[I] then
          begin
            var P := $120 + I * 8;
            var Addr := W(P);
            var Pg := B(P + 5) and 7;
            var Base := $C000;
            if Addr < $C000 then
              Base := $8000;
            if (Addr >= $8000) and (Offs[Pg] <> 0) then
            begin
              var Len := Min(65536 - Addr, Sizes[Pg] - (Addr - Base));
              Need(Len >= 0, 'SQD sample range');
              var Loop := Len;
              if B(P + 4) <> 0 then
                Loop := Max(0, W(P + 2) - Addr);
              Sample(I, Offs[Pg] + Addr - Base, Len, Loop, 0, 0);
            end;
          end;
      end;
    dkDMM:
      begin
        var Offs: array[0..7] of Integer;
        var Sizes: array[0..7] of Integer;
        for var I := 0 to 7 do
        begin
          Offs[I] := 0;
          Sizes[I] := 0;
        end;
        var At := B($44) * 256;
        for var I := 0 to 5 do
        begin
          var EndAt := W(I * 2);
          Need(EndAt >= $C000, 'DMM bank');
          if EndAt = $C000 then
            Continue;
          var Len := 256 * (1 + ((EndAt - $C000 + 255) div 256 * 256) div 512);
          RequireBytes(Data, At, Len);
          Offs[DMMBanks[I]] := At;
          Sizes[DMMBanks[I]] := Len;
          Inc(At, Len);
        end;
        for var I := 1 to 15 do
        begin
          var P := $5A + (I - 1) * 16;
          if B(P) = Ord('.') then
            Continue;
          var Addr := W(P + 9);
          var EndAt := W(P + 12);
          var Pg := B(P + 11) and 7;
          Need((Addr >= $C000) and (EndAt >= Addr) and ((B(P + 11) and $F8) = $50), 'DMM sample');
          var Len := EndAt - Addr;
          if Len >= 12 then
            Dec(Len, 12);
          Need((Offs[Pg] <> 0) and (EndAt - $C000 <= Sizes[Pg] * 2), 'DMM sample bank');
          var Loop := Len;
          if W(P + 14) >= Addr then
            Loop := W(P + 14) - Addr;
          Sample(I, Offs[Pg] + (Addr - $C000) div 2, Len div 2, Loop, 2);
        end;
      end;
    dkDST:
      begin
        var Raw: array[0..15] of TBytes;
        var Loops: array[0..15] of Integer;
        var Is4: array[0..15] of Boolean;
        FillChar(Loops, SizeOf(Loops), 0);
        FillChar(Is4, SizeOf(Is4), 0);
        var Count := 0;
        var Four := 0;
        for var I := 0 to 15 do
          if Used[I] then
          begin
            var P := $100 + I * 16;
            var Addr := W(P);
            var Len := W(P + 6);
            if Len = 0 then
              Continue;
            var Pg := B(P + 4) and 7;
            Need((DSTOffsets[Pg] <> 0) and (Addr >= $8000), 'DST sample bank');
            var Start := 0;
            if Addr < $C000 then
              Start := $200 + Addr - $8000
            else
            begin
              Start := DSTOffsets[Pg] + Addr - $C000;
              if Compiled and (Pg <> 0) then
                Inc(Start, $1000);
            end;
            Loops[I] := Max(0, W(P + 2) - Addr);
            var Available := Min(Len, $C000 - Max($8000, Addr));
            if Addr >= $C000 then
              Available := Len;
            RequireBytes(Data, Start, Available);
            Raw[I] := Copy(Data, Start, Available);
            if Available < Len then
            begin
              Start := DSTOffsets[Pg];
              if Compiled and (Pg <> 0) then
                Inc(Start, $1000);
              RequireBytes(Data, Start, Len - Available);
              Raw[I] := Raw[I] + Copy(Data, Start, Len - Available);
            end;
            var Size := 0;
            while (Size < Length(Raw[I])) and (Raw[I][Size] <> 255) do
              Inc(Size);
            SetLength(Raw[I], Size);
            var Found := 0;
            for var V in Raw[I] do
              if V and $F0 = $A0 then
                Inc(Found);
            Is4[I] := Found >= Size div 2;
            Inc(Count);
            if Is4[I] then
              Inc(Four);
          end;
        var AY := Four >= Count div 2;
        var Cycles := 356;
        if AY then
          Cycles := 344;
        Result.BaseRate := 3500000 * 88 div Cycles div 256;
        for var I := 0 to 15 do
        begin
          SetLength(Result.Samples[I].PCM, Length(Raw[I]));
          Result.Samples[I].Loop := Min(Loops[I], Length(Raw[I]));
          for var J := 0 to High(Raw[I]) do
            if AY and Is4[I] then
              Result.Samples[I].PCM[J] := AYLevels[Raw[I][J] and 15] div 2
            else
              Result.Samples[I].PCM[J] := (Integer(Raw[I][J]) - 128) * 256;
        end;
      end;
  end;
end;

end.

