unit PS2.IOP.MemoryCard;

// Memory cards: each card is its flash with the PS2 card file system on it
// (TPS2MemoryCard, saved by the front end as one file), and a high-level
// MCSERV/XMCSERV RPC server (SID 80000400h) for libmc working on that file
// system. It
// takes both function sets (70h..80h of MCSERV, 01h..15h, 33h and FEh of
// XMCSERV), the parameter blocks libmc sends and the result block it reads
// (result, MCSERV and MCMAN versions), and behaves as MCMAN does on a
// formatted 8 MB card: the first access after a card appears reports a new
// card, at most three files are open, directories list in creation order
// ('.' and '..' except in the root) with '*' and '?' patterns, a file
// created over an existing one replaces it, and file times come from the
// console clock.
// Games that bring their own card driver (MCMAN/XMCMAN over SIO2) reach the
// same flash page by page (TPS2CardLink): 16384 pages of 512 bytes with 16
// spare bytes for ECC, erased in blocks of 16 pages. A new card is
// formatted and empty.
// References: ps2sdk libmc, mcserv and mcman (AFL 2.0; interface, data
// layouts, result codes, the file system structures and the card command
// set), ps2tek (SIO2 PS2 memory card commands, superblock).
{$IFDEF PS2_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$POINTERMATH ON}

interface

uses
  System.SysUtils, System.Classes, System.Math, System.DateUtils, System.Generics.Collections,
  System.Generics.Defaults, System.ZLib, Core.Snapshots, PS2.Types, PS2.SIF;

const
  PS2MCServerSID = $80000400;
  PS2MemoryCardMagic: array[0..7] of AnsiChar = 'RMPS2MC3';
  PS2MemoryCardMagic2: array[0..7] of AnsiChar = 'RMPS2MC2';
  PS2MemoryCardMagic1: array[0..7] of AnsiChar = 'RMPS2MC1';
  PS2CardNoCluster = $FFFFFFFF;
  // The card as flash: pages of data and spare bytes, erase blocks.
  PS2CardPageSize = 512;
  PS2CardSpareSize = 16;
  PS2CardRawPage = PS2CardPageSize + PS2CardSpareSize;
  PS2CardBlockPages = 16;
  PS2CardPages = 16384;
  PS2CardFlashSize = PS2CardPages * PS2CardRawPage;

type
  // A directory entry of the card's file system (512 bytes on the card):
  // where it is (the first cluster of its directory and its index there)
  // and its fields. Clusters count from the first allocatable one; a file
  // without data has no cluster (PS2CardNoCluster).
  TPS2CardEntry = record
    DirCluster: Cardinal;
    Index: Integer;
    Mode: Word;
    Length: Cardinal;
    // sceMcStDateTime: unused, second, minute, hour, day, month, year (16).
    Created, Modified: UInt64;
    Cluster, DirEntry, Attr: Cardinal;
    Name: string;
    function IsDirectory: Boolean;
    function Exists: Boolean;
  end;

  // A card: its flash (16384 pages of 512 data and 16 spare bytes) and the
  // PS2 card file system on it, as MCMAN formats and keeps it (superblock,
  // indirect FAT, FAT, directories of 512-byte entries in 1 KB clusters).
  // The high-level MCSERV works on the file system and card drivers over
  // SIO2 on the pages: both see the same card. Paths are absolute without
  // the leading '/' ('' is the root) and case-sensitive.
  TPS2MemoryCard = class
  private
    FMounted, FFormatted: Boolean;
    FAllocOffset, FIndirect, FMaxClusters: Cardinal;
    procedure Mount;
    function Ptr(Cluster: Cardinal; Offset: Integer): PByte;
    procedure ReadBytes(Cluster: Cardinal; Offset: Integer; Dest: PByte; Count: Integer);
    procedure WriteBytes(Cluster: Cardinal; Offset: Integer; Src: PByte; Count: Integer);
    function FAT(N: Cardinal): Cardinal;
    procedure SetFAT(N, Value: Cardinal);
    function Chain(First: Cardinal): TArray<Cardinal>;
    function Allocate: Cardinal;
    procedure FreeChain(First: Cardinal);
    function ReadEntry(DirCluster: Cardinal; Index: Integer): TPS2CardEntry;
    function DirLength(DirCluster: Cardinal): Integer;
    procedure SetDirLength(DirCluster: Cardinal; Count: Integer);
    function FindIn(DirCluster: Cardinal; const Name: string; out E: TPS2CardEntry): Boolean;
    function NewEntry(DirCluster: Cardinal; out E: TPS2CardEntry): Boolean;
    procedure LoadLegacy(S: TStream; V2: Boolean);
  public
    Dirty: Boolean;
    Flash: TBytes;
    constructor Create;
    // A formatted empty card (time 0).
    procedure Clear;
    // Formats the flash as MCMAN does, created at Time.
    procedure FormatFlash(Time: UInt64);
    // A driver changed the pages: the file system is read again.
    procedure FlashWritten;
    function Formatted: Boolean;
    function Lookup(const Path: string; out E: TPS2CardEntry): Boolean;
    // A directory's entries in card order, deleted slots included.
    function Entries(const Dir: TPS2CardEntry): TArray<TPS2CardEntry>;
    function MakeDir(const Path: string; Mode: Word; Time: UInt64): Integer;
    function MakeFile(const Path: string; Mode: Word; Time: UInt64; out E: TPS2CardEntry): Integer;
    procedure WriteEntry(const E: TPS2CardEntry);
    // Frees the data and marks the entry deleted.
    procedure Remove(var E: TPS2CardEntry);
    function ReadAt(const E: TPS2CardEntry; Offset, Count: Integer; Dest: PByte): Integer;
    // Gives E clusters for Size bytes; False (nothing changed) on a full card.
    function Grow(var E: TPS2CardEntry; Size: Integer): Boolean;
    // Writes into clusters Grow provided; the length follows (not saved).
    procedure WriteAt(var E: TPS2CardEntry; Offset: Integer; Data: PByte; Count: Integer);
    function FreeClusters: Integer;
    // 'RMPS2MC3' and the deflated flash; Load also takes raw card images
    // (with or without spare bytes) and the earlier file-tree cards.
    function Image: TBytes;
    procedure Load(const Data: TBytes);
    procedure SerializeState(State: TStateArchive);
  end;

  // A card as SIO2 reaches it (commands after the 81h device byte): the end
  // byte replies close with (55h after power-on) and the page and byte
  // position the start commands 21h-23h set for erasing, writing and
  // reading. Replies run alongside the command bytes: after the device and
  // command bytes, most end with 2Bh and the end byte.
  TPS2CardLink = record
    Terminator: Byte;
    Page, Offset: Integer;
    procedure Reset;
    procedure Exchange(Card: TPS2MemoryCard; Time: UInt64; Cmd, Reply: PByte; Len: Integer);
  end;

  TPS2MCFile = record
    Port: Integer;
    Path: string;
    Position: Integer;
    Open, CanRead, CanWrite: Boolean;
  end;

  TPS2MCServer = class(TPS2RPCServer)
  private
    FEERAM: PByte;
    FFiles: array[0..2] of TPS2MCFile;
    FCurrent: array[0..1] of string;
    FKnown: array[0..1] of Boolean;
    // The result block (kept between calls).
    FStat: array[0..2] of Integer;
    // Directory listing in progress.
    FListPort: Integer;
    FListDir, FListPattern: string;
    FListPos: Integer;
    FListValid: Boolean;
    function Card(Port, Slot: Cardinal): TPS2MemoryCard;
    function Detect(Port, Slot: Cardinal; Second: Boolean = False): Integer;
    function EEPtr(Address: Cardinal; Size: Integer): PByte;
    procedure Touched(Address: Cardinal; Size: Integer);
    function Resolve(Port: Integer; const Name: string): string;
    function FileHandle(Fd: Integer): Integer;
    function OpenFile(Port: Integer; Flags: Cardinal; const Name: string): Integer;
    function ReadFile(Fd: Integer; Buffer: Cardinal; Size: Integer): Integer;
    function WriteFile(Fd: Integer; InData: PByte; InSize: Integer; Buffer: Cardinal; Size: Integer): Integer;
    function GetDir(Port: Integer; Flags: Cardinal; MaxEntries: Integer; Table: Cardinal; const Name: string): Integer;
    function ChDir(Port: Integer; Table: Cardinal; const Name: string): Integer;
    function SetFileInfo(Port: Integer; Flags: Cardinal; Info: Cardinal; const Name: string): Integer;
    function DeleteEntry(Port: Integer; const Name: string): Integer;
    procedure Entry(Dest: PByte; const Name: string; const E: TPS2CardEntry);
    procedure Touch(C: TPS2MemoryCard; const Dir: string);
  public
    Cards: array[0..1] of TPS2MemoryCard;
    // A card in the second slot (the first always has one).
    SecondCard: Boolean;
    // EE cycles since power-on for file times (nil: a fixed time).
    Clock: PInt64;
    // Versions in the init reply: those of the MCSERV and MCMAN the game
    // loads.
    ServVersion, ManVersion: Word;
    // Diagnostics: calls when assigned.
    Log: TStrings;
    constructor Create(EERAM: PByte);
    destructor Destroy; override;
    procedure Reset; override;
    function Call(Fn: Cardinal; Args: PByte; Size: Integer; ReplySize: Integer): TBytes; override;
    procedure SerializeState(State: TStateArchive); override;
    // The card time now (sceMcStDateTime layout).
    function CardNow: UInt64;
    // The card in a port (0, 1), nil when there is none.
    function PortCard(Port: Integer): TPS2MemoryCard;
    // The cards' contents (kept across IOP resets).
    procedure SerializeCards(State: TStateArchive);
  end;

