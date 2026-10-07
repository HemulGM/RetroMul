unit RetroTune.TFM.Stream;

interface

uses
  System.SysUtils, System.Generics.Collections;

type
  TTFMWrite = record
    Chip, RegisterID, Value: Byte;
    class function Make(Chip, RegisterID, Value: Integer): TTFMWrite; static;
  end;

  TTFMFrame = TArray<TTFMWrite>;

  TTFMFrames = TArray<TTFMFrame>;

  TTFMStream = record
    Frames: TTFMFrames;
    Rate: Integer;
    Title, Author, Comment: string;
  end;

function ParseTFC(const Data: TBytes): TTFMStream;

function ParseTFD(const Data: TBytes): TTFMStream;

implementation

uses
  RetroTune.Binary;

const
  MaxFrames = 90000;

class function TTFMWrite.Make(Chip, RegisterID, Value: Integer): TTFMWrite;
begin
  if (Chip < 0) or (Chip > 1) or (RegisterID < 0) or (RegisterID > 255) or
    (Value < 0) or (Value > 255) then
    raise EArgumentException.Create('Invalid TurboFM register write');
  Result.Chip := Chip;
  Result.RegisterID := RegisterID;
  Result.Value := Value;
end;

function CString(const Data: TBytes; var Offset: Integer; Limit: Integer): string;
begin
  var Start := Offset;
  repeat
    RequireBytes(Data, Offset, 1);
    if Data[Offset] = 0 then
      Break;
    Inc(Offset);
    if Offset - Start > Limit then
      raise EArgumentException.Create('TurboFM metadata too long');
  until False;
  Result := TextField(Data, Start, Offset - Start);
  Inc(Offset);
end;

function ParseTFD(const Data: TBytes): TTFMStream;
var
  Frames: TList<TTFMFrame>;
  Writes: TList<TTFMWrite>;
  Offset, Chip, Count: Integer;
  Cmd: Byte;
begin
  Result := Default(TTFMStream);
  Result.Rate := 50;
  RequireBytes(Data, 0, 8);
  if TEncoding.ASCII.GetString(Data, 0, 4) <> 'TFMD' then
    raise EArgumentException.Create('Invalid TFD signature');
  Offset := 4;
  Result.Title := CString(Data, Offset, 64);
  Result.Author := CString(Data, Offset, 64);
  Result.Comment := CString(Data, Offset, 384);
  Frames := TList<TTFMFrame>.Create;
  Writes := TList<TTFMWrite>.Create;
  try
    Chip := 0;
    repeat
      RequireBytes(Data, Offset, 1);
      Cmd := Data[Offset];
      Inc(Offset);
      case Cmd of
        $FB:
          Break;
        $FA:
          ; // Loop metadata: the player renders one complete pass.
          $FC:
          Chip := 0;
        $FD:
          Chip := 1;
        $FF, $FE:
          begin
            if Frames.Count > 0 then
              Frames[Frames.Count - 1] := Writes.ToArray;
            Writes.Clear;
            Count := 1;
            if Cmd = $FE then
            begin
              RequireBytes(Data, Offset, 1);
              Count := 3 + Data[Offset];
              Inc(Offset);
            end;
            if Frames.Count + Count > MaxFrames then
              raise EArgumentException.Create('TFD exceeds frame limit');
            for var I := 1 to Count do
              Frames.Add(nil);
            Chip := 0;
          end;
      else
        begin
          RequireBytes(Data, Offset, 1);
          if Frames.Count > 0 then
            Writes.Add(TTFMWrite.Make(Chip, Cmd, Data[Offset]));
          Inc(Offset);
        end;
      end;
    until False;
    // Final frame marker closes the previous interval, as in the dump writer.
    if Frames.Count = 0 then
      raise EArgumentException.Create('Empty TFD');
    Frames.Delete(Frames.Count - 1);
    Result.Frames := Frames.ToArray;
  finally
    Writes.Free;
    Frames.Free;
  end;
end;

