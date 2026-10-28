unit PSP.FileSystem;

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections, Core.Storage,
  PSP.Media, PSP.Memory, PSP.CPU, PSP.Kernel;

type
  TPSPFileHandle = class
    Stream: TStream;
    Flags, LBA: Cardinal;
    Disc, BlockMode: Boolean;
    AsyncResult: Int64;
    AsyncPending: Boolean;
    AsyncPriority: Integer;
    AsyncClosing: Boolean;
    AsyncReady: UInt64;
    CallbackId, CallbackArgument, WaiterThread, WaiterOutput: Cardinal;
    AsyncNotified: Boolean;
    destructor Destroy; override;
  end;

  TPSPDirectoryHandle = class
    Entries: TArray<TPSPDiscEntry>;
    Index: Integer;
    Disc: Boolean;
  end;

  TPSPFileSystem = class
  private
    FStorage: IStorage;
    FMemory: TPSPMemory;
    FCPU: TPSPCPU;
    FKernel: TPSPKernel;
    FImage: TStream;
    FDisc: TPSPDisc;
    FFiles: TObjectDictionary<Cardinal, TPSPFileHandle>;
    FDirectories: TObjectDictionary<Cardinal, TPSPDirectoryHandle>;
    FNextHandle: Cardinal;
    FAsyncPriority: Integer;
    FRoot, FCwd: string;
    FFatEnabled: Cardinal;
    FMemoryStickCallbacks, FFatCallbacks: TList<Cardinal>;
    function Normalize(const Path: string): string;
    function HostPath(const Path: string): string;
    function Open(const Path: string; Flags: Cardinal): Cardinal;
    function Transfer(Id, Address, Count: Cardinal; Writing: Boolean): Cardinal;
    function Seek(Id: Cardinal; Offset: Int64; Origin: Cardinal): Int64;
    function Stat(const Path: string; Address: Cardinal): Cardinal;
    procedure AsyncResult(FileHandle: TPSPFileHandle; Value: Int64);
    function PollAsync(Id, Address: Cardinal; Poll: Boolean): Cardinal;
    function OpenDirectory(const Path: string): Cardinal;
    function ReadDirectory(Id, Address: Cardinal): Cardinal;
    function Ioctl(Id, Command, Input, InputSize, Output, OutputSize: Cardinal): Cardinal;
    function Devctl(const Device: string; Command, Input, InputSize, Output, OutputSize: Cardinal): Cardinal;
    procedure WriteStat(Address: Cardinal; const Entry: TPSPDiscEntry; Disc: Boolean);
  public
    constructor Create(const Storage: IStorage; Memory: TPSPMemory; CPU: TPSPCPU; const ProgramData: TPSPProgram; Kernel: TPSPKernel = nil);
    destructor Destroy; override;
    procedure Advance(Time: UInt64);
    function Handle(NID: Cardinal; out Value: Cardinal): Boolean;
    function ReadProgram(const Path: string): TPSPProgram; overload;
    function ReadProgram(Id: Cardinal; out ProgramData: TPSPProgram): Cardinal; overload;
    function MemoryStickPath(const Path: string): string;
  end;

implementation

uses
  System.IOUtils, System.Math, System.DateUtils;

function TPSPFileSystem.MemoryStickPath(const Path: string): string;
begin
  Result := HostPath(Normalize(Path));
end;

destructor TPSPFileHandle.Destroy;
begin
  Stream.Free;
  inherited;
end;

constructor TPSPFileSystem.Create(const Storage: IStorage; Memory: TPSPMemory; CPU: TPSPCPU; const ProgramData: TPSPProgram; Kernel: TPSPKernel);
begin
  inherited Create;
  FStorage := Storage;
  if FStorage = nil then
    FStorage := TStorage.Default;
  FMemory := Memory;
  FCPU := CPU;
  FKernel := Kernel;
  FFiles := TObjectDictionary<Cardinal, TPSPFileHandle>.Create([doOwnsValues]);
  FDirectories := TObjectDictionary<Cardinal, TPSPDirectoryHandle>.Create([doOwnsValues]);
  FFatEnabled := 1;
  FMemoryStickCallbacks := TList<Cardinal>.Create;
  FFatCallbacks := TList<Cardinal>.Create;
  FNextHandle := 3;
  FRoot := TPath.Combine(FStorage.SaveRoot, 'psp-memstick');
  ForceDirectories(TPath.Combine(FRoot, 'PSP/SAVEDATA'));
  FCwd := 'ms0:/PSP/GAME/RetroMul';
  if ProgramData.MediaPath <> '' then
  begin
    FImage := FStorage.OpenRead(ProgramData.MediaPath);
    FDisc := TPSPDisc.Create(FImage);
    FCwd := 'disc0:/PSP_GAME/USRDIR';
  end;
