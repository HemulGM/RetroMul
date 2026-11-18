unit J2ME.RMS.Store;

interface

uses
  System.Classes, JVM.StateIO, System.SysUtils, System.Generics.Collections,
  Core.Storage;

type
  ERMS = class(Exception)
  public
    Kind: string;
    constructor Create(const ErrorKind, Message: string);
  end;

  TRMSSnapshot = class
  public
    Vendor, Suite, Name: string;
    Shared, Writable: Boolean;
    NextID: Integer;
    Version, Modified: Int64;
    Records: TDictionary<Integer, TBytes>;
    constructor Create;
    destructor Destroy; override;
    function Encode: TBytes;
    class function Decode(const Bytes: TBytes): TRMSSnapshot; static;
  end;

  TRMSChange = record
    Kind, ID: Integer; // 1 added, 2 changed, 3 deleted.
  end;

  TRMSLease = class
  private
    FLock: TObject;
    FPending: TQueue<TRMSChange>;
    FNotifications: Boolean;
  public
    FileName, Vendor, Suite, Name: string;
    Owner, CanWrite: Boolean;
    procedure TransferState(S: TJVMStateIO);
    destructor Destroy; override;
    function TakeChange(out Change: TRMSChange): Boolean;
    procedure SetNotifications(Enabled: Boolean);
  end;

  TRMSDatabase = class
  private
    FStorage: IStorage;
    FRoot, FVendor, FSuite: string;
    FCancelled: TFunc<Boolean>;
    FLockTimeoutMillis: Integer;
    procedure EnsureFolder(const Folder: string);
    function Enter: TObject;
    procedure Leave(Lock: TObject);
    function Load(Lease: TRMSLease): TRMSSnapshot;
    function SuiteBytes(const Vendor, Suite: string): Int64;
    procedure Commit(State: TRMSSnapshot);
  public
    const
      MaxStoreBytes = 16 * 1024 * 1024;
      MaxSuiteBytes = 64 * 1024 * 1024;
    constructor Create(const Storage: IStorage; const Vendor, Suite: string);
    property Cancelled: TFunc<Boolean> read FCancelled write FCancelled;
    // Default waits for the transaction lock; finite bounds are an explicit policy.
    property LockTimeoutMillis: Integer read FLockTimeoutMillis write FLockTimeoutMillis;
    function SuiteFolder(const Vendor, Suite: string): string;
    function StoreFile(const Vendor, Suite, Name: string): string;
    function Open(const Vendor, Suite, Name: string; CreateIfMissing: Boolean; AuthMode: Integer; Writable: Boolean; Now: Int64): TRMSLease;
    function CaptureStateStores: TDictionary<string, TBytes>;
    procedure ReplaceStateStores(Stores: TDictionary<string, TBytes>);
    procedure AttachStateLease(Lease: TRMSLease);
    function Read(Lease: TRMSLease): TRMSSnapshot;
    function Modify(Lease: TRMSLease; Kind, ID: Integer; const Data: TBytes; Now: Int64): Integer;
    procedure SetMode(Lease: TRMSLease; AuthMode: Integer; Writable: Boolean; Now: Int64);
    procedure Delete(const Name: string);
    function Names: TArray<string>;
    function Available(Lease: TRMSLease): Integer;
  end;

function J2MESuiteStorageKey(const A, B: string): string;

function LockJ2MEDataFile(const Path: string; const Cancelled: TFunc<Boolean>): TObject;

implementation

uses
  System.IOUtils, System.Hash, System.SyncObjs,
  {$IFDEF MSWINDOWS}
  Winapi.Windows,
  {$ELSE}
  Posix.Base, Posix.Fcntl, Posix.Unistd, Posix.Errno,
  {$ENDIF}
  System.Math;

{$Q-}{$R-}

{$IFNDEF MSWINDOWS}
function RMSFlock(Handle, Operation: Integer): Integer; cdecl; external libc name _PU + 'flock';
{$ENDIF}

type
  TRMSFileLock = class
  private
    {$IFDEF MSWINDOWS}
    FHandle: THandle;
    FOverlap: TOverlapped;
    {$ELSE}
    FHandle: Integer;
    {$ENDIF}
    FLocked: Boolean;
  public
    constructor Create(const Name: string; Exclusive: Boolean; Timeout: Integer; const Cancelled: TFunc<Boolean> = nil);
    destructor Destroy; override;
  end;

