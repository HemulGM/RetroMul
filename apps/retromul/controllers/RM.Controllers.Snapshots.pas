unit RM.Controllers.Snapshots;

{$I ..\RM.Mobile.inc}

interface

uses
  RM.Controllers.Base;

type
  TSnapshotsController = class(TMainController)
  public
    function GameSnapshotDirectory: string;
    procedure SaveSnapshot(const Name: string);
    procedure LoadSnapshot(const Name: string);
    procedure LoadSnapshotPreview(const Name: string);
    procedure SaveStateClick(Sender: TObject);
    procedure LoadStateClick(Sender: TObject);
    procedure PrepareGameplayMenu(Sender: TObject);
    procedure SaveSnapshotAsClick(Sender: TObject);
    procedure OpenSnapshotClick(Sender: TObject);
    procedure RecentSnapshotClick(Sender: TObject);
    procedure ScreenshotClick(Sender: TObject);
    function SaveScreenshot: string;
    procedure OpenScreenshotFolderClick(Sender: TObject);
    procedure AutosaveOnExit;
    procedure PollAutosave;
  end;

implementation

uses
  System.SysUtils, System.Classes, System.UITypes, FMX.Types, System.IOUtils,
  System.Math, System.Generics.Collections, System.Generics.Defaults,
  FMX.Graphics, FMX.Dialogs, FMX.Menus, Core.Emulation, Core.Storage,
  Core.SavePaths, HGM.FMX.Image, RM.Dialogs, RM.Styles;

function TSnapshotsController.GameSnapshotDirectory: string;
begin
  Result := '';
  var Location: IEmulationSnapshotLocation;
  if (FState.Session.Emulation <> nil) and Supports(FState.Session.Emulation, IEmulationSnapshotLocation, Location) then
    Result := Location.GetSnapshotDirectory;
end;

procedure TSnapshotsController.SaveSnapshot(const Name: string);
begin
  if FState.Session.Emulation = nil then
    raise Exception.Create(Translate('No game loaded'));

  if not FState.Session.Emulation.SupportsSnapshots then
    raise ENotSupportedException.Create(Translate('Snapshots are not implemented by this core'));

  FState.Session.Emulation.SaveSnapshot(Name);
end;

procedure TSnapshotsController.LoadSnapshot(const Name: string);
begin
  if FState.Session.Emulation = nil then
    raise Exception.Create(Translate('No game loaded'));

  if not FState.Session.Emulation.SupportsSnapshots then
    raise ENotSupportedException.Create(Translate('Snapshots are not implemented by this core'));

  FState.Session.Emulation.LoadSnapshot(Name);
  FState.Session.EmulationFaulted := False;
  FView.SyncActivity;
  if not FView.UpdateFrame then
    FView.LoadSnapshotPreview(Name);
end;

procedure TSnapshotsController.LoadSnapshotPreview(const Name: string);
begin
  var Location: IEmulationSnapshotLocation;
  if not Supports(FState.Session.Emulation, IEmulationSnapshotLocation, Location) then
    Exit;

  var Directory := Location.GetSnapshotDirectory;
  if Directory = '' then
    Exit;

  var Bitmap := FMX.Graphics.TBitmap.Create;
  try
    for var Extension in ['.png', '.bmp'] do
    try
      var Path := ChangeFileExt(ResolveSnapshotPath(Directory, Name), Extension);
      if not FState.Session.Storage.Exists(Path) then
        Continue;

      var Stream := FState.Session.Storage.OpenRead(Path);
      try
        Bitmap.LoadFromStream(Stream);
      finally
        Stream.Free;
      end;
      if Bitmap.IsEmpty then
        Continue;
      FView.ImageCanvas.Bitmap.Assign(Bitmap);
      FView.ImageCanvas.ResetHistory;
      FView.ImageCanvas.Repaint;
      Exit;
    except
      // Optional artwork must not prevent a valid game state from loading.
      on E: Exception do
        Continue;
    end;
  finally
    Bitmap.Free;
  end;
end;

procedure TSnapshotsController.SaveStateClick(Sender: TObject);
begin
  if (FState.Session.Emulation = nil) or not FState.Session.Emulation.SupportsSnapshots then
    Exit;

  try
    FView.SaveSnapshot('Quick');
  except
    on E: Exception do
      ShowRetroMessage(FView, Translate(E.Message));
  end;
end;

