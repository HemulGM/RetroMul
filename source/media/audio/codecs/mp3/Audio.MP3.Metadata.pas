unit Audio.MP3.Metadata;

interface

uses
  System.SysUtils;

type
  TMP3TextFrame = record
    Id, Text: string;
  end;

  TMP3Metadata = record
    Present: Boolean;
    AudioOffset, AudioEnd: Integer;
    TextFrames: TArray<TMP3TextFrame>;
  end;

function ReadMP3Metadata(const Data: TBytes): TMP3Metadata;

implementation

uses
  System.StrUtils, System.Generics.Collections;

function ReadSize(const Data: TBytes; Offset, Count: Integer; SyncSafe: Boolean): Integer;
var
  I, Shift: Integer;
  Value: UInt32;
begin
  Result := -1;
  if (Offset < 0) or (Offset > Length(Data) - Count) then
    Exit;
  Shift := 8 - Ord(SyncSafe);
  Value := 0;
  for I := Offset to Offset + Count - 1 do
  begin
    if SyncSafe and (Data[I] > 127) then
      Exit;
    Value := (Value shl Shift) or Data[I];
  end;
  if Value <= UInt32(MaxInt) then
    Result := Integer(Value);
end;

procedure RemoveUnsynchronisation(var Data: TBytes);
var
  ReadIndex, WriteIndex: Integer;
begin
  ReadIndex := 0;
  WriteIndex := 0;
  while ReadIndex < Length(Data) do
  begin
    Data[WriteIndex] := Data[ReadIndex];
    Inc(WriteIndex);
    Inc(ReadIndex);
    if (Data[WriteIndex - 1] = $FF) and (ReadIndex < Length(Data)) and (Data[ReadIndex] = 0) then
      Inc(ReadIndex);
  end;
  SetLength(Data, WriteIndex);
end;

function TextBytes(const Data: TBytes; Offset, Count, Encoding: Integer; BigEndian: Boolean = False): string;
var
  I: Integer;
