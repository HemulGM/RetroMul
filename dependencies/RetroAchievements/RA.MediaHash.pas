unit RA.MediaHash;

interface

{$SCOPEDENUMS ON}

uses
  System.SysUtils, RA.ArchiveHash, RA.DiscHash, RA.Hash3DS, RA.HashDiscReader,
  RA.HashFileReader;

type
  // The callback supplies a track for Path and the selector used by RA.DiscHash.
  TRAOpenMediaTrack = reference to function(const Path: string; TrackNumber: Cardinal; out Track: TRADiscTrack): Boolean;

  TRAMediaHashMessage = reference to procedure(const Path: string; ConsoleID: Cardinal; const Message: string);

  TRAHashLegacyMessage = procedure(MessageText: PAnsiChar); cdecl;

  TRAMediaHashOptions = record
  private
    FHasCallbackTable: Boolean;
    FCallbackTable: TRAHashIteratorCallbacks;
    FCallbackUserData: Pointer;
    FDefaultsResolved: Boolean;
  public
    OpenFile: TRAOpenArchive;
    OpenDiscTrack: TRAOpenMediaTrack;
    Keys: TRA3DSKeyProviders;
    OnVerbose, OnError: TRAMediaHashMessage;
    class operator Initialize(out Dest: TRAMediaHashOptions);
    function HasCallbacks: Boolean;
    function SameReaders(const Options: TRAMediaHashOptions): Boolean;
    function WithDefaults: TRAMediaHashOptions;
    // Per-operation tables override populated callbacks and explicit user data.
    procedure ApplyOverrides(const Options: TRAMediaHashOptions);
    procedure SetFileReader(const Reader: TRAHashFileReader);
    procedure SetDiscReader(const Reader: TRAHashDiscReader; Context: PRAHashDiscIteratorContext = nil);
    // Explicit Pascal readers take precedence over the corresponding C callbacks.
    procedure SetCallbackTable(const Callbacks: TRAHashIteratorCallbacks; UserData: Pointer = nil);
  end;

  TRAMediaHashCandidate = record
    ConsoleID: Cardinal;
    Hash: string;
  end;

  IRAMediaHashIterator = interface
    ['{ECA3BAD0-6C04-4C65-8EF2-42B94E25AF42}']
    function TryNext(var Cursor: Integer; out Candidate: TRAMediaHashCandidate): Boolean;
  end;

// Reader defaults are captured by new iterators. Legacy message callbacks are read when dispatched.
// Empty readers or nil callbacks restore defaults.
procedure SetRADefaultHashFileReader(const Reader: TRAHashFileReader);

procedure SetRADefaultHashDiscReader(const Reader: TRAHashDiscReader);

procedure SetRADefaultHash3DSCIAKey(Callback: TRAHashIteratorCIAKey);

procedure SetRADefaultHash3DSNCCHKeys(Callback: TRAHashIteratorNCCHKeys);

procedure SetRADefaultHashMessages(Verbose, Error: TRAHashLegacyMessage);

procedure SetRADefaultHashVerboseMessage(Callback: TRAHashLegacyMessage);

procedure SetRADefaultHashErrorMessage(Callback: TRAHashLegacyMessage);

function CreateRAMediaHashIterator(ConsoleID: Cardinal; const Path: string; const Data: TBytes; const Options: TRAMediaHashOptions): IRAMediaHashIterator;

function CreateRAMediaHashIteratorWithCallbacks(ConsoleID: Cardinal; const Path: string; const Data: TBytes; const Callbacks: TRAHashIteratorCallbacks; UserData: Pointer = nil): IRAMediaHashIterator;

function TryNextUniqueRAMediaHash(const Iterator: IRAMediaHashIterator; var Cursor: Integer; const TriedHashes: array of string; out Candidate: TRAMediaHashCandidate): Boolean;

function TryHashRAMedia(ConsoleID: Cardinal; const Path: string; const Data: TBytes; const Options: TRAMediaHashOptions; out Digest: string): Boolean;

// Explicit console and source, including zero-length buffers.
function TryHashRAMediaBuffer(ConsoleID: Cardinal; const Data: TBytes; const Options: TRAMediaHashOptions; out Digest: string): Boolean;

function TryHashRAMediaFile(ConsoleID: Cardinal; const Path: string; const Options: TRAMediaHashOptions; out Digest: string): Boolean;

implementation

uses
  System.Classes, System.Generics.Defaults, System.Hash, System.Math,
  System.StrUtils, System.SyncObjs, RA.CDReader, RA.Console, RA.Hash,
  RA.Playlist;

type
  TRAConsoleExtension = record
    Extension: string;
    ConsoleID: Cardinal;
  end;

