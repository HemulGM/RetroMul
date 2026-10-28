unit RM.Keyboard.Session;

{$I RM.Mobile.inc}

interface

uses
  Core.Input.Keyboard, RM.Session.Runtime;

type
  TKeyboardSessionHandler = class(TPlatformSessionHandler)
  public
    class function Order: Integer; override;
    class function InputControls(const Context: TSessionRuntimeContext): TArray<TSessionInputControl>; override;
    class function ExclusiveInput(const Context: TSessionRuntimeContext): Boolean; override;
    class function TouchControl(const Context: TSessionRuntimeContext): TSessionInputControl; override;
    class procedure SyncActivity(const Context: TSessionRuntimeContext); override;
    class procedure Disconnect(const Context: TSessionRuntimeContext); override;
  end;

implementation

uses
  RM.Keyboard.Input, System.SysUtils, RM.Dialogs, RM.Keyboard;

function SessionControl(Control: TScreenKeyboard): TSessionInputControl;
begin
  Result := Default(TSessionInputControl);
  if Control <> nil then
    Result := TSessionInputControl.Create(Control, Control.AttachToForm, Control.ReleaseAll);
end;

class function TKeyboardSessionHandler.Order: Integer;
begin
  Result := 10;
end;



class function TKeyboardSessionHandler.InputControls(const Context: TSessionRuntimeContext): TArray<TSessionInputControl>;
begin
  var Devices := KeyboardInputState(Context);
  Result := TArray<TSessionInputControl>.Create(SessionControl(Devices.Keyboard));
end;

class function TKeyboardSessionHandler.ExclusiveInput(const Context: TSessionRuntimeContext): Boolean;
var
  Keyboard: IEmulationKeyboard;
begin
  Result := Supports(Context.State.Session.Emulation, IEmulationKeyboard, Keyboard) and Keyboard.HasKeyboard;
end;

class function TKeyboardSessionHandler.TouchControl(const Context: TSessionRuntimeContext): TSessionInputControl;
begin
  var Devices := KeyboardInputState(Context);
  Result := inherited TouchControl(Context);
  if ExclusiveInput(Context) then
    {$IFDEF IOS}
    Result := Default(TSessionInputControl);{$ELSE}
  Result := SessionControl(Devices.Keyboard);{$ENDIF}
end;

class procedure TKeyboardSessionHandler.SyncActivity(const Context: TSessionRuntimeContext);
begin
  var Devices := KeyboardInputState(Context);
  var Active := ExclusiveInput(Context);
  if Devices.Keyboard <> nil then
  begin
    Devices.Keyboard.Visible := Active;
    Devices.Keyboard.Enabled := Active and not Context.State.Session.EmulationFaulted and
      not Context.State.Session.OpeningRom and not Context.State.Browser.ViewingLibrary and
      (Context.State.Settings.View = nil) and (Context.State.Help.View = nil) and not RetroDialogVisible(Context.View);
  end;
  {$IFDEF ANDROID}    Devices.TouchAttached := Active;{$ENDIF}
  inherited SyncActivity(Context);
end;

class procedure TKeyboardSessionHandler.Disconnect(const Context: TSessionRuntimeContext);
begin
  inherited;
  {$IFDEF ANDROID}
  var Devices := KeyboardInputState(Context, False);
  if Devices <> nil then Devices.TouchAttached := False;
  {$ENDIF}
end;



end.

