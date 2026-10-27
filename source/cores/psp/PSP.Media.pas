unit PSP.Media;

interface

uses
  System.Classes, System.SysUtils, System.Generics.Collections;

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

  // Borrowed stream. Reads ISO9660 UMD and CISO v1 without loading the disc.
  TPSPDisc = class
  private
    FStream: TStream;
    FSize: Int64;
    FCompressed: Boolean;
    FBlockSize, FAlignment: Cardinal;
    FIndex: TArray<Cardinal>;
    FRootLBA, FRootSize: Cardinal;
    FCacheBlock: Int64;
    FCache: TBytes;
    procedure ReadAt(Offset: Int64; var Buffer; Count: Integer);
    procedure ReadBlock(Index: Cardinal; out Data: TBytes);
    function ReadExtent(LBA, Size, Limit: Cardinal): TBytes;
    function FindEntry(const Path: string; out LBA, Size: Cardinal; out Directory: Boolean): Boolean;
  public
    constructor Create(Stream: TStream);
    class function Recognizes(Stream: TStream): Boolean; static;
    function HasFile(const Path: string): Boolean;
    function ReadFile(const Path: string; Limit: Cardinal = 64 * 1024 * 1024): TBytes;
    function IsPSP: Boolean;
    function OpenFile(const Path: string): TStream;
    function OpenRaw: TStream;
    function ReadSectors(LBA, Count: Cardinal): TBytes;
    function FileInfo(const Path: string; out FileSize: Int64; out Directory: Boolean): Boolean;
    function ReadDirectory(const Path: string): TArray<TPSPDiscEntry>;
    function FileLBA(const Path: string): Cardinal;
    property Size: Int64 read FSize;
  end;

  TPSPProgram = record
    Executable, Parameters: TBytes;
    Title, DiscId, MediaPath, BootPath: string;
    TemporaryMedia: Boolean;
    class function Read(Stream: TStream): TPSPProgram; static;
  end;

function PSPLE16(const Data: TBytes; Offset: Int64): Word;

function PSPLE32(const Data: TBytes; Offset: Int64): Cardinal;

implementation

uses
  System.ZLib, System.Math, System.DateUtils, PSP.PRX;

type
  TPSPDiscStream = class(TStream)
  private
    FDisc: TPSPDisc;
    FStart, FLength, FPosition: Int64;
  protected
    function GetSize: Int64; override;
  public
    constructor Create(Disc: TPSPDisc; LBA, Size: Cardinal);
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
  end;

constructor TPSPDiscStream.Create(Disc: TPSPDisc; LBA, Size: Cardinal);
begin
  inherited Create;
  FDisc := Disc;
  FStart := Int64(LBA) * 2048;
  FLength := Size;
  if (FStart > Disc.Size) or (FLength > Disc.Size - FStart) then
    raise EPSPFormat.Create('PSP: UMD file outside image');
end;

function TPSPDiscStream.GetSize: Int64;
begin
  Result := FLength;
end;

function TPSPDiscStream.Read(var Buffer; Count: Longint): Longint;
begin
  if Count <= 0 then
    Exit(0);
  if FPosition >= FLength then
    Exit(0);
  Result := Min(Int64(Count), FLength - FPosition);
  var Done := 0;
  while Done < Result do
  begin
    var Offset := FStart + FPosition + Done;
    var Sector: TBytes;
    FDisc.ReadBlock(Offset div 2048, Sector);
    var InSector := Integer(Offset mod 2048);
    var N := Min(Result - Done, 2048 - InSector);
    Move(Sector[InSector], PByte(@Buffer)[Done], N);
    Inc(Done, N);
  end;
  Inc(FPosition, Result);
end;

function TPSPDiscStream.Write(const Buffer; Count: Longint): Longint;
begin
  raise EWriteError.Create('PSP: UMD is read only');
end;

function TPSPDiscStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  var NewPosition := Offset;
  case Origin of
    soCurrent:
      NewPosition := FPosition + Offset;
    soEnd:
      NewPosition := FLength + Offset;
  end;
  if NewPosition < 0 then
    raise EStreamError.Create('PSP: negative UMD seek');
  FPosition := NewPosition;
  Result := FPosition;