// The card time EE cycles after power-on (the clock CDVD reports).
function PS2CardTime(Cycles: Int64): UInt64;

implementation

const
  ResSucceed = 0;
  ResChangedCard = -1;
  ResNoEntry = -4;
  ResDenied = -5;
  ResNotEmpty = -6;
  ResUpLimit = -7;
  ResFullDevice = -3;
  // No card answers (MCMAN's detection errors).
  ResFailDetect = -12;
  ResFailDetect2 = -11;

  AttrReadable = $0001;
  AttrWritable = $0002;
  AttrExecutable = $0004;
  AttrProtected = $0008;
  AttrFile = $0010;
  AttrSubdir = $0020;
  CreateDir = $0040;
  CreateFile = $0200;
  Attr0400 = $0400;
  AttrHidden = $2000;
  AttrExists = $8000;
  ModeFile = AttrExists or Attr0400 or AttrFile or AttrExecutable or AttrWritable or AttrReadable;
  ModeDir = AttrExists or Attr0400 or AttrSubdir or AttrExecutable or AttrWritable or AttrReadable;

  // An empty formatted 8 MB card; 1 KB clusters, two 512-byte directory
  // entries per cluster.
  CardClusters = 8000;
  ClusterSize = 1024;

  // Versions in the result block of the init call when the modules are not
  // known: the newest seen on game discs (libmc refuses modules older than
  // its own SDK's).
  MCServVersion = $210;
  MCManVersion = $230;

  // Parameter blocks: file (fd, port, slot, size, offset, origin, buffer,
  // param, data[16]) and name (port, slot, flags, max entries, table,
  // name[1024]).
  DFd = 0;
  DPort = 4;
  DSlot = 8;
  DSize = 12;
  DOffset = 16;
  DOrigin = 20;
  DBuffer = 24;
  DParam = 28;
  DData = 32;
  NPort = 0;
  NSlot = 4;
  NFlags = 8;
  NMax = 12;
  NTable = 16;
  NName = 20;

function Parent(const Path: string): string;
begin
  var P := Path.LastIndexOf('/');
  if P < 0 then
    Result := ''
  else
    Result := Path.Substring(0, P);
end;

function BaseName(const Path: string): string;
begin
  Result := Path.Substring(Path.LastIndexOf('/') + 1);
end;

function Join(const Dir, Name: string): string;
begin
  if Dir = '' then
    Result := Name
  else
    Result := Dir + '/' + Name;
end;

function CString(P: PByte; Max: Integer): string;
begin
  var N := 0;
  while (N < Max) and (P[N] <> 0) do
    Inc(N);
  Result := '';
  if N > 0 then
  begin
    var B: TBytes;
    SetLength(B, N);
    Move(P^, B[0], N);
    Result := TEncoding.ANSI.GetString(B);
  end;
end;

// Name against a pattern: '?' any one character, '*' any run.
function Matches(const Name, Pattern: string): Boolean;

  function Match(N, P: Integer): Boolean;
  begin
    while P <= Length(Pattern) do
    begin
      if Pattern[P] = '*' then
      begin
        for var K := N to Length(Name) + 1 do
          if Match(K, P + 1) then
            Exit(True);
        Exit(False);
      end;
      if (N > Length(Name)) or ((Pattern[P] <> '?') and (Pattern[P] <> Name[N])) then
        Exit(False);
      Inc(N);
      Inc(P);
    end;
    Result := N > Length(Name);
  end;

begin
  Result := Match(1, 1);
end;

function PS2CardTime(Cycles: Int64): UInt64;
begin
  var T := PS2ClockAt(Cycles);
  Result := (UInt64(T.Second) shl 8) or (UInt64(T.Minute) shl 16) or (UInt64(T.Hour) shl 24) or
    (UInt64(T.Day) shl 32) or (UInt64(T.Month) shl 40) or (UInt64(T.Year) shl 48);
end;

const
  // The card's answer to command 26h: flags (ECC in the spare bytes, bad
  // block list), then page size, pages per erase block, pages.
  CardSpecFlags = $2B;
  // Flash file system of a standard card: 2 pages per cluster, the
  // superblock in cluster 0, one indirect FAT cluster listing 32 FAT
  // clusters, the first allocatable cluster after them, the last two erase
  // blocks kept for backups.
  FlashClusterPages = 2;
  FlashBlockClusters = PS2CardBlockPages div FlashClusterPages;
  FlashClusters = PS2CardPages div FlashClusterPages;
  FlashIndirectCluster = 8;
  FlashFATClusters = FlashClusters * 4 div ClusterSize;
  FlashAllocOffset = FlashIndirectCluster + 1 + FlashFATClusters;
  FlashBackupBlock1 = PS2CardPages div PS2CardBlockPages - 1;
  FlashBackupBlock2 = FlashBackupBlock1 - 1;
  FlashAllocEnd = FlashBackupBlock2 * FlashBlockClusters - FlashAllocOffset;
  FlashMagic: AnsiString = 'Sony PS2 Memory Card Format 1.2.0.0';
  // FAT entries: end of a chain (allocated), free.
  FATChainEnd = $FFFFFFFF;
  FATFree = $7FFFFFFF;
  // Card file section after the file tree: the flash, deflated.
  FlashTag: array[0..3] of AnsiChar = 'FLSH';

// ECC of 128 bytes of page data, 3 bytes: column parities (bits 0-2 of
// the data bits whose bit number has bit 0, 1, 2 clear; bits 4-6 of those
// with it set), then the line parities (over the numbers of the bytes with
// odd parity, complemented and plain), each inverted.
procedure CardChunkECC(Data, ECC: PByte);
begin
  var Column := 0;
  var LineNot := 0;
  var Line := 0;
  for var I := 0 to 127 do
  begin
    var B := Data[I];
    var Parity := 0;
    for var K := 0 to 7 do
      if ((B shr K) and 1) <> 0 then
      begin
        Parity := Parity xor 1;
        for var J := 0 to 2 do
          if ((K shr J) and 1) = 0 then
            Column := Column xor (1 shl J)
          else
            Column := Column xor (1 shl (J + 4));
      end;
    if Parity <> 0 then
    begin
      LineNot := LineNot xor not I;
      Line := Line xor I;
    end;
  end;
  ECC[0] := Byte(not Column and $77);
  ECC[1] := Byte(not LineNot and $7F);
  ECC[2] := Byte(not Line and $7F);
end;

// A page as a card driver programs it: the data, then the ECC of each 128
// bytes in the spare area (the rest of it zero).
procedure WriteFlashPage(const Flash: TBytes; Page: Integer; Data: PByte);
begin
  var P := PByte(@Flash[Page * PS2CardRawPage]);
  Move(Data^, P^, PS2CardPageSize);
  FillChar(P[PS2CardPageSize], PS2CardSpareSize, 0);
  for var K := 0 to PS2CardPageSize div 128 - 1 do
    CardChunkECC(@P[K * 128], @P[PS2CardPageSize + K * 3]);
end;

{ TPS2CardEntry }

function TPS2CardEntry.IsDirectory: Boolean;
begin
  Result := (Mode and AttrSubdir) <> 0;
end;

function TPS2CardEntry.Exists: Boolean;
begin
  Result := (Mode and AttrExists) <> 0;
end;

{ TPS2MemoryCard }

const
  EntrySize = 512;
  FATPerCluster = ClusterSize div 4;
  FATAllocated = $80000000;
  // Raw card images without the spare bytes.
  PS2CardDataSize = PS2CardPages * PS2CardPageSize;

constructor TPS2MemoryCard.Create;
begin
  inherited Create;
  Clear;
end;

procedure TPS2MemoryCard.Clear;
begin
  FormatFlash(PS2CardTime(0));
  Dirty := False;
end;

// The layout a card driver's format leaves: block 0 (superblock), the
// blocks of the indirect FAT and FAT clusters and the first backup block
// programmed with zeros, the FAT marking the root directory's cluster and
// the allocatable clusters free, the root directory ('.' and '..') in the
// first allocatable cluster; the rest erased.
procedure TPS2MemoryCard.FormatFlash(Time: UInt64);
var
  Cluster: array[0..ClusterSize - 1] of Byte;

  procedure WriteCluster(N: Integer);
  begin
    for var K := 0 to FlashClusterPages - 1 do
      WriteFlashPage(Flash, N * FlashClusterPages + K, @Cluster[K * PS2CardPageSize]);
  end;

  procedure Put32(Offset: Integer; Value: Cardinal);
  begin
    PCardinal(@Cluster[Offset])^ := Value;
  end;

