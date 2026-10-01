unit RM.Main;

interface

uses
  System.SysUtils, System.Classes, System.Types, System.UITypes, FMX.Forms,
  FMX.Types, FMX.Controls, FMX.Objects, FMX.Graphics, FMX.Dialogs, NES.Consts,
  NES.Controller, Core.Emulation, Core.EmulatorFactory, Core.Adapter.MD,
  WinUI3.Form, WinUI3.Style, FMX.Controls.Presentation, FMX.StdCtrls,
  FMX.Layouts, NES.SuborKeyboard,
  {$IFDEF ANDROID}
  Androidapi.Helpers, Androidapi.JNI.GraphicsContentViewText, Androidapi.JNI.App,
  Androidapi.JNI.Widget, Androidapi.JNI.Os, Androidapi.JNI.Media, FMX.Platform,
  FMX.ApplicationEvents, RM.RomPicker.Android,
  {$ENDIF}
  RM.FolderPicker.Android, RM.Gamepad, FMX.ListBox, SCRP.GameList, FMX.Edit,
  FMX.SearchBox;

type
  TListBoxItemGame = class(TListBoxItem)
  protected
    FLoaded: Boolean;
  public
    RomFile: TRomFile;
    procedure ApplyStyle; override;
  end;

  TFormMain = class(TWinUIForm)
    ImageCanvas: TImage;
    TimerUpdate: TTimer;
    LayoutHead: TLayout;
    LabelStatus: TLabel;
    ImageLogo: TImage;
    RectangleBG: TRectangle;
    LayoutLeft: TLayout;
    LayoutClient: TLayout;
    LabelPaused: TLabel;
    Panel1: TPanel;
    Layout2: TLayout;
    ListBoxGames: TListBox;
    ListBoxItem1: TListBoxItem;
    RadioButtonGB: TRadioButton;
    RadioButtonGBC: TRadioButton;
    RadioButtonNES: TRadioButton;
    RadioButtonMD: TRadioButton;
    ImageNoBox: TImage;
    Layout1: TLayout;
    ButtonOpen: TButton;
    SearchBoxGame: TSearchBox;
    ButtonStop: TButton;
    ButtonPalette: TButton;
    PathLabel1: TPathLabel;
    PathLabel2: TPathLabel;
    PathLabel3: TPathLabel;
    Panel2: TPanel;
    ButtonSetRoot: TButton;
    ButtonCloseRom: TButton;
    procedure FormActivate(Sender: TObject);
    procedure FormResize(Sender: TObject);
    procedure FormDeactivate(Sender: TObject);
    procedure FormKeyUp(Sender: TObject; var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
    procedure FormKeyDown(Sender: TObject; var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
    procedure TimerUpdateTimer(Sender: TObject);
    procedure ButtonOpenClick(Sender: TObject);
    procedure FormSafeAreaChanged(Sender: TObject; const AInsets: TRectF);
    procedure FormCreate(Sender: TObject);
    procedure ChangeSystem(Sender: TObject);
    procedure ListBoxGamesItemClick(const Sender: TCustomListBox; const Item: TListBoxItem);
    procedure LayoutClientClick(Sender: TObject);
    procedure ButtonStopClick(Sender: TObject);
    procedure ButtonPaletteClick(Sender: TObject);
    procedure LayoutClientDblClick(Sender: TObject);
    procedure ButtonSetRootClick(Sender: TObject);
    procedure FormSaveState(Sender: TObject);
    procedure ButtonCloseRomClick(Sender: TObject);
    procedure ImageCanvasMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Single);
    procedure ImageCanvasMouseUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Single);
  private
    FEmulation: IEmulationCore;
    FGamepad: TScreenGamepad;
    FSystemId: string;
    FSuborKeyboard: TNesSuborKeyboard;
    FGamepadInput: TEmulatorInput;
    FSoundErrorShown: Boolean;
    FRomDisplayName: string;
    FOpeningRom: Boolean;
    FEmulationFaulted: Boolean;
    FUserPaused: Boolean;
    FKeysDown: array[0..2048] of Boolean;
    FRomsRoot: string;
    FZapperPixel: TPoint;
    {$IFDEF ANDROID}
    FPicker: TAndroidRomPicker;
    FAppEvents: TApplicationEvents;
    FInBackground, FActivityPaused: Boolean;
    FSuborKeyboardTouchAttached: Boolean;
    function ApplicationStateChanged(Sender: TObject; const AAppEvent: TApplicationEvent; const AContext: TObject): Boolean;
    procedure PollRomPicker;
    {$ENDIF}
    procedure GamepadChanged(Sender: TObject);
    procedure SuborKeyboardChanged(Sender: TObject);
    procedure SetStatus(const Text: string);
    procedure SyncActivity;
    procedure OpenRom;
    procedure StopOnError;
    procedure UpdateFrame;
    procedure SwitchPause;
    procedure LoadSystem(const SystemId: string);
    procedure FillGameItem(Item: TListBoxItem; Game: TGame; const Root: string);
    procedure SwitchFullScreen;
    procedure Load;
    procedure Save;
    procedure MobileCloseRom;
    procedure Stop;
  protected
    procedure DoOnSettingChange; override;
  public
    procedure SaveSnapshot(const Name: string);
    procedure LoadSnapshot(const Name: string);
    procedure LoadRom(const FileName: string; const DisplayName: string = '');
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

  end;

const
  AppName = 'RetroMul';
  ConfigFileName = 'config.ini';

var
  FormMain: TFormMain;

implementation

uses
  System.IOUtils, System.Math, FMX.Ani, System.IniFiles, System.Messaging,
  RM.Styles, Core.Adapter.GB, GB.Palettes, Core.Adapter.NES, Core.SavePaths,
  HGM.FMX.Image;

{$R *.fmx}

function ReadZapperMask(const Mask: TNesZapperMask; const PixelX, PixelY: Integer): Boolean;
begin
  Result := False;
  if (PixelX < Low(Mask)) or (PixelX > High(Mask)) then
    Exit;
  if (PixelY < Low(Mask[PixelX])) or (PixelY > High(Mask[PixelX])) then
    Exit;

  Result := Mask[PixelX, PixelY] <> 0;
end;

function TryGetImagePixel(const Image: TImage; const X, Y: Single; out PixelX, PixelY: Integer): Boolean;
begin
  Result := False;
  PixelX := -1;
  PixelY := -1;

  if (Image.Width <= 0) or (Image.Height <= 0) or (Image.Bitmap.Width <= 0) or (Image.Bitmap.Height <= 0) then
    Exit;

  var Scale := Min(Image.Width / Image.Bitmap.Width, Image.Height / Image.Bitmap.Height);
  var DrawWidth := Image.Bitmap.Width * Scale;
  var DrawHeight := Image.Bitmap.Height * Scale;
  var Left := (Image.Width - DrawWidth) / 2;
  var Top := (Image.Height - DrawHeight) / 2;

  if (X < Left) or (Y < Top) or (X >= Left + DrawWidth) or (Y >= Top + DrawHeight) then
    Exit;

  PixelX := Min(Image.Bitmap.Width - 1, Floor((X - Left) / Scale));
  PixelY := Min(Image.Bitmap.Height - 1, Floor((Y - Top) / Scale));
  Result := True;
