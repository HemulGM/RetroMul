unit NES.Cartridge;

interface

uses
  Core.Storage, System.Classes, System.SysUtils, NES.Types, NES.Mapper,
  NES.DiskSystem;

{$SCOPEDENUMS ON}

const
  NES_ROM_SIGNATURE: AnsiString = 'NES' + #$1A;
  NES_ROM_SIGNATURE_SIZE = 4;
  NES_ROM_HEADER_SIZE = 16;
  NES_ROM_TRAINER_SIZE = 512;
  NES_ROM_PRG_BANK_SIZE = $4000;
  NES_ROM_CHR_BANK_SIZE = $2000;
  NES_ROM_RAM_BANK_SIZE = $2000;
  NES_ROM_FILE_MAX_SIZE = 64 * 1024 * 1024 + NES_ROM_HEADER_SIZE + NES_ROM_TRAINER_SIZE;
  NES_ROM_LARGE_MAX_SIZE = 256 * 1024 * 1024 + NES_ROM_HEADER_SIZE + NES_ROM_TRAINER_SIZE + $1200;

type
  TRomFormat = (Unknown, INES, NES20, FDS, StudyBox);

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
    FRomIdentity, FPreSpeechRomIdentity, FPreTrainerRomIdentity, FSaveFileName: string;
    FRomFileName: string;
    FSaveSize: Integer;
    FLastSaveMemory: TByteArray;
    FAchievementROM: TBytes;
    FStorage: IStorage;
    FFdsBiosFile: string;
    FFdsBiosConfigured: Boolean;
    function LoadTurboGameDoctorBios(const RomName: string): TByteArray;
    function LoadFdsBios(const RomName: string): TByteArray;
    procedure LoadStudyBoxTape(Stream: TStream; const RomName: string);
    function LoadStudyBoxBios(const RomName: string): TByteArray;
    function LoadFcnsFirmware(const RomName: string; const Names: array of string; Size: Integer): TBytes;
    procedure DescribeStudyBox;
    function ReadFdsMedia(Stream: TStream; const FileName: string): TFdsMedia;
    procedure LoadDisk(Stream: TStream; const RomName: string);
    procedure LoadBufferedRom(Stream: TStream; const RomName: string; Mmc3IrqRevision: TMmc3IrqRevision);
  public
    destructor Destroy; override;
    procedure LoadFromFile(const FileName: string);
    procedure LoadFromStream(Stream: TStream; const RomName: string = ''; Mmc3IrqRevision: TMmc3IrqRevision = TMmc3IrqRevision.Auto);
    property Storage: IStorage read FStorage write FStorage;
    procedure Reset(ColdStart: Boolean = False);
    procedure LoadBattery(const DirectoryName: string);
    procedure SaveBattery;
    function DiskSystem: TMapperFds;
    procedure ConfigureFdsBIOS(const FileName: string);
    procedure OpenDisk(const FileName, SaveDirectory: string);
    function MatchesSnapshotIdentity(const Identity: string; Version: Integer): Boolean;
    function MatchesSnapshotSubmapper(Submapper, Version: Integer): Boolean;
    function CanMigrateSnapshotMapper(MapperId: Integer): Boolean;
    property AchievementROM: TBytes read FAchievementROM;
    property RomIdentity: string read FRomIdentity;
    property SaveFileName: string read FSaveFileName;
    property Mapper: TMapper read FMapper;
    property MapperId: Integer read FMapperId;
    property HeaderMapperId: Integer read FHeaderMapperId;
    property Valid: Boolean read FValid;
    property Metadata: TCartridgeMetadata read FMetadata;
  end;

function IsLargeNesImage(const Prefix: TBytes; FileSize: Int64): Boolean;

implementation

uses
  NES.RomHashes, NES.RomMetadata, NES.Mapper.Factory, Core.SavePaths,
  NES.Audio.Jaleco, NES.Mapper.Discrete, NES.Mapper.Cnrom, NES.Mapper.Uxrom,
  NES.Mapper.Mxm1, NES.Mapper.FlameCyclone, NES.Mapper.Bandai, NES.Mapper.Nrom,
  NES.Firmware, NES.Mapper.Jf13, NES.Mapper.GameDoctor, NES.Mapper.MagicCard,
  NES.Mapper.Yuxing, NES.Mapper.ExtendedDiscrete, NES.Mapper.ExtendedMemory,
  NES.Mapper.ExtendedMmc3, NES.Mapper.ExtendedIrq, NES.Mapper.Jy,
  NES.Mapper.Mmc1, NES.Mapper.Fcns, NES.Mapper.Vrc, NES.Mapper.Mmc3,
  NES.Mapper.Mmc3Variants, NES.Mapper.Mmc5, NES.Mapper.OneBus, NES.Mapper.Flash,
  NES.Mapper.Rainbow, NES.Mapper.Mindkids, NES.Mapper.BlazePro,
  NES.Mapper.SuperGameMega, NES.StudyBox.Media, NES.Mapper.StudyBox,
  NES.Mapper.Um6578, System.Hash,
  {$IFDEF MSWINDOWS}
  Winapi.Windows,
  {$ENDIF}
  {$IFDEF POSIX}
  Posix.Stdio, Posix.Unistd,
  {$ENDIF}
  System.IOUtils, Core.Archive.Container, Core.MediaArchive;

type
  TInesHeader = packed record
    Magic: array[0..NES_ROM_SIGNATURE_SIZE - 1] of AnsiChar;
    PrgRomChunks: UInt8;
    ChrRomChunks: UInt8;
    Flags6: UInt8;
    Flags7: UInt8;
    PrgRamSize: UInt8;
    Flags9: UInt8;
    Flags10: UInt8;
    Zero: array[0..NES_ROM_HEADER_SIZE - NES_ROM_SIGNATURE_SIZE - 8] of UInt8;
  end;

procedure ReadExact(Stream: TStream; var Buffer; Count: Integer);
begin
  if Stream.Read(Buffer, Count) <> Count then
    raise ENesException.Create('Unexpected end of file');
end;

function MatchesRomSha1(const Data: TBytes; const Identity: string): Boolean;
begin
  var Hash := THashSHA1.Create;
  Hash.Update(Data);
  Result := SameText(Hash.HashAsString, Identity);
end;

function RestoreBmc3927BankOrder(const Data: TByteArray): TByteArray;
const
  BankSize = $8000;
  SourceBanks: array[0..15] of Byte = (4, 5, 6, 7, 12, 13, 14, 15, 0, 1, 2, 3, 10, 9, 11, 8);
begin
  SetLength(Result, Length(Data));
  for var Bank := Low(SourceBanks) to High(SourceBanks) do
    Move(Data[SourceBanks[Bank] * BankSize], Result[Bank * BankSize], BankSize);
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
  Result.PrgRomSize := UInt64(Header.PrgRomChunks) * NES_ROM_PRG_BANK_SIZE;
  Result.ChrRomSize := UInt64(Header.ChrRomChunks) * NES_ROM_CHR_BANK_SIZE;
  if (Header.Flags7 and $0C) = $08 then
  begin
    Result.Format := TRomFormat.Nes20;
    Result.MapperId := Result.MapperId or ((Header.PrgRamSize and $0F) shl 8);
    Result.Submapper := Header.PrgRamSize shr 4;
    Result.PrgRomSize := RomSize(Header.PrgRomChunks, Header.Flags9 and $0F, NES_ROM_PRG_BANK_SIZE);
    Result.ChrRomSize := RomSize(Header.ChrRomChunks, Header.Flags9 shr 4, NES_ROM_CHR_BANK_SIZE);
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
      Result.ChrRamSize := NES_ROM_CHR_BANK_SIZE;
    if Result.LegacyHeaderDirty then
      Result.MapperId := Header.Flags6 shr 4
    else
    begin
      Result.ConsoleType := Header.Flags7 and 3;
      Result.Timing := TRomTiming(1 + (Header.Flags9 and 1));
      // iNES zero means an inferred 8 KiB, not an explicit absence of RAM.
      Result.PrgRamSize := UInt64(Header.PrgRamSize) * NES_ROM_RAM_BANK_SIZE;
      if Result.PrgRamSize = 0 then
        Result.PrgRamSize := NES_ROM_RAM_BANK_SIZE;
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

function IsVt369Board(Mapper: Integer): Boolean;
begin
  case Mapper of
    MAPPER_ONEBUS, MAPPER_VT369_4150, MAPPER_VT369_411E, MAPPER_VT369_41E6, MAPPER_VT369_SERIAL_ROM, MAPPER_VT369_INVERTER_ROM, MAPPER_VT389:
      Result := True;
  else
    Result := False;
  end;
end;

function ValidVt369Misc(Mapper, Submapper, Count: Integer; Size: Int64): Boolean;
begin
  if Mapper = MAPPER_VT369_SERIAL_ROM then
  begin
    // A serial device image is 256 bytes. Submapper 3 adds a parameter ROM.
    if Size >= $1000 then
    begin
      Dec(Size, $1000);
      Dec(Count);
    end;
    Result := ((Size = 0) and (Count = 0)) or ((Size = $100) and (Count = 1)) or
      ((Submapper = 3) and (Size = $200) and (Count = 2));
  end
  else
    Result := ((Count = 0) and (Size = 0)) or ((Count = 1) and (Size = $1000));
end;

function HasLargeNesHeader(const Header: TInesHeader; FileSize: Int64): Boolean;
begin
  if (FileSize <= NES_ROM_FILE_MAX_SIZE) or (FileSize > NES_ROM_LARGE_MAX_SIZE) or
    not CompareMem(@Header.Magic[0], PAnsiChar(NES_ROM_SIGNATURE), NES_ROM_SIGNATURE_SIZE) then
    Exit(False);
  var Metadata := ParseMetadata(Header);
  if (Metadata.Format <> TRomFormat.Nes20) or (Metadata.ChrRomSize <> 0) or
    (Metadata.PrgRomSize > 256 * 1024 * 1024) then
    Exit(False);
  var ExpectedSize := Metadata.PrgRomSize + NES_ROM_HEADER_SIZE;
  if Metadata.HasTrainer then
    Inc(ExpectedSize, NES_ROM_TRAINER_SIZE);
  if ExpectedSize > UInt64(FileSize) then
    Exit(False);
  if Metadata.MapperId = MAPPER_COOLGIRL then
    Exit((Metadata.PrgRomSize <= 128 * 1024 * 1024) and (Metadata.MiscRomCount = 0) and
      (UInt64(FileSize) = ExpectedSize));
  if Metadata.MapperId = MAPPER_MINDKIDS_FPGA then
    Exit((Metadata.Submapper = 2) and (Metadata.PrgRomSize = 128 * 1024 * 1024) and
      (Metadata.MiscRomCount = 0) and
      ((UInt64(FileSize) = ExpectedSize) or (UInt64(FileSize) = ExpectedSize + $100)));
  if Metadata.MapperId = MAPPER_BLAZEPRO then
    Exit((Metadata.Submapper in [0, 1]) and (Metadata.PrgRomSize = 128 * 1024 * 1024) and
      (Metadata.MiscRomCount = 0) and (UInt64(FileSize) = ExpectedSize));
  if (Metadata.ExtendedConsoleType = 10) and IsVt369Board(Metadata.MapperId) then
    Exit(ValidVt369Misc(Metadata.MapperId, Metadata.Submapper, Metadata.MiscRomCount,
        FileSize - Int64(ExpectedSize)));
  Result := (Metadata.ExtendedConsoleType = 9) and (Metadata.MapperId = MAPPER_VT32) and
    (UInt64(FileSize) = ExpectedSize);
