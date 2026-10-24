unit PS2.IOP.MemoryCard;

// Memory cards at the file level: each card is a tree of directories and
// files kept in memory (TPS2MemoryCard, saved by the front end as one file)
// and a high-level MCSERV/XMCSERV RPC server (SID 80000400h) for libmc. It
// takes both function sets (70h..80h of MCSERV, 01h..15h, 33h and FEh of
// XMCSERV), the parameter blocks libmc sends and the result block it reads
// (result, MCSERV and MCMAN versions), and behaves as MCMAN does on a
// formatted 8 MB card: the first access after a card appears reports a new
// card, at most three files are open, directories list in creation order
// ('.' and '..' except in the root) with '*' and '?' patterns, a file
// created over an existing one replaces it, and file times come from the
// console clock. The raw card format (pages, ECC, FAT) is not emulated.
// References: ps2sdk libmc, mcserv and mcman (AFL 2.0; interface, data
// layouts and result codes).
{$IFDEF PS2_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$POINTERMATH ON}

interface

uses
  System.SysUtils, System.Classes, System.Math, System.DateUtils, System.Generics.Collections,
  System.Generics.Defaults, Core.Snapshots, PS2.Types, PS2.SIF;

const
  PS2MCServerSID = $80000400;
  PS2MemoryCardMagic: array[0..7] of AnsiChar = 'RMPS2MC2';
  PS2MemoryCardMagic1: array[0..7] of AnsiChar = 'RMPS2MC1';

type
  TPS2MemoryCardEntry = class
  public
    Data: TBytes;
    IsDirectory: Boolean;
    // sceMcStDateTime: unused, second, minute, hour, day, month, year (16).
    Created, Modified: UInt64;
    // Mode bits (sceMcFileAttr*) and the attribute word.
    Mode: Word;
    Attr: Cardinal;
    // Creation sequence: the order directories list in.
    Order: Int64;
  end;

  // A card's contents: absolute paths without the leading '/' ('' is the
  // root), case-sensitive like the card's file system.
  TPS2MemoryCard = class
  private
    FEntries: TObjectDictionary<string, TPS2MemoryCardEntry>;
    FNextOrder: Int64;
  public
    Dirty: Boolean;
    constructor Create;
    destructor Destroy; override;
    procedure Clear;
    function Find(const Path: string): TPS2MemoryCardEntry;
    function Add(const Path: string; Directory: Boolean; Time: UInt64): TPS2MemoryCardEntry;
    procedure Remove(const Path: string);
    procedure Rename(const OldPath, NewPath: string);
    // Direct children of a directory (names only), in creation order.
    function Children(const Directory: string): TArray<string>;
    // Clusters (1 KB) the files and directories take.
    function UsedClusters: Integer;
    function Image: TBytes;
    procedure Load(const Data: TBytes);
    procedure SerializeState(State: TStateArchive);
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
    function CardNow: UInt64;
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
    procedure Entry(Dest: PByte; const Name: string; E: TPS2MemoryCardEntry);
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
  var T := IncSecond(EncodeDateTime(2004, 1, 1, 12, 0, 0, 0), Cycles div PS2EEClock);
  var Y, Mo, D, H, Mi, S, Ms: Word;
  DecodeDateTime(T, Y, Mo, D, H, Mi, S, Ms);
  Result := (UInt64(S) shl 8) or (UInt64(Mi) shl 16) or (UInt64(H) shl 24) or (UInt64(D) shl 32) or
    (UInt64(Mo) shl 40) or (UInt64(Y) shl 48);
end;

{ TPS2MemoryCard }

constructor TPS2MemoryCard.Create;
begin
  inherited Create;
  FEntries := TObjectDictionary<string, TPS2MemoryCardEntry>.Create([doOwnsValues]);
  Clear;
end;

destructor TPS2MemoryCard.Destroy;
begin
  FEntries.Free;
  inherited;
end;

procedure TPS2MemoryCard.Clear;
begin
  FEntries.Clear;
  FNextOrder := 0;
  Add('', True, PS2CardTime(0));
  Dirty := False;
end;

function TPS2MemoryCard.Find(const Path: string): TPS2MemoryCardEntry;
begin
  if not FEntries.TryGetValue(Path, Result) then
    Result := nil;
end;

