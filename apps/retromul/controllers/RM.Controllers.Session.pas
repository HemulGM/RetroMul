unit RM.Controllers.Session;

{$I ..\RM.Mobile.inc}

interface

uses
  RM.BitmapShaders, RM.Platforms.Presentation, System.SysUtils, FMX.Types,
  Core.Emulation, RM.Controllers.Base, RM.Session.Runtime;

type
  TSessionController = class(TMainController)
  private
    FLoadingCore: Boolean;
    FLoadGeneration: Integer;
    FCancelLoad: TProc;
    function RuntimeContext: TSessionRuntimeContext;
    procedure UpdateVirtualButtons;
    procedure EndCoreLoading;
    procedure CancelCoreLoading;
    procedure BeginGameLoading(const FileName, DisplayName: string; StartPaused: Boolean; const SnapshotName: string);
    procedure InstallCore(const NewEmulation: IEmulationCore; const FileName, DisplayName: string; StartPaused: Boolean);
  public
    destructor Destroy; override;
    procedure DisconnectSession;
    procedure FormActivate(Sender: TObject);
    procedure FormDeactivate(Sender: TObject);
    procedure ApplicationException(Sender: TObject; E: Exception);
    procedure DialogActivityChanged(Sender: TObject);
    procedure SyncActivity;
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
    procedure FormSaveState(Sender: TObject);
    procedure ButtonOpenClick(Sender: TObject);
    procedure OpenRom;
    procedure SelectDocument(ForCassette: Boolean; const FileName: string = '');
    procedure FinishFileSelection;
    function CanAcceptRomDrop(const Data: TDragObject): Boolean;
    procedure LoadRom(const FileName: string; const DisplayName: string = ''; StartPaused: Boolean = False; const SnapshotName: string = '');
    procedure ResetConsole(Hard: Boolean);
    procedure HardRestart;
    procedure ButtonCloseRomClick(Sender: TObject);
    procedure Stop;
    procedure StopOnError;
    procedure TimerUpdateTimer(Sender: TObject);
    function UpdateFrame: Boolean;
    procedure PauseClick(Sender: TObject);
    procedure SwitchPause;
    procedure UpdatePauseOverlay;
    procedure InsertCoinClick(Sender: TObject);
  end;

implementation

uses
  System.Classes, System.SyncObjs, System.UITypes, System.Math, RM.Input,
  System.IOUtils, FMX.Forms, FMX.Objects, FMX.Graphics, FMX.OpenDialog,
  Core.Storage, Core.EmulatorFactory, Core.InputConfig, Core.Platforms,
  Core.PlatformServices, RM.Gamepad, RM.FrameUpload, RM.Dialogs, RM.Styles,
  Core.SavePaths;

function NewLoadCancellation(out CancelLoad: TProc): TProc;
begin
  // A separate closure frame contains only the shared flag. Read streams can
  // retain the check without retaining the form, worker or loaded core.
  var Cancelled: Integer := 0;
  CancelLoad :=
    procedure
    begin
      TInterlocked.Exchange(Cancelled, 1);
    end;
  Result :=
    procedure
    begin
      if TInterlocked.CompareExchange(Cancelled, 0, 0) <> 0 then
        raise EAbort.Create('Game loading cancelled');
    end;
end;

destructor TSessionController.Destroy;
begin
  if Assigned(FCancelLoad) then
    FCancelLoad();
  inherited;
end;

function TSessionController.RuntimeContext: TSessionRuntimeContext;
begin
  Result := Default(TSessionRuntimeContext);
  Result.View := FView;
  Result.State := FState;
end;

procedure TSessionController.DisconnectSession;
begin
  DetachSessionTouch(RuntimeContext);
  PlatformSessionHandler(FState.Input.SystemId).Disconnect(RuntimeContext);
end;

procedure TSessionController.FormActivate(Sender: TObject);
begin
  if FState.Session.OpeningRom then
    Exit;

  if FState.Session.AutoPaused and FView.InputHasFocus and not FState.Session.UserPaused and not FState.Browser.ViewingLibrary and
    not RetroDialogVisible(FView) and (FState.Settings.View = nil) and (FState.Help.View = nil) then
  begin
    FState.Session.AutoPaused := False;
    if (FState.Session.Emulation <> nil) and not FState.Session.EmulationFaulted then
      FState.Session.Emulation.Resume;
  end;

  FState.Input.SuppressInputUntilRelease := True;
  {$IFDEF ANDROID}
  ReattachSessionTouch(RuntimeContext);
  {$ENDIF}
  FView.SyncActivity;
end;

