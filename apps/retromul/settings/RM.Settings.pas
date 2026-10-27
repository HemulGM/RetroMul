unit RM.Settings;

{$I ..\RM.Mobile.inc}

interface

uses
  Core.Platforms, Core.RomFormat, System.IOUtils, System.SysUtils,
  System.Classes, System.IniFiles, System.Generics.Collections, System.Types,
  System.UITypes, FMX.Forms, FMX.Types, FMX.Controls, FMX.Layouts, FMX.StdCtrls,
  FMX.Text, FMX.Edit, FMX.EditBox, FMX.SpinBox, FMX.ListBox,
  FMX.Controls.Presentation, Core.Storage, Core.Emulation, FMXInput, FMX.Objects,
  RM.Settings.Platform, RM.Settings.Catalog, RM.ShaderBitmap, RM.BitmapShaders,
  RM.Settings.Builder, RM.Settings.Binding, RM.Settings.Session,
  RM.Settings.Rendering, RM.Settings.Template.Device;

const
  SETTINGS_CATEGORY_GENERAL = RM.Settings.platform.SETTINGS_CATEGORY_GENERAL;
  SETTINGS_CATEGORY_LIBRARY = RM.Settings.platform.SETTINGS_CATEGORY_LIBRARY;
  SETTINGS_CATEGORY_VIDEO_AUDIO = RM.Settings.platform.SETTINGS_CATEGORY_VIDEO_AUDIO;
  SETTINGS_CATEGORY_CONTROLS = RM.Settings.platform.SETTINGS_CATEGORY_CONTROLS;
  SETTINGS_CATEGORY_PERIPHERALS = RM.Settings.platform.SETTINGS_CATEGORY_PERIPHERALS;

const
  SETTINGS_PAGE_MAIN = RM.Settings.platform.SETTINGS_PAGE_MAIN;
  SETTINGS_PAGE_GB = RM.Settings.platform.SETTINGS_PAGE_GB;
  SETTINGS_PAGE_GBC = RM.Settings.platform.SETTINGS_PAGE_GBC;
  SETTINGS_PAGE_NES = RM.Settings.platform.SETTINGS_PAGE_NES;
  SETTINGS_PAGE_MD = RM.Settings.platform.SETTINGS_PAGE_MD;
  SETTINGS_PAGE_SNES = RM.Settings.platform.SETTINGS_PAGE_SNES;
  SETTINGS_PAGE_NEOGEO = RM.Settings.platform.SETTINGS_PAGE_NEOGEO;
  SETTINGS_PAGE_GBA = RM.Settings.platform.SETTINGS_PAGE_GBA;
  SETTINGS_PAGE_N64 = RM.Settings.platform.SETTINGS_PAGE_N64;
  SETTINGS_PAGE_SG1000 = RM.Settings.platform.SETTINGS_PAGE_SG1000;
  SETTINGS_PAGE_SC3000 = RM.Settings.platform.SETTINGS_PAGE_SC3000;
  SETTINGS_PAGE_SF7000 = RM.Settings.platform.SETTINGS_PAGE_SF7000;
  SETTINGS_PAGE_MULTIVISION = RM.Settings.platform.SETTINGS_PAGE_MULTIVISION;
  SETTINGS_PAGE_SMS = RM.Settings.platform.SETTINGS_PAGE_SMS;
  SETTINGS_PAGE_GG = RM.Settings.platform.SETTINGS_PAGE_GG;
  SETTINGS_PAGE_GW = RM.Settings.platform.SETTINGS_PAGE_GW;

const
  AUTOSAVE_DEFAULT_MINUTES = 10;
  AUTOSAVE_MAX_MINUTES = 1440;

const
  SettingsCategoryNames: array[SETTINGS_CATEGORY_GENERAL..SETTINGS_CATEGORY_PERIPHERALS] of string =
    ('General', 'Library', 'Video and audio', 'Controls', 'Peripherals');

// Read the catalog's current tables; do not capture an initialization-time copy.
function SettingsCoreIds: TArray<string>;
function SettingsPageNames: TArray<string>;
function SettingsCoreOrder: TArray<Integer>;

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

  TSettingsTemplatePicker = reference to procedure(const SuggestedName: string; const Callback: TStorageSelectionCallback);

  TSettingsField = TSettingsBinding;

  TSettingsDevice = class
    RowView: TSettingsRowView;
    Template: TSettingsDeviceTemplate;
    Control: TControl;
    Diagram: TControl;
    Capture, Clear: TButton;
    Caption: TLabel;
    Assignments: TLayout;
    AssignmentList: TLayout;
    Port: Integer;
    Device: string;
  end;

  TSettingsView = class(TFrame)
    PanelSidebar: TPanel;
    PanelPlatforms: TPanel;
    LayoutPlatformSearchSlot: TLayout;
    ListBoxPlatforms: TListBox;
    LabelNoPlatforms: TLabel;
    LayoutPlatformPickerSlot: TLayout;
    ButtonReset: TButton;
    ButtonRefresh: TButton;
    ListBoxNavigation: TListBox;
    LayoutBody, LayoutContent, LayoutHeader, LayoutFooter: TLayout;
    LayoutSettingsMainColumn, LayoutSettingsPreviewColumn: TLayout;
    VertScrollBoxScroll: TVertScrollBox;
    LabelTitle, LabelStatus: TLabel;
    PanelConfigurationNotice: TPanel;
    VertScrollBoxConfigurationNotice: TVertScrollBox;
    LabelConfigurationNotice: TLabel;
    ButtonApply, ButtonBack, ButtonCancelCapture: TButton;
    ButtonSidebarBack: TButton;
    LayoutSettingsSearchSlot, LayoutSettingsPagePickerSlot: TLayout;
    LayoutSettingsHeading, LayoutSettingsCompactSearchSlot: TLayout;
    LayoutSettingsCompactReset, LayoutSettingsActions: TLayout;
    PathCategoryGeneral, PathCategoryLibrary, PathCategoryVideoAudio: TPath;
    PathCategoryControls, PathCategoryPeripherals: TPath;
    LabelBrand: TLabel;
    PathBrandIcon: TPath;
  private
    FStorage: IStorage;
    FPicker: TSettingsLocationPicker;
    FTemplatePicker: TSettingsTemplatePicker;
    FPickingBootROM: Boolean;
    FPickingTranslation: Boolean;
    FInput: TInputManager; // Draft assignments owned by this view.
    FHostInput: TInputManager; // Shared device snapshots; owned by the form.
    FDrafts: TArray<TMemIniFile>;
    FContext: TSettingsPageBuilder;
    FSession: TSettingsSession;
    FRows: TObjectList<TSettingsRowView>;
    FGroups: TObjectList<TSettingsGroupView>;
    FBindingDevices: TDictionary<TButton, TSettingsDevice>;
    FBlockControls: TDictionary<TSettingsBlockDefinition, TControl>;
    FSelections: TDictionary<TComboBox, TSettingsSelection>;
    FLastRow, FNextRow: TSettingsRowView;
    FNextEditor: TControl;
    FNextKind: TSettingsRowKind;
    FScaling, FPalette: TComboBox;
    FVideoGroup: TPanel;
    FShaderStatus: TLabel;
    FFields: TObjectList<TSettingsField>;
    FDevices: TObjectList<TSettingsDevice>;
    FDeviceIds: array[0..11] of string;
    FAlive: TFunc<Boolean>;
    FInvalidate: TProc;
    FSearch: TEdit;
    FPagePicker: TComboBox;
    FCategory, FCorePage, FPlayer: Integer;
    FPlatformSearch: TEdit;
    FPlatformPicker: TComboBox;
    FCategoryIcons: array[SETTINGS_CATEGORY_GENERAL..SETTINGS_CATEGORY_PERIPHERALS] of TControl;
    FPage: Integer;
    FGroup: TPanel;
    FPreview: TControl;
    FPreviewGroup: TPanel;
    FPreviewShaderFile: string;
    FPreviewShaderLoaded: Boolean;
    FHeight: Single;
    FBuilding, FRebuildPending, FArranging, FDeviceArranging, FLayoutPending: Boolean;
    FVolumeValue: TLabel;
    FAutosaveMinutes: TSpinBox;
    FCaptureAction: Integer;
    FCaptureDeadline: UInt64;
    FCaptureButton: TButton;
    FOnApply, FOnClose: TNotifyEvent;
    procedure InitializeRuntimeControls;
    procedure RefreshPlatformList;
    procedure SyncPlatformSelection;
    procedure PlatformSearchChange(Sender: TObject);
    procedure PlatformSelectionChange(Sender: TObject);
    procedure PlatformPickerChange(Sender: TObject);
    procedure BuildPalettePreview(Palette: TChoiceSetting);
    procedure BuildVideoPreview;
    procedure UpdateShaderPreview;
    procedure ShaderParameterChange(Sender: TObject);
    procedure ShaderFileChange(Sender: TObject);
    function ShaderTrack(const Name, Caption, Description, Key: string; Default, Minimum, Maximum: Integer): TTrackBar;
    procedure ClearPathClick(Sender: TObject);
    procedure SaveTemplateClick(Sender: TObject);
    procedure BuildPage(PreserveScroll: Boolean = False);
    procedure RequestRebuild;
    procedure StorePage;
    procedure WireConfigurationChanges;
    procedure ConfigurationChange(Sender: TObject);
    procedure UpdateConfigurationNotice;
    procedure MeasureConfigurationNotice;
    procedure Heading(const Name, Caption: string; Emphasized: Boolean = True; TitleSize: Single = 20);
    procedure RenderGroup(Group: TSettingsGroup);
    procedure RenderField(Definition: TSettingsFieldDefinition);
    procedure RenderBlock(Definition: TSettingsBlockDefinition);
    procedure SelectionChange(Sender: TObject);
    function GetPageDefinition: TSettingsPageDefinition;
    procedure ReleasePage;
    function RowView(Panel: TControl): TSettingsRowView;
    procedure SetChangeHandler(Control: TControl; Handler: TNotifyEvent);
    procedure UpdateConditions;
    function Row(const Name, Caption, Description: string; Kind: TSettingsRowKind = TSettingsRowKind.Standard): TPanel;
    function Combo(const Name, Caption, Description, Section, Key: string; const Labels, Values: array of string; const Default: string): TComboBox;
    function Check(const Name, Caption, Description, Section, Key: string; Default: Boolean): TSwitch;
    function Number(const Name, Caption, Description, Section, Key: string; Default, Max: Integer): TSpinBox;
    function EditText(const Name, Caption, Description, Section, Key, Default: string): TEdit;
    function PathEdit(const Name, Caption, Description, Section, Key, Default: string; Folder: Boolean): TEdit;
    procedure ArrangeGroup(Group: TPanel);
    procedure ContentResize(Sender: TObject);
    procedure EditorResize(Sender: TObject);
    procedure ComboResize(Sender: TObject);
    procedure RowResize(Sender: TObject);
    procedure DeviceResize(Sender: TObject);
    procedure BindingFooterResize(Sender: TObject);
    procedure NavigationChange(Sender: TObject);
    procedure PagePickerChange(Sender: TObject);
    procedure SearchChange(Sender: TObject);
    procedure PlayerChange(Sender: TObject);
    procedure BuildPort(Port: Integer; const Caption: string);
    procedure BuildBindings(Port: Integer; const Device: string);
    function AddBinding(const Caption: string; Action, Port: Integer): TButton;
    procedure BuildDevice(Port: Integer; const Device: string);
    procedure AddDeviceAssignment(Device: TSettingsDevice; Panel: TPanel; Action: Integer; const Caption: string);
    procedure RefreshBindings;
    procedure SelectBinding(Device: TSettingsDevice; Action: Integer; const Caption: string);
    procedure AssignmentClick(Sender: TObject);
    procedure CalloutClick(Sender: TObject);
    procedure VirtualDeviceChange(Sender: TObject);
    procedure DeviceChange(Sender: TObject);
    procedure RefreshDevicesClick(Sender: TObject);
    procedure PortChange(Sender: TObject);
    procedure CaptureClick(Sender: TObject);
    procedure ClearBindingClick(Sender: TObject);
    procedure CancelCaptureClick(Sender: TObject);
    procedure VolumeChange(Sender: TObject);
    procedure PreviewChange(Sender: TObject);
    procedure ResetClick(Sender: TObject);
    procedure PathClick(Sender: TObject);
    procedure DetectRomFoldersClick(Sender: TObject);
    procedure ApplyClick(Sender: TObject);
    procedure BackClick(Sender: TObject);
  protected
    procedure Resize; override;
    procedure PickLocation(Folder: Boolean; const Current: string; const Callback: TStorageSelectionCallback); virtual;
    procedure PickTemplateLocation(const Callback: TStorageSelectionCallback); virtual;
  public
    constructor CreateSettings(AOwner: TComponent; const Storage: IStorage; Input: TInputManager);
    destructor Destroy; override;
    procedure SelectCategory(Index: Integer);
    procedure SelectCore(Index: Integer; PreserveCategory: Boolean = False);
    function ControlFor(Block: TSettingsBlockDefinition): TControl;
    property PageDefinition: TSettingsPageDefinition read GetPageDefinition;
    property Bindings: TObjectList<TSettingsField> read FFields;
    property SettingsSearch: TEdit read FSearch;
    property Category: Integer read FCategory;
    property CorePage: Integer read FCorePage;
    procedure Poll;
    procedure CancelCapture;
    property InputManager: TInputManager read FInput;
    function HandleCaptureKeyDown(var Key: Word; var KeyChar: WideChar): Boolean;
    procedure ApplyLanguage(const PreviousLanguage: string);
    property OnApply: TNotifyEvent read FOnApply write FOnApply;
    property LocationPicker: TSettingsLocationPicker read FPicker write FPicker;
    property TemplateLocationPicker: TSettingsTemplatePicker read FTemplatePicker write FTemplatePicker;
    property OnClose: TNotifyEvent read FOnClose write FOnClose;
  end;

