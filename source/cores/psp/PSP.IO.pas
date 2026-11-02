unit PSP.IO;

// IoFileMgrForUser. Devices: the UMD (disc0:, umd0:, umd1:, isofs0:), host
// folders (ms0:/fatms0: memory stick, flash0:, host0:) and the emulator
// device used by test programs. Async operations finish after a latency on the
// master clock and notify their callback.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

{$RTTI EXPLICIT FIELDS([vcPrivate, vcProtected, vcPublic, vcPublished]) METHODS([vcPrivate, vcProtected, vcPublic,
  vcPublished]) PROPERTIES([vcPublic, vcPublished])}

uses
  System.SysUtils, System.Classes, System.Generics.Collections, System.IOUtils,
  PSP.Types, PSP.Memory, PSP.CPU, PSP.HLE, PSP.Kernel, PSP.Media,
  PSP.State.Action;

type
  TPSPIoDriver = record
    Arg, Funcs, GP: Cardinal;
  end;

  TPSPDeviceKind = (dkNone, dkUMD, dkHost, dkEmulator, dkTTY, dkMsStor);
  TPSPFatName = record
    LongName, ShortName: string;
  end;

  TPSPOpenFile = class
  public
    Id: Integer;
    Path: string;
    Kind: TPSPDeviceKind;
    Stream: TStream;
    // UMD files: byte range on the disc; raw opens address sectors.
    DiscStart, DiscSize, Position: Int64;
    RawSectors: Boolean;
    Flags: Cardinal;
    GuestArg, GuestFuncs, GuestGP: Cardinal;
    IsDirectory: Boolean;
    Entries: TArray<TPSPDiscEntry>;
    EntryIndex: Integer;
    AsyncPending: Boolean;
    AsyncResult: Int64;
    AsyncDone: Int64;
    AsyncTimer: Int64;
    AsyncCallback: Cardinal;
    AsyncArg: Cardinal;
    AsyncWorker: Cardinal;
    AsyncPriority: Integer;
    AsyncLatency: Int64;
    AsyncTask: IPSPStateAction;
    Waiters: TList<TPSPThread>;
    constructor Create;
    destructor Destroy; override;
  end;

  TPSPOutputEvent = procedure(const Text: RawByteString) of object;
  TPSPScreenshotEvent = procedure of object;
  TPSPHostChangeEvent = procedure(const Name: string; Created, Tree: Boolean) of object;

  TPSPIO = class
  private
    FKernel: TPSPKernel;
    FHLE: TPSPHLE;
    FMemory: TPSPMemory;
    FDisc: TPSPDisc;
    FFiles: TDictionary<Integer, TPSPOpenFile>;
    FDrivers: TDictionary<string, TPSPIoDriver>;
    FFatNames: TDictionary<string, TPSPFatName>;
    FAsyncStub: Cardinal;
    FAsyncPriority: Integer;
    FMemstickInserted: Boolean;
    FMemstickCallbacks: TList<Cardinal>;
    FMemstickRoot, FFlashRoot, FHostRoot: string;
    FCwd: string;
    FOnOutput: TPSPOutputEvent;
    FOnScreenshot: TPSPScreenshotEvent;
    FHasDisplay: Boolean;
    FOnHostChange: TPSPHostChangeEvent;
    function Split(const Path: string; out Device, Rest: string): Boolean;
    function DeviceKind(const Device: string): TPSPDeviceKind;
    function HostRoot(const Device: string): string;
    function Resolve(const Path: string): string;
    function HostPath(const Device, Rest: string): string;
    function MissingMemstick(const Path: string): Boolean;
    function RejectMissingMemstick(const Path: string): Boolean;
    procedure SetMemstickInserted(Value: Boolean);
    function FatName(const Rest, Name: string): string;
    procedure SeedFatDirectory(const Host, Rest: string);
    procedure ForgetFatPath(const Host: string; const Destination: string = '');
    procedure RememberFatPath(const Host: string);
    function AllocFd: Integer;
    function AllocTTYFd: Integer;
    function GetFile(Fd: Cardinal): TPSPOpenFile;
    function DoRead(F: TPSPOpenFile; Address, Size: Cardinal): Int64;
    function DoWrite(F: TPSPOpenFile; Address, Size: Cardinal): Int64;
    function DoSeek(F: TPSPOpenFile; Offset: Int64; Whence: Integer): Int64;
    function OpenPath(const Path: string; Flags, Mode: Cardinal; out F: TPSPOpenFile): Cardinal;
    function StartAsync(F: TPSPOpenFile; const Task: IPSPStateAction; Latency: Int64): Boolean;
    function EnsureAsyncWorker(F: TPSPOpenFile): Boolean;
    procedure StopAsyncWorker(F: TPSPOpenFile);
    procedure CollectAsync(F: TPSPOpenFile; ResultPtr: Cardinal);
    procedure hAsyncWorker;
    procedure StatePerformAsync(Action: TPSPStateAction; Value: Cardinal);
    procedure FinishAsync(F: TPSPOpenFile);
    procedure StateAsyncDone(Action: TPSPStateAction; Value: Cardinal);
    procedure StateDriverDeleted(Action: TPSPStateAction; Value: Cardinal);
    procedure StateDriverOpened(Action: TPSPStateAction; Value: Cardinal);
    procedure StateDriverReturned(Action: TPSPStateAction; Value: Cardinal);
    function AsyncRetry(T: TPSPThread): Boolean;
    procedure AsyncAbort(T: TPSPThread);
    procedure WaitAsync(AllowCB: Boolean);
    procedure WriteStat(Address: Cardinal; IsDir: Boolean; Size: Int64; Time: TDateTime; ReadOnly: Boolean;
      WritePrivate: Boolean = False; LBA: Cardinal = 0);
    procedure DeviceYield(Result: Cardinal; Latency: Int64);
    function OnHostDevice(const Path: string): Boolean;
    function DeviceYieldRetry(T: TPSPThread): Boolean;
    function ReadLatency(F: TPSPOpenFile; Size: Int64): Int64;
    function TransferLatency(F: TPSPOpenFile; Address, Size: Cardinal; Writing: Boolean): Int64;
    function RefuseFileWait(F: TPSPOpenFile): Boolean;
    procedure hAddDrv;
    procedure hDelDrv;
    function OpenGuestDriver(const Path: string; Flags, Mode: Cardinal): Boolean;
    function CallFileDriver(F: TPSPOpenFile; Slot: Integer; const Args: array of Cardinal): Boolean;
    procedure hOpen;
    procedure hOpenAsync;
    procedure hClose;
    procedure hCloseAsync;
    procedure hRead;
    procedure hReadAsync;
    procedure hWrite;
    procedure hWriteAsync;
    procedure hLseek;
    procedure hLseekAsync;
    procedure hLseek32;
    procedure hLseek32Async;
    procedure hIoctl;
    procedure hIoctlAsync;
    procedure hDevctl;
    procedure hGetstat;
    procedure hChstat;
    procedure hDopen;
    procedure hDread;
    procedure hDclose;
    procedure hMkdir;
    procedure hRmdir;
    procedure hRemove;
    procedure hRename;
    procedure hChdir;
    procedure hSync;
    procedure hAssign;
    procedure hUnassign;
    procedure hGetDevType;
    procedure hCancel;
    procedure hWaitAsync;
    procedure hWaitAsyncCB;
    procedure hPollAsync;
    procedure hGetAsyncStat;
    procedure hChangeAsyncPriority;
    procedure hSetAsyncCallback;
    procedure hGetFdList;
    procedure hStdout;
    procedure hStderr;
    procedure hStdin;
    function IoctlCommon(F: TPSPOpenFile; Cmd, InPtr, InLen, OutPtr, OutLen: Cardinal): Cardinal;
  public
    // No emulator: device, as on hardware: test programs then write their
    // output and screenshots to host0: the way they did when recorded.
    NoEmulatorDevice: Boolean;
    constructor Create(Kernel: TPSPKernel);
    destructor Destroy; override;
    procedure Reset;
    procedure Register;
    // Reads a whole file through the devices (module loading, utility).
    function ReadAll(const Path: string; out Data: TBytes): Cardinal;
    // The rest of an open file from its position (sceKernelLoadModuleByID).
    function ReadOpen(Fd: Cardinal; out Data: TBytes; out Path: string): Cardinal;
    function Exists(const Path: string): Boolean;
    function HostFileName(const Path: string): string;
    procedure HostChanged(const Name: string; Created: Boolean = False; Tree: Boolean = False);
    function StateStreamMode(Stream: TStream): Word;
    property Disc: TPSPDisc read FDisc write FDisc;
    property MemstickRoot: string read FMemstickRoot write FMemstickRoot;
    property MemstickInserted: Boolean read FMemstickInserted write SetMemstickInserted;
    property FlashRoot: string read FFlashRoot write FFlashRoot;
    property HostDirectory: string read FHostRoot write FHostRoot;
    property Cwd: string read FCwd write FCwd;
    property HasDisplay: Boolean read FHasDisplay write FHasDisplay;
    property OnOutput: TPSPOutputEvent read FOnOutput write FOnOutput;
    property OnScreenshot: TPSPScreenshotEvent read FOnScreenshot write FOnScreenshot;
    property OnHostChange: TPSPHostChangeEvent read FOnHostChange write FOnHostChange;
  end;

const
  PSP_O_RDONLY = $0001;
  PSP_O_WRONLY = $0002;
  PSP_O_RDWR = $0003;
  PSP_O_NBLOCK = $0004;
  PSP_O_DIROPEN = $0008;
  PSP_O_APPEND = $0100;
  PSP_O_CREAT = $0200;
  PSP_O_TRUNC = $0400;
  PSP_O_EXCL = $0800;

implementation

uses
  System.Math, System.DateUtils, PSP.Scheduler;

{ TPSPOpenFile }

constructor TPSPOpenFile.Create;
begin
  inherited Create;
  Waiters := TList<TPSPThread>.Create;
end;

destructor TPSPOpenFile.Destroy;
begin
  Stream.Free;
  Waiters.Free;
  inherited;
end;

{ TPSPIO }

constructor TPSPIO.Create(Kernel: TPSPKernel);
begin
  inherited Create;
  FKernel := Kernel;
  FHLE := Kernel.HLE;
  FMemory := Kernel.Memory;
  FFiles := TDictionary<Integer, TPSPOpenFile>.Create;
  FDrivers := TDictionary<string, TPSPIoDriver>.Create;
  FFatNames := TDictionary<string, TPSPFatName>.Create;
  FMemstickInserted := True;
  FMemstickCallbacks := TList<Cardinal>.Create;
  FHasDisplay := True;
end;

destructor TPSPIO.Destroy;
begin
  for var F in FFiles.Values do
  begin
    StopAsyncWorker(F);
    F.Free;
  end;
  FFiles.Free;
  FDrivers.Free;
  FFatNames.Free;
  FMemstickCallbacks.Free;
  inherited;
end;

procedure TPSPIO.Reset;
begin
  for var F in FFiles.Values do
  begin
    StopAsyncWorker(F);
    F.Free;
  end;
  FFiles.Clear;
  FDrivers.Clear;
  FFatNames.Clear;
  FMemstickCallbacks.Clear;
  FAsyncStub := 0;
  FAsyncPriority := 0;
  FCwd := '';
end;

