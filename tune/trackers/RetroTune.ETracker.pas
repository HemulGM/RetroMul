unit RetroTune.ETracker;

interface

uses
  System.SysUtils;

type
  TSAARegisters = array[0..31] of Byte;

  TETrackerWrite = record
    RegisterID, Value: Byte;
  end;

  TETrackerFrame = TArray<TETrackerWrite>;

  TETrackerSong = record
    Frames: TArray<TETrackerFrame>;
  end;

function CompileETracker(const Data: TBytes): TETrackerSong;

implementation

uses
  System.Math, System.Generics.Collections, RetroTune.Binary;

type
  TSampleLine = record
    Tone, Noise, Left, Right: Integer;
    ToneOn, NoiseOn: Boolean;
  end;

  TSample = record
    Lines: TArray<TSampleLine>;
    Loop: Integer;
  end;

  TOrnament = record
    Notes: TArray<Integer>;
    Loop: Integer;
  end;

  TCell = record
    Note, Sample, Ornament, Attenuation, Swap, Envelope, Noise: Integer;
  end;

  TRow = record
    Cells: array[0..5] of TCell;
    Tempo, Transpose: Integer;
  end;

  TChannel = record
    Note, Sample, SamplePos, Ornament, OrnamentPos, Attenuation: Integer;
    Swap: Boolean;
  end;

function CompileETracker(const Data: TBytes): TETrackerSong;
const
  Notes: array[0..11] of Integer = ($05, $21, $3C, $55, $6D, $84, $99, $AD, $C0, $D2, $E3, $F3);
  Envelopes: array[0..12] of Byte = ($00, $96, $9E, $9A, $86, $8E, $8A, $97, $9F, $9B, $87, $8F, $8B);
var
  Rows: TList<TRow>;
  Frames: TList<TETrackerFrame>;
  Writes: TList<TETrackerWrite>;
  Samples: array[0..31] of TSample;
  Ornaments: array[0..31] of TOrnament;
  State: array[0..5] of TChannel;
  UsedS, UsedO: array[0..31] of Boolean;
  DecodeLengths: array[0..255] of Integer;
  Marker: Integer;
  Regs, Previous: TSAARegisters;
  Retrigger: array[0..1] of Boolean;
  NoiseType: array[0..1] of Integer;

  procedure Need(OK: Boolean; const S: string);
  begin
    if not OK then
      raise EArgumentException.Create('E-Tracker: ' + S);
  end;

  function ByteAt(P: Integer): Integer;
  begin
    RequireBytes(Data, P, 1);
    Result := Data[P];
  end;

  function Next(var P: Integer): Integer;
  begin
    Result := ByteAt(P);
    Inc(P);
  end;

  function EmptyCell: TCell;
  begin
    Result.Note := -1;
    Result.Sample := -1;
    Result.Ornament := -1;
    Result.Attenuation := -1;
    Result.Swap := -1;
    Result.Envelope := -1;
    Result.Noise := -1;
  end;

  procedure ReadSample(Index: Integer);
  var
    Lines: TList<TSampleLine>;
    Line: TSampleLine;
  begin
    var At := Integer(LE16(Data, LE16(Data, 4) + Index * 2));
    var Dev := 0;
    var Vol := 0;
    Lines := TList<TSampleLine>.Create;
    Line := Default(TSampleLine);
    Samples[Index].Loop := -1;
    try
      var Commands := 0;
      while True do
      begin
        Inc(Commands);
        Need(Commands <= 65536, 'sample control limit');
        if Dev = 0 then
        begin
          Dev := 1;
          var Done := False;
          while True do
          begin
            var V := Next(At);
            if V = 254 then
            begin
              Samples[Index].Loop := Lines.Count;
              Continue;
            end;
            if V = 252 then
            begin
              Done := True;
              Break;
            end;
            if V and 1 = 0 then
            begin
              Dev := 2 + (V shr 1);
              Continue;
            end
            else
            begin
              Line.ToneOn := V and 16 <> 0;
              Line.NoiseOn := V and 32 <> 0;
              Line.Noise := V shr 6;
              Line.Tone := ((V and 14) shl 7) or Next(At);
            end;
            Break;
          end;
          if Done then
            Break;
        end;
        if Vol = 0 then
        begin
          var V := Next(At);
          Vol := 1;
          if V = Marker then
          begin
            Vol := Next(At);
            V := Next(At);
          end
          else if DecodeLengths[V] <> 0 then
          begin
            Vol := DecodeLengths[V];
            V := Next(At);
          end;
          Line.Left := V and 15;
          Line.Right := V shr 4;
        end;
        var Count := Min(Dev, Vol);
        Need((Count > 0) and (Lines.Count + Count <= 4096), 'sample length/run');
        for var I := 1 to Count do
          Lines.Add(Line);
        Dec(Dev, Count);
        Dec(Vol, Count);
      end;
      Samples[Index].Lines := Lines.ToArray;
      if Samples[Index].Loop < 0 then
        Samples[Index].Loop := Lines.Count;
      Samples[Index].Loop := Min(Samples[Index].Loop, Lines.Count);
    finally
      Lines.Free;
    end;
  end;

  procedure ReadOrnament(Index: Integer);
  var
    Lines: TList<Integer>;
  begin
    var At := Integer(LE16(Data, LE16(Data, 6) + Index * 2));
    var Skip := 1;
    var Loop := -1;
    Lines := TList<Integer>.Create;
    try
      var Steps := 0;
      while True do
      begin
        Inc(Steps);
        Need(Steps <= 65536, 'ornament control limit');
        var V := Next(At);
        if V = 255 then
          Break;
        if V = 254 then
        begin
          Loop := Lines.Count;
          Continue;
        end;
        if V >= $60 then
        begin
          Skip := V + 2 - $60;
          Continue;
        end;
        Need(Lines.Count + Skip <= 4096, 'ornament length');
        for var I := 1 to Skip do
          Lines.Add(V);
        Skip := 1;
      end;
      Ornaments[Index].Notes := Lines.ToArray;
      if Loop < 0 then
        Loop := Lines.Count;
      Ornaments[Index].Loop := Min(Loop, Lines.Count);
    finally
      Lines.Free;
    end;
  end;

