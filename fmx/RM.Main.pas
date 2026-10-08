unit RM.Main;

interface

uses
  System.SysUtils, System.Classes, System.Types, System.UITypes, FMX.Forms,
  FMX.Types, FMX.Controls, FMX.Objects, FMX.Graphics, FMX.Dialogs, NES.Consts,
  NES.Controller, Core.Emulation, Core.EmulatorFactory, Core.Adapter.MD,
  Core.Adapter.SNES, Core.Adapter.NeoGeo, WinUI3.Form, WinUI3.Style,
  FMX.Controls.Presentation, FMX.StdCtrls, FMX.Layouts, FMX.Platform,
  NES.SuborKeyboard, NES.PowerPad, NES.FamicomKeyboard, NES.MiraclePiano,
  {$IFDEF ANDROID}
  Androidapi.Helpers, Androidapi.JNI.GraphicsContentViewText, Androidapi.JNI.App,
  Androidapi.JNI.Widget, Androidapi.JNI.Os, Androidapi.JNI.Media,
  FMX.ApplicationEvents, RM.DocumentTransfer.Android,
  {$ENDIF}
  Core.Storage, RM.Storage.Dialogs, FMX.OpenDialog, RM.Gamepad, FMX.ListBox,
  SCRP.GameList, FMX.Edit, FMX.SearchBox, NES.FamicomDataRecorder,
  NES.DataRecorder, RM.FrameUpload, RM.Settings, RM.Input, FMXInput,
  Core.InputConfig;

