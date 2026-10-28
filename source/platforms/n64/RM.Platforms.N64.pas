unit RM.Platforms.N64;

interface

uses
  Core.EmulatorRegistry, RM.Input, System.IniFiles, FMXInput, System.SysUtils;

const
  ROM_SYSTEM_N64 = 'n64';

type
  TN64Platform = class
  strict private
    class var
      FRegistered: Boolean;
    class function Recognize(Context: TCoreLoadContext): TCoreMatch; static;
    class procedure RegisterPlatforms; static;
    class procedure RegisterRomFormats; static;
    class procedure RegisterCore; static;
    class procedure RegisterServices; static;
    class procedure LoadLegacyKeys(var Keys: TPlatformInputKeyMap); static;
    class procedure LoadLegacyExtras(Input: TInputManager; Ini: TCustomIniFile); static;
    class procedure RegisterInput; static;
    class procedure RegisterClient; static;
  public
    class procedure RegisterPlatform; static;
  end;

implementation

uses
  RM.Settings.Catalog, N64.RomFormat, Core.Snapshots,
  System.StrUtils, Core.Emulation, Core.Platforms, Core.Platforms.N64.Adapter, RM.Platforms.N64.Settings,
  RM.Platforms.Presentation, RM.Platforms.N64.Icons, RM.Gamepad.Factory,
  RM.Platforms.N64.Gamepads, RM.Input.Runtime, RM.Platforms.N64.Input,
  RM.Session.Runtime, RM.Window.Layout, RM.Settings.Runtime,
  RM.ControlsHelp.Content, RM.Platforms.N64.Help, RM.Settings.Callouts,
  RM.Platforms.N64.Devices, RM.Settings.Devices, System.Classes;

class function TN64Platform.Recognize(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  var Encoding: string;
  if not N64.RomFormat.TryDetectEncoding(Context.Data, Encoding) then
    Exit;
  Result := ImageMatch(Context, 'N64',
    function(const Data: TBytes; Input: TStream): IEmulationCore
    begin
      Result := TN64CoreAdapter.Create(Input, Context.Storage, Context.RomName);
    end, True, 'n64', Encoding, N64_IMAGE_MAX_SIZE);
end;

class procedure TN64Platform.RegisterPlatforms;
begin
  TPlatformRegistry.RegisterPlatform('n64', 'Nintendo 64', 'N64',
    'Nintendo', 'N64', 'n64', ['n64'],
    ['.z64', '.n64', '.v64', '.zip', '.7z'],
    'N64', 'n64', 4);
end;

class procedure TN64Platform.RegisterCore;
begin
  RegisterPlatforms;
  var Registration := TEmulationCoreRegistration.Create('N64', ['.z64', '.n64', '.v64']);
  Registration.Add(TCoreLoadStage.Header, 60, Recognize);
  RegisterEmulationCore(Registration);
end;

class procedure TN64Platform.RegisterServices;
begin
  var Policy := TSnapshotPolicy.Create(4);
  Policy.VersionError := 'N64 snapshot version %d is unsupported; expected version %d';
  RegisterSnapshotPolicy('N64', Policy);
end;

class procedure TN64Platform.LoadLegacyKeys(var Keys: TPlatformInputKeyMap);
var
  Config: IEmulatorConfig;
begin
  var C := TN64Config.Create('', nil);
  Config := C;
  var Map := C.Keys;
  for var Port := 0 to 3 do
    for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
      Keys[Port, B] := Map[Port, B];
end;

class procedure TN64Platform.LoadLegacyExtras(Input: TInputManager; Ini: TCustomIniFile);
var
  Config: IEmulatorConfig;
begin
  var C := TN64Config.Create('', nil);
  Config := C;
  for var Port := 0 to 3 do
  begin
    var Section := 'Keys';
    if Port > 0 then
      Section := Section + IntToStr(Port + 1);
    AddLegacyInputKey(Input, N64LAction + Port, ReadEmulatorKey(Ini, Section, 'L', C.LKey(Port)));
  end;
end;

class procedure TN64Platform.RegisterInput;
begin
  var Definition := TPlatformInputDefinition.Create([TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left,
      TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.Select, TEmulatorButton.Start,
      TEmulatorButton.C, TEmulatorButton.X, TEmulatorButton.Y, TEmulatorButton.Z, TEmulatorButton.Mode]);
  Definition.ButtonNames[TEmulatorButton.Select] := 'Z';
  Definition.ButtonNames[TEmulatorButton.C] := 'CDown';
  Definition.ButtonNames[TEmulatorButton.X] := 'CLeft';
  Definition.ButtonNames[TEmulatorButton.Y] := 'CUp';
  Definition.ButtonNames[TEmulatorButton.Z] := 'CRight';
  Definition.ButtonNames[TEmulatorButton.Mode] := 'R';
  Definition.LegacyPorts := 4;
  Definition.LegacySection := 'Keys';
  Definition.AfterLegacyBindings := LoadSharedLegacyBindings;
  Definition.UseSharedBindingRules := True;
  Definition.LoadLegacyKeys := LoadLegacyKeys;
  Definition.LegacyKeyNames[TEmulatorButton.Select] := 'Z';
  Definition.LegacyKeyNames[TEmulatorButton.C] := 'CDown';
  Definition.LegacyKeyNames[TEmulatorButton.X] := 'CLeft';
  Definition.LegacyKeyNames[TEmulatorButton.Y] := 'CUp';
  Definition.LegacyKeyNames[TEmulatorButton.Z] := 'CRight';
  Definition.LegacyKeyNames[TEmulatorButton.Mode] := 'R';
  Definition.BeforeLegacyBindings := LoadLegacyExtras;
  RegisterPlatformInput('n64', Definition);
end;

class procedure TN64Platform.RegisterClient;
begin
  RegisterSettingsProfile('N64', TN64Settings);
  RegisterPlatformSettingsDevices('n64', TN64SettingsDevices);
  RegisterPlatformDeviceCallouts('n64', TN64DeviceCallouts);
  RegisterPlatformControlsHelp('n64', TN64ControlsHelp);
  RegisterPlatformSettingsHandler('n64', TPlatformSettingsHandler);
  RegisterPlatformWindowLayout('n64', TPlatformWindowLayout);
  RegisterPlatformSessionHandler('n64', TPlatformSessionHandler);
  RegisterPlatformInputHandler('n64', TN64InputHandler);
  RegisterInput;
  RegisterPlatformGamepads('n64', TGamepadN64Standart, []);
  RegisterPlatformPresentation('n64', 'n64', PlatformIconN64);
end;

class procedure TN64Platform.RegisterRomFormats;
begin
  RegisterRomEncoding(N64_ENCODING_BYTE_SWAPPED,
    function(const Data: TBytes): TBytes
    begin
      Result := N64.RomFormat.NormalizeImage(Data, N64_ENCODING_BYTE_SWAPPED);
    end);
  RegisterRomEncoding(N64_ENCODING_WORD_SWAPPED,
    function(const Data: TBytes): TBytes
    begin
      Result := N64.RomFormat.NormalizeImage(Data, N64_ENCODING_WORD_SWAPPED);
    end);
  RegisterRomNormalizer('n64',
    function(const Data: TBytes; const Format: TRomFormatInfo): TBytes
    begin
      Result := N64.RomFormat.NormalizeImage(Data, Format.Encoding);
    end);
end;

class procedure TN64Platform.RegisterPlatform;
begin
  if FRegistered then
    Exit;
  RegisterRomFormats;
  RegisterServices;
  RegisterCore;
  RegisterClient;
  FRegistered := True;
end;

end.

