unit OneEmu.Main;

interface

uses
  System.Classes, System.SysUtils, System.Types, System.UITypes,
  System.Generics.Collections, FMX.Types, FMX.Controls, FMX.Forms, FMX.Layouts,
  FMX.Objects, FMX.StdCtrls, FMX.ListBox, FMX.Graphics, Core.Emulation,
  Core.Platforms, Core.InputConfig, Core.Storage, FMXInput, RM.Gamepad,
  RM.ShaderBitmap, RM.Settings, RM.Input.Runtime, RM.Platform.Host,
  FMX.Controls.Presentation;

type
  TOneEmuMenu = (Closed, Main, Options);

  TFormMain = class(TForm)
  published
    TimerFrame: TTimer;
    RectangleWindow, RectangleStage, RectangleShade, RectangleMenu: TRectangle;
    LayoutHeader, LayoutToolbar, LayoutStatus, LayoutStage, LayoutOutput: TLayout;
    LayoutEmpty, LayoutOverlay, LayoutGameOptions, LayoutSettings, LayoutFullscreenToolbar: TLayout;
    LayoutSlots, LayoutStatePreview, LayoutStateButtons: TLayout;
    LabelBrand, LabelPlatform, LabelRom, LabelActivity, LabelStatus, LabelFrame: TLabel;
    LabelEmptyTitle, LabelEmptyFormats, LabelMenuGame, LabelState, LabelSlot, LabelStateTime: TLabel;
    LabelOptions: TLabel;
    ImageState: TImage;
    ButtonMenu, ButtonFullscreen, ButtonFullscreenMenu, ButtonEmptyOpen, ButtonResume: TButton;
    ButtonOpenRom, ButtonOptions, ButtonLoadState, ButtonSaveState, ButtonSettings: TButton;
    ButtonMenuFullscreen, ButtonCloseRom, ButtonOptionsBack, ButtonPause, ButtonMute: TButton;
    ButtonRestart, ButtonCoin: TButton;
    ComboBoxSlot: TComboBox;
    VertScrollBoxMainMenu, VertScrollBoxActions: TVertScrollBox;
    procedure TimerFrameTimer(Sender: TObject);
    procedure MenuClick(Sender: TObject);
    procedure FullscreenClick(Sender: TObject);
    procedure OpenRomClick(Sender: TObject);
    procedure ResumeClick(Sender: TObject);
    procedure OptionsClick(Sender: TObject);
    procedure BackToMenuClick(Sender: TObject);
    procedure SaveStateClick(Sender: TObject);
    procedure LoadStateClick(Sender: TObject);
    procedure SlotChange(Sender: TObject);
    procedure SettingsClick(Sender: TObject);
    procedure CloseRomClick(Sender: TObject);
    procedure PauseClick(Sender: TObject);
    procedure MuteClick(Sender: TObject);
    procedure RestartClick(Sender: TObject);
    procedure CoinClick(Sender: TObject);
    procedure ActivityChanged(Sender: TObject);
    procedure FormActivate(Sender: TObject);
    procedure FormDeactivate(Sender: TObject);
    procedure StageResize(Sender: TObject);
  private
    FHost: IPlatformHost;
    FRuntime: TInputRuntimeContext;
    FStorage: IStorage;
    FCore: IEmulationCore;
    FStartupPlatform: TPlatformInfo;
    FInput: TInputManager;
    FPorts: TCoreInputPorts;
    FGamepad: TScreenGamepad;
    FViewport: TShaderBitmap;
    FSettings: TSettingsView;
    FData: TDictionary<string, IInterface>;
    FAlive: TFunc<Boolean>;
    FInvalidate: TProc;
    FMenu: TOneEmuMenu;
    FRom, FDisplayName, FActivityText: string;
    FLoading, FPicking, FInactive, FPaused, FPauseSent, FFailed, FCompleted: Boolean;
    FReady, FConnected, FUpdating, FSettingsClosing, FInputFailed: Boolean;
    FSlotOccupied: Boolean;
    FKeysDown: TDictionary<Word, Boolean>;
    FSnapshot: IEmulationSnapshotOperation;
    FSnapshotName: string;
    FSnapshotLoading: Boolean;
    function SystemId: string;
    function CurrentPlatform: TPlatformInfo;
    function Busy: Boolean;
    function CanPlay: Boolean;
    procedure SyncActivity;
    procedure RefreshChrome;
    procedure SetMenu(Value: TOneEmuMenu);
    procedure SetStatus(const Text: string);
    procedure ClearInput;
    procedure ReloadInput;
    procedure SubmitInput;
    procedure ForwardKey(Code: Word; Pressed: Boolean);
    procedure PeripheralChanged(Sender: TObject);
    procedure ViewportDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Single);
    procedure ViewportMove(Sender: TObject; Shift: TShiftState; X, Y: Single);
    procedure ViewportUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Single);
    procedure InstallCore(const Loaded: IEmulationCore; const Location: string);
    procedure StopCore;
    procedure PresentFrame;
    procedure DoReset;
    procedure Fail(const Text: string);
    procedure RebuildGameActions;
    procedure GameActionClick(Sender: TObject);
    procedure MoveDiscClick(Sender: TObject);
    function SlotName: string;
    function StatePath(const Name: string): string;
    procedure UpdateSlot;
    procedure DoSnapshot(Loading: Boolean);
    procedure PollSnapshot;
    procedure SnapshotDone(const Name: string; Loading: Boolean);
    procedure SettingsApplied(Sender: TObject);
    procedure SettingsClosed(Sender: TObject);
    procedure CloseSettings;
  protected
    function CreateStorage: IStorage; virtual;
  public
    procedure KeyDown(var Key: Word; var KeyChar: WideChar; Shift: TShiftState); override;
    procedure KeyUp(var Key: Word; var KeyChar: WideChar; Shift: TShiftState); override;
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure LoadRom(const Location: string);
  end;

var
  FormMain: TFormMain;

implementation

uses
  System.IniFiles, System.IOUtils, System.Math, System.StrUtils, FMX.Dialogs,
  FMX.OpenDialog, FMX.Platform, FMX.Controls.Presentation, Core.Emulation.Types,
  Core.EmulatorRegistry, Core.EmulatorFactory, Core.SavePaths,
  RM.Session.Runtime, RM.Settings.Runtime, RM.Settings.Catalog,
  RM.Platforms.Presentation, RM.Storage.Dialogs, RM.Styles, RM.Dialogs,
  RM.Controls.Lifetime, RM.Input, RM.Input.Gamepads, RM.FrameUpload,
  RM.Window.Layout, WinUI3.Style;

{$R *.fmx}

