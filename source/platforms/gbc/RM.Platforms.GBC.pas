unit RM.Platforms.GBC;

interface

uses
  FMXInput, Core.EmulatorRegistry, RM.Input, System.SysUtils;

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
    class procedure LoadGamepadPreset(Input: TInputManager; Port: Integer); static;
  public
    class procedure RegisterPlatform; static;
  end;

implementation

uses
  RA.Console, Core.PlatformServices, RM.Input.Gamepads, GB.Cartridge,
  RM.Settings.Catalog, RM.Platforms.GB.RomFormat, GB.RomFormat, Core.Snapshots,
  System.StrUtils, Core.Emulation, Core.Platforms, Core.Platforms.GBC.Adapter,
  RM.Platforms.GBC.Settings, RM.Platforms.Presentation, RM.Gamepad.Factory,
  RM.Platforms.GBC.Gamepads, Core.Platforms.GB.Adapter, GB.Joypad,
  RM.Input.Runtime, RM.Session.Runtime, RM.Window.Layout, RM.Settings.Runtime,
  RM.ControlsHelp.Content, RM.Settings.Callouts, RM.Settings.Devices,
  System.Classes;

const
  PlatformIcon =
    'M54.1669998168945,4.16699981689453 C54.1669998168945,3.01599979400635 53.234001159668,2.08299970626831 52.0830' +
    '001831055,2.08299970626831 L14.5830001831055,2.08299970626831 C13.4330005645752,2.08299970626831 12.5,3.015999' +
    '79400635 12.5,4.16699981689453 L12.5,62.5 C12.5,63.6510009765625 13.4329996109009,64.5830001831055 14.58300018' +
    '31055,64.5830001831055 L43.7519989013672,64.5830001831055 C46.5139999389648,64.5830001831055 49.1629981994629,' +
    '63.4860000610352 51.1159973144531,61.5330009460449 C53.0689964294434,59.5800018310547 54.1669960021973,56.9309' +
    '997558594 54.1669960021973,54.169002532959 C54.1669960021973,38.0490036010742 54.1669960021973,4.1670036315918' +
    ' 54.1669960021973,4.1670036315918 Z M23.9580001831055,56.25 L26.0419998168945,56.25 C27.1909999847412,56.25 28' +
    '.125,55.3160018920898 28.125,54.1669998168945 C28.125,53.0169982910156 27.1909999847412,52.0830001831055 26.04' +
    '19998168945,52.0830001831055 L23.9580001831055,52.0830001831055 C22.8090000152588,52.0830001831055 21.875,53.0' +
    '169982910156 21.875,54.1669998168945 C21.875,55.3159980773926 22.8090000152588,56.25 23.9580001831055,56.25 Z ' +
    'M32.2919998168945,56.25 L34.375,56.25 C35.5250015258789,56.25 36.4580001831055,55.3160018920898 36.45800018310' +
    '55,54.1669998168945 C36.4580001831055,53.0169982910156 35.5250015258789,52.0830001831055 34.375,52.08300018310' +
    '55 L32.2919998168945,52.0830001831055 C31.1420001983643,52.0830001831055 30.2080001831055,53.0169982910156 30.' +
    '2080001831055,54.1669998168945 C30.2080001831055,55.3159980773926 31.1420001983643,56.25 32.2919998168945,56.2' +
    '5 Z M40.625,56.25 L42.7080001831055,56.25 C43.8580017089844,56.25 44.7919998168945,55.3160018920898 44.7919998' +
    '168945,54.1669998168945 C44.7919998168945,53.0169982910156 43.8580017089844,52.0830001831055 42.7080001831055,' +
    '52.0830001831055 L40.625,52.0830001831055 C39.4749984741211,52.0830001831055 38.5419998168945,53.0169982910156' +
    ' 38.5419998168945,54.1669998168945 C38.5419998168945,55.3159980773926 39.4749984741211,56.25 40.625,56.25 Z M2' +
    '2.9169998168945,37.5 L21.875,37.5 C20.7250003814697,37.5 19.7919998168945,38.4339981079102 19.7919998168945,39' +
    '.5830001831055 C19.7919998168945,40.7330017089844 20.7250003814697,41.6669998168945 21.875,41.6669998168945 L2' +
    '2.9169998168945,41.6669998168945 L22.9169998168945,42.7080001831055 C22.9169998168945,43.8580017089844 23.8500' +
    '003814697,44.7919998168945 25,44.7919998168945 C26.1499996185303,44.7919998168945 27.0830001831055,43.85800170' +
    '89844 27.0830001831055,42.7080001831055 L27.0830001831055,41.6669998168945 L28.125,41.6669998168945 C29.274999' +
    '6185303,41.6669998168945 30.2080001831055,40.7330017089844 30.2080001831055,39.5830001831055 C30.2080001831055' +
    ',38.4340019226074 29.2749996185303,37.5 28.125,37.5 L27.0830001831055,37.5 L27.0830001831055,36.4580001831055 ' +
    'C27.0830001831055,35.3090019226074 26.1499996185303,34.375 25,34.375 C23.8500003814697,34.375 22.9169998168945' +
    ',35.3089981079102 22.9169998168945,36.4580001831055 L22.9169998168945,37.5 Z M42.1620025634766,41.666999816894' +
    '5 C42.1620025634766,42.8159980773926 41.2280044555664,43.75 40.0780029296875,43.75 C38.9290046691895,43.75 37.' +
    '995002746582,42.8160018920898 37.995002746582,41.6669998168945 C37.995002746582,40.5169982910156 38.9290008544' +
    '922,39.5830001831055 40.0780029296875,39.5830001831055 C41.2280044555664,39.5830001831055 42.1620025634766,40.' +
    '5169982910156 42.1620025634766,41.6669998168945 Z M43.7500038146973,35.4169998168945 C44.9000053405762,35.4169' +
    '998168945 45.8330039978027,36.3499984741211 45.8330039978027,37.5 C45.8330039978027,38.6500015258789 44.900005' +
    '3405762,39.5830001831055 43.7500038146973,39.5830001831055 C42.6000022888184,39.5830001831055 41.6670036315918' +
    ',38.6500015258789 41.6670036315918,37.5 C41.6670036315918,36.3499984741211 42.6000022888184,35.4169998168945 4' +
    '3.7500038146973,35.4169998168945 Z M47.9170036315918,10.4169998168945 C47.9170036315918,9.26599979400635 46.98' +
    '40049743652,8.33300018310547 45.8330039978027,8.33300018310547 L20.8330039978027,8.33300018310547 C19.68300437' +
    '92725,8.33300018310547 18.7500038146973,9.26599979400635 18.7500038146973,10.4169998168945 L18.7500038146973,2' +
    '7.0830001831055 C18.7500038146973,28.234001159668 19.6830043792725,29.1669998168945 20.8330039978027,29.166999' +
    '8168945 L45.8330039978027,29.1669998168945 C46.9840049743652,29.1669998168945 47.9170036315918,28.233999252319' +
    '3 47.9170036315918,27.0830001831055 L47.9170036315918,10.4169998168945 Z M36.7900009155273,19.3600006103516 L3' +
    '3.9440002441406,22.2060012817383 C33.1300010681152,23.0190010070801 33.1300010681152,24.3390007019043 33.94400' +
    '02441406,25.1520004272461 C34.7569999694824,25.9659996032715 36.0769996643066,25.9659996032715 36.889999389648' +
    '4,25.1520004272461 L39.7360000610352,22.3059997558594 C40.548999786377,21.4930000305176 40.548999786377,20.173' +
    '0003356934 39.7360000610352,19.3600006103516 C38.9230003356934,18.5470008850098 37.6030006408691,18.5470008850' +
    '098 36.7900009155273,19.3600006103516 Z M33.9440002441406,12.3480005264282 L26.9309997558594,19.3600006103516 ' +
    'C26.1180000305176,20.1730003356934 26.1180000305176,21.4930000305176 26.9309997558594,22.3059997558594 C27.743' +
    '9994812012,23.1199989318848 29.0639991760254,23.1199989318848 29.8769989013672,22.3059997558594 L36.8899993896' +
    '484,15.293999671936 C37.7029991149902,14.4809999465942 37.7029991149902,13.1609992980957 36.8899993896484,12.3' +
    '479995727539 C36.0769996643066,11.5339994430542 34.7569999694824,11.5339994430542 33.9440002441406,12.34799957' +
    '27539 Z ';
  GBC_IMAGE_MAX_SIZE = 64 * 1024 * 1024;