implementation

uses
  RM.Settings.Template.Group, RM.Settings.Template.Row,
  RM.Settings.Template.Path, RM.Settings.Template.Interval,
  RM.Settings.Template.Volume, RM.Settings.Template.Track,
  RM.Settings.Template.Preview, RM.Settings.Template.Binding, System.Math,
  System.StrUtils, System.TypInfo, RM.Input, GB.Memory, GB.Palettes,
  FMX.OpenDialog, RM.Gamepad, NES.PowerPad, NES.SuborKeyboard,
  NES.FamicomKeyboard, NES.MiraclePiano, NES.Controller, NES.MiraclePianoDevice,
  FMX.BehaviorManager, FMX.Graphics, FMX.SpinBox.Style, FMX.Presentation.Style,
  FMX.Presentation.Factory, RM.LibraryView, RM.Icons, RM.SearchEdit, RM.Styles,
  RM.Dialogs, FMX.TextLayout, Core.Adapter.PS1, Core.Adapter.DC
  {$IFDEF ANDROID}, Core.Storage.Android{$ENDIF};

{$R *.fmx}

function SettingsCoreIds: TArray<string>;
begin
  Result := RM.Settings.Catalog.SettingsCoreIds;
end;

function SettingsPageNames: TArray<string>;
begin
  Result := RM.Settings.Catalog.SettingsPageNames;
end;

function SettingsCoreOrder: TArray<Integer>;
begin
  Result := RM.Settings.Catalog.SettingsCoreOrder;
end;

type
  TSettingsLayoutAccess = class(TLayout);

  TSettingsInputBackend = class(TInputBackend)
  private
    FHost: TInputManager;
  public
    constructor Create(Host: TInputManager);
    procedure Refresh; override;
    procedure RefreshIfNeeded; override;
    function Poll: TArray<TInputValue>; override;
  end;

  TSettingsPreview = class(TShaderBitmap)
  private
    FPaletteIndex: Integer;
    procedure SetPaletteIndex(Value: Integer);
  public
    constructor Create(AOwner: TComponent); override;
    property PaletteIndex: Integer read FPaletteIndex write SetPaletteIndex;
    procedure SetColorPattern;
  published
    property Align;
    property Margins;
    property Position;
    property Size;
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

constructor TSettingsInputBackend.Create(Host: TInputManager);
begin
  inherited Create;
  FHost := Host;
end;

procedure TSettingsInputBackend.Refresh;
begin
  FHost.Refresh;
  RefreshIfNeeded;
end;

procedure TSettingsInputBackend.RefreshIfNeeded;
begin
  FDevices := FHost.Devices;
end;

function TSettingsInputBackend.Poll: TArray<TInputValue>;
begin
  // The frontend polls the native backend once. Editing assignments must not
  // replace the running game's map or consume relative input a second time.
  Result := FHost.Values;
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

constructor TSettingsPreview.Create(AOwner: TComponent);
begin
  inherited;
  WrapMode := TImageWrapMode.Fit;
  DisableInterpolation := True;
  FPaletteIndex := -1;
  SetPaletteIndex(0);
end;

procedure TSettingsPreview.SetPaletteIndex(Value: Integer);
begin
  Value := EnsureRange(Value, 0, SCREEN_PALETTE_COUNT - 1);
  if Value = FPaletteIndex then
    Exit;
  Bitmap.SetSize(160, 144);
  var Data: TBitmapData;
  if not Bitmap.Map(TMapAccess.Write, Data) then
    Exit;
  try
    var Palette := ScreenPalettes[Value];
    for var PixelY := 0 to Bitmap.Height - 1 do
      for var PixelX := 0 to Bitmap.Width - 1 do
      begin
        var X := PixelX * 32 div Bitmap.Width;
        var Y := PixelY * 29 div Bitmap.Height;
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
        Data.SetPixel(PixelX, PixelY, Palette.Colors[Shade]);
      end;
    FPaletteIndex := Value;
  finally
    Bitmap.Unmap(Data);
  end;
  ResetHistory;
end;

procedure TSettingsPreview.SetColorPattern;
begin
  if FPaletteIndex = -1 then
    Exit;
  Bitmap.SetSize(256, 240);
  var Data: TBitmapData;
  if not Bitmap.Map(TMapAccess.Write, Data) then
    Exit;
  try
    // Fine edges, gradients and saturated colors make all built-in effects visible.
    for var Y := 0 to Bitmap.Height - 1 do
      for var X := 0 to Bitmap.Width - 1 do
      begin
        var Pixel: TAlphaColorRec;
        Pixel.A := 255;
        Pixel.R := X;
        Pixel.G := Y * 255 div 239;
        Pixel.B := 255 - X;
        if Y < 48 then
        begin
          Pixel.R := 255 * Ord((X div 32 and 1) <> 0);
          Pixel.G := 255 * Ord((X div 32 and 2) <> 0);
          Pixel.B := 255 * Ord((X div 32 and 4) <> 0);
        end;
        if (Y > 176) and (X > 16) and (X < 240) then
        begin
          var Shade := Byte(48 + 160 * Ord(((X div 4 + Y div 4) and 1) = 0));
          Pixel.R := Shade;
          Pixel.G := Shade;
          Pixel.B := Shade;
        end;
        if (X in [16, 239]) or (Y in [64, 160]) then
          Pixel.Color := TAlphaColors.White;
        Data.SetPixel(X, Y, Pixel.Color);
      end;
    FPaletteIndex := -1;
  finally
    Bitmap.Unmap(Data);
  end;
  ResetHistory;
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
  else if FItems[Index].Button < 0 then
    // -1 - N: auxiliary button N.
    Result := TScreenGamepad(FDevice).AuxiliaryButtonBounds(-1 - FItems[Index].Button)
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
      var Name := Translate(CoreButtonName(Core, B));
      AddCallout(Ord(B), PadAction(Port, B), Name, Translate('Button ') + Name, Left, Click);
    end;
  if (Core = ROM_SYSTEM_N64) and (Device is TScreenGamepad) and
    not TScreenGamepad(Device).AuxiliaryButtonBounds(0).IsEmpty then
    AddCallout(-1, N64LAction + Port, 'L', Translate('Button ') + 'L', True, Click);
  if (Core = ROM_SYSTEM_PS1) and (Device is TScreenGamepad) then
    for var Extra := Low(TPS1Extra) to High(TPS1Extra) do
      if not TScreenGamepad(Device).AuxiliaryButtonBounds(Ord(Extra)).IsEmpty then
        AddCallout(-1 - Ord(Extra), PS1Action(Port, Extra), Translate(PS1ExtraName(Extra)),
          Translate('Button ') + Translate(PS1ExtraName(Extra)), True, Click);
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
    Aspect := TNesPowerPad(FDevice).AspectRatio;
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
  // PaintTo temporarily detaches Parent when rendering to a bitmap.
  var D := TDeviceCallouts(Owner);
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
  FBuilding := True;
  inherited Create(AOwner);
  FCategory := SETTINGS_CATEGORY_GENERAL;
  FPage := SETTINGS_PAGE_MAIN;
  FCorePage := SETTINGS_PAGE_GB;
  if SettingsPlatforms.Find(FCorePage) = nil then
  begin
    var Available := SettingsPlatforms.Matching('');
    if Length(Available) > 0 then FCorePage := Available[0].PageId
    else FCorePage := SETTINGS_PAGE_MAIN;
  end;
  FStorage := Storage;
  FHostInput := Input;
  if Input <> nil then
    FInput := TInputManager.Create(TSettingsInputBackend.Create(Input));
  FFields := TObjectList<TSettingsField>.Create;
  FRows := TObjectList<TSettingsRowView>.Create;
  FGroups := TObjectList<TSettingsGroupView>.Create;
  FBindingDevices := TDictionary<TButton, TSettingsDevice>.Create;
  FBlockControls := TDictionary<TSettingsBlockDefinition, TControl>.Create;
  FSelections := TDictionary<TComboBox, TSettingsSelection>.Create;
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
  FSession := TSettingsSession.Create(FStorage, SettingsPlatforms.MaxPageId + 1);
  FSession.Open(SETTINGS_PAGE_MAIN, 'config');
  for var platform in SettingsPlatforms.Items do
    FSession.Open(platform.PageId, platform.CoreId);
  FDrafts := FSession.Drafts;
  FContext := TSettingsPageBuilder.Create;
  FContext.OnRebuild := PortChange;
  FContext.OnGroup :=
    procedure(Group: TSettingsGroup)
    begin
      RenderGroup(Group);
    end;
  FContext.OnField :=
    procedure(Field: TSettingsFieldDefinition)
    begin
      RenderField(Field);
    end;
  FContext.OnBlock :=
    procedure(Block: TSettingsBlockDefinition)
    begin
      RenderBlock(Block);
    end;
  FContext.OnBindings :=
    procedure(Port: Integer; Device: string)
    begin
      BuildBindings(Port, Device);
    end;
  FContext.OnPalette :=
    procedure(Palette: TChoiceSetting)
    begin
      BuildPalettePreview(Palette);
    end;
  InitializeRuntimeControls;
  FormStyles.RelocalizeUI(Self, 'en');
  ButtonSidebarBack.OnClick := BackClick;
  ButtonSidebarBack.StylesData['text.Margins.Left'] := 36;
  ButtonSidebarBack.StylesData['text.Margins.Right'] := 10;
  for var i := Low(FCategoryIcons) to High(FCategoryIcons) do
  begin
    ListBoxNavigation.ListItems[i].StyledSettings := ListBoxNavigation.ListItems[i].StyledSettings + [TStyledSetting.Other];
    ListBoxNavigation.ListItems[i].TextSettings.HorzAlign := TTextAlign.Leading;
    ListBoxNavigation.ListItems[i].StylesData['text.Margins.Left'] := 48;
  end;
  ListBoxNavigation.OnChange := NavigationChange;
  FSearch.OnChangeTracking := SearchChange;
  FSearch.OnResize := EditorResize;
  FPlatformSearch.TextPrompt := Translate('Search platforms');
  FPlatformSearch.OnChangeTracking := PlatformSearchChange;
  FPlatformSearch.OnResize := EditorResize;
  FPlatformPicker.OnChange := PlatformPickerChange;
  FPlatformPicker.OnResize := ComboResize;
  ListBoxPlatforms.OnChange := PlatformSelectionChange;
  RefreshPlatformList;
  FPagePicker.OnResize := ComboResize;
  ComboResize(FPagePicker);
  FPagePicker.OnChange := PagePickerChange;
  ButtonApply.OnClick := ApplyClick;
  ButtonBack.OnClick := BackClick;
  ButtonReset.OnClick := ResetClick;
  ButtonRefresh.OnClick := RefreshDevicesClick;
  ButtonRefresh.Enabled := FInput <> nil;
  ButtonCancelCapture.OnClick := CancelCaptureClick;
  VertScrollBoxScroll.OnResize := ContentResize;
  BuildPage;
end;

procedure TSettingsView.BuildVideoPreview;
begin
  var PreviousGroup := FGroup;
  var PreviousDefinition := FContext.CurrentGroup;
  FContext.Heading('GroupPreview', 'Preview', True, True);
  FPreviewGroup := FGroup;
  AddSettingsControl(FContext, 'Row160144', '160 × 144',
    'Preview of the selected palette and shader settings.', TSettingsRowKind.Preview,
    function(Row: TSettingsRowView): TControl
    begin
      Row.CustomLayout := True;
      Row.Panel.Padding.Rect := TRectF.Empty;
      Row.Panel.Height := 350;
      Row.Text.Visible := False;
      var Template := TSettingsPreviewTemplate(Row.Template);
      FPreview := TSettingsPreview.Create(Template);
      FPreview.Parent := Template.LayoutPalettePreviewSlot;
      FPreview.Align := TAlignLayout.Client;
      FShaderStatus := Template.LabelShaderStatus;
      FShaderStatus.Parent := FPreviewGroup;
      Result := FPreview;
    end);
  FGroup := PreviousGroup;
  FContext.CurrentGroup := PreviousDefinition;
