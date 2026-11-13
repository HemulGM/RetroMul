unit RM.LibraryView;

{$I ..\RM.Mobile.inc}

interface

uses
  System.SysUtils, System.Classes, System.Types, System.UITypes,
  System.Generics.Collections, System.IniFiles, FMX.Types, FMX.Controls,
  FMX.Forms, FMX.Layouts, FMX.StdCtrls, FMX.Edit, FMX.Objects, Core.Storage,
  FMX.Controls.Presentation, FMX.ListBox, FMXInput, RM.LibraryNavigation,
  FMX.Ani;

type
  TLibraryGame = class
  public
    FileInfo: TStorageFile;
    SystemId, Title, Cover, BoxCover, Description, Developer, Genre, Players: string;
    Favorite: Boolean;
    InLibrary: Boolean;
    LastPlayed: TDateTime;
    function Key: string;
    function GamepadCover: string;
  end;

  TLibraryLoader = class(TThread)
  private
    FStorage: IStorage;
    FState: TMemIniFile;
    FGames: TObjectList<TLibraryGame>;
    FOnComplete: TThreadMethod;
    FError: string;
    function FindGame(const Location: string): TLibraryGame;
    procedure LoadRecentGames;
  protected
    procedure Execute; override;
  public
    constructor Create(const Storage: IStorage; State: TMemIniFile; const OnComplete: TThreadMethod);
    destructor Destroy; override;
  end;

  TLibraryCard = class(TPanel)
    Cover: TImage;
    Title, platform: TLabel;
    Selection: TRectangle;
    TextLayout: TLayout;
  end;

  TLibraryView = class(TFrame)
    PanelSidebar, PanelInspector: TPanel;
    LayoutCompactActions, LayoutPlatformCombo: TLayout;
    ComboBoxPlatform: TComboBox;
    VertScrollBoxScroll: TVertScrollBox;
    LayoutGrid: TLayout;
    LabelTitle, LabelCount, LabelDetails, LabelDescription, LabelGameInfo, LabelSavesEmpty, LabelEmpty, LabelContinueTitle: TLabel;
    EditRomPath: TEdit;
    ImageCover: TImage;
    LayoutContinuePreview: TLayout;
    LabelContinueNoPreview: TLabel;
    LabelContinueCaption, LabelContinuePlatform, LabelContinueLastPlayed, LabelContinueSave: TLabel;
    PathPlayIcon: TPath;
    VertScrollBoxPlatforms: TVertScrollBox;
    Path1: TPath;
    Path2: TPath;
  private
    FPadMode, FPadStartPending: Boolean;
    FPadPageOpen: Boolean;
    FPadPageFocus, FPadPageSaveCount: Integer;
    FPadPageSaves: TArray<TButton>;
    ImagePadBackdrop, ImagePadBackdropNext: TImage;
    TimerPadBackdrop: TTimer;
    FPadBackdropStarted, FPadBackdropDue: UInt64;
    FPadBackdropRequested, FPadBackdropFallback: string;
    FPadBackdropPending, FPadBackdropFading: Boolean;
    FPadTextRounding: Boolean;
    procedure PadTextResize(Sender: TObject);
    procedure RoundPadTextSizes(Node: TFmxObject);
    procedure PadBackdropReady(const Location: string; Success: Boolean);
    procedure UpdatePadBackdrop;
    procedure LoadPadBackdrop;
    procedure LayoutPadBackdrop;
    procedure PadBackdropTick(Sender: TObject);
    procedure SelectPadTab(const Id: string);
    function ActivePadTab: string;
    procedure OpenPadGamePage;
    procedure ClosePadGamePage;
    procedure UpdatePadGamePage;
    procedure ResizePadGamePage;
    procedure MovePadPageFocus(Delta: Integer);
    procedure PadPageAction(Sender: TObject);
  private
    FOrientationKnown, FOrientationLandscape, FOrientationPending: Boolean;
    FNavigation: TLibraryNavigation;
    FPadHintDevice: string;
    FPadGames: TList<TLibraryGame>;
    LayoutGamepadLibrary, LayoutPadCarousel: TLayout;
    LabelPadTitle, LabelPadInfo, LabelPadDescription, LabelPadCount: TLabel;
    ButtonPadPlatform, ButtonPadFilter, ButtonPadPlay: TButton;
    FPadCovers: TArray<TImage>;
    FPadSlots: TArray<TRectangle>;
    FPadLabels: TArray<TLabel>;
    FPadSystemButtons: TArray<TButton>;
    FPadSystemSignature: string;
    FPadSystemFirst, FPadWheelDelta: Integer;
    FPadScrollFirst, FPadAppearanceIndex: Integer;
    FPadArranging: Boolean;
    LayoutPadTouchSurface: TLayout;
    FPadTouchDown, FPadTouchHorizontal, FPadTouchVertical: Boolean;
    FPadTouchStart: TPointF;
    FPadTouchOrigin: Double;
    FPadTouchLastX: Single;
    FPadTouchLastTick: UInt64;
    FPadTouchInterrupted, FPadKeyScrolling: Boolean;
    FPadTouchScrolling, FPadScrollArranging, FPadScrollSnapping: Boolean;
    FPadScrollPosition, FPadScrollVelocity: Double;
    FPadScrollTick: UInt64;
    FPadScrollTarget: Double;
    FPadTouchIndex: Integer;
    LayoutPadPlatformSurface, LayoutPadPlatformTrack, LayoutPadPlatformViewport: TLayout;
    TimerPadPlatforms: TTimer;
    FPadSystems: TArray<string>;
    FPadPlatformPosition, FPadPlatformVelocity, FPadPlatformTarget, FPadPlatformOrigin: Double;
    FPadPlatformPitch, FPadPlatformLastX: Single;
    FPadPlatformMaximum: Double;
    FPadPlatformTick, FPadPlatformLastTick: UInt64;
    FPadPlatformDown, FPadPlatformHorizontal, FPadPlatformVertical, FPadPlatformInterrupted: Boolean;
    FPadPlatformMoving, FPadPlatformSnapping, FPadPlatformArranging: Boolean;
    FPadPlatformStart: TPointF;
    FPadPlatformHit: Integer;
    procedure LayoutPadPlatforms;
    procedure CancelPadPlatformTouch;
    procedure PadPlatformDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Single);
    procedure PadPlatformMove(Sender: TObject; Shift: TShiftState; X, Y: Single);
    procedure PadPlatformUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Single);
    procedure PadPlatformTick(Sender: TObject);
    procedure BindPadScrollSlots(First: Integer);
    procedure LayoutPadScroll;
    procedure SetPadScrollPosition(Value: Double);
    procedure EndPadScroll;
    procedure CancelPadTouch;
    function PadTouchStep: Single;
    procedure PadTouchDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Single);
    procedure PadTouchMove(Sender: TObject; Shift: TShiftState; X, Y: Single);
    procedure PadTouchUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Single);
    procedure PadViewportResize(Sender: TObject);
    procedure PadReflowTick(Sender: TObject);
    procedure EnsurePadSlots(Count: Integer);
    procedure UpdatePadPlatforms(KeepActiveVisible: Boolean = False);
    procedure PadPlatformClick(Sender: TObject);
    procedure PadMouseWheel(Sender: TObject; Shift: TShiftState; WheelDelta: Integer; var Handled: Boolean);
    procedure UpdatePadCardAppearance(Image: TImage);
    procedure LoadPadCover(Image: TImage; Game: TLibraryGame);
  private
    TimerPadTransition: TTimer;
    TimerPadLayout: TTimer;
    ImagePadPrevious: TImage;
    procedure PadTransitionTick(Sender: TObject);
    procedure FinishPadSelection;
    procedure LayoutPadSlots;
    procedure InitializePadView;
    procedure SelectPadStartPage;
    procedure UpdatePadHints;
    procedure AnimatePadSelection(Direction: Integer);
    procedure UpdatePadView(RebuildGames: Boolean = True);
    procedure ResizePadView;
    procedure SetPadMode(Enabled, Persist: Boolean);
    procedure TogglePadView(Sender: TObject);
    procedure PadAction(Sender: TObject);
    procedure PadCommand(Command: Integer);
    procedure ChangePadPlatform(Delta: Integer);
  private
    FLoadThread: TLibraryLoader;
    FReloadPending, FClosing: Boolean;
    ButtonReloadLibrary: TButton;
    LayoutLibraryLoading: TLayout;
    AniIndicatorLibraryLoading: TAniIndicator;
    FStorage: IStorage;
    FGames: TObjectList<TLibraryGame>;
    FState: TMemIniFile;
    FSelected, FRecent: TLibraryGame;
    FSystemFilter, FLetterFilter: string;
    FMode, FLimit: Integer;
    FSnapshotName: string;
    LayoutBody, LayoutHeader, LayoutFilters, FContinue: TLayout;
    FSearch: TEdit;
    FLetterScroll: TVertScrollBox;
    FLetterButtons: TList<TButton>;
    ButtonPlay, ButtonFavorite, ButtonMore, FGridButton, FListButton, FResume: TButton;
    FSaveButtons: array[0..2] of TButton;
    FSaveImages: array[0..2] of TImage;
    FPlatformButtons: TList<TButton>;
    FConfiguredPlatforms: TList<string>;
    LayoutLibraryEmptyState, LayoutEmptyMessage: TLayout;
    ButtonConfigureLibrary: TButton;
    FSidebarPlatformBorders: TList<TRectangle>;
    FNavButtons: array[0..2] of TButton;
    FNavIcons: array[0..2] of TPath;
    FGridIcon, FListIcon: TPath;
    FContinueCover: TRectangle;
    FContinueGamePreview: TImage;
    FCards: TList<TLibraryCard>;
    FListMode, FBuilding, FArranging, FLayouting, FShowPlatform, FShowLetters: Boolean;
    FInspectorOpen: Boolean;
    FCardWidth: Integer;
    FContinueCollapse, FContinueExtent: Single;
    FOnPlay, FOnSettings, FOnOpen, FOnPresentationChanged: TNotifyEvent;
    procedure ClearCards;
    procedure SaveState;
    function FindGame(const Location: string): TLibraryGame;
    procedure FinishReload;
    procedure SetLoading(const Value: Boolean);
    procedure ReloadClick(Sender: TObject);
    function Matches(Game: TLibraryGame): Boolean;
    function GetSelected: TLibraryGame;
    function Snapshots(Game: TLibraryGame): TArray<TStorageSnapshot>;
    procedure LoadImage(Image: TImage; const Location: string);
    procedure BuildCards(AppendOnly: Boolean = False);
    procedure ArrangeCards;
    procedure UpdateLetterNavigation(const Games: TList<TLibraryGame>);
    procedure ArrangeLetterNavigation;
    procedure UpdateViewIcons;
    procedure GridResize(Sender: TObject);
    procedure BodyResize(Sender: TObject);
    {$IFDEF ISMOBILE}
    procedure ScrollViewportChanged(Sender: TObject; const OldPosition, NewPosition: TPointF; const ContentSizeChanged: Boolean);
    {$ENDIF}
    procedure UpdateInspector;
    procedure SelectContinueGame;
    procedure UpdateContinue;
    procedure LoadContinueGamePreview;
    procedure ArrangeContinuePreview;
    procedure OpenClick(Sender: TObject);
    procedure SettingsClick(Sender: TObject);
    procedure FilterClick(Sender: TObject);
    procedure UpdateConfiguredPlatforms;
    procedure UpdatePlatformCombo;
    procedure PlatformChange(Sender: TObject);
    procedure ModeClick(Sender: TObject);
    procedure SearchChange(Sender: TObject);
    procedure LetterClick(Sender: TObject);
    procedure CardClick(Sender: TObject);
    procedure DetailsBackClick(Sender: TObject);
    {$IFDEF ISMOBILE}
    procedure CardTap(Sender: TObject; const Point: TPointF);
    {$ELSE}
    procedure CardDblClick(Sender: TObject);
    {$ENDIF}
    procedure PlayClick(Sender: TObject);
    procedure ResumeClick(Sender: TObject);
    procedure SaveClick(Sender: TObject);
    procedure FavoriteClick(Sender: TObject);
    procedure ViewClick(Sender: TObject);
    procedure MoreClick(Sender: TObject);
  protected
    procedure Resize; override;
  public
    constructor CreateLibrary(AOwner: TComponent; const Storage: IStorage);
    destructor Destroy; override;
    procedure PollLibraryInput(Input: TInputManager; Active: Boolean);
    function LibraryKey(Key: Word; PhysicalKeyboard: Boolean = True): Boolean;
    property GamepadMode: Boolean read FPadMode;
    procedure ApplyOrientationPresentation(Landscape: Boolean);
    procedure Reload;
    procedure ApplyPreferences;
    procedure ApplyLanguage(const PreviousLanguage: string);
    procedure RecordSession(const FileName, SnapshotDirectory: string; const SystemId: string = ''; const DisplayName: string = '');
    procedure RefreshSnapshots;
    function CloseDetails: Boolean;
    property Selected: TLibraryGame read GetSelected;
    property SnapshotName: string read FSnapshotName;
    property OnPresentationChanged: TNotifyEvent read FOnPresentationChanged write FOnPresentationChanged;
    property OnPlay: TNotifyEvent read FOnPlay write FOnPlay;
    property OnSettings: TNotifyEvent read FOnSettings write FOnSettings;
    property OnOpen: TNotifyEvent read FOnOpen write FOnOpen;
  end;

function LibrarySystemFullName(const Id: string): string;

function LibrarySystemName(const Id: string): string;

implementation

{$R *.fmx}

uses
  {$IFDEF ANDROID}  Core.Storage.Android, {$ENDIF}
  System.IOUtils, System.Math, System.Math.Vectors, System.Hash,
  System.Character, System.Generics.Defaults, FMX.Graphics, FMX.BehaviorManager,
  Core.GameList, FMX.Image, Core.Platforms, Core.SavePaths, RM.Icons,
  RM.SearchEdit, RM.Styles, RM.Controls.Lifetime;

{$IFDEF ISMOBILE}
type
  TLibraryScrollBox = class(TVertScrollBox)
  private
    FInputTransform: TMatrix;
    FStableInput: Boolean;
    function InputPoint(const X, Y: Single): TPointF;
  protected
    procedure AniMouseDown(const Touch: Boolean; const X, Y: Single); override;
    procedure AniMouseMove(const Touch: Boolean; const X, Y: Single); override;
    procedure AniMouseUp(const Touch: Boolean; const X, Y: Single); override;
  end;

function TLibraryScrollBox.InputPoint(const X, Y: Single): TPointF;
begin
  Result := TPointF.Create(X, Y);
  if FStableInput and (ContentLayout <> nil) then
    Result := ContentLayout.LocalToAbsolute(Result) * FInputTransform;
end;

procedure TLibraryScrollBox.AniMouseDown(const Touch: Boolean; const X, Y: Single);
begin
  if not AniCalculations.Down then
  begin
    FStableInput := Touch and (ContentLayout <> nil);
    if FStableInput then
      FInputTransform := ContentLayout.InvertAbsoluteMatrix;
  end;
  inherited;
end;

procedure TLibraryScrollBox.AniMouseMove(const Touch: Boolean; const X, Y: Single);
begin
  // FMX supplies viewport-local points. Keep the gesture's initial coordinates
  // while collapsing the header moves and enlarges the viewport under the finger.
  var P := InputPoint(X, Y);
  inherited AniMouseMove(Touch, P.X, P.Y);
end;

procedure TLibraryScrollBox.AniMouseUp(const Touch: Boolean; const X, Y: Single);
begin
  var P := InputPoint(X, Y);
  inherited AniMouseUp(Touch, P.X, P.Y);
end;
{$ENDIF}

function LibrarySystemName(const Id: string): string;
begin
  if Id = '' then
    Exit(Translate('All'));
  var Info: TPlatformInfo;
  if TPlatformRegistry.Find(Id, Info) then
    Result := Translate(Info.ShortName)
  else
    Result := Id;
end;

function AdvanceLibraryScroll(var Position, Velocity, Target: Double; var Snapping: Boolean; DT, Pitch, Maximum: Double): Boolean;
begin
  Result := False;
  if not Snapping then
  begin
    var Decay := Exp(-8.5 * DT);
    var Next := Position + Velocity * (1 - Decay) / (8.5 * Pitch);
    Velocity := Velocity * Decay;
    if (Next < 0) or (Next > Maximum) then
      Velocity := 0;
    Position := EnsureRange(Next, 0, Maximum);
    if Abs(Velocity) < 70 then
    begin
      Snapping := True;
      Target := EnsureRange(Double(Round(Position)), 0, Maximum);
    end;
  end
  else
  begin
    var Distance := Position - Target;
    var V := Velocity / Pitch;
    var C := V + 28 * Distance;
    var Decay := Exp(-28 * DT);
    Velocity := (V - 28 * C * DT) * Decay * Pitch;
    Position := EnsureRange(Target + (Distance + C * DT) * Decay, 0, Maximum);
    Result := (Abs(Position - Target) * Pitch < 0.12) and (Abs(Velocity) < 4);
    if Result then
    begin
      Position := Target;
      Velocity := 0;
    end;
  end;
end;

function LibrarySystemFullName(const Id: string): string;
begin
  if Id = '' then
    Exit(Translate('All'));
  var Info: TPlatformInfo;
  if TPlatformRegistry.Find(Id, Info) then
    Result := Translate(Info.Name)
  else
    Result := Id;
end;

function LibraryDate(const Value: TDateTime): string;
begin
  if Trunc(Value) = Trunc(Date) then
    Result := Translate('today, ') + FormatDateTime('hh:nn', Value)
  else if Trunc(Value) = Trunc(Date) - 1 then
    Result := Translate('yesterday, ') + FormatDateTime('hh:nn', Value)
  else
    Result := FormatDateTime('dd.mm.yyyy hh:nn', Value);
end;

function TLibraryGame.GamepadCover: string;
begin
  Result := BoxCover;
  if Result = '' then
    Result := Cover;
end;

function TLibraryGame.Key: string;
begin
  Result := THashSHA2.GetHashString(FileInfo.Location);
end;

function LibraryTitleLetter(const Title: string): string;
begin
  var Value := Title.Trim;
  Result := '#';
  if (Value <> '') and Value.Chars[0].IsLetter then
    Result := Value.Substring(0, 1).ToUpper;
end;

function TextLabel(Owner: TComponent; Parent: TFmxObject; const Text: string; Size: Single = 14): TLabel;
begin
  Result := TLabel.Create(Owner);
  Result.Parent := Parent;
  Result.Text := Text;
  Result.StyledSettings := [];
  Result.TextSettings.Font.Family := 'Segoe UI';
  Result.TextSettings.Font.Size := Size;
  Result.TextSettings.FontColor := $FFE8ECF1;
  Result.TextSettings.Trimming := TTextTrimming.Character;
  Result.TextSettings.WordWrap := False;
  Result.HitTest := False;
end;

function ActionButton(Owner: TComponent; Parent: TFmxObject; const Text: string; Click: TNotifyEvent): TButton;
begin
  Result := TButton.Create(Owner);
  Result.Parent := Parent;
  Result.Text := Translate(Text);
  Result.StyledSettings := Result.StyledSettings - [TStyledSetting.Other];
  Result.TextSettings.Trimming := TTextTrimming.Character;
  Result.TextSettings.WordWrap := False;
  Result.Height := 42;
  Result.OnClick := Click;
end;

