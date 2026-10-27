unit Core.Storage.Android;

interface

uses
  System.Classes, Core.Storage;

type
  TAndroidStorage = class
  public
    class procedure EnsureSubfolder(const FolderUri, Name: string); static;
    class function SameDocument(const Left, Right: string): Boolean; static;
    class function OpenUri(const Uri: string): TStream; static;
    class function OpenWriteUri(const Uri: string): TStream; static;
    class function Exists(const Uri: string): Boolean; static;
    class function ModifiedTime(const Uri: string): TDateTime; static;
    class function Describe(const Uri: string): TStorageFile; static;
    class function Enumerate(const FolderUri: string; Recursive: Boolean = True; Directories: Boolean = False): TArray<TStorageFile>; static;
  end;

implementation

uses
  System.SysUtils, System.Math, System.DateUtils, System.Generics.Collections,
  System.IOUtils, Posix.Unistd, Posix.Stdio, Androidapi.JNI.Os,
  Androidapi.Helpers, Androidapi.JNI.Net, Androidapi.JNI.JavaTypes,
  Androidapi.JNI.Provider, Androidapi.JNI.GraphicsContentViewText,
  Androidapi.JNIBridge;

type
  TDocumentWriteStream = class(TStream)
  private
    FOutput: JOutputStream;
    FPosition: Int64;
  public
    constructor Create(const Uri: string);
    destructor Destroy; override;
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
  end;

  TDocumentFileStream = class(THandleStream)
  private
    FDescriptor: JParcelFileDescriptor;
  public
    constructor Create(const Descriptor: JParcelFileDescriptor);
    destructor Destroy; override;
  end;

  TDocumentStream = class(TStream)
  private
    FInput: JInputStream;
    FCache: TFileStream;
    FCachePath: string;
    FPosition, FSize: Int64;
    FEOF: Boolean;
    procedure CacheUntil(Target: Int64);
  protected
    function GetSize: Int64; override;
  public
    constructor Create(const Uri: string);
    destructor Destroy; override;
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
  end;

function ParseUri(const Value: string): Jnet_Uri;
begin
  Result := TJnet_Uri.JavaClass.parse(StringToJString(Value));
end;

function Resolver: JContentResolver;
begin
  Result := TAndroidHelper.Context.getContentResolver;
end;

class function TAndroidStorage.SameDocument(const Left, Right: string): Boolean;
begin
  if Left = Right then Exit(True);
  Result := False;
  try
    var A := ParseUri(Left);
    var B := ParseUri(Right);
    if not SameText(JStringToString(A.getScheme), 'content') or
      not SameText(JStringToString(B.getScheme), 'content') or
      not SameText(JStringToString(A.getAuthority), JStringToString(B.getAuthority)) then
      Exit;
    // IDs are opaque and case-sensitive; a picker URI need not contain the
    // tree grant used to enumerate the very same document.
    Result := JStringToString(TJDocumentsContract.JavaClass.getDocumentId(A)) =
      JStringToString(TJDocumentsContract.JavaClass.getDocumentId(B));
  except
    // Non-document content providers cannot identify a sibling this way.
    Result := False;
  end;
end;

constructor TDocumentWriteStream.Create(const Uri: string);
begin
  inherited Create;
  FOutput := Resolver.openOutputStream(ParseUri(Uri), StringToJString('wt'));
  if FOutput = nil then
    raise EWriteError.Create('Cannot write document');
end;

destructor TDocumentWriteStream.Destroy;
begin
  if FOutput <> nil then
    FOutput.close;
  inherited;
end;

function TDocumentWriteStream.Read(var Buffer; Count: Longint): Longint;
begin
  raise EReadError.Create('Document output stream is write-only');
end;

function TDocumentWriteStream.Write(const Buffer; Count: Longint): Longint;
begin
  if Count <= 0 then
    Exit(0);
  var Data := TJavaArray<Byte>.Create(Count);
  try
    Move(Buffer, Data.Data^, Count);
    Data.Sync;
    FOutput.write(Data, 0, Count);
    Inc(FPosition, Count);
    Result := Count;
  finally
    Data.Free;
  end;
end;

function TDocumentWriteStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  if (Offset = 0) and (Origin = soCurrent) then
    Exit(FPosition);
  raise EStreamError.Create('Document output stream does not support seeking');
end;

constructor TDocumentFileStream.Create(const Descriptor: JParcelFileDescriptor);
begin
  inherited Create(Descriptor.getFd);
  FDescriptor := Descriptor;
end;

