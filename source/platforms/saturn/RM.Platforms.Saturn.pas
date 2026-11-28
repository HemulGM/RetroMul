unit RM.Platforms.Saturn;

interface

uses
  FMXInput, Core.EmulatorRegistry, RM.Input, System.SysUtils;

const
  ROM_SYSTEM_SATURN = 'saturn';

type
  TSaturnPlatform = class
  strict private
    class function LoadDisc(Context: TCoreLoadContext): TCoreMatch; static;
    class var
      FRegistered: Boolean;
    class function Recognize(Context: TCoreLoadContext): TCoreMatch; static;
    class function Disc(Context: TCoreLoadContext): TCoreMatch; static;
    class procedure RegisterPlatforms; static;
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
  RA.Console, Core.PlatformServices, RM.Input.Gamepads, RM.Settings.Catalog,
  Core.Snapshots, System.StrUtils, Core.Emulation, Core.Platforms,
  Core.Platforms.Saturn.Adapter, RM.Platforms.Saturn.Settings,
  RM.Platforms.Presentation, RM.Gamepad.Factory, RM.Platforms.Saturn.Gamepads,
  RM.Input.Runtime, RM.Session.Runtime, RM.Window.Layout, RM.Settings.Runtime,
  RM.ControlsHelp.Content, RM.Settings.Callouts, RM.Settings.Devices,
  System.Classes;