begin
  SetLength(Flash, PS2CardFlashSize);
  FillChar(Flash[0], Length(Flash), $FF);
  FillChar(Cluster, SizeOf(Cluster), 0);
  for var Block := 0 to (FlashAllocOffset - 1) div FlashBlockClusters do
    for var K := 0 to PS2CardBlockPages - 1 do
      WriteFlashPage(Flash, Block * PS2CardBlockPages + K, @Cluster[0]);
  for var K := 0 to PS2CardBlockPages - 1 do
    WriteFlashPage(Flash, FlashBackupBlock1 * PS2CardBlockPages + K, @Cluster[0]);
  // Superblock.
  Move(FlashMagic[1], Cluster[0], Length(FlashMagic));
  PWord(@Cluster[40])^ := PS2CardPageSize;
  PWord(@Cluster[42])^ := FlashClusterPages;
  PWord(@Cluster[44])^ := PS2CardBlockPages;
  PWord(@Cluster[46])^ := $FF00;
  Put32(48, FlashClusters);
  Put32(52, FlashAllocOffset);
  Put32(56, FlashAllocEnd);
  Put32(60, 0);
  Put32(64, FlashBackupBlock1);
  Put32(68, FlashBackupBlock2);
  Put32(80, FlashIndirectCluster);
  // No bad blocks.
  FillChar(Cluster[208], 32 * 4, $FF);
  Cluster[336] := 2;
  Cluster[337] := $52;
  Put32(340, ClusterSize);
  Put32(344, ClusterSize div 4);
  Put32(348, FlashBlockClusters);
  Put32(368, CardClusters);
  Put32(380, $FFFFFFFF);
  WriteCluster(0);
  // Indirect FAT cluster: where the FAT clusters are.
  FillChar(Cluster, SizeOf(Cluster), 0);
  for var K := 0 to FlashFATClusters - 1 do
    Put32(K * 4, FlashIndirectCluster + 1 + Cardinal(K));
  WriteCluster(FlashIndirectCluster);
  // FAT, by cluster number from the first allocatable one.
  for var F := 0 to FlashFATClusters - 1 do
  begin
    FillChar(Cluster, SizeOf(Cluster), 0);
    for var K := 0 to ClusterSize div 4 - 1 do
    begin
      var N := F * (ClusterSize div 4) + K;
      if N = 0 then
        Put32(K * 4, FATChainEnd)
      else if N < FlashAllocEnd then
        Put32(K * 4, FATFree);
    end;
    WriteCluster(FlashIndirectCluster + 1 + F);
  end;
  // Root directory: '.' (its entry count) and '..'.
  FillChar(Cluster, SizeOf(Cluster), 0);
  PWord(@Cluster[0])^ := ModeDir;
  Put32(4, 2);
  PUInt64(@Cluster[8])^ := Time;
  PUInt64(@Cluster[24])^ := Time;
  Cluster[64] := Ord('.');
  PWord(@Cluster[512])^ := ModeDir and not AttrReadable or AttrHidden;
  PUInt64(@Cluster[512 + 8])^ := Time;
  PUInt64(@Cluster[512 + 24])^ := Time;
  Cluster[512 + 64] := Ord('.');
  Cluster[512 + 65] := Ord('.');
  WriteCluster(FlashAllocOffset);
  Dirty := True;
  FMounted := False;
end;

procedure TPS2MemoryCard.FlashWritten;
begin
  FMounted := False;
  Dirty := True;
end;

// The superblock of a standard card: magic, 512-byte pages, two per
// cluster, the root directory in the first allocatable cluster. MCMAN
// allocates in the first (clusters per card / 1000) * 1000 + 1 clusters.
procedure TPS2MemoryCard.Mount;
begin
  FMounted := True;
  FFormatted := False;
  if Length(Flash) <> PS2CardFlashSize then
    Exit;
  var SB := PByte(@Flash[0]);
  if not CompareMem(SB, PAnsiChar(FlashMagic), 28) or (PWord(SB + 40)^ <> PS2CardPageSize) or
    (PWord(SB + 42)^ <> FlashClusterPages) or (PCardinal(SB + 60)^ <> 0) then
    Exit;
  var Clusters := PCardinal(SB + 48)^;
  FAllocOffset := PCardinal(SB + 52)^;
  FIndirect := PCardinal(SB + 80)^;
  if (Clusters = 0) or (Clusters > PS2CardPages div FlashClusterPages) or (FAllocOffset >= Clusters) or
    (FIndirect >= Clusters) then
    Exit;
  FMaxClusters := Min((Clusters div 1000) * 1000 + 1, Clusters - FAllocOffset);
  FFormatted := True;
end;

function TPS2MemoryCard.Formatted: Boolean;
begin
  if not FMounted then
    Mount;
  Result := FFormatted;
end;

// Data byte Offset (0..1023) of absolute cluster Cluster.
function TPS2MemoryCard.Ptr(Cluster: Cardinal; Offset: Integer): PByte;
begin
  var Page := Integer(Cluster) * FlashClusterPages + Offset div PS2CardPageSize;
  Result := @Flash[Page * PS2CardRawPage + Offset mod PS2CardPageSize];
end;

procedure TPS2MemoryCard.ReadBytes(Cluster: Cardinal; Offset: Integer; Dest: PByte; Count: Integer);
begin
  while Count > 0 do
  begin
    var N := Min(Count, PS2CardPageSize - Offset mod PS2CardPageSize);
    Move(Ptr(Cluster, Offset)^, Dest^, N);
    Inc(Offset, N);
    Inc(Dest, N);
    Dec(Count, N);
  end;
end;

// Changes the data of the pages and programs their ECC again.
procedure TPS2MemoryCard.WriteBytes(Cluster: Cardinal; Offset: Integer; Src: PByte; Count: Integer);
var
  Page: array[0..PS2CardPageSize - 1] of Byte;
begin
  while Count > 0 do
  begin
    var InPage := Offset mod PS2CardPageSize;
    var N := Min(Count, PS2CardPageSize - InPage);
    var Start := Ptr(Cluster, Offset - InPage);
    Move(Start^, Page[0], PS2CardPageSize);
    Move(Src^, Page[InPage], N);
    WriteFlashPage(Flash, Integer(Cluster) * FlashClusterPages + Offset div PS2CardPageSize, @Page[0]);
    Inc(Offset, N);
    Inc(Src, N);
    Dec(Count, N);
  end;
  Dirty := True;
end;

// FAT entry of (relative) cluster N, through the indirect FAT clusters
// the superblock lists.
function TPS2MemoryCard.FAT(N: Cardinal): Cardinal;
begin
  var FC := N div FATPerCluster;
  var Indirect := PCardinal(Ptr(0, 80 + Integer(FC div FATPerCluster) * 4))^;
  var FATCluster: Cardinal;
  ReadBytes(Indirect, Integer(FC mod FATPerCluster) * 4, @FATCluster, 4);
  ReadBytes(FATCluster, Integer(N mod FATPerCluster) * 4, @Result, 4);
end;

procedure TPS2MemoryCard.SetFAT(N, Value: Cardinal);
begin
  var FC := N div FATPerCluster;
  var Indirect := PCardinal(Ptr(0, 80 + Integer(FC div FATPerCluster) * 4))^;
  var FATCluster: Cardinal;
  ReadBytes(Indirect, Integer(FC mod FATPerCluster) * 4, @FATCluster, 4);
  WriteBytes(FATCluster, Integer(N mod FATPerCluster) * 4, @Value, 4);
end;

// The clusters of a chain from First (empty for PS2CardNoCluster).
function TPS2MemoryCard.Chain(First: Cardinal): TArray<Cardinal>;
begin
  Result := nil;
  var N := First;
  while (N < FMaxClusters) and (Cardinal(Length(Result)) <= FMaxClusters) do
  begin
    Result := Result + [N];
    var V := FAT(N);
    if (V = FATChainEnd) or ((V and FATAllocated) = 0) then
      Break;
    N := V and not FATAllocated;
  end;
end;

// The first free cluster, marked as the end of a chain.
function TPS2MemoryCard.Allocate: Cardinal;
begin
  for var N := 0 to Integer(FMaxClusters) - 1 do
    if (FAT(N) and FATAllocated) = 0 then
    begin
      SetFAT(N, FATChainEnd);
      Exit(N);
    end;
  Result := PS2CardNoCluster;
end;

procedure TPS2MemoryCard.FreeChain(First: Cardinal);
begin
  for var N in Chain(First) do
    SetFAT(N, FATFree);
end;

function TPS2MemoryCard.FreeClusters: Integer;
begin
  Result := 0;
  if not Formatted then
    Exit;
  for var N := 0 to Integer(FMaxClusters) - 1 do
    if (FAT(N) and FATAllocated) = 0 then
      Inc(Result);
end;

// Entry Index of the directory starting at DirCluster (Mode 0 past its
// clusters).
function TPS2MemoryCard.ReadEntry(DirCluster: Cardinal; Index: Integer): TPS2CardEntry;
var
  Raw: array[0..EntrySize - 1] of Byte;