procedure TSessionController.FormDeactivate(Sender: TObject);
begin
  if FState.Input.Rumble <> nil then
    FState.Input.Rumble.Stop;

  {$IFNDEF ISMOBILE}
  if FState.Preferences.PauseOnFocusLoss and not FView.InputHasFocus and not FState.Browser.ViewingLibrary and
    not RetroDialogVisible(FView) and (FState.Settings.View = nil) and
    (FState.Session.Emulation <> nil) and not FState.Session.Emulation.IsPaused then
  begin
    FState.Session.AutoPaused := True;
    FState.Session.Emulation.Pause;
  end;
  {$ENDIF}

  // Release keys whose key-up may be lost. Mobile lifecycle controls pausing.
  FillChar(FState.Input.KeysDown, SizeOf(FState.Input.KeysDown), 0);
  FState.Input.SuppressInputUntilRelease := True;
  if FState.Input.Manager <> nil then
    FState.Input.Manager.Enabled := False;
  if FState.Settings.View <> nil then
    FState.Settings.View.CancelCapture;
  if FState.Input.Gamepad <> nil then
    FState.Input.Gamepad.ReleaseAll;
  ReleaseSessionInputs(RuntimeContext);
  if FState.Session.Emulation <> nil then
    FState.Session.Emulation.ClearInput;
  FState.Input.GamepadInput := Default(TEmulatorInput);
  {$IFNDEF ISMOBILE}
  if not (csDestroying in FView.ComponentState) then
    FView.SyncActivity;
  {$ENDIF}
end;

procedure TSessionController.ApplicationException(Sender: TObject; E: Exception);
begin
  if not (E is EAbort) then
  begin
    var MessageText := E.Message;
    if MessageText.Trim = '' then
      MessageText := E.ClassName;
    ShowRetroMessage(FView, MessageText);
  end;
end;

procedure TSessionController.DialogActivityChanged(Sender: TObject);
begin
  if RetroDialogVisible(FView) then
  begin
    FState.Session.DialogCore := FState.Session.Emulation;
    FState.Session.DialogWasPaused := (FState.Session.Emulation = nil) or FState.Session.Emulation.IsPaused;
    FView.FormDeactivate(FView);
    if (FState.Session.Emulation <> nil) and not FState.Session.EmulationFaulted then
      FState.Session.Emulation.Pause;
  end
  else
  begin
    FState.Input.SuppressInputUntilRelease := True;
    FillChar(FState.Input.KeysDown, SizeOf(FState.Input.KeysDown), 0);
    if (FState.Session.DialogCore <> nil) and (FState.Session.DialogCore = FState.Session.Emulation) and
      not FState.Session.DialogWasPaused and not FState.Session.EmulationFaulted and not FState.Session.UserPaused and
      not FState.Session.AutoPaused and {$IFDEF ISMOBILE}not FState.Mobile.InBackground and {$ENDIF} not FState.Session.OpeningRom and
      not FState.Browser.ViewingLibrary and (FState.Settings.View = nil) and (FState.Help.View = nil) then
    begin
      {$IFNDEF ISMOBILE}
      if FState.Preferences.PauseOnFocusLoss and not FView.InputHasFocus then
        FState.Session.AutoPaused := True
      else
      {$ENDIF}
        FState.Session.Emulation.Resume;
    end;
    FState.Session.DialogCore := nil;
  end;
  FView.SyncActivity;
end;

procedure TSessionController.UpdateVirtualButtons;
begin
  if (FState.Input.Gamepad <> nil) and (FState.Session.Emulation <> nil) then
  begin
    var Controls: IEmulationVirtualControls;
    if Supports(FState.Session.Emulation, IEmulationVirtualControls, Controls) then
      FState.Input.Gamepad.ButtonMask := Controls.GetVirtualButtons;
  end;
end;

