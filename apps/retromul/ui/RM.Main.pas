unit RM.Main;

{$I ..\RM.Mobile.inc}

interface

uses
  System.SysUtils, System.Classes, System.Types, System.UITypes, FMX.Types,
  FMX.Platform, FMX.Dialogs, Core.Emulation, Core.Storage, FMXInput,
  NES.FamicomDataRecorder, RM.Main.View, RM.Main.State, RM.Controllers.Browser,
  RM.ShaderBitmap, RM.Controllers.Window, RM.Controllers.Settings, RM.Controllers.Snapshots,
  RM.Controllers.Input, RM.Controllers.Mobile, RM.Controllers.Session, FMX.Menus,
  FMX.Objects, FMX.StdCtrls, FMX.Controls.Presentation, FMX.Layouts,
  FMX.Controls, FMX.TabControl
  {$IF not Defined(LINUX)}
    , System.Sensors
  {$ENDIF}
;

type
  TFormMain = class(TMainView)
  published
    procedure FormActivate(Sender: TObject); override;
    procedure FormResize(Sender: TObject); override;
    procedure FormDeactivate(Sender: TObject); override;
    procedure FormKeyUp(Sender: TObject; var Key: Word; var KeyChar: WideChar; Shift: TShiftState); override;
    procedure FormKeyDown(Sender: TObject; var Key: Word; var KeyChar: WideChar; Shift: TShiftState); override;
    procedure TimerUpdateTimer(Sender: TObject); override;
    procedure ButtonOpenClick(Sender: TObject); override;
    procedure FormSafeAreaChanged(Sender: TObject; const AInsets: TRectF); override;
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean); override;
    procedure LayoutClientClick(Sender: TObject); override;
    procedure LayoutClientDblClick(Sender: TObject); override;
    procedure FormSaveState(Sender: TObject); override;
    procedure ButtonCloseRomClick(Sender: TObject); override;
    procedure ImageCanvasMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Single); override;
    procedure ImageCanvasMouseUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Single); override;
  private
    FBrowserController: TBrowserController;
    FWindowController: TWindowController;
    FSettingsController: TSettingsController;
    FSnapshotsController: TSnapshotsController;
    FInputController: TInputController;
    FMobileController: TMobileController;
    FSessionController: TSessionController;
  public
    procedure PollRumble; override;
    procedure SyncMotionSensor; override;
    procedure PollMotionSensor; override;
    {$IF not Defined(LINUX)}
    procedure ChooseMotionSensor(Sender: TObject; const Sensors: TSensorArray; var ChoseSensorIndex: Integer); override;
    {$ENDIF}
    procedure InitializeLibrary; override;
    procedure InitializeScreenshotTool; override;
    procedure InitializePeripherals; override;
    {$IFDEF ISMOBILE}
    procedure InitializeMobileViews; override;
    {$ENDIF}
    {$IFNDEF ISMOBILE}
    procedure InitializeDesktopViews; override;
    {$ENDIF}
    {$IFDEF ANDROID}
    procedure InitializeAndroidServices; override;
    {$ENDIF}
    procedure Load; override;
    procedure Save; override;
    {$IFDEF MSWINDOWS}
    procedure RestoreWindowState; override;
    procedure SaveWindowState; override;
    {$ENDIF}
    procedure ApplyControlInset; override;
    procedure SetStatus(const Text: string); override;
    procedure SyncActivity; override;
    procedure DialogActivityChanged(Sender: TObject); override;
    procedure ApplicationException(Sender: TObject; E: Exception); override;
    procedure OpenRom; override;
    procedure SelectDocument(ForCassette: Boolean; const FileName: string = ''); override;
    procedure FinishFileSelection; override;
    function CanAcceptRomDrop(const Data: TDragObject): Boolean; override;
    procedure Stop; override;
    procedure StopOnError; override;
    function UpdateFrame: Boolean; override;
    procedure AutosaveOnExit; override;
    procedure PollAutosave; override;
    procedure LibraryPlay(Sender: TObject); override;
    procedure LibraryBack(Sender: TObject); override;
    procedure PauseClick(Sender: TObject); override;
    procedure SwitchPause; override;
    procedure UpdatePauseOverlay; override;
    procedure FullscreenClick(Sender: TObject); override;
    procedure SwitchFullScreen; override;
    procedure UpdateGameChrome; override;
    procedure InsertCoinClick(Sender: TObject); override;
    procedure SettingsClick(Sender: TObject); override;
    procedure SettingsApplied(Sender: TObject); override;
    procedure SettingsClose(Sender: TObject); override;
    procedure ControlsHelpClick(Sender: TObject); override;
    procedure ControlsHelpClose(Sender: TObject); override;
    procedure ControlsHelpSettings(Sender: TObject); override;
    procedure CloseControlsHelp(OpenSettings: Boolean = False); override;
    function GameSnapshotDirectory: string; override;
    procedure LoadSnapshotPreview(const Name: string); override;
    procedure SaveStateClick(Sender: TObject); override;
    procedure LoadStateClick(Sender: TObject); override;
    procedure PrepareGameplayMenu(Sender: TObject); override;
    procedure SaveSnapshotAsClick(Sender: TObject); override;
    procedure OpenSnapshotClick(Sender: TObject); override;
    procedure RecentSnapshotClick(Sender: TObject); override;
    procedure ScreenshotClick(Sender: TObject); override;
    procedure OpenScreenshotFolderClick(Sender: TObject); override;
    procedure LoadHostInput(const SystemId: string); override;
    procedure ReloadHostInputBindings; override;
    procedure PollHostInput; override;
    procedure ForwardKeyState(Code: Word; Pressed: Boolean); override;
    procedure GamepadChanged(Sender: TObject); override;
    function CombinedGamepadInput: TEmulatorInput; override;
    procedure UpdatePeripheralInput; override;
    procedure UpdatePeripheralFeedback; override;
    procedure MiraclePianoChanged(Sender: TObject); override;
    procedure FamicomKeyboardChanged(Sender: TObject); override;
    procedure SuborKeyboardChanged(Sender: TObject); override;
    procedure SuborKeyboardPower(Sender: TObject); override;
    procedure PowerPadChanged(Sender: TObject); override;
    procedure TapeAction(Sender: TObject; Action: TTapeAction; const FileName: string); override;
    procedure ChooseTapeFile(Sender: TObject); override;
    procedure SaveTapeAs(Sender: TObject); override;
    {$IFDEF ISMOBILE}
    function ApplicationStateChanged(Sender: TObject; const AAppEvent: TApplicationEvent; const AContext: TObject): Boolean; override;
    {$ENDIF}
    {$IFDEF ANDROID}
    procedure PollDocumentTransfer; override;
    {$ENDIF}
  protected
    function DetectSystemLanguage: string; override;
    function AutosaveClock: UInt64; override;
    function CreateStorage: IStorage; override;
    function CreateHostInput: TInputManager; override;
    function HostInputHasFocus: Boolean; override;
    procedure ReportAudioError(const MessageText: string); override;
    function CreateCore(const FileName: string): IEmulationCore; override;
    function ExecuteSnapshotDialog(Dialog: TOpenDialog): Boolean; override;
    procedure OpenDirectory(const Directory: string); override;
    procedure DoOnSettingChange; override;
    {$IFDEF MSWINDOWS}
    procedure DoShow; override;
    {$ENDIF}
  public
    procedure KeyDown(var Key: Word; var KeyChar: WideChar; Shift: TShiftState); override;
    procedure DragOver(const Data: TDragObject; const Point: TPointF; var Operation: TDragOperation); override;
    procedure DragDrop(const Data: TDragObject; const Point: TPointF); override;
    procedure SaveSnapshot(const Name: string); override;
    procedure LoadSnapshot(const Name: string); override;
    procedure LoadRom(const FileName: string; const DisplayName: string = ''; StartPaused: Boolean = False; const SnapshotName: string = ''); override;
    procedure ResetConsole(Hard: Boolean); override;
    procedure ResetClick(Sender: TObject); override;
    procedure HardRestart; override;
    procedure SelectTapeFile(const FileName: string); override;
    function SaveScreenshot: string; override;
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  end;

