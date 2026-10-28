unit RM.Platforms.NES.Input;

{$I RM.Mobile.inc}

interface

uses
  System.Classes, System.Types, System.IniFiles, FMXInput, RM.Input,
  NES.Controller, NES.FamicomKeyboardDevice, NES.MiraclePianoDevice,
  RM.Platforms.NES.Controls.PowerPad, RM.Input.Runtime, NES.FamicomDataRecorder,
  RM.Platforms.NES.Controls.DataRecorder, RM.Platforms.NES.Keyboard,
  RM.Platforms.NES.Controls.MiraclePiano, Core.Emulation;

const
  PowerPadAction = 128;
  ZapperTriggerAction = 160;
  SuborAction = 256;
  FamicomAction = 384;
  PianoAction = 512;

type
  TNesInputState = class;

  INesInputState = interface
    ['{79AE514D-8F83-420B-ACD6-4CE4B0D82908}']
    function GetState: TNesInputState;
  end;

  TNesInputState = class(TInterfacedObject, INesInputState)
  private
    FContext: TInputRuntimeContext;
    FObserver: TComponent;
    function GetState: TNesInputState;
    procedure InputChanged(Sender: TObject);
    procedure KeyboardPower(Sender: TObject);
    procedure TapeAction(Sender: TObject; Action: TTapeAction; const FileName: string);
    procedure ChooseTapeFile(Sender: TObject);
    procedure SaveTapeAs(Sender: TObject);
  public
    SuborKeyboard: TNesSuborKeyboard;
    FamicomKeyboard: TNesFamicomKeyboard;
    MiraclePiano: TNesMiraclePiano;
    PowerPad: TGamepadNESPowerPad;
    DataRecorder: TNesDataRecorder;
    ZapperPixel: TPoint;
    SuborKeyboardTouchAttached, FamicomKeyboardTouchAttached: Boolean;
    MiraclePianoTouchAttached, PowerPadTouchAttached: Boolean;
    constructor Create(const Context: TInputRuntimeContext);
    destructor Destroy; override;
    procedure ReleaseDevices;
  end;

  TNesInputHandler = class(TPlatformInputHandler)
  public
    class function InitializationOrder: Integer; override;
    class procedure Initialize(const Context: TInputRuntimeContext); override;
    class procedure Finalize(const Context: TInputRuntimeContext); override;
    class function KeyPolicy(const Context: TInputRuntimeContext): TInputKeyPolicy; override;
    class function ForwardKey(const Context: TInputRuntimeContext; Code: Word; Pressed: Boolean): Boolean; override;
    class procedure CombineInput(const Context: TInputRuntimeContext; var Input: TEmulatorInput); override;
    class procedure UpdateInput(const Context: TInputRuntimeContext); override;
    class procedure UpdateFeedback(const Context: TInputRuntimeContext); override;
    class procedure PollInput(const Context: TInputRuntimeContext); override;
    class procedure ScreenInputChanged(const Context: TInputRuntimeContext; Sender: TObject); override;
    class procedure PointerButton(const Context: TInputRuntimeContext; X, Y: Single; Pressed: Boolean); override;
    class procedure Command(const Context: TInputRuntimeContext; const Name: string; Code: Integer; const FileName: string); override;
  private
    class procedure DoTapeAction(const Context: TInputRuntimeContext; Action: TTapeAction; const FileName: string);
    class procedure DoSelectTapeFile(const Context: TInputRuntimeContext; const FileName: string);
    class procedure DoSaveTapeAs(const Context: TInputRuntimeContext);
  end;

// Borrowed state; lifetime is bounded by the owning window or explicit finalization.
function NesInputState(const Context: TInputRuntimeContext; CreateIfMissing: Boolean = True): TNesInputState;

function ReadSuborInput(Input: TInputManager): TSuborKeys;

function ReadFamicomInput(Input: TInputManager): TFamicomKeys;

function ReadPianoInput(Input: TInputManager): TMiracleKeys;

procedure EnsurePeripheralBindings(Input: TInputManager; Ini: TCustomIniFile);

procedure LoadNesLegacyAuxiliaries(Input: TInputManager; Ini: TCustomIniFile);

