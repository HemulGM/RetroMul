unit PSP.Media;

// UMD images (ISO9660 and CISO v1), PBP packages and PARAM.SFO. The disc reads
// sectors on demand from a borrowed stream.

interface

uses
  System.Classes, System.SysUtils, System.Generics.Collections, Core.Archive.Container;

type
  EPSPFormat = class(EReadError);

  TPSPDiscEntry = record
    Name: string;
    Size: Int64;
    Directory: Boolean;
    LBA: Cardinal;
    Created, Accessed, Modified: TDateTime;
  end;

  TPSPSFO = class
  private
    FStrings: TDictionary<string, string>;
    FIntegers: TDictionary<string, Cardinal>;
  public
    constructor Create(const Data: TBytes);
    destructor Destroy; override;
    function Text(const Key: string): string;
    function Number(const Key: string; Default: Cardinal = 0): Cardinal;
  end;

  TPSPDisc = class
  private
    FStream: TStream;
    FSize: Int64;
    FCompressed: Boolean;
    FBlockSize: Cardinal;
    FAlign: Byte;
    FIndex: TArray<Cardinal>;
    FRootLBA, FRootSize: Cardinal;
    FCache: TDictionary<Cardinal, TBytes>;
    FCacheOrder: TQueue<Cardinal>;
    FSectors: Cardinal;
    function ReadBlock(Block: Cardinal): TBytes;
    function ParseDirectory(LBA, Size: Cardinal): TArray<TPSPDiscEntry>;
    function Lookup(const Path: string; out Entry: TPSPDiscEntry): Boolean;
  public
    constructor Create(Stream: TStream);
    destructor Destroy; override;
    class function Recognizes(Stream: TStream): Boolean; static;
    procedure ReadSector(LBA: Cardinal; var Buffer);
    function ReadSectors(LBA, Count: Cardinal): TBytes;
    // Reads Count bytes at a byte offset within the image.
    procedure ReadAt(Offset: Int64; var Buffer; Count: Integer);
    function HasFile(const Path: string): Boolean;
    function ReadFile(const Path: string; Limit: Cardinal = 64 * 1024 * 1024): TBytes;
    function IsPSP: Boolean;
    function IsUMDVideo: Boolean;
    function OpenFile(const Path: string): TStream;
    function OpenRaw: TStream;
    function FileInfo(const Path: string; out FileSize: Int64; out Directory: Boolean): Boolean;
    function Entry(const Path: string; out Info: TPSPDiscEntry): Boolean;
    function ReadDirectory(const Path: string): TArray<TPSPDiscEntry>;
    function FileLBA(const Path: string): Cardinal;
    property Size: Int64 read FSize;
    property SectorCount: Cardinal read FSectors;
  end;

  TPSPProgram = record
    Executable, Parameters: TBytes;
    Title, DiscId, MediaPath, BootPath: string;
    TemporaryMedia, UMDVideo: Boolean;
    Archive: IArchiveContainer;
    procedure AttachArchive(const Container: IArchiveContainer; const MemberName: string);
    class function Read(Stream: TStream): TPSPProgram; static;
  end;

const
  PSPArchiveMount = '/PSP/GAME/APP';

function PSPLE16(const Data: TBytes; Offset: Int64): Word;

function PSPLE32(const Data: TBytes; Offset: Int64): Cardinal;

function ReadPBPSection(const Data: TBytes; Index: Integer): TBytes;

implementation

uses
  System.ZLib, System.Math, System.DateUtils;

function PSPLE16(const Data: TBytes; Offset: Int64): Word;
begin
  if (Offset < 0) or (Offset + 2 > Length(Data)) then
    raise EPSPFormat.Create('PSP: truncated data');
  Result := Data[Offset] or (Word(Data[Offset + 1]) shl 8);
end;

function PSPLE32(const Data: TBytes; Offset: Int64): Cardinal;
begin
  if (Offset < 0) or (Offset + 4 > Length(Data)) then
    raise EPSPFormat.Create('PSP: truncated data');
  Result := Data[Offset] or (Cardinal(Data[Offset + 1]) shl 8) or (Cardinal(Data[Offset + 2]) shl 16) or
    (Cardinal(Data[Offset + 3]) shl 24);
