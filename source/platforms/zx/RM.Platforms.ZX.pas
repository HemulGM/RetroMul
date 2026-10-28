unit RM.Platforms.ZX;

interface

uses
  Core.Input.Keyboard, Core.EmulatorRegistry, RM.Input, System.SysUtils;

type
  TZXPlatform = class
  strict private
    class var
      FRegistered: Boolean;
    class function Source(Context: TCoreLoadContext): TCoreMatch; static;
    class function Image(Context: TCoreLoadContext): TCoreMatch; static;
    class function Preference(const OldName, NewName: string): Integer; static;
    class procedure RegisterPlatforms; static;
    class procedure RegisterCore; static;
    class procedure RegisterServices; static;
    class procedure RegisterTerminalInput; static;
    class procedure LoadLegacyKeys(var Keys: TPlatformInputKeyMap); static;
    class procedure RegisterInput; static;
    class procedure RegisterClient; static;
  public
    class procedure RegisterPlatform; static;
  end;

implementation

uses
  RM.Settings.Catalog, RM.Platforms.ZX.Keyboard, Core.PlatformServices,
  Core.Snapshots, System.StrUtils, Core.Emulation, Core.Platforms,
  Core.Platforms.ZX.Adapter, RM.Platforms.ZX.Settings,
  RM.Platforms.Presentation, RM.Platforms.SG1000.Icons, RM.Gamepad.Factory,
  RM.Platforms.ZX.Gamepads, RM.Input.Runtime, RM.Keyboard.Input,
  RM.Platforms.ZX.Runtime, RM.Session.Runtime, RM.Keyboard.Session,
  RM.Window.Layout, RM.Keyboard.Window, RM.Settings.Runtime,
  RM.Keyboard.Settings, RM.ControlsHelp.Content, RM.Platforms.ZX.Help,
  RM.Settings.Callouts, RM.Settings.Devices, System.Classes;