type
  TListBoxItemGame = class(TListBoxItem)
  protected
    FLoaded: Boolean;
  public
    RomFile: TStorageFile;
    Storage: IStorage;
    procedure ApplyStyle; override;
  end;

  TFormMain = class(TWinUIForm)
    ImageCanvas: TImage;
    TimerUpdate: TTimer;
    LayoutHead: TLayout;
    LabelStatus: TLabel;
    ImageLogo: TImage;
    RectangleBG: TRectangle;
    LayoutLeft: TLayout;
    LayoutClient: TLayout;
    LabelPaused: TLabel;
    Panel1: TPanel;
    Layout2: TLayout;
    ListBoxGames: TListBox;
    ListBoxItem1: TListBoxItem;
    RadioButtonGB: TRadioButton;
    RadioButtonGBC: TRadioButton;
    RadioButtonNES: TRadioButton;
    RadioButtonMD: TRadioButton;
    RadioButtonNeoGeo: TRadioButton;
    RadioButtonSNES: TRadioButton;
    ImageNoBox: TImage;
    Layout1: TLayout;
    ButtonOpen: TButton;
    SearchBoxGame: TSearchBox;
    ButtonStop: TButton;
    ButtonPalette: TButton;
    PathLabel1: TPathLabel;
    PathLabel2: TPathLabel;
    PathLabel3: TPathLabel;
    Panel2: TPanel;
    ButtonSetRoot: TButton;
    ButtonCloseRom: TButton;
    procedure FormActivate(Sender: TObject);
    procedure FormResize(Sender: TObject);
    procedure FormDeactivate(Sender: TObject);
    procedure FormKeyUp(Sender: TObject; var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
    procedure FormKeyDown(Sender: TObject; var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
    procedure TimerUpdateTimer(Sender: TObject);
    procedure ButtonOpenClick(Sender: TObject);
    procedure FormSafeAreaChanged(Sender: TObject; const AInsets: TRectF);
    procedure FormCreate(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
    procedure ChangeSystem(Sender: TObject);
    procedure ListBoxGamesItemClick(const Sender: TCustomListBox; const Item: TListBoxItem);
    procedure LayoutClientClick(Sender: TObject);
    procedure ButtonStopClick(Sender: TObject);
    procedure ButtonPaletteClick(Sender: TObject);
    procedure LayoutClientDblClick(Sender: TObject);
    procedure ButtonSetRootClick(Sender: TObject);
    procedure FormSaveState(Sender: TObject);
    procedure ButtonCloseRomClick(Sender: TObject);
    procedure ImageCanvasMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Single);
    procedure ImageCanvasMouseUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Single);
  private
    FEmulation: IEmulationCore;
    FInput: TInputManager;
    FInputPorts: TCoreInputPorts;
    FInputSystemId: string;
    FSettingsView: TSettingsView;
    FSettingsLibraryWidth: Single;
    FSettingsClientVisible, FSettingsWasPaused, FSettingsClosing: Boolean;
    FSettingsLeftAlign: TAlignLayout;
    FControlBottomInset: Integer;
    FDispatchingInput, FSuppressInputUntilRelease: Boolean;
    procedure SettingsClick(Sender: TObject);
    procedure SettingsApplied(Sender: TObject);
    procedure SettingsClose(Sender: TObject);
    procedure PollHostInput;
    procedure LoadHostInput(const SystemId: string);
    procedure ApplyControlInset;
  private
    FGamepad: TScreenGamepad;
    FSystemId: string;
    FSuborKeyboard: TNesSuborKeyboard;
    FFamicomKeyboard: TNesFamicomKeyboard;
    FMiraclePiano: TNesMiraclePiano;
    FPowerPad: TNesPowerPad;
    FDataRecorder: TNesDataRecorder;
    FGamepadInput: TEmulatorInput;
    FSoundErrorShown: Boolean;
    FRomDisplayName: string;
    FOpeningRom: Boolean;
    FEmulationFaulted: Boolean;
    FUserPaused: Boolean;
    FKeysDown: array[0..2048] of Boolean;
    FStorage: IStorage;
    FZapperPixel: TPoint;
    FFileDialog: TFMXOpenDialog;
    FCallbackAlive: TFunc<Boolean>;
    FInvalidateCallbacks: TProc;
    {$IFDEF ANDROID}
    FTransfer: TAndroidDocumentTransfer;
    FChoosingTape: Boolean;
    FAppEvents: TApplicationEvents;
    FInBackground, FActivityPaused: Boolean;
    FSuborKeyboardTouchAttached: Boolean;
    FFamicomKeyboardTouchAttached: Boolean;
    FMiraclePianoTouchAttached: Boolean;
    FPowerPadTouchAttached: Boolean;
    function ApplicationStateChanged(Sender: TObject; const AAppEvent: TApplicationEvent; const AContext: TObject): Boolean;
    procedure PollDocumentTransfer;
    {$ENDIF}
    procedure ScreenshotClick(Sender: TObject);
    procedure GamepadChanged(Sender: TObject);
    procedure SuborKeyboardChanged(Sender: TObject);
    procedure FamicomKeyboardChanged(Sender: TObject);
    procedure MiraclePianoChanged(Sender: TObject);
    procedure UpdatePeripheralInput;
    function CombinedGamepadInput: TEmulatorInput;
    procedure ForwardKeyState(Code: Word; Pressed: Boolean);
    procedure SuborKeyboardPower(Sender: TObject);
    procedure PowerPadChanged(Sender: TObject);
    procedure TapeAction(Sender: TObject; Action: TTapeAction; const FileName: string);
    procedure ChooseTapeFile(Sender: TObject);
    procedure SaveTapeAs(Sender: TObject);
    procedure UpdatePeripheralFeedback;
    procedure SetStatus(const Text: string);
    procedure SyncActivity;
    procedure OpenRom;
    procedure SelectDocument(ForCassette: Boolean);
    procedure FinishFileSelection;
    procedure StopOnError;
    procedure UpdateFrame;
    procedure SwitchPause;
    procedure LoadSystem(const SystemId: string);
    procedure FillGameItem(Item: TListBoxItem; Game: TGame; const Root: string);
    procedure SwitchFullScreen;
    procedure Load;
    procedure Save;
    procedure MobileCloseRom;
    procedure Stop;
  protected
    function CreateStorage: IStorage; virtual;
    function CreateHostInput: TInputManager; virtual;
    function HostInputHasFocus: Boolean; virtual;
    procedure ReportAudioError(const MessageText: string); virtual;
    function CreateCore(const FileName: string): IEmulationCore; virtual;
    procedure DoOnSettingChange; override;
  public
    procedure SaveSnapshot(const Name: string);
    procedure LoadSnapshot(const Name: string);
    procedure LoadRom(const FileName: string; const DisplayName: string = '');
    procedure SelectTapeFile(const FileName: string);
    function SaveScreenshot: string;
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

  end;

const
  AppName = 'RetroMul';
  ConfigFileName = 'config.ini';

var
  FormMain: TFormMain;

implementation

uses
  System.IOUtils, System.Math, FMX.Ani, System.IniFiles, System.Messaging,
  RM.Styles, Core.Adapter.GB, GB.Palettes, Core.Adapter.NES, Core.SavePaths,
  Core.RomFormat,
  {$IFDEF MSWINDOWS}
  Winapi.Windows,
  {$ENDIF}
  HGM.FMX.Image, Core.Adapter.GBC;

{$R *.fmx}

function HostKeyCode(Key: Word; KeyChar: WideChar): Word;
begin
  // Some FMX backends report printable keys through KeyChar alone.
  // Preserve native codes (including numpad keys); use the same fallback
  // on down and up so lowercase/uppercase characters address one held key.
  if Key <> 0 then
    Exit(Key);
  case KeyChar of
    'a'..'z':
      Result := Ord(KeyChar) - Ord('a') + vkA;
    'A'..'Z', '0'..'9':
      Result := Ord(KeyChar);
    ' ':
      Result := vkSpace;
    '!':
      Result := vk1;
    '@':
      Result := vk2;
    '#':
      Result := vk3;
    '$':
      Result := vk4;
    '%':
      Result := vk5;
    '^':
      Result := vk6;
    '&':
      Result := vk7;
    '*':
      Result := vk8;
    '(':
      Result := vk9;
    ')':
      Result := vk0;
    ';', ':':
      Result := vkSemicolon;
    '=', '+':
      Result := vkEqual;
    ',', '<':
      Result := vkComma;
    '-', '_':
      Result := vkMinus;
    '.', '>':
      Result := vkPeriod;
    '/', '?':
      Result := vkSlash;
    '`', '~':
      Result := vkTilde;
    '[', '{':
      Result := vkLeftBracket;
    '\', '|':
      Result := vkBackslash;
    ']', '}':
      Result := vkRightBracket;
    '''', '"':
      Result := vkQuote;
  else
    Result := 0;
  end;
end;

function TryGetImagePixel(const Image: TImage; const X, Y: Single; out PixelX, PixelY: Integer): Boolean;
begin
  Result := False;
  PixelX := -1;
  PixelY := -1;

  if (Image.Width <= 0) or (Image.Height <= 0) or (Image.Bitmap.Width <= 0) or (Image.Bitmap.Height <= 0) then
    Exit;

  var Scale := Min(Image.Width / Image.Bitmap.Width, Image.Height / Image.Bitmap.Height);
  var DrawWidth := Image.Bitmap.Width * Scale;
  var DrawHeight := Image.Bitmap.Height * Scale;
  var Left := (Image.Width - DrawWidth) / 2;
  var Top := (Image.Height - DrawHeight) / 2;

  if (X < Left) or (Y < Top) or (X >= Left + DrawWidth) or (Y >= Top + DrawHeight) then
    Exit;

  PixelX := Min(Image.Bitmap.Width - 1, Floor((X - Left) / Scale));
  PixelY := Min(Image.Bitmap.Height - 1, Floor((Y - Top) / Scale));
  Result := True;
end;

{ TFormMain }

procedure TFormMain.ApplyControlInset;
begin
  if FGamepad <> nil then
    FGamepad.Margins.Bottom := FControlBottomInset;
  if FPowerPad <> nil then
    FPowerPad.Margins.Bottom := FControlBottomInset;
  if FSuborKeyboard <> nil then
    FSuborKeyboard.Margins.Bottom := FControlBottomInset;
  if FFamicomKeyboard <> nil then
    FFamicomKeyboard.Margins.Bottom := FControlBottomInset;
  if FMiraclePiano <> nil then
    FMiraclePiano.Margins.Bottom := FControlBottomInset;
end;

procedure TFormMain.LoadHostInput(const SystemId: string);
begin
  FInputSystemId := SystemId;
  FInputPorts := LoadCoreInputPorts(FStorage, SystemId);
  var Ini := FStorage.ReadConfig(FStorage.ConfigFile(SystemId));
  try
    if FInput <> nil then
    begin
      LoadInputBindings(FInput, Ini, SystemId);
      FilterInputBindings(FInput, Ini);
    end;
  finally
    Ini.Free;
  end;
  FSuppressInputUntilRelease := True;
end;

procedure TFormMain.SettingsClick(Sender: TObject);
begin
  if (FSettingsView <> nil) or FOpeningRom then
    Exit;
  FSettingsWasPaused := (FEmulation <> nil) and FEmulation.IsPaused;
  FormDeactivate(Self);
  if FEmulation <> nil then
    FEmulation.Pause;
  FSettingsLibraryWidth := LayoutLeft.Width;
  FSettingsClientVisible := LayoutClient.Visible;
  FSettingsLeftAlign := LayoutLeft.Align;
  FSettingsView := TSettingsView.CreateSettings(Self, FStorage, FInput);
  FSettingsView.Parent := Self;
  FSettingsView.Align := TAlignLayout.Client;
  FSettingsView.OnApply := SettingsApplied;
  FSettingsView.OnClose := SettingsClose;
  Panel1.Visible := False;
  ButtonSetRoot.Visible := False;
  LayoutLeft.Align := TAlignLayout.Left;
  LayoutLeft.Width := Layout2.Width;
  LayoutClient.Visible := False;
  FSettingsView.BringToFront;
  SyncActivity;
  {$IFDEF ANDROID}
  FGamepad.AttachToForm(nil);
  FPowerPad.AttachToForm(nil);
  FSuborKeyboard.AttachToForm(nil);
  FFamicomKeyboard.AttachToForm(nil);
  FMiraclePiano.AttachToForm(nil);
  {$ENDIF}
end;

procedure TFormMain.SettingsApplied(Sender: TObject);
begin
  Load;
  // Keep the active core's hardware connections until the ROM is reopened.
  // Input assignments can be refreshed independently on close.
end;

procedure TFormMain.SettingsClose(Sender: TObject);
begin
  if (FSettingsView = nil) or FSettingsClosing then
    Exit;
  FSettingsClosing := True;
  FSettingsView.Visible := False;
  // Release through the UI queue so the clicked button finishes its event first.
  var Alive: TFunc<Boolean> := FCallbackAlive;
  TThread.ForceQueue(nil,
    procedure
    begin
      if not Alive() then
        Exit;
      FreeAndNil(FSettingsView);
      FSettingsClosing := False;
      LayoutLeft.Align := FSettingsLeftAlign;
      LayoutLeft.Width := FSettingsLibraryWidth;
      Panel1.Visible := True;
      LayoutClient.Visible := FSettingsClientVisible;
      LoadSystem(FSystemId);
      if FInput <> nil then
      begin
        var Ini := FStorage.ReadConfig(FStorage.ConfigFile(FInputSystemId));
        try
          LoadInputBindings(FInput, Ini, FInputSystemId);
          FilterInputBindings(FInput, Ini);
        finally
          Ini.Free;
        end;
      end;
      FSuppressInputUntilRelease := True;
      if (FEmulation <> nil) and not FSettingsWasPaused and not FEmulationFaulted then
        FEmulation.Resume;
      SyncActivity;
      {$IFDEF ANDROID}
      FormActivate(Self);
      {$ENDIF}
      if LayoutClient.Visible then
        LayoutClient.SetFocus;
    end);
end;

procedure TFormMain.PollHostInput;
begin
  FInput.Enabled := HostInputHasFocus and not FOpeningRom;
  FInput.Poll;
  if not FInput.Enabled then
    Exit;
  if FSettingsView <> nil then
  begin
    FSettingsView.Poll;
    Exit;
  end;
  if (Focused <> nil) and (Focused.GetObject is TCustomEdit) then
  begin
    if FEmulation <> nil then
      FEmulation.ClearInput;
    FSuppressInputUntilRelease := True;
    FillChar(FKeysDown, SizeOf(FKeysDown), 0);
    Exit;
  end;
  var Keys := ReadHostKeys(FInput);
  if FSuppressInputUntilRelease then
  begin
    for var V in FInput.Values do
      if (V.Kind in [TInputElementKind.Key, TInputElementKind.Button]) and (V.Value > 0.5) then
        Exit;
    FSuppressInputUntilRelease := False;
  end;
  var Shift: TShiftState := [];
  if Keys[vkShift] then
    Include(Shift, ssShift);
  if Keys[vkControl] then
    Include(Shift, ssCtrl);
  if Keys[vkMenu] then
    Include(Shift, ssAlt);
  FDispatchingInput := True;
  try
    for var i := 1 to High(Keys) do
      if Keys[i] <> FKeysDown[i] then
      begin
        var Code := Word(i);
        var Ch: WideChar := #0;
        if Keys[i] then
          FormKeyDown(Self, Code, Ch, Shift)
        else
          FormKeyUp(Self, Code, Ch, Shift);
      end;
  finally
    FDispatchingInput := False;
  end;
  if (FEmulation = nil) or FEmulation.IsPaused or FEmulationFaulted then
    Exit;
  var Input := CombinedGamepadInput;
  if (ssCtrl in Shift) then
    Input := Default(TEmulatorInput);
  FEmulation.SetGamepadInput(Input);
  UpdatePeripheralInput;
  var Peripheral: INesPeripheralCore;
  if Supports(FEmulation, INesPeripheralCore, Peripheral) then
  begin
    if Peripheral.Zapper.Enabled then
    begin
      var Mouse: IFMXMouseService;
      if TPlatformServices.Current.SupportsPlatformService(IFMXMouseService, Mouse) then
      begin
        var Point := ImageCanvas.AbsoluteToLocal(ScreenToClient(Mouse.GetMousePos));
        TryGetImagePixel(ImageCanvas, Point.X, Point.Y, FZapperPixel.X, FZapperPixel.Y);
      end;
      Peripheral.Zapper.TriggerPressed := FInput.IsPressed(ZapperTriggerAction);
    end;
  end;
end;

procedure TFormMain.ButtonCloseRomClick(Sender: TObject);
begin
  MobileCloseRom;
end;

procedure TFormMain.MobileCloseRom;
begin
  Stop;
  SwitchFullScreen;
end;

procedure TFormMain.ButtonOpenClick(Sender: TObject);
begin
  try
    OpenRom;
  except
    on E: Exception do
      ShowMessage(E.Message);
  end;
end;

procedure TFormMain.ButtonPaletteClick(Sender: TObject);
begin
  if FEmulation = nil then
    Exit;
  var GBEmulatorConfig: IGBEmulatorConfig;
  if Supports(FEmulation.Config, IGBEmulatorConfig, GBEmulatorConfig) then
  begin
    var CP := GBEmulatorConfig.ScreenPalette;
    Inc(CP);
    if CP >= SCREEN_PALETTE_COUNT then
      CP := 0;
    GBEmulatorConfig.ScreenPalette := CP;
    GBEmulatorConfig.Save;
  end;
end;

procedure TFormMain.ButtonSetRootClick(Sender: TObject);
begin
  if FOpeningRom then
    Exit;
  FOpeningRom := True;
  ButtonOpen.Enabled := False;
  FormDeactivate(Self);
  SyncActivity;
  var IsAlive: TFunc<Boolean> := FCallbackAlive;
  FStorage.SelectRomFolder(
    procedure(const Selection: TStorageSelection)
    begin
      if not IsAlive() then
        Exit;
      try
        try
          if Selection.Error <> '' then
            raise Exception.Create(Selection.Error);
          if not Selection.Cancelled then
            LoadSystem(FSystemId);
        except
          on E: Exception do
            ShowMessage(E.Message);
        end;
      finally
        FinishFileSelection;
      end;
    end);
end;

procedure TFormMain.ButtonStopClick(Sender: TObject);
begin
  Stop;
end;

procedure TFormMain.Stop;
begin
  FormDeactivate(Self);
  if FEmulation <> nil then
  begin
    TimerUpdate.Enabled := False;
    FEmulation.Stop;
    ImageCanvas.Bitmap := nil;
    ImageLogo.Visible := True;
    FEmulation := nil;
  end;
  SyncActivity;
end;

procedure TFormMain.ChangeSystem(Sender: TObject);
begin
  if FSettingsView <> nil then
    SettingsClose(Self);
  var SystemId := '';
  if RadioButtonGB.IsChecked then
    SystemId := RadioButtonGB.TagString
  else if RadioButtonGBC.IsChecked then
    SystemId := RadioButtonGBC.TagString
  else if RadioButtonNES.IsChecked then
    SystemId := RadioButtonNES.TagString
  else if RadioButtonMD.IsChecked then
    SystemId := RadioButtonMD.TagString
  else if RadioButtonSNES.IsChecked then
    SystemId := RadioButtonSNES.TagString
  else if RadioButtonNeoGeo.IsChecked then
    SystemId := RadioButtonNeoGeo.TagString;

  if FSystemId = SystemId then
    Exit;
  LoadSystem(SystemId);
end;

procedure TFormMain.Load;
begin
  var Ini := FStorage.ReadConfig(FStorage.ConfigFile('config'));
  try
    FControlBottomInset := EnsureRange(Ini.ReadInteger('General', 'ControlBottomInset', 100), 0, 400);
    ApplyControlInset;
    // Import the previously selected folder once.
    if FStorage.RomFolder = '' then
    begin
      var LegacyFolder := Ini.ReadString('General', 'Path', '');
      if LegacyFolder <> '' then
        FStorage.RomFolder := LegacyFolder;
    end;
  finally
    Ini.Free;
  end;
end;

procedure TFormMain.Save;
begin
  var Ini := FStorage.ReadConfig(FStorage.ConfigFile('config'));
  try
    Ini.WriteString('General', 'Path', FStorage.RomFolder);
    Ini.WriteInteger('General', 'ControlBottomInset', FControlBottomInset);
    FStorage.WriteConfig(Ini);
  finally
    Ini.Free;
  end;
end;

procedure TFormMain.LoadSystem(const SystemId: string);
begin
  FSystemId := SystemId;
  LayoutLeft.Enabled := False;
  ListBoxGames.Visible := False;
  ListBoxGames.BeginUpdate;
  try
    ListBoxGames.Clear;
    try
      var Folder := TPath.Combine(FStorage.RomFolder, SystemId);
      var Metadata := TGameList.Create;
      try
        var XMLPath := TPath.Combine(Folder, 'gamelist.xml');
        if not FStorage.RomFolder.StartsWith('content://') and FStorage.Exists(XMLPath) then
        begin
          var Input := FStorage.OpenRead(XMLPath);
          try
            Metadata.LoadFromStream(Input);
          finally
            Input.Free;
          end;
        end;
        ListBoxGames.DefaultItemStyles.ItemStyle := 'listboxitemstyle';
        ListBoxGames.ItemHeight := 32;
        if Metadata.Games.Count > 0 then
        begin
          ListBoxGames.DefaultItemStyles.ItemStyle := 'listboxitemstyle_game';
          ListBoxGames.ItemHeight := 70;
        end;
        for var FileInfo in FStorage.Roms(SystemId) do
        begin
          var Game := TGame.Create;
          try
            Game.Path := FileInfo.Location;
            Game.Name := TPath.GetFileNameWithoutExtension(FileInfo.Name);
            var DisplayGame := Game;
            for var Entry in Metadata.Games do
              if SameFileName(ExpandFileName(Entry.GetPhysicalPath(Folder, Entry.Path)),
                ExpandFileName(FileInfo.Location)) then
              begin
                DisplayGame := Entry;
                Break;
              end;
            var Item := TListBoxItemGame.Create(ListBoxGames);
            Item.RomFile := FileInfo;
            Item.Storage := FStorage;
            ListBoxGames.AddObject(Item);
            FillGameItem(Item, DisplayGame, Folder);
          finally
            Game.Free;
          end;
        end;
      finally
        Metadata.Free;
      end;
    except
      on E: Exception do
      begin
        ListBoxGames.Clear;
        SetStatus('Cannot load game list: ' + E.Message);
      end;
    end;
  finally
    ListBoxGames.EndUpdate;
    LayoutLeft.Enabled := True;
    ButtonSetRoot.Visible := ListBoxGames.Count <= 0;
    ListBoxGames.Visible := True;
  end;
end;

procedure TFormMain.FillGameItem(Item: TListBoxItem; Game: TGame; const Root: string);
begin
  var GameName: string := '';
  GameName := Game.Name;

  if Item.ItemData.Bitmap.IsEmpty then
    Item.ItemData.Bitmap := ImageNoBox.Bitmap;

  Item.ItemData.Detail := Game.Genre;
  Item.StylesData['info'] := Game.Developer;
  Item.StylesData['rating'] := Game.Rating;
  Item.StylesData['warn.Visible'] := False;
  Item.StylesData['favorite.Visible'] := Game.Favorite;
  Item.StylesData['box'] := Game.GetPhysicalPath(Root, Game.Box);
  Item.Text := GameName;
  Item.TagString := Game.GetPhysicalPath(Root, Game.Path);
end;

function TFormMain.CreateStorage: IStorage;
begin
  Result := TStorage.Create('', TStoragePicker.Create);
end;

function TFormMain.CreateHostInput: TInputManager;
begin
  {$IF Defined(MSWINDOWS) or (Defined(LINUX) and not Defined(ANDROID)) or (Defined(MACOS) and not Defined(IOS))}
  Result := TInputManager.Create(CreateFMXInputBackend);
  {$ELSE}
  Result := nil;
  {$ENDIF}
end;

function TFormMain.HostInputHasFocus: Boolean;
begin
  Result := Active;
end;

constructor TFormMain.Create(AOwner: TComponent);
begin
  FormStyles := TFormStyles.Create(Application);
  inherited;
  OnCloseQuery := FormCloseQuery;
  FStorage := CreateStorage;
  var Alive := True;
  FCallbackAlive :=
    function: Boolean
    begin
      Result := Alive;
    end;
  FInvalidateCallbacks :=
    procedure
    begin
      Alive := False;
    end;
  {$IF Defined(MSWINDOWS) or Defined(LINUX) or (Defined(MACOS) and not Defined(IOS))}
  {$IFNDEF ANDROID}
  FInput := CreateHostInput;
  {$ENDIF}
  {$ENDIF}
  var SettingsButton := TButton.Create(Self);
  SettingsButton.Name := 'ButtonSettings';
  SettingsButton.Parent := Layout2;
  SettingsButton.Align := TAlignLayout.Bottom;
  SettingsButton.Height := 64;
  SettingsButton.Text := '⚙';
  SettingsButton.Hint := 'Параметры';
  SettingsButton.ShowHint := True;
  SettingsButton.StyleLookup := 'buttonstyle_subtle';
  SettingsButton.OnClick := SettingsClick;
  var SettingsLabel := TLabel.Create(Self);
  SettingsLabel.Parent := SettingsButton;
  SettingsLabel.Align := TAlignLayout.Bottom;
  SettingsLabel.Height := 18;
  SettingsLabel.Text := 'Параметры';
  SettingsLabel.HitTest := False;
  SettingsLabel.TextSettings.HorzAlign := TTextAlign.Center;
  SettingsLabel.StyledSettings := SettingsLabel.StyledSettings - [TStyledSetting.Size];
  SettingsLabel.TextSettings.Font.Size := 10;
  FFileDialog := TFMXOpenDialog.Create(Self);
  FFileDialog.MultipleSelection := False;
  var ScreenshotButton := TButton.Create(Self);
  ScreenshotButton.Name := 'ButtonScreenshot';
  ScreenshotButton.Parent := LayoutHead;
  ScreenshotButton.Align := TAlignLayout.Right;
  ScreenshotButton.Width := 60;
  ScreenshotButton.Text := 'PNG';
  ScreenshotButton.Hint := 'Screenshot (F8)';
  ScreenshotButton.OnClick := ScreenshotClick;
  LayoutClient.CanFocus := True;
  LayoutClient.OnKeyDown := FormKeyDown;
  LayoutClient.OnKeyUp := FormKeyUp;
  LayoutClient.DisableFocusEffect := False;
  LayoutClient.CanParentFocus := True;
  SetStatus('Open ROM');
  {$IFDEF ANDROID}
  // Hardware volume keys control game audio, including before a ROM is loaded.
  TAndroidHelper.Activity.setVolumeControlStream(TJAudioManager.JavaClass.STREAM_MUSIC);
  FTransfer := TAndroidDocumentTransfer.Create(FStorage);
  FAppEvents := TApplicationEvents.Create(Self);
  FAppEvents.OnStateChanged := ApplicationStateChanged;
  LayoutClient.Visible := False;
  LayoutLeft.Align := TAlignLayout.Client;
  {$ENDIF}
  Fill.Color := TAlphaColors.Black;
  ImageCanvas.WrapMode := TImageWrapMode.Fit;
  ImageCanvas.DisableInterpolation := True;
  ImageCanvas.Bitmap.SetSize(NES_WIDTH, NES_HEIGHT);
  ImageCanvas.Bitmap.Clear(TAlphaColors.Black);
  FGamepad := TScreenGamepad.Create(Self);
  FGamepad.Name := 'ScreenGamepad';
  FGamepad.Parent := LayoutClient;
  FGamepad.Align := TAlignLayout.Bottom;
  FGamepad.OnChange := GamepadChanged;
  FGamepad.Enabled := False;
  FGamepad.Visible := False;
  FGamepad.Margins.Bottom := 100;
  FSuborKeyboard := TNesSuborKeyboard.Create(Self);
  FSuborKeyboard.Name := 'ScreenSuborKeyboard';
  FSuborKeyboard.Parent := LayoutClient;
  FSuborKeyboard.Align := TAlignLayout.Bottom;
  FSuborKeyboard.OnChange := SuborKeyboardChanged;
  FSuborKeyboard.OnPower := SuborKeyboardPower;
  FSuborKeyboard.OnReset := SuborKeyboardPower;
  FSuborKeyboard.Enabled := False;
  FSuborKeyboard.Visible := False;
  FFamicomKeyboard := TNesFamicomKeyboard.Create(Self);
  FFamicomKeyboard.Name := 'ScreenFamicomKeyboard';
  FFamicomKeyboard.Parent := LayoutClient;
  FFamicomKeyboard.Align := TAlignLayout.Bottom;
  FFamicomKeyboard.OnChange := FamicomKeyboardChanged;
  FFamicomKeyboard.Enabled := False;
  FFamicomKeyboard.Visible := False;
  FMiraclePiano := TNesMiraclePiano.Create(Self);
  FMiraclePiano.Name := 'ScreenMiraclePiano';
  FMiraclePiano.Parent := LayoutClient;
  FMiraclePiano.Align := TAlignLayout.Bottom;
  FMiraclePiano.OnChange := MiraclePianoChanged;
  FMiraclePiano.Enabled := False;
  FMiraclePiano.Visible := False;
  FPowerPad := TNesPowerPad.Create(Self);
  FPowerPad.Name := 'ScreenPowerPad';
  FPowerPad.Parent := LayoutClient;
  FPowerPad.Align := TAlignLayout.Bottom;
  FPowerPad.OnChange := PowerPadChanged;
  FPowerPad.Enabled := False;
  FPowerPad.Visible := False;
  FPowerPad.Margins.Bottom := 100;
  FDataRecorder := TNesDataRecorder.Create(Self);
  FDataRecorder.Name := 'ScreenDataRecorder';
  FDataRecorder.Parent := LayoutClient;
  FDataRecorder.Align := TAlignLayout.Bottom;
  FDataRecorder.OnAction := TapeAction;
  FDataRecorder.OnChooseFile := ChooseTapeFile;
  FDataRecorder.OnSaveAs := SaveTapeAs;
  FDataRecorder.Visible := False;
  FDataRecorder.Enabled := False;
  FormResize(Self);
  TimerUpdate.Interval := 8;
  ListBoxGames.Clear;
  Load;
  LoadSystem(ROM_SYSTEM_GB);
  LoadHostInput(ROM_SYSTEM_GB);
  SyncActivity;
end;

destructor TFormMain.Destroy;
begin
  if Assigned(FInvalidateCallbacks) then
    FInvalidateCallbacks();
  if TimerUpdate <> nil then
    TimerUpdate.Enabled := False;
  FreeAndNil(FSettingsView);
  FreeAndNil(FInput);
  FreeAndNil(FSuborKeyboard);
  FreeAndNil(FFamicomKeyboard);
  FreeAndNil(FMiraclePiano);
  FreeAndNil(FPowerPad);
  FreeAndNil(FDataRecorder);
  FreeAndNil(FGamepad); // Detach the native listener before destroying the form.
  {$IFDEF ANDROID}
  FreeAndNil(FAppEvents);
  FreeAndNil(FTransfer);
  {$ENDIF}
  if FEmulation <> nil then
  try
    FEmulation.Stop;
  except
    Application.HandleException(Self);
  end;
  FEmulation := nil;
  inherited;
end;

procedure TFormMain.FormActivate(Sender: TObject);
begin
  FSuppressInputUntilRelease := True;
  {$IFDEF ANDROID}
  if FMiraclePianoTouchAttached then
    FMiraclePiano.AttachToForm(Self)
  else if FPowerPadTouchAttached then
    FPowerPad.AttachToForm(Self)
  else if FSuborKeyboardTouchAttached then
    FSuborKeyboard.AttachToForm(Self)
  else if FFamicomKeyboardTouchAttached then
    FFamicomKeyboard.AttachToForm(Self)
  else if FGamepad <> nil then
    FGamepad.AttachToForm(Self);
  {$ENDIF}
  SyncActivity;
end;

procedure TFormMain.FormCreate(Sender: TObject);
begin
  RadioButtonNeoGeo.TagString := ROM_SYSTEM_NEOGEO;
  RadioButtonNeoGeo.StylesData['path.Data.Data'] := 'M13.8120002746582,35.951000213623 C7.50200033187866,35.951000213623 2.09899997711182,28.1060009002686 3.82600021362305,22.0359992980957 C5.55300045013428,15.9659976959229 11.4860000610352,12.0489988327026 ' +
    '24,12.0489988327026 C36.5139999389648,12.0489988327026 42.4469985961914,15.9659986495972 44.173999786377,22.0359992980957 C45.9010009765625,28.1059989929199 40.5,35.9500007629395 34.1879997253418,35.9500007629395 ' +
    'C29.9179992675781,35.9500007629395 31.2519989013672,34.9589996337891 24,34.9589996337891 C16.7480010986328,34.9589996337891 18.0820007324219,35.9500007629395 13.8120002746582,35.9500007629395 Z M17.1410007476807,' +
    '21.0249996185303 C17.1410007476807,23.1921653747559 15.384165763855,24.9489994049072 13.2170000076294,24.9489994049072 C11.0498342514038,24.9489994049072 9.29300022125244,23.1921653747559 9.29300022125244,' +
    '21.0249996185303 C9.29300022125244,18.8578338623047 11.0498342514038,17.1009998321533 13.2170000076294,17.1009998321533 C15.384165763855,17.1009998321533 17.1410007476807,18.8578338623047 17.1410007476807,' +
    '21.0249996185303 Z M15.293999671936,21.0249996185303 C15.293999671936,22.1720943450928 14.3640956878662,23.1019992828369 13.2170000076294,23.1019992828369 C12.0699043273926,23.1019992828369 11.1400003433228,' +
    '22.1720943450928 11.1400003433228,21.0249996185303 C11.1400003433228,19.8779048919678 12.0699043273926,18.9479999542236 13.2170000076294,18.9479999542236 C14.3640956878662,18.9479999542236 15.293999671936,' +
    '19.8779048919678 15.293999671936,21.0249996185303 Z M25.7089996337891,20.7080001831055 C25.7089996337891,21.497766494751 25.0687656402588,22.1380004882813 24.2789993286133,22.1380004882813 C23.4892330169678,' +
    '22.1380004882813 22.8489990234375,21.497766494751 22.8489990234375,20.7080001831055 C22.8489990234375,19.91823387146 23.4892330169678,19.2779998779297 24.2789993286133,19.2779998779297 C25.0687656402588,' +
    '19.2779998779297 25.7089996337891,19.91823387146 25.7089996337891,20.7080001831055 Z M30.1560001373291,14.2959995269775 C30.1560001373291,14.7102127075195 29.8202133178711,15.0459995269775 29.4060001373291,' +
    '15.0459995269775 C28.9917869567871,15.0459995269775 28.6560001373291,14.7102127075195 28.6560001373291,14.2959995269775 C28.6560001373291,13.8817863464355 28.9917869567871,13.5459995269775 29.4060001373291,' +
    '13.5459995269775 C29.8202133178711,13.5459995269775 30.1560001373291,13.8817863464355 30.1560001373291,14.2959995269775 Z M30.1200008392334,18.3090000152588 C30.1200008392334,19.0987663269043 29.4797668457031,' +
    '19.7390003204346 28.6900005340576,19.7390003204346 C27.9002342224121,19.7390003204346 27.2600002288818,19.0987663269043 27.2600002288818,18.3090000152588 C27.2600002288818,17.5192337036133 27.9002342224121,' +
    '16.878999710083 28.6900005340576,16.878999710083 C29.4797668457031,16.878999710083 30.1200008392334,17.5192337036133 30.1200008392334,18.3090000152588 Z M34.9960021972656,17.7399997711182 C34.9960021972656,' +
    '18.5297660827637 34.355770111084,19.1700000762939 33.5660018920898,19.1700000762939 C32.7762336730957,19.1700000762939 32.1360015869141,18.5297660827637 32.1360015869141,17.7399997711182 C32.1360015869141,' +
    '16.9502334594727 32.7762336730957,16.3099994659424 33.5660018920898,16.3099994659424 C34.355770111084,16.3099994659424 34.9960021972656,16.9502334594727 34.9960021972656,17.7399997711182 Z M39.6440010070801,' +
    '18.4200000762939 C39.6440010070801,19.2097663879395 39.0037689208984,19.8500003814697 38.2140007019043,19.8500003814697 C37.4242324829102,19.8500003814697 36.7840003967285,19.2097663879395 36.7840003967285,' +
    '18.4200000762939 C36.7840003967285,17.6302337646484 37.4242324829102,16.9899997711182 38.2140007019043,16.9899997711182 C39.0037689208984,16.9899997711182 39.6440010070801,17.6302337646484 39.6440010070801,' +
    '18.4200000762939 Z M22.2159996032715,34.992000579834 C22.8104496002197,34.9718551635742 23.4051876068115,34.9611930847168 23.9999809265137,34.9599990844727 C31.2519798278809,34.9599990844727 29.9179801940918,' +
    '35.951000213623 34.1879806518555,35.951000213623 C39.8879814147949,35.951000213623 44.8449783325195,29.5510005950928 44.4789810180664,23.8390007019043 C31.5089797973633,20.7190017700195 22.2159805297852,' +
    '23.9990005493164 22.2159805297852,34.992000579834 Z M25.7439994812012,16.6949996948242 C25.7439994812012,17.1092128753662 25.4082126617432,17.4449996948242 24.9939994812012,17.4449996948242 C24.5797863006592,' +
    '17.4449996948242 24.2439994812012,17.1092128753662 24.2439994812012,16.6949996948242 C24.2439994812012,16.2807865142822 24.5797863006592,15.9449996948242 24.9939994812012,15.9449996948242 C25.4082126617432,' +
    '15.9449996948242 25.7439994812012,16.2807865142822 25.7439994812012,16.6949996948242 Z ';

  RadioButtonGB.TagString := ROM_SYSTEM_GB;
  RadioButtonGB.StylesData['path.Data.Data'] := 'M17,2 L7,2 C6.00543832778931,2 5.05161094665527,2.39508819580078 4.34834957122803,3.09834957122803 C3.6450879573822,3.80161118507385 3.25,4.75543832778931 3.25,5.75000047683716 L3.25,18.25 C3.25,19.2445621490479 ' +
    '3.6450879573822,20.1983871459961 4.34834957122803,20.9016494750977 C5.05161094665527,21.6049098968506 6.00543832778931,22 7,22 L17,22 C19.0687866210938,21.9945049285889 20.7445049285889,20.3187866210938 ' +
    '20.75,18.25 L20.75,5.75 C20.7445125579834,3.681227684021 19.0688018798828,2.00550317764282 17.0000152587891,2 M10.2500152587891,16.6000003814697 L9.25001525878906,16.6000003814697 L9.25001525878906,17.6000003814697 ' +
    'C9.25001525878906,17.8679504394531 9.10706615447998,18.1155452728271 8.87501525878906,18.2495193481445 C8.64296436309814,18.3834934234619 8.35706615447998,18.3834934234619 8.12501525878906,18.2495193481445 ' +
    'C7.89296436309814,18.1155452728271 7.75001525878906,17.8679504394531 7.75001525878906,17.6000003814697 L7.75001525878906,16.6000003814697 L6.75001525878906,16.6000003814697 C6.48206615447998,16.6000003814697 ' +
    '6.2344708442688,16.4570503234863 6.10049629211426,16.2250003814697 C5.96652173995972,15.9929494857788 5.96652173995972,15.7070512771606 6.10049629211426,15.4750003814697 C6.2344708442688,15.2429494857788 ' +
    '6.48206615447998,15.1000003814697 6.75001525878906,15.1000003814697 L7.75001525878906,15.1000003814697 L7.75001525878906,14.1000003814697 C7.75001525878906,13.8320512771606 7.89296436309814,13.5844564437866 ' +
    '8.12501525878906,13.4504814147949 C8.35706615447998,13.3165073394775 8.64296436309814,13.3165073394775 8.87501525878906,13.4504814147949 C9.10706615447998,13.5844564437866 9.25001525878906,13.8320512771606 ' +
    '9.25001525878906,14.1000003814697 L9.25001525878906,15.1000003814697 L10.2500152587891,15.1000003814697 C10.5179643630981,15.1000003814697 10.7655591964722,15.2429494857788 10.8995342254639,15.4750003814697 ' +
    'C11.0335092544556,15.7070512771606 11.0335092544556,15.9929494857788 10.8995342254639,16.2250003814697 C10.7655591964722,16.4570503234863 10.5179643630981,16.6000003814697 10.2500152587891,16.6000003814697 ' +
    'M14,19.75 L12,19.75 C11.7320508956909,19.75 11.4844560623169,19.6070499420166 11.3504810333252,19.375 C11.2165060043335,19.1429500579834 11.2165060043335,18.8570499420166 11.3504810333252,18.625 C11.4844560623169,' +
    '18.3929500579834 11.7320508956909,18.25 12,18.25 L14,18.25 C14.2679491043091,18.25 14.5155439376831,18.3929500579834 14.6495189666748,18.625 C14.7834939956665,18.8570499420166 14.7834939956665,19.1429500579834 ' +
    '14.6495189666748,19.375 C14.5155439376831,19.6070499420166 14.2679491043091,19.75 14,19.75 M15.8800001144409,16.5 C15.8800001144409,16.7679500579834 15.7370510101318,17.0155448913574 15.5050001144409,17.1495189666748 ' +
    'C15.27294921875,17.2834930419922 14.9870510101318,17.2834930419922 14.7550001144409,17.1495189666748 C14.52294921875,17.0155448913574 14.3800001144409,16.7679500579834 14.3800001144409,16.5 L14.3800001144409,' +
    '16.1000003814697 C14.3800001144409,15.8320512771606 14.52294921875,15.5844564437866 14.7550001144409,15.4504814147949 C14.9870510101318,15.3165073394775 15.27294921875,15.3165073394775 15.5050001144409,' +
    '15.4504814147949 C15.7370510101318,15.5844564437866 15.8800001144409,15.8320512771606 15.8800001144409,16.1000003814697 Z M17.6499996185303,14.5 C17.6499996185303,14.7679491043091 17.5070495605469,15.0155439376831 ' +
    '17.2749996185303,15.1495189666748 C17.0429496765137,15.2834939956665 16.7570495605469,15.2834939956665 16.5249996185303,15.1495189666748 C16.2929496765137,15.0155439376831 16.1499996185303,14.7679491043091 ' +
    '16.1499996185303,14.5 L16.1499996185303,14.1000003814697 C16.1499996185303,13.8320512771606 16.2929496765137,13.5844564437866 16.5249996185303,13.4504814147949 C16.7570495605469,13.3165073394775 17.0429496765137,' +
    '13.3165073394775 17.2749996185303,13.4504814147949 C17.5070495605469,13.5844564437866 17.6499996185303,13.8320512771606 17.6499996185303,14.1000003814697 Z M18.25,10.0300006866455 C18.201473236084,10.9517374038696 ' +
    '17.4223861694336,11.6640472412109 16.5,11.6300010681152 L7.5,11.6300010681152 C6.57559823989868,11.6695623397827 5.793212890625,10.9542379379272 5.75,10.0299997329712 L5.75,5.73999977111816 C5.76818323135376,' +
    '5.29430103302002 5.96287298202515,4.87413167953491 6.2911491394043,4.57211780548096 C6.61942529678345,4.270103931427 7.05433464050293,4.11104297637939 7.50000047683716,4.13000011444092 L16.5,4.13000011444092 ' +
    'C17.4260921478271,4.09608936309814 18.2067527770996,4.81429624557495 18.25,5.73999977111816 Z ';

  RadioButtonGBC.TagString := ROM_SYSTEM_GBC;
  RadioButtonGBC.StylesData['path.Data.Data'] := 'M17,2 L7,2 C6.00543832778931,2 5.05161094665527,2.39508819580078 4.34834957122803,3.09834957122803 C3.6450879573822,3.80161118507385 3.25,4.75543832778931 3.25,5.75000047683716 L3.25,18.25 C3.25,19.2445621490479 ' +
    '3.6450879573822,20.1983871459961 4.34834957122803,20.9016494750977 C5.05161094665527,21.6049098968506 6.00543832778931,22 7,22 L17,22 C19.0687866210938,21.9945049285889 20.7445049285889,20.3187866210938 ' +
    '20.75,18.25 L20.75,5.75 C20.7445125579834,3.681227684021 19.0688018798828,2.00550317764282 17.0000152587891,2 M10.2500152587891,16.6000003814697 L9.25001525878906,16.6000003814697 L9.25001525878906,17.6000003814697 ' +
    'C9.25001525878906,17.8679504394531 9.10706615447998,18.1155452728271 8.87501525878906,18.2495193481445 C8.64296436309814,18.3834934234619 8.35706615447998,18.3834934234619 8.12501525878906,18.2495193481445 ' +
    'C7.89296436309814,18.1155452728271 7.75001525878906,17.8679504394531 7.75001525878906,17.6000003814697 L7.75001525878906,16.6000003814697 L6.75001525878906,16.6000003814697 C6.48206615447998,16.6000003814697 ' +
    '6.2344708442688,16.4570503234863 6.10049629211426,16.2250003814697 C5.96652173995972,15.9929494857788 5.96652173995972,15.7070512771606 6.10049629211426,15.4750003814697 C6.2344708442688,15.2429494857788 ' +
    '6.48206615447998,15.1000003814697 6.75001525878906,15.1000003814697 L7.75001525878906,15.1000003814697 L7.75001525878906,14.1000003814697 C7.75001525878906,13.8320512771606 7.89296436309814,13.5844564437866 ' +
    '8.12501525878906,13.4504814147949 C8.35706615447998,13.3165073394775 8.64296436309814,13.3165073394775 8.87501525878906,13.4504814147949 C9.10706615447998,13.5844564437866 9.25001525878906,13.8320512771606 ' +
    '9.25001525878906,14.1000003814697 L9.25001525878906,15.1000003814697 L10.2500152587891,15.1000003814697 C10.5179643630981,15.1000003814697 10.7655591964722,15.2429494857788 10.8995342254639,15.4750003814697 ' +
    'C11.0335092544556,15.7070512771606 11.0335092544556,15.9929494857788 10.8995342254639,16.2250003814697 C10.7655591964722,16.4570503234863 10.5179643630981,16.6000003814697 10.2500152587891,16.6000003814697 ' +
    'M14,19.75 L12,19.75 C11.7320508956909,19.75 11.4844560623169,19.6070499420166 11.3504810333252,19.375 C11.2165060043335,19.1429500579834 11.2165060043335,18.8570499420166 11.3504810333252,18.625 C11.4844560623169,' +
    '18.3929500579834 11.7320508956909,18.25 12,18.25 L14,18.25 C14.2679491043091,18.25 14.5155439376831,18.3929500579834 14.6495189666748,18.625 C14.7834939956665,18.8570499420166 14.7834939956665,19.1429500579834 ' +
    '14.6495189666748,19.375 C14.5155439376831,19.6070499420166 14.2679491043091,19.75 14,19.75 M15.8800001144409,16.5 C15.8800001144409,16.7679500579834 15.7370510101318,17.0155448913574 15.5050001144409,17.1495189666748 ' +
    'C15.27294921875,17.2834930419922 14.9870510101318,17.2834930419922 14.7550001144409,17.1495189666748 C14.52294921875,17.0155448913574 14.3800001144409,16.7679500579834 14.3800001144409,16.5 L14.3800001144409,' +
    '16.1000003814697 C14.3800001144409,15.8320512771606 14.52294921875,15.5844564437866 14.7550001144409,15.4504814147949 C14.9870510101318,15.3165073394775 15.27294921875,15.3165073394775 15.5050001144409,' +
    '15.4504814147949 C15.7370510101318,15.5844564437866 15.8800001144409,15.8320512771606 15.8800001144409,16.1000003814697 Z M17.6499996185303,14.5 C17.6499996185303,14.7679491043091 17.5070495605469,15.0155439376831 ' +
    '17.2749996185303,15.1495189666748 C17.0429496765137,15.2834939956665 16.7570495605469,15.2834939956665 16.5249996185303,15.1495189666748 C16.2929496765137,15.0155439376831 16.1499996185303,14.7679491043091 ' +
    '16.1499996185303,14.5 L16.1499996185303,14.1000003814697 C16.1499996185303,13.8320512771606 16.2929496765137,13.5844564437866 16.5249996185303,13.4504814147949 C16.7570495605469,13.3165073394775 17.0429496765137,' +
    '13.3165073394775 17.2749996185303,13.4504814147949 C17.5070495605469,13.5844564437866 17.6499996185303,13.8320512771606 17.6499996185303,14.1000003814697 Z M18.25,10.0300006866455 C18.201473236084,10.9517374038696 ' +
    '17.4223861694336,11.6640472412109 16.5,11.6300010681152 L7.5,11.6300010681152 C6.57559823989868,11.6695623397827 5.793212890625,10.9542379379272 5.75,10.0299997329712 L5.75,5.73999977111816 C5.76818323135376,' +
    '5.29430103302002 5.96287298202515,4.87413167953491 6.2911491394043,4.57211780548096 C6.61942529678345,4.270103931427 7.05433464050293,4.11104297637939 7.50000047683716,4.13000011444092 L16.5,4.13000011444092 ' +
    'C17.4260921478271,4.09608936309814 18.2067527770996,4.81429624557495 18.25,5.73999977111816 Z ';

  RadioButtonNES.TagString := ROM_SYSTEM_NES;
  RadioButtonNES.StylesData['path.Data.Data'] := 'M21,6 L3,6 C2.46956706047058,6 1.96085917949677,6.21071338653564 1.58578646183014,6.58578634262085 C1.21071362495422,6.96085929870605 0.999999940395355,7.469566822052 1,8 L1,16 C0.999999940395355,16.5304336547852 ' +
    '1.21071362495422,17.0391407012939 1.58578646183014,17.414213180542 C1.96085917949677,17.78928565979 2.46956706047058,18 3,18 L21,18 C21.5304336547852,18 22.0391407012939,17.78928565979 22.414213180542,' +
    '17.414213180542 C22.78928565979,17.0391407012939 23,16.5304336547852 23,16 L23,8 C23,7.469566822052 22.78928565979,6.96085929870605 22.414213180542,6.58578634262085 C22.0391407012939,6.21071338653564 21.5304336547852,' +
    '6 21,6 M11,13 L8,13 L8,16 L6,16 L6,13 L3,13 L3,11 L6,11 L6,8 L8,8 L8,11 L11,11 M15.5,15 C15.1021757125854,15 14.7206439971924,14.8419647216797 14.4393396377563,14.5606603622437 C14.1580352783203,14.2793560028076 ' +
    '14,13.8978252410889 14,13.5 C14,13.1021747589111 14.1580352783203,12.7206439971924 14.4393396377563,12.4393396377563 C14.7206439971924,12.1580352783203 15.1021757125854,12 15.5,12 C15.8978242874146,12 ' +
    '16.279354095459,12.1580352783203 16.5606594085693,12.4393396377563 C16.8419647216797,12.7206439971924 17,13.1021757125854 17,13.5 C17,13.8978242874146 16.8419647216797,14.2793560028076 16.5606594085693,' +
    '14.5606603622437 C16.279354095459,14.8419647216797 15.8978242874146,15 15.5,15 M19.5,12 C19.1021747589111,12 18.720645904541,11.8419647216797 18.4393405914307,11.5606603622437 C18.1580352783203,11.2793560028076 ' +
    '18,10.8978252410889 18,10.5 C18,10.1021747589111 18.1580352783203,9.72064399719238 18.4393405914307,9.43933963775635 C18.720645904541,9.15803527832031 19.1021747589111,9 19.5,9 C19.8978252410889,9 20.279354095459,' +
    '9.15803527832031 20.5606594085693,9.43933963775635 C20.8419647216797,9.72064399719238 21,10.1021757125854 21,10.5 C21,10.8978242874146 20.8419647216797,11.2793560028076 20.5606594085693,11.5606603622437 ' +
    'C20.279354095459,11.8419647216797 19.8978252410889,12 19.5,12 ';

  RadioButtonSNES.TagString := ROM_SYSTEM_SNES;
  RadioButtonSNES.StylesData['path.Data.Data'] :=
    'M7,6 L17,6 C21,6 23,8 23,12 C23,16 20,19 17,18 L13,16 L11,16 ' +
    'L7,18 C3,19 1,16 1,12 C1,8 3,6 7,6 Z M6,9 L6,11 L4,11 L4,13 ' +
    'L6,13 L6,15 L8,15 L8,13 L10,13 L10,11 L8,11 L8,9 Z ' +
    'M16,9 L18,11 L16,13 L14,11 Z M19,12 L21,14 L19,16 L17,14 Z';

  RadioButtonMD.TagString := ROM_FOLDER_MD;
  RadioButtonMD.StylesData['path.Data.Data'] := 'M10.0769996643066,10.9820003509521 L10.3039999008179,10.9820003509521 L10.3039999008179,11.0570001602173 L10.0260000228882,11.0570001602173 L10.0260000228882,10.7840003967285 L10.4139995574951,10.7840003967285 ' +
    'L10.5939998626709,10.66100025177 L9.98799991607666,10.66100025177 L9.80200004577637,10.7870006561279 L9.80200004577637,11.1800003051758 L10.3559999465942,11.1800003051758 L10.5270004272461,11.0640001296997 ' +
    'L10.5270004272461,10.8590002059937 L10.2580003738403,10.8590002059937 Z M11.8639993667603,10.8130006790161 L11.5899991989136,10.66100025177 L11.3629989624023,10.66100025177 L11.3629989624023,11.1800003051758 ' +
    'L11.5859985351563,11.1800003051758 L11.5859985351563,10.8340005874634 L11.8639984130859,11.0070009231567 L11.8639984130859,11.1800012588501 L12.0879983901978,11.1800012588501 L12.0879983901978,10.6610012054443 ' +
    'L11.8639984130859,10.6610012054443 Z M11.1309995651245,10.7840003967285 L11.3129997253418,10.66100025177 L10.7799997329712,10.66100025177 L10.585000038147,10.7810001373291 L10.585000038147,11.1800003051758 ' +
    'L11.1269998550415,11.1800003051758 L11.3099994659424,11.0570001602173 L10.8089990615845,11.0570001602173 L10.8089990615845,10.9820003509521 L11.0229988098145,10.9820003509521 L11.2049989700317,10.8590002059937 ' +
    'L10.8089990615845,10.8590002059937 L10.8089990615845,10.7840003967285 Z M12.3739995956421,11.0570001602173 L12.3739995956421,10.9820003509521 L12.5879993438721,10.9820003509521 L12.7709989547729,10.8590002059937 ' +
    'L12.3739986419678,10.8590002059937 L12.3739986419678,10.7840003967285 L12.6969985961914,10.7840003967285 L12.8779983520508,10.66100025177 L12.3449983596802,10.66100025177 L12.1509981155396,10.7810001373291 ' +
    'L12.1509981155396,11.1800003051758 L12.6929979324341,11.1800003051758 L12.875997543335,11.0570001602173 Z M14.5109996795654,10.7840003967285 L14.6929998397827,10.66100025177 L14.1440000534058,10.66100025177 ' +
    'L13.960000038147,10.7870006561279 L13.960000038147,10.9820003509521 L14.4580001831055,10.9820003509521 L14.4580001831055,11.0570001602173 L14.1360006332397,11.0570001602173 L13.9540004730225,11.1800003051758 ' +
    'L14.5040006637573,11.1800003051758 L14.6820011138916,11.0590000152588 L14.6820011138916,10.8590002059937 L14.1840009689331,10.8590002059937 L14.1840009689331,10.7840003967285 Z M13.6499996185303,10.66100025177 ' +
    'L13.8739995956421,10.66100025177 L13.8739995956421,11.1789999008179 L13.6499996185303,11.1789999008179 Z M13.4099998474121,10.7840003967285 L13.5920000076294,10.66100025177 L13.0419998168945,10.66100025177 ' +
    'L12.8590002059937,10.7870006561279 L12.8590002059937,10.9820003509521 L13.3570003509521,10.9820003509521 L13.3570003509521,11.0570001602173 L13.0350008010864,11.0570001602173 L12.8530006408691,11.1800003051758 ' +
    'L13.4020004272461,11.1800003051758 L13.581000328064,11.0590000152588 L13.581000328064,10.8590002059937 L13.0820007324219,10.8590002059937 L13.0820007324219,10.7840003967285 Z M21.2869987487793,11.1870002746582 ' +
    'C19.886999130249,9.14400005340576 16.3469982147217,7.80600023269653 12.644998550415,7.66400051116943 L12.6309986114502,7.62700033187866 C12.4309988021851,7.22700023651123 13.5449981689453,6.69500017166138 ' +
    '13.7439985275269,6.38100051879883 C14.0287218093872,5.95176649093628 14.0893898010254,5.41170835494995 13.9069986343384,4.93000030517578 C13.7189989089966,4.42000007629395 12.899998664856,4.64000034332275 ' +
    '13.0899982452393,5.15700054168701 C13.3849983215332,5.95800065994263 12.5609979629517,6.22900056838989 12.0969982147217,6.69400024414063 C11.8460340499878,6.94583988189697 11.7282285690308,7.30110740661621 ' +
    '11.778998374939,7.65300035476685 C7.92799854278564,7.70500040054321 4.16499853134155,9.06500053405762 2.71399879455566,11.1870002746582 C1.23399877548218,13.3520002365112 2.29699873924255,16.609001159668 ' +
    '3.70799875259399,18.0750007629395 C5.11899852752686,19.5410003662109 6.7579984664917,20.0530014038086 7.6159987449646,17.9530010223389 C8.36699867248535,16.1110000610352 11.7919988632202,16.0330009460449 ' +
    '11.9999980926514,16.0300006866455 C12.2079973220825,16.0270004272461 15.6329975128174,16.1110000610352 16.3849983215332,17.9530010223389 C17.2429981231689,20.0590019226074 18.8849983215332,19.5440006256104 ' +
    '20.2929992675781,18.0770015716553 C21.701000213623,16.6100025177002 22.7669982910156,13.3530015945435 21.2869987487793,11.1870021820068 M15.3859987258911,10.1140022277832 L16.9779987335205,9.40600204467773 ' +
    'C17.0810775756836,9.36058235168457 17.2005596160889,9.37361717224121 17.2914180755615,9.4401969909668 C17.3822765350342,9.50677680969238 17.4307041168213,9.61678028106689 17.4184474945068,9.72875308990479 ' +
    'C17.4061908721924,9.84072589874268 17.3351154327393,9.93764877319336 17.232006072998,9.98299789428711 L15.6370058059692,10.6909980773926 C15.4768304824829,10.7646837234497 15.2872295379639,10.6949243545532 ' +
    '15.2130060195923,10.5349979400635 C15.1778402328491,10.4567680358887 15.1778402328491,10.3672275543213 15.2130060195923,10.2889976501465 C15.2438678741455,10.2108755111694 15.3042087554932,10.1480207443237 ' +
    '15.3810062408447,10.1139974594116 Z M6.38599872589111,16.1340026855469 C5.05556488037109,16.1449451446533 3.85007357597351,15.3518257141113 3.33352565765381,14.1257123947144 C2.81697797775269,12.8996000289917 ' +
    '3.09152007102966,11.4829587936401 4.02870559692383,10.5385770797729 C4.96589136123657,9.59419536590576 6.3803915977478,9.30882453918457 7.61041975021362,9.81597995758057 C8.84044742584229,10.3231344223022 ' +
    '9.6427640914917,11.5225229263306 9.64199829101563,12.8530015945435 C9.6447868347168,14.6591386795044 8.18519020080566,16.1268177032471 6.37903165817261,16.1340007781982 Z M9.82499885559082,11.334002494812 ' +
    'L9.48199844360352,11.1340026855469 L9.48199844360352,10.6890029907227 L9.80399799346924,10.5010032653809 L11.3879976272583,10.5010032653809 L11.6749973297119,10.0890035629272 L12.8289976119995,10.0890035629272 ' +
    'L13.1179971694946,10.5010032653809 L14.7259969711304,10.5010032653809 L15.0499973297119,10.6900033950806 L15.0499973297119,11.1300029754639 L14.7069969177246,11.330002784729 Z M20.1659984588623,13.753002166748 ' +
    'C19.4279975891113,14.0200023651123 18.1349983215332,14.6480026245117 18.121997833252,14.6530017852783 C18.0309982299805,14.6920013427734 17.7439975738525,14.8530015945435 17.4119987487793,15.048002243042 ' +
    'C17.0359992980957,15.2630023956299 16.5679988861084,15.5320024490356 16.2249984741211,15.709002494812 C16.0065135955811,15.8141279220581 15.7664155960083,15.8665313720703 15.523998260498,15.8620023727417 ' +
    'C14.5134525299072,15.8751525878906 13.6773157119751,15.0789813995361 13.6409969329834,14.0690031051636 C13.4769973754883,12.3810033798218 16.391996383667,10.947003364563 16.5159969329834,10.8870029449463 ' +
    'C18.4849967956543,9.99700260162354 19.9359970092773,10.0410032272339 20.7759971618652,11.0000028610229 C21.1989212036133,11.4062938690186 21.3809757232666,12.0027961730957 21.2569980621338,12.576003074646 ' +
    'C21.0994396209717,13.1185159683228 20.6950225830078,13.5548124313354 20.1659984588623,13.7530031204224 M17.6299991607666,12.1090030670166 C17.3240928649902,12.1069774627686 17.0471973419189,12.2897462844849 ' +
    '16.9288196563721,12.5718269348145 C16.8104419708252,12.853907585144 16.8739776611328,13.1795425415039 17.0897159576416,13.3964309692383 C17.3054542541504,13.6133193969727 17.630744934082,13.6785888671875 ' +
    '17.9134521484375,13.5617122650146 C18.196159362793,13.4448356628418 18.3803977966309,13.1689167022705 18.3799991607666,12.8630037307739 C18.3810653686523,12.6634035110474 18.3025188446045,12.4716081619263 ' +
    '18.161750793457,12.3300886154175 C18.0209827423096,12.1885690689087 17.829610824585,12.1090021133423 17.6300029754639,12.1090040206909 M18.97900390625,10.4590044021606 C18.1540203094482,10.5005197525024 ' +
    '17.346492767334,10.7119340896606 16.6070022583008,11.080005645752 C16.5800018310547,11.0930051803589 13.7060022354126,12.5080051422119 13.8530025482178,14.0480060577393 C13.885461807251,14.9463510513306 ' +
    '14.6271057128906,15.6556329727173 15.5260038375854,15.648006439209 C15.7335920333862,15.6517934799194 15.9392557144165,15.6076498031616 16.1270046234131,15.519006729126 C16.4660053253174,15.3440065383911 ' +
    '16.9270038604736,15.0760068893433 17.3060054779053,14.8620071411133 C17.6580047607422,14.6620073318481 17.9360046386719,14.5000076293945 18.0340061187744,14.462007522583 C18.0420055389404,14.4570074081421 ' +
    '19.345006942749,13.8240070343018 20.0930061340332,13.5530071258545 C20.556957244873,13.3810710906982 20.912712097168,13.0004873275757 21.0530052185059,12.5260066986084 C21.1513633728027,12.0210990905762 ' +
    '20.9876804351807,11.5007009506226 20.6180038452148,11.1430063247681 C20.2013607025146,10.6815013885498 19.6001091003418,10.4305820465088 18.97900390625,10.4590072631836 M15.6870040893555,14.9010066986084 ' +
    'C15.2949476242065,14.9034366607666 14.9401416778564,14.6691389083862 14.7884216308594,14.3076210021973 C14.6367015838623,13.9461030960083 14.7180309295654,13.5287685394287 14.9943990707397,13.2506771087646 ' +
    'C15.2707672119141,12.9725856781006 15.6875867843628,12.8886623382568 16.0500411987305,13.0381317138672 C16.4124946594238,13.1876010894775 16.6489963531494,13.5409421920776 16.6490039825439,13.9330062866211 ' +
    'C16.6497993469238,14.1889476776123 16.5488929748535,14.4347143173218 16.368480682373,14.6162490844727 C16.1880683898926,14.7977838516235 15.9429321289063,14.9002141952515 15.6869974136353,14.9010066986084 ' +
    'M17.629997253418,13.8310070037842 C17.2379417419434,13.8334369659424 16.8831348419189,13.599139213562 16.7314147949219,13.237621307373 C16.5796947479248,12.8761034011841 16.6610260009766,12.4587688446045 ' +
    '16.9373931884766,12.1806774139404 C17.2137603759766,11.9025859832764 17.6305809020996,11.8186626434326 17.993034362793,11.968132019043 C18.3554878234863,12.1176013946533 18.5919895172119,12.4709424972534 ' +
    '18.5919971466064,12.8630065917969 C18.5927925109863,13.1189479827881 18.491886138916,13.3647146224976 18.3114738464355,13.5462493896484 C18.1310615539551,13.7277841567993 17.8859252929688,13.8302145004272 ' +
    '17.6299915313721,13.8310070037842 M19.6659908294678,12.9460067749023 C19.2737560272217,12.9488430023193 18.9185810089111,12.714695930481 18.7666034698486,12.3530893325806 C18.6146259307861,11.9914827346802 ' +
    '18.6958904266357,11.5739068984985 18.9723854064941,11.2956857681274 C19.2488803863525,11.0174646377563 19.6659412384033,10.9336032867432 20.0284862518311,11.083327293396 C20.3910312652588,11.2330513000488 ' +
    '20.6273860931396,11.5867614746094 20.6269912719727,11.9790067672729 C20.6280937194824,12.5111932754517 20.1981544494629,12.9438076019287 19.6659812927246,12.9460067749023 M5.91499996185303,14.5530004501343 ' +
    'L5.91499996185303,13.3030004501343 L4.68599987030029,13.3150005340576 C4.85151767730713,13.9138841629028 5.31733989715576,14.3831176757813 5.91499996185303,14.5530004501343 M19.6660003662109,11.2240009307861 ' +
    'C19.3600978851318,11.2215700149536 19.0829601287842,11.4039707183838 18.9642086029053,11.6858940124512 C18.8454570770264,11.9678173065186 18.908561706543,12.2935342788696 19.1240100860596,12.5107088088989 ' +
    'C19.3394584655762,12.7278833389282 19.6646633148193,12.7935857772827 19.9475250244141,12.6770858764648 C20.2303867340088,12.5605869293213 20.4149913787842,12.2849140167236 20.4150009155273,11.9790010452271 ' +
    'C20.4161109924316,11.5639114379883 20.0810928344727,11.2262058258057 19.6660041809082,11.2240009307861 M15.6870040893555,13.1790008544922 C15.3811855316162,13.1773805618286 15.1045961380005,13.360408782959 ' +
    '14.986533164978,13.642523765564 C14.8684701919556,13.9246387481689 14.9322566986084,14.2501106262207 15.1480751037598,14.4667911529541 C15.3638935089111,14.6834716796875 15.6891088485718,14.7485551834106 ' +
    '15.9716920852661,14.6316184997559 C16.2542762756348,14.5146818161011 16.438404083252,14.2388229370117 16.4380035400391,13.9330005645752 C16.4385585784912,13.5175247192383 16.1024875640869,13.1801061630249 ' +
    '15.6870079040527,13.1790008544922 M15.5490083694458,10.4970006942749 L17.1380081176758,9.78800106048584 C17.1930923461914,9.76573657989502 17.2205410003662,9.70375347137451 17.200008392334,9.64800071716309 ' +
    'C17.1823596954346,9.60940742492676 17.1422710418701,9.58615684509277 17.1000080108643,9.59000110626221 C17.0830917358398,9.58913040161133 17.0662307739258,9.59257125854492 17.0510082244873,9.60000133514404 ' +
    'L15.4580078125,10.3080015182495 C15.4300775527954,10.3203477859497 15.4079055786133,10.3428773880005 15.3960075378418,10.3710012435913 C15.3854494094849,10.3959293365479 15.3854494094849,10.4240732192993 ' +
    '15.3960075378418,10.4490013122559 C15.4092197418213,10.4763450622559 15.4331483840942,10.4970092773438 15.4621238708496,10.5060997009277 C15.491099357605,10.5151901245117 15.5225439071655,10.5118970870972 ' +
    '15.5490074157715,10.4970016479492 M6.84400749206543,11.1470012664795 L6.84400749206543,12.3980016708374 L8.07300758361816,12.3850021362305 C7.90748977661133,11.7861185073853 7.4416675567627,11.3168840408325 ' +
    '6.84400749206543,11.1470012664795 M6.83000755310059,12.5970010757446 C6.71955060958862,12.5970010757446 6.63000774383545,12.5074577331543 6.63000774383545,12.3970012664795 L6.63000774383545,11.1030015945435 ' +
    'C6.46425199508667,11.0783576965332 6.29576349258423,11.0783576965332 6.13000774383545,11.1030015945435 L6.13000774383545,12.4030017852783 C6.13000774383545,12.5134582519531 6.04046535491943,12.6030015945435 ' +
    '5.93000841140747,12.6030015945435 L4.64200019836426,12.6030015945435 C4.61788988113403,12.7718114852905 4.61789035797119,12.9431915283203 4.64200019836426,13.1120014190674 L5.92899990081787,13.1120014190674 ' +
    'C6.03945684432983,13.1120014190674 6.12899971008301,13.2015447616577 6.12899971008301,13.3120012283325 L6.12899971008301,14.6120014190674 C6.29485511779785,14.6352624893188 6.46314477920532,14.6352624893188 ' +
    '6.62900018692017,14.6120014190674 L6.62900018692017,13.3050012588501 C6.62900018692017,13.1945447921753 6.71854257583618,13.105001449585 6.82899951934814,13.105001449585 L8.11699962615967,13.105001449585 ' +
    'C8.14110946655273,12.9361925125122 8.14110946655273,12.7648124694824 8.11699962615967,12.5960025787354 Z M5.91500759124756,11.1470012664795 C5.31759738922119,11.3166999816895 4.85182666778564,11.7855014801025 ' +
    '4.68600749969482,12.3840007781982 L5.91500759124756,12.3840007781982 Z M6.37900733947754,9.78100109100342 C5.13579034805298,9.77330684661865 4.01066732406616,10.5161743164063 3.52938151359558,11.6624774932861 ' +
    'C3.04809546470642,12.808780670166 3.30567455291748,14.1321887969971 4.18175840377808,15.0143022537231 C5.05784225463867,15.8964157104492 6.37945175170898,16.1630668640137 7.52902936935425,15.6896553039551 ' +
    'C8.67860698699951,15.2162437438965 9.42917442321777,14.0962419509888 9.43000793457031,12.8530015945435 C9.43445205688477,11.1627740859985 8.06928539276123,9.78818416595459 6.37903738021851,9.78100204467773 ' +
    'M3.81303739547729,13.0530023574829 L3.33003735542297,12.8530025482178 L3.81303739547729,12.6470022201538 Z M6.37903738021851,9.78300285339355 L6.58403730392456,10.2680025100708 L6.1750373840332,10.2680025100708 ' +
    'Z M6.37903738021851,15.9200029373169 L6.17903757095337,15.4340028762817 L6.58803749084473,15.4340028762817 Z M8.33703708648682,13.1060028076172 L8.31303691864014,13.2320032119751 L8.29603672027588,13.3190031051636 ' +
    'L8.28603649139404,13.3190031051636 C8.11624336242676,14.0354280471802 7.55927085876465,14.5962629318237 6.84403705596924,14.7710027694702 L6.84403705596924,14.7770023345947 L6.76003694534302,14.794002532959 ' +
    'L6.63403701782227,14.8190021514893 L6.63403701782227,14.8130025863647 C6.55016946792603,14.8243494033813 6.4656662940979,14.830361366272 6.38103723526001,14.8310022354126 C6.29674243927002,14.8303194046021 ' +
    '6.21257448196411,14.8243074417114 6.12903785705566,14.8130025863647 L6.12903785705566,14.8190021514893 L6.00303792953491,14.794002532959 L5.92003774642944,14.7770023345947 L5.92003774642944,14.7710027694702 ' +
    'C5.20441770553589,14.5965909957886 4.64699649810791,14.0356941223145 4.47703742980957,13.3190031051636 L4.46503734588623,13.3190031051636 L4.44903755187988,13.2320032119751 L4.42403745651245,13.1060028076172 ' +
    'L4.43003749847412,13.1060028076172 C4.4059271812439,12.9371938705444 4.40592765808105,12.7658138275146 4.43003749847412,12.5970039367676 L4.42403745651245,12.5970039367676 L4.44903755187988,12.4700040817261 ' +
    'L4.46503734588623,12.3840036392212 L4.47203731536865,12.3840036392212 C4.64199638366699,11.6673126220703 5.19941759109497,11.1064157485962 5.91503763198853,10.9320039749146 L5.91503763198853,10.9250040054321 ' +
    'L6,10.9079999923706 L6.1269998550415,10.8839998245239 L6.1269998550415,10.8899993896484 C6.29301023483276,10.8690843582153 6.46098947525024,10.8690843582153 6.6269998550415,10.8899993896484 L6.6269998550415,' +
    '10.8839998245239 L6.75299978256226,10.9079999923706 L6.83899974822998,10.9250001907349 L6.83899974822998,10.9320001602173 C7.5565505027771,11.1047668457031 8.11621284484863,11.6659746170044 8.28699970245361,' +
    '12.3839998245239 L8.29299926757813,12.3839998245239 L8.30999946594238,12.4700002670288 L8.33399963378906,12.5970001220703 L8.32800006866455,12.5970001220703 C8.35354423522949,12.7657051086426 8.35354423522949,' +
    '12.9372940063477 8.32800006866455,13.1059989929199 Z M8.94903755187988,12.6450023651123 L9.43103790283203,12.8510026931763 L8.94903755187988,13.0570030212402 Z M6.84203720092773,14.5530023574829 C7.43983268737793,' +
    '14.3836040496826 7.90603351593018,13.9147500991821 8.07203674316406,13.3160028457642 L6.82999992370605,13.3160028457642 Z ';
end;

procedure TFormMain.FormResize(Sender: TObject);
begin
  if FMiraclePiano <> nil then
    FMiraclePiano.Height := TNesMiraclePiano.PreferredHeight(LayoutClient.Width,
      ClientHeight - Padding.Top - Padding.Bottom - LayoutHead.Height);
  if FDataRecorder <> nil then
    FDataRecorder.Height := TNesDataRecorder.PreferredHeight(LayoutClient.Width,
      ClientHeight - Padding.Top - Padding.Bottom - LayoutHead.Height);
  if FPowerPad <> nil then
    FPowerPad.Height := TNesPowerPad.PreferredHeight(LayoutClient.Width,
      ClientHeight - Padding.Top - Padding.Bottom - LayoutHead.Height);
  if FGamepad <> nil then
  begin
    FGamepad.Height := TScreenGamepad.PreferredHeight(
      ClientWidth - Padding.Left - Padding.Right,
      ClientHeight - Padding.Top - Padding.Bottom - LayoutHead.Height);
  end;
  if FSuborKeyboard <> nil then
  begin
    FSuborKeyboard.Height := TNesSuborKeyboard.PreferredHeight(
      ClientWidth - Padding.Left - Padding.Right,
      ClientHeight - Padding.Top - Padding.Bottom - LayoutHead.Height);
  end;
  if FFamicomKeyboard <> nil then
    FFamicomKeyboard.Height := TNesFamicomKeyboard.PreferredHeight(
      ClientWidth - Padding.Left - Padding.Right,
      ClientHeight - Padding.Top - Padding.Bottom - LayoutHead.Height);
end;

procedure TFormMain.TapeAction(Sender: TObject; Action: TTapeAction; const FileName: string);
begin
  var Tape: INesTapeCore;
  if not Supports(FEmulation, INesTapeCore, Tape) then
    Exit;
  try
    Tape.TapeCommand(Action, FileName);
    FDataRecorder.Progress := Tape.GetTapeProgress;
  except
    on E: Exception do
      ShowMessage('Cassette: ' + E.Message);
  end;
end;

procedure TFormMain.SelectTapeFile(const FileName: string);
begin
  var Tape: INesTapeCore;
  if not Supports(FEmulation, INesTapeCore, Tape) or not Tape.UsesDataRecorder then
    raise EInvalidOperation.Create('No data recorder connected');
  Tape.TapeCommand(TapeSelectFile, FileName);
  FDataRecorder.Progress := Tape.GetTapeProgress;
end;

procedure TFormMain.ChooseTapeFile(Sender: TObject);
begin
  SelectDocument(True);
end;

procedure TFormMain.SaveTapeAs(Sender: TObject);
begin
  var Tape: INesTapeCore;
  if not Supports(FEmulation, INesTapeCore, Tape) or not Tape.UsesDataRecorder then
    Exit;
  FormDeactivate(Self);
  {$IFDEF ANDROID}
  if FOpeningRom then
    Exit;
  var Path := FStorage.TemporaryFile('.tape');
  try
    Tape.TapeCommand(TapeSaveAs, Path);
    FTransfer.Save(Path, ExtractFileName(Tape.GetTapeProgress.FileName));
    FOpeningRom := True;
    ButtonOpen.Enabled := False;
    SyncActivity;
  except
    on E: Exception do
    begin
      FStorage.Delete(Path);
      ShowMessage('Cassette: ' + E.Message);
    end;
  end;
  {$ELSE}
  var Dialog := TSaveDialog.Create(Self);
  try
    Dialog.Title := 'Save cassette as';
    Dialog.Filter := 'Cassette (*.tape)|*.tape';
    Dialog.DefaultExt := 'tape';
    Dialog.Options := [TOpenOption.ofPathMustExist, TOpenOption.ofOverwritePrompt];
    Dialog.FileName := Tape.GetTapeProgress.FileName;
    if Dialog.Execute then
    try
      Tape.TapeCommand(TapeSaveAs, Dialog.FileName);
      FDataRecorder.Progress := Tape.GetTapeProgress;
    except
      on E: Exception do
        ShowMessage('Cassette: ' + E.Message);
    end;
  finally
    Dialog.Free;
    FormActivate(Self);
  end;
  {$ENDIF}
end;

procedure TFormMain.GamepadChanged(Sender: TObject);
begin
  FGamepadInput.Buttons := FGamepad.Buttons;
  if FEmulation <> nil then
    FEmulation.SetGamepadInput(CombinedGamepadInput);
end;

function TFormMain.CombinedGamepadInput: TEmulatorInput;
const
  Mapping: array[TNesButton] of TEmulatorButton = (TEmulatorButton.A,
    TEmulatorButton.B, TEmulatorButton.Select, TEmulatorButton.Start,
    TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left, TEmulatorButton.Right);
begin
  Result := FGamepadInput;
  if FInput <> nil then
  begin
    var Host := ReadPadInput(FInput, FInputPorts);
    Result.Buttons := Result.Buttons + Host.Buttons;
    Result.Buttons2 := Host.Buttons2;
    Result.Buttons3 := Host.Buttons3;
    Result.Buttons4 := Host.Buttons4;
    Result.Buttons5 := Host.Buttons5;
    Result.Buttons6 := Host.Buttons6;
    Result.Buttons7 := Host.Buttons7;
    Result.Buttons8 := Host.Buttons8;
  end;
  if FInputPorts.Devices[0] = 'none' then
    Result.Buttons := [];
  var Piano: INesMiraclePianoCore;
  if Supports(FEmulation, INesMiraclePianoCore, Piano) and Piano.UsesMiraclePiano then
  begin
    for var Button in FMiraclePiano.Buttons do
      Include(Result.Buttons, Mapping[Button]);
    if FInput <> nil then
      for var Button := Low(TNesButton) to High(TNesButton) do
        if FInput.IsPressed(PadAction(0, Mapping[Button])) then
          Include(Result.Buttons, Mapping[Button]);
  end;
end;

procedure TFormMain.UpdatePeripheralInput;
begin
  var Peripheral: INesPeripheralCore;
  if Supports(FEmulation, INesPeripheralCore, Peripheral) then
  begin
    if FEmulation.UsesSuborKeyboard then
      Peripheral.SetSuborKeys(FSuborKeyboard.Keys + ReadSuborInput(FInput));
    if Peripheral.UsesFamicomKeyboard then
      Peripheral.SetFamicomKeys(FFamicomKeyboard.Keys + ReadFamicomInput(FInput));
    if Peripheral.UsesPowerPad then
    begin
      var Buttons := FPowerPad.Buttons;
      if FInput <> nil then
        for var i := 0 to 11 do
          if FInput.IsPressed(PowerPadAction + i) then
            Include(Buttons, i + 1);
      Peripheral.SetPowerPadButtons(Buttons);
    end;
  end;
  var Piano: INesMiraclePianoCore;
  if Supports(FEmulation, INesMiraclePianoCore, Piano) and Piano.UsesMiraclePiano then
    Piano.SetMiracleKeys(FMiraclePiano.Keys + ReadPianoInput(FInput));
end;

procedure TFormMain.ImageCanvasMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Single);
begin
  if (FInput <> nil) or (Button <> TMouseButton.mbLeft) then
    Exit;
  var Peripheral: INesPeripheralCore;
  if Supports(FEmulation, INesPeripheralCore, Peripheral) then
  begin
    TryGetImagePixel(ImageCanvas, X, Y, FZapperPixel.X, FZapperPixel.Y);
    Peripheral.Zapper.TriggerPressed := True;
  end;
end;

procedure TFormMain.ImageCanvasMouseUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Single);
begin
  if (FInput <> nil) or (Button <> TMouseButton.mbLeft) then
    Exit;
  var Peripheral: INesPeripheralCore;
  if Supports(FEmulation, INesPeripheralCore, Peripheral) then
  begin
    Peripheral.Zapper.TriggerPressed := False;
  end;
end;

procedure TFormMain.ForwardKeyState(Code: Word; Pressed: Boolean);
begin
  if FEmulation = nil then
    Exit;
  {$IFDEF MSWINDOWS}
  // Windows FMX reports generic Shift. HVC-007 has two separate contacts.
  var Peripheral: INesPeripheralCore;
  if (FInput = nil) and (Code = vkShift) and Supports(FEmulation, INesPeripheralCore, Peripheral) and Peripheral.UsesFamicomKeyboard then
  begin
    FEmulation.SetKeyState(vkLShift, Winapi.Windows.GetKeyState(vkLShift) < 0);
    FEmulation.SetKeyState(vkRShift, Winapi.Windows.GetKeyState(vkRShift) < 0);
    Exit;
  end;
  {$ENDIF}
  FEmulation.SetKeyState(Code, Pressed);
end;

procedure TFormMain.MiraclePianoChanged(Sender: TObject);
begin
  var Piano: INesMiraclePianoCore;
  if not Supports(FEmulation, INesMiraclePianoCore, Piano) or not Piano.UsesMiraclePiano then
    Exit;
  UpdatePeripheralInput;
  FEmulation.SetGamepadInput(CombinedGamepadInput);
end;

procedure TFormMain.FamicomKeyboardChanged(Sender: TObject);
begin
  UpdatePeripheralInput;
end;

procedure TFormMain.SuborKeyboardChanged(Sender: TObject);
begin
  UpdatePeripheralInput;
end;

procedure TFormMain.SuborKeyboardPower(Sender: TObject);
begin
  if (FEmulation = nil) or FEmulationFaulted then
    Exit;
  try
    FEmulation.Reset;
  except
    StopOnError;
    raise;
  end;
end;

procedure TFormMain.PowerPadChanged(Sender: TObject);
begin
  UpdatePeripheralInput;
end;

procedure TFormMain.SetStatus(const Text: string);
begin
  Caption := AppName + ' - ' + Text;
  {$IFDEF ANDROID}
  LabelStatus.Text := Caption;
  {$ELSE}
  LayoutHead.Visible := False;
  {$ENDIF}
end;

procedure TFormMain.SyncActivity;
begin
  var Tape: INesTapeCore;
  if FDataRecorder <> nil then
  begin
    FDataRecorder.Visible := Supports(FEmulation, INesTapeCore, Tape) and Tape.UsesDataRecorder;
    FDataRecorder.Enabled := FDataRecorder.Visible and not FOpeningRom and not FEmulationFaulted;
    if FDataRecorder.Visible then
      FDataRecorder.Progress := Tape.GetTapeProgress;
  end;
  var SuborKeyboardActive := (FEmulation <> nil) and FEmulation.UsesSuborKeyboard;
  var Peripheral: INesPeripheralCore;
  var FamicomKeyboardActive := Supports(FEmulation, INesPeripheralCore, Peripheral) and
    Peripheral.UsesFamicomKeyboard;
  var Piano: INesMiraclePianoCore;
  var PianoActive := Supports(FEmulation, INesMiraclePianoCore, Piano) and Piano.UsesMiraclePiano;
  if FMiraclePiano <> nil then
  begin
    FMiraclePiano.Visible := PianoActive;
    FMiraclePiano.Enabled := PianoActive and not FEmulationFaulted and not FOpeningRom;
  end;
  {$IFDEF ANDROID}
  var KeyboardActive := SuborKeyboardActive or FamicomKeyboardActive or PianoActive;
  var PowerPadActive := Supports(FEmulation, INesPeripheralCore, Peripheral);
  if PowerPadActive then
    PowerPadActive := Peripheral.UsesPowerPad and not KeyboardActive;
  {$ENDIF}
  if FGamepad <> nil then
  begin
    {$IFDEF ANDROID}
    FGamepad.Visible := not KeyboardActive and not PowerPadActive;
    FGamepad.Enabled := (FEmulation <> nil) and not FEmulationFaulted and not FOpeningRom and not KeyboardActive and not PowerPadActive;
    {$ENDIF}
  end;
  if FSuborKeyboard <> nil then
  begin
    FSuborKeyboard.Visible := SuborKeyboardActive;
    FSuborKeyboard.Enabled := SuborKeyboardActive and not FEmulationFaulted and not FOpeningRom;
  end;
  if FFamicomKeyboard <> nil then
  begin
    FFamicomKeyboard.Visible := FamicomKeyboardActive;
    FFamicomKeyboard.Enabled := FamicomKeyboardActive and not FEmulationFaulted and not FOpeningRom;
  end;

  if FPowerPad <> nil then
  begin
    {$IFDEF ANDROID}
    FPowerPad.Visible := PowerPadActive;
    FPowerPad.Enabled := PowerPadActive and not FEmulationFaulted and not FOpeningRom;
    {$ENDIF}
  end;

  {$IFDEF ANDROID}
  // The Android view accepts one native touch listener.
  // The controls are mutually exclusive, so hand it to the currently visible control.
  if (FSuborKeyboardTouchAttached <> SuborKeyboardActive) or
    (FFamicomKeyboardTouchAttached <> FamicomKeyboardActive) or
    (FPowerPadTouchAttached <> PowerPadActive) or
    (FMiraclePianoTouchAttached <> PianoActive) then
  begin
    if FMiraclePianoTouchAttached then
      FMiraclePiano.AttachToForm(nil)
    else if FPowerPadTouchAttached then
      FPowerPad.AttachToForm(nil)
    else if FSuborKeyboardTouchAttached then
      FSuborKeyboard.AttachToForm(nil)
    else if FFamicomKeyboardTouchAttached then
      FFamicomKeyboard.AttachToForm(nil)
    else
      FGamepad.AttachToForm(nil);
    if PianoActive then
      FMiraclePiano.AttachToForm(Self)
    else if PowerPadActive then
      FPowerPad.AttachToForm(Self)
    else if SuborKeyboardActive then
      FSuborKeyboard.AttachToForm(Self)
    else if FamicomKeyboardActive then
      FFamicomKeyboard.AttachToForm(Self)
    else
      FGamepad.AttachToForm(Self);
    FSuborKeyboardTouchAttached := SuborKeyboardActive;
    FFamicomKeyboardTouchAttached := FamicomKeyboardActive;
    FPowerPadTouchAttached := PowerPadActive;
    FMiraclePianoTouchAttached := PianoActive;
  end;
  if FMiraclePiano <> nil then
    FMiraclePiano.Enabled := FMiraclePiano.Enabled and not FInBackground;
  var Paused := FInBackground or FOpeningRom or FUserPaused or (FSettingsView <> nil);
  if FPowerPad <> nil then
    FPowerPad.Enabled := FPowerPad.Enabled and not FInBackground;
  if FGamepad <> nil then
    FGamepad.Enabled := FGamepad.Enabled and not FInBackground;
  if FSuborKeyboard <> nil then
    FSuborKeyboard.Enabled := FSuborKeyboard.Enabled and not FInBackground;
  if FFamicomKeyboard <> nil then
    FFamicomKeyboard.Enabled := FFamicomKeyboard.Enabled and not FInBackground;
  if Paused <> FActivityPaused then
  begin
    FActivityPaused := Paused;
    if FEmulation <> nil then
      if Paused then
      begin
        FormDeactivate(Self);
        FEmulation.Pause;
      end
      else if not FEmulationFaulted then
        FEmulation.Resume;
  end;
  TimerUpdate.Enabled := not FInBackground and (FOpeningRom or ((FEmulation <> nil) and not FEmulationFaulted));
  {$ELSE}
  TimerUpdate.Enabled := (FInput <> nil) or ((FEmulation <> nil) and not FEmulationFaulted);
  {$ENDIF}
end;

{$IFDEF ANDROID}
function TFormMain.ApplicationStateChanged(Sender: TObject; const AAppEvent: TApplicationEvent; const AContext: TObject): Boolean;
begin
  case AAppEvent of
    TApplicationEvent.WillBecomeInactive, TApplicationEvent.EnteredBackground:
      FInBackground := True;
    TApplicationEvent.BecameActive:
      FInBackground := False;
  else
    Exit(False);
  end;
  SyncActivity;
  Result := False;
end;

procedure TFormMain.PollDocumentTransfer;
begin
  if not FOpeningRom then
    Exit;
  var FileName, DisplayName, Error: string;
  if not FTransfer.Poll(FileName, DisplayName, Error) then
    Exit;
  try
    try
      if Error <> '' then
        raise Exception.Create(Error);
      if FileName <> '' then
        if FChoosingTape then
        begin
          // SAF documents are imported into a durable app-owned cassette file.
          var Root := TPath.Combine(FStorage.SaveRoot, 'cassettes');
          var Path := FStorage.GamePath(Root, DisplayName, TGUID.NewGuid.ToString, '.tape');
          var Input := FStorage.OpenRead(FileName);
          try
            FStorage.WriteAtomic(Path, Input);
          finally
            Input.Free;
          end;
          SelectTapeFile(Path);
        end
        else
          LoadRom(FileName, DisplayName);
    except
      on E: Exception do
        ShowMessage(E.Message);
    end;
  finally
    FinishFileSelection;
  end;
end;
{$ENDIF}

procedure TFormMain.FormDeactivate(Sender: TObject);
begin
  // Release keys whose key-up may be lost. Android lifecycle controls pausing.
  FillChar(FKeysDown, SizeOf(FKeysDown), 0);
  FSuppressInputUntilRelease := True;
  if FInput <> nil then
    FInput.Enabled := False;
  if FSettingsView <> nil then
    FSettingsView.CancelCapture;
  if FGamepad <> nil then
    FGamepad.ReleaseAll;
  if FSuborKeyboard <> nil then
    FSuborKeyboard.ReleaseAll;
  if FFamicomKeyboard <> nil then
    FFamicomKeyboard.ReleaseAll;
  if FMiraclePiano <> nil then
    FMiraclePiano.ReleaseAll;
  if FPowerPad <> nil then
    FPowerPad.ReleaseAll;
  if FEmulation <> nil then
    FEmulation.ClearInput;
  FGamepadInput := Default(TEmulatorInput);
end;

procedure TFormMain.ScreenshotClick(Sender: TObject);
begin
  if FEmulation = nil then
    Exit;
  try
    SetStatus('Screenshot: ' + SaveScreenshot);
  except
    on E: Exception do
      SetStatus(E.Message);
  end;
end;

function TFormMain.SaveScreenshot: string;
begin
  if FEmulation = nil then
    raise EInvalidOperation.Create('No game loaded');
  Result := FStorage.ScreenshotFile(FRomDisplayName);
  var Stream := TMemoryStream.Create;
  try
    ImageCanvas.Bitmap.SaveToStream(Stream);
    FStorage.WriteAtomic(Result, Stream);
  finally
    Stream.Free;
  end;
end;

procedure TFormMain.SaveSnapshot(const Name: string);
begin
  if FEmulation = nil then
    raise Exception.Create('No game loaded');
  if not FEmulation.SupportsSnapshots then
    raise ENotSupportedException.Create('Snapshots are not implemented by this core');
  FEmulation.SaveSnapshot(Name);
end;

procedure TFormMain.LoadSnapshot(const Name: string);
begin
  if FEmulation = nil then
    raise Exception.Create('No game loaded');
  if not FEmulation.SupportsSnapshots then
    raise ENotSupportedException.Create('Snapshots are not implemented by this core');
  FEmulation.LoadSnapshot(Name);
  FEmulationFaulted := False;
  SyncActivity;
  UpdateFrame;
end;

procedure TFormMain.SwitchFullScreen;
begin
  FullScreen := not FullScreen;
  LayoutLeft.Visible := not FullScreen;
  {$IFDEF ANDROID}
  LayoutClient.Visible := FullScreen;
  {$ENDIF}
  if FullScreen then
  begin
    LayoutClient.Cursor := crNone;
    LayoutClient.SetFocus;
  end
  else
    LayoutClient.Cursor := crDefault;
end;

procedure TFormMain.FormKeyDown(Sender: TObject; var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
begin
  if FSettingsView <> nil then
    Exit;
  if (FInput <> nil) and not FDispatchingInput then
  begin
    if (FEmulation <> nil) and ((Focused = nil) or not (Focused.GetObject is TCustomEdit)) then
    begin
      Key := 0;
      KeyChar := #0;
    end;
    Exit;
  end;
  Key := HostKeyCode(Key, KeyChar);
  if Key in [vkVolumeUp, vkVolumeDown, vkVolumeMute] then
    Exit;
  if Key = 0 then
  begin
    KeyChar := #0;
    Exit;
  end;
  var Code: Word := Key;
  var SuborKeyboardActive := (FEmulation <> nil) and FEmulation.UsesSuborKeyboard;
  var Peripheral: INesPeripheralCore;
  var Piano: INesMiraclePianoCore;
  var KeyboardActive := SuborKeyboardActive or
    (Supports(FEmulation, INesPeripheralCore, Peripheral) and Peripheral.UsesFamicomKeyboard) or
    (Supports(FEmulation, INesMiraclePianoCore, Piano) and Piano.UsesMiraclePiano);
  var WasDown: Boolean := False;
  if Code <= High(FKeysDown) then
  begin
    WasDown := FKeysDown[Code];
    FKeysDown[Code] := True;
  end;
  if not WasDown then
  begin
    if (Code = vkEscape) and not KeyboardActive then
    begin
      if FullScreen then
        SwitchFullScreen
    end
    else if (Code = vkF11) then
      SwitchFullScreen
    else if (Code = vkO) and (ssCtrl in Shift) and not KeyboardActive then
      OpenRom
    else if (Code = vkR) and (FEmulation <> nil) and not KeyboardActive then
    begin
      TimerUpdate.Enabled := False;
      try
        FEmulation.Reset;
        FUserPaused := False;
        FEmulationFaulted := False;
        {$IFDEF ANDROID}
        if FActivityPaused then
          FEmulation.Pause;
        {$ENDIF}
        SyncActivity;
        SetStatus(FRomDisplayName);
      except
        StopOnError;
        raise;
      end;
    end
    else if (Code = vkP) and not KeyboardActive then
      SwitchPause
    else if (Code = vkF8) and (FEmulation <> nil) and not KeyboardActive then
    begin
      try
        SetStatus('Screenshot: ' + SaveScreenshot);
      except
        on E: Exception do
          ShowMessage(E.Message);
      end;
    end
    else if (Code in [vkF5, vkF6]) and (FEmulation <> nil) and not KeyboardActive then
    begin
      try
        if Code = vkF5 then
          SaveSnapshot('quick')
        else
          LoadSnapshot('quick');
      except
        on E: Exception do
          ShowMessage('Snapshot: ' + E.Message);
      end;
    end;
  end;
  if KeyboardActive or not (ssCtrl in Shift) then
    if (FEmulation <> nil) and (FInput = nil) then
      ForwardKeyState(Code, True);
  Key := 0;
  KeyChar := #0;
end;

procedure TFormMain.FormKeyUp(Sender: TObject; var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
begin
  if FSettingsView <> nil then
    Exit;
  if (FInput <> nil) and not FDispatchingInput then
  begin
    if (FEmulation <> nil) and ((Focused = nil) or not (Focused.GetObject is TCustomEdit)) then
    begin
      Key := 0;
      KeyChar := #0;
    end;
    Exit;
  end;
  Key := HostKeyCode(Key, KeyChar);
  if Key in [vkVolumeUp, vkVolumeDown, vkVolumeMute] then
    Exit;
  if Key = 0 then
  begin
    KeyChar := #0;
    Exit;
  end;
  var Code: Word := Key;
  if Code <= High(FKeysDown) then
    FKeysDown[Code] := False;
  if (FEmulation <> nil) and (FInput = nil) then
    ForwardKeyState(Code, False);
  Key := 0;
  KeyChar := #0;
end;

procedure TFormMain.SwitchPause;
begin
  if (FEmulation = nil) or FEmulationFaulted then
    Exit;

  FUserPaused := not FUserPaused;
  if FUserPaused then
  begin
    FormDeactivate(Self);
    FEmulation.Pause;
  end
  else
  begin
    {$IFNDEF ANDROID}
    FEmulation.Resume;
    {$ENDIF}
  end;
  SyncActivity;
  // SyncActivity can release input again when Android changes pause state.
  FKeysDown[vkP] := True;
end;

procedure TFormMain.FormSafeAreaChanged(Sender: TObject; const AInsets: TRectF);
begin
  Padding.Left := AInsets.Left;
  Padding.Top := AInsets.Top;
  Padding.Right := AInsets.Right;
  Padding.Bottom := AInsets.Bottom;
  FormResize(Self);
end;

procedure TFormMain.FormSaveState(Sender: TObject);
begin
  try
    Save;
  except
    //
  end;
end;

procedure TFormMain.UpdatePeripheralFeedback;
var
  Peripheral: INesPeripheralCore;
  Tape: INesTapeCore;
  Piano: INesMiraclePianoCore;
begin
  if (FEmulation = nil) or FEmulationFaulted then
    Exit;
  if (FMiraclePiano <> nil) and FMiraclePiano.Visible and FMiraclePiano.Enabled and
    Supports(FEmulation, INesMiraclePianoCore, Piano) then
    FMiraclePiano.CoreKeys := Piano.GetMiracleKeys;
  if (FDataRecorder <> nil) and Supports(FEmulation, INesTapeCore, Tape) and Tape.UsesDataRecorder then
    FDataRecorder.Progress := Tape.GetTapeProgress;
  if (FGamepad <> nil) and FGamepad.Visible and FGamepad.Enabled then
    FGamepad.CoreButtons := FEmulation.GetInputState.Buttons;
  if Supports(FEmulation, INesPeripheralCore, Peripheral) then
  begin
    if (FSuborKeyboard <> nil) and FSuborKeyboard.Visible and FSuborKeyboard.Enabled then
    begin
      FSuborKeyboard.CoreKeys := Peripheral.GetSuborKeys;
      FSuborKeyboard.Indicators := Peripheral.GetSuborIndicators;
    end;
    if (FFamicomKeyboard <> nil) and FFamicomKeyboard.Visible and FFamicomKeyboard.Enabled then
      FFamicomKeyboard.CoreKeys := Peripheral.GetFamicomKeys;
    if (FPowerPad <> nil) and FPowerPad.Visible and FPowerPad.Enabled then
      FPowerPad.CoreButtons := Peripheral.GetPowerPadButtons;
  end;
end;

procedure TFormMain.TimerUpdateTimer(Sender: TObject);
begin
  if FInput <> nil then
  try
    PollHostInput;
  except
    on E: Exception do
    begin
      FInput.Enabled := False;
      TimerUpdate.Enabled := False;
      if FEmulation <> nil then
        FEmulation.ClearInput;
      SetStatus('Ошибка ввода: ' + E.Message);
      Exit;
    end;
  end;
  if FSettingsView <> nil then
    Exit;
  {$IFDEF ANDROID}
  PollDocumentTransfer;
  if FOpeningRom then
    Exit;
  {$ENDIF}
  if FEmulationFaulted or not TimerUpdate.Enabled or (FEmulation = nil) then
    Exit;
  if FEmulation.IsPaused then
  begin
    ImageCanvas.Opacity := 0.5;
    LabelPaused.Visible := True;
  end
  else
  begin
    ImageCanvas.Opacity := 1;
    LabelPaused.Visible := False;
  end;
  try
    UpdatePeripheralFeedback;
    UpdateFrame;
  except
    StopOnError;
    raise;
  end;
end;

procedure TFormMain.StopOnError;
begin
  FEmulationFaulted := True;
  TimerUpdate.Enabled := False;
  if FEmulation <> nil then
    FEmulation.Pause;
  FormDeactivate(Self);
  SetStatus('Stopped after error - ' + FRomDisplayName);
  SyncActivity;
end;

procedure TFormMain.LayoutClientClick(Sender: TObject);
begin
  LayoutClient.SetFocus;
end;

procedure TFormMain.LayoutClientDblClick(Sender: TObject);
begin
  {$IFDEF ANDROID}
  Exit;
  {$ENDIF}
  SwitchFullScreen;
end;

procedure TFormMain.ListBoxGamesItemClick(const Sender: TCustomListBox; const Item: TListBoxItem);
begin
  if FOpeningRom then
    Exit;
  var FileInfo := (Item as TListBoxItemGame).RomFile;
  LoadRom(FileInfo.Location, FileInfo.Name);
end;

function TFormMain.CreateCore(const FileName: string): IEmulationCore;
begin
  var Stream := FStorage.OpenRead(FileName);
  try
    Result := CreateEmulationCore(Stream, FStorage, FileName);
  finally
    Stream.Free;
  end;
end;

procedure TFormMain.LoadRom(const FileName: string; const DisplayName: string);
begin
  ImageLogo.Visible := False;
  // Construct first: an invalid ROM leaves the current worker running.
  var NewEmulation: IEmulationCore;
  NewEmulation := CreateCore(FileName);
  try
    if FEmulation <> nil then
      FEmulation.Stop;
  except
    NewEmulation := nil;
    raise;
  end;
  if FGamepad <> nil then
    FGamepad.ReleaseAll;
  if FSuborKeyboard <> nil then
    FSuborKeyboard.ReleaseAll;
  if FFamicomKeyboard <> nil then
    FFamicomKeyboard.ReleaseAll;
  if FMiraclePiano <> nil then
    FMiraclePiano.ReleaseAll;
  if FPowerPad <> nil then
    FPowerPad.ReleaseAll;
  TimerUpdate.Enabled := False;
  FEmulation := nil; // Join before replacing the session.
  FEmulation := NewEmulation;
  var InputSystem := ROM_SYSTEM_NES;
  if FEmulation.Config is TMDConfig then
    InputSystem := ROM_SYSTEM_MD
  else if FEmulation.Config is TNeoGeoConfig then
    InputSystem := ROM_SYSTEM_NEOGEO
  else if FEmulation.Config is TSnesConfig then
    InputSystem := ROM_SYSTEM_SNES
  else if FEmulation.Config is TGBCEmulatorConfig then
    InputSystem := ROM_SYSTEM_GBC
  else if FEmulation.Config is TGBEmulatorConfig then
    InputSystem := ROM_SYSTEM_GB;
  LoadHostInput(InputSystem);
  if FEmulation.Config is TMDConfig then
    FGamepad.Layout := TScreenGamepadLayout.Sega
  else if FEmulation.Config is TNeoGeoConfig then
    FGamepad.Layout := TScreenGamepadLayout.NeoGeo
  else if FEmulation.Config is TSnesConfig then
    FGamepad.Layout := TScreenGamepadLayout.Snes
  else if FEmulation.Config is TGBCEmulatorConfig then
    FGamepad.Layout := TScreenGamepadLayout.GameBoyColor
  else if FEmulation.Config is TGBEmulatorConfig then
    FGamepad.Layout := TScreenGamepadLayout.GameBoy
  else
    FGamepad.Layout := TScreenGamepadLayout.Nes;
               {
  var NesEmulatorConfig: INesEmulatorConfig;
  if Supports(FEmulation.Config, INesEmulatorConfig, NesEmulatorConfig) then
  begin
    NesEmulatorConfig.FourScore := False;
    NesEmulatorConfig.ZapperEnabled := False;
    FEmulation.Config.Save;
  end;     }

  ImageCanvas.HitTest := False;
  ImageCanvas.CanFocus := False;
  ImageCanvas.DisableFocusEffect := True;
  var Peripheral: INesPeripheralCore;
  if Supports(FEmulation, INesPeripheralCore, Peripheral) then
  begin
    ImageCanvas.HitTest := True;
    ImageCanvas.CanFocus := True;
    ImageCanvas.OnKeyDown := FormKeyDown;
    ImageCanvas.OnKeyUp := FormKeyUp;
    ImageCanvas.DisableFocusEffect := False;
    ImageCanvas.CanParentFocus := True;
    Peripheral.Zapper.OnReadLight :=
      function(const Mask: TNesZapperMask): Boolean
      begin
        // External photosensor implementation goes here.
        // True = light detected; False = darkness / aim outside the screen.
        //Result := ReadExternalPhotoSensor(Mask);

        Result := TZapper.ReadMask(Mask, FZapperPixel.X, FZapperPixel.Y);
      end;
  end;

  FUserPaused := False;
  ImageCanvas.DisableInterpolation := SameText(FEmulation.Config.Filter, 'nearest');
  FillChar(FKeysDown, SizeOf(FKeysDown), 0);
  FRomDisplayName := DisplayName;
  if FRomDisplayName = '' then
    FRomDisplayName := ExtractFileName(FileName);
  FSoundErrorShown := False;
  try
    ImageCanvas.Bitmap.Clear(TAlphaColors.Black);
    FEmulationFaulted := False;
    {$IFDEF ANDROID}
    if FActivityPaused then
      FEmulation.Pause;
    {$ENDIF}
    FEmulation.Start;
    SyncActivity;
    SetStatus(FEmulation.Name + ' - ' + FRomDisplayName);
  except
    StopOnError;
    raise;
  end;
  {$IFDEF ANDROID}
  SwitchFullscreen;
  {$ENDIF}
end;

procedure TFormMain.FinishFileSelection;
begin
  {$IFDEF ANDROID}
  FTransfer.Finish;
  FChoosingTape := False;
  {$ENDIF}
  FOpeningRom := False;
  ButtonOpen.Enabled := True;
  FormActivate(Self);
end;

procedure TFormMain.SelectDocument(ForCassette: Boolean);
begin
  if FOpeningRom then
    Exit;
  FOpeningRom := True;
  ButtonOpen.Enabled := False;
  FormDeactivate(Self);
  SyncActivity;
  var IsAlive: TFunc<Boolean> := FCallbackAlive;
  var Completion: TStorageSelectionCallback :=
    procedure(const Selection: TStorageSelection)
    begin
      if not IsAlive() then
        Exit;
      var Importing := False;
      try
        try
          if Selection.Error <> '' then
            raise Exception.Create(Selection.Error);
          if not Selection.Cancelled then
          begin
            if ForCassette then
            begin
              {$IFDEF ANDROID}
              FChoosingTape := True;
              FTransfer.Import(Selection.Location, True);
              Importing := True;
              {$ELSE}
              SelectTapeFile(Selection.Location);
              {$ENDIF}
            end
            else
              LoadRom(Selection.Location, FStorage.Describe(Selection.Location).Name);
          end;
        except
          on E: Exception do
            ShowMessage(E.Message);
        end;
      finally
        if not Importing then
          FinishFileSelection;
      end;
    end;
  if ForCassette then
  begin
    FFileDialog.InitialDirectory := '';
    FFileDialog.FileMustExist := False;
    FFileDialog.Title := 'Choose a cassette file';
    FFileDialog.Filter := 'Cassette (*.tape)|*.tape|All files|*.*';
    FFileDialog.SelectFiles(
      procedure(const Selection: TFMXSelectionResult)
      begin
        var Result := Default(TStorageSelection);
        Result.Cancelled := Selection.Status = TFMXSelectionStatus.Cancelled;
        Result.Error := Selection.Error;
        if Selection.Status = TFMXSelectionStatus.Selected then
          Result.Location := Selection.Locations[0];
        Completion(Result);
      end);
  end
  else
  begin
    ImageLogo.Visible := False;
    FStorage.SelectRom(Completion);
  end;
end;

procedure TFormMain.OpenRom;
begin
  SelectDocument(False);
end;

procedure TFormMain.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  try
    Stop;
  except
    on E: Exception do
    begin
      CanClose := False;
      ShowMessage(E.Message);
    end;
  end;
end;

procedure TFormMain.ReportAudioError(const MessageText: string);
begin
  ShowMessage('Sound unavailable; the game will continue without audio.' + SLineBreak + MessageText);
end;

procedure TFormMain.UpdateFrame;
begin
  if FEmulation = nil then
    Exit;
  var Frame: TEmulatorFrame;
  var NewFrame := FEmulation.TryGetFrame(Frame);
  var AudioDiagnostics: IEmulationAudioDiagnostics;
  if Supports(FEmulation, IEmulationAudioDiagnostics, AudioDiagnostics) then
  begin
    var AudioError := AudioDiagnostics.TakeAudioError;
    if (AudioError <> '') and not FSoundErrorShown then
    begin
      FSoundErrorShown := True;
      ReportAudioError(AudioError);
    end;
  end;
  var ErrorText := FEmulation.TakeError;
  if (ErrorText <> '') and not FEmulationFaulted then
  begin
    StopOnError;
    raise Exception.Create(ErrorText);
  end;
  if not FEmulationFaulted and NewFrame then
  begin
    var NewCaption := Format('%s - %.1f FPS', [FEmulation.Name, Frame.FramesPerSecond]);
    if Caption <> NewCaption then
      SetStatus(NewCaption);
  end;
  if not NewFrame then
    Exit;
  if (ImageCanvas.Bitmap.Width <> Frame.Width) or (ImageCanvas.Bitmap.Height <> Frame.Height) then
  begin
    ImageCanvas.Bitmap.SetSize(Frame.Width, Frame.Height);
  end;
  var Data: TBitmapData;
  if ImageCanvas.Bitmap.Map(TMapAccess.Write, Data) then
  try
    UploadFramePixels(Frame.Pixels, Frame.Width, Frame.Height, Data);
  finally
    ImageCanvas.Bitmap.Unmap(Data);
  end;
  ImageCanvas.Repaint;
end;

procedure TFormMain.DoOnSettingChange;
begin
  //FF2C4361 - FF0B1E39
  var OverAccentColor := SystemAccentColor;

  // Set stylebook and color for theme
  if IsDark then
  begin
    // Set accent color for stylebook
    ChangeStyleBookColor(FormStyles.StyleBookWinUI3, OverAccentColor);
    StyleBook := FormStyles.StyleBookWinUI3;
  end
  else
  begin
    // Set accent color for stylebook
    ChangeStyleBookColor(FormStyles.StyleBookWinUI3Light, OverAccentColor);
    StyleBook := FormStyles.StyleBookWinUI3Light;
  end;

  inherited;

  SystemBackdropType := TWindowBackdropType.Disable;
  Fill.Kind := TBrushKind.None;

  UpdateSystemBackdropType;
               {
  if RadioButtonSetBGGradient.IsChecked then
  begin
    Fill.Kind := TBrushKind.Gradient;
    //Fill.Gradient.Color := $FF2C4361;
    //Fill.Gradient.Color1 := $FF0B1E39;
    Fill.Gradient.Color := ComboColorBoxSetBGColor1.Color;
    Fill.Gradient.Color1 := ComboColorBoxSetBGColor2.Color;
  end;    }

  TMessageManager.DefaultManager.SendMessage(Self, TStyleChangedMessage.Create(StyleBook, Self), True);
  TMessageManager.DefaultManager.SendMessage(Self, TInternalSettingChangedMessage.Create(StyleBook, Self), True);
end;

{ TListBoxItemGame }

procedure TListBoxItemGame.ApplyStyle;
begin
  inherited;
  if FLoaded then
    Exit;
  FLoaded := True;
  var BoxPath := StylesData['box'].AsString;
  try
    if (Storage <> nil) and Storage.Exists(BoxPath) then
      ItemData.Bitmap.LoadFromFileAsync(Self, BoxPath, 64, 64, nil, Storage)
    else
      ItemData.Bitmap := nil;
  except
    ItemData.Bitmap := nil;
  end;
end;

end.

