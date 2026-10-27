unit RM.Main.State;

{$I ..\RM.Mobile.inc}

interface

uses
  System.SysUtils, System.Types, System.UITypes, FMX.Forms, FMX.StdCtrls,
  FMX.Menus, Core.Emulation, Core.Storage, Core.InputConfig, FMX.OpenDialog,
  RM.LibraryView, RM.Settings, RM.ControlsHelp, RM.Input, FMXInput, RM.Rumble,
  RM.Gamepad, SG1000.Keyboard, NES.SuborKeyboard, NES.FamicomKeyboard, NES.MiraclePiano,
  NES.PowerPad, NES.DataRecorder
  {$IFDEF MSWINDOWS}
    , Winapi.Windows
  {$ENDIF}
  {$IF not Defined(LINUX)}
    , System.Sensors.Components
  {$ENDIF}
  {$IFDEF ISMOBILE}
    , FMX.ApplicationEvents
  {$ENDIF}
  {$IFDEF ANDROID}
    , RM.DocumentTransfer.Android
  {$ENDIF};

type
  TMainSessionState = record
    Emulation: IEmulationCore;
    Storage: IStorage;
    FileDialog: TFMXOpenDialog;
    CallbackAlive: TFunc<Boolean>;
    InvalidateCallbacks: TProc;
    SoundErrorShown: Boolean;
    RomDisplayName: string;
    RomLocation: string;
    OpeningRom: Boolean;
    PendingAutosaveChoice: Boolean;
    PreserveOpeningAutosave: Boolean;
    EmulationFaulted: Boolean;
    UserPaused: Boolean;
    AutoPaused: Boolean;
    DialogWasPaused: Boolean;
    DialogCore: IEmulationCore;
    PreviousExceptionHandler: FMX.Forms.TExceptionEvent;
  end;

  TMainBrowserState = record
    View: TLibraryView;
    ViewingLibrary: Boolean;
    ReloadPending: Boolean;
    PendingLanguage: string;
    BackTool, ScreenshotTool, ActionsTool: TButton;
    PanelHidden: Boolean;
    Tools: array[0..4] of TButton;
    ScreenshotMenu, SaveMenu, LoadMenu: TPopupMenu;
    HelpTool, CoinTool: TButton;
    GamePlatform, GameFPS, GameAudio: TLabel;
    GameStatus: TPanel;
    FullScreenPadding: TRectF;
  end;

  TMainPreferencesState = record
    PauseOnFocusLoss, StartFullscreen: Boolean;
  end;

  TMainHelpState = record
    View: TControlsHelpView;
    WasPaused, Closing: Boolean;
  end;

  TMainSettingsState = record
    View: TSettingsView;
    ClientVisible, WasPaused, Closing: Boolean;
    LibraryVisible: Boolean;
  end;

  TMainAutosaveState = record
    OnExit, Periodic: Boolean;
    Minutes: Integer;
    LastTick: UInt64;
  end;

  TMainInputState = record
    Manager: TInputManager;
    Ports: TCoreInputPorts;
    SystemId: string;
    BottomInset: Integer;
    DispatchingInput, SuppressInputUntilRelease, PollingFailed: Boolean;
    Gamepad: TScreenGamepad;
    SuborKeyboard: TNesSuborKeyboard;
    SGKeyboard: TSGKeyboard;
    FamicomKeyboard: TNesFamicomKeyboard;
    MiraclePiano: TNesMiraclePiano;
    PowerPad: TNesPowerPad;
    DataRecorder: TNesDataRecorder;
    Rumble: TRumblePlayer;
    RumbleDeviceId: string;
    GamepadInput: TEmulatorInput;
    KeysDown: array[0..2048] of Boolean;
    ZapperPixel: TPoint;
    {$IF not Defined(LINUX)}
    MotionSensor: TMotionSensor;
    MotionAttempted: Boolean;
    {$ENDIF}
  end;

  TMainWindowState = record
    {$IFDEF MSWINDOWS}
    FullScreenBorderStyle: TFmxFormBorderStyle;
    FullScreenWindowState: TWindowState;
    FullScreenPlacement: TWindowPlacement;
    WindowStateRestored, WindowStateSaved: Boolean;
    {$ENDIF}
  end;

  TMainMobileState = record
    {$IFDEF ISMOBILE}
    AppEvents: TApplicationEvents;
    InBackground, ActivityPaused: Boolean;
    {$ENDIF}
    {$IFDEF ANDROID}
    Transfer: TAndroidDocumentTransfer;
    ChoosingTape: Boolean;
    SuborKeyboardTouchAttached: Boolean;
    SGKeyboardTouchAttached: Boolean;
    FamicomKeyboardTouchAttached: Boolean;
    MiraclePianoTouchAttached: Boolean;
    PowerPadTouchAttached: Boolean;
    {$ENDIF}
  end;

  // Shared data used by controllers; behavior lives in RM.Controllers.*.
  TMainState = class
  public
    Session: TMainSessionState;
    Browser: TMainBrowserState;
    Preferences: TMainPreferencesState;
    Help: TMainHelpState;
    Settings: TMainSettingsState;
    Autosave: TMainAutosaveState;
    Input: TMainInputState;
    Window: TMainWindowState;
    Mobile: TMainMobileState;
  end;

implementation

end.

