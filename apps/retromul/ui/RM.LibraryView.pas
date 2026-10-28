unit RM.LibraryView;

{$I ..\RM.Mobile.inc}

interface

uses
  System.SysUtils, System.Classes, System.Types, System.UITypes,
  System.Generics.Collections, System.IniFiles, FMX.Types, FMX.Controls,
  FMX.Forms, FMX.Layouts, FMX.StdCtrls, FMX.Edit, FMX.Objects, Core.Storage,
  FMX.Controls.Presentation, FMX.ListBox;

type
  TLibraryGame = class
  public
    FileInfo: TStorageFile;
    SystemId, Title, Cover, Description, Developer, Genre, Players: string;
    Favorite: Boolean;
    InLibrary: Boolean;
    LastPlayed: TDateTime;
    function Key: string;
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
    FOnPlay, FOnSettings, FOnOpen: TNotifyEvent;
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
    procedure Reload;
    procedure ApplyPreferences;
    procedure ApplyLanguage(const PreviousLanguage: string);
    procedure RecordSession(const FileName, SnapshotDirectory: string; const SystemId: string = ''; const DisplayName: string = '');
    procedure RefreshSnapshots;
    function CloseDetails: Boolean;
    property Selected: TLibraryGame read GetSelected;
    property SnapshotName: string read FSnapshotName;
    property OnPlay: TNotifyEvent read FOnPlay write FOnPlay;
    property OnSettings: TNotifyEvent read FOnSettings write FOnSettings;
    property OnOpen: TNotifyEvent read FOnOpen write FOnOpen;
  end;

function LibrarySystemFullName(const Id: string): string;

function LibrarySystemName(const Id: string): string;

implementation

{$R *.fmx}

uses
  System.IOUtils, System.Math, System.Math.Vectors, System.Hash,
  System.Character, System.Generics.Defaults, FMX.Graphics, FMX.BehaviorManager,
  Core.GameList, FMX.Image, Core.Platforms, Core.SavePaths, RM.Icons,
  RM.SearchEdit, RM.Styles;

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
  FBuilding := False;
  ApplyPreferences;
  Reload;
end;