const
  PlatformIcon = 'M29.6000003814697,46.7000007629395 C28.8999996185303,46.6000022888184 28.3999996185303,46.1000022888184 28.3000011444092,45.5 L28,41.7999992370605 C28,41.5 27.7000007629395,41.2999992370605 27.3999996185303,' +
    '41.2999992370605 L25.1000003814697,41.2999992370605 C24.8000011444092,41.2999992370605 24.6000003814697,41.5 24.5,41.7999992370605 L24.2999992370605,45.5 C24.1999988555908,46.2000007629395 23.6999988555908,' +
    '46.7000007629395 23,46.7999992370605 L20,46.9000015258789 C19.7000007629395,46.9000015258789 19.5,47.2000007629395 19.5,47.5 L19.5,50 C19.5,50.2999992370605 19.7000007629395,50.5 20,50.5999984741211 L23.2999992370605,' +
    '50.7999992370605 C23.8999996185303,50.8999977111816 24.3999996185303,51.2999992370605 24.5999984741211,52 L24.9999980926514,54.9000015258789 C25.0999984741211,55.2000007629395 25.2999973297119,55.4000015258789 ' +
    '25.5999984741211,55.4000015258789 L27.8999977111816,55.4000015258789 C28.1999969482422,55.4000015258789 28.3999977111816,55.2000007629395 28.4999980926514,54.9000015258789 L28.6999988555908,51.8000030517578 ' +
    'C28.7999992370605,51.1000022888184 29.2999992370605,50.6000022888184 29.9999980926514,50.5000038146973 L33,50.4000053405762 C33.2999992370605,50.4000053405762 33.5,50.1000061035156 33.5,49.8000068664551 ' +
    'L33.5,47.4000053405762 C33.5,47.1000061035156 33.2999992370605,46.9000053405762 33,46.8000068664551 L29.6000003814697,46.7000007629395 Z M88.1999969482422,36.9000015258789 C88.1999969482422,36.9000015258789 ' +
    '87,34.9000015258789 84.7999954223633,32.5 C85.6999969482422,31.8999996185303 85.1999969482422,31.3999996185303 85.1999969482422,31.3999996185303 C77.6999969482422,22.2999992370605 69,23.5999984741211 67.7999954223633,' +
    '23.5999984741211 C66.7999954223633,23.5999984741211 66.8999938964844,24.3999977111816 66.9999923706055,24.6999988555908 C60.1999931335449,25.0999984741211 58.299991607666,27.3999996185303 50.299991607666,' +
    '27.3999996185303 L49.5999908447266,27.3999996185303 C41.5999908447266,27.3999996185303 39.6999893188477,25.1000003814697 32.8999900817871,24.6999988555908 C32.9999885559082,24.3999996185303 33.1999893188477,' +
    '23.6999988555908 32.0999908447266,23.5999984741211 C30.799991607666,23.4999980926514 22.0999908447266,22.2999992370605 14.6999912261963,31.3999977111816 C14.6999912261963,31.3999977111816 14.1999912261963,' +
    '31.8999977111816 15.0999908447266,32.4999961853027 C12.8999910354614,34.8999977111816 11.6999912261963,36.8999977111816 11.6999912261963,36.8999977111816 C7.89999103546143,41.8999977111816 2.79999160766602,' +
    '60.5999984741211 5.99999141693115,66.5 C10.799991607666,75.3000030517578 17.799991607666,77 28.799991607666,68.8000030517578 C39.799991607666,60.6000022888184 49.6999893188477,61.2000045776367 49.6999893188477,' +
    '61.2000045776367 L50.0999908447266,61.2000045776367 C50.0999908447266,61.2000045776367 59.9999923706055,60.6000061035156 70.9999923706055,68.8000030517578 C81.9999923706055,77 88.9999923706055,75.2000045776367 ' +
    '93.7999877929688,66.5 C97.0999984741211,60.5999984741211 91.9000015258789,41.9000015258789 88.1999969482422,36.9000015258789 Z M76.6999969482422,34.7000007629395 C78.3999938964844,34.7000007629395 79.6999969482422,' +
    '36 79.6999969482422,37.7000007629395 C79.6999969482422,39.4000015258789 78.3999938964844,40.7000007629395 76.6999969482422,40.7000007629395 C75,40.7000007629395 73.6999969482422,39.4000015258789 73.6999969482422,' +
    '37.7000007629395 C73.6999969482422,36 75,34.7000007629395 76.6999969482422,34.7000007629395 Z M69.5999984741211,37.7000007629395 C71.2999954223633,37.7000007629395 72.5999984741211,39 72.5999984741211,' +
    '40.7000007629395 C72.5999984741211,42.4000015258789 71.2999954223633,43.7000007629395 69.5999984741211,43.7000007629395 C67.9000015258789,43.7000007629395 66.5999984741211,42.4000015258789 66.5999984741211,' +
    '40.7000007629395 C66.5999984741211,39 67.9000015258789,37.7000007629395 69.5999984741211,37.7000007629395 Z M26.5,57.7000007629395 C21.5,57.7000007629395 17.5,53.7000007629395 17.5,48.7000007629395 C17.5,' +
    '43.7000007629395 21.5,39.7000007629395 26.5,39.7000007629395 C31.5,39.7000007629395 35.5,43.7000007629395 35.5,48.7000007629395 C35.5,53.5999984741211 31.3999996185303,57.7000007629395 26.5,57.7000007629395 ' +
    'Z M50.2999992370605,57.7000007629395 C48.0999984741211,57.7000007629395 46.3999977111816,57 46.3999977111816,56.2000007629395 C46.3999977111816,55.4000015258789 48.1999969482422,54.7000007629395 50.2999992370605,' +
    '54.7000007629395 C52.4000015258789,54.7000007629395 54.2000007629395,55.4000015258789 54.2000007629395,56.2000007629395 C54.2000007629395,57.0999984741211 52.4000015258789,57.7000007629395 50.2999992370605,' +
    '57.7000007629395 Z M60.2999992370605,45.7999992370605 C60.2999992370605,44.0999984741211 61.5999984741211,42.7999992370605 63.2999992370605,42.7999992370605 C65,42.7999992370605 66.3000030517578,44.0999984741211 ' +
    '66.3000030517578,45.7999992370605 C66.3000030517578,47.5 65,48.7999992370605 63.3000030517578,48.7999992370605 C61.6000061035156,48.7999992370605 60.2999992370605,47.5 60.2999992370605,45.7999992370605 ' +
    'Z M66.0999984741211,58.9000015258789 C63.8999977111816,58.9000015258789 62.0999984741211,57.1000022888184 62.0999984741211,54.9000015258789 C62.0999984741211,52.7000007629395 63.8999977111816,50.9000015258789 ' +
    '66.0999984741211,50.9000015258789 C68.2999954223633,50.9000015258789 70.0999984741211,52.7000007629395 70.0999984741211,54.9000015258789 C70.0999984741211,57.0999984741211 68.3000030517578,58.9000015258789 ' +
    '66.0999984741211,58.9000015258789 Z M73.6999969482422,53 C71.5,53 69.6999969482422,51.2000007629395 69.6999969482422,49 C69.6999969482422,46.7999992370605 71.5,45 73.6999969482422,45 C75.8999938964844,' +
    '45 77.6999969482422,46.7999992370605 77.6999969482422,49 C77.6999969482422,51.2000007629395 75.9000015258789,53 73.6999969482422,53 Z M82.5,49.2000007629395 C80.3000030517578,49.2000007629395 78.5,47.4000015258789 ' +
    '78.5,45.2000007629395 C78.5,43 80.3000030517578,41.2000007629395 82.5,41.2000007629395 C84.6999969482422,41.2000007629395 86.5,43 86.5,45.2000007629395 C86.5,47.4000015258789 84.8000030517578,49.2000007629395 ' +
    '82.5,49.2000007629395 Z ';
  SATURN_IMAGE_MAX_SIZE = 64 * 1024 * 1024;

class procedure TSaturnPlatform.LoadGamepadPreset(Input: TInputManager; Port: Integer);
begin
  for var Direction := TEmulatorButton.Up to TEmulatorButton.Right do
    AddStandardDirection(Input, Port, PadAction(Port, Direction), Ord(Direction), True);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.A), TGamepadButton.West);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.B), TGamepadButton.South);
  AddStandardTrigger(Input, Port, PadAction(Port, TEmulatorButton.Select), True);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.Start), TGamepadButton.Start);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.C), TGamepadButton.East);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.X), TGamepadButton.LeftShoulder);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.Y), TGamepadButton.North);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.Z), TGamepadButton.RightShoulder);
  AddStandardTrigger(Input, Port, PadAction(Port, TEmulatorButton.Mode), False);
end;

