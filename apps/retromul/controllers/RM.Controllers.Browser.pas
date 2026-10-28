unit RM.Controllers.Browser;

{$I ..\RM.Mobile.inc}

interface

uses
  System.Classes, System.UITypes, FMX.Menus, RM.Controllers.Base;

type
  TBrowserController = class(TMainController)
  private
    FMenuParent: TMenuItem;
    FMenuPointerDown, FMenuDragged: Boolean;
    FMenuPointerY, FMenuScrollY: Single;
    procedure DiscMenuClick(Sender: TObject);
    procedure OpenDiscClick(Sender: TObject);
    procedure MobileMenuDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Single);
    procedure MobileMenuMove(Sender: TObject; Shift: TShiftState; X, Y: Single);
    procedure MobileMenuUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Single);
    procedure RenderMobileMenu(Parent: TMenuItem);
    procedure SizeMobileMenu;
    procedure MobileMenuClick(Sender: TObject);
    procedure MobileMenuBack(Sender: TObject);
    procedure MobileMenuActivity(Sender: TObject);
  public
    procedure InitializeScreenshotTool;
    procedure InitializeMobileGameMenu;
    procedure PrepareGameActionsMenu(Sender: TObject);
    procedure ShowGameActionsMenu(Sender: TObject);
    procedure SetPanelVisibility(Sender: TObject);
    procedure InitializeLibrary;
    {$IFNDEF ISMOBILE}
    procedure InitializeDesktopViews;
    {$ENDIF}
    procedure LibraryPlay(Sender: TObject);
    procedure LibraryBack(Sender: TObject);
    procedure UpdateGameChrome;
    procedure SetStatus(const Text: string);
    procedure LayoutClientClick(Sender: TObject);
    procedure LayoutClientDblClick(Sender: TObject);
  end;

implementation

uses
  RM.Input.Runtime, System.SysUtils, System.Types, System.Math, FMX.Types,
  FMX.Controls, FMX.StdCtrls, FMX.Objects, FMX.Layouts, RM.Main.View, RM.Toolbar,
  RM.LibraryView, RM.Dialogs, RM.Styles, RM.Icons, Core.Emulation, Core.Storage;

procedure TBrowserController.InitializeScreenshotTool;
begin
  FView.ButtonReset.OnClick := FView.ResetClick;
  // Split buttons and hardware views have no installed design-time components.
  {$IFDEF ISMOBILE}
  InitializeMobileGameMenu;
  {$ELSE}
  FView.ButtonCloseRom.Hint := Translate('Close game');
  {$ENDIF}
end;

procedure TBrowserController.InitializeMobileGameMenu;
begin
  FState.Browser.ActionsTool := FView.GameActionsButton;
  FView.GameActionsButton.Visible := True;
  FView.GameActionsButton.Hint := Translate('More actions');
  FView.GameActionsButton.OnClick := ShowGameActionsMenu;
  FView.GameActionsMenu.OnPopup := PrepareGameActionsMenu;
  FView.GameActionsPopup.PlacementTarget := FView.GameActionsButton;
  FView.GameActionsPopup.OnPopup := MobileMenuActivity;
  FView.GameActionsPopup.OnClosePopup := MobileMenuActivity;
  FView.GameActionsBack.OnClick := MobileMenuBack;
  FView.GameActionsBack.Text := Translate('Back');
  FState.Browser.ScreenshotMenu := FView.ScreenshotMenu;
  FState.Browser.SaveMenu := FView.SaveSnapshotMenu;
  FState.Browser.LoadMenu := FView.LoadSnapshotMenu;
  FView.ButtonHidePanel.Visible := True;
  FView.ButtonHidePanel.Hint := Translate('Hide panel');
  FView.ButtonShowPanel.Hint := Translate('Show panel');
  FView.ButtonHidePanel.OnClick := SetPanelVisibility;
  FView.ButtonShowPanel.OnClick := SetPanelVisibility;
  FView.ButtonCloseRom.Hint := Translate('Close game');
end;

