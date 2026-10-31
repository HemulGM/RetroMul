unit PS2.CDVD.Drive;

// The CDVD drive and its MECHACON as the BIOS's CDVDMAN drives them
// (External BIOS boot), registers 1F402000h-1F4020FFh on the IOP.
// N commands (seeks and reads) run in the background: the drive spins up,
// seeks and reads sectors at the disc's speed into a small buffer that DMA
// channel 3 empties, then raises its interrupt (I_STAT bits 0 and 1 of the
// drive, IOP I_STAT bit 2). S commands (MECHACON services) answer at once
// through the parameter and result FIFOs, with the exact result lengths
// CDVDMAN expects. The real-time clock follows the emulated console clock
// plus what the BIOS writes. NVM words, the configuration blocks, the model
// name and the i.Link ID live in the MECHACON's 1 KiB EEPROM (a companion
// .nvm file of the BIOS when present, blank otherwise), laid out as the
// console's MECHACON keeps it: the configuration areas (EEGS, OSD, DVD
// player) are 16-byte rows of 15 bytes and a checksum at 280h/300h/200h on
// the earlier MECHACON and at 270h/2B0h/200h on the Dragon MECHACON of the
// SCPH-50000 and later consoles.
// References: ps2tek (CDVD I/O ports, N and S commands, read timing),
// ps2sdk cdvdman (AFL 2.0; register protocol and result sizes), PS2
// Developer wiki (MECHACON EEPROM layouts).
{$IFDEF PS2_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$POINTERMATH ON}

interface

uses
  System.SysUtils, System.Classes, System.Math, Core.Snapshots, Core.DVD.Image, PS2.Types, PS2.Scheduler;

type
  TPS2CDVDDrive = class
  private
    FScheduler: TPS2Scheduler;
    FImage: TDVDImage;
    FRegs: array[0..255] of Byte;
    FIStat, FStatus, FSticky, FDiskType, FError: Byte;
    // N command: parameters, the command running and when its next step is.
    FNParams: array[0..15] of Byte;
    FNParamCount: Integer;
    FNCmd: Byte;
    FNBusy: Boolean;
    FDue: Int64;
    // Reading: next sector, sectors left, block size, the buffer DMA takes
    // from.
    FSector: Int64;
    FLeft: Integer;
    FBlock: Integer;
    FDVD: Boolean;
    FSpinning: Boolean;
    FBuffer: array[0..4 * 2340 - 1] of Byte;
    FBufLen, FBufPos: Integer;
    // S command FIFOs.
    FSParams: array[0..15] of Byte;
    FSParamCount: Integer;
    FSCmd: Byte;
    FSResult: array[0..15] of Byte;
    FSResultCount, FSResultPos: Integer;
    // The clock: emulated time plus the offset the BIOS wrote (seconds).
    FClockOffset: Int64;
    // MECHACON EEPROM and configuration access.
    FNVM: array[0..1023] of Byte;
    FDragon: Boolean;
    FNVMChanged: Boolean;
    FConfigOpen: Boolean;
    FConfigWrite: Boolean;
    FConfigBlock, FConfigCount, FConfigPos: Integer;
    FMechacon: array[0..3] of Byte;
    // The disc key registers (20h-24h, 28h-2Ch, 30h-34h; 38h which parts
    // are valid) of the last ReadKey, and the disc's serial they encode.
    FKey: array[0..15] of Byte;
    FSerialLetters: AnsiString;
    FSerialNumber: Integer;
    // Diagnostics: reads per register.
    FReads: array[0..255] of Integer;
    FLastRead: array[0..255] of Byte;
    procedure Interrupt(Bits: Byte);
    procedure StartN;
    procedure FinishN;
    procedure ReadNext;
    procedure SCommand;
    procedure Result(const Bytes: array of Byte);
    function BlockTime: Int64;
    function SeekTime(Target: Int64): Int64;
    procedure ClockBytes(out B: array of Byte);
    procedure ReadKey(Sector: Cardinal);
    function ClockSeconds: Int64;
    procedure WriteClock;
    function ReadRegister(Reg: Cardinal): Byte;
    // EEPROM offset of row Row of configuration area Block (-1 outside it).
    function ConfigRow(Block, Row: Integer): Integer;
    function ModelNameAt: Integer;
  public
    OnInterrupt: TProc;
    OnData: TProc;
    Log: TStrings;
    constructor Create(Scheduler: TPS2Scheduler; Image: TDVDImage);
    procedure Reset;
    // The MECHACON version (4 bytes) and EEPROM (1 KiB) of the console, and
    // whether its MECHACON is the Dragon (EEPROM layout).
    procedure SetMechacon(const Version: TBytes);
    procedure SetNVM(const Data: TBytes; Dragon: Boolean);
    function NVM: TBytes;
    // The BIOS wrote the EEPROM (configuration or NVM words) since the last
    // ClearNVMChanged.
    property NVMChanged: Boolean read FNVMChanged;
    procedure ClearNVMChanged;
    // Seconds the BIOS moved the clock from the emulated console clock.
    property ClockOffset: Int64 read FClockOffset write FClockOffset;
    function Read(Reg: Cardinal): Byte;
    procedure Write(Reg: Cardinal; Value: Byte);
    // DMA channel 3 takes up to MaxBytes of read data; returns the bytes.
    function TakeData(Dest: PByte; MaxBytes: Integer): Integer;
    // Scheduler event CDVD.
    procedure Event;
    procedure SerializeState(State: TStateArchive);
    // Diagnostics.
    function Describe: string;
  end;

