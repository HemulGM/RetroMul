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

function OpenAMRForPlayback(const Data: TBytes): IAudioSource;

implementation

uses
  System.Classes, System.Math, Audio.Decoder, Audio.AMR.Storage;

type
  TAMRSource = class(TInterfacedObject, IAudioSource, IAudioMetadata, IAudioTracks)
  private
    FInput: TBytesStream;
    FReader: TAMRStorageReader;
    FFormat: TAudioFormat;
    FInfo: TAudioInfo;
    FBlock: TArray<SmallInt>;
    FBlockOffset: Integer;
  public
    constructor Create(const Data: TBytes; DownmixSurround: Boolean);
    destructor Destroy; override;
    function GetFormat: TAudioFormat;
    function GetInfo: TAudioInfo;
    procedure SelectTrack(Index: Integer);
    function Render(var Samples: array of SmallInt; Frames: Integer): Integer;
  end;

function DetectAMR(const Data: TBytes): TAMRKind;
begin
  var Codec: TAMRCodec;
  if not DetectAMRStorage(Data, Codec) then
    Exit(TAMRKind.Unknown);
  if Codec = TAMRCodec.Narrowband then
    Result := TAMRKind.Narrowband
  else
    Result := TAMRKind.Wideband;
end;

function SupportsAMR(Kind: TAMRKind): Boolean;
begin
  Result := Kind in [TAMRKind.Narrowband, TAMRKind.Wideband];
end;

function AMRFrameSize(Header: Byte; Kind: TAMRKind): Integer;
begin
  case Kind of
    TAMRKind.Narrowband:
      Result := AMRStorageFrameSize(Header, TAMRCodec.Narrowband);
    TAMRKind.Wideband:
      Result := AMRStorageFrameSize(Header, TAMRCodec.Wideband);
  else
    Result := 0;
  end;
end;

constructor TAMRSource.Create(const Data: TBytes; DownmixSurround: Boolean);
begin
  inherited Create;
  FInput := TBytesStream.Create(Data);
  FReader := TAMRStorageReader.Create(FInput);
  var BlockCount := FReader.CountRemainingBlocks;
  if BlockCount = 0 then
    raise EReadError.Create('AMR clip is empty');

  FFormat.SampleRate := FReader.SampleRate;
  FFormat.Channels := FReader.Channels;
  if DownmixSurround and (FFormat.Channels > 2) then
    FFormat.Channels := 1;
  FInfo.SampleRate := FFormat.SampleRate;
  FInfo.Channels := FFormat.Channels;
  FInfo.TrackCount := 1;
  FInfo.TrackDurations := [BlockCount / 50];
  if FReader.Codec = TAMRCodec.Narrowband then
    FInfo.FormatName := 'AMR-NB'
  else
    FInfo.FormatName := 'AMR-WB';
end;

destructor TAMRSource.Destroy;
begin
  FReader.Free;
  FInput.Free;
  inherited;
end;

function TAMRSource.GetFormat: TAudioFormat;
begin
  Result := FFormat;
end;

function TAMRSource.GetInfo: TAudioInfo;
begin
  Result := FInfo;
end;

procedure TAMRSource.SelectTrack(Index: Integer);
begin
  if Index <> 0 then
    raise EArgumentOutOfRangeException.Create('AMR track index');
  FreeAndNil(FReader);
  FInput.Position := 0;
  FReader := TAMRStorageReader.Create(FInput);
  FBlock := nil;
  FBlockOffset := 0;
end;

function TAMRSource.Render(var Samples: array of SmallInt; Frames: Integer): Integer;
begin
  ValidateRender(Length(Samples), Frames, FFormat.Channels);
  Result := 0;
  while Result < Frames do
  begin
    if FBlockOffset = Length(FBlock) then
    begin
      FBlockOffset := 0;
      if not FReader.ReadBlock(FBlock) then
        Break;
    end;
    var Channels := FReader.Channels;
    var Count := Min(Frames - Result, (Length(FBlock) - FBlockOffset) div Channels);
    if Channels = FFormat.Channels then
      Move(FBlock[FBlockOffset], Samples[Result * Channels], Count * Channels * SizeOf(SmallInt))
    else
    begin
      // The PCM output accepts one or two channels. Preserve every input
      // channel at equal gain, regardless of the file's channel layout.
      for var Frame := 0 to Count - 1 do
      begin
        var Sum := 0;
        for var Channel := 0 to Channels - 1 do
          Inc(Sum, FBlock[FBlockOffset + Frame * Channels + Channel]);
        Samples[Result + Frame] := SmallInt(Sum div Channels);
      end;
    end;
    Inc(FBlockOffset, Count * Channels);
    Inc(Result, Count);
  end;
end;

function OpenAMR(const Data: TBytes): IAudioSource;
begin
  Result := TAMRSource.Create(Data, False);
end;

function OpenAMRForPlayback(const Data: TBytes): IAudioSource;
begin
  Result := TAMRSource.Create(Data, True);
end;

end.

