unit RM.Platforms.NES;

interface

uses
  FMXInput, Core.EmulatorRegistry, RM.Input, System.SysUtils;

type
  TNESPlatform = class
  strict private
    class var
      FRegistered: Boolean;
    class function RecognizeStream(Context: TCoreLoadContext): TCoreMatch; static;
    class function Recognize(Context: TCoreLoadContext): TCoreMatch; static;
    class procedure RegisterPlatforms; static;
    class procedure RegisterCore; static;
    class procedure RegisterRuntimeServices; static;
    class procedure LoadLegacyKeys(var Keys: TPlatformInputKeyMap); static;
    class procedure RegisterInput; static;
    class procedure RegisterClient; static;
    class procedure LoadGamepadPreset(Input: TInputManager; Port: Integer); static;
  public
    class procedure RegisterPlatform; static;
  end;

implementation

uses
  RM.Input.Gamepads, NES.Cartridge, NES.DiskSystem, NES.StudyBox.Media,
  RM.Settings.Catalog, Core.InputConfig, System.IniFiles, Core.PlatformServices,
  System.StrUtils, Core.Emulation, Core.Platforms, Core.Platforms.NES.Adapter,
  RM.Platforms.NES.Settings, RM.Platforms.Presentation, RM.Gamepad.Factory,
  RM.Platforms.NES.Gamepads, NES.Controller, NES.Types, RM.Input.Runtime,
  RM.Platforms.NES.Input, RM.Session.Runtime, RM.Platforms.NES.Session,
  RM.Window.Layout, RM.Platforms.NES.Window, RM.Settings.Runtime,
  RM.Platforms.NES.SettingsHandler, RM.ControlsHelp.Content,
  RM.Platforms.NES.Help, RM.Settings.Callouts, RM.Platforms.NES.Devices,
  RM.Settings.Devices, System.Classes;

