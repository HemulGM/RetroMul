unit RM.Platforms.NES.SettingsHandler;

interface

uses
  RM.Settings.Runtime;

type
  TNesSettingsHandler = class(TPlatformSettingsHandler)
  public
    class function HelpInfo(const Context: TSettingsRuntimeContext): TSettingsHelpInfo; override;
    class function Peripherals(const Context: TSettingsRuntimeContext): TArray<TSettingsPeripheral>; override;
  end;

implementation

uses
  RM.Platforms.NES.Input, System.SysUtils, Core.Platforms.NES.Adapter,
  RM.Session.Runtime, RM.Platforms.NES.Controls.PowerPad,
  RM.Platforms.NES.Keyboard, RM.Platforms.NES.Controls.MiraclePiano;

class function TNesSettingsHandler.HelpInfo(const Context: TSettingsRuntimeContext): TSettingsHelpInfo;
var
  Config: INesEmulatorConfig;
  Peripheral: INesPeripheralCore;
  Piano: INesMiraclePianoCore;
begin
  Result := inherited HelpInfo(Context);
  if Supports(Context.State.Session.Emulation.Config, INesEmulatorConfig, Config) and Config.FourScore then
    Result.Players := 4;
  Result.KeyboardPeripheral := NesUsesSuborKeyboard(Context.State.Session.Emulation) or
    (Supports(Context.State.Session.Emulation, INesPeripheralCore, Peripheral) and Peripheral.UsesFamicomKeyboard) or
    (Supports(Context.State.Session.Emulation, INesMiraclePianoCore, Piano) and Piano.UsesMiraclePiano);
end;

class function TNesSettingsHandler.Peripherals(const Context: TSettingsRuntimeContext): TArray<TSettingsPeripheral>;
begin
  var Devices := NesInputState(Context);
  SetLength(Result, 4);
  var PowerPad := Devices.PowerPad;
  if PowerPad <> nil then
    Result[0] := TSettingsPeripheral.Create(TSessionInputControl.Create(PowerPad, PowerPad.AttachToForm, PowerPad.ReleaseAll), 10, 10);
  var Subor := Devices.SuborKeyboard;
  if Subor <> nil then
    Result[1] := TSettingsPeripheral.Create(TSessionInputControl.Create(Subor, Subor.AttachToForm, Subor.ReleaseAll), 20, 20);
  var Famicom := Devices.FamicomKeyboard;
  if Famicom <> nil then
    Result[2] := TSettingsPeripheral.Create(TSessionInputControl.Create(Famicom, Famicom.AttachToForm, Famicom.ReleaseAll), 30, 40);
  var Piano := Devices.MiraclePiano;
  if Piano <> nil then
    Result[3] := TSettingsPeripheral.Create(TSessionInputControl.Create(Piano, Piano.AttachToForm, Piano.ReleaseAll), 40, 50);
end;

end.

