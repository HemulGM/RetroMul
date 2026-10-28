unit NeoGeo.Cartridge;

interface

uses
  System.SysUtils, System.Classes, Core.Storage, Core.CD.Disc;

const
  ROM_SYSTEM_NEOGEO = 'neogeo';
  ROM_SYSTEM_NEOGEOCD = 'neogeocd';
  ROM_SYSTEM_NEOGEOAES = 'neogeoaes';
  ROM_CORE_ID_NEOGEO = 'NEOGEO';
  ROM_CORE_ID_NEOGEOCD = 'NEOGEOCD';

const
  ROM_EXTENSION_ZIP = '.zip';
  ROM_EXTENSION_7Z = '.7z';

const
  NEOGEO_ROM_SIGNATURE: AnsiString = 'NEO' + #1;
  NEOGEO_ROM_MAGIC_SIZE = 3;
  NEOGEO_ROM_HEADER_SIZE = $1000;
  NEOGEO_ROM_MAX_CONTAINER_SIZE = 256 * 1024 * 1024;
  NEOGEO_ROM_REGION_COUNT = 5;
  NEOGEO_ROM_REGION_SIZES_OFFSET = 4;
  NEOGEO_ROM_NAME_OFFSET = $30;
  NEOGEO_ROM_NAME_SIZE = 33;

const
  NG_MAX_CONTAINER = NEOGEO_ROM_MAX_CONTAINER_SIZE;

type
  TNeoGeoCartridge = class
  private
    procedure LoadNeo(const Data: TBytes);
    procedure LoadZip(const Data: TBytes; const Storage: IStorage; const Location: string);
    procedure Validate;
  public
    Disc: TCDDisc;
    CDZ: Boolean;
    AES, PAL, CardInserted, CardReadOnly: Boolean;
    CardSize: Integer;
    Region, CabinetDIPs: Byte;
    ProgramROM, FixedROM, AudioROM, SamplesA, SamplesB, SpriteROM: TBytes;
    BIOS, FixedBIOS, AudioBIOS, ZoomROM: TBytes;
    SetName: string;
    FixedBankType: Integer;
    Protection: string;
    constructor Create(const Data: TBytes; const Storage: IStorage = nil; const Location: string = '');
    constructor CreateCD(Stream: TStream; const Storage: IStorage; const Location: string; const BIOSName: string = ''; const Model: string = 'auto');
    destructor Destroy; override;
    procedure ConfigureHardware(const Storage: IStorage; const Location, Model, Country, BIOSName: string);
    function Identity: TBytes;
    function MasterClock: Integer;
    function FrameLines: Integer;
    function VideoHeight: Integer;
  end;

function ReadNeoGeoData(Stream: TStream): TBytes;

implementation

uses
  Core.Archive.SevenZip, System.Zip, System.IOUtils, System.Hash, NeoGeo.RomSets,
  NeoGeo.Protection, NeoGeo.Bootleg, NeoGeo.PCB;

{$R NeoGeo.Firmware.res}

function ReadNeoGeoData(Stream: TStream): TBytes;
begin
  if Stream = nil then
    raise EArgumentNilException.Create('Stream');

  var Buffer: array[0..65535] of Byte;
  var Memory := TMemoryStream.Create;
  try
    while True do
    begin
      var Count := Stream.Read(Buffer, SizeOf(Buffer));
      if Count = 0 then
        Break;

      if (Count < 0) or (Memory.Size + Count > NG_MAX_CONTAINER) then
        raise EReadError.Create('Neo Geo container exceeds 256 MiB');

      Memory.WriteBuffer(Buffer, Count);
    end;
    SetLength(Result, Memory.Size);
    Memory.Position := 0;
    if Length(Result) > 0 then
      Memory.ReadBuffer(Result[0], Length(Result));
  finally
    Memory.Free;
  end;
end;

function ResourceBytes(const Name: string): TBytes;
begin
  var Stream := TResourceStream.Create(HInstance, Name, PChar(10));
  try
    SetLength(Result, Stream.Size);
    Stream.ReadBuffer(Result[0], Length(Result));
  finally
    Stream.Free;
  end;
end;

procedure SwapWords(var Data: TBytes);
begin
  if Odd(Length(Data)) then
    raise EReadError.Create('Odd Neo Geo 68000 ROM size');

  for var i := 0 to Length(Data) div 2 - 1 do
  begin
    var B := Data[i * 2];
    Data[i * 2] := Data[i * 2 + 1];
    Data[i * 2 + 1] := B;
  end;
end;

