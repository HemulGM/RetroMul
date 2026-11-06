unit Core.Platforms.PSP.Archive;

interface

uses
  System.Classes, Core.Archive.Container, Core.Storage, PSP.Media;

// Recognition inspects a 4 MiB ISO prefix; readers may cache the full member.
// Disc extraction streams to storage's temporary area. Homebrew retains the
// container so the PSP can open neighboring modules and resources on demand.
function IsPSPArchive(const Archive: IArchiveContainer): Boolean;

function ReadPSPArchive(const Archive: IArchiveContainer; const Storage: IStorage; KeepMedia: Boolean = False): TPSPProgram;

implementation

uses
  System.SysUtils;

function Candidate(Archive: IArchiveContainer): Integer;
begin
  Result := -1;
  if Archive = nil then
    Exit;
  var Count := 0;
  var Boot := -1;
  var BootDepth := MaxInt;
  var BootTied := False;
  var HasDisc := False;
  for var i := 0 to Archive.Count - 1 do
  begin
    if Archive.Entries[i].IsDirectory then
      Continue;
    var Name := Archive.Entries[i].Name.Replace('\', '/');
    if Name.Contains('__MACOSX/') or ExtractFileName(Name).StartsWith('._') then
      Continue;
    var Ext := ExtractFileExt(Name).ToLower;
    if (Ext <> '.iso') and (Ext <> '.cso') and (Ext <> '.pbp') and (Ext <> '.elf') and (Ext <> '.prx') then
      Continue;
    Inc(Count);
    HasDisc := HasDisc or (Ext = '.iso') or (Ext = '.cso');
    if SameText(Name.Substring(Name.LastIndexOf('/') + 1), 'EBOOT.PBP') then
    begin
      var Depth := Length(Name.Split(['/']));
      if Depth < BootDepth then
      begin
        Boot := i;
        BootDepth := Depth;
        BootTied := False;
      end
      else if Depth = BootDepth then
        BootTied := True;
    end;
    Result := i;
  end;
  if Count > 1 then
    if (Boot >= 0) and not BootTied and not HasDisc then
      Result := Boot
    else
      Result := -1; // Unrelated programs/discs retain factory handling.
end;

function IsPSPArchive(const Archive: IArchiveContainer): Boolean;
begin
  Result := False;
  begin
    var Index := Candidate(Archive);
    if Index < 0 then
      Exit;
    var Ext := ExtractFileExt(Archive.Entries[Index].Name).ToLower;
    if (Ext <> '.iso') and (Ext <> '.elf') then
      Exit(True);
    var Input: TStream;
    Input := Archive.OpenRead(Index);
    try
      var N := Archive.Entries[Index].Size;
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
  end;
end;

function ReadPSPArchive(const Archive: IArchiveContainer; const Storage: IStorage; KeepMedia: Boolean): TPSPProgram;
begin
  if Archive = nil then
    raise EArgumentNilException.Create('Archive');
  if Storage = nil then
    raise EArgumentNilException.Create('Storage');
  var Temporary := '';
  var Retained := False;
  var Completed := False;
  try
    var Index := Candidate(Archive);
    if Index < 0 then
      raise EPSPFormat.Create('PSP: Archive has no unambiguous boot image (ISO, CSO, PBP, ELF or PRX)');
    var Size := Archive.Entries[Index].Size;
    if (Size < 4) or (Size > UInt64(4) * 1024 * 1024 * 1024) then
      raise EPSPFormat.Create('PSP: Archive image size exceeds 4 GiB');
    Temporary := Storage.TemporaryFile('.psp-image');
    var Output := Storage.OpenWrite(Temporary);
    try
      var Input: TStream;
      Input := Archive.OpenRead(Index);
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
          raise EPSPFormat.Create('PSP: Archive entry exceeds its declared size');
      finally
        Input.Free;
      end;
    finally
      Output.Free;
    end;
    var Image := Storage.OpenRead(Temporary);
    try
      Result := TPSPProgram.Read(Image);
      if not TPSPDisc.Recognizes(Image) then
        Result.AttachArchive(Archive, Archive.Entries[Index].Name);
      if KeepMedia and TPSPDisc.Recognizes(Image) then
      begin
        Result.MediaPath := Temporary;
        Result.TemporaryMedia := True;
        Retained := True;
      end;
    finally
      Image.Free;
    end;
    Completed := True;
  finally
    if not Retained and (Temporary <> '') and Storage.Exists(Temporary) then
    try
      Storage.Delete(Temporary);
    except
      if Completed then
        raise;
    end;
  end;
end;

end.

