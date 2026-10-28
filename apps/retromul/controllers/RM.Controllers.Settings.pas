unit RM.Controllers.Settings;

{$I ..\RM.Mobile.inc}

interface

uses
  RM.Platforms.Presentation, RM.Controllers.Base, RM.Settings.Runtime;

type
  TSettingsController = class(TMainController)
  private
    function RuntimeContext: TSettingsRuntimeContext;
  public
    procedure Load;
    procedure Save;
    procedure SettingsClick(Sender: TObject);
    procedure SettingsApplied(Sender: TObject);
    procedure SettingsClose(Sender: TObject);
    procedure ControlsHelpClick(Sender: TObject);
    procedure ControlsHelpClose(Sender: TObject);
    procedure ControlsHelpSettings(Sender: TObject);
    procedure CloseControlsHelp(OpenSettings: Boolean = False);
  end;

implementation

uses
  System.SysUtils, System.Classes, System.Math, System.UITypes, FMX.Types,
  RM.Gamepad, RM.Settings, RM.ControlsHelp, RM.Styles, RM.Dialogs,
  RM.Gamepad.Base;

function TSettingsController.RuntimeContext: TSettingsRuntimeContext;
begin
  Result := Default(TSettingsRuntimeContext);
  Result.View := FView;
  Result.State := FState;
end;

procedure TSettingsController.Load;
begin
  var Ini := FState.Session.Storage.ReadConfig(FState.Session.Storage.ConfigFile('config'));
  try
    var PreviousLanguage := FormStyles.Lang.Lang;
    var FirstLaunch := not Ini.ValueExists('General', 'Language');
    var Language := Ini.ReadString('General', 'Language', 'en');
    if FirstLaunch then
      Language := FView.SystemLanguage;
    var Translation: TStringList := nil;
    var TranslationError := '';
    try
      try
        Translation := FormStyles.LoadTranslation(FState.Session.Storage,
          Ini.ReadString('General', 'TranslationFile', '').Trim, Language);
      except
        on E: Exception do
          TranslationError := E.Message;
      end;
      FormStyles.SetLanguage(Language, Translation);
    finally
      Translation.Free;
    end;
    if FirstLaunch then
    begin
      Ini.WriteString('General', 'Language', FormStyles.SelectedLanguage);
      FState.Session.Storage.WriteConfig(Ini);
    end;
    if PreviousLanguage <> FormStyles.Lang.Lang then
    begin
      FormStyles.RelocalizeUI(FView.LayoutClient, PreviousLanguage);
      if FState.Browser.View <> nil then
        if FState.Browser.ViewingLibrary then
          FState.Browser.View.ApplyLanguage(PreviousLanguage)
        else if FState.Browser.PendingLanguage = '' then
          FState.Browser.PendingLanguage := PreviousLanguage;
      if FState.Settings.View <> nil then
        FState.Settings.View.ApplyLanguage(PreviousLanguage);
      if FState.Session.Emulation = nil then
        FView.SetStatus(Translate('Open ROM'));
    end;
    FState.Input.BottomInset := EnsureRange(Ini.ReadInteger('General', 'ControlBottomInset', 100), 0, 400);
    FView.ApplyControlInset;
    FState.Input.Gamepad.LayoutScale := EnsureRange(
      Ini.ReadInteger('General', 'GamepadScale', 100), 50, 200) / 100;
    TVirtualGamepadControl.TouchHapticsEnabled := Ini.ReadBool('General', 'TouchHaptics', True);
    FState.Preferences.PauseOnFocusLoss := Ini.ReadBool('General', 'PauseOnFocusLoss', True);
    FState.Preferences.StartFullscreen := Ini.ReadBool('General', 'StartFullscreen', False);
    FState.Autosave.OnExit := Ini.ReadBool('General', 'AutosaveOnExit', True);
    FState.Autosave.Periodic := Ini.ReadBool('General', 'AutosavePeriodic', False);
    FState.Autosave.Minutes := EnsureRange(Ini.ReadInteger('General', 'AutosaveMinutes',
        AUTOSAVE_DEFAULT_MINUTES), 1, AUTOSAVE_MAX_MINUTES);
    FState.Autosave.LastTick := FView.CurrentTick;
    if TranslationError <> '' then
      FView.SetStatus(Translate('Unable to load translation: ') + TranslationError);
  finally
    Ini.Free;
  end;
end;

procedure TSettingsController.Save;
begin
  var Ini := FState.Session.Storage.ReadConfig(FState.Session.Storage.ConfigFile('config'));
  try
    Ini.WriteInteger('General', 'ControlBottomInset', FState.Input.BottomInset);
    FState.Session.Storage.WriteConfig(Ini);
  finally
    Ini.Free;
  end;