end;

procedure CheckRange(const Data: TBytes; Offset, Count: Int64);
begin
  if (Offset < 0) or (Count < 0) or (Offset > Length(Data)) or
    (Count > Length(Data) - Offset) then
    raise EPSPFormat.Create('PSP: truncated or invalid container');
end;

function PSPLE16(const Data: TBytes; Offset: Int64): Word;
begin
  CheckRange(Data, Offset, 2);
  Result := Word(Data[Offset]) or (Word(Data[Offset + 1]) shl 8);
end;

function PSPLE32(const Data: TBytes; Offset: Int64): Cardinal;
begin
  CheckRange(Data, Offset, 4);
  Result := Cardinal(Data[Offset]) or (Cardinal(Data[Offset + 1]) shl 8) or
    (Cardinal(Data[Offset + 2]) shl 16) or (Cardinal(Data[Offset + 3]) shl 24);
end;

function ZeroText(const Data: TBytes; Start, Limit: Int64): string;
begin
  CheckRange(Data, Start, Limit);
  var Count: Int64 := 0;
  while (Count < Limit) and (Data[Start + Count] <> 0) do
    Inc(Count);
  if Count = Limit then
    raise EPSPFormat.Create('PSP: unterminated container string');
  Result := TEncoding.UTF8.GetString(Data, Start, Count);
end;

constructor TPSPSFO.Create(const Data: TBytes);
begin
  inherited Create;
  FStrings := TDictionary<string, string>.Create;
  FIntegers := TDictionary<string, Cardinal>.Create;
  if Length(Data) = 0 then
    Exit;
  if (Length(Data) < 20) or (PSPLE32(Data, 0) <> $46535000) or
    (PSPLE32(Data, 4) <> $101) then
    raise EPSPFormat.Create('PSP: invalid PARAM.SFO header');
  var Keys := Int64(PSPLE32(Data, 8));
  var Values := Int64(PSPLE32(Data, 12));
  var Count := PSPLE32(Data, 16);
  CheckRange(Data, 20, Int64(Count) * 16);
  if (Keys < 20 + Int64(Count) * 16) or (Values < Keys) or (Values > Length(Data)) then
    raise EPSPFormat.Create('PSP: invalid PARAM.SFO tables');
  for var I := 0 to Int64(Count) - 1 do
  begin
    var Entry := 20 + I * 16;
    var K := Keys + PSPLE16(Data, Entry);
    if K >= Values then
      raise EPSPFormat.Create('PSP: invalid SFO key offset');
    var Name := ZeroText(Data, K, Values - K);
    var Used := PSPLE32(Data, Entry + 4);
    var Capacity := PSPLE32(Data, Entry + 8);
    var V := Values + PSPLE32(Data, Entry + 12);
    if Used > Capacity then
      raise EPSPFormat.Create('PSP: invalid SFO value size');
    CheckRange(Data, V, Capacity);
    case PSPLE16(Data, Entry + 2) of
      $0204:
        FStrings.AddOrSetValue(Name, ZeroText(Data, V, Used));
      $0404:
        begin
          if Used <> 4 then
            raise EPSPFormat.Create('PSP: invalid SFO integer');
          FIntegers.AddOrSetValue(Name, PSPLE32(Data, V));
        end;
    end;
  end;
end;

destructor TPSPSFO.Destroy;
begin
  FIntegers.Free;
  FStrings.Free;
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

procedure TPSPDisc.ReadAt(Offset: Int64; var Buffer; Count: Integer);
begin
  if (Offset < 0) or (Count < 0) or (Offset > FStream.Size) or
    (Count > FStream.Size - Offset) then
    raise EPSPFormat.Create('PSP: disc read outside image');
  FStream.Position := Offset;
  FStream.ReadBuffer(Buffer, Count);
end;

