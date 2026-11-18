unit J2ME.FileSystem;

interface

uses
  System.SysUtils, JVM.Types, JVM.Runtime, JVM.ClassFile, Core.Storage,
  J2ME.FileSystem.Store;

type
  TJ2MEFileSystem = class
  private
    FVM: TJVM;
    FStorage: IStorage;
    FPath: string;
    function BeginStore: TJ2MEFileStore;
    procedure IOFailure(const Message: string);
    function StringArgument(const Value: TJVMValue): string;
    function ByteArray(const Value: TJVMValue): TJVMObject;
    procedure RefreshInput(Stream: TJVMObject; const Data: TBytes; Revision: Int64);
    function NewEnumeration(const Names: TArray<string>): TJVMValue;
    function InvokeRegistry(Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
    function SiemensPath(const Value: string; Directory: Boolean = False): string;
    function SiemensOpen(C: TJVMClass; const Path: string; Store: TJ2MEFileStore): TJVMValue;
    function InvokeSiemensDescriptor(Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
    function InvokeSiemensFile(Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
    function InvokeConnection(Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
    function InvokeInput(Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
    procedure InvokeOutput(Method: TJVMMethod; const Args: TArray<TJVMValue>);
    procedure FlushOutput(Stream: TJVMObject; Store: TJ2MEFileStore);
  public
    constructor Create(VM: TJVM; const Storage: IStorage; const Vendor, Suite: string);
    procedure Install;
    function Open(const URL: string; Mode: Integer; Siemens: Boolean = False): Integer;
    function ReadMedia(const URL: string; Siemens: Boolean): TBytes;
    function Handles(const Owner: string): Boolean;
    function Invoke(Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
    function GetProperty(const Name: string; out Value: string): Boolean;
  end;

implementation

uses
  System.Classes, System.DateUtils, System.IOUtils, System.Math, System.StrUtils,
  System.Generics.Collections, Java.Classes, J2ME.RMS.Store;

const
  IO = 'javax/microedition/io/';
  PackageName = IO + 'file/';
  FileAPI = PackageName + 'FileConnection';
  Registry = PackageName + 'FileSystemRegistry';
  Listener = PackageName + 'FileSystemListener';
  ClosedConnection = PackageName + 'ConnectionClosedException';
  IllegalMode = PackageName + 'IllegalModeException';
  FileImpl = FileAPI + '$Impl';
  FileInput = FileAPI + '$Input';
  FileOutput = FileAPI + '$Output';
  FileEnum = Registry + '$Enumeration';
  SiemensFile = 'com/siemens/mp/io/File';
  SiemensHandle = SiemensFile + '$Descriptor';
  SiemensHandles = '[L' + SiemensHandle + ';';
  SiemensDrive = 'a:';
  SiemensRoot = 'c:';
  SiemensPrivate = SiemensRoot + '/private';
  SiemensMaxHandles = 64;
  StringDesc = 'Ljava/lang/String;';
  EnumDesc = 'Ljava/util/Enumeration;';
  ListenerDesc = 'L' + Listener + ';';
  SiemensHandleID = SiemensHandle + '.$id:I';
  SiemensHandleIdentity = SiemensHandle + '.$identity:' + StringDesc;
  SiemensHandlePosition = SiemensHandle + '.$position:I';
  FilePath = FileImpl + '.$path:' + StringDesc;
  FileMode = FileImpl + '.$mode:I';
  FileImplicitCreate = '$file.siemensImplicitCreate';
  FileFolder = FileImpl + '.$folder:Z';
  FileClosed = FileImpl + '.$closed:Z';
  FileInRef = FileImpl + '.$in:L' + FileInput + ';';
  FileOutRef = FileImpl + '.$out:L' + FileOutput + ';';
  InData = FileInput + '.$data:[B';
  InPosition = FileInput + '.$position:I';
  InMark = FileInput + '.$mark:I';
  InTarget = FileInput + '.$path:' + StringDesc;
  InIdentity = FileInput + '.$identity:' + StringDesc;
  InRevision = FileInput + '.$revision:J';
  OutData = FileOutput + '.$data:[B';
  OutCount = FileOutput + '.$count:I';
  OutOffset = FileOutput + '.$offset:I';
  OutTarget = FileOutput + '.$path:' + StringDesc;
  OutIdentity = FileOutput + '.$identity:' + StringDesc;
  OutClosed = FileOutput + '.$closed:Z';
  EnumItems = FileEnum + '.$items:[Ljava/lang/String;';
  EnumPosition = FileEnum + '.$position:I';

function FileTimeMillis: Int64;
begin
  var UTC := TTimeZone.local.ToUniversalTime(Now);
  Result := DateTimeToUnix(UTC, True) * 1000 + MilliSecondOf(UTC);
end;

function DecodeFilePath(const Value: string; out Decoded: string): Boolean;
begin
  Result := False;
  var Encoding := TEncoding.UTF8;
  var Bytes := Encoding.GetBytes(Value);
  if Encoding.GetString(Bytes) <> Value then
    Exit;
  var Count := 0;
  var Index := 0;
  while Index < Length(Bytes) do
  begin
    var B := Bytes[Index];
    Inc(Index);
    if B = Ord('%') then
    begin
      if (Index + 2 > Length(Bytes)) or
        not CharInSet(Char(Bytes[Index]), ['0'..'9', 'A'..'F', 'a'..'f']) or
        not CharInSet(Char(Bytes[Index + 1]), ['0'..'9', 'A'..'F', 'a'..'f']) then
        Exit;
      B := Byte(StrToInt('$' + Char(Bytes[Index]) + Char(Bytes[Index + 1])));
      if (B = Ord('/')) or (B = Ord('\')) then
        Exit;
      Inc(Index, 2);
    end;
    Bytes[Count] := B;
    Inc(Count);
  end;
  Decoded := Encoding.GetString(Bytes, 0, Count);
  var RoundTrip := Encoding.GetBytes(Decoded);
  Result := (Length(RoundTrip) = Count) and ((Count = 0) or CompareMem(@Bytes[0], @RoundTrip[0], Count));
end;

function EncodeFilePath(const Value: string): string;
begin
  Result := '';
  for var B in TEncoding.UTF8.GetBytes(Value) do
    if CharInSet(Char(B), ['a'..'z', 'A'..'Z', '0'..'9', '-', '.', '_', '~', '/', ':']) then
      Result := Result + Char(B)
    else
      Result := Result + '%' + IntToHex(B, 2);
end;

function FileMatches(const Name, Pattern: string): Boolean;
begin
  var N := 1;
  var P := 1;
  var Star := 0;
  var Retry := 0;
  while N <= Length(Name) do
  begin
    if (P <= Length(Pattern)) and (Pattern[P] = '*') then
    begin
      Star := P;
      Inc(P);
      Retry := N;
    end
    else if (P <= Length(Pattern)) and (Pattern[P] = Name[N]) then
    begin
      Inc(P);
      Inc(N);
    end
    else if Star <> 0 then
    begin
      P := Star + 1;
      Inc(Retry);
      N := Retry;
    end
    else
      Exit(False);
  end;
  while (P <= Length(Pattern)) and (Pattern[P] = '*') do
    Inc(P);
  Result := P > Length(Pattern);
end;

constructor TJ2MEFileSystem.Create(VM: TJVM; const Storage: IStorage; const Vendor, Suite: string);
begin
  inherited Create;
  FVM := VM;
  FStorage := Storage;
  FPath := TPath.Combine(Storage.SaveRoot, 'j2me' + PathDelim + 'files' + PathDelim +
    J2MESuiteStorageKey(Vendor, Suite) + '.vfs');
end;

function TJ2MEFileSystem.BeginStore: TJ2MEFileStore;
begin
  Result := TJ2MEFileStore.Create(FStorage, FPath,
    function: Boolean
    begin
      var Executor := TThread.CurrentThread;
      if not Executor.ExternalThread and Executor.CheckTerminated then
        FVM.RequestStop;
      Result := FVM.StopRequested;
    end);
end;

procedure TJ2MEFileSystem.Install;
var
  B: TJavaClassBuilder;

  procedure Done;
  begin
    FVM.DefineClass(B.Detach);
    FreeAndNil(B);
  end;

  procedure InterfaceClass(const Name: string);
  begin
    B := TJavaClassBuilder.Create(Name, 'java/lang/Object', JVM_ACC_PUBLIC or $0200 or JVM_ACC_ABSTRACT);
  end;

  procedure AbstractMethod(const Name, Desc: string);
  begin
    B.JavaClass.AddNative(Name, Desc).Access := JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT;
  end;

  procedure FileMethods(abstract: Boolean);

    procedure Method(const Name, Desc: string);
    begin
      if abstract then
        AbstractMethod(Name, Desc)
      else
        B.JavaClass.AddNative(Name, Desc);
    end;

  begin
    for var N in ['exists', 'isOpen', 'isDirectory', 'isHidden', 'canRead', 'canWrite'] do
      Method(N, '()Z');
    for var N in ['getName', 'getPath', 'getURL'] do
      Method(N, '()' + StringDesc);
    for var N in ['fileSize', 'totalSize', 'usedSize', 'availableSize', 'lastModified'] do
      Method(N, '()J');
    for var N in ['create', 'mkdir', 'delete'] do
      Method(N, '()V');
    for var N in ['setReadable', 'setWritable', 'setHidden'] do
      Method(N, '(Z)V');
    for var N in ['rename', 'setFileConnection'] do
      Method(N, '(' + StringDesc + ')V');
    Method('list', '()' + EnumDesc);
    Method('list', '(' + StringDesc + 'Z)' + EnumDesc);
    Method('directorySize', '(Z)J');
    Method('truncate', '(J)V');
    Method('openOutputStream', '(J)Ljava/io/OutputStream;');
  end;

  procedure DataWrapper(Reading: Boolean);
  begin
    var Kind := 'Output';
    if Reading then
      Kind := 'Input';
    var Wrapper := 'java/io/Data' + Kind + 'Stream';
    var Desc := 'Ljava/io/' + Kind + 'Stream;';
    B.Start;
    B.Ref($BB, B.ClassRef(Wrapper));
    B.Emit([$59, $2A]);
    B.Ref($B6, B.Member(FileImpl, 'open' + Kind + 'Stream', '()' + Desc));
    B.Ref($B7, B.Member(Wrapper, '<init>', '(' + Desc + ')V'));
    B.Emit([$B0]);
    B.Finish('openData' + Kind + 'Stream', '()L' + Wrapper + ';', JVM_ACC_PUBLIC, 3, 1);
  end;

  procedure InstallSiemensFile;
  const
    FinalConstant = JVM_ACC_PUBLIC or JVM_ACC_STATIC or JVM_ACC_FINAL;
  begin
    B := TJavaClassBuilder.Create(SiemensFile, 'java/lang/Object');
    B.Field('INSIDE_STORAGE_PATH', 'I', FinalConstant);
    B.JavaClass.Fields.Last.Value := TJVMValue.Int(1);
    B.Field('OUTSIDE_STORAGE_PATH', 'I', FinalConstant);
    B.JavaClass.Fields.Last.Value := TJVMValue.Int(0);
    B.Field('STORAGE_DRIVE', StringDesc, FinalConstant);
    B.JavaClass.Fields.Last.ConstantIndex := B.StringConstant(SiemensDrive);
    B.Field('$handles', SiemensHandles, JVM_ACC_PRIVATE or JVM_ACC_STATIC);
    B.Field('$nextHandle', 'I', JVM_ACC_PRIVATE or JVM_ACC_STATIC);
    B.Start;
    B.Emit([$2A]);
    B.Ref($B7, B.Member('java/lang/Object', '<init>', '()V'));
    B.Emit([$B1]);
    B.Finish('<init>', '()V', JVM_ACC_PUBLIC, 1, 1);
    B.JavaClass.AddNative('open', '(' + StringDesc + ')I');
    for var N in ['close', 'length'] do
      B.JavaClass.AddNative(N, '(I)I');
    B.JavaClass.AddNative('seek', '(II)I');
    for var N in ['read', 'write'] do
      B.JavaClass.AddNative(N, '(I[BII)I');
    for var N in ['checkFileName', 'exists', 'delete'] do
      B.JavaClass.AddNative(N, '(' + StringDesc + ')I', True);
    for var N in ['copy', 'rename', 'debugWrite'] do
      B.JavaClass.AddNative(N, '(' + StringDesc + StringDesc + ')I', True);
    B.JavaClass.AddNative('buildPath', '(' + StringDesc + ')' + StringDesc, True);
    B.JavaClass.AddNative('isDirectory', '(' + StringDesc + ')Z', True);
    B.JavaClass.AddNative('list', '(' + StringDesc + ')[Ljava/lang/String;', True);
    B.JavaClass.AddNative('spaceAvailable', '()I', True);
    B.JavaClass.AddNative('truncate', '(II)V', True);
    Done;

    B := TJavaClassBuilder.Create(SiemensHandle, 'java/lang/Object', JVM_ACC_FINAL or $0020);
    B.Field('$id', 'I', JVM_ACC_PRIVATE);
    B.Field('$identity', StringDesc, JVM_ACC_PRIVATE);
    B.Field('$position', 'I', JVM_ACC_PRIVATE);
    Done;
  end;

  procedure ExceptionClass(const Name: string);
  const
    Parent = 'java/lang/RuntimeException';
  begin
    B := TJavaClassBuilder.Create(Name, Parent);
    B.Start;
    B.Emit([$2A]);
    B.Ref($B7, B.Member(Parent, '<init>', '()V'));
    B.Emit([$B1]);
    B.Finish('<init>', '()V', JVM_ACC_PUBLIC, 1, 1);
    B.Start;
    B.Emit([$2A, $2B]);
    B.Ref($B7, B.Member(Parent, '<init>', '(' + StringDesc + ')V'));
    B.Emit([$B1]);
    B.Finish('<init>', '(' + StringDesc + ')V', JVM_ACC_PUBLIC, 2, 2);
    Done;
  end;

begin
  B := nil;
  try
    ExceptionClass(ClosedConnection);
    ExceptionClass(IllegalMode);
    InstallSiemensFile;
    InterfaceClass(FileAPI);
    B.JavaClass.Interfaces := [IO + 'StreamConnection'];
    FileMethods(True);
    Done;

    InterfaceClass(Listener);
    B.Field('ROOT_ADDED', 'I', JVM_ACC_PUBLIC or JVM_ACC_STATIC or JVM_ACC_FINAL);
    B.JavaClass.Fields.Last.Value := TJVMValue.Int(0);
    B.Field('ROOT_REMOVED', 'I', JVM_ACC_PUBLIC or JVM_ACC_STATIC or JVM_ACC_FINAL);
    B.JavaClass.Fields.Last.Value := TJVMValue.Int(1);
    AbstractMethod('rootChanged', '(I' + StringDesc + ')V');
    Done;

    B := TJavaClassBuilder.Create(Registry, 'java/lang/Object');
    B.Field('$listeners', '[' + ListenerDesc, JVM_ACC_PRIVATE or JVM_ACC_STATIC);
    B.JavaClass.AddNative('listRoots', '()' + EnumDesc, True);
    B.JavaClass.AddNative('addFileSystemListener', '(' + ListenerDesc + ')Z', True);
    B.JavaClass.AddNative('removeFileSystemListener', '(' + ListenerDesc + ')Z', True);
    Done;

    B := TJavaClassBuilder.Create(FileImpl, 'java/lang/Object', JVM_ACC_PUBLIC or JVM_ACC_FINAL);
    B.JavaClass.Interfaces := [FileAPI];
    B.Field('$path', StringDesc, JVM_ACC_PRIVATE);
    B.Field('$mode', 'I', JVM_ACC_PRIVATE);
    B.Field('$folder', 'Z', JVM_ACC_PRIVATE);
    B.Field('$closed', 'Z', JVM_ACC_PRIVATE);
    B.Field('$in', 'L' + FileInput + ';', JVM_ACC_PRIVATE);
    B.Field('$out', 'L' + FileOutput + ';', JVM_ACC_PRIVATE);
    FileMethods(False);
    B.JavaClass.AddNative('close', '()V');
    B.JavaClass.AddNative('openInputStream', '()Ljava/io/InputStream;');
    B.JavaClass.AddNative('openOutputStream', '()Ljava/io/OutputStream;');
    DataWrapper(True);
    DataWrapper(False);
    Done;

    B := TJavaClassBuilder.Create(FileInput, 'java/io/InputStream', JVM_ACC_PUBLIC or JVM_ACC_FINAL);
    B.Field('$data', '[B', JVM_ACC_PRIVATE);
    B.Field('$position', 'I', JVM_ACC_PRIVATE);
    B.Field('$mark', 'I', JVM_ACC_PRIVATE);
    B.Field('$path', StringDesc, JVM_ACC_PRIVATE);
    B.Field('$identity', StringDesc, JVM_ACC_PRIVATE);
    B.Field('$revision', 'J', JVM_ACC_PRIVATE);
    B.JavaClass.AddNative('read', '()I');
    B.JavaClass.AddNative('read', '([BII)I');
    B.JavaClass.AddNative('skip', '(J)J');
    B.JavaClass.AddNative('available', '()I');
    B.JavaClass.AddNative('markSupported', '()Z');
    B.JavaClass.AddNative('mark', '(I)V');
    B.JavaClass.AddNative('reset', '()V');
    B.JavaClass.AddNative('close', '()V');
    Done;

    B := TJavaClassBuilder.Create(FileOutput, 'java/io/OutputStream', JVM_ACC_PUBLIC or JVM_ACC_FINAL);
    B.Field('$data', '[B', JVM_ACC_PRIVATE);
    B.Field('$count', 'I', JVM_ACC_PRIVATE);
    B.Field('$offset', 'I', JVM_ACC_PRIVATE);
    B.Field('$path', StringDesc, JVM_ACC_PRIVATE);
    B.Field('$identity', StringDesc, JVM_ACC_PRIVATE);
    B.Field('$closed', 'Z', JVM_ACC_PRIVATE);
    B.JavaClass.AddNative('write', '(I)V');
    B.JavaClass.AddNative('write', '([BII)V');
    B.JavaClass.AddNative('flush', '()V');
    B.JavaClass.AddNative('close', '()V');
    Done;

    B := TJavaClassBuilder.Create(FileEnum, 'java/lang/Object', JVM_ACC_PUBLIC or JVM_ACC_FINAL);
    B.JavaClass.Interfaces := ['java/util/Enumeration'];
    B.Field('$items', '[' + StringDesc, JVM_ACC_PRIVATE);
    B.Field('$position', 'I', JVM_ACC_PRIVATE);
    B.JavaClass.AddNative('hasMoreElements', '()Z');
    B.JavaClass.AddNative('nextElement', '()Ljava/lang/Object;');
    Done;
  finally
    B.Free;
  end;
end;

procedure TJ2MEFileSystem.IOFailure(const Message: string);
begin
  FVM.RaiseJava('java/io/IOException', Message);
end;

function TJ2MEFileSystem.StringArgument(const Value: TJVMValue): string;
begin
  if Value.AsRef = 0 then
    FVM.RaiseJava('java/lang/NullPointerException');
  Result := FVM.GetObject(Value.AsRef).Text;
end;

function TJ2MEFileSystem.ByteArray(const Value: TJVMValue): TJVMObject;
begin
  if Value.AsRef = 0 then
    FVM.RaiseJava('java/lang/NullPointerException');
  Result := FVM.GetObject(Value.AsRef);
end;

function TJ2MEFileSystem.Open(const URL: string; Mode: Integer; Siemens: Boolean): Integer;
begin
  var Rest := Copy(URL, Pos(':', URL) + 1, MaxInt);
  var LegacyPath := Siemens and Rest.StartsWith('//') and ValidJ2MEFileName(Copy(Rest, 3, MaxInt));
  if LegacyPath then
    Rest := '///c:/' + EncodeFilePath(Copy(Rest, 3, MaxInt));
  if not Rest.StartsWith('//') then
    FVM.RaiseJava('java/lang/IllegalArgumentException', 'Absolute file URL required');
  Delete(Rest, 1, 2);
  var Slash := Pos('/', Rest);
  if Slash = 0 then
    FVM.RaiseJava('java/lang/IllegalArgumentException', 'File URL has no root');
  var Authority := Copy(Rest, 1, Slash - 1);
  if (Authority <> '') and not SameText(Authority, 'localhost') then
    FVM.RaiseJava('java/lang/SecurityException', 'Only local virtual volumes are available');
  var Path := '';
  if not DecodeFilePath(Copy(Rest, Slash + 1, MaxInt), Path) or (Length(Path) > J2MEPathChars + 1) then
    FVM.RaiseJava('java/lang/IllegalArgumentException', 'Invalid file URL');
  var Folder := Path.EndsWith('/');
  if Folder then
    SetLength(Path, Length(Path) - 1);
  var Parts := Path.Split(['/']);
  Parts[0] := Parts[0].ToLowerInvariant;
  if not J2MEFileRoot(Parts[0]) then
    IOFailure('Unknown virtual file root');
  for var I := 1 to High(Parts) do
    if not ValidJ2MEFileName(Parts[I]) then
      FVM.RaiseJava('java/lang/IllegalArgumentException', 'Invalid file path component');
  Path := string.Join('/', Parts);
  if Length(Path) > J2MEPathChars then
    FVM.RaiseJava('java/lang/IllegalArgumentException', 'File path too long');

  Result := FVM.NewObject(FileImpl);
  var Obj := FVM.GetObject(Result);
  Obj.Fields[FilePath] := TJVMValue.Ref(FVM.NewString(Path));
  Obj.Fields[FileFolder] := TJVMValue.Int(Ord(Folder or J2MEFileRoot(Path)));
  Obj.Fields[FileMode] := TJVMValue.Int(Mode);
  if LegacyPath then
    Obj.Fields.AddOrSetValue(FileImplicitCreate, TJVMValue.Int(1));
end;

function TJ2MEFileSystem.ReadMedia(const URL: string; Siemens: Boolean): TBytes;
begin
  var Ref := Open(URL, 1, Siemens);
  var Obj := FVM.GetObject(Ref);
  var Path := FVM.GetObject(Obj.Fields[FilePath].AsRef).Text;
  try
    var Store := BeginStore;
    try
      var Entry: TJ2MEFileEntry;
      if Obj.Fields[FileFolder].AsInt <> 0 then
        IOFailure('Media locator identifies a directory');
      if not Store.Entries.TryGetValue(Path, Entry) or Entry.Has(FileDirectory) or Entry.Has(FileUnreadable) then
        IOFailure('Media file is unavailable: ' + Path);
      Result := Entry.Data;
    finally
      Store.Free;
    end;
  except
    on E: EJ2MEFileIO do
      IOFailure(E.Message);
    on E: EInOutError do
      IOFailure('Virtual file system I/O error');
  end;
end;

function TJ2MEFileSystem.GetProperty(const Name: string; out Value: string): Boolean;
begin
  Result := True;
  if Name = 'microedition.io.file.FileConnection.version' then
    Value := '1.0'
  else if Name = 'file.separator' then
    Value := '/'
  else if Name = 'fileconn.dir.memorycard' then
    Value := 'file:///e:/'
  else if Name = 'fileconn.dir.roots.names' then
    Value := 'Phone memory;Memory card'
  else if MatchStr(Name, ['fileconn.dir.photos', 'fileconn.dir.music', 'fileconn.dir.videos',
      'fileconn.dir.recordings', 'fileconn.dir.private']) then
    Value := 'file:///c:/' + Copy(Name, Length('fileconn.dir.') + 1, MaxInt) + '/'
  else
    Result := False;
end;

function TJ2MEFileSystem.NewEnumeration(const Names: TArray<string>): TJVMValue;
begin
  var Ref := FVM.NewObject(FileEnum);
  var ArrayRef := FVM.NewArray('[' + StringDesc, Length(Names));
  FVM.GetObject(Ref).Fields[EnumItems] := TJVMValue.Ref(ArrayRef);
  var Data := FVM.GetObject(ArrayRef);
  for var I := 0 to High(Names) do
    Data.ElementValues[I] := TJVMValue.Ref(FVM.NewString(Names[I]));
  Result := TJVMValue.Ref(Ref);
end;

function TJ2MEFileSystem.InvokeRegistry(Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
begin
  if Method.Name = 'listRoots' then
    Exit(NewEnumeration([J2MEFileRoots[0] + '/', J2MEFileRoots[1] + '/']));
  if Args[0].AsRef = 0 then
    FVM.RaiseJava('java/lang/NullPointerException');
  var Field := Method.Owner.Fields[0];
  var Ref := Field.Value.AsRef;
  var List: TJVMObject := nil;
  var Count := 0;
  var Found := -1;
  if Ref <> 0 then
  begin
    List := FVM.GetObject(Ref);
    Count := List.ElementCount;
    for var I := 0 to Count - 1 do
      if List.ElementValues[I].AsRef = Args[0].AsRef then
      begin
        Found := I;
        Break;
      end;
  end;
  // The two roots remain mounted throughout a session.
  var Adding := Method.Name = 'addFileSystemListener';
  if (Adding and ((Found >= 0) or (Count >= 256))) or (not Adding and (Found < 0)) then
    Exit(TJVMValue.Int(0));
  if Adding then
  begin
    Ref := FVM.NewArray('[' + ListenerDesc, Count + 1);
    var Target := FVM.GetObject(Ref);
    if Count <> 0 then
      List.CopyArrayElementsTo(Target, 0, 0, Count);
    Target.ElementValues[Count] := Args[0];
  end
  else if Count = 1 then
    Ref := 0
  else
  begin
    Ref := FVM.NewArray('[' + ListenerDesc, Count - 1);
    var Target := FVM.GetObject(Ref);
    if Found > 0 then
      List.CopyArrayElementsTo(Target, 0, 0, Found);
    if Found < Count - 1 then
      List.CopyArrayElementsTo(Target, Found + 1, Found, Count - Found - 1);
  end;
  Field.Value := TJVMValue.Ref(Ref);
  Result := TJVMValue.Int(1);
end;

procedure TJ2MEFileSystem.FlushOutput(Stream: TJVMObject; Store: TJ2MEFileStore);
var
  Entry: TJ2MEFileEntry;
begin
  if Stream.Fields[OutClosed].AsInt <> 0 then
    Exit;
  var Count := Stream.Fields[OutCount].AsInt;
  if Count = 0 then
    Exit;
  var Path := StringArgument(Stream.Fields[OutTarget]);
  if not Store.Entries.TryGetValue(Path, Entry) or Entry.Has(FileDirectory or FileUnwritable) or
    (Entry.Identity <> StringArgument(Stream.Fields[OutIdentity])) then
    IOFailure('Output file has been replaced or is inaccessible');
  var Offset := Min(Stream.Fields[OutOffset].AsInt, Length(Entry.Data));
  var Size := Max(Length(Entry.Data), Offset + Count);
  if Store.BytesUnder(Copy(Path, 1, 3), True) + Size - Length(Entry.Data) > J2MEVolumeBytes then
    IOFailure('Virtual volume is full');
  var Data := Copy(Entry.Data);
  SetLength(Data, Size);
  var Buffer := FVM.GetObject(Stream.Fields[OutData].AsRef);
  for var I := 0 to Count - 1 do
    Data[Offset + I] := Byte(Buffer.ElementValues[I].AsInt and 255);
  Entry.Data := Data;
  Entry.Modified := FileTimeMillis;
  Store.Entries[Path] := Entry;
  Store.Commit;
  Stream.Fields[OutOffset] := TJVMValue.Int(Offset + Count);
  Stream.Fields[OutCount] := TJVMValue.Int(0);
end;

function TJ2MEFileSystem.InvokeConnection(Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
var
  Entry, Parent: TJ2MEFileEntry;
  Store: TJ2MEFileStore;

  procedure CloseStreams(Obj: TJVMObject);
  begin
    var Ref := Obj.Fields[FileOutRef].AsRef;
    if Ref <> 0 then
    begin
      var Output := FVM.GetObject(Ref);
      FlushOutput(Output, Store);
      Output.Fields[OutClosed] := TJVMValue.Int(1);
      Output.Fields[OutData] := TJVMValue.Ref(0);
      Obj.Fields[FileOutRef] := TJVMValue.Ref(0);
    end;
    Ref := Obj.Fields[FileInRef].AsRef;
    if Ref <> 0 then
    begin
      FVM.GetObject(Ref).Fields[InData] := TJVMValue.Ref(0);
      Obj.Fields[FileInRef] := TJVMValue.Ref(0);
    end;
  end;

begin
  Result := Default(TJVMValue);
  var Obj := FVM.GetObject(Args[0].AsRef);
  var N := Method.Name;
  if N = 'isOpen' then
    Exit(TJVMValue.Int(Ord(Obj.Fields[FileClosed].AsInt = 0)));
  if N = 'close' then
  begin
    Obj.Fields[FileClosed] := TJVMValue.Int(1);
    Obj.Fields[FileInRef] := TJVMValue.Ref(0);
    Obj.Fields[FileOutRef] := TJVMValue.Ref(0);
    Exit;
  end;
  var Naming := MatchStr(N, ['getName', 'getPath', 'getURL']);
  if not Naming and (Obj.Fields[FileClosed].AsInt <> 0) then
  begin
    if MatchStr(N, ['openInputStream', 'openOutputStream']) then
      IOFailure('File connection is closed');
    FVM.RaiseJava(ClosedConnection, 'File connection is closed');
  end;
  var Mode := Obj.Fields[FileMode].AsInt;
  var Writing := MatchStr(N, ['openOutputStream', 'create', 'mkdir', 'rename', 'delete',
      'truncate', 'setHidden', 'setReadable', 'setWritable']);
  if not Naming and (N <> 'setFileConnection') and
    ((Writing and (Mode = 1)) or (not Writing and (Mode = 2))) then
    FVM.RaiseJava(IllegalMode, 'Connection mode does not permit this operation');

  var Path := StringArgument(Obj.Fields[FilePath]);
  var Folder := Obj.Fields[FileFolder].AsInt <> 0;
  var Root := J2MEFileRoot(Path);
  Store := BeginStore;
  try
    var Exists := Store.Entries.TryGetValue(Path, Entry) and (not Folder or Entry.Has(FileDirectory));
    if Exists and Entry.Has(FileDirectory) then
      Folder := True;
    var Suffix := '';
    if Folder then
      Suffix := '/';
    if N = 'getName' then
      Exit(TJVMValue.Ref(FVM.NewString(J2MEFileLeaf(Path) + Suffix)));
    if N = 'getPath' then
      Exit(TJVMValue.Ref(FVM.NewString('/' + Copy(Path, 1, LastDelimiter('/', Path)))));
    if N = 'getURL' then
      Exit(TJVMValue.Ref(FVM.NewString('file:///' + EncodeFilePath(Path) + Suffix)));

    if N = 'exists' then
      Exit(TJVMValue.Int(Ord(Exists)));
    if N = 'isDirectory' then
      Exit(TJVMValue.Int(Ord(Exists and Entry.Has(FileDirectory))));
    if N = 'canRead' then
      Exit(TJVMValue.Int(Ord(Exists and not Entry.Has(FileUnreadable))));
    if N = 'canWrite' then
      Exit(TJVMValue.Int(Ord(Exists and not Entry.Has(FileUnwritable))));
    if N = 'isHidden' then
      Exit(TJVMValue.Int(Ord(Exists and Entry.Has(FileHidden))));
    if N = 'lastModified' then
    begin
      if not Exists or Entry.Has(FileUnreadable) then
        Exit(TJVMValue.Long(0));
      Exit(TJVMValue.Long(Entry.Modified));
    end;
    if N = 'totalSize' then
      Exit(TJVMValue.Long(J2MEVolumeBytes));
    if MatchStr(N, ['usedSize', 'availableSize']) then
    begin
      var Used := Store.BytesUnder(Copy(Path, 1, 3), True);
      if N = 'usedSize' then
        Exit(TJVMValue.Long(Used));
      Exit(TJVMValue.Long(J2MEVolumeBytes - Used));
    end;
    if N = 'fileSize' then
    begin
      if not Exists or Entry.Has(FileUnreadable) then
        Exit(TJVMValue.Long(-1));
      if Entry.Has(FileDirectory) then
        IOFailure('File size is unavailable for a directory');
      Exit(TJVMValue.Long(Length(Entry.Data)));
    end;
    if N = 'directorySize' then
    begin
      if not Exists or Entry.Has(FileUnreadable) then
        Exit(TJVMValue.Long(-1));
      if not Entry.Has(FileDirectory) then
        IOFailure('Directory size requires a directory');
      Exit(TJVMValue.Long(Store.BytesUnder(Path + '/', Args[1].AsInt <> 0)));
    end;

    var ImplicitCreate := (N = 'openOutputStream') and (Length(Args) = 1) and not Exists and
      Obj.Fields.ContainsKey(FileImplicitCreate);
    if MatchStr(N, ['create', 'mkdir']) or ImplicitCreate then
    begin
      if (Store.Entries.Count = J2MEFileEntries) or Store.Entries.ContainsKey(Path) or
        not Store.Entries.TryGetValue(J2MEFileParent(Path), Parent) or
        not Parent.Has(FileDirectory) or Parent.Has(FileUnwritable) or ((N = 'create') and Folder) then
        IOFailure('Unable to create virtual file or directory');
      Entry := Default(TJ2MEFileEntry);
      Entry.Modified := FileTimeMillis;
      if N = 'mkdir' then
        Entry.Flags := FileDirectory
      else
        Entry.Identity := TGUID.NewGuid.ToString;
      Store.Entries.Add(Path, Entry);
      Store.Commit;
      if not ImplicitCreate then
        Exit;
      Exists := True;
    end;
    if not Exists then
      IOFailure('Virtual file or directory does not exist');

    if MatchStr(N, ['list', 'setFileConnection']) then
    begin
      if not Entry.Has(FileDirectory) or Entry.Has(FileUnreadable) then
        IOFailure('Accessible virtual directory required');
      if N = 'setFileConnection' then
      begin
        var Child := StringArgument(Args[1]);
        var Target := J2MEFileParent(Path);
        if Child <> '..' then
        begin
          if Child.EndsWith('/') then
            SetLength(Child, Length(Child) - 1);
          if not ValidJ2MEFileName(Child) then
            FVM.RaiseJava('java/lang/IllegalArgumentException', 'Invalid child filename');
          Target := Path + '/' + Child;
        end;
        if not Store.Entries.TryGetValue(Target, Entry) then
          FVM.RaiseJava('java/lang/IllegalArgumentException', 'Target does not exist');
        Obj.Fields[FilePath] := TJVMValue.Ref(FVM.NewString(Target));
        Obj.Fields[FileFolder] := TJVMValue.Int(Ord(Entry.Has(FileDirectory)));
        Exit;
      end;
      var Pattern: string := '*';
      var Hidden := False;
      if Length(Args) > 1 then
      begin
        Pattern := StringArgument(Args[1]);
        Hidden := Args[2].AsInt <> 0;
        if not ValidJ2MEFileName(Pattern, True) then
          FVM.RaiseJava('java/lang/IllegalArgumentException', 'Invalid file filter');
      end;
      var Names := TList<string>.Create;
      try
        for var Pair in Store.Entries do
          if (J2MEFileParent(Pair.Key) = Path) and (Hidden or not Pair.Value.Has(FileHidden)) then
          begin
            var Leaf := J2MEFileLeaf(Pair.Key);
            if FileMatches(Leaf, Pattern) then
            begin
              if Pair.Value.Has(FileDirectory) then
                Leaf := Leaf + '/';
              Names.Add(Leaf);
            end;
          end;
        Names.Sort;
        Exit(NewEnumeration(Names.ToArray));
      finally
        Names.Free;
      end;
    end;

    if N = 'openInputStream' then
    begin
      if Entry.Has(FileDirectory or FileUnreadable) then
        IOFailure('Accessible virtual file required');
      var Existing := Obj.Fields[FileInRef].AsRef;
      if (Existing <> 0) and (FVM.GetObject(Existing).Fields[InData].AsRef <> 0) then
        IOFailure('An input stream is already open');
      var Ref := FVM.NewObject(FileInput);
      var Input := FVM.GetObject(Ref);
      Input.Fields[InTarget] := Obj.Fields[FilePath];
      Input.Fields[InIdentity] := TJVMValue.Ref(FVM.NewString(Entry.Identity));
      RefreshInput(Input, Entry.Data, J2MEFileRevision);
      Obj.Fields[FileInRef] := TJVMValue.Ref(Ref);
      Exit(TJVMValue.Ref(Ref));
    end;
    if N = 'openOutputStream' then
    begin
      var Offset: Int64 := 0;
      if Length(Args) > 1 then
        Offset := Args[1].AsLong;
      if Offset < 0 then
        FVM.RaiseJava('java/lang/IllegalArgumentException', 'Negative file offset');
      if Entry.Has(FileDirectory or FileUnwritable) then
        IOFailure('Writable virtual file required');
      var Existing := Obj.Fields[FileOutRef].AsRef;
      if (Existing <> 0) and (FVM.GetObject(Existing).Fields[OutClosed].AsInt = 0) then
        IOFailure('An output stream is already open');
      var Ref := FVM.NewObject(FileOutput);
      var Stream := FVM.GetObject(Ref);
      Stream.Fields[OutTarget] := Obj.Fields[FilePath];
      Stream.Fields[OutIdentity] := TJVMValue.Ref(FVM.NewString(Entry.Identity));
      Stream.Fields[OutOffset] := TJVMValue.Int(Integer(Min(Offset, Int64(Length(Entry.Data)))));
      Obj.Fields[FileOutRef] := TJVMValue.Ref(Ref);
      Exit(TJVMValue.Ref(Ref));
    end;

    if Root then
      IOFailure('A virtual volume root cannot be changed');
    if MatchStr(N, ['setHidden', 'setReadable', 'setWritable']) then
    begin
      var Flag := FileHidden;
      var SetFlag := Args[1].AsInt <> 0;
      if N <> 'setHidden' then
      begin
        if N = 'setReadable' then
          Flag := FileUnreadable
        else
          Flag := FileUnwritable;
        SetFlag := not SetFlag;
      end;
      if SetFlag then
        Entry.Flags := Entry.Flags or Flag
      else
        Entry.Flags := Entry.Flags and not Flag;
      Store.Entries[Path] := Entry;
      Store.Commit;
      Exit;
    end;
    if Entry.Has(FileUnwritable) then
      IOFailure('Virtual file is read-only');
    if N = 'truncate' then
    begin
      var Offset := Args[1].AsLong;
      if Offset < 0 then
        FVM.RaiseJava('java/lang/IllegalArgumentException', 'Negative file length');
      if Entry.Has(FileDirectory) then
        IOFailure('Cannot truncate a directory');
      var OutRef := Obj.Fields[FileOutRef].AsRef;
      if OutRef <> 0 then
        FlushOutput(FVM.GetObject(OutRef), Store);
      Entry := Store.Entries[Path];
      if Offset < Length(Entry.Data) then
      begin
        Entry.Data := Copy(Entry.Data, 0, Integer(Offset));
        Entry.Modified := FileTimeMillis;
        Store.Entries[Path] := Entry;
        Store.Commit;
        if OutRef <> 0 then
        begin
          var Output := FVM.GetObject(OutRef);
          if Output.Fields[OutOffset].AsInt > Offset then
            Output.Fields[OutOffset] := TJVMValue.Int(Integer(Offset));
        end;
      end;
      Exit;
    end;
    if N = 'delete' then
    begin
      for var Key in Store.Entries.Keys do
        if J2MEFileParent(Key) = Path then
          IOFailure('Virtual directory is not empty');
      CloseStreams(Obj);
      Store.Entries.Remove(Path);
      Store.Commit;
      Exit;
    end;
    if N = 'rename' then
    begin
      var Leaf := StringArgument(Args[1]);
      if Entry.Has(FileDirectory) and Leaf.EndsWith('/') then
        SetLength(Leaf, Length(Leaf) - 1);
      if not ValidJ2MEFileName(Leaf) then
        FVM.RaiseJava('java/lang/IllegalArgumentException', 'Invalid destination filename');
      var Target := J2MEFileParent(Path) + '/' + Leaf;
      if Store.Entries.ContainsKey(Target) then
        IOFailure('Virtual destination already exists');
      var Prefix := Path + '/';
      var Keys := Store.Entries.Keys.ToArray;
      for var Key in Keys do
        if ((Key = Path) or Key.StartsWith(Prefix)) and
          (Length(Target) + Length(Key) - Length(Path) > J2MEPathChars) then
          IOFailure('Renamed path too long');
      var TargetRef := FVM.NewString(Target);
      CloseStreams(Obj);
      for var Key in Keys do
        if (Key = Path) or Key.StartsWith(Prefix) then
        begin
          var Moved := Store.Entries[Key];
          Store.Entries.Remove(Key);
          Store.Entries.Add(Target + Copy(Key, Length(Path) + 1, MaxInt), Moved);
        end;
      Store.Commit;
      Obj.Fields[FilePath] := TJVMValue.Ref(TargetRef);
      Obj.Fields[FileFolder] := TJVMValue.Int(Ord(Entry.Has(FileDirectory)));
      Exit;
    end;
    raise EJVMUnsupported.Create('Unknown file connection method ' + N);
  finally
    Store.Free;
  end;
end;

procedure TJ2MEFileSystem.RefreshInput(Stream: TJVMObject; const Data: TBytes; Revision: Int64);
begin
  var Ref := FVM.NewArray('[B', Length(Data));
  var Buffer := FVM.GetObject(Ref);
  for var I := 0 to High(Data) do
    Buffer.ElementValues[I] := TJVMValue.Int(ShortInt(Data[I]));
  Stream.Fields[InData] := TJVMValue.Ref(Ref);
  Stream.Fields[InRevision] := TJVMValue.Long(Revision);
end;

function TJ2MEFileSystem.InvokeInput(Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
begin
  Result := Default(TJVMValue);
  var Obj := FVM.GetObject(Args[0].AsRef);
  var N := Method.Name;
  if N = 'markSupported' then
    Exit(TJVMValue.Int(1));
  if N = 'close' then
  begin
    Obj.Fields[InData] := TJVMValue.Ref(0);
    Exit;
  end;
  var Ref := Obj.Fields[InData].AsRef;
  if Ref = 0 then
  begin
    if N = 'mark' then
      Exit;
    IOFailure('Input stream is closed');
  end;
  if Obj.Fields[InRevision].AsLong <> J2MEFileRevision then
  begin
    var Store := BeginStore;
    try
      var Entry: TJ2MEFileEntry;
      if not Store.Entries.TryGetValue(StringArgument(Obj.Fields[InTarget]), Entry) or
        (Entry.Identity <> StringArgument(Obj.Fields[InIdentity])) then
      begin
        Obj.Fields[InData] := TJVMValue.Ref(0);
        IOFailure('Input file has been replaced or removed');
      end;
      RefreshInput(Obj, Entry.Data, J2MEFileRevision);
      Ref := Obj.Fields[InData].AsRef;
    finally
      Store.Free;
    end;
  end;
  var Buffer := FVM.GetObject(Ref);
  var Position := Obj.Fields[InPosition].AsInt;
  var Remaining := Max(0, Buffer.ElementCount - Position);
  if N = 'available' then
    Exit(TJVMValue.Int(Remaining));
  if N = 'mark' then
  begin
    Obj.Fields[InMark] := Obj.Fields[InPosition];
    Exit;
  end;
  if N = 'reset' then
  begin
    Obj.Fields[InPosition] := Obj.Fields[InMark];
    Exit;
  end;
  if N = 'skip' then
  begin
    var Count := Integer(Min(Int64(Remaining), Max(Int64(0), Args[1].AsLong)));
    Obj.Fields[InPosition] := TJVMValue.Int(Position + Count);
    Exit(TJVMValue.Long(Count));
  end;

  if Length(Args) = 1 then
  begin
    if Remaining = 0 then
      Exit(TJVMValue.Int(-1));
    Obj.Fields[InPosition] := TJVMValue.Int(Position + 1);
    Exit(TJVMValue.Int(Buffer.ElementValues[Position].AsInt and 255));
  end;
  var Target := ByteArray(Args[1]);
  var Offset := Args[2].AsInt;
  var Count := Args[3].AsInt;
  if (Offset < 0) or (Count < 0) or (Int64(Offset) + Count > Target.ElementCount) then
    FVM.RaiseJava('java/lang/IndexOutOfBoundsException');
  if Count = 0 then
    Exit(TJVMValue.Int(0));
  if Remaining = 0 then
    Exit(TJVMValue.Int(-1));
  Count := Min(Count, Remaining);
  Buffer.CopyArrayElementsTo(Target, Position, Offset, Count);
  Obj.Fields[InPosition] := TJVMValue.Int(Position + Count);
  Result := TJVMValue.Int(Count);
end;

procedure TJ2MEFileSystem.InvokeOutput(Method: TJVMMethod; const Args: TArray<TJVMValue>);
var
  Source, Buffer: TJVMObject;
begin
  var Obj := FVM.GetObject(Args[0].AsRef);
  var N := Method.Name;
  if Obj.Fields[OutClosed].AsInt <> 0 then
  begin
    if N = 'close' then
      Exit;
    IOFailure('Output stream is closed');
  end;
  if (N = 'flush') or (N = 'close') then
  begin
    if Obj.Fields[OutCount].AsInt <> 0 then
    begin
      var Store := BeginStore;
      try
        FlushOutput(Obj, Store);
      finally
        Store.Free;
      end;
    end;
    if N = 'close' then
    begin
      Obj.Fields[OutClosed] := TJVMValue.Int(1);
      Obj.Fields[OutData] := TJVMValue.Ref(0);
    end;
    Exit;
  end;

  Source := nil;
  var Count := 1;
  var Start := 0;
  if Length(Args) > 2 then
  begin
    Source := ByteArray(Args[1]);
    Start := Args[2].AsInt;
    Count := Args[3].AsInt;
    if (Start < 0) or (Count < 0) or (Int64(Start) + Count > Source.ElementCount) then
      FVM.RaiseJava('java/lang/IndexOutOfBoundsException');
    if Count = 0 then
      Exit;
  end;
  var Buffered := Obj.Fields[OutCount].AsInt;
  var Limit := Min(J2MEFileBytes, FVM.MaxArrayLength);
  if Int64(Obj.Fields[OutOffset].AsInt) + Buffered + Count > Limit then
    IOFailure('Virtual file is too large');
  var Ref := Obj.Fields[OutData].AsRef;
  var Size := 0;
  Buffer := nil;
  if Ref <> 0 then
  begin
    Buffer := FVM.GetObject(Ref);
    Size := Buffer.ElementCount;
  end;
  if Buffered + Count > Size then
  begin
    Ref := FVM.NewArray('[B', Min(Limit, Max(Buffered + Count, Max(256, Size * 2))));
    var NewBuffer := FVM.GetObject(Ref);
    if Buffered > 0 then
      Buffer.CopyArrayElementsTo(NewBuffer, 0, 0, Buffered);
    Obj.Fields[OutData] := TJVMValue.Ref(Ref);
    Buffer := NewBuffer;
  end;
  if Source = nil then
    Buffer.ElementValues[Buffered] := TJVMValue.Int(ShortInt(Args[1].AsInt and 255))
  else
    Source.CopyArrayElementsTo(Buffer, Start, Buffered, Count);
  Obj.Fields[OutCount] := TJVMValue.Int(Buffered + Count);
end;

function TJ2MEFileSystem.SiemensPath(const Value: string; Directory: Boolean): string;
begin
  var Path := Value.Replace('\', '/');
  var Root := SiemensPrivate;
  if SameText(Copy(Path, 1, 3), SiemensDrive + '/') then
  begin
    Root := SiemensRoot;
    Delete(Path, 1, 3);
  end;
  if Path.StartsWith('/') then
    FVM.RaiseJava('java/lang/IllegalArgumentException', 'Invalid Siemens file path');
  if Directory and Path.EndsWith('/') then
    SetLength(Path, Length(Path) - 1);
  if (Path = '') and Directory then
    Exit(Root);
  for var Part in Path.Split(['/']) do
    if not ValidJ2MEFileName(Part) then
      FVM.RaiseJava('java/lang/IllegalArgumentException', 'Invalid Siemens file path');
  Result := Root + '/' + Path;
  if Length(Result) > J2MEPathChars then
    FVM.RaiseJava('java/lang/IllegalArgumentException', 'Siemens file path is too long');
end;

function SiemensStaticField(C: TJVMClass; const Name: string): TJVMField;
begin
  for var Field in C.Fields do
    if Field.Name = Name then
      Exit(Field);
  raise EJVMError.Create('Missing Siemens File field: ' + Name);
end;

function SiemensParentWritable(Store: TJ2MEFileStore; const Path: string): Boolean;
begin
  var Parent: TJ2MEFileEntry;
  Result := Store.Entries.TryGetValue(J2MEFileParent(Path), Parent) and Parent.Has(FileDirectory) and
    not Parent.Has(FileUnwritable);
end;

function TJ2MEFileSystem.SiemensOpen(C: TJVMClass; const Path: string; Store: TJ2MEFileStore): TJVMValue;
begin
  Result := TJVMValue.Int(-1);
  var Entry: TJ2MEFileEntry;
  var Exists := Store.Entries.TryGetValue(Path, Entry);
  if Exists then
  begin
    if Entry.Has(FileDirectory) or (Entry.Has(FileUnreadable) and Entry.Has(FileUnwritable)) then
      Exit;
  end
  else if (Store.Entries.Count >= J2MEFileEntries) or not SiemensParentWritable(Store, Path) then
    Exit;

  var Field := SiemensStaticField(C, '$handles');
  if Field.Value.AsRef = 0 then
    Field.Value := TJVMValue.Ref(FVM.NewArray(SiemensHandles, SiemensMaxHandles));
  var Slots := FVM.GetObject(Field.Value.AsRef);
  var Slot := 0;
  while (Slot < Slots.ElementCount) and (Slots.ElementValues[Slot].AsRef <> 0) do
    Inc(Slot);
  var Sequence := SiemensStaticField(C, '$nextHandle');
  if (Slot = Slots.ElementCount) or (Sequence.Value.AsInt = MaxInt) then
    Exit;
  var ID := Sequence.Value.AsInt + 1;
  var Ref := FVM.NewObject(SiemensHandle);
  var Handle := FVM.GetObject(Ref);
  if not Exists then
  begin
    Entry := Default(TJ2MEFileEntry);
    Entry.Identity := TGUID.NewGuid.ToString;
    Entry.Modified := FileTimeMillis;
  end;
  Handle.Fields[SiemensHandleID] := TJVMValue.Int(ID);
  Handle.Fields[SiemensHandleIdentity] := TJVMValue.Ref(FVM.NewString(Entry.Identity));
  if not Exists then
  begin
    Store.Entries.Add(Path, Entry);
    Store.Commit;
  end;
  Slots.ElementValues[Slot] := TJVMValue.Ref(Ref);
  Sequence.Value := TJVMValue.Int(ID);
  Result := TJVMValue.Int(ID);
end;

function TJ2MEFileSystem.InvokeSiemensDescriptor(Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
var
  Handle: TJVMObject;
  Entry: TJ2MEFileEntry;
begin
  var N := Method.Name;
  var Truncate := N = 'truncate';
  var ID := Args[Ord(not Truncate)].AsInt;
  Result := TJVMValue.Int(-1);
  Handle := nil;
  var Ref := SiemensStaticField(Method.Owner, '$handles').Value.AsRef;
  if Ref <> 0 then
  begin
    var Slots := FVM.GetObject(Ref);
    for var Slot := 0 to Slots.ElementCount - 1 do
    begin
      Ref := Slots.ElementValues[Slot].AsRef;
      if Ref = 0 then
        Continue;
      var Candidate := FVM.GetObject(Ref);
      if Candidate.Fields[SiemensHandleID].AsInt <> ID then
        Continue;
      Handle := Candidate;
      if N = 'close' then
      begin
        Slots.ElementValues[Slot] := TJVMValue.Ref(0);
        Exit(TJVMValue.Int(0));
      end;
      Break;
    end;
  end;
  if Handle = nil then
  begin
    if Truncate then
      IOFailure('Invalid Siemens file descriptor');
    Exit;
  end;

  var Store := BeginStore;
  try
    var Identity := StringArgument(Handle.Fields[SiemensHandleIdentity]);
    var Path := '';
    for var Pair in Store.Entries do
      if Pair.Value.Identity = Identity then
      begin
        Path := Pair.Key;
        Entry := Pair.Value;
        Break;
      end;
    if Path = '' then
    begin
      if Truncate then
        IOFailure('Siemens file has been removed');
      Exit;
    end;

    if N = 'length' then
      Exit(TJVMValue.Int(Length(Entry.Data)));
    if N = 'seek' then
    begin
      if Args[2].AsInt < 0 then
        Exit;
      Handle.Fields[SiemensHandlePosition] := Args[2];
      Exit(Args[2]);
    end;

    var Position := Handle.Fields[SiemensHandlePosition].AsInt;
    var Offset := 0;
    var Count := 0;
    var Buffer: TJVMObject := nil;
    if not Truncate then
    begin
      Buffer := ByteArray(Args[2]);
      Offset := Args[3].AsInt;
      Count := Args[4].AsInt;
      if (Offset < 0) or (Count < 0) or (Offset > Buffer.ElementCount - Count) then
        FVM.RaiseJava('java/lang/IndexOutOfBoundsException');
      if N = 'read' then
      begin
        if Entry.Has(FileUnreadable) then
          Exit;
        Count := Min(Count, Max(0, Length(Entry.Data) - Position));
        for var I := 0 to Count - 1 do
          Buffer.ElementValues[Offset + I] := TJVMValue.Int(ShortInt(Entry.Data[Position + I]));
        Handle.Fields[SiemensHandlePosition] := TJVMValue.Int(Position + Count);
        Exit(TJVMValue.Int(Count));
      end;
      if Entry.Has(FileUnwritable) or ((Count <> 0) and (Position > J2MEFileBytes - Count)) then
        Exit;
      if Count = 0 then
        Exit(TJVMValue.Int(0));
    end;

    var Size: Integer;
    if Truncate then
    begin
      Size := Args[1].AsInt;
      if Entry.Has(FileUnwritable) or (Size < 0) or (Size > J2MEFileBytes) then
        IOFailure('Invalid Siemens file size');
    end
    else
      Size := Max(Position + Count, Length(Entry.Data));

    if Store.BytesUnder(SiemensRoot + '/', True) + Size - Length(Entry.Data) > J2MEVolumeBytes then
      IOFailure('Virtual volume is full');
    SetLength(Entry.Data, Size);
    for var I := 0 to Count - 1 do
      Entry.Data[Position + I] := Byte(Buffer.ElementValues[Offset + I].AsInt and 255);
    Entry.Modified := FileTimeMillis;
    Store.Entries[Path] := Entry;
    Store.Commit;
    if not Truncate then
    begin
      Handle.Fields[SiemensHandlePosition] := TJVMValue.Int(Position + Count);
      Result := TJVMValue.Int(Count);
    end;
  finally
    Store.Free;
  end;
end;

function TJ2MEFileSystem.InvokeSiemensFile(Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
var
  Entry: TJ2MEFileEntry;
begin
  var N := Method.Name;
  if MatchStr(N, ['close', 'length', 'seek', 'read', 'write', 'truncate']) then
    Exit(InvokeSiemensDescriptor(Method, Args));

  Result := TJVMValue.Int(-1);
  var Path := '';
  if N <> 'spaceAvailable' then
    Path := SiemensPath(StringArgument(Args[Ord(N = 'open')]), MatchStr(N, ['list', 'isDirectory', 'buildPath', 'checkFileName']));
  if N = 'checkFileName' then
    Exit(TJVMValue.Int(Ord(not SameText(Copy(StringArgument(Args[0]), 1, 2), SiemensDrive))));
  if N = 'buildPath' then
    Exit(TJVMValue.Ref(FVM.NewString(SiemensDrive + Copy(Path, 3, MaxInt).Replace('/', '\'))));

  var Store := BeginStore;
  try
    if N = 'spaceAvailable' then
      Exit(TJVMValue.Int(Integer(J2MEVolumeBytes - Store.BytesUnder(SiemensRoot + '/', True))));
    if N = 'open' then
      Exit(SiemensOpen(Method.Owner, Path, Store));

    var Exists := Store.Entries.TryGetValue(Path, Entry);
    if N = 'exists' then
    begin
      if Exists then
        Result := TJVMValue.Int(1);
      Exit;
    end;
    if N = 'isDirectory' then
      Exit(TJVMValue.Int(Ord(Exists and Entry.Has(FileDirectory))));
    if N = 'list' then
    begin
      if not Exists or not Entry.Has(FileDirectory) or Entry.Has(FileUnreadable) then
        IOFailure('Accessible Siemens directory required');
      var Names := TList<string>.Create;
      try
        for var Item in Store.Entries.Keys do
          if J2MEFileParent(Item) = Path then
            Names.Add(J2MEFileLeaf(Item));
        Names.Sort;
        var ListRef := FVM.NewArray('[Ljava/lang/String;', Names.Count);
        var List := FVM.GetObject(ListRef);
        for var I := 0 to Names.Count - 1 do
          List.ElementValues[I] := TJVMValue.Ref(FVM.NewString(Names[I]));
        Exit(TJVMValue.Ref(ListRef));
      finally
        Names.Free;
      end;
    end;

    if N = 'debugWrite' then
    begin
      var Data := TEncoding.UTF8.GetBytes(StringArgument(Args[1]));
      if (not Exists and ((Store.Entries.Count >= J2MEFileEntries) or not SiemensParentWritable(Store, Path))) or
        (Exists and Entry.Has(FileDirectory or FileUnwritable)) then
        Exit;
      if not Exists then
        Entry := Default(TJ2MEFileEntry);
      var OldLength := Length(Entry.Data);
      if (Length(Data) > J2MEFileBytes - OldLength) or
        (Store.BytesUnder(SiemensRoot + '/', True) + Length(Data) > J2MEVolumeBytes) then
        IOFailure('Virtual volume or file is full');
      if not Exists then
        Entry.Identity := TGUID.NewGuid.ToString;
      SetLength(Entry.Data, OldLength + Length(Data));
      if Length(Data) <> 0 then
        Move(Data[0], Entry.Data[OldLength], Length(Data));
      Entry.Modified := FileTimeMillis;
      Store.Entries.AddOrSetValue(Path, Entry);
      Store.Commit;
      Exit(TJVMValue.Int(1));
    end;

    if not Exists or Entry.Has(FileDirectory) then
      Exit;
    if N = 'delete' then
    begin
      if Entry.Has(FileUnwritable) or not SiemensParentWritable(Store, Path) then
        Exit;
      Store.Entries.Remove(Path);
    end
    else
    begin
      var Destination := SiemensPath(StringArgument(Args[1]));
      if Store.Entries.ContainsKey(Destination) or not SiemensParentWritable(Store, Destination) then
        Exit;
      if N = 'copy' then
      begin
        if Entry.Has(FileUnreadable) or (Store.Entries.Count >= J2MEFileEntries) then
          Exit;
        if Store.BytesUnder(SiemensRoot + '/', True) + Length(Entry.Data) > J2MEVolumeBytes then
          IOFailure('Virtual volume is full');
        Entry.Identity := TGUID.NewGuid.ToString;
        Entry.Modified := FileTimeMillis;
      end
      else
      begin
        if Entry.Has(FileUnwritable) or not SiemensParentWritable(Store, Path) then
          Exit;
        Store.Entries.Remove(Path);
      end;
      Store.Entries.Add(Destination, Entry);
    end;
    Store.Commit;
    Result := TJVMValue.Int(1);
  finally
    Store.Free;
  end;
end;

function TJ2MEFileSystem.Handles(const Owner: string): Boolean;
begin
  Result := MatchStr(Owner, [Registry, FileImpl, FileInput, FileOutput, FileEnum, SiemensFile]);
end;

function TJ2MEFileSystem.Invoke(Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
begin
  Result := Default(TJVMValue);
  var Owner := Method.Owner.Name;
  try
    if Owner = FileImpl then
      Exit(InvokeConnection(Method, Args));
    if Owner = SiemensFile then
      Exit(InvokeSiemensFile(Method, Args));
    if Owner = FileInput then
      Exit(InvokeInput(Method, Args));
    if Owner = FileOutput then
    begin
      InvokeOutput(Method, Args);
      Exit;
    end;
    if Owner = Registry then
      Exit(InvokeRegistry(Method, Args));
    var Obj := FVM.GetObject(Args[0].AsRef);
    var Items := FVM.GetObject(Obj.Fields[EnumItems].AsRef);
    var Position := Obj.Fields[EnumPosition].AsInt;
    if Method.Name = 'hasMoreElements' then
      Exit(TJVMValue.Int(Ord(Position < Items.ElementCount)));
    if Position >= Items.ElementCount then
      FVM.RaiseJava('java/util/NoSuchElementException');
    Result := Items.ElementValues[Position];
    Obj.Fields[EnumPosition] := TJVMValue.Int(Position + 1);
  except
    on E: EJVMError do
      raise;
    on E: EAccessViolation do
      raise;
    on E: EOutOfMemory do
      FVM.RaiseJava('java/lang/OutOfMemoryError');
    on E: EJ2MEFileIO do
      IOFailure(E.Message);
    on E: Exception do
      IOFailure('Virtual file system I/O error');
  end;
end;

end.

