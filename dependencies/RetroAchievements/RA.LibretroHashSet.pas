unit RA.LibretroHashSet;

interface

uses
  System.Classes, System.Generics.Collections, System.SysUtils,
  RA.HashFileReader;

const
  RALibretroSaveDiskHash = '[SAVE DISK]';
  RALibretroSaveDiskGameID = -1;

type
  TRALibretroGetImagePath = reference to function(Index: Cardinal; out Path: string): Boolean;

  TRALibretroReadImagePath = function(Index: Cardinal; Buffer: PAnsiChar; BufferSize: NativeUInt): Integer; cdecl;

  // Return a stream owned by the hash set, or nil if the file could not be opened.
  TRALibretroOpenPlaylist = reference to function(const Path: string): TStream;

  TRALibretroHashSet = class
  private
    type
      THash = array[0..32] of Byte;

      TEntry = record
        PathKey: Cardinal;
        GameID: Integer;
        Digest: THash;
      end;
  private
    FEntries: TList<TEntry>;
    function GetCount: Integer;
    function FindPath(Key: Cardinal): Integer;
    class function EncodeHash(const Digest: string): THash; static;
    procedure AddEntry(Key: Cardinal; GameID: Integer; const Digest: string);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Clear;
    procedure Initialize(const Path: string; const GetImagePath: TRALibretroGetImagePath; const OpenPlaylist: TRALibretroOpenPlaylist = nil; const OnError: TProc<string> = nil);
    procedure InitializeWithCallbacks(const Path: string; GetImagePath: TRALibretroReadImagePath; const FileReader: TRAHashFileReader; const OnError: TProc<string> = nil);
    procedure Add(const Path: string; GameID: Integer; const Digest: string); overload;
    procedure Add(GameID: Integer; const Digest: string); overload;
    function TryGetHash(const Path: string; out Digest: string): Boolean;
    function GetGameID(const Digest: string): Integer;
    property Count: Integer read GetCount;
  end;

implementation

uses
  RA.Playlist, RA.Utils;

const
  SaveDiskPrefix = '#SAVEDISK:';

function OpenPlaylistStream(const Path: string; const OpenPlaylist: TRALibretroOpenPlaylist): TStream;
begin
  try
    if Assigned(OpenPlaylist) then
      Result := OpenPlaylist(Path)
    else
      Result := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  except
    on EFOpenError do
      Result := nil;
  end;
end;

constructor TRALibretroHashSet.Create;
begin
  inherited;
  FEntries := TList<TEntry>.Create;
end;

destructor TRALibretroHashSet.Destroy;
begin
  FEntries.Free;
  inherited;
end;

procedure TRALibretroHashSet.Clear;
begin
  FEntries.Clear;
end;

function TRALibretroHashSet.GetCount: Integer;
begin
  Result := FEntries.Count;
end;

procedure TRALibretroHashSet.Initialize(const Path: string; const GetImagePath: TRALibretroGetImagePath; const OpenPlaylist: TRALibretroOpenPlaylist; const OnError: TProc<string>);
var
  Stream: TStream;
  Reader: TRAPlaylistReader;
  PlaylistPath, Line, ImagePath: string;
  First, Terminator: Integer;
  Index: Cardinal;
  TrailingSlot: Boolean;
