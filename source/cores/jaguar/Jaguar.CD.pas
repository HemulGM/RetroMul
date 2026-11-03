unit Jaguar.CD;

interface

uses
  System.SysUtils, System.Classes, Core.CD.Disc, Core.Snapshots, HW.EEPROM93Cxx,
  Jaguar.Video;

type
  TJaguarCDSample = procedure(Left, Right: SmallInt) of object;

  TJaguarCDTrace = procedure(Offset, Value: Cardinal; Size: Integer) of object;

  // BUTCH and the Philips DSA transport. Disc ownership stays with the worker.
  // No filesystem is imposed: Jaguar data tracks use the Red Book word stream.
  TJaguarCD = class
  private
    FDisc: TCDDisc;
    FIRQ: TJaguarIRQ;
    FSample: TJaguarCDSample;
    FTrace, FReadTrace: TJaguarCDTrace;
    FEEPROM: TSerialEEPROM93Cxx;
    FRegs: array[0..11] of Cardinal;
    FFIFO: array[0..15] of Cardinal;
    FResponses: array[0..1023] of Word;
    FRead, FWrite, FCount, FResponseRead, FResponseWrite, FResponseCount: Integer;
    FResponseDelay, FSeekDelay, FLBA, FByte, FMinute, FSecond: Integer;
    FSpeed, FMode, FVolume, FError: Byte;
    FPhase: Int64;
    FPlaying, FPaused, FIRQLevel, FResponseReady, FFramePending, FTimePending: Boolean;
    FSector: TBytes;
    FLastResponse, FLastWord: Word;
    FSerialLeft, FSerialRight: SmallInt;
    FSubQ: array[0..11] of Byte;
    FDataSessionStart: Integer;
    // Derived from immutable media at insertion; rebuilt before state load.
    FTrackReadShift: TArray<Integer>;
    FTrackPrefix: TArray<Boolean>;
    FCDIDataEnd: Int64;
    FMediaCorrection: string;
    FUnderflows, FOverflows: UInt64;
    procedure InspectCDILayout;
    procedure ReadMediaSector(LBA: Integer; var Sector: TBytes);
    function SessionCount: Integer;
    function SessionOf(Index: Integer): Integer;
    procedure Queue(Value: Word);
    procedure Command(Value: Word);
    procedure Seek(LBA: Integer);
    procedure UpdateIRQ;
    function Status: Cardinal;
    function GetLastCommand: Word;
    function ReadRegister(Index: Integer): Cardinal;
    procedure LoadSector;
    procedure SampleTick;
  public
    constructor Create(IRQ: TJaguarIRQ; Sample: TJaguarCDSample);
    destructor Destroy; override;
    procedure Reset;
    procedure InsertDisc(Disc: TCDDisc);
    function ReadBootCode(out Address: Cardinal; out Code: TBytes; PositionDrive: Boolean = True): Boolean;
    class function IsJaguarDisc(Disc: TCDDisc): Boolean; static;
    function TrackSession(Number: Integer): Integer;
    procedure StartAt(LBA, ByteOffset: Integer);
    procedure Clock(Cycles: Integer);
    function Read(Offset: Cardinal; Size: Integer): Cardinal;
    procedure Write(Offset, Value: Cardinal; Size: Integer);
    procedure SerializeState(State: TStateArchive);
    property Disc: TCDDisc read FDisc;
    property EEPROM: TSerialEEPROM93Cxx read FEEPROM;
    property LastCommand: Word read GetLastCommand;
    property OnRegisterWrite: TJaguarCDTrace read FTrace write FTrace;
    property OnFIFORead: TJaguarCDTrace read FReadTrace write FReadTrace;
    property PositionLBA: Integer read FLBA;
    property FIFOCount: Integer read FCount;
    property Underflows: UInt64 read FUnderflows;
    property Overflows: UInt64 read FOverflows;
    property MediaCorrection: string read FMediaCorrection;
  end;

implementation

uses
  System.Math;

{$Q-}{$R-}

const
  MasterClock = 26590906;
  ResponseCycles = 2048; // serial command/response latency, not host poll count

function MSF(Frames: Integer): Cardinal;
begin
  Frames := Max(0, Frames);
  Result := (Cardinal(Frames div 4500) shl 16) or
    (Cardinal(Frames div 75 mod 60) shl 8) or Cardinal(Frames mod 75);
