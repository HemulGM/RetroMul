unit RM.Settings;

interface

uses
  Core.RomFormat, System.SysUtils, System.Classes, System.IniFiles,
  System.Generics.Collections, System.Types, System.UITypes, FMX.Types,
  FMX.Controls, FMX.Layouts, FMX.StdCtrls, FMX.Text, FMX.Edit, FMX.EditBox,
  FMX.SpinBox, FMX.ListBox, FMX.Controls.Presentation, Core.Storage,
  Core.Emulation, FMXInput;

type
  TDeviceCallouts = class;

  TBindingLines = class(TControl)
  protected
    procedure Paint; override;
  end;

  TBindingCallout = record
    Button: Integer;
    Name: string;
    Left: Boolean;
    LabelControl: TLabel;
  end;

  TDeviceCallouts = class(TControl)
  private
    FDevice: TControl;
    FItems: TArray<TBindingCallout>;
    FLines: TBindingLines;
    FInput: TInputManager;
    FAnnotations: Boolean;
    function ButtonBounds(Index: Integer): TRectF;
    procedure AddCallout(Button, Action: Integer; const Name, Caption: string; Left: Boolean; Click: TNotifyEvent);
  protected
    procedure Resize; override;
  public
    procedure Configure(Device: TControl; Input: TInputManager; const Core: string; Port: Integer; Click: TNotifyEvent);
    procedure Refresh;
    procedure ShowAnnotations(Value: Boolean);
  end;

  TSettingsLocationPicker = reference to procedure(Folder: Boolean; const Current: string; const Callback: TStorageSelectionCallback);

  TSettingsField = class
    Control: TControl;
    Row: TPanel;
    Section, Key, DefaultValue: string;
    Values: TArray<string>;
  end;

  TSettingsDevice = class
    Control: TControl;
    Diagram: TControl;
    Capture, Clear: TButton;
    Caption: TLabel;
    Assignments: TVertScrollBox;
    AssignmentList: TLayout;
    Port: Integer;
    Device: string;
  end;

  TSettingsView = class(TPanel)
  private
    FStorage: IStorage;
    FPicker: TSettingsLocationPicker;
    FInput: TInputManager; // Shared with the frontend; ownership stays with the form.
    FDrafts: array[0..6] of TMemIniFile;
    FFields: TObjectList<TSettingsField>;
    FDevices: TObjectList<TSettingsDevice>;
    FSidebar: TPanel;
    FGroup: TPanel;
    FCategory, FCorePage, FPlayer: Integer;
    FCoreTabs: TLayout;
    FCoreButtons: array[1..6] of TButton;
    FSearch: TEdit;
    FReset: TButton;
    FPreview: TControl;
    FPreviewGroup: TPanel;
    FRefresh: TButton;
    FNavigation: TListBox;
    FCategoryIcons: array[0..4] of TControl;
    FPagePicker: TComboBox;
    FBody, FContent, FHeader, FFooter: TLayout;
    FScroll: TVertScrollBox;
    FTitle, FStatus: TLabel;
    FApply, FBack, FCancelCapture: TButton;
    FPage, FCaptureAction: Integer;
    FHeight: Single;
    FBuilding, FRebuildPending, FArranging: Boolean;
    FVolumeValue: TLabel;
    FCaptureDeadline: UInt64;
    FCaptureButton: TButton;
    FDeviceIds: array[0..7] of string;
    FOnApply, FOnClose: TNotifyEvent;
    FFolderEdit: TEdit;
    FAutosaveMinutes: TSpinBox;
    FAlive: TFunc<Boolean>;
    FInvalidate: TProc;
    procedure AutosaveToggle(Sender: TObject);
    function Row(const Caption, Description: string): TPanel;
    function Field(Control: TControl; const Section, Key: string): TSettingsField;
    function Combo(const Caption, Description, Section, Key: string; const Labels, Values: array of string; const Default: string): TComboBox;
    function Check(const Caption, Description, Section, Key: string; Default: Boolean): TSwitch;
    function Number(const Caption, Description, Section, Key: string; Default, Max: Integer): TSpinBox;
    function EditText(const Caption, Description, Section, Key, Default: string): TEdit;
    procedure Heading(const Caption: string);
    procedure SearchChange(Sender: TObject);
    procedure CoreClick(Sender: TObject);
    procedure ResetClick(Sender: TObject);
    procedure PlayerChange(Sender: TObject);
    procedure PreviewChange(Sender: TObject);
    procedure ArrangeGroup(Group: TPanel);
    procedure DeviceResize(Sender: TObject);
    procedure AssignmentClick(Sender: TObject);
    procedure NavigationChange(Sender: TObject);
    procedure PagePickerChange(Sender: TObject);
    procedure PortChange(Sender: TObject);
    procedure CaptureClick(Sender: TObject);
    procedure ClearBindingClick(Sender: TObject);
    procedure CancelCaptureClick(Sender: TObject);
    procedure PathClick(Sender: TObject);
    function PathEdit(const Caption, Description, Section, Key, Default: string; Folder: Boolean): TEdit;
    procedure VolumeChange(Sender: TObject);
    procedure ContentResize(Sender: TObject);
    procedure ComboResize(Sender: TObject);
    procedure EditorResize(Sender: TObject);
    procedure BuildDevice(Port: Integer; const Device: string);
    procedure VirtualDeviceChange(Sender: TObject);
    procedure CalloutClick(Sender: TObject);
    procedure SelectBinding(Device: TSettingsDevice; Action: Integer; const Caption: string);
    procedure RefreshBindings;
    procedure ApplyClick(Sender: TObject);
    procedure BackClick(Sender: TObject);
    procedure StorePage;
    procedure BuildPage(PreserveScroll: Boolean = False);
    procedure RequestRebuild;
    procedure BuildPort(Port: Integer; const Caption: string);
    procedure BuildBindings(Port: Integer; const Device: string);
    function AddBinding(const Caption: string; Action, Port: Integer): TButton;
    procedure DeviceChange(Sender: TObject);
    procedure RefreshDevicesClick(Sender: TObject);
    procedure RowResize(Sender: TObject);
    procedure BindingFooterResize(Sender: TObject);
  protected
    procedure Resize; override;
    procedure PickLocation(Folder: Boolean; const Current: string; const Callback: TStorageSelectionCallback); virtual;
  public
    constructor CreateSettings(AOwner: TComponent; const Storage: IStorage; Input: TInputManager);
    destructor Destroy; override;
    procedure SelectCategory(Index: Integer);
    procedure SelectCore(Index: Integer);
    property Category: Integer read FCategory;
    property CorePage: Integer read FCorePage;
    procedure Poll;
    procedure CancelCapture;
    procedure ApplyLanguage(const PreviousLanguage: string);
    property OnApply: TNotifyEvent read FOnApply write FOnApply;
    property LocationPicker: TSettingsLocationPicker read FPicker write FPicker;
    property OnClose: TNotifyEvent read FOnClose write FOnClose;
  end;

const
  AUTOSAVE_DEFAULT_MINUTES = 10;
  AUTOSAVE_MAX_MINUTES = 1440;
  SettingsCategoryNames: array[0..4] of string = ('General', 'Library', 'Video and audio', 'Controls', 'Peripherals');
  SettingsCoreIds: array[1..6] of string = (
    ROM_SYSTEM_GB, ROM_SYSTEM_GBC, ROM_SYSTEM_NES, ROM_SYSTEM_MD, ROM_SYSTEM_SNES, ROM_SYSTEM_NEOGEO);
  SettingsPageNames: array[0..6] of string = ('Main', 'Game Boy', 'Game Boy Color',
    'NES / Famicom', 'Mega Drive', 'Super Nintendo', 'Neo Geo');

implementation

uses
  System.Math, System.IOUtils, System.TypInfo, RM.Input, GB.Palettes,
  FMX.OpenDialog, RM.Gamepad, NES.PowerPad, NES.SuborKeyboard,
  NES.FamicomKeyboard, NES.MiraclePiano, NES.Controller, NES.MiraclePianoDevice,
  FMX.BehaviorManager, FMX.Graphics, FMX.SpinBox.Style, FMX.Presentation.Style,
  FMX.Presentation.Factory, FMX.Objects, RM.LibraryView, RM.Icons, RM.SearchEdit, RM.Styles;

type
  TSettingsPreview = class(TControl)
  public
    PaletteIndex: Integer;
  protected
    procedure Paint; override;
  end;

  TSettingsComboBox = class(TComboBox)
  private
    FCaption: TLabel;
  protected
    procedure ApplyStyle; override;
    procedure DoChange; override;
  public
    constructor Create(AOwner: TComponent); override;
  end;

  TSettingsTrackBar = class(TTrackBar)
  protected
    procedure DoRealign; override;
    procedure MouseWheel(Shift: TShiftState; WheelDelta: Integer; var Handled: Boolean); override;
  end;

  TSettingsSpinBox = class(TSpinBox)
  protected
    function DefinePresentationName: string; override;
  end;

  TSettingsSpinBoxStyle = class(TStyledSpinBox)
  protected
    procedure MouseWheel(Shift: TShiftState; WheelDelta: Integer; var Handled: Boolean); override;
  end;

function SettingsLabel(Owner: TComponent): TLabel;
begin
  Result := TLabel.Create(Owner);
  Result.StyledSettings := Result.StyledSettings - [TStyledSetting.Other];
  Result.TextSettings.Trimming := TTextTrimming.Character;
  Result.TextSettings.WordWrap := False;
end;

function SettingsButton(Owner: TComponent): TButton;
begin
  Result := TButton.Create(Owner);
  Result.StyledSettings := Result.StyledSettings - [TStyledSetting.Other];
  Result.TextSettings.Trimming := TTextTrimming.Character;
  Result.TextSettings.WordWrap := False;
end;

constructor TSettingsComboBox.Create(AOwner: TComponent);
begin
  inherited;
  StyleLookup := 'comboboxstyle';
  FCaption := SettingsLabel(Self);
  FCaption.Parent := Self;
  FCaption.Align := TAlignLayout.Client;
  FCaption.Margins.Rect := TRectF.Create(12, 0, 32, 0);
  FCaption.HitTest := False;
  FCaption.StyledSettings := [];
  FCaption.TextSettings.Font.Family := 'Segoe UI';
  FCaption.TextSettings.Font.Size := 14;
  FCaption.TextSettings.FontColor := $FFE8ECF1;
end;

procedure TSettingsComboBox.ApplyStyle;
begin
  inherited;
  var Content: TControl;
  if FindStyleResource<TControl>('content', Content) then
    Content.OnPaint := nil;
  if FCaption <> nil then
    FCaption.BringToFront;
end;

procedure TSettingsComboBox.DoChange;
begin
  if FCaption <> nil then
    FCaption.Text := Text;
  inherited;
end;

