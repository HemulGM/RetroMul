unit RM.Main;

interface

uses
  {$IFDEF MSWINDOWS}
  Winapi.Windows,
  {$ENDIF}
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
  Core.InputConfig, RM.LibraryView, RM.ControlsHelp;

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
    ImageLogo: TImage;
    RectangleBG: TRectangle;
    LayoutClient: TLayout;
    LabelPaused: TLabel;
    ImageNoBox: TImage;
    LayoutLeft: TLayout;
    LayoutHead: TLayout;
    LabelStatus: TLabel;
    ButtonCloseRom: TButton;
    procedure FormActivate(Sender: TObject);
    procedure FormResize(Sender: TObject);
    procedure FormDeactivate(Sender: TObject);
    procedure FormKeyUp(Sender: TObject; var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
    procedure FormKeyDown(Sender: TObject; var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
    procedure TimerUpdateTimer(Sender: TObject);
    procedure ButtonOpenClick(Sender: TObject);
    procedure FormSafeAreaChanged(Sender: TObject; const AInsets: TRectF);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
    procedure ListBoxGamesItemClick(const Sender: TCustomListBox; const Item: TListBoxItem);
    procedure LayoutClientClick(Sender: TObject);
    procedure ButtonStopClick(Sender: TObject);
    procedure ButtonPaletteClick(Sender: TObject);
    procedure LayoutClientDblClick(Sender: TObject);
    procedure FormSaveState(Sender: TObject);
    procedure ButtonCloseRomClick(Sender: TObject);
    procedure ImageCanvasMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Single);
    procedure ImageCanvasMouseUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Single);
  private
    FLibrary: TLibraryView;
    FSettingsLibraryVisible, FViewingLibrary, FPauseOnFocusLoss, FStartFullscreen, FAutoPaused: Boolean;
    FLibraryBackTool, FScreenshotTool: TButton;
    FGameTools: array[0..4] of TButton;
    FHelpTool, FCoinTool: TButton;
    FGamePlatform, FGameFPS, FGameAudio: TLabel;
    FGameStatus: TPanel;
    FHelp: TControlsHelpView;
    FHelpWasPaused, FHelpClosing, FHelpFullScreen: Boolean;
    FFullScreenPadding: TRectF;
    {$IFDEF MSWINDOWS}
    FFullScreenBorderStyle: TFmxFormBorderStyle;
    FFullScreenWindowState: TWindowState;
    FFullScreenPlacement: TWindowPlacement;
    {$ENDIF}
    procedure ControlsHelpClick(Sender: TObject);
    procedure ControlsHelpClose(Sender: TObject);
    procedure ControlsHelpSettings(Sender: TObject);
    procedure CloseControlsHelp(OpenSettings: Boolean = False);
    procedure UpdateGameChrome;
    procedure UpdatePauseOverlay;
    procedure LibraryPlay(Sender: TObject);
    procedure LibraryBack(Sender: TObject);
    procedure PauseClick(Sender: TObject);
    procedure InsertCoinClick(Sender: TObject);
    procedure SaveStateClick(Sender: TObject);
    procedure LoadStateClick(Sender: TObject);
    procedure FullscreenClick(Sender: TObject);
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
    function UpdateFrame: Boolean;
    procedure LoadSnapshotPreview(const Name: string);
    procedure SwitchPause;
    procedure SwitchFullScreen;
    procedure Load;
    procedure Save;
    procedure MobileCloseRom;
    procedure Stop;
  protected
    function DetectSystemLanguage: string; virtual;
    function CreateStorage: IStorage; virtual;
    function CreateHostInput: TInputManager; virtual;
    function HostInputHasFocus: Boolean; virtual;
    procedure ReportAudioError(const MessageText: string); virtual;
    function CreateCore(const FileName: string): IEmulationCore; virtual;
    procedure DoOnSettingChange; override;
  public
    procedure SaveSnapshot(const Name: string);
    procedure LoadSnapshot(const Name: string);
    procedure LoadRom(const FileName: string; const DisplayName: string = ''; StartPaused: Boolean = False);
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
  FMX.DialogService, RM.Styles, Core.Adapter.GB, GB.Palettes, Core.Adapter.NES,
  Core.SavePaths, Core.RomFormat,
  {$IFDEF MSWINDOWS}
  FMX.Platform.Win,
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
  if FHelp <> nil then
  begin
    CloseControlsHelp(True);
    Exit;
  end;
  if FullScreen then
    SwitchFullScreen;
  if (FSettingsView <> nil) or FOpeningRom then
    Exit;
  FSettingsLibraryVisible := (FLibrary <> nil) and FLibrary.Visible;
  if FLibrary <> nil then
    FLibrary.Visible := False;
  FSettingsWasPaused := (FEmulation <> nil) and FEmulation.IsPaused;
  if FLibrary <> nil then
    FSettingsWasPaused := FViewingLibrary or FUserPaused or FAutoPaused;
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
  if FLibrary <> nil then
    LayoutLeft.Visible := False;
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
  if FLibrary <> nil then
  begin
    FLibrary.ApplyPreferences;
    FLibrary.Reload;
  end;
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
      if FLibrary <> nil then
        FLibrary.Visible := FSettingsLibraryVisible;
      LayoutClient.Visible := FSettingsClientVisible;
      //LoadSystem(FSystemId);
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
  if FViewingLibrary then
    Exit;
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
  if (FHelp <> nil) or (FEmulation = nil) or FEmulation.IsPaused or FEmulationFaulted then
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
  if FLibrary <> nil then
    LibraryBack(Self);
  SyncActivity;
