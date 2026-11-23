unit RM.Platforms.NeoGeo;

interface

uses
  FMXInput, Core.EmulatorRegistry, RM.Input, System.SysUtils;

type
  TNeoGeoPlatform = class
  strict private
    class function LoadDisc(Context: TCoreLoadContext): TCoreMatch; static;
    class var
      FRegistered: Boolean;
    class function Header(Context: TCoreLoadContext): TCoreMatch; static;
    class function Container(Context: TCoreLoadContext): TCoreMatch; static;
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
  RM.Input.Gamepads, NeoGeo.Cartridge, NeoGeo.RomSets, Core.Archive.Container,
  RM.Settings.Catalog, Core.Snapshots, System.StrUtils, Core.Emulation,
  Core.Platforms, Core.Platforms.NeoGeo.Adapter, RM.Platforms.NeoGeo.Settings,
  RM.Platforms.Presentation, RM.Gamepad.Factory, RM.Platforms.NeoGeo.Gamepads,
  RM.Input.Runtime, RM.Session.Runtime, RM.Window.Layout, RM.Settings.Runtime,
  RM.ControlsHelp.Content, RM.Settings.Callouts, RM.Settings.Devices,
  System.Classes;

const
  PlatformIcon =
 'M35.8400001525879,47.1809997558594 C35.8400001525879,50.955867767334 32.7798652648926,54.015998840332 29.00499' +
    '91607666,54.015998840332 C25.2301330566406,54.015998840332 22.1699981689453,50.955867767334 22.1699981689453,4' +
    '7.1809997558594 C22.1699981689453,43.4061317443848 25.2301330566406,40.3460006713867 29.0049991607666,40.34600' +
    '06713867 C32.7798652648926,40.3460006713867 35.8400001525879,43.4061317443848 35.8400001525879,47.180999755859' +
    '4 Z M85.495002746582,42.5149993896484 C80.6590042114258,31.9629993438721 70.495002746582,29.5149993896484 65.4' +
    '95002746582,31.681999206543 C60.5190010070801,33.8380012512207 50.101001739502,34.8479995727539 50,34.84799957' +
    '27539 C49.9000015258789,34.8479995727539 39.4809989929199,33.8380012512207 34.5050010681152,31.6809997558594 C' +
    '29.5050010681152,29.5139999389648 19.3410015106201,31.9629993438721 14.5050010681152,42.5139999389648 C9.00500' +
    '106811523,54.5139999389648 10.0050010681152,71.0130004882813 25.5050010681152,68.8470001220703 C40.91899871826' +
    '17,66.693000793457 49.8970031738281,67.338996887207 49.9960021972656,67.3460006713867 L49.9960021972656,67.347' +
    '0001220703 L50,67.3470001220703 C50,67.3470001220703 50.0050010681152,67.3470001220703 50.0050010681152,67.347' +
    '0001220703 L50.0050010681152,67.3460006713867 C50.1040000915527,67.338996887207 59.0810012817383,66.6930007934' +
    '57 74.495002746582,68.8470001220703 C89.995002746582,71.0139999389648 90.995002746582,54.5149993896484 85.4950' +
    '02746582,42.5149993896484 Z M29.0049991607666,56.3740005493164 C23.92799949646,56.3740005493164 19.81299972534' +
    '18,52.257999420166 19.8129997253418,47.181999206543 C19.8129997253418,42.1049995422363 23.9290008544922,37.989' +
    '9978637695 29.0050010681152,37.9899978637695 C34.0810012817383,37.9899978637695 38.1970024108887,42.1059989929' +
    '199 38.1970024108887,47.181999206543 C38.1969985961914,52.257999420166 34.0820007324219,56.3740005493164 29.00' +
    '49991607666,56.3740005493164 Z M51.0530014038086,58.806999206543 C49.2150001525879,59.8369979858398 47.4700012' +
    '207031,60.2150001525879 47.1560020446777,59.6549987792969 C46.8420028686523,59.0929985046387 48.076000213623,5' +
    '7.8019981384277 49.9140014648438,56.7729988098145 C51.7510032653809,55.7430000305176 53.4960021972656,55.36399' +
    '84130859 53.810001373291,55.9249992370605 C54.125,56.4860000610352 52.890998840332,57.7760009765625 51.0530014' +
    '038086,58.806999206543 Z M52.273998260498,49.5379981994629 C50.4359970092773,50.5679969787598 48.6909980773926' +
    ',50.9459991455078 48.3769989013672,50.3849983215332 C48.0629997253418,49.8239974975586 49.2969970703125,48.532' +
    '9971313477 51.1349983215332,47.5039978027344 C52.9729995727539,46.4739990234375 54.7169990539551,46.0949974060' +
    '059 55.0309982299805,46.6559982299805 C55.3470001220703,47.2179985046387 54.1119995117188,48.507999420166 52.2' +
    '73998260498,49.5379981994629 Z M59.5130004882813,45.523998260498 C59.5130004882813,43.3109970092773 61.3079986' +
    '572266,41.515998840332 63.5209999084473,41.515998840332 C65.734001159668,41.515998840332 67.5270004272461,43.3' +
    '109970092773 67.5270004272461,45.523998260498 C67.5270004272461,47.7369995117188 65.734001159668,49.5319976806' +
    '641 63.5209999084473,49.5319976806641 C61.3079986572266,49.5319976806641 59.5130004882813,47.7369995117188 59.' +
    '5130004882813,45.523998260498 Z M68.6650009155273,58.0149993896484 C66.4520034790039,58.0149993896484 64.65699' +
    '76806641,56.2200012207031 64.6569976806641,54.0069999694824 C64.6569976806641,51.7939987182617 66.452003479003' +
    '9,50 68.6650009155273,50 C70.8779983520508,50 72.6709976196289,51.7939987182617 72.6709976196289,54.0069999694' +
    '824 C72.6709976196289,56.2200012207031 70.8779983520508,58.0149993896484 68.6650009155273,58.0149993896484 Z M' +
    '68.6650009155273,40.5149993896484 C68.6650009155273,38.3019981384277 70.4589996337891,36.507999420166 72.67199' +
    '70703125,36.507999420166 C74.8849945068359,36.507999420166 76.6790008544922,38.3019981384277 76.6790008544922,' +
    '40.5149993896484 C76.6790008544922,42.7280006408691 74.8850021362305,44.5219993591309 72.6719970703125,44.5219' +
    '993591309 C70.4589920043945,44.5219993591309 68.6650009155273,42.7280006408691 68.6650009155273,40.51499938964' +
    '84 Z M78.1360015869141,54.007999420166 C75.9230041503906,54.007999420166 74.1300048828125,52.2130012512207 74.' +
    '1300048828125,50 C74.1300048828125,47.7869987487793 75.9230041503906,45.992000579834 78.1360015869141,45.99200' +
    '0579834 C80.3489990234375,45.992000579834 82.1440048217773,47.7869987487793 82.1440048217773,50 C82.1440048217' +
    '773,52.2130012512207 80.3489990234375,54.007999420166 78.1360015869141,54.007999420166 Z ';
  PlatformIconNEOGEOCD =
    'M35.8400001525879,47.1809997558594 C35.8400001525879,50.955867767334 32.7798652648926,54.015998840332 29.00499' +
    '91607666,54.015998840332 C25.2301330566406,54.015998840332 22.1699981689453,50.955867767334 22.1699981689453,4' +
    '7.1809997558594 C22.1699981689453,43.4061317443848 25.2301330566406,40.3460006713867 29.0049991607666,40.34600' +
    '06713867 C32.7798652648926,40.3460006713867 35.8400001525879,43.4061317443848 35.8400001525879,47.180999755859' +
    '4 Z M85.495002746582,42.5149993896484 C80.6590042114258,31.9629993438721 70.495002746582,29.5149993896484 65.4' +
    '95002746582,31.681999206543 C60.5190010070801,33.8380012512207 50.101001739502,34.8479995727539 50,34.84799957' +
    '27539 C49.9000015258789,34.8479995727539 39.4809989929199,33.8380012512207 34.5050010681152,31.6809997558594 C' +
    '29.5050010681152,29.5139999389648 19.3410015106201,31.9629993438721 14.5050010681152,42.5139999389648 C9.00500' +
    '106811523,54.5139999389648 10.0050010681152,71.0130004882813 25.5050010681152,68.8470001220703 C40.91899871826' +
    '17,66.693000793457 49.8970031738281,67.338996887207 49.9960021972656,67.3460006713867 L49.9960021972656,67.347' +
    '0001220703 L50,67.3470001220703 C50,67.3470001220703 50.0050010681152,67.3470001220703 50.0050010681152,67.347' +
    '0001220703 L50.0050010681152,67.3460006713867 C50.1040000915527,67.338996887207 59.0810012817383,66.6930007934' +
    '57 74.495002746582,68.8470001220703 C89.995002746582,71.0139999389648 90.995002746582,54.5149993896484 85.4950' +
    '02746582,42.5149993896484 Z M29.0049991607666,56.3740005493164 C23.92799949646,56.3740005493164 19.81299972534' +
    '18,52.257999420166 19.8129997253418,47.181999206543 C19.8129997253418,42.1049995422363 23.9290008544922,37.989' +
    '9978637695 29.0050010681152,37.9899978637695 C34.0810012817383,37.9899978637695 38.1970024108887,42.1059989929' +
    '199 38.1970024108887,47.181999206543 C38.1969985961914,52.257999420166 34.0820007324219,56.3740005493164 29.00' +
    '49991607666,56.3740005493164 Z M51.0530014038086,58.806999206543 C49.2150001525879,59.8369979858398 47.4700012' +
    '207031,60.2150001525879 47.1560020446777,59.6549987792969 C46.8420028686523,59.0929985046387 48.076000213623,5' +
    '7.8019981384277 49.9140014648438,56.7729988098145 C51.7510032653809,55.7430000305176 53.4960021972656,55.36399' +
    '84130859 53.810001373291,55.9249992370605 C54.125,56.4860000610352 52.890998840332,57.7760009765625 51.0530014' +
    '038086,58.806999206543 Z M52.273998260498,49.5379981994629 C50.4359970092773,50.5679969787598 48.6909980773926' +
    ',50.9459991455078 48.3769989013672,50.3849983215332 C48.0629997253418,49.8239974975586 49.2969970703125,48.532' +
    '9971313477 51.1349983215332,47.5039978027344 C52.9729995727539,46.4739990234375 54.7169990539551,46.0949974060' +
    '059 55.0309982299805,46.6559982299805 C55.3470001220703,47.2179985046387 54.1119995117188,48.507999420166 52.2' +
    '73998260498,49.5379981994629 Z M59.5130004882813,45.523998260498 C59.5130004882813,43.3109970092773 61.3079986' +
    '572266,41.515998840332 63.5209999084473,41.515998840332 C65.734001159668,41.515998840332 67.5270004272461,43.3' +
    '109970092773 67.5270004272461,45.523998260498 C67.5270004272461,47.7369995117188 65.734001159668,49.5319976806' +
    '641 63.5209999084473,49.5319976806641 C61.3079986572266,49.5319976806641 59.5130004882813,47.7369995117188 59.' +
    '5130004882813,45.523998260498 Z M68.6650009155273,58.0149993896484 C66.4520034790039,58.0149993896484 64.65699' +
    '76806641,56.2200012207031 64.6569976806641,54.0069999694824 C64.6569976806641,51.7939987182617 66.452003479003' +
    '9,50 68.6650009155273,50 C70.8779983520508,50 72.6709976196289,51.7939987182617 72.6709976196289,54.0069999694' +
    '824 C72.6709976196289,56.2200012207031 70.8779983520508,58.0149993896484 68.6650009155273,58.0149993896484 Z M' +
    '68.6650009155273,40.5149993896484 C68.6650009155273,38.3019981384277 70.4589996337891,36.507999420166 72.67199' +
    '70703125,36.507999420166 C74.8849945068359,36.507999420166 76.6790008544922,38.3019981384277 76.6790008544922,' +
    '40.5149993896484 C76.6790008544922,42.7280006408691 74.8850021362305,44.5219993591309 72.6719970703125,44.5219' +
    '993591309 C70.4589920043945,44.5219993591309 68.6650009155273,42.7280006408691 68.6650009155273,40.51499938964' +
    '84 Z M78.1360015869141,54.007999420166 C75.9230041503906,54.007999420166 74.1300048828125,52.2130012512207 74.' +
    '1300048828125,50 C74.1300048828125,47.7869987487793 75.9230041503906,45.992000579834 78.1360015869141,45.99200' +
    '0579834 C80.3489990234375,45.992000579834 82.1440048217773,47.7869987487793 82.1440048217773,50 C82.1440048217' +
    '773,52.2130012512207 80.3489990234375,54.007999420166 78.1360015869141,54.007999420166 Z ';