const
  ConsoleExtensions: array[0..75] of TRAConsoleExtension = (
    (Extension: '.2d'; ConsoleID: RAConsoleSharpX1),
    (Extension: '.3ds'; ConsoleID: RAConsoleNintendo3DS),
    (Extension: '.3dsx'; ConsoleID: RAConsoleNintendo3DS),
    (Extension: '.7z'; ConsoleID: RAConsoleArcade),
    (Extension: '.83g'; ConsoleID: RAConsoleTI83),
    (Extension: '.83p'; ConsoleID: RAConsoleTI83),
    (Extension: '.a26'; ConsoleID: RAConsoleAtari2600),
    (Extension: '.a78'; ConsoleID: RAConsoleAtari7800),
    (Extension: '.app'; ConsoleID: RAConsoleNintendo3DS),
    (Extension: '.arduboy'; ConsoleID: RAConsoleArduboy),
    (Extension: '.axf'; ConsoleID: RAConsoleNintendo3DS),
    (Extension: '.bs'; ConsoleID: RAConsoleSuperNintendo),
    (Extension: '.cart'; ConsoleID: RAConsoleSuperCassettevision),
    (Extension: '.cas'; ConsoleID: RAConsoleMSX),
    (Extension: '.cci'; ConsoleID: RAConsoleNintendo3DS),
    (Extension: '.chf'; ConsoleID: RAConsoleFairchildChannelF),
    (Extension: '.cia'; ConsoleID: RAConsoleNintendo3DS),
    (Extension: '.col'; ConsoleID: RAConsoleColecovision),
    (Extension: '.csw'; ConsoleID: RAConsoleZXSpectrum),
    (Extension: '.cxi'; ConsoleID: RAConsoleNintendo3DS),
    (Extension: '.d64'; ConsoleID: RAConsoleCommodore64),
    (Extension: '.dosz'; ConsoleID: RAConsoleMSDOS),
    (Extension: '.elf'; ConsoleID: RAConsoleNintendo3DS),
    (Extension: '.fd'; ConsoleID: RAConsoleThomsonTO8),
    (Extension: '.fds'; ConsoleID: RAConsoleNintendo),
    (Extension: '.fig'; ConsoleID: RAConsoleSuperNintendo),
    (Extension: '.gb'; ConsoleID: RAConsoleGameBoy),
    (Extension: '.gba'; ConsoleID: RAConsoleGameBoyAdvance),
    (Extension: '.gbc'; ConsoleID: RAConsoleGameBoyColor),
    (Extension: '.gdi'; ConsoleID: RAConsoleDreamcast),
    (Extension: '.gg'; ConsoleID: RAConsoleGameGear),
    (Extension: '.hex'; ConsoleID: RAConsoleArduboy),
    (Extension: '.jag'; ConsoleID: RAConsoleAtariJaguar),
    (Extension: '.k7'; ConsoleID: RAConsoleThomsonTO8),
    (Extension: '.lnx'; ConsoleID: RAConsoleAtariLynx),
    (Extension: '.m5'; ConsoleID: RAConsoleThomsonTO8),
    (Extension: '.m7'; ConsoleID: RAConsoleThomsonTO8),
    (Extension: '.md'; ConsoleID: RAConsoleMegaDrive),
    (Extension: '.min'; ConsoleID: RAConsolePokemonMini),
    (Extension: '.mx1'; ConsoleID: RAConsoleMSX),
    (Extension: '.mx2'; ConsoleID: RAConsoleMSX),
    (Extension: '.n64'; ConsoleID: RAConsoleNintendo64),
    (Extension: '.ndd'; ConsoleID: RAConsoleNintendo64),
    (Extension: '.nds'; ConsoleID: RAConsoleNintendoDS),
    (Extension: '.neo'; ConsoleID: RAConsoleArcade),
    (Extension: '.nes'; ConsoleID: RAConsoleNintendo),
    (Extension: '.ngc'; ConsoleID: RAConsoleNeoGeoPocket),
    (Extension: '.pbp'; ConsoleID: RAConsolePSP),
    (Extension: '.pce'; ConsoleID: RAConsolePCEngine),
    (Extension: '.pgm'; ConsoleID: RAConsoleElektorTvGamesComputer),
    (Extension: '.pzx'; ConsoleID: RAConsoleZXSpectrum),
    (Extension: '.ri'; ConsoleID: RAConsoleMSX),
    (Extension: '.rom'; ConsoleID: RAConsoleMSX),
    (Extension: '.sap'; ConsoleID: RAConsoleThomsonTO8),
    (Extension: '.scl'; ConsoleID: RAConsoleZXSpectrum),
    (Extension: '.sfc'; ConsoleID: RAConsoleSuperNintendo),
    (Extension: '.sg'; ConsoleID: RAConsoleSG1000),
    (Extension: '.sgx'; ConsoleID: RAConsolePCEngine),
    (Extension: '.smc'; ConsoleID: RAConsoleSuperNintendo),
    (Extension: '.sms'; ConsoleID: RAConsoleMasterSystem),
    (Extension: '.sv'; ConsoleID: RAConsoleSupervision),
    (Extension: '.swc'; ConsoleID: RAConsoleSuperNintendo),
    (Extension: '.tap'; ConsoleID: RAConsoleCommodore64),
    (Extension: '.tic'; ConsoleID: RAConsoleTIC80),
    (Extension: '.trd'; ConsoleID: RAConsoleZXSpectrum),
    (Extension: '.tvc'; ConsoleID: RAConsoleElektorTvGamesComputer),
    (Extension: '.tzx'; ConsoleID: RAConsoleZXSpectrum),
    (Extension: '.uze'; ConsoleID: RAConsoleUzebox),
    (Extension: '.v64'; ConsoleID: RAConsoleNintendo64),
    (Extension: '.vb'; ConsoleID: RAConsoleVirtualBoy),
    (Extension: '.wad'; ConsoleID: RAConsoleWii),
    (Extension: '.wasm'; ConsoleID: RAConsoleWASM4),
    (Extension: '.woz'; ConsoleID: RAConsoleAppleII),
    (Extension: '.wsc'; ConsoleID: RAConsoleWonderSwan),
    (Extension: '.z64'; ConsoleID: RAConsoleNintendo64),
    (Extension: '.zip'; ConsoleID: RAConsoleArcade)
  );

type
  TRAMediaHashIterator = class(TInterfacedObject, IRAMediaHashIterator)
  private
    FPath: string;
    FData: TBytes;
    FOptions: TRAMediaHashOptions;
    FConsoleID, FMessageConsoleID: Cardinal;
    FConsoles: TArray<Cardinal>;
    FInitialized, FBufferOnly: Boolean;
    FEmptyBuffer: Byte;
    FCallbackPath: UTF8String;
    FCallbackContext: TRAHashDiscIteratorContext;
    procedure Initialize;
    procedure BindCallbackTable;
    procedure BindMessageCallbacks;
    procedure RefreshCallbackContext(Index: Integer; const Path: string; const Data: TBytes);
    procedure ReportCallbackMessage(Callback: TRAHashIteratorMessage; const MessageText: string);
  public
    constructor Create(ConsoleID: Cardinal; const Path: string; const Data: TBytes; const Options: TRAMediaHashOptions; BufferOnly: Boolean = False);
    function TryNext(var Cursor: Integer; out Candidate: TRAMediaHashCandidate): Boolean;
  end;

var
  DefaultHashLock: TCriticalSection;
  DefaultHashCallbacks: TRAHashIteratorCallbacks;
  DefaultHashVerbose, DefaultHashError: TRAHashLegacyMessage;

procedure SetRADefaultHashFileReader(const Reader: TRAHashFileReader);
var
  Merged: TRAHashFileReader;