var
  Gate, DataGate: TCriticalSection;
  Leases: TList<TRMSLease>;

function LockJ2MEDataFile(const Path: string; const Cancelled: TFunc<Boolean>): TObject;
begin
  Result := TRMSFileLock.Create(Path, True, -1, Cancelled);
end;

constructor ERMS.Create(const ErrorKind, Message: string);
begin
  inherited Create(Message);
  Kind := ErrorKind;
end;

constructor TRMSFileLock.Create(const Name: string; Exclusive: Boolean; Timeout: Integer; const Cancelled: TFunc<Boolean>);

  function IsCancelled: Boolean;
  begin
    Result := Assigned(Cancelled) and Cancelled();
  end;

  procedure CheckCancelled;
  begin
    if IsCancelled then
      raise ERMS.Create('RecordStoreException', 'RMS wait cancelled');
  end;

begin
  inherited Create;
  {$IFDEF MSWINDOWS}
  FHandle := INVALID_HANDLE_VALUE;
  CheckCancelled;
  FHandle := CreateFile(PChar(NativeStoragePath(Name)), GENERIC_READ or GENERIC_WRITE, FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE,
    nil, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL or FILE_FLAG_OVERLAPPED, 0);
  if FHandle = INVALID_HANDLE_VALUE then
    RaiseLastOSError;
  FOverlap.hEvent := CreateEvent(nil, True, False, nil);
  if FOverlap.hEvent = 0 then
    RaiseLastOSError;
  var Flags: Cardinal := 0;
  if Exclusive then
    Flags := Flags or LOCKFILE_EXCLUSIVE_LOCK;
  if Timeout = 0 then
    Flags := Flags or LOCKFILE_FAIL_IMMEDIATELY;
  if LockFileEx(FHandle, Flags, 0, 1, 0, FOverlap) then
  begin
    FLocked := True;
    CheckCancelled;
    Exit;
  end;
  var Code := GetLastError;
  if Code = ERROR_IO_PENDING then
  begin
    var Started := TThread.GetTickCount64;
    repeat
      var Delay: Cardinal := INFINITE;
      if Timeout >= 0 then
      begin
        var Elapsed := TThread.GetTickCount64 - Started;
        if Elapsed >= UInt64(Timeout) then
          Delay := 0
        else
          Delay := Cardinal(UInt64(Timeout) - Elapsed);
      end;
      if Assigned(Cancelled) then
        Delay := Min(Delay, Cardinal(25));
      var Status := WaitForSingleObject(FOverlap.hEvent, Delay);
      var WaitError := Cardinal(0);
      if Status = WAIT_FAILED then
        WaitError := GetLastError;
      var Transferred: Cardinal := 0;
      if Status = WAIT_OBJECT_0 then
      begin
        if GetOverlappedResult(FHandle, FOverlap, Transferred, False) then
        begin
          FLocked := True;
          CheckCancelled;
          Exit;
        end;
        Code := GetLastError;
        Break;
      end;
      var Cancel := IsCancelled;
      var Expired := (Timeout >= 0) and (TThread.GetTickCount64 - Started >= UInt64(Timeout));
      if Cancel or Expired or (Status <> WAIT_TIMEOUT) then
      begin
        // Keep OVERLAPPED/event alive until cancellation retires the request.
        // A grant racing cancellation still belongs to us and must be unlocked.
        CancelIoEx(FHandle, @FOverlap);
        FLocked := GetOverlappedResult(FHandle, FOverlap, Transferred, True);
        if Cancel then
          raise ERMS.Create('RecordStoreException', 'RMS wait cancelled');
        if Expired then
          raise ERMS.Create('RecordStoreException', 'RMS lock timed out: ' + ExtractFileName(Name));
        if WaitError <> 0 then
          RaiseLastOSError(WaitError);
        raise ERMS.Create('RecordStoreException', 'RMS lock wait failed');
      end;
    until False;
  end;
  if Code = ERROR_LOCK_VIOLATION then
    raise ERMS.Create('RecordStoreException', 'RMS file is in use: ' + ExtractFileName(Name));
  RaiseLastOSError(Code);
  {$ELSE}
  FHandle := -1;
  CheckCancelled;
  var Path := UTF8String(Name);
  FHandle := Posix.Fcntl.open(PAnsiChar(Path), O_RDWR or O_CREAT, $180);
  if FHandle < 0 then
    RaiseLastOSError;
  fcntl(FHandle, F_SETFD, FD_CLOEXEC);
  var Started := TThread.GetTickCount64;
  repeat
    CheckCancelled;
    var Flags := 1 or 4;
    if Exclusive then
      Flags := 2 or 4;
    if RMSFlock(FHandle, Flags) = 0 then
    begin
      FLocked := True;
      CheckCancelled;
      Exit;
    end;
    var Code := Posix.Errno.errno;
    if (Code <> EAGAIN) and (Code <> EWOULDBLOCK) and (Code <> EINTR) then
      RaiseLastOSError(Code);
    if (Timeout >= 0) and (TThread.GetTickCount64 - Started >= UInt64(Timeout)) then
      raise ERMS.Create('RecordStoreException', 'RMS lock timed out');
    TThread.Sleep(1);
  until False;
  {$ENDIF}
