unit Audio.Format.WAV;

interface

uses
  Audio.Types, System.SysUtils, Audio.Decoder, Audio.Codec.GSM;

type
  TWavDecoder = class(TInterfacedObject, IAudioSource, IAudioMetadata, IAudioSeekSource)
  private
    FInfo: TAudioInfo;
    FData: TBytes;
    FDataOffset, FFrameCount, FPosition, FBits, FBlockAlign: Integer;
    FFormatTag: Integer;
    FFramesPerBlock, FCachedBlock: Integer;
    FBlockPCM: TArray<SmallInt>;
    FGsmState: TGSMDecoder;
    FGsmNextBlock, FGsmCheckpointCount: Integer;
    FGsmCheckpoints: TArray<TGSMDecoder>;
    procedure ReadGsmFormat(FormatOffset, FormatSize, DataSize: Integer; FactFrames: Cardinal);
    procedure DecodeGsmBlock(Block: Integer; const Cancelled: TFunc<Boolean>);
    procedure ReadImaFormat(FormatOffset, FormatSize, DataSize: Integer; FactFrames: Cardinal);
    procedure DecodeImaBlock(Block: Integer);
    function ReadSample(Offset: Integer): SmallInt;
  public
    constructor Create(const Data: TBytes);
    function SeekFrame(Frame: Int64; const Cancelled: TFunc<Boolean>): Int64;
    function GetInfo: TAudioInfo;
    function GetFormat: TAudioFormat;
    function Render(var Samples: array of SmallInt; Frames: Integer): Integer;
  end;

function OpenWav(const Data: TBytes): IAudioSource;

implementation

uses
  System.Math, Audio.Binary;

const
  WavePCM = $0001;
  WaveFloat = $0003;
  WaveALaw = $0006;
  WaveMuLaw = $0007;
  WaveImaADPCM = $0011;
  WaveGSM610 = $0031;
  GSMCheckpointInterval = 128;
  WaveExtensible = $FFFE;

function DecodeALaw(Code: Byte): SmallInt;
begin
  Code := Code xor $55;
  var Segment := (Code shr 4) and 7;
  var Magnitude: Integer := ((Code and $0F) shl 4) + 8;
  if Segment > 0 then
    Magnitude := (Magnitude + $100) shl (Segment - 1);
  if (Code and $80) = 0 then
    Magnitude := -Magnitude;
  Result := SmallInt(Magnitude);
end;

function DecodeMuLaw(Code: Byte): SmallInt;
const
  Bias = $84;
begin
  Code := Code xor $FF;
  var Segment := (Code shr 4) and 7;
  var Magnitude: Integer := ((((Code and $0F) shl 3) + Bias) shl Segment) - Bias;
  if (Code and $80) <> 0 then
    Magnitude := -Magnitude;
  Result := SmallInt(Magnitude);
