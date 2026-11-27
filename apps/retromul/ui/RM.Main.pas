unit RM.Main;

{$I ..\RM.Mobile.inc}

interface

uses
  System.SysUtils, System.Classes, System.Types, System.UITypes, FMX.Types,
  FMX.Platform, FMX.Dialogs, Core.Emulation, Core.Storage, FMXInput, WinUI3.Form,
  RM.Main.State, RM.ShaderBitmap, FMX.Menus, FMX.Objects, FMX.StdCtrls,
  FMX.Controls.Presentation, FMX.Layouts, FMX.Controls, FMX.TabControl, FMX.Edit,
  FMX.ListBox, RA.Account
  {$IF not Defined(LINUX)}
    , System.Sensors
  {$ENDIF}
;

type
  TFormMain = class(TWinUIForm)
  protected
    FState: TMainState;
  published
    GameActionsButton, ButtonHidePanel, ButtonShowPanel: TButton;
    LayoutShowPanel: TLayout;
    GameActionsMenu, ScreenshotMenu, SaveSnapshotMenu, LoadSnapshotMenu: TPopupMenu;
    GameActionsPopup: TPopup;
    GameActionsItems: TLayout;
    GameActionsScroll: TVertScrollBox;
    GameActionsBack: TButton;
    ScreenTabs: TTabControl;
    LibraryScreen: TTabItem;
    GameScreen: TTabItem;
    SettingsScreen: TTabItem;
    HelpScreen: TTabItem;
    VertScrollBoxHelp: TVertScrollBox;
    LayoutHelpPage, LayoutHelpContent, LayoutHelpBrand, LayoutHelpActions: TLayout;
    PanelHelpSidebar, PanelHelpPlatforms: TPanel;
    LayoutHelpPlatformSearchSlot, LayoutHelpPlatformPickerRow: TLayout;
    ListBoxHelpPlatforms: TListBox;
    ComboBoxHelpPlatforms: TComboBox;
    LabelHelpTitle, LabelHelpNoPlatforms: TLabel;
    ButtonHelpBack, ButtonHelpWebsite, ButtonHelpFeedback: TButton;
    ButtonLibrary: TButton;
    GamePause: TButton;
    ButtonReset: TButton;
    GamePauseIcon: TPath;
    GameResumeIcon: TPath;
    GameFullscreen: TButton;
    GameSettings: TButton;
    GameInsertCoin: TButton;
    GameControlsHelp: TButton;
    GameStatus: TPanel;
    StatusDot: TCircle;
    GamePlatform: TLabel;
    GameFPS: TLabel;
    GameAudio: TLabel;
    LayoutVideoOutput: TLayout;
    TimerUpdate, TimerAchievementNotice: TTimer;
    ImageLogo: TImage;
    RectangleBG: TRectangle;
    LayoutClient: TLayout;
    LabelPaused: TLabel;
    LayoutAchievementOverlay, LayoutAchievementNoticeCorner: TLayout;
    LayoutAchievementNoticeIcon, LayoutAchievementNoticeText: TLayout;
    RectangleAchievementNotice, RectangleAchievementNoticeIcon: TRectangle;
    PathAchievementNoticeIcon: TPath;
    LabelAchievementNoticeCaption, LabelAchievementNotice: TLabel;
    ImageNoBox: TImage;
    LayoutHead: TLayout;
    LabelStatus: TLabel;
    ButtonCloseRom: TButton;
    procedure LayoutAchievementNoticeCornerResize(Sender: TObject);
    procedure TimerAchievementNoticeTimer(Sender: TObject);
    procedure RefreshAchievements(Sender: TObject);
    procedure FormActivate(Sender: TObject); virtual;
    procedure FormResize(Sender: TObject); virtual;
    procedure FormDeactivate(Sender: TObject); virtual;
    procedure FormKeyUp(Sender: TObject; var Key: Word; var KeyChar: WideChar; Shift: TShiftState); virtual;
    procedure FormKeyDown(Sender: TObject; var Key: Word; var KeyChar: WideChar; Shift: TShiftState); virtual;
    procedure TimerUpdateTimer(Sender: TObject); virtual;
    procedure ResizeHelpPage(Sender: TObject);
    procedure ResizeHelpContent(Sender: TObject);
    procedure HelpPlatformListChange(Sender: TObject);
    procedure HelpPlatformPickerChange(Sender: TObject);
    procedure HelpPlatformPickerMouseWheel(Sender: TObject; Shift: TShiftState; WheelDelta: Integer; var Handled: Boolean);
    procedure CloseHelpClick(Sender: TObject);
    procedure OpenHelpWebsiteClick(Sender: TObject);
    procedure ReportBugClick(Sender: TObject); virtual;
    procedure ButtonOpenClick(Sender: TObject); virtual;
    procedure ButtonOpenOpticalDiscClick(Sender: TObject);
    procedure FormSafeAreaChanged(Sender: TObject; const AInsets: TRectF); virtual;
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean); virtual;
    procedure LayoutClientClick(Sender: TObject); virtual;
    procedure LayoutClientDblClick(Sender: TObject); virtual;
    procedure FormSaveState(Sender: TObject); virtual;
    procedure ButtonCloseRomClick(Sender: TObject); virtual;
    procedure ImageCanvasMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Single); virtual;
    procedure ImageCanvasMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Single);
    procedure ImageCanvasMouseUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Single); virtual;
  private
    // The concrete controller types are private to the implementation.
    FControllers: TObject;
    FHelpReturnTab: TTabItem;
    FResizingHelp, FUpdatingHelpPlatforms: Boolean;
    FHelpPlatformId: string;
    FHelpPlatformSearch: TEdit;
    {$IFNDEF ISMOBILE}
    FHelpResumeCore: IEmulationCore;
    {$ENDIF}
    procedure RefreshHelpPlatforms;
    procedure HelpPlatformSearchChange(Sender: TObject);
    procedure SelectHelpPlatform(const PageId: string);
    procedure ShowHelpArticle;
  public
    ImageCanvas: TShaderBitmap;
    function DetectSystemLanguage: string; virtual;
    function AutosaveClock: UInt64; virtual;
    function HostInputHasFocus: Boolean; virtual;
    procedure ReportAudioError(const MessageText: string); virtual;
    function ExecuteSnapshotDialog(Dialog: TOpenDialog): Boolean; virtual;
    procedure OpenDirectory(const Directory: string); virtual;
    property State: TMainState read FState;
    function HelpPageActive: Boolean;
    procedure OpenHelpClick(Sender: TObject);
    procedure ApplyHelpLanguage(const PreviousLanguage: string);
    procedure ApplyFeedbackLanguage(const PreviousLanguage: string); virtual;
    procedure PollRumble; virtual;
    procedure SyncMotionSensor; virtual;
    procedure PollMotionSensor; virtual;
    {$IF not Defined(LINUX)}
    procedure ChooseMotionSensor(Sender: TObject; const Sensors: TSensorArray; var ChoseSensorIndex: Integer); virtual;
    {$ENDIF}
    procedure InitializeLibrary; virtual;
    procedure Load; virtual;
    procedure Save; virtual;
    {$IFDEF MSWINDOWS}
    procedure RestoreWindowState; virtual;
    procedure SaveWindowState; virtual;
    {$ENDIF}
    procedure ApplyControlInset; virtual;
    procedure SetStatus(const Text: string); virtual;
    procedure SyncActivity; virtual;
    procedure DialogActivityChanged(Sender: TObject); virtual;
    procedure ApplicationException(Sender: TObject; E: Exception); virtual;
    procedure OpenRom; virtual;
    procedure FinishFileSelection; virtual;
    procedure Stop; virtual;
    procedure StopOnError; virtual;
    function UpdateFrame: Boolean; virtual;
    procedure AutosaveOnExit; virtual;
    procedure PollAutosave; virtual;
    procedure LibraryPlay(Sender: TObject); virtual;
    procedure LibraryBack(Sender: TObject); virtual;
    procedure PauseClick(Sender: TObject); virtual;
    procedure SwitchPause; virtual;
    procedure UpdatePauseOverlay; virtual;
    procedure FullscreenClick(Sender: TObject); virtual;
    procedure SwitchFullScreen; virtual;
    procedure UpdateGameChrome; virtual;
    procedure InsertCoinClick(Sender: TObject); virtual;
    procedure SettingsClick(Sender: TObject); virtual;
    procedure SettingsApplied(Sender: TObject); virtual;
    procedure SettingsClose(Sender: TObject); virtual;
    procedure ControlsHelpClick(Sender: TObject); virtual;
    procedure ControlsHelpClose(Sender: TObject); virtual;
    procedure ControlsHelpSettings(Sender: TObject); virtual;
    procedure CloseControlsHelp(OpenSettings: Boolean = False); virtual;
    function GameSnapshotDirectory: string; virtual;
    procedure LoadSnapshotPreview(const Name: string); virtual;
    procedure SaveStateClick(Sender: TObject); virtual;
    procedure LoadStateClick(Sender: TObject); virtual;
    procedure PrepareGameplayMenu(Sender: TObject); virtual;
    procedure SaveSnapshotAsClick(Sender: TObject); virtual;
    procedure OpenSnapshotClick(Sender: TObject); virtual;
    procedure RecentSnapshotClick(Sender: TObject); virtual;
    procedure ScreenshotClick(Sender: TObject); virtual;
    procedure OpenScreenshotFolderClick(Sender: TObject); virtual;
    procedure LoadHostInput(const SystemId: string); virtual;
    procedure ReloadHostInputBindings; virtual;
    procedure PollHostInput; virtual;
    procedure ForwardKeyState(Code: Word; Pressed: Boolean); virtual;
    procedure GamepadChanged(Sender: TObject); virtual;
    function CombinedGamepadInput: TEmulatorInput; virtual;
    procedure UpdatePeripheralInput; virtual;
    procedure UpdatePeripheralFeedback; virtual;
    {$IFDEF ISMOBILE}
    function ApplicationStateChanged(Sender: TObject; const AAppEvent: TApplicationEvent; const AContext: TObject): Boolean; virtual;
    {$ENDIF}
    {$IFDEF ANDROID}
    procedure PollDocumentTransfer; virtual;
    {$ENDIF}
  protected
    function CreateStorage: IStorage; virtual;
    function OpenWebsite: Boolean; virtual;
    function CreateHostInput: TInputManager; virtual;
    function CreateCore(const FileName: string): IEmulationCore; virtual;
    procedure DoOnSettingChange; override;
    procedure DoShow; override;
  public
    procedure KeyDown(var Key: Word; var KeyChar: WideChar; Shift: TShiftState); override;
    procedure DragOver(const Data: TDragObject; const Point: TPointF; var Operation: TDragOperation); override;
    procedure DragDrop(const Data: TDragObject; const Point: TPointF); override;
    procedure SaveSnapshot(const Name: string); virtual;
    procedure LoadSnapshot(const Name: string); virtual;
    procedure LoadRom(const FileName: string; const DisplayName: string = ''; StartPaused: Boolean = False; const SnapshotName: string = ''; const LibraryPlatformId: string = ''); virtual;
    procedure ResetConsole(Hard: Boolean); virtual;
    procedure ResetClick(Sender: TObject); virtual;
    procedure HardRestart; virtual;
    procedure SelectTapeFile(const FileName: string); virtual;
    procedure SetAchievementNoticeCorner(Corner: TRAAchievementCorner);
    procedure PresentAchievementNotice(const Caption, Text: string; Duration: Integer = RANotificationDefaultDuration);
    procedure HideAchievementNotice;
    function SaveScreenshot: string; virtual;
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  end;

