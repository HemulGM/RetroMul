unit RM.Feedback;

interface

uses
  System.SysUtils, System.Classes, System.JSON, FMX.Types, FMX.Controls,
  FMX.Forms, FMX.Layouts, FMX.StdCtrls, FMX.Objects, FMX.Memo, FMX.Edit,
  Core.Emulation, Core.Storage, RM.Main.View, FMX.Memo.Types, FMX.ScrollBox,
  FMX.Controls.Presentation;

type
  TFeedbackView = class(TFrame)
    RectangleBackdrop: TRectangle;
    PanelFeedback: TPanel;
    LayoutHeader, LayoutFooter, LayoutAttachmentActions: TLayout;
    LayoutSystemInformation, LayoutSessionInformation, LayoutSuccess: TLayout;
    LabelSuccessTitle, LabelSuccessMessage: TLabel;
    LabelTitle, LabelStatus, LabelAttachment, LabelDescription: TLabel;
    VertScrollBoxContent: TVertScrollBox;
    CheckBoxSystem, CheckBoxScreenshot: TCheckBox;
    MemoDescription: TMemo;
    EditOperatingSystem, EditArchitecture, EditProcessBits, EditProcessorCount, EditScreen: TEdit;
    EditVersion, EditPlatform, EditLaunchMethod, EditRom, EditRomCRC: TEdit;
    LabelError: TLabel;
    ImageScreenshot: TImage;
    ButtonChooseAttachment, ButtonRemoveAttachment, ButtonSend, ButtonCancel: TButton;
    TimerSnapshot: TTimer;
    procedure CancelClick(Sender: TObject);
    procedure SendClick(Sender: TObject);
    procedure ChooseAttachmentClick(Sender: TObject);
    procedure RemoveAttachmentClick(Sender: TObject);
    procedure SnapshotTick(Sender: TObject);
    procedure SystemChanged(Sender: TObject);
  private
    FHost: TMainView;
    FStorage: IStorage;
    FCore: IEmulationCore;
    FOperation: IEmulationSnapshotOperation;
    FMetadata, FSystem: TJSONObject;
    FScreenshot: TBytes;
    FAttachment, FSnapshotPath, FRomLocation: string;
    FAlive: TFunc<Boolean>;
    FInvalidate: TProc;
    FWasPaused, FPreparingCRC, FSending, FSent: Boolean;
    FGeneration: Integer;
    FSnapshotStarted: UInt64;
    procedure UpdateDetails;
    procedure UpdateButtons;
    procedure SetAttachment(const Location: string);
    procedure CloseReport;
  protected
    procedure Resize; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure ApplyLanguage(const PreviousLanguage: string);
    procedure OpenReport(Host: TMainView);
  end;

implementation

uses
  System.Types, System.UITypes, System.Math, System.IOUtils,
  System.Net.HttpClient, System.Net.URLClient, System.Net.Mime, FMX.Graphics,
  FMX.OpenDialog, FMX.BehaviorManager, Core.SavePaths, RM.Styles, RM.Dialogs;

{$R *.fmx}

const
  FeedbackURL = 'https://retromul.retroscraper.pro/feedback/';
  FeedbackToken = 'retromul-feedback-v1-7e8320b09f6a4cd1';
  AttachmentLimit = 50 * 1024 * 1024;
  ArchitectureNames: array[TOSVersion.TArchitecture] of string = ('x86', 'x64', 'ARM32', 'ARM64');

function RomCRC(const Storage: IStorage; const Location: string; const Alive: TFunc<Boolean>): string;
var
  Table: array[0..255] of Cardinal;
  Buffer: array[0..65535] of Byte;
begin
  for var I := 0 to 255 do
  begin
    var Value := Cardinal(I);
    for var Bit := 0 to 7 do
      if (Value and 1) <> 0 then
        Value := (Value shr 1) xor $EDB88320
      else
        Value := Value shr 1;
    Table[I] := Value;
  end;
  var Stream := Storage.OpenRead(Location);
  try
    var CRC := Cardinal($FFFFFFFF);
    while True do
    begin
      if not Alive() then
        Exit('');
      var Count := Stream.Read(Buffer, SizeOf(Buffer));
      if Count = 0 then
        Break;
      for var I := 0 to Count - 1 do
        CRC := (CRC shr 8) xor Table[(CRC xor Buffer[I]) and $FF];
    end;
    Result := IntToHex(CRC xor Cardinal($FFFFFFFF), 8);
  finally
    Stream.Free;
  end;
