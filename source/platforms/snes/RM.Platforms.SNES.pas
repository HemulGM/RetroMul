unit RM.Platforms.SNES;

interface

uses
  Core.EmulatorRegistry, RM.Input, System.SysUtils;

const
  ROM_SYSTEM_SNES = 'snes';

type
  TSNESPlatform = class
  strict private
    class var
      FRegistered: Boolean;
    class function Recognize(Context: TCoreLoadContext): TCoreMatch; static;
    class procedure RegisterPlatforms; static;
    class procedure RegisterRomFormats; static;
    class procedure RegisterCore; static;
    class procedure RegisterServices; static;
    class procedure LoadLegacyKeys(var Keys: TPlatformInputKeyMap); static;
    class procedure RegisterInput; static;
    class procedure RegisterClient; static;
  public
    class procedure RegisterPlatform; static;
  end;

implementation

uses
  RM.Settings.Catalog, SNES.RomFormat, Core.Snapshots,
  System.StrUtils, Core.Emulation, Core.Platforms, Core.Platforms.SNES.Adapter, SNES.Cartridge, RM.Platforms.SNES.Settings,
  RM.Platforms.Presentation, RM.Platforms.SNES.Icons, RM.Gamepad.Factory,
  RM.Platforms.SNES.Gamepads, SNES.Console, RM.Input.Runtime, RM.Session.Runtime,
  RM.Window.Layout, RM.Settings.Runtime, RM.Platforms.SNES.SettingsHandler,
  RM.ControlsHelp.Content, RM.Settings.Callouts, RM.Platforms.SNES.Callouts,
  RM.Settings.Devices, System.Classes;

const
  SNES_IMAGE_MAX_SIZE = 64 * 1024 * 1024;

class function TSNESPlatform.Recognize(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  var Header: TSnesHeader;
  if not DetectSnesHeader(Context.Data, Header) then
    Exit;
  var Encoding := '';
  if Header.CopierSize <> 0 then
    Encoding := SNES_ENCODING_COPIER;
  Result := ImageMatch(Context, 'SNES',
    function(const Data: TBytes; Input: TStream): IEmulationCore
    begin
      Result := TSnesCoreAdapter.Create(Input, Context.Storage, Context.RomName);
    end, True, 'snes', Encoding, SNES_IMAGE_MAX_SIZE);
end;

class procedure TSNESPlatform.RegisterPlatforms;
begin
  TPlatformRegistry.RegisterPlatform('snes', 'Super Nintendo', 'SNES',
    'Nintendo', 'SNES Super Famicom', 'snes', ['snes'],
    ['.sfc', '.smc', '.swc', '.fig', '.zip', '.7z'],
    'SNES', 'snes', 2);
end;

class procedure TSNESPlatform.RegisterCore;
begin
  RegisterPlatforms;
  var Registration := TEmulationCoreRegistration.Create('SNES', ['.sfc', '.smc', '.swc', '.fig']);
  Registration.Add(TCoreLoadStage.Header, 140, Recognize);
  RegisterEmulationCore(Registration);
end;

class procedure TSNESPlatform.RegisterServices;
begin
  RegisterSnapshotPolicy('SNES', TSnapshotPolicy.Create(10));
end;

class procedure TSNESPlatform.LoadLegacyKeys(var Keys: TPlatformInputKeyMap);
const
  SNESMapping: array[TSnesButton] of TEmulatorButton = (TEmulatorButton.Up,
    TEmulatorButton.Down, TEmulatorButton.Left, TEmulatorButton.Right,
    TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.Select, TEmulatorButton.Start,
    TEmulatorButton.X, TEmulatorButton.Y, TEmulatorButton.C, TEmulatorButton.Z);
var
  Config: IEmulatorConfig;
begin
  var C := TSnesConfig.Create('');
  Config := C;
  for var B := Low(TSnesButton) to High(TSnesButton) do
  begin
    for var Port := 0 to 7 do
    begin
      var Map := C.KeyMap(Port);
      Keys[Port, SNESMapping[B]] := Map[B];
    end;
  end;
end;

class procedure TSNESPlatform.RegisterInput;
begin
  var Definition := TPlatformInputDefinition.Create([TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left,
      TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.Select, TEmulatorButton.Start,
      TEmulatorButton.C, TEmulatorButton.X, TEmulatorButton.Y, TEmulatorButton.Z]);
  Definition.ButtonNames[TEmulatorButton.C] := 'L';
  Definition.ButtonNames[TEmulatorButton.Z] := 'R';
  Definition.LegacyPorts := 8;
  Definition.LegacySection := 'Keys';
  Definition.AfterLegacyBindings := LoadSharedLegacyBindings;
  Definition.UseSharedBindingRules := True;
  Definition.LoadLegacyKeys := LoadLegacyKeys;
  Definition.LegacyKeyNames[TEmulatorButton.C] := 'L';
  Definition.LegacyKeyNames[TEmulatorButton.Z] := 'R';
  RegisterPlatformInput('snes', Definition);
end;

class procedure TSNESPlatform.RegisterClient;
begin
  RegisterSettingsProfile('SNES', TSNESSettings);
  RegisterPlatformSettingsDevices('snes', TPlatformSettingsDevices);
  RegisterPlatformDeviceCallouts('snes', TSNESDeviceCallouts);
  RegisterPlatformControlsHelp('snes', TPlatformControlsHelp);
  RegisterPlatformSettingsHandler('snes', TSNESSettingsHandler);
  RegisterPlatformWindowLayout('snes', TPlatformWindowLayout);
  RegisterPlatformSessionHandler('snes', TPlatformSessionHandler);
  RegisterPlatformInputHandler('snes', TPlatformInputHandler);
  RegisterInput;
  RegisterPlatformGamepads('snes', TGamepadSNESStandart, []);
  RegisterPlatformPresentation('snes', 'snes', PlatformIconSNES);
end;

class procedure TSNESPlatform.RegisterRomFormats;
begin
  RegisterRomEncoding(SNES_ENCODING_COPIER,
    function(const Data: TBytes): TBytes
    begin
      Result := SNES.RomFormat.NormalizeImage(Data, SNES_ENCODING_COPIER);
    end);
  RegisterRomNormalizer('snes',
    function(const Data: TBytes; const Format: TRomFormatInfo): TBytes
    begin
      Result := SNES.RomFormat.NormalizeImage(Data, Format.Encoding);
    end);
end;

class procedure TSNESPlatform.RegisterPlatform;
begin
  if FRegistered then
    Exit;
  RegisterRomFormats;
  RegisterServices;
  RegisterCore;
  RegisterClient;
  FRegistered := True;
end;

end.