end;

function EventKey(Key: Word; KeyChar: WideChar): Word;
begin
  Result := Key;
  if (Result = 0) and (KeyChar <> #0) then
    Result := Ord(UpCase(KeyChar));
end;

{ TFormMain }

procedure TFormMain.ButtonCloseRomClick(Sender: TObject);
begin
  MobileCloseRom;
end;

procedure TFormMain.MobileCloseRom;
begin
  Stop;
  SwitchFullScreen;
end;

procedure TFormMain.ButtonOpenClick(Sender: TObject);
begin
  try
    OpenRom;
  except
    on E: Exception do
      ShowMessage(E.Message);
  end;
end;

procedure TFormMain.ButtonPaletteClick(Sender: TObject);
begin
  if FEmulation = nil then
    Exit;
  var GBEmulatorConfig: IGBEmulatorConfig;
  if Supports(FEmulation.Config, IGBEmulatorConfig, GBEmulatorConfig) then
  begin
    var CP := GBEmulatorConfig.ScreenPalette;
    Inc(CP);
    if CP >= SCREEN_PALETTE_COUNT then
      CP := 0;
    GBEmulatorConfig.ScreenPalette := CP;
    GBEmulatorConfig.Save;
  end;
end;

procedure TFormMain.ButtonSetRootClick(Sender: TObject);
begin
  {$IFDEF ANDROID}
  TRomStorage.SelectFolder(
    procedure(Success: Boolean)
    begin
      FRomsRoot := TRomStorage.FolderUri;
      LoadSystem(FSystemId);
    end);
  Exit;
  {$ENDIF}
  var Dir: string := FRomsRoot;
  if SelectDirectory(Translate('Select ROM folder'), '', Dir) then
    FRomsRoot := Dir
  else
    Exit;

  LoadSystem(FSystemId);
end;

procedure TFormMain.ButtonStopClick(Sender: TObject);
begin
  Stop;
end;

procedure TFormMain.Stop;
begin
  if FEmulation <> nil then
  begin
    TimerUpdate.Enabled := False;
    ImageCanvas.Bitmap := nil;
    ImageLogo.Visible := True;
    FEmulation.Stop;
    FEmulation := nil;
  end;
end;

procedure TFormMain.ChangeSystem(Sender: TObject);
begin
  var SystemId := '';
  if RadioButtonGB.IsChecked then
    SystemId := RadioButtonGB.TagString
  else if RadioButtonGBC.IsChecked then
    SystemId := RadioButtonGBC.TagString
  else if RadioButtonNES.IsChecked then
    SystemId := RadioButtonNES.TagString
  else if RadioButtonMD.IsChecked then
    SystemId := RadioButtonMD.TagString;

  if FSystemId = SystemId then
    Exit;
  LoadSystem(SystemId);
end;

procedure TFormMain.Load;
begin
  try
    if TFile.Exists(TPath.Combine(GetDocumentsDirectory, ConfigFileName)) then
    begin
      var Ini := TIniFile.Create(TPath.Combine(GetDocumentsDirectory, ConfigFileName));
      try
        FRomsRoot := Trim(Ini.ReadString('General', 'Path', FRomsRoot));
      finally
        Ini.Free;
      end;
    end
    else
      Save;
  except
    // silent
  end;
end;

procedure TFormMain.Save;
begin
  try
    TDirectory.CreateDirectory(GetDocumentsDirectory);
    var Ini := TIniFile.Create(TPath.Combine(GetDocumentsDirectory, ConfigFileName));
    try
      Ini.WriteString('General', 'Path', FRomsRoot);
    finally
      Ini.Free;
    end;
  except
    //silent
  end;
end;

procedure TFormMain.LoadSystem(const SystemId: string);
begin
  FSystemId := SystemId;
  // FMX controls and their styles belong to the main thread. Keeping this
  // operation scoped to the call also prevents work outliving the form.
  LayoutLeft.Enabled := False;
  ListBoxGames.Visible := False;
  ListBoxGames.BeginUpdate;
  try
    ListBoxGames.Clear;
    try
      {$IFDEF ANDROID}
      TRomStorage.FolderUri := FRomsRoot;
      // XML metadata is not supported by the SAF reader yet. Its presence
      // must not suppress the ROM scan.
      ListBoxGames.DefaultItemStyles.ItemStyle := 'listboxitemstyle';
      ListBoxGames.ItemHeight := 32;
      var Games := TRomStorage.GetFiles(['gb', 'gbc', 'nes', 'gen', 'md', 'smd', 'bin'], True);
      for var GameFile in Games do
        if GameFile.RelativePath.StartsWith(SystemId + '/') or
          GameFile.RelativePath.StartsWith(SystemId + '\') then
        begin
          var Game := TGame.Create;
          try
            Game.Path := GameFile.Uri;
            Game.Name := TPath.GetFileNameWithoutExtension(GameFile.Name);
            var Item := TListBoxItemGame.Create(ListBoxGames);
            Item.RomFile := GameFile;
            ListBoxGames.AddObject(Item);
            FillGameItem(Item, Game, '');
          finally
            Game.Free;
          end;
        end;
      {$ELSE}
      var Folder := TPath.Combine(FRomsRoot, SystemId);
      if not TDirectory.Exists(Folder) then
        Exit;
      var GameListXML := TPath.Combine(Folder, 'gamelist.xml');
      if TFile.Exists(GameListXML) then
      begin
        ListBoxGames.DefaultItemStyles.ItemStyle := 'listboxitemstyle_game';
        ListBoxGames.ItemHeight := 70;
        var GameList := TGameList.Create;
        try
          GameList.LoadFromFile(GameListXML);
          for var Game in GameList.Games do
          begin
            var Item := TListBoxItemGame.Create(ListBoxGames);
            ListBoxGames.AddObject(Item);
            FillGameItem(Item, Game, Folder);
          end;
        finally
          GameList.Free;
        end;
      end
      else
      begin
        ListBoxGames.DefaultItemStyles.ItemStyle := 'listboxitemstyle';
        ListBoxGames.ItemHeight := 32;
        for var GameFile in TDirectory.GetFiles(Folder) do
        begin
          var Ext := TPath.GetExtension(GameFile).ToLower;
          if (Ext <> '.nes') and (Ext <> '.gb') and (Ext <> '.gbc') and
            (Ext <> '.smd') and (Ext <> '.bin') and (Ext <> '.md') and (Ext <> '.gen') then
            Continue;
          var Game := TGame.Create;
          try
            Game.Path := GameFile;
            Game.Name := TPath.GetFileNameWithoutExtension(GameFile);
            var Item := TListBoxItemGame.Create(ListBoxGames);
            ListBoxGames.AddObject(Item);
            FillGameItem(Item, Game, Folder);
          finally
            Game.Free;
          end;
        end;
      end;
      {$ENDIF}
    except
      on E: Exception do
      begin
        ListBoxGames.Clear;
        SetStatus('Cannot load game list: ' + E.Message);
      end;
    end;
  finally
    ListBoxGames.EndUpdate;
    LayoutLeft.Enabled := True;
    ButtonSetRoot.Visible := ListBoxGames.Count <= 0;
    ListBoxGames.Visible := True;
    ListBoxGames.Opacity := 0;
    TAnimator.AnimateFloat(ListBoxGames, 'Opacity', 1);
  end;
end;

procedure TFormMain.FillGameItem(Item: TListBoxItem; Game: TGame; const Root: string);
begin
  var GameName: string := '';
  GameName := Game.Name;

  if Item.ItemData.Bitmap.IsEmpty then
    Item.ItemData.Bitmap := ImageNoBox.Bitmap;

  Item.ItemData.Detail := Game.Genre;
  Item.StylesData['info'] := Game.Developer;
  Item.StylesData['rating'] := Game.Rating;
  Item.StylesData['warn.Visible'] := False;
  Item.StylesData['favorite.Visible'] := Game.Favorite;
  Item.StylesData['box'] := Game.GetPhysicalPath(Root, Game.Box);
  Item.Text := GameName;
  Item.TagString := Game.GetPhysicalPath(Root, Game.Path);
end;

constructor TFormMain.Create(AOwner: TComponent);
begin
  FormStyles := TFormStyles.Create(Application);
  inherited;
  LayoutClient.CanFocus := True;
  LayoutClient.OnKeyDown := FormKeyDown;
  LayoutClient.OnKeyUp := FormKeyUp;
  LayoutClient.DisableFocusEffect := False;
  LayoutClient.CanParentFocus := True;
  SetStatus('Open ROM');
  {$IFDEF ANDROID}
  // Hardware volume keys control game audio, including before a ROM is loaded.
  TAndroidHelper.Activity.setVolumeControlStream(TJAudioManager.JavaClass.STREAM_MUSIC);
  FPicker := TAndroidRomPicker.Create;
  FAppEvents := TApplicationEvents.Create(Self);
  FAppEvents.OnStateChanged := ApplicationStateChanged;
  LayoutClient.Visible := False;
  LayoutLeft.Align := TAlignLayout.Client;
  {$ENDIF}
  Fill.Color := TAlphaColors.Black;
  ImageCanvas.WrapMode := TImageWrapMode.Fit;
  ImageCanvas.DisableInterpolation := True;
  ImageCanvas.Bitmap.SetSize(NES_WIDTH, NES_HEIGHT);
  ImageCanvas.Bitmap.Clear(TAlphaColors.Black);
  FGamepad := TScreenGamepad.Create(Self);
  FGamepad.Name := 'ScreenGamepad';
  FGamepad.Parent := LayoutClient;
  FGamepad.Align := TAlignLayout.Bottom;
  FGamepad.OnChange := GamepadChanged;
  FGamepad.Enabled := False;
  FGamepad.Visible := False;
  FSuborKeyboard := TNesSuborKeyboard.Create(Self);
  FSuborKeyboard.Name := 'ScreenSuborKeyboard';
  FSuborKeyboard.Parent := LayoutClient;
  FSuborKeyboard.Align := TAlignLayout.Bottom;
  FSuborKeyboard.OnChange := SuborKeyboardChanged;
  FSuborKeyboard.Enabled := False;
  FSuborKeyboard.Visible := False;
  FormResize(Self);
  TimerUpdate.Interval := 8;
  ListBoxGames.Clear;
  Load;
  LoadSystem('gb');
end;

destructor TFormMain.Destroy;
begin
  if TimerUpdate <> nil then
    TimerUpdate.Enabled := False;
  FreeAndNil(FSuborKeyboard);
  FreeAndNil(FGamepad); // Detach the native listener before destroying the form.
  {$IFDEF ANDROID}
  FreeAndNil(FAppEvents);
  FreeAndNil(FPicker);
  {$ENDIF}
  if FEmulation <> nil then
  try
    FEmulation.Stop;
  except
    Application.HandleException(Self);
  end;
  FEmulation := nil;
  inherited;
end;

procedure TFormMain.FormActivate(Sender: TObject);
begin
  {$IFDEF ANDROID}
  if FSuborKeyboardTouchAttached then
    FSuborKeyboard.AttachToForm(Self)
  else if FGamepad <> nil then
    FGamepad.AttachToForm(Self);
  {$ENDIF}
  SyncActivity;
end;

procedure TFormMain.FormCreate(Sender: TObject);
begin
  RadioButtonGB.TagString := 'gb';
  RadioButtonGB.StylesData['path.Data.Data'] := 'M17,2 L7,2 C6.00543832778931,2 5.05161094665527,2.39508819580078 4.34834957122803,3.09834957122803 C3.6450879573822,3.80161118507385 3.25,4.75543832778931 3.25,5.75000047683716 L3.25,18.25 C3.25,19.2445621490479 ' +
    '3.6450879573822,20.1983871459961 4.34834957122803,20.9016494750977 C5.05161094665527,21.6049098968506 6.00543832778931,22 7,22 L17,22 C19.0687866210938,21.9945049285889 20.7445049285889,20.3187866210938 ' +
    '20.75,18.25 L20.75,5.75 C20.7445125579834,3.681227684021 19.0688018798828,2.00550317764282 17.0000152587891,2 M10.2500152587891,16.6000003814697 L9.25001525878906,16.6000003814697 L9.25001525878906,17.6000003814697 ' +
    'C9.25001525878906,17.8679504394531 9.10706615447998,18.1155452728271 8.87501525878906,18.2495193481445 C8.64296436309814,18.3834934234619 8.35706615447998,18.3834934234619 8.12501525878906,18.2495193481445 ' +
    'C7.89296436309814,18.1155452728271 7.75001525878906,17.8679504394531 7.75001525878906,17.6000003814697 L7.75001525878906,16.6000003814697 L6.75001525878906,16.6000003814697 C6.48206615447998,16.6000003814697 ' +
    '6.2344708442688,16.4570503234863 6.10049629211426,16.2250003814697 C5.96652173995972,15.9929494857788 5.96652173995972,15.7070512771606 6.10049629211426,15.4750003814697 C6.2344708442688,15.2429494857788 ' +
    '6.48206615447998,15.1000003814697 6.75001525878906,15.1000003814697 L7.75001525878906,15.1000003814697 L7.75001525878906,14.1000003814697 C7.75001525878906,13.8320512771606 7.89296436309814,13.5844564437866 ' +
    '8.12501525878906,13.4504814147949 C8.35706615447998,13.3165073394775 8.64296436309814,13.3165073394775 8.87501525878906,13.4504814147949 C9.10706615447998,13.5844564437866 9.25001525878906,13.8320512771606 ' +
    '9.25001525878906,14.1000003814697 L9.25001525878906,15.1000003814697 L10.2500152587891,15.1000003814697 C10.5179643630981,15.1000003814697 10.7655591964722,15.2429494857788 10.8995342254639,15.4750003814697 ' +
    'C11.0335092544556,15.7070512771606 11.0335092544556,15.9929494857788 10.8995342254639,16.2250003814697 C10.7655591964722,16.4570503234863 10.5179643630981,16.6000003814697 10.2500152587891,16.6000003814697 ' +
    'M14,19.75 L12,19.75 C11.7320508956909,19.75 11.4844560623169,19.6070499420166 11.3504810333252,19.375 C11.2165060043335,19.1429500579834 11.2165060043335,18.8570499420166 11.3504810333252,18.625 C11.4844560623169,' +
    '18.3929500579834 11.7320508956909,18.25 12,18.25 L14,18.25 C14.2679491043091,18.25 14.5155439376831,18.3929500579834 14.6495189666748,18.625 C14.7834939956665,18.8570499420166 14.7834939956665,19.1429500579834 ' +
    '14.6495189666748,19.375 C14.5155439376831,19.6070499420166 14.2679491043091,19.75 14,19.75 M15.8800001144409,16.5 C15.8800001144409,16.7679500579834 15.7370510101318,17.0155448913574 15.5050001144409,17.1495189666748 ' +
    'C15.27294921875,17.2834930419922 14.9870510101318,17.2834930419922 14.7550001144409,17.1495189666748 C14.52294921875,17.0155448913574 14.3800001144409,16.7679500579834 14.3800001144409,16.5 L14.3800001144409,' +
    '16.1000003814697 C14.3800001144409,15.8320512771606 14.52294921875,15.5844564437866 14.7550001144409,15.4504814147949 C14.9870510101318,15.3165073394775 15.27294921875,15.3165073394775 15.5050001144409,' +
    '15.4504814147949 C15.7370510101318,15.5844564437866 15.8800001144409,15.8320512771606 15.8800001144409,16.1000003814697 Z M17.6499996185303,14.5 C17.6499996185303,14.7679491043091 17.5070495605469,15.0155439376831 ' +
    '17.2749996185303,15.1495189666748 C17.0429496765137,15.2834939956665 16.7570495605469,15.2834939956665 16.5249996185303,15.1495189666748 C16.2929496765137,15.0155439376831 16.1499996185303,14.7679491043091 ' +
    '16.1499996185303,14.5 L16.1499996185303,14.1000003814697 C16.1499996185303,13.8320512771606 16.2929496765137,13.5844564437866 16.5249996185303,13.4504814147949 C16.7570495605469,13.3165073394775 17.0429496765137,' +
    '13.3165073394775 17.2749996185303,13.4504814147949 C17.5070495605469,13.5844564437866 17.6499996185303,13.8320512771606 17.6499996185303,14.1000003814697 Z M18.25,10.0300006866455 C18.201473236084,10.9517374038696 ' +
    '17.4223861694336,11.6640472412109 16.5,11.6300010681152 L7.5,11.6300010681152 C6.57559823989868,11.6695623397827 5.793212890625,10.9542379379272 5.75,10.0299997329712 L5.75,5.73999977111816 C5.76818323135376,' +
    '5.29430103302002 5.96287298202515,4.87413167953491 6.2911491394043,4.57211780548096 C6.61942529678345,4.270103931427 7.05433464050293,4.11104297637939 7.50000047683716,4.13000011444092 L16.5,4.13000011444092 ' +
    'C17.4260921478271,4.09608936309814 18.2067527770996,4.81429624557495 18.25,5.73999977111816 Z ';
  RadioButtonGBC.TagString := 'gbc';
  RadioButtonGBC.StylesData['path.Data.Data'] := 'M17,2 L7,2 C6.00543832778931,2 5.05161094665527,2.39508819580078 4.34834957122803,3.09834957122803 C3.6450879573822,3.80161118507385 3.25,4.75543832778931 3.25,5.75000047683716 L3.25,18.25 C3.25,19.2445621490479 ' +
    '3.6450879573822,20.1983871459961 4.34834957122803,20.9016494750977 C5.05161094665527,21.6049098968506 6.00543832778931,22 7,22 L17,22 C19.0687866210938,21.9945049285889 20.7445049285889,20.3187866210938 ' +
    '20.75,18.25 L20.75,5.75 C20.7445125579834,3.681227684021 19.0688018798828,2.00550317764282 17.0000152587891,2 M10.2500152587891,16.6000003814697 L9.25001525878906,16.6000003814697 L9.25001525878906,17.6000003814697 ' +
    'C9.25001525878906,17.8679504394531 9.10706615447998,18.1155452728271 8.87501525878906,18.2495193481445 C8.64296436309814,18.3834934234619 8.35706615447998,18.3834934234619 8.12501525878906,18.2495193481445 ' +
    'C7.89296436309814,18.1155452728271 7.75001525878906,17.8679504394531 7.75001525878906,17.6000003814697 L7.75001525878906,16.6000003814697 L6.75001525878906,16.6000003814697 C6.48206615447998,16.6000003814697 ' +
    '6.2344708442688,16.4570503234863 6.10049629211426,16.2250003814697 C5.96652173995972,15.9929494857788 5.96652173995972,15.7070512771606 6.10049629211426,15.4750003814697 C6.2344708442688,15.2429494857788 ' +
    '6.48206615447998,15.1000003814697 6.75001525878906,15.1000003814697 L7.75001525878906,15.1000003814697 L7.75001525878906,14.1000003814697 C7.75001525878906,13.8320512771606 7.89296436309814,13.5844564437866 ' +
    '8.12501525878906,13.4504814147949 C8.35706615447998,13.3165073394775 8.64296436309814,13.3165073394775 8.87501525878906,13.4504814147949 C9.10706615447998,13.5844564437866 9.25001525878906,13.8320512771606 ' +
    '9.25001525878906,14.1000003814697 L9.25001525878906,15.1000003814697 L10.2500152587891,15.1000003814697 C10.5179643630981,15.1000003814697 10.7655591964722,15.2429494857788 10.8995342254639,15.4750003814697 ' +
    'C11.0335092544556,15.7070512771606 11.0335092544556,15.9929494857788 10.8995342254639,16.2250003814697 C10.7655591964722,16.4570503234863 10.5179643630981,16.6000003814697 10.2500152587891,16.6000003814697 ' +
    'M14,19.75 L12,19.75 C11.7320508956909,19.75 11.4844560623169,19.6070499420166 11.3504810333252,19.375 C11.2165060043335,19.1429500579834 11.2165060043335,18.8570499420166 11.3504810333252,18.625 C11.4844560623169,' +
    '18.3929500579834 11.7320508956909,18.25 12,18.25 L14,18.25 C14.2679491043091,18.25 14.5155439376831,18.3929500579834 14.6495189666748,18.625 C14.7834939956665,18.8570499420166 14.7834939956665,19.1429500579834 ' +
    '14.6495189666748,19.375 C14.5155439376831,19.6070499420166 14.2679491043091,19.75 14,19.75 M15.8800001144409,16.5 C15.8800001144409,16.7679500579834 15.7370510101318,17.0155448913574 15.5050001144409,17.1495189666748 ' +
    'C15.27294921875,17.2834930419922 14.9870510101318,17.2834930419922 14.7550001144409,17.1495189666748 C14.52294921875,17.0155448913574 14.3800001144409,16.7679500579834 14.3800001144409,16.5 L14.3800001144409,' +
    '16.1000003814697 C14.3800001144409,15.8320512771606 14.52294921875,15.5844564437866 14.7550001144409,15.4504814147949 C14.9870510101318,15.3165073394775 15.27294921875,15.3165073394775 15.5050001144409,' +
    '15.4504814147949 C15.7370510101318,15.5844564437866 15.8800001144409,15.8320512771606 15.8800001144409,16.1000003814697 Z M17.6499996185303,14.5 C17.6499996185303,14.7679491043091 17.5070495605469,15.0155439376831 ' +
    '17.2749996185303,15.1495189666748 C17.0429496765137,15.2834939956665 16.7570495605469,15.2834939956665 16.5249996185303,15.1495189666748 C16.2929496765137,15.0155439376831 16.1499996185303,14.7679491043091 ' +
    '16.1499996185303,14.5 L16.1499996185303,14.1000003814697 C16.1499996185303,13.8320512771606 16.2929496765137,13.5844564437866 16.5249996185303,13.4504814147949 C16.7570495605469,13.3165073394775 17.0429496765137,' +
    '13.3165073394775 17.2749996185303,13.4504814147949 C17.5070495605469,13.5844564437866 17.6499996185303,13.8320512771606 17.6499996185303,14.1000003814697 Z M18.25,10.0300006866455 C18.201473236084,10.9517374038696 ' +
    '17.4223861694336,11.6640472412109 16.5,11.6300010681152 L7.5,11.6300010681152 C6.57559823989868,11.6695623397827 5.793212890625,10.9542379379272 5.75,10.0299997329712 L5.75,5.73999977111816 C5.76818323135376,' +
    '5.29430103302002 5.96287298202515,4.87413167953491 6.2911491394043,4.57211780548096 C6.61942529678345,4.270103931427 7.05433464050293,4.11104297637939 7.50000047683716,4.13000011444092 L16.5,4.13000011444092 ' +
    'C17.4260921478271,4.09608936309814 18.2067527770996,4.81429624557495 18.25,5.73999977111816 Z ';
  RadioButtonNES.TagString := 'nes';
  RadioButtonNES.StylesData['path.Data.Data'] := 'M21,6 L3,6 C2.46956706047058,6 1.96085917949677,6.21071338653564 1.58578646183014,6.58578634262085 C1.21071362495422,6.96085929870605 0.999999940395355,7.469566822052 1,8 L1,16 C0.999999940395355,16.5304336547852 ' +
    '1.21071362495422,17.0391407012939 1.58578646183014,17.414213180542 C1.96085917949677,17.78928565979 2.46956706047058,18 3,18 L21,18 C21.5304336547852,18 22.0391407012939,17.78928565979 22.414213180542,' +
    '17.414213180542 C22.78928565979,17.0391407012939 23,16.5304336547852 23,16 L23,8 C23,7.469566822052 22.78928565979,6.96085929870605 22.414213180542,6.58578634262085 C22.0391407012939,6.21071338653564 21.5304336547852,' +
    '6 21,6 M11,13 L8,13 L8,16 L6,16 L6,13 L3,13 L3,11 L6,11 L6,8 L8,8 L8,11 L11,11 M15.5,15 C15.1021757125854,15 14.7206439971924,14.8419647216797 14.4393396377563,14.5606603622437 C14.1580352783203,14.2793560028076 ' +
    '14,13.8978252410889 14,13.5 C14,13.1021747589111 14.1580352783203,12.7206439971924 14.4393396377563,12.4393396377563 C14.7206439971924,12.1580352783203 15.1021757125854,12 15.5,12 C15.8978242874146,12 ' +
    '16.279354095459,12.1580352783203 16.5606594085693,12.4393396377563 C16.8419647216797,12.7206439971924 17,13.1021757125854 17,13.5 C17,13.8978242874146 16.8419647216797,14.2793560028076 16.5606594085693,' +
    '14.5606603622437 C16.279354095459,14.8419647216797 15.8978242874146,15 15.5,15 M19.5,12 C19.1021747589111,12 18.720645904541,11.8419647216797 18.4393405914307,11.5606603622437 C18.1580352783203,11.2793560028076 ' +
    '18,10.8978252410889 18,10.5 C18,10.1021747589111 18.1580352783203,9.72064399719238 18.4393405914307,9.43933963775635 C18.720645904541,9.15803527832031 19.1021747589111,9 19.5,9 C19.8978252410889,9 20.279354095459,' +
    '9.15803527832031 20.5606594085693,9.43933963775635 C20.8419647216797,9.72064399719238 21,10.1021757125854 21,10.5 C21,10.8978242874146 20.8419647216797,11.2793560028076 20.5606594085693,11.5606603622437 ' +
    'C20.279354095459,11.8419647216797 19.8978252410889,12 19.5,12 ';
  RadioButtonMD.TagString := 'megadrive';
  RadioButtonMD.StylesData['path.Data.Data'] := 'M7,6 L17,6 C18.5912990570068,6 20.1174240112305,6.63214111328125 21.2426414489746,7.75735950469971 C22.3678588867188,8.88257789611816 23,10.4087009429932 23,12 C23,13.5912990570068 22.3678588867188,15.1174230575562 ' +
    '21.2426414489746,16.2426414489746 C20.1174240112305,17.3678588867188 18.5912990570068,18 17,18 C15.2200002670288,18 13.6300001144409,17.2299995422363 12.5300006866455,16 L11.4700012207031,16 C10.3700008392334,' +
    '17.2299995422363 8.78000068664551,18 7.00000143051147,18 C5.40870189666748,18 3.88257908821106,17.3678588867188 2.75736093521118,16.2426414489746 C1.63214254379272,15.1174230575562 1.00000131130219,13.5912981033325 ' +
    '1.00000143051147,11.9999990463257 C1.00000154972076,10.4086990356445 1.6321427822113,8.88257598876953 2.75736141204834,7.75735759735107 C3.88257956504822,6.63213968276978 5.4087028503418,5.99999904632568 ' +
    '7.00000143051147,5.99999904632568 M6,9 L6,11 L4,11 L4,13 L6,13 L6,15 L8,15 L8,13 L10,13 L10,11 L8,11 L8,9 Z M15.5,12 C15.1021757125854,12 14.7206439971924,12.1580352783203 14.4393396377563,12.4393396377563 ' +
    'C14.1580352783203,12.7206439971924 14,13.1021747589111 14,13.5 C14,13.8978252410889 14.1580352783203,14.2793560028076 14.4393396377563,14.5606603622437 C14.7206439971924,14.8419647216797 15.1021757125854,' +
    '15 15.5,15 C15.8978242874146,15 16.279354095459,14.8419647216797 16.5606594085693,14.5606603622437 C16.8419647216797,14.2793560028076 17,13.8978242874146 17,13.5 C17,13.1021757125854 16.8419647216797,12.7206439971924 ' +
    '16.5606594085693,12.4393396377563 C16.279354095459,12.1580352783203 15.8978242874146,12 15.5,12 M18.5,9 C18.1021747589111,9 17.720645904541,9.15803527832031 17.4393405914307,9.43933963775635 C17.1580352783203,' +
    '9.72064399719238 17,10.1021747589111 17,10.5 C17,10.8978252410889 17.1580352783203,11.2793560028076 17.4393405914307,11.5606603622437 C17.720645904541,11.8419647216797 18.1021747589111,12 18.5,12 C18.8978252410889,' +
    '12 19.279354095459,11.8419647216797 19.5606594085693,11.5606603622437 C19.8419647216797,11.2793560028076 20,10.8978242874146 20,10.5 C20,10.1021757125854 19.8419647216797,9.72064399719238 19.5606594085693,' +
    '9.43933963775635 C19.279354095459,9.15803527832031 18.8978252410889,9 18.5,9 ';
end;

procedure TFormMain.FormResize(Sender: TObject);
begin
  if FGamepad <> nil then
  begin
    FGamepad.Height := TScreenGamepad.PreferredHeight(
      ClientWidth - Padding.Left - Padding.Right,
      ClientHeight - Padding.Top - Padding.Bottom - LayoutHead.Height);
  end;
  if FSuborKeyboard <> nil then
  begin
    FSuborKeyboard.Height := TNesSuborKeyboard.PreferredHeight(
      ClientWidth - Padding.Left - Padding.Right,
      ClientHeight - Padding.Top - Padding.Bottom - LayoutHead.Height);
  end;
end;

procedure TFormMain.GamepadChanged(Sender: TObject);
begin
  FGamepadInput.Buttons := FGamepad.Buttons;
  if FEmulation <> nil then
    FEmulation.SetGamepadInput(FGamepadInput);
end;

procedure TFormMain.ImageCanvasMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Single);
begin
  var Peripheral: INesPeripheralCore;
  if Supports(FEmulation, INesPeripheralCore, Peripheral) then
  begin
    TryGetImagePixel(ImageCanvas, X, Y, FZapperPixel.X, FZapperPixel.Y);
    Peripheral.Zapper.TriggerPressed := True;
  end;
end;

procedure TFormMain.ImageCanvasMouseUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Single);
begin
  var Peripheral: INesPeripheralCore;
  if Supports(FEmulation, INesPeripheralCore, Peripheral) then
  begin
    Peripheral.Zapper.TriggerPressed := False;
  end;