begin
  Result := Default(TPS2CardEntry);
  Result.DirCluster := DirCluster;
  Result.Index := Index;
  var Clusters := Chain(DirCluster);
  if (Index < 0) or (Index div 2 >= Length(Clusters)) then
    Exit;
  ReadBytes(FAllocOffset + Clusters[Index div 2], (Index mod 2) * EntrySize, @Raw[0], EntrySize);
  Result.Mode := PWord(@Raw[0])^;
  Result.Length := PCardinal(@Raw[4])^;
  Result.Created := PUInt64(@Raw[8])^;
  Result.Cluster := PCardinal(@Raw[16])^;
  Result.DirEntry := PCardinal(@Raw[20])^;
  Result.Modified := PUInt64(@Raw[24])^;
  Result.Attr := PCardinal(@Raw[32])^;
  Result.Name := CString(@Raw[64], 32);
end;

procedure TPS2MemoryCard.WriteEntry(const E: TPS2CardEntry);
var
  Raw: array[0..EntrySize - 1] of Byte;
begin
  var Clusters := Chain(E.DirCluster);
  if (E.Index < 0) or (E.Index div 2 >= Length(Clusters)) then
    Exit;
  var Cluster := FAllocOffset + Clusters[E.Index div 2];
  var Offset := (E.Index mod 2) * EntrySize;
  ReadBytes(Cluster, Offset, @Raw[0], EntrySize);
  PWord(@Raw[0])^ := E.Mode;
  PCardinal(@Raw[4])^ := E.Length;
  PUInt64(@Raw[8])^ := E.Created;
  PCardinal(@Raw[16])^ := E.Cluster;
  PCardinal(@Raw[20])^ := E.DirEntry;
  PUInt64(@Raw[24])^ := E.Modified;
  PCardinal(@Raw[32])^ := E.Attr;
  FillChar(Raw[64], 32, 0);
  var Name := TEncoding.ANSI.GetBytes(E.Name);
  if Length(Name) > 0 then
    Move(Name[0], Raw[64], Min(Length(Name), 31));
  WriteBytes(Cluster, Offset, @Raw[0], EntrySize);
end;

// A directory's entry count is in its entry in the parent, which its '.'
// entry points to (the root's '.' points to itself).
function TPS2MemoryCard.DirLength(DirCluster: Cardinal): Integer;
begin
  var Dot := ReadEntry(DirCluster, 0);
  Result := Integer(ReadEntry(Dot.Cluster, Dot.DirEntry).Length);
end;

procedure TPS2MemoryCard.SetDirLength(DirCluster: Cardinal; Count: Integer);
begin
  var Dot := ReadEntry(DirCluster, 0);
  var Owner := ReadEntry(Dot.Cluster, Dot.DirEntry);
  Owner.Length := Cardinal(Count);
  WriteEntry(Owner);
end;

function TPS2MemoryCard.FindIn(DirCluster: Cardinal; const Name: string; out E: TPS2CardEntry): Boolean;
begin
  var Count := DirLength(DirCluster);
  for var K := 0 to Count - 1 do
  begin
    E := ReadEntry(DirCluster, K);
    if E.Exists and (E.Name = Name) then
      Exit(True);
  end;
  Result := False;
end;

function TPS2MemoryCard.Lookup(const Path: string; out E: TPS2CardEntry): Boolean;
begin
  E := Default(TPS2CardEntry);
  if not Formatted then
    Exit(False);
  if Path = '' then
  begin
    E := ReadEntry(0, 0);
    E.Name := '';
    Exit(E.Exists);
  end;
  var Parts := Path.Split(['/']);
  var Dir: Cardinal := 0;
  for var K := 0 to High(Parts) do
  begin
    if not FindIn(Dir, Parts[K], E) then
      Exit(False);
    if K < High(Parts) then
    begin
      if not E.IsDirectory then
        Exit(False);
      Dir := E.Cluster;
    end;
  end;
  Result := True;
end;

function TPS2MemoryCard.Entries(const Dir: TPS2CardEntry): TArray<TPS2CardEntry>;
begin
  SetLength(Result, Dir.Length);
  for var K := 0 to Integer(Dir.Length) - 1 do
    Result[K] := ReadEntry(Dir.Cluster, K);
end;

// A slot for a new entry: the first deleted one after '.' and '..', or a
// new one at the end (a new cluster when the last is full).
function TPS2MemoryCard.NewEntry(DirCluster: Cardinal; out E: TPS2CardEntry): Boolean;
begin
  var Count := DirLength(DirCluster);
  for var K := 2 to Count - 1 do
  begin
    E := ReadEntry(DirCluster, K);
    if not E.Exists then
    begin
      E := Default(TPS2CardEntry);
      E.DirCluster := DirCluster;
      E.Index := K;
      Exit(True);
    end;
  end;
  var Clusters := Chain(DirCluster);
  if Count div 2 >= Length(Clusters) then
  begin
    var X := Allocate;
    if X = PS2CardNoCluster then
      Exit(False);
    var Zero: array[0..ClusterSize - 1] of Byte;
    FillChar(Zero, SizeOf(Zero), 0);
    WriteBytes(FAllocOffset + X, 0, @Zero[0], ClusterSize);
    SetFAT(Clusters[High(Clusters)], X or FATAllocated);
  end;
  SetDirLength(DirCluster, Count + 1);
  E := Default(TPS2CardEntry);
  E.DirCluster := DirCluster;
  E.Index := Count;
  Result := True;
end;

function TPS2MemoryCard.MakeDir(const Path: string; Mode: Word; Time: UInt64): Integer;
var
  Cluster: array[0..ClusterSize - 1] of Byte;
begin
  var P, E: TPS2CardEntry;
  if (Path = '') or not Lookup(Parent(Path), P) or not P.IsDirectory or FindIn(P.Cluster, BaseName(Path), E) then
    Exit(ResNoEntry);
  if FreeClusters < 2 then
    Exit(ResFullDevice);
  if not NewEntry(P.Cluster, E) then
    Exit(ResFullDevice);
  var X := Allocate;
  if X = PS2CardNoCluster then
    Exit(ResFullDevice);
  // '.' points to the entry in the parent, '..' where the parent's '.'
  // points.
  var ParentDot := ReadEntry(P.Cluster, 0);
  FillChar(Cluster, SizeOf(Cluster), 0);
  PWord(@Cluster[0])^ := ModeDir;
  PUInt64(@Cluster[8])^ := Time;
  PCardinal(@Cluster[16])^ := P.Cluster;
  PCardinal(@Cluster[20])^ := Cardinal(E.Index);
  PUInt64(@Cluster[24])^ := Time;
  Cluster[64] := Ord('.');
  PWord(@Cluster[EntrySize])^ := ModeDir;
  PUInt64(@Cluster[EntrySize + 8])^ := ParentDot.Created;
  PCardinal(@Cluster[EntrySize + 16])^ := ParentDot.Cluster;
  PCardinal(@Cluster[EntrySize + 20])^ := ParentDot.DirEntry;
  PUInt64(@Cluster[EntrySize + 24])^ := ParentDot.Created;
  Cluster[EntrySize + 64] := Ord('.');
  Cluster[EntrySize + 65] := Ord('.');
  WriteBytes(FAllocOffset + X, 0, @Cluster[0], ClusterSize);
  E.Mode := Mode;
  E.Length := 2;
  E.Created := Time;
  E.Modified := Time;
  E.Cluster := X;
  E.Name := BaseName(Path);
  WriteEntry(E);
  Result := ResSucceed;
end;

function TPS2MemoryCard.MakeFile(const Path: string; Mode: Word; Time: UInt64; out E: TPS2CardEntry): Integer;
begin
  var P: TPS2CardEntry;
  if (Path = '') or not Lookup(Parent(Path), P) or not P.IsDirectory then
    Exit(ResNoEntry);
  if not NewEntry(P.Cluster, E) then
    Exit(ResFullDevice);
  E.Mode := Mode;
  E.Length := 0;
  E.Created := Time;
  E.Modified := Time;
  E.Cluster := PS2CardNoCluster;
  E.Name := BaseName(Path);
  WriteEntry(E);
  Result := ResSucceed;
end;

procedure TPS2MemoryCard.Remove(var E: TPS2CardEntry);
begin
  if E.Cluster < FMaxClusters then
    FreeChain(E.Cluster);
  E.Mode := E.Mode and not AttrExists;
  WriteEntry(E);
end;

function TPS2MemoryCard.ReadAt(const E: TPS2CardEntry; Offset, Count: Integer; Dest: PByte): Integer;
begin
  Count := EnsureRange(Integer(E.Length) - Offset, 0, Max(Count, 0));
  Result := Count;
  if Count = 0 then
    Exit;
  var Clusters := Chain(E.Cluster);
  while Count > 0 do
  begin
    var K := Offset div ClusterSize;
    var InCluster := Offset mod ClusterSize;
    var N := Min(Count, ClusterSize - InCluster);
    if K < Length(Clusters) then
      ReadBytes(FAllocOffset + Clusters[K], InCluster, Dest, N)
    else
      FillChar(Dest^, N, 0);
    Inc(Offset, N);
    Inc(Dest, N);
    Dec(Count, N);
  end;