end;

procedure TSettingsView.BuildPalettePreview(Palette: TChoiceSetting);
begin
  for var Binding in FFields do
    if Binding.Definition = Palette then
      FPalette := TComboBox(Binding.Control);
  SetChangeHandler(FPalette, PreviewChange);
  if FScaling <> nil then
    SetChangeHandler(FScaling, PreviewChange);
  BuildVideoPreview;
  TSettingsPreview(FPreview).PaletteIndex := FPalette.ItemIndex;
  TSettingsPreview(FPreview).DisableInterpolation := FScaling.ItemIndex = 0;
end;

function TSettingsView.ShaderTrack(const Name, Caption, Description, Key: string; Default, Minimum, Maximum: Integer): TTrackBar;
begin
  FNextKind := TSettingsRowKind.Track;
  var Definition := FContext.AddSlider(Name, Caption, Description, 'Shaders', Key,
    Default, Minimum, Maximum, 1, True);
  if Key = 'LCDResponseMS' then
    Definition.UnitCaption := 'ms'
  else
    Definition.UnitCaption := '%';
  Result := TTrackBar(FFields.Last.Control);
  Result.Frequency := 1;
  Result.Tracking := True;
  SetChangeHandler(Result, ShaderParameterChange);
  ShaderParameterChange(Result);
end;

procedure TSettingsView.ShaderParameterChange(Sender: TObject);
begin
  for var Binding in FFields do
    if Binding.Control = Sender then
    begin
      var Definition := TSliderSetting(Binding.Definition);
      if Binding.RowView.ValueLabel <> nil then
        Binding.RowView.ValueLabel.Text := IntToStr(Round(TTrackBar(Sender).Value)) +
          IfThen(Definition.UnitCaption = '%', '%', ' ' + Translate(Definition.UnitCaption));
      Break;
    end;
  if FBuilding then
    Exit;
  StorePage;
  UpdateShaderPreview;
end;

procedure TSettingsView.ShaderFileChange(Sender: TObject);
begin
  if FBuilding then
    Exit;
  StorePage;
  UpdateShaderPreview;
end;

procedure TSettingsView.UpdateShaderPreview;
begin
  if not (FPreview is TSettingsPreview) then
    Exit;
  var Preview := TSettingsPreview(FPreview);
  var Draft := FDrafts[FPage];
  var Options := TBitmapShaderSettings.Default;
  Options.ScanlineStrength := Draft.ReadInteger('Shaders', 'Scanlines', 35) / 100;
  Options.Curvature := Draft.ReadInteger('Shaders', 'Curvature', 8) / 100;
  Options.MaskStrength := Draft.ReadInteger('Shaders', 'Mask', 65) / 100;
  Options.Glow := Draft.ReadInteger('Shaders', 'Glow', 20) / 100;
  Options.LCDGridStrength := Draft.ReadInteger('Shaders', 'LCDGrid', 35) / 100;
  Options.LCDResponseMS := Draft.ReadInteger('Shaders', 'LCDResponseMS', 65);
  Options.Gamma := Draft.ReadInteger('Shaders', 'Gamma', 100) / 100;
  Options.Saturation := Draft.ReadInteger('Shaders', 'Saturation', 100) / 100;
  Options.Temperature := Draft.ReadInteger('Shaders', 'Temperature', 100) / 100 - 1;
  Preview.Settings := Options;
  Preview.DisableInterpolation := Draft.ReadString('Video', 'Filter', 'nearest') = 'nearest';
  var Effect := Draft.ReadString('Shaders', 'Mode', 'off');
  var NextMode := TBitmapShaderMode.Original;
  if Effect = 'scanlines' then
    NextMode := TBitmapShaderMode.Scanlines
  else if Effect = 'crt' then
    NextMode := TBitmapShaderMode.CRT
  else if Effect = 'lcd' then
    NextMode := TBitmapShaderMode.LCD
  else if Effect = 'color' then
    NextMode := TBitmapShaderMode.ColorCorrection;
  var Status := FShaderStatus;
  if Effect = 'custom' then
  begin
    var FileName := Draft.ReadString('Shaders', 'File', '').Trim;
    if (FileName <> FPreviewShaderFile) or (not FPreviewShaderLoaded and not Status.Visible) then
    begin
      FPreviewShaderFile := FileName;
      FPreviewShaderLoaded := False;
      Status.Visible := False;
      if FileName <> '' then
      begin
        if not System.IOUtils.TPath.IsPathRooted(FileName) then
          FileName := System.IOUtils.TPath.Combine(System.IOUtils.TPath.GetDocumentsPath, FileName);
        try
          Preview.LoadShaderFromFile(FileName);
          FPreviewShaderLoaded := True;
        except
          on E: Exception do
          begin
            Preview.Mode := TBitmapShaderMode.Original;
            Status.Text := Translate('Cannot preview this shader. Check the shader file.');
            Status.Hint := E.Message;
            Status.ShowHint := True;
            Status.Visible := True;
          end;
        end;
      end
      else
      begin
        Status.Text := Translate('Choose a shader file to see the preview.');
        Status.Visible := True;
      end;
    end;
    if FPreviewShaderLoaded then
      NextMode := TBitmapShaderMode.Custom;
  end
  else
    Status.Visible := False;
  Preview.Mode := NextMode;
end;

procedure TSettingsView.ClearPathClick(Sender: TObject);
begin
  for var R in FRows do
    if R.Clear = Sender then
    begin
      TEdit(R.Editor).Text := '';
      Exit;
    end;
end;

procedure TSettingsView.InitializeRuntimeControls;
type
  TControlClass = class of TControl;

  function CreateInSlot(Slot: TLayout; Kind: TControlClass): TControl;
  begin
    Result := Kind.Create(Self);
    Result.Name := Copy(Kind.ClassName, 2, MaxInt) + string(Slot.Name).Substring(6).Replace('Slot', '');
    Result.Parent := Slot.Parent;
    Result.Size.Size := Slot.Size.Size;
    Result.Margins.Assign(Slot.Margins);
    Result.Align := Slot.Align;
    Result.Index := Slot.Index;
    Slot.Visible := False;
  end;

begin
  FSearch := TEdit(CreateInSlot(LayoutSettingsSearchSlot, TSearchEdit));
  FSearch.TextPrompt := Translate('Search this section');
  FPagePicker := TComboBox(CreateInSlot(LayoutSettingsPagePickerSlot, TSettingsComboBox));
  for var Caption in SettingsCategoryNames do
    FPagePicker.Items.Add(Translate(Caption));
  FPlatformSearch := TEdit(CreateInSlot(LayoutPlatformSearchSlot, TSearchEdit));
  FPlatformPicker := TComboBox(CreateInSlot(LayoutPlatformPickerSlot, TSettingsComboBox));
  FCategoryIcons[0] := PathCategoryGeneral;
  FCategoryIcons[1] := PathCategoryLibrary;
  FCategoryIcons[2] := PathCategoryVideoAudio;
  FCategoryIcons[3] := PathCategoryControls;
  FCategoryIcons[4] := PathCategoryPeripherals;
end;

destructor TSettingsView.Destroy;
begin
  FBuilding := True;
  if Assigned(FInvalidate) then
    FInvalidate();
  CancelCapture;
  ReleasePage;
  FContext.Free;
  FFields.Free;
  FRows.Free;
  FGroups.Free;
  FBindingDevices.Free;
  FBlockControls.Free;
  FSelections.Free;
  FDevices.Free;
  FDrafts := nil;
  FSession.Free;
  FInput.Free;
  inherited;
end;