const
  AppName = RM.Main.View.AppName;

var
  FormMain: TFormMain;

implementation

uses
  System.IOUtils, System.Messaging, FMX.Forms, FMX.Graphics, FMX.OpenDialog,
  WinUI3.Form, WinUI3.Style, Core.EmulatorFactory, Core.RomFormat,
  RM.Storage.Dialogs, RM.Dialogs, RM.Styles, RM.Rumble, NES.Consts
  {$IF not Defined(LINUX)}
    , System.Sensors.Components
  {$ENDIF}
  {$IFDEF MSWINDOWS}
    , Winapi.Windows, FMX.Platform.Win, Winapi.ShellAPI
  {$ENDIF}
  {$IF Defined(MACOS) and not Defined(IOS)}
    , Macapi.AppKit, Macapi.Helpers
  {$ENDIF}
  {$IF Defined(LINUX) and not Defined(ANDROID)}
    , Posix.Stdlib
  {$ENDIF};

{$R *.fmx}

constructor TFormMain.Create(AOwner: TComponent);
begin
  FState := TMainState.Create;
  FBrowserController := TBrowserController.Create(Self);
  FWindowController := TWindowController.Create(Self);
  FSettingsController := TSettingsController.Create(Self);
  FSnapshotsController := TSnapshotsController.Create(Self);
  FInputController := TInputController.Create(Self);
  FMobileController := TMobileController.Create(Self);
  FSessionController := TSessionController.Create(Self);
  FormStyles := TFormStyles.Create(Application);
  inherited;
  ImageCanvas := TShaderBitmap.Create(Self);
  ImageCanvas.Name := 'ImageCanvas';
  ImageCanvas.Parent := LayoutVideoOutput.Parent;
  ImageCanvas.Index := LayoutVideoOutput.Index;
  ImageCanvas.Align := TAlignLayout.Client;
  ImageCanvas.OnMouseDown := ImageCanvasMouseDown;
  ImageCanvas.OnMouseUp := ImageCanvasMouseUp;
  ImageLogo.Parent := ImageCanvas;
  LabelPaused.Parent := ImageCanvas;
  FreeAndNil(LayoutVideoOutput);
  // Screen changes are controlled by application state, not swipe gestures.
  SetRetroDialogActivity(Self, DialogActivityChanged);
  State.Session.PreviousExceptionHandler := Application.OnException;
  Application.OnException := ApplicationException;
  ScreenTabs.AniCalculations.TouchTracking := [];
  OnCloseQuery := FormCloseQuery;
  State.Session.Storage := CreateStorage;
  var Alive := True;
  State.Session.CallbackAlive :=
    function: Boolean
    begin
      Result := Alive;
    end;
  State.Session.InvalidateCallbacks :=
    procedure
    begin
      Alive := False;
    end;
  {$IF Defined(MSWINDOWS) or Defined(LINUX) or (Defined(MACOS) and not Defined(IOS))}
  {$IFNDEF ISMOBILE}
  State.Input.Manager := CreateHostInput;
  {$ENDIF}
  {$ENDIF}
  State.Session.FileDialog := TFMXOpenDialog.Create(Self);
  State.Session.FileDialog.MultipleSelection := False;
  InitializeScreenshotTool;
  LayoutClient.CanFocus := True;
  LayoutClient.OnKeyDown := FormKeyDown;
  LayoutClient.OnKeyUp := FormKeyUp;
  LayoutClient.DisableFocusEffect := False;
  LayoutClient.CanParentFocus := True;
  SetStatus('Open ROM');
  {$IFDEF ANDROID}
  InitializeAndroidServices;
  {$ENDIF}
  {$IFDEF ISMOBILE}
  InitializeMobileViews;
  {$ENDIF}
  Fill.Color := TAlphaColors.Black;
  ImageCanvas.WrapMode := TImageWrapMode.Fit;
  ImageCanvas.DisableInterpolation := True;
  ImageCanvas.Bitmap.SetSize(NES_WIDTH, NES_HEIGHT);
  ImageCanvas.Bitmap.Clear(TAlphaColors.Black);
  InitializePeripherals;
  State.Input.Rumble := TRumblePlayer.Create;
  {$IF not Defined(LINUX)}
  State.Input.MotionSensor := TMotionSensor.Create(Self);
  State.Input.MotionSensor.OnSensorChoosing := ChooseMotionSensor;
  {$ENDIF}
  FormResize(Self);
  TimerUpdate.Interval := 8;
  Load;
  LoadHostInput(ROM_SYSTEM_GB);
  InitializeLibrary;
  {$IFNDEF ISMOBILE}
  InitializeDesktopViews;
  {$ENDIF}
  SyncActivity;