procedure FilterNesCompatibilityBinding(const Binding: TInputBinding; Ini: TCustomIniFile; var Policy: TInputBindingPolicy);

implementation

uses
  System.SysUtils, System.IOUtils, System.Math, System.UITypes, FMX.Types,
  FMX.Forms, FMX.Platform, FMX.Dialogs, FMX.OpenDialog,
  Core.Platforms.NES.Adapter, NES.Input, NES.Types, RM.Gamepad,
  RM.Settings.Rendering, RM.Dialogs, RM.Rumble
  {$IFDEF MSWINDOWS}, Winapi.Windows{$ENDIF}
  {$IFDEF ANDROID}, RM.DocumentTransfer.Android{$ENDIF};

type
  TNesDeviceObserver = class(TComponent)
  public
    State: TNesInputState;
    procedure Notification(AComponent: TComponent; Operation: TOperation); override;
  end;

const
  NesStateKey = 'retromul.nes/peripherals';

procedure TNesDeviceObserver.Notification(AComponent: TComponent; Operation: TOperation);
begin
  inherited;
  if Operation <> opRemove then
    Exit;
  if AComponent = State.SuborKeyboard then
    State.SuborKeyboard := nil;
  if AComponent = State.FamicomKeyboard then
    State.FamicomKeyboard := nil;
  if AComponent = State.MiraclePiano then
    State.MiraclePiano := nil;
  if AComponent = State.PowerPad then
    State.PowerPad := nil;
  if AComponent = State.DataRecorder then
    State.DataRecorder := nil;
end;

constructor TNesInputState.Create(const Context: TInputRuntimeContext);
begin
  inherited Create;
  FContext := Context;
  var Observer := TNesDeviceObserver.Create(nil);
  Observer.State := Self;
  FObserver := Observer;
end;

destructor TNesInputState.Destroy;
begin
  ReleaseDevices;
  FObserver.Free;
  inherited;
end;

function TNesInputState.GetState: TNesInputState;
begin
  Result := Self;
end;

function NesInputState(const Context: TInputRuntimeContext; CreateIfMissing: Boolean): TNesInputState;
begin
  var Value := Context.Data(NesStateKey);
  if (Value = nil) and CreateIfMissing then
  begin
    Value := TNesInputState.Create(Context);
    Context.SetData(NesStateKey, Value);
  end;
  if Value = nil then
    Exit(nil);
  Result := (Value as INesInputState).GetState;
end;

procedure TNesInputState.InputChanged(Sender: TObject);
begin
  if Assigned(FContext.ScreenInputChanged) then
    FContext.ScreenInputChanged(Sender);
end;

procedure TNesInputState.KeyboardPower(Sender: TObject);
begin
  if (FContext.State.Session.Emulation = nil) or FContext.State.Session.EmulationFaulted then
    Exit;
  try
    if FContext.State.Input.Rumble <> nil then
      FContext.State.Input.Rumble.Reset;
    FContext.State.Session.Emulation.Reset;
  except
    FContext.View.StopOnError;
    raise;
  end;
end;

procedure TNesInputState.TapeAction(Sender: TObject; Action: TTapeAction; const FileName: string);
begin
  TNesInputHandler.Command(FContext, 'tape.action', Ord(Action), FileName);
end;

procedure TNesInputState.ChooseTapeFile(Sender: TObject);
begin
  FContext.View.SelectDocument(True);
end;

procedure TNesInputState.SaveTapeAs(Sender: TObject);
begin
  TNesInputHandler.Command(FContext, 'tape.saveas', 0, '');
end;