implementation

const
  // Drive status (1F40200Ah).
  StatShellOpen = $01;
  StatSpin = $02;
  StatRead = $04;
  StatPause = $08;
  StatSeek = $10;
  // Disc types (1F40200Fh).
  TypeNone = $00;
  TypePS2CD = $12;
  TypePS2DVD = $14;
  // Read speeds: CD 24x (153600 bytes/s at 1x), DVD 4x (1382400 bytes/s).
  CDSpeed = 24 * 153600;
  DVDSpeed = 4 * 1382400;

constructor TPS2CDVDDrive.Create(Scheduler: TPS2Scheduler; Image: TDVDImage);
begin
  inherited Create;
  FScheduler := Scheduler;
  FImage := Image;
  FMechacon[0] := $03;
  FMechacon[1] := $06;
  FMechacon[2] := $02;
  FMechacon[3] := $00;
  Reset;
end;

procedure TPS2CDVDDrive.SetMechacon(const Version: TBytes);
begin
  if Length(Version) >= 4 then
    Move(Version[0], FMechacon[0], 4);
end;

procedure TPS2CDVDDrive.SetNVM(const Data: TBytes; Dragon: Boolean);
begin
  FillChar(FNVM, SizeOf(FNVM), 0);
  if Length(Data) > 0 then
    Move(Data[0], FNVM[0], Min(Length(Data), SizeOf(FNVM)));
  FDragon := Dragon;
  FNVMChanged := False;
end;

function TPS2CDVDDrive.NVM: TBytes;
begin
  SetLength(Result, SizeOf(FNVM));
  Move(FNVM[0], Result[0], SizeOf(FNVM));
end;

procedure TPS2CDVDDrive.ClearNVMChanged;
begin
  FNVMChanged := False;
end;

// Configuration areas: 0 EEGS (4 rows), 1 OSD (7 rows), 2 DVD player (7
// rows).
function TPS2CDVDDrive.ConfigRow(Block, Row: Integer): Integer;
const
  Rows: array[0..2] of Integer = (4, 7, 7);
  Old: array[0..2] of Integer = ($280, $300, $200);
  New: array[0..2] of Integer = ($270, $2B0, $200);