end;

function JaguarCDPrefix: TBytes;
begin
  // Atari's invariant first data-track framing, before the load address.
  SetLength(Result, 98);
  for var i := 0 to 15 do
  begin
    Result[2 + i * 4] := Ord('A');
    Result[3 + i * 4] := Ord('T');
    Result[4 + i * 4] := Ord('R');
    Result[5 + i * 4] := Ord('I');
  end;
  const Magic: AnsiString = 'ATARI APPROVED DATA HEADER ATRI ';
  for var i := 1 to Length(Magic) do
    Result[65 + i] := Ord(Magic[i]);
  // Disc audio stores each big-endian guest word in little-endian order.
  for var i := 0 to Length(Result) div 2 - 1 do
  begin
    var B := Result[i * 2];
    Result[i * 2] := Result[i * 2 + 1];
    Result[i * 2 + 1] := B;
  end;
end;

procedure TJaguarCD.InspectCDILayout;
const
  Window = 65536;
begin
  FTrackReadShift := nil;
  FTrackPrefix := nil;
  FCDIDataEnd := 0;
  FMediaCorrection := '';
  if FDisc = nil then
    Exit;
  SetLength(FTrackReadShift, FDisc.TrackCount);
  SetLength(FTrackPrefix, FDisc.TrackCount);
  var Boot := -1;
  for var i := 1 to FDisc.TrackCount do
    if FDisc.Track(i).Session = 2 then
    begin
      Boot := i - 1;
      Break;
    end;
  if Boot < 0 then
    Exit;
  var Track := FDisc.Track(Boot + 1);
  if not Track.Audio or (Track.SectorSize <> 2352) or
    not SameText(ExtractFileExt(Track.SourceName), '.cdi') then
    Exit;
  var Input := Track.Stream;
  if Input.Size < 8 then
    Exit;
  var Saved := Input.Position;
  try
    Input.Position := Input.Size - 8;
    var Version, HeaderOffset: Cardinal;
    Input.ReadBuffer(Version, 4);
    Input.ReadBuffer(HeaderOffset, 4);
    if not ((Version = $80000004) or (Version = $80000005) or (Version = $80000006)) then
      Exit;
    FCDIDataEnd := HeaderOffset;
    if Version = $80000006 then
      FCDIDataEnd := Input.Size - HeaderOffset;
    if (FCDIDataEnd < 0) or (FCDIDataEnd > Input.Size - 8) then
      Exit;
    var DataStart := Track.ByteOffset + Int64(Track.FileSector) * 2352;
    var ScanStart := Max(Track.ByteOffset, DataStart - Window);
    var Count := Integer(Min(Int64(Window * 2), FCDIDataEnd - ScanStart));
    if (Count < 98) or (DataStart < ScanStart) or (DataStart - ScanStart > Count - 98) then
      Exit;
    var Bytes: TBytes;
    SetLength(Bytes, Count);
    Input.Position := ScanStart;
    Input.ReadBuffer(Bytes[0], Count);
    var Expected := Integer(DataStart - ScanStart);
    var Prefix := JaguarCDPrefix;
    var Found := False;
    var Best := 0;
    // A displaced CDI payload is not a different TOC. Normalize its byte
    // view, leaving the source file and the shared CD reader untouched.
    // The sync run and full magic must agree; positive shifts need silence.
    for var P := 66 to Count - 32 do
    begin
      if (P and 1 <> 0) or not CompareMem(@Bytes[P], @Prefix[66], 32) or
        not CompareMem(@Bytes[P - 64], @Prefix[2], 64) then
        Continue;
      var Delta := Integer(ScanStart + P - 66 - DataStart);
      if (Abs(Delta) >= Window) or
        ((Version = $80000004) and (Delta < -Track.FileSector * 2352)) then
        Continue;
      var Valid := True;
      if Delta > 0 then
        for var J := Expected to Expected + Delta - 1 do
          if Bytes[J] <> 0 then
          begin
            Valid := False;
            Break;
          end;
      if Valid and (not Found or (Abs(Delta) < Abs(Best))) then
      begin
        Found := True;
        Best := Delta;
      end;
    end;
    if Found then
    begin
      if Best <> 0 then
      begin
        if Version = $80000004 then
          FTrackReadShift[Boot] := Best
        else
          for var i := 0 to High(FTrackReadShift) do
          begin
            var Item := FDisc.Track(i + 1);
            if Item.Audio and (Item.SectorSize = 2352) then
              FTrackReadShift[i] := Best;
          end;
        FMediaCorrection := Format('CDI byte displacement %d (boot track %d)', [Best, Track.Number]);
      end;
      Exit;
    end;
    if Version <> $80000004 then
      Exit;
    // Some V2 dumps lost only the constant prefix. Require a unique suffix
    // of at least six bytes. Never invent entry, length or executable bytes.
    for var Lost := 1 to 92 do
      if (Lost <= Track.FileSector * 2352) and
        CompareMem(@Bytes[Expected], @Prefix[Lost], 98 - Lost) then
      begin
        FTrackReadShift[Boot] := -Lost;
        FTrackPrefix[Boot] := True;
        FMediaCorrection := Format('CDI V2 constant prefix restored: %d bytes (track %d)', [Lost, Track.Number]);
        Exit;
      end;
  finally
    Input.Position := Saved;
  end;