procedure TSettingsView.BuildPage(PreserveScroll: Boolean);
begin
  var Position := VertScrollBoxScroll.ViewportPosition;
  FBuilding := True;
  VertScrollBoxScroll.BeginUpdate;
  try
    FPagePicker.ItemIndex := FCategory;
    CancelCapture;
    FAutosaveMinutes := nil;
    FVolumeValue := nil;
    if FPreview is TSettingsPreview then
      TSettingsPreview(FPreview).Mode := TBitmapShaderMode.Original;
    FPreview := nil;
    FPreviewGroup := nil;
    FPreviewShaderFile := '';
    FPreviewShaderLoaded := False;
    ReleasePage;
    FContext.PageId := FPage;
    FContext.Draft := FDrafts[FPage];
    LayoutSettingsMainColumn.BeginUpdate;
    LayoutSettingsPreviewColumn.BeginUpdate;
    LayoutContent.Margins.Right := Max(16, VertScrollBoxScroll.Width - 1240);
    FGroup := nil;
    FHeight := 0;
    LabelStatus.Text := Translate('Click Apply to save changes.');
    if FCategory = SETTINGS_CATEGORY_GENERAL then
    begin
      Heading('GroupAppearance', 'Appearance');
      Combo('RowLanguage', 'Language', 'Detected on first launch. Your selection is saved.', 'General', 'Language', ['English', 'Русский', 'Português'], ['en', 'ru', 'pt'], 'en');
      PathEdit('RowTranslationfile', 'Translation file', 'Overrides the selected language. Leave empty to use the built-in' + ' translation.', 'General', 'TranslationFile', '',
        False);
      FContext.AddAction('RowTranslationtemplate', 'Translation template',
        'Save all original strings to a UTF-8 file for translation.',
        'Save translation template', SaveTemplateClick);
      FContext.AddInformation('RowTheme', 'Theme',
        'RetroMul dark theme with an amber accent.', 'Dark · RetroMul');

      Heading('GroupDuringgameplay', 'During gameplay');
      Check('RowPausewhenfocusislost', 'Pause when focus is lost', 'When switching to another application.', 'General', 'PauseOnFocusLoss', True);
      Check('RowStartinfullscreen', 'Start in full screen', 'Open games in full screen.', 'General', 'StartFullscreen', False);
      Heading('GroupAutosave', 'Autosave');
      Check('RowAutosaveonexit', 'Autosave on exit', 'Save when closing a game or the application.', 'General', 'AutosaveOnExit', True);
      FNextKind := TSettingsRowKind.Interval;
      var Periodic := Check('RowAutosaveeveryNminutes', 'Autosave every N minutes', 'Overwrite the autosave slot at the selected interval.', 'General', 'AutosavePeriodic', False);
      var PeriodicDefinition := TBooleanSetting(FFields.Last.Definition);
      var IntervalRow := FLastRow;
      var IntervalTemplate := TSettingsIntervalTemplate(IntervalRow.Template);
      FAutosaveMinutes := TSettingsSpinBox.Create(IntervalRow.Template);
      FAutosaveMinutes.Parent := IntervalTemplate.LayoutAutosaveMinutesSlot;
      FNextRow := IntervalRow;
      FNextEditor := FAutosaveMinutes;
      var Minutes := FContext.AddInteger('AutosaveMinutes', 'Autosave interval', '',
        'General', 'AutosaveMinutes', AUTOSAVE_DEFAULT_MINUTES, AUTOSAVE_MAX_MINUTES);
      Minutes.Min := 1;
      Periodic.Align := TAlignLayout.Right;
      FAutosaveMinutes.Align := TAlignLayout.Client;
      FAutosaveMinutes.Enabled := Periodic.IsChecked;
      Minutes.EnabledWhen := PeriodicDefinition.IsTrue();
      Heading('GroupOnscreenbuttons', 'On-screen buttons');
      var PadScale := Number('RowGamepadscale', 'Gamepad scale (%)', '50-200%. Limited by available screen space.', 'General', 'GamepadScale', 100, 200);
      TIntegerSetting(FFields.Last.Definition).Min := 50;
      PadScale.Min := 50;
      PadScale.Value := Max(50, PadScale.Value);
      Number('RowBottominset', 'Bottom inset', 'Distance from the bottom edge. The safe area is included automat' + 'ically.', 'General', 'ControlBottomInset', 100, 400);
      Check('RowTouchhaptics', 'Touch vibration', 'A short pulse when an on-screen gamepad button is pressed.', 'General', 'TouchHaptics', True);
    end
    else if FCategory = SETTINGS_CATEGORY_LIBRARY then
    begin
      Heading('GroupPlatformFolders', 'Platform ROM folders', False, 14);
      FContext.AddAction('RowDetectRomFolders', 'Detect platform folders',
        'Choose a parent folder to fill the platform paths below.',
        'Detect automatically', DetectRomFoldersClick);
      for var platform in TPlatformRegistry.All do
        PathEdit('RowRomFolder' + platform.Folder.Substring(0, 1).ToUpper + platform.Folder.Substring(1), platform.Name.Replace(' (experimental)', ''), 'ROM folder',
          'RomFolders', platform.Id, '', True);
      Heading('GroupGamelibrary', 'Game library');
      Combo('RowLibraryview', 'Library view', 'Cover grid or compact list.', 'Library', 'View', ['Covers', 'List'], ['grid', 'list'], 'grid');
      Combo('RowCardsize', 'Card size', 'The number of covers per row adapts to the window.', 'Library', 'CardWidth', ['Compact', 'Normal', 'Large'], ['140', '170', '220'], '170');
      Check('RowShowplatformoncards', 'Show platform on cards', 'Console name below each game cover.', 'Library', 'ShowPlatform', True);
      Check('RowLetternavigation', 'Letter navigation', 'Filter ROMs by their first letter using the column on the left.', 'Library', 'ShowLetters', False);
      Heading('GroupMetadata', 'Metadata');
      FContext.AddInformation('RowCoversanddescriptions', 'Covers and descriptions',
        'Files with known ROM extensions from all platforms are listed. Optional gamelist.xml adds descriptions and artwork.', '');
    end
    else
    begin
      var platform := SettingsPlatforms.Find(FPage);
      if platform = nil then
      begin
        LabelStatus.Text := Translate('No platforms found');
        Exit;
      end;
      FContext.PageId := FPage;
      FContext.Draft := FDrafts[FPage];
      if FInput <> nil then
        LoadInputBindings(FInput, FDrafts[FPage], SettingsCoreIds[FPage]);
      if FCategory = SETTINGS_CATEGORY_VIDEO_AUDIO then
      begin
        platform.Configuration(FContext);
        Heading('GroupVideo', 'Video');
        var Scaling := Combo('RowImagescaling', 'Image scaling', 'Nearest neighbor preserves sharp pixels; smoothing softens the i' + 'mage.', 'Video', 'Filter',
          ['Nearest neighbor', 'Smoothing'], ['nearest', 'linear'], 'nearest');
        FScaling := Scaling;
        SetChangeHandler(Scaling, PreviewChange);
        FVideoGroup := FGroup;
        var VideoDefinition := FContext.CurrentGroup;
        platform.Video(FContext);
        FGroup := FVideoGroup;
        FContext.CurrentGroup := VideoDefinition;
        var ShaderMode := Combo('RowShaderMode', 'Shader', 'Display effect for this platform.', 'Shaders', 'Mode', ['Off', 'Scanlines', 'CRT', 'LCD', 'Color correction',
            'Custom'], ['off', 'scanlines', 'crt', 'lcd', 'color', 'custom'], 'off');
        SetChangeHandler(ShaderMode, PortChange);
        var Effect := FDrafts[FPage].ReadString('Shaders', 'Mode', 'off');
        if (Effect = 'scanlines') or (Effect = 'crt') then
          ShaderTrack('RowShaderScanlines', 'Scanline strength (%)', 'Darkening between scanlines.', 'Scanlines', 35, 0, 100);
        if Effect = 'crt' then
        begin
          ShaderTrack('RowShaderCurvature', 'CRT curvature (%)', 'Screen curvature.', 'Curvature', 8, 0, 30);
          ShaderTrack('RowShaderMask', 'CRT mask (%)', 'Phosphor mask strength.', 'Mask', 65, 0, 100);
          ShaderTrack('RowShaderGlow', 'CRT glow (%)', 'Phosphor glow strength.', 'Glow', 20, 0, 100);
        end;
        if Effect = 'lcd' then
        begin
          ShaderTrack('RowShaderLCDGrid', 'LCD grid (%)', 'Pixel grid strength.', 'LCDGrid', 35, 0, 100);
          ShaderTrack('RowShaderLCDResponse', 'LCD response (ms)', 'Set to zero to disable image persistence.', 'LCDResponseMS', 65, 0, 500);
        end;
        if Effect = 'custom' then
          SetChangeHandler(EditText('RowShaderFile', 'Custom shader file', 'Absolute path or path relative to Documents (.shader.json).', 'Shaders', 'File', ''), ShaderFileChange);
        if (Effect = 'color') or (Effect = 'custom') then
        begin
          ShaderTrack('RowShaderGamma', 'Gamma (%)', '100 is neutral.', 'Gamma', 100, 25, 400);
          ShaderTrack('RowShaderSaturation', 'Saturation (%)', '100 is neutral.', 'Saturation', 100, 0, 200);
          ShaderTrack('RowShaderTemperature', 'Color temperature', '100 is neutral; lower is cooler, higher is warmer.', 'Temperature', 100, 0, 200);
        end;
        if FPreview = nil then
        begin
          BuildVideoPreview;
          TSettingsPreview(FPreview).SetColorPattern;
        end;
        Heading('GroupAudio', 'Audio');
        FNextKind := TSettingsRowKind.Volume;
        FContext.AddSlider('RowVolume', 'Volume', 'Audio level for the selected platform.', 'Audio', 'Volume', 0.5, 0, 100, 100, False);
        var Volume := TTrackBar(FFields.Last.Control);
        FVolumeValue := FLastRow.ValueLabel;
        SetChangeHandler(Volume, VolumeChange);
        VolumeChange(Volume);
        platform.Audio(FContext);
      end
      else if FCategory = SETTINGS_CATEGORY_CONTROLS then
      begin
        Heading('GroupController', 'Controller');
        var Count := platform.PlayerCount(FDrafts[FPage]);
        FPlayer := EnsureRange(FPlayer, 0, Count - 1);
        var Players: TArray<string>;
        SetLength(Players, Count);
        for var I := 0 to Count - 1 do
          Players[I] := Translate('Player ') + IntToStr(I + 1);
        FContext.AddSelection('RowPlayer', 'Player', 'Bindings are saved separately for each player.',
          Players, FPlayer, PlayerChange);
        BuildPort(FPlayer, Translate('Bindings · player ') + IntToStr(FPlayer + 1));
      end
      else if FPage <> SETTINGS_PAGE_GW then
      begin
        platform.Peripherals(FContext);
        for var Port := 0 to platform.Ports - 1 do
          BuildPort(Port, Translate('Port ') + IntToStr(Port + 1));
        platform.Expansion(FContext);
      end;

      LabelStatus.Text := Translate('Settings are saved separately for each platform. Core options apply when you next open a ROM.');
      if platform.HasConfiguration then
        LabelStatus.Text := Translate('Configuration changes stay in this draft until you click Apply. Hardware options apply when you next open a ROM.');
    end;
    WireConfigurationChanges;
  finally
    FBuilding := False;
    UpdateShaderPreview;
    UpdateConfigurationNotice;
    Resize;
    LayoutSettingsMainColumn.EndUpdate;
    LayoutSettingsPreviewColumn.EndUpdate;
    VertScrollBoxScroll.EndUpdate;
    if PreserveScroll then
      VertScrollBoxScroll.ViewportPosition := TPointF.Create(0, EnsureRange(Position.Y, 0,
          Max(0, VertScrollBoxScroll.ContentBounds.Height - VertScrollBoxScroll.ClientHeight)))
    else
      VertScrollBoxScroll.ViewportPosition := TPointF.Zero;
    SearchChange(FSearch);
  end;
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

procedure TSettingsView.WireConfigurationChanges;
begin
  // Every typed binding is wired when it is constructed. Page providers add
  // semantic callbacks without replacing the editor's storage notification.
  for var Field in FFields do
    Field.Load;
  UpdateConditions;
end;

procedure TSettingsView.ConfigurationChange(Sender: TObject);
begin
  if FBuilding then
    Exit;
  for var F in FFields do
    if F.Control = Sender then
    begin
      if not F.Pull then
        Exit; // Ignore delayed notifications from switch animation.
      // Multiple panels can edit a shared setting (for example a keyboard
      // connected through different ports). Keep their editors in agreement.
      FBuilding := True;
      try
        for var Other in FFields do
          if (Other <> F) and SameText(Other.Section, F.Section) and SameText(Other.Key, F.Key) then
            Other.Load;
      finally
        FBuilding := False;
      end;
      if FRebuildPending then
        Exit;
      if Assigned(F.Definition.OnChange) then
        F.Definition.OnChange(Sender)
      else if Assigned(F.ChangeHandler) then
        F.ChangeHandler(Sender)
      else
      begin
        var platform := SettingsPlatforms.Find(FPage);
        if (platform <> nil) and platform.HasConfiguration then
        begin
          LabelStatus.Text := Translate('Configuration changed in the draft. Click Apply to save, or Cancel to discard.');
          StorePage;
          if platform.ChangeConfiguration(FDrafts[FPage], F.Section, F.Key) then
            RequestRebuild
          else
          begin
            FBuilding := True;
            try
              for var Preset in FFields do
                if SameText(Preset.Section, 'Hardware') and SameText(Preset.Key, 'Preset') then
                  Preset.Load;
            finally
              FBuilding := False;
            end;
          end;
          UpdateConfigurationNotice;
        end;
      end;
      UpdateConditions;
      Exit;
    end;
end;

procedure TSettingsView.MeasureConfigurationNotice;
begin
  if not PanelConfigurationNotice.Visible then
    Exit;
  var Layout := TTextLayoutManager.DefaultTextLayout.Create;
  try
    Layout.BeginUpdate;
    Layout.Font.Assign(LabelConfigurationNotice.TextSettings.Font);
    Layout.MaxSize := TPointF.Create(Max(1, PanelConfigurationNotice.Width - 48), 100000);
    Layout.WordWrap := True;
    Layout.Text := LabelConfigurationNotice.Text;
    Layout.EndUpdate;
    LabelConfigurationNotice.Height := Max(24, Ceil(Layout.TextHeight) + 8);
    PanelConfigurationNotice.Height := Min(Max(64, LabelConfigurationNotice.Height + 16),
      Max(64, Min(180, Height * 0.25)));
  finally
    Layout.Free;
  end;
  VertScrollBoxConfigurationNotice.RealignContent;
end;

procedure TSettingsView.UpdateConfigurationNotice;
begin
  var platform := SettingsPlatforms.Find(FPage);
  var Text := '';
  if (platform <> nil) and platform.HasConfiguration then
    Text := platform.ConfigurationNotice(FDrafts[FPage]);
  if LabelConfigurationNotice.Text <> Text then
    VertScrollBoxConfigurationNotice.ViewportPosition := TPointF.Zero;
  LabelConfigurationNotice.Text := Text;
  PanelConfigurationNotice.Visible := Text <> '';
  MeasureConfigurationNotice;
end;

procedure TSettingsView.StorePage;
begin
  for var Field in FFields do
    Field.Pull;
  if (FPage > SETTINGS_PAGE_MAIN) and (FInput <> nil) then
    SaveInputBindings(FInput, FDrafts[FPage]);
end;

procedure TSettingsView.Heading(const Name, Caption: string; Emphasized: Boolean; TitleSize: Single);
begin
  FContext.Heading(Name, Caption, Emphasized, False, TitleSize);
end;

procedure TSettingsView.RenderGroup(Group: TSettingsGroup);
begin
  var Template := TSettingsGroupTemplate.Create(nil);
  Template.Name := '';
  InsertComponent(Template);
  var View := TSettingsGroupView.Create;
  FGroups.Add(View);
  View.Definition := Group;
  View.Template := Template;
  View.Panel := Template.PanelSetting;
  View.Title := Template.LabelSettingTitle;
  View.Title.Text := Translate(Group.Caption);
  View.Title.TextSettings.Font.Size := Group.TitleSize;
  View.Title.StyledSettings := View.Title.StyledSettings - [TStyledSetting.Style];
  if Group.Emphasized then
    View.Title.TextSettings.Font.Style := [TFontStyle.fsBold]
  else
    View.Title.TextSettings.Font.Style := [];
  View.Panel.TagString := View.Title.Text;
  FGroup := View.Panel;
  if Group.Preview then
    FGroup.Parent := LayoutSettingsPreviewColumn
  else
    FGroup.Parent := LayoutSettingsMainColumn;
  FGroup.Position.Y := 0;
  FGroup.OnResize := ContentResize;
  FGroup.Width := VertScrollBoxScroll.Width - 16;
end;

function TSettingsView.Row(const Name, Caption, Description: string; Kind: TSettingsRowKind): TPanel;
begin
  FLastRow := CreateSettingsRow(Self, Kind, Name, Caption, Description);
  FRows.Add(FLastRow);
  Result := FLastRow.Panel;
  Result.Parent := FGroup;
  Result.Position.Y := 0;
  Result.Width := VertScrollBoxScroll.Width - 16;
  Result.OnResize := RowResize;
end;

function TSettingsView.RowView(Panel: TControl): TSettingsRowView;
begin
  Result := nil;
  for var Item in FRows do
    if Item.Panel = Panel then
      Exit(Item);
end;

