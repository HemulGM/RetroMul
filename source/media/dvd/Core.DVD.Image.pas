unit Core.DVD.Image;

// DVD (and CD) sector sources for disc-based consoles that read 2048-byte
// user data by LBA: ISO images of any size (64-bit offsets, dual-layer
// images with the layer break taken from the second volume descriptor),
// DVD CHD (chdman createdvd), a minimal Alcohol 120% DVD MDS/MDF reader and
// CD images through TCDDisc (Mode 1 / Mode 2 Form 1). The source is
// independent of the container, so more formats can be added as classes.
// Also an ISO 9660 file reader over any source.

interface

uses
  System.SysUtils, System.Classes, System.Hash, Core.Storage, Core.CD.Disc;

const
  DVDSectorSize = 2048;

type
  EDVDImage = class(Exception);

  TDVDImage = class abstract
  protected
    FLayerBreak: Int64;
    FIdentity: TBytes;
    procedure DetectLayers;
    procedure ComputeIdentity;
  public
    function SectorCount: Int64; virtual; abstract;
    // Count sectors from LBA into Dest (zeros past the end).
    procedure ReadSectors(LBA: Int64; Count: Integer; Dest: PByte); virtual; abstract;
    function ReadSector(LBA: Int64): TBytes;
    // First sector of layer 1 (the sectors of layer 0) for a dual-layer
    // DVD, 0 otherwise.
    property LayerBreak: Int64 read FLayerBreak;
    // True for DVD media (false for CD images).
    function IsDVD: Boolean; virtual;
    // Stable identity of the medium for snapshots and save names.
    property Identity: TBytes read FIdentity;
  end;

  // Plain sector data in a stream: 2048-byte ISO, or raw CD sectors (2352, or 2448 with subchannels).
  TDVDStreamImage = class(TDVDImage)
  private
    FStream: TStream;
    FOffset: Int64;
    FSectorSize, FDataOffset: Integer;
    FCount: Int64;
    FBuffer: TBytes;
  public
    // Takes ownership of Stream.
    constructor Create(Stream: TStream; Offset: Int64 = 0; SectorSize: Integer = DVDSectorSize; Count: Int64 = -1);
    destructor Destroy; override;
    function SectorCount: Int64; override;
    procedure ReadSectors(LBA: Int64; Count: Integer; Dest: PByte); override;
    function IsDVD: Boolean; override;
  end;

  TDVDCDImage = class(TDVDImage)
  private
    FDisc: TCDDisc;
    FOwns: Boolean;
    FStart, FCount: Int64;
  public
    constructor Create(Disc: TCDDisc; OwnsDisc: Boolean);
    destructor Destroy; override;
    function SectorCount: Int64; override;
    procedure ReadSectors(LBA: Int64; Count: Integer; Dest: PByte); override;
    function IsDVD: Boolean; override;
    property Disc: TCDDisc read FDisc;
  end;

  TISO9660Entry = record
    LBA: Int64;
    Size: Int64;
    Directory: Boolean;
    Name: string;
  end;

  TISO9660 = class
  private
    FImage: TDVDImage;
    FBase: Int64;
    FRootLBA, FRootSize: Int64;
    function ReadDirectory(LBA, Size: Int64): TArray<TISO9660Entry>;
  public
    // A volume whose sector numbers count from Base (layer 1 of a dual-layer
    // disc); entries carry image LBAs.
    constructor Create(Image: TDVDImage; Base: Int64 = 0);
    class function HasVolume(Image: TDVDImage; Base: Int64 = 0): Boolean; static;
    // Path with '/' or '\' separators, case-insensitive, ";1" optional.
    function Find(const Path: string; out Entry: TISO9660Entry): Boolean;
    function ReadFile(const Path: string; MaximumSize: Integer = 16 * 1024 * 1024): TBytes;
    function List(const Path: string): TArray<TISO9660Entry>;
  end;

  // SYSTEM.CNF of a PlayStation 2 disc.
  TPS2DiscInfo = record
    Boot2, VMode, Version, Serial: string;
  end;

// A DVD/CD source for a disc image file: .iso (any size), .chd (DVD),
// .mds/.mdf (DVD), .cue/.bin and CD .chd through TCDDisc. Stream is owned.
function OpenDVDImage(Stream: TStream; const Storage: IStorage; const Location: string): TDVDImage;
// Whether a stream holds an ISO 9660 volume with 2048-byte sectors.

