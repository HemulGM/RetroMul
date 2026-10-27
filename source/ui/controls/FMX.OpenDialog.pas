unit FMX.OpenDialog;

interface

uses
  System.SysUtils, System.Classes;

type
  TFMXSelectionStatus = (Selected, Cancelled, Failed);

  TFMXSelectionResult = record
    Status: TFMXSelectionStatus;
    // Android: content URIs, accessed using ContentResolver. Desktop: paths.
    // A folder selection contains exactly one entry.
    Locations: TArray<string>;
    Error: string;
  end;

  TFMXSelectionCallback = reference to procedure(const AResult: TFMXSelectionResult);

  TFMXOpenDialog = class(TComponent)
  private
    FTitle, FFilter, FInitialDirectory, FMimeType: string;
    FMultipleSelection: Boolean;
    FFileMustExist: Boolean;
    procedure Select(AFolder: Boolean; const ACallback: TFMXSelectionCallback; const SaveName: string = '');
  public
    constructor Create(AOwner: TComponent); override;
    // Call on the main thread. Completion is always deferred to the main thread.
    // Requests snapshot the settings and survive destruction of this component.
    // Callbacks must manage the lifetime of any objects they capture.
    procedure SelectFiles(const ACallback: TFMXSelectionCallback);
    procedure SelectFolder(const ACallback: TFMXSelectionCallback);
    procedure SaveFile(const SuggestedName: string; const ACallback: TFMXSelectionCallback);
    property Title: string read FTitle write FTitle;
    property Filter: string read FFilter write FFilter;
    // Desktop filesystem directory. Android providers control the initial folder.
    property InitialDirectory: string read FInitialDirectory write FInitialDirectory;
    // Android MIME filter; Filter is used by desktop dialogs.
    property MimeType: string read FMimeType write FMimeType;
    property MultipleSelection: Boolean read FMultipleSelection write FMultipleSelection;
    property FileMustExist: Boolean read FFileMustExist write FFileMustExist;
  end;

implementation

uses
  FMX.Dialogs, FMX.Platform,
  {$IFDEF ANDROID}
  System.Messaging, Androidapi.Helpers, Androidapi.JNI.App,
  Androidapi.JNI.GraphicsContentViewText, Androidapi.JNI.Net,
  Androidapi.JNI.JavaTypes,
  {$ENDIF}
  {$IFDEF IOS}
  Macapi.ObjectiveC, Macapi.Helpers, iOSapi.Foundation, iOSapi.UIKit,
  iOSapi.Helpers, Core.Storage, System.IOUtils,
  {$ENDIF}
  System.UITypes;

type
  ISelectionRequest = interface
    ['{9C32D8EC-FE3E-461C-AB40-3410B01119A5}']
    procedure Start;
  end;

  {$IFDEF IOS}
  TSelectionRequest = class;

  TIOSSelectionDelegate = class(TOCLocal, UIDocumentPickerDelegate)
  private
    FRequest: TSelectionRequest;
  public
    constructor Create(Request: TSelectionRequest);
    procedure documentPicker(controller: UIDocumentPickerViewController; didPickDocumentsAtURLs: NSArray); overload; cdecl;
    procedure documentPicker(controller: UIDocumentPickerViewController; didPickDocumentAtURL: NSURL); overload; cdecl;
    procedure documentPickerWasCancelled(controller: UIDocumentPickerViewController); cdecl;
  end;
  {$ENDIF}

  TSelectionRequest = class(TInterfacedObject, ISelectionRequest)
  private
    FFolder, FMultiple, FCompleted, FFileMustExist: Boolean;
    FTitle, FFilter, FDirectory, FMime, FSaveName: string;
    FCallback: TFMXSelectionCallback;
    {$IFDEF ANDROID}
    FRequestCode: Integer;
    FSubscribed: Boolean;
    procedure ActivityResult(const Sender: TObject; const Message: TMessage);
    {$ENDIF}
    {$IFDEF IOS}
    FIOSDelegate: TIOSSelectionDelegate;
    FIOSPicker: UIDocumentPickerViewController;
    FExportDirectory: string;
    procedure StartIOS;
    procedure SelectedIOS(const URLs: NSArray);
    {$ENDIF}
    procedure Complete(const AResult: TFMXSelectionResult);
  public
    constructor Create(ADialog: TFMXOpenDialog; AFolder: Boolean; const ACallback: TFMXSelectionCallback; const SaveName: string);
    destructor Destroy; override;
    procedure Start;
  end;

