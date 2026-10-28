unit RM.Platforms.GB;

interface

uses
  Core.EmulatorRegistry, RM.Input, System.SysUtils;

const
  ROM_SYSTEM_GB = 'gb';

type
  TGBPlatform = class
  strict private
    class var
      FRegistered: Boolean;
    class function GBX(Context: TCoreLoadContext): TCoreMatch; static;
    class function Header(Context: TCoreLoadContext): TCoreMatch; static;
    class function MMM01(Context: TCoreLoadContext): TCoreMatch; static;
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
  System.StrUtils, Core.Emulation, Core.Platforms, Core.Platforms.GB.Adapter, RM.Platforms.GB.Settings, RM.Platforms.Presentation,
  RM.Platforms.GB.Icons, RM.Gamepad.Factory, RM.Platforms.GB.Gamepads, GB.Joypad,
  RM.Input.Runtime, RM.Session.Runtime, RM.Window.Layout, RM.Settings.Runtime,
  RM.ControlsHelp.Content, RM.Settings.Callouts, RM.Settings.Devices,
  RM.Settings.PalettePreview, RM.Platforms.GB.PalettePreview, System.Classes;

const
  GB_IMAGE_MAX_SIZE = 64 * 1024 * 1024;

class function TGBPlatform.GBX(Context: TCoreLoadContext): TCoreMatch;
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
  if not IsColor then
    Result := ImageMatch(Context, 'GB',
      function(const Data: TBytes; Input: TStream): IEmulationCore
      begin
        Result := TGBCoreAdapter.Create(Input, Context.Storage, Context.RomName);
      end, True, 'gb', '', GB_IMAGE_MAX_SIZE);
end;

class function TGBPlatform.Header(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  var Bytes := Context.Data;
  if (Length(Bytes) >= GB_ROM_HEADER_SIZE) and CompareMem(@Bytes[GB_ROM_LOGO_OFFSET], @GB_ROM_LOGO[0], SizeOf(GB_ROM_LOGO)) then
  begin
    var IsColor := Bytes[GB_ROM_CGB_FLAG_OFFSET] in [GB_ROM_CGB_SUPPORTED_FLAG, GB_ROM_CGB_ONLY_FLAG];
    if not IsColor then
      Result := ImageMatch(Context, 'GB',
        function(const Data: TBytes; Input: TStream): IEmulationCore
        begin
          Result := TGBCoreAdapter.Create(Input, Context.Storage, Context.RomName);
        end, True, 'gb', '', GB_IMAGE_MAX_SIZE);
  end;
end;

class function TGBPlatform.MMM01(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  var Bytes := Context.Data;
  if (Length(Bytes) >= GB_ROM_MIN_SIZE) and
    (Bytes[Length(Bytes) - $8000 + GB_ROM_CARTRIDGE_TYPE_OFFSET] in [$0B..$0D]) and
    CompareMem(@Bytes[Length(Bytes) - $8000 + GB_ROM_LOGO_OFFSET], @GB_ROM_LOGO[0], SizeOf(GB_ROM_LOGO)) then
    Result := ImageMatch(Context, 'GB',
      function(const Data: TBytes; Input: TStream): IEmulationCore
      begin
        Result := TGBCoreAdapter.Create(Input, Context.Storage, Context.RomName);
      end, True, 'gb', '', GB_IMAGE_MAX_SIZE);
end;

class procedure TGBPlatform.RegisterPlatforms;
begin
  TPlatformRegistry.RegisterPlatform('gb', 'Game Boy', 'GB',
    'Nintendo', 'GB DMG MGB', 'gb', ['gb'],
    ['.gb', '.gbx', '.zip', '.7z'],
    'GameBoy', 'gb', 1);
end;

class procedure TGBPlatform.RegisterCore;
begin
  RegisterPlatforms;
  var Registration := TEmulationCoreRegistration.Create('GB', ['.gb', '.gbx']);
  Registration.Add(TCoreLoadStage.Header, 70, GBX);
  Registration.Add(TCoreLoadStage.Header, 110, Header);
  Registration.Add(TCoreLoadStage.Header, 111, MMM01);
  RegisterEmulationCore(Registration);
end;

class procedure TGBPlatform.RegisterServices;
begin
  RegisterSnapshotPolicy('GB', TSnapshotPolicy.Create(5));
end;

class procedure TGBPlatform.LoadLegacyKeys(var Keys: TPlatformInputKeyMap);
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

class procedure TGBPlatform.RegisterInput;
begin
  var Definition := TPlatformInputDefinition.Create([TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left,
      TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.Select, TEmulatorButton.Start]);
  Definition.LegacyPorts := 1;
  Definition.LegacySection := 'Controls';
  Definition.AfterLegacyBindings := LoadSharedLegacyBindings;
  Definition.UseSharedBindingRules := True;
  Definition.LoadLegacyKeys := LoadLegacyKeys;
  RegisterPlatformInput('gb', Definition);
end;

class procedure TGBPlatform.RegisterClient;
begin
  RegisterSettingsProfile('GameBoy', TGameBoySettings);
  RegisterPlatformPalettePreview('gb', TGameBoyPalettePreview);
  RegisterPlatformSettingsDevices('gb', TPlatformSettingsDevices);
  RegisterPlatformDeviceCallouts('gb', TPlatformDeviceCallouts);
  RegisterPlatformControlsHelp('gb', TPlatformControlsHelp);
  RegisterPlatformSettingsHandler('gb', TPlatformSettingsHandler);
  RegisterPlatformWindowLayout('gb', TPlatformWindowLayout);
  RegisterPlatformSessionHandler('gb', TPlatformSessionHandler);
  RegisterPlatformInputHandler('gb', TPlatformInputHandler);
  RegisterInput;
  RegisterPlatformGamepads('gb', TGamepadGBStandart, []);
  RegisterPlatformPresentation('gb', 'gb', PlatformIconGB);
end;

class procedure TGBPlatform.RegisterRomFormats;
begin
  RM.Platforms.GB.RomFormat.RegisterGBXReader;
end;

class procedure TGBPlatform.RegisterPlatform;
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