end;

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
  Limit, Offset, Size, FormatOffset, FormatSize, DataSize: Integer;
  Next: Int64;
  DataFound: Boolean;
  Rate, FactFrames: Cardinal;

  procedure AddMetadata(const Name, Value: string);
  begin
    var N := Length(FInfo.Metadata);
    if N >= 4096 then
      raise EArgumentException.Create('WAV contains too many metadata fields');
    SetLength(FInfo.Metadata, N + 1);
    FInfo.Metadata[N].Name := Name;
    FInfo.Metadata[N].Value := Value;
  end;

  procedure ReadInfoList(Start, Count: Integer; MissingTerminator: Boolean);
  begin
    var Cursor := Start + 4;
    var ListEnd := Start + Count;
    while Cursor < ListEnd do
    begin
      if ListEnd - Cursor < 8 then
        raise EArgumentException.Create('Truncated WAV INFO header');
      var TextEnd := Int64(Cursor) + 8 + LE32(Data, Cursor + 4);
      if TextEnd > ListEnd then
      begin
        if not MissingTerminator or (TextEnd <> Int64(ListEnd) + 1) then
          raise EArgumentException.Create('Truncated WAV INFO text');
        TextEnd := ListEnd;
      end;
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
  FactFrames := 0;
  while Offset < Limit do
  begin
    if Limit - Offset < 8 then
      raise EArgumentException.Create('Truncated WAV chunk header');
    Next := Int64(Offset) + 8 + LE32(Data, Offset + 4);
    if Next > Limit then
    begin
      // Some writers omit the last INFO field's terminator from RIFF's
      // size. A reader may have copied only the bytes inside that size.
      if (Next <> Int64(Limit) + 1) or not Odd(Limit) or (Limit - Offset < 12) or
        not HasTag(Data, Offset, 'LIST') or not HasTag(Data, Offset + 8, 'INFO') then
        raise EArgumentException.Create('WAV chunk exceeds the RIFF size');
    end;
    Size := Integer(Min(Next, Limit) - Offset - 8);
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
    else if HasTag(Data, Offset, 'fact') and (Size >= 4) then
      FactFrames := LE32(Data, Offset + 8)
    else if HasTag(Data, Offset, 'LIST') and (Size >= 4) then
    begin
      if HasTag(Data, Offset + 8, 'INFO') then
        ReadInfoList(Offset + 8, Size, Next > Limit);
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
  FFormatTag := LE16(Data, FormatOffset);
  FInfo.Channels := LE16(Data, FormatOffset + 2);
  Rate := LE32(Data, FormatOffset + 4);
  FBlockAlign := LE16(Data, FormatOffset + 12);
  FBits := LE16(Data, FormatOffset + 14);
  if FormatSize > 16 then
  begin
    if (FormatSize < 18) or (LE16(Data, FormatOffset + 16) > FormatSize - 18) then
      raise EArgumentException.Create('Invalid WAV format extension size');
  end;
  if FFormatTag = WaveExtensible then
  begin
    if (FormatSize < 40) or (LE16(Data, FormatOffset + 16) < 22) then
      raise EArgumentException.Create('Truncated extensible WAV format');
    for var I := 0 to High(SubFormatTail) do
      if Data[FormatOffset + 28 + I] <> SubFormatTail[I] then
        raise ENotSupportedException.Create('Unsupported extensible WAV subformat');
    var SubFormat := LE32(Data, FormatOffset + 24);
    case SubFormat of
      WavePCM, WaveFloat, WaveALaw, WaveMuLaw:
        FFormatTag := Integer(SubFormat);
    else
      raise ENotSupportedException.Create('Unsupported extensible WAV subformat');
    end;
    var ValidBits := LE16(Data, FormatOffset + 18);
    if (ValidBits = 0) or (ValidBits > FBits) or ((FFormatTag <> WavePCM) and (ValidBits <> FBits)) then
      raise EArgumentException.Create('Invalid extensible WAV sample precision');
    AddMetadata('Valid bits', IntToStr(ValidBits));
    AddMetadata('Channel mask', '$' + IntToHex(LE32(Data, FormatOffset + 20), 8));
  end;
  case FFormatTag of
    WavePCM:
      if not (FBits in [8, 16, 24, 32]) then
        raise ENotSupportedException.Create('Unsupported WAV PCM sample depth');
    WaveFloat:
      if not (FBits in [32, 64]) then
        raise ENotSupportedException.Create('Unsupported WAV float sample depth');
    WaveALaw, WaveMuLaw:
      if FBits <> 8 then
        raise EArgumentException.Create('Expected 8-bit WAV G.711 samples');
    WaveImaADPCM, WaveGSM610:
      ;
  else
    raise ENotSupportedException.Create('Unsupported WAV audio format');
  end;
  if (FInfo.Channels < 1) or (FInfo.Channels > 2) then
    raise ENotSupportedException.Create('WAV supports mono and stereo audio only');
  if (Rate < 1) or (Rate > 384000) then
    raise EArgumentException.Create('Invalid WAV sample rate');
  // The input is immutable; share its snapshot instead of copying large PCM data.
  FData := Data;
  if FFormatTag = WaveImaADPCM then
    ReadImaFormat(FormatOffset, FormatSize, DataSize, FactFrames)
  else if FFormatTag = WaveGSM610 then
    ReadGsmFormat(FormatOffset, FormatSize, DataSize, FactFrames)
  else
  begin
    if (FBlockAlign <> FInfo.Channels * (FBits div 8)) or
      (LE32(Data, FormatOffset + 8) <> Rate * Cardinal(FBlockAlign)) or
      (DataSize mod FBlockAlign <> 0) then
      raise EArgumentException.Create('Invalid WAV block alignment or byte rate');
    FFrameCount := DataSize div FBlockAlign;
    if ((FFormatTag = WaveALaw) or (FFormatTag = WaveMuLaw)) and (FactFrames <> 0) then
      FFrameCount := Integer(Min(Int64(FFrameCount), Int64(FactFrames)));
  end;
  FInfo.SampleRate := Integer(Rate);
  FInfo.FormatName := 'WAV';
  FInfo.TrackCount := 1;
  FInfo.TrackDurations := [FFrameCount / FInfo.SampleRate];
  if FBits <> 0 then
    AddMetadata('Source bit depth', IntToStr(FBits));
  AddMetadata('Block size, bytes', IntToStr(FBlockAlign));
  AddMetadata('Audio frames', IntToStr(FFrameCount));
  AddMetadata('Bytes per second', IntToStr(LE32(Data, FormatOffset + 8)));
  case FFormatTag of
    WaveImaADPCM:
      FInfo.Details := 'IMA ADPCM 4-bit';
    WaveGSM610:
      FInfo.Details := 'GSM 6.10 (WAV49)';
    WaveALaw:
      FInfo.Details := 'G.711 A-law';
    WaveMuLaw:
      FInfo.Details := 'G.711 mu-law';
    WaveFloat:
      FInfo.Details := Format('IEEE Float %d-bit', [FBits]);
  else
    FInfo.Details := Format('PCM %d-bit', [FBits]);
  end;
  FPosition := 0;
