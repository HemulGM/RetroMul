unit RM.Keyboard.Settings;

interface

uses
  Core.Input.Keyboard, RM.Settings.Runtime;

type
  TKeyboardSettingsHandler = class(TPlatformSettingsHandler)
  public
    class function HelpInfo(const Context: TSettingsRuntimeContext): TSettingsHelpInfo; override;
    class function Peripherals(const Context: TSettingsRuntimeContext): TArray<TSettingsPeripheral>; override;
  end;

implementation

uses
  RM.Keyboard.Input, System.SysUtils, RM.Keyboard, RM.Session.Runtime;

class function TKeyboardSettingsHandler.HelpInfo(const Context: TSettingsRuntimeContext): TSettingsHelpInfo;
var
  Keyboard: IEmulationKeyboard;
begin
  Result := inherited HelpInfo(Context);
  Result.KeyboardPeripheral := Supports(Context.State.Session.Emulation, IEmulationKeyboard, Keyboard) and Keyboard.HasKeyboard;
end;

class function TKeyboardSettingsHandler.Peripherals(const Context: TSettingsRuntimeContext): TArray<TSettingsPeripheral>;
begin
  var Devices := KeyboardInputState(Context);
  Result := nil;
  var Keyboard := Devices.Keyboard;
  if Keyboard <> nil then
    Result := TArray<TSettingsPeripheral>.Create(TSettingsPeripheral.Create(
        TSessionInputControl.Create(Keyboard, Keyboard.AttachToForm, Keyboard.ReleaseAll), 50, 30));
end;

end.