const
  AppName = 'RetroMul';

var
  FormMain: TFormMain;

implementation

uses
  System.IOUtils, System.Math, System.Messaging, FMX.Forms, FMX.Graphics,
  FMX.TextLayout, FMX.OpenDialog, FMX.BehaviorManager, Core.EmulatorFactory,
  RM.Storage.Dialogs, RM.Feedback, RM.Controllers.Browser, RM.Controllers.Window,
  RM.Controllers.Settings, RM.Controllers.Snapshots, RM.Controllers.Input,
  RM.Controllers.Mobile, RM.Controllers.Session, RM.Dialogs, RM.Styles,
  RM.Rumble, FMX.Image, RM.Input.Gamepads, RM.Help.Content, RM.Settings.Catalog,
  RM.Settings.Platform, RM.SearchEdit, RM.Icons, RM.Controls.Lifetime
  {$IF not Defined(LINUX)}
    , System.Sensors.Components
  {$ENDIF}
  {$IFDEF MSWINDOWS}
    , Winapi.Windows, FMX.Platform.Win, Winapi.ShellAPI
  {$ENDIF}
  {$IF Defined(MACOS) and not Defined(IOS)}
    , Macapi.AppKit, Macapi.Helpers
  {$ENDIF}
  {$IFDEF IOS}
    , iOSapi.Helpers, Macapi.Helpers
  {$ENDIF}
  {$IFDEF ANDROID}
    , Androidapi.Helpers, Androidapi.JNI.App,
    Androidapi.JNI.GraphicsContentViewText, Androidapi.JNI.JavaTypes,
    Androidapi.JNI.Net
  {$ENDIF}
  {$IF Defined(LINUX) and not Defined(ANDROID)}
    , Posix.Stdlib
  {$ENDIF};

{$R *.fmx}

type
  TMainControllers = class
  public
    Browser: TBrowserController;
    Window: TWindowController;
    Settings: TSettingsController;
    Snapshots: TSnapshotsController;
    Input: TInputController;
    Mobile: TMobileController;
    Session: TSessionController;
    Feedback: TFeedbackView; // Owned by the form.
    constructor Create(Form: TFormMain);
    destructor Destroy; override;
  end;

constructor TMainControllers.Create(Form: TFormMain);
begin
  inherited Create;
  Browser := TBrowserController.Create(Form);
  Window := TWindowController.Create(Form);
  Settings := TSettingsController.Create(Form);
  Snapshots := TSnapshotsController.Create(Form);
  Input := TInputController.Create(Form);
  Mobile := TMobileController.Create(Form);
  Session := TSessionController.Create(Form);
end;

destructor TMainControllers.Destroy;
begin
  Session.Free;
  Mobile.Free;
  Input.Free;
  Snapshots.Free;
  Settings.Free;
  Window.Free;
  Browser.Free;
  inherited;
end;

