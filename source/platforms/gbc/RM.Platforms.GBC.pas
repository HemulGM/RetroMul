unit RM.Platforms.GBC;

interface

uses
  Core.EmulatorRegistry, RM.Input, System.SysUtils;

const
  ROM_SYSTEM_GBC = 'gbc';

type
  TGBCPlatform = class
  strict private
    class var
      FRegistered: Boolean;
    class function GBX(Context: TCoreLoadContext): TCoreMatch; static;
    class function Header(Context: TCoreLoadContext): TCoreMatch; static;
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
  GB.Cartridge, RM.Settings.Catalog, RM.Platforms.GB.RomFormat, GB.RomFormat, Core.Snapshots,
  System.StrUtils, Core.Emulation, Core.Platforms, Core.Platforms.GBC.Adapter, RM.Platforms.GBC.Settings,
  RM.Platforms.Presentation, RM.Platforms.GBC.Icons, RM.Gamepad.Factory,
  RM.Platforms.GBC.Gamepads, Core.Platforms.GB.Adapter, GB.Joypad,
  RM.Input.Runtime, RM.Session.Runtime, RM.Window.Layout, RM.Settings.Runtime,
  RM.ControlsHelp.Content, RM.Settings.Callouts, RM.Settings.Devices,
  System.Classes;

const
  GBC_IMAGE_MAX_SIZE = 64 * 1024 * 1024;

class function TGBCPlatform.GBX(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  var Bytes := Context.Data;
  var Footer := ReadGBXFooter(Bytes);
  if not Footer.Present then
    Exit;
  var Header := 0;
  if Footer.Mapper = 'MMM1' then
    Header := Integer(Footer.ROMSize) - $8000;
  var IsColor := Bytes[Header + GB_ROM_CGB_FLAG_OFFSET] in [GB_ROM_CGB_SUPPORTED_FLAG, GB_ROM_CGB_ONLY_FLAG];
  if IsColor then
    Result := ImageMatch(Context, 'GBC',
      function(const Data: TBytes; Input: TStream): IEmulationCore
      begin
        Result := TGBCCoreAdapter.Create(Input, Context.Storage, Context.RomName);
      end, True, 'gbc', '', GBC_IMAGE_MAX_SIZE);
end;

class function TGBCPlatform.Header(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  var Bytes := Context.Data;
  if (Length(Bytes) >= GB_ROM_HEADER_SIZE) and CompareMem(@Bytes[GB_ROM_LOGO_OFFSET], @GB_ROM_LOGO[0], SizeOf(GB_ROM_LOGO)) then
  begin
    var IsColor := Bytes[GB_ROM_CGB_FLAG_OFFSET] in [GB_ROM_CGB_SUPPORTED_FLAG, GB_ROM_CGB_ONLY_FLAG];
    if IsColor then
      Result := ImageMatch(Context, 'GBC',
        function(const Data: TBytes; Input: TStream): IEmulationCore
        begin
          Result := TGBCCoreAdapter.Create(Input, Context.Storage, Context.RomName);
        end, True, 'gbc', '', GBC_IMAGE_MAX_SIZE);
  end;
end;

class procedure TGBCPlatform.RegisterPlatforms;
begin
  TPlatformRegistry.RegisterPlatform('gbc', 'Game Boy Color', 'GBC',
    'Nintendo', 'GBC CGB', 'gbc', ['gbc'],
    ['.gbc', '.gbx', '.zip', '.7z'],
    'GameBoyColor', 'gbc', 1);
end;

class procedure TGBCPlatform.RegisterCore;
begin
  RegisterPlatforms;
  var Registration := TEmulationCoreRegistration.Create('GBC', ['.gbc', '.gbx']);
  Registration.Add(TCoreLoadStage.Header, 70, GBX);
  Registration.Add(TCoreLoadStage.Header, 110, Header);

  RegisterEmulationCore(Registration);
end;

class procedure TGBCPlatform.RegisterServices;
begin
  RegisterSnapshotPolicy('GBC', TSnapshotPolicy.Create(5));
end;

class procedure TGBCPlatform.LoadLegacyKeys(var Keys: TPlatformInputKeyMap);
var
  Config: IEmulatorConfig;

  procedure CopyGB(const Map: TGBKeyMap);
  begin
    Keys[0, TEmulatorButton.A] := Map.A;
    Keys[0, TEmulatorButton.B] := Map.B;
    Keys[0, TEmulatorButton.Select] := Map.Select;
    Keys[0, TEmulatorButton.Start] := Map.Start;
    Keys[0, TEmulatorButton.Up] := Map.Up;
    Keys[0, TEmulatorButton.Down] := Map.Down;
    Keys[0, TEmulatorButton.Left] := Map.Left;
    Keys[0, TEmulatorButton.Right] := Map.Right;
  end;

begin
  var C := TGBEmulatorConfig.Create('');
  Config := C;
  CopyGB(C.GetKeys);
end;

class procedure TGBCPlatform.RegisterInput;
begin
  var Definition := TPlatformInputDefinition.Create([TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left,
      TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.Select, TEmulatorButton.Start]);
  Definition.LegacyPorts := 1;
  Definition.LegacySection := 'Controls';
  Definition.AfterLegacyBindings := LoadSharedLegacyBindings;
  Definition.UseSharedBindingRules := True;
  Definition.LoadLegacyKeys := LoadLegacyKeys;
  RegisterPlatformInput('gbc', Definition);
end;

class procedure TGBCPlatform.RegisterClient;
begin
  RegisterSettingsProfile('GameBoyColor', TGameBoyColorSettings);
  RegisterPlatformSettingsDevices('gbc', TPlatformSettingsDevices);
  RegisterPlatformDeviceCallouts('gbc', TPlatformDeviceCallouts);
  RegisterPlatformControlsHelp('gbc', TPlatformControlsHelp);
  RegisterPlatformSettingsHandler('gbc', TPlatformSettingsHandler);
  RegisterPlatformWindowLayout('gbc', TPlatformWindowLayout);
  RegisterPlatformSessionHandler('gbc', TPlatformSessionHandler);
  RegisterPlatformInputHandler('gbc', TPlatformInputHandler);
  RegisterInput;
  RegisterPlatformGamepads('gbc', TGamepadGBCStandart, []);
  RegisterPlatformPresentation('gbc', 'gbc', PlatformIconGBC);
end;

class procedure TGBCPlatform.RegisterRomFormats;
begin
  RM.Platforms.GB.RomFormat.RegisterGBXReader;
end;

class procedure TGBCPlatform.RegisterPlatform;
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