procedure TSettingsPreview.Paint;
begin
  inherited;
  var Palette := ScreenPalettes[EnsureRange(PaletteIndex, 0, SCREEN_PALETTE_COUNT - 1)];
  var W := Width / 32;
  var H := Height / 29;
  Canvas.Fill.Kind := TBrushKind.Solid;
  for var Y := 0 to 28 do
    for var X := 0 to 31 do
    begin
      var Shade := 0;
      if Y > 12 + Abs(16 - X) div 2 then
        Shade := 1;
      if Y > 19 then
        Shade := 2;
      if (Y = 20) or ((Y > 20) and ((X + Y) mod 4 = 0)) then
        Shade := 3;
      if (X in [4..7]) and (Y in [9..16]) then
        Shade := 2;
      if (X = 6) and (Y in [16..19]) then
        Shade := 3;
      if (X in [14..15]) and (Y in [16..19]) then
        Shade := 3;
      if (Y in [4..5]) and (X in [18..22]) then
        Shade := 0;
      Canvas.Fill.Color := Palette.Colors[Shade];
      Canvas.FillRect(TRectF.Create(Floor(X * W), Floor(Y * H), Ceil((X + 1) * W), Ceil((Y + 1) * H)), 0, 0, [], AbsoluteOpacity);
    end;
end;

procedure TSettingsTrackBar.DoRealign;
begin
  inherited;
  // FMX updates the highlight during Resize, before the styled track is resized.
  // Recalculate it after alignment, when the track and thumb have their final bounds.
  if (FTrack = nil) or (FTrackHighlight = nil) then
    Exit;
  var Center := GetThumbRect.CenterPoint;
  if Orientation = TOrientation.Horizontal then
  begin
    if Reverse then
      Center.X := FTrack.Width - Center.X;
    FTrackHighlight.Width := Round(Center.X);
  end
  else
  begin
    if Reverse then
      Center.Y := FTrack.Height - Center.Y;
    FTrackHighlight.Height := Round(Center.Y);
  end;
end;

procedure TSettingsTrackBar.MouseWheel(Shift: TShiftState; WheelDelta: Integer; var Handled: Boolean);
begin
  // Leave the wheel unhandled so the containing scroll box receives it.
end;

function TSettingsSpinBox.DefinePresentationName: string;
begin
  Result := 'SettingsSpinBox-' + GetPresentationSuffix;
end;

procedure TSettingsSpinBoxStyle.MouseWheel(Shift: TShiftState; WheelDelta: Integer; var Handled: Boolean);
begin
  // TStyledEditBox increments even when Handled is true; bypass that implementation.
end;

function TDeviceCallouts.ButtonBounds(Index: Integer): TRectF;
begin
  if FDevice is TNesPowerPad then
    Result := TNesPowerPad(FDevice).ButtonBounds(FItems[Index].Button)
  else
    Result := TScreenGamepad(FDevice).ButtonBounds(TEmulatorButton(FItems[Index].Button));
end;

procedure TDeviceCallouts.AddCallout(Button, Action: Integer; const Name, Caption: string; Left: Boolean; Click: TNotifyEvent);
begin
  var Index := Length(FItems);
  SetLength(FItems, Index + 1);
  FItems[Index].Button := Button;
  FItems[Index].Name := Name;
  FItems[Index].Left := Left;
  var L := SettingsLabel(Self);
  FItems[Index].LabelControl := L;
  L.Parent := Self;
  L.Height := 28;
  L.HitTest := FInput <> nil;
  L.OnClick := Click;
  L.Tag := Action;
  L.TagString := Caption;
  L.StyledSettings := L.StyledSettings - [TStyledSetting.Size, TStyledSetting.Other];
  L.TextSettings.Font.Size := 12;
  L.TextSettings.WordWrap := False;
  L.TextSettings.Trimming := TTextTrimming.Character;
  if Left then
    L.TextSettings.HorzAlign := TTextAlign.Trailing
  else
    L.TextSettings.HorzAlign := TTextAlign.Leading;
end;

procedure TDeviceCallouts.Configure(Device: TControl; Input: TInputManager; const Core: string; Port: Integer; Click: TNotifyEvent);
begin
  HitTest := False;
  FDevice := Device;
  FInput := Input;
  FDevice.Parent := Self;
  FAnnotations := True;
  FDevice.Align := TAlignLayout.None;
  FLines := TBindingLines.Create(Self);
  FLines.Parent := Self;
  FLines.Align := TAlignLayout.Client;
  FLines.HitTest := False;
  if Device is TNesPowerPad then
    for var Button := 1 to 12 do
      AddCallout(Button, PowerPadAction + Button - 1, IntToStr(Button),
        Translate('Pad ') + IntToStr(Button), (Button - 1) mod 4 < 2, Click)
  else
    for var B in TScreenGamepad(Device).ButtonMask do
    begin
      var Left := B in [TEmulatorButton.Up, TEmulatorButton.Down,
          TEmulatorButton.Left, TEmulatorButton.Right, TEmulatorButton.Select,
          TEmulatorButton.Mode];
      if (Core = ROM_SYSTEM_SNES) and (B = TEmulatorButton.C) then
        Left := True;
      var Name := CoreButtonName(Core, B);
      AddCallout(Ord(B), PadAction(Port, B), Name, Translate('Button ') + Name, Left, Click);
    end;
  Refresh;
  Resize;
end;

procedure TDeviceCallouts.Refresh;
begin
  for var Item in FItems do
  begin
    var L := Item.LabelControl;
    if L = nil then
      Continue;

    var Assignment := BindingCaption(FInput, L.Tag);
    L.Text := Item.Name + ' · ' + Assignment;
    if Width < 460 then
      L.Text := Assignment;
    L.Hint := L.TagString + ': ' + Assignment;
    L.ShowHint := True;
  end;
end;

procedure TDeviceCallouts.Resize;
begin
  inherited;
  if csDestroying in ComponentState then
    Exit;
  if (FDevice = nil) or (FLines = nil) then
    Exit;

  var Rail := Min(170, Max(40, Width * 0.18));
  if not FAnnotations then
    Rail := 0;
  var Aspect: Single := 0.46;
  if FDevice is TScreenGamepad then
    Aspect := TScreenGamepad(FDevice).AspectRatio;
  if FDevice is TNesPowerPad then
    Aspect := 3.8 / 4.4;
  var Limit := IfThen(FAnnotations, 400, 640);
  var PadWidth := Min(Min(Limit, Max(40, Height / Aspect)), Max(40, Width - 2 * (Rail + 12)));
  FDevice.SetBounds((Width - PadWidth) / 2, (Height - PadWidth * Aspect) / 2,
    PadWidth, PadWidth * Aspect);
  for var Side := 0 to 1 do
  begin
    var Buttons: TArray<Integer> := nil;
    for var B := 0 to High(FItems) do
      if FItems[B].Left = (Side = 0) then
      begin
        var N := Length(Buttons);
        SetLength(Buttons, N + 1);
        Buttons[N] := B;
      end;
    // Match vertical button order to the callouts to limit crossed leaders.
    for var i := 0 to High(Buttons) - 1 do
      for var J := i + 1 to High(Buttons) do
      begin
        var ReverseColumns := (FDevice is TNesPowerPad) and (Side = 1);
        var EarlierColumn := ButtonBounds(Buttons[J]).CenterPoint.X < ButtonBounds(Buttons[i]).CenterPoint.X;
        if ReverseColumns then
          EarlierColumn := ButtonBounds(Buttons[J]).CenterPoint.X > ButtonBounds(Buttons[i]).CenterPoint.X;
        if (ButtonBounds(Buttons[J]).CenterPoint.Y < ButtonBounds(Buttons[i]).CenterPoint.Y) or
          ((ButtonBounds(Buttons[J]).CenterPoint.Y = ButtonBounds(Buttons[i]).CenterPoint.Y) and
          EarlierColumn) then
        begin
          var B := Buttons[i];
          Buttons[i] := Buttons[J];
          Buttons[J] := B;
        end;
      end;
    var Step := Min(34, Height / Max(1, Length(Buttons)));
    for var i := 0 to High(Buttons) do
    begin
      var L := FItems[Buttons[i]].LabelControl;
      var X: Single := 0;
      if Side = 1 then
        X := Width - Rail;
      L.SetBounds(X, (Height - Step * Length(Buttons)) / 2 + i * Step + (Step - L.Height) / 2,
        Rail, L.Height);
    end;
  end;
  Refresh;
  FLines.Repaint;
end;

procedure TDeviceCallouts.ShowAnnotations(Value: Boolean);
begin
  FAnnotations := Value;
  for var Item in FItems do
    Item.LabelControl.Visible := Value;
  FLines.Visible := Value;
  Resize;
end;

procedure TBindingLines.Paint;
begin
  inherited;
  var D := TDeviceCallouts(Parent);
  Canvas.Stroke.Kind := TBrushKind.Solid;
  Canvas.Stroke.Color := TAlphaColors.Gray;
  Canvas.Stroke.Thickness := 1;
  for var B := 0 to High(D.FItems) do
  begin
    var R := D.ButtonBounds(B);
    var L := D.FItems[B].LabelControl;
    var Start := R.CenterPoint + D.FDevice.Position.Point;
    var Finish := TPointF.Create(L.Position.X - 5, L.Position.Y + L.Height / 2);
    Start.X := R.Right + D.FDevice.Position.X;
    if D.FItems[B].Left then
    begin
      Start.X := R.Left + D.FDevice.Position.X;
      Finish.X := L.Position.X + L.Width + 5;
    end;
    if (D.FDevice is TNesPowerPad) and ((D.FItems[B].Button - 1) mod 4 in [1, 2]) then
    begin
      // Route inner columns through the gaps below each row, away from pad numbers.
      Start := TPointF.Create(R.CenterPoint.X + D.FDevice.Position.X, R.Bottom + D.FDevice.Position.Y);
      var ExitPoint := TPointF.Create(Start.X, Start.Y + 4);
      var RailX := D.FDevice.Position.X + D.FDevice.Width + 8;
      if D.FItems[B].Left then
        RailX := D.FDevice.Position.X - 8;
      var Outside := TPointF.Create(RailX, ExitPoint.Y);
      var Elbow := TPointF.Create(RailX, Finish.Y);
      Canvas.DrawLine(Start, ExitPoint, AbsoluteOpacity * 0.8);
      Canvas.DrawLine(ExitPoint, Outside, AbsoluteOpacity * 0.8);
      Canvas.DrawLine(Outside, Elbow, AbsoluteOpacity * 0.8);
      Canvas.DrawLine(Elbow, Finish, AbsoluteOpacity * 0.8);
    end
    else
    begin
      var Elbow := TPointF.Create((Start.X + Finish.X) / 2, Finish.Y);
      Canvas.DrawLine(Start, Elbow, AbsoluteOpacity * 0.8);
      Canvas.DrawLine(Elbow, Finish, AbsoluteOpacity * 0.8);
    end;
    Canvas.Fill.Color := TAlphaColors.Gray;
    Canvas.FillEllipse(TRectF.Create(Start.X - 2, Start.Y - 2, Start.X + 2, Start.Y + 2), AbsoluteOpacity);
  end;
