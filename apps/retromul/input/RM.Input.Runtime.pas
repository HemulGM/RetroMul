unit RM.Input.Runtime;

interface

uses
  System.Classes, System.UITypes, Core.Emulation, RM.Main.View, RM.Main.State,
  FMX.Objects;

type
  TInputRuntimeContext = record
    View: TMainView;
    State: TMainState;
    ScreenInputChanged: TNotifyEvent;
    function Data(const Key: string): IInterface;
    procedure SetData(const Key: string; const Value: IInterface);
  end;

  TInputKeyPolicy = record
    KeyboardActive, ForwardWithManager: Boolean;
    ReserveCaptureShortcuts, AllowSnapshotsWithKeyboard: Boolean;
    ControlKeys: set of Byte;
    function IsControlKey(Code: Word): Boolean;
  end;

  // Stateless handlers operate on the calling view's state. Registration is static.
  TPlatformInputHandler = class
  public
    class function InitializationOrder: Integer; virtual;
    class procedure Initialize(const Context: TInputRuntimeContext); virtual;
    class procedure Finalize(const Context: TInputRuntimeContext); virtual;
    class function KeyPolicy(const Context: TInputRuntimeContext): TInputKeyPolicy; virtual;
    class function ForwardKey(const Context: TInputRuntimeContext; Code: Word; Pressed: Boolean): Boolean; virtual;
    class procedure CombineInput(const Context: TInputRuntimeContext; var Input: TEmulatorInput); virtual;
    class procedure UpdateInput(const Context: TInputRuntimeContext); virtual;
    class procedure UpdateFeedback(const Context: TInputRuntimeContext); virtual;
    class procedure PollInput(const Context: TInputRuntimeContext); virtual;
    class procedure ScreenInputChanged(const Context: TInputRuntimeContext; Sender: TObject); virtual;
    class procedure PointerButton(const Context: TInputRuntimeContext; X, Y: Single; Pressed: Boolean); virtual;
    class procedure Command(const Context: TInputRuntimeContext; const Name: string; Code: Integer; const FileName: string); virtual;
  end;

  TPlatformInputHandlerClass = class of TPlatformInputHandler;

procedure RegisterPlatformInputHandler(const PlatformId: string; Handler: TPlatformInputHandlerClass);

function TryPlatformInputHandler(const PlatformId: string; out Handler: TPlatformInputHandlerClass): Boolean;

function PlatformInputHandler(const PlatformId: string): TPlatformInputHandlerClass;

procedure InitializePlatformInputHandlers(const Context: TInputRuntimeContext);

procedure FinalizePlatformInputHandlers(const Context: TInputRuntimeContext);

function TryGetImagePixel(const Image: TImage; const X, Y: Single; out PixelX, PixelY: Integer): Boolean;

implementation

uses
  System.SysUtils, System.Math, System.Generics.Collections,
  System.Generics.Defaults, Core.Platforms, RM.Gamepad;

var
  Handlers: TDictionary<string, TPlatformInputHandlerClass>;

type
  IInputRuntimeData = interface
    ['{E54CB49A-2C01-473C-B135-31E7E7CCCE83}']
    function GetValue(const Key: string): IInterface;
    procedure SetValue(const Key: string; const Value: IInterface);
    function InitializedHandlers: TArray<TPlatformInputHandlerClass>;
    procedure TrackInitialization(Handler: TPlatformInputHandlerClass);
    function BeginFinalization: TArray<TPlatformInputHandlerClass>;
    function IsFinalizing: Boolean;
  end;

  TInputRuntimeData = class(TInterfacedObject, IInputRuntimeData)
  private
    FValues: TDictionary<string, IInterface>;
    FInitialized: TList<TPlatformInputHandlerClass>;
    FFinalizing: Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    function GetValue(const Key: string): IInterface;
    procedure SetValue(const Key: string; const Value: IInterface);
    function InitializedHandlers: TArray<TPlatformInputHandlerClass>;
    procedure TrackInitialization(Handler: TPlatformInputHandlerClass);
    function BeginFinalization: TArray<TPlatformInputHandlerClass>;
    function IsFinalizing: Boolean;
  end;

