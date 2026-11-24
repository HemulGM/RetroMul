unit RM.Platforms.DC;

interface

uses
  Core.EmulatorRegistry, RM.Input, System.IniFiles, FMXInput, System.SysUtils;

const
  ROM_SYSTEM_DC = 'dc';
  ROM_CORE_ID_DC = 'DC';

type
  TDCPlatform = class
  strict private
    class function LoadDisc(Context: TCoreLoadContext): TCoreMatch; static;
    class var
      FRegistered: Boolean;
    class function Source(Context: TCoreLoadContext): TCoreMatch; static;
    class function Disc(Context: TCoreLoadContext): TCoreMatch; static;
    class function Header(Context: TCoreLoadContext): TCoreMatch; static;
    class procedure RegisterPlatforms; static;
    class procedure RegisterCore; static;
    class procedure RegisterRuntimeServices; static;
    class procedure LoadLegacyKeys(var Keys: TPlatformInputKeyMap); static;
    class procedure LoadLegacyExtras(Input: TInputManager; Ini: TCustomIniFile); static;
    class procedure RegisterInput; static;
    class procedure RegisterClient; static;
    class procedure LoadGamepadPreset(Input: TInputManager; Port: Integer); static;
  public
    class procedure RegisterPlatform; static;
  end;

implementation

uses
  RM.Input.Gamepads, RM.Settings.Catalog, Core.CD.Disc, Core.PlatformServices,
  System.StrUtils, Core.Emulation, Core.Platforms, Core.Platforms.DC.Adapter,
  Core.Snapshots, DC.ELF, RM.Platforms.DC.Settings, RM.Platforms.Presentation,
  RM.Gamepad.Factory, RM.Platforms.DC.Gamepads, RM.Input.Runtime,
  RM.Platforms.DC.Runtime, RM.Session.Runtime, RM.Window.Layout,
  RM.Settings.Runtime, RM.ControlsHelp.Content, RM.Platforms.DC.Help,
  RM.Settings.Callouts, RM.Settings.Devices, RM.Platforms.DC.Devices,
  System.Classes;

const
  PlatformIcon =
    'M10,12 L54,12 C57.3,12 60,14.7 60,18 L60,50 C60,53.3 57.3,56 54,56 L10,56 C6.7,56 4,53.3 4,50 L4,18 ' +
    'C4,14.7 6.7,12 10,12 Z M32,16 C24.27,16 18,22.27 18,30 C18,37.73 24.27,44 32,44 C39.73,44 46,37.73 46,30 ' +
    'C46,22.27 39.73,16 32,16 Z M32,20 C37.52,20 42,24.48 42,30 C42,35.52 37.52,40 32,40 C26.48,40 22,35.52 22,30 ' +
    'C22,24.48 26.48,20 32,20 Z M32,27 C30.34,27 29,28.34 29,30 C29,31.66 30.34,33 32,33 C33.66,33 35,31.66 35,30 ' +
    'C35,28.34 33.66,27 32,27 Z M10,48 L10,52 L17,52 L17,48 Z M20,48 L20,52 L27,52 L27,48 Z M37,48 L37,52 L44,52 ' +
    'L44,48 Z M47,48 L47,52 L54,52 L54,48 Z ';
  DC_IMAGE_MAX_SIZE = 64 * 1024 * 1024;

class procedure TDCPlatform.LoadGamepadPreset(Input: TInputManager; Port: Integer);
begin
  for var Direction := TEmulatorButton.Up to TEmulatorButton.Right do
    AddStandardDirection(Input, Port, PadAction(Port, Direction), Ord(Direction), True);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.A), TGamepadButton.South);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.B), TGamepadButton.East);
  AddStandardTrigger(Input, Port, PadAction(Port, TEmulatorButton.Select), True);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.Start), TGamepadButton.Start);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.X), TGamepadButton.West);
  AddStandardButton(Input, Port, PadAction(Port, TEmulatorButton.Y), TGamepadButton.North);
  AddStandardTrigger(Input, Port, PadAction(Port, TEmulatorButton.Mode), False);
end;

