unit RM.Keyboard.Input;

{$I RM.Mobile.inc}

interface

uses
  Core.Input.Keyboard, System.Classes, RM.Input.Runtime, RM.Keyboard;

type
  TKeyboardInputState = class;

  IKeyboardInputState = interface
    ['{062746E3-5A14-4EBB-8ED6-B87B401C6F63}']
    function GetState: TKeyboardInputState;
  end;

  TKeyboardInputState = class(TInterfacedObject, IKeyboardInputState)
  private
    FObserver: TComponent;
    function GetState: TKeyboardInputState;
  public
    Keyboard: TScreenKeyboard;
    TouchAttached: Boolean;
    constructor Create;
    destructor Destroy; override;
    procedure ReleaseDevice;
  end;

  TKeyboardInputHandler = class(TPlatformInputHandler)
  public
    class function InitializationOrder: Integer; override;
    class procedure Initialize(const Context: TInputRuntimeContext); override;
    class procedure Finalize(const Context: TInputRuntimeContext); override;
    class function KeyPolicy(const Context: TInputRuntimeContext): TInputKeyPolicy; override;
    class procedure UpdateInput(const Context: TInputRuntimeContext); override;
    class procedure ScreenInputChanged(const Context: TInputRuntimeContext; Sender: TObject); override;
  end;

procedure RegisterPlatformKeyboard(const PlatformId: string; KeyboardClass: TScreenKeyboardClass);

function KeyboardInputState(const Context: TInputRuntimeContext; CreateIfMissing: Boolean = True): TKeyboardInputState;

implementation

uses
  System.SysUtils, System.UITypes, FMX.Types, RM.Settings.Rendering, System.Generics.Collections;

var
  KeyboardClasses: TDictionary<string, TScreenKeyboardClass>;

procedure RegisterPlatformKeyboard(const PlatformId: string; KeyboardClass: TScreenKeyboardClass);
begin
  if (PlatformId.Trim = '') or (KeyboardClass = nil) then
    raise EArgumentException.Create('Keyboard platform and class are required');
  KeyboardClasses.AddOrSetValue(PlatformId.Trim.ToLower, KeyboardClass);
end;

type
  TKeyboardDeviceObserver = class(TComponent)
  public
    State: TKeyboardInputState;
    procedure Notification(AComponent: TComponent; Operation: TOperation); override;
  end;

const
  KeyboardStateKey = 'retromul.keyboard/peripherals';

procedure TKeyboardDeviceObserver.Notification(AComponent: TComponent; Operation: TOperation);
begin
  inherited;
  if (Operation = opRemove) and (AComponent = State.Keyboard) then
    State.Keyboard := nil;
end;

constructor TKeyboardInputState.Create;
begin
  inherited Create;
  var Observer := TKeyboardDeviceObserver.Create(nil);
  Observer.State := Self;
  FObserver := Observer;
end;

destructor TKeyboardInputState.Destroy;
begin
  ReleaseDevice;
  FObserver.Free;
  inherited;
end;

function TKeyboardInputState.GetState: TKeyboardInputState;
begin
  Result := Self;
end;

function KeyboardInputState(const Context: TInputRuntimeContext; CreateIfMissing: Boolean): TKeyboardInputState;
begin
  var Value := Context.Data(KeyboardStateKey);
  if (Value = nil) and CreateIfMissing then
  begin
    Value := TKeyboardInputState.Create;
    Context.SetData(KeyboardStateKey, Value);
  end;
  if Value = nil then
    Exit(nil);
  Result := (Value as IKeyboardInputState).GetState;
  if CreateIfMissing then
  begin
    var PlatformId := Context.State.Input.SystemId;
    if Context.State.Session.Emulation <> nil then
      PlatformId := Context.State.Session.Emulation.SystemId;
    var KeyboardClass: TScreenKeyboardClass;
    if not KeyboardClasses.TryGetValue(PlatformId.ToLower, KeyboardClass) then
      KeyboardClass := nil;
    if (Result.Keyboard <> nil) and ((KeyboardClass = nil) or (Result.Keyboard.ClassType <> KeyboardClass)) then
      Result.ReleaseDevice;
    if (Result.Keyboard = nil) and (KeyboardClass <> nil) then
    begin
      Result.Keyboard := KeyboardClass.Create(Context.View);
      Result.Keyboard.Name := Copy(KeyboardClass.ClassName, 2, MaxInt) + 'Peripheral';
      Result.Keyboard.FreeNotification(Result.FObserver);
      Result.Keyboard.Parent := Context.View.LayoutClient;
      Result.Keyboard.Align := TAlignLayout.Bottom;
      Result.Keyboard.OnChange := Context.ScreenInputChanged;
      Result.Keyboard.Enabled := False;
      Result.Keyboard.Visible := False;
    end;
  end;
end;

procedure TKeyboardInputState.ReleaseDevice;
begin
  if Keyboard <> nil then
  begin
    var Control := Keyboard;
    Keyboard := nil;
    Control.OnChange := nil;
    DisconnectSettingsControl(Control);
    Control.AttachToForm(nil);
    Control.ReleaseAll;
    RetireSettingsControl(Control);
  end;
  TouchAttached := False;
end;

class procedure TKeyboardInputHandler.Finalize(const Context: TInputRuntimeContext);
begin
  var Devices := KeyboardInputState(Context, False);
  if Devices <> nil then
    Devices.ReleaseDevice;
  Context.SetData(KeyboardStateKey, nil);
end;

class function TKeyboardInputHandler.InitializationOrder: Integer;
begin
  Result := 10;
end;

class procedure TKeyboardInputHandler.Initialize(const Context: TInputRuntimeContext);
begin
  KeyboardInputState(Context);
end;

class function TKeyboardInputHandler.KeyPolicy(const Context: TInputRuntimeContext): TInputKeyPolicy;
var
  Keyboard: IEmulationKeyboard;
begin
  Result := inherited KeyPolicy(Context);
  Result.KeyboardActive := Supports(Context.State.Session.Emulation, IEmulationKeyboard, Keyboard) and Keyboard.HasKeyboard;
  Result.ForwardWithManager := Result.KeyboardActive;
end;

class procedure TKeyboardInputHandler.UpdateInput(const Context: TInputRuntimeContext);
begin
  var Devices := KeyboardInputState(Context);
  var Keyboard: IEmulationKeyboard;
  if (Devices.Keyboard <> nil) and Supports(Context.State.Session.Emulation, IEmulationKeyboard, Keyboard) and Keyboard.HasKeyboard then
    Keyboard.SetScreenKeys(Devices.Keyboard.Keys);
end;

class procedure TKeyboardInputHandler.ScreenInputChanged(const Context: TInputRuntimeContext; Sender: TObject);
begin
  var Devices := KeyboardInputState(Context);
  if Sender = Devices.Keyboard then
    UpdateInput(Context);
end;


initialization
  KeyboardClasses := TDictionary<string, TScreenKeyboardClass>.Create;
finalization
  KeyboardClasses.Free;
end.