end;

function TFormMain.DetectSystemLanguage: string;
begin
  Result := 'en';
  var Locale: IFMXLocaleService;
  if TPlatformServices.Current.SupportsPlatformService(IFMXLocaleService, Locale) then
    Result := Locale.GetCurrentLangID;
end;

procedure TFormMain.Load;
begin
  var Ini := FStorage.ReadConfig(FStorage.ConfigFile('config'));
  try
    var PreviousLanguage := FormStyles.Lang.Lang;
    var FirstLaunch := not Ini.ValueExists('General', 'Language');
    var Language := Ini.ReadString('General', 'Language', 'en');
    if FirstLaunch then
      Language := DetectSystemLanguage;
    FormStyles.SetLanguage(Language);
    if FirstLaunch then
    begin
      Ini.WriteString('General', 'Language', FormStyles.Lang.Lang);
      FStorage.WriteConfig(Ini);
    end;
    if PreviousLanguage <> FormStyles.Lang.Lang then
    begin
      FormStyles.RelocalizeUI(LayoutLeft, PreviousLanguage);
      FormStyles.RelocalizeUI(LayoutClient, PreviousLanguage);
      if FLibrary <> nil then
        FLibrary.ApplyLanguage(PreviousLanguage);
      if FSettingsView <> nil then
        FSettingsView.ApplyLanguage(PreviousLanguage);
      if FEmulation = nil then
        SetStatus(Translate('Open ROM'));
    end;
    FControlBottomInset := EnsureRange(Ini.ReadInteger('General', 'ControlBottomInset', 100), 0, 400);
    ApplyControlInset;
    FPauseOnFocusLoss := Ini.ReadBool('General', 'PauseOnFocusLoss', True);
    FStartFullscreen := Ini.ReadBool('General', 'StartFullscreen', False);
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
  FFileDialog := TFMXOpenDialog.Create(Self);
  FFileDialog.MultipleSelection := False;
  var ScreenshotButton := TButton.Create(Self);
  FScreenshotTool := ScreenshotButton;
  ScreenshotButton.Name := 'ButtonScreenshot';
  ScreenshotButton.Parent := LayoutHead;
  ScreenshotButton.Align := TAlignLayout.Right;
  ScreenshotButton.Width := 60;
  ScreenshotButton.Text := 'PNG';
  ScreenshotButton.Hint := Translate('Screenshot (F8)');
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
  Load;
  LoadHostInput(ROM_SYSTEM_GB);
  {$IFNDEF ANDROID}
  FLibrary := TLibraryView.CreateLibrary(Self, FStorage);
  FLibrary.Parent := Self;
  FLibrary.Align := TAlignLayout.Client;
  FLibrary.OnPlay := LibraryPlay;
  FLibrary.OnSettings := SettingsClick;
  FLibrary.OnOpen := ButtonOpenClick;
  LayoutLeft.Visible := False;
  LayoutClient.Visible := False;
  FViewingLibrary := True;
  var BackButton := TButton.Create(Self);
  BackButton.Name := 'ButtonLibrary';
  BackButton.Parent := LayoutHead;
  BackButton.Align := TAlignLayout.Left;
  BackButton.Width := 140;
  BackButton.Text := Translate('← Library');
  BackButton.OnClick := LibraryBack;
  FLibraryBackTool := BackButton;
  ButtonCloseRom.Visible := False;
  LabelStatus.Align := TAlignLayout.None;
  for var I := 0 to High(FGameTools) do
  begin
    FGameTools[I] := TButton.Create(Self);
    FGameTools[I].Parent := LayoutHead;
    FGameTools[I].Align := TAlignLayout.None;
    FGameTools[I].Width := 104;
  end;
  FGameTools[0].Name := 'GamePause';
  FGameTools[0].OnClick := PauseClick;
  FGameTools[1].Name := 'GameSave';
  FGameTools[2].Name := 'GameLoad';
  FGameTools[3].Name := 'GameFullscreen';
  FGameTools[1].OnClick := SaveStateClick;
  FGameTools[2].OnClick := LoadStateClick;
  FGameTools[3].OnClick := FullscreenClick;
  FGameTools[4].Name := 'GameSettings';
  FGameTools[4].OnClick := SettingsClick;
  FGameTools[1].Hint := Translate('Quick save · Quick slot');
  FGameTools[2].Hint := Translate('Load quick save · Quick slot');
  GameplayButton(FLibraryBackTool, Translate('Library'), 'M24,13 L2,13 M10,5 L2,13 L10,21', Translate('Back to library'));
  GameplayButton(FGameTools[0], Translate('Pause'), IconPause, Translate('Pause / resume · P'));
  GameplayButton(FGameTools[1], Translate('Save'), IconSave, Translate('Quick save · F5'));
  GameplayButton(FGameTools[2], Translate('Load'), IconLoad, Translate('Quick load · F6'));
  GameplayButton(FScreenshotTool, Translate('Screenshot'), IconCamera, Translate('Take screenshot · F8'));
  GameplayButton(FGameTools[3], '', IconFullScreen, Translate('Full screen · F11'));
  GameplayButton(FGameTools[4], '', IconGear, Translate('Settings'));
  FCoinTool := TButton.Create(Self);
  FCoinTool.Parent := LayoutHead;
  FCoinTool.Name := 'GameInsertCoin';
  GameplayButton(FCoinTool, Translate('Insert coin'), IconCoin, Translate('Insert coin · F9'));
  FCoinTool.Visible := False;
  FCoinTool.OnClick := InsertCoinClick;
  FHelpTool := TButton.Create(Self);
  FHelpTool.Parent := LayoutHead;
  FHelpTool.Name := 'GameControlsHelp';
  GameplayButton(FHelpTool, 'F1', IconPad, Translate('Controls and shortcuts · F1'));
  FHelpTool.OnClick := ControlsHelpClick;
  var HelpBorder := TRectangle.Create(FHelpTool);
  HelpBorder.Parent := FHelpTool;
  HelpBorder.Align := TAlignLayout.Contents;
  HelpBorder.Fill.Kind := TBrushKind.None;
  HelpBorder.Stroke.Color := $FFFFB43B;
  HelpBorder.XRadius := 8;
  HelpBorder.YRadius := 8;
  HelpBorder.HitTest := False;
  LabelStatus.StyledSettings := [];
  LabelStatus.TextSettings.Font.Family := 'Segoe UI';
  LabelStatus.TextSettings.Font.Size := 17;
  LabelStatus.TextSettings.Font.Style := [TFontStyle.fsBold];
  LabelStatus.TextSettings.FontColor := $FFE8ECF1;
  LabelStatus.TextSettings.Trimming := TTextTrimming.Character;
  FGamePlatform := GameplayLabel(Self, LayoutHead, '', 12);
  FGamePlatform.Opacity := 0.6;
  FGameStatus := TPanel.Create(Self);
  FGameStatus.Parent := LayoutClient;
  FGameStatus.Name := 'GameStatus';
  FGameStatus.Align := TAlignLayout.Bottom;
  FGameStatus.Height := 30;
  FGameStatus.StyleLookup := 'retromul_sidebar';
  var Dot := TCircle.Create(Self);
  Dot.Parent := FGameStatus;
  Dot.SetBounds(14, 11, 8, 8);
  Dot.Fill.Color := $FF7ED94C;
  Dot.Stroke.Kind := TBrushKind.None;
  Dot.HitTest := False;
  FGameFPS := GameplayLabel(Self, FGameStatus, '', 12);
  FGameFPS.Align := TAlignLayout.Client;
  FGameFPS.Margins.Left := 32;
  FGameAudio := GameplayLabel(Self, FGameStatus, '', 12);
  FGameAudio.Align := TAlignLayout.Right;
  FGameAudio.AutoSize := True;
  FGameAudio.Margins.Left := 24;
  FGameAudio.Margins.Right := 12;
  FGameAudio.TextSettings.HorzAlign := TTextAlign.Trailing;
  InterfaceIcon(FGameAudio, IconSpeaker, -24, 7, 16);
  LabelPaused.Text := Translate('Paused');
  LabelPaused.TextSettings.Font.Size := 28;
  LayoutHead.OnResize := FormResize;
  var ToolbarBackground := TPanel.Create(Self);
  ToolbarBackground.Parent := LayoutHead;
  ToolbarBackground.Align := TAlignLayout.Contents;
  ToolbarBackground.StyleLookup := 'retromul_sidebar';
  ToolbarBackground.HitTest := False;
  ToolbarBackground.SendToBack;
  FormResize(Self);
  {$ENDIF}
  SyncActivity;