end;

constructor TSettingsView.CreateSettings(AOwner: TComponent; const Storage: IStorage; Input: TInputManager);
begin
  inherited Create(AOwner);
  StyleLookup := 'retromul_settings';
  FCorePage := 1;
  FStorage := Storage;
  FInput := Input;
  FFields := TObjectList<TSettingsField>.Create;
  FDevices := TObjectList<TSettingsDevice>.Create;
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
  FDrafts[0] := FStorage.ReadConfig(FStorage.ConfigFile('config'));
  FDrafts[0].WriteString('General', 'Path', FStorage.RomFolder);
  for var i := 1 to High(SettingsCoreIds) do
    FDrafts[i] := FStorage.ReadConfig(FStorage.ConfigFile(SettingsCoreIds[i]));
  FSidebar := TPanel.Create(Self);
  FSidebar.Parent := Self;
  FSidebar.Align := TAlignLayout.Left;
  FSidebar.Width := 264;
  FSidebar.StyleLookup := 'retromul_sidebar';
  var Brand := SettingsLabel(Self);
  Brand.Parent := FSidebar;
  Brand.Align := TAlignLayout.Top;
  Brand.Height := 76;
  Brand.Margins.Left := 64;
  Brand.Text := 'RetroMul';
  Brand.StyledSettings := Brand.StyledSettings - [TStyledSetting.Size, TStyledSetting.Style];
  Brand.TextSettings.Font.Size := 23;
  Brand.TextSettings.Font.Style := [TFontStyle.fsBold];
  InterfaceIcon(FSidebar, IconPad, 24, 26, 30, $FFFFB344);
  var Back := SettingsButton(Self);
  Back.Parent := FSidebar;
  Back.Align := TAlignLayout.Top;
  Back.Margins.Rect := TRectF.Create(12, 0, 12, 24);
  Back.Height := 42;
  Back.Text := Translate('Back to library');
  CreatePathIcon(Back, IconBack, 16, 11, 20, $FFE8ECF1);
  Back.StylesData['text.Margins.Left'] := 36;
  Back.StylesData['text.Margins.Right'] := 10;
  Back.StyleLookup := 'buttonstyle_subtle';
  Back.OnClick := BackClick;
  FNavigation := TListBox.Create(Self);
  FNavigation.Name := 'SettingsNavigation';
  FNavigation.Parent := FSidebar;
  FNavigation.Align := TAlignLayout.Client;
  FNavigation.Width := 204;
  FNavigation.Margins.Rect := TRectF.Create(12, 24, 12, 12);
  FNavigation.ShowScrollBars := False;
  FNavigation.ScrollAnimation := TBehaviorBoolean.True;
  FNavigation.ItemHeight := 52;
  for var Index := 0 to High(SettingsCategoryNames) do
  begin
    var Item := TListBoxItem.Create(Self);
    Item.Parent := FNavigation;
    Item.Text := Translate(SettingsCategoryNames[Index]);
    Item.StyleLookup := 'listboxitemstyle';
    Item.StyledSettings := Item.StyledSettings - [TStyledSetting.Size, TStyledSetting.Other];
    Item.TextSettings.Trimming := TTextTrimming.Character;
    Item.TextSettings.WordWrap := False;
    Item.TextSettings.Font.Size := 15;
    Item.StylesData['text.Margins.Left'] := 48;
    var Icon := IconGear;
    case Index of
      1:
        Icon := IconLibrary;
      2:
        Icon := IconDisplay;
      3, 4:
        Icon := IconPad;
    end;
    FCategoryIcons[Index] := InterfaceIcon(Item, Icon, 12, 14, 24);
  end;
  FNavigation.ItemIndex := 0;
  FNavigation.OnChange := NavigationChange;
  FBody := TLayout.Create(Self);
  FBody.Parent := Self;
  FBody.Align := TAlignLayout.Client;
  FBody.Padding.Rect := TRectF.Create(24, 16, 24, 16);
  FHeader := TLayout.Create(Self);
  FHeader.Parent := FBody;
  FHeader.Align := TAlignLayout.Top;
  FHeader.Height := 100;
  FTitle := SettingsLabel(Self);
  FTitle.Parent := FHeader;
  FTitle.Align := TAlignLayout.Top;
  FTitle.Height := 44;
  FTitle.StyledSettings := FTitle.StyledSettings - [TStyledSetting.Size];
  FTitle.TextSettings.Font.Size := 30;
  FSearch := TSearchEdit.Create(Self);
  FSearch.Parent := FHeader;
  FSearch.Name := 'SettingsSearch';
  FSearch.SetBounds(560, 0, 260, 32);
  FSearch.TextPrompt := Translate('Search this section');
  FSearch.OnChangeTracking := SearchChange;
  FSearch.OnResize := EditorResize;
  FCoreTabs := TLayout.Create(Self);
  FCoreTabs.Parent := FHeader;
  FCoreTabs.Align := TAlignLayout.Bottom;
  FCoreTabs.Height := 40;
  for var i := 1 to 6 do
  begin
    FCoreButtons[i] := SettingsButton(Self);
    FCoreButtons[i].Parent := FCoreTabs;
    FCoreButtons[i].Text := SettingsPageNames[i];
    FCoreButtons[i].Tag := i;
    FCoreButtons[i].OnClick := CoreClick;
  end;
  FPagePicker := TSettingsComboBox.Create(Self);
  FPagePicker.Parent := FHeader;
  FPagePicker.Align := TAlignLayout.Bottom;
  FPagePicker.Height := 32;
  FPagePicker.OnResize := ComboResize;
  ComboResize(FPagePicker);
  for var Name in SettingsCategoryNames do
    FPagePicker.Items.Add(Translate(Name));
  FPagePicker.ItemIndex := 0;
  FPagePicker.OnChange := PagePickerChange;
  FFooter := TLayout.Create(Self);
  FFooter.Parent := FBody;
  FFooter.Align := TAlignLayout.Bottom;
  FFooter.Height := 96;
  FStatus := SettingsLabel(Self);
  FStatus.Parent := FFooter;
  FStatus.Align := TAlignLayout.Top;
  FStatus.Height := 48;
  FStatus.TextSettings.WordWrap := True;
  FApply := SettingsButton(Self);
  FApply.Parent := FFooter;
  FApply.Position.Y := 56;
  FApply.Width := 132;
  FApply.Height := 32;
  FApply.Text := Translate('Apply');
  FApply.StyleLookup := 'buttonstyle_accent';
  FApply.OnClick := ApplyClick;
  FBack := SettingsButton(Self);
  FBack.Parent := FFooter;
  FBack.Position.Point := TPointF.Create(144, 56);
  FBack.Width := 132;
  FBack.Height := 32;
  FBack.Text := Translate('Cancel');
  FBack.OnClick := BackClick;
  FReset := SettingsButton(Self);
  FReset.Parent := FFooter;
  FReset.Text := Translate('Reset section');
  FReset.Width := 160;
  FReset.Height := 40;
  FReset.OnClick := ResetClick;
  FRefresh := SettingsButton(Self);
  FRefresh.Parent := FFooter;
  FRefresh.Text := Translate('Refresh devices');
  FRefresh.OnClick := RefreshDevicesClick;
  FRefresh.Enabled := FInput <> nil;
  FCancelCapture := SettingsButton(Self);
  FCancelCapture.Parent := FFooter;
  FCancelCapture.Position.Point := TPointF.Create(288, 56);
  FCancelCapture.Width := 132;
  FCancelCapture.Height := 32;
  FCancelCapture.Text := Translate('Cancel input');
  FCancelCapture.OnClick := CancelCaptureClick;
  FCancelCapture.Visible := False;
  FScroll := TVertScrollBox.Create(Self);
  FScroll.Parent := FBody;
  FScroll.Align := TAlignLayout.Client;
  FScroll.ShowScrollBars := True;
  FScroll.ScrollAnimation := TBehaviorBoolean.True;
  FScroll.OnResize := ContentResize;
  BuildPage;
end;

destructor TSettingsView.Destroy;
begin
  FBuilding := True;
  if Assigned(FInvalidate) then
    FInvalidate();
  CancelCapture;
  FFields.Free;
  FDevices.Free;
  for var Ini in FDrafts do
    Ini.Free;
  inherited;
end;

procedure TSettingsView.Resize;
begin
  if FBuilding or (csDestroying in ComponentState) then
    Exit;

  inherited;
  if (FBody = nil) or FArranging then
    Exit;

  FArranging := True;
  try
    FSidebar.Visible := Width >= 900;
    FNavigation.Visible := FSidebar.Visible;
    FPagePicker.Visible := not FSidebar.Visible;
    FTitle.Text := Translate(SettingsCategoryNames[FCategory]);
    if FCategory = 0 then
      FTitle.Text := Translate('General settings');
    FCoreTabs.Visible := FCategory >= 2;
    for var i := 0 to High(FCategoryIcons) do
      if i = FCategory then
        TPath(FCategoryIcons[i]).Stroke.Color := $FFFFB344
      else
        TPath(FCategoryIcons[i]).Stroke.Color := $FFB9C2CC;
    FHeader.Height := 60 + IfThen(FCoreTabs.Visible, 48, 0) + IfThen(FPagePicker.Visible, 44, 0);
    FPagePicker.Align := TAlignLayout.None;
    FPagePicker.SetBounds(0, 48, FHeader.Width, 32);
    FCoreTabs.Align := TAlignLayout.None;
    FCoreTabs.SetBounds(0, FHeader.Height - 48, FHeader.Width, 40);
    FSearch.Visible := FHeader.Width >= 740;
    FSearch.SetBounds(Max(0, FHeader.Width - 260), 0, 260, 32);
    var X: Single := 0;
    for var i := 1 to 6 do
    begin
      FCoreButtons[i].Text := SettingsPageNames[i];
      case i of
        1:
          FCoreButtons[i].Text := 'GB';
        2:
          FCoreButtons[i].Text := 'GBC';
        3:
          FCoreButtons[i].Text := 'NES';
        5:
          FCoreButtons[i].Text := 'SNES';
      end;
      if FCoreTabs.Width < 600 then
        case i of
          4:
            FCoreButtons[i].Text := 'MD';
          6:
            FCoreButtons[i].Text := 'NG';
        end;
      var W := Max(48, Min(104, (FCoreTabs.Width - 35) / 6));
      FCoreButtons[i].SetBounds(X, 0, W, 36);
      X := X + W + 7;
      if i = FCorePage then
        FCoreButtons[i].StyleLookup := 'buttonstyle_accent'
      else
        FCoreButtons[i].StyleLookup := 'buttonstyle';
    end;
    if FContent = nil then
      Exit;

    FContent.Width := Min(1240, Max(0, FScroll.Width - 16));
    var Y: Single := 0;
    var LeftY: Single := 0;
    var Columns := (FCategory = 2) and (FPreviewGroup <> nil) and (FContent.Width >= 850);
    for var i := 0 to FContent.ChildrenCount - 1 do
      if FContent.Children[i] is TPanel then
      begin
        var C := TPanel(FContent.Children[i]);
        if not C.Visible then
          Continue;

        C.Width := FContent.Width;
        if Columns then
          if C = FPreviewGroup then
            C.Width := FContent.Width * 0.38 - 8
          else
            C.Width := FContent.Width * 0.62 - 8;
        ArrangeGroup(C);
        C.Position.X := 0;
        if Columns then
          if C = FPreviewGroup then
          begin
            C.Position.Point := TPointF.Create(FContent.Width * 0.62 + 8, 0);
            Y := Max(Y, C.Height);
          end
          else
          begin
            C.Position.Y := LeftY;
            LeftY := LeftY + C.Height + 16;
            Y := Max(Y, LeftY);
          end
        else
        begin
          C.Position.Y := Y;
          Y := Y + C.Height + 16;
        end;
      end;
    FContent.Height := Y;
    FApply.SetBounds(Max(0, FFooter.Width - 140), 52, 140, 40);
    FBack.SetBounds(Max(0, FFooter.Width - 260), 52, 108, 40);
    FReset.SetBounds(0, 52, 160, 40);
    FReset.Visible := FFooter.Width >= 520;
    FRefresh.SetBounds(176, 52, 176, 40);
    FRefresh.Visible := (FCategory = 3) and (FFooter.Width >= 700);
    FCancelCapture.SetBounds(Max(0, FFooter.Width - 150), 52, 150, 40);
    FApply.Visible := FCaptureButton = nil;
    FBack.Visible := FCaptureButton = nil;
  finally
    FArranging := False;
  end;
