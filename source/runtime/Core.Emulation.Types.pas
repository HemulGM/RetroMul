unit Core.Emulation.Types;

interface

uses
  System.UITypes;

{$SCOPEDENUMS ON}

const
  EmulatorMaxPlayers = 12;

type
  // Every frontend supplies the same logical pad.  A core can ignore buttons
  // which do not exist on its hardware.
  TEmulatorButton = (Up, Down, Left, Right, A, B, Select, Start, C, X, Y, Z, Mode);

  TEmulatorButtons = set of TEmulatorButton;

  TEmulatorAnalogPad = record
    Valid: Boolean;
    X, Y: SmallInt; // -32768..32767; zero is centered.
    LeftTrigger, RightTrigger: Byte;
  end;

  TEmulatorInput = record
    Buttons: TEmulatorButtons;
    Buttons3, Buttons4: TEmulatorButtons; // Additional adapter controllers.
    Buttons5, Buttons6, Buttons7, Buttons8: TEmulatorButtons; // SNES Multitap.
    Buttons2: TEmulatorButtons; // Second controller; ignored by single-player cores.
    Buttons9, Buttons10, Buttons11, Buttons12: TEmulatorButtons; // Two Saturn six-player taps.
    Analog: array[0..EmulatorMaxPlayers - 1] of TEmulatorAnalogPad;
  end;

  IEmulatorConfig = interface
    ['{CDB768C2-70EE-4F51-AEFE-C59985CE04C9}']
    function GetAudioEnabled: Boolean;
    procedure SetAudioEnabled(const Value: Boolean);
    function GetAudioVolume: Single;
    procedure SetAudioVolume(const Value: Single);
    function GetFilter: string;
    procedure SetFilter(const Value: string);
    function GetScale: Integer;
    procedure SetScale(const Value: Integer);
    function GetFileName: string;
    procedure Load;
    procedure Save;
    property AudioEnabled: Boolean read GetAudioEnabled write SetAudioEnabled;
    property AudioVolume: Single read GetAudioVolume write SetAudioVolume;
    property Filter: string read GetFilter write SetFilter;
    property Scale: Integer read GetScale write SetScale;
    property FileName: string read GetFileName;
  end;

  // Pixels are premultiplied-alpha ARGB colors in row-major order.
  TEmulatorFrame = record
    Width: Integer;
    Height: Integer;
    Pixels: TArray<TAlphaColor>;
    FrameNumber: UInt64;
    FramesPerSecond: Double;
  end;

  // Device warnings do not stop emulation; frontends may report them once.
  IEmulationAudioDiagnostics = interface
    ['{FB3848EA-CA1B-4D12-A7ED-1D31776921A6}']
    function TakeAudioError: string;
  end;

  // Values are screen-space acceleration in g, including gravity. A missing
  // host sensor supplies zero; sensor input is independent of joypad input.
  // Relative host counts: X right, Y down. Buttons: bit 0 left, 1 right, 2 middle.
  // Frontends call once per input poll. Cores queue deltas; never replay per frame.
  IEmulationMouseInput = interface
    ['{B4BCB7D6-937B-4D82-8A03-B98D2DC22385}']
    procedure SendMouseDelta(DX, DY: Integer; Buttons: Byte);
  end;

  // Absolute aiming for light guns: the host pointer in frame pixels, Valid
  // False when it is off the picture. Frontends call once per input poll
  // while UsesPointer is true (mouse buttons arrive through IEmulationMouseInput).
  IEmulationPointerInput = interface
    ['{5E0B8C2A-3F7D-4A61-9B1E-2C4D8A7F6E30}']
    function GetUsesPointer: Boolean;
    procedure SetPointer(X, Y: Integer; Valid: Boolean);
    property UsesPointer: Boolean read GetUsesPointer;
  end;

  IEmulationMotionInput = interface
    ['{1B7C1D32-86B7-4DCC-BD4B-20B1D41120A7}']
    function GetHasAccelerometer: Boolean;
    procedure SetAcceleration(X, Y: Double);
    property HasAccelerometer: Boolean read GetHasAccelerometer;
  end;

  // Rotation about the screen normal, normalized to 180 degrees per second.
  IEmulationRotationInput = interface
    ['{94335543-B087-4B1B-A26F-5AC933E13A21}']
    function GetHasGyroscope: Boolean;
    procedure SetRotation(Value: Double);
    property HasGyroscope: Boolean read GetHasGyroscope;
  end;

  // Motor duty since the previous read, 0..255; zero while paused/stopped.
  // Reading consumes the accumulated sample. Host effects belong
  // to the frontend; cores never call platform APIs from their worker thread.
  IEmulationRumbleOutput = interface
    ['{01F1B1AF-03D5-4DDE-AFBA-07744CA57D65}']
    function GetHasRumble: Boolean;
    function GetRumbleLevel: Byte;
    property HasRumble: Boolean read GetHasRumble;
    property RumbleLevel: Byte read GetRumbleLevel;
  end;

  // Frontend-thread API. Media changes are applied synchronously by the worker.
  IEmulationDiscControl = interface
    ['{3DC6D68E-C452-4CB1-862F-8FDDC606A9C1}']
    function GetDiscCount: Integer;
    function GetDiscName(Index: Integer): string;
    function GetDiscIndex: Integer; // -1 while the lid is open.
    procedure ChangeDisc(Index: Integer);
    procedure OpenDisc(const Location: string);
    procedure EjectDisc;
  end;

  IEmulationSnapshotLocation = interface
    ['{E6C77DB0-6B7D-43F9-9C16-C9985DA992E9}']
    function GetSnapshotDirectory: string;
  end;

  // Optional, thread-safe metadata for controls actually used by a loaded game.
  // Settings use the platform's complete control set instead.
  IEmulationVirtualControls = interface
    ['{7DB70A11-8A90-4EA4-95E7-586D24CF66A7}']
    function GetVirtualButtons: TEmulatorButtons;
  end;

  // Called on the frontend thread after Config.Load. Workers receive copies
  // under their locks and apply hardware changes at frame boundaries.
  IEmulationLiveSettings = interface
    ['{EF393DA0-69D0-4CEA-86D3-23D9AF0F159E}']
    procedure ApplyLiveSettings;
  end;

  IEmulationCore = interface
    ['{60C5F8B6-85D8-46F5-BA4D-0EC532A7E7F0}']
    function GetName: string;
    function GetSystemId: string;
    function GetSupportsSnapshots: Boolean;
    function GetHasCoinAcceptor: Boolean;
    procedure InsertCoin1;
    procedure InsertCoin2;
    procedure Start;
    procedure Stop;
    procedure Pause;
    procedure Resume;
    procedure Reset;
    procedure ClearInput;
    procedure SetKeyState(Code: UInt32; Pressed: Boolean);
    procedure SetGamepadInput(const Input: TEmulatorInput);
    // Read-only feedback for virtual controls. Call on the frontend thread,
    // just like the input setters; implementations synchronize with workers.
    function GetInputState: TEmulatorInput;
    procedure SaveSnapshot(const Name: string);
    procedure LoadSnapshot(const Name: string);
    function TryGetFrame(out Frame: TEmulatorFrame): Boolean;
    function TakeError: string;
    function GetConfig: IEmulatorConfig;
    property Name: string read GetName;
    property SystemId: string read GetSystemId;
    property SupportsSnapshots: Boolean read GetSupportsSnapshots;
    // Coin methods do nothing when the loaded ROM has no coin acceptor.
    property HasCoinAcceptor: Boolean read GetHasCoinAcceptor;
    property Config: IEmulatorConfig read GetConfig;
    function IsPaused: Boolean;
  end;

implementation

end.

