unit SCRP.GameList;

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections, Xml.XMLIntf,
  Xml.XMLDoc, Xml.xmldom, Xml.OmniXMLDom;

type
  TGameProvider = class
  private
    FSystem: string;
    FSoftware: string;
    FDatabase: string;
    FWeb: string;
  public
    procedure Clear;

    procedure LoadFromXML(const ANode: IXMLNode);
    function SaveToXML(const AParent: IXMLNode): IXMLNode;

    property System: string read FSystem write FSystem;
    property Software: string read FSoftware write FSoftware;
    property Database: string read FDatabase write FDatabase;
    property Web: string read FWeb write FWeb;
  end;

  TGameMap = class
  private
    FPath: string;
    FTitle: string;
  public
    procedure LoadFromXML(const ANode: IXMLNode);
    function SaveToXML(const AParent: IXMLNode): IXMLNode;

    property Path: string read FPath write FPath;
    property Title: string read FTitle write FTitle;
  end;

  TGame = class
  private
    FID: string;
    FSource: string;

    FPath: string;
    FName: string;
    FDesc: string;
    FRating: string;
    FReleaseDate: string;
    FDeveloper: string;
    FPublisher: string;
    FGenreID: string;
    FGenre: string;
    FPlayers: string;
    FHash: string;
    FMD5: string;
    FImage: string;
    FBox: string;
    FThumbnail: string;
    FVideo: string;
    FManual: string;
    FFavorite: Boolean;
    FHasFavorite: Boolean;
    FTips: string;
    FMaps: TObjectList<TGameMap>;
    function GetRomName: string;
    function GetRomNameWoExt: string;
    procedure SetFavorite(const Value: Boolean);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Clear;
    function GetPhysicalPath(const ARootFolder, APath: string): string;

    procedure LoadFromXML(const ANode: IXMLNode);
    function SaveToXML(const AParent: IXMLNode): IXMLNode;

    property ID: string read FID write FID;
    property Source: string read FSource write FSource;

    property Path: string read FPath write FPath;
    property Name: string read FName write FName;
    property Desc: string read FDesc write FDesc;
    property Rating: string read FRating write FRating;
    property ReleaseDate: string read FReleaseDate write FReleaseDate;
    property Developer: string read FDeveloper write FDeveloper;
    property Publisher: string read FPublisher write FPublisher;
    property GenreID: string read FGenreID write FGenreID;
    property Genre: string read FGenre write FGenre;
    property Players: string read FPlayers write FPlayers;
    property Hash: string read FHash write FHash;
    property MD5: string read FMD5 write FMD5;
    property Image: string read FImage write FImage;
    property Box: string read FBox write FBox;
    property Thumbnail: string read FThumbnail write FThumbnail;
    property Video: string read FVideo write FVideo;
    property Manual: string read FManual write FManual;
    property Tips: string read FTips write FTips;
    property Maps: TObjectList<TGameMap> read FMaps;
    property Favorite: Boolean read FFavorite write SetFavorite;
    property HasFavorite: Boolean read FHasFavorite;
    //
    property RomName: string read GetRomName;
    property RomNameWoExt: string read GetRomNameWoExt;
  end;

  TGameList = class
  private
    FProvider: TGameProvider;
    FGames: TObjectList<TGame>;
  public
    constructor Create;
    destructor Destroy; override;

    procedure Clear;

    procedure LoadFromXML(const ANode: IXMLNode);
    procedure SaveToXML(const ADocument: IXMLDocument);

    procedure LoadFromFile(const AFileName: string);
    procedure SaveToFile(const AFileName: string);

    property Provider: TGameProvider read FProvider;
    property Games: TObjectList<TGame> read FGames;
  end;

implementation

uses
  System.IOUtils;

function XMLChild(const AParent: IXMLNode; const AName: string): IXMLNode;
begin
  Result := AParent.ChildNodes.FindNode(AName);
end;

