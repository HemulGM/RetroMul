unit Core.CD.Physical;

interface

uses
  System.Classes, System.SysUtils;

const
  {$IF Defined(MSWINDOWS) or (Defined(LINUX) and not Defined(ANDROID))}
  PhysicalCDSupported = True;
  {$ELSE}
  PhysicalCDSupported = False;
  {$ENDIF}
  CDCookedSectorSize = 2048;
  CDRawSectorSize = 2352;
  CDRawWithSubchannelSize = 2448;
  CDReadAheadSectors = 16;
  CDMaximumTracks = 99;
  CDMaximumLeadOut = 100 * 60 * 75;

type
  {$SCOPEDENUMS ON}
  TPhysicalCDReadMode = (Cooked, Raw, RawWithSubchannel, Audio, AudioWithSubchannel);
  {$SCOPEDENUMS OFF}

const
  PhysicalCDSectorSizes: array[TPhysicalCDReadMode] of Integer = (CDCookedSectorSize, CDRawSectorSize,
    CDRawWithSubchannelSize, CDRawSectorSize, CDRawWithSubchannelSize);

type
  TPhysicalCDTrack = record
    StartLBA, EndLBA, SectorSize, DataOffset, Session: Integer;
    Audio, HasSubchannel: Boolean;
  end;

  // A read-only optical device with a block address space shared across tracks.
  IPhysicalCDDevice = interface
    function ReadTracks: TArray<TPhysicalCDTrack>;
    // Absolute end of the cooked block device; zero if the driver does not report it.
    function CookedSectorCount: Integer;
    // Returns bytes transferred, zero at end of medium, or -1 on an I/O error.
    // Buffer capacity is Count * PhysicalCDSectorSizes[Mode].
    function ReadSectors(LBA, Count: Integer; Mode: TPhysicalCDReadMode; Buffer: Pointer): Integer;
  end;

  TPhysicalCDSource = class(TMemoryStream)
  private
    FDevice: IPhysicalCDDevice;
    FTracks: TArray<TPhysicalCDTrack>;
    FReadModes: TArray<TPhysicalCDReadMode>;
    FIdentity: TBytes;
    FLocation, FDisplayName: string;
  public
    constructor Create(const DriveLocation: string);
    function OpenTrack(Index: Integer): TStream;
    property Tracks: TArray<TPhysicalCDTrack> read FTracks;
    property Identity: TBytes read FIdentity;
    property Location: string read FLocation;
    property DisplayName: string read FDisplayName;
  end;

function OpticalCDDrives: TArray<string>;

function OpticalCDLocation(const Drive: string): string;

function IsOpticalCDLocation(const Location: string): Boolean;

function OpticalCDDrive(const Location: string): string;

function OpticalCDDriveExists(const Drive: string): Boolean;

implementation

uses
  System.Hash, System.Math,
  {$IF Defined(MSWINDOWS)}
  Core.CD.Physical.Windows,
  {$ELSEIF Defined(LINUX) and not Defined(ANDROID)}
  Core.CD.Physical.Linux,
  {$ENDIF}
  Core.Storage;

const
  DrivePrefix = 'cdrom://';
  DriveExtension = '.cd-drive';
  DiscHashLength = 64;

type
  TPhysicalCDTrackStream = class(TStream)
  private
    FDevice: IPhysicalCDDevice;
    FTrack: TPhysicalCDTrack;
    FReadMode: TPhysicalCDReadMode;
    FCacheLBA, FCachedSectors: Integer;
    FPosition: Int64;
    FCache: array[0..CDReadAheadSectors * CDRawWithSubchannelSize - 1] of Byte;
    procedure FillCache(LBA: Integer);
  protected
    function GetSize: Int64; override;
  public
    constructor Create(const Device: IPhysicalCDDevice; const Track: TPhysicalCDTrack; ReadMode: TPhysicalCDReadMode);
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
  end;

