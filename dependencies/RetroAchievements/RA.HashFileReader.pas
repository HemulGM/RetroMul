unit RA.HashFileReader;

interface

uses
  System.Classes;

type
  TRAHashFileOpen = function(Path: PAnsiChar): Pointer; cdecl;

  TRAHashFileSeek = procedure(Handle: Pointer; Offset: Int64; Origin: Integer); cdecl;

  TRAHashFileTell = function(Handle: Pointer): Int64; cdecl;

  TRAHashFileRead = function(Handle, Buffer: Pointer; Count: NativeUInt): NativeUInt; cdecl;

  TRAHashFileClose = procedure(Handle: Pointer); cdecl;

  // Layout of rcheevos's rc_hash_filereader_t. Close may be nil.
  TRAHashFileReader = record
    Open: TRAHashFileOpen;
    Seek: TRAHashFileSeek;
    Tell: TRAHashFileTell;
    Read: TRAHashFileRead;
    Close: TRAHashFileClose;
    class function DefaultReader: TRAHashFileReader; static;
    function OpenStream(const Path: string): TStream;
  end;

implementation

uses
  System.SysUtils;

type
  TRAHashCallbackStream = class(TStream)
  private
    FReader: TRAHashFileReader;
    FHandle: Pointer;
  public
    constructor Create(const Path: string; const Reader: TRAHashFileReader);
    destructor Destroy; override;
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
  end;

constructor TRAHashCallbackStream.Create(const Path: string; const Reader: TRAHashFileReader);
var
  Encoded: UTF8String;
begin
  inherited Create;
  FReader := Reader;
  Encoded := UTF8String(Path) + #0;
  FHandle := FReader.Open(PAnsiChar(Encoded));
end;

destructor TRAHashCallbackStream.Destroy;
begin
  if (FHandle <> nil) and Assigned(FReader.Close) then
    FReader.Close(FHandle);
  inherited;
end;

function TRAHashCallbackStream.Read(var Buffer; Count: Longint): Longint;
var
  Received: NativeUInt;
begin
  if Count <= 0 then
    Exit(0);
  Received := FReader.Read(FHandle, @Buffer, NativeUInt(Count));
  if Received > NativeUInt(Count) then
    raise EReadError.Create('Invalid RetroAchievements file read length');
  Result := Longint(Received);
end;

function TRAHashCallbackStream.Write(const Buffer; Count: Longint): Longint;
begin
  raise EWriteError.Create('RetroAchievements file stream is read-only');
end;

function TRAHashCallbackStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  FReader.Seek(FHandle, Offset, Ord(Origin));
  Result := FReader.Tell(FHandle);
  if Result < 0 then
    raise EStreamError.Create('Invalid RetroAchievements file position');
end;

function TRAHashFileReader.OpenStream(const Path: string): TStream;
var
  Stream: TRAHashCallbackStream;
begin
  if not (Assigned(Open) and Assigned(Seek) and Assigned(Tell) and Assigned(Read)) then
    Exit(nil);
  Stream := TRAHashCallbackStream.Create(Path, Self);
  if Stream.FHandle <> nil then
    Exit(Stream);
  Stream.Free;
  Result := nil;
end;

function DefaultOpen(Path: PAnsiChar): Pointer; cdecl;
begin
  try
    Result := TFileStream.Create(UTF8ToString(Path), fmOpenRead or fmShareDenyWrite);
  except
    on EFOpenError do
      Result := nil;
  end;
end;

procedure DefaultSeek(Handle: Pointer; Offset: Int64; Origin: Integer); cdecl;
begin
  TFileStream(Handle).Seek(Offset, TSeekOrigin(Origin));
end;

function DefaultTell(Handle: Pointer): Int64; cdecl;
begin
  Result := TFileStream(Handle).Position;
end;

function DefaultRead(Handle, Buffer: Pointer; Count: NativeUInt): NativeUInt; cdecl;
begin
  if Count > NativeUInt(High(Integer)) then
    Count := High(Integer);
  Result := TFileStream(Handle).Read(Buffer^, Integer(Count));
end;

procedure DefaultClose(Handle: Pointer); cdecl;
begin
  TFileStream(Handle).Free;
end;

class function TRAHashFileReader.DefaultReader: TRAHashFileReader;
begin
  Result.Open := DefaultOpen;
  Result.Seek := DefaultSeek;
  Result.Tell := DefaultTell;
  Result.Read := DefaultRead;
  Result.Close := DefaultClose;
end;

end.