end;

{ TPSPSFO }

constructor TPSPSFO.Create(const Data: TBytes);
begin
  inherited Create;
  FStrings := TDictionary<string, string>.Create;
  FIntegers := TDictionary<string, Cardinal>.Create;
  if (Length(Data) < 20) or (PSPLE32(Data, 0) <> $46535000) then
    Exit;
  var KeyTable := PSPLE32(Data, 8);
  var ValueTable := PSPLE32(Data, 12);
  var Count := PSPLE32(Data, 16);
  for var I := 0 to Integer(Count) - 1 do
  begin
    var E := 20 + I * 16;
    if E + 16 > Length(Data) then
      Break;
    var KeyOffset := KeyTable + PSPLE16(Data, E);
    var Fmt := PSPLE16(Data, E + 2);
    var Len := PSPLE32(Data, E + 4);
    var ValOffset := ValueTable + PSPLE32(Data, E + 12);
    var K := '';
    var P := KeyOffset;
    while (P < Cardinal(Length(Data))) and (Data[P] <> 0) do
    begin
      K := K + Char(Data[P]);
      Inc(P);
    end;
    if Fmt = $0404 then
    begin
      if ValOffset + 4 <= Cardinal(Length(Data)) then
        FIntegers.AddOrSetValue(K, PSPLE32(Data, ValOffset));
    end
    else
    begin
      var N := Len;
      if ValOffset + N > Cardinal(Length(Data)) then
        N := Cardinal(Length(Data)) - ValOffset;
      var Raw: TBytes;
      SetLength(Raw, N);
      if N > 0 then
        Move(Data[ValOffset], Raw[0], N);
      while (Length(Raw) > 0) and (Raw[High(Raw)] = 0) do
        SetLength(Raw, Length(Raw) - 1);
      FStrings.AddOrSetValue(K, TEncoding.UTF8.GetString(Raw));
    end;
  end;
end;

destructor TPSPSFO.Destroy;
begin
  FStrings.Free;
  FIntegers.Free;
  inherited;
end;

function TPSPSFO.Text(const Key: string): string;
begin
  if not FStrings.TryGetValue(Key, Result) then
    Result := '';
end;

function TPSPSFO.Number(const Key: string; Default: Cardinal): Cardinal;
begin
  if not FIntegers.TryGetValue(Key, Result) then
    Result := Default;
end;

{ Streams over the disc }

type
  TPSPDiscStream = class(TStream)
  private
    FDisc: TPSPDisc;
    FStart, FLength, FPosition: Int64;
  protected
    function GetSize: Int64; override;
  public
    constructor Create(Disc: TPSPDisc; Start, Length: Int64);
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
  end;

constructor TPSPDiscStream.Create(Disc: TPSPDisc; Start, Length: Int64);
begin
  inherited Create;
  FDisc := Disc;
  FStart := Start;
  FLength := Length;
end;

function TPSPDiscStream.GetSize: Int64;
begin
  Result := FLength;
end;

function TPSPDiscStream.Read(var Buffer; Count: Longint): Longint;
begin
  if (Count <= 0) or (FPosition >= FLength) then
    Exit(0);
  Result := Min(Int64(Count), FLength - FPosition);
  FDisc.ReadAt(FStart + FPosition, Buffer, Result);
  Inc(FPosition, Result);
end;

function TPSPDiscStream.Write(const Buffer; Count: Longint): Longint;
begin
  raise EPSPFormat.Create('PSP: UMD is read-only');
end;

function TPSPDiscStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  case Origin of
    soBeginning:
      FPosition := Offset;
    soCurrent:
      FPosition := FPosition + Offset;
    soEnd:
      FPosition := FLength + Offset;
  end;
  if FPosition < 0 then
    FPosition := 0;
  Result := FPosition;
end;

{ TPSPDisc }

