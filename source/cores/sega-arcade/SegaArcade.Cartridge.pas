unit SegaArcade.Cartridge;

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections, Core.Storage,
  SegaArcade.RomSets, Core.Archive.Container;

type
  ESegaArcadeRom = class(EReadError);

  TSegaRomIdentify = function(const Archive: IArchiveContainer; const Hint: string; out RomSet: TSegaArcadeRomSet): Boolean;

  TSegaRomFind = function(const Name: string; out RomSet: TSegaArcadeRomSet): Boolean;

  TSegaArcadeCartridge = class
  private
    FSet: TSegaArcadeRomSet;
    FIdentityPrefix: string;
    FRegions: TDictionary<string, TBytes>;
    function GetRegion(const Name: string): TBytes;
  public
    constructor Create(Stream: TStream; const Name: string; const Storage: IStorage; const platform, IdentityPrefix: string; Identify: TSegaRomIdentify; Find: TSegaRomFind);
    destructor Destroy; override;
    function Identity: TBytes;
    property RomSet: TSegaArcadeRomSet read FSet;
    property Regions[const Name: string]: TBytes read GetRegion; default;
  end;

implementation

uses
  System.Hash, Core.MediaArchive;

constructor TSegaArcadeCartridge.Create(Stream: TStream; const Name: string; const Storage: IStorage; const platform, IdentityPrefix: string; Identify: TSegaRomIdentify; Find: TSegaRomFind);
begin
  inherited Create;
  FIdentityPrefix := IdentityPrefix;
  FRegions := TDictionary<string, TBytes>.Create;
  var S := Storage;
  if S = nil then
    S := TStorage.Default;
  var Archive := OpenMediaArchive(Stream, Name, S);
  if not Identify(Archive, Name, FSet) then
    raise ESegaArcadeRom.CreateFmt('Unrecognized %s ROM set: %s', [platform, Name]);
  if FSet.Unsupported <> '' then
    raise ESegaArcadeRom.Create(FSet.Title + ': ' + FSet.Unsupported);
  var Parents := TList<IArchiveContainer>.Create;
  var Seen := TList<string>.Create;
  var Cache := TDictionary<Cardinal, TBytes>.Create;
  try
    Parents.Add(Archive);
    var Parent := FSet.Parent;
    while (Parent <> '') and not Seen.Contains(Parent) do
    begin
      Seen.Add(Parent);
      var Path := FindMediaArchive(S, ExtractFilePath(Name.Replace('/', PathDelim)) + Parent);
      if Path <> '' then
      begin
        var Input := S.OpenRead(Path);
        try
          Parents.Add(OpenMediaArchive(Input, Path, S));
        finally
          Input.Free;
        end;
      end;
      var ParentSet: TSegaArcadeRomSet;
      if not Find(Parent, ParentSet) then
        Break;
      Parent := ParentSet.Parent;
    end;
    var Total: Int64 := 0;
    for var R in FSet.Regions do
    begin
      if (R.Size <= 0) or (R.Size > 8 * 1024 * 1024) then
        raise ESegaArcadeRom.Create(platform + ': Invalid ROM region size');
      Inc(Total, R.Size);
      if Total > 32 * 1024 * 1024 then
        raise ESegaArcadeRom.Create(platform + ': ROM regions exceed 32 MiB');
      var Bytes: TBytes;
      SetLength(Bytes, R.Size);
      FillChar(Bytes[0], Length(Bytes), $FF);
      FRegions.Add(R.Name, Bytes);
      Bytes := nil;
    end;
    for var F in FSet.Files do
    begin
      var Bytes: TBytes;
      if not Cache.TryGetValue(F.CRC, Bytes) then
      begin
        var Found := False;
        for var A in Parents do
        begin
          var Index := A.FindCRC(F.CRC);
          if Index < 0 then
            Continue;
          if A.Entries[Index].Size <> UInt64(F.FileSize) then
            raise ESegaArcadeRom.Create(platform + ': Incorrect ROM size: ' + F.Name);
          var Input := A.OpenRead(Index);
          try
            if ArchiveCRC(Input) <> F.CRC then
              raise ESegaArcadeRom.Create(platform + ': Corrupt ROM: ' + F.Name);
          finally
            Input.Free;
          end;
          A.Read(Index, Bytes);
          Found := True;
          Break;
        end;
        if not Found then
          raise ESegaArcadeRom.CreateFmt('%s: missing ROM %s (CRC %.8x). Place its parent archive beside the selected set.', [FSet.Name, F.Name, F.CRC]);
        Cache.Add(F.CRC, Bytes);
      end;
      var Dest := FRegions[F.Region];
      if (F.Offset < 0) or (F.Size <= 0) or (Length(Bytes) <> F.FileSize) or (F.SourceOffset < 0) or
        (Int64(F.SourceOffset) + F.Size > Length(Bytes)) or
        not (F.Stride in [1, 2]) or
        (Int64(F.Offset) + Int64(F.Size - 1) * F.Stride >= Length(Dest)) then
        raise ESegaArcadeRom.Create(platform + ': Invalid ROM wiring: ' + F.Name);
      for var I := 0 to F.Size - 1 do
        Dest[F.Offset + I * F.Stride] := Bytes[F.SourceOffset + I];
    end;
  finally
    Cache.Free;
    Seen.Free;
    Parents.Free;
  end;
end;

destructor TSegaArcadeCartridge.Destroy;
begin
  FRegions.Free;
  inherited;
end;

function TSegaArcadeCartridge.GetRegion(const Name: string): TBytes;
begin
  if not FRegions.TryGetValue(Name, Result) then
    Result := nil;
end;

function TSegaArcadeCartridge.Identity: TBytes;
begin
  var Hash := THashSHA2.Create;
  Hash.Update(TEncoding.UTF8.GetBytes(FIdentityPrefix + ':' + FSet.Name));
  for var R in FSet.Regions do
  begin
    Hash.Update(TEncoding.UTF8.GetBytes(R.Name));
    Hash.Update(GetRegion(R.Name));
  end;
  Result := Hash.HashAsBytes;
end;

end.