end;

procedure ApplyLegacy178SpeechMetadata(const Sha1: string; var Metadata: TCartridgeMetadata);
const
  Boards: array[0..7] of record
  Sha1: string;
  Ram: Integer;
  Expansion: Byte;
end = (
    (Sha1: 'c022b8b023c2d1e14ad8f45f487fbe420ae13d53'; Ram: $8000; Expansion: 39), // Magister Genius 2
    (Sha1: '665fb3c862c336a07a4c0e1a7dbbb6ffaca96073'; Ram: $2000; Expansion: 40), // Educational Computer 2000 English
    (Sha1: 'faca83d1b7dbdc6fc83021560092f9d20be1fba6'; Ram: 0; Expansion: 40),     // Educational Computer 2000 Spanish
    (Sha1: '7fe06307815f1eef0672ab5f85ccd96d827255a0'; Ram: 0; Expansion: 40),     // Educational Computer Spanish
    (Sha1: '2cd5accc1db6744719d441faf732a42363bea9af'; Ram: $2000; Expansion: 40), // Sistema Cyber
    (Sha1: '6d52e2333408ee4a230a50fd126ab9dbe707308f'; Ram: $2000; Expansion: 39), // Smart Kids
    (Sha1: 'f58cd023b6686fddfd24876285fd248d0a934690'; Ram: 0; Expansion: 38),     // FL-E4MC
    (Sha1: 'c8770f4285e7600b15b2e728533575b41db7b612'; Ram: $2000; Expansion: 40)  // Archival English dump
    );
begin
  for var Board in Boards do
    if Sha1 = Board.Sha1 then
    begin
      Metadata.Submapper := 2;
      Metadata.Timing := TRomTiming.Dendy;
      Metadata.HasBattery := False;
      Metadata.PrgRamSize := Board.Ram;
      Metadata.PrgNvRamSize := 0;
      Metadata.DefaultExpansionDevice := Board.Expansion;
      Exit;
    end;
end;

function IsMapper241SpeechRom(const Sha1: string): Boolean;
begin
  Result := (Sha1 = '1760bad593f2d9e7735fe9f085a81f74723a4077') or  // Educational Computer 2000 Spanish, mapper hack
    (Sha1 = '3e0677d80414629951a540d512dd434a62e5e145') or           // English Blaster
    (Sha1 = '92ac31dd9bc0954a1c68874df033f6828961a4e4') or           // Español de Estudio 32-in-1
    (Sha1 = '16409f693e199920ed2b376d571dc6a202ed503a') or           // Sunsonic Educational Computer
    (Sha1 = 'bd16d02a7c40131f405f74ab1107fae3e25a1080') or           // Zhong Tian Speech Educational Software
    (Sha1 = 'eae01c031c41507bb3ec2b78aad8a645f84fd024') or           // Sound-Word Blaster
    (Sha1 = '415870a0a9fbe68683f04d0240500ee7343aca26') or           // Changda Multimedia Computer
    (Sha1 = 'd37a1140908a04cae5858a0180d4743d643398a0');             // Hongda Little Doctor
end;

function IsLargeNesImage(const Prefix: TBytes; FileSize: Int64): Boolean;
begin
  var Header: TInesHeader;
  if Length(Prefix) < SizeOf(Header) then
    Exit(False);
  Move(Prefix[0], Header, SizeOf(Header));
  Result := HasLargeNesHeader(Header, FileSize);
end;

procedure TCartridge.LoadFromStream(Stream: TStream; const RomName: string; Mmc3IrqRevision: TMmc3IrqRevision);
begin
  FAchievementROM := nil;
  // Large images can be parsed directly from a seekable stream.
  var FileSize: Int64 := -1;
  if Stream <> nil then
  try
    if Stream.Position = 0 then
      FileSize := Stream.Size;
  except
    on E: EStreamError do
      FileSize := -1;
  end;
  if (FileSize > NES_ROM_FILE_MAX_SIZE) and (FileSize <= NES_ROM_LARGE_MAX_SIZE) then
  begin
    var Header: TInesHeader;
    ReadExact(Stream, Header, SizeOf(Header));
    Stream.Position := 0;
    if CompareMem(@Header.Magic, PAnsiChar(STUDY_BOX_SIGNATURE), Length(STUDY_BOX_SIGNATURE)) or
      HasLargeNesHeader(Header, FileSize) then
    begin
      LoadBufferedRom(Stream, RomName, Mmc3IrqRevision);
      if (FMetadata.Format in [TRomFormat.INES, TRomFormat.NES20]) and (DiskSystem = nil) then
      begin
        // RA hashes at most 64 MiB after the iNES header.
        var Position := Stream.Position;
        try
          Stream.Position := 0;
          SetLength(FAchievementROM, 64 * 1024 * 1024 + NES_ROM_HEADER_SIZE);
          ReadExact(Stream, FAchievementROM[0], Length(FAchievementROM));
        finally
          Stream.Position := Position;
        end;
      end;
      Exit;
    end;
  end;
  var Data := ReadRomData(Stream, NES_ROM_FILE_MAX_SIZE);
  var Input := TBytesStream.Create(Data);
  try
    LoadBufferedRom(Input, RomName, Mmc3IrqRevision);
    if (FMetadata.Format in [TRomFormat.INES, TRomFormat.NES20]) and (DiskSystem = nil) and
      (Length(Data) >= NES_ROM_HEADER_SIZE) and
      CompareMem(@Data[0], PAnsiChar(NES_ROM_SIGNATURE), Length(NES_ROM_SIGNATURE)) then
      FAchievementROM := Data;
  finally
    Input.Free;
  end;
end;

function IsKnownFcnsCard(const Identity: string): Boolean;
const
  // Nintendo FCNS entries in NES 2.0 XML Database, 2026-09-26.
  Cards: array[0..26] of string = (
    '0351f3f8a87583d312c5c75f2e9aa22cd377ef26',
    '453eb42c3a2a62aa403881c0784af0f4efc3300c',
    '8dfbe9b32de176b332a940acd3316ea5730786f8',
    'af571b867db965daa3c4cb5f95c24c058a9f1a92',
    'd66168708d9b0a9bd497ad72b31ed8aeae4d78f6',
    '4f10e531800188ebb1e55660126ec4b5bab88532',
    '3951fc1bb2bd44c2e9525d50bdf97b7c5d9f0b9f',
    '1678d0096f9deba5aa5ce32610fc713ae62de1f6',
    'eb15e768f7bb7a928f13d941fb3fbac8f63375c7',
    '75fdd5d1dc2b158d7fc27e7a5eeff7289a4d8459',
    'e5f21a616c8831ad79399b857a8472aa12a3389c',
    'fed8b8b695f59955ffa50e0c1c2af967b6993e64',
    'd6cd7c6f5f4c7df2d322c5faad24c4bceb5cfca0',
    'e67dbd53c36206abe54bd7bce4e9a3bcc2177936',
    '813cbd0049c771a0589a27736e4effedf267c394',
    '651f46d93250515713c186fe047842df3e212dd4',
    '66db2cade5e82693903808d6a075441c5e45ee38',
    'b2453b77caec3c65f5756d573db5ab59168dd69b',
    '7eaa0e168e8c6a167eeb2252a502081d7bc97d76',
    '30fd7561d5bebddd8ab9d24e14e5f93f5a6399bb',
    '407b4f433a44dc288b826ae6b55014d5d733a44c',
    '3b22438b4189fec29b43f1921477dcf5754e52f0',
    '5f55188fff761ca20b03d01f43ae75462d9dde9d',
    'f3155fa23e9ee201b679dd5260a7ef8da1fcd9f3',
    '0d420bcf0c5a14886a66fe6f0f890297cca59f97',
    '9f856f45b1d5ff22d1162387e19aa9ed94656e3e',
    'cd4bb4b6d883004955ca8c49d371e435a43247e3');
begin
  for var Card in Cards do
    if Identity = Card then
      Exit(True);
  Result := False;
end;

