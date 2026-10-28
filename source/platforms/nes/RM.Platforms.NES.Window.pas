unit RM.Platforms.NES.Window;

interface

uses
  RM.Window.Layout;

type
  TNesWindowLayout = class(TPlatformWindowLayout)
  public
    class function Controls(const Context: TWindowLayoutContext): TArray<TWindowControlLayout>; override;
  end;

implementation

uses
  RM.Platforms.NES.Input, RM.Platforms.NES.Controls.MiraclePiano,
  RM.Platforms.NES.Controls.DataRecorder, RM.Platforms.NES.Controls.PowerPad,
  RM.Platforms.NES.Keyboard;

class function TNesWindowLayout.Controls(const Context: TWindowLayoutContext): TArray<TWindowControlLayout>;
begin
  var Devices := NesInputState(Context);
  Result := TArray<TWindowControlLayout>.Create(
    TWindowControlLayout.Create(Devices.MiraclePiano, TNesMiraclePiano.PreferredHeight,
      TWindowControlWidth.ClientLayout, 10, 50),
    TWindowControlLayout.Create(Devices.DataRecorder, TNesDataRecorder.PreferredHeight,
      TWindowControlWidth.ClientLayout, 20, -1),
    TWindowControlLayout.Create(Devices.PowerPad, TGamepadNESPowerPad.PreferredHeight,
      TWindowControlWidth.ClientLayout, 30, 10, 20),
    TWindowControlLayout.Create(Devices.SuborKeyboard, TNesSuborKeyboard.PreferredHeight,
      TWindowControlWidth.FormContent, 60, 20),
    TWindowControlLayout.Create(Devices.FamicomKeyboard, TNesFamicomKeyboard.PreferredHeight,
      TWindowControlWidth.FormContent, 70, 40));
end;

end.

