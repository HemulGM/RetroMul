unit RM.Platforms.CPS;

interface

uses
  FMXInput, Core.EmulatorRegistry, RM.Input, System.SysUtils;

type
  TCPSPlatform = class
  strict private
    class var
      FRegistered: Boolean;
    class function Recognize(Context: TCoreLoadContext): TCoreMatch; static;
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
  RM.Input.Gamepads, RM.Settings.Catalog, RM.Settings.Platform, Core.Snapshots,
  System.StrUtils, Core.Emulation, Core.Platforms, Core.PlatformServices,
  Core.Platforms.CPS.Adapter, CPS.RomSets, RM.Platforms.Presentation,
  RM.Gamepad.Factory, RM.Platforms.CPS.Gamepads, RM.Input.Runtime,
  RM.Session.Runtime, RM.Window.Layout, RM.Settings.Runtime,
  RM.ControlsHelp.Content, RM.Settings.Callouts, RM.Settings.Devices,
  System.Classes;

const
  PlatformIcon =
 'M65.7399978637695,56.0699996948242 L65.7399978637695,63 C65.7399978637695,64.0608673095703 65.3185729980469,65.0782852172852 64.5684280395508,65.8284301757813 C63.8182830810547,66.5785751342773 62.8008651733398,' +
    '67 61.7399978637695,67 L8.26000022888184,67 C7.199134349823,67 6.18171834945679,66.5785751342773 5.43157291412354,65.8284301757813 C4.68142747879028,65.0782852172852 4.26000022888184,64.0608673095703 4.26000022888184,' +
    '63 L4.26000022888184,56.0699996948242 C4.26000022888184,55.8047828674316 4.36535739898682,55.5504302978516 4.55289363861084,55.3628921508789 C4.74042987823486,55.1753540039063 4.99478387832642,55.0699996948242 ' +
    '5.26000022888184,55.0699996948242 L64.7399978637695,55.0699996948242 C65.0052108764648,55.0699996948242 65.2595672607422,55.1753540039063 65.4471054077148,55.3628921508789 C65.6346435546875,55.5504302978516 ' +
    '65.7399978637695,55.8047828674316 65.7399978637695,56.0699996948242 Z M65.7399978637695,7 C65.7399978637695,5.93913412094116 65.3185729980469,4.92171812057495 64.5684280395508,4.1715726852417 C63.8182830810547,' +
    '3.42142724990845 62.8008651733398,3 61.7399978637695,3 L8.26000022888184,3 C7.199134349823,3 6.18171834945679,3.42142724990845 5.43157291412354,4.1715726852417 C4.68142747879028,4.92171812057495 4.26000022888184,' +
    '5.93913459777832 4.26000022888184,7.00000047683716 L4.26000022888184,13.9300003051758 C4.26000022888184,13.9300003051758 4.26000022888184,13.9300003051758 4.26000022888184,13.9800004959106 C4.26000022888184,' +
    '14.0300006866455 4.26000022888184,13.9800004959106 4.26000022888184,13.9800004959106 L7.76000022888184,51.9799995422363 L6.76000022888184,52.9799995422363 L17.6000003814697,52.9799995422363 C17.54758644104,' +
    '52.7638893127441 17.5207366943359,52.5423736572266 17.5200004577637,52.3199996948242 L17.5200004577637,47.75 L13.3800001144409,47.75 L14.3000001907349,14.9300003051758 L55.7000007629395,14.9300003051758 ' +
    'L56.6300010681152,47.75 L23.5200004577637,47.75 L23.5200004577637,52.4099998474121 C23.5192642211914,52.6323890686035 23.4924125671387,52.8539009094238 23.4399967193604,53.070011138916 L63.2299995422363,' +
    '53.070011138916 L62.2299995422363,52.070011138916 L65.7299957275391,14.070011138916 L65.7299957275391,14.070011138916 C65.7299957275391,14.070011138916 65.7299957275391,14.070011138916 65.7299957275391,' +
    '14.0200109481812 Z M42.2000007629395,51.9000015258789 L41,51.9000015258789 C40.6427345275879,51.9000015258789 40.3126106262207,51.7094039916992 40.133975982666,51.4000015258789 C39.9553413391113,51.0905990600586 ' +
    '39.9553413391113,50.7094039916992 40.133975982666,50.4000015258789 C40.3126106262207,50.0905990600586 40.6427345275879,49.9000015258789 41,49.9000015258789 L42.2000007629395,49.9000015258789 C42.5572662353516,' +
    '49.9000015258789 42.8873901367188,50.0905990600586 43.0660247802734,50.4000015258789 C43.2446594238281,50.7094039916992 43.2446594238281,51.0905990600586 43.0660247802734,51.4000015258789 C42.8873901367188,' +
    '51.7094039916992 42.5572662353516,51.9000015258789 42.2000007629395,51.9000015258789 Z M47.1100006103516,51.9000015258789 L45.9300003051758,51.9000015258789 C45.5727348327637,51.9000015258789 45.2426109313965,' +
    '51.7094039916992 45.0639762878418,51.4000015258789 C44.8853416442871,51.0905990600586 44.8853416442871,50.7094039916992 45.0639762878418,50.4000015258789 C45.2426109313965,50.0905990600586 45.5727348327637,' +
    '49.9000015258789 45.9300003051758,49.9000015258789 L47.1100006103516,49.9000015258789 C47.4672660827637,49.9000015258789 47.7973899841309,50.0905990600586 47.9760246276855,50.4000015258789 C48.1546592712402,' +
    '50.7094039916992 48.1546592712402,51.0905990600586 47.9760246276855,51.4000015258789 C47.7973899841309,51.7094039916992 47.4672660827637,51.9000015258789 47.1100006103516,51.9000015258789 Z M52.0299987792969,' +
    '51.9000015258789 L50.8499984741211,51.9000015258789 C50.492733001709,51.9000015258789 50.1626091003418,51.7094039916992 49.9839744567871,51.4000015258789 C49.8053398132324,51.0905990600586 49.8053398132324,' +
    '50.7094039916992 49.9839744567871,50.4000015258789 C50.1626091003418,50.0905990600586 50.492733001709,49.9000015258789 50.8499984741211,49.9000015258789 L52,49.9000015258789 C52.3572654724121,49.9000015258789 ' +
    '52.6873893737793,50.0905990600586 52.866024017334,50.4000015258789 C53.0446586608887,50.7094039916992 53.0446586608887,51.0905990600586 52.866024017334,51.4000015258789 C52.6873893737793,51.7094039916992 ' +
    '52.3572654724121,51.9000015258789 52,51.9000015258789 Z M19.5200004577637,45.5800018310547 L19.5200004577637,52.9000015258789 L21.5200004577637,52.9000015258789 L21.5200004577637,45.5800018310547 C23.4362316131592,' +
    '45.0771827697754 24.6811065673828,43.2296905517578 24.4276142120361,41.2648735046387 C24.1741218566895,39.3000564575195 22.5011024475098,37.8290176391602 20.5200004577637,37.8290176391602 C18.5388984680176,' +
    '37.8290176391602 16.8658790588379,39.3000564575195 16.6123867034912,41.2648735046387 C16.3588943481445,43.2296905517578 17.6037693023682,45.0771827697754 19.5200023651123,45.5800018310547 Z ';

