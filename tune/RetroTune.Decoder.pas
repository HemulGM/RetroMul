unit RetroTune.Decoder;

interface

uses
  System.SysUtils, System.Generics.Collections;

type
  TTuneInfo = record
    Title, Artist, CopyrightText, FormatName, Details: string;
    TrackCount, DefaultTrack, SampleRate, Channels: Integer;
    TrackNames: TArray<string>;
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

  TTuneDecoderFactory = function(const Data: TBytes): ITuneDecoder;

  TTuneDecoderRegistration = record
    Extension, Description: string;
    Factory: TTuneDecoderFactory;
  end;

  TTuneDecoders = class
  private
    class var
      FFormats: TList<TTuneDecoderRegistration>;
  public
    class constructor Create;
    class destructor Destroy;
    // Register during unit initialization, before any player is started.
    class procedure RegisterFormat(const Extension, Description: string; Factory: TTuneDecoderFactory);
    class function Open(const Path: string): ITuneDecoder;
    class function DialogFilter: string;
  end;

implementation

uses
  System.IOUtils;

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
  Entry.Extension := LowerCase(Extension);
  Entry.Description := Description;
  Entry.Factory := Factory;
  FFormats.Add(Entry);
end;

class function TTuneDecoders.Open(const Path: string): ITuneDecoder;
var
  Entry: TTuneDecoderRegistration;
begin
  for Entry in FFormats do
    if SameText(ExtractFileExt(Path), Entry.Extension) then
    begin
      if TFile.GetSize(Path) > 16 * 1024 * 1024 then
        raise EArgumentException.Create('Music file exceeds the 16 MiB limit');
      Exit(Entry.Factory(TFile.ReadAllBytes(Path)));
    end;
  raise EArgumentException.Create('Unsupported music format: ' + ExtractFileExt(Path));
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
  Result := 'Поддерживаемые форматы|' + Patterns;
  for Entry in FFormats do
  begin
    if Result <> '' then
      Result := Result + '|';
    Result := Result + Entry.Description + ' (*' + Entry.Extension + ')|*' + Entry.Extension;
  end;
end;

end.