function TPS2MemoryCard.Add(const Path: string; Directory: Boolean; Time: UInt64): TPS2MemoryCardEntry;
begin
  Result := TPS2MemoryCardEntry.Create;
  Result.IsDirectory := Directory;
  Result.Created := Time;
  Result.Modified := Time;
  if Directory then
    Result.Mode := ModeDir
  else
    Result.Mode := ModeFile;
  Result.Order := FNextOrder;
  Inc(FNextOrder);
  FEntries.AddOrSetValue(Path, Result);
  Dirty := True;
end;

procedure TPS2MemoryCard.Remove(const Path: string);
begin
  FEntries.Remove(Path);
  Dirty := True;
end;

procedure TPS2MemoryCard.Rename(const OldPath, NewPath: string);
begin
  // The entry and, for a directory, everything below it.
  var Moves := TList<string>.Create;
  try
    for var Key in FEntries.Keys do
      if (Key = OldPath) or Key.StartsWith(OldPath + '/') then
        Moves.Add(Key);
    for var Key in Moves do
    begin
      var E := FEntries.ExtractPair(Key).Value;
      FEntries.AddOrSetValue(NewPath + Key.Substring(Length(OldPath)), E);
    end;
  finally
    Moves.Free;
  end;
  Dirty := True;
end;

function TPS2MemoryCard.Children(const Directory: string): TArray<string>;
begin
  var L := TList<TPair<Int64, string>>.Create;
  try
    for var P in FEntries do
      if (P.Key <> '') and (Parent(P.Key) = Directory) then
        L.Add(TPair<Int64, string>.Create(P.Value.Order, BaseName(P.Key)));
    L.Sort(TComparer<TPair<Int64, string>>.Construct(
      function(const A, B: TPair<Int64, string>): Integer
      begin
        Result := CompareValue(A.Key, B.Key);
      end));
    SetLength(Result, L.Count);
    for var K := 0 to L.Count - 1 do
      Result[K] := L[K].Value;
  finally
    L.Free;
  end;
end;

function TPS2MemoryCard.UsedClusters: Integer;
begin
  Result := 0;
  var Counts := TDictionary<string, Integer>.Create;
  try
    for var Key in FEntries.Keys do
      if Key <> '' then
      begin
        var Dir := Parent(Key);
        var N: Integer;
        if not Counts.TryGetValue(Dir, N) then
          N := 0;
        Counts.AddOrSetValue(Dir, N + 1);
      end;
    for var P in FEntries do
      if P.Value.IsDirectory then
      begin
        // '.', '..' and the entries, two per cluster; the root's first
        // cluster belongs to the format.
        var N: Integer;
        if not Counts.TryGetValue(P.Key, N) then
          N := 0;
        var Clusters := (N + 2 + 1) div 2;
        if P.Key = '' then
          Dec(Clusters);
        Inc(Result, Clusters);
      end
      else
        Inc(Result, (Length(P.Value.Data) + ClusterSize - 1) div ClusterSize);
  finally
    Counts.Free;
  end;
end;

