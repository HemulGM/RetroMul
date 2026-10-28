unit RM.Platforms.ZX.Runtime;

interface

uses
  RM.Keyboard.Input, RM.Input.Runtime, RM.Keyboard.Session, RM.Session.Runtime;

type
  TZXInputHandler = class(TKeyboardInputHandler)
  public
    class function KeyPolicy(const Context: TInputRuntimeContext): TInputKeyPolicy; override;
  end;

type
  TZXSessionHandler = class(TKeyboardSessionHandler)
  public
    class function ShowPauseShortcut(const Context: TSessionRuntimeContext): Boolean; override;
    class procedure FrameStatus(const Context: TSessionRuntimeContext); override;
  end;

implementation

uses
  System.UITypes, System.SysUtils, Core.Platforms.ZX.Adapter;

class function TZXInputHandler.KeyPolicy(const Context: TInputRuntimeContext): TInputKeyPolicy;
begin
  Result := inherited KeyPolicy(Context);
  Result.ReserveCaptureShortcuts := True;
  Result.AllowSnapshotsWithKeyboard := True;
  Result.ControlKeys := [vkF7, vkF8, vkF9, vkF10];
end;

class function TZXSessionHandler.ShowPauseShortcut(const Context: TSessionRuntimeContext): Boolean;
begin
  Result := not Context.State.Input.Ports.KeyboardEnabled;
end;

class procedure TZXSessionHandler.FrameStatus(const Context: TSessionRuntimeContext);
var
  Tape: IZXTapeCore;
begin
  if Supports(Context.State.Session.Emulation, IZXTapeCore, Tape) then
  begin
    var Status := Tape.GetTapeStatus;
    if Status <> '' then
      Context.View.SetStatus(Status);
  end;
end;

end.

