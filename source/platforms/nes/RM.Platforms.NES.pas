unit RM.Platforms.NES;

interface

uses
  Core.EmulatorRegistry, RM.Input, System.SysUtils;

type
  TNESPlatform = class
  strict private
    class var
      FRegistered: Boolean;
    class function Recognize(Context: TCoreLoadContext): TCoreMatch; static;
    class procedure RegisterPlatforms; static;
    class procedure RegisterCore; static;
    class procedure RegisterRuntimeServices; static;
    class procedure LoadLegacyKeys(var Keys: TPlatformInputKeyMap); static;
    class procedure RegisterInput; static;
    class procedure RegisterClient; static;
  public
    class procedure RegisterPlatform; static;
  end;

implementation

uses
  NES.Cartridge, RM.Settings.Catalog, Core.InputConfig, System.IniFiles, Core.PlatformServices,
  System.StrUtils, Core.Emulation, Core.Platforms, Core.Platforms.NES.Adapter, RM.Platforms.NES.Settings,
  RM.Platforms.Presentation, RM.Platforms.NES.Icons, RM.Gamepad.Factory,
  RM.Platforms.NES.Gamepads, NES.Controller, NES.Types, RM.Input.Runtime,
  RM.Platforms.NES.Input, RM.Session.Runtime, RM.Platforms.NES.Session,
  RM.Window.Layout, RM.Platforms.NES.Window, RM.Settings.Runtime,
  RM.Platforms.NES.SettingsHandler, RM.ControlsHelp.Content,
  RM.Platforms.NES.Help, RM.Settings.Callouts, RM.Platforms.NES.Devices,
  RM.Settings.Devices, System.Classes;

const
  NES_IMAGE_MAX_SIZE = 64 * 1024 * 1024;

class function TNESPlatform.Recognize(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;

  if Context.Signature(0, NES_ROM_SIGNATURE) then
    Result := ImageMatch(Context, 'NES',
      function(const Data: TBytes; Input: TStream): IEmulationCore
      begin
        Result := TNesCoreAdapter.Create(Input, Context.Storage, Context.RomName);
      end, True, 'nes', '', NES_IMAGE_MAX_SIZE);
end;

class procedure TNESPlatform.RegisterPlatforms;
begin
  TPlatformRegistry.RegisterPlatform('nes', 'NES / Famicom', 'NES',
    'Nintendo', 'NES Famicom Dendy', 'nes', ['nes'],
    ['.nes', '.zip', '.7z'], 'NES', 'nes', 2);
end;

class procedure TNESPlatform.RegisterCore;
begin
  RegisterPlatforms;
  var Registration := TEmulationCoreRegistration.Create('NES', ['.nes']);
  Registration.Add(TCoreLoadStage.Header, 100, Recognize);
  RegisterEmulationCore(Registration);
end;

class procedure TNESPlatform.RegisterRuntimeServices;
begin
  var Service := Default(TPlatformServices);
  Service.UnprefixedSaveIdentity := True;
  Service.DocumentSelection.Title := 'Choose a cassette file';
  Service.DocumentSelection.FileFilter := 'Cassette (*.tape)|*.tape|All files|*.*';
  Service.DocumentSelection.AllowedExtensions := ['.tape'];
  RegisterPlatformServices('nes', Service);
end;

class procedure TNESPlatform.LoadLegacyKeys(var Keys: TPlatformInputKeyMap);
var
  Config: IEmulatorConfig;

  procedure CopyNES(Port: Integer; const Map: TKeyMap);
  begin
    Keys[Port, TEmulatorButton.A] := Map.A;
    Keys[Port, TEmulatorButton.B] := Map.B;
    Keys[Port, TEmulatorButton.Select] := Map.Select;
    Keys[Port, TEmulatorButton.Start] := Map.Start;
    Keys[Port, TEmulatorButton.Up] := Map.Up;
    Keys[Port, TEmulatorButton.Down] := Map.Down;
    Keys[Port, TEmulatorButton.Left] := Map.Left;
    Keys[Port, TEmulatorButton.Right] := Map.Right;
  end;

begin
  var C := TNesEmulatorConfig.Create('');
  Config := C;
  CopyNES(0, C.GetKeys);
  CopyNES(1, C.GetKeys2);
  CopyNES(2, C.GetKeys3);
  CopyNES(3, C.GetKeys4);
end;

class procedure TNESPlatform.RegisterInput;
begin
  var Definition := TPlatformInputDefinition.Create([TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left,
      TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.Select, TEmulatorButton.Start]);
  Definition.Devices := TArray<TInputDeviceVariant>.Create(TInputDeviceVariant.Create('paddendy',
      [TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left, TEmulatorButton.Right, TEmulatorButton.A,
        TEmulatorButton.B, TEmulatorButton.Select, TEmulatorButton.Start, TEmulatorButton.X, TEmulatorButton.Y]));
  Definition.ButtonNames[TEmulatorButton.X] := 'Turbo B';
  Definition.ButtonNames[TEmulatorButton.Y] := 'Turbo A';
  Definition.LegacyPorts := 4;
  Definition.LegacySection := 'Controls';
  Definition.AfterLegacyBindings := LoadSharedLegacyBindings;
  Definition.UseSharedBindingRules := True;
  Definition.LoadLegacyKeys := LoadLegacyKeys;
  Definition.LegacyKeyNames[TEmulatorButton.X] := 'Turbo B';
  Definition.LegacyKeyNames[TEmulatorButton.Y] := 'Turbo A';
  Definition.AfterLoadBindings := EnsurePeripheralBindings;
  Definition.SharedLegacyBindings := LoadNesLegacyAuxiliaries;
  Definition.SharedFilterBinding := FilterNesCompatibilityBinding;
  Definition.SharedBindingOrder := 10;
  RegisterPlatformInput('nes', Definition);
end;

class procedure TNESPlatform.RegisterClient;
begin
  RegisterSettingsProfile('NES', TNESSettings);
  RegisterPlatformSettingsDevices('nes', TNESSettingsDevices);
  RegisterPlatformDeviceCallouts('nes', TNESDeviceCallouts);
  RegisterPlatformControlsHelp('nes', TNESControlsHelp);
  RegisterPlatformSettingsHandler('nes', TNesSettingsHandler);
  RegisterPlatformWindowLayout('nes', TNesWindowLayout);
  RegisterPlatformSessionHandler('nes', TNesSessionHandler);
  RegisterPlatformInputHandler('nes', TNesInputHandler);
  RegisterInput;
  RegisterPlatformGamepads('nes', TGamepadNESStandart, [TGamepadDeviceVariant.Create('paddendy', TGamepadNESDendy)]);
  RegisterPlatformPresentation('nes', 'nes', PlatformIconNES);
end;

class procedure TNESPlatform.RegisterPlatform;
begin
  if FRegistered then
    Exit;
  RegisterInputPortsReader('nes',
    procedure(Ini: TCustomIniFile; var Ports: TCoreInputPorts)
    begin
      Ports.FourScore := Ini.ReadBool('Input', 'FourScore', Ports.FourScore);
      Ports.LegacyZapper := Ini.ReadBool('Input', 'Zapper', Ports.LegacyZapper);
    end);
  RegisterRuntimeServices;
  RegisterCore;
  RegisterClient;
  FRegistered := True;
end;

end.

