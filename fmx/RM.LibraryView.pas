unit RM.LibraryView;

interface

uses
  System.SysUtils, System.Classes, System.Types, System.UITypes,
  System.Generics.Collections, System.IniFiles, FMX.Types, FMX.Controls,
  FMX.Forms, FMX.Layouts, FMX.StdCtrls, FMX.Edit, FMX.Objects, Core.Storage,
  FMX.Controls.Presentation;

type
  TLibraryGame = class
  public
    FileInfo: TStorageFile;
    SystemId, Title, Cover, Description, Developer, Genre, Players: string;
    Favorite: Boolean;
    LastPlayed: TDateTime;
    function Key: string;
  end;

  TLibraryCard = class(TPanel)
    Cover: TImage;
    Title, platform: TLabel;
    Selection: TRectangle;
  end;

  TLibraryView = class(TFrame)
    FSidebar, FInspector: TPanel;
    FCompactActions: TLayout;
    FScroll: TVertScrollBox;
    FGrid: TLayout;
    FTitle, FCount, FDetails, FDescription, FGameInfo, FSavesEmpty, FEmpty, FContinueTitle: TLabel;
    FCover: TImage;
    FContinuePreview: TLayout;
    FContinueNoPreview: TLabel;
    FContinueCaption, FContinuePlatform, FContinueLastPlayed, FContinueSave: TLabel;
    Path1: TPath;
  private
    {$REGION 'Library data and selection'}
    FStorage: IStorage;
    FGames: TObjectList<TLibraryGame>;
    FState: TMemIniFile;
    FSelected, FRecent: TLibraryGame;
    FSystemFilter: string;
    FMode, FLimit: Integer;
    FSnapshotName: string;
    {$ENDREGION}
    {$REGION 'Runtime controls'}
    FBody, FHeader, FFilters, FContinue: TLayout;
    FSearch: TEdit;
    FPlay, FFavorite, FMore, FGridButton, FListButton, FResume: TButton;
    FSaveButtons: array[0..2] of TButton;
    FSaveImages: array[0..2] of TImage;
    FPlatformButtons: array[0..6] of TButton;
    FSidebarPlatformBorders: array[1..6] of TRectangle;
    FNavButtons: array[0..2] of TButton;
    FNavIcons: array[0..2] of TPath;
    FGridIcon, FListIcon: TPath;
    FContinueCover: TRectangle;
    FContinueGamePreview: TImage;
    FCards: TList<TLibraryCard>;
    {$ENDREGION}
    {$REGION 'Layout and view preferences'}
    FListMode, FBuilding, FArranging, FLayouting, FShowPlatform: Boolean;
    FCardWidth: Integer;
    FContinueCollapse, FContinueExtent: Single;
    {$ENDREGION}
    {$REGION 'View events'}
    FOnPlay, FOnSettings, FOnOpen: TNotifyEvent;
    {$ENDREGION}
    {$REGION 'Library data and preferences'}
    procedure SaveState;
    function Matches(Game: TLibraryGame): Boolean;
    function GetSelected: TLibraryGame;
    function Snapshots(Game: TLibraryGame): TArray<TStorageSnapshot>;
    procedure LoadImage(Image: TImage; const Location: string);
    {$ENDREGION}
    {$REGION 'Cards and layout'}
    procedure BuildCards;
    procedure ArrangeCards;
    procedure UpdateViewIcons;
    procedure GridResize(Sender: TObject);
    procedure BodyResize(Sender: TObject);
    {$IF Defined(ANDROID) or Defined(IOS)}
    procedure ScrollViewportChanged(Sender: TObject; const OldPosition, NewPosition: TPointF;
      const ContentSizeChanged: Boolean);
    {$ENDIF}
    {$ENDREGION}
    {$REGION 'Selected game and continue panel'}
    procedure UpdateInspector;
    procedure SelectContinueGame;
    procedure UpdateContinue;
    procedure LoadContinueGamePreview;
    procedure ArrangeContinuePreview;
    {$ENDREGION}
    {$REGION 'View events'}
    procedure OpenClick(Sender: TObject);
    procedure SettingsClick(Sender: TObject);
    procedure FilterClick(Sender: TObject);
    procedure ModeClick(Sender: TObject);
    procedure SearchChange(Sender: TObject);
    procedure CardClick(Sender: TObject);
    {$IF Defined(ANDROID) or Defined(IOS)}
    procedure CardTap(Sender: TObject; const Point: TPointF);
    {$ENDIF}
    procedure PlayClick(Sender: TObject);
    procedure ResumeClick(Sender: TObject);
    procedure SaveClick(Sender: TObject);
    procedure FavoriteClick(Sender: TObject);
    procedure ViewClick(Sender: TObject);
    procedure MoreClick(Sender: TObject);
    {$ENDREGION}
  protected
    procedure Resize; override;
  public
    constructor CreateLibrary(AOwner: TComponent; const Storage: IStorage);
    destructor Destroy; override;
    procedure Reload;
    procedure ApplyPreferences;
    procedure ApplyLanguage(const PreviousLanguage: string);
    procedure RecordSession(const FileName, SnapshotDirectory: string);
    procedure RefreshSnapshots;
    property Selected: TLibraryGame read GetSelected;
    property SnapshotName: string read FSnapshotName;
    property OnPlay: TNotifyEvent read FOnPlay write FOnPlay;
    property OnSettings: TNotifyEvent read FOnSettings write FOnSettings;
    property OnOpen: TNotifyEvent read FOnOpen write FOnOpen;
  end;