constructor TLibraryView.CreateLibrary(AOwner: TComponent; const Storage: IStorage);
begin
  FBuilding := True;
  inherited Create(AOwner);
  FStorage := Storage;
  {$IFDEF ISMOBILE}
  var IsMobile := True;
  {$ELSE}
  var IsMobile := False;
  {$ENDIF}            ;
  FNavigation := TLibraryNavigation.Create(IsMobile);
  FPadGames := TList<TLibraryGame>.Create;
  FGames := TObjectList<TLibraryGame>.Create;
  FCards := TList<TLibraryCard>.Create;
  FLetterButtons := TList<TButton>.Create;
  FPlatformButtons := TList<TButton>.Create;
  FConfiguredPlatforms := TList<string>.Create;
  FSidebarPlatformBorders := TList<TRectangle>.Create;
  FState := FStorage.ReadConfig(FStorage.ConfigFile('library'));
  FLimit := 48;
  PanelSidebar := FindComponent('PanelSidebar') as TPanel;
  PanelInspector := FindComponent('PanelInspector') as TPanel;
  LayoutBody := FindComponent('LayoutBody') as TLayout;
  LayoutHeader := FindComponent('LayoutHeader') as TLayout;
  LayoutFilters := FindComponent('LayoutFilters') as TLayout;
  FContinue := FindComponent('LayoutContinue') as TLayout;
  LayoutCompactActions := FindComponent('LayoutCompactActions') as TLayout;
  VertScrollBoxScroll := FindComponent('VertScrollBoxScroll') as TVertScrollBox;
  LayoutGrid := FindComponent('LayoutGrid') as TLayout;

  FLetterScroll := TVertScrollBox.Create(Self);
  FLetterScroll.Name := 'VertScrollBoxLetters';
  var LetterSlot := FindComponent('LayoutLetterNavigationSlot') as TLayout;
  FLetterScroll.Parent := LetterSlot;
  FLetterScroll.Align := TAlignLayout.Client;
  FLetterScroll.ShowScrollBars := False;
  FLetterScroll.ScrollAnimation := TBehaviorBoolean.True;

  var AllLetters := ActionButton(Self, FLetterScroll, '*', LetterClick);
  AllLetters.Name := 'ButtonAllLetters';
  AllLetters.TagString := '';
  AllLetters.Hint := Translate('All');
  AllLetters.ShowHint := True;
  FLetterButtons.Add(AllLetters);
  {$IFDEF ISMOBILE}
  // Retain the standard control in the designer; use stable gesture coordinates at runtime.
  var Scroll := TLibraryScrollBox.Create(Self);
  Scroll.Align := VertScrollBoxScroll.Align;
  Scroll.Margins.Assign(VertScrollBoxScroll.Margins);
  Scroll.ScrollAnimation := VertScrollBoxScroll.ScrollAnimation;
  Scroll.StyleLookup := VertScrollBoxScroll.StyleLookup;
  Scroll.Parent := VertScrollBoxScroll.Parent;
  Scroll.TabOrder := VertScrollBoxScroll.TabOrder;

  LayoutGrid.Parent := Scroll;
  VertScrollBoxScroll.Free;
  VertScrollBoxScroll := Scroll;
  VertScrollBoxScroll.Name := 'LibraryScrollBoxScroll';
  {$ENDIF}
  LabelTitle := FindComponent('LabelTitle') as TLabel;
  LabelCount := FindComponent('LabelCount') as TLabel;
  LabelDetails := FindComponent('LabelDetails') as TLabel;
  LabelDescription := FindComponent('LabelDescription') as TLabel;
  LabelGameInfo := FindComponent('LabelGameInfo') as TLabel;
  LabelSavesEmpty := FindComponent('LabelSavesEmpty') as TLabel;
  LabelEmpty := FindComponent('LabelEmpty') as TLabel;
  LayoutLibraryEmptyState := FindComponent('LayoutLibraryEmptyState') as TLayout;
  LayoutEmptyMessage := FindComponent('LayoutEmptyMessage') as TLayout;
  ButtonConfigureLibrary := FindComponent('ButtonConfigureLibrary') as TButton;
  ButtonConfigureLibrary.OnClick := SettingsClick;
  LayoutLibraryEmptyState.BringToFront;
  LabelContinueTitle := FindComponent('LabelContinueTitle') as TLabel;
  ImageCover := FindComponent('ImageCover') as TImage;
  ButtonPlay := FindComponent('ButtonPlay') as TButton;
  ButtonFavorite := FindComponent('ButtonFavorite') as TButton;
  (FindComponent('ButtonInspectorBack') as TButton).OnClick := DetailsBackClick;
  ButtonMore := FindComponent('ButtonMore') as TButton;
  FGridButton := FindComponent('ButtonGridView') as TButton;
  FListButton := FindComponent('ButtonListView') as TButton;
  ButtonReloadLibrary := FindComponent('ButtonReloadLibrary') as TButton;
  ButtonReloadLibrary.OnClick := ReloadClick;
  LayoutLibraryLoading := FindComponent('LayoutLibraryLoading') as TLayout;
  AniIndicatorLibraryLoading := FindComponent('AniIndicatorLibraryLoading') as TAniIndicator;
  FGridIcon := FindComponent('PathGridViewIcon') as FMX.Objects.TPath;
  FListIcon := FindComponent('PathListViewIcon') as FMX.Objects.TPath;
  FResume := FindComponent('ButtonResume') as TButton;
  LayoutContinuePreview := FindComponent('LayoutContinuePreview') as TLayout;
  FContinueCover := FindComponent('RectangleContinueCover') as TRectangle;
  FContinueCover.Fill.Bitmap.WrapMode := TWrapMode.TileStretch;
  FContinueGamePreview := FindComponent('ImageContinueGamePreview') as TImage;
  LabelContinueNoPreview := FindComponent('LabelContinueNoPreview') as TLabel;
  LabelContinueCaption := FindComponent('LabelContinueCaption') as TLabel;
  LabelContinuePlatform := FindComponent('LabelContinuePlatform') as TLabel;
  LabelContinueLastPlayed := FindComponent('LabelContinueLastPlayed') as TLabel;
  LabelContinueSave := FindComponent('LabelContinueSave') as TLabel;

  for var i := 0 to 2 do
  begin
    FNavButtons[i] := FindComponent('ButtonNav' + IntToStr(i)) as TButton;
    FNavButtons[i].OnClick := ModeClick;
    FNavButtons[i].TextSettings.HorzAlign := TTextAlign.Leading;
    FNavButtons[i].StylesData['text.Margins.Left'] := 48;
    FNavIcons[i] := FindComponent('PathNavIcon' + IntToStr(i)) as FMX.Objects.TPath;
    FSaveImages[i] := FindComponent('ImageSavePreview' + IntToStr(i)) as TImage;
    FSaveButtons[i] := FindComponent('ButtonSaveButton' + IntToStr(i)) as TButton;
    FSaveButtons[i].OnClick := SaveClick;
  end;

  var FirstRow := FindComponent('LayoutFilterRow0') as TLayout;
  var AllButton := ActionButton(Self, FirstRow, 'All', FilterClick);
  AllButton.Name := 'ButtonFilterAll';
  AllButton.Height := 31;
  FPlatformButtons.Add(AllButton);
  var Brand := '';
  var Group: TLayout := nil;
  var Order := 0;
  for var platform in TPlatformRegistry.All do
  begin
    var Filter := ActionButton(Self, FirstRow, platform.ShortName, FilterClick);
    Filter.Name := 'ButtonFilter' + platform.Id;
    Filter.TagString := platform.Id;
    Filter.Height := 31;
    FPlatformButtons.Add(Filter);

    if Brand <> platform.Manufacturer then
    begin
      Brand := platform.Manufacturer;
      Group := TLayout.Create(Self);
      Group.Parent := VertScrollBoxPlatforms;
      Group.Name := 'PlatformGroup' + IntToStr(Order);
      Group.Position.Y := Order * 1000;
      Group.Align := TAlignLayout.Top;
      Group.Height := 46;
      Group.Width := VertScrollBoxPlatforms.Width;
      var Heading := TextLabel(Self, Group, Brand, 12);
      Heading.Name := 'PlatformManufacturer' + IntToStr(Order);
      Heading.Align := TAlignLayout.Top;
      Heading.Height := 30;
      Heading.Margins.Rect := RectF(12, 12, 0, 4);
      Heading.Position.Y := 0;
      Heading.TextSettings.FontColor := $FFB9C2CC;
      Inc(Order);
    end;
    var Button := ActionButton(Self, Group, platform.Name, FilterClick);
    Button.Name := 'ButtonSidebar' + platform.Id;
    Button.TagString := platform.Id;
    Button.Position.Y := Group.Height;
    Button.Align := TAlignLayout.Top;
    Group.Height := Group.Height + Button.Height;
    Inc(Order);
    Button.StyleLookup := 'buttonstyle_subtle';
    Button.TextSettings.HorzAlign := TTextAlign.Leading;
    Button.StylesData['text.Margins.Left'] := 48;
    CreatePlatformIcon(Button, platform.Id);
    var Border := TRectangle.Create(Button);
    Border.TagString := platform.Id;
    FSidebarPlatformBorders.Add(Border);
    Border.Parent := Button;
    Border.Align := TAlignLayout.Contents;
    Border.Fill.Kind := TBrushKind.None;
    Border.Stroke.Color := $FFFFB344;
    Border.Stroke.Thickness := 2;
    Border.XRadius := 6;
    Border.YRadius := 6;
    Border.HitTest := False;
    Border.Visible := False;
  end;

  for var Name in ['ButtonOpenRom', 'ButtonSettings'] do
  begin
    var Button := FindComponent(Name) as TButton;
    Button.TextSettings.HorzAlign := TTextAlign.Leading;
    Button.StylesData['text.Margins.Left'] := 48;
  end;

  var SearchHost := FindComponent('LayoutSearchHost') as TLayout;
  FSearch := TSearchEdit.Create(Self);
  FSearch.Name := 'SearchEditSearch';
  FSearch.Parent := SearchHost;
  FSearch.Align := TAlignLayout.Client;
  FSearch.TextPrompt := Translate('Search games');
  FSearch.OnChangeTracking := SearchChange;

  (FindComponent('ButtonOpenRom') as TButton).OnClick := OpenClick;
  (FindComponent('ButtonSettings') as TButton).OnClick := SettingsClick;
  (FindComponent('ButtonCompactOpen') as TButton).OnClick := OpenClick;
  (FindComponent('ButtonCompactSettings') as TButton).OnClick := SettingsClick;
  FormStyles.RelocalizeUI(Self, 'en');
  ButtonPlay.OnClick := PlayClick;
  ButtonFavorite.OnClick := FavoriteClick;
  FResume.OnClick := ResumeClick;
  FListButton.OnClick := ViewClick;
  FGridButton.OnClick := ViewClick;
  ButtonMore.OnClick := MoreClick;
  LayoutBody.OnResize := BodyResize;
  LayoutGrid.OnResize := GridResize;
  {$IFDEF ISMOBILE}
  FContinue.ClipChildren := True;
  VertScrollBoxScroll.OnViewportPositionChange := ScrollViewportChanged;
  {$ENDIF}
  InitializePadView;
  {$IFDEF ISMOBILE}
  FPadMode := True;
  (FindComponent('ButtonGamepadView') as TButton).Visible := False;
  {$ELSE}
  FPadMode := FState.ReadBool('View', 'Gamepad', False);
  {$ENDIF}
  FBuilding := False;
  ApplyPreferences;
  FPadStartPending := FPadMode;
  Reload;
end;

destructor TLibraryView.Destroy;

  procedure CancelImages(Owner: TComponent);
  begin
    TBitmap.RemoveCallback(Owner);
    for var i := 0 to Owner.ComponentCount - 1 do
      CancelImages(Owner.Components[i]);
  end;

begin
  FClosing := True;
  FBuilding := True;
  for var Timer in [TimerPadTransition, TimerPadPlatforms, TimerPadLayout, TimerPadBackdrop] do
    if Timer <> nil then
    begin
      Timer.Enabled := False;
      Timer.OnTimer := nil;
    end;
  CancelPadTouch;
  CancelImages(Self);
  DisconnectControl(Self);
  FOnPlay := nil;
  FOnSettings := nil;
  FOnOpen := nil;
  FOnPresentationChanged := nil;
  if FLoadThread <> nil then
  begin
    FLoadThread.Terminate;
    FLoadThread.WaitFor;
    TThread.RemoveQueuedEvents(FLoadThread);
    FreeAndNil(FLoadThread);
  end;
  try
    // Controls borrow game/model pointers; keep those valid through UI teardown.
    inherited;
  finally
    FSelected := nil;
    FRecent := nil;
    FNavigation.Free;
    FPadGames.Free;
    FCards.Free;
    FLetterButtons.Free;
    FConfiguredPlatforms.Free;
    FPlatformButtons.Free;
    FSidebarPlatformBorders.Free;
    FGames.Free;
    FState.Free;
  end;
end;

procedure TLibraryView.ClearCards;

  procedure Detach(Control: TControl);
  begin
    if (Control.Root <> nil) and (Control.Root.Captured <> nil) and (Control.Root.Captured.GetObject = Control) then
      Control.Root.SetCaptured(nil);
    Control.OnClick := nil;
    Control.OnDblClick := nil;
    Control.OnMouseDown := nil;
    Control.OnMouseUp := nil;
    Control.OnTap := nil;
    Control.TagObject := nil;
    for var Child in Control.Controls do
      Detach(Child);
  end;

begin
  for var Card in FCards do
  begin
    Detach(Card);
    Card.Parent := nil;
    Card.Release;
  end;
  FCards.Clear;
end;

constructor TLibraryLoader.Create(const Storage: IStorage; State: TMemIniFile; const OnComplete: TThreadMethod);
begin
  inherited Create(True);
  FStorage := Storage;
  FOnComplete := OnComplete;
  FGames := TObjectList<TLibraryGame>.Create;
  FState := TMemIniFile.Create('');
  var Lines := TStringList.Create;
  try
    State.GetStrings(Lines);
    FState.SetStrings(Lines);
  finally
    Lines.Free;
  end;
end;

destructor TLibraryLoader.Destroy;
begin
  inherited;
  FGames.Free;
  FState.Free;
end;

