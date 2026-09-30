unit RM.RomPicker.Android;

interface

uses
  System.Messaging, Androidapi.Jni, Androidapi.JNI.GraphicsContentViewText,
  Androidapi.JNI.Net;

type
  IRomImport = interface
    ['{871CFC81-D811-4B37-9A59-E8468E861B41}']
    procedure Run(const Resolver: JContentResolver; const Uri: Jnet_Uri);
    procedure Cancel;
    function Snapshot(out FileName, DisplayName, Error: string): Boolean;
  end;

  // Activity results are asynchronous. A detached worker owns its import job;
  // it never captures the form/picker or queues callbacks to a destroyed owner.
  TAndroidRomPicker = class
  private
    FWaiting, FReady: Boolean;
    FError: string;
    FJob: IRomImport;
    procedure ActivityResult(const Sender: TObject; const Message: TMessage);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Open;
    function Poll(out FileName, DisplayName, Error: string): Boolean;
    // Keep the private file alive until LoadRom has finished reading it.
    procedure Finish;
  end;

implementation

uses
  System.SysUtils, System.Classes, System.IOUtils, Androidapi.Helpers,
  Androidapi.JNI.App, Androidapi.JNI.JavaTypes, Androidapi.JNIBridge;

const
  ROM_REQUEST_CODE = $4E45;
  MAX_ROM_IMPORT_BYTES = 64 * 1024 * 1024;

type
  TRomImport = class(TInterfacedObject, IRomImport)
  private
    FCancelled, FDone: Boolean;
    FFileName, FDisplayName, FError: string;
    function Cancelled: Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Run(const Resolver: JContentResolver; const Uri: Jnet_Uri);
    procedure Cancel;
    function Snapshot(out FileName, DisplayName, Error: string): Boolean;
  end;

constructor TRomImport.Create;
begin
  inherited;
  FFileName := TPath.Combine(TPath.GetTempPath, TGUID.NewGuid.ToString + '.rom');
  FDisplayName := 'Temp.rom';
end;

destructor TRomImport.Destroy;
begin
  try
    if TFile.Exists(FFileName) then
      TFile.Delete(FFileName);
  except
    // Cache eviction/cleanup must not raise during form or thread destruction.
  end;
  inherited;
end;

procedure TRomImport.Cancel;
begin
  TMonitor.Enter(Self);
  try
    FCancelled := True;
  finally
    TMonitor.Exit(Self);
  end;
end;

function TRomImport.Cancelled: Boolean;
begin
  TMonitor.Enter(Self);
  try
    Result := FCancelled;
  finally
    TMonitor.Exit(Self);
  end;
end;

function TRomImport.Snapshot(out FileName, DisplayName, Error: string): Boolean;
begin
  TMonitor.Enter(Self);
  try
    Result := FDone;
    if Result then
    begin
      FileName := FFileName;
      DisplayName := FDisplayName;
      Error := FError;
    end;
  finally
    TMonitor.Exit(Self);
  end;
end;

