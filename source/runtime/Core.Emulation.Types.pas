unit Core.Emulation.Types;

interface

uses
  System.Classes, System.SysUtils, System.UITypes, System.Types,
  Core.RomMetadata;

{$SCOPEDENUMS ON}

const
  EmulatorMaxPlayers = 12;

type
  IEmulationRomMetadata = interface
    ['{EA16F7EE-6D7B-410D-96ED-0F0F05EAFC59}']
    function GetRomMetadata: IRomMetadata;
    property RomMetadata: IRomMetadata read GetRomMetadata;
  end;

  // Every frontend supplies the same logical pad.  A core can ignore buttons
  // which do not exist on its hardware.
  TEmulatorButton = (Up, Down, Left, Right, A, B, Select, Start, C, X, Y, Z, Mode);

  TEmulatorButtons = set of TEmulatorButton;

  TEmulatorAnalogPad = record
    Valid: Boolean;
    X, Y: SmallInt; // -32768..32767; zero is centered.
    LeftTrigger, RightTrigger: Byte;
  end;

  TEmulatorAnalogButtons = record
    Valid, Digital, Axes: TEmulatorButtons;
    Values: array[TEmulatorButton] of Byte;
  end;

  TEmulatorInput = record
    Buttons: TEmulatorButtons;
    Buttons3, Buttons4: TEmulatorButtons; // Additional adapter controllers.
    Buttons5, Buttons6, Buttons7, Buttons8: TEmulatorButtons; // SNES Multitap.
    Buttons2: TEmulatorButtons; // Second controller; ignored by single-player cores.
    Buttons9, Buttons10, Buttons11, Buttons12: TEmulatorButtons; // Two Saturn six-player taps.
    Analog: array[0..EmulatorMaxPlayers - 1] of TEmulatorAnalogPad;
    // Optional analog travel of digital bindings. Binary pad bits stay instant.
    AnalogButtons: array[0..EmulatorMaxPlayers - 1] of TEmulatorAnalogButtons;
    // Keyboard/on-screen commands are relative steering; real bindings stay absolute.
    RelativeButtons: array[0..EmulatorMaxPlayers - 1] of TEmulatorButtons;
    SteeringAutoCenter: Boolean;
    function PortButtons(Port: Integer): TEmulatorButtons;
    function ButtonAmount(Port: Integer; Button: TEmulatorButton): Single;
    function DigitalButton(Port: Integer; Button: TEmulatorButton): Boolean;
    procedure AliasButton(Source, Target: TEmulatorButton);
    class function LegacySize: Integer; static;
    class function TravelSize: Integer; static;
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

  // Settings UI can switch an existing core between platform and game files.
  IEmulatorConfigLocation = interface
    ['{22F96BD2-263D-4D2B-B017-033873289FEA}']
    procedure SetConfigFileName(const Value: string);
  end;

  // Pixels are premultiplied-alpha ARGB colors in row-major order.
  TEmulatorFrame = record
    Width: Integer;
    Height: Integer;
    Pixels: TArray<TAlphaColor>;
    FrameNumber: UInt64;
    FramesPerSecond: Double;
  end;

  // Independent display regions in the most recently published frame.
  // Post-processing must isolate their source pixels and temporal histories.
  IEmulationVideoRegions = interface
    ['{AF85F329-1830-4EBA-A4A7-76BE777F360E}']
    function GetVideoRegions: TArray<TRect>;
  end;

  // A guest can end normally while its adapter remains available for snapshots.
  IEmulationCompletion = interface
    ['{38231ED3-334E-4C30-8D61-2EA69D297CC2}']
    function IsFinished: Boolean;
  end;

  // Device warnings do not stop emulation; frontends may report them once.
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

  // Absolute contact events in the published frame's pixels, before any
  // platform-specific inverse display transform. Contact 0 is the primary
  // mouse/touch contact. Cancel must release state without activating a tap.
  TEmulationTouchPhase = (Down, Move, Up, Cancel);

  TEmulationTouchEvent = record
    Phase: TEmulationTouchPhase;
    Contact, X, Y: Integer;
  end;

  IEmulationTouchInput = interface
    ['{C4FF4237-71C1-4CA4-9B4C-655CC47E18A4}']
    function GetUsesTouch: Boolean;
    procedure SendTouch(const Event: TEmulationTouchEvent);
    property UsesTouch: Boolean read GetUsesTouch;
  end;

  IEmulationMotionInput = interface
    ['{1B7C1D32-86B7-4DCC-BD4B-20B1D41120A7}']
    function GetHasAccelerometer: Boolean;
    procedure SetAcceleration(X, Y: Double);
    property HasAccelerometer: Boolean read GetHasAccelerometer;
  end;

  // Rotation about the screen normal, normalized to 180 degrees per second.
  // Optional three-axis extension of IEmulationMotionInput.
  IEmulationMotionInput3D = interface
    ['{C5781AF3-009E-4AF7-9E25-61CB587BBDFE}']
    procedure SetAcceleration3D(X, Y, Z: Double; Available: Boolean);
  end;

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

  TEmulationAchievementRead = reference to function(Address: Cardinal; Buffer: PByte; Count: Cardinal): Cardinal;

  // Observer operations run on the emulation thread. The memory reader is valid only during Frame.
  IEmulationAchievementObserver = interface
    ['{ACF983F7-7E67-4804-947E-545E773B812B}']
    procedure Frame(const ReadMemory: TEmulationAchievementRead);
    procedure Reset;
    function CaptureProgress: TBytes;
    procedure RestoreProgress(const Data: TBytes);
  end;

  // Platform capability for identifying achievement media before a core is started.
  // The provider is used by a library worker and preserves the input position.
  IEmulationAchievementMedia = interface
    ['{136E8028-531E-4361-A92E-BDFBC5A3508B}']
    function GetConsoleId: Cardinal;
    function IsDisc: Boolean;
    function AcceptsROM(const SourceName: string; Input: TStream): Boolean;
    property ConsoleId: Cardinal read GetConsoleId;
  end;

  IEmulationAchievements = interface
    ['{0044A383-D20C-424A-9E10-7719C0304C41}']
    function AchievementROM: TBytes;
    procedure SetAchievementObserver(const Observer: IEmulationAchievementObserver);
  end;

  // A loaded arcade set identified by its ROM catalog, including split sets.
  IEmulationArcadeAchievements = interface
    ['{331F0513-73F6-4DFC-8C01-AA644D91FF8F}']
    function AchievementSetName: string;
  end;

  IEmulationSnapshotLocation = interface
    ['{E6C77DB0-6B7D-43F9-9C16-C9985DA992E9}']
    function GetSnapshotDirectory: string;
  end;

  // Optional nonblocking transport for cores whose state reconstruction is slow.
  // Status returns True while pending/running. All methods are frontend-thread safe.
  IEmulationSnapshotOperation = interface
    ['{A17F341E-C6D0-42BC-ACD5-BB427632C9B8}']
    procedure BeginSnapshot(const Name: string; Loading: Boolean);
    function SnapshotStatus(out Done, Total: UInt64; out Error: string): Boolean;
    procedure CancelSnapshot;
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

  // Frontend-thread commands. Captions are translation keys; IDs are stable
  // within a core. Query again when opening the menu and before execution.
  TEmulationGameAction = record
    Id, Caption: string;
    Enabled: Boolean;
    GroupCaption: string; // Optional translation key for a shared submenu.
    Checked: Boolean;
  end;

  IEmulationGameActions = interface
    ['{044A3D71-354B-496A-9FF4-78FD523D1232}']
    function GetGameActions: TArray<TEmulationGameAction>;
    procedure ExecuteGameAction(const Id: string);
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

