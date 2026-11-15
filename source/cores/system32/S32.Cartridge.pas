unit S32.Cartridge;

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections, Core.Storage,
  S32.RomSets;

type
  ES32Rom = class(EReadError);

  TS32Cartridge = class
  private
    FSet: TS32RomSet;
    FRegions: TDictionary<string, TBytes>;
    function GetRegion(const Name: string): TBytes;
  public
    constructor Create(Stream: TStream; const Name: string; const Storage: IStorage = nil);
    destructor Destroy; override;
    function Identity: TBytes;
    property RomSet: TS32RomSet read FSet;
    property Regions[const Name: string]: TBytes read GetRegion; default;
  end;

implementation

uses
  System.Hash, Core.Archive.Container, Core.MediaArchive;

constructor TS32Cartridge.Create(Stream: TStream; const Name: string; const Storage: IStorage);
begin
  inherited Create;
  FRegions := TDictionary<string, TBytes>.Create;
  var S := Storage;
  if S = nil then
    S := TStorage.Default;
  var Archive := OpenMediaArchive(Stream, Name, S);
  if not TS32RomSet.Identify(Archive, Name, FSet) then
    raise ES32Rom.Create('Unrecognized Sega System 32 ROM set: ' + Name);
  if FSet.Unsupported <> '' then
    raise ES32Rom.Create(FSet.Unsupported + ': ' + FSet.Title);
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
      var ParentSet: TS32RomSet;
      if not TS32RomSet.Find(Parent, ParentSet) then
        Break;
      Parent := ParentSet.Parent;
    end;
    var Total: Int64 := 0;
    for var R in FSet.Regions do
    begin
      if (R.Size <= 0) or (R.Size > 32 * 1024 * 1024) then
        raise ES32Rom.Create('Invalid System 32 region size');
      Inc(Total, R.Size);
      if Total > 96 * 1024 * 1024 then
        raise ES32Rom.Create('System 32 ROM regions exceed 96 MiB');
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
            raise ES32Rom.Create('Incorrect System 32 ROM size: ' + F.Name);
          var Input := A.OpenRead(Index);
          try
            if ArchiveCRC(Input) <> F.CRC then
              raise ES32Rom.Create('Corrupt System 32 ROM: ' + F.Name);
          finally
            Input.Free;
          end;
          A.Read(Index, Bytes);
          Found := True;
          Break;
        end;
        if not Found then
          raise ES32Rom.CreateFmt('%s: missing ROM %s (CRC %.8x). Place its parent archive beside the selected set.', [FSet.Name, F.Name, F.CRC]);
        Cache.Add(F.CRC, Bytes);
      end;
      var Dest := FRegions[F.Region];
      if (F.Offset < 0) or (F.Size <= 0) or (Length(Bytes) <> F.FileSize) or (F.SourceOffset < 0) or
        (Int64(F.SourceOffset) + F.Size > Length(Bytes)) or
        not (F.Stride in [1, 2, 4, 8]) or not (F.Group in [1, 2]) or (F.Size mod F.Group <> 0) or
        (Int64(F.Offset) + Int64((F.Size - 1) div F.Group) * F.Stride + (F.Size - 1) mod F.Group >= Length(Dest)) then
        raise ES32Rom.Create('Invalid System 32 ROM wiring: ' + F.Name);
      for var I := 0 to F.Size - 1 do
        Dest[F.Offset + (I div F.Group) * F.Stride + I mod F.Group] := Bytes[F.SourceOffset + I];
    end;
  finally
    Cache.Free;
    Seen.Free;
    Parents.Free;
  end;
end;

destructor TS32Cartridge.Destroy;
begin
  FRegions.Free;
  inherited;
end;

function TS32Cartridge.GetRegion(const Name: string): TBytes;
begin
  if not FRegions.TryGetValue(Name, Result) then
    Result := nil;
end;

function TS32Cartridge.Identity: TBytes;
begin
  var Hash := THashSHA2.Create;
  Hash.Update(TEncoding.UTF8.GetBytes('System32:' + FSet.Name));
  for var R in FSet.Regions do
  begin
    Hash.Update(TEncoding.UTF8.GetBytes(R.Name));
    Hash.Update(GetRegion(R.Name));
  end;
  Result := Hash.HashAsBytes;
end;

end.