procedure TCartridge.LoadBufferedRom(Stream: TStream; const RomName: string; Mmc3IrqRevision: TMmc3IrqRevision);
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

  var Prefix: TBytes;
  SetLength(Prefix, 16);
  SetLength(Prefix, Stream.Read(Prefix[0], Length(Prefix)));
  Stream.Position := 0;
  if (Length(Prefix) >= Length(STUDY_BOX_SIGNATURE)) and
    CompareMem(@Prefix[0], PAnsiChar(STUDY_BOX_SIGNATURE), Length(STUDY_BOX_SIGNATURE)) then
  begin
    LoadStudyBoxTape(Stream, RomName);
    Exit;
  end;
  if TFdsMedia.HasSignature(Prefix) or SameText(ExtractFileExt(RomName), '.fds') or
    SameText(ExtractFileExt(RomName), '.qd') then
  begin
    LoadDisk(Stream, RomName);
    Exit;
  end;

  var Header: TInesHeader;
  var PrgRom: TByteArray;
  var ChrRom: TByteArray;
  var Trainer: TByteArray;
  var MiscRom: TArray<Byte>;
  var Mirror: TMirrorMode;
  var HasTrainer: Boolean;
  var ChrRam: Boolean;
  ReadExact(Stream, Header, SizeOf(Header));
  var RawFcns := False;
  if not CompareMem(@Header.Magic[0], PAnsiChar(NES_ROM_SIGNATURE), Length(NES_ROM_SIGNATURE)) then
  begin
    if (Stream.Size < $4000) or (Stream.Size > $40000) or ((Stream.Size and $3FFF) <> 0) then
    begin
      if SameText(ExtractFileExt(RomName), '.fcn') then
        raise ENesException.Create('Invalid FCNS card size');
      raise ENesException.Create('Invalid iNES file');
    end;
    RawFcns := True;

    // The SHA-1 also identifies cards loaded through an archive or content URI.
    FillChar(Header, SizeOf(Header), 0);
    Header.PrgRomChunks := Stream.Size div NES_ROM_PRG_BANK_SIZE;
    Header.Flags6 := $12;
    Header.Flags7 := $0B;
    Header.PrgRamSize := $60;
    Header.Flags10 := $90;
    Header.Zero[2] := FCNS_CONSOLE_TYPE;
    Stream.Position := 0;
  end;

  FMetadata := ParseMetadata(Header);
  FMapperId := FMetadata.MapperId;
  FHeaderMapperId := FMapperId;
  Mirror := FMetadata.MirrorMode;
  HasTrainer := FMetadata.HasTrainer;
    // Validate before allocating; malformed size fields must not exhaust memory.
  var Remaining := UInt64(Stream.Size - Stream.Position);
  if HasTrainer then
  begin
    if Remaining < NES_ROM_TRAINER_SIZE then
      raise ENesException.Create('Unexpected end of file');
    Dec(Remaining, NES_ROM_TRAINER_SIZE);
  end;
  if (FMetadata.PrgRomSize > Remaining) or (FMetadata.PrgRomSize > UInt64(High(Integer))) then
    raise ENesException.Create('Invalid PRG ROM size');

  Dec(Remaining, FMetadata.PrgRomSize);
  if (FMetadata.ChrRomSize > Remaining) or (FMetadata.ChrRomSize > UInt64(High(Integer))) then
    raise ENesException.Create('Invalid CHR ROM size');

  if HasTrainer then
  begin
    SetLength(Trainer, NES_ROM_TRAINER_SIZE);
    ReadExact(Stream, Trainer[0], NES_ROM_TRAINER_SIZE);
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
  if (FMapperId = MAPPER_NESTICLE_MMC3) and HasTrainer then
    Hash.Update(Trainer[0], Length(Trainer));
  Hash.Update(PrgRom[0], Length(PrgRom));
  if Length(ChrRom) > 0 then
    Hash.Update(ChrRom[0], Length(ChrRom));
  var MiscLength := Stream.Size - Stream.Position;
  FPreSpeechRomIdentity := '';
  FPreTrainerRomIdentity := '';
  if HasTrainer and ((FMapperId in [MAPPER_FFE_F4XXX, MAPPER_FFE_F3XXX, MAPPER_FFE_F8XXX]) or
    ((FMapperId = MAPPER_MMC3_12) and (FMetadata.Submapper = 1))) then
  begin
    var PayloadHash := Hash;
    FPreTrainerRomIdentity := LowerCase(PayloadHash.HashAsString);
    Hash.Update(Trainer[0], Length(Trainer));
  end;
  case FMapperId of
    MAPPER_JALECO_SS88006, MAPPER_JALECO_JF17, MAPPER_JALECO_JF13, MAPPER_JALECO_JF19:
      if FMetadata.MiscRomCount <> 0 then
      begin
        if (FMetadata.MiscRomCount <> 1) or ((MiscLength <> $8000) and
          ((FMapperId <> MAPPER_JALECO_SS88006) or (MiscLength <> $4000))) then
          raise ENesException.Create('Invalid Jaleco voice ROM size');
        SetLength(MiscRom, Integer(MiscLength));
      end;
    MAPPER_CHINA_ER_SAN2:
      if FMetadata.MiscRomCount <> 0 then
      begin
        if (FMetadata.MiscRomCount <> 1) or (MiscLength <> $74E0) then
          raise ENesException.Create('Invalid CHINA_ER_SAN2 font ROM size');
        SetLength(MiscRom, $74E0);
      end;
    MAPPER_BATMAP_SRRX:
      begin
        if (FMetadata.MiscRomCount <> 1) or (MiscLength <> $800000) then
          raise ENesException.Create('Mapper 413 requires the 8 MiB speech ROM');
        SetLength(MiscRom, $800000);
      end;
    MAPPER_3D_BLOCK_PIC:
      begin
        if (FMetadata.MiscRomCount <> 1) or (MiscLength <> $400) then
          raise ENesException.Create('Mapper 355 requires the 1024-byte PIC16C54 misc ROM');
        SetLength(MiscRom, $400);
      end;
    MAPPER_SUPER_GAME_DOCTOR, MAPPER_TURBO_GAME_DOCTOR:
      if FMetadata.MiscRomCount > 0 then
      begin
        if (FMetadata.MiscRomCount <> 1) or HasTrainer or (MiscLength < 4) or (MiscLength > $10004) then
          raise ENesException.Create('Invalid Game Doctor misc ROM trainer');
        SetLength(MiscRom, Integer(MiscLength));
      end
      else if HasTrainer then
        Hash.Update(Trainer[0], Length(Trainer));
  end;
  if (FMetadata.ExtendedConsoleType = 10) and IsVt369Board(FMapperId) and
    (FMetadata.MiscRomCount <> 0) then
  begin
    if not ValidVt369Misc(FMapperId, FMetadata.Submapper, FMetadata.MiscRomCount, MiscLength) then
      raise ENesException.Create('Invalid VT369 miscellaneous ROM layout');
    SetLength(MiscRom, Integer(MiscLength));
  end;
  var LegacyJf13 := (FMapperId = MAPPER_JALECO_JF13) and
    (FMetadata.Format = TRomFormat.INes) and (MiscLength = $8000) and not HasTrainer and
    MatchesRomSha1(TBytes(PrgRom), '361fc153f06451c94c97f2b60127a50234a11836') and
    MatchesRomSha1(TBytes(ChrRom), 'c06ef1f446c4e66ce5efc4e8b282e5f7b9eb3baa');
  if LegacyJf13 then
    SetLength(MiscRom, $8000);
  if Length(MiscRom) <> 0 then
  begin
    ReadExact(Stream, MiscRom[0], Length(MiscRom));
    if LegacyJf13 then
      if MatchesRomSha1(MiscRom, '93fd7e6317baedcacce807f460ee80cd2c59a7f') then
      begin
        FMetadata.Submapper := 1;
        FMetadata.MiscRomCount := 1;
      end
      else
        MiscRom := nil;
    if Length(MiscRom) <> 0 then
    begin
      if FMapperId in [MAPPER_JALECO_SS88006, MAPPER_JALECO_JF17, MAPPER_JALECO_JF13, MAPPER_JALECO_JF19] then
      begin
        var ProgramHash := Hash;
        FPreSpeechRomIdentity := LowerCase(ProgramHash.HashAsString);
      end;
      Hash.Update(MiscRom[0], Length(MiscRom));
    end;
  end;
  FRomIdentity := LowerCase(Hash.HashAsString);
  if RawFcns and not IsKnownFcnsCard(FRomIdentity) then
  begin
    if SameText(ExtractFileExt(RomName), '.fcn') then
      raise ENesException.Create('Unrecognized headerless FCNS card');
    raise ENesException.Create('Invalid iNES file');
  end;
  // The archival PCB3927 dump uses a different 32 KiB bank order on both chips.
  if (FMapperId = MAPPER_BMC_3927_ARCHIVAL) and (FMetadata.Submapper = 0) and
    (Length(PrgRom) = $80000) and (Length(ChrRom) = $80000) and
    (FRomIdentity = ROM_NES_BMC_3927_WRONG_BANK_ORDER_SHA1) then
  begin
    PrgRom := RestoreBmc3927BankOrder(PrgRom);
    ChrRom := RestoreBmc3927BankOrder(ChrRom);
    FMapperId := MAPPER_BMC_3927;
    FMetadata.MapperId := FMapperId;
    FMetadata.PrgRamSize := NES_ROM_RAM_BANK_SIZE;
    Mirror := TMirrorMode.Horizontal;
    FMetadata.MirrorMode := Mirror;
  end;

  // The public MCaFE-e1 demo predates the board's NES 2.0 assignment.
  if (FMetadata.Format = TRomFormat.Nes20) and (FMapperId = 4064) and
    (FRomIdentity = ROM_NES_MCAFE_E1_DEMO_SHA1) then
  begin
    FMapperId := MAPPER_MCAFE_E1;
    FMetadata.HasBattery := True;
    FMetadata.PrgRamSize := 0;
    FMetadata.PrgNvRamSize := $2000;
  end;
  if FMetadata.Format = TRomFormat.INes then
  begin
    if (FMapperId = MAPPER_MMC1) and (FRomIdentity = ROM_NES_DRAGON_WARRIOR_IV_OVERDUMP_SHA1) and
      (Length(PrgRom) = $100000) and ChrRam then
    begin
      // In this overdump, odd 4 KiB pages take PRG A18 from dump A19.
      // Recover the upper 256 KiB of the SUROM PRG and keep the save identity.
      for var Block := 0 to 31 do
      begin
        var Offset := $41000 + Block * $2000;
        Move(PrgRom[Offset + $40000], PrgRom[Offset], $1000);
      end;
      SetLength(PrgRom, $80000);
      FMetadata.PrgRomSize := Length(PrgRom);
    end;
    FMetadata.HasBattery := FMetadata.HasBattery or IsLegacyBatteryRom(FRomIdentity);
    // The BIOS published with VirtuaNES BBK uses a provisional iNES ID.
    if (FMapperId = 171) and ((FRomIdentity = ROM_NES_SB2000_REV0_SHA1) or
      (FRomIdentity = ROM_NES_SB2000_REV1_SHA1)) then
    begin
      FMapperId := MAPPER_SUBOR_SB2000;
      if FRomIdentity = ROM_NES_SB2000_REV1_SHA1 then
        FMetadata.Submapper := 3;
      FMetadata.Timing := TRomTiming.Dendy;
      FMetadata.ConsoleType := 3;
      FMetadata.ExtendedConsoleType := $0B;
      FMetadata.DefaultExpansionDevice := $41;
      FMetadata.PrgRamSize := $2000;
      FMetadata.PrgNvRamSize := 0;
      FMetadata.ChrRamSize := $80000;
    end;
    if (FMapperId = MAPPER_VS_SYSTEM) and IsLegacyVsZapperRom(FRomIdentity) then
    begin
      FMetadata.DefaultExpansionDevice := 7;
      FMetadata.ConsoleType := 1;
      Mirror := TMirrorMode.FourScreen;
      FMetadata.MirrorMode := Mirror;
    end;
    if (FMapperId = MAPPER_MMC3) and IsLegacyMmc6Rom(FRomIdentity) then
    begin
      FMetadata.Submapper := 1;
      FMetadata.PrgRamSize := 0;
      FMetadata.PrgNvRamSize := $400;
    end;
    if (FMapperId = MAPPER_MMC3) and IsLegacyMcAccRom(FRomIdentity) then
      FMetadata.Submapper := 3;
    if (FMapperId = MAPPER_MMC3) and not HasTrainer and IsLegacyMmc3WithoutPrgRam(FRomIdentity) then
    begin
      FMetadata.HasBattery := False;
      FMetadata.PrgRamSize := 0;
      FMetadata.PrgNvRamSize := 0;
    end;
    if (FMapperId = MAPPER_MMC3) and not HasTrainer and IsNesosRom(FRomIdentity) then
    begin
      FMetadata.HasBattery := True;
      FMetadata.PrgRamSize := 0;
      FMetadata.PrgNvRamSize := $800;
    end;
    if (FMapperId = MAPPER_WAIXING178) and ((FRomIdentity = ROM_NES_GAMEINIS_BOXING_SOCCER_REV0_SHA1) or
      (FRomIdentity = ROM_NES_GAMEINIS_BOXING_SOCCER_REV1_SHA1) or
      (FRomIdentity = ROM_NES_GAMEINIS_PING_PONG_REV0_SHA1) or
      (FRomIdentity = ROM_NES_GAMEINIS_PING_PONG_REV1_SHA1)) then
    begin
      FMetadata.Submapper := 1;
      FMetadata.HasBattery := False;
      FMetadata.PrgRamSize := 0;
      FMetadata.PrgNvRamSize := 0;
      if FRomIdentity = ROM_NES_GAMEINIS_PING_PONG_REV0_SHA1 then
        FMetadata.Timing := TRomTiming.Dendy;
    end;
    if FMapperId = MAPPER_WAIXING178 then
      ApplyLegacy178SpeechMetadata(FRomIdentity, FMetadata);
    if (FMapperId = MAPPER_WAIXING178) and (FRomIdentity = ROM_NES_Y2K_42_150_IN_1_SHA1) then
    begin
      FMetadata.Submapper := 3;
      FMetadata.HasBattery := False;
      FMetadata.PrgRamSize := 0;
      FMetadata.PrgNvRamSize := 0;
      FMetadata.DefaultExpansionDevice := $2A;
    end;
    if (FMapperId = MAPPER_SUNSOFT4) and ((FRomIdentity = ROM_NES_NANTETTATTE_BASEBALL_SHA1) or
      (FRomIdentity = ROM_NES_NANTETTATTE_BASEBALL_1991_SHA1) or
      (FRomIdentity = ROM_NES_NANTETTATTE_BASEBALL_OB_SHA1) or
      (FRomIdentity = ROM_NES_NANTETTATTE_BASEBALL_EN_SHA1) or
      (FRomIdentity = ROM_NES_NANTETTATTE_BASEBALL_SAMPLE_SHA1)) then
    begin
      FMetadata.Submapper := 1;
      FMetadata.HasBattery := True;
      FMetadata.PrgRamSize := 0;
      FMetadata.PrgNvRamSize := $2000;
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
  var RepairedCnrom := False;
  var KnownDiscreteBoard := False;
  var KnownCamericaBoard := False;
  var RepairedNrom := False;
    // Preserve explicit NES 2.0 metadata; legacy corrections require exact payload identity.
  if (Header.Flags7 and $0C) <> $08 then
  begin
    FMapperId := ResolveLegacyMapper(FMapperId, PrgRom, ChrRom);
    var DiscreteBoard: TLegacyDiscreteBoard;
    if not HasTrainer and TryResolveLegacyDiscreteBoard(FMapperId, FRomIdentity, DiscreteBoard) then
    begin
      KnownDiscreteBoard := True;
      FMetadata.Submapper := DiscreteBoard.Submapper;
      FMetadata.PrgRamSize := DiscreteBoard.PrgRam;
      FMetadata.PrgNvRamSize := DiscreteBoard.PrgNvRam;
      FMetadata.HasBattery := DiscreteBoard.Battery;
    end;
    RepairedCnrom := (FHeaderMapperId = MAPPER_NROM) and (FMapperId = MAPPER_CNROM) and
      ((FRomIdentity = ROM_NES_ADVENTURES_OF_DINO_RIKI_SHA1) or (FRomIdentity = ROM_NES_MYSTERY_QUEST_SHA1));
    var IsDeadlyTowers := (FMapperId = MAPPER_BNROM_NINA001) and (FRomIdentity = ROM_NES_DEADLY_TOWERS_SHA1);
    var RepairedMmc3 := (FHeaderMapperId = MAPPER_MMC3) and
      (FMapperId in [MAPPER_DXROM, MAPPER_TXSROM, MAPPER_RAMBO1]);
    var Repaired148 := (FHeaderMapperId = MAPPER_CNROM) and (FMapperId = MAPPER_HES_148);
    if RepairedCnrom or IsDeadlyTowers then
      FMetadata.Submapper := 2;
    if RepairedCnrom or IsDeadlyTowers or RepairedMmc3 or Repaired148 or
      ((FMapperId = MAPPER_COLOR_DREAMS) and (FRomIdentity = ROM_NES_CASTLE_OF_DECEIT_SHA1)) then
    begin
      FMetadata.HasBattery := False;
      FMetadata.PrgRamSize := 0;
      FMetadata.PrgNvRamSize := 0;
    end;
    if ((FMapperId = MAPPER_IREM_G101) and (FRomIdentity = ROM_NES_IREM_MAJOR_LEAGUE_SHA1)) or
      ((FMapperId = MAPPER_CAMERICA_QUATTRO) and (FRomIdentity = ROM_NES_QUATTRO_SPORTS_SHA1)) then
      FMetadata.Submapper := 1;
    if (FMapperId = MAPPER_JY_281) and (FRomIdentity = ROM_NES_JY052_TARZAN_SHA1) then
      FMetadata.PrgRamSize := 0;
    Mirror := ResolveLegacyMirror(Mirror, PrgRom, ChrRom);
    if KnownDiscreteBoard and (FMapperId = MAPPER_BNROM_NINA001) and
      (FRomIdentity = ROM_NES_IMPOSSIBLE_MISSION_2_SHA1) then
      Mirror := TMirrorMode.Vertical;
    if not HasTrainer and (FMapperId in [MAPPER_MMC3, MAPPER_MMC3_245]) and
      (FRomIdentity = ROM_NES_F003_DRAGON_QUEST_VII_SHA1) then
    begin
      FMapperId := MAPPER_MMC3_245;
      FMetadata.MapperId := FMapperId;
      FMetadata.PrgRamSize := 0;
      FMetadata.PrgNvRamSize := $2000;
      FMetadata.HasBattery := True;
      FMetadata.Timing := TRomTiming.Dendy;
      Mirror := TMirrorMode.Horizontal;
    end
    else if (FMapperId = MAPPER_MMC3_245) and not HasTrainer and
      (FRomIdentity = ROM_NES_DRAGON_QUEST_VI_WAIXING_SHA1) then
      FMetadata.Timing := TRomTiming.Dendy;
    var NromMirror: TMirrorMode;
    if not HasTrainer and TryResolveLegacyNrom(FMapperId, FRomIdentity, NromMirror) then
    begin
      RepairedNrom := True;
      FMapperId := MAPPER_NROM;
      FMetadata.MapperId := MAPPER_NROM;
      FMetadata.Submapper := 0;
      FMetadata.PrgRamSize := 0;
      FMetadata.PrgNvRamSize := 0;
      FMetadata.HasBattery := False;
      Mirror := NromMirror;
    end;
    if not HasTrainer and (FMapperId = MAPPER_CNROM) and (FRomIdentity = ROM_NES_FFE_CHOPLIFTER_SHA1) then
    begin
      FMapperId := MAPPER_FFE_F4XXX;
      FMetadata.MapperId := FMapperId;
      FMetadata.Submapper := 6;
      Mirror := TMirrorMode.Vertical;
    end
    else if not HasTrainer and (FMapperId = MAPPER_UXROM) and (FRomIdentity = ROM_NES_FFE_HOLMES_SHA1) then
    begin
      // This old conversion specified its CIRAM wiring in the iNES header.
      FMapperId := MAPPER_FFE_F4XXX;
      FMetadata.MapperId := FMapperId;
      FMetadata.Submapper := 2;
    end
    else if FMapperId = MAPPER_FFE_F4XXX then
      FMetadata.Submapper := 1;
    FMetadata.MirrorMode := Mirror;
    if ((FMapperId = MAPPER_MMC1) and (FRomIdentity = ROM_NES_SNAKE_RATTLE_ROLL_PAL_SHA1)) or
      IsLegacyPalRom(PrgRom, ChrRom) then
      FMetadata.Timing := TRomTiming.PAL;
    var CamericaBoard: TCamericaBoard;
    if not HasTrainer and (FMapperId in [MAPPER_CAMERICA, MAPPER_UXROM]) and
      TryResolveLegacyCamerica(FRomIdentity, CamericaBoard) then
    begin
      KnownCamericaBoard := True;
      FMapperId := MAPPER_CAMERICA;
      FMetadata.MapperId := FMapperId;
      FMetadata.Submapper := CamericaBoard.Submapper;
      FMetadata.Timing := TRomTiming(Ord(TRomTiming.NTSC) + CamericaBoard.Timing);
      FMetadata.HasBattery := False;
      FMetadata.PrgRamSize := 0;
      FMetadata.PrgNvRamSize := 0;
      if CamericaBoard.Vertical then
        Mirror := TMirrorMode.Vertical
      else
        Mirror := TMirrorMode.Horizontal;
      FMetadata.MirrorMode := Mirror;
    end;
    if RepairedMmc3 or Repaired148 then
    begin
      FMetadata.Timing := TRomTiming.NTSC;
      if FRomIdentity = ROM_NES_GOAL_2_PAL_SHA1 then
        FMetadata.Timing := TRomTiming.PAL;
      FMetadata.DefaultExpansionDevice := 1;
      if FRomIdentity = ROM_NES_PLAY_ACTION_FOOTBALL_SHA1 then
        FMetadata.DefaultExpansionDevice := 2;
    end;
  end;
  if (FMapperId = MAPPER_IREM_G101) and (FMetadata.Submapper = 1) then
  begin
    Mirror := TMirrorMode.Single1;
    FMetadata.MirrorMode := Mirror;
  end;
  if (FMapperId = MAPPER_CAMERICA) and (FMetadata.Submapper = 1) then
  begin
    Mirror := TMirrorMode.Single0;
    FMetadata.MirrorMode := Mirror;
  end;
  // UNROM512 uses header bit 3 without bit 0 for register-controlled
  // single-screen mirroring; setting both bits selects four-screen RAM.
  if ((FMapperId = MAPPER_UNROM512) or (FMapperId = MAPPER_RAINBOW512)) and ((Header.Flags6 and 9) = 8) then
  begin
    Mirror := TMirrorMode.Single0;
    FMetadata.MirrorMode := Mirror
  end;
  // Mapper 218 uses bits 3/0 to select CIRAM A10 from PPU A10..A13.
  // Bit 3 selects A12/A13 rather than four-screen nametable RAM.
  if (FMapperId = MAPPER_MAGIC_FLOOR218) and ((Header.Flags6 and 8) <> 0) then
  begin
    if (Header.Flags6 and 1) = 0 then
      Mirror := TMirrorMode.Single0
    else
      Mirror := TMirrorMode.Single1;
    FMetadata.MirrorMode := Mirror
  end;
  if (FMetadata.Format = TRomFormat.Nes20) and (FMetadata.ConsoleType = 3) and
    (FMetadata.ExtendedConsoleType = FCNS_CONSOLE_TYPE) then
  begin
    if not (FMapperId in [MAPPER_MMC1, MAPPER_MMC1A]) or (FMetadata.Submapper <> 6) or
      not ChrRam or HasTrainer or (FMetadata.MiscRomCount <> 0) then
      raise ENesException.Create('Unsupported FCNS card hardware');
    var Kanji := LoadFcnsFirmware(RomName, ['lh5323m1.bin',
        '[BIOS] LH5323M1 Kanji Graphic ROM (Japan).bin'], FCNS_KANJI_SIZE);
    var Cpu2Rom := LoadFcnsFirmware(RomName, ['rf5a18.bin',
        '[BIOS] RF5A18 CPU2 ROM (Japan).bin'], FCNS_CPU2_ROM_SIZE);
    var FirmwareHash := THashSHA1.Create;
    FirmwareHash.Update(Kanji[0], Length(Kanji));
    var KanjiHash := LowerCase(FirmwareHash.HashAsString);
    if (KanjiHash <> FCNS_KANJI_DUMP_SHA1) and (KanjiHash <> FCNS_KANJI_LINEAR_SHA1) then
      raise ENesException.Create('Unrecognized FCNS LH5323M1 graphics ROM');
    FirmwareHash := THashSHA1.Create;
    FirmwareHash.Update(Cpu2Rom[0], Length(Cpu2Rom));
    if not SameText(FirmwareHash.HashAsString, FCNS_CPU2_ROM_SHA1) then
      raise ENesException.Create('Unrecognized FCNS RF5A18 CPU2 ROM');
    FMapper := TMapperFcns.Create(PrgRom, Kanji, Cpu2Rom, KanjiHash = FCNS_KANJI_DUMP_SHA1);
    FMetadata.ChrRamSize := $4000;
    FMetadata.DefaultExpansionDevice := FCNS_EXPANSION_CONTROLLER;
  end
  else if (FMapperId = MAPPER_HARATYLER) and (FMetadata.Submapper = 0) then
  begin
    // HG and MP share 451.0. A matching music folder opts other releases into the MP variant.
    var AudioFolder := ChangeFileExt(RomName, '');
    if (FRomIdentity = ROM_NES_HARATYLER_MP_SHA1) or
      ((FRomIdentity <> ROM_NES_HARATYLER_HG_SHA1) and (AudioFolder <> '') and FStorage.FolderExists(AudioFolder)) then
      FMapper := TMapperHaratylerMp.Create(PrgRom, ChrRom, Mirror, AudioFolder, FStorage)
    else
      FMapper := TMapperHaratyler.Create(PrgRom, ChrRom, Mirror);
  end
  else if (FMapperId = MAPPER_HOMEBREW_800) and (FMetadata.Submapper = 0) then
  begin
    // MXM-1 and FlameCyclone share mapper and submapper 800.0.
    if (Length(PrgRom) >= $200000) and (Length(ChrRom) >= $400000) and
      (FMetadata.PrgRamSize = $100000) and (FMetadata.ChrRamSize = $2000) and
      (Mirror = TMirrorMode.FourScreen) then
      FMapper := TMapperMxm1.Create(PrgRom, ChrRom, FMetadata.PrgRamSize)
    else
      // FlameCyclone's Double Dragon II build declares no RAM and starts with work RAM at $6000.
      FMapper := TMapperFlameCyclone.Create(PrgRom, ChrRom,
        FMetadata.PrgRamSize, FMetadata.ChrRamSize, FMetadata.PrgNvRamSize, FMetadata.ChrNvRamSize,
        FRomIdentity = ROM_NES_FLAME_DOUBLE_DRAGON_II_2026_SHA1);
  end
  else if (FMapperId = MAPPER_CNROM) and (FRomIdentity = ROM_NES_AEROBICS_STUDIO_SHA1) then
  begin
    if FMetadata.DefaultExpansionDevice = 0 then
      FMetadata.DefaultExpansionDevice := $0E;
    var Aerobics := TMapperAerobicsStudio.Create(PrgRom, ChrRom, Mirror);
    FMapper := Aerobics;
    Aerobics.LoadRecordings(FStorage, RomName);
  end
  else if (FMapperId = MAPPER_DISCRETE_241) and IsMapper241SpeechRom(FRomIdentity) then
    FMapper := TMapperPeLpc.Create(FMapperId, PrgRom, ChrRom, ChrRam, Mirror, FMetadata.Submapper)
  else if RepairedNrom then
    FMapper := TMapperNrom.Create(PrgRom, ChrRom, ChrRam, Mirror, False)
  else
  begin
    var JalecoPack := JalecoRecordingPack(FMapperId, FRomIdentity);
    FMapper := CreateMapper(FMapperId, PrgRom, ChrRom, ChrRam, Mirror,
      (FMetadata.Format = TRomFormat.INes) and not (RepairedCnrom or KnownCamericaBoard),
      FMetadata.Submapper, FMetadata.HasBattery, MiscRom, JalecoPack);
    if FMapper is TMapperJalecoJfSpeech then
      TMapperJalecoJfSpeech(FMapper).Speech.LoadRecordings(FStorage, RomName, JalecoPack)
    else if FMapper is TMapperJalecoIrqSpeech then
      TMapperJalecoIrqSpeech(FMapper).Speech.LoadRecordings(FStorage, RomName, JalecoPack)
    else if FMapper is TMapperJf13 then
      TMapperJf13(FMapper).LoadRecordings(FStorage, RomName);
  end;
  if FMapper is TMapperPeLpc then
    TMapperPeLpc(FMapper).ConfigureWorkRam(FMetadata.PrgRamSize + FMetadata.PrgNvRamSize);

  if FMapper = nil then
    raise ENesException.CreateFmt('Unsupported mapper: %d', [FMapperId]);

  if (Mmc3IrqRevision <> TMmc3IrqRevision.Auto) and (FMapperId = MAPPER_MMC3) and
    (FMetadata.Submapper in [0, 2, 4]) then
    TMapperMmc3(FMapper).ConfigureIrqRevision(Mmc3IrqRevision);

  if KnownDiscreteBoard or (FMetadata.Format = TRomFormat.Nes20) then
  begin
    var PrgRamSize := FMetadata.PrgRamSize + FMetadata.PrgNvRamSize;
    if FMapper is TMapperUxrom then
    begin
      // Preserve the implicit trainer window used by older mapper 2 images.
      if (PrgRamSize <> 0) or not HasTrainer then
        TMapperUxrom(FMapper).ConfigurePrgRam(PrgRamSize);
    end
    else if FMapper is TMapperCnrom then
      TMapperCnrom(FMapper).ConfigurePrgRam(PrgRamSize);
  end;

  if (FMapperId = MAPPER_BANDAI_FCG) and (FMetadata.Submapper in [4, 5]) then
    TMapperBandai(FMapper).Configure24C02(FMetadata.PrgNvRamSize);

  if ((FMapperId = MAPPER_BNROM_NINA001) and (FMetadata.Submapper in [1, 2])) or
    ((FMapperId = MAPPER_DXROM) and ((FMetadata.Format = TRomFormat.Nes20) or FMetadata.HasBattery)) then
    TMapperDiscrete(FMapper).ConfigureFittedPrgRam(FMetadata.PrgRamSize + FMetadata.PrgNvRamSize);

  if FMapperId = MAPPER_TXSROM then
    TMapperExtendedMmc3(FMapper).HasBoardPrgRam := (FMetadata.PrgRamSize + FMetadata.PrgNvRamSize) <> 0;

  if FMapper is TMapperMmc1TwoMe then
  begin
    TMapperMmc1TwoMe(FMapper).ConfigureCardRam(FMetadata.PrgRamSize, FMetadata.PrgNvRamSize);
    FMetadata.HasBattery := True;
  end;

  if FMapperId = MAPPER_RAINBOW512 then
    TMapperRainbow512(FMapper).ConfigureChrRam(FMetadata.ChrRamSize)
  else if (FMapperId = MAPPER_RAINBOW_PROTO) and (FRomIdentity = ROM_NES_RAINBOW_CHAT_2020_SHA1) then
    TMapperRainbowProto(FMapper).UseLegacyEspOpcodes;

  if FMapper is TMapperUm6578 then
  begin
    TMapperUm6578(FMapper).ConfigureMemory(FMetadata.PrgRamSize, FMetadata.PrgNvRamSize,
        FMetadata.DefaultExpansionDevice);
    if FMapperId = MAPPER_SUBOR_SB2000 then
      FMetadata.ChrRamSize := $80000
    else
      FMetadata.ChrRamSize := $8000;
  end;

  if FMapperId = MAPPER_STUDY_BOX then
    DescribeStudyBox;

  if FMapperId = MAPPER_BMC_JY104 then
  begin
    if ChrRam and (FMetadata.ChrRamSize = 0) then
      FMetadata.ChrRamSize := NES_ROM_CHR_BANK_SIZE;
    TMapperBmcJy104(FMapper).ConfigureMemory(FMetadata.PrgRamSize, FMetadata.ChrRamSize);
    FMetadata.PrgNvRamSize := $100;
    FMetadata.HasBattery := True;
  end;

  if FMapperId = MAPPER_BMC_810344C then
  begin
    FMetadata.PrgRamSize := 0;
    FMetadata.PrgNvRamSize := $200;
    FMetadata.HasBattery := True;
  end;

  if FMapperId = MAPPER_BTL_UT1245A then
  begin
    if (FMetadata.Submapper = 1) or
      ((FMetadata.Submapper = 0) and (FMetadata.PrgNvRamSize = $100)) then
    begin
      FMetadata.PrgRamSize := 0;
      FMetadata.PrgNvRamSize := $100;
    end;
    FMetadata.HasBattery := FMetadata.PrgNvRamSize <> 0;
    TMapperDbzBootleg(FMapper).ConfigureSaveMemory(FMetadata.PrgRamSize, FMetadata.PrgNvRamSize);
  end;

  if FMapperId = MAPPER_SUPER_GAME_MEGA then
  begin
    // The original public image predates a CHR RAM size and expansion ID.
    FMetadata.ChrRamSize := $2000;
    if FMetadata.DefaultExpansionDevice = 0 then
      FMetadata.DefaultExpansionDevice := $2A;
    TMapperSuperGameMega(FMapper).ConfigureRam((FMetadata.PrgRamSize + FMetadata.PrgNvRamSize) <> 0);
  end;

  if FMapperId = MAPPER_MINDKIDS_FPGA then
  begin
    if FMetadata.ChrNvRamSize <> 0 then
      raise ENesException.Create('Unsupported Mindkids FPGA persistent CHR RAM');
    TMapperMindkids(FMapper).ConfigureMemory(FMetadata.PrgRamSize, FMetadata.PrgNvRamSize, FMetadata.ChrRamSize);
  end;

  if FMapperId = MAPPER_BLAZEPRO then
  begin
    if FMetadata.ChrNvRamSize <> 0 then
      raise ENesException.Create('Unsupported BlazePro CPLD persistent CHR RAM');
    TMapperBlazePro(FMapper).ConfigureMemory(FMetadata.PrgRamSize + FMetadata.PrgNvRamSize, FMetadata.ChrRamSize);
  end;

  if FMapper is TMapperOneBus then
  begin
    if (FMetadata.ExtendedConsoleType = 10) and not IsVt369Board(FMapperId) then
      raise ENesException.CreateFmt('Unsupported VT369 board: %d', [FMapperId]);
    var SerialEepromSize := 0;
    if (FMapperId = MAPPER_VT369_INVERTER_ROM) and (FMetadata.Submapper = 0) then
    begin
      // The Oregon Trail's board responds at I2C addresses $50 through $53.
      if (FRomIdentity = ROM_NES_OREGON_TRAIL_SHA1) and (FMetadata.PrgNvRamSize = $200) then
        FMetadata.PrgNvRamSize := $400;
      if (FMetadata.PrgNvRamSize = $200) or (FMetadata.PrgNvRamSize = $400) then
        SerialEepromSize := Integer(FMetadata.PrgNvRamSize);
    end;
    // Mapper 408.0 also covers boards without the H12 Pro's GPIO bank select.
    var H12Pro := (FMapperId = MAPPER_ARCADE_ADVANCED) and (FRomIdentity = ROM_NES_H12_PRO_1000_IN_1_SHA1);
    TMapperOneBus(FMapper).ConfigureHardware(FMetadata.ExtendedConsoleType,
        (FMetadata.PrgRamSize <> 0) or ((FMetadata.PrgNvRamSize <> 0) and (SerialEepromSize = 0)),
        MiscRom, SerialEepromSize, H12Pro);
  end;

  if (((FMapperId = MAPPER_MMC1) or (FMapperId = MAPPER_MMC1A)) and (FMetadata.Submapper = 7)) or
    (FMapperId = MAPPER_RESET_SLROM) or (FMapperId = MAPPER_JY012005) or
    (FMapperId = MAPPER_BMC_3927) or (FMapperId = MAPPER_BMC_K3011) or (FMapperId = MAPPER_BMC_FC41) or
    (FMapperId = MAPPER_BMC_03101) or (FMapperId = MAPPER_PREDATOR_C806) then
    TMapperMmc1(FMapper).HasBoardPrgRam := (FMetadata.PrgRamSize <> 0) or (FMetadata.PrgNvRamSize <> 0);

  if (FMapperId in [MAPPER_VRC4A_VRC4C, MAPPER_VRC2A, MAPPER_VRC2B_VRC4E,
      MAPPER_VRC2C_VRC4B]) and (KnownDiscreteBoard or (FMetadata.Format = TRomFormat.Nes20)) then
    TMapperVrc(FMapper).ConfigureBoardPrgRam(FMetadata.PrgRamSize + FMetadata.PrgNvRamSize);
  if (FMapperId = MAPPER_VRC2B_VRC4E) and (FMetadata.Submapper = 3) and
    Vrc2HasFloatingInput(FRomIdentity) then
    TMapperVrc(FMapper).DisableVrc2BitLatch;

  if (FMapperId = MAPPER_VRC_L1A16) or (FMapperId = MAPPER_VRC_KL06) or
    (FMapperId = MAPPER_VRC_J33C) or (FMapperId = MAPPER_VRC_9052) or
    (FMapperId = MAPPER_VRC_JC011) or (FMapperId = MAPPER_VRC_AD301) then
    TMapperVrc(FMapper).ConfigureBoardPrgRam(FMetadata.PrgRamSize + FMetadata.PrgNvRamSize);

  if FMapper is TMapperBatmap then
    TMapperBatmap(FMapper).ConfigurePrgRam(FMetadata.PrgRamSize + FMetadata.PrgNvRamSize);

  if FMapper is TMapperYuxing then
    TMapperYuxing(FMapper).ConfigureMemory(FMetadata.PrgRamSize, FMetadata.PrgNvRamSize,
        FMetadata.ChrRamSize, FMetadata.HasBattery);

  if FMapper is TMapperJyMultiAsic then
    TMapperJyMultiAsic(FMapper).ConfigureMemory((FMetadata.PrgRamSize <> 0) or (FMetadata.PrgNvRamSize <> 0),
        (FMetadata.ChrRamSize <> 0) or (FMetadata.ChrNvRamSize <> 0));

  if FMapper is TMapperJy then
    TMapperJy(FMapper).ConfigureWorkRam((FMetadata.PrgRamSize <> 0) or (FMetadata.PrgNvRamSize <> 0));

  case FMapperId of
    MAPPER_00202650, MAPPER_GAMES_XPLOSION, MAPPER_BMC_840415C, MAPPER_BMC_810431C, MAPPER_BMC_10_24_C_A1, MAPPER_BMC_810305C, MAPPER_F600, MAPPER_REALTEC_8210, MAPPER_JY302, MAPPER_JY208, MAPPER_YY841155C, MAPPER_A88S1, MAPPER_REALTEC_K6C3001A, MAPPER_BMC_K3022, MAPPER_BMC_FC53A, MAPPER_SACHEN_TC032, MAPPER_BMC_FC49, MAPPER_BMC_NT319, MAPPER_RETROAD_KJ01A, MAPPER_ESTIQUE:
      TMapperExtendedMmc3(FMapper).HasBoardPrgRam := (FMetadata.PrgRamSize <> 0) or (FMetadata.PrgNvRamSize <> 0);
  end;
  if (FMapperId = MAPPER_KEYBYTE_COMPUTER) or (FMapperId = MAPPER_BMC_T215) or
    (FMapperId = MAPPER_BMC_821134) or (FMapperId = MAPPER_LIKO_429) then
    TMapperExtendedDiscrete(FMapper).ConfigureBoardPrgRam(FMetadata.PrgRamSize + FMetadata.PrgNvRamSize);

  if FMapperId = MAPPER_DG574B then
    TMapperExtendedMmc3(FMapper).HasBoardPrgRam := (FMetadata.PrgRamSize + FMetadata.PrgNvRamSize) <> 0;

  if FMapperId = MAPPER_GAMESTAR_CM9309 then
    TMapperMmc1(FMapper).HasBoardPrgRam := (FMetadata.PrgRamSize <> 0) or (FMetadata.PrgNvRamSize <> 0);

  if FMapperId = MAPPER_RETROAD_KJ01A then
    TMapperExtendedMmc3(FMapper).ConfigureRetroadChrRam(FMetadata.ChrRamSize);

  if FMapperId = MAPPER_COOLX_LITE then
    TMapperExtendedMmc3(FMapper).ConfigureCoolXPrgRam(FMetadata.PrgRamSize + FMetadata.PrgNvRamSize);
  if (FMapperId = MAPPER_BMC_10_24_C_A1) or (FMapperId = MAPPER_BMC_810305C) or
    (FMapperId = MAPPER_JY302) or (FMapperId = MAPPER_JY208) then
    TMapperExtendedMmc3(FMapper).HasBoardChrRam := (FMetadata.ChrRamSize <> 0) or (FMetadata.ChrNvRamSize <> 0);

  if (FMapperId = MAPPER_BMC_480) or (FMapperId = MAPPER_SACHEN_TC032) or (FMapperId = MAPPER_BMC_K3044) then
    TMapperExtendedMmc3(FMapper).HasBoardChrRam := (FMetadata.ChrRamSize <> 0) or (FMetadata.ChrNvRamSize <> 0);

  if FMapperId = MAPPER_BMC_GN26 then
    TMapperExtendedMmc3(FMapper).Gn26LegacyPrgOrder := FRomIdentity = ROM_NES_GN26_WRONG_PRG_ORDER_SHA1;

  if (FMapperId = MAPPER_MMC3_126) or (FMapperId = MAPPER_TEC9719) or (FMapperId = MAPPER_ING022) then
    TMapperExtendedMmc3(FMapper).ConfigureTecMemory(FMetadata.ChrRamSize,
        (FMetadata.Format = TRomFormat.INes) or (FMetadata.PrgRamSize <> 0) or (FMetadata.PrgNvRamSize <> 0),
        HasLegacyTecChrOrder(FRomIdentity), HasLegacyTecPrgOrder(FRomIdentity));

  if ((FMapperId = MAPPER_SUPER_GAMES_KING) or (FMapperId = MAPPER_BMC_K1053)) and
    (FMetadata.ChrRamSize <> 0) then
    TMapperExtendedDiscrete(FMapper).ConfigureBankedChrRam(FMetadata.ChrRamSize);

  if FMapperId = MAPPER_MMC5 then
  begin
    var Mmc5 := TMapperMmc5(FMapper);
    if FMetadata.Format = TRomFormat.Nes20 then
      Mmc5.ConfigurePrgRam(FMetadata.PrgRamSize, FMetadata.PrgNvRamSize);

    // This exact translation stops its PCM introduction with $5010=$FF.
    // Hardware read mode would instead play CPU opcodes as sample data.
    if FRomIdentity = ROM_NES_SAINT_SEIYA_T_CHI_V2_SHA1 then
      Mmc5.ConfigureWriteOnlyPcm;
  end;

  if (FMapperId in [MAPPER_MMC3, MAPPER_MMC3_249]) and
    ((FMapperId <> MAPPER_MMC3) or (FMetadata.Submapper <> 1)) then
  begin
    var PrgRamSize := FMetadata.PrgRamSize + FMetadata.PrgNvRamSize;
    if not HasTrainer and (PrgRamSize = 0) and
      ((FMetadata.Format = TRomFormat.Nes20) or
      ((FMapperId = MAPPER_MMC3) and IsLegacyMmc3WithoutPrgRam(FRomIdentity))) then
      TMapperMmc3(FMapper).ConfigurePrgRam(0)
    else if (PrgRamSize > 0) and (PrgRamSize <= $2000) and
      ((FMetadata.PrgRamSize = 0) or (FMetadata.PrgNvRamSize = 0)) then
      TMapperMmc3(FMapper).ConfigurePrgRam(Integer(PrgRamSize))
    else if (FMetadata.Format = TRomFormat.Nes20) and (FMapperId = MAPPER_MMC3) and
      (FMetadata.Submapper = 0) and (FMetadata.PrgRamSize = 0) and (FMetadata.PrgNvRamSize > $2000) then
    begin
      if FMetadata.PrgNvRamSize > $10000 then
        raise ENesException.Create('Unsupported MMC3 RAM layout');
      TMapperMmc3(FMapper).ConfigurePrgRam(Integer(FMetadata.PrgNvRamSize));
    end;
  end;

  // These Waixing boards can save to a serial 93C66 independently of volatile CPU RAM.
  var Waixing93C66 := (FMapperId = MAPPER_WAIXING164) or (FMapperId = MAPPER_WAIXING558);
  if Waixing93C66 and (FMetadata.Format = TRomFormat.Nes20) and (FMetadata.PrgNvRamSize = 512) then
  begin
    if (FMetadata.PrgRamSize > $2000) or (FMetadata.ChrNvRamSize <> 0) then
      raise ENesException.Create('Unsupported Waixing 93C66 RAM layout');

    TMapperExtendedMemory(FMapper).Configure93C66(Integer(FMetadata.PrgRamSize));
    FMetadata.HasBattery := True;
  end
  else if (FMapperId = MAPPER_WAIXING558) and (FMetadata.Format = TRomFormat.Nes20) then
    TMapperExtendedMemory(FMapper).ConfigureWaixing558Ram(FMetadata.PrgRamSize + FMetadata.PrgNvRamSize);

  if (FMapperId = MAPPER_GTROM) or (FMapperId = MAPPER_HARATYLER) or
    (FMapperId = MAPPER_SACHEN_9602) or (FMapperId = MAPPER_4MROM512) or
    (FMapperId = MAPPER_RAINBOW) or
    (FMapperId = MAPPER_BANDAI_DATACH) or
    ((FMapperId = MAPPER_RACERMATE) and (FMetadata.Format = TRomFormat.INes)) then
    FMetadata.HasBattery := True;

  // Trainer data initializes the cartridge's CPU RAM before battery activation.
  // A persisted save, when present, subsequently takes precedence.
  if FMapper is TMapperGameDoctor then
  begin
    var Bios: TByteArray;
    if FMapperId = MAPPER_TURBO_GAME_DOCTOR then
      Bios := LoadTurboGameDoctorBios(RomName);
    TMapperGameDoctor(FMapper).ConfigureMedia(FMetadata.ChrRamSize, Trainer, Bios);
  end
  else if FMapper is TMapperMagicCard then
  begin
    FMetadata.HasBattery := False;
    FMetadata.PrgNvRamSize := 0;
    FMetadata.ChrNvRamSize := 0;
    FMetadata.PrgRamSize := $8000;
    FMetadata.ChrRamSize := $8000;
    if FMapperId = MAPPER_FFE_F8XXX then
      FMetadata.ChrRamSize := $40000;
    TMapperMagicCard(FMapper).ConfigureTrainer(Trainer);
  end
  else if FMapper is TMapperNesticle then
    TMapperNesticle(FMapper).InstallTrainer(Trainer)
  else
    for var i := 0 to High(Trainer) do
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
  var ExRamSize: Integer := 0;
  if FMapper is TMapperMmc5 then
    ExRamSize := TMapperMmc5(FMapper).ExRamSaveSize;
  var PrgSaveSize := FSaveSize - ExRamSize;
  var Waixing93C66 := (FMapperId = MAPPER_WAIXING164) or (FMapperId = MAPPER_WAIXING558);
  if (FMetadata.Format = TRomFormat.Nes20) and (FMapperId = MAPPER_WAIXING164) and
    (FSaveSize = 512) and (FMetadata.PrgNvRamSize <> 512) then
    raise ENesException.Create('Unsupported mapper 164 EEPROM size');

  if (FMetadata.Format = TRomFormat.Nes20) and (FMapperId <> MAPPER_NAMCO_163) and (FMapperId <> MAPPER_CHINA_ER_SAN2) and
    (FMapperId <> MAPPER_UNROM512) and (FMapperId <> MAPPER_RAINBOW512) and
    (FMapperId <> MAPPER_GTROM) and (FMapperId <> MAPPER_4MROM512) and (FMapperId <> MAPPER_BANDAI_DATACH) and (FMapperId <> MAPPER_RACERMATE) and (FMapperId <> MAPPER_FK23C) and
    (FMapperId <> MAPPER_SACHEN_9602) and (FMapperId <> MAPPER_RAINBOW) and
    (FMapperId <> MAPPER_RAINBOW13) and (FMapperId <> MAPPER_RAINBOW_PROTO) and (FMapperId <> MAPPER_RAINBOW_NROM) and
    (FMapperId <> MAPPER_KONAMI_QTA) and (FMapperId <> MAPPER_YUXING) and
    (FMapperId <> MAPPER_IMPACT_SOFT_406) and (FMapperId <> MAPPER_HARATYLER) and
    (FMapperId <> MAPPER_MINDKIDS_FPGA) and (FMapperId <> MAPPER_COOLGIRL) and
    not (FMapper is TMapperFlameCyclone) and not (FMapper is TMapperMmc1TwoMe) then
  begin
    if (FMetadata.ChrNvRamSize <> 0) or
      ((FMetadata.PrgRamSize <> 0) and (FMetadata.PrgNvRamSize <> 0) and
      not (Waixing93C66 and (FMetadata.PrgNvRamSize = 512) and (FSaveSize = 512)) and
      not ((FMapperId = MAPPER_BMC_JY104) and (FSaveSize = $100) and (FMetadata.PrgNvRamSize = $100)) and
      not ((FMapperId = MAPPER_BTL_UT1245A) and (FMetadata.PrgNvRamSize = UInt64(FSaveSize))) and
      not ((FMapperId = MAPPER_VT369_INVERTER_ROM) and (FMetadata.Submapper = 0) and
      ((FSaveSize = $200) or (FSaveSize = $400)) and (FMetadata.PrgNvRamSize = UInt64(FSaveSize))) and
      not ((FMapperId = MAPPER_MMC5) and (FMetadata.PrgNvRamSize = UInt64(PrgSaveSize))) and
      not ((FMapperId = MAPPER_MMC3_CHR_RAM_195) and (FMetadata.PrgRamSize = $1000) and
      (FMetadata.PrgNvRamSize = $2000) and (FSaveSize = $2000))) or
      (FMetadata.PrgNvRamSize > UInt64(PrgSaveSize)) then
      raise ENesException.Create('Unsupported NES 2.0 persistent memory layout');

    FSaveSize := Integer(FMetadata.PrgNvRamSize) + ExRamSize;
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
      var LegacyOregonTrailSave := (FMapperId = MAPPER_VT369_INVERTER_ROM) and
        (FRomIdentity = ROM_NES_OREGON_TRAIL_SHA1) and (FSaveSize = $400) and (Stream.Size = $200);
      var LegacyTwoMeSave := (FMapper is TMapperMmc1TwoMe) and
        (FMetadata.PrgNvRamSize >= $2000) and (Stream.Size = $2000);
      var LegacyMmc5Save := (ExRamSize <> 0) and (PrgSaveSize <> 0) and (Stream.Size = PrgSaveSize);
      var LegacyNesosSave := (FMapperId = MAPPER_MMC3) and (FSaveSize = $800) and
        (Stream.Size = $2000) and IsNesosRom(FRomIdentity);
      if (Stream.Size <> FSaveSize) and not LegacyOregonTrailSave and not LegacyTwoMeSave and
        not LegacyMmc5Save and not LegacyNesosSave then
        raise ENesException.CreateFmt('Invalid save size: %s (expected %d bytes)', [Path, FSaveSize]);

      if LegacyOregonTrailSave then
        FillChar(Memory[$200], $200, $FF);
      if LegacyMmc5Save then
        FillChar(Memory[PrgSaveSize], ExRamSize, 0);
      if LegacyNesosSave then
        ReadExact(Stream, Memory[0], FSaveSize)
      else
        ReadExact(Stream, Memory[0], Integer(Stream.Size));
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

