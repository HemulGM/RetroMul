unit PS2.IOP.FileIO;

// High-level IOP file services: the ioman device table (tty, host, cdrom0,
// rom0, mc0 through TPS2FileSystem) and the FILEIO RPC server (SID
// 80000001h, the version 1000/2xxx protocol the EE libraries use).
// References: ps2sdk fileio-common.h (AFL 2.0; structures of the 1000
// protocol).
{$IFDEF PS2_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, System.Classes, System.Math, System.Generics.Collections, Core.Snapshots, PS2.Types, PS2.SIF;

type
  // A file source for a device prefix ('host', 'cdrom0', 'rom0'...).
  TPS2FileSystem = class
  public
    // Whole-file reads keep the core deterministic and serializable; nil
    // when missing.
    function ReadFile(const Device, Path: string): TBytes; virtual; abstract;
    function WriteFile(const Device, Path: string; const Data: TBytes): Boolean; virtual;
    function FileSize(const Device, Path: string): Int64; virtual;
    // Reads Count bytes at Offset (large disc files).
    function ReadAt(const Device, Path: string; Offset: Int64; Count: Integer): TBytes; virtual;
  end;

  // The memory card device (mc0:, mc1:) MCMAN registers with ioman: files
  // and directories on the card file system, MCMAN's handles. Results are
  // ioman's (negative errno); Stat is an io_stat_t, Dirent an io_dirent_t.
  TPS2CardDevice = class
  public
    function Open(Port: Integer; const Path: string; Flags: Integer): Integer; virtual; abstract;
    function Close(Handle: Integer): Integer; virtual; abstract;
    function Read(Handle, Count: Integer; out Data: TBytes): Integer; virtual; abstract;
    function Write(Handle: Integer; const Data: TBytes): Integer; virtual; abstract;
    function Seek(Handle, Offset, Whence: Integer): Integer; virtual; abstract;
    function MakeDir(Port: Integer; const Path: string): Integer; virtual; abstract;
    function Remove(Port: Integer; const Path: string): Integer; virtual; abstract;
    function GetStat(Port: Integer; const Path: string; out Stat: TBytes): Integer; virtual; abstract;
    // 1 and the next entry of an open directory, 0 at its end.
    function DirRead(Handle: Integer; out Dirent: TBytes): Integer; virtual; abstract;
  end;

  TPS2OpenFile = record
    Used: Boolean;
    Device, Path: string;
    Position, Size: Int64;
    Mode: Integer;
    // The card device's handle (files on mc0:/mc1:).
    Handle: Integer;
  end;

  TPS2IOMan = class
  private
    FFS: TPS2FileSystem;
    FCards: TPS2CardDevice;
    FFiles: array[0..63] of TPS2OpenFile;
    FOnTTY: TProc<string>;
    function CardPort(const Device: string): Integer;
    function NewFile: Integer;
    function IsCardFile(Fd: Integer): Boolean;
  public
    constructor Create(FS: TPS2FileSystem);
    procedure Reset;
    class procedure SplitPath(const Name: string; out Device, Path: string); static;
    // Devices of the expansion bay (HDD, its file system, network): nothing
    // is there, ioman finds no such device.
    class function IsAbsentDevice(const Name: string): Boolean; static;
    function Open(const Name: string; Mode: Integer): Integer;
    function Close(Fd: Integer): Integer;
    function Read(Fd: Integer; Count: Integer; out Data: TBytes): Integer;
    function Write(Fd: Integer; const Data: TBytes): Integer;
    function Seek(Fd: Integer; Offset: Int64; Whence: Integer): Int64;
    function GetStat(const Name: string; out Size: Int64): Integer; overload;
    // The io_stat_t of Name (files elsewhere: a regular file of their size).
    function GetStat(const Name: string; out Stat: TBytes): Integer; overload;
    function MakeDir(const Name: string): Integer;
    function Remove(const Name: string): Integer;
    function DirOpen(const Name: string): Integer;
    function DirRead(Fd: Integer; out Dirent: TBytes): Integer;
    procedure SerializeState(State: TStateArchive);
    property FileSystem: TPS2FileSystem read FFS write FFS;
    property Cards: TPS2CardDevice read FCards write FCards;
    property OnTTY: TProc<string> read FOnTTY write FOnTTY;
  end;

  TPS2FileIOServer = class(TPS2RPCServer)
  private
    FIOMan: TPS2IOMan;
    // EE buffer for result records (2200 protocol).
    FRecordAddress: Cardinal;
    procedure WriteEE(Address: Cardinal; const Data: TBytes);
    function ReadEE(Address: Cardinal; Count: Integer): TBytes;
    function CallRecord(Fn: Cardinal; Args: PByte; Size: Integer): TBytes;
  public
    // FILEIO module version of the IOP image (1000, 2100, 2200...): from
    // 2200 on, results come back as records (see CallRecord).
    Version: Integer;
    // Diagnostics: calls with their first string argument and result.
    Log: TStrings;
    constructor Create(IOMan: TPS2IOMan);
    procedure Reset; override;
    function Call(Fn: Cardinal; Args: PByte; Size: Integer; ReplySize: Integer): TBytes; override;
    procedure SerializeState(State: TStateArchive); override;
  end;

function IntBytes(Value: Integer): TBytes;

implementation

function IntBytes(Value: Integer): TBytes;
begin
  SetLength(Result, 4);
  PInteger(@Result[0])^ := Value;
end;

const
  // io_stat_t mode of a regular file.
  StatFile = $2000;

function IsCardPath(const Name: string): Boolean;
begin
  var Device, Path: string;
  TPS2IOMan.SplitPath(Name, Device, Path);
  Result := (Device = 'mc') or (Device = 'mc0') or (Device = 'mc1');
end;

// io_stat_t: mode, attribute, size, three times, high size word.
function StatRecord(Size: Int64): TBytes;
begin
  SetLength(Result, 64);
  FillChar(Result[0], 64, 0);
  PCardinal(@Result[0])^ := StatFile;
  PCardinal(@Result[8])^ := Cardinal(Size);
  PCardinal(@Result[36])^ := Cardinal(Size shr 32);
end;

{ TPS2FileSystem }

function TPS2FileSystem.WriteFile(const Device, Path: string; const Data: TBytes): Boolean;
begin
  Result := False;
end;

function TPS2FileSystem.FileSize(const Device, Path: string): Int64;
begin
  var D := ReadFile(Device, Path);
  if D = nil then
    Result := -1
  else
    Result := Length(D);
end;

function TPS2FileSystem.ReadAt(const Device, Path: string; Offset: Int64; Count: Integer): TBytes;
begin
  var D := ReadFile(Device, Path);
  if (D = nil) or (Offset >= Length(D)) or (Count <= 0) then
    Exit(nil);
  if Offset + Count > Length(D) then
    Count := Length(D) - Integer(Offset);
  Result := Copy(D, Integer(Offset), Count);
end;

{ TPS2IOMan }

constructor TPS2IOMan.Create(FS: TPS2FileSystem);
begin
  inherited Create;
  FFS := FS;
  Reset;
end;

procedure TPS2IOMan.Reset;
begin
  for var K := 0 to High(FFiles) do
    FFiles[K] := Default(TPS2OpenFile);
end;

class procedure TPS2IOMan.SplitPath(const Name: string; out Device, Path: string);
begin
  var Colon := Name.IndexOf(':');
  if Colon < 0 then
  begin
    Device := 'host';
    Path := Name;
  end
  else
  begin
    Device := Name.Substring(0, Colon).ToLower;
    Path := Name.Substring(Colon + 1);
  end;
  // cdrom0:\FILE.ELF;1 -> FILE.ELF
  Path := Path.Replace('\', '/');
  while Path.StartsWith('/') do
    Path := Path.Substring(1);
  var Semi := Path.LastIndexOf(';');
  if Semi >= 0 then
    Path := Path.Substring(0, Semi);
  if (Device = 'cdrom') or (Device = 'cdrom1') then
    Device := 'cdrom0';
end;

class function TPS2IOMan.IsAbsentDevice(const Name: string): Boolean;
begin
  var Colon := Name.IndexOf(':');
  if Colon < 0 then
    Exit(False);
  var Device := Name.Substring(0, Colon).ToLower;
  while (Device <> '') and CharInSet(Device[Length(Device)], ['0'..'9']) do
    Delete(Device, Length(Device), 1);
  Result := (Device = 'hdd') or (Device = 'pfs') or (Device = 'dev9x') or (Device = 'smap') or (Device = 'xhdd');
end;

// mc0: / mc: is port 0, mc1: port 1; -1 for other devices.
function TPS2IOMan.CardPort(const Device: string): Integer;
begin
  Result := -1;
  if FCards = nil then
    Exit;
  if (Device = 'mc') or (Device = 'mc0') then
    Result := 0
  else if Device = 'mc1' then
    Result := 1;
end;

function TPS2IOMan.NewFile: Integer;
begin
  for var K := 3 to High(FFiles) do
    if not FFiles[K].Used then
      Exit(K);
  Result := -1;
end;

function TPS2IOMan.IsCardFile(Fd: Integer): Boolean;
begin
  Result := (Fd >= 3) and (Fd <= High(FFiles)) and FFiles[Fd].Used and (CardPort(FFiles[Fd].Device) >= 0);
end;

function TPS2IOMan.Open(const Name: string; Mode: Integer): Integer;
begin
  if IsAbsentDevice(Name) then
    Exit(-19);
  var Device, Path: string;
  SplitPath(Name, Device, Path);
  if (Device = 'tty') or (Device = 'tty0') then
    Exit(1);
  var Port := CardPort(Device);
  if Port >= 0 then
  begin
    var K := NewFile;
    if K < 0 then
      Exit(-24);
    var H := FCards.Open(Port, Path, Mode);
    if H < 0 then
      Exit(H);
    FFiles[K] := Default(TPS2OpenFile);
    FFiles[K].Used := True;
    FFiles[K].Device := Device;
    FFiles[K].Path := Path;
    FFiles[K].Mode := Mode;
    FFiles[K].Handle := H;
    Exit(K);
  end;
  if FFS = nil then
    Exit(-2);
  var Size := FFS.FileSize(Device, Path);
  var Creating := (Mode and $200) <> 0;
  if (Size < 0) and not Creating then
    Exit(-2);
  for var K := 3 to High(FFiles) do
    if not FFiles[K].Used then
    begin
      FFiles[K].Used := True;
      FFiles[K].Device := Device;
      FFiles[K].Path := Path;
      FFiles[K].Position := 0;
      if Size < 0 then
        Size := 0;
      FFiles[K].Size := Size;
      FFiles[K].Mode := Mode;
      Exit(K);
    end;
  Result := -24;
end;

function TPS2IOMan.Close(Fd: Integer): Integer;
begin
  if IsCardFile(Fd) then
  begin
    FFiles[Fd].Used := False;
    Exit(FCards.Close(FFiles[Fd].Handle));
  end;
  if (Fd >= 3) and (Fd <= High(FFiles)) and FFiles[Fd].Used then
  begin
    FFiles[Fd].Used := False;
    Exit(0);
  end;
  if (Fd >= 0) and (Fd < 3) then
    Exit(0);
  Result := -9;
end;

function TPS2IOMan.Read(Fd: Integer; Count: Integer; out Data: TBytes): Integer;
begin
  Data := nil;
  if IsCardFile(Fd) then
    Exit(FCards.Read(FFiles[Fd].Handle, Count, Data));
  if (Fd < 3) or (Fd > High(FFiles)) or not FFiles[Fd].Used then
    Exit(-9);
  if Count <= 0 then
    Exit(0);
  var Left := FFiles[Fd].Size - FFiles[Fd].Position;
  if Left <= 0 then
    Exit(0);
  if Count > Left then
    Count := Integer(Left);
  Data := FFS.ReadAt(FFiles[Fd].Device, FFiles[Fd].Path, FFiles[Fd].Position, Count);
  Inc(FFiles[Fd].Position, Length(Data));
  Result := Length(Data);
end;

function TPS2IOMan.Write(Fd: Integer; const Data: TBytes): Integer;
begin
  if (Fd >= 0) and (Fd < 3) or (Fd = 1) then
  begin
    if Assigned(FOnTTY) and (Length(Data) > 0) then
      FOnTTY(TEncoding.ANSI.GetString(Data));
    Exit(Length(Data));
  end;
  if IsCardFile(Fd) then
    Exit(FCards.Write(FFiles[Fd].Handle, Data));
  if (Fd > High(FFiles)) or (Fd < 0) or not FFiles[Fd].Used then
    Exit(-9);
  // Writes go to the file system as a whole file.
  var Old := FFS.ReadFile(FFiles[Fd].Device, FFiles[Fd].Path);
  var EndPos := FFiles[Fd].Position + Length(Data);
  if EndPos > Length(Old) then
    SetLength(Old, EndPos);
  if Length(Data) > 0 then
    Move(Data[0], Old[FFiles[Fd].Position], Length(Data));
  if not FFS.WriteFile(FFiles[Fd].Device, FFiles[Fd].Path, Old) then
    Exit(-5);
  FFiles[Fd].Position := EndPos;
  FFiles[Fd].Size := Length(Old);
  Result := Length(Data);
end;

function TPS2IOMan.Seek(Fd: Integer; Offset: Int64; Whence: Integer): Int64;
begin
  if IsCardFile(Fd) then
    Exit(FCards.Seek(FFiles[Fd].Handle, Integer(Offset), Whence));
  if (Fd < 3) or (Fd > High(FFiles)) or not FFiles[Fd].Used then
    Exit(-9);
  case Whence of
    0: FFiles[Fd].Position := Offset;
    1: FFiles[Fd].Position := FFiles[Fd].Position + Offset;
    2: FFiles[Fd].Position := FFiles[Fd].Size + Offset;
  end;
  if FFiles[Fd].Position < 0 then
    FFiles[Fd].Position := 0;
  Result := FFiles[Fd].Position;
end;

function TPS2IOMan.GetStat(const Name: string; out Size: Int64): Integer;
begin
  Size := -1;
  if IsAbsentDevice(Name) then
    Exit(-19);
  var Device, Path: string;
  SplitPath(Name, Device, Path);
  if FFS <> nil then
    Size := FFS.FileSize(Device, Path);
  if Size < 0 then
    Result := -2
  else
    Result := 0;
end;

function TPS2IOMan.GetStat(const Name: string; out Stat: TBytes): Integer;
begin
  Stat := nil;
  var Device, Path: string;
  SplitPath(Name, Device, Path);
  var Port := CardPort(Device);
  if Port >= 0 then
    Exit(FCards.GetStat(Port, Path, Stat));
  var Size: Int64;
  Result := GetStat(Name, Size);
  if Result = 0 then
    Stat := StatRecord(Size);
end;

// Directories exist only on the card; elsewhere nothing is done (and
// directories do not open), unless the device is absent.
function TPS2IOMan.MakeDir(const Name: string): Integer;
begin
  if IsAbsentDevice(Name) then
    Exit(-19);
  var Device, Path: string;
  SplitPath(Name, Device, Path);
  var Port := CardPort(Device);
  if Port >= 0 then
    Result := FCards.MakeDir(Port, Path)
  else
    Result := 0;
end;

function TPS2IOMan.Remove(const Name: string): Integer;
begin
  if IsAbsentDevice(Name) then
    Exit(-19);
  var Device, Path: string;
  SplitPath(Name, Device, Path);
  var Port := CardPort(Device);
  if Port >= 0 then
    Result := FCards.Remove(Port, Path)
  else
    Result := 0;
end;

function TPS2IOMan.DirOpen(const Name: string): Integer;
begin
  if IsAbsentDevice(Name) then
    Exit(-19);
  var Device, Path: string;
  SplitPath(Name, Device, Path);
  if CardPort(Device) < 0 then
    Exit(-2);
  // A directory opens like a file on the card (MCMAN's dopen).
  Result := Open(Name, 0);
end;

function TPS2IOMan.DirRead(Fd: Integer; out Dirent: TBytes): Integer;
begin
  Dirent := nil;
  if not IsCardFile(Fd) then
    Exit(-9);
  Result := FCards.DirRead(FFiles[Fd].Handle, Dirent);
end;

procedure TPS2IOMan.SerializeState(State: TStateArchive);
begin
  for var K := 0 to High(FFiles) do
  begin
    State.Field(FFiles[K].Used, SizeOf(Boolean));
    State.Field(FFiles[K].Position, SizeOf(Int64));
    State.Field(FFiles[K].Size, SizeOf(Int64));
    State.Field(FFiles[K].Mode, SizeOf(Integer));
    State.Field(FFiles[K].Handle, SizeOf(Integer));
    var S := FFiles[K].Device + '|' + FFiles[K].Path;
    var B := TEncoding.UTF8.GetBytes(S);
    var N := Length(B);
    State.Field(N, SizeOf(N));
    if State.Loading then
    begin
      if (N < 0) or (N > 4096) then
        raise EReadError.Create('PS2 snapshot file table');
      SetLength(B, N);
    end;
    if N > 0 then
      State.Field(B[0], N);
    if State.Loading then
    begin
      S := TEncoding.UTF8.GetString(B);
      var Bar := S.IndexOf('|');
      FFiles[K].Device := S.Substring(0, Bar);
      FFiles[K].Path := S.Substring(Bar + 1);
    end;
  end;
end;

{ TPS2FileIOServer }

const
  FnOpen = 0;
  FnClose = 1;
  FnRead = 2;
  FnWrite = 3;
  FnSeek = 4;
  FnRemove = 6;
  FnMkdir = 7;
  FnRmdir = 8;
  FnDOpen = 9;
  FnDClose = 10;
  FnDRead = 11;
  FnGetStat = 12;
  FnSeek64 = 22;
  FnInit = $FF;
  // Errors (negative errno).
  ErrNoEntry = -2;
  ErrNoDevice = -19;
  // Result record command (2200 protocol).
  CmdResult = $80000011;

constructor TPS2FileIOServer.Create(IOMan: TPS2IOMan);
begin
  inherited Create($80000001);
  FIOMan := IOMan;
  Version := 1000;
end;

procedure TPS2FileIOServer.WriteEE(Address: Cardinal; const Data: TBytes);
begin
  if Length(Data) = 0 then
    Exit;
  var A := Address and PS2RAMMask;
  var N := Length(Data);
  if A + Cardinal(N) > PS2RAMSize then
    N := Integer(PS2RAMSize - A);
  Move(Data[0], (FSIF.EERAM + A)^, N);
  FSIF.MarkEE(A, Cardinal(N));
end;

function TPS2FileIOServer.ReadEE(Address: Cardinal; Count: Integer): TBytes;
begin
  Result := nil;
  var A := Address and PS2RAMMask;
  if (Count <= 0) or (A + Cardinal(Count) > PS2RAMSize) then
    Exit;
  SetLength(Result, Count);
  Move((FSIF.EERAM + A)^, Result[0], Count);
end;

function ArgString(Args: PByte; Size, Offset, Max: Integer): string;
begin
  var B: TBytes;
  for var K := 0 to Min(Max, Size - Offset) - 1 do
  begin
    var C := Args[Offset + K];
    if C = 0 then
      Break;
    B := B + [C];
  end;
  Result := TEncoding.ANSI.GetString(B);
end;

function ArgU32(Args: PByte; Size, Offset: Integer): Cardinal;
begin
  if Offset + 4 > Size then
    Exit(0);
  Result := PCardinal(Args + Offset)^;
end;

// The path of a 2200 request without a documented layout: at +0Ch when it
// names a device there, else at +10h (after a mode word).
function RecordName(Args: PByte; Size: Integer): string;
begin
  Result := ArgString(Args, Size, 12, 1024);
  if not Result.Contains(':') then
    Result := ArgString(Args, Size, 16, 1024);
end;

procedure TPS2FileIOServer.Reset;
begin
  FRecordAddress := 0;
end;

procedure TPS2FileIOServer.SerializeState(State: TStateArchive);
begin
  State.Field(Version, SizeOf(Version));
  State.Field(FRecordAddress, SizeOf(FRecordAddress));
end;

// FILEIO 2200 and later:
// a request is (semaphore, result address, result size) and the function's
// own words from +0Ch; the RPC reply is only a nonzero word. The answer is a
// record put in the EE buffer named by function FFh and announced by SIF
// command 80000011h: the semaphore, the function, the result address and
// size, the result from +10h; read leaves the unaligned head and tail at
// +14h empty, getstat puts the stat address at +14h and the stat at +18h.
// The EE copies the result to its address and signals the semaphore.
// Requests: open (flags +0Ch, mode +10h, name +14h), close (fd +0Ch), read
// (fd, buffer, size), write (fd, buffer, size, head count +18h, head bytes
// +1Ch), lseek (fd, offset, whence), getstat (stat address, name +10h),
// lseek64 (fd, 64-bit offset +10h, whence +18h; 64-bit result).
function TPS2FileIOServer.CallRecord(Fn: Cardinal; Args: PByte; Size: Integer): TBytes;
var
  Rec: TBytes;
begin
  SetLength(Rec, 32);
  FillChar(Rec[0], 32, 0);
  PCardinal(@Rec[0])^ := ArgU32(Args, Size, 0);
  PCardinal(@Rec[4])^ := Fn;
  PCardinal(@Rec[8])^ := ArgU32(Args, Size, 4);
  PCardinal(@Rec[12])^ := ArgU32(Args, Size, 8);
  var Fd := Integer(ArgU32(Args, Size, 12));
  var R: Int64 := ErrNoDevice;
  case Fn of
    FnOpen:
      R := FIOMan.Open(ArgString(Args, Size, 20, 1024), Integer(ArgU32(Args, Size, 12)));
    FnClose:
      R := FIOMan.Close(Fd);
    FnRead:
      begin
        var Data: TBytes;
        R := FIOMan.Read(Fd, Integer(ArgU32(Args, Size, 20)), Data);
        WriteEE(ArgU32(Args, Size, 16), Data);
      end;
    FnWrite:
      R := FIOMan.Write(Fd, ReadEE(ArgU32(Args, Size, 16), Integer(ArgU32(Args, Size, 20))));
    FnSeek:
      R := FIOMan.Seek(Fd, Integer(ArgU32(Args, Size, 16)), Integer(ArgU32(Args, Size, 20)));
    FnSeek64:
      if Size >= 28 then
      begin
        R := FIOMan.Seek(Fd, PInt64(Args + 16)^, Integer(ArgU32(Args, Size, 24)));
        PInt64(@Rec[16])^ := R;
      end;
    FnGetStat:
      begin
        var St: TBytes;
        R := FIOMan.GetStat(ArgString(Args, Size, 16, 1024), St);
        SetLength(Rec, 24 + 64);
        FillChar(Rec[16], Length(Rec) - 16, 0);
        PCardinal(@Rec[20])^ := ArgU32(Args, Size, 12);
        if R = 0 then
        begin
          Move(St[0], Rec[24], Min(Length(St), 64));
          WriteEE(ArgU32(Args, Size, 12), St);
        end;
      end;
    FnDOpen:
      if IsCardPath(RecordName(Args, Size)) then
        R := FIOMan.DirOpen(RecordName(Args, Size))
      else
        R := ErrNoEntry;
    FnDClose:
      R := FIOMan.Close(Fd);
    FnDRead:
      begin
        var Dirent: TBytes;
        R := FIOMan.DirRead(Fd, Dirent);
        if R > 0 then
          WriteEE(ArgU32(Args, Size, 16), Dirent);
      end;
    FnMkdir, FnRemove, FnRmdir:
      if IsCardPath(RecordName(Args, Size)) then
      begin
        if Fn = FnMkdir then
          R := FIOMan.MakeDir(RecordName(Args, Size))
        else
          R := FIOMan.Remove(RecordName(Args, Size));
      end
      else if TPS2IOMan.IsAbsentDevice(ArgString(Args, Size, 12, 1024)) or
        TPS2IOMan.IsAbsentDevice(ArgString(Args, Size, 16, 1024)) then
        R := ErrNoDevice
      else
        R := 0;
  else
    // Directories, devices and the rest (mount, devctl, format...): nothing
    // to do, unless the device named first is not there.
    if TPS2IOMan.IsAbsentDevice(ArgString(Args, Size, 12, 1024)) or
      TPS2IOMan.IsAbsentDevice(ArgString(Args, Size, 16, 1024)) then
      R := ErrNoDevice
    else
      R := 0;
  end;
  if Fn <> FnSeek64 then
    PInteger(@Rec[16])^ := Integer(R);
  if Log <> nil then
    Log.Add(Format('fileio %d "%s" "%s" -> %d', [Fn, ArgString(Args, Size, 12, 1024), ArgString(Args, Size, 20, 1024),
      R]));
  if FRecordAddress <> 0 then
    FSIF.SendData(FRecordAddress, Rec);
  var Cmd: TBytes;
  SetLength(Cmd, 16);
  FillChar(Cmd[0], 16, 0);
  FSIF.SendCommand(CmdResult, Cmd);
  Result := IntBytes(1);
end;

// Function FFh starts the service (from 2200 on its word is the address for
// result records); the reply is the version in ASCII. Up to version 2100
// each call answers in its RPC reply with the argument blocks of ps2sdk's
// fileio: open (mode, name), close (fd), read (fd, buffer, size, address of
// the unaligned head/tail record, left empty), write (fd, buffer, size,
// unaligned count, unaligned bytes), lseek (fd, offset, whence), getstat
// (stat address, name).
function TPS2FileIOServer.Call(Fn: Cardinal; Args: PByte; Size: Integer; ReplySize: Integer): TBytes;
begin
  if Fn = FnInit then
  begin
    if Version >= 2200 then
      FRecordAddress := ArgU32(Args, Size, 0);
    Result := TEncoding.ANSI.GetBytes(IntToStr(Version) + '....');
    Exit;
  end;
  if Version >= 2200 then
    Exit(CallRecord(Fn, Args, Size));
  if Log <> nil then
    Log.Add(Format('fileio %d "%s" size %d', [Fn, ArgString(Args, Size, 4, 256), Size]));
  case Fn of
    FnOpen:
      Result := IntBytes(FIOMan.Open(ArgString(Args, Size, 4, 256), Integer(ArgU32(Args, Size, 0))));
    FnClose:
      Result := IntBytes(FIOMan.Close(Integer(ArgU32(Args, Size, 0))));
    FnRead:
      begin
        var Data: TBytes;
        var N := FIOMan.Read(Integer(ArgU32(Args, Size, 0)), Integer(ArgU32(Args, Size, 8)), Data);
        WriteEE(ArgU32(Args, Size, 4), Data);
        var Tail := ArgU32(Args, Size, 12);
        if Tail <> 0 then
        begin
          var Z: TBytes;
          SetLength(Z, 16);
          FillChar(Z[0], 16, 0);
          WriteEE(Tail, Z);
        end;
        Result := IntBytes(N);
      end;
    FnWrite:
      begin
        var Count := Max(Integer(ArgU32(Args, Size, 8)), 0);
        var Mis := EnsureRange(Integer(ArgU32(Args, Size, 12)), 0, Min(16, Count));
        var Data: TBytes;
        SetLength(Data, Count);
        if Mis > 0 then
          Move(Args[16], Data[0], Mis);
        var Rest := ReadEE(ArgU32(Args, Size, 4) + Cardinal(Mis), Count - Mis);
        if Length(Rest) > 0 then
          Move(Rest[0], Data[Mis], Length(Rest));
        Result := IntBytes(FIOMan.Write(Integer(ArgU32(Args, Size, 0)), Data));
      end;
    FnSeek:
      Result := IntBytes(Integer(FIOMan.Seek(Integer(ArgU32(Args, Size, 0)), Integer(ArgU32(Args, Size, 4)),
        Integer(ArgU32(Args, Size, 8)))));
    FnGetStat:
      begin
        var St: TBytes;
        var R := FIOMan.GetStat(ArgString(Args, Size, 4, 256), St);
        if R = 0 then
          WriteEE(ArgU32(Args, Size, 0), St);
        Result := IntBytes(R);
      end;
    FnMkdir:
      Result := IntBytes(FIOMan.MakeDir(ArgString(Args, Size, 0, 256)));
    FnRemove, FnRmdir:
      Result := IntBytes(FIOMan.Remove(ArgString(Args, Size, 0, 256)));
    FnDOpen:
      Result := IntBytes(FIOMan.DirOpen(ArgString(Args, Size, 0, 256)));
    FnDClose:
      Result := IntBytes(FIOMan.Close(Integer(ArgU32(Args, Size, 0))));
    FnDRead:
      begin
        var Dirent: TBytes;
        var R := FIOMan.DirRead(Integer(ArgU32(Args, Size, 0)), Dirent);
        if R > 0 then
          WriteEE(ArgU32(Args, Size, 4), Dirent);
        Result := IntBytes(R);
      end;
  else
    Result := IntBytes(ErrNoDevice);
  end;
end;

end.