function OpticalCDDrives: TArray<string>;
begin
  {$IF Defined(MSWINDOWS) or (Defined(LINUX) and not Defined(ANDROID))}
  Result := PlatformOpticalDrives;
  {$ELSE}
  Result := nil;
  {$ENDIF}
end;

function OpticalCDDriveExists(const Drive: string): Boolean;
begin
  {$IF Defined(MSWINDOWS) or (Defined(LINUX) and not Defined(ANDROID))}
  Result := PlatformOpticalDriveExists(Drive);
  {$ELSE}
  Result := False;
  {$ENDIF}
end;

function OpticalCDLocation(const Drive: string): string;
begin
  Result := '';
  {$IF Defined(MSWINDOWS) or (Defined(LINUX) and not Defined(ANDROID))}
  var DeviceId := PlatformOpticalDriveId(Drive);
  if DeviceId <> '' then
    Result := DrivePrefix + DeviceId;
  {$ENDIF}
end;

function OpticalCDDrive(const Location: string): string;
begin
  Result := '';
  {$IF Defined(MSWINDOWS) or (Defined(LINUX) and not Defined(ANDROID))}
  if not Location.StartsWith(DrivePrefix, True) then
    Exit;
  var DeviceId := Location.Substring(Length(DrivePrefix));
  var Separator := DeviceId.IndexOf('/');
  if Separator >= 0 then
  begin
    var HashPart := DeviceId.Substring(Separator + 1);
    if (Length(HashPart) <> DiscHashLength + Length(DriveExtension)) or
      not HashPart.EndsWith(DriveExtension, True) then
      Exit;
    for var Index := 1 to DiscHashLength do
      if not CharInSet(UpCase(HashPart[Index]), ['0'..'9', 'A'..'F']) then
        Exit;
    DeviceId := DeviceId.Substring(0, Separator);
  end;
  Result := PlatformOpticalDrivePath(DeviceId);
  {$ENDIF}
end;

function IsOpticalCDLocation(const Location: string): Boolean;
begin
  Result := OpticalCDDrive(Location) <> '';
end;

function OpenDevice(const Drive: string): IPhysicalCDDevice;
begin
  {$IF Defined(MSWINDOWS) or (Defined(LINUX) and not Defined(ANDROID))}
  Result := OpenPlatformOpticalDisc(Drive);
  {$ELSE}
  raise EReadError.Create('Optical drive is unavailable.');
  {$ENDIF}
end;

function ReadableCookedEndLBA(const Device: IPhysicalCDDevice; StartLBA, EndLBA: Integer): Integer;
var
  Sector: array[0..CDCookedSectorSize - 1] of Byte;
begin
  Result := EndLBA;
  // A virtual optical device can round up its reported capacity. Only a
  // confirmed end of the readable volume can shorten the data track.
  if Device.ReadSectors(EndLBA - 1, 1, TPhysicalCDReadMode.Cooked, @Sector[0]) <> 0 then
    Exit;
  var Low := StartLBA;
  var High := EndLBA - 1;
  while Low < High do
  begin
    var LBA := Low + (High - Low) div 2;
    case Device.ReadSectors(LBA, 1, TPhysicalCDReadMode.Cooked, @Sector[0]) of
      0:
        High := LBA;
      CDCookedSectorSize:
        Low := LBA + 1;
    else
      Exit;
    end;
  end;
  if Low > StartLBA then
    Result := Low;
end;

constructor TPhysicalCDTrackStream.Create(const Device: IPhysicalCDDevice; const Track: TPhysicalCDTrack; ReadMode: TPhysicalCDReadMode);
begin
  inherited Create;
  FDevice := Device;
  FTrack := Track;
  FReadMode := ReadMode;
end;

