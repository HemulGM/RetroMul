unit RM.Platforms.NDS;

interface

uses
  Core.EmulatorRegistry;

type
  TNDSPlatform = class
  strict private
    class var
      FRegistered: Boolean;
    class function Source(Context: TCoreLoadContext): TCoreMatch; static;
    class function Header(Context: TCoreLoadContext): TCoreMatch; static;
    class function ExtensionHint(Context: TCoreLoadContext): TCoreMatch; static;
  public
    class procedure RegisterPlatform; static;
  end;

implementation

uses
  System.SysUtils, System.Classes, Core.Platforms, Core.Emulation,
  Core.Platforms.NDS.Adapter, NDS.Cartridge, RM.Settings.Catalog,
  RM.Platforms.NDS.Settings, RM.Platforms.NDS.Input, RM.Input, RM.Input.Runtime,
  RM.Session.Runtime, RM.Window.Layout, RM.Settings.Runtime,
  RM.ControlsHelp.Content, RM.Settings.Callouts, RM.Settings.Devices,
  RM.Gamepad.Factory, RM.Platforms.SNES.Gamepads, RM.Platforms.Presentation,
  RM.Platforms.GBA.Icons, Core.Snapshots;

type
  TNDSSessionHandler = class(TPlatformSessionHandler)
    class procedure Connect(const Context: TSessionRuntimeContext); override;
  end;

class procedure TNDSSessionHandler.Connect(const Context: TSessionRuntimeContext);
begin
  inherited;
  Context.View.ImageCanvas.HitTest := True;
  Context.View.ImageCanvas.CanFocus := True;
  Context.View.ImageCanvas.OnKeyDown := Context.View.FormKeyDown;
  Context.View.ImageCanvas.OnKeyUp := Context.View.FormKeyUp;
  Context.View.ImageCanvas.DisableFocusEffect := False;
  Context.View.ImageCanvas.CanParentFocus := True;
end;

class function TNDSPlatform.Source(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  if Context.HasExtension(['.nds']) then
  begin
    Result := TCoreMatch.Create('NDS',
      function: IEmulationCore
      begin
        var Saved := Context.Stream.Position;
        try
          Result := TNDSCoreAdapter.Create(Context.Stream, Context.Storage, Context.RomName);
        finally
          Context.Stream.Position := Saved;
        end;
      end);
    Result.Format.SystemId := 'nds';
  end;
end;

class function TNDSPlatform.Header(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  if IsNDSROM(Context.Data) then
    Result := ImageMatch(Context, 'NDS',
      function(const Data: TBytes; Input: TStream): IEmulationCore
      begin
        Result := TNDSCoreAdapter.Create(Input, Context.Storage, Context.RomName);
      end,
          False, 'nds', '', NDS_ROM_MAX_SIZE);
end;

class function TNDSPlatform.ExtensionHint(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  if not Context.HeaderRecognized and Context.HasExtension(['.nds']) then
    Result := ImageMatch(Context, 'NDS',
      function(const Data: TBytes; Input: TStream): IEmulationCore
      begin
        Result := TNDSCoreAdapter.Create(Input, Context.Storage, Context.RomName);
      end,
          False, 'nds', '', NDS_ROM_MAX_SIZE);
end;

class procedure TNDSPlatform.RegisterPlatform;
begin
  if FRegistered then
    Exit;
  TPlatformRegistry.RegisterPlatform('nds', 'Nintendo DS (experimental)', 'NDS',
    'Nintendo', 'Nintendo DS ARM9 ARM7 stylus', 'nds', ['nds'], ['.nds', '.zip', '.7z'], 'NDS', 'nds', 1);
  var Registration := TEmulationCoreRegistration.Create('NDS', ['.nds']);
  Registration.MaxArchiveImageSize := NDS_ROM_MAX_SIZE;
  Registration.Add(TCoreLoadStage.Source, 40, Source);
  Registration.Add(TCoreLoadStage.Header, 92, Header);
  Registration.Add(TCoreLoadStage.OverrideHint, 20, ExtensionHint);
  RegisterEmulationCore(Registration);
  RegisterSnapshotPolicy('NDS', TSnapshotPolicy.Create(1, 32 * 1024 * 1024));
  RegisterSettingsProfile('NDS', TNDSSettings);
  RegisterPlatformSettingsDevices('nds', TPlatformSettingsDevices);
  RegisterPlatformDeviceCallouts('nds', TPlatformDeviceCallouts);
  RegisterPlatformControlsHelp('nds', TPlatformControlsHelp);
  RegisterPlatformSettingsHandler('nds', TPlatformSettingsHandler);
  RegisterPlatformWindowLayout('nds', TPlatformWindowLayout);
  RegisterPlatformSessionHandler('nds', TNDSSessionHandler);
  RegisterPlatformInputHandler('nds', TNDSInputHandler);
  var Definition := TPlatformInputDefinition.Create(NDS_BUTTONS);
  Definition.ButtonNames[TEmulatorButton.C] := 'L';
  Definition.ButtonNames[TEmulatorButton.Z] := 'R';
  Definition.LegacyPorts := 1;
  Definition.LegacySection := 'Keys';
  Definition.AfterLegacyBindings := LoadSharedLegacyBindings;
  Definition.UseSharedBindingRules := True;
  Definition.LegacyKeyNames[TEmulatorButton.C] := 'L';
  Definition.LegacyKeyNames[TEmulatorButton.Z] := 'R';
  Definition.LoadLegacyKeys :=
    procedure(var Keys: TPlatformInputKeyMap)
    begin
      var C := TNDSConfig.Create('', nil);
      var Hold: IEmulatorConfig := C;
      for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
        Keys[0, B] := C.Keys[B];
    end;
  RegisterPlatformInput('nds', Definition);
  RegisterPlatformGamepads('nds', TGamepadSNESStandart, []);
  RegisterPlatformPresentation('nds', 'nds', PlatformIconGBA);
  FRegistered := True;
end;

end.

