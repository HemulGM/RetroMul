unit RM.Session.Runtime;

{$I ..\RM.Mobile.inc}

interface

uses
  System.Classes, FMX.Forms, FMX.Controls, RM.Gamepad, RM.Gamepad.Base,
  RM.Input.Runtime;

type
  TSessionRuntimeContext = TInputRuntimeContext;

  TSessionAttachInput = procedure(Form: TCommonCustomForm) of object;

  TSessionReleaseInput = procedure of object;

  // Non-owning references. The target control must own/outlive its callbacks.
  TSessionInputControl = record
    Control: TControl;
    Attach: TSessionAttachInput;
    Release: TSessionReleaseInput;
    class function Create(Control: TControl; Attach: TSessionAttachInput; Release: TSessionReleaseInput): TSessionInputControl; static;
  end;

  TPlatformSessionHandler = class
  public
    class function Order: Integer; virtual;
    class procedure Connect(const Context: TSessionRuntimeContext); virtual;
    class procedure Disconnect(const Context: TSessionRuntimeContext); virtual;
    class function InputControls(const Context: TSessionRuntimeContext): TArray<TSessionInputControl>; virtual;
    class function ExclusiveInput(const Context: TSessionRuntimeContext): Boolean; virtual;
    class function ShowPauseShortcut(const Context: TSessionRuntimeContext): Boolean; virtual;
    class function TouchControl(const Context: TSessionRuntimeContext): TSessionInputControl; virtual;
    class procedure SyncActivity(const Context: TSessionRuntimeContext); virtual;
    class procedure ApplyActivityGate(const Context: TSessionRuntimeContext); virtual;
    class procedure LayoutControls(const Context: TSessionRuntimeContext); virtual;
    class procedure FrameStatus(const Context: TSessionRuntimeContext); virtual;
    class procedure FramePresented(const Context: TSessionRuntimeContext); virtual;
  end;

  TPlatformSessionHandlerClass = class of TPlatformSessionHandler;

procedure RegisterPlatformSessionHandler(const PlatformId: string; Handler: TPlatformSessionHandlerClass);

function TryPlatformSessionHandler(const PlatformId: string; out Handler: TPlatformSessionHandlerClass): Boolean;

function PlatformSessionHandler(const PlatformId: string): TPlatformSessionHandlerClass;

procedure ReleaseSessionInputs(const Context: TSessionRuntimeContext);

function SessionControl(Control: TVirtualGamepadControl): TSessionInputControl; overload;

function SessionControl(Control: TScreenGamepad): TSessionInputControl; overload;

procedure SyncSessionTouch(const Context: TSessionRuntimeContext);

procedure DetachSessionTouch(const Context: TSessionRuntimeContext);

procedure ReattachSessionTouch(const Context: TSessionRuntimeContext);

implementation

uses
  System.SysUtils, System.Math, System.Generics.Collections,
  System.Generics.Defaults, Core.Platforms, RM.Input, RM.Dialogs,
  RM.Window.Layout;

var
  Handlers: TDictionary<string, TPlatformSessionHandlerClass>;

type
  TTouchObserver = class(TComponent)
  private
    FTarget: TSessionInputControl;
  protected
    procedure Notification(AComponent: TComponent; Operation: TOperation); override;
  public
    destructor Destroy; override;
    procedure Select(const Target: TSessionInputControl; Form: TCommonCustomForm);
    procedure Reattach(Form: TCommonCustomForm);
  end;

  ISessionTouchState = interface
    ['{7C731A04-C839-46C0-B649-93DDF7225DC8}']
    procedure Select(const Target: TSessionInputControl; Form: TCommonCustomForm);
    procedure Reattach(Form: TCommonCustomForm);
  end;

  TSessionTouchState = class(TInterfacedObject, ISessionTouchState)
  private
    FObserver: TTouchObserver;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Select(const Target: TSessionInputControl; Form: TCommonCustomForm);
    procedure Reattach(Form: TCommonCustomForm);
  end;

const
  TouchStateKey = 'retromul.session/native-touch';

procedure TTouchObserver.Notification(AComponent: TComponent; Operation: TOperation);
begin
  inherited;
  if (Operation = opRemove) and (AComponent = FTarget.Control) then
    FTarget := Default(TSessionInputControl);
end;

destructor TTouchObserver.Destroy;
begin
  if FTarget.Control <> nil then
    FTarget.Control.RemoveFreeNotification(Self);
  inherited;
end;

