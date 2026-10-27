unit Core.EmulatorFactory;

interface

uses
  System.Classes, System.SysUtils, Core.Storage, Core.Emulation;

function CreateEmulationCore(const FileName: string): IEmulationCore; overload;

// The caller owns Stream. Cartridges copy bytes; CD cores own separate track streams.
// RomName must retain the location for Neo Geo parent ZIPs and CD tracks/BIOS.
function CreateEmulationCore(Stream: TStream; const Storage: IStorage; const RomName: string = ''): IEmulationCore; overload;

implementation

uses
  Core.Adapter.PCE, PCE.Cartridge, Core.CD.Disc, Core.Adapter.GW, GW.Cartridge,
  Core.RomArchive, System.Zip, System.IOUtils, SG1000.Console, Core.RomFormat,
  Core.Adapter.SG1000, Core.Adapter.NES, Core.Adapter.GB, Core.Adapter.GBC,
  Core.Adapter.N64, Core.Adapter.MD, Core.Adapter.GBA, Core.Adapter.SNES,
  Core.Adapter.NeoGeo, NeoGeo.Cartridge, Core.Adapter.Saturn, Core.Adapter.NGP,
  Core.Adapter.CPS, CPS.RomSets, Core.Adapter.ZX, Core.Adapter.PS1,
  Core.Adapter.PSP, Core.PSP.Archive, PSP.Media, Core.Adapter.DC, DC.ELF,
  System.StrUtils, Core.Adapter.MSX, MSX.Machine, MSX.Cartridge, Core.Adapter.PS2, Core.DVD.Image;

