unit RM.LibraryView;

interface

uses
  System.SysUtils, System.Classes, System.Types, System.UITypes,
  System.Generics.Collections, System.IniFiles, FMX.Types, FMX.Controls,
  FMX.Layouts, FMX.StdCtrls, FMX.Edit, FMX.Objects, Core.Storage;

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

  TLibraryView = class(TPanel)
  private
    FStorage: IStorage;
    FGames: TObjectList<TLibraryGame>;
    FState: TMemIniFile;
    FSidebar, FInspector: TPanel;
    FBody, FHeader, FFilters, FContinue: TLayout;
    FCompactActions: TLayout;
    FScroll: TVertScrollBox;
    FGrid: TLayout;
    FSearch: TEdit;
    FTitle, FCount, FDetails, FDescription, FGameInfo, FSavesEmpty, FEmpty, FContinueTitle: TLabel;
    FCover: TImage;
    FPlay, FFavorite, FMore, FGridButton, FListButton, FResume: TButton;
    FSaveButtons: array[0..2] of TButton;
    FSaveImages: array[0..2] of TImage;
    FPlatformButtons: array[0..6] of TButton;
    FNavButtons: array[0..2] of TButton;
    FNavIcons: array[0..2] of TPath;
    FContinuePreview: TLayout;
    FContinueCover: TRectangle;
    FContinueGamePreview: TImage;
    FContinueNoPreview: TLabel;
    FContinueCaption, FContinuePlatform, FContinueLastPlayed, FContinueSave: TLabel;
    FCards: TList<TLibraryCard>;
    FSelected, FRecent: TLibraryGame;
    FSystemFilter: string;
    FMode, FLimit: Integer;
    FListMode, FBuilding, FArranging, FLayouting, FShowPlatform: Boolean;
    FCardWidth: Integer;
    FSnapshotName: string;
    FOnPlay, FOnSettings, FOnOpen: TNotifyEvent;
    procedure OpenClick(Sender: TObject);
    procedure SettingsClick(Sender: TObject);
    procedure GridResize(Sender: TObject);
    procedure BodyResize(Sender: TObject);
    procedure FilterClick(Sender: TObject);
    procedure ModeClick(Sender: TObject);
    procedure SearchChange(Sender: TObject);
    procedure CardClick(Sender: TObject);
    procedure PlayClick(Sender: TObject);
    procedure ResumeClick(Sender: TObject);
    procedure SaveClick(Sender: TObject);
    procedure FavoriteClick(Sender: TObject);
    procedure ViewClick(Sender: TObject);
    procedure MoreClick(Sender: TObject);
    procedure BuildCards;
    procedure UpdateInspector;
    procedure UpdateContinue;
    procedure SelectContinueGame;
    procedure ArrangeContinuePreview;
    procedure LoadContinueGamePreview;
    procedure ArrangeCards;
    procedure SaveState;
    function Matches(Game: TLibraryGame): Boolean;
    function GetSelected: TLibraryGame;
    function Snapshots(Game: TLibraryGame): TArray<TStorageSnapshot>;
    procedure LoadImage(Image: TImage; const Location: string);
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

function InterfaceIcon(Parent: TControl; const Data: string; X, Y, Size: Single; Color: TAlphaColor = $FFB9C2CC): TPath;

implementation

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

function InterfaceIcon(Parent: TControl; const Data: string; X, Y, Size: Single; Color: TAlphaColor): FMX.Objects.TPath;
begin
  Result := CreatePathIcon(Parent, Data, X, Y, Size, Color);
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