destructor TDocumentFileStream.Destroy;
begin
  if FDescriptor <> nil then
    FDescriptor.close;
  inherited;
end;

constructor TDocumentStream.Create(const Uri: string);
begin
  inherited Create;
  FSize := TAndroidStorage.Describe(Uri).Size;
  FInput := Resolver.openInputStream(ParseUri(Uri));
  if FInput = nil then
    raise EReadError.Create('Cannot open document');
  FCachePath := TStorage.Default.TemporaryFile('.document');
  TDirectory.CreateDirectory(ExtractFilePath(FCachePath));
  FCache := TFileStream.Create(FCachePath, fmCreate);
end;

procedure TDocumentStream.CacheUntil(Target: Int64);
begin
  while not FEOF and (FCache.Size < Target) do
  begin
    TStorage.CheckReadCancelled;
    var Bytes := TJavaArray<Byte>.Create(Integer(Min(Int64(65536), Target - FCache.Size)));
    try
      var Count := FInput.read(Bytes);
      if Count <= 0 then
      begin
        FEOF := True;
        FSize := FCache.Size;
        Break;
      end;
      FCache.Position := FCache.Size;
      FCache.WriteBuffer(Bytes.Data^, Count);
    finally
      Bytes.Free;
    end;
  end;
end;

destructor TDocumentStream.Destroy;
begin
  try
    if FInput <> nil then
      FInput.close;
  finally
    FCache.Free;
    if FCachePath <> '' then
    try
      TFile.Delete(FCachePath);
    except
      // Cache cleanup must not hide a document read/cancellation error.
    end;
    inherited;
  end;
end;

function TDocumentStream.GetSize: Int64;
begin
  if FSize < 0 then
    CacheUntil(High(Int64));
  Result := FSize;
end;

function TDocumentStream.Read(var Buffer; Count: Longint): Longint;
begin
  if Count <= 0 then
    Exit(0);
  Count := Min(Count, 65536);
  if FPosition > High(Int64) - Count then
    Exit(0);
  CacheUntil(FPosition + Count);
  FCache.Position := FPosition;
  Result := FCache.Read(Buffer, Count);
  Inc(FPosition, Result);
end;

function TDocumentStream.Write(const Buffer; Count: Longint): Longint;
begin
  raise EWriteError.Create('Document stream is read-only');
end;

function TDocumentStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  var Base: Int64 := 0;
  case Origin of
    soBeginning: ;
    soCurrent: Base := FPosition;
    soEnd: Base := Size;
  else
    raise EStreamError.Create('Invalid document seek origin');
  end;
  if (Offset < -Base) or (Offset > High(Int64) - Base) then
    raise EStreamError.Create('Invalid document position');
  FPosition := Base + Offset;
  Result := FPosition;
end;

class function TAndroidStorage.OpenUri(const Uri: string): TStream;
begin
  var Descriptor: JParcelFileDescriptor := nil;
  try
    try
      Descriptor := Resolver.openFileDescriptor(ParseUri(Uri), StringToJString('r'));
      if (Descriptor <> nil) and (lseek(Descriptor.getFd, 0, SEEK_CUR) >= 0) then
      begin
        Result := TDocumentFileStream.Create(Descriptor);
        Descriptor := nil; // The stream keeps the descriptor open.
        Exit;
      end;
    except
      // Some providers offer only an input stream, or a non-seekable pipe.
    end;
  finally
    if Descriptor <> nil then
      Descriptor.close;
  end;
  Result := TDocumentStream.Create(Uri);
end;

class function TAndroidStorage.OpenWriteUri(const Uri: string): TStream;
begin
  Result := TDocumentWriteStream.Create(Uri);
end;

class function TAndroidStorage.Exists(const Uri: string): Boolean;
begin
  var Document := ParseUri(Uri);
  if Uri.Contains('/tree/') and not Uri.Contains('/document/') then
    Document := TJDocumentsContract.JavaClass.buildDocumentUriUsingTree(Document,
      TJDocumentsContract.JavaClass.getTreeDocumentId(Document));
  var Cursor := Resolver.query(Document, nil, nil, nil, nil);
  Result := False;
  if Cursor <> nil then
  try
    Result := Cursor.moveToFirst;
  finally
    Cursor.close;
  end;
end;