type
  TOneEmuHost = class(TInterfacedObject, IPlatformHost, IPlatformInput, IPlatformVideo, IFmxPlatformSurface, IPlatformDocuments)
  private
    FForm: TFormMain;
    function GetCore: IEmulationCore;
    function GetSystemId: string;
    function GetStorage: IStorage;
    function GetActivity: TPlatformActivity;
    function GetInput: IPlatformInput;
    function GetVideo: IPlatformVideo;
    function GetData(const Key: string): IInterface;
    procedure SetData(const Key: string; const Value: IInterface);
    procedure ResetGame;
    procedure SetStatus(const Text: string);
    procedure ShowMessage(const Text: string; IsError: Boolean);
    function GetPorts: TCoreInputPorts;
    procedure SetPorts(const Ports: TCoreInputPorts);
    function GetHasInputSource: Boolean;
    function GetBindings: TArray<TInputBinding>;
    function IsActionPressed(Action: Integer): Boolean;
    function ActionAmount(Action: Integer): Single;
    function DigitalAnalogAmount(Action: Integer; Pressed: Boolean): Single;
    procedure ClearCachedInput;
    procedure RequestInputUpdate(SubmitToCore: Boolean);
    function TryLocalToFrame(const Point: TPointF; out Pixel: TPoint): Boolean;
    function TryScreenToFrame(const Point: TPointF; out Pixel: TPoint): Boolean;
    function TryPointerToFrame(out Pixel: TPoint): Boolean;
    function GetPointerCaptured: Boolean;
    procedure SetPointerCaptured(Value: Boolean);
    procedure SetPointerInputEnabled(Enabled, ShowFocus: Boolean);
    procedure FitFrame;
    function GetInputForm: TCommonCustomForm;
    function GetContent: TControl;
    function GetFrameLayer: TImage;
    function GetGamepad: TScreenGamepad;
    function GetUsableSize: TSizeF;
    function GetBottomInset: Single;
    procedure OpenDocument(const Request: TPlatformDocumentRequest; const Selected: TPlatformDocumentAction);
    procedure SaveDocument(const Request: TPlatformDocumentRequest; const Write: TPlatformDocumentAction);
  public
    constructor Create(Form: TFormMain);
  end;

constructor TFormMain.Create(AOwner: TComponent);
begin
  inherited;
  var Cores := RegisteredEmulationCores;
  if Length(Cores) <> 1 then
    raise EInvalidOperation.Create('OneEmu requires exactly one registered core.');
  var Platforms := TPlatformRegistry.All;
  if Length(Platforms) = 0 then
    raise EInvalidOperation.Create('The core has no registered systems.');
  FStartupPlatform := Platforms[0];
  for var Info in Platforms do
    if SameText(Info.Id, Info.SettingsCoreId) then
    begin
      FStartupPlatform := Info;
      Break;
    end;

  var Alive := True;
  FAlive :=
    function: Boolean
    begin
      Result := Alive;
    end;
  FInvalidate :=
    procedure
    begin
      Alive := False;
    end;
  FStorage := CreateStorage;
  FData := TDictionary<string, IInterface>.Create;
  FKeysDown := TDictionary<Word, Boolean>.Create;
  FormStyles := TFormStyles.Create(Self);
  FormStyles.SetLanguage('ru');
  ChangeStyleBookColor(FormStyles.StyleBookWinUI3, $FFAC99F0);
  StyleBook := FormStyles.StyleBookWinUI3;
  FViewport := TShaderBitmap.Create(Self);
  FViewport.Name := 'ShaderBitmapGame';
  FViewport.Parent := LayoutOutput;
  FViewport.Align := TAlignLayout.Client;
  FViewport.WrapMode := TImageWrapMode.Fit;
  FViewport.DisableInterpolation := True;
  FViewport.AutoCapture := True;
  FViewport.OnMouseDown := ViewportDown;
  FViewport.OnMouseMove := ViewportMove;
  FViewport.OnMouseUp := ViewportUp;
  FGamepad := TScreenGamepad.Create(Self);
  FGamepad.Name := 'ScreenGamepadVirtual';
  FGamepad.Parent := LayoutStage;
  FGamepad.Align := TAlignLayout.Bottom;
  FGamepad.Visible := False;
  FGamepad.OnChange := PeripheralChanged;
  LayoutOverlay.BringToFront;
  ButtonFullscreenMenu.BringToFront;
  {$IF Defined(MSWINDOWS) or Defined(LINUX) or Defined(ANDROID) or (Defined(MACOS) and not Defined(IOS))}
  FInput := TGamepadInputManager.Create(CreateFMXInputBackend);
  {$ENDIF}
  FHost := TOneEmuHost.Create(Self);
  FRuntime.Host := FHost;
  FRuntime.ScreenInputChanged := PeripheralChanged;
  InitializePlatformInputHandlers(FRuntime);
  ReloadInput;
  SetRetroDialogActivity(Self, ActivityChanged);
  ComboBoxSlot.ItemIndex := 0;
  FReady := True;
  RefreshChrome;
  TimerFrame.Enabled := True;
end;

destructor TFormMain.Destroy;
begin
  FReady := False;
  if Assigned(FInvalidate) then
    FInvalidate();
  if TimerFrame <> nil then
    TimerFrame.Enabled := False;
  if FHost <> nil then
  begin
    SetRetroDialogActivity(Self, nil);
    CloseSettings;
    StopCore;
    FinalizePlatformInputHandlers(FRuntime);
    FRuntime := Default(TInputRuntimeContext);
    FHost := nil;
  end;
  if FGamepad <> nil then
  begin
    FGamepad.OnChange := nil;
    FGamepad.AttachToForm(nil);
  end;
  FInput.Free;
  FKeysDown.Free;
  FData.Free;
  if (FormStyles <> nil) and (FormStyles.Owner = Self) then
    FormStyles := nil;
  inherited;
end;

function TFormMain.CreateStorage: IStorage;
begin
  var Root := TPath.GetDocumentsPath;
  if not TPath.IsPathRooted(Root) then
    Root := TPath.GetHomePath;
  if not TPath.IsPathRooted(Root) then
    raise EInOutError.Create('Cannot determine OneEmu data directory.');
  Result := TStorage.Create(TPath.Combine(Root, 'OneEmu'), TStoragePicker.Create);
end;

function TFormMain.SystemId: string;
begin
  if FCore <> nil then
    Result := FCore.SystemId
  else
    Result := FStartupPlatform.Id;
end;

function TFormMain.CurrentPlatform: TPlatformInfo;
begin
  if not TPlatformRegistry.Find(SystemId, Result) then
    Result := FStartupPlatform;
end;

function TFormMain.Busy: Boolean;
begin
  Result := FLoading or FPicking or (FSnapshot <> nil);
end;