procedure TLibraryLoader.Execute;
var
  Directories: TObjectDictionary<string, TDictionary<string, string>>;

  function DirectoryEntries(const Folder: string; FoldersOnly: Boolean): TDictionary<string, string>;
  begin
    TStorage.CheckReadCancelled;
    var Key := BoolToStr(FoldersOnly) + ':' + Folder;
    if Directories.TryGetValue(Key, Result) then
      Exit;
    Result := TDictionary<string, string>.Create(TIStringComparer.Ordinal);
    Directories.Add(Key, Result);
    {$IFDEF ANDROID}
    if Folder.StartsWith('content://', True) then
    begin
      // SAF already returns display names with URIs; do not query each child again.
      for var Item in TAndroidStorage.Enumerate(Folder, False, FoldersOnly) do
        if not Result.ContainsKey(Item.Name) then
          Result.Add(Item.Name, Item.Location);
      Exit;
    end;
    {$ENDIF}
    var Candidates: TArray<string>;
    if FoldersOnly then
      Candidates := FStorage.Folders(Folder)
    else
      Candidates := FStorage.Files(Folder);
    for var Candidate in Candidates do
    begin
      TStorage.CheckReadCancelled;
      var Name := FStorage.Describe(Candidate).Name;
      if not Result.ContainsKey(Name) then
        Result.Add(Name, Candidate);
    end;
  end;

  function MetadataPath(const Folder, Relative: string): string;
  begin
    TStorage.CheckReadCancelled;
    Result := '';
    if Relative = '' then
      Exit;
    if not Folder.StartsWith('content://', True) then
      Exit(TPath.Combine(Folder, Relative));
    // SAF identifiers are opaque. Cache names only for this scan so a reload
    // picks up additions, removals and changed provider permissions.
    Result := Folder;
    var Parts := Relative.Replace('\', '/').Split(['/']);
    for var i := 0 to High(Parts) do
    begin
      if (Parts[i] = '') or (Parts[i] = '.') then
        Continue;
      var Entries := DirectoryEntries(Result, i <> High(Parts));
      var Found: string;
      if not Entries.TryGetValue(Parts[i], Found) then
        Exit('');
      Result := Found;
    end;
  end;

  function RelativeMetadataKey(const Path: string): string;
  begin
    // Match ROMs using the display-name path supplied by directory enumeration,
    // without resolving every gamelist entry through the document provider.
    Result := '';
    for var Part in Path.Replace('\', '/').Split(['/']) do
    begin
      if (Part = '') or (Part = '.') then
        Continue;
      if Part = '..' then
      begin
        if Result = '' then
          Exit('');
        var Separator := Result.LastIndexOf('/');
        if Separator < 0 then
          Result := ''
        else
          Result := Result.Substring(0, Separator);
      end
      else
      begin
        if Result <> '' then
          Result := Result + '/';
        Result := Result + Part;
      end;
    end;
    Result := Result.ToLower;
  end;

  function MetadataKey(const Location: string): string;
  begin
    if Location.StartsWith('content://', True) then
      Exit(Location);
    Result := ExpandFileName(Location);
    {$IFDEF MSWINDOWS}
    Result := LowerCase(Result);
    {$ENDIF}
  end;

begin
  {$IFDEF RETROMUL_LIBRARY_TRACE}
  var Trace := TStringList.Create;
  var LoadStarted := TThread.GetTickCount64;
  {$ENDIF}
  var Cancellation := TStorage.BeginReadCancellation(
    procedure
    begin
      if Terminated then
        Abort;
    end);
  try
    for var platform in TPlatformRegistry.All do
    begin
      if Terminated then
        Abort;
      {$IFDEF RETROMUL_LIBRARY_TRACE}
      var PlatformStarted := TThread.GetTickCount64;
      var GamesBefore := FGames.Count;
      {$ENDIF}
      // Optional metadata enriches files found in the configured platform folder.
      var Metadata := TObjectList<TGameList>.Create(True);
      var Lookup := TDictionary<string, TGame>.Create;
      Directories := TObjectDictionary<string, TDictionary<string, string>>.Create([doOwnsValues]);
      try
        var Folder := FStorage.RomFolder(platform.Id);
        var DocumentFolder := Folder.StartsWith('content://', True);
        var XML := '';
        if DocumentFolder then
          DirectoryEntries(Folder, False).TryGetValue('gamelist.xml', XML)
        else if Folder <> '' then
        begin
          XML := TPath.Combine(Folder, 'gamelist.xml');
          if not FStorage.Exists(XML) then
          begin
            XML := '';
            // Native case-sensitive filesystems may contain GameList.XML.
            for var Location in FStorage.Files(Folder) do
              if SameText(ExtractFileName(Location), 'gamelist.xml') then
              begin
                XML := Location;
                Break;
              end;
          end;
        end;
        if XML <> '' then
        begin
          var Catalog := TGameList.Create;
          Metadata.Add(Catalog);
          try
            var Stream := FStorage.OpenRead(XML);
            try
              Catalog.LoadFromStream(Stream);
            finally
              Stream.Free;
            end;
          except
            Catalog.Clear;
          end;
          for var Game in Catalog.Games do
          begin
            TStorage.CheckReadCancelled;
            var Key: string;
            if DocumentFolder then
              Key := RelativeMetadataKey(Game.Path)
            else
              Key := MetadataKey(MetadataPath(Folder, Game.Path));
            Lookup.AddOrSetValue(Key, Game);
          end;
        end;
        for var FileInfo in FStorage.Roms(platform.Id) do
        begin
          if Terminated then
            Abort;
          var Item := TLibraryGame.Create;
          FGames.Add(Item);
          Item.FileInfo := FileInfo;
          Item.InLibrary := True;
          Item.SystemId := platform.Id;
          Item.Title := TPath.GetFileNameWithoutExtension(FileInfo.Name);
          var Entry: TGame;
          var Key: string;
          if DocumentFolder then
            Key := RelativeMetadataKey(FileInfo.RelativePath)
          else
            Key := MetadataKey(FileInfo.Location);
          if Lookup.TryGetValue(Key, Entry) then
          begin
            if Entry.Name <> '' then
              Item.Title := Entry.Name;
            // Resolve artwork only for files actually present in the library.
            var Thumbnail := MetadataPath(Folder, Entry.Thumbnail);
            if (Thumbnail <> '') and (DocumentFolder or FStorage.Exists(Thumbnail)) then
              Item.BoxCover := Thumbnail
            else
            begin
              var Box := MetadataPath(Folder, Entry.Box);
              if (Box <> '') and (DocumentFolder or FStorage.Exists(Box)) then
                Item.BoxCover := Box;
            end;
            Item.Cover := MetadataPath(Folder, Entry.Image);
            if Item.Cover.IsEmpty then
              Item.Cover := Item.BoxCover;
            Item.Description := Entry.Desc;
            Item.Developer := Entry.Developer;
            Item.Genre := Entry.Genre;
            Item.Players := Entry.Players;
            Item.Favorite := Entry.Favorite;
          end;
          Item.Favorite := FState.ReadBool('Favorites', Item.Key, Item.Favorite);
          Item.LastPlayed := FState.ReadFloat('Recent', Item.Key, 0);
        end;
      finally
        Directories.Free;
        Lookup.Free;
        Metadata.Free;
      end;
      {$IFDEF RETROMUL_LIBRARY_TRACE}
      Trace.Add(Format('%s: %d ms, %d games', [platform.Id,
            TThread.GetTickCount64 - PlatformStarted, FGames.Count - GamesBefore]));
      {$ENDIF}
    end;
    LoadRecentGames;
    FGames.Sort(TComparer<TLibraryGame>.Construct(
      function(const A, B: TLibraryGame): Integer
      begin
        Result := CompareText(A.Title, B.Title);
      end));
  except
    on E: Exception do
      FError := E.Message;
  end;
  {$IFDEF RETROMUL_LIBRARY_TRACE}
  try
    Trace.Add(Format('Scan total: %d ms, %d games; error=%s',
        [TThread.GetTickCount64 - LoadStarted, FGames.Count, FError]));
    Trace.SaveToFile(TPath.Combine(FStorage.Root, 'library-load-timing.txt'), TEncoding.UTF8);
  finally
    Trace.Free;
  end;
  {$ENDIF}
  if not Terminated then
    TThread.Queue(Self, FOnComplete);
end;

procedure TLibraryView.SetLoading(const Value: Boolean);
begin
  LayoutLibraryLoading.Visible := Value;
  AniIndicatorLibraryLoading.Enabled := Value;
  ButtonReloadLibrary.Enabled := not Value;
  VertScrollBoxScroll.Visible := not Value;
  LayoutFilters.Visible := not Value;
  LabelCount.Visible := not Value;
  if Value then
  begin
    LayoutLibraryEmptyState.Visible := False;
    if FConfiguredPlatforms.Count = 0 then
    begin
      (FindComponent('LayoutPlatforms') as TLayout).Visible := False;
      VertScrollBoxPlatforms.Visible := False;
    end;
    (FindComponent('LayoutLetterNavigationSlot') as TLayout).Visible := False;
    FContinue.Visible := False;
    PanelInspector.Visible := False;
    (FindComponent('LayoutInspectorOverlay') as TLayout).Visible := False;
    LabelCount.Text := '';
    LayoutLibraryLoading.BringToFront;
  end;
end;

procedure TLibraryView.ReloadClick(Sender: TObject);
begin
  Reload;
end;

procedure TLibraryView.Reload;
begin
  FPadPageOpen := False;
  (FindComponent('LayoutPadGamePage') as TLayout).Visible := False;
  (FindComponent('LayoutPadShelf') as TLayout).Visible := True;
  CancelPadTouch;
  FinishPadSelection;
  if FLoadThread <> nil then
  begin
    FReloadPending := True;
    Exit;
  end;
  FInspectorOpen := False;
  FLoadThread := TLibraryLoader.Create(FStorage, FState, FinishReload);
  FNavigation.Reset;
  SetLoading(True);
  UpdatePadView;
  FLoadThread.Start;
end;

procedure TLibraryView.FinishReload;
begin
  {$IFDEF RETROMUL_LIBRARY_TRACE}
  var FinishStarted := TThread.GetTickCount64;
  {$ENDIF}
  if FClosing then
    Exit;
  FLoadThread.WaitFor;
  var Error := FLoadThread.FError;
  if (Error = '') and not FReloadPending then
  begin
    FSelected := nil;
    FRecent := nil;
    ClearCards;
    FPadGames.Clear;
    FGames.Free;
    FGames := FLoadThread.FGames;
    FLoadThread.FGames := nil;
    // Session history and favorites may have changed while scanning.
    for var Game in FGames do
    begin
      Game.Favorite := FState.ReadBool('Favorites', Game.Key, Game.Favorite);
      Game.LastPlayed := FState.ReadFloat('Recent', Game.Key, 0);
    end;
  end;
  FreeAndNil(FLoadThread);
  if FReloadPending then
  begin
    FReloadPending := False;
    Reload;
    Exit;
  end;
  SetLoading(False);
  UpdateConfiguredPlatforms;
  UpdateContinue;
  BuildCards;
  Resize;
  {$IFDEF RETROMUL_LIBRARY_TRACE}
  TFile.AppendAllText(TPath.Combine(FStorage.Root, 'library-load-timing.txt'),
    Format('UI total: %d ms', [TThread.GetTickCount64 - FinishStarted]) + sLineBreak, TEncoding.UTF8);
  {$ENDIF}
  if Error <> '' then
  begin
    LabelEmpty.Text := Translate('Unable to load library') + sLineBreak + Error;
    LabelEmpty.Visible := True;
    LayoutLibraryEmptyState.Visible := True;
    ButtonConfigureLibrary.Visible := False;
    if FPadMode then
      LabelPadTitle.Text := LabelEmpty.Text;
  end;
end;

procedure TLibraryView.ApplyPreferences;
begin
  var Ini := FStorage.ReadConfig(FStorage.ConfigFile('config'));
  try
    FListMode := Ini.ReadString('Library', 'View', 'grid') = 'list';
    FShowPlatform := Ini.ReadBool('Library', 'ShowPlatform', True);
    FShowLetters := Ini.ReadBool('Library', 'ShowLetters', False);
    if not FShowLetters then
      FLetterFilter := '';
    FCardWidth := EnsureRange(Ini.ReadInteger('Library', 'CardWidth', 170), 140, 240);
  finally
    Ini.Free;
  end;
  UpdateViewIcons;
  (FindComponent('ButtonGamepadView') as TButton).Hint := Translate('Gamepad');
  if FCards <> nil then
    BuildCards;
end;

procedure TLibraryView.ApplyLanguage(const PreviousLanguage: string);
begin
  FormStyles.RelocalizeUI(Self, PreviousLanguage);
  for var Button in FPlatformButtons do
    Button.Text := LibrarySystemName(Button.TagString);
  for var platform in TPlatformRegistry.All do
    (FindComponent('ButtonSidebar' + platform.Id) as TButton).Text := Translate(platform.Name);

  // Rebuild data captions from the game records so titles and metadata stay intact.
  BuildCards;
  UpdateInspector;
  UpdateContinue;
  if FPadPageOpen then
  begin
    UpdatePadGamePage;
    ResizePadGamePage;
  end;
end;

function TLibraryView.FindGame(const Location: string): TLibraryGame;
begin
  for var Game in FGames do
    if SameText(Game.FileInfo.Location, Location) then
      Exit(Game);
  Result := nil;
end;

function TLibraryLoader.FindGame(const Location: string): TLibraryGame;
begin
  for var Game in FGames do
    if SameText(Game.FileInfo.Location, Location) then
      Exit(Game);
  Result := nil;
end;

procedure TLibraryLoader.LoadRecentGames;
begin
  var Keys := TStringList.Create;
  try
    FState.ReadSection('RecentLocations', Keys);
    for var Key in Keys do
    begin
      var Location := FState.ReadString('RecentLocations', Key, '');
      if (Location = '') or (FindGame(Location) <> nil) then
        Continue;
      var platform: TPlatformInfo;
      if not TPlatformRegistry.Find(FState.ReadString('RecentSystems', Key, ''), platform) then
        Continue;
      // Removable files and document providers may be temporarily unavailable.
      try
        if not FStorage.Exists(Location) then
          Continue;
      except
        Continue;
      end;
      var Game := TLibraryGame.Create;
      FGames.Add(Game);
      Game.FileInfo.Location := Location;
      Game.FileInfo.Name := FState.ReadString('RecentNames', Key, TPath.GetFileName(Location));
      Game.InLibrary := False;
      Game.SystemId := platform.Id;
      Game.Title := TPath.GetFileNameWithoutExtension(Game.FileInfo.Name);
      Game.LastPlayed := FState.ReadFloat('Recent', Game.Key, 0);
      Game.Favorite := FState.ReadBool('Favorites', Game.Key, False);
    end;
  finally
    Keys.Free;
  end;
end;

procedure TLibraryView.RecordSession(const FileName, SnapshotDirectory, SystemId, DisplayName: string);
begin
  var Game := FindGame(FileName);
  if Game = nil then
  begin
    var platform: TPlatformInfo;
    if not TPlatformRegistry.Find(SystemId, platform) then
      Exit;
    Game := TLibraryGame.Create;
    FGames.Add(Game);
    Game.FileInfo.Location := FileName;
    Game.FileInfo.Name := DisplayName;
    if Game.FileInfo.Name = '' then
      Game.FileInfo.Name := TPath.GetFileName(FileName);
    Game.InLibrary := False;
    Game.SystemId := platform.Id;
    Game.Title := TPath.GetFileNameWithoutExtension(Game.FileInfo.Name);
    Game.Favorite := FState.ReadBool('Favorites', Game.Key, False);
  end;
  Game.LastPlayed := Now;
  var Key := Game.Key;
  FState.WriteFloat('Recent', Key, Game.LastPlayed);
  FState.WriteString('RecentLocations', Key, Game.FileInfo.Location);
  FState.WriteString('RecentSystems', Key, Game.SystemId);
  FState.WriteString('RecentNames', Key, Game.FileInfo.Name);
  if SnapshotDirectory <> '' then
    FState.WriteString('Snapshots', Key, SnapshotDirectory);
  SaveState;
  if FLoadThread <> nil then
    FReloadPending := True;
  UpdateContinue;
  BuildCards;
end;

procedure TLibraryView.SaveState;
begin
  FStorage.WriteConfig(FState);
end;

function TLibraryView.Matches(Game: TLibraryGame): Boolean;
begin
  // Standalone ROMs belong to Recent; only scanned ROMs belong to the catalog.
  Result := (Game.InLibrary or (FMode = 1)) and
    ((FSystemFilter = '') or (Game.SystemId = FSystemFilter)) and
    ((FMode <> 1) or (Game.LastPlayed > 0)) and ((FMode <> 2) or Game.Favorite) and
    ((FSearch.Text = '') or Game.Title.ToLower.Contains(FSearch.Text.ToLower));
end;

function TLibraryView.GetSelected: TLibraryGame;
begin
  Result := FSelected;
end;

function TLibraryView.Snapshots(Game: TLibraryGame): TArray<TStorageSnapshot>;
begin
  Result := nil;
  if Game = nil then
    Exit;

  var Directory := FState.ReadString('Snapshots', Game.Key, '');
  if Directory = '' then
    Exit;

  var Items := TList<TStorageSnapshot>.Create;
  try
    for var Location in FStorage.Files(Directory) do
      if SameText(ExtractFileExt(Location), SNAPSHOT_EXTENSION) then
      begin
        var Item := Default(TStorageSnapshot);
        Item.Name := ChangeFileExt(ExtractFileName(Location), '');
        Item.Location := Location;
        Item.Modified := FStorage.ModifiedTime(Location);
        Item.PreviewLocation := ChangeFileExt(Location, '.png');
        if not FStorage.Exists(Item.PreviewLocation) then
          Item.PreviewLocation := ChangeFileExt(Location, '.bmp');
        Items.Add(Item);
      end;
    Items.Sort(TComparer<TStorageSnapshot>.Construct(
      function(const A, B: TStorageSnapshot): Integer
      begin
        Result := CompareValue(B.Modified, A.Modified);
        if Result = 0 then
          Result := CompareText(A.Location, B.Location);
      end));
    Result := Items.ToArray;
  finally
    Items.Free;
  end;
end;

procedure TLibraryView.LoadImage(Image: TImage; const Location: string);
begin
  Image.Bitmap.RemoveCallback(Image);
  Image.Bitmap := nil;
  try
    if (Location <> '') and FStorage.Exists(Location) then
      Image.Bitmap.LoadFromFileAsync(Image, Location, 320, 400, nil, FStorage);
  except
    Image.Bitmap := nil;
  end;
end;

procedure TLibraryView.RefreshSnapshots;
begin
  UpdateInspector;
  UpdateContinue;
  if FPadPageOpen then
    UpdatePadGamePage
  else
    UpdatePadView;
  Resize;
end;

procedure TLibraryView.BuildCards(AppendOnly: Boolean);
begin
  if FBuilding or (FLoadThread <> nil) or (LayoutGrid = nil) then
    Exit;

  if FPadMode then
  begin
    ClearCards;
    UpdatePadView;
    Resize;
    Exit;
  end;
  var PreviousSelected := FSelected;
  FBuilding := True;
  try
    var MatchesList := TList<TLibraryGame>.Create;
    try
      for var Game in FGames do
        if Matches(Game) then
          MatchesList.Add(Game);

      // Index the current search and platform before filtering by initial.
      if FShowLetters then
        UpdateLetterNavigation(MatchesList)
      else
        FLetterScroll.Visible := False;
      if FLetterFilter <> '' then
        for var i := MatchesList.Count - 1 downto 0 do
          if LibraryTitleLetter(MatchesList[i].Title) <> FLetterFilter then
            MatchesList.Delete(i);
      if FMode = 1 then
        MatchesList.Sort(TComparer<TLibraryGame>.Construct(
          function(const A, B: TLibraryGame): Integer
          begin
            Result := CompareValue(B.LastPlayed, A.LastPlayed);
          end));

      // Append only when the existing cards still match the current prefix.
      // A recorded session can change the order of the Recent list.
      if AppendOnly then
      begin
        AppendOnly := FCards.Count <= Min(FLimit, MatchesList.Count);
        if AppendOnly then
          for var i := 0 to FCards.Count - 1 do
            if FCards[i].TagObject <> MatchesList[i] then
            begin
              AppendOnly := False;
              Break;
            end;
      end;

      if not AppendOnly then
      begin
        ClearCards;
      end;

      var SelectedVisible := MatchesList.Contains(FSelected);
      if not SelectedVisible then
      begin
        FSelected := nil;
        if MatchesList.Count > 0 then
          FSelected := MatchesList[0];
      end;

      LabelCount.Text := IntToStr(MatchesList.Count) + Translate(' games');
      for var i := FCards.Count to Min(FLimit, MatchesList.Count) - 1 do
      begin
        var Game := MatchesList[i];
        var Card := TLibraryCard.Create(LayoutGrid);
        Card.Parent := LayoutGrid;
        Card.StyleLookup := 'retromul_card';
        Card.TagObject := Game;
        {$IFDEF ISMOBILE}
        Card.OnTap := CardTap;
        {$IF not Defined(ANDROID) and not Defined(IOS)}
        // Desktop preview uses mouse clicks instead of native touch taps.
        Card.OnClick := CardClick;
        {$ENDIF}
        {$ELSE}
        Card.OnClick := CardClick;
        Card.OnDblClick := CardDblClick;
        {$ENDIF}
        FCards.Add(Card);
        var Cover := TImage.Create(Card);
        Card.Cover := Cover;
        Cover.Parent := Card;
        Cover.HitTest := False;
        Cover.WrapMode := TImageWrapMode.Fit;
        LoadImage(Cover, Game.Cover);
        Card.TextLayout := TLayout.Create(Card);
        Card.TextLayout.Parent := Card;
        Card.TextLayout.Align := TAlignLayout.Bottom;
        Card.TextLayout.Height := 58;
        var Title := TextLabel(Card, Card.TextLayout, Game.Title, 14);
        Card.Title := Title;
        Title.TextSettings.Font.Style := [TFontStyle.fsBold];
        var platform := TextLabel(Card, Card.TextLayout, LibrarySystemName(Game.SystemId), 12);
        Card.platform := platform;
        platform.Opacity := 0.6;
        platform.Visible := FShowPlatform;
        var SelectedBorder := TRectangle.Create(Card);
        Card.Selection := SelectedBorder;
        SelectedBorder.Parent := Card;
        SelectedBorder.Align := TAlignLayout.Contents;
        SelectedBorder.Fill.Kind := TBrushKind.None;
        SelectedBorder.Stroke.Color := $FFFFB344;
        SelectedBorder.Stroke.Thickness := 2;
        SelectedBorder.XRadius := 10;
        SelectedBorder.YRadius := 10;
        SelectedBorder.HitTest := False;
        SelectedBorder.Visible := FSelected = Game;
      end;
      ButtonMore.Visible := MatchesList.Count > FLimit;
      LabelEmpty.Visible := MatchesList.Count = 0;
      LayoutLibraryEmptyState.Visible := MatchesList.Count = 0;
      ButtonConfigureLibrary.Visible := FConfiguredPlatforms.Count = 0;
      LayoutEmptyMessage.Height := IfThen(ButtonConfigureLibrary.Visible, 160, 92);
      if (FGames.Count = 0) or (FConfiguredPlatforms.Count = 0) then
        LabelEmpty.Text := Translate('Your library is empty') + sLineBreak + Translate('Open settings and choose a ROM folder.')
      else
        LabelEmpty.Text := Translate('No games found') + sLineBreak + Translate('Change your search or filter.');
    finally
      MatchesList.Free;
    end;
  finally
    FBuilding := False;
  end;

  if AppendOnly then
  begin
    ArrangeCards;
    if FSelected <> PreviousSelected then
      UpdateInspector;
    Exit;
  end;

  for var i := 0 to 2 do
  begin
    if i = FMode then
      FNavButtons[i].StyleLookup := 'retromul_nav_active'
    else
      FNavButtons[i].StyleLookup := 'buttonstyle_subtle';
    FNavButtons[i].StylesData['text.Margins.Left'] := 48;
    if i = FMode then
      FNavIcons[i].Stroke.Color := $FFFFB344
    else
      FNavIcons[i].Stroke.Color := $FFB9C2CC;
  end;

  for var Button in FPlatformButtons do
    if FSystemFilter = Button.TagString then
      Button.StyleLookup := 'buttonstyle_accent'
    else
      Button.StyleLookup := 'buttonstyle';

  UpdatePlatformCombo;

  for var Border in FSidebarPlatformBorders do
    Border.Visible := FSystemFilter = Border.TagString;

  Resize;
  UpdateInspector;
end;

procedure TLibraryView.UpdateLetterNavigation(const Games: TList<TLibraryGame>);
begin
  var Letters := TStringList.Create;
  try
    Letters.Sorted := True;
    Letters.Duplicates := dupIgnore;
    for var Game in Games do
      Letters.Add(LibraryTitleLetter(Game.Title));
    for var Letter in Letters do
    begin
      var Found := False;
      for var Button in FLetterButtons do
        if Button.TagString = Letter then
        begin
          Found := True;
          Break;
        end;

      if not Found then
      begin
        var Button := ActionButton(Self, FLetterScroll, Letter, LetterClick);
        Button.TagString := Letter;
        Button.StyledSettings := [];
        Button.TextSettings.Font.Size := 13;
        Button.TextSettings.HorzAlign := TTextAlign.Leading;
        Button.TextSettings.Font.Style := [TFontStyle.fsBold];
        FLetterButtons.Add(Button);
      end;
    end;

    FLetterButtons.Sort(TComparer<TButton>.Construct(
      function(const A, B: TButton): Integer
      begin
        Result := CompareText(A.TagString, B.TagString);
      end));

    for var Button in FLetterButtons do
    begin
      Button.Visible := (Button.TagString = '') or (Letters.IndexOf(Button.TagString) >= 0);
      Button.StyledSettings := Button.StyledSettings - [TStyledSetting.FontColor];
      if Button.TagString = FLetterFilter then
      begin
        Button.StyleLookup := 'buttonstyle_accent';
        Button.TextSettings.FontColor := $FF1B2025;
      end
      else
      begin
        Button.StyleLookup := 'buttonstyle_subtle';
        Button.TextSettings.FontColor := $FFE8ECF1;
      end;
    end;
    FLetterButtons[0].Hint := Translate('All');
    FLetterScroll.Visible := Games.Count > 0;
  finally
    Letters.Free;
  end;
end;

procedure TLibraryView.ArrangeLetterNavigation;
begin
  var Slot := FindComponent('LayoutLetterNavigationSlot') as TLayout;
  Slot.Visible := (FLoadThread = nil) and FLetterScroll.Visible;
  var Count := 0;
  for var Button in FLetterButtons do
    if Button.Visible then
      Inc(Count);
  var H := EnsureRange(Floor(FLetterScroll.Height / Max(1, Count)), 24, 36);
  FLetterScroll.BeginUpdate;
  try
    for var i := 0 to FLetterButtons.Count - 1 do
    begin
      var Button := FLetterButtons[i];
      Button.Align := TAlignLayout.Top;
      Button.Height := H - 2;
      Button.Margins.Bottom := 2;
      Button.Position.Y := i * H; // FMX Top-alignment ordering key.
    end;
  finally
    FLetterScroll.EndUpdate;
  end;
end;

procedure TLibraryView.ArrangeCards;
begin
  if FBuilding or FArranging or (LayoutGrid = nil) then
    Exit;
  FArranging := True;
  try
    var Available := Max(1, LayoutGrid.Width);
    var Columns := Max(1, Floor((Available + 14) / (FCardWidth + 14)));
    {$IFDEF ISMOBILE}
    Columns := Max(2, Columns);
    {$ENDIF}
    if FListMode then
      Columns := 1;
    var W := Max(1, (Available - (Columns - 1) * 14) / Columns);
    var H := IfThen(FListMode, 92 * 2 / 3, W * 1.1 + 66);
    var Gap := IfThen(FListMode, 14 * 2 / 3, 14);
    var Rows := FindComponent('LayoutCardRows') as TLayout;
    Rows.BeginUpdate;
    try
      var RowCount := Ceil(FCards.Count / Columns);
      while Rows.ChildrenCount < RowCount do
      begin
        var Row := TLayout.Create(Rows);
        Row.Parent := Rows;
        Row.Align := TAlignLayout.Top;
      end;
      for var i := 0 to Rows.ChildrenCount - 1 do
      begin
        var Row := TLayout(Rows.Children[i]);
        Row.Visible := i < RowCount;
        Row.Height := H;
        Row.Margins.Bottom := Gap;
        Row.Position.Y := i * (H + Gap); // Sort aligned rows, never place cards.
      end;
      for var i := 0 to FCards.Count - 1 do
      begin
        var Card := FCards[i];
        Card.Parent := Rows.Children[i div Columns];
        Card.Align := TAlignLayout.Left;
        Card.Width := W;
        Card.Margins.Right := IfThen(i mod Columns = Columns - 1, 0, 14);
        Card.Position.X := (i mod Columns) * (W + 14); // Alignment order within this row.
        Card.Padding.Rect := RectF(8, 8, 8, 8);
        Card.Title.Align := TAlignLayout.Top;
        Card.Title.Height := 28;
        Card.platform.Align := TAlignLayout.Top;
        Card.platform.Height := 22;
        if FListMode then
        begin
          Card.Cover.Align := TAlignLayout.Left;
          Card.Cover.Width := 40;
          Card.Cover.Margins.Rect := RectF(0, 0, 16, 0);
          Card.TextLayout.Align := TAlignLayout.Client;
          Card.TextLayout.Padding.Rect := RectF(0, 0, 12, 0);
          Card.Title.Height := 24;
          Card.platform.Height := 18;
          Card.platform.Margins.Top := 0;
        end
        else
        begin
          Card.TextLayout.Align := TAlignLayout.Bottom;
          Card.TextLayout.Height := IfThen(FShowPlatform, 58, 36);
          Card.TextLayout.Padding.Rect := RectF(4, 6, 4, 0);
          Card.Cover.Align := TAlignLayout.Client;
          Card.Cover.Margins.Rect := TRectF.Empty;
          Card.platform.Margins.Top := 0;
        end;
      end;
      Rows.Height := RowCount * (H + Gap);
      var More := FindComponent('LayoutMoreActions') as TLayout;
      More.Visible := ButtonMore.Visible;
      LayoutGrid.Height := Max(180, Rows.Height + IfThen(More.Visible, 64, 0));
    finally
      Rows.EndUpdate;
    end;
  finally
    FArranging := False;
  end;
end;

procedure TLibraryView.Resize;
begin
  if (csLoading in ComponentState) or FBuilding or FLayouting or (LayoutBody = nil) then
    Exit;
  LayoutGamepadLibrary.Visible := FPadMode;
  if FPadMode then
  begin
    PanelSidebar.Visible := False;
    PanelInspector.Visible := False;
    LayoutBody.Visible := False;
    (FindComponent('LayoutInspectorOverlay') as TLayout).Visible := False;
    LayoutGamepadLibrary.BringToFront;
    ResizePadView;
    Exit;
  end;
  FLayouting := True;
  try
    LayoutBody.Visible := True;
    inherited;
    PanelSidebar.Visible := Width >= 900;
    LayoutCompactActions.Visible := not PanelSidebar.Visible;
    var CompactNav := FindComponent('LayoutCompactNavigation') as TLayout;
    CompactNav.Visible := not PanelSidebar.Visible;
    var Nav := FindComponent('LayoutNav') as TLayout;
    if CompactNav.Visible then
    begin
      Nav.Parent := CompactNav;
      Nav.Align := TAlignLayout.Client;
      Nav.Margins.Rect := TRectF.Empty;
    end
    else
    begin
      Nav.Parent := PanelSidebar;
      Nav.Align := TAlignLayout.Top;
      Nav.Height := 162;
      Nav.Margins.Rect := RectF(12, 12, 12, 0);
    end;
    var InspectorOverlay := FindComponent('LayoutInspectorOverlay') as TLayout;
    var WideInspector := Width >= 1120;
    if WideInspector then
    begin
      PanelInspector.Parent := Self;
      PanelInspector.Align := TAlignLayout.Right;
      PanelInspector.Width := 292;
    end
    else
    begin
      PanelInspector.Parent := FindComponent('LayoutInspectorContent') as TLayout;
      PanelInspector.Align := TAlignLayout.Client;
    end;
    InspectorOverlay.Visible := (FLoadThread = nil) and not WideInspector and FInspectorOpen;
    PanelInspector.Visible := (FLoadThread = nil) and (WideInspector or FInspectorOpen);
    if InspectorOverlay.Visible then
      InspectorOverlay.BringToFront;
    // Restoring the side panes changes the client area. Resolve that alignment
    // before wrapping filters and sizing cards against LayoutBody.Width.
    Realign;
    for var i := 0 to High(FNavButtons) do
    begin
      FNavIcons[i].Visible := not CompactNav.Visible;
      if CompactNav.Visible then
      begin
        FNavButtons[i].Align := TAlignLayout.Left;
        FNavButtons[i].Width := Max(1, (CompactNav.Width - 8) / 3);
        FNavButtons[i].Margins.Rect := RectF(0, 0, 4, 0);
        FNavButtons[i].Position.X := i * 1000; // Left-alignment order.
        FNavButtons[i].TextSettings.HorzAlign := TTextAlign.Center;
        FNavButtons[i].StylesData['text.Margins.Left'] := 4;
      end
      else
      begin
        FNavButtons[i].Align := TAlignLayout.Top;
        FNavButtons[i].Height := 46;
        FNavButtons[i].Margins.Rect := RectF(0, 0, 0, 8);
        FNavButtons[i].Position.Y := i * 54;
        FNavButtons[i].TextSettings.HorzAlign := TTextAlign.Leading;
        FNavButtons[i].StylesData['text.Margins.Left'] := 48;
      end;
    end;
    var NarrowToolbar := LayoutBody.Width - 48 < 500;
    LayoutHeader.BeginUpdate;
    LayoutCompactActions.BeginUpdate;
    try
      var Tools := FindComponent('LayoutHeaderTools') as TLayout;
      LayoutHeader.Height := IfThen(NarrowToolbar, 142, 92);
      if NarrowToolbar then
        Tools.Align := TAlignLayout.Bottom
      else
        Tools.Align := TAlignLayout.Right;
      Tools.Width := 294;
      Tools.Height := 50;
      (FindComponent('LayoutSearchHost') as TLayout).Margins.Right := IfThen(NarrowToolbar, 0, 12);
      var PrimaryActions := FindComponent('LayoutCompactPrimaryActions') as TLayout;
      var SecondaryActions := FindComponent('LayoutCompactSecondaryActions') as TLayout;
      SecondaryActions.Visible := NarrowToolbar;
      LayoutCompactActions.Height := IfThen(NarrowToolbar, 96, 48);
      var Report := FindComponent('ButtonCompactReportBug') as TButton;
      if NarrowToolbar then
      begin
        Report.Parent := SecondaryActions;
        Report.Align := TAlignLayout.Client;
        Report.Margins.Rect := RectF(0, 0, 0, 12);
      end
      else
      begin
        Report.Parent := PrimaryActions;
        Report.Align := TAlignLayout.Right;
        Report.Width := 125;
        Report.Margins.Rect := RectF(6, 0, 0, 12);
      end;
      for var Name in ['ButtonCompactOpen', 'ButtonCompactSettings'] do
      begin
        var Button := FindComponent(Name) as TButton;
        Button.Width := IfThen(NarrowToolbar, Max(1, (LayoutBody.Width - 56) / 2), 136);
        Button.Margins.Right := IfThen(NarrowToolbar and (Name = 'ButtonCompactSettings'), 0, 8);
      end;
    finally
      LayoutCompactActions.EndUpdate;
      LayoutHeader.EndUpdate;
    end;
    if VertScrollBoxPlatforms.Content <> nil then
      for var i := 0 to VertScrollBoxPlatforms.Content.ChildrenCount - 1 do
        if VertScrollBoxPlatforms.Content.Children[i] is TLayout then
          TLayout(VertScrollBoxPlatforms.Content.Children[i]).Width := VertScrollBoxPlatforms.Width;
    LayoutEmptyMessage.Width := Min(520, Max(1, LayoutLibraryEmptyState.Width - 32));
    var ContentWidth := Max(1, LayoutBody.Width - 48);
    LayoutContinuePreview.Visible := ContentWidth >= 720;
    FContinueCollapse := 0;
    FContinueExtent := 0;
    if FContinue.Visible then
    begin
      var Stacked := ContentWidth < 520;
      var CardHeight := IfThen(Stacked, 208, 154);
      FContinueExtent := CardHeight + 16;
      if LayoutBody.Height - LayoutHeader.Height - FContinueExtent < 274 then
        FContinueExtent := 0;
      {$IFDEF ISMOBILE}
      FContinueCollapse := EnsureRange(VertScrollBoxScroll.ViewportPosition.Y, 0, FContinueExtent);
      {$ENDIF}
      FContinue.Opacity := IfThen(FContinueExtent > 0, 1 - FContinueCollapse / Max(1, FContinueExtent), 0);
      FContinue.Enabled := (FContinueExtent > 0) and (FContinueCollapse < CardHeight);
      FContinue.Height := Max(0, Min(CardHeight, FContinueExtent - FContinueCollapse));
      FContinue.Margins.Bottom := Max(0, FContinueExtent - FContinueCollapse - FContinue.Height);
      FResume.Width := Min(144, ContentWidth - 40);
      if Stacked then
      begin
        FResume.Align := TAlignLayout.Bottom;
        FResume.Height := 40;
        FResume.Margins.Rect := RectF(0, 12, 0, 0);
      end
      else
      begin
        FResume.Align := TAlignLayout.Right;
        FResume.Margins.Rect := RectF(20, 80, 0, 2);
      end;
      ArrangeContinuePreview;
    end;
    // Filters wrap by moving their aligned controls between static FMX rows.
    LayoutFilters.BeginUpdate;
    try
      for var i := 0 to 2 do
        TLayout(FindComponent('LayoutFilterRow' + IntToStr(i))).Visible := False;
      var RowIndex := 0;
      var Used: Single := 0;
      for var B in FPlatformButtons do
      begin
        if (B.TagString <> '') and not FConfiguredPlatforms.Contains(B.TagString) then
          Continue;
        var W: Single := Max(56, Length(LibrarySystemName(B.TagString)) * 8 + 24);
        W := Min(W, ContentWidth);
        if (Used > 0) and (Used + W > ContentWidth) then
        begin
          Inc(RowIndex);
          Used := 0;
        end;
        if RowIndex >= 3 then
          Break;
        var Row := FindComponent('LayoutFilterRow' + IntToStr(RowIndex)) as TLayout;
        Row.Visible := True;
        Row.Position.Y := RowIndex * 41; // Top-alignment sort key.
        var Item: TControl := B;
        if B.Parent <> LayoutFilters then
          if (B.Parent is TLayout) and not string(B.Parent.Name).StartsWith('LayoutFilterRow') then
            Item := TControl(B.Parent);
        Item.Parent := Row;
        Item.Align := TAlignLayout.Left;
        Item.Width := W;
        Item.Margins.Rect := RectF(0, 4, 7, 3);
        Item.Position.X := Used; // Left-alignment sort key.
        B.Visible := True;
        Used := Used + W + 7;
      end;
      LayoutPlatformCombo.Visible := RowIndex >= 3;
      if LayoutPlatformCombo.Visible then
      begin
        for var i := 0 to 2 do
          TLayout(FindComponent('LayoutFilterRow' + IntToStr(i))).Visible := False;
        LayoutFilters.Height := 46;
      end
      else
        LayoutFilters.Height := (RowIndex + 1) * 41 + 5;
    finally
      LayoutFilters.EndUpdate;
    end;
    LayoutGrid.Margins.Top := FContinueCollapse;
    ArrangeLetterNavigation;
    ArrangeCards;
  finally
    FLayouting := False;
  end;
end;

procedure TLibraryView.GridResize(Sender: TObject);
begin
  ArrangeCards;
end;

procedure TLibraryView.BodyResize(Sender: TObject);
begin
  Resize;
end;

{$IFDEF ISMOBILE}
procedure TLibraryView.ScrollViewportChanged(Sender: TObject; const OldPosition, NewPosition: TPointF; const ContentSizeChanged: Boolean);
begin
  if FBuilding or FLayouting or not FContinue.Visible or (FContinueExtent <= 0) then
    Exit;
  var Collapse := EnsureRange(NewPosition.Y, 0, FContinueExtent);
  if SameValue(Collapse, FContinueCollapse, 0.1) then
    Exit;
  FLayouting := True;
  try
    FContinueCollapse := Collapse;
    var CardHeight := FContinueExtent - 16;
    FContinue.Height := Max(0, Min(CardHeight, FContinueExtent - Collapse));
    FContinue.Margins.Bottom := Max(0, FContinueExtent - Collapse - FContinue.Height);
    FContinue.Opacity := 1 - Collapse / FContinueExtent;
    FContinue.Enabled := Collapse < CardHeight;
    LayoutGrid.Margins.Top := Collapse;
    ArrangeLetterNavigation;
  finally
    FLayouting := False;
  end;
end;

{$ENDIF}

procedure TLibraryView.UpdateInspector;
begin
  if FLoadThread <> nil then
    Exit;
  var Content := TControl(ImageCover.Parent);
  Content.BeginUpdate;
  try
    ButtonPlay.Enabled := FSelected <> nil;
    ButtonFavorite.Enabled := FSelected <> nil;
    ImageCover.Visible := (FSelected <> nil) and (FSelected.Cover <> '');
    if FSelected = nil then
    begin
      LabelTitle.Text := Translate('Select a game');
      ImageCover.Bitmap := nil;
      LabelDetails.Text := '';
      LabelDescription.Text := '';
      LabelGameInfo.Text := '';
      EditRomPath.Text := '';
    end
    else
    begin
      LabelTitle.Text := FSelected.Title;
      var Location := FSelected.FileInfo.Location;
      if (Location <> '') and not Location.Contains('://') then
        Location := ExpandFileName(Location);
      EditRomPath.Text := Location;
      EditRomPath.CaretPosition := 0;
      LabelDetails.Text := LibrarySystemFullName(FSelected.SystemId) + sLineBreak + FSelected.Developer;
      LabelDescription.Text := FSelected.Description;
      if LabelDescription.Text = '' then
        LabelDescription.Text := FSelected.Genre;
      LabelGameInfo.Text := '';
      if FSelected.Genre <> '' then
        LabelGameInfo.Text := Translate('Genre: ') + FSelected.Genre;
      if FSelected.Players <> '' then
        LabelGameInfo.Text := LabelGameInfo.Text + sLineBreak + Translate('Players: ') + FSelected.Players;
      if FSelected.Favorite then
        ButtonFavorite.Text := Translate('Remove from favorites')
      else
        ButtonFavorite.Text := Translate('Add to favorites');
      LoadImage(ImageCover, FSelected.Cover);
    end;
    EditRomPath.Visible := EditRomPath.Text <> '';
    EditRomPath.Hint := EditRomPath.Text;
    LabelDetails.Visible := LabelDetails.Text <> '';
    LabelDescription.Visible := LabelDescription.Text <> '';
    LabelGameInfo.Visible := LabelGameInfo.Text <> '';

    var Saves := Snapshots(FSelected);
    LabelSavesEmpty.Visible := Length(Saves) = 0;
    LabelSavesEmpty.Text := Translate('No save states yet.');
    for var i := 0 to 2 do
    begin
      FSaveButtons[i].Visible := i < Length(Saves);
      TControl(FSaveButtons[i].Parent).Visible := FSaveButtons[i].Visible;
      FSaveImages[i].Visible := i < Length(Saves);
      if i < Length(Saves) then
      begin
        FSaveButtons[i].Text := Saves[i].Name + sLineBreak + FormatDateTime('dd.mm.yyyy hh:nn', Saves[i].Modified);
        FSaveButtons[i].TagString := Saves[i].Location;
        LoadImage(FSaveImages[i], Saves[i].PreviewLocation);
      end;
    end;
    // Hidden Top-aligned controls retain old positions. Restore the logical
    // order before FMX sorts them when the selected game's content changes.
    var Items: TArray<TControl> := [ImageCover, LabelTitle, LabelDetails, EditRomPath,
        ButtonPlay, ButtonFavorite, LabelDescription, LabelGameInfo,
        FindComponent('LabelSnapshots') as TControl, LabelSavesEmpty,
        TControl(FSaveButtons[0].Parent), TControl(FSaveButtons[1].Parent),
        TControl(FSaveButtons[2].Parent)];
    var OrderY: Single := 0;
    for var Item in Items do
    begin
      Item.Position.Y := OrderY + Item.Margins.Top;
      OrderY := OrderY + Item.Margins.Top + Item.Height + Item.Margins.Bottom;
    end;
  finally
    Content.EndUpdate;
  end;
end;

procedure TLibraryView.SelectContinueGame;
begin
  FRecent := nil;
  for var Game in FGames do
    if (Game.LastPlayed > 0) and ((FRecent = nil) or (Game.LastPlayed > FRecent.LastPlayed)) then
      FRecent := Game;
  if FRecent <> nil then
    Exit;
  var Latest: TDateTime := 0;
  for var Game in FGames do
  begin
    var Saves := Snapshots(Game);
    if (Length(Saves) > 0) and ((FRecent = nil) or (Saves[0].Modified > Latest)) then
    begin
      FRecent := Game;
      Latest := Saves[0].Modified;
    end;
  end;
end;

procedure TLibraryView.UpdateContinue;
begin
  if FLoadThread <> nil then
    Exit;
  SelectContinueGame;
  var Bitmap := FContinueCover.Fill.Bitmap.Bitmap;
  Bitmap.RemoveCallback(FContinueCover);
  FContinueGamePreview.Bitmap.RemoveCallback(FContinueGamePreview);
  FContinue.Visible := FRecent <> nil;
  if FRecent = nil then
    Exit;

  LabelContinueTitle.Text := FRecent.Title;
  LabelContinuePlatform.Text := LibrarySystemName(FRecent.SystemId);
  if FRecent.Genre <> '' then
    LabelContinuePlatform.Text := LabelContinuePlatform.Text + ' · ' + FRecent.Genre;
  LabelContinueLastPlayed.Text := Translate('Last played: ') + LibraryDate(FRecent.LastPlayed);
  var Saves := Snapshots(FRecent);
  var Preview := '';
  if Length(Saves) > 0 then
  begin
    LabelContinueCaption.Text := Translate('Continue playing');
    FResume.Text := Translate('Resume');
    LabelContinueSave.Text := Translate('Save state: ') + Saves[0].Name + ' · ' + LibraryDate(Saves[0].Modified);
    if FStorage.Exists(Saves[0].PreviewLocation) then
      Preview := Saves[0].PreviewLocation;
  end
  else
  begin
    LabelContinueCaption.Text := Translate('Recently played');
    FResume.Text := Translate('Play');
    LabelContinueSave.Text := Translate('No save states yet');
  end;
  Bitmap.SetSize(0, 0);
  FContinueCover.Fill.Kind := TBrushKind.Solid;
  FContinueCover.Visible := True;
  FContinueGamePreview.Bitmap := nil;
  FContinueGamePreview.Visible := False;
  LabelContinueNoPreview.Visible := True;
  LabelContinueNoPreview.Text := Translate('No save-state screenshot');
  if Length(Saves) = 0 then
    LabelContinueNoPreview.Text := Translate('No save state');
  ArrangeContinuePreview;
  if Preview <> '' then
    Bitmap.LoadFromFileAsync(FContinueCover, Preview, 320, 400,
      procedure(Success: Boolean)
      begin
        if Success then
        begin
          FContinueCover.Fill.Kind := TBrushKind.Bitmap;
          LabelContinueNoPreview.Visible := False;
          Resize;
        end
        else
          LoadContinueGamePreview;
      end, FStorage)
  else
    LoadContinueGamePreview;
end;

procedure TLibraryView.LoadContinueGamePreview;
begin
  FContinueCover.Visible := False;
  FContinueGamePreview.Visible := True;
  LabelContinueNoPreview.Text := Translate('Preview unavailable');
  LabelContinueNoPreview.Visible := (FRecent.Cover = '') or not FStorage.Exists(FRecent.Cover);
  LoadImage(FContinueGamePreview, FRecent.Cover);
end;

procedure TLibraryView.ArrangeContinuePreview;
begin
  var Bitmap := FContinueCover.Fill.Bitmap.Bitmap;
  if not Bitmap.IsEmpty then
    LayoutContinuePreview.Width := LayoutContinuePreview.Height * Bitmap.Width / Bitmap.Height
  else
    LayoutContinuePreview.Width := 176;
  FContinueCover.Align := TAlignLayout.Contents;
end;

procedure TLibraryView.OpenClick(Sender: TObject);
begin
  if Assigned(FOnOpen) then
    FOnOpen(Self);
end;

procedure TLibraryView.SettingsClick(Sender: TObject);
begin
  if Assigned(FOnSettings) then
    FOnSettings(Sender);
end;

procedure TLibraryView.UpdateConfiguredPlatforms;
begin
  FPadSystemSignature := '';
  FConfiguredPlatforms.Clear;
  for var platform in TPlatformRegistry.All do
    if FStorage.RomFolder(platform.Id) <> '' then
      FConfiguredPlatforms.Add(platform.Id);
  TLayout(FindComponent('LayoutPlatforms')).Visible := FConfiguredPlatforms.Count > 0;
  VertScrollBoxPlatforms.Visible := FConfiguredPlatforms.Count > 0;
  if (FSystemFilter <> '') and not FConfiguredPlatforms.Contains(FSystemFilter) then
    FSystemFilter := '';

  for var Button in FPlatformButtons do
    Button.Visible := (Button.TagString = '') or FConfiguredPlatforms.Contains(Button.TagString);
  if (VertScrollBoxPlatforms.Content = nil) or (VertScrollBoxPlatforms.Content.ChildrenCount = 0) then
    Exit;
  for var Child in VertScrollBoxPlatforms.Content.Children do
    if Child is TLayout then
    begin
      var Group := TLayout(Child);
      var Height: Single := 46; // Manufacturer heading and its margins.
      var HasPlatforms := False;
      Group.BeginUpdate;
      try
        for var Control in Group.Controls do
          if Control is TButton then
          begin
            Control.Visible := FConfiguredPlatforms.Contains(Control.TagString);
            if Control.Visible then
            begin
              Control.Position.Y := Height;
              Height := Height + Control.Height + Control.Margins.Top + Control.Margins.Bottom;
              HasPlatforms := True;
            end;
          end;
        Group.Height := Height;
        Group.Visible := HasPlatforms;
      finally
        Group.EndUpdate;
      end;
    end;
end;

procedure TLibraryView.UpdatePlatformCombo;
begin
  ComboBoxPlatform.OnChange := nil;
  ComboBoxPlatform.Items.BeginUpdate;
  try
    ComboBoxPlatform.Items.Clear;
    var SelectedIndex := -1;
    for var Button in FPlatformButtons do
    begin
      if (Button.TagString <> '') and not FConfiguredPlatforms.Contains(Button.TagString) then
        Continue;
      var Index := ComboBoxPlatform.Items.AddObject(LibrarySystemFullName(Button.TagString), Button);
      if Button.TagString = FSystemFilter then
        SelectedIndex := Index;
    end;
    ComboBoxPlatform.ItemIndex := SelectedIndex;
  finally
    ComboBoxPlatform.Items.EndUpdate;
    ComboBoxPlatform.OnChange := PlatformChange;
  end;
end;

procedure TLibraryView.PlatformChange(Sender: TObject);
begin
  var Index := ComboBoxPlatform.ItemIndex;
  if FBuilding or (Index < 0) or (Index >= ComboBoxPlatform.Items.Count) then
    Exit;
  var Button := TButton(ComboBoxPlatform.Items.Objects[Index]);
  if Button.TagString = FSystemFilter then
    Exit;
  FilterClick(Button);
end;

procedure TLibraryView.FilterClick(Sender: TObject);
begin
  FSystemFilter := TButton(Sender).TagString;
  FLetterFilter := '';
  FLimit := 48;
  BuildCards;
  VertScrollBoxScroll.ViewportPosition := TPointF.Zero;
end;

procedure TLibraryView.ModeClick(Sender: TObject);
begin
  FMode := TButton(Sender).Tag;
  FLetterFilter := '';
  FLimit := 48;
  BuildCards;
end;

procedure TLibraryView.SearchChange(Sender: TObject);
begin
  FLetterFilter := '';
  FLimit := 48;
  BuildCards;
end;

procedure TLibraryView.LetterClick(Sender: TObject);
begin
  FLetterFilter := TButton(Sender).TagString;
  FLimit := 48;
  BuildCards;
  VertScrollBoxScroll.ViewportPosition := TPointF.Zero;
end;

procedure TLibraryView.CardClick(Sender: TObject);
begin
  FSelected := TLibraryGame(TPanel(Sender).TagObject);
  for var Card in FCards do
    Card.Selection.Visible := Card.TagObject = FSelected;
  UpdateInspector;
  if Width < 1120 then
  begin
    FInspectorOpen := True;
    Resize;
  end;
end;

function TLibraryView.CloseDetails: Boolean;
begin
  Result := FInspectorOpen;
  FInspectorOpen := False;
  Resize;
end;

procedure TLibraryView.DetailsBackClick(Sender: TObject);
begin
  CloseDetails;
end;

{$IFDEF ISMOBILE}
procedure TLibraryView.CardTap(Sender: TObject; const Point: TPointF);
begin
  CardClick(Sender);
end;
{$ELSE}

procedure TLibraryView.CardDblClick(Sender: TObject);
begin
  if PanelInspector.Visible then
  begin
    CardClick(Sender);
    PlayClick(Self);
  end;
end;
{$ENDIF}

procedure TLibraryView.PlayClick(Sender: TObject);
begin
  FSnapshotName := '';
  if (FSelected <> nil) and Assigned(FOnPlay) then
    FOnPlay(Self);
end;

procedure TLibraryView.ResumeClick(Sender: TObject);
begin
  if FRecent = nil then
    Exit;

  FSelected := FRecent;
  var Saves := Snapshots(FRecent);
  FSnapshotName := '';
  if Length(Saves) > 0 then
    FSnapshotName := Saves[0].Location;
  if Assigned(FOnPlay) then
    FOnPlay(Self);
end;

procedure TLibraryView.SaveClick(Sender: TObject);
begin
  FSnapshotName := TButton(Sender).TagString;
  if Assigned(FOnPlay) then
    FOnPlay(Self);
end;

procedure TLibraryView.FavoriteClick(Sender: TObject);
begin
  if FSelected = nil then
    Exit;

  FSelected.Favorite := not FSelected.Favorite;
  FState.WriteBool('Favorites', FSelected.Key, FSelected.Favorite);
  SaveState;
  // The favorite action lives in the inspector, which survives card rebuilds.
  BuildCards;
end;

procedure TLibraryView.UpdateViewIcons;
begin
  if FListMode then
  begin
    FListIcon.Stroke.Color := $FFFFB344;
    FGridIcon.Stroke.Color := $FFE8ECF1;
  end
  else
  begin
    FListIcon.Stroke.Color := $FFE8ECF1;
    FGridIcon.Stroke.Color := $FFFFB344;
  end;
end;

procedure TLibraryView.ViewClick(Sender: TObject);
begin
  FListMode := TButton(Sender).Tag = 1;
  UpdateViewIcons;
  var Ini := FStorage.ReadConfig(FStorage.ConfigFile('config'));
  try
    if FListMode then
      Ini.WriteString('Library', 'View', 'list')
    else
      Ini.WriteString('Library', 'View', 'grid');
    FStorage.WriteConfig(Ini);
  finally
    Ini.Free;
  end;
  ArrangeCards;
end;

procedure TLibraryView.MoreClick(Sender: TObject);
begin
  if FBuilding or (LayoutGrid = nil) then
    Exit;
  var Viewport := VertScrollBoxScroll.ViewportPosition;
  Inc(FLimit, 48);
  BuildCards(True);
  VertScrollBoxScroll.ViewportPosition := Viewport;
end;

procedure TLibraryView.InitializePadView;
begin
  LayoutGamepadLibrary := FindComponent('LayoutGamepadLibrary') as TLayout;
  LayoutPadCarousel := FindComponent('LayoutPadCarousel') as TLayout;
  LayoutPadTouchSurface := FindComponent('LayoutPadTouchSurface') as TLayout;
  LayoutPadTouchSurface.AutoCapture := True;
  LayoutPadTouchSurface.OnMouseDown := PadTouchDown;
  LayoutPadTouchSurface.OnMouseMove := PadTouchMove;
  LayoutPadTouchSurface.OnMouseUp := PadTouchUp;
  LayoutPadTouchSurface.OnMouseWheel := PadMouseWheel;
  LayoutPadPlatformSurface := FindComponent('LayoutPadPlatformTouchSurface') as TLayout;
  LayoutPadPlatformTrack := FindComponent('LayoutPadPlatformTrack') as TLayout;
  LayoutPadPlatformViewport := FindComponent('LayoutPadPlatformViewport') as TLayout;
  LayoutPadPlatformSurface.AutoCapture := True;
  LayoutPadPlatformSurface.OnMouseDown := PadPlatformDown;
  LayoutPadPlatformSurface.OnMouseMove := PadPlatformMove;
  LayoutPadPlatformSurface.OnMouseUp := PadPlatformUp;
  TimerPadPlatforms := FindComponent('TimerPadPlatforms') as TTimer;
  TimerPadPlatforms.OnTimer := PadPlatformTick;
  TimerPadTransition := FindComponent('TimerPadTransition') as TTimer;
  TimerPadTransition.OnTimer := PadTransitionTick;
  TimerPadLayout := FindComponent('TimerPadLayout') as TTimer;
  TimerPadLayout.OnTimer := PadReflowTick;
  ImagePadPrevious := FindComponent('ImagePadPrevious') as TImage;
  ImagePadBackdrop := FindComponent('ImagePadBackdrop') as TImage;
  ImagePadBackdropNext := FindComponent('ImagePadBackdropNext') as TImage;
  TimerPadBackdrop := FindComponent('TimerPadBackdrop') as TTimer;
  TimerPadBackdrop.OnTimer := PadBackdropTick;
  (FindComponent('ButtonPadPagePlay') as TButton).OnClick := PadPageAction;
  (FindComponent('ButtonPadPageFavorite') as TButton).OnClick := PadPageAction;
  LabelPadTitle := FindComponent('LabelPadTitle') as TLabel;
  LabelPadInfo := FindComponent('LabelPadInfo') as TLabel;
  LabelPadDescription := FindComponent('LabelPadDescription') as TLabel;
  LabelPadCount := FindComponent('LabelPadCount') as TLabel;
  ButtonPadPlatform := FindComponent('ButtonPadPlatform') as TButton;
  ButtonPadFilter := FindComponent('ButtonPadFilter') as TButton;
  ButtonPadPlay := FindComponent('ButtonPadPlay') as TButton;
  SetLength(FPadSlots, 7);
  SetLength(FPadCovers, 7);
  SetLength(FPadLabels, 7);
  FPadSystemFirst := -1;
  FPadScrollFirst := -1;
  FPadAppearanceIndex := -1;
  SetLength(FPadSystemButtons, 1);
  FPadSystemButtons[0] := ButtonPadPlatform;
  ButtonPadPlatform.OnClick := PadPlatformClick;
  OnMouseWheel := PadMouseWheel;
  (FindComponent('LayoutPadPlatformViewport') as TLayout).OnResize := PadViewportResize;
  LayoutPadCarousel.OnResize := PadViewportResize;
  for var i := 0 to High(FPadSlots) do
  begin
    FPadSlots[i] := FindComponent('RectanglePadCover' + IntToStr(i)) as TRectangle;
    FPadCovers[i] := FindComponent('ImagePadCover' + IntToStr(i)) as TImage;
    FPadSlots[i].OnClick := PadAction;
    FPadLabels[i] := FindComponent('LabelPadCover' + IntToStr(i)) as TLabel;
  end;
  for var N in ['ButtonGamepadView'] do
    (FindComponent(N) as TButton).OnClick := TogglePadView;
  for var N in ['ButtonPadDesktop', 'ButtonPadPreviousPlatform', 'ButtonPadNextPlatform', 'ButtonPadFilter', 'ButtonPadPlay', 'ButtonPadFavorite', 'ButtonPadSettings'] do
    (FindComponent(N) as TButton).OnClick := PadAction;
end;

procedure TLibraryView.SelectPadStartPage;
begin
  FPadStartPending := False;
  FMode := 0;
  FSystemFilter := '';
  FLetterFilter := '';
  FSelected := nil;
  for var Game in FGames do
    if (Game.LastPlayed > 0) and ((FSelected = nil) or (Game.LastPlayed > FSelected.LastPlayed)) then
      FSelected := Game;
  if FSelected <> nil then
    FMode := 1;
  // An old desktop search must not hide the history/default catalog on entry.
  var Change := FSearch.OnChangeTracking;
  FSearch.OnChangeTracking := nil;
  try
    FSearch.Text := '';
  finally
    FSearch.OnChangeTracking := Change;
  end;
end;

procedure TLibraryView.ApplyOrientationPresentation(Landscape: Boolean);
begin
  {$IFDEF ISMOBILE}
  // Native rotation and intermediate resize events never change the mobile view.
  Landscape := True;
  {$ENDIF}
  if FClosing or (FOrientationKnown and (FOrientationLandscape = Landscape)) then
    Exit;
  FOrientationKnown := True;
  FOrientationLandscape := Landscape;
  FOrientationPending := True;
  // Apply outside native resize/alignment callbacks: switching rebuilds cards.
  TimerPadLayout.Enabled := True;
end;

procedure TLibraryView.SetPadMode(Enabled, Persist: Boolean);
begin
  {$IFDEF ISMOBILE}
  Enabled := True;
  Persist := False;
  {$ENDIF}
  if FPadMode = Enabled then
    Exit;
  CancelPadTouch;
  if FPadPageOpen then
    ClosePadGamePage;
  FPadMode := Enabled;
  FNavigation.Reset;
  FInspectorOpen := False;
  if Persist then
  begin
    FState.WriteBool('View', 'Gamepad', FPadMode);
    SaveState;
  end;
  if not FPadMode then
  begin
    TimerPadBackdrop.Enabled := False;
    FPadBackdropPending := False;
    FPadBackdropFading := False;
    FPadBackdropRequested := '';
    ImagePadBackdropNext.Visible := False;
    ImagePadBackdropNext.Bitmap.RemoveCallback(ImagePadBackdropNext);
    ImagePadBackdropNext.TagString := '';
  end;
  if not FPadMode then
    FLimit := Max(FLimit, FPadGames.IndexOf(FSelected) + 1);
  FinishPadSelection;
  FPadStartPending := FPadMode;
  // Keep selection and catalog filters shared between both presentations.
  BuildCards;
  Resize;
  if Assigned(FOnPresentationChanged) then
    FOnPresentationChanged(Self);
end;

procedure TLibraryView.TogglePadView(Sender: TObject);
begin
  if Sender <> nil then
    FNavigation.PointerUsed;
  SetPadMode(not FPadMode, True);
end;

procedure TLibraryView.EnsurePadSlots(Count: Integer);
begin
  if Count <= Length(FPadSlots) then
    Exit;
  var First := Length(FPadSlots);
  SetLength(FPadSlots, Count);
  SetLength(FPadCovers, Count);
  SetLength(FPadLabels, Count);
  FPadScrollFirst := -1;
  LayoutPadCarousel.BeginUpdate;
  try
    for var i := First to Count - 1 do
    begin
      var Slot := TRectangle.Create(Self);
      Slot.Name := 'RectanglePadCover' + IntToStr(i);
      Slot.Parent := LayoutPadCarousel;
      Slot.Align := TAlignLayout.Left;
      Slot.ClipChildren := True;
      Slot.Fill.Kind := TBrushKind.None;
      Slot.Stroke.Kind := TBrushKind.None;
      Slot.XRadius := 10;
      Slot.YRadius := 10;
      Slot.OnClick := PadAction;
      Slot.OnMouseWheel := PadMouseWheel;
      FPadSlots[i] := Slot;
      var Image := TImage.Create(Self);
      Image.Name := 'ImagePadCover' + IntToStr(i);
      Image.Parent := Slot;
      Image.Align := TAlignLayout.Client;
      Image.Margins.Rect := RectF(4, 4, 4, 4);
      Image.WrapMode := TImageWrapMode.Fit;
      Image.HitTest := False;
      FPadCovers[i] := Image;
      var Caption := TLabel.Create(Self);
      Caption.Name := 'LabelPadCover' + IntToStr(i);
      Caption.Parent := Slot;
      Caption.Align := TAlignLayout.Client;
      Caption.Margins.Rect := RectF(12, 12, 12, 12);
      Caption.StyledSettings := [];
      Caption.TextSettings.Font.Size := 12.8;
      Caption.TextSettings.HorzAlign := TTextAlign.Center;
      Caption.TextSettings.VertAlign := TTextAlign.Center;
      Caption.TextSettings.WordWrap := True;
      Caption.TextSettings.Trimming := TTextTrimming.Character;
      Caption.Visible := False;
      Caption.HitTest := False;
      FPadLabels[i] := Caption;
      var ShelfTitle := TLabel.Create(Self);
      ShelfTitle.Name := 'LabelPadShelfTitle' + IntToStr(i);
      ShelfTitle.Parent := Slot;
      ShelfTitle.Align := TAlignLayout.Bottom;
      ShelfTitle.Height := 24;
      ShelfTitle.Margins.Rect := RectF(6, 4, 6, 0);
      ShelfTitle.HitTest := False;
      ShelfTitle.StyledSettings := [];
      ShelfTitle.TextSettings.Font.Size := 11.2;
      ShelfTitle.TextSettings.WordWrap := False;
      ShelfTitle.TextSettings.Trimming := TTextTrimming.Character;
      ShelfTitle.Visible := False;
    end;
  finally
    LayoutPadCarousel.EndUpdate;
  end;
end;

procedure TLibraryView.UpdatePadCardAppearance(Image: TImage);
begin
  // The previous-image prefetch has no card or caption.
  if not (Image.Parent is TRectangle) then
    Exit;
  var Slot := TRectangle(Image.Parent);
  var Missing := Image.Bitmap.IsEmpty;
  var Selected := string(Slot.Name).StartsWith('RectanglePadCover') and (Slot.Tag >= 0) and (Slot.Tag < FPadGames.Count) and
    (FPadGames[Slot.Tag] = FSelected);
  Slot.Stroke.Kind := TBrushKind.None;
  Slot.Fill.Kind := TBrushKind.Solid;
  if Selected then
    Slot.Fill.Color := $FFFFB344
  else if Missing then
    Slot.Fill.Color := $FF252C32
  else
    Slot.Fill.Color := $99252C32;
  Image.Visible := not Missing;
  var ShelfTitle: TLabel := nil;
  if string(Slot.Name).StartsWith('RectanglePadCover') then
    ShelfTitle := FindComponent(string(Slot.Name).Replace('RectanglePadCover', 'LabelPadShelfTitle')) as TLabel;
  if ShelfTitle <> nil then
  begin
    ShelfTitle.Visible := not Missing;
    if ShelfTitle.Visible then
      ShelfTitle.ApplyStyleLookup;
    if (Slot.Tag >= 0) and (Slot.Tag < FPadGames.Count) then
      ShelfTitle.Text := FPadGames[Slot.Tag].Title;
    if Selected then
      ShelfTitle.TextSettings.FontColor := $FF181C21
    else
      ShelfTitle.TextSettings.FontColor := $FFE8ECF1;
  end;
  for var i := 0 to Slot.ControlsCount - 1 do
    if (Slot.Controls[i] is TLabel) and (Slot.Controls[i] <> ShelfTitle) then
    begin
      var Caption := TLabel(Slot.Controls[i]);
      Caption.Visible := Missing;
      if Selected then
        Caption.TextSettings.FontColor := $FF181C21
      else
        Caption.TextSettings.FontColor := $FFE8ECF1;
    end;
  RoundPadTextSizes(Slot);
end;

procedure TLibraryView.LoadPadCover(Image: TImage; Game: TLibraryGame);
begin
  if Image.Parent is TRectangle then
    for var i := 0 to TRectangle(Image.Parent).ControlsCount - 1 do
      if TRectangle(Image.Parent).Controls[i] is TLabel then
        TLabel(TRectangle(Image.Parent).Controls[i]).Text := Game.Title;
  var Location := Game.GamepadCover;
  if Image.TagString = Location then
  begin
    UpdatePadCardAppearance(Image);
    Exit;
  end;
  Image.TagString := Location;
  Image.Bitmap.RemoveCallback(Image);
  Image.Bitmap := nil;
  UpdatePadCardAppearance(Image);
  if Location = '' then
    Exit;
  var Fallback := Game.Cover;
  Image.Bitmap.LoadFromFileAsync(Image, Location, 420, 600,
    procedure(Success: Boolean)
    begin
      // Capture paths, not a catalog object which can be replaced during reload.
      if FClosing or (Image.TagString <> Location) then
        Exit;
      if not Success and (Fallback <> '') and (Fallback <> Location) then
        Image.Bitmap.LoadFromFileAsync(Image, Fallback, 420, 600,
          procedure(FallbackSuccess: Boolean)
          begin
            if not FClosing and (Image.TagString = Location) then
              UpdatePadCardAppearance(Image);
          end, FStorage)
      else
        UpdatePadCardAppearance(Image);
    end, FStorage);
end;

procedure TLibraryView.ResizePadView;
begin
  if (LayoutPadCarousel = nil) or FPadArranging then
    Exit;
  FPadArranging := True;
  try
    var Side := IfThen(Width < 700, 18, IfThen(Width < 1200, 32, 54));
    var Short := Height < 500;
    LayoutGamepadLibrary.BeginUpdate;
    try
      LayoutGamepadLibrary.Padding.Rect := RectF(Side, IfThen(Short, 10, 24), Side, IfThen(Short, 8, 16));
      (FindComponent('LayoutPadHeaderSection') as TLayout).Visible := True;
      (FindComponent('LayoutPadHeaderSection') as TLayout).Height := IfThen(Short, 34, 42);
      (FindComponent('LayoutPadPlatforms') as TLayout).Height := IfThen(Short, 34, 42);
      (FindComponent('LabelPadBrand') as TLabel).Visible := Width >= 760;
      (FindComponent('LabelPadBrand') as TLabel).Width := IfThen(Width < 1100, 72, 108);
      (FindComponent('TextPadClock') as TText).Visible := Width >= 650;
      (FindComponent('TextPadClock') as TText).Width := 58;
      (FindComponent('PathPadBrandIcon') as FMX.Objects.TPath).Visible := Width >= 600;
      (FindComponent('LayoutPadShelf') as TLayout).Visible := not FPadPageOpen;
      (FindComponent('LayoutPadShelf') as TLayout).Height := Min(Max(0, Height - IfThen(Short, 100, 132)),
          EnsureRange(Height * 0.44, 240.0, 430.0));
      (FindComponent('LayoutPadTitle') as TLayout).Height := IfThen(Short, 54, 68);
      LabelPadTitle.TextSettings.Font.Size := IfThen(Short, 23, IfThen(Width < 1000, 28, 34));
      (FindComponent('LabelPadSubtitle') as TLabel).TextSettings.Font.Size := IfThen(Short, 10.4, 12.8);
      (FindComponent('LayoutPadBottomSection') as TLayout).Height := IfThen(Short, 32, 44);
      (FindComponent('LayoutPadInfo') as TLayout).Margins.Rect := TRectF.Empty;
      (FindComponent('LayoutPadMetaColumns') as TLayout).Visible := False;
      LabelPadDescription.Height := 20;
      LabelPadDescription.TextSettings.Font.Size := IfThen(Short, 10.4, 12.8);
      (FindComponent('LayoutPadProgress') as TLayout).Height := 10;
      (FindComponent('LayoutPadProgressTrack') as TLayout).Width := Min(440, Max(100, Width * 0.32));
      (FindComponent('LayoutPadActionsSection') as TLayout).Height := IfThen(Short, 36, 44);
      (FindComponent('LayoutPadFooter') as TLayout).Height := IfThen(Short, 32, 36);
      (FindComponent('LayoutPadFooter') as TLayout).Margins.Top := 0;
      (FindComponent('LayoutPadNavigationSection') as TLayout).Width := IfThen(Width < 780, 28, 94);
      (FindComponent('TextPadNavigationHint') as TText).Visible := Width >= 780;
      (FindComponent('LayoutPadBackSection') as TLayout).Width := IfThen(Width < 650, 42, 100);
      (FindComponent('LayoutPadFavoriteSection') as TLayout).Width := IfThen(Width < 650, 42, IfThen(FPadPageOpen, 186, 140));
      for var Name in ['ButtonPadDesktop', 'ButtonPadFavorite', 'ButtonPadSettings'] do
      begin
        var Button := FindComponent(Name) as TButton;
        var ShowCaption := Width >= 650;
        var W := 100;
        if Name = 'ButtonPadFavorite' then
          W := IfThen(FPadPageOpen, 178, 132);
        if Name = 'ButtonPadSettings' then
          W := 116;
        if not ShowCaption then
          W := 38;
        Button.Width := W;
        Button.Margins.Right := 8;
        (FindComponent('TextCaption' + Name) as TText).Visible := ShowCaption;
        (FindComponent('TextCaption' + Name) as TText).TextSettings.Font.Size := 11.2;
      end;
      ButtonPadPlay.Width := IfThen(Width < 650, 94, 118);
      (FindComponent('TextCaptionButtonPadPlay') as TText).TextSettings.Font.Size := 11.2;
      for var Name in ['RectanglePadNavDivider', 'RectanglePadBackDivider', 'RectanglePadFavoriteDivider'] do
        (FindComponent(Name) as TRectangle).Visible := False;
      (FindComponent('LayoutPadPlatforms') as TLayout).Enabled := not FPadPageOpen;
    finally
      LayoutGamepadLibrary.EndUpdate;
    end;
    EnsurePadSlots(Max(8, Ceil(LayoutPadCarousel.Width / Max(24, PadTouchStep)) + 7));
    if FPadTouchScrolling then
      LayoutPadScroll
    else
      LayoutPadSlots;
    UpdatePadPlatforms;
    var Track := FindComponent('LayoutPadProgressTrack') as TLayout;
    var Thumb := FindComponent('RectanglePadProgressThumb') as TRectangle;
    Track.Visible := FPadGames.Count > 0;
    Thumb.Width := IfThen(FPadGames.Count <= 1, Track.Width, Min(48, Max(18, Track.Width / Max(1, FPadGames.Count))));
    (FindComponent('LayoutPadProgressOffset') as TLayout).Width := Max(0, FPadScrollPosition) /
      Max(1, FPadGames.Count - 1) * Max(0, Track.Width - Thumb.Width);
    LayoutPadBackdrop;
    if FPadPageOpen then
      ResizePadGamePage;
    RoundPadTextSizes(LayoutGamepadLibrary);
  finally
    FPadArranging := False;
  end;
end;

procedure TLibraryView.PadViewportResize(Sender: TObject);
begin
  if FPadArranging or FPadScrollArranging or FPadPlatformArranging then
    Exit;
  CancelPadTouch;
  if FClosing or FBuilding or (TimerPadLayout = nil) then
    Exit;
  // Resize notifications can arrive while an ancestor's AlignObjects is still
  // running. Reflow after that pass, never mutate its alignment sort keys.
  TimerPadLayout.Enabled := True;
end;

procedure TLibraryView.PadReflowTick(Sender: TObject);
begin
  TimerPadLayout.Enabled := False;
  if FClosing then
    Exit;
  if FOrientationPending then
  begin
    if FBuilding then
    begin
      TimerPadLayout.Enabled := True;
      Exit;
    end;
    FOrientationPending := False;
    SetPadMode(FOrientationLandscape, False);
  end;
  if FPadMode then
  begin
    ResizePadView;
    // Resize callbacks can cancel an in-flight platform transition after its
    // target was calculated. Resolve visibility against the settled viewport.
    UpdatePadPlatforms(True);
    // Newly pooled controls can receive their scene/style only after the
    // ancestor alignment pass. Complete that lookup before the next paint.
    for var i := 0 to ComponentCount - 1 do
      if (Components[i] is TStyledControl) and string(Components[i].Name).Contains('Pad') then
        TStyledControl(Components[i]).ApplyStyleLookup;
  end;
end;

procedure TLibraryView.UpdatePadPlatforms(KeepActiveVisible: Boolean);
begin
  var Signature := ActivePadTab + '|' + string.Join(',', FConfiguredPlatforms.ToArray) + '|' +
    IntToStr(Round(LayoutPadPlatformViewport.Width)) + '|' + FormStyles.Lang.Lang;
  if (Signature = FPadSystemSignature) and not KeepActiveVisible then
    Exit;
  var Initialized := Length(FPadSystems) > 0;
  var OldPitch := FPadPlatformPitch;
  CancelPadPlatformTouch;
  FPadSystemSignature := Signature;
  FPadSystems := ['', '@recent', '@favorites'] + FConfiguredPlatforms.ToArray;
  FPadPlatformPitch := Min(IfThen(Width < 1000, 92, 112), Max(1, LayoutPadPlatformViewport.Width));
  FPadPlatformMaximum := Max(0, Length(FPadSystems) - LayoutPadPlatformViewport.Width / FPadPlatformPitch);
  var Active := 0;
  for var i := 0 to High(FPadSystems) do
    if FPadSystems[i] = ActivePadTab then
      Active := i;
  var VisibleCount := Max(1, Floor(LayoutPadPlatformViewport.Width / FPadPlatformPitch));
  FPadPlatformTarget := EnsureRange(Double(Active - Min(2, VisibleCount - 1)), 0, FPadPlatformMaximum);
  FPadPlatformPosition := EnsureRange(FPadPlatformPosition, 0, FPadPlatformMaximum);
  if KeepActiveVisible or not Initialized or not SameValue(OldPitch, FPadPlatformPitch) then
    FPadPlatformPosition := FPadPlatformTarget;
  FPadPlatformMoving := Abs(FPadPlatformPosition - FPadPlatformTarget) > 0.001;
  FPadPlatformSnapping := True;
  FPadPlatformVelocity := 0;
  FPadPlatformTick := TThread.GetTickCount64;
  LayoutPadPlatforms;
  TimerPadPlatforms.Enabled := FPadPlatformMoving;
end;

procedure TLibraryView.LayoutPadPlatforms;
begin
  if FPadPlatformArranging or (FPadPlatformPitch <= 0) then
    Exit;
  FPadPlatformArranging := True;
  LayoutPadPlatformTrack.BeginUpdate;
  try
    var Count := Min(Length(FPadSystems), Ceil(Max(0, LayoutPadPlatformViewport.Width) / FPadPlatformPitch) + 3);
    var OldCount := Length(FPadSystemButtons);
    if OldCount < Count then
    begin
      SetLength(FPadSystemButtons, Count);
      for var i := OldCount to Count - 1 do
      begin
        var B := TButton.Create(Self);
        B.Name := 'ButtonPadSystem' + IntToStr(i);
        B.Parent := LayoutPadPlatformTrack;
        B.Align := TAlignLayout.Left;
        B.StyledSettings := [];
        B.TextSettings.Font.Size := (16) * 0.8;
        B.OnClick := PadPlatformClick;
        FPadSystemButtons[i] := B;
      end;
    end;
    var First := Max(0, Floor(FPadPlatformPosition) - 1);
    FPadSystemFirst := First;
    var Offset := (FPadPlatformPosition - First) * FPadPlatformPitch;
    // The track must cover its pooled children even when the leading slot is
    // outside a narrow viewport; otherwise FMX culls the entire track.
    LayoutPadPlatformTrack.Width := Count * FPadPlatformPitch;
    LayoutPadPlatformTrack.Margins.Rect := RectF(-Offset, 0, 0, 0);
    for var i := 0 to High(FPadSystemButtons) do
    begin
      var B := FPadSystemButtons[i];
      var Index := First + i;
      B.Visible := (i < Count) and (Index < Length(FPadSystems));
      if not B.Visible then
        Continue;
      B.Enabled := True;
      B.Opacity := 1;
      B.Width := FPadPlatformPitch - 8;
      B.Margins.Right := 8;
      B.Position.X := i * 1000;
      B.Tag := Index;
      B.TagString := FPadSystems[Index];
      B.Text := LibrarySystemName(B.TagString);
      if B.TagString = '@recent' then
        B.Text := Translate('Recent');
      if B.TagString = '@favorites' then
        B.Text := Translate('Favorites');
      var Style := 'buttonstyle_subtle';
      var Color: TAlphaColor := $FFB9C2CC;
      if B.TagString = ActivePadTab then
      begin
        Style := 'buttonstyle_accent';
        Color := $FF181C21;
        ButtonPadPlatform := B;
      end;
      if B.StyleLookup <> Style then
        B.StyleLookup := Style;
      B.TextSettings.FontColor := Color;
    end;
  finally
    LayoutPadPlatformTrack.EndUpdate;
    FPadPlatformArranging := False;
  end;
  // Pooled buttons can acquire their scene/style after the parent alignment pass.
  for var B in FPadSystemButtons do
    if B.Visible then
    begin
      B.ApplyStyleLookup;
      RoundPadTextSizes(B);
    end;
end;

procedure TLibraryView.CancelPadPlatformTouch;
begin
  FPadPlatformDown := False;
  FPadPlatformHorizontal := False;
  FPadPlatformVertical := False;
  FPadPlatformVelocity := 0;
  FPadPlatformMoving := False;
  if TimerPadPlatforms <> nil then
    TimerPadPlatforms.Enabled := False;
  if (LayoutPadPlatformSurface <> nil) and (Root <> nil) and (Root.Captured <> nil) and
    (Root.Captured.GetObject = LayoutPadPlatformSurface) then
    Root.SetCaptured(nil);
  FPadPlatformPosition := EnsureRange(Double(Round(FPadPlatformPosition)), 0, FPadPlatformMaximum);
  if not FClosing and not FBuilding then
    LayoutPadPlatforms;
end;

procedure TLibraryView.PadPlatformDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Single);
begin
  if (Button <> TMouseButton.mbLeft) or not FPadMode or (FPadPlatformPitch <= 0) then
    Exit;
  FNavigation.PointerUsed;
  UpdatePadHints;
  FinishPadSelection;
  FPadPlatformInterrupted := FPadPlatformMoving;
  TimerPadPlatforms.Enabled := False;
  FPadPlatformVelocity := 0;
  FPadPlatformDown := True;
  FPadPlatformHorizontal := False;
  FPadPlatformVertical := False;
  FPadPlatformStart := PointF(X, Y);
  FPadPlatformLastX := X;
  FPadPlatformOrigin := FPadPlatformPosition;
  FPadPlatformLastTick := TThread.GetTickCount64;
  FPadPlatformHit := -1;
  var Point := LayoutPadPlatformSurface.LocalToAbsolute(PointF(X, Y));
  for var B in FPadSystemButtons do
    if B.Visible and B.AbsoluteRect.Contains(Point) then
    begin
      FPadPlatformHit := B.Tag;
      Break;
    end;
end;

procedure TLibraryView.PadPlatformMove(Sender: TObject; Shift: TShiftState; X, Y: Single);
begin
  if not FPadPlatformDown then
    Exit;
  var DX := Abs(X - FPadPlatformStart.X);
  var DY := Abs(Y - FPadPlatformStart.Y);
  if not FPadPlatformHorizontal and not FPadPlatformVertical and (Max(DX, DY) >= 12) then
  begin
    FPadPlatformHorizontal := DX > DY * 1.2;
    FPadPlatformVertical := DY > DX * 1.2;
  end;
  if not FPadPlatformHorizontal then
    Exit;
  FPadPlatformMoving := True;
  var Now := TThread.GetTickCount64;
  var DT := (Now - FPadPlatformLastTick) / 1000.0;
  if DT >= 0.004 then
  begin
    var Speed := EnsureRange((FPadPlatformLastX - X) / DT, -2600.0, 2600.0);
    FPadPlatformVelocity := FPadPlatformVelocity + (Speed - FPadPlatformVelocity) * (1 - Exp(-DT / 0.04));
    if DT > 0.12 then
      FPadPlatformVelocity := Speed;
    FPadPlatformLastX := X;
    FPadPlatformLastTick := Now;
  end;
  var Position := FPadPlatformOrigin + (FPadPlatformStart.X - X) / FPadPlatformPitch;
  if (Position < 0) or (Position > FPadPlatformMaximum) then
    FPadPlatformVelocity := 0;
  FPadPlatformPosition := EnsureRange(Position, 0, FPadPlatformMaximum);
  LayoutPadPlatforms;
end;

procedure TLibraryView.PadPlatformUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Single);
begin
  if (Button <> TMouseButton.mbLeft) or not FPadPlatformDown then
    Exit;
  PadPlatformMove(Sender, Shift, X, Y);
  FPadPlatformDown := False;
  if FPadPlatformMoving then
  begin
    if TThread.GetTickCount64 - FPadPlatformLastTick > 100 then
      FPadPlatformVelocity := 0;
    FPadPlatformSnapping := Abs(FPadPlatformVelocity) < 70;
    FPadPlatformTarget := EnsureRange(Double(Round(FPadPlatformPosition)), 0, FPadPlatformMaximum);
    FPadPlatformTick := TThread.GetTickCount64;
    TimerPadPlatforms.Enabled := True;
  end
  else if not FPadPlatformVertical and not FPadPlatformInterrupted and
    (Abs(X - FPadPlatformStart.X) < 12) and (Abs(Y - FPadPlatformStart.Y) < 12) and
    (FPadPlatformHit >= 0) and (FPadPlatformHit < Length(FPadSystems)) then
  begin
    var Id := FPadSystems[FPadPlatformHit];
    CancelPadTouch;
    FNavigation.PointerUsed;
    SelectPadTab(Id);
  end;