begin
  Result := Default(TETrackerSong);
  RequireBytes(Data, 0, 30);
  Need(TEncoding.ASCII.GetString(Data, 10, 8) = 'ETracker', 'signature');
  Need(Length(Data) <= $8000, 'module size');
  FillChar(UsedS, SizeOf(UsedS), 0);
  FillChar(UsedO, SizeOf(UsedO), 0);
  FillChar(DecodeLengths, SizeOf(DecodeLengths), 0);
  var At := Integer(LE16(Data, 8));
  Marker := Next(At);
  for var I := 0 to 255 do
  begin
    var Code := Next(At);
    if Code = 0 then
      Break;
    DecodeLengths[Code] := Next(At);
  end;
  Rows := TList<TRow>.Create;
  Frames := TList<TETrackerFrame>.Create;
  Writes := TList<TETrackerWrite>.Create;
  try
    At := LE16(Data, 0);
    var Transpose := 0;
    var Positions := 0;
    while True do
    begin
      var V := Next(At);
      if V = 255 then
        Break;
      if V = 254 then
        Continue;
      if V >= $60 then
      begin
        Transpose := V - $60;
        Continue;
      end;
      Need((V mod 3 = 0) and (V div 3 < 32), 'pattern number');
      Inc(Positions);
      Need(Positions <= 255, 'positions');
      var Cursor: array[0..5] of Integer;
      var Skip: array[0..5] of Integer;
      for var C := 0 to 5 do
      begin
        Cursor[C] := LE16(Data, LE16(Data, 2) + (V div 3) * 12 + C * 2);
        Need(Cursor[C] >= 28, 'pattern offset');
        Skip[C] := 0;
      end;
      var Added := 0;
      for var R := 0 to 63 do
      begin
        var EndPattern := False;
        for var C := 0 to 5 do
          if (Skip[C] = 0) and (ByteAt(Cursor[C]) = $51) then
            EndPattern := True;
        if EndPattern then
          Break;
        var Row: TRow;
        Row.Tempo := 0;
        Row.Transpose := Transpose;
        for var C := 0 to 5 do
        begin
          Row.Cells[C] := EmptyCell;
          if Skip[C] > 0 then
          begin
            Dec(Skip[C]);
            Continue;
          end;
          var Steps := 0;
          while True do
          begin
            Inc(Steps);
            Need(Steps <= 4096, 'pattern control limit');
            var Cmd := Next(Cursor[C]);
            if Cmd >= $D2 then
            begin
              Skip[C] := Cmd - $D2;
              Break;
            end;
            if Cmd >= $72 then
              Row.Cells[C].Note := Cmd - $72
            else if Cmd >= $52 then
            begin
              Row.Cells[C].Sample := Cmd - $52;
              UsedS[Cmd - $52] := True;
            end
            else if Cmd = $51 then
              Break
            else if Cmd = $50 then
              Row.Cells[C].Note := -2
            else if Cmd >= $30 then
            begin
              Row.Cells[C].Ornament := Cmd - $30;
              UsedO[Cmd - $30] := True;
            end
            else if Cmd >= $2E then
              Row.Cells[C].Swap := Ord(Cmd > $2E)
            else if Cmd >= $21 then
              Row.Cells[C].Envelope := Cmd - $21
            else if Cmd >= $11 then
              Row.Cells[C].Attenuation := Cmd - $11
            else if Cmd >= $0F then
            begin
              Row.Cells[C].Noise := 0;
              if Cmd <> $0F then
                Row.Cells[C].Noise := 3;
            end
            else
              Row.Tempo := Cmd + 1;
          end;
        end;
        Rows.Add(Row);
        Inc(Added);
      end;
      if Added = 0 then
      begin
        var Row: TRow;
        Row.Tempo := 0;
        Row.Transpose := Transpose;
        for var C := 0 to 5 do
          Row.Cells[C] := EmptyCell;
        Rows.Add(Row);
      end;
    end;
    Need(Positions > 0, 'empty positions');
    for var I := 0 to 31 do
    begin
      if UsedS[I] then
        ReadSample(I);
      if UsedO[I] then
        ReadOrnament(I);
    end;
    FillChar(State, SizeOf(State), 0);
    FillChar(Regs, SizeOf(Regs), 0);
    FillChar(Previous, SizeOf(Previous), 0);
    FillChar(NoiseType, SizeOf(NoiseType), 0);
    for var C := 0 to 5 do
      State[C].SamplePos := Length(Samples[0].Lines);
    Regs[$1C] := 1;
    var Tempo := 6;
    for var Row in Rows do
    begin
      Retrigger[0] := False;
      Retrigger[1] := False;
      if Row.Tempo > 0 then
        Tempo := Row.Tempo;
      for var C := 0 to 5 do
      begin
        var Cell := Row.Cells[C];
        if Cell.Note = -2 then
        begin
          State[C].SamplePos := Length(Samples[State[C].Sample].Lines);
          State[C].OrnamentPos := 0;
        end
        else if Cell.Note >= 0 then
        begin
          State[C].Note := Cell.Note;
          State[C].SamplePos := 0;
          State[C].OrnamentPos := 0;
        end;
        if Cell.Sample >= 0 then
        begin
          State[C].Sample := Cell.Sample;
          State[C].SamplePos := 0;
          State[C].OrnamentPos := 0;
        end;
        if Cell.Ornament >= 0 then
        begin
          State[C].Ornament := Cell.Ornament;
          State[C].OrnamentPos := 0;
        end;
        if Cell.Attenuation >= 0 then
          State[C].Attenuation := Cell.Attenuation;
        if Cell.Swap >= 0 then
          State[C].Swap := Cell.Swap <> 0;
        if Cell.Noise >= 0 then
          NoiseType[C div 3] := Cell.Noise;
        if Cell.Envelope >= 0 then
        begin
          Regs[$18 + C div 3] := Envelopes[Cell.Envelope];
          Retrigger[C div 3] := True;
        end;
      end;
      for var Tick := 0 to Tempo - 1 do
      begin
        Regs[$14] := 0;
        Regs[$15] := 0;
        Regs[$16] := 0;
        for var C := 0 to 5 do
        begin
          var S := State[C].Sample;
          var SP := State[C].SamplePos;
          var Line := Default(TSampleLine);
          if SP < Length(Samples[S].Lines) then
          begin
            Line := Samples[S].Lines[SP];
            Inc(State[C].SamplePos);
            if State[C].SamplePos = Length(Samples[S].Lines) then
              State[C].SamplePos := Samples[S].Loop;
          end;
          var O := State[C].Ornament;
          var OP := State[C].OrnamentPos;
          var Note := State[C].Note;
          if OP < Length(Ornaments[O].Notes) then
          begin
            Inc(Note, Ornaments[O].Notes[OP]);
            Inc(State[C].OrnamentPos);
            if State[C].OrnamentPos = Length(Ornaments[O].Notes) then
              State[C].OrnamentPos := Ornaments[O].Loop;
          end;
          var Tone := $7FF;
          if Note <> $5F then
          begin
            Inc(Note, Row.Transpose);
            if Note >= $100 then
              Dec(Note, $60);
            Tone := (Note div 12) * 256 + Notes[Note mod 12];
          end;
          Tone := (Tone + Line.Tone) and $7FF;
          Regs[8 + C] := Tone and 255;
          var Oct := (Tone shr 8) and 7;
          if Odd(C) then
            Regs[$10 + C div 2] := (Regs[$10 + C div 2] and 7) or (Oct shl 4)
          else
            Regs[$10 + C div 2] := (Regs[$10 + C div 2] and $70) or Oct;
          if Line.ToneOn then
            Regs[$14] := Regs[$14] or (1 shl C);
          if Line.NoiseOn then
            Regs[$15] := Regs[$15] or (1 shl C);
          if Line.NoiseOn or (C = 0) then
            Regs[$16] := (Regs[$16] and (not (3 shl ((C div 3) * 4)))) or (Line.Noise shl ((C div 3) * 4));
          var L := Line.Left;
          var R := Line.Right;
          if State[C].Swap then
          begin
            var Temp := L;
            L := R;
            R := Temp;
          end;
          Regs[C] := Max(0, L - State[C].Attenuation) or (Max(0, R - State[C].Attenuation) shl 4);
        end;
        Regs[$16] := Regs[$16] or NoiseType[0] or (NoiseType[1] shl 4);
        Writes.Clear;
        for var I := 0 to 31 do
          if (Regs[I] <> Previous[I]) or ((I in [$18, $19]) and (Tick = 0) and Retrigger[I - $18]) then
          begin
            var W: TETrackerWrite;
            W.RegisterID := I;
            W.Value := Regs[I];
            Writes.Add(W);
            Previous[I] := Regs[I];
          end;
        Frames.Add(Writes.ToArray);
        Need(Frames.Count <= 90000, 'song frame limit');
      end;
    end;
    Result.Frames := Frames.ToArray;
  finally
    Writes.Free;
    Frames.Free;
    Rows.Free;
  end;
end;

end.

