unit PS2.IOP.CDVD;

// High-level CDVD services: the disc file system (cdrom0: over ISO 9660),
// generated rom0: files (ROMVER and friends by region), and the CDVDFSV RPC
// servers (SIDs 80000592h..8000059Ch: init, S-commands such as disc type and
// dual-layer info, sector reads into EE or IOP memory, read chains,
// streaming, file search and disc readiness).
// References: Play! Iop_Cdvdfsv (BSD-2), ps2sdk libcdvd-rpc.h (interfaces),
// ps2tek.
{$IFDEF PS2_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$POINTERMATH ON}

interface

uses
  System.SysUtils, System.Classes, System.IOUtils, System.Generics.Collections, Core.Snapshots, Core.DVD.Image,
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
    procedure ReadSectors(LBA: Int64; Count: Integer; Dest: Cardinal; ToIOP: Boolean);
    function SearchFile(Args: PByte; Size: Integer): Integer;
  public
    // Sectors read (diagnostics, not serialized).
    SectorsRead: Int64;
    Log: TStrings;
    constructor Create(SID: Cardinal; FS: TPS2DiscFileSystem);
    function Call(Fn: Cardinal; Args: PByte; Size: Integer; ReplySize: Integer): TBytes; override;
    procedure SerializeState(State: TStateArchive); override;
  end;

const
  PS2CDVDServerSIDs: array[0..6] of Cardinal = ($80000592, $80000593, $80000595, $80000596, $80000597, $8000059A,
    $8000059C);

implementation

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
    Move(Data^, (FSIF.EERAM + A)^, Count);
end;

procedure TPS2CDVDServer.ReadSectors(LBA: Int64; Count: Integer; Dest: Cardinal; ToIOP: Boolean);
begin
  if (FFS.Image = nil) or (Count <= 0) then
    Exit;
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
end;

function TPS2CDVDServer.SearchFile(Args: PByte; Size: Integer): Integer;
var
  E: TISO9660Entry;