// 'RMPS2MC2', count, then per entry in creation order: kind (0 file, 1
// directory), name length and UTF-8 name, created and modified times, mode,
// attribute, data length and data (little endian). 'RMPS2MC1' images have
// kind, name and data only.
function TPS2MemoryCard.Image: TBytes;
begin
  var S := TMemoryStream.Create;
  try
    S.WriteBuffer(PS2MemoryCardMagic, 8);
    var Keys := FEntries.Keys.ToArray;
    TArray.Sort<string>(Keys, TComparer<string>.Construct(
      function(const A, B: string): Integer
      begin
        Result := CompareValue(FEntries[A].Order, FEntries[B].Order);
      end));
    var Count := Length(Keys);
    S.WriteBuffer(Count, 4);
    for var Key in Keys do
    begin
      var E := FEntries[Key];
      var Kind: Byte := Ord(E.IsDirectory);
      var Name := TEncoding.UTF8.GetBytes(Key);
      var NameLen := Length(Name);
      var DataLen := Length(E.Data);
      S.WriteBuffer(Kind, 1);
      S.WriteBuffer(NameLen, 4);
      if NameLen > 0 then
        S.WriteBuffer(Name[0], NameLen);
      S.WriteBuffer(E.Created, 8);
      S.WriteBuffer(E.Modified, 8);
      S.WriteBuffer(E.Mode, 2);
      S.WriteBuffer(E.Attr, 4);
      S.WriteBuffer(DataLen, 4);
      if DataLen > 0 then
        S.WriteBuffer(E.Data[0], DataLen);
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
  var S := TBytesStream.Create(Data);
  try
    var Magic: array[0..7] of AnsiChar;
    if S.Read(Magic, 8) <> 8 then
      raise EReadError.Create('Not a RetroMul PS2 memory card');
    var V2 := CompareMem(@Magic, @PS2MemoryCardMagic, 8);
    if not V2 and not CompareMem(@Magic, @PS2MemoryCardMagic1, 8) then
      raise EReadError.Create('Not a RetroMul PS2 memory card');
    var Count: Integer;
    S.ReadBuffer(Count, 4);
    if (Count < 0) or (Count > 100000) then
      raise EReadError.Create('Damaged PS2 memory card');
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
      var Path := TEncoding.UTF8.GetString(Name);
      var E := Find(Path);
      if E = nil then
        E := Add(Path, Kind <> 0, PS2CardTime(0));
      E.IsDirectory := Kind <> 0;
      if V2 then
      begin
        S.ReadBuffer(E.Created, 8);
        S.ReadBuffer(E.Modified, 8);
        S.ReadBuffer(E.Mode, 2);
        S.ReadBuffer(E.Attr, 4);
      end;
      S.ReadBuffer(DataLen, 4);
      if (DataLen < 0) or (DataLen > S.Size - S.Position) then
        raise EReadError.Create('Damaged PS2 memory card');
      SetLength(E.Data, DataLen);
      if DataLen > 0 then
        S.ReadBuffer(E.Data[0], DataLen);
    end;
  finally
    S.Free;
  end;
  Dirty := False;
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
  var Dir := C.Find(Parent(Path));
  if (Dir = nil) or not Dir.IsDirectory then
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
  var E := C.Find(Path);
  if (Flags and CreateDir) <> 0 then
  begin
    if E <> nil then
      Exit(ResNoEntry);
    E := C.Add(Path, True, CardNow);
    E.Mode := E.Mode or (Flags and AttrHidden);
    Dir.Modified := E.Created;
    Exit(ResSucceed);
  end;
  if E = nil then
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
      C.Remove(Path);
      E := nil;
    end;
  end;
  if E = nil then
  begin
    E := C.Add(Path, False, CardNow);
    E.Mode := E.Mode or (Flags and AttrHidden);
    if Dir <> nil then
      Dir.Modified := E.Created;
  end;
  FFiles[Slot] := Default(TPS2MCFile);
  FFiles[Slot].Port := Port;
  FFiles[Slot].Path := Path;
  FFiles[Slot].Open := True;
  FFiles[Slot].CanRead := (Flags and AttrReadable) <> 0;
  FFiles[Slot].CanWrite := (Flags and AttrWritable) <> 0;
  Result := Slot;
end;

function TPS2MCServer.ReadFile(Fd: Integer; Buffer: Cardinal; Size: Integer): Integer;
begin
  var H := FileHandle(Fd);
  if (H < 0) or not FFiles[H].CanRead then
    Exit(ResDenied);
  var E := Cards[FFiles[H].Port].Find(FFiles[H].Path);
  if (E = nil) or E.IsDirectory then
    Exit(ResDenied);
  var Count := EnsureRange(Length(E.Data) - FFiles[H].Position, 0, Max(Size, 0));
  var P := EEPtr(Buffer, Count);
  if (P <> nil) and (Count > 0) then
  begin
    Move(E.Data[FFiles[H].Position], P^, Count);
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
  var E := C.Find(FFiles[H].Path);
  if (E = nil) or E.IsDirectory then
    Exit(ResDenied);
  InSize := EnsureRange(InSize, 0, 16);
  Size := Max(Size, 0);
  var Total := InSize + Size;
  var Pos := FFiles[H].Position;
  var NewLength := Max(Length(E.Data), Pos + Total);
  // Clusters the file grows by must be free.
  var Grow := (NewLength + ClusterSize - 1) div ClusterSize - (Length(E.Data) + ClusterSize - 1) div ClusterSize;
  if Grow > CardClusters - C.UsedClusters then
    Exit(ResFullDevice);
  SetLength(E.Data, NewLength);
  if InSize > 0 then
    Move(InData^, E.Data[Pos], InSize);
  var P := EEPtr(Buffer, Size);
  if (P <> nil) and (Size > 0) then
    Move(P^, E.Data[Pos + InSize], Size);
  FFiles[H].Position := Pos + Total;
  E.Modified := CardNow;
  C.Dirty := True;
  Result := Total;
