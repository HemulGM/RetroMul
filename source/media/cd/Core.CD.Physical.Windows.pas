unit Core.CD.Physical.Windows;

interface

uses
  Core.CD.Physical;

function PlatformOpticalDrives: TArray<string>;

function PlatformOpticalDriveExists(const Drive: string): Boolean;

function PlatformOpticalDrivePath(const DeviceId: string): string;

function PlatformOpticalDriveId(const Drive: string): string;

function OpenPlatformOpticalDisc(const Drive: string): IPhysicalCDDevice;

implementation

uses
  System.Classes, System.SysUtils, System.Math, Winapi.Windows, Core.Storage;

const
  IOCTL_CDROM_READ_TOC_EX = $00024054;
  IOCTL_CDROM_RAW_READ = $0002403E;
  ReadCooked = -1;
  ReadMode2 = 0;
  ReadCDDA = 2;
  ReadWithSubcode = 5;

type
  TTOCEntry = packed record
    Reserved, ControlAndADR, TrackNumber, Reserved1: Byte;
    Address: array[0..3] of Byte;
    function LBA: Cardinal;
  end;

  TCDTOC = packed record
    LengthMSB, LengthLSB, FirstTrack, LastTrack: Byte;
    Entries: array[0..CDMaximumTracks] of TTOCEntry;
  end;

  TFullTOCEntry = packed record
    Session, ControlAndADR, TrackNumber, Point: Byte;
    Reserved: array[0..3] of Byte;
    Minutes, Seconds, Frames: Byte;
    function LBA: Integer;
  end;

  TCDFullTOC = packed record
    LengthMSB, LengthLSB, FirstSession, LastSession: Byte;
    Entries: array[0..CDMaximumTracks * 8 - 1] of TFullTOCEntry;
  end;

  TRawReadInfo = packed record
    DiskOffset: Int64;
    SectorCount, TrackMode: DWORD;
  end;

  TWindowsCDDevice = class(TInterfacedObject, IPhysicalCDDevice)
  private
    FHandle: THandle;
    FReadBuffer: Pointer;
    FMediaChangeCount: DWORD;
    FHasMediaChangeCount: Boolean;
    procedure VerifyMedia(Opening: Boolean);
    function ReadIntoBuffer(LBA, Count, Mode, SectorSize: Integer): Integer;
  public
    constructor Create(const Drive: string);
    destructor Destroy; override;
    function ReadTOC(Request: DWORD; Buffer: Pointer; BufferSize: DWORD): DWORD;
    function ReadBasicTracks: TArray<TPhysicalCDTrack>;
    function ReadFullTracks: TArray<TPhysicalCDTrack>;
    function CookedSectorCount: Integer;
    function ReadTracks: TArray<TPhysicalCDTrack>;
    function ReadSectors(LBA, Count: Integer; Mode: TPhysicalCDReadMode; Buffer: Pointer): Integer;
  end;

function PlatformOpticalDrivePath(const DeviceId: string): string;
begin
  Result := '';
  if (Length(DeviceId) = 2) and CharInSet(UpCase(DeviceId[1]), ['A'..'Z']) and (DeviceId[2] = ':') then
    Result := UpCase(DeviceId[1]) + ':';
end;

function PlatformOpticalDriveId(const Drive: string): string;
begin
  Result := PlatformOpticalDrivePath(Drive);
end;

