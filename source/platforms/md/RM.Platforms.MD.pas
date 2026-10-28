unit RM.Platforms.MD;

interface

uses
  Core.EmulatorRegistry, RM.Input, System.SysUtils;

const
  ROM_SYSTEM_MD = 'md';
  ROM_SYSTEM_SEGACD = 'segacd';
  ROM_SYSTEM_SEGA32X = 'sega32x';

type
  TMDPlatform = class
  strict private
    class var
      FRegistered: Boolean;
    class function Header(Context: TCoreLoadContext): TCoreMatch; static;
    class function Disc(Context: TCoreLoadContext): TCoreMatch; static;
    class procedure RegisterPlatforms; static;
    class procedure RegisterRomFormats; static;
    class procedure RegisterCore; static;
    class procedure RegisterServices; static;
    class procedure LoadLegacyKeys(var Keys: TPlatformInputKeyMap); static;
    class procedure RegisterInput; static;
    class procedure RegisterClient; static;
  public
    class procedure RegisterPlatform; static;
  end;

implementation

uses
  MD.Cartridge, RM.Settings.Catalog, MD.RomFormat, Core.Snapshots,
  System.StrUtils, Core.Emulation, Core.Platforms, Core.Platforms.MD.Adapter, RM.Platforms.MD.Settings, RM.Platforms.Presentation,
  RM.Platforms.MD.Icons, RM.Gamepad.Factory, RM.Platforms.MD.Gamepads,
  MD.Console, RM.Input.Runtime, RM.Session.Runtime, RM.Window.Layout,
  RM.Settings.Runtime, RM.ControlsHelp.Content, RM.Settings.Callouts,
  RM.Settings.Devices, System.Classes;

const
  MD_IMAGE_MAX_SIZE = 64 * 1024 * 1024;

