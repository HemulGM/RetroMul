unit RM.Controllers.Input;

{$I ..\RM.Mobile.inc}

interface

uses
  System.Classes, System.UITypes, Core.Emulation, NES.DataRecorder,
  NES.FamicomDataRecorder, RM.Controllers.Base
  {$IF not Defined(LINUX)}
    , System.Sensors
  {$ENDIF};

type
  TInputController = class(TMainController)
  public
    procedure InitializePeripherals;
    procedure PollRumble;
    procedure SyncMotionSensor;
    procedure PollMotionSensor;
    {$IF not Defined(LINUX)}
    procedure ChooseMotionSensor(Sender: TObject; const Sensors: TSensorArray; var ChoseSensorIndex: Integer);
    {$ENDIF}
    procedure LoadHostInput(const SystemId: string);
    procedure ReloadHostInputBindings;
    procedure PollHostInput;
    procedure FormKeyDown(Sender: TObject; var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
    procedure FormKeyUp(Sender: TObject; var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
    procedure ForwardKeyState(Code: Word; Pressed: Boolean);
    procedure GamepadChanged(Sender: TObject);
    function CombinedGamepadInput: TEmulatorInput;
    procedure UpdatePeripheralInput;
    procedure UpdatePeripheralFeedback;
    procedure MiraclePianoChanged(Sender: TObject);
    procedure FamicomKeyboardChanged(Sender: TObject);
    procedure SuborKeyboardChanged(Sender: TObject);
    procedure SGKeyboardChanged(Sender: TObject);
    procedure SuborKeyboardPower(Sender: TObject);
    procedure PowerPadChanged(Sender: TObject);
    procedure ImageCanvasMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Single);
    procedure ImageCanvasMouseUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Single);
    procedure TapeAction(Sender: TObject; Action: TTapeAction; const FileName: string);
    procedure SelectTapeFile(const FileName: string);
    procedure ChooseTapeFile(Sender: TObject);
    procedure SaveTapeAs(Sender: TObject);
  end;

implementation

uses
  System.SysUtils, System.Types, System.IOUtils, System.Math, FMX.Types,
  FMX.Forms, FMX.Objects, FMX.Dialogs, FMX.Platform, FMX.Edit, FMX.OpenDialog,
  FMXInput, RM.Input, RM.Rumble, Core.Adapter.NES, Core.Adapter.N64, N64.Console,
  Core.Adapter.PS1, PS1.SIO, Core.Adapter.PS2, Core.InputConfig, Core.RomFormat,
  Core.Adapter.SG1000, SG1000.Keyboard, NES.Controller, RM.Gamepad,
  NES.SuborKeyboard, NES.FamicomKeyboard, NES.MiraclePiano, NES.PowerPad,
  RM.Dialogs, RM.Styles, Core.Adapter.DC
  {$IFDEF MSWINDOWS}
    , Winapi.Windows
  {$ENDIF}
  {$IF not Defined(LINUX)}
    , System.Sensors.Components
  {$ENDIF}
  {$IFDEF ANDROID}
    , Androidapi.Helpers, Androidapi.JNI.GraphicsContentViewText,
    RM.DocumentTransfer.Android
  {$ENDIF};