end;

procedure TWavDecoder.ReadGsmFormat(FormatOffset, FormatSize, DataSize: Integer; FactFrames: Cardinal);
begin
  if (FInfo.Channels <> 1) or (FBits <> 0) or (FormatSize < 20) or
    (LE16(FData, FormatOffset + 16) < 2) or
    (FBlockAlign <> GSMWavBlockBytes) or (LE16(FData, FormatOffset + 18) <> GSMWavBlockFrames) then
    raise EArgumentException.Create('Invalid WAV GSM 6.10 format');
  if DataSize mod GSMWavBlockBytes <> 0 then
    raise EArgumentException.Create('Incomplete WAV GSM 6.10 block');

  var Frames := Int64(DataSize div GSMWavBlockBytes) * GSMWavBlockFrames;
  if FactFrames <> 0 then
    Frames := Min(Frames, Int64(FactFrames));
  if Frames > MaxInt then
    raise EArgumentException.Create('Invalid WAV GSM 6.10 frame count');
  FFrameCount := Integer(Frames);
  FFramesPerBlock := GSMWavBlockFrames;
  FCachedBlock := -1;
  SetLength(FBlockPCM, GSMWavBlockFrames);
  FGsmState.Reset;
  FGsmCheckpoints := [FGsmState];
  FGsmCheckpointCount := 1;
end;

procedure TWavDecoder.DecodeGsmBlock(Block: Integer; const Cancelled: TFunc<Boolean>);
var
  PCM: TGSMWavSamples;
