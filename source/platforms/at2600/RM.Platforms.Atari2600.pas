unit RM.Platforms.Atari2600;

interface

uses
  Core.EmulatorRegistry, RM.Input, System.SysUtils;

const
  ROM_SYSTEM_A2600 = 'at2600';

type
  TA2600Platform = class
  strict private
    class var
      FRegistered: Boolean;
    class function Recognize(Context: TCoreLoadContext): TCoreMatch; static;
    class function RecognizeArchive(Context: TCoreLoadContext): TCoreMatch; static;
    class procedure RegisterPlatforms; static;
    class procedure RegisterCore; static;
    class procedure LoadLegacyKeys(var Keys: TPlatformInputKeyMap); static;
    class procedure RegisterInput; static;
    class procedure RegisterClient; static;
  public
    class procedure RegisterPlatform; static;
  end;

implementation

uses
  RM.Platforms.Atari2600.Settings, RM.Settings.Catalog, RM.Settings.Platform,
  Core.Emulation, Core.Platforms, Core.Platforms.Atari2600.Adapter,
  RM.Platforms.Presentation, RM.Gamepad.Factory, RM.Platforms.Atari2600.Gamepads,
  RM.Input.Runtime, RM.Session.Runtime, RM.Window.Layout, RM.Settings.Runtime,
  RM.ControlsHelp.Content, RM.Settings.Callouts, RM.Settings.Devices,
  System.Classes, System.UITypes, System.Zip, System.IOUtils, Core.Snapshots,
  Core.InputConfig, System.IniFiles;

procedure ReadA2600InputPorts(Ini: TCustomIniFile; var Ports: TCoreInputPorts);
begin
  for var Port := 0 to 1 do
  begin
    var Section := 'Paddles' + IntToStr(Port + 1);
    Ports.SetOption(Section + '.Speed', IntToStr(Ini.ReadInteger(Section, 'Speed', 100)));
    Ports.SetOption(Section + '.Mouse', BoolToStr(Ini.ReadBool(Section, 'Mouse', False), True));
    Ports.SetOption(Section + '.MouseSensitivity', IntToStr(Ini.ReadInteger(Section, 'MouseSensitivity', 100)));
    for var Knob := 1 to 2 do
    begin
      var Suffix := IntToStr(Knob);
      for var Key in ['Minimum', 'Maximum', 'DeadZone', 'Invert'] do
      begin
        var DefaultValue: string := '0';
        if Key = 'Maximum' then
          DefaultValue := '100';
        if Key = 'DeadZone' then
          DefaultValue := '2';
        if Key = 'Invert' then
          Ports.SetOption(Section + '.' + Key + Suffix, BoolToStr(Ini.ReadBool(Section, Key + Suffix, False), True))
        else
          Ports.SetOption(Section + '.' + Key + Suffix, Ini.ReadString(Section, Key + Suffix, DefaultValue));
      end;
    end;
  end;
end;