end;

destructor TRMSFileLock.Destroy;
begin
  {$IFDEF MSWINDOWS}
  if FHandle <> INVALID_HANDLE_VALUE then
  begin
    if FLocked then
      UnlockFileEx(FHandle, 0, 1, 0, FOverlap);
    CloseHandle(FHandle);
  end;
  if FOverlap.hEvent <> 0 then
    CloseHandle(FOverlap.hEvent);
  {$ELSE}
  if FHandle >= 0 then
  begin
    if FLocked then
      RMSFlock(FHandle, 8);
    Posix.Unistd.__close(FHandle);
  end;
  {$ENDIF}
  inherited;
end;

function Digest(const Data: TBytes; Count: Integer): TBytes;
begin
  var Hash := THashSHA2.Create;
  if Count > 0 then
    Hash.Update(Data[0], Count);
  Result := Hash.HashAsBytes;
end;

procedure UInt(Stream: TStream; Value: UInt64; Count: Integer);
begin
  for var I := 1 to Count do
  begin
    var B := Byte(Value);
    Stream.WriteBuffer(B, 1);
    Value := Value shr 8;
  end;
end;

procedure Text(Stream: TStream; const Value: string);
begin
  UInt(Stream, Length(Value), 4);
  for var C in Value do
    UInt(Stream, Ord(C), 2);
end;

function J2MESuiteStorageKey(const A, B: string): string;
begin
  var Stream := TMemoryStream.Create;
  try
    Text(Stream, A);
    Text(Stream, B);
    var Hash := THashSHA2.Create;
    Hash.Update(Stream.Memory^, Integer(Stream.Size));
    Result := Hash.HashAsString;
  finally
    Stream.Free;
  end;
end;

constructor TRMSSnapshot.Create;
begin
  inherited;
  NextID := 1;
  Records := TDictionary<Integer, TBytes>.Create;
end;

destructor TRMSSnapshot.Destroy;
begin
  Records.Free;
  inherited;
end;

function TRMSSnapshot.Encode: TBytes;
var
  Stream: TMemoryStream;
  Hash: TBytes;
begin
  Stream := TMemoryStream.Create;
  try
    var Magic: AnsiString := 'RMRMS001';
    Stream.WriteBuffer(Magic[1], 8);
    Text(Stream, Vendor);
    Text(Stream, Suite);
    Text(Stream, Name);
    UInt(Stream, Ord(Shared), 1);
    UInt(Stream, Ord(Writable), 1);
    UInt(Stream, NextID, 4);
    UInt(Stream, UInt64(Version), 8);
    UInt(Stream, UInt64(Modified), 8);
    UInt(Stream, Records.Count, 4);
    var IDs := Records.Keys.ToArray;
    TArray.Sort<Integer>(IDs);
    for var ID in IDs do
    begin
      var Data := Records[ID];
      UInt(Stream, ID, 4);
      UInt(Stream, Length(Data), 4);
      if Length(Data) > 0 then
        Stream.WriteBuffer(Data[0], Length(Data));
    end;
    if Stream.Size > TRMSDatabase.MaxStoreBytes - 32 then
      raise ERMS.Create('RecordStoreFullException', 'RMS store size limit');
    SetLength(Result, Stream.Size);
    if Stream.Size > 0 then
      Move(Stream.Memory^, Result[0], Stream.Size);
    Hash := Digest(Result, Length(Result));
    SetLength(Result, Length(Result) + 32);
    Move(Hash[0], Result[Length(Result) - 32], 32);
  finally
    Stream.Free;
  end;
