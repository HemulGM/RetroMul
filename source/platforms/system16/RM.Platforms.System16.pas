unit RM.Platforms.System16;

interface

uses
  FMXInput, Core.EmulatorRegistry, RM.Input;

type
  TSystem16Platform = class
  private
    class var
      FRegistered: Boolean;
    class function Recognize(Context: TCoreLoadContext): TCoreMatch; static;
    class function RecognizeSystem18(Context: TCoreLoadContext): TCoreMatch; static;
    class procedure RegisterSharedServices(const SystemId: string; Registration: TEmulationCoreRegistration; System18: Boolean); static;
    class procedure LoadLegacyKeys(var Keys: TPlatformInputKeyMap); static;
    class procedure LoadGamepadPreset(Input: TInputManager; Port: Integer); static;
  public
    class procedure RegisterPlatform; static;
  end;

implementation

uses
  System.Classes, Core.Emulation, Core.Platforms, Core.Snapshots, S16.RomSets,
  Core.Platforms.System16.Adapter, RM.Gamepad.Factory, RM.Input.Gamepads,
  RM.Input.Runtime, RM.Platforms.Presentation, RM.Platforms.CPS.Icons,
  RM.Platforms.System16.Gamepads, RM.Settings.Catalog, RM.Settings.Platform,
  RM.Session.Runtime, RM.Window.Layout, RM.Settings.Runtime,
  RM.ControlsHelp.Content, RM.Settings.Callouts, RM.Settings.Devices,
  RM.Settings.Builder, Core.PlatformServices, S18.RomSets,
  Core.Platforms.System18.Adapter;

type
  TSystem16Settings = class(TSettingsPlatform)
  protected
    function DIPSection: string; virtual;
  public
    procedure Video(Context: TSettingsPageBuilder); override;
  end;

  TSystem18Settings = class(TSystem16Settings)
  protected
    function DIPSection: string; override;
  end;

function TSystem16Settings.DIPSection: string;
begin
  Result := 'System16';
end;

function TSystem18Settings.DIPSection: string;
begin
  Result := 'System18';
end;

procedure TSystem16Settings.Video(Context: TSettingsPageBuilder);
begin
  Context.Heading('Group' + DIPSection + 'DIP', 'DIP switches');
  var A := Context.AddInteger('Row' + DIPSection + 'DIPA', 'DIP bank A',
    'Use -1 for game defaults, or 0-255 to set all eight switches. Reopen the game to apply.',
    DIPSection, 'DIPA', -1, 255);
  A.Min := -1;
  A.ApplyMode := TSettingsApplyMode.OnNextLoad;
  var B := Context.AddInteger('Row' + DIPSection + 'DIPB', 'DIP bank B',
    'Use -1 for game defaults, or 0-255 to set all eight switches. Reopen the game to apply.',
    DIPSection, 'DIPB', -1, 255);
  B.Min := -1;
  B.ApplyMode := TSettingsApplyMode.OnNextLoad;
end;

class function TSystem16Platform.Recognize(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  var RomSet: TS16RomSet;
  if TS16RomSet.Identify(Context.Archive, Context.SourceName, RomSet) then
  begin
    Result := TCoreMatch.Create('System16',
      function: IEmulationCore
      begin
        Context.Stream.Position := 0;
        Result := TS16CoreAdapter.Create(Context.Stream, Context.Storage, Context.RomName);
      end);
    Result.Format.SystemId := 'system16';
  end;
end;

class function TSystem16Platform.RecognizeSystem18(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  var RomSet: TS16RomSet;
  if IdentifySystem18Rom(Context.Archive, Context.SourceName, RomSet) then
  begin
    Result := TCoreMatch.Create('System18',
      function: IEmulationCore
      begin
        Context.Stream.Position := 0;
        Result := TS18CoreAdapter.Create(Context.Stream, Context.Storage, Context.RomName);
      end);
    Result.Format.SystemId := 'system18';
  end;
end;

class procedure TSystem16Platform.LoadLegacyKeys(var Keys: TPlatformInputKeyMap);
var
  Config: IEmulatorConfig;
begin
  var C := TS16Config.Create('', nil);
  Config := C;
  for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
    for var P := 0 to 3 do
      Keys[P, B] := C.Keys[P, B];
end;

class procedure TSystem16Platform.LoadGamepadPreset(Input: TInputManager; Port: Integer);
begin
  for var B := TEmulatorButton.Up to TEmulatorButton.Right do
    AddStandardDirection(Input, Port, PadAction(Port, B), Ord(B), True);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.A), TGamepadButton.West);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.B), TGamepadButton.South);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.C), TGamepadButton.East);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.Select), TGamepadButton.Select);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.Start), TGamepadButton.Start);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.Mode), TGamepadButton.RightStick);
