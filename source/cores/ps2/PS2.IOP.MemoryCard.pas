unit PS2.IOP.MemoryCard;

// Memory cards at the file level: each card is a tree of directories and
// files kept in memory (TPS2MemoryCard, saved by the front end as one file)
// and the high-level MCSERV RPC server (SID 80000400h) libmc talks to: card
// info, open/close/seek/read/write, directories, delete, rename.
// Command layouts after Play! (BSD-2, Iop_McServ); the raw card format
// (pages, ECC, FAT) is not emulated.
{$IFDEF PS2_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, System.Classes, System.Math, System.Masks, System.Generics.Collections, System.Generics.Defaults,
  Core.Snapshots, PS2.Types, PS2.SIF;

const
  PS2MCServerSID = $80000400;
  PS2MemoryCardMagic: array[0..7] of AnsiChar = 'RMPS2MC1';

type
  TPS2MemoryCardEntry = class
  public
    Data: TBytes;
    IsDirectory: Boolean;
    Modified: TDateTime;
  end;

  // A card's contents: absolute paths without the leading '/' ('' is the
  // root), case-sensitive like the card's file system.
  TPS2MemoryCard = class
  private
    FEntries: TObjectDictionary<string, TPS2MemoryCardEntry>;
  public
    Dirty: Boolean;
    constructor Create;
    destructor Destroy; override;
    procedure Clear;
    function Find(const Path: string): TPS2MemoryCardEntry;
    function Add(const Path: string; Directory: Boolean): TPS2MemoryCardEntry;
    procedure Remove(const Path: string);
    procedure Rename(const OldPath, NewPath: string);
    // Direct children of a directory (names only).
    function Children(const Directory: string): TArray<string>;
    function Image: TBytes;
    procedure Load(const Data: TBytes);
    procedure SerializeState(State: TStateArchive);
  end;

  TPS2MCFile = record
    Port: Integer;
    Path: string;
    Position: Integer;
    Open: Boolean;
  end;

  TPS2MCServer = class(TPS2RPCServer)
  private
    FEERAM: PByte;
    FFiles: array[0..4] of TPS2MCFile;
    FCurrent: array[0..1] of string;
    FKnown: array[0..1] of Boolean;
    FListing: TList<TBytes>;
    FListIndex: Integer;
    function Card(Port: Cardinal): TPS2MemoryCard;
    function EEPtr(Address: Cardinal; Size: Integer): PByte;
    function Resolve(Port: Integer; const Name: string): string;
    function FileEntry(Handle: Cardinal; out F: TPS2MCFile; out E: TPS2MemoryCardEntry): Boolean;
    function MakeEntry(const Name: string; E: TPS2MemoryCardEntry; Count: Integer): TBytes;
    function OpenFile(Port: Integer; Flags: Cardinal; const Name: string): Integer;
    function GetDir(Port: Integer; Flags: Cardinal; MaxEntries: Integer; Table: Cardinal; const Name: string): Integer;
    function ChDir(Port: Integer; Table: Cardinal; const Name: string): Integer;
  public
    Cards: array[0..1] of TPS2MemoryCard;
    // A card in the second slot (the first always has one).
    SecondCard: Boolean;
    Log: TStrings;
    constructor Create(EERAM: PByte);
    destructor Destroy; override;
    procedure Reset; override;
    function Call(Fn: Cardinal; Args: PByte; Size: Integer; ReplySize: Integer): TBytes; override;
    procedure SerializeState(State: TStateArchive); override;
    // The cards' contents (kept across IOP resets).
    procedure SerializeCards(State: TStateArchive);
  end;

implementation

const
  ResNoEntry = -4;
  ResDenied = -5;
  ResNotEmpty = -6;
  AttrRead = $0001;
  AttrWrite = $0002;
  AttrExecute = $0004;
  AttrFile = $0010;
  AttrSubdir = $0020;
  AttrClosed = $0080;
  Attr0400 = $0400;
  AttrExists = $8000;
  AttrFolder = Attr0400 or AttrExists or AttrSubdir or AttrRead or AttrWrite or AttrExecute;
  AttrRegular = Attr0400 or AttrExists or AttrClosed or AttrFile or AttrRead or AttrWrite or AttrExecute;
  OpenCreate = $0200;
  OpenTrunc = $0400;
  OpenDirectory = $0040;

type
  TPS2MCArgs = array[0..15] of Cardinal;
  PPS2MCArgs = ^TPS2MCArgs;

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
  Add('', True);
  Dirty := False;
end;

function TPS2MemoryCard.Find(const Path: string): TPS2MemoryCardEntry;
begin
  if not FEntries.TryGetValue(Path, Result) then
    Result := nil;
end;

function TPS2MemoryCard.Add(const Path: string; Directory: Boolean): TPS2MemoryCardEntry;
begin
  Result := TPS2MemoryCardEntry.Create;
  Result.IsDirectory := Directory;
  Result.Modified := Now;
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
  var E := FEntries.ExtractPair(OldPath).Value;
  if E <> nil then
    FEntries.AddOrSetValue(NewPath, E);
  Dirty := True;
end;

function TPS2MemoryCard.Children(const Directory: string): TArray<string>;
begin
  var L := TList<string>.Create;
  try
    for var Key in FEntries.Keys do
      if (Key <> '') and (Parent(Key) = Directory) then
        L.Add(BaseName(Key));
    L.Sort;
    Result := L.ToArray;
  finally
    L.Free;
  end;
end;

// 'RMPS2MC1', count, then per entry: kind (0 file, 1 directory), name
// length and UTF-8 name, data length and data (little endian).
function TPS2MemoryCard.Image: TBytes;
begin
  var S := TMemoryStream.Create;
  try
    S.WriteBuffer(PS2MemoryCardMagic, 8);
    var Keys := FEntries.Keys.ToArray;
    TArray.Sort<string>(Keys);
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
    if (S.Read(Magic, 8) <> 8) or not CompareMem(@Magic, @PS2MemoryCardMagic, 8) then
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
      S.ReadBuffer(DataLen, 4);
      if (DataLen < 0) or (DataLen > S.Size - S.Position) then
        raise EReadError.Create('Damaged PS2 memory card');
      var E := Add(TEncoding.UTF8.GetString(Name), Kind <> 0);
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
  FListing := TList<TBytes>.Create;
  SecondCard := True;
  // libmc expects the reply some time after the call.
  Latency := PS2EEClock div 400;
end;

destructor TPS2MCServer.Destroy;
begin
  FListing.Free;
  Cards[0].Free;
  Cards[1].Free;
  inherited;
end;

procedure TPS2MCServer.Reset;
begin
  for var K := 0 to High(FFiles) do
    FFiles[K].Open := False;
  FCurrent[0] := '';
  FCurrent[1] := '';
  FKnown[0] := False;
  FKnown[1] := False;
  FListing.Clear;
  FListIndex := 0;
end;

function TPS2MCServer.Card(Port: Cardinal): TPS2MemoryCard;
begin
  if (Port > 1) or ((Port = 1) and not SecondCard) then
    Exit(nil);
  Result := Cards[Port];
end;

function TPS2MCServer.EEPtr(Address: Cardinal; Size: Integer): PByte;
begin
  var A := Address and PS2RAMMask;
  if (Size < 0) or (A + Cardinal(Size) > PS2RAMSize) then
    Exit(nil);
  Result := FEERAM + A;
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

function TPS2MCServer.FileEntry(Handle: Cardinal; out F: TPS2MCFile; out E: TPS2MemoryCardEntry): Boolean;
begin
  E := nil;
  if Handle > Cardinal(High(FFiles)) then
    Exit(False);
  F := FFiles[Handle];
  if not F.Open then
    Exit(False);
  E := Cards[F.Port].Find(F.Path);
  Result := (E <> nil) and not E.IsDirectory;
end;

function TPS2MCServer.OpenFile(Port: Integer; Flags: Cardinal; const Name: string): Integer;
begin
  var C := Cards[Port];
  var Path := Resolve(Port, Name);
  var Dir := C.Find(Parent(Path));
  if (Dir = nil) or not Dir.IsDirectory then
    Exit(ResNoEntry);
  var E := C.Find(Path);
  if Flags = OpenDirectory then
  begin
    if E <> nil then
      Exit(ResNoEntry);
    C.Add(Path, True);
    Exit(0);
  end;
  if (E <> nil) and E.IsDirectory then
    Exit(ResNoEntry);
  if E = nil then
  begin
    if (Flags and OpenCreate) = 0 then
      Exit(ResNoEntry);
    C.Add(Path, False);
  end
  else if (Flags and OpenTrunc) <> 0 then
  begin
    E.Data := nil;
    C.Dirty := True;
  end;
  for var K := 0 to High(FFiles) do
    if not FFiles[K].Open then
    begin
      FFiles[K].Port := Port;
      FFiles[K].Path := Path;
      FFiles[K].Position := 0;
      FFiles[K].Open := True;
      Exit(K);
    end;
  Result := -7;
end;

function TPS2MCServer.MakeEntry(const Name: string; E: TPS2MemoryCardEntry; Count: Integer): TBytes;
begin
  SetLength(Result, $40);
  FillChar(Result[0], $40, 0);
  var Y, Mo, D, H, Mi, S, Ms: Word;
  DecodeDate(E.Modified, Y, Mo, D);
  DecodeTime(E.Modified, H, Mi, S, Ms);
  for var T := 0 to 1 do
  begin
    Result[T * 8 + 1] := S;
    Result[T * 8 + 2] := Mi;
    Result[T * 8 + 3] := H;
    Result[T * 8 + 4] := D;
    Result[T * 8 + 5] := Mo;
    PWord(@Result[T * 8 + 6])^ := Y;
  end;
  if E.IsDirectory then
  begin
    PCardinal(@Result[16])^ := Cardinal(Count);
    PWord(@Result[20])^ := AttrFolder;
  end
  else
  begin
    PCardinal(@Result[16])^ := Cardinal(Length(E.Data));
    PWord(@Result[20])^ := AttrRegular;
  end;
  var N := TEncoding.ANSI.GetBytes(Name);
  Move(N[0], Result[32], Min(Length(N), 31));
end;

function TPS2MCServer.GetDir(Port: Integer; Flags: Cardinal; MaxEntries: Integer; Table: Cardinal;
  const Name: string): Integer;
begin
  var C := Cards[Port];
  if Flags = 0 then
  begin
    FListing.Clear;
    FListIndex := 0;
    var Path := Resolve(Port, Name);
    var Pattern := BaseName(Name);
    var Dir := Parent(Path);
    if not Name.Contains('/') then
      Dir := Resolve(Port, '');
    if Pattern = '' then
      Pattern := '*';
    var DE := C.Find(Dir);
    if (DE = nil) or not DE.IsDirectory then
      Exit(ResNoEntry);
    var Names := C.Children(Dir);
    var Mask := TMask.Create(Pattern);
    try
      for var Special in ['.', '..'] do
        if Mask.Matches(Special) then
          FListing.Add(MakeEntry(Special, DE, 0));
      for var N in Names do
        if Mask.Matches(N) then
        begin
          var Child := Dir;
          if Child <> '' then
            Child := Child + '/';
          Child := Child + N;
          FListing.Add(MakeEntry(N, C.Find(Child), Length(C.Children(Child)) + 2));
        end;
    finally
      Mask.Free;
    end;
  end;
  Result := 0;
  while (Result < MaxEntries) and (FListIndex < FListing.Count) do
  begin
    var P := EEPtr(Table + Cardinal(Result) * $40, $40);
    if P <> nil then
      Move(FListing[FListIndex][0], P^, $40);
    Inc(FListIndex);
    Inc(Result);
  end;
end;

function TPS2MCServer.ChDir(Port: Integer; Table: Cardinal; const Name: string): Integer;
begin
  if Table <> 0 then
  begin
    var P := EEPtr(Table, 256);
    if P <> nil then
    begin
      var Cur := TEncoding.ANSI.GetBytes('/' + FCurrent[Port]);
      FillChar(P^, 256, 0);
      Move(Cur[0], P^, Min(Length(Cur), 255));
    end;
  end;
  var Path := Resolve(Port, Name);
  var E := Cards[Port].Find(Path);
  if (E = nil) or not E.IsDirectory then
    Exit(ResNoEntry);
  FCurrent[Port] := Path;
  Result := 0;
end;

function TPS2MCServer.Call(Fn: Cardinal; Args: PByte; Size: Integer; ReplySize: Integer): TBytes;
begin
  SetLength(Result, Max(ReplySize, 16));
  FillChar(Result[0], Length(Result), 0);
  var A := PPS2MCArgs(Args);
  var Method := Fn and $7FFFFFFF;
  var R: Integer := 0;
  // Commands with a path: port, slot, flags, max entries, table, name.
  var CmdPort := A[0];
  var CmdFlags := A[2];
  var CmdMax := Integer(A[3]);
  var CmdTable := A[4];
  var CmdName := '';
  if Size >= $14 then
    CmdName := CString(Args + $14, Min(Size - $14, $400));
  // File commands: handle, size at +12, offset +16, origin +20, buffer +24,
  // parameter +28, inline data +32.
  var Handle := A[0];
  var FSize := Integer(A[3]);
  var FOffset := Integer(A[4]);
  var FOrigin := A[5];
  var FBuffer := A[6];
  var FParam := A[7];
  if Log <> nil then
    Log.Add(Format('mc fn %x %.8x %.8x %.8x %s', [Method, A[0], A[1], A[2], CmdName]));
  case Method of
    $01, $78:
      begin
        // GetInfo(port, slot, formatted?, free?, type?, -, buffer)
        var Port := PCardinal(Args + 4)^;
        var Buffer := PCardinal(Args + 28)^;
        if Card(Port) = nil then
        begin
          // No card: type 0, result 'not detected'.
          var P := EEPtr(Buffer, $94);
          if P <> nil then
          begin
            PCardinal(P)^ := 0;
            PCardinal(P + 4)^ := 0;
            PCardinal(P + $90)^ := 0;
          end;
          R := -10;
        end
        else
        begin
          var P := EEPtr(Buffer, $94);
          if P <> nil then
          begin
            if PCardinal(Args + 20)^ <> 0 then
              PCardinal(P)^ := 2;
            if PCardinal(Args + 16)^ <> 0 then
              PCardinal(P + 4)^ := $2000;
            if PCardinal(Args + 12)^ <> 0 then
              PCardinal(P + $90)^ := 1;
          end;
          if FKnown[Port] then
            R := 0
          else
            R := -1;
          FKnown[Port] := True;
        end;
      end;
    $02, $71:
      if Card(CmdPort) = nil then
        R := -1
      else
        R := OpenFile(CmdPort, CmdFlags, CmdName);
    $03, $72:
      if Handle <= Cardinal(High(FFiles)) then
        FFiles[Handle].Open := False
      else
        R := -1;
    $04:
      begin
        var F: TPS2MCFile;
        var E: TPS2MemoryCardEntry;
        if not FileEntry(Handle, F, E) then
          R := -1
        else
        begin
          var Pos := FOffset;
          case FOrigin of
            1: Pos := F.Position + FOffset;
            2: Pos := Length(E.Data) + FOffset;
          end;
          FFiles[Handle].Position := Max(Pos, 0);
          R := FFiles[Handle].Position;
        end;
      end;
    $05, $73, $16:
      begin
        var F: TPS2MCFile;
        var E: TPS2MemoryCardEntry;
        if FParam <> 0 then
        begin
          var P := EEPtr(FParam, 8);
          if P <> nil then
            FillChar(P^, 8, 0);
        end;
        if not FileEntry(Handle, F, E) then
          R := ResDenied
        else
        begin
          var Count := EnsureRange(Length(E.Data) - F.Position, 0, Max(FSize, 0));
          var P := EEPtr(FBuffer, Count);
          if (P <> nil) and (Count > 0) then
            Move(E.Data[F.Position], P^, Count);
          Inc(FFiles[Handle].Position, Count);
          R := Count;
        end;
      end;
    $06, $74, $1B:
      begin
        var F: TPS2MCFile;
        var E: TPS2MemoryCardEntry;
        if not FileEntry(Handle, F, E) then
          R := ResDenied
        else
        begin
          var Head := 0;
          if Method <> $1B then
            Head := Integer(Min(FOrigin, 16));
          var Total := Head + Max(FSize, 0);
          if F.Position + Total > Length(E.Data) then
            SetLength(E.Data, F.Position + Total);
          if Head > 0 then
            Move((Args + 32)^, E.Data[F.Position], Head);
          var P := EEPtr(FBuffer, Max(FSize, 0));
          if (P <> nil) and (FSize > 0) then
            Move(P^, E.Data[F.Position + Head], FSize);
          Inc(FFiles[Handle].Position, Total);
          E.Modified := Now;
          Cards[F.Port].Dirty := True;
          R := Total;
        end;
      end;
    $0A, $7A:
      R := 0;
    $0C:
      if Card(CmdPort) = nil then
        R := -1
      else
        R := ChDir(CmdPort, CmdTable, CmdName);
    $0D, $76:
      if Card(CmdPort) = nil then
        R := -1
      else
        R := GetDir(CmdPort, CmdFlags, CmdMax, CmdTable, CmdName);
    $0E, $7C:
      if Card(CmdPort) = nil then
        R := -1
      else
      begin
        // SetFileInfo: renames when the file attribute bit is given.
        var C := Cards[CmdPort];
        var Path := Resolve(CmdPort, CmdName);
        if C.Find(Path) = nil then
          R := ResNoEntry
        else if (CmdFlags and AttrFile) <> 0 then
        begin
          var P := EEPtr(CmdTable + 32, 32);
          if P <> nil then
          begin
            var NewName := CString(P, 32);
            var Target := Parent(Path);
            if Target <> '' then
              Target := Target + '/';
            Target := Target + NewName;
            if (NewName <> '') and (Target <> Path) then
              C.Rename(Path, Target);
          end;
        end;
      end;
    $0F, $79:
      if Card(CmdPort) = nil then
        R := -1
      else
      begin
        var C := Cards[CmdPort];
        var Path := Resolve(CmdPort, CmdName);
        var E := C.Find(Path);
        if (E = nil) or (Path = '') then
          R := ResNoEntry
        else if E.IsDirectory and (Length(C.Children(Path)) > 0) then
          R := ResNotEmpty
        else
          C.Remove(Path);
      end;
    $12:
      if Card(CmdPort) = nil then
        R := -1
      else
      begin
        var E := Cards[CmdPort].Find(Resolve(CmdPort, CmdName));
        if (E <> nil) and E.IsDirectory then
          R := $FE
        else
          R := ResNoEntry;
      end;
    $14:
      R := 0;
    $15:
      R := 1;
    $70, $FE:
      begin
        // Init: status, MCSERV and MCMAN versions.
        PCardinal(@Result[4])^ := $20A;
        PCardinal(@Result[8])^ := $20E;
      end;
  else
    R := 0;
  end;
  PInteger(@Result[0])^ := R;
end;

procedure TPS2MCServer.SerializeState(State: TStateArchive);
begin
  for var K := 0 to High(FFiles) do
  begin
    State.Field(FFiles[K].Port, SizeOf(Integer));
    State.Field(FFiles[K].Position, SizeOf(Integer));
    State.Field(FFiles[K].Open, SizeOf(Boolean));
    var Path := TEncoding.UTF8.GetBytes(FFiles[K].Path);
    var Len := Length(Path);
    State.Field(Len, SizeOf(Len));
    if State.Loading then
    begin
      if (Len < 0) or (Len > 4096) then
        raise EReadError.Create('PS2 snapshot memory card file');
      SetLength(Path, Len);
    end;
    if Len > 0 then
      State.Field(Path[0], Len);
    if State.Loading then
      FFiles[K].Path := TEncoding.UTF8.GetString(Path);
  end;
  State.Field(FKnown, SizeOf(FKnown));
  for var P := 0 to 1 do
  begin
    var Cur := TEncoding.UTF8.GetBytes(FCurrent[P]);
    var Len := Length(Cur);
    State.Field(Len, SizeOf(Len));
    if State.Loading then
    begin
      if (Len < 0) or (Len > 4096) then
        raise EReadError.Create('PS2 snapshot memory card directory');
      SetLength(Cur, Len);
    end;
    if Len > 0 then
      State.Field(Cur[0], Len);
    if State.Loading then
      FCurrent[P] := TEncoding.UTF8.GetString(Cur);
  end;
end;

procedure TPS2MCServer.SerializeCards(State: TStateArchive);
begin
  Cards[0].SerializeState(State);
  Cards[1].SerializeState(State);
end;

end.