function TFormMain.CanPlay: Boolean;
begin
  Result := FReady and (FCore <> nil) and not (Busy or FInactive or FPaused or FFailed or FCompleted) and
    (FMenu = TOneEmuMenu.Closed) and (FSettings = nil) and not RetroDialogVisible(Self);
end;

procedure TFormMain.SyncActivity;
begin
  if not FReady then
    Exit;
  if FCore <> nil then
  begin
    var PauseNow := not CanPlay;
    if PauseNow <> FPauseSent then
    begin
      FPauseSent := PauseNow;
      if PauseNow then
      begin
        ClearInput;
        FCore.Pause;
      end
      else
        FCore.Resume;
    end;
    PlatformSessionHandler(SystemId).SyncActivity(FRuntime);
    SyncSessionTouch(FRuntime);
    PlatformSessionHandler(SystemId).ApplyActivityGate(FRuntime);
    StageResize(Self);
  end;
  RefreshChrome;
end;

procedure TFormMain.RefreshChrome;
begin
  var HasGame := FCore <> nil;
  var platform := CurrentPlatform;
  LabelPlatform.Text := Translate(platform.Name);
  Caption := 'OneEmu · ' + platform.ShortName;
  LabelRom.Text := FDisplayName;
  if not HasGame then
    LabelRom.Text := 'ROM не открыт';
  LabelMenuGame.Text := LabelRom.Text;
  LabelEmptyFormats.Text := string.Join(' · ', platform.Extensions);
  if FLoading then
    LabelActivity.Text := 'Открытие ROM…'
  else if FFailed then
    LabelActivity.Text := 'Ошибка эмуляции'
  else if FCompleted then
    LabelActivity.Text := 'Игра завершена'
  else if not HasGame then
    LabelActivity.Text := 'Готов к запуску'
  else if not CanPlay then
    LabelActivity.Text := 'На паузе'
  else
    LabelActivity.Text := 'Идёт игра';
  if FActivityText = '' then
    LabelStatus.Text := LabelActivity.Text
  else
    LabelStatus.Text := FActivityText;
  var ShowGame := FSettings = nil;
  LayoutHeader.Visible := not FullScreen;
  LayoutToolbar.Visible := not FullScreen and ShowGame;
  LayoutStatus.Visible := not FullScreen;
  LayoutStage.Visible := ShowGame;
  LayoutSettings.Visible := not ShowGame;
  LayoutEmpty.Visible := not HasGame;
  LayoutOutput.Visible := HasGame;
  LayoutOverlay.Visible := FMenu <> TOneEmuMenu.Closed;
  VertScrollBoxMainMenu.Visible := FMenu = TOneEmuMenu.Main;
  LayoutGameOptions.Visible := FMenu = TOneEmuMenu.Options;
  LayoutFullscreenToolbar.Visible := FullScreen and not LayoutOverlay.Visible;
  ButtonFullscreenMenu.Visible := LayoutFullscreenToolbar.Visible;
  ButtonEmptyOpen.Enabled := not Busy;
  ButtonOpenRom.Enabled := not Busy;
  ButtonCloseRom.Enabled := HasGame and not Busy;
  ButtonResume.Enabled := HasGame and not (Busy or FFailed or FCompleted);
  ButtonOptions.Enabled := HasGame and not Busy;
  ButtonSettings.Enabled := not Busy;
  LayoutSlots.Visible := HasGame and FCore.SupportsSnapshots;
  LayoutStatePreview.Visible := LayoutSlots.Visible;
  LayoutStateButtons.Visible := LayoutSlots.Visible;
  ComboBoxSlot.Enabled := not Busy;
  ButtonSaveState.Enabled := LayoutSlots.Visible and not (Busy or FFailed or FCompleted);
  ButtonLoadState.Enabled := LayoutSlots.Visible and not Busy and FSlotOccupied;
  ButtonCoin.Visible := HasGame and FCore.HasCoinAcceptor;
  var LiveSettings: IEmulationLiveSettings;
  ButtonMute.Visible := HasGame and Supports(FCore, IEmulationLiveSettings, LiveSettings);
  if ButtonMute.Visible and FCore.Config.AudioEnabled then
    ButtonMute.Text := 'Выключить звук'
  else
    ButtonMute.Text := 'Включить звук';
  if FPaused then
    ButtonPause.Text := 'Снять паузу'
  else
    ButtonPause.Text := 'Пауза';
  if FullScreen then
    ButtonMenuFullscreen.Text := 'Оконный режим   F11'
  else
    ButtonMenuFullscreen.Text := 'Полный экран   F11';
end;

procedure TFormMain.SetMenu(Value: TOneEmuMenu);
begin
  if (FSettings <> nil) or (FMenu = Value) then
    Exit;
  FMenu := Value;
  if Value = TOneEmuMenu.Main then
    UpdateSlot;
  if Value = TOneEmuMenu.Options then
    RebuildGameActions;
  SyncActivity;
end;

procedure TFormMain.SetStatus(const Text: string);
begin
  FActivityText := Text;
  if Text = '' then
    LabelStatus.Text := LabelActivity.Text
  else
    LabelStatus.Text := Text;
end;

procedure TFormMain.LoadRom(const Location: string);
begin
  if (Location = '') or Busy or (FSettings <> nil) then
    Exit;
  FLoading := True;
  FActivityText := '';
  SyncActivity;
  var IsAlive: TFunc<Boolean> := FAlive;
  var Storage := FStorage;
  TThread.CreateAnonymousThread(
    procedure
    var
      Loaded: IEmulationCore;
    begin
      var ErrorText := '';
      try
        var Stream := Storage.OpenRead(Location);
        try
          Loaded := CreateEmulationCore(Stream, Storage, Location);
        finally
          Stream.Free;
        end;
      except
        on E: Exception do
          ErrorText := E.Message;
      end;
      TThread.Queue(nil,
        procedure
        begin
          if not IsAlive() then
            Exit;
          FLoading := False;
          try
            if ErrorText <> '' then
              raise EReadError.Create(ErrorText);
            InstallCore(Loaded, Location);
          except
            on E: Exception do
              ShowRetroMessage(Self, TranslateCoreMessage(E.Message));
          end;
          SyncActivity;
        end);
    end).Start;
end;

procedure TFormMain.InstallCore(const Loaded: IEmulationCore; const Location: string);
begin
  var Name := FStorage.Describe(Location).Name;
  StopCore;
  FCore := Loaded;
  FRom := Location;
  FDisplayName := Name;
  FMenu := TOneEmuMenu.Closed;
  FPaused := False;
  FPauseSent := False;
  try
    ReloadInput;
    var Ini := FStorage.ReadConfig(FCore.Config.FileName);
    try
      FViewport.LoadSettings(Ini);
    finally
      Ini.Free;
    end;
    FViewport.DisableInterpolation := SameText(FCore.Config.Filter, 'nearest');
    FViewport.ResetHistory;
    FConnected := True;
    PlatformSessionHandler(SystemId).Connect(FRuntime);
    FCore.Start;
  except
    StopCore;
    raise;
  end;
  UpdateSlot;
