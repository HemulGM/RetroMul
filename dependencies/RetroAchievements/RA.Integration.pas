unit RA.Integration;

interface

{$SCOPEDENUMS ON}

uses
  RA.Session;

type
  TRAIntegrationAchievementState = (None, published, local, Modified, Insecure);

  TRAIntegrationMenuItem = record
    ID: Cardinal; // Zero denotes a separator.
    LabelText: string;
    Checked, Enabled: Boolean;
  end;

  TRAIntegrationEventKind = (None, MenuItemChanged, HardcoreChanged, Pause, MenuChanged);

  TRAIntegrationEvent = record
    Kind: TRAIntegrationEventKind;
    MenuItem: TRAIntegrationMenuItem;
  end;

  TRAIntegrationEventHandler = reference to procedure(const Event: TRAIntegrationEvent);

  TRAIntegrationWriteMemory = reference to procedure(Address: Cardinal; Buffer: PByte; Count: Cardinal);

  TRAIntegrationGetGameName = reference to function: string;

  TRAIntegrationHost = record
    MainWindowHandle: NativeUInt;
    ClientName, ClientVersion: string;
    Offline: Boolean;
  end;

  IRAIntegrationProvider = interface
    ['{260944AE-FB9E-497C-820E-6A7781C1DC0A}']
    function GetVersion: string;
    function Initialize(const Host: TRAIntegrationHost; Session: TRASession): Boolean;
    // Called after every attempted initialization, including a failed one.
    procedure Shutdown;
    procedure UpdateMainWindowHandle(Handle: NativeUInt);
    function GetMenu: TArray<TRAIntegrationMenuItem>;
    function ActivateMenuItem(ID: Cardinal): Boolean;
    procedure SetWriteMemoryFunction(const Handler: TRAIntegrationWriteMemory);
    procedure SetGetGameNameFunction(const Handler: TRAIntegrationGetGameName);
    procedure SetEventHandler(const Handler: TRAIntegrationEventHandler);
    procedure SetConsoleID(ConsoleID: Cardinal);
    function HasModifications: Boolean;
    function GetAchievementState(ID: Cardinal): TRAIntegrationAchievementState;
  end;

  IRAIntegrationHostProvider = interface
    ['{63DCA90C-D7C0-48A8-B37D-52A32EFDB8D9}']
    function TryGetServerHost(out Host: string): Boolean;
  end;

  IRAIntegrationExternalClient = interface
    ['{220CC56B-7725-43BB-8990-7561B3669BED}']
    // Transfers ownership of the exported client to the integration.
    // The integration releases the client before it calls Shutdown.
    function AcquireExternalSession: IRAExternalSession;
  end;

  TRAIntegrationLoadResult = record
    Status: TRAQueryStatus;
    CurrentVersion, MinimumVersion: string;
  end;

  TRAIntegrationLoaded = reference to procedure(const Result: TRAIntegrationLoadResult);

  // The integration and its provider are used on the thread that pumps Session's network.
  // The owner must dispose of the integration before freeing the borrowed Session.
  TRAIntegration = class
  private
    type
      IConnection = interface(IRAExternalSession)
        function GetProvider: IRAIntegrationProvider;
        property Provider: IRAIntegrationProvider read GetProvider;
      end;

      TPendingConfiguration = record
        WriteMemory: TRAIntegrationWriteMemory;
        GetGameName: TRAIntegrationGetGameName;
        EventHandler: TRAIntegrationEventHandler;
        ConsoleID: Cardinal;
        HasConsoleID: Boolean;
      end;
  private
    FSession: TRASession;
    FConnection: IConnection;
    FPendingLoad: IRAQuery;
    FPendingConfiguration: TPendingConfiguration;
    FGeneration: UInt64;
    FWindowHandle: NativeUInt;
    function GetLoaded: Boolean;
    function ApplyPendingConfiguration(const Provider: IRAIntegrationProvider; Generation: UInt64): Boolean;
    function ConfigureProviderHost(const Provider: IRAIntegrationProvider; Generation: UInt64): Boolean;
    procedure FinishLoad(Generation: UInt64; const Provider: IRAIntegrationProvider; Host: TRAIntegrationHost; const Status: TRAQueryStatus; const MinimumVersion: string; const Completed: TRAIntegrationLoaded);
  public
    constructor Create(Session: TRASession);
    destructor Destroy; override;
    function BeginLoad(const Provider: IRAIntegrationProvider; const Host: TRAIntegrationHost; const Completed: TRAIntegrationLoaded = nil): IRAQuery;
    procedure Unload;
    procedure UpdateMainWindowHandle(Handle: NativeUInt);
    function GetMenu: TArray<TRAIntegrationMenuItem>;
    function ActivateMenuItem(ID: Cardinal): Boolean;
    procedure SetWriteMemoryFunction(const Handler: TRAIntegrationWriteMemory);
    procedure SetGetGameNameFunction(const Handler: TRAIntegrationGetGameName);
    procedure SetEventHandler(const Handler: TRAIntegrationEventHandler);
    procedure SetConsoleID(ConsoleID: Cardinal);
    function HasModifications: Boolean;
    function GetAchievementState(ID: Cardinal): TRAIntegrationAchievementState;
    property Loaded: Boolean read GetLoaded;
  end;