var
  // One native picker at a time, including requests from different components.
  ActiveRequest: ISelectionRequest;
  {$IFDEF ANDROID}
  NextRequestCode: Integer = $6200;
  {$ENDIF}

procedure Deliver(const ACallback: TFMXSelectionCallback; const AResult: TFMXSelectionResult);
begin
  TThread.ForceQueue(nil,
    procedure
    begin
      ACallback(AResult);
    end);
end;

{ TFMXOpenDialog }

constructor TFMXOpenDialog.Create(AOwner: TComponent);
begin
  inherited;
  FFilter := 'All files|*';
  FMimeType := '*/*';
  FMultipleSelection := True;
  FFileMustExist := True;
end;

procedure TFMXOpenDialog.SelectFiles(const ACallback: TFMXSelectionCallback);
begin
  Select(False, ACallback);
end;

procedure TFMXOpenDialog.SelectFolder(const ACallback: TFMXSelectionCallback);
begin
  Select(True, ACallback);
end;

procedure TFMXOpenDialog.SaveFile(const SuggestedName: string; const ACallback: TFMXSelectionCallback);
begin
  if SuggestedName = '' then
    raise EArgumentException.Create('A suggested file name is required');

  Select(False, ACallback, SuggestedName);
end;

procedure TFMXOpenDialog.Select(AFolder: Boolean; const ACallback: TFMXSelectionCallback; const SaveName: string);
begin
  if TThread.CurrentThread.ThreadID <> MainThreadID then
    raise EInvalidOperation.Create('File selection must start on the main thread');

  if not Assigned(ACallback) then
    raise EArgumentNilException.Create('ACallback');

  if ActiveRequest <> nil then
  begin
    var Selection := Default(TFMXSelectionResult);
    Selection.Status := TFMXSelectionStatus.Failed;
    Selection.Error := 'A file or folder picker is already open';
    Deliver(ACallback, Selection);
    Exit;
  end;

  var Request: ISelectionRequest := TSelectionRequest.Create(Self, AFolder, ACallback, SaveName);
  ActiveRequest := Request;
  TThread.ForceQueue(nil,
    procedure
    begin
      Request.Start;
    end);
end;

constructor TSelectionRequest.Create(ADialog: TFMXOpenDialog; AFolder: Boolean; const ACallback: TFMXSelectionCallback; const SaveName: string);
begin
  inherited Create;
  FFolder := AFolder;
  FMultiple := ADialog.MultipleSelection;
  FFileMustExist := ADialog.FileMustExist;
  FTitle := ADialog.Title;
  FFilter := ADialog.Filter;
  FDirectory := ADialog.InitialDirectory;
  FMime := ADialog.MimeType;
  FSaveName := SaveName;
  FCallback := ACallback;
  {$IFDEF ANDROID}
  FRequestCode := NextRequestCode;
  Inc(NextRequestCode);
  if NextRequestCode > $7FFF then
    NextRequestCode := $6200;
  {$ENDIF}
end;

destructor TSelectionRequest.Destroy;
begin
  {$IFDEF IOS}
  if FIOSPicker <> nil then
    FIOSPicker.setDelegate(nil);
  FIOSPicker := nil;
  FIOSDelegate.Free;
  if (FExportDirectory <> '') and TDirectory.Exists(FExportDirectory) then
    TDirectory.Delete(FExportDirectory, True);
  {$ENDIF}
  {$IFDEF ANDROID}
  if FSubscribed then
    TMessageManager.DefaultManager.Unsubscribe(TMessageResultNotification, ActivityResult);
  {$ENDIF}
  inherited;
end;