end;

procedure TSettingsView.ArrangeGroup(Group: TPanel);
begin
  var Y: Single := 14;
  if (FCategory = 3) and (Group.TagString = Translate('Controller')) and (Group.Width >= 850) then
  begin
    var Index := 0;
    Y := 132;
    for var i := 0 to Group.ChildrenCount - 1 do
      if (Group.Children[i] is TControl) and (Group.Children[i].Owner = FContent) then
      begin
        var C := TControl(Group.Children[i]);
        if C is TPanel then
        begin
          var P := TPanel(C);
          // Player, device and source occupy the first row. Special-device
          // options stay below them, with room for their descriptions.
          if Index < 3 then
          begin
            P.Tag := 2;
            P.Padding.Rect := TRectF.Empty;
            P.SetBounds(16 + Index * (Group.Width - 32) / 3, 56, (Group.Width - 56) / 3, 64);
            var Text := TLayout(TLabel(P.TagObject).Parent);
            Text.Align := TAlignLayout.None;
            Text.Margins.Rect := TRectF.Empty;
            Text.SetBounds(0, 0, P.Width, 24);
            TControl(Text.Children[1]).Visible := False;
            for var J := 0 to P.ChildrenCount - 1 do
              if (P.Children[J] is TControl) and (P.Children[J].Owner = FContent) then
              begin
                var Editor := TControl(P.Children[J]);
                Editor.Align := TAlignLayout.None;
                Editor.Margins.Rect := TRectF.Empty;
                var W := P.Width;
                if Editor is TSwitch then
                  W := 64;
                Editor.SetBounds(P.Width - W, 32, W, 32);
              end;
          end
          else
          begin
            P.Tag := 0;
            P.Width := Max(0, Group.Width - 32);
            RowResize(P);
            P.SetBounds(16, Y, P.Width, P.Height);
            if P.Visible then
              Y := Y + P.Height + 6;
          end;
          Inc(Index);
        end
        else
          C.SetBounds(16, 14, Group.Width - 32, 36);
      end;
    Group.Height := Y + 12;
    Exit;
  end;
  for var i := 0 to Group.ChildrenCount - 1 do
    if (Group.Children[i] is TControl) and (Group.Children[i].Owner = FContent) then
    begin
      var C := TControl(Group.Children[i]);
      C.Width := Max(0, Group.Width - 32);
      if C is TPanel then
      begin
        if C.Tag = 2 then
          C.Tag := 0;
        RowResize(C);
      end;
      if not C.Visible then
        Continue;
      C.SetBounds(16, Y, C.Width, C.Height);
      Y := Y + C.Height + 6;
    end;
  Group.Height := Y + 12;
end;

procedure TSettingsView.ContentResize(Sender: TObject);
begin
  Resize;
end;

procedure TSettingsView.EditorResize(Sender: TObject);
begin
  var C := TControl(Sender);
  if C.Height > 32 then
    C.Height := 32;
  if (C is TSwitch) and (C.Width > 64) then
    C.Width := 64;
end;

procedure TSettingsView.ComboResize(Sender: TObject);
begin
  EditorResize(Sender);
  var C := TComboBox(Sender);
  C.DisableMouseWheel := True;
  C.ItemHeight := C.Height;
  C.ListBox.ScrollAnimation := TBehaviorBoolean.True;
end;

procedure TSettingsView.RowResize(Sender: TObject);
begin
  var P := TPanel(Sender);
  if P.Tag in [1, 2] then
    Exit; // Device previews and the controller grid arrange themselves.

  P.Padding.Rect := TRectF.Create(16, 12, 16, 12);
  var Text := TLayout(TLabel(P.TagObject).Parent);
  Text.Align := TAlignLayout.None;
  Text.Margins.Rect := TRectF.Empty;
  if Text.ChildrenCount > 1 then
    TControl(Text.Children[1]).Visible := True;
  var Narrow := P.Width < 600;
  P.Height := IfThen(Narrow, 134, 72);
  var TextWidth := Max(0, P.Width - 32);
  // Explicit bounds keep editors centered without stretching them vertically.
  for var i := 0 to P.ChildrenCount - 1 do
    if (P.Children[i] is TControl) and (P.Children[i].Owner = FContent) then
    begin
      var C := TControl(P.Children[i]);
      var W: Single := 220;
      if C is TSwitch then
        W := 64
      else if C is TLayout then
        W := 268;
      if Narrow and not (C is TSwitch) then
        W := TextWidth;
      W := Min(W, Max(0, P.Width - 32));
      C.Align := TAlignLayout.None;
      C.Margins.Rect := TRectF.Empty;
      var Top := (P.Height - 32) / 2;
      if Narrow then
        Top := P.Height - 44;
      C.SetBounds(Max(16, P.Width - 16 - W), Top, W, 32);
      if not Narrow then
        TextWidth := Max(0, P.Width - 48 - W);
    end;
  Text.SetBounds(16, 12, TextWidth, IfThen(Narrow, 70, 48));
end;

function TSettingsView.Row(const Caption, Description: string): TPanel;
begin
  Result := TPanel.Create(FContent);
  Result.Parent := FGroup;
  Result.Align := TAlignLayout.None;
  Result.Height := 72;
  Result.TagString := Caption + ' ' + Description;
  Result.Width := FScroll.Width - 16;
  Result.Padding.Rect := TRectF.Create(16, 12, 16, 12);
  Result.StyleLookup := 'retromul_row';
  Result.OnResize := RowResize;
  FHeight := FHeight + Result.Height + 8;
  var Text := TLayout.Create(Result);
  Text.Parent := Result;
  Text.Align := TAlignLayout.Client;
  Text.Margins.Right := 16;
  var Title := SettingsLabel(Text);
  Title.Parent := Text;
  Title.Align := TAlignLayout.Top;
  Title.Height := 24;
  Title.Text := Caption;
  Title.StyledSettings := Title.StyledSettings - [TStyledSetting.Size];
  Title.TextSettings.Font.Size := 15;
  Result.TagObject := Title;
  var Detail := SettingsLabel(Text);
  Detail.Parent := Text;
  Detail.Align := TAlignLayout.Client;
  Detail.Text := Description;
  Detail.StyledSettings := Detail.StyledSettings - [TStyledSetting.Size];
  Detail.TextSettings.Font.Size := 14;
  Detail.Opacity := 0.72;
  Detail.TextSettings.WordWrap := True;
end;

function TSettingsView.Field(Control: TControl; const Section, Key: string): TSettingsField;
begin
  Result := TSettingsField.Create;
  Result.Control := Control;
  Result.Row := TPanel(Control.Parent);
  Result.Section := Section;
  Result.Key := Key;
  FFields.Add(Result);
  Control.Align := TAlignLayout.None;
  Control.OnResize := EditorResize;
  Control.SetBounds(16, 20, 220, 32);
end;

function TSettingsView.Combo(const Caption, Description, Section, Key: string; const Labels, Values: array of string; const Default: string): TComboBox;
begin
  Result := TSettingsComboBox.Create(FContent);
  Result.Parent := Row(Caption, Description);
  var F := Field(Result, Section, Key);
  F.DefaultValue := Default;
  Result.OnResize := ComboResize;
  ComboResize(Result);
  SetLength(F.Values, Length(Values));
  var Current := FDrafts[FPage].ReadString(Section, Key, Default);
  var Selected := 0;
  for var i := 0 to High(Labels) do
  begin
    Result.Items.Add(Labels[i]);
    F.Values[i] := Values[i];
    if SameText(Current, Values[i]) then
      Selected := i;
  end;
  Result.ItemIndex := Selected;
end;

function TSettingsView.Check(const Caption, Description, Section, Key: string; Default: Boolean): TSwitch;
begin
  Result := TSwitch.Create(FContent);
  Result.Parent := Row(Caption, Description);
  Field(Result, Section, Key).DefaultValue := IntToStr(Ord(Default));
  Result.Width := 64;
  Result.IsChecked := FDrafts[FPage].ReadBool(Section, Key, Default);
end;

function TSettingsView.Number(const Caption, Description, Section, Key: string; Default, Max: Integer): TSpinBox;
begin
  Result := TSettingsSpinBox.Create(FContent);
  Result.Parent := Row(Caption, Description);
  Field(Result, Section, Key).DefaultValue := IntToStr(Default);
  Result.Min := 0;
  Result.Max := Max;
  Result.ValueType := TNumValueType.Integer;
  Result.Value := EnsureRange(FDrafts[FPage].ReadInteger(Section, Key, Default), 0, Max);
end;

function TSettingsView.EditText(const Caption, Description, Section, Key, Default: string): TEdit;
begin
  Result := TEdit.Create(FContent);
  Result.Parent := Row(Caption, Description);
  Field(Result, Section, Key).DefaultValue := Default;
  Result.Text := FDrafts[FPage].ReadString(Section, Key, Default);
end;

