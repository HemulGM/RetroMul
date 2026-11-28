unit RM.Platforms.NDS;

interface

uses
  FMXInput, Core.EmulatorRegistry;

type
  TNDSPlatform = class
  strict private
    class var
      FRegistered: Boolean;
    class function Source(Context: TCoreLoadContext): TCoreMatch; static;
    class function Header(Context: TCoreLoadContext): TCoreMatch; static;
    class function ExtensionHint(Context: TCoreLoadContext): TCoreMatch; static;
    class procedure LoadGamepadPreset(Input: TInputManager; Port: Integer); static;
  public
    class procedure RegisterPlatform; static;
  end;

implementation

uses
  RA.Console, Core.PlatformServices, RM.Input.Gamepads, System.SysUtils,
  System.Classes, Core.Platforms, Core.Emulation, Core.Platforms.NDS.Adapter,
  NDS.Cartridge, RM.Settings.Catalog, RM.Platforms.NDS.Settings,
  RM.Platforms.NDS.Input, RM.Input, RM.Input.Runtime, RM.Session.Runtime,
  RM.Window.Layout, RM.Settings.Runtime, RM.ControlsHelp.Content,
  RM.Settings.Callouts, RM.Settings.Devices, RM.Gamepad.Factory,
  RM.Platforms.SNES.Gamepads, RM.Platforms.Presentation, Core.Snapshots;

const
  PlatformIcon =
 'M30,2 L27,2 C26.44700050354,2 26,1.55200004577637 26,1 C26,0.447999954223633 25.55299949646,0 25,0 L7,0 C6.447' +
    '00002670288,0 6,0.448000013828278 6,1 C6,1.55200004577637 5.55299997329712,2 5,2 L2,2 C0.896000027656555,2 0,2' +
    '.89599990844727 0,4 L0,15 C0,16.1040000915527 0.896000027656555,17 2,17 L5,17 C5.55299997329712,17 6,17.447000' +
    '50354 6,18 C6,18.55299949646 6.44700002670288,19 7,19 L25,19 C25.55299949646,19 26,18.55299949646 26,18 C26,17' +
    '.44700050354 26.44700050354,17 27,17 L30,17 C31.1040000915527,17 32,16.1040000915527 32,15 L32,4 C32,2.8959999' +
    '0844727 31.1040000915527,2 30,2 Z M6,10 L5,10 L5,11 C5,11.55299949646 4.55299997329712,12 4,12 C3.447000026702' +
    '88,12 3,11.5530004501343 3,11 L3,10 L2,10 C1.44700002670288,10 1,9.55200004577637 1,9 C1,8.44799995422363 1.44' +
    '700002670288,8 2,8 L3,8 L3,7 C3,6.44799995422363 3.44700002670288,6 4,6 C4.55299997329712,6 5,6.44799995422363' +
    ' 5,7 L5,8 L6,8 C6.55299997329712,8 7,8.44799995422363 7,9 C7,9.55200004577637 6.55299997329712,10 6,10 Z M23,1' +
    '5 C23,15.55299949646 22.55299949646,16 22,16 L10,16 C9.44700050354004,16 9,15.5530004501343 9,15 L9,4 C9,3.447' +
    '99995422363 9.44699954986572,3 10,3 L22,3 C22.55299949646,3 23,3.44799995422363 23,4 L23,15 Z M26.5,13 C25.672' +
    '0008850098,13 25,12.3280000686646 25,11.5 C25,10.6719999313354 25.6720008850098,10 26.5,10 C27.3279991149902,1' +
    '0 28,10.6719999313354 28,11.5 C28,12.3280000686646 27.3279991149902,13 26.5,13 Z M29.5,10 C28.6720008850098,10' +
    ' 28,9.32800006866455 28,8.5 C28,7.67199993133545 28.6720008850098,7 29.5,7 C30.3279991149902,7 31,7.6719999313' +
    '3545 31,8.5 C31,9.32800006866455 30.3279991149902,10 29.5,10 Z M5,0 L2,0 C1.44700002670288,0 1,0 1,1 L5,1 L5,0' +
    ' Z M2,19 L5,19 L5,18 L1,18 C1,18.55299949646 1.44700002670288,19 2,19 Z M30,0 L27,0 L27,1 L31,1 C31,0 30.55299' +
    '949646,0 30,0 Z M27,19 L30,19 C30.55299949646,19 31,18.55299949646 31,18 L27,18 L27,19 Z ';

type
  TNDSSessionHandler = class(TPlatformSessionHandler)
    class procedure Connect(const Context: TSessionRuntimeContext); override;
  end;

class procedure TNDSPlatform.LoadGamepadPreset(Input: TInputManager; Port: Integer);
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