end;

procedure TSettingsController.SettingsClick(Sender: TObject);
begin
  if FState.Help.View <> nil then
  begin
    FView.CloseControlsHelp(True);
    Exit;
  end;

  if FView.FullScreen then
    FView.SwitchFullScreen;
  if (FState.Settings.View <> nil) or FState.Session.OpeningRom then
    Exit;

  FState.Settings.LibraryVisible := (FState.Browser.View <> nil) and FState.Browser.View.Visible;
  if FState.Browser.View <> nil then
    FState.Browser.View.Visible := False;
  FState.Settings.WasPaused := (FState.Session.Emulation <> nil) and FState.Session.Emulation.IsPaused;
  if FState.Browser.View <> nil then
    FState.Settings.WasPaused := FState.Settings.WasPaused or FState.Browser.ViewingLibrary or
      FState.Session.UserPaused or FState.Session.AutoPaused;
  FView.FormDeactivate(FView);
  if FState.Session.Emulation <> nil then
    FState.Session.Emulation.Pause;
  FState.Settings.ClientVisible := FView.LayoutClient.Visible;
  FState.Settings.View := TSettingsView.CreateSettings(FView, FState.Session.Storage, FState.Input.Manager);
  if (FState.Browser.View <> nil) and
    (Sender = FState.Browser.View.FindComponent('ButtonConfigureLibrary')) then
    FState.Settings.View.SelectCategory(SETTINGS_CATEGORY_LIBRARY)
  else if FState.Session.Emulation <> nil then
    FState.Settings.View.SelectCore(PlatformPresentation(FState.Input.SystemId).SettingsPageId, True);
  FState.Settings.View.Parent := FView.SettingsScreen;
  FView.ScreenTabs.ActiveTab := FView.SettingsScreen;
  FState.Settings.View.Align := TAlignLayout.Client;
  FState.Settings.View.OnApply := FView.SettingsApplied;
  FState.Settings.View.OnClose := FView.SettingsClose;
  FView.LayoutClient.Visible := False;
  FState.Settings.View.BringToFront;
  FView.SyncActivity;

  {$IFDEF ISMOBILE}
  DetachSettingsPeripherals(RuntimeContext);
  {$ENDIF}
end;

procedure TSettingsController.SettingsApplied(Sender: TObject);
begin
  if FState.Session.Emulation <> nil then
  begin
    var Config := FState.Session.Emulation.Config;
    var Ini := FState.Session.Storage.ReadConfig(Config.FileName);
    try
      PlatformSettingsHandler(FState.Input.SystemId).Apply(RuntimeContext, Ini);
      FView.ImageCanvas.LoadSettings(Ini);
      FView.ImageCanvas.DisableInterpolation := SameText(Config.Filter, 'nearest');
      FView.UpdateFrame;
      FView.ImageCanvas.Repaint;
    finally
      Ini.Free;
    end;
  end;
  FView.Load;
  if FState.Browser.View <> nil then
  begin
    FState.Browser.ReloadPending := True;
    if FState.Browser.ViewingLibrary then
    begin
      FState.Browser.View.ApplyPreferences;
      FState.Browser.View.Reload;
      FState.Browser.ReloadPending := False;
    end;
  end;
  FView.ReloadHostInputBindings;
  FView.SyncActivity;
end;