end;

destructor TFormMain.Destroy;
begin
  if Assigned(FInvalidateCallbacks) then
    FInvalidateCallbacks();
  if TimerUpdate <> nil then
    TimerUpdate.Enabled := False;
  FreeAndNil(FSettingsView);
  FreeAndNil(FHelp);
  FreeAndNil(FLibrary);
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
  if FAutoPaused and not FUserPaused and not FViewingLibrary and (FSettingsView = nil) and (FHelp = nil) then
  begin
    FAutoPaused := False;
    if (FEmulation <> nil) and not FEmulationFaulted then
      FEmulation.Resume;
  end;
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

procedure TFormMain.FormResize(Sender: TObject);
begin
  if csDestroying in ComponentState then
    Exit;
  if (FLibraryBackTool <> nil) and (FHelpTool <> nil) then
  begin
    var HasCoin := (FCoinTool <> nil) and FCoinTool.Visible;
    var Narrow := LayoutHead.Width < IfThen(HasCoin, 1386, 1186);
    var Compact := LayoutHead.Width < IfThen(HasCoin, 740, 660);
    var Y := IfThen(Narrow, 56, 8);
    var Actions: TArray<TButton> := [FGameTools[0], FGameTools[1], FGameTools[2], FScreenshotTool,
        FGameTools[3], FGameTools[4], FHelpTool];
    var Widths: TArray<Single> := [130, 132, 132, 112, 44, 44, 88];
    if HasCoin then
    begin
      Actions := [FGameTools[0], FCoinTool, FGameTools[1], FGameTools[2], FScreenshotTool,
          FGameTools[3], FGameTools[4], FHelpTool];
      Widths := [130, 188, 132, 132, 112, 44, 44, 88];
    end;
    var Total: Single := (Length(Actions) - 1) * 8;
    for var W in Widths do
      Total := Total + W;
    var X := LayoutHead.Width - Total - 12;
    if Narrow then
      X := 8;
    LayoutHead.Height := IfThen(Narrow, 104, 64);
    FLibraryBackTool.Align := TAlignLayout.None;
    FLibraryBackTool.SetBounds(8, 8, 156, 40);
    var TitleWidth := Max(0, IfThen(Narrow, LayoutHead.Width - 188, X - 192));
    LabelStatus.SetBounds(184, 5, TitleWidth, 30);
    FGamePlatform.SetBounds(184, 33, TitleWidth, 22);
    FScreenshotTool.Align := TAlignLayout.None;
    for var I := 0 to High(Actions) do
    begin
      var W := Widths[I];
      if Narrow then
      begin
        W := (LayoutHead.Width - 16 - (Length(Actions) - 1) * 6) / Length(Actions);
        if I = 0 then
          W := Max(32, W) + 26
        else
          W := Max(32, W - 26 / (Length(Actions) - 1));
      end;
      Actions[I].SetBounds(X, Y, W, 40);
      X := X + W + IfThen(Narrow, 6, 8);
    end;
    if (FEmulation <> nil) and (FUserPaused or FAutoPaused) then
      FGameTools[0].Text := Translate('Resume')
    else
      FGameTools[0].Text := Translate('Pause');
    FGameTools[1].Text := Translate('Save');
    FGameTools[2].Text := Translate('Load');
    FScreenshotTool.Text := Translate('Screenshot');
    if HasCoin then
      FCoinTool.Text := Translate('Insert coin');
    FGameTools[3].Text := '';
    FGameTools[4].Text := '';
    for var I := 0 to High(Actions) do
    begin
      if (Compact and (Actions[I] <> FHelpTool)) or
        ((Actions[I] = FCoinTool) and (Actions[I].Width < 180)) then
        Actions[I].Text := '';
      for var Child in Actions[I].Children do
        if Child is FMX.Objects.TPath then
        begin
          var Icon := FMX.Objects.TPath(Child);
          if I = 0 then
            if (FEmulation <> nil) and (FUserPaused or FAutoPaused) then
              Icon.Data.Data := IconPlay
            else
              Icon.Data.Data := IconPause;
          Icon.Position.X := IfThen(Actions[I].Text = '', (Actions[I].Width - 20) / 2, 12);
        end;
    end;
  end;
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
      ShowMessage(Translate('Cassette: ') + E.Message);
  end;
