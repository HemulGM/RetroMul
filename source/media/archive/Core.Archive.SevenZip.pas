unit Core.Archive.SevenZip;

interface

uses
  System.SysUtils;

// Bridges the file-based native 7z reader to existing stream-based ZIP consumers.
// Names remain archive metadata and are never used as filesystem paths.
function SevenZipAsZip(const Data: TBytes): TBytes;

implementation

uses
  System.Classes, System.IOUtils, System.Zip, System.StrUtils, Z7.Archive;

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
        if (Entry.Size < 0) or (Entry.Size > 256 * 1024 * 1024 - Total) then
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

