unit PS2.CDVD.Drive;

// The CDVD drive and its MECHACON as the BIOS's CDVDMAN drives them
// (External BIOS boot), registers 1F402000h-1F4020FFh on the IOP.
// N commands (seeks and reads) run in the background: the drive spins up,
// seeks and reads sectors at the disc's speed into a small buffer that DMA
// channel 3 empties, then raises its interrupt (I_STAT bits 0 and 1 of the
// drive, IOP I_STAT bit 2). S commands (MECHACON services) answer at once
// through the parameter and result FIFOs, with the exact result lengths
// CDVDMAN expects. The real-time clock follows the emulated console clock
// plus what the BIOS writes; NVM words and configuration blocks live in the
// drive's EEPROM (a companion .nvm file of the BIOS when present, blank
// otherwise).
// References: ps2tek (CDVD I/O ports, N and S commands, read timing),
// ps2sdk cdvdman (AFL 2.0; register protocol and result sizes).
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
    FConfigOpen: Boolean;
    FConfigWrite: Boolean;
    FConfigBlock, FConfigCount, FConfigPos: Integer;
    FConfig: array[0..3, 0..$43, 0..14] of Byte;
    FMechacon: array[0..3] of Byte;
    // Diagnostics: reads per register.
    FReads: array[0..255] of Integer;
    procedure Interrupt(Bits: Byte);
    procedure StartN;
    procedure FinishN;
    procedure ReadNext;
    procedure SCommand;
    procedure Result(const Bytes: array of Byte);
    function BlockTime: Int64;
    function SeekTime(Target: Int64): Int64;
    procedure ClockBytes(out B: array of Byte);
    function ReadRegister(Reg: Cardinal): Byte;
  public
    OnInterrupt: TProc;
    OnData: TProc;
    Log: TStrings;
    constructor Create(Scheduler: TPS2Scheduler; Image: TDVDImage);
    procedure Reset;
    // The MECHACON version (4 bytes) and EEPROM (1 KiB) of the console.
    procedure SetMechacon(const Version: TBytes);
    procedure SetNVM(const Data: TBytes);
    function Read(Reg: Cardinal): Byte;
    procedure Write(Reg: Cardinal; Value: Byte);
    // DMA channel 3 takes up to MaxBytes of read data; returns the bytes.
    function TakeData(Dest: PByte; MaxBytes: Integer): Integer;
    // Scheduler event CDVD.
    procedure Event;
    procedure SerializeState(State: TStateArchive);
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

procedure TPS2CDVDDrive.SetNVM(const Data: TBytes);
begin
  FillChar(FNVM, SizeOf(FNVM), 0);
  if Length(Data) > 0 then
    Move(Data[0], FNVM[0], Min(Length(Data), SizeOf(FNVM)));
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
  FScheduler.Cancel(TPS2Event.CDVD);
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
    Log.Add(Format('cdvd ncmd %.2x params %d: %.8x %.8x %.8x', [FNCmd, FNParamCount, P[0], P[1], P[2]]));
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

procedure TPS2CDVDDrive.ClockBytes(out B: array of Byte);
begin
  var Cycles := FScheduler.Now;
  var T := PS2ClockAt(Cycles + FClockOffset * PS2EEClock);
  B[0] := 0;
  B[1] := PS2BCD(T.Second);
  B[2] := PS2BCD(T.Minute);
  B[3] := PS2BCD(T.Hour);
  B[4] := 0;
  B[5] := PS2BCD(T.Day);
  B[6] := PS2BCD(T.Month);
  B[7] := PS2BCD(T.Year mod 100);
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
    $06, $0C, $14, $16, $19, $1B, $1C, $24, $25, $28, $29, $2E, $31, $33, $34, $3B, $3E, $1F, $13, $18, $0B:
      Result([0]);
    $08:
      begin
        ClockBytes(Clock);
        Result(Clock);
      end;
    $09:
      begin
        // WriteRTC: the offset between the written time and the clock.
        ClockBytes(Clock);
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
    $12: Result([0, 0, 0, 0, 0, 0, 0, 0, 0]);
    $15: Result([5]);
    $17:
      begin
        // Model name (two halves).
        var Name := AnsiString('SCPH-50000') + #0#0#0#0#0#0;
        var Half := P[0] and 8;
        Result([0, Byte(Name[Half + 1]), Byte(Name[Half + 2]), Byte(Name[Half + 3]), Byte(Name[Half + 4]),
          Byte(Name[Half + 5]), Byte(Name[Half + 6]), Byte(Name[Half + 7]), Byte(Name[Half + 8])]);
      end;
    $1A: Result([1]);
    $1D: Result([0, 0, 0, 0, 0]);
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
        // ReadConfig: the next 15-byte block and its checksum.
        if FConfigOpen and not FConfigWrite and (FConfigPos < FConfigCount) then
        begin
          var B: array[0..15] of Byte;
          var Sum: Byte := 0;
          for var K := 0 to 14 do
          begin
            B[K] := FConfig[FConfigBlock, FConfigPos, K];
            Sum := Byte(Sum + B[K]);
          end;
          B[15] := Sum;
          Inc(FConfigPos);
          Result(B);
        end
        else
          Result([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
      end;
    $42:
      begin
        if FConfigOpen and FConfigWrite and (FConfigPos < FConfigCount) then
        begin
          for var K := 0 to 14 do
            FConfig[FConfigBlock, FConfigPos, K] := P[K];
          Inc(FConfigPos);
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
    Inc(FReads[Reg and $FF]);
    if FReads[Reg and $FF] <= 20 then
      Log.Add(Format('cdvd r %.2x = %.2x', [Reg, Result]));
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
  State.Field(FConfig, SizeOf(FConfig));
  State.Field(FMechacon, SizeOf(FMechacon));
end;

end.