class procedure TNDSSessionHandler.Connect(const Context: TSessionRuntimeContext);
begin
  inherited;
  Context.Host.Video.SetPointerInputEnabled(True, True);
end;

class function TNDSPlatform.Source(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  if Context.HasExtension(['.nds']) then
  begin
    Result := TCoreMatch.Create('NDS',
      function: IEmulationCore
      begin
        var Saved := Context.Stream.Position;
        try
          Result := TNDSCoreAdapter.Create(Context.Stream, Context.Storage, Context.RomName);
        finally
          Context.Stream.Position := Saved;
        end;
      end);
    Result.Format.SystemId := 'nds';
  end;
end;

class function TNDSPlatform.Header(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  if IsNDSROM(Context.Data) then
    Result := ImageMatch(Context, 'NDS',
      function(const Data: TBytes; Input: TStream): IEmulationCore
      begin
        Result := TNDSCoreAdapter.Create(Input, Context.Storage, Context.RomName);
      end,
          False, 'nds', '', NDS_ROM_MAX_SIZE);
end;

class function TNDSPlatform.ExtensionHint(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  if not Context.HeaderRecognized and Context.HasExtension(['.nds']) then
    Result := ImageMatch(Context, 'NDS',
      function(const Data: TBytes; Input: TStream): IEmulationCore
      begin
        Result := TNDSCoreAdapter.Create(Input, Context.Storage, Context.RomName);
      end,
          False, 'nds', '', NDS_ROM_MAX_SIZE);
end;

class procedure TNDSPlatform.RegisterPlatform;
begin
  if FRegistered then
    Exit;
  TPlatformRegistry.RegisterPlatform('nds', 'Nintendo DS', 'NDS',
    'Nintendo', 'Nintendo DS ARM9 ARM7 stylus', 'nds', ['nds'], ['.nds'], 'NDS', 'nds', 1);
  var Registration := TEmulationCoreRegistration.Create('NDS', ['.nds']);
  Registration.MaxArchiveImageSize := NDS_ROM_MAX_SIZE;
  Registration.Add(TCoreLoadStage.Source, 40, Source);
  Registration.Add(TCoreLoadStage.Header, 92, Header);
  Registration.Add(TCoreLoadStage.OverrideHint, 20, ExtensionHint);
  RegisterEmulationCore(Registration);
  RegisterSnapshotPolicy('NDS', TSnapshotPolicy.Create(1, 32 * 1024 * 1024));
  RegisterSettingsProfile('NDS', TNDSSettings,
    'Place the upper screen above or beside the touch screen in Video and Audio. Use touch or ' +
    'pointer input on the lower screen. If an unrecognized game needs a different cartridge ' +
    'save size, change the setting and restart. Existing save files keep their size.');
  RegisterPlatformSettingsDevices('nds', TPlatformSettingsDevices);
  RegisterPlatformDeviceCallouts('nds', TPlatformDeviceCallouts);
  RegisterPlatformControlsHelp('nds', TPlatformControlsHelp);
  RegisterPlatformSettingsHandler('nds', TPlatformSettingsHandler);
  RegisterPlatformWindowLayout('nds', TPlatformWindowLayout);
  RegisterPlatformSessionHandler('nds', TNDSSessionHandler);
  RegisterPlatformInputHandler('nds', TNDSInputHandler);
  var Definition := TPlatformInputDefinition.Create(NDS_BUTTONS);
  Definition.ButtonNames[TEmulatorButton.C] := 'L';
  Definition.ButtonNames[TEmulatorButton.Z] := 'R';
  Definition.LegacyPorts := 1;
  Definition.LegacySection := 'Keys';
  Definition.AfterLegacyBindings := LoadSharedLegacyBindings;
  Definition.UseSharedBindingRules := True;
  Definition.LegacyKeyNames[TEmulatorButton.C] := 'L';
  Definition.LegacyKeyNames[TEmulatorButton.Z] := 'R';
  Definition.LoadLegacyKeys :=
    procedure(var Keys: TPlatformInputKeyMap)
    begin
      var C := TNDSConfig.Create('', nil);
      var Hold: IEmulatorConfig := C;
      for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
        Keys[0, B] := C.Keys[B];
    end;
  Definition.LoadGamepadPreset := LoadGamepadPreset;
  RegisterPlatformInput('nds', Definition);
  RegisterPlatformGamepads('nds', TGamepadSNESStandart, []);
  RegisterPlatformPresentation('nds', 'nds', PlatformIcon);
  FRegistered := True;
  RegisterPlatformAchievementMedia('nds', RAConsoleNintendoDS, TPlatformRegistry.Require('nds').Extensions);
end;

end.