procedure TSelectionRequest.Complete(const AResult: TFMXSelectionResult);
var
  KeepAlive: ISelectionRequest;
begin
  if FCompleted then
    Exit;

  KeepAlive := Self;
  FCompleted := True;
  {$IFDEF ANDROID}
  if FSubscribed then
  begin
    TMessageManager.DefaultManager.Unsubscribe(TMessageResultNotification, ActivityResult);
    FSubscribed := False;
  end;
  {$ENDIF}
  var Callback := FCallback;
  FCallback := nil;
  ActiveRequest := nil;
  // Keep the native delegate alive until UIKit has returned from its callback.
  TThread.ForceQueue(nil,
    procedure
    begin
      if KeepAlive <> nil then
        Callback(AResult);
    end);
end;

{$IFDEF IOS}
constructor TIOSSelectionDelegate.Create(Request: TSelectionRequest);
begin
  inherited Create;
  FRequest := Request;
end;

procedure TIOSSelectionDelegate.documentPicker(controller: UIDocumentPickerViewController; didPickDocumentsAtURLs: NSArray);
begin
  FRequest.SelectedIOS(didPickDocumentsAtURLs);
end;

procedure TIOSSelectionDelegate.documentPicker(controller: UIDocumentPickerViewController; didPickDocumentAtURL: NSURL);
begin
  FRequest.SelectedIOS(TNSArray.Wrap(TNSArray.OCClass.arrayWithObject((didPickDocumentAtURL as ILocalObject).GetObjectID)));
end;

procedure TIOSSelectionDelegate.documentPickerWasCancelled(controller: UIDocumentPickerViewController);
begin
  var Selection := Default(TFMXSelectionResult);
  Selection.Status := TFMXSelectionStatus.Cancelled;
  FRequest.Complete(Selection);
end;

procedure TSelectionRequest.SelectedIOS(const URLs: NSArray);
begin
  if FCompleted then
    Exit;
  var Selection := Default(TFMXSelectionResult);
  try
    if (URLs = nil) or (URLs.count = 0) then
      raise EInOutError.Create('The picker returned no document');
    SetLength(Selection.Locations, URLs.count);
    for var I := 0 to High(Selection.Locations) do
      Selection.Locations[I] := RememberIOSDocumentURL(TNSURL.Wrap(URLs.objectAtIndex(I)));
    Selection.Status := TFMXSelectionStatus.Selected;
  except
    on E: Exception do
    begin
      Selection.Status := TFMXSelectionStatus.Failed;
      Selection.Locations := nil;
      Selection.Error := E.Message;
    end;
  end;
  Complete(Selection);
end;

procedure TSelectionRequest.StartIOS;
begin
  var Window := TiOSHelper.SharedApplication.keyWindow;
  if Window = nil then
    raise EInvalidOperation.Create('No active window for document selection');

  var Presenter := Window.rootViewController;
  if Presenter = nil then
    raise EInvalidOperation.Create('No view controller for document selection');

  while Presenter.presentedViewController <> nil do
    Presenter := Presenter.presentedViewController;
  if FSaveName <> '' then
  begin
    // Moving a sandbox placeholder returns a writable, security-scoped URL.
    // The caller writes its contents after the asynchronous selection completes.
    FExportDirectory := TPath.Combine(TPath.GetTempPath, 'retromul-export-' + TGUID.NewGuid.ToString);
    TDirectory.CreateDirectory(FExportDirectory);
    var Path := TPath.Combine(FExportDirectory, TPath.GetFileName(FSaveName));
    TFile.WriteAllBytes(Path, nil);
    var URL := TNSURL.OCClass.fileURLWithPath(StrToNSStr(Path));
    FIOSPicker := TUIDocumentPickerViewController.Wrap(
      TUIDocumentPickerViewController.Alloc.initWithURL(URL, UIDocumentPickerModeMoveToService));
  end
  else
  begin
    var UTI := 'public.item';
    if FFolder then
      UTI := 'public.folder';
    var Types := TNSArray.Wrap(TNSArray.OCClass.arrayWithObject((StrToNSStr(UTI) as ILocalObject).GetObjectID));
    FIOSPicker := TUIDocumentPickerViewController.Wrap(
      TUIDocumentPickerViewController.Alloc.initWithDocumentTypes(Types, UIDocumentPickerModeOpen));
    FIOSPicker.setAllowsMultipleSelection(FMultiple and not FFolder);
  end;
  if FIOSPicker = nil then
    raise ENotSupportedException.Create('Cannot create the document picker');

  FIOSDelegate := TIOSSelectionDelegate.Create(Self);
  FIOSPicker.setDelegate(FIOSDelegate.GetObjectID);
  FIOSPicker.setTitle(StrToNSStr(FTitle));
  Presenter.presentViewController(FIOSPicker, True, nil);
