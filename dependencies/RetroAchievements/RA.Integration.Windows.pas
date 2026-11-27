unit RA.Integration.Windows;

interface

{$ALIGN 8}

uses
  Winapi.Windows, RA.ExternalClient, RA.ExternalClient.ABI, RA.Integration,
  RA.Session;

type
  PRAIntegrationABIMenuItem = ^TRAIntegrationABIMenuItem;

  TRAIntegrationABIMenuItem = record
    LabelText: PAnsiChar;
    ID: Cardinal;
    Checked, Enabled: Byte;
  end;

  PRAIntegrationABIMenu = ^TRAIntegrationABIMenu;

  TRAIntegrationABIMenu = record
    Items: PRAIntegrationABIMenuItem;
    Count: Cardinal;
  end;

  PRAIntegrationABIEvent = ^TRAIntegrationABIEvent;

  TRAIntegrationABIEvent = record
    Kind: Cardinal;
    Item: PRAIntegrationABIMenuItem;
  end;

  TRAIntegrationABIWriteMemory = procedure(Address: Cardinal; Buffer: PByte; Count: Cardinal; Client: Pointer); cdecl;

  TRAIntegrationABIGetGameName = procedure(Buffer: PAnsiChar; BufferSize: Cardinal; Client: Pointer); cdecl;

  TRAIntegrationABIEventHandler = procedure(Event: PRAIntegrationABIEvent; Client: Pointer); cdecl;

  TRAIntegrationExportLookup = reference to function(const Name: AnsiString): Pointer;

  // The caller supplies live exports and keeps their code available for the provider's lifetime.
  TRAIntegrationExports = record
    GetVersion: function: PAnsiChar; cdecl;
    GetHostURL: function: PAnsiChar; cdecl;
    Initialize, InitializeOffline: function(Window: HWND; ClientName, ClientVersion: PAnsiChar): Integer; cdecl;
    Shutdown: procedure; cdecl;
    UpdateWindow: procedure(Window: HWND); cdecl;
    SetConsoleID: procedure(ConsoleID: Integer); cdecl;
    GetExternalClient: function(Table: PRAExternalClientTable; Version: Integer): Integer; cdecl;
    GetMenu: function: PRAIntegrationABIMenu; cdecl;
    ActivateMenuItem: function(ID: Cardinal): Integer; cdecl;
    SetWriteMemory: procedure(Client: Pointer; Handler: TRAIntegrationABIWriteMemory); cdecl;
    SetGetGameName: procedure(Client: Pointer; Handler: TRAIntegrationABIGetGameName); cdecl;
    SetEventHandler: procedure(Client: Pointer; Handler: TRAIntegrationABIEventHandler); cdecl;
    HasModifications: function: Integer; cdecl;
    GetAchievementState: function(ID: Cardinal): Integer; cdecl;
  end;

  TRAIntegrationExportProvider = class(TInterfacedObject, IRAIntegrationProvider, IRAIntegrationHostProvider, IRAIntegrationExternalClient)
  private
    type
      TExternalSession = class(TRAExternalClientSession)
      private
        FProvider: TRAIntegrationExportProvider;
        FKeepProvider: IRAIntegrationProvider;
      public
        destructor Destroy; override;
      end;
  private
    FExports: TRAIntegrationExports;
    FPost: TRAHostedPost;
    FClient: TExternalSession;
    FWriteMemory: TRAIntegrationWriteMemory;
    FGetGameName: TRAIntegrationGetGameName;
    FEventHandler: TRAIntegrationEventHandler;
    FInitialized, FInitializationAttempted: Boolean;
    FBusy, FShutdownPending: Boolean;
    procedure FinishShutdown;
    class procedure ReceiveWriteMemory(Address: Cardinal; Buffer: PByte; Count: Cardinal; Client: Pointer); cdecl; static;
    class procedure ReceiveGameName(Buffer: PAnsiChar; BufferSize: Cardinal; Client: Pointer); cdecl; static;
    class procedure ReceiveEvent(Event: PRAIntegrationABIEvent; Client: Pointer); cdecl; static;
  public
    constructor Create(const Functions: TRAIntegrationExports; const Post: TRAHostedPost);
    function GetVersion: string;
    function TryGetServerHost(out Host: string): Boolean;
    function Initialize(const Host: TRAIntegrationHost; Session: TRASession): Boolean;
    function AcquireExternalSession: IRAExternalSession;
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

  // The owner calls this on the window thread. The parent menu is borrowed.
  TRAIntegrationWindowMenu = class
  private
    FParentMenu, FPopupMenu: HMENU;
    FWindowHandle: HWND;
    function FindPopup: Integer;
    procedure Redraw;
  public
    destructor Destroy; override;
    function Rebuild(ParentMenu: HMENU; WindowHandle: HWND; const Items: TArray<TRAIntegrationMenuItem>; const Caption: string = '&RetroAchievements'): Boolean;
    function UpdateItem(const Item: TRAIntegrationMenuItem): Boolean;
    procedure Clear;
  end;

