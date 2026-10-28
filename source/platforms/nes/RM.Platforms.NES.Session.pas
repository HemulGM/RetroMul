unit RM.Platforms.NES.Session;

{$I RM.Mobile.inc}

interface

uses
  RM.Session.Runtime;

type
  TNesSessionActivity = record
    Subor, Famicom, Piano, PowerPad, Tape: Boolean;
    function KeyboardActive: Boolean;
  end;

  TNesSessionHandler = class(TPlatformSessionHandler)
  private
    class function Activity(const Context: TSessionRuntimeContext): TNesSessionActivity;
  public
    class function Order: Integer; override;
    class procedure Connect(const Context: TSessionRuntimeContext); override;
    class procedure Disconnect(const Context: TSessionRuntimeContext); override;
    class function InputControls(const Context: TSessionRuntimeContext): TArray<TSessionInputControl>; override;
    class function ExclusiveInput(const Context: TSessionRuntimeContext): Boolean; override;
    class function TouchControl(const Context: TSessionRuntimeContext): TSessionInputControl; override;
    class procedure SyncActivity(const Context: TSessionRuntimeContext); override;
  end;

implementation

uses
  RM.Platforms.NES.Input, System.SysUtils, Core.Platforms.NES.Adapter,
  NES.Controller, RM.Platforms.NES.Keyboard,
  RM.Platforms.NES.Controls.MiraclePiano, RM.Platforms.NES.Controls.PowerPad,
  RM.Platforms.NES.Controls.DataRecorder;

function SessionControl(Control: TNesSuborKeyboard): TSessionInputControl; overload;
begin
  Result := Default(TSessionInputControl);
  if Control <> nil then
    Result := TSessionInputControl.Create(Control, Control.AttachToForm, Control.ReleaseAll);
end;

function SessionControl(Control: TNesFamicomKeyboard): TSessionInputControl; overload;
begin
  Result := Default(TSessionInputControl);
  if Control <> nil then
    Result := TSessionInputControl.Create(Control, Control.AttachToForm, Control.ReleaseAll);
end;

function SessionControl(Control: TNesMiraclePiano): TSessionInputControl; overload;
begin
  Result := Default(TSessionInputControl);
  if Control <> nil then
    Result := TSessionInputControl.Create(Control, Control.AttachToForm, Control.ReleaseAll);
end;

function SessionControl(Control: TGamepadNESPowerPad): TSessionInputControl; overload;
begin
  Result := Default(TSessionInputControl);
  if Control <> nil then
    Result := TSessionInputControl.Create(Control, Control.AttachToForm, Control.ReleaseAll);
end;

function TNesSessionActivity.KeyboardActive: Boolean;
begin
  Result := Subor or Famicom or Piano;
end;

class function TNesSessionHandler.Order: Integer;
begin
  Result := 20;
end;

class function TNesSessionHandler.Activity(const Context: TSessionRuntimeContext): TNesSessionActivity;
var
  Peripheral: INesPeripheralCore;
  Piano: INesMiraclePianoCore;
  Tape: INesTapeCore;
begin
  Result := Default(TNesSessionActivity);
  Result.Subor := (Context.State.Session.Emulation <> nil) and NesUsesSuborKeyboard(Context.State.Session.Emulation);
  Result.Famicom := Supports(Context.State.Session.Emulation, INesPeripheralCore, Peripheral) and Peripheral.UsesFamicomKeyboard;
  Result.Piano := Supports(Context.State.Session.Emulation, INesMiraclePianoCore, Piano) and Piano.UsesMiraclePiano;
  Result.PowerPad := (Peripheral <> nil) and Peripheral.UsesPowerPad and not Result.KeyboardActive;
  Result.Tape := Supports(Context.State.Session.Emulation, INesTapeCore, Tape) and Tape.UsesDataRecorder;
end;

class procedure TNesSessionHandler.Connect(const Context: TSessionRuntimeContext);
var
  Peripheral: INesPeripheralCore;
begin
  var Devices := NesInputState(Context);
  inherited;
  if Supports(Context.State.Session.Emulation, INesPeripheralCore, Peripheral) then
  begin
    Context.View.ImageCanvas.HitTest := True;
    Context.View.ImageCanvas.CanFocus := True;
    Context.View.ImageCanvas.OnKeyDown := Context.View.FormKeyDown;
    Context.View.ImageCanvas.OnKeyUp := Context.View.FormKeyUp;
    Context.View.ImageCanvas.DisableFocusEffect := False;
    Context.View.ImageCanvas.CanParentFocus := True;
    Peripheral.Zapper.OnReadLight :=
      function(const Mask: TNesZapperMask): Boolean
      begin
        Result := TZapper.ReadMask(Mask, Devices.ZapperPixel.X, Devices.ZapperPixel.Y);
      end;
  end;