end;

constructor TFeedbackView.Create(AOwner: TComponent);
begin
  inherited;
  var Alive := True;
  FAlive :=
    function: Boolean
    begin
      Result := Alive;
    end;
  FInvalidate :=
    procedure
    begin
      Alive := False;
    end;
  FMetadata := TJSONObject.Create;
  FSystem := TJSONObject.Create;
  MemoDescription.ScrollAnimation := TBehaviorBoolean.True;
  ApplyLanguage('en');
end;

procedure TFeedbackView.ApplyLanguage(const PreviousLanguage: string);
begin
  FormStyles.RelocalizeUI(Self, PreviousLanguage);
  if Visible then
    UpdateDetails;
end;

destructor TFeedbackView.Destroy;
begin
  FInvalidate();
  TimerSnapshot.Enabled := False;
  if FOperation <> nil then
    FOperation.CancelSnapshot;
  FOperation := nil;
  FCore := nil;
  FMetadata.Free;
  FSystem.Free;
  inherited;
end;

procedure TFeedbackView.Resize;
begin
  inherited;
  if (PanelFeedback = nil) or (csLoading in ComponentState) then
    Exit;
  if (Width < 760) or (Height < 720) then
    PanelFeedback.Align := TAlignLayout.Client
  else
  begin
    PanelFeedback.Align := TAlignLayout.Center;
    PanelFeedback.Width := Min(680, Width - 48);
    PanelFeedback.Height := Min(760, Height - 48);
  end;
end;

procedure TFeedbackView.UpdateDetails;

  function Value(Info: TJSONObject; const Key: string): string;
  begin
    Result := Translate('Not available');
    if Info = nil then
      Exit;
    var Item := Info.GetValue(Key);
    if (Item <> nil) and (Item.Value <> '') then
      Result := Item.Value;
  end;

begin
  if (FMetadata = nil) or (FSystem = nil) then
    Exit;
  LayoutSystemInformation.Visible := CheckBoxSystem.IsChecked;
  EditOperatingSystem.Text := Value(FSystem, 'os');
  EditArchitecture.Text := Value(FSystem, 'architecture');
  EditProcessBits.Text := Value(FSystem, 'process_bits');
  EditProcessorCount.Text := Value(FSystem, 'cpu_count');
  EditScreen.Text := Value(FSystem, 'screen');
  EditVersion.Text := Value(FMetadata, 'version');
  var Session := FMetadata.GetValue<TJSONObject>('session');
  EditPlatform.Text := Value(Session, 'platform');
  var Launch := Value(Session, 'launch_method');
  if Launch = 'file_picker' then
    Launch := Translate('File picker')
  else if Launch = 'library' then
    Launch := Translate('Game library')
  else if Launch = 'drag_and_drop' then
    Launch := Translate('Drag and drop')
  else if Launch = 'direct' then
    Launch := Translate('Direct launch');
  if Value(Session, 'launch_state') = 'snapshot' then
    Launch := Launch + ' · ' + Translate('Save state');
  EditLaunchMethod.Text := Launch;
  var Rom := FMetadata.GetValue<TJSONObject>('rom');
  EditRom.Text := Value(Rom, 'filename');
  EditRomCRC.Text := Value(Rom, 'crc32');
  var Error := FMetadata.GetValue('error');
  LabelError.Visible := (Error <> nil) and (Error.Value <> '');
  if LabelError.Visible then
    LabelError.Text := Translate('Last error: ') + Error.Value;
end;

procedure TFeedbackView.SystemChanged(Sender: TObject);
begin
  UpdateDetails;
end;

procedure TFeedbackView.UpdateButtons;
begin
  ButtonSend.Enabled := not FSending and not FSent and not FPreparingCRC and (FOperation = nil);
  ButtonCancel.Enabled := not FSending;
  ButtonChooseAttachment.Enabled := not FSending and not FSent and (FOperation = nil);
  ButtonRemoveAttachment.Enabled := ButtonChooseAttachment.Enabled and (FAttachment <> '');
  CheckBoxSystem.Enabled := not FSending and not FSent;
  CheckBoxScreenshot.Enabled := not FSending and not FSent and (Length(FScreenshot) > 0);
  MemoDescription.ReadOnly := FSending or FSent;
end;