begin
  if (Block < 0) or (Block > 2) or (Row < 0) or (Row >= Rows[Block]) then
    Exit(-1);
  if FDragon then
    Result := New[Block] + Row * 16
  else
    Result := Old[Block] + Row * 16;
end;

function TPS2CDVDDrive.ModelNameAt: Integer;
begin
  if FDragon then
    Result := $1B0
  else
    Result := $1A0;
end;

procedure TPS2CDVDDrive.Reset;
begin
  FillChar(FRegs, SizeOf(FRegs), 0);
  FIStat := 0;
  FError := 0;
  FNParamCount := 0;
  FNCmd := 0;
  FNBusy := False;
  FDue := PS2Never;
  FLeft := 0;
  FBufLen := 0;
  FBufPos := 0;
  FSParamCount := 0;
  FSResultCount := 0;
  FSResultPos := 0;
  FConfigOpen := False;
  FSpinning := False;
  if FImage = nil then
  begin
    FDiskType := TypeNone;
    FStatus := 0;
  end
  else
  begin
    if FImage.IsDVD then
      FDiskType := TypePS2DVD
    else
      FDiskType := TypePS2CD;
    FStatus := StatPause;
  end;
  FSticky := FStatus;
  FillChar(FKey, SizeOf(FKey), 0);
  // The serial from the boot file name (cdrom0:\SLPS_250.88;1: SLPS, 25088).
  FSerialLetters := '';
  FSerialNumber := 0;
  var Info: TPS2DiscInfo;
  if (FImage <> nil) and ReadPS2DiscInfo(FImage, Info) and (Length(Info.Serial) >= 5) then
  begin
    FSerialLetters := AnsiString(Info.Serial.Substring(0, 4));
    FSerialNumber := StrToIntDef(Info.Serial.Substring(5), 0);
  end;
  FScheduler.Cancel(TPS2Event.CDVD);
end;

// The disc key the MECHACON reads from a sector. The key of sector 75 (4Bh)
// carries the disc's serial as CDVDMAN decodes it (ps2sdk cdvdman,
// sceCdDeobfuscateUsingUniqueKey): bits 0-39 of key bytes 0-4 hold, from the
// top, the four letters (7 bits each, first letter highest) between number
// bits 0-4 (bits 35-39) and number bits 10-16 (bits 0-6); number bits 5-9 are
// bits 3-7 of key byte 14. Its valid parts (register 38h) are the first and
// the third; other sectors give the first part.
procedure TPS2CDVDDrive.ReadKey(Sector: Cardinal);
begin
  FillChar(FKey, SizeOf(FKey), 0);
  if FImage = nil then
    Exit;
  var Letters: array[0..3] of UInt64;
  for var K := 0 to 3 do
    if K < Length(FSerialLetters) then
      Letters[K] := Ord(FSerialLetters[K + 1]) and $7F
    else
      Letters[K] := 0;
  var N := UInt64(FSerialNumber and $1FFFF);
  var V := ((N shr 10) and $7F) or (Letters[3] shl 7) or (Letters[2] shl 14) or (Letters[1] shl 21) or
    (Letters[0] shl 28) or ((N and $1F) shl 35);
  for var K := 0 to 4 do
    FKey[K] := Byte(V shr (K * 8));
  if Sector = 75 then
  begin
    FKey[14] := Byte(((N shr 5) and $1F) shl 3);
    FKey[15] := 5;
  end
  else
    FKey[15] := 1;
end;
procedure TPS2CDVDDrive.Interrupt(Bits: Byte);
begin
  FIStat := FIStat or Bits;
  if Assigned(OnInterrupt) then
    OnInterrupt();
end;

// IOP cycles a block takes at the disc's speed, in EE cycles.
function TPS2CDVDDrive.BlockTime: Int64;
begin
  if FDVD then
    Result := Int64(PS2IOPClock) * FBlock div DVDSpeed * 8
  else
    Result := Int64(PS2IOPClock) * FBlock div CDSpeed * 8;