class function TSaturnPlatform.LoadDisc(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := TCoreMatch.Create('Saturn',
    function: IEmulationCore
    begin
      Context.Stream.Position := 0;
      Result := TSaturnCoreAdapter.Create(Context.Stream, Context.EffectiveStorage, Context.RomName, Context.TakeDisc);
    end);
  Result.Format.SystemId := 'saturn';
end;

class function TSaturnPlatform.Recognize(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;

  if Context.Signature(0, AnsiString(#$20#$00#$02#$00#$06#$00#$20#$00#$20#$00#$02#$00#$06#$00#$20#$00)) then
    Result := ImageMatch(Context, 'Saturn',
      function(const Data: TBytes; Input: TStream): IEmulationCore
      begin
        Result := TSaturnCoreAdapter.Create(Input, Context.Storage, Context.RomName);
      end, True, 'saturn', '', SATURN_IMAGE_MAX_SIZE);
end;

class function TSaturnPlatform.Disc(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  if Context.IsDiscSource and Context.DiscSignature('SEGA SEGASATURN ') then
    Result := LoadDisc(Context);
end;

class procedure TSaturnPlatform.RegisterPlatforms;
begin
  TPlatformRegistry.RegisterPlatform('saturn', 'SEGA Saturn', 'Saturn',
    'Sega', 'Saturn SH2 CD', 'saturn', ['saturn'],
    ['.bin', '.rom', '.bios', '.cue', '.iso', '.chd', '.mds', '.nrg'],
    'Saturn', 'saturn', 2);
end;

class procedure TSaturnPlatform.RegisterCore;
begin
  RegisterPlatforms;
  var Registration := TEmulationCoreRegistration.Create('Saturn', []);
  Registration.Add(TCoreLoadStage.Header, 40, Recognize);
  Registration.Add(TCoreLoadStage.Source, 50, Disc);
  Registration.AddDiscPlatform('saturn', LoadDisc);
  RegisterEmulationCore(Registration);
end;

class procedure TSaturnPlatform.RegisterServices;
begin
  var Policy := TSnapshotPolicy.Create(5);
  Policy.AcceptedVersions := [2, 3, 4];
  RegisterSnapshotPolicy('SATURN', Policy);
end;

class procedure TSaturnPlatform.LoadLegacyKeys(var Keys: TPlatformInputKeyMap);
var
  Config: IEmulatorConfig;
begin
  var C := TSaturnConfig.Create('');
  Config := C;
  for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
  begin
    Keys[0, B] := C.Keys[B];
    Keys[1, B] := C.Keys2[B];
  end;
end;

class procedure TSaturnPlatform.RegisterInput;
begin
  var Definition := TPlatformInputDefinition.Create([TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left,
      TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.Select, TEmulatorButton.Start,
      TEmulatorButton.C, TEmulatorButton.X, TEmulatorButton.Y, TEmulatorButton.Z, TEmulatorButton.Mode]);
  Definition.ButtonNames[TEmulatorButton.Select] := 'L';
  Definition.ButtonNames[TEmulatorButton.Mode] := 'R';
  Definition.LegacyPorts := 12;
  Definition.LegacySection := 'Keys';
  Definition.AfterLegacyBindings := LoadSharedLegacyBindings;
  Definition.UseSharedBindingRules := True;
  Definition.LoadLegacyKeys := LoadLegacyKeys;
  Definition.LoadGamepadPreset := LoadGamepadPreset;
  RegisterPlatformInput('saturn', Definition);
end;

class procedure TSaturnPlatform.RegisterClient;
begin
  RegisterSettingsProfile('Saturn', TSaturnSettings,
    'Saturn has a built-in regional BIOS and an optional 512 KiB override. Choose the ' +
    'cartridge expansion required by the game. For the CD Block, the command model is the ' +
    'normal choice. Original SH-1 firmware mode is experimental.');
  RegisterPlatformSettingsDevices('saturn', TPlatformSettingsDevices);
  RegisterPlatformDeviceCallouts('saturn', TPlatformDeviceCallouts);
  RegisterPlatformControlsHelp('saturn', TPlatformControlsHelp);
  RegisterPlatformSettingsHandler('saturn', TPlatformSettingsHandler);
  RegisterPlatformWindowLayout('saturn', TPlatformWindowLayout);
  RegisterPlatformSessionHandler('saturn', TPlatformSessionHandler);
  RegisterPlatformInputHandler('saturn', TPlatformInputHandler);
  RegisterInput;
  RegisterPlatformGamepads('saturn', TGamepadSaturnDigital, [TGamepadDeviceVariant.Create('pad-analog', TGamepadSaturnAnalog)]);
  RegisterPlatformPresentation('saturn', 'saturn', PlatformIcon);
end;

class procedure TSaturnPlatform.RegisterPlatform;
begin
  if FRegistered then
    Exit;
  RegisterServices;
  RegisterCore;
  RegisterClient;
  FRegistered := True;
  RegisterPlatformAchievementMedia('saturn', RAConsoleSaturn, TPlatformRegistry.Require('saturn').Extensions, True);
end;

end.