procedure TCartridge.Reset(ColdStart: Boolean);
begin
  if FMapper <> nil then
    if ColdStart then
      FMapper.PowerOn
    else
      FMapper.Reset;
end;

function TCartridge.DiskSystem: TMapperFds;
begin
  Result := nil;
  if FMapper is TMapperFds then
    Result := TMapperFds(FMapper);
end;

function TCartridge.LoadTurboGameDoctorBios(const RomName: string): TByteArray;
begin
  Result := nil;
  for var Folder in TArray<string>.Create(ExtractFilePath(RomName), TPath.Combine(FStorage.Root, 'bios')) do
  begin
    if Folder = '' then
      Continue;
    var Path := TPath.Combine(Folder, TURBO_GAME_DOCTOR_BIOS_FILE);
    if not FStorage.Exists(Path) then
      Continue;
    var Input := FStorage.OpenRead(Path);
    try
      case Input.Size of
        $800:
          Input.Position := 0;
        $1000:
          Input.Position := $800;
      else
        raise ENesException.Create('Invalid Turbo Game Doctor BIOS size');
      end;
      SetLength(Result, $800);
      ReadExact(Input, Result[0], Length(Result));
    finally
      Input.Free;
    end;
    Exit;
  end;
end;

function TCartridge.LoadFdsBios(const RomName: string): TByteArray;
begin
  var ConfigPath := FStorage.ConfigFile('nes');
  var Path := FFdsBiosFile;
  if not FFdsBiosConfigured then
  begin
    var Ini := FStorage.ReadConfig(ConfigPath);
    try
      Path := Ini.ReadString('FDS', 'BIOSFile', '');
    finally
      Ini.Free;
    end;
  end;
  if Path = '' then
    for var Candidate in TArray<string>.Create(TPath.Combine(ExtractFilePath(RomName), 'disksys.rom'), TPath.Combine(FStorage.RomFolder('nes'), 'disksys.rom'), TPath.Combine(ExtractFilePath(ConfigPath), 'disksys.rom')) do
      if FStorage.Exists(Candidate) then
      begin
        Path := Candidate;
        Break;
      end;
  if Path = '' then
    Exit(LoadBuiltinFdsBIOS);
  if not FStorage.Exists(Path) then
    raise ENesException.CreateFmt('FDS BIOS file not found: %s', [Path]);
  var Input := FStorage.OpenRead(Path);
  try
    if Input.Size <> $2000 then
      raise ENesException.CreateFmt('FDS BIOS must be exactly 8192 bytes: %s', [Path]);
    SetLength(Result, $2000);
    Input.ReadBuffer(Result[0], Length(Result));
  finally
    Input.Free;
  end;