end;
{$ENDIF}

procedure TSelectionRequest.Start;
begin
  var Selection := Default(TFMXSelectionResult);
  Selection.Status := TFMXSelectionStatus.Cancelled;
  try
    {$IFDEF ANDROID}
    var Intent: JIntent;
    if FFolder then
      Intent := TJIntent.JavaClass.init(TJIntent.JavaClass.ACTION_OPEN_DOCUMENT_TREE)
    else
    begin
      if FSaveName <> '' then
      begin
        Intent := TJIntent.JavaClass.init(TJIntent.JavaClass.ACTION_CREATE_DOCUMENT);
        Intent.putExtra(TJIntent.JavaClass.EXTRA_TITLE, StringToJString(FSaveName));
      end
      else
        Intent := TJIntent.JavaClass.init(TJIntent.JavaClass.ACTION_OPEN_DOCUMENT);
      Intent.addCategory(TJIntent.JavaClass.CATEGORY_OPENABLE);
      if FMime = '' then
        FMime := '*/*';
      Intent.setType(StringToJString(FMime));
      if FSaveName = '' then
        Intent.putExtra(TJIntent.JavaClass.EXTRA_ALLOW_MULTIPLE, FMultiple);
    end;
    Intent.addFlags(TJIntent.JavaClass.FLAG_GRANT_READ_URI_PERMISSION or
      TJIntent.JavaClass.FLAG_GRANT_PERSISTABLE_URI_PERMISSION);
    if FSaveName <> '' then
      Intent.addFlags(TJIntent.JavaClass.FLAG_GRANT_WRITE_URI_PERMISSION);
    if FFolder then
      Intent.addFlags(TJIntent.JavaClass.FLAG_GRANT_PREFIX_URI_PERMISSION);
    TMessageManager.DefaultManager.SubscribeToMessage(TMessageResultNotification, ActivityResult);
    FSubscribed := True;
    TAndroidHelper.Activity.startActivityForResult(Intent, FRequestCode);
    Exit;
    {$ELSE}
    {$IFDEF IOS}
    StartIOS;
    Exit;
    {$ELSE}
    // Desktop native dialogs run their modal UI loop. The public API and
    // completion stay asynchronous; no FMX controls are used on worker threads.
    var Service: IFMXDialogService;
    if not TPlatformServices.Current.SupportsPlatformService(IFMXDialogService, Service) then
      raise ENotSupportedException.Create('File dialogs are unavailable on this platform');

    if FSaveName <> '' then
    begin
      var SaveDialog := TSaveDialog.Create(nil);
      try
        SaveDialog.Title := FTitle;
        SaveDialog.Filter := FFilter;
        SaveDialog.InitialDir := FDirectory;
        SaveDialog.FileName := FSaveName;
        SaveDialog.DefaultExt := ExtractFileExt(FSaveName).TrimLeft(['.']);
        SaveDialog.Options := [TOpenOption.ofPathMustExist, TOpenOption.ofNoChangeDir, TOpenOption.ofOverwritePrompt];
        if SaveDialog.Execute then
        begin
          Selection.Locations := [SaveDialog.FileName];
          Selection.Status := TFMXSelectionStatus.Selected;
        end;
      finally
        SaveDialog.Free;
      end;
    end
    else
    begin
      var Dialog := TOpenDialog.Create(nil);
      try
        Dialog.Title := FTitle;
        // GTK treats *.* literally: it excludes names without a dot, including
        // directories. Folder selection must ignore any file-extension filter.
        if FFolder then
          Dialog.Filter := 'Folders|*'
        else
          Dialog.Filter := FFilter;
        Dialog.InitialDir := FDirectory;
        Dialog.Options := [TOpenOption.ofPathMustExist, TOpenOption.ofNoChangeDir];
        if FFileMustExist and not FFolder then
          Dialog.Options := Dialog.Options + [TOpenOption.ofFileMustExist];
        if FMultiple and not FFolder then
          Dialog.Options := Dialog.Options + [TOpenOption.ofAllowMultiSelect];
        var Files: TStrings := TStringList.Create;
        try
          var DialogType := TDialogType.Standard;
          if FFolder then
            DialogType := TDialogType.Directory;
          if Service.DialogOpenFiles(Dialog, Files, DialogType) then
          begin
            Selection.Locations := Files.ToStringArray;
            if Length(Selection.Locations) = 0 then
              raise EInvalidOperation.Create('The picker returned no selection');

            Selection.Status := TFMXSelectionStatus.Selected;
          end;
        finally
          Files.Free;
        end;
      finally
        Dialog.Free;
      end;
    end;
    {$ENDIF}
    {$ENDIF}
  except
    on E: Exception do
    begin
      Selection.Status := TFMXSelectionStatus.Failed;
      Selection.Locations := nil;
      Selection.Error := E.Message;
    end;
  end;
  Complete(Selection);
