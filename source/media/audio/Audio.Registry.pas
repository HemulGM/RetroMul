unit Audio.Registry;

interface

uses
  System.SysUtils, System.Generics.Collections, Audio.Types, Audio.Decoder;

type
  TAudioDecoderFactory = function(const Data: TBytes): IAudioSource;

  TAudioContextFactory = function(const Data: TBytes; const Resolver: IAudioResolver): IAudioSource;

  TAudioDataLoader = function(const Path: string; const Data: TBytes): TBytes;

  IAudioRegistry = interface(IAudioResolver)
    ['{8B1FF8D4-4F66-4895-AFA2-13DA6E2CF907}']
    procedure RegisterFormat(const Extension, Description: string; Factory: TAudioDecoderFactory); overload;
    procedure RegisterFormat(const Extension, Description: string; Factory: TAudioContextFactory); overload;
    procedure RegisterDataLoader(const Extension: string; Loader: TAudioDataLoader);
    function Open(const Path: string): IAudioSource;
    function SupportedFormats: TArray<TAudioFormatInfo>;
    function DialogFilter: string;
  end;

  TAudioDecoderRegistration = record
    Extension, Description: string;
    Factory: TAudioDecoderFactory;
    ContextFactory: TAudioContextFactory;
    DataLoader: TAudioDataLoader;
  end;

  // Populate on the owning thread before publishing to decoder/player workers.
  TAudioRegistry = class(TInterfacedObject, IAudioRegistry, IAudioResolver)
  private
    FFormats: TList<TAudioDecoderRegistration>;
    procedure CheckDataSize(Size: Int64; const Extension: string);
  public
    constructor Create;
    destructor Destroy; override;
    procedure RegisterFormat(const Extension, Description: string; Factory: TAudioDecoderFactory); overload;
    procedure RegisterFormat(const Extension, Description: string; Factory: TAudioContextFactory); overload;
    procedure RegisterDataLoader(const Extension: string; Loader: TAudioDataLoader);
    function ReadData(const Path: string): TBytes;
    function Open(const Path: string): IAudioSource;
    function OpenData(const Data: TBytes; const Extension: string): IAudioSource;
    function SupportsFormat(const Extension: string): Boolean;
    function SupportedFormats: TArray<TAudioFormatInfo>;
    function DialogFilter: string;
  end;

implementation

uses
  System.IOUtils, System.Classes, System.Generics.Defaults;

threadvar
  DecoderDepth: Integer;

constructor TAudioRegistry.Create;
begin
  inherited;
  FFormats := TList<TAudioDecoderRegistration>.Create;
end;

destructor TAudioRegistry.Destroy;
begin
  FFormats.Free;
  inherited;
end;

procedure TAudioRegistry.RegisterFormat(const Extension, Description: string; Factory: TAudioContextFactory);
begin
  if (Extension = '') or (Extension[1] <> '.') or not Assigned(Factory) then
    raise EArgumentException.Create('Invalid decoder registration');
  if SupportsFormat(Extension) then
    raise EArgumentException.Create('Decoder already registered: ' + Extension);
  var Entry := Default(TAudioDecoderRegistration);
  Entry.Extension := LowerCase(Extension);
  Entry.Description := Description;
  Entry.ContextFactory := Factory;
  FFormats.Add(Entry);
end;

function TAudioRegistry.SupportsFormat(const Extension: string): Boolean;
begin
  for var Entry in FFormats do
    if SameText(Entry.Extension, Extension) then
      Exit(True);
  Result := False;
end;

procedure TAudioRegistry.RegisterFormat(const Extension, Description: string; Factory: TAudioDecoderFactory);
var
  Entry: TAudioDecoderRegistration;
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
  Entry.ContextFactory := nil;
  FFormats.Add(Entry);
end;

procedure TAudioRegistry.RegisterDataLoader(const Extension: string; Loader: TAudioDataLoader);
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

procedure TAudioRegistry.CheckDataSize(Size: Int64; const Extension: string);
begin
  if SameText(Extension, '.wav') then
  begin
    if Size > 512 * 1024 * 1024 then
      raise EArgumentException.Create('WAV file exceeds the 512 MiB limit');
  end
  else if Size > 16 * 1024 * 1024 then
    raise EArgumentException.Create('Music file exceeds the 16 MiB limit');
end;

function TAudioRegistry.ReadData(const Path: string): TBytes;
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

function TAudioRegistry.Open(const Path: string): IAudioSource;
begin
  Result := OpenData(ReadData(Path), ExtractFileExt(Path));
end;

function TAudioRegistry.OpenData(const Data: TBytes; const Extension: string): IAudioSource;
var
  Entry: TAudioDecoderRegistration;
begin
  for Entry in FFormats do
    if SameText(Extension, Entry.Extension) then
    begin
      CheckDataSize(Length(Data), Extension);
      if DecoderDepth >= 8 then
        raise EArgumentException.Create('Music containers are nested too deeply');
      Inc(DecoderDepth);
      try
        if Assigned(Entry.ContextFactory) then
          Result := Entry.ContextFactory(Data, Self)
        else
          Result := Entry.Factory(Data);
      finally
        Dec(DecoderDepth);
      end;
      Exit;
    end;
  raise EArgumentException.Create('Unsupported music format: ' + Extension);
end;

function TAudioRegistry.SupportedFormats: TArray<TAudioFormatInfo>;
begin
  SetLength(Result, FFormats.Count);
  for var I := 0 to FFormats.Count - 1 do
  begin
    Result[I].Extension := FFormats[I].Extension;
    Result[I].Description := FFormats[I].Description;
  end;
  TArray.Sort<TAudioFormatInfo>(Result, TComparer<TAudioFormatInfo>.Construct(
    function(const Left, Right: TAudioFormatInfo): Integer
    begin
      Result := CompareStr(Left.Extension, Right.Extension);
    end));
end;

function TAudioRegistry.DialogFilter: string;
var
  Entry: TAudioDecoderRegistration;
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

