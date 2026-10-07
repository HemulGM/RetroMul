unit RetroTune.Decoder.WAV;

interface

uses
  System.SysUtils, RetroTune.Decoder;

type
  TWavDecoder = class(TInterfacedObject, ITuneDecoder)
  private
    FInfo: TTuneInfo;
    FData: TBytes;
    FDataOffset, FFrameCount, FPosition, FBits, FBlockAlign: Integer;
    FFloat: Boolean;
    function ReadSample(Offset: Integer): SmallInt;
  public
    constructor Create(const Data: TBytes);
    function GetInfo: TTuneInfo;
    procedure SelectTrack(Index: Integer);
    function Render(var Samples: array of SmallInt; Frames: Integer): Integer;
  end;

implementation

uses
  System.Math, RetroTune.Binary;

function HasTag(const Data: TBytes; Offset: Integer; const Tag: AnsiString): Boolean;
begin
  RequireBytes(Data, Offset, 4);
  Result := (Data[Offset] = Ord(Tag[1])) and (Data[Offset + 1] = Ord(Tag[2])) and
    (Data[Offset + 2] = Ord(Tag[3])) and (Data[Offset + 3] = Ord(Tag[4]));
end;

constructor TWavDecoder.Create(const Data: TBytes);
const
  SubFormatTail: array[0..11] of Byte = (0, 0, $10, 0, $80, 0, 0, $AA, 0, $38, $9B, $71);
var
  Limit, Offset, Size, FormatOffset, FormatSize, DataSize, AudioFormat: Integer;
  Next: Int64;
  DataFound: Boolean;
  Rate: Cardinal;

  procedure AddMetadata(const Name, Value: string);
  begin
    var N := Length(FInfo.Metadata);
    if N >= 4096 then
      raise EArgumentException.Create('WAV contains too many metadata fields');
    SetLength(FInfo.Metadata, N + 1);
    FInfo.Metadata[N].Name := Name;
    FInfo.Metadata[N].Value := Value;
  end;

  procedure ReadInfoList(Start, Count: Integer);
  begin
    var Cursor := Start + 4;
    var ListEnd := Start + Count;
    while Cursor < ListEnd do
    begin
      if ListEnd - Cursor < 8 then
        raise EArgumentException.Create('Truncated WAV INFO header');
      var TextEnd := Int64(Cursor) + 8 + LE32(Data, Cursor + 4);
      if TextEnd > ListEnd then
        raise EArgumentException.Create('Truncated WAV INFO text');
      var TextSize := Integer(TextEnd - Cursor - 8);
      var Tag := TEncoding.ASCII.GetString(Data, Cursor, 4);
      var Text := TextField(Data, Cursor + 8, TextSize);
      AddMetadata('INFO / ' + Tag, Text);
      if Tag = 'INAM' then
        FInfo.Title := Text
      else if Tag = 'IART' then
        FInfo.Artist := Text
      else if Tag = 'ICOP' then
        FInfo.CopyrightText := Text;
      Cursor := Integer(TextEnd);
      if Odd(TextSize) and (Cursor < ListEnd) then
        Inc(Cursor);
    end;
  end;