end;

class function TRMSSnapshot.Decode(const Bytes: TBytes): TRMSSnapshot;
var
  Position, Limit: Integer;

  function ReadUInt(Count: Integer): UInt64;
  begin
    if (Count < 0) or (Position > Limit - Count) then
      raise ERMS.Create('RecordStoreException', 'Truncated RMS data');
    Result := 0;
    for var I := 0 to Count - 1 do
    begin
      Result := Result or (UInt64(Bytes[Position]) shl (I * 8));
      Inc(Position);
    end;
  end;

  function ReadText: string;
  begin
    var Count := ReadUInt(4);
    if (Count > 65536) or (Count > UInt64((Limit - Position) div 2)) then
      raise ERMS.Create('RecordStoreException', 'RMS identity size');
    SetLength(Result, Integer(Count));
    for var I := 1 to Integer(Count) do
      Result[I] := Char(ReadUInt(2));
  end;

begin
  if (Length(Bytes) < 78) or (Length(Bytes) > TRMSDatabase.MaxStoreBytes) then
    raise ERMS.Create('RecordStoreException', 'RMS file size');
  if TEncoding.ASCII.GetString(Bytes, 0, 8) <> 'RMRMS001' then
    raise ERMS.Create('RecordStoreException', 'RMS format');
  var Hash := Digest(Bytes, Length(Bytes) - 32);
  if not CompareMem(@Hash[0], @Bytes[Length(Bytes) - 32], 32) then
    raise ERMS.Create('RecordStoreException', 'RMS checksum mismatch');
  Position := 8;
  Limit := Length(Bytes) - 32;
  var State := TRMSSnapshot.Create;
  try
    State.Vendor := ReadText;
    State.Suite := ReadText;
    State.Name := ReadText;
    var Flags := ReadUInt(1);
    if Flags > 1 then
      raise ERMS.Create('RecordStoreException', 'RMS authorization flag');
    State.Shared := Flags <> 0;
    Flags := ReadUInt(1);
    if Flags > 1 then
      raise ERMS.Create('RecordStoreException', 'RMS writable flag');
    State.Writable := Flags <> 0;
    var Next := ReadUInt(4);
    var Version := ReadUInt(8);
    var Modified := ReadUInt(8);
    var Count := ReadUInt(4);
    if (Next < 1) or (Next > UInt64(MaxInt)) or (Version > UInt64(High(Int64))) or (Count > 65536) or
      (Length(State.Name) < 1) or (Length(State.Name) > 32) or (State.Vendor = '') or (State.Suite = '') then
      raise ERMS.Create('RecordStoreException', 'RMS metadata');
    State.NextID := Integer(Next);
    State.Version := Int64(Version);
    State.Modified := Int64(Modified);
    var Previous := 0;
    for var I := 1 to Integer(Count) do
    begin
      var ID := ReadUInt(4);
      var Size := ReadUInt(4);
      if (ID <= UInt64(Previous)) or (ID >= Next) or (Size > 1024 * 1024) or (Size > UInt64(Limit - Position)) then
        raise ERMS.Create('RecordStoreException', 'RMS record bounds');
      State.Records.Add(Integer(ID), Copy(Bytes, Position, Integer(Size)));
      Inc(Position, Integer(Size));
      Previous := Integer(ID);
    end;
    if Position <> Limit then
      raise ERMS.Create('RecordStoreException', 'RMS trailing data');
    Result := State;
    State := nil;
  finally
    State.Free;
  end;
end;

destructor TRMSLease.Destroy;
begin
  Gate.Acquire;
  try
    Leases.Remove(Self);
    FPending.Free;
    FLock.Free;
  finally
    Gate.Release;
  end;
  inherited;
