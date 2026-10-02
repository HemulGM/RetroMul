unit Core.Storage.Android;

interface

uses
  System.Classes, Core.Storage;

type
  TAndroidStorage = class
  public
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

  TDocumentStream = class(TStream)
  private
    FUri: Jnet_Uri;
    FInput: JInputStream;
    FPosition, FSize: Int64;
    procedure Reopen;
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

constructor TDocumentStream.Create(const Uri: string);
begin
  inherited Create;
  FUri := ParseUri(Uri);
  FSize := TAndroidStorage.Describe(Uri).Size;
  Reopen;
end;

procedure TDocumentStream.Reopen;
begin
  if FInput <> nil then
    FInput.close;
  FInput := Resolver.openInputStream(FUri);
  if FInput = nil then
    raise EReadError.Create('Cannot open document');
  FPosition := 0;
end;

destructor TDocumentStream.Destroy;
begin
  if FInput <> nil then
    FInput.close;
  inherited;
end;

function TDocumentStream.GetSize: Int64;
begin
  if FSize < 0 then
    raise EReadError.Create('Document provider did not report its size');
  Result := FSize;
end;

function TDocumentStream.Read(var Buffer; Count: Longint): Longint;
begin
  if Count <= 0 then
    Exit(0);
  var Bytes := TJavaArray<Byte>.Create(Min(Count, 65536));
  try
    Result := FInput.read(Bytes);
    if Result < 0 then
      Result := 0;
    if Result > 0 then
      Move(Bytes.Data^, Buffer, Result);
    Inc(FPosition, Result);
  finally
    Bytes.Free;
  end;
end;

function TDocumentStream.Write(const Buffer; Count: Longint): Longint;
begin
  raise EWriteError.Create('Document stream is read-only');
end;

function TDocumentStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  var Target := Offset;
  case Origin of
    soCurrent:
      Inc(Target, FPosition);
    soEnd:
      Inc(Target, Size);
  end;
  if Target < 0 then
    raise EStreamError.Create('Invalid document position');
  if Target < FPosition then
    Reopen;
  var Buffer: array[0..4095] of Byte;
  while FPosition < Target do
    if Read(Buffer, Min(Int64(SizeOf(Buffer)), Target - FPosition)) = 0 then
      raise EReadError.Create('Unexpected end of document');
  Result := FPosition;
end;

class function TAndroidStorage.OpenUri(const Uri: string): TStream;
begin
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