function IsISO9660Stream(Stream: TStream): Boolean;
// SYSTEM.CNF with BOOT2 (PlayStation 2), False otherwise.

function ReadPS2DiscInfo(Image: TDVDImage; out Info: TPS2DiscInfo): Boolean;

implementation

uses
  System.Math, CHD;

{ TDVDImage }

function TDVDImage.ReadSector(LBA: Int64): TBytes;
begin
  SetLength(Result, DVDSectorSize);
  ReadSectors(LBA, 1, @Result[0]);
end;

function TDVDImage.IsDVD: Boolean;
begin
  Result := True;
end;

procedure TDVDImage.DetectLayers;
begin
  // A dual-layer image carries a second volume descriptor 16 sectors into
  // layer 1. On PS2 discs the primary volume size counts those 16 sectors,
  // so the descriptor sits at the volume size and layer 1 starts 16 sectors
  // earlier; an image whose layer 1 starts right at the volume size is
  // accepted too.
  FLayerBreak := 0;
  if SectorCount < 32 then
    Exit;
  var PVD := ReadSector(16);
  if (PVD[0] <> 1) or (TEncoding.ASCII.GetString(PVD, 1, 5) <> 'CD001') then
    Exit;
  var VolumeSize := Int64(PCardinal(@PVD[80])^);
  for var Start in [VolumeSize - 16, VolumeSize] do
  begin
    if (Start <= 16) or (Start + 17 > SectorCount) then
      Continue;
    var Second := ReadSector(Start + 16);
    if (Second[0] = 1) and (TEncoding.ASCII.GetString(Second, 1, 5) = 'CD001') then
    begin
      FLayerBreak := Start;
      Exit;
    end;
  end;
end;

procedure TDVDImage.ComputeIdentity;
begin
  // Volume descriptor, root directory sector and size.
  var H := THashSHA2.Create;
  var Count := SectorCount;
  H.Update(Count, SizeOf(Count));
  for var LBA in [16, 17, 0] do
    if LBA < Count then
    begin
      var S := ReadSector(LBA);
      H.Update(S[0], Length(S));
    end;
  FIdentity := H.HashAsBytes;
end;

{ TDVDStreamImage }

constructor TDVDStreamImage.Create(Stream: TStream; Offset: Int64; SectorSize: Integer; Count: Int64);
begin
  inherited Create;
  FStream := Stream;
  if Stream = nil then
    raise EArgumentNilException.Create('DVD image stream');
  if (SectorSize <> DVDSectorSize) and (SectorSize <> 2352) and (SectorSize <> 2448) then
    raise EDVDImage.Create('Unsupported DVD image sector size');
  var StreamSize := Stream.Size;
  if (Offset < 0) or (Offset > StreamSize) then
    raise EDVDImage.Create('DVD image offset outside stream');
  var Available := (StreamSize - Offset) div SectorSize;
  if Count > Available then
    raise EDVDImage.Create('DVD image sector count exceeds stream');
  FOffset := Offset;
  FSectorSize := SectorSize;
  FDataOffset := 0;
  if (SectorSize = 2352) or (SectorSize = 2448) then
    FDataOffset := 16;
  if Count < 0 then
    Count := Available;
  FCount := Count;
  // Raw images: Mode 2 sectors have an 8-byte subheader before the data.
  if (FDataOffset = 16) and (FCount > 16) then
  begin
    var Header: array[0..15] of Byte;
    FStream.Position := FOffset + 16 * Int64(SectorSize);
    FStream.ReadBuffer(Header, 16);
    if Header[15] = 2 then
      FDataOffset := 24;
  end;
  DetectLayers;
  ComputeIdentity;
end;

destructor TDVDStreamImage.Destroy;
begin
  FStream.Free;
  inherited;
end;

function TDVDStreamImage.IsDVD: Boolean;
begin
  Result := FDataOffset = 0;
end;

function TDVDStreamImage.SectorCount: Int64;
begin
  Result := FCount;
end;

