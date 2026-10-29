unit RM.Platforms.Atari5200;

interface

uses
  Core.EmulatorRegistry, RM.Input, System.SysUtils;

const
  ROM_SYSTEM_A5200 = 'at5200';

type
  TA5200Platform = class
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
  RM.Platforms.Atari5200.Settings, RM.Settings.Catalog, RM.Settings.Platform,
  Core.Emulation, Core.Platforms, Core.Platforms.Atari5200.Adapter,
  RM.Platforms.Presentation, RM.Gamepad.Factory, RM.Platforms.Atari5200.Gamepads,
  RM.Input.Runtime, RM.Session.Runtime, RM.Window.Layout, RM.Settings.Runtime,
  RM.ControlsHelp.Content, RM.Settings.Callouts, RM.Settings.Devices,
  System.Classes, System.UITypes, System.Zip, System.IOUtils, Core.Snapshots,
  RM.Platforms.Atari5200.Input;

class function TA5200Platform.RecognizeArchive(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  var Hint := Context.RomName.ToLower.Replace('\', '/');
  if not Context.HasExtension(['.zip']) or
    not (Hint.Contains('/at5200/') or Hint.Contains('/atari5200/') or Hint.Contains('/a5200/')) then
    Exit;
  var Zip := TZipFile.Create;
  try
    Zip.Open(Context.Stream, zmRead);
    var Best := -1;
    var BestScore := Low(Integer);
    var Base := ChangeFileExt(ExtractFileName(Context.RomName), '').ToLower;
    for var i := 0 to Zip.FileCount - 1 do
    begin
      var Name := Zip.FileNames[i].ToLower;
      if not (Name.EndsWith('.car') or Name.EndsWith('.a52') or Name.EndsWith('.bin') or Name.EndsWith('.rom')) then
        Continue;
      var Score := 0;
      if Name.Contains('(merged)') then
        Inc(Score, 5000);
      if Name.Contains('($') then
        Dec(Score, 5000);
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
        Best := i;
        BestScore := Score;
      end;
    end;
    if Best < 0 then
      Exit;
    var Data: TBytes;
    if Zip.FileInfo[Best].UncompressedSize64 > 40976 then
      raise EReadError.Create('Unsupported Atari 5200 cartridge size');
    var Name := Zip.FileNames[Best];
    Zip.Read(Best, Data);
    Zip.Close;
    Context.LoadArchiveEntry(Data, Name);
    Result := Recognize(Context);
  finally
    Zip.Free;
  end;
end;

class function TA5200Platform.Recognize(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  var Hint := (Context.RomName + ' ' + Context.SourceName).ToLower.Replace('\', '/');
  if Context.HasExtension(['.a52']) or
    (Context.Signature(0, 'CART') and (Length(Context.Data) > 16) and
    (Context.Data[4] = 0) and (Context.Data[5] = 0) and (Context.Data[6] = 0) and
    (Context.Data[7] in [4, 6, 7, 16, 19, 20])) or
    ((Hint.Contains('/at5200/') or Hint.Contains('/atari5200/') or Hint.Contains('/a5200/')) and
    Context.HasExtension(['.bin', '.rom', '.a52', '.car'])) then
    Result := ImageMatch(Context, 'A5200',
      function(const Data: TBytes; Input: TStream): IEmulationCore
      begin
        Result := TA5200CoreAdapter.Create(Input, Context.Storage, Context.RomName, Context.SourceName);
      end);
end;

class procedure TA5200Platform.RegisterPlatforms;
begin
  TPlatformRegistry.RegisterPlatform('at5200', 'Atari 5200', '5200',
    'Atari', 'Atari SuperSystem 5200', 'at5200', ['at5200', 'atari5200', 'a5200'],
    ['.a52', '.car', '.bin', '.rom', '.zip', '.7z'], '', 'at5200', 4);
  TPlatformRegistry.RegisterAlias('a5200', 'at5200');
  TPlatformRegistry.RegisterAlias('atari5200', 'at5200');
end;

class procedure TA5200Platform.RegisterCore;
begin
  RegisterPlatforms;
  RegisterSnapshotPolicy('A5200', TSnapshotPolicy.Create(2));
  var Registration := TEmulationCoreRegistration.Create('A5200', ['.a52', '.car', '.bin', '.rom']);
  Registration.Add(TCoreLoadStage.Container, 5, RecognizeArchive);
  Registration.Add(TCoreLoadStage.Image, 5, Recognize);
  RegisterEmulationCore(Registration);
end;

class procedure TA5200Platform.LoadLegacyKeys(var Keys: TPlatformInputKeyMap);
var
  Config: IEmulatorConfig;
begin
  var C := TA5200Config.Create('');
  Config := C;
  for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
  begin
    Keys[0, B] := C.Keys[B];
    Keys[1, B] := C.Keys2[B];
  end;
end;

class procedure TA5200Platform.RegisterInput;
begin
  var Definition := TPlatformInputDefinition.Create([TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left, TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.Mode, TEmulatorButton.Start, TEmulatorButton.Select]);
  Definition.PadDevicesOnly := True;
  Definition.ButtonNames[TEmulatorButton.Start] := 'Start';
  Definition.ButtonNames[TEmulatorButton.Mode] := 'Reset';
  Definition.ButtonNames[TEmulatorButton.B] := 'Top fire';
  Definition.ButtonNames[TEmulatorButton.Select] := 'Pause';
  Definition.ButtonNames[TEmulatorButton.A] := 'Fire';
  Definition.LegacyPorts := 2;
  Definition.LegacySection := 'Keys';
  Definition.AfterLegacyBindings := LoadAtari5200LegacyBindings;
  Definition.AfterLoadBindings := MigrateAtari5200Bindings;
  Definition.FilterBinding := FilterAtari5200Binding;
  Definition.UseSharedBindingRules := True;
  Definition.LoadLegacyKeys := LoadLegacyKeys;
  RegisterPlatformInput('at5200', Definition);
end;

class procedure TA5200Platform.RegisterClient;
begin
  RegisterSettingsPlatform('at5200', TAtari5200Settings);
  RegisterPlatformSettingsDevices('at5200', TAtari5200SettingsDevices);
  RegisterPlatformDeviceCallouts('at5200', TPlatformDeviceCallouts);
  RegisterPlatformControlsHelp('at5200', TPlatformControlsHelp);
  RegisterPlatformSettingsHandler('at5200', TPlatformSettingsHandler);
  RegisterPlatformWindowLayout('at5200', TPlatformWindowLayout);
  RegisterPlatformSessionHandler('at5200', TPlatformSessionHandler);
  RegisterPlatformInputHandler('at5200', TAtari5200InputHandler);
  RegisterInput;
  RegisterPlatformGamepads('at5200', TGamepadAtari5200Standart,
    [TGamepadDeviceVariant.Create('pad-analog', TGamepadAtari5200Analog)]);
  RegisterPlatformPresentation('at5200', 'at5200', 'M10,25 L90,25 L100,65 L0,65 Z M10,55 L90,55 L90,60 L10,60 Z M20,30 L24,30 L24,48 L20,48 Z M30,30 L34,30 L34,48 L30,48 Z M40,30 L44,30 L44,48 L40,48 Z M50,30 L54,30 L54,48 L50,48 Z M60,30 L64,30 L64,48 L60,48 Z M75,33 L85,33 L85,43 L75,43 Z');
end;

class procedure TA5200Platform.RegisterPlatform;
begin
  if FRegistered then
    Exit;
  RegisterCore;
  RegisterClient;
  FRegistered := True;
end;

end.