procedure TSnapshotsController.LoadStateClick(Sender: TObject);
begin
  if (FState.Session.Emulation = nil) or not FState.Session.Emulation.SupportsSnapshots then
    Exit;

  try
    FView.LoadSnapshot('Quick');
  except
    on E: Exception do
      ShowRetroMessage(FView, Translate(E.Message));
  end;
end;

procedure TSnapshotsController.PrepareGameplayMenu(Sender: TObject);

  procedure AddItem(const ItemCaption: string; Click: TNotifyEvent; const Path: string = '');
  begin
    var Item := TMenuItem.Create(TPopupMenu(Sender));
    Item.Text := ItemCaption;
    Item.TagString := Path;
    Item.OnClick := Click;
    TPopupMenu(Sender).AddObject(Item);
  end;

begin
  var Menu := TPopupMenu(Sender);
  Menu.Clear;
  try
    if Menu = FState.Browser.ScreenshotMenu then
    begin
      {$IFNDEF ISMOBILE}
      AddItem(Translate('Open screenshot folder'), FView.OpenScreenshotFolderClick)
      {$ENDIF}
    end
    else if Menu = FState.Browser.SaveMenu then
      AddItem(Translate('Save as...'), FView.SaveSnapshotAsClick)
    else if Menu = FState.Browser.LoadMenu then
    begin
      var Directory := FView.GameSnapshotDirectory;
      var Saves := TList<TStorageSnapshot>.Create;
      try
        if Directory <> '' then
          for var Path in FState.Session.Storage.Files(Directory) do
            if SameText(ExtractFileExt(Path), SNAPSHOT_EXTENSION) then
            begin
              var SnapshotInfo := Default(TStorageSnapshot);
              SnapshotInfo.Location := Path;
              SnapshotInfo.Name := ChangeFileExt(ExtractFileName(Path), '');
              SnapshotInfo.Modified := FState.Session.Storage.ModifiedTime(Path);
              Saves.Add(SnapshotInfo);
            end;
        Saves.Sort(TComparer<TStorageSnapshot>.Construct(
          function(const A, B: TStorageSnapshot): Integer
          begin
            Result := CompareValue(B.Modified, A.Modified);
            if Result = 0 then
              Result := CompareText(A.Location, B.Location);
          end));
        for var i := 0 to Min(8, Saves.Count) - 1 do
          AddItem(Saves[i].Name, FView.RecentSnapshotClick, Saves[i].Location);
        if Saves.Count > 0 then
          AddItem('-', nil);
      finally
        Saves.Free;
      end;
      AddItem(Translate('Open snapshot...'), FView.OpenSnapshotClick);
    end;
  except
    on E: Exception do
      ShowRetroMessage(FView, Translate(E.Message));
  end;
end;

procedure TSnapshotsController.SaveSnapshotAsClick(Sender: TObject);
begin
  if (FState.Session.Emulation = nil) or not FState.Session.Emulation.SupportsSnapshots or FState.Session.OpeningRom then
    Exit;

  var Directory := FView.GameSnapshotDirectory;
  if Directory = '' then
    Exit;

  var Dialog := TSaveDialog.Create(FView);
  FView.FormDeactivate(FView);
  FState.Session.OpeningRom := True;
  FView.SyncActivity;
  try
    try
      FState.Session.Storage.EnsureFolder(Directory);
      Dialog.Title := Translate('Save as...');
      Dialog.Filter := Translate('Snapshots (*.snapshot)|*.snapshot');
      Dialog.DefaultExt := 'snapshot';
      Dialog.InitialDir := Directory;
      Dialog.FileName := FormatDateTime('yyyy-mm-dd_hh-nn-ss-zzz', Now) + SNAPSHOT_EXTENSION;
      Dialog.Options := [TOpenOption.ofPathMustExist, TOpenOption.ofOverwritePrompt];
      if FView.RunSnapshotDialog(Dialog) then
        FView.SaveSnapshot(TPath.GetFullPath(Dialog.FileName));
    except
      on E: Exception do
        ShowRetroMessage(FView, Translate(E.Message));
    end;
  finally
    Dialog.Free;
    FState.Session.OpeningRom := False;
    FView.FormActivate(FView);
    FView.SyncActivity;
  end;
end;