function TPSPIO.Split(const Path: string; out Device, Rest: string): Boolean;
begin
  var P := Path.IndexOf(':');
  if P < 0 then
    Exit(False);
  Device := Path.Substring(0, P).ToLower;
  Rest := Path.Substring(P + 1).Replace('\', '/');
  Result := True;
end;

function TPSPIO.DeviceKind(const Device: string): TPSPDeviceKind;
begin
  if (Device = 'disc0') or (Device = 'umd0') or (Device = 'umd1') or (Device = 'umd') or (Device = 'isofs0') or
    (Device = 'isofs') then
    Result := dkUMD
  else if (Device = 'ms0') or (Device = 'fatms0') or (Device = 'ms') or (Device = 'flash0') or (Device = 'flash1') or
    (Device = 'host0') or (Device = 'host') or (Device = 'ef0') or (Device = 'fatms') then
    Result := dkHost
  else if ((Device = 'emulator') or (Device = 'kemulator')) and not NoEmulatorDevice then
    Result := dkEmulator
  else if Device.StartsWith('tty') then
    Result := dkTTY
  else if Device.StartsWith('msstor') or Device.StartsWith('mscmhc') then
    Result := dkMsStor
  else
    Result := dkNone;
end;

function TPSPIO.HostRoot(const Device: string): string;
begin
  if (Device = 'flash0') or (Device = 'flash1') then
    Result := FFlashRoot
  else if (Device = 'host0') or (Device = 'host') then
    Result := FHostRoot
  else
    Result := FMemstickRoot;
end;

function IsMemstick(const Device: string): Boolean;
begin
  Result := (Device = 'ms0') or (Device = 'ms') or (Device = 'fatms0') or (Device = 'fatms');
end;

function TPSPIO.MissingMemstick(const Path: string): Boolean;
begin
  if FMemstickInserted then
    Exit(False);
  var Dev, Rest: string;
  Result := Split(Resolve(Path), Dev, Rest) and IsMemstick(Dev);
end;

function TPSPIO.RejectMissingMemstick(const Path: string): Boolean;
begin
  Result := MissingMemstick(Path);
  if Result then
    FHLE.Result(SCE_KERNEL_ERROR_NODEV);
end;

procedure TPSPIO.SetMemstickInserted(Value: Boolean);
begin
  if FMemstickInserted = Value then
    Exit;
  FMemstickInserted := Value;
  for var Id in FMemstickCallbacks.ToArray do
  begin
    var CB := TPSPCallback(FKernel.GetObject(Id, TPSPCallback));
    if CB <> nil then
      FKernel.NotifyCallback(CB, Ord(Value))
    else
      FMemstickCallbacks.Remove(Id);
  end;
end;

function NormalizeRest(const Rest: string): string;
begin
  var Parts := TList<string>.Create;
  try
    for var Part in Rest.Replace('\', '/').Split(['/'], TStringSplitOptions.ExcludeEmpty) do
    begin
      if Part = '.' then
        Continue;
      if Part = '..' then
      begin
        if Parts.Count > 0 then
          Parts.Delete(Parts.Count - 1);
        Continue;
      end;
      Parts.Add(Part);
    end;
    Result := '/' + string.Join('/', Parts.ToArray);
  finally
    Parts.Free;
  end;
end;

function TPSPIO.Resolve(const Path: string): string;
begin
  if Path.Contains(':') then
    Exit(Path);
  var Base := FCwd;
  if Base = '' then
    Base := 'disc0:/';
  // A path without a device always continues the current directory, even
  // one starting with a slash; only a doubled slash is merged.
  if Base.EndsWith('/') and Path.StartsWith('/') then
    Result := Base + Path.Substring(1)
  else if Base.EndsWith('/') or Base.EndsWith(':') or Path.StartsWith('/') then
    Result := Base + Path
  else
    Result := Base + '/' + Path;
end;

function TPSPIO.HostPath(const Device, Rest: string): string;
begin
  var Root := HostRoot(Device);
  if Root = '' then
    Exit('');
  Result := TPath.Combine(Root, NormalizeRest(Rest).Substring(1).Replace('/', PathDelim));
  if not ((Device = 'ms0') or (Device = 'ms') or (Device = 'fatms0') or (Device = 'fatms') or (Device = 'ef0')) then
    Exit;
  Result := Root;
  var Dir := '';
  for var Part in NormalizeRest(Rest).Split(['/'], TStringSplitOptions.ExcludeEmpty) do
  begin
    SeedFatDirectory(Result, Dir);
    var Item: TPSPFatName;
    var Actual := Part;
    if FFatNames.TryGetValue((Dir + '/' + Part).ToLower, Item) then
      Actual := Item.LongName
    else
      for var Pair in FFatNames do
        if (Pair.Key.Substring(0, Pair.Key.LastIndexOf('/')) = Dir.ToLower) and
          SameText(Pair.Value.ShortName, Part) then
        begin
          Actual := Pair.Value.LongName;
          Break;
        end;
    Result := TPath.Combine(Result, Actual);
    Dir := Dir + '/' + Actual;
  end;
end;

function TPSPIO.FatName(const Rest, Name: string): string;
  function Clean(const S: string): string;
  begin
    Result := '';
    for var C in S.ToUpper do
      if (C <> ' ') and (C <> '.') then
        if CharInSet(C,
          ['A'..'Z', '0'..'9', '$', '%', #39, '-', '_', '@', '~', '`', '!', '(', ')', '{', '}', '^', '#', '&']) then
          Result := Result + C
        else
          Result := Result + '_';
  end;
begin
  if (Name = '.') or (Name = '..') then
    Exit(Name);
  var Key := NormalizeRest(Rest).ToLower;
  var Item: TPSPFatName;
  if FFatNames.TryGetValue(Key, Item) then
    Exit(Item.ShortName);
  var Dot := Name.LastIndexOf('.');
  var Base := Name;
  var Ext := '';
  if Dot >= 0 then
  begin
    Base := Name.Substring(0, Dot);
    Ext := Name.Substring(Dot + 1);
  end;
  if Dot = 0 then
  begin
    Base := Ext;
    Ext := '';
  end;
  var Stem := Clean(Base);
  var Suffix := Clean(Ext);
  Suffix := Suffix.Substring(0, Min(3, Length(Suffix)));
  if Stem = '' then
    Stem := '_';
  var Direct := (Length(Stem) <= 8) and (Length(Ext) <= 3) and (Stem = Base.ToUpper) and
    ((Dot < 0) or (Name = Name.ToUpper));
  var Parent := Key.Substring(0, Key.LastIndexOf('/') + 1);
  var Used := TDictionary<string, Boolean>.Create;
  try
    for var Pair in FFatNames do
      if Pair.Key.Substring(0, Pair.Key.LastIndexOf('/') + 1) = Parent then
        Used.AddOrSetValue(Pair.Value.ShortName, True);
    Result := Stem;
    if Suffix <> '' then
      Result := Result + '.' + Suffix;
    if not Direct or Used.ContainsKey(Result) then
    begin
      var N := 1;
      repeat
        var Tail := '~' + IntToStr(N);
        Result := Stem.Substring(0, Min(Length(Stem), Max(1, 8 - Length(Tail)))) + Tail;
        if Suffix <> '' then
          Result := Result + '.' + Suffix;
        Inc(N);
      until not Used.ContainsKey(Result);
    end;
  finally
    Used.Free;
  end;
  Item.LongName := Name;
  Item.ShortName := Result;
  FFatNames.Add(Key, Item);
end;

procedure TPSPIO.SeedFatDirectory(const Host, Rest: string);
begin
  // A folder mount has no on-disk FAT entries. Seed it once; subsequent guest
  // creations reserve aliases immediately, not in the host's listing order.
  var Key := Rest.ToLower + '/';
  if FFatNames.ContainsKey(Key) or not DirectoryExists(Host) then
    Exit;
  FFatNames.Add(Key, Default(TPSPFatName));
  for var Name in TDirectory.GetFileSystemEntries(Host) do
    FatName(Rest + '/' + ExtractFileName(Name), ExtractFileName(Name));
end;

procedure TPSPIO.RememberFatPath(const Host: string);
begin
  var Root := IncludeTrailingPathDelimiter(FMemstickRoot);
  if (FMemstickRoot = '') or not Host.StartsWith(Root, True) then
    Exit;
  var Rest := '/' + Host.Substring(Root.Length).Replace(PathDelim, '/');
  FatName(Rest, ExtractFileName(Host));
end;

procedure TPSPIO.ForgetFatPath(const Host, Destination: string);
begin
  var Root := IncludeTrailingPathDelimiter(FMemstickRoot);
  if (FMemstickRoot = '') or not Host.StartsWith(Root, True) then
    Exit;
  var Key := '/' + Host.Substring(Root.Length).Replace(PathDelim, '/').ToLower;
  var NewKey := '';
  if Destination <> '' then
    NewKey := '/' + Destination.Substring(Root.Length).Replace(PathDelim, '/').ToLower;
  for var Pair in FFatNames.ToArray do
    if (Pair.Key = Key) or Pair.Key.StartsWith(Key + '/') then
    begin
      FFatNames.Remove(Pair.Key);
      if (NewKey <> '') and (Pair.Key <> Key) then
        FFatNames.AddOrSetValue(NewKey + Pair.Key.Substring(Key.Length), Pair.Value);
    end;
  if Destination <> '' then
    RememberFatPath(Destination);
end;

function TPSPIO.OnHostDevice(const Path: string): Boolean;
begin
  var Dev, Rest: string;
  Result := Split(Resolve(Path), Dev, Rest) and (DeviceKind(Dev) = dkHost);
end;

function HostReadOnly(const Name: string): Boolean;
begin
{$IFDEF MSWINDOWS}
  var A := FileGetAttr(Name);
  Result := (A <> -1) and ((A and faReadOnly) <> 0);
{$ELSE}
  try
    Result := not (TFileAttribute.faOwnerWrite in TFile.GetAttributes(Name));
  except
    Result := False;
  end;
{$ENDIF}
end;

procedure HostSetReadOnly(const Name: string; ReadOnly: Boolean);
begin
{$IFDEF MSWINDOWS}
  var A := FileGetAttr(Name);
  if A = -1 then
    Exit;
  if ReadOnly then
    A := A or faReadOnly
  else
    A := A and not faReadOnly;
  FileSetAttr(Name, A);
{$ELSE}
  try
    var A := TFile.GetAttributes(Name);
    if ReadOnly then
      A := A - [TFileAttribute.faOwnerWrite, TFileAttribute.faGroupWrite, TFileAttribute.faOthersWrite]
    else
      A := A + [TFileAttribute.faOwnerWrite];
    TFile.SetAttributes(Name, A);
  except
  end;
{$ENDIF}
end;

function TPSPIO.HostFileName(const Path: string): string;
begin
  if MissingMemstick(Path) then
    Exit('');
  var Dev, Rest: string;
  if not Split(Resolve(Path), Dev, Rest) or (DeviceKind(Dev) <> dkHost) then
    Exit('');
  Result := HostPath(Dev, Rest);
end;

procedure TPSPIO.HostChanged(const Name: string; Created, Tree: Boolean);
begin
  if Assigned(FOnHostChange) then
    FOnHostChange(Name, Created, Tree);
end;

function TPSPIO.AllocTTYFd: Integer;
begin
  // Descriptors 0..2 are stdio; the first free one after the ttys' own.
  Result := 5;
  while FFiles.ContainsKey(Result) do
    Inc(Result);
end;

function TPSPIO.AllocFd: Integer;
begin
  Result := 3;
  while FFiles.ContainsKey(Result) do
    Inc(Result);
end;

function TPSPIO.GetFile(Fd: Cardinal): TPSPOpenFile;
begin
  if not FFiles.TryGetValue(Integer(Fd), Result) then
    Result := nil;
end;

function ParseLBN(const Rest: string; out LBA, Size: Cardinal): Boolean;
begin
  // /sce_lbn<lba>_size<size>: both hexadecimal, with or without 0x.
  var S := Rest.ToLower;
  var P := S.IndexOf('sce_lbn');
  Result := False;
  if P < 0 then
    Exit;
  S := S.Substring(P + 7);
  var Q := S.IndexOf('_size');
  if Q < 0 then
    Exit;
  var A := S.Substring(0, Q);
  var B := S.Substring(Q + 5);
  if A.StartsWith('0x') then
    A := A.Substring(2);
  if B.StartsWith('0x') then
    B := B.Substring(2);
  var N := 0;
  while (N < B.Length) and CharInSet(B.Chars[N], ['0'..'9', 'a'..'f']) do
    Inc(N);
  B := B.Substring(0, N);
  if (A = '') or (B = '') then
    Exit;
  var LA, LS: Int64;
  Result := TryStrToInt64('$' + A, LA) and TryStrToInt64('$' + B, LS);
  LBA := Cardinal(LA);
  Size := Cardinal(LS);
end;

function TPSPIO.OpenPath(const Path: string; Flags, Mode: Cardinal; out F: TPSPOpenFile): Cardinal;
begin
  F := nil;
  var Dev, Rest: string;
  var Canonical := Resolve(Path);
  if not Split(Canonical, Dev, Rest) then
    Exit(SCE_ERROR_ERRNO_ENOENT);
  if not FMemstickInserted and IsMemstick(Dev) then
    Exit(SCE_KERNEL_ERROR_NODEV);
  case DeviceKind(Dev) of
    dkUMD:
      begin
        if FDisc = nil then
          Exit(SCE_KERNEL_ERROR_NODEV);
        if (Flags and PSP_O_WRONLY) <> 0 then
          Exit(SCE_ERROR_ERRNO_EACCES);
        F := TPSPOpenFile.Create;
        F.Kind := dkUMD;
        F.Path := Canonical;
        var LBA, Size: Cardinal;
        if (Rest = '') or (Rest = '/') then
        begin
          F.RawSectors := True;
          F.DiscStart := 0;
          F.DiscSize := FDisc.Size;
        end
        else if ParseLBN(Rest, LBA, Size) then
        begin
          F.DiscStart := Int64(LBA) * 2048;
          F.DiscSize := Size;
        end
        else
        begin
          var E: TPSPDiscEntry;
          if not FDisc.Entry(Rest, E) or E.Directory then
          begin
            FreeAndNil(F);
            Exit(SCE_ERROR_ERRNO_ENOENT);
          end;
          F.DiscStart := Int64(E.LBA) * 2048;
          F.DiscSize := E.Size;
        end;
      end;
    dkHost:
      begin
        // The FAT driver refuses a wildcard in a name.
        if Pos('?', Rest) > 0 then
          Exit(SCE_ERROR_ERRNO_EINVAL);
        var Name := HostPath(Dev, Rest);
        if Name = '' then
          Exit(SCE_KERNEL_ERROR_NODEV);
        if DirectoryExists(Name) then
          Exit(SCE_ERROR_ERRNO_ENOENT);
        var Exists := FileExists(Name);
        if not Exists and ((Flags and PSP_O_CREAT) = 0) then
          Exit(SCE_ERROR_ERRNO_ENOENT);
        if Exists and ((Flags and PSP_O_CREAT) <> 0) and ((Flags and PSP_O_EXCL) <> 0) then
          Exit(SCE_ERROR_ERRNO_EEXIST);
        if not Exists and not DirectoryExists(ExtractFileDir(Name)) then
          Exit(SCE_ERROR_ERRNO_ENOENT);
        var S: TStream;
        try
          if (Flags and PSP_O_WRONLY) <> 0 then
          begin
            if not Exists or ((Flags and PSP_O_TRUNC) <> 0) then
              S := TFileStream.Create(Name, fmCreate or fmShareDenyNone)
            else
              S := TFileStream.Create(Name, fmOpenReadWrite or fmShareDenyNone);
          end
          else
            S := TFileStream.Create(Name, fmOpenRead or fmShareDenyNone);
        except
          Exit(SCE_ERROR_ERRNO_EACCES);
        end;
        F := TPSPOpenFile.Create;
        F.Kind := dkHost;
        F.Path := Canonical;
        F.Stream := S;
        if not Exists then
          RememberFatPath(Name);
        if ((Flags and PSP_O_WRONLY) <> 0) and (not Exists or ((Flags and PSP_O_TRUNC) <> 0)) then
          HostChanged(Name, not Exists);
        if (Flags and PSP_O_APPEND) <> 0 then
          S.Position := S.Size;
      end;
    dkEmulator, dkTTY, dkMsStor:
      begin
        F := TPSPOpenFile.Create;
        F.Kind := DeviceKind(Dev);
        F.Path := Canonical;
      end;
  else
    Exit(SCE_KERNEL_ERROR_NODEV);
  end;
  F.Flags := Flags;
  Result := 0;
end;

function TPSPIO.ReadAll(const Path: string; out Data: TBytes): Cardinal;
begin
  Data := nil;
  var F: TPSPOpenFile;
  Result := OpenPath(Path, PSP_O_RDONLY, 0, F);
  if Result <> 0 then
    Exit;
  try
    case F.Kind of
      dkUMD:
        begin
          SetLength(Data, F.DiscSize);
          if F.DiscSize > 0 then
            FDisc.ReadAt(F.DiscStart, Data[0], F.DiscSize);
        end;
      dkHost:
        begin
          SetLength(Data, F.Stream.Size);
          if Length(Data) > 0 then
            F.Stream.ReadBuffer(Data[0], Length(Data));
        end;
    end;
  finally
    F.Free;
  end;
end;

function TPSPIO.ReadOpen(Fd: Cardinal; out Data: TBytes; out Path: string): Cardinal;
begin
  Data := nil;
  Path := '';
  var F := GetFile(Fd);
  if (F = nil) or F.IsDirectory then
    Exit(SCE_KERNEL_ERROR_BADF);
  if MissingMemstick(F.Path) then
    Exit(SCE_KERNEL_ERROR_NODEV);
  Path := F.Path;
  case F.Kind of
    dkUMD:
      begin
        var Start := F.Position;
        if F.RawSectors then
          Start := Start * 2048;
        var N := F.DiscSize - Start;
        if N < 0 then
          N := 0;
        SetLength(Data, N);
        if N > 0 then
          FDisc.ReadAt(F.DiscStart + Start, Data[0], N);
      end;
    dkHost:
      begin
        var N := F.Stream.Size - F.Stream.Position;
        SetLength(Data, N);
        if N > 0 then
          F.Stream.ReadBuffer(Data[0], N);
      end;
  else
    Exit(SCE_KERNEL_ERROR_BADF);
  end;
  Result := 0;
end;

function TPSPIO.Exists(const Path: string): Boolean;
begin
  var F: TPSPOpenFile;
  Result := OpenPath(Path, PSP_O_RDONLY, 0, F) = 0;
  F.Free;
end;

function TPSPIO.DoRead(F: TPSPOpenFile; Address, Size: Cardinal): Int64;
begin
  if MissingMemstick(F.Path) then
    Exit(Int64(Integer(SCE_KERNEL_ERROR_NODEV)));
  if (F.Flags and PSP_O_RDONLY) = 0 then
    Exit(Int64(Integer(SCE_KERNEL_ERROR_BADF)));
  case F.Kind of
    dkUMD:
      begin
        var Pos := F.Position;
        var Avail: Int64;
        if F.RawSectors then
        begin
          // Raw UMD access counts in sectors.
          var Bytes := Int64(Size) * 2048;
          var Start := Pos * 2048;
          Avail := Min(Bytes, F.DiscSize - Start);
          if Avail <= 0 then
            Exit(0);
          var P := FMemory.Ptr(Address, Avail);
          if P = nil then
            Exit(Int64(Integer(SCE_KERNEL_ERROR_ILLEGAL_ADDR)));
          FDisc.ReadAt(Start, P^, Avail);
          FMemory.Touched(Address, Avail);
          F.Position := Pos + (Avail + 2047) div 2048;
          Exit(Avail div 2048);
        end;
        Avail := Min(Int64(Size), F.DiscSize - Pos);
        if Avail <= 0 then
          Exit(0);
        var P := FMemory.Ptr(Address, Avail);
        if P = nil then
          Exit(Int64(Integer(SCE_KERNEL_ERROR_ILLEGAL_ADDR)));
        FDisc.ReadAt(F.DiscStart + Pos, P^, Avail);
        FMemory.Touched(Address, Avail);
        F.Position := Pos + Avail;
        Result := Avail;
      end;
    dkHost:
      begin
        if Size = 0 then
          Exit(0);
        var P := FMemory.Ptr(Address, Size);
        if P = nil then
          Exit(Int64(Integer(SCE_KERNEL_ERROR_ILLEGAL_ADDR)));
        Result := F.Stream.Read(P^, Size);
        FMemory.Touched(Address, Result);
      end;
  else
    Result := 0;
  end;
end;

function TPSPIO.DoWrite(F: TPSPOpenFile; Address, Size: Cardinal): Int64;
begin
  if MissingMemstick(F.Path) then
    Exit(Int64(Integer(SCE_KERNEL_ERROR_NODEV)));
  case F.Kind of
    dkHost:
      begin
        if (F.Flags and PSP_O_WRONLY) = 0 then
          Exit(Int64(Integer(SCE_KERNEL_ERROR_BADF)));
        if Size = 0 then
          Exit(0);
        if not FMemory.Valid(Address, Size) then
          Exit(Int64(Integer(SCE_KERNEL_ERROR_ILLEGAL_ADDR)));
        var Buf: TBytes;
        SetLength(Buf, Size);
        FMemory.ReadBytes(Address, Buf[0], Size);
        if (F.Flags and PSP_O_APPEND) <> 0 then
          F.Stream.Position := F.Stream.Size;
        Result := F.Stream.Write(Buf[0], Size);
        HostChanged(HostFileName(F.Path));
      end;
    dkEmulator:
      begin
        if Assigned(FOnOutput) then
          FOnOutput(FMemory.ReadAnsi(Address, Size));
        Result := Size;
      end;
    dkTTY:
      begin
        // Explicit tty opens address the debug terminal, not stdio's pipes.
        // Descriptors 1/2 still use hWrite's stdout/stderr path.
        FHLE.Log('tty %s: %s', [F.Path, string(FMemory.ReadAnsi(Address, Size))]);
        Result := Size;
      end;
  else
    Result := Int64(Integer(SCE_KERNEL_ERROR_BADF));
  end;
end;

function TPSPIO.DoSeek(F: TPSPOpenFile; Offset: Int64; Whence: Integer): Int64;
begin
  if MissingMemstick(F.Path) then
    Exit(Int64(Integer(SCE_KERNEL_ERROR_NODEV)));
  case F.Kind of
    dkUMD:
      begin
        var Size := F.DiscSize;
        if F.RawSectors then
          Size := F.DiscSize div 2048;
        var NewPos: Int64;
        case Whence of
          0:
            NewPos := Offset;
          1:
            NewPos := F.Position + Offset;
          2:
            NewPos := Size + Offset;
        else
          Exit(Int64(Integer(SCE_KERNEL_ERROR_INVAL)));
        end;
        if NewPos < 0 then
          Exit(Int64(Integer(SCE_ERROR_ERRNO_EINVAL)));
        F.Position := NewPos;
        Result := NewPos;
      end;
    dkHost:
      begin
        var Origin: TSeekOrigin;
        case Whence of
          0:
            Origin := soBeginning;
          1:
            Origin := soCurrent;
          2:
            Origin := soEnd;
        else
          Exit(Int64(Integer(SCE_KERNEL_ERROR_INVAL)));
        end;
        var Target: Int64;
        case Whence of
          0:
            Target := Offset;
          1:
            Target := F.Stream.Position + Offset;
        else
          Target := F.Stream.Size + Offset;
        end;
        if Target < 0 then
          Exit(Int64(Integer(SCE_ERROR_ERRNO_EINVAL)));
        Result := F.Stream.Seek(Offset, Origin);
      end;
  else
    Result := 0;
  end;
end;

function TPSPIO.ReadLatency(F: TPSPOpenFile; Size: Int64): Int64;
begin
  // ns: a seek-ish setup plus transfer at the UMD's rate; the memory stick is faster.
  if F.Kind = dkUMD then
    Result := 100000 + Size * 1000000000 div (4 * 1024 * 1024)
  else
    Result := 50000 + Size * 1000000000 div (8 * 1024 * 1024);
end;

function TPSPIO.TransferLatency(F: TPSPOpenFile; Address, Size: Cardinal; Writing: Boolean): Int64;
begin
  var Bytes := Int64(Size);
  if not Writing and (F.Kind = dkUMD) then
  begin
    var Position := F.Position;
    if F.RawSectors then
    begin
      Bytes := Bytes * 2048;
      Position := Position * 2048;
    end;
    Bytes := Max(Int64(0), Min(Bytes, F.DiscSize - Position));
    if (Bytes > High(Cardinal)) or not FMemory.Valid(Address, Cardinal(Bytes)) then
      Bytes := 0;
  end
  else if not FMemory.Valid(Address, Size) then
    Bytes := 0
  else if not Writing and (F.Stream <> nil) then
    Bytes := Max(Int64(0), Min(Bytes, F.Stream.Size - F.Stream.Position));
  if (Writing and ((F.Flags and PSP_O_WRONLY) = 0)) or (not Writing and ((F.Flags and PSP_O_RDONLY) = 0)) then
    Bytes := 0;
  Result := ReadLatency(F, Bytes);
end;

function TPSPIO.RefuseFileWait(F: TPSPOpenFile): Boolean;
begin
  Result := (F.Kind in [dkHost, dkUMD]) and FKernel.RefuseWait;
  if Result and not FKernel.InInterrupt then
  begin
    var Dev, Rest: string;
    // USB host-file calls report the host bridge's failure, whereas the FAT
    // and UMD drivers retain the kernel's cannot-wait error.
    if Split(F.Path, Dev, Rest) and ((Dev = 'host0') or (Dev = 'host')) then
      FHLE.Result($FFFFFFFF);
  end;
end;

function TPSPIO.EnsureAsyncWorker(F: TPSPOpenFile): Boolean;
begin
  Result := False;
  if F.AsyncWorker <> 0 then
  begin
    var Existing := FKernel.ThreadById(F.AsyncWorker);
    if (Existing <> nil) and not Existing.IsDormant then
      Exit(True);
    if Existing <> nil then
      FKernel.DeleteThread(Existing);
    F.AsyncWorker := 0;
  end;
  if FKernel.Current = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_CONTEXT);
    Exit;
  end;
  if FAsyncStub = 0 then
  begin
    FAsyncStub := FKernel.AllocKernel(16, 'async IO stub');
    if FAsyncStub = 0 then
    begin
      FHLE.Result(SCE_KERNEL_ERROR_NO_MEMORY);
      Exit;
    end;
    FHLE.Register('PSPInternalIO', 1, 'async IO worker', hAsyncWorker);
    var Index := FHLE.Find('PSPInternalIO', 1);
    FMemory.Write32(FAsyncStub, (Cardinal(Index) shl 6) or $0C);
    FMemory.Write32(FAsyncStub + 4, (2 shl 26) or ((FAsyncStub shr 2) and $03FFFFFF));
    FMemory.Write32(FAsyncStub + 8, 0);
  end;
  var Priority := F.AsyncPriority;
  if Priority = 0 then
    Priority := FAsyncPriority;
  if Priority = 0 then
    Priority := FKernel.Current.Priority;
  // Firmware thread metadata (not its implementation): a 2-KiB system worker
  // retains whether the creating thread originated in user mode.
  var Attr: Cardinal := $00100000;
  if not FKernel.Current.IsKernel then
    Attr := $08100000;
  var T := FKernel.CreateThread('SceIofileAsync', FAsyncStub, Priority, $800, Attr, 0);
  if T = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_NO_MEMORY);
    Exit;
  end;
  F.AsyncWorker := T.UID;
  FKernel.StartThread(T, 0, 0);
  // Like creating a thread through ThreadMan, creating the asynchronous worker
  // re-enables dispatch, but does not turn CPU interrupts back on.
  FKernel.EnableDispatch;
  Result := True;
end;

procedure TPSPIO.StopAsyncWorker(F: TPSPOpenFile);
begin
  if F.AsyncWorker = 0 then
    Exit;
  var T := FKernel.ThreadById(F.AsyncWorker);
  F.AsyncWorker := 0;
  FKernel.CancelTimersOf(F);
  if T <> nil then
  begin
    FKernel.TerminateThread(T, 0);
    FKernel.DeleteThread(T);
  end;
end;

// A descriptor takes one asynchronous request at a time: the next is refused
// until the last one's result has been collected, not merely completed.
function AsyncSlotHeld(F: TPSPOpenFile): Boolean;
begin
  Result := F.AsyncPending or (F.AsyncDone <> 0);
end;

function TPSPIO.StartAsync(F: TPSPOpenFile; const Task: IPSPStateAction; Latency: Int64): Boolean;
begin
  Result := EnsureAsyncWorker(F);
  if not Result then
    Exit;
  F.AsyncPending := True;
  F.AsyncTask := Task;
  F.AsyncDone := 0;
  F.AsyncLatency := Latency;
  F.AsyncTimer := 0;
  var T := FKernel.ThreadById(F.AsyncWorker);
  if T.IsWaiting and (T.Wait.HLETag = 'ioasync') then
    FKernel.EndWait(T, 0);
end;

procedure TPSPIO.hAsyncWorker;
begin
  var T := FKernel.Current;
  var F: TPSPOpenFile := nil;
  for var Entry in FFiles.Values do
    if Entry.AsyncWorker = T.UID then
    begin
      F := Entry;
      Break;
    end;
  if F = nil then
  begin
    FKernel.ExitCurrent(0);
    FKernel.DeleteThread(T);
    Exit;
  end;
  if F.AsyncPending and (F.AsyncDone = 0) then
  begin
    F.AsyncDone := FKernel.Scheduler.Now + F.AsyncLatency;
    FKernel.BeginWait(PSPWaitEventFlag, nil, 0, 0, False, nil, nil, 'ioasyncdelay');
    F.AsyncTimer := FKernel.AddStateTimer(F.AsyncDone, F, TPSPStateAction.Create(StateAsyncDone, [F], []));
    Exit;
  end;
  var Task := F.AsyncTask;
  F.AsyncTask := nil;
  if F.AsyncPending and (Task <> nil) then
    Task.Run;
  FKernel.BeginWait(PSPWaitEventFlag, nil, 0, 0, False, nil, nil, 'ioasync');
  if F.AsyncPending then
    FinishAsync(F);
end;

procedure TPSPIO.StatePerformAsync(Action: TPSPStateAction; Value: Cardinal);
begin
  var F := TPSPOpenFile(Action.Obj(0));
  case Action.Arg(0) of
    0:
      begin
        var Opened: TPSPOpenFile;
        var Err := OpenPath(Action.Text, Cardinal(Action.Arg(1)), Cardinal(Action.Arg(2)), Opened);
        F.AsyncResult := Integer(Err);
        if Err = 0 then
          try
            F.Kind := Opened.Kind;
            F.Path := Opened.Path;
            F.Flags := Opened.Flags;
            F.DiscStart := Opened.DiscStart;
            F.DiscSize := Opened.DiscSize;
            F.Position := Opened.Position;
            F.RawSectors := Opened.RawSectors;
            F.Stream := Opened.Stream;
            Opened.Stream := nil;
            F.AsyncResult := F.Id;
          finally
            Opened.Free;
          end;
      end;
    1:
      begin
        FreeAndNil(F.Stream);
        F.Kind := dkNone;
        F.Flags := 0;
        F.AsyncResult := 0;
      end;
    2:
      F.AsyncResult := DoRead(F, Cardinal(Action.Arg(1)), Cardinal(Action.Arg(2)));
    3:
      F.AsyncResult := DoWrite(F, Cardinal(Action.Arg(1)), Cardinal(Action.Arg(2)));
    4:
      F.AsyncResult := DoSeek(F, Action.Arg(1), Integer(Action.Arg(2)));
    5:
      F.AsyncResult := Integer(IoctlCommon(F, Cardinal(Action.Arg(1)), Cardinal(Action.Arg(2)), Cardinal(Action.Arg(3)),
        Cardinal(Action.Arg(4)), Cardinal(Action.Arg(5))));
  else
    raise EReadError.Create('Invalid asynchronous IO operation');
  end;
end;

procedure TPSPIO.StateAsyncDone(Action: TPSPStateAction; Value: Cardinal);
begin
  var F := TPSPOpenFile(Action.Obj(0));
  if F.AsyncWorker = 0 then
  begin
    FinishAsync(F);
    Exit;
  end; // Earlier direct states.
  F.AsyncTimer := 0;
  var T := FKernel.ThreadById(F.AsyncWorker);
  if (T <> nil) and T.IsWaiting and (T.Wait.HLETag = 'ioasyncdelay') then
    FKernel.EndWait(T, 0);
end;

function TPSPIO.StateStreamMode(Stream: TStream): Word;
begin
  for var F in FFiles.Values do
    if F.Stream = Stream then
    begin
      if (F.Flags and PSP_O_WRONLY) <> 0 then
        Exit(fmOpenReadWrite)
      else
        Exit(fmOpenRead);
    end;
  raise EInvalidOpException.Create('PSP state stream is not owned by an open file');
end;

procedure TPSPIO.FinishAsync(F: TPSPOpenFile);
begin
  F.AsyncPending := False;
  var Collected := False;
  while F.Waiters.Count > 0 do
  begin
    var T := F.Waiters[0];
    F.Waiters.Delete(0);
    if T.IsWaiting and (T.Wait.Obj = nil) and (T.Wait.HLETag = 'io') then
    begin
      if T.Wait.Data[1] <> 0 then
      begin
        FMemory.Write32(T.Wait.Data[1], Cardinal(F.AsyncResult));
        FMemory.Write32(T.Wait.Data[1] + 4, Cardinal(UInt64(F.AsyncResult) shr 32));
      end;
      FKernel.EndWait(T, 0);
      Collected := True;
    end;
  end;
  if Collected then
    F.AsyncDone := 0;
  if F.AsyncCallback <> 0 then
  begin
    var CB := TPSPCallback(FKernel.GetObject(F.AsyncCallback, TPSPCallback));
    if CB <> nil then
      FKernel.NotifyCallback(CB, F.AsyncArg);
  end;
  if Collected and (F.Kind = dkNone) and (F.Flags = 0) then
  begin
    FFiles.Remove(F.Id);
    StopAsyncWorker(F);
    F.Free;
  end;
end;

procedure TPSPIO.CollectAsync(F: TPSPOpenFile; ResultPtr: Cardinal);
begin
  if ResultPtr <> 0 then
  begin
    FMemory.Write32(ResultPtr, Cardinal(F.AsyncResult));
    FMemory.Write32(ResultPtr + 4, Cardinal(UInt64(F.AsyncResult) shr 32));
  end;
  F.AsyncDone := 0;
  if (F.Kind = dkNone) and (F.Flags = 0) then
  begin
    FFiles.Remove(F.Id);
    StopAsyncWorker(F);
    F.Free;
  end;
end;

function TPSPIO.AsyncRetry(T: TPSPThread): Boolean;
begin
  var F := GetFile(T.Wait.Data[0]);
  Result := (F = nil) or not F.AsyncPending;
  if Result then
  begin
    if F = nil then
      T.SetResult(SCE_KERNEL_ERROR_BADF)
    else
    begin
      CollectAsync(F, T.Wait.Data[1]);
      T.SetResult(0);
    end;
  end
  else if not F.Waiters.Contains(T) then
    F.Waiters.Add(T);
end;

procedure TPSPIO.AsyncAbort(T: TPSPThread);
begin
  for var F in FFiles.Values do
    F.Waiters.Remove(T);
end;

procedure TPSPIO.WaitAsync(AllowCB: Boolean);
begin
  var F := GetFile(FHLE.Arg(0));
  var ResPtr := FHLE.Arg(1);
  if F = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_BADF);
    Exit;
  end;
  if FKernel.InInterrupt then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_CONTEXT);
    Exit;
  end;
  if not AllowCB and FKernel.RefuseWait then
    Exit;
  if not F.AsyncPending and (F.AsyncDone = 0) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_NOASYNC);
    Exit;
  end;
  FHLE.Result(0);
  if not F.AsyncPending then
  begin
    CollectAsync(F, ResPtr);
    if AllowCB then
      FKernel.CheckCallbacks;
    Exit;
  end;
  if not FKernel.CanWait then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_CAN_NOT_WAIT);
    Exit;
  end;
  F.Waiters.Add(FKernel.Current);
  FKernel.BeginWait(PSPWaitEventFlag, nil, Cardinal(F.Id), 0, AllowCB, AsyncRetry, AsyncAbort, 'io');
  var T := FKernel.Current;
  if (T <> nil) and (T.Wait.HLETag = 'io') then
  begin
    T.Wait.Data[0] := Cardinal(F.Id);
    T.Wait.Data[1] := ResPtr;
  end
  else if (T <> nil) and (T.Frames.Count > 0) then
  begin
    var Fr := T.Frames.Last;
    Fr.SavedWait.Data[0] := Cardinal(F.Id);
    Fr.SavedWait.Data[1] := ResPtr;
    T.Frames[T.Frames.Count - 1] := Fr;
  end;
