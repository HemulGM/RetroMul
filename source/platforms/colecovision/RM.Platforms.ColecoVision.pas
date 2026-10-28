unit RM.Platforms.ColecoVision;

interface

uses
  Core.EmulatorRegistry, RM.Input;

const
  ROM_SYSTEM_COLECOVISION = 'colecovision';

type
  TColecoVisionPlatform = class
  strict private
    class var
      FRegistered: Boolean;
    class function Match(Context: TCoreLoadContext): TCoreMatch; static;
    class function Header(Context: TCoreLoadContext): TCoreMatch; static;
    class function ExtensionHint(Context: TCoreLoadContext): TCoreMatch; static;
    class procedure LoadLegacyKeys(var Keys: TPlatformInputKeyMap); static;
  public
    class procedure RegisterPlatform; static;
  end;

implementation

uses
  System.SysUtils, System.Classes, System.UITypes, Core.Emulation,
  Core.Platforms, Core.Snapshots, Core.PlatformServices, CV.Cartridge,
  Core.Platforms.ColecoVision.Adapter, RM.Platforms.ColecoVision.Input,
  RM.Platforms.ColecoVision.Gamepads, RM.Platforms.ColecoVision.Settings,
  RM.Settings.Catalog, RM.Platforms.Presentation, RM.Gamepad.Factory,
  RM.Input.Runtime, RM.Keyboard.Input, RM.Session.Runtime, RM.Keyboard.Session,
  RM.Window.Layout, RM.Keyboard.Window, RM.Settings.Runtime,
  RM.Keyboard.Settings, RM.ControlsHelp.Content, RM.Settings.Callouts,
  RM.Settings.Devices;