procedure TNesInputState.ReleaseDevices;
begin
  if SuborKeyboard <> nil then
  begin
    var Control := SuborKeyboard;
    SuborKeyboard := nil;
    Control.OnChange := nil;
    Control.OnPower := nil;
    Control.OnReset := nil;
    DisconnectSettingsControl(Control);
    Control.AttachToForm(nil);
    Control.ReleaseAll;
    RetireSettingsControl(Control);
  end;
  if FamicomKeyboard <> nil then
  begin
    var Control := FamicomKeyboard;
    FamicomKeyboard := nil;
    Control.OnChange := nil;
    DisconnectSettingsControl(Control);
    Control.AttachToForm(nil);
    Control.ReleaseAll;
    RetireSettingsControl(Control);
  end;
  if MiraclePiano <> nil then
  begin
    var Control := MiraclePiano;
    MiraclePiano := nil;
    Control.OnChange := nil;
    DisconnectSettingsControl(Control);
    Control.AttachToForm(nil);
    Control.ReleaseAll;
    RetireSettingsControl(Control);
  end;
  if PowerPad <> nil then
  begin
    var Control := PowerPad;
    PowerPad := nil;
    Control.OnChange := nil;
    DisconnectSettingsControl(Control);
    Control.AttachToForm(nil);
    Control.ReleaseAll;
    RetireSettingsControl(Control);
  end;
  if DataRecorder <> nil then
  begin
    var Control := DataRecorder;
    DataRecorder := nil;
    Control.OnAction := nil;
    Control.OnChooseFile := nil;
    Control.OnSaveAs := nil;
    RetireSettingsControl(Control);
  end;
  SuborKeyboardTouchAttached := False;
  FamicomKeyboardTouchAttached := False;
  MiraclePianoTouchAttached := False;
  PowerPadTouchAttached := False;
end;

function ReadSuborInput(Input: TInputManager): TSuborKeys;
begin
  Result := [];
  if Input = nil then
    Exit;

  for var K := Low(TSuborKey) to High(TSuborKey) do
    if (K <> SkNone) and Input.IsPressed(SuborAction + Ord(K)) then
      Include(Result, K);
end;

function ReadFamicomInput(Input: TInputManager): TFamicomKeys;
begin
  Result := [];
  if Input = nil then
    Exit;

  for var K := Low(TFamicomKey) to High(TFamicomKey) do
    if (K <> FkNone) and Input.IsPressed(FamicomAction + Ord(K)) then
      Include(Result, K);
end;

function ReadPianoInput(Input: TInputManager): TMiracleKeys;
begin
  Result := [];
  if Input = nil then
    Exit;

  for var K := Low(TMiracleKey) to High(TMiracleKey) do
    if Input.IsPressed(PianoAction + K) then
      Include(Result, K);
end;

procedure EnsurePeripheralBindings(Input: TInputManager; Ini: TCustomIniFile);

  procedure AddKey(Action, Hid: Integer);
  begin
    Input.AddBinding(TInputBinding.Create(Action,
        TInputValue.Create(SystemKeyboardId, TInputElementKind.Key, Hid, 1)));
  end;

begin
  if Ini.ReadInteger('FMXInput', 'PeripheralVersion', 0) >= 1 then
    Exit;

  var Subor := TSuborKeyboard.Create;
  var Famicom := TFamicomKeyboard.Create;
  try
    for var Hid := 4 to 231 do
    begin
      var Code := HidToHostKey(Hid);
      if Code = 0 then
        Continue;

      Subor.Clear;
      Subor.SetHostKey(Code, True);
      for var K in Subor.GetPressedKeys do
        AddKey(SuborAction + Ord(K), Hid);
      Famicom.Clear;
      Famicom.SetHostKey(Code, True);
      for var K in Famicom.GetPressedKeys do
        AddKey(FamicomAction + Ord(K), Hid);
      var PianoKey := TMiraclePianoDevice.HostKey(Code);
      if PianoKey >= 0 then
        AddKey(PianoAction + PianoKey, Hid);
    end;
    Ini.WriteInteger('FMXInput', 'PeripheralVersion', 1);
  finally
    Famicom.Free;
    Subor.Free;
  end;
end;

procedure LoadNesLegacyAuxiliaries(Input: TInputManager; Ini: TCustomIniFile);
const
  PowerKeys: array[0..11] of Word = (vk1, vk2, vk3, vk4, vk5, vk6, vk7, vk8, vk9, vk0, vkMinus, vkEqual);
begin
  for var I := 0 to 11 do
    AddLegacyInputKey(Input, PowerPadAction + I, PowerKeys[I]);
  Input.AddBinding(TInputBinding.Create(ZapperTriggerAction,
      TInputValue.Create(SystemMouseId, TInputElementKind.Button, MouseLeft, 1)));
end;

