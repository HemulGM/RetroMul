unit RM.FolderPicker.Android;

interface

uses
  System.SysUtils, System.Classes;

type
  TRomFile = record
    Name: string;
    RelativePath: string;
    Uri: string;
    MimeType: string;
    Size: Int64;

    function Extension: string;
  end;

  TRomStorage = class
  public
    class var
      FolderUri: string;
    class procedure SelectFolder(const AOnSelected: TProc<Boolean> = nil); static;
    class function HasFolder: Boolean; static;
    class procedure ClearFolder; static;
    class function GetFiles(const AExtensions: array of string; ARecursive: Boolean = True): TArray<TRomFile>; static;
    class function GetAllFiles(ARecursive: Boolean = True): TArray<TRomFile>; static;
    class function OpenFile(const AFile: TRomFile): TStream; static;
    class function OpenUri(const AUri: string): TStream; static;
    {$IFDEF ANDROID}
    class function SaveToFile(RomFile: TRomFile): string; static;
   {$ENDIF}
  end;

implementation

uses
  System.Generics.Collections, FMX.Dialogs,
  {$IFDEF ANDROID}
  System.Messaging, Androidapi.Helpers, Androidapi.JNI.App,
  Androidapi.JNI.GraphicsContentViewText, Androidapi.JNI.JavaTypes,
  Androidapi.JNI.Net, Androidapi.JNI.Provider, Androidapi.JNIBridge,
  {$ENDIF}
  System.IOUtils;

const
  CStorageFileName = 'rom-folder.uri';

{$IFDEF ANDROID}
const
  CSelectFolderRequestCode = 17431;
  CStreamBufferSize = 64 * 1024;

var
  GOnFolderSelected: TProc<Boolean>;
  GMessageListener: TMessageListener;
  GMessageSubscription: TMessageSubscriptionId;
{$ENDIF}

function TRomFile.Extension: string;
begin
  Result := TPath.GetExtension(Name);
end;

function StorageFileName: string;
begin
  Result := TPath.Combine(TPath.GetDocumentsPath, CStorageFileName);
end;

procedure SaveFolderUri(const AUri: string);
begin
  TRomStorage.FolderUri := AUri;
end;

class function TRomStorage.HasFolder: Boolean;
begin
  Result := not FolderUri.IsEmpty;
end;

{$IFDEF ANDROID}

function StringToUri(const AUri: string): Jnet_Uri;
begin
  Result := TJnet_Uri.JavaClass.parse(StringToJString(AUri));
end;

function ContentResolver: JContentResolver;
begin
  Result := TAndroidHelper.Context.getContentResolver;
end;

function NormalizeExtension(const AExtension: string): string;
begin
  Result := AExtension.Trim.ToLower;
  if not Result.IsEmpty and not Result.StartsWith('.') then
    Result := '.' + Result;
end;

function ExtensionAccepted(const AFileName: string; const AExtensions: array of string): Boolean;
begin
  if Length(AExtensions) = 0 then
    Exit(True);

  var LExtension := TPath.GetExtension(AFileName).ToLower;

  for var I := Low(AExtensions) to High(AExtensions) do
    if LExtension = NormalizeExtension(AExtensions[I]) then
      Exit(True);

  Result := False;
end;