end;

procedure TFormMain.InitializeScreenshotTool;
begin
  FBrowserController.InitializeScreenshotTool;
end;

procedure TFormMain.InitializePeripherals;
begin
  FInputController.InitializePeripherals;
end;

procedure TFormMain.InitializeLibrary;
begin
  FBrowserController.InitializeLibrary;
end;

{$IFNDEF ISMOBILE}
procedure TFormMain.InitializeDesktopViews;
begin
  FBrowserController.InitializeDesktopViews;
end;

{$ENDIF}
{$IFDEF ANDROID}
procedure TFormMain.InitializeAndroidServices;
begin
  FMobileController.InitializeAndroidServices;
end;

{$ENDIF}
{$IFDEF ISMOBILE}
procedure TFormMain.InitializeMobileViews;
begin
  FMobileController.InitializeMobileViews;
end;

{$ENDIF}
destructor TFormMain.Destroy;
begin
  if TMethod(Application.OnException).Data = Self then
    Application.OnException := State.Session.PreviousExceptionHandler;
  {$IFDEF MSWINDOWS}
  if State.Window.WindowStateRestored and not State.Window.WindowStateSaved then
  try
    SaveWindowState;
  except
    Application.HandleException(Self);
  end;
  {$ENDIF}
  if Assigned(State.Session.InvalidateCallbacks) then
    State.Session.InvalidateCallbacks();
  FreeAndNil(State.Input.Rumble);
  if TimerUpdate <> nil then
    TimerUpdate.Enabled := False;
  try
    AutosaveOnExit;
  except
    Application.HandleException(Self);
  end;
  FreeAndNil(State.Settings.View);
  FreeAndNil(State.Help.View);
  FreeAndNil(State.Browser.View);
  {$IF not Defined(LINUX)}
  if State.Input.MotionSensor <> nil then
  try
    State.Input.MotionSensor.Active := False;
  except
  end;
  FreeAndNil(State.Input.MotionSensor);
  {$ENDIF}
  FreeAndNil(State.Input.Manager);
  FreeAndNil(State.Input.SuborKeyboard);
  FreeAndNil(State.Input.SGKeyboard);
  FreeAndNil(State.Input.FamicomKeyboard);
  FreeAndNil(State.Input.MiraclePiano);
  FreeAndNil(State.Input.PowerPad);
  FreeAndNil(State.Input.DataRecorder);
  FreeAndNil(State.Input.Gamepad); // Detach the native listener before destroying the form.
  {$IFDEF ISMOBILE}
  FreeAndNil(State.Mobile.AppEvents);
  {$ENDIF}
  {$IFDEF ANDROID}
  FreeAndNil(State.Mobile.Transfer);
  {$ENDIF}
  if State.Session.Emulation <> nil then
  try
    State.Session.Emulation.Stop;
  except
    Application.HandleException(Self);
  end;
  State.Session.Emulation := nil;
  try
    inherited;
  finally
    FreeAndNil(FSessionController);
    FreeAndNil(FMobileController);
    FreeAndNil(FInputController);
    FreeAndNil(FSnapshotsController);
    FreeAndNil(FSettingsController);
    FreeAndNil(FWindowController);
    FreeAndNil(FBrowserController);
    FreeAndNil(FState);
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