end;

procedure TFormMain.StopCore;
begin
  if FCore = nil then
    Exit;
  if FSnapshot <> nil then
  begin
    FSnapshot.CancelSnapshot;
    FSnapshot := nil;
  end;
  ClearInput;
  ReleaseSessionInputs(FRuntime);
  FCore.Stop;
  DetachSessionTouch(FRuntime);
  if FConnected then
  begin
    FConnected := False;
    PlatformSessionHandler(SystemId).Disconnect(FRuntime);
  end;
  FCore := nil;
  FRom := '';
  FDisplayName := '';
  FActivityText := '';
  FFailed := False;
  FCompleted := False;
  LabelFrame.Text := '';
  FViewport.Bitmap.SetSize(0, 0);
  FViewport.ResetHistory;
end;

procedure TFormMain.ReloadInput;
begin
  var FileName := FStorage.ConfigFile(CurrentPlatform.SettingsCoreId);
  if FCore <> nil then
    FileName := FCore.Config.FileName;
  var Ini := FStorage.ReadConfig(FileName);
  try
    FPorts := ReadCoreInputPorts(Ini, SystemId);
    if FInput <> nil then
    begin
      LoadInputBindings(FInput, Ini, SystemId);
      FilterInputBindings(FInput, Ini, SystemId);
      TGamepadInputManager(FInput).LoadAnalogSettings(Ini);
      FInputFailed := False;
    end;
  finally
    Ini.Free;
  end;
end;

procedure TFormMain.ClearInput;
begin
  CancelScreenTouch(FRuntime);
  if FInput <> nil then
    FInput.Enabled := False;
  if FGamepad <> nil then
    FGamepad.ReleaseAll;
  if FCore <> nil then
    FCore.ClearInput;
end;

procedure TFormMain.SubmitInput;
begin
  if not CanPlay or FUpdating then
    Exit;
  FUpdating := True;
  try
    var Handler := PlatformInputHandler(SystemId);
    var Packet := Default(TEmulatorInput);
    if (FInput <> nil) and not FInputFailed then
      Packet := ReadPadInput(FInput, FPorts);
    if FGamepad.Enabled and FGamepad.Visible and (FPorts.Devices[0] <> 'none') then
    begin
      var VirtualPad := Default(TEmulatorInput);
      VirtualPad.Buttons := FGamepad.Buttons;
      Packet.Buttons := Packet.Buttons + VirtualPad.Buttons;
      if FGamepad.AnalogInput.Valid then
        Packet.Analog[0] := FGamepad.AnalogInput;
      MergeVirtualAnalogButtons(FInput, VirtualPad, Packet);
    end;
    Handler.CombineInput(FRuntime, Packet);
    FCore.SetGamepadInput(Packet);
    Handler.UpdateInput(FRuntime);
  finally
    FUpdating := False;
  end;
end;

procedure TFormMain.ForwardKey(Code: Word; Pressed: Boolean);
begin
  if (FCore = nil) or (Code = 0) then
    Exit;
  var Handler := PlatformInputHandler(SystemId);
  var Policy := Handler.KeyPolicy(FRuntime);
  if not Handler.ForwardKey(FRuntime, Code, Pressed) and
    ((FInput = nil) or FInputFailed or Policy.ForwardWithManager or Policy.KeyboardActive) then
    FCore.SetKeyState(Code, Pressed);
end;

procedure TFormMain.PeripheralChanged(Sender: TObject);
begin
  if CanPlay then
  begin
    if Sender <> FGamepad then
      PlatformInputHandler(SystemId).ScreenInputChanged(FRuntime, Sender);
    SubmitInput;
  end;
end;

procedure TFormMain.PresentFrame;
begin
  var Frame: TEmulatorFrame;
  if not FCore.TryGetFrame(Frame) then
    Exit;
  if (FViewport.Bitmap.Width <> Frame.Width) or (FViewport.Bitmap.Height <> Frame.Height) then
    FViewport.Bitmap.SetSize(Frame.Width, Frame.Height);
  var Regions: IEmulationVideoRegions;
  if Supports(FCore, IEmulationVideoRegions, Regions) then
    FViewport.ScreenRegions := Regions.GetVideoRegions
  else
    FViewport.ScreenRegions := nil;
  var Pixels: TBitmapData;
  if FViewport.Bitmap.Map(TMapAccess.Write, Pixels) then
  try
    UploadFramePixels(Frame.Pixels, Frame.Width, Frame.Height, Pixels);
  finally
    FViewport.Bitmap.Unmap(Pixels);
  end;
  FViewport.Repaint;
  LabelFrame.Text := Format('%s  ·  %d × %d  ·  %.1f FPS',
    [CurrentPlatform.ShortName, Frame.Width, Frame.Height, Frame.FramesPerSecond]);
  PlatformSessionHandler(SystemId).FramePresented(FRuntime);
end;

procedure TFormMain.TimerFrameTimer(Sender: TObject);
begin
  if not FReady then
    Exit;
  try
    if (FInput <> nil) and not FInputFailed then
    try
      FInput.Enabled := CanPlay or ((FSettings <> nil) and not FSettingsClosing) or RetroDialogVisible(Self);
      if FInput.Enabled then
        FInput.Poll;
    except
      on E: Exception do
      begin
        FInputFailed := True;
        FInput.Enabled := False;
        SetStatus(E.Message);
      end;
    end;
    if (FSettings <> nil) and not FSettingsClosing then
      FSettings.Poll;
    if FCore = nil then
      Exit;
    PollSnapshot;
    if FFailed then
      Exit;
    ValidateScreenTouch(FRuntime);
    if CanPlay then
    begin
      var Handler := PlatformInputHandler(SystemId);
      Handler.PollInput(FRuntime);
      SubmitInput;
      Handler.UpdateFeedback(FRuntime);
    end;
    PresentFrame;
    PlatformSessionHandler(SystemId).FrameStatus(FRuntime);
    var ErrorText := FCore.TakeError;
    if ErrorText <> '' then
      Fail(ErrorText)
    else
    begin
      var Completion: IEmulationCompletion;
      if not FCompleted and Supports(FCore, IEmulationCompletion, Completion) and Completion.IsFinished then
      begin
        FCompleted := True;
        FMenu := TOneEmuMenu.Main;
        SyncActivity;
      end;
    end;
  except
    on E: Exception do
      Fail(E.Message);
  end;
end;