end;

procedure TJaguarCD.ReadMediaSector(LBA: Integer; var Sector: TBytes);
begin
  var Index := FDisc.TrackAt(LBA);
  if (Index >= 0) and (Index < Length(FTrackReadShift)) and
    ((FTrackReadShift[Index] <> 0) or FTrackPrefix[Index]) then
  begin
    var Track := FDisc.Track(Index + 1);
    var Position := Track.ByteOffset + Int64(Track.FileSector + LBA - Track.StartLBA) * Track.SectorSize +
      FTrackReadShift[Index];
    SetLength(Sector, 2352);
    FillChar(Sector[0], 2352, 0);
    var Skip := Integer(Max(Int64(0), Track.ByteOffset - Position));
    Position := Max(Track.ByteOffset, Position);
    var Count := Integer(Min(Int64(2352 - Skip), FCDIDataEnd - Position));
    if (Skip < 2352) and (Count > 0) then
    begin
      Track.Stream.Position := Position;
      Track.Stream.ReadBuffer(Sector[Skip], Count);
    end;
    if FTrackPrefix[Index] and (LBA = Track.StartLBA) then
    begin
      var Prefix := JaguarCDPrefix;
      Move(Prefix[0], Sector[0], Length(Prefix));
    end;
    Exit;
  end;
  if FDisc.IsData(LBA) then
    FDisc.ReadRawData(LBA, Sector)
  else
    FDisc.ReadAudio(LBA, Sector);
end;

constructor TJaguarCD.Create(IRQ: TJaguarIRQ; Sample: TJaguarCDSample);
begin
  inherited Create;
  FIRQ := IRQ;
  FSample := Sample;
  FEEPROM := TSerialEEPROM93Cxx.Create(128, 16);
  SetLength(FSector, 2352);
  Reset;
end;

destructor TJaguarCD.Destroy;
begin
  FEEPROM.Free;
  inherited;
end;

procedure TJaguarCD.Reset;
begin
  FillChar(FRegs, SizeOf(FRegs), 0);
  FillChar(FSubQ, SizeOf(FSubQ), 0);
  FillChar(FFIFO, SizeOf(FFIFO), 0);
  FillChar(FResponses, SizeOf(FResponses), 0);
  FillChar(FSector[0], Length(FSector), 0);
  FRead := 0;
  FWrite := 0;
  FCount := 0;
  FUnderflows := 0;
  FOverflows := 0;
  FResponseRead := 0;
  FResponseWrite := 0;
  FResponseCount := 0;
  FResponseDelay := 0;
  FSeekDelay := 0;
  FLBA := 0;
  FByte := 0;
  FMinute := 0;
  FSecond := 0;
  FSpeed := 1;
  FMode := 1;
  FVolume := 255;
  FError := 0;
  FPhase := 0;
  FPlaying := False;
  FPaused := False;
  FIRQLevel := False;
  FResponseReady := False;
  FFramePending := False;
  FTimePending := False;
  FLastResponse := 0;
  FLastWord := 0;
  FSerialLeft := 0;
  FSerialRight := 0;
  FEEPROM.Reset;
end;