constructor TFormMain.Create(AOwner: TComponent);
begin
  FState := TMainState.Create;
  FState.AchievementAccount := CreateRAAccount;
  FControllers := TMainControllers.Create(Self);
  FormStyles := TFormStyles.Create(Application);
  inherited;
  ButtonHelpBack.StylesData['text.Margins.Left'] := 44;
  ComboBoxHelpPlatforms.ListBox.ScrollAnimation := TBehaviorBoolean.True;
  ComboBoxHelpPlatforms.ListBox.OnMouseWheel := HelpPlatformPickerMouseWheel;
  OnTouch := TMainControllers(FControllers).Input.FormTouch;
  ImageCanvas := TShaderBitmap.Create(Self);
  ImageCanvas.Name := 'ImageCanvas';
  ImageCanvas.Parent := LayoutVideoOutput.Parent;
  ImageCanvas.Index := LayoutVideoOutput.Index;
  ImageCanvas.Align := TAlignLayout.Client;
  ImageCanvas.OnMouseDown := ImageCanvasMouseDown;
  ImageCanvas.OnMouseUp := ImageCanvasMouseUp;
  ImageCanvas.OnMouseMove := ImageCanvasMouseMove;
  ImageCanvas.AutoCapture := True;
  ImageLogo.Parent := ImageCanvas;
  LabelPaused.Parent := ImageCanvas;
  FreeAndNil(LayoutVideoOutput);
  // Screen changes are controlled by application state, not swipe gestures.
  SetRetroDialogActivity(Self, DialogActivityChanged);
  State.Session.PreviousExceptionHandler := Application.OnException;
  Application.OnException := ApplicationException;
  ScreenTabs.AniCalculations.TouchTracking := [];
  OnCloseQuery := FormCloseQuery;
  State.Session.Storage := CreateStorage;
  var Alive := True;
  State.Session.CallbackAlive :=
    function: Boolean
    begin
      Result := Alive;
    end;
  State.Session.InvalidateCallbacks :=
    procedure
    begin
      Alive := False;
    end;
  {$IF Defined(ANDROID) or ((Defined(MSWINDOWS) or Defined(LINUX) or (Defined(MACOS) and not Defined(IOS))) and not Defined(ISMOBILE))}
  State.Input.Manager := CreateHostInput;
  {$ENDIF}
  State.Session.FileDialog := TFMXOpenDialog.Create(Self);
  State.Session.FileDialog.MultipleSelection := False;
  TMainControllers(FControllers).Browser.InitializeScreenshotTool;
  LayoutClient.CanFocus := True;
  LayoutClient.OnKeyDown := FormKeyDown;
  LayoutClient.OnKeyUp := FormKeyUp;
  LayoutClient.DisableFocusEffect := False;
  LayoutClient.CanParentFocus := True;
  SetStatus('Open ROM');
  {$IFDEF ANDROID}
  TMainControllers(FControllers).Mobile.InitializeAndroidServices;
  {$ENDIF}
  {$IFDEF ISMOBILE}
  TMainControllers(FControllers).Mobile.InitializeMobileViews;
  {$ENDIF}
  Fill.Color := TAlphaColors.Black;
  ImageCanvas.WrapMode := TImageWrapMode.Fit;
  ImageCanvas.DisableInterpolation := True;
  ImageCanvas.Bitmap.SetSize(256, 240);
  ImageCanvas.Bitmap.Clear(TAlphaColors.Black);
  TMainControllers(FControllers).Input.InitializePeripherals;
  State.Input.Rumble := TRumblePlayer.Create;
  {$IF not Defined(LINUX)}
  State.Input.MotionSensor := TMotionSensor.Create(Self);
  State.Input.MotionSensor.OnSensorChoosing := ChooseMotionSensor;
  {$ENDIF}
  FormResize(Self);
  TimerUpdate.Interval := 8;
  Load;
  TMainControllers(FControllers).Input.InitializeHostInput;
  InitializeLibrary;
  {$IFNDEF ISMOBILE}
  TMainControllers(FControllers).Browser.InitializeDesktopViews;
  {$ENDIF}
  SyncActivity;
end;

function TFormMain.HelpPageActive: Boolean;
begin
  Result := (ScreenTabs <> nil) and (HelpScreen <> nil) and (ScreenTabs.ActiveTab = HelpScreen);
end;

procedure TFormMain.ResizeHelpPage(Sender: TObject);
begin
  if (csLoading in ComponentState) or (csDestroying in ComponentState) or (LayoutHelpPage = nil) or
    (PanelHelpSidebar = nil) or (LayoutHelpBrand = nil) or (LayoutHelpActions = nil) or
    (PanelHelpPlatforms = nil) or (LayoutHelpPlatformPickerRow = nil) then
    Exit;

  var Compact := LayoutHelpPage.Width < 760;
  PanelHelpPlatforms.Visible := LayoutHelpPage.Width >= 1000;
  LayoutHelpPlatformPickerRow.Visible := not PanelHelpPlatforms.Visible;
  var SidebarAlign := TAlignLayout.MostLeft;
  if Compact then
    SidebarAlign := TAlignLayout.Top;
  LayoutHelpActions.BeginUpdate;
  try
    if PanelHelpSidebar.Align <> SidebarAlign then
    begin
      PanelHelpSidebar.Align := SidebarAlign;
      LayoutHelpBrand.Visible := not Compact;
      if Compact then
      begin
        PanelHelpSidebar.Height := 58;
        PanelHelpSidebar.StyleLookup := 'retromul_panel_top';
      end
      else
      begin
        PanelHelpSidebar.Width := 264;
        PanelHelpSidebar.StyleLookup := 'retromul_panel_left';
      end;
      for var I := 0 to LayoutHelpActions.ControlsCount - 1 do
      begin
        var Button := LayoutHelpActions.Controls[I];
        // FMX uses the position along the alignment axis to order sibling controls.
        if Compact then
        begin
          Button.Align := TAlignLayout.Left;
          Button.Position.X := I * 200;
          Button.Margins.Rect := TRectF.Create(0, 8, 8 * Ord(I < LayoutHelpActions.ControlsCount - 1), 8);
        end
        else
        begin
          Button.Align := TAlignLayout.Top;
          Button.Position.Y := I * 50;
          Button.Height := 42;
          Button.Margins.Rect := TRectF.Create(0, 0, 0, 8);
        end;
      end;
    end;
    if Compact then
    begin
      var ActionsWidth := LayoutHelpPage.Width - LayoutHelpActions.Padding.Left - LayoutHelpActions.Padding.Right;
      var Gaps := 8 * (LayoutHelpActions.ControlsCount - 1);
      var ButtonWidth := Max(1, (ActionsWidth - Gaps) / LayoutHelpActions.ControlsCount);
      for var I := 0 to LayoutHelpActions.ControlsCount - 1 do
        LayoutHelpActions.Controls[I].Width := ButtonWidth;
    end;
  finally
    LayoutHelpActions.EndUpdate;
  end;
end;

procedure TFormMain.ResizeHelpContent(Sender: TObject);
begin
  if FResizingHelp or (csLoading in ComponentState) or (csDestroying in ComponentState) or
    (LayoutHelpContent = nil) then
    Exit;

  FResizingHelp := True;
  try
    var Inset := Max(20, (LayoutHelpContent.Width - 720) / 2);
    LayoutHelpContent.Padding.Left := Inset;
    LayoutHelpContent.Padding.Right := Inset;
    var Height := LayoutHelpContent.Padding.Top + LayoutHelpContent.Padding.Bottom;
    for var I := 0 to LayoutHelpContent.ControlsCount - 1 do
    begin
      var Control := LayoutHelpContent.Controls[I];
      Height := Height + Control.Height + Control.Margins.Top + Control.Margins.Bottom;
    end;
    LayoutHelpContent.Height := Height;
  finally
    FResizingHelp := False;
  end;
end;