procedure TSessionController.SyncActivity;
begin
  UpdateVirtualButtons;
  if RetroDialogVisible(FView) and (FState.Session.Emulation <> nil) and (FState.Session.DialogCore <> FState.Session.Emulation) then
  begin
    // A queued message may survive loading a new session.
    FState.Session.DialogCore := FState.Session.Emulation;
    FState.Session.DialogWasPaused := FState.Session.UserPaused;
    FState.Session.Emulation.Pause;
  end;
  FView.ButtonReset.Enabled := (FState.Session.Emulation <> nil) and not FState.Session.OpeningRom and
    not FState.Session.PendingAutosaveChoice and not FState.Browser.ViewingLibrary and
    (FState.Settings.View = nil) and (FState.Help.View = nil);
  FView.GamePause.Enabled := (FState.Session.Emulation <> nil) and not FState.Session.EmulationFaulted and not FState.Session.OpeningRom;
  var UserPaused := (FState.Session.Emulation <> nil) and (FState.Session.UserPaused or FState.Session.AutoPaused);
  FView.GamePauseIcon.Visible := not UserPaused;
  FView.GameResumeIcon.Visible := UserPaused;
  if UserPaused then
  begin
    FView.GamePause.Hint := Translate('Resume');
    FView.GamePause.StyleLookup := 'buttonstyle_accent';
    FView.GamePause.TextSettings.FontColor := $FF1B2026;
  end
  else
  begin
    FView.GamePause.Hint := Translate('Pause');
    FView.GamePause.StyleLookup := 'buttonstyle';
    FView.GamePause.TextSettings.FontColor := $FFE8ECF1;
  end;
  {$IFNDEF ISMOBILE}
  if FView.GamePauseIcon.Align = TAlignLayout.Center then
    FView.GamePause.Text := ''
  else
    FView.GamePause.Text := FView.GamePause.Hint;
  if PlatformSessionHandler(FState.Input.SystemId).ShowPauseShortcut(RuntimeContext) then
    FView.GamePause.Hint := FView.GamePause.Hint + ' · P';
  // Changing the style recreates its text resource, including its margins.
  FView.GamePause.ApplyStyleLookup;
  FView.GamePause.StylesData['text.Margins.Left'] := 36;
  FView.GamePause.StylesData['text.Margins.Right'] := 10;
  {$ENDIF}
  if FState.Browser.Tools[0] <> nil then
  begin
    FState.Browser.Tools[1].Enabled := (FState.Session.Emulation <> nil) and FState.Session.Emulation.SupportsSnapshots and not FState.Session.OpeningRom;
    FState.Browser.Tools[4].Enabled := not FState.Session.OpeningRom;
  end;
  if FState.Browser.ScreenshotTool <> nil then
    FState.Browser.ScreenshotTool.Enabled := (FState.Session.Emulation <> nil) and not FState.Session.OpeningRom;
  if FState.Browser.ActionsTool <> nil then
    FState.Browser.ActionsTool.Enabled := not FState.Session.OpeningRom;
  PlatformSessionHandler(FState.Input.SystemId).SyncActivity(RuntimeContext);
  {$IFDEF ISMOBILE}
  SyncSessionTouch(RuntimeContext);
  PlatformSessionHandler(FState.Input.SystemId).LayoutControls(RuntimeContext);
  PlatformSessionHandler(FState.Input.SystemId).ApplyActivityGate(RuntimeContext);
  var Paused := FState.Mobile.InBackground or FView.GameActionsPopup.IsOpen or FState.Session.OpeningRom or FState.Browser.ViewingLibrary or FState.Session.UserPaused or
    (FState.Settings.View <> nil) or (FState.Help.View <> nil) or RetroDialogVisible(FView);
  if Paused <> FState.Mobile.ActivityPaused then
  begin
    FState.Mobile.ActivityPaused := Paused;
    if FState.Session.Emulation <> nil then
      if Paused then
      begin
        FView.FormDeactivate(FView);
        FState.Session.Emulation.Pause;
      end
      else if not FState.Session.EmulationFaulted then
        FState.Session.Emulation.Resume;
  end;
  FView.TimerUpdate.Enabled := not FState.Mobile.InBackground and (FState.Session.OpeningRom or ((FState.Session.Emulation <> nil) and not FState.Session.EmulationFaulted));
  {$ELSE}

  // Idle windows use native key events. Keep polling for gameplay and settings
  // capture; background rendering is only needed while a core is running.
  var NeedsInput := (FState.Input.Manager <> nil) and not FState.Input.PollingFailed and FView.InputHasFocus and
    not FState.Session.OpeningRom and
    ((FState.Settings.View <> nil) or (FState.Session.Emulation <> nil));
  var NeedsFrames := (FState.Session.Emulation <> nil) and
    not FState.Session.EmulationFaulted and not FState.Session.Emulation.IsPaused;
  FView.TimerUpdate.Enabled := NeedsInput or NeedsFrames;
  {$ENDIF}
  FView.SyncMotionSensor;
  FView.PollRumble;
  FView.UpdateGameChrome;
end;

procedure TSessionController.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  try
    {$IFDEF MSWINDOWS}
    FView.SaveWindowState;
    {$ENDIF}
    FView.Stop;
  except
    on E: Exception do
    begin
      CanClose := False;
      {$IFDEF MSWINDOWS}
      FState.Window.WindowStateSaved := False;
      {$ENDIF}
      ShowRetroMessage(FView, E.Message);
    end;
  end;