procedure TJaguarCD.InsertDisc(Disc: TCDDisc);
begin
  FDisc := Disc;
  FPlaying := False;
  FPaused := False;
  FSeekDelay := 0;
  FCount := 0;
  FResponseCount := 0;
  FResponseRead := 0;
  FResponseWrite := 0;
  FResponseReady := False;
  FFramePending := False;
  FTimePending := False;
  FSector := nil;
  SetLength(FSector, 2352);
  FError := 0;
  if Disc = nil then
    FError := 2;
  FDataSessionStart := 0;
  InspectCDILayout;
  if Disc <> nil then
  begin
    var Entry: Cardinal;
    var Code: TBytes;
    ReadBootCode(Entry, Code, False);
  end;
  UpdateIRQ;
end;

procedure TJaguarCD.StartAt(LBA, ByteOffset: Integer);
begin
  FLBA := LBA;
  FByte := ByteOffset;
  FPhase := 0;
  FSpeed := 2;
  FMode := $0A;
  FPlaying := True;
  FPaused := False;
  LoadSector;
end;

class function TJaguarCD.IsJaguarDisc(Disc: TCDDisc): Boolean;
begin
  var Probe := TJaguarCD.Create(nil, nil);
  try
    Probe.InsertDisc(Disc);
    var Entry: Cardinal;
    var Code: TBytes;
    Result := Probe.ReadBootCode(Entry, Code, False);
  finally
    Probe.Free;
  end;
end;

function TJaguarCD.TrackSession(Number: Integer): Integer;
begin
  Result := SessionOf(Number - 1);
end;

function TJaguarCD.ReadBootCode(out Address: Cardinal; out Code: TBytes; PositionDrive: Boolean): Boolean;
const
  Header: AnsiString = 'ATARI APPROVED DATA HEADER ATRI ';
var
  Raw, Sector: TBytes;

  procedure ReadTrackSector(LBA: Integer);
  begin
    ReadMediaSector(LBA, Sector);
  end;

  function DataByte(Offset: Integer; Swapped: Boolean): Byte;
  begin
    if Swapped then
      Offset := Offset xor 1;
    Result := Raw[Offset];
  end;

  function LongAt(Offset: Integer; Swapped: Boolean): Cardinal;
  begin
    Result := 0;
    for var i := 0 to 3 do
      Result := (Result shl 8) or DataByte(Offset + i, Swapped);
  end;

begin
  Result := False;
  Address := 0;
  Code := nil;
  if FDisc = nil then
    Exit;
  for var T := 1 to FDisc.TrackCount do
  begin
    var Track := FDisc.Track(T);
    // INDEX 01 is a TOC position, not a boundary for Atari's byte stream.
    // Mastered discs can put the boot header in the stored INDEX 00 audio.
    var FirstLBA := Track.StartLBA - Min(150, Track.StoredPregap);
    var Sectors := Min(Track.StartLBA - FirstLBA + 32, Track.EndLBA - FirstLBA);
    if Sectors <= 0 then
      Continue;
    SetLength(Raw, Sectors * 2352);
    for var N := 0 to Sectors - 1 do
    begin
      ReadTrackSector(FirstLBA + N);
      Move(Sector[0], Raw[N * 2352], 2352);
    end;
    for var Swap := False to True do
      for var P := 0 to (Length(Raw) - 40) div 2 do
      begin
        var Offset := P * 2;
        var Match := True;
        // The last byte is Atari's per-track sequence character.
        for var i := 0 to 30 do
          if DataByte(Offset + i, Swap) <> Byte(Header[i + 1]) then
          begin
            Match := False;
            Break;
          end;
        if not Match then
          Continue;
        var Entry := LongAt(Offset + 32, Swap);
        var Count := LongAt(Offset + 36, Swap);
        if (Entry < $4000) or (Entry >= $200000) or (Entry and 1 <> 0) or
          (Count = 0) or (Count > $200000 - Entry) then
          Continue;
        var EndOffset := Offset + 40 + Integer(Count);
        if (T <= Length(FTrackReadShift)) and (FTrackReadShift[T - 1] <> 0) then
        begin
          var PhysicalEnd := Track.ByteOffset +
            Int64(Track.FileSector + FirstLBA - Track.StartLBA) * Track.SectorSize +
            FTrackReadShift[T - 1] + EndOffset;
          // Sector reads can pad a missing recording tail with silence;
          // silence must never stand in for a missing boot executable.
          if PhysicalEnd > FCDIDataEnd then
            Continue;
        end;
        var Required := (EndOffset + 2351) div 2352;
        if Required > Track.EndLBA - FirstLBA then
          Continue;
        if Required > Sectors then
        begin
          SetLength(Raw, Required * 2352);
          for var N := Sectors to Required - 1 do
          begin
            ReadTrackSector(FirstLBA + N);
            Move(Sector[0], Raw[N * 2352], 2352);
          end;
        end;
        SetLength(Code, Count);
        for var i := 0 to Integer(Count) - 1 do
          Code[i] := DataByte(Offset + 40 + i, Swap);
        Address := Entry;
        // Plain CUE has no session field. Infer its audio/data boundary from
        // Atari's boot header, while preserving explicit CDI/CHD/MDS sessions.
        var ExplicitSessions := False;
        for var i := 1 to FDisc.TrackCount do
          ExplicitSessions := ExplicitSessions or (FDisc.Track(i).Session > 1);
        if not ExplicitSessions and (T > 1) then
          FDataSessionStart := T;
        if PositionDrive then
          StartAt(FirstLBA + EndOffset div 2352, EndOffset mod 2352);
        Exit(True);
      end;
  end;
