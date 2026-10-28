unit Core.Platforms.PSP.Archive;

interface

uses
  System.Classes, Core.Storage, PSP.Media;

// ZIP recognition reads at most a 4 MiB ISO prefix. Full extraction streams to
// storage's temporary area, with cancellation, a size cap and cleanup on error.
function IsPSPArchive(Stream: TStream): Boolean;

function ReadPSPArchive(Stream: TStream; const Storage: IStorage; KeepMedia: Boolean = False): TPSPProgram;

implementation

uses
  System.SysUtils, System.Zip;

function Candidate(Archive: TZipFile): Integer;
begin
  Result := -1;
  for var I := 0 to Archive.FileCount - 1 do
  begin
    var Name := Archive.FileNames[I];
    if Name.Contains('__MACOSX/') or ExtractFileName(Name).StartsWith('._') then
      Continue;
    var Ext := ExtractFileExt(Name).ToLower;
    if (Ext <> '.iso') and (Ext <> '.cso') and (Ext <> '.pbp') and (Ext <> '.elf') and (Ext <> '.prx') then
      Continue;
    if Result >= 0 then
      Exit(-1); // Ambiguous sets retain existing factory handling.
    Result := I;
  end;
end;

function IsPSPArchive(Stream: TStream): Boolean;
begin
  Result := False;
  var Saved := Stream.Position;
  var Archive := TZipFile.Create;
  try
    Archive.Open(Stream, zmRead);
    var Index := Candidate(Archive);
    if Index < 0 then
      Exit;
    var Ext := ExtractFileExt(Archive.FileNames[Index]).ToLower;
    if (Ext <> '.iso') and (Ext <> '.elf') then
      Exit(True);
    var Header: TZipHeader;
    var Input: TStream;
    Archive.Read(Index, Input, Header);
    try
      var N := Archive.FileInfo[Index].UncompressedSize64;
      if N > 4 * 1024 * 1024 then
        N := 4 * 1024 * 1024;
      var Prefix: TBytes;
      SetLength(Prefix, N);
      if N <> 0 then
        Input.ReadBuffer(Prefix[0], Length(Prefix));
      if Ext = '.elf' then
      begin
        // SH-4 ELF belongs to Dreamcast; MIPS and malformed PSP files keep
        // the executable loader's existing validation/error reporting.
        Exit(not ((Length(Prefix) >= 20) and (Prefix[0] = $7F) and
          (Prefix[1] = Ord('E')) and (Prefix[2] = Ord('L')) and (Prefix[3] = Ord('F')) and
          (Prefix[18] = 42) and (Prefix[19] = 0)));
      end;
      var Probe := TBytesStream.Create(Prefix);
      try
        if not TPSPDisc.Recognizes(Probe) then
          Exit;
        try
          var Disc := TPSPDisc.Create(Probe);
          try
            Result := Disc.IsPSP;
          finally
            Disc.Free;
          end;
        except
          on E: EPSPFormat do
            Result := False;
        end;
      finally
        Probe.Free;
      end;
    finally
      Input.Free;
    end;
  finally
    Archive.Free;
    Stream.Position := Saved;
  end;
end;

function ReadPSPArchive(Stream: TStream; const Storage: IStorage; KeepMedia: Boolean): TPSPProgram;
begin
  var Saved := Stream.Position;
  var Archive := TZipFile.Create;
  var Temporary := '';
  var Retained := False;
  try
    Archive.Open(Stream, zmRead);
    var Index := Candidate(Archive);
    if Index < 0 then
      raise EPSPFormat.Create('PSP: ZIP must contain exactly one ISO, CSO, PBP or ELF');
    var Size := Archive.FileInfo[Index].UncompressedSize64;
    if (Size < 4) or (Size > UInt64(4) * 1024 * 1024 * 1024) then
      raise EPSPFormat.Create('PSP: ZIP image size exceeds 4 GiB');
    Temporary := Storage.TemporaryFile('.psp-image');
    var Output := Storage.OpenWrite(Temporary);
    try
      var Header: TZipHeader;
      var Input: TStream;
      Archive.Read(Index, Input, Header, True);
      try
        var Buffer: TBytes;
        SetLength(Buffer, 1024 * 1024);
        var Remaining := Size;
        while Remaining <> 0 do
        begin
          TStorage.CheckReadCancelled;
          var N := Length(Buffer);
          if Remaining < UInt64(N) then
            N := Remaining;
          Input.ReadBuffer(Buffer[0], N);
          Output.WriteBuffer(Buffer[0], N);
          Dec(Remaining, N);
        end;
        var Extra: Byte;
        if Input.Read(Extra, 1) <> 0 then
          raise EPSPFormat.Create('PSP: ZIP entry exceeds its declared size');
      finally
        Input.Free;
      end;
    finally
      Output.Free;
    end;
    var Image := Storage.OpenRead(Temporary);
    try
      Result := TPSPProgram.Read(Image);
      if KeepMedia and TPSPDisc.Recognizes(Image) then
      begin
        Result.MediaPath := Temporary;
        Result.TemporaryMedia := True;
        Retained := True;
      end;
    finally
      Image.Free;
    end;
  finally
    try
      if not Retained and (Temporary <> '') and Storage.Exists(Temporary) then
        Storage.Delete(Temporary);
    finally
      Archive.Free;
      Stream.Position := Saved;
    end;
  end;
end;

end.

