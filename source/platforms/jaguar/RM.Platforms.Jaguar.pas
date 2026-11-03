unit RM.Platforms.Jaguar;

interface

uses
  Core.EmulatorRegistry, RM.Input;

type
  TJaguarPlatform = class
  strict private
    class function LoadDisc(Context: TCoreLoadContext): TCoreMatch; static;
    class var
      FRegistered: Boolean;
    class function Source(Context: TCoreLoadContext): TCoreMatch; static;
    class function Recognize(Context: TCoreLoadContext): TCoreMatch; static;
    class function RecognizeArchive(Context: TCoreLoadContext): TCoreMatch; static;
    class procedure LoadKeys(var Keys: TPlatformInputKeyMap); static;
  public
    class procedure RegisterPlatform; static;
  end;

implementation

uses
  System.SysUtils, System.Classes, System.UITypes, Core.Emulation,
  Core.Platforms, Core.Platforms.Jaguar.Adapter, Jaguar.Jerry, Jaguar.CD,
  Core.CD.Disc, Core.Snapshots, RM.Settings.Catalog,
  RM.Platforms.Jaguar.Settings, RM.Platforms.Jaguar.Gamepads,
  RM.Platforms.Presentation, RM.Gamepad.Factory, RM.Input.Runtime,
  RM.Platforms.Jaguar.Input, RM.Session.Runtime, RM.Settings.Runtime,
  RM.Window.Layout, RM.ControlsHelp.Content, RM.Settings.Callouts,
  RM.Settings.Devices;