procedure TTouchObserver.Select(const Target: TSessionInputControl; Form: TCommonCustomForm);
begin
  if (FTarget.Control = Target.Control) and
    (TMethod(FTarget.Attach).Code = TMethod(Target.Attach).Code) and
    (TMethod(FTarget.Attach).Data = TMethod(Target.Attach).Data) then
    Exit;
  if FTarget.Control <> nil then
  begin
    if Assigned(FTarget.Attach) then
      FTarget.Attach(nil);
    FTarget.Control.RemoveFreeNotification(Self);
  end;
  FTarget := Target;
  if FTarget.Control <> nil then
  begin
    FTarget.Control.FreeNotification(Self);
    if Assigned(FTarget.Attach) then
      FTarget.Attach(Form);
  end;
end;

procedure TTouchObserver.Reattach(Form: TCommonCustomForm);
begin
  if (FTarget.Control <> nil) and Assigned(FTarget.Attach) then
    FTarget.Attach(Form);
end;

constructor TSessionTouchState.Create;
begin
  inherited;
  FObserver := TTouchObserver.Create(nil);
end;

destructor TSessionTouchState.Destroy;
begin
  FObserver.Free;
  inherited;
end;

procedure TSessionTouchState.Select(const Target: TSessionInputControl; Form: TCommonCustomForm);
begin
  FObserver.Select(Target, Form);
end;

procedure TSessionTouchState.Reattach(Form: TCommonCustomForm);
begin
  FObserver.Reattach(Form);
end;

function TouchState(const Context: TSessionRuntimeContext; CreateIfMissing: Boolean): ISessionTouchState;
begin
  var Value := Context.Data(TouchStateKey);
  if (Value = nil) and CreateIfMissing then
  begin
    Value := TSessionTouchState.Create;
    Context.SetData(TouchStateKey, Value);
  end;
  if Value = nil then
    Exit(nil);
  Result := Value as ISessionTouchState;
end;

class function TSessionInputControl.Create(Control: TControl; Attach: TSessionAttachInput; Release: TSessionReleaseInput): TSessionInputControl;
begin
  Result := Default(TSessionInputControl);
  if Control = nil then
    Exit;
  Result.Control := Control;
  Result.Attach := Attach;
  Result.Release := Release;
end;

function SessionControl(Control: TVirtualGamepadControl): TSessionInputControl;
begin
  Result := Default(TSessionInputControl);
  if Control <> nil then
    Result := TSessionInputControl.Create(Control, Control.AttachToForm, Control.ReleaseAll);
end;

function SessionControl(Control: TScreenGamepad): TSessionInputControl;
begin
  Result := Default(TSessionInputControl);
  if Control <> nil then
    Result := TSessionInputControl.Create(Control, Control.AttachToForm, Control.ReleaseAll);
end;

procedure RegisterPlatformSessionHandler(const PlatformId: string; Handler: TPlatformSessionHandlerClass);
begin
  var Id := PlatformId.Trim.ToLower;
  if (Id = '') or (Handler = nil) then
    raise EArgumentException.Create('Invalid platform session handler: ' + PlatformId);
  if Handlers.ContainsKey(Id) then
    raise EArgumentException.Create('Duplicate platform session handler: ' + Id);
  Handlers.Add(Id, Handler);
end;

function TryPlatformSessionHandler(const PlatformId: string; out Handler: TPlatformSessionHandlerClass): Boolean;
begin
  Handler := nil;
  var Id := PlatformId.Trim.ToLower;
  Result := Handlers.TryGetValue(Id, Handler);
  if not Result then
    Result := Handlers.TryGetValue(TPlatformRegistry.CanonicalId(Id), Handler);
end;

function PlatformSessionHandler(const PlatformId: string): TPlatformSessionHandlerClass;
begin
  if not TryPlatformSessionHandler(PlatformId, Result) then
    Result := TPlatformSessionHandler;
end;

procedure ReleaseSessionInputs(const Context: TSessionRuntimeContext);
begin
  var Classes := TList<TPlatformSessionHandlerClass>.Create;
  var Released := TList<TControl>.Create;
  try
    for var Handler in Handlers.Values do
      if not Classes.Contains(Handler) then
        Classes.Add(Handler);
    Classes.Sort(TComparer<TPlatformSessionHandlerClass>.Construct(
      function(const A, B: TPlatformSessionHandlerClass): Integer
      begin
        Result := CompareValue(A.Order, B.Order);
        if Result = 0 then
          Result := CompareStr(A.ClassName, B.ClassName);
      end));
    for var Handler in Classes do
      for var Item in Handler.InputControls(Context) do
        if (Item.Control <> nil) and Assigned(Item.Release) and not Released.Contains(Item.Control) then
        begin
          Released.Add(Item.Control);
          Item.Release;
        end;
  finally
    Released.Free;
    Classes.Free;
  end;