procedure TBrowserController.ShowGameActionsMenu(Sender: TObject);
begin
  {$IFDEF ISMOBILE}
  PrepareGameActionsMenu(nil);
  RenderMobileMenu(nil);
  FView.GameActionsPopup.IsOpen := True;
  {$ELSE}
  var P := FView.GameActionsButton.LocalToScreen(PointF(0, FView.GameActionsButton.Height));
  FView.GameActionsMenu.Popup(P.X, P.Y);
  {$ENDIF}
end;

procedure TBrowserController.SizeMobileMenu;
begin
  var Popup := FView.GameActionsPopup;
  var Available := FView.LayoutClient.AbsoluteRect;
  var BelowButton := FView.GameActionsButton.LocalToAbsolute(PointF(0, FView.GameActionsButton.Height)).Y;
  var ContentHeight := FView.GameActionsItems.Height + Popup.Padding.Top + Popup.Padding.Bottom;
  if FView.GameActionsBack.Visible then
    ContentHeight := ContentHeight + FView.GameActionsBack.Height + FView.GameActionsBack.Margins.Top + FView.GameActionsBack.Margins.Bottom;
  var W := Min(320, Max(0, Available.Width - 16));
  var H := Min(ContentHeight, Max(0, Available.Bottom - BelowButton - 8));
  if SameValue(Popup.Width, W, 0.1) and SameValue(Popup.Height, H, 0.1) and
    SameValue(Popup.PopupFormSize.Width, W, 0.1) and SameValue(Popup.PopupFormSize.Height, H, 0.1) then
    Exit;
  Popup.Width := W;
  Popup.Height := H;
  // A live popup has its own form. Resizing only the control leaves that form
  // at the old size, clipping its viewport when changing pages or orientation.
  Popup.PopupFormSize := TSizeF.Create(Popup.Width, Popup.Height);
  FView.GameActionsScroll.RealignContent;
end;

procedure TBrowserController.MobileMenuActivity(Sender: TObject);
begin
  if not (csDestroying in FView.ComponentState) then
    FView.SyncActivity;
end;

procedure TBrowserController.RenderMobileMenu(Parent: TMenuItem);

  procedure DetachMenuControl(Control: TControl);
  begin
    if (Control.Root <> nil) and (Control.Root.Captured <> nil) and
      (Control.Root.Captured.GetObject = Control) then
      Control.Root.SetCaptured(nil);
    Control.OnClick := nil;
    Control.OnDblClick := nil;
    Control.OnMouseDown := nil;
    Control.OnMouseMove := nil;
    Control.OnMouseUp := nil;
    Control.OnTap := nil;
    Control.TagObject := nil;
    for var Child in Control.Controls do
      DetachMenuControl(Child);
  end;

begin
  FMenuParent := Parent;
  FView.GameActionsBack.Visible := Parent <> nil;
  if Parent <> nil then
    FView.GameActionsBack.ApplyStyleLookup;
  // FMX still uses the clicked button after OnClick. Detach it now and let
  // Release defer destruction until the input event has finished.
  while FView.GameActionsItems.ChildrenCount > 0 do
  begin
    var Control := FView.GameActionsItems.Children[FView.GameActionsItems.ChildrenCount - 1] as TControl;
    DetachMenuControl(Control);
    Control.Parent := nil;
    Control.Release;
  end;
  var Count := FView.GameActionsMenu.ItemsCount;
  if Parent <> nil then
    Count := Parent.ItemsCount;
  var Top: Single := 0;
  for var I := 0 to Count - 1 do
  begin
    var Item: TMenuItem;
    if Parent <> nil then
      Item := Parent.Items[I]
    else
      Item := FView.GameActionsMenu.Items[I];
    if not Item.Visible or (Item.Text = '-') then
      Continue;
    var Button := TButton.Create(FView.GameActionsItems);
    Button.Parent := FView.GameActionsItems;
    Button.SetBounds(0, Top, 300, 44);
    Button.Align := TAlignLayout.Top;
    Button.Margins.Bottom := 4;
    Button.Text := Item.Text;
    Button.StyledSettings := [];
    Button.TextSettings.FontColor := $FFE8ECF1;
    Button.TextSettings.Font.Size := 14;
    Button.TextSettings.HorzAlign := TTextAlign.Leading;
    Button.StyleLookup := 'buttonstyle';
    Button.Enabled := Item.Enabled;
    Button.TagObject := Item;
    Button.OnClick := MobileMenuClick;
    Button.OnMouseDown := MobileMenuDown;
    Button.OnMouseMove := MobileMenuMove;
    Button.OnMouseUp := MobileMenuUp;
    Button.Touch.InteractiveGestures := [TInteractiveGesture.Pan];
    Top := Top + 48;
  end;
  FView.GameActionsItems.Height := Top;
  SizeMobileMenu;
  FView.GameActionsScroll.RealignContent;
  FView.GameActionsScroll.ViewportPosition := PointF(0, 0);