constructor TLibraryView.CreateLibrary(AOwner: TComponent; const Storage: IStorage);
begin
  inherited Create(AOwner);
  FBuilding := True;
  StyleLookup := 'retromul_settings';
  FStorage := Storage;
  FGames := TObjectList<TLibraryGame>.Create;
  FCards := TList<TLibraryCard>.Create;
  FState := FStorage.ReadConfig(FStorage.ConfigFile('library'));
  FLimit := 48;
  FSidebar := TPanel.Create(Self);
  FSidebar.Parent := Self;
  FSidebar.Align := TAlignLayout.Left;
  FSidebar.Width := 264;
  FSidebar.StyleLookup := 'retromul_sidebar';
  var Brand := TextLabel(Self, FSidebar, 'RetroMul', 26);
  Brand.SetBounds(64, 22, 154, 40);
  Brand.TextSettings.Font.Size := 23;
  InterfaceIcon(FSidebar, IconPad, 24, 26, 30, $FFFFB344);
  Brand.TextSettings.Font.Style := [TFontStyle.fsBold];
  var Nav := TLayout.Create(Self);
  Nav.Parent := FSidebar;
  Nav.SetBounds(12, 88, 240, 162);
  for var i := 0 to 2 do
  begin
    var Name := Translate('Library');
    if i = 1 then
      Name := Translate('Recent');
    if i = 2 then
      Name := Translate('Favorites');
    FNavButtons[i] := ActionButton(Self, Nav, Name, ModeClick);
    FNavButtons[i].SetBounds(0, i * 54, 240, 46);
    FNavButtons[i].StyledSettings := FNavButtons[i].StyledSettings - [TStyledSetting.Size, TStyledSetting.Other];
    FNavButtons[i].TextSettings.Font.Size := 15;
    FNavButtons[i].Tag := i;
    FNavButtons[i].TextSettings.HorzAlign := TTextAlign.Leading;
    FNavButtons[i].StylesData['text.Margins.Left'] := 48;
    var Icon := IconLibrary;
    if i = 1 then
      Icon := IconClock;
    if i = 2 then
      Icon := IconHeart;
    FNavIcons[i] := InterfaceIcon(FNavButtons[i], Icon, 16, 13, 22);
  end;
  var Platforms := TLayout.Create(Self);
  Platforms.Parent := FSidebar;
  Platforms.SetBounds(12, 272, 240, 338);
  var PL := TextLabel(Self, Platforms, Translate('Platforms'), 13);
  PL.SetBounds(8, 0, 184, 30);
  PL.Opacity := 0.6;
  for var i := 1 to High(SystemIds) do
  begin
    var B := ActionButton(Self, Platforms, SystemNames[i], FilterClick);
    B.SetBounds(0, 34 + (i - 1) * 47, 240, 42);
    B.StyleLookup := 'buttonstyle_subtle';
    B.StyledSettings := B.StyledSettings - [TStyledSetting.Size, TStyledSetting.Other];
    B.TextSettings.Font.Size := 14;
    B.TagString := SystemIds[i];
    B.TextSettings.HorzAlign := TTextAlign.Leading;
    B.StylesData['text.Margins.Left'] := 48;
    InterfaceIcon(B, IconPad, 16, 11, 22);
  end;
  var Bottom := TLayout.Create(Self);
  Bottom.Parent := FSidebar;
  Bottom.Align := TAlignLayout.Bottom;
  Bottom.Height := 118;
  Bottom.Padding.Rect := TRectF.Create(12, 12, 12, 12);
  var Open := ActionButton(Self, Bottom, Translate('Open ROM'), nil);
  Open.Name := 'LibraryOpenRom';
  Open.Align := TAlignLayout.Top;
  Open.OnClick := OpenClick;
  Open.StyledSettings := Open.StyledSettings - [TStyledSetting.Other];
  Open.TextSettings.HorzAlign := TTextAlign.Leading;
  Open.StylesData['text.Margins.Left'] := 48;
  InterfaceIcon(Open, IconFolder, 16, 10, 22);
  var Settings := ActionButton(Self, Bottom, Translate('Settings'), nil);
  Settings.Align := TAlignLayout.Bottom;
  Settings.OnClick := SettingsClick;
  Settings.StyledSettings := Settings.StyledSettings - [TStyledSetting.Other];
  Settings.TextSettings.HorzAlign := TTextAlign.Leading;
  Settings.StylesData['text.Margins.Left'] := 48;
  InterfaceIcon(Settings, IconGear, 16, 10, 22);
  FInspector := TPanel.Create(Self);
  FInspector.Parent := Self;
  FInspector.Align := TAlignLayout.Right;
  FInspector.Width := 292;
  FInspector.Padding.Rect := TRectF.Create(20, 24, 20, 20);
  FInspector.StyleLookup := 'retromul_sidebar';
  var DetailScroll := TVertScrollBox.Create(Self);
  DetailScroll.ScrollAnimation := TBehaviorBoolean.True;
  DetailScroll.Parent := FInspector;
  DetailScroll.Align := TAlignLayout.Client;
  FCover := TImage.Create(Self);
  FCover.Parent := DetailScroll;
  FCover.SetBounds(0, 0, 248, 272);
  FCover.WrapMode := TImageWrapMode.Fit;
  FTitle := TextLabel(Self, DetailScroll, Translate('Select a game'), 23);
  FTitle.SetBounds(0, 282, 248, 64);
  FTitle.TextSettings.WordWrap := True;
  FTitle.TextSettings.Font.Style := [TFontStyle.fsBold];
  FDetails := TextLabel(Self, DetailScroll, '', 13);
  FDetails.SetBounds(0, 348, 248, 50);
  FDetails.TextSettings.WordWrap := True;
  FDetails.Opacity := 0.65;
  FPlay := ActionButton(Self, DetailScroll, Translate('Play'), PlayClick);
  FPlay.SetBounds(0, 406, 248, 44);
  FPlay.StyleLookup := 'buttonstyle_accent';
  FFavorite := ActionButton(Self, DetailScroll, Translate('Add to favorites'), FavoriteClick);
  FFavorite.SetBounds(0, 460, 248, 40);
  FDescription := TextLabel(Self, DetailScroll, '', 13);
  FDescription.SetBounds(0, 516, 248, 92);
  FDescription.TextSettings.WordWrap := True;
  FDescription.Opacity := 0.7;
  FGameInfo := TextLabel(Self, DetailScroll, '', 13);
  FGameInfo.SetBounds(0, 610, 248, 48);
  FGameInfo.TextSettings.WordWrap := True;
  FGameInfo.Opacity := 0.7;
  var SL := TextLabel(Self, DetailScroll, Translate('Save states'), 19);
  SL.SetBounds(0, 670, 248, 32);
  FSavesEmpty := TextLabel(Self, DetailScroll, '', 13);
  FSavesEmpty.SetBounds(0, 710, 248, 54);
  FSavesEmpty.TextSettings.WordWrap := True;
  FSavesEmpty.Opacity := 0.6;
  for var i := 0 to 2 do
  begin
    FSaveImages[i] := TImage.Create(Self);
    FSaveImages[i].Parent := DetailScroll;
    FSaveImages[i].SetBounds(0, 710 + i * 84, 76, 64);
    FSaveButtons[i] := ActionButton(Self, DetailScroll, Translate('No save state'), SaveClick);
    FSaveButtons[i].SetBounds(84, 710 + i * 84, 164, 64);
    FSaveButtons[i].Visible := False;
  end;
  FBody := TLayout.Create(Self);
  FBody.Parent := Self;
  FBody.Align := TAlignLayout.Client;
  FBody.Padding.Rect := TRectF.Create(24, 22, 24, 18);
  FBody.OnResize := BodyResize;
  FHeader := TLayout.Create(Self);
  FHeader.Parent := FBody;
  FHeader.Align := TAlignLayout.None;
  FHeader.Height := 92;
  FCompactActions := TLayout.Create(Self);
  FCompactActions.Parent := FBody;
  FCompactActions.Align := TAlignLayout.None;
  FCompactActions.Position.Y := 92;
  FCompactActions.Height := 48;
  var CompactOpen := ActionButton(Self, FCompactActions, Translate('Open ROM'), OpenClick);
  CompactOpen.SetBounds(0, 0, 136, 36);
  var CompactSettings := ActionButton(Self, FCompactActions, Translate('Settings'), SettingsClick);
  CompactSettings.SetBounds(144, 0, 136, 36);
  var Heading := TextLabel(Self, FHeader, Translate('Library'), 30);
  Heading.Align := TAlignLayout.Top;
  Heading.Height := 42;
  Heading.TextSettings.Font.Style := [TFontStyle.fsBold];
  FListButton := ActionButton(Self, FHeader, '', ViewClick);
  FListButton.Name := 'LibraryListView';
  FListButton.Hint := Translate('List');
  AddButtonIcon(FListButton, IconViewList, 18);
  FListButton.Align := TAlignLayout.Right;
  FListButton.Width := 42;
  FListButton.Tag := 1;
  FListButton.Margins.Rect := RectF(0, 8, 0, 8);
  FGridButton := ActionButton(Self, FHeader, '', ViewClick);
  FGridButton.Name := 'LibraryGridView';
  FGridButton.Hint := Translate('Covers');
  AddButtonIcon(FGridButton, IconViewGrid, 18);
  FGridButton.Align := TAlignLayout.Right;
  FGridButton.Width := 42;
  FGridButton.Margins.Rect := RectF(8, 8, 0, 8);
  FSearch := TSearchEdit.Create(Self);
  FSearch.Name := 'LibrarySearch';
  FSearch.Parent := FHeader;
  FSearch.Align := TAlignLayout.Client;
  FSearch.Margins.Right := 12;
  FSearch.TextPrompt := Translate('Search games');
  FSearch.OnChangeTracking := SearchChange;
  FContinue := TLayout.Create(Self);
  FContinue.Name := 'LibraryContinue';
  FContinue.Parent := FBody;
  FContinue.Align := TAlignLayout.None;
  FContinue.Height := 102;
  FContinue.Margins.Rect := TRectF.Create(0, 8, 0, 14);
  var ContinueBG := TPanel.Create(Self);
  ContinueBG.Parent := FContinue;
  ContinueBG.Align := TAlignLayout.Contents;
  ContinueBG.StyleLookup := 'retromul_card';
  FContinuePreview := TLayout.Create(Self);
  FContinuePreview.Parent := FContinue;
  FContinueCover := TRectangle.Create(Self);
  FContinueCover.Name := 'LibraryResumePreview';
  FContinueCover.Parent := FContinuePreview;
  FContinueCover.HitTest := False;
  FContinueCover.Stroke.Kind := TBrushKind.None;
  FContinueCover.Fill.Color := $FF181C21;
  FContinueCover.Fill.Bitmap.WrapMode := TWrapMode.TileStretch;
  FContinueCover.XRadius := 10;
  FContinueCover.YRadius := 10;
  FContinueGamePreview := TImage.Create(Self);
  FContinueGamePreview.Name := 'LibraryResumeGamePreview';
  FContinueGamePreview.Parent := FContinuePreview;
  FContinueGamePreview.Align := TAlignLayout.Contents;
  FContinueGamePreview.WrapMode := TImageWrapMode.Fit;
  FContinueGamePreview.HitTest := False;
  FContinueNoPreview := TextLabel(Self, FContinuePreview, Translate('No save-state screenshot'), 12);
  FContinueNoPreview.Align := TAlignLayout.Contents;
  FContinueNoPreview.TextSettings.HorzAlign := TTextAlign.Center;
  FContinueNoPreview.TextSettings.WordWrap := True;
  FContinueNoPreview.Opacity := 0.5;
  FContinueCaption := TextLabel(Self, FContinue, Translate('Continue playing'), 13);
  FContinueCaption.Opacity := 0.6;
  FContinueTitle := TextLabel(Self, FContinue, '', 24);
  FContinueTitle.TextSettings.Font.Style := [TFontStyle.fsBold];
  FContinuePlatform := TextLabel(Self, FContinue, '', 13);
  FContinuePlatform.Opacity := 0.7;
  FContinueLastPlayed := TextLabel(Self, FContinue, '', 12);
  FContinueLastPlayed.Opacity := 0.6;
  FContinueSave := TextLabel(Self, FContinue, '', 12);
  FContinueSave.Opacity := 0.6;
  FResume := ActionButton(Self, FContinue, Translate('Resume'), ResumeClick);
  FResume.Name := 'LibraryResume';
  FResume.StyleLookup := 'buttonstyle_accent';
  FFilters := TLayout.Create(Self);
  FFilters.Parent := FBody;
  FFilters.Align := TAlignLayout.None;
  FFilters.Height := 46;
  for var i := 0 to High(SystemIds) do
  begin
    FPlatformButtons[i] := ActionButton(Self, FFilters, SystemNames[i], FilterClick);
    FPlatformButtons[i].TagString := SystemIds[i];
    FPlatformButtons[i].Height := 34;
  end;
  FCount := TextLabel(Self, FBody, '', 12);
  FCount.Align := TAlignLayout.None;
  FCount.Height := 28;
  FCount.Opacity := 0.55;
  FScroll := TVertScrollBox.Create(Self);
  FScroll.Parent := FBody;
  FScroll.Align := TAlignLayout.None;
  FScroll.ScrollAnimation := TBehaviorBoolean.True;
  FGrid := TLayout.Create(Self);
  FGrid.Parent := FScroll;
  FGrid.OnResize := GridResize;
  FEmpty := TextLabel(Self, FGrid, '', 18);
  FEmpty.TextSettings.WordWrap := True;
  FMore := ActionButton(Self, FGrid, Translate('Show more'), MoreClick);
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
  if FCards <> nil then
    BuildCards;
