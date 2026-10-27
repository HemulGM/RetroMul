unit Core.RomArchive;

interface

uses
  System.SysUtils;

// Bridges the file-based native 7z reader to existing stream-based ZIP consumers.
// Names remain archive metadata and are never used as filesystem paths.
function SevenZipAsZip(const Data: TBytes): TBytes;

function CartridgeArchiveEntry(const Name: string; Size: Int64): Boolean;

function CartridgeVariantScore(const Name: string): Integer;

implementation

uses
  System.Classes, System.IOUtils, System.Zip, System.StrUtils, Z7.Archive,
  Core.RomFormat;

function CartridgeArchiveEntry(const Name: string; Size: Int64): Boolean;
begin
  var Ext := ExtractFileExt(Name).ToLower;
  Result := not Name.Contains('__MACOSX/') and
    not ExtractFileName(Name).StartsWith('._') and
    MatchText(Ext, ['.sna', '.z80', '.tap', '.tzx', '.trd', '.scl', '.pro', '.kdi', '.ngp',
        '.ngc', '.pce', '.sgx', '.sg', '.sc', '.sf7', '.sf', '.dsk',
        '.mx1', '.mx2', '.mxp', '.cas', '.mv', '.sms', '.gg', '.nes', '.gb', '.gbc', '.gbx', '.gba', '.exe', '.sfc', '.smc', '.swc',
        '.fig', '.z64', '.n64', '.v64', '.smd', '.gen', '.md', '.32x', '.neo', '.gw', '.mgw']);
  Result := Result or ((Ext = '.bin') and (Size = $2000) and Name.ToLower.Contains('initial program loader'));
end;

function CartridgeVariantScore(const Name: string): Integer;
begin
  var S := Name.ToLower;
  Result := 0;
  if S.Contains('[!]') then
    Inc(Result, 30);
  if S.Contains('(world)') or S.Contains('(europe)') or S.Contains('(usa)') or
    S.Contains('(ue)') or S.Contains('(u)') or S.Contains('(e)') or S.Contains('(jue)') or S.Contains('(en') then
    Inc(Result, 20);
  if S.Contains('[a') or S.Contains('[b') or S.Contains('[h') or S.Contains('[o') or
    S.Contains('[t') or S.Contains('(beta') or S.Contains('(proto') or
    S.Contains('(demo') then
    Dec(Result, 100);
end;

function SevenZipAsZip(const Data: TBytes): TBytes;
begin
  var TempName := TPath.GetTempFileName;
  try
    TFile.WriteAllBytes(TempName, Data);
    var Archive := TSevenZipArchive.Create(TempName);
    try
      var Entries := Archive.Entries;
      var Total: Int64 := 0;
      for var Entry in Entries do
      begin
        if (Entry.Size < 0) or (Entry.Size > NEOGEO_ROM_MAX_CONTAINER_SIZE - Total) then
          raise EReadError.Create('7z unpacked data exceeds 256 MiB');

        Inc(Total, Entry.Size);
      end;
      var Output := TBytesStream.Create;
      try
        var Zip := TZipFile.Create;
        try
          Zip.Open(Output, zmWrite);
          for var i := 0 to High(Entries) do
          begin
            if Entries[i].IsDirectory then
              Continue;

            var Item := TMemoryStream.Create;
            try
              Archive.Extract(i, Item);
              Item.Position := 0;
              Zip.Add(Item, Entries[i].Name, zcStored);
            finally
              Item.Free;
            end;
          end;
          Zip.Close;
          SetLength(Result, Output.Size);
          if Output.Size > 0 then
            Move(Output.Bytes[0], Result[0], Output.Size);
        finally
          Zip.Free;
        end;
      finally
        Output.Free;
      end;
    finally
      Archive.Free;
    end;
  finally
    TFile.Delete(TempName);
  end;
end;

end.

