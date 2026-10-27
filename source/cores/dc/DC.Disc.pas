unit DC.Disc;

// Dreamcast view of a disc image: GD-ROM (high-density area from LBA 45000)
// or CD-ROM/CD-R (MIL-CD, multi-session), the boot track holding IP.BIN,
// ISO 9660 files at absolute sector numbers, the GD-ROM TOC layout and the
// boot-file descrambling used for CD media.
// References: Marcus Comstedt's GD-ROM, IP.BIN and scramble notes.
{$IFDEF DC_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, System.Classes, Core.CD.Disc;

const
  DCDiscCDDA = $00;
  DCDiscCDROM = $10;
  DCDiscCDROMXA = $20;
  DCDiscGDROM = $80;

type
  TDCDisc = class
  private
    FDisc: TCDDisc;
    FBootTrack: Integer;
    // First sector of IP.BIN: the boot track's start, or an IP.BIN file.
    FBootLBA: Integer;
    FSector: TBytes;
    function FindBootTrack: Integer;
    function StartsWithHardwareID(LBA: Integer): Boolean;
  public
    // The image remains owned by the caller.
    constructor Create(Disc: TCDDisc);
    // Disc type reported by the drive (GD-ROM, CD-ROM XA, ...).
    function DiscType: Cardinal;
    function IsGDROM: Boolean;
    function BootTrack: TCDTrack;
    function HasBootTrack: Boolean;
    // 2048-byte user data of the sector at LBA; False outside data tracks.
    function ReadData(LBA: Integer; Dest: PByte): Boolean;
    // Raw 2352-byte audio (zero outside audio tracks).
    procedure ReadAudio(LBA: Integer; Dest: PByte);
    function TrackOf(LBA: Integer): Integer;
    // 102 TOC words: 99 entries, first, last and lead-out. Area 1 is the
    // high-density area of a GD-ROM. Words are (CTRL<<28)|(ADR<<24)|FAD.
    function TOC(Area: Integer; out Words: TArray<Cardinal>): Boolean;
    function ReadBootSector(Index: Integer): TBytes;
    // The boot ROM descrambles boot files of CD media; images whose boot
    // area is an IP.BIN file hold GD-ROM software as it is.
    function ScrambledBootFile: Boolean;
    // Root-directory file of the boot track's ISO 9660 volume.
    function FindFile(const Name: string; out LBA: Integer; out Size: Cardinal): Boolean;
    function ReadFile(const Name: string; MaximumSize: Integer): TBytes;
    property Image: TCDDisc read FDisc;
  end;

// The boot area of a data track starts with the hardware ID string.
function IsDreamcastDisc(Disc: TCDDisc): Boolean;
// Undo the slice permutation the boot ROM applies to a CD boot file.
procedure DCDescramble(var Data: TBytes);

implementation

const
  HardwareID: AnsiString = 'SEGA SEGAKATANA ';

function SessionOf(const Track: TCDTrack): Integer;
begin
  Result := Track.Session;
  if Result < 1 then
    Result := 1;
end;

function IsDreamcastDisc(Disc: TCDDisc): Boolean;
begin
  Result := False;
  var Wrapper := TDCDisc.Create(Disc);
  try
    if not Wrapper.HasBootTrack then
      Exit;
    var Sector := Wrapper.ReadBootSector(0);
    Result := (Length(Sector) >= 16) and CompareMem(@Sector[0], PAnsiChar(HardwareID), 16);
  finally
    Wrapper.Free;
  end;
end;

constructor TDCDisc.Create(Disc: TCDDisc);
begin
  inherited Create;
  FDisc := Disc;
  SetLength(FSector, 2048);
  FBootTrack := FindBootTrack;
  if FBootTrack > 0 then
  begin
    FBootLBA := BootTrack.StartLBA;
    // Some single-session images of GD-ROM software keep the boot area as
    // the file IP.BIN of an ISO volume that starts at sector 0.
    var LBA: Integer;
    var Size: Cardinal;
    if not StartsWithHardwareID(FBootLBA) and FindFile('IP.BIN', LBA, Size) and (Size >= 16 * 2048) and
      StartsWithHardwareID(LBA) then
      FBootLBA := LBA;
  end;
end;

function TDCDisc.StartsWithHardwareID(LBA: Integer): Boolean;
begin
  var Sector: TBytes;
  SetLength(Sector, 2048);
  Result := ReadData(LBA, @Sector[0]) and CompareMem(@Sector[0], PAnsiChar(HardwareID), 16);
end;

function TDCDisc.FindBootTrack: Integer;
begin
  // GD-ROM: the first high-density track. CD: the first data track of the
  // last session (MIL-CD and CD-R boot discs).
  Result := 0;
  if FDisc.TrackCount = 0 then
    Exit;
  if FDisc.HighDensity then
  begin
    for var T := 1 to FDisc.TrackCount do
      if (FDisc.Track(T).StartLBA >= 45000) and not FDisc.Track(T).Audio then
        Exit(T);
  end;
  var LastSession := 1;
  for var T := 1 to FDisc.TrackCount do
    if SessionOf(FDisc.Track(T)) > LastSession then
      LastSession := SessionOf(FDisc.Track(T));
  for var T := 1 to FDisc.TrackCount do
    if (SessionOf(FDisc.Track(T)) = LastSession) and not FDisc.Track(T).Audio then
      Exit(T);
  for var T := 1 to FDisc.TrackCount do
    if not FDisc.Track(T).Audio then
      Exit(T);
end;

function TDCDisc.HasBootTrack: Boolean;
begin
  Result := FBootTrack > 0;
end;

function TDCDisc.BootTrack: TCDTrack;
begin
  Result := FDisc.Track(FBootTrack);
end;

function TDCDisc.IsGDROM: Boolean;
begin
  Result := FDisc.HighDensity;
end;

function TDCDisc.DiscType: Cardinal;
begin
  if FDisc.HighDensity then
    Exit(DCDiscGDROM);
  // Self-booting copies of GD-ROM software keep the IP.BIN device
  // information; their programs expect the drive to report a GD-ROM.
  if FBootTrack > 0 then
  begin
    var Sector := ReadBootSector(0);
    if TEncoding.ANSI.GetString(Sector, $20, 16).Contains('GD-ROM') then
      Exit(DCDiscGDROM);
  end;
  Result := DCDiscCDDA;
  for var T := 1 to FDisc.TrackCount do
    if not FDisc.Track(T).Audio then
    begin
      if FDisc.Track(T).DataOffset in [8, 24] then
        Exit(DCDiscCDROMXA);
      Result := DCDiscCDROM;
    end;
end;

function TDCDisc.TrackOf(LBA: Integer): Integer;
begin
  Result := FDisc.TrackAt(LBA) + 1;
end;

function TDCDisc.ReadData(LBA: Integer; Dest: PByte): Boolean;
begin
  Result := FDisc.IsData(LBA);
  if not Result then
  begin
    FillChar(Dest^, 2048, 0);
    Exit;
  end;
  FDisc.ReadData(LBA, FSector);
  Move(FSector[0], Dest^, 2048);
end;

procedure TDCDisc.ReadAudio(LBA: Integer; Dest: PByte);
begin
  var Sector: TBytes;
  FDisc.ReadAudio(LBA, Sector);
  Move(Sector[0], Dest^, 2352);
end;

function TDCDisc.ReadBootSector(Index: Integer): TBytes;
begin
  SetLength(Result, 2048);
  if (FBootTrack = 0) or not ReadData(FBootLBA + Index, @Result[0]) then
    FillChar(Result[0], 2048, 0);
end;

function TDCDisc.ScrambledBootFile: Boolean;
begin
  Result := not FDisc.HighDensity and (FBootTrack > 0) and (FBootLBA = BootTrack.StartLBA);
end;

function TDCDisc.TOC(Area: Integer; out Words: TArray<Cardinal>): Boolean;
begin
  SetLength(Words, 102);
  for var I := 0 to 101 do
    Words[I] := $FFFFFFFF;
  // Only a GD-ROM has a high-density area.
  if (Area = 1) and not FDisc.HighDensity then
    Exit(False);
  var First := 0;
  var Last := 0;
  for var T := 1 to FDisc.TrackCount do
  begin
    var Track := FDisc.Track(T);
    if FDisc.HighDensity and ((Area = 1) <> (Track.StartLBA >= 45000)) then
      Continue;
    var Control: Cardinal := 4;
    if Track.Audio then
      Control := 0;
    Words[T - 1] := (Control shl 28) or (Cardinal(1) shl 24) or Cardinal(Track.StartLBA + 150);
    if First = 0 then
      First := T;
    Last := T;
  end;
  if First = 0 then
    Exit(False);
  var FirstControl: Cardinal := 4;
  if FDisc.Track(First).Audio then
    FirstControl := 0;
  var LastControl: Cardinal := 4;
  if FDisc.Track(Last).Audio then
    LastControl := 0;
  Words[99] := (FirstControl shl 28) or (Cardinal(1) shl 24) or (Cardinal(First) shl 16);
  Words[100] := (LastControl shl 28) or (Cardinal(1) shl 24) or (Cardinal(Last) shl 16);
  Words[101] := (LastControl shl 28) or (Cardinal(1) shl 24) or Cardinal(FDisc.Track(Last).EndLBA + 150);
  Result := True;
end;

function LE32(const B: TBytes; Offset: Integer): Cardinal;
begin
  Result := Cardinal(B[Offset]) or (Cardinal(B[Offset + 1]) shl 8) or (Cardinal(B[Offset + 2]) shl 16) or
    (Cardinal(B[Offset + 3]) shl 24);
end;

function TDCDisc.FindFile(const Name: string; out LBA: Integer; out Size: Cardinal): Boolean;
begin
  Result := False;
  LBA := 0;
  Size := 0;
  if FBootTrack = 0 then
    Exit;
  // Volume descriptors from sector 16 of the boot track; extents are absolute.
  var Sector: TBytes;
  SetLength(Sector, 2048);
  var Root := -1;
  var RootSize: Cardinal := 0;
  for var D := 16 to 32 do
  begin
    if not ReadData(BootTrack.StartLBA + D, @Sector[0]) then
      Exit;
    if not CompareMem(@Sector[1], PAnsiChar(AnsiString('CD001')), 5) then
      Exit;
    if Sector[0] = 1 then
    begin
      Root := Integer(LE32(Sector, 158));
      RootSize := LE32(Sector, 166);
      Break;
    end;
    if Sector[0] = 255 then
      Exit;
  end;
  if (Root < 0) or (RootSize = 0) or (RootSize > 1024 * 1024) then
    Exit;
  var Offset: Cardinal := 0;
  while Offset < RootSize do
  begin
    if not ReadData(Root + Integer(Offset div 2048), @Sector[0]) then
      Exit;
    var Cursor := 0;
    while Cursor < 2048 do
    begin
      var RecordSize := Integer(Sector[Cursor]);
      if RecordSize = 0 then
        Break;
      if (RecordSize < 34) or (Cursor + RecordSize > 2048) then
        Exit;
      var NameSize := Integer(Sector[Cursor + 32]);
      if NameSize > RecordSize - 33 then
        Exit;
      var Identifier := TEncoding.ANSI.GetString(Sector, Cursor + 33, NameSize);
      var Version := Pos(';', Identifier);
      if Version > 0 then
        Identifier := Copy(Identifier, 1, Version - 1);
      if SameText(Identifier, Name) and ((Sector[Cursor + 25] and 2) = 0) then
      begin
        LBA := Integer(LE32(Sector, Cursor + 2));
        Size := LE32(Sector, Cursor + 10);
        Exit(True);
      end;
      Inc(Cursor, RecordSize);
    end;
    Inc(Offset, 2048);
  end;
end;

function TDCDisc.ReadFile(const Name: string; MaximumSize: Integer): TBytes;
begin
  Result := nil;
  var LBA: Integer;
  var Size: Cardinal;
  if not FindFile(Name, LBA, Size) or (Size = 0) or (Size > Cardinal(MaximumSize)) then
    Exit;
  SetLength(Result, (Size + 2047) and not Cardinal(2047));
  for var I := 0 to Integer((Size + 2047) div 2048) - 1 do
    ReadData(LBA + I, @Result[I * 2048]);
  SetLength(Result, Size);
end;

procedure DCDescramble(var Data: TBytes);
var
  Seed: Cardinal;

  function NextRandom: Cardinal;
  begin
    Seed := (Seed * 2109 + 9273) and $7FFF;
    Result := (Seed + $C000) and $FFFF;
  end;

begin
  // The file is cut into chunks of 2 MiB, then halving down to 32 bytes;
  // each chunk's 32-byte slices were permuted by a seeded generator.
  var Size := Length(Data);
  var Output: TBytes;
  SetLength(Output, Size);
  Seed := Cardinal(Size) and $FFFF;
  var Source := 0;
  var Chunk := 2048 * 1024;
  var Index: TArray<Integer>;
  while Chunk >= 32 do
  begin
    while Size - Source >= Chunk do
    begin
      var ChunkStart := Source;
      var Slices := Chunk div 32;
      SetLength(Index, Slices);
      for var I := 0 to Slices - 1 do
        Index[I] := I;
      for var I := Slices - 1 downto 0 do
      begin
        var X := Integer((NextRandom * Cardinal(I)) shr 16);
        var T := Index[I];
        Index[I] := Index[X];
        Index[X] := T;
        Move(Data[Source], Output[ChunkStart + Index[I] * 32], 32);
        Inc(Source, 32);
      end;
    end;
    Chunk := Chunk div 2;
  end;
  if Source < Size then
    Move(Data[Source], Output[Source], Size - Source);
  Data := Output;
end;

end.