end;

function TJaguarCD.SessionOf(Index: Integer): Integer;
begin
  Result := Max(1, FDisc.Track(Index + 1).Session) - 1;
  if (FDataSessionStart > 0) and (Index + 1 >= FDataSessionStart) then
    Result := 1;
end;

function TJaguarCD.SessionCount: Integer;
begin
  Result := 0;
  if FDisc <> nil then
    for var i := 0 to FDisc.TrackCount - 1 do
      Result := Max(Result, SessionOf(i) + 1);
end;

procedure TJaguarCD.Queue(Value: Word);
begin
  if FResponseCount = Length(FResponses) then
    Exit;
  FResponses[FResponseWrite] := Value;
  FResponseWrite := (FResponseWrite + 1) and High(FResponses);
  Inc(FResponseCount);
  if (FResponseDelay = 0) and not FResponseReady then
    FResponseDelay := ResponseCycles;
end;

procedure TJaguarCD.Seek(LBA: Integer);
begin
  if (FDisc = nil) or (LBA < 0) or (LBA >= FDisc.LeadOut) then
  begin
    FError := $29;
    Queue($0400 or FError);
    Exit;
  end;
  // A finite mechanical delay; distance affects it. Never synthesize data in a
  // register read: software polling frequency must not change drive speed.
  FSeekDelay := MasterClock div 100 + Abs(FLBA - LBA) * 12;
  FLBA := LBA;
  FByte := 0;
  FPhase := 0;
  FPlaying := False;
  FRead := 0;
  FWrite := 0;
  FCount := 0;
end;