const
  PlatformIcon =
 'M77.6119995117187,58.6669998168945 C77.6119995117187,60.8148345947266 75.8708343505859,62.5559997558594 73.722' +
    '9995727539,62.5559997558594 C71.5751647949219,62.5559997558594 69.8339996337891,60.8148345947266 69.8339996337' +
    '891,58.6669998168945 C69.8339996337891,56.5191650390625 71.5751647949219,54.7779998779297 73.7229995727539,54.' +
    '7779998779297 C75.8708343505859,54.7779998779297 77.6119995117187,56.5191650390625 77.6119995117187,58.6669998' +
    '168945 Z M89.9459991455078,58.6669998168945 C89.9459991455078,60.8148345947266 88.204833984375,62.555999755859' +
    '4 86.056999206543,62.5559997558594 C83.9091644287109,62.5559997558594 82.1679992675781,60.8148345947266 82.167' +
    '9992675781,58.6669998168945 C82.1679992675781,56.5191650390625 83.9091644287109,54.7779998779297 86.0569992065' +
    '43,54.7779998779297 C88.204833984375,54.7779998779297 89.9459991455078,56.5191650390625 89.9459991455078,58.66' +
    '69998168945 Z M95.3339996337891,29.75 L4.66699981689453,29.75 C3.5629997253418,29.75 2.66699981689453,30.64599' +
    '99084473 2.66699981689453,31.75 L2.66699981689453,68.25 C2.66699981689453,69.3539962768555 3.5629997253418,70.' +
    '25 4.66699981689453,70.25 L95.3339996337891,70.25 C96.4379959106445,70.25 97.3339996337891,69.3539962768555 97' +
    '.3339996337891,68.25 L97.3339996337891,31.75 C97.3339996337891,30.6459999084473 96.4380035400391,29.75 95.3339' +
    '996337891,29.75 Z M28.8470001220703,56.4020004272461 C28.8470001220703,56.9519996643066 28.3969993591309,57.40' +
    '20004272461 27.8470001220703,57.4020004272461 L24.6949996948242,57.4020004272461 C24.1450004577637,57.40200042' +
    '72461 23.6949996948242,57.8520011901855 23.6949996948242,58.4020004272461 L23.6949996948242,61.5550003051758 C' +
    '23.6949996948242,62.1049995422363 23.2449989318848,62.5550003051758 22.6949996948242,62.5550003051758 L18.1949' +
    '996948242,62.5550003051758 C17.6450004577637,62.5550003051758 17.1949996948242,62.1049995422363 17.19499969482' +
    '42,61.5550003051758 L17.1949996948242,58.4020004272461 C17.1949996948242,57.8520011901855 16.7449989318848,57.' +
    '4020004272461 16.1949996948242,57.4020004272461 L13.0429992675781,57.4020004272461 C12.4929990768433,57.402000' +
    '4272461 12.0429992675781,56.9519996643066 12.0429992675781,56.4020004272461 L12.0429992675781,51.9029998779297' +
    ' C12.0429992675781,51.3530006408691 12.4929990768433,50.9029998779297 13.0429992675781,50.9029998779297 L16.19' +
    '49996948242,50.9029998779297 C16.7449989318848,50.9029998779297 17.1949996948242,50.4529991149902 17.194999694' +
    '8242,49.9029998779297 L17.1949996948242,46.75 C17.1949996948242,46.2000007629395 17.6450004577637,45.75 18.194' +
    '9996948242,45.75 L22.6949996948242,45.75 C23.2449989318848,45.75 23.6949996948242,46.2000007629395 23.69499969' +
    '48242,46.75 L23.6949996948242,49.9029998779297 C23.6949996948242,50.4529991149902 24.1450004577637,50.90299987' +
    '79297 24.6949996948242,50.9029998779297 L27.8470001220703,50.9029998779297 C28.3969993591309,50.9029998779297 ' +
    '28.8470001220703,51.3530006408691 28.8470001220703,51.9029998779297 L28.8470001220703,56.4020004272461 Z M63.2' +
    '5,62.25 C63.25,63.3540000915527 62.3540000915527,64.25 61.25,64.25 L38.75,64.25 C37.6459999084473,64.25 36.75,' +
    '63.3540000915527 36.75,62.25 L36.75,55.0839996337891 C36.75,53.9799995422363 37.6459999084473,53.0839996337891' +
    ' 38.75,53.0839996337891 L61.25,53.0839996337891 C62.3540000915527,53.0839996337891 63.25,53.9799995422363 63.2' +
    '5,55.0839996337891 L63.25,62.25 Z M79.1389999389648,62.25 C79.1389999389648,63.3540000915527 78.2440032958984,' +
    '64.25 77.1389999389648,64.25 L70.306999206543,64.25 C69.2019958496094,64.25 68.306999206543,63.3540000915527 6' +
    '8.306999206543,62.25 L68.306999206543,55.0839996337891 C68.306999206543,53.9799995422363 69.2019958496094,53.0' +
    '839996337891 70.306999206543,53.0839996337891 L77.1389999389648,53.0839996337891 C78.2440032958984,53.08399963' +
    '37891 79.1389999389648,53.9799995422363 79.1389999389648,55.0839996337891 L79.1389999389648,62.25 Z M91.472999' +
    '5727539,62.25 C91.4729995727539,63.3540000915527 90.5769958496094,64.25 89.4729995727539,64.25 L82.63899993896' +
    '48,64.25 C81.5350036621094,64.25 80.6389999389648,63.3540000915527 80.6389999389648,62.25 L80.6389999389648,55' +
    '.0839996337891 C80.6389999389648,53.9799995422363 81.5350036621094,53.0839996337891 82.6389999389648,53.083999' +
    '6337891 L89.4729995727539,53.0839996337891 C90.5769958496094,53.0839996337891 91.4729995727539,53.979999542236' +
    '3 91.4729995727539,55.0839996337891 L91.4729995727539,62.25 Z M45.9169998168945,57.0839996337891 L41.583000183' +
    '1055,57.0839996337891 C40.7080001831055,57.0839996337891 40,57.7929992675781 40,58.6669998168945 C40,59.541000' +
    '3662109 40.7080001831055,60.25 41.5830001831055,60.25 L45.9169998168945,60.25 C46.7919998168945,60.25 47.5,59.' +
    '5410003662109 47.5,58.6669998168945 C47.5,57.7929992675781 46.7910003662109,57.0839996337891 45.9169998168945,' +
    '57.0839996337891 Z M58.4179992675781,57.0839996337891 L54.0839996337891,57.0839996337891 C53.2089996337891,57.' +
    '0839996337891 52.5,57.7929992675781 52.5,58.6669998168945 C52.5,59.5410003662109 53.2089996337891,60.25 54.083' +
    '9996337891,60.25 L58.4179992675781,60.25 C59.2910003662109,60.25 60,59.5410003662109 60,58.6669998168945 C60,5' +
    '7.7929992675781 59.2910003662109,57.0839996337891 58.4179992675781,57.0839996337891 Z ';