procedure TDVDStreamImage.ReadSectors(LBA: Int64; Count: Integer; Dest: PByte);
begin
  if Count <= 0 then
    Exit;
  if LBA < 0 then
    raise EDVDImage.Create('Negative DVD sector address');
  var Valid: Integer;
  if LBA >= FCount then
    Valid := 0
  else
    Valid := Integer(Min(Int64(Count), FCount - LBA));
  if Valid < Count then
    FillChar((Dest + Valid * DVDSectorSize)^, (Count - Valid) * DVDSectorSize, 0);
  if Valid <= 0 then
    Exit;
  if FSectorSize = DVDSectorSize then
  begin
    FStream.Position := FOffset + LBA * DVDSectorSize;
    FStream.ReadBuffer(Dest^, Valid * DVDSectorSize);
    Exit;
  end;
  if Length(FBuffer) < FSectorSize then
    SetLength(FBuffer, FSectorSize);
  FStream.Position := FOffset + LBA * FSectorSize;
  for var K := 0 to Valid - 1 do
  begin
    FStream.ReadBuffer(FBuffer[0], FSectorSize);
    Move(FBuffer[FDataOffset], (Dest + K * DVDSectorSize)^, DVDSectorSize);
  end;
end;

{ TDVDCDImage }

constructor TDVDCDImage.Create(Disc: TCDDisc; OwnsDisc: Boolean);
begin
  inherited Create;
  FDisc := Disc;
  FOwns := OwnsDisc;
  FStart := 0;
  FCount := Disc.LeadOut;
  ComputeIdentity;
end;

destructor TDVDCDImage.Destroy;
begin
  if FOwns then
    FDisc.Free;
  inherited;
end;

function TDVDCDImage.IsDVD: Boolean;
begin
  Result := False;
end;

function TDVDCDImage.SectorCount: Int64;
begin
  Result := FCount;
end;

procedure TDVDCDImage.ReadSectors(LBA: Int64; Count: Integer; Dest: PByte);
var
  Sector: TBytes;
begin
  for var K := 0 to Count - 1 do
  begin
    var L := LBA + K;
    if (L < FCount) and FDisc.IsData(Integer(L)) then
    begin
      FDisc.ReadData(Integer(L), Sector);
      Move(Sector[0], (Dest + K * DVDSectorSize)^, Min(Length(Sector), DVDSectorSize));
    end
    else
      FillChar((Dest + K * DVDSectorSize)^, DVDSectorSize, 0);
  end;
end;

{ Containers }

function IsISO9660Stream(Stream: TStream): Boolean;
begin
  Result := False;
  if Stream.Size < 17 * DVDSectorSize then
    Exit;
  var Header: array[0..5] of Byte;
  var Saved := Stream.Position;
  try
    Stream.Position := 16 * DVDSectorSize;
    Stream.ReadBuffer(Header, SizeOf(Header));
    Result := (Header[0] = 1) and (Header[1] = Ord('C')) and (Header[2] = Ord('D')) and (Header[3] = Ord('0')) and
      (Header[4] = Ord('0')) and (Header[5] = Ord('1'));
  finally
    Stream.Position := Saved;
  end;
end;

// Alcohol 120% descriptor: the first data track's offset in the MDF. DVDs use
// 2048-byte sectors; CDs (PS2 CD games) raw 2352/2448-byte sectors.
function OpenMDS(Stream: TStream; const Storage: IStorage; const Location: string): TDVDImage;
var
  Data: TBytes;
begin
  try
    var Size := Stream.Size;
    if Size > 1024 * 1024 then
      raise EDVDImage.Create('DVD MDS exceeds 1 MiB');
    SetLength(Data, Size);
    if Length(Data) > 0 then
      Stream.ReadBuffer(Data[0], Length(Data));
  finally
    Stream.Free;
  end;
  if (Length(Data) < $58) or (TEncoding.ASCII.GetString(Data, 0, 16) <> 'MEDIA DESCRIPTOR') then
    raise EDVDImage.Create('Not an Alcohol 120% descriptor');
  var CD := PWord(@Data[$12])^ < $10;
  var Sessions := PCardinal(@Data[$50])^;
  if Int64(Sessions) + $18 > Length(Data) then
    raise EDVDImage.Create('Invalid MDS sessions');
  var Tracks := PCardinal(@Data[Sessions + $14])^;
  var Count := Integer(Data[Sessions + $0A]);
  var Offset: Int64 := -1;
  var SectorSize := DVDSectorSize;
  var Length_: Int64 := -1;
  for var K := 0 to Count - 1 do
  begin
    var T := Int64(Tracks) + K * $50;
    if T + $50 > Length(Data) then
      Break;
    var Point := Data[T + 4];
    if (Point = 0) or (Point >= $A0) then
      Continue;
    SectorSize := PWord(@Data[T + $10])^;
    Offset := PInt64(@Data[T + $28])^;
    // DVD descriptors keep the track length where CD ones point at extras.
    if not CD then
      Length_ := PCardinal(@Data[T + $0C])^;
    Break;
  end;
  if (Offset < 0) or ((SectorSize <> DVDSectorSize) and not (CD and ((SectorSize = 2352) or (SectorSize = 2448)))) then
    raise EDVDImage.Create('Unsupported MDS track layout');
  var MDF := ChangeFileExt(Location, '.mdf');
  if not Storage.Exists(MDF) then
    MDF := ChangeFileExt(Location, '.MDF');
  var DataStream := Storage.OpenRead(MDF);
  try
    var Available := DataStream.Size - Offset;
    if Available < 0 then
      raise EDVDImage.Create('MDS track offset outside MDF image');
    if (Length_ <= 0) or (Length_ > Available div SectorSize) then
      Length_ := -1;
    var Input := DataStream;
    DataStream := nil;
    Result := TDVDStreamImage.Create(Input, Offset, SectorSize, Length_);
  finally
    DataStream.Free;
  end;