end;

function TPS2MemoryCard.Grow(var E: TPS2CardEntry; Size: Integer): Boolean;
begin
  var Clusters := Chain(E.Cluster);
  var Need := (Size + ClusterSize - 1) div ClusterSize - Length(Clusters);
  if Need <= 0 then
    Exit(True);
  if Need > FreeClusters then
    Exit(False);
  for var K := 1 to Need do
  begin
    var X := Allocate;
    if Length(Clusters) = 0 then
      E.Cluster := X
    else
      SetFAT(Clusters[High(Clusters)], X or FATAllocated);
    Clusters := Clusters + [X];
  end;
  Result := True;
end;

procedure TPS2MemoryCard.WriteAt(var E: TPS2CardEntry; Offset: Integer; Data: PByte; Count: Integer);
begin
  var Clusters := Chain(E.Cluster);
  var Pos := Offset;
  var Left := Count;
  while Left > 0 do
  begin
    var K := Pos div ClusterSize;
    if K >= Length(Clusters) then
      Break;
    var InCluster := Pos mod ClusterSize;
    var N := Min(Left, ClusterSize - InCluster);
    WriteBytes(FAllocOffset + Clusters[K], InCluster, Data, N);
    Inc(Pos, N);
    Inc(Data, N);
    Dec(Left, N);
  end;
  E.Length := Max(E.Length, Cardinal(Pos));
end;

function TPS2MemoryCard.Image: TBytes;
begin
  var S := TMemoryStream.Create;
  try
    S.WriteBuffer(PS2MemoryCardMagic, 8);
    var Z := TZCompressionStream.Create(S);
    try
      Z.WriteBuffer(Flash[0], Length(Flash));
    finally
      Z.Free;
    end;
    SetLength(Result, S.Size);
    Move(S.Memory^, Result[0], S.Size);
  finally
    S.Free;
  end;
end;

procedure TPS2MemoryCard.Load(const Data: TBytes);
begin
  Clear;
  if Length(Data) = 0 then
    Exit;
  if Length(Data) = PS2CardFlashSize then
  begin
    // A raw card with spare bytes (as card dumps and PCSX2 keep them).
    Flash := Copy(Data);
    FMounted := False;
  end
  else if Length(Data) = PS2CardDataSize then
  begin
    for var Page := 0 to PS2CardPages - 1 do
      WriteFlashPage(Flash, Page, @Data[Page * PS2CardPageSize]);
    FMounted := False;
  end
  else
  begin
    var S := TBytesStream.Create(Data);
    try
      var Magic: array[0..7] of AnsiChar;
      if S.Read(Magic, 8) <> 8 then
        raise EReadError.Create('Not a PS2 memory card');
      if CompareMem(@Magic, @PS2MemoryCardMagic, 8) then
      begin
        var Z := TZDecompressionStream.Create(S);
        try
          Z.ReadBuffer(Flash[0], PS2CardFlashSize);
        finally
          Z.Free;
        end;
        FMounted := False;
      end
      else if CompareMem(@Magic, @PS2MemoryCardMagic2, 8) then
        LoadLegacy(S, True)
      else if CompareMem(@Magic, @PS2MemoryCardMagic1, 8) then
        LoadLegacy(S, False)
      else
        raise EReadError.Create('Not a PS2 memory card');
    finally
      S.Free;
    end;
  end;
  Dirty := False;
end;

// Earlier RetroMul cards: a file tree ('RMPS2MC2': count, then per entry in
// creation order kind, name, created, modified, mode, attribute and data;
// 'RMPS2MC1': kind, name and data) and, optionally, the flash card drivers
// used ('FLSH', deflated). The files go onto that flash (or a freshly
// formatted one) in their creation order; the card is saved in the new form.
procedure TPS2MemoryCard.LoadLegacy(S: TStream; V2: Boolean);
type
  TOld = record
    Directory: Boolean;
    Path: string;
    Created, Modified: UInt64;
    Mode: Word;
    Attr: Cardinal;
    Data: TBytes;
  end;
begin
  var Count: Integer;
  S.ReadBuffer(Count, 4);
  if (Count < 0) or (Count > 100000) then
    raise EReadError.Create('Damaged PS2 memory card');
  var Old: TArray<TOld>;
  SetLength(Old, Count);
  for var K := 0 to Count - 1 do
  begin
    var Kind: Byte;
    var NameLen, DataLen: Integer;
    S.ReadBuffer(Kind, 1);
    S.ReadBuffer(NameLen, 4);
    if (NameLen < 0) or (NameLen > 4096) then
      raise EReadError.Create('Damaged PS2 memory card');
    var Name: TBytes;
    SetLength(Name, NameLen);
    if NameLen > 0 then
      S.ReadBuffer(Name[0], NameLen);
    Old[K].Directory := Kind <> 0;
    Old[K].Path := TEncoding.UTF8.GetString(Name);
    if Old[K].Directory then
      Old[K].Mode := ModeDir
    else
      Old[K].Mode := ModeFile;
    if V2 then
    begin
      S.ReadBuffer(Old[K].Created, 8);
      S.ReadBuffer(Old[K].Modified, 8);
      S.ReadBuffer(Old[K].Mode, 2);
      S.ReadBuffer(Old[K].Attr, 4);
    end;
    S.ReadBuffer(DataLen, 4);
    if (DataLen < 0) or (DataLen > S.Size - S.Position) then
      raise EReadError.Create('Damaged PS2 memory card');
    SetLength(Old[K].Data, DataLen);
    if DataLen > 0 then
      S.ReadBuffer(Old[K].Data[0], DataLen);
  end;
  var Tag: array[0..3] of AnsiChar;
  if (S.Size - S.Position >= 8) and (S.Read(Tag, 4) = 4) and CompareMem(@Tag, @FlashTag, 4) then
  begin
    var DeflatedLen: Integer;
    S.ReadBuffer(DeflatedLen, 4);
    if (DeflatedLen <= 0) or (DeflatedLen > S.Size - S.Position) then
      raise EReadError.Create('Damaged PS2 memory card');
    var Deflated := TMemoryStream.Create;
    try
      Deflated.CopyFrom(S, DeflatedLen);
      Deflated.Position := 0;
      var Z := TZDecompressionStream.Create(Deflated);
      try
        Z.ReadBuffer(Flash[0], PS2CardFlashSize);
      finally
        Z.Free;
      end;
    finally
      Deflated.Free;
    end;
    FMounted := False;
    if not Formatted then
      FormatFlash(PS2CardTime(0));
  end;
  for var O in Old do
  begin
    var E: TPS2CardEntry;
    if O.Path = '' then
    begin
      if Lookup('', E) then
      begin
        E.Modified := O.Modified;
        WriteEntry(E);
      end;
      Continue;
    end;
    if Lookup(O.Path, E) then
      Continue;
    if O.Directory then
    begin
      if (MakeDir(O.Path, O.Mode, O.Created) <> ResSucceed) or not Lookup(O.Path, E) then
        Continue;
    end
    else
    begin
      if MakeFile(O.Path, O.Mode, O.Created, E) <> ResSucceed then
        Continue;
      if not Grow(E, Length(O.Data)) then
      begin
        Remove(E);
        Continue;
      end;
      if Length(O.Data) > 0 then
        WriteAt(E, 0, @O.Data[0], Length(O.Data));
    end;
    E.Modified := O.Modified;
    E.Attr := O.Attr;
    WriteEntry(E);
  end;
end;

procedure TPS2MemoryCard.SerializeState(State: TStateArchive);
begin
  var Data: TBytes := nil;
  if not State.Loading then
    Data := Image;
  var Len := Length(Data);
  State.Field(Len, SizeOf(Len));
  if State.Loading then
  begin
    if (Len < 0) or (Len > $4000000) then
      raise EReadError.Create('PS2 snapshot memory card');
    SetLength(Data, Len);
  end;
  if Len > 0 then
    State.Field(Data[0], Len);
  if State.Loading then
  begin
    Load(Data);
    Dirty := True;
  end;
end;

{ TPS2CardLink }

procedure TPS2CardLink.Reset;
begin
  Terminator := $55;
  Page := 0;
  Offset := 0;
end;

// Cmd[0] is the device byte (81h), Cmd[1] the command. Commands: 11h probe,
// 12h (before writes and erases), 21h/22h/23h start erase/write/read at a
// page (4 bytes and their XOR), 26h card specs, 27h set and 28h get the end
// byte, 42h write and 43h read up to 128 bytes at the position (size byte,
// data, XOR), 81h end of a read or write, 82h erase the block; the rest
// (BFh, F3h and the authentication commands) are acknowledged.
procedure TPS2CardLink.Exchange(Card: TPS2MemoryCard; Time: UInt64; Cmd, Reply: PByte; Len: Integer);

  procedure Close;
  begin
    if Len >= 4 then
    begin
      Reply[Len - 2] := $2B;
      Reply[Len - 1] := Terminator;
    end;
  end;

  function Position(Size: Integer): Integer;
  begin
    if (Page < 0) or (Page >= PS2CardPages) or (Offset + Size > PS2CardRawPage) then
      Exit(-1);
    Result := Page * PS2CardRawPage + Offset;
  end;