constructor TNeoGeoCartridge.Create(const Data: TBytes; const Storage: IStorage; const Location: string);
begin
  inherited Create;
  Region := 2;
  CabinetDIPs := $FF;
  CardSize := 2048;
  BIOS := ResourceBytes('NG_MVS_BIOS');
  SwapWords(BIOS);
  FixedBIOS := ResourceBytes('NG_FIX_BIOS');
  AudioBIOS := ResourceBytes('NG_AUDIO_BIOS');
  ZoomROM := ResourceBytes('NG_ZOOM');
  if (Length(Data) >= Length(NEOGEO_ROM_SIGNATURE)) and
    CompareMem(@Data[0], PAnsiChar(NEOGEO_ROM_SIGNATURE), NEOGEO_ROM_MAGIC_SIZE) then
    LoadNeo(Data)
  else
    LoadZip(Data, Storage, Location);
  Validate;
end;

constructor TNeoGeoCartridge.CreateCD(Stream: TStream; const Storage: IStorage; const Location, BIOSName, Model: string);
begin
  inherited Create;
  Region := 2;
  CabinetDIPs := $FF;
  CardSize := 2048;
  Disc := TCDDisc.Create(Stream, Storage, Location);
  if Disc.Track(1).Audio then
    raise EReadError.Create('Neo Geo CD requires its data track first');

  Disc.RequireISO9660;
  ZoomROM := ResourceBytes('NG_ZOOM');

  // The CD has writable graphics, sound and program memory, no cartridge ROM.
  SetLength(ProgramROM, $200000);
  SetLength(SpriteROM, $400000);
  SetLength(FixedROM, $20000);
  SetLength(AudioROM, $10000);
  SetLength(SamplesA, $100000);
  SamplesB := SamplesA;
  var SourceName := Location;
  if Location.StartsWith('content://', True) then
    SourceName := Storage.Describe(Location).Name;
  SetName := ChangeFileExt(ExtractFileName(SourceName), '');
  var SourceFolder := ExtractFilePath(Location);
  if Location.StartsWith('content://', True) then
    SourceFolder := Location;
  var Folders := TArray<string>.Create(SourceFolder,
    Storage.RomFolder(ROM_SYSTEM_NEOGEOCD),
    TPath.Combine(Storage.Root, 'bios'), Storage.Root);
  var Names := TArray<string>.Create('neocd.bin', 'neocd_z.rom', 'neocd_t.bin', 'neocd_f.bin', 'top-sp1.bin', 'neocd_t.rom', 'front-sp1.bin', 'neocd_f.rom');
  if BIOSName <> '' then
    Names := TArray<string>.Create(BIOSName)
  else if Model = 'cdz' then
    Names := TArray<string>.Create('neocd_z.rom', 'neocd.bin')
  else if Model = 'front' then
    Names := TArray<string>.Create('front-sp1.bin', 'neocd_f.rom', 'neocd_f.bin')
  else if Model = 'top' then
    Names := TArray<string>.Create('top-sp1.bin', 'neocd_t.rom', 'neocd_t.bin');
  for var Folder in Folders do
    for var Name in Names do
    begin
      var Path := '';
      if Name.Contains(':') then
        Path := Name
      else if Folder.StartsWith('content://', True) then
      begin
        try
          Path := CDSibling(Storage, Location, Name);
        except
          on E: EReadError do
            Continue;
        end;
      end
      else
        Path := TPath.Combine(Folder, Name);
      if not Storage.Exists(Path) then
        Continue;

      var Input := Storage.OpenRead(Path);
      try
        if Input.Size <> $80000 then
          raise EReadError.Create('Neo Geo CD BIOS must be 512 KiB: ' + Name);

        SetLength(BIOS, $80000);
        Input.ReadBuffer(BIOS[0], Length(BIOS));
      finally
        Input.Free;
      end;
      // Accept chip byte order and normalized big-endian dumps.
      if (BIOS[4] <> 0) or (BIOS[5] <> $C0) then
        SwapWords(BIOS);
      if (BIOS[4] <> 0) or (BIOS[5] <> $C0) then
        raise EReadError.Create('Invalid Neo Geo CD BIOS reset vector');

      CDZ := (BIOS[$6D] = $C0) and (BIOS[$6E] = $A3) and (BIOS[$6F] = $E8);
      Exit;
    end;

  raise EReadError.Create('Neo Geo CD BIOS missing: place neocd.bin (512 KiB CD/CDZ) beside the image or in the neogeocd ROM folder');
end;