end;

procedure TFormMain.SuborKeyboardChanged(Sender: TObject);
begin
  var Peripheral: INesPeripheralCore;
  if Supports(FEmulation, INesPeripheralCore, Peripheral) then
    Peripheral.SetSuborKeys(FSuborKeyboard.Keys);
end;

procedure TFormMain.SetStatus(const Text: string);
begin
  Caption := AppName + ' - ' + Text;
  {$IFDEF ANDROID}
  LabelStatus.Text := Caption;
  {$ELSE}
  LayoutHead.Visible := False;
  {$ENDIF}
end;

procedure TFormMain.SyncActivity;
begin
  var SuborKeyboardActive := (FEmulation <> nil) and FEmulation.UsesSuborKeyboard;
  if FGamepad <> nil then
  begin
    {$IFDEF ANDROID}
    FGamepad.Visible := not SuborKeyboardActive;
    FGamepad.Enabled := (FEmulation <> nil) and not FEmulationFaulted and not FOpeningRom and not SuborKeyboardActive;
    {$ENDIF}
  end;
  if FSuborKeyboard <> nil then
  begin
    FSuborKeyboard.Visible := SuborKeyboardActive;
    FSuborKeyboard.Enabled := SuborKeyboardActive and not FEmulationFaulted and not FOpeningRom;
  end;

  {$IFDEF ANDROID}
  // The Android view accepts one native touch listener.
  // The controls are mutually exclusive, so hand it to the currently visible control.
  if FSuborKeyboardTouchAttached <> SuborKeyboardActive then
  begin
    if FSuborKeyboardTouchAttached then
      FSuborKeyboard.AttachToForm(nil)
    else
      FGamepad.AttachToForm(nil);
    if SuborKeyboardActive then
      FSuborKeyboard.AttachToForm(Self)
    else
      FGamepad.AttachToForm(Self);
    FSuborKeyboardTouchAttached := SuborKeyboardActive;
  end;
  var Paused := FInBackground or FOpeningRom or FUserPaused;
  if FGamepad <> nil then
    FGamepad.Enabled := FGamepad.Enabled and not FInBackground;
  if FSuborKeyboard <> nil then
    FSuborKeyboard.Enabled := FSuborKeyboard.Enabled and not FInBackground;
  if Paused <> FActivityPaused then
  begin
    FActivityPaused := Paused;
    if FEmulation <> nil then
      if Paused then
      begin
        FormDeactivate(Self);
        FEmulation.Pause;
      end
      else if not FEmulationFaulted then
        FEmulation.Resume;
  end;
  TimerUpdate.Enabled := not FInBackground and (FOpeningRom or ((FEmulation <> nil) and not FEmulationFaulted));
  {$ELSE}
  TimerUpdate.Enabled := (FEmulation <> nil) and not FEmulationFaulted;
  {$ENDIF}