class procedure TCPSPlatform.LoadGamepadPreset(Input: TInputManager; Port: Integer);
begin
  for var Direction := TEmulatorButton.Up to TEmulatorButton.Right do
    AddStandardDirection(Input, Port, PadAction(Port, Direction), Ord(Direction), True);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.A), TGamepadButton.West);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.B), TGamepadButton.South);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.Select), TGamepadButton.Select);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.Start), TGamepadButton.Start);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.C), TGamepadButton.East);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.X), TGamepadButton.LeftShoulder);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.Y), TGamepadButton.North);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.Z), TGamepadButton.RightShoulder);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.Mode), TGamepadButton.RightStick);
end;

class function TCPSPlatform.Recognize(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  if (Context.Archive = nil) then
    Exit;
  var RomSet: TCPSRomSet;
  if TCPSRomSet.Identify(Context.Archive, Context.SourceName, RomSet) then
  begin
    Result := TCoreMatch.Create('CPS',
      function: IEmulationCore
      begin
        Context.Stream.Position := 0;
        Result := TCPSCoreAdapter.Create(Context.Stream, Context.Storage, Context.RomName);
      end);
    Result.Format.SystemId := 'cps' + IntToStr(Ord(RomSet.Generation));
  end;
end;

class procedure TCPSPlatform.RegisterPlatforms;
begin
  TPlatformRegistry.RegisterPlatform('cps1', 'Capcom Play System I', 'CPS-1',
    'Capcom', 'CPS CPS1 arcade', 'cps1', ['cps1'],
    [],
    'CPS1', 'cps1', 4);
  TPlatformRegistry.RegisterPlatform('cps2', 'Capcom Play System II', 'CPS-2',
    'Capcom', 'CPS CPS2 arcade', 'cps2', ['cps2'],
    [],
    'CPS2', 'cps2', 4);
  TPlatformRegistry.RegisterPlatform('cps3', 'Capcom Play System III', 'CPS-3',
    'Capcom', 'CPS CPS3 arcade SIMM No-CD', 'cps3', ['cps3'],
    [],
    'CPS3', 'cps3', 2);
end;

class procedure TCPSPlatform.RegisterCore;
begin
  RegisterPlatforms;
  var Registration := TEmulationCoreRegistration.Create('CPS', []);
  Registration.Add(TCoreLoadStage.Container, 20, Recognize);
  RegisterEmulationCore(Registration);
end;

class procedure TCPSPlatform.RegisterServices;
begin
  RegisterSnapshotPolicy('CPS1', TSnapshotPolicy.Create(4));
  RegisterSnapshotPolicy('CPS2', TSnapshotPolicy.Create(2));
  RegisterSnapshotPolicy('CPS3', TSnapshotPolicy.Create(1, 128 * 1024 * 1024));
  var Services := Default(TPlatformServices);
  Services.CompanionArchives := ['cps1pic'];
  RegisterPlatformServices('cps1', Services);
end;

class procedure TCPSPlatform.LoadLegacyKeys(var Keys: TPlatformInputKeyMap);
var
  Config: IEmulatorConfig;
begin
  var C := TCPSConfig.Create('', nil);
  Config := C;
  for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
  begin
    Keys[0, B] := C.Keys[0, B];
    Keys[1, B] := C.Keys[1, B];
  end;
end;

class procedure TCPSPlatform.RegisterInput;
begin
  var Definition := TPlatformInputDefinition.Create([TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left,
      TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.Select, TEmulatorButton.Start,
      TEmulatorButton.C, TEmulatorButton.X, TEmulatorButton.Y, TEmulatorButton.Z, TEmulatorButton.Mode]);
  Definition.ButtonNames[TEmulatorButton.A] := 'LP';
  Definition.ButtonNames[TEmulatorButton.B] := 'MP';
  Definition.ButtonNames[TEmulatorButton.Select] := 'Coin';
  Definition.ButtonNames[TEmulatorButton.C] := 'HP';
  Definition.ButtonNames[TEmulatorButton.X] := 'LK';
  Definition.ButtonNames[TEmulatorButton.Y] := 'MK';
  Definition.ButtonNames[TEmulatorButton.Z] := 'HK';
  Definition.ButtonNames[TEmulatorButton.Mode] := 'Service';
  Definition.LegacyPorts := 2;
  Definition.LegacySection := 'Keys';
  Definition.AfterLegacyBindings := LoadSharedLegacyBindings;
  Definition.UseSharedBindingRules := True;
  Definition.LoadLegacyKeys := LoadLegacyKeys;
  Definition.LegacyKeyNames[TEmulatorButton.A] := 'LP';
  Definition.LegacyKeyNames[TEmulatorButton.B] := 'MP';
  Definition.LegacyKeyNames[TEmulatorButton.Select] := 'Coin';
  Definition.LegacyKeyNames[TEmulatorButton.C] := 'HP';
  Definition.LegacyKeyNames[TEmulatorButton.X] := 'LK';
  Definition.LegacyKeyNames[TEmulatorButton.Y] := 'MK';
  Definition.LegacyKeyNames[TEmulatorButton.Z] := 'HK';
  Definition.LegacyKeyNames[TEmulatorButton.Mode] := 'Service';
  Definition.LoadGamepadPreset := LoadGamepadPreset;
  RegisterPlatformInput('cps1', Definition);
  RegisterPlatformInput('cps2', Definition);
  RegisterPlatformInput('cps3', Definition);
end;

class procedure TCPSPlatform.RegisterClient;
begin
  RegisterSettingsPlatform('cps1', TSettingsPlatform,
    'Use a complete, recognized arcade ROM set for the matching board. Keep the ROM archive ' +
    'name and the expected names inside it. Some variants require parent set data or ' +
    'board-specific ROMs. The emulation menu offers coin insertion for games with a coin ' +
    'acceptor.');
  RegisterSettingsPlatform('cps2', TSettingsPlatform,
    'Use a complete, recognized arcade ROM set for the matching board. Keep the ROM archive ' +
    'name and the expected names inside it. Some variants require parent set data or ' +
    'board-specific ROMs. The emulation menu offers coin insertion for games with a coin ' +
    'acceptor.');
  RegisterSettingsPlatform('cps3', TSettingsPlatform,
    'Use a complete, recognized arcade ROM set for the matching board. Keep the ROM archive ' +
    'name and the expected names inside it. Some variants require parent set data or ' +
    'board-specific ROMs. The emulation menu offers coin insertion for games with a coin ' +
    'acceptor.');
  RegisterPlatformSettingsDevices('cps1', TPlatformSettingsDevices);
  RegisterPlatformSettingsDevices('cps2', TPlatformSettingsDevices);
  RegisterPlatformSettingsDevices('cps3', TPlatformSettingsDevices);
  RegisterPlatformDeviceCallouts('cps1', TPlatformDeviceCallouts);
  RegisterPlatformDeviceCallouts('cps2', TPlatformDeviceCallouts);
  RegisterPlatformDeviceCallouts('cps3', TPlatformDeviceCallouts);
  RegisterPlatformControlsHelp('cps1', TPlatformControlsHelp);
  RegisterPlatformControlsHelp('cps2', TPlatformControlsHelp);
  RegisterPlatformControlsHelp('cps3', TPlatformControlsHelp);
  RegisterPlatformSettingsHandler('cps1', TPlatformSettingsHandler);
  RegisterPlatformSettingsHandler('cps2', TPlatformSettingsHandler);
  RegisterPlatformSettingsHandler('cps3', TPlatformSettingsHandler);
  RegisterPlatformWindowLayout('cps1', TPlatformWindowLayout);
  RegisterPlatformWindowLayout('cps2', TPlatformWindowLayout);
  RegisterPlatformWindowLayout('cps3', TPlatformWindowLayout);
  RegisterPlatformSessionHandler('cps1', TPlatformSessionHandler);
  RegisterPlatformSessionHandler('cps2', TPlatformSessionHandler);
  RegisterPlatformSessionHandler('cps3', TPlatformSessionHandler);
  RegisterPlatformInputHandler('cps1', TPlatformInputHandler);
  RegisterPlatformInputHandler('cps2', TPlatformInputHandler);
  RegisterPlatformInputHandler('cps3', TPlatformInputHandler);
  RegisterInput;
  RegisterPlatformGamepads('cps1', TGamepadCPSArcade, []);
  RegisterPlatformGamepads('cps2', TGamepadCPSArcade, []);
  RegisterPlatformGamepads('cps3', TGamepadCPSArcade, []);
  RegisterPlatformPresentation('cps1', 'cps1', PlatformIcon);
  RegisterPlatformPresentation('cps2', 'cps2', PlatformIcon);
  RegisterPlatformPresentation('cps3', 'cps3', PlatformIcon);
end;

class procedure TCPSPlatform.RegisterPlatform;
begin
  if FRegistered then
    Exit;
  RegisterServices;
  RegisterCore;
  RegisterClient;
  FRegistered := True;
end;

end.

