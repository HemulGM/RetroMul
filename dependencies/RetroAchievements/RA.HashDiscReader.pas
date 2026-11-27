unit RA.HashDiscReader;

interface

uses
  RA.DiscHash, RA.HashFileReader;

type
  PRAHashDiscIteratorContext = ^TRAHashDiscIteratorContext;

  TRAHashDiscOpen = function(Path: PAnsiChar; Number: Cardinal): Pointer; cdecl;

  TRAHashDiscOpenIterator = function(Path: PAnsiChar; Number: Cardinal; Iterator: PRAHashDiscIteratorContext): Pointer; cdecl;

  TRAHashDiscReadSector = function(Handle: Pointer; Sector: Cardinal; Buffer: PByte; Count: NativeUInt): NativeUInt; cdecl;

  TRAHashDiscClose = procedure(Handle: Pointer); cdecl;

  TRAHashDiscFirstSector = function(Handle: Pointer): Cardinal; cdecl;

  TRAHashDiscReader = record
    OpenTrack: TRAHashDiscOpen;
    ReadSector: TRAHashDiscReadSector;
    CloseTrack: TRAHashDiscClose;
    FirstTrackSector: TRAHashDiscFirstSector;
    OpenTrackIterator: TRAHashDiscOpenIterator;
    class function DefaultReader: TRAHashDiscReader; static;
    function TryOpenTrack(const Path: string; Number: Cardinal; out Track: TRADiscTrack; Context: PRAHashDiscIteratorContext = nil): Boolean;
  end;

  TRAHashIteratorMessage = procedure(MessageText: PAnsiChar; Iterator: PRAHashDiscIteratorContext); cdecl;

  TRAHashIteratorCIAKey = function(CommonKeyIndex: Byte; NormalKey: PByte): Integer; cdecl;

  TRAHashIteratorNCCHKeys = function(PrimaryKeyY: PByte; SecondaryKeySlot: Byte; ProgramID, PrimaryNormalKey, SecondaryNormalKey: PByte): Integer; cdecl;

  TRAHashIteratorCallbacks = record
    VerboseMessage, ErrorMessage: TRAHashIteratorMessage;
    FileReader: TRAHashFileReader;
    DiscReader: TRAHashDiscReader;
    CIAKey: TRAHashIteratorCIAKey;
    NCCHKeys: TRAHashIteratorNCCHKeys;
  end;

  // Layout of rc_hash_iterator_t with disc and encrypted-media support enabled.
  // Backing storage for any supplied pointers must remain valid throughout hashing.
  TRAHashDiscIteratorContext = record
    Buffer: PByte;
    BufferSize: NativeUInt;
    Consoles: array[0..11] of Byte;
    Index: Integer;
    Path: PAnsiChar;
    UserData: Pointer;
    Callbacks: TRAHashIteratorCallbacks;
  end;

implementation

uses
  System.Classes, System.Math, System.SysUtils, RA.ArchiveHash, RA.CDReader;

type
  TRADefaultDiscHandle = class
  public
    Track: TRADiscTrack;
    Stream: TStream;
    destructor Destroy; override;
  end;

destructor TRADefaultDiscHandle.Destroy;
begin
  Track := Default(TRADiscTrack);
  Stream.Free;
  inherited;
end;

function DefaultOpenTrack(Path: PAnsiChar; Number: Cardinal; Context: PRAHashDiscIteratorContext): Pointer; cdecl;
var
  FileName, Extension: string;
  FileReader: TRAHashFileReader;
  OpenFile: TRAOpenArchive;
  OpenTrack: TRAOpenDiscTrack;
  Handle: TRADefaultDiscHandle;
  Opened: Boolean;