function ParseTFC(const Data: TBytes): TTFMStream;
var
  Channels: array[0..5] of TTFMFrames;
  Loops: array[0..5] of Integer;
  List: TList<TTFMFrame>;
  Writes: TList<TTFMWrite>;
  Offset, Cursor, ReturnAt, Repeats, Freq, Chan, Cmd, Total, Count, At, Steps: Integer;

  function ByteAt(var P: Integer): Integer;
  begin
    RequireBytes(Data, P, 1);
    Result := Data[P];
    Inc(P);
  end;

  function BEWord(var P: Integer): Integer;
  begin
    Result := ByteAt(P) * 256;
    Inc(Result, ByteAt(P));
  end;

  function Relative(var P: Integer): Integer;
  begin
    var Delta := BEWord(P);
    if Delta >= 32768 then
      Dec(Delta, 65536);
    Result := P + Delta;
    RequireBytes(Data, Result, 1);
  end;

  procedure WriteReg(Reg, Value: Integer);
  begin
    Writes.Add(TTFMWrite.Make(Ord(Chan >= 3), Reg, Value));
  end;

  procedure Frequency(Value: Integer);
  begin
    Freq := Value;
    WriteReg($A4 + Chan mod 3, Value shr 8);
    WriteReg($A0 + Chan mod 3, Value and 255);
  end;

  procedure FrameData(var P: Integer);
  begin
    var Flags := ByteAt(P);
    if Flags and $C0 <> 0 then
      WriteReg($28, Chan mod 3);
    if Flags and 1 <> 0 then
      Frequency(BEWord(P));
    for var I := 1 to (Flags and $3E) shr 1 do
    begin
      var Reg := ByteAt(P);
      var Value := ByteAt(P);
      WriteReg(Reg, Value);
    end;
    if Flags and $80 <> 0 then
      WriteReg($28, $F0 or (Chan mod 3));
  end;

begin
  Result := Default(TTFMStream);
  RequireBytes(Data, 0, 43);
  if TEncoding.ASCII.GetString(Data, 0, 6) <> 'TFMcom' then
    raise EArgumentException.Create('Invalid TFC signature');
  Result.Rate := Data[9];
  if not (Result.Rate in [50, 60]) then
    raise EArgumentException.Create('TFC interrupt rate');
  Offset := 34;
  Result.Title := CString(Data, Offset, 64);
  Result.Author := CString(Data, Offset, 64);
  Result.Comment := CString(Data, Offset, 384);
  List := TList<TTFMFrame>.Create;
  Writes := TList<TTFMWrite>.Create;
  try
    Total := 0;
    for Chan := 0 to 5 do
    begin
      List.Clear;
      Loops[Chan] := 0;
      Freq := 0;
      Repeats := 0;
      ReturnAt := 0;
      Steps := 0;
      Cursor := LE16(Data, 10 + Chan * 2);
      if Cursor < Offset then
        raise EArgumentException.Create('TFC channel overlaps metadata');
      repeat
        Inc(Steps);
        if (Steps > MaxFrames * 8) or (List.Count >= MaxFrames) then
          raise EArgumentException.Create('TFC exceeds frame/control limit');
        if Repeats > 0 then
        begin
          Dec(Repeats);
          if Repeats = 0 then
          begin
            Cursor := ReturnAt;
            ReturnAt := 0;
          end;
        end;
        // Control commands do not consume a frame or repeat counter.
        repeat
          Cmd := ByteAt(Cursor);
          if Cmd = $7E then
            Loops[Chan] := List.Count
          else
            Break;
          Inc(Steps);
          if Steps > MaxFrames * 8 then
            raise EArgumentException.Create('TFC control loop');
        until False;
        if Cmd = $7F then
          Break;
        if Cmd = $D0 then
        begin
          if Repeats <> 0 then
            raise EArgumentException.Create('Nested TFC repeat');
          Repeats := ByteAt(Cursor);
          if Repeats = 0 then
            raise EArgumentException.Create('Empty TFC repeat');
          At := Relative(Cursor);
          ReturnAt := Cursor;
          Cursor := At;
          Cmd := ByteAt(Cursor);
        end;
        Writes.Clear;
        Count := 1;
        case Cmd of
          $BF:
            begin
              At := Relative(Cursor);
              FrameData(At);
            end;
          $FF:
            begin
              At := ByteAt(Cursor) - 256;
              At := Cursor + At;
              FrameData(At);
            end;
          $E0..$FE:
            Count := 256 - Cmd;
          $C0..$DF:
            Frequency((Freq and $FF00) or ((Freq + Cmd + $30) and 255));
        else
          Dec(Cursor);
          FrameData(Cursor);
        end;
        List.Add(Writes.ToArray);
        if List.Count + Count - 1 > MaxFrames then
          raise EArgumentException.Create('TFC frame limit');
        for var I := 2 to Count do
          List.Add(nil);
      until False;
      if List.Count = 0 then
        raise EArgumentException.Create('Empty TFC channel');
      if Loops[Chan] >= List.Count then
        raise EArgumentException.Create('Empty TFC loop');
      Channels[Chan] := List.ToArray;
      if List.Count > Total then
        Total := List.Count;
    end;
    SetLength(Result.Frames, Total);
    for var Frame := 0 to Total - 1 do
    begin
      Writes.Clear;
      for Chan := 0 to 5 do
      begin
        At := Frame;
        if At >= Length(Channels[Chan]) then
          At := Loops[Chan] + (At - Length(Channels[Chan])) mod (Length(Channels[Chan]) - Loops[Chan]);
        Writes.AddRange(Channels[Chan][At]);
      end;
      Result.Frames[Frame] := Writes.ToArray;
    end;
  finally
    Writes.Free;
    List.Free;
  end;
end;

end.

