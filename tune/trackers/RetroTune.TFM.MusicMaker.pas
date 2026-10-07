unit RetroTune.TFM.MusicMaker;

interface

uses
  System.SysUtils, RetroTune.TFM.Stream;

function ParseTFMMusicMaker(const Source: TBytes; Extended: Boolean): TTFMStream;

implementation

uses
  System.Math, System.Generics.Collections, RetroTune.Binary;

type
  TCell = record
    Note, Volume, Instrument: Integer;
    Code, Param: array[0..3] of Integer;
  end;

  TChannel = record
    Instrument, Algorithm, Note, Volume, Target, PortaStep: Integer;
    TL: array[0..3] of Integer;
    Arp: array[0..2] of Integer;
    ArpPosition, VibPosition, VibSpeed, VibDepth, VibValue: Integer;
    ToneUp, ToneDown, VolumeUp, VolumeDown: Integer;
    ToneActive, VolumeActive, VibActive, PortaActive: Boolean;
    Retrig, Cut, Delay: Integer;
  end;

  TCursor = record
    Position, Row, EvenSpeed, OddSpeed, Interleave, TempoCounter: Integer;
  end;

function Unpack(const Source: TBytes; Extended: Boolean): TBytes;
var
  Size, Input, Output, Last, Count, Shift, V: Integer;
begin
  if Extended then
  begin
    Size := 4341209;
    Input := 8;
  end
  else
  begin
    Size := 1981904;
    Input := 0;
  end;
  RequireBytes(Source, 0, Input);
  if Extended and (TEncoding.ASCII.GetString(Source, 0, 8) <> 'TFMfmtV2') then
    raise EArgumentException.Create('Invalid TFE signature');
  SetLength(Result, Size);
  Output := Input;
  for var I := 0 to Input - 1 do
    Result[I] := Source[I];
  Last := -1;
  while Output < Size do
  begin
    RequireBytes(Source, Input, 1);
    V := Source[Input];
    Inc(Input);
    if V <> $80 then
    begin
      Last := V;
      Result[Output] := V;
      Inc(Output);
    end
    else
    begin
      Count := 0;
      Shift := 0;
      repeat
        RequireBytes(Source, Input, 1);
        V := Source[Input];
        Inc(Input);
        if Shift > 21 then
          raise EArgumentException.Create('TFM repeat counter too large');
        Count := Count or ((V and 127) shl Shift);
        Inc(Shift, 7);
      until V and 128 <> 0;
      if Count = 0 then
      begin
        Result[Output] := $80;
        Inc(Output);
      end
      else
      begin
        if (Count < 2) or (Last < 0) or (Count - 1 > Size - Output) then
          raise EArgumentException.Create('Invalid TFM RLE sequence');
        for var I := 1 to Count - 1 do
        begin
          Result[Output] := Last;
          Inc(Output);
        end;
        Last := -1;
      end;
    end;
  end;
  // Some editor revisions append settings after the compressed module image.
end;

function ParseTFMMusicMaker(const Source: TBytes; Extended: Boolean): TTFMStream;
const
  Freqs: array[0..13] of Integer = (707, 749, 793, 840, 890, 943, 999, 1059, 1122, 1189, 1259, 1334, 1413, 1497);
  Sines: array[0..31] of Integer = (0, 49, 97, 142, 181, 212, 236, 251, 256, 251, 236, 212, 181, 142, 97, 49,
    0, -49, -97, -142, -181, -212, -236, -251, -256, -251, -236, -212, -181, -142, -97, -49);
  Carriers: array[0..7] of Integer = (8, 8, 8, 8, 12, 14, 14, 15);
  Levels: array[0..31] of Integer = (0, 0, $58, $5A, $5B, $5D, $5F, $60, $61, $62, $64, $66, $68, $6A, $6B, $6D,
    $6E, $70, $71, $72, $73, $74, $76, $77, $78, $79, $7A, $7B, $7C, $7D, $7E, $7F);