procedure TSettingsView.ReleasePage;
begin
  FLastRow := nil;
  FNextRow := nil;
  FNextEditor := nil;
  FScaling := nil;
  FPalette := nil;
  FVideoGroup := nil;
  FShaderStatus := nil;
  FBindingDevices.Clear;
  FBlockControls.Clear;
  FSelections.Clear;
  for var D in FDevices do
  begin
    if D.Control is TScreenGamepad then
      TScreenGamepad(D.Control).OnChange := nil;
    if D.Control is TNesPowerPad then
      TNesPowerPad(D.Control).OnChange := nil;
    if D.Control is TNesSuborKeyboard then
      TNesSuborKeyboard(D.Control).OnChange := nil;
    if D.Control is TNesFamicomKeyboard then
      TNesFamicomKeyboard(D.Control).OnChange := nil;
    if D.Control is TNesMiraclePiano then
      TNesMiraclePiano(D.Control).OnChange := nil;
  end;
  // Templates own their detached visual roots. Disconnect every root before
  // releasing its owner; queued FMX events must not see obsolete bindings.
  for var R in FRows do
  begin
    DisconnectSettingsControl(R.Panel);
    R.Panel.Visible := False;
    R.Panel.Parent := nil;
    R.Template.Name := '';
    R.Template.Release;
  end;
  for var G in FGroups do
  begin
    DisconnectSettingsControl(G.Panel);
    G.Panel.Parent := nil;
    G.Template.Name := '';
    G.Template.Release;
  end;
  FFields.Clear;
  FDevices.Clear;
  FRows.Clear;
  FGroups.Clear;
  if FContext <> nil then
    FContext.Clear;
end;

procedure TSettingsView.SetChangeHandler(Control: TControl; Handler: TNotifyEvent);
begin
  for var Binding in FFields do
    if Binding.Control = Control then
    begin
      Binding.ChangeHandler := Handler;
      Exit;
    end;
  raise EArgumentException.Create('Settings control has no binding');
end;

procedure TSettingsView.UpdateConditions;
begin
  for var F in FFields do
  begin
    if Assigned(F.Definition.EnabledWhen) then
      F.Control.Enabled := F.Definition.EnabledWhen();
    if Assigned(F.Definition.VisibleWhen) then
      F.Row.Visible := F.Definition.VisibleWhen();
  end;
  if not FBuilding then
    SearchChange(FSearch);
end;

function TSettingsView.GetPageDefinition: TSettingsPageDefinition;
begin
  Result := FContext.Definition;
end;

procedure TSettingsView.RenderBlock(Definition: TSettingsBlockDefinition);
begin
  var Kind := TSettingsRowKind.Standard;
  if Definition is TSettingsControlDefinition then
    Kind := TSettingsControlDefinition(Definition).RowKind;
  Row(Definition.Id, Definition.Caption, Definition.Description, Kind);
  var R := FLastRow;
  if Definition is TSettingsAction then
  begin
    var Action := TSettingsAction(Definition);
    var Button := SettingsButton(R.Template);
    Button.Parent := TSettingsRowTemplate(R.Template).LayoutSettingEditorSlot;
    TControl(Button.Parent).Margins.Rect := TRectF.Empty;
    Button.Align := TAlignLayout.Client;
    Button.Text := Translate(Action.ActionCaption);
    Button.OnClick := Action.OnExecute;
    R.Editor := Button;
  end
  else if Definition is TSettingsSelection then
  begin
    var Selection := TSettingsSelection(Definition);
    var Combo := TSettingsComboBox.Create(R.Template);
    Combo.Parent := TSettingsRowTemplate(R.Template).LayoutSettingEditorSlot;
    TControl(Combo.Parent).Margins.Rect := TRectF.Empty;
    Combo.Align := TAlignLayout.Client;
    for var Item in Selection.Items do
      Combo.Items.Add(Translate(Item));
    Combo.ItemIndex := Selection.Index;
    FSelections.Add(Combo, Selection);
    Combo.OnChange := SelectionChange;
    Combo.OnResize := ComboResize;
    ComboResize(Combo);
    R.Editor := Combo;
  end
  else if Definition is TSettingsInformation then
  begin
    var LabelValue := SettingsLabel(R.Template);
    LabelValue.Parent := TSettingsRowTemplate(R.Template).LayoutSettingEditorSlot;
    TControl(LabelValue.Parent).Margins.Rect := TRectF.Empty;
    LabelValue.Align := TAlignLayout.Client;
    LabelValue.Text := Translate(TSettingsInformation(Definition).Text);
    R.Editor := LabelValue;
    if TSettingsInformation(Definition).Text = '' then
    begin
      R.Editors.Visible := False;
      R.CustomLayout := True;
    end;
  end
  else if Definition is TSettingsControlDefinition then
  begin
    var Custom := TSettingsControlDefinition(Definition);
    if Assigned(Custom.Factory) then
      R.Editor := Custom.Factory(R);
  end
  else
    raise EArgumentException.Create('Unsupported settings block: ' + Definition.Id);
  FBlockControls.Add(Definition, R.Editor);
end;

function TSettingsView.ControlFor(Block: TSettingsBlockDefinition): TControl;
begin
  if not FBlockControls.TryGetValue(Block, Result) then
    Result := nil;
end;

procedure TSettingsView.SelectionChange(Sender: TObject);
begin
  if FBuilding then
    Exit;
  var Selection: TSettingsSelection;
  if not FSelections.TryGetValue(TComboBox(Sender), Selection) then
    Exit;
  Selection.Index := TComboBox(Sender).ItemIndex;
  if Assigned(Selection.OnChange) then
    Selection.OnChange(Sender);
end;

procedure TSettingsView.RenderField(Definition: TSettingsFieldDefinition);
begin
  var Kind := FNextKind;
  FNextKind := TSettingsRowKind.Standard;
  if Definition.Kind = TSettingsFieldKind.Path then
    Kind := TSettingsRowKind.Path;
  var R := FNextRow;
  FNextRow := nil;
  if R = nil then
  begin
    Row(Definition.Id, Definition.Caption, Definition.Description, Kind);
    R := FLastRow;
  end;
  var C := FNextEditor;
  FNextEditor := nil;
  var Binding: TSettingsBinding;
  case Definition.Kind of
    TSettingsFieldKind.BooleanValue:
      begin
        Binding := TBooleanSettingsBinding.Create;
        if C = nil then
          C := R.Editor;
        if C = nil then
          C := TSwitch.Create(R.Template);
      end;
    TSettingsFieldKind.Choice:
      begin
        Binding := TChoiceSettingsBinding.Create;
        if C = nil then
          C := TSettingsComboBox.Create(R.Template);
      end;
    TSettingsFieldKind.IntegerValue:
      begin
        Binding := TIntegerSettingsBinding.Create;
        if C = nil then
          C := TSettingsSpinBox.Create(R.Template);
      end;
    TSettingsFieldKind.Text, TSettingsFieldKind.Path:
      begin
        Binding := TTextSettingsBinding.Create;
        if C = nil then
          C := R.Editor;
        if C = nil then
          C := TEdit.Create(R.Template);
      end;
    TSettingsFieldKind.Slider:
      begin
        Binding := TSliderSettingsBinding.Create;
        if C = nil then
          C := TSettingsTrackBar.Create(R.Template);
      end;
  else
    raise EArgumentException.Create('Unsupported setting kind');
  end;
  if Definition.SingleLineDescription then
  begin
    R.Title.TextSettings.Trimming := TTextTrimming.Character;
    R.Detail.TextSettings.Trimming := TTextTrimming.Character;
    R.Detail.TextSettings.WordWrap := False;
  end;
  Binding.Definition := Definition;
  Binding.RowView := R;
  Binding.Control := C;
  Binding.Row := R.Panel;
  FFields.Add(Binding);
  if C.Parent = nil then
  begin
    if R.Template is TSettingsRowTemplate then
      C.Parent := TSettingsRowTemplate(R.Template).LayoutSettingEditorSlot
    else if R.Template is TSettingsTrackTemplate then
      C.Parent := TSettingsTrackTemplate(R.Template).LayoutSettingEditorSlot
    else if R.Template is TSettingsVolumeTemplate then
      C.Parent := TSettingsVolumeTemplate(R.Template).LayoutVolumeTrackSlot
    else
      C.Parent := R.Editors;
    // Slots keep the designer independent of runtime editor classes. Their
    // original margins belong to the editor container, not to a second inset.
    if C.Parent <> R.Editors then
      TControl(C.Parent).Margins.Rect := TRectF.Empty;
    C.Align := TAlignLayout.Client;
  end;
  if Definition.Kind = TSettingsFieldKind.BooleanValue then
    if not (R.Template is TSettingsIntervalTemplate) then
      R.Editors.Width := 64;
  if R.Editor = nil then
    R.Editor := C;
  if R.Template is TSettingsVolumeTemplate then
    R.Editor := TSettingsVolumeTemplate(R.Template).LayoutVolumeEditor;
  if C.Name = '' then
    C.Name := Copy(C.ClassName, 2, MaxInt) + Definition.Id + 'Editor';
  C.OnResize := EditorResize;
  Binding.Load;
  case Definition.Kind of
    TSettingsFieldKind.BooleanValue:
      TSwitch(C).OnSwitch := ConfigurationChange;
    TSettingsFieldKind.Choice:
      begin
        TComboBox(C).OnChange := ConfigurationChange;
        C.OnResize := ComboResize;
        ComboResize(C);
      end;
    TSettingsFieldKind.IntegerValue:
      TSpinBox(C).OnChange := ConfigurationChange;
    TSettingsFieldKind.Text, TSettingsFieldKind.Path:
      TEdit(C).OnChangeTracking := ConfigurationChange;
    TSettingsFieldKind.Slider:
      TTrackBar(C).OnChange := ConfigurationChange;
  end;
  if Definition is TPathSetting then
  begin
    {$IFDEF ISMOBILE}
    TEdit(C).ReadOnly := True;{$ENDIF}
    R.Folder := TPathSetting(Definition).Folder;
    TSettingsPathTemplate(R.Template).PathSettingBrowseIcon.Visible := not R.Folder;
    TSettingsPathTemplate(R.Template).PathFolderBrowseIcon.Visible := R.Folder;
    if R.Folder then
      R.Browse.Hint := Translate('Choose folder')
    else
      R.Browse.Hint := Translate('Choose file');
    R.Clear.Visible := TPathSetting(Definition).AllowClear;
    if Definition.SingleLineDescription then
    begin
      TSettingsPathTemplate(R.Template).PathSettingBrowseIcon.Visible := False;
      TSettingsPathTemplate(R.Template).PathFolderBrowseIcon.Visible := False;
      R.Browse.Text := '…';
      R.Clear.Text := '×';
    end;
    R.Clear.Hint := Translate('Clear');
    R.Browse.OnClick := PathClick;
    R.Clear.OnClick := ClearPathClick;
  end;
end;

function TSettingsView.Combo(const Name, Caption, Description, Section, Key: string; const Labels, Values: array of string; const Default: string): TComboBox;
begin
  FContext.AddChoice(Name, Caption, Description, Section, Key, SettingChoices(Labels, Values), Default);
  Result := TComboBox(FFields.Last.Control);
end;

function TSettingsView.Check(const Name, Caption, Description, Section, Key: string; Default: Boolean): TSwitch;
begin
  FContext.AddBoolean(Name, Caption, Description, Section, Key, Default);
  Result := TSwitch(FFields.Last.Control);
end;

function TSettingsView.Number(const Name, Caption, Description, Section, Key: string; Default, Max: Integer): TSpinBox;
begin
  FContext.AddInteger(Name, Caption, Description, Section, Key, Default, Max);
  Result := TSpinBox(FFields.Last.Control);
end;

function TSettingsView.EditText(const Name, Caption, Description, Section, Key, Default: string): TEdit;
begin
  FContext.AddText(Name, Caption, Description, Section, Key, Default);
  Result := TEdit(FFields.Last.Control);
end;

function TSettingsView.PathEdit(const Name, Caption, Description, Section, Key, Default: string; Folder: Boolean): TEdit;
begin
  FContext.AddPath(Name, Caption, Description, Section, Key, Default, Folder);
  Result := TEdit(FFields.Last.Control);
end;