procedure FilterNesCompatibilityBinding(const Binding: TInputBinding; Ini: TCustomIniFile; var Policy: TInputBindingPolicy);
begin
  if not Ini.ReadBool('Ports', 'KeyboardEnabled', True) and (Binding.Kind = TInputElementKind.Key) and
    (((Binding.Action >= SuborAction) and (Binding.Action < ExtraPadAction)) or
    ((Ini.ReadString('Ports', 'Port1', 'auto') = 'piano') and (Binding.Action < 32))) then
    Policy.Enabled := False;
  if (Binding.Action >= PowerPadAction) and (Binding.Action < SuborAction) then
    Policy.SourceKey := 'Source2';
  if (Binding.Action >= SuborAction) and (Binding.Action < PianoAction) then
    Policy.SourceKey := 'SourceExpansion';
  if (Binding.Action >= PianoAction) and (Binding.Action < ExtraPadAction) then
    Policy.SourceKey := 'Source1';
end;

class procedure TNesInputHandler.Finalize(const Context: TInputRuntimeContext);
begin
  var Devices := NesInputState(Context, False);
  if Devices <> nil then
    Devices.ReleaseDevices;
  Context.SetData(NesStateKey, nil);
end;

class function TNesInputHandler.InitializationOrder: Integer;
begin
  Result := 20;
end;

class procedure TNesInputHandler.Initialize(const Context: TInputRuntimeContext);
begin
  var Devices := NesInputState(Context);
  Devices.FContext := Context;
  if Devices.SuborKeyboard = nil then
  begin
    Devices.SuborKeyboard := TNesSuborKeyboard.Create(Context.View);
    Devices.SuborKeyboard.FreeNotification(Devices.FObserver);
    Devices.SuborKeyboard.Name := 'ScreenSuborKeyboard';
    Devices.SuborKeyboard.Parent := Context.View.LayoutClient;
    Devices.SuborKeyboard.Align := TAlignLayout.Bottom;
    Devices.SuborKeyboard.OnChange := Devices.InputChanged;
    Devices.SuborKeyboard.OnPower := Devices.KeyboardPower;
    Devices.SuborKeyboard.OnReset := Devices.KeyboardPower;
    Devices.SuborKeyboard.Enabled := False;
    Devices.SuborKeyboard.Visible := False;
  end;
  if Devices.FamicomKeyboard = nil then
  begin
    Devices.FamicomKeyboard := TNesFamicomKeyboard.Create(Context.View);
    Devices.FamicomKeyboard.FreeNotification(Devices.FObserver);
    Devices.FamicomKeyboard.Name := 'ScreenFamicomKeyboard';
    Devices.FamicomKeyboard.Parent := Context.View.LayoutClient;
    Devices.FamicomKeyboard.Align := TAlignLayout.Bottom;
    Devices.FamicomKeyboard.OnChange := Devices.InputChanged;
    Devices.FamicomKeyboard.Enabled := False;
    Devices.FamicomKeyboard.Visible := False;
  end;
  if Devices.MiraclePiano = nil then
  begin
    Devices.MiraclePiano := TNesMiraclePiano.Create(Context.View);
    Devices.MiraclePiano.FreeNotification(Devices.FObserver);
    Devices.MiraclePiano.Name := 'ScreenMiraclePiano';
    Devices.MiraclePiano.Parent := Context.View.LayoutClient;
    Devices.MiraclePiano.Align := TAlignLayout.Bottom;
    Devices.MiraclePiano.OnChange := Devices.InputChanged;
    Devices.MiraclePiano.Enabled := False;
    Devices.MiraclePiano.Visible := False;
  end;
  if Devices.PowerPad = nil then
  begin
    Devices.PowerPad := TGamepadNESPowerPad.Create(Context.View);
    Devices.PowerPad.FreeNotification(Devices.FObserver);
    Devices.PowerPad.Name := 'ScreenPowerPad';
    Devices.PowerPad.Parent := Context.View.LayoutClient;
    Devices.PowerPad.Align := TAlignLayout.Bottom;
    Devices.PowerPad.OnChange := Devices.InputChanged;
    Devices.PowerPad.Enabled := False;
    Devices.PowerPad.Visible := False;
    Devices.PowerPad.Margins.Bottom := 100;
  end;
  if Devices.DataRecorder = nil then
  begin
    Devices.DataRecorder := TNesDataRecorder.Create(Context.View);
    Devices.DataRecorder.FreeNotification(Devices.FObserver);
    Devices.DataRecorder.Name := 'ScreenDataRecorder';
    Devices.DataRecorder.Parent := Context.View.LayoutClient;
    Devices.DataRecorder.Align := TAlignLayout.Bottom;
    Devices.DataRecorder.OnAction := Devices.TapeAction;
    Devices.DataRecorder.OnChooseFile := Devices.ChooseTapeFile;
    Devices.DataRecorder.OnSaveAs := Devices.SaveTapeAs;
    Devices.DataRecorder.Visible := False;
    Devices.DataRecorder.Enabled := False;
  end;