function TryResolveRAIntegrationExports(const Lookup: TRAIntegrationExportLookup; out Functions: TRAIntegrationExports; out MissingExport: AnsiString): Boolean;

implementation

uses
  System.SysUtils, RA.ExternalClient.Events, RA.Streams;

function TryResolveRAIntegrationExports(const Lookup: TRAIntegrationExportLookup; out Functions: TRAIntegrationExports; out MissingExport: AnsiString): Boolean;
var
  Resolved: TRAIntegrationExports;

  function ResolveRequired(const Name: AnsiString; Destination: PPointer): Boolean;
  begin
    Destination^ := Lookup(Name);
    Result := Destination^ <> nil;
    if not Result then
      MissingExport := Name;
  end;

begin
  Functions := Default(TRAIntegrationExports);
  MissingExport := '';
  if not Assigned(Lookup) then
    raise EArgumentNilException.Create('RAIntegration requires an export lookup function');

  Resolved := Default(TRAIntegrationExports);
  if not ResolveRequired('_RA_IntegrationVersion', @@Resolved.GetVersion) or
    not ResolveRequired('_RA_InitClient', @@Resolved.Initialize) or
    not ResolveRequired('_Rcheevos_GetExternalClient', @@Resolved.GetExternalClient) then
    Exit(False);

  PPointer(@@Resolved.GetHostURL)^ := Lookup('_RA_HostUrl');
  PPointer(@@Resolved.InitializeOffline)^ := Lookup('_RA_InitOffline');
  PPointer(@@Resolved.Shutdown)^ := Lookup('_RA_Shutdown');
  PPointer(@@Resolved.UpdateWindow)^ := Lookup('_RA_UpdateHWnd');
  PPointer(@@Resolved.SetConsoleID)^ := Lookup('_RA_SetConsoleID');
  PPointer(@@Resolved.GetMenu)^ := Lookup('_Rcheevos_RAIntegrationGetMenu');
  PPointer(@@Resolved.ActivateMenuItem)^ := Lookup('_Rcheevos_ActivateRAIntegrationMenuItem');
  PPointer(@@Resolved.SetWriteMemory)^ := Lookup('_Rcheevos_SetRAIntegrationWriteMemoryFunction');
  PPointer(@@Resolved.SetGetGameName)^ := Lookup('_Rcheevos_SetRAIntegrationGetGameNameFunction');
  PPointer(@@Resolved.SetEventHandler)^ := Lookup('_Rcheevos_SetRAIntegrationEventHandler');
  PPointer(@@Resolved.HasModifications)^ := Lookup('_Rcheevos_HasModifications');
  PPointer(@@Resolved.GetAchievementState)^ := Lookup('_Rcheevos_GetAchievementState');
  Functions := Resolved;
  Result := True;