end;

procedure TFormMain.SelectTapeFile(const FileName: string);
begin
  var Tape: INesTapeCore;
  if not Supports(FEmulation, INesTapeCore, Tape) or not Tape.UsesDataRecorder then
    raise EInvalidOperation.Create(Translate('No data recorder connected'));
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
      ShowMessage(Translate('Cassette: ') + E.Message);
    end;
  end;
  {$ELSE}
  var Dialog := TSaveDialog.Create(Self);
  try
    Dialog.Title := Translate('Save cassette as');
    Dialog.Filter := Translate('Cassette (*.tape)|*.tape');
    Dialog.DefaultExt := 'tape';
    Dialog.Options := [TOpenOption.ofPathMustExist, TOpenOption.ofOverwritePrompt];
    Dialog.FileName := Tape.GetTapeProgress.FileName;
    if Dialog.Execute then
    try
      Tape.TapeCommand(TapeSaveAs, Dialog.FileName);
      FDataRecorder.Progress := Tape.GetTapeProgress;
    except
      on E: Exception do
        ShowMessage(Translate('Cassette: ') + E.Message);
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
  Caption := AppName;
  {$IFDEF ANDROID}
  LabelStatus.Text := Text;
  {$ELSE}
  LabelStatus.Text := Text;
  if FEmulation <> nil then
    LabelStatus.Text := FRomDisplayName;
  UpdateGameChrome;
  if FLibrary <> nil then
    FormResize(Self);
  {$ENDIF}