procedure TFormMain.Fail(const Text: string);
begin
  if FFailed then
    Exit;
  FFailed := True;
  FMenu := TOneEmuMenu.Main;
  SyncActivity;
  ShowRetroMessage(Self, TranslateCoreMessage(Text));
end;

procedure TFormMain.MenuClick(Sender: TObject);
begin
  if FMenu = TOneEmuMenu.Closed then
    SetMenu(TOneEmuMenu.Main)
  else if FMenu = TOneEmuMenu.Options then
    SetMenu(TOneEmuMenu.Main)
  else
    SetMenu(TOneEmuMenu.Closed);
end;

procedure TFormMain.FullscreenClick(Sender: TObject);
begin
  if FSettings <> nil then
    Exit;
  FullScreen := not FullScreen;
  SetMenu(TOneEmuMenu.Closed);
  SyncActivity;
end;

procedure TFormMain.OpenRomClick(Sender: TObject);
begin
  if Busy then
    Exit;
  var IsAlive: TFunc<Boolean> := FAlive;
  FPicking := True;
  SyncActivity;
  try
    FStorage.SelectRom(
      procedure(const Selection: TStorageSelection)
      begin
        if not IsAlive() then
          Exit;
        FPicking := False;
        if Selection.Error <> '' then
          ShowRetroMessage(Self, Selection.Error)
        else if not Selection.Cancelled then
          LoadRom(Selection.Location);
        SyncActivity;
      end);
  except
    on E: Exception do
    begin
      FPicking := False;
      SyncActivity;
      ShowRetroMessage(Self, E.Message);
    end;
  end;
end;

procedure TFormMain.ResumeClick(Sender: TObject);
begin
  FPaused := False;
  SetMenu(TOneEmuMenu.Closed);
end;

procedure TFormMain.OptionsClick(Sender: TObject);
begin
  SetMenu(TOneEmuMenu.Options);
end;

procedure TFormMain.BackToMenuClick(Sender: TObject);
begin
  SetMenu(TOneEmuMenu.Main);
end;

procedure TFormMain.CloseRomClick(Sender: TObject);
begin
  if Busy then
    Exit;
  StopCore;
  ReloadInput;
  SetMenu(TOneEmuMenu.Closed);
  RefreshChrome;
end;

procedure TFormMain.PauseClick(Sender: TObject);
begin
  FPaused := not FPaused;
  SetMenu(TOneEmuMenu.Closed);
  SyncActivity;
end;

procedure TFormMain.MuteClick(Sender: TObject);
begin
  var Live: IEmulationLiveSettings;
  if Supports(FCore, IEmulationLiveSettings, Live) then
  try
    FCore.Config.AudioEnabled := not FCore.Config.AudioEnabled;
    Live.ApplyLiveSettings;
    RefreshChrome;
  except
    on E: Exception do
      ShowRetroMessage(Self, E.Message);
  end;
end;

procedure TFormMain.DoReset;
begin
  if (FCore = nil) or Busy then
    Exit;
  try
    ClearInput;
    FCore.Reset;
    FFailed := False;
    FPaused := False;
    FCompleted := False;
    FActivityText := '';
    SetMenu(TOneEmuMenu.Closed);
    SyncActivity;
  except
    on E: Exception do
      Fail(E.Message);
  end;
end;

procedure TFormMain.RestartClick(Sender: TObject);
begin
  DoReset;
end;

procedure TFormMain.CoinClick(Sender: TObject);
begin
  if (FCore <> nil) and FCore.HasCoinAcceptor then
    FCore.InsertCoin1;
end;

procedure TFormMain.RebuildGameActions;

  procedure Add(const Text, Id: string; Enabled: Boolean; Click: TNotifyEvent);
  begin
    var Item := TButton.Create(VertScrollBoxActions);
    Item.Parent := VertScrollBoxActions;
    Item.Align := TAlignLayout.Top;
    Item.Height := 36;
    Item.Margins.Bottom := 5;
    Item.Text := Text;
    Item.TagString := Id;
    Item.Enabled := Enabled;
    Item.OnClick := Click;
  end;

begin
  var Content := VertScrollBoxActions.Content;
  while Content.ChildrenCount <> 0 do
    RetireControl(Content.Children[Content.ChildrenCount - 1] as TControl);
  var Actions: IEmulationGameActions;
  if Supports(FCore, IEmulationGameActions, Actions) then
    for var Action in Actions.GetGameActions do
      Add(Translate(Action.Caption), Action.Id, Action.Enabled, GameActionClick);
  var Discs: IEmulationDiscControl;
  if Supports(FCore, IEmulationDiscControl, Discs) and (Discs.GetDiscCount > 0) then
  begin
    for var Index := 0 to Discs.GetDiscCount - 1 do
      Add(Discs.GetDiscName(Index), IntToStr(Index), Index <> Discs.GetDiscIndex, MoveDiscClick);
    if Discs.GetDiscIndex >= 0 then
      Add('Извлечь диск', '-1', True, MoveDiscClick);
    Add('Открыть диск…', 'open', True, MoveDiscClick);
  end;
end;

procedure TFormMain.GameActionClick(Sender: TObject);
begin
  var Actions: IEmulationGameActions;
  if not Supports(FCore, IEmulationGameActions, Actions) then
    Exit;
  var Id := TButton(Sender).TagString;
  for var Action in Actions.GetGameActions do
    if SameText(Action.Id, Id) and Action.Enabled then
    begin
      try
        Actions.ExecuteGameAction(Id);
        SetMenu(TOneEmuMenu.Closed);
      except
        on E: Exception do
          ShowRetroMessage(Self, E.Message);
      end;
      Break;
    end;
end;

procedure TFormMain.MoveDiscClick(Sender: TObject);
begin
  var Discs: IEmulationDiscControl;
  if Supports(FCore, IEmulationDiscControl, Discs) then
  try
    var Command := TButton(Sender).TagString;
    if Command = 'open' then
    begin
      var Documents: IPlatformDocuments;
      if not Supports(FHost, IPlatformDocuments, Documents) then
        Exit;
      var Request := Default(TPlatformDocumentRequest);
      Request.Title := 'Открыть диск';
      Request.Filter := TPlatformRegistry.FileFilter;
      Request.SaveFolder := 'discs';
      Documents.OpenDocument(Request,
        procedure(const FileName: string)
        begin
          Discs.OpenDisc(FileName);
          SetMenu(TOneEmuMenu.Closed);
        end);
      Exit;
    end;
    var Index := StrToInt(Command);
    if Index < 0 then
      Discs.EjectDisc
    else
      Discs.ChangeDisc(Index);
    SetMenu(TOneEmuMenu.Closed);
  except
    on E: Exception do
      ShowRetroMessage(Self, E.Message);
  end;
end;