begin
  Result := '';
  if Count <= 0 then
    Exit;
  if Encoding in [1, 2] then
  begin
    if (Encoding = 1) and (Count >= 2) then
    begin
      if (Data[Offset] = $FF) and (Data[Offset + 1] = $FE) then
      begin
        BigEndian := False;
        Inc(Offset, 2);
        Dec(Count, 2);
      end
      else if (Data[Offset] = $FE) and (Data[Offset + 1] = $FF) then
      begin
        BigEndian := True;
        Inc(Offset, 2);
        Dec(Count, 2);
      end;
    end;
    Count := Count and not 1;
    if BigEndian or (Encoding = 2) then
      Result := TEncoding.BigEndianUnicode.GetString(Data, Offset, Count)
    else
      Result := TEncoding.Unicode.GetString(Data, Offset, Count);
  end
  else if Encoding = 3 then
    Result := TEncoding.UTF8.GetString(Data, Offset, Count)
  else if Encoding = 0 then
  begin
    SetLength(Result, Count);
    for I := 1 to Count do
      Result[I] := Char(Data[Offset + I - 1]);
  end;
  I := Length(Result);
  while (I > 0) and (Result[I] = #0) do
    Dec(I);
  SetLength(Result, I);
end;

function FrameId(const Data: TBytes; Offset, Count: Integer): string;
var
  I: Integer;
begin
  SetLength(Result, Count);
  for I := 1 to Count do
  begin
    Result[I] := Char(Data[Offset + I - 1]);
    if not CharInSet(Result[I], ['A'..'Z', '0'..'9']) then
      Exit('');
  end;
  if Count = 3 then
    case IndexStr(Result, ['TT2', 'TT3', 'TP1', 'TP2', 'TAL', 'TRK', 'TYE', 'TCO', 'COM', 'TCM', 'TLE']) of
      0:
        Result := 'TIT2';
      1:
        Result := 'TIT3';
      2:
        Result := 'TPE1';
      3:
        Result := 'TPE2';
      4:
        Result := 'TALB';
      5:
        Result := 'TRCK';
      6:
        Result := 'TYER';
      7:
        Result := 'TCON';
      8:
        Result := 'COMM';
      9:
        Result := 'TCOM';
      10:
        Result := 'TLEN';
    end;
end;

procedure AddFrame(Frames: TList<TMP3TextFrame>; const Id, Text: string);
var
  Frame: TMP3TextFrame;
begin
  Frame.Id := Id;
  Frame.Text := Text;
  Frames.Add(Frame);
end;

procedure DecodeTextFrame(Frames: TList<TMP3TextFrame>; const Id: string; const Bytes: TBytes; Offset: Integer);
var
  Encoding, Width, Desc, EndPos: Integer;
  BigEndian: Boolean;
begin
  EndPos := Length(Bytes);
  if Offset >= EndPos then
    Exit;
  Encoding := Bytes[Offset];
  if Encoding > 3 then
    Exit;
  Inc(Offset);
  BigEndian := False;
  if Id = 'COMM' then
  begin
    Inc(Offset, 3); // Language.
    if Offset >= EndPos then
      Exit;
    Width := 1 + Ord(Encoding in [1, 2]);
    Desc := Offset;
    if (Encoding = 1) and (Desc + 2 <= EndPos) then
      BigEndian := (Bytes[Desc] = $FE) and (Bytes[Desc + 1] = $FF);
    // Skip the description, using the same byte order for its text.
    while Desc + Width <= EndPos do
    begin
      if (Bytes[Desc] = 0) and ((Width = 1) or (Bytes[Desc + 1] = 0)) then
        Break;
      Inc(Desc, Width);
    end;
    Offset := Desc + Width;
    if Offset > EndPos then
      Exit;
  end;
  AddFrame(Frames, Id, TextBytes(Bytes, Offset, EndPos - Offset, Encoding, BigEndian));
end;

procedure ParseID3v2(const Data: TBytes; Version, Flags: Byte; Frames: TList<TMP3TextFrame>);
const
  MaxTextBytes = 64 * 1024;
var
  Tag, Payload: TBytes;
  Position, Size, HeadSize, IdSize, FrameFlags, Extra: Integer;
  Id: string;
begin
  Tag := Data;
  if (Version < 4) and (Flags and $80 <> 0) then
    RemoveUnsynchronisation(Tag);
  Position := 0;
  if Flags and $40 <> 0 then
  begin
    if Version = 2 then
      Exit; // The v2.2 flag means the whole tag is compressed.
    Size := ReadSize(Tag, 0, 4, Version = 4);
    if (Size < 4) or (Size > Length(Tag)) then
      Exit;
    Position := Size;
    if Version = 3 then
      Inc(Position, 4);
  end;
  HeadSize := 10;
  IdSize := 4;
  if Version = 2 then
  begin
    HeadSize := 6;
    IdSize := 3;
  end;
  while (Position <= Length(Tag) - HeadSize) and (Frames.Count < 256) do
  begin
    Id := FrameId(Tag, Position, IdSize);
    if Id = '' then
      Break;
    Size := ReadSize(Tag, Position + IdSize, IdSize, Version = 4);
    if (Size < 1) or (Size > Length(Tag) - Position - HeadSize) then
      Break;
    FrameFlags := 0;
    if Version > 2 then
      FrameFlags := Tag[Position + 9];
    Inc(Position, HeadSize);
    if (Size <= MaxTextBytes) and ((Id = 'COMM') or ((Id[1] = 'T') and (Id <> 'TXXX') and (Id <> 'TXX'))) then
    begin
      Extra := 0;
      if ((Version <> 3) or (FrameFlags and $C0 = 0)) and
        ((Version <> 4) or (FrameFlags and $0C = 0)) then
      begin
        Payload := Copy(Tag, Position, Size);
        if Version = 3 then
          Extra := Ord(FrameFlags and $20 <> 0);
        if Version = 4 then
        begin
          if (Flags and $80 <> 0) or (FrameFlags and 2 <> 0) then
            RemoveUnsynchronisation(Payload);
          Extra := Ord(FrameFlags and $40 <> 0) + 4 * Ord(FrameFlags and 1 <> 0);
        end;
        DecodeTextFrame(Frames, Id, Payload, Extra);
      end;
    end;
    Inc(Position, Size);
  end;
end;

procedure ParseID3v1(const Data: TBytes; Start: Integer; Frames: TList<TMP3TextFrame>);
const
  Genres: array[0..79] of string = (
    'Blues', 'Classic Rock', 'Country', 'Dance', 'Disco', 'Funk', 'Grunge', 'Hip-Hop', 'Jazz', 'Metal',
    'New Age', 'Oldies', 'Other', 'Pop', 'RnB', 'Rap', 'Reggae', 'Rock', 'Techno', 'Industrial',
    'Alternative', 'Ska', 'Death Metal', 'Pranks', 'Soundtrack', 'Euro-Techno', 'Ambient', 'Trip-Hop',
    'Vocal', 'Jazz+Funk', 'Fusion', 'Trance', 'Classical', 'Instrumental', 'Acid', 'House', 'Game', 'Sound Clip',
    'Gospel', 'Noise', 'Alternative Rock', 'Bass', 'Soul', 'Punk', 'Space', 'Meditative', 'Instrumental Pop',
    'Instrumental Rock', 'Ethnic', 'Gothic', 'Darkwave', 'Techno-Industrial', 'Electronic', 'Pop-Folk',
    'Eurodance', 'Dream', 'Southern Rock', 'Comedy', 'Cult', 'Gangsta', 'Top 40', 'Christian Rap',
    'Pop/Funk', 'Jungle', 'Native American', 'Cabaret', 'New Wave', 'Psychedelic', 'Rave', 'Showtunes',
    'Trailer', 'Lo-Fi', 'Tribal', 'Acid Punk', 'Acid Jazz', 'Polka', 'Retro', 'Musical', 'Rock & Roll', 'Hard Rock');
var
  HasTrack: Boolean;

  procedure ReadField(const Id: string; Offset, Count: Integer);
  var
    Text: string;
  begin
    Text := Trim(TextBytes(Data, Start + Offset, Count, 0));
    if Text <> '' then
      AddFrame(Frames, Id, Text);
  end;

begin
  ReadField('TIT2', 3, 30);
  ReadField('TPE1', 33, 30);
  ReadField('TALB', 63, 30);
  ReadField('TYER', 93, 4);
  HasTrack := (Data[Start + 125] = 0) and (Data[Start + 126] <> 0);
  ReadField('COMM', 97, 30 - 2 * Ord(HasTrack));
  if HasTrack then
    AddFrame(Frames, 'TRCK', IntToStr(Data[Start + 126]));
  if Data[Start + 127] <= High(Genres) then
    AddFrame(Frames, 'TCON', Genres[Data[Start + 127]]);
end;

function ReadMP3Metadata(const Data: TBytes): TMP3Metadata;
const
  MaxParsedTagBytes = 4 * 1024 * 1024;
var
  TagLength, Tail: Integer;
  HasV1: Boolean;
  Frames: TList<TMP3TextFrame>;
begin
  Result := Default(TMP3Metadata);
  Result.AudioEnd := Length(Data);
  Tail := Result.AudioEnd - 128;
  HasV1 := (Tail >= 0) and (Data[Tail] = Ord('T')) and (Data[Tail + 1] = Ord('A')) and (Data[Tail + 2] = Ord('G'));
  if HasV1 then
    Result.AudioEnd := Tail;
  Frames := TList<TMP3TextFrame>.Create;
  try
    if (Result.AudioEnd >= 10) and (Data[0] = Ord('I')) and
      (Data[1] = Ord('D')) and (Data[2] = Ord('3')) then
    begin
      TagLength := ReadSize(Data, 6, 4, True);
      if (TagLength >= 0) and (TagLength <= Result.AudioEnd - 10) then
      begin
        Result.AudioOffset := TagLength + 10;
        if (Data[3] = 4) and (Data[5] and $10 <> 0) and (Result.AudioOffset <= Result.AudioEnd - 10) then
          Inc(Result.AudioOffset, 10);
        if Data[3] in [2..4] then
        begin
          Result.Present := True;
          if TagLength <= MaxParsedTagBytes then
            ParseID3v2(Copy(Data, 10, TagLength), Data[3], Data[5], Frames);
        end;
      end;
    end;
    if not Result.Present and HasV1 then
    begin
      Result.Present := True;
      ParseID3v1(Data, Tail, Frames);
    end;
    Result.TextFrames := Frames.ToArray;
  finally
    Frames.Free;
  end;
end;

end.