end;

class function TNesInputHandler.KeyPolicy(const Context: TInputRuntimeContext): TInputKeyPolicy;
var
  Peripheral: INesPeripheralCore;
  Piano: INesMiraclePianoCore;
begin
  Result := inherited KeyPolicy(Context);
  Result.KeyboardActive := ((Context.State.Session.Emulation <> nil) and NesUsesSuborKeyboard(Context.State.Session.Emulation)) or
    (Supports(Context.State.Session.Emulation, INesPeripheralCore, Peripheral) and Peripheral.UsesFamicomKeyboard) or
    (Supports(Context.State.Session.Emulation, INesMiraclePianoCore, Piano) and Piano.UsesMiraclePiano);
end;

class function TNesInputHandler.ForwardKey(const Context: TInputRuntimeContext; Code: Word; Pressed: Boolean): Boolean;
begin
  Result := False;
  {$IFDEF MSWINDOWS}
  // Windows FMX reports generic Shift. HVC-007 has two separate contacts.
  var Peripheral: INesPeripheralCore;
  if (Context.State.Input.Manager = nil) and (Code = vkShift) and Supports(Context.State.Session.Emulation, INesPeripheralCore, Peripheral) and Peripheral.UsesFamicomKeyboard then
  begin
    Context.State.Session.Emulation.SetKeyState(vkLShift, Winapi.Windows.GetKeyState(vkLShift) < 0);
    Context.State.Session.Emulation.SetKeyState(vkRShift, Winapi.Windows.GetKeyState(vkRShift) < 0);
    Exit(True);
  end;
  {$ENDIF}
end;

class procedure TNesInputHandler.CombineInput(const Context: TInputRuntimeContext; var Input: TEmulatorInput);
const
  Mapping: array[TNesButton] of TEmulatorButton = (TEmulatorButton.A,
    TEmulatorButton.B, TEmulatorButton.Select, TEmulatorButton.Start,
    TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left, TEmulatorButton.Right);
begin
  var Devices := NesInputState(Context);
  var Piano: INesMiraclePianoCore;
  if Supports(Context.State.Session.Emulation, INesMiraclePianoCore, Piano) and Piano.UsesMiraclePiano then
  begin
    for var Button in Devices.MiraclePiano.Buttons do
      Include(Input.Buttons, Mapping[Button]);
    if Context.State.Input.Manager <> nil then
      for var Button := Low(TNesButton) to High(TNesButton) do
        if Context.State.Input.Manager.IsPressed(PadAction(0, Mapping[Button])) then
          Include(Input.Buttons, Mapping[Button]);
  end;
end;

class procedure TNesInputHandler.UpdateInput(const Context: TInputRuntimeContext);
begin
  var Devices := NesInputState(Context);
  var Peripheral: INesPeripheralCore;
  if Supports(Context.State.Session.Emulation, INesPeripheralCore, Peripheral) then
  begin
    if NesUsesSuborKeyboard(Context.State.Session.Emulation) then
      Peripheral.SetSuborKeys(Devices.SuborKeyboard.Keys + ReadSuborInput(Context.State.Input.Manager));
    if Peripheral.UsesFamicomKeyboard then
      Peripheral.SetFamicomKeys(Devices.FamicomKeyboard.Keys + ReadFamicomInput(Context.State.Input.Manager));
    if Peripheral.UsesPowerPad then
    begin
      var Buttons := Devices.PowerPad.Buttons;
      if Context.State.Input.Manager <> nil then
        for var i := 0 to 11 do
          if Context.State.Input.Manager.IsPressed(PowerPadAction + i) then
            Include(Buttons, i + 1);
      Peripheral.SetPowerPadButtons(Buttons);
    end;
  end;

  var Piano: INesMiraclePianoCore;
  if Supports(Context.State.Session.Emulation, INesMiraclePianoCore, Piano) and Piano.UsesMiraclePiano then
    Piano.SetMiracleKeys(Devices.MiraclePiano.Keys + ReadPianoInput(Context.State.Input.Manager));