begin
  // sceCdlFILE (lsn, size, name[16], date[8]) at 0, then the path at 24h
  // (20h in the oldest layout) and the EE address of the caller's sceCdlFILE.
  var PathOffset := $24;
  var EEDest := $124;
  if Size = $124 then
  begin
    PathOffset := $20;
    EEDest := $120;
  end;
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
  PCardinal(Args)^ := Cardinal(E.LBA);
  PCardinal(Args + 4)^ := Cardinal(E.Size);
  var Name := ExtractFileName(Clean.Replace('/', '\'));
  var Info: array[0..31] of Byte;
  FillChar(Info, SizeOf(Info), 0);
  PCardinal(@Info[0])^ := Cardinal(E.LBA);
  PCardinal(@Info[4])^ := Cardinal(E.Size);
  var NB := TEncoding.ANSI.GetBytes(Name + ';1');
  for var K := 0 to Length(NB) - 1 do
    if K < 16 then
      Info[8 + K] := NB[K];
  var Dest := PCardinal(Args + EEDest)^;
  if Dest <> 0 then
    WriteEE(Dest, @Info[0], 32);
  Result := 1;
end;

function TPS2CDVDServer.Call(Fn: Cardinal; Args: PByte; Size: Integer; ReplySize: Integer): TBytes;
begin
  SetLength(Result, 16);
  FillChar(Result[0], 16, 0);
  var A := PCardinal(Args);
  case FKind of
    $592:
      // Init: versions, debug mode.
      PCardinal(@Result[12])^ := $FF;
    $593:
      case Fn of
        $01: // ReadClock: status then the clock (seconds..year in BCD)
          begin
            SetLength(Result, 16);
            Result[0] := 1;
            Result[5] := $00;
            Result[6] := $00;
            Result[7] := $12;
            Result[9] := $01;
            Result[10] := $01;
            Result[11] := $04;
          end;
        $03: // GetDiskType: PS2 DVD (14h) or PS2 CD (12h)
          if (FFS.Image <> nil) and FFS.Image.IsDVD then
            PCardinal(@Result[0])^ := $14
          else if FFS.Image <> nil then
            PCardinal(@Result[0])^ := $12;
        $04: PCardinal(@Result[0])^ := 0;
        $05: PCardinal(@Result[0])^ := 1;
        $0C: PCardinal(@Result[0])^ := 10;
        $16, $22: PCardinal(@Result[0])^ := 1;
        $27: // ReadDvdDualInfo
          begin
            PCardinal(@Result[0])^ := 1;
            if (FFS.Image <> nil) and (FFS.Image.LayerBreak > 0) then
            begin
              PCardinal(@Result[4])^ := 1;
              PCardinal(@Result[8])^ := Cardinal(FFS.Image.LayerBreak);
            end;
          end;
      else
        PCardinal(@Result[0])^ := 1;
      end;
    $595:
      case Fn of
        $01: // Read(sector, count, EE buffer, mode)
          begin
            if Log <> nil then
              Log.Add(Format('cdvd read %d x%d -> %.8x mode %.8x %.8x %.8x', [A[0], A[1], A[2], A[3], A[4], A[5]]));
            ReadSectors(A[0], Integer(A[1]), A[2], False);
            // All data went straight to the buffer: the EE's alignment fixup
            // (A[4]: head/tail sizes, destinations, bytes) has nothing to copy;
            // A[5] is the read position.
            var Fix: array[0..15] of Byte;
            FillChar(Fix, SizeOf(Fix), 0);
            if A[4] <> 0 then
              WriteEE(A[4], @Fix[0], 16);
            if A[5] <> 0 then
            begin
              var Pos := A[1] * 2048;
              WriteEE(A[5], @Pos, 4);
            end;
            PCardinal(@Result[0])^ := 0;
          end;
        $04: PCardinal(@Result[0])^ := 1;
        $05, $08: PCardinal(@Result[0])^ := 1;
        $09: // Stream commands
          begin
            case A[3] of
              1:
                begin
                  FStreamPos := A[0];
                  FStreaming := True;
                  PCardinal(@Result[0])^ := 1;
                end;
              2:
                begin
                  ReadSectors(FStreamPos, Integer(A[1]), A[2], False);
                  Inc(FStreamPos, A[1]);
                  PCardinal(@Result[0])^ := A[1];
                end;
              3:
                begin
                  FStreaming := False;
                  PCardinal(@Result[0])^ := 1;
                end;
              4, 9:
                begin
                  FStreamPos := A[0];
                  PCardinal(@Result[0])^ := 1;
                end;
              5:
                begin
                  FStreamBuffer := A[0];
                  PCardinal(@Result[0])^ := 1;
                end;
              6: PCardinal(@Result[0])^ := FStreamBuffer;
            end;
          end;
        $0D: // ReadIopMem
          begin
            ReadSectors(A[0], Integer(A[1]), A[2], True);
            PCardinal(@Result[0])^ := 0;
          end;
        $0E: PCardinal(@Result[0])^ := 2;
        $0F: // ReadChain: (sector, count, address) tuples, -1 ends
          begin
            for var T := 0 to 63 do
            begin
              var S := A[T * 3];
              var N := A[T * 3 + 1];
              var D := A[T * 3 + 2];
              if (S = $FFFFFFFF) or (N = $FFFFFFFF) or (D = $FFFFFFFF) then
                Break;
              // Bit 0 of the address selects IOP memory.
              ReadSectors(S, Integer(N), D and not Cardinal(1), (D and 1) <> 0);
            end;
          end;
      else
        PCardinal(@Result[0])^ := 1;
      end;
    $596:
      PCardinal(@Result[0])^ := 0;
    $597:
      PCardinal(@Result[0])^ := Cardinal(SearchFile(Args, Size));
    $59A, $59C:
      PCardinal(@Result[0])^ := 2;
  end;
end;

procedure TPS2CDVDServer.SerializeState(State: TStateArchive);
begin
  State.Field(FStreamPos, SizeOf(FStreamPos));
  State.Field(FStreaming, SizeOf(FStreaming));
  State.Field(FStreamBuffer, SizeOf(FStreamBuffer));
end;

end.