end;

// Spin-up (333 ms when stopped), a contiguous read, a fast seek (30 ms
// within 14764 DVD or 4371 CD sectors) or a full seek (100 ms).
function TPS2CDVDDrive.SeekTime(Target: Int64): Int64;
begin
  if not FSpinning then
    Exit(PS2EEClock div 3);
  var Delta := Abs(Target - FSector);
  var Near: Int64 := 8;
  var Fast: Int64 := 4371;
  if FDVD then
  begin
    Near := 16;
    Fast := 14764;
  end;
  if Delta <= Near then
    Result := Max(Delta, 1) * BlockTime
  else if Delta < Fast then
    Result := PS2EEClock div 1000 * 30
  else
    Result := PS2EEClock div 10;
end;

procedure TPS2CDVDDrive.StartN;
begin
  FNBusy := True;
  FError := 0;
  var P := PCardinal(@FNParams[0]);
  if (Log <> nil) and (Log.Count < 100000) then
    Log.Add(Format('cdvd %d ncmd %.2x params %d: %.8x %.8x %.8x', [FScheduler.Now div 4915200, FNCmd, FNParamCount, P[0],
      P[1], P[2]]));
  case FNCmd of
    $05, $06, $08:
      begin
        // Seek, ReadCd (block size from byte 10: 2328, 2340 or 2048),
        // ReadDvd (2064-byte blocks).
        var Target := Int64(P[0]);
        FDVD := (FNCmd = $08) or ((FImage <> nil) and FImage.IsDVD);
        FBlock := 2048;
        if FNCmd = $08 then
          FBlock := 2064
        else if FNParams[10] = 1 then
          FBlock := 2328
        else if FNParams[10] = 2 then
          FBlock := 2340;
        FLeft := 0;
        if FNCmd <> $05 then
          FLeft := Integer(P[1]);
        FBufLen := 0;
        FBufPos := 0;
        FStatus := StatSeek or StatSpin;
        FDue := FScheduler.Now + SeekTime(Target);
        FSector := Target;
        FSpinning := True;
        if FImage = nil then
        begin
          FError := $01;
          FDue := FScheduler.Now + 2000;
        end;
      end;
    $02, $04:
      begin
        // Standby, pause: spinning, paused.
        FDue := FScheduler.Now + Max(Int64(10000), Ord(not FSpinning) * (PS2EEClock div 3));
        FSpinning := True;
      end;
    $03:
      begin
        // Stop: about 166 ms to spin down.
        FDue := FScheduler.Now + PS2EEClock div 6;
        FSpinning := False;
        FSector := 0;
      end;
    $0C:
      begin
        // ReadKey (mode, two flags, sector).
        ReadKey(PCardinal(@FNParams[3])^);
        FDue := FScheduler.Now + 10000;
      end;
  else
    // NOP, NOPsync, GetToc and the rest: done shortly.
    FDue := FScheduler.Now + 10000;
  end;
  FScheduler.Schedule(TPS2Event.CDVD, FDue);
end;

procedure TPS2CDVDDrive.FinishN;
begin
  FNBusy := False;
  FDue := PS2Never;
  FScheduler.Cancel(TPS2Event.CDVD);
  if FImage <> nil then
  begin
    if FSpinning then
      FStatus := StatPause or StatSpin
    else
      FStatus := 0;
  end;
  FSticky := FSticky or FStatus;
  // Reads raise "data ready" (bit 0) and "command complete" (bit 1).
  if FNCmd in [$06, $07, $08] then
    Interrupt($03)
  else
    Interrupt($02);
end;

