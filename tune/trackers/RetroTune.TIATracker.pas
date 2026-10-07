unit RetroTune.TIATracker;

interface

uses
  System.SysUtils;

type
  TTIATrackFrame = array[0..5] of Byte;

  TTIATrack = record
    Frames: TArray<TTIATrackFrame>;
    Title, Artist, Comment: string;
    Rate: Integer;
  end;

function CompileTIATracker(const Data: TBytes): TTIATrack;

implementation

uses
  System.JSON, System.Math, System.Generics.Collections;

type
  TNote = record
    Kind, Index, Value: Integer;
  end;

  TPattern = record
    Notes: TArray<TNote>;
    OddSpeed, EvenSpeed: Integer;
  end;

  TEnvelope = record
    Volume, Frequency, Wave: TArray<Integer>;
    Sustain, Release: Integer;
    Overlay: Boolean;
  end;

  TEntry = record
    Pattern, Jump: Integer;
  end;

  TVoice = record
    Entry, Row, Envelope: Integer;
    Note: TNote;
    Overlay, Released: Boolean;
  end;

function CompileTIATracker(const Data: TBytes): TTIATrack;
const
  NoteKinds: array[0..4] of Integer = (2, 0, 3, 1, 4);
var
  Root: TJSONObject;
  Patterns: TArray<TPattern>;
  Instruments, Percussion: TArray<TEnvelope>;
  Sequence: array[0..1] of TArray<TEntry>;
  Seen: array[0..1] of TArray<Boolean>;
  Voice: array[0..1] of TVoice;
  Finished, GlobalSpeed: Boolean;
  Frames: TList<TTIATrackFrame>;
  OddSpeed, EvenSpeed: Integer;

  procedure Need(B: Boolean; const S: string);
  begin
    if not B then
      raise EArgumentException.Create('TIATracker: ' + S);
  end;

  function Obj(V: TJSONValue): TJSONObject;
  begin
    Need(V is TJSONObject, 'expected object');
    Result := TJSONObject(V);
  end;

  function Arr(O: TJSONObject; const N: string; Min, Max: Integer): TJSONArray;
  begin
    var V := O.GetValue(N);
    Need(V is TJSONArray, 'expected array ' + N);
    Result := TJSONArray(V);
    Need((Result.Count >= Min) and (Result.Count <= Max), 'array length ' + N);
  end;

  function Num(O: TJSONObject; const N: string; Min, Max: Integer): Integer;
  begin
    var V := O.GetValue(N);
    Need(V is TJSONNumber, 'expected integer ' + N);
    Need(TryStrToInt(V.Value, Result), 'integer ' + N);
    Need((Result >= Min) and (Result <= Max), 'range ' + N);
  end;

  function Text(O: TJSONObject; const N: string): string;
  begin
    var V := O.GetValue(N);
    if V = nil then
      Exit('');
    Need(V is TJSONString, 'expected text ' + N);
    Result := V.Value;
  end;

  function Flag(O: TJSONObject; const N: string): Boolean;
  begin
    var V := O.GetValue(N);
    Need((V is TJSONTrue) or (V is TJSONFalse), 'expected boolean ' + N);
    Result := V is TJSONTrue;
  end;

  procedure Envelope(O: TJSONObject; out E: TEnvelope; IsPercussion: Boolean);
  begin
    var Len := Num(O, 'envelopeLength', 1, 256);
    var V := Arr(O, 'volumes', Len, Len);
    var F := Arr(O, 'frequencies', Len, Len);
    SetLength(E.Volume, Len);
    SetLength(E.Frequency, Len);
    SetLength(E.Wave, Len);
    var W: TJSONArray := nil;
    var Wave := 0;
    if IsPercussion then
    begin
      W := Arr(O, 'waveforms', Len, Len);
      E.Overlay := Flag(O, 'overlay');
    end
    else
    begin
      Wave := Num(O, 'waveform', 0, 16);
      E.Sustain := Num(O, 'sustainStart', 0, Len - 1);
      E.Release := Num(O, 'releaseStart', 1, Len - 1);
      Need(E.Sustain < E.Release, 'sustain/release');
    end;
    for var I := 0 to Len - 1 do
    begin
      Need(TryStrToInt(V.Items[I].Value, E.Volume[I]) and (E.Volume[I] >= 0) and (E.Volume[I] <= 15), 'volume');
      Need(TryStrToInt(F.Items[I].Value, E.Frequency[I]) and (E.Frequency[I] >= -128) and (E.Frequency[I] <= 255), 'frequency');
      E.Wave[I] := Wave;
      if IsPercussion then
        Need(TryStrToInt(W.Items[I].Value, E.Wave[I]) and (E.Wave[I] >= 0) and (E.Wave[I] <= 15), 'waveform');
    end;
  end;

  procedure forward(C: Integer);
  begin
    Inc(Voice[C].Row);
    if Voice[C].Row < Length(Patterns[Sequence[C][Voice[C].Entry].Pattern].Notes) then
      Exit;
    var Next := Sequence[C][Voice[C].Entry].Jump;
    if Next < 0 then
      Next := Voice[C].Entry + 1;
    if (Next >= Length(Sequence[C])) or Seen[C][Next] then
    begin
      Finished := True;
      Exit;
    end;
    Seen[C][Next] := True;
    Voice[C].Entry := Next;
    Voice[C].Row := 0;
  end;

  procedure ReadNote(C: Integer; Sustain: Boolean = False);
  begin
    var N := Patterns[Sequence[C][Voice[C].Entry].Pattern].Notes[Voice[C].Row];
    case N.Kind of
      0, 1:
        begin
          Voice[C].Note := N;
          Voice[C].Envelope := 0;
          Voice[C].Released := False;
          if Sustain and (N.Kind = 0) then
            Voice[C].Envelope := Instruments[N.Index].Sustain;
        end;
      3:
        if Voice[C].Note.Kind = 0 then
        begin
          Voice[C].Envelope := Instruments[Voice[C].Note.Index].Release;
          Voice[C].Released := True;
        end;
      4:
        if Voice[C].Note.Kind = 0 then
          Voice[C].Note.Value := (Voice[C].Note.Value + N.Value) and 63;
    end;
  end;

