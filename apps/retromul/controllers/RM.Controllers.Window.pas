unit RM.Controllers.Window;

{$I ..\RM.Mobile.inc}

interface

uses
  System.Types, RM.Controllers.Base;

type
  TWindowController = class(TMainController)
  public
    procedure FormResize(Sender: TObject);
    procedure ApplyControlInset;
    procedure FormSafeAreaChanged(Sender: TObject; const AInsets: TRectF);
    {$IFDEF MSWINDOWS}
    procedure RestoreWindowState;
    {$ENDIF}
    {$IFDEF MSWINDOWS}
    procedure SaveWindowState;
    {$ENDIF}
    procedure FullscreenClick(Sender: TObject);
    procedure SwitchFullScreen;
  end;

implementation

uses
  System.SysUtils, System.Classes, System.Math, System.UITypes, FMX.Types,
  FMX.Forms, FMX.Objects, FMX.StdCtrls, FMX.Layouts, RM.Toolbar, RM.Gamepad,
  SG1000.Keyboard, NES.SuborKeyboard, NES.FamicomKeyboard, NES.MiraclePiano, NES.PowerPad,
  NES.DataRecorder, RM.Styles, RM.Gamepad.Viewport
  {$IFDEF MSWINDOWS}
    , Winapi.Windows, Winapi.MultiMon, FMX.Platform.Win, FMX.Helpers.Win
  {$ENDIF};