constructor TPSPDisc.Create(Stream: TStream);
begin
  inherited Create;
  FStream := Stream;
  FCache := TDictionary<Cardinal, TBytes>.Create;
  FCacheOrder := TQueue<Cardinal>.Create;
  FStream.Position := 0;
  var Head: array[0..23] of Byte;
  if FStream.Read(Head, 24) <> 24 then
    raise EPSPFormat.Create('PSP: image too small');
  if (Head[0] = Ord('C')) and (Head[1] = Ord('I')) and (Head[2] = Ord('S')) and (Head[3] = Ord('O')) then
  begin
    FCompressed := True;
    FSize := PInt64(@Head[8])^;
    FBlockSize := PCardinal(@Head[16])^;
    FAlign := Head[21];
    if FBlockSize <> 2048 then
      raise EPSPFormat.CreateFmt('PSP: CSO block size %d is unsupported', [FBlockSize]);
    var Blocks := (FSize + FBlockSize - 1) div FBlockSize;
    SetLength(FIndex, Blocks + 1);
    FStream.Position := 24;
    FStream.ReadBuffer(FIndex[0], Length(FIndex) * 4);
  end
  else
  begin
    FSize := FStream.Size;
    FBlockSize := 2048;
  end;
  FSectors := FSize div 2048;
  var PVD: array[0..2047] of Byte;
  ReadSector(16, PVD);
  if (PVD[1] <> Ord('C')) or (PVD[2] <> Ord('D')) or (PVD[3] <> Ord('0')) or (PVD[4] <> Ord('0')) or
    (PVD[5] <> Ord('1')) then
    raise EPSPFormat.Create('PSP: not an ISO9660 image');
  FRootLBA := PCardinal(@PVD[156 + 2])^;
  FRootSize := PCardinal(@PVD[156 + 10])^;
end;

destructor TPSPDisc.Destroy;
begin
  FCache.Free;
  FCacheOrder.Free;
  inherited;
end;

class function TPSPDisc.Recognizes(Stream: TStream): Boolean;
begin
  var Saved := Stream.Position;
  try
    var Head: array[0..3] of Byte;
    Stream.Position := 0;
    if Stream.Read(Head, 4) <> 4 then
      Exit(False);
    if (Head[0] = Ord('C')) and (Head[1] = Ord('I')) and (Head[2] = Ord('S')) and (Head[3] = Ord('O')) then
      Exit(True);
    if Stream.Size < 17 * 2048 then
      Exit(False);
    var Id: array[0..5] of Byte;
    Stream.Position := 16 * 2048;
    if Stream.Read(Id, 6) <> 6 then
      Exit(False);
    Result := (Id[1] = Ord('C')) and (Id[2] = Ord('D')) and (Id[3] = Ord('0')) and (Id[4] = Ord('0')) and
      (Id[5] = Ord('1'));
  finally
    Stream.Position := Saved;
  end;
end;

function TPSPDisc.ReadBlock(Block: Cardinal): TBytes;
begin
  if FCache.TryGetValue(Block, Result) then
    Exit;
  SetLength(Result, 2048);
  if not FCompressed then
  begin
    FillChar(Result[0], 2048, 0);
    var Offset := Int64(Block) * 2048;
    if Offset < FSize then
    begin
      FStream.Position := Offset;
      FStream.Read(Result[0], Min(Int64(2048), FSize - Offset));
    end;
  end
  else
  begin
    if Block + 1 >= Cardinal(Length(FIndex)) then
    begin
      FillChar(Result[0], 2048, 0);
      Exit;
    end;
    var E := FIndex[Block];
    var Start := Int64(E and $7FFFFFFF) shl FAlign;
    var Stop := Int64(FIndex[Block + 1] and $7FFFFFFF) shl FAlign;
    var Raw: TBytes;
    SetLength(Raw, Max(Int64(0), Stop - Start));
    FStream.Position := Start;
    if Length(Raw) > 0 then
      FStream.Read(Raw[0], Length(Raw));
    if (E and $80000000) <> 0 then
    begin
      FillChar(Result[0], 2048, 0);
      Move(Raw[0], Result[0], Min(2048, Length(Raw)));
    end
    else
    begin
      var Input := TBytesStream.Create(Raw);
      try
        var Z := TZDecompressionStream.Create(Input, -15);
        try
          var Got := Z.Read(Result[0], 2048);
          if Got < 2048 then
            FillChar(Result[Got], 2048 - Got, 0);
        finally
          Z.Free;
        end;
      finally
        Input.Free;
      end;
    end;
  end;
  if FCacheOrder.Count >= 256 then
    FCache.Remove(FCacheOrder.Dequeue);
  FCache.AddOrSetValue(Block, Result);
  FCacheOrder.Enqueue(Block);
