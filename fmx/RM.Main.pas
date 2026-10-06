unit RM.Main;

interface

uses
  System.SysUtils, System.Classes, System.Types, System.UITypes, FMX.Forms,
  FMX.Types, FMX.Controls, FMX.Objects, FMX.Graphics, FMX.Dialogs, NES.Consts,
  NES.Controller, Core.Emulation, Core.EmulatorFactory, Core.Adapter.MD,
  Core.Adapter.SNES, WinUI3.Form, WinUI3.Style, FMX.Controls.Presentation,
  FMX.StdCtrls, FMX.Layouts, FMX.Platform, NES.SuborKeyboard, NES.PowerPad,
  NES.FamicomKeyboard, NES.MiraclePiano,
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
    SystemId := RadioButtonSNES.TagString;

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
  RadioButtonMD.TagString := ROM_FOLDER_MD;
  RadioButtonSNES.TagString := ROM_SYSTEM_SNES;
  RadioButtonSNES.StylesData['path.Data.Data'] :=
    'M7,6 L17,6 C21,6 23,8 23,12 C23,16 20,19 17,18 L13,16 L11,16 ' +
    'L7,18 C3,19 1,16 1,12 C1,8 3,6 7,6 Z M6,9 L6,11 L4,11 L4,13 ' +
    'L6,13 L6,15 L8,15 L8,13 L10,13 L10,11 L8,11 L8,9 Z ' +
    'M16,9 L18,11 L16,13 L14,11 Z M19,12 L21,14 L19,16 L17,14 Z';
  RadioButtonMD.StylesData['path.Data.Data'] := 'M7,6 L17,6 C18.5912990570068,6 20.1174240112305,6.63214111328125 21.2426414489746,7.75735950469971 C22.3678588867188,8.88257789611816 23,10.4087009429932 23,12 C23,13.5912990570068 22.3678588867188,15.1174230575562 ' +
    '21.2426414489746,16.2426414489746 C20.1174240112305,17.3678588867188 18.5912990570068,18 17,18 C15.2200002670288,18 13.6300001144409,17.2299995422363 12.5300006866455,16 L11.4700012207031,16 C10.3700008392334,' +
    '17.2299995422363 8.78000068664551,18 7.00000143051147,18 C5.40870189666748,18 3.88257908821106,17.3678588867188 2.75736093521118,16.2426414489746 C1.63214254379272,15.1174230575562 1.00000131130219,13.5912981033325 ' +
    '1.00000143051147,11.9999990463257 C1.00000154972076,10.4086990356445 1.6321427822113,8.88257598876953 2.75736141204834,7.75735759735107 C3.88257956504822,6.63213968276978 5.4087028503418,5.99999904632568 ' +
    '7.00000143051147,5.99999904632568 M6,9 L6,11 L4,11 L4,13 L6,13 L6,15 L8,15 L8,13 L10,13 L10,11 L8,11 L8,9 Z M15.5,12 C15.1021757125854,12 14.7206439971924,12.1580352783203 14.4393396377563,12.4393396377563 ' +
    'C14.1580352783203,12.7206439971924 14,13.1021747589111 14,13.5 C14,13.8978252410889 14.1580352783203,14.2793560028076 14.4393396377563,14.5606603622437 C14.7206439971924,14.8419647216797 15.1021757125854,' +
    '15 15.5,15 C15.8978242874146,15 16.279354095459,14.8419647216797 16.5606594085693,14.5606603622437 C16.8419647216797,14.2793560028076 17,13.8978242874146 17,13.5 C17,13.1021757125854 16.8419647216797,12.7206439971924 ' +
    '16.5606594085693,12.4393396377563 C16.279354095459,12.1580352783203 15.8978242874146,12 15.5,12 M18.5,9 C18.1021747589111,9 17.720645904541,9.15803527832031 17.4393405914307,9.43933963775635 C17.1580352783203,' +
    '9.72064399719238 17,10.1021747589111 17,10.5 C17,10.8978252410889 17.1580352783203,11.2793560028076 17.4393405914307,11.5606603622437 C17.720645904541,11.8419647216797 18.1021747589111,12 18.5,12 C18.8978252410889,' +
    '12 19.279354095459,11.8419647216797 19.5606594085693,11.5606603622437 C19.8419647216797,11.2793560028076 20,10.8978242874146 20,10.5 C20,10.1021757125854 19.8419647216797,9.72064399719238 19.5606594085693,' +
    '9.43933963775635 C19.279354095459,9.15803527832031 18.8978252410889,9 18.5,9 ';
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
    Result := CreateEmulationCore(Stream, FStorage, FStorage.Describe(FileName).Name);
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
  else if FEmulation.Config is TSnesConfig then
    InputSystem := ROM_SYSTEM_SNES
  else if FEmulation.Config is TGBCEmulatorConfig then
    InputSystem := ROM_SYSTEM_GBC
  else if FEmulation.Config is TGBEmulatorConfig then
    InputSystem := ROM_SYSTEM_GB;
  LoadHostInput(InputSystem);
  if FEmulation.Config is TMDConfig then
    FGamepad.Layout := TScreenGamepadLayout.Sega
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
    // Port 2 is selected by the NES configuration before the worker starts.
    // Attaching the light-sensor callback must not connect a gun to every ROM.
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