procedure TPhysicalCDTrackStream.FillCache(LBA: Integer);
begin
  FCachedSectors := 0;
  var Count := Min(CDReadAheadSectors, FTrack.EndLBA - LBA);
  if FDevice.ReadSectors(LBA, Count, FReadMode, @FCache[0]) <> Count * FTrack.SectorSize then
  begin
    // A request spanning the boundary with a pregap can fail as a unit.
    if (Count = 1) or (FDevice.ReadSectors(LBA, 1, FReadMode, @FCache[0]) <> FTrack.SectorSize) then
      raise EReadError.CreateFmt('Cannot read optical disc sector %d.', [LBA]);
    Count := 1;
  end;
  FCacheLBA := LBA;
  FCachedSectors := Count;
end;

function TPhysicalCDTrackStream.GetSize: Int64;
begin
  Result := Int64(FTrack.EndLBA - FTrack.StartLBA) * FTrack.SectorSize;
end;

function TPhysicalCDTrackStream.Read(var Buffer; Count: Longint): Longint;
begin
  Result := 0;
  Count := Integer(Min(Int64(Count), Size - FPosition));
  while Result < Count do
  begin
    TStorage.CheckReadCancelled;
    var LBA := FTrack.StartLBA + Integer(FPosition div FTrack.SectorSize);
    if (LBA < FCacheLBA) or (LBA >= FCacheLBA + FCachedSectors) then
      FillCache(LBA);
    var Offset := (LBA - FCacheLBA) * FTrack.SectorSize + Integer(FPosition mod FTrack.SectorSize);
    var Bytes := Min(Count - Result, FCachedSectors * FTrack.SectorSize - Offset);
    Move(FCache[Offset], (PByte(@Buffer) + Result)^, Bytes);
    Inc(FPosition, Bytes);
    Inc(Result, Bytes);
  end;
end;

function TPhysicalCDTrackStream.Write(const Buffer; Count: Longint): Longint;
begin
  raise EWriteError.Create('Optical disc is read-only.');
end;

function TPhysicalCDTrackStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  Result := Offset;
  case Origin of
    soCurrent:
      Inc(Result, FPosition);
    soEnd:
      Inc(Result, Size);
  end;
  if (Result < 0) or (Result > Size) then
    raise EStreamError.Create('Invalid optical disc stream position.');
  FPosition := Result;
end;

constructor TPhysicalCDSource.Create(const DriveLocation: string);
var
  Sector: array[0..CDRawWithSubchannelSize - 1] of Byte;
  Data: array[0..CDCookedSectorSize - 1] of Byte;

  procedure ConfigureTrack(var Track: TPhysicalCDTrack; out Mode: TPhysicalCDReadMode);
  begin
    Mode := TPhysicalCDReadMode.RawWithSubchannel;
    if Track.Audio then
      Mode := TPhysicalCDReadMode.AudioWithSubchannel;
    Track.HasSubchannel := FDevice.ReadSectors(Track.StartLBA, 1, Mode, @Sector[0]) = CDRawWithSubchannelSize;
    if not Track.HasSubchannel then
    begin
      if Track.Audio then
        Mode := TPhysicalCDReadMode.Audio
      else
      begin
        Mode := TPhysicalCDReadMode.Raw;
        if FDevice.ReadSectors(Track.StartLBA, 1, Mode, @Sector[0]) <> CDRawSectorSize then
          Mode := TPhysicalCDReadMode.Cooked;
      end;
    end;
    Track.SectorSize := PhysicalCDSectorSizes[Mode];
    if Track.Audio or (Mode = TPhysicalCDReadMode.Cooked) then
      Exit;
    if (Sector[0] <> 0) or (Sector[1] <> $FF) or (Sector[11] <> 0) or not (Sector[15] in [1, 2]) then
      raise EReadError.Create('Unsupported optical disc sector format.');
    Track.DataOffset := 16;
    if Sector[15] = 2 then
      Track.DataOffset := 24;
  end;