end;

procedure TFormMain.SyncActivity;
begin
  if FGameTools[0] <> nil then
  begin
    FGameTools[0].Enabled := (FEmulation <> nil) and not FEmulationFaulted and not FOpeningRom;
    if (FEmulation <> nil) and (FUserPaused or FAutoPaused) then
      FGameTools[0].Text := Translate('Resume')
    else
      FGameTools[0].Text := Translate('Pause');
    FGameTools[1].Enabled := (FEmulation <> nil) and FEmulation.SupportsSnapshots and not FOpeningRom;
    FGameTools[2].Enabled := FGameTools[1].Enabled;
    FGameTools[4].Enabled := not FOpeningRom;
  end;
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
  var Paused := FInBackground or FOpeningRom or FUserPaused or (FSettingsView <> nil) or (FHelp <> nil);
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
  UpdateGameChrome;
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
  {$IFNDEF ANDROID}
  if FPauseOnFocusLoss and not HostInputHasFocus and not FViewingLibrary and
    (FSettingsView = nil) and (FEmulation <> nil) and not FEmulation.IsPaused then
  begin
    FAutoPaused := True;
    FEmulation.Pause;
  end;
  {$ENDIF}
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
    SetStatus(Translate('Screenshot: ') + SaveScreenshot);
  except
    on E: Exception do
      SetStatus(E.Message);
  end;
end;

function TFormMain.SaveScreenshot: string;
begin
  if FEmulation = nil then
    raise EInvalidOperation.Create(Translate('No game loaded'));
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
    raise Exception.Create(Translate('No game loaded'));
  if not FEmulation.SupportsSnapshots then
    raise ENotSupportedException.Create(Translate('Snapshots are not implemented by this core'));
  FEmulation.SaveSnapshot(Name);
  if FLibrary <> nil then
    FLibrary.RefreshSnapshots;
end;

procedure TFormMain.LoadSnapshot(const Name: string);
begin
  if FEmulation = nil then
    raise Exception.Create(Translate('No game loaded'));
  if not FEmulation.SupportsSnapshots then
    raise ENotSupportedException.Create(Translate('Snapshots are not implemented by this core'));
  FEmulation.LoadSnapshot(Name);
  FEmulationFaulted := False;
  SyncActivity;
  if not UpdateFrame then
    LoadSnapshotPreview(Name);
end;

procedure TFormMain.InsertCoinClick(Sender: TObject);
begin
  if (FEmulation = nil) or FEmulationFaulted or FOpeningRom or FViewingLibrary or
    (FSettingsView <> nil) or (FHelp <> nil) or not FEmulation.HasCoinAcceptor then
    Exit;
  FEmulation.InsertCoin1;
end;

procedure TFormMain.UpdatePauseOverlay;
begin
  var Paused := (FEmulation <> nil) and (FUserPaused or FAutoPaused or FEmulation.IsPaused);
  ImageCanvas.Opacity := IfThen(Paused, 0.5, 1);
  LabelPaused.Visible := Paused and not FViewingLibrary and (FHelp = nil) and (FSettingsView = nil);
  if LabelPaused.Visible then
    LabelPaused.BringToFront;
end;