function TFormMain.DetectSystemLanguage: string;
begin
  Result := 'en';
  var Locale: IFMXLocaleService;
  if TPlatformServices.Current.SupportsPlatformService(IFMXLocaleService, Locale) then
    Result := Locale.GetCurrentLangID;
end;

procedure TFormMain.Load;
begin
  FSettingsController.Load;
end;

procedure TFormMain.Save;
begin
  FSettingsController.Save;
end;

procedure TFormMain.DoOnSettingChange;
begin
  StyleBook := FormStyles.StyleBookWinUI3;

  inherited;

  SystemBackdropType := TWindowBackdropType.Disable;
  Fill.Color := $FF181C21;
  Fill.Kind := TBrushKind.Solid;

  TMessageManager.DefaultManager.SendMessage(Self, TStyleChangedMessage.Create(StyleBook, Self), True);
  TMessageManager.DefaultManager.SendMessage(Self, TInternalSettingChangedMessage.Create(StyleBook, Self), True);
end;

{$IFDEF MSWINDOWS}
procedure TFormMain.DoShow;
begin
  // Apply once, after FMX has positioned and created the native window.
  if not State.Window.WindowStateRestored then
  begin
    State.Window.WindowStateRestored := True;
    RestoreWindowState;
  end;
  inherited;
