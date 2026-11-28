unit RM.Platforms.PSP;

interface

uses
  Core.EmulatorRegistry, RM.Input, System.SysUtils, FMXInput, System.IniFiles;

type
  TPSPPlatform = class
  strict private
    class var
      FRegistered: Boolean;
    class function Source(Context: TCoreLoadContext): TCoreMatch; static;
    class function Header(Context: TCoreLoadContext): TCoreMatch; static;
    class procedure RegisterPlatforms; static;
    class procedure RegisterCore; static;
    class procedure LoadLegacyKeys(var Keys: TPlatformInputKeyMap); static;
    class procedure LoadGamepadPreset(Input: TInputManager; Port: Integer); static;
    class procedure RegisterInput; static;
    class procedure RegisterClient; static;
  public
    class procedure RegisterPlatform; static;
  end;

implementation

uses
  RA.Console, Core.PlatformServices, RM.Input.Gamepads, RM.Settings.Catalog,
  RM.Settings.Platform, System.StrUtils, Core.Emulation, Core.Platforms,
  Core.Platforms.PSP.Adapter, Core.Platforms.PSP.Archive, PSP.Media,
  RM.Platforms.Presentation, RM.Gamepad.Factory, RM.Platforms.PSP.Gamepads,
  RM.Platforms.PSP.Settings, RM.Input.Runtime, RM.Session.Runtime,
  RM.Window.Layout, RM.Settings.Runtime, RM.ControlsHelp.Content,
  RM.Settings.Callouts, RM.Settings.Devices, RM.Platforms.PSP.Input,
  System.Classes;

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

class function TPSPPlatform.Source(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  var Suitable := Context.HasExtension(['.pbp', '.elf', '.prx', '.cso']);
  if Context.HasExtension(['.elf']) then
  begin
    var Header := Context.Prefix(20);
    if (Length(Header) >= 20) and (Header[0] = $7F) and (Header[1] = Ord('E')) and
      (Header[2] = Ord('L')) and (Header[3] = Ord('F')) and (Header[18] = 42) and (Header[19] = 0) then
      Suitable := False;
  end;
  var RestorePosition := False;
  if Context.HasExtension(['.iso']) and TPSPDisc.Recognizes(Context.Stream) then
  begin
    var Saved := Context.Stream.Position;
    try
      try
        var Disc := TPSPDisc.Create(Context.Stream);
        try
          Suitable := Disc.IsPSP;
          RestorePosition := Suitable;
        finally
          Disc.Free;
        end;
      except
        on E: EPSPFormat do
          Suitable := False;
      end;
    finally
      Context.Stream.Position := Saved;
    end;
  end;
  if (Context.Archive <> nil) then
    Suitable := IsPSPArchive(Context.Archive);
  if Suitable then
    Result := TCoreMatch.Create('PSP',
      function: IEmulationCore
      begin
        var Saved := Context.Stream.Position;
        try
          Result := TPSPCoreAdapter.Create(Context.Stream, Context.Storage, Context.RomName, Context.SourceName);
        finally
          if RestorePosition then
            Context.Stream.Position := Saved;
        end;
      end);
end;

class function TPSPPlatform.Header(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  var Bytes := Context.Data;
  if Context.Signature(0, #0'PBP') or
    ((Length(Bytes) >= 20) and Context.Signature(0, #$7F'ELF') and (Bytes[18] = 8) and (Bytes[19] = 0)) then
    Result := ImageMatch(Context, 'PSP',
      function(const Data: TBytes; Input: TStream): IEmulationCore
      begin
        Result := TPSPCoreAdapter.Create(Input, Context.Storage, Context.RomName, Context.SourceName);
      end);
end;

class procedure TPSPPlatform.RegisterPlatforms;
begin
  TPlatformRegistry.RegisterPlatform('psp', 'PlayStation Portable (experimental)', 'PSP',
    'Sony', 'PSP PlayStation Portable Allegrex homebrew', 'psp', ['psp'],
    ['.iso', '.cso', '.pbp', '.elf', '.prx'],
    '', 'psp', 1);
end;

class procedure TPSPPlatform.RegisterCore;
begin
  RegisterPlatforms;
  var Registration := TEmulationCoreRegistration.Create('PSP', ['.pbp', '.elf', '.prx', '.cso']);
  Registration.Add(TCoreLoadStage.Source, 20, Source);
  Registration.Add(TCoreLoadStage.Header, 31, Header);
  // Library platform selection routes ISO/ZIP media through disc loaders.
  Registration.AddDiscPlatform('psp', Source);
  RegisterEmulationCore(Registration);
end;

class procedure TPSPPlatform.LoadLegacyKeys(var Keys: TPlatformInputKeyMap);
var
  Config: IEmulatorConfig;
begin
  var C := TPSPConfig.Create('', nil);
  Config := C;
  for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
    Keys[0, B] := C.Keys[B];
end;

class procedure TPSPPlatform.LoadGamepadPreset(Input: TInputManager; Port: Integer);
begin
  for var Direction := TEmulatorButton.Up to TEmulatorButton.Right do
    AddStandardDirection(Input, Port, PadAction(Port, Direction), Ord(Direction), False);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.A), TGamepadButton.South);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.B), TGamepadButton.East);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.Select), TGamepadButton.Select);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.Start), TGamepadButton.Start);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.C), TGamepadButton.LeftShoulder);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.X), TGamepadButton.West);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.Y), TGamepadButton.North);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.Z), TGamepadButton.RightShoulder);
  AddStandardStick(Input, Port, False, [
      PSPStickActionOf(TPSPStickDirection.StickUp), PSPStickActionOf(TPSPStickDirection.StickDown),
      PSPStickActionOf(TPSPStickDirection.StickLeft), PSPStickActionOf(TPSPStickDirection.StickRight)]);
