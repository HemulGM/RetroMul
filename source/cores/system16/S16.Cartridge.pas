unit S16.Cartridge;

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections, Core.Storage,
  S16.RomSets;

type
  ES16Rom = class(EReadError);

  TS16Cartridge = class
  private
    FSet: TS16RomSet;
    FRegions: TDictionary<string, TBytes>;
    function GetRegion(const Name: string): TBytes;
  public
    constructor Create(Stream: TStream; const Name: string; const Storage: IStorage = nil);
    destructor Destroy; override;
    function Identity: TBytes;
    property RomSet: TS16RomSet read FSet;
    property Regions[const Name: string]: TBytes read GetRegion; default;
  end;

implementation

uses
  System.Hash, Core.Archive.Container, Core.MediaArchive;

constructor TS16Cartridge.Create(Stream: TStream; const Name: string; const Storage: IStorage);
begin
  inherited Create;
  FRegions := TDictionary<string, TBytes>.Create;
  var S := Storage;
  if S = nil then
    S := TStorage.Default;
  var Archive := OpenMediaArchive(Stream, Name, S);
  if not TS16RomSet.Identify(Archive, Name, FSet) then
    raise ES16Rom.Create('Unrecognized Sega System 16 ROM set: ' + Name);
  if FSet.Unsupported <> '' then
    raise ES16Rom.Create(FSet.Title + ': ' + FSet.Unsupported);
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
      var ParentSet: TS16RomSet;
      if not TS16RomSet.Find(Parent, ParentSet) then
        Break;
      Parent := ParentSet.Parent;
    end;
    var Total: Int64 := 0;
    for var R in FSet.Regions do
    begin
      if (R.Size <= 0) or (R.Size > 8 * 1024 * 1024) then
        raise ES16Rom.Create('Invalid System 16 region size');
      Inc(Total, R.Size);
      if Total > 32 * 1024 * 1024 then
        raise ES16Rom.Create('System 16 ROM regions exceed 32 MiB');
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
            raise ES16Rom.Create('Incorrect System 16 ROM size: ' + F.Name);
          var Input := A.OpenRead(Index);
          try
            if ArchiveCRC(Input) <> F.CRC then
              raise ES16Rom.Create('Corrupt System 16 ROM: ' + F.Name);
          finally
            Input.Free;
          end;
          A.Read(Index, Bytes);
          Found := True;
          Break;
        end;
        if not Found then
          raise ES16Rom.CreateFmt('%s: missing ROM %s (CRC %.8x). Place its parent archive beside the selected set.', [FSet.Name, F.Name, F.CRC]);
        Cache.Add(F.CRC, Bytes);
      end;
      var Dest := FRegions[F.Region];
      if (F.Offset < 0) or (F.Size <= 0) or (Length(Bytes) <> F.FileSize) or (F.SourceOffset < 0) or
        (Int64(F.SourceOffset) + F.Size > Length(Bytes)) or
        not (F.Stride in [1, 2]) or
        (Int64(F.Offset) + Int64(F.Size - 1) * F.Stride >= Length(Dest)) then
        raise ES16Rom.Create('Invalid System 16 ROM wiring: ' + F.Name);
      for var I := 0 to F.Size - 1 do
        Dest[F.Offset + I * F.Stride] := Bytes[F.SourceOffset + I];
    end;
  finally
    Cache.Free;
    Seen.Free;
    Parents.Free;
  end;
end;

destructor TS16Cartridge.Destroy;
begin
  FRegions.Free;
  inherited;
end;

function TS16Cartridge.GetRegion(const Name: string): TBytes;
begin
  if not FRegions.TryGetValue(Name, Result) then
    Result := nil;
end;

function TS16Cartridge.Identity: TBytes;
begin
  var Hash := THashSHA2.Create;
  Hash.Update(TEncoding.UTF8.GetBytes('System16:' + FSet.Name));
  for var R in FSet.Regions do
  begin
    Hash.Update(TEncoding.UTF8.GetBytes(R.Name));
    Hash.Update(GetRegion(R.Name));
  end;
  Result := Hash.HashAsBytes;
end;

end.

