unit Core.CD.Physical.Linux;

interface

uses
  Core.CD.Physical;

function PlatformOpticalDrives: TArray<string>;

function PlatformOpticalDriveExists(const Drive: string): Boolean;

function PlatformOpticalDrivePath(const DeviceId: string): string;

function PlatformOpticalDriveId(const Drive: string): string;

function OpenPlatformOpticalDisc(const Drive: string): IPhysicalCDDevice;

{$WARN SYMBOL_PLATFORM OFF}

implementation

uses
  System.Classes, System.SysUtils, System.IOUtils, System.Generics.Collections,
  System.Generics.Defaults, Posix.Base, Posix.Fcntl, Posix.Unistd, Posix.SysStat,
  Posix.Errno, Core.Storage;

const
  DeviceDirectory = '/dev/';
  CDROM_READ_TOC_HEADER = $5305;
  CDROM_READ_TOC_ENTRY = $5306;
  CDROM_READ_AUDIO = $530E;
  CDROM_READ_RAW = $5314;
  CDROM_MEDIA_CHANGED = $5325;
  CDROM_DRIVE_STATUS = $5326;
  CDROM_CURRENT_SLOT = $7FFFFFFF;
  CDROM_NO_DISC = 1;
  CDROM_TRAY_OPEN = 2;
  CDROM_NOT_READY = 3;
  CDROM_ADDRESS_LBA = 1;
  CDROM_LEAD_OUT = $AA;
  CDROM_DATA_TRACK = 4;
  BLKGETSIZE64 = $80081272;
  SG_IO = $2285;
  SG_DXFER_FROM_DEV = -3;
  SG_INFO_OK_MASK = 1;
  MMC_READ_CD = $BE;
  O_CLOEXEC = $80000;

type
  TCDTOCHeader = packed record
    FirstTrack, LastTrack: Byte;
  end;

  TCDTOCEntry = packed record
    Track, ADRAndControl, AddressFormat, Reserved: Byte;
    LBA: Int32;
    DataMode: Byte;
    Padding: array[0..2] of Byte;
  end;

  TCDReadAudio = record
    LBA: Int32;
    AddressFormat: Byte;
    Frames: Int32;
    Buffer: Pointer;
  end;

  TSGIOHeader = record
    InterfaceId, Direction: Int32;
    CommandLength, MaxSenseLength: Byte;
    IOVectorCount: Word;
    TransferLength: UInt32;
    TransferBuffer, Command, SenseBuffer: Pointer;
    Timeout, Flags: UInt32;
    PackId: Int32;
    UserPointer: Pointer;
    Status, MaskedStatus, MessageStatus, SenseWritten: Byte;
    HostStatus, DriverStatus: Word;
    Residual: Int32;
    Duration, Info: UInt32;
  end;

  TLinuxCDDevice = class(TInterfacedObject, IPhysicalCDDevice)
  private
    FDescriptor: Integer;
    FDetectMediaChange: Boolean;
    function ReadTOCEntry(TrackNumber: Byte): TCDTOCEntry;
    function ReadRaw(LBA, Count: Integer; Buffer: Pointer): Integer;
    function ReadAudio(LBA, Count: Integer; Buffer: Pointer): Integer;
    function ReadWithSubchannel(LBA, Count: Integer; Audio: Boolean; Buffer: Pointer): Integer;
  public
    constructor Create(const Drive: string);
    destructor Destroy; override;
    function ReadTracks: TArray<TPhysicalCDTrack>;
    function CookedSectorCount: Integer;
    function ReadSectors(LBA, Count: Integer; Mode: TPhysicalCDReadMode; Buffer: Pointer): Integer;
  end;

function NativeIoctl(FD: Integer; Request: NativeUInt; Arg: Pointer): Integer; cdecl; external libc name 'ioctl';

function RetryIoctl(FD: Integer; Request: NativeUInt; Arg: Pointer): Integer;
begin
  repeat
    Result := NativeIoctl(FD, Request, Arg);
  until (Result >= 0) or (errno <> EINTR);
end;

function PlatformOpticalDrivePath(const DeviceId: string): string;
begin
  Result := '';
  if not DeviceId.StartsWith('sr') or (Length(DeviceId) < 3) then
    Exit;
  for var Index := 3 to Length(DeviceId) do
    if not CharInSet(DeviceId[Index], ['0'..'9']) then
      Exit;
  Result := DeviceDirectory + DeviceId;
end;

function PlatformOpticalDriveId(const Drive: string): string;
begin
  Result := '';
  if not Drive.StartsWith(DeviceDirectory) then
    Exit;
  var DeviceId := Drive.Substring(Length(DeviceDirectory));
  if PlatformOpticalDrivePath(DeviceId) <> '' then
    Result := DeviceId;
