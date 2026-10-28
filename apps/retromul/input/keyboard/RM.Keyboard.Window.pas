unit RM.Keyboard.Window;

interface

uses
  RM.Window.Layout;

type
  TKeyboardWindowLayout = class(TPlatformWindowLayout)
  public
    class function Controls(const Context: TWindowLayoutContext): TArray<TWindowControlLayout>; override;
  end;

implementation

uses
  RM.Keyboard.Input, RM.Keyboard;

class function TKeyboardWindowLayout.Controls(const Context: TWindowLayoutContext): TArray<TWindowControlLayout>;
begin
  var Devices := KeyboardInputState(Context);
  Result := TArray<TWindowControlLayout>.Create(
    TWindowControlLayout.Create(Devices.Keyboard, TScreenKeyboard.PreferredHeight,
      TWindowControlWidth.FormContent, 50, 30));
end;

end.