end;

class procedure TNesInputHandler.UpdateFeedback(const Context: TInputRuntimeContext);
var
  Peripheral: INesPeripheralCore;
  Tape: INesTapeCore;
  Piano: INesMiraclePianoCore;
begin
  var Devices := NesInputState(Context);
  if (Context.State.Session.Emulation = nil) or Context.State.Session.EmulationFaulted then
    Exit;

  if (Devices.MiraclePiano <> nil) and Devices.MiraclePiano.Visible and Devices.MiraclePiano.Enabled and
    Supports(Context.State.Session.Emulation, INesMiraclePianoCore, Piano) then
    Devices.MiraclePiano.CoreKeys := Piano.GetMiracleKeys;
  if (Devices.DataRecorder <> nil) and Supports(Context.State.Session.Emulation, INesTapeCore, Tape) and Tape.UsesDataRecorder then
    Devices.DataRecorder.Progress := Tape.GetTapeProgress;
  if (Context.State.Input.Gamepad <> nil) and Context.State.Input.Gamepad.Visible and Context.State.Input.Gamepad.Enabled then
    Context.State.Input.Gamepad.CoreButtons := Context.State.Session.Emulation.GetInputState.Buttons;
  if Supports(Context.State.Session.Emulation, INesPeripheralCore, Peripheral) then
  begin
    if (Devices.SuborKeyboard <> nil) and Devices.SuborKeyboard.Visible and Devices.SuborKeyboard.Enabled then
    begin
      Devices.SuborKeyboard.CoreKeys := Peripheral.GetSuborKeys;
      Devices.SuborKeyboard.Indicators := Peripheral.GetSuborIndicators;
    end;
    if (Devices.FamicomKeyboard <> nil) and Devices.FamicomKeyboard.Visible and Devices.FamicomKeyboard.Enabled then
      Devices.FamicomKeyboard.CoreKeys := Peripheral.GetFamicomKeys;
    if (Devices.PowerPad <> nil) and Devices.PowerPad.Visible and Devices.PowerPad.Enabled then
      Devices.PowerPad.CoreButtons := Peripheral.GetPowerPadButtons;
  end;
end;

class procedure TNesInputHandler.PollInput(const Context: TInputRuntimeContext);
begin
  var Devices := NesInputState(Context);
  var Peripheral: INesPeripheralCore;
  if Supports(Context.State.Session.Emulation, INesPeripheralCore, Peripheral) then
  begin
    if Peripheral.Zapper.Enabled then
    begin
      var Mouse: IFMXMouseService;
      if TPlatformServices.Current.SupportsPlatformService(IFMXMouseService, Mouse) then
      begin
        var Point := Context.View.ImageCanvas.AbsoluteToLocal(Context.View.ScreenToClient(Mouse.GetMousePos));
        TryGetImagePixel(Context.View.ImageCanvas, Point.X, Point.Y, Devices.ZapperPixel.X, Devices.ZapperPixel.Y);
      end;
      Peripheral.Zapper.TriggerPressed := Context.State.Input.Manager.IsPressed(ZapperTriggerAction);
    end;
  end;
end;

class procedure TNesInputHandler.ScreenInputChanged(const Context: TInputRuntimeContext; Sender: TObject);
var
  Piano: INesMiraclePianoCore;
begin
  var Devices := NesInputState(Context);
  if Sender = Devices.MiraclePiano then
  begin
    if not Supports(Context.State.Session.Emulation, INesMiraclePianoCore, Piano) or not Piano.UsesMiraclePiano then
      Exit;

    Context.View.UpdatePeripheralInput;
    Context.State.Session.Emulation.SetGamepadInput(Context.View.CombinedGamepadInput);
  end
  else if (Sender = Devices.SuborKeyboard) or (Sender = Devices.FamicomKeyboard) or
    (Sender = Devices.PowerPad) then
    Context.View.UpdatePeripheralInput;