class procedure TNESPlatform.LoadGamepadPreset(Input: TInputManager; Port: Integer);
begin
  for var Direction := TEmulatorButton.Up to TEmulatorButton.Right do
    AddStandardDirection(Input, Port, PadAction(Port, Direction), Ord(Direction), True);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.A), TGamepadButton.East);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.B), TGamepadButton.South);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.Select), TGamepadButton.Select);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.Start), TGamepadButton.Start);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.X), TGamepadButton.West);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.Y), TGamepadButton.North);
end;

class function TNESPlatform.RecognizeStream(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  var FileSize := Context.Stream.Size;
  var Prefix := Context.Prefix(NES_ROM_HEADER_SIZE);
  var StudyBox := (FileSize <= STUDY_BOX_MAX_SIZE) and (Length(Prefix) >= Length(STUDY_BOX_SIGNATURE)) and
    CompareMem(@Prefix[0], PAnsiChar(STUDY_BOX_SIGNATURE), Length(STUDY_BOX_SIGNATURE));
  if not StudyBox and not IsLargeNesImage(Prefix, FileSize) then
    Exit;

  Result := TCoreMatch.Create('NES',
    function: IEmulationCore
    begin
      Context.Stream.Position := 0;
      Result := TNesCoreAdapter.Create(Context.Stream, Context.Storage, Context.RomName);
    end);
  Result.Format.SystemId := 'nes';
end;

class function TNESPlatform.Recognize(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;

  var DiskImage := Context.Signature(0, FDS_SIGNATURE) or
    Context.Signature(0, #1'*NINTENDO-HVC*') or Context.HasExtension(['.fds', '.qd']);
  if Context.Signature(0, NES_ROM_SIGNATURE) or DiskImage or Context.HasExtension(['.fcn']) then
  begin
    var SystemId := 'nes';
    if DiskImage then
      SystemId := 'fds';
    Result := ImageMatch(Context, 'NES',
      function(const Data: TBytes; Input: TStream): IEmulationCore
      begin
        Result := TNesCoreAdapter.Create(Input, Context.Storage, Context.RomName);
      end, True, SystemId, '', NES_ROM_FILE_MAX_SIZE);
  end;
end;

class procedure TNESPlatform.RegisterPlatforms;
begin
  TPlatformRegistry.RegisterPlatform('nes', 'NES / Famicom', 'NES',
    'Nintendo', 'NES Famicom Dendy Disk System FDS', 'nes', ['nes'],
    ['.nes', '.fds', '.qd', '.study', '.studybox', '.stbx', '.fcn'], 'NES', 'nes', 2);
  TPlatformRegistry.RegisterPlatform('fds', 'Famicom Disk System', 'FDS',
    'Nintendo', 'FDS Famicom Disk System Twin Famicom', 'fds', ['fds', 'famicomdisksystem'],
    ['.fds', '.qd'], 'NES', 'nes', 2);
end;

class procedure TNESPlatform.RegisterCore;
begin
  RegisterPlatforms;
  var Registration := TEmulationCoreRegistration.Create('NES', ['.nes', '.fds', '.qd', '.study', '.studybox', '.stbx', '.fcn']);
  Registration.MaxArchiveImageSize := NES_ROM_LARGE_MAX_SIZE;
  Registration.Add(TCoreLoadStage.Stream, 100, RecognizeStream);
  Registration.Add(TCoreLoadStage.Header, 100, Recognize);
  RegisterEmulationCore(Registration);
end;

class procedure TNESPlatform.RegisterRuntimeServices;
begin
  var Service := Default(TPlatformServices);
  Service.UnprefixedSaveIdentity := True;
  Service.DocumentSelection.Title := 'Choose a cassette file';
  Service.DocumentSelection.FileFilter := 'Cassette (*.tape)|*.tape|All files|*.*';
  Service.DocumentSelection.AllowedExtensions := ['.tape'];
  RegisterPlatformServices('nes', Service);
  Service.DocumentSelection.Title := 'Choose FDS disk image';
  Service.DocumentSelection.FileFilter := 'NES disk images (*.fds;*.qd;*.img;*.ima)|*.fds;*.qd;*.img;*.ima|All files|*.*';
  Service.DocumentSelection.AllowedExtensions := ['.fds', '.qd'];
  RegisterPlatformServices('fds', Service);
end;

class procedure TNESPlatform.LoadLegacyKeys(var Keys: TPlatformInputKeyMap);
var
  Config: IEmulatorConfig;

  procedure CopyNES(Port: Integer; const Map: TKeyMap);
  begin
    Keys[Port, TEmulatorButton.A] := Map.A;
    Keys[Port, TEmulatorButton.B] := Map.B;
    Keys[Port, TEmulatorButton.Select] := Map.Select;
    Keys[Port, TEmulatorButton.Start] := Map.Start;
    Keys[Port, TEmulatorButton.Up] := Map.Up;
    Keys[Port, TEmulatorButton.Down] := Map.Down;
    Keys[Port, TEmulatorButton.Left] := Map.Left;
    Keys[Port, TEmulatorButton.Right] := Map.Right;
  end;

begin
  var C := TNesEmulatorConfig.Create('');
  Config := C;
  CopyNES(0, C.GetKeys);
  CopyNES(1, C.GetKeys2);
  CopyNES(2, C.GetKeys3);
  CopyNES(3, C.GetKeys4);
end;

class procedure TNESPlatform.RegisterInput;
begin
  var Definition := TPlatformInputDefinition.Create([TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left,
      TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.Select, TEmulatorButton.Start]);
  Definition.Devices := TArray<TInputDeviceVariant>.Create(TInputDeviceVariant.Create('paddendy',
      [TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left, TEmulatorButton.Right, TEmulatorButton.A,
        TEmulatorButton.B, TEmulatorButton.Select, TEmulatorButton.Start, TEmulatorButton.X, TEmulatorButton.Y]));
  Definition.ButtonNames[TEmulatorButton.X] := 'Turbo B';
  Definition.ButtonNames[TEmulatorButton.Y] := 'Turbo A';
  Definition.LegacyPorts := 4;
  Definition.LegacySection := 'Controls';
  Definition.AfterLegacyBindings := LoadSharedLegacyBindings;
  Definition.UseSharedBindingRules := True;
  Definition.LoadLegacyKeys := LoadLegacyKeys;
  Definition.LegacyKeyNames[TEmulatorButton.X] := 'Turbo B';
  Definition.LegacyKeyNames[TEmulatorButton.Y] := 'Turbo A';
  Definition.AfterLoadBindings := EnsurePeripheralBindings;
  Definition.SharedLegacyBindings := LoadNesLegacyAuxiliaries;
  Definition.SharedFilterBinding := FilterNesCompatibilityBinding;
  Definition.SharedBindingOrder := 10;
  Definition.LoadGamepadPreset := LoadGamepadPreset;
  RegisterPlatformInput('nes', Definition);
end;

class procedure TNESPlatform.RegisterClient;
begin
  RegisterSettingsProfile('NES', TNESSettings,
    'Choose the NES folder for .nes cartridges and Famicom Disk System for .fds or .qd disks. ' +
    'Keep the region on Automatic unless a game needs a specific region. Choose the device for ' +
    'each port in Peripherals. Four Score and devices such as Zapper, Power Pad and Miracle ' +
    'Piano use conflicting port wiring.');
  RegisterPlatformSettingsDevices('nes', TNESSettingsDevices);
  RegisterPlatformDeviceCallouts('nes', TNESDeviceCallouts);
  RegisterPlatformControlsHelp('nes', TNESControlsHelp);
  RegisterPlatformSettingsHandler('nes', TNesSettingsHandler);
  RegisterPlatformWindowLayout('nes', TNesWindowLayout);
  RegisterPlatformSessionHandler('nes', TNesSessionHandler);
  RegisterPlatformInputHandler('nes', TNesInputHandler);
  RegisterInput;
  RegisterPlatformGamepads('nes', TGamepadNESStandart, [TGamepadDeviceVariant.Create('paddendy', TGamepadNESDendy)]);
  RegisterPlatformPresentation('nes', 'nes', PlatformIcon);
  RegisterPlatformPresentation('fds', 'nes', PlatformIcon);
end;

class procedure TNESPlatform.RegisterPlatform;
begin
  if FRegistered then
    Exit;
  RegisterInputPortsReader('nes',
    procedure(Ini: TCustomIniFile; var Ports: TCoreInputPorts)
    begin
      Ports.FourScore := Ini.ReadBool('Input', 'FourScore', Ports.FourScore);
      Ports.LegacyZapper := Ini.ReadBool('Input', 'Zapper', Ports.LegacyZapper);
    end);
  RegisterRuntimeServices;
  RegisterCore;
  RegisterClient;
  FRegistered := True;
end;

end.