class function TColecoVisionPlatform.Match(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := ImageMatch(Context, 'COLECO',
    function(const Data: TBytes; Input: TStream): IEmulationCore
    begin
      Result := TCVCoreAdapter.Create(Input, Context.Storage, Context.RomName);
    end, False, 'colecovision', '', $200000);
end;

class function TColecoVisionPlatform.Header(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  // Two signature bytes alone are too weak to override another console's
  // distinctive header. Restrict generic ROM/BIN detection to plausible carts.
  if not Context.HasExtension(['.col', '.cv', '.rom', '.bin']) then
    Exit;
  var Data := Context.Data;
  if (Length(Data) < 32) or (Length(Data) > $200000) then
    Exit;
  if TCVCartridge.HasHeader(Data) or
    ((Length(Data) > $8000) and TCVCartridge.HasHeader(Data, Length(Data) - $4000)) then
    Result := Match(Context);
end;

class function TColecoVisionPlatform.ExtensionHint(Context: TCoreLoadContext): TCoreMatch;
begin
  Result := nil;
  if Context.HasExtension(['.col', '.cv']) then
    Result := Match(Context)
  else if Context.HasExtension(['.rom', '.bin']) and
    Context.RomName.ToLower.Replace('\', '/').Contains('/colecovision/') then
    Result := Match(Context);
end;

class procedure TColecoVisionPlatform.LoadLegacyKeys(var Keys: TPlatformInputKeyMap);
begin
  Keys[0, TEmulatorButton.Up] := vkUp;
  Keys[0, TEmulatorButton.Down] := vkDown;
  Keys[0, TEmulatorButton.Left] := vkLeft;
  Keys[0, TEmulatorButton.Right] := vkRight;
  Keys[0, TEmulatorButton.A] := vkZ;
  Keys[0, TEmulatorButton.B] := vkX;
  Keys[0, TEmulatorButton.Start] := vkReturn;
  Keys[0, TEmulatorButton.Select] := vkSpace;
  Keys[0, TEmulatorButton.X] := vkC;
  Keys[0, TEmulatorButton.Y] := vkV;
  Keys[1, TEmulatorButton.Up] := vkT;
  Keys[1, TEmulatorButton.Down] := vkG;
  Keys[1, TEmulatorButton.Left] := vkF;
  Keys[1, TEmulatorButton.Right] := vkH;
  Keys[1, TEmulatorButton.A] := vkN;
  Keys[1, TEmulatorButton.B] := vkM;
  Keys[1, TEmulatorButton.Start] := vkY;
  Keys[1, TEmulatorButton.Select] := vkB;
  Keys[1, TEmulatorButton.X] := vkO;
  Keys[1, TEmulatorButton.Y] := vkP;
end;

class procedure TColecoVisionPlatform.RegisterPlatform;
const
  // ColecoVision console silhouette with its recessed controller bays.
  Icon = 'M4,8 L92,8 L96,16 L96,74 L4,74 Z M12,16 L12,52 L40,52 L40,16 Z ' +
    'M56,16 L56,52 L84,52 L84,16 Z M16,20 L36,20 L36,32 L16,32 Z ' +
    'M60,20 L80,20 L80,32 L60,32 Z M12,60 L88,60 L88,66 L12,66 Z';
begin
  if FRegistered then
    Exit;
  TPlatformRegistry.RegisterPlatform('colecovision', 'ColecoVision', 'ColecoVision',
    'Coleco', 'Coleco Vision CV Super Game Module MegaCart', 'colecovision',
    ['colecovision', 'coleco'], ['.col', '.cv', '.rom', '.bin', '.zip', '.7z'],
    'ColecoVision', 'colecovision', 2);
  TPlatformRegistry.RegisterAlias('coleco', 'colecovision');
  RegisterSnapshotPolicy('COLECO', TSnapshotPolicy.Create(2));
  var Registration := TEmulationCoreRegistration.Create('COLECO', ['.col', '.cv', '.rom', '.bin']);
  Registration.Add(TCoreLoadStage.Header, 95, Header);
  Registration.Add(TCoreLoadStage.OverrideHint, 10, ExtensionHint);
  RegisterEmulationCore(Registration);
  var Service := Default(TPlatformServices);
  Service.TerminalInput :=
    function(const Core: IEmulationCore): TTerminalInputPolicy
    begin
      Result := Default(TTerminalInputPolicy);
      Result.AllKeys := True;
      Result.ExitKey := $1B;
    end;
  RegisterPlatformServices('colecovision', Service);
  RegisterSettingsProfile('ColecoVision', TColecoSettings);
  RegisterPlatformSettingsDevices('colecovision', TPlatformSettingsDevices);
  RegisterPlatformDeviceCallouts('colecovision', TColecoDeviceCallouts);
  RegisterPlatformControlsHelp('colecovision', TColecoControlsHelp);
  RegisterPlatformSettingsHandler('colecovision', TPlatformSettingsHandler);
  RegisterPlatformSessionHandler('colecovision', TPlatformSessionHandler);
  RegisterPlatformInputHandler('colecovision', TColecoInputHandler);
  RegisterPlatformGamepads('colecovision', TGamepadColecoVision,
    [TGamepadDeviceVariant.Create('superaction', TGamepadColecoSuperAction),
      TGamepadDeviceVariant.Create('driving', TGamepadColecoDriving),
      TGamepadDeviceVariant.Create('roller', TGamepadColecoRoller)]);
  RegisterPlatformPresentation('colecovision', 'colecovision', Icon);
  var Definition := TPlatformInputDefinition.Create([TEmulatorButton.Up, TEmulatorButton.Down,
      TEmulatorButton.Left, TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B,
      TEmulatorButton.Start, TEmulatorButton.Select]);
  Definition.PadDevicesOnly := False;
  Definition.LegacyButtons := Definition.Buttons + [TEmulatorButton.X, TEmulatorButton.Y];
  Definition.Devices := [TInputDeviceVariant.Create('superaction', Definition.Buttons + [TEmulatorButton.X, TEmulatorButton.Y]),
      TInputDeviceVariant.Create('driving', [TEmulatorButton.Left, TEmulatorButton.Right, TEmulatorButton.A]),
      TInputDeviceVariant.Create('roller', [TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left,
          TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B])];
  Definition.ButtonNames[TEmulatorButton.A] := 'L';
  Definition.ButtonNames[TEmulatorButton.B] := 'R';
  Definition.ButtonNames[TEmulatorButton.Start] := '1';
  Definition.ButtonNames[TEmulatorButton.Select] := '2';
  Definition.ButtonNames[TEmulatorButton.X] := 'Blue';
  Definition.ButtonNames[TEmulatorButton.Y] := 'Purple';
  Definition.LegacyPorts := 2;
  Definition.LegacySection := 'Keys';
  Definition.AfterLegacyBindings := LoadSharedLegacyBindings;
  Definition.UseSharedBindingRules := True;
  Definition.LoadLegacyKeys := LoadLegacyKeys;
  RegisterPlatformInput('colecovision', Definition);
  FRegistered := True;
end;

end.