end;

procedure TPSPIO.WriteStat(Address: Cardinal; IsDir: Boolean; Size: Int64; Time: TDateTime; ReadOnly: Boolean;
  WritePrivate: Boolean; LBA: Cardinal);
begin
  var Buf: array[0..$57] of Byte;
  FillChar(Buf, SizeOf(Buf), 0);
  var Mode: Cardinal := $01FF;
  var Attr: Cardinal := 0;
  if ReadOnly then
  begin
    Mode := $016D;
    Attr := $01;
  end;
  if IsDir then
  begin
    Mode := Mode or $1000;
    Attr := Attr or $10;
  end
  else
  begin
    Mode := Mode or $2000;
    Attr := Attr or $20;
  end;
  PCardinal(@Buf[0])^ := Mode;
  PCardinal(@Buf[4])^ := Attr;
  PInt64(@Buf[8])^ := Size;
  if Time <> 0 then
    for var K := 0 to 2 do
    begin
      var O := 16 + K * 16;
      var Y, Mo, D, H, Mi, S, Ms: Word;
      DecodeDateTime(Time, Y, Mo, D, H, Mi, S, Ms);
      PWord(@Buf[O])^ := Y;
      PWord(@Buf[O + 2])^ := Mo;
      PWord(@Buf[O + 4])^ := D;
      PWord(@Buf[O + 6])^ := H;
      PWord(@Buf[O + 8])^ := Mi;
      PWord(@Buf[O + 10])^ := S;
      PCardinal(@Buf[O + 12])^ := Cardinal(Ms) * 1000;
    end;
  PCardinal(@Buf[64])^ := LBA;
  if WritePrivate then
    FMemory.WriteBytes(Address, Buf, SizeOf(Buf))
  else
    FMemory.WriteBytes(Address, Buf, 64);