begin
  inherited Create;
  RequireBytes(Data, 0, 12);
  if not HasTag(Data, 0, 'RIFF') or not HasTag(Data, 8, 'WAVE') then
    raise EArgumentException.Create('Expected a RIFF/WAVE file');
  Next := Int64(LE32(Data, 4)) + 8;
  if (Next < 12) or (Next > Length(Data)) then
    raise EArgumentException.Create('Truncated WAV RIFF chunk');
  Limit := Integer(Next);
  Offset := 12;
  FormatOffset := -1;
  FormatSize := 0;
  DataSize := 0;
  DataFound := False;
  while Offset < Limit do
  begin
    if Limit - Offset < 8 then
      raise EArgumentException.Create('Truncated WAV chunk header');
    Next := Int64(Offset) + 8 + LE32(Data, Offset + 4);
    if Next > Limit then
      raise EArgumentException.Create('WAV chunk exceeds the RIFF size');
    Size := Integer(Next - Offset - 8);
    AddMetadata('RIFF / ' + TEncoding.ASCII.GetString(Data, Offset, 4),
      IntToStr(Size) + ' bytes');
    if HasTag(Data, Offset, 'fmt ') then
    begin
      if FormatOffset >= 0 then
        raise EArgumentException.Create('Duplicate WAV format chunk');
      FormatOffset := Offset + 8;
      FormatSize := Size;
    end
    else if HasTag(Data, Offset, 'data') then
    begin
      if DataFound then
        raise ENotSupportedException.Create('Multiple WAV data chunks are not supported');
      DataFound := True;
      FDataOffset := Offset + 8;
      DataSize := Size;
    end
    else if HasTag(Data, Offset, 'LIST') and (Size >= 4) then
    begin
      if HasTag(Data, Offset + 8, 'INFO') then
        ReadInfoList(Offset + 8, Size);
    end;
    Offset := Integer(Next);
    // RIFF chunks are padded to even sizes. Accept an unpadded final chunk,
    // as used by common writers for odd-length 8-bit mono audio.
    if Odd(Size) and (Offset < Limit) then
      Inc(Offset);
  end;
  if (FormatOffset < 0) or not DataFound then
    raise EArgumentException.Create('WAV requires fmt and data chunks');
  if FormatSize < 16 then
    raise EArgumentException.Create('Truncated WAV format chunk');
  AudioFormat := LE16(Data, FormatOffset);
  FInfo.Channels := LE16(Data, FormatOffset + 2);
  Rate := LE32(Data, FormatOffset + 4);
  FBlockAlign := LE16(Data, FormatOffset + 12);
  FBits := LE16(Data, FormatOffset + 14);
  if FormatSize > 16 then
  begin
    if (FormatSize < 18) or (LE16(Data, FormatOffset + 16) > FormatSize - 18) then
      raise EArgumentException.Create('Invalid WAV format extension size');
  end;
  if AudioFormat = $FFFE then
  begin
    if (FormatSize < 40) or (LE16(Data, FormatOffset + 16) < 22) then
      raise EArgumentException.Create('Truncated extensible WAV format');
    for var I := 0 to High(SubFormatTail) do
      if Data[FormatOffset + 28 + I] <> SubFormatTail[I] then
        raise ENotSupportedException.Create('Unsupported extensible WAV subformat');
    var SubFormat := LE32(Data, FormatOffset + 24);
    if not ((SubFormat = 1) or (SubFormat = 3)) then
      raise ENotSupportedException.Create('WAV supports PCM and IEEE Float audio only');
    AudioFormat := Integer(SubFormat);
    var ValidBits := LE16(Data, FormatOffset + 18);
    if (ValidBits = 0) or (ValidBits > FBits) or ((AudioFormat = 3) and (ValidBits <> FBits)) then
      raise EArgumentException.Create('Invalid extensible WAV sample precision');
    AddMetadata('Valid bits', IntToStr(ValidBits));
    AddMetadata('Channel mask', '$' + IntToHex(LE32(Data, FormatOffset + 20), 8));
  end;
  FFloat := AudioFormat = 3;
  if (AudioFormat <> 1) and not FFloat then
    raise ENotSupportedException.Create('WAV supports PCM and IEEE Float audio only');
  if (FInfo.Channels < 1) or (FInfo.Channels > 2) then
    raise ENotSupportedException.Create('WAV supports mono and stereo audio only');
  if (Rate < 1) or (Rate > 384000) then
    raise EArgumentException.Create('Invalid WAV sample rate');
  if (FFloat and (FBits <> 32) and (FBits <> 64)) or
    (not FFloat and (FBits <> 8) and (FBits <> 16) and (FBits <> 24) and (FBits <> 32)) then
    raise ENotSupportedException.Create('Unsupported WAV sample depth');
  if (FBlockAlign <> FInfo.Channels * (FBits div 8)) or
    (LE32(Data, FormatOffset + 8) <> Rate * Cardinal(FBlockAlign)) or
    (DataSize mod FBlockAlign <> 0) then
    raise EArgumentException.Create('Invalid WAV block alignment or byte rate');
  // The input is immutable; share its snapshot instead of copying large PCM data.
  FData := Data;
  FInfo.SampleRate := Integer(Rate);
  FInfo.FormatName := 'WAV';
  FInfo.TrackCount := 1;
  FFrameCount := DataSize div FBlockAlign;
  FInfo.TrackDurations := [FFrameCount / FInfo.SampleRate];
  AddMetadata('Source bit depth', IntToStr(FBits));
  AddMetadata('Block size, bytes', IntToStr(FBlockAlign));
  AddMetadata('Audio frames', IntToStr(FFrameCount));
  AddMetadata('Bytes per second', IntToStr(Rate * Cardinal(FBlockAlign)));
  if FFloat then
    FInfo.Details := Format('IEEE Float %d-bit', [FBits])
  else
    FInfo.Details := Format('PCM %d-bit', [FBits]);
  SelectTrack(0);
end;

function TWavDecoder.GetInfo: TTuneInfo;
begin
  Result := FInfo;
end;

procedure TWavDecoder.SelectTrack(Index: Integer);
begin
  if Index <> 0 then
    raise EArgumentOutOfRangeException.Create('Invalid WAV track');
  FPosition := 0;
end;

function TWavDecoder.ReadSample(Offset: Integer): SmallInt;
var
  Value: Double;
  SingleValue: Single;
  Bits32: Cardinal;
  Bits64: UInt64;
  Signed: Integer;
begin
  if FFloat then
  begin
    Bits32 := LE32(FData, Offset);
    if FBits = 32 then
    begin
      Move(Bits32, SingleValue, SizeOf(SingleValue));
      Value := SingleValue;
    end
    else
    begin
      Bits64 := UInt64(Bits32) or (UInt64(LE32(FData, Offset + 4)) shl 32);
      Move(Bits64, Value, SizeOf(Value));
    end;
    if IsNan(Value) then
      Result := 0
    else if Value >= 1 then
      Result := 32767
    else if Value <= -1 then
      Result := -32768
    else
      Result := SmallInt(EnsureRange(Round(Value * 32768), Int64(-32768), Int64(32767)));
  end
  else if FBits = 8 then
    Result := (Integer(FData[Offset]) - 128) * 256
  else
  begin
    // Keep the high 16 bits of signed little-endian PCM, including its sign.
    Inc(Offset, FBits div 8 - 2);
    Signed := LE16(FData, Offset);
    if Signed >= 32768 then
      Dec(Signed, 65536);
    Result := Signed;
  end;
end;

function TWavDecoder.Render(var Samples: array of SmallInt; Frames: Integer): Integer;
begin
  ValidateRender(Length(Samples), Frames, FInfo.Channels);
  Result := Min(Frames, FFrameCount - FPosition);
  var Offset := FDataOffset + FPosition * FBlockAlign;
  for var I := 0 to Result * FInfo.Channels - 1 do
  begin
    Samples[I] := ReadSample(Offset);
    Inc(Offset, FBits div 8);
  end;
  Inc(FPosition, Result);
end;

function OpenWav(const Data: TBytes): ITuneDecoder;
begin
  Result := TWavDecoder.Create(Data);
end;

initialization
  TTuneDecoders.RegisterFormat('.wav', 'Wave audio (PCM / IEEE Float)', OpenWav);

end.

