unit Audio.Format.AMR;

interface

uses
  System.SysUtils, Audio.Types;

const
  AMRNarrowbandContentType = 'audio/amr';
  AMRWidebandContentType = 'audio/amr-wb';

type
  TAMRKind = (Unknown, Narrowband, Wideband);

function DetectAMR(const Data: TBytes): TAMRKind;

function SupportsAMR(Kind: TAMRKind): Boolean;

function AMRFrameSize(Header: Byte; Kind: TAMRKind): Integer;

function OpenAMR(const Data: TBytes): IAudioSource;

implementation

uses
  System.Classes
  {$IFDEF ANDROID}
    , System.Diagnostics, System.Math, Audio.Decoder, Androidapi.JNI,
    Androidapi.JNIBridge, Androidapi.Helpers, Androidapi.JNI.JavaTypes,
    Androidapi.JNI.Media
  {$ENDIF}
  {$IFDEF MSWINDOWS}
    , Audio.AMR.Windows
  {$ENDIF}
;

function DetectAMR(const Data: TBytes): TAMRKind;
const
  NB: array[0..5] of Byte = (35, 33, 65, 77, 82, 10);
  WB: array[0..8] of Byte = (35, 33, 65, 77, 82, 45, 87, 66, 10);
begin
  if (Length(Data) >= Length(NB)) and CompareMem(@Data[0], @NB[0], Length(NB)) then
    Exit(TAMRKind.Narrowband);
  if (Length(Data) >= Length(WB)) and CompareMem(@Data[0], @WB[0], Length(WB)) then
    Exit(TAMRKind.Wideband);
  Result := TAMRKind.Unknown;
end;

function AMRFrameSize(Header: Byte; Kind: TAMRKind): Integer;
const
  // RFC 4867 storage. These lengths include the frame header byte.
  NB: array[0..15] of Byte = (13, 14, 16, 18, 20, 21, 27, 32, 6, 0, 0, 0, 0, 0, 0, 1);
  WB: array[0..15] of Byte = (18, 24, 33, 37, 41, 47, 51, 59, 61, 6, 0, 0, 0, 0, 1, 1);
begin
  var FrameType := (Header shr 3) and 15;
  case Kind of
    TAMRKind.Narrowband:
      Result := NB[FrameType];
    TAMRKind.Wideband:
      Result := WB[FrameType];
  else
    Result := 0;
  end;
end;

function SupportsAMR(Kind: TAMRKind): Boolean;
begin
  {$IFDEF ANDROID}
  Result := Kind in [TAMRKind.Narrowband, TAMRKind.Wideband];
  {$ELSEIF Defined(MSWINDOWS)}
  Result := (Kind = TAMRKind.Narrowband) and WindowsAMRAvailable;
  {$ELSE}
  Result := False;
  {$ENDIF}
end;

function AMRPacketCount(const Data: TBytes; Kind: TAMRKind; Offset: Integer): Integer;
begin
  Result := 0;
  while Offset < Length(Data) do
  begin
    var Size := AMRFrameSize(Data[Offset], Kind);
    if (Size = 0) or (Size > Length(Data) - Offset) then
      raise EReadError.Create('Invalid or truncated AMR frame');
    Inc(Result);
    Inc(Offset, Size);
  end;
  if Result = 0 then
    raise EReadError.Create('AMR clip is empty');
end;

{$IFDEF ANDROID}
type
  TAMRSource = class(TInterfacedObject, IAudioSource, IAudioMetadata)
  private
    FData: TBytes;
    FKind: TAMRKind;
    FMime: JString;
    FCodec: JMediaCodec;
    FBufferInfo: JMediaCodec_BufferInfo;
    FRate, FOffset, FPacketCount, FPacketIndex: Integer;
    FOutput: TArray<SmallInt>;
    FOutputOffset, FOutputCount: Integer;
    FInputEnded, FOutputEnded: Boolean;
    procedure OpenCodec;
    function FeedInput: Boolean;
    function ReadOutput(TimeoutUs: Int64): Boolean;
  public
    constructor Create(const Data: TBytes);
    destructor Destroy; override;
    function GetFormat: TAudioFormat;
    function GetInfo: TAudioInfo;
    function Render(var Samples: array of SmallInt; Frames: Integer): Integer;
  end;

function DirectBuffer(const Buffer: JByteBuffer): PByte;
begin
  if Buffer = nil then
    raise EReadError.Create('Missing AMR codec buffer');
  var Env := TJNIResolver.GetJNIEnv;
  Result := Env^.GetDirectBufferAddress(Env, (Buffer as ILocalObject).GetObjectID);
  if Result = nil then
    raise EReadError.Create('Invalid AMR codec buffer');
end;

constructor TAMRSource.Create(const Data: TBytes);
begin
  inherited Create;
  FKind := DetectAMR(Data);
  case FKind of
    TAMRKind.Narrowband:
      begin
        FOffset := 6;
        FRate := 8000;
        FMime := StringToJString('audio/3gpp');
      end;
    TAMRKind.Wideband:
      begin
        FOffset := 9;
        FRate := 16000;
        FMime := StringToJString(AMRWidebandContentType);
      end;
  else
    raise EReadError.Create('Invalid AMR file header');
  end;
  FPacketCount := AMRPacketCount(Data, FKind, FOffset);
  FData := Data;
end;

procedure TAMRSource.OpenCodec;
begin
  FCodec := TJMediaCodec.JavaClass.createDecoderByType(FMime);
  if FCodec = nil then
    raise ENotSupportedException.Create('AMR decoder is unavailable');
  var Format := TJMediaFormat.JavaClass.createAudioFormat(FMime, FRate, 1);
  FCodec.configure(Format, nil, JMediaCrypto(nil), 0);
  FCodec.start;
  FBufferInfo := TJMediaCodec_BufferInfo.JavaClass.init;