end;

procedure TSessionController.FormSaveState(Sender: TObject);
begin
  try
    FView.Save;
  except
    on E: Exception do
      ShowRetroMessage(FView, E.Message);
  end;
end;

procedure TSessionController.ButtonOpenClick(Sender: TObject);
begin
  try
    FView.OpenRom;
  except
    on E: Exception do
      ShowRetroMessage(FView, E.Message);
  end;
end;

procedure TSessionController.OpenRom;
begin
  FView.SelectDocument(False);
end;

procedure TSessionController.SelectDocument(ForCassette: Boolean; const FileName: string);
begin
  if FState.Session.OpeningRom then
    Exit;

  if not ForCassette and (FState.Help.View <> nil) then
    FView.CloseControlsHelp;
  FState.Session.OpeningRom := True;
  FView.FormDeactivate(FView);
  FView.SyncActivity;
  var IsAlive: TFunc<Boolean> := FState.Session.CallbackAlive;
  var Completion: TStorageSelectionCallback :=
    procedure(const Selection: TStorageSelection)
    begin
      if not IsAlive() then
        Exit;

      var Importing := False;
      try
        try
          if Selection.Error <> '' then
            raise Exception.Create(Selection.Error);

          if not Selection.Cancelled then
          begin
            if ForCassette then
            begin
              {$IFDEF ANDROID}
              FState.Mobile.ChoosingTape := True;
              FState.Mobile.Transfer.Import(Selection.Location, True, FState.Input.SystemId);
              Importing := True;
              {$ELSE}
              FView.SelectTapeFile(Selection.Location);
              {$ENDIF}
            end
            else
              FView.LoadRom(Selection.Location, FState.Session.Storage.Describe(Selection.Location).Name);
          end;
        except
          on E: Exception do
            ShowRetroMessage(FView, E.Message);
        end;
      finally
        if not Importing then
          FView.FinishFileSelection;
      end;
    end;
  try
    if FileName <> '' then
    begin
      var Selection := Default(TStorageSelection);
      Selection.Location := FileName;
      Completion(Selection);
    end
    else if ForCassette then
    begin
      FState.Session.FileDialog.InitialDirectory := '';
      FState.Session.FileDialog.FileMustExist := False;
      var Selection := PlatformDocumentSelection(FState.Input.SystemId);
      FState.Session.FileDialog.Title := Translate(Selection.Title);
      FState.Session.FileDialog.Filter := Translate(Selection.FileFilter);
      FState.Session.FileDialog.SelectFiles(
        procedure(const Selection: TFMXSelectionResult)
        begin
          var Result := Default(TStorageSelection);
          Result.Cancelled := Selection.Status = TFMXSelectionStatus.Cancelled;
          Result.Error := Selection.Error;
          if Selection.Status = TFMXSelectionStatus.Selected then
            Result.Location := Selection.Locations[0];
          Completion(Result);
        end);
    end
    else
    begin
      FView.ImageLogo.Visible := False;
      FState.Session.Storage.SelectRom(Completion);
    end;
  except
    FView.FinishFileSelection;
    raise;
  end;
end;

procedure TSessionController.FinishFileSelection;
begin
  if FLoadingCore or FState.Session.PendingAutosaveChoice then
    Exit;

  {$IFDEF ANDROID}
  FState.Mobile.Transfer.Finish;
  FState.Mobile.ChoosingTape := False;
  {$ENDIF}
  FState.Session.OpeningRom := False;
  FView.FormActivate(FView);
end;

function TSessionController.CanAcceptRomDrop(const Data: TDragObject): Boolean;
begin
  Result := not (csDestroying in FView.ComponentState) and not FState.Session.OpeningRom and
    not FState.Help.Closing and (FState.Settings.View = nil) and
    (FView.ScreenTabs.ActiveTab <> FView.SettingsScreen) and (Length(Data.Files) = 1);
  if Result then
    // Like the file picker, accept renamed ROMs and validate their contents on load.
    Result := TFile.Exists(Data.Files[0]);
end;

procedure TSessionController.EndCoreLoading;
begin
  FCancelLoad := nil;
  FState.Session.PreserveOpeningAutosave := False;
  FLoadingCore := False;
  FState.Session.OpeningRom := FState.Session.PendingAutosaveChoice;
  CloseRetroLoading(FView);
  FView.FinishFileSelection;
end;