procedure TFeedbackView.SetAttachment(const Location: string);
begin
  if Location = '' then
  begin
    FAttachment := '';
    LabelAttachment.Text := Translate('No attachment');
  end
  else
  begin
    var Stream := FStorage.OpenRead(Location);
    try
      if (Stream.Size <= 0) or (Stream.Size > AttachmentLimit) then
        raise EInOutError.Create(Translate('Attachment must be between 1 byte and 50 MB.'));
      FAttachment := Location;
      LabelAttachment.Text := FStorage.Describe(Location).Name + ' (' + FormatFloat('0.00', Stream.Size / 1048576) + ' MB)';
    finally
      Stream.Free;
    end;
  end;
  UpdateButtons;
end;

procedure TFeedbackView.OpenReport(Host: TMainView);
begin
  if Visible or FSending then
    Exit;
  Inc(FGeneration);
  FHost := Host;
  Host.State.Session.Reporting := True;
  FStorage := Host.State.Session.Storage;
  FCore := Host.State.Session.Emulation;
  FWasPaused := (FCore = nil) or FCore.IsPaused;
  FSent := False;
  VertScrollBoxContent.Visible := True;
  LayoutSuccess.Visible := False;
  ButtonSend.Visible := True;
  VertScrollBoxContent.ViewportPosition := TPointF.Zero;
  FPreparingCRC := False;
  FScreenshot := nil;
  FAttachment := '';
  FSnapshotPath := '';
  FRomLocation := Host.State.Session.LastReportRom;
  FMetadata.Free;
  FMetadata := TJSONObject.Create;
  var Id := TGUID.NewGuid.ToString.Replace('{', '').Replace('}', '').Replace('-', '').ToLower;
  FMetadata.AddPair('report_id', Id);
  FMetadata.AddPair('app', 'RetroMul');
  FMetadata.AddPair('version', '1.0.0');
  FMetadata.AddPair('error', Host.State.Session.LastReportError);
  var Session := TJSONObject.Create;
  Session.AddPair('platform', Host.State.Session.LastReportPlatform);
  Session.AddPair('launch_method', Host.State.Session.LastReportLaunch);
  Session.AddPair('launch_state', Host.State.Session.LastReportLaunchState);
  Session.AddPair('active', TJSONBool.Create(FCore <> nil));
  Session.AddPair('faulted', TJSONBool.Create(Host.State.Session.EmulationFaulted));
  FMetadata.AddPair('session', Session);
  var Rom := TJSONObject.Create;
  Rom.AddPair('filename', Host.State.Session.LastReportFilename);
  Rom.AddPair('crc32', '');
  Rom.AddPair('crc_scope', 'selected file bytes (archive/container if applicable)');
  FMetadata.AddPair('rom', Rom);
  FSystem.Free;
  FSystem := TJSONObject.Create;
  FSystem.AddPair('os', TOSVersion.ToString);
  FSystem.AddPair('architecture', ArchitectureNames[TOSVersion.Architecture]);
  FSystem.AddPair('process_bits', TJSONNumber.Create(SizeOf(Pointer) * 8));
  FSystem.AddPair('cpu_count', TJSONNumber.Create(TThread.ProcessorCount));
  FSystem.AddPair('screen', IntToStr(Round(Screen.Width)) + 'x' + IntToStr(Round(Screen.Height)));
  CheckBoxSystem.IsChecked := True;
  CheckBoxScreenshot.IsChecked := False;
  ImageScreenshot.Bitmap.Clear(0);
  ImageScreenshot.Visible := False;
  MemoDescription.Text := '';
  LabelStatus.Text := '';
  if FCore <> nil then
  begin
    Host.FormDeactivate(Host);
    FCore.Pause;
    try
      if not Host.ImageCanvas.Bitmap.IsEmpty then
      begin
        ImageScreenshot.Bitmap.Assign(Host.ImageCanvas.Bitmap);
        var Stream := TMemoryStream.Create;
        try
          ImageScreenshot.Bitmap.SaveToStream(Stream);
          if Stream.Size > 10 * 1024 * 1024 then
            raise EInOutError.Create(Translate('Screenshot exceeds 10 MB'));
          SetLength(FScreenshot, Stream.Size);
          Stream.Position := 0;
          Stream.ReadBuffer(FScreenshot, Length(FScreenshot));
        finally
          Stream.Free;
        end;
        ImageScreenshot.Visible := True;
        CheckBoxScreenshot.IsChecked := True;
      end;
    except
      on E: Exception do
        LabelStatus.Text := Translate('Screenshot unavailable: ') + E.Message;
    end;
  end;
  Visible := True;
  BringToFront;
  Resize;
  UpdateDetails;
  SetAttachment('');
  try
    var Path := '';
    if FRomLocation <> '' then
      Path := FindRecordedAutosave(FStorage, FRomLocation);
    if Path <> '' then
      SetAttachment(Path)
    else if (FCore <> nil) and FCore.SupportsSnapshots and not Host.State.Session.EmulationFaulted then
    begin
      FSnapshotPath := ResolveSnapshotPath(Host.GameSnapshotDirectory, SNAPSHOT_AUTOSAVE);
      if Supports(FCore, IEmulationSnapshotOperation, FOperation) then
      begin
        FOperation.BeginSnapshot(SNAPSHOT_AUTOSAVE, False);
        FSnapshotStarted := TThread.GetTickCount64;
        TimerSnapshot.Enabled := True;
        LabelStatus.Text := Translate('Preparing autosave...');
      end
      else
      begin
        FCore.SaveSnapshot(SNAPSHOT_AUTOSAVE);
        SetAttachment(FSnapshotPath);
      end;
    end;
  except
    on E: Exception do
    begin
      FOperation := nil;
      LabelStatus.Text := Translate('Autosave unavailable: ') + E.Message;
    end;
  end;
  if FRomLocation <> '' then
  begin
    FPreparingCRC := True;
    if LabelStatus.Text = '' then
      LabelStatus.Text := Translate('Calculating ROM CRC...');
    var Storage := FStorage;
    var Location := FRomLocation;
    var Alive: TFunc<Boolean> := FAlive;
    var Generation := FGeneration;
    TThread.CreateAnonymousThread(
      procedure
      var
        CRC, Error: string;
      begin
        try
          CRC := RomCRC(Storage, Location, Alive);
        except
          on E: Exception do
            Error := E.Message;
        end;
        TThread.ForceQueue(nil,
          procedure
          begin
            if not Alive() then
              Exit;
            if (Generation <> FGeneration) or not Visible then
              Exit;
            FPreparingCRC := False;
            if LabelStatus.Text = Translate('Calculating ROM CRC...') then
              LabelStatus.Text := '';
            var RomInfo := FMetadata.GetValue<TJSONObject>('rom');
            RomInfo.RemovePair('crc32').Free;
            RomInfo.AddPair('crc32', CRC);
            if Error <> '' then
              RomInfo.AddPair('crc_error', Error);
            UpdateDetails;
            UpdateButtons;
          end);
      end).Start;
  end;
  UpdateButtons;
  Host.SyncActivity;