end;

procedure TCartridge.DescribeStudyBox;
begin
  FMetadata.MapperId := MAPPER_STUDY_BOX;
  FMetadata.PrgRomSize := STUDY_BOX_BIOS_SIZE;
  FMetadata.PrgRamSize := $10000;
  FMetadata.ChrRamSize := $2000;
  FMetadata.MirrorMode := TMirrorMode.FourScreen;
  FMetadata.Timing := TRomTiming.NTSC;
end;

function TCartridge.LoadStudyBoxBios(const RomName: string): TByteArray;
const
  BiosSHA1 = '3a5683e8c417a07c3252e1db4a054effdf75cb6e';
begin
  var FileName := RomName;
  {$IFDEF MSWINDOWS}
  FileName := FileName.Replace('/', PathDelim);
  {$ENDIF}
  for var Folder in TArray<string>.Create(ExtractFilePath(FileName), TPath.Combine(FStorage.Root, 'bios')) do
  begin
    if Folder = '' then
      Continue;
    var Path := TPath.Combine(Folder, STUDY_BOX_BIOS_FILE);
    if not FStorage.Exists(Path) then
      Continue;
    var Input := FStorage.OpenRead(Path);
    try
      if Input.Size <> STUDY_BOX_BIOS_SIZE then
        raise ENesException.CreateFmt('StudyBox BIOS must contain the raw SBX-01 program ROM: %s', [Path]);
      SetLength(Result, STUDY_BOX_BIOS_SIZE);
      ReadExact(Input, Result[0], Length(Result));
      var Hash := THashSHA1.Create;
      Hash.Update(Result[0], Length(Result));
      if not SameText(Hash.HashAsString, BiosSHA1) then
        raise ENesException.CreateFmt('Unrecognized StudyBox SBX-01 BIOS: %s', [Path]);
    finally
      Input.Free;
    end;
    Exit;
  end;
  raise ENesException.Create('Place StudyBox.bin beside the tape image or in the BIOS folder');