procedure TSessionController.CancelCoreLoading;
begin
  if not FLoadingCore then
    Exit;

  if Assigned(FCancelLoad) then
    FCancelLoad();
  Inc(FLoadGeneration);
  EndCoreLoading;
end;

procedure TSessionController.LoadRom(const FileName: string; const DisplayName: string; StartPaused: Boolean; const SnapshotName: string);
begin
  if FLoadingCore or FState.Session.PendingAutosaveChoice then
    Exit;
  Inc(FLoadGeneration);
  // The explicit snapshot is already a launch choice. Otherwise consult only
  // the persisted association; never open ROM streams or instantiate a core here.
  var Path := '';
  if SnapshotName = '' then
    Path := FindRecordedAutosave(FState.Session.Storage, FileName);
  if Path = '' then
  begin
    BeginGameLoading(FileName, DisplayName, StartPaused, SnapshotName);
    Exit;
  end;

  var Text := Translate('An autosave was found for this game. Load it?') + sLineBreak + sLineBreak;
  if FState.Autosave.OnExit then
    Text := Text + Translate('The autosave will be overwritten when you exit the game.')
  else
    Text := Text + Translate('Autosave on exit is disabled.');
  if FState.Autosave.Periodic then
    Text := Text + sLineBreak + Translate('Periodic autosaving will also overwrite this autosave.');

  var IsAlive := FState.Session.CallbackAlive;
  var Generation := FLoadGeneration;
  FState.Session.PendingAutosaveChoice := True;
  FState.Session.OpeningRom := True;
  ShowRetroChoice(FView, Text,
    procedure(Choice: TRetroDialogChoice)
    begin
      if not IsAlive() then
        Exit;
      if Generation <> FLoadGeneration then
        Exit;
      try
        if Choice <> TRetroDialogChoice.Cancel then
        begin
          // Preserve the chosen snapshot when replacing the same running game;
          // save a different game's progress normally before switching.
          var PreviousDirectory := FView.GameSnapshotDirectory;
          FState.Session.PreserveOpeningAutosave := (Choice = TRetroDialogChoice.Accept) and
            SameText(ExcludeTrailingPathDelimiter(PreviousDirectory), ExcludeTrailingPathDelimiter(ExtractFilePath(Path)));
          FState.Session.PendingAutosaveChoice := False;
          try
            var Snapshot := '';
            if Choice = TRetroDialogChoice.Accept then
              Snapshot := Path;
            // Restored games wait for an explicit Resume after the dialog closes.
            BeginGameLoading(FileName, DisplayName, StartPaused or (Choice = TRetroDialogChoice.Accept), Snapshot);
          except
            on E: Exception do
              ShowRetroMessage(FView, Translate('Unable to open game: ') + E.Message);
          end;
        end;
      finally
        FState.Session.PendingAutosaveChoice := False;
        if not FLoadingCore then
          FState.Session.PreserveOpeningAutosave := False;
        FView.FinishFileSelection;
        FView.SyncActivity;
      end;
    end, 'Load autosave', 'Start new game', 'Cancel launch');
end;

procedure TSessionController.ResetConsole(Hard: Boolean);
begin
  if (FState.Session.Emulation = nil) or FState.Session.OpeningRom or
    FLoadingCore or FState.Session.PendingAutosaveChoice or FState.Browser.ViewingLibrary or
    (FState.Settings.View <> nil) or (FState.Help.View <> nil) then
    Exit;
  if Hard then
  begin
    HardRestart;
    Exit;
  end;
  FView.TimerUpdate.Enabled := False;
  try
    if FState.Input.Rumble <> nil then
      FState.Input.Rumble.Reset;
    FState.Session.Emulation.Reset;
    FState.Session.UserPaused := False;
    FState.Session.EmulationFaulted := False;
    {$IFDEF ISMOBILE}
    if FState.Mobile.ActivityPaused then
      FState.Session.Emulation.Pause;
    {$ENDIF}
    FView.SyncActivity;
    FView.SetStatus(FState.Session.RomDisplayName);
  except
    FView.StopOnError;
    raise;
  end;
end;

procedure TSessionController.HardRestart;
begin
  if (FState.Session.Emulation = nil) or FState.Session.OpeningRom or
    FLoadingCore or FState.Session.PendingAutosaveChoice then
    Exit;

  // Use the normal replacement path to preserve battery RAM and rebuild
  // peripherals, video and timing. Bypass the autosave prompt/restoration:
  // a hard restart must start a fresh machine with the saved configuration.
  BeginGameLoading(FState.Session.RomLocation, FState.Session.RomDisplayName, False, '');
  FState.Input.SuppressInputUntilRelease := True;
end;

