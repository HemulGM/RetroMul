unit Audio.Format.FLAC;

interface

uses
  System.SysUtils, Audio.Types;

function OpenFLAC(const Data: TBytes): IAudioSource;

implementation

uses
  System.Classes, System.Math, Audio.Decoder, Audio.Binary, CHD.FLAC;

type
  TFLACSource = class(TAudioMusicSource)
  private
    FData, FBlock: TBytes;
    FInfo: TAudioInfo;
    FStart, FOffset, FBlockOffset, FDepth: Integer;
    FSampleCount, FDecoded: Int64;
    procedure DecodeBlock;
  public
    constructor Create(const Data: TBytes);
    function GetInfo: TAudioInfo; override;
    procedure SelectTrack(Index: Integer); override;
    function Render(var Samples: array of SmallInt; Frames: Integer): Integer; override;
  end;

constructor TFLACSource.Create(const Data: TBytes);
begin
  inherited Create;
  RequireBytes(Data, 0, 42);
  if LE32(Data, 0) <> $43614C66 then
    raise EArgumentException.Create('Invalid FLAC signature');
  if ((Data[4] and $7F) <> 0) or (Data[5] <> 0) or (Data[6] <> 0) or (Data[7] <> 34) then
    raise EArgumentException.Create('FLAC STREAMINFO block is missing');

  FInfo.SampleRate := (Integer(Data[18]) shl 12) or (Integer(Data[19]) shl 4) or (Data[20] shr 4);
  FInfo.Channels := ((Data[20] shr 1) and 7) + 1;
  FDepth := (((Data[20] and 1) shl 4) or (Data[21] shr 4)) + 1;
  FSampleCount := (Int64(Data[21] and 15) shl 32) or (Int64(Data[22]) shl 24) or
    (Int64(Data[23]) shl 16) or (Int64(Data[24]) shl 8) or Data[25];
  if (FInfo.SampleRate <= 0) or not (FInfo.Channels in [1, 2]) or (FDepth < 4) or (FDepth > 24) then
    raise ENotSupportedException.Create('FLAC requires mono or stereo audio with 4 to 24 bits per sample');

  FStart := 4;
  var Last: Boolean;
  repeat
    RequireBytes(Data, FStart, 4);
    Last := (Data[FStart] and $80) <> 0;
    var Size := (Integer(Data[FStart + 1]) shl 16) or (Integer(Data[FStart + 2]) shl 8) or Data[FStart + 3];
    Inc(FStart, 4);
    RequireBytes(Data, FStart, Size);
    Inc(FStart, Size);
  until Last;
  FData := Data;
  FInfo.TrackCount := 1;
  FInfo.FormatName := 'FLAC';
  FInfo.Details := Format('%d-bit FLAC', [FDepth]);
  if FSampleCount > 0 then
    FInfo.TrackDurations := [FSampleCount / FInfo.SampleRate];
  SelectTrack(0);
  DecodeBlock;
end;

procedure TFLACSource.DecodeBlock;
begin
  var Consumed: Integer;
  FBlock := DecodeFLACFrame(FData, FOffset, FInfo.Channels, FDepth, FInfo.SampleRate, Consumed);
  Inc(FOffset, Consumed);
  Inc(FDecoded, Length(FBlock) div (SizeOf(SmallInt) * FInfo.Channels));
  if (FSampleCount <> 0) and ((FDecoded > FSampleCount) or
    ((FOffset = Length(FData)) and (FDecoded <> FSampleCount))) then
    raise EReadError.Create('FLAC sample count differs from STREAMINFO');
  FBlockOffset := 0;
end;

function TFLACSource.GetInfo: TAudioInfo;
begin
  Result := FInfo;
end;

procedure TFLACSource.SelectTrack(Index: Integer);
begin
  if Index <> 0 then
    raise EArgumentOutOfRangeException.Create('FLAC track index');
  FOffset := FStart;
  FBlock := nil;
  FBlockOffset := 0;
  FDecoded := 0;
end;

function TFLACSource.Render(var Samples: array of SmallInt; Frames: Integer): Integer;
begin
  ValidateRender(Length(Samples), Frames, FInfo.Channels);
  Result := 0;
  var FrameBytes := FInfo.Channels * SizeOf(SmallInt);
  while Result < Frames do
  begin
    if FBlockOffset = Length(FBlock) then
    begin
      if FOffset = Length(FData) then
        Break;
      DecodeBlock;
    end;
    var Count := Min(Frames - Result, (Length(FBlock) - FBlockOffset) div FrameBytes);
    Move(FBlock[FBlockOffset], Samples[Result * FInfo.Channels], Count * FrameBytes);
    Inc(FBlockOffset, Count * FrameBytes);
    Inc(Result, Count);
  end;
end;

function OpenFLAC(const Data: TBytes): IAudioSource;
begin
  Result := TFLACSource.Create(Data);
end;

end.