procedure TSettingsController.SettingsClose(Sender: TObject);
begin
  if (FState.Settings.View = nil) or FState.Settings.Closing then
    Exit;

  FState.Settings.Closing := True;
  FState.Settings.View.Visible := False;
  // Release through the UI queue so the clicked button finishes its event first.
  var Alive: TFunc<Boolean> := FState.Session.CallbackAlive;
  TThread.ForceQueue(nil,
    procedure
    begin
      if not Alive() then
        Exit;

      FreeAndNil(FState.Settings.View);
      FState.Settings.Closing := False;
      if FState.Settings.LibraryVisible then
        FView.ScreenTabs.ActiveTab := FView.LibraryScreen
      else
        FView.ScreenTabs.ActiveTab := FView.GameScreen;
      if FState.Browser.View <> nil then
        FState.Browser.View.Visible := FState.Settings.LibraryVisible;
      FView.LayoutClient.Visible := FState.Settings.ClientVisible;
      //LoadSystem(FSystemId);
      FView.ReloadHostInputBindings;
      FState.Input.SuppressInputUntilRelease := True;
      if (FState.Session.Emulation <> nil) and not FState.Settings.WasPaused and
        not FState.Session.UserPaused and not FState.Session.AutoPaused and
        not FState.Session.EmulationFaulted and not FState.Session.OpeningRom and
        not FState.Browser.ViewingLibrary and (FState.Help.View = nil) then
      begin
        // A dialog opened by Apply inherited the settings pause. Transfer the
        // running state to it so dismissal can resume the session later.
        if RetroDialogVisible(FView) and (FState.Session.DialogCore = FState.Session.Emulation) then
          FState.Session.DialogWasPaused := False;
        {$IFNDEF ISMOBILE}
        if FState.Preferences.PauseOnFocusLoss and not FView.InputHasFocus and not RetroDialogVisible(FView) then
          FState.Session.AutoPaused := True
        else
        {$ENDIF}
          if not RetroDialogVisible(FView)
          {$IFDEF ISMOBILE} and not FState.Mobile.InBackground{$ENDIF} then
          FState.Session.Emulation.Resume;
      end;
      FView.SyncActivity;

      {$IFDEF ISMOBILE}
      FView.FormActivate(FView);
      {$ENDIF}

      if FView.LayoutClient.Visible then
        FView.LayoutClient.SetFocus;
    end);
end;

procedure TSettingsController.ControlsHelpClick(Sender: TObject);
begin
  if FState.Help.View <> nil then
  begin
    FView.ControlsHelpClose(FView);
    Exit;
  end;

  if (FState.Session.Emulation = nil) or FState.Browser.ViewingLibrary or (FState.Settings.View <> nil) or FState.Session.OpeningRom or FState.Help.Closing then
    Exit;

  FState.Help.WasPaused := FState.Session.Emulation.IsPaused or FState.Session.UserPaused or FState.Session.AutoPaused;
  FView.FormDeactivate(FView);
  FState.Session.Emulation.Pause;
  var HelpInfo := PlatformSettingsHandler(FState.Input.SystemId).HelpInfo(RuntimeContext);
  try
    FState.Help.View := TControlsHelpView.CreateHelp(FView, FState.Input.Manager, FState.Input.SystemId, FState.Input.Ports, HelpInfo.Players, HelpInfo.KeyboardPeripheral, FState.Session.Storage, FState.Session.Emulation.HasCoinAcceptor);
    FState.Help.View.Parent := FView;
    FState.Help.View.Align := TAlignLayout.Contents;
    FState.Help.View.OnClose := FView.ControlsHelpClose;
    FState.Help.View.OnSettings := FView.ControlsHelpSettings;
    FState.Help.View.BringToFront;
  except
    FreeAndNil(FState.Help.View);
    if not FState.Help.WasPaused then
      FState.Session.Emulation.Resume;
    raise;
  end;

  FState.Input.KeysDown[vkF1] := True;
  FView.SyncActivity;
end;

procedure TSettingsController.ControlsHelpClose(Sender: TObject);
begin
  FView.CloseControlsHelp;
end;

procedure TSettingsController.ControlsHelpSettings(Sender: TObject);
begin
  FView.CloseControlsHelp(True);
end;

procedure TSettingsController.CloseControlsHelp(OpenSettings: Boolean);
begin
  if (FState.Help.View = nil) or FState.Help.Closing then
    Exit;

  FState.Help.Closing := True;
  var Alive: TFunc<Boolean> := FState.Session.CallbackAlive;
  TThread.ForceQueue(nil,
    procedure
    begin
      if not Alive() then
        Exit;

      FreeAndNil(FState.Help.View);
      FState.Help.Closing := False;
      if (FState.Session.Emulation <> nil) and
        not FState.Help.WasPaused and
        not FState.Session.UserPaused and
        not FState.Session.AutoPaused and
        not FState.Session.EmulationFaulted and
        FView.InputHasFocus then
        FState.Session.Emulation.Resume;
      FState.Input.SuppressInputUntilRelease := True;
      FillChar(FState.Input.KeysDown, SizeOf(FState.Input.KeysDown), 0);
      if OpenSettings then
      begin
        FView.SettingsClick(FView);
        if FState.Settings.View <> nil then
        begin
          FState.Settings.View.SelectCore(PlatformPresentation(FState.Input.SystemId).SettingsPageId);
          FState.Settings.View.SelectCategory(SETTINGS_CATEGORY_CONTROLS);
        end;
      end
      else
      begin
        FView.FormActivate(FView);
        FView.LayoutClient.SetFocus;
      end;
      FView.SyncActivity;
    end);
end;

end.