end;

function PlatformOpticalDriveExists(const Drive: string): Boolean;
begin
  Result := False;
  if PlatformOpticalDriveId(Drive) = '' then
    Exit;
  var Name := UTF8String(Drive);
  var Info: _stat;
  Result := (Posix.SysStat.stat(PAnsiChar(Name), Info) = 0) and S_ISBLK(Info.st_mode);
end;

function PlatformOpticalDrives: TArray<string>;
begin
  Result := nil;
  // sr names are the Linux SCSI CD-ROM device nodes, including USB optical drives.
  if not TDirectory.Exists('/sys/class/block') then
    Exit;
  for var Entry in TDirectory.GetFileSystemEntries('/sys/class/block', 'sr*') do
  begin
    var Drive := PlatformOpticalDrivePath(TPath.GetFileName(Entry));
    if PlatformOpticalDriveExists(Drive) then
      Result := Result + [Drive];
  end;
  TArray.Sort<string>(Result, TComparer<string>.Default);
end;

constructor TLinuxCDDevice.Create(const Drive: string);
begin
  inherited Create;
  FDescriptor := -1;
  if not PlatformOpticalDriveExists(Drive) then
    raise EReadError.Create('Optical drive is unavailable.');
  var Name := UTF8String(Drive);
  FDescriptor := Posix.Fcntl.open(PAnsiChar(Name), O_RDONLY or O_NONBLOCK or O_CLOEXEC);
  if FDescriptor < 0 then
  begin
    var Error := errno;
    if Error = ENOMEDIUM then
      raise EReadError.Create('Insert a game disc into the optical drive.');
    RaiseLastOSError(Error);
  end;
  var Status := RetryIoctl(FDescriptor, CDROM_DRIVE_STATUS, Pointer(NativeUInt(CDROM_CURRENT_SLOT)));
  if Status in [CDROM_NO_DISC, CDROM_TRAY_OPEN, CDROM_NOT_READY] then
    raise EReadError.Create('Insert a game disc into the optical drive.');
end;

destructor TLinuxCDDevice.Destroy;
begin
  if FDescriptor >= 0 then
    Posix.Unistd.__close(FDescriptor);
  inherited;
end;

function TLinuxCDDevice.ReadTOCEntry(TrackNumber: Byte): TCDTOCEntry;
begin
  Result := Default(TCDTOCEntry);
  Result.Track := TrackNumber;
  Result.AddressFormat := CDROM_ADDRESS_LBA;
  TStorage.CheckReadCancelled;
  if RetryIoctl(FDescriptor, CDROM_READ_TOC_ENTRY, @Result) < 0 then
  begin
    if errno = ENOMEDIUM then
      raise EReadError.Create('Insert a game disc into the optical drive.');
    raise EReadError.Create('Unsupported optical disc track table.');
  end;
end;

function TLinuxCDDevice.ReadTracks: TArray<TPhysicalCDTrack>;
begin
  TStorage.CheckReadCancelled;
  var Header: TCDTOCHeader;
  if RetryIoctl(FDescriptor, CDROM_READ_TOC_HEADER, @Header) < 0 then
  begin
    if errno = ENOMEDIUM then
      raise EReadError.Create('Insert a game disc into the optical drive.');
    Exit(nil);
  end;
  if (Header.FirstTrack <> 1) or (Header.LastTrack < 1) or (Header.LastTrack > CDMaximumTracks) then
    Exit(nil);

  SetLength(Result, Header.LastTrack);
  var Entry := ReadTOCEntry(Header.FirstTrack);
  for var Index := 0 to High(Result) do
  begin
    var Next: TCDTOCEntry;
    if Index = High(Result) then
      Next := ReadTOCEntry(CDROM_LEAD_OUT)
    else
      Next := ReadTOCEntry(Index + 2);
    if (Entry.LBA < 0) or (Entry.LBA >= Next.LBA) or (Next.LBA > CDMaximumLeadOut) then
      Exit(nil);
    Result[Index].StartLBA := Entry.LBA;
    Result[Index].EndLBA := Next.LBA;
    Result[Index].Audio := ((Entry.ADRAndControl shr 4) and CDROM_DATA_TRACK) = 0;
    Result[Index].Session := 1;
    Entry := Next;
  end;
  // Establish the baseline after the TOC read has opened the medium.
  FDetectMediaChange := RetryIoctl(FDescriptor, CDROM_MEDIA_CHANGED, Pointer(NativeUInt(CDROM_CURRENT_SLOT))) >= 0;
end;