function TSettingsView.PathEdit(const Caption, Description, Section, Key, Default: string; Folder: Boolean): TEdit;
begin
  Result := EditText(Caption, Description, Section, Key, Default);
  {$IFDEF ANDROID}
  Result.ReadOnly := True;
  {$ENDIF}
  var Browse := TEditButton.Create(Result);
  Browse.Parent := Result;
  Browse.Hint := Translate('Browse');
  AddButtonIcon(Browse, IconMore, 16);
  Browse.Width := 32;
  Browse.Hint := Translate('Choose file');
  if Folder then
    Browse.Hint := Translate('Choose folder');
  Browse.Tag := Ord(Folder);
  Browse.TagObject := Result;
  Browse.OnClick := PathClick;
end;

procedure TSettingsView.VolumeChange(Sender: TObject);
begin
  if FVolumeValue <> nil then
    FVolumeValue.Text := IntToStr(Round(TTrackBar(Sender).Value)) + '%';
end;

procedure TSettingsView.Heading(const Caption: string);
begin
  FGroup := TPanel.Create(FContent);
  FGroup.Parent := FContent;
  FGroup.StyleLookup := 'retromul_card';
  FGroup.Width := FScroll.Width - 16;
  FGroup.TagString := Caption;
  var L := SettingsLabel(FContent);
  L.Parent := FGroup;
  L.Height := 36;
  L.Text := Caption;
  L.StyledSettings := L.StyledSettings - [TStyledSetting.Size, TStyledSetting.Style];
  L.TextSettings.Font.Size := 20;
  L.TextSettings.Font.Style := [TFontStyle.fsBold];
end;

procedure TSettingsView.AutosaveToggle(Sender: TObject);
begin
  if FAutosaveMinutes <> nil then
    FAutosaveMinutes.Enabled := TSwitch(Sender).IsChecked;
end;

procedure TSettingsView.StorePage;
begin
  for var F in FFields do
  begin
    if F.Control is TComboBox then
    begin
      var Index := TComboBox(F.Control).ItemIndex;
      if (Index >= 0) and (Index < Length(F.Values)) then
        FDrafts[FPage].WriteString(F.Section, F.Key, F.Values[Index]);
    end
    else if F.Control is TSwitch then
      FDrafts[FPage].WriteBool(F.Section, F.Key, TSwitch(F.Control).IsChecked)
    else if F.Control is TSpinBox then
      FDrafts[FPage].WriteInteger(F.Section, F.Key, Round(TSpinBox(F.Control).Value))
    else if F.Control is TTrackBar then
      FDrafts[FPage].WriteFloat(F.Section, F.Key, TTrackBar(F.Control).Value / 100)
    else if F.Control is TEdit then
      FDrafts[FPage].WriteString(F.Section, F.Key, TEdit(F.Control).Text.Trim);
  end;
  if (FPage > 0) and (FInput <> nil) then
    SaveInputBindings(FInput, FDrafts[FPage]);
end;

procedure TSettingsView.BuildPage(PreserveScroll: Boolean);
begin
  var Position := FScroll.ViewportPosition;
  FBuilding := True;
  FScroll.BeginUpdate;
  try
    CancelCapture;
    FFolderEdit := nil;
    FAutosaveMinutes := nil;
    FVolumeValue := nil;
    FPreview := nil;
    FPreviewGroup := nil;
    FDevices.Clear;
    FFields.Clear;
    FreeAndNil(FContent);
    FContent := TLayout.Create(Self);
    FContent.Parent := FScroll;
    FContent.Width := Min(1240, Max(0, FScroll.Width - 16));
    FGroup := nil;
    FHeight := 0;
    FStatus.Text := Translate('Click Apply to save changes.');
    if FCategory = 0 then
    begin
      Heading(Translate('Appearance'));
      Combo(Translate('Language'), Translate('Detected on first launch. Your selection is saved.'),
        'General', 'Language', ['English', 'Русский', 'Português'], ['en', 'ru', 'pt'], 'en');
      var Theme := Row(Translate('Theme'), Translate('RetroMul dark theme with an amber accent.'));
      var Value := SettingsLabel(FContent);
      Value.Parent := Theme;
      Value.Align := TAlignLayout.Right;
      Value.Width := 220;
      Value.Text := Translate('Dark · RetroMul');
      Heading(Translate('During gameplay'));
      Check(Translate('Pause when focus is lost'), Translate('When switching to another application.'), 'General', 'PauseOnFocusLoss', True);
      Check(Translate('Start in full screen'), Translate('Open games in full screen.'), 'General', 'StartFullscreen', False);
      Heading(Translate('Autosave'));
      var ExitSave := Check(Translate('Autosave on exit'), Translate('Save when closing a game or the application.'),
        'General', 'AutosaveOnExit', True);
      ExitSave.Name := 'AutosaveOnExit';
      var Periodic := Check(Translate('Autosave every N minutes'), Translate('Overwrite the autosave slot at the selected interval.'),
        'General', 'AutosavePeriodic', False);
      Periodic.Name := 'AutosavePeriodic';
      FAutosaveMinutes := TSettingsSpinBox.Create(FContent);
      FAutosaveMinutes.Parent := Periodic.Parent;
      FAutosaveMinutes.Name := 'AutosaveMinutes';
      Field(FAutosaveMinutes, 'General', 'AutosaveMinutes').DefaultValue := IntToStr(AUTOSAVE_DEFAULT_MINUTES);
      FAutosaveMinutes.Min := 1;
      FAutosaveMinutes.Max := AUTOSAVE_MAX_MINUTES;
      FAutosaveMinutes.ValueType := TNumValueType.Integer;
      FAutosaveMinutes.Value := EnsureRange(FDrafts[0].ReadInteger('General', 'AutosaveMinutes',
        AUTOSAVE_DEFAULT_MINUTES), 1, AUTOSAVE_MAX_MINUTES);
      var IntervalEditor := TLayout.Create(FContent);
      IntervalEditor.Parent := Periodic.Parent;
      Periodic.Parent := IntervalEditor;
      Periodic.Align := TAlignLayout.Right;
      Periodic.Width := 64;
      FAutosaveMinutes.Parent := IntervalEditor;
      FAutosaveMinutes.Align := TAlignLayout.Client;
      FAutosaveMinutes.Margins.Right := 12;
      FAutosaveMinutes.Enabled := Periodic.IsChecked;
      Periodic.OnSwitch := AutosaveToggle;
      Heading(Translate('On-screen buttons'));
      Number(Translate('Bottom inset'), Translate('Distance from the bottom edge. The safe area is included automatically.'),
        'General', 'ControlBottomInset', 100, 400);
    end
    else if FCategory = 1 then
    begin
      Heading(Translate('Game library'));
      FFolderEdit := PathEdit(Translate('ROM folder'), Translate('Subfolders: nes, snes, gb, gbc, megadrive, neogeo.'),
        'General', 'Path', FStorage.RomFolder, True);
      Combo(Translate('Library view'), Translate('Cover grid or compact list.'), 'Library', 'View',
        [Translate('Covers'), Translate('List')], ['grid', 'list'], 'grid');
      Combo(Translate('Card size'), Translate('The number of covers per row adapts to the window.'), 'Library', 'CardWidth',
        [Translate('Compact'), Translate('Normal'), Translate('Large')], ['140', '170', '220'], '170');
      Check(Translate('Show platform on cards'), Translate('Console name below each game cover.'), 'Library', 'ShowPlatform', True);
      Heading(Translate('Metadata'));
      Row(Translate('Covers and descriptions'), Translate('Loaded from gamelist.xml next to the ROMs. Favorites are stored separately and do not change the XML.'));
    end
    else
    begin
      if FInput <> nil then
        LoadInputBindings(FInput, FDrafts[FPage], SettingsCoreIds[FPage]);
      if FCategory = 2 then
      begin
        Heading(Translate('Video'));
        Combo(Translate('Image scaling'), Translate('Nearest neighbor preserves sharp pixels; smoothing softens the image.'),
          'Video', 'Filter', [Translate('Nearest neighbor'), Translate('Smoothing')], ['nearest', 'linear'], 'nearest');
        if FPage = 1 then
        begin
          var Labels, Values: TArray<string>;
          SetLength(Labels, SCREEN_PALETTE_COUNT);
          SetLength(Values, SCREEN_PALETTE_COUNT);
          for var i := 0 to SCREEN_PALETTE_COUNT - 1 do
          begin
            Labels[i] := ScreenPalettes[i].Name;
            Values[i] := IntToStr(i);
          end;
          var Palette := Combo(Translate('Game Boy palette'), Translate('Colors of the monochrome display.'), 'Video', 'Palette', Labels, Values, '0');
          Palette.OnChange := PreviewChange;
          Heading(Translate('Preview'));
          FPreviewGroup := FGroup;
          var PreviewRow := Row('160 × 144', Translate('Example using the selected palette.'));
          PreviewRow.Tag := 1;
          PreviewRow.Padding.Rect := TRectF.Empty;
          PreviewRow.Height := 350;
          TLayout(TLabel(PreviewRow.TagObject).Parent).Visible := False;
          var Preview := TSettingsPreview.Create(PreviewRow);
          FPreview := Preview;
          Preview.Parent := PreviewRow;
          Preview.SetBounds(0, 0, 320, 288);
          Preview.Align := TAlignLayout.Fit;
          Preview.Margins.Rect := TRectF.Create(0, 10, 0, 10);
          Preview.PaletteIndex := Palette.ItemIndex;
        end;
        if FPage = 2 then
          Check(Translate('LCD colors'), Translate('Approximate Game Boy Color color reproduction.'), 'Video', 'ColorCorrection', False);
        if FPage = 3 then
          Combo(Translate('NES region'), Translate('Frame rate and timing based on the ROM.'), 'Video', 'Region',
            [Translate('Automatic'), 'NTSC', 'PAL'], ['Auto', 'NTSC', 'PAL'], 'Auto');
        if FPage = 5 then
          Check(Translate('Crop overscan'), Translate('Show the central 224 lines instead of 239.'), 'Video', 'CropOverscan', False);
        Heading(Translate('Audio'));
        Check(Translate('Audio'), Translate('Audio playback for the selected platform.'), 'Audio', 'Enabled', True);
        var Volume := TSettingsTrackBar.Create(FContent);
        Volume.Parent := Row(Translate('Volume'), Translate('Audio level for the selected platform.'));
        Field(Volume, 'Audio', 'Volume').DefaultValue := '0.5';
        var Editor := TLayout.Create(FContent);
        Editor.Parent := Volume.Parent;
        Editor.Align := TAlignLayout.None;
        Editor.Width := 268;
        Editor.Height := 32;
        Volume.Parent := Editor;
        Volume.Align := TAlignLayout.Client;
        Volume.Margins.Rect := TRectF.Empty;
        FVolumeValue := SettingsLabel(Editor);
        FVolumeValue.Parent := Editor;
        FVolumeValue.Align := TAlignLayout.Right;
        FVolumeValue.Width := 52;
        FVolumeValue.Margins.Left := 8;
        FVolumeValue.TextSettings.HorzAlign := TTextAlign.Trailing;
        Volume.Min := 0;
        Volume.Max := 100;
        Volume.Value := EnsureRange(FDrafts[FPage].ReadFloat('Audio', 'Volume', 0.5), 0, 1) * 100;
        Volume.OnChange := VolumeChange;
        VolumeChange(Volume);
      end
      else if FCategory = 3 then
      begin
        Heading(Translate('Controller'));
        var Count := 2;
        if FPage <= 2 then
          Count := 1;
        if (FPage = 3) and FDrafts[FPage].ReadBool('Input', 'FourScore', False) then
          Count := 4;
        if (FPage = 5) and FDrafts[FPage].ReadBool('Input', 'Multitap2', False) then
          Count := 5;
        if (FPage = 5) and FDrafts[FPage].ReadBool('Input', 'Multitap1', False) then
          Count := 8;
        FPlayer := EnsureRange(FPlayer, 0, Count - 1);
        var Player := TSettingsComboBox.Create(FContent);
        Player.Parent := Row(Translate('Player'), Translate('Bindings are saved separately for each player.'));
        Player.Align := TAlignLayout.None;
        Player.SetBounds(16, 20, 220, 32);
        for var i := 1 to Count do
          Player.Items.Add(Translate('Player ') + IntToStr(i));
        Player.ItemIndex := FPlayer;
        Player.OnChange := PlayerChange;
        Player.OnResize := ComboResize;
        ComboResize(Player);
        BuildPort(FPlayer, Translate('Bindings · player ') + IntToStr(FPlayer + 1));
      end
      else
      begin
        if FPage = 3 then
        begin
          Heading(Translate('Additional players'));
          var FourScore := Check('Four Score', Translate('Extra controllers for players 3 and 4; incompatible with Zapper, Power Pad and Miracle Piano.'),
            'Input', 'FourScore', False);
          FourScore.OnSwitch := PortChange;
        end;
        if FPage = 5 then
        begin
          Heading(Translate('Additional players'));
          var Multi := Check(Translate('Multitap · port 2'), Translate('Controllers for players 2–5.'), 'Input', 'Multitap2', False);
          Multi.OnSwitch := PortChange;
          Multi := Check(Translate('Multitap · port 1'), Translate('Players 1, 6, 7 and 8.'), 'Input', 'Multitap1', False);
          Multi.OnSwitch := PortChange;
        end;
        BuildPort(0, Translate('Port 1'));
        if FPage > 2 then
          BuildPort(1, Translate('Port 2'));
        if FPage = 3 then
        begin
          Heading(Translate('Famicom expansion port'));
          var Expansion := Combo(Translate('Connected device'), Translate('Automatic uses the ROM metadata.'), 'Ports', 'Expansion',
            [Translate('Automatic'), Translate('None'), Translate('Subor keyboard'), Translate('Famicom keyboard'), 'Data Recorder'],
            ['auto', 'none', 'subor', 'famicom', 'recorder'], 'auto');
          Expansion.OnChange := PortChange;
          var Device := FDrafts[FPage].ReadString('Ports', 'Expansion', 'auto');
          if (Device = 'subor') or (Device = 'famicom') then
          begin
            Check(Translate('Physical keyboard'), Translate('An on-screen keyboard is available during gameplay.'), 'Ports', 'KeyboardEnabled', True);
            BuildBindings(4, Device);
          end;
          if (Device = 'recorder') or (Device = 'famicom') then
            PathEdit(Translate('Initial cassette'),
              Translate('Leave blank to use the current game''s cassette.'), 'Ports', 'TapeFile', '', False);
        end;
      end;
      FStatus.Text := Translate('Settings are saved separately for each platform. Core options apply when you next open a ROM.');
    end;
  finally
    FBuilding := False;
    FScroll.EndUpdate;
    Resize;
    if PreserveScroll then
      FScroll.ViewportPosition := TPointF.Create(0, EnsureRange(Position.Y, 0,
          Max(0, FScroll.ContentBounds.Height - FScroll.ClientHeight)))
    else
      FScroll.ViewportPosition := TPointF.Zero;
    SearchChange(FSearch);
  end;