end;

procedure TPSPIO.DeviceYield(Result: Cardinal; Latency: Int64);
begin
  // The memory stick driver serves requests on its own thread: the caller
  // gives up the CPU while it does.
  FHLE.Result(Result);
  if not FKernel.CanWait then
    Exit;
  var T := FKernel.Current;
  FKernel.BeginWait(PSPWaitEventFlag, nil, 0, 0, False, DeviceYieldRetry, nil, 'iodev');
  if T.Wait.HLETag <> 'iodev' then
    Exit;
  T.Wait.Data[0] := Result;
  FKernel.AddWakeTimer(FKernel.Scheduler.Now + Latency, T, 'iodev', Result, 0);
end;

function TPSPIO.DeviceYieldRetry(T: TPSPThread): Boolean;
begin
  Result := False;
end;

{ HLE }

{ PSP.IO: guest file drivers (IoFileMgrForKernel). }

procedure TPSPIO.hAddDrv;
begin
  if FKernel.InInterrupt then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_CONTEXT);
    Exit;
  end;
  var Table := FHLE.Arg(0);
  var Name := FMemory.ReadString(FMemory.Read32(Table), 32).ToLower;
  if (Name = '') or FDrivers.ContainsKey(Name) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ARGUMENT);
    Exit;
  end;
  var Arg := FKernel.AllocKernel(8, 'io driver:' + Name);
  if Arg = 0 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_NO_MEMORY);
    Exit;
  end;
  var D := Default(TPSPIoDriver);
  D.Arg := Arg;
  D.Funcs := FMemory.Read32(Table + 16);
  D.GP := FHLE.CPU.Ctx.GPR[28];
  FMemory.Write32(Arg, Table);
  FMemory.Write32(Arg + 4, 0);
  FDrivers.Add(Name, D);
  FHLE.Result(0);
  var Init := FMemory.Read32(D.Funcs);
  if Init <> 0 then
    // Even an init returning -1 leaves the driver installed (io/iodrv).
    FKernel.CallGuest(Init, [Arg], nil, D.GP);
