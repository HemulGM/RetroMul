unit RM.DocumentTransfer.Android;

interface

uses
  Core.Storage, System.Messaging, Androidapi.Jni, Androidapi.JNI.GraphicsContentViewText,
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
  TAndroidDocumentTransfer = class
  private
    FWaiting, FReady: Boolean;
    FForCassette: Boolean;
    FError: string;
    FExportSource: string;
    FJob: IRomImport;
    FStorage: IStorage;
    procedure ActivityResult(const Sender: TObject; const Message: TMessage);
  public
    constructor Create(const Storage: IStorage);
    destructor Destroy; override;
    procedure Import(const Uri: string; ForCassette: Boolean = False);
    procedure Save(const SourceFile, SuggestedName: string);
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
    FForCassette: Boolean;
    FExporting: Boolean;
    FFileName, FDisplayName, FError: string;
    FStorage: IStorage;
    function Cancelled: Boolean;
  public
    constructor Create(ForCassette: Boolean; const Storage: IStorage; const ExportSource: string = '');
    destructor Destroy; override;
    procedure Run(const Resolver: JContentResolver; const Uri: Jnet_Uri);
    procedure Cancel;
    function Snapshot(out FileName, DisplayName, Error: string): Boolean;
  end;

constructor TRomImport.Create(ForCassette: Boolean; const Storage: IStorage; const ExportSource: string);
begin
  inherited Create;
  FStorage := Storage;
  FForCassette := ForCassette;
  FFileName := FStorage.TemporaryFile('.tape');
  FDisplayName := 'Temp.rom';
  FExporting := ExportSource <> '';
  if FExporting then
    FFileName := ExportSource;
end;

destructor TRomImport.Destroy;
begin
  try
    FStorage.Delete(FFileName);
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
      if FExporting then
        FileName := ''; // Export completion must not load a ROM.
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
      if Cancelled then Exit;
      var Location := JStringToString(Uri.toString);
      if not FExporting then
      begin
        var Info := FStorage.Describe(Location);
        FDisplayName := Info.Name;
        if FForCassette and not SameText(ExtractFileExt(FDisplayName), '.tape') then
          raise EReadError.Create('Choose a .tape cassette');
      end;
      var Input: TStream;
      var Output: TStream;
      if FExporting then
      begin
        Input := FStorage.OpenRead(FFileName);
        try Output := FStorage.OpenWrite(Location); except Input.Free; raise; end;
      end
      else
      begin
        Input := FStorage.OpenRead(Location);
        try Output := FStorage.OpenWrite(FFileName); except Input.Free; raise; end;
      end;
      try
        var Buffer: array[0..65535] of Byte;
        var Total: Int64 := 0;
        while not Cancelled do
        begin
          var Count := Input.Read(Buffer, SizeOf(Buffer));
          if Count = 0 then Break;
          Inc(Total, Count);
          if Total > MAX_ROM_IMPORT_BYTES then raise EReadError.Create('Document exceeds 64 MiB');
          Output.WriteBuffer(Buffer, Count);
        end;
      finally Output.Free; Input.Free; end;
    except on E: Exception do FError := E.Message; end;
  finally
    TMonitor.Enter(Self);
    try FDone := True; finally TMonitor.Exit(Self); end;
  end;
end;

constructor TAndroidDocumentTransfer.Create(const Storage: IStorage);
begin
  inherited Create;
  FStorage := Storage;
  TMessageManager.DefaultManager.SubscribeToMessage(TMessageResultNotification, ActivityResult);
end;

destructor TAndroidDocumentTransfer.Destroy;
begin
  TMessageManager.DefaultManager.Unsubscribe(TMessageResultNotification, ActivityResult);
  Finish;
  inherited;
end;

procedure TAndroidDocumentTransfer.Import(const Uri: string; ForCassette: Boolean);
begin
  if FWaiting or FReady or (FJob <> nil) then
    raise EInvalidOperation.Create('A document transfer is already active');
  var Resolver := TAndroidHelper.Context.getContentResolver;
  var DocumentUri := TJnet_Uri.JavaClass.parse(StringToJString(Uri));
  var Job: IRomImport := TRomImport.Create(ForCassette, FStorage);
  FJob := Job;
  TThread.CreateAnonymousThread(
    procedure
    begin
      Job.Run(Resolver, DocumentUri);
    end).Start;
end;

procedure TAndroidDocumentTransfer.Save(const SourceFile, SuggestedName: string);
begin
  if FWaiting or FReady or (FJob <> nil) then
    raise EInvalidOperation.Create('A file picker is already open');
  FForCassette := True;
  FExportSource := SourceFile;
  var Intent := TJIntent.JavaClass.init(TJIntent.JavaClass.ACTION_CREATE_DOCUMENT);
  Intent.addCategory(TJIntent.JavaClass.CATEGORY_OPENABLE);
  Intent.setType(StringToJString('application/octet-stream'));
  Intent.putExtra(TJIntent.JavaClass.EXTRA_TITLE, StringToJString(SuggestedName));
  Intent.addFlags(TJIntent.JavaClass.FLAG_GRANT_WRITE_URI_PERMISSION);
  FWaiting := True;
  try
    TAndroidHelper.Activity.startActivityForResult(Intent, ROM_REQUEST_CODE);
  except
    FWaiting := False;
    FExportSource := '';
    raise;
  end;
end;

procedure TAndroidDocumentTransfer.ActivityResult(const Sender: TObject; const Message: TMessage);
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
    var Job: IRomImport := TRomImport.Create(FForCassette, FStorage, FExportSource);
    FJob := Job;
    FExportSource := ''; // The job now owns the temporary export file.
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

function TAndroidDocumentTransfer.Poll(out FileName, DisplayName, Error: string): Boolean;
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

procedure TAndroidDocumentTransfer.Finish;
begin
  if FJob <> nil then
    FJob.Cancel;
  FJob := nil;
  if FExportSource <> '' then
  begin
    FStorage.Delete(FExportSource);
    FExportSource := '';
  end;
  FReady := False;
  FError := '';
end;

end.