function XMLReadString(const AParent: IXMLNode; const AName: string): string;
begin
  var Node := XMLChild(AParent, AName);

  if Assigned(Node) then
    Result := Node.Text
  else
    Result := '';
end;

function XMLReadAttribute(const ANode: IXMLNode; const AName: string): string;
begin
  if ANode.HasAttribute(AName) then
    Result := ANode.GetAttribute(AName)
  else
    Result := '';
end;

function XMLReadBool(const AParent: IXMLNode; const AName: string; const ADefault: Boolean = False): Boolean;
begin
  var Node := XMLChild(AParent, AName);

  if not Assigned(Node) then
    Exit(ADefault);

  var S := Node.Text.Trim.ToLower;
  if S.IsEmpty then
    Exit(ADefault);

  Result := (S = 'true') or (S = '1') or (S = 'yes');
end;

function XMLAddElement(const AParent: IXMLNode; const AName: string; const AValue: string): IXMLNode;
begin
  Result := AParent.AddChild(AName);
  Result.Text := AValue;
end;

function XMLAddAttribute(const ANode: IXMLNode; const AName: string; const AValue: string): IXMLNode;
begin
  ANode.SetAttribute(AName, AValue);
  Result := ANode;
end;

function XMLBoolToString(const AValue: Boolean): string;
begin
  if AValue then
    Result := 'true'
  else
    Result := 'false';
end;

{ TGameProvider }

procedure TGameProvider.Clear;
begin
  FSystem := '';
  FSoftware := '';
  FDatabase := '';
  FWeb := '';
end;

procedure TGameProvider.LoadFromXML(const ANode: IXMLNode);
begin
  Clear;

  if not Assigned(ANode) then
    Exit;

  FSystem := XMLReadString(ANode, 'System');
  FSoftware := XMLReadString(ANode, 'software');
  FDatabase := XMLReadString(ANode, 'database');
  FWeb := XMLReadString(ANode, 'web');
end;

function TGameProvider.SaveToXML(const AParent: IXMLNode): IXMLNode;
begin
  Result := AParent.AddChild('provider');

  XMLAddElement(Result, 'System', FSystem);
  XMLAddElement(Result, 'software', FSoftware);
  XMLAddElement(Result, 'database', FDatabase);
  XMLAddElement(Result, 'web', FWeb);
end;

{ TGame }

constructor TGame.Create;
begin
  inherited Create;
  FMaps := TObjectList<TGameMap>.Create;
  Clear;
end;

destructor TGame.Destroy;
begin
  FMaps.Free;
  inherited;
end;

function TGame.GetPhysicalPath(const ARootFolder, APath: string): string;
begin
  if APath.IsEmpty then
    Result := ''
  else
  begin
    // Strip only the leading current-directory marker. Replacing every './'
    // corrupts parent paths ('../') and valid directory names ending in a dot.
    var RelativePath := APath;
    if RelativePath.StartsWith('./') then
      Delete(RelativePath, 1, 2);
    Result := TPath.Combine(ARootFolder, RelativePath);
  end;
end;

procedure TGame.SetFavorite(const Value: Boolean);
begin
  FFavorite := Value;
  FHasFavorite := True;
end;

function TGame.GetRomName: string;
begin
  Result := TPath.GetFileName(FPath);
end;

function TGame.GetRomNameWoExt: string;
begin
  Result := TPath.GetFileNameWithoutExtension(FPath);
end;

procedure TGame.Clear;
begin
  FMaps.Clear;
  FID := '';
  FSource := '';

  FPath := '';
  FName := '';
  FDesc := '';
  FRating := '';
  FReleaseDate := '';
  FDeveloper := '';
  FPublisher := '';
  FGenreID := '';
  FGenre := '';
  FPlayers := '';
  FHash := '';
  FMD5 := '';
  FImage := '';
  FBox := '';
  FThumbnail := '';
  FVideo := '';
  FManual := '';
  FFavorite := False;
  FHasFavorite := False;
  FTips := '';
end;