class function TZXPlatform.Source(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  if Context.HasExtension(['.mmc', '.ide']) then
    Result := TCoreMatch.Create('ZX',
      function: IEmulationCore
      begin
        Result := TZXCoreAdapter.Create(Context.Stream, Context.Storage, Context.RomName, Context.SourceName);
      end);
end;

class function TZXPlatform.Image(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  if IsZXImageName(Context.SourceName) then
    Result := ImageMatch(Context, 'ZX',
      function(const Data: TBytes; Input: TStream): IEmulationCore
      begin
        var Owned := Data;
        Result := TZXCoreAdapter.CreateOwned(Owned, Context.Storage, Context.RomName, Context.SourceName);
      end);
end;

class function TZXPlatform.Preference(const OldName, NewName: string): Integer;
begin
  Result := -1;
  if not IsZXImageName(OldName) or not IsZXImageName(NewName) then
    Exit;
  var OldDisk := MatchText(ExtractFileExt(OldName), ['.trd', '.scl', '.dsk']);
  var NewDisk := MatchText(ExtractFileExt(NewName), ['.trd', '.scl', '.dsk']);
  if OldDisk and not NewDisk then
    Exit(0);
  if NewDisk and not OldDisk then
    Exit(1);
  if SameText(ExtractFileExt(OldName), '.trd') and SameText(ExtractFileExt(NewName), '.scl') then
    Exit(0);
  if SameText(ExtractFileExt(NewName), '.trd') and SameText(ExtractFileExt(OldName), '.scl') then
    Exit(1);
end;

class procedure TZXPlatform.RegisterPlatforms;
begin
  TPlatformRegistry.RegisterPlatform('zx', 'ZX Spectrum', 'ZX',
    'Sinclair', 'ZX Spectrum 48K 128K +2 Pentagon 128K TR-DOS', 'zxspectrum', ['zxspectrum', 'zx', 'spectrum'],
    ['.sna', '.z80', '.tap', '.tzx', '.trd', '.scl', '.dsk', '.mmc', '.ide', '.dck', '.pro', '.kdi', '.zip', '.7z'],
    'ZXSpectrum', 'zx', 2);
end;

class procedure TZXPlatform.RegisterCore;
begin
  RegisterPlatforms;
  var Registration := TEmulationCoreRegistration.Create('ZX', ['.sna', '.z80', '.tap', '.tzx', '.trd', '.scl', '.dsk', '.dck', '.mmc', '.ide', '.pro', '.kdi']);
  Registration.Add(TCoreLoadStage.Source, 110, Source);
  Registration.Add(TCoreLoadStage.Image, 30, Image);
  Registration.ArchivePreference := Preference;
  RegisterEmulationCore(Registration);
end;

class procedure TZXPlatform.RegisterServices;
begin
  RegisterSnapshotPolicy('ZX', TSnapshotPolicy.Create(28));
end;

class procedure TZXPlatform.RegisterTerminalInput;
begin
  var Service := Default(TPlatformServices);
  Service.TerminalInput :=
    function(const Core: IEmulationCore): TTerminalInputPolicy
    var
      Keyboard: IEmulationKeyboard;
    begin
      Result := Default(TTerminalInputPolicy);
      Result.ExitKey := $1B;
      Result.AllKeys := Supports(Core, IEmulationKeyboard, Keyboard) and Keyboard.HasKeyboard;
      if Result.AllKeys then
        Result.ExitKey := $7B;
    end;
  RegisterPlatformServices('zx', Service);
end;

class procedure TZXPlatform.LoadLegacyKeys(var Keys: TPlatformInputKeyMap);
var
  Config: IEmulatorConfig;
begin
  var C := TZXConfig.Create('', nil);
  Config := C;
  for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
    Keys[0, B] := C.Keys[B];
end;

class procedure TZXPlatform.RegisterInput;
begin
  var Definition := TPlatformInputDefinition.Create([TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left,
      TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.Select, TEmulatorButton.Start,
      TEmulatorButton.Mode]);
  Definition.PadDevicesOnly := False;
  Definition.Devices := TArray<TInputDeviceVariant>.Create(TInputDeviceVariant.Create('none', []));
  Definition.ButtonNames[TEmulatorButton.A] := 'Fire';
  Definition.ButtonNames[TEmulatorButton.B] := 'Tape play/pause';
  Definition.ButtonNames[TEmulatorButton.Select] := '1';
  Definition.ButtonNames[TEmulatorButton.Start] := 'Enter';
  Definition.ButtonNames[TEmulatorButton.Mode] := 'Tape rewind';
  Definition.LegacyPorts := 1;
  Definition.LegacySection := 'Keys';
  Definition.AfterLegacyBindings := LoadSharedLegacyBindings;
  Definition.UseSharedBindingRules := True;
  Definition.LoadLegacyKeys := LoadLegacyKeys;
  RegisterPlatformInput('zx', Definition);
end;

class procedure TZXPlatform.RegisterClient;
begin
  RegisterSettingsProfile('ZXSpectrum', TZXSettings);
  RegisterPlatformKeyboard('zx', TZXKeyboard);
  RegisterPlatformSettingsDevices('zx', TPlatformSettingsDevices);
  RegisterPlatformDeviceCallouts('zx', TPlatformDeviceCallouts);
  RegisterPlatformControlsHelp('zx', TZXControlsHelp);
  RegisterPlatformSettingsHandler('zx', TKeyboardSettingsHandler);
  RegisterPlatformWindowLayout('zx', TKeyboardWindowLayout);
  RegisterPlatformSessionHandler('zx', TZXSessionHandler);
  RegisterPlatformInputHandler('zx', TZXInputHandler);
  RegisterInput;
  RegisterPlatformGamepads('zx', TGamepadZX, []);
  RegisterPlatformPresentation('zx', 'zx', PlatformIconSC3000);
end;

class procedure TZXPlatform.RegisterPlatform;
begin
  if FRegistered then
    Exit;
  RegisterTerminalInput;
  RegisterServices;
  RegisterCore;
  RegisterClient;
  FRegistered := True;
end;

end.

