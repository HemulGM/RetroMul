unit PS2.IOP.FileIO;

// High-level IOP file services: the ioman device table (tty, host, cdrom0,
// rom0, mc0 through TPS2FileSystem) and the FILEIO RPC server (SID
// 80000001h, the version 1000/2xxx protocol the EE libraries use).
// References: ps2sdk fileio-common.h (AFL 2.0, structures), Play!
// Iop_FileIo (BSD-2).
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

  TPS2OpenFile = record
    Used: Boolean;
    Device, Path: string;
    Position, Size: Int64;
    Mode: Integer;
  end;

  TPS2IOMan = class
  private
    FFS: TPS2FileSystem;
    FFiles: array[0..63] of TPS2OpenFile;
    FOnTTY: TProc<string>;
  public
    constructor Create(FS: TPS2FileSystem);
    procedure Reset;
    class procedure SplitPath(const Name: string; out Device, Path: string); static;
    function Open(const Name: string; Mode: Integer): Integer;
    function Close(Fd: Integer): Integer;
    function Read(Fd: Integer; Count: Integer; out Data: TBytes): Integer;
    function Write(Fd: Integer; const Data: TBytes): Integer;
    function Seek(Fd: Integer; Offset: Int64; Whence: Integer): Int64;
    function GetStat(const Name: string; out Size: Int64): Integer;
    procedure SerializeState(State: TStateArchive);
    property FileSystem: TPS2FileSystem read FFS write FFS;
    property OnTTY: TProc<string> read FOnTTY write FOnTTY;
  end;

  TPS2FileIOServer = class(TPS2RPCServer)
  private
    FIOMan: TPS2IOMan;
    FResultPtr: array[0..1] of Cardinal;
    procedure WriteEE(Address: Cardinal; const Data: TBytes);
    function Call2200(Fn: Cardinal; Args: PByte; Size: Integer): TBytes;
  public
    // FILEIO module version of the IOP image (1000, 2100, 2200...): from
    // 2200 on, results come back in a SIF command (80000011h).
    Version: Integer;
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
  if Device = 'mc1' then
    Device := 'mc1';
end;

function TPS2IOMan.Open(const Name: string; Mode: Integer): Integer;
begin
  var Device, Path: string;
  SplitPath(Name, Device, Path);
  if (Device = 'tty') or (Device = 'tty0') then
    Exit(1);
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
  var Device, Path: string;
  SplitPath(Name, Device, Path);
  Size := -1;
  if FFS <> nil then
    Size := FFS.FileSize(Device, Path);
  if Size < 0 then
    Result := -2
  else
    Result := 0;
end;

procedure TPS2IOMan.SerializeState(State: TStateArchive);
begin
  for var K := 0 to High(FFiles) do
  begin
    State.Field(FFiles[K].Used, SizeOf(Boolean));
    State.Field(FFiles[K].Position, SizeOf(Int64));
    State.Field(FFiles[K].Size, SizeOf(Int64));
    State.Field(FFiles[K].Mode, SizeOf(Integer));
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
end;

function ArgString(Args: PByte; Offset, Max: Integer): string;
begin
  var B: TBytes;
  for var K := 0 to Max - 1 do
  begin
    var C := Args[Offset + K];
    if C = 0 then
      Break;
    B := B + [C];
  end;
  Result := TEncoding.ANSI.GetString(B);
end;

function ArgU32(Args: PByte; Offset: Integer): Cardinal;
begin
  Result := PCardinal(Args + Offset)^;
end;

procedure TPS2FileIOServer.Reset;
begin
  FResultPtr[0] := 0;
  FResultPtr[1] := 0;
end;

procedure TPS2FileIOServer.SerializeState(State: TStateArchive);
begin
  State.Field(Version, SizeOf(Version));
  State.Field(FResultPtr, SizeOf(FResultPtr));
end;

// FILEIO 2200: every request starts with (semaphore, result pointer, result
// size); the reply record (header, result, three words) goes to the EE
// buffer named at init, then command 80000011h wakes the caller.
function TPS2FileIOServer.Call2200(Fn: Cardinal; Args: PByte; Size: Integer): TBytes;
var
  Reply: TBytes;
