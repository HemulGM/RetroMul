unit RM.Settings.Callouts;

interface

uses System.Types, FMX.Controls;

type
  TDeviceCalloutContext = record
    SystemId: string;
    Port: Integer;
    Device: TControl; // Borrowed; owned by the diagram/view.
  end;
  TDeviceCalloutDefinition = record
    Button, Action: Integer;
    Name, Caption: string;
    Left: Boolean;
    class function Create(Button, Action: Integer; const Name, Caption: string;
      Left: Boolean): TDeviceCalloutDefinition; static;
  end;

  TPlatformDeviceCallouts = class
  public
    class function Definitions(const Context: TDeviceCalloutContext): TArray<TDeviceCalloutDefinition>; virtual;
    class function ButtonBounds(const Context: TDeviceCalloutContext; Button: Integer): TRectF; virtual;
    class function AspectRatio(const Context: TDeviceCalloutContext): Single; virtual;
    class function ReverseColumns(const Context: TDeviceCalloutContext; Left: Boolean): Boolean; virtual;
    // Points are in diagram coordinates. The first point receives the anchor dot.
    class function LinePath(const Context: TDeviceCalloutContext; const Definition: TDeviceCalloutDefinition;
      const Bounds: TRectF; LabelControl: TControl): TArray<TPointF>; virtual;
  end;
  TPlatformDeviceCalloutsClass = class of TPlatformDeviceCallouts;

procedure RegisterPlatformDeviceCallouts(const PlatformId: string; Provider: TPlatformDeviceCalloutsClass);
function TryPlatformDeviceCallouts(const PlatformId: string; out Provider: TPlatformDeviceCalloutsClass): Boolean;
function PlatformDeviceCallouts(const PlatformId: string): TPlatformDeviceCalloutsClass;

implementation

uses System.SysUtils, System.Generics.Collections, System.Generics.Defaults,
  FMX.Types, Core.Platforms, Core.Emulation, RM.Gamepad, RM.Input;

var Providers: TDictionary<string, TPlatformDeviceCalloutsClass>;

class function TDeviceCalloutDefinition.Create(Button, Action: Integer; const Name, Caption: string;
  Left: Boolean): TDeviceCalloutDefinition;
begin
  Result.Button := Button;
  Result.Action := Action;
  Result.Name := Name;
  Result.Caption := Caption;
  Result.Left := Left;
end;

procedure RegisterPlatformDeviceCallouts(const PlatformId: string; Provider: TPlatformDeviceCalloutsClass);
begin
  var Id := PlatformId.Trim.ToLower;
  if (Id = '') or (Provider = nil) then
    raise EArgumentException.Create('Invalid device callouts provider: ' + PlatformId);
  if Providers.ContainsKey(Id) then
    raise EArgumentException.Create('Duplicate device callouts provider: ' + Id);
  Providers.Add(Id, Provider);
end;

function TryPlatformDeviceCallouts(const PlatformId: string; out Provider: TPlatformDeviceCalloutsClass): Boolean;
begin
  Provider := nil;
  var Id := PlatformId.Trim.ToLower;
  Result := Providers.TryGetValue(Id, Provider);
  if not Result then Result := Providers.TryGetValue(TPlatformRegistry.CanonicalId(Id), Provider);
end;

function PlatformDeviceCallouts(const PlatformId: string): TPlatformDeviceCalloutsClass;
begin
  if not TryPlatformDeviceCallouts(PlatformId, Result) then Result := TPlatformDeviceCallouts;
end;

class function TPlatformDeviceCallouts.Definitions(const Context: TDeviceCalloutContext): TArray<TDeviceCalloutDefinition>;
begin
  Result := nil;
  if not (Context.Device is TScreenGamepad) then Exit;
  for var Button in TScreenGamepad(Context.Device).ButtonMask do
  begin
    if ButtonBounds(Context, Ord(Button)).IsEmpty then
      Continue;
    var Left := Button in [TEmulatorButton.Up, TEmulatorButton.Down,
      TEmulatorButton.Left, TEmulatorButton.Right, TEmulatorButton.Select, TEmulatorButton.Mode];
    var Name := Translate(CoreButtonName(Context.SystemId, Button));
    Result := Result + [TDeviceCalloutDefinition.Create(Ord(Button), PadAction(Context.Port, Button),
      Name, Translate('Button ') + Name, Left)];
  end;
end;

class function TPlatformDeviceCallouts.ButtonBounds(const Context: TDeviceCalloutContext; Button: Integer): TRectF;
begin
  Result := TRectF.Empty;
  if not (Context.Device is TScreenGamepad) then Exit;
  if Button < 0 then
    Result := TScreenGamepad(Context.Device).AuxiliaryButtonBounds(-1 - Button)
  else
    Result := TScreenGamepad(Context.Device).ButtonBounds(TEmulatorButton(Button));
end;

class function TPlatformDeviceCallouts.AspectRatio(const Context: TDeviceCalloutContext): Single;
begin
  Result := 0.46;
  if Context.Device is TScreenGamepad then Result := TScreenGamepad(Context.Device).AspectRatio;
end;

class function TPlatformDeviceCallouts.ReverseColumns(const Context: TDeviceCalloutContext; Left: Boolean): Boolean;
begin Result := False; end;

class function TPlatformDeviceCallouts.LinePath(const Context: TDeviceCalloutContext;
  const Definition: TDeviceCalloutDefinition; const Bounds: TRectF; LabelControl: TControl): TArray<TPointF>;
begin
  var Start := Bounds.CenterPoint + Context.Device.Position.Point;
  var Finish := TPointF.Create(LabelControl.Position.X - 5, LabelControl.Position.Y + LabelControl.Height / 2);
  Start.X := Bounds.Right + Context.Device.Position.X;
  if Definition.Left then
  begin
    Start.X := Bounds.Left + Context.Device.Position.X;
    Finish.X := LabelControl.Position.X + LabelControl.Width + 5;
  end;
  var Elbow := TPointF.Create((Start.X + Finish.X) / 2, Finish.Y);
  Result := [Start, Elbow, Finish];
end;

initialization
  Providers := TDictionary<string, TPlatformDeviceCalloutsClass>.Create(TIStringComparer.Ordinal);
finalization
  Providers.Free;
end.