end;

{$IFDEF ANDROID}
function TFormMain.ApplicationStateChanged(Sender: TObject; const AAppEvent: TApplicationEvent; const AContext: TObject): Boolean;
begin
  case AAppEvent of
    TApplicationEvent.WillBecomeInactive, TApplicationEvent.EnteredBackground:
      FInBackground := True;
    TApplicationEvent.BecameActive:
      FInBackground := False;
  else
    Exit(False);
  end;
  SyncActivity;
  Result := False;
end;

procedure TFormMain.PollRomPicker;
begin
  if not FOpeningRom then
    Exit;
  var FileName, DisplayName, Error: string;
  if not FPicker.Poll(FileName, DisplayName, Error) then
    Exit;
  try
    try
      if Error <> '' then
        raise Exception.Create(Error);
      if FileName <> '' then
        LoadRom(FileName, DisplayName);
    except
      on E: Exception do
        ShowMessage(E.Message);
    end;
  finally
    FPicker.Finish;
    FOpeningRom := False;
    ButtonOpen.Enabled := True;
    SyncActivity;
  end;
end;
{$ENDIF}

procedure TFormMain.FormDeactivate(Sender: TObject);
begin
  // Release keys whose key-up may be lost. Android lifecycle controls pausing.
  FillChar(FKeysDown, SizeOf(FKeysDown), 0);
  if FGamepad <> nil then
    FGamepad.ReleaseAll;
  if FSuborKeyboard <> nil then
    FSuborKeyboard.ReleaseAll;
  if FEmulation <> nil then
    FEmulation.ClearInput;
  FGamepadInput := Default(TEmulatorInput);