end;

procedure TPSPIO.hDelDrv;
begin
  if FKernel.InInterrupt then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_CONTEXT);
    Exit;
  end;
  var Name := FMemory.ReadString(FHLE.Arg(0), 32).ToLower;
  var D: TPSPIoDriver;
  if not FDrivers.TryGetValue(Name, D) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_NODEV);
    Exit;
  end;
  for var F in FFiles.Values do
    if (F.GuestArg <> 0) and (FMemory.Read32(F.GuestArg + 8) = D.Arg) then
    begin
      FHLE.Result(SCE_KERNEL_ERROR_ASYNC_BUSY);
      Exit;
    end;
  FDrivers.Remove(Name);
  var K := FKernel;
  var ExitFunc := FMemory.Read32(D.Funcs + 4);
  FHLE.Result(0);
  if ExitFunc <> 0 then
    K.CallGuest(ExitFunc, [D.Arg], nil, D.GP, TPSPStateAction.Create(StateDriverDeleted, [], [D.Arg]))
  else
    K.KernelPartition.FreeBlock(D.Arg);
end;

procedure TPSPIO.StateDriverDeleted(Action: TPSPStateAction; Value: Cardinal);
begin
  FKernel.KernelPartition.FreeBlock(Cardinal(Action.Arg(0)));
end;

function TPSPIO.OpenGuestDriver(const Path: string; Flags, Mode: Cardinal): Boolean;
begin
  Result := False;
  if FDrivers.Count = 0 then
    Exit;
  var Device, Rest: string;
  if not Split(Resolve(Path), Device, Rest) then
    Exit;
  var Number: Cardinal := 0;
  var P := Length(Device);
  while (P > 0) and CharInSet(Device[P], ['0'..'9']) do
    Dec(P);
  if P < Length(Device) then
  begin
    Number := Cardinal(StrToIntDef(Device.Substring(P), 0));
    Device := Device.Substring(0, P);
  end;
  var D: TPSPIoDriver;
  if not FDrivers.TryGetValue(Device, D) then
    Exit;
  Result := True;
  if FKernel.RefuseWait then
    Exit;
  var OpenFunc := FMemory.Read32(D.Funcs + 8);
  if OpenFunc = 0 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNSUP);
    Exit;
  end;
  var FileName := RawByteString(Rest.TrimStart(['/']));
  var Arg := FKernel.AllocKernel($20 + Cardinal(Length(FileName)) + 1, 'io file:' + Device);
  if Arg = 0 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_NO_MEMORY);
    Exit;
  end;
  FMemory.Fill(Arg, 0, $20);
  FMemory.Write32(Arg, Flags);
  FMemory.Write32(Arg + 4, Number);
  FMemory.Write32(Arg + 8, D.Arg);
  FMemory.Write32(Arg + 12, FMemory.Read32(FMemory.Read32(D.Arg) + 4));
  FMemory.WriteString(Arg + $20, FileName, Length(FileName) + 1);
  var F := TPSPOpenFile.Create;
  F.Id := AllocFd;
  F.Path := Path;
  F.Flags := Flags;
  F.GuestArg := Arg;
  F.GuestFuncs := D.Funcs;
  F.GuestGP := D.GP;
  FFiles.Add(F.Id, F);
  // IoOpen sees the access mask, with create granting read/write access.
  var Access := Flags and 3;
  if (Flags and PSP_O_CREAT) <> 0 then
    Access := Access or 5;
  FKernel.CallGuest(OpenFunc, [Arg, Arg + $20, Access, Mode], nil, D.GP, TPSPStateAction.Create(StateDriverOpened, [],
    [F.Id, Arg]));
end;

procedure TPSPIO.StateDriverOpened(Action: TPSPStateAction; Value: Cardinal);
begin
  var F := GetFile(Cardinal(Action.Arg(0)));
  if F = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_BADF);
    Exit;
  end;
  if Integer(Value) < 0 then
  begin
    FFiles.Remove(F.Id);
    FKernel.KernelPartition.FreeBlock(Cardinal(Action.Arg(1)));
    F.Free;
    FHLE.Result(Value);
  end
  else
    FHLE.Result(Cardinal(F.Id));
end;

function TPSPIO.CallFileDriver(F: TPSPOpenFile; Slot: Integer; const Args: array of Cardinal): Boolean;
begin
  Result := F.GuestArg <> 0;
  if not Result then
    Exit;
  var Func := FMemory.Read32(F.GuestFuncs + Cardinal(Slot) * 4);
  if Func = 0 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNSUP);
    Exit;
  end;
  if FKernel.RefuseWait then
    Exit;
  var Data: TArray<Cardinal>;
  SetLength(Data, Length(Args) + 1);
  Data[0] := F.GuestArg;
  for var I := 0 to High(Args) do
    Data[I + 1] := Args[I];
  FKernel.CallGuest(Func, Data, nil, F.GuestGP, TPSPStateAction.Create(StateDriverReturned, [], [F.Id, Slot]));
end;

procedure TPSPIO.StateDriverReturned(Action: TPSPStateAction; Value: Cardinal);
begin
  FHLE.Result(Value);
  var F := GetFile(Cardinal(Action.Arg(0)));
  if (F <> nil) and (Action.Arg(1) = 3) and (Value = 0) then
  begin
    FFiles.Remove(F.Id);
    FKernel.KernelPartition.FreeBlock(F.GuestArg);
    F.Free;
  end;
end;

procedure TPSPIO.hOpen;
begin
  if FKernel.InInterrupt then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_CONTEXT);
    Exit;
  end;
  if not FKernel.CanWait then
  begin
    FHLE.Result($FFFFFFFF);
    Exit;
  end;
  var Path := FMemory.ReadString(FHLE.Arg(0), 1024);
  if OpenGuestDriver(Path, FHLE.Arg(1), FHLE.Arg(2)) then
    Exit;
  var F: TPSPOpenFile;
  var Err := OpenPath(Path, FHLE.Arg(1), FHLE.Arg(2), F);
  var Host := OnHostDevice(Path);
  if Err <> 0 then
  begin
    FHLE.Log('sceIoOpen %s -> %.8x', [Path, Err]);
    if Host then
      DeviceYield(Err, 30000)
    else
      FHLE.Result(Err);
    Exit;
  end;
  if F.Kind = dkTTY then
    F.Id := AllocTTYFd
  else
    F.Id := AllocFd;
  FFiles.Add(F.Id, F);
  if FKernel.Trace then
    FHLE.Log('sceIoOpen %s -> fd %d', [Path, F.Id]);
  if Host then
    DeviceYield(Cardinal(F.Id), 30000)
  else
    FHLE.Result(Cardinal(F.Id));
end;