constructor TInputRuntimeData.Create;
begin
  inherited;
  FValues := TDictionary<string, IInterface>.Create;
  FInitialized := TList<TPlatformInputHandlerClass>.Create;
end;

destructor TInputRuntimeData.Destroy;
begin
  FValues.Free;
  FInitialized.Free;
  inherited;
end;

function TInputRuntimeData.GetValue(const Key: string): IInterface;
begin
  FValues.TryGetValue(Key, Result);
end;

procedure TInputRuntimeData.SetValue(const Key: string; const Value: IInterface);
begin
  if Value = nil then
    FValues.Remove(Key)
  else
    FValues.AddOrSetValue(Key, Value);
end;

function TInputRuntimeData.InitializedHandlers: TArray<TPlatformInputHandlerClass>;
begin
  Result := FInitialized.ToArray;
end;

procedure TInputRuntimeData.TrackInitialization(Handler: TPlatformInputHandlerClass);
begin
  FInitialized.Add(Handler);
end;

function TInputRuntimeData.BeginFinalization: TArray<TPlatformInputHandlerClass>;
begin
  Result := nil;
  if FFinalizing then
    Exit;
  FFinalizing := True;
  Result := FInitialized.ToArray;
  FInitialized.Clear;
end;

function TInputRuntimeData.IsFinalizing: Boolean;
begin
  Result := FFinalizing;
end;

function TInputRuntimeContext.Data(const Key: string): IInterface;
begin
  Result := nil;
  if State.Input.RuntimeData <> nil then
    Result := (State.Input.RuntimeData as IInputRuntimeData).GetValue(Key);
end;

procedure TInputRuntimeContext.SetData(const Key: string; const Value: IInterface);
begin
  if (State.Input.RuntimeData = nil) and (Value = nil) then
    Exit;
  if State.Input.RuntimeData = nil then
    State.Input.RuntimeData := TInputRuntimeData.Create;
  (State.Input.RuntimeData as IInputRuntimeData).SetValue(Key, Value);
end;

function TInputKeyPolicy.IsControlKey(Code: Word): Boolean;
begin
  Result := (Code <= High(Byte)) and (Byte(Code) in ControlKeys);
end;

procedure RegisterPlatformInputHandler(const PlatformId: string; Handler: TPlatformInputHandlerClass);
begin
  var Id := PlatformId.Trim.ToLower;
  if (Id = '') or (Handler = nil) then
    raise EArgumentException.Create('Invalid platform input handler: ' + PlatformId);
  if Handlers.ContainsKey(Id) then
    raise EArgumentException.Create('Duplicate platform input handler: ' + Id);
  Handlers.Add(Id, Handler);
end;

function TryPlatformInputHandler(const PlatformId: string; out Handler: TPlatformInputHandlerClass): Boolean;
begin
  Handler := nil;
  var Id := PlatformId.Trim.ToLower;
  Result := Handlers.TryGetValue(Id, Handler);
  if not Result then
    Result := Handlers.TryGetValue(TPlatformRegistry.CanonicalId(Id), Handler);
end;

function PlatformInputHandler(const PlatformId: string): TPlatformInputHandlerClass;
begin
  if not TryPlatformInputHandler(PlatformId, Result) then
    Result := TPlatformInputHandler;
end;