end;

function TCartridge.MatchesSnapshotSubmapper(Submapper, Version: Integer): Boolean;
begin
  if Submapper = FMetadata.Submapper then
    Exit(True);
  if (Submapper <> 0) or (FMetadata.Format <> TRomFormat.INes) then
    Exit(False);
  // Early MC-ACC states stored the compatibility submapper.
  if (Version < 26) and (FMapperId = MAPPER_MMC3) and (FMetadata.Submapper = 3) then
    Exit(True);

  if (FMapperId = MAPPER_CAMERICA) and not FMetadata.HasTrainer then
  begin
    var CamericaBoard: TCamericaBoard;
    Exit(TryResolveLegacyCamerica(FRomIdentity, CamericaBoard) and
      (CamericaBoard.Submapper = FMetadata.Submapper));
  end;

  if (Version < MAGIC_CARD_STATE_VERSION) and (FMapperId = MAPPER_FFE_F4XXX) then
    Exit(True);

  // Exact legacy discrete boards used the same serialized latch and RAM layout.
  var Board: TLegacyDiscreteBoard;
  Result := not FMetadata.HasTrainer and
    TryResolveLegacyDiscreteBoard(FMapperId, FRomIdentity, Board) and
    (Board.Submapper = FMetadata.Submapper);
end;