var
  Data: TBytes;
  State: array[0..5] of TChannel;
  Cells: array[0..5] of TCell;
  Frames: TList<TTFMFrame>;
  Writes: TList<TTFMWrite>;
  Cursor, LoopStart, NextCursor: TCursor;
  Header, Positions, Instruments, PatternSizes, Patterns, ChannelSize, PatternSize, PositionCount: Integer;
  SpecialMode, LoopSet, Jump: Boolean;
  LoopCount, Pattern, Rows, Quirk, Tempo, ArpValue: Integer;
  ToneOffsets: array[0..3] of Integer;

  procedure Need(OK: Boolean; const S: string);
  begin
    if not OK then
      raise EArgumentException.Create('TFM: ' + S);
  end;

  procedure Write(Ch, Reg, Value: Integer);
  begin
    Writes.Add(TTFMWrite.Make(Ch div 3, Reg, Value and 255));
  end;

  procedure ChannelReg(Ch, Reg, Value: Integer);
  begin
    Write(Ch, Reg + Ch mod 3, Value);
  end;

  procedure OpReg(Ch, Op, Reg, Value: Integer);
  begin
    ChannelReg(Ch, Reg + Op * 4, Value);
  end;

  procedure Key(Ch, Mask: Integer);
  begin
    Write(Ch, $28, (Ch mod 3) or (Mask shl 4));
  end;

  procedure Frequency(Ch, Note, Op: Integer);
  begin
    Note := EnsureRange(Note, 0, $BFF);
    var Half := Note div 32;
    var N := Half mod 12;
    var F := Freqs[N] + (Freqs[N + 1] - Freqs[N]) * (Note mod 32) div 32;
    if Op = 0 then
    begin
      ChannelReg(Ch, $A4, (Half div 12) * 8 + (F shr 8));
      ChannelReg(Ch, $A0, F and 255);
    end
    else
    begin
      var Reg := $AC;
      if Op = 2 then
        Reg := $AE
      else if Op = 3 then
        Reg := $AD;
      Write(Ch, Reg, (Half div 12) * 8 + (F shr 8));
      Write(Ch, Reg - 4, F and 255);
    end;
  end;

  procedure LoadInstrument(Ch, Ins: Integer; const Cell: TCell);
  begin
    Need((Ins > 0) and (Ins <= 255), 'instrument index');
    var Offset := Instruments + (Ins - 1) * 42;
    State[Ch].Instrument := Ins;
    State[Ch].Algorithm := Data[Offset];
    Need(State[Ch].Algorithm < 8, 'instrument algorithm');
    Need(Data[Offset + 1] < 8, 'instrument feedback');
    ChannelReg(Ch, $B0, Data[Offset] or (Data[Offset + 1] shl 3));
    for var Op := 0 to 3 do
    begin
      var O := Offset + 2 + Op * 10;
      var Multiple := Integer(Data[O]);
      for var E := 0 to 3 do
        if (Cell.Code[E] = 14) and (Cell.Param[E] shr 4 = Op) then
          Multiple := Cell.Param[E] and 15;
      var Detune := Integer(Data[O + 1]);
      if Detune >= 128 then
        Dec(Detune, 256);
      Need((Detune >= -3) and (Detune <= 3) and (Multiple < 16), 'detune/multiplier');
      if Detune < 0 then
        Detune := 4 - Detune;
      OpReg(Ch, Op, $30, (Detune shl 4) or Multiple);
      State[Ch].TL[Op] := Data[O + 2] xor 127;
      var Invert := 0;
      if Extended then
        Invert := 31;
      Need(Data[O + 3] < 4, 'rate scaling');
      OpReg(Ch, Op, $50, (Data[O + 3] shl 6) or (Data[O + 4] xor Invert));
      OpReg(Ch, Op, $60, Data[O + 5] xor Invert);
      OpReg(Ch, Op, $70, Data[O + 6] xor Invert);
      if Extended then
        Invert := 15;
      OpReg(Ch, Op, $80, (Data[O + 8] shl 4) or (Data[O + 7] xor Invert));
      OpReg(Ch, Op, $90, Data[O + 9]);
    end;
  end;

  function ReadCell(Ch: Integer): TCell;
  begin
    Result := Default(TCell);
    var Offset := Patterns + Pattern * PatternSize + Ch * ChannelSize + Cursor.Row;
    Result.Note := Data[Offset] xor 255;
    Result.Volume := Data[Offset + 256];
    Result.Instrument := Data[Offset + 512];
    Need(Result.Volume <= 31, 'volume');
    for var E := 0 to 3 do
      Result.Code[E] := 7;
    var Count := 1;
    if Extended then
      Count := 4;
    for var E := 0 to Count - 1 do
    begin
      Result.Code[E] := Data[Offset + 768 + E * 512];
      Result.Param[E] := Data[Offset + 1024 + E * 512];
      Need(Result.Code[E] <= 15, 'effect');
    end;
    if not Extended and (Result.Code[0] = 11) and (Result.Param[0] <> 0) then
    begin
      var P := Result.Param[0];
      for var E := 0 to 3 do
        Result.Code[E] := 11;
      Result.Param[0] := 1;
      Result.Param[1] := 16 or (P shr 4);
      Result.Param[2] := 32 or (P and 15);
      Result.Param[3] := $3C;
    end;
  end;

  procedure Controls(const Cell: TCell);
  begin
    for var E := 0 to 3 do
    begin
      var Code := Cell.Code[E];
      var P := Cell.Param[E];
      var X := P shr 4;
      var Y := P and 15;
      if Code = 15 then
      begin
        if X <> 0 then
        begin
          Cursor.EvenSpeed := X;
          Cursor.OddSpeed := Y;
        end
        else
          Cursor.Interleave := Y;
      end
      else if (Code = 14) and (X = 6) then
      begin
        if Y = 0 then
        begin
          if not LoopSet or (LoopStart.Position <> Cursor.Position) or (LoopStart.Row <> Cursor.Row) then
          begin
            LoopStart := Cursor;
            LoopSet := True;
            LoopCount := 0;
          end;
        end
        else if LoopSet and (LoopCount < Y) then
        begin
          Inc(LoopCount);
          if LoopCount >= Y then
            LoopCount := 16;
          NextCursor := LoopStart;
          Jump := True;
        end;
      end;
    end;
  end;

  procedure NewRow(Ch: Integer; const Cell: TCell);
  begin
    State[Ch].ToneActive := False;
    State[Ch].VolumeActive := False;
    State[Ch].VibActive := False;
    State[Ch].PortaActive := False;
    State[Ch].Retrig := -1;
    State[Ch].Cut := -1;
    State[Ch].Delay := -1;
    var Portamento := False;
    var Mixer := False;
    var Drop := False;
    for var E := 0 to 3 do
    begin
      var Code := Cell.Code[E];
      var P := Cell.Param[E];
      var X := P shr 4;
      var Y := P and 15;
      if Code in [3, 5] then
        Portamento := True;
      if Code = 11 then
      begin
        if X = 0 then
        begin
          SpecialMode := Y <> 0;
          Write(2, $27, Ord(SpecialMode) * $40);
        end
        else
        begin
          Need(X < 4, 'special-mode operator');
          ToneOffsets[X] := Y;
        end;
      end
      else if Code = 14 then
        case X of
          5:
            Mixer := True;
          8:
            case Y of
              1:
                ChannelReg(Ch, $B4, $80);
              2:
                ChannelReg(Ch, $B4, $40);
            else
              ChannelReg(Ch, $B4, $C0);
            end;
          9:
            if Y <> 0 then
              State[Ch].Retrig := Y;
          12:
            if Y <> 0 then
              State[Ch].Cut := Y;
          13:
            if Y <> 0 then
              State[Ch].Delay := Y;
          14:
            Drop := True;
        end;
    end;
    if Cell.Note = 254 then
      Key(Ch, 0)
    else if Cell.Note <> 255 then
    begin
      Need((Cell.Note >= 12) and (Cell.Note <= 107), 'note');
      if not Portamento then
        Key(Ch, 0);
      var Ins := Cell.Instrument;
      if (Ins = 0) and (State[Ch].Instrument = 0) then
        Ins := 1;
      if Drop and (Ins = 0) then
        Ins := State[Ch].Instrument;
      if (Ins <> 0) and ((Ins <> State[Ch].Instrument) or Drop) then
        LoadInstrument(Ch, Ins, Cell);
      if Portamento then
        State[Ch].Target := (Cell.Note - 12) * 32
      else
      begin
        State[Ch].Note := (Cell.Note - 12) * 32;
        for var I := 0 to 2 do
          State[Ch].Arp[I] := 0;
        State[Ch].ArpPosition := 0;
        State[Ch].VibValue := 0;
        if (State[Ch].Delay < 0) and not Mixer then
          Key(Ch, 15);
      end;
    end;
    if Cell.Volume <> 0 then
      State[Ch].Volume := Cell.Volume * 8;
    for var E := 0 to 3 do
    begin
      var Code := Cell.Code[E];
      var P := Cell.Param[E];
      var X := P shr 4;
      var Y := P and 15;
      case Code of
        0:
          if P <> 0 then
          begin
            if P = $FF then
            begin
              State[Ch].Arp[1] := 0;
              State[Ch].Arp[2] := 0;
            end
            else
            begin
              State[Ch].Arp[1] := X;
              State[Ch].Arp[2] := Y;
            end;
          end;
        1, 2:
          begin
            State[Ch].ToneActive := True;
            if P <> 0 then
              if Code = 1 then
                State[Ch].ToneUp := P
              else
                State[Ch].ToneDown := -P;
          end;
        3, 5:
          begin
            State[Ch].PortaActive := True;
            if (Code = 3) and (P <> 0) then
              State[Ch].PortaStep := P;
          end;
        4, 6:
          begin
            State[Ch].VibActive := True;
            if Code = 4 then
            begin
              if X <> 0 then
                State[Ch].VibSpeed := X;
              if Y <> 0 then
                State[Ch].VibDepth := Y * 2;
              if P <> 0 then
              begin
                State[Ch].VibPosition := 0;
                State[Ch].VibValue := 0;
              end;
            end;
          end;
        8, 9:
          State[Ch].TL[Code - 8] := P and 127;
        12, 13:
          State[Ch].TL[Code - 10] := P and 127;
        14:
          case X of
            0..3:
              if State[Ch].Instrument <> 0 then
              begin
                var O := Instruments + (State[Ch].Instrument - 1) * 42 + 2 + X * 10;
                var D := Integer(Data[O + 1]);
                if D >= 128 then
                  Dec(D, 256);
                if D < 0 then
                  D := 4 - D;
                OpReg(Ch, X, $30, (D shl 4) or Y);
              end;
            5:
              Key(Ch, Y);
            15:
              if State[Ch].Algorithm >= 0 then
                ChannelReg(Ch, $B0, State[Ch].Algorithm or (Y shl 3));
          end;
      end;
      if Code in [5, 6, 10] then
      begin
        State[Ch].VolumeActive := True;
        if X <> 0 then
          State[Ch].VolumeUp := X;
        if Y <> 0 then
          State[Ch].VolumeDown := -Y;
      end;
    end;
  end;

  procedure Synthesize(Ch: Integer);
  begin
    if State[Ch].PortaActive and (State[Ch].Target >= 0) then
    begin
      if State[Ch].Target > State[Ch].Note then
        State[Ch].Note := Min(State[Ch].Target, State[Ch].Note + State[Ch].PortaStep)
      else
        State[Ch].Note := Max(State[Ch].Target, State[Ch].Note - State[Ch].PortaStep);
    end;
    if not State[Ch].VibActive then
    begin
      if State[Ch].VibValue <> 0 then
        State[Ch].VibPosition := 0;
      State[Ch].VibValue := 0;
    end;
    if State[Ch].VibActive then
    begin
      State[Ch].VibValue := Sines[State[Ch].VibPosition div 2] * State[Ch].VibDepth div 256;
      State[Ch].VibPosition := (State[Ch].VibPosition + State[Ch].VibSpeed) and 63;
    end;
    if State[Ch].ToneActive then
    begin
      State[Ch].Note := Min($BFF, State[Ch].Note + State[Ch].ToneUp);
      State[Ch].Note := Max(0, State[Ch].Note + State[Ch].ToneDown);
    end;
    ArpValue := State[Ch].Arp[State[Ch].ArpPosition] * 32;
    State[Ch].ArpPosition := (State[Ch].ArpPosition + 1) mod 3;
    if State[Ch].Note >= 0 then
    begin
      var Note := State[Ch].Note + ArpValue + State[Ch].VibValue;
      Frequency(Ch, Note, 0);
      if (Ch = 2) and SpecialMode then
        for var Op := 1 to 3 do
          Frequency(Ch, Note + ToneOffsets[Op] * 32, Op);
    end;
    if State[Ch].VolumeActive then
    begin
      State[Ch].Volume := Min(248, State[Ch].Volume + State[Ch].VolumeUp);
      State[Ch].Volume := Max(0, State[Ch].Volume + State[Ch].VolumeDown);
    end;
    if State[Ch].Algorithm >= 0 then
      for var Op := 0 to 3 do
      begin
        var TL := State[Ch].TL[Op];
        if Carriers[State[Ch].Algorithm] and (1 shl Op) <> 0 then
          TL := 127 - (127 - TL) * Levels[State[Ch].Volume div 8] div 127;
        OpReg(Ch, Op, $40, TL);
      end;
    if (State[Ch].Retrig > 0) and (Quirk mod State[Ch].Retrig = 0) then
    begin
      Key(Ch, 0);
      Key(Ch, 15);
    end;
    if Quirk = State[Ch].Cut then
      Key(Ch, 0);
    if Quirk = State[Ch].Delay then
    begin
      Key(Ch, 0);
      Key(Ch, 15);
    end;
  end;