begin
  var State := FGsmState;
  var Next := FGsmNextBlock;
  if Block < Next then
  begin
    // A GSM block depends on the speech filter state from previous blocks.
    // Sparse checkpoints bound the work of backward seeks into decoded audio.
    var Checkpoint := Min(Block div GSMCheckpointInterval, FGsmCheckpointCount - 1);
    State := FGsmCheckpoints[Checkpoint];
    Next := Checkpoint * GSMCheckpointInterval;
  end;
  repeat
    if Assigned(Cancelled) and Cancelled() then
      raise EAbort.Create('Audio seek cancelled');
    State.DecodeWavBlock(FData, FDataOffset + Next * GSMWavBlockBytes, PCM);
    Inc(Next);
    if Next = FGsmCheckpointCount * GSMCheckpointInterval then
    begin
      if FGsmCheckpointCount = Length(FGsmCheckpoints) then
        SetLength(FGsmCheckpoints, Length(FGsmCheckpoints) * 2);
      FGsmCheckpoints[FGsmCheckpointCount] := State;
      Inc(FGsmCheckpointCount);
    end;
  until Next > Block;
  Move(PCM[0], FBlockPCM[0], SizeOf(PCM));
  FGsmState := State;
  FGsmNextBlock := Next;
  FCachedBlock := Block;
end;

procedure TWavDecoder.ReadImaFormat(FormatOffset, FormatSize, DataSize: Integer; FactFrames: Cardinal);
begin
  if (FBits <> 4) or (FormatSize < 20) or (LE16(FData, FormatOffset + 16) < 2) then
    raise ENotSupportedException.Create('Expected 4-bit WAV IMA ADPCM format');
  var GroupSize := 4 * FInfo.Channels;
  if (FBlockAlign < GroupSize) or (FBlockAlign mod GroupSize <> 0) then
    raise EArgumentException.Create('Invalid WAV IMA ADPCM block size');
  FFramesPerBlock := LE16(FData, FormatOffset + 18);
  if FFramesPerBlock <> 1 + (FBlockAlign div GroupSize - 1) * 8 then
    raise EArgumentException.Create('Invalid WAV IMA ADPCM frames per block');

  var Capacity := Int64(DataSize div FBlockAlign) * FFramesPerBlock;
  var Tail := DataSize mod FBlockAlign;
  if Tail > 0 then
  begin
    if (Tail < GroupSize) or (Tail mod GroupSize <> 0) then
      raise EArgumentException.Create('Incomplete WAV IMA ADPCM channel group');
    Inc(Capacity, 1 + (Tail div GroupSize - 1) * 8);
  end;
  // The optional fact count trims padding. Some encoders report more
  // frames than the blocks contain, so never extend the decoded audio.
  if FactFrames <> 0 then
    Capacity := Min(Capacity, Int64(FactFrames));
  if Capacity > MaxInt then
    raise EArgumentException.Create('Invalid WAV IMA ADPCM frame count');
  FFrameCount := Integer(Capacity);
  FCachedBlock := -1;
  SetLength(FBlockPCM, Min(FFramesPerBlock, FFrameCount) * FInfo.Channels);
end;

procedure TWavDecoder.DecodeImaBlock(Block: Integer);
const
  Steps: array[0..88] of Integer = (7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31,
    34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230, 253,
    279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411,
    1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358, 5894,
    6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899, 15289, 16818, 18500, 20350,
    22385, 24623, 27086, 29794, 32767);
  IndexChanges: array[0..7] of Integer = (-1, -1, -1, -1, 2, 4, 6, 8);
