unit RM.Platforms.MD;

interface

uses
  FMXInput, Core.EmulatorRegistry, RM.Input, System.SysUtils;

const
  ROM_SYSTEM_MD = 'md';
  ROM_SYSTEM_SEGACD = 'segacd';
  ROM_SYSTEM_SEGA32X = 'sega32x';

type
  TMDPlatform = class
  strict private
    class function LoadDisc(Context: TCoreLoadContext): TCoreMatch; static;
    class var
      FRegistered: Boolean;
    class function Header(Context: TCoreLoadContext): TCoreMatch; static;
    class function Disc(Context: TCoreLoadContext): TCoreMatch; static;
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
  RA.Console, Core.PlatformServices, RM.Input.Gamepads, MD.Cartridge,
  RM.Settings.Catalog, MD.RomFormat, Core.Snapshots, System.StrUtils,
  Core.Emulation, Core.Platforms, Core.Platforms.MD.Adapter,
  RM.Platforms.MD.Settings, RM.Platforms.Presentation, RM.Gamepad.Factory,
  RM.Platforms.MD.Gamepads, MD.Console, RM.Input.Runtime, RM.Session.Runtime,
  RM.Window.Layout, RM.Settings.Runtime, RM.ControlsHelp.Content,
  RM.Settings.Callouts, RM.Settings.Devices, System.Classes;