function TLinuxCDDevice.CookedSectorCount: Integer;
begin
  Result := 0;
  var Capacity: UInt64;
  if (RetryIoctl(FDescriptor, BLKGETSIZE64, @Capacity) = 0) and
    (Capacity mod CDCookedSectorSize = 0) and (Capacity div CDCookedSectorSize <= CDMaximumLeadOut) then
    Result := Integer(Capacity div CDCookedSectorSize);
end;

function TLinuxCDDevice.ReadRaw(LBA, Count: Integer; Buffer: Pointer): Integer;
begin
  for var Index := 0 to Count - 1 do
  begin
    TStorage.CheckReadCancelled;
    var Sector := PByte(Buffer) + Index * CDRawSectorSize;
    var MSF := LBA + Index + 150;
    // CDROMREADRAW takes a binary MSF address and writes the sector over it.
    FillChar(Sector^, 6, 0);
    Sector[0] := MSF div 4500;
    Sector[1] := (MSF div 75) mod 60;
    Sector[2] := MSF mod 75;
    if RetryIoctl(FDescriptor, CDROM_READ_RAW, Sector) < 0 then
      Exit(-1);
  end;
  Result := Count * CDRawSectorSize;
end;

function TLinuxCDDevice.ReadAudio(LBA, Count: Integer; Buffer: Pointer): Integer;
begin
  var Request := Default(TCDReadAudio);
  Request.LBA := LBA;
  Request.AddressFormat := CDROM_ADDRESS_LBA;
  Request.Frames := Count;
  Request.Buffer := Buffer;
  Result := -1;
  if RetryIoctl(FDescriptor, CDROM_READ_AUDIO, @Request) = 0 then
    Result := Count * CDRawSectorSize;
end;

function TLinuxCDDevice.ReadWithSubchannel(LBA, Count: Integer; Audio: Boolean; Buffer: Pointer): Integer;
var
  Command: array[0..11] of Byte;
  Sense: array[0..31] of Byte;
begin
  FillChar(Command, SizeOf(Command), 0);
  Command[0] := MMC_READ_CD;
  Command[2] := Byte(LBA shr 24);
  Command[3] := Byte(LBA shr 16);
  Command[4] := Byte(LBA shr 8);
  Command[5] := Byte(LBA);
  Command[8] := Count;
  Command[9] := $F8; // Sync, headers, data and EDC/ECC.
  if Audio then
  begin
    Command[1] := 1 shl 2; // Expected sector type: CD-DA.
    Command[9] := $10; // CD-DA samples are the user data.
  end;
  Command[10] := 1; // Raw interleaved P-W subchannel bytes.

  var Request := Default(TSGIOHeader);
  Request.InterfaceId := Ord('S');
  Request.Direction := SG_DXFER_FROM_DEV;
  Request.CommandLength := SizeOf(Command);
  Request.MaxSenseLength := SizeOf(Sense);
  Request.TransferLength := Count * CDRawWithSubchannelSize;
  Request.TransferBuffer := Buffer;
  Request.Command := @Command[0];
  Request.SenseBuffer := @Sense[0];
  Request.Timeout := 10000;
  Result := -1;
  if (RetryIoctl(FDescriptor, SG_IO, @Request) = 0) and
    ((Request.Info and SG_INFO_OK_MASK) = 0) and (Request.Residual = 0) then
    Result := Integer(Request.TransferLength);
end;

function TLinuxCDDevice.ReadSectors(LBA, Count: Integer; Mode: TPhysicalCDReadMode; Buffer: Pointer): Integer;
begin
  TStorage.CheckReadCancelled;
  if FDetectMediaChange and
    (RetryIoctl(FDescriptor, CDROM_MEDIA_CHANGED, Pointer(NativeUInt(CDROM_CURRENT_SLOT))) > 0) then
    raise EReadError.Create('The disc in the optical drive has changed.');

  case Mode of
    TPhysicalCDReadMode.Cooked:
      begin
        repeat
          Result := Integer(pread(FDescriptor, Buffer, Count * CDCookedSectorSize, Int64(LBA) * CDCookedSectorSize));
        until (Result >= 0) or (errno <> EINTR);
      end;
    TPhysicalCDReadMode.Raw:
      Result := ReadRaw(LBA, Count, Buffer);
    TPhysicalCDReadMode.Audio:
      Result := ReadAudio(LBA, Count, Buffer);
  else
    Result := ReadWithSubchannel(LBA, Count, Mode = TPhysicalCDReadMode.AudioWithSubchannel, Buffer);
  end;
end;

function OpenPlatformOpticalDisc(const Drive: string): IPhysicalCDDevice;
begin
  Result := TLinuxCDDevice.Create(Drive);
end;

end.