end;

function TLibraryView.Matches(Game: TLibraryGame): Boolean;
begin
  Result := ((FSystemFilter = '') or (Game.SystemId = FSystemFilter)) and
    ((FMode <> 1) or (Game.LastPlayed > 0)) and ((FMode <> 2) or Game.Favorite) and
    ((FSearch.Text = '') or Game.Title.ToLower.Contains(FSearch.Text.ToLower));
end;

procedure TLibraryView.ApplyLanguage(const PreviousLanguage: string);
begin
  FormStyles.RelocalizeUI(Self, PreviousLanguage);
  // Rebuild data captions from the game records so titles and metadata stay intact.
  BuildCards;
  UpdateInspector;
  UpdateContinue;
end;

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
        Card.OnClick := CardClick;
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
    if FListMode then
      Columns := 1;
    var W := (Available - (Columns - 1) * 14) / Columns;
    var H := W * 1.1 + 66;
    if FListMode then
      H := 92;
    for var i := 0 to FCards.Count - 1 do
    begin
      var Card := FCards[i];
      Card.SetBounds((i mod Columns) * (W + 14), (i div Columns) * (H + 14), W, H);
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
    var Y := Ceil(FCards.Count / Columns) * (H + 14);
    FMore.SetBounds(Max(0, (Available - 180) / 2), Y + 4, 180, 42);
    FEmpty.SetBounds(16, 28, Available - 32, 132);
    FGrid.Height := Max(180, Y + IfThen(FMore.Visible, 64, 0));
  finally
    FArranging := False;
  end;