procedure ReadDirectory(const ATreeUri: Jnet_Uri; const ADocumentId: JString; const ARelativePath: string; const AExtensions: array of string; const ARecursive: Boolean; const AFiles: TList<TRomFile>);
begin
  var LChildrenUri := TJDocumentsContract.JavaClass.buildChildDocumentsUriUsingTree(ATreeUri, ADocumentId);

  var LProjection := TJavaObjectArray<JString>.Create(4);
  try
    LProjection.Items[0] := TJDocumentsContract_Document.JavaClass.COLUMN_DOCUMENT_ID;
    LProjection.Items[1] := TJDocumentsContract_Document.JavaClass.COLUMN_DISPLAY_NAME;
    LProjection.Items[2] := TJDocumentsContract_Document.JavaClass.COLUMN_MIME_TYPE;
    LProjection.Items[3] := TJDocumentsContract_Document.JavaClass.COLUMN_SIZE;

    var LCursor := ContentResolver.query(LChildrenUri, LProjection, nil, nil, nil);

    if LCursor = nil then
      Exit;

    try
      while LCursor.moveToNext do
      begin
        var LDocumentId := LCursor.getString(0);
        var LName := JStringToString(LCursor.getString(1));
        var LMimeType := JStringToString(LCursor.getString(2));

        var LPath: string;
        if ARelativePath.IsEmpty then
          LPath := LName
        else
          LPath := ARelativePath + '/' + LName;

        if LMimeType = JStringToString(TJDocumentsContract_Document.JavaClass.MIME_TYPE_DIR) then
        begin
          if ARecursive then
            ReadDirectory(ATreeUri, LDocumentId, LPath, AExtensions, True, AFiles);

          Continue;
        end;

        if not ExtensionAccepted(LName, AExtensions) then
          Continue;

        var LDocumentUri := TJDocumentsContract.JavaClass.buildDocumentUriUsingTree(ATreeUri, LDocumentId);

        var LFile: TRomFile;
        LFile.Name := LName;
        LFile.RelativePath := LPath;
        LFile.Uri := JStringToString(LDocumentUri.toString);
        LFile.MimeType := LMimeType;

        if LCursor.isNull(3) then
          LFile.Size := -1
        else
          LFile.Size := LCursor.getLong(3);

        AFiles.Add(LFile);
      end;
    finally
      LCursor.close;
    end;
  finally
    LProjection.Free;
  end;
end;

procedure HandleFolderResult(const AResultCode: Integer; const AIntent: JIntent);
begin
  var LSuccess := False;
  try
    if (AResultCode <> TJActivity.JavaClass.RESULT_OK) or (AIntent = nil) then
      Exit;

    var LUri := AIntent.getData;
    if LUri = nil then
      Exit;

    var LFlags := AIntent.getFlags and
      (TJIntent.JavaClass.FLAG_GRANT_READ_URI_PERMISSION or TJIntent.JavaClass.FLAG_GRANT_WRITE_URI_PERMISSION);

    if (LFlags and TJIntent.JavaClass.FLAG_GRANT_READ_URI_PERMISSION) = 0 then
      LFlags := LFlags or TJIntent.JavaClass.FLAG_GRANT_READ_URI_PERMISSION;

    ContentResolver.takePersistableUriPermission(LUri, LFlags);

    SaveFolderUri(JStringToString(LUri.toString));
    LSuccess := True;
  finally
    var LCallback := GOnFolderSelected;
    GOnFolderSelected := nil;

    if Assigned(LCallback) then
      LCallback(LSuccess);
  end;
end;

procedure HandleAndroidMessage(const Sender: TObject; const M: TMessage);
begin
  if not (M is TMessageResultNotification) then
    Exit;

  var LMessage := TMessageResultNotification(M);

  if LMessage.RequestCode <> CSelectFolderRequestCode then
    Exit;

  HandleFolderResult(LMessage.ResultCode, LMessage.Value);
end;

class procedure TRomStorage.SelectFolder(const AOnSelected: TProc<Boolean>);
begin
  GOnFolderSelected := AOnSelected;

  var LIntent := TJIntent.Create;
  LIntent.setAction(TJIntent.JavaClass.ACTION_OPEN_DOCUMENT_TREE);

  LIntent.addFlags(
    TJIntent.JavaClass.FLAG_GRANT_READ_URI_PERMISSION or
    TJIntent.JavaClass.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
    TJIntent.JavaClass.FLAG_GRANT_PREFIX_URI_PERMISSION
  );

  TAndroidHelper.Activity.startActivityForResult(LIntent, CSelectFolderRequestCode);
end;

class procedure TRomStorage.ClearFolder;
begin
  var LUriText := FolderUri;

  if not LUriText.IsEmpty then
  begin
    try
      ContentResolver.releasePersistableUriPermission(StringToUri(LUriText), TJIntent.JavaClass.FLAG_GRANT_READ_URI_PERMISSION);
    except
    end;
  end;

  SaveFolderUri('');
end;