end;

procedure TBrowserController.MobileMenuClick(Sender: TObject);
begin
  if FMenuDragged then
    Exit;
  var Item := TMenuItem(TButton(Sender).TagObject);
  if Item.ItemsCount > 0 then
    RenderMobileMenu(Item)
  else
  begin
    FView.GameActionsPopup.IsOpen := False;
    if Assigned(Item.OnClick) then
      Item.OnClick(Item);
  end;
end;

procedure TBrowserController.MobileMenuDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Single);
begin
  FMenuPointerDown := Button = TMouseButton.mbLeft;
  FMenuDragged := False;
  FMenuPointerY := TControl(Sender).LocalToAbsolute(PointF(X, Y)).Y;
  FMenuScrollY := FView.GameActionsScroll.ViewportPosition.Y;
end;

procedure TBrowserController.MobileMenuMove(Sender: TObject; Shift: TShiftState; X, Y: Single);
begin
  if not FMenuPointerDown then
    Exit;
  var Delta := FMenuPointerY - TControl(Sender).LocalToAbsolute(PointF(X, Y)).Y;
  if Abs(Delta) > 6 then
    FMenuDragged := True;
  if FMenuDragged then
    FView.GameActionsScroll.ViewportPosition := PointF(0, EnsureRange(FMenuScrollY + Delta, 0.0,
        Max(0.0, FView.GameActionsScroll.ContentBounds.Bottom - FView.GameActionsScroll.ViewportRect.Height)));
end;

procedure TBrowserController.MobileMenuUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Single);
begin
  FMenuPointerDown := False;
end;

procedure TBrowserController.MobileMenuBack(Sender: TObject);
begin
  if (FMenuParent <> nil) and (FMenuParent.Parent is TMenuItem) then
    RenderMobileMenu(TMenuItem(FMenuParent.Parent))
  else
    RenderMobileMenu(nil);
end;

procedure TBrowserController.SetPanelVisibility(Sender: TObject);
begin
  FState.Browser.PanelHidden := Sender = FView.ButtonHidePanel;
  if FState.Browser.PanelHidden and (FState.Session.UserPaused or FState.Session.AutoPaused) then
    FView.SwitchPause;
  UpdateGameChrome;
  FView.FormResize(FView);
end;

procedure TBrowserController.PrepareGameActionsMenu(Sender: TObject);

  function Add(Parent: TFmxObject; const Caption: string; Click: TNotifyEvent; Enabled: Boolean = True): TMenuItem;
  begin
    Result := TMenuItem.Create(FView.GameActionsMenu);
    Result.Text := Translate(Caption);
    Result.OnClick := Click;
    Result.Enabled := Enabled;
    Parent.AddObject(Result);
  end;

  procedure CopyItem(Source: TMenuItem; Parent: TFmxObject);
  begin
    var Item := Add(Parent, Source.Text, Source.OnClick, Source.Enabled);
    Item.Text := Source.Text;
    Item.TagString := Source.TagString;
    Item.Visible := Source.Visible;
    for var I := 0 to Source.ItemsCount - 1 do
      CopyItem(Source.Items[I], Item);
  end;

  procedure AddOptions(Parent: TMenuItem; Source: TPopupMenu);
  begin
    // Mobile uses quick slots and existing saves; file dialogs remain desktop-only.
    {$IFDEF ISMOBILE}
    if Source = FState.Browser.SaveMenu then
      Exit;
    {$ENDIF}
    FView.PrepareGameplayMenu(Source);
    var OpenSnapshot: TNotifyEvent := FView.OpenSnapshotClick;
    for var I := 0 to Source.ItemsCount - 1 do
    begin
      if Source.Items[I].Text = '-' then
        Continue;
      {$IFDEF ISMOBILE}
      if (Source = FState.Browser.LoadMenu) and
        (TMethod(Source.Items[I].OnClick) = TMethod(OpenSnapshot)) then
        Continue;
      {$ENDIF}
      CopyItem(Source.Items[I], Parent);
    end;
  end;

