unit NES.Cartridge;

interface

uses
  Core.Storage, System.Classes, System.SysUtils, NES.Types, NES.Mapper;

{$SCOPEDENUMS ON}

type
  TRomFormat = (Unknown, INES, NES20);

  TRomTiming = (Unknown, NTSC, PAL, MultiRegion, Dendy);

  TCartridgeMetadata = record
    Format: TRomFormat;
    Title: string;
    MapperId, Submapper: Integer;
    PrgRomSize, ChrRomSize: UInt64;
    PrgRamSize, PrgNvRamSize, ChrRamSize, ChrNvRamSize: UInt64;
    HasBattery, HasTrainer, LegacyHeaderDirty: Boolean;
    MirrorMode: TMirrorMode;
    Timing: TRomTiming;
    ConsoleType, ExtendedConsoleType, VsPpuType, VsHardwareType: Byte;
    MiscRomCount, DefaultExpansionDevice: Byte;
  end;

  TCartridge = class
  private
    FMapper: TMapper;
    FMapperId: Integer;
    FHeaderMapperId: Integer;
    FValid: Boolean;
    FMetadata: TCartridgeMetadata;
    FRomIdentity, FSaveFileName: string;
    FRomFileName: string;
    FSaveSize: Integer;
    FLastSaveMemory: TByteArray;
    FStorage: IStorage;
    procedure LoadBufferedRom(Stream: TStream; const RomName: string);
  public
    destructor Destroy; override;
    procedure LoadFromFile(const FileName: string);
    procedure LoadFromStream(Stream: TStream; const RomName: string = '');
    property Storage: IStorage read FStorage write FStorage;
    procedure Reset;
    procedure LoadBattery(const DirectoryName: string);
    procedure SaveBattery;
    property RomIdentity: string read FRomIdentity;
    property SaveFileName: string read FSaveFileName;
    property Mapper: TMapper read FMapper;
    property MapperId: Integer read FMapperId;
    property HeaderMapperId: Integer read FHeaderMapperId;
    property Valid: Boolean read FValid;
    property Metadata: TCartridgeMetadata read FMetadata;
  end;

implementation

uses
  Core.RomHashes, NES.RomMetadata, NES.Mapper.Factory, Core.SavePaths,
  Core.RomFormat, System.Hash,
  {$IFDEF MSWINDOWS}
  Winapi.Windows,
  {$ENDIF}
  {$IFDEF POSIX}
  Posix.Stdio, Posix.Unistd,
  {$ENDIF}
  System.IOUtils;

type
  TInesHeader = packed record
    Magic: array[0..3] of AnsiChar;
    PrgRomChunks: UInt8;
    ChrRomChunks: UInt8;
    Flags6: UInt8;
    Flags7: UInt8;
    PrgRamSize: UInt8;
    Flags9: UInt8;
    Flags10: UInt8;
    Zero: array[0..4] of UInt8;
  end;

procedure ReadExact(Stream: TStream; var Buffer; Count: Integer);
begin
  if Stream.Read(Buffer, Count) <> Count then
    raise ENesException.Create('Unexpected end of file');
end;

function RomSize(LowByte, HighNibble: Byte; UnitSize: Integer): UInt64;
begin
  if HighNibble <> $0F then
    Exit(UInt64(LowByte or (Integer(HighNibble) shl 8)) * UInt64(UnitSize));

  var Factor := UInt64((LowByte and 3) * 2 + 1);
  var Power := UInt64(1) shl (LowByte shr 2);
  if Power > High(UInt64) div Factor then
    raise ENesException.Create('ROM size overflows 64 bits');

  Result := Power * Factor;
end;

function RamSize(Shift: Byte): UInt64;
begin
  if Shift = 0 then
    Exit(0);

  Result := UInt64(64) shl Shift;
end;

