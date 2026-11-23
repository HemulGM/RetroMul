unit RM.platform.Host;

interface

uses
  System.Classes, System.Types, Core.Emulation, Core.InputConfig,
  Core.Storage.Types, FMXInput, FMX.Forms, FMX.Controls, FMX.Objects, RM.Gamepad;

type
  TPlatformSessionPhase = (Empty, Loading, Running, Paused, Failed);

  TPlatformActivity = record
    Phase: TPlatformSessionPhase;
    GameplayVisible: Boolean;
    AcceptsGameInput: Boolean;
    CanShowGameNotice: Boolean;
    SettingsOpen: Boolean;
    PeripheralInputBlocked: Boolean;
    ShowVirtualGamepad: Boolean;
    VirtualControlsEnabled: Boolean;
  end;

  IPlatformInput = interface
    ['{4E58CC25-DBEF-4CAE-8B27-E96733EDEA77}']
    function GetPorts: TCoreInputPorts;
    procedure SetPorts(const Ports: TCoreInputPorts);
    function GetHasInputSource: Boolean;
    function GetBindings: TArray<TInputBinding>;
    function IsActionPressed(Action: Integer): Boolean;
    function ActionAmount(Action: Integer): Single;
    function DigitalAnalogAmount(Action: Integer; Pressed: Boolean): Single;
    procedure ClearCachedInput;
    procedure RequestInputUpdate(SubmitToCore: Boolean);
    property Ports: TCoreInputPorts read GetPorts write SetPorts;
    property HasInputSource: Boolean read GetHasInputSource;
    property Bindings: TArray<TInputBinding> read GetBindings;
  end;

  IPlatformVideo = interface
    ['{7564F83E-D60B-4AE7-A2A2-6C51101CB7D5}']
    // Local coordinates belong to the surface receiving PointerButton.
    function TryLocalToFrame(const Point: TPointF; out Pixel: TPoint): Boolean;
    function TryScreenToFrame(const Point: TPointF; out Pixel: TPoint): Boolean;
    function TryPointerToFrame(out Pixel: TPoint): Boolean;
    function GetPointerCaptured: Boolean;
    procedure SetPointerCaptured(Value: Boolean);
    procedure SetPointerInputEnabled(Enabled, ShowFocus: Boolean);
    procedure FitFrame;
    property PointerCaptured: Boolean read GetPointerCaptured write SetPointerCaptured;
  end;

  // FMX controls are borrowed from the host and used only on the UI thread.
  IFmxPlatformSurface = interface
    ['{A6281E7D-AA4A-4711-AC8C-107B832CB043}']
    function GetInputForm: TCommonCustomForm;
    function GetContent: TControl;
    function GetFrameLayer: TImage;
    function GetGamepad: TScreenGamepad;
    function GetUsableSize: TSizeF;
    function GetBottomInset: Single;
    property InputForm: TCommonCustomForm read GetInputForm;
    property Content: TControl read GetContent;
    property FrameLayer: TImage read GetFrameLayer;
    property Gamepad: TScreenGamepad read GetGamepad;
    property UsableSize: TSizeF read GetUsableSize;
    property BottomInset: Single read GetBottomInset;
  end;

  TPlatformDocumentRequest = record
    Title, Filter, Extension, SuggestedName, SaveFolder: string;
    AllowedExtensions: TArray<string>;
  end;

  TPlatformDocumentAction = reference to procedure(const FileName: string);

  IPlatformDocuments = interface
    ['{49B20FF4-4215-4FE6-B2C9-407F31295097}']
    // Callbacks are delivered on the UI thread while the originating game is current.
    procedure OpenDocument(const Request: TPlatformDocumentRequest; const Selected: TPlatformDocumentAction);
    procedure SaveDocument(const Request: TPlatformDocumentRequest; const Write: TPlatformDocumentAction);
  end;

  IPlatformHost = interface
    ['{4488614F-6D74-405D-94A7-AA88EA13BBD5}']
    function GetCore: IEmulationCore;
    function GetSystemId: string;
    function GetStorage: IStorage;
    function GetActivity: TPlatformActivity;
    function GetInput: IPlatformInput;
    function GetVideo: IPlatformVideo;
    // Per-window state of registered handlers, released by finalization.
    function GetData(const Key: string): IInterface;
    procedure SetData(const Key: string; const Value: IInterface);
    procedure ResetGame;
    procedure SetStatus(const Text: string);
    procedure ShowMessage(const Text: string; IsError: Boolean);
    property Core: IEmulationCore read GetCore;
    property SystemId: string read GetSystemId;
    property Storage: IStorage read GetStorage;
    property Activity: TPlatformActivity read GetActivity;
    property Input: IPlatformInput read GetInput;
    property Video: IPlatformVideo read GetVideo;
  end;

implementation

end.