end;

function TRMSLease.TakeChange(out Change: TRMSChange): Boolean;
begin
  Gate.Acquire;
  try
    Result := FPending.Count <> 0;
    if Result then
      Change := FPending.Dequeue;
  finally
    Gate.Release;
  end;
end;

procedure TRMSLease.SetNotifications(Enabled: Boolean);
begin
  Gate.Acquire;
  try
    FNotifications := Enabled;
    if not Enabled then
      FPending.Clear;
  finally
    Gate.Release;
  end;
end;

constructor TRMSDatabase.Create(const Storage: IStorage; const Vendor, Suite: string);
begin
  inherited Create;
  if Storage = nil then
    raise EArgumentNilException.Create('RMS storage');
  FStorage := Storage;
  FVendor := Vendor;
  FSuite := Suite;
  FLockTimeoutMillis := -1;
  FRoot := TPath.GetFullPath(TPath.Combine(Storage.SaveRoot, 'j2me' + PathDelim + 'rms'));
end;

procedure TRMSDatabase.EnsureFolder(const Folder: string);
begin
  if FStorage.FolderExists(Folder) then
    Exit;
  // The root lock cannot exist before its parent directory. Create each missing
  // parent separately so a simultaneous first launch can accept EEXIST at that
  // exact component, rather than racing RTL ForceDirectories on the whole path.
  var Parent := ExcludeTrailingPathDelimiter(ExtractFileDir(Folder));
  if (Parent <> '') and (Parent <> Folder) then
    EnsureFolder(Parent);
  try
    FStorage.EnsureFolder(Folder);
  except
    on E: Exception do
      if not FStorage.FolderExists(Folder) then
        raise;
  end;
end;

function TRMSDatabase.Enter: TObject;
begin
  // Lease/notification metadata has a separate short-held gate. Waiting for
  // another process must not block polling events belonging to other VMs.
  var Started := TThread.GetTickCount64;
  while not DataGate.TryEnter do
  begin
    if Assigned(FCancelled) and FCancelled() then
      raise ERMS.Create('RecordStoreException', 'RMS wait cancelled');
    if (FLockTimeoutMillis >= 0) and (TThread.GetTickCount64 - Started >= UInt64(FLockTimeoutMillis)) then
      raise ERMS.Create('RecordStoreException', 'RMS transaction gate timed out');
    TThread.Sleep(1);
  end;
  try
    EnsureFolder(FRoot);
    var Remaining := FLockTimeoutMillis;
    if Remaining >= 0 then
      Remaining := Integer(Max(Int64(0), Int64(Remaining) - Int64(TThread.GetTickCount64 - Started)));
    Result := TRMSFileLock.Create(TPath.Combine(FRoot, '.lock'), True, Remaining, FCancelled);
  except
    DataGate.Release;
    raise;
  end;
end;

procedure TRMSDatabase.Leave(Lock: TObject);
begin
  try
    Lock.Free;
  finally
    DataGate.Release;
  end;
end;

function TRMSDatabase.SuiteFolder(const Vendor, Suite: string): string;
begin
  Result := TPath.Combine(FRoot, J2MESuiteStorageKey(Vendor, Suite));
end;

function TRMSDatabase.StoreFile(const Vendor, Suite, Name: string): string;
begin
  Result := TPath.Combine(SuiteFolder(Vendor, Suite), J2MESuiteStorageKey(Name, '') + '.rms');
end;

function TRMSDatabase.Load(Lease: TRMSLease): TRMSSnapshot;
begin
  if not FStorage.Exists(Lease.FileName) then
    raise ERMS.Create('RecordStoreNotFoundException', Lease.Name);
  Result := TRMSSnapshot.Decode(FStorage.ReadBytes(Lease.FileName));
  if (Result.Vendor <> Lease.Vendor) or (Result.Suite <> Lease.Suite) or (Result.Name <> Lease.Name) then
  begin
    FreeAndNil(Result);
    raise ERMS.Create('RecordStoreException', 'RMS identity mismatch');
  end;
end;