// The pool may overwrite an array only while no consumer owns it.
function EmulationBufferReferences(Data: Pointer): Integer; inline;

// Read a bounded byte range without invoking the guest bus or its devices.
function ReadAchievementMemoryBlock(Address: Cardinal; Buffer: PByte; Count: Cardinal; Memory: PByte; Size: Cardinal; ByteXor: Cardinal = 0): Cardinal; overload;

function ReadAchievementMemoryBlock(Address: Cardinal; Buffer: PByte; Count: Cardinal; const Memory: TBytes): Cardinal; overload;

implementation

function ReadAchievementMemoryBlock(Address: Cardinal; Buffer: PByte; Count: Cardinal; Memory: PByte; Size, ByteXor: Cardinal): Cardinal;
begin
  if (Address >= Size) or (Buffer = nil) or (Memory = nil) or (Count = 0) then
    Exit(0);
  Result := Size - Address;
  if Count < Result then
    Result := Count;
  if ByteXor = 0 then
    Move((Memory + Address)^, Buffer^, Result)
  else
    for var I: Cardinal := 0 to Result - 1 do
    begin
      var Index := (Address + I) xor ByteXor;
      if Index >= Size then
        Exit(I);
      Buffer[I] := Memory[Index];
    end;
end;

function ReadAchievementMemoryBlock(Address: Cardinal; Buffer: PByte; Count: Cardinal; const Memory: TBytes): Cardinal;
begin
  Result := ReadAchievementMemoryBlock(Address, Buffer, Count, Pointer(Memory), Length(Memory));