function ParseMetadata(const Header: TInesHeader): TCartridgeMetadata;
begin
  Result := Default(TCartridgeMetadata);
  Result.Format := TRomFormat.INes;
  Result.HasBattery := (Header.Flags6 and 2) <> 0;
  Result.HasTrainer := (Header.Flags6 and 4) <> 0;
  if (Header.Flags6 and 8) <> 0 then
    Result.MirrorMode := TMirrorMode.FourScreen
  else if (Header.Flags6 and 1) <> 0 then
    Result.MirrorMode := TMirrorMode.Vertical
  else
    Result.MirrorMode := TMirrorMode.Horizontal;
  Result.MapperId := (Header.Flags7 and $F0) or (Header.Flags6 shr 4);
  Result.PrgRomSize := UInt64(Header.PrgRomChunks) * $4000;
  Result.ChrRomSize := UInt64(Header.ChrRomChunks) * $2000;
  if (Header.Flags7 and $0C) = $08 then
  begin
    Result.Format := TRomFormat.Nes20;
    Result.MapperId := Result.MapperId or ((Header.PrgRamSize and $0F) shl 8);
    Result.Submapper := Header.PrgRamSize shr 4;
    Result.PrgRomSize := RomSize(Header.PrgRomChunks, Header.Flags9 and $0F, $4000);
    Result.ChrRomSize := RomSize(Header.ChrRomChunks, Header.Flags9 shr 4, $2000);
    Result.PrgRamSize := RamSize(Header.Flags10 and $0F);
    Result.PrgNvRamSize := RamSize(Header.Flags10 shr 4);
    Result.ChrRamSize := RamSize(Header.Zero[0] and $0F);
    Result.ChrNvRamSize := RamSize(Header.Zero[0] shr 4);
    Result.Timing := TRomTiming(1 + (Header.Zero[1] and 3));
    Result.ConsoleType := Header.Flags7 and 3;
    if Result.ConsoleType = 1 then
    begin
      Result.VsPpuType := Header.Zero[2] and $0F;
      Result.VsHardwareType := Header.Zero[2] shr 4;
    end
    else if Result.ConsoleType = 3 then
      Result.ExtendedConsoleType := Header.Zero[2] and $0F;
    Result.MiscRomCount := Header.Zero[3] and 3;
    Result.DefaultExpansionDevice := Header.Zero[4] and $3F;
  end
  else
  begin
    Result.LegacyHeaderDirty := (Header.Zero[1] or Header.Zero[2] or Header.Zero[3] or Header.Zero[4]) <> 0;
    if Result.ChrRomSize = 0 then
      Result.ChrRamSize := $2000;
    if Result.LegacyHeaderDirty then
      Result.MapperId := Header.Flags6 shr 4
    else
    begin
      Result.ConsoleType := Header.Flags7 and 3;
      Result.Timing := TRomTiming(1 + (Header.Flags9 and 1));
      // iNES zero means an inferred 8 KiB, not an explicit absence of RAM.
      Result.PrgRamSize := UInt64(Header.PrgRamSize) * $2000;
      if Result.PrgRamSize = 0 then
        Result.PrgRamSize := $2000;
      if Result.HasBattery then
      begin
        Result.PrgNvRamSize := Result.PrgRamSize;
        Result.PrgRamSize := 0;
      end;
    end;
  end;
end;

function ReadRomTitle(Stream: TStream; const Metadata: TCartridgeMetadata): string;
begin
  Result := '';
  // NES 2.0 trailing data may contain miscellaneous ROMs, not a title.
  if Metadata.Format <> TRomFormat.INes then
    Exit;

  var Remaining := Stream.Size - Stream.Position;
  if Metadata.ConsoleType = 2 then
  begin
    if (Remaining = $2000 + 127) or (Remaining = $2000 + 128) then
      Stream.Position := Stream.Position + $2000
    else if (Remaining = $2020 + 127) or (Remaining = $2020 + 128) then
      Stream.Position := Stream.Position + $2020
    else
      Exit;
    Remaining := Stream.Size - Stream.Position;
  end;
  if (Remaining <> 127) and (Remaining <> 128) then
    Exit;

  var Data: TBytes;
  SetLength(Data, Integer(Remaining));
  ReadExact(Stream, Data[0], Length(Data));
  var EndOfText := False;
  for var Value in Data do
  begin
    if Value = 0 then
      EndOfText := True
    else if (Value < 32) or (Value > 126) or (EndOfText and (Value <> 32)) then
      Exit('');

    if not EndOfText then
      Result := Result + Char(Value);
  end;
  Result := Trim(Result);
end;

destructor TCartridge.Destroy;
begin
  FMapper.Free;
  inherited Destroy;
end;

procedure TCartridge.LoadFromFile(const FileName: string);
begin
  if FStorage = nil then
    FStorage := TStorage.Default;
  var Stream := FStorage.OpenRead(FileName);
  try
    LoadFromStream(Stream, FileName);
  finally
    Stream.Free;
  end;
end;

procedure TCartridge.LoadFromStream(Stream: TStream; const RomName: string);
begin
  var Input := TBytesStream.Create(ReadRomData(Stream));
  try
    LoadBufferedRom(Input, RomName);
  finally
    Input.Free;
  end;
end;