procedure TPSPIO.hOpenAsync;
begin
  if FKernel.InInterrupt then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_CONTEXT);
    Exit;
  end;
  var Path := Resolve(FMemory.ReadString(FHLE.Arg(0), 1024));
  var F := TPSPOpenFile.Create;
  F.Path := Path;
  F.Id := AllocFd;
  FFiles.Add(F.Id, F);
  if not StartAsync(F, TPSPStateAction.Create(StatePerformAsync, [F], [0, FHLE.Arg(1), FHLE.Arg(2)], Path), 100000) then
  begin
    FFiles.Remove(F.Id);
    F.Free;
    Exit;
  end;
  FHLE.Result(Cardinal(F.Id));
end;

procedure TPSPIO.hClose;
begin
  var F := GetFile(FHLE.Arg(0));
  if F = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_BADF);
    Exit;
  end;
  if CallFileDriver(F, 3, []) then
    Exit;
  // Programs built after 2.60 cannot close past an uncollected result.
  if F.AsyncPending or ((F.AsyncDone <> 0) and (FKernel.CompiledSdkVersion > $02060010)) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ASYNC_BUSY);
    Exit;
  end;
  FKernel.CancelTimersOf(F);
  StopAsyncWorker(F);
  FFiles.Remove(F.Id);
  var Host := F.Kind = dkHost;
  F.Free;
  if Host then
    DeviceYield(0, 20000)
  else
    FHLE.Result(0);
end;

procedure TPSPIO.hCloseAsync;
begin
  if FKernel.InInterrupt then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_CONTEXT);
    Exit;
  end;
  var F := GetFile(FHLE.Arg(0));
  if F = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_BADF);
    Exit;
  end;
  if AsyncSlotHeld(F) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ASYNC_BUSY);
    Exit;
  end;
  // The descriptor closes when its async result is collected.
  if not StartAsync(F, TPSPStateAction.Create(StatePerformAsync, [F], [1]), 20000) then
    Exit;
  FHLE.Result(0);
end;

procedure TPSPIO.hRead;
begin
  var F := GetFile(FHLE.Arg(0));
  if F = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_BADF);
    Exit;
  end;
  if CallFileDriver(F, 4, [FHLE.Arg(1), FHLE.Arg(2)]) then
    Exit;
  if F.AsyncPending then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ASYNC_BUSY);
    Exit;
  end;
  if RefuseFileWait(F) then
    Exit;
  var R := DoRead(F, FHLE.Arg(1), FHLE.Arg(2));
  // The caller waits for the drive, the UMD's as the memory stick's (GTA
  // Liberty City Stories streams the city only when its reads take time).
  if (F.Kind = dkHost) or (F.Kind = dkUMD) then
    DeviceYield(Cardinal(R), ReadLatency(F, Max(R, 0)))
  else
    FHLE.Result(Cardinal(R));
end;

procedure TPSPIO.hReadAsync;
begin
  if FKernel.InInterrupt then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_CONTEXT);
    Exit;
  end;
  var F := GetFile(FHLE.Arg(0));
  if F = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_BADF);
    Exit;
  end;
  if AsyncSlotHeld(F) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ASYNC_BUSY);
    Exit;
  end;
  if not StartAsync(F, TPSPStateAction.Create(StatePerformAsync, [F], [2, FHLE.Arg(1), FHLE.Arg(2)]), TransferLatency(F,
    FHLE.Arg(1), FHLE.Arg(2), False)) then
    Exit;
  FHLE.Result(0);
end;

procedure TPSPIO.hWrite;
begin
  var Fd := FHLE.Arg(0);
  if (Fd = 1) or (Fd = 2) then
  begin
    if Assigned(FOnOutput) then
      FOnOutput(FMemory.ReadAnsi(FHLE.Arg(1), FHLE.Arg(2)));
    begin
      FHLE.Result(FHLE.Arg(2));
      Exit;
    end;
  end;
  var F := GetFile(Fd);
  if F = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_BADF);
    Exit;
  end;
  if CallFileDriver(F, 5, [FHLE.Arg(1), FHLE.Arg(2)]) then
    Exit;
  if F.AsyncPending then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ASYNC_BUSY);
    Exit;
  end;
  if RefuseFileWait(F) then
    Exit;
  var R := DoWrite(F, FHLE.Arg(1), FHLE.Arg(2));
  if (F.Kind = dkHost) and (R > 0) then
    DeviceYield(Cardinal(R), ReadLatency(F, R))
  else
    FHLE.Result(Cardinal(R));
end;

procedure TPSPIO.hWriteAsync;
begin
  if FKernel.InInterrupt then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_CONTEXT);
    Exit;
  end;
  var Fd := FHLE.Arg(0);
  var F := GetFile(Fd);
  if F = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_BADF);
    Exit;
  end;
  if AsyncSlotHeld(F) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ASYNC_BUSY);
    Exit;
  end;
  if not StartAsync(F, TPSPStateAction.Create(StatePerformAsync, [F], [3, FHLE.Arg(1), FHLE.Arg(2)]), TransferLatency(F,
    FHLE.Arg(1), FHLE.Arg(2), True)) then
    Exit;
  FHLE.Result(0);
end;

procedure TPSPIO.hLseek;
begin
  var F := GetFile(FHLE.Arg(0));
  if F = nil then
  begin
    FHLE.Result64(UInt64(Int64(Integer(SCE_KERNEL_ERROR_BADF))));
    Exit;
  end;
  if F.AsyncPending then
  begin
    FHLE.Result64(UInt64(Int64(Integer(SCE_KERNEL_ERROR_ASYNC_BUSY))));
    Exit;
  end;
  // (fd, pad, offset64 in a2/a3, whence in t0)
  var Offset := Int64(FHLE.Arg64(2));
  var R := DoSeek(F, Offset, FHLE.ArgInt(4));
  FHLE.Result64(UInt64(R));
  if F.Kind = dkHost then
    DeviceYield(Cardinal(UInt64(R)), 20000);
end;

procedure TPSPIO.hLseekAsync;
begin
  if FKernel.InInterrupt then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_CONTEXT);
    Exit;
  end;
  var F := GetFile(FHLE.Arg(0));
  if F = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_BADF);
    Exit;
  end;
  if AsyncSlotHeld(F) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ASYNC_BUSY);
    Exit;
  end;
  if not StartAsync(F, TPSPStateAction.Create(StatePerformAsync, [F], [4, Int64(FHLE.Arg64(2)), FHLE.ArgInt(4)]),
    20000) then
    Exit;
  FHLE.Result(0);
end;

procedure TPSPIO.hLseek32;
begin
  var F := GetFile(FHLE.Arg(0));
  if F = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_BADF);
    Exit;
  end;
  if F.AsyncPending then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ASYNC_BUSY);
    Exit;
  end;
  var R := Cardinal(DoSeek(F, FHLE.ArgInt(1), FHLE.ArgInt(2)));
  if F.Kind = dkHost then
    DeviceYield(R, 20000)
  else
    FHLE.Result(R);
end;

procedure TPSPIO.hLseek32Async;
begin
  if FKernel.InInterrupt then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_CONTEXT);
    Exit;
  end;
  var F := GetFile(FHLE.Arg(0));
  if F = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_BADF);
    Exit;
  end;
  if AsyncSlotHeld(F) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ASYNC_BUSY);
    Exit;
  end;
  if not StartAsync(F, TPSPStateAction.Create(StatePerformAsync, [F], [4, FHLE.ArgInt(1), FHLE.ArgInt(2)]), 20000) then
    Exit;
  FHLE.Result(0);
end;

function TPSPIO.IoctlCommon(F: TPSPOpenFile; Cmd, InPtr, InLen, OutPtr, OutLen: Cardinal): Cardinal;
begin
  Result := 0;
  if F.Kind = dkMsStor then
  begin
    case Cmd of
      $02125008, $02125009:
        begin
          if (OutPtr = 0) or (OutLen < 4) then
            Exit($80220183);
          FMemory.Write32(OutPtr, Ord(Cmd = $02125008));
        end;
    else
      Exit($80220183);
    end;
    Exit;
  end;
  if F.Kind <> dkUMD then
    Exit(SCE_KERNEL_ERROR_UNSUP);
  case Cmd of
    $01010005:
      begin
        // Seek in bytes.
        if InPtr <> 0 then
          F.Position := FMemory.Read32(InPtr);
      end;
    $01020001, $01020006:
      if (OutPtr <> 0) and (OutLen >= 4) then
        FMemory.Write32(OutPtr, Cardinal(F.DiscStart div 2048));
    $01020004:
      if (OutPtr <> 0) and (OutLen >= 4) then
        FMemory.Write32(OutPtr, Cardinal(Max(Int64(0), F.DiscSize - F.Position)));
    $01020007:
      if (OutPtr <> 0) and (OutLen >= 8) then
      begin
        FMemory.Write32(OutPtr, Cardinal(F.DiscSize));
        FMemory.Write32(OutPtr + 4, 0);
      end;
  end;
end;

procedure TPSPIO.hIoctl;
begin
  var F := GetFile(FHLE.Arg(0));
  if F = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_BADF);
    Exit;
  end;
  FHLE.Result(IoctlCommon(F, FHLE.Arg(1), FHLE.Arg(2), FHLE.Arg(3), FHLE.Arg(4), FHLE.Arg(5)));
end;

procedure TPSPIO.hIoctlAsync;
begin
  if FKernel.InInterrupt then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_CONTEXT);
    Exit;
  end;
  var F := GetFile(FHLE.Arg(0));
  if F = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_BADF);
    Exit;
  end;
  if AsyncSlotHeld(F) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ASYNC_BUSY);
    Exit;
  end;
  if not StartAsync(F, TPSPStateAction.Create(StatePerformAsync, [F],
    [5, FHLE.Arg(1), FHLE.Arg(2), FHLE.Arg(3), FHLE.Arg(4), FHLE.Arg(5)]), 20000) then
    Exit;
  FHLE.Result(0);
end;

procedure TPSPIO.hDevctl;
begin
  var Name := FMemory.ReadString(FHLE.Arg(0), 64).ToLower;
  var Cmd := FHLE.Arg(1);
  var InPtr := FHLE.Arg(2);
  var InLen := FHLE.Arg(3);
  var OutPtr := FHLE.Arg(4);
  var OutLen := FHLE.Arg(5);
  var Dev := Name;
  if Dev.EndsWith(':') then
    Dev := Dev.Substring(0, Dev.Length - 1);
  FHLE.Result(0);
  case DeviceKind(Dev) of
    dkEmulator:
      case Cmd of
        1:
          if (OutPtr <> 0) and (OutLen >= 4) then
            FMemory.Write32(OutPtr, Ord(FHasDisplay));
        2:
          if Assigned(FOnOutput) then
            FOnOutput(FMemory.ReadAnsi(InPtr, InLen));
        3:
          ;
        $20:
          if Assigned(FOnScreenshot) then
            FOnScreenshot();
      end;
    dkMsStor:
      case Cmd of
        $02025806:
          if (OutPtr <> 0) and (OutLen >= 4) then
            if FMemstickInserted then
              FMemory.Write32(OutPtr, 1)
            else
              FMemory.Write32(OutPtr, 2)
          else
            FHLE.Result($80220183);
        $02125802:
          if (OutPtr <> 0) and (OutLen >= 4) then
            FMemory.Write32(OutPtr, $40)
          else
            FHLE.Result($80220183);
      else
        FHLE.Result($80220183);
      end;
    dkUMD:
      case Cmd of
        $01F20001:
          if (OutPtr <> 0) and (OutLen >= 8) then
          begin
            FMemory.Write32(OutPtr, 0);
            FMemory.Write32(OutPtr + 4, $10);
          end;
        $01F20002, $01F20003:
          if (OutPtr <> 0) and (OutLen >= 4) then
            FMemory.Write32(OutPtr, 0);
        $01E18030:
          FHLE.Result(1);
      end;
    dkHost:
      case Cmd of
        $02025801:
          if OutPtr <> 0 then
            FMemory.Write32(OutPtr, 4);
        $02015804, $02025806:
          if OutPtr <> 0 then
            FMemory.Write32(OutPtr, 1);
        $02415821, $02415823:
          begin
            // Register the current medium state and subsequent insertion changes.
            if (InPtr <> 0) and (InLen >= 4) then
            begin
              var CB := TPSPCallback(FKernel.GetObject(FMemory.Read32(InPtr), TPSPCallback));
              if CB <> nil then
              begin
                if not FMemstickCallbacks.Contains(CB.UID) then
                  FMemstickCallbacks.Add(CB.UID);
                FKernel.NotifyCallback(CB, Ord(FMemstickInserted));
              end;
            end;
          end;
        $02415822:
          if (InPtr <> 0) and (InLen >= 4) then
            FMemstickCallbacks.Remove(FMemory.Read32(InPtr));
        $02425818:
          if not FMemstickInserted then
            FHLE.Result(SCE_KERNEL_ERROR_NODEV)
          else if InPtr <> 0 then
          begin
            // Free space: 1 GB in 32 KB clusters.
            var P := FMemory.Read32(InPtr);
            FMemory.Write32(P + 0, 32768);
            FMemory.Write32(P + 4, 32768);
            FMemory.Write32(P + 8, 32768);
            FMemory.Write32(P + 12, 512);
            FMemory.Write32(P + 16, 64);
          end;
        // FAT on the stick ready: 1 (0 without a stick, utility/savedata/nomemstick).
        $02425823:
          if OutPtr <> 0 then
            FMemory.Write32(OutPtr, Ord(FMemstickInserted));
        $02425824:
          if OutPtr <> 0 then
            FMemory.Write32(OutPtr, 0);
      end;
  else
    FHLE.Result(SCE_KERNEL_ERROR_NODEV);
  end;