procedure TJaguarCD.Command(Value: Word);
begin
  if FRegs[1] and $10000 = 0 then
    Exit;
  var Op := Value shr 8;
  var Param := Value and 255;
  if (FDisc = nil) and not (Op in [$16, $17, $50, $51, $70]) then
  begin
    FError := 2;
    Queue($0402);
    Exit;
  end;
  case Op of
    $01:
      begin
        var Found := False;
        for var i := 0 to FDisc.TrackCount - 1 do
          if FDisc.Track(i + 1).Number = Param then
          begin
            Seek(FDisc.Track(i + 1).StartLBA);
            Found := True;
            Break;
          end;
        if not Found then
        begin
          FError := $29;
          Queue($0429);
        end;
      end;
    $02:
      begin
        FPlaying := False;
        FPaused := False;
        Queue($0200);
      end;
    $03, $14:
      begin
        var First := -1;
        var Last := -1;
        for var i := 0 to FDisc.TrackCount - 1 do
          if SessionOf(i) = Param then
          begin
            if First < 0 then
              First := i;
            Last := i;
          end;
        if First < 0 then
        begin
          FError := $29;
          Queue($0429);
          Exit;
        end;
        if Op = $03 then
        begin
          Queue($2000 or FDisc.Track(First + 1).Number);
          Queue($2100 or FDisc.Track(Last + 1).Number);
          var Time := MSF(FDisc.Track(Last + 1).EndLBA + 150);
          Queue($2200 or (Time shr 16));
          Queue($2300 or ((Time shr 8) and 255));
          Queue($2400 or (Time and 255));
        end
        else
          for var i := First to Last do
          begin
            var Track := FDisc.Track(i + 1);
            var Time := MSF(Track.StartLBA + 150);
            Queue($6000 or Track.Number);
            var Control := 1;
            if not Track.Audio then
              Control := $41;
            Queue($6100 or Control);
            Queue($6200 or (Time shr 16));
            Queue($6300 or ((Time shr 8) and 255));
            Queue($6400 or (Time and 255));
          end;
        Queue($0400);
      end;
    $04:
      begin
        FPaused := True;
        Queue($0400);
      end;
    $05:
      begin
        FPaused := False;
        Queue($0400);
      end;
    $09:
      begin
        var Duration := -1;
        for var i := 0 to FDisc.TrackCount - 1 do
          if FDisc.Track(i + 1).Number = Param then
            Duration := (FDisc.Track(i + 1).EndLBA - FDisc.Track(i + 1).StartLBA) div 75;
        if Duration < 0 then
          Queue($0429)
        else
        begin
          Queue($0900 or (Duration and 255));
          Queue($0A00 or (Duration shr 8));
          Queue($0400);
        end;
      end;
    $0D:
      begin
        var Time := MSF(FLBA + 150);
        Queue($1400 or (Time shr 16));
        Queue($1500 or ((Time shr 8) and 255));
        Queue($1600 or (Time and 255));
        Queue($0400);
      end;
    $10:
      FMinute := Param;
    $11:
      FSecond := Param;
    $12:
      if (FMinute > 99) or (FSecond > 59) or (Param > 74) then
        Queue($0429)
      else
        Seek((FMinute * 60 + FSecond) * 75 + Param - 150);
    $15:
      begin
        if (Param and 7 in [1, 2]) then
          FSpeed := Param and 7;
        FMode := Param;
        Queue($1700 or Param);
      end;
    $16:
      Queue($0400 or FError);
    $17:
      begin
        FError := 0;
        Queue($0400);
      end;
    $18:
      if Param < SessionCount then
        Queue($0143)
      else
        Queue($0429);
    $50:
      if FDisc = nil then
        Queue($0300)
      else
        Queue($0301);
    $51:
      begin
        FVolume := Param;
        Queue(Value);
      end;
    $54:
      Queue($5400 or SessionCount);
    $6A:
      Queue($6A00);
    $70:
      Queue(Value);
  else
    FError := $22;
    Queue($0422);
  end;
  UpdateIRQ;
end;

function TJaguarCD.Status: Cardinal;
begin
  Result := (FRegs[0] and $FFFF007F) or $1000;
  if FCount >= 8 then
    Result := Result or $200;
  if FTimePending then
    Result := Result or $400;
  if FFramePending then
    Result := Result or $800;
  if FResponseReady then
    Result := Result or $2000;
  if FError <> 0 then
    Result := Result or $4000;
end;

function TJaguarCD.GetLastCommand: Word;
begin
  Result := Word(FRegs[2]);
end;

procedure TJaguarCD.UpdateIRQ;
begin
  var S := Status;
  var Active := (S and 1 <> 0) and (((S shr 8) and S and $7E) <> 0);
  if Active and not FIRQLevel and Assigned(FIRQ) then
    FIRQ(0);
  FIRQLevel := Active;
end;

function TJaguarCD.ReadRegister(Index: Integer): Cardinal;
begin
  Result := FRegs[Index];
  case Index of
    0:
      Result := Status;
    2:
      begin
        if FResponseReady and (FResponseCount > 0) then
        begin
          FLastResponse := FResponses[FResponseRead];
          FResponseRead := (FResponseRead + 1) and High(FResponses);
          Dec(FResponseCount);
          FResponseReady := False;
          if FResponseCount > 0 then
            FResponseDelay := ResponseCycles;
        end;
        Result := FLastResponse;
      end;
    4:
      begin
        Result := Result and not $10;
        if FCount > 0 then
          Result := Result or $10;
      end;
    5:
      begin
        FFramePending := False;
        FTimePending := False;
      end;
    6:
      if FRegs[5] <> 0 then
      begin
        var SubIndex := Min(11, FByte div (49 * 4));
        Result := (Cardinal(FSubQ[SubIndex]) shl 8) or Cardinal($10 + SubIndex);
      end;
    9, 10:
      begin
        Result := FFIFO[FRead];
      end;
    11:
      Result := (Result and not 8) or (Cardinal(Ord(FEEPROM.Output)) shl 3);
  end;