end;

procedure TLibraryView.Resize;
begin
  if FBuilding or FLayouting or (FBody = nil) then
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
    if FContinue.Visible then
    begin
      var Stacked := ContentWidth < 520;
      var Height := IfThen(Stacked, 208, 154);
      FContinue.SetBounds(24, Y, ContentWidth, Height);
      var TextX: Single := 20;
      if FContinuePreview.Visible then
      begin
        var PreviewWidth: Single := 176;
        FContinuePreview.SetBounds(12, 12, PreviewWidth, Height - 24);
        ArrangeContinuePreview;
        TextX := 12 + PreviewWidth + 24;
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
      Y := Y + Height + 16;
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
    FScroll.SetBounds(24, Y, ContentWidth, Max(0, FBody.Height - Y - 18));
    ArrangeCards;
  finally
    FLayouting := False;
  end;
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

function TLibraryView.GetSelected: TLibraryGame;
begin
  Result := FSelected;
end;

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

procedure TLibraryView.GridResize(Sender: TObject);
begin
  ArrangeCards;
end;

procedure TLibraryView.BodyResize(Sender: TObject);
begin
  Resize;
end;

procedure TLibraryView.FilterClick(Sender: TObject);
begin
  FSystemFilter := TButton(Sender).TagString;
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

procedure TLibraryView.SaveState;
begin
  FStorage.WriteConfig(FState);
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

procedure TLibraryView.ViewClick(Sender: TObject);
begin
  FListMode := TButton(Sender).Tag = 1;
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

procedure TLibraryView.ArrangeContinuePreview;
begin
  var Bounds := FContinuePreview.LocalRect;
  var Bitmap := FContinueCover.Fill.Bitmap.Bitmap;
  if not Bitmap.IsEmpty then
  begin
    var Fit := TRectF.Create(0, 0, Bitmap.Width, Bitmap.Height);
    Fit.Fit(Bounds);
    Bounds := Fit;
  end;
  FContinueCover.SetBounds(Bounds.Left, Bounds.Top, Bounds.Width, Bounds.Height);
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
          ArrangeContinuePreview;
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

procedure TLibraryView.RefreshSnapshots;
begin
  UpdateInspector;
  UpdateContinue;
  Resize;
end;

end.