procedure TSettingsView.Resize;
begin
  if (csLoading in ComponentState) or FBuilding or (csDestroying in ComponentState) then
    Exit;

  inherited;
  if (LayoutBody = nil) or FArranging then
    Exit;

  // FMX can call Resize from inside an unfinished parent alignment. Settle
  // once more after that alignment has applied the final column bounds.
  if not FLayoutPending then
  begin
    FLayoutPending := True;
    var Alive: TFunc<Boolean> := FAlive;
    TThread.ForceQueue(nil,
      procedure
      begin
        if not Alive() then
          Exit;
        try
          Resize;
        finally
          FLayoutPending := False;
        end;
      end);
  end;

  FArranging := True;
  try
    PanelSidebar.Visible := Width >= 1050;
    PanelSidebar.Width := 264;
    PanelPlatforms.Visible := (FCategory >= SETTINGS_CATEGORY_VIDEO_AUDIO) and (Width >= 760);
    PanelPlatforms.Width := 216;
    PanelSidebar.Align := TAlignLayout.MostLeft;
    PanelPlatforms.Align := TAlignLayout.Left;
    LayoutBody.Align := TAlignLayout.Client;
    ListBoxNavigation.Visible := PanelSidebar.Visible;
    FPagePicker.Visible := not PanelSidebar.Visible;
    FPlatformPicker.Visible := (FCategory >= SETTINGS_CATEGORY_VIDEO_AUDIO) and not PanelPlatforms.Visible;
    // Settle the sidebar widths before using the header's available width.
    // During a window-state transition the parent can still be realigning.
    Realign;
    TSettingsLayoutAccess(LayoutBody).Realign;
    LabelTitle.Text := Translate(SettingsCategoryNames[FCategory]);
    if FCategory = SETTINGS_CATEGORY_GENERAL then
      LabelTitle.Text := Translate('General settings');
    for var I := Low(FCategoryIcons) to High(FCategoryIcons) do
      if I = FCategory then
        TPath(FCategoryIcons[I]).Stroke.Color := $FFFFB344
      else
        TPath(FCategoryIcons[I]).Stroke.Color := $FFB9C2CC;
    var CompactSearch := LayoutHeader.Width < 740;
    var HeadingRow := LayoutSettingsHeading;
    var CompactSearchSlot := LayoutSettingsCompactSearchSlot;
    CompactSearchSlot.Visible := CompactSearch;
    if CompactSearch then
    begin
      FSearch.Parent := CompactSearchSlot;
      FSearch.Align := TAlignLayout.Client;
      FSearch.Margins.Rect := TRectF.Empty;
    end
    else
    begin
      FSearch.Parent := HeadingRow;
      FSearch.Align := TAlignLayout.Right;
      FSearch.Width := 260;
      FSearch.Margins.Rect := RectF(16, 0, 0, 12);
    end;
    LayoutHeader.Height := 60 + 44 * (Ord(FPagePicker.Visible) + Ord(FPlatformPicker.Visible) + Ord(CompactSearch));
    VertScrollBoxScroll.Align := TAlignLayout.Client;
    FSearch.Visible := True;
    if LayoutContent = nil then
      Exit;

    var CompactReset := LayoutFooter.Width < 520;
    var ResetRow := LayoutSettingsCompactReset;
    ResetRow.Visible := CompactReset and (FCaptureButton = nil);
    if CompactReset then
      ButtonReset.Parent := ResetRow
    else
      ButtonReset.Parent := LayoutSettingsActions;
    ButtonReset.Visible := FCaptureButton = nil;
    LayoutFooter.Height := 96 + 44 * Ord(ResetRow.Visible);
    ButtonRefresh.Visible := (FCategory = SETTINGS_CATEGORY_CONTROLS) and (LayoutFooter.Width >= 700);
    ButtonApply.Visible := FCaptureButton = nil;
    ButtonBack.Visible := FCaptureButton = nil;
    MeasureConfigurationNotice;
    // Header/footer heights determine the viewport. Apply them, then settle
    // the content width before measuring responsive rows and column heights.
    TSettingsLayoutAccess(LayoutBody).Realign;
    LayoutContent.Margins.Right := Max(16, VertScrollBoxScroll.Width - 1240);
    VertScrollBoxScroll.RealignContent;
    LayoutContent.BeginUpdate;
    try
      var Columns := (FCategory = SETTINGS_CATEGORY_VIDEO_AUDIO) and (FPreviewGroup <> nil) and (LayoutContent.Width >= 850);
      if FPreviewGroup <> nil then
        if Columns then
          FPreviewGroup.Parent := LayoutSettingsPreviewColumn
        else
        begin
          FPreviewGroup.Parent := LayoutSettingsMainColumn;
          // Keep the preview next to its image settings in the single column.
          var VideoGroup := FVideoGroup;
          FPreviewGroup.Index := VideoGroup.Index + 1;
        end;
      LayoutSettingsPreviewColumn.Visible := Columns and (FPreviewGroup <> nil) and FPreviewGroup.Visible;
      if Columns then
      begin
        LayoutSettingsPreviewColumn.Align := TAlignLayout.Right;
        LayoutSettingsPreviewColumn.Margins.Rect := TRectF.Create(16, 0, 0, 0);
        LayoutSettingsPreviewColumn.Width := LayoutContent.Width * 0.38 - 8;
        LayoutSettingsMainColumn.Align := TAlignLayout.Client;
        LayoutSettingsMainColumn.Width := Max(0, LayoutContent.Width - LayoutSettingsPreviewColumn.Width - 16);
      end
      else
      begin
        LayoutSettingsMainColumn.Align := TAlignLayout.MostTop;
        LayoutSettingsPreviewColumn.Align := TAlignLayout.Top;
        // The last main card already contributes the shared 16px bottom margin.
        LayoutSettingsPreviewColumn.Margins.Rect := TRectF.Empty;
        LayoutSettingsMainColumn.Width := LayoutContent.Width;
        LayoutSettingsPreviewColumn.Width := LayoutContent.Width;
      end;
      var MainHeight: Single := 0;
      var PreviewHeight: Single := 0;
      for var Column in [LayoutSettingsMainColumn, LayoutSettingsPreviewColumn] do
      begin
        Column.BeginUpdate;
        try
          for var I := 0 to Column.ChildrenCount - 1 do
            if Column.Children[I] is TPanel then
            begin
              var Card := TPanel(Column.Children[I]);
              if not Card.Visible then
                Continue;
              // A resize can arrive while FMX is already aligning this column.
              // Use the real stack offset, since a nested Realign is skipped.
              if Column = LayoutSettingsMainColumn then
                Card.Position.Y := MainHeight
              else
                Card.Position.Y := PreviewHeight;
              Card.Width := Column.Width;
              ArrangeGroup(Card);
              if Column = LayoutSettingsMainColumn then
                MainHeight := MainHeight + Card.Height + Card.Margins.Top + Card.Margins.Bottom
              else
                PreviewHeight := PreviewHeight + Card.Height + Card.Margins.Top + Card.Margins.Bottom;
            end;
        finally
          Column.EndUpdate;
        end;
      end;
      LayoutSettingsMainColumn.Height := MainHeight;
      LayoutSettingsPreviewColumn.Height := PreviewHeight;
      if Columns then
        LayoutContent.Height := Max(MainHeight, PreviewHeight)
      else if LayoutSettingsPreviewColumn.Visible then
        LayoutContent.Height := MainHeight + PreviewHeight + LayoutSettingsPreviewColumn.Margins.Top
      else
        LayoutContent.Height := MainHeight;
    finally
      LayoutContent.EndUpdate;
    end;
    // Publishing the measured height must also refresh the scroll range;
    // FMX may have cached it earlier in the native window resize sequence.
    VertScrollBoxScroll.RealignContent;
  finally
    FArranging := False;
  end;
end;

procedure TSettingsView.ArrangeGroup(Group: TPanel);
begin
  Group.BeginUpdate;
  try
    // Group padding and Top-aligned rows are shared by every platform.
    Group.Padding.Rect := TRectF.Create(16, 14, 16, 12);
    var ContentHeight: Single := 0;
    for var Child in Group.Children do
      if (Child is TControl) and ((Child is TLabel) or (RowView(TControl(Child)) <> nil)) then
      begin
        var C := TControl(Child);
        C.Align := TAlignLayout.Top;
        C.Position.Y := Group.Padding.Top + ContentHeight;
        C.Margins.Rect := TRectF.Create(0, 0, 0, 6);
        if C is TPanel then
        begin
          C.Width := Max(0, Group.Width - 32);
          if (RowView(C) <> nil) and RowView(C).CustomLayout then
            DeviceResize(C)
          else
            RowResize(C);
        end;
        if C.Visible then
          ContentHeight := ContentHeight + C.Height + C.Margins.Bottom;
      end;
    Group.Height := ContentHeight + Group.Padding.Top + Group.Padding.Bottom;
  finally
    Group.EndUpdate;
  end;
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
  var R := RowView(P);
  if (R = nil) or R.CustomLayout then
    Exit;
  P.Padding.Rect := TRectF.Create(16, 12, 16, 12);
  var Text := R.Text;
  var Editors := R.Editors;
  Text.Align := TAlignLayout.Client;
  Text.Margins.Rect := TRectF.Empty;
  R.Detail.Visible := True;
  var Narrow := P.Width < 600;
  P.Height := IfThen(Narrow, 134, 72);
  var W: Single := 220;
  if R.Editor <> nil then
  begin
    var Editor := R.Editor;
    if Editor is TSwitch then
      W := 64
    else if Editor is TLayout then
      W := 268;
    if Narrow and (Editor is TSwitch) then
    begin
      Editor.Align := TAlignLayout.Right;
      Editor.Width := 64;
    end
    else
      Editor.Align := TAlignLayout.Client;
    Editor.Margins.Rect := TRectF.Empty;
  end;
  if Narrow then
  begin
    Editors.Align := TAlignLayout.Bottom;
    Editors.Height := 32;
    Editors.Margins.Rect := TRectF.Create(0, 8, 0, 0);
  end
  else
  begin
    Editors.Align := TAlignLayout.Right;
    Editors.Width := Min(W, Max(0, P.Width - 32));
    Editors.Margins.Rect := TRectF.Create(16, 8, 0, 8);
  end;
  // Mobile FMX can resize aligned rows after the view's layout pass. Keep
  // card and scroll-content heights in sync with those final row sizes.
  if not FBuilding and not FArranging then
    Resize;
end;

procedure TSettingsView.DeviceResize(Sender: TObject);
begin
  if FDeviceArranging or (FDevices = nil) or (csDestroying in ComponentState) then
    Exit;
  FDeviceArranging := True;
  try
    var P := TPanel(Sender);
    for var D in FDevices do
      if (D.Control <> nil) and (D.Control.Owner = P) then
      begin
        var Slot := D.Template.LayoutBindingPreview;
        Slot.Visible := (D.Assignments = nil) or (P.Width >= 600);
        Slot.Align := TAlignLayout.Client;
        P.Height := 460;
        if D.Assignments <> nil then
        begin
          D.Assignments.Visible := True;
          D.Assignments.Align := TAlignLayout.Client;
          D.Assignments.Margins.Rect := TRectF.Create(0, 8, 0, 8);
          var BodyHeight := D.AssignmentList.Height + D.Assignments.Margins.Top + D.Assignments.Margins.Bottom;
          if Slot.Visible then
            if P.Width >= 850 then
            begin
              D.Assignments.Align := TAlignLayout.Right;
              D.Assignments.Width := 248;
              D.Assignments.Margins.Left := 12;
              BodyHeight := Max(BodyHeight, 280 + Slot.Margins.Top + Slot.Margins.Bottom);
            end
            else
            begin
              Slot.Align := TAlignLayout.Top;
              Slot.Height := 280;
              BodyHeight := BodyHeight + Slot.Height + Slot.Margins.Top + Slot.Margins.Bottom;
            end;
          var Header := D.RowView.Text;
          var Footer := D.Template.LayoutBindingFooter;
          P.Height := P.Padding.Top + P.Padding.Bottom +
            Header.Height + Header.Margins.Top + Header.Margins.Bottom +
            BodyHeight + Footer.Height + Footer.Margins.Top + Footer.Margins.Bottom;
        end;
        if D.Diagram is TDeviceCallouts then
          TDeviceCallouts(D.Diagram).ShowAnnotations(True);
      end;
  finally
    FDeviceArranging := False;
  end;
end;

procedure TSettingsView.BindingFooterResize(Sender: TObject);
begin
  var Footer := TLayout(Sender);
  var Device: TSettingsDevice := nil;
  for var D in FDevices do
    if D.Template.LayoutBindingFooter = Footer then
      Device := D;
  if Device = nil then
    Exit;
  var Caption := Device.Template.LabelBindingCaption;
  var Editors := Device.Template.LayoutPadEditors;
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

procedure TSettingsView.SelectCategory(Index: Integer);
begin
  if FBuilding or (Index < Low(SettingsCategoryNames)) or (Index > High(SettingsCategoryNames)) or (Index = FCategory) then
    Exit;

  StorePage;
  FCategory := Index;
  if Index < SETTINGS_CATEGORY_VIDEO_AUDIO then
    FPage := SETTINGS_PAGE_MAIN
  else
    FPage := FCorePage;
  FBuilding := True;
  try
    ListBoxNavigation.ItemIndex := Index;
    FPagePicker.ItemIndex := Index;
  finally
    FBuilding := False;
  end;
  FSearch.Text := '';
  BuildPage;
end;

procedure TSettingsView.SelectCore(Index: Integer; PreserveCategory: Boolean);
begin
  if FBuilding or (SettingsPlatforms.Find(Index) = nil) then
    Exit;

  StorePage;
  FCorePage := Index;
  FPlayer := 0;
  if (FCategory < SETTINGS_CATEGORY_VIDEO_AUDIO) and not PreserveCategory then
    FCategory := SETTINGS_CATEGORY_VIDEO_AUDIO;
  if FCategory < SETTINGS_CATEGORY_VIDEO_AUDIO then
    FPage := SETTINGS_PAGE_MAIN
  else
    FPage := FCorePage;
  FBuilding := True;
  try
    ListBoxNavigation.ItemIndex := FCategory;
    FPagePicker.ItemIndex := FCategory;
  finally
    FBuilding := False;
  end;
  SyncPlatformSelection;
  BuildPage;
