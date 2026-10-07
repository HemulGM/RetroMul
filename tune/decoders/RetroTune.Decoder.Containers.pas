unit RetroTune.Decoder.Containers;

interface

implementation

uses
  System.SysUtils, System.Math, System.Generics.Collections, RetroTune.Decoder,
  RetroTune.Binary, RetroTune.VortexText;

type
  TMixedDecoder = class(TInterfacedObject, ITuneDecoder)
  private
    FStreams: TArray<ITuneDecoder>;
    FEnded: TArray<Boolean>;
    FInfo: TTuneInfo;
  public
    constructor Create(const Streams: TArray<ITuneDecoder>; const Kind, Title, Author: string);
    function GetInfo: TTuneInfo;
    procedure SelectTrack(Index: Integer);
    function Render(var Samples: array of SmallInt; Frames: Integer): Integer;
  end;

constructor TMixedDecoder.Create(const Streams: TArray<ITuneDecoder>; const Kind, Title, Author: string);
begin
  inherited Create;
  if (Length(Streams) = 0) or (Length(Streams) > 32) then
    raise EArgumentException.Create('Invalid container stream count');
  FStreams := Copy(Streams);
  SetLength(FEnded, Length(Streams));
  FInfo := Streams[0].GetInfo;
  if Title <> '' then
    FInfo.Title := Title;
  if Author <> '' then
    FInfo.Artist := Author;
  FInfo.FormatName := Kind;
  FInfo.TrackCount := 1;
  FInfo.DefaultTrack := 0;
  FInfo.Channels := 2;
  FInfo.SampleRate := 44100;
  FInfo.Details := '';
  var Duration := 0.0;
  for var Decoder in FStreams do
  begin
    var Info := Decoder.GetInfo;
    if (Info.SampleRate <> 44100) or (Info.Channels <> 2) or (Info.TrackCount <> 1) then
      raise EArgumentException.Create('Container requires single-song stereo streams at 44100 Hz');
    if (Length(Info.TrackDurations) <> 1) or (Info.TrackDurations[0] < 0) then
      raise EArgumentException.Create('Container stream has unknown length');
    Duration := Max(Duration, Info.TrackDurations[0]);
    if FInfo.Details <> '' then
      FInfo.Details := FInfo.Details + ' + ';
    FInfo.Details := FInfo.Details + Info.FormatName;
  end;
  FInfo.Details := Format('%d simultaneous streams: %s', [Length(Streams), FInfo.Details]);
  FInfo.TrackDurations := [Duration];
  FInfo.TrackNames := nil;
  SelectTrack(0);
end;

function TMixedDecoder.GetInfo: TTuneInfo;
begin
  Result := FInfo;
end;

procedure TMixedDecoder.SelectTrack(Index: Integer);
begin
  if Index <> 0 then
    raise EArgumentOutOfRangeException.Create('Container track');
  for var I := 0 to High(FStreams) do
  begin
    FStreams[I].SelectTrack(0);
    FEnded[I] := False;
  end;
end;

function TMixedDecoder.Render(var Samples: array of SmallInt; Frames: Integer): Integer;
var
  PCM: TArray<SmallInt>;
  Sum: TArray<Integer>;
begin
  ValidateRender(Length(Samples), Frames, 2);
  SetLength(PCM, Frames * 2);
  SetLength(Sum, Frames * 2);
  Result := 0;
  for var Stream := 0 to High(FStreams) do
    if not FEnded[Stream] then
    begin
      var Count := FStreams[Stream].Render(PCM, Frames);
      if Count < Frames then
        FEnded[Stream] := True;
      Result := Max(Result, Count);
      for var I := 0 to Count * 2 - 1 do
        Inc(Sum[I], PCM[I]);
    end;
  for var I := 0 to Result * 2 - 1 do
    Samples[I] := Sum[I] div Length(FStreams);
end;

function OpenTXT(const Data: TBytes): ITuneDecoder;
begin
  var Decoder := TTuneDecoders.OpenData(CompileVortexText(Data), '.pt3');
  Result := TMixedDecoder.Create([Decoder], 'Vortex TXT', '', '');
end;

function OpenTS(const Data: TBytes): ITuneDecoder;
begin
  RequireBytes(Data, Length(Data) - 16, 16);
  var Footer := Length(Data) - 16;
  if TEncoding.ASCII.GetString(Data, Footer + 12, 4) <> '02TS' then
    raise EArgumentException.Create('Invalid TurboSound footer');
  var Size1 := LE16(Data, Footer + 4);
  var Size2 := LE16(Data, Footer + 10);
  if (Size1 = 0) or (Size2 = 0) or (Integer(Size1) + Size2 <> Footer) then
    raise EArgumentException.Create('Invalid TurboSound sizes');
  var Kind1 := TEncoding.ASCII.GetString(Data, Footer, 4);
  var Kind2 := TEncoding.ASCII.GetString(Data, Footer + 6, 4);
  if (Kind1[4] <> '!') or (Kind2[4] <> '!') then
    raise EArgumentException.Create('Invalid TurboSound module IDs');
  var A := TTuneDecoders.OpenData(Copy(Data, 0, Size1), '.' + Copy(Kind1, 1, 3).Trim);
  var B := TTuneDecoders.OpenData(Copy(Data, Size1, Size2), '.' + Copy(Kind2, 1, 3).Trim);
  Result := TMixedDecoder.Create([A, B], 'TS', '', '');
end;

