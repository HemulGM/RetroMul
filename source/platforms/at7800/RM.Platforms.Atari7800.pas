unit RM.Platforms.Atari7800;

interface

uses
  FMXInput, Core.EmulatorRegistry, RM.Input;

type
  TA7800Platform = class
  strict private
    class var
      FRegistered: Boolean;
    class function Recognize(Context: TCoreLoadContext): TCoreMatch; static;
    class function RecognizeArchive(Context: TCoreLoadContext): TCoreMatch; static;
    class procedure LoadKeys(var Keys: TPlatformInputKeyMap); static;
    class procedure LoadGamepadPreset(Input: TInputManager; Port: Integer); static;
  public
    class procedure RegisterPlatform; static;
  end;

implementation

uses
  RM.Input.Gamepads,
  System.SysUtils, System.Classes, System.UITypes, Core.Emulation,
  Core.Platforms, Core.Platforms.Atari7800.Adapter, A7800.Cartridge,
  Core.Snapshots, RM.Settings.Catalog, RM.Platforms.Atari7800.Settings,
  RM.Platforms.Atari7800.Gamepads, RM.Platforms.Presentation, RM.Gamepad.Factory,
  RM.Input.Runtime, RM.Session.Runtime, RM.Settings.Runtime, RM.Window.Layout,
  RM.ControlsHelp.Content, RM.Settings.Callouts, RM.Settings.Devices;

class procedure TA7800Platform.LoadGamepadPreset(Input: TInputManager; Port: Integer);
begin
  for var Direction := TEmulatorButton.Up to TEmulatorButton.Right do
    AddStandardDirection(Input, Port, PadAction(Port, Direction), Ord(Direction), True);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.A), TGamepadButton.South);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.B), TGamepadButton.East);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.Select), TGamepadButton.Select);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.Start), TGamepadButton.Start);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.Mode), TGamepadButton.RightShoulder);
end;

class function TA7800Platform.Recognize(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  var Hint := (Context.RomName + ' ' + Context.SourceName).ToLower.Replace('\', '/');
  if Context.HasExtension(['.a78']) or TA7800Cartridge.HasHeader(Context.Prefix(128)) or
    (Context.HasExtension(['.bin', '.rom']) and
    (Hint.Contains('/at7800/') or Hint.Contains('/atari7800/') or Hint.Contains('/a7800/'))) then
    Result := ImageMatch(Context, 'A7800',
      function(const Data: TBytes; Input: TStream): IEmulationCore
      begin
        Result := TA7800CoreAdapter.Create(Input, Context.EffectiveStorage, Context.RomName, Context.SourceName);
      end, False, 'at7800', '', $100080);
end;

class function TA7800Platform.RecognizeArchive(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  var Hint := Context.RomName.ToLower.Replace('\', '/');
  if (Context.Archive = nil) or not (Hint.Contains('/at7800/') or
    Hint.Contains('/atari7800/') or Hint.Contains('/a7800/')) then
    Exit;
  var Archive := Context.Archive;
  var Best := -1;
  var BestScore := Low(Integer);
  for var I := 0 to Archive.Count - 1 do
  begin
    if Archive.Entries[I].IsDirectory or (Archive.Entries[I].Size > $100080) then
      Continue;
    var Name := Archive.Entries[I].Name.ToLower;
    if not (Name.EndsWith('.a78') or Name.EndsWith('.bin') or Name.EndsWith('.rom')) then
      Continue;
    var Score := 0;
    if Name.EndsWith('.a78') then
      Inc(Score, 1000);
    if Name.Contains('[!]') then
      Inc(Score, 100);
    if Name.Contains('[b') or Name.Contains('[h') or Name.Contains('[o') then
      Dec(Score, 200);
    if Score > BestScore then
    begin
      Best := I;
      BestScore := Score;
    end;
  end;
  if Best < 0 then
    Exit;
  var Data: TBytes;
  Archive.Read(Best, Data);
  Context.LoadArchiveEntry(Data, Archive.Entries[Best].Name);
  Result := Recognize(Context);
end;

class procedure TA7800Platform.LoadKeys(var Keys: TPlatformInputKeyMap);
begin
  var C := TA7800Config.Create('');
  try
    for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
    begin
      Keys[0, B] := C.Keys[B];
      Keys[1, B] := C.Keys2[B];
    end;
  finally
    C.Free;
  end;
end;

class procedure TA7800Platform.RegisterPlatform;
begin
  if FRegistered then
    Exit;
  TPlatformRegistry.RegisterPlatform('at7800', 'Atari 7800', '7800', 'Atari',
    'Atari 7800 ProSystem', 'at7800', ['at7800', 'atari7800', 'a7800'],
    ['.a78', '.bin', '.rom'], 'Atari7800', 'at7800', 2);
  TPlatformRegistry.RegisterAlias('atari7800', 'at7800');
  TPlatformRegistry.RegisterAlias('a7800', 'at7800');
  RegisterSnapshotPolicy('A7800', TSnapshotPolicy.Create(2));
  var Registration := TEmulationCoreRegistration.Create('A7800', ['.a78', '.bin', '.rom']);
  Registration.Add(TCoreLoadStage.Container, 6, RecognizeArchive);
  Registration.Add(TCoreLoadStage.Header, 100, Recognize);
  Registration.Add(TCoreLoadStage.OverrideHint, 6, Recognize);
  RegisterEmulationCore(Registration);
  RegisterSettingsProfile('Atari7800', TAtari7800Settings);
  RegisterPlatformSettingsDevices('at7800', TPlatformSettingsDevices);
  RegisterPlatformDeviceCallouts('at7800', TPlatformDeviceCallouts);
  RegisterPlatformControlsHelp('at7800', TPlatformControlsHelp);
  RegisterPlatformSettingsHandler('at7800', TPlatformSettingsHandler);
  RegisterPlatformWindowLayout('at7800', TPlatformWindowLayout);
  RegisterPlatformSessionHandler('at7800', TPlatformSessionHandler);
  RegisterPlatformInputHandler('at7800', TPlatformInputHandler);
  RegisterPlatformGamepads('at7800', TGamepadAtari7800, []);
  // Console silhouette is a subject-specific image.
  RegisterPlatformPresentation('at7800', 'at7800',
    'M8,24 L88,24 L98,72 L2,72 Z M12,30 L84,30 L86,44 L10,44 Z ' +
    'M16,54 L30,54 L30,62 L16,62 Z M40,54 L48,54 L48,62 L40,62 Z M58,54 L66,54 L66,62 L58,62 Z');
  var Definition := TPlatformInputDefinition.Create([TEmulatorButton.Up, TEmulatorButton.Down,
      TEmulatorButton.Left, TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B,
      TEmulatorButton.Start, TEmulatorButton.Select, TEmulatorButton.Mode]);
  Definition.ButtonNames[TEmulatorButton.A] := '1';
  Definition.ButtonNames[TEmulatorButton.B] := '2';
  Definition.ButtonNames[TEmulatorButton.Start] := 'Reset';
  Definition.ButtonNames[TEmulatorButton.Select] := 'Select';
  Definition.ButtonNames[TEmulatorButton.Mode] := 'Pause';
  Definition.LegacyPorts := 2;
  Definition.LegacySection := 'Keys';
  Definition.AfterLegacyBindings := LoadSharedLegacyBindings;
  Definition.UseSharedBindingRules := True;
  Definition.LoadLegacyKeys := LoadKeys;
  Definition.LoadGamepadPreset := LoadGamepadPreset;
  RegisterPlatformInput('at7800', Definition);
  FRegistered := True;
end;

end.