procedure TWindowController.FormResize(Sender: TObject);
begin
  if csDestroying in FView.ComponentState then
    Exit;

  {$IFDEF ISMOBILE}
  if FState.Browser.ActionsTool <> nil then
  begin
    var Actions := FView.FindComponent('LayoutGameActions') as TLayout;
    Actions.Width := 196;
    FState.Browser.ActionsTool.Parent := Actions;
    FState.Browser.ActionsTool.Align := TAlignLayout.Right;
    FState.Browser.ActionsTool.Width := 60;
    FState.Browser.ActionsTool.Margins.Rect := TRectF.Empty;
    FView.GamePause.Parent := Actions;
    FView.GamePause.Align := TAlignLayout.Right;
    FView.GamePause.Width := 60;
    FView.GamePause.Margins.Rect := TRectF.Create(0, 0, 8, 0);
    FView.ButtonReset.Align := TAlignLayout.Right;
    FView.ButtonReset.Width := 60;
    FView.ButtonReset.Text := '';
    FView.ButtonReset.Margins.Rect := TRectF.Create(0, 0, 8, 0);
    for var Child in FView.ButtonReset.Children do
      if Child is TPath then
      begin
        TPath(Child).Align := TAlignLayout.Center;
        TPath(Child).Margins.Rect := TRectF.Empty;
      end;
    FView.LabelStatus.Align := TAlignLayout.Client;
  end;
  {$ENDIF}

  if (FState.Browser.BackTool <> nil) and (FState.Browser.HelpTool <> nil) then
  begin
    var HasCoin := (FState.Browser.CoinTool <> nil) and FState.Browser.CoinTool.Visible;
    var Narrow := FView.LayoutHead.Width < IfThen(HasCoin, 1420, 1220);
    var Compact := FView.LayoutHead.Width < IfThen(HasCoin, 820, 740);
    var ActionLayout := FView.FindComponent('LayoutGameActions') as TLayout;
    var Identity := FView.FindComponent('LayoutGameIdentity') as TLayout;
    ActionLayout.BeginUpdate;
    var Actions: TArray<TButton> := [
        FState.Browser.Tools[0], FView.ButtonReset, FState.Browser.Tools[1],
        FState.Browser.Tools[3], FState.Browser.Tools[4], FState.Browser.HelpTool, FView.GameActionsButton];
    var Widths: TArray<Single> := [130, 130, 164, 44, 44, 88, 60];
    if HasCoin then
    begin
      Actions := [
          FState.Browser.Tools[0], FView.ButtonReset, FState.Browser.CoinTool, FState.Browser.Tools[1],
          FState.Browser.Tools[3], FState.Browser.Tools[4], FState.Browser.HelpTool, FView.GameActionsButton];
      Widths := [130, 130, 188, 164, 44, 44, 88, 60];
    end;
    if Narrow and Compact then
    begin
      var Minimum: Single := 0;
      for var i := 0 to High(Actions) do
      begin
        Widths[i] := 32;
        if Actions[i] is TToolbarSplitButton then
          Widths[i] := 48;
        if i = 0 then
          Widths[i] := 58;
        Minimum := Minimum + Widths[i];
      end;
      var Extra := Max(0, (FView.LayoutHead.Width - 16 - (Length(Actions) - 1) * 6 - Minimum) / Length(Actions));
      for var i := 0 to High(Widths) do
        Widths[i] := Widths[i] + Extra;
    end;
    var Total: Single := (Length(Actions) - 1) * 8;
    for var W in Widths do
      Total := Total + W;
    FView.LayoutHead.Padding.Rect := TRectF.Create(8,8,8,8);
    FView.LayoutHead.Height := IfThen(Narrow,112,64);
    ActionLayout.Align := TAlignLayout.Right;
    ActionLayout.Width := Total;
    ActionLayout.Margins.Rect := TRectF.Create(16,4,0,4);
    if Narrow then
    begin
      ActionLayout.Align := TAlignLayout.Bottom;
      ActionLayout.Height := 40;
      ActionLayout.Margins.Rect := TRectF.Create(0,8,0,0);
    end;
    Identity.Align := TAlignLayout.Client;
    FState.Browser.BackTool.Align := TAlignLayout.Left;
    FState.Browser.BackTool.Width := 156;
    FState.Browser.BackTool.Margins.Rect := TRectF.Create(0,0,20,8);
    FView.LabelStatus.Align := TAlignLayout.Top;
    FView.LabelStatus.Height := 26;
    FState.Browser.GamePlatform.Align := TAlignLayout.Client;
    for var i := 0 to High(Actions) do
    begin
      var W := Widths[i];
      if Narrow and not Compact then
      begin
        W := (FView.LayoutHead.Width - 16 - (Length(Actions) - 1) * 6) / Length(Actions);
        if i = 0 then
          W := Max(32, W) + 26
        else
          W := Max(32, W - 26 / (Length(Actions) - 1));
      end;
      Actions[i].Parent := ActionLayout;
      Actions[i].Align := TAlignLayout.Left;
      Actions[i].Width := W;
      Actions[i].Margins.Rect := TRectF.Create(0,0,IfThen(Narrow,6,8),0);
      if I = High(Actions) then Actions[I].Margins.Right := 0;
      Actions[i].Position.X := I * 200; // Left-alignment ordering key.

    end;
    ActionLayout.EndUpdate;
    if (FState.Session.Emulation <> nil) and (FState.Session.UserPaused or FState.Session.AutoPaused) then
      FState.Browser.Tools[0].Text := Translate('Resume')
    else
      FState.Browser.Tools[0].Text := Translate('Pause');
    FView.ButtonReset.Text := Translate('Reset');
    FState.Browser.Tools[1].Text := Translate('Save');
    if HasCoin then
      FState.Browser.CoinTool.Text := Translate('Insert coin');
    FState.Browser.Tools[3].Text := '';
    FState.Browser.Tools[4].Text := '';
    FState.Browser.HelpTool.Text := 'F1';
    for var i := 0 to High(Actions) do
    begin
      if Compact or ((Actions[i] = FState.Browser.CoinTool) and (Actions[i].Width < 180)) then
        Actions[i].Text := '';
      for var Child in Actions[i].Children do
        if Child is FMX.Objects.TPath then
        begin
          var Icon := FMX.Objects.TPath(Child);
          Icon.BeginUpdate;
          try
            Icon.Margins.Rect := TRectF.Empty;
            if Actions[i].Text = '' then
              // Right-aligned menu arrows already reserve their own width.
              Icon.Align := TAlignLayout.Center
            else
            begin
              Icon.Align := TAlignLayout.LeftCenter;
              Icon.Margins.Left := 12;
            end;
            Icon.Width := 20;
            Icon.Height := 20;
          finally
            Icon.EndUpdate;
          end;
        end;
    end;
  end;
  if FState.Input.MiraclePiano <> nil then
    FState.Input.MiraclePiano.Height := TNesMiraclePiano.PreferredHeight(FView.LayoutClient.Width,
      FView.ClientHeight - FView.Padding.Top - FView.Padding.Bottom - FView.LayoutHead.Height);
  if FState.Input.DataRecorder <> nil then
    FState.Input.DataRecorder.Height := TNesDataRecorder.PreferredHeight(FView.LayoutClient.Width,
      FView.ClientHeight - FView.Padding.Top - FView.Padding.Bottom - FView.LayoutHead.Height);
  if FState.Input.PowerPad <> nil then
    FState.Input.PowerPad.Height := TNesPowerPad.PreferredHeight(FView.LayoutClient.Width,
      FView.ClientHeight - FView.Padding.Top - FView.Padding.Bottom - FView.LayoutHead.Height);
  if FState.Input.Gamepad <> nil then
  begin
    FState.Input.Gamepad.Height := TScreenGamepad.PreferredHeight(
      FView.ClientWidth - FView.Padding.Left - FView.Padding.Right,
      FView.ClientHeight - FView.Padding.Top - FView.Padding.Bottom - FView.LayoutHead.Height);
  end;
  if FState.Input.SGKeyboard <> nil then
    FState.Input.SGKeyboard.Height := TSGKeyboard.PreferredHeight(
      FView.ClientWidth - FView.Padding.Left - FView.Padding.Right,
      FView.ClientHeight - FView.Padding.Top - FView.Padding.Bottom - FView.LayoutHead.Height);
  if FState.Input.SuborKeyboard <> nil then
  begin
    FState.Input.SuborKeyboard.Height := TNesSuborKeyboard.PreferredHeight(
      FView.ClientWidth - FView.Padding.Left - FView.Padding.Right,
      FView.ClientHeight - FView.Padding.Top - FView.Padding.Bottom - FView.LayoutHead.Height);
  end;
  if FState.Input.FamicomKeyboard <> nil then
    FState.Input.FamicomKeyboard.Height := TNesFamicomKeyboard.PreferredHeight(
      FView.ClientWidth - FView.Padding.Left - FView.Padding.Right,
      FView.ClientHeight - FView.Padding.Top - FView.Padding.Bottom - FView.LayoutHead.Height);
  {$IFDEF ISMOBILE}
  ArrangeVirtualGamepads(FState.Input.Gamepad, FState.Input.PowerPad, FView.ImageCanvas);
  if FView.LayoutShowPanel.Visible then
    FView.LayoutShowPanel.BringToFront;
  if FView.GameActionsPopup.IsOpen then
    FView.UpdateGameChrome;
  {$ENDIF}