end;

procedure TPSPDisc.ReadSector(LBA: Cardinal; var Buffer);
begin
  var B := ReadBlock(LBA);
  Move(B[0], Buffer, 2048);
end;

function TPSPDisc.ReadSectors(LBA, Count: Cardinal): TBytes;
begin
  SetLength(Result, Int64(Count) * 2048);
  for var I := 0 to Integer(Count) - 1 do
    ReadSector(LBA + Cardinal(I), Result[I * 2048]);
end;

procedure TPSPDisc.ReadAt(Offset: Int64; var Buffer; Count: Integer);
begin
  if (not FCompressed) and (Count > 4096) then
  begin
    // Large uncompressed reads go straight to the stream.
    FillChar(Buffer, Count, 0);
    if Offset < FSize then
    begin
      FStream.Position := Offset;
      FStream.Read(Buffer, Min(Int64(Count), FSize - Offset));
    end;
    Exit;
  end;
  var Done := 0;
  while Done < Count do
  begin
    var Pos := Offset + Done;
    var B := ReadBlock(Cardinal(Pos div 2048));
    var InBlock := Integer(Pos mod 2048);
    var N := Min(Count - Done, 2048 - InBlock);
    Move(B[InBlock], PByte(@Buffer)[Done], N);
    Inc(Done, N);
  end;
end;

function ISODate(const R: TBytes; Offset: Integer): TDateTime;
begin
  try
    Result := EncodeDateTime(1900 + R[Offset], Max(1, R[Offset + 1]), Max(1, R[Offset + 2]), R[Offset + 3] mod 24,
      R[Offset + 4] mod 60, R[Offset + 5] mod 60, 0);
  except
    Result := 0;
  end;
end;

function TPSPDisc.ParseDirectory(LBA, Size: Cardinal): TArray<TPSPDiscEntry>;
begin
  Result := nil;
  if Size > 16 * 1024 * 1024 then
    Exit;
  var Data := ReadSectors(LBA, (Size + 2047) div 2048);
  var P := 0;
  while P < Integer(Size) do
  begin
    var Len := Data[P];
    if Len = 0 then
    begin
      P := (P div 2048 + 1) * 2048;
      Continue;
    end;
    if P + Len > Length(Data) then
      Break;
    var NameLen := Data[P + 32];
    var E := Default(TPSPDiscEntry);
    E.LBA := PCardinal(@Data[P + 2])^;
    E.Size := PCardinal(@Data[P + 10])^;
    E.Directory := (Data[P + 25] and 2) <> 0;
    E.Created := ISODate(Data, P + 18);
    E.Modified := E.Created;
    E.Accessed := E.Created;
    if (NameLen = 1) and (Data[P + 33] <= 1) then
    begin
      if Data[P + 33] = 0 then
        E.Name := '.'
      else
        E.Name := '..';
    end
    else
    begin
      var Raw: TBytes;
      SetLength(Raw, NameLen);
      Move(Data[P + 33], Raw[0], NameLen);
      E.Name := TEncoding.ANSI.GetString(Raw);
      var Semi := E.Name.IndexOf(';');
      if Semi >= 0 then
        E.Name := E.Name.Substring(0, Semi);
    end;
    Result := Result + [E];
    Inc(P, Len);
  end;
end;