begin
  FillChar(Reply^, Len, $FF);
  if Len < 2 then
    Exit;
  if Length(Card.Flash) <> PS2CardFlashSize then
    Card.FormatFlash(Time);
  case Cmd[1] of
    $21, $22, $23:
      begin
        if Len >= 6 then
          Page := Integer(Cmd[2] or (Cardinal(Cmd[3]) shl 8) or (Cardinal(Cmd[4]) shl 16) or (Cardinal(Cmd[5]) shl 24));
        Offset := 0;
        Close;
      end;
    $26:
      if Len >= 13 then
      begin
        Reply[2] := CardSpecFlags;
        PWord(@Reply[3])^ := PS2CardPageSize;
        PWord(@Reply[5])^ := PS2CardBlockPages;
        PCardinal(@Reply[7])^ := PS2CardPages;
        var X: Byte := 0;
        for var K := 3 to 10 do
          X := X xor Reply[K];
        Reply[11] := X;
        Reply[12] := Terminator;
      end;
    $27:
      begin
        if Len >= 3 then
          Terminator := Cmd[2];
        Close;
      end;
    $28:
      if Len >= 5 then
      begin
        Reply[2] := $2B;
        Reply[3] := Terminator;
        Reply[4] := $55;
      end;
    $42:
      begin
        var Size := 0;
        if Len >= 3 then
          Size := Min(Integer(Cmd[2]), Len - 3);
        var P := Position(Size);
        if P >= 0 then
        begin
          Move(Cmd[3], Card.Flash[P], Size);
          Card.FlashWritten;
        end;
        Inc(Offset, Size);
        if Len >= 4 then
        begin
          Reply[2] := $2B;
          Reply[3] := Terminator;
          Reply[Len - 1] := Terminator;
        end;
      end;
    $43:
      begin
        var Size := 0;
        if Len >= 3 then
          Size := Max(0, Min(Integer(Cmd[2]), Len - 6));
        var P := Position(Size);
        var X: Byte := 0;
        for var K := 0 to Size - 1 do
        begin
          if P >= 0 then
            Reply[4 + K] := Card.Flash[P + K];
          X := X xor Reply[4 + K];
        end;
        Inc(Offset, Size);
        if Len >= 6 then
        begin
          Reply[2] := $2B;
          Reply[3] := Terminator;
          Reply[4 + Size] := X;
          Reply[Len - 1] := Terminator;
        end;
      end;
    $82:
      begin
        if (Page >= 0) and (Page < PS2CardPages) then
        begin
          var First := Page - Page mod PS2CardBlockPages;
          FillChar(Card.Flash[First * PS2CardRawPage], PS2CardBlockPages * PS2CardRawPage, $FF);
          Card.FlashWritten;
        end;
        Close;
      end;
  else
    Close;
  end;
end;

{ TPS2MCServer }

constructor TPS2MCServer.Create(EERAM: PByte);
begin
  inherited Create(PS2MCServerSID);
  FEERAM := EERAM;
  Cards[0] := TPS2MemoryCard.Create;
  Cards[1] := TPS2MemoryCard.Create;
  SecondCard := True;
  // libmc polls for the reply (mcSync); it comes some time after the call.
  Latency := PS2EEClock div 400;
end;

destructor TPS2MCServer.Destroy;
begin
  Cards[0].Free;
  Cards[1].Free;
  inherited;
end;

procedure TPS2MCServer.Reset;
begin
  for var K := 0 to High(FFiles) do
    FFiles[K] := Default(TPS2MCFile);
  FCurrent[0] := '';
  FCurrent[1] := '';
  FKnown[0] := False;
  FKnown[1] := False;
  FillChar(FStat, SizeOf(FStat), 0);
  FListValid := False;
  FListDir := '';
  FListPattern := '';
  FListPos := 0;
  FListPort := 0;
  ServVersion := MCServVersion;
  ManVersion := MCManVersion;
end;

function TPS2MCServer.Card(Port, Slot: Cardinal): TPS2MemoryCard;
begin
  if (Port > 1) or (Slot <> 0) or ((Port = 1) and not SecondCard) then
    Exit(nil);
  Result := Cards[Port];
end;

function TPS2MCServer.PortCard(Port: Integer): TPS2MemoryCard;
begin
  if (Port < 0) or (Port > 1) then
    Exit(nil);
  Result := Card(Cardinal(Port), 0);
end;

function TPS2MCServer.CardNow: UInt64;
begin
  if Clock <> nil then
    Result := PS2CardTime(Clock^)
  else
    Result := PS2CardTime(0);
end;

// Card detection before every access: no card, a card seen for the first
// time (changed card) or the same card as before.
function TPS2MCServer.Detect(Port, Slot: Cardinal; Second: Boolean): Integer;
begin
  if Card(Port, Slot) = nil then
  begin
    if Port <= 1 then
      FKnown[Port] := False;
    if Second then
      Exit(ResFailDetect2);
    Exit(ResFailDetect);
  end;
  if not FKnown[Port] then
  begin
    FKnown[Port] := True;
    Exit(ResChangedCard);
  end;
  Result := ResSucceed;
end;

function TPS2MCServer.EEPtr(Address: Cardinal; Size: Integer): PByte;
begin
  var A := Address and PS2RAMMask;
  if (Size < 0) or (A + Cardinal(Size) > PS2RAMSize) then
    Exit(nil);
  Result := FEERAM + A;
end;

procedure TPS2MCServer.Touched(Address: Cardinal; Size: Integer);
begin
  if (FSIF <> nil) and (Size > 0) then
    FSIF.MarkEE(Address and PS2RAMMask, Cardinal(Size));
end;

// An absolute card path (no leading '/') for a name relative to the port's
// current directory.
function TPS2MCServer.Resolve(Port: Integer; const Name: string): string;
begin
  var Full := Name;
  if not Full.StartsWith('/') then
    Full := FCurrent[Port] + '/' + Full;
  var Parts := TList<string>.Create;
  try
    for var Part in Full.Split(['/']) do
    begin
      if (Part = '') or (Part = '.') then
        Continue;
      if Part = '..' then
      begin
        if Parts.Count > 0 then
          Parts.Delete(Parts.Count - 1);
      end
      else
        Parts.Add(Part);
    end;
    Result := string.Join('/', Parts.ToArray);
  finally
    Parts.Free;
  end;
end;

// The open file's slot, or -1.
function TPS2MCServer.FileHandle(Fd: Integer): Integer;
begin
  if (Fd < 0) or (Fd > High(FFiles)) or not FFiles[Fd].Open then
    Exit(-1);
  Result := Fd;
end;

// Flags: 1 read, 2 write, 200h create (or replace), 40h make a directory.
function TPS2MCServer.OpenFile(Port: Integer; Flags: Cardinal; const Name: string): Integer;
begin
  if Name = '' then
    Exit(ResNoEntry);
  if (Flags and CreateFile) <> 0 then
    Flags := Flags or AttrWritable;
  var C := Cards[Port];
  var Path := Resolve(Port, Name);
  var Dir, E: TPS2CardEntry;
  if (Path = '') or not C.Lookup(Parent(Path), Dir) or not Dir.IsDirectory then
    Exit(ResNoEntry);
  var Slot := -1;
  for var K := 0 to High(FFiles) do
    if not FFiles[K].Open then
    begin
      Slot := K;
      Break;
    end;
  if Slot < 0 then
    Exit(ResUpLimit);
  var Found := C.Lookup(Path, E);
  if (Flags and CreateDir) <> 0 then
  begin
    if Found then
      Exit(ResNoEntry);
    var R := C.MakeDir(Path, ModeDir or (Flags and AttrHidden), CardNow);
    if R = ResSucceed then
      Touch(C, Parent(Path));
    Exit(R);
  end;
  if not Found then
  begin
    if (Flags and CreateFile) = 0 then
      Exit(ResNoEntry);
  end
  else
  begin
    if ((Flags and AttrWritable) <> 0) and ((E.Mode and AttrWritable) = 0) then
      Exit(ResDenied);
    if ((Flags and AttrReadable) <> 0) and ((E.Mode and AttrReadable) = 0) then
      Exit(ResDenied);
    if E.IsDirectory then
    begin
      // Directory handles neither read nor write.
      FFiles[Slot] := Default(TPS2MCFile);
      FFiles[Slot].Port := Port;
      FFiles[Slot].Path := Path;
      FFiles[Slot].Open := True;
      Exit(Slot);
    end;
    if (Flags and AttrWritable) <> 0 then
      for var K := 0 to High(FFiles) do
        if FFiles[K].Open and FFiles[K].CanWrite and (FFiles[K].Port = Port) and (FFiles[K].Path = Path) then
          Exit(ResDenied);
    if (Flags and CreateFile) <> 0 then
    begin
      C.Remove(E);
      Found := False;
    end;
  end;
  if not Found then
  begin
    var R := C.MakeFile(Path, ModeFile or (Flags and AttrHidden), CardNow, E);
    if R <> ResSucceed then
      Exit(R);
    Touch(C, Parent(Path));
  end;
  FFiles[Slot] := Default(TPS2MCFile);
  FFiles[Slot].Port := Port;
  FFiles[Slot].Path := Path;
  FFiles[Slot].Open := True;
  FFiles[Slot].CanRead := (Flags and AttrReadable) <> 0;
  FFiles[Slot].CanWrite := (Flags and AttrWritable) <> 0;
  Result := Slot;