begin
  SetLength(Reply, 32);
  FillChar(Reply[0], 32, 0);
  PCardinal(@Reply[0])^ := ArgU32(Args, 0);
  PCardinal(@Reply[4])^ := Fn;
  PCardinal(@Reply[8])^ := ArgU32(Args, 4);
  PCardinal(@Reply[12])^ := ArgU32(Args, 8);
  var R: Int64 := -1;
  case Fn of
    0: R := FIOMan.Open(ArgString(Args, 20, 256), Integer(ArgU32(Args, 12)));
    1: R := FIOMan.Close(Integer(ArgU32(Args, 12)));
    2:
      begin
        var Data: TBytes;
        R := FIOMan.Read(Integer(ArgU32(Args, 12)), Integer(ArgU32(Args, 20)), Data);
        WriteEE(ArgU32(Args, 16), Data);
      end;
    3:
      begin
        var Count := Integer(ArgU32(Args, 20));
        var Data: TBytes;
        SetLength(Data, Max(Count, 0));
        var A := ArgU32(Args, 16) and PS2RAMMask;
        if (Count > 0) and (A + Cardinal(Count) <= PS2RAMSize) then
          Move((FSIF.EERAM + A)^, Data[0], Count);
        R := FIOMan.Write(Integer(ArgU32(Args, 12)), Data);
      end;
    4: R := FIOMan.Seek(Integer(ArgU32(Args, 12)), Integer(ArgU32(Args, 16)), Integer(ArgU32(Args, 20)));
    12:
      begin
        var Sz: Int64;
        R := FIOMan.GetStat(ArgString(Args, 16, 256), Sz);
        SetLength(Reply, 24 + 64);
        PCardinal(@Reply[20])^ := ArgU32(Args, 12);
        if R = 0 then
        begin
          PCardinal(@Reply[24])^ := $2000;
          PCardinal(@Reply[32])^ := Cardinal(Sz);
          PCardinal(@Reply[60])^ := Cardinal(Sz shr 32);
          var St: TBytes := Copy(Reply, 24, 40);
          WriteEE(ArgU32(Args, 12), St);
        end;
      end;
    22:
      begin
        R := FIOMan.Seek(Integer(ArgU32(Args, 12)), PInt64(Args + 16)^, Integer(ArgU32(Args, 24)));
        PInt64(@Reply[16])^ := R;
        R := Cardinal(R);
      end;
    9: R := -2;
    18, 19, 20, 21, 23, 26: R := 0;
  end;
  if Fn <> 22 then
    PInteger(@Reply[16])^ := Integer(R);
  if FResultPtr[0] <> 0 then
    FSIF.SendData(FResultPtr[0], Reply);
  var Cmd: TBytes;
  SetLength(Cmd, 16);
  FSIF.SendCommand($80000011, Cmd);
  Result := IntBytes(1);
end;

function TPS2FileIOServer.Call(Fn: Cardinal; Args: PByte; Size: Integer; ReplySize: Integer): TBytes;
begin
  if Fn = 255 then
  begin
    if Version >= 2200 then
    begin
      FResultPtr[0] := ArgU32(Args, 0);
      FResultPtr[1] := ArgU32(Args, 4);
    end;
    Result := TEncoding.ANSI.GetBytes(IntToStr(Version) + '....');
    Exit;
  end;
  if Version >= 2200 then
    Exit(Call2200(Fn, Args, Size));
  case Fn of
    0: // open {mode, name[256]}
      Result := IntBytes(FIOMan.Open(ArgString(Args, 4, 256), Integer(ArgU32(Args, 0))));
    1: // close {fd}
      Result := IntBytes(FIOMan.Close(Integer(ArgU32(Args, 0))));
    2: // read {fd, ptr, size, read_data}
      begin
        var Data: TBytes;
        var N := FIOMan.Read(Integer(ArgU32(Args, 0)), Integer(ArgU32(Args, 8)), Data);
        WriteEE(ArgU32(Args, 4), Data);
        // The EE copies nothing from read_data.
        var RD := ArgU32(Args, 12);
        if RD <> 0 then
        begin
          var Z: TBytes;
          SetLength(Z, 16);
          WriteEE(RD, Z);
        end;
        Result := IntBytes(N);
      end;
    3: // write {fd, ptr, size, mis, aligned[16]}
      begin
        var Fd := Integer(ArgU32(Args, 0));
        var Ptr := ArgU32(Args, 4);
        var Count := Integer(ArgU32(Args, 8));
        var Mis := Integer(ArgU32(Args, 12));
        if Count < 0 then
          Count := 0;
        if Mis > 16 then
          Mis := 16;
        if Mis > Count then
          Mis := Count;
        var Data: TBytes;
        SetLength(Data, Count);
        if Mis > 0 then
          Move(Args[16], Data[0], Mis);
        var A := (Ptr + Cardinal(Mis)) and PS2RAMMask;
        if (Count - Mis > 0) and (A + Cardinal(Count - Mis) <= PS2RAMSize) then
          Move((FSIF.EERAM + A)^, Data[Mis], Count - Mis);
        Result := IntBytes(FIOMan.Write(Fd, Data));
      end;
    4: // lseek {fd, offset, whence}
      Result := IntBytes(Integer(FIOMan.Seek(Integer(ArgU32(Args, 0)), Integer(ArgU32(Args, 4)),
        Integer(ArgU32(Args, 8)))));
    12: // getstat {buf, name[256]}
      begin
        var Sz: Int64;
        var R := FIOMan.GetStat(ArgString(Args, 4, 256), Sz);
        if R = 0 then
        begin
          // io_stat_t: mode, attr, size, ctime[8], atime[8], mtime[8], hisize.
          var St: TBytes;
          SetLength(St, 40);
          PCardinal(@St[0])^ := $2000;
          PCardinal(@St[8])^ := Cardinal(Sz);
          PCardinal(@St[36])^ := Cardinal(Sz shr 32);
          WriteEE(ArgU32(Args, 0), St);
        end;
        Result := IntBytes(R);
      end;
  else
    Result := IntBytes(-1);
  end;
end;

end.