end;

procedure TLibraryView.PadPlatformTick(Sender: TObject);
begin
  if FPadPlatformDown then
    Exit;
  var Now := TThread.GetTickCount64;
  var DT := Min(0.05, (Now - FPadPlatformTick) / 1000.0);
  FPadPlatformTick := Now;
  if DT <= 0 then
    Exit;
  var Done := AdvanceLibraryScroll(FPadPlatformPosition, FPadPlatformVelocity, FPadPlatformTarget,
    FPadPlatformSnapping, DT, FPadPlatformPitch, FPadPlatformMaximum);
  LayoutPadPlatforms;
  if Done then
  begin
    TimerPadPlatforms.Enabled := False;
    FPadPlatformMoving := False;
  end;
end;

procedure TLibraryView.PadPlatformClick(Sender: TObject);
begin
  CancelPadTouch;
  FinishPadSelection;
  SelectPadTab(TButton(Sender).TagString);
end;

procedure TLibraryView.PadMouseWheel(Sender: TObject; Shift: TShiftState; WheelDelta: Integer; var Handled: Boolean);
begin
  if FPadMode and FPadPageOpen and (WheelDelta <> 0) then
  begin
    var Scroll := FindComponent('VertScrollBoxPadPage') as TVertScrollBox;
    Scroll.ViewportPosition := PointF(0, Max(0, Scroll.ViewportPosition.Y - WheelDelta * 0.5));
    Handled := True;
    Exit;
  end;
  if not FPadMode or (WheelDelta = 0) then
    Exit;
  FNavigation.PointerUsed;
  Handled := True;
  Inc(FPadWheelDelta, WheelDelta);
  while Abs(FPadWheelDelta) >= 120 do
  begin
    if FPadWheelDelta > 0 then
    begin
      Dec(FPadWheelDelta, 120);
      PadCommand(0);
    end
    else
    begin
      Inc(FPadWheelDelta, 120);
      PadCommand(1);
    end;
  end;