procedure TFormMain.OpenHelpClick(Sender: TObject);
begin
  var ReturnTab := ScreenTabs.ActiveTab;
  if ((ReturnTab <> LibraryScreen) and (ReturnTab <> GameScreen)) or
    State.Session.OpeningRom or State.Session.Reporting or (State.Help.View <> nil) then
    Exit;

  {$IFNDEF ISMOBILE}
  var Core := State.Session.Emulation;
  if (ReturnTab = GameScreen) and (Core <> nil) and
    not State.Session.EmulationFaulted and not Core.IsPaused then
  begin
    Core.Pause;
    FHelpResumeCore := Core;
  end;
  {$ENDIF}
  FHelpReturnTab := ReturnTab;
  ScreenTabs.ActiveTab := HelpScreen;
  FormDeactivate(Self);
  if State.Browser.View <> nil then
    State.Browser.View.PollLibraryInput(nil, False);
  {$IFDEF ISMOBILE}
  SyncActivity;
  {$ENDIF}
  if FHelpPlatformSearch = nil then
  begin
    FHelpPlatformSearch := TSearchEdit.Create(Self);
    FHelpPlatformSearch.Name := 'SearchEditHelpPlatforms';
    FHelpPlatformSearch.Parent := LayoutHelpPlatformSearchSlot;
    FHelpPlatformSearch.Align := TAlignLayout.Client;
    FHelpPlatformSearch.OnChangeTracking := HelpPlatformSearchChange;
    RefreshHelpPlatforms;
    ShowHelpArticle;
  end;
  VertScrollBoxHelp.ViewportPosition := TPointF.Zero;
  ResizeHelpPage(Self);
  ResizeHelpContent(Self);
  ButtonHelpBack.SetFocus;
end;

procedure TFormMain.ApplyHelpLanguage(const PreviousLanguage: string);
begin
  FormStyles.RelocalizeUI(HelpScreen, PreviousLanguage);
  if FHelpPlatformSearch <> nil then
  begin
    RefreshHelpPlatforms;
    ShowHelpArticle;
  end;
end;

procedure TFormMain.RefreshHelpPlatforms;

  function AddItem(const PageId, Caption: string): TListBoxItem;
  begin
    Result := TListBoxItem.Create(ListBoxHelpPlatforms);
    Result.TagString := PageId;
    Result.Text := Caption;
    Result.Height := 44;
    Result.TextSettings.HorzAlign := TTextAlign.Leading;
    Result.TextSettings.Trimming := TTextTrimming.Character;
    Result.TextSettings.WordWrap := False;
    Result.Parent := ListBoxHelpPlatforms;
  end;

begin
  FUpdatingHelpPlatforms := True;
  ListBoxHelpPlatforms.BeginUpdate;
  ComboBoxHelpPlatforms.BeginUpdate;
  try
    while ListBoxHelpPlatforms.Count > 0 do
      RetireControl(ListBoxHelpPlatforms.ListItems[0]);
    ComboBoxHelpPlatforms.Items.Clear;
    var Overview := Translate('Overview');
    var Item := AddItem('', Overview);
    if FHelpPlatformId = '' then
      ListBoxHelpPlatforms.ItemIndex := Item.Index;
    ComboBoxHelpPlatforms.Items.Add(Overview);
    ComboBoxHelpPlatforms.ItemIndex := 0;

    var Brand := '';
    var Matches := SettingsPlatforms.Matching(FHelpPlatformSearch.Text);
    for var platform in Matches do
    begin
      if Brand <> platform.Brand then
      begin
        Brand := platform.Brand;
        var Header := TListBoxGroupHeader.Create(ListBoxHelpPlatforms);
        Header.Text := Brand;
        Header.Height := 36;
        Header.HitTest := False;
        Header.Selectable := False;
        Header.Parent := ListBoxHelpPlatforms;
        Header.StyledSettings := Header.StyledSettings - [TStyledSetting.Other];
        Header.TextSettings.WordWrap := False;
        Header.TextSettings.Trimming := TTextTrimming.Character;
      end;
      Item := AddItem(platform.PageId, Translate(platform.Name));
      Item.StylesData['text.Margins.Left'] := 44;
      CreatePlatformIcon(Item, platform.CoreId);
      if platform.PageId = FHelpPlatformId then
        ListBoxHelpPlatforms.ItemIndex := Item.Index;
    end;

    for var platform in SettingsPlatforms.Matching('') do
    begin
      var I := ComboBoxHelpPlatforms.Items.AddObject(platform.Brand + ' · ' + Translate(platform.Name), platform);
      if platform.PageId = FHelpPlatformId then
        ComboBoxHelpPlatforms.ItemIndex := I;
    end;
    LabelHelpNoPlatforms.Visible := Length(Matches) = 0;
    LabelHelpNoPlatforms.Text := Translate('No platforms found');
    FHelpPlatformSearch.TextPrompt := Translate('Search platforms');
  finally
    ComboBoxHelpPlatforms.EndUpdate;
    ListBoxHelpPlatforms.EndUpdate;
    FUpdatingHelpPlatforms := False;
  end;
end;

procedure TFormMain.HelpPlatformSearchChange(Sender: TObject);
begin
  if not FUpdatingHelpPlatforms and not (csDestroying in ComponentState) then
    RefreshHelpPlatforms;
end;

procedure TFormMain.HelpPlatformListChange(Sender: TObject);
begin
  if not FUpdatingHelpPlatforms and not (csDestroying in ComponentState) and
    (ListBoxHelpPlatforms.Selected <> nil) then
    SelectHelpPlatform(ListBoxHelpPlatforms.Selected.TagString);
end;

procedure TFormMain.HelpPlatformPickerMouseWheel(Sender: TObject; Shift: TShiftState; WheelDelta: Integer; var Handled: Boolean);
begin
  // FMX can invalidate the popup list's bounds while applying item styles.
  // Rebuild them before the inherited wheel handler tests whether the list can scroll.
  var List := TComboListBox(Sender);
  if List.ContentBounds.IsEmpty then
    List.RealignContent;
end;

procedure TFormMain.HelpPlatformPickerChange(Sender: TObject);
begin
  if FUpdatingHelpPlatforms or (csDestroying in ComponentState) or (ComboBoxHelpPlatforms.ItemIndex < 0) then
    Exit;
  var platform := TSettingsPlatform(ComboBoxHelpPlatforms.Items.Objects[ComboBoxHelpPlatforms.ItemIndex]);
  if platform = nil then
    SelectHelpPlatform('')
  else
    SelectHelpPlatform(platform.PageId);
end;

procedure TFormMain.SelectHelpPlatform(const PageId: string);
begin
  if (csDestroying in ComponentState) or (FHelpPlatformId = PageId) then
    Exit;
  FHelpPlatformId := PageId;
  FUpdatingHelpPlatforms := True;
  try
    ListBoxHelpPlatforms.ItemIndex := -1;
    for var I := 0 to ListBoxHelpPlatforms.Count - 1 do
    begin
      var Item := ListBoxHelpPlatforms.ListItems[I];
      if Item.Selectable and (Item.TagString = PageId) then
      begin
        ListBoxHelpPlatforms.ItemIndex := I;
        Break;
      end;
    end;
    var platform := SettingsPlatforms.Find(PageId);
    ComboBoxHelpPlatforms.ItemIndex := ComboBoxHelpPlatforms.Items.IndexOfObject(platform);
  finally
    FUpdatingHelpPlatforms := False;
  end;
  ShowHelpArticle;
end;

procedure TFormMain.ShowHelpArticle;

  procedure AddLabel(const Name, Caption: string; Heading: Boolean; Order: Integer);
  begin
    var TextLabel := TLabel.Create(LayoutHelpContent);
    TextLabel.Name := Name;
    TextLabel.Align := TAlignLayout.Top;
    TextLabel.Position.Y := Order * 1000; // Top-alignment order.
    TextLabel.AutoSize := True;
    TextLabel.AutoTranslate := False;
    TextLabel.HitTest := False;
    TextLabel.StyledSettings := [TStyledSetting.Family];
    TextLabel.TextSettings.VertAlign := TTextAlign.Leading;
    TextLabel.TextSettings.WordWrap := True;
    if Heading then
    begin
      TextLabel.TextSettings.Font.Size := 17;
      TextLabel.TextSettings.Font.Style := [TFontStyle.fsBold];
      TextLabel.TextSettings.FontColor := ThemeTextColor;
      TextLabel.Margins.Bottom := 4;
    end
    else
    begin
      TextLabel.TextSettings.Font.Size := 15;
      TextLabel.TextSettings.FontColor := ThemeSecondaryTextColor;
      TextLabel.Margins.Bottom := 20;
    end;
    TextLabel.Text := Caption;
    TextLabel.OnResize := ResizeHelpContent;
    TextLabel.Parent := LayoutHelpContent;
  end;