end;

function TEmulatorInput.PortButtons(Port: Integer): TEmulatorButtons;
begin
  case Port of
    0:
      Result := Buttons;
    1:
      Result := Buttons2;
    2:
      Result := Buttons3;
    3:
      Result := Buttons4;
    4:
      Result := Buttons5;
    5:
      Result := Buttons6;
    6:
      Result := Buttons7;
    7:
      Result := Buttons8;
    8:
      Result := Buttons9;
    9:
      Result := Buttons10;
    10:
      Result := Buttons11;
    11:
      Result := Buttons12;
  else
    Result := [];
  end;
end;

function TEmulatorInput.ButtonAmount(Port: Integer; Button: TEmulatorButton): Single;
begin
  if (Port >= 0) and (Port < EmulatorMaxPlayers) and (Button in AnalogButtons[Port].Valid) then
    Result := AnalogButtons[Port].Values[Button] / 255
  else
    Result := Ord(Button in PortButtons(Port));
end;

function TEmulatorInput.DigitalButton(Port: Integer; Button: TEmulatorButton): Boolean;
begin
  if (Port >= 0) and (Port < EmulatorMaxPlayers) and (Button in AnalogButtons[Port].Valid) then
    Result := Button in AnalogButtons[Port].Digital
  else
    Result := Button in PortButtons(Port);
end;

procedure TEmulatorInput.AliasButton(Source, Target: TEmulatorButton);
begin
  if Source in AnalogButtons[0].Valid then
  begin
    if not (Target in AnalogButtons[0].Valid) then
      AnalogButtons[0].Values[Target] := 255 * Ord(Target in Buttons);
    Include(AnalogButtons[0].Valid, Target);
    if AnalogButtons[0].Values[Source] > AnalogButtons[0].Values[Target] then
      AnalogButtons[0].Values[Target] := AnalogButtons[0].Values[Source];
    if Source in AnalogButtons[0].Digital then
      Include(AnalogButtons[0].Digital, Target);
    if Source in AnalogButtons[0].Axes then
      Include(AnalogButtons[0].Axes, Target);
  end;
  if Source in RelativeButtons[0] then
    Include(RelativeButtons[0], Target);
  if Source in Buttons then
    Include(Buttons, Target);
end;

class function TEmulatorInput.LegacySize: Integer;
begin
  var Value: TEmulatorInput;
  Result := NativeUInt(@Value.AnalogButtons) - NativeUInt(@Value);
end;

class function TEmulatorInput.TravelSize: Integer;
begin
  var Value: TEmulatorInput;
  Result := NativeUInt(@Value.RelativeButtons) - NativeUInt(@Value);
end;

function EmulationBufferReferences(Data: Pointer): Integer;
type
  THeader = packed record
{$IFDEF CPU64BITS}
    Padding: Integer;
{$ENDIF}
    RefCount: Integer;
    Length: NativeInt;
  end;

  PHeader = ^THeader;
begin
  if Data = nil then
    Exit(0);
  Result := PHeader(PByte(Data) - SizeOf(THeader))^.RefCount;
end;

end.