procedure InitializePlatformInputHandlers(const Context: TInputRuntimeContext);
begin
  if Context.State.Input.RuntimeData = nil then
    Context.State.Input.RuntimeData := TInputRuntimeData.Create;
  var Runtime := Context.State.Input.RuntimeData as IInputRuntimeData;
  if Runtime.IsFinalizing then
    raise EInvalidOperation.Create('Peripheral finalization is in progress');
  var Classes := TList<TPlatformInputHandlerClass>.Create;
  try
    for var Handler in Handlers.Values do
      if not Classes.Contains(Handler) then
        Classes.Add(Handler);
    Classes.Sort(TComparer<TPlatformInputHandlerClass>.Construct(
      function(const A, B: TPlatformInputHandlerClass): Integer
      begin
        Result := CompareValue(A.InitializationOrder, B.InitializationOrder);
        if Result = 0 then
          Result := CompareStr(A.ClassName, B.ClassName);
      end));
    for var Handler in Runtime.InitializedHandlers do
      Classes.Remove(Handler);
    try
      for var Handler in Classes do
      begin
        // Include the currently initializing handler so partial creation is cleaned up.
        Runtime.TrackInitialization(Handler);
        Handler.Initialize(Context);
      end;
    except
      FinalizePlatformInputHandlers(Context);
      raise;
    end;
  finally
    Classes.Free;
  end;
end;

procedure FinalizePlatformInputHandlers(const Context: TInputRuntimeContext);
var
  Classes: TArray<TPlatformInputHandlerClass>;

  procedure FinalizeAt(Index: Integer);
  begin
    if Index < 0 then
      Exit;
    try
      Classes[Index].Finalize(Context);
    finally
      // A failing extension must not skip the other initialized handlers.
      FinalizeAt(Index - 1);
    end;
  end;

begin
  if Context.State.Input.RuntimeData = nil then
    Exit;
  var Runtime := Context.State.Input.RuntimeData as IInputRuntimeData;
  if Runtime.IsFinalizing then
    Exit;
  Classes := Runtime.BeginFinalization;
  try
    FinalizeAt(High(Classes));
  finally
    Context.State.Input.RuntimeData := nil;
  end;
end;

class function TPlatformInputHandler.InitializationOrder: Integer;
begin
  Result := 100;
end;

class procedure TPlatformInputHandler.Initialize(const Context: TInputRuntimeContext);
begin
end;

class procedure TPlatformInputHandler.Finalize(const Context: TInputRuntimeContext);
begin
end;

class function TPlatformInputHandler.KeyPolicy(const Context: TInputRuntimeContext): TInputKeyPolicy;
begin
  Result := Default(TInputKeyPolicy);
end;

class function TPlatformInputHandler.ForwardKey(const Context: TInputRuntimeContext; Code: Word; Pressed: Boolean): Boolean;
begin
  Result := False;
end;

class procedure TPlatformInputHandler.CombineInput(const Context: TInputRuntimeContext; var Input: TEmulatorInput);
begin
end;

class procedure TPlatformInputHandler.UpdateInput(const Context: TInputRuntimeContext);
begin
end;

class procedure TPlatformInputHandler.UpdateFeedback(const Context: TInputRuntimeContext);
begin
  if (Context.State.Session.Emulation = nil) or Context.State.Session.EmulationFaulted then
    Exit;
  if (Context.State.Input.Gamepad <> nil) and Context.State.Input.Gamepad.Visible and Context.State.Input.Gamepad.Enabled then
    Context.State.Input.Gamepad.CoreButtons := Context.State.Session.Emulation.GetInputState.Buttons;
end;

class procedure TPlatformInputHandler.PollInput(const Context: TInputRuntimeContext);
begin
end;

class procedure TPlatformInputHandler.ScreenInputChanged(const Context: TInputRuntimeContext; Sender: TObject);
begin
end;

class procedure TPlatformInputHandler.PointerButton(const Context: TInputRuntimeContext; X, Y: Single; Pressed: Boolean);
begin
end;

class procedure TPlatformInputHandler.Command(const Context: TInputRuntimeContext; const Name: string; Code: Integer; const FileName: string);
begin
  if Name = 'tape.select' then
    raise EInvalidOperation.Create('No data recorder connected');
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

initialization
  Handlers := TDictionary<string, TPlatformInputHandlerClass>.Create(TIStringComparer.Ordinal);

finalization
  Handlers.Free;

end.