procedure TFormMain.UpdateGameChrome;
begin
  if csDestroying in ComponentState then
    Exit;
  if FGamePlatform <> nil then
  begin
    FGamePlatform.Text := LibrarySystemName(FInputSystemId);
    if FEmulation <> nil then
      FGamePlatform.Text := FEmulation.Name;
  end;
  if FGameStatus <> nil then
  begin
    FGameStatus.Visible := not FullScreen;
    if FEmulation <> nil then
      if FEmulation.Config.AudioEnabled and (FEmulation.Config.AudioVolume > 0) and not FSoundErrorShown then
        FGameAudio.Text := Translate('Audio on')
      else
        FGameAudio.Text := Translate('Audio off');
  end;
  {$IFNDEF ANDROID}
  LayoutHead.Visible := (FLibrary <> nil) and not FullScreen;
  {$ENDIF}
  if FCoinTool <> nil then
  begin
    var WasVisible := FCoinTool.Visible;
    FCoinTool.Visible := (FEmulation <> nil) and FEmulation.HasCoinAcceptor;
    FCoinTool.Enabled := FCoinTool.Visible and not FEmulationFaulted and not FOpeningRom and
      not FViewingLibrary and (FSettingsView = nil) and (FHelp = nil);
    if WasVisible <> FCoinTool.Visible then
      FormResize(Self);
  end;
  if FHelpTool <> nil then
  begin
    FHelpTool.Enabled := (FEmulation <> nil) and not FOpeningRom and not FHelpClosing;
    if FHelp <> nil then
      FHelpTool.StyleLookup := 'buttonstyle_accent'
    else
      FHelpTool.StyleLookup := 'buttonstyle';
    var Color: TAlphaColor := $FFFFB43B;
    if FHelp <> nil then
      Color := $FF1B2026;
    FHelpTool.TextSettings.FontColor := Color;
    for var Child in FHelpTool.Children do
      if Child is FMX.Objects.TPath then
        FMX.Objects.TPath(Child).Stroke.Color := Color;
  end;
  {$IFNDEF ANDROID}
  if FullScreen then
  begin
    // SyncActivity and frame/status updates can make controls visible again.
    // Hide game chrome while retaining the pause overlay.
    for var Child in LayoutClient.Children do
      if (Child is TControl) and (Child <> ImageCanvas) and (Child <> RectangleBG) and (Child <> LabelPaused) then
        TControl(Child).Visible := False;
    ImageLogo.Visible := False;
  end;
  {$ENDIF}
  UpdatePauseOverlay;
end;

procedure TFormMain.ControlsHelpClick(Sender: TObject);
begin
  if FHelp <> nil then
  begin
    ControlsHelpClose(Self);
    Exit;
  end;
  if (FEmulation = nil) or FViewingLibrary or (FSettingsView <> nil) or FOpeningRom or FHelpClosing then
    Exit;
  FHelpWasPaused := FEmulation.IsPaused or FUserPaused or FAutoPaused;
  FHelpFullScreen := FullScreen;
  if FullScreen then
    SwitchFullScreen;
  FormDeactivate(Self);
  FEmulation.Pause;
  var Players := 2;
  if FInputSystemId = 'gb' then
    Players := 1;
  if FInputSystemId = 'gbc' then
    Players := 1;
  if FInputSystemId = 'snes' then
    if FInputPorts.Multitap[1] then
      Players := 8
    else if FInputPorts.Multitap[0] then
      Players := 5;
  if FInputSystemId = 'nes' then
  begin
    var Config: INesEmulatorConfig;
    if Supports(FEmulation.Config, INesEmulatorConfig, Config) and Config.FourScore then
      Players := 4;
  end;
  var Peripheral: INesPeripheralCore;
  var Piano: INesMiraclePianoCore;
  var KeyboardPeripheral := FEmulation.UsesSuborKeyboard or
    (Supports(FEmulation, INesPeripheralCore, Peripheral) and Peripheral.UsesFamicomKeyboard) or
    (Supports(FEmulation, INesMiraclePianoCore, Piano) and Piano.UsesMiraclePiano);
  try
    FHelp := TControlsHelpView.CreateHelp(Self, FInput, FInputSystemId, FInputPorts, Players, KeyboardPeripheral, FStorage, FEmulation.HasCoinAcceptor);
    FHelp.Parent := Self;
    FHelp.Align := TAlignLayout.Contents;
    FHelp.OnClose := ControlsHelpClose;
    FHelp.OnSettings := ControlsHelpSettings;
    FHelp.BringToFront;
  except
    FreeAndNil(FHelp);
    if not FHelpWasPaused then
      FEmulation.Resume;
    if FHelpFullScreen then
      SwitchFullScreen;
    raise;
  end;
  FKeysDown[vkF1] := True;
  SyncActivity;
end;

procedure TFormMain.ControlsHelpClose(Sender: TObject);
begin
  CloseControlsHelp;
end;

procedure TFormMain.ControlsHelpSettings(Sender: TObject);
begin
  CloseControlsHelp(True);
end;

procedure TFormMain.CloseControlsHelp(OpenSettings: Boolean);
begin
  if (FHelp = nil) or FHelpClosing then
    Exit;
  FHelpClosing := True;
  var Alive: TFunc<Boolean> := FCallbackAlive;
  TThread.ForceQueue(nil,
    procedure
    begin
      if not Alive() then
        Exit;
      FreeAndNil(FHelp);
      FHelpClosing := False;
      if (FEmulation <> nil) and not FHelpWasPaused and not FUserPaused and not FAutoPaused and
        not FEmulationFaulted and HostInputHasFocus then
        FEmulation.Resume;
      FSuppressInputUntilRelease := True;
      FillChar(FKeysDown, SizeOf(FKeysDown), 0);
      if OpenSettings then
      begin
        SettingsClick(Self);
        if FSettingsView <> nil then
        begin
          for var I := Low(SettingsCoreIds) to High(SettingsCoreIds) do
            if SettingsCoreIds[I] = FInputSystemId then
              FSettingsView.SelectCore(I);
          FSettingsView.SelectCategory(3);
        end;
      end
      else
      begin
        if FHelpFullScreen and (FEmulation <> nil) and not FViewingLibrary then
          SwitchFullScreen;
        FormActivate(Self);
        LayoutClient.SetFocus;
      end;
      SyncActivity;
    end);