begin
  Merged := TRAHashFileReader.DefaultReader;
  if Assigned(Reader.Open) then
    Merged.Open := Reader.Open;
  if Assigned(Reader.Seek) then
    Merged.Seek := Reader.Seek;
  if Assigned(Reader.Tell) then
    Merged.Tell := Reader.Tell;
  if Assigned(Reader.Read) then
    Merged.Read := Reader.Read;
  if Assigned(Reader.Close) then
    Merged.Close := Reader.Close;
  if not (Assigned(Reader.Open) or Assigned(Reader.Seek) or Assigned(Reader.Tell) or
    Assigned(Reader.Read) or Assigned(Reader.Close)) then
    Merged := Default(TRAHashFileReader);
  DefaultHashLock.Acquire;
  try
    DefaultHashCallbacks.FileReader := Merged;
  finally
    DefaultHashLock.Release;
  end;
end;

procedure SetRADefaultHashDiscReader(const Reader: TRAHashDiscReader);
begin
  DefaultHashLock.Acquire;
  try
    DefaultHashCallbacks.DiscReader := Reader;
  finally
    DefaultHashLock.Release;
  end;
end;

procedure SetRADefaultHash3DSCIAKey(Callback: TRAHashIteratorCIAKey);
begin
  DefaultHashLock.Acquire;
  try
    DefaultHashCallbacks.CIAKey := Callback;
  finally
    DefaultHashLock.Release;
  end;
end;

procedure SetRADefaultHash3DSNCCHKeys(Callback: TRAHashIteratorNCCHKeys);
begin
  DefaultHashLock.Acquire;
  try
    DefaultHashCallbacks.NCCHKeys := Callback;
  finally
    DefaultHashLock.Release;
  end;
end;

procedure SetRADefaultHashMessages(Verbose, Error: TRAHashLegacyMessage);
begin
  DefaultHashLock.Acquire;
  try
    DefaultHashVerbose := Verbose;
    DefaultHashError := Error;
  finally
    DefaultHashLock.Release;
  end;
end;

procedure SetRADefaultHashVerboseMessage(Callback: TRAHashLegacyMessage);
begin
  DefaultHashLock.Acquire;
  try
    DefaultHashVerbose := Callback;
  finally
    DefaultHashLock.Release;
  end;
end;

procedure SetRADefaultHashErrorMessage(Callback: TRAHashLegacyMessage);
begin
  DefaultHashLock.Acquire;
  try
    DefaultHashError := Callback;
  finally
    DefaultHashLock.Release;
  end;
end;

procedure GetDefaultHashMessages(out Verbose, Error: TRAHashLegacyMessage);
begin
  DefaultHashLock.Acquire;
  try
    Verbose := DefaultHashVerbose;
    Error := DefaultHashError;
  finally
    DefaultHashLock.Release;
  end;
end;

procedure DefaultHashVerboseProxy(MessageText: PAnsiChar; Iterator: PRAHashDiscIteratorContext); cdecl;
var
  Verbose, Error: TRAHashLegacyMessage;
begin
  GetDefaultHashMessages(Verbose, Error);
  if Assigned(Verbose) then
    Verbose(MessageText);
end;

procedure DefaultHashErrorProxy(MessageText: PAnsiChar; Iterator: PRAHashDiscIteratorContext); cdecl;
var
  Verbose, Error: TRAHashLegacyMessage;
begin
  GetDefaultHashMessages(Verbose, Error);
  if Assigned(Error) then
    Error(MessageText);
end;

class operator TRAMediaHashOptions.Initialize(out Dest: TRAMediaHashOptions);
begin
  Dest.FHasCallbackTable := False;
  Dest.FCallbackTable := Default(TRAHashIteratorCallbacks);
  Dest.FCallbackUserData := nil;
  Dest.FDefaultsResolved := False;
end;

function TRAMediaHashOptions.HasCallbacks: Boolean;
begin
  Result := FHasCallbackTable or Assigned(OpenFile) or Assigned(OpenDiscTrack) or Assigned(Keys.CIA) or Assigned(Keys.NCCH) or
    Assigned(OnVerbose) or Assigned(OnError);
end;

function TRAMediaHashOptions.WithDefaults: TRAMediaHashOptions;
var
  Callbacks: TRAHashIteratorCallbacks;
begin
  if FDefaultsResolved then
    Exit(Self);
  Result := Default(TRAMediaHashOptions);
  DefaultHashLock.Acquire;
  try
    Callbacks := DefaultHashCallbacks;
    if Assigned(DefaultHashVerbose) then
      Callbacks.VerboseMessage := DefaultHashVerboseProxy;
    if Assigned(DefaultHashError) then
      Callbacks.ErrorMessage := DefaultHashErrorProxy;
  finally
    DefaultHashLock.Release;
  end;
  if Assigned(Callbacks.FileReader.Open) or Assigned(Callbacks.DiscReader.OpenTrack) or
    Assigned(Callbacks.DiscReader.OpenTrackIterator) or Assigned(Callbacks.CIAKey) or
    Assigned(Callbacks.NCCHKeys) or Assigned(Callbacks.VerboseMessage) or Assigned(Callbacks.ErrorMessage) then
    Result.SetCallbackTable(Callbacks, FCallbackUserData);
  Result.ApplyOverrides(Self);
  Result.FDefaultsResolved := True;
end;

function TRAMediaHashOptions.SameReaders(const Options: TRAMediaHashOptions): Boolean;
begin
  Result := (FHasCallbackTable = Options.FHasCallbackTable) and
    (not FHasCallbackTable or ((FCallbackUserData = Options.FCallbackUserData) and
    CompareMem(@FCallbackTable, @Options.FCallbackTable, SizeOf(FCallbackTable)))) and
    TEqualityComparer<TRAOpenArchive>.Default.Equals(OpenFile, Options.OpenFile) and
    TEqualityComparer<TRAOpenMediaTrack>.Default.Equals(OpenDiscTrack, Options.OpenDiscTrack) and
    TEqualityComparer<TRACIAKeyProvider>.Default.Equals(Keys.CIA, Options.Keys.CIA) and
    TEqualityComparer<TRANCCHKeyProvider>.Default.Equals(Keys.NCCH, Options.Keys.NCCH);
end;