function LibrarySystemName(const Id: string): string;

implementation

{$R *.fmx}

uses
  System.IOUtils, System.Math, System.Hash, System.Generics.Defaults,
  FMX.Graphics, FMX.BehaviorManager, SCRP.GameList, HGM.FMX.Image,
  Core.RomFormat, Core.SavePaths, RM.Icons, RM.SearchEdit, RM.Styles;

const
  SystemIds: array[0..6] of string = ('', ROM_SYSTEM_NES, ROM_SYSTEM_SNES, ROM_SYSTEM_GB, ROM_SYSTEM_GBC, ROM_SYSTEM_MD, ROM_SYSTEM_NEOGEO);
  SystemNames: array[0..6] of string = ('All', 'NES', 'SNES', 'GB', 'GBC', 'Mega Drive', 'Neo Geo');

function LibrarySystemName(const Id: string): string;
begin
  Result := Id;
  for var i := 0 to High(SystemIds) do
    if Id = SystemIds[i] then
      Exit(Translate(SystemNames[i]));
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

{$REGION 'Initialization and lifetime'}
constructor TLibraryView.CreateLibrary(AOwner: TComponent; const Storage: IStorage);
begin
  FBuilding := True;
  inherited Create(AOwner);
  FStorage := Storage;
  FGames := TObjectList<TLibraryGame>.Create;
  FCards := TList<TLibraryCard>.Create;
  FState := FStorage.ReadConfig(FStorage.ConfigFile('library'));
  FLimit := 48;
  FSidebar := FindComponent('FSidebar') as TPanel;
  FInspector := FindComponent('FInspector') as TPanel;
  FBody := FindComponent('FBody') as TLayout;
  FHeader := FindComponent('FHeader') as TLayout;
  FFilters := FindComponent('FFilters') as TLayout;
  FContinue := FindComponent('LibraryContinue') as TLayout;
  FCompactActions := FindComponent('FCompactActions') as TLayout;
  FScroll := FindComponent('FScroll') as TVertScrollBox;
  FGrid := FindComponent('FGrid') as TLayout;
  FTitle := FindComponent('FTitle') as TLabel;
  FCount := FindComponent('FCount') as TLabel;
  FDetails := FindComponent('FDetails') as TLabel;
  FDescription := FindComponent('FDescription') as TLabel;
  FGameInfo := FindComponent('FGameInfo') as TLabel;
  FSavesEmpty := FindComponent('FSavesEmpty') as TLabel;
  FEmpty := FindComponent('FEmpty') as TLabel;
  FContinueTitle := FindComponent('FContinueTitle') as TLabel;
  FCover := FindComponent('FCover') as TImage;
  FPlay := FindComponent('FPlay') as TButton;
  FFavorite := FindComponent('FFavorite') as TButton;
  FMore := FindComponent('FMore') as TButton;
  FGridButton := FindComponent('LibraryGridView') as TButton;
  FListButton := FindComponent('LibraryListView') as TButton;
  FGridIcon := FindComponent('LibraryDecoration11') as FMX.Objects.TPath;
  FListIcon := FindComponent('LibraryDecoration10') as FMX.Objects.TPath;
  FResume := FindComponent('LibraryResume') as TButton;
  FContinuePreview := FindComponent('FContinuePreview') as TLayout;
  FContinueCover := FindComponent('LibraryResumePreview') as TRectangle;
  FContinueCover.Fill.Bitmap.WrapMode := TWrapMode.TileStretch;
  FContinueGamePreview := FindComponent('LibraryResumeGamePreview') as TImage;
  FContinueNoPreview := FindComponent('FContinueNoPreview') as TLabel;
  FContinueCaption := FindComponent('FContinueCaption') as TLabel;
  FContinuePlatform := FindComponent('FContinuePlatform') as TLabel;
  FContinueLastPlayed := FindComponent('FContinueLastPlayed') as TLabel;
  FContinueSave := FindComponent('FContinueSave') as TLabel;

  for var I := 0 to 2 do
  begin
    FNavButtons[I] := FindComponent('Nav' + IntToStr(I)) as TButton;
    FNavButtons[I].OnClick := ModeClick;
    FNavButtons[I].TextSettings.HorzAlign := TTextAlign.Leading;
    FNavButtons[I].StylesData['text.Margins.Left'] := 48;
    FNavIcons[I] := FindComponent('NavIcon' + IntToStr(I)) as FMX.Objects.TPath;
    FSaveImages[I] := FindComponent('SavePreview' + IntToStr(I)) as TImage;
    FSaveButtons[I] := FindComponent('SaveButton' + IntToStr(I)) as TButton;
    FSaveButtons[I].OnClick := SaveClick;
  end;
  for var I := 0 to 6 do
  begin
    FPlatformButtons[I] := FindComponent('Filter' + IntToStr(I)) as TButton;
    FPlatformButtons[I].OnClick := FilterClick;
  end;
  var Platforms := FindComponent('Platforms') as TLayout;
  for var Child in Platforms.Children do
    if Child is TButton then
    begin
      TButton(Child).OnClick := FilterClick;
      TButton(Child).TextSettings.HorzAlign := TTextAlign.Leading;
      TButton(Child).StylesData['text.Margins.Left'] := 48;
      var Border := TRectangle.Create(Child);
      FSidebarPlatformBorders[TButton(Child).Tag] := Border;
      Border.Parent := Child;
      Border.Align := TAlignLayout.Contents;
      Border.Fill.Kind := TBrushKind.None;
      Border.Stroke.Color := $FFFFB344;
      Border.Stroke.Thickness := 2;
      Border.XRadius := 6;
      Border.YRadius := 6;
      Border.HitTest := False;
      Border.Visible := False;
    end;
  for var Name in ['LibraryOpenRom', 'Settings'] do
  begin
    var Button := FindComponent(Name) as TButton;
    Button.TextSettings.HorzAlign := TTextAlign.Leading;
    Button.StylesData['text.Margins.Left'] := 48;
  end;
  var SearchHost := FindComponent('SearchHost') as TLayout;
  FSearch := TSearchEdit.Create(Self);
  FSearch.Name := 'LibrarySearch';
  FSearch.Parent := SearchHost;
  FSearch.Align := TAlignLayout.Client;
  FSearch.TextPrompt := Translate('Search games');
  FSearch.OnChangeTracking := SearchChange;
  (FindComponent('LibraryOpenRom') as TButton).OnClick := OpenClick;
  (FindComponent('Settings') as TButton).OnClick := SettingsClick;
  (FindComponent('CompactOpen') as TButton).OnClick := OpenClick;
  (FindComponent('CompactSettings') as TButton).OnClick := SettingsClick;
  FormStyles.RelocalizeUI(Self, 'en');
  FPlay.OnClick := PlayClick;
  FFavorite.OnClick := FavoriteClick;
  FResume.OnClick := ResumeClick;
  FListButton.OnClick := ViewClick;
  FGridButton.OnClick := ViewClick;
  FMore.OnClick := MoreClick;
  FBody.OnResize := BodyResize;
  FGrid.OnResize := GridResize;
  {$IF Defined(ANDROID) or Defined(IOS)}
  FContinue.ClipChildren := True;
  FScroll.OnViewportPositionChange := ScrollViewportChanged;
  {$ENDIF}
  FBuilding := False;
  ApplyPreferences;
  Reload;