end;

procedure TLibraryView.CancelPadTouch;
begin
  CancelPadPlatformTouch;
  FPadTouchDown := False;
  FPadTouchHorizontal := False;
  FPadTouchVertical := False;
  FPadTouchIndex := -1;
  if (LayoutPadTouchSurface <> nil) and (Root <> nil) and
    (Root.Captured <> nil) and (Root.Captured.GetObject = LayoutPadTouchSurface) then
    Root.SetCaptured(nil);
  if FPadTouchScrolling then
  begin
    if FPadKeyScrolling then
      FPadScrollPosition := FPadScrollTarget;
    EndPadScroll;
  end;
end;

function TLibraryView.PadTouchStep: Single;
begin
  // The physical pitch must equal the rendered small card plus its gap.
  Result := Min(290, Max(1, LayoutPadCarousel.Height)) * 0.68 * 0.90 + 18;
end;

procedure TLibraryView.BindPadScrollSlots(First: Integer);
begin
  for var i := 0 to High(FPadSlots) do
  begin
    var Index := First + i;
    var Visible := (Index >= 0) and (Index < FPadGames.Count);
    if Visible then
    begin
      var Cover := FPadGames[Index].GamepadCover;
      // Keep every still-visible image alive while the pool gains leading slots.
      var Reuse := -1;
      for var J := i to High(FPadSlots) do
        if (FPadSlots[J].Tag = Index) and (FPadCovers[J].TagString = Cover) then
        begin
          Reuse := J;
          Break;
        end;
      if Reuse < 0 then
        for var J := i to High(FPadSlots) do
        begin
          var OldIndex := FPadSlots[J].Tag;
          if (OldIndex < First) or (OldIndex >= First + Length(FPadSlots)) or
            (OldIndex >= FPadGames.Count) or
            ((OldIndex >= 0) and (FPadCovers[J].TagString <> FPadGames[OldIndex].GamepadCover)) then
          begin
            Reuse := J;
            Break;
          end;
        end;
      if Reuse < 0 then
        Reuse := i;
      var Slot := FPadSlots[i];
      FPadSlots[i] := FPadSlots[Reuse];
      FPadSlots[Reuse] := Slot;
      var Image := FPadCovers[i];
      FPadCovers[i] := FPadCovers[Reuse];
      FPadCovers[Reuse] := Image;
      var Caption := FPadLabels[i];
      FPadLabels[i] := FPadLabels[Reuse];
      FPadLabels[Reuse] := Caption;
      FPadSlots[i].Tag := Index;
      if (FPadCovers[i].TagString <> Cover) and
        (ImagePadPrevious.TagString = Cover) and not ImagePadPrevious.Bitmap.IsEmpty then
      begin
        FPadCovers[i].Bitmap.RemoveCallback(FPadCovers[i]);
        FPadCovers[i].Bitmap.Assign(ImagePadPrevious.Bitmap);
        FPadCovers[i].TagString := Cover;
      end
      else
        LoadPadCover(FPadCovers[i], FPadGames[Index]);
      FPadLabels[i].Text := FPadGames[Index].Title;
    end;
    FPadSlots[i].Visible := Visible;
  end;