procedure TNeoGeoCartridge.ConfigureHardware(const Storage: IStorage; const Location, Model, Country, BIOSName: string);

  function ReadBIOS(const Name: string): TBytes;
  begin
    Result := nil;
    if Name = '' then
      Exit;

    if Storage.Exists(Name) then
      Result := Storage.ReadBytes(Name)
    else
    begin
      for var Folder in TArray<string>.Create(ExtractFilePath(Location), Storage.RomFolder(ROM_SYSTEM_NEOGEO), Storage.RomFolder(ROM_SYSTEM_NEOGEOAES), Storage.RomFolder(ROM_SYSTEM_NEOGEOCD), TPath.Combine(Storage.Root, 'bios')) do
      begin
        if Storage.Exists(TPath.Combine(Folder, Name)) then
          Exit(Storage.ReadBytes(TPath.Combine(Folder, Name)));

        var ZipPath := TPath.Combine(Folder, 'neogeo.zip');
        if not Storage.Exists(ZipPath) then
          ZipPath := ChangeFileExt(ZipPath, ROM_EXTENSION_7Z);
        if not Storage.Exists(ZipPath) then
          Continue;

        var Input := Storage.OpenRead(ZipPath);
        var Zip := TZipFile.Create;
        try
          if SameText(ExtractFileExt(ZipPath), ROM_EXTENSION_7Z) then
          begin
            var PackedData := SevenZipAsZip(ReadNeoGeoData(Input));
            FreeAndNil(Input);
            Input := TBytesStream.Create(PackedData);
          end;
          Zip.Open(Input, zmRead);
          for var I := 0 to Zip.FileCount - 1 do
            if SameText(ExtractFileName(Zip.FileNames[I]), Name) then
            begin
              Zip.Read(I, Result);
              Exit;
            end;
        finally
          Zip.Free;
          Input.Free;
        end;
      end;
    end;
  end;

begin
  if Storage = nil then
    raise EArgumentNilException.Create('Storage');

  if SameText(Country, 'japan') then
    Region := 0
  else if SameText(Country, 'usa') then
    Region := 1
  else if SameText(Country, 'europe') then
    Region := 2;
  AES := (Disc = nil) and SameText(Model, 'aes');
  var Names: TArray<string>;
  if BIOSName <> '' then
    Names := TArray<string>.Create(BIOSName)
  else if AES then
    if Region = 0 then
      Names := TArray<string>.Create('neo-po.bin', 'neo-po.sp1', 'uni-bios_2_3.rom')
    else
      Names := TArray<string>.Create('neo-epo.sp1', 'neo-epo.bin', 'uni-bios_2_3.rom')
  else if Disc <> nil then
    Names := nil
  else if (Country <> '') and not SameText(Country, 'auto') then
    case Region of
      0:
        Names := TArray<string>.Create('vs-bios.rom', 'sp-j2.rom');
      1:
        Names := TArray<string>.Create('usa_2slt.bin');
      2:
        Names := TArray<string>.Create('sp-s2.sp1');
    end;
  if Length(Names) > 0 then
  begin
    var Bytes: TBytes;
    for var Name in Names do
    begin
      Bytes := ReadBIOS(Name);
      if Length(Bytes) > 0 then
        Break;
    end;
    if (Length(Bytes) = 0) and AES and (BIOSName = '') then
      if Region = 0 then
        Bytes := ResourceBytes('NG_AES_BIOS_JP')
      else
        Bytes := ResourceBytes('NG_AES_BIOS_EU');
    if Length(Bytes) = 0 then
      raise EReadError.Create('Neo Geo BIOS not found: ' + string.Join(', ', Names));

    if ((Disc = nil) and (Length(Bytes) <> $20000) and (Length(Bytes) <> $80000)) or
      ((Disc <> nil) and (Length(Bytes) <> $80000)) then
      raise EReadError.Create('Invalid Neo Geo BIOS size');

    if (Bytes[4] <> 0) or (Bytes[5] <> $C0) then
      SwapWords(Bytes);
    if (Bytes[4] <> 0) or (Bytes[5] <> $C0) then
      raise EReadError.Create('Invalid Neo Geo BIOS vector');

    BIOS := Bytes;
    if Disc <> nil then
      CDZ := (BIOS[$6D] = $C0) and (BIOS[$6E] = $A3) and (BIOS[$6F] = $E8);
  end;
  if (Disc = nil) and (Length(BIOS) > $401) then
  begin
    // Game ROMs and container extensions do not select the machine type.
    // Original system ROMs identify AES at $400 = 0 and MVS at $400 = $80.
    // Automatic follows the loaded BIOS; the bundled default is MVS.
    if (Model = '') or SameText(Model, 'auto') then
      AES := BIOS[$400] = 0;
    if (Country = '') or SameText(Country, 'auto') or (BIOS[$400] <> 0) then
      Region := BIOS[$401] and 3
    else if AES and (BIOS[$400] = 0) then
      // The original AES firmware stores its nationality in this data byte.
      // Configure the loaded copy; never modify the external image or code.
      BIOS[$401] := Region;
  end;
  if (Disc <> nil) and not SameText(Model, 'auto') and (Model <> '') then
    if SameText(Model, 'cdz') <> CDZ then
      raise EReadError.Create('Neo Geo CD model and BIOS do not match');