class function TPSPDisc.Recognizes(Stream: TStream): Boolean;
begin
  var Saved := Stream.Position;
  try
    Result := False;
    var Magic: array[0..7] of Byte;
    Stream.Position := 0;
    if Stream.Read(Magic, 4) = 4 then
      if (Magic[0] = Ord('C')) and (Magic[1] = Ord('I')) and
        (Magic[2] = Ord('S')) and (Magic[3] = Ord('O')) then
        Exit(True);
    if Stream.Size < 17 * 2048 then
      Exit;
    Stream.Position := 16 * 2048;
    Stream.ReadBuffer(Magic, 7);
    Result := (Magic[0] = 1) and (Magic[1] = Ord('C')) and (Magic[2] = Ord('D')) and
      (Magic[3] = Ord('0')) and (Magic[4] = Ord('0')) and (Magic[5] = Ord('1')) and (Magic[6] = 1);
  finally
    Stream.Position := Saved;
  end;
end;

constructor TPSPDisc.Create(Stream: TStream);
begin
  inherited Create;
  if Stream = nil then
    raise EArgumentNilException.Create('Stream');
  FStream := Stream;
  FCacheBlock := -1;
  FBlockSize := 2048;
  FSize := Stream.Size;
  var Header: TBytes;
  SetLength(Header, 24);
  ReadAt(0, Header[0], Length(Header));
  FCompressed := PSPLE32(Header, 0) = $4F534943;
  if FCompressed then
  begin
    var HeaderSize := PSPLE32(Header, 4);
    FSize := Int64(UInt64(PSPLE32(Header, 8)) or (UInt64(PSPLE32(Header, 12)) shl 32));
    FBlockSize := PSPLE32(Header, 16);
    FAlignment := Header[21];
    if (HeaderSize < 24) or (Header[20] <> 1) or (FBlockSize <> 2048) or
      (FAlignment > 16) or (FSize < 17 * 2048) or (FSize > Int64(4) * 1024 * 1024 * 1024) then
      raise EPSPFormat.Create('PSP: unsupported or invalid CISO header (v1/2048 required)');
    var Entries := (FSize + FBlockSize - 1) div FBlockSize + 1;
    if Int64(HeaderSize) + Entries * 4 > Stream.Size then
      raise EPSPFormat.Create('PSP: truncated CISO index');
    SetLength(Header, Entries * 4);
    ReadAt(HeaderSize, Header[0], Length(Header));
    SetLength(FIndex, Entries);
    var Previous := Int64(HeaderSize) + Entries * 4;
    for var I := 0 to High(FIndex) do
    begin
      FIndex[I] := PSPLE32(Header, Int64(I) * 4);
      var Offset := Int64(FIndex[I] and $7FFFFFFF) shl FAlignment;
      if (Offset < Previous) or (Offset > Stream.Size) then
        raise EPSPFormat.Create('PSP: invalid CISO block offset');
      Previous := Offset;
    end;
  end;
  var PVD := ReadExtent(16, 2048, 2048);
  if (PVD[0] <> 1) or (TEncoding.ASCII.GetString(PVD, 1, 5) <> 'CD001') or
    (PVD[6] <> 1) or (PSPLE16(PVD, 128) <> 2048) or (PVD[156] < 34) then
    raise EPSPFormat.Create('PSP: invalid ISO9660 primary volume');
  FRootLBA := PSPLE32(PVD, 158);
  FRootSize := PSPLE32(PVD, 166);
end;

