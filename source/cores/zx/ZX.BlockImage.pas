unit ZX.BlockImage;

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections, Core.Snapshots;

type
  // Immutable source stream, writable sparse sector overlay. The class owns Source.
  TZXBlockImage = class
  private
    FSource: TStream;
    FHash: TBytes;
    FChanges: TDictionary<Cardinal, TBytes>;
    FProtected, FDirty: Boolean;
    FCount: Cardinal;
    // Derived immutable-source read cache, never persisted; overlay wins.
    FReadCache: TBytes;
    FCacheFirst, FCacheSectors: Cardinal;
  public
    constructor Create(Source: TStream; const KnownHash: TBytes = nil);
    destructor Destroy; override;
    class function Identity(Source: TStream): TBytes; static;
    function ReadSector(LBA: Cardinal; out Data: TBytes): Boolean;
    function WriteSector(LBA: Cardinal; const Data: TBytes): Boolean;
    procedure SerializeState(State: TStateArchive);
    function SaveOverlay: TBytes;
    procedure LoadOverlay(const Data: TBytes);
    property Sectors: Cardinal read FCount;
    property Hash: TBytes read FHash;
    property WriteProtected: Boolean read FProtected write FProtected;
    property Dirty: Boolean read FDirty write FDirty;
  end;

implementation

uses
  System.Hash, System.Math, System.Generics.Defaults;

class function TZXBlockImage.Identity(Source: TStream): TBytes;
begin
  if (Source.Size < 512) or (Source.Size mod 512 <> 0) or (Source.Size > Int64($10000000) * 512) then
    raise EReadError.Create('Raw CF/SD image must contain 512-byte sectors (maximum 128 GiB)');

  var Position := Source.Position;
  Source.Position := 0;
  try
    Result := THashSHA2.GetHashBytes(Source);
  finally
    Source.Position := Position;
  end;
end;

constructor TZXBlockImage.Create(Source: TStream; const KnownHash: TBytes);
begin
  inherited Create;
  FSource := Source;
  FChanges := TDictionary<Cardinal, TBytes>.Create;
  if (Source.Size < 512) or (Source.Size mod 512 <> 0) or (Source.Size > Int64($10000000) * 512) then
    raise EReadError.Create('Invalid CF/SD source geometry');

  if Length(KnownHash) = 0 then
    FHash := Identity(Source)
  else
  begin
    if Length(KnownHash) <> 32 then
      raise EArgumentException.Create('CF/SD identity must be SHA-256');

    FHash := Copy(KnownHash); // Caller holds the source immutable after computing this identity.
  end;
  FCount := Source.Size div 512;
end;

destructor TZXBlockImage.Destroy;
begin
  FChanges.Free;
  FSource.Free;
  inherited;
end;

function TZXBlockImage.ReadSector(LBA: Cardinal; out Data: TBytes): Boolean;
begin
  Result := LBA < FCount;
  Data := nil;
  if not Result then
    Exit;
  if FChanges.TryGetValue(LBA, Data) then
  begin
    Data := Copy(Data);
    Exit;
  end;
  SetLength(Data, 512);
  if (FCacheSectors = 0) or (LBA < FCacheFirst) or (LBA - FCacheFirst >= FCacheSectors) then
  begin
    // Read the requested sector first: its I/O failures must propagate unchanged.
    var Sequential := (FCacheSectors <> 0) and (LBA = FCacheFirst + FCacheSectors);
    FCacheSectors := 0;
    FSource.Position := Int64(LBA) * 512;
    FSource.ReadBuffer(Data[0], 512);
    FCacheFirst := LBA;
    if Length(FReadCache) < 512 then
      SetLength(FReadCache, 512);
    Move(Data[0], FReadCache[0], 512);
    FCacheSectors := 1;
    // Random misses stay sector-sized; sequential access enables 64 KiB read-ahead.
    var Count: Cardinal := 1;
    if Sequential then
      Count := Min(Cardinal(128), FCount - LBA);
    if Count > 1 then
    try
      SetLength(FReadCache, Count * 512);
      FSource.ReadBuffer(FReadCache[512], (Count - 1) * 512);
      FCacheSectors := Count;
    except
      // A speculative neighbour failure cannot invalidate the requested sector
      // or surface an error before that neighbour is actually requested.
      FCacheSectors := 1;
    end;
  end
  else
    Move(FReadCache[(LBA - FCacheFirst) * 512], Data[0], 512);