end;

destructor TLibraryView.Destroy;
begin
  FBuilding := True;
  FCards.Free;
  FGames.Free;
  FState.Free;
  inherited;
end;
{$ENDREGION}

{$REGION 'Library data and preferences'}

procedure TLibraryView.Reload;
begin
  FBuilding := True;
  FSelected := nil;
  FRecent := nil;
  // Cards reference games. Release them before replacing the catalog.
  for var Card in FCards do
    Card.Free;
  FCards.Clear;
  FGames.Clear;
  try
    for var i := 1 to High(SystemIds) do
    begin
      var Folder := TPath.Combine(FStorage.RomFolder, RomSystemFolder(RomSystemFromId(SystemIds[i])));
      var Metadata := TGameList.Create;
      var Lookup := TDictionary<string, TGame>.Create;
      try
        var XML := TPath.Combine(Folder, 'gamelist.xml');
        if not FStorage.RomFolder.StartsWith('content://') and FStorage.Exists(XML) then
        begin
          var Stream := FStorage.OpenRead(XML);
          try
            try
              Metadata.LoadFromStream(Stream);
            except
              Metadata.Clear;
            end;
          finally
            Stream.Free;
          end;
          for var Game in Metadata.Games do
            Lookup.AddOrSetValue(LowerCase(ExpandFileName(Game.GetPhysicalPath(Folder, Game.Path))), Game);
        end;
        for var FileInfo in FStorage.Roms(SystemIds[i]) do
        begin
          var Item := TLibraryGame.Create;
          FGames.Add(Item);
          Item.FileInfo := FileInfo;
          Item.SystemId := SystemIds[i];
          Item.Title := TPath.GetFileNameWithoutExtension(FileInfo.Name);
          var Entry: TGame;
          if Lookup.TryGetValue(LowerCase(ExpandFileName(FileInfo.Location)), Entry) then
          begin
            if Entry.Name <> '' then
              Item.Title := Entry.Name;
            Item.Cover := Entry.GetPhysicalPath(Folder, Entry.Image);
            if Item.Cover.IsEmpty then
              Item.Cover := Entry.GetPhysicalPath(Folder, Entry.Box);
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
    FGames.Sort(TComparer<TLibraryGame>.Construct(
      function(const A, B: TLibraryGame): Integer
      begin
        Result := CompareText(A.Title, B.Title);
      end));
  finally
    FBuilding := False;
  end;
  UpdateContinue;
  BuildCards;
