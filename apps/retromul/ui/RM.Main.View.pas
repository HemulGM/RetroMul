unit RM.Main.View;

{$I ..\RM.Mobile.inc}

interface

uses
  System.SysUtils, System.Classes, System.Types, System.UITypes, FMX.Types,
  FMX.Controls, FMX.Forms, FMX.TabControl, FMX.Objects, FMX.StdCtrls,
  FMX.Layouts, FMX.Menus, FMX.Dialogs, WinUI3.Form, Core.Emulation, Core.Storage,
  RM.ShaderBitmap, RM.Input, FMXInput, RM.Main.State
  {$IF not Defined(LINUX)}
    , System.Sensors
  {$ENDIF}
  {$IFDEF ISMOBILE}
    , FMX.Platform
  {$ENDIF};

type
  // Form contract shared by controllers, with no dependency on RM.Main.
  TMainView = class(TWinUIForm)
  protected
    FState: TMainState;
    function DetectSystemLanguage: string; virtual; abstract;
    function AutosaveClock: UInt64; virtual; abstract;
    function CreateStorage: IStorage; virtual; abstract;
    function CreateHostInput: TInputManager; virtual; abstract;
    function HostInputHasFocus: Boolean; virtual; abstract;
    procedure ReportAudioError(const MessageText: string); virtual; abstract;
    function CreateCore(const FileName: string): IEmulationCore; virtual; abstract;
    function ExecuteSnapshotDialog(Dialog: TOpenDialog): Boolean; virtual; abstract;
    procedure OpenDirectory(const Directory: string); virtual; abstract;
  published
    GameActionsButton, ButtonHidePanel, ButtonShowPanel: TButton;
    LayoutShowPanel: TLayout;
    GameActionsMenu, ScreenshotMenu, SaveSnapshotMenu, LoadSnapshotMenu: TPopupMenu;
    GameActionsPopup: TPopup;
    GameActionsItems: TLayout;
    GameActionsScroll: TVertScrollBox;
    GameActionsBack: TButton;
    ScreenTabs: TTabControl;
    LibraryScreen: TTabItem;
    GameScreen: TTabItem;
    SettingsScreen: TTabItem;
    ButtonLibrary: TButton;
    GamePause: TButton;
    ButtonReset: TButton;
    GamePauseIcon: TPath;
    GameResumeIcon: TPath;
    GameFullscreen: TButton;
    GameSettings: TButton;
    GameInsertCoin: TButton;
    GameControlsHelp: TButton;
    GameStatus: TPanel;
    StatusDot: TCircle;
    GamePlatform: TLabel;
    GameFPS: TLabel;
    GameAudio: TLabel;
    LayoutVideoOutput: TLayout;
    TimerUpdate: TTimer;
    ImageLogo: TImage;
    RectangleBG: TRectangle;
    LayoutClient: TLayout;
    LabelPaused: TLabel;
    ImageNoBox: TImage;
    LayoutHead: TLayout;
    LabelStatus: TLabel;
    ButtonCloseRom: TButton;
  public
    ImageCanvas: TShaderBitmap;
    function SystemLanguage: string;
    function CurrentTick: UInt64;
    function NewStorage: IStorage;
    function NewHostInput: TInputManager;
    function InputHasFocus: Boolean;
    procedure ShowAudioError(const MessageText: string);
    function NewCore(const FileName: string): IEmulationCore;
    function RunSnapshotDialog(Dialog: TOpenDialog): Boolean;
    procedure ShowDirectory(const Directory: string);
    property State: TMainState read FState;
    procedure FormActivate(Sender: TObject); virtual; abstract;
    procedure FormResize(Sender: TObject); virtual; abstract;
    procedure FormDeactivate(Sender: TObject); virtual; abstract;
    procedure FormKeyUp(Sender: TObject; var Key: Word; var KeyChar: WideChar; Shift: TShiftState); virtual; abstract;
    procedure FormKeyDown(Sender: TObject; var Key: Word; var KeyChar: WideChar; Shift: TShiftState); virtual; abstract;
    procedure TimerUpdateTimer(Sender: TObject); virtual; abstract;
    procedure ButtonOpenClick(Sender: TObject); virtual; abstract;
    procedure FormSafeAreaChanged(Sender: TObject; const AInsets: TRectF); virtual; abstract;
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean); virtual; abstract;
    procedure LayoutClientClick(Sender: TObject); virtual; abstract;
    procedure LayoutClientDblClick(Sender: TObject); virtual; abstract;
    procedure FormSaveState(Sender: TObject); virtual; abstract;
    procedure ButtonCloseRomClick(Sender: TObject); virtual; abstract;
    procedure ImageCanvasMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Single); virtual; abstract;
    procedure ImageCanvasMouseUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Single); virtual; abstract;
    procedure PollRumble; virtual; abstract;
    procedure SyncMotionSensor; virtual; abstract;
    procedure PollMotionSensor; virtual; abstract;
    {$IF not Defined(LINUX)}
    procedure ChooseMotionSensor(Sender: TObject; const Sensors: TSensorArray; var ChoseSensorIndex: Integer); virtual; abstract;
    {$ENDIF}
    procedure InitializeLibrary; virtual; abstract;
    procedure InitializeScreenshotTool; virtual; abstract;
    procedure InitializePeripherals; virtual; abstract;
    {$IFDEF ISMOBILE}
    procedure InitializeMobileViews; virtual; abstract;
    {$ENDIF}
    {$IFNDEF ISMOBILE}
    procedure InitializeDesktopViews; virtual; abstract;
    {$ENDIF}
    {$IFDEF ANDROID}
    procedure InitializeAndroidServices; virtual; abstract;
    {$ENDIF}
    procedure Load; virtual; abstract;
    procedure Save; virtual; abstract;
    {$IFDEF MSWINDOWS}
    procedure RestoreWindowState; virtual; abstract;
    {$ENDIF}
    {$IFDEF MSWINDOWS}
    procedure SaveWindowState; virtual; abstract;
    {$ENDIF}
    procedure ApplyControlInset; virtual; abstract;
    procedure SetStatus(const Text: string); virtual; abstract;
    procedure SyncActivity; virtual; abstract;
    procedure DialogActivityChanged(Sender: TObject); virtual; abstract;
    procedure ApplicationException(Sender: TObject; E: Exception); virtual; abstract;
    procedure OpenRom; virtual; abstract;
    procedure SelectDocument(ForCassette: Boolean; const FileName: string = ''); virtual; abstract;
    procedure FinishFileSelection; virtual; abstract;
    function CanAcceptRomDrop(const Data: TDragObject): Boolean; virtual; abstract;
    procedure Stop; virtual; abstract;
    procedure StopOnError; virtual; abstract;
    function UpdateFrame: Boolean; virtual; abstract;
    procedure AutosaveOnExit; virtual; abstract;
    procedure PollAutosave; virtual; abstract;
    procedure LibraryPlay(Sender: TObject); virtual; abstract;
    procedure LibraryBack(Sender: TObject); virtual; abstract;
    procedure PauseClick(Sender: TObject); virtual; abstract;
    procedure SwitchPause; virtual; abstract;
    procedure UpdatePauseOverlay; virtual; abstract;
    procedure FullscreenClick(Sender: TObject); virtual; abstract;
    procedure SwitchFullScreen; virtual; abstract;
    procedure UpdateGameChrome; virtual; abstract;
    procedure InsertCoinClick(Sender: TObject); virtual; abstract;
    procedure SettingsClick(Sender: TObject); virtual; abstract;
    procedure SettingsApplied(Sender: TObject); virtual; abstract;
    procedure SettingsClose(Sender: TObject); virtual; abstract;
    procedure ControlsHelpClick(Sender: TObject); virtual; abstract;
    procedure ControlsHelpClose(Sender: TObject); virtual; abstract;
    procedure ControlsHelpSettings(Sender: TObject); virtual; abstract;
    procedure CloseControlsHelp(OpenSettings: Boolean = False); virtual; abstract;
    function GameSnapshotDirectory: string; virtual; abstract;
    procedure LoadSnapshotPreview(const Name: string); virtual; abstract;
    procedure SaveStateClick(Sender: TObject); virtual; abstract;
    procedure LoadStateClick(Sender: TObject); virtual; abstract;
    procedure PrepareGameplayMenu(Sender: TObject); virtual; abstract;
    procedure SaveSnapshotAsClick(Sender: TObject); virtual; abstract;
    procedure OpenSnapshotClick(Sender: TObject); virtual; abstract;
    procedure RecentSnapshotClick(Sender: TObject); virtual; abstract;
    procedure ScreenshotClick(Sender: TObject); virtual; abstract;
    procedure OpenScreenshotFolderClick(Sender: TObject); virtual; abstract;
    procedure LoadHostInput(const SystemId: string); virtual; abstract;
    procedure ReloadHostInputBindings; virtual; abstract;
    procedure PollHostInput; virtual; abstract;
    procedure ForwardKeyState(Code: Word; Pressed: Boolean); virtual; abstract;
    procedure GamepadChanged(Sender: TObject); virtual; abstract;
    function CombinedGamepadInput: TEmulatorInput; virtual; abstract;
    procedure UpdatePeripheralInput; virtual; abstract;
    procedure UpdatePeripheralFeedback; virtual; abstract;
    {$IFDEF ISMOBILE}
    function ApplicationStateChanged(Sender: TObject; const AAppEvent: TApplicationEvent; const AContext: TObject): Boolean; virtual; abstract;
    {$ENDIF}
    {$IFDEF ANDROID}
    procedure PollDocumentTransfer; virtual; abstract;
    {$ENDIF}
    procedure SaveSnapshot(const Name: string); virtual; abstract;
    procedure LoadSnapshot(const Name: string); virtual; abstract;
    procedure LoadRom(const FileName: string; const DisplayName: string = ''; StartPaused: Boolean = False; const SnapshotName: string = ''); virtual; abstract;
    procedure ResetConsole(Hard: Boolean); virtual; abstract;
    procedure ResetClick(Sender: TObject); virtual; abstract;
    procedure HardRestart; virtual; abstract;
    procedure SelectTapeFile(const FileName: string); virtual; abstract;
    function SaveScreenshot: string; virtual; abstract;
  end;

const
  AppName = 'RetroMul';

implementation

function TMainView.SystemLanguage: string;
begin
  Result := DetectSystemLanguage;
end;

function TMainView.CurrentTick: UInt64;
begin
  Result := AutosaveClock;
end;

function TMainView.NewStorage: IStorage;
begin
  Result := CreateStorage;
end;

function TMainView.NewHostInput: TInputManager;
begin
  Result := CreateHostInput;
end;

function TMainView.InputHasFocus: Boolean;
begin
  Result := HostInputHasFocus;
end;

procedure TMainView.ShowAudioError(const MessageText: string);
begin
  ReportAudioError(MessageText);
end;

function TMainView.NewCore(const FileName: string): IEmulationCore;
begin
  Result := CreateCore(FileName);
end;

function TMainView.RunSnapshotDialog(Dialog: TOpenDialog): Boolean;
begin
  Result := ExecuteSnapshotDialog(Dialog);
end;

procedure TMainView.ShowDirectory(const Directory: string);
begin
  OpenDirectory(Directory);
end;

end.