end;

function TZXBlockImage.WriteSector(LBA: Cardinal; const Data: TBytes): Boolean;
begin
  Result := not FProtected and (LBA < FCount) and (Length(Data) = 512);
  if not Result then
    Exit;
  if (FChanges.Count >= 65536) and not FChanges.ContainsKey(LBA) then
    raise EWriteError.Create('CF/SD overlay exceeds 32 MiB of changed sectors');

  FChanges.AddOrSetValue(LBA, Copy(Data));
  FDirty := True;
end;

procedure TZXBlockImage.SerializeState(State: TStateArchive);
begin
  var Hash := Copy(FHash);
  State.Field(Hash[0], 32);
  var Count := FCount;
  State.Field(Count, 4);
  if (Count <> FCount) or not CompareMem(@Hash[0], @FHash[0], 32) then
    raise EReadError.Create('CF/SD state belongs to another source image');

  var Keys := FChanges.Keys.ToArray;
  TArray.Sort<Cardinal>(Keys);
  var N := Length(Keys);
  State.Field(N, 4);
  if (N < 0) or (N > 65536) then
    raise EReadError.Create('Invalid CF/SD overlay size');

  var Changes := TDictionary<Cardinal, TBytes>.Create;
  try
    for var i := 0 to N - 1 do
    begin
      var LBA: Cardinal := 0;
      var Data: TBytes;
      if not State.Loading then
      begin
        LBA := Keys[i];
        Data := FChanges[LBA];
      end;
      State.Field(LBA, 4);
      if State.Loading then
        SetLength(Data, 512);
      State.Field(Data[0], 512);
      if (LBA >= FCount) or Changes.ContainsKey(LBA) then
        raise EReadError.Create('Invalid CF/SD overlay sector');

      Changes.Add(LBA, Data);
    end;
    State.Field(FProtected, SizeOf(FProtected));
    var Dirty := FDirty;
    State.Field(Dirty, SizeOf(Dirty));
    if State.Loading then
    begin
      FChanges.Free;
      FChanges := Changes;
      Changes := nil;
      FDirty := Dirty;
    end;
  finally
    Changes.Free;
  end;
end;

function TZXBlockImage.SaveOverlay: TBytes;
begin
  var S := TMemoryStream.Create;
  try
    var Magic: UInt64 := $32564F4B4C42585A;
    S.WriteBuffer(Magic, 8);
    var A := TStateArchive.Create(S, False);
    try
      SerializeState(A);
    finally
      A.Free;
    end;
    var Data: TBytes;
    SetLength(Data, S.Size);
    S.Position := 0;
    S.ReadBuffer(Data[0], Length(Data));
    var Hasher := THashSHA2.Create;
    Hasher.Update(Data);
    var Digest := Hasher.HashAsBytes;
    SetLength(Result, Length(Data) + 32);
    Move(Data[0], Result[0], Length(Data));
    Move(Digest[0], Result[Length(Data)], 32);
  finally
    S.Free;
  end;
end;

procedure TZXBlockImage.LoadOverlay(const Data: TBytes);
begin
  if Length(Data) < 81 then
    raise EReadError.Create('Truncated CF/SD overlay file');
  var Payload := Copy(Data, 0, Length(Data) - 32);
  var Hasher := THashSHA2.Create;
  Hasher.Update(Payload);
  var Digest := Hasher.HashAsBytes;
  if not CompareMem(@Digest[0], @Data[Length(Payload)], 32) then
    raise EReadError.Create('CF/SD overlay checksum mismatch');
  var S := TBytesStream.Create(Payload);
  try
    var Magic: UInt64;
    S.ReadBuffer(Magic, 8);
    if Magic <> $32564F4B4C42585A then
      raise EReadError.Create('Invalid CF/SD overlay file');
    var A := TStateArchive.Create(S, True);
    try
      SerializeState(A);
    finally
      A.Free;
    end;
    if S.Position <> S.Size then
      raise EReadError.Create('Trailing CF/SD overlay data');
  finally
    S.Free;
  end;
end;

end.