end;

procedure SyncSessionTouch(const Context: TSessionRuntimeContext);
begin
  var Target := PlatformSessionHandler(Context.State.Input.SystemId).TouchControl(Context);
  if Context.State.Settings.View <> nil then
    Target := Default(TSessionInputControl);
  TouchState(Context, True).Select(Target, Context.View);
end;

procedure DetachSessionTouch(const Context: TSessionRuntimeContext);
begin
  var Touch := TouchState(Context, False);
  if Touch <> nil then
    Touch.Select(Default(TSessionInputControl), nil);
end;

procedure ReattachSessionTouch(const Context: TSessionRuntimeContext);
begin
  var Touch := TouchState(Context, False);
  if Touch <> nil then
    Touch.Reattach(Context.View)
  else
    TouchState(Context, True).Select(SessionControl(Context.State.Input.Gamepad), Context.View);
end;

class function TPlatformSessionHandler.Order: Integer;
begin
  Result := 100;
end;

class procedure TPlatformSessionHandler.Connect(const Context: TSessionRuntimeContext);
begin
  Context.State.Input.Gamepad.Configure(Context.State.Input.SystemId, Context.State.Input.Ports.Devices[0],
    CoreButtons(Context.State.Input.SystemId, Context.State.Input.Ports.Devices[0]));
  Context.View.ImageCanvas.HitTest := False;
  Context.View.ImageCanvas.CanFocus := False;
  Context.View.ImageCanvas.DisableFocusEffect := True;
end;

class procedure TPlatformSessionHandler.Disconnect(const Context: TSessionRuntimeContext);
begin
  for var Item in InputControls(Context) do
    if Item.Control <> nil then
    begin
      if Assigned(Item.Attach) then
        Item.Attach(nil);
      Item.Control.Visible := False;
      Item.Control.Enabled := False;
    end;
end;

class function TPlatformSessionHandler.InputControls(const Context: TSessionRuntimeContext): TArray<TSessionInputControl>;
begin
  Result := nil;
end;

class function TPlatformSessionHandler.ExclusiveInput(const Context: TSessionRuntimeContext): Boolean;
begin
  Result := False;
end;

class function TPlatformSessionHandler.ShowPauseShortcut(const Context: TSessionRuntimeContext): Boolean;
begin
  Result := True;
end;

class function TPlatformSessionHandler.TouchControl(const Context: TSessionRuntimeContext): TSessionInputControl;
begin
  Result := SessionControl(Context.State.Input.Gamepad);
end;

class procedure TPlatformSessionHandler.SyncActivity(const Context: TSessionRuntimeContext);
begin
  {$IFDEF ISMOBILE}
  if Context.State.Input.Gamepad <> nil then
  begin
    Context.State.Input.Gamepad.Visible := not ExclusiveInput(Context);
    Context.State.Input.Gamepad.Enabled := (Context.State.Session.Emulation <> nil) and
      not Context.State.Session.EmulationFaulted and not Context.State.Session.OpeningRom and not ExclusiveInput(Context);
  end;
  {$ENDIF}
end;

class procedure TPlatformSessionHandler.ApplyActivityGate(const Context: TSessionRuntimeContext);
begin
  {$IFDEF ISMOBILE}
  var Allowed := not Context.State.Mobile.InBackground and not Context.View.GameActionsPopup.IsOpen and
    not RetroDialogVisible(Context.View);
  if Context.State.Input.Gamepad <> nil then
    Context.State.Input.Gamepad.Enabled := Context.State.Input.Gamepad.Enabled and Allowed;
  for var Item in InputControls(Context) do
    if Item.Control <> nil then
      Item.Control.Enabled := Item.Control.Enabled and Allowed;
  {$ENDIF}
end;

class procedure TPlatformSessionHandler.LayoutControls(const Context: TSessionRuntimeContext);
begin
  ArrangePlatformWindowControls(Context);
end;

class procedure TPlatformSessionHandler.FrameStatus(const Context: TSessionRuntimeContext);
begin
end;

class procedure TPlatformSessionHandler.FramePresented(const Context: TSessionRuntimeContext);
begin
end;

initialization
  Handlers := TDictionary<string, TPlatformSessionHandlerClass>.Create(TIStringComparer.Ordinal);

finalization
  Handlers.Free;

end.