end;

procedure TWindowController.ApplyControlInset;
begin
  if FState.Input.Gamepad <> nil then
    FState.Input.Gamepad.Margins.Bottom := FState.Input.BottomInset;
  if FState.Input.PowerPad <> nil then
    FState.Input.PowerPad.Margins.Bottom := FState.Input.BottomInset;
  if FState.Input.SuborKeyboard <> nil then
    FState.Input.SuborKeyboard.Margins.Bottom := FState.Input.BottomInset;
  if FState.Input.SGKeyboard <> nil then FState.Input.SGKeyboard.Margins.Bottom := FState.Input.BottomInset;
  if FState.Input.FamicomKeyboard <> nil then
    FState.Input.FamicomKeyboard.Margins.Bottom := FState.Input.BottomInset;
  if FState.Input.MiraclePiano <> nil then
    FState.Input.MiraclePiano.Margins.Bottom := FState.Input.BottomInset;
end;

procedure TWindowController.FormSafeAreaChanged(Sender: TObject; const AInsets: TRectF);
begin
  FView.Padding.Left := AInsets.Left;
  FView.Padding.Top := AInsets.Top;
  FView.Padding.Right := AInsets.Right;
  FView.Padding.Bottom := AInsets.Bottom;
  FView.FormResize(FView);