end;

{$IFDEF ANDROID}
procedure TSelectionRequest.ActivityResult(const Sender: TObject; const Message: TMessage);
begin
  if FCompleted or not (Message is TMessageResultNotification) then
    Exit;

  var Notification := TMessageResultNotification(Message);
  if Notification.RequestCode <> FRequestCode then
    Exit;

  var Selection := Default(TFMXSelectionResult);
  Selection.Status := TFMXSelectionStatus.Cancelled;
  try
    if Notification.ResultCode = TJActivity.JavaClass.RESULT_OK then
    begin
      var Intent := Notification.Value;
      if Intent = nil then
        raise EInvalidOperation.Create('The picker returned no document');

      var Clip := Intent.getClipData;
      if not FFolder and (Clip <> nil) then
      begin
        SetLength(Selection.Locations, Clip.getItemCount);
        for var I := 0 to Clip.getItemCount - 1 do
        begin
          var Uri := Clip.getItemAt(I).getUri;
          if Uri = nil then
            raise EInvalidOperation.Create('The picker returned an invalid document');

          Selection.Locations[I] := JStringToString(Uri.toString);
        end;
      end
      else
      begin
        var Uri := Intent.getData;
        if Uri = nil then
          raise EInvalidOperation.Create('The picker returned no document');

        Selection.Locations := [JStringToString(Uri.toString)];
      end;
      if Length(Selection.Locations) = 0 then
        raise EInvalidOperation.Create('The picker returned no selection');

      // Preserve read access when the provider grants persistable permission.
      if (Intent.getFlags and TJIntent.JavaClass.FLAG_GRANT_PERSISTABLE_URI_PERMISSION) <> 0 then
      begin
        var PermissionMask := TJIntent.JavaClass.FLAG_GRANT_READ_URI_PERMISSION;
        if FSaveName <> '' then
          PermissionMask := PermissionMask or TJIntent.JavaClass.FLAG_GRANT_WRITE_URI_PERMISSION;
        var Flags := Intent.getFlags and PermissionMask;
        for var Location in Selection.Locations do
          TAndroidHelper.Context.getContentResolver.takePersistableUriPermission(
            TJnet_Uri.JavaClass.parse(StringToJString(Location)), Flags);
      end;
      Selection.Status := TFMXSelectionStatus.Selected;
    end;
  except
    on E: Exception do
    begin
      Selection.Status := TFMXSelectionStatus.Failed;
      Selection.Locations := nil;
      Selection.Error := E.Message;
    end;
  end;
  Complete(Selection);
end;
{$ENDIF}

end.