begin
  var Menu := FView.GameActionsMenu;
  FMenuParent := nil;
  Menu.Clear;
  var Ready := (FState.Session.Emulation <> nil) and not FState.Session.OpeningRom
    and not FState.Session.EmulationFaulted;
  var Snapshots := Ready and FState.Session.Emulation.SupportsSnapshots;
  {$IFDEF ISMOBILE}
  Add(Menu, 'Back to library', FView.LibraryBack, not FState.Session.OpeningRom);
  var Paused := FState.Session.UserPaused or
    ((FState.Session.Emulation <> nil) and FState.Session.Emulation.IsPaused);
  var PauseText := 'Pause';
  if Paused then
    PauseText := 'Resume';
  Add(Menu, PauseText, FView.PauseClick, Ready);
  {$ENDIF}
  if (FState.Session.Emulation <> nil) and FState.Session.Emulation.HasCoinAcceptor then
    Add(Menu, 'Insert coin', FView.InsertCoinClick, Ready and not FState.Browser.ViewingLibrary
      and (FState.Settings.View = nil) and (FState.Help.View = nil));
  var Discs: IEmulationDiscControl;
  if Ready and Supports(FState.Session.Emulation, IEmulationDiscControl, Discs) and (Discs.GetDiscCount > 0) then
  begin
    var DiscMenu := Add(Menu, 'Change disc', nil);
    DiscMenu.Name := 'MenuItemChangeDisc';
    for var I := 0 to Discs.GetDiscCount - 1 do
    begin
      var Caption := Format('%d. %s', [I + 1, Discs.GetDiscName(I)]);
      if I = Discs.GetDiscIndex then
        Caption := '✓ ' + Caption;
      var DiscItem := Add(DiscMenu, Caption, DiscMenuClick);
      DiscItem.Name := 'MenuItemDisc' + IntToStr(I + 1);
      DiscItem.Tag := I;
    end;
    Add(DiscMenu, 'Open disc image...', OpenDiscClick).Name := 'MenuItemOpenDiscImage';
    var Eject := Add(DiscMenu, 'Eject disc', DiscMenuClick, Discs.GetDiscIndex >= 0);
    Eject.Name := 'MenuItemEjectDisc';
    Eject.Tag := -1;
  end;
  var Save := Add(Menu, 'Save', nil, Snapshots);
  Add(Save, 'Quick save · F5', FView.SaveStateClick);
  AddOptions(Save, FState.Browser.SaveMenu);
  var Load := Add(Menu, 'Load', nil, Snapshots);
  Add(Load, 'Quick load · F6', FView.LoadStateClick);
  AddOptions(Load, FState.Browser.LoadMenu);
  var Screenshot := Add(Menu, 'Screenshot', nil, Ready);
  Add(Screenshot, 'Take screenshot', FView.ScreenshotClick);
  AddOptions(Screenshot, FState.Browser.ScreenshotMenu);
  {$IFDEF ISMOBILE}
  Add(Menu, 'Full screen', FView.FullscreenClick, Ready and not FState.Browser.ViewingLibrary
    and (FState.Settings.View = nil) and (FState.Help.View = nil));
  {$ENDIF}
  Add(Menu, 'Settings', FView.SettingsClick, not FState.Session.OpeningRom);
  {$IFDEF ISMOBILE}
  Add(Menu, 'Controls and shortcuts', FView.ControlsHelpClick, Ready and not FState.Help.Closing);
  {$ENDIF}
end;

