unit PS2.IOP.CDVD;

// High-level CDVD services: the disc file system (cdrom0: over ISO 9660),
// generated rom0: files (ROMVER and friends by region), and the CDVDFSV RPC
// servers libcdvd binds: init (80000592h), S-commands (80000593h: clock,
// disc type, status, dual-layer information...), N-commands (80000595h:
// sector reads into EE or IOP memory, read chains, streaming, TOC, disc
// readiness), file search (80000597h), disc ready (8000059Ah/8000059Ch)
// and power-off (80000596h). Results and data go where libcdvd reads them.
// References: ps2sdk libcdvd-rpc.h, cdvd-ioctl.h, cdvdfsv and cdvdstm
// (AFL 2.0; packet layouts and result codes), ps2tek.
{$IFDEF PS2_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$POINTERMATH ON}

interface

uses
  System.SysUtils, System.Classes, System.Math, System.IOUtils, System.Generics.Collections, Core.Snapshots,
  Core.DVD.Image,
  PS2.Types, PS2.SIF, PS2.IOP.FileIO;

type
  TPS2Region = (Japan, America, Europe);

  // cdrom0:, rom0: and host: in one place.
  TPS2DiscFileSystem = class(TPS2FileSystem)
  private
    FImage: TDVDImage;
    FISO: TISO9660;
    FHostRoot: string;
    FRegion: TPS2Region;
    FROMFiles: TDictionary<string, TBytes>;
    FWritten: TDictionary<string, TBytes>;
    function ROMFile(const Path: string): TBytes;
  public
    constructor Create(Image: TDVDImage; const HostRoot: string; Region: TPS2Region);
    destructor Destroy; override;
    function ReadFile(const Device, Path: string): TBytes; override;
    function WriteFile(const Device, Path: string; const Data: TBytes): Boolean; override;
    function FileSize(const Device, Path: string): Int64; override;
    function ReadAt(const Device, Path: string; Offset: Int64; Count: Integer): TBytes; override;
    // Files from the user's BIOS replace the generated rom0: ones.
    procedure SetROMFile(const Name: string; const Data: TBytes);
    property Image: TDVDImage read FImage;
    property ISO: TISO9660 read FISO;
    property Region: TPS2Region read FRegion write FRegion;
  end;

  // One server per SID; Kind selects the function set.
  TPS2CDVDServer = class(TPS2RPCServer)
  private
    FFS: TPS2DiscFileSystem;
    FKind: Cardinal;
    FStreamPos: Int64;
    FStreaming: Boolean;
    FStreamBuffer: Cardinal;
    procedure WriteEE(Address: Cardinal; Data: PByte; Count: Integer);
    procedure WriteEEWord(Address, Value: Cardinal);
    function ReadSectors(LBA: Int64; Count: Integer; Dest: Cardinal; ToIOP: Boolean): Integer;
    function SearchFile(Args: PByte; Size: Integer): Integer;
    function SCommand(Fn: Cardinal; Args: PByte; Size: Integer): TBytes;
    function NCommand(Fn: Cardinal; Args: PByte; Size: Integer): TBytes;
    function Stream(A: PCardinal): Integer;
  public
    // Sectors read (diagnostics, not serialized).
    SectorsRead: Int64;
    Log: TStrings;
    // EE cycles since power-on for the real-time clock (nil: a fixed time).
    Clock: PInt64;
    constructor Create(SID: Cardinal; FS: TPS2DiscFileSystem);
    function Call(Fn: Cardinal; Args: PByte; Size: Integer; ReplySize: Integer): TBytes; override;
    procedure SerializeState(State: TStateArchive); override;
  end;

const
  PS2CDVDServerSIDs: array[0..6] of Cardinal = ($80000592, $80000593, $80000595, $80000596, $80000597, $8000059A,
    $8000059C);

implementation

function ToBCD(V: Int64): Byte;
begin
  Result := Byte((((V div 10) mod 10) shl 4) or (V mod 10));
end;

{ TPS2DiscFileSystem }