end;

function ConvertIntegrationMenuItem(const Item: TRAIntegrationABIMenuItem): TRAIntegrationMenuItem;
begin
  Result.ID := Item.ID;
  Result.LabelText := ReadExternalText(Item.LabelText);
  Result.Checked := Item.Checked <> 0;
  Result.Enabled := Item.Enabled <> 0;
end;

constructor TRAIntegrationExportProvider.Create(const Functions: TRAIntegrationExports; const Post: TRAHostedPost);
begin
  inherited Create;
  if not Assigned(Functions.GetVersion) or not Assigned(Functions.Initialize) or not Assigned(Functions.GetExternalClient) then
    raise EArgumentException.Create('RAIntegration requires version, initialization and external client exports');
  if not Assigned(Post) then
    raise EArgumentNilException.Create('RAIntegration requires a hosted transport');
  FExports := Functions;
  FPost := Post;
end;

function TRAIntegrationExportProvider.GetVersion: string;
begin
  Result := ReadExternalText(FExports.GetVersion());
end;

function TRAIntegrationExportProvider.TryGetServerHost(out Host: string): Boolean;
begin
  Host := '';
  if Assigned(FExports.GetHostURL) then
    Host := ReadExternalText(FExports.GetHostURL());
  Result := Host <> '';
end;

function TRAIntegrationExportProvider.Initialize(const Host: TRAIntegrationHost; Session: TRASession): Boolean;
var
  Name, Version: UTF8String;
begin
  if FInitializationAttempted or FBusy then
    Exit(False);
  Name := UTF8String(Host.ClientName);
  Version := UTF8String(Host.ClientVersion);
  FInitializationAttempted := True;
  FShutdownPending := False;
  FBusy := True;
  try
    if Host.Offline and Assigned(FExports.InitializeOffline) then
      Result := FExports.InitializeOffline(Host.MainWindowHandle, PAnsiChar(Name), PAnsiChar(Version)) <> 0
    else
      Result := FExports.Initialize(Host.MainWindowHandle, PAnsiChar(Name), PAnsiChar(Version)) <> 0;
    FInitialized := Result and not FShutdownPending;
    Result := FInitialized;
  finally
    FBusy := False;
    if FShutdownPending then
      FinishShutdown;
  end;
end;

function TRAIntegrationExportProvider.AcquireExternalSession: IRAExternalSession;
var
  Table: TRAExternalClientTable;
  Client: TExternalSession;
  Owner: IRAExternalSession;
  Version: Integer;
begin
  Result := nil;
  if not FInitialized or FBusy or (FClient <> nil) then
    Exit;
  FBusy := True;
  try
    Version := RAExternalClientABIVersion;
    while Version > 0 do
    begin
      Table := Default(TRAExternalClientTable);
      if FExports.GetExternalClient(@Table, Version) <> 0 then
        Break;
      if FShutdownPending then
        Exit;
      Dec(Version);
    end;
    if Version = 0 then
      Exit;
    if FShutdownPending then
    begin
      if Assigned(Table.Destroy) then
        Table.Destroy();
      Exit;
    end;
    Client := TExternalSession.CreateHosted(FPost, @Table, Version);
    try
      Owner := TRAExternalSession.Create(Client);
    except
      Client.Free;
      raise;
    end;
    Client.FProvider := Self;
    Client.FKeepProvider := Self;
    FClient := Client;
    if not FShutdownPending then
      SetWriteMemoryFunction(FWriteMemory);
    if not FShutdownPending then
      SetGetGameNameFunction(FGetGameName);
    if not FShutdownPending then
      SetEventHandler(FEventHandler);
    if not FShutdownPending then
      Result := Owner;
  finally
    try
      Owner := nil;
    finally
      FBusy := False;
      if FShutdownPending then
        FinishShutdown;
    end;
  end;
end;