procedure TBrowserController.DiscMenuClick(Sender: TObject);
begin
  var Discs: IEmulationDiscControl;
  if FState.Session.OpeningRom or FState.Session.EmulationFaulted or
    not Supports(FState.Session.Emulation, IEmulationDiscControl, Discs) then
    Exit;
  try
    FState.Session.Emulation.ClearInput;
    if TMenuItem(Sender).Tag < 0 then
      Discs.EjectDisc
    else
      Discs.ChangeDisc(TMenuItem(Sender).Tag);
    FView.SyncActivity;
  except
    on E: Exception do
      ShowRetroMessage(FView, E.Message);
  end;
end;

procedure TBrowserController.OpenDiscClick(Sender: TObject);
begin
  var Discs: IEmulationDiscControl;
  if FState.Session.OpeningRom or FState.Session.EmulationFaulted or
    not Supports(FState.Session.Emulation, IEmulationDiscControl, Discs) then
    Exit;
  var Core := FState.Session.Emulation;
  var IsAlive := FState.Session.CallbackAlive;
  FState.Session.OpeningRom := True;
  FView.FormDeactivate(FView);
  FView.SyncActivity;
  try
    FState.Session.Storage.SelectRom(
      procedure(const Selection: TStorageSelection)
      begin
        if not IsAlive() then
          Exit;
        try
          try
            if Selection.Error <> '' then
              raise Exception.Create(Selection.Error);
            if not Selection.Cancelled and (FState.Session.Emulation = Core) then
              Discs.OpenDisc(Selection.Location);
          except
            on E: Exception do
              ShowRetroMessage(FView, E.Message);
          end;
        finally
          FView.FinishFileSelection;
        end;
      end);
  except
    FView.FinishFileSelection;
    raise;
  end;
end;

procedure TBrowserController.InitializeLibrary;
begin
  FState.Browser.View := TLibraryView.CreateLibrary(FView, FState.Session.Storage);
  FState.Browser.View.Parent := FView.LibraryScreen;
  FState.Browser.View.Align := TAlignLayout.Client;
  FState.Browser.View.OnPlay := FView.LibraryPlay;
  FState.Browser.View.OnSettings := FView.SettingsClick;
  FState.Browser.View.OnOpen := FView.ButtonOpenClick;
  FView.LayoutClient.Visible := False;
  FState.Browser.ViewingLibrary := True;
  FView.ScreenTabs.ActiveTab := FView.LibraryScreen;
end;

{$IFNDEF ISMOBILE}
procedure TBrowserController.InitializeDesktopViews;
begin
  FView.GameActionsButton.Visible := True;
  FView.GameActionsButton.OnClick := ShowGameActionsMenu;
  FView.GameActionsMenu.OnPopup := PrepareGameActionsMenu;
  FState.Browser.BackTool := FView.ButtonLibrary;
  FState.Browser.BackTool.OnClick := FView.LibraryBack;
  FView.ButtonCloseRom.Visible := False;
  FState.Browser.Tools[0] := FView.GamePause;
  FState.Browser.Tools[1] := TToolbarSplitButton.Create(FView);
  FState.Browser.Tools[1].Name := 'ToolbarSplitButtonSave';
  FState.Browser.Tools[3] := FView.GameFullscreen;
  FState.Browser.Tools[4] := FView.GameSettings;
  FState.Browser.Tools[1].Parent := FView.FindComponent('LayoutGameActions') as TLayout;
  FState.Browser.Tools[1].Width := 104;
  FState.Browser.Tools[0].OnClick := FView.PauseClick;
  FState.Browser.Tools[1].OnClick := FView.SaveStateClick;
  FState.Browser.Tools[3].OnClick := FView.FullscreenClick;
  FState.Browser.Tools[4].OnClick := FView.SettingsClick;
  GameplayButton(FState.Browser.Tools[1], Translate('Save'), IconSave, Translate('Quick save · F5'));
  FState.Browser.Tools[1].StylesData['text.Margins.Right'] := 32;
  FState.Browser.ScreenshotMenu := FView.ScreenshotMenu;
  FState.Browser.SaveMenu := FView.SaveSnapshotMenu;
  FState.Browser.LoadMenu := FView.LoadSnapshotMenu;
  for var Menu in [FState.Browser.ScreenshotMenu, FState.Browser.SaveMenu, FState.Browser.LoadMenu] do
    Menu.OnPopup := FView.PrepareGameplayMenu;
  FState.Browser.Tools[1].PopupMenu := FState.Browser.SaveMenu;
  FState.Browser.CoinTool := FView.GameInsertCoin;
  FState.Browser.CoinTool.OnClick := FView.InsertCoinClick;
  FState.Browser.HelpTool := FView.GameControlsHelp;
  FState.Browser.HelpTool.OnClick := FView.ControlsHelpClick;
  FState.Browser.GamePlatform := FView.GamePlatform;
  FState.Browser.GameStatus := FView.GameStatus;
  FState.Browser.GameFPS := FView.GameFPS;
  FState.Browser.GameAudio := FView.GameAudio;
  for var Tool in [FView.ButtonLibrary, FView.GamePause, FView.ButtonReset, FView.GameFullscreen, FView.GameSettings, FView.GameInsertCoin, FView.GameControlsHelp] do
  begin
    Tool.StylesData['text.Margins.Left'] := 36;
    Tool.StylesData['text.Margins.Right'] := 10;
  end;
  FormStyles.RelocalizeUI(FView.GameScreen, 'en');
  FView.LayoutHead.OnResize := FView.FormResize;
  FView.FormResize(FView);