procedure TPSPDisc.ReadBlock(Index: Cardinal; out Data: TBytes);
begin
  if Int64(Index) * FBlockSize >= FSize then
    raise EPSPFormat.Create('PSP: invalid UMD block');
  if FCacheBlock = Index then
  begin
    Data := FCache;
    Exit;
  end;
  SetLength(Data, FBlockSize);
  if not FCompressed then
    ReadAt(Int64(Index) * FBlockSize, Data[0], Length(Data))
  else
  begin
    var Start := Int64(FIndex[Index] and $7FFFFFFF) shl FAlignment;
    var Finish := Int64(FIndex[Index + 1] and $7FFFFFFF) shl FAlignment;
    if FIndex[Index] and $80000000 <> 0 then
    begin
      if Finish - Start < FBlockSize then
        raise EPSPFormat.Create('PSP: truncated plain CISO block');
      ReadAt(Start, Data[0], Length(Data));
    end
    else
    begin
      // A sector cannot require an unbounded compressed allocation.
      if (Finish <= Start) or (Finish - Start > FBlockSize + (Int64(1) shl FAlignment) + 256) then
        raise EPSPFormat.Create('PSP: invalid compressed CISO block size');
      var CompressedData: TBytes;
      SetLength(CompressedData, Finish - Start);
      ReadAt(Start, CompressedData[0], Length(CompressedData));
      var Input := TBytesStream.Create(CompressedData);
      try
        var Decoder := TZDecompressionStream.Create(Input, -15);
        try
          Decoder.ReadBuffer(Data[0], Length(Data));
          var Extra: Byte;
          if Decoder.Read(Extra, 1) <> 0 then
            raise EPSPFormat.Create('PSP: oversized CISO sector');
        finally
          Decoder.Free;
        end;
      finally
        Input.Free;
      end;
    end;
  end;
  FCache := Data;
  FCacheBlock := Index;
end;

function TPSPDisc.ReadExtent(LBA, Size, Limit: Cardinal): TBytes;
begin
  if (Size > Limit) or (Int64(LBA) * 2048 > FSize) or
    (Size > FSize - Int64(LBA) * 2048) then
    raise EPSPFormat.Create('PSP: invalid or oversized ISO9660 extent');
  SetLength(Result, Size);
  var Done: Cardinal := 0;
  while Done < Size do
  begin
    var Sector: TBytes;
    ReadBlock(LBA + Done div 2048, Sector);
    var N := Min(Cardinal(2048), Size - Done);
    Move(Sector[0], Result[Done], N);
    Inc(Done, N);
  end;
end;