class function TRomStorage.GetFiles(const AExtensions: array of string; ARecursive: Boolean): TArray<TRomFile>;
begin
  var LUriText := FolderUri;

  if LUriText.IsEmpty then
    Exit(nil);

  var LTreeUri := StringToUri(LUriText);
  var LRootId := TJDocumentsContract.JavaClass.getTreeDocumentId(LTreeUri);

  var LFiles := TList<TRomFile>.Create;
  try
    ReadDirectory(LTreeUri, LRootId, '', AExtensions, ARecursive, LFiles);
    Result := LFiles.ToArray;
  finally
    LFiles.Free;
  end;
end;

class function TRomStorage.SaveToFile(RomFile: TRomFile): string;
begin
  var Extension := TPath.GetExtension(RomFile.Name).ToLower;
  if (Extension <> '.nes') and (Extension <> '.gb') and (Extension <> '.gbc') and
    (Extension <> '.md') and (Extension <> '.gen') and (Extension <> '.bin') and (Extension <> '.smd') then
    raise Exception.Create('Choose a .nes, .gb, .gbc, .md, .gen, .bin or .smd ROM');
  Result := TPath.Combine(TPath.GetTempPath, ChangeFileExt('retromul_temp.rom', Extension));
  var Input := OpenFile(RomFile);
  if Input = nil then
    raise Exception.Create('Cannot open the selected document');
  try
    var Output := TFileStream.Create(Result, fmCreate);
    try
      Output.CopyFrom(Input);
    finally
      Output.Free;
    end;
  finally
    Input.Free;
  end;
end;

class function TRomStorage.GetAllFiles(ARecursive: Boolean): TArray<TRomFile>;
begin
  Result := GetFiles([], ARecursive);
end;

class function TRomStorage.OpenFile(const AFile: TRomFile): TStream;
begin
  Result := OpenUri(AFile.Uri);
end;

class function TRomStorage.OpenUri(const AUri: string): TStream;
begin
  if AUri.IsEmpty then
    raise EArgumentException.Create('URI is empty');

  var LInput := ContentResolver.openInputStream(StringToUri(AUri));

  if LInput = nil then
    raise EStreamError.CreateFmt('Cannot open URI: %s', [AUri]);

  var LResult := TMemoryStream.Create;

  try
    var LBuffer := TJavaArray<Byte>.Create(CStreamBufferSize);
    try
      while True do
      begin
        var LRead := LInput.read(LBuffer);

        if LRead <= 0 then
          Break;

        LResult.WriteBuffer(LBuffer.Data^, LRead);
      end;
    finally
      LBuffer.Free;
      LInput.close;
    end;

    LResult.Position := 0;
    Result := LResult;
  except
    LResult.Free;
    raise;
  end;
end;

{$ELSE}

class procedure TRomStorage.SelectFolder(const AOnSelected: TProc<Boolean>);
begin
  raise ENotSupportedException.Create('TRomStorage.SelectFolder is currently implemented only for Android');
end;

class procedure TRomStorage.ClearFolder;
begin
  SaveFolderUri('');
end;

class function TRomStorage.GetFiles(const AExtensions: array of string; ARecursive: Boolean): TArray<TRomFile>;
begin
  raise ENotSupportedException.Create('TRomStorage.GetFiles is currently implemented only for Android');
end;

class function TRomStorage.GetAllFiles(ARecursive: Boolean): TArray<TRomFile>;
begin
  raise ENotSupportedException.Create('TRomStorage.GetAllFiles is currently implemented only for Android');
end;

class function TRomStorage.OpenFile(const AFile: TRomFile): TStream;
begin
  raise ENotSupportedException.Create('TRomStorage.OpenFile is currently implemented only for Android');
end;

class function TRomStorage.OpenUri(const AUri: string): TStream;
begin
  raise ENotSupportedException.Create('TRomStorage.OpenUri is currently implemented only for Android');
end;

{$ENDIF}

{$IFDEF ANDROID}
initialization
  GMessageListener :=
    procedure(const Sender: TObject; const M: TMessage)
    begin
      HandleAndroidMessage(Sender, M);
    end;

  GMessageSubscription :=
    TMessageManager.DefaultManager.SubscribeToMessage(
    TMessageResultNotification,
    GMessageListener
  );

finalization
  TMessageManager.DefaultManager.Unsubscribe(
    TMessageResultNotification,
    GMessageSubscription
  );

  GMessageListener := nil;
  GOnFolderSelected := nil;
{$ENDIF}

end.