end;

class procedure TNesSessionHandler.Disconnect(const Context: TSessionRuntimeContext);
var
  Peripheral: INesPeripheralCore;
begin
  var Devices := NesInputState(Context);
  if Supports(Context.State.Session.Emulation, INesPeripheralCore, Peripheral) then
    Peripheral.Zapper.OnReadLight := nil;
  inherited;
  if Devices.DataRecorder <> nil then
  begin
    Devices.DataRecorder.Visible := False;
    Devices.DataRecorder.Enabled := False;
  end;
  {$IFDEF ANDROID}
  Devices.SuborKeyboardTouchAttached := False;
  Devices.FamicomKeyboardTouchAttached := False;
  Devices.MiraclePianoTouchAttached := False;
  Devices.PowerPadTouchAttached := False;
  {$ENDIF}
end;

class function TNesSessionHandler.InputControls(const Context: TSessionRuntimeContext): TArray<TSessionInputControl>;
begin
  var Devices := NesInputState(Context);
  Result := TArray<TSessionInputControl>.Create(SessionControl(Devices.SuborKeyboard),
    SessionControl(Devices.FamicomKeyboard), SessionControl(Devices.MiraclePiano),
    SessionControl(Devices.PowerPad));
end;

class function TNesSessionHandler.ExclusiveInput(const Context: TSessionRuntimeContext): Boolean;
begin
  var Active := Activity(Context);
  Result := Active.KeyboardActive or Active.PowerPad;
end;

class function TNesSessionHandler.TouchControl(const Context: TSessionRuntimeContext): TSessionInputControl;
begin
  var Devices := NesInputState(Context);
  var Active := Activity(Context);
  Result := inherited TouchControl(Context);
  {$IFDEF IOS}
  if Active.PowerPad then
    Result := SessionControl(Devices.PowerPad)
  else if Active.KeyboardActive then
    Result := Default(TSessionInputControl);
  {$ELSE}
  if Active.Piano then
    Result := SessionControl(Devices.MiraclePiano)
  else if Active.PowerPad then
    Result := SessionControl(Devices.PowerPad)
  else if Active.Subor then
    Result := SessionControl(Devices.SuborKeyboard)
  else if Active.Famicom then
    Result := SessionControl(Devices.FamicomKeyboard);
  {$ENDIF}
end;

class procedure TNesSessionHandler.SyncActivity(const Context: TSessionRuntimeContext);
var
  Tape: INesTapeCore;
begin
  var Devices := NesInputState(Context);
  var Active := Activity(Context);
  if Devices.DataRecorder <> nil then
  begin
    Devices.DataRecorder.Visible := Active.Tape;
    Devices.DataRecorder.Enabled := Active.Tape and not Context.State.Session.OpeningRom and not Context.State.Session.EmulationFaulted;
    if Active.Tape and Supports(Context.State.Session.Emulation, INesTapeCore, Tape) then
      Devices.DataRecorder.Progress := Tape.GetTapeProgress;
  end;
  if Devices.MiraclePiano <> nil then
  begin
    Devices.MiraclePiano.Visible := Active.Piano;
    Devices.MiraclePiano.Enabled := Active.Piano and not Context.State.Session.EmulationFaulted and not Context.State.Session.OpeningRom;
  end;
  inherited SyncActivity(Context);
  if Devices.SuborKeyboard <> nil then
  begin
    Devices.SuborKeyboard.Visible := Active.Subor;
    Devices.SuborKeyboard.Enabled := Active.Subor and not Context.State.Session.EmulationFaulted and not Context.State.Session.OpeningRom;
  end;
  if Devices.FamicomKeyboard <> nil then
  begin
    Devices.FamicomKeyboard.Visible := Active.Famicom;
    Devices.FamicomKeyboard.Enabled := Active.Famicom and not Context.State.Session.EmulationFaulted and not Context.State.Session.OpeningRom;
  end;
  {$IFDEF ISMOBILE}
  if Devices.PowerPad <> nil then
  begin
    Devices.PowerPad.Visible := Active.PowerPad;
    Devices.PowerPad.Enabled := Active.PowerPad and not Context.State.Session.EmulationFaulted and not Context.State.Session.OpeningRom;
  end;
  {$ENDIF}
  {$IFDEF ANDROID}
  Devices.SuborKeyboardTouchAttached := Active.Subor;
  Devices.FamicomKeyboardTouchAttached := Active.Famicom;
  Devices.MiraclePianoTouchAttached := Active.Piano;
  Devices.PowerPadTouchAttached := Active.PowerPad;
  {$ENDIF}
end;

end.