end;

procedure TLibraryView.ApplyPreferences;
begin
  var Ini := FStorage.ReadConfig(FStorage.ConfigFile('config'));
  try
    FListMode := Ini.ReadString('Library', 'View', 'grid') = 'list';
    FShowPlatform := Ini.ReadBool('Library', 'ShowPlatform', True);
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
  // Rebuild data captions from the game records so titles and metadata stay intact.
  BuildCards;
  UpdateInspector;
  UpdateContinue;
end;

procedure TLibraryView.RecordSession(const FileName, SnapshotDirectory: string);
begin
  for var Game in FGames do
    if SameText(Game.FileInfo.Location, FileName) then
    begin
      Game.LastPlayed := Now;
      FState.WriteFloat('Recent', Game.Key, Game.LastPlayed);
      if SnapshotDirectory <> '' then
        FState.WriteString('Snapshots', Game.Key, SnapshotDirectory);
      SaveState;
      RefreshSnapshots;
      Break;
    end;
end;

procedure TLibraryView.SaveState;
begin
  FStorage.WriteConfig(FState);
end;

function TLibraryView.Matches(Game: TLibraryGame): Boolean;
begin
  Result := ((FSystemFilter = '') or (Game.SystemId = FSystemFilter)) and
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
{$ENDREGION}