class procedure TAndroidStorage.EnsureSubfolder(const FolderUri, Name: string);
begin
  for var Folder in Enumerate(FolderUri, False, True) do
    if SameText(Folder.Name, Name) then
      Exit;

  var Parent := ParseUri(FolderUri);
  if not FolderUri.Contains('/document/') then
    Parent := TJDocumentsContract.JavaClass.buildDocumentUriUsingTree(Parent,
      TJDocumentsContract.JavaClass.getTreeDocumentId(Parent));
  var Document := TJDocumentsContract.JavaClass.createDocument(Resolver, Parent,
    TJDocumentsContract_Document.JavaClass.MIME_TYPE_DIR, StringToJString(Name));
  if Document = nil then
    raise EWriteError.CreateFmt('Cannot create folder: %s', [Name]);
end;

class function TAndroidStorage.ModifiedTime(const Uri: string): TDateTime;
begin
  Result := 0;
  var Cursor := Resolver.query(ParseUri(Uri), nil, nil, nil, nil);
  if Cursor <> nil then
  try
    if Cursor.moveToFirst then
    begin
      var Column := Cursor.getColumnIndex(TJDocumentsContract_Document.JavaClass.COLUMN_LAST_MODIFIED);
      if (Column >= 0) and not Cursor.isNull(Column) then
        Result := UnixToDateTime(Cursor.getLong(Column) div 1000, False);
    end;
  finally
    Cursor.close;
  end;
end;

class function TAndroidStorage.Describe(const Uri: string): TStorageFile;
begin
  Result := Default(TStorageFile);
  Result.Location := Uri;
  Result.Size := -1;
  var Cursor := Resolver.query(ParseUri(Uri), nil, nil, nil, nil);
  if Cursor <> nil then
  try
    if Cursor.moveToFirst then
    begin
      var Column := Cursor.getColumnIndex(StringToJString('_display_name'));
      if Column >= 0 then
        Result.Name := JStringToString(Cursor.getString(Column));
      Column := Cursor.getColumnIndex(StringToJString('_size'));
      if (Column >= 0) and not Cursor.isNull(Column) then
        Result.Size := Cursor.getLong(Column);
    end;
  finally
    Cursor.close;
  end;
end;

class function TAndroidStorage.Enumerate(const FolderUri: string; Recursive, Directories: Boolean): TArray<TStorageFile>;
var
  List: TList<TStorageFile>;
  Tree: Jnet_Uri;

  procedure Visit(const Id: JString; const Relative: string);
  begin
    var Children := TJDocumentsContract.JavaClass.buildChildDocumentsUriUsingTree(Tree, Id);
    var Cursor := Resolver.query(Children, nil, nil, nil, nil);
    if Cursor = nil then
      Exit;
    try
      var IdColumn := Cursor.getColumnIndex(TJDocumentsContract_Document.JavaClass.COLUMN_DOCUMENT_ID);
      var NameColumn := Cursor.getColumnIndex(TJDocumentsContract_Document.JavaClass.COLUMN_DISPLAY_NAME);
      var MimeColumn := Cursor.getColumnIndex(TJDocumentsContract_Document.JavaClass.COLUMN_MIME_TYPE);
      var SizeColumn := Cursor.getColumnIndex(TJDocumentsContract_Document.JavaClass.COLUMN_SIZE);
      while Cursor.moveToNext do
      begin
        var ChildId := Cursor.getString(IdColumn);
        var Item := Default(TStorageFile);
        Item.Name := JStringToString(Cursor.getString(NameColumn));
        Item.RelativePath := Relative + Item.Name;
        if JStringToString(Cursor.getString(MimeColumn)) =
          JStringToString(TJDocumentsContract_Document.JavaClass.MIME_TYPE_DIR) then
        begin
          if Directories then
          begin
            Item.Location := JStringToString(TJDocumentsContract.JavaClass.buildDocumentUriUsingTree(Tree, ChildId).toString);
            List.Add(Item);
          end;
          if Recursive then
            Visit(ChildId, Item.RelativePath + '/');
        end
        else
        begin
          Item.Location := JStringToString(TJDocumentsContract.JavaClass.buildDocumentUriUsingTree(Tree, ChildId).toString);
          Item.Size := -1;
          if (SizeColumn >= 0) and not Cursor.isNull(SizeColumn) then
            Item.Size := Cursor.getLong(SizeColumn);
          if not Directories then
            List.Add(Item);
        end;
      end;
    finally
      Cursor.close;
    end;
  end;

begin
  List := TList<TStorageFile>.Create;
  try
    Tree := ParseUri(FolderUri);
    if FolderUri.Contains('/document/') then
      Visit(TJDocumentsContract.JavaClass.getDocumentId(Tree), '')
    else
      Visit(TJDocumentsContract.JavaClass.getTreeDocumentId(Tree), '');
    Result := List.ToArray;
  finally
    List.Free;
  end;
end;

end.