procedure TGame.LoadFromXML(const ANode: IXMLNode);
begin
  Clear;

  if not Assigned(ANode) then
    Exit;

  // Attributes
  FID := XMLReadAttribute(ANode, 'id');
  FSource := XMLReadAttribute(ANode, 'source');

  // Fields
  FPath := XMLReadString(ANode, 'path');
  FName := XMLReadString(ANode, 'name');
  FDesc := XMLReadString(ANode, 'desc');
  FRating := XMLReadString(ANode, 'rating');
  FReleaseDate := XMLReadString(ANode, 'releasedate');
  FDeveloper := XMLReadString(ANode, 'developer');
  FPublisher := XMLReadString(ANode, 'publisher');
  FGenreID := XMLReadString(ANode, 'genreid');
  FGenre := XMLReadString(ANode, 'genre');
  FPlayers := XMLReadString(ANode, 'players');
  FHash := XMLReadString(ANode, 'hash');
  FMD5 := XMLReadString(ANode, 'md5');
  FImage := XMLReadString(ANode, 'image');
  FBox := XMLReadString(ANode, 'box');
  FThumbnail := XMLReadString(ANode, 'thumbnail');
  FVideo := XMLReadString(ANode, 'video');
  FManual := XMLReadString(ANode, 'manual');
  FFavorite := XMLReadBool(ANode, 'favorite');
  FHasFavorite := Assigned(XMLChild(ANode, 'favorite'));
  FTips := XMLReadString(ANode, 'tips');

  var MapsNode := XMLChild(ANode, 'maps');
  if Assigned(MapsNode) then
  begin
    var MapNode := XMLChild(MapsNode, 'map');
    while Assigned(MapNode) do
    begin
      if (MapNode.NodeType <> ntElement) or (MapNode.NodeName <> 'map') then
      begin
        MapNode := MapNode.NextSibling;
        Continue;
      end;

      var Map := TGameMap.Create;
      try
        Map.LoadFromXML(MapNode);
      except
        Map.Free;
        raise;
      end;
      FMaps.Add(Map);

      MapNode := MapNode.NextSibling;
    end;
  end;
end;

function TGame.SaveToXML(const AParent: IXMLNode): IXMLNode;
begin
  Result := AParent.AddChild('game');

  // Attributes
  if FID <> '' then
    XMLAddAttribute(Result, 'id', FID);

  if FSource <> '' then
    XMLAddAttribute(Result, 'source', FSource);

  // Fields
  if FPath <> '' then
    XMLAddElement(Result, 'path', FPath);

  if FName <> '' then
    XMLAddElement(Result, 'name', FName);

  if FDesc <> '' then
    XMLAddElement(Result, 'desc', FDesc);

  if FRating <> '' then
    XMLAddElement(Result, 'rating', FRating);

  if FReleaseDate <> '' then
    XMLAddElement(Result, 'releasedate', FReleaseDate);

  if FDeveloper <> '' then
    XMLAddElement(Result, 'developer', FDeveloper);

  if FPublisher <> '' then
    XMLAddElement(Result, 'publisher', FPublisher);

  if FGenreID <> '' then
    XMLAddElement(Result, 'genreid', FGenreID);

  if FGenre <> '' then
    XMLAddElement(Result, 'genre', FGenre);

  if FPlayers <> '' then
    XMLAddElement(Result, 'players', FPlayers);

  if FHash <> '' then
    XMLAddElement(Result, 'hash', FHash);

  if FMD5 <> '' then
    XMLAddElement(Result, 'md5', FMD5);

  if FImage <> '' then
    XMLAddElement(Result, 'image', FImage);

  if FBox <> '' then
    XMLAddElement(Result, 'box', FBox);

  if FThumbnail <> '' then
    XMLAddElement(Result, 'thumbnail', FThumbnail);

  if FVideo <> '' then
    XMLAddElement(Result, 'video', FVideo);

  if FManual <> '' then
    XMLAddElement(Result, 'manual', FManual);

  if FTips <> '' then
    XMLAddElement(Result, 'tips', FTips);

  if FMaps.Count > 0 then
  begin
    var MapsNode := Result.AddChild('maps');

    for var Map in FMaps do
      Map.SaveToXML(MapsNode);
  end;

  if FHasFavorite then
    XMLAddElement(Result, 'favorite', XMLBoolToString(FFavorite));