end;

procedure TSettingsView.NavigationChange(Sender: TObject);
begin
  // TListBox.OnChange passes the selected item as Sender.
  SelectCategory(ListBoxNavigation.ItemIndex);
end;

procedure TSettingsView.PagePickerChange(Sender: TObject);
begin
  SelectCategory(FPagePicker.ItemIndex);
end;

procedure TSettingsView.RefreshPlatformList;
begin
  var WasBuilding := FBuilding;
  FBuilding := True;
  ListBoxPlatforms.BeginUpdate;
  try
    while ListBoxPlatforms.Count > 0 do
      RetireSettingsControl(ListBoxPlatforms.ListItems[0]);
    FPlatformPicker.Items.Clear;
    var Brand := '';
    var Matches := SettingsPlatforms.Matching(FPlatformSearch.Text);
    for var platform in Matches do
    begin
      if Brand <> platform.Brand then
      begin
        Brand := platform.Brand;
        var Header := TListBoxGroupHeader.Create(ListBoxPlatforms);
        Header.Parent := ListBoxPlatforms;
        Header.Text := Brand;
        Header.Height := 36;
        Header.HitTest := False;
        Header.Selectable := False;
      end;
      var Item := TListBoxItem.Create(ListBoxPlatforms);
      Item.Parent := ListBoxPlatforms;
      Item.Name := 'ListBoxItemPlatform' + IntToStr(platform.PageId);
      Item.Tag := platform.PageId;
      Item.Text := Translate(platform.Name);
      Item.Height := 44;
      Item.TextSettings.HorzAlign := TTextAlign.Leading;
      Item.TextSettings.Trimming := TTextTrimming.Character;
      Item.TextSettings.WordWrap := False;
      Item.StylesData['text.Margins.Left'] := 44;
      CreatePlatformIcon(Item, platform.CoreId);
      Item.StyleLookup := 'listboxitemstyle';
      if platform.PageId = FCorePage then
        ListBoxPlatforms.ItemIndex := Item.Index;
    end;
    // The compact selector remains complete even when the sidebar is filtered.
    for var platform in SettingsPlatforms.Matching('') do
    begin
      var Index := FPlatformPicker.Items.AddObject(platform.Brand + ' · ' + Translate(platform.Name), platform);
      if platform.PageId = FCorePage then
        FPlatformPicker.ItemIndex := Index;
    end;
    LabelNoPlatforms.Visible := Length(Matches) = 0;
    LabelNoPlatforms.Text := Translate('No platforms found');
    FPlatformSearch.TextPrompt := Translate('Search platforms');
  finally
    ListBoxPlatforms.EndUpdate;
    FBuilding := WasBuilding;
  end;
end;

procedure TSettingsView.PlatformSearchChange(Sender: TObject);
begin
  if not FBuilding then
    RefreshPlatformList;
end;

procedure TSettingsView.SyncPlatformSelection;
begin
  var WasBuilding := FBuilding;
  FBuilding := True;
  try
    ListBoxPlatforms.ItemIndex := -1;
    for var I := 0 to ListBoxPlatforms.Count - 1 do
      if ListBoxPlatforms.ListItems[I].Tag = FCorePage then
      begin
        ListBoxPlatforms.ItemIndex := I;
        Break;
      end;
    for var I := 0 to FPlatformPicker.Items.Count - 1 do
      if TSettingsPlatform(FPlatformPicker.Items.Objects[I]).PageId = FCorePage then
      begin
        FPlatformPicker.ItemIndex := I;
        Break;
      end;
  finally
    FBuilding := WasBuilding;
  end;
end;

procedure TSettingsView.PlatformSelectionChange(Sender: TObject);
begin
  if not FBuilding and (ListBoxPlatforms.Selected <> nil) and
    (ListBoxPlatforms.Selected.Tag > 0) then
    SelectCore(ListBoxPlatforms.Selected.Tag, True);
end;

procedure TSettingsView.PlatformPickerChange(Sender: TObject);
begin
  if not FBuilding and (FPlatformPicker.ItemIndex >= 0) then
    SelectCore(TSettingsPlatform(FPlatformPicker.Items.Objects[FPlatformPicker.ItemIndex]).PageId, True);
end;

procedure TSettingsView.SearchChange(Sender: TObject);
begin
  if FBuilding or (LayoutContent = nil) then
    Exit;
  var Query := FSearch.Text.Trim.ToLower;
  for var Group in FGroups do
  begin
    var ShowGroup := Query = '';
    var GroupAllowed := not Assigned(Group.Definition.VisibleWhen) or Group.Definition.VisibleWhen();
    for var Row in FRows do
      if Row.Panel.Parent = Group.Panel then
      begin
        var Allowed := True;
        for var Binding in FFields do
          if (Binding.RowView = Row) and Assigned(Binding.Definition.VisibleWhen) then
            Allowed := Allowed and Binding.Definition.VisibleWhen();
        Row.Panel.Visible := Allowed and ((Query = '') or
          Row.Panel.TagString.ToLower.Contains(Query) or Group.Panel.TagString.ToLower.Contains(Query));
        ShowGroup := ShowGroup or Row.Panel.Visible;
      end;
    Group.Panel.Visible := GroupAllowed and ShowGroup;
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

procedure TSettingsView.BuildPort(Port: Integer; const Caption: string);
begin
  if FCategory <> SETTINGS_CATEGORY_CONTROLS then
    Heading('GroupPort' + IntToStr(Port + 1), 'Port ' + IntToStr(Port + 1), Port < 2);
  var Key := 'Port' + IntToStr(Port + 1);
  if FPage = SETTINGS_PAGE_GW then
  begin
    // The handheld's controls are built in; only host input bindings are configurable.
    FDrafts[FPage].WriteString('Ports', Key, 'pad');
    BuildBindings(Port, 'pad');
    Exit;
  end;
  var Device := FDrafts[FPage].ReadString('Ports', Key, 'auto');
  var Options := SettingsPlatforms.Find(FPage).PortOptions(Port);
  var C := Combo(Options.RowName, Options.Caption, Options.Description, 'Ports', Key,
    Options.Labels, Options.Values, Options.Default);
  if Options.SingleLineDescription then
  begin
    FFields.Last.Definition.SingleLineDescription := True;
    FFields.Last.RowView.Detail.TextSettings.WordWrap := False;
    FFields.Last.RowView.Detail.TextSettings.Trimming := TTextTrimming.Character;
  end;
  // Normalize absent legacy values to the device displayed by the selector.
  for var F in FFields do
    if F.Control = C then
      Device := F.Values[C.ItemIndex];
  SetChangeHandler(C, PortChange);
  if FCategory = SETTINGS_CATEGORY_CONTROLS then
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
  if (FPage = SETTINGS_PAGE_NES) and (Port = 4) then
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
  var Source := Combo('RowInputsource' + IntToStr(Port), 'Input source', 'Choose a device, then assign its buttons, axes or D-pad.', 'Ports', SourceKey, Labels, Values, '');
  FDeviceIds[Port] := SavedId;
  Source.Tag := Port;
  SetChangeHandler(Source, DeviceChange);
  Source.Enabled := FInput <> nil;
  if (Device = 'piano') then
  begin
    Check('RowPhysicalkeyboard2' + IntToStr(Port), 'Physical keyboard', 'Notes Z'#8211'M and Q'#8211'P; Space is the pedal. An on-screen piano is als' + 'o available.', 'Ports',
      'KeyboardEnabled', True);
  end;
  if Device = 'zapper' then
    AddBinding(Translate('Zapper trigger'), ZapperTriggerAction, Port)
  else
    BuildDevice(Port, Device);
end;

function TSettingsView.AddBinding(const Caption: string; Action, Port: Integer): TButton;
begin
  var Capture: TButton := nil;
  AddSettingsControl(FContext, 'RowBinding' + IntToStr(Port), 'Zapper trigger',
    'Click Assign, then press a button or direction on the device.', TSettingsRowKind.Binding,
    function(R: TSettingsRowView): TControl
    begin
      var Template := TSettingsBindingTemplate(R.Template);
      Capture := Template.ButtonBindingEditorsCapture;
      Capture.Text := Translate('Assign · ') + BindingCaption(FInput, Action);
      Capture.Tag := Action;
      Capture.TagString := IntToStr(Port);
      Capture.OnClick := CaptureClick;
      Capture.Enabled := FInput <> nil;
      var Clear := Template.ButtonBindingEditorsClear;
      Clear.Tag := Action;
      Clear.OnClick := ClearBindingClick;
      Clear.Enabled := FInput <> nil;
      Result := Template.LayoutBindingEditors;
    end);
  Result := Capture;
end;

procedure TSettingsView.AddDeviceAssignment(Device: TSettingsDevice; Panel: TPanel; Action: Integer; const Caption: string);
begin
  var Binding := SettingsButton(Panel);
  Binding.Parent := Device.AssignmentList;
  Binding.Align := TAlignLayout.Top;
  Binding.Height := 32;
  Binding.Margins.Rect := RectF(8, 4, 8, 4);
  Binding.Index := Device.AssignmentList.ChildrenCount - 1;
  Binding.Tag := Action;
  FBindingDevices.Add(Binding, Device);
  Binding.TagString := Caption;
  Binding.Text := Translate(Caption) + '   ·   ' + BindingCaption(FInput, Action);
  Binding.OnClick := AssignmentClick;
  Binding.Enabled := FInput <> nil;
end;

procedure TSettingsView.BuildDevice(Port: Integer; const Device: string);
begin
  Heading('GroupBindings' + IntToStr(Port), 'Bindings');
  AddSettingsControl(FContext, 'RowButtonbindings' + IntToStr(Port), 'Button bindings',
    'Select a button on the diagram, then press a key or controller button.', TSettingsRowKind.Device,
    function(R: TSettingsRowView): TControl
    begin
      var D := TSettingsDevice.Create;
      FDevices.Add(D);
      D.Port := Port;
      D.Device := Device;
      var P := R.Panel;
      D.RowView := R;
      D.Template := TSettingsDeviceTemplate(R.Template);
      D.RowView.CustomLayout := True;
      P.Height := 340;
      var Text := D.RowView.Text;
      Text.Align := TAlignLayout.Top;
      Text.Height := 34;
      D.RowView.Detail.Visible := False;
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
        Pad.Configure(TPlatformRegistry.Require(SettingsCoreIds[FPage]).System, Device,
          CoreButtons(SettingsCoreIds[FPage], Device));
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
      D.Template.LayoutPadAssignments.Visible := False;
      if (FPage = SETTINGS_PAGE_GW) or (D.Control is TScreenGamepad) then
      begin
        D.Assignments := D.Template.LayoutPadAssignments;
        D.Assignments.Visible := True;
        D.AssignmentList := D.Template.LayoutPadAssignmentList;
        var Y: Single := 8;
        for var B in CoreButtons(SettingsCoreIds[FPage], Device) do
        begin
          AddDeviceAssignment(D, P, PadAction(Port, B), CoreButtonName(SettingsCoreIds[FPage], B));
          Y := Y + 40;
        end;
        if SettingsCoreIds[FPage] = ROM_SYSTEM_N64 then
        begin
          AddDeviceAssignment(D, P, N64LAction + Port, 'L');
          Y := Y + 40;
        end;
        // A digital pad has only L2 beyond the logical pad.
        if SettingsCoreIds[FPage] = ROM_SYSTEM_PS1 then
          for var Extra := Low(TPS1Extra) to High(TPS1Extra) do
            if (Extra = TPS1Extra.L2) or (Device = 'pad-analog') then
            begin
              AddDeviceAssignment(D, P, PS1Action(Port, Extra), PS1ExtraName(Extra));
              Y := Y + 40;
            end;
        if SettingsCoreIds[FPage] = ROM_SYSTEM_DC then
          for var Extra := Low(TDCExtra) to High(TDCExtra) do
          begin
            AddDeviceAssignment(D, P, DCAction(Port, Extra), DCExtraName(Extra));
            Y := Y + 40;
          end;
        D.AssignmentList.Height := Y;
      end;
      Preview.Parent := D.Template.LayoutBindingPreview;
      Preview.Align := TAlignLayout.Client;
      Preview.Margins.Rect := TRectF.Empty;
      D.Control.Tag := Port;
      // Keep the editor inside this card. No button is selected until the user clicks.
      var Footer := D.Template.LayoutBindingFooter;
      D.Caption := D.Template.LabelBindingCaption;
      D.Caption.Text := '';
      D.Capture := D.Template.ButtonPadEditorsCapture;
      D.Capture.Text := Translate('Assign');
      D.Capture.Tag := -1;
      D.Capture.TagString := IntToStr(Port);
      D.Capture.OnClick := CaptureClick;
      D.Capture.Enabled := FInput <> nil;
      D.Capture.Visible := False;
      D.Clear := D.Template.ButtonPadEditorsClear;
      D.Clear.Tag := -1;
      D.Clear.OnClick := ClearBindingClick;
      D.Clear.Enabled := FInput <> nil;
      D.Clear.Visible := False;
      Footer.OnResize := BindingFooterResize;
      BindingFooterResize(Footer);
      P.OnResize := DeviceResize;
      DeviceResize(P);
      Result := D.Control;
    end);
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
          B.Text := Translate(B.TagString) + '   ·   ' + BindingCaption(FInput, B.Tag);
        end;
    if (D.Capture.Tag >= 0) and (D.Capture <> FCaptureButton) then
      D.Capture.Text := Translate('Assign · ') + BindingCaption(FInput, D.Capture.Tag);
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