function RAIntegrationVersionLess(const Left, Right: string): Boolean;

implementation

uses
  System.Math, System.SysUtils, RA.Errors, RA.Protocol;

type
  // A host call or an exported-client call can retain the connection while Unload detaches it.
  TRAIntegrationConnection = class(TInterfacedObject, TRAIntegration.IConnection)
  private
    FExternal: IRAExternalSession;
    FProvider: IRAIntegrationProvider;
    function GetSession: TRASession;
    function GetProvider: IRAIntegrationProvider;
  public
    constructor Create(const Provider: IRAIntegrationProvider);
    procedure AcquireExternal(const Client: IRAIntegrationExternalClient);
    destructor Destroy; override;
  end;

constructor TRAIntegrationConnection.Create(const Provider: IRAIntegrationProvider);
begin
  inherited Create;
  FProvider := Provider;
end;

procedure TRAIntegrationConnection.AcquireExternal(const Client: IRAIntegrationExternalClient);
begin
  // Keep the interface result temporary out of the enclosing load operation.
  FExternal := Client.AcquireExternalSession;
end;

destructor TRAIntegrationConnection.Destroy;
begin
  try
    try
      FExternal := nil;
    finally
      FProvider.Shutdown;
    end;
  finally
    inherited;
  end;
end;

function TRAIntegrationConnection.GetSession: TRASession;
begin
  if FExternal = nil then
    Exit(nil);
  Result := FExternal.Session;
end;

function TRAIntegrationConnection.GetProvider: IRAIntegrationProvider;
begin
  Result := FProvider;
end;

function RAIntegrationVersionLess(const Left, Right: string): Boolean;
var
  LeftParts, RightParts: TArray<string>;
  LeftPart, RightPart: string;

  function Component(const Parts: TArray<string>; Index: Integer): string;
  var
    Start: Integer;
  begin
    if Index >= Length(Parts) then
      Exit('');
    Result := Parts[Index];
    Start := 1;
    while (Start <= Length(Result)) and (Result[Start] = '0') do
      Inc(Start);
    Delete(Result, 1, Start - 1);
  end;

begin
  LeftParts := Left.Split(['.']);
  RightParts := Right.Split(['.']);
  for var Index := 0 to Max(Length(LeftParts), Length(RightParts)) - 1 do
  begin
    LeftPart := Component(LeftParts, Index);
    RightPart := Component(RightParts, Index);
    if Length(LeftPart) <> Length(RightPart) then
      Exit(Length(LeftPart) < Length(RightPart));
    for var Digit := 1 to Length(LeftPart) do
      if LeftPart[Digit] <> RightPart[Digit] then
        Exit(LeftPart[Digit] < RightPart[Digit]);
  end;
  Result := False;
end;

constructor TRAIntegration.Create(Session: TRASession);
begin
  inherited Create;
  if Session = nil then
    raise EArgumentNilException.Create('RetroAchievements session is required');
  FSession := Session;
end;

destructor TRAIntegration.Destroy;
begin
  try
    Unload;
  finally
    inherited;
  end;
end;

function TRAIntegration.GetLoaded: Boolean;
begin
  Result := FConnection <> nil;
end;

function TRAIntegration.ConfigureProviderHost(const Provider: IRAIntegrationProvider; Generation: UInt64): Boolean;
var
  HostProvider: IRAIntegrationHostProvider;
  ServerHost: string;
begin
  Result := False;
  if not Supports(Provider, IRAIntegrationHostProvider, HostProvider) or
    not HostProvider.TryGetServerHost(ServerHost) or (Generation <> FGeneration) then
    Exit;
  Result := ServerHost = 'OFFLINE';
  if not Result and (ServerHost <> RAAPIHost) then
    FSession.SetHost(ServerHost);
end;

function TRAIntegration.BeginLoad(const Provider: IRAIntegrationProvider; const Host: TRAIntegrationHost; const Completed: TRAIntegrationLoaded): IRAQuery;
var
  Generation: UInt64;
  LoadResult: TRAIntegrationLoadResult;
