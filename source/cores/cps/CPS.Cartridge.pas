unit CPS.Cartridge;

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections, CPS.RomSets,
  Core.Storage;

type
  ECPSRom = class(EReadError);

  TCPSCartridge = class
  private
    FSet: TCPSRomSet;
    FRegions: TDictionary<string, TBytes>;
    function GetRegion(const Name: string): TBytes;
  public
    constructor Create(Stream: TStream; const Name: string; const Storage: IStorage = nil);
    destructor Destroy; override;
    property RomSet: TCPSRomSet read FSet;
    property Regions[const Name: string]: TBytes read GetRegion; default;
    function HasRegion(const Name: string): Boolean;
    function Identity: TBytes;
  end;

function CPSCRC32(const Data: TBytes): Cardinal;

implementation

uses
  Core.Archive.Container, System.Hash, Core.MediaArchive;

var
  CRCTable: array[0..255] of Cardinal;

function CPSCRC32(const Data: TBytes): Cardinal;
begin
  Result := $FFFFFFFF;
  for var B in Data do
    Result := (Result shr 8) xor CRCTable[(Result xor B) and $FF];
  Result := Result xor $FFFFFFFF;
end;

constructor TCPSCartridge.Create(Stream: TStream; const Name: string; const Storage: IStorage);
var
  S: IStorage;
  Parents: TList<IArchiveContainer>;

  procedure OpenSibling(const BaseName: string);
  begin
    var Path := FindMediaArchive(S, IncludeTrailingPathDelimiter(ExtractFilePath(
          StringReplace(Name, '/', PathDelim, [rfReplaceAll]))) + BaseName);
    if Path = '' then
      Exit;
    var Input := S.OpenRead(Path);
    try
      Parents.Add(OpenMediaArchive(Input, Path, S));
    finally
      Input.Free;
    end;
  end;

