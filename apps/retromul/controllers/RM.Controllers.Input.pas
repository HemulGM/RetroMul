unit RM.Controllers.Input;

{$I ..\RM.Mobile.inc}

interface

uses
  System.Classes, System.UITypes, Core.Emulation, RM.Controllers.Base,
  RM.Input.Runtime
  {$IF not Defined(LINUX)}
    , System.Sensors
  {$ENDIF};

type
  TInputController = class(TMainController)
  private
    function RuntimeContext: TInputRuntimeContext;
    procedure PeripheralChanged(Sender: TObject);
  public
    procedure InitializePeripherals;
    procedure FinalizePeripherals;
    procedure InitializeHostInput;
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
    procedure ImageCanvasMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Single);
    procedure ImageCanvasMouseUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Single);
    procedure SelectTapeFile(const FileName: string);
  end;

implementation

uses
  System.SysUtils, System.Types, System.IOUtils, System.Math, FMX.Types,
  FMX.Forms, FMX.Objects, FMX.Dialogs, FMX.Platform, FMX.Edit, FMX.OpenDialog,
  FMXInput, RM.Input, RM.Rumble, Core.InputConfig, RM.Gamepad, RM.Dialogs,
  RM.Styles
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

function TInputController.RuntimeContext: TInputRuntimeContext;
begin
  Result.View := FView;
  Result.State := FState;
  Result.ScreenInputChanged := PeripheralChanged;
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

  InitializePlatformInputHandlers(RuntimeContext);
end;

procedure TInputController.PeripheralChanged(Sender: TObject);
begin
  PlatformInputHandler(FState.Input.SystemId).ScreenInputChanged(RuntimeContext, Sender);
end;

procedure TInputController.FinalizePeripherals;
begin
  FinalizePlatformInputHandlers(RuntimeContext);
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

procedure TInputController.InitializeHostInput;
begin
  // Before the first game there is no platform profile to load.
  FState.Input.SystemId := '';
  FState.Input.Ports := TCoreInputPorts.Defaults;
  FState.Input.GamepadInput := Default(TEmulatorInput);
  FState.Input.PollingFailed := False;
  FState.Input.SuppressInputUntilRelease := True;
  FillChar(FState.Input.KeysDown, SizeOf(FState.Input.KeysDown), 0);
  if FState.Input.Manager <> nil then
  begin
    FState.Input.Manager.CancelCapture;
    FState.Input.Manager.ClearBindings;
  end;
end;

procedure TInputController.LoadHostInput(const SystemId: string);
begin
  if SystemId = '' then
  begin
    InitializeHostInput;
    Exit;
  end;
  FState.Input.SystemId := SystemId;
  FState.Input.Ports := LoadCoreInputPorts(FState.Session.Storage, SystemId);
  FView.ReloadHostInputBindings;
end;

procedure TInputController.ReloadHostInputBindings;
begin
  if FState.Input.SystemId = '' then
  begin
    InitializeHostInput;
    Exit;
  end;
  if FState.Input.Manager = nil then
    Exit;

  // Assignments belong to the active game, independently of the settings page.
  // Connection changes are applied separately on the owning emulation thread.
  var Ini := FState.Session.Storage.ReadConfig(FState.Session.Storage.ConfigFile(FState.Input.SystemId));
  try
    LoadInputBindings(FState.Input.Manager, Ini, FState.Input.SystemId);
    FilterInputBindings(FState.Input.Manager, Ini, FState.Input.SystemId);
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
  PlatformInputHandler(FState.Input.SystemId).PollInput(RuntimeContext);
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
  var Policy := PlatformInputHandler(FState.Input.SystemId).KeyPolicy(RuntimeContext);
  var KeyboardActive := Policy.KeyboardActive;

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
    else if (Code = vkF9) and not KeyboardActive and not Policy.ReserveCaptureShortcuts then
      FView.InsertCoinClick(FView)
    else if (Code = vkF8) and (FState.Session.Emulation <> nil) and not KeyboardActive and not Policy.ReserveCaptureShortcuts then
    begin
      try
        FView.SetStatus(Translate('Screenshot: ') + FView.SaveScreenshot);
      except
        on E: Exception do
          ShowRetroMessage(FView, E.Message);
      end;
    end
    else if (Code in [vkF5, vkF6]) and (FState.Session.Emulation <> nil) and (not KeyboardActive or Policy.AllowSnapshotsWithKeyboard) then
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

  var ControlKey := Policy.IsControlKey(Code);
  if (FState.Help.View = nil) and (KeyboardActive or not (ssCtrl in Shift) or ControlKey) then
    if (FState.Session.Emulation <> nil) and ((FState.Input.Manager = nil) or ControlKey or Policy.ForwardWithManager) then
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

  var Policy := PlatformInputHandler(FState.Input.SystemId).KeyPolicy(RuntimeContext);
  if (FState.Help.View = nil) and (FState.Session.Emulation <> nil) and
    ((FState.Input.Manager = nil) or Policy.IsControlKey(Code) or
    Policy.ForwardWithManager) then
    FView.ForwardKeyState(Code, False);

  Key := 0;
  KeyChar := #0;
end;

procedure TInputController.ForwardKeyState(Code: Word; Pressed: Boolean);
begin
  if FState.Session.Emulation = nil then
    Exit;
  if not PlatformInputHandler(FState.Input.SystemId).ForwardKey(RuntimeContext, Code, Pressed) then
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

  PlatformInputHandler(FState.Input.SystemId).CombineInput(RuntimeContext, Result);
end;

procedure TInputController.UpdatePeripheralInput;
begin
  PlatformInputHandler(FState.Input.SystemId).UpdateInput(RuntimeContext);
end;

procedure TInputController.UpdatePeripheralFeedback;
begin
  if (FState.Session.Emulation = nil) or FState.Session.EmulationFaulted then
    Exit;
  PlatformInputHandler(FState.Input.SystemId).UpdateFeedback(RuntimeContext);
end;

procedure TInputController.ImageCanvasMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Single);
begin
  if (FState.Input.Manager <> nil) or (Button <> TMouseButton.mbLeft) then
    Exit;
  PlatformInputHandler(FState.Input.SystemId).PointerButton(RuntimeContext, X, Y, True);
end;

procedure TInputController.ImageCanvasMouseUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Single);
begin
  if (FState.Input.Manager <> nil) or (Button <> TMouseButton.mbLeft) then
    Exit;
  PlatformInputHandler(FState.Input.SystemId).PointerButton(RuntimeContext, X, Y, False);
end;

procedure TInputController.SelectTapeFile(const FileName: string);
begin
  PlatformInputHandler(FState.Input.SystemId).Command(RuntimeContext, 'tape.select', 0, FileName);
end;

end.

