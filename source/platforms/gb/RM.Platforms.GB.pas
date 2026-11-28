unit RM.Platforms.GB;

interface

uses
  FMXInput, Core.EmulatorRegistry, RM.Input, System.SysUtils;

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
    class procedure LoadGamepadPreset(Input: TInputManager; Port: Integer); static;
  public
    class procedure RegisterPlatform; static;
  end;

implementation

uses
  RA.Console, Core.PlatformServices, RM.Input.Gamepads, GB.Cartridge,
  RM.Settings.Catalog, RM.Platforms.GB.RomFormat, GB.RomFormat, Core.Snapshots,
  System.StrUtils, Core.Emulation, Core.Platforms, Core.Platforms.GB.Adapter,
  RM.Platforms.GB.Settings, RM.Platforms.Presentation, RM.Gamepad.Factory,
  RM.Platforms.GB.Gamepads, GB.Joypad, RM.Input.Runtime, RM.Session.Runtime,
  RM.Window.Layout, RM.Settings.Runtime, RM.ControlsHelp.Content,
  RM.Settings.Callouts, RM.Settings.Devices, RM.Settings.PalettePreview,
  RM.Platforms.GB.PalettePreview, System.Classes;

const
  PlatformIcon =
    'M50,4 L14,4 C12.8999996185303,4 12,4.90000009536743 12,6 L12,56 C12,58.2099990844727 13.789999961853,60 16,60 ' +
    'L48,60 C50.2099990844727,60 52,58.2099990844727 52,56 L52,6 C52,4.90000009536743 51.0999984741211,4 50,4 Z M27' +
    ',44 L24,44 L24,47 L20,47 L20,44 L17,44 L17,40 L20,40 L20,37 L24,37 L24,40 L27,40 L27,44 Z M30,56 L29,56 C28.45' +
    '00007629395,56 28,55.5499992370605 28,55 C28,54.4500007629395 28.4500007629395,54 29,54 L30,54 C30.54999923706' +
    '05,54 31,54.4500007629395 31,55 C31,55.5499992370605 30.5499992370605,56 30,56 Z M35,56 L34,56 C33.45000076293' +
    '95,56 33,55.5499992370605 33,55 C33,54.4500007629395 33.4500007629395,54 34,54 L35,54 C35.5499992370605,54 36,' +
    '54.4500007629395 36,55 C36,55.5499992370605 35.5499992370605,56 35,56 Z M38,48 C36.3400001525879,48 35,46.6599' +
    '998474121 35,45 C35,43.3400001525879 36.3400001525879,42 38,42 C39.6599998474121,42 41,43.3400001525879 41,45 ' +
    'C41,46.6599998474121 39.6599998474121,48 38,48 Z M45,41 C43.3400001525879,41 42,39.6599998474121 42,38 C42,36.' +
    '3400001525879 43.3400001525879,35 45,35 C46.6599998474121,35 48,36.3400001525879 48,38 C48,39.6599998474121 46' +
    '.6599998474121,41 45,41 Z M48,30 L16,30 L16,8 L48,8 L48,30 Z ';
  GB_IMAGE_MAX_SIZE = 64 * 1024 * 1024;

class procedure TGBPlatform.LoadGamepadPreset(Input: TInputManager; Port: Integer);
begin
  for var Direction := TEmulatorButton.Up to TEmulatorButton.Right do
    AddStandardDirection(Input, Port, PadAction(Port, Direction), Ord(Direction), True);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.A), TGamepadButton.East);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.B), TGamepadButton.South);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.Select), TGamepadButton.Select);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.Start), TGamepadButton.Start);
end;

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
    ['.gb', '.gbx'],
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
  Definition.LoadGamepadPreset := LoadGamepadPreset;
  RegisterPlatformInput('gb', Definition);
end;

class procedure TGBPlatform.RegisterClient;
begin
  RegisterSettingsProfile('GameBoy', TGameBoySettings,
    'The palette changes how monochrome games look. Game Boy Color also has LCD color ' +
    'correction. Boot ROM settings choose the startup sequence. CPU speed above 100% can ' +
    'change game timing as well as reduce slowdown.');
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
  RegisterPlatformPresentation('gb', 'gb', PlatformIcon);
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
  RegisterPlatformAchievementMedia('gb', RAConsoleGameBoy, TPlatformRegistry.Require('gb').Extensions);
end;

end.