{$REGION 'Cards and layout'}

procedure TLibraryView.BuildCards;
begin
  if FBuilding or (FGrid = nil) then
    Exit;
  FBuilding := True;
  try
    for var Card in FCards do
      Card.Free;
    FCards.Clear;
    var MatchesList := TList<TLibraryGame>.Create;
    try
      for var Game in FGames do
        if Matches(Game) then
          MatchesList.Add(Game);
      if FMode = 1 then
        MatchesList.Sort(TComparer<TLibraryGame>.Construct(
          function(const A, B: TLibraryGame): Integer
          begin
            Result := CompareValue(B.LastPlayed, A.LastPlayed);
          end));
      var SelectedVisible := MatchesList.Contains(FSelected);
      if not SelectedVisible then
      begin
        FSelected := nil;
        if MatchesList.Count > 0 then
          FSelected := MatchesList[0];
      end;
      FCount.Text := IntToStr(MatchesList.Count) + Translate(' games');
      for var i := 0 to Min(FLimit, MatchesList.Count) - 1 do
      begin
        var Game := MatchesList[i];
        var Card := TLibraryCard.Create(FGrid);
        Card.Parent := FGrid;
        Card.StyleLookup := 'retromul_card';
        Card.TagObject := Game;
        {$IF Defined(ANDROID) or Defined(IOS)}
        Card.OnTap := CardTap;
        {$ELSE}
        Card.OnClick := CardClick;
        {$ENDIF}
        FCards.Add(Card);
        var Cover := TImage.Create(Card);
        Card.Cover := Cover;
        Cover.Parent := Card;
        Cover.HitTest := False;
        Cover.WrapMode := TImageWrapMode.Fit;
        LoadImage(Cover, Game.Cover);
        var Title := TextLabel(Card, Card, Game.Title, 14);
        Card.Title := Title;
        Title.TextSettings.Font.Style := [TFontStyle.fsBold];
        var platform := TextLabel(Card, Card, LibrarySystemName(Game.SystemId), 12);
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
      FMore.Visible := MatchesList.Count > FLimit;
      FEmpty.Visible := MatchesList.Count = 0;
      if FGames.Count = 0 then
        FEmpty.Text := Translate('Your library is empty') + sLineBreak + Translate('Open settings and choose a ROM folder.')
      else
        FEmpty.Text := Translate('No games found') + sLineBreak + Translate('Change your search or filter.');
    finally
      MatchesList.Free;
    end;
  finally
    FBuilding := False;
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
  for var i := 0 to High(SystemIds) do
    if FSystemFilter = SystemIds[i] then
      FPlatformButtons[i].StyleLookup := 'buttonstyle_accent'
    else
      FPlatformButtons[i].StyleLookup := 'buttonstyle';
  for var I := Low(FSidebarPlatformBorders) to High(FSidebarPlatformBorders) do
    FSidebarPlatformBorders[I].Visible := FSystemFilter = SystemIds[I];
  Resize;
  UpdateInspector;
end;

