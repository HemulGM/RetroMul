unit RM.Controllers.Mobile;

{$I ..\RM.Mobile.inc}

interface

uses
  RM.Controllers.Base
  {$IFDEF ISMOBILE}
    , FMX.Platform
  {$ENDIF};

type
  TMobileController = class(TMainController)
  public
    {$IFDEF ISMOBILE}
    procedure InitializeMobileViews;
    {$ENDIF}
    {$IFDEF ANDROID}
    procedure InitializeAndroidServices;
    {$ENDIF}
    {$IFDEF ISMOBILE}
    function ApplicationStateChanged(Sender: TObject; const AAppEvent: TApplicationEvent; const AContext: TObject): Boolean;
    {$ENDIF}
    {$IFDEF ANDROID}
    procedure PollDocumentTransfer;
    {$ENDIF}
  end;

implementation

uses
  System.SysUtils, System.Types, System.UITypes, System.IOUtils, FMX.Types,
  FMX.Controls, FMX.Forms, FMX.Objects, RM.Dialogs
  {$IFDEF ISMOBILE}
    , FMX.ApplicationEvents
  {$ENDIF}
  {$IFDEF ANDROID}
    , Androidapi.Helpers, Androidapi.JNI.App, Androidapi.JNI.Media,
    RM.DocumentTransfer.Android
  {$ENDIF};

{$IFDEF ISMOBILE}
procedure TMobileController.InitializeMobileViews;
begin
  FState.Mobile.AppEvents := TApplicationEvents.Create(FView);
  FState.Mobile.AppEvents.OnStateChanged := FView.ApplicationStateChanged;
  for var Tool in [FView.ButtonLibrary, FView.GameFullscreen, FView.GameSettings, FView.GameInsertCoin, FView.GameControlsHelp] do
    Tool.Visible := False;
  FView.GamePause.Visible := True;
  FView.GamePause.Text := '';
  FView.GamePause.OnClick := FView.PauseClick;
  FView.GamePause.Align := TAlignLayout.Right;
  FView.GamePause.Width := 60;
  for var Child in FView.GamePause.Children do
    if Child is FMX.Objects.TPath then
    begin
      FMX.Objects.TPath(Child).Margins.Rect := TRectF.Empty;
      FMX.Objects.TPath(Child).Align := TAlignLayout.Center;
    end;
  FView.GameStatus.Visible := False;
  FView.GamePlatform.Visible := False;
  (FView.FindComponent('ToolbarBackground') as TControl).Visible := False;
  FView.LabelPaused.TextSettings.Font.Size := 60;
  FView.LabelStatus.Align := TAlignLayout.Client;
  FView.LabelStatus.StyledSettings := [TStyledSetting.Family, TStyledSetting.Size,
      TStyledSetting.Style];
  FView.LabelStatus.TextSettings.FontColor := TAlphaColors.White;
  FView.LayoutClient.Visible := False;
  FView.ScreenTabs.ActiveTab := FView.GameScreen;
  FView.LayoutHead.OnResize := FView.FormResize;
end;

{$ENDIF}
{$IFDEF ANDROID}
procedure TMobileController.InitializeAndroidServices;
begin
  // Hardware volume keys control game audio, including before a ROM is loaded.
  TAndroidHelper.Activity.setVolumeControlStream(TJAudioManager.JavaClass.STREAM_MUSIC);
  FState.Mobile.Transfer := TAndroidDocumentTransfer.Create(FState.Session.Storage);
end;

{$ENDIF}
{$IFDEF ISMOBILE}
function TMobileController.ApplicationStateChanged(Sender: TObject; const AAppEvent: TApplicationEvent; const AContext: TObject): Boolean;
begin
  case AAppEvent of
    TApplicationEvent.WillBecomeInactive, TApplicationEvent.EnteredBackground:
      FState.Mobile.InBackground := True;
    TApplicationEvent.BecameActive:
      FState.Mobile.InBackground := False;
  else
    Exit(False);
  end;
  FView.SyncActivity;
  // Mobile systems may terminate a background app without closing its form.
  if AAppEvent = TApplicationEvent.EnteredBackground then
  try
    FView.AutosaveOnExit;
  except
    Application.HandleException(FView);
  end;
  Result := False;
end;

{$ENDIF}
{$IFDEF ANDROID}
procedure TMobileController.PollDocumentTransfer;
begin
  if not FState.Session.OpeningRom then
    Exit;
  var FileName, DisplayName, Error: string;
  if not FState.Mobile.Transfer.Poll(FileName, DisplayName, Error) then
    Exit;
  try
    try
      if Error <> '' then
        raise Exception.Create(Error);
      if FileName <> '' then
        if Assigned(FState.Mobile.PlatformDocumentSelected) then
        begin
          if FState.Session.Emulation <> FState.Mobile.PlatformDocumentCore then
            Exit;
          var Storage := FState.Session.Storage;
          var Folder := System.IOUtils.TPath.Combine(Storage.SaveRoot, FState.Mobile.PlatformDocumentFolder);
          var Path := Storage.GamePath(Folder, DisplayName, TGUID.NewGuid.ToString,
            FState.Mobile.PlatformDocumentExtension);
          var Input := Storage.OpenRead(FileName);
          try
            Storage.WriteAtomic(Path, Input);
          finally
            Input.Free;
          end;
          FState.Mobile.PlatformDocumentSelected(Path);
        end
        else
          FView.LoadRom(FileName, DisplayName);
    except
      on E: Exception do
        ShowRetroMessage(FView, E.Message);
    end;
  finally
    FView.FinishFileSelection;
  end;
end;

{$ENDIF}
end.

