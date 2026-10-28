unit RM.ControlsHelp.Content;

interface

uses
  System.Classes, FMX.Controls, FMXInput, Core.InputConfig;

type
  TControlsHelpContext = record
    SystemId: string;
    Ports: TCoreInputPorts;
    Player: Integer;
    KeyboardPeripheral, HasCoinAcceptor: Boolean;
    Input: TInputManager; // Borrowed for this synchronous call.
  end;

  TControlsHelpInfo = record
    ControllerTitle, Note: string;
    AssignmentColumns: Integer;
    AssignmentRowHeight, AssignmentCaptionWidth: Single;
  end;

  TControlsHelpAssignment = record
    Caption: string;
    Action: Integer;
    class function Create(const Caption: string; Action: Integer): TControlsHelpAssignment; static;
  end;

  TControlsHelpShortcut = record
    Id, Caption, Keys: string;
    Available: Boolean;
    class function Create(const Id, Caption, Keys: string; Available: Boolean = True): TControlsHelpShortcut; static;
  end;

  TPlatformControlsHelp = class
  protected
    class function DescribeDevice(const Context: TControlsHelpContext; Device: TControl; Owner: TComponent): TControl;
  public
    class function Info(const Context: TControlsHelpContext): TControlsHelpInfo; virtual;
    class function Assignments(const Context: TControlsHelpContext): TArray<TControlsHelpAssignment>; virtual;
    // Returns the complete reference diagram, or nil for an unconnected port.
    class function CreateDiagram(const Context: TControlsHelpContext; Owner: TComponent): TControl; virtual;
    class function StandardShortcutAvailable(const Context: TControlsHelpContext; const Id: string): Boolean; virtual;
    class function Shortcuts(const Context: TControlsHelpContext): TArray<TControlsHelpShortcut>; virtual;
  end;

  TPlatformControlsHelpClass = class of TPlatformControlsHelp;

procedure RegisterPlatformControlsHelp(const PlatformId: string; Provider: TPlatformControlsHelpClass);

function TryPlatformControlsHelp(const PlatformId: string; out Provider: TPlatformControlsHelpClass): Boolean;

function PlatformControlsHelp(const PlatformId: string): TPlatformControlsHelpClass;

implementation

uses
  FMX.Types, System.SysUtils, System.Generics.Collections,
  System.Generics.Defaults, Core.Platforms, RM.Input, RM.Gamepad, RM.Settings,
  RM.Settings.Rendering, RM.Styles;

var
  Providers: TDictionary<string, TPlatformControlsHelpClass>;

class function TControlsHelpAssignment.Create(const Caption: string; Action: Integer): TControlsHelpAssignment;
begin
  Result.Caption := Caption;
  Result.Action := Action;
end;

class function TControlsHelpShortcut.Create(const Id, Caption, Keys: string; Available: Boolean): TControlsHelpShortcut;
begin
  Result.Id := Id;
  Result.Caption := Caption;
  Result.Keys := Keys;
  Result.Available := Available;
end;

procedure RegisterPlatformControlsHelp(const PlatformId: string; Provider: TPlatformControlsHelpClass);
begin
  var Id := PlatformId.Trim.ToLower;
  if (Id = '') or (Provider = nil) then
    raise EArgumentException.Create('Invalid controls help provider: ' + PlatformId);
  if Providers.ContainsKey(Id) then
    raise EArgumentException.Create('Duplicate controls help provider: ' + Id);
  Providers.Add(Id, Provider);
end;

function TryPlatformControlsHelp(const PlatformId: string; out Provider: TPlatformControlsHelpClass): Boolean;
begin
  Provider := nil;
  var Id := PlatformId.Trim.ToLower;
  Result := Providers.TryGetValue(Id, Provider);
  if not Result then
    Result := Providers.TryGetValue(TPlatformRegistry.CanonicalId(Id), Provider);
end;

function PlatformControlsHelp(const PlatformId: string): TPlatformControlsHelpClass;
begin
  if not TryPlatformControlsHelp(PlatformId, Result) then
    Result := TPlatformControlsHelp;
end;

class function TPlatformControlsHelp.Info(const Context: TControlsHelpContext): TControlsHelpInfo;
begin
  Result.ControllerTitle := Translate('Game controller');
  Result.Note := Translate('Change bindings in the controls settings.');
  if Context.KeyboardPeripheral then
    if Context.HasCoinAcceptor then
      Result.Note := Translate('Letter shortcuts, F5, F6, F8 and F9 are unavailable with keyboard peripherals.')
    else
      Result.Note := Translate('Letter shortcuts, F5, F6 and F8 are unavailable with keyboard peripherals.');
  Result.AssignmentColumns := 2;
  Result.AssignmentRowHeight := 34;
  Result.AssignmentCaptionWidth := 40;
end;

class function TPlatformControlsHelp.Assignments(const Context: TControlsHelpContext): TArray<TControlsHelpAssignment>;
begin
  Result := nil;
  for var Button in CoreButtons(Context.SystemId, Context.Ports.Devices[Context.Player]) do
    Result := Result + [TControlsHelpAssignment.Create(CoreButtonName(Context.SystemId, Button), PadAction(Context.Player, Button))];
end;

class function TPlatformControlsHelp.DescribeDevice(const Context: TControlsHelpContext; Device: TControl; Owner: TComponent): TControl;
begin
  var Diagram := TDeviceCallouts.Create(Owner);
  try
    if Owner is TControl then
    begin
      Diagram.Parent := TControl(Owner);
      Diagram.Align := TAlignLayout.Client;
    end;
    Device.HitTest := False;
    Device.Enabled := False;
    Diagram.Configure(Device, Context.Input, Context.SystemId, Context.Player, nil);
    Result := Diagram;
  except
    RetireSettingsControl(Diagram);
    raise;
  end;
end;

class function TPlatformControlsHelp.CreateDiagram(const Context: TControlsHelpContext; Owner: TComponent): TControl;
begin
  Result := nil;
  var Buttons := CoreButtons(Context.SystemId, Context.Ports.Devices[Context.Player]);
  if Buttons = [] then
    Exit;
  var Pad := TScreenGamepad.Create(Owner);
  try
    Pad.Configure(TPlatformRegistry.Require(Context.SystemId).Id, Context.Ports.Devices[Context.Player], Buttons);
    Result := DescribeDevice(Context, Pad, Owner);
  except
    RetireSettingsControl(Pad);
    raise;
  end;
end;

class function TPlatformControlsHelp.StandardShortcutAvailable(const Context: TControlsHelpContext; const Id: string): Boolean;
begin
  Result := not Context.KeyboardPeripheral or
    not ((Id = 'save') or (Id = 'load') or (Id = 'screenshot') or (Id = 'pause') or
    (Id = 'reset') or (Id = 'hard-restart') or (Id = 'open') or (Id = 'coin'));
end;

class function TPlatformControlsHelp.Shortcuts(const Context: TControlsHelpContext): TArray<TControlsHelpShortcut>;
begin
  Result := nil;
end;

initialization
  Providers := TDictionary<string, TPlatformControlsHelpClass>.Create(TIStringComparer.Ordinal);

finalization
  Providers.Free;

end.