const
  PlatformIcon =
    'M69.6999969482422,50.5 C69.6999969482422,52.8195953369141 67.8195953369141,54.7000007629395 65.5,54.7000007629' +
    '395 C63.1804046630859,54.7000007629395 61.2999992370605,52.8195953369141 61.2999992370605,50.5 C61.29999923706' +
    '05,48.1804046630859 63.1804046630859,46.2999992370605 65.5,46.2999992370605 C67.8195953369141,46.2999992370605' +
    ' 69.6999969482422,48.1804046630859 69.6999969482422,50.5 Z M78.7999954223633,45.2999992370605 C78.799995422363' +
    '3,47.5643653869629 76.9643630981445,49.3999977111816 74.6999969482422,49.3999977111816 C72.4356307983398,49.39' +
    '99977111816 70.5999984741211,47.5643653869629 70.5999984741211,45.2999992370605 C70.5999984741211,43.035633087' +
    '1582 72.4356307983398,41.2000007629395 74.6999969482422,41.2000007629395 C76.9643630981445,41.2000007629395 78' +
    '.7999954223633,43.0356330871582 78.7999954223633,45.2999992370605 Z M84.0999984741211,38 C81.9000015258789,38 ' +
    '80.5,39.5999984741211 80.5,41.7999992370605 C80.5,44.2000007629395 82.8000030517578,45.7999992370605 84.300003' +
    '0517578,45.7999992370605 C86.5,45.7999992370605 88.1000061035156,44.2000007629395 88.1000061035156,42 C88.1000' +
    '061035156,39.7999992370605 86.3000030517578,38 84.0999984741211,38 Z M50.4000015258789,22.5 L49.6000022888184,' +
    '22.5 C25.2000007629395,22.5 5.30000019073486,33.2999992370605 5,47.9000015258789 C4.69999980926514,62.5 13.600' +
    '0003814697,70.6000061035156 13.6000003814697,70.6000061035156 C13.6000003814697,70.6000061035156 18,76 23.2000' +
    '007629395,76 C28.4000015258789,76 30,71.5 30,71.5 C32.4000015258789,59.0999984741211 48.7000007629395,60 48.70' +
    '00007629395,60 L49.4000015258789,60 C49.4000015258789,60 67.6000061035156,59.0999984741211 70,71.5 C70,71.5 71' +
    '.5999984741211,76 76.8000030517578,76 C82,76 86.4000015258789,70.5999984741211 86.4000015258789,70.59999847412' +
    '11 C86.4000015258789,70.5999984741211 95.3000030517578,62.5 95,47.8999977111816 C94.6999969482422,33.299999237' +
    '0605 74.6999969482422,22.5 50.4000015258789,22.5 Z M25.1000003814697,59 C17.6000003814697,59 11.6000003814697,' +
    '53.4000015258789 11.6000003814697,46.0999984741211 C11.6000003814697,38.7999992370605 17.7000007629395,32.5 25' +
    '.1000003814697,32.5 C32.5999984741211,32.5 38.0999984741211,37.4000015258789 38.0999984741211,44.7000007629395' +
    ' C38.0999984741211,52 32.5999984741211,59 25.1000003814697,59 Z M65.9000015258789,33.2000007629395 L71.9000015' +
    '258789,30.6000003814697 C72.4000015258789,30.3999996185303 72.9000015258789,30.6000003814697 73.0999984741211,' +
    '31.1000003814697 L73.0999984741211,31.1000003814697 C73.2999954223633,31.6000003814697 73.0999984741211,32.099' +
    '9984741211 72.5999984741211,32.2999992370605 L66.5999984741211,34.8999977111816 C66.0999984741211,35.099998474' +
    '1211 65.5999984741211,34.8999977111816 65.4000015258789,34.3999977111816 L65.4000015258789,34.3999977111816 C6' +
    '5.1999969482422,33.9000015258789 65.4000015258789,33.4000015258789 65.9000015258789,33.2000007629395 Z M86.099' +
    '9984741211,49.2000007629395 C86.0999984741211,49.2000007629395 81.1999969482422,50.7999992370605 77.0999984741' +
    '211,52.6000022888184 C73,54.4000015258789 69.1999969482422,57.1000022888184 69.1999969482422,57.1000022888184 ' +
    'C69.1999969482422,57.1000022888184 63.7999954223633,60.5000038146973 59.7999954223633,52.8000030517578 C57.799' +
    '9954223633,49.0000038146973 61.4999961853027,44.0000038146973 63.1999969482422,42.9000015258789 C63.1999969482' +
    '422,42.9000015258789 65.2999954223633,40.5 70.5999984741211,38.2000007629395 C75.9000015258789,35.900001525878' +
    '9 79.5999984741211,36 79.5999984741211,36 C83.0999984741211,35.7999992370605 86.7999954223633,35.5999984741211' +
    ' 88.5,39.5999984741211 C88.5999984741211,39.5999984741211 92.0999984741211,46.2999992370605 86.0999984741211,4' +
    '9.2000007629395 Z M25,36.0999984741211 C19.6000003814697,36.0999984741211 15.1999998092651,40.6999969482422 15' +
    '.1999998092651,46 C15.1999998092651,51.3000030517578 19.6000003814697,55.4000015258789 25,55.4000015258789 C30' +
    '.3999996185303,55.4000015258789 34.4000015258789,50.3000030517578 34.4000015258789,45 C34.5,39.7000007629395 3' +
    '0.3999996185303,36.0999984741211 25,36.0999984741211 Z M32.5,44 L32.5,46.2999992370605 C32.5,46.7000007629395 ' +
    '32.2000007629395,47 31.7999992370605,47 L27,47 C26.7999992370605,47 26.7000007629395,47.2000007629395 26.60000' +
    '03814697,47.2999992370605 L26.6000003814697,52.3999977111816 C26.6000003814697,52.7999992370605 26.30000114440' +
    '92,53.0999984741211 25.8999996185303,53.0999984741211 L23.1999988555908,53.0999984741211 C22.7999992370605,53.' +
    '0999984741211 22.4999980926514,52.7999992370605 22.4999980926514,52.3999977111816 L22.6999988555908,47.4999961' +
    '853027 C22.6999988555908,47.2999954223633 22.4999980926514,47.0999946594238 22.2999992370605,47.0999946594238 ' +
    'L17.5999984741211,47.0999946594238 C17.1999988555908,47.0999946594238 16.8999977111816,46.7999954223633 16.899' +
    '9977111816,46.3999938964844 L16.8999977111816,43.9999923706055 C16.8999977111816,43.5999908447266 17.199996948' +
    '2422,43.299991607666 17.5999984741211,43.299991607666 L22.5999984741211,43.299991607666 C22.7999992370605,43.2' +
    '99991607666 22.9999980926514,43.0999908447266 22.9999980926514,42.8999900817871 L22.9999980926514,38.299991607' +
    '666 C22.9999980926514,37.8999900817871 23.2999973297119,37.5999908447266 23.6999988555908,37.5999908447266 L26' +
    '.1999988555908,37.5999908447266 C26.5999984741211,37.5999908447266 26.8999996185303,37.8999900817871 26.899999' +
    '6185303,38.299991607666 L26.8999996185303,43 C26.8999996185303,43.2000007629395 27.1000003814697,43.4000015258' +
    '789 27.2999992370605,43.4000015258789 L31.7999992370605,43.4000015258789 C32.2000007629395,43.2999992370605 32' +
    '.5,43.7000007629395 32.5,44 Z ';
  MD_IMAGE_MAX_SIZE = 64 * 1024 * 1024;

class procedure TMDPlatform.LoadGamepadPreset(Input: TInputManager; Port: Integer);
begin
  for var Direction := TEmulatorButton.Up to TEmulatorButton.Right do
    AddStandardDirection(Input, Port, PadAction(Port, Direction), Ord(Direction), True);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.A), TGamepadButton.West);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.B), TGamepadButton.South);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.Start), TGamepadButton.Start);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.C), TGamepadButton.East);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.X), TGamepadButton.LeftShoulder);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.Y), TGamepadButton.North);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.Z), TGamepadButton.RightShoulder);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.Mode), TGamepadButton.Select);