procedure TSettingsView.AssignmentClick(Sender: TObject);
begin
  var B := TButton(Sender);
  var Device: TSettingsDevice;
  if FBindingDevices.TryGetValue(B, Device) then
    SelectBinding(Device, B.Tag, Translate('Button ') + B.TagString);
end;

procedure TSettingsView.CalloutClick(Sender: TObject);
begin
  if FBuilding or (FInput = nil) then
    Exit;

  var LabelControl := TLabel(Sender);
  for var D in FDevices do
    if (D.Diagram = LabelControl.Parent) or ((LabelControl.Parent <> nil) and (D.Diagram = LabelControl.Parent.Parent)) then
    begin
      SelectBinding(D, LabelControl.Tag, LabelControl.TagString);
      Exit;
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
      begin
        if (SettingsCoreIds[FPage] = ROM_SYSTEM_N64) and
          ((TScreenGamepad(Sender).AuxiliaryButtons and 1) <> 0) then
        begin
          Action := N64LAction + D.Port;
          Caption := Translate('Button ') + 'L';
        end;
        if SettingsCoreIds[FPage] = ROM_SYSTEM_PS1 then
          for var Extra := Low(TPS1Extra) to High(TPS1Extra) do
            if (TScreenGamepad(Sender).AuxiliaryButtons and (1 shl Ord(Extra))) <> 0 then
            begin
              Action := PS1Action(D.Port, Extra);
              Caption := Translate('Button ') + Translate(PS1ExtraName(Extra));
            end;
        for var B in TScreenGamepad(Sender).Buttons do
          if B in CoreButtons(SettingsCoreIds[FPage], D.Device) then
          begin
            Action := PadAction(D.Port, B);
            Caption := Translate('Button ') + Translate(CoreButtonName(SettingsCoreIds[FPage], B));
            Break;
          end;
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

procedure TSettingsView.PortChange(Sender: TObject);
begin
  if FBuilding then
    Exit;

  StorePage;
  RequestRebuild;
end;

procedure TSettingsView.CaptureClick(Sender: TObject);
begin
  if (FInput = nil) or (TButton(Sender).Tag < 0) then
    Exit;

  CancelCapture;
  FCaptureButton := TButton(Sender);
  FCaptureAction := FCaptureButton.Tag;
  var Port := StrToIntDef(FCaptureButton.TagString, 0);
  FHostInput.Poll;
  FInput.BeginCapture(FCaptureAction, FDeviceIds[Port]);
  FCaptureDeadline := TThread.GetTickCount64 + 10000;
  LabelStatus.Text := Translate('Press a button or direction. Esc cancels. Waiting: 10 seconds.');
  FCaptureButton.Text := Translate('Waiting for input…');
  ButtonCancelCapture.Visible := True;
  Resize;
end;

procedure TSettingsView.ClearBindingClick(Sender: TObject);
begin
  CancelCapture;
  FInput.RemoveBindings(TButton(Sender).Tag);
  StorePage;
  RefreshBindings;
  LabelStatus.Text := Translate('Binding removed. Click Apply.');
  Resize;
end;

procedure TSettingsView.CancelCapture;
begin
  if FInput <> nil then
    FInput.CancelCapture;
  if FCaptureButton <> nil then
    FCaptureButton.Text := Translate('Assign · ') + BindingCaption(FInput, FCaptureAction);
  FCaptureButton := nil;
  if ButtonCancelCapture <> nil then
    ButtonCancelCapture.Visible := False;
end;

procedure TSettingsView.CancelCaptureClick(Sender: TObject);
begin
  CancelCapture;
  LabelStatus.Text := Translate('Binding cancelled.');
  Resize;
end;

function TSettingsView.HandleCaptureKeyDown(var Key: Word; var KeyChar: WideChar): Boolean;
begin
  Result := FCaptureButton <> nil;
  if not Result then
    Exit;

  // Native input captures the physical key. Do not also let the focused editor
  // change the source, move focus, or restart capture with Enter/Space.
  if Key = vkEscape then
    CancelCaptureClick(Self);
  Key := 0;
  KeyChar := #0;
end;

procedure TSettingsView.Poll;
begin
  if FInput = nil then
    Exit;

  FInput.Enabled := FHostInput.Enabled;
  FInput.Poll;
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
    LabelStatus.Text := Translate('Binding saved in the draft. Click Apply.');
    Resize;
  end
  else if TThread.GetTickCount64 >= FCaptureDeadline then
    CancelCaptureClick(Self);
end;

procedure TSettingsView.VolumeChange(Sender: TObject);
begin
  if FVolumeValue <> nil then
    FVolumeValue.Text := IntToStr(Round(TTrackBar(Sender).Value)) + '%';
end;

procedure TSettingsView.PreviewChange(Sender: TObject);
begin
  if FBuilding then
    Exit;
  StorePage;
  if (FPalette <> nil) and (FPreview is TSettingsPreview) then
    TSettingsPreview(FPreview).PaletteIndex :=
      FPalette.ItemIndex;
  UpdateShaderPreview;
end;

procedure TSettingsView.ResetClick(Sender: TObject);
begin
  CancelCapture;
  for var Field in FFields do
    Field.Definition.Reset;
  if (FCategory = SETTINGS_CATEGORY_CONTROLS) and (FInput <> nil) then
  begin
    FDrafts[FPage].DeleteKey('FMXInput', 'Bindings');
    LoadInputBindings(FInput, FDrafts[FPage], SettingsCoreIds[FPage]);
    SaveInputBindings(FInput, FDrafts[FPage]);
  end;
  BuildPage;
  LabelStatus.Text := Translate('Section reset. Click Apply to save.');
end;

procedure TSettingsView.PathClick(Sender: TObject);
begin
  CancelCapture;
  var Button := TEditButton(Sender);
  var Row: TSettingsRowView := nil;
  for var R in FRows do
    if R.Browse = Button then
      Row := R;
  if Row = nil then
    Exit;
  var Edit := TEdit(Row.Editor);
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
  FPickingBootROM := Section = 'Boot';
  FPickingTranslation := (Section = 'General') and (Key = 'TranslationFile');
  PickLocation(Row.Folder, Edit.Text,
    procedure(const Selection: TStorageSelection)
    begin
      if not Alive() then
        Exit;

      if Selection.Error <> '' then
        LabelStatus.Text := Selection.Error
      else if not Selection.Cancelled then
      begin
        FDrafts[Page].WriteString(Section, Key, Selection.Location);
        if FPage = Page then
          for var F in FFields do
            if (F.Section = Section) and (F.Key = Key) then
              TEdit(F.Control).Text := Selection.Location;
        LabelStatus.Text := Translate('Click Apply to save changes.');
      end;
    end);
end;

procedure TSettingsView.DetectRomFoldersClick(Sender: TObject);
begin
  CancelCapture;
  StorePage;
  var Alive: TFunc<Boolean> := FAlive;
  PickLocation(True, '',
    procedure(const Selection: TStorageSelection)
    begin
      if not Alive() then
        Exit;
      if Selection.Error <> '' then
        LabelStatus.Text := Selection.Error
      else if not Selection.Cancelled then
      try
        var Count := 0;
        for var platform in TPlatformRegistry.All do
        begin
          var Folder := FStorage.DetectRomFolder(Selection.Location, platform.Id);
          if Folder = '' then
            Continue;
          FDrafts[SETTINGS_PAGE_MAIN].WriteString('RomFolders', platform.Id, Folder);
          Inc(Count);
        end;
        if (FPage = SETTINGS_PAGE_MAIN) and (FCategory = SETTINGS_CATEGORY_LIBRARY) then
          BuildPage(True);
        LabelStatus.Text := Format(Translate('Platform folders found: %d. Click Apply to save changes.'), [Count]);
      except
        on E: Exception do
          LabelStatus.Text := E.Message;
      end;
    end);
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
      if FPickingTranslation then
      begin
        Dialog.Title := Translate('Choose translation file');
        Dialog.Filter := Translate('Translation files (*.txt;*.lng)|*.txt;*.lng|All files|*.*');
      end
      else if FPickingBootROM then
      begin
        Dialog.Title := Translate('Choose boot ROM');
        Dialog.Filter := 'Boot ROM (*.bin;*.rom;*.gb)|*.bin;*.rom;*.gb|All files|*.*';
      end
      else
      begin
        Dialog.Title := Translate('Choose cassette');
        Dialog.Filter := Translate('Cassettes (*.tape)|*.tape|All files|*.*');
      end;
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

procedure TSettingsView.PickTemplateLocation(const Callback: TStorageSelectionCallback);
begin
  if Assigned(FTemplatePicker) then
  begin
    FTemplatePicker('lang_template.txt', Callback);
    Exit;
  end;
  var Dialog := TFMXOpenDialog.Create(nil);
  try
    Dialog.Title := Translate('Save translation template');
    Dialog.Filter := Translate('Text files (*.txt)|*.txt|All files|*.*');
    Dialog.MimeType := 'text/plain';
    Dialog.SaveFile('lang_template.txt',
      procedure(const Selection: TFMXSelectionResult)
      begin
        var Result := Default(TStorageSelection);
        Result.Cancelled := Selection.Status = TFMXSelectionStatus.Cancelled;
        Result.Error := Selection.Error;
        if Selection.Status = TFMXSelectionStatus.Selected then
          Result.Location := Selection.Locations[0];
        Callback(Result);
      end);
  finally
    Dialog.Free;
  end;
end;

procedure TSettingsView.SaveTemplateClick(Sender: TObject);
begin
  CancelCapture;
  var Alive: TFunc<Boolean> := FAlive;
  try
    PickTemplateLocation(
      procedure(const Selection: TStorageSelection)
      begin
        if not Alive() or Selection.Cancelled then
          Exit;
        try
          if Selection.Error <> '' then
            raise Exception.Create(Selection.Error);
          FormStyles.SaveTranslationTemplate(FStorage, Selection.Location);
          LabelStatus.Text := Translate('Translation template saved.');
        except
          on E: Exception do
            LabelStatus.Text := Translate('Unable to save translation template: ') + E.Message;
        end;
      end);
  except
    on E: Exception do
      LabelStatus.Text := Translate('Unable to save translation template: ') + E.Message;
  end;
end;

procedure TSettingsView.ApplyClick(Sender: TObject);
begin
  try
    CancelCapture;
    StorePage;
    FContext.Validate;
    var Translation := FormStyles.LoadTranslation(FStorage,
      FDrafts[SETTINGS_PAGE_MAIN].ReadString('General', 'TranslationFile', '').Trim,
      FDrafts[SETTINGS_PAGE_MAIN].ReadString('General', 'Language', 'en'));
    Translation.Free; // Validate the file before writing any settings.
    for var platform in TPlatformRegistry.All do
    begin
      var Folder := FDrafts[SETTINGS_PAGE_MAIN].ReadString('RomFolders', platform.Id, '').Trim;
      if (Folder <> '') and not FStorage.FolderExists(Folder) then
        raise Exception.Create(platform.Name + ': ' + Translate('ROM folder not found. Choose an existing folder.'));
    end;
    FDrafts[SETTINGS_PAGE_MAIN].DeleteKey('General', 'Path');

    for var platform in SettingsPlatforms.Items do
    begin
      var Draft := FDrafts[platform.PageId];
      Draft.DeleteKey('Audio', 'Enabled');
      Draft.DeleteKey('Audio', 'FMEnabled');
      Draft.DeleteKey('SegaCD', 'AudioEnabled');
      Draft.DeleteKey('Sega32X', 'AudioEnabled');
      platform.Validate(Draft);
    end;

    // Config writes are per core and retain all settings that this UI does not expose.
    FSession.Save;
    if Assigned(FOnApply) then
      FOnApply(Self);
    LabelStatus.Text := Translate('Saved. Runtime settings applied. Hardware and boot options apply when you next open a ROM.');
  except
    on E: Exception do
      LabelStatus.Text := Translate('Unable to save settings: ') + E.Message;
  end;
  UpdateConfigurationNotice;
end;

procedure TSettingsView.ApplyLanguage(const PreviousLanguage: string);
begin
  FBuilding := True;
  try
    FormStyles.RelocalizeUI(Self, PreviousLanguage);
  finally
    FBuilding := False;
  end;
  RefreshPlatformList;
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