// The next sector into the buffer (when it has room), or the end of the
// read once DMA has taken everything.
procedure TPS2CDVDDrive.ReadNext;
begin
  if FLeft = 0 then
  begin
    if FBufPos >= FBufLen then
      FinishN
    else
      FDue := PS2Never;
    Exit;
  end;
  if FBufLen + FBlock > Length(FBuffer) then
  begin
    // Full: wait for DMA.
    FDue := PS2Never;
    Exit;
  end;
  FStatus := StatRead or StatSpin;
  var Dest: PByte := @FBuffer[FBufLen];
  FillChar(Dest^, FBlock, 0);
  if (FImage <> nil) and (FSector < FImage.SectorCount) then
  begin
    if FBlock = 2064 then
    begin
      // DVD block: volume number + 20h, the sector number from the volume
      // start + 30000h (big-endian), eight zero bytes, the data, four zeros.
      var Layer := 0;
      var Rel := FSector;
      if (FImage.LayerBreak > 0) and (FSector >= FImage.LayerBreak) then
      begin
        Layer := 1;
        Rel := FSector - FImage.LayerBreak;
      end;
      var N := Rel + $30000;
      Dest[0] := $20 + Layer;
      Dest[1] := Byte(N shr 16);
      Dest[2] := Byte(N shr 8);
      Dest[3] := Byte(N);
      FImage.ReadSectors(FSector, 1, Dest + 12);
    end
    else
      FImage.ReadSectors(FSector, 1, Dest);
  end
  else
    FError := $01;
  Inc(FBufLen, FBlock);
  Inc(FSector);
  Dec(FLeft);
  FDue := FScheduler.Now + BlockTime;
  if Assigned(OnData) then
    OnData();
end;

procedure TPS2CDVDDrive.Event;
begin
  if FScheduler.Now < FDue then
  begin
    FScheduler.Schedule(TPS2Event.CDVD, FDue);
    Exit;
  end;
  if FNBusy and (FNCmd in [$06, $07, $08]) then
    ReadNext
  else if FNBusy then
    FinishN;
  if FDue <> PS2Never then
    FScheduler.Schedule(TPS2Event.CDVD, FDue);
end;

function TPS2CDVDDrive.TakeData(Dest: PByte; MaxBytes: Integer): Integer;
begin
  Result := Min(MaxBytes, FBufLen - FBufPos);
  if Result <= 0 then
    Exit(0);
  Move(FBuffer[FBufPos], Dest^, Result);
  Inc(FBufPos, Result);
  if FBufPos >= FBufLen then
  begin
    FBufLen := 0;
    FBufPos := 0;
    // Room again: the drive goes on (or finishes) now.
    if FNBusy and (FDue = PS2Never) then
    begin
      FDue := FScheduler.Now + 64;
      FScheduler.Schedule(TPS2Event.CDVD, FDue);
    end;
  end;
end;

procedure TPS2CDVDDrive.Result(const Bytes: array of Byte);
begin
  FSResultCount := Min(Length(Bytes), Length(FSResult));
  for var K := 0 to FSResultCount - 1 do
    FSResult[K] := Bytes[K];
  FSResultPos := 0;
end;

// Seconds since 2004-01-01 00:00:00: the console clock (from 12:00:00 that
// day, as PS2ClockAt) moved by what the BIOS wrote.
function TPS2CDVDDrive.ClockSeconds: Int64;
begin
  Result := Int64(12 * 3600) + FScheduler.Now div PS2EEClock + FClockOffset;
end;

procedure TPS2CDVDDrive.ClockBytes(out B: array of Byte);
begin
  var Secs := ClockSeconds;
  var Days := Secs div 86400;
  var Rem := Secs mod 86400;
  if Rem < 0 then
  begin
    Inc(Rem, 86400);
    Dec(Days);
  end;
  var Y, M, D: Word;
  DecodeDate(Trunc(EncodeDate(2004, 1, 1)) + Days, Y, M, D);
  B[0] := 0;
  B[1] := PS2BCD(Rem mod 60);
  B[2] := PS2BCD((Rem div 60) mod 60);
  B[3] := PS2BCD(Rem div 3600);
  B[4] := 0;
  B[5] := PS2BCD(D);
  B[6] := PS2BCD(M);
  B[7] := PS2BCD(Y mod 100);