end;

procedure TSettingsView.BuildPort(Port: Integer; const Caption: string);
begin
  if FCategory <> 3 then
    Heading(Caption);
  var Key := 'Port' + IntToStr(Port + 1);
  var Device := FDrafts[FPage].ReadString('Ports', Key, 'auto');
  var C: TComboBox;
  if FPage <= 2 then
    C := Combo(Translate('Controller'), Translate('Use the console''s built-in buttons.'), 'Ports', Key,
      [Translate('Gamepad'), Translate('None')], ['pad', 'none'], 'pad')
  else if FPage = 4 then
    C := Combo(Translate('Connected device'), Translate('Controller protocol for this port.'), 'Ports', Key,
      [Translate('Gamepad · 6 buttons'), Translate('Gamepad · 3 buttons'), Translate('None')], ['pad6', 'pad3', 'none'], 'pad6')
  else if (FPage = 3) and (Port = 0) then
    C := Combo(Translate('Connected device'), Translate('Automatic keeps the device selected by the ROM.'), 'Ports', Key,
      [Translate('Automatic'), Translate('Gamepad'), 'Miracle Piano', Translate('None')], ['auto', 'pad', 'piano', 'none'], 'auto')
  else if (FPage = 3) and (Port = 1) then
    C := Combo(Translate('Connected device'), Translate('Zapper and Power Pad use the second port.'), 'Ports', Key,
      [Translate('Automatic'), Translate('Gamepad'), 'Zapper', 'Power Pad', Translate('None')],
      ['auto', 'pad', 'zapper', 'powerpad', 'none'], 'auto')
  else
    C := Combo(Translate('Connected device'), Translate('Controller connected to this port.'), 'Ports', Key,
      [Translate('Gamepad'), Translate('None')], ['pad', 'none'], 'pad');
  // Normalize absent legacy values to the device displayed by the selector.
  for var F in FFields do
    if F.Control = C then
      Device := F.Values[C.ItemIndex];
  C.OnChange := PortChange;
  if FCategory = 3 then
    BuildBindings(Port, Device);
end;

procedure TSettingsView.BuildBindings(Port: Integer; const Device: string);
begin
  if Device = 'none' then
    Exit;
  var Labels, Values: TArray<string>;
  var Devices: TArray<TInputDevice>;
  if FInput <> nil then
    Devices := FInput.Devices;
  SetLength(Labels, Length(Devices) + 1);
  SetLength(Values, Length(Labels));
  Labels[0] := Translate('All devices');
  Values[0] := '';
  for var i := 0 to High(Devices) do
  begin
    Labels[i + 1] := Devices[i].Name;
    if Devices[i].Id = SystemKeyboardId then
      Labels[i + 1] := Translate('Keyboard')
    else if Devices[i].Id = SystemMouseId then
      Labels[i + 1] := Translate('Mouse');
    Values[i + 1] := Devices[i].Id;
  end;
  var SourceKey := 'Source' + IntToStr(Port + 1);
  if (FPage = 3) and (Port = 4) then
    SourceKey := 'SourceExpansion';
  var SavedId := FDrafts[FPage].ReadString('Ports', SourceKey, '');
  var Found := SavedId = '';
  for var Id in Values do
    if Id = SavedId then
      Found := True;
  if not Found then
  begin
    var N := Length(Labels);
    SetLength(Labels, N + 1);
    SetLength(Values, N + 1);
    Labels[N] := Translate('Disconnected device');
    Values[N] := SavedId;
  end;
  var Source := Combo(Translate('Input source'), Translate('Choose a device, then assign its buttons, axes or D-pad.'),
    'Ports', SourceKey, Labels, Values, '');
  FDeviceIds[Port] := SavedId;
  Source.Tag := Port;
  Source.OnChange := DeviceChange;
  Source.Enabled := FInput <> nil;
  if (Device = 'piano') then
  begin
    Check(Translate('Physical keyboard'), Translate('Notes Z–M and Q–P; Space is the pedal. An on-screen piano is also available.'),
      'Ports', 'KeyboardEnabled', True);
  end;
  if Device = 'zapper' then
    AddBinding(Translate('Zapper trigger'), ZapperTriggerAction, Port)
  else
    BuildDevice(Port, Device);
end;

function TSettingsView.AddBinding(const Caption: string; Action, Port: Integer): TButton;
begin
  var P := Row(Caption, Translate('Click Assign, then press a button or direction on the device.'));
  var Editors := TLayout.Create(FContent);
  Editors.Parent := P;
  Editors.Align := TAlignLayout.Right;
  Editors.Width := 268;
  Editors.Height := 32;
  Editors.Margins.Top := 16;
  Editors.Margins.Bottom := 16;
  var B := SettingsButton(Editors);
  B.Parent := Editors;
  B.Align := TAlignLayout.Client;
  B.Text := Translate('Assign · ') + BindingCaption(FInput, Action);
  B.Tag := Action;
  B.TagString := IntToStr(Port);
  B.TagObject := P.TagObject;
  B.OnClick := CaptureClick;
  B.Enabled := FInput <> nil;
  var Clear := SettingsButton(Editors);
  Clear.Parent := Editors;
  Clear.Align := TAlignLayout.Right;
  Clear.Width := 36;
  Clear.Margins.Left := 8;
  AddButtonIcon(Clear, IconClose, 14);
  Clear.Hint := Translate('Remove binding');
  Clear.ShowHint := True;
  Clear.Tag := Action;
  Clear.OnClick := ClearBindingClick;
  Clear.Enabled := FInput <> nil;
  Result := B;
end;