begin
  if Provider = nil then
    raise EArgumentNilException.Create('RetroAchievements integration provider is required');
  if (Host.MainWindowHandle = 0) or (Host.ClientName = '') or (Host.ClientVersion = '') then
    raise EArgumentException.Create('RetroAchievements integration requires a window, client name and client version');

  if Loaded or not FSession.CanInitializeIntegration then
  begin
    LoadResult := Default(TRAIntegrationLoadResult);
    LoadResult.Status.ResultCode := RAErrorInvalidState;
    LoadResult.Status.ServerCode := 'invalid_state';
    if Loaded then
      LoadResult.Status.ErrorMessage := 'RAIntegration is already initialized'
    else
      LoadResult.Status.ErrorMessage := 'Cannot initialize RAIntegration after login';
    if Assigned(Completed) then
      Completed(LoadResult);
    Exit(nil);
  end;

  Unload;
  Generation := FGeneration;
  ConfigureProviderHost(Provider, Generation);
  if Generation <> FGeneration then
    Exit(nil);
  FWindowHandle := Host.MainWindowHandle;
  FPendingLoad := FSession.BeginFetchIntegrationVersion(
    procedure(const Status: TRAQueryStatus; const MinimumVersion: string)
    begin
      FinishLoad(Generation, Provider, Host, Status, MinimumVersion, Completed);
    end);
  Result := FPendingLoad;
end;

function TRAIntegration.ApplyPendingConfiguration(const Provider: IRAIntegrationProvider; Generation: UInt64): Boolean;
var
  Config: TPendingConfiguration;
begin
  Config := FPendingConfiguration;
  FPendingConfiguration := Default(TPendingConfiguration);
  if Config.HasConsoleID then
    Provider.SetConsoleID(Config.ConsoleID);
  if (Generation = FGeneration) and Assigned(Config.GetGameName) then
    Provider.SetGetGameNameFunction(Config.GetGameName);
  if (Generation = FGeneration) and Assigned(Config.WriteMemory) then
    Provider.SetWriteMemoryFunction(Config.WriteMemory);
  if (Generation = FGeneration) and Assigned(Config.EventHandler) then
    Provider.SetEventHandler(Config.EventHandler);
  Result := Generation = FGeneration;
end;

procedure TRAIntegration.FinishLoad(Generation: UInt64; const Provider: IRAIntegrationProvider; Host: TRAIntegrationHost; const Status: TRAQueryStatus; const MinimumVersion: string; const Completed: TRAIntegrationLoaded);
var
  LoadResult: TRAIntegrationLoadResult;
  ExternalClient: IRAIntegrationExternalClient;
  ConnectionObject: TRAIntegrationConnection;
  Connection: IConnection;
begin
  if Generation <> FGeneration then
    Exit;
  FPendingLoad := nil;
  LoadResult := Default(TRAIntegrationLoadResult);
  LoadResult.Status := Status;
  LoadResult.MinimumVersion := MinimumVersion;
  if Status.Success then
  begin
    LoadResult.Status.Success := False;
    try
      if not FSession.CanInitializeIntegration then
      begin
        LoadResult.Status.ResultCode := RAErrorInvalidState;
        LoadResult.Status.ServerCode := 'invalid_state';
        LoadResult.Status.ErrorMessage := 'Cannot initialize RAIntegration after login';
      end
      else
      begin
        LoadResult.CurrentVersion := Provider.GetVersion;
        if Generation <> FGeneration then
          Exit;
        if RAIntegrationVersionLess(LoadResult.CurrentVersion, MinimumVersion) then
        begin
          LoadResult.Status.ResultCode := RAErrorAborted;
          LoadResult.Status.ServerCode := 'integration_outdated';
          LoadResult.Status.ErrorMessage := Format('RAIntegration version %s is lower than minimum version %s',
            [LoadResult.CurrentVersion, MinimumVersion]);
        end
        else
        begin
          // The provider can choose a different host or offline mode after version validation.
          if ConfigureProviderHost(Provider, Generation) then
            Host.Offline := True;
          if Generation <> FGeneration then
            Exit;
          Host.MainWindowHandle := FWindowHandle;
          ConnectionObject := TRAIntegrationConnection.Create(Provider);
          Connection := ConnectionObject;
          try
            if not Provider.Initialize(Host, FSession) then
              raise Exception.Create('RAIntegration initialization failed');
            if (Generation <> FGeneration) or not ApplyPendingConfiguration(Provider, Generation) then
              Exit;
            if not FSession.CanInitializeIntegration then
            begin
              LoadResult.Status.ResultCode := RAErrorInvalidState;
              LoadResult.Status.ServerCode := 'invalid_state';
              LoadResult.Status.ErrorMessage := 'Cannot initialize RAIntegration after login';
            end
            else
            begin
              if Supports(Provider, IRAIntegrationExternalClient, ExternalClient) then
              begin
                ConnectionObject.AcquireExternal(ExternalClient);
                if Generation <> FGeneration then
                  Exit;
                if (Connection.Session = nil) or not FSession.AttachExternalSession(Connection) then
                  raise Exception.Create('RAIntegration external client export failed');
              end;
              if Generation <> FGeneration then
                Exit;
              if Host.MainWindowHandle <> FWindowHandle then
                Provider.UpdateMainWindowHandle(FWindowHandle);
              if Generation <> FGeneration then
                Exit;
              FConnection := Connection;
              LoadResult.Status.Success := True;
            end;
          finally
            if not LoadResult.Status.Success and (Connection.Session <> nil) then
              FSession.DetachExternalSession(Connection);
            Connection := nil;
          end;
        end;
      end;
    except
      on Error: Exception do
      begin
        LoadResult.Status.ResultCode := RAErrorAborted;
        LoadResult.Status.ServerCode := 'integration_init_failed';
        LoadResult.Status.ErrorMessage := Error.Message;
      end;
    end;
  end;
  if Generation = FGeneration then
  begin
    FPendingConfiguration := Default(TPendingConfiguration);
    if Assigned(Completed) then
      Completed(LoadResult);
  end;