procedure TSessionController.BeginGameLoading(const FileName, DisplayName: string; StartPaused: Boolean; const SnapshotName: string);
begin
  var SourceName := FileName;
  if FileName.StartsWith('content://', True) then
    SourceName := FState.Session.Storage.Describe(FileName).Name;
  if not LoadMediaInBackground(SourceName) then
  begin
    InstallCore(FView.NewCore(FileName), FileName, DisplayName, StartPaused);
    if SnapshotName <> '' then
      FView.LoadSnapshot(SnapshotName);
    Exit;
  end;

  // Capture only immutable arguments and storage for the worker. All form/core
  // replacement and lifetime checks run on the main thread.
  var Storage := FState.Session.Storage;
  var IsAlive := FState.Session.CallbackAlive;
  var Path := FileName;
  var Title := DisplayName;
  var Snapshot := SnapshotName;
  var Paused := StartPaused;
  var Generation := FLoadGeneration;
  var CheckCancelled := NewLoadCancellation(FCancelLoad);
  FLoadingCore := True;
  FState.Session.OpeningRom := True;
  FView.FormDeactivate(FView);
  ShowRetroLoading(FView, SourceName,
    procedure
    begin
      CancelCoreLoading;
    end);
  FView.SyncActivity;
  try
    TThread.CreateAnonymousThread(
      procedure
      var
        Core: IEmulationCore;
        ErrorText: string;
      begin
        var Scope := TStorage.BeginReadCancellation(CheckCancelled);
        try
          CheckCancelled();
          var Stream := Storage.OpenRead(Path);
          try
            Core := CreateEmulationCore(Stream, Storage, Path);
            CheckCancelled();
          finally
            Stream.Free;
          end;
        except
          on E: Exception do
            ErrorText := E.Message;
        end;
        Scope := nil;
        try
          CheckCancelled();
        except
          on E: EAbort do
            Exit;
        end;
        TThread.ForceQueue(nil,
          procedure
          begin
            if not IsAlive() then
              Exit;

            if Generation <> FLoadGeneration then
              Exit;

            try
              if ErrorText <> '' then
                ShowRetroMessage(FView, Translate('Unable to open game: ') + ErrorText)
              else
              try
                InstallCore(Core, Path, Title, Paused);
                if Snapshot <> '' then
                  FView.LoadSnapshot(Snapshot);
              except
                on E: Exception do
                  ShowRetroMessage(FView, Translate('Unable to open game: ') + E.Message);
              end;
            finally
              EndCoreLoading;
            end;
          end);
      end).Start;
  except
    EndCoreLoading;
    raise;
  end;
end;

procedure TSessionController.InstallCore(const NewEmulation: IEmulationCore; const FileName, DisplayName: string; StartPaused: Boolean);
begin
  FView.ImageLogo.Visible := False;
  // Construct first: an invalid ROM leaves the current worker running.
  if FState.Session.Emulation <> nil then
  begin
    if not FState.Session.PreserveOpeningAutosave then
      FView.AutosaveOnExit;
    FState.Session.Emulation.Stop;
  end;

  if FState.Input.Gamepad <> nil then
    FState.Input.Gamepad.ReleaseAll;
  ReleaseSessionInputs(RuntimeContext);
  FView.TimerUpdate.Enabled := False;
  if FState.Input.Rumble <> nil then
    FState.Input.Rumble.Reset;
  DisconnectSession;
  FState.Session.Emulation := nil; // Join before replacing the session.
  FView.SyncMotionSensor;
  FState.Session.Emulation := NewEmulation;
  FState.Session.PreserveOpeningAutosave := False;
  FState.Session.PendingAutosaveChoice := False;

  var platform := TPlatformRegistry.Require(FState.Session.Emulation.SystemId);
  var InputSystem := platform.Id;
  FView.LoadHostInput(InputSystem);
  PlatformSessionHandler(InputSystem).Connect(RuntimeContext);

  FState.Session.UserPaused := StartPaused;
  FState.Session.AutoPaused := False;

  var VideoIni := FState.Session.Storage.ReadConfig(FState.Session.Emulation.Config.FileName);
  try
    FView.ImageCanvas.LoadSettings(VideoIni);
  finally
    VideoIni.Free;
  end;
  FView.ImageCanvas.DisableInterpolation := SameText(FState.Session.Emulation.Config.Filter, 'nearest');
  FillChar(FState.Input.KeysDown, SizeOf(FState.Input.KeysDown), 0);
  FState.Session.RomLocation := FileName;
  FState.Session.RomDisplayName := DisplayName;
  if FState.Session.RomDisplayName = '' then
    FState.Session.RomDisplayName := ExtractFileName(FileName);
  FState.Session.SoundErrorShown := False;
  try
    FView.ImageCanvas.Bitmap.Clear(TAlphaColors.Black);
    FState.Session.EmulationFaulted := False;
    if FState.Session.UserPaused then
      FState.Session.Emulation.Pause;
    {$IFDEF ISMOBILE}
    if FState.Mobile.ActivityPaused then
      FState.Session.Emulation.Pause;
    {$ENDIF}
    FState.Session.Emulation.Start;
    FState.Autosave.LastTick := FView.CurrentTick;
    var Info: IEmulationSnapshotLocation;
    var Directory := '';
    if FState.Session.Emulation.SupportsSnapshots and
      Supports(FState.Session.Emulation, IEmulationSnapshotLocation, Info) then
      Directory := Info.GetSnapshotDirectory;
    RecordGameSnapshotDirectory(FState.Session.Storage, FileName, Directory);
    if FState.Browser.View <> nil then
    begin
      FState.Browser.View.RecordSession(FileName, Directory, platform.Id, DisplayName);
      FState.Browser.View.Visible := False;
      FView.ScreenTabs.ActiveTab := FView.GameScreen;
      FView.LayoutClient.Visible := True;
      FState.Browser.ViewingLibrary := False;
      FView.LayoutClient.SetFocus;
      if FState.Preferences.StartFullscreen and not FView.FullScreen then
        FView.SwitchFullScreen;
    end;
    FView.SyncActivity;
    FView.SetStatus(FState.Session.Emulation.Name + ' - ' + FState.Session.RomDisplayName);
  except
    FView.StopOnError;
    raise;
  end;

  {$IFDEF ISMOBILE}
  if not FView.FullScreen then
    FView.SwitchFullScreen;
  {$ENDIF}