begin
  FCachedBlock := -1;
  var Channels := FInfo.Channels;
  var Start := FDataOffset + Block * FBlockAlign;
  var Count := Min(FFramesPerBlock, FFrameCount - Block * FFramesPerBlock);
  for var Channel := 0 to Channels - 1 do
  begin
    var Header := Start + Channel * 4;
    var Predictor := Integer(SmallInt(LE16(FData, Header)));
    var Index := Integer(FData[Header + 2]);
    if Index > High(Steps) then
      raise EArgumentException.Create('Invalid WAV IMA ADPCM step index');
    FBlockPCM[Channel] := SmallInt(Predictor);

    // Each group contains eight samples per channel, low nibble first.
    for var I := 0 to Count - 2 do
    begin
      var Offset := Header + ((I div 8) + 1) * 4 * Channels + (I mod 8) div 2;
      var Code := (FData[Offset] shr (4 * (I and 1))) and $F;
      var Step := Steps[Index];
      var Delta := (Step shr 3) + ((Step shr 2) * (Code and 1)) +
        ((Step shr 1) * ((Code shr 1) and 1)) + (Step * ((Code shr 2) and 1));
      if (Code and 8) <> 0 then
        Dec(Predictor, Delta)
      else
        Inc(Predictor, Delta);
      Predictor := EnsureRange(Predictor, Low(SmallInt), High(SmallInt));
      Index := EnsureRange(Index + IndexChanges[Code and 7], 0, High(Steps));
      FBlockPCM[(I + 1) * Channels + Channel] := SmallInt(Predictor);
    end;
  end;
  FCachedBlock := Block;
end;

function TWavDecoder.SeekFrame(Frame: Int64; const Cancelled: TFunc<Boolean>): Int64;
begin
  if Assigned(Cancelled) and Cancelled() then
    raise EAbort.Create('Audio seek cancelled');
  Result := EnsureRange(Frame, Int64(0), Int64(FFrameCount));
  if (FFormatTag = WaveGSM610) and (Result < FFrameCount) then
  begin
    var Block := Integer(Result div FFramesPerBlock);
    if FCachedBlock <> Block then
      DecodeGsmBlock(Block, Cancelled);
  end;
  FPosition := Integer(Result);
end;

function TWavDecoder.GetInfo: TAudioInfo;
begin
  Result := FInfo;
end;

function TWavDecoder.GetFormat: TAudioFormat;
begin
  Result.SampleRate := FInfo.SampleRate;
  Result.Channels := FInfo.Channels;
end;

function TWavDecoder.ReadSample(Offset: Integer): SmallInt;
var
  Value: Double;
  SingleValue: Single;
  Bits32: Cardinal;
  Bits64: UInt64;
  Signed: Integer;
begin
  case FFormatTag of
    WaveALaw:
      Exit(DecodeALaw(FData[Offset]));
    WaveMuLaw:
      Exit(DecodeMuLaw(FData[Offset]));
  end;
  if FFormatTag = WaveFloat then
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
  if FFramesPerBlock <> 0 then
  begin
    var Channels := FInfo.Channels;
    var Copied := 0;
    while Copied < Result do
    begin
      var Block := FPosition div FFramesPerBlock;
      if FCachedBlock <> Block then
      begin
        if FFormatTag = WaveGSM610 then
          DecodeGsmBlock(Block, nil)
        else
          DecodeImaBlock(Block);
      end;
      var WithinBlock := FPosition mod FFramesPerBlock;
      var Count := Min(Result - Copied, FFramesPerBlock - WithinBlock);
      Move(FBlockPCM[WithinBlock * Channels], Samples[Copied * Channels],
        Count * Channels * SizeOf(SmallInt));
      Inc(Copied, Count);
      Inc(FPosition, Count);
    end;
    Exit;
  end;
  var Offset := FDataOffset + FPosition * FBlockAlign;
  for var I := 0 to Result * FInfo.Channels - 1 do
  begin
    Samples[I] := ReadSample(Offset);
    Inc(Offset, FBits div 8);
  end;
  Inc(FPosition, Result);
end;

function OpenWav(const Data: TBytes): IAudioSource;
begin
  if Length(Data) > 512 * 1024 * 1024 then
    raise EArgumentException.Create('Music file exceeds the 512 MiB limit');
  Result := TWavDecoder.Create(Data);
end;

end.