end;

function TJaguarCD.Read(Offset: Cardinal; Size: Integer): Cardinal;
begin
  Result := 0;
  if (Offset >= $30) or not (Size in [1, 2, 4]) then
    Exit;
  var Index := Integer(Offset div 4);
  var V: Cardinal;
  if (Index = 2) and (Offset + Cardinal(Size) <= $A) then
    V := 0
  else
    V := ReadRegister(Index);
  Result := V shr ((4 - Size - Integer(Offset and 3)) * 8);
  if Size = 1 then
    Result := Result and 255
  else if Size = 2 then
    Result := Result and 65535;
  if (Index in [9, 10]) and Assigned(FReadTrace) then
    FReadTrace(Offset, Result, Size);
  // FIFO has 32-bit cells. Reading both 68k words consumes exactly one cell.
  if (Index in [9, 10]) and ((Offset and 3) + Cardinal(Size) >= 4) then
    if FCount > 0 then
    begin
      FRead := (FRead + 1) and 15;
      Dec(FCount);
    end
    else
      Inc(FUnderflows);
  UpdateIRQ;
end;

procedure TJaguarCD.Write(Offset, Value: Cardinal; Size: Integer);
begin
  if (Offset >= $30) or not (Size in [1, 2, 4]) then
    Exit;
  if Assigned(FTrace) then
    FTrace(Offset, Value, Size);
  var Index := Integer(Offset div 4);
  var Shift := (4 - Size - Integer(Offset and 3)) * 8;
  var Mask: Cardinal := $FFFFFFFF;
  if Size = 1 then
    Mask := 255
  else if Size = 2 then
    Mask := 65535;
  var V := (FRegs[Index] and not (Mask shl Shift)) or ((Value and Mask) shl Shift);
  if Index = 0 then
    V := V and $FFFF007F;
  if Index = 4 then
    V := V and not $10;
  FRegs[Index] := V;
  if (Index = 2) and (Offset + Cardinal(Size) > $A) then
    Command(Word(V));
  if Index = 11 then
    FEEPROM.Lines(V and 1 <> 0, V and 2 <> 0, V and 4 <> 0);
  // An ICR service re-evaluates the external interrupt after the bus cycle.
  if Index = 0 then
    FIRQLevel := False;
  UpdateIRQ;
end;

procedure TJaguarCD.LoadSector;
begin
  if (FDisc = nil) or (FLBA >= FDisc.LeadOut) then
  begin
    FPlaying := False;
    FillChar(FSector[0], 2352, 0);
    Exit;
  end;
  ReadMediaSector(FLBA, FSector);
  var Q: TBytes;
  FDisc.ReadSubQ(FLBA, Q);
  Move(Q[0], FSubQ, SizeOf(FSubQ));
  FFramePending := True;
  if (FRegs[8] and $1000000 <> 0) and (MSF(FLBA + 150) = FRegs[8] and $FFFFFF) then
    FTimePending := True;
end;

procedure TJaguarCD.SampleTick;
begin
  if FByte >= 2352 then
  begin
    Inc(FLBA);
    FByte := 0;
    LoadSector;
  end;
  if not FPlaying then
    Exit;
  var Left := Word(FSector[FByte]) or (Word(FSector[FByte + 1]) shl 8);
  var Right := Word(FSector[FByte + 2]) or (Word(FSector[FByte + 3]) shl 8);
  Inc(FByte, 4);
  if FRegs[4] and 1 <> 0 then
  begin
    if FRegs[4] and 4 <> 0 then
    begin
      // I2S assembles a FIFO long from right/left words. The left word of
      // the following stereo frame is paired with the preceding right word.
      var V := (Cardinal(FLastWord) shl 16) or Left;
      FFIFO[FWrite] := V;
      FWrite := (FWrite + 1) and 15;
      if FCount = 16 then
      begin
        FRead := (FRead + 1) and 15;
        Inc(FOverflows);
      end
      else
        Inc(FCount);
    end;
    if FRegs[4] and 2 <> 0 then
    begin
      FSerialLeft := SmallInt(Integer(SmallInt(Left)) * FVolume div 255);
      FSerialRight := SmallInt(Integer(SmallInt(Right)) * FVolume div 255);
      if Assigned(FSample) then
        FSample(FSerialLeft, FSerialRight);
    end;
  end;
  FLastWord := Right;