end;

procedure TFeedbackView.SnapshotTick(Sender: TObject);
begin
  if FOperation = nil then
    Exit;
  try
    var Done, Total: UInt64;
    var Error: string;
    if TThread.GetTickCount64 - FSnapshotStarted > 30000 then
    begin
      FOperation.CancelSnapshot;
      Error := Translate('Autosave timed out. You can send the report without it.');
    end
    else if FOperation.SnapshotStatus(Done, Total, Error) then
      Exit;
    TimerSnapshot.Enabled := False;
    FOperation := nil;
    if Error = '' then
    begin
      SetAttachment(FSnapshotPath);
      LabelStatus.Text := '';
    end
    else
      LabelStatus.Text := Error;
  except
    on E: Exception do
    begin
      TimerSnapshot.Enabled := False;
      FOperation := nil;
      LabelStatus.Text := E.Message;
    end;
  end;
  UpdateButtons;
end;

procedure TFeedbackView.ChooseAttachmentClick(Sender: TObject);
begin
  var Dialog := TFMXOpenDialog.Create(nil);
  try
    Dialog.Title := Translate('Choose report attachment');
    Dialog.Filter := Translate('Snapshots (*.snapshot)|*.snapshot|All files|*');
    Dialog.MultipleSelection := False;
    var Alive: TFunc<Boolean> := FAlive;
    var Generation := FGeneration;
    Dialog.SelectFiles(
      procedure(const Selection: TFMXSelectionResult)
      begin
        if not Alive() then
          Exit;
        if (Generation <> FGeneration) or not Visible then
          Exit;
        try
          if Selection.Error <> '' then
            raise EInOutError.Create(Selection.Error);
          if Selection.Status = TFMXSelectionStatus.Selected then
            SetAttachment(Selection.Locations[0]);
        except
          on E: Exception do
            LabelStatus.Text := E.Message;
        end;
      end);
  finally
    Dialog.Free;
  end;
end;

procedure TFeedbackView.RemoveAttachmentClick(Sender: TObject);
begin
  SetAttachment('');
end;