end;

function OpenDVDImage(Stream: TStream; const Storage: IStorage; const Location: string): TDVDImage;
begin
  var Input := Stream;
  try
    var Ext := LowerCase(ExtractFileExt(Location));
    if Ext = '.mds' then
    begin
      Input := nil;
      Exit(OpenMDS(Stream, Storage, Location));
    end;
    if Ext = '.chd' then
    begin
      // chdman createdvd stores 2048-byte units. CD CHDs use raw 2448-byte frames.
      var Header := TCHDFile.ReadHeader(Stream);
      if Header.UnitBytes = DVDSectorSize then
      begin
        if (Header.LogicalBytes mod DVDSectorSize) <> 0 then
          raise EDVDImage.Create('Incomplete DVD CHD sector');
        Input := nil;
        var Reader := TCHDFile.Create(Stream, True);
        try
          var DiscStream := CHD.TCHDStream.Create(Reader, True);
          Reader := nil;
          Exit(TDVDStreamImage.Create(DiscStream));
        finally
          Reader.Free;
        end;
      end;
    end;
    if (Ext = '.iso') or (Ext = '.img') or (Ext = '.mdf') then
    begin
      var SectorSize := DVDSectorSize;
      if not IsISO9660Stream(Stream) and (Stream.Size mod 2352 = 0) then
        SectorSize := 2352;
      Input := nil;
      Exit(TDVDStreamImage.Create(Stream, 0, SectorSize));
    end;
    Result := TDVDCDImage.Create(TCDDisc.Create(Stream, Storage, Location), True);
  finally
    Input.Free;
  end;
end;

{ TISO9660 }

constructor TISO9660.Create(Image: TDVDImage; Base: Int64);
begin
  inherited Create;
  FImage := Image;
  FBase := Base;
  var PVD := Image.ReadSector(Base + 16);
  if (PVD[0] <> 1) or (TEncoding.ASCII.GetString(PVD, 1, 5) <> 'CD001') then
    raise EDVDImage.Create('No ISO 9660 volume');
  FRootLBA := Base + PCardinal(@PVD[156 + 2])^;
  FRootSize := PCardinal(@PVD[156 + 10])^;
end;

class function TISO9660.HasVolume(Image: TDVDImage; Base: Int64): Boolean;
begin
  var PVD := Image.ReadSector(Base + 16);
  Result := (PVD[0] = 1) and (TEncoding.ASCII.GetString(PVD, 1, 5) = 'CD001');
end;