function TCartridge.CanMigrateSnapshotMapper(MapperId: Integer): Boolean;
begin
  if (FMetadata.Format <> TRomFormat.INes) or (MapperId <> FHeaderMapperId) then
    Exit(False);
  if (FMapperId = MAPPER_FFE_F4XXX) and not FMetadata.HasTrainer then
    Exit(MapperId in [MAPPER_CNROM, MAPPER_UXROM]);
  if (FMapperId = MAPPER_NROM) and not FMetadata.HasTrainer then
    Exit(MapperId in [MAPPER_MMC1, MAPPER_UXROM, MAPPER_CNROM, MAPPER_MULTICART_15]);
  if (FMapperId = MAPPER_MMC3_245) and (MapperId = MAPPER_MMC3) then
    Exit(FRomIdentity = ROM_NES_F003_DRAGON_QUEST_VII_SHA1);
  Result := ((MapperId = MAPPER_CNROM) and (FMapperId = MAPPER_HES_148)) or
    ((MapperId = MAPPER_UXROM) and (FMapperId = MAPPER_CAMERICA));
end;

function TCartridge.MatchesSnapshotIdentity(const Identity: string; Version: Integer): Boolean;
begin
  Result := (Identity = FRomIdentity) or ((Version < MAGIC_CARD_STATE_VERSION) and
    (FMapper is TMapperMagicCard) and (FPreTrainerRomIdentity <> '') and (Identity = FPreTrainerRomIdentity)) or
    ((Version < 39) and
    (FMapperId in [MAPPER_JALECO_SS88006, MAPPER_JALECO_JF17, MAPPER_JALECO_JF13, MAPPER_JALECO_JF19]) and
    ((FMapperId <> MAPPER_JALECO_JF13) or (Version < 38)) and
    (FPreSpeechRomIdentity <> '') and (Identity = FPreSpeechRomIdentity));