end;

class procedure TPSPPlatform.RegisterInput;
begin
  var Definition := TPlatformInputDefinition.Create([TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left,
      TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.Select, TEmulatorButton.Start,
      TEmulatorButton.C, TEmulatorButton.X, TEmulatorButton.Y, TEmulatorButton.Z]);
  Definition.ButtonNames[TEmulatorButton.A] := 'Cross';
  Definition.ButtonNames[TEmulatorButton.B] := 'Circle';
  Definition.ButtonNames[TEmulatorButton.C] := 'L';
  Definition.ButtonNames[TEmulatorButton.X] := 'Square';
  Definition.ButtonNames[TEmulatorButton.Y] := 'Triangle';
  Definition.ButtonNames[TEmulatorButton.Z] := 'R';
  Definition.LegacyPorts := 1;
  Definition.LegacySection := 'Keys';
  Definition.AfterLegacyBindings := LoadSharedLegacyBindings;
  Definition.UseSharedBindingRules := True;
  Definition.LoadLegacyKeys := LoadLegacyKeys;
  Definition.LoadGamepadPreset := LoadGamepadPreset;
  Definition.FilterBinding :=
    procedure(const Binding: TInputBinding; Ini: TCustomIniFile; var Policy: TInputBindingPolicy)
    begin
      if (Binding.Action >= PSPStickAction) and (Binding.Action < PSPStickAction + 4) then
        Policy.SourceKey := 'Source1';
    end;
  RegisterPlatformInput('psp', Definition);
end;

class procedure TPSPPlatform.RegisterClient;
begin
  RegisterSettingsPlatform('psp', TPSPSettings,
    'The CPU renderer is the default. Experimental Vulkan LLE aims to match it using compute ' +
    'shaders at 480×272. Experimental Vulkan HLE uses the GPU graphics pipeline and supports ' +
    'higher internal resolution and optional texture scaling, with possible image differences. ' +
    'The settings show available renderers for the device. Stop and reopen the game after ' +
    'changing the renderer. JIT controls CPU execution separately.');
  RegisterPlatformSettingsDevices('psp', TPSPSettingsDevices);
  RegisterPlatformDeviceCallouts('psp', TPlatformDeviceCallouts);
  RegisterPlatformControlsHelp('psp', TPSPControlsHelp);
  RegisterPlatformSettingsHandler('psp', TPlatformSettingsHandler);
  RegisterPlatformWindowLayout('psp', TPlatformWindowLayout);
  RegisterPlatformSessionHandler('psp', TPlatformSessionHandler);
  RegisterPlatformInputHandler('psp', TPSPInputHandler);
  RegisterInput;
  RegisterPlatformGamepads('psp', TGamepadPSP, []);
  RegisterPlatformPresentation('psp', 'psp', PlatformIcon);
end;

class procedure TPSPPlatform.RegisterPlatform;
begin
  if FRegistered then
    Exit;
  RegisterCore;
  RegisterClient;
  FRegistered := True;
  RegisterPlatformAchievementMedia('psp', RAConsolePSP, ['.iso', '.cso'], True);
end;

end.