destructor TLibraryView.Destroy;
begin
  FClosing := True;
  FBuilding := True;
  if FLoadThread <> nil then
  begin
    FLoadThread.Terminate;
    FLoadThread.WaitFor;
    TThread.RemoveQueuedEvents(FLoadThread);
    FreeAndNil(FLoadThread);
  end;
  FCards.Free;
  FLetterButtons.Free;
  FConfiguredPlatforms.Free;
  FPlatformButtons.Free;
  FSidebarPlatformBorders.Free;
  FGames.Free;
  FState.Free;
  inherited;
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

  function MetadataPath(const Folder, Relative: string): string;
  begin
    Result := '';
    if Relative = '' then
      Exit;
    if not Folder.StartsWith('content://', True) then
      Exit(TPath.Combine(Folder, Relative));
    // SAF identifiers are opaque: resolve metadata by display names.
    Result := Folder;
    var Parts := Relative.Replace('\', '/').Split(['/']);
    for var I := 0 to High(Parts) do
    begin
      if (Parts[I] = '') or (Parts[I] = '.') then
        Continue;
      var Candidates: TArray<string>;
      if I = High(Parts) then
        Candidates := FStorage.Files(Result)
      else
        Candidates := FStorage.Folders(Result);
      var Found := '';
      for var Candidate in Candidates do
        if SameText(FStorage.Describe(Candidate).Name, Parts[I]) then
        begin
          Found := Candidate;
          Break;
        end;
      if Found = '' then
        Exit('');
      Result := Found;
    end;
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
      // Optional metadata enriches files found in the configured platform folder.
      var Metadata := TObjectList<TGameList>.Create(True);
      var Lookup := TDictionary<string, TGame>.Create;
      try
        var Folder := FStorage.RomFolder(platform.Id);
        if Folder <> '' then
          for var XMLLocation in FStorage.Files(Folder) do
          begin
            if not SameText(FStorage.Describe(XMLLocation).Name, 'gamelist.xml') then
              Continue;
            var XML := XMLLocation;
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
              Game.Image := MetadataPath(Folder, Game.Image);
              Game.Box := MetadataPath(Folder, Game.Box);
              var Key := MetadataKey(MetadataPath(Folder, Game.Path));
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
          var Key := MetadataKey(FileInfo.Location);
          if Lookup.TryGetValue(Key, Entry) then
          begin
            if Entry.Name <> '' then
              Item.Title := Entry.Name;
            Item.Cover := Entry.Image;
            if Item.Cover.IsEmpty then
              Item.Cover := Entry.Box;
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
        Lookup.Free;
        Metadata.Free;
      end;
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
  if FLoadThread <> nil then
  begin
    FReloadPending := True;
    Exit;
  end;
  FInspectorOpen := False;
  FLoadThread := TLibraryLoader.Create(FStorage, FState, FinishReload);
  SetLoading(True);
  FLoadThread.Start;
end;

procedure TLibraryView.FinishReload;
begin
  if FClosing then
    Exit;
  FLoadThread.WaitFor;
  var Error := FLoadThread.FError;
  if (Error = '') and not FReloadPending then
  begin
    FSelected := nil;
    FRecent := nil;
    ClearCards;
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
  if Error <> '' then
  begin
    LabelEmpty.Text := Translate('Unable to load library') + sLineBreak + Error;
    LabelEmpty.Visible := True;
    LayoutLibraryEmptyState.Visible := True;
    ButtonConfigureLibrary.Visible := False;
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
  Resize;
end;

procedure TLibraryView.BuildCards(AppendOnly: Boolean);
begin
  if FBuilding or (FLoadThread <> nil) or (LayoutGrid = nil) then
    Exit;

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
  FLayouting := True;
  try
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
    for var I := 0 to High(FNavButtons) do
    begin
      FNavIcons[I].Visible := not CompactNav.Visible;
      if CompactNav.Visible then
      begin
        FNavButtons[I].Align := TAlignLayout.Left;
        FNavButtons[I].Width := Max(1, (CompactNav.Width - 8) / 3);
        FNavButtons[I].Margins.Rect := RectF(0, 0, 4, 0);
        FNavButtons[I].Position.X := I * 1000; // Left-alignment order.
        FNavButtons[I].TextSettings.HorzAlign := TTextAlign.Center;
        FNavButtons[I].StylesData['text.Margins.Left'] := 4;
      end
      else
      begin
        FNavButtons[I].Align := TAlignLayout.Top;
        FNavButtons[I].Height := 46;
        FNavButtons[I].Margins.Rect := RectF(0, 0, 0, 8);
        FNavButtons[I].Position.Y := I * 54;
        FNavButtons[I].TextSettings.HorzAlign := TTextAlign.Leading;
        FNavButtons[I].StylesData['text.Margins.Left'] := 48;
      end;
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
    if VertScrollBoxPlatforms.Content <> nil then
      for var I := 0 to VertScrollBoxPlatforms.Content.ChildrenCount - 1 do
        if VertScrollBoxPlatforms.Content.Children[I] is TLayout then
          TLayout(VertScrollBoxPlatforms.Content.Children[I]).Width := VertScrollBoxPlatforms.Width;
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
      {$IFDEF ISMOBILE}
      if LayoutBody.Height - LayoutHeader.Height - FContinueExtent < 274 then
        FContinueExtent := 0;
      FContinueCollapse := EnsureRange(VertScrollBoxScroll.ViewportPosition.Y, 0, FContinueExtent);
      FContinue.Opacity := IfThen(FContinueExtent > 0, 1 - FContinueCollapse / Max(1, FContinueExtent), 0);
      FContinue.Enabled := (FContinueExtent > 0) and (FContinueCollapse < CardHeight);
      {$ENDIF}
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
  var Latest: TDateTime := 0;
  var HasSnapshot := False;
  for var Game in FGames do
  begin
    var Saves := Snapshots(Game);
    if Length(Saves) > 0 then
    begin
      if not HasSnapshot or (Saves[0].Modified > Latest) or
        ((Saves[0].Modified = Latest) and (Game.LastPlayed > FRecent.LastPlayed)) then
      begin
        FRecent := Game;
        Latest := Saves[0].Modified;
      end;
      HasSnapshot := True;
    end
    else if not HasSnapshot and (Game.LastPlayed > 0) and
      ((FRecent = nil) or (Game.LastPlayed > FRecent.LastPlayed)) then
      FRecent := Game;
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

end.