end;

// A directory's modification time becomes the card clock.
procedure TPS2MCServer.Touch(C: TPS2MemoryCard; const Dir: string);
begin
  var D: TPS2CardEntry;
  if C.Lookup(Dir, D) then
  begin
    D.Modified := CardNow;
    C.WriteEntry(D);
  end;
end;

function TPS2MCServer.ReadFile(Fd: Integer; Buffer: Cardinal; Size: Integer): Integer;
begin
  var H := FileHandle(Fd);
  if (H < 0) or not FFiles[H].CanRead then
    Exit(ResDenied);
  var E: TPS2CardEntry;
  if not Cards[FFiles[H].Port].Lookup(FFiles[H].Path, E) or E.IsDirectory then
    Exit(ResDenied);
  var Count := EnsureRange(Integer(E.Length) - FFiles[H].Position, 0, Max(Size, 0));
  var P := EEPtr(Buffer, Count);
  if (P <> nil) and (Count > 0) then
  begin
    Cards[FFiles[H].Port].ReadAt(E, FFiles[H].Position, Count, P);
    Touched(Buffer, Count);
  end;
  Inc(FFiles[H].Position, Count);
  Result := Count;
end;

// InSize bytes from the parameter block, then Size bytes from EE RAM.
function TPS2MCServer.WriteFile(Fd: Integer; InData: PByte; InSize: Integer; Buffer: Cardinal;
  Size: Integer): Integer;
begin
  var H := FileHandle(Fd);
  if (H < 0) or not FFiles[H].CanWrite then
    Exit(ResDenied);
  var C := Cards[FFiles[H].Port];
  var E: TPS2CardEntry;
  if not C.Lookup(FFiles[H].Path, E) or E.IsDirectory then
    Exit(ResDenied);
  InSize := EnsureRange(InSize, 0, 16);
  Size := Max(Size, 0);
  var Total := InSize + Size;
  var Pos := FFiles[H].Position;
  // Clusters the file grows by must be free.
  if not C.Grow(E, Max(Integer(E.Length), Pos + Total)) then
    Exit(ResFullDevice);
  if InSize > 0 then
    C.WriteAt(E, Pos, InData, InSize);
  var P := EEPtr(Buffer, Size);
  if (P <> nil) and (Size > 0) then
    C.WriteAt(E, Pos + InSize, P, Size);
  FFiles[H].Position := Pos + Total;
  E.Modified := CardNow;
  C.WriteEntry(E);
  Result := Total;
end;

procedure TPS2MCServer.Entry(Dest: PByte; const Name: string; const E: TPS2CardEntry);
begin
  FillChar(Dest^, 64, 0);
  PUInt64(Dest)^ := E.Created;
  PUInt64(Dest + 8)^ := E.Modified;
  if not E.IsDirectory then
    PCardinal(Dest + 16)^ := E.Length;
  PWord(Dest + 20)^ := E.Mode;
  PCardinal(Dest + 24)^ := E.Attr;
  var N := TEncoding.ANSI.GetBytes(Name);
  if Length(N) > 0 then
    Move(N[0], Dest[32], Min(Length(N), 32));
end;

// Flags 0 starts a listing of Name (a directory, then a pattern after the
// last '/'), other values go on with it; up to MaxEntries entries of 64
// bytes go to Table. Entries list in card order; '.' and '..' show the
// directory's and its parent's entries.
function TPS2MCServer.GetDir(Port: Integer; Flags: Cardinal; MaxEntries: Integer; Table: Cardinal;
  const Name: string): Integer;
begin
  var C := Cards[Port];
  if (Flags and $FFFF) = 0 then
  begin
    FListValid := False;
    var Slash := Name.LastIndexOf('/');
    var Dir: string;
    if Slash < 0 then
      Dir := Resolve(Port, '')
    else if Slash = 0 then
      Dir := ''
    else
      Dir := Resolve(Port, Name.Substring(0, Slash));
    var DE: TPS2CardEntry;
    if not C.Lookup(Dir, DE) or not DE.IsDirectory then
      Exit(ResNoEntry);
    FListPort := Port;
    FListDir := Dir;
    FListPattern := Name.Substring(Slash + 1);
    // The root lists no '.' and '..'.
    FListPos := 0;
    if Dir = '' then
      FListPos := 2;
    FListValid := True;
  end
  else if not FListValid or (FListPort <> Port) then
    Exit(ResNoEntry);
  var Dir: TPS2CardEntry;
  if not C.Lookup(FListDir, Dir) or not Dir.IsDirectory then
    Exit(ResNoEntry);
  var List := C.Entries(Dir);
  Result := 0;
  while (Result < MaxEntries) and (FListPos < Length(List)) do
  begin
    var Pos := FListPos;
    Inc(FListPos);
    var E := List[Pos];
    if not E.Exists then
      Continue;
    var EntryName := E.Name;
    case Pos of
      0:
        begin
          EntryName := '.';
          E := Dir;
        end;
      1:
        begin
          EntryName := '..';
          if not C.Lookup(Parent(FListDir), E) then
            Continue;
        end;
    end;
    if ((E.Mode and AttrHidden) <> 0) or not Matches(EntryName, FListPattern) then
      Continue;
    var P := EEPtr(Table + Cardinal(Result) * 64, 64);
    if P <> nil then
    begin
      Entry(P, EntryName, E);
      Touched(Table + Cardinal(Result) * 64, 64);
    end;
    Inc(Result);
  end;
end;

// The new current directory; its absolute path ('/' first) goes to Table.
function TPS2MCServer.ChDir(Port: Integer; Table: Cardinal; const Name: string): Integer;
begin
  var Path := Resolve(Port, Name);
  var E: TPS2CardEntry;
  if not Cards[Port].Lookup(Path, E) or not E.IsDirectory then
    Result := ResNoEntry
  else
  begin
    FCurrent[Port] := Path;
    Result := ResSucceed;
  end;
  var P := EEPtr(Table, 1024);
  if (Table <> 0) and (P <> nil) then
  begin
    var Cur := TEncoding.ANSI.GetBytes('/' + FCurrent[Port]);
    FillChar(P^, 1024, 0);
    Move(Cur[0], P^, Min(Length(Cur), 1023));
    Touched(Table, 1024);
  end;
end;

// Flags: 1 creation time, 2 modification time, 4 (or 200h) mode bits, 8 the
// attribute word, 10h the name, from the 64-byte entry at Info.
function TPS2MCServer.SetFileInfo(Port: Integer; Flags: Cardinal; Info: Cardinal; const Name: string): Integer;
begin
  var C := Cards[Port];
  var Path := Resolve(Port, Name);
  var E: TPS2CardEntry;
  var P := EEPtr(Info, 64);
  if not C.Lookup(Path, E) or (P = nil) then
    Exit(ResNoEntry);
  if (Flags and AttrFile) <> 0 then
  begin
    var NewName := CString(P + 32, 32);
    if (NewName = '') or (NewName = '.') or (NewName = '..') or NewName.Contains('/') or (Path = '') then
      Exit(ResNoEntry);
    var Target := Join(Parent(Path), NewName);
    var Other: TPS2CardEntry;
    if (Target <> Path) and C.Lookup(Target, Other) then
      Exit(ResDenied);
    if Target <> Path then
    begin
      E.Name := NewName;
      for var K := 0 to High(FFiles) do
        if FFiles[K].Open and (FFiles[K].Port = Port) and (FFiles[K].Path = Path) then
          FFiles[K].Path := Target;
    end;
  end;
  if (Flags and AttrProtected) <> 0 then
    E.Attr := PCardinal(P + 24)^;
  if (Flags and (AttrExecutable or CreateFile)) <> 0 then
    E.Mode := (E.Mode and not Word($180F)) or (PWord(P + 20)^ and $180F);
  if (Flags and AttrReadable) <> 0 then
    E.Created := PUInt64(P)^;
  if (Flags and AttrWritable) <> 0 then
    E.Modified := PUInt64(P + 8)^;
  C.WriteEntry(E);
  Result := ResSucceed;
end;

function TPS2MCServer.DeleteEntry(Port: Integer; const Name: string): Integer;
begin
  var C := Cards[Port];
  var Path := Resolve(Port, Name);
  var E: TPS2CardEntry;
  if (Path = '') or not C.Lookup(Path, E) then
    Exit(ResNoEntry);
  if (E.Mode and AttrWritable) = 0 then
    Exit(ResDenied);
  if E.IsDirectory then
    for var X in C.Entries(E) do
      if X.Exists and (X.Index >= 2) then
        Exit(ResNotEmpty);
  C.Remove(E);
  Touch(C, Parent(Path));
  Result := ResSucceed;