end;

procedure TLibraryView.LayoutPadScroll;
begin
  if not FPadTouchScrolling or FPadScrollArranging then
    Exit;
  FPadScrollArranging := True;
  LayoutPadCarousel.BeginUpdate;
  try
    var Base := Floor(FPadScrollPosition);
    var First := Max(0, Base - 3);
    var Rebound := FPadScrollFirst <> First;
    if Rebound then
    begin
      BindPadScrollSlots(First);
      FPadScrollFirst := First;
    end;
    var SelectedIndex := FPadGames.IndexOf(FSelected);
    var AppearanceChanged := Rebound or (FPadAppearanceIndex <> SelectedIndex);
    var H := Min(290, Max(1, LayoutPadCarousel.Height));
    var Large := H * 0.68;
    var Small := Large * 0.90;
    var Fraction := FPadScrollPosition - Base;
    var Blend := Fraction * Fraction * (3 - 2 * Fraction);
    var Offset := (FPadScrollPosition - First - Min(2.0, FPadScrollPosition)) * PadTouchStep;
    LayoutPadCarousel.Margins.Rect := RectF(-Offset, 0, Offset, 0);
    for var i := 0 to High(FPadSlots) do
    begin
      var Focus: Single := 0;
      if FPadSlots[i].Tag = Base then
        Focus := 1 - Blend
      else if FPadSlots[i].Tag = Base + 1 then
        Focus := Blend;
      FPadSlots[i].Width := Small + (Large - Small) * Focus;
      FPadSlots[i].Margins.Top := H * 0.035 * (1 - Focus);
      FPadSlots[i].Margins.Bottom := Max(0, LayoutPadCarousel.Height - H + H * 0.07 * (1 - Focus));
      FPadSlots[i].Margins.Right := 18;
      if Rebound then
        FPadSlots[i].Position.X := i * 1000;
      FPadSlots[i].Opacity := 1;
      if AppearanceChanged then
        UpdatePadCardAppearance(FPadCovers[i]);
    end;
    FPadAppearanceIndex := SelectedIndex;
    var Track := FindComponent('LayoutPadProgressTrack') as TLayout;
    var Thumb := FindComponent('RectanglePadProgressThumb') as TRectangle;
    (FindComponent('LayoutPadProgressOffset') as TLayout).Width :=
      FPadScrollPosition / Max(1, FPadGames.Count - 1) * Max(0, Track.Width - Thumb.Width);
  finally
    LayoutPadCarousel.EndUpdate;
    FPadScrollArranging := False;
  end;
  // Complete rounding after parent alignment, including newly visible styles.
  RoundPadTextSizes(LayoutPadCarousel);