function TPSPDisc.FindEntry(const Path: string; out LBA, Size: Cardinal; out Directory: Boolean): Boolean;
begin
  LBA := 0;
  Size := 0;
  Directory := False;
  var RawName := Path.Trim(['/']).ToLower;
  if RawName.StartsWith('sce_lbn') then
  begin
    Result := False;
    Directory := False;
    var Separator := RawName.IndexOf('_size');
    if Separator < 7 then
      Exit;
    var LBAText := RawName.Substring(7, Separator - 7);
    var SizeText := RawName.Substring(Separator + 5);
    if LBAText.StartsWith('0x') then
      LBAText := LBAText.Substring(2);
    if SizeText.StartsWith('0x') then
      SizeText := SizeText.Substring(2);
    var LBAValue, SizeValue: UInt64;
    if not TryStrToUInt64('$' + LBAText, LBAValue) or not TryStrToUInt64('$' + SizeText, SizeValue) or
      (LBAValue > High(Cardinal)) or (SizeValue > High(Cardinal)) then
      Exit;
    if (LBAValue * 2048 > UInt64(FSize)) or (SizeValue > UInt64(FSize) - LBAValue * 2048) then
      Exit;
    LBA := Cardinal(LBAValue);
    Size := Cardinal(SizeValue);
    Exit(True);
  end;
  LBA := FRootLBA;
  Size := FRootSize;
  Directory := True;
  for var Part in Path.Replace('\', '/').Split(['/'], TStringSplitOptions.ExcludeEmpty) do
  begin
    if not Directory then
      Exit(False);
    var Data := ReadExtent(LBA, Size, 8 * 1024 * 1024);
    var Pos := 0;
    var Found := False;
    while Pos < Length(Data) do
    begin
      var N := Integer(Data[Pos]);
      if N = 0 then
      begin
        Pos := ((Pos div 2048) + 1) * 2048;
        Continue;
      end;
      CheckRange(Data, Pos, N);
      if (N < 34) or ((Pos mod 2048) + N > 2048) or (Integer(Data[Pos + 32]) > N - 33) then
        raise EPSPFormat.Create('PSP: malformed ISO9660 directory record');
      var Name := TEncoding.ASCII.GetString(Data, Pos + 33, Data[Pos + 32]);
      if Name.EndsWith(';1') then
        Name := Name.Substring(0, Name.Length - 2);
      if SameText(Name, Part) then
      begin
        if Data[Pos + 25] and $80 <> 0 then
          raise EPSPFormat.Create('PSP: multi-extent ISO files are unsupported');
        LBA := PSPLE32(Data, Pos + 2);
        Size := PSPLE32(Data, Pos + 10);
        Directory := Data[Pos + 25] and 2 <> 0;
        Found := True;
        Break;
      end;
      Inc(Pos, N);
    end;
    if not Found then
      Exit(False);
  end;
  Result := True;
end;

function TPSPDisc.HasFile(const Path: string): Boolean;
begin
  var LBA, Size: Cardinal;
  var Directory: Boolean;
  Result := FindEntry(Path, LBA, Size, Directory) and not Directory;
end;

function TPSPDisc.ReadFile(const Path: string; Limit: Cardinal): TBytes;
begin
  var LBA, Size: Cardinal;
  var Directory: Boolean;
  if not FindEntry(Path, LBA, Size, Directory) or Directory then
    raise EPSPFormat.Create('PSP: UMD file not found: ' + Path);
  Result := ReadExtent(LBA, Size, Limit);
end;

function TPSPDisc.IsPSP: Boolean;
begin
  Result := HasFile('PSP_GAME/PARAM.SFO') and HasFile('PSP_GAME/SYSDIR/EBOOT.BIN');
end;

function TPSPDisc.OpenRaw: TStream;
begin
  if FSize > High(Cardinal) then
    raise EPSPFormat.Create('PSP: UMD image exceeds device address range');
  Result := TPSPDiscStream.Create(Self, 0, Cardinal(FSize));
end;

function TPSPDisc.ReadSectors(LBA, Count: Cardinal): TBytes;
begin
  if Count > 32768 then
    raise EPSPFormat.Create('PSP: oversized UMD sector request');
  Result := ReadExtent(LBA, Count * 2048, 64 * 1024 * 1024);
end;

function TPSPDisc.OpenFile(const Path: string): TStream;
begin
  var LBA, Size: Cardinal;
  var Directory: Boolean;
  if not FindEntry(Path, LBA, Size, Directory) or Directory then
    raise EFOpenError.CreateFmt('PSP: UMD file not found: %s', [Path]);
  Result := TPSPDiscStream.Create(Self, LBA, Size);
end;

function TPSPDisc.FileInfo(const Path: string; out FileSize: Int64; out Directory: Boolean): Boolean;
begin
  var LBA, Size: Cardinal;
  Result := FindEntry(Path, LBA, Size, Directory);
  FileSize := Size;
end;

function TPSPDisc.FileLBA(const Path: string): Cardinal;
begin
  var Size: Cardinal;
  var Directory: Boolean;
  if not FindEntry(Path, Result, Size, Directory) then
    Result := 0;
end;

function TPSPDisc.ReadDirectory(const Path: string): TArray<TPSPDiscEntry>;
begin
  var LBA, Size: Cardinal;
  var Directory: Boolean;
  if not FindEntry(Path, LBA, Size, Directory) or not Directory then
    raise EFOpenError.CreateFmt('PSP: UMD directory not found: %s', [Path]);
  var Data := ReadExtent(LBA, Size, 8 * 1024 * 1024);
  var Entries := TList<TPSPDiscEntry>.Create;
  try
    var At := 0;
    while At < Length(Data) do
    begin
      var Count := Integer(Data[At]);
      if Count = 0 then
      begin
        At := ((At div 2048) + 1) * 2048;
        Continue;
      end;
      CheckRange(Data, At, Count);
      if (Count < 34) or ((At mod 2048) + Count > 2048) or (Data[At + 32] > Count - 33) then
        raise EPSPFormat.Create('PSP: malformed ISO9660 directory record');
      if (Data[At + 32] = 1) and (Data[At + 33] in [0, 1]) then
      begin
        Inc(At, Count);
        Continue;
      end;
      var Entry := Default(TPSPDiscEntry);
      Entry.Name := TEncoding.ASCII.GetString(Data, At + 33, Data[At + 32]);
      if Entry.Name.EndsWith(';1') then
        Entry.Name := Entry.Name.Substring(0, Entry.Name.Length - 2);
      Entry.LBA := PSPLE32(Data, At + 2);
      Entry.Size := PSPLE32(Data, At + 10);
      Entry.Directory := Data[At + 25] and 2 <> 0;
      if Data[At + 25] and $80 <> 0 then
        raise EPSPFormat.Create('PSP: multi-extent ISO files are unsupported');
      TryEncodeDateTime(1900 + Data[At + 18], Data[At + 19], Data[At + 20], Data[At + 21], Data[At + 22], Data[At + 23], 0, Entry.Modified);
      Entry.Created := Entry.Modified;
      Entry.Accessed := Entry.Modified;
      Entries.Add(Entry);
      Inc(At, Count);
    end;
    Result := Entries.ToArray;
  finally
    Entries.Free;
  end;
end;

class function TPSPProgram.Read(Stream: TStream): TPSPProgram;
begin
  Result := Default(TPSPProgram);
  var Saved := Stream.Position;
  try
    if TPSPDisc.Recognizes(Stream) then
    begin
      var Disc := TPSPDisc.Create(Stream);
      try
        if not Disc.IsPSP then
          raise EPSPFormat.Create('PSP: image does not contain PSP_GAME');
        Result.BootPath := 'disc0:/PSP_GAME/SYSDIR/EBOOT.BIN';
        Result.Parameters := Disc.ReadFile('PSP_GAME/PARAM.SFO', 1024 * 1024);
        Result.Executable := Disc.ReadFile('PSP_GAME/SYSDIR/EBOOT.BIN');
        if (Length(Result.Executable) >= 4) and (PSPLE32(Result.Executable, 0) <> $464C457F) and
          Disc.HasFile('PSP_GAME/SYSDIR/BOOT.BIN') then
        begin
          var Boot := Disc.ReadFile('PSP_GAME/SYSDIR/BOOT.BIN');
          if (Length(Boot) >= 4) and (PSPLE32(Boot, 0) = $464C457F) then
            Result.Executable := Boot;
        end;
      finally
        Disc.Free;
      end;
    end
    else
    begin
      if (Stream.Size < 4) or (Stream.Size > 64 * 1024 * 1024) then
        raise EPSPFormat.Create('PSP: executable size must be between 4 bytes and 64 MiB');
      var Data: TBytes;
      SetLength(Data, Stream.Size);
      Stream.Position := 0;
      Stream.ReadBuffer(Data[0], Length(Data));
      if PSPLE32(Data, 0) = $50425000 then
      begin
        CheckRange(Data, 0, 40);
        var Offsets: array[0..8] of Cardinal;
        for var I := 0 to 7 do
        begin
          Offsets[I] := PSPLE32(Data, 8 + I * 4);
          if (Offsets[I] < 40) or (Offsets[I] > Cardinal(Length(Data))) then
            raise EPSPFormat.Create('PSP: invalid PBP section offset');
          if (I > 0) and (Offsets[I] < Offsets[I - 1]) then
            raise EPSPFormat.Create('PSP: unordered PBP sections');
        end;
        Offsets[8] := Length(Data);
        Result.Parameters := Copy(Data, Offsets[0], Offsets[1] - Offsets[0]);
        Result.Executable := Copy(Data, Offsets[6], Offsets[7] - Offsets[6]);
      end
      else
        Result.Executable := Data;
    end;
    var SFO := TPSPSFO.Create(Result.Parameters);
    try
      Result.Title := SFO.Text('TITLE');
      Result.DiscId := SFO.Text('DISC_ID');
    finally
      SFO.Free;
    end;
    Result.Executable := DecryptPSPPRX(Result.Executable);
    if (Length(Result.Executable) < 52) or (PSPLE32(Result.Executable, 0) <> $464C457F) then
      raise EPSPFormat.Create('PSP: expected an unencrypted ELF32 executable');
  finally
    Stream.Position := Saved;
  end;
end;

end.