begin
  inherited Create;
  var Drive := OpticalCDDrive(DriveLocation);
  FDevice := OpenDevice(Drive);
  FTracks := FDevice.ReadTracks;
  if Length(FTracks) = 0 then
    raise EReadError.Create('Unsupported optical disc track table.');

  SetLength(FReadModes, Length(FTracks));
  var FirstDataTrack := -1;
  for var Index := 0 to High(FTracks) do
    if not FTracks[Index].Audio then
    begin
      FirstDataTrack := Index;
      Break;
    end;
  if FirstDataTrack < 0 then
    raise EReadError.Create('The optical disc has no game data tracks.');

  for var Index := 0 to High(FTracks) do
    ConfigureTrack(FTracks[Index], FReadModes[Index]);
  var FingerprintEndLBA := FTracks[FirstDataTrack].EndLBA;
  if (Length(FTracks) = 1) and (FReadModes[0] = TPhysicalCDReadMode.Cooked) then
  begin
    var StartLBA := FTracks[0].StartLBA;
    var ReportedEndLBA := FDevice.CookedSectorCount;
    if ReportedEndLBA > StartLBA then
      FingerprintEndLBA := ReportedEndLBA;
    var ReadableEndLBA := ReadableCookedEndLBA(FDevice, StartLBA, FingerprintEndLBA);
    FTracks[0].EndLBA := ReadableEndLBA;

    // Retain existing save associations when all previous samples are readable.
    var ReportedLength := FingerprintEndLBA - StartLBA;
    var LastSample := Max(Min(31, ReportedLength - 1), ReportedLength * 2 div 3);
    if StartLBA + LastSample >= ReadableEndLBA then
      FingerprintEndLBA := ReadableEndLBA;
  end;

  // Identify the disc without reading the whole medium. Use user data so
  // the fingerprint is independent of the drive's support for raw reads.
  var Hash := THashSHA2.Create;
  for var Index := 0 to High(FTracks) do
  begin
    var Item := FTracks[Index];
    var EndLBA := Item.EndLBA;
    if Index = FirstDataTrack then
      EndLBA := FingerprintEndLBA;
    Hash.Update(Format('%d/%d/%d;', [Item.StartLBA, EndLBA, Ord(Item.Audio)]));
  end;
  var Track := FTracks[FirstDataTrack];
  var Stream := OpenTrack(FirstDataTrack);
  try
    var SectorCount := FingerprintEndLBA - Track.StartLBA;
    for var Index := 0 to Min(31, SectorCount - 1) do
    begin
      Stream.Position := Int64(Index) * Track.SectorSize + Track.DataOffset;
      Stream.ReadBuffer(Data, SizeOf(Data));
      Hash.Update(Data, SizeOf(Data));
      if (Index = 16) and (Data[0] = 1) and CompareMem(@Data[1], PAnsiChar(AnsiString('CD001')), 5) then
      begin
        // The ISO 9660 primary volume descriptor stores a 32-byte volume ID.
        for var C := 40 to 71 do
          if CharInSet(Char(Data[C]), ['A'..'Z', 'a'..'z', '0'..'9', ' ', '_', '-']) then
            FDisplayName := FDisplayName + Char(Data[C]);
        FDisplayName := FDisplayName.Trim;
      end;
    end;
    for var Sample := 1 to 2 do
    begin
      Stream.Position := Int64(SectorCount * Sample div 3) * Track.SectorSize + Track.DataOffset;
      Stream.ReadBuffer(Data, SizeOf(Data));
      Hash.Update(Data, SizeOf(Data));
    end;
  finally
    Stream.Free;
  end;
  FIdentity := Hash.HashAsBytes;
  FLocation := OpticalCDLocation(Drive) + '/' + THash.DigestAsString(FIdentity) + DriveExtension;
  if not SameText(DriveLocation, OpticalCDLocation(Drive)) and not SameText(DriveLocation, FLocation) then
    raise EReadError.Create('The disc in the optical drive has changed.');
end;

function TPhysicalCDSource.OpenTrack(Index: Integer): TStream;
begin
  Result := TPhysicalCDTrackStream.Create(FDevice, FTracks[Index], FReadModes[Index]);
end;

end.

