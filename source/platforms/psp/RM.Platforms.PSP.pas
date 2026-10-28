unit RM.Platforms.PSP;

interface

uses
  Core.EmulatorRegistry, RM.Input, System.SysUtils;

type
  TPSPPlatform = class
  strict private
    class var
      FRegistered: Boolean;
    class function Source(Context: TCoreLoadContext): TCoreMatch; static;
    class function Header(Context: TCoreLoadContext): TCoreMatch; static;
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
  RM.Settings.Catalog, RM.Settings.Platform, System.StrUtils, Core.Emulation,
  Core.Platforms, Core.Platforms.PSP.Adapter,
  Core.Platforms.PSP.Archive, PSP.Media, RM.Platforms.Presentation,
  RM.Platforms.GBA.Icons, RM.Gamepad.Factory, RM.Platforms.PSP.Gamepads,
  RM.Input.Runtime, RM.Session.Runtime, RM.Window.Layout, RM.Settings.Runtime,
  RM.ControlsHelp.Content, RM.Settings.Callouts, RM.Settings.Devices,
  System.Classes;

class function TPSPPlatform.Source(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  var Suitable := Context.HasExtension(['.pbp', '.elf', '.prx', '.cso']);
  if Context.HasExtension(['.elf']) then
  begin
    var Header := Context.Prefix(20);
    if (Length(Header) >= 20) and (Header[0] = $7F) and (Header[1] = Ord('E')) and
      (Header[2] = Ord('L')) and (Header[3] = Ord('F')) and (Header[18] = 42) and (Header[19] = 0) then
      Suitable := False;
  end;
  var RestorePosition := False;
  if Context.HasExtension(['.iso']) and TPSPDisc.Recognizes(Context.Stream) then
  begin
    var Saved := Context.Stream.Position;
    var Disc := TPSPDisc.Create(Context.Stream);
    try
      Suitable := Disc.IsPSP;
      RestorePosition := Suitable;
    finally
      Disc.Free;
      Context.Stream.Position := Saved;
    end;
  end;
  if Context.HasExtension(['.zip']) then
    Suitable := IsPSPArchive(Context.Stream);
  if Suitable then
    Result := TCoreMatch.Create('PSP',
      function: IEmulationCore
      begin
        var Saved := Context.Stream.Position;
        try
          Result := TPSPCoreAdapter.Create(Context.Stream, Context.Storage, Context.RomName, Context.SourceName);
        finally
          if RestorePosition then
            Context.Stream.Position := Saved;
        end;
      end);
end;

class function TPSPPlatform.Header(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  var Bytes := Context.Data;
  if Context.Signature(0, #0'PBP') or
    ((Length(Bytes) >= 20) and Context.Signature(0, #$7F'ELF') and (Bytes[18] = 8) and (Bytes[19] = 0)) then
    Result := ImageMatch(Context, 'PSP',
      function(const Data: TBytes; Input: TStream): IEmulationCore
      begin
        Result := TPSPCoreAdapter.Create(Input, Context.Storage, Context.RomName, Context.SourceName);
      end);
end;

class procedure TPSPPlatform.RegisterPlatforms;
begin
  TPlatformRegistry.RegisterPlatform('psp', 'PlayStation Portable (experimental)', 'PSP',
    'Sony', 'PSP PlayStation Portable Allegrex homebrew', 'psp', ['psp'],
    ['.iso', '.cso', '.pbp', '.elf', '.prx', '.zip'],
    '', 'psp', 1);
end;

class procedure TPSPPlatform.RegisterCore;
begin
  RegisterPlatforms;
  var Registration := TEmulationCoreRegistration.Create('PSP', ['.pbp', '.elf', '.prx', '.cso']);
  Registration.Add(TCoreLoadStage.Source, 20, Source);
  Registration.Add(TCoreLoadStage.Header, 31, Header);
  RegisterEmulationCore(Registration);
end;

class procedure TPSPPlatform.LoadLegacyKeys(var Keys: TPlatformInputKeyMap);
var
  Config: IEmulatorConfig;
begin
  var C := TPSPConfig.Create('', nil);
  Config := C;
  for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
    Keys[0, B] := C.Keys[B];
end;

class procedure TPSPPlatform.RegisterInput;
begin
  var Definition := TPlatformInputDefinition.Create([TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left,
      TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.Select, TEmulatorButton.Start,
      TEmulatorButton.C, TEmulatorButton.X, TEmulatorButton.Y, TEmulatorButton.Z]);
  Definition.ButtonNames[TEmulatorButton.A] := 'Cross';
  Definition.ButtonNames[TEmulatorButton.B] := 'Circle';
  Definition.ButtonNames[TEmulatorButton.C] := 'L';
  Definition.ButtonNames[TEmulatorButton.X] := 'Square';
  Definition.ButtonNames[TEmulatorButton.Y] := 'Triangle';
  Definition.ButtonNames[TEmulatorButton.Z] := 'R';
  Definition.LegacyPorts := 1;
  Definition.LegacySection := 'Keys';
  Definition.AfterLegacyBindings := LoadSharedLegacyBindings;
  Definition.UseSharedBindingRules := True;
  Definition.LoadLegacyKeys := LoadLegacyKeys;
  RegisterPlatformInput('psp', Definition);
end;

class procedure TPSPPlatform.RegisterClient;
begin
  RegisterSettingsPlatform('psp', TSettingsPlatform);
  RegisterPlatformSettingsDevices('psp', TPlatformSettingsDevices);
  RegisterPlatformDeviceCallouts('psp', TPlatformDeviceCallouts);
  RegisterPlatformControlsHelp('psp', TPlatformControlsHelp);
  RegisterPlatformSettingsHandler('psp', TPlatformSettingsHandler);
  RegisterPlatformWindowLayout('psp', TPlatformWindowLayout);
  RegisterPlatformSessionHandler('psp', TPlatformSessionHandler);
  RegisterPlatformInputHandler('psp', TPlatformInputHandler);
  RegisterInput;
  RegisterPlatformGamepads('psp', TGamepadPSP, []);
  RegisterPlatformPresentation('psp', 'psp', PlatformIconGBA);
end;

class procedure TPSPPlatform.RegisterPlatform;
begin
  if FRegistered then
    Exit;
  RegisterCore;
  RegisterClient;
  FRegistered := True;
end;

end.