procedure TSettingsView.BuildDevice(Port: Integer; const Device: string);
begin
  Heading(Translate('Bindings'));
  var D := TSettingsDevice.Create;
  FDevices.Add(D);
  D.Port := Port;
  D.Device := Device;
  var P := Row(Translate('Button bindings'), Translate('Select a button on the diagram, then press a key or controller button.'));
  P.Tag := 1;
  P.Height := 340;
  var Text := TLayout(TLabel(P.TagObject).Parent);
  Text.Align := TAlignLayout.Top;
  Text.Height := 34;
  TControl(Text.Children[1]).Visible := False;
  if Device = 'powerpad' then
  begin
    var Pad := TNesPowerPad.Create(P);
    Pad.OnChange := VirtualDeviceChange;
    D.Control := Pad;
    var Diagram := TDeviceCallouts.Create(P);
    Diagram.Configure(Pad, FInput, ROM_SYSTEM_NES, Port, CalloutClick);
    D.Diagram := Diagram;
    P.Height := 448;
  end
  else if Device = 'subor' then
  begin
    var Keyboard := TNesSuborKeyboard.Create(P);
    Keyboard.OnChange := VirtualDeviceChange;
    D.Control := Keyboard;
  end
  else if Device = 'famicom' then
  begin
    var Keyboard := TNesFamicomKeyboard.Create(P);
    Keyboard.OnChange := VirtualDeviceChange;
    D.Control := Keyboard;
  end
  else if Device = 'piano' then
  begin
    var Piano := TNesMiraclePiano.Create(P);
    Piano.OnChange := VirtualDeviceChange;
    D.Control := Piano;
  end
  else
  begin
    var Pad := TScreenGamepad.Create(P);
    case FPage of
      1:
        Pad.Layout := TScreenGamepadLayout.GameBoy;
      2:
        Pad.Layout := TScreenGamepadLayout.GameBoyColor;
      3:
        Pad.Layout := TScreenGamepadLayout.Nes;
      4:
        Pad.Layout := TScreenGamepadLayout.Sega;
      5:
        Pad.Layout := TScreenGamepadLayout.Snes;
      6:
        Pad.Layout := TScreenGamepadLayout.NeoGeo;
    end;
    Pad.ButtonMask := CoreButtons(SettingsCoreIds[FPage], Device);
    Pad.OnChange := VirtualDeviceChange;
    D.Control := Pad;
    var Diagram := TDeviceCallouts.Create(P);
    Diagram.Configure(Pad, FInput, SettingsCoreIds[FPage], Port, CalloutClick);
    D.Diagram := Diagram;
    P.Height := 460;
  end;
  var Preview := D.Control;
  if D.Diagram <> nil then
    Preview := D.Diagram;
  if D.Control is TScreenGamepad then
  begin
    D.Assignments := TVertScrollBox.Create(P);
    D.Assignments.ScrollAnimation := TBehaviorBoolean.True;
    D.Assignments.Parent := P;
    D.Assignments.Align := TAlignLayout.Right;
    D.Assignments.Width := 300;
    D.Assignments.Margins.Left := 20;
    D.Assignments.ShowScrollBars := True;
    D.AssignmentList := TLayout.Create(P);
    D.AssignmentList.Parent := D.Assignments;
    D.AssignmentList.Width := 284;
    var Y: Single := 8;
    for var B in TScreenGamepad(D.Control).ButtonMask do
    begin
      var Binding := SettingsButton(P);
      Binding.Parent := D.AssignmentList;
      Binding.SetBounds(8, Y, D.AssignmentList.Width - 16, 32);
      Binding.Tag := PadAction(Port, B);
      Binding.TagObject := D;
      Binding.TagString := CoreButtonName(SettingsCoreIds[FPage], B);
      Binding.Text := Binding.TagString + '   ·   ' + BindingCaption(FInput, Binding.Tag);
      Binding.OnClick := AssignmentClick;
      Binding.Enabled := FInput <> nil;
      Y := Y + 40;
    end;
    D.AssignmentList.Height := Y;
  end;
  Preview.Parent := P;
  Preview.Align := TAlignLayout.Client;
  Preview.Margins.Top := 8;
  Preview.Margins.Bottom := 8;
  D.Control.Tag := Port;
  // Keep the editor inside this card. No button is selected until the user clicks.
  var Footer := TLayout.Create(P);
  Footer.Parent := P;
  Footer.Align := TAlignLayout.Bottom;
  Footer.Height := 60;
  D.Caption := SettingsLabel(Footer);
  D.Caption.Parent := Footer;
  D.Caption.Align := TAlignLayout.Top;
  D.Caption.Height := 24;
  D.Caption.Text := '';
  var Editors := TLayout.Create(Footer);
  Editors.Parent := Footer;
  Editors.Align := TAlignLayout.Bottom;
  Editors.Height := 32;
  D.Capture := SettingsButton(Editors);
  D.Capture.Parent := Editors;
  D.Capture.Align := TAlignLayout.Client;
  D.Capture.Width := 220;
  D.Capture.Text := Translate('Assign');
  D.Capture.Tag := -1;
  D.Capture.TagString := IntToStr(Port);
  D.Capture.TagObject := D.Caption;
  D.Capture.OnClick := CaptureClick;
  D.Capture.Enabled := FInput <> nil;
  D.Capture.Visible := False;
  D.Clear := SettingsButton(Editors);
  D.Clear.Parent := Editors;
  D.Clear.Align := TAlignLayout.Right;
  D.Clear.Width := 36;
  D.Clear.Margins.Left := 8;
  AddButtonIcon(D.Clear, IconClose, 14);
  D.Clear.Hint := Translate('Remove binding');
  D.Clear.ShowHint := True;
  D.Clear.Tag := -1;
  D.Clear.OnClick := ClearBindingClick;
  D.Clear.Enabled := FInput <> nil;
  D.Clear.Visible := False;
  Footer.OnResize := BindingFooterResize;
  BindingFooterResize(Footer);
  P.OnResize := DeviceResize;
  DeviceResize(P);
end;

procedure TSettingsView.DeviceResize(Sender: TObject);
begin
  var P := TPanel(Sender);
  for var D in FDevices do
    if (D.Assignments <> nil) and (D.Assignments.Parent = P) then
    begin
      D.Assignments.Visible := P.Width >= 850;
      if D.Diagram is TDeviceCallouts then
        TDeviceCallouts(D.Diagram).ShowAnnotations(not D.Assignments.Visible);
    end;
end;

procedure TSettingsView.AssignmentClick(Sender: TObject);
begin
  var B := TButton(Sender);
  SelectBinding(TSettingsDevice(B.TagObject), B.Tag, Translate('Button ') + B.TagString);
end;

procedure TSettingsView.BindingFooterResize(Sender: TObject);
begin
  var Footer := TLayout(Sender);
  var Caption := TLabel(Footer.Children[0]);
  var Editors := TLayout(Footer.Children[1]);
  if Footer.Width < 600 then
  begin
    Caption.Align := TAlignLayout.Top;
    Caption.Height := 24;
    Editors.Align := TAlignLayout.Bottom;
    Editors.Height := 32;
    Editors.Margins.Top := 0;
    Editors.Margins.Bottom := 0;
  end
  else
  begin
    Caption.Align := TAlignLayout.Client;
    Editors.Align := TAlignLayout.Right;
    Editors.Width := 268;
    Editors.Margins.Top := 14;
    Editors.Margins.Bottom := 14;
  end;
end;

procedure TSettingsView.SelectBinding(Device: TSettingsDevice; Action: Integer; const Caption: string);
begin
  CancelCapture;
  Device.Capture.Tag := Action;
  Device.Clear.Tag := Action;
  Device.Caption.Text := Caption;
  Device.Capture.Text := Translate('Assign · ') + BindingCaption(FInput, Action);
  Device.Capture.Visible := True;
  Device.Clear.Visible := True;
  CaptureClick(Device.Capture);
end;

procedure TSettingsView.CalloutClick(Sender: TObject);
begin
  if FBuilding or (FInput = nil) then
    Exit;
  var LabelControl := TLabel(Sender);
  for var D in FDevices do
    if D.Diagram = LabelControl.Parent then
    begin
      SelectBinding(D, LabelControl.Tag, LabelControl.TagString);
      Exit;
    end;
end;

procedure TSettingsView.RefreshBindings;
begin
  for var D in FDevices do
  begin
    if D.Diagram is TDeviceCallouts then
      TDeviceCallouts(D.Diagram).Refresh;
    if D.AssignmentList <> nil then
      for var i := 0 to D.AssignmentList.ChildrenCount - 1 do
        if D.AssignmentList.Children[i] is TButton then
        begin
          var B := TButton(D.AssignmentList.Children[i]);
          B.Text := B.TagString + '   ·   ' + BindingCaption(FInput, B.Tag);
        end;
    if (D.Capture.Tag >= 0) and (D.Capture <> FCaptureButton) then
      D.Capture.Text := Translate('Assign · ') + BindingCaption(FInput, D.Capture.Tag);
  end;
end;

procedure TSettingsView.VirtualDeviceChange(Sender: TObject);
const
  Mapping: array[TNesButton] of TEmulatorButton = (TEmulatorButton.A,
    TEmulatorButton.B, TEmulatorButton.Select, TEmulatorButton.Start,
    TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left, TEmulatorButton.Right);
  Notes: array[0..11] of string = ('C', 'C♯', 'D', 'D♯', 'E', 'F', 'F♯', 'G', 'G♯', 'A', 'A♯', 'B');
begin
  if FBuilding or (FInput = nil) then
    Exit;
  for var D in FDevices do
    if D.Control = Sender then
    begin
      var Action := -1;
      var Caption := '';
      if Sender is TScreenGamepad then
        for var B in TScreenGamepad(Sender).Buttons do
          if B in CoreButtons(SettingsCoreIds[FPage], D.Device) then
          begin
            Action := PadAction(D.Port, B);
            Caption := Translate('Button ') + CoreButtonName(SettingsCoreIds[FPage], B);
            Break;
          end;
      if Sender is TNesPowerPad then
        for var B in TNesPowerPad(Sender).Buttons do
        begin
          Action := PowerPadAction + B - 1;
          Caption := Translate('Pad ') + IntToStr(B);
          Break;
        end;
      if Sender is TNesSuborKeyboard then
        for var K in TNesSuborKeyboard(Sender).Keys do
        begin
          Action := SuborAction + Ord(K);
          Caption := Translate('Key ') + Copy(GetEnumName(TypeInfo(TSuborKey), Ord(K)), 3, MaxInt);
          Break;
        end;
      if Sender is TNesFamicomKeyboard then
        for var K in TNesFamicomKeyboard(Sender).Keys do
        begin
          Action := FamicomAction + Ord(K);
          Caption := Translate('Key ') + Copy(GetEnumName(TypeInfo(TFamicomKey), Ord(K)), 3, MaxInt);
          Break;
        end;
      if Sender is TNesMiraclePiano then
      begin
        for var K in TNesMiraclePiano(Sender).Keys do
        begin
          Action := PianoAction + K;
          if K < 49 then
            Caption := Translate('Note ') + Notes[K mod 12] + IntToStr(2 + K div 12)
          else
            Caption := Translate('Piano button ') + IntToStr(K);
          Break;
        end;
        if Action < 0 then
          for var B in TNesMiraclePiano(Sender).Buttons do
          begin
            Action := PadAction(0, Mapping[B]);
            Caption := Translate('Button ') + CoreButtonName(ROM_SYSTEM_NES, Mapping[B]);
            Break;
          end;
      end;
      if Action < 0 then
        Exit;
      SelectBinding(D, Action, Caption);
      Exit;
    end;
end;

procedure TSettingsView.DeviceChange(Sender: TObject);
begin
  if FBuilding then
    Exit;
  var C := TComboBox(Sender);
  for var F in FFields do
    if F.Control = C then
      FDeviceIds[C.Tag] := F.Values[C.ItemIndex];
end;

procedure TSettingsView.RefreshDevicesClick(Sender: TObject);
begin
  CancelCapture;
  StorePage;
  FInput.Refresh;
  RequestRebuild;
end;

procedure TSettingsView.NavigationChange(Sender: TObject);
begin
  // TListBox.OnChange passes the selected item as Sender.
  SelectCategory(FNavigation.ItemIndex);
end;