begin
  var platform := SettingsPlatforms.Find(FHelpPlatformId);
  var Sections: TArray<THelpSection>;
  LayoutHelpContent.BeginUpdate;
  FResizingHelp := True;
  try
    for var I := LayoutHelpContent.ControlsCount - 1 downto 0 do
      if LayoutHelpContent.Controls[I] <> LabelHelpTitle then
        RetireControl(LayoutHelpContent.Controls[I]);
    if platform = nil then
    begin
      LabelHelpTitle.Text := Translate('Help');
      Sections := GeneralHelpSections;
    end
    else
    begin
      LabelHelpTitle.Text := Translate(platform.Name);
      Sections := PlatformHelpSections(platform);
    end;
    for var I := 0 to High(Sections) do
    begin
      AddLabel('LabelHelpSection' + IntToStr(I + 1), Sections[I].Title, True, I * 2 + 1);
      AddLabel('LabelHelpSectionText' + IntToStr(I + 1), Sections[I].Text, False, I * 2 + 2);
    end;
  finally
    LayoutHelpContent.EndUpdate;
    FResizingHelp := False;
  end;
  ResizeHelpContent(Self);
  VertScrollBoxHelp.ViewportPosition := TPointF.Zero;
end;

procedure TFormMain.CloseHelpClick(Sender: TObject);
begin
  if not HelpPageActive or State.Session.Reporting then
    Exit;

  ScreenTabs.ActiveTab := FHelpReturnTab;
  FHelpReturnTab := nil;
  {$IFNDEF ISMOBILE}
  var Core := FHelpResumeCore;
  FHelpResumeCore := nil;
  if (Core <> nil) and (Core = State.Session.Emulation) and
    not State.Session.EmulationFaulted and not State.Session.UserPaused and not State.Session.AutoPaused then
  begin
    if State.Preferences.PauseOnFocusLoss and not HostInputHasFocus then
      State.Session.AutoPaused := True
    else
      Core.Resume;
  end;
  {$ENDIF}
  FormActivate(Self);
  if (ScreenTabs.ActiveTab = GameScreen) and LayoutClient.Visible then
    LayoutClient.SetFocus;
end;

function TFormMain.OpenWebsite: Boolean;
const
  Website = 'https://retromul.retroscraper.pro/';
begin
  {$IF Defined(MSWINDOWS)}
  Result := ShellExecute(WindowHandleToPlatform(Handle).Wnd, 'open', PChar(Website), nil, nil, SW_SHOWNORMAL) > 32;
  {$ELSEIF Defined(ANDROID)}
  var Intent := TJIntent.JavaClass.init(TJIntent.JavaClass.ACTION_VIEW,
    TJnet_Uri.JavaClass.parse(StringToJString(Website)));
  TAndroidHelper.Activity.startActivity(Intent);
  Result := True;
  {$ELSEIF Defined(IOS)}
  var URL := StrToNSUrl(Website);
  var App := TiOSHelper.SharedApplication;
  Result := App.canOpenURL(URL);
  if Result then
    App.openURL(URL, nil, nil);
  {$ELSEIF Defined(MACOS)}
  Result := TNSWorkspace.Wrap(TNSWorkspace.OCClass.sharedWorkspace).openURL(StrToNSUrl(Website));
  {$ELSEIF Defined(LINUX)}
  Result := Posix.Stdlib._system(PAnsiChar(UTF8String('xdg-open ' + Website))) = 0;
  {$ELSE}
  Result := False;
  {$ENDIF}
end;

procedure TFormMain.OpenHelpWebsiteClick(Sender: TObject);
begin
  try
    if not OpenWebsite then
      ShowRetroMessage(Self, Translate('Unable to open the website.'));
  except
    on E: Exception do
      ShowRetroMessage(Self, Translate('Unable to open the website.') + sLineBreak + E.Message);
  end;
end;

procedure TFormMain.ReportBugClick(Sender: TObject);
begin
  if State.Session.OpeningRom then
    Exit;
  if TMainControllers(FControllers).Feedback = nil then
  begin
    TMainControllers(FControllers).Feedback := TFeedbackView.Create(Self);
    TMainControllers(FControllers).Feedback.Parent := Self;
    TMainControllers(FControllers).Feedback.Align := TAlignLayout.Contents;
  end;
  TMainControllers(FControllers).Feedback.OpenReport(Self);
end;

procedure TFormMain.ApplyFeedbackLanguage(const PreviousLanguage: string);
begin
  if TMainControllers(FControllers).Feedback <> nil then
    TMainControllers(FControllers).Feedback.ApplyLanguage(PreviousLanguage);
end;

procedure TFormMain.InitializeLibrary;
begin
  TMainControllers(FControllers).Browser.InitializeLibrary;
  (State.Browser.View.FindComponent('ButtonHelp') as TButton).OnClick := OpenHelpClick;
  (State.Browser.View.FindComponent('ButtonCompactHelp') as TButton).OnClick := OpenHelpClick;
end;

destructor TFormMain.Destroy;
begin
  if TMethod(Application.OnException).Data = Self then
    Application.OnException := State.Session.PreviousExceptionHandler;
  {$IFDEF MSWINDOWS}
  if State.Window.WindowStateRestored and not State.Window.WindowStateSaved and
    not State.Window.WindowStateSaveAttempted then
  try
    SaveWindowState;
  except
    Application.HandleException(Self);
  end;
  {$ENDIF}
  if Assigned(State.Session.InvalidateCallbacks) then
    State.Session.InvalidateCallbacks();
  FreeAndNil(State.Input.Rumble);
  if TimerUpdate <> nil then
    TimerUpdate.Enabled := False;
  try
    AutosaveOnExit;
  except
    Application.HandleException(Self);
  end;
  // Finish image workers while FMX codecs and all bitmap owners still exist.
  FMX.Graphics.TBitmap.ShutdownAsyncLoads;
  FreeAndNil(State.Settings.View);
  FreeAndNil(State.Help.View);
  FreeAndNil(State.Browser.View);
  // Stop callbacks and detach session input while the devices still exist.
  if State.Session.Emulation <> nil then
  try
    State.Session.Emulation.Stop;
  except
    Application.HandleException(Self);
  end;
  TMainControllers(FControllers).Session.DisconnectSession;
  try
    TMainControllers(FControllers).Input.FinalizePeripherals;
  except
    Application.HandleException(Self);
  end;
  {$IF not Defined(LINUX)}
  if State.Input.MotionSensor <> nil then
  try
    State.Input.MotionSensor.Active := False;
  except
  end;
  FreeAndNil(State.Input.MotionSensor);
  {$ENDIF}
  FreeAndNil(State.Input.Manager);
  FreeAndNil(State.Input.Gamepad); // Detach the native listener before destroying the form.
  {$IFDEF ISMOBILE}
  FreeAndNil(State.Mobile.AppEvents);
  {$ENDIF}
  {$IFDEF ANDROID}
  FreeAndNil(State.Mobile.Transfer);
  {$ENDIF}
  State.Session.Emulation := nil;
  try
    inherited;
  finally
    FreeAndNil(FControllers);
    FreeAndNil(FState);
  end;