constructor TPS2DiscFileSystem.Create(Image: TDVDImage; const HostRoot: string; Region: TPS2Region);
begin
  inherited Create;
  FImage := Image;
  if (Image <> nil) and TISO9660.HasVolume(Image) then
    FISO := TISO9660.Create(Image);
  FHostRoot := HostRoot;
  FRegion := Region;
  FROMFiles := TDictionary<string, TBytes>.Create;
  FWritten := TDictionary<string, TBytes>.Create;
end;

destructor TPS2DiscFileSystem.Destroy;
begin
  FISO.Free;
  FROMFiles.Free;
  FWritten.Free;
  inherited;
end;

procedure TPS2DiscFileSystem.SetROMFile(const Name: string; const Data: TBytes);
begin
  FROMFiles.AddOrSetValue(Name.ToUpper, Data);
end;

function TPS2DiscFileSystem.ROMFile(const Path: string): TBytes;
begin
  var Name := Path.ToUpper;
  if FROMFiles.TryGetValue(Name, Result) then
    Exit;
  Result := nil;
  if Name = 'ROMVER' then
  begin
    // Version 2.30, region letter, console (C), date.
    var Letter := 'A';
    case FRegion of
      TPS2Region.Japan: Letter := 'J';
      TPS2Region.Europe: Letter := 'E';
    end;
    Result := TEncoding.ASCII.GetBytes('0230' + Letter + 'C20040614' + #10#0);
  end
  else if Name = 'EXTINFO' then
    Result := TEncoding.ASCII.GetBytes('')
  else if Name = 'OSDSYS' then
    Result := nil;
end;

function TPS2DiscFileSystem.ReadFile(const Device, Path: string): TBytes;
begin
  Result := nil;
  if FWritten.TryGetValue(Device + ':' + Path.ToUpper, Result) then
    Exit;
  if Device = 'cdrom0' then
  begin
    if FISO <> nil then
      Result := FISO.ReadFile(Path, 64 * 1024 * 1024);
  end
  else if Device = 'rom0' then
    Result := ROMFile(Path)
  else if (Device = 'host') and (FHostRoot <> '') then
  begin
    var Full := TPath.Combine(FHostRoot, Path.Replace('/', PathDelim));
    if TFile.Exists(Full) then
      Result := TFile.ReadAllBytes(Full);
  end;
end;

function TPS2DiscFileSystem.WriteFile(const Device, Path: string; const Data: TBytes): Boolean;
begin
  FWritten.AddOrSetValue(Device + ':' + Path.ToUpper, Copy(Data));
  Result := True;
end;

function TPS2DiscFileSystem.FileSize(const Device, Path: string): Int64;
var
  E: TISO9660Entry;
begin
  var W: TBytes;
  if FWritten.TryGetValue(Device + ':' + Path.ToUpper, W) then
    Exit(Length(W));
  if Device = 'cdrom0' then
  begin
    if (FISO <> nil) and FISO.Find(Path, E) and not E.Directory then
      Exit(E.Size);
    Exit(-1);
  end;
  if (Device = 'host') and (FHostRoot <> '') then
  begin
    var Full := TPath.Combine(FHostRoot, Path.Replace('/', PathDelim));
    if TFile.Exists(Full) then
      Exit(TFile.GetSize(Full));
    Exit(-1);
  end;
  var D := ReadFile(Device, Path);
  if D = nil then
    Result := -1
  else
    Result := Length(D);
end;

function TPS2DiscFileSystem.ReadAt(const Device, Path: string; Offset: Int64; Count: Integer): TBytes;
var
  E: TISO9660Entry;
begin
  if (Device = 'cdrom0') and (FISO <> nil) then
  begin
    Result := nil;
    if not FISO.Find(Path, E) or E.Directory or (Offset >= E.Size) or (Count <= 0) then
      Exit;
    if Offset + Count > E.Size then
      Count := Integer(E.Size - Offset);
    var First := E.LBA + Offset div DVDSectorSize;
    var Skip := Integer(Offset mod DVDSectorSize);
    var Sectors := (Skip + Count + DVDSectorSize - 1) div DVDSectorSize;
    var Buf: TBytes;
    SetLength(Buf, Sectors * DVDSectorSize);
    FImage.ReadSectors(First, Sectors, @Buf[0]);
    Result := Copy(Buf, Skip, Count);
    Exit;
  end;
  Result := inherited ReadAt(Device, Path, Offset, Count);
end;

{ TPS2CDVDServer }

const
  SIDInit = $592;
  SIDSCmd = $593;
  SIDNCmd = $595;
  SIDPowerOff = $596;
  SIDSearch = $597;
  SIDReady = $59A;
  SIDReady2 = $59C;

  // sceCdDiskReady / N-command 0Eh: ready, not ready.
  Ready = 2;
  NotReady = 6;
  // sceCdGetDiskType: PS2 CD, PS2 DVD.
  TypePS2CD = $12;
  TypePS2DVD = $14;
  // sceCdStatus: paused (spinning, not reading).
  StatusPause = $0A;
  // Module versions in the init reply (cdvdfsv, cdvdman).
  FSVVersion = $226;
  ManVersion = $226;

constructor TPS2CDVDServer.Create(SID: Cardinal; FS: TPS2DiscFileSystem);
begin
  inherited Create(SID);
  FFS := FS;
  FKind := SID and $FFF;
end;

procedure TPS2CDVDServer.WriteEE(Address: Cardinal; Data: PByte; Count: Integer);
begin
  var A := Address and PS2RAMMask;
  if A + Cardinal(Count) > PS2RAMSize then
    Count := Integer(PS2RAMSize - A);
  if Count > 0 then
  begin
    Move(Data^, (FSIF.EERAM + A)^, Count);
    FSIF.MarkEE(A, Cardinal(Count));
  end;
end;

procedure TPS2CDVDServer.WriteEEWord(Address, Value: Cardinal);
begin
  if Address <> 0 then
    WriteEE(Address, @Value, 4);
end;

// Count 2048-byte sectors from LBA into EE memory or IOP memory; the bytes
// read.
function TPS2CDVDServer.ReadSectors(LBA: Int64; Count: Integer; Dest: Cardinal; ToIOP: Boolean): Integer;
begin
  if (FFS.Image = nil) or (Count <= 0) then
    Exit(0);
  var Buf: TBytes;
  SetLength(Buf, Count * DVDSectorSize);
  FFS.Image.ReadSectors(LBA, Count, @Buf[0]);
  Inc(SectorsRead, Count);
  if ToIOP then
  begin
    var A := Dest and PS2IOPRAMMask;
    var N := Length(Buf);
    if A + Cardinal(N) > PS2IOPRAMSize then
      N := Integer(PS2IOPRAMSize - A);
    Move(Buf[0], (FSIF.IOPRAM + A)^, N);
  end
  else
    WriteEE(Dest, @Buf[0], Length(Buf));
  Result := Length(Buf);
end;

// sceCdSearchFile: a sceCdlFILE (sector, size, name[16], date[8]) the
// server fills, then the path; three layouts by size: 12Ch (file
// attributes, path, EE address, layer), 128h (attributes, path, EE
// address), 124h (path, EE address). The sceCdlFILE (with the attributes
// word in the newer layouts) goes to the EE address.
function TPS2CDVDServer.SearchFile(Args: PByte; Size: Integer): Integer;
var
  E: TISO9660Entry;
  Info: array[0..35] of Byte;
begin
  var PathOffset := $24;
  var EEAddress := $124;
  var InfoSize := 36;
  if Size < $128 then
  begin
    PathOffset := $20;
    EEAddress := $120;
    InfoSize := 32;
  end;
  if Size < EEAddress + 4 then
    Exit(0);
  var B: TBytes;
  for var K := 0 to 255 do
  begin
    var C := Args[PathOffset + K];
    if C = 0 then
      Break;
    B := B + [C];
  end;
  var Path := TEncoding.ANSI.GetString(B);
  var Clean := Path;
  var Semi := Clean.IndexOf(';');
  if Semi >= 0 then
    Clean := Clean.Substring(0, Semi);
  var Found := (FFS.ISO <> nil) and FFS.ISO.Find(Clean, E) and not E.Directory;
  if Log <> nil then
    Log.Add(Format('cdvd search %s: %s', [Path, BoolToStr(Found, True)]));
  if not Found then
    Exit(0);
  FillChar(Info, SizeOf(Info), 0);
  PCardinal(@Info[0])^ := Cardinal(E.LBA);
  PCardinal(@Info[4])^ := Cardinal(E.Size);
  var NB := TEncoding.ANSI.GetBytes(ExtractFileName(Clean.Replace('/', '\')) + ';1');
  Move(NB[0], Info[8], Min(Length(NB), 16));
  Move(Info, Args^, 32);
  var Dest := PCardinal(Args + EEAddress)^;
  if Dest <> 0 then
    WriteEE(Dest, @Info[0], InfoSize);
  Result := 1;
end;

// S-commands (SID 80000593h): the result word, then the command's data.
function TPS2CDVDServer.SCommand(Fn: Cardinal; Args: PByte; Size: Integer): TBytes;
begin
  SetLength(Result, 32);
  FillChar(Result[0], Length(Result), 0);
  var R: Integer := 1;
  case Fn of
    $01:
      begin
        // ReadClock: status, second, minute, hour, -, day, month, year
        // (BCD): 2004-01-01 12:00:00 plus the emulated time, so that games
        // waiting for the clock to move see it move.
        var Secs: Int64 := 12 * 3600;
        if Clock <> nil then
          Inc(Secs, Clock^ div PS2EEClock);
        Result[5] := ToBCD(Secs mod 60);
        Result[6] := ToBCD((Secs div 60) mod 60);
        Result[7] := ToBCD((Secs div 3600) mod 24);
        Result[9] := ToBCD(1 + (Secs div 86400) mod 31);
        Result[10] := $01;
        Result[11] := $04;
      end;
    $03:
      // GetDiskType.
      if FFS.Image = nil then
        R := 0
      else if FFS.Image.IsDVD then
        R := TypePS2DVD
      else
        R := TypePS2CD;
    $04:
      // GetError: none.
      R := 0;
    $05, $06, $15, $16, $1A, $21, $22, $23, $24, $25, $26:
      // Tray request (tray unchanged), ILink id, audio out, break, model
      // name, power off, media mode, thread priority, GUID, time-out,
      // model id: done (the data stays zero).
      R := 1;
    $0C:
      R := StatusPause;
    $27:
      // ReadDvdDualInfo: dual layer, layer 1 start.
      if (FFS.Image <> nil) and (FFS.Image.LayerBreak > 0) then
      begin
        PCardinal(@Result[4])^ := 1;
        PCardinal(@Result[8])^ := Cardinal(FFS.Image.LayerBreak);
      end;
  else
    R := 0;
  end;
  PInteger(@Result[0])^ := R;
end;

// N-commands (SID 80000595h).
function TPS2CDVDServer.NCommand(Fn: Cardinal; Args: PByte; Size: Integer): TBytes;
begin
  SetLength(Result, 16);
  FillChar(Result[0], Length(Result), 0);
  var A := PCardinal(Args);
  var R: Integer := 0;
  case Fn of
    $01, $13:
      begin
        // Read (sector, count, EE buffer, mode, unaligned record, read
        // position address): all the data goes straight to the buffer, so
        // the unaligned head/tail record stays empty; the result is the
        // bytes read.
        if Log <> nil then
          Log.Add(Format('cdvd read %d x%d -> %.8x mode %.8x %.8x %.8x', [A[0], A[1], A[2], A[3], A[4], A[5]]));
        R := ReadSectors(A[0], Integer(A[1]), A[2], False);
        var Empty: array[0..15] of Byte;
        FillChar(Empty, SizeOf(Empty), 0);
        if A[4] <> 0 then
          WriteEE(A[4], @Empty[0], 16);
        WriteEEWord(A[5], Cardinal(R));
      end;
    $04:
      begin
        // GetToc: the TOC buffer (nothing for a PS2 disc), DVD flag.
        var Toc: TBytes;
        SetLength(Toc, $810);
        FillChar(Toc[0], Length(Toc), 0);
        if A[0] <> 0 then
          WriteEE(A[0], @Toc[0], Length(Toc));
        R := 1;
        if (FFS.Image <> nil) and FFS.Image.IsDVD then
          PCardinal(@Result[4])^ := 1;
      end;
    $05, $06, $07, $08:
      // Seek, standby, stop, pause.
      R := 1;
    $09:
      R := Stream(A);
    $0D:
      // Read into IOP memory (sector, count, address, mode, -, read
      // position address).
      WriteEEWord(A[5], Cardinal(ReadSectors(A[0], Integer(A[1]), A[2], True)));
    $0E:
      if FFS.Image <> nil then
        R := Ready
      else
        R := NotReady;
    $0F:
      begin
        // ReadChain: up to 64 (sector, count, address) entries ended by -1
        // (bit 0 of the address: IOP memory), the mode, then the read
        // position address.
        var Pos: Cardinal := 0;
        for var T := 0 to 63 do
        begin
          var S := A[T * 3];
          var N := A[T * 3 + 1];
          var D := A[T * 3 + 2];
          if (S = $FFFFFFFF) or (N = $FFFFFFFF) or (D = $FFFFFFFF) then
            Break;
          Inc(Pos, ReadSectors(S, Integer(N), D and not Cardinal(1), (D and 1) <> 0));
        end;
        if Size >= 65 * 12 + 8 then
          WriteEEWord(A[65 * 3 + 1], Pos);
        R := 1;
      end;
  end;
  PInteger(@Result[0])^ := R;
end;

// Streaming (N-command 09h, the cdrom_stm0: requests): first word the
// sector or size, second the count, buffer, command, mode. Commands: 1
// start at a sector, 2 read sectors from the stream, 3 stop, 4 seek, 5 set
// up the buffer (sectors, banks), 6 sectors buffered, 7 pause, 8 resume,
// 9 seek and pause. The disc is read when the stream is read, so the buffer
// is always full.
function TPS2CDVDServer.Stream(A: PCardinal): Integer;
begin
  case A[3] of
    1, 4, 9:
      begin
        FStreamPos := A[0];
        FStreaming := True;
        Result := 1;
      end;
    2:
      begin
        Result := ReadSectors(FStreamPos, Integer(A[1]), A[2], False) div DVDSectorSize;
        Inc(FStreamPos, Result);
      end;
    3:
      begin
        FStreaming := False;
        Result := 1;
      end;
    5:
      begin
        FStreamBuffer := A[0];
        Result := 1;
      end;
    6:
      Result := Integer(FStreamBuffer);
    7, 8:
      Result := 1;
  else
    Result := 0;
  end;
end;

function TPS2CDVDServer.Call(Fn: Cardinal; Args: PByte; Size: Integer; ReplySize: Integer): TBytes;
begin
  SetLength(Result, 16);
  FillChar(Result[0], 16, 0);
  case FKind of
    SIDInit:
      begin
        // Result, cdvdfsv and cdvdman versions, debug level.
        PCardinal(@Result[0])^ := 1;
        PCardinal(@Result[4])^ := FSVVersion;
        PCardinal(@Result[8])^ := ManVersion;
      end;
    SIDSCmd:
      Result := SCommand(Fn, Args, Size);
    SIDNCmd:
      Result := NCommand(Fn, Args, Size);
    SIDSearch:
      PCardinal(@Result[0])^ := Cardinal(SearchFile(Args, Size));
    SIDReady, SIDReady2:
      if FFS.Image <> nil then
        PCardinal(@Result[0])^ := Ready
      else
        PCardinal(@Result[0])^ := NotReady;
    SIDPowerOff:
      ;
  end;
end;

procedure TPS2CDVDServer.SerializeState(State: TStateArchive);
begin
  State.Field(FStreamPos, SizeOf(FStreamPos));
  State.Field(FStreaming, SizeOf(FStreaming));
  State.Field(FStreamBuffer, SizeOf(FStreamBuffer));
end;

end.