procedure TLibraryView.ArrangeCards;
begin
  if FBuilding or FArranging or (FGrid = nil) then
    Exit;

  FArranging := True;
  try
    var Available := Max(140, FScroll.Width - 16);
    FGrid.Width := Available;
    var Columns := Max(1, Floor((Available + 14) / (FCardWidth + 14)));
    {$IF Defined(ANDROID) or Defined(IOS)}
    // Mobile grid cards must fit at least two across, even at the largest setting.
    Columns := Max(2, Columns);
    {$ENDIF}
    if FListMode then
      Columns := 1;
    var W := (Available - (Columns - 1) * 14) / Columns;
    var H := W * 1.1 + 66;
    if FListMode then
      H := 92;
    for var i := 0 to FCards.Count - 1 do
    begin
      var Card := FCards[i];
      Card.SetBounds((i mod Columns) * (W + 14), FContinueCollapse + (i div Columns) * (H + 14), W, H);
      var Image := Card.Cover;
      var Title := Card.Title;
      var platform := Card.platform;
      if FListMode then
      begin
        Image.SetBounds(8, 8, 60, 76);
        Title.SetBounds(84, 14, W - 104, 32);
        platform.SetBounds(84, 49, W - 104, 24);
      end
      else
      begin
        Image.SetBounds(8, 8, W - 16, H - 74);
        Title.SetBounds(12, H - 60, W - 24, 28);
        platform.SetBounds(12, H - 32, W - 24, 22);
      end;
    end;
    var Y := FContinueCollapse + Ceil(FCards.Count / Columns) * (H + 14);
    FMore.SetBounds(Max(0, (Available - 180) / 2), Y + 4, 180, 42);
    FEmpty.SetBounds(16, FContinueCollapse + 28, Available - 32, 132);
    FGrid.Height := Max(180, Y + IfThen(FMore.Visible, 64, 0));
  finally
    FArranging := False;
  end;
end;

procedure TLibraryView.Resize;
begin
  if (csLoading in ComponentState) or FBuilding or FLayouting or (FBody = nil) then
    Exit;

  FLayouting := True;
  try
    inherited;
    FSidebar.Visible := Width >= 900;
    FCompactActions.Visible := not FSidebar.Visible;
    FInspector.Visible := Width >= 1120;
    var ContentWidth := Max(140, FBody.Width - 48);
    var Y: Single := 22;
    FHeader.SetBounds(24, Y, ContentWidth, 92);
    Y := Y + 96;
    if FCompactActions.Visible then
    begin
      FCompactActions.SetBounds(24, Y, ContentWidth, 48);
      Y := Y + 48;
    end;
    FContinuePreview.Visible := ContentWidth >= 720;
    FContinueCollapse := 0;
    FContinueExtent := 0;
    if FContinue.Visible then
    begin
      var Stacked := ContentWidth < 520;
      var Height := IfThen(Stacked, 208, 154);
      FContinueExtent := Height + 16;
      {$IF Defined(ANDROID) or Defined(IOS)}
      // Reserve the wrapped filters, count, and a usable list viewport on short screens.
      if FBody.Height - Y - FContinueExtent < 88 + 28 + 18 + 92 then
        FContinueExtent := 0;
      FContinueCollapse := EnsureRange(FScroll.ViewportPosition.Y, 0, FContinueExtent);
      if FContinueExtent = 0 then
        FContinue.Opacity := 0
      else
        FContinue.Opacity := 1 - FContinueCollapse / FContinueExtent;
      FContinue.Enabled := (FContinueExtent > 0) and (FContinueCollapse < Height);
      {$ENDIF}
      FContinue.SetBounds(24, Y, ContentWidth, Max(0, Min(Height, FContinueExtent - FContinueCollapse)));
      var TextX: Single := 20;
      if FContinuePreview.Visible then
      begin
        var PreviewWidth: Single := 176;
        FContinuePreview.SetBounds(12, 12, PreviewWidth, Height - 24);
        ArrangeContinuePreview;
        TextX := 12 + FContinuePreview.Width + 24;
      end;
      var ButtonWidth := Min(144, ContentWidth - 40);
      var TextWidth := ContentWidth - TextX - 20;
      if not Stacked then
        TextWidth := TextWidth - ButtonWidth - 20;
      FContinueCaption.SetBounds(TextX, 16, TextWidth, 18);
      FContinueTitle.SetBounds(TextX, 38, TextWidth, 32);
      FContinuePlatform.SetBounds(TextX, 74, TextWidth, 18);
      FContinueLastPlayed.SetBounds(TextX, 94, TextWidth, 18);
      FContinueSave.SetBounds(TextX, 114, TextWidth, 18);
      FResume.SetBounds(ContentWidth - ButtonWidth - 18, Height - 58, ButtonWidth, 40);
      Y := Y + FContinueExtent - FContinueCollapse;
    end;
    FFilters.SetBounds(24, Y, ContentWidth, 46);
    var X: Single := 0;
    var FilterY: Single := 4;
    for var B in FPlatformButtons do
    begin
      var W: Single := 56;
      if Length(B.Text) > 6 then
        W := 102;
      if X + W > ContentWidth then
      begin
        X := 0;
        FilterY := FilterY + 41;
      end;
      B.Visible := True;
      B.SetBounds(X, FilterY, W, 34);
      X := X + W + 7;
    end;
    FFilters.Height := FilterY + 42;
    Y := Y + FFilters.Height;
    FCount.SetBounds(24, Y, ContentWidth, 28);
    Y := Y + 28;
    // Add the consumed header distance to the content before growing its viewport.
    // This keeps the scroll range and card motion continuous during the collapse.
    FScroll.Width := ContentWidth;
    ArrangeCards;
    FScroll.SetBounds(24, Y, ContentWidth, Max(0, FBody.Height - Y - 18));
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