class function TMDPlatform.Header(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  var Encoding: string;
  if not MD.RomFormat.TryDetectEncoding(Context.Data, Encoding) then
    Exit;
  Result := ImageMatch(Context, 'MD',
    function(const Data: TBytes; Input: TStream): IEmulationCore
    begin
      Result := TMDCoreAdapter.Create(Input, Context.Storage, Context.RomName);
    end, True, 'md', Encoding, MD_IMAGE_MAX_SIZE);
end;

class function TMDPlatform.Disc(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  if Context.IsDiscSource and Context.DiscSignature('SEGADISCSYSTEM') then
    Result := TCoreMatch.Create('MDCD',
      function: IEmulationCore
      begin
        Context.Stream.Position := 0;
        Result := TMDCoreAdapter.Create(Context.Stream, Context.Storage, Context.RomName, True);
      end);
end;

class procedure TMDPlatform.RegisterPlatforms;
begin
  TPlatformRegistry.RegisterPlatform('md', 'MegaDrive', 'MegaDrive',
    'Sega', 'MD Genesis Sega CD Mega CD 32X', 'megadrive', ['megadrive'],
    ['.smd', '.bin', '.gen', '.md', '.zip', '.7z'],
    'MegaDrive', 'md', 4);
  TPlatformRegistry.RegisterPlatform('segacd', 'Sega CD', 'Sega CD',
    'Sega', 'Mega CD CD32X 32X CD', 'segacd', ['segacd', 'megacd'],
    ['.cue', '.iso', '.chd', '.mds', '.nrg'],
    'MegaDrive', 'md', 4);
  TPlatformRegistry.RegisterPlatform('sega32x', 'Sega 32X', 'Sega 32X',
    'Sega', '32X Mars Super 32X', 'sega32x', ['sega32x', '32x'],
    ['.32x', '.bin', '.gen', '.md', '.smd', '.zip', '.7z'],
    'MegaDrive', 'md', 4);
end;

class procedure TMDPlatform.RegisterCore;
begin
  RegisterPlatforms;
  var Registration := TEmulationCoreRegistration.Create('MD', ['.smd', '.gen', '.md', '.32x']);
  Registration.Add(TCoreLoadStage.Header, 120, Header);
  Registration.Add(TCoreLoadStage.Source, 60, Disc);
  RegisterEmulationCore(Registration);
end;

class procedure TMDPlatform.RegisterServices;
begin
  RegisterSnapshotPolicy('MD', TSnapshotPolicy.Create(9));
end;

class procedure TMDPlatform.LoadLegacyKeys(var Keys: TPlatformInputKeyMap);
const
  MDMapping: array[TMDButton] of TEmulatorButton = (TEmulatorButton.Up,
    TEmulatorButton.Down, TEmulatorButton.Left, TEmulatorButton.Right,
    TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.C, TEmulatorButton.Start,
    TEmulatorButton.X, TEmulatorButton.Y, TEmulatorButton.Z, TEmulatorButton.Mode);
var
  Config: IEmulatorConfig;
begin
  var C := TMDConfig.Create('');
  Config := C;
  for var B := Low(TMDButton) to High(TMDButton) do
  begin
    Keys[0, MDMapping[B]] := C.Keys[B];
    Keys[1, MDMapping[B]] := C.Keys2[B];
  end;
end;

class procedure TMDPlatform.RegisterInput;
begin
  var Definition := TPlatformInputDefinition.Create([TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left,
      TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.Start, TEmulatorButton.C,
      TEmulatorButton.X, TEmulatorButton.Y, TEmulatorButton.Z, TEmulatorButton.Mode]);
  Definition.Devices := TArray<TInputDeviceVariant>.Create(TInputDeviceVariant.Create('pad3', [TEmulatorButton.Up,
        TEmulatorButton.Down, TEmulatorButton.Left, TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B,
        TEmulatorButton.Start, TEmulatorButton.C]));
  Definition.LegacyPorts := 4;
  Definition.LegacySection := 'Keys';
  Definition.AfterLegacyBindings := LoadSharedLegacyBindings;
  Definition.UseSharedBindingRules := True;
  Definition.LoadLegacyKeys := LoadLegacyKeys;
  RegisterPlatformInput('md', Definition);
  RegisterPlatformInput('segacd', Definition);
  RegisterPlatformInput('sega32x', Definition);
end;

class procedure TMDPlatform.RegisterClient;
begin
  RegisterSettingsProfile('MegaDrive', TMegaDriveSettings);
  RegisterPlatformSettingsDevices('md', TPlatformSettingsDevices);
  RegisterPlatformSettingsDevices('segacd', TPlatformSettingsDevices);
  RegisterPlatformSettingsDevices('sega32x', TPlatformSettingsDevices);
  RegisterPlatformDeviceCallouts('md', TPlatformDeviceCallouts);
  RegisterPlatformDeviceCallouts('segacd', TPlatformDeviceCallouts);
  RegisterPlatformDeviceCallouts('sega32x', TPlatformDeviceCallouts);
  RegisterPlatformControlsHelp('md', TPlatformControlsHelp);
  RegisterPlatformControlsHelp('segacd', TPlatformControlsHelp);
  RegisterPlatformControlsHelp('sega32x', TPlatformControlsHelp);
  RegisterPlatformSettingsHandler('md', TPlatformSettingsHandler);
  RegisterPlatformSettingsHandler('segacd', TPlatformSettingsHandler);
  RegisterPlatformSettingsHandler('sega32x', TPlatformSettingsHandler);
  RegisterPlatformWindowLayout('md', TPlatformWindowLayout);
  RegisterPlatformWindowLayout('segacd', TPlatformWindowLayout);
  RegisterPlatformWindowLayout('sega32x', TPlatformWindowLayout);
  RegisterPlatformSessionHandler('md', TPlatformSessionHandler);
  RegisterPlatformSessionHandler('segacd', TPlatformSessionHandler);
  RegisterPlatformSessionHandler('sega32x', TPlatformSessionHandler);
  RegisterPlatformInputHandler('md', TPlatformInputHandler);
  RegisterPlatformInputHandler('segacd', TPlatformInputHandler);
  RegisterPlatformInputHandler('sega32x', TPlatformInputHandler);
  RegisterInput;
  RegisterPlatformGamepads('md', TGamepadSEGAPad6, [TGamepadDeviceVariant.Create('pad3', TGamepadSEGAPad3)]);
  RegisterPlatformGamepads('segacd', TGamepadSEGAMegaCDPad6, [TGamepadDeviceVariant.Create('pad3', TGamepadSEGAMegaCDPad3)]);
  RegisterPlatformGamepads('sega32x', TGamepadSEGAMega32XPad6, [TGamepadDeviceVariant.Create('pad3', TGamepadSEGAMega32XPad3)]);
  RegisterPlatformPresentation('md', 'md', PlatformIconMD);
  RegisterPlatformPresentation('segacd', 'md', PlatformIconMD);
  RegisterPlatformPresentation('sega32x', 'md', PlatformIconMD);
end;

class procedure TMDPlatform.RegisterRomFormats;
begin
  RegisterRomEncoding(MD_ENCODING_SMD,
    function(const Data: TBytes): TBytes
    begin
      Result := MD.RomFormat.NormalizeImage(Data, MD_ENCODING_SMD);
    end);
  RegisterRomEncoding(MD_ENCODING_BYTE_SWAPPED,
    function(const Data: TBytes): TBytes
    begin
      Result := MD.RomFormat.NormalizeImage(Data, MD_ENCODING_BYTE_SWAPPED);
    end);
  RegisterRomNormalizer('md',
    function(const Data: TBytes; const Format: TRomFormatInfo): TBytes
    begin
      Result := MD.RomFormat.NormalizeImage(Data, Format.Encoding);
    end);
end;

class procedure TMDPlatform.RegisterPlatform;
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