function TRMSDatabase.SuiteBytes(const Vendor, Suite: string): Int64;
begin
  Result := 0;
  var Folder := SuiteFolder(Vendor, Suite);
  if not FStorage.FolderExists(Folder) then
    Exit;
  for var Name in FStorage.Files(Folder) do
    if LowerCase(ExtractFileExt(Name)) = '.rms' then
    begin
      var Input := FStorage.OpenRead(Name);
      try
        Inc(Result, Input.Size);
      finally
        Input.Free;
      end;
    end;
end;

procedure TRMSDatabase.Commit(State: TRMSSnapshot);
begin
  var FileName := StoreFile(State.Vendor, State.Suite, State.Name);
  var Data := State.Encode;
  var Previous: Int64 := 0;
  if FStorage.Exists(FileName) then
  begin
    var Input := FStorage.OpenRead(FileName);
    try
      Previous := Input.Size;
    finally
      Input.Free;
    end;
  end;
  if SuiteBytes(State.Vendor, State.Suite) - Previous + Length(Data) > MaxSuiteBytes then
    raise ERMS.Create('RecordStoreFullException', 'RMS suite quota');
  FStorage.WriteBytes(FileName, Data);
end;

function TRMSDatabase.Open(const Vendor, Suite, Name: string; CreateIfMissing: Boolean; AuthMode: Integer; Writable: Boolean; Now: Int64): TRMSLease;
var
  State: TRMSSnapshot;
  Lock: TObject;
  Lease: TRMSLease;
begin
  if (Length(Name) < 1) or (Length(Name) > 32) then
    raise ERMS.Create('IllegalArgumentException', 'RecordStore name');
  if (Vendor = '') or (Suite = '') or (Length(Vendor) > 65536) or (Length(Suite) > 65536) then
    raise ERMS.Create('RecordStoreException', 'Incomplete/oversized suite identity');
  Lock := Enter;
  State := nil;
  Lease := TRMSLease.Create;
  try
    Lease.Name := Name;
    Lease.Vendor := Vendor;
    Lease.Suite := Suite;
    Lease.FileName := StoreFile(Vendor, Suite, Name);
    Lease.Owner := (Vendor = FVendor) and (Suite = FSuite);
    Lease.FPending := TQueue<TRMSChange>.Create;
    if CreateIfMissing and Lease.Owner then
      FStorage.EnsureFolder(SuiteFolder(Vendor, Suite));
    if FStorage.Exists(Lease.FileName) then
      State := Load(Lease)
    else
    begin
      if not CreateIfMissing or not Lease.Owner then
        raise ERMS.Create('RecordStoreNotFoundException', Name);
      if not (AuthMode in [0, 1]) then
        raise ERMS.Create('IllegalArgumentException', 'RecordStore auth mode');
      var Count := 0;
      for var FileName in FStorage.Files(SuiteFolder(Vendor, Suite)) do
        if LowerCase(ExtractFileExt(FileName)) = '.rms' then
          Inc(Count);
      if Count >= 1024 then
        raise ERMS.Create('RecordStoreFullException', 'RMS store count limit');
      State := TRMSSnapshot.Create;
      State.Vendor := Vendor;
      State.Suite := Suite;
      State.Name := Name;
      State.Shared := AuthMode = 1;
      State.Writable := Writable;
      State.Modified := Now;
    end;
    if not Lease.Owner and not State.Shared then
      raise ERMS.Create('SecurityException', 'RecordStore is private');
    Lease.CanWrite := Lease.Owner or State.Writable;
    Lease.FLock := TRMSFileLock.Create(Lease.FileName + '.open', False, 0);
    if not FStorage.Exists(Lease.FileName) then
      Commit(State);
    Gate.Acquire;
    try
      Leases.Add(Lease);
    finally
      Gate.Release;
    end;
    Result := Lease;
    Lease := nil;
  finally
    State.Free;
    Lease.Free;
    Leave(Lock);
  end;
end;

function TRMSDatabase.Read(Lease: TRMSLease): TRMSSnapshot;
begin
  var Lock := Enter;
  try
    Result := Load(Lease);
  finally
    Leave(Lock);
  end;
end;

function TRMSDatabase.Modify(Lease: TRMSLease; Kind, ID: Integer; const Data: TBytes; Now: Int64): Integer;
var
  State: TRMSSnapshot;
  Lock: TObject;