class function TJaguarPlatform.LoadDisc(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := TCoreMatch.Create('JAGUAR',
    function: IEmulationCore
    begin
      Context.Stream.Position := 0;
      Result := TJaguarCoreAdapter.Create(Context.Stream, Context.EffectiveStorage, Context.RomName, Context.SourceName, Context.TakeDisc);
    end);
  Result.Format.SystemId := 'jaguarcd';
end;

class function TJaguarPlatform.Source(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  var Hint := (Context.RomName + ' ' + Context.SourceName).ToLower.Replace('\', '/');
  var IsJaguar := Hint.Contains('/jaguarcd/') or Hint.Contains('/jaguar-cd/') or
    Hint.Contains('/atarijaguarcd/');
  if Context.HasExtension(['.m3u']) then
  begin
    if not IsJaguar then
    begin
      try
        IsJaguar := TJaguarCD.IsJaguarDisc(Context.PlaylistDisc('jaguarcd'));
      except
        on E: EReadError do
          Exit;
      end;
    end;
    if not IsJaguar then
      Exit;
    Exit(LoadDisc(Context));
  end;
  if Context.IsDiscSource and (IsJaguar or TJaguarCD.IsJaguarDisc(Context.Disc)) then
  begin
    Result := LoadDisc(Context);
    if IsJaguar then
      Result.Confidence := TCoreMatchConfidence.Hint;
  end;
end;

class function TJaguarPlatform.Recognize(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  var Hint := (Context.RomName + ' ' + Context.SourceName).ToLower.Replace('\', '/');
  if Context.HasExtension(['.j64']) or
    (Context.HasExtension(['.bin', '.rom']) and
    (Hint.Contains('/jaguar/') or Hint.Contains('/atarijaguar/') or Hint.Contains('/jag/'))) then
    Result := ImageMatch(Context, 'JAGUAR',
      function(const Data: TBytes; Input: TStream): IEmulationCore
      begin
        Result := TJaguarCoreAdapter.Create(Input, Context.EffectiveStorage, Context.RomName, Context.SourceName);
      end, False, 'jaguar', '', $600000);
end;

class function TJaguarPlatform.RecognizeArchive(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  var Hint := Context.RomName.ToLower.Replace('\', '/');
  if (Context.Archive = nil) or not (Hint.Contains('/jaguar/') or
    Hint.Contains('/atarijaguar/') or Hint.Contains('/jag/')) then
    Exit;
  var Archive := Context.Archive;
  var Best := -1;
  var BestScore := Low(Integer);
  for var i := 0 to Archive.Count - 1 do
  begin
    if Archive.Entries[i].IsDirectory or (Archive.Entries[i].Size > $600000) then
      Continue;
    var Name := Archive.Entries[i].Name.ToLower;
    if not (Name.EndsWith('.j64') or Name.EndsWith('.bin') or Name.EndsWith('.rom')) then
      Continue;
    var Score := 0;
    if Name.EndsWith('.j64') then
      Inc(Score, 1000);
    if Name.Contains('[!]') then
      Inc(Score, 100);
    if Name.Contains('[b') or Name.Contains('[h') or Name.Contains('[o') then
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
  Archive.Read(Best, Data);
  Context.LoadArchiveEntry(Data, Archive.Entries[Best].Name);
  Result := Recognize(Context);
end;

class procedure TJaguarPlatform.LoadKeys(var Keys: TPlatformInputKeyMap);
begin
  var C := TJaguarConfig.Create('');
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

class procedure TJaguarPlatform.RegisterPlatform;
begin
  if FRegistered then
    Exit;
  TPlatformRegistry.RegisterPlatform('jaguar', 'Atari Jaguar', 'Jaguar', 'Atari',
    'Atari Jaguar', 'jaguar', ['jaguar', 'atarijaguar', 'jag'],
    ['.j64', '.bin', '.rom'], 'Jaguar', 'jaguar', 2);
  TPlatformRegistry.RegisterAlias('atarijaguar', 'jaguar');
  TPlatformRegistry.RegisterAlias('jag', 'jaguar');
  TPlatformRegistry.RegisterPlatform('jaguarcd', 'Atari Jaguar CD', 'Jaguar CD', 'Atari',
    'Atari Jaguar CD', 'jaguarcd', ['jaguarcd', 'jaguar-cd', 'atarijaguarcd'],
    ['.m3u', '.cue', '.chd', '.cdi', '.mds', '.nrg', '.ccd'], 'Jaguar', 'jaguar', 2);
  RegisterSnapshotPolicy('JAGUAR', TSnapshotPolicy.Create(2));
  var Registration := TEmulationCoreRegistration.Create('JAGUAR', ['.j64', '.bin', '.rom']);
  // Identify Jaguar's raw audio/data layout before the generic CDI and M3U
  // loaders and the Neo Geo CD fallback. CD extensions are shared by several systems.
  Registration.Add(TCoreLoadStage.Source, 5, Source);
  Registration.Add(TCoreLoadStage.Container, 6, RecognizeArchive);
  Registration.Add(TCoreLoadStage.Header, 100, Recognize);
  Registration.Add(TCoreLoadStage.OverrideHint, 6, Recognize);
  Registration.AddDiscPlatform('jaguarcd', LoadDisc);
  RegisterEmulationCore(Registration);
  RegisterSettingsProfile('Jaguar', TJaguarSettings);
  for var Id in ['jaguar', 'jaguarcd'] do
  begin
    RegisterPlatformSettingsDevices(Id, TJaguarSettingsDevices);
    RegisterPlatformDeviceCallouts(Id, TPlatformDeviceCallouts);
    RegisterPlatformControlsHelp(Id, TPlatformControlsHelp);
    RegisterPlatformSettingsHandler(Id, TPlatformSettingsHandler);
    RegisterPlatformWindowLayout(Id, TPlatformWindowLayout);
    RegisterPlatformSessionHandler(Id, TPlatformSessionHandler);
    RegisterPlatformInputHandler(Id, TJaguarInputHandler);
    RegisterPlatformGamepads(Id, TGamepadJaguar, []);
  // Console silhouette is a subject-specific image.
    RegisterPlatformPresentation(Id, 'jaguar',
      'M8,24 L88,24 L98,72 L2,72 Z M12,30 L84,30 L86,44 L10,44 Z ' +
      'M16,54 L30,54 L30,62 L16,62 Z M40,54 L48,54 L48,62 L40,62 Z M58,54 L66,54 L66,62 L58,62 Z');
    var Definition := TPlatformInputDefinition.Create([TEmulatorButton.Up, TEmulatorButton.Down,
        TEmulatorButton.Left, TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B,
        TEmulatorButton.C, TEmulatorButton.Start, TEmulatorButton.Select,
        TEmulatorButton.X, TEmulatorButton.Y, TEmulatorButton.Z]);
    Definition.ButtonNames[TEmulatorButton.A] := 'A';
    Definition.ButtonNames[TEmulatorButton.B] := 'B';
    Definition.ButtonNames[TEmulatorButton.C] := 'C';
    Definition.ButtonNames[TEmulatorButton.Start] := 'Pause';
    Definition.ButtonNames[TEmulatorButton.Select] := 'Option';
    Definition.LegacyPorts := 2;
    Definition.LegacySection := 'Keys';
    Definition.AfterLegacyBindings := LoadJaguarLegacyBindings;
    Definition.AfterLoadBindings := MigrateJaguarBindings;
    Definition.FilterBinding := FilterJaguarBinding;
    Definition.UseSharedBindingRules := True;
    Definition.LoadLegacyKeys := LoadKeys;
    RegisterPlatformInput(Id, Definition);
  end;
  FRegistered := True;
end;

end.