end;

destructor TNeoGeoCartridge.Destroy;
begin
  Disc.Free;
  inherited;
end;

procedure TNeoGeoCartridge.LoadNeo(const Data: TBytes);

  function SizeAt(Offset: Integer): Integer;
  begin
    var Size := UInt64(Data[Offset]) or (UInt64(Data[Offset + 1]) shl 8) or
      (UInt64(Data[Offset + 2]) shl 16) or (UInt64(Data[Offset + 3]) shl 24);

    if Size > NG_MAX_CONTAINER then
      raise EReadError.Create('Oversized Neo Geo region');

    Result := Integer(Size);
  end;

begin
  if (Length(Data) < NEOGEO_ROM_HEADER_SIZE) or
    (Data[NEOGEO_ROM_MAGIC_SIZE] <> Ord(NEOGEO_ROM_SIGNATURE[NEOGEO_ROM_MAGIC_SIZE + 1])) then
    raise EReadError.Create('Unsupported or truncated NeoSD NEO header');

  var Sizes: array[0..NEOGEO_ROM_REGION_COUNT - 1] of Integer;
  var Total: Int64 := NEOGEO_ROM_HEADER_SIZE;
  for var i := 0 to High(Sizes) do
  begin
    Sizes[i] := SizeAt(NEOGEO_ROM_REGION_SIZES_OFFSET + i * SizeOf(Cardinal));
    Inc(Total, Sizes[i]);
  end;

  if Total <> Length(Data) then
    raise EReadError.Create('NeoSD region sizes do not match the file');

  var Offset := NEOGEO_ROM_HEADER_SIZE;
  ProgramROM := Copy(Data, Offset, Sizes[0]);
  Inc(Offset, Sizes[0]);
  FixedROM := Copy(Data, Offset, Sizes[1]);
  Inc(Offset, Sizes[1]);
  AudioROM := Copy(Data, Offset, Sizes[2]);
  Inc(Offset, Sizes[2]);
  SamplesA := Copy(Data, Offset, Sizes[3]);
  Inc(Offset, Sizes[3]);
  SamplesB := SamplesA;
  SpriteROM := Copy(Data, Offset, Sizes[4]);

  // NeoSD stores P in chip order; accept already normalized homebrew images too.
  if (Length(ProgramROM) > $106) and (ProgramROM[$100] = Ord('E')) and (ProgramROM[$101] = Ord('N')) then
    SwapWords(ProgramROM);
  SetName := TEncoding.ASCII.GetString(Data, NEOGEO_ROM_NAME_OFFSET, NEOGEO_ROM_NAME_SIZE).Trim([#0, ' ']);
end;

procedure TNeoGeoCartridge.LoadZip(const Data: TBytes; const Storage: IStorage; const Location: string);
var
  Archive, Parent, Firmware: TZipFile;
  MainStream, ParentStream, FirmwareStream: TStream;
  Ancestors: TArray<TZipFile>;
  AncestorStreams: TArray<TStream>;

  function FindFile(Zip: TZipFile; const Name: string): Integer;
  begin
    Result := -1;
    if Zip = nil then
      Exit;

    for var i := 0 to Zip.FileCount - 1 do
      if SameText(ExtractFileName(Zip.FileNames[i]), Name) then
        Exit(i);
  end;

  function ReadEntry(Zip: TZipFile; Index: Integer): TBytes;
  begin
    var Header := Zip.FileInfo[Index];
    if Header.UncompressedSize > 64 * 1024 * 1024 then
      raise EReadError.Create('Neo Geo ZIP member exceeds 64 MiB');

    Zip.Read(Index, Result);
  end;

  function Chip(const Name, CRC: string): TBytes;
  begin
    var Zip := Archive;
    var Index := FindFile(Zip, Name);
    if Index < 0 then
    begin
      Zip := Parent;
      Index := FindFile(Zip, Name);
    end;

    if (Index < 0) or not SameText(IntToHex(Zip.FileInfo[Index].CRC32, 8), CRC) then
    begin
      // CRC aliases allow older ROM-set filenames, without guessing chip order.
      var Candidates := TArray<TZipFile>.Create(Archive, Parent);
      Candidates := Candidates + Ancestors;
      for var Candidate in Candidates do
        if Candidate <> nil then
          for var i := 0 to Candidate.FileCount - 1 do
            if SameText(IntToHex(Candidate.FileInfo[i].CRC32, 8), CRC) then
            begin
              Zip := Candidate;
              Index := i;
              Break;
            end;
    end;

    if Index < 0 then
      raise EReadError.Create('Missing Neo Geo ROM: ' + Name);

    if not SameText(IntToHex(Zip.FileInfo[Index].CRC32, 8), CRC) then
      raise EReadError.Create('Incorrect Neo Geo ROM CRC: ' + Name);

    Result := ReadEntry(Zip, Index);
  end;

  procedure OpenSibling(const Name: string; out Zip: TZipFile; out Stream: TStream);
  begin
    if (Storage = nil) or (Location = '') or Location.StartsWith('content://') then
      Exit;

    var Path := TPath.Combine(ExtractFilePath(Location.Replace('/', PathDelim)), Name + ROM_EXTENSION_ZIP);
    if not Storage.Exists(Path) then
      Path := ChangeFileExt(Path, ROM_EXTENSION_7Z);
    if not Storage.Exists(Path) then
      Exit;

    Stream := Storage.OpenRead(Path);
    if SameText(ExtractFileExt(Path), ROM_EXTENSION_7Z) then
    begin
      var PackedData: TBytes;
      try
        PackedData := SevenZipAsZip(ReadNeoGeoData(Stream));
      finally
        FreeAndNil(Stream);
      end;
      Stream := TBytesStream.Create(PackedData);
    end;
    Zip := TZipFile.Create;
    Zip.Open(Stream, zmRead);
  end;

  procedure OverrideFirmware(const Name: string; var Target: TBytes; Swapped: Boolean);
  begin
    var Index := FindFile(Firmware, Name);
    if Index < 0 then
      Exit;

    var Bytes := ReadEntry(Firmware, Index);
    if Length(Bytes) <> $20000 then
      raise EReadError.Create('Incorrect system ROM size: ' + Name);

    if Swapped then
      SwapWords(Bytes);
    Target := Bytes;
  end;

  procedure Region(var Target: TBytes; const Rows: TArray<string>; const Name: string; Size: Integer);
  begin
    if (Size < 0) or (Size > 128 * 1024 * 1024) then
      raise EReadError.Create('Invalid Neo Geo region size');

    SetLength(Target, Size);
    for var Row in Rows do
    begin
      var F := Row.Split([',']);
      if (Length(F) <> 7) or (F[0] <> Name) then
        Continue;

      var Bytes := Chip(F[1], F[6]);
      var Dest := StrToInt(F[2]);
      var Count := StrToInt(F[3]);
      var Source := StrToInt(F[4]);
      var Step := 1;
      if F[5] = 'I' then
        Step := 2;

      var WordInterleave := (F[5] = 'D') or (F[5] = 'U');
      if (Source < 0) or (Count <= 0) or (Int64(Source) + Count > Length(Bytes)) or
        (Dest < 0) or (Int64(Dest) + Int64(Count - 1) * Step >= Size) then
        raise EReadError.Create('Truncated or invalid Neo Geo ROM: ' + F[1]);

      if WordInterleave and (Int64(Dest) + Int64(Count div 2 - 1) * 4 + 1 >= Size) then
        raise EReadError.Create('Truncated interleaved Neo Geo program');

      if ((F[5] = 'W') or WordInterleave) and (Odd(Count) or Odd(Source)) then
        raise EReadError.Create('Invalid word-swapped ROM');

      for var i := 0 to Count - 1 do
      begin
        var Input := i;
        if (F[5] = 'W') or (F[5] = 'D') then
          Input := i xor 1;
        var Output := Dest + i * Step;
        if WordInterleave then
          Output := Dest + (i div 2) * 4 + (i and 1);
        Target[Output] := Bytes[Source + Input];
      end;
    end;
  end;

begin
  Archive := nil;
  Parent := nil;
  Firmware := nil;
  MainStream := nil;
  ParentStream := nil;
  FirmwareStream := nil;
  try
    MainStream := TBytesStream.Create(Data);
    Archive := TZipFile.Create;
    Archive.Open(MainStream, zmRead);
    SetName := ChangeFileExt(ExtractFileName(Location.Replace('/', PathDelim)), '').ToLower;
    var CRCs: TArray<string>;
    SetLength(CRCs, Archive.FileCount);
    for var i := 0 to Archive.FileCount - 1 do
      CRCs[i] := IntToHex(Archive.FileInfo[i].CRC32, 8);

    var Description := SelectNeoGeoSet(SetName, CRCs);
    if Description = '' then
    begin
      SetName := IdentifyNeoGeoSet(Archive.FileNames);
      Description := SelectNeoGeoSet(SetName, CRCs);
    end;

    if Description = '' then
      raise EReadError.Create('Unknown Neo Geo ZIP ROM set; use a named MAME set or an unencrypted .neo image');

    var Parts := Description.Split(['|']);
    if Parts[2] <> '1' then
      raise ENotSupportedException.Create('Neo Geo cartridge protection or special hardware is not implemented: ' + SetName);

    if Parts[1] <> ROM_SYSTEM_NEOGEO then
      OpenSibling(Parts[1], Parent, ParentStream);
    var ParentName := Parts[1];
    for var Depth := 0 to 7 do
    begin
      var ParentDescription := NeoGeoSet(ParentName);
      if ParentDescription = '' then
        Break;

      var ParentParts := ParentDescription.Split(['|']);
      if (ParentParts[1] = ROM_SYSTEM_NEOGEO) or (ParentParts[1] = ParentName) then
        Break;

      ParentName := ParentParts[1];
      var Zip: TZipFile := nil;
      var Stream: TStream := nil;
      try
        OpenSibling(ParentName, Zip, Stream);
        if Zip = nil then
          Break;

        Ancestors := Ancestors + [Zip];
        AncestorStreams := AncestorStreams + [Stream];
      except
        Zip.Free;
        Stream.Free;
        raise;
      end;
    end;

    for var Zip in TArray<TZipFile>.Create(Parent) + Ancestors do
      if Zip <> nil then
        for var i := 0 to Zip.FileCount - 1 do
          CRCs := CRCs + [IntToHex(Zip.FileInfo[i].CRC32, 8)];

    Description := SelectNeoGeoSet(SetName, CRCs);
    Parts := Description.Split(['|']);
    OpenSibling(ROM_SYSTEM_NEOGEO, Firmware, FirmwareStream);
    OverrideFirmware('sp-s2.sp1', BIOS, True);
    OverrideFirmware('sfix.sfix', FixedBIOS, False);
    OverrideFirmware('sm1.sm1', AudioBIOS, False);
    OverrideFirmware('000-lo.lo', ZoomROM, False);
    var Rows := Parts[9].Split([';']);
    Region(ProgramROM, Rows, 'P', StrToInt(Parts[3]));
    Region(FixedROM, Rows, 'S', StrToInt(Parts[4]));
    Region(AudioROM, Rows, 'M', StrToInt(Parts[5]));
    Region(SamplesA, Rows, 'A', StrToInt(Parts[6]));
    Region(SamplesB, Rows, 'B', StrToInt(Parts[7]));
    Region(SpriteROM, Rows, 'C', StrToInt(Parts[8]));
    var Decrypted := '';
    if Length(Parts) > 12 then
      Decrypted := Parts[12];
    var OriginalP, OriginalS, OriginalM, OriginalA: TBytes;
    if Decrypted.Contains('P') then
      OriginalP := Copy(ProgramROM);
    if Decrypted.Contains('S') then
      OriginalS := Copy(FixedROM);
    if Decrypted.Contains('M') then
      OriginalM := Copy(AudioROM);
    if Decrypted.Contains('A') then
      OriginalA := Copy(SamplesA);
    var Machine := Parts[10];
    var PCB := (Machine = 'ms5pcb') or (Machine = 'svcpcb') or
      (Machine = 'svcpcba') or (Machine = 'kf2k3pcb');
    var KOFPCB := Machine = 'kf2k3pcb';
    if Machine = 'irrmaze' then
    begin
      BIOS := Chip('236-bios.sp1', '853e6b96');
      SwapWords(BIOS);
    end;
    if PCB then
    begin
      if KOFPCB then
        BIOS := Chip('spj.sp1', '148dd727')
      else
        BIOS := Chip('sp-4x.sp1', 'b4590283');
      SwapWords(BIOS);
      if KOFPCB then
        DecryptPCBBIOS(BIOS)
      else
        BIOS := Copy(BIOS, $20000, $20000);
      DecryptPCBGraphics(SpriteROM, KOFPCB);
      if Machine = 'ms5pcb' then
        Machine := 'mslug5'
      else if KOFPCB then
        Machine := 'kof2003'
      else
        Machine := 'svc';
      if not KOFPCB then
        SetLength(ProgramROM, $800000);
    end;

    // FIX bank wiring from MAME's cmc/sma/pcm2/pvc/kof2k2 cartridge profiles.
    // PCB and Matrimelee bootleg boards use the column-based bank table.
    if PCB or (Machine = 'matrimbl') or (Machine = 'matrim') or
      (Machine = 'kof2000') or (Machine = 'kof2000n') or (Machine = 'svc') or
      (Machine = 'kof2003') or (Machine = 'kof2003h') then
      FixedBankType := 2
    else if (Machine = 'kof99') or (Machine = 'garou') or (Machine = 'garouh') or
      (Machine = 'mslug3') or (Machine = 'mslug3a') or (Machine = 'mslug3h') or
      (Machine = 'zupapa') or (Machine = 'ganryu') or (Machine = 's1945p') or
      (Machine = 'preisle2') or (Machine = 'bangbead') or (Machine = 'nitd') or
      (Machine = 'sengoku3') or (Machine = 'kof99k') or (Machine = 'kof2001') or
      (Machine = 'jockeygp') or (Machine = 'mslug4') or (Machine = 'rotd') or
      (Machine = 'pnyaa') or (Machine = 'mslug5') or (Machine = 'samsho5') or
      (Machine = 'samsh5sp') then
      FixedBankType := 1;
    Protection := Machine;
    var Key := -1;
    var CMC50 := False;
    var ExtractFixed := True;
    var IsBootleg :=
      (Machine = 'svcboot') or (Machine = 'svcplus') or (Machine = 'cthd2k3') or
      (Machine = 'svcplusa') or (Machine = 'svcsplus') or (Machine = 'garoubl') or
      (Machine = 'ct2k3sp') or (Machine = 'ct2k3sa') or (Machine = 'kf10thep') or
      (Machine = 'kf2k5uni') or (Machine = 'kof10th') or (Machine = 'kof2002b') or
      (Machine = 'kf2k2mp') or (Machine = 'kof2km2') or (Machine = 'kf2k2mp2') or
      (Machine = 'kf2k3bl') or (Machine = 'kf2k3pl') or (Machine = 'kf2k3upl') or
      (Machine = 'kof2k4se') or (Machine = 'kog') or (Machine = 'lans2004') or
      (Machine = 'samsho5b') or (Machine = 'ms5plus') or (Machine = 'mslug3b6') or
      (Machine = 'matrimbl');

    if IsBootleg then
    begin
      DecryptBootleg(ProgramROM, FixedROM, AudioROM, SamplesA, SpriteROM, Machine, Parts[11] = '1');
    end
    else if (Machine = 'jockeygp') then
    begin
      Key := $AC;
      CMC50 := True;
    end
    else if (Machine = 'mslug5') or (Machine = 'svc') or (Machine = 'kof2003') or (Machine = 'kof2003h') then
    begin
      if KOFPCB then
        DecryptPVC(ProgramROM, 'kf2k3pcb')
      else
        DecryptPVC(ProgramROM, Machine);
      CMC50 := True;
      if Machine = 'mslug5' then
      begin
        Key := $19;
        DecryptPCM(SamplesA, 0, 2);
      end
      else if Machine = 'svc' then
      begin
        Key := $57;
        DecryptPCM(SamplesA, 0, 3);
      end
      else
      begin
        Key := $9D;
        DecryptPCM(SamplesA, 0, 5);
      end;
    end
    else if (Machine = 'kof99') or (Machine = 'garou') or (Machine = 'garouh') or
      (Machine = 'mslug3') or (Machine = 'mslug3a') or (Machine = 'kof2000') then
    begin
      DecryptSMA(ProgramROM, Machine);
      if Machine = 'kof99' then
        Key := 0
      else if (Machine = 'garou') or (Machine = 'garouh') then
      begin
        Key := 6;
      end
      else if Machine = 'kof2000' then
      begin
        Key := 0;
        CMC50 := True;
      end
      else
      begin
        Key := $AD;
      end;
    end
    else if Machine = 'mslug3h' then
    begin
      Key := $AD;
    end
    else if Machine = 'zupapa' then
      Key := $BD
    else if Machine = 'ganryu' then
      Key := $07
    else if Machine = 's1945p' then
      Key := $05
    else if Machine = 'preisle2' then
      Key := $9F
    else if Machine = 'bangbead' then
      Key := $F8
    else if Machine = 'nitd' then
      Key := $FF
    else if Machine = 'sengoku3' then
      Key := $FE
    else if Machine = 'kof99k' then
      Key := 0
    else if Machine = 'kof2001' then
    begin
      Key := $1E;
      CMC50 := True;
    end
    else if Machine = 'kof2000n' then
    begin
      Key := 0;
      CMC50 := True;
    end
    else if (Machine = 'mslug4') or (Machine = 'ms4plus') then
    begin
      Key := $31;
      CMC50 := True;
      ExtractFixed := Machine <> 'ms4plus';
      DecryptPCM(SamplesA, 8, 0);
    end
    else if Machine = 'rotd' then
    begin
      Key := $3F;
      CMC50 := True;
      DecryptPCM(SamplesA, 16, 0);
    end
    else if Machine = 'pnyaa' then
    begin
      Key := $2E;
      CMC50 := True;
      DecryptPCM(SamplesA, 4, 0);
    end
    else if (Machine = 'kof2002') or (Machine = 'kf2k2pls') then
    begin
      ReorderProgram(ProgramROM, 'kof2002');
      Key := $EC;
      CMC50 := True;
      ExtractFixed := Machine <> 'kf2k2pls';
      DecryptPCM(SamplesA, 0, 0);
    end
    else if Machine = 'matrim' then
    begin
      ReorderProgram(ProgramROM, Machine);
      Key := $6A;
      CMC50 := True;
      DecryptPCM(SamplesA, 0, 1);
    end
    else if Machine = 'samsho5' then
    begin
      ReorderProgram(ProgramROM, Machine);
      Key := $0F;
      CMC50 := True;
      DecryptPCM(SamplesA, 0, 4);
    end
    else if Machine = 'samsh5sp' then
    begin
      ReorderProgram(ProgramROM, Machine);
      Key := $0D;
      CMC50 := True;
      DecryptPCM(SamplesA, 0, 6);
    end;
    if Machine = 'kof98' then
      DecryptKOF98(ProgramROM);
    if Key >= 0 then
    begin
      if Decrypted.Contains('C') then
      begin
        if ExtractFixed and not Decrypted.Contains('S') then
          ExtractCMCText(SpriteROM, FixedROM);
        if CMC50 and (Parts[11] = '1') and not Decrypted.Contains('M') then
          DecryptCMCAudio(AudioROM);
      end
      else
        DecryptCMC(SpriteROM, FixedROM, AudioROM, Byte(Key), CMC50,
          ExtractFixed and not Decrypted.Contains('S'), (Parts[11] = '1') and not Decrypted.Contains('M'));
    end;
    if PCB then
    begin
      DecryptPCBFixed(SpriteROM, FixedROM, KOFPCB);
      if KOFPCB then
        for var i := 0 to High(AudioROM) do
          AudioROM[i] := Byte(BootlegBits(AudioROM[i], [5, 6, 1, 4, 3, 0, 7, 2]));
    end;
    if Decrypted.Contains('P') then
      ProgramROM := OriginalP;
    if Decrypted.Contains('S') then
      FixedROM := OriginalS;
    if Decrypted.Contains('M') then
      AudioROM := OriginalM;
    if Decrypted.Contains('A') then
      SamplesA := OriginalA;
    if (Machine = 'vliner') and (Length(AudioROM) = 0) then
      AudioROM := Copy(AudioBIOS);
    if Length(SamplesB) = 0 then
      SamplesB := SamplesA;
  finally
    Firmware.Free;
    for var Zip in Ancestors do
      Zip.Free;
    for var Stream in AncestorStreams do
      Stream.Free;
    Parent.Free;
    Archive.Free;
    FirmwareStream.Free;
    ParentStream.Free;
    MainStream.Free;
  end;
end;

procedure TNeoGeoCartridge.Validate;
begin
  if (Length(ProgramROM) < $200) or (Length(ProgramROM) > $900000) or
    Odd(Length(ProgramROM)) or (Length(FixedROM) < 32) or
    (Length(AudioROM) < $8000) or (Length(AudioROM) > $80000) or
    (Length(SpriteROM) < 128) or (Length(SpriteROM) mod 128 <> 0) then
    raise EReadError.Create('Invalid Neo Geo cartridge region sizes');
end;

function TNeoGeoCartridge.Identity: TBytes;
begin
  var Hardware: array[0..2] of Byte;
  Hardware[0] := Ord(AES);
  Hardware[1] := Ord(PAL);
  Hardware[2] := Region;
  if Disc <> nil then
  begin
    var Hash := THashSHA2.Create;
    Hash.Update(Disc.Identity);
    Hash.Update(BIOS);
    if Region <> 2 then
      Hash.Update(Hardware, SizeOf(Hardware));
    Exit(Hash.HashAsBytes);
  end;

  var Hash := THashSHA2.Create;
  Hash.Update(ProgramROM);
  Hash.Update(FixedROM);
  Hash.Update(AudioROM);
  Hash.Update(SamplesA);
  Hash.Update(SamplesB);
  Hash.Update(SpriteROM);
  Hash.Update(BIOS);
  Hash.Update(FixedBIOS);
  Hash.Update(AudioBIOS);
  Hash.Update(ZoomROM);
  if AES or PAL or (Region <> 2) then
    Hash.Update(Hardware, SizeOf(Hardware));
  Result := Hash.HashAsBytes;
end;

function TNeoGeoCartridge.MasterClock: Integer;
begin
  Result := 24000000;
  if AES or (Disc <> nil) then
    Result := 24168000;
end;

function TNeoGeoCartridge.FrameLines: Integer;
begin
  Result := 264;
  if AES and PAL then
    Result := 312;
end;

function TNeoGeoCartridge.VideoHeight: Integer;
begin
  Result := 224;
  if AES and PAL then
    Result := 256;
end;

end.