end;

function TFormMain.CreateStorage: IStorage;
begin
  Result := TStorage.Create('', TStoragePicker.Create);
end;

function TFormMain.CreateHostInput: TInputManager;
begin
  {$IF Defined(ANDROID) or Defined(MSWINDOWS) or (Defined(LINUX) and not Defined(ANDROID)) or (Defined(MACOS) and not Defined(IOS))}
  Result := TGamepadInputManager.Create(CreateFMXInputBackend);
  {$ELSE}
  Result := nil;
  {$ENDIF}
end;

function TFormMain.DetectSystemLanguage: string;
begin
  Result := 'en';
  var Locale: IFMXLocaleService;
  if TPlatformServices.Current.SupportsPlatformService(IFMXLocaleService, Locale) then
    Result := Locale.GetCurrentLangID;
end;

procedure TFormMain.LayoutAchievementNoticeCornerResize(Sender: TObject);
const
  MinimumHeight = 66;
begin
  if RectangleAchievementNotice = nil then
    Exit;
  RectangleAchievementNotice.Width := Min(312, LayoutAchievementNoticeCorner.Width);
  if (LabelAchievementNotice = nil) or not RectangleAchievementNotice.Visible then
    Exit;

  var NoticeHeight := MinimumHeight;
  if LabelAchievementNotice.Text.Contains(sLineBreak) then
  begin
    var Layout := TTextLayoutManager.DefaultTextLayout.Create;
    try
      Layout.BeginUpdate;
      Layout.Font.Assign(LabelAchievementNotice.ResultingTextSettings.Font);
      Layout.MaxSize := TPointF.Create(Max(1, LabelAchievementNotice.Width), 100000);
      Layout.WordWrap := True;
      Layout.Text := LabelAchievementNotice.Text;
      Layout.EndUpdate;
      NoticeHeight := Max(MinimumHeight, Ceil(Layout.TextHeight + LabelAchievementNoticeCaption.Height +
          RectangleAchievementNotice.Padding.Top + RectangleAchievementNotice.Padding.Bottom));
    finally
      Layout.Free;
    end;
  end;
  if LayoutAchievementNoticeCorner.Height <> NoticeHeight then
    LayoutAchievementNoticeCorner.Height := NoticeHeight;
end;

procedure TFormMain.SetAchievementNoticeCorner(Corner: TRAAchievementCorner);
begin
  if Corner in [TRAAchievementCorner.TopRight, TRAAchievementCorner.TopLeft] then
    LayoutAchievementNoticeCorner.Align := TAlignLayout.Top
  else
    LayoutAchievementNoticeCorner.Align := TAlignLayout.Bottom;
  if Corner in [TRAAchievementCorner.TopRight, TRAAchievementCorner.BottomRight] then
    RectangleAchievementNotice.Align := TAlignLayout.Right
  else
    RectangleAchievementNotice.Align := TAlignLayout.Left;
end;

procedure TFormMain.PresentAchievementNotice(const Caption, Text: string; Duration: Integer);
begin
  LabelAchievementNoticeCaption.Text := Caption;
  LabelAchievementNotice.Text := Text;
  RectangleAchievementNotice.Visible := True;
  LayoutAchievementNoticeCornerResize(LayoutAchievementNoticeCorner);
  LayoutAchievementOverlay.BringToFront;
  TimerAchievementNotice.Enabled := False;
  TimerAchievementNotice.Interval := Duration;
  TimerAchievementNotice.Enabled := True;
end;

procedure TFormMain.HideAchievementNotice;
begin
  if TimerAchievementNotice <> nil then
    TimerAchievementNotice.Enabled := False;
  if RectangleAchievementNotice <> nil then
    RectangleAchievementNotice.Visible := False;
end;

procedure TFormMain.TimerAchievementNoticeTimer(Sender: TObject);
begin
  HideAchievementNotice;
end;

procedure TFormMain.RefreshAchievements(Sender: TObject);
begin
  TMainControllers(FControllers).Session.RefreshAchievements;
end;

procedure TFormMain.Load;
begin
  TMainControllers(FControllers).Settings.Load;
end;

procedure TFormMain.Save;
begin
  TMainControllers(FControllers).Settings.Save;
end;

procedure TFormMain.DoOnSettingChange;
begin
  StyleBook := FormStyles.StyleBookWinUI3;

  inherited;

  SystemBackdropType := TWindowBackdropType.Disable;
  Fill.Color := ThemeBackgroundColor;
  Fill.Kind := TBrushKind.Solid;

  TMessageManager.DefaultManager.SendMessage(Self, TStyleChangedMessage.Create(StyleBook, Self), True);
  TMessageManager.DefaultManager.SendMessage(Self, TInternalSettingChangedMessage.Create(StyleBook, Self), True);
end;

procedure TFormMain.DoShow;
begin
  {$IFDEF MSWINDOWS}
  // Apply once, after FMX has positioned and created the native window.
  if not State.Window.WindowStateRestored then
  begin
    State.Window.WindowStateRestored := True;
    RestoreWindowState;
  end;
  {$ENDIF}
  inherited;
  if FControllers <> nil then
    TMainControllers(FControllers).Window.SyncLibrarySystemUI;
end;

{$IFDEF MSWINDOWS}
procedure TFormMain.RestoreWindowState;
begin
  TMainControllers(FControllers).Window.RestoreWindowState;
end;

{$ENDIF}
{$IFDEF MSWINDOWS}
procedure TFormMain.SaveWindowState;
begin
  TMainControllers(FControllers).Window.SaveWindowState;
end;

{$ENDIF}
procedure TFormMain.FormResize(Sender: TObject);
begin
  TMainControllers(FControllers).Window.FormResize(Sender);
end;

procedure TFormMain.ApplyControlInset;
begin
  TMainControllers(FControllers).Window.ApplyControlInset;
end;

procedure TFormMain.FormSafeAreaChanged(Sender: TObject; const AInsets: TRectF);
begin
  TMainControllers(FControllers).Window.FormSafeAreaChanged(Sender, AInsets);
end;

procedure TFormMain.FormActivate(Sender: TObject);
begin
  TMainControllers(FControllers).Session.FormActivate(Sender);
end;

procedure TFormMain.FormDeactivate(Sender: TObject);
begin
  TMainControllers(FControllers).Session.FormDeactivate(Sender);
end;

function TFormMain.HostInputHasFocus: Boolean;
begin
  Result := Active and not RetroDialogVisible(Self) and not State.Session.Reporting;
end;

procedure TFormMain.ApplicationException(Sender: TObject; E: Exception);
begin
  TMainControllers(FControllers).Session.ApplicationException(Sender, E);
end;

procedure TFormMain.DialogActivityChanged(Sender: TObject);
begin
  TMainControllers(FControllers).Session.DialogActivityChanged(Sender);
end;

procedure TFormMain.SetStatus(const Text: string);
begin
  TMainControllers(FControllers).Browser.SetStatus(Text);
end;

procedure TFormMain.SyncActivity;
begin
  TMainControllers(FControllers).Window.SyncLibrarySystemUI;
  TMainControllers(FControllers).Session.SyncActivity;
end;

procedure TFormMain.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  TMainControllers(FControllers).Session.FormCloseQuery(Sender, CanClose);
end;

procedure TFormMain.FormSaveState(Sender: TObject);
begin
  TMainControllers(FControllers).Session.FormSaveState(Sender);
end;

procedure TFormMain.ButtonOpenClick(Sender: TObject);
begin
  TMainControllers(FControllers).Session.ButtonOpenClick(Sender);
end;