procedure TRAMediaHashOptions.ApplyOverrides(const Options: TRAMediaHashOptions);
begin
  if Options.FHasCallbackTable then
  begin
    FHasCallbackTable := True;
    if Assigned(Options.FCallbackTable.VerboseMessage) then
      FCallbackTable.VerboseMessage := Options.FCallbackTable.VerboseMessage;
    if Assigned(Options.FCallbackTable.ErrorMessage) then
      FCallbackTable.ErrorMessage := Options.FCallbackTable.ErrorMessage;
    if Assigned(Options.FCallbackTable.FileReader.Open) then
      FCallbackTable.FileReader := Options.FCallbackTable.FileReader;
    if Assigned(Options.FCallbackTable.DiscReader.OpenTrack) or
      Assigned(Options.FCallbackTable.DiscReader.OpenTrackIterator) then
      FCallbackTable.DiscReader := Options.FCallbackTable.DiscReader;
    if Assigned(Options.FCallbackTable.CIAKey) then
      FCallbackTable.CIAKey := Options.FCallbackTable.CIAKey;
    if Assigned(Options.FCallbackTable.NCCHKeys) then
      FCallbackTable.NCCHKeys := Options.FCallbackTable.NCCHKeys;
    if Options.FCallbackUserData <> nil then
      FCallbackUserData := Options.FCallbackUserData;
  end;
  if Assigned(Options.OpenFile) then
    OpenFile := Options.OpenFile;
  if Assigned(Options.OpenDiscTrack) then
    OpenDiscTrack := Options.OpenDiscTrack;
  if Assigned(Options.Keys.CIA) then
    Keys.CIA := Options.Keys.CIA;
  if Assigned(Options.Keys.NCCH) then
    Keys.NCCH := Options.Keys.NCCH;
  if Assigned(Options.OnVerbose) then
    OnVerbose := Options.OnVerbose;
  if Assigned(Options.OnError) then
    OnError := Options.OnError;
end;

procedure TRAMediaHashOptions.SetCallbackTable(const Callbacks: TRAHashIteratorCallbacks; UserData: Pointer);
begin
  FHasCallbackTable := True;
  FCallbackTable := Callbacks;
  FCallbackUserData := UserData;
end;

procedure TRAMediaHashOptions.SetFileReader(const Reader: TRAHashFileReader);
var
  Callbacks: TRAHashFileReader;
begin
  Callbacks := Reader;
  OpenFile :=
    function(const Path: string): TStream
    begin
      Result := Callbacks.OpenStream(Path);
    end;
end;

procedure TRAMediaHashOptions.SetDiscReader(const Reader: TRAHashDiscReader; Context: PRAHashDiscIteratorContext);
var
  Callbacks: TRAHashDiscReader;
  SavedContext: TRAHashDiscIteratorContext;
begin
  Callbacks := Reader;
  if Context <> nil then
    SavedContext := Context^
  else
  begin
    SavedContext := Default(TRAHashDiscIteratorContext);
    SavedContext.Index := -1;
  end;
  OpenDiscTrack :=
    function(const Path: string; TrackNumber: Cardinal; out Track: TRADiscTrack): Boolean
    begin
      Result := Callbacks.TryOpenTrack(Path, TrackNumber, Track, @SavedContext);
    end;
end;

procedure ReportHashMessage(const Handler: TRAMediaHashMessage; const Path: string; ConsoleID: Cardinal; const Message: string);
begin
  if not Assigned(Handler) then
    Exit;
  try
    Handler(Path, ConsoleID, Message);
  except
    on Exception do
      Exit;
  end;
end;

function IsMediaIOError(const Error: Exception): Boolean;
begin
  Result := (Error is EStreamError) or (Error is EInOutError) or (Error is EOSError);
end;