end;

procedure TSessionController.ButtonCloseRomClick(Sender: TObject);
begin
  FView.Stop;
end;

procedure TSessionController.Stop;
begin
  CancelCoreLoading;
  Inc(FLoadGeneration);

  if FView.FullScreen then
    FView.SwitchFullScreen;

  FView.FormDeactivate(FView);
  if FState.Session.Emulation <> nil then
  begin
    FView.AutosaveOnExit;
    FView.TimerUpdate.Enabled := False;
    FState.Session.Emulation.Stop;
    DisconnectSession;
    FView.ImageCanvas.Mode := TBitmapShaderMode.Original;
    FView.ImageCanvas.Bitmap := nil;
    FView.ImageLogo.Visible := True;
    FState.Session.Emulation := nil;
  end;
  if FState.Browser.View <> nil then
    FView.LibraryBack(FView);
  FState.Session.PendingAutosaveChoice := False;
  FState.Session.OpeningRom := False;
  FState.Session.RomLocation := '';
  FView.SyncActivity;
end;

procedure TSessionController.StopOnError;
begin
  FState.Session.EmulationFaulted := True;
  FView.TimerUpdate.Enabled := False;
  if FState.Session.Emulation <> nil then
    FState.Session.Emulation.Pause;
  FView.FormDeactivate(FView);
  FView.SetStatus(Translate('Stopped after error - ') + FState.Session.RomDisplayName);
  FView.SyncActivity;
end;

procedure TSessionController.TimerUpdateTimer(Sender: TObject);
begin
  if (FState.Input.Manager <> nil) and not FState.Input.PollingFailed then
  try
    FView.PollHostInput;
  except
    on E: Exception do
    begin
      FState.Input.PollingFailed := True;
      FState.Input.Manager.Enabled := False;
      FView.FormDeactivate(FView);
      if FState.Session.Emulation <> nil then
      begin
        FState.Session.UserPaused := True;
        FState.Session.Emulation.Pause;
      end;
      FView.SyncActivity;
      FView.SetStatus(Translate('Input error: ') + E.Message);
      ShowRetroMessage(FView, Translate('Input error: ') + E.Message);
      Exit;
    end;
  end;

  FView.PollRumble;
  if FState.Settings.View <> nil then
    Exit;

  {$IFDEF ANDROID}
  FView.PollDocumentTransfer;
  {$ENDIF}

  {$IFDEF ISMOBILE}
  if FState.Session.OpeningRom then
    Exit;
  {$ENDIF}

  if FState.Session.EmulationFaulted or not FView.TimerUpdate.Enabled or (FState.Session.Emulation = nil) then
    Exit;

  FView.UpdatePauseOverlay;
  try
    FView.PollMotionSensor;
    FView.UpdatePeripheralFeedback;
    FView.UpdateFrame;
    FView.PollAutosave;
  except
    FView.StopOnError;
    raise;
  end;
