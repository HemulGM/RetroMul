unit Audio.Decoder;

interface

uses
  System.SysUtils, Audio.Types;

type
  // Containers retain only the resolver supplied by their caller. No global registry.
  IAudioResolver = interface
    ['{866DC310-33E6-4AE1-90CD-FF4CDE6DE4F9}']
    function OpenData(const Data: TBytes; const Extension: string): IAudioSource;
    function ReadData(const Path: string): TBytes;
    function SupportsFormat(const Extension: string): Boolean;
  end;

  TAudioMusicSource = class abstract(TInterfacedObject, IAudioSource, IAudioMetadata, IAudioTracks)
  public
    function GetFormat: TAudioFormat;
    function GetInfo: TAudioInfo; virtual; abstract;
    procedure SelectTrack(Index: Integer); virtual; abstract;
    function Render(var Samples: array of SmallInt; Frames: Integer): Integer; virtual; abstract;
  end;

function GetAudioInfo(const Source: IAudioSource): TAudioInfo;

procedure SelectAudioTrack(const Source: IAudioSource; Index: Integer);

procedure PrepareAudioSource(const Source: IAudioSource; Index: Integer; RestartRequired: Boolean);

procedure ValidateRender(Available, Frames, Channels: Integer);

implementation

function TAudioMusicSource.GetFormat: TAudioFormat;
begin
  var Info := GetInfo;
  Result.SampleRate := Info.SampleRate;
  Result.Channels := Info.Channels;
end;

function GetAudioInfo(const Source: IAudioSource): TAudioInfo;
begin
  if Source = nil then
    raise EArgumentNilException.Create('Audio source is required');
  Result := Default(TAudioInfo);
  var Metadata: IAudioMetadata;
  if Supports(Source, IAudioMetadata, Metadata) then
    Result := Metadata.GetInfo;
  var Format := Source.GetFormat;
  Result.SampleRate := Format.SampleRate;
  Result.Channels := Format.Channels;
  var Tracks: IAudioTracks;
  if not Supports(Source, IAudioTracks, Tracks) then
  begin
    Result.TrackCount := 1;
    Result.DefaultTrack := 0;
  end;
end;

procedure SelectAudioTrack(const Source: IAudioSource; Index: Integer);
begin
  if Source = nil then
    raise EArgumentNilException.Create('Audio source is required');
  var Tracks: IAudioTracks;
  if Supports(Source, IAudioTracks, Tracks) then
  begin
    Tracks.SelectTrack(Index);
    Exit;
  end;
  if Index <> 0 then
    raise EArgumentOutOfRangeException.Create('Audio source has no selectable tracks');
  var Seeker: IAudioSeekSource;
  if Supports(Source, IAudioSeekSource, Seeker) then
    Seeker.SeekFrame(0, nil)
  else
    raise ENotSupportedException.Create('Audio source cannot restart');
end;

procedure ValidateRender(Available, Frames, Channels: Integer);
begin
  if (Frames < 0) or (Frames > 4096) or (Channels < 1) or (Frames > Available div Channels) then
    raise EArgumentOutOfRangeException.Create('Invalid PCM frame count (maximum 4096)');
end;

procedure PrepareAudioSource(const Source: IAudioSource; Index: Integer; RestartRequired: Boolean);
begin
  if Source = nil then
    raise EArgumentNilException.Create('Audio source is required');
  if Supports(Source, IAudioTracks) or Supports(Source, IAudioSeekSource) then
    SelectAudioTrack(Source, Index)
  else if Index <> 0 then
    raise EArgumentOutOfRangeException.Create('Audio source has no selectable tracks')
  else if RestartRequired then
    raise ENotSupportedException.Create('Audio source cannot restart');
  // A fresh forward-only source can be consumed without any optional interface.
end;

end.

