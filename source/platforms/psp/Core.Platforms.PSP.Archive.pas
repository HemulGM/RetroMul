unit Core.Platforms.PSP.Archive;

interface

uses
  System.Classes, Core.Archive.Container, Core.Storage, PSP.Media;

// Recognition inspects a 4 MiB ISO prefix; readers may cache the full member.
// The container retains disc members and supplies neighboring homebrew files.
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
  var Index := Candidate(Archive);
  if Index < 0 then
    raise EPSPFormat.Create('PSP: Archive has no unambiguous boot image (ISO, CSO, PBP, ELF or PRX)');
  var Size := Archive.Entries[Index].Size;
  if (Size < 4) or (Size > UInt64(4) * 1024 * 1024 * 1024) then
    raise EPSPFormat.Create('PSP: Archive image size exceeds 4 GiB');
  // The archive owns a validated, seekable copy of each opened member.
  var Input := Archive.OpenRead(Index);
  try
    var IsDisc := TPSPDisc.Recognizes(Input);
    Result := TPSPProgram.Read(Input);
    if not IsDisc then
      Result.AttachArchive(Archive, Archive.Entries[Index].Name)
    else if KeepMedia then
    begin
      Result.DiscArchive := Archive;
      Result.DiscEntry := Index;
    end;
  finally
    Input.Free;
  end;
end;

end.