// The first disc named by an M3U playlist (as written); restores the stream position.
function FirstPlaylistEntry(Stream: TStream): string;
begin
  Result := '';
  var Start := Stream.Position;
  try
    var Size := Stream.Size - Start;
    if Size > 64 * 1024 then
      Size := 64 * 1024;
    var Data: TBytes;
    SetLength(Data, Size);
    if Size > 0 then
      Stream.ReadBuffer(Data[0], Size);
    for var Line in TEncoding.UTF8.GetString(Data).Split([#13, #10]) do
    begin
      var Entry := Line.Trim;
      if (Entry = '') or Entry.StartsWith('#') then
        Continue;
      Exit(Entry.DeQuotedString('"'));
    end;
  finally
    Stream.Position := Start;
  end;
end;

function CreateEmulationCore(const FileName: string): IEmulationCore;
begin
  var Storage := TStorage.Default;
  var Stream := Storage.OpenRead(FileName);
  try
    Result := CreateEmulationCore(Stream, Storage, FileName);
  finally
    Stream.Free;
  end;
end;

function CreateEmulationCore(Stream: TStream; const Storage: IStorage; const RomName: string): IEmulationCore;
begin
  // Disc streams exceed cartridge limits; keep them on disk and read sectors.
  var SourceName := RomName;
  var MSXHint := -1;
  var FolderHint := RomName.ToLower.Replace('\', '/');
  if FolderHint.Contains('/msx1/') or FolderHint.Contains('/msx/') then MSXHint := Ord(MSX1);
  if FolderHint.Contains('/msx2/') then MSXHint := Ord(MSX2);
  if FolderHint.Contains('/msx2plus/') or FolderHint.Contains('/msx2+/') then MSXHint := Ord(MSX2Plus);
  if (Storage <> nil) and RomName.StartsWith('content://', True) then
    SourceName := Storage.Describe(RomName).Name;

  // PlayStation 2 DVD images may exceed what TCDDisc reads; ELF programs too.
  var PS2 := TPS2CoreAdapter.TryCreate(Stream, Storage, RomName, SourceName);
  if PS2 <> nil then
    Exit(PS2);

  // ELF is shared by PSP and Dreamcast; use the existing SH-4 header probe.
  if SameText(ExtractFileExt(SourceName), ROM_EXTENSION_ELF) then
  begin
    var SavedPosition := Stream.Position;
    var Header: TBytes;
    SetLength(Header, 52);
    try
      SetLength(Header, Stream.Read(Header[0], Length(Header)));
    finally
      Stream.Position := SavedPosition;
    end;
    if IsDCELF(Header) then
      Exit(TDCCoreAdapter.Create(Stream, Storage, RomName));
  end;

  // PSP executables and UMD must be dispatched before generic CD/cartridge
  // readers, whose sector assumptions and 64 MiB cartridge limit differ.
  if SameText(ExtractFileExt(SourceName), ROM_EXTENSION_PBP) or
    SameText(ExtractFileExt(SourceName), ROM_EXTENSION_ELF) or
    SameText(ExtractFileExt(SourceName), ROM_EXTENSION_PRX) or
    SameText(ExtractFileExt(SourceName), ROM_EXTENSION_CSO) then
    Exit(TPSPCoreAdapter.Create(Stream, Storage, RomName));
  if SameText(ExtractFileExt(SourceName), ROM_EXTENSION_ISO) and TPSPDisc.Recognizes(Stream) then
  begin
    var SavedPosition := Stream.Position;
    var PSPDisc := TPSPDisc.Create(Stream);
    try
      if PSPDisc.IsPSP then Exit(TPSPCoreAdapter.Create(Stream, Storage, RomName));
    finally
      PSPDisc.Free;
      Stream.Position := SavedPosition;
    end;
  end;
  if SameText(ExtractFileExt(SourceName), ROM_EXTENSION_ZIP) and IsPSPArchive(Stream) then
    Exit(TPSPCoreAdapter.Create(Stream, Storage, RomName));

  // GD-ROM and DiscJuggler images only hold Dreamcast discs.
  if SameText(ExtractFileExt(SourceName), ROM_EXTENSION_GDI) or
    SameText(ExtractFileExt(SourceName), ROM_EXTENSION_CDI) then
  begin
    var DiscStorage := Storage;
    if DiscStorage = nil then
      DiscStorage := TStorage.Default;
    var Disc := TCDDisc.Create(Stream, DiscStorage, RomName);
    try
      if not TDCCoreAdapter.IsDCDisc(Disc) then
        raise EReadError.Create('Not a Dreamcast disc: the boot track lacks the SEGA SEGAKATANA identifier');
    except
      Disc.Free;
      raise;
    end;
    Exit(TDCCoreAdapter.Create(Stream, DiscStorage, RomName, Disc));
  end;

  // Playlists: Dreamcast in its ROM folder or for GD-ROM/DiscJuggler images,
  // else PlayStation.
  if SameText(ExtractFileExt(SourceName), ROM_EXTENSION_M3U) then
  begin
    var PlaylistFolder := ExtractFileName(ExcludeTrailingPathDelimiter(ExtractFilePath(SourceName)));
    if SameText(PlaylistFolder, ROM_SYSTEM_DC) or SameText(PlaylistFolder, 'dreamcast') or
      MatchText(ExtractFileExt(FirstPlaylistEntry(Stream)), [ROM_EXTENSION_GDI, ROM_EXTENSION_CDI]) then
      Exit(TDCCoreAdapter.Create(Stream, Storage, RomName));
    Exit(TPS1CoreAdapter.Create(Stream, Storage, RomName));
  end;

  // A raw single-track .bin is a disc, not a cartridge (CD sync at sector 0).
  var RawDisc := SameText(ExtractFileExt(SourceName), ROM_EXTENSION_BIN) and IsCDRawImage(Stream);
  var ZipDisc := SameText(ExtractFileExt(SourceName), ROM_EXTENSION_ZIP) and TCDDisc.IsDiscZip(Stream);
  if SameText(ExtractFileExt(SourceName), ROM_EXTENSION_CUE) or
    SameText(ExtractFileExt(SourceName), ROM_EXTENSION_ISO) or
    SameText(ExtractFileExt(SourceName), ROM_EXTENSION_CHD) or
    SameText(ExtractFileExt(SourceName), ROM_EXTENSION_MDS) or
    SameText(ExtractFileExt(SourceName), ROM_EXTENSION_NRG) or RawDisc or ZipDisc then
  begin
    // A location is only a hint. Confirm the native NEC boot string in the first
    // data track so generic .cue/.iso/.chd still select the correct CD family.
    var DiscStorage := Storage;
    if DiscStorage = nil then
      DiscStorage := TStorage.Default;
    var Disc := TCDDisc.Create(Stream, DiscStorage, RomName);
    var IsPCE := False;
    var IsSegaCD := False;
    var IsSaturn := False;
    try
      if TDCCoreAdapter.IsDCDisc(Disc) then
      begin
        var OwnedDisc := Disc;
        Disc := nil;
        Exit(TDCCoreAdapter.Create(Stream, DiscStorage, RomName, OwnedDisc));
      end;
      for var T := 1 to Disc.TrackCount do
      begin
        var Track := Disc.Track(T);
        if Track.Audio then
          Continue;

        // The IPL information block and NEC identifier occupy the second
        // data sector; the first sector contains the bootstrap program.
        for var Offset := 0 to 1 do
        begin
          if not Disc.IsData(Track.StartLBA + Offset) then
            Break;

          var Sector: TBytes;
          Disc.ReadData(Track.StartLBA + Offset, Sector);
          if Offset = 0 then
          begin
            IsSegaCD := TEncoding.ASCII.GetString(Sector, 0, 14) = 'SEGADISCSYSTEM';
            IsSaturn := TEncoding.ASCII.GetString(Sector, 0, 16) = 'SEGA SEGASATURN ';
          end;
          IsPCE := TEncoding.ASCII.GetString(Sector).Contains('PC Engine CD-ROM SYSTEM');
          if IsPCE then
            Break;
        end;

        Break;
      end;
      var Folder := ExtractFileName(ExcludeTrailingPathDelimiter(ExtractFilePath(SourceName)));
      if IsSaturn then
      begin
        var OwnedDisc := Disc;
        Disc := nil;
        Exit(TSaturnCoreAdapter.Create(Stream, DiscStorage, RomName, OwnedDisc));
      end;
      if IsSegaCD then
      begin
        Stream.Position := 0;
        Exit(TMDCoreAdapter.Create(Stream, Storage, RomName, True));
      end;
      // PS2 CDs name their executable with BOOT2 (PS1 detection would take them).
      if not IsPCE and TPS2CoreAdapter.IsPS2CD(Disc) then
      begin
        var OwnedDisc := Disc;
        Disc := nil;
        Exit(TPS2CoreAdapter.Create(Stream, DiscStorage, RomName, TDVDCDImage.Create(OwnedDisc, True)));
      end;
      if not IsPCE and TPS1CoreAdapter.IsPS1Disc(Disc) then
      begin
        var OwnedDisc := Disc;
        Disc := nil;
        Exit(TPS1CoreAdapter.Create(Stream, DiscStorage, RomName, OwnedDisc));
      end;
      if IsPCE or SameText(Folder, 'pcecd') or SameText(Folder, 'pcenginecd') then
      begin
        var OwnedDisc := Disc;
        Disc := nil;
        Exit(TPCECoreAdapter.Create(Stream, Storage, RomName, OwnedDisc));
      end;
    finally
      Disc.Free;
    end;
    Stream.Position := 0;
    Exit(TNeoGeoCoreAdapter.Create(Stream, Storage, RomName, True));
  end;

  if SameText(ExtractFileExt(SourceName), '.mmc') or SameText(ExtractFileExt(SourceName), '.ide') then
    Exit(TZXCoreAdapter.Create(Stream, Storage, RomName, SourceName));

  var Data := ReadNeoGeoData(Stream);
  var IsSevenZip := SameText(ExtractFileExt(SourceName), ROM_EXTENSION_7Z);
  if IsSevenZip then
  begin
    Data := SevenZipAsZip(Data);
    SourceName := ChangeFileExt(SourceName, ROM_EXTENSION_ZIP);
  end;
  if TGWCartridge.Recognizes(Data, SourceName) then
  begin
    var GWStream := TBytesStream.Create(Data);
    try
      Result := TGWCoreAdapter.Create(GWStream, Storage, RomName);
    finally
      GWStream.Free;
    end;
    Exit;
  end;

  if SameText(ExtractFileExt(SourceName), ROM_EXTENSION_ZIP) then
  begin
    var CPSStream := TBytesStream.Create(Data);
    try
      var CPSSet: TCPSRomSet;
      if TCPSRomSet.IdentifyStream(CPSStream, SourceName, CPSSet) then
      begin
        CPSStream.Position := 0;
        Exit(TCPSCoreAdapter.Create(CPSStream, Storage, SourceName));
      end;
    finally
      CPSStream.Free;
    end;
    var ArchiveStream := TBytesStream.Create(Data);
    var Archive := TZipFile.Create;
    try
      Archive.Open(ArchiveStream, TZipMode.zmRead);
      var Candidate := -1;

      for var i := 0 to Archive.FileCount - 1 do
      begin
        var Name := Archive.FileNames[i];
        if Name.Contains('__MACOSX/') or ExtractFileName(Name).StartsWith('._') then
          Continue;

        var BinaryCartridge := False;
        if MatchText(ExtractFileExt(Name), ['.bin', '.rom']) and
          (Archive.FileInfo[i].UncompressedSize <= ROM_MAX_SIZE) then
        begin
          var Probe: TBytes;
          Archive.Read(i, Probe);
          var ProbeFormat := DetectRom(Probe);
          BinaryCartridge := not (ProbeFormat.System in [TRomSystem.Unknown, TRomSystem.NeoGeo]);
        end;
        var MSXEntry := (MSXHint >= 0) and MatchText(ExtractFileExt(Name), ['.rom','.wav']);
        if CartridgeArchiveEntry(Name, Archive.FileInfo[i].UncompressedSize) or BinaryCartridge or MSXEntry then
        begin
          if Candidate >= 0 then
          begin
            if not IsSevenZip and (MSXHint < 0) then
            begin
              var OldName := Archive.FileNames[Candidate];
              var NewDisk := SameText(ExtractFileExt(Name), '.trd') or SameText(ExtractFileExt(Name), '.scl') or SameText(ExtractFileExt(Name), '.dsk');
              var OldDisk := SameText(ExtractFileExt(OldName), '.trd') or SameText(ExtractFileExt(OldName), '.scl') or SameText(ExtractFileExt(OldName), '.dsk');
              if IsZXImageName(Name) and IsZXImageName(OldName) and (NewDisk or OldDisk) then
              begin
                if OldDisk and not NewDisk then
                  Continue;
                if NewDisk and not OldDisk then
                begin
                  Candidate := i;
                  Continue;
                end;
                if SameText(ExtractFileExt(OldName), '.trd') and SameText(ExtractFileExt(Name), '.scl') then
                  Continue;
                if SameText(ExtractFileExt(Name), '.trd') and SameText(ExtractFileExt(OldName), '.scl') then
                begin
                  Candidate := i;
                  Continue;
                end;
              end;
              raise EReadError.Create('Cartridge ZIP must contain one cartridge or disk image');
            end;
            var Score := CartridgeVariantScore(Name);
            var Previous := CartridgeVariantScore(Archive.FileNames[Candidate]);
            if (Score < Previous) or ((Score = Previous) and
              (CompareText(Name, Archive.FileNames[Candidate]) >= 0)) then
              Continue;
          end;

          Candidate := i;
        end;
      end;
      if Candidate >= 0 then
      begin
        if Archive.FileInfo[Candidate].UncompressedSize > ROM_MAX_SIZE then
          raise EReadError.Create('Cartridge archive image exceeds 64 MiB');

        SourceName := Archive.FileNames[Candidate];
        if SourceName.ToLower.Contains('initial program loader') then
          SourceName := ChangeFileExt(SourceName, '.sf7');
        Archive.Read(Candidate, Data);
      end;
    finally
      Archive.Free;
      ArchiveStream.Free;
    end;
  end;

  if SameText(ExtractFileExt(SourceName), '.mx1') and (MSXHint < 0) then MSXHint := Ord(MSX1);
  if SameText(ExtractFileExt(SourceName), '.mx2') and (MSXHint < 0) then MSXHint := Ord(MSX2);
  if SameText(ExtractFileExt(SourceName), '.mxp') then MSXHint := Ord(MSX2Plus);
  if SameText(ExtractFileExt(SourceName),'.cas') then
  begin
    if MSXHint<0 then MSXHint:=Ord(MSX1);
    Exit(TMSXCoreAdapter.Create(Data,TMSXModel(MSXHint),Storage,RomName,CASMedia));
  end;
  if (MSXHint>=0) and SameText(ExtractFileExt(SourceName),'.wav') then
    Exit(TMSXCoreAdapter.Create(Data,TMSXModel(MSXHint),Storage,RomName,WAVMedia));
  var MSXDisk:=SameText(ExtractFileExt(SourceName),'.dsk') and (MSXHint>=0);
  // Outside a system folder, only claim a raw FAT image with a valid MSX BPB.
  // CPC containers and the historic SF-7000 160 KiB dispatch keep their paths.
  if SameText(ExtractFileExt(SourceName),'.dsk') and (MSXHint<0) and
    (Length(Data)>=320*1024) and (Length(Data)<=86*2*9*512) and
    ((Data[0]=$EB) or (Data[0]=$E9)) and (Data[11]=0) and (Data[12]=2) and
    (Data[24] in [8,9]) and (Data[25]=0) and (Data[26] in [1,2]) and (Data[27]=0) and
    (Length(Data) mod (512*Data[24]*Data[26])=0) then
  begin MSXDisk:=True; MSXHint:=Ord(MSX2);end;
  if MSXDisk then Exit(TMSXCoreAdapter.Create(Data,TMSXModel(MSXHint),Storage,RomName,DiskMedia));
  if (MSXHint >= 0) and
    (TMSXCartridge.Recognizes(Data) or MatchText(ExtractFileExt(SourceName), ['.rom', '.mx1', '.mx2', '.mxp'])) then
    Exit(TMSXCoreAdapter.Create(Data, TMSXModel(MSXHint), Storage, RomName));

  if SameText(ExtractFileExt(SourceName), ROM_EXTENSION_PCE) or
    SameText(ExtractFileExt(SourceName), ROM_EXTENSION_SGX) then
  begin
    var InputPCE := TBytesStream.Create(Data);
    try
      Result := TPCECoreAdapter.Create(InputPCE, Storage, RomName, nil, SourceName);
    finally
      InputPCE.Free;
    end;
    Exit;
  end;

  // DSK is shared with SF-7000. Raw 160 KiB media and an explicit Sega path
  // retain their historical dispatch; other CPC DSK containers default to +3.
  var DSKContainer := (Length(Data) >= 256) and
    ((TEncoding.ASCII.GetString(Data, 0, 20) = 'EXTENDED CPC DSK File') or
    (TEncoding.ASCII.GetString(Data, 0, 20) = 'MV - CPCEMU Disk-File'));
  var SegaDisk := SameText(ExtractFileExt(SourceName), '.dsk') and
    (((Length(Data) = 163840) and not DSKContainer) or
    ((Length(Data) >= 512) and DSKContainer and (Data[$30] = 40) and (Data[$31] = 1) and
    (Data[256 + $14] = 1) and (Data[256 + $15] = 16)) or
    RomName.ToLower.Replace('\', '/').Contains('/sf7000/') or
    RomName.ToLower.Replace('\', '/').Contains('/sg1000/') or
    RomName.ToLower.Contains('(sf-7000)') or RomName.ToLower.Contains('initial program loader'));
  if IsZXImageName(SourceName) and not SegaDisk then
  begin
    Result := TZXCoreAdapter.CreateOwned(Data, Storage, RomName, SourceName);
    Exit;
  end;

  var Format := DetectRom(Data);

  // These cartridges have no mandatory signature. A supplied extension is the
  // explicit platform hint; arbitrary unrecognized .bin files stay rejected.
  if SameText(ExtractFileExt(SourceName), ROM_EXTENSION_SG) or
    ((Format.System = TRomSystem.Unknown) and (Length(Data) <= $C000) and
    SameText(ExtractFileExt(SourceName), ROM_EXTENSION_SMS) and
    (SourceName.Contains('(SG-1000)') or
    SameText(ExtractFileName(ExcludeTrailingPathDelimiter(ExtractFilePath(SourceName))), ROM_SYSTEM_SG1000))) then
  begin
    Format.System := TRomSystem.SG1000;
    Format.Encoding := TRomEncoding.Native;
  end
  else if SameText(ExtractFileExt(SourceName), ROM_EXTENSION_SC) then
  begin
    Format.System := TRomSystem.SC3000;
    Format.Encoding := TRomEncoding.Native;
  end
  else if SameText(ExtractFileExt(SourceName), ROM_EXTENSION_SF7) or
    SameText(ExtractFileExt(SourceName), ROM_EXTENSION_SF) or SameText(ExtractFileExt(SourceName), ROM_EXTENSION_DSK) then
    Format.System := TRomSystem.SF7000
  else if SameText(ExtractFileExt(SourceName), ROM_EXTENSION_MV) then
    Format.System := TRomSystem.Multivision
  else if SameText(ExtractFileExt(SourceName), ROM_EXTENSION_SMS) then
    Format.System := TRomSystem.SMS
  else if SameText(ExtractFileExt(SourceName), ROM_EXTENSION_GG) then
    Format.System := TRomSystem.GameGear;
  if (Format.System = TRomSystem.Unknown) and SameText(ExtractFileExt(SourceName), ROM_EXTENSION_GBA) then
    Format.System := TRomSystem.GBA;
  if (Format.System <> TRomSystem.NeoGeo) and (Length(Data) > ROM_MAX_SIZE) then
    raise EReadError.Create('ROM exceeds 64 MiB');

  if Format.System = TRomSystem.Unknown then
    raise EReadError.Create('Unrecognized ROM header (NES, Game Boy, Game Boy Color, Game Boy Advance, Mega Drive, SNES, Nintendo 64, Neo Geo or Neo Geo Pocket expected; use .sg/.sc for SG-1000/SC-3000)');

  Data := NormalizeRom(Data, Format);
  var Input := TBytesStream.Create(Data);
  try
    case Format.System of
      TRomSystem.MSX1:
        Result := TMSXCoreAdapter.Create(Data, MSX1, Storage, RomName);
      TRomSystem.MSX2:
        Result := TMSXCoreAdapter.Create(Data, MSX2, Storage, RomName);
      TRomSystem.MSX2Plus:
        Result := TMSXCoreAdapter.Create(Data, MSX2Plus, Storage, RomName);
      TRomSystem.SG1000, TRomSystem.SC3000:
        Result := TSGCoreAdapter.Create(Input, Storage, RomName, Format.System = TRomSystem.SC3000);
      TRomSystem.SF7000:
        Result := TSGCoreAdapter.Create(Input, Storage, RomName, True, Ord(TSGModel.SF7000));
      TRomSystem.Multivision:
        Result := TSGCoreAdapter.Create(Input, Storage, RomName, False, Ord(TSGModel.Multivision));
      TRomSystem.SMS:
        Result := TSGCoreAdapter.Create(Input, Storage, RomName, False, Ord(TSGModel.MasterSystem));
      TRomSystem.GameGear:
        Result := TSGCoreAdapter.Create(Input, Storage, RomName, False, Ord(TSGModel.GameGear));
      TRomSystem.N64:
        Result := TN64CoreAdapter.Create(Input, Storage, RomName);
      TRomSystem.NeoGeo:
        Result := TNeoGeoCoreAdapter.Create(Input, Storage, RomName);
      TRomSystem.NeoGeoPocket, TRomSystem.NeoGeoPocketColor:
        Result := TNGPCoreAdapter.Create(Input, Storage, RomName);
      TRomSystem.NES:
        Result := TNesCoreAdapter.Create(Input, Storage, RomName);
      TRomSystem.GB:
        Result := TGBCoreAdapter.Create(Input, Storage, RomName);
      TRomSystem.GBC:
        Result := TGBCCoreAdapter.Create(Input, Storage, RomName);
      TRomSystem.GBA:
        Result := TGBACoreAdapter.Create(Input, Storage, RomName);
      TRomSystem.MD:
        Result := TMDCoreAdapter.Create(Input, Storage, RomName);
      TRomSystem.Saturn:
        Result := TSaturnCoreAdapter.Create(Input, Storage, RomName);
      TRomSystem.PS1:
        Result := TPS1CoreAdapter.Create(Input, Storage, RomName);
      TRomSystem.DC:
        Result := TDCCoreAdapter.Create(Input, Storage, RomName);
      TRomSystem.SNES:
        Result := TSnesCoreAdapter.Create(Input, Storage, RomName);
    end;
  finally
    Input.Free;
  end;
end;

end.