function FilenameStart(const Path: string): Integer;
begin
  Result := LastDelimiter('/\', Path) + 1;
end;

function PathExtension(const Path: string): string;
var
  Dot: Integer;
begin
  // The upstream iterator searches the entire path for the last dot.
  Dot := LastDelimiter('.', Path);
  if Dot = 0 then
    Exit('');
  Result := Copy(Path, Dot, MaxInt);
end;

function ExtensionOf(const Path: string): string;
begin
  Result := LowerCase(PathExtension(Path));
end;

function FirstPlaylistItem(const Path: string; ConsoleID: Cardinal; const Options: TRAMediaHashOptions): string;
var
  Stream: TStream;
  Reader: TRAPlaylistReader;
  Entry: string;
  Last: Integer;
begin
  Result := '';
  ReportHashMessage(Options.OnVerbose, Path, ConsoleID, 'Processing playlist: ' + Copy(Path, FilenameStart(Path), MaxInt));
  Stream := OpenRAHashFile(Path, Options.OpenFile);
  if Stream = nil then
    Exit;
  try
    Reader := TRAPlaylistReader.Create(Stream);
    try
      while Reader.ReadLine(Entry) do
      begin
        if (Entry = '') or CharInSet(Entry[1], ['#', #13]) then
          Continue;
        Last := Length(Entry);
        while (Last > 0) and IsRAPlaylistWhitespace(Entry[Last]) do
          Dec(Last);
        if Last = 0 then
          Continue;
        SetLength(Entry, Last);
        ReportHashMessage(Options.OnVerbose, Path, ConsoleID, 'Extracted ' + Entry + ' from playlist');
        if Entry.StartsWith('/') or Entry.StartsWith('\') or (Copy(Entry, 2, 2) = ':\') or Entry.Contains(':/') then
          Exit(Entry);
        Exit(Copy(Path, 1, FilenameStart(Path) - 1) + Entry);
      end;
    finally
      Reader.Free;
    end;
  finally
    Stream.Free;
  end;
end;

function UsesPlaylist(ConsoleID: Cardinal; HasBuffer: Boolean): Boolean;
begin
  case ConsoleID of
    RAConsoleUnknown, RAConsole3DO, RAConsoleDreamcast, RAConsolePCEngineCD, RAConsolePCFX, RAConsolePlayStation, RAConsolePlayStation2, RAConsolePlayStation3, RAConsoleSegaCD, RAConsoleSaturn:
      Result := True;
    RAConsoleMegaDrive, RAConsoleAmstradPC, RAConsoleAppleII, RAConsoleCommodore64, RAConsoleMSX, RAConsolePC8800:
      Result := not HasBuffer;
  else
    Result := False;
  end;
end;

function DetectConsoles(const Path, Extension: string; const Data: TBytes; const Options: TRAMediaHashOptions): TArray<Cardinal>;
var
  Ext: string;
  Size: Int64;
  Stream: TStream;
begin
  // The C lookup key holds seven ASCII characters after the dot.
  Ext := LowerCase(Copy(Extension, 1, 8));
  if MatchText(Ext, ['.bin', '.dsk']) then
  begin
    Size := Length(Data);
    if Data = nil then
    begin
      try
        Stream := OpenRAHashFile(Path, Options.OpenFile);
        if Stream <> nil then
        try
          Size := Stream.Size - Stream.Position;
        finally
          Stream.Free;
        end;
      except
        on Error: Exception do
        begin
          if not IsMediaIOError(Error) then
            raise;
          // The extension still supplies candidates when the advisory file-size probe fails.
          ReportHashMessage(Options.OnError, Path, RAConsoleUnknown, Error.Message);
        end;
      end;
    end;
    if Ext = '.bin' then
    begin
      if (Data = nil) and (Size > 32 * 1024 * 1024) then
        Exit(TArray<Cardinal>.Create(RAConsole3DO, RAConsolePlayStation, RAConsolePlayStation2, RAConsoleSegaCD, RAConsoleMegaDrive));
      Exit(TArray<Cardinal>.Create(RAConsoleMegaDrive));
    end;
    if (Size = 256 * 16 * 35) or (Size = 256 * 13 * 35) then
      Exit(TArray<Cardinal>.Create(RAConsoleAppleII, RAConsoleMSX, RAConsoleAmstradPC, RAConsoleZXSpectrum));
    Exit(TArray<Cardinal>.Create(RAConsoleMSX, RAConsoleAmstradPC, RAConsoleZXSpectrum, RAConsoleAppleII));
  end;

  if Ext = '.d88' then
    Exit(TArray<Cardinal>.Create(RAConsolePC8800, RAConsoleSharpX1));
  if Ext = '.nib' then
    Exit(TArray<Cardinal>.Create(RAConsoleAppleII, RAConsoleCommodore64));
  if Ext = '.chd' then
    Exit(TArray<Cardinal>.Create(RAConsolePlayStation, RAConsolePlayStation2, RAConsoleDreamcast, RAConsoleSegaCD, RAConsolePSP,
        RAConsolePlayStation3, RAConsolePCEngineCD, RAConsole3DO, RAConsoleNeoGeoCD, RAConsolePCFX));
  if Ext = '.cue' then
    Exit(TArray<Cardinal>.Create(RAConsolePlayStation, RAConsolePlayStation2, RAConsoleDreamcast, RAConsoleSegaCD, RAConsolePCEngineCD,
        RAConsole3DO, RAConsolePCFX, RAConsoleNeoGeoCD, RAConsoleAtariJaguarCD));
  if Ext = '.iso' then
    Exit(TArray<Cardinal>.Create(RAConsolePlayStation2, RAConsolePSP, RAConsolePlayStation3, RAConsole3DO, RAConsoleSegaCD,
        RAConsoleGameCube, RAConsoleWii));

  for var Entry in ConsoleExtensions do
    if Ext = Entry.Extension then
      Exit(TArray<Cardinal>.Create(Entry.ConsoleID));
  Result := nil;
end;

function ArcadeHash(const Path: string; out Digest: string): Boolean;
var
  Start: Integer;
  FileName, Ext, Parent, Identifier: string;
begin
  Start := FilenameStart(Path);
  FileName := Copy(Path, Start, MaxInt);
  if FileName = '' then
    Exit(False);
  Ext := ExtractFileExt(FileName);
  Identifier := FileName;
  if Length(Ext) > 1 then
  begin
    SetLength(Identifier, Length(FileName) - Length(Ext));
    Parent := Copy(Path, 1, Start - 2);
    Parent := LowerCase(Copy(Parent, FilenameStart(Parent), MaxInt));
    if MatchText(Parent, ['nes', 'fds', 'sms', 'msx', 'ngp', 'pce', 'chf', 'sgx', 'tg16', 'msx1',
        'neocd', 'coleco', 'sg1000', 'genesis', 'gamegear', 'megadriv', 'pcengine', 'channelf', 'spectrum',
        'megadrive', 'supergrafx', 'zxspectrum', 'mastersystem', 'colecovision']) and
      (TEncoding.UTF8.GetByteCount(Parent + '_' + Identifier) < 128) then
      Identifier := Parent + '_' + Identifier;
  end;
  Digest := LowerCase(THashMD5.GetHashString(Identifier));
  Result := True;
end;

function DiscConsole(ConsoleID: Cardinal; out Console: TRADiscConsole): Boolean;
begin
  case ConsoleID of
    RAConsolePlayStation:
      Console := TRADiscConsole.PlayStation;
    RAConsolePlayStation2:
      Console := TRADiscConsole.PlayStation2;
    RAConsolePlayStation3:
      Console := TRADiscConsole.PlayStation3;
    RAConsolePSP:
      Console := TRADiscConsole.PlayStationPortable;
    RAConsoleSegaCD:
      Console := TRADiscConsole.SegaCD;
    RAConsoleSaturn:
      Console := TRADiscConsole.Saturn;
    RAConsoleDreamcast:
      Console := TRADiscConsole.Dreamcast;
    RAConsolePCEngineCD:
      Console := TRADiscConsole.PCEngineCD;
    RAConsolePCFX:
      Console := TRADiscConsole.PCFX;
    RAConsoleNeoGeoCD:
      Console := TRADiscConsole.NeoGeoCD;
    RAConsole3DO:
      Console := TRADiscConsole.ThreeDO;
    RAConsoleAtariJaguarCD:
      Console := TRADiscConsole.JaguarCD;
  else
    Console := Default(TRADiscConsole);
    Exit(False);
  end;
  Result := True;
end;

function HashSingleDisc(Console: TRADiscConsole; Stream: TStream; out Digest: string): Boolean;
var
  OpenTrack: TRAOpenDiscTrack;
  Start: Int64;
begin
  Start := Stream.Position;
  OpenTrack :=
    function(Number: Cardinal; out Track: TRADiscTrack): Boolean
    begin
      Stream.Position := Start;
      Result := TryOpenRARawDiscTrack(Stream, Number, Track);
    end;
  Result := TryHashRADisc(Console, OpenTrack, Digest);
end;

function HashPS3Files(const Path: string; const OpenFile: TRAOpenArchive; out Digest: string): Boolean;
var
  DirectoryEnd: Integer;
  SFOPath: string;
  Hash: THashMD5;

  function AppendFile(const FileName: string): Boolean;
  var
    Stream: TStream;
    Buffer: array[0..4095] of Byte;
    Count: Integer;
  begin
    Stream := OpenRAHashFile(FileName, OpenFile);
    if Stream = nil then
      Exit(False);
    try
      repeat
        Count := Stream.Read(Buffer[0], Integer(SizeOf(Buffer)));
        if Count > 0 then
          Hash.Update(Buffer, Count);
      until Count <> SizeOf(Buffer);
      Result := True;
    finally
      Stream.Free;
    end;
  end;

begin
  Digest := '';
  DirectoryEnd := Pos('PS3_GAME/USRDIR/', Path);
  if DirectoryEnd = 0 then
    DirectoryEnd := Pos('PS3_GAME\USRDIR\', Path);
  if DirectoryEnd > 0 then
    Inc(DirectoryEnd, Length('PS3_GAME/'))
  else
  begin
    DirectoryEnd := Pos('USRDIR/', Path);
    if DirectoryEnd = 0 then
      DirectoryEnd := Pos('USRDIR\', Path);
  end;
  if DirectoryEnd = 0 then
    DirectoryEnd := FilenameStart(Path);
  SFOPath := Copy(Path, 1, DirectoryEnd - 1) + 'PARAM.SFO';
  Hash := THashMD5.Create;
  Result := AppendFile(SFOPath) and AppendFile(Path);
  if Result then
    Digest := LowerCase(Hash.HashAsString);
end;

function HashCandidate(ConsoleID: Cardinal; const Path: string; const Data: TBytes; HasBuffer: Boolean; const Options: TRAMediaHashOptions; out Digest: string): Boolean;
var
  Ext: string;
  Stream: TStream;
  Disc: TRADiscConsole;
  ArduboyArchive, DiscInput, UseBuffer: Boolean;
  OpenTrack: TRAOpenDiscTrack;
begin
  Digest := '';
  Ext := ExtensionOf(Path);
  if ConsoleID = RAConsoleArcade then
  begin
    if HasBuffer then
      Exit(TryHashRARom(TRARomConsole.NeoGeoCartridge, Data, Digest));
    if Ext <> '.neo' then
      Exit(ArcadeHash(Path, Digest));
  end;

  if (ConsoleID = RAConsolePCEngineCD) and MatchText(Ext, ['.pce', '.sgx']) then
    Exit(False);
  ArduboyArchive := (ConsoleID = RAConsoleArduboy) and (Ext = '.arduboy');
  DiscInput := DiscConsole(ConsoleID, Disc) and not ((ConsoleID = RAConsolePSP) and (Ext = '.pbp'));
  UseBuffer := HasBuffer and not ArduboyArchive;
  if UseBuffer and (DiscInput or (ConsoleID in [RAConsoleGameCube, RAConsoleWii, RAConsolePSP, RAConsoleMSDOS])) then
  begin
    // These media types can fall back to the file when the caller supplies a buffer.
    if not MatchText(Ext, ['.cue', '.iso', '.chd', '.m3u']) then
      Exit(False);
    UseBuffer := False;
  end;
  if (ConsoleID = RAConsolePlayStation3) and not MatchText(Ext, ['.iso', '.chd']) then
    Exit(HashPS3Files(Path, Options.OpenFile, Digest));

  if DiscInput and Assigned(Options.OpenDiscTrack) then
  begin
    OpenTrack :=
      function(Number: Cardinal; out Track: TRADiscTrack): Boolean
      begin
        Result := Options.OpenDiscTrack(Path, Number, Track);
      end;
    Exit(TryHashRADisc(Disc, OpenTrack, Digest));
  end;

  if DiscInput then
  begin
    if MatchText(Ext, ['.cue', '.gdi']) then
      Exit(TryHashRADisc(Disc, CreateRADescriptorDiscReader(Path, Options.OpenFile), Digest));
    if Ext = '.chd' then
      Exit(False);
  end;
  if UseBuffer then
    Stream := TBytesStream.Create(Data)
  else
    Stream := OpenRAHashFile(Path, Options.OpenFile);
  if Stream = nil then
    Exit(False);
  try
    if DiscInput then
      Result := HashSingleDisc(Disc, Stream, Digest)
    else if ConsoleID = RAConsoleMSDOS then
      Result := TryHashRADOSZ(Path, Stream, Digest, Options.OpenFile)
    else if ConsoleID = RAConsoleNintendo3DS then
      Result := TryHashRA3DS(Stream, Options.Keys, Digest)
    else if ArduboyArchive then
      Result := TryHashRAArduboyFX(Stream, Digest)
    else if ConsoleID <= Cardinal(Ord(High(TRARomConsole))) then
    begin
      if UseBuffer then
        Result := TryHashRARom(TRARomConsole(ConsoleID), Data, Digest)
      else
        Result := TryHashRARom(TRARomConsole(ConsoleID), Stream, Digest);
    end
    else
      Result := False;
  finally
    Stream.Free;
  end;
end;

constructor TRAMediaHashIterator.Create(ConsoleID: Cardinal; const Path: string; const Data: TBytes; const Options: TRAMediaHashOptions; BufferOnly: Boolean);
var
  FileOpener: TRAOpenArchive;
begin
  inherited Create;
  var Terminator := Pos(#0, Path);
  if Terminator = 0 then
    FPath := Path
  else
    FPath := Copy(Path, 1, Terminator - 1);
  FData := Data;
  FBufferOnly := BufferOnly;
  FOptions := Options.WithDefaults;
  FConsoleID := ConsoleID;
  FMessageConsoleID := ConsoleID;
  if FOptions.FHasCallbackTable then
    BindCallbackTable;
  BindMessageCallbacks;
  if not Assigned(FOptions.OnError) then
    FOptions.OnError := FOptions.OnVerbose;
  if Assigned(FOptions.OnVerbose) then
  begin
    FileOpener := FOptions.OpenFile;
    FOptions.OpenFile :=
      function(const FileName: string): TStream
      begin
        Result := OpenRAHashFile(FileName, FileOpener);
        if Result <> nil then
          ReportHashMessage(FOptions.OnVerbose, FileName, FMessageConsoleID,
            'Opened ' + Copy(FileName, FilenameStart(FileName), MaxInt));
      end;
  end;
end;

procedure TRAMediaHashIterator.BindCallbackTable;
var
  Callbacks: TRAHashIteratorCallbacks;
  HasDiscReader: Boolean;
begin
  Callbacks := FOptions.FCallbackTable;
  FCallbackContext.Callbacks := Callbacks;
  FCallbackContext.UserData := FOptions.FCallbackUserData;
  if not Assigned(Callbacks.FileReader.Open) then
    FCallbackContext.Callbacks.FileReader := TRAHashFileReader.DefaultReader;
  if not Assigned(FOptions.OpenFile) then
    FOptions.SetFileReader(FCallbackContext.Callbacks.FileReader);
  HasDiscReader := Assigned(Callbacks.DiscReader.OpenTrack) or Assigned(Callbacks.DiscReader.OpenTrackIterator);
  if not HasDiscReader then
    FCallbackContext.Callbacks.DiscReader := TRAHashDiscReader.DefaultReader;
  if not Assigned(FOptions.OpenDiscTrack) and HasDiscReader then
    FOptions.OpenDiscTrack :=
      function(const TrackPath: string; TrackNumber: Cardinal; out Track: TRADiscTrack): Boolean
      begin
        Result := FCallbackContext.Callbacks.DiscReader.TryOpenTrack(TrackPath, TrackNumber, Track, @FCallbackContext);
      end;
  if Assigned(Callbacks.CIAKey) and not Assigned(FOptions.Keys.CIA) then
    FOptions.Keys.CIA :=
      function(KeyIndex: Byte; out Key: TRA3DSKey): Boolean
      begin
        Result := FCallbackContext.Callbacks.CIAKey(KeyIndex, @Key[0]) <> 0;
      end;
  if Assigned(Callbacks.NCCHKeys) and not Assigned(FOptions.Keys.NCCH) then
    FOptions.Keys.NCCH :=
      function(const PrimaryKeyY: TRA3DSKey; SecondaryKeyXSlot: Byte; ProgramID: PRA3DSProgramID; out PrimaryKey, SecondaryKey: TRA3DSKey): Boolean
      var
        KeyY: TRA3DSKey;
      begin
        KeyY := PrimaryKeyY;
        Result := FCallbackContext.Callbacks.NCCHKeys(@KeyY[0], SecondaryKeyXSlot,
          PByte(ProgramID), @PrimaryKey[0], @SecondaryKey[0]) <> 0;
      end;
  RefreshCallbackContext(-1, FPath, FData);
end;

procedure SendLegacyHashMessage(Callback: TRAHashLegacyMessage; const MessageText: string);
var
  Encoded: UTF8String;
begin
  Encoded := UTF8String(MessageText);
  Callback(PAnsiChar(Encoded));
end;

procedure TRAMediaHashIterator.BindMessageCallbacks;
var
  Verbose, Error: TRAMediaHashMessage;
  VerboseCallback, ErrorCallback: TRAHashIteratorMessage;
begin
  VerboseCallback := FOptions.FCallbackTable.VerboseMessage;
  ErrorCallback := FOptions.FCallbackTable.ErrorMessage;
  Verbose := FOptions.OnVerbose;
  Error := FOptions.OnError;
  if not Assigned(Error) then
    Error := Verbose;
  // Keep dispatch active even if globals are currently nil: they may be set after construction.
  FOptions.OnVerbose :=
    procedure(const MessagePath: string; MessageConsole: Cardinal; const MessageText: string)
    var
      LegacyVerbose, LegacyError: TRAHashLegacyMessage;
    begin
      GetDefaultHashMessages(LegacyVerbose, LegacyError);
      if Assigned(VerboseCallback) then
        ReportCallbackMessage(VerboseCallback, MessageText)
      else if Assigned(LegacyVerbose) then
        SendLegacyHashMessage(LegacyVerbose, MessageText);
      ReportHashMessage(Verbose, MessagePath, MessageConsole, MessageText);
    end;
  FOptions.OnError :=
    procedure(const MessagePath: string; MessageConsole: Cardinal; const MessageText: string)
    var
      LegacyVerbose, LegacyError: TRAHashLegacyMessage;
    begin
      GetDefaultHashMessages(LegacyVerbose, LegacyError);
      if Assigned(ErrorCallback) then
        ReportCallbackMessage(ErrorCallback, MessageText)
      else if Assigned(LegacyError) then
        SendLegacyHashMessage(LegacyError, MessageText)
      else if Assigned(VerboseCallback) then
        ReportCallbackMessage(VerboseCallback, MessageText)
      else if Assigned(LegacyVerbose) then
        SendLegacyHashMessage(LegacyVerbose, MessageText);
      ReportHashMessage(Error, MessagePath, MessageConsole, MessageText);
    end;
end;

procedure TRAMediaHashIterator.RefreshCallbackContext(Index: Integer; const Path: string; const Data: TBytes);
begin
  if not FOptions.FHasCallbackTable then
    Exit;
  if FConsoleID <> RAConsoleUnknown then
    Index := -1;
  FCallbackPath := UTF8String(Path) + #0;
  FCallbackContext.Path := PAnsiChar(FCallbackPath);
  FCallbackContext.Buffer := PByte(Data);
  FCallbackContext.BufferSize := Length(Data);
  if FBufferOnly then
  begin
    FCallbackContext.Path := nil;
    if FCallbackContext.Buffer = nil then
      FCallbackContext.Buffer := @FEmptyBuffer;
  end;
  FCallbackContext.Index := Index;
  FillChar(FCallbackContext.Consoles, SizeOf(FCallbackContext.Consoles), 0);
  if FConsoleID = RAConsoleUnknown then
    for var CandidateIndex := 0 to Min(High(FConsoles), High(FCallbackContext.Consoles)) do
      FCallbackContext.Consoles[CandidateIndex] := Byte(FConsoles[CandidateIndex]);
end;

procedure TRAMediaHashIterator.ReportCallbackMessage(Callback: TRAHashIteratorMessage; const MessageText: string);
var
  Encoded: UTF8String;
begin
  Encoded := UTF8String(MessageText) + #0;
  Callback(PAnsiChar(Encoded), @FCallbackContext);
end;

procedure TRAMediaHashIterator.Initialize;
var
  MediaPath, NextPath, MediaExtension, ExtensionName: string;
  MediaData: TBytes;
begin
  MediaPath := FPath;
  MediaData := FData;
  if UsesPlaylist(FConsoleID, MediaData <> nil) then
  begin
    for var Depth := 1 to 16 do
    begin
      if ExtensionOf(MediaPath) <> '.m3u' then
        Break;
      RefreshCallbackContext(-1, MediaPath, MediaData);
      try
        NextPath := FirstPlaylistItem(MediaPath, FConsoleID, FOptions);
      except
        on Error: Exception do
        begin
          if not IsMediaIOError(Error) then
            raise;
          ReportHashMessage(FOptions.OnError, MediaPath, FConsoleID, Error.Message);
          Exit;
        end;
      end;
      if NextPath = '' then
      begin
        ReportHashMessage(FOptions.OnError, MediaPath, FConsoleID, 'Could not read a media path from the playlist');
        Exit;
      end;
      MediaPath := NextPath;
      MediaData := nil;
    end;
    if ExtensionOf(MediaPath) = '.m3u' then
    begin
      RefreshCallbackContext(-1, MediaPath, MediaData);
      ReportHashMessage(FOptions.OnError, MediaPath, FConsoleID, 'Nested media playlist limit exceeded');
      Exit;
    end;
  end;

  FPath := MediaPath;
  FData := MediaData;
  if FConsoleID <> RAConsoleUnknown then
  begin
    FConsoles := [FConsoleID];
    RefreshCallbackContext(-1, FPath, FData);
  end
  else
  begin
    MediaExtension := PathExtension(MediaPath);
    ExtensionName := Copy(MediaExtension, 2);
    RefreshCallbackContext(-1, MediaPath, MediaData);
    FConsoles := DetectConsoles(MediaPath, MediaExtension, MediaData, FOptions);
    if Length(FConsoles) = 0 then
    begin
      RefreshCallbackContext(-1, FPath, FData);
      ReportHashMessage(FOptions.OnError, MediaPath, FConsoleID,
        Format('No console mapping specified for %s file extension - trying full file hash', [ExtensionName]));
      FConsoles := [RAConsoleGameBoy];
    end
    else
    begin
      RefreshCallbackContext(-1, FPath, FData);
      ReportHashMessage(FOptions.OnVerbose, MediaPath, FConsoleID,
        Format('Found %d potential consoles for %s file extension', [Length(FConsoles), ExtensionName]));
    end;
  end;
end;

function TRAMediaHashIterator.TryNext(var Cursor: Integer; out Candidate: TRAMediaHashCandidate): Boolean;
begin
  Candidate := Default(TRAMediaHashCandidate);
  if Cursor < 0 then
    Exit(False);

  if not FInitialized then
  begin
    FInitialized := True;
    try
      Initialize;
    except
      FInitialized := False;
      raise;
    end;
  end;

  while Cursor < Length(FConsoles) do
  begin
    Candidate.ConsoleID := FConsoles[Cursor];
    FMessageConsoleID := Candidate.ConsoleID;
    Inc(Cursor);
    RefreshCallbackContext(Cursor, FPath, FData);
    ReportHashMessage(FOptions.OnVerbose, FPath, Candidate.ConsoleID, 'Generating media hash');
    try
      if HashCandidate(Candidate.ConsoleID, FPath, FData, FBufferOnly or (FData <> nil), FOptions, Candidate.Hash) then
      begin
        if Assigned(FOptions.OnVerbose) then
          ReportHashMessage(FOptions.OnVerbose, FPath, Candidate.ConsoleID, 'Media hash: ' + Candidate.Hash);
        Exit(True);
      end;
    except
      on Error: Exception do
      begin
        ReportHashMessage(FOptions.OnError, FPath, Candidate.ConsoleID, Error.Message);
        if IsMediaIOError(Error) then
          Continue;
        raise;
      end;
    end;
    ReportHashMessage(FOptions.OnError, FPath, Candidate.ConsoleID, 'Could not generate a hash for this media and console');
  end;
  Candidate := Default(TRAMediaHashCandidate);
  Result := False;
end;

function CreateRAMediaHashIterator(ConsoleID: Cardinal; const Path: string; const Data: TBytes; const Options: TRAMediaHashOptions): IRAMediaHashIterator;
begin
  Result := TRAMediaHashIterator.Create(ConsoleID, Path, Data, Options);
end;

function CreateRAMediaHashIteratorWithCallbacks(ConsoleID: Cardinal; const Path: string; const Data: TBytes; const Callbacks: TRAHashIteratorCallbacks; UserData: Pointer): IRAMediaHashIterator;
var
  Options: TRAMediaHashOptions;
begin
  Options := Default(TRAMediaHashOptions);
  Options.SetCallbackTable(Callbacks, UserData);
  Result := CreateRAMediaHashIterator(ConsoleID, Path, Data, Options);
end;

function TryNextUniqueRAMediaHash(const Iterator: IRAMediaHashIterator; var Cursor: Integer; const TriedHashes: array of string; out Candidate: TRAMediaHashCandidate): Boolean;
begin
  while Iterator.TryNext(Cursor, Candidate) do
    if not MatchText(Candidate.Hash, TriedHashes) then
      Exit(True);
  Result := False;
end;

function TryFirstMediaHash(const Iterator: IRAMediaHashIterator; out Digest: string): Boolean;
var
  Candidate: TRAMediaHashCandidate;
  Cursor: Integer;
begin
  Cursor := 0;
  Result := Iterator.TryNext(Cursor, Candidate);
  Digest := Candidate.Hash;
end;

function TryHashRAMedia(ConsoleID: Cardinal; const Path: string; const Data: TBytes; const Options: TRAMediaHashOptions; out Digest: string): Boolean;
begin
  Result := TryFirstMediaHash(CreateRAMediaHashIterator(ConsoleID, Path, Data, Options), Digest);
end;

function TryHashRAMediaBuffer(ConsoleID: Cardinal; const Data: TBytes; const Options: TRAMediaHashOptions; out Digest: string): Boolean;
begin
  Digest := '';
  if ConsoleID = RAConsoleUnknown then
    Exit(False);
  Result := TryFirstMediaHash(TRAMediaHashIterator.Create(ConsoleID, '', Data, Options, True), Digest);
end;

function TryHashRAMediaFile(ConsoleID: Cardinal; const Path: string; const Options: TRAMediaHashOptions; out Digest: string): Boolean;
begin
  Digest := '';
  if ConsoleID = RAConsoleUnknown then
    Exit(False);
  Result := TryHashRAMedia(ConsoleID, Path, nil, Options, Digest);
end;

initialization
  DefaultHashLock := TCriticalSection.Create;

finalization
  DefaultHashLock.Free;

end.

