unit RM.Platforms.PCE;

interface

uses
  FMXInput, Core.EmulatorRegistry, RM.Input, System.SysUtils;

type
  TPCEPlatform = class
  strict private
    class function LoadDisc(Context: TCoreLoadContext): TCoreMatch; static;
    class var
      FRegistered: Boolean;
    class function DiscMatch(Context: TCoreLoadContext): TCoreMatch; static;
    class function Disc(Context: TCoreLoadContext): TCoreMatch; static;
    class function FolderHint(Context: TCoreLoadContext): TCoreMatch; static;
    class function Image(Context: TCoreLoadContext): TCoreMatch; static;
    class procedure RegisterPlatforms; static;
    class procedure RegisterCore; static;
    class procedure RegisterRuntimeServices; static;
    class procedure LoadLegacyKeys(var Keys: TPlatformInputKeyMap); static;
    class procedure RegisterInput; static;
    class procedure RegisterClient; static;
    class procedure LoadGamepadPreset(Input: TInputManager; Port: Integer); static;
  public
    class procedure RegisterPlatform; static;
  end;

implementation

uses
  RM.Input.Gamepads,
  RM.Settings.Catalog, Core.PlatformServices, System.StrUtils, Core.Emulation,
  Core.Platforms, Core.Platforms.PCE.Adapter, RM.Platforms.PCE.Settings,
  RM.Platforms.Presentation, RM.Platforms.PCE.Icons, RM.Gamepad.Factory,
  RM.Platforms.PCE.Gamepads, RM.Input.Runtime, RM.Session.Runtime,
  RM.Window.Layout, RM.Settings.Runtime, RM.Platforms.PCE.SettingsHandler,
  RM.ControlsHelp.Content, RM.Settings.Callouts, RM.Settings.Devices,
  System.Classes;

class procedure TPCEPlatform.LoadGamepadPreset(Input: TInputManager; Port: Integer);
begin
  for var Direction := TEmulatorButton.Up to TEmulatorButton.Right do
    AddStandardDirection(Input, Port, PadAction(Port, Direction), Ord(Direction), True);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.A), TGamepadButton.East);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.B), TGamepadButton.South);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.Select), TGamepadButton.Select);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.Start), TGamepadButton.Start);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.C), TGamepadButton.LeftShoulder);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.X), TGamepadButton.North);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.Y), TGamepadButton.West);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.Z), TGamepadButton.RightShoulder);
end;

