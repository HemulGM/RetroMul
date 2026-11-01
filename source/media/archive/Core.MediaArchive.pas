unit Core.MediaArchive;

interface

uses
  System.Classes, System.SysUtils, Core.Storage, Core.Archive.Container;

type
  TMediaArchiveProbe = reference to function(Input: TStream): Boolean;

  TMediaArchiveReader = reference to function(Input: TStream; const Storage: IStorage): IArchiveContainer;

procedure RegisterMediaArchiveFormat(const Extension: string; const Reader: TMediaArchiveReader; const Probe: TMediaArchiveProbe = nil);

function MediaArchiveExtensions: TArray<string>;

function IsMediaArchive(const Name: string): Boolean;

function FindMediaArchive(const Storage: IStorage; const BaseName: string): string;
// Name selects a registered reader; empty names allow signature detection.
// An archive source view reuses its already opened container.

function OpenMediaArchive(Input: TStream; const Name: string = ''; const Storage: IStorage = nil): IArchiveContainer;

// Probes registered formats without treating the outer ROM name as payload type.
function HasMediaArchiveSignature(Input: TStream): Boolean;

function ReadMediaContainer(Stream: TStream): TBytes;

implementation

uses
  System.Generics.Collections, Core.Archive.Zip, Core.Archive.SevenZip,
  Core.Archive.RAR;

type
  TArchiveFormat = record
    Reader: TMediaArchiveReader;
    Probe: TMediaArchiveProbe;
  end;

var
  Readers: TDictionary<string, TArchiveFormat>;
  Extensions: TArray<string>;

procedure RegisterMediaArchiveFormat(const Extension: string; const Reader: TMediaArchiveReader; const Probe: TMediaArchiveProbe);
begin
  if (Length(Extension) < 2) or (Extension[1] <> '.') or not Assigned(Reader) or
    (ExtractFileExt('media' + Extension) <> Extension) then
    raise EArgumentException.Create('Archive registration needs an extension and reader');
  TMonitor.Enter(Readers);
  try
    var Key := Extension.ToLower;
    if Readers.ContainsKey(Key) then
      raise EArgumentException.Create('Duplicate archive extension: ' + Extension);
    var Value: TArchiveFormat;
    Value.Reader := Reader;
    Value.Probe := Probe;
    Readers.Add(Key, Value);
    Extensions := Extensions + [Key];
  finally TMonitor.Exit(Readers); end;
end;

function MediaArchiveExtensions: TArray<string>;
begin
  TMonitor.Enter(Readers);
  try Result := Copy(Extensions); finally TMonitor.Exit(Readers); end;
end;

function IsMediaArchive(const Name: string): Boolean;
begin
  TMonitor.Enter(Readers);
  try Result := Readers.ContainsKey(ExtractFileExt(Name).ToLower);
  finally TMonitor.Exit(Readers); end;
end;

function FindMediaArchive(const Storage: IStorage; const BaseName: string): string;
begin
  if Storage = nil then raise EArgumentNilException.Create('Storage');
  for var Extension in MediaArchiveExtensions do
    if Storage.Exists(BaseName + Extension) then Exit(BaseName + Extension);
  Result := '';
end;

function DetectArchive(Input: TStream; out Format: TArchiveFormat): Boolean;
begin
  var Formats: TArray<TArchiveFormat>;
  TMonitor.Enter(Readers);
  try
    SetLength(Formats, Length(Extensions));
    for var I := 0 to High(Formats) do Formats[I] := Readers[Extensions[I]];
  finally TMonitor.Exit(Readers); end;
  var Saved := Input.Position;
  try
    for var Candidate in Formats do
      if Assigned(Candidate.Probe) then
      begin
        TStorage.CheckReadCancelled;
        Input.Position := 0;
        if Candidate.Probe(Input) then
        begin Format := Candidate; Exit(True); end;
      end;
  finally Input.Position := Saved; end;
  Format := Default(TArchiveFormat);
  Result := False;
end;

function HasMediaArchiveSignature(Input: TStream): Boolean;
begin
  if Input = nil then raise EArgumentNilException.Create('Input');
  if Input is TArchiveSourceStream then Exit(TArchiveSourceStream(Input).Container <> nil);
  var Format: TArchiveFormat;
  Result := DetectArchive(Input, Format);
end;

function OpenMediaArchive(Input: TStream; const Name: string; const Storage: IStorage): IArchiveContainer;
begin
  if Input = nil then raise EArgumentNilException.Create('Input');
  if Input is TArchiveSourceStream then Exit(TArchiveSourceStream(Input).Container);
  var Format: TArchiveFormat;
  TMonitor.Enter(Readers);
  var Found: Boolean;
  try Found := Readers.TryGetValue(ExtractFileExt(Name).ToLower, Format);
  finally TMonitor.Exit(Readers); end;
  if not Found then Found := DetectArchive(Input, Format);
  if not Found then raise EReadError.Create('Unsupported archive format: ' + ExtractFileExt(Name));
  var Saved := Input.Position;
  var ReadFailed := False;
  try
    try
      try
      Input.Position := 0;
      Result := Format.Reader(Input, Storage);
      if Result = nil then raise EReadError.Create('Archive reader returned no container');
      except ReadFailed := True; raise; end;
    finally
      try Input.Position := Saved; except if not ReadFailed then raise; end;
    end;
  except Result := nil; raise; end;
end;

function ReadMediaContainer(Stream: TStream): TBytes;
const
  MaxSize = 256 * 1024 * 1024;
begin
  var Memory := TMemoryStream.Create;
  try
    var Buffer: array[0..65535] of Byte;
    while True do
    begin
      TStorage.CheckReadCancelled;
      var N := Stream.Read(Buffer, SizeOf(Buffer));
      if N = 0 then
        Break;
      if (N < 0) or (N > SizeOf(Buffer)) or (N > MaxSize - Memory.Size) then
        raise EReadError.Create('Media exceeds 256 MiB');
      Memory.WriteBuffer(Buffer, N);
    end;
    SetLength(Result, Memory.Size);
    if Memory.Size <> 0 then
      Move(Memory.Memory^, Result[0], Memory.Size);
  finally
    Memory.Free;
  end;
end;

initialization
  Readers := TDictionary<string, TArchiveFormat>.Create;
  RegisterMediaArchiveFormat('.zip', OpenZip, IsZipArchive);
  RegisterMediaArchiveFormat('.7z', OpenSevenZip, IsSevenZipArchive);
  RegisterMediaArchiveFormat('.rar', OpenRar, IsRarArchive);

finalization
  Readers.Free;

end.