procedure TFormMain.ButtonOpenOpticalDiscClick(Sender: TObject);
begin
  TMainControllers(FControllers).Session.ButtonOpenOpticalDiscClick(Sender);
end;

procedure TFormMain.OpenRom;
begin
  TMainControllers(FControllers).Session.OpenRom;
end;

procedure TFormMain.FinishFileSelection;
begin
  TMainControllers(FControllers).Session.FinishFileSelection;
end;

procedure TFormMain.DragOver(const Data: TDragObject; const Point: TPointF; var Operation: TDragOperation);
begin
  if Length(Data.Files) = 0 then
  begin
    inherited;
    Exit;
  end;
  // Handle file drags at form level so child controls cannot consume the ROM.
  Operation := TDragOperation.None;
  if TMainControllers(FControllers).Session.CanAcceptRomDrop(Data) then
    Operation := TDragOperation.Copy;
end;

procedure TFormMain.DragDrop(const Data: TDragObject; const Point: TPointF);
begin
  if Length(Data.Files) = 0 then
  begin
    inherited;
    Exit;
  end;
  if not TMainControllers(FControllers).Session.CanAcceptRomDrop(Data) then
    Exit;
  try
    State.Session.ReportLaunchSource := 'drag_and_drop';
    TMainControllers(FControllers).Session.SelectDocument(Data.Files[0]);
  except
    on E: Exception do
    begin
      FinishFileSelection;
      ShowRetroMessage(Self, E.Message);
    end;
  end;
end;

function TFormMain.CreateCore(const FileName: string): IEmulationCore;
begin
  var Stream := State.Session.Storage.OpenRead(FileName);
  try
    Result := CreateEmulationCore(Stream, State.Session.Storage, FileName);
  finally
    Stream.Free;
  end;
end;

procedure TFormMain.ResetConsole(Hard: Boolean);
begin
  TMainControllers(FControllers).Session.ResetConsole(Hard);
end;

procedure TFormMain.ResetClick(Sender: TObject);
begin
  {$IFDEF MSWINDOWS}
  var Hard := Winapi.Windows.GetKeyState(vkShift) < 0;
  {$ELSE}
  var Hard := State.Input.KeysDown[vkShift] or State.Input.KeysDown[vkLShift] or State.Input.KeysDown[vkRShift];
  {$ENDIF}
  ResetConsole(Hard);
end;

procedure TFormMain.HardRestart;
begin
  TMainControllers(FControllers).Session.HardRestart;
end;

procedure TFormMain.LoadRom(const FileName: string; const DisplayName: string; StartPaused: Boolean; const SnapshotName, LibraryPlatformId: string);
begin
  TMainControllers(FControllers).Session.LoadRom(FileName, DisplayName, StartPaused, SnapshotName, LibraryPlatformId);
end;

procedure TFormMain.ButtonCloseRomClick(Sender: TObject);
begin
  TMainControllers(FControllers).Session.ButtonCloseRomClick(Sender);
end;

procedure TFormMain.Stop;
begin
  TMainControllers(FControllers).Session.Stop;
end;

procedure TFormMain.StopOnError;
begin
  TMainControllers(FControllers).Session.StopOnError;
end;

{$IF not Defined(LINUX)}
procedure TFormMain.ChooseMotionSensor(Sender: TObject; const Sensors: TSensorArray; var ChoseSensorIndex: Integer);
begin
  TMainControllers(FControllers).Input.ChooseMotionSensor(Sender, Sensors, ChoseSensorIndex);
end;
{$ENDIF}

procedure TFormMain.SyncMotionSensor;
begin
  TMainControllers(FControllers).Input.SyncMotionSensor;
end;

procedure TFormMain.PollMotionSensor;
begin
  TMainControllers(FControllers).Input.PollMotionSensor;
end;

procedure TFormMain.PollRumble;
begin
  TMainControllers(FControllers).Input.PollRumble;
end;

procedure TFormMain.TimerUpdateTimer(Sender: TObject);
begin
  TMainControllers(FControllers).Session.TimerUpdateTimer(Sender);
end;

function TFormMain.UpdateFrame: Boolean;
begin
  Result := TMainControllers(FControllers).Session.UpdateFrame;
end;

procedure TFormMain.ReportAudioError(const MessageText: string);
begin
  State.Session.LastReportError := MessageText;
  ShowRetroMessage(Self, Translate('Sound unavailable; the game will continue without audio.') + SLineBreak + TranslateCoreMessage(MessageText), TRetroDialogKind.Warning);
end;

function TFormMain.AutosaveClock: UInt64;
begin
  Result := TThread.GetTickCount64;
end;

procedure TFormMain.AutosaveOnExit;
begin
  TMainControllers(FControllers).Snapshots.AutosaveOnExit;
end;

procedure TFormMain.PollAutosave;
begin
  TMainControllers(FControllers).Snapshots.PollAutosave;
end;

procedure TFormMain.LibraryPlay(Sender: TObject);
begin
  TMainControllers(FControllers).Browser.LibraryPlay(Sender);
end;

procedure TFormMain.LibraryBack(Sender: TObject);
begin
  TMainControllers(FControllers).Browser.LibraryBack(Sender);
end;

procedure TFormMain.PauseClick(Sender: TObject);
begin
  TMainControllers(FControllers).Session.PauseClick(Sender);
end;

procedure TFormMain.SwitchPause;
begin
  TMainControllers(FControllers).Session.SwitchPause;
end;

procedure TFormMain.UpdatePauseOverlay;
begin
  TMainControllers(FControllers).Session.UpdatePauseOverlay;
end;

procedure TFormMain.FullscreenClick(Sender: TObject);
begin
  TMainControllers(FControllers).Window.FullscreenClick(Sender);
end;

procedure TFormMain.SwitchFullScreen;
begin
  TMainControllers(FControllers).Window.SwitchFullScreen;
end;

procedure TFormMain.UpdateGameChrome;
begin
  TMainControllers(FControllers).Browser.UpdateGameChrome;
end;

procedure TFormMain.InsertCoinClick(Sender: TObject);
begin
  TMainControllers(FControllers).Session.InsertCoinClick(Sender);
end;

procedure TFormMain.LayoutClientClick(Sender: TObject);
begin
  TMainControllers(FControllers).Browser.LayoutClientClick(Sender);
end;

procedure TFormMain.LayoutClientDblClick(Sender: TObject);
begin
  TMainControllers(FControllers).Browser.LayoutClientDblClick(Sender);
end;

procedure TFormMain.SettingsClick(Sender: TObject);
begin
  TMainControllers(FControllers).Settings.SettingsClick(Sender);
end;

procedure TFormMain.SettingsApplied(Sender: TObject);
begin
  TMainControllers(FControllers).Settings.SettingsApplied(Sender);
end;

procedure TFormMain.SettingsClose(Sender: TObject);
begin
  TMainControllers(FControllers).Settings.SettingsClose(Sender);
end;

procedure TFormMain.ControlsHelpClick(Sender: TObject);
begin
  TMainControllers(FControllers).Settings.ControlsHelpClick(Sender);
end;

procedure TFormMain.ControlsHelpClose(Sender: TObject);
begin
  TMainControllers(FControllers).Settings.ControlsHelpClose(Sender);
end;

procedure TFormMain.ControlsHelpSettings(Sender: TObject);
begin
  TMainControllers(FControllers).Settings.ControlsHelpSettings(Sender);
end;

procedure TFormMain.CloseControlsHelp(OpenSettings: Boolean);
begin
  TMainControllers(FControllers).Settings.CloseControlsHelp(OpenSettings);
end;

function TFormMain.GameSnapshotDirectory: string;
begin
  Result := TMainControllers(FControllers).Snapshots.GameSnapshotDirectory;
end;