end;

{$IFDEF MSWINDOWS}
procedure TWindowController.RestoreWindowState;
begin
  var Ini := FState.Session.Storage.ReadConfig(FState.Session.Storage.ConfigFile('config'));
  try
    if not (Ini.ValueExists('Window', 'Left') and Ini.ValueExists('Window', 'Top') and
      Ini.ValueExists('Window', 'Width') and Ini.ValueExists('Window', 'Height')) then
      Exit;

    var X := Ini.ReadInteger('Window', 'Left', 0);
    var Y := Ini.ReadInteger('Window', 'Top', 0);
    var W := Ini.ReadInteger('Window', 'Width', 0);
    var H := Ini.ReadInteger('Window', 'Height', 0);

    if (W <= 0) or (H <= 0) or (W > 1000000) or (H > 1000000) or
      (Abs(Int64(X)) > 1000000) or (Abs(Int64(Y)) > 1000000) then
      Exit;

    var Bounds := TRect.Create(X, Y, X + W, Y + H);
    var Monitor := Default(TMonitorInfo);
    Monitor.cbSize := SizeOf(Monitor);
    if not GetMonitorInfo(MonitorFromRect(@Bounds, MONITOR_DEFAULTTONEAREST), @Monitor) then
      Exit;

    var Wnd := WindowHandleToPlatform(FView.Handle).Wnd;
    var Scale := FMX.Helpers.Win.GetWndScale(Wnd);
    if Scale <= 0 then
      Scale := 1;
    W := Min(Max(W, Round(FView.Constraints.MinWidth * Scale)), Monitor.rcWork.Width);
    H := Min(Max(H, Round(FView.Constraints.MinHeight * Scale)), Monitor.rcWork.Height);
    X := EnsureRange(X, Monitor.rcWork.Left, Monitor.rcWork.Right - W);
    Y := EnsureRange(Y, Monitor.rcWork.Top, Monitor.rcWork.Bottom - H);
    Bounds := TRect.Create(X, Y, X + W, Y + H);

    // WINDOWPLACEMENT uses workspace coordinates, not screen coordinates.
    OffsetRect(Bounds, Monitor.rcMonitor.Left - Monitor.rcWork.Left, Monitor.rcMonitor.Top - Monitor.rcWork.Top);
    var Placement := Default(TWindowPlacement);
    Placement.length := SizeOf(Placement);
    Placement.rcNormalPosition := Bounds;
    if Ini.ReadBool('Window', 'Maximized', False) then
      Placement.showCmd := SW_SHOWMAXIMIZED
    else
      Placement.showCmd := SW_SHOWNORMAL;
    FView.Position := TFormPosition.Designed;
    SetWindowPlacement(Wnd, @Placement);
  finally
    Ini.Free;
  end;
end;