destructor TRAIntegrationExportProvider.TExternalSession.Destroy;
begin
  try
    if FProvider <> nil then
    begin
      if Assigned(FProvider.FExports.SetEventHandler) then
        FProvider.FExports.SetEventHandler(Self, nil);
      if Assigned(FProvider.FExports.SetGetGameName) then
        FProvider.FExports.SetGetGameName(Self, nil);
      if Assigned(FProvider.FExports.SetWriteMemory) then
        FProvider.FExports.SetWriteMemory(Self, nil);
    end;
  finally
    try
      inherited;
    finally
      if FProvider <> nil then
      begin
        FProvider.FClient := nil;
        if FProvider.FShutdownPending then
          FProvider.FinishShutdown;
      end;
    end;
  end;
end;

procedure TRAIntegrationExportProvider.Shutdown;
begin
  FInitialized := False;
  FShutdownPending := True;
  FWriteMemory := nil;
  FGetGameName := nil;
  FEventHandler := nil;
  FinishShutdown;
end;

procedure TRAIntegrationExportProvider.FinishShutdown;
begin
  // The external table and its callbacks are still in use until the client is destroyed.
  if FBusy or (FClient <> nil) or not FInitializationAttempted then
    Exit;
  FInitializationAttempted := False;
  FShutdownPending := False;
  FBusy := True;
  try
    if Assigned(FExports.Shutdown) then
      FExports.Shutdown();
  finally
    FBusy := False;
  end;
end;

procedure TRAIntegrationExportProvider.UpdateMainWindowHandle(Handle: NativeUInt);
begin
  if FInitialized and Assigned(FExports.UpdateWindow) then
    FExports.UpdateWindow(Handle);
end;

function TRAIntegrationExportProvider.GetMenu: TArray<TRAIntegrationMenuItem>;
var
  Menu: PRAIntegrationABIMenu;
  Item: PRAIntegrationABIMenuItem;
begin
  Result := nil;
  if not FInitialized or not Assigned(FExports.GetMenu) then
    Exit;
  Menu := FExports.GetMenu();
  if Menu = nil then
    Exit;
  Item := Menu.Items;
  SetLength(Result, CheckedExternalCount(Menu.Count, Item));
  for var Index := 0 to High(Result) do
  begin
    Result[Index] := ConvertIntegrationMenuItem(Item^);
    Inc(Item);
  end;
end;

function TRAIntegrationExportProvider.ActivateMenuItem(ID: Cardinal): Boolean;
begin
  Result := (ID <> 0) and FInitialized and Assigned(FExports.ActivateMenuItem) and (FExports.ActivateMenuItem(ID) <> 0);
end;

procedure TRAIntegrationExportProvider.SetConsoleID(ConsoleID: Cardinal);
begin
  if FInitialized and Assigned(FExports.SetConsoleID) then
    FExports.SetConsoleID(Integer(ConsoleID));
end;

function TRAIntegrationExportProvider.HasModifications: Boolean;
begin
  Result := FInitialized and Assigned(FExports.HasModifications) and (FExports.HasModifications() <> 0);
end;

function TRAIntegrationExportProvider.GetAchievementState(ID: Cardinal): TRAIntegrationAchievementState;
var
  State: Integer;
begin
  Result := TRAIntegrationAchievementState.None;
  if not FInitialized or not Assigned(FExports.GetAchievementState) then
    Exit;
  State := FExports.GetAchievementState(ID);
  if (State >= Ord(Low(TRAIntegrationAchievementState))) and (State <= Ord(High(TRAIntegrationAchievementState))) then
    Result := TRAIntegrationAchievementState(State);
end;

procedure TRAIntegrationExportProvider.SetWriteMemoryFunction(const Handler: TRAIntegrationWriteMemory);
var
  Callback: TRAIntegrationABIWriteMemory;