class procedure TGBCPlatform.LoadGamepadPreset(Input: TInputManager; Port: Integer);
begin
  for var Direction := TEmulatorButton.Up to TEmulatorButton.Right do
    AddStandardDirection(Input, Port, PadAction(Port, Direction), Ord(Direction), True);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.A), TGamepadButton.East);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.B), TGamepadButton.South);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.Select), TGamepadButton.Select);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.Start), TGamepadButton.Start);
end;

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
    ['.gbc', '.gbx'],
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
  Definition.LoadGamepadPreset := LoadGamepadPreset;
  RegisterPlatformInput('gbc', Definition);
end;

class procedure TGBCPlatform.RegisterClient;
begin
  RegisterSettingsProfile('GameBoyColor', TGameBoyColorSettings,
    'The palette changes how monochrome games look. Game Boy Color also has LCD color ' +
    'correction. Boot ROM settings choose the startup sequence. CPU speed above 100% can ' +
    'change game timing as well as reduce slowdown.');
  RegisterPlatformSettingsDevices('gbc', TPlatformSettingsDevices);
  RegisterPlatformDeviceCallouts('gbc', TPlatformDeviceCallouts);
  RegisterPlatformControlsHelp('gbc', TPlatformControlsHelp);
  RegisterPlatformSettingsHandler('gbc', TPlatformSettingsHandler);
  RegisterPlatformWindowLayout('gbc', TPlatformWindowLayout);
  RegisterPlatformSessionHandler('gbc', TPlatformSessionHandler);
  RegisterPlatformInputHandler('gbc', TPlatformInputHandler);
  RegisterInput;
  RegisterPlatformGamepads('gbc', TGamepadGBCStandart, []);
  RegisterPlatformPresentation('gbc', 'gbc', PlatformIcon);
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
  RegisterPlatformAchievementMedia('gbc', RAConsoleGameBoyColor, TPlatformRegistry.Require('gbc').Extensions);
end;

end.