end;

procedure TFormMain.SaveSnapshot(const Name: string);
begin
  if FEmulation = nil then
    raise Exception.Create('No game loaded');
  if not FEmulation.SupportsSnapshots then
    raise ENotSupportedException.Create('Snapshots are not implemented by this core');
  FEmulation.SaveSnapshot(Name);
end;

procedure TFormMain.LoadSnapshot(const Name: string);
begin
  if FEmulation = nil then
    raise Exception.Create('No game loaded');
  if not FEmulation.SupportsSnapshots then
    raise ENotSupportedException.Create('Snapshots are not implemented by this core');
  FEmulation.LoadSnapshot(Name);
  FEmulationFaulted := False;
  SyncActivity;
  UpdateFrame;
end;

procedure TFormMain.SwitchFullScreen;
begin
  FullScreen := not FullScreen;
  LayoutLeft.Visible := not FullScreen;
  {$IFDEF ANDROID}
  LayoutClient.Visible := FullScreen;
  {$ENDIF}
  if FullScreen then
  begin
    LayoutClient.Cursor := crNone;
    LayoutClient.SetFocus;
  end
  else
    LayoutClient.Cursor := crDefault;
end;

procedure TFormMain.FormKeyDown(Sender: TObject; var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
begin
  if Key in [vkVolumeUp, vkVolumeDown, vkVolumeMute] then
    Exit;
  var Code: Word := EventKey(Key, KeyChar);
  var SuborKeyboardActive := (FEmulation <> nil) and FEmulation.UsesSuborKeyboard;
  var WasDown: Boolean := False;
  if Code <= High(FKeysDown) then
  begin
    WasDown := FKeysDown[Code];
    FKeysDown[Code] := True;
  end;
  if not WasDown then
  begin
    if (Code = vkEscape) and not SuborKeyboardActive then
    begin
      if FullScreen then
        SwitchFullScreen
    end
    else if (Code = vkF11) then
      SwitchFullScreen
    else if (Code = vkO) and (ssCtrl in Shift) then
      OpenRom
    else if (Code = vkR) and (FEmulation <> nil) and not SuborKeyboardActive then
    begin
      TimerUpdate.Enabled := False;
      try
        FEmulation.Reset;
        FUserPaused := False;
        FEmulationFaulted := False;
        {$IFDEF ANDROID}
        if FActivityPaused then
          FEmulation.Pause;
        {$ENDIF}
        SyncActivity;
        SetStatus(FRomDisplayName);
      except
        StopOnError;
        raise;
      end;
    end
    else if (Code = vkP) and not SuborKeyboardActive then
      SwitchPause
    else if (Code in [vkF5, vkF6]) and (FEmulation <> nil) and not SuborKeyboardActive then
    begin
      try
        if Code = vkF5 then
          SaveSnapshot('quick')
        else
          LoadSnapshot('quick');
      except
        on E: Exception do
          ShowMessage('Snapshot: ' + E.Message);
      end;
    end;
  end;
  if SuborKeyboardActive or not (ssCtrl in Shift) then
    if FEmulation <> nil then
      FEmulation.SetKeyState(Code, True);
  Key := 0;
  KeyChar := #0;
end;

procedure TFormMain.FormKeyUp(Sender: TObject; var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
begin
  if Key in [vkVolumeUp, vkVolumeDown, vkVolumeMute] then
    Exit;
  var Code: Word := EventKey(Key, KeyChar);
  if Code <= High(FKeysDown) then
    FKeysDown[Code] := False;
  if FEmulation <> nil then
    FEmulation.SetKeyState(Code, False);
  Key := 0;
  KeyChar := #0;
end;

procedure TFormMain.SwitchPause;
begin
  if (FEmulation = nil) or FEmulationFaulted then
    Exit;

  FUserPaused := not FUserPaused;
  if FUserPaused then
  begin
    FormDeactivate(Self);
    FEmulation.Pause;
  end
  else
  begin
    {$IFNDEF ANDROID}
    FEmulation.Resume;
    {$ENDIF}
  end;
  SyncActivity;
  // SyncActivity can release input again when Android changes pause state.
  FKeysDown[vkP] := True;
end;

procedure TFormMain.FormSafeAreaChanged(Sender: TObject; const AInsets: TRectF);
begin
  Padding.Left := AInsets.Left;
  Padding.Top := AInsets.Top;
  Padding.Right := AInsets.Right;
  Padding.Bottom := AInsets.Bottom;
  FormResize(Self);
end;

procedure TFormMain.FormSaveState(Sender: TObject);
begin
  try
    Save;
  except
    //
  end;
end;

procedure TFormMain.TimerUpdateTimer(Sender: TObject);
begin
  {$IFDEF ANDROID}
  PollRomPicker;
  if FOpeningRom then
    Exit;
  {$ENDIF}
  if FEmulationFaulted or not TimerUpdate.Enabled or (FEmulation = nil) then
    Exit;
  if FEmulation.IsPaused then
  begin
    ImageCanvas.Opacity := 0.5;
    LabelPaused.Visible := True;
  end
  else
  begin
    ImageCanvas.Opacity := 1;
    LabelPaused.Visible := False;
  end;
  try
    UpdateFrame;
  except
    StopOnError;
    raise;
  end;
end;

procedure TFormMain.StopOnError;
begin
  FEmulationFaulted := True;
  TimerUpdate.Enabled := False;
  if FEmulation <> nil then
    FEmulation.Pause;
  FormDeactivate(Self);
  SetStatus('Stopped after error - ' + FRomDisplayName);
  SyncActivity;
end;

procedure TFormMain.LayoutClientClick(Sender: TObject);
begin
  LayoutClient.SetFocus;
end;

procedure TFormMain.LayoutClientDblClick(Sender: TObject);
begin
  {$IFDEF ANDROID}
  Exit;
  {$ENDIF}
  SwitchFullScreen;
end;

procedure TFormMain.ListBoxGamesItemClick(const Sender: TCustomListBox; const Item: TListBoxItem);
begin
  {$IFDEF ANDROID}
  var TempRomFile := TRomStorage.SaveToFile((Item as TListBoxItemGame).RomFile);
  LoadRom(TempRomFile);
  Exit;
  {$ENDIF}
  LoadRom(Item.TagString);
end;

procedure TFormMain.LoadRom(const FileName: string; const DisplayName: string);
begin
  ImageLogo.Visible := False;
  // Construct first: an invalid ROM leaves the current worker running.
  var NewEmulation: IEmulationCore;
  NewEmulation := CreateEmulationCore(FileName);
  try
    if FEmulation <> nil then
      FEmulation.Stop;
  except
    NewEmulation := nil;
    raise;
  end;
  if FGamepad <> nil then
    FGamepad.ReleaseAll;
  if FSuborKeyboard <> nil then
    FSuborKeyboard.ReleaseAll;
  TimerUpdate.Enabled := False;
  FEmulation := nil; // Join before replacing the session.
  FEmulation := NewEmulation;
  if FEmulation.Config is TMDConfig then
    FGamepad.Layout := TScreenGamepadLayout.Sega
  else
    FGamepad.Layout := TScreenGamepadLayout.Nes;
               {
  var NesEmulatorConfig: INesEmulatorConfig;
  if Supports(FEmulation.Config, INesEmulatorConfig, NesEmulatorConfig) then
  begin
    NesEmulatorConfig.FourScore := False;
    NesEmulatorConfig.ZapperEnabled := False;
    FEmulation.Config.Save;
  end;     }

  ImageCanvas.HitTest := False;
  ImageCanvas.CanFocus := False;
  ImageCanvas.DisableFocusEffect := True;
  var Peripheral: INesPeripheralCore;
  if Supports(FEmulation, INesPeripheralCore, Peripheral) then
  begin
    ImageCanvas.HitTest := True;
    ImageCanvas.CanFocus := True;
    ImageCanvas.OnKeyDown := FormKeyDown;
    ImageCanvas.OnKeyUp := FormKeyUp;
    ImageCanvas.DisableFocusEffect := False;
    ImageCanvas.CanParentFocus := True;
    Peripheral.Zapper.OnReadLight :=
      function(const Mask: TNesZapperMask): Boolean
      begin
        // External photosensor implementation goes here.
        // True = light detected; False = darkness / aim outside the screen.
        //Result := ReadExternalPhotoSensor(Mask);

        Result := ReadZapperMask(Mask, FZapperPixel.X, FZapperPixel.Y);

        {for var X := Low(Mask) to High(Mask) do
          for var Y := Low(Mask[X]) to High(Mask[X]) do
            if Mask[X, Y] <> 0 then
              Exit(True);
        Result := False;  }
      end;
    // Port 2 is selected by the NES configuration before the worker starts.
    // Attaching the light-sensor callback must not connect a gun to every ROM.
    //Peripheral.SetSuborKeys(FSuborKeyboard.Keys);
  end;

  FUserPaused := False;
  ImageCanvas.DisableInterpolation := SameText(FEmulation.Config.Filter, 'nearest');
  FillChar(FKeysDown, SizeOf(FKeysDown), 0);
  FRomDisplayName := DisplayName;
  if FRomDisplayName = '' then
    FRomDisplayName := ExtractFileName(FileName);
  FSoundErrorShown := False;
  try
    ImageCanvas.Bitmap.Clear(TAlphaColors.Black);
    FEmulationFaulted := False;
    {$IFDEF ANDROID}
    if FActivityPaused then
      FEmulation.Pause;
    {$ENDIF}
    FEmulation.Start;
    SyncActivity;
    SetStatus(FEmulation.Name + ' - ' + FRomDisplayName);
  except
    StopOnError;
    raise;
  end;
  {$IFDEF ANDROID}
  SwitchFullscreen;
  {$ENDIF}
end;

procedure TFormMain.OpenRom;
begin
  if FOpeningRom then
    Exit;
  FOpeningRom := True;
  ButtonOpen.Enabled := False;
  ImageLogo.Visible := False;
  FormDeactivate(Self);
  {$IFDEF ANDROID}
  try
    SyncActivity;
    FPicker.Open;
  except
    FPicker.Finish;
    FOpeningRom := False;
    ButtonOpen.Enabled := True;
    SyncActivity;
    raise;
  end;
  {$ELSE}
  var Dialog: TOpenDialog := TOpenDialog.Create(Self);
  try
    Dialog.Filter := 'Console ROM|*.nes;*.gb;*.gbc;*.md;*.gen;*.bin;*.smd|NES ROM (*.nes)|*.nes|Game Boy ROM (*.gb;*.gbc)|*.gb;*.gbc|Mega Drive ROM (*.md;*.gen;*.bin;*.smd)|*.md;*.gen;*.bin;*.smd';
    Dialog.Options := [TOpenOption.ofFileMustExist, TOpenOption.ofPathMustExist];
    if Dialog.Execute then
      LoadRom(Dialog.FileName);
  finally
    Dialog.Free;
    FOpeningRom := False;
    ButtonOpen.Enabled := True;
    FormActivate(Self);
  end;
  {$ENDIF}
end;

procedure TFormMain.UpdateFrame;
begin
  if FEmulation = nil then
    Exit;
  var Frame: TEmulatorFrame;
  var NewFrame := FEmulation.TryGetFrame(Frame);
  var ErrorText := FEmulation.TakeError;
  if (ErrorText <> '') and not FEmulationFaulted then
  begin
    StopOnError;
    raise Exception.Create(ErrorText);
  end;
  if not FEmulationFaulted and NewFrame then
  begin
    var NewCaption := Format('%s - %.1f FPS', [FEmulation.Name, Frame.FramesPerSecond]);
    if Caption <> NewCaption then
      SetStatus(NewCaption);
  end;
  if not NewFrame then
    Exit;
  if (ImageCanvas.Bitmap.Width <> Frame.Width) or (ImageCanvas.Bitmap.Height <> Frame.Height) then
  begin
    ImageCanvas.Bitmap.SetSize(Frame.Width, Frame.Height);
  end;
  var Data: TBitmapData;
  if ImageCanvas.Bitmap.Map(TMapAccess.Write, Data) then
  try
    for var Y := 0 to Frame.Height - 1 do
      for var X := 0 to Frame.Width - 1 do
        Data.SetPixel(X, Y, Frame.Pixels[Y * Frame.Width + X]);
  finally
    ImageCanvas.Bitmap.Unmap(Data);
  end;
  ImageCanvas.Repaint;
end;

procedure TFormMain.DoOnSettingChange;
begin
  //FF2C4361 - FF0B1E39
  var OverAccentColor := SystemAccentColor;

  // Set stylebook and color for theme
  if IsDark then
  begin
    // Set accent color for stylebook
    ChangeStyleBookColor(FormStyles.StyleBookWinUI3, OverAccentColor);
    StyleBook := FormStyles.StyleBookWinUI3;
  end
  else
  begin
    // Set accent color for stylebook
    ChangeStyleBookColor(FormStyles.StyleBookWinUI3Light, OverAccentColor);
    StyleBook := FormStyles.StyleBookWinUI3Light;
  end;

  inherited;

  SystemBackdropType := TWindowBackdropType.Disable;
  Fill.Kind := TBrushKind.None;

  UpdateSystemBackdropType;
               {
  if RadioButtonSetBGGradient.IsChecked then
  begin
    Fill.Kind := TBrushKind.Gradient;
    //Fill.Gradient.Color := $FF2C4361;
    //Fill.Gradient.Color1 := $FF0B1E39;
    Fill.Gradient.Color := ComboColorBoxSetBGColor1.Color;
    Fill.Gradient.Color1 := ComboColorBoxSetBGColor2.Color;
  end;    }

  TMessageManager.DefaultManager.SendMessage(Self, TStyleChangedMessage.Create(StyleBook, Self), True);
  TMessageManager.DefaultManager.SendMessage(Self, TInternalSettingChangedMessage.Create(StyleBook, Self), True);
end;

{ TListBoxItemGame }

procedure TListBoxItemGame.ApplyStyle;
begin
  inherited;
  if FLoaded then
    Exit;
  FLoaded := True;
  var BoxPath := StylesData['box'].AsString;
  try
    if TFile.Exists(BoxPath) then
      ItemData.Bitmap.LoadFromFileAsync(Self, BoxPath, 64, 64)
    else
      ItemData.Bitmap := nil;
  except
    ItemData.Bitmap := nil;
  end;
end;

end.