end;

procedure TLibraryView.SetPadScrollPosition(Value: Double);
begin
  FPadScrollPosition := EnsureRange(Value, 0, Max(0, FPadGames.Count - 1));
  var Index := EnsureRange(Round(FPadScrollPosition), 0, Max(0, FPadGames.Count - 1));
  if not FPadKeyScrolling and (FPadGames.Count > 0) and (FSelected <> FPadGames[Index]) then
  begin
    FSelected := FPadGames[Index];
    UpdatePadView(False);
  end;
  LayoutPadScroll;
end;

procedure TLibraryView.EndPadScroll;
begin
  TimerPadTransition.Enabled := False;
  FPadScrollVelocity := 0;
  FPadTouchScrolling := False;
  FPadKeyScrolling := False;
  var Index := EnsureRange(Round(FPadScrollPosition), 0, Max(0, FPadGames.Count - 1));
  FPadScrollPosition := Index;
  if FPadGames.Count > 0 then
    FSelected := FPadGames[Index];
  if not FClosing then
    UpdatePadView(False);
end;

procedure TLibraryView.PadTouchDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Single);
begin
  if (Button <> TMouseButton.mbLeft) or not FPadMode or FClosing or (FLoadThread <> nil) then
    Exit;
  FNavigation.PointerUsed;
  UpdatePadHints;
  FPadTouchInterrupted := FPadTouchScrolling;
  if not FPadTouchScrolling then
  begin
    FinishPadSelection;
    FPadScrollPosition := Max(0, FPadGames.IndexOf(FSelected));
  end;
  TimerPadTransition.Enabled := False;
  FPadScrollVelocity := 0;
  FPadTouchOrigin := FPadScrollPosition;
  FPadKeyScrolling := False;
  FPadTouchDown := True;
  FPadTouchHorizontal := False;
  FPadTouchVertical := False;
  FPadTouchStart := PointF(X, Y);
  FPadTouchLastX := X;
  FPadTouchLastTick := TThread.GetTickCount64;
  FPadTouchIndex := -1;
  var Point := LayoutPadTouchSurface.LocalToAbsolute(FPadTouchStart);
  for var Slot in FPadSlots do
    if Slot.Visible and Slot.AbsoluteRect.Contains(Point) then
    begin
      FPadTouchIndex := Slot.Tag;
      Break;
    end;
end;

procedure TLibraryView.PadTouchMove(Sender: TObject; Shift: TShiftState; X, Y: Single);
begin
  if not FPadTouchDown then
    Exit;
  var DX := Abs(X - FPadTouchStart.X);
  var DY := Abs(Y - FPadTouchStart.Y);
  if not FPadTouchHorizontal and not FPadTouchVertical and (Max(DX, DY) >= 12) then
  begin
    FPadTouchHorizontal := DX > DY * 1.2;
    FPadTouchVertical := DY > DX * 1.2;
  end;
  if not FPadTouchHorizontal then
    Exit;
  FNavigation.PointerUsed;
  FPadTouchScrolling := True;
  var Now := TThread.GetTickCount64;
  var DT := (Now - FPadTouchLastTick) / 1000.0;
  if DT >= 0.004 then
  begin
    var Speed := EnsureRange((FPadTouchLastX - X) / DT, -2600.0, 2600.0);
    FPadScrollVelocity := FPadScrollVelocity + (Speed - FPadScrollVelocity) * (1 - Exp(-DT / 0.04));
    if DT > 0.12 then
      FPadScrollVelocity := Speed;
    FPadTouchLastX := X;
    FPadTouchLastTick := Now;
  end;
  var Position := FPadTouchOrigin + (FPadTouchStart.X - X) / PadTouchStep;
  if (Position < 0) or (Position > FPadGames.Count - 1) then
    FPadScrollVelocity := 0;
  SetPadScrollPosition(Position);
end;

procedure TLibraryView.PadTouchUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Single);
begin
  if (Button <> TMouseButton.mbLeft) or not FPadTouchDown then
    Exit;
  PadTouchMove(Sender, Shift, X, Y);
  FPadTouchDown := False;
  if FPadTouchScrolling then
  begin
    if TThread.GetTickCount64 - FPadTouchLastTick > 100 then
      FPadScrollVelocity := 0;
    FPadScrollSnapping := Abs(FPadScrollVelocity) < 70;
    FPadScrollTarget := Round(FPadScrollPosition);
    FPadScrollTick := TThread.GetTickCount64;
    TimerPadTransition.Enabled := True;
  end
  else if not FPadTouchVertical and not FPadTouchInterrupted and
    (Abs(X - FPadTouchStart.X) < 12) and (Abs(Y - FPadTouchStart.Y) < 12) and
    (FPadTouchIndex >= 0) and (FPadTouchIndex < FPadGames.Count) then
  begin
    FNavigation.PointerUsed;
    FSelected := FPadGames[FPadTouchIndex];
    UpdatePadView(False);
    UpdatePadHints;
  end;
  FPadTouchIndex := -1;
end;

procedure TLibraryView.LayoutPadSlots;
begin
  var Scrolling := FPadTouchScrolling;
  FPadTouchScrolling := True;
  try
    FPadScrollPosition := Max(0, FPadGames.IndexOf(FSelected));
    LayoutPadScroll;
  finally
    FPadTouchScrolling := Scrolling;
  end;
end;

procedure TLibraryView.FinishPadSelection;
begin
  if FPadTouchScrolling then
  begin
    if FPadKeyScrolling then
      FPadScrollPosition := FPadScrollTarget;
    EndPadScroll;
  end;
end;

procedure TLibraryView.PadTransitionTick(Sender: TObject);
begin
  if not FPadTouchScrolling or FPadTouchDown then
    Exit;
  var Now := TThread.GetTickCount64;
  var DT := Min(0.05, (Now - FPadScrollTick) / 1000.0);
  FPadScrollTick := Now;
  if DT <= 0 then
    Exit;
  if FPadKeyScrolling then
    DT := DT * 3.2;
  var Done := AdvanceLibraryScroll(FPadScrollPosition, FPadScrollVelocity, FPadScrollTarget,
    FPadScrollSnapping, DT, PadTouchStep, Max(0, FPadGames.Count - 1));
  SetPadScrollPosition(FPadScrollPosition);
  if Done then
    EndPadScroll;
end;