begin
  Lock := Enter;
  State := nil;
  try
    State := Load(Lease);
    if not Lease.CanWrite then
      raise ERMS.Create('SecurityException', 'Read-only RecordStore');
    if (Kind <> 1) and not State.Records.ContainsKey(ID) then
      raise ERMS.Create('InvalidRecordIDException', IntToStr(ID));
    if (Kind <> 3) and (Length(Data) > 1024 * 1024) then
      raise ERMS.Create('RecordStoreFullException', 'RMS record size limit');
    if State.Version = High(Int64) then
      raise ERMS.Create('RecordStoreFullException', 'RMS version limit');
    if Kind = 1 then
    begin
      if (State.NextID = MaxInt) or (State.Records.Count >= 65536) then
        raise ERMS.Create('RecordStoreFullException', 'RMS record count/id limit');
      ID := State.NextID;
      Inc(State.NextID);
      State.Records.Add(ID, Copy(Data));
    end
    else if Kind = 2 then
      State.Records[ID] := Copy(Data)
    else if Kind = 3 then
      State.Records.Remove(ID)
    else
      raise ERMS.Create('RecordStoreException', 'RMS mutation kind');
    Inc(State.Version);
    State.Modified := Now;
    Commit(State);
    var Change: TRMSChange;
    Change.Kind := Kind;
    Change.ID := ID;
    Gate.Acquire;
    try
      for var Other in Leases do
        if (Other <> Lease) and Other.FNotifications and SameFileName(Other.FileName, Lease.FileName) then
          Other.FPending.Enqueue(Change);
    finally
      Gate.Release;
    end;
    Result := ID;
  finally
    State.Free;
    Leave(Lock);
  end;
end;

procedure TRMSDatabase.SetMode(Lease: TRMSLease; AuthMode: Integer; Writable: Boolean; Now: Int64);
var
  State: TRMSSnapshot;
  Lock: TObject;
begin
  Lock := Enter;
  State := nil;
  try
    if not Lease.Owner then
      raise ERMS.Create('SecurityException', 'Only the RecordStore owner can change its mode');
    if not (AuthMode in [0, 1]) then
      raise ERMS.Create('IllegalArgumentException', 'RecordStore auth mode');
    State := Load(Lease);
    State.Shared := AuthMode = 1;
    State.Writable := Writable;
    State.Modified := Now;
    Commit(State);
  finally
    State.Free;
    Leave(Lock);
  end;
end;

procedure TRMSDatabase.Delete(const Name: string);
begin
  if (Length(Name) < 1) or (Length(Name) > 32) then
    raise ERMS.Create('IllegalArgumentException', 'RecordStore name');
  var Lock := Enter;
  try
    var FileName := StoreFile(FVendor, FSuite, Name);
    if not FStorage.Exists(FileName) then
      raise ERMS.Create('RecordStoreNotFoundException', Name);
    var LeaseLock := TRMSFileLock.Create(FileName + '.open', True, 0);
    try
      FStorage.Delete(FileName);
    finally
      LeaseLock.Free;
    end;
    FStorage.Delete(FileName + '.open');
  finally
    Leave(Lock);
  end;
end;

function TRMSDatabase.Names: TArray<string>;
begin
  Result := nil;
  var Lock := Enter;
  try
    var Folder := SuiteFolder(FVendor, FSuite);
    if not FStorage.FolderExists(Folder) then
      Exit;
    for var FileName in FStorage.Files(Folder) do
      if LowerCase(ExtractFileExt(FileName)) = '.rms' then
      begin
        var State := TRMSSnapshot.Decode(FStorage.ReadBytes(FileName));
        try
          if (State.Vendor <> FVendor) or (State.Suite <> FSuite) or not SameFileName(FileName, StoreFile(FVendor, FSuite, State.Name)) then
            raise ERMS.Create('RecordStoreException', 'RMS directory identity mismatch');
          var N := Length(Result);
          SetLength(Result, N + 1);
          Result[N] := State.Name;
        finally
          State.Free;
        end;
      end;
  finally
    Leave(Lock);
  end;
end;