procedure TCartridge.LoadBufferedRom(Stream: TStream; const RomName: string);
begin
  if FStorage = nil then
    FStorage := TStorage.Default;
  SaveBattery;
  FSaveFileName := '';
  FLastSaveMemory := nil;
  FSaveSize := 0;
  FreeAndNil(FMapper);
  FValid := False;
  FMapperId := -1;
  FHeaderMapperId := -1;
  FMetadata := Default(TCartridgeMetadata);
  FRomFileName := RomName;

  var Header: TInesHeader;
  var PrgRom: TByteArray;
  var ChrRom: TByteArray;
  var Trainer: TByteArray;
  var Mirror: TMirrorMode;
  var HasTrainer: Boolean;
  var ChrRam: Boolean;
  ReadExact(Stream, Header, SizeOf(Header));
  if not CompareMem(@Header.Magic[0], PAnsiChar(NES_ROM_SIGNATURE), Length(NES_ROM_SIGNATURE)) then
    raise ENesException.Create('Invalid iNES file');

  FMetadata := ParseMetadata(Header);
  FMapperId := FMetadata.MapperId;
  FHeaderMapperId := FMapperId;
  Mirror := FMetadata.MirrorMode;
  HasTrainer := FMetadata.HasTrainer;
    // Validate before allocating; malformed size fields must not exhaust memory.
  var Remaining := UInt64(Stream.Size - Stream.Position);
  if HasTrainer then
  begin
    if Remaining < 512 then
      raise ENesException.Create('Unexpected end of file');
    Dec(Remaining, 512);
  end;
  if (FMetadata.PrgRomSize > Remaining) or (FMetadata.PrgRomSize > UInt64(High(Integer))) then
    raise ENesException.Create('Invalid PRG ROM size');

  Dec(Remaining, FMetadata.PrgRomSize);
  if (FMetadata.ChrRomSize > Remaining) or (FMetadata.ChrRomSize > UInt64(High(Integer))) then
    raise ENesException.Create('Invalid CHR ROM size');

  if HasTrainer then
  begin
    SetLength(Trainer, 512);
    ReadExact(Stream, Trainer[0], 512);
  end;

  SetLength(PrgRom, Integer(FMetadata.PrgRomSize));
  if Length(PrgRom) = 0 then
    raise ENesException.Create('ROM has no PRG data');

  ReadExact(Stream, PrgRom[0], Length(PrgRom));

  SetLength(ChrRom, Integer(FMetadata.ChrRomSize));
  ChrRam := Length(ChrRom) = 0;
  if Length(ChrRom) > 0 then
    ReadExact(Stream, ChrRom[0], Length(ChrRom));

  var Hash := THashSHA1.Create;
  Hash.Update(PrgRom[0], Length(PrgRom));
  if Length(ChrRom) > 0 then
    Hash.Update(ChrRom[0], Length(ChrRom));
  FRomIdentity := LowerCase(Hash.HashAsString);
  if FMetadata.Format = TRomFormat.INes then
  begin
    FMetadata.HasBattery := FMetadata.HasBattery or IsLegacyBatteryRom(FRomIdentity);
    if (FMapperId = MAPPER_MMC3) and IsLegacyMmc6Rom(FRomIdentity) then
    begin
      FMetadata.Submapper := 1;
      FMetadata.PrgRamSize := 0;
      FMetadata.PrgNvRamSize := $400;
    end;
    if IsLegacyFamicomKeyboardRom(FRomIdentity) then
      FMetadata.DefaultExpansionDevice := $23;
    if IsLegacyDataRecorderRom(FRomIdentity) then
      FMetadata.DefaultExpansionDevice := $20;
    if IsLegacyMiraclePianoRom(FRomIdentity) then
      FMetadata.DefaultExpansionDevice := $19;
    if IsLegacyPowerPadRom(FRomIdentity) then
      FMetadata.DefaultExpansionDevice := 12;
      // Legacy iNES cannot declare the VS PPU model. This exact ROM uses RP2C04-0004.
    if (FMapperId = MAPPER_VS_SYSTEM) and (FRomIdentity = ROM_NES_VS_SUPER_MARIO_BROS_X_SHA1) then
      FMetadata.VsPpuType := 5;
  end;

  FMetadata.Title := ReadRomTitle(Stream, FMetadata);
    // Preserve explicit NES 2.0 metadata; legacy corrections require exact payload identity.
  if (Header.Flags7 and $0C) <> $08 then
  begin
    FMapperId := ResolveLegacyMapper(FMapperId, PrgRom, ChrRom);
    Mirror := ResolveLegacyMirror(Mirror, PrgRom, ChrRom);
    FMetadata.MirrorMode := Mirror;
    if IsLegacyPalRom(PrgRom, ChrRom) then
      FMetadata.Timing := TRomTiming.PAL;
  end;
  // UNROM512 uses header bit 3 without bit 0 for register-controlled
  // single-screen mirroring; setting both bits selects four-screen RAM.
  if (FMapperId = MAPPER_UNROM512) and ((Header.Flags6 and 9) = 8) then
  begin
    Mirror := TMirrorMode.Single0;
    FMetadata.MirrorMode := Mirror
  end;
  FMapper := CreateMapper(FMapperId, PrgRom, ChrRom, ChrRam, Mirror,
    FMetadata.Format = TRomFormat.INes, FMetadata.Submapper, FMetadata.HasBattery);
  if FMapper = nil then
    raise ENesException.CreateFmt('Unsupported mapper: %d', [FMapperId]);

  if (FMapperId = MAPPER_GTROM) or
    (FMapperId = MAPPER_SACHEN_9602) or
    (FMapperId = MAPPER_RAINBOW) or
    (FMapperId = MAPPER_BANDAI_DATACH) or
    ((FMapperId = MAPPER_RACERMATE) and (FMetadata.Format = TRomFormat.INes)) then
    FMetadata.HasBattery := True;

  // Trainer data initializes the cartridge's CPU RAM before battery activation.
  // A persisted save, when present, subsequently takes precedence.
  for var i := 0 to Length(Trainer) - 1 do
    FMapper.CpuWrite($7000 + i, Trainer[i]);

  FValid := True;