procedure TFeedbackView.CloseReport;
begin
  Inc(FGeneration);
  TimerSnapshot.Enabled := False;
  if FOperation <> nil then
    FOperation.CancelSnapshot;
  FOperation := nil;
  Visible := False;
  FHost.State.Session.Reporting := False;
  if (FCore <> nil) and (FCore = FHost.State.Session.Emulation) and not FWasPaused and
    not FHost.State.Session.EmulationFaulted and not FHost.State.Session.UserPaused and
    not FHost.State.Session.AutoPaused and not FHost.State.Browser.ViewingLibrary then
    FCore.Resume;
  FCore := nil;
  FHost.State.Input.SuppressInputUntilRelease := True;
  FHost.SyncActivity;
end;

procedure TFeedbackView.CancelClick(Sender: TObject);
begin
  if not FSending then
    CloseReport;
end;

procedure TFeedbackView.SendClick(Sender: TObject);
begin
  if not ButtonSend.Enabled then
    Exit;
  if Length(MemoDescription.Text) > 50000 then
  begin
    LabelStatus.Text := Translate('Description is too long (maximum 50000 characters).');
    Exit;
  end;
  var Report := FMetadata.Clone as TJSONObject;
  var Metadata: string;
  try
    Report.AddPair('description', MemoDescription.Text);
    if CheckBoxSystem.IsChecked then
      Report.AddPair('system', FSystem.Clone as TJSONObject);
    Metadata := Report.ToJSON;
  finally
    Report.Free;
  end;
  var Attachment := FAttachment;
  var Screenshot: TBytes;
  if CheckBoxScreenshot.IsChecked then
    Screenshot := Copy(FScreenshot);
  var Storage := FStorage;
  var Alive: TFunc<Boolean> := FAlive;
  FSending := True;
  LabelStatus.Text := Translate('Sending report...');
  UpdateButtons;
  TThread.CreateAnonymousThread(
    procedure
    var
      Error, ReportId: string;
    begin
      var Client := THTTPClient.Create;
      var Form := TMultipartFormData.Create;
      try
        try
          Client.ConnectionTimeout := 15000;
          Client.ResponseTimeout := 180000;
          Client.HandleRedirects := False;
          Form.AddField('metadata', Metadata, 'application/json; charset=utf-8');
          if Attachment <> '' then
          begin
            var Stream := Storage.OpenRead(Attachment);
            try
              if (Stream.Size < 1) or (Stream.Size > AttachmentLimit) then
                raise EInOutError.Create('Attachment exceeds 50 MB');
              Form.AddStream('attachment', Stream, True, Storage.Describe(Attachment).Name, 'application/octet-stream');
              Stream := nil;
            finally
              Stream.Free;
            end;
          end;
          if Length(Screenshot) > 0 then
            Form.AddBytes('screenshot', Screenshot, 'emulation.png', 'image/png');
          var Response := Client.Post(FeedbackURL, Form, nil,
            [TNameValuePair.Create('Authorization', 'Bearer ' + FeedbackToken)]);
          if (Response.StatusCode <> 200) and (Response.StatusCode <> 201) then
            raise EInOutError.CreateFmt('HTTP %d: %s', [Response.StatusCode, Copy(Response.ContentAsString, 1, 500)]);
          var JSON := TJSONObject.ParseJSONValue(Response.ContentAsString);
          try
            if (JSON = nil) or not JSON.TryGetValue<string>('id', ReportId) or (Length(ReportId) <> 32) then
              raise EInOutError.Create('Invalid server response');
          finally
            JSON.Free;
          end;
        except
          on E: Exception do
            Error := E.Message;
        end;
      finally
        Form.Free;
        Client.Free;
      end;
      TThread.ForceQueue(nil,
        procedure
        begin
          if not Alive() then
            Exit;
          FSending := False;
          FSent := Error = '';
          if FSent then
          begin
            VertScrollBoxContent.Visible := False;
            LayoutSuccess.Visible := True;
            LabelSuccessTitle.Text := Translate('Report sent');
            LabelSuccessMessage.Text := Translate('Thank you for helping improve RetroMul.') +
              sLineBreak + sLineBreak + Translate('Report ID: ') + ReportId;
            ButtonSend.Visible := False;
          end
          else
            LabelStatus.Text := Translate('Could not send report. You can retry. ') + TranslateCoreMessage(Error);
          UpdateButtons;
          if FSent then
            ButtonCancel.SetFocus;
        end);
    end).Start;
end;

end.