end;

destructor TPSPFileSystem.Destroy;
begin
  FDirectories.Free;
  FMemoryStickCallbacks.Free;
  FFatCallbacks.Free;
  FFiles.Free;
  FDisc.Free;
  FImage.Free;
  inherited;
end;

function TPSPFileSystem.Normalize(const Path: string): string;
begin
  var Value := Path.Replace('\', '/');
  if Value.Contains(':') then
  begin
    if Value.StartsWith('umd0:', True) then
      Value := 'disc0:' + Value.Substring(5);
    if Value.StartsWith('fatms0:', True) then
      Value := 'ms0:' + Value.Substring(7);
  end
  else if Value.StartsWith('/') then
    Value := FCwd.Split([':'])[0] + ':' + Value
  else
    Value := FCwd + '/' + Value;
  var Colon := Value.IndexOf(':');
  if Colon < 0 then
    raise EArgumentException.Create('PSP: invalid device path');
  var Device := Value.Substring(0, Colon).ToLower;
  if (Device <> 'disc0') and (Device <> 'ms0') then
    raise EFOpenError.CreateFmt('%s', ['PSP: unknown filesystem device']);
  var Parts := TList<string>.Create;
  try
    for var Part in Value.Substring(Colon + 1).Split(['/'], TStringSplitOptions.ExcludeEmpty) do
      if Part = '..' then
      begin
        if Parts.Count > 0 then
          Parts.Delete(Parts.Count - 1);
      end
      else if Part <> '.' then
      begin
        if Part.Contains(':') or Part.Contains(#0) then
          raise EArgumentException.Create('PSP: invalid path component');
        Parts.Add(Part);
      end;
    Result := Device + ':/' + string.Join('/', Parts.ToArray);
  finally
    Parts.Free;
  end;
end;

function TPSPFileSystem.HostPath(const Path: string): string;
begin
  if not Path.StartsWith('ms0:/') then
    raise EWriteError.Create('PSP: disc is read only');
  Result := TPath.GetFullPath(TPath.Combine(FRoot, Path.Substring(5).Replace('/', PathDelim)));
  var Root := IncludeTrailingPathDelimiter(TPath.GetFullPath(FRoot));
  if not SameText(Result, ExcludeTrailingPathDelimiter(Root)) and not Result.StartsWith(Root, True) then
    raise EArgumentException.Create('PSP: path escapes memory stick');
end;

function TPSPFileSystem.Open(const Path: string; Flags: Cardinal): Cardinal;
begin
  var Name := Normalize(Path);
  var Stream: TStream;
  var BlockMode := SameText(Path, 'umd0:') or SameText(Path, 'umd0:/');
  if Name.StartsWith('disc0:') then
  begin
    if FDisc = nil then
      Exit($80010013);
    if Flags and 3 <> 1 then
      Exit($8001001E);
    try
      if BlockMode then
        Stream := FDisc.OpenRaw
      else
        Stream := FDisc.OpenFile(Name.Substring(7));
    except
      on EFOpenError do
        Exit($80010002)
    end;
  end
  else
  begin
    var FileName := HostPath(Name);
    var Exists := TFile.Exists(FileName);
    if not Exists and (Flags and $200 = 0) then
      Exit($80010002);
    if Exists and (Flags and $A00 = $A00) then
      Exit($80010011);
    if not Exists then
    begin
      ForceDirectories(ExtractFilePath(FileName));
      var Created := TFileStream.Create(FileName, fmCreate);
      Created.Free;
    end;
    if Flags and $400 <> 0 then
    begin
      var Truncated := TFileStream.Create(FileName, fmCreate);
      Truncated.Free;
    end;
    var Mode: Word := fmOpenRead;
    if Flags and 3 = 2 then
      Mode := fmOpenWrite;
    if Flags and 3 = 3 then
      Mode := fmOpenReadWrite;
    Stream := TFileStream.Create(FileName, Mode or fmShareDenyNone);
    if Flags and $100 <> 0 then
      Stream.Position := Stream.Size;
  end;
  var FileHandle := TPSPFileHandle.Create;
  FileHandle.Stream := Stream;
  FileHandle.Flags := Flags;
  FileHandle.Disc := Name.StartsWith('disc0:');
  FileHandle.BlockMode := BlockMode;
  if FileHandle.Disc and not BlockMode then
    FileHandle.LBA := FDisc.FileLBA(Name.Substring(7));
  Result := FNextHandle;
  Inc(FNextHandle);
  FFiles.Add(Result, FileHandle);
end;

function TPSPFileSystem.Transfer(Id, Address, Count: Cardinal; Writing: Boolean): Cardinal;
begin
  if Writing and (Id in [1, 2]) then
    Exit(Count);
  var FileHandle: TPSPFileHandle;
  if not FFiles.TryGetValue(Id, FileHandle) then
    Exit($80010009);
  if FileHandle.BlockMode then
  begin
    if Count > PSPRAMSize div 2048 then
      Exit($80010016);
    Count := Count * 2048;
  end;
  if Count > PSPRAMSize then
    Exit($80010016);
  if (Count <> 0) and not FMemory.IsValid(Address, Count) then
    Exit($800200D3);
  if Writing and (FileHandle.Flags and 2 = 0) then
    Exit($80010009);
  if not Writing and (FileHandle.Flags and 1 = 0) then
    Exit($80010009);
  Result := 0;
  var Data: TBytes;
  SetLength(Data, Min(Count, Cardinal(65536)));
  while Result < Count do
  begin
    var N := Integer(Min(Count - Result, Cardinal(Length(Data))));
    if Writing then
    begin
      Data := FMemory.ReadBytes(Address + Result, N);
      N := FileHandle.Stream.Write(Data[0], N);
    end
    else
    begin
      N := FileHandle.Stream.Read(Data[0], N);
      if N > 0 then
        FMemory.Load(Address + Result, Copy(Data, 0, N));
    end;
    if N = 0 then
      Break;
    Inc(Result, N);
  end;
  if FileHandle.BlockMode then
    Result := Result div 2048;
end;

function TPSPFileSystem.Seek(Id: Cardinal; Offset: Int64; Origin: Cardinal): Int64;
begin
  var FileHandle: TPSPFileHandle;
  if not FFiles.TryGetValue(Id, FileHandle) then
    Exit(Integer($80010009));
  if Origin > 2 then
    Exit(Integer($80010016));
  if FileHandle.BlockMode then
  begin
    if (Offset > High(Int64) div 2048) or (Offset < Low(Int64) div 2048) then
      Exit(Integer($80010016));
    Offset := Offset * 2048;
  end;
  var Position := Offset;
  if Origin = 1 then
    Position := FileHandle.Stream.Position + Offset;
  if Origin = 2 then
    Position := FileHandle.Stream.Size + Offset;
  if Position < 0 then
    Exit(Integer($80010016));
  Result := FileHandle.Stream.Seek(Position, soBeginning);
  if FileHandle.BlockMode then
    Result := Result div 2048;
end;

procedure TPSPFileSystem.WriteStat(Address: Cardinal; const Entry: TPSPDiscEntry; Disc: Boolean);

  procedure Clock(At: Cardinal; Value: TDateTime);
  begin
    if Value = 0 then
      Exit;
    var Y, M, D, H, N, S, MS: Word;
    DecodeDateTime(Value, Y, M, D, H, N, S, MS);
    FMemory.Write16(At, Y);
    FMemory.Write16(At + 2, M);
    FMemory.Write16(At + 4, D);
    FMemory.Write16(At + 6, H);
    FMemory.Write16(At + 8, N);
    FMemory.Write16(At + 10, S);
    FMemory.Write32(At + 12, Cardinal(MS) * 1000);
  end;

begin
  FMemory.Zero(Address, 88);
  var Access: Cardinal := $1FF;
  if Disc then
    Access := $16D;
  var Mode: Cardinal := $2000 or Access;
  var Attributes: Cardinal := $20;
  if Entry.Directory then
  begin
    Mode := $1000 or Access;
    Attributes := $10;
  end;
  FMemory.Write32(Address, Mode);
  FMemory.Write32(Address + 4, Attributes);
  FMemory.Write32(Address + 8, Cardinal(UInt64(Entry.Size) and $FFFFFFFF));
  FMemory.Write32(Address + 12, Cardinal(UInt64(Entry.Size) shr 32));
  Clock(Address + 16, Entry.Created);
  Clock(Address + 32, Entry.Accessed);
  Clock(Address + 48, Entry.Modified);
  if Disc then
    FMemory.Write32(Address + 64, Entry.LBA);
end;

function TPSPFileSystem.OpenDirectory(const Path: string): Cardinal;
begin
  var Name := Normalize(Path);
  var Handle := TPSPDirectoryHandle.Create;
  try
    Handle.Disc := Name.StartsWith('disc0:');
    if Handle.Disc then
    begin
      if FDisc = nil then
        Exit($80010013);
      Handle.Entries := FDisc.ReadDirectory(Name.Substring(7));
    end
    else
    begin
      var Host := HostPath(Name);
      if not TDirectory.Exists(Host) then
        Exit($80010002);
      var Entries := TList<TPSPDiscEntry>.Create;
      try
        var Entry := Default(TPSPDiscEntry);
        Entry.Name := '.';
        Entry.Directory := True;
        Entry.Created := TDirectory.GetCreationTime(Host);
        Entry.Accessed := TDirectory.GetLastAccessTime(Host);
        Entry.Modified := TDirectory.GetLastWriteTime(Host);
        Entries.Add(Entry);
        Entry.Name := '..';
        Entry.Size := 4096;
        Entries.Add(Entry);
        for var Item in TDirectory.GetFileSystemEntries(Host) do
        begin
          if Entries.Count >= 65536 then
            Exit($80020190);
          Entry := Default(TPSPDiscEntry);
          Entry.Name := TPath.GetFileName(Item);
          Entry.Directory := TDirectory.Exists(Item);
          if Entry.Directory then
          begin
            Entry.Created := TDirectory.GetCreationTime(Item);
            Entry.Accessed := TDirectory.GetLastAccessTime(Item);
            Entry.Modified := TDirectory.GetLastWriteTime(Item);
          end
          else
          begin
            var Stream := TFileStream.Create(Item, fmOpenRead or fmShareDenyNone);
            try
              Entry.Size := Stream.Size;
            finally
              Stream.Free;
            end;
            Entry.Created := TFile.GetCreationTime(Item);
            Entry.Accessed := TFile.GetLastAccessTime(Item);
            Entry.Modified := TFile.GetLastWriteTime(Item);
          end;
          Entries.Add(Entry);
        end;
        Handle.Entries := Entries.ToArray;
      finally
        Entries.Free;
      end;
    end;
    Result := FNextHandle;
    Inc(FNextHandle);
    FDirectories.Add(Result, Handle);
    Handle := nil;
  finally
    Handle.Free;
  end;
end;

function TPSPFileSystem.ReadDirectory(Id, Address: Cardinal): Cardinal;
begin
  var Handle: TPSPDirectoryHandle;
  if not FDirectories.TryGetValue(Id, Handle) then
    Exit($80010009);
  if not FMemory.IsValid(Address, 352) then
    Exit($800200D3);
  if Handle.Index >= Length(Handle.Entries) then
  begin
    FMemory.Write8(Address + 88, 0);
    Exit(0);
  end;
  var Entry := Handle.Entries[Handle.Index];
  WriteStat(Address, Entry, Handle.Disc);
  var Name := TEncoding.UTF8.GetBytes(Entry.Name);
  if Length(Name) > 255 then
    SetLength(Name, 255);
  FMemory.Zero(Address + 88, 256);
  FMemory.Load(Address + 88, Name);
  Inc(Handle.Index);
  Result := 1;
end;

function TPSPFileSystem.Ioctl(Id, Command, Input, InputSize, Output, OutputSize: Cardinal): Cardinal;
begin
  var FileHandle: TPSPFileHandle;
  if not FFiles.TryGetValue(Id, FileHandle) then
    Exit($80010009);
  if not FileHandle.Disc then
    Exit($80010086);
  Result := 0;
  case Command of
    $01020003, $01020004, $01020006, $01D20001:
      begin
        if (OutputSize < 4) or not FMemory.IsValid(Output, 4) then
          Exit($80010016);
        var Value: Cardinal := 2048;
        case Command of
          $01020004:
            Value := Cardinal(FileHandle.Stream.Position);
          $01020006:
            Value := FileHandle.LBA;
          $01D20001:
            Value := Cardinal(FileHandle.Stream.Position div 2048);
        end;
        FMemory.Write32(Output, Value);
      end;
    $01020007:
      begin
        if not FMemory.IsValid(Output, 8) then
          Exit($80010016);
        FMemory.Write32(Output, Cardinal(UInt64(FileHandle.Stream.Size) and $FFFFFFFF));
        FMemory.Write32(Output + 4, Cardinal(UInt64(FileHandle.Stream.Size) shr 32));
      end;
    $01020001:
      begin
        if (OutputSize < 2048) or not FMemory.IsValid(Output, 2048) then
          Exit($80010016);
        FMemory.Load(Output, FDisc.ReadSectors(16, 1));
      end;
    $01030008, $01F30003:
      begin
        if (InputSize < 4) or not FMemory.IsValid(Input, 4) then
          Exit($80010016);
        var Count := FMemory.Read32(Input);
        if Count > OutputSize then
          Exit($80010016);
        Result := Transfer(Id, Output, Count, False);
      end;
    $01010005, $01F100A6:
      begin
        if (InputSize < 4) or not FMemory.IsValid(Input, 16) then
          Exit($80010016);
        var Offset := Int64(UInt64(FMemory.Read32(Input)) or (UInt64(FMemory.Read32(Input + 4)) shl 32));
        var Position := Seek(Id, Offset, FMemory.Read32(Input + 12));
        if Position < 0 then
          Result := Cardinal(Position);
      end;
  else
    Result := $80010086;
  end;
end;

function TPSPFileSystem.Devctl(const Device: string; Command, Input, InputSize, Output, OutputSize: Cardinal): Cardinal;
begin
  Result := 0;
  var Name := Device.ToLower;
  if Name.StartsWith('umd') or Name.StartsWith('disc') then
  begin
    if FDisc = nil then
      Exit($80010013);
    case Command of
      $01F20001:
        if (OutputSize < 8) or not FMemory.IsValid(Output, 8) then
          Exit($80010016)
        else
          FMemory.Write32(Output + 4, $10);
      $01F20002:
        if (OutputSize < 4) or not FMemory.IsValid(Output, 4) then
          Exit($80010016)
        else
          FMemory.Write32(Output, 16);
      $01F20003:
        if (OutputSize < 4) or not FMemory.IsValid(Output, 4) then
          Exit($80010016)
        else
          FMemory.Write32(Output, FDisc.Size div 2048 - 1);
    else
      Result := $80010086;
    end;
    Exit;
  end;
  if not (Name.StartsWith('ms') or Name.StartsWith('fatms')) then
    Exit($80010013);
  case Command of
    $02015804, $02415821, $02015805, $02415822:
      begin
        if (InputSize < 4) or not FMemory.IsValid(Input, 4) then
          Exit($80010016);
        var Callback := FMemory.Read32(Input);
        var List := FMemoryStickCallbacks;
        if (Command = $02415821) or (Command = $02415822) then
          List := FFatCallbacks;
        if (Command = $02015804) or (Command = $02415821) then
        begin
          if (FKernel = nil) or (List.Count >= 32) or List.Contains(Callback) then
            Exit($80010016);
          var State: Cardinal := 1;
          if Command = $02415821 then
            State := FFatEnabled;
          if FKernel.NotifyCallback(Callback, State) <> 0 then
            Exit($80010016);
          List.Add(Callback);
        end
        else if List.Remove(Callback) < 0 then
          Exit($80010016);
      end;
    $02025801:
      if (OutputSize < 4) or not FMemory.IsValid(Output, 4) then
        Result := $80010016
      else
        FMemory.Write32(Output, 4);
    $02025806, $02425823:
      if ((Command = $02025806) and (OutputSize < 4)) or not FMemory.IsValid(Output, 4) then
        Result := $80010016
      else if Command = $02025806 then
        FMemory.Write32(Output, 1)
      else
        FMemory.Write32(Output, FFatEnabled);
    $02425824:
      if (OutputSize < 4) or not FMemory.IsValid(Output, 4) then
        Result := $80010016
      else
        FMemory.Write32(Output, 0);
    $02415823:
      if (InputSize < 4) or not FMemory.IsValid(Input, 4) then
        Result := $80010016
      else if FMemory.Read32(Input) > 1 then
        Result := $80010016
      else
        FFatEnabled := FMemory.Read32(Input);
    $02425818:
      begin
        if (InputSize < 4) or not FMemory.IsValid(Input, 4) then
          Exit($80010016);
        var Address := FMemory.Read32(Input);
        if not FMemory.IsValid(Address, 20) then
          Exit($80010016);
        // A formatted virtual 2 GiB card with 32 KiB allocation units.
        var Used: UInt64 := 0;
        for var FileName in TDirectory.GetFiles(FRoot, '*', TSearchOption.soAllDirectories) do
        begin
          var Stream := TFileStream.Create(FileName, fmOpenRead or fmShareDenyNone);
          try
            Inc(Used, (UInt64(Stream.Size) + 32767) div 32768);
          finally
            Stream.Free;
          end;
        end;
        FMemory.Write32(Address, 65532);
        FMemory.Write32(Address + 4, Cardinal(65532 - Min(UInt64(65532), Used)));
        FMemory.Write32(Address + 8, 65532 * 64);
        FMemory.Write32(Address + 12, 512);
        FMemory.Write32(Address + 16, 64);
      end;
  else
    Result := $80010086;
  end;
end;

function TPSPFileSystem.Stat(const Path: string; Address: Cardinal): Cardinal;
begin
  if not FMemory.IsValid(Address, 88) then
    Exit($800200D3);
  var Name := Normalize(Path);
  var Size: Int64 := 0;
  var Directory := False;
  if Name.StartsWith('disc0:') then
  begin
    if (FDisc = nil) or not FDisc.FileInfo(Name.Substring(7), Size, Directory) then
      Exit($80010002);
  end
  else
  begin
    var Host := HostPath(Name);
    Directory := TDirectory.Exists(Host);
    if not Directory then
    begin
      if not TFile.Exists(Host) then
        Exit($80010002);
      var Stream := TFileStream.Create(Host, fmOpenRead or fmShareDenyNone);
      try
        Size := Stream.Size;
      finally
        Stream.Free;
      end;
    end;
  end;
  var Entry := Default(TPSPDiscEntry);
  Entry.Size := Size;
  Entry.Directory := Directory;
  var Disc := Name.StartsWith('disc0:');
  if Disc then
    Entry.LBA := FDisc.FileLBA(Name.Substring(7))
  else if Directory then
  begin
    Entry.Created := TDirectory.GetCreationTime(HostPath(Name));
    Entry.Accessed := TDirectory.GetLastAccessTime(HostPath(Name));
    Entry.Modified := TDirectory.GetLastWriteTime(HostPath(Name));
  end
  else
  begin
    Entry.Created := TFile.GetCreationTime(HostPath(Name));
    Entry.Accessed := TFile.GetLastAccessTime(HostPath(Name));
    Entry.Modified := TFile.GetLastWriteTime(HostPath(Name));
  end;
  WriteStat(Address, Entry, Disc);
  Result := 0;
end;

function TPSPFileSystem.ReadProgram(const Path: string): TPSPProgram;
begin
  var Id := Open(Path, 1);
  if Id and $80000000 <> 0 then
    raise EFOpenError.CreateFmt('PSP: module file not found: %s', [Path]);
  try
    Result := TPSPProgram.Read(FFiles[Id].Stream);
    Result.BootPath := Normalize(Path);
  finally
    FFiles.Remove(Id);
  end;
end;

function TPSPFileSystem.ReadProgram(Id: Cardinal; out ProgramData: TPSPProgram): Cardinal;
begin
  ProgramData := Default(TPSPProgram);
  var FileHandle: TPSPFileHandle;
  if not FFiles.TryGetValue(Id, FileHandle) then
    Exit($80010009);
  var Size := FileHandle.Stream.Size - FileHandle.Stream.Position;
  if (Size < 4) or (Size > 64 * 1024 * 1024) then
    Exit($80020148);
  var Data: TBytes;
  SetLength(Data, Size);
  FileHandle.Stream.ReadBuffer(Data[0], Length(Data));
  var Input := TBytesStream.Create(Data);
  try
    ProgramData := TPSPProgram.Read(Input)
  finally
    Input.Free
  end;
  Result := 0;
end;

procedure TPSPFileSystem.AsyncResult(FileHandle: TPSPFileHandle; Value: Int64);
begin
  FileHandle.AsyncResult := Value;
  FileHandle.AsyncPending := True;
  FileHandle.AsyncNotified := False;
  FileHandle.AsyncReady := 0;
  if FKernel <> nil then
  begin
    FileHandle.AsyncReady := FKernel.Time + 100;
    FKernel.ScheduleDeviceEvent(FileHandle.AsyncReady);
  end;
end;

procedure TPSPFileSystem.Advance(Time: UInt64);
begin
  var Closing := TList<Cardinal>.Create;
  try
    for var Pair in FFiles do
    begin
      var FileHandle := Pair.Value;
      if not FileHandle.AsyncPending or (Time < FileHandle.AsyncReady) then
        Continue;
      if not FileHandle.AsyncNotified then
      begin
        if (FKernel <> nil) and (FileHandle.CallbackId <> 0) then
          FKernel.NotifyCallback(FileHandle.CallbackId, FileHandle.CallbackArgument);
        FileHandle.AsyncNotified := True;
      end;
      if FileHandle.WaiterThread = 0 then
        Continue;
      if (FKernel <> nil) and FKernel.IsWaitingDevice(FileHandle.WaiterThread, 5, Pair.Key) then
      begin
        var Address := FileHandle.WaiterOutput;
        FMemory.Write32(Address, Cardinal(UInt64(FileHandle.AsyncResult) and $FFFFFFFF));
        FMemory.Write32(Address + 4, Cardinal(UInt64(FileHandle.AsyncResult) shr 32));
        FileHandle.AsyncPending := False;
        FKernel.CompleteDevice(5, Pair.Key, 0);
        if FileHandle.AsyncClosing then
          Closing.Add(Pair.Key);
      end;
      FileHandle.WaiterThread := 0;
      FileHandle.WaiterOutput := 0;
    end;
    for var Id in Closing do
      FFiles.Remove(Id);
  finally
    Closing.Free;
  end;
end;

function TPSPFileSystem.PollAsync(Id, Address: Cardinal; Poll: Boolean): Cardinal;
begin
  var FileHandle: TPSPFileHandle;
  if not FFiles.TryGetValue(Id, FileHandle) then
    Exit($80010009);
  if not FileHandle.AsyncPending then
    Exit($8002032A);
  if (Address = 0) or not FMemory.IsValid(Address, 8) then
    Exit($800200D3);
  if (FKernel <> nil) and (FKernel.Time < FileHandle.AsyncReady) then
  begin
    if Poll then
      Exit(1);
    if (FileHandle.WaiterThread <> 0) and (FileHandle.WaiterThread <> FKernel.CurrentThreadId) then
      Exit($80020329);
    FileHandle.WaiterThread := FKernel.CurrentThreadId;
    FileHandle.WaiterOutput := Address;
    FKernel.WaitDevice(5, Id);
    Exit(0);
  end;
  if not FileHandle.AsyncNotified and (FKernel <> nil) and (FileHandle.CallbackId <> 0) then
    FKernel.NotifyCallback(FileHandle.CallbackId, FileHandle.CallbackArgument);
  FileHandle.AsyncNotified := True;
  FMemory.Write32(Address, Cardinal(UInt64(FileHandle.AsyncResult) and $FFFFFFFF));
  FMemory.Write32(Address + 4, Cardinal(UInt64(FileHandle.AsyncResult) shr 32));
  FileHandle.AsyncPending := False;
  Result := 0;
  if FileHandle.AsyncClosing then
    FFiles.Remove(Id);
end;

function TPSPFileSystem.Handle(NID: Cardinal; out Value: Cardinal): Boolean;
begin
  Result := True;
  Value := 0;
  var A := FCPU.Registers[4];
  var B := FCPU.Registers[5];
  var C := FCPU.Registers[6];
  try
    case NID of
      $63632449, $E95A012B:
        begin
          var FileHandle: TPSPFileHandle;
          if not FFiles.TryGetValue(A, FileHandle) then
            Value := $80010009
          else if FileHandle.AsyncPending then
            Value := $80020329
          else
          begin
            Value := Ioctl(A, B, C, FCPU.Registers[7], FCPU.Registers[8], FCPU.Registers[9]);
            if NID = $E95A012B then
            begin
              AsyncResult(FileHandle, Integer(Value));
              Value := 0;
            end;
          end;
        end;
      $A12A0514:
        begin
          var FileHandle: TPSPFileHandle;
          if not FFiles.TryGetValue(A, FileHandle) then
            Value := $80010009
          else
          begin
            FileHandle.CallbackId := B;
            FileHandle.CallbackArgument := C;
          end;
        end;
      $B29DDF9C:
        Value := OpenDirectory(FMemory.ReadString(A, 1024));
      $E3EB004C:
        Value := ReadDirectory(A, B);
      $EB092469:
        if FDirectories.ContainsKey(A) then
          FDirectories.Remove(A)
        else
          Value := $80010009;
      $54F5FB11:
        begin
          Value := Devctl(FMemory.ReadString(A, 128), B, C, FCPU.Registers[7], FCPU.Registers[8], FCPU.Registers[9]);
          {$IFDEF PSP_TRACE_IO}                               Writeln('devctl ', FMemory.ReadString(A, 128), ' cmd=', IntToHex(B, 8), ' in=', FCPU.Registers[7], ' out=', FCPU.Registers[9], ' result=', IntToHex(Value, 8)); {$ENDIF}
        end;
      $89AA9906:
        begin
          Value := Open(FMemory.ReadString(A, 1024), B);
          if Value and $80000000 = 0 then
            AsyncResult(FFiles[Value], Value);
        end;
      $3251EA56:
        Value := PollAsync(A, B, True);
      $E23EEC33, $35DBD746:
        begin
          Value := PollAsync(A, B, False);
          if (NID = $35DBD746) and (Value = 0) and (FKernel <> nil) and FKernel.IsWaitingDevice(FKernel.CurrentThreadId, 5, A) then
            FKernel.AcceptCallbacks;
        end;
      $CB05F8D6:
        Value := PollAsync(A, C, B <> 0);
      $FF5940B6, $A0B5A7C2, $0FACAB19, $1B385D8F, $71B19E77:
        begin
          var FileHandle: TPSPFileHandle;
          if not FFiles.TryGetValue(A, FileHandle) then
            Value := $80010009
          else if FileHandle.AsyncPending then
            Value := $80020329
          else
          begin
            var OperationResult: Int64 := 0;
            case NID of
              $FF5940B6:
                begin
                  FreeAndNil(FileHandle.Stream);
                  FileHandle.AsyncClosing := True;
                end;
              $A0B5A7C2:
                OperationResult := Integer(Transfer(A, B, C, False));
              $0FACAB19:
                OperationResult := Integer(Transfer(A, B, C, True));
              $1B385D8F:
                OperationResult := Seek(A, Integer(B), C);
              $71B19E77:
                OperationResult := Seek(A, Int64(UInt64(C) or (UInt64(FCPU.Registers[7]) shl 32)), FCPU.Registers[8]);
            end;
            AsyncResult(FileHandle, OperationResult);
          end;
        end;
      $109F50BC:
        Value := Open(FMemory.ReadString(A, 1024), B);
      $810C4BC3:
        if not FFiles.ContainsKey(A) then
          Value := $80010009
        else if FFiles[A].AsyncPending then
          Value := $80020329
        else
          FFiles.Remove(A);
      $6A638D83:
        Value := Transfer(A, B, C, False);
      $42EC03AC:
        Value := Transfer(A, B, C, True);
      $68963324:
        Value := Cardinal(Seek(A, Integer(B), C));
      $27EB27B8:
        begin
          var Offset := Int64(UInt64(C) or (UInt64(FCPU.Registers[7]) shl 32));
          var Position := Seek(A, Offset, FCPU.Registers[8]);
          Value := Cardinal(UInt64(Position) and $FFFFFFFF);
          FCPU.Registers[3] := Cardinal(UInt64(Position) shr 32);
        end;
      $55F4717D:
        begin
          var NewPath := Normalize(FMemory.ReadString(A, 1024));
          var Directory := False;
          var Size: Int64;
          if NewPath.StartsWith('disc0:') then
          begin
            if (FDisc <> nil) and FDisc.FileInfo(NewPath.Substring(7), Size, Directory) and Directory then
              FCwd := NewPath
            else
              Value := $80010002;
          end
          else if TDirectory.Exists(HostPath(NewPath)) then
            FCwd := NewPath
          else
            Value := $80010002;
        end;
      $ACE946E8:
        Value := Stat(FMemory.ReadString(A, 1024), B);
      $06A70004:
        begin
          var Path := Normalize(FMemory.ReadString(A, 1024));
          if Path.StartsWith('disc0:') then
            Value := $8001001E
          else if not ForceDirectories(HostPath(Path)) then
            Value := $80010005;
        end;
      $B293727F:
        begin
          var Priority := Integer(B);
          if (Priority <> -1) and ((Priority < 8) or (Priority > 119)) then
            Value := $80020193
          else if A = $FFFFFFFF then
            FAsyncPriority := Priority
          else if FFiles.ContainsKey(A) then
            FFiles[A].AsyncPriority := Priority
          else
            Value := $80010009;
        end;
    else
      Result := False;
    end;
  except
    on E: EFOpenError do
      Value := $80010002;
    on E: EWriteError do
      Value := $8001001E;
    on E: EArgumentException do
      Value := $80010016;
    on E: EStreamError do
      Value := $80010005;
  end;
end;

end.