begin
  Clear;
  PlaylistPath := Path;
  Terminator := Pos(#0, PlaylistPath);
  if Terminator <> 0 then
    SetLength(PlaylistPath, Terminator - 1);
  if not SameText(ExtractFileExt(PlaylistPath), '.m3u') then
    Exit;
  Stream := OpenPlaylistStream(PlaylistPath, OpenPlaylist);
  if Stream = nil then
  begin
    if Assigned(OnError) then
      OnError('Could not open playlist');
    Exit;
  end;

  Index := 0;
  TrailingSlot := False;
  try
    if not Assigned(GetImagePath) then
      Exit;
    Reader := TRAPlaylistReader.Create(Stream);
    try
      while True do
      begin
        try
          if not Reader.ReadLine(Line) then
            Break;
        except
          on EStreamError do
          begin
            Clear;
            if Assigned(OnError) then
              OnError('Could not read playlist');
            Exit;
          end;
        end;

        First := 1;
        while (First <= Length(Line)) and IsRAPlaylistWhitespace(Line[First]) do
          Inc(First);
        TrailingSlot := Reader.LastLineTerminated or (First > Length(Line));
        if First > Length(Line) then
          Continue;
        if Line[First] <> '#' then
          Inc(Index)
        else if (Copy(Line, First, Length(SaveDiskPrefix)) = SaveDiskPrefix) and GetImagePath(Index, ImagePath) then
        begin
          Add(ImagePath, RALibretroSaveDiskGameID, RALibretroSaveDiskHash);
          Inc(Index);
        end;
      end;
    finally
      Reader.Free;
    end;
  finally
    Stream.Free;
  end;

  // The upstream scanner counts a final newline or whitespace-only tail in its last-slot probe.
  if TrailingSlot then
    Inc(Index);
  if (Count > 0) and not GetImagePath(Index - 1, ImagePath) then
    Clear;
end;

procedure TRALibretroHashSet.InitializeWithCallbacks(const Path: string; GetImagePath: TRALibretroReadImagePath; const FileReader: TRAHashFileReader; const OnError: TProc<string>);
var
  GetPath: TRALibretroGetImagePath;
  Callbacks: TRAHashFileReader;
begin
  if Assigned(GetImagePath) then
    GetPath :=
      function(Index: Cardinal; out ImagePath: string): Boolean
      var
        Buffer: array[0..1023] of AnsiChar;
      begin
        FillChar(Buffer, SizeOf(Buffer), 0);
        Result := GetImagePath(Index, @Buffer[0], SizeOf(Buffer)) <> 0;
        if Result then
        begin
          Buffer[High(Buffer)] := #0;
          ImagePath := UTF8ToString(PAnsiChar(@Buffer[0]));
        end;
      end;
  Callbacks := FileReader;
  Initialize(Path, GetPath,
    function(const PlaylistPath: string): TStream
    begin
      Result := Callbacks.OpenStream(PlaylistPath);
    end, OnError);
end;

function TRALibretroHashSet.FindPath(Key: Cardinal): Integer;
begin
  for var I := 0 to FEntries.Count - 1 do
    if FEntries[I].PathKey = Key then
      Exit(I);
  Result := -1;
end;

procedure TRALibretroHashSet.AddEntry(Key: Cardinal; GameID: Integer; const Digest: string);
var
  Entry: TEntry;
  Index: Integer;
begin
  Entry.PathKey := Key;
  Entry.GameID := GameID;
  Entry.Digest := EncodeHash(Digest);

  // The upstream cache identifies paths by their DJB2 value. A missing path appends.
  Index := -1;
  if Key <> 0 then
    Index := FindPath(Key);
  if Index < 0 then
    FEntries.Add(Entry)
  else
    FEntries[Index] := Entry;
end;

class function TRALibretroHashSet.EncodeHash(const Digest: string): THash;
var
  Encoded: UTF8String;
  Count: Integer;
begin
  Result := Default(THash);
  Encoded := UTF8String(Digest);
  Count := Length(Encoded);
  if Count > SizeOf(Result) then
    Count := SizeOf(Result);
  if Count > 0 then
    Move(PAnsiChar(Encoded)^, Result[0], Count);
end;

procedure TRALibretroHashSet.Add(const Path: string; GameID: Integer; const Digest: string);
begin
  AddEntry(RADJB2(UTF8String(Path)), GameID, Digest);
end;

procedure TRALibretroHashSet.Add(GameID: Integer; const Digest: string);
begin
  AddEntry(0, GameID, Digest);
end;

function TRALibretroHashSet.TryGetHash(const Path: string; out Digest: string): Boolean;
var
  Index: Integer;
  Bytes: TBytes;
  Stored: THash;
  Count: Integer;
begin
  Index := FindPath(RADJB2(UTF8String(Path)));
  Result := Index >= 0;
  if Result then
  begin
    Stored := FEntries[Index].Digest;
    Count := 0;
    while (Count < Length(Stored)) and (Stored[Count] <> 0) do
      Inc(Count);
    SetLength(Bytes, Count);
    if Count > 0 then
      Move(Stored[0], Bytes[0], Count);
    Digest := TEncoding.UTF8.GetString(Bytes);
  end
  else
    Digest := '';
end;

function TRALibretroHashSet.GetGameID(const Digest: string): Integer;
var
  Encoded: THash;
begin
  Encoded := EncodeHash(Digest);
  for var Entry in FEntries do
    if CompareMem(@Entry.Digest[0], @Encoded[0], SizeOf(Encoded)) then
      Exit(Entry.GameID);
  Result := 0;
end;

end.