{$IF Defined(ANDROID) or Defined(IOS)}
procedure TLibraryView.ScrollViewportChanged(Sender: TObject; const OldPosition, NewPosition: TPointF;
  const ContentSizeChanged: Boolean);
begin
  if FBuilding or FLayouting or not FContinue.Visible then
    Exit;
  var Collapse := EnsureRange(NewPosition.Y, 0, FContinueExtent);
  if not SameValue(Collapse, FContinueCollapse, 0.1) then
    Resize;
end;
{$ENDIF}
{$ENDREGION}

{$REGION 'Selected game and continue panel'}

procedure TLibraryView.UpdateInspector;
begin
  FPlay.Enabled := FSelected <> nil;
  FFavorite.Enabled := FSelected <> nil;
  if FSelected = nil then
  begin
    FTitle.Text := Translate('Select a game');
    FCover.Bitmap := nil;
    FDetails.Text := '';
    FDescription.Text := '';
    FGameInfo.Text := '';
  end
  else
  begin
    FTitle.Text := FSelected.Title;
    FDetails.Text := LibrarySystemName(FSelected.SystemId) + sLineBreak + FSelected.Developer;
    FDescription.Text := FSelected.Description;
    if FDescription.Text = '' then
      FDescription.Text := FSelected.Genre;
    FGameInfo.Text := '';
    if FSelected.Genre <> '' then
      FGameInfo.Text := Translate('Genre: ') + FSelected.Genre;
    if FSelected.Players <> '' then
      FGameInfo.Text := FGameInfo.Text + sLineBreak + Translate('Players: ') + FSelected.Players;
    if FSelected.Favorite then
      FFavorite.Text := Translate('Remove from favorites')
    else
      FFavorite.Text := Translate('Add to favorites');
    LoadImage(FCover, FSelected.Cover);
  end;
  var Saves := Snapshots(FSelected);
  FSavesEmpty.Visible := Length(Saves) = 0;
  FSavesEmpty.Text := Translate('No save states yet.');
  for var i := 0 to 2 do
  begin
    FSaveButtons[i].Visible := i < Length(Saves);
    FSaveImages[i].Visible := i < Length(Saves);
    if i < Length(Saves) then
    begin
      FSaveButtons[i].Text := Saves[i].Name + sLineBreak + FormatDateTime('dd.mm.yyyy hh:nn', Saves[i].Modified);
      FSaveButtons[i].TagString := Saves[i].Location;
      LoadImage(FSaveImages[i], Saves[i].PreviewLocation);
    end;
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
  SelectContinueGame;
  var Bitmap := FContinueCover.Fill.Bitmap.Bitmap;
  Bitmap.RemoveCallback(FContinueCover);
  FContinueGamePreview.Bitmap.RemoveCallback(FContinueGamePreview);
  FContinue.Visible := FRecent <> nil;
  if FRecent = nil then
    Exit;

  FContinueTitle.Text := FRecent.Title;
  FContinuePlatform.Text := LibrarySystemName(FRecent.SystemId);
  if FRecent.Genre <> '' then
    FContinuePlatform.Text := FContinuePlatform.Text + ' · ' + FRecent.Genre;
  FContinueLastPlayed.Text := Translate('Last played: ') + LibraryDate(FRecent.LastPlayed);
  var Saves := Snapshots(FRecent);
  var Preview := '';
  if Length(Saves) > 0 then
  begin
    FContinueCaption.Text := Translate('Continue playing');
    FResume.Text := Translate('Resume');
    FContinueSave.Text := Translate('Save state: ') + Saves[0].Name + ' · ' + LibraryDate(Saves[0].Modified);
    if FStorage.Exists(Saves[0].PreviewLocation) then
      Preview := Saves[0].PreviewLocation;
  end
  else
  begin
    FContinueCaption.Text := Translate('Recently played');
    FResume.Text := Translate('Play');
    FContinueSave.Text := Translate('No save states yet');
  end;
  Bitmap.SetSize(0, 0);
  FContinueCover.Fill.Kind := TBrushKind.Solid;
  FContinueCover.Visible := True;
  FContinueGamePreview.Bitmap := nil;
  FContinueGamePreview.Visible := False;
  FContinueNoPreview.Visible := True;
  FContinueNoPreview.Text := Translate('No save-state screenshot');
  if Length(Saves) = 0 then
    FContinueNoPreview.Text := Translate('No save state');
  ArrangeContinuePreview;
  if Preview <> '' then
    Bitmap.LoadFromFileAsync(FContinueCover, Preview, 320, 400,
      procedure(Success: Boolean)
      begin
        if Success then
        begin
          FContinueCover.Fill.Kind := TBrushKind.Bitmap;
          FContinueNoPreview.Visible := False;
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
  FContinueNoPreview.Text := Translate('Preview unavailable');
  FContinueNoPreview.Visible := (FRecent.Cover = '') or not FStorage.Exists(FRecent.Cover);
  LoadImage(FContinueGamePreview, FRecent.Cover);
end;

procedure TLibraryView.ArrangeContinuePreview;
begin
  var Bitmap := FContinueCover.Fill.Bitmap.Bitmap;
  if not Bitmap.IsEmpty then
    FContinuePreview.Width := FContinuePreview.Height * Bitmap.Width / Bitmap.Height
  else
    FContinuePreview.Width := 176;
  FContinueCover.SetBounds(0, 0, FContinuePreview.Width, FContinuePreview.Height);
end;
{$ENDREGION}

{$REGION 'View events'}

procedure TLibraryView.OpenClick(Sender: TObject);
begin
  if Assigned(FOnOpen) then
    FOnOpen(Self);
end;

procedure TLibraryView.SettingsClick(Sender: TObject);
begin
  if Assigned(FOnSettings) then
    FOnSettings(Self);
end;

procedure TLibraryView.FilterClick(Sender: TObject);
begin
  FSystemFilter := SystemIds[TButton(Sender).Tag];
  FLimit := 48;
  BuildCards;
end;

procedure TLibraryView.ModeClick(Sender: TObject);
begin
  FMode := TButton(Sender).Tag;
  FLimit := 48;
  BuildCards;
end;

procedure TLibraryView.SearchChange(Sender: TObject);
begin
  FLimit := 48;
  BuildCards;
end;

procedure TLibraryView.CardClick(Sender: TObject);
begin
  FSelected := TLibraryGame(TPanel(Sender).TagObject);
  for var Card in FCards do
    Card.Selection.Visible := Card.TagObject = FSelected;
  UpdateInspector;
  if not FInspector.Visible then
    PlayClick(Self);
end;

{$IF Defined(ANDROID) or Defined(IOS)}
procedure TLibraryView.CardTap(Sender: TObject; const Point: TPointF);
begin
  CardClick(Sender);
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
  Inc(FLimit, 48);
  BuildCards;
end;
{$ENDREGION}

end.