end;

// WriteRTC (second, minute, hour, day, month, year in BCD after an ignored
// byte each where ReadRTC returns zero): the clock goes on from there.
procedure TPS2CDVDDrive.WriteClock;

  function FromBCD(B: Byte): Integer;
  begin
    Result := (B shr 4) * 10 + (B and $F);
  end;

begin
  var Date: TDateTime;
  if not TryEncodeDate(2000 + FromBCD(FSParams[7]), FromBCD(FSParams[6]), FromBCD(FSParams[5]), Date) then
    Exit;
  var Secs := Int64(Trunc(Date) - Trunc(EncodeDate(2004, 1, 1))) * 86400 + FromBCD(FSParams[3]) * 3600 +
    FromBCD(FSParams[2]) * 60 + FromBCD(FSParams[1]);
  FClockOffset := FClockOffset + Secs - ClockSeconds;
end;

procedure TPS2CDVDDrive.SCommand;
var
  Clock: array[0..7] of Byte;
begin
  var P := FSParams;
  if (Log <> nil) and (Log.Count < 100000) then
    Log.Add(Format('cdvd %d scmd %.2x params %d: %.2x %.2x %.2x %.2x', [FScheduler.Now div 4915200, FSCmd, FSParamCount, P[0], P[1],
      P[2], P[3]]));
  case FSCmd of
    $02: Result([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
    $03:
      case P[0] of
        // MECHACON version.
        $00: Result([FMechacon[0], FMechacon[1], FMechacon[2], FMechacon[3]]);
        $30: Result([0, 0]);
      else
        begin
          if (Log <> nil) and (Log.Count < 100000) then
            Log.Add(Format('cdvd scmd 03:%.2x unknown', [P[0]]));
          Result([0]);
        end;
      end;
    $05:
      begin
        FSticky := FStatus;
        Result([0]);
      end;
    $06, $0C, $14, $16, $19, $1B, $1C, $24, $25, $28, $29, $2E, $31, $33, $34, $3B, $3E, $1F, $13, $18:
      Result([0]);
    $0B:
      begin
        // WriteNVM: word address and the word (big-endian).
        var A := ((Integer(P[0]) shl 8) or P[1]) * 2;
        if A + 1 < Length(FNVM) then
        begin
          FNVM[A] := P[3];
          FNVM[A + 1] := P[2];
          FNVMChanged := True;
        end;
        Result([0]);
      end;
    $08:
      begin
        ClockBytes(Clock);
        Result(Clock);
      end;
    $09:
      begin
        WriteClock;
        Result([0]);
      end;
    $0A:
      begin
        // ReadNVM: word address (big-endian), the word (status, high, low).
        var A := ((Integer(P[0]) shl 8) or P[1]) * 2;
        if A + 1 < Length(FNVM) then
          Result([0, FNVM[A + 1], FNVM[A]])
        else
          Result([0, 0, 0]);
      end;
    $12:
      begin
        // The i.Link ID.
        var A := $1C0;
        if FDragon then
          A := $1E0;
        Result([0, FNVM[A], FNVM[A + 1], FNVM[A + 2], FNVM[A + 3], FNVM[A + 4], FNVM[A + 5], FNVM[A + 6], FNVM[A + 7]]);
      end;
    $15: Result([5]);
    $17:
      begin
        // Model name (two halves) from the EEPROM, a default without one.
        var Name: array[0..15] of Byte;
        Move(FNVM[ModelNameAt], Name[0], 16);
        if Name[0] = 0 then
        begin
          FillChar(Name, SizeOf(Name), 0);
          var Default := AnsiString('SCPH-50000');
          Move(Default[1], Name[0], Length(Default));
        end;
        var Half := P[0] and 8;
        Result([0, Name[Half], Name[Half + 1], Name[Half + 2], Name[Half + 3], Name[Half + 4], Name[Half + 5],
          Name[Half + 6], Name[Half + 7]]);
      end;
    $1A: Result([1]);
    $1D: Result([0, 0, 0, 0, 0]);
    // Remote control read (RMMAN2): bit 7 of the status, no remote data.
    $1E: Result([$80, 0, 0, 0, 0]);
    $22: Result([0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
    $26: Result([0, 0, 0]);
    $27: Result([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
    $2C, $2D, $32, $35: Result([0, 0]);
    $36: Result([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
    $40:
      begin
        // OpenConfig(mode, block, blocks).
        FConfigOpen := True;
        FConfigWrite := P[0] <> 0;
        FConfigBlock := P[1] and 3;
        FConfigCount := Min(Integer(P[2]), $44);
        FConfigPos := 0;
        Result([0]);
      end;
    $41:
      begin
        // ReadConfig: the next row (15 bytes and the checksum stored with
        // them).
        var A := -1;
        if FConfigOpen and not FConfigWrite and (FConfigPos < FConfigCount) then
          A := ConfigRow(FConfigBlock, FConfigPos);
        Inc(FConfigPos);
        if A >= 0 then
          Result(Slice(PByteArray(@FNVM[A])^, 16))
        else
          Result([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
      end;
    $42:
      begin
        // WriteConfig: the next row (CDVDMAN sends the checksum).
        var A := -1;
        if FConfigOpen and FConfigWrite and (FConfigPos < FConfigCount) then
          A := ConfigRow(FConfigBlock, FConfigPos);
        Inc(FConfigPos);
        if A >= 0 then
        begin
          Move(P[0], FNVM[A], 16);
          FNVMChanged := True;
        end;
        Result([0]);
      end;
    $43:
      begin
        FConfigOpen := False;
        Result([0]);
      end;
  else
    begin
      if (Log <> nil) and (Log.Count < 100000) then
        Log.Add(Format('cdvd scmd %.2x unknown', [FSCmd]));
      Result([0]);
    end;
  end;
  FSParamCount := 0;
end;

function TPS2CDVDDrive.Read(Reg: Cardinal): Byte;
begin
  Result := ReadRegister(Reg);
  if (Log <> nil) and (Log.Count < 100000) and (Reg <> $17) and (Reg <> $18) then
  begin
    // The first reads of each register, then changed values.
    Inc(FReads[Reg and $FF]);
    if (FReads[Reg and $FF] <= 3) or (FLastRead[Reg and $FF] <> Result) then
      Log.Add(Format('cdvd %d r %.2x = %.2x', [FScheduler.Now div 4915200, Reg, Result]));
    FLastRead[Reg and $FF] := Result;
  end;
end;

function TPS2CDVDDrive.ReadRegister(Reg: Cardinal): Byte;
begin
  case Reg of
    $04: Result := FNCmd;
    $05:
      begin
        // Ready (bit 6) unless busy (bit 7); bit 0 error.
        Result := $40;
        if FNBusy then
          Result := $80;
        if FError <> 0 then
          Result := Result or 1;
      end;
    $06: Result := FError;
    $08: Result := FIStat;
    $0A:
      begin
        Result := FStatus;
        if FImage = nil then
          Result := Result or StatShellOpen;
      end;
    $0B: Result := FSticky;
    $0F: Result := FDiskType;
    $20..$24: Result := FKey[Reg - $20];
    $28..$2C: Result := FKey[Reg - $28 + 5];
    $30..$34: Result := FKey[Reg - $30 + 10];
    $38: Result := FKey[15];
    // The value the key bytes are XORed with.
    $39: Result := 0;
    $16: Result := FSCmd;
    $17:
      begin
        // Bit 6: no result data; bit 7: busy (never, the drive answers at
        // once).
        Result := 0;
        if FSResultPos >= FSResultCount then
          Result := $40;
      end;
    $18:
      if FSResultPos < FSResultCount then
      begin
        Result := FSResult[FSResultPos];
        Inc(FSResultPos);
      end
      else
        Result := 0;
  else
    Result := FRegs[Reg and $FF];
  end;
end;

procedure TPS2CDVDDrive.Write(Reg: Cardinal; Value: Byte);
begin
  case Reg of
    $04:
      begin
        FNCmd := Value;
        StartN;
        FNParamCount := 0;
      end;
    $05:
      if FNParamCount < Length(FNParams) then
      begin
        FNParams[FNParamCount] := Value;
        Inc(FNParamCount);
      end;
    $07:
      begin
        // BREAK: the running N command stops.
        if FNBusy then
        begin
          FLeft := 0;
          FBufLen := 0;
          FBufPos := 0;
          FinishN;
        end;
      end;
    $08: FIStat := FIStat and not Value;
    $16:
      begin
        FSCmd := Value;
        SCommand;
      end;
    $17:
      if FSParamCount < Length(FSParams) then
      begin
        FSParams[FSParamCount] := Value;
        Inc(FSParamCount);
      end;
  else
    FRegs[Reg and $FF] := Value;
  end;
end;

function TPS2CDVDDrive.Describe: string;
begin
  Result := Format('ncmd %.2x busy %d left %d sector %d buf %d/%d due %d now %d istat %x status %x', [FNCmd, Ord(FNBusy),
    FLeft, FSector, FBufPos, FBufLen, FDue, FScheduler.Now, FIStat, FStatus]);
end;

procedure TPS2CDVDDrive.SerializeState(State: TStateArchive);
begin
  State.Field(FRegs, SizeOf(FRegs));
  State.Field(FIStat, SizeOf(FIStat));
  State.Field(FStatus, SizeOf(FStatus));
  State.Field(FSticky, SizeOf(FSticky));
  State.Field(FDiskType, SizeOf(FDiskType));
  State.Field(FError, SizeOf(FError));
  State.Field(FNParams, SizeOf(FNParams));
  State.Field(FNParamCount, SizeOf(FNParamCount));
  State.Field(FNCmd, SizeOf(FNCmd));
  State.Field(FNBusy, SizeOf(FNBusy));
  State.Field(FDue, SizeOf(FDue));
  State.Field(FSector, SizeOf(FSector));
  State.Field(FLeft, SizeOf(FLeft));
  State.Field(FBlock, SizeOf(FBlock));
  State.Field(FDVD, SizeOf(FDVD));
  State.Field(FSpinning, SizeOf(FSpinning));
  State.Field(FBuffer, SizeOf(FBuffer));
  State.Field(FBufLen, SizeOf(FBufLen));
  State.Field(FBufPos, SizeOf(FBufPos));
  State.Field(FSParams, SizeOf(FSParams));
  State.Field(FSParamCount, SizeOf(FSParamCount));
  State.Field(FSCmd, SizeOf(FSCmd));
  State.Field(FSResult, SizeOf(FSResult));
  State.Field(FSResultCount, SizeOf(FSResultCount));
  State.Field(FSResultPos, SizeOf(FSResultPos));
  State.Field(FClockOffset, SizeOf(FClockOffset));
  State.Field(FNVM, SizeOf(FNVM));
  State.Field(FConfigOpen, SizeOf(FConfigOpen));
  State.Field(FConfigWrite, SizeOf(FConfigWrite));
  State.Field(FConfigBlock, SizeOf(FConfigBlock));
  State.Field(FConfigCount, SizeOf(FConfigCount));
  State.Field(FConfigPos, SizeOf(FConfigPos));
  State.Field(FDragon, SizeOf(FDragon));
  State.Field(FNVMChanged, SizeOf(FNVMChanged));
  State.Field(FMechacon, SizeOf(FMechacon));
  State.Field(FKey, SizeOf(FKey));
end;

end.