end;

{$ENDIF}
{$IFDEF MSWINDOWS}
procedure TFormMain.RestoreWindowState;
begin
  FWindowController.RestoreWindowState;
end;

{$ENDIF}
{$IFDEF MSWINDOWS}
procedure TFormMain.SaveWindowState;
begin
  FWindowController.SaveWindowState;
end;

{$ENDIF}
procedure TFormMain.FormResize(Sender: TObject);
begin
  FWindowController.FormResize(Sender);
end;

procedure TFormMain.ApplyControlInset;
begin
  FWindowController.ApplyControlInset;
end;

procedure TFormMain.FormSafeAreaChanged(Sender: TObject; const AInsets: TRectF);
begin
  FWindowController.FormSafeAreaChanged(Sender, AInsets);
end;

procedure TFormMain.FormActivate(Sender: TObject);
begin
  FSessionController.FormActivate(Sender);
end;

procedure TFormMain.FormDeactivate(Sender: TObject);
begin
  FSessionController.FormDeactivate(Sender);
end;

function TFormMain.HostInputHasFocus: Boolean;
begin
  Result := Active and not RetroDialogVisible(Self);
end;

procedure TFormMain.ApplicationException(Sender: TObject; E: Exception);
begin
  FSessionController.ApplicationException(Sender, E);
end;

procedure TFormMain.DialogActivityChanged(Sender: TObject);
begin
  FSessionController.DialogActivityChanged(Sender);
end;

procedure TFormMain.SetStatus(const Text: string);
begin
  FBrowserController.SetStatus(Text);
end;

procedure TFormMain.SyncActivity;
begin
  FSessionController.SyncActivity;
end;

procedure TFormMain.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  FSessionController.FormCloseQuery(Sender, CanClose);
end;

procedure TFormMain.FormSaveState(Sender: TObject);
begin
  FSessionController.FormSaveState(Sender);
end;

procedure TFormMain.ButtonOpenClick(Sender: TObject);
begin
  FSessionController.ButtonOpenClick(Sender);
end;

procedure TFormMain.OpenRom;
begin
  FSessionController.OpenRom;
end;

procedure TFormMain.SelectDocument(ForCassette: Boolean; const FileName: string);
begin
  FSessionController.SelectDocument(ForCassette, FileName);
end;

procedure TFormMain.FinishFileSelection;
begin
  FSessionController.FinishFileSelection;
end;

function TFormMain.CanAcceptRomDrop(const Data: TDragObject): Boolean;
begin
  Result := FSessionController.CanAcceptRomDrop(Data);
end;

procedure TFormMain.DragOver(const Data: TDragObject; const Point: TPointF; var Operation: TDragOperation);
begin
  if Length(Data.Files) = 0 then
  begin
    inherited;
    Exit;
  end;
  // Handle file drags at form level so child controls cannot consume the ROM.
  Operation := TDragOperation.None;
  if CanAcceptRomDrop(Data) then
    Operation := TDragOperation.Copy;
end;

procedure TFormMain.DragDrop(const Data: TDragObject; const Point: TPointF);
begin
  if Length(Data.Files) = 0 then
  begin
    inherited;
    Exit;
  end;
  if not CanAcceptRomDrop(Data) then
    Exit;
  try
    SelectDocument(False, Data.Files[0]);
  except
    on E: Exception do
    begin
      FinishFileSelection;
      ShowRetroMessage(Self, E.Message);
    end;
  end;
end;