class function TDCPlatform.LoadDisc(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := TCoreMatch.Create('DC',
    function: IEmulationCore
    begin
      Context.Stream.Position := 0;
      Result := TDCCoreAdapter.Create(Context.Stream, Context.EffectiveStorage, Context.RomName, Context.TakeDisc);
    end);
  Result.Format.SystemId := 'dc';
end;

class function TDCPlatform.Source(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  var ELF := Context.HasExtension(['.elf']) and IsDCELF(Context.Prefix(52));
  var NativeDisc := Context.HasExtension(['.gdi', '.cdi']) and not Context.ArchiveEntry;
  var Playlist := False;
  if Context.HasExtension(['.m3u']) then
  begin
    var Folder := ExtractFileName(ExcludeTrailingPathDelimiter(ExtractFilePath(Context.SourceName)));
    Playlist := SameText(Folder, 'dc') or SameText(Folder, 'dreamcast') or
      MatchText(ExtractFileExt(Context.FirstPlaylistEntry), ['.gdi', '.cdi']);
  end;
  if NativeDisc then
  begin
    if NativeDisc and not TDCCoreAdapter.IsDCDisc(Context.Disc) then
      Exit;
    Exit(TCoreMatch.Create('DC',
      function: IEmulationCore
      begin
        Result := TDCCoreAdapter.Create(Context.Stream, Context.EffectiveStorage, Context.RomName, Context.TakeDisc);
      end));
  end;
  if Playlist then
  begin
    try
      Playlist := TDCCoreAdapter.IsDCDisc(Context.PlaylistDisc('dc'));
    except
      on E: EReadError do
        Playlist := False;
    end;
  end;
  if ELF or Playlist then
    Result := TCoreMatch.Create('DC',
      function: IEmulationCore
      begin
        Result := TDCCoreAdapter.Create(Context.Stream, Context.Storage, Context.RomName);
      end);
end;

class function TDCPlatform.Disc(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  if Context.IsDiscSource and TDCCoreAdapter.IsDCDisc(Context.Disc) then
    Result := LoadDisc(Context);
end;

class function TDCPlatform.Header(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  var Bytes := Context.Data;
  if IsDCELF(Bytes) then
    Result := ImageMatch(Context, 'DC',
      function(const Data: TBytes; Input: TStream): IEmulationCore
      begin
        Result := TDCCoreAdapter.Create(Input, Context.Storage, Context.RomName);
      end, True, 'dc', '', DC_IMAGE_MAX_SIZE);
end;

class procedure TDCPlatform.RegisterPlatforms;
begin
  TPlatformRegistry.RegisterPlatform('dc', 'Dreamcast', 'Dreamcast',
    'Sega', 'DC Dreamcast GD-ROM', 'dc', ['dc', 'dreamcast'],
    ['.m3u', '.gdi', '.cdi', '.chd', '.cue', '.iso', '.mds', '.nrg', '.elf'],
    'DC', 'dc', 4);
end;

class procedure TDCPlatform.RegisterCore;
begin
  RegisterPlatforms;
  var Registration := TEmulationCoreRegistration.Create('DC', ['.elf']);
  Registration.Add(TCoreLoadStage.Source, 10, Source);
  Registration.Add(TCoreLoadStage.Source, 40, Disc);
  Registration.Add(TCoreLoadStage.Header, 30, Header);
  Registration.AddDiscPlatform('dc', LoadDisc);
  RegisterEmulationCore(Registration);
end;

class procedure TDCPlatform.RegisterRuntimeServices;
begin
  var Policy := TSnapshotPolicy.Create(4);
  Policy.AcceptedVersions := [1, 2, 3];
  RegisterSnapshotPolicy(ROM_CORE_ID_DC, Policy);
  var Service := Default(TPlatformServices);
  Service.LibraryFeatures := [TLibraryFeature.Playlists, TLibraryFeature.CueTracks] + [TLibraryFeature.GdiTracks];
  RegisterPlatformServices('dc', Service);
end;

class procedure TDCPlatform.LoadLegacyKeys(var Keys: TPlatformInputKeyMap);
var
  Config: IEmulatorConfig;
begin
  var C := TDCConfig.Create('', nil);
  Config := C;
  var Map := C.Keys;
  for var Port := 0 to 3 do
    for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
      Keys[Port, B] := Map[Port, B];
end;

class procedure TDCPlatform.LoadLegacyExtras(Input: TInputManager; Ini: TCustomIniFile);
var
  Config: IEmulatorConfig;
begin
  var C := TDCConfig.Create('', nil);
  Config := C;
  for var Port := 0 to 3 do
  begin
    var Section := 'Keys';
    if Port > 0 then
      Section := Section + IntToStr(Port + 1);
    for var Extra := Low(TDCExtra) to High(TDCExtra) do
      AddLegacyInputKey(Input, DCAction(Port, Extra), ReadEmulatorKey(Ini, Section, TDCConfig.ExtraKeyName(Extra),
          C.ExtraKey(Port, Extra)));
  end;
end;

class procedure TDCPlatform.RegisterInput;
begin
  var Definition := TPlatformInputDefinition.Create([TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left,
      TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.Select, TEmulatorButton.Start,
      TEmulatorButton.X, TEmulatorButton.Y, TEmulatorButton.Mode]);
  Definition.PadDevicesOnly := False;
  Definition.Devices := TArray<TInputDeviceVariant>.Create(TInputDeviceVariant.Create('none', []));
  Definition.ButtonNames[TEmulatorButton.Select] := 'L';
  Definition.ButtonNames[TEmulatorButton.Mode] := 'R';
  // The controller's L and R are analog triggers (ReadDCPad).
  Definition.AnalogButtons := [TEmulatorButton.Select, TEmulatorButton.Mode];
  Definition.LegacyPorts := 4;
  Definition.LegacySection := 'Keys';
  Definition.AfterLegacyBindings := LoadSharedLegacyBindings;
  Definition.UseSharedBindingRules := True;
  Definition.LoadLegacyKeys := LoadLegacyKeys;
  Definition.BeforeLegacyBindings := LoadLegacyExtras;
  Definition.LoadGamepadPreset := LoadGamepadPreset;
  RegisterPlatformInput('dc', Definition);
end;

class procedure TDCPlatform.RegisterClient;
begin
  RegisterSettingsProfile('DC', TDCSettings,
    'Built-in boot uses high-level firmware services. Automatic mode can use a boot ROM when ' +
    'found. Boot ROM file mode starts from a Dreamcast boot ROM. With a .gdi image keep all ' +
    'referenced tracks. For multi-disc games you can open an .m3u playlist. CPU recompiler ' +
    'availability depends on the host.');
  RegisterPlatformSettingsDevices('dc', TDCSettingsDevices);
  RegisterPlatformDeviceCallouts('dc', TPlatformDeviceCallouts);
  RegisterPlatformControlsHelp('dc', TDCControlsHelp);
  RegisterPlatformSettingsHandler('dc', TPlatformSettingsHandler);
  RegisterPlatformWindowLayout('dc', TPlatformWindowLayout);
  RegisterPlatformSessionHandler('dc', TDCSessionHandler);
  RegisterPlatformInputHandler('dc', TDCInputHandler);
  RegisterInput;
  RegisterPlatformGamepads('dc', TGamepadDCStandart, []);
  RegisterPlatformPresentation('dc', 'dc', PlatformIcon);
end;

class procedure TDCPlatform.RegisterPlatform;
begin
  if FRegistered then
    Exit;
  RegisterCDTrackAdjustment('.gdi',
    function(const Track: TCDTrack; StartLBA: Integer): Integer

      function BootSector(Position: Int64): Boolean;
      var
        Text: array[0..15] of AnsiChar;
      begin
        Track.Stream.Position := Position;
        Result := (Track.Stream.Read(Text, SizeOf(Text)) = SizeOf(Text)) and
          CompareMem(@Text[0], PAnsiChar(AnsiString('SEGA SEGAKATANA ')), 16);
      end;


    begin
      Result := 0;
      if not Track.Audio and (StartLBA >= 45000) and (Track.SectorSize = 2352) and
        not BootSector(Track.DataOffset) and BootSector(Int64(150) * 2352 + Track.DataOffset) then
        Result := 150;
    end);
  RegisterRuntimeServices;
  RegisterCore;
  RegisterClient;
  FRegistered := True;
end;

end.