begin
  Result := Default(TTIATrack);
  Need((Length(Data) > 2) and (Length(Data) <= 1024 * 1024), 'module size');
  // Bound nesting before invoking the recursive JSON parser.
  var Depth := 0;
  var Quoted := False;
  var Escape := False;
  for var B in Data do
  begin
    if Quoted then
    begin
      if Escape then
        Escape := False
      else if B = 92 then
        Escape := True
      else if B = 34 then
        Quoted := False;
    end
    else if B = 34 then
      Quoted := True
    else if B in [91, 123] then
    begin
      Inc(Depth);
      Need(Depth <= 32, 'JSON nesting');
    end
    else if B in [93, 125] then
      Dec(Depth);
  end;
  var Value := TJSONObject.ParseJSONValue(TEncoding.UTF8.GetString(Data));
  try
    Root := Obj(Value);
    Need(Num(Root, 'version', 1, 1) = 1, 'version');
    Result.Title := Text(Root, 'metaName');
    Result.Artist := Text(Root, 'metaAuthor');
    Result.Comment := Text(Root, 'metaComment');
    var TV := Text(Root, 'tvmode');
    Need((TV = 'pal') or (TV = 'ntsc'), 'TV mode');
    Result.Rate := 50;
    if TV = 'ntsc' then
      Result.Rate := 60;
    GlobalSpeed := Flag(Root, 'globalspeed');
    OddSpeed := Num(Root, 'oddspeed', 1, 255);
    EvenSpeed := Num(Root, 'evenspeed', 1, 255);
    var A := Arr(Root, 'instruments', 1, 7);
    SetLength(Instruments, A.Count);
    for var I := 0 to A.Count - 1 do
      Envelope(Obj(A.Items[I]), Instruments[I], False);
    A := Arr(Root, 'percussion', 1, 15);
    SetLength(Percussion, A.Count);
    for var I := 0 to A.Count - 1 do
      Envelope(Obj(A.Items[I]), Percussion[I], True);
    A := Arr(Root, 'patterns', 1, 256);
    SetLength(Patterns, A.Count);
    for var I := 0 to A.Count - 1 do
    begin
      var O := Obj(A.Items[I]);
      Patterns[I].OddSpeed := Num(O, 'oddspeed', 1, 255);
      Patterns[I].EvenSpeed := Num(O, 'evenspeed', 1, 255);
      var Notes := Arr(O, 'notes', 1, 256);
      SetLength(Patterns[I].Notes, Notes.Count);
      for var J := 0 to Notes.Count - 1 do
      begin
        O := Obj(Notes.Items[J]);
        var N: TNote;
        N.Kind := NoteKinds[Num(O, 'type', 0, 4)];
        N.Index := Num(O, 'number', 0, 22);
        N.Value := Num(O, 'value', -31, 63);
        if N.Kind = 0 then
          Need((N.Index < Length(Instruments)) and (N.Value >= 0), 'instrument note');
        if N.Kind = 1 then
          Need(N.Index < Length(Percussion), 'percussion note');
        Patterns[I].Notes[J] := N;
      end;
    end;
    A := Arr(Root, 'channels', 2, 2);
    for var C := 0 to 1 do
    begin
      var Entries := Arr(Obj(A.Items[C]), 'sequence', 1, 256);
      SetLength(Sequence[C], Entries.Count);
      SetLength(Seen[C], Entries.Count);
      for var I := 0 to Entries.Count - 1 do
      begin
        var O := Obj(Entries.Items[I]);
        Sequence[C][I].Pattern := Num(O, 'patternindex', 0, High(Patterns));
        Sequence[C][I].Jump := Num(O, 'gototarget', -1, Entries.Count - 1);
      end;
      Voice[C] := Default(TVoice);
      Voice[C].Note.Kind := 2;
      Seen[C][0] := True;
    end;
    Frames := TList<TTIATrackFrame>.Create;
    try
      Finished := False;
      var First := True;
      var Tick := 0;
      while not Finished do
      begin
        if Tick = 0 then
        begin
          for var C := 0 to 1 do
          begin
            if not First and not Voice[C].Overlay then
              forward(C);
            if Finished then
              Break;
            if not Voice[C].Overlay then
              ReadNote(C);
            Voice[C].Overlay := False;
          end;
          if Finished then
            Break;
          First := False;
          var P := Patterns[Sequence[0][Voice[0].Entry].Pattern];
          if GlobalSpeed then
          begin
            P.OddSpeed := OddSpeed;
            P.EvenSpeed := EvenSpeed;
          end;
          Tick := P.OddSpeed;
          if Odd(Voice[0].Row) then
            Tick := P.EvenSpeed;
        end;
        var Frame: TTIATrackFrame;
        FillChar(Frame, SizeOf(Frame), 0);
        for var C := 0 to 1 do
        begin
          var S := Voice[C];
          var E: TEnvelope;
          if S.Note.Kind = 0 then
            E := Instruments[S.Note.Index]
          else if S.Note.Kind = 1 then
            E := Percussion[S.Note.Index]
          else
            Continue;
          if S.Envelope >= Length(E.Volume) then
            Continue;
          var Wave := E.Wave[S.Envelope];
          var Frequency := E.Frequency[S.Envelope];
          if S.Note.Kind = 0 then
          begin
            if Wave = 16 then
            begin
              Wave := 4;
              if S.Note.Value >= 32 then
                Wave := 12;
            end;
            Inc(Frequency, S.Note.Value and 31);
          end;
          Frame[C] := Wave;
          Frame[2 + C] := Frequency and 31;
          Frame[4 + C] := E.Volume[S.Envelope];
          Inc(Voice[C].Envelope);
          if (S.Note.Kind = 0) and not S.Released and (Voice[C].Envelope = E.Release) then
            Voice[C].Envelope := E.Sustain;
          if (S.Note.Kind = 1) and E.Overlay and (Voice[C].Envelope = Length(E.Volume)) then
          begin
            forward(C);
            if not Finished then
            begin
              Voice[C].Overlay := True;
              ReadNote(C, True);
            end;
          end;
        end;
        Frames.Add(Frame);
        Need(Frames.Count <= 90000, 'frame limit');
        Dec(Tick);
      end;
      Need(Frames.Count > 0, 'empty song');
      Result.Frames := Frames.ToArray;
    finally
      Frames.Free;
    end;
  finally
    Value.Free;
  end;
end;

end.