end;

procedure TPSPIO.hGetstat;
begin
  var Path := Resolve(FMemory.ReadString(FHLE.Arg(0), 1024));
  if RejectMissingMemstick(Path) then
    Exit;
  var StatPtr := FHLE.Arg(1);
  var Dev, Rest: string;
  if not Split(Path, Dev, Rest) then
  begin
    FHLE.Result(SCE_ERROR_ERRNO_ENOENT);
    Exit;
  end;
  case DeviceKind(Dev) of
    dkUMD:
      begin
        if FDisc = nil then
        begin
          FHLE.Result(SCE_KERNEL_ERROR_NODEV);
          Exit;
        end;
        var E: TPSPDiscEntry;
        if not FDisc.Entry(Rest, E) then
        begin
          FHLE.Result(SCE_ERROR_ERRNO_ENOENT);
          Exit;
        end;
        // UMD files keep their sector number in st_private[0].
        WriteStat(StatPtr, E.Directory, E.Size, E.Modified, True, True, E.LBA);
        FHLE.Result(0);
      end;
    dkHost:
      begin
        var Name := HostPath(Dev, Rest);
        if NormalizeRest(Rest) = '/' then
        begin
          FHLE.Result(SCE_ERROR_ERRNO_EINVAL);
          Exit;
        end;
        if DirectoryExists(Name) then
        begin
          WriteStat(StatPtr, True, 0, TDirectory.GetLastWriteTime(Name), HostReadOnly(Name));
          DeviceYield(0, 20000);
        end
        else if FileExists(Name) then
        begin
          var Size: Int64 := 0;
          var SR: TSearchRec;
          if FindFirst(Name, faAnyFile, SR) = 0 then
          begin
            Size := SR.Size;
            FindClose(SR);
          end;
          WriteStat(StatPtr, False, Size, TFile.GetLastWriteTime(Name), HostReadOnly(Name));
          DeviceYield(0, 20000);
        end
        else
          DeviceYield(SCE_ERROR_ERRNO_ENOENT, 20000);
      end;
  else
    FHLE.Result(SCE_KERNEL_ERROR_NODEV);
  end;
end;

procedure TPSPIO.hChstat;
begin
  var Path := FMemory.ReadString(FHLE.Arg(0), 1024);
  if RejectMissingMemstick(Path) then
    Exit;
  var Name := HostFileName(Path);
  var StatPtr := FHLE.Arg(1);
  var Bits := FHLE.Arg(2);
  if Name = '' then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNSUP);
    Exit;
  end;
  if not FileExists(Name) and not DirectoryExists(Name) then
  begin
    DeviceYield(SCE_ERROR_ERRNO_ENOENT, 20000);
    Exit;
  end;
  var ReadOnly := HostReadOnly(Name);
  if (Bits and 1) <> 0 then
    ReadOnly := (FMemory.Read32(StatPtr) and $92) = 0;
  if (Bits and 2) <> 0 then
    ReadOnly := (FMemory.Read32(StatPtr + 4) and 1) <> 0;
  HostSetReadOnly(Name, ReadOnly);
  HostChanged(Name);
  DeviceYield(0, 20000);
end;

procedure TPSPIO.hDopen;
begin
  var Path := Resolve(FMemory.ReadString(FHLE.Arg(0), 1024));
  if RejectMissingMemstick(Path) then
    Exit;
  if FKernel.Trace then
    FHLE.Log('dopen %s', [Path]);
  var Dev, Rest: string;
  if not Split(Path, Dev, Rest) then
  begin
    FHLE.Result(SCE_ERROR_ERRNO_ENOENT);
    Exit;
  end;
  var F := TPSPOpenFile.Create;
  F.IsDirectory := True;
  F.Path := Path;
  case DeviceKind(Dev) of
    dkUMD:
      begin
        if FDisc = nil then
        begin
          F.Free;
          begin
            FHLE.Result(SCE_KERNEL_ERROR_NODEV);
            Exit;
          end;
        end;
        var E: TPSPDiscEntry;
        if not FDisc.Entry(Rest, E) or not E.Directory then
        begin
          F.Free;
          begin
            FHLE.Result(SCE_ERROR_ERRNO_ENOENT);
            Exit;
          end;
        end;
        F.Kind := dkUMD;
        // The UMD file system lists no '.' or '..'.
        for var D in FDisc.ReadDirectory(Rest) do
          if (D.Name <> '.') and (D.Name <> '..') then
            F.Entries := F.Entries + [D];
      end;
    dkHost:
      begin
        var Name := HostPath(Dev, Rest);
        var Exists := DirectoryExists(Name);
        // A mounted device's root is there even when no host files back it.
        if not Exists and ((Name = '') or (NormalizeRest(Rest) <> '/')) then
        begin
          F.Free;
          begin
            FHLE.Result(SCE_ERROR_ERRNO_ENOENT);
            Exit;
          end;
        end;
        F.Kind := dkHost;
        var Dot := Default(TPSPDiscEntry);
        Dot.Name := '.';
        Dot.Directory := True;
        if not Exists then
        begin
          F.Entries := [Dot];
          Dot.Name := '..';
          F.Entries := F.Entries + [Dot];
          F.Id := AllocFd;
          FFiles.Add(F.Id, F);
          FHLE.Result(Cardinal(F.Id));
          Exit;
        end;
        Dot.Modified := TDirectory.GetLastWriteTime(Name);
        var DotDot := Dot;
        DotDot.Name := '..';
        var Mount := ExcludeTrailingPathDelimiter(TPath.GetFullPath(HostRoot(Dev)));
        var Parent := ExtractFileDir(ExcludeTrailingPathDelimiter(TPath.GetFullPath(Name)));
        if not SameText(Parent, Mount) and not Parent.StartsWith(IncludeTrailingPathDelimiter(Mount), True) then
          Parent := Mount;
        DotDot.Modified := TDirectory.GetLastWriteTime(Parent);
        F.Entries := [Dot, DotDot];
        for var D in TDirectory.GetDirectories(Name) do
        begin
          var E := Default(TPSPDiscEntry);
          E.Name := ExtractFileName(D);
          E.Directory := True;
          E.Modified := TDirectory.GetLastWriteTime(D);
          if HostReadOnly(D) then
            E.Accessed := 1;
          F.Entries := F.Entries + [E];
        end;
        for var FN in TDirectory.GetFiles(Name) do
        begin
          var E := Default(TPSPDiscEntry);
          E.Name := ExtractFileName(FN);
          var SR: TSearchRec;
          if FindFirst(FN, faAnyFile, SR) = 0 then
          begin
            E.Size := SR.Size;
            FindClose(SR);
          end;
          E.Modified := TFile.GetLastWriteTime(FN);
          if HostReadOnly(FN) then
            E.Accessed := 1;
          F.Entries := F.Entries + [E];
        end;
      end;
  else
    F.Free;
    begin
      FHLE.Result(SCE_KERNEL_ERROR_NODEV);
      Exit;
    end;
  end;
  F.Id := AllocFd;
  FFiles.Add(F.Id, F);
  FHLE.Result(Cardinal(F.Id));
end;

procedure TPSPIO.hDread;
begin
  var F := GetFile(FHLE.Arg(0));
  if (F = nil) or not F.IsDirectory then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_BADF);
    Exit;
  end;
  if RejectMissingMemstick(F.Path) then
    Exit;
  var P := FHLE.Arg(1);
  if F.EntryIndex >= Length(F.Entries) then
  begin
    FHLE.Result(0);
    Exit;
  end;
  var E := F.Entries[F.EntryIndex];
  Inc(F.EntryIndex);
  if F.Kind = dkUMD then
    WriteStat(P, E.Directory, E.Size, E.Modified, True, True, E.LBA)
  else
    WriteStat(P, E.Directory, E.Size, E.Modified, E.Accessed <> 0);
  FMemory.WriteString(P + $58, RawByteString(E.Name), 256);
  if F.Kind = dkHost then
  begin
    var Dev, Rest: string;
    Split(F.Path, Dev, Rest);
    if (Dev = 'ms0') or (Dev = 'ms') or (Dev = 'fatms0') or (Dev = 'fatms') or (Dev = 'ef0') then
    begin
      var Priv := FMemory.Read32(P + $158);
      if Priv <> 0 then
      begin
        var Short := FatName(NormalizeRest(Rest) + '/' + E.Name, E.Name);
        if FKernel.CompiledSdkVersion < $03080000 then
        begin
          FMemory.WriteString(Priv, RawByteString(Short), 13);
          FMemory.WriteString(Priv + 13, RawByteString(E.Name), 256);
        end
        else if FMemory.Read32(Priv) >= 1044 then
        begin
          FMemory.WriteString(Priv + 4, RawByteString(Short), 16);
          FMemory.WriteString(Priv + 20, RawByteString(E.Name), 1024);
        end;
      end;
    end;
  end;
  FHLE.Result(1);
end;

procedure TPSPIO.hDclose;
begin
  var F := GetFile(FHLE.Arg(0));
  if (F = nil) or not F.IsDirectory then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_BADF);
    Exit;
  end;
  FFiles.Remove(F.Id);
  F.Free;
  FHLE.Result(0);
end;

procedure TPSPIO.hMkdir;
begin
  var Path := FMemory.ReadString(FHLE.Arg(0), 1024);
  if RejectMissingMemstick(Path) then
    Exit;
  var Name := HostFileName(Path);
  if Name = '' then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNSUP);
    Exit;
  end;
  if DirectoryExists(Name) or FileExists(Name) then
  begin
    DeviceYield(SCE_ERROR_ERRNO_EEXIST, 20000);
    Exit;
  end;
  if not DirectoryExists(ExtractFileDir(Name)) then
  begin
    DeviceYield(SCE_ERROR_ERRNO_ENOENT, 20000);
    Exit;
  end;
  if CreateDir(Name) then
  begin
    RememberFatPath(Name);
    HostChanged(Name, True);
    DeviceYield(0, 30000);
  end
  else
    DeviceYield(SCE_ERROR_ERRNO_EACCES, 30000);
end;