end;

class procedure TNesInputHandler.PointerButton(const Context: TInputRuntimeContext; X, Y: Single; Pressed: Boolean);
var
  Peripheral: INesPeripheralCore;
begin
  var Devices := NesInputState(Context);
  if Supports(Context.State.Session.Emulation, INesPeripheralCore, Peripheral) then
  begin
    if Pressed then
      TryGetImagePixel(Context.View.ImageCanvas, X, Y, Devices.ZapperPixel.X, Devices.ZapperPixel.Y);
    Peripheral.Zapper.TriggerPressed := Pressed;
  end;
end;

class procedure TNesInputHandler.DoTapeAction(const Context: TInputRuntimeContext; Action: TTapeAction; const FileName: string);
begin
  var Devices := NesInputState(Context);
  var Tape: INesTapeCore;
  if not Supports(Context.State.Session.Emulation, INesTapeCore, Tape) then
    Exit;

  try
    Tape.TapeCommand(Action, FileName);
    Devices.DataRecorder.Progress := Tape.GetTapeProgress;
  except
    on E: Exception do
      ShowRetroMessage(Context.View, Translate('Cassette: ') + E.Message);
  end;
end;

class procedure TNesInputHandler.DoSelectTapeFile(const Context: TInputRuntimeContext; const FileName: string);
begin
  var Devices := NesInputState(Context);
  var Tape: INesTapeCore;
  if not Supports(Context.State.Session.Emulation, INesTapeCore, Tape) or not Tape.UsesDataRecorder then
    raise EInvalidOperation.Create(Translate('No data recorder connected'));

  Tape.TapeCommand(TapeSelectFile, FileName);
  Devices.DataRecorder.Progress := Tape.GetTapeProgress;
end;

class procedure TNesInputHandler.DoSaveTapeAs(const Context: TInputRuntimeContext);
begin
  var Devices := NesInputState(Context);
  var Tape: INesTapeCore;
  if not Supports(Context.State.Session.Emulation, INesTapeCore, Tape) or not Tape.UsesDataRecorder then
    Exit;

  Context.View.FormDeactivate(Context.View);
  {$IFDEF ANDROID}
  if Context.State.Session.OpeningRom then
    Exit;

  var Path := Context.State.Session.Storage.TemporaryFile('.tape');
  try
    Tape.TapeCommand(TapeSaveAs, Path);
    Context.State.Mobile.Transfer.Save(Path, ExtractFileName(Tape.GetTapeProgress.FileName));
    Context.State.Session.OpeningRom := True;
    Context.View.SyncActivity;
  except
    on E: Exception do
    begin
      Context.State.Session.Storage.Delete(Path);
      ShowRetroMessage(Context.View, Translate('Cassette: ') + E.Message);
    end;
  end;
  {$ELSE}
  var Dialog := TSaveDialog.Create(Context.View);
  try
    Dialog.Title := Translate('Save cassette as');
    Dialog.Filter := Translate('Cassette (*.tape)|*.tape');
    Dialog.DefaultExt := 'tape';
    Dialog.Options := [TOpenOption.ofPathMustExist, TOpenOption.ofOverwritePrompt];
    Dialog.FileName := Tape.GetTapeProgress.FileName;
    if Dialog.Execute then
    try
      Tape.TapeCommand(TapeSaveAs, Dialog.FileName);
      Devices.DataRecorder.Progress := Tape.GetTapeProgress;
    except
      on E: Exception do
        ShowRetroMessage(Context.View, Translate('Cassette: ') + E.Message);
    end;
  finally
    Dialog.Free;
    Context.View.FormActivate(Context.View);
  end;
  {$ENDIF}
end;

class procedure TNesInputHandler.Command(const Context: TInputRuntimeContext; const Name: string; Code: Integer; const FileName: string);
begin
  if Name = 'tape.action' then
    DoTapeAction(Context, TTapeAction(Code), FileName)
  else if Name = 'tape.select' then
    DoSelectTapeFile(Context, FileName)
  else if Name = 'tape.saveas' then
    DoSaveTapeAs(Context)
  else
    inherited Command(Context, Name, Code, FileName);
end;

end.