function TPSPDisc.Lookup(const Path: string; out Entry: TPSPDiscEntry): Boolean;
begin
  Entry := Default(TPSPDiscEntry);
  Entry.LBA := FRootLBA;
  Entry.Size := FRootSize;
  Entry.Directory := True;
  Entry.Name := '';
  var Parts := Path.Replace('\', '/').Split(['/'], TStringSplitOptions.ExcludeEmpty);
  for var Part in Parts do
  begin
    if Part = '.' then
      Continue;
    if not Entry.Directory then
      Exit(False);
    var Found := False;
    for var E in ParseDirectory(Entry.LBA, Entry.Size) do
      if SameText(E.Name, Part) then
      begin
        Entry := E;
        Found := True;
        Break;
      end;
    if not Found then
      Exit(False);
  end;
  Result := True;
end;

function TPSPDisc.Entry(const Path: string; out Info: TPSPDiscEntry): Boolean;
begin
  Result := Lookup(Path, Info);
end;

function TPSPDisc.HasFile(const Path: string): Boolean;
begin
  var E: TPSPDiscEntry;
  Result := Lookup(Path, E) and not E.Directory;
end;

function TPSPDisc.ReadFile(const Path: string; Limit: Cardinal): TBytes;
begin
  var E: TPSPDiscEntry;
  if not Lookup(Path, E) or E.Directory then
    raise EPSPFormat.CreateFmt('PSP: %s not found on the disc', [Path]);
  if E.Size > Limit then
    raise EPSPFormat.CreateFmt('PSP: %s is too large', [Path]);
  SetLength(Result, E.Size);
  if E.Size > 0 then
    ReadAt(Int64(E.LBA) * 2048, Result[0], E.Size);
end;

function TPSPDisc.IsPSP: Boolean;
begin
  Result := HasFile('PSP_GAME/PARAM.SFO') or HasFile('PSP_GAME/SYSDIR/EBOOT.BIN') or IsUMDVideo;
end;

function TPSPDisc.IsUMDVideo: Boolean;
begin
  Result := HasFile('UMD_VIDEO/PLAYLIST.UMD') and HasFile('UMD_VIDEO/PARAM.SFO');
end;

function TPSPDisc.OpenFile(const Path: string): TStream;
begin
  var E: TPSPDiscEntry;
  if not Lookup(Path, E) or E.Directory then
    raise EPSPFormat.CreateFmt('PSP: %s not found on the disc', [Path]);
  Result := TPSPDiscStream.Create(Self, Int64(E.LBA) * 2048, E.Size);
end;

function TPSPDisc.OpenRaw: TStream;
begin
  Result := TPSPDiscStream.Create(Self, 0, FSize);
end;

function TPSPDisc.FileInfo(const Path: string; out FileSize: Int64; out Directory: Boolean): Boolean;
begin
  var E: TPSPDiscEntry;
  Result := Lookup(Path, E);
  FileSize := E.Size;
  Directory := E.Directory;
end;

function TPSPDisc.ReadDirectory(const Path: string): TArray<TPSPDiscEntry>;
begin
  var E: TPSPDiscEntry;
  if not Lookup(Path, E) or not E.Directory then
    raise EPSPFormat.CreateFmt('PSP: directory %s not found', [Path]);
  Result := ParseDirectory(E.LBA, E.Size);
end;

function TPSPDisc.FileLBA(const Path: string): Cardinal;
begin
  var E: TPSPDiscEntry;
  if not Lookup(Path, E) then
    raise EPSPFormat.CreateFmt('PSP: %s not found on the disc', [Path]);
  Result := E.LBA;
end;

{ TPSPProgram }

function ReadPBPSection(const Data: TBytes; Index: Integer): TBytes;
begin
  if (Length(Data) < 40) or (PSPLE32(Data, 0) <> $50425000) then
    raise EPSPFormat.Create('PSP: not a PBP');
  var Start := PSPLE32(Data, 8 + Index * 4);
  var Stop: Cardinal;
  if Index < 7 then
    Stop := PSPLE32(Data, 12 + Index * 4)
  else
    Stop := Length(Data);
  if (Start > Cardinal(Length(Data))) or (Stop > Cardinal(Length(Data))) or (Stop < Start) then
    raise EPSPFormat.Create('PSP: damaged PBP');
  SetLength(Result, Stop - Start);
  if Stop > Start then
    Move(Data[Start], Result[0], Stop - Start);
end;

function IsExecutable(const Data: TBytes): Boolean;
begin
  Result := (Length(Data) >= 4) and (((Data[0] = $7F) and (Data[1] = Ord('E')) and (Data[2] = Ord('L')) and
    (Data[3] = Ord('F'))) or ((Data[0] = Ord('~')) and (Data[1] = Ord('P')) and (Data[2] = Ord('S')) and
    (Data[3] = Ord('P'))) or ((Data[0] = Ord('~')) and (Data[1] = Ord('S')) and (Data[2] = Ord('C')) and
    (Data[3] = Ord('E'))));
end;

procedure TPSPProgram.AttachArchive(const Container: IArchiveContainer; const MemberName: string);
begin
  if (Container = nil) or (BootPath <> '') then
    Exit;
  // Preserve the package tree: relative opens and explicit ms0: paths refer to
  // the same files. Member names never become native filesystem paths.
  for var Name in Container.Names do
  begin
    var Path := Name.Replace('\', '/');
    if Path.StartsWith('/') or Path.Contains(':') or Path.Contains(#0) then
      raise EPSPFormat.Create('PSP: invalid archive path: ' + Name);
    for var Part in Path.Split(['/']) do
      if (Part = '..') or (Part = '.') then
        raise EPSPFormat.Create('PSP: invalid archive path: ' + Name);
  end;
  Archive := Container;
  BootPath := 'ms0:' + PSPArchiveMount + '/' + MemberName.Replace('\', '/');
end;

class function TPSPProgram.Read(Stream: TStream): TPSPProgram;
begin
  Result := Default(TPSPProgram);
  if TPSPDisc.Recognizes(Stream) then
  begin
    var Disc := TPSPDisc.Create(Stream);
    try
      if not Disc.IsPSP then
        raise EPSPFormat.Create('PSP: the image holds no PSP game or UMD Video');
      Result.UMDVideo := Disc.IsUMDVideo;
      if Result.UMDVideo then
      begin
        Result.Parameters := Disc.ReadFile('UMD_VIDEO/PARAM.SFO');
        Result.BootPath := 'disc0:/UMD_VIDEO/PLAYLIST.UMD';
      end
      else
      begin
        if Disc.HasFile('PSP_GAME/PARAM.SFO') then
          Result.Parameters := Disc.ReadFile('PSP_GAME/PARAM.SFO');
        Result.BootPath := 'disc0:/PSP_GAME/SYSDIR/EBOOT.BIN';
        if Disc.HasFile('PSP_GAME/SYSDIR/EBOOT.BIN') then
          Result.Executable := Disc.ReadFile('PSP_GAME/SYSDIR/EBOOT.BIN');
        // Discs patched to boot through a custom-firmware loader keep the
        // game's own executable as EBOOT.OLD.
        if Disc.HasFile('PSP_GAME/SYSDIR/EBOOT.OLD') then
        begin
          var Old := Disc.ReadFile('PSP_GAME/SYSDIR/EBOOT.OLD');
          if IsExecutable(Old) then
            Result.Executable := Old;
        end;
        if not IsExecutable(Result.Executable) and Disc.HasFile('PSP_GAME/SYSDIR/BOOT.BIN') then
        begin
          var Boot := Disc.ReadFile('PSP_GAME/SYSDIR/BOOT.BIN');
          if IsExecutable(Boot) then
          begin
            Result.Executable := Boot;
            Result.BootPath := 'disc0:/PSP_GAME/SYSDIR/BOOT.BIN';
          end;
        end;
      end;
    finally
      Disc.Free;
    end;
  end
  else
  begin
    var Data: TBytes;
    Stream.Position := 0;
    SetLength(Data, Stream.Size);
    if Length(Data) > 0 then
      Stream.ReadBuffer(Data[0], Length(Data));
    if (Length(Data) >= 4) and (PSPLE32(Data, 0) = $50425000) then
    begin
      Result.Parameters := ReadPBPSection(Data, 0);
      Result.Executable := ReadPBPSection(Data, 6);
    end
    else
      Result.Executable := Data;
    if not IsExecutable(Result.Executable) then
      raise EPSPFormat.Create('PSP: no executable');
    if Stream is TArchiveImageStream then
      Result.AttachArchive(TArchiveImageStream(Stream).Container, TArchiveImageStream(Stream).MemberName);
  end;
  if Length(Result.Parameters) > 0 then
  begin
    var SFO := TPSPSFO.Create(Result.Parameters);
    try
      Result.Title := SFO.Text('TITLE');
      Result.DiscId := SFO.Text('DISC_ID');
    finally
      SFO.Free;
    end;
  end;
end;

end.

