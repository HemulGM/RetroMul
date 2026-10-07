unit RetroTune.Decoder;

interface

uses
  System.SysUtils, System.Generics.Collections;

type
  TTuneMetadataField = record
    Name, Value: string;
  end;

  TTuneInfo = record
    Title, Artist, CopyrightText, FormatName, Details: string;
    TrackCount, DefaultTrack, SampleRate, Channels: Integer;
    TrackNames: TArray<string>;
    // Seconds per logical track; missing entries / negative values mean unknown.
    TrackDurations: TArray<Double>;
    Metadata: TArray<TTuneMetadataField>;
  end;

  // Decoder methods run exclusively on the playback thread after creation.
  // PCM is interleaved signed 16-bit; counts and return values are FRAMES.
  // SelectTrack uses a zero-based index and resets the stream to its beginning.
  // Render returns 0 at EOF, allowing formats with finite tracks in the future.
  ITuneDecoder = interface
    ['{B678AC92-52F7-49E6-8CA2-DB39B96BD14E}']
    function GetInfo: TTuneInfo;
    procedure SelectTrack(Index: Integer);
    function Render(var Samples: array of SmallInt; Frames: Integer): Integer;
  end;

  TTuneDataLoader = function(const Path: string; const Data: TBytes): TBytes;

  TTuneDecoderFactory = function(const Data: TBytes): ITuneDecoder;

  TTuneFormatInfo = record
    Extension, Description: string;
  end;

  TTuneDecoderRegistration = record
    Extension, Description: string;
    Factory: TTuneDecoderFactory;
    DataLoader: TTuneDataLoader;
  end;

  TTuneDecoders = class
  private
    class var
      FFormats: TList<TTuneDecoderRegistration>;
    class procedure CheckDataSize(Size: Int64; const Extension: string); static;
  public
    class constructor Create;
    class destructor Destroy;
    // Register during unit initialization, before any player is started.
    class procedure RegisterFormat(const Extension, Description: string; Factory: TTuneDecoderFactory);
    class procedure RegisterDataLoader(const Extension: string; Loader: TTuneDataLoader);
    class function ReadData(const Path: string): TBytes;
    class function Open(const Path: string): ITuneDecoder;
    class function OpenData(const Data: TBytes; const Extension: string): ITuneDecoder;
    class function DialogFilter: string;
    class function SupportedFormats: TArray<TTuneFormatInfo>;
  end;

implementation

uses
  System.IOUtils, System.Classes, System.Generics.Defaults;

threadvar
  DecoderDepth: Integer;

class constructor TTuneDecoders.Create;
begin
  FFormats := TList<TTuneDecoderRegistration>.Create;
end;

class destructor TTuneDecoders.Destroy;
begin
  FFormats.Free;
end;

class procedure TTuneDecoders.RegisterFormat(const Extension, Description: string; Factory: TTuneDecoderFactory);
var
  Entry: TTuneDecoderRegistration;
begin
  if (Extension = '') or (Extension[1] <> '.') or not Assigned(Factory) then
    raise EArgumentException.Create('Invalid decoder registration');
  for Entry in FFormats do
    if SameText(Entry.Extension, Extension) then
      raise EArgumentException.Create('Decoder already registered: ' + Extension);
  Entry.DataLoader := nil;
  Entry.Extension := LowerCase(Extension);
  Entry.Description := Description;
  Entry.Factory := Factory;
  FFormats.Add(Entry);
end;

class procedure TTuneDecoders.RegisterDataLoader(const Extension: string; Loader: TTuneDataLoader);
begin
  if not Assigned(Loader) then
    raise EArgumentException.Create('Invalid music data loader');
  for var I := 0 to FFormats.Count - 1 do
    if SameText(Extension, FFormats[I].Extension) then
    begin
      var Entry := FFormats[I];
      Entry.DataLoader := Loader;
      FFormats[I] := Entry;
      Exit;
    end;
  raise EArgumentException.Create('Register the decoder before its data loader');
end;

class procedure TTuneDecoders.CheckDataSize(Size: Int64; const Extension: string);
begin
  if SameText(Extension, '.wav') then
  begin
    if Size > 512 * 1024 * 1024 then
      raise EArgumentException.Create('WAV file exceeds the 512 MiB limit');
  end
  else if Size > 16 * 1024 * 1024 then
    raise EArgumentException.Create('Music file exceeds the 16 MiB limit');
end;

class function TTuneDecoders.ReadData(const Path: string): TBytes;
begin
  var Input := TFileStream.Create(Path, fmOpenRead or fmShareDenyWrite);
  try
    CheckDataSize(Input.Size, ExtractFileExt(Path));
    SetLength(Result, Integer(Input.Size));
    if Length(Result) > 0 then
      Input.ReadBuffer(Result[0], Length(Result));
  finally
    Input.Free;
  end;
  for var Entry in FFormats do
    if SameText(ExtractFileExt(Path), Entry.Extension) and Assigned(Entry.DataLoader) then
    begin
      Result := Entry.DataLoader(Path, Result);
      CheckDataSize(Length(Result), Entry.Extension);
      Break;
    end;
end;

class function TTuneDecoders.Open(const Path: string): ITuneDecoder;
begin
  Result := OpenData(ReadData(Path), ExtractFileExt(Path));
end;

class function TTuneDecoders.OpenData(const Data: TBytes; const Extension: string): ITuneDecoder;
var
  Entry: TTuneDecoderRegistration;
begin
  for Entry in FFormats do
    if SameText(Extension, Entry.Extension) then
    begin
      CheckDataSize(Length(Data), Extension);
      if DecoderDepth >= 8 then
        raise EArgumentException.Create('Music containers are nested too deeply');
      Inc(DecoderDepth);
      try
        Result := Entry.Factory(Data);
      finally
        Dec(DecoderDepth);
      end;
      Exit;
    end;
  raise EArgumentException.Create('Unsupported music format: ' + Extension);
end;

class function TTuneDecoders.SupportedFormats: TArray<TTuneFormatInfo>;
begin
  SetLength(Result, FFormats.Count);
  for var I := 0 to FFormats.Count - 1 do
  begin
    Result[I].Extension := FFormats[I].Extension;
    Result[I].Description := FFormats[I].Description;
  end;
  TArray.Sort<TTuneFormatInfo>(Result, TComparer<TTuneFormatInfo>.Construct(
    function(const Left, Right: TTuneFormatInfo): Integer
    begin
      Result := CompareStr(Left.Extension, Right.Extension);
    end));
end;

class function TTuneDecoders.DialogFilter: string;
var
  Entry: TTuneDecoderRegistration;
  Patterns: string;
begin
  Patterns := '';
  for Entry in FFormats do
  begin
    if Patterns <> '' then
      Patterns := Patterns + ';';
    Patterns := Patterns + '*' + Entry.Extension;
  end;
  Result := 'Supported formats|' + Patterns;
  for Entry in FFormats do
  begin
    if Result <> '' then
      Result := Result + '|';
    Result := Result + Entry.Description + ' (*' + Entry.Extension + ')|*' + Entry.Extension;
  end;
end;

end.

