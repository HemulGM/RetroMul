unit Core.MediaArchive;

interface

uses System.Classes, System.SysUtils;

type
  // Other archive formats supply a canonical ZIP, so set/disc loaders and
  // individual-image recognizers all gain support without platform changes.
  TMediaArchiveDecoder = reference to function(const Data: TBytes): TBytes;

procedure RegisterMediaArchiveFormat(const Extension: string; const Decoder: TMediaArchiveDecoder);
function IsMediaArchive(const Name: string): Boolean;
function DecodeMediaArchive(const Name: string; const Data: TBytes): TBytes;
function ReadMediaContainer(Stream: TStream): TBytes;

implementation

uses System.Generics.Collections, Core.Archive.SevenZip, Core.Storage;

var
  Decoders: TDictionary<string, TMediaArchiveDecoder>;

procedure RegisterMediaArchiveFormat(const Extension: string; const Decoder: TMediaArchiveDecoder);
begin
  if (Extension = '') or (Extension[1] <> '.') or not Assigned(Decoder) then
    raise EArgumentException.Create('Archive registration needs an extension and decoder');
  Decoders.Add(Extension.ToLower, Decoder);
end;

function IsMediaArchive(const Name: string): Boolean;
begin
  Result := SameText(ExtractFileExt(Name), '.zip') or Decoders.ContainsKey(ExtractFileExt(Name).ToLower);
end;

function DecodeMediaArchive(const Name: string; const Data: TBytes): TBytes;
begin
  var Decoder: TMediaArchiveDecoder;
  if not Decoders.TryGetValue(ExtractFileExt(Name).ToLower, Decoder) then
    raise EReadError.Create('Unsupported archive format');
  Result := Decoder(Data);
end;

function ReadMediaContainer(Stream: TStream): TBytes;
const
  MaxContainerSize = 256 * 1024 * 1024;
begin
  var Buffer: array[0..65535] of Byte;
  var Memory := TMemoryStream.Create;
  try
    while True do
    begin
      TStorage.CheckReadCancelled;
      var Count := Stream.Read(Buffer, SizeOf(Buffer));
      if Count = 0 then Break;
      if (Count < 0) or (Memory.Size + Count > MaxContainerSize) then
        raise EReadError.Create('Media container exceeds 256 MiB');
      Memory.WriteBuffer(Buffer, Count);
    end;
    SetLength(Result, Memory.Size);
    if Memory.Size <> 0 then Move(Memory.Memory^, Result[0], Memory.Size);
  finally
    Memory.Free;
  end;
end;

initialization
  Decoders := TDictionary<string, TMediaArchiveDecoder>.Create;
  RegisterMediaArchiveFormat('.7z',
    function(const Data: TBytes): TBytes
    begin
      Result := SevenZipAsZip(Data);
    end);
finalization
  Decoders.Free;
end.