function TFormMain.CreateCore(const FileName: string): IEmulationCore;
begin
  var Stream := State.Session.Storage.OpenRead(FileName);
  try
    Result := CreateEmulationCore(Stream, State.Session.Storage, FileName);
  finally
    Stream.Free;
  end;
end;

procedure TFormMain.ResetConsole(Hard: Boolean);
begin
  FSessionController.ResetConsole(Hard);
end;

procedure TFormMain.ResetClick(Sender: TObject);
begin
  {$IFDEF MSWINDOWS}
  var Hard := Winapi.Windows.GetKeyState(vkShift) < 0;
  {$ELSE}
  var Hard := State.Input.KeysDown[vkShift] or State.Input.KeysDown[vkLShift] or State.Input.KeysDown[vkRShift];
  {$ENDIF}
  ResetConsole(Hard);
end;

procedure TFormMain.HardRestart;
begin
  FSessionController.HardRestart;
end;

procedure TFormMain.LoadRom(const FileName: string; const DisplayName: string; StartPaused: Boolean; const SnapshotName: string);
begin
  FSessionController.LoadRom(FileName, DisplayName, StartPaused, SnapshotName);
end;

procedure TFormMain.ButtonCloseRomClick(Sender: TObject);
begin
  FSessionController.ButtonCloseRomClick(Sender);
end;

procedure TFormMain.Stop;
begin
  FSessionController.Stop;
end;

procedure TFormMain.StopOnError;
begin
  FSessionController.StopOnError;
end;

{$IF not Defined(LINUX)}
procedure TFormMain.ChooseMotionSensor(Sender: TObject; const Sensors: TSensorArray; var ChoseSensorIndex: Integer);
begin
  FInputController.ChooseMotionSensor(Sender, Sensors, ChoseSensorIndex);
end;

{$ENDIF}
procedure TFormMain.SyncMotionSensor;
begin
  FInputController.SyncMotionSensor;
end;

procedure TFormMain.PollMotionSensor;
begin
  FInputController.PollMotionSensor;
end;

procedure TFormMain.PollRumble;
begin
  FInputController.PollRumble;
end;

procedure TFormMain.TimerUpdateTimer(Sender: TObject);
begin
  FSessionController.TimerUpdateTimer(Sender);
end;

function TFormMain.UpdateFrame: Boolean;
begin
  Result := FSessionController.UpdateFrame;
end;

procedure TFormMain.ReportAudioError(const MessageText: string);
begin
  ShowRetroMessage(Self, Translate('Sound unavailable; the game will continue without audio.') + SLineBreak + MessageText, TRetroDialogKind.Warning);
end;

function TFormMain.AutosaveClock: UInt64;
begin
  Result := TThread.GetTickCount64;
end;

procedure TFormMain.AutosaveOnExit;
begin
  FSnapshotsController.AutosaveOnExit;
end;

procedure TFormMain.PollAutosave;
begin
  FSnapshotsController.PollAutosave;
end;

procedure TFormMain.LibraryPlay(Sender: TObject);
begin
  FBrowserController.LibraryPlay(Sender);
end;

procedure TFormMain.LibraryBack(Sender: TObject);
begin
  FBrowserController.LibraryBack(Sender);
end;

procedure TFormMain.PauseClick(Sender: TObject);
begin
  FSessionController.PauseClick(Sender);
end;

procedure TFormMain.SwitchPause;
begin
  FSessionController.SwitchPause;
end;

procedure TFormMain.UpdatePauseOverlay;
begin
  FSessionController.UpdatePauseOverlay;
end;

procedure TFormMain.FullscreenClick(Sender: TObject);
begin
  FWindowController.FullscreenClick(Sender);
end;

procedure TFormMain.SwitchFullScreen;
begin
  FWindowController.SwitchFullScreen;
end;

procedure TFormMain.UpdateGameChrome;
begin
  FBrowserController.UpdateGameChrome;
end;

procedure TFormMain.InsertCoinClick(Sender: TObject);
begin
  FSessionController.InsertCoinClick(Sender);
end;

procedure TFormMain.LayoutClientClick(Sender: TObject);
begin
  FBrowserController.LayoutClientClick(Sender);
end;