class procedure TNeoGeoPlatform.LoadGamepadPreset(Input: TInputManager; Port: Integer);
begin
  for var Direction := TEmulatorButton.Up to TEmulatorButton.Right do
    AddStandardDirection(Input, Port, PadAction(Port, Direction), Ord(Direction), True);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.A), TGamepadButton.West);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.B), TGamepadButton.South);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.Select), TGamepadButton.Select);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.Start), TGamepadButton.Start);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.C), TGamepadButton.North);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.X), TGamepadButton.East);
end;

class function TNeoGeoPlatform.LoadDisc(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := TCoreMatch.Create('NeoGeoCD',
    function: IEmulationCore
    begin
      Context.Stream.Position := 0;
      Result := TNeoGeoCoreAdapter.Create(Context.Stream, Context.EffectiveStorage, Context.RomName, True);
    end);
  Result.Format.SystemId := 'neogeocd';
end;

class function TNeoGeoPlatform.Header(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  if Context.Signature(0, NEOGEO_ROM_SIGNATURE) then
  begin
    Result := ImageMatch(Context, 'NeoGeo',
      function(const Data: TBytes; Input: TStream): IEmulationCore
      begin
        Result := TNeoGeoCoreAdapter.Create(Input, Context.Storage, Context.RomName);
      end, True, 'neogeo', '', 0);
  end;
end;

class function TNeoGeoPlatform.Container(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  if (Context.Archive = nil) then
    Exit;
  var Archive := Context.Archive;
  try
    var CRCs: TArray<string>;
    SetLength(CRCs, Archive.Count);
    for var i := 0 to Archive.Count - 1 do
      CRCs[i] := IntToHex(Archive.Checksum(i), 8);
    var SetName := ChangeFileExt(ExtractFileName(Context.RomName), '').ToLower;
    var Description := SelectNeoGeoSet(SetName, CRCs);
    if Description = '' then
      Description := SelectNeoGeoSet(IdentifyNeoGeoSet(Archive.Names), CRCs);
    if Description = '' then
      Exit;
    // A named split set can contain only graphics. Verify a chip checksum
    // and let the cartridge loader check its parent archives for the program.
    var Parts := Description.Split(['|']);
    var NamedSet := SameText(Parts[0], SetName);
    for var Row in Parts[9].Split([';']) do
    begin
      var Fields := Row.Split([',']);
      if (Length(Fields) <> 7) or (not NamedSet and (Fields[0] <> 'P')) then
        Continue;
      if not MatchText(Fields[6], CRCs) then
        Continue;
      Result := TCoreMatch.Create('NeoGeo',
        function: IEmulationCore
        begin
          Context.Stream.Position := 0;
          try
            Result := TNeoGeoCoreAdapter.Create(Context.Stream, Context.Storage, Context.RomName);
          except
            on E: ENeoGeoIncompleteSet do
              raise ECoreInvalidMedia.Create(E.Message);
          end;
        end);
      Result.ArchiveCandidate := False;
      Exit;
    end;
  finally
    Archive := nil;
  end;
end;

class function TNeoGeoPlatform.Disc(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  if Context.IsDiscSource and not Context.Disc.Track(1).Audio and
    (Length(Context.Disc.ReadISOFile('IPL.TXT', 65536)) > 0) then
    Result := LoadDisc(Context);
end;

class procedure TNeoGeoPlatform.RegisterPlatforms;
begin
  TPlatformRegistry.RegisterPlatform('neogeo', 'Neo Geo', 'NG',
    'SNK', 'NG NeoGeo MVS AES Advanced Entertainment System', 'neogeo', ['neogeo', 'neogeoaes', 'aes'],
    ['.neo'],
    'NeoGeo', 'neogeo', 2);
  TPlatformRegistry.RegisterPlatform('neogeocd', 'Neo Geo CD', 'NG CD',
    'SNK', 'NG NeoGeo CD', 'neogeocd', ['neogeocd'],
    ['.cue', '.iso', '.chd', '.mds', '.nrg'],
    'NeoGeo', 'neogeocd', 2);
  TPlatformRegistry.RegisterAlias('neogeoaes', 'neogeo');
  TPlatformRegistry.RegisterAlias('aes', 'neogeo');
end;

class procedure TNeoGeoPlatform.RegisterCore;
begin
  RegisterPlatforms;
  var Registration := TEmulationCoreRegistration.Create('NeoGeo', ['.neo']);
  Registration.Add(TCoreLoadStage.Header, 80, Header);
  Registration.Add(TCoreLoadStage.Container, 30, Container);
  Registration.Add(TCoreLoadStage.Source, 100, Disc);
  Registration.AddDiscPlatform('neogeocd', LoadDisc);
  RegisterEmulationCore(Registration);
end;

class procedure TNeoGeoPlatform.RegisterServices;
begin
  RegisterSnapshotPolicy('NEOGEO', TSnapshotPolicy.Create(4));
  RegisterSnapshotPolicy('NEOGEOCD', TSnapshotPolicy.Create(3));
end;

class procedure TNeoGeoPlatform.LoadLegacyKeys(var Keys: TPlatformInputKeyMap);
var
  Config: IEmulatorConfig;
begin
  var C := TNeoGeoConfig.Create('');
  Config := C;
  for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
  begin
    Keys[0, B] := C.Keys[B];
    Keys[1, B] := C.Keys2[B];
  end;
end;

class procedure TNeoGeoPlatform.RegisterInput;
begin
  var Definition := TPlatformInputDefinition.Create([TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left,
      TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.Select, TEmulatorButton.Start,
      TEmulatorButton.C, TEmulatorButton.X]);
  Definition.ButtonNames[TEmulatorButton.X] := 'D';
  Definition.LegacyPorts := 2;
  Definition.LegacySection := 'Keys';
  Definition.AfterLegacyBindings := LoadSharedLegacyBindings;
  Definition.UseSharedBindingRules := True;
  Definition.LoadLegacyKeys := LoadLegacyKeys;
  Definition.LegacyKeyNames[TEmulatorButton.X] := 'D';
  Definition.LoadGamepadPreset := LoadGamepadPreset;
  RegisterPlatformInput('neogeo', Definition);
  RegisterPlatformInput('neogeoaes', Definition);
  RegisterPlatformInput('neogeocd', Definition);
end;

class procedure TNeoGeoPlatform.RegisterClient;
begin
  RegisterSettingsProfile('NeoGeo', TNeoGeoSettings,
    'Cartridge systems use named arcade sets or supported unencrypted .neo images. Neo Geo CD ' +
    'uses disc images and has its own library folder. Machine and region settings affect how ' +
    'the BIOS starts the game.');
  RegisterPlatformSettingsDevices('neogeo', TPlatformSettingsDevices);
  RegisterPlatformSettingsDevices('neogeoaes', TPlatformSettingsDevices);
  RegisterPlatformSettingsDevices('neogeocd', TPlatformSettingsDevices);
  RegisterPlatformDeviceCallouts('neogeo', TPlatformDeviceCallouts);
  RegisterPlatformDeviceCallouts('neogeoaes', TPlatformDeviceCallouts);
  RegisterPlatformDeviceCallouts('neogeocd', TPlatformDeviceCallouts);
  RegisterPlatformControlsHelp('neogeo', TPlatformControlsHelp);
  RegisterPlatformControlsHelp('neogeoaes', TPlatformControlsHelp);
  RegisterPlatformControlsHelp('neogeocd', TPlatformControlsHelp);
  RegisterPlatformSettingsHandler('neogeo', TPlatformSettingsHandler);
  RegisterPlatformSettingsHandler('neogeoaes', TPlatformSettingsHandler);
  RegisterPlatformSettingsHandler('neogeocd', TPlatformSettingsHandler);
  RegisterPlatformWindowLayout('neogeo', TPlatformWindowLayout);
  RegisterPlatformWindowLayout('neogeoaes', TPlatformWindowLayout);
  RegisterPlatformWindowLayout('neogeocd', TPlatformWindowLayout);
  RegisterPlatformSessionHandler('neogeo', TPlatformSessionHandler);
  RegisterPlatformSessionHandler('neogeoaes', TPlatformSessionHandler);
  RegisterPlatformSessionHandler('neogeocd', TPlatformSessionHandler);
  RegisterPlatformInputHandler('neogeo', TPlatformInputHandler);
  RegisterPlatformInputHandler('neogeoaes', TPlatformInputHandler);
  RegisterPlatformInputHandler('neogeocd', TPlatformInputHandler);
  RegisterInput;
  RegisterPlatformGamepads('neogeo', TGamepadNeoGeoArcade, []);
  RegisterPlatformGamepads('neogeoaes', TGamepadNeoGeoAES, []);
  RegisterPlatformGamepads('neogeocd', TGamepadNeoGeoCD, []);
  RegisterPlatformPresentation('neogeo', 'neogeo', PlatformIcon);
  RegisterPlatformPresentation('neogeocd', 'neogeocd', PlatformIconNEOGEOCD);
end;

class procedure TNeoGeoPlatform.RegisterPlatform;
begin
  if FRegistered then
    Exit;
  RegisterServices;
  RegisterCore;
  RegisterClient;
  FRegistered := True;
end;

end.

