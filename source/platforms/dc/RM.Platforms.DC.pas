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
  public
    class procedure RegisterPlatform; static;
  end;

implementation

uses
  RM.Settings.Catalog, Core.CD.Disc, Core.PlatformServices, System.StrUtils,
  Core.Emulation, Core.Platforms, Core.Platforms.DC.Adapter,
  DC.ELF, RM.Platforms.DC.Settings, RM.Platforms.Presentation,
  RM.Platforms.DC.Icons, RM.Gamepad.Factory, RM.Platforms.DC.Gamepads,
  RM.Input.Runtime, RM.Platforms.DC.Runtime, RM.Session.Runtime,
  RM.Window.Layout, RM.Settings.Runtime, RM.ControlsHelp.Content,
  RM.Platforms.DC.Help, RM.Settings.Callouts, RM.Settings.Devices,
  RM.Platforms.DC.Devices, System.Classes;

const
  DC_IMAGE_MAX_SIZE = 64 * 1024 * 1024;

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
      raise EReadError.Create('Not a Dreamcast disc: the boot track lacks the SEGA SEGAKATANA identifier');
    Exit(TCoreMatch.Create('DC',
      function: IEmulationCore
      begin
        Result := TDCCoreAdapter.Create(Context.Stream, Context.EffectiveStorage, Context.RomName, Context.TakeDisc);
      end));
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
    Result := TCoreMatch.Create('DC',
      function: IEmulationCore
      begin
        Result := TDCCoreAdapter.Create(Context.Stream, Context.EffectiveStorage, Context.RomName, Context.TakeDisc);
      end);
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
  RegisterEmulationCore(Registration);
end;

class procedure TDCPlatform.RegisterRuntimeServices;
begin
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
  Definition.LegacyPorts := 4;
  Definition.LegacySection := 'Keys';
  Definition.AfterLegacyBindings := LoadSharedLegacyBindings;
  Definition.UseSharedBindingRules := True;
  Definition.LoadLegacyKeys := LoadLegacyKeys;
  Definition.BeforeLegacyBindings := LoadLegacyExtras;
  RegisterPlatformInput('dc', Definition);
end;

class procedure TDCPlatform.RegisterClient;
begin
  RegisterSettingsProfile('DC', TDCSettings);
  RegisterPlatformSettingsDevices('dc', TDCSettingsDevices);
  RegisterPlatformDeviceCallouts('dc', TPlatformDeviceCallouts);
  RegisterPlatformControlsHelp('dc', TDCControlsHelp);
  RegisterPlatformSettingsHandler('dc', TPlatformSettingsHandler);
  RegisterPlatformWindowLayout('dc', TPlatformWindowLayout);
  RegisterPlatformSessionHandler('dc', TDCSessionHandler);
  RegisterPlatformInputHandler('dc', TDCInputHandler);
  RegisterInput;
  RegisterPlatformGamepads('dc', TGamepadDCStandart, []);
  RegisterPlatformPresentation('dc', 'dc', PlatformIconDC);
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