class function TPCEPlatform.LoadDisc(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := TCoreMatch.Create('PCECD',
    function: IEmulationCore
    begin
      Context.Stream.Position := 0;
      Result := TPCECoreAdapter.Create(Context.Stream, Context.EffectiveStorage, Context.RomName, Context.TakeDisc);
    end);
  Result.Format.SystemId := 'pcecd';
end;

class function TPCEPlatform.DiscMatch(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := TCoreMatch.Create('PCECD',
    function: IEmulationCore
    begin
      Result := TPCECoreAdapter.Create(Context.Stream, Context.Storage, Context.RomName, Context.TakeDisc);
    end);
end;

class function TPCEPlatform.Disc(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  if Context.IsDiscSource then
    for var Offset := 0 to 1 do
      if TEncoding.ASCII.GetString(Context.DiscSector(Offset)).Contains('PC Engine CD-ROM SYSTEM') then
        Exit(DiscMatch(Context));
end;

class function TPCEPlatform.FolderHint(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  if not Context.IsDiscSource then
    Exit;
  var Folder := ExtractFileName(ExcludeTrailingPathDelimiter(ExtractFilePath(Context.SourceName)));
  if SameText(Folder, 'pcecd') or SameText(Folder, 'pcenginecd') then
  begin
    Result := DiscMatch(Context);
    Result.Confidence := TCoreMatchConfidence.Hint;
  end;
end;

class function TPCEPlatform.Image(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  if Context.HasExtension(['.pce', '.sgx']) then
  begin
    Result := ImageMatch(Context, 'PCE',
      function(const Data: TBytes; Input: TStream): IEmulationCore
      begin
        Result := TPCECoreAdapter.Create(Input, Context.Storage, Context.RomName, nil, Context.SourceName);
      end);
    Result.Format.SystemId := 'pce';
    if Context.HasExtension(['.sgx']) or (Context.SelectedPlatform = 'sgx') then
      Result.Format.SystemId := 'sgx';
  end;
end;

class procedure TPCEPlatform.RegisterPlatforms;
begin
  TPlatformRegistry.RegisterPlatform('pce', 'PC Engine / TurboGrafx-16', 'PCE',
    'NEC', 'PCE CoreGrafx Shuttle GT LT TurboExpress', 'pcengine', ['pcengine', 'pce'],
    ['.pce'],
    'PCE', 'pce', 5);
  TPlatformRegistry.RegisterPlatform('sgx', 'SuperGrafx', 'SuperGrafx',
    'NEC', 'SGX', 'sgx', ['sgx', 'supergrafx', 'pcengine', 'pce'],
    ['.sgx', '.pce'],
    'PCE', 'sgx', 5);
  TPlatformRegistry.RegisterPlatform('pcecd', 'PC Engine CD', 'PCE CD',
    'NEC', 'CD-ROM2 Super CD-ROM2 Duo TurboDuo Arcade Card', 'pcenginecd', ['pcenginecd', 'pcecd'],
    ['.cue', '.iso', '.chd', '.mds', '.nrg'],
    'PCE', 'pcecd', 5);
end;

class procedure TPCEPlatform.RegisterCore;
begin
  RegisterPlatforms;
  var Registration := TEmulationCoreRegistration.Create('PCE', ['.pce', '.sgx']);
  Registration.Add(TCoreLoadStage.Source, 70, Disc);
  Registration.Add(TCoreLoadStage.Source, 90, FolderHint);
  Registration.Add(TCoreLoadStage.Image, 20, Image);
  Registration.AddDiscPlatform('pcecd', LoadDisc);
  RegisterEmulationCore(Registration);
end;

class procedure TPCEPlatform.RegisterRuntimeServices;
begin
  var Service := Default(TPlatformServices);
  Service.TerminalInput :=
    function(const Core: IEmulationCore): TTerminalInputPolicy
    begin
      Result := Default(TTerminalInputPolicy);
      Result.ExitKey := $1B;
      Result.AllKeys := True;
    end;
  RegisterPlatformServices('pce', Service);
  RegisterPlatformServices('sgx', Service);
  RegisterPlatformServices('pcecd', Service);
end;

class procedure TPCEPlatform.LoadLegacyKeys(var Keys: TPlatformInputKeyMap);
var
  Config: IEmulatorConfig;
begin
  var C := TPCEConfig.Create('');
  Config := C;
  for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
  begin
    Keys[0, B] := C.Keys[B];
    Keys[1, B] := C.Keys2[B];
  end;
end;

class procedure TPCEPlatform.RegisterInput;
begin
  var Definition := TPlatformInputDefinition.Create([TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left,
      TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.Select, TEmulatorButton.Start]);
  Definition.PadDevicesOnly := False;
  Definition.Devices := TArray<TInputDeviceVariant>.Create(TInputDeviceVariant.Create('none', []),
    TInputDeviceVariant.Create('pad6', [TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left,
        TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.Select, TEmulatorButton.Start,
        TEmulatorButton.C, TEmulatorButton.X, TEmulatorButton.Y, TEmulatorButton.Z]));
  Definition.ButtonNames[TEmulatorButton.A] := 'I';
  Definition.ButtonNames[TEmulatorButton.B] := 'II';
  Definition.ButtonNames[TEmulatorButton.Start] := 'Run';
  Definition.ButtonNames[TEmulatorButton.C] := 'V';
  Definition.ButtonNames[TEmulatorButton.X] := 'III';
  Definition.ButtonNames[TEmulatorButton.Y] := 'IV';
  Definition.ButtonNames[TEmulatorButton.Z] := 'VI';
  Definition.LegacyPorts := 5;
  Definition.LegacySection := 'Keys';
  Definition.AfterLegacyBindings := LoadSharedLegacyBindings;
  Definition.UseSharedBindingRules := True;
  Definition.LoadLegacyKeys := LoadLegacyKeys;
  Definition.LegacyButtons := [TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left,
      TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.Select, TEmulatorButton.Start,
      TEmulatorButton.C, TEmulatorButton.X, TEmulatorButton.Y, TEmulatorButton.Z];
  Definition.LoadGamepadPreset := LoadGamepadPreset;
  RegisterPlatformInput('pce', Definition);
  RegisterPlatformInput('sgx', Definition);
  RegisterPlatformInput('pcecd', Definition);
end;

class procedure TPCEPlatform.RegisterClient;
begin
  RegisterSettingsProfile('PCE', TPCESettings);
  RegisterPlatformSettingsDevices('pce', TPlatformSettingsDevices);
  RegisterPlatformSettingsDevices('sgx', TPlatformSettingsDevices);
  RegisterPlatformSettingsDevices('pcecd', TPlatformSettingsDevices);
  RegisterPlatformDeviceCallouts('pce', TPlatformDeviceCallouts);
  RegisterPlatformDeviceCallouts('sgx', TPlatformDeviceCallouts);
  RegisterPlatformDeviceCallouts('pcecd', TPlatformDeviceCallouts);
  RegisterPlatformControlsHelp('pce', TPlatformControlsHelp);
  RegisterPlatformControlsHelp('sgx', TPlatformControlsHelp);
  RegisterPlatformControlsHelp('pcecd', TPlatformControlsHelp);
  RegisterPlatformSettingsHandler('pce', TPCESettingsHandler);
  RegisterPlatformSettingsHandler('sgx', TPCESettingsHandler);
  RegisterPlatformSettingsHandler('pcecd', TPCESettingsHandler);
  RegisterPlatformWindowLayout('pce', TPlatformWindowLayout);
  RegisterPlatformWindowLayout('sgx', TPlatformWindowLayout);
  RegisterPlatformWindowLayout('pcecd', TPlatformWindowLayout);
  RegisterPlatformSessionHandler('pce', TPlatformSessionHandler);
  RegisterPlatformSessionHandler('sgx', TPlatformSessionHandler);
  RegisterPlatformSessionHandler('pcecd', TPlatformSessionHandler);
  RegisterPlatformInputHandler('pce', TPlatformInputHandler);
  RegisterPlatformInputHandler('sgx', TPlatformInputHandler);
  RegisterPlatformInputHandler('pcecd', TPlatformInputHandler);
  RegisterInput;
  RegisterPlatformGamepads('pce', TGamepadPCEPad2, [TGamepadDeviceVariant.Create('pad6', TGamepadPCEPad6)]);
  RegisterPlatformGamepads('sgx', TGamepadSuperGrafxPad2, [TGamepadDeviceVariant.Create('pad6', TGamepadSuperGrafxPad6)]);
  RegisterPlatformGamepads('pcecd', TGamepadPCECDPad2, [TGamepadDeviceVariant.Create('pad6', TGamepadPCECDPad6)]);
  RegisterPlatformPresentation('pce', 'pce', PlatformIconPCE);
  RegisterPlatformPresentation('sgx', 'sgx', PlatformIconSGX);
  RegisterPlatformPresentation('pcecd', 'pcecd', PlatformIconPCECD);
end;

class procedure TPCEPlatform.RegisterPlatform;
begin
  if FRegistered then
    Exit;
  RegisterRuntimeServices;
  RegisterCore;
  RegisterClient;
  FRegistered := True;
end;

end.