end;

class function TMDPlatform.LoadDisc(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := TCoreMatch.Create('MDCD',
    function: IEmulationCore
    begin
      Context.Stream.Position := 0;
      Result := TMDCoreAdapter.Create(Context.Stream, Context.EffectiveStorage, Context.RomName, True);
    end);
  Result.Format.SystemId := 'segacd';
end;

class function TMDPlatform.Header(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  var Encoding: string;
  if not MD.RomFormat.TryDetectEncoding(Context.Data, Encoding) then
    Exit;
  var SystemId := ROM_SYSTEM_MD;
  if Context.HasExtension(['.32x']) then
    SystemId := ROM_SYSTEM_SEGA32X;
  Result := ImageMatch(Context, 'MD',
    function(const Data: TBytes; Input: TStream): IEmulationCore
    begin
      Result := TMDCoreAdapter.Create(Input, Context.Storage, Context.RomName, False, Context.SourceName, Context.Data);
    end, True, SystemId, Encoding, MD_IMAGE_MAX_SIZE);
end;

class function TMDPlatform.Disc(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  if Context.IsDiscSource and Context.DiscSignature('SEGADISCSYSTEM') then
    Result := LoadDisc(Context);
end;

class procedure TMDPlatform.RegisterPlatforms;
begin
  TPlatformRegistry.RegisterPlatform('md', 'MegaDrive', 'MegaDrive',
    'Sega', 'MD Genesis Sega CD Mega CD 32X', 'megadrive', ['megadrive'],
    ['.smd', '.bin', '.gen', '.md'],
    'MegaDrive', 'md', 4);
  TPlatformRegistry.RegisterPlatform('segacd', 'Sega CD', 'Sega CD',
    'Sega', 'Mega CD CD32X 32X CD', 'segacd', ['segacd', 'megacd'],
    ['.cue', '.iso', '.chd', '.mds', '.nrg'],
    'MegaDrive', 'md', 4);
  TPlatformRegistry.RegisterPlatform('sega32x', 'Sega 32X', 'Sega 32X',
    'Sega', '32X Mars Super 32X', 'sega32x', ['sega32x', '32x'],
    ['.32x', '.bin', '.gen', '.md', '.smd'],
    'MegaDrive', 'md', 4);
end;

class procedure TMDPlatform.RegisterCore;
begin
  RegisterPlatforms;
  var Registration := TEmulationCoreRegistration.Create('MD', ['.smd', '.gen', '.md', '.32x']);
  Registration.Add(TCoreLoadStage.Header, 120, Header);
  Registration.Add(TCoreLoadStage.Source, 60, Disc);
  Registration.AddDiscPlatform('segacd', LoadDisc);
  RegisterEmulationCore(Registration);
end;

class procedure TMDPlatform.RegisterServices;
begin
  RegisterSnapshotPolicy('MD', TSnapshotPolicy.Create(9));
end;

class procedure TMDPlatform.LoadLegacyKeys(var Keys: TPlatformInputKeyMap);
const
  MDMapping: array[TMDButton] of TEmulatorButton = (TEmulatorButton.Up,
    TEmulatorButton.Down, TEmulatorButton.Left, TEmulatorButton.Right,
    TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.C, TEmulatorButton.Start,
    TEmulatorButton.X, TEmulatorButton.Y, TEmulatorButton.Z, TEmulatorButton.Mode);
var
  Config: IEmulatorConfig;
begin
  var C := TMDConfig.Create('');
  Config := C;
  for var B := Low(TMDButton) to High(TMDButton) do
  begin
    Keys[0, MDMapping[B]] := C.Keys[B];
    Keys[1, MDMapping[B]] := C.Keys2[B];
  end;
end;

class procedure TMDPlatform.RegisterInput;
begin
  var Definition := TPlatformInputDefinition.Create([TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left,
      TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.Start, TEmulatorButton.C,
      TEmulatorButton.X, TEmulatorButton.Y, TEmulatorButton.Z, TEmulatorButton.Mode]);
  Definition.Devices := TArray<TInputDeviceVariant>.Create(TInputDeviceVariant.Create('pad3', [TEmulatorButton.Up,
        TEmulatorButton.Down, TEmulatorButton.Left, TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B,
        TEmulatorButton.Start, TEmulatorButton.C]));
  Definition.LegacyPorts := 4;
  Definition.LegacySection := 'Keys';
  Definition.AfterLegacyBindings := LoadSharedLegacyBindings;
  Definition.UseSharedBindingRules := True;
  Definition.LoadLegacyKeys := LoadLegacyKeys;
  Definition.LoadGamepadPreset := LoadGamepadPreset;
  RegisterPlatformInput('md', Definition);
  RegisterPlatformInput('segacd', Definition);
  RegisterPlatformInput('sega32x', Definition);
end;

class procedure TMDPlatform.RegisterClient;
begin
  RegisterSettingsProfile('MegaDrive', TMegaDriveSettings,
    'Assign separate folders to Mega Drive, Sega CD and 32X. Sega CD uses disc images, so keep ' +
    'descriptors and tracks together. Choose the control type for the game, such as a three- ' +
    'or six-button pad.');
  RegisterPlatformSettingsDevices('md', TPlatformSettingsDevices);
  RegisterPlatformSettingsDevices('segacd', TPlatformSettingsDevices);
  RegisterPlatformSettingsDevices('sega32x', TPlatformSettingsDevices);
  RegisterPlatformDeviceCallouts('md', TPlatformDeviceCallouts);
  RegisterPlatformDeviceCallouts('segacd', TPlatformDeviceCallouts);
  RegisterPlatformDeviceCallouts('sega32x', TPlatformDeviceCallouts);
  RegisterPlatformControlsHelp('md', TPlatformControlsHelp);
  RegisterPlatformControlsHelp('segacd', TPlatformControlsHelp);
  RegisterPlatformControlsHelp('sega32x', TPlatformControlsHelp);
  RegisterPlatformSettingsHandler('md', TPlatformSettingsHandler);
  RegisterPlatformSettingsHandler('segacd', TPlatformSettingsHandler);
  RegisterPlatformSettingsHandler('sega32x', TPlatformSettingsHandler);
  RegisterPlatformWindowLayout('md', TPlatformWindowLayout);
  RegisterPlatformWindowLayout('segacd', TPlatformWindowLayout);
  RegisterPlatformWindowLayout('sega32x', TPlatformWindowLayout);
  RegisterPlatformSessionHandler('md', TPlatformSessionHandler);
  RegisterPlatformSessionHandler('segacd', TPlatformSessionHandler);
  RegisterPlatformSessionHandler('sega32x', TPlatformSessionHandler);
  RegisterPlatformInputHandler('md', TPlatformInputHandler);
  RegisterPlatformInputHandler('segacd', TPlatformInputHandler);
  RegisterPlatformInputHandler('sega32x', TPlatformInputHandler);
  RegisterInput;
  RegisterPlatformGamepads('md', TGamepadSEGAPad6, [TGamepadDeviceVariant.Create('pad3', TGamepadSEGAPad3)]);
  RegisterPlatformGamepads('segacd', TGamepadSEGAMegaCDPad6, [TGamepadDeviceVariant.Create('pad3', TGamepadSEGAMegaCDPad3)]);
  RegisterPlatformGamepads('sega32x', TGamepadSEGAMega32XPad6, [TGamepadDeviceVariant.Create('pad3', TGamepadSEGAMega32XPad3)]);
  RegisterPlatformPresentation('md', 'md', PlatformIcon);
  RegisterPlatformPresentation('segacd', 'md', PlatformIcon);
  RegisterPlatformPresentation('sega32x', 'md', PlatformIcon);
end;

class procedure TMDPlatform.RegisterRomFormats;
begin
  RegisterRomEncoding(MD_ENCODING_SMD,
    function(const Data: TBytes): TBytes
    begin
      Result := MD.RomFormat.NormalizeImage(Data, MD_ENCODING_SMD);
    end);
  RegisterRomEncoding(MD_ENCODING_BYTE_SWAPPED,
    function(const Data: TBytes): TBytes
    begin
      Result := MD.RomFormat.NormalizeImage(Data, MD_ENCODING_BYTE_SWAPPED);
    end);
  RegisterRomNormalizer('md',
    function(const Data: TBytes; const Format: TRomFormatInfo): TBytes
    begin
      Result := MD.RomFormat.NormalizeImage(Data, Format.Encoding);
    end);
end;

class procedure TMDPlatform.RegisterPlatform;
begin
  if FRegistered then
    Exit;
  RegisterRomFormats;
  RegisterServices;
  RegisterCore;
  RegisterClient;
  FRegistered := True;
  RegisterPlatformAchievementMedia('md', RAConsoleMegaDrive, TPlatformRegistry.Require('md').Extensions);
  RegisterPlatformAchievementMedia('sega32x', RAConsoleSega32X, TPlatformRegistry.Require('sega32x').Extensions);
  RegisterPlatformAchievementMedia('segacd', RAConsoleSegaCD, TPlatformRegistry.Require('segacd').Extensions, True);
end;

end.