procedure TFormMain.LayoutClientDblClick(Sender: TObject);
begin
  FBrowserController.LayoutClientDblClick(Sender);
end;

procedure TFormMain.SettingsClick(Sender: TObject);
begin
  FSettingsController.SettingsClick(Sender);
end;

procedure TFormMain.SettingsApplied(Sender: TObject);
begin
  FSettingsController.SettingsApplied(Sender);
end;

procedure TFormMain.SettingsClose(Sender: TObject);
begin
  FSettingsController.SettingsClose(Sender);
end;

procedure TFormMain.ControlsHelpClick(Sender: TObject);
begin
  FSettingsController.ControlsHelpClick(Sender);
end;

procedure TFormMain.ControlsHelpClose(Sender: TObject);
begin
  FSettingsController.ControlsHelpClose(Sender);
end;

procedure TFormMain.ControlsHelpSettings(Sender: TObject);
begin
  FSettingsController.ControlsHelpSettings(Sender);
end;

procedure TFormMain.CloseControlsHelp(OpenSettings: Boolean);
begin
  FSettingsController.CloseControlsHelp(OpenSettings);
end;

function TFormMain.GameSnapshotDirectory: string;
begin
  Result := FSnapshotsController.GameSnapshotDirectory;
end;

procedure TFormMain.SaveSnapshot(const Name: string);
begin
  FSnapshotsController.SaveSnapshot(Name);
end;

procedure TFormMain.LoadSnapshot(const Name: string);
begin
  FSnapshotsController.LoadSnapshot(Name);
end;

procedure TFormMain.LoadSnapshotPreview(const Name: string);
begin
  FSnapshotsController.LoadSnapshotPreview(Name);
end;

procedure TFormMain.SaveStateClick(Sender: TObject);
begin
  FSnapshotsController.SaveStateClick(Sender);
end;

procedure TFormMain.LoadStateClick(Sender: TObject);
begin
  FSnapshotsController.LoadStateClick(Sender);
end;

procedure TFormMain.PrepareGameplayMenu(Sender: TObject);
begin
  FSnapshotsController.PrepareGameplayMenu(Sender);
end;

function TFormMain.ExecuteSnapshotDialog(Dialog: TOpenDialog): Boolean;
begin
  Result := Dialog.Execute;
end;

procedure TFormMain.SaveSnapshotAsClick(Sender: TObject);
begin
  FSnapshotsController.SaveSnapshotAsClick(Sender);
end;

procedure TFormMain.OpenSnapshotClick(Sender: TObject);
begin
  FSnapshotsController.OpenSnapshotClick(Sender);
end;

procedure TFormMain.RecentSnapshotClick(Sender: TObject);
begin
  FSnapshotsController.RecentSnapshotClick(Sender);
end;

procedure TFormMain.ScreenshotClick(Sender: TObject);
begin
  FSnapshotsController.ScreenshotClick(Sender);
end;

function TFormMain.SaveScreenshot: string;
begin
  Result := FSnapshotsController.SaveScreenshot;
end;

procedure TFormMain.OpenScreenshotFolderClick(Sender: TObject);
begin
  FSnapshotsController.OpenScreenshotFolderClick(Sender);
end;

procedure TFormMain.OpenDirectory(const Directory: string);
begin
  {$IFDEF MSWINDOWS}
  if NativeInt(ShellExecute(0, 'open', PChar(Directory), nil, nil, SW_SHOWNORMAL)) > 32 then
    Exit;
  {$ENDIF}
  {$IF Defined(MACOS) and not Defined(IOS)}
  if TNSWorkspace.Wrap(TNSWorkspace.OCClass.sharedWorkspace).openFile(StrToNSStr(Directory)) then
    Exit;
  {$ENDIF}
  {$IF Defined(LINUX) and not Defined(ANDROID)}
  var Quoted := #39 + Directory.Replace(#39, #39 + '"' + #39 + '"' + #39) + #39;
  if Posix.Stdlib._system(PAnsiChar(UTF8String('xdg-open ' + Quoted))) = 0 then
    Exit;
  {$ENDIF}
  raise EInOutError.Create(Translate('Cannot open screenshot folder'));
end;