function TRMSDatabase.Available(Lease: TRMSLease): Integer;
begin
  var Lock := Enter;
  try
    var Input := FStorage.OpenRead(Lease.FileName);
    var Size: Int64;
    try
      Size := Input.Size;
    finally
      Input.Free;
    end;
    Result := Integer(Max(Int64(0), Min(Int64(MaxStoreBytes) - Size, Int64(MaxSuiteBytes) - SuiteBytes(Lease.Vendor, Lease.Suite))));
  finally
    Leave(Lock);
  end;
end;

procedure TRMSLease.TransferState(S: TJVMStateIO);
begin
  Gate.Acquire;
  try
    S.Text(Vendor);
    S.Text(Suite);
    S.Text(Name);
    S.Bool(Owner);
    S.Bool(CanWrite);
    S.Bool(FNotifications);
    if FPending = nil then
      FPending := TQueue<TRMSChange>.Create;
    var Changes := FPending.ToArray;
    var N: Integer := Length(Changes);
    S.Count(N, 65536);
    if S.Loading then
    begin
      FPending.Clear;
      SetLength(Changes, N);
    end;
    for var I := 0 to N - 1 do
    begin
      S.Int(Changes[I].Kind);
      S.Int(Changes[I].ID);
      if S.Loading then
        FPending.Enqueue(Changes[I]);
    end;
  finally
    Gate.Release;
  end;
end;

function TRMSDatabase.CaptureStateStores: TDictionary<string, TBytes>;
begin
  Result := TDictionary<string, TBytes>.Create;
  try
    var Lock := Enter;
    try
      var Folder := SuiteFolder(FVendor, FSuite);
      if FStorage.FolderExists(Folder) then
        for var FileName in FStorage.Files(Folder) do
          if SameText(ExtractFileExt(FileName), '.rms') then
          begin
            var Data := FStorage.ReadBytes(FileName);
            var State := TRMSSnapshot.Decode(Data);
            try
              if (State.Vendor <> FVendor) or (State.Suite <> FSuite) or not SameFileName(FileName, StoreFile(FVendor, FSuite, State.Name)) then
                raise EReadError.Create('Invalid snapshot RMS identity');
              Result.Add(State.Name, Data);
            finally
              State.Free;
            end;
          end;
    finally
      Leave(Lock);
    end;
  except
    Result.Free;
    raise;
  end;
end;

procedure TRMSDatabase.ReplaceStateStores(Stores: TDictionary<string, TBytes>);
begin
  var Lock := Enter;
  try
    EnsureFolder(SuiteFolder(FVendor, FSuite));
    for var Pair in Stores do
    begin
      var Input := TBytesStream.Create(Pair.Value);
      try
        FStorage.WriteAtomic(StoreFile(FVendor, FSuite, Pair.Key), Input);
      finally
        Input.Free;
      end;
    end;
    for var FileName in FStorage.Files(SuiteFolder(FVendor, FSuite)) do
      if SameText(ExtractFileExt(FileName), '.rms') then
      begin
        var State := TRMSSnapshot.Decode(FStorage.ReadBytes(FileName));
        try
          if (State.Vendor <> FVendor) or (State.Suite <> FSuite) then
            raise EReadError.Create('Invalid snapshot RMS identity');
          if not Stores.ContainsKey(State.Name) then
            FStorage.Delete(FileName);
        finally
          State.Free;
        end;
      end;
  finally
    Leave(Lock);
  end;
end;

procedure TRMSDatabase.AttachStateLease(Lease: TRMSLease);
begin
  if (Lease.Vendor <> FVendor) or (Lease.Suite <> FSuite) or not Lease.Owner then
    raise EReadError.Create('Java ME snapshots do not support shared foreign record stores');
  Lease.FileName := StoreFile(Lease.Vendor, Lease.Suite, Lease.Name);
  var State := Read(Lease);
  State.Free;
  Lease.FLock := TRMSFileLock.Create(Lease.FileName + '.open', False, 0);
  Gate.Acquire;
  try
    Leases.Add(Lease);
  finally
    Gate.Release;
  end;
end;

initialization
  Gate := TCriticalSection.Create;
  DataGate := TCriticalSection.Create;
  Leases := TList<TRMSLease>.Create;

finalization
  Leases.Free;
  DataGate.Free;
  Gate.Free;

end.