function Embedded(const Data: TBytes; const Filename: string): ITuneDecoder;
begin
  RequireBytes(Data, 0, 8);
  var Start := TEncoding.ASCII.GetString(Data, 0, Min(32, Length(Data)));
  var Ext := '';
  if Start.StartsWith('ProTracker 3.') or Start.StartsWith('Vortex Tracker II') then
    Ext := '.pt3'
  else if Start.StartsWith('TFMcom') then
    Ext := '.tfc'
  else if Start.StartsWith('TFMD') then
    Ext := '.tfd'
  else if Start.StartsWith('TFMfmtV2') then
    Ext := '.tfe'
  else if Start.StartsWith('[Module]') then
    Ext := '.txt'
  else if (Length(Data) >= 16) and (TEncoding.ASCII.GetString(Data, Length(Data) - 4, 4) = '02TS') then
    Ext := '.ts';
  if Ext = '' then
  begin
    var Hint := LowerCase(ExtractFileExt(Filename));
    if (Hint <> '.mtc') and TTuneDecoders.DialogFilter.Contains(' (*' + Hint + ')|') then
      Ext := Hint;
  end;
  if Ext = '' then
    raise ENotSupportedException.Create('Unsupported MTC embedded stream');
  Result := TTuneDecoders.OpenData(Data, Ext);
end;

function OpenMTC(const Data: TBytes): ITuneDecoder;
var
  Streams: TList<ITuneDecoder>;
  Title, Author: string;

  procedure Chunks(BeginAt, EndAt: Integer; Track: Boolean);
  begin
    var At := BeginAt;
    var Selected: ITuneDecoder := nil;
    var Filename := '';
    if Track then
    begin
      // Properties may follow DATA. Read the filename hint before choosing a stream.
      while At < EndAt do
      begin
        RequireBytes(Data, At, 8);
        if EndAt - At < 8 then
          raise EArgumentException.Create('Truncated MTC chunk header');
        var Kind := TEncoding.ASCII.GetString(Data, At, 4);
        var Size := Cardinal(Data[At + 4]) * 16777216 + Cardinal(Data[At + 5]) * 65536 +
          Cardinal(Data[At + 6]) * 256 + Data[At + 7];
        Inc(At, 8);
        if Size > Cardinal(EndAt - At) then
          raise EArgumentException.Create('MTC chunk exceeds parent');
        if Kind = 'PROP' then
        begin
          var PropertyText := TextField(Data, At, Integer(Size));
          if PropertyText.StartsWith('Filename=') then
            Filename := PropertyText.Substring(9);
        end;
        Inc(At, Integer(Size) + (Integer(Size) and 1));
        if At > EndAt then
          raise EArgumentException.Create('Missing MTC chunk padding');
      end;
      At := BeginAt;
    end;
    while At < EndAt do
    begin
      RequireBytes(Data, At, 8);
      if EndAt - At < 8 then
        raise EArgumentException.Create('Truncated MTC chunk header');
      var Kind := TEncoding.ASCII.GetString(Data, At, 4);
      var Size := Cardinal(Data[At + 4]) * 16777216 + Cardinal(Data[At + 5]) * 65536 +
        Cardinal(Data[At + 6]) * 256 + Data[At + 7];
      Inc(At, 8);
      if Size > Cardinal(EndAt - At) then
        raise EArgumentException.Create('MTC chunk exceeds parent');
      var Count := Integer(Size);
      if (Kind = 'TRCK') and not Track then
        Chunks(At, At + Count, True)
      else if (Kind = 'DATA') and Track and (Selected = nil) then
      begin
        try
          Selected := Embedded(Copy(Data, At, Count), Filename);
        except
          on E: ENotSupportedException do
            Selected := nil;
          on E: EArgumentException do
            Selected := nil;
          on E: EConvertError do
            Selected := nil;
          on E: EEncodingError do
            Selected := nil;
        end;
      end
      else if not Track then
      begin
        if Kind = 'NAME' then
          Title := TextField(Data, At, Count)
        else if Kind = 'AUTH' then
          Author := TextField(Data, At, Count);
      end;
      Inc(At, Count + (Count and 1));
      if At > EndAt then
        raise EArgumentException.Create('Missing MTC chunk padding');
    end;
    if Track then
    begin
      if Selected = nil then
        raise EArgumentException.Create('MTC track has no audio stream');
      if Streams.Count >= 32 then
        raise EArgumentException.Create('Too many MTC tracks');
      Streams.Add(Selected);
    end;
  end;

begin
  RequireBytes(Data, 0, 8);
  if TEncoding.ASCII.GetString(Data, 0, 4) <> 'MTC1' then
    raise EArgumentException.Create('Invalid MTC signature');
  var Size := Cardinal(Data[4]) * 16777216 + Cardinal(Data[5]) * 65536 + Cardinal(Data[6]) * 256 + Data[7];
  if Size <> Cardinal(Length(Data) - 8) then
    raise EArgumentException.Create('Invalid MTC root size');
  Streams := TList<ITuneDecoder>.Create;
  try
    Chunks(8, Length(Data), False);
    Result := TMixedDecoder.Create(Streams.ToArray, 'MTC', Title, Author);
  finally
    Streams.Free;
  end;
end;

initialization
  TTuneDecoders.RegisterFormat('.txt', 'Vortex Tracker text module', OpenTXT);
  TTuneDecoders.RegisterFormat('.ts', 'TurboSound container', OpenTS);
  TTuneDecoders.RegisterFormat('.mtc', 'Multitrack audio container', OpenMTC);

end.