function HostKeyCode(Key: Word; KeyChar: WideChar): Word;
begin
  // Some FMX backends report printable keys through KeyChar alone.
  // Preserve native codes (including numpad keys); use the same fallback
  // on down and up so lowercase/uppercase characters address one held key.
  if Key <> 0 then
    Exit(Key);

  case KeyChar of
    'a'..'z':
      Result := Ord(KeyChar) - Ord('a') + vkA;
    'A'..'Z', '0'..'9':
      Result := Ord(KeyChar);
    ' ':
      Result := vkSpace;
    '!':
      Result := vk1;
    '@':
      Result := vk2;
    '#':
      Result := vk3;
    '$':
      Result := vk4;
    '%':
      Result := vk5;
    '^':
      Result := vk6;
    '&':
      Result := vk7;
    '*':
      Result := vk8;
    '(':
      Result := vk9;
    ')':
      Result := vk0;
    ';', ':':
      Result := vkSemicolon;
    '=', '+':
      Result := vkEqual;
    ',', '<':
      Result := vkComma;
    '-', '_':
      Result := vkMinus;
    '.', '>':
      Result := vkPeriod;
    '/', '?':
      Result := vkSlash;
    '`', '~':
      Result := vkTilde;
    '[', '{':
      Result := vkLeftBracket;
    '\', '|':
      Result := vkBackslash;
    ']', '}':
      Result := vkRightBracket;
    '''', '"':
      Result := vkQuote;
  else
    Result := 0;
  end;
end;

function TryGetImagePixel(const Image: TImage; const X, Y: Single; out PixelX, PixelY: Integer): Boolean;
begin
  Result := False;
  PixelX := -1;
  PixelY := -1;

  if (Image.Width <= 0) or (Image.Height <= 0) or (Image.Bitmap.Width <= 0) or (Image.Bitmap.Height <= 0) then
    Exit;

  var Scale := Min(Image.Width / Image.Bitmap.Width, Image.Height / Image.Bitmap.Height);
  var DrawWidth := Image.Bitmap.Width * Scale;
  var DrawHeight := Image.Bitmap.Height * Scale;
  var Left := (Image.Width - DrawWidth) / 2;
  var Top := (Image.Height - DrawHeight) / 2;

  if (X < Left) or (Y < Top) or (X >= Left + DrawWidth) or (Y >= Top + DrawHeight) then
    Exit;

  PixelX := Min(Image.Bitmap.Width - 1, Floor((X - Left) / Scale));
  PixelY := Min(Image.Bitmap.Height - 1, Floor((Y - Top) / Scale));
  Result := True;
end;

procedure TInputController.InitializePeripherals;
begin
  FState.Input.Gamepad := TScreenGamepad.Create(FView);
  FState.Input.Gamepad.Name := 'ScreenGamepad';
  FState.Input.Gamepad.Parent := FView.LayoutClient;
  FState.Input.Gamepad.Align := TAlignLayout.Bottom;
  FState.Input.Gamepad.OnChange := FView.GamepadChanged;
  FState.Input.Gamepad.Enabled := False;
  FState.Input.Gamepad.Visible := False;
  FState.Input.Gamepad.Margins.Bottom := 100;

  FState.Input.SGKeyboard := TSGKeyboard.Create(FView);
  FState.Input.SGKeyboard.Parent := FView.LayoutClient;
  FState.Input.SGKeyboard.Align := TAlignLayout.Bottom;
  FState.Input.SGKeyboard.OnChange := SGKeyboardChanged;
  FState.Input.SGKeyboard.Enabled := False;
  FState.Input.SGKeyboard.Visible := False;

  FState.Input.SuborKeyboard := TNesSuborKeyboard.Create(FView);
  FState.Input.SuborKeyboard.Name := 'ScreenSuborKeyboard';
  FState.Input.SuborKeyboard.Parent := FView.LayoutClient;
  FState.Input.SuborKeyboard.Align := TAlignLayout.Bottom;
  FState.Input.SuborKeyboard.OnChange := FView.SuborKeyboardChanged;
  FState.Input.SuborKeyboard.OnPower := FView.SuborKeyboardPower;
  FState.Input.SuborKeyboard.OnReset := FView.SuborKeyboardPower;
  FState.Input.SuborKeyboard.Enabled := False;
  FState.Input.SuborKeyboard.Visible := False;

  FState.Input.FamicomKeyboard := TNesFamicomKeyboard.Create(FView);
  FState.Input.FamicomKeyboard.Name := 'ScreenFamicomKeyboard';
  FState.Input.FamicomKeyboard.Parent := FView.LayoutClient;
  FState.Input.FamicomKeyboard.Align := TAlignLayout.Bottom;
  FState.Input.FamicomKeyboard.OnChange := FView.FamicomKeyboardChanged;
  FState.Input.FamicomKeyboard.Enabled := False;
  FState.Input.FamicomKeyboard.Visible := False;

  FState.Input.MiraclePiano := TNesMiraclePiano.Create(FView);
  FState.Input.MiraclePiano.Name := 'ScreenMiraclePiano';
  FState.Input.MiraclePiano.Parent := FView.LayoutClient;
  FState.Input.MiraclePiano.Align := TAlignLayout.Bottom;
  FState.Input.MiraclePiano.OnChange := FView.MiraclePianoChanged;
  FState.Input.MiraclePiano.Enabled := False;
  FState.Input.MiraclePiano.Visible := False;

  FState.Input.PowerPad := TNesPowerPad.Create(FView);
  FState.Input.PowerPad.Name := 'ScreenPowerPad';
  FState.Input.PowerPad.Parent := FView.LayoutClient;
  FState.Input.PowerPad.Align := TAlignLayout.Bottom;
  FState.Input.PowerPad.OnChange := FView.PowerPadChanged;
  FState.Input.PowerPad.Enabled := False;
  FState.Input.PowerPad.Visible := False;
  FState.Input.PowerPad.Margins.Bottom := 100;

  FState.Input.DataRecorder := TNesDataRecorder.Create(FView);
  FState.Input.DataRecorder.Name := 'ScreenDataRecorder';
  FState.Input.DataRecorder.Parent := FView.LayoutClient;
  FState.Input.DataRecorder.Align := TAlignLayout.Bottom;
  FState.Input.DataRecorder.OnAction := FView.TapeAction;
  FState.Input.DataRecorder.OnChooseFile := FView.ChooseTapeFile;
  FState.Input.DataRecorder.OnSaveAs := FView.SaveTapeAs;
  FState.Input.DataRecorder.Visible := False;
  FState.Input.DataRecorder.Enabled := False;
end;

procedure TInputController.PollRumble;
begin
  if FState.Input.Rumble = nil then
    Exit;

  var Level: Byte := 0;
  var Rumble: IEmulationRumbleOutput;
  if (FState.Session.Emulation <> nil) and not FState.Session.EmulationFaulted and not FState.Session.OpeningRom and
    not FState.Browser.ViewingLibrary and (FState.Settings.View = nil) and (FState.Help.View = nil) and
    not RetroDialogVisible(FView) and FView.InputHasFocus and
    {$IFDEF ISMOBILE}not FState.Mobile.InBackground and {$ENDIF}
    not FState.Session.Emulation.IsPaused and Supports(FState.Session.Emulation, IEmulationRumbleOutput, Rumble) and
    Rumble.HasRumble then
    Level := Rumble.RumbleLevel;

  // No device search is needed for a silent, paused or absent core.
  if Level <> 0 then
  begin
    if FState.Input.Manager <> nil then
    begin
      var DeviceId := RumbleDeviceId(FState.Input.Manager, 0);
      if DeviceId <> FState.Input.RumbleDeviceId then
      begin
        FState.Input.RumbleDeviceId := DeviceId;
        FState.Input.Rumble.SetDevice(CreateGamepadRumbleDevice(FState.Input.Manager, DeviceId));
      end;
    end;
  end;
  FState.Input.Rumble.Update(Level, TThread.GetTickCount64);
end;

procedure TInputController.SyncMotionSensor;
begin
  {$IF not Defined(LINUX)}
  if FState.Input.MotionSensor = nil then
    Exit;

  var Motion: IEmulationMotionInput;
  var RotationInput: IEmulationRotationInput;
  var WantsRotation := Supports(FState.Session.Emulation, IEmulationRotationInput, RotationInput) and RotationInput.HasGyroscope;
  var Wanted := Supports(FState.Session.Emulation, IEmulationMotionInput, Motion);
  if Wanted then
    Wanted := Motion.HasAccelerometer;
  Wanted := (Wanted or WantsRotation) and not FState.Session.OpeningRom and not FState.Session.EmulationFaulted and not FState.Session.UserPaused and
    not FState.Session.AutoPaused and not FState.Browser.ViewingLibrary and (FState.Settings.View = nil) and
    (FState.Help.View = nil) and not RetroDialogVisible(FView);
  {$IFDEF ISMOBILE}
  Wanted := Wanted and not FState.Mobile.InBackground;
  {$ENDIF}

  if not Wanted then
  begin
    if FState.Input.MotionAttempted then
    begin
      try
        FState.Input.MotionSensor.Active := False;
      except
      end;
      FState.Input.MotionAttempted := False;
    end;
    if Motion <> nil then
      Motion.SetAcceleration(0, 0);
    if RotationInput <> nil then
      RotationInput.SetRotation(0);
  end
  else if not FState.Input.MotionAttempted then
  begin
    FState.Input.MotionAttempted := True;
    try
      FState.Input.MotionSensor.Active := True;
    except
      // Desktop machines commonly have no accelerometer. Keep neutral input
      // and avoid retrying a failed sensor every frame.
      try
        FState.Input.MotionSensor.Active := False;
      except
      end;
      if Motion <> nil then
        Motion.SetAcceleration(0, 0);
      if RotationInput <> nil then
        RotationInput.SetRotation(0);
    end;
  end;
  {$ENDIF}
end;

procedure TInputController.PollMotionSensor;
begin
  FView.SyncMotionSensor;
  {$IF not Defined(LINUX)}
  var RotationInput: IEmulationRotationInput;
  if Supports(FState.Session.Emulation, IEmulationRotationInput, RotationInput) and RotationInput.HasGyroscope then
  begin
    var Value: Double := 0;
    if (FState.Input.MotionSensor <> nil) and FState.Input.MotionSensor.Active and (FState.Input.MotionSensor.Sensor <> nil) then
    try
      Value := FState.Input.MotionSensor.Sensor.AngleAccelZ;

      // Android's RTL returns the native gyroscope value in radians/second.
      {$IFDEF ANDROID}
      Value := Value / Pi;
      {$ELSE}
      Value := Value / 180;
      {$ENDIF}

      if IsNan(Value) or IsInfinite(Value) then
        Value := 0;
    except
      Value := 0;
    end;
    RotationInput.SetRotation(Value);
    Exit;
  end;

  var Motion: IEmulationMotionInput;
  if not Supports(FState.Session.Emulation, IEmulationMotionInput, Motion) or not Motion.HasAccelerometer then
    Exit;

  var X, Y: Double;
  X := 0;
  Y := 0;
  if (FState.Input.MotionSensor <> nil) and FState.Input.MotionSensor.Active and (FState.Input.MotionSensor.Sensor <> nil) then
  try
    // System.Sensors normalizes Android and iOS acceleration to g.
    X := FState.Input.MotionSensor.Sensor.AccelerationX;
    Y := FState.Input.MotionSensor.Sensor.AccelerationY;
    {$IF Defined(ANDROID) or Defined(IOS)} // Native sensor orientation.
    var Rotation := 0;
    {$IFDEF ANDROID}
    // Android sensor axes follow the device's natural orientation, which
    // can be landscape on tablets. Use display rotation rather than shape.
    if TAndroidHelper.Display <> nil then
      Rotation := TAndroidHelper.Display.getRotation;
    {$ELSE}
    var ScreenService: IFMXScreenService;
    if TPlatformServices.Current.SupportsPlatformService(IFMXScreenService, ScreenService) then
      case ScreenService.GetScreenOrientation of
        TScreenOrientation.Landscape:
          Rotation := 1;
        TScreenOrientation.InvertedPortrait:
          Rotation := 2;
        TScreenOrientation.InvertedLandscape:
          Rotation := 3;
      end;
    {$ENDIF}
    var OriginalX := X;
    case Rotation of
      1:
        begin
          X := -Y;
          Y := OriginalX;
        end;
      2:
        begin
          X := -X;
          Y := -Y;
        end;
      3:
        begin
          X := Y;
          Y := -OriginalX;
        end;
    end;
    {$ENDIF}
  except
    X := 0;
    Y := 0;
    try
      FState.Input.MotionSensor.Active := False;
    except
    end;
  end;
  Motion.SetAcceleration(X, Y);
  {$ENDIF}
end;

{$IF not Defined(LINUX)}
procedure TInputController.ChooseMotionSensor(Sender: TObject; const Sensors: TSensorArray; var ChoseSensorIndex: Integer);
begin
  ChoseSensorIndex := -1;
  var Desired := TMotionSensorType.Accelerometer3D;
  var RotationInput: IEmulationRotationInput;
  if Supports(FState.Session.Emulation, IEmulationRotationInput, RotationInput) and RotationInput.HasGyroscope then
    Desired := TMotionSensorType.Gyrometer3D;
  for var i := 0 to High(Sensors) do
    if (Sensors[i] is TCustomMotionSensor) and (TCustomMotionSensor(Sensors[i]).SensorType = Desired) then
    begin
      ChoseSensorIndex := i;
      Break;
    end;
end;
{$ENDIF}

procedure TInputController.LoadHostInput(const SystemId: string);
begin
  FState.Input.SystemId := SystemId;
  FState.Input.Ports := LoadCoreInputPorts(FState.Session.Storage, SystemId);
  FView.ReloadHostInputBindings;
end;

procedure TInputController.ReloadHostInputBindings;
begin
  if FState.Input.Manager = nil then
    Exit;

  // Assignments belong to the active game, independently of the settings page.
  // Connection changes are applied separately on the owning emulation thread.
  var Ini := FState.Session.Storage.ReadConfig(FState.Session.Storage.ConfigFile(FState.Input.SystemId));
  try
    LoadInputBindings(FState.Input.Manager, Ini, FState.Input.SystemId);
    FilterInputBindings(FState.Input.Manager, Ini);
    FState.Input.PollingFailed := False;
  finally
    Ini.Free;
  end;
  FState.Input.SuppressInputUntilRelease := True;
  FillChar(FState.Input.KeysDown, SizeOf(FState.Input.KeysDown), 0);
  if FState.Session.Emulation <> nil then
    FState.Session.Emulation.ClearInput;
end;

procedure TInputController.PollHostInput;
begin
  var MouseInput: IEmulationMouseInput;
  var HasMouse := Supports(FState.Session.Emulation, IEmulationMouseInput, MouseInput);
  if HasMouse and ((FState.Input.Manager = nil) or FState.Input.PollingFailed or not FView.InputHasFocus or
    FState.Session.OpeningRom or (FState.Settings.View <> nil) or FState.Browser.ViewingLibrary or
    (FState.Help.View <> nil) or FState.Session.Emulation.IsPaused or FState.Session.EmulationFaulted or
    RetroDialogVisible(FView) or ((FView.Focused <> nil) and (FView.Focused.GetObject is TCustomEdit))) then
    MouseInput.SendMouseDelta(0, 0, 0);
  if (FState.Input.Manager = nil) or FState.Input.PollingFailed then
    Exit;

  FState.Input.Manager.Enabled := FView.InputHasFocus and not FState.Session.OpeningRom;
  if not FState.Input.Manager.Enabled then
    Exit;

  FState.Input.Manager.Poll;
  if RetroDialogVisible(FView) then
    Exit;

  if FState.Settings.View <> nil then
  begin
    FState.Settings.View.Poll;
    Exit;
  end;

  if not FState.Input.Manager.Enabled then
    Exit;

  if FState.Browser.ViewingLibrary then
    Exit;

  if (FView.Focused <> nil) and (FView.Focused.GetObject is TCustomEdit) then
  begin
    if FState.Session.Emulation <> nil then
      FState.Session.Emulation.ClearInput;
    FState.Input.SuppressInputUntilRelease := True;
    FillChar(FState.Input.KeysDown, SizeOf(FState.Input.KeysDown), 0);
    Exit;
  end;

  var Keys := ReadHostKeys(FState.Input.Manager);
  if FState.Input.SuppressInputUntilRelease then
  begin
    for var V in FState.Input.Manager.Values do
      if (V.Kind in [TInputElementKind.Key, TInputElementKind.Button]) and (V.Value > 0.5) then
        Exit;

    FState.Input.SuppressInputUntilRelease := False;
  end;

  var Shift: TShiftState := [];
  if Keys[vkShift] then
    Include(Shift, ssShift);
  if Keys[vkControl] then
    Include(Shift, ssCtrl);
  if Keys[vkMenu] then
    Include(Shift, ssAlt);

  FState.Input.DispatchingInput := True;
  try
    for var i := 1 to High(Keys) do
      if Keys[i] <> FState.Input.KeysDown[i] then
      begin
        var Code := Word(i);
        var Ch: WideChar := #0;
        if Keys[i] then
          FView.FormKeyDown(FView, Code, Ch, Shift)
        else
          FView.FormKeyUp(FView, Code, Ch, Shift);
      end;
  finally
    FState.Input.DispatchingInput := False;
  end;

  if (FState.Help.View <> nil) or (FState.Session.Emulation = nil) or FState.Session.Emulation.IsPaused or FState.Session.EmulationFaulted then
    Exit;

  var Input := FView.CombinedGamepadInput;
  if (ssCtrl in Shift) then
    Input := Default(TEmulatorInput);
  FState.Session.Emulation.SetGamepadInput(Input);
  if HasMouse then
  begin
    var DX, DY: Integer;
    var Buttons: Byte;
    ReadRelativeMouse(FState.Input.Manager, DX, DY, Buttons);
    MouseInput.SendMouseDelta(DX, DY, Buttons);
  end;
  var PointerInput: IEmulationPointerInput;
  if Supports(FState.Session.Emulation, IEmulationPointerInput, PointerInput) and PointerInput.UsesPointer then
  begin
    var PixelX := 0;
    var PixelY := 0;
    var Valid := False;
    var Mouse: IFMXMouseService;
    if TPlatformServices.Current.SupportsPlatformService(IFMXMouseService, Mouse) then
    begin
      var Point := FView.ImageCanvas.AbsoluteToLocal(FView.ScreenToClient(Mouse.GetMousePos));
      Valid := TryGetImagePixel(FView.ImageCanvas, Point.X, Point.Y, PixelX, PixelY);
    end;
    PointerInput.SetPointer(PixelX, PixelY, Valid);
  end;
  FView.UpdatePeripheralInput;
  var Peripheral: INesPeripheralCore;
  if Supports(FState.Session.Emulation, INesPeripheralCore, Peripheral) then
  begin
    if Peripheral.Zapper.Enabled then
    begin
      var Mouse: IFMXMouseService;
      if TPlatformServices.Current.SupportsPlatformService(IFMXMouseService, Mouse) then
      begin
        var Point := FView.ImageCanvas.AbsoluteToLocal(FView.ScreenToClient(Mouse.GetMousePos));
        TryGetImagePixel(FView.ImageCanvas, Point.X, Point.Y, FState.Input.ZapperPixel.X, FState.Input.ZapperPixel.Y);
      end;
      Peripheral.Zapper.TriggerPressed := FState.Input.Manager.IsPressed(ZapperTriggerAction);
    end;
  end;
end;

procedure TInputController.FormKeyDown(Sender: TObject; var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
begin
  if RetroDialogVisible(FView) then
    Exit;

  if (FState.Settings.View <> nil) or FState.Browser.ViewingLibrary then
    Exit;

  if (FState.Input.Manager <> nil) and (FState.Session.Emulation <> nil) and not FState.Input.DispatchingInput then
  begin
    if (FState.Session.Emulation <> nil) and ((FView.Focused = nil) or not (FView.Focused.GetObject is TCustomEdit)) then
    begin
      Key := 0;
      KeyChar := #0;
    end;
    Exit;
  end;

  Key := HostKeyCode(Key, KeyChar);
  if Key in [vkVolumeUp, vkVolumeDown, vkVolumeMute] then
    Exit;

  if Key = 0 then
  begin
    KeyChar := #0;
    Exit;
  end;

  var Code: Word := Key;
  var SuborKeyboardActive := (FState.Session.Emulation <> nil) and FState.Session.Emulation.UsesSuborKeyboard;
  var Peripheral: INesPeripheralCore;
  var Piano: INesMiraclePianoCore;
  var SGKeyboard: ISGKeyboardCore;
  var KeyboardActive := (Supports(FState.Session.Emulation, ISGKeyboardCore, SGKeyboard) and SGKeyboard.HasKeyboard) or SuborKeyboardActive or
    (Supports(FState.Session.Emulation, INesPeripheralCore, Peripheral) and Peripheral.UsesFamicomKeyboard) or
    (Supports(FState.Session.Emulation, INesMiraclePianoCore, Piano) and Piano.UsesMiraclePiano);

  var ZXActive := FState.Input.SystemId = ROM_SYSTEM_ZX;

  var WasDown: Boolean := False;
  if Code <= High(FState.Input.KeysDown) then
  begin
    WasDown := FState.Input.KeysDown[Code];
    FState.Input.KeysDown[Code] := True;
  end;

  if not WasDown then
  begin
    if FState.Help.View <> nil then
    begin
      if Code in [vkEscape, vkF1] then
        FView.ControlsHelpClose(FView);
      Key := 0;
      KeyChar := #0;
      Exit;
    end
    else if Code = vkF1 then
    begin
      FView.ControlsHelpClick(FView);
      Key := 0;
      KeyChar := #0;
      Exit;
    end
    else if (Code = vkEscape) and (FView.FullScreen or not KeyboardActive) then
    begin
      if FView.FullScreen then
        FView.SwitchFullScreen
    end
    else if (Code = vkF11) then
      FView.SwitchFullScreen
    else if (Code = vkO) and (ssCtrl in Shift) and not KeyboardActive then
      FView.OpenRom
    else if (Code = vkR) and (FState.Session.Emulation <> nil) and not KeyboardActive then
    begin
      if ssShift in Shift then
      begin
        FView.ResetConsole(True);
        // InstallCore clears held keys; keep this shortcut down until key-up.
        FState.Input.KeysDown[Code] := True;
        Key := 0;
        KeyChar := #0;
        Exit;
      end;
      FView.ResetConsole(False);
    end
    else if (Code = vkP) and not KeyboardActive then
      FView.SwitchPause
    else if (Code = vkF9) and not KeyboardActive and not ZXActive then
      FView.InsertCoinClick(FView)
    else if (Code = vkF8) and (FState.Session.Emulation <> nil) and not KeyboardActive and not ZXActive then
    begin
      try
        FView.SetStatus(Translate('Screenshot: ') + FView.SaveScreenshot);
      except
        on E: Exception do
          ShowRetroMessage(FView, E.Message);
      end;
    end
    else if (Code in [vkF5, vkF6]) and (FState.Session.Emulation <> nil) and (not KeyboardActive or ZXActive) then
    begin
      try
        if Code = vkF5 then
          FView.SaveSnapshot('Quick')
        else
          FView.LoadSnapshot('Quick');
      except
        on E: Exception do
          ShowRetroMessage(FView, Translate('Snapshot: ') + E.Message);
      end;
    end;
  end;

  var ZXControlKey := ZXActive and (Code in [vkF7, vkF8, vkF9, vkF10]);
  if (FState.Help.View = nil) and (KeyboardActive or not (ssCtrl in Shift) or ZXControlKey) then
    if (FState.Session.Emulation <> nil) and ((FState.Input.Manager = nil) or ZXControlKey or ((SGKeyboard <> nil) and SGKeyboard.HasKeyboard)) then
      FView.ForwardKeyState(Code, True);

  Key := 0;
  KeyChar := #0;
end;

procedure TInputController.FormKeyUp(Sender: TObject; var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
begin
  if RetroDialogVisible(FView) then
  begin
    {$IFDEF ANDROID}
    if Key = vkHardwareBack then
      HandleRetroDialogKey(FView, Key, KeyChar);
    {$ENDIF}
    Key := 0;
    KeyChar := #0;
    Exit;
  end;

  {$IFDEF ANDROID}
  if Key = vkHardwareBack then
  begin
    if FState.Help.View <> nil then
      FView.ControlsHelpClose(FView)
    else if FState.Settings.View <> nil then
      FView.SettingsClose(FView)
    else if not FState.Browser.ViewingLibrary then
      FView.LibraryBack(FView)
    else if (FState.Browser.View <> nil) and FState.Browser.View.CloseDetails then
    begin
      // Close the compact game details before leaving the library.
    end
    else
      Exit;
    Key := 0;
    KeyChar := #0;
    Exit;
  end;
  {$ENDIF}

  if FState.Browser.ViewingLibrary and (Key = vkEscape) and
    (FState.Browser.View <> nil) and FState.Browser.View.CloseDetails then
  begin
    Key := 0;
    KeyChar := #0;
    Exit;
  end;

  if (FState.Settings.View <> nil) or FState.Browser.ViewingLibrary then
    Exit;

  if (FState.Input.Manager <> nil) and (FState.Session.Emulation <> nil) and not FState.Input.DispatchingInput then
  begin
    if (FState.Session.Emulation <> nil) and ((FView.Focused = nil) or not (FView.Focused.GetObject is TCustomEdit)) then
    begin
      Key := 0;
      KeyChar := #0;
    end;
    Exit;
  end;

  Key := HostKeyCode(Key, KeyChar);
  if Key in [vkVolumeUp, vkVolumeDown, vkVolumeMute] then
    Exit;

  if Key = 0 then
  begin
    KeyChar := #0;
    Exit;
  end;

  var Code: Word := Key;
  if Code <= High(FState.Input.KeysDown) then
    FState.Input.KeysDown[Code] := False;

  var SGKeyboard: ISGKeyboardCore;
  if (FState.Help.View = nil) and (FState.Session.Emulation <> nil) and
    ((FState.Input.Manager = nil) or ((FState.Input.SystemId = ROM_SYSTEM_ZX) and (Code in [vkF7, vkF8, vkF9, vkF10])) or
    (Supports(FState.Session.Emulation, ISGKeyboardCore, SGKeyboard) and SGKeyboard.HasKeyboard)) then
    FView.ForwardKeyState(Code, False);

  Key := 0;
  KeyChar := #0;
end;

procedure TInputController.ForwardKeyState(Code: Word; Pressed: Boolean);
begin
  if FState.Session.Emulation = nil then
    Exit;

  {$IFDEF MSWINDOWS}
  // Windows FMX reports generic Shift. HVC-007 has two separate contacts.
  var Peripheral: INesPeripheralCore;
  if (FState.Input.Manager = nil) and (Code = vkShift) and Supports(FState.Session.Emulation, INesPeripheralCore, Peripheral) and Peripheral.UsesFamicomKeyboard then
  begin
    FState.Session.Emulation.SetKeyState(vkLShift, Winapi.Windows.GetKeyState(vkLShift) < 0);
    FState.Session.Emulation.SetKeyState(vkRShift, Winapi.Windows.GetKeyState(vkRShift) < 0);
    Exit;
  end;
  {$ENDIF}
  FState.Session.Emulation.SetKeyState(Code, Pressed);
end;

procedure TInputController.GamepadChanged(Sender: TObject);
begin
  FState.Input.GamepadInput.Buttons := FState.Input.Gamepad.Buttons;
  FState.Input.GamepadInput.Analog[0] := FState.Input.Gamepad.AnalogInput;
  if FState.Session.Emulation <> nil then
    FState.Session.Emulation.SetGamepadInput(FView.CombinedGamepadInput);
end;

function TInputController.CombinedGamepadInput: TEmulatorInput;
const
  Mapping: array[TNesButton] of TEmulatorButton = (TEmulatorButton.A,
    TEmulatorButton.B, TEmulatorButton.Select, TEmulatorButton.Start,
    TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left, TEmulatorButton.Right);
begin
  Result := FState.Input.GamepadInput;
  if FState.Input.Manager <> nil then
  begin
    var Host := ReadPadInput(FState.Input.Manager, FState.Input.Ports);
    Result.Buttons := Result.Buttons + Host.Buttons;
    Result.Buttons2 := Host.Buttons2;
    Result.Buttons3 := Host.Buttons3;
    Result.Buttons4 := Host.Buttons4;
    Result.Buttons5 := Host.Buttons5;
    Result.Buttons6 := Host.Buttons6;
    Result.Buttons7 := Host.Buttons7;
    Result.Buttons8 := Host.Buttons8;
    Result.Buttons9 := Host.Buttons9;
    Result.Buttons10 := Host.Buttons10;
    Result.Buttons11 := Host.Buttons11;
    Result.Buttons12 := Host.Buttons12;
    var VirtualAnalog := Result.Analog[0];
    Result.Analog := Host.Analog;
    if VirtualAnalog.Valid then
      Result.Analog[0] := VirtualAnalog;
  end;

  if FState.Input.Ports.Devices[0] = 'none' then
  begin
    Result.Buttons := [];
    Result.Analog[0].Valid := False;
  end;

  var N64Input: IN64ControllerInput;
  if Supports(FState.Session.Emulation, IN64ControllerInput, N64Input) then
    for var Port := 0 to 3 do
    begin
      var Pad := Default(TN64Pad);
      if ((Port = 0) and ((FState.Input.Gamepad.AuxiliaryButtons and 1) <> 0)) or
        ((FState.Input.Manager <> nil) and FState.Input.Manager.IsPressed(N64LAction + Port)) then
        Pad.Buttons := $20;
      if Result.Analog[Port].Valid then
      begin
        Pad.StickX := Round(Result.Analog[Port].X / 32767 * 80);
        Pad.StickY := -Round(Result.Analog[Port].Y / 32767 * 80);
      end;
      N64Input.SetN64Controller(Port, Pad);
    end;

  // PlayStation L2/L3/R3, ANALOG and the right stick sit outside the logical
  // pad; on-screen auxiliary button N is TPS1Extra(N).
  var PS1Input: IPS1ControllerInput;
  if Supports(FState.Session.Emulation, IPS1ControllerInput, PS1Input) then
    for var Port := 0 to 1 do
    begin
      var Pad := ReadPS1Pad(FState.Input.Manager, Port);
      if Port = 0 then
      begin
        var Auxiliary := FState.Input.Gamepad.AuxiliaryButtons;
        if (Auxiliary and (1 shl Ord(TPS1Extra.L2))) <> 0 then
          Pad.Buttons := Pad.Buttons or PS1PadL2;
        if (Auxiliary and (1 shl Ord(TPS1Extra.L3))) <> 0 then
          Pad.Buttons := Pad.Buttons or PS1PadL3;
        if (Auxiliary and (1 shl Ord(TPS1Extra.R3))) <> 0 then
          Pad.Buttons := Pad.Buttons or PS1PadR3;
        if (Auxiliary and (1 shl Ord(TPS1Extra.Analog))) <> 0 then
          Pad.AnalogButton := True;
        // The on-screen right stick (the left one arrives as Analog[0]).
        var Right := FState.Input.Gamepad.RightAnalogInput;
        if Right.Valid then
        begin
          Pad.RightX := EnsureRange(Integer(Pad.RightX) + Right.X, -32768, 32767);
          Pad.RightY := EnsureRange(Integer(Pad.RightY) + Right.Y, -32768, 32767);
        end;
      end;
      PS1Input.SetPS1Controller(Port, Pad);
    end;
  // Dreamcast stick and trigger axes from host bindings (the on-screen stick
  // and triggers arrive as Analog[0]).
  var DCInput: IDCControllerInput;
  if Supports(FState.Session.Emulation, IDCControllerInput, DCInput) then
    for var Port := 0 to 3 do
      DCInput.SetDCController(Port, ReadDCPad(FState.Input.Manager, Port));

  // The DualShock 2 takes the same extras (and the same L2/L3/R3 bits).
  var PS2Input: IPS2ControllerInput;
  if Supports(FState.Session.Emulation, IPS2ControllerInput, PS2Input) then
    for var Port := 0 to 1 do
    begin
      var Pad := ReadPS1Pad(FState.Input.Manager, Port);
      if Port = 0 then
      begin
        var Auxiliary := FState.Input.Gamepad.AuxiliaryButtons;
        if (Auxiliary and (1 shl Ord(TPS1Extra.L2))) <> 0 then
          Pad.Buttons := Pad.Buttons or PS1PadL2;
        if (Auxiliary and (1 shl Ord(TPS1Extra.Analog))) <> 0 then
          Pad.AnalogButton := True;
        var Right := FState.Input.Gamepad.RightAnalogInput;
        if Right.Valid then
        begin
          Pad.RightX := EnsureRange(Integer(Pad.RightX) + Right.X, -32768, 32767);
          Pad.RightY := EnsureRange(Integer(Pad.RightY) + Right.Y, -32768, 32767);
        end;
      end;
      var Pad2: TPS2Pad;
      Pad2.Buttons := Pad.Buttons;
      Pad2.AnalogButton := Pad.AnalogButton;
      Pad2.LeftX := Pad.LeftX;
      Pad2.LeftY := Pad.LeftY;
      Pad2.RightX := Pad.RightX;
      Pad2.RightY := Pad.RightY;
      PS2Input.SetPS2Controller(Port, Pad2);
    end;

  var Piano: INesMiraclePianoCore;
  if Supports(FState.Session.Emulation, INesMiraclePianoCore, Piano) and Piano.UsesMiraclePiano then
  begin
    for var Button in FState.Input.MiraclePiano.Buttons do
      Include(Result.Buttons, Mapping[Button]);
    if FState.Input.Manager <> nil then
      for var Button := Low(TNesButton) to High(TNesButton) do
        if FState.Input.Manager.IsPressed(PadAction(0, Mapping[Button])) then
          Include(Result.Buttons, Mapping[Button]);
  end;
end;

procedure TInputController.UpdatePeripheralInput;
begin
  SGKeyboardChanged(nil);
  var Peripheral: INesPeripheralCore;
  if Supports(FState.Session.Emulation, INesPeripheralCore, Peripheral) then
  begin
    if FState.Session.Emulation.UsesSuborKeyboard then
      Peripheral.SetSuborKeys(FState.Input.SuborKeyboard.Keys + ReadSuborInput(FState.Input.Manager));
    if Peripheral.UsesFamicomKeyboard then
      Peripheral.SetFamicomKeys(FState.Input.FamicomKeyboard.Keys + ReadFamicomInput(FState.Input.Manager));
    if Peripheral.UsesPowerPad then
    begin
      var Buttons := FState.Input.PowerPad.Buttons;
      if FState.Input.Manager <> nil then
        for var i := 0 to 11 do
          if FState.Input.Manager.IsPressed(PowerPadAction + i) then
            Include(Buttons, i + 1);
      Peripheral.SetPowerPadButtons(Buttons);
    end;
  end;

  var Piano: INesMiraclePianoCore;
  if Supports(FState.Session.Emulation, INesMiraclePianoCore, Piano) and Piano.UsesMiraclePiano then
    Piano.SetMiracleKeys(FState.Input.MiraclePiano.Keys + ReadPianoInput(FState.Input.Manager));
end;

procedure TInputController.UpdatePeripheralFeedback;
var
  Peripheral: INesPeripheralCore;
  Tape: INesTapeCore;
  Piano: INesMiraclePianoCore;
begin
  if (FState.Session.Emulation = nil) or FState.Session.EmulationFaulted then
    Exit;

  if (FState.Input.MiraclePiano <> nil) and FState.Input.MiraclePiano.Visible and FState.Input.MiraclePiano.Enabled and
    Supports(FState.Session.Emulation, INesMiraclePianoCore, Piano) then
    FState.Input.MiraclePiano.CoreKeys := Piano.GetMiracleKeys;
  if (FState.Input.DataRecorder <> nil) and Supports(FState.Session.Emulation, INesTapeCore, Tape) and Tape.UsesDataRecorder then
    FState.Input.DataRecorder.Progress := Tape.GetTapeProgress;
  if (FState.Input.Gamepad <> nil) and FState.Input.Gamepad.Visible and FState.Input.Gamepad.Enabled then
    FState.Input.Gamepad.CoreButtons := FState.Session.Emulation.GetInputState.Buttons;
  if Supports(FState.Session.Emulation, INesPeripheralCore, Peripheral) then
  begin
    if (FState.Input.SuborKeyboard <> nil) and FState.Input.SuborKeyboard.Visible and FState.Input.SuborKeyboard.Enabled then
    begin
      FState.Input.SuborKeyboard.CoreKeys := Peripheral.GetSuborKeys;
      FState.Input.SuborKeyboard.Indicators := Peripheral.GetSuborIndicators;
    end;
    if (FState.Input.FamicomKeyboard <> nil) and FState.Input.FamicomKeyboard.Visible and FState.Input.FamicomKeyboard.Enabled then
      FState.Input.FamicomKeyboard.CoreKeys := Peripheral.GetFamicomKeys;
    if (FState.Input.PowerPad <> nil) and FState.Input.PowerPad.Visible and FState.Input.PowerPad.Enabled then
      FState.Input.PowerPad.CoreButtons := Peripheral.GetPowerPadButtons;
  end;
end;

procedure TInputController.MiraclePianoChanged(Sender: TObject);
begin
  var Piano: INesMiraclePianoCore;
  if not Supports(FState.Session.Emulation, INesMiraclePianoCore, Piano) or not Piano.UsesMiraclePiano then
    Exit;

  FView.UpdatePeripheralInput;
  FState.Session.Emulation.SetGamepadInput(FView.CombinedGamepadInput);
end;

procedure TInputController.FamicomKeyboardChanged(Sender: TObject);
begin
  FView.UpdatePeripheralInput;
end;

procedure TInputController.SGKeyboardChanged(Sender: TObject);
begin
  var Keyboard: ISGKeyboardCore;
  if (FState.Input.SGKeyboard <> nil) and Supports(FState.Session.Emulation, ISGKeyboardCore, Keyboard) and Keyboard.HasKeyboard then
    Keyboard.SetScreenKeys(FState.Input.SGKeyboard.Keys);
end;

procedure TInputController.SuborKeyboardChanged(Sender: TObject);
begin
  FView.UpdatePeripheralInput;
end;

procedure TInputController.SuborKeyboardPower(Sender: TObject);
begin
  if (FState.Session.Emulation = nil) or FState.Session.EmulationFaulted then
    Exit;

  try
    if FState.Input.Rumble <> nil then
      FState.Input.Rumble.Reset;
    FState.Session.Emulation.Reset;
  except
    FView.StopOnError;
    raise;
  end;
end;

procedure TInputController.PowerPadChanged(Sender: TObject);
begin
  FView.UpdatePeripheralInput;
end;

procedure TInputController.ImageCanvasMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Single);
begin
  if (FState.Input.Manager <> nil) or (Button <> TMouseButton.mbLeft) then
    Exit;

  var Peripheral: INesPeripheralCore;
  if Supports(FState.Session.Emulation, INesPeripheralCore, Peripheral) then
  begin
    TryGetImagePixel(FView.ImageCanvas, X, Y, FState.Input.ZapperPixel.X, FState.Input.ZapperPixel.Y);
    Peripheral.Zapper.TriggerPressed := True;
  end;
end;

procedure TInputController.ImageCanvasMouseUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Single);
begin
  if (FState.Input.Manager <> nil) or (Button <> TMouseButton.mbLeft) then
    Exit;

  var Peripheral: INesPeripheralCore;
  if Supports(FState.Session.Emulation, INesPeripheralCore, Peripheral) then
  begin
    Peripheral.Zapper.TriggerPressed := False;
  end;
end;

procedure TInputController.TapeAction(Sender: TObject; Action: TTapeAction; const FileName: string);
begin
  var Tape: INesTapeCore;
  if not Supports(FState.Session.Emulation, INesTapeCore, Tape) then
    Exit;

  try
    Tape.TapeCommand(Action, FileName);
    FState.Input.DataRecorder.Progress := Tape.GetTapeProgress;
  except
    on E: Exception do
      ShowRetroMessage(FView, Translate('Cassette: ') + E.Message);
  end;
end;

procedure TInputController.SelectTapeFile(const FileName: string);
begin
  var Tape: INesTapeCore;
  if not Supports(FState.Session.Emulation, INesTapeCore, Tape) or not Tape.UsesDataRecorder then
    raise EInvalidOperation.Create(Translate('No data recorder connected'));

  Tape.TapeCommand(TapeSelectFile, FileName);
  FState.Input.DataRecorder.Progress := Tape.GetTapeProgress;
end;

procedure TInputController.ChooseTapeFile(Sender: TObject);
begin
  FView.SelectDocument(True);
end;

procedure TInputController.SaveTapeAs(Sender: TObject);
begin
  var Tape: INesTapeCore;
  if not Supports(FState.Session.Emulation, INesTapeCore, Tape) or not Tape.UsesDataRecorder then
    Exit;

  FView.FormDeactivate(FView);
  {$IFDEF ANDROID}
  if FState.Session.OpeningRom then
    Exit;

  var Path := FState.Session.Storage.TemporaryFile('.tape');
  try
    Tape.TapeCommand(TapeSaveAs, Path);
    FState.Mobile.Transfer.Save(Path, ExtractFileName(Tape.GetTapeProgress.FileName));
    FState.Session.OpeningRom := True;
    FView.SyncActivity;
  except
    on E: Exception do
    begin
      FState.Session.Storage.Delete(Path);
      ShowRetroMessage(FView, Translate('Cassette: ') + E.Message);
    end;
  end;
  {$ELSE}
  var Dialog := TSaveDialog.Create(FView);
  try
    Dialog.Title := Translate('Save cassette as');
    Dialog.Filter := Translate('Cassette (*.tape)|*.tape');
    Dialog.DefaultExt := 'tape';
    Dialog.Options := [TOpenOption.ofPathMustExist, TOpenOption.ofOverwritePrompt];
    Dialog.FileName := Tape.GetTapeProgress.FileName;
    if Dialog.Execute then
    try
      Tape.TapeCommand(TapeSaveAs, Dialog.FileName);
      FState.Input.DataRecorder.Progress := Tape.GetTapeProgress;
    except
      on E: Exception do
        ShowRetroMessage(FView, Translate('Cassette: ') + E.Message);
    end;
  finally
    Dialog.Free;
    FView.FormActivate(FView);
  end;
  {$ENDIF}
end;

end.