end;

procedure TRAIntegration.Unload;
var
  Connection: IConnection;
begin
  Inc(FGeneration);
  FPendingConfiguration := Default(TPendingConfiguration);
  if FPendingLoad <> nil then
  begin
    FPendingLoad.Cancel;
    FPendingLoad := nil;
  end;
  FWindowHandle := 0;
  Connection := FConnection;
  FConnection := nil;
  if (Connection <> nil) and (Connection.Session <> nil) then
    FSession.DetachExternalSession(Connection);
end;

procedure TRAIntegration.UpdateMainWindowHandle(Handle: NativeUInt);
var
  Connection: IConnection;
begin
  Connection := FConnection;
  FWindowHandle := Handle;
  if Connection <> nil then
    Connection.Provider.UpdateMainWindowHandle(Handle);
end;

function TRAIntegration.GetMenu: TArray<TRAIntegrationMenuItem>;
var
  Connection: IConnection;
begin
  Connection := FConnection;
  if Connection = nil then
    Exit(nil);
  Result := Copy(Connection.Provider.GetMenu);
end;

function TRAIntegration.ActivateMenuItem(ID: Cardinal): Boolean;
var
  Connection: IConnection;
begin
  Connection := FConnection;
  Result := (ID <> 0) and (Connection <> nil) and Connection.Provider.ActivateMenuItem(ID);
end;

procedure TRAIntegration.SetWriteMemoryFunction(const Handler: TRAIntegrationWriteMemory);
var
  Connection: IConnection;
begin
  Connection := FConnection;
  if Connection <> nil then
    Connection.Provider.SetWriteMemoryFunction(Handler)
  else
    FPendingConfiguration.WriteMemory := Handler;
end;

procedure TRAIntegration.SetGetGameNameFunction(const Handler: TRAIntegrationGetGameName);
var
  Connection: IConnection;
begin
  Connection := FConnection;
  if Connection <> nil then
    Connection.Provider.SetGetGameNameFunction(Handler)
  else
    FPendingConfiguration.GetGameName := Handler;
end;

procedure TRAIntegration.SetEventHandler(const Handler: TRAIntegrationEventHandler);
var
  Connection: IConnection;
begin
  Connection := FConnection;
  if Connection <> nil then
    Connection.Provider.SetEventHandler(Handler)
  else
    FPendingConfiguration.EventHandler := Handler;
end;

procedure TRAIntegration.SetConsoleID(ConsoleID: Cardinal);
var
  Connection: IConnection;
begin
  Connection := FConnection;
  if Connection <> nil then
    Connection.Provider.SetConsoleID(ConsoleID)
  else
  begin
    FPendingConfiguration.ConsoleID := ConsoleID;
    FPendingConfiguration.HasConsoleID := True;
  end;
end;

function TRAIntegration.HasModifications: Boolean;
var
  Connection: IConnection;
begin
  Connection := FConnection;
  Result := (Connection <> nil) and Connection.Provider.HasModifications;
end;

function TRAIntegration.GetAchievementState(ID: Cardinal): TRAIntegrationAchievementState;
var
  Connection: IConnection;
begin
  Connection := FConnection;
  if Connection = nil then
    Exit(TRAIntegrationAchievementState.None);
  Result := Connection.Provider.GetAchievementState(ID);
end;

end.