end;

procedure TCartridge.LoadBattery(const DirectoryName: string);
begin
  // Activation is explicit: validating a replacement ROM must not load a stale
  // save while the previous emulation session is still running.
  if not FValid or not FMetadata.HasBattery or (DirectoryName = '') then
    Exit;
  if FSaveFileName <> '' then
    Exit;

  var Memory := FMapper.GetSaveMemory;
  FSaveSize := Length(Memory);
  if (FMetadata.Format = TRomFormat.Nes20) and (FMapperId <> MAPPER_NAMCO_163) and (FMapperId <> MAPPER_UNROM512) and
    (FMapperId <> MAPPER_GTROM) and (FMapperId <> MAPPER_BANDAI_DATACH) and (FMapperId <> MAPPER_RACERMATE) and (FMapperId <> MAPPER_FK23C) and
    (FMapperId <> MAPPER_SACHEN_9602) and (FMapperId <> MAPPER_RAINBOW) then
  begin
    if (FMetadata.ChrNvRamSize <> 0) or
      ((FMetadata.PrgRamSize <> 0) and (FMetadata.PrgNvRamSize <> 0)) or
      (FMetadata.PrgNvRamSize > UInt64(FSaveSize)) then
      raise ENesException.Create('Unsupported NES 2.0 persistent memory layout');

    FSaveSize := Integer(FMetadata.PrgNvRamSize);
  end;
  // Some legacy headers set the battery bit on boards with no writable memory.
  if FSaveSize = 0 then
    Exit;

  var Path := FStorage.GamePath(DirectoryName, FRomFileName, FRomIdentity, '.sav');
  if FStorage.Exists(Path) then
  begin
    var Stream := FStorage.OpenRead(Path);
    try
      // Preserve the older 8 KiB file layout when loading a legacy MMC6 save.
      // RAM was previously stored at the MMC3 $7000 offset inside that file.
      if (FMapperId = MAPPER_MMC3) and (FMetadata.Submapper = 1) and (FSaveSize = $400) and (Stream.Size = $2000) then
      begin
        FSaveSize := $2000;
        SetLength(Memory, FSaveSize);
      end;
      if Stream.Size <> FSaveSize then
        raise ENesException.CreateFmt('Invalid save size: %s (expected %d bytes)', [Path, FSaveSize]);

      ReadExact(Stream, Memory[0], FSaveSize);
    finally
      Stream.Free;
    end;
    FMapper.SetSaveMemory(Memory);
  end;
  FLastSaveMemory := Copy(Memory, 0, FSaveSize);
  // A failed read never arms saving, so a damaged save cannot be overwritten.
  FSaveFileName := Path;
end;

procedure TCartridge.SaveBattery;
begin
  if (FSaveFileName = '') or not FValid then
    Exit;

  var Memory := FMapper.GetSaveMemory;
  if Length(Memory) < FSaveSize then
    raise ENesException.Create('Cartridge persistent memory size changed');

  if CompareMem(@Memory[0], @FLastSaveMemory[0], FSaveSize) then
    Exit;

  var Data: TBytes;
  SetLength(Data, FSaveSize);
  if FSaveSize > 0 then
    Move(Memory[0], Data[0], FSaveSize);
  FStorage.WriteBytes(FSaveFileName, Data);
  FLastSaveMemory := Copy(Memory, 0, FSaveSize);
end;

procedure TCartridge.Reset;
begin
  if FMapper <> nil then
    FMapper.Reset;
end;

end.