procedure TPSPIO.hRmdir;
begin
  var Path := FMemory.ReadString(FHLE.Arg(0), 1024);
  if RejectMissingMemstick(Path) then
    Exit;
  var Name := HostFileName(Path);
  if Name = '' then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNSUP);
    Exit;
  end;
  if not DirectoryExists(Name) then
  begin
    DeviceYield(SCE_ERROR_ERRNO_ENOENT, 20000);
    Exit;
  end;
  if RemoveDir(Name) then
  begin
    ForgetFatPath(Name);
    HostChanged(Name);
    DeviceYield(0, 30000);
  end
  else
    DeviceYield(SCE_ERROR_ERRNO_ENOTEMPTY, 30000);
end;

procedure TPSPIO.hRemove;
begin
  var Path := FMemory.ReadString(FHLE.Arg(0), 1024);
  if RejectMissingMemstick(Path) then
    Exit;
  var Name := HostFileName(Path);
  if Name = '' then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNSUP);
    Exit;
  end;
  if not FileExists(Name) then
  begin
    DeviceYield(SCE_ERROR_ERRNO_ENOENT, 20000);
    Exit;
  end;
  if DeleteFile(Name) then
  begin
    ForgetFatPath(Name);
    HostChanged(Name);
    DeviceYield(0, 30000);
  end
  else
    DeviceYield(SCE_ERROR_ERRNO_EACCES, 30000);
end;

procedure TPSPIO.hRename;
begin
  // The FAT driver renames in place: only the new name's last part counts.
  var SrcPath := FMemory.ReadString(FHLE.Arg(0), 1024);
  var DstPath := FMemory.ReadString(FHLE.Arg(1), 1024);
  if RejectMissingMemstick(SrcPath) or RejectMissingMemstick(DstPath) then
    Exit;
  if (SrcPath.IndexOfAny(['*', '?']) >= 0) or (DstPath.IndexOfAny(['*', '?']) >= 0) then
  begin
    DeviceYield(SCE_ERROR_ERRNO_EINVAL, 20000);
    Exit;
  end;
  var SrcDev, SrcRest, DstDev, DstRest: string;
  if not Split(Resolve(SrcPath), SrcDev, SrcRest) then
  begin
    FHLE.Result(SCE_ERROR_ERRNO_ENOENT);
    Exit;
  end;
  if DstPath.Contains(':') and Split(DstPath, DstDev, DstRest) and (DstDev <> SrcDev) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_XDEV);
    Exit;
  end;
  var Src := HostFileName(SrcPath);
  if Src = '' then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNSUP);
    Exit;
  end;
  var NewName := DstPath.Replace('\', '/');
  if NewName.Contains(':') then
    NewName := NewName.Substring(NewName.IndexOf(':') + 1);
  while NewName.EndsWith('/') do
    NewName := NewName.Substring(0, NewName.Length - 1);
  NewName := NewName.Substring(NewName.LastIndexOf('/') + 1);
  if not FileExists(Src) and not DirectoryExists(Src) then
  begin
    DeviceYield(SCE_ERROR_ERRNO_ENOENT, 20000);
    Exit;
  end;
  var Dst := TPath.Combine(ExtractFileDir(Src), NewName);
  if FileExists(Dst) or DirectoryExists(Dst) then
  begin
    DeviceYield(SCE_ERROR_ERRNO_EEXIST, 20000);
    Exit;
  end;
  if RenameFile(Src, Dst) then
  begin
    var GuestDst := Resolve(SrcPath);
    GuestDst := GuestDst.Substring(0, GuestDst.LastIndexOf('/') + 1) + NewName;
    for var F in FFiles.Values do
      if F.Kind = dkHost then
      begin
        var OpenName := HostFileName(F.Path);
        if SameText(OpenName, Src) or OpenName.StartsWith(IncludeTrailingPathDelimiter(Src), True) then
          F.Path := GuestDst + OpenName.Substring(Src.Length).Replace(PathDelim, '/');
      end;
    HostChanged(Src);
    HostChanged(Dst, False, True);
    ForgetFatPath(Src, Dst);
    DeviceYield(0, 30000)
  end
  else
    DeviceYield(SCE_ERROR_ERRNO_EACCES, 30000);
end;

procedure TPSPIO.hChdir;
begin
  var Path := FMemory.ReadString(FHLE.Arg(0), 1024);
  if RejectMissingMemstick(Path) then
    Exit;
  FCwd := Resolve(Path);
  FHLE.Result(0);
end;

procedure TPSPIO.hSync;
begin
  FHLE.Result(0);
end;

procedure TPSPIO.hAssign;
begin
  FHLE.Result(0);
end;

procedure TPSPIO.hUnassign;
begin
  FHLE.Result(0);
end;

procedure TPSPIO.hGetDevType;
begin
  var F := GetFile(FHLE.Arg(0));
  if F = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_BADF);
    Exit;
  end;
  case F.Kind of
    dkUMD:
      FHLE.Result($10);
  else
    FHLE.Result($20);
  end;
end;

procedure TPSPIO.hCancel;
begin
  var F := GetFile(FHLE.Arg(0));
  if F = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_BADF);
    Exit;
  end;
  FHLE.Result(SCE_KERNEL_ERROR_UNSUP);
end;

procedure TPSPIO.hWaitAsync;
begin
  WaitAsync(False);
end;

procedure TPSPIO.hWaitAsyncCB;
begin
  WaitAsync(True);
end;

procedure TPSPIO.hPollAsync;
begin
  var F := GetFile(FHLE.Arg(0));
  var ResPtr := FHLE.Arg(1);
  if F = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_BADF);
    Exit;
  end;
  if F.AsyncPending then
  begin
    FHLE.Result(1);
    Exit;
  end;
  if F.AsyncDone = 0 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_NOASYNC);
    Exit;
  end;
  CollectAsync(F, ResPtr);
  FHLE.Result(0);
end;

procedure TPSPIO.hGetAsyncStat;
begin
  if FKernel.InInterrupt and (GetFile(FHLE.Arg(0)) <> nil) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_CONTEXT);
    Exit;
  end;
  var Poll := FHLE.Arg(1) <> 0;
  if Poll then
  begin
    var Saved := FHLE.CPU.Ctx.GPR[5];
    FHLE.CPU.Ctx.GPR[5] := FHLE.Arg(2);
    hPollAsync;
    FHLE.CPU.Ctx.GPR[5] := Saved;
  end
  else
  begin
    FHLE.CPU.Ctx.GPR[5] := FHLE.Arg(2);
    WaitAsync(False);
  end;
end;

procedure TPSPIO.hChangeAsyncPriority;
begin
  var Priority := FHLE.ArgInt(1);
  var KernelCaller := (FKernel.Current <> nil) and FKernel.Current.IsKernel;
  if (Priority <> -1) and (((Priority < 1) or (Priority > 126)) or
    (not KernelCaller and ((Priority < 8) or (Priority > 119)))) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_PRIORITY);
    Exit;
  end;
  if Integer(FHLE.Arg(0)) = -1 then
  begin
    FAsyncPriority := Max(0, Priority);
    FHLE.Result(0);
    Exit;
  end;
  var F := GetFile(FHLE.Arg(0));
  if F = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_BADF);
    Exit;
  end;
  if (Priority = -1) and (FKernel.Current = nil) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_PRIORITY);
    Exit;
  end;
  F.AsyncPriority := Max(0, Priority);
  var T := FKernel.ThreadById(F.AsyncWorker);
  if (F.AsyncWorker <> 0) and (T <> nil) then
  begin
    if Priority = -1 then
      Priority := FKernel.Current.Priority;
    FKernel.ChangePriority(T, Priority);
  end;
  FHLE.Result(0);
end;

procedure TPSPIO.hSetAsyncCallback;
begin
  var F := GetFile(FHLE.Arg(0));
  if F = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_BADF);
    Exit;
  end;
  F.AsyncCallback := FHLE.Arg(1);
  F.AsyncArg := FHLE.Arg(2);
  FHLE.Result(0);
end;

procedure TPSPIO.hGetFdList;
begin
  FHLE.Result(0);
end;

procedure TPSPIO.hStdout;
begin
  FHLE.Result(1);
end;

procedure TPSPIO.hStderr;
begin
  FHLE.Result(2);
end;

procedure TPSPIO.hStdin;
begin
  FHLE.Result(0);
end;

procedure TPSPIO.Register;
const
  L = 'IoFileMgrForUser';
begin
  var H := FHLE;
  H.Register('IoFileMgrForKernel', $8E982A74, 'sceIoAddDrv', hAddDrv);
  H.Register('IoFileMgrForKernel', $C7F35804, 'sceIoDelDrv', hDelDrv);
  H.Register(L, $109F50BC, 'sceIoOpen', hOpen);
  H.Register(L, $89AA9906, 'sceIoOpenAsync', hOpenAsync);
  H.Register(L, $810C4BC3, 'sceIoClose', hClose);
  H.Register(L, $FF5940B6, 'sceIoCloseAsync', hCloseAsync);
  H.Register(L, $6A638D83, 'sceIoRead', hRead);
  H.Register(L, $A0B5A7C2, 'sceIoReadAsync', hReadAsync);
  H.Register(L, $42EC03AC, 'sceIoWrite', hWrite);
  H.Register(L, $0FACAB19, 'sceIoWriteAsync', hWriteAsync);
  H.Register(L, $27EB27B8, 'sceIoLseek', hLseek);
  H.Register(L, $71B19E77, 'sceIoLseekAsync', hLseekAsync);
  H.Register(L, $68963324, 'sceIoLseek32', hLseek32);
  H.Register(L, $1B385D8F, 'sceIoLseek32Async', hLseek32Async);
  H.Register(L, $63632449, 'sceIoIoctl', hIoctl);
  H.Register(L, $E95A012B, 'sceIoIoctlAsync', hIoctlAsync);
  H.Register(L, $54F5FB11, 'sceIoDevctl', hDevctl);
  H.Register(L, $ACE946E8, 'sceIoGetstat', hGetstat);
  H.Register(L, $B8A740F4, 'sceIoChstat', hChstat);
  H.Register(L, $B29DDF9C, 'sceIoDopen', hDopen);
  H.Register(L, $E3EB004C, 'sceIoDread', hDread);
  H.Register(L, $EB092469, 'sceIoDclose', hDclose);
  H.Register(L, $06A70004, 'sceIoMkdir', hMkdir);
  H.Register(L, $1117C65F, 'sceIoRmdir', hRmdir);
  H.Register(L, $F27A9C51, 'sceIoRemove', hRemove);
  H.Register(L, $779103A0, 'sceIoRename', hRename);
  H.Register(L, $55F4717D, 'sceIoChdir', hChdir);
  H.Register(L, $AB96437F, 'sceIoSync', hSync);
  H.Register(L, $B2A628C1, 'sceIoAssign', hAssign);
  H.Register(L, $6D08A871, 'sceIoUnassign', hUnassign);
  H.Register(L, $08BD7374, 'sceIoGetDevType', hGetDevType);
  H.Register(L, $E8BC6571, 'sceIoCancel', hCancel);
  H.Register(L, $E23EEC33, 'sceIoWaitAsync', hWaitAsync);
  H.Register(L, $35DBD746, 'sceIoWaitAsyncCB', hWaitAsyncCB);
  H.Register(L, $3251EA56, 'sceIoPollAsync', hPollAsync);
  H.Register(L, $CB05F8D6, 'sceIoGetAsyncStat', hGetAsyncStat);
  H.Register(L, $B293727F, 'sceIoChangeAsyncPriority', hChangeAsyncPriority);
  H.Register(L, $A12A0514, 'sceIoSetAsyncCallback', hSetAsyncCallback);
  H.Register(L, $5C2BE2CC, 'sceIoGetFdList', hGetFdList);
  H.Register('StdioForUser', $A6BAB2E9, 'sceKernelStdout', hStdout);
  H.Register('StdioForUser', $F78BA90A, 'sceKernelStderr', hStderr);
  H.Register('StdioForUser', $172D316E, 'sceKernelStdin', hStdin);
end;

end.