procedure TSnapshotsController.OpenSnapshotClick(Sender: TObject);
begin
  if (FState.Session.Emulation = nil) or not FState.Session.Emulation.SupportsSnapshots or FState.Session.OpeningRom then
    Exit;

  var Directory := FView.GameSnapshotDirectory;
  if Directory = '' then
    Exit;

  var Dialog := TOpenDialog.Create(FView);
  FView.FormDeactivate(FView);
  FState.Session.OpeningRom := True;
  FView.SyncActivity;
  try
    try
      FState.Session.Storage.EnsureFolder(Directory);
      Dialog.Title := Translate('Open snapshot...');
      Dialog.Filter := Translate('Snapshots (*.snapshot)|*.snapshot');
      Dialog.DefaultExt := 'snapshot';
      Dialog.InitialDir := Directory;
      Dialog.Options := [TOpenOption.ofPathMustExist, TOpenOption.ofFileMustExist];
      if FView.RunSnapshotDialog(Dialog) then
        FView.LoadSnapshot(TPath.GetFullPath(Dialog.FileName));
    except
      on E: Exception do
        ShowRetroMessage(FView, Translate(E.Message));
    end;
  finally
    Dialog.Free;
    FState.Session.OpeningRom := False;
    FView.FormActivate(FView);
    FView.SyncActivity;
  end;
end;

procedure TSnapshotsController.RecentSnapshotClick(Sender: TObject);
begin
  if (FState.Session.Emulation = nil) or not FState.Session.Emulation.SupportsSnapshots or FState.Session.OpeningRom then
    Exit;

  try
    FView.LoadSnapshot(TMenuItem(Sender).TagString);
  except
    on E: Exception do
      ShowRetroMessage(FView, Translate(E.Message));
  end;
end;

procedure TSnapshotsController.ScreenshotClick(Sender: TObject);
begin
  if FState.Session.Emulation = nil then
    Exit;

  try
    FView.SetStatus(Translate('Screenshot: ') + FView.SaveScreenshot);
  except
    on E: Exception do
      ShowRetroMessage(FView, Translate(E.Message));
  end;
end;

function TSnapshotsController.SaveScreenshot: string;
begin
  if FState.Session.Emulation = nil then
    raise EInvalidOperation.Create(Translate('No game loaded'));

  Result := FState.Session.Storage.ScreenshotFile(FState.Session.RomDisplayName);
  var Stream := TMemoryStream.Create;
  try
    FView.ImageCanvas.Bitmap.SaveToStream(Stream);
    FState.Session.Storage.WriteAtomic(Result, Stream);
  finally
    Stream.Free;
  end;
end;

procedure TSnapshotsController.OpenScreenshotFolderClick(Sender: TObject);
begin
  try
    var Directory := TPath.Combine(FState.Session.Storage.Root, 'screenshots');
    FState.Session.Storage.EnsureFolder(Directory);
    FView.ShowDirectory(Directory);
  except
    on E: Exception do
      ShowRetroMessage(FView, Translate(E.Message));
  end;
end;

procedure TSnapshotsController.AutosaveOnExit;
begin
  if FState.Autosave.OnExit and (FState.Session.Emulation <> nil) and
    not FState.Session.PendingAutosaveChoice and not FState.Session.PreserveOpeningAutosave and
    not FState.Session.EmulationFaulted and
    FState.Session.Emulation.SupportsSnapshots then
    FView.SaveSnapshot(SNAPSHOT_AUTOSAVE);
end;

procedure TSnapshotsController.PollAutosave;
begin
  if not FState.Autosave.Periodic or (FState.Session.Emulation = nil) or FState.Session.EmulationFaulted or
    FState.Session.OpeningRom or FState.Session.PendingAutosaveChoice or FState.Browser.ViewingLibrary or
    (FState.Settings.View <> nil) or (FState.Help.View <> nil) or
    FState.Session.Emulation.IsPaused or not FState.Session.Emulation.SupportsSnapshots then
    Exit;

  var Tick := FView.CurrentTick;
  if (Tick < FState.Autosave.LastTick) or
    (Tick - FState.Autosave.LastTick < UInt64(FState.Autosave.Minutes) * 60000) then
    Exit;

  // Retry on the next interval, rather than on every display update after an error.
  FState.Autosave.LastTick := Tick;
  try
    FView.SaveSnapshot(SNAPSHOT_AUTOSAVE);
  except
    on E: Exception do
      ShowRetroMessage(FView, Translate('Autosave failed: ') + E.Message);
  end;
end;

end.