procedure TFormMain.LoadHostInput(const SystemId: string);
begin
  FInputController.LoadHostInput(SystemId);
end;

procedure TFormMain.ReloadHostInputBindings;
begin
  FInputController.ReloadHostInputBindings;
end;

procedure TFormMain.PollHostInput;
begin
  FInputController.PollHostInput;
end;

procedure TFormMain.KeyDown(var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
begin
  {$IFDEF ANDROID}
  // Handle Back on key-up, so the same press cannot also close settings.
  if RetroDialogVisible(Self) and (Key = vkHardwareBack) then
  begin
    Key := 0;
    KeyChar := #0;
    Exit;
  end;
  {$ENDIF}
  if HandleRetroDialogKey(Self, Key, KeyChar) then
  begin
    if Key = vkTab then
      inherited;
    Exit;
  end;
  // Intercept before FMX dispatches to focused controls and handles Tab.
  if (State.Settings.View <> nil) and State.Settings.View.HandleCaptureKeyDown(Key, KeyChar) then
    Exit;
  inherited;
end;

procedure TFormMain.FormKeyDown(Sender: TObject; var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
begin
  FInputController.FormKeyDown(Sender, Key, KeyChar, Shift);
end;

procedure TFormMain.FormKeyUp(Sender: TObject; var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
begin
  FInputController.FormKeyUp(Sender, Key, KeyChar, Shift);
end;

procedure TFormMain.ForwardKeyState(Code: Word; Pressed: Boolean);
begin
  FInputController.ForwardKeyState(Code, Pressed);
end;

procedure TFormMain.GamepadChanged(Sender: TObject);
begin
  FInputController.GamepadChanged(Sender);
end;

function TFormMain.CombinedGamepadInput: TEmulatorInput;
begin
  Result := FInputController.CombinedGamepadInput;
end;

procedure TFormMain.UpdatePeripheralInput;
begin
  FInputController.UpdatePeripheralInput;
end;

procedure TFormMain.UpdatePeripheralFeedback;
begin
  FInputController.UpdatePeripheralFeedback;
end;

procedure TFormMain.ImageCanvasMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Single);
begin
  FInputController.ImageCanvasMouseDown(Sender, Button, Shift, X, Y);
end;

procedure TFormMain.ImageCanvasMouseUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Single);
begin
  FInputController.ImageCanvasMouseUp(Sender, Button, Shift, X, Y);
end;

procedure TFormMain.MiraclePianoChanged(Sender: TObject);
begin
  FInputController.MiraclePianoChanged(Sender);
end;

procedure TFormMain.FamicomKeyboardChanged(Sender: TObject);
begin
  FInputController.FamicomKeyboardChanged(Sender);
end;

procedure TFormMain.SuborKeyboardChanged(Sender: TObject);
begin
  FInputController.SuborKeyboardChanged(Sender);
end;

procedure TFormMain.SuborKeyboardPower(Sender: TObject);
begin
  FInputController.SuborKeyboardPower(Sender);
end;

procedure TFormMain.PowerPadChanged(Sender: TObject);
begin
  FInputController.PowerPadChanged(Sender);
end;

procedure TFormMain.TapeAction(Sender: TObject; Action: TTapeAction; const FileName: string);
begin
  FInputController.TapeAction(Sender, Action, FileName);
end;

procedure TFormMain.SelectTapeFile(const FileName: string);
begin
  FInputController.SelectTapeFile(FileName);
end;

procedure TFormMain.ChooseTapeFile(Sender: TObject);
begin
  FInputController.ChooseTapeFile(Sender);
end;

procedure TFormMain.SaveTapeAs(Sender: TObject);
begin
  FInputController.SaveTapeAs(Sender);
end;

{$IFDEF ISMOBILE}
function TFormMain.ApplicationStateChanged(Sender: TObject; const AAppEvent: TApplicationEvent; const AContext: TObject): Boolean;
begin
  Result := FMobileController.ApplicationStateChanged(Sender, AAppEvent, AContext);
end;

{$ENDIF}
{$IFDEF ANDROID}
procedure TFormMain.PollDocumentTransfer;
begin
  FMobileController.PollDocumentTransfer;
end;
{$ENDIF}

end.