procedure TRomImport.Run(const Resolver: JContentResolver; const Uri: Jnet_Uri);
begin
  try
    try
      if Cancelled then
        Exit;
      // A provider URI is not a filesystem path. Metadata is only a UI label;
      // never use an untrusted document name to build the private cache path.
      try
        var Cursor := Resolver.query(Uri, nil, nil, nil, nil);
        if Cursor <> nil then
        try
          var Column := Cursor.getColumnIndex(StringToJString('_display_name'));
          if (Column >= 0) and Cursor.moveToFirst then
            FDisplayName := JStringToString(Cursor.getString(Column));
        finally
          Cursor.close;
        end;
      except
        // Some document providers do not expose a display name.
      end;
      if Cancelled then
        Exit;
      var Extension := TPath.GetExtension(FDisplayName).ToLower;
      if (Extension <> '.nes') and (Extension <> '.gb') and (Extension <> '.gbc') and
        (Extension <> '.md') and (Extension <> '.gen') and (Extension <> '.bin') and (Extension <> '.smd') then
        raise Exception.Create('Choose a .nes, .gb, .gbc, .md, .gen, .bin or .smd ROM');
      FFileName := ChangeFileExt(FFileName, Extension);
      var Input := Resolver.openInputStream(Uri);
      if Input = nil then
        raise Exception.Create('Cannot open the selected document');
      try
        var Output := TFileStream.Create(FFileName, fmCreate);
        try
          var Buffer := TJavaArray<Byte>.Create(64 * 1024);
          try
            while not Cancelled do
            begin
              var Count := Input.read(Buffer);
              if Count = -1 then
                Break;
              if (Count <= 0) or (Count > Buffer.Length) then
                raise Exception.Create('Document provider returned an invalid read');
              if Output.Size + Count > MAX_ROM_IMPORT_BYTES then
                raise Exception.Create('ROM exceeds the 64 MiB import limit');
              Output.WriteBuffer(Buffer.Data^, Count);
              Buffer.Sync;
            end;
          finally
            Buffer.Free;
          end;
        finally
          Output.Free;
        end;
      finally
        Input.close;
      end;
    except
      on E: Exception do
        FError := E.Message;
    end;
  finally
    TMonitor.Enter(Self);
    try
      FDone := True;
    finally
      TMonitor.Exit(Self);
    end;
  end;
end;

constructor TAndroidRomPicker.Create;
begin
  inherited;
  TMessageManager.DefaultManager.SubscribeToMessage(TMessageResultNotification, ActivityResult);
end;

destructor TAndroidRomPicker.Destroy;
begin
  TMessageManager.DefaultManager.Unsubscribe(TMessageResultNotification, ActivityResult);
  Finish;
  inherited;
end;

procedure TAndroidRomPicker.Open;
begin
  if FWaiting or FReady or (FJob <> nil) then
    Exit;
  var Intent := TJIntent.JavaClass.init(TJIntent.JavaClass.ACTION_OPEN_DOCUMENT);
  Intent.addCategory(TJIntent.JavaClass.CATEGORY_OPENABLE);
  // .nes has no universally registered MIME type. Validate the file in the core.
  Intent.setType(StringToJString('*/*'));
  Intent.addFlags(TJIntent.JavaClass.FLAG_GRANT_READ_URI_PERMISSION);
  FWaiting := True;
  try
    TAndroidHelper.Activity.startActivityForResult(Intent, ROM_REQUEST_CODE);
  except
    FWaiting := False;
    raise;
  end;
end;

procedure TAndroidRomPicker.ActivityResult(const Sender: TObject; const Message: TMessage);
begin
  if not FWaiting or not (Message is TMessageResultNotification) then
    Exit;
  var Notification := TMessageResultNotification(Message);
  if Notification.RequestCode <> ROM_REQUEST_CODE then
    Exit;
  FWaiting := False;
  FReady := True;
  FError := '';
  if Notification.ResultCode <> TJActivity.JavaClass.RESULT_OK then
    Exit;
  try
    if (Notification.Value = nil) or (Notification.Value.getData = nil) then
      raise Exception.Create('No document was returned by the file picker');
    var Uri := Notification.Value.getData;
    var Resolver := TAndroidHelper.Context.getContentResolver;
    var Job: IRomImport := TRomImport.Create;
    FJob := Job;
    TThread.CreateAnonymousThread(
      procedure
      begin
        Job.Run(Resolver, Uri);
      end).Start;
  except
    on E: Exception do
    begin
      FError := E.Message;
      FJob := nil;
    end;
  end;
end;

function TAndroidRomPicker.Poll(out FileName, DisplayName, Error: string): Boolean;
begin
  FileName := '';
  DisplayName := '';
  Error := '';
  if FJob <> nil then
    Exit(FJob.Snapshot(FileName, DisplayName, Error));
  Result := FReady;
  if Result then
    Error := FError;
end;

procedure TAndroidRomPicker.Finish;
begin
  if FJob <> nil then
    FJob.Cancel;
  FJob := nil;
  FReady := False;
  FError := '';
end;

end.