procedure TLibraryView.UpdatePadView(RebuildGames: Boolean);
begin
  if (FPadGames = nil) or (LayoutGamepadLibrary = nil) then
    Exit;
  if not FPadMode then
    Exit;
  if FLoadThread <> nil then
  begin
    LabelPadTitle.Text := Translate('Loading...');
    LabelPadInfo.Text := '';
    LabelPadDescription.Text := '';
    LabelPadCount.Text := '';
    for var i := 0 to High(FPadSlots) do
      FPadSlots[i].Visible := False;
    ButtonPadPlay.Enabled := False;
    Exit;
  end;
  if FPadStartPending then
  begin
    SelectPadStartPage;
    RebuildGames := True;
  end;
  if RebuildGames then
  begin
    FPadScrollFirst := -1;
    FPadAppearanceIndex := -1;
    FPadGames.Clear;
    for var Game in FGames do
      if Matches(Game) then
        FPadGames.Add(Game);
    if FMode = 1 then
      FPadGames.Sort(TComparer<TLibraryGame>.Construct(
        function(const A, B: TLibraryGame): Integer
        begin
          Result := CompareValue(B.LastPlayed, A.LastPlayed);
        end));
  end;
  var Index := FPadGames.IndexOf(FSelected);
  if Index < 0 then
  begin
    FSelected := nil;
    Index := 0;
    if FPadGames.Count > 0 then
      FSelected := FPadGames[0];
  end;
  (FindComponent('LabelPadBrand') as TLabel).Text := 'RetroMul';
  (FindComponent('ButtonGamepadView') as TButton).Hint := Translate('Gamepad');
  (FindComponent('ButtonPadDesktop') as TButton).Text := 'B  ' + Translate('Back');
  (FindComponent('ButtonPadSettings') as TButton).Text := Translate('Settings');
  (FindComponent('ButtonPadFavorite') as TButton).Text := 'X  ' + Translate('Favorites');
  case FMode of
    1:
      ButtonPadFilter.Text := 'Y  ' + Translate('Recent');
    2:
      ButtonPadFilter.Text := 'Y  ' + Translate('Favorites');
  else
    ButtonPadFilter.Text := 'Y  ' + Translate('All');
  end;
  ButtonPadPlay.Text := 'A  ' + Translate('Play');
  ButtonPadPlay.Enabled := FSelected <> nil;
  (FindComponent('RectanglePadPlayBackground') as TRectangle).Opacity := IfThen(ButtonPadPlay.Enabled, 1, 0.45);
  LabelPadCount.Text := Format('%d / %d', [Min(Index + 1, FPadGames.Count), FPadGames.Count]);
  LabelPadTitle.Text := Translate('No games found');
  LabelPadInfo.Text := '';
  (FindComponent('LabelPadGenre') as TLabel).Text := '';
  (FindComponent('LabelPadDeveloper') as TLabel).Text := '';
  (FindComponent('LabelPadPlayers') as TLabel).Text := '';
  LabelPadDescription.Text := Translate('Open settings and choose a ROM folder.');
  if FGames.Count > 0 then
    LabelPadDescription.Text := Translate('Change your search or filter.');
  (FindComponent('LayoutPadMetaColumns') as TLayout).Visible := False;
  if FSelected <> nil then
  begin
    LabelPadTitle.Text := FSelected.Title;
    LabelPadInfo.Text := LibrarySystemFullName(FSelected.SystemId);
    (FindComponent('LabelPadGenre') as TLabel).Text := FSelected.Genre;
    (FindComponent('LabelPadDeveloper') as TLabel).Text := FSelected.Developer;
    (FindComponent('LabelPadPlayers') as TLabel).Text := FSelected.Players;
    LabelPadDescription.Text := FSelected.Description.Replace(#13, ' ').Replace(#10, ' ');
  end;
  if not FPadTouchScrolling then
    FPadScrollPosition := Index;
  var Subtitle := LibrarySystemFullName(FSystemFilter);
  if FSelected <> nil then
  begin
    Subtitle := LibrarySystemFullName(FSelected.SystemId);
    if FSelected.Genre <> '' then
      Subtitle := Subtitle + '  ·  ' + FSelected.Genre;
    if FSelected.LastPlayed > 0 then
      Subtitle := Subtitle + '  ·  ' + Translate('Last played: ') + LibraryDate(FSelected.LastPlayed);
  end;
  (FindComponent('LabelPadSubtitle') as TLabel).Text := Subtitle;
  UpdatePadBackdrop;
  if RebuildGames and (Index > 0) then
    LoadPadCover(ImagePadPrevious, FPadGames[Index - 1]);
  UpdatePadHints;
  if RebuildGames then
    ResizePadView
  else
  begin
    if not FPadTouchScrolling then
      LayoutPadSlots;
    RoundPadTextSizes(FindComponent('LayoutPadTitle') as TFmxObject);
    RoundPadTextSizes(FindComponent('LayoutPadInfo') as TFmxObject);
  end;
end;

procedure TLibraryView.ChangePadPlatform(Delta: Integer);
begin
  FinishPadSelection;
  var Tabs := TArray<string>.Create('', '@recent', '@favorites') + FConfiguredPlatforms.ToArray;
  var Index := 0;
  for var i := 0 to High(Tabs) do
    if Tabs[i] = ActivePadTab then
      Index := i;
  SelectPadTab(Tabs[(Index + Delta + Length(Tabs)) mod Length(Tabs)]);
end;

procedure TLibraryView.PadCommand(Command: Integer);
begin
  if FPadPageOpen then
  begin
    case Command of
      0, 10:
        MovePadPageFocus(-1);
      1, 11:
        MovePadPageFocus(1);
      2:
        if FPadPageFocus = 0 then
          PlayClick(Self)
        else if FPadPageFocus = 1 then
          PadPageAction(FindComponent('ButtonPadPageFavorite'))
        else if FPadPageFocus - 2 < FPadPageSaveCount then
          SaveClick(FPadPageSaves[FPadPageFocus - 2]);
      3:
        ClosePadGamePage;
      4, 5:
        PadPageAction(FindComponent('ButtonPadPageFavorite'));
      6, 7:
        begin
          var Scroll := FindComponent('VertScrollBoxPadPage') as TVertScrollBox;
          Scroll.ViewportPosition := PointF(0, Max(0, Scroll.ViewportPosition.Y + IfThen(Command = 6, -1, 1) * Scroll.Height * 0.6));
        end;
      8:
        PlayClick(Self);
      9:
        SettingsClick(Self);
    end;
    Exit;
  end;
  if FPadMode and (Command in [0, 1]) and FPadKeyScrolling then
    CancelPadPlatformTouch
  else
  begin
    CancelPadTouch;
    FinishPadSelection;
  end;
  if not FPadMode then
    Exit;
  if Command = 3 then
  begin
    TogglePadView(nil);
    Exit;
  end;
  if FLoadThread <> nil then
    Exit;
  case Command of
    0, 1:
      if FPadGames.Count > 0 then
      begin
        var Index := Max(0, FPadGames.IndexOf(FSelected));
        Index := EnsureRange(Index + IfThen(Command = 0, -1, 1), 0, FPadGames.Count - 1);
        if FSelected <> FPadGames[Index] then
        begin
          FSelected := FPadGames[Index];
          AnimatePadSelection(IfThen(Command = 0, -1, 1));
        end;
      end;
    2:
      PlayClick(Self);
    4:
      OpenPadGamePage;
    5:
      begin
        FMode := (FMode + 1) mod 3;
        FLetterFilter := '';
        UpdatePadView;
      end;
    6:
      ChangePadPlatform(-1);
    7:
      ChangePadPlatform(1);
    8:
      PlayClick(Self);
    9:
      SettingsClick(Self);
    16:
      ChangePadPlatform(-2);
    17:
      ChangePadPlatform(2);
  end;
end;

procedure TLibraryView.PadAction(Sender: TObject);
begin
  FinishPadSelection;
  FNavigation.PointerUsed;
  if Sender is TRectangle then
  begin
    var Index := TRectangle(Sender).Tag;
    if (Index >= 0) and (Index < FPadGames.Count) then
    begin
      FSelected := FPadGames[Index];
      UpdatePadView(False);
    end;
  end
  else
    PadCommand(TControl(Sender).Tag);
  UpdatePadHints;
end;

function TLibraryView.LibraryKey(Key: Word; PhysicalKeyboard: Boolean): Boolean;
begin
  if PhysicalKeyboard then
    FNavigation.KeyboardUsed
  else
    FNavigation.PointerUsed;
  UpdatePadHints;
  Result := True;
  if not FPadMode then
    Result := False
  else
    case Key of
      vkUp:
        PadCommand(10);
      vkDown:
        PadCommand(11);
      vkLeft:
        PadCommand(0);
      vkRight:
        PadCommand(1);
      vkReturn:
        PadCommand(2);
      vkEscape:
        PadCommand(3);
      vkX:
        PadCommand(4);
      vkY:
        PadCommand(5);
      vkPrior:
        PadCommand(6);
      vkNext:
        PadCommand(7);
      vkSpace:
        PadCommand(8);
    else
      Result := False;
    end;
end;

procedure TLibraryView.AnimatePadSelection(Direction: Integer);
begin
  var WasScrolling := FPadTouchScrolling;
  FPadKeyScrolling := True;
  FPadScrollTarget := Max(0, FPadGames.IndexOf(FSelected));
  if not WasScrolling then
  begin
    FPadScrollPosition := EnsureRange(FPadScrollTarget - Direction, 0, Max(0, FPadGames.Count - 1));
    FPadScrollVelocity := 0;
  end
  else if FPadScrollVelocity * (FPadScrollTarget - FPadScrollPosition) < 0 then
    FPadScrollVelocity := 0;
  FPadTouchScrolling := True;
  FPadTouchDown := False;
  FPadScrollSnapping := True;
  // Retargeting must not discard elapsed animation time between timer ticks.
  if not WasScrolling then
    FPadScrollTick := TThread.GetTickCount64;
  UpdatePadView(False);
  LayoutPadScroll;
  TimerPadTransition.Enabled := True;
end;

function TLibraryView.ActivePadTab: string;
begin
  Result := FSystemFilter;
  if FMode = 1 then
    Result := '@recent';
  if FMode = 2 then
    Result := '@favorites';
end;

procedure TLibraryView.SelectPadTab(const Id: string);
begin
  FPadStartPending := False;
  FMode := 0;
  FSystemFilter := Id;
  if Id.StartsWith('@') then
  begin
    FSystemFilter := '';
    if Id = '@recent' then
      FMode := 1;
    if Id = '@favorites' then
      FMode := 2;
  end;
  FLetterFilter := '';
  UpdatePadView;
end;

type
  TLibraryControlAccess = class(TControl);

procedure SoftenLibraryBackdrop(Bitmap: FMX.Graphics.TBitmap);
const
  Radius = 2;
  Kernel = Radius * 2 + 1;
var
  Data: TBitmapData;
  Pixels, Scratch: TArray<TAlphaColor>;
  R, G, B, A: Integer;

  procedure Add(Color: TAlphaColor; Sign: Integer);
  begin
    Inc(R, Integer((Color shr 16) and $FF) * Sign);
    Inc(G, Integer((Color shr 8) and $FF) * Sign);
    Inc(B, Integer(Color and $FF) * Sign);
    Inc(A, Integer(Color shr 24) * Sign);
  end;

  function Average: TAlphaColor;
  begin
    Result := (Cardinal((A + Kernel div 2) div Kernel) shl 24) or
      (Cardinal((R + Kernel div 2) div Kernel) shl 16) or
      (Cardinal((G + Kernel div 2) div Kernel) shl 8) or
      Cardinal((B + Kernel div 2) div Kernel);
  end;

begin
  // Blur only the reduced background staging bitmap, once per load.
  // Three small box passes approximate a Gaussian without a live GPU effect.
  if Bitmap.IsEmpty or not Bitmap.Map(TMapAccess.ReadWrite, Data) then
    Exit;
  try
    var W := Bitmap.Width;
    var H := Bitmap.Height;
    SetLength(Pixels, W * H);
    SetLength(Scratch, W * H);
    for var Y := 0 to H - 1 do
      for var X := 0 to W - 1 do
        Pixels[Y * W + X] := Data.GetPixel(X, Y);
    for var Pass := 1 to 3 do
    begin
      for var Y := 0 to H - 1 do
      begin
        R := 0;
        G := 0;
        B := 0;
        A := 0;
        for var K := -Radius to Radius do
          Add(Pixels[Y * W + EnsureRange(K, 0, W - 1)], 1);
        for var X := 0 to W - 1 do
        begin
          Scratch[Y * W + X] := Average;
          Add(Pixels[Y * W + Max(0, X - Radius)], -1);
          Add(Pixels[Y * W + Min(W - 1, X + Radius + 1)], 1);
        end;
      end;
      for var X := 0 to W - 1 do
      begin
        R := 0;
        G := 0;
        B := 0;
        A := 0;
        for var K := -Radius to Radius do
          Add(Scratch[EnsureRange(K, 0, H - 1) * W + X], 1);
        for var Y := 0 to H - 1 do
        begin
          Pixels[Y * W + X] := Average;
          Add(Scratch[Max(0, Y - Radius) * W + X], -1);
          Add(Scratch[Min(H - 1, Y + Radius + 1) * W + X], 1);
        end;
      end;
    end;
    for var Y := 0 to H - 1 do
      for var X := 0 to W - 1 do
        Data.SetPixel(X, Y, Pixels[Y * W + X]);
  finally
    Bitmap.Unmap(Data);
  end;
end;

procedure TLibraryView.PadTextResize(Sender: TObject);
begin
  if FClosing or FPadTextRounding or not (Sender is TText) then
    Exit;
  var Text := TText(Sender);
  if csDestroying in Text.ComponentState then
    Exit;
  // Integral cache surfaces stay inside the aligned parent. Fractional
  // positions are retained so dragging and carousel animation stay smooth.
  var W := Max(0, Floor(Text.Width + 0.001));
  var H := Max(0, Floor(Text.Height + 0.001));
  if SameValue(Text.Width, W, 0.001) and SameValue(Text.Height, H, 0.001) then
    Exit;
  FPadTextRounding := True;
  var Parent: TLibraryControlAccess := nil;
  var WasAligning := False;
  if Text.Parent is TControl then
  begin
    Parent := TLibraryControlAccess(Text.Parent);
    WasAligning := Parent.FDisableAlign;
    // SetBounds requests parent alignment before raising OnResize. Suppress
    // that nested request, otherwise Client alignment restores the fraction.
    Parent.FDisableAlign := True;
  end;
  try
    Text.SetBounds(Text.Position.X, Text.Position.Y, W, H);
  finally
    if Parent <> nil then
      Parent.FDisableAlign := WasAligning;
    FPadTextRounding := False;
  end;
end;

procedure TLibraryView.RoundPadTextSizes(Node: TFmxObject);
begin
  if FClosing then
    Exit;
  if (Node is TControl) and not TControl(Node).Visible then
    Exit;
  if Node is TStyledControl then
    TStyledControl(Node).ApplyStyleLookup;
  if Node is TText then
  begin
    var Text := TText(Node);
    // Do not replace existing custom handlers in designer/user styles.
    if not Assigned(Text.OnResize) then
      Text.OnResize := PadTextResize;
    PadTextResize(Text);
  end;
  for var i := 0 to Node.ChildrenCount - 1 do
    RoundPadTextSizes(Node.Children[i]);
end;

procedure TLibraryView.PadBackdropReady(const Location: string; Success: Boolean);
begin
  if FClosing or not FPadMode or FPadBackdropPending or
    (FPadBackdropRequested <> Location) or (ImagePadBackdropNext.TagString <> Location) then
    Exit;
  if not Success then
  begin
    ImagePadBackdrop.Visible := False;
    Exit;
  end;
  SoftenLibraryBackdrop(ImagePadBackdropNext.Bitmap);
  LayoutPadBackdrop;
  ImagePadBackdropNext.Opacity := 0;
  ImagePadBackdropNext.Visible := True;
  FPadBackdropStarted := TThread.GetTickCount64;
  FPadBackdropFading := True;
  TimerPadBackdrop.Enabled := True;
end;

procedure TLibraryView.LayoutPadBackdrop;
begin
  var Backdrop := FindComponent('LayoutPadBackdrop') as TLayout;
  for var Image in [ImagePadBackdrop, ImagePadBackdropNext] do
    if (Image <> nil) and not Image.Bitmap.IsEmpty then
    begin
      var Scale := Max(Backdrop.Width / Image.Bitmap.Width, Backdrop.Height / Image.Bitmap.Height);
      var X := (Backdrop.Width - Image.Bitmap.Width * Scale) * 0.5;
      var Y := (Backdrop.Height - Image.Bitmap.Height * Scale) * 0.5;
      Image.Margins.Rect := RectF(X, Y, X, Y);
    end;
end;

procedure TLibraryView.UpdatePadBackdrop;
begin
  var Location := '';
  var Fallback := '';
  if FSelected <> nil then
  begin
    Location := FSelected.GamepadCover;
    Fallback := FSelected.Cover;
  end;
  if FPadBackdropRequested = Location then
    Exit;
  FPadBackdropRequested := Location;
  FPadBackdropFallback := Fallback;
  FPadBackdropDue := TThread.GetTickCount64 + 240;
  FPadBackdropPending := True;
  // Keep the displayed backdrop/crossfade, but cancel stale decoding. During
  // rapid scrolling only the last settled game should be read and blurred.
  ImagePadBackdropNext.Bitmap.RemoveCallback(ImagePadBackdropNext);
  TimerPadBackdrop.Enabled := True;
end;

procedure TLibraryView.LoadPadBackdrop;
begin
  var Location: string := FPadBackdropRequested;
  var Fallback: string := FPadBackdropFallback;
  FPadBackdropPending := False;
  ImagePadBackdropNext.TagString := Location;
  ImagePadBackdropNext.Visible := False;
  ImagePadBackdropNext.Bitmap := nil;
  if Location = '' then
  begin
    ImagePadBackdrop.Visible := False;
    Exit;
  end;
  ImagePadBackdropNext.Bitmap.LoadFromFileAsync(ImagePadBackdropNext, Location, 640, 450,
    procedure(Success: Boolean)
    begin
      if FClosing or (ImagePadBackdropNext.TagString <> Location) then
        Exit;
      if not Success and (Fallback <> '') and (Fallback <> Location) then
        ImagePadBackdropNext.Bitmap.LoadFromFileAsync(ImagePadBackdropNext, Fallback, 640, 450,
          procedure(FallbackSuccess: Boolean)
          begin
            PadBackdropReady(Location, FallbackSuccess);
          end, FStorage)
      else
        PadBackdropReady(Location, Success);
    end, FStorage);
end;

procedure TLibraryView.PadBackdropTick(Sender: TObject);
begin
  if FClosing or not FPadMode then
  begin
    TimerPadBackdrop.Enabled := False;
    Exit;
  end;
  var Tick := TThread.GetTickCount64;
  if FPadBackdropFading then
  begin
    var T := Min(1.0, (Tick - FPadBackdropStarted) / 180.0);
    ImagePadBackdropNext.Opacity := T * T * (3 - 2 * T);
    if T >= 1 then
    begin
      FPadBackdropFading := False;
      ImagePadBackdrop.Bitmap.Assign(ImagePadBackdropNext.Bitmap);
      ImagePadBackdrop.Visible := True;
      ImagePadBackdropNext.Visible := False;
      LayoutPadBackdrop;
    end;
  end;
  if FPadBackdropPending and not FPadBackdropFading and (Tick >= FPadBackdropDue) and
    not FPadTouchScrolling and not FPadTouchDown then
    LoadPadBackdrop;
  TimerPadBackdrop.Enabled := FPadBackdropPending or FPadBackdropFading;
end;

procedure TLibraryView.OpenPadGamePage;
begin
  if FSelected = nil then
    Exit;
  CancelPadTouch;
  FinishPadSelection;
  FPadPageOpen := True;
  FPadPageFocus := 0;
  (FindComponent('LayoutPadGamePage') as TLayout).Visible := True;
  (FindComponent('VertScrollBoxPadPage') as TVertScrollBox).ViewportPosition := TPointF.Zero;
  UpdatePadGamePage;
  UpdatePadHints;
  ResizePadView;
end;

procedure TLibraryView.ClosePadGamePage;
begin
  FPadPageOpen := False;
  (FindComponent('LayoutPadGamePage') as TLayout).Visible := False;
  (FindComponent('LayoutPadShelf') as TLayout).Visible := True;
  UpdatePadView;
end;

procedure TLibraryView.UpdatePadGamePage;
begin
  if not FPadPageOpen or (FSelected = nil) then
    Exit;
  (FindComponent('LabelPadPageTitle') as TLabel).Text := FSelected.Title;
  var Metadata := LibrarySystemFullName(FSelected.SystemId);
  if FSelected.Genre <> '' then
    Metadata := Metadata + '  ·  ' + FSelected.Genre;
  if FSelected.Developer <> '' then
    Metadata := Metadata + '  ·  ' + FSelected.Developer;
  if FSelected.Players <> '' then
    Metadata := Metadata + '  ·  ' + Translate('Players: ') + FSelected.Players;
  (FindComponent('LabelPadPageMetadata') as TLabel).Text := Metadata;
  var Description := FindComponent('LabelPadPageDescription') as TLabel;
  Description.Text := FSelected.Description;
  if Description.Text = '' then
    Description.Text := FSelected.Genre;
  LoadPadCover(FindComponent('ImagePadPageCover') as TImage, FSelected);
  (FindComponent('ButtonPadPagePlay') as TButton).Text := Translate('Play');
  var Favorite := FindComponent('ButtonPadPageFavorite') as TButton;
  Favorite.Text := Translate('Add to favorites');
  if FSelected.Favorite then
    Favorite.Text := Translate('Remove from favorites');
  (FindComponent('LabelPadPageSaves') as TLabel).Text := Translate('Save states');
  var Saves := Snapshots(FSelected);
  FPadPageSaveCount := Length(Saves);
  var OldCount := Length(FPadPageSaves);
  if OldCount < Length(Saves) then
  begin
    SetLength(FPadPageSaves, Length(Saves));
    for var i := OldCount to High(Saves) do
    begin
      var Button := TButton.Create(Self);
      Button.Name := 'ButtonPadPageSave' + IntToStr(i);
      Button.Parent := FindComponent('LayoutPadPageSaveList') as TLayout;
      Button.Align := TAlignLayout.Top;
      Button.Height := 56;
      Button.Margins.Bottom := 8;
      Button.StyledSettings := [];
      Button.TextSettings.Font.Size := 13;
      Button.TextSettings.WordWrap := True;
      Button.OnClick := SaveClick;
      FPadPageSaves[i] := Button;
    end;
  end;
  for var i := 0 to High(FPadPageSaves) do
  begin
    var Button := FPadPageSaves[i];
    Button.Visible := i < Length(Saves);
    Button.Enabled := Button.Visible;
    Button.Position.Y := i * 64;
    Button.TagString := '';
    if Button.Visible then
    begin
      Button.Text := Saves[i].Name + '  ·  ' + FormatDateTime('dd.mm.yyyy hh:nn', Saves[i].Modified);
      Button.TagString := Saves[i].Location;
    end;
  end;
  (FindComponent('LabelPadPageSavesEmpty') as TLabel).Text := Translate('No save states yet.');
  (FindComponent('LabelPadPageSavesEmpty') as TLabel).Visible := Length(Saves) = 0;
  (FindComponent('LayoutPadPageSaveList') as TLayout).Height := Length(Saves) * 64;
  FPadPageFocus := Min(FPadPageFocus, FPadPageSaveCount + 1);
  MovePadPageFocus(0);
  ResizePadGamePage;
  for var Button in FPadPageSaves do
    if Button.Visible then
      Button.RecalcSize;
end;

procedure TLibraryView.ResizePadGamePage;
begin
  var Page := FindComponent('LayoutPadGamePage') as TLayout;
  Page.Padding.Rect := RectF(IfThen(Width < 700, 12, 18), 12, IfThen(Width < 700, 12, 18), 12);
  var Left := FindComponent('LayoutPadPageActions') as TLayout;
  Left.Width := IfThen(Width < 700, 140, IfThen(Width < 1100, 200, 260));
  Left.Margins.Right := IfThen(Width < 700, 16, 32);
  var Image := FindComponent('RectanglePadPageArt') as TRectangle;
  Image.Visible := Left.Height >= 180;
  Image.Height := Max(0, Min(Left.Width * 1.36, Left.Height - 112));
  (FindComponent('LabelPadPageTitle') as TLabel).TextSettings.Font.Size := IfThen(Width < 700, 21, 28);
  for var N in ['ButtonPadPagePlay', 'ButtonPadPageFavorite'] do
  begin
    var B := FindComponent(N) as TButton;
    B.TextSettings.Font.Size := IfThen(Width < 700, 11.2, 13.6);
    B.TextSettings.WordWrap := True;
    B.TextSettings.Trimming := TTextTrimming.Character;
  end;
  var Scroll := FindComponent('VertScrollBoxPadPage') as TVertScrollBox;
  var Content := FindComponent('LayoutPadPageContent') as TLayout;
  var Description := FindComponent('LabelPadPageDescription') as TLabel;
  Description.Width := Max(1, Scroll.Width - 8);
  Description.AutoSize := False;
  Description.AutoSize := True;
  Content.Height := 28 + Description.Height + 24 + 32 + IfThen(FPadPageSaveCount = 0, 28, 0) + FPadPageSaveCount * 64;
  Scroll.RealignContent;
  RoundPadTextSizes(FindComponent('LayoutPadGamePage') as TFmxObject);
end;

procedure TLibraryView.MovePadPageFocus(Delta: Integer);
begin
  FPadPageFocus := EnsureRange(FPadPageFocus + Delta, 0, FPadPageSaveCount + 1);
  var Controls: TArray<TButton> := [
    FindComponent('ButtonPadPagePlay') as TButton,
    FindComponent('ButtonPadPageFavorite') as TButton] + FPadPageSaves;
  for var i := 0 to High(Controls) do
  begin
    if i = FPadPageFocus then
    begin
      Controls[i].StyleLookup := 'buttonstyle_accent';
      Controls[i].TextSettings.FontColor := $FF181C21;
    end
    else
    begin
      Controls[i].StyleLookup := 'buttonstyle_subtle';
      Controls[i].TextSettings.FontColor := $FFE8ECF1;
    end;
    Controls[i].ApplyStyleLookup;
    RoundPadTextSizes(Controls[i]);
  end;
  if (Delta <> 0) and (FPadPageFocus >= 2) then
  begin
    var Scroll := FindComponent('VertScrollBoxPadPage') as TVertScrollBox;
    var Y := FPadPageSaves[FPadPageFocus - 2].AbsoluteRect.Top - TLayout(FindComponent('LayoutPadPageContent')).AbsoluteRect.Top;
    Scroll.ViewportPosition := PointF(0, Max(0, Y - Scroll.Height * 0.5));
  end;
end;

procedure TLibraryView.PadPageAction(Sender: TObject);
begin
  if (FSelected = nil) or not FPadPageOpen then
    Exit;
  if TButton(Sender).Tag = 0 then
    PlayClick(Self)
  else
  begin
    // Keep the open game page stable when removing it from the Favorites tab.
    FSelected.Favorite := not FSelected.Favorite;
    FState.WriteBool('Favorites', FSelected.Key, FSelected.Favorite);
    SaveState;
    UpdatePadGamePage;
    UpdatePadHints;
  end;
end;

procedure TLibraryView.UpdatePadHints;

  procedure Hint(const Name, Caption: string; Command: Integer);
  begin
    var Button := FindComponent(Name) as TButton;
    Button.Text := '';
    var Title := FindComponent('TextCaption' + Name);
    if Title <> nil then
      (Title as TText).Text := Caption;
    var Text := FindComponent('TextKey' + Name) as TText;
    var Circle := FindComponent('CircleKey' + Name) as TCircle;
    var Path := FindComponent('PathKey' + Name) as FMX.Objects.TPath;
    var Key := FNavigation.Hint(Command);
    Path.Width := 18;
    Path.Height := 18;
    Text.TextSettings.Font.Size := (IfThen(Length(Key) > 3, 9, 11)) * 0.8;
    Text.Text := Key;
    (FindComponent('LayoutKey' + Name) as TLayout).Visible := True;
    Text.Visible := True;
    Path.Visible := False;
    Circle.Visible := True;
    Circle.Fill.Kind := TBrushKind.Solid;
    Circle.Fill.Color := $FF2B323A;
    Circle.Stroke.Kind := TBrushKind.Solid;
    Circle.Stroke.Color := $FFB9C2CC;
    Text.TextSettings.FontColor := $FFE8ECF1;
    Path.Stroke.Color := $FFE8ECF1;
    if (FNavigation.Device.Kind = TInputDeviceKind.Controller) and (Command in [2, 3, 4, 5]) then
    begin
      Circle.Stroke.Kind := TBrushKind.None;
      case Command of
        2:
          Circle.Fill.Color := $FF68A74C;
        3:
          Circle.Fill.Color := $FFD85C5C;
        4:
          Circle.Fill.Color := $FF687BE0;
        5:
          begin
            Circle.Fill.Color := $FFD7BD45;
            Text.TextSettings.FontColor := $FF181C21;
          end;
      end;
    end;
    if Key = 'Enter' then
      Text.Text := #$21B5;
    if Key = 'Space' then
      Text.Text := #$2423;
    if Key = 'PgUp' then
      Text.Text := 'Pg' + #$2191;
    if Key = 'PgDn' then
      Text.Text := 'Pg' + #$2193;
    if Key = '' then
      Text.Text := #$2630;
    if Button.StyleLookup = 'buttonstyle_accent' then
    begin
      (FindComponent('TextCaption' + Name) as TText).TextSettings.FontColor := $FF181C21;
      Circle.Fill.Color := $FF181C21;
      Circle.Stroke.Kind := TBrushKind.None;
    end;
    if Key = 'Enter' then
      Path.Data.Data := 'M17,2 L17,11 L3,11 M7,6 L2,11 L7,16'
    else if Key = 'Space' then
      Path.Data.Data := 'M3,6 L3,14 L17,14 L17,6'
    else if Key = 'Cross' then
      Path.Data.Data := 'M2,2 L18,18 M18,2 L2,18'
    else if Key = 'Square' then
      Path.Data.Data := 'M2,2 L18,2 L18,18 L2,18 Z'
    else if Key = 'Triangle' then
      Path.Data.Data := 'M10,1 L19,18 L1,18 Z'
    else if Key = 'Circle' then
      Path.Data.Data := 'M10,1 C22,1 22,19 10,19 C-2,19 -2,1 10,1 Z'
    else if Command = 0 then
      Path.Data.Data := 'M15,2 L5,10 L15,18'
    else if Command = 1 then
      Path.Data.Data := 'M5,2 L15,10 L5,18';
    if (Key = 'Cross') or (Key = 'Circle') or (Key = 'Square') or
      (Key = 'Triangle') or (Key = 'Enter') or (Key = 'Space') or (Command in [0, 1]) then
    begin
      Path.Visible := True;
      Text.Visible := False;
      Circle.Visible := True;
    end;
    if (FNavigation.Device.Kind = TInputDeviceKind.Controller) and (Command in [8, 9]) then
    begin
      Path.Width := 14;
      Path.Height := 14;
      if Command = 8 then
        Path.Data.Data := 'M3,5 L17,5 M3,10 L17,10 M3,15 L17,15'
      else
        Path.Data.Data := 'M1,1 L13,1 L13,13 L1,13 Z M7,7 L19,7 L19,19 L7,19 Z';
      Path.Visible := True;
      Circle.Visible := True;
      Text.Visible := False;
    end;
  end;

begin
  {$IFDEF ISMOBILE}
  (FindComponent('LayoutPadBackSection') as TLayout).Visible := FPadPageOpen;
  {$ENDIF}
  Hint('ButtonPadPreviousPlatform', '', 6);
  Hint('ButtonPadNextPlatform', '', 7);
  Hint('ButtonPadDesktop', Translate('Back'), 3);
  var FavoriteCaption := Translate('Add to favorites');
  if (FSelected <> nil) and FSelected.Favorite then
    FavoriteCaption := Translate('Remove from favorites');
  if not FPadPageOpen then
    FavoriteCaption := Translate('Options');
  Hint('ButtonPadFavorite', FavoriteCaption, 4);
  (FindComponent('ButtonPadFavorite') as TButton).Enabled := FSelected <> nil;
  (FindComponent('ButtonPadFavorite') as TButton).Hint := FavoriteCaption;
  Hint('ButtonPadSettings', Translate('Settings'), 9);
  (FindComponent('TextPadNavigationHint') as TText).Text := Translate('Selection');
  var Filter := Translate('All');
  if FMode = 1 then
    Filter := Translate('Recent');
  if FMode = 2 then
    Filter := Translate('Favorites');
  Hint('ButtonPadFilter', Filter, 5);
  if FPadPageOpen then
    Hint('ButtonPadPlay', Translate('Selection'), 2)
  else
    Hint('ButtonPadPlay', Translate('Play'), 2);
  ButtonPadPlay.TextSettings.FontColor := $FFE8ECF1;
  ButtonPadPlatform.TextSettings.FontColor := $FF181C21;
  (FindComponent('LabelPadCaptionGenre') as TLabel).Text := Translate('Genre: ').Trim;
  (FindComponent('LabelPadCaptionPlayers') as TLabel).Text := Translate('Players: ').Trim;
  (FindComponent('TextPadClock') as TText).Text := FormatDateTime('hh:nn', Now);
end;

procedure TLibraryView.PollLibraryInput(Input: TInputManager; Active: Boolean);
begin
  if not Active or (Input = nil) then
  begin
    if not Active then
      CancelPadTouch;
    FNavigation.Reset;
    Exit;
  end;
  var Command := FNavigation.Poll(Input.Devices, Input.Values, TThread.GetTickCount64);
  if FPadHintDevice <> FNavigation.Device.Id then
  begin
    FPadHintDevice := FNavigation.Device.Id;
    if FPadPageOpen then
    begin
      UpdatePadHints;
      UpdatePadGamePage;
    end
    else
      UpdatePadView;
  end;
  if Command >= 0 then
    PadCommand(Command);
end;

end.