function TFormMain.SlotName: string;
begin
  Result := Format('slot%.2d', [Max(0, ComboBoxSlot.ItemIndex) + 1]);
end;

function TFormMain.StatePath(const Name: string): string;
begin
  var Location: IEmulationSnapshotLocation;
  Result := '';
  if Supports(FCore, IEmulationSnapshotLocation, Location) then
  begin
    var Directory := Location.GetSnapshotDirectory;
    if Directory <> '' then
      Result := ResolveSnapshotPath(Directory, Name);
  end;
end;

procedure TFormMain.UpdateSlot;
begin
  FSlotOccupied := False;
  ImageState.Bitmap.SetSize(0, 0);
  LabelState.Text := 'Слот пуст';
  LabelStateTime.Text := 'Нет сохранения';
  var Path := StatePath(SlotName);
  if (Path = '') or not FStorage.Exists(Path) then
    Exit;
  FSlotOccupied := True;
  LabelState.Text := 'Сохранено';
  LabelStateTime.Text := DateTimeToStr(FStorage.ModifiedTime(Path));
  var Preview := ChangeFileExt(Path, '.png');
  if FStorage.Exists(Preview) then
  try
    var ImageStream := FStorage.OpenRead(Preview);
    try
      ImageState.Bitmap.LoadFromStream(ImageStream);
    finally
      ImageStream.Free;
    end;
  except
    on E: Exception do
      ImageState.Bitmap.SetSize(0, 0);
  end;
end;

procedure TFormMain.SlotChange(Sender: TObject);
begin
  if FReady then
  begin
    UpdateSlot;
    RefreshChrome;
  end;
end;

procedure TFormMain.DoSnapshot(Loading: Boolean);
begin
  if (FCore = nil) or not FCore.SupportsSnapshots or Busy or (FSettings <> nil) then
    Exit;
  var Name := SlotName;
  var Path := StatePath(Name);
  if Loading and (Path <> '') and not FStorage.Exists(Path) then
    Exit;
  try
    if Supports(FCore, IEmulationSnapshotOperation, FSnapshot) then
    begin
      FSnapshotName := Name;
      FSnapshotLoading := Loading;
      FSnapshot.BeginSnapshot(Name, Loading);
      SetStatus('Обработка состояния…');
      SyncActivity;
    end
    else
    begin
      if Loading then
        FCore.LoadSnapshot(Name)
      else
        FCore.SaveSnapshot(Name);
      SnapshotDone(Name, Loading);
    end;
  except
    on E: Exception do
    begin
      FSnapshot := nil;
      SyncActivity;
      ShowRetroMessage(Self, E.Message);
    end;
  end;
end;

procedure TFormMain.PollSnapshot;
begin
  if FSnapshot = nil then
    Exit;
  var Done, Total: UInt64;
  var ErrorText: string;
  if FSnapshot.SnapshotStatus(Done, Total, ErrorText) then
    Exit;
  FSnapshot := nil;
  if ErrorText <> '' then
  begin
    SetStatus('Ошибка состояния');
    ShowRetroMessage(Self, ErrorText);
    SyncActivity;
  end
  else
    SnapshotDone(FSnapshotName, FSnapshotLoading);
end;

procedure TFormMain.SnapshotDone(const Name: string; Loading: Boolean);
begin
  if Loading then
  begin
    FFailed := False;
    FCompleted := False;
    FPaused := False;
    FViewport.ResetHistory;
    SetMenu(TOneEmuMenu.Closed);
    SetStatus('Состояние загружено');
  end
  else
  begin
    var Path := StatePath(Name);
    if (Path <> '') and FStorage.Exists(Path) and not FViewport.Bitmap.IsEmpty then
    try
      var Preview := TMemoryStream.Create;
      try
        FViewport.Bitmap.SaveToStream(Preview);
        Preview.Position := 0;
        FStorage.WriteAtomic(ChangeFileExt(Path, '.png'), Preview);
      finally
        Preview.Free;
      end;
    except
      // State validity does not depend on the optional preview.
    end;
    UpdateSlot;
    SetStatus('Состояние сохранено');
  end;
  SyncActivity;
end;

procedure TFormMain.SaveStateClick(Sender: TObject);
begin
  DoSnapshot(False);
end;

procedure TFormMain.LoadStateClick(Sender: TObject);
begin
  DoSnapshot(True);
end;

procedure TFormMain.SettingsClick(Sender: TObject);
begin
  if Busy or (FSettings <> nil) then
    Exit;
  var Page := PlatformPresentation(SystemId).SettingsPageId;
  if SettingsPlatforms.Find(Page) = nil then
  begin
    ShowRetroMessage(Self, 'Для этой системы не зарегистрирована страница настроек.', TRetroDialogKind.Information);
    Exit;
  end;
  FullScreen := False;
  FMenu := TOneEmuMenu.Main;
  SyncActivity;
  try
    FSettings := TSettingsView.CreateSettings(Self, FStorage, FInput, '', '', '', Page);
    FSettings.Name := 'SettingsViewPlatform';
    FSettings.LabelBrand.Text := 'OneEmu';
    FSettings.Parent := LayoutSettings;
    FSettings.Align := TAlignLayout.Client;
    FSettings.OnApply := SettingsApplied;
    FSettings.OnClose := SettingsClosed;
    DetachSettingsPeripherals(FRuntime);
    SyncActivity;
  except
    on E: Exception do
    begin
      CloseSettings;
      ShowRetroMessage(Self, E.Message);
    end;
  end;
end;

procedure TFormMain.SettingsApplied(Sender: TObject);
begin
  if FCore <> nil then
  begin
    var Ini := FStorage.ReadConfig(FCore.Config.FileName);
    try
      PlatformSettingsHandler(SystemId).Apply(FRuntime, Ini);
      FViewport.LoadSettings(Ini);
      FViewport.DisableInterpolation := SameText(FCore.Config.Filter, 'nearest');
      FViewport.Repaint;
    finally
      Ini.Free;
    end;
  end;
  ReloadInput;
end;

procedure TFormMain.SettingsClosed(Sender: TObject);
begin
  if (FSettings = nil) or FSettingsClosing then
    Exit;
  FSettingsClosing := True;
  FSettings.Visible := False;
  var IsAlive: TFunc<Boolean> := FAlive;
  TThread.ForceQueue(nil,
    procedure
    begin
      if IsAlive() then
        CloseSettings;
    end);
end;

procedure TFormMain.CloseSettings;
begin
  if FSettings = nil then
    Exit;
  var Settings := FSettings;
  FSettings := nil;
  FSettingsClosing := False;
  Settings.OnApply := nil;
  Settings.OnClose := nil;
  Settings.CancelCapture;
  if FReady then
    RetireControl(Settings)
  else
    Settings.Free;
  SyncActivity;