function PlatformOpticalDriveExists(const Drive: string): Boolean;
begin
  Result := (Drive <> '') and (GetDriveType(PChar(Drive + '\')) = DRIVE_CDROM);
end;

function PlatformOpticalDrives: TArray<string>;
begin
  Result := nil;
  var Drives := GetLogicalDrives;
  for var Index := 0 to 25 do
    if (Drives and (DWORD(1) shl Index)) <> 0 then
    begin
      var Drive := Char(Ord('A') + Index) + ':';
      if PlatformOpticalDriveExists(Drive) then
        Result := Result + [Drive];
    end;
end;

function TTOCEntry.LBA: Cardinal;
begin
  Result := (Cardinal(Address[0]) shl 24) or (Cardinal(Address[1]) shl 16) or
    (Cardinal(Address[2]) shl 8) or Address[3];
end;

function TFullTOCEntry.LBA: Integer;
begin
  Result := -1;
  if (Seconds < 60) and (Frames < 75) then
    Result := (Integer(Minutes) * 60 + Seconds) * 75 + Frames - 150;
end;

constructor TWindowsCDDevice.Create(const Drive: string);
begin
  inherited Create;
  FHandle := INVALID_HANDLE_VALUE;
  if not PlatformOpticalDriveExists(Drive) then
    raise EReadError.Create('Optical drive is unavailable.');
  var OldMode: DWORD;
  var ModeChanged := SetThreadErrorMode(GetThreadErrorMode or SEM_FAILCRITICALERRORS, OldMode);
  try
    FHandle := CreateFile(PChar('\\.\' + Drive), GENERIC_READ, FILE_SHARE_READ or FILE_SHARE_WRITE,
      nil, OPEN_EXISTING, 0, 0);
    if FHandle = INVALID_HANDLE_VALUE then
      RaiseLastOSError;
    VerifyMedia(True);
  finally
    if ModeChanged then
      SetThreadErrorMode(OldMode, OldMode);
  end;
  // Windows can enforce sector alignment on direct volume reads.
  FReadBuffer := VirtualAlloc(nil, CDReadAheadSectors * CDRawWithSubchannelSize, MEM_COMMIT or MEM_RESERVE, PAGE_READWRITE);
  if FReadBuffer = nil then
    RaiseLastOSError;
end;

destructor TWindowsCDDevice.Destroy;
begin
  if FReadBuffer <> nil then
    VirtualFree(FReadBuffer, 0, MEM_RELEASE);
  if FHandle <> INVALID_HANDLE_VALUE then
    CloseHandle(FHandle);
  inherited;
end;

procedure TWindowsCDDevice.VerifyMedia(Opening: Boolean);
begin
  var Count, BytesRead: DWORD;
  if not DeviceIoControl(FHandle, IOCTL_STORAGE_CHECK_VERIFY, nil, 0,
    @Count, SizeOf(Count), BytesRead, nil) then
  begin
    var Error := GetLastError;
    if (Error = ERROR_NOT_READY) or (Error = ERROR_NO_MEDIA_IN_DRIVE) then
      raise EReadError.Create('Insert a game disc into the optical drive.');
    // Some bridges only implement TOC and sector reads.
    if Opening and (Error in [ERROR_INVALID_FUNCTION, ERROR_INVALID_PARAMETER, ERROR_NOT_SUPPORTED]) then
      Exit;
    RaiseLastOSError(Error);
  end;
  if Opening then
  begin
    FHasMediaChangeCount := BytesRead = SizeOf(Count);
    if FHasMediaChangeCount then
      FMediaChangeCount := Count;
  end
  else if (BytesRead = SizeOf(Count)) and (Count <> FMediaChangeCount) then
    raise EReadError.Create('The disc in the optical drive has changed.');
end;

function TWindowsCDDevice.ReadTOC(Request: DWORD; Buffer: Pointer; BufferSize: DWORD): DWORD;
begin
  var BytesRead: DWORD;
  if DeviceIoControl(FHandle, IOCTL_CDROM_READ_TOC_EX, @Request, SizeOf(Request), Buffer,
    BufferSize, BytesRead, nil) then
    Exit(BytesRead);
  var Error := GetLastError;
  if (Error = ERROR_NOT_READY) or (Error = ERROR_NO_MEDIA_IN_DRIVE) then
    raise EReadError.Create('Insert a game disc into the optical drive.');
  Result := 0;
end;

function TWindowsCDDevice.ReadBasicTracks: TArray<TPhysicalCDTrack>;
var
  TOC: TCDTOC;
begin
  Result := nil;
  FillChar(TOC, SizeOf(TOC), 0);
  // Format 0 returns track starts and the lead-out in LBA form.
  var BytesRead := ReadTOC(0, @TOC, SizeOf(TOC));
  var Count := Integer(TOC.LastTrack);
  var TOCSize := Integer(TOC.LengthMSB) * 256 + TOC.LengthLSB + 2;
  if (TOC.FirstTrack <> 1) or (Count < 1) or (Count > CDMaximumTracks) or
    (Min(Integer(BytesRead), TOCSize) < 4 + (Count + 1) * SizeOf(TTOCEntry)) or
    (TOC.Entries[Count].TrackNumber <> $AA) or (TOC.Entries[Count].LBA > CDMaximumLeadOut) then
    Exit;
  SetLength(Result, Count);
  for var Index := 0 to Count - 1 do
  begin
    var Current := TOC.Entries[Index];
    var StartLBA := Current.LBA;
    var EndLBA := TOC.Entries[Index + 1].LBA;
    if (Current.TrackNumber <> Index + 1) or (StartLBA >= EndLBA) then
      Exit(nil);
    Result[Index].StartLBA := Integer(StartLBA);
    Result[Index].EndLBA := Integer(EndLBA);
    Result[Index].Session := 1;
    Result[Index].Audio := (Current.ControlAndADR and 4) = 0;
  end;
end;

function TWindowsCDDevice.ReadFullTracks: TArray<TPhysicalCDTrack>;
var
  TOC: TCDFullTOC;
  Tracks: array[1..CDMaximumTracks] of TPhysicalCDTrack;
  LeadOut: array[1..CDMaximumTracks] of Integer;
begin
  Result := nil;
  FillChar(TOC, SizeOf(TOC), 0);
  // Some USB bridges only return a complete track table in full TOC mode.
  var Size := Integer(ReadTOC($82, @TOC, SizeOf(TOC)));
  Size := Min(Size, Integer(TOC.LengthMSB) * 256 + TOC.LengthLSB + 2);
  if Size < 4 + SizeOf(TFullTOCEntry) then
    Exit;
  FillChar(Tracks, SizeOf(Tracks), 0);
  FillChar(LeadOut, SizeOf(LeadOut), 0);
  var LastTrack := 0;
  for var Index := 0 to (Size - 4) div SizeOf(TFullTOCEntry) - 1 do
  begin
    var Entry := TOC.Entries[Index];
    if not (Entry.Session in [1..CDMaximumTracks]) or (Entry.ControlAndADR shr 4 <> 1) then
      Continue;
    if Entry.Point = $A2 then
      LeadOut[Entry.Session] := Entry.LBA
    else if Entry.Point in [1..CDMaximumTracks] then
    begin
      Tracks[Entry.Point].Session := Entry.Session;
      Tracks[Entry.Point].StartLBA := Entry.LBA;
      Tracks[Entry.Point].Audio := (Entry.ControlAndADR and 4) = 0;
      LastTrack := Max(LastTrack, Entry.Point);
    end;
  end;
  SetLength(Result, LastTrack);
  var PreviousEnd := 0;
  for var Index := 1 to LastTrack do
  begin
    var Track := Tracks[Index];
    if (Track.Session = 0) or (Track.StartLBA < PreviousEnd) then
      Exit(nil);
    Track.EndLBA := LeadOut[Track.Session];
    if (Index < LastTrack) and (Tracks[Index + 1].Session = Track.Session) then
      Track.EndLBA := Tracks[Index + 1].StartLBA;
    if (Track.EndLBA <= Track.StartLBA) or (Track.EndLBA > CDMaximumLeadOut) then
      Exit(nil);
    Result[Index - 1] := Track;
    PreviousEnd := Track.EndLBA;
  end;
end;

function TWindowsCDDevice.ReadIntoBuffer(LBA, Count, Mode, SectorSize: Integer): Integer;
begin
  TStorage.CheckReadCancelled;
  if FHasMediaChangeCount then
    VerifyMedia(False);

  var BytesRead: DWORD;
  var Requested := Count * SectorSize;
  if Mode = ReadCooked then
  begin
    if not SetFilePointerEx(FHandle, Int64(LBA) * CDCookedSectorSize, nil, FILE_BEGIN) then
      Exit(-1);
    if ReadFile(FHandle, FReadBuffer^, Requested, BytesRead, nil) then
      Exit(Integer(BytesRead));
    if GetLastError = ERROR_HANDLE_EOF then
      Exit(0);
  end
  else
  begin
    var Request: TRawReadInfo;
    Request.DiskOffset := Int64(LBA) * CDCookedSectorSize;
    Request.SectorCount := Count;
    Request.TrackMode := Mode;
    if DeviceIoControl(FHandle, IOCTL_CDROM_RAW_READ, @Request, SizeOf(Request), FReadBuffer,
      Requested, BytesRead, nil) then
      Exit(Integer(BytesRead));
  end;
  Result := -1;
end;

function TWindowsCDDevice.ReadSectors(LBA, Count: Integer; Mode: TPhysicalCDReadMode; Buffer: Pointer): Integer;
const
  WindowsModes: array[TPhysicalCDReadMode] of Integer = (ReadCooked, ReadMode2, ReadWithSubcode,
    ReadCDDA, ReadWithSubcode);
begin
  Result := ReadIntoBuffer(LBA, Count, WindowsModes[Mode], PhysicalCDSectorSizes[Mode]);
  if Result > 0 then
    Move(FReadBuffer^, Buffer^, Result);
end;

function TWindowsCDDevice.CookedSectorCount: Integer;
begin
  Result := 0;
  var Capacity: Int64;
  var BytesRead: DWORD;
  if DeviceIoControl(FHandle, IOCTL_DISK_GET_LENGTH_INFO, nil, 0, @Capacity,
    SizeOf(Capacity), BytesRead, nil) and (BytesRead = SizeOf(Capacity)) and
    (Capacity > 0) and (Capacity mod CDCookedSectorSize = 0) and
    (Capacity div CDCookedSectorSize <= CDMaximumLeadOut) then
    Result := Integer(Capacity div CDCookedSectorSize);
end;

function TWindowsCDDevice.ReadTracks: TArray<TPhysicalCDTrack>;
begin
  Result := ReadBasicTracks;
  if Length(Result) = 0 then
    Result := ReadFullTracks;
end;

function OpenPlatformOpticalDisc(const Drive: string): IPhysicalCDDevice;
begin
  Result := TWindowsCDDevice.Create(Drive);
end;

end.