begin
  FWriteMemory := Handler;
  if (FClient <> nil) and Assigned(FExports.SetWriteMemory) then
  begin
    Callback := nil;
    if Assigned(FWriteMemory) then
      Callback := ReceiveWriteMemory;
    FExports.SetWriteMemory(FClient, Callback);
  end;
end;

procedure TRAIntegrationExportProvider.SetGetGameNameFunction(const Handler: TRAIntegrationGetGameName);
var
  Callback: TRAIntegrationABIGetGameName;
begin
  FGetGameName := Handler;
  if (FClient <> nil) and Assigned(FExports.SetGetGameName) then
  begin
    Callback := nil;
    if Assigned(FGetGameName) then
      Callback := ReceiveGameName;
    FExports.SetGetGameName(FClient, Callback);
  end;
end;

procedure TRAIntegrationExportProvider.SetEventHandler(const Handler: TRAIntegrationEventHandler);
var
  Callback: TRAIntegrationABIEventHandler;
begin
  FEventHandler := Handler;
  if (FClient <> nil) and Assigned(FExports.SetEventHandler) then
  begin
    Callback := nil;
    if Assigned(FEventHandler) then
      Callback := ReceiveEvent;
    FExports.SetEventHandler(FClient, Callback);
  end;
end;

class procedure TRAIntegrationExportProvider.ReceiveWriteMemory(Address: Cardinal; Buffer: PByte; Count: Cardinal; Client: Pointer);
begin
  try
    if (Client = nil) or (Buffer = nil) or (Count = 0) then
      Exit;
    var Handler := TExternalSession(Client).FProvider.FWriteMemory;
    if Assigned(Handler) then
      Handler(Address, Buffer, Count);
  except
    on Exception do
      Exit;
  end;
end;

class procedure TRAIntegrationExportProvider.ReceiveGameName(Buffer: PAnsiChar; BufferSize: Cardinal; Client: Pointer);
begin
  if (Buffer = nil) or (BufferSize = 0) then
    Exit;
  Buffer^ := #0;
  try
    if Client = nil then
      Exit;
    var Handler := TExternalSession(Client).FProvider.FGetGameName;
    if Assigned(Handler) then
      CopyRAUTF8Text(Handler(), Buffer, BufferSize);
  except
    on Exception do
      Exit;
  end;
end;

class procedure TRAIntegrationExportProvider.ReceiveEvent(Event: PRAIntegrationABIEvent; Client: Pointer);
var
  Data: TRAIntegrationEvent;
begin
  try
    if (Client = nil) or (Event = nil) or (Event.Kind > Cardinal(Ord(High(TRAIntegrationEventKind)))) then
      Exit;
    var Handler := TExternalSession(Client).FProvider.FEventHandler;
    if not Assigned(Handler) then
      Exit;
    Data := Default(TRAIntegrationEvent);
    Data.Kind := TRAIntegrationEventKind(Event.Kind);
    if Event.Item <> nil then
      Data.MenuItem := ConvertIntegrationMenuItem(Event.Item^);
    Handler(Data);
  except
    on Exception do
      Exit;
  end;
end;

function TRAIntegrationWindowMenu.FindPopup: Integer;
begin
  Result := -1;
  if (FParentMenu = 0) or (FPopupMenu = 0) then
    Exit;
  for var Index := GetMenuItemCount(FParentMenu) - 1 downto 0 do
    if GetSubMenu(FParentMenu, Index) = FPopupMenu then
      Exit(Index);
end;

procedure TRAIntegrationWindowMenu.Redraw;
begin
  if (FWindowHandle <> 0) and (GetMenu(FWindowHandle) = FParentMenu) then
    DrawMenuBar(FWindowHandle);
end;

destructor TRAIntegrationWindowMenu.Destroy;
begin
  Clear;
  inherited;
end;

procedure TRAIntegrationWindowMenu.Clear;
var
  Index: Integer;