procedure TSettingsView.PagePickerChange(Sender: TObject);
begin
  SelectCategory(FPagePicker.ItemIndex);
end;

procedure TSettingsView.SelectCategory(Index: Integer);
begin
  if FBuilding or (Index < 0) or (Index > High(SettingsCategoryNames)) or (Index = FCategory) then
    Exit;

  StorePage;
  FCategory := Index;
  if Index < 2 then
    FPage := 0
  else
    FPage := FCorePage;
  FBuilding := True;
  try
    FNavigation.ItemIndex := Index;
    FPagePicker.ItemIndex := Index;
  finally
    FBuilding := False;
  end;
  FSearch.Text := '';
  BuildPage;
end;

procedure TSettingsView.SelectCore(Index: Integer);
begin
  if FBuilding or (Index < 1) or (Index > High(SettingsCoreIds)) then
    Exit;

  StorePage;
  FCorePage := Index;
  FPlayer := 0;
  if FCategory < 2 then
    FCategory := 2;
  FPage := FCorePage;
  FBuilding := True;
  try
    FNavigation.ItemIndex := FCategory;
    FPagePicker.ItemIndex := FCategory;
  finally
    FBuilding := False;
  end;
  BuildPage;
end;

procedure TSettingsView.CoreClick(Sender: TObject);
begin
  SelectCore(TButton(Sender).Tag);
end;

procedure TSettingsView.SearchChange(Sender: TObject);
begin
  if FBuilding or (FContent = nil) then
    Exit;

  var Query := FSearch.Text.Trim.ToLower;
  for var i := 0 to FContent.ChildrenCount - 1 do
    if FContent.Children[i] is TPanel then
    begin
      var Group := TPanel(FContent.Children[i]);
      var ShowGroup := Query = '';
      for var J := 0 to Group.ChildrenCount - 1 do
        if Group.Children[J] is TPanel then
        begin
          var Row := TPanel(Group.Children[J]);
          Row.Visible := (Query = '') or Row.TagString.ToLower.Contains(Query) or Group.TagString.ToLower.Contains(Query);
          ShowGroup := ShowGroup or Row.Visible;
        end;
      Group.Visible := ShowGroup;
    end;
  Resize;
end;

procedure TSettingsView.PlayerChange(Sender: TObject);
begin
  if FBuilding then
    Exit;

  StorePage;
  FPlayer := TComboBox(Sender).ItemIndex;
  RequestRebuild;
end;

procedure TSettingsView.PreviewChange(Sender: TObject);
begin
  if FPreview is TSettingsPreview then
  begin
    TSettingsPreview(FPreview).PaletteIndex := TComboBox(Sender).ItemIndex;
    FPreview.Repaint;
  end;
end;

procedure TSettingsView.ResetClick(Sender: TObject);
begin
  CancelCapture;
  for var Field in FFields do
    FDrafts[FPage].WriteString(Field.Section, Field.Key, Field.DefaultValue);
  if (FCategory = 3) and (FInput <> nil) then
  begin
    FDrafts[FPage].DeleteKey('FMXInput', 'Bindings');
    LoadInputBindings(FInput, FDrafts[FPage], SettingsCoreIds[FPage]);
    SaveInputBindings(FInput, FDrafts[FPage]);
  end;
  BuildPage;
  FStatus.Text := Translate('Section reset. Click Apply to save.');
end;

procedure TSettingsView.PortChange(Sender: TObject);
begin
  if FBuilding then
    Exit;

  StorePage;
  RequestRebuild;
end;

procedure TSettingsView.RequestRebuild;
begin
  if FRebuildPending then
    Exit;

  FRebuildPending := True;
  var Alive: TFunc<Boolean> := FAlive;
  TThread.ForceQueue(nil,
    procedure
    begin
      if not Alive() then
        Exit;

      FRebuildPending := False;
      BuildPage(True);
    end);
end;

procedure TSettingsView.CaptureClick(Sender: TObject);
begin
  if (FInput = nil) or (TButton(Sender).Tag < 0) then
    Exit;

  CancelCapture;
  FCaptureButton := TButton(Sender);
  FCaptureAction := FCaptureButton.Tag;
  var Port := StrToIntDef(FCaptureButton.TagString, 0);
  FInput.BeginCapture(FCaptureAction, FDeviceIds[Port]);
  FCaptureDeadline := TThread.GetTickCount64 + 10000;
  FStatus.Text := Translate('Press a button or direction. Esc cancels. Waiting: 10 seconds.');
  FCaptureButton.Text := Translate('Waiting for input…');
  FCancelCapture.Visible := True;
  Resize;
end;

procedure TSettingsView.ClearBindingClick(Sender: TObject);
begin
  CancelCapture;
  FInput.RemoveBindings(TButton(Sender).Tag);
  StorePage;
  RefreshBindings;
  FStatus.Text := Translate('Binding removed. Click Apply.');
  Resize;
end;

procedure TSettingsView.CancelCapture;
begin
  if FInput <> nil then
    FInput.CancelCapture;
  if FCaptureButton <> nil then
    FCaptureButton.Text := Translate('Assign · ') + BindingCaption(FInput, FCaptureAction);
  FCaptureButton := nil;
  if FCancelCapture <> nil then
    FCancelCapture.Visible := False;
end;

procedure TSettingsView.CancelCaptureClick(Sender: TObject);
begin
  CancelCapture;
  FStatus.Text := Translate('Binding cancelled.');
  Resize;
end;

procedure TSettingsView.Poll;
begin
  if FCaptureButton = nil then
    Exit;

  var Binding: TInputBinding;
  if FInput.TakeCaptured(Binding) then
  begin
    if (Binding.Kind = TInputElementKind.Key) and (Binding.Code = 41) then
    begin
      CancelCaptureClick(Self);
      Exit;
    end;

    FInput.RemoveBindings(FCaptureAction);
    FInput.AddBinding(Binding);
    CancelCapture;
    RefreshBindings;
    FStatus.Text := Translate('Binding saved in the draft. Click Apply.');
    Resize;
  end
  else if TThread.GetTickCount64 >= FCaptureDeadline then
    CancelCaptureClick(Self);
end;

procedure TSettingsView.PickLocation(Folder: Boolean; const Current: string; const Callback: TStorageSelectionCallback);
begin
  if Assigned(FPicker) then
  begin
    FPicker(Folder, Current, Callback);
    Exit;
  end;

  var Dialog := TFMXOpenDialog.Create(nil);
  try
    Dialog.MultipleSelection := False;
    Dialog.InitialDirectory := Current;
    if not Folder then
      Dialog.InitialDirectory := ExtractFilePath(Current);
    Dialog.Title := Translate('Choose ROM folder');
    if not Folder then
    begin
      Dialog.Title := Translate('Choose cassette');
      Dialog.Filter := Translate('Cassettes (*.tape)|*.tape|All files|*.*');
      Dialog.FileMustExist := True;
    end;
    var Completion: TFMXSelectionCallback :=
      procedure(const Selection: TFMXSelectionResult)
      begin
        var Result := Default(TStorageSelection);
        Result.Cancelled := Selection.Status = TFMXSelectionStatus.Cancelled;
        Result.Error := Selection.Error;
        if Selection.Status = TFMXSelectionStatus.Selected then
          Result.Location := Selection.Locations[0];
        Callback(Result);
      end;
    if Folder then
      Dialog.SelectFolder(Completion)
    else
      Dialog.SelectFiles(Completion);
  finally
    Dialog.Free;
  end;
end;

procedure TSettingsView.PathClick(Sender: TObject);
begin
  CancelCapture;
  var Button := TEditButton(Sender);
  var Edit := TEdit(Button.TagObject);
  var Section, Key: string;
  for var F in FFields do
    if F.Control = Edit then
    begin
      Section := F.Section;
      Key := F.Key;
      Break;
    end;

  var Page := FPage;
  var Alive: TFunc<Boolean> := FAlive;
  PickLocation(Button.Tag = 1, Edit.Text,
    procedure(const Selection: TStorageSelection)
    begin
      if not Alive() then
        Exit;

      if Selection.Error <> '' then
        FStatus.Text := Selection.Error
      else if not Selection.Cancelled then
      begin
        FDrafts[Page].WriteString(Section, Key, Selection.Location);
        if FPage = Page then
          for var F in FFields do
            if (F.Section = Section) and (F.Key = Key) then
              TEdit(F.Control).Text := Selection.Location;
      end;
    end);
end;

procedure TSettingsView.ApplyClick(Sender: TObject);
begin
  try
    CancelCapture;
    StorePage;
    var Folder := FDrafts[0].ReadString('General', 'Path', '').Trim;

    {$IFNDEF ANDROID}
    if (Folder <> '') and not TDirectory.Exists(Folder) then
      raise Exception.Create(Translate('ROM folder not found. Choose an existing folder.'));
    {$ENDIF}

    if FDrafts[3].ReadBool('Input', 'FourScore', False) and
      ((FDrafts[3].ReadString('Ports', 'Port1', 'auto') = 'piano') or
      (FDrafts[3].ReadString('Ports', 'Port2', 'auto') = 'zapper') or
      (FDrafts[3].ReadString('Ports', 'Port2', 'auto') = 'powerpad')) then
      raise Exception.Create(Translate('Disable Four Score to use Zapper, Power Pad or Miracle Piano.'));

    if (FDrafts[3].ReadString('Ports', 'Port1', 'auto') = 'piano') and
      ((FDrafts[3].ReadString('Ports', 'Port2', 'auto') = 'zapper') or
      (FDrafts[3].ReadString('Ports', 'Port2', 'auto') = 'powerpad')) then
      raise Exception.Create(Translate('Miracle Piano uses both ports. Disconnect Zapper or Power Pad.'));

    // Config writes are per core and retain all settings that this UI does not expose.
    for var Ini in FDrafts do
      FStorage.WriteConfig(Ini);
    FStorage.RomFolder := Folder;
    if Assigned(FOnApply) then
      FOnApply(Self);
    FStatus.Text := Translate('Saved. Core options and connected devices apply when you next open a ROM.');
  except
    on E: Exception do
      FStatus.Text := Translate('Unable to save settings: ') + E.Message;
  end;
end;

procedure TSettingsView.ApplyLanguage(const PreviousLanguage: string);
begin
  FBuilding := True;
  try
    FormStyles.RelocalizeUI(Self, PreviousLanguage);
  finally
    FBuilding := False;
  end;
  BuildPage(True);
end;

procedure TSettingsView.BackClick(Sender: TObject);
begin
  CancelCapture;
  if Assigned(FOnClose) then
    FOnClose(Self);
end;

initialization
  TPresentationProxyFactory.Current.Register(TSettingsSpinBox, TControlType.Styled,
    TStyledPresentationProxy<TSettingsSpinBoxStyle>);

finalization
  TPresentationProxyFactory.Current.Unregister(TSettingsSpinBox, TControlType.Styled,
    TStyledPresentationProxy<TSettingsSpinBoxStyle>);

end.