end;

{ TGameList }

constructor TGameList.Create;
begin
  inherited Create;

  FProvider := TGameProvider.Create;
  FGames := TObjectList<TGame>.Create(True);
end;

destructor TGameList.Destroy;
begin
  FGames.Free;
  FProvider.Free;

  inherited;
end;

procedure TGameList.Clear;
begin
  FProvider.Clear;
  FGames.Clear;
end;

procedure TGameList.LoadFromXML(const ANode: IXMLNode);
begin
  Clear;

  if not Assigned(ANode) then
    Exit;

  // provider
  var ProviderNode := XMLChild(ANode, 'provider');
  if Assigned(ProviderNode) then
    FProvider.LoadFromXML(ProviderNode);

  // games
  var GamesNode := ANode.ChildNodes.First;
  while Assigned(GamesNode) do
  begin
    if (GamesNode.NodeType <> ntElement) or (GamesNode.NodeName <> 'game') then
    begin
      GamesNode := GamesNode.NextSibling;
      Continue;
    end;

    var Game := TGame.Create;
    try
      Game.LoadFromXML(GamesNode);
    except
      Game.Free;
      raise;
    end;
    FGames.Add(Game);

    GamesNode := GamesNode.NextSibling;
  end;
end;

procedure TGameList.SaveToXML(const ADocument: IXMLDocument);
begin
  if not Assigned(ADocument) then
    raise EArgumentNilException.Create('ADocument');

  ADocument.Active := True;
  ADocument.ChildNodes.Clear;

  ADocument.Encoding := 'utf-8';
  ADocument.StandAlone := 'yes';
  ADocument.Version := '1.0';

  var Root := ADocument.AddChild('gameList');

  FProvider.SaveToXML(Root);

  for var Game in FGames do
    Game.SaveToXML(Root);
end;

procedure TGameList.LoadFromFile(const AFileName: string);
begin
  var Document := TXMLDocument.Create(nil);
  Document.DOMVendor := GetDOMVendor(sOmniXmlVendor);

  var XML: IXMLDocument := Document;
  XML.LoadFromFile(AFileName);

  if not XML.Active then
    raise Exception.CreateFmt('Unable to load XML file: %s', [AFileName]);

  var Root := XML.DocumentElement;

  if not Assigned(Root) then
    raise Exception.Create('XML document has no root element');

  if Root.NodeName <> 'gameList' then
    raise Exception.CreateFmt('Invalid root element "%s", expected "gameList"', [Root.NodeName]);

  LoadFromXML(Root);
end;

procedure TGameList.SaveToFile(const AFileName: string);
begin
  var Document := TXMLDocument.Create(nil);
  Document.DOMVendor := GetDOMVendor(sOmniXmlVendor);

  var XML: IXMLDocument := Document;
  SaveToXML(XML);
  try
    XML.SaveToFile(AFileName);
  except
    on E: Exception do
      raise Exception.CreateFmt('Unable to save XML file: %s' + sLineBreak + '%s', [AFileName, E.Message]);
  end;
end;

{ TGameMap }

procedure TGameMap.LoadFromXML(const ANode: IXMLNode);
begin
  FPath := '';
  FTitle := '';

  if not Assigned(ANode) then
    Exit;

  FPath := XMLReadAttribute(ANode, 'path');
  FTitle := XMLReadAttribute(ANode, 'title');
end;

function TGameMap.SaveToXML(const AParent: IXMLNode): IXMLNode;
begin
  Result := AParent.AddChild('map');

  if FPath <> '' then
    XMLAddAttribute(Result, 'path', FPath);

  if FTitle <> '' then
    XMLAddAttribute(Result, 'title', FTitle);
end;

end.