function TISO9660.ReadDirectory(LBA, Size: Int64): TArray<TISO9660Entry>;
begin
  Result := nil;
  if (Size <= 0) or (Size > 4 * 1024 * 1024) then
    Exit;
  var Sectors := Integer((Size + DVDSectorSize - 1) div DVDSectorSize);
  var Data: TBytes;
  SetLength(Data, Sectors * DVDSectorSize);
  FImage.ReadSectors(LBA, Sectors, @Data[0]);
  var P := 0;
  while P < Size do
  begin
    var Len := Data[P];
    if Len = 0 then
    begin
      // Records do not cross sectors: skip to the next one.
      P := (P div DVDSectorSize + 1) * DVDSectorSize;
      Continue;
    end;
    if (Len < 34) or (P + Len > Size) or ((P mod DVDSectorSize) + Len > DVDSectorSize) then
      raise EDVDImage.Create('Invalid ISO 9660 directory record');
    var NameLen := Data[P + 32];
    if (NameLen = 0) or (NameLen > Len - 33) then
      raise EDVDImage.Create('Invalid ISO 9660 file identifier');
    var E: TISO9660Entry;
    E.LBA := FBase + PCardinal(@Data[P + 2])^;
    E.Size := PCardinal(@Data[P + 10])^;
    E.Directory := (Data[P + 25] and 2) <> 0;
    if (NameLen = 1) and (Data[P + 33] <= 1) then
      E.Name := ''
    else
    begin
      E.Name := TEncoding.ANSI.GetString(Data, P + 33, NameLen);
      var Semi := E.Name.IndexOf(';');
      if Semi >= 0 then
        E.Name := E.Name.Substring(0, Semi);
      if E.Name.EndsWith('.') then
        E.Name := E.Name.Substring(0, Length(E.Name) - 1);
    end;
    if E.Name <> '' then
      Result := Result + [E];
    Inc(P, Len);
  end;
end;

function TISO9660.Find(const Path: string; out Entry: TISO9660Entry): Boolean;
begin
  var Parts := Path.Replace('\', '/').Split(['/'], TStringSplitOptions.ExcludeEmpty);
  var LBA := FRootLBA;
  var Size := FRootSize;
  Entry := Default(TISO9660Entry);
  Entry.LBA := LBA;
  Entry.Size := Size;
  Entry.Directory := True;
  for var I := 0 to High(Parts) do
  begin
    var Name := Parts[I];
    var Semi := Name.IndexOf(';');
    if Semi >= 0 then
      Name := Name.Substring(0, Semi);
    var Found := False;
    for var E in ReadDirectory(LBA, Size) do
      if SameText(E.Name, Name) then
      begin
        Entry := E;
        Found := True;
        Break;
      end;
    if not Found then
      Exit(False);
    LBA := Entry.LBA;
    Size := Entry.Size;
  end;
  Result := True;
end;

function TISO9660.ReadFile(const Path: string; MaximumSize: Integer): TBytes;
var
  E: TISO9660Entry;
begin
  Result := nil;
  if not Find(Path, E) or E.Directory then
    Exit;
  var Size := Min(E.Size, Int64(MaximumSize));
  var Sectors := Integer((Size + DVDSectorSize - 1) div DVDSectorSize);
  SetLength(Result, Sectors * DVDSectorSize);
  if Sectors > 0 then
    FImage.ReadSectors(E.LBA, Sectors, @Result[0]);
  SetLength(Result, Size);
end;

function TISO9660.List(const Path: string): TArray<TISO9660Entry>;
var
  E: TISO9660Entry;
begin
  Result := nil;
  if Find(Path, E) and E.Directory then
    Result := ReadDirectory(E.LBA, E.Size);
end;

function ReadPS2DiscInfo(Image: TDVDImage; out Info: TPS2DiscInfo): Boolean;
begin
  Info := Default(TPS2DiscInfo);
  Result := False;
  if not TISO9660.HasVolume(Image) then
    Exit;
  var ISO := TISO9660.Create(Image);
  try
    var Text := TEncoding.ANSI.GetString(ISO.ReadFile('SYSTEM.CNF', 4096));
    for var Line in Text.Split([#10, #13], TStringSplitOptions.ExcludeEmpty) do
    begin
      var Eq := Line.IndexOf('=');
      if Eq < 0 then
        Continue;
      var Key := Line.Substring(0, Eq).Trim.ToUpper;
      var Value := Line.Substring(Eq + 1).Trim;
      if Key = 'BOOT2' then
        Info.Boot2 := Value
      else if Key = 'VMODE' then
        Info.VMode := Value.ToUpper
      else if Key = 'VER' then
        Info.Version := Value;
    end;
    if Info.Boot2 = '' then
      Exit;
    // cdrom0:\SLUS_208.11;1 -> SLUS-20811
    var Name := Info.Boot2;
    var Slash := Name.LastIndexOfAny(['\', '/', ':']);
    Name := Name.Substring(Slash + 1);
    var Semi := Name.IndexOf(';');
    if Semi >= 0 then
      Name := Name.Substring(0, Semi);
    Info.Serial := Name.Replace('_', '-').Replace('.', '');
    Result := True;
  finally
    ISO.Free;
  end;
end;

end.