end;

procedure TFormMain.SwitchFullScreen;
begin
  if (FEmulation = nil) or FViewingLibrary or (FSettingsView <> nil) or (FHelp <> nil) then
    Exit;
  {$IFNDEF ANDROID}
  if not FullScreen then
    FFullScreenPadding := Padding.Rect;
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  if not FullScreen then
  begin
    FFullScreenBorderStyle := BorderStyle;
    FFullScreenWindowState := WindowState;
    FFullScreenPlacement := Default(TWindowPlacement);
    FFullScreenPlacement.length := SizeOf(FFullScreenPlacement);
    if not GetWindowPlacement(WindowHandleToPlatform(Handle).Wnd, @FFullScreenPlacement) then
      FFullScreenPlacement.length := 0;
  end;
  {$ENDIF}
  FullScreen := not FullScreen;
  {$IFDEF MSWINDOWS}
  if not FullScreen then
  begin
    // FMX skips restoring the frame when the first fullscreen entry is from
    // a maximized window, because its saved normal size is still empty.
    BorderStyle := FFullScreenBorderStyle;
    WindowState := FFullScreenWindowState;
    // Restoring BorderStyle recreates the HWND. Preserve its normal restore
    // rectangle too, including when fullscreen was entered while maximized.
    if FFullScreenPlacement.length <> 0 then
      SetWindowPlacement(WindowHandleToPlatform(Handle).Wnd, @FFullScreenPlacement);
    UpdateSystemBackdropType;
  end;
  {$ENDIF}
  {$IFNDEF ANDROID}
  if FullScreen then
    Padding.Rect := TRectF.Empty
  else
    Padding.Rect := FFullScreenPadding;
  {$ENDIF}
  LayoutLeft.Visible := (FLibrary = nil) and not FullScreen;
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
  SyncActivity;
  FSuppressInputUntilRelease := True;
  FKeysDown[vkF11] := True;
end;