procedure TFormMain.SaveSnapshot(const Name: string);
begin
  TMainControllers(FControllers).Snapshots.SaveSnapshot(Name);
end;

procedure TFormMain.LoadSnapshot(const Name: string);
begin
  TMainControllers(FControllers).Snapshots.LoadSnapshot(Name);
end;

procedure TFormMain.LoadSnapshotPreview(const Name: string);
begin
  TMainControllers(FControllers).Snapshots.LoadSnapshotPreview(Name);
end;

procedure TFormMain.SaveStateClick(Sender: TObject);
begin
  TMainControllers(FControllers).Snapshots.SaveStateClick(Sender);
end;

procedure TFormMain.LoadStateClick(Sender: TObject);
begin
  TMainControllers(FControllers).Snapshots.LoadStateClick(Sender);
end;

procedure TFormMain.PrepareGameplayMenu(Sender: TObject);
begin
  TMainControllers(FControllers).Snapshots.PrepareGameplayMenu(Sender);
end;

function TFormMain.ExecuteSnapshotDialog(Dialog: TOpenDialog): Boolean;
begin
  Result := Dialog.Execute;
end;

procedure TFormMain.SaveSnapshotAsClick(Sender: TObject);
begin
  TMainControllers(FControllers).Snapshots.SaveSnapshotAsClick(Sender);
end;

procedure TFormMain.OpenSnapshotClick(Sender: TObject);
begin
  TMainControllers(FControllers).Snapshots.OpenSnapshotClick(Sender);
end;

procedure TFormMain.RecentSnapshotClick(Sender: TObject);
begin
  TMainControllers(FControllers).Snapshots.RecentSnapshotClick(Sender);
end;

procedure TFormMain.ScreenshotClick(Sender: TObject);
begin
  TMainControllers(FControllers).Snapshots.ScreenshotClick(Sender);
end;

function TFormMain.SaveScreenshot: string;
begin
  Result := TMainControllers(FControllers).Snapshots.SaveScreenshot;
end;

procedure TFormMain.OpenScreenshotFolderClick(Sender: TObject);
begin
  TMainControllers(FControllers).Snapshots.OpenScreenshotFolderClick(Sender);
end;

procedure TFormMain.OpenDirectory(const Directory: string);
begin
  {$IFDEF MSWINDOWS}
  if NativeInt(ShellExecute(0, 'open', PChar(Directory), nil, nil, SW_SHOWNORMAL)) > 32 then
    Exit;
  {$ENDIF}
  {$IF Defined(MACOS) and not Defined(IOS)}
  if TNSWorkspace.Wrap(TNSWorkspace.OCClass.sharedWorkspace).openFile(StrToNSStr(Directory)) then
    Exit;
  {$ENDIF}
  {$IF Defined(LINUX) and not Defined(ANDROID)}
  var Quoted := #39 + Directory.Replace(#39, #39 + '"' + #39 + '"' + #39) + #39;
  if Posix.Stdlib._system(PAnsiChar(UTF8String('xdg-open ' + Quoted))) = 0 then
    Exit;
  {$ENDIF}
  raise EInOutError.Create(Translate('Cannot open screenshot folder'));
end;

procedure TFormMain.LoadHostInput(const SystemId: string);
begin
  TMainControllers(FControllers).Input.LoadHostInput(SystemId);
end;

procedure TFormMain.ReloadHostInputBindings;
begin
  TMainControllers(FControllers).Input.ReloadHostInputBindings;
end;

procedure TFormMain.PollHostInput;
begin
  TMainControllers(FControllers).Input.PollHostInput;
end;

procedure TFormMain.KeyDown(var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
begin
  {$IFDEF ANDROID}
  // Handle Back on key-up, so the same press cannot also close settings.
  if RetroDialogVisible(Self) and (Key = vkHardwareBack) then
  begin
    Key := 0;
    KeyChar := #0;
    Exit;
  end;
  {$ENDIF}
  if HandleRetroDialogKey(Self, Key, KeyChar) then
  begin
    if Key = vkTab then
      inherited;
    Exit;
  end;
  if State.Session.Reporting then
  begin
    inherited;
    Exit;
  end;
  if HelpPageActive then
  begin
    if (Key = vkEscape) {$IFDEF ANDROID} or (Key = vkHardwareBack){$ENDIF} then
    begin
      Key := 0;
      KeyChar := #0;
    end
    else
      inherited;
    Exit;
  end;
  // Intercept before FMX dispatches to focused controls and handles Tab.
  if (State.Settings.View <> nil) and State.Settings.View.HandleCaptureKeyDown(Key, KeyChar) then
    Exit;
  if Key = vkF11 then
  begin
    TMainControllers(FControllers).Input.FormKeyDown(Self, Key, KeyChar, Shift);
    if (Key = 0) and (KeyChar = #0) then
      Exit;
  end;
  if (State.Settings.View = nil) and State.Browser.ViewingLibrary and
    (State.Browser.View <> nil) and State.Browser.View.GamepadMode then
  begin
    // Library shortcuts and their input-source hints must precede focused edits/buttons.
    TMainControllers(FControllers).Input.FormKeyDown(Self, Key, KeyChar, Shift);
    if (Key = 0) and (KeyChar = #0) then
      Exit;
  end;
  inherited;
end;

procedure TFormMain.FormKeyDown(Sender: TObject; var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
begin
  TMainControllers(FControllers).Input.FormKeyDown(Sender, Key, KeyChar, Shift);
end;

procedure TFormMain.FormKeyUp(Sender: TObject; var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
begin
  TMainControllers(FControllers).Input.FormKeyUp(Sender, Key, KeyChar, Shift);
end;

procedure TFormMain.ForwardKeyState(Code: Word; Pressed: Boolean);
begin
  TMainControllers(FControllers).Input.ForwardKeyState(Code, Pressed);
end;

procedure TFormMain.GamepadChanged(Sender: TObject);
begin
  TMainControllers(FControllers).Input.GamepadChanged(Sender);
end;

function TFormMain.CombinedGamepadInput: TEmulatorInput;
begin
  Result := TMainControllers(FControllers).Input.CombinedGamepadInput;
end;

procedure TFormMain.UpdatePeripheralInput;
begin
  TMainControllers(FControllers).Input.UpdatePeripheralInput;
end;

procedure TFormMain.UpdatePeripheralFeedback;
begin
  TMainControllers(FControllers).Input.UpdatePeripheralFeedback;
end;

procedure TFormMain.ImageCanvasMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Single);
begin
  TMainControllers(FControllers).Input.ImageCanvasMouseDown(Sender, Button, Shift, X, Y);
end;

procedure TFormMain.ImageCanvasMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Single);
begin
  TMainControllers(FControllers).Input.ImageCanvasMouseMove(Sender, Shift, X, Y);
end;

procedure TFormMain.ImageCanvasMouseUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Single);
begin
  TMainControllers(FControllers).Input.ImageCanvasMouseUp(Sender, Button, Shift, X, Y);
end;

procedure TFormMain.SelectTapeFile(const FileName: string);
begin
  TMainControllers(FControllers).Input.SelectTapeFile(FileName);
end;

{$IFDEF ISMOBILE}
function TFormMain.ApplicationStateChanged(Sender: TObject; const AAppEvent: TApplicationEvent; const AContext: TObject): Boolean;
begin
  Result := TMainControllers(FControllers).Mobile.ApplicationStateChanged(Sender, AAppEvent, AContext);
end;
{$ENDIF}

{$IFDEF ANDROID}

procedure TFormMain.PollDocumentTransfer;
begin
  TMainControllers(FControllers).Mobile.PollDocumentTransfer;
end;
{$ENDIF}

end.