end;

function TPS2MCServer.Call(Fn: Cardinal; Args: PByte; Size: Integer; ReplySize: Integer): TBytes;
var
  Block: array[0..1043] of Byte;
begin
  // The parameter block (file or name form).
  FillChar(Block, SizeOf(Block), 0);
  Move(Args^, Block, Min(Size, SizeOf(Block)));
  var B := PByte(@Block[0]);
  var Fd := PInteger(B + DFd)^;
  var Port := PCardinal(B + DPort)^;
  var Slot := PCardinal(B + DSlot)^;
  var NamePort := PCardinal(B + NPort)^;
  var NameSlot := PCardinal(B + NSlot)^;
  var Name := CString(B + NName, 1024);
  if Log <> nil then
    Log.Add(Format('mc fn %x %.8x %.8x %.8x %s', [Fn, PCardinal(B)[0], PCardinal(B)[1], PCardinal(B)[2], Name]));
  var R := FStat[0];
  var Handled := True;
  case Fn of
    $70, $FE:
      begin
        R := ResSucceed;
        FStat[1] := ServVersion;
        FStat[2] := ManVersion;
      end;
    $78, $01:
      begin
        // Card information into the end parameter block: type at +0, free
        // clusters at +4; the XMCSERV block also has 'formatted' at +144.
        var NewForm := Fn = $01;
        R := Detect(Port, Slot, NewForm);
        var Present := Card(Port, Slot) <> nil;
        var Free := 0;
        var IsFormatted := False;
        if Present then
        begin
          Free := Cards[Port].FreeClusters;
          IsFormatted := Cards[Port].Formatted;
        end;
        var EndSize := 64;
        if NewForm then
          EndSize := 192;
        var P := EEPtr(PCardinal(B + DParam)^, EndSize);
        if P <> nil then
        begin
          var WantType, WantFree, WantFormat: Boolean;
          if NewForm then
          begin
            WantType := PInteger(B + DOrigin)^ > 0;
            WantFree := PInteger(B + DOffset)^ > 0;
            WantFormat := PInteger(B + DSize)^ > 0;
          end
          else
          begin
            WantType := PInteger(B + DSize)^ > 0;
            WantFree := PInteger(B + DOffset)^ <> 0;
            WantFormat := False;
          end;
          FillChar(P^, EndSize, 0);
          if WantType and Present then
            PInteger(P)^ := 2;
          if WantFree and (R >= ResChangedCard) then
            PInteger(P + 4)^ := Free;
          if WantFormat and (R >= ResChangedCard) then
            PInteger(P + 144)^ := Ord(IsFormatted);
          Touched(PCardinal(B + DParam)^, EndSize);
        end;
      end;
    $71, $02:
      begin
        R := Detect(NamePort, NameSlot);
        if R = ResSucceed then
          R := OpenFile(NamePort, PCardinal(B + NFlags)^, Name);
      end;
    $72, $03:
      if FileHandle(Fd) < 0 then
        R := ResDenied
      else
      begin
        FFiles[Fd].Open := False;
        R := Detect(FFiles[Fd].Port, 0);
      end;
    $75, $04:
      if FileHandle(Fd) < 0 then
        R := ResDenied
      else
      begin
        R := Detect(FFiles[Fd].Port, 0);
        if R = ResSucceed then
        begin
          var E: TPS2CardEntry;
          var Found := Cards[FFiles[Fd].Port].Lookup(FFiles[Fd].Path, E);
          var Pos := PInteger(B + DOffset)^;
          case PInteger(B + DOrigin)^ of
            0: ;
            2:
              if Found and not E.IsDirectory then
                Inc(Pos, Integer(E.Length));
          else
            Inc(Pos, FFiles[Fd].Position);
          end;
          FFiles[Fd].Position := Max(Pos, 0);
          R := FFiles[Fd].Position;
        end;
      end;
    $73, $05:
      begin
        // All the data goes straight to the buffer; the end parameter block
        // (unaligned head and tail for libmc to copy) stays empty.
        var EndSize := 64;
        if Fn = $05 then
          EndSize := 192;
        var P := EEPtr(PCardinal(B + DParam)^, EndSize);
        if P <> nil then
        begin
          FillChar(P^, EndSize, 0);
          Touched(PCardinal(B + DParam)^, EndSize);
        end;
        if FileHandle(Fd) < 0 then
          R := ResDenied
        else
        begin
          R := Detect(FFiles[Fd].Port, 0);
          if R = ResSucceed then
            R := ReadFile(Fd, PCardinal(B + DBuffer)^, PInteger(B + DSize)^);
          if R < 0 then
            FFiles[Fd].Open := False;
        end;
      end;
    $74, $06:
      if FileHandle(Fd) < 0 then
        R := ResDenied
      else
      begin
        R := Detect(FFiles[Fd].Port, 0);
        if R = ResSucceed then
          R := WriteFile(Fd, B + DData, PInteger(B + DOrigin)^, PCardinal(B + DBuffer)^, PInteger(B + DSize)^);
        if R < 0 then
          FFiles[Fd].Open := False;
      end;
    $7A, $0A:
      if FileHandle(Fd) < 0 then
        R := ResDenied
      else
        R := Detect(FFiles[Fd].Port, 0);
    $7B, $0C:
      begin
        R := Detect(NamePort, NameSlot);
        if R = ResSucceed then
          R := ChDir(NamePort, PCardinal(B + NTable)^, Name);
      end;
    $76, $0D:
      begin
        R := Detect(NamePort, NameSlot);
        if R = ResSucceed then
          R := GetDir(NamePort, PCardinal(B + NFlags)^, PInteger(B + NMax)^, PCardinal(B + NTable)^, Name);
      end;
    $7C, $0E:
      begin
        R := Detect(NamePort, NameSlot);
        if R = ResSucceed then
          R := SetFileInfo(NamePort, PCardinal(B + NFlags)^, PCardinal(B + NTable)^, Name);
      end;
    $79, $0F:
      begin
        R := Detect(NamePort, NameSlot);
        if R = ResSucceed then
          R := DeleteEntry(NamePort, Name);
      end;
    $77, $10, $80, $11:
      begin
        // Format and unformat leave an empty formatted card.
        R := Detect(Port, Slot);
        if R >= ResChangedCard then
        begin
          for var K := 0 to High(FFiles) do
            if FFiles[K].Port = Integer(Port) then
              FFiles[K].Open := False;
          Cards[Port].FormatFlash(CardNow);
          FCurrent[Port] := '';
          R := ResSucceed;
        end;
      end;
    $12:
      begin
        // Free directory entries: the rest of the last cluster.
        R := Detect(NamePort, NameSlot);
        if R = ResSucceed then
        begin
          var E: TPS2CardEntry;
          if not Cards[NamePort].Lookup(Resolve(NamePort, Name), E) or not E.IsDirectory then
            R := ResNoEntry
          else
            R := Integer(E.Length and 1);
        end;
      end;
    $14, $33:
      // Thread priority; bad block check (none).
      R := ResSucceed;
    $15:
      // Slots on a port (newer libmc): one, as there is no multitap.
      R := 1;
  else
    Handled := False;
  end;
  if Handled then
    FStat[0] := R;
  SetLength(Result, Max(ReplySize, SizeOf(FStat)));
  FillChar(Result[0], Length(Result), 0);
  Move(FStat, Result[0], SizeOf(FStat));
end;

procedure TPS2MCServer.SerializeState(State: TStateArchive);

  procedure Text(var S: string);
  begin
    var B := TEncoding.UTF8.GetBytes(S);
    var Len := Length(B);
    State.Field(Len, SizeOf(Len));
    if State.Loading then
    begin
      if (Len < 0) or (Len > 4096) then
        raise EReadError.Create('PS2 snapshot memory card path');
      SetLength(B, Len);
    end;
    if Len > 0 then
      State.Field(B[0], Len);
    if State.Loading then
      S := TEncoding.UTF8.GetString(B);
  end;

begin
  for var K := 0 to High(FFiles) do
  begin
    State.Field(FFiles[K].Port, SizeOf(Integer));
    State.Field(FFiles[K].Position, SizeOf(Integer));
    State.Field(FFiles[K].Open, SizeOf(Boolean));
    State.Field(FFiles[K].CanRead, SizeOf(Boolean));
    State.Field(FFiles[K].CanWrite, SizeOf(Boolean));
    Text(FFiles[K].Path);
  end;
  State.Field(FKnown, SizeOf(FKnown));
  State.Field(FStat, SizeOf(FStat));
  State.Field(ServVersion, SizeOf(ServVersion));
  State.Field(ManVersion, SizeOf(ManVersion));
  Text(FCurrent[0]);
  Text(FCurrent[1]);
  State.Field(FListPort, SizeOf(FListPort));
  State.Field(FListPos, SizeOf(FListPos));
  State.Field(FListValid, SizeOf(FListValid));
  Text(FListDir);
  Text(FListPattern);
end;

procedure TPS2MCServer.SerializeCards(State: TStateArchive);
begin
  Cards[0].SerializeState(State);
  Cards[1].SerializeState(State);
end;

end.