end;

procedure TFormMain.KeyDown(var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
begin
  if not FReady then
  begin
    inherited;
    Exit;
  end;
  if HandleRetroDialogKey(Self, Key, KeyChar) then
    Exit;
  if FSettings <> nil then
  begin
    if FSettings.HandleCaptureKeyDown(Key, KeyChar) then
      Exit;
    if Key = vkEscape then
    begin
      SettingsClosed(Self);
      Key := 0;
      KeyChar := #0;
    end
    else
      inherited;
    Exit;
  end;
  if FKeysDown.ContainsKey(Key) and (Key <> 0) then
    Exit;
  if Key <> 0 then
    FKeysDown.AddOrSetValue(Key, True);
  var Policy := PlatformInputHandler(SystemId).KeyPolicy(FRuntime);
  if Key = vkEscape then
    MenuClick(Self)
  else if Key = vkF11 then
    FullscreenClick(Self)
  else if (ssCtrl in Shift) and ((Key = vkO) or (UpCase(KeyChar) = 'O')) then
    OpenRomClick(Self)
  else if (ssCtrl in Shift) and ((Key = vkR) or (UpCase(KeyChar) = 'R')) then
    DoReset
  else if (Key = vkF5) and (not Policy.KeyboardActive or Policy.AllowSnapshotsWithKeyboard) then
    SaveStateClick(Self)
  else if (Key = vkF8) and (not Policy.KeyboardActive or Policy.AllowSnapshotsWithKeyboard) then
    LoadStateClick(Self)
  else
  begin
    if CanPlay then
      ForwardKey(Key, True);
    inherited;
    Exit;
  end;
  Key := 0;
  KeyChar := #0;
end;

procedure TFormMain.KeyUp(var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
begin
  if FReady then
  begin
    FKeysDown.Remove(Key);
    if CanPlay then
      ForwardKey(Key, False);
  end;
  inherited;
end;

procedure TFormMain.ViewportDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Single);
begin
  if (Button = TMouseButton.mbLeft) and CanPlay and
    not DispatchScreenTouch(FRuntime, TEmulationTouchPhase.Down, X, Y) then
    PlatformInputHandler(SystemId).PointerButton(FRuntime, X, Y, True);
end;

procedure TFormMain.ViewportMove(Sender: TObject; Shift: TShiftState; X, Y: Single);
begin
  if CanPlay then
    DispatchScreenTouch(FRuntime, TEmulationTouchPhase.Move, X, Y);
end;

procedure TFormMain.ViewportUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Single);
begin
  if (Button = TMouseButton.mbLeft) and CanPlay and
    not DispatchScreenTouch(FRuntime, TEmulationTouchPhase.Up, X, Y) then
    PlatformInputHandler(SystemId).PointerButton(FRuntime, X, Y, False);
end;

procedure TFormMain.ActivityChanged(Sender: TObject);
begin
  SyncActivity;
end;

procedure TFormMain.FormActivate(Sender: TObject);
begin
  FInactive := False;
  SyncActivity;
end;

procedure TFormMain.FormDeactivate(Sender: TObject);
begin
  FInactive := True;
  if FKeysDown <> nil then
    FKeysDown.Clear;
  SyncActivity;
end;

procedure TFormMain.StageResize(Sender: TObject);
begin
  if FReady and (FCore <> nil) then
  begin
    ResizePlatformControls(FRuntime);
    PlatformSessionHandler(SystemId).LayoutControls(FRuntime);
  end;
end;

constructor TOneEmuHost.Create(Form: TFormMain);
begin
  inherited Create;
  FForm := Form;
end;

function TOneEmuHost.GetCore: IEmulationCore;
begin
  Result := FForm.FCore;
end;

function TOneEmuHost.GetSystemId: string;
begin
  Result := FForm.SystemId;
end;

function TOneEmuHost.GetStorage: IStorage;
begin
  Result := FForm.FStorage;
end;

function TOneEmuHost.GetActivity: TPlatformActivity;
begin
  Result := Default(TPlatformActivity);
  Result.SettingsOpen := FForm.FSettings <> nil;
  Result.GameplayVisible := (GetCore <> nil) and not Result.SettingsOpen;
  Result.AcceptsGameInput := FForm.CanPlay;
  Result.PeripheralInputBlocked := not Result.AcceptsGameInput;
  Result.CanShowGameNotice := Result.GameplayVisible and not FForm.Busy and
    (FForm.FMenu = TOneEmuMenu.Closed) and not RetroDialogVisible(FForm);
  {$IF Defined(ANDROID) or Defined(IOS)}
  Result.ShowVirtualGamepad := True;
  {$ENDIF}
  Result.VirtualControlsEnabled := Result.AcceptsGameInput;
  if FForm.Busy then
    Result.Phase := TPlatformSessionPhase.Loading
  else if FForm.FFailed then
    Result.Phase := TPlatformSessionPhase.Failed
  else if GetCore = nil then
    Result.Phase := TPlatformSessionPhase.Empty
  else if Result.AcceptsGameInput then
    Result.Phase := TPlatformSessionPhase.Running
  else
    Result.Phase := TPlatformSessionPhase.Paused;
end;

function TOneEmuHost.GetInput: IPlatformInput;
begin
  Result := Self;
end;

function TOneEmuHost.GetVideo: IPlatformVideo;
begin
  Result := Self;
end;

function TOneEmuHost.GetData(const Key: string): IInterface;
begin
  FForm.FData.TryGetValue(Key, Result);
end;

procedure TOneEmuHost.SetData(const Key: string; const Value: IInterface);
begin
  if Value = nil then
    FForm.FData.Remove(Key)
  else
    FForm.FData.AddOrSetValue(Key, Value);
end;

procedure TOneEmuHost.ResetGame;
begin
  FForm.DoReset;
end;

procedure TOneEmuHost.SetStatus(const Text: string);
begin
  FForm.SetStatus(Text);
end;

procedure TOneEmuHost.ShowMessage(const Text: string; IsError: Boolean);
begin
  if IsError then
    ShowRetroMessage(FForm, Text)
  else
    ShowRetroMessage(FForm, Text, TRetroDialogKind.Information);
end;

function TOneEmuHost.GetPorts: TCoreInputPorts;
begin
  Result := FForm.FPorts;
end;

procedure TOneEmuHost.SetPorts(const Ports: TCoreInputPorts);
begin
  FForm.FPorts := Ports;
end;

function TOneEmuHost.GetHasInputSource: Boolean;
begin
  Result := (FForm.FInput <> nil) and not FForm.FInputFailed;
end;

function TOneEmuHost.GetBindings: TArray<TInputBinding>;
begin
  Result := nil;
  if GetHasInputSource then
    Result := FForm.FInput.Bindings;