end;

function TCartridge.LoadFcnsFirmware(const RomName: string; const Names: array of string; Size: Integer): TBytes;
begin
  var FileName := RomName;
  {$IFDEF MSWINDOWS}
  FileName := FileName.Replace('/', PathDelim);
  {$ENDIF}
  var CardFolder := ExtractFilePath(FileName);
  var FirmwareFolder := '';
  if CardFolder <> '' then
    FirmwareFolder := TPath.Combine(CardFolder, 'Firmware');
  for var Folder in TArray<string>.Create(CardFolder, FirmwareFolder, TPath.Combine(FStorage.Root, 'bios')) do
  begin
    if Folder = '' then
      Continue;
    for var Name in Names do
    begin
      var Path := TPath.Combine(Folder, Name);
      if not FStorage.Exists(Path) then
        Continue;
      var Input := FStorage.OpenRead(Path);
      try
        if Input.Size <> Size then
          raise ENesException.CreateFmt('Invalid FCNS firmware size: %s', [Path]);
        SetLength(Result, Size);
        ReadExact(Input, Result[0], Size);
      finally
        Input.Free;
      end;
      Exit;
    end;
  end;
  raise ENesException.CreateFmt('FCNS requires %s beside the card, in Firmware, or in the BIOS folder', [Names[0]]);
end;

procedure TCartridge.LoadStudyBoxTape(Stream: TStream; const RomName: string);
begin
  var Bios := LoadStudyBoxBios(RomName);
  var Media := TStudyBoxMedia.Load(Stream, Bios);
  FMapper := TMapperStudyBox.Create(Bios, Media);
  FRomIdentity := Media.Identity;
  FMapperId := MAPPER_STUDY_BOX;
  FHeaderMapperId := FMapperId;
  FMetadata.Format := TRomFormat.StudyBox;
  DescribeStudyBox;
  FValid := True;
end;

procedure TCartridge.ConfigureFdsBIOS(const FileName: string);
begin
  FFdsBiosFile := FileName.Trim;
  FFdsBiosConfigured := True;
end;

procedure TCartridge.LoadDisk(Stream: TStream; const RomName: string);
begin
  var Bios := LoadFdsBios(RomName);
  var Media := ReadFdsMedia(Stream, RomName);
  try
    FMapper := TMapperFds.Create(Media, Bios);
    FRomIdentity := Media.Identity;
    Media := nil;
  finally
    Media.Free;
  end;
  FMapperId := FDS_MAPPER_ID;
  FHeaderMapperId := FMapperId;
  FMetadata.Format := TRomFormat.FDS;
  FMetadata.MapperId := FMapperId;
  FMetadata.PrgRamSize := $8000;
  FMetadata.ChrRamSize := $2000;
  FMetadata.PrgRomSize := $2000;
  FMetadata.MirrorMode := TMirrorMode.Vertical;
  FMetadata.Timing := TRomTiming.NTSC;
  FMetadata.HasBattery := True;
  FValid := True;
end;

procedure TCartridge.OpenDisk(const FileName, SaveDirectory: string);
begin
  var Floppy: TYuxingFloppy := nil;
  if FMapper is TMapperYuxing then
    Floppy := TMapperYuxing(FMapper).Floppy
  else if FMapper is TMapperSuborSb2000 then
    Floppy := TMapperSuborSb2000(FMapper).Floppy;
  if Floppy <> nil then
  begin
    var Input := FStorage.OpenRead(FileName);
    try
      if (Input.Size <> 737280) and (Input.Size <> 1228800) and (Input.Size <> 1474560) then
        raise ENesException.Create('Unsupported NES floppy size');
      var Image: TByteArray;
      SetLength(Image, Integer(Input.Size));
      ReadExact(Input, Image[0], Length(Image));
      Floppy.Mount(Image, ExtractFileName(FileName));
    finally
      Input.Free;
    end;
    Exit;
  end;
  var Disk := DiskSystem;
  if Disk = nil then
    raise ENesException.Create('No Famicom Disk System is connected');
  var Stream := FStorage.OpenRead(FileName);
  var Media: TFdsMedia := nil;
  try
    Media := ReadFdsMedia(Stream, FileName);
    SaveBattery;
    // Validate the replacement save before touching the running session.
    var Path := FStorage.GamePath(SaveDirectory, FileName, Media.Identity, '.sav');
    if FStorage.Exists(Path) then
      Media.LoadMemory(TByteArray(FStorage.ReadBytes(Path)));
    var Memory := Media.SaveMemory;
    Disk.ReplaceMedia(Media);
    Media := nil;
    FRomFileName := FileName;
    FLastSaveMemory := Memory;
    FSaveSize := Length(Memory);
    FSaveFileName := Path;
  finally
    Media.Free;
    Stream.Free;
  end;
end;

function TCartridge.ReadFdsMedia(Stream: TStream; const FileName: string): TFdsMedia;
begin
  var Data := ReadRomData(Stream);
  // The main registry may already have extracted the image while retaining
  // its archive filename. Media replacement also accepts the archive itself.
  var Probe := TBytesStream.Create(Data);
  var IsPacked: Boolean;
  try
    IsPacked := HasMediaArchiveSignature(Probe);
  finally
    Probe.Free;
  end;
  if TFdsMedia.HasSignature(Data) or not IsPacked then
    Exit(TFdsMedia.Create(TByteArray(Data), SameText(ExtractFileExt(FileName), '.qd')));
  var Input := TBytesStream.Create(Data);
  var Archive: IArchiveContainer;
  try
    Archive := OpenMediaArchive(Input, FileName, FStorage);
    var Candidate := -1;
    for var I := 0 to Archive.Count - 1 do
      if not Archive.Entries[I].IsDirectory and
        (SameText(ExtractFileExt(Archive.Entries[I].Name), '.fds') or
        SameText(ExtractFileExt(Archive.Entries[I].Name), '.qd')) then
      begin
        if Candidate >= 0 then
          raise ENesException.Create('FDS archive must contain exactly one disk image');
        Candidate := I;
      end;
    if Candidate < 0 then
      raise ENesException.Create('FDS archive must contain exactly one disk image');
    if Archive.Entries[Candidate].Size > 64 * 1024 * 1024 then
      raise ENesException.Create('FDS archive image exceeds 64 MiB');
    var Name := Archive.Entries[Candidate].Name;
    Archive.Read(Candidate, Data);
    Result := TFdsMedia.Create(TByteArray(Data), SameText(ExtractFileExt(Name), '.qd'));
  finally
    Archive := nil;
    Input.Free;
  end;
end;

end.