begin
  Index := FindPopup;
  if Index < 0 then
  begin
    // The host can remove the menu item without destroying its submenu.
    if FPopupMenu <> 0 then
      DestroyMenu(FPopupMenu);
  end
  else if RemoveMenu(FParentMenu, Index, MF_BYPOSITION) then
  begin
    DestroyMenu(FPopupMenu);
    Redraw;
  end;
  FParentMenu := 0;
  FPopupMenu := 0;
  FWindowHandle := 0;
end;

function TRAIntegrationWindowMenu.Rebuild(ParentMenu: HMENU; WindowHandle: HWND; const Items: TArray<TRAIntegrationMenuItem>; const Caption: string): Boolean;
var
  Popup: HMENU;
  Flags: UINT;
  Position, CaptionLength, ItemLength: Integer;
  CaptionBuffer: string;
begin
  Result := False;
  if not IsMenu(ParentMenu) then
    Exit;
  Popup := CreatePopupMenu;
  if Popup = 0 then
    Exit;
  try
    for var Item in Items do
    begin
      if Item.ID = 0 then
      begin
        if not AppendMenuW(Popup, MF_SEPARATOR, 0, nil) then
          Exit;
        Continue;
      end;

      Flags := MF_STRING;
      if Item.Checked then
        Flags := Flags or MF_CHECKED;
      if not Item.Enabled then
        Flags := Flags or MF_GRAYED;
      if not AppendMenuW(Popup, Flags, Item.ID, PWideChar(Item.LabelText)) then
        Exit;
    end;

    Position := -1;
    if ParentMenu = FParentMenu then
      Position := FindPopup;
    if (Position < 0) and (Caption <> '') then
    begin
      CaptionLength := Length(Caption);
      // Read one extra character to distinguish a longer caption with the same prefix.
      SetLength(CaptionBuffer, CaptionLength + 2);
      for var Index := GetMenuItemCount(ParentMenu) - 1 downto 0 do
      begin
        ItemLength := GetMenuStringW(ParentMenu, Index, PWideChar(CaptionBuffer),
          Length(CaptionBuffer), MF_BYPOSITION);
        if (ItemLength = CaptionLength) and (Copy(CaptionBuffer, 1, ItemLength) = Caption) then
        begin
          Position := Index;
          Break;
        end;
      end;
    end;

    Flags := MF_POPUP or MF_STRING;
    if Length(Items) = 0 then
      Flags := Flags or MF_GRAYED;
    if Position >= 0 then
    begin
      if not ModifyMenuW(ParentMenu, Position, Flags or MF_BYPOSITION, UINT_PTR(Popup), PWideChar(Caption)) then
        Exit;
    end
    else if not AppendMenuW(ParentMenu, Flags, UINT_PTR(Popup), PWideChar(Caption)) then
      Exit;

    Clear;
    FParentMenu := ParentMenu;
    FPopupMenu := Popup;
    FWindowHandle := WindowHandle;
    Popup := 0;
    Redraw;
    Result := True;
  finally
    if Popup <> 0 then
      DestroyMenu(Popup);
  end;
end;

function TRAIntegrationWindowMenu.UpdateItem(const Item: TRAIntegrationMenuItem): Boolean;
var
  Entry: TMenuItemInfoW;
begin
  Result := False;
  if (Item.ID = 0) or (FindPopup < 0) then
    Exit;
  Entry := Default(TMenuItemInfoW);
  Entry.cbSize := SizeOf(Entry);
  Entry.fMask := MIIM_STATE;
  if not GetMenuItemInfoW(FPopupMenu, Item.ID, False, Entry) then
    Exit;
  Entry.fState := Entry.fState and not UINT(MFS_CHECKED or MFS_GRAYED);
  if Item.Checked then
    Entry.fState := Entry.fState or MFS_CHECKED;
  if not Item.Enabled then
    Entry.fState := Entry.fState or MFS_GRAYED;
  Result := SetMenuItemInfoW(FPopupMenu, Item.ID, False, Entry);
end;

end.