end;

function TOneEmuHost.IsActionPressed(Action: Integer): Boolean;
begin
  Result := GetHasInputSource and FForm.FInput.IsPressed(Action);
end;

function TOneEmuHost.ActionAmount(Action: Integer): Single;
begin
  Result := 0;
  if GetHasInputSource then
    Result := RM.Input.ActionAmount(FForm.FInput, FForm.FInput.Bindings, FForm.FInput.Values, Action);
end;

function TOneEmuHost.DigitalAnalogAmount(Action: Integer; Pressed: Boolean): Single;
begin
  Result := Ord(Pressed);
  if GetHasInputSource then
    Result := TGamepadInputManager(FForm.FInput).DigitalAnalogAmount(Action, Pressed);
end;

procedure TOneEmuHost.ClearCachedInput;
begin
  FForm.ClearInput;
end;

procedure TOneEmuHost.RequestInputUpdate(SubmitToCore: Boolean);
begin
  if SubmitToCore then
    FForm.SubmitInput
  else if FForm.CanPlay then
    PlatformInputHandler(GetSystemId).UpdateInput(FForm.FRuntime);
end;

function TOneEmuHost.TryLocalToFrame(const Point: TPointF; out Pixel: TPoint): Boolean;
begin
  Result := TryGetImagePixel(FForm.FViewport, Point.X, Point.Y, Pixel.X, Pixel.Y);
end;

function TOneEmuHost.TryScreenToFrame(const Point: TPointF; out Pixel: TPoint): Boolean;
begin
  Result := TryLocalToFrame(FForm.FViewport.AbsoluteToLocal(FForm.ScreenToClient(Point)), Pixel);
end;

function TOneEmuHost.TryPointerToFrame(out Pixel: TPoint): Boolean;
begin
  var Mouse: IFMXMouseService;
  if TPlatformServices.Current.SupportsPlatformService(IFMXMouseService, Mouse) then
    Exit(TryScreenToFrame(Mouse.GetMousePos, Pixel));
  Pixel := Point(-1, -1);
  Result := False;
end;

function TOneEmuHost.GetPointerCaptured: Boolean;
begin
  var View := FForm.FViewport;
  Result := (View.Root <> nil) and (View.Root.Captured <> nil) and (View.Root.Captured.GetObject = View);
end;

procedure TOneEmuHost.SetPointerCaptured(Value: Boolean);
begin
  var View := FForm.FViewport;
  if View.Root <> nil then
    if Value then
      View.Root.SetCaptured(View)
    else if GetPointerCaptured then
      View.Root.SetCaptured(nil);
end;

procedure TOneEmuHost.SetPointerInputEnabled(Enabled, ShowFocus: Boolean);
begin
  FForm.FViewport.HitTest := Enabled;
  FForm.FViewport.CanFocus := Enabled;
  FForm.FViewport.DisableFocusEffect := not ShowFocus;
end;

procedure TOneEmuHost.FitFrame;
begin
  FForm.FViewport.WrapMode := TImageWrapMode.Fit;
end;

function TOneEmuHost.GetInputForm: TCommonCustomForm;
begin
  Result := FForm;
end;

function TOneEmuHost.GetContent: TControl;
begin
  Result := FForm.LayoutStage;
end;

function TOneEmuHost.GetFrameLayer: TImage;
begin
  Result := FForm.FViewport;
end;

function TOneEmuHost.GetGamepad: TScreenGamepad;
begin
  Result := FForm.FGamepad;
end;

function TOneEmuHost.GetUsableSize: TSizeF;
begin
  Result := FForm.LayoutStage.Size.Size;
end;

function TOneEmuHost.GetBottomInset: Single;
begin
  Result := 0;
end;

procedure TOneEmuHost.OpenDocument(const Request: TPlatformDocumentRequest; const Selected: TPlatformDocumentAction);
begin
  if FForm.Busy or not Assigned(Selected) then
    Exit;
  var Origin := GetCore;
  var IsAlive: TFunc<Boolean> := FForm.FAlive;
  var Options := Request;
  var OnSelected := Selected;
  var Dialog := TFMXOpenDialog.Create(nil);
  FForm.FPicking := True;
  FForm.SyncActivity;
  try
    Dialog.Title := Options.Title;
    Dialog.Filter := Options.Filter;
    Dialog.FileMustExist := True;
    Dialog.SelectFiles(
      procedure(const Selection: TFMXSelectionResult)
      begin
        if not IsAlive() then
          Exit;
        try
          try
            if Origin <> GetCore then
              Exit;
            if Selection.Error <> '' then
              raise EReadError.Create(Selection.Error);
            if Selection.Status = TFMXSelectionStatus.Selected then
            begin
              var Location := Selection.Locations[0];
              var Storage := GetStorage;
              var Name := Storage.Describe(Location).Name;
              if (Length(Options.AllowedExtensions) <> 0) and
                not MatchText(ExtractFileExt(Name), Options.AllowedExtensions) then
                raise EReadError.Create('Неподдерживаемый формат файла.');
              if Location.StartsWith('content://') then
              begin
                var Directory := TPath.Combine(Storage.SaveRoot, Options.SaveFolder);
                var Path := Storage.GamePath(Directory, Name, TGUID.NewGuid.ToString, ExtractFileExt(Name));
                var InputStream := Storage.OpenRead(Location);
                try
                  Storage.WriteAtomic(Path, InputStream);
                finally
                  InputStream.Free;
                end;
                Location := Path;
              end;
              OnSelected(Location);
            end;
          except
            on E: Exception do
              ShowMessage(E.Message, True);
          end;
        finally
          FForm.FPicking := False;
          FForm.SyncActivity;
        end;
      end);
  except
    FForm.FPicking := False;
    FForm.SyncActivity;
    Dialog.Free;
    raise;
  end;
  Dialog.Free;
end;

procedure TOneEmuHost.SaveDocument(const Request: TPlatformDocumentRequest; const Write: TPlatformDocumentAction);
begin
  if FForm.Busy or not Assigned(Write) then
    Exit;
  var Origin := GetCore;
  var Dialog := TSaveDialog.Create(FForm);
  FForm.FPicking := True;
  FForm.SyncActivity;
  try
    Dialog.Title := Request.Title;
    Dialog.Filter := Request.Filter;
    Dialog.FileName := Request.SuggestedName;
    Dialog.DefaultExt := Request.Extension.TrimLeft(['.']);
    Dialog.Options := [TOpenOption.ofPathMustExist, TOpenOption.ofOverwritePrompt];
    if Dialog.Execute and (GetCore = Origin) then
      Write(Dialog.FileName);
  finally
    Dialog.Free;
    FForm.FPicking := False;
    FForm.SyncActivity;
  end;
end;

end.

