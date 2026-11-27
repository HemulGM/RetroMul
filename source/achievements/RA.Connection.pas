unit RA.Connection;

interface

uses
  Core.Emulation.Types, Core.Storage, System.Classes,
  System.Generics.Collections, System.SyncObjs, System.SysUtils, RA.GameData,
  RA.Hash, RA.Http, RA.Protocol, RA.Runtime, RA.Session;

type
  IRAConnection = interface(IEmulationAchievementObserver)
    ['{9585C936-518D-4182-BB26-D3EE91071410}']
    function GameData: TRAGameData;
    function TakeRuntimeEvents: TArray<TRARuntimeEvent>;
    function TakeSubmissions: TArray<TRASubmission>;
    function TakeError: string;
    procedure SetShareRichPresence(Value: Boolean);
  end;

function TryHashRAFile(const Storage: IStorage; const SystemId, Location: string; const Media: IEmulationAchievementMedia; out Digest: string): Boolean;

// Call on a background worker, then attach the returned observer on the frontend thread.
function OpenRAConnection(Console: TRARomConsole; const ROM: TBytes; const Credentials: TRACredentials; const UserAgent: string; ShareRichPresence: Boolean = True): IRAConnection; overload;

function OpenRAConnection(Console: TRARomConsole; const ROM: TBytes; const Credentials: TRACredentials; const Post: TRAPost): IRAConnection; overload;

implementation

uses
  Core.EmulatorRegistry, Core.MediaArchive, RA.Memory;

function TryHashRAFile(const Storage: IStorage; const SystemId, Location: string; const Media: IEmulationAchievementMedia; out Digest: string): Boolean;
begin
  Digest := '';
  if Media = nil then
    Exit(False);
  var Stream := Storage.OpenRead(Location);
  try
    var Context := TCoreLoadContext.Create(Stream, Storage, Location);
    try
      if IsMediaArchive(Context.SourceName) then
      begin
        var Match := ResolveEmulationCore(Context, SystemId, '');
        try
          if (Match = nil) or (Match.PlatformId <> SystemId) or not Context.ArchiveEntry then
            Exit(False);
        finally
          Match.Free;
        end;
      end;
      var Input := Context.Stream;
      Input.Position := 0;
      Result := Media.AcceptsROM(Context.SourceName, Input) and
        TryHashRAEmulatedROM(TRARomConsole(Media.ConsoleId), Input, Digest);
    finally
      Context.Free;
    end;
  finally
    Stream.Free;
  end;
end;

type
  TRAConnection = class(TInterfacedObject, IEmulationAchievementObserver, IRAConnection)
  private
    FHTTP: TRAHttpClient;
    FSession: TRASession;
    FNetwork: TThread;
    FWake: TEvent;
    FLock: TCriticalSection;
    FRuntimeEvents: TList<TRARuntimeEvent>;
    FSubmissions: TList<TRASubmission>;
    FError: string;
    FEmulationFailed: Boolean;
    procedure BeginSession(Console: TRARomConsole; const ROM: TBytes; const Credentials: TRACredentials; const Post: TRAPost; ShareRichPresence: Boolean);
    procedure NetworkLoop;
    procedure ReportError(const Message: string);
  public
    constructor Create(Console: TRARomConsole; const ROM: TBytes; const Credentials: TRACredentials; const UserAgent: string; ShareRichPresence: Boolean); overload;
    constructor Create(Console: TRARomConsole; const ROM: TBytes; const Credentials: TRACredentials; const Post: TRAPost); overload;
    destructor Destroy; override;
    procedure Frame(const ReadMemory: TEmulationAchievementRead);
    procedure Reset;
    function CaptureProgress: TBytes;
    procedure RestoreProgress(const Data: TBytes);
    function GameData: TRAGameData;
    function TakeRuntimeEvents: TArray<TRARuntimeEvent>;
    function TakeSubmissions: TArray<TRASubmission>;
    function TakeError: string;
    procedure SetShareRichPresence(Value: Boolean);
  end;

constructor TRAConnection.Create(Console: TRARomConsole; const ROM: TBytes; const Credentials: TRACredentials; const UserAgent: string; ShareRichPresence: Boolean);
begin
  inherited Create;
  FHTTP := TRAHttpClient.Create(UserAgent);
  BeginSession(Console, ROM, Credentials, nil, ShareRichPresence);
end;

constructor TRAConnection.Create(Console: TRARomConsole; const ROM: TBytes; const Credentials: TRACredentials; const Post: TRAPost);
begin
  inherited Create;
  BeginSession(Console, ROM, Credentials, Post, True);
end;

procedure TRAConnection.BeginSession(Console: TRARomConsole; const ROM: TBytes; const Credentials: TRACredentials; const Post: TRAPost; ShareRichPresence: Boolean);
var
  GameHash: string;