procedure TFormMain.FormKeyDown(Sender: TObject; var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
begin
  if (FSettingsView <> nil) or FViewingLibrary then
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
    if FHelp <> nil then
    begin
      if Code in [vkEscape, vkF1] then
        ControlsHelpClose(Self);
      Key := 0;
      KeyChar := #0;
      Exit;
    end
    else if Code = vkF1 then
    begin
      ControlsHelpClick(Self);
      Key := 0;
      KeyChar := #0;
      Exit;
    end
    else if (Code = vkEscape) and (FullScreen or not KeyboardActive) then
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
    else if (Code = vkF9) and not KeyboardActive then
      InsertCoinClick(Self)
    else if (Code = vkF8) and (FEmulation <> nil) and not KeyboardActive then
    begin
      try
        SetStatus(Translate('Screenshot: ') + SaveScreenshot);
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
          ShowMessage(Translate('Snapshot: ') + E.Message);
      end;
    end;
  end;
  if (FHelp = nil) and (KeyboardActive or not (ssCtrl in Shift)) then
    if (FEmulation <> nil) and (FInput = nil) then
      ForwardKeyState(Code, True);
  Key := 0;
  KeyChar := #0;
end;

procedure TFormMain.FormKeyUp(Sender: TObject; var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
begin
  if (FSettingsView <> nil) or FViewingLibrary then
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
  if (FHelp = nil) and (FEmulation <> nil) and (FInput = nil) then
    ForwardKeyState(Code, False);
  Key := 0;
  KeyChar := #0;
end;

procedure TFormMain.SwitchPause;
begin
  if (FEmulation = nil) or FEmulationFaulted then
    Exit;

  FAutoPaused := False;
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
      SetStatus(Translate('Input error: ') + E.Message);
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
  UpdatePauseOverlay;
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
  SetStatus(Translate('Stopped after error - ') + FRomDisplayName);
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

procedure TFormMain.LibraryPlay(Sender: TObject);
begin
  if (FLibrary.Selected = nil) or FOpeningRom then
    Exit;
  var Game := FLibrary.Selected;
  var Snapshot := FLibrary.SnapshotName;
  try
    LoadRom(Game.FileInfo.Location, Game.Title, Snapshot <> '');
    if Snapshot <> '' then
      LoadSnapshot(Snapshot);
  except
    on E: Exception do
      TDialogService.ShowMessage(Translate('Unable to open game: ') + E.Message);
  end;
end;

procedure TFormMain.LibraryBack(Sender: TObject);
begin
  if FLibrary = nil then
    Exit;
  FormDeactivate(Self);
  if FEmulation <> nil then
    FEmulation.Pause;
  if FullScreen then
    SwitchFullScreen;
  LayoutLeft.Visible := False;
  LayoutClient.Visible := False;
  FLibrary.Visible := True;
  FLibrary.RefreshSnapshots;
  FLibrary.BringToFront;
  FViewingLibrary := True;
  UpdateGameChrome;
end;

procedure TFormMain.PauseClick(Sender: TObject);
begin
  SwitchPause;
end;

procedure TFormMain.SaveStateClick(Sender: TObject);
begin
  if (FEmulation = nil) or not FEmulation.SupportsSnapshots then
    Exit;
  try
    SaveSnapshot('Quick');
  except
    on E: Exception do
      TDialogService.ShowMessage(E.Message);
  end;
end;

procedure TFormMain.LoadStateClick(Sender: TObject);
begin
  if (FEmulation = nil) or not FEmulation.SupportsSnapshots then
    Exit;
  try
    LoadSnapshot('Quick');
  except
    on E: Exception do
      TDialogService.ShowMessage(E.Message);
  end;
end;

procedure TFormMain.FullscreenClick(Sender: TObject);
begin
  SwitchFullScreen;
end;

procedure TFormMain.LoadRom(const FileName: string; const DisplayName: string; StartPaused: Boolean);
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

  FUserPaused := StartPaused;
  FAutoPaused := False;
  ImageCanvas.DisableInterpolation := SameText(FEmulation.Config.Filter, 'nearest');
  FillChar(FKeysDown, SizeOf(FKeysDown), 0);
  FRomDisplayName := DisplayName;
  if FRomDisplayName = '' then
    FRomDisplayName := ExtractFileName(FileName);
  FSoundErrorShown := False;
  try
    ImageCanvas.Bitmap.Clear(TAlphaColors.Black);
    FEmulationFaulted := False;
    if FUserPaused then
      FEmulation.Pause;
    {$IFDEF ANDROID}
    if FActivityPaused then
      FEmulation.Pause;
    {$ENDIF}
    FEmulation.Start;
    if FLibrary <> nil then
    begin
      var Info: IEmulationSnapshotLocation;
      var Directory := '';
      if Supports(FEmulation, IEmulationSnapshotLocation, Info) then
        Directory := Info.GetSnapshotDirectory;
      FLibrary.RecordSession(FileName, Directory);
      FLibrary.Visible := False;
      LayoutClient.Visible := True;
      LayoutLeft.Visible := False;
      FViewingLibrary := False;
      LayoutClient.SetFocus;
      if FStartFullscreen and not FullScreen then
        SwitchFullScreen;
    end;
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
  FormActivate(Self);
end;

procedure TFormMain.SelectDocument(ForCassette: Boolean);
begin
  if FOpeningRom then
    Exit;
  FOpeningRom := True;
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
    FFileDialog.Title := Translate('Choose a cassette file');
    FFileDialog.Filter := Translate('Cassette (*.tape)|*.tape|All files|*.*');
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
  ShowMessage(Translate('Sound unavailable; the game will continue without audio.') + SLineBreak + MessageText);
end;

procedure TFormMain.LoadSnapshotPreview(const Name: string);
begin
  var Location: IEmulationSnapshotLocation;
  if not Supports(FEmulation, IEmulationSnapshotLocation, Location) then
    Exit;
  var Directory := Location.GetSnapshotDirectory;
  if Directory = '' then
    Exit;
  var Bitmap := FMX.Graphics.TBitmap.Create;
  try
    for var Extension in ['.png', '.bmp'] do
    try
      var Path := TPath.Combine(Directory, Name + Extension);
      if not FStorage.Exists(Path) then
        Continue;
      var Stream := FStorage.OpenRead(Path);
      try
        Bitmap.LoadFromStream(Stream);
      finally
        Stream.Free;
      end;
      if Bitmap.IsEmpty then
        Continue;
      ImageCanvas.Bitmap.Assign(Bitmap);
      ImageCanvas.Repaint;
      Exit;
    except
      // Optional artwork must not prevent a valid game state from loading.
      on E: Exception do
        Continue;
    end;
  finally
    Bitmap.Free;
  end;
end;

function TFormMain.UpdateFrame: Boolean;
begin
  Result := False;
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
    if FGameFPS <> nil then
      FGameFPS.Text := Format('%.1f FPS   ·   %s   ·   %d × %d',
        [Frame.FramesPerSecond, UpperCase(FInputSystemId), Frame.Width, Frame.Height]);
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
    Result := True;
  finally
    ImageCanvas.Bitmap.Unmap(Data);
  end;
  ImageCanvas.Repaint;
end;

procedure TFormMain.DoOnSettingChange;
begin
  StyleBook := FormStyles.StyleBookWinUI3;

  inherited;

  //UpdateSystemBackdropType;
  SystemBackdropType := TWindowBackdropType.Disable;
  Fill.Color := $FF181C21;
  Fill.Kind := TBrushKind.Solid;

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