end;

destructor TAMRSource.Destroy;
begin
  if FCodec <> nil then
  try
    FCodec.release;
  except
    // A failed codec may already have released its native resources.
  end;
  inherited;
end;

function TAMRSource.GetFormat: TAudioFormat;
begin
  Result.SampleRate := FRate;
  Result.Channels := 1;
end;

function TAMRSource.GetInfo: TAudioInfo;
begin
  Result := Default(TAudioInfo);
  Result.SampleRate := FRate;
  Result.Channels := 1;
  Result.TrackCount := 1;
  if FKind = TAMRKind.Wideband then
    Result.FormatName := 'AMR-WB'
  else
    Result.FormatName := 'AMR-NB';
  Result.TrackDurations := [FPacketCount / 50];
end;

function TAMRSource.FeedInput: Boolean;
begin
  Result := False;
  if FInputEnded then
    Exit;
  var Index := FCodec.dequeueInputBuffer(0);
  if Index < 0 then
    Exit;
  var Timestamp := Int64(FPacketIndex) * 20000;
  if FOffset = Length(FData) then
  begin
    FCodec.queueInputBuffer(Index, 0, 0, Timestamp, TJMediaCodec.JavaClass.BUFFER_FLAG_END_OF_STREAM);
    FInputEnded := True;
  end
  else
  begin
    var Size := AMRFrameSize(FData[FOffset], FKind);
    var Buffer := FCodec.getInputBuffer(Index);
    var Dest := DirectBuffer(Buffer);
    if Size > Buffer.capacity then
      raise EReadError.Create('AMR codec input buffer is too small');
    Move(FData[FOffset], Dest^, Size);
    Dest^ := Dest^ and $7C; // The receiver ignores the storage padding bits.
    FCodec.queueInputBuffer(Index, 0, Size, Timestamp, 0);
    Inc(FOffset, Size);
    Inc(FPacketIndex);
  end;
  Result := True;
end;

function TAMRSource.ReadOutput(TimeoutUs: Int64): Boolean;
begin
  var Index := FCodec.dequeueOutputBuffer(FBufferInfo, TimeoutUs);
  Result := Index <> TJMediaCodec.JavaClass.INFO_TRY_AGAIN_LATER;
  if Index = TJMediaCodec.JavaClass.INFO_OUTPUT_FORMAT_CHANGED then
  begin
    var Format := FCodec.getOutputFormat;
    var Keys := TJMediaFormat.JavaClass;
    if (Format.getInteger(Keys.KEY_SAMPLE_RATE) <> FRate) or
      (Format.getInteger(Keys.KEY_CHANNEL_COUNT) <> 1) or
      (Format.containsKey(Keys.KEY_PCM_ENCODING) and (Format.getInteger(Keys.KEY_PCM_ENCODING) <> 2)) then
      raise EReadError.Create('Unsupported AMR decoder output format');
    Exit;
  end;
  if Index < 0 then
    Exit;
  try
    var Size := FBufferInfo.size;
    var Offset := FBufferInfo.offset;
    if (Size < 0) or (Size > 128 * 1024) or Odd(Size) or (Offset < 0) then
      raise EReadError.Create('Invalid AMR output size');
    if Size > 0 then
    begin
      var Buffer := FCodec.getOutputBuffer(Index);
      var Source := DirectBuffer(Buffer);
      if Offset > Buffer.capacity - Size then
        raise EReadError.Create('Invalid AMR output buffer bounds');
      FOutputOffset := 0;
      FOutputCount := Size div SizeOf(SmallInt);
      if FOutputCount > Length(FOutput) then
        SetLength(FOutput, FOutputCount);
      Move((Source + Offset)^, FOutput[0], Size);
    end;
    FOutputEnded := (FBufferInfo.flags and TJMediaCodec.JavaClass.BUFFER_FLAG_END_OF_STREAM) <> 0;
  finally
    FCodec.releaseOutputBuffer(Index, False);
  end;
end;

function TAMRSource.Render(var Samples: array of SmallInt; Frames: Integer): Integer;
begin
  ValidateRender(Length(Samples), Frames, 1);
  Result := 0;
  if Frames = 0 then
    Exit;
  if FCodec = nil then
    OpenCodec;
  var Idle := TStopwatch.StartNew;
  while Result < Frames do
  begin
    if FOutputOffset < FOutputCount then
    begin
      var Count := Min(Frames - Result, FOutputCount - FOutputOffset);
      Move(FOutput[FOutputOffset], Samples[Result], Count * SizeOf(SmallInt));
      Inc(FOutputOffset, Count);
      Inc(Result, Count);
      Continue;
    end;
    if FOutputEnded then
      Break;
    var Fed := FeedInput;
    var Received := ReadOutput(IfThen(Fed, 0, 10000));
    if Fed or Received then
      Idle := TStopwatch.StartNew
    else if Idle.ElapsedMilliseconds >= 2000 then
      raise EReadError.Create('AMR decoder stopped responding');
  end;
end;
{$ENDIF}

function OpenAMR(const Data: TBytes): IAudioSource;
begin
  {$IFDEF ANDROID}
  Result := TAMRSource.Create(Data);
  {$ELSEIF Defined(MSWINDOWS)}
  if DetectAMR(Data) <> TAMRKind.Narrowband then
    raise ENotSupportedException.Create('Windows AMR decoder requires an AMR-NB clip');
  Result := OpenWindowsAMR(Data, AMRPacketCount(Data, TAMRKind.Narrowband, 6));
  {$ELSE}
  raise ENotSupportedException.Create('AMR decoder is unavailable on this platform');
  {$ENDIF}
end;

end.