end;
{$ENDIF}

procedure TBrowserController.LibraryPlay(Sender: TObject);
begin
  if (FState.Browser.View.Selected = nil) or FState.Session.OpeningRom then
    Exit;

  var Game := FState.Browser.View.Selected;
  var Snapshot := FState.Browser.View.SnapshotName;
  try
    FView.LoadRom(Game.FileInfo.Location, Game.Title, Snapshot <> '', Snapshot);
  except
    on E: Exception do
      ShowRetroMessage(FView, Translate('Unable to open game: ') + E.Message);
  end;
end;

procedure TBrowserController.LibraryBack(Sender: TObject);
begin
  if FState.Browser.View = nil then
    Exit;

  FView.FormDeactivate(FView);
  if FState.Session.Emulation <> nil then
  begin
    FState.Session.Emulation.Pause;
    if not FState.Browser.ViewingLibrary then
      FView.AutosaveOnExit;
  end;
  if FView.FullScreen then
    FView.SwitchFullScreen;
  FView.LayoutClient.Visible := False;
  FView.ScreenTabs.ActiveTab := FView.LibraryScreen;
  FState.Browser.View.Visible := True;
  FState.Browser.View.CloseDetails;
  var LanguageRefreshed := FState.Browser.PendingLanguage <> '';
  if LanguageRefreshed then
  begin
    FState.Browser.View.ApplyLanguage(FState.Browser.PendingLanguage);
    FState.Browser.PendingLanguage := '';
  end;
  if FState.Browser.ReloadPending then
  begin
    FState.Browser.View.ApplyPreferences;
    FState.Browser.View.Reload;
    FState.Browser.ReloadPending := False;
  end
  else if not LanguageRefreshed then
    FState.Browser.View.RefreshSnapshots;
  FState.Browser.View.BringToFront;
  FState.Browser.ViewingLibrary := True;
  FView.SyncActivity;
end;