begin
  Result := Default(TTFMStream);
  Result.Rate := 50;
  Data := Unpack(Source, Extended);
  Header := 10;
  if Extended then
    Header := 19;
  Positions := Header + 512;
  Instruments := Positions + 256 + 255 * 16;
  PatternSizes := Instruments + 255 * 42;
  Patterns := PatternSizes + 256;
  ChannelSize := 1280;
  if Extended then
    ChannelSize := 2816;
  PatternSize := ChannelSize * 6;
  Result.Author := TextField(Data, Header, 64);
  Result.Title := TextField(Data, Header + 64, 64);
  Result.Comment := TextField(Data, Header + 128, 384);
  Cursor := Default(TCursor);
  if Extended then
  begin
    Cursor.EvenSpeed := Data[8];
    Cursor.OddSpeed := Data[9];
    Cursor.Interleave := Data[10];
    PositionCount := Data[11];
  end
  else
  begin
    Cursor.EvenSpeed := Data[0] shr 4;
    Cursor.OddSpeed := Data[0] and 15;
    Cursor.Interleave := Data[1];
    PositionCount := Data[2];
  end;
  if PositionCount = 0 then
    PositionCount := 256;
  Need((Cursor.EvenSpeed > 0) and (Cursor.OddSpeed > 0) and (Cursor.Interleave > 0), 'initial tempo');
  for var Ch := 0 to 5 do
  begin
    State[Ch] := Default(TChannel);
    State[Ch].Algorithm := -1;
    State[Ch].Note := -1;
    State[Ch].Volume := 248;
    State[Ch].Target := -1;
  end;
  SpecialMode := False;
  LoopSet := False;
  LoopCount := 0;
  for var Op := 0 to 3 do
    ToneOffsets[Op] := 0;
  Frames := TList<TTFMFrame>.Create;
  Writes := TList<TTFMWrite>.Create;
  try
    while Cursor.Position < PositionCount do
    begin
      Pattern := Data[Positions + Cursor.Position];
      Rows := Data[PatternSizes + Pattern];
      Need(Rows > 0, 'empty pattern in order');
      Jump := False;
      for var Ch := 0 to 5 do
      begin
        Cells[Ch] := ReadCell(Ch);
        Controls(Cells[Ch]);
      end;
      Need((Cursor.EvenSpeed > 0) and (Cursor.OddSpeed > 0) and (Cursor.Interleave > 0), 'tempo effect');
      Tempo := Cursor.EvenSpeed;
      if Cursor.TempoCounter >= Cursor.Interleave then
        Tempo := Cursor.OddSpeed;
      for Quirk := 0 to Tempo - 1 do
      begin
        Writes.Clear;
        if Quirk = 0 then
          for var Ch := 0 to 5 do
            NewRow(Ch, Cells[Ch]);
        for var Ch := 0 to 5 do
          Synthesize(Ch);
        Need(Frames.Count < 90000, 'song exceeds 30 minutes');
        Frames.Add(Writes.ToArray);
      end;
      if Jump then
        Cursor := NextCursor
      else
      begin
        Inc(Cursor.Row);
        Cursor.TempoCounter := (Cursor.TempoCounter + 1) mod (Cursor.Interleave * 2);
        if Cursor.Row >= Rows then
        begin
          Cursor.Row := 0;
          Inc(Cursor.Position);
        end;
      end;
    end;
    Result.Frames := Frames.ToArray;
  finally
    Writes.Free;
    Frames.Free;
  end;
end;

end.