end;

function TSessionController.UpdateFrame: Boolean;
begin
  Result := False;
  UpdateVirtualButtons;
  if FState.Session.Emulation = nil then
    Exit;

  var Frame: TEmulatorFrame;
  var NewFrame := FState.Session.Emulation.TryGetFrame(Frame);
  var AudioDiagnostics: IEmulationAudioDiagnostics;
  if Supports(FState.Session.Emulation, IEmulationAudioDiagnostics, AudioDiagnostics) then
  begin
    var AudioError := AudioDiagnostics.TakeAudioError;
    if (AudioError <> '') and not FState.Session.SoundErrorShown then
    begin
      FState.Session.SoundErrorShown := True;
      FView.ShowAudioError(AudioError);
    end;
  end;

  var ErrorText := FState.Session.Emulation.TakeError;
  if (ErrorText <> '') and not FState.Session.EmulationFaulted then
  begin
    FView.StopOnError;
    raise Exception.Create(ErrorText);
  end;

  if not FState.Session.EmulationFaulted and NewFrame then
  begin
    if FState.Browser.GameFPS <> nil then
      FState.Browser.GameFPS.Text := Format('%.1f FPS   ·   %s   ·   %d × %d',
        [Frame.FramesPerSecond, UpperCase(FState.Input.SystemId), Frame.Width, Frame.Height]);
    {$IFDEF ISMOBILE}
    var FrameStatus := Format('%s - %.1f FPS', [FState.Session.Emulation.Name, Frame.FramesPerSecond]);
    if FView.LabelStatus.Text <> FrameStatus then
      FView.SetStatus(FrameStatus);
    {$ENDIF}
  end;
  PlatformSessionHandler(FState.Input.SystemId).FrameStatus(RuntimeContext);
  if not NewFrame then
    Exit;

  if (FView.ImageCanvas.Bitmap.Width <> Frame.Width) or (FView.ImageCanvas.Bitmap.Height <> Frame.Height) then
  begin
    FView.ImageCanvas.Bitmap.SetSize(Frame.Width, Frame.Height);
  end;
  var Data: TBitmapData;
  if FView.ImageCanvas.Bitmap.Map(TMapAccess.Write, Data) then
  try
    UploadFramePixels(Frame.Pixels, Frame.Width, Frame.Height, Data);
    Result := True;
  finally
    FView.ImageCanvas.Bitmap.Unmap(Data);
  end;
  FView.ImageCanvas.Repaint;
  PlatformSessionHandler(FState.Input.SystemId).FramePresented(RuntimeContext);
end;

procedure TSessionController.PauseClick(Sender: TObject);
begin
  FView.SwitchPause;
end;

procedure TSessionController.SwitchPause;
begin
  if (FState.Session.Emulation = nil) or FState.Session.EmulationFaulted then
    Exit;

  FState.Session.UserPaused := not (FState.Session.UserPaused or FState.Session.AutoPaused);
  FState.Session.AutoPaused := False;
  if FState.Session.UserPaused then
  begin
    FView.FormDeactivate(FView);
    FState.Session.Emulation.Pause;
  end
  else
  begin
    {$IFNDEF ISMOBILE}
    FState.Session.Emulation.Resume;
    {$ENDIF}
  end;
  FView.SyncActivity;
  // SyncActivity can release input again when the mobile pause state changes.
  FState.Input.KeysDown[vkP] := True;
end;

procedure TSessionController.UpdatePauseOverlay;
begin
  var Paused := (FState.Session.Emulation <> nil) and (FState.Session.UserPaused or FState.Session.AutoPaused or FState.Session.Emulation.IsPaused);
  FView.ImageCanvas.Opacity := IfThen(Paused, 0.5, 1);
  FView.LabelPaused.Visible := Paused and not FState.Browser.ViewingLibrary and (FState.Help.View = nil) and (FState.Settings.View = nil);
  if FView.LabelPaused.Visible then
    FView.LabelPaused.BringToFront;
end;

procedure TSessionController.InsertCoinClick(Sender: TObject);
begin
  if (FState.Session.Emulation = nil) or FState.Session.EmulationFaulted or FState.Session.OpeningRom or FState.Browser.ViewingLibrary or
    (FState.Settings.View <> nil) or (FState.Help.View <> nil) or not FState.Session.Emulation.HasCoinAcceptor then
    Exit;

  FState.Session.Emulation.InsertCoin1;
end;

end.