end;

procedure TPS2MCServer.Entry(Dest: PByte; const Name: string; E: TPS2MemoryCardEntry);
begin
  FillChar(Dest^, 64, 0);
  PUInt64(Dest)^ := E.Created;
  PUInt64(Dest + 8)^ := E.Modified;
  if not E.IsDirectory then
    PCardinal(Dest + 16)^ := Cardinal(Length(E.Data));
  PWord(Dest + 20)^ := E.Mode;
  PCardinal(Dest + 24)^ := E.Attr;
  var N := TEncoding.ANSI.GetBytes(Name);
  if Length(N) > 0 then
    Move(N[0], Dest[32], Min(Length(N), 32));
end;

// Flags 0 starts a listing of Name (a directory, then a pattern after the
// last '/'), other values go on with it; up to MaxEntries entries of 64
// bytes go to Table.
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
    var DE := C.Find(Dir);
    if (DE = nil) or not DE.IsDirectory then
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
  var Names := C.Children(FListDir);
  Result := 0;
  while (Result < MaxEntries) and (FListPos < Length(Names) + 2) do
  begin
    var Pos := FListPos;
    Inc(FListPos);
    var EntryName: string;
    var E: TPS2MemoryCardEntry;
    case Pos of
      0:
        begin
          EntryName := '.';
          E := C.Find(FListDir);
        end;
      1:
        begin
          EntryName := '..';
          E := C.Find(Parent(FListDir));
        end;
    else
      EntryName := Names[Pos - 2];
      E := C.Find(Join(FListDir, EntryName));
    end;
    if (E = nil) or ((E.Mode and AttrHidden) <> 0) or not Matches(EntryName, FListPattern) then
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
  var E := Cards[Port].Find(Path);
  if (E = nil) or not E.IsDirectory then
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
  var E := C.Find(Path);
  var P := EEPtr(Info, 64);
  if (E = nil) or (P = nil) then
    Exit(ResNoEntry);
  if (Flags and AttrFile) <> 0 then
  begin
    var NewName := CString(P + 32, 32);
    if (NewName = '') or (NewName = '.') or (NewName = '..') or NewName.Contains('/') or (Path = '') then
      Exit(ResNoEntry);
    var Target := Join(Parent(Path), NewName);
    if (Target <> Path) and (C.Find(Target) <> nil) then
      Exit(ResDenied);
    if Target <> Path then
    begin
      C.Rename(Path, Target);
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
  C.Dirty := True;
  Result := ResSucceed;
end;

function TPS2MCServer.DeleteEntry(Port: Integer; const Name: string): Integer;
begin
  var C := Cards[Port];
  var Path := Resolve(Port, Name);
  var E := C.Find(Path);
  if (E = nil) or (Path = '') then
    Exit(ResNoEntry);
  if (E.Mode and AttrWritable) = 0 then
    Exit(ResDenied);
  if E.IsDirectory and (Length(C.Children(Path)) > 0) then
    Exit(ResNotEmpty);
  C.Remove(Path);
  var Dir := C.Find(Parent(Path));
  if Dir <> nil then
    Dir.Modified := CardNow;
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
        if Present then
          Free := Max(0, CardClusters - Cards[Port].UsedClusters);
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
            PInteger(P + 144)^ := 1;
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
          var E := Cards[FFiles[Fd].Port].Find(FFiles[Fd].Path);
          var Pos := PInteger(B + DOffset)^;
          case PInteger(B + DOrigin)^ of
            0: ;
            2:
              if (E <> nil) and not E.IsDirectory then
                Inc(Pos, Length(E.Data));
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
          Cards[Port].Clear;
          Cards[Port].Dirty := True;
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
          var Path := Resolve(NamePort, Name);
          var E := Cards[NamePort].Find(Path);
          if (E = nil) or not E.IsDirectory then
            R := ResNoEntry
          else
            R := (Length(Cards[NamePort].Children(Path)) + 2) and 1;
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