procedure TWindowController.SaveWindowState;
begin
  if not FState.Window.WindowStateRestored or (FState.Session.Storage = nil) then
    Exit;

  var Placement := Default(TWindowPlacement);
  Placement.length := SizeOf(Placement);
  // Fullscreen is temporary gameplay UI: preserve its original window placement.
  if FView.FullScreen and (FState.Window.FullScreenPlacement.length <> 0) then
    Placement := FState.Window.FullScreenPlacement
  else if not GetWindowPlacement(WindowHandleToPlatform(FView.Handle).Wnd, @Placement) then
    Exit;

  var Bounds := Placement.rcNormalPosition;
  if (Bounds.Width <= 0) or (Bounds.Height <= 0) then
    Exit;

  var Monitor := Default(TMonitorInfo);
  Monitor.cbSize := SizeOf(Monitor);
  if GetMonitorInfo(MonitorFromRect(@Bounds, MONITOR_DEFAULTTONEAREST), @Monitor) then
    OffsetRect(Bounds, Monitor.rcWork.Left - Monitor.rcMonitor.Left,
      Monitor.rcWork.Top - Monitor.rcMonitor.Top);
  var Maximized := (Placement.showCmd = SW_SHOWMAXIMIZED) or
    ((Placement.showCmd = SW_SHOWMINIMIZED) and ((Placement.flags and WPF_RESTORETOMAXIMIZED) <> 0));
  var Ini := FState.Session.Storage.ReadConfig(FState.Session.Storage.ConfigFile('config'));
  try
    Ini.WriteInteger('Window', 'Left', Bounds.Left);
    Ini.WriteInteger('Window', 'Top', Bounds.Top);
    Ini.WriteInteger('Window', 'Width', Bounds.Width);
    Ini.WriteInteger('Window', 'Height', Bounds.Height);
    Ini.WriteBool('Window', 'Maximized', Maximized);
    FState.Session.Storage.WriteConfig(Ini);
    FState.Window.WindowStateSaved := True;
  finally
    Ini.Free;
  end;
end;
{$ENDIF}

procedure TWindowController.FullscreenClick(Sender: TObject);
begin
  FView.SwitchFullScreen;
end;

procedure TWindowController.SwitchFullScreen;
begin
  if (FState.Session.Emulation = nil) or FState.Browser.ViewingLibrary or (FState.Settings.View <> nil) or (FState.Help.View <> nil) then
    Exit;
  {$IFNDEF ISMOBILE}
  if not FView.FullScreen then
    FState.Browser.FullScreenPadding := FView.Padding.Rect;
  {$ENDIF}

  {$IFDEF MSWINDOWS}
  if not FView.FullScreen then
  begin
    FState.Window.FullScreenBorderStyle := FView.BorderStyle;
    FState.Window.FullScreenWindowState := FView.WindowState;
    FState.Window.FullScreenPlacement := Default(TWindowPlacement);
    FState.Window.FullScreenPlacement.length := SizeOf(FState.Window.FullScreenPlacement);
    if not GetWindowPlacement(WindowHandleToPlatform(FView.Handle).Wnd, @FState.Window.FullScreenPlacement) then
      FState.Window.FullScreenPlacement.length := 0;
  end;
  {$ENDIF}

  FView.FullScreen := not FView.FullScreen;

  {$IFDEF MSWINDOWS}
  if not FView.FullScreen then
  begin
    // FMX skips restoring the frame when the first fullscreen entry is from
    // a maximized window, because its saved normal size is still empty.
    FView.BorderStyle := FState.Window.FullScreenBorderStyle;
    FView.WindowState := FState.Window.FullScreenWindowState;
    // Restoring BorderStyle recreates the HWND. Preserve its normal restore
    // rectangle too, including when fullscreen was entered while maximized.
    if FState.Window.FullScreenPlacement.length <> 0 then
      SetWindowPlacement(WindowHandleToPlatform(FView.Handle).Wnd, @FState.Window.FullScreenPlacement);
    FView.UpdateSystemBackdropType;
  end;
  {$ENDIF}

  {$IFNDEF ISMOBILE}
  if FView.FullScreen then
    FView.Padding.Rect := TRectF.Empty
  else
    FView.Padding.Rect := FState.Browser.FullScreenPadding;
  {$ENDIF}

  {$IFDEF ISMOBILE}
  // The game tab owns its toolbar as well as the canvas.
  FView.LayoutClient.Visible := True;
  {$ENDIF}

  if FView.FullScreen then
  begin
    FView.LayoutClient.Cursor := crNone;
    FView.LayoutClient.SetFocus;
  end
  else
    FView.LayoutClient.Cursor := crDefault;
  FView.SyncActivity;
  FState.Input.SuppressInputUntilRelease := True;
  FState.Input.KeysDown[vkF11] := True;
end;

end.