begin
  inherited Create;
  FRegions := TDictionary<string, TBytes>.Create;
  var Archive: IArchiveContainer;
  var Cache := TDictionary<Cardinal, TBytes>.Create;
  S := Storage;
  if S = nil then
    S := TStorage.Default;
  Parents := TList<IArchiveContainer>.Create;
  try
    Archive := OpenMediaArchive(Stream, Name, S);
    if not TCPSRomSet.Identify(Archive, Name, FSet) then
      raise ECPSRom.Create('Unrecognized CPS ROM set: ' + Name);

    // Resolve declared parent archives beside the selected archive. Content still
    // receives the exact same size and actual CRC validation as the child.
    var ParentName := FSet.Parent;
    if FSet.Machine = 'punipic' then
      OpenSibling('cps1pic');
    var Seen := TList<string>.Create;
    try
      while (ParentName <> '') and not Seen.Contains(ParentName) do
      begin
        Seen.Add(ParentName);
        OpenSibling(ParentName);
        var ParentSet: TCPSRomSet;
        if not TCPSRomSet.Find(ParentName, ParentSet) then
          Break;
        ParentName := ParentSet.Parent;
      end;
    finally
      Seen.Free;
    end;

    var Total: Int64 := 0;
    for var R in FSet.Regions do
    begin
      if (R.Size <= 0) or (R.Size > 128 * 1024 * 1024) then
        raise ECPSRom.Create('Invalid CPS region size: ' + R.Name);

      Inc(Total, R.Size);
      if Total > 256 * 1024 * 1024 then
        raise ECPSRom.Create('CPS ROM regions exceed 256 MiB');

      var Bytes: TBytes;
      SetLength(Bytes, R.Size);
      FillChar(Bytes[0], Length(Bytes), $FF);
      FRegions.Add(R.Name, Bytes);
      Bytes := nil;
    end;
    for var F in FSet.Files do
    begin
      if F.Name.StartsWith('#copy:') then
      begin
        var Source := FRegions[F.Name.Substring(6)];
        var Dest := FRegions[F.Region];
        if (F.Offset < 0) or (F.SourceOffset < 0) or (F.Size < 1) or
          (Int64(F.Offset) + F.Size > Length(Dest)) or
          (Int64(F.SourceOffset) + F.Size > Length(Source)) then
          raise ECPSRom.Create('Invalid CPS region copy');

        Move(Source[F.SourceOffset], Dest[F.Offset], F.Size);
        Continue;
      end;

      if F.FillValue >= 0 then
      begin
        var Dest := FRegions[F.Region];
        if (F.FillValue > 255) or (F.Size <= 0) or (F.Offset < 0) or (Int64(F.Offset) + F.Size > Length(Dest)) then
          raise ECPSRom.Create('Invalid CPS region fill');

        FillChar(Dest[F.Offset], F.Size, Byte(F.FillValue));
        Continue;
      end;

      var Bytes: TBytes;
      if not Cache.TryGetValue(F.CRC, Bytes) then
      begin
        var Index := -1;
        var SourceArchive := Archive;
        var SameName := -1;
        for var i := 0 to Archive.Count - 1 do
        begin
          if SameText(ExtractFileName(Archive.Entries[i].Name), F.Name) then
            SameName := i;
          if not Archive.Entries[i].IsDirectory and (Archive.Checksum(i) = F.CRC) then
            Index := i;
        end;
        if Index < 0 then
          for var ParentArchive in Parents do
          begin
            for var i := 0 to ParentArchive.Count - 1 do
              if not ParentArchive.Entries[i].IsDirectory and (ParentArchive.Checksum(i) = F.CRC) then
              begin
                SourceArchive := ParentArchive;
                Index := i;
                Break;
              end;

            if Index >= 0 then
              Break;
          end;

        if Index < 0 then
        begin
          if F.Region = 'timekeeper' then
          begin
            FRegions.Remove(F.Region);
            Continue;
          end;

          if (F.Region = 'key') and ((FSet.EncryptedBytes <> 0) or FSet.Machine.StartsWith('dead_cps2')) then
          begin
            FRegions.Remove('key');
            Continue;
          end;

          if SameName >= 0 then
            raise ECPSRom.CreateFmt('%s: CRC mismatch for %s (expected %.8x, archive %.8x)', [FSet.Name, F.Name, F.CRC, Archive.Checksum(SameName)]);

          raise ECPSRom.CreateFmt('%s: missing ROM %s (CRC %.8x). Supply the complete set or its parent archive beside it.', [FSet.Name, F.Name, F.CRC]);
        end;

        if SourceArchive.Entries[Index].Size > 64 * 1024 * 1024 then
          raise ECPSRom.Create('CPS ROM member exceeds 64 MiB');

        SourceArchive.Read(Index, Bytes);
        if CPSCRC32(Bytes) <> F.CRC then
          raise ECPSRom.Create('Corrupt CPS ROM content: ' + F.Name);

        Cache.Add(F.CRC, Bytes);
      end;
      var Dest := FRegions[F.Region];
      if (F.Size <= 0) or (F.SourceOffset < 0) or
        (Int64(F.SourceOffset) + F.Size > Length(Bytes)) or
        (F.Group < 1) or (F.Stride < F.Group) or (F.Size mod F.Group <> 0) or
        (F.Offset < 0) or
        (Int64(F.Offset) + Int64(F.Size div F.Group - 1) * F.Stride + F.Group > Length(Dest)) then
        raise ECPSRom.Create('Invalid CPS ROM wiring: ' + F.Name);

      for var i := 0 to F.Size - 1 do
      begin
        var Source := i;
        if F.Swap then
          Source := Source xor 1;
        Dest[F.Offset + (i div F.Group) * F.Stride + i mod F.Group] := Bytes[F.SourceOffset + Source];
      end;
    end;
  finally
    Cache.Free;
    Parents.Free;
    Archive := nil;
  end;
end;

destructor TCPSCartridge.Destroy;
begin
  FRegions.Free;
  inherited;
end;

function TCPSCartridge.GetRegion(const Name: string): TBytes;
begin
  if not FRegions.TryGetValue(Name, Result) then
    Result := nil;
end;

function TCPSCartridge.HasRegion(const Name: string): Boolean;
begin
  Result := FRegions.ContainsKey(Name);
end;

function TCPSCartridge.Identity: TBytes;
begin
  var Hash := THashSHA2.Create;
  Hash.Update(TEncoding.UTF8.GetBytes('CPS:' + FSet.Name));
  for var R in FSet.Regions do
  begin
    Hash.Update(TEncoding.UTF8.GetBytes(R.Name));
    Hash.Update(GetRegion(R.Name));
  end;
  Result := Hash.HashAsBytes;
end;

initialization
  for var i := 0 to 255 do
  begin
    var Value := Cardinal(i);
    for var J := 0 to 7 do
      if Odd(Value) then
        Value := (Value shr 1) xor $EDB88320
      else
        Value := Value shr 1;
    CRCTable[i] := Value;
  end;

end.