end;

procedure TJaguarCD.Clock(Cycles: Integer);
begin
  if FResponseDelay > 0 then
  begin
    Dec(FResponseDelay, Cycles);
    if FResponseDelay <= 0 then
    begin
      FResponseDelay := 0;
      FResponseReady := FResponseCount > 0;
    end;
  end;
  if FSeekDelay > 0 then
  begin
    Dec(FSeekDelay, Cycles);
    if FSeekDelay <= 0 then
    begin
      FSeekDelay := 0;
      FPlaying := True;
      FByte := 0;
      LoadSector;
      Queue($0100);
    end;
  end
  else if FPlaying and not FPaused then
  begin
    Inc(FPhase, Int64(Cycles) * 44100 * FSpeed);
    while FPhase >= MasterClock do
    begin
      Dec(FPhase, MasterClock);
      SampleTick;
    end;
  end;
  UpdateIRQ;
end;

procedure TJaguarCD.SerializeState(State: TStateArchive);
begin
  var Identity: TBytes;
  if FDisc <> nil then
    Identity := FDisc.Identity
  else
    SetLength(Identity, 32);
  var Stored := Copy(Identity);
  State.Field(Stored[0], Length(Stored));
  if not CompareMem(@Stored[0], @Identity[0], Length(Identity)) then
    raise EReadError.Create('Jaguar CD snapshot requires the original inserted disc');
  State.Field(FRegs, SizeOf(FRegs));
  State.Field(FFIFO, SizeOf(FFIFO));
  State.Field(FResponses, SizeOf(FResponses));
  State.Field(FRead, SizeOf(FRead));
  State.Field(FWrite, SizeOf(FWrite));
  State.Field(FCount, SizeOf(FCount));
  State.Field(FResponseRead, SizeOf(FResponseRead));
  State.Field(FResponseWrite, SizeOf(FResponseWrite));
  State.Field(FResponseCount, SizeOf(FResponseCount));
  State.Field(FResponseDelay, SizeOf(FResponseDelay));
  State.Field(FSeekDelay, SizeOf(FSeekDelay));
  State.Field(FLBA, SizeOf(FLBA));
  State.Field(FByte, SizeOf(FByte));
  State.Field(FMinute, SizeOf(FMinute));
  State.Field(FSecond, SizeOf(FSecond));
  State.Field(FSpeed, SizeOf(FSpeed));
  State.Field(FMode, SizeOf(FMode));
  State.Field(FVolume, SizeOf(FVolume));
  State.Field(FError, SizeOf(FError));
  State.Field(FPhase, SizeOf(FPhase));
  State.Field(FPlaying, SizeOf(FPlaying));
  State.Field(FPaused, SizeOf(FPaused));
  State.Field(FIRQLevel, SizeOf(FIRQLevel));
  State.Field(FResponseReady, SizeOf(FResponseReady));
  State.Field(FFramePending, SizeOf(FFramePending));
  State.Field(FTimePending, SizeOf(FTimePending));
  State.Field(FSector[0], 2352);
  State.Field(FLastResponse, SizeOf(FLastResponse));
  State.Field(FLastWord, SizeOf(FLastWord));
  State.Field(FSerialLeft, SizeOf(FSerialLeft));
  State.Field(FSerialRight, SizeOf(FSerialRight));
  FEEPROM.SerializeState(State);
  State.Field(FSubQ, SizeOf(FSubQ));
  State.Field(FDataSessionStart, SizeOf(FDataSessionStart));
  if State.Loading and ((FCount < 0) or (FCount > 16) or
    (FResponseCount < 0) or (FResponseCount > 1024) or
    (FRead < 0) or (FRead > 15) or (FWrite < 0) or (FWrite > 15) or
    (FResponseRead < 0) or (FResponseRead > 1023) or
    (FResponseWrite < 0) or (FResponseWrite > 1023) or
    (FByte < 0) or (FByte > 2352) or not (FSpeed in [1, 2])) then
    raise EReadError.Create('Invalid Jaguar CD snapshot state');
end;

end.