begin
  if (Length(ROM) = 0) or not TryHashRARom(Console, ROM, GameHash) then
    raise ERARomNotRecognized.Create('Could not identify the ROM for RetroAchievements');
  FLock := TCriticalSection.Create;
  FWake := TEvent.Create(nil, False, False, '');
  FRuntimeEvents := TList<TRARuntimeEvent>.Create;
  FSubmissions := TList<TRASubmission>.Create;
  if FHTTP <> nil then
    FSession := TRASession.CreateHosted(FHTTP.PostTo, Credentials, GameHash, Ord(Console),
      False, nil, ShareRichPresence)
  else
    FSession := TRASession.Create(Post, Credentials, GameHash, Ord(Console),
      False, nil, ShareRichPresence);
  FNetwork := TThread.CreateAnonymousThread(NetworkLoop);
  FNetwork.FreeOnTerminate := False;
  FNetwork.Start;
end;

destructor TRAConnection.Destroy;
begin
  if FNetwork <> nil then
  begin
    FNetwork.Terminate;
    FWake.SetEvent;
    FNetwork.WaitFor;
    FNetwork.Free;
  end;
  FSession.Free;
  FSubmissions.Free;
  FRuntimeEvents.Free;
  FWake.Free;
  FLock.Free;
  FHTTP.Free;
  inherited;
end;

procedure TRAConnection.NetworkLoop;
var
  Submission: TRASubmission;
begin
  while not TThread.CurrentThread.CheckTerminated do
  begin
    try
      if FSession.PumpNetwork(Submission) then
      begin
        FLock.Acquire;
        try
          FSubmissions.Add(Submission);
        finally
          FLock.Release;
        end;
        Continue;
      end;
    except
      on Error: Exception do
        ReportError(Error.Message);
    end;
    FWake.WaitFor(250);
  end;
end;

procedure TRAConnection.ReportError(const Message: string);
begin
  FLock.Acquire;
  try
    FError := Message;
  finally
    FLock.Release;
  end;
end;

procedure TRAConnection.Frame(const ReadMemory: TEmulationAchievementRead);
var
  Events: TArray<TRARuntimeEvent>;
  Reader: TRAMemoryRead;
begin
  if FEmulationFailed then
    Exit;
  try
    Reader :=
      function(Address: Cardinal; Buffer: PByte; Count: Cardinal): Cardinal
      begin
        Result := ReadMemory(Address, Buffer, Count);
      end;
    Events := FSession.EvaluateFrame(Reader);
    if Length(Events) <> 0 then
    begin
      FLock.Acquire;
      try
        FRuntimeEvents.AddRange(Events);
      finally
        FLock.Release;
      end;
      FWake.SetEvent;
    end;
  except
    on Error: Exception do
    begin
      FEmulationFailed := True;
      ReportError(Error.Message);
    end;
  end;
end;

procedure TRAConnection.Reset;
begin
  FSession.Reset;
  FEmulationFailed := False;
end;

function TRAConnection.CaptureProgress: TBytes;
begin
  Result := FSession.CaptureProgress;
end;

procedure TRAConnection.RestoreProgress(const Data: TBytes);
begin
  if not FSession.RestoreProgress(Data) then
    FSession.RestoreProgress(nil);
  FEmulationFailed := False;
end;

function TRAConnection.GameData: TRAGameData;
begin
  Result := FSession.Game;
end;

function TRAConnection.TakeRuntimeEvents: TArray<TRARuntimeEvent>;
begin
  FLock.Acquire;
  try
    Result := FRuntimeEvents.ToArray;
    FRuntimeEvents.Clear;
  finally
    FLock.Release;
  end;
end;

function TRAConnection.TakeSubmissions: TArray<TRASubmission>;
begin
  FLock.Acquire;
  try
    Result := FSubmissions.ToArray;
    FSubmissions.Clear;
  finally
    FLock.Release;
  end;
end;

procedure TRAConnection.SetShareRichPresence(Value: Boolean);
begin
  FSession.SetShareRichPresence(Value);
end;

function TRAConnection.TakeError: string;
begin
  FLock.Acquire;
  try
    Result := FError;
    FError := '';
  finally
    FLock.Release;
  end;
end;

function OpenRAConnection(Console: TRARomConsole; const ROM: TBytes; const Credentials: TRACredentials; const UserAgent: string; ShareRichPresence: Boolean): IRAConnection;
begin
  Result := TRAConnection.Create(Console, ROM, Credentials, UserAgent, ShareRichPresence);
end;

function OpenRAConnection(Console: TRARomConsole; const ROM: TBytes; const Credentials: TRACredentials; const Post: TRAPost): IRAConnection;
begin
  Result := TRAConnection.Create(Console, ROM, Credentials, Post);
end;

end.