class function TA2600Platform.RecognizeArchive(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  var Hint := Context.RomName.ToLower.Replace('\', '/');
  if not Context.HasExtension(['.zip']) or
    not (Hint.Contains('/at2600/') or Hint.Contains('/atari2600/') or Hint.Contains('/a2600/')) then
    Exit;
  var Zip := TZipFile.Create;
  try
    Zip.Open(Context.Stream, zmRead);
    var Best := -1;
    var BestScore := Low(Integer);
    var Base := ChangeFileExt(ExtractFileName(Context.RomName), '').ToLower;
    for var I := 0 to Zip.FileCount - 1 do
    begin
      var Name := Zip.FileNames[I].ToLower;
      if not (Name.EndsWith('.a26') or Name.EndsWith('.bin') or Name.EndsWith('.rom')) then
        Continue;
      var Score := 0;
      if ExtractFileName(Name).StartsWith(Base) then
        Inc(Score, 1000);
      if Name.Contains('[!]') then
        Inc(Score, 100);
      if Name.Contains('(pal)') then
        Dec(Score, 10);
      if Name.Contains('[a') or Name.Contains('[b') or Name.Contains('[h') or
        Name.Contains('[o') or Name.Contains('[t') then
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
    if Zip.FileInfo[Best].UncompressedSize64 > 512 * 1024 then
      raise EReadError.Create('Unsupported Atari 2600 cartridge size');
    var Name := Zip.FileNames[Best];
    Zip.Read(Best, Data);
    Zip.Close;
    Context.LoadArchiveEntry(Data, Name);
    Result := Recognize(Context);
  finally
    Zip.Free;
  end;
end;

class function TA2600Platform.Recognize(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  var Hint := (Context.RomName + ' ' + Context.SourceName).ToLower.Replace('\', '/');
  if Context.HasExtension(['.a26']) or
    ((Hint.Contains('/at2600/') or Hint.Contains('/atari2600/') or Hint.Contains('/a2600/')) and
    Context.HasExtension(['.bin', '.rom', '.a26'])) then
    Result := ImageMatch(Context, 'A2600',
      function(const Data: TBytes; Input: TStream): IEmulationCore
      begin
        Result := TA2600CoreAdapter.Create(Input, Context.Storage, Context.RomName, Context.SourceName);
      end);
end;

class procedure TA2600Platform.RegisterPlatforms;
begin
  TPlatformRegistry.RegisterPlatform('at2600', 'Atari 2600', '2600',
    'Atari', 'Atari VCS 2600', 'at2600', ['at2600', 'atari2600', 'a2600'],
    ['.a26', '.bin', '.rom', '.zip', '.7z'], '', 'at2600', 2);
  TPlatformRegistry.RegisterAlias('a2600', 'at2600');
  TPlatformRegistry.RegisterAlias('atari2600', 'at2600');
end;

class procedure TA2600Platform.RegisterCore;
begin
  RegisterPlatforms;
  var Policy := TSnapshotPolicy.Create(3);
  Policy.AcceptedVersions := [2];
  RegisterSnapshotPolicy('A2600', Policy);
  RegisterInputPortsReader('at2600', ReadA2600InputPorts);
  var Registration := TEmulationCoreRegistration.Create('A2600', ['.a26', '.bin', '.rom']);
  Registration.Add(TCoreLoadStage.Container, 5, RecognizeArchive);
  Registration.Add(TCoreLoadStage.Image, 5, Recognize);
  RegisterEmulationCore(Registration);
end;

class procedure TA2600Platform.LoadLegacyKeys(var Keys: TPlatformInputKeyMap);
var
  Config: IEmulatorConfig;
begin
  var C := TA2600Config.Create('');
  Config := C;
  for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
  begin
    Keys[0, B] := C.Keys[B];
    Keys[1, B] := C.Keys2[B];
  end;
end;

class procedure TA2600Platform.RegisterInput;
begin
  var JoystickButtons: TEmulatorButtons := [TEmulatorButton.Up, TEmulatorButton.Down,
      TEmulatorButton.Left, TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.Start, TEmulatorButton.Select];
  var Definition := TPlatformInputDefinition.Create(JoystickButtons + [TEmulatorButton.B]);
  Definition.Devices := [TInputDeviceVariant.Create('pad', JoystickButtons),
      TInputDeviceVariant.Create('pad-analog', Definition.Buttons)];
  Definition.PadDevicesOnly := True;
  Definition.ButtonNames[TEmulatorButton.Start] := 'Reset';
  Definition.ButtonNames[TEmulatorButton.Select] := 'Select';
  Definition.ButtonNames[TEmulatorButton.A] := 'Fire';
  Definition.ButtonNames[TEmulatorButton.B] := 'Paddle 2 fire';
  Definition.LegacyPorts := 2;
  Definition.LegacySection := 'Keys';
  Definition.AfterLegacyBindings := LoadSharedLegacyBindings;
  Definition.UseSharedBindingRules := True;
  Definition.LoadLegacyKeys := LoadLegacyKeys;
  RegisterPlatformInput('at2600', Definition);
end;

class procedure TA2600Platform.RegisterClient;
begin
  RegisterSettingsPlatform('at2600', TAtari2600Settings);
  RegisterPlatformSettingsDevices('at2600', TAtari2600SettingsDevices);
  RegisterPlatformDeviceCallouts('at2600', TPlatformDeviceCallouts);
  RegisterPlatformControlsHelp('at2600', TPlatformControlsHelp);
  RegisterPlatformSettingsHandler('at2600', TPlatformSettingsHandler);
  RegisterPlatformWindowLayout('at2600', TPlatformWindowLayout);
  RegisterPlatformSessionHandler('at2600', TPlatformSessionHandler);
  RegisterPlatformInputHandler('at2600', TPlatformInputHandler);
  RegisterInput;
  RegisterPlatformGamepads('at2600', TGamepadAtari2600Standart,
    [TGamepadDeviceVariant.Create('pad-analog', TGamepadAtari2600Paddles)]);
  RegisterPlatformPresentation('at2600', 'at2600', 'M10,25 L90,25 L100,65 L0,65 Z M10,55 L90,55 L90,60 L10,60 Z M20,30 L24,30 L24,48 L20,48 Z M30,30 L34,30 L34,48 L30,48 Z M40,30 L44,30 L44,48 L40,48 Z M50,30 L54,30 L54,48 L50,48 Z M60,30 L64,30 L64,48 L60,48 Z M75,33 L85,33 L85,43 L75,43 Z');
end;

class procedure TA2600Platform.RegisterPlatform;
begin
  if FRegistered then
    Exit;
  RegisterCore;
  RegisterClient;
  FRegistered := True;
end;

end.