procedure TBrowserController.UpdateGameChrome;
begin
  if csDestroying in FView.ComponentState then
    Exit;
  if (FState.Session.Emulation = nil) or FState.Session.EmulationFaulted then
    FView.StatusDot.Fill.Color := $FFFF6B6B
  else if FState.Session.UserPaused or FState.Session.AutoPaused or FState.Session.Emulation.IsPaused then
    FView.StatusDot.Fill.Color := $FFFFB43B
  else
    FView.StatusDot.Fill.Color := $FF7ED94C;

  if FState.Browser.GamePlatform <> nil then
  begin
    FState.Browser.GamePlatform.Text := LibrarySystemName(FState.Input.SystemId);
    if FState.Session.Emulation <> nil then
      FState.Browser.GamePlatform.Text := FState.Session.Emulation.Name;
  end;
  if FState.Browser.GameStatus <> nil then
  begin
    FState.Browser.GameStatus.Visible := not FView.FullScreen;
    if FState.Session.Emulation <> nil then
      if FState.Session.Emulation.Config.AudioEnabled and (FState.Session.Emulation.Config.AudioVolume > 0) and not FState.Session.SoundErrorShown then
        FState.Browser.GameAudio.Text := Translate('Audio on')
      else
        FState.Browser.GameAudio.Text := Translate('Audio off');
  end;

  {$IFNDEF ISMOBILE}
  FView.LayoutHead.Visible := (FState.Browser.View <> nil) and not FView.FullScreen;
  {$ENDIF}

  if FState.Browser.ActionsTool <> nil then
  begin
    FView.LayoutHead.Visible := not FState.Browser.PanelHidden;
    FView.LayoutShowPanel.Visible := FState.Browser.PanelHidden;
    if FView.LayoutShowPanel.Visible then
      FView.LayoutShowPanel.BringToFront;
    if FView.GameActionsPopup.IsOpen then
      SizeMobileMenu;
  end;

  if FState.Browser.CoinTool <> nil then
  begin
    var WasVisible := FState.Browser.CoinTool.Visible;
    FState.Browser.CoinTool.Visible := (FState.Session.Emulation <> nil) and FState.Session.Emulation.HasCoinAcceptor;
    FState.Browser.CoinTool.Enabled := FState.Browser.CoinTool.Visible and not FState.Session.EmulationFaulted and not FState.Session.OpeningRom and
      not FState.Browser.ViewingLibrary and (FState.Settings.View = nil) and (FState.Help.View = nil);
    if WasVisible <> FState.Browser.CoinTool.Visible then
      FView.FormResize(FView);
  end;
  if FState.Browser.ScreenshotTool <> nil then
  begin
    var InputContext := Default(TInputRuntimeContext);
    InputContext.State := FState;
    InputContext.View := FView;
    if PlatformInputHandler(FState.Input.SystemId).KeyPolicy(InputContext).ReserveCaptureShortcuts then
      FState.Browser.ScreenshotTool.Hint := Translate('Take screenshot')
    else
      FState.Browser.ScreenshotTool.Hint := Translate('Take screenshot · F8');
  end;
  if FState.Browser.HelpTool <> nil then
  begin
    FState.Browser.HelpTool.Enabled := (FState.Session.Emulation <> nil) and not FState.Session.OpeningRom and not FState.Help.Closing;
    if FState.Help.View <> nil then
      FState.Browser.HelpTool.StyleLookup := 'buttonstyle_accent'
    else
      FState.Browser.HelpTool.StyleLookup := 'buttonstyle';
    var Color: TAlphaColor := $FFFFB43B;
    if FState.Help.View <> nil then
      Color := $FF1B2026;
    FState.Browser.HelpTool.TextSettings.FontColor := Color;
    for var Child in FState.Browser.HelpTool.Children do
      if Child is FMX.Objects.TPath then
        FMX.Objects.TPath(Child).Stroke.Color := Color;
  end;

  {$IFNDEF ISMOBILE}
  if FView.FullScreen then
  begin
    // SyncActivity and frame/status updates can make controls visible again.
    // Hide game chrome while retaining the pause overlay.
    for var Child in FView.LayoutClient.Children do
      if (Child is TControl) and (Child <> FView.ImageCanvas) and (Child <> FView.RectangleBG) and (Child <> FView.LabelPaused) then
        TControl(Child).Visible := False;
    FView.ImageLogo.Visible := False;
  end;
  {$ENDIF}

  FView.UpdatePauseOverlay;
end;

procedure TBrowserController.SetStatus(const Text: string);
begin
  FView.Caption := AppName;

  {$IFDEF ISMOBILE}
  FView.LabelStatus.Text := Text;
  {$ELSE}

  FView.LabelStatus.Text := Text;
  if FState.Session.Emulation <> nil then
    FView.LabelStatus.Text := FState.Session.RomDisplayName;
  FView.UpdateGameChrome;
  if FState.Browser.View <> nil then
    FView.FormResize(FView);
  {$ENDIF}
end;

procedure TBrowserController.LayoutClientClick(Sender: TObject);
begin
  FView.LayoutClient.SetFocus;
end;

procedure TBrowserController.LayoutClientDblClick(Sender: TObject);
begin
  {$IFDEF ISMOBILE}
  Exit;
  {$ENDIF}
  FView.SwitchFullScreen;
end;

end.