end;

class procedure TSystem16Platform.RegisterPlatform;
begin
  if FRegistered then
    Exit;
  TPlatformRegistry.RegisterPlatform('system16', 'Sega System 16', 'System 16',
    'Sega', 'Sega System16 System 16A 16B arcade', 'system16', ['system16', 'segas16'],
    [], 'System16', 'system16', 4);
  var System16Registration := TEmulationCoreRegistration.Create('System16', []);
  System16Registration.Add(TCoreLoadStage.Container, 20, Recognize);
  RegisterSharedServices('system16', System16Registration, False);

  TPlatformRegistry.RegisterPlatform('system18', 'Sega System 18', 'System 18',
    'Sega', 'Sega System18 arcade', 'system18', ['system18', 'segas18'],
    [], 'System18', 'system18', 4);
  var System18Registration := TEmulationCoreRegistration.Create('System18', []);
  System18Registration.Add(TCoreLoadStage.Container, 20, RecognizeSystem18);
  RegisterSharedServices('system18', System18Registration, True);
  var Services := Default(TPlatformServices);
  Services.TerminalInput :=
    function(const Core: IEmulationCore): TTerminalInputPolicy
    begin
      Result.AllKeys := True;
      Result.ExitKey := $1B;
    end;
  RegisterPlatformServices('system18', Services);
  FRegistered := True;
end;

class procedure TSystem16Platform.RegisterSharedServices(const SystemId: string; Registration: TEmulationCoreRegistration; System18: Boolean);
begin
  RegisterEmulationCore(Registration);
  if System18 then
  begin
    RegisterSnapshotPolicy(SystemId, TSnapshotPolicy.Create(1));
    RegisterSettingsPlatform(SystemId, TSystem18Settings);
  end
  else
  begin
    RegisterSnapshotPolicy(SystemId, TSnapshotPolicy.Create(2));
    RegisterSettingsPlatform(SystemId, TSystem16Settings);
  end;
  RegisterPlatformSettingsDevices(SystemId, TPlatformSettingsDevices);
  RegisterPlatformDeviceCallouts(SystemId, TPlatformDeviceCallouts);
  RegisterPlatformControlsHelp(SystemId, TPlatformControlsHelp);
  RegisterPlatformSettingsHandler(SystemId, TPlatformSettingsHandler);
  RegisterPlatformWindowLayout(SystemId, TPlatformWindowLayout);
  RegisterPlatformSessionHandler(SystemId, TPlatformSessionHandler);
  RegisterPlatformInputHandler(SystemId, TPlatformInputHandler);
  var Definition := TPlatformInputDefinition.Create([TEmulatorButton.Up, TEmulatorButton.Down,
      TEmulatorButton.Left, TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B,
      TEmulatorButton.C, TEmulatorButton.Select, TEmulatorButton.Start, TEmulatorButton.Mode]);
  Definition.ButtonNames[TEmulatorButton.A] := '1';
  Definition.ButtonNames[TEmulatorButton.B] := '2';
  Definition.ButtonNames[TEmulatorButton.C] := '3';
  Definition.ButtonNames[TEmulatorButton.Select] := 'Coin';
  Definition.ButtonNames[TEmulatorButton.Mode] := 'Service';
  Definition.LegacyPorts := 4;
  Definition.LegacySection := 'Keys';
  Definition.AfterLegacyBindings := LoadSharedLegacyBindings;
  Definition.UseSharedBindingRules := True;
  Definition.LoadLegacyKeys := LoadLegacyKeys;
  Definition.LoadGamepadPreset := LoadGamepadPreset;
  RegisterPlatformInput(SystemId, Definition);
  RegisterPlatformGamepads(SystemId, TGamepadSystem16, []);
  RegisterPlatformPresentation(SystemId, SystemId, PlatformIconCPS);
end;

end.