begin
  Result := nil;
  if (Path = nil) or (Path^ = #0) then
    Exit;
  FileName := UTF8ToString(Path);
  Extension := ExtractFileExt(FileName);
  if (Context <> nil) and Assigned(Context.Callbacks.FileReader.Open) then
  begin
    FileReader := Context.Callbacks.FileReader;
    OpenFile :=
      function(const Name: string): TStream
      begin
        Result := FileReader.OpenStream(Name);
      end;
  end;
  Handle := TRADefaultDiscHandle.Create;
  try
    try
      if SameText(Extension, '.cue') or SameText(Extension, '.gdi') then
      begin
        OpenTrack := CreateRADescriptorDiscReader(FileName, OpenFile);
        Opened := OpenTrack(Number, Handle.Track);
      end
      else
      begin
        if Number <> 1 then
        begin
          if (Context <> nil) and Assigned(Context.Callbacks.VerboseMessage) then
            Context.Callbacks.VerboseMessage('Cannot locate secondary tracks without a cue sheet', Context);
          Exit;
        end;
        Handle.Stream := OpenRAHashFile(FileName, OpenFile);
        Opened := TryOpenRARawDiscTrack(Handle.Stream, Number, Handle.Track);
      end;
      if Opened then
      begin
        Result := Handle;
        Handle := nil;
      end;
    except
      on Exception do
        Result := nil;
    end;
  finally
    Handle.Free;
  end;
end;

function DefaultReadSector(Handle: Pointer; Sector: Cardinal; Buffer: PByte; Count: NativeUInt): NativeUInt; cdecl;
begin
  Result := 0;
  if (Handle = nil) or (Buffer = nil) or (Count = 0) then
    Exit;
  try
    Result := TRADefaultDiscHandle(Handle).Track.Read(Sector, Buffer,
        Cardinal(Min(UInt64(Count), UInt64(High(Cardinal)))));
  except
    on Exception do
      Result := 0;
  end;
end;

procedure DefaultCloseTrack(Handle: Pointer); cdecl;
begin
  TRADefaultDiscHandle(Handle).Free;
end;

function DefaultFirstTrackSector(Handle: Pointer): Cardinal; cdecl;
begin
  if Handle = nil then
    Exit(0);
  Result := TRADefaultDiscHandle(Handle).Track.FirstSector;
end;

class function TRAHashDiscReader.DefaultReader: TRAHashDiscReader;
begin
  Result.OpenTrack := nil;
  Result.ReadSector := DefaultReadSector;
  Result.CloseTrack := DefaultCloseTrack;
  Result.FirstTrackSector := DefaultFirstTrackSector;
  Result.OpenTrackIterator := DefaultOpenTrack;
end;

type
  IRAHashCallbackTrack = interface
    ['{7F91CF4D-17C2-462A-A3A0-387D79CF26A4}']
    function Read(Sector: Cardinal; Buffer: PByte; Count: Cardinal): Cardinal;
  end;

  TRAHashCallbackTrack = class(TInterfacedObject, IRAHashCallbackTrack)
  private
    FReader: TRAHashDiscReader;
    FHandle: Pointer;
    FPath: UTF8String;
    FIterator: TRAHashDiscIteratorContext;
  public
    constructor Create(const Path: string; Number: Cardinal; const Reader: TRAHashDiscReader; Context: PRAHashDiscIteratorContext);
    destructor Destroy; override;
    function FirstSector: Cardinal;
    function Read(Sector: Cardinal; Buffer: PByte; Count: Cardinal): Cardinal;
  end;

constructor TRAHashCallbackTrack.Create(const Path: string; Number: Cardinal; const Reader: TRAHashDiscReader; Context: PRAHashDiscIteratorContext);
begin
  inherited Create;
  FReader := Reader;
  FPath := UTF8String(Path) + #0;
  if Assigned(FReader.OpenTrackIterator) then
  begin
    if Context <> nil then
      FIterator := Context^
    else
      FIterator.Index := -1;
    // A reader may retain pointers to the iterator's callbacks until it closes the track.
    FIterator.Path := PAnsiChar(FPath);
    FIterator.Callbacks.DiscReader := Reader;
    FHandle := FReader.OpenTrackIterator(FIterator.Path, Number, @FIterator);
  end
  else
    FHandle := FReader.OpenTrack(PAnsiChar(FPath), Number);
end;

destructor TRAHashCallbackTrack.Destroy;
begin
  if (FHandle <> nil) and Assigned(FReader.CloseTrack) then
    FReader.CloseTrack(FHandle);
  inherited;
end;

function TRAHashCallbackTrack.FirstSector: Cardinal;
begin
  if Assigned(FReader.FirstTrackSector) then
    Exit(FReader.FirstTrackSector(FHandle));
  Result := 0;
end;

function TRAHashCallbackTrack.Read(Sector: Cardinal; Buffer: PByte; Count: Cardinal): Cardinal;
var
  Received: NativeUInt;
begin
  if (Buffer = nil) or (Count = 0) then
    Exit(0);
  Received := FReader.ReadSector(FHandle, Sector, Buffer, Count);
  if Received > Count then
    raise EReadError.Create('Invalid RetroAchievements sector read length');
  Result := Cardinal(Received);
end;

function TRAHashDiscReader.TryOpenTrack(const Path: string; Number: Cardinal; out Track: TRADiscTrack; Context: PRAHashDiscIteratorContext): Boolean;
var
  Source: TRAHashCallbackTrack;
  Owner: IRAHashCallbackTrack;
begin
  Track := Default(TRADiscTrack);
  if not Assigned(ReadSector) or not (Assigned(OpenTrackIterator) or Assigned(OpenTrack)) then
    Exit(False);
  Source := TRAHashCallbackTrack.Create(Path, Number, Self, Context);
  Owner := Source;
  if Source.FHandle = nil then
    Exit(False);
  Track.FirstSector := Source.FirstSector;
  Track.Read :=
    function(Sector: Cardinal; Buffer: PByte; Count: Cardinal): Cardinal
    begin
      Result := Owner.Read(Sector, Buffer, Count);
    end;
  Result := True;
end;

end.

