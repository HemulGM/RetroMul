unit PS1.CDROM;

interface

uses
  System.SysUtils, System.Classes, Core.Snapshots, Core.CD.Disc, PS1.Types,
  PS1.Scheduler, PS1.DMA, PS1.CDROM.Audio;

{$SCOPEDENUMS ON}

type
  // Interrupt bits 0..2 are the INT number; bit 7 marks an INT1 that
  // delivers the newest sector.
  TPS1CDResponse = record
    Interrupt: Byte;
    Count: Byte;
    Data: array[0..15] of Byte;
  end;

  TPS1CDDrive = (Idle, SeekRead, SeekPlay, SeekOnly, Reading, Playing);

  TPS1CDSector = array[0..2351] of Byte;

  // CD-ROM controller: the decoder's host interface (banked registers,
  // parameter/result/data FIFOs, interrupts), the drive microcontroller's
  // commands and response timing, and the drive (seek, sector reads, CD-DA
  // play, XA-ADPCM delivery). The disc is borrowed; the owner frees it.
  TPS1CDROM = class(TPS1DMADevice)
  private
    FScheduler: TPS1Scheduler;
    FIRQ: TPS1IRQRequest;
    FAudio: TPS1CDAudio;
    FDisc: TCDDisc;
    FRegion: Char;
    // Host interface.
    FIndex, FIntEnable, FIntFlag, FRequest: Byte;
    FParams: array[0..15] of Byte;
    FParamCount: Integer;
    FResult: array[0..15] of Byte;
    FResultCount, FResultRead: Integer;
    FData: TPS1CDSector;
    FDataCount, FDataRead: Integer;
    // Command waiting to be executed by the drive controller.
    FCommand: Byte;
    FCommandPending: Boolean;
    FCommandAt: Int64;
    // Responses waiting for delivery once no interrupt is raised.
    FQueue: array[0..3] of TPS1CDResponse;
    FQueueCount: Integer;
    FNextInterrupt: Int64;
    // A data or report INT1 is queued (only one is held at a time).
    FDataQueued: Boolean;
    // Delayed second response (Pause, Stop, Init, GetID, ...).
    FSecond: TPS1CDResponse;
    FSecondAt: Int64;
    FSecondAction: Byte;
    // Drive.
    FDrive: TPS1CDDrive;
    FDriveAt: Int64;
    // The motor runs, at full speed from FSpinUntil on.
    FSpinUntil: Int64;
    FMotorOn, FShellOpen, FShellWasOpen: Boolean;
    FMode, FFile, FChannel: Byte;
    FPosition, FTarget, FLastRead: Integer;
    FSeekPending: Boolean;
    FSeekCommand: Byte;
    FPlayTrack, FFastStep: Integer;
    // Sectors: the one belonging to the delivered INT1 and the newest one.
    FDelivered, FNewest: TPS1CDSector;
    FDeliveredValid, FNewestValid: Boolean;
    FHeader: array[0..7] of Byte;
    FHeaderValid: Boolean;
    FLastQ: array[0..11] of Byte;
    FXAActive: Boolean;
    // Stored subchannel Q is usable (most sampled sectors check out).
    FStoredQ: Boolean;
    FBuffer: TBytes;
    function Stat: Byte;
    function MotorReady: Boolean; inline;
    procedure SetInterrupt(Value: Byte);
    procedure Respond(const Response: TPS1CDResponse);
    procedure Enqueue(const Response: TPS1CDResponse);
    procedure QueueData(const Response: TPS1CDResponse);
    procedure DropData;
    procedure ScheduleNext;
    procedure Execute(Command: Byte);
    procedure LoadData;
    function SectorPeriod: Int64;
    function SeekTime(Target: Integer): Int64;
    procedure StartDrive(Next: TPS1CDDrive; Target: Integer);
    procedure StopDrive;
    procedure DriveEvent;
    procedure SecondEvent;
    procedure ReadSector;
    procedure PlaySector;
    function ReadDisc(LBA: Integer; var Sector: TPS1CDSector): Boolean;
    procedure PositionQ(LBA: Integer; var Q: array of Byte);
    function DiscType: Byte;
    function RegionLetter: Byte;
    function LeadOut: Integer;
  public
    constructor Create(Scheduler: TPS1Scheduler; const IRQ: TPS1IRQRequest);
    destructor Destroy; override;
    procedure Reset;
    // nil removes the disc. Region is the console letter used when the disc
    // does not name one (I, A or E).
    procedure SetDisc(Disc: TCDDisc);
    procedure OpenShell;
    procedure CloseShell(Disc: TCDDisc);
    function Read(Address: Cardinal): Byte;
    procedure Write(Address: Cardinal; Value: Byte);
    procedure Event(Time: Int64);
    function DMARequest(Channel: Integer): Boolean; override;
    procedure DMARead(Channel: Integer; Data: PCardinal; Count: Integer); override;
    procedure SerializeState(State: TStateArchive);
    property Audio: TPS1CDAudio read FAudio;
    property Region: Char read FRegion write FRegion;
    property Disc: TCDDisc read FDisc;
  end;

implementation

const
  // Timings in CPU cycles. Acknowledge and second-response delays follow
  // the psx-spx response timing tables and ps1-tests cdrom/timing.
  AckDelay = 25000;
  InitAckDelay = 75000;
  InterruptGap = 2500;
  GetIDDelay = $4A00;
  InitDelay = 476000;
  PauseDelay = 1000000;
  IdleDelay = 7600;
  StopDelaySingle = $D38ACA;
  StopDelayDouble = $18A6076;
  SpinUpDelay = PS1CPUClock div 2;
  ReadTOCDelay = PS1CPUClock;
  // Seeks into the lead-out succeed up to 74:10 or 1.5 minutes past its
  // start (ps1-tests cdrom/getloc reaches 74:00 but not 74:30).
  MinSeekLimit = ( 74 * 60 + 10) * 75 - 150;
  LeadOutSeek = 90 * 75;
  // Sectors skipped per sector time by Forward/Backward.
  FastStep = 10;
  // 2352 bytes at 4 bytes per 44100 Hz frame.
  SinglePeriod = Int64(PS1CPUClock) * 2352 div 4 div 44100;

  // Second-response side effects.
  ActionNone = 0;
  ActionStop = 1;
  ActionInit = 2;
  ActionSpinUp = 3;
  StatError = $01;
  StatMotor = $02;
  StatSeekError = $04;
  StatIdError = $08;
  StatShellOpen = $10;
  StatRead = $20;
  StatSeek = $40;
  StatPlay = $80;
  ModeCDDA = $01;
  ModeAutoPause = $02;
  ModeReport = $04;
  ModeFilter = $08;
  ModeSize = $20;
  ModeXA = $40;
  ModeDouble = $80;

function BCD(Value: Integer): Byte; inline;
begin
  Result := Byte((Value div 10) * 16 + Value mod 10);
end;

function ValidBCD(Value: Byte; Limit: Integer): Boolean; inline;
begin
  Result := ((Value and $F) <= 9) and ((Value shr 4) <= 9) and ((Value shr 4) * 10 + (Value and $F) < Limit);
end;

function FromBCD(Value: Byte): Integer; inline;
begin
  Result := (Value shr 4) * 10 + (Value and $F);
end;

function Response(Interrupt: Byte; const Bytes: array of Byte): TPS1CDResponse;
begin
  Result := Default(TPS1CDResponse);
  Result.Interrupt := Interrupt;
  Result.Count := Length(Bytes);
  for var I := 0 to High(Bytes) do
    Result.Data[I] := Bytes[I];
end;

function ISqrt(Value: Int64): Int64;
begin
  Result := 0;
  var Bit: Int64 := Int64(1) shl 62;
  while Bit > Value do
    Bit := Bit shr 2;
  while Bit <> 0 do
  begin
    if Value >= Result + Bit then
    begin
      Dec(Value, Result + Bit);
      Result := (Result shr 1) + Bit;
    end
    else
      Result := Result shr 1;
    Bit := Bit shr 2;
  end;
end;

constructor TPS1CDROM.Create(Scheduler: TPS1Scheduler; const IRQ: TPS1IRQRequest);
begin
  inherited Create;
  FScheduler := Scheduler;
  FIRQ := IRQ;
  FAudio := TPS1CDAudio.Create;
  FRegion := 'A';
  Reset;
end;

destructor TPS1CDROM.Destroy;
begin
  FAudio.Free;
  inherited;
end;

procedure TPS1CDROM.Reset;
begin
  FIndex := 0;
  FIntEnable := 0;
  FIntFlag := 0;
  FRequest := 0;
  FParamCount := 0;
  FillChar(FResult, SizeOf(FResult), 0);
  FResultCount := 0;
  FResultRead := 0;
  FDataCount := 0;
  FDataRead := 0;
  FCommandPending := False;
  FCommandAt := PS1Never;
  FQueueCount := 0;
  FNextInterrupt := 0;
  FDataQueued := False;
  FSecondAt := PS1Never;
  FSecondAction := ActionNone;
  FDrive := TPS1CDDrive.Idle;
  FDriveAt := PS1Never;
  FSpinUntil := 0;
  // The drive has already spun up and read the TOC when the CPU starts.
  FMotorOn := (FDisc <> nil) and not FShellOpen;
  FShellWasOpen := FShellOpen;
  FMode := 0;
  FFile := 0;
  FChannel := 0;
  FPosition := 0;
  FTarget := 0;
  FLastRead := 0;
  FSeekPending := False;
  FSeekCommand := 0;
  FPlayTrack := 1;
  FFastStep := 0;
  FDeliveredValid := False;
  FNewestValid := False;
  FHeaderValid := False;
  FillChar(FLastQ, SizeOf(FLastQ), 0);
  FXAActive := False;
  FAudio.Reset;
  FScheduler.Cancel(TPS1Event.CDROM);
end;

procedure TPS1CDROM.SetDisc(Disc: TCDDisc);
begin
  FDisc := Disc;
  FMotorOn := (FDisc <> nil) and not FShellOpen;
  FStoredQ := False;
  if FDisc = nil then
    Exit;

  if not FDisc.HasSubchannelQ then
    Exit;

  // A subchannel file whose Q checksums mostly fail is ignored.
  var Valid := 0;
  for var Sample := 0 to 15 do
    if FDisc.ReadSubQ(FDisc.LeadOut * Sample div 16, FBuffer) then
      Inc(Valid);
  FStoredQ := Valid >= 12;
end;

function TPS1CDROM.MotorReady: Boolean;
begin
  Result := FMotorOn and (FScheduler.Now >= FSpinUntil);
end;

function TPS1CDROM.LeadOut: Integer;
begin
  Result := 0;
  if FDisc <> nil then
    Result := FDisc.LeadOut;
end;

function TPS1CDROM.Stat: Byte;
begin
  Result := 0;
  if MotorReady then
    Result := Result or StatMotor;
  if FShellOpen or FShellWasOpen then
    Result := Result or StatShellOpen;
  case FDrive of
    TPS1CDDrive.SeekRead, TPS1CDDrive.SeekPlay, TPS1CDDrive.SeekOnly:
      Result := Result or StatSeek;
    TPS1CDDrive.Reading:
      Result := Result or StatRead;
    TPS1CDDrive.Playing:
      Result := Result or StatPlay;
  end;
end;

// The decoder raises its line whenever HINTSTS and HINTMSK share a bit.
procedure TPS1CDROM.SetInterrupt(Value: Byte);
begin
  var Before := (FIntFlag and FIntEnable and $1F) <> 0;
  FIntFlag := Value;
  if not Before and ((FIntFlag and FIntEnable and $1F) <> 0) then
    FIRQ(TPS1IRQ.CDROM);
end;

procedure TPS1CDROM.Respond(const Response: TPS1CDResponse);
begin
  Move(Response.Data, FResult, SizeOf(FResult));
  FResultCount := Response.Count;
  FResultRead := 0;
  SetInterrupt((FIntFlag and not Byte(7)) or (Response.Interrupt and 7));
end;

procedure TPS1CDROM.Enqueue(const Response: TPS1CDResponse);
begin
  if FQueueCount < Length(FQueue) then
  begin
    FQueue[FQueueCount] := Response;
    Inc(FQueueCount);
  end;
  ScheduleNext;
end;

// Only one data or report response waits at a time; a newer one replaces it.
procedure TPS1CDROM.QueueData(const Response: TPS1CDResponse);
begin
  if FDataQueued then
    for var I := 0 to FQueueCount - 1 do
      if (FQueue[I].Interrupt and 7) = 1 then
      begin
        FQueue[I] := Response;
        Exit;
      end;
  FDataQueued := True;
  Enqueue(Response);
end;

procedure TPS1CDROM.DropData;
begin
  if not FDataQueued then
    Exit;

  var Kept := 0;
  for var I := 0 to FQueueCount - 1 do
    if (FQueue[I].Interrupt and 7) <> 1 then
    begin
      FQueue[Kept] := FQueue[I];
      Inc(Kept);
    end;
  FQueueCount := Kept;
  FDataQueued := False;
  FNewestValid := False;
end;

procedure TPS1CDROM.ScheduleNext;
begin
  var Next := FDriveAt;
  if FSecondAt < Next then
    Next := FSecondAt;
  // Queued responses may go out while a command waits for its delay; a due
  // command goes first.
  if (FIntFlag and 7) = 0 then
  begin
    if FCommandPending then
    begin
      var Ready := FCommandAt;
      if FNextInterrupt > Ready then
        Ready := FNextInterrupt;
      if Ready < Next then
        Next := Ready;
    end;
    if (FQueueCount > 0) and (FNextInterrupt < Next) then
      Next := FNextInterrupt;
  end;
  if Next = PS1Never then
    FScheduler.Cancel(TPS1Event.CDROM)
  else
    FScheduler.Schedule(TPS1Event.CDROM, Next);
end;

function TPS1CDROM.Read(Address: Cardinal): Byte;
begin
  case Address and 3 of
    0:
      begin
        Result := FIndex;
        if FXAActive and (FAudio.Count > 0) then
          Result := Result or $04;
        if FParamCount = 0 then
          Result := Result or $08;
        if FParamCount < 16 then
          Result := Result or $10;
        if FResultRead < FResultCount then
          Result := Result or $20;
        if FDataRead < FDataCount then
          Result := Result or $40;
        if FCommandPending then
          Result := Result or $80;
      end;
    1:
      begin
        // Past the response the 16-byte buffer repeats, zero padded.
        Result := FResult[FResultRead and 15];
        Inc(FResultRead);
        if FResultRead >= 32 then
          Dec(FResultRead, 16);
      end;
    2:
      if FDataRead < FDataCount then
      begin
        Result := FData[FDataRead];
        Inc(FDataRead);
      end
      else if FDataCount = 0 then
        Result := 0
      else if FDataCount = 2048 then
        Result := FData[FDataCount - 8]
      else
        Result := FData[FDataCount - 4];
  else
    if (FIndex and 1) = 0 then
      Result := FIntEnable or $E0
    else
      Result := FIntFlag or $E0;
  end;
end;

procedure TPS1CDROM.Write(Address: Cardinal; Value: Byte);
begin
  case Address and 3 of
    0:
      FIndex := Value and 3;
    1:
      case FIndex of
        0:
          begin
            // A command written before the previous one ran replaces it.
            FCommand := Value;
            FCommandPending := True;
            FCommandAt := FScheduler.Now + AckDelay;
            if (Value = $0A) or (Value = $1E) then
              FCommandAt := FScheduler.Now + InitAckDelay;
            ScheduleNext;
          end;
        3:
          FAudio.WriteVolume(2, Value);
      end;
    2:
      case FIndex of
        0:
          if FParamCount < 16 then
          begin
            FParams[FParamCount] := Value;
            Inc(FParamCount);
          end;
        1:
          begin
            var Before := (FIntFlag and FIntEnable and $1F) <> 0;
            FIntEnable := Value and $1F;
            if not Before and ((FIntFlag and FIntEnable and $1F) <> 0) then
              FIRQ(TPS1IRQ.CDROM);
          end;
        2:
          FAudio.WriteVolume(0, Value);
        3:
          FAudio.WriteVolume(3, Value);
      end;
    3:
      case FIndex of
        0:
          begin
            FRequest := Value;
            if (Value and $80) = 0 then
            begin
              FDataCount := 0;
              FDataRead := 0;
            end
            else if FDataRead >= FDataCount then
              LoadData;
          end;
        1:
          begin
            // Unread response bytes stay readable after the acknowledge.
            FIntFlag := FIntFlag and not (Value and $1F);
            if (Value and $40) <> 0 then
              FParamCount := 0;
            if (Value and $80) <> 0 then
            begin
              FParamCount := 0;
              FDataCount := 0;
              FDataRead := 0;
              FIntFlag := 0;
            end;
            if (FIntFlag and 7) = 0 then
              FNextInterrupt := FScheduler.Now + InterruptGap;
            ScheduleNext;
          end;
        2:
          FAudio.WriteVolume(1, Value);
        3:
          FAudio.WriteControl(Value);
      end;
  end;
end;

// BFRD moves the sector of the delivered INT1 into the data FIFO: user data
// (800h bytes) or the sector after its sync pattern (924h bytes).
procedure TPS1CDROM.LoadData;
begin
  FDataRead := 0;
  FDataCount := 0;
  if not FDeliveredValid then
    Exit;

  if (FMode and ModeSize) <> 0 then
  begin
    FDataCount := 2340;
    Move(FDelivered[12], FData[0], 2340);
  end
  else
  begin
    FDataCount := 2048;
    var Offset := 24;
    if FDelivered[15] = 1 then
      Offset := 16;
    Move(FDelivered[Offset], FData[0], 2048);
  end;
end;

function TPS1CDROM.DMARequest(Channel: Integer): Boolean;
begin
  Result := FDataRead < FDataCount;
end;

procedure TPS1CDROM.DMARead(Channel: Integer; Data: PCardinal; Count: Integer);
begin
  for var I := 0 to Count - 1 do
  begin
    var Value: Cardinal := 0;
    for var B := 0 to 3 do
      Value := Value or (Cardinal(Read(2)) shl (B * 8));
    Data^ := Value;
    Inc(Data);
  end;
end;

procedure TPS1CDROM.Event(Time: Int64);
begin
  var Now := FScheduler.Now;
  var Progress := True;
  while Progress do
  begin
    Progress := False;
    if FDriveAt <= Now then
    begin
      DriveEvent;
      Progress := True;
    end;
    if FSecondAt <= Now then
    begin
      SecondEvent;
      Progress := True;
    end;
    if ((FIntFlag and 7) = 0) and (Now >= FNextInterrupt) then
    begin
      if FCommandPending and (Now >= FCommandAt) then
      begin
        FCommandPending := False;
        Execute(FCommand);
        FParamCount := 0;
        Progress := True;
      end
      else if FQueueCount > 0 then
      begin
        var Item := FQueue[0];
        Dec(FQueueCount);
        if FQueueCount > 0 then
          Move(FQueue[1], FQueue[0], FQueueCount * SizeOf(TPS1CDResponse));
        if (Item.Interrupt and 7) = 1 then
          FDataQueued := False;
        if (Item.Interrupt and $80) <> 0 then
        begin
          FDelivered := FNewest;
          FDeliveredValid := True;
          FNewestValid := False;
        end;
        Respond(Item);
        Progress := True;
      end;
    end;
  end;
  ScheduleNext;
end;

procedure TPS1CDROM.SecondEvent;
begin
  FSecondAt := PS1Never;
  case FSecondAction of
    ActionStop:
      FMotorOn := False;
    ActionInit:
      FMode := $20;
  end;
  FSecondAction := ActionNone;
  var Item := FSecond;
  // Responses without bytes report the status when they fire.
  if Item.Count = 0 then
  begin
    Item.Count := 1;
    Item.Data[0] := Stat;
  end;
  Enqueue(Item);
end;

function TPS1CDROM.SectorPeriod: Int64;
begin
  Result := SinglePeriod;
  if (FMode and ModeDouble) <> 0 then
    Result := SinglePeriod div 2;
end;

// No seek model is published; this one is fitted to ps1-tests cdrom/timing
// (a 110-sector seek costs about 12 ms) and keeps long seeks around 0.2 s:
// 8 ms plus 0.25 s * sqrt(distance / 330000 sectors).
function TPS1CDROM.SeekTime(Target: Integer): Int64;
begin
  var Distance := Abs(Int64(Target) - FPosition);
  Result := 271000 + 8467200 * ISqrt(Distance * 1000000 div 330000) div 1000;
end;

procedure TPS1CDROM.StartDrive(Next: TPS1CDDrive; Target: Integer);
begin
  var Now := FScheduler.Now;
  var Delay := SeekTime(Target);
  if not FMotorOn then
  begin
    FMotorOn := True;
    FSpinUntil := Now + SpinUpDelay;
  end;
  if FSpinUntil > Now then
    Inc(Delay, FSpinUntil - Now);
  DropData;
  FDrive := Next;
  FTarget := Target;
  FHeaderValid := False;
  FXAActive := False;
  FAudio.ResetXA;
  FDriveAt := Now + Delay;
  ScheduleNext;
end;

procedure TPS1CDROM.StopDrive;
begin
  if FDrive in [TPS1CDDrive.Reading, TPS1CDDrive.Playing] then
    FPosition := FLastRead;
  FDrive := TPS1CDDrive.Idle;
  FDriveAt := PS1Never;
  FXAActive := False;
  DropData;
end;

// Fills a raw sector. Data sectors from 2048-byte images become Mode 2
// Form 1 sectors (as PS1 discs are); False means an audio or gap sector.
// The pregap before a first data track and the lead-out after a last one
// read as empty Mode 2 sectors with headers (ps1-tests cdrom/getloc).
function TPS1CDROM.ReadDisc(LBA: Integer; var Sector: TPS1CDSector): Boolean;
begin
  FillChar(Sector, SizeOf(Sector), 0);
  Result := (FDisc <> nil) and FDisc.IsData(LBA);
  if (FDisc <> nil) and (((LBA < 0) and not FDisc.Track(1).Audio) or
    ((LBA >= FDisc.LeadOut) and not FDisc.Track(FDisc.TrackCount).Audio)) then
  begin
    for var I := 1 to 10 do
      Sector[I] := $FF;
    var Position := LBA + 150;
    if Position < 0 then
      Position := 0;
    Sector[12] := BCD(Position div 4500 mod 100);
    Sector[13] := BCD((Position div 75) mod 60);
    Sector[14] := BCD(Position mod 75);
    Sector[15] := 2;
    Exit(True);
  end;
  if not Result then
  begin
    if (FDisc <> nil) and (LBA >= 0) and (LBA < FDisc.LeadOut) then
    begin
      FDisc.ReadAudio(LBA, FBuffer);
      Move(FBuffer[0], Sector[0], 2352);
    end;
    Exit;
  end;

  var Index := FDisc.TrackAt(LBA);
  if FDisc.Track(Index + 1).DataOffset = 0 then
  begin
    for var I := 1 to 10 do
      Sector[I] := $FF;
    var Position := LBA + 150;
    Sector[12] := BCD(Position div 4500);
    Sector[13] := BCD((Position div 75) mod 60);
    Sector[14] := BCD(Position mod 75);
    Sector[15] := 2;
    Sector[18] := $08;
    Sector[22] := $08;
    FDisc.ReadData(LBA, FBuffer);
    Move(FBuffer[0], Sector[24], 2048);
  end
  else
  begin
    FDisc.ReadRawData(LBA, FBuffer);
    Move(FBuffer[0], Sector[0], 2352);
  end;
end;

procedure TPS1CDROM.PositionQ(LBA: Integer; var Q: array of Byte);
begin
  for var I := 0 to 11 do
    Q[I] := 0;
  if FDisc = nil then
    Exit;

  // Stored subchannel keeps the last Q with a valid checksum, as the drive
  // does (LibCrypt relies on this); otherwise Q is derived from the TOC.
  if FStoredQ and (LBA >= 0) and (LBA < FDisc.LeadOut) then
  begin
    if FDisc.ReadSubQ(LBA, FBuffer) then
      Move(FBuffer[0], FLastQ[0], 12);
    Move(FLastQ[0], Q[0], 12);
    Exit;
  end;

  var Track := FDisc.TrackAt(LBA);
  var Relative: Integer;
  if LBA >= FDisc.LeadOut then
  begin
    Q[0] := $01;
    Q[1] := $AA;
    Q[2] := $01;
    Relative := LBA - FDisc.LeadOut;
  end
  else
  begin
    if Track < 0 then
      Track := 0;
    var Item := FDisc.Track(Track + 1);
    Q[0] := $01;
    if not Item.Audio then
      Q[0] := $41;
    Q[1] := BCD(Track + 1);
    Q[2] := BCD(FDisc.IndexAt(LBA));
    if LBA < 0 then
      Q[2] := 0;
    Relative := Abs(LBA - Item.StartLBA);
  end;
  Q[3] := BCD(Relative div 4500 mod 100);
  Q[4] := BCD((Relative div 75) mod 60);
  Q[5] := BCD(Relative mod 75);
  var LAbsolute := LBA + 150;
  if LAbsolute < 0 then
    LAbsolute := 0;
  Q[7] := BCD(LAbsolute div 4500 mod 100);
  Q[8] := BCD((LAbsolute div 75) mod 60);
  Q[9] := BCD(LAbsolute mod 75);
end;

function TPS1CDROM.DiscType: Byte;
begin
  Result := 0;
  if (FDisc = nil) or (FDisc.TrackCount = 0) or FDisc.Track(1).Audio then
    Exit;

  var Sector: TPS1CDSector;
  if ReadDisc(FDisc.Track(1).StartLBA, Sector) and (Sector[15] = 2) then
    Result := $20;
end;

// Sector 4 holds the license text naming the disc's region.
function TPS1CDROM.RegionLetter: Byte;
begin
  Result := Ord(FRegion);
  var Sector: TPS1CDSector;
  if (FDisc = nil) or not ReadDisc(4, Sector) then
    Exit;

  var Offset := 24;
  if Sector[15] = 1 then
    Offset := 16;
  var License := '';
  for var I := 0 to 127 do
    if Sector[Offset + I] in [32..126] then
      License := License + Char(Sector[Offset + I]);
  if License.Contains('Entertainment Euro') then
    Result := Ord('E')
  else if License.Contains('Entertainment Amer') then
    Result := Ord('A')
  else if License.Contains('Entertainment Inc') then
    Result := Ord('I');
end;

procedure TPS1CDROM.DriveEvent;
begin
  case FDrive of
    TPS1CDDrive.SeekRead, TPS1CDDrive.SeekPlay, TPS1CDDrive.SeekOnly:
      begin
        var Kind := FDrive;
        var Limit := LeadOut + LeadOutSeek;
        if Limit < MinSeekLimit then
          Limit := MinSeekLimit;
        if (FTarget < -150) or (FTarget >= Limit) then
        begin
          FDrive := TPS1CDDrive.Idle;
          FDriveAt := PS1Never;
          FMotorOn := False;
          Enqueue(Response(5, [Stat or StatSeekError, $04]));
          Exit;
        end;
        FPosition := FTarget;
        FLastRead := FTarget;
        case Kind of
          TPS1CDDrive.SeekRead:
            begin
              FDrive := TPS1CDDrive.Reading;
              Inc(FDriveAt, SectorPeriod);
            end;
          TPS1CDDrive.SeekPlay:
            begin
              FDrive := TPS1CDDrive.Playing;
              FPlayTrack := FDisc.TrackAt(FPosition) + 1;
              Inc(FDriveAt, SectorPeriod);
            end;
        else
          begin
            FDrive := TPS1CDDrive.Idle;
            FDriveAt := PS1Never;
            var Sector: TPS1CDSector;
            var IsData := ReadDisc(FTarget, Sector);
            // SeekL needs data sector headers to find its target.
            if (FSeekCommand = $15) and not IsData and (FTarget < LeadOut) then
            begin
              FMotorOn := False;
              Enqueue(Response(5, [Stat or StatSeekError, $04]));
              Exit;
            end;
            if IsData then
            begin
              Move(Sector[12], FHeader[0], 8);
              FHeaderValid := True;
            end;
            Enqueue(Response(2, [Stat]));
          end;
        end;
      end;
    TPS1CDDrive.Reading:
      begin
        Inc(FDriveAt, SectorPeriod);
        ReadSector;
      end;
    TPS1CDDrive.Playing:
      begin
        Inc(FDriveAt, SectorPeriod);
        PlaySector;
      end;
  else
    FDriveAt := PS1Never;
  end;
end;

procedure TPS1CDROM.ReadSector;
var
  Sector: TPS1CDSector;
  Q: array[0..11] of Byte;
begin
  var LBA := FPosition;
  if LBA >= LeadOut then
  begin
    StopDrive;
    Enqueue(Response(4, [Stat]));
    Exit;
  end;

  var IsData := ReadDisc(LBA, Sector);
  // Q advances with the head even when software is not polling GetlocP.
  PositionQ(LBA, Q);
  FLastRead := LBA;
  FPosition := LBA + 1;
  if not IsData then
  begin
    FHeaderValid := False;
    var Index := FDisc.TrackAt(LBA);
    var InGap := (Index >= 0) and (LBA < FDisc.Track(Index + 1).StartLBA);
    if (FMode and ModeCDDA) = 0 then
    begin
      if not InGap then
      begin
        StopDrive;
        Enqueue(Response(5, [Stat or StatError, $40]));
        Exit;
      end;
      // A gap before an audio track reads back as an empty data sector.
      FillChar(Sector, SizeOf(Sector), 0);
      Sector[15] := 2;
      Sector[18] := $08;
      Sector[22] := $08;
    end;
  end
  else
  begin
    Move(Sector[12], FHeader[0], 8);
    FHeaderValid := True;
  end;

  // psx-spx "Data/ADPCM Sector Filtering/Delivery".
  var Mode2 := IsData and (Sector[15] = 2);
  var Matches := (Sector[16] = FFile) and (Sector[17] = FChannel);
  var RealTimeAudio := Mode2 and ((Sector[18] and $44) = $44);
  var Filter := (FMode and ModeFilter) <> 0;
  if RealTimeAudio and ((FMode and ModeXA) <> 0) and (not Filter or Matches) then
  begin
    FAudio.DecodeXA(Sector);
    FXAActive := True;
    Exit;
  end;
  if Filter and RealTimeAudio then
    Exit;
  // A sector that has to wait for delivery is filtered by file/channel.
  if Filter and Mode2 and not Matches and (((FIntFlag and 7) <> 0) or (FQueueCount > 0)) then
    Exit;

  FNewest := Sector;
  FNewestValid := True;
  QueueData(Response($81, [Stat]));
end;

procedure TPS1CDROM.PlaySector;
var
  Sector: TPS1CDSector;
  Q: array[0..11] of Byte;
begin
  var LBA := FPosition;
  // Backward turns into Play at the start of track 1.
  if (FFastStep < 0) and (LBA < FDisc.Track(1).StartLBA) then
  begin
    FFastStep := 0;
    LBA := FDisc.Track(1).StartLBA;
    FPosition := LBA;
  end;
  if LBA >= LeadOut then
  begin
    StopDrive;
    if LBA >= LeadOut then
      FMotorOn := False;
    Enqueue(Response(4, [Stat]));
    Exit;
  end;

  var Track := FDisc.TrackAt(LBA) + 1;
  if ((FMode and ModeAutoPause) <> 0) and (Track > FPlayTrack) then
  begin
    // The head stays at the end of the finished track.
    StopDrive;
    FPosition := LBA;
    Enqueue(Response(4, [Stat]));
    Exit;
  end;

  FLastRead := LBA;
  if FFastStep <> 0 then
    FPosition := LBA + FFastStep
  else
  begin
    FPosition := LBA + 1;
    if not ReadDisc(LBA, Sector) then
      FAudio.PushCDDA(Sector)
    else
    begin
      FillChar(Sector, SizeOf(Sector), 0);
      FAudio.PushCDDA(Sector);
    end;
  end;

  PositionQ(LBA, Q);
  if (FMode and ModeReport) = 0 then
    Exit;
  var Frame := FromBCD(Q[9]);
  if not (Frame in [0, 10, 20, 30, 40, 50, 60, 70]) then
    Exit;

  var Peak := FAudio.Peak;
  if (Frame mod 20) = 0 then
    QueueData(Response(1, [Stat, Q[1], Q[2], Q[7], Q[8], Q[9], Byte(Peak), Byte(Peak shr 8)]))
  else
    QueueData(Response(1, [Stat, Q[1], Q[2], Q[3], Q[4] or $80, Q[5], Byte(Peak), Byte(Peak shr 8)]));
end;

procedure TPS1CDROM.Execute(Command: Byte);
var
  Q: array[0..11] of Byte;

  procedure Ack;
  begin
    Respond(Response(3, [Stat]));
  end;

  procedure Fail(Code: Byte);
  begin
    Respond(Response(5, [Stat or StatError, Code]));
  end;

  procedure Second(Interrupt: Byte; Delay: Int64; Action: Byte; const Bytes: array of Byte);
  begin
    FSecond := Response(Interrupt, Bytes);
    FSecondAt := FScheduler.Now + Delay;
    FSecondAction := Action;
  end;

  function Params(Count: Integer): Boolean;
  begin
    Result := FParamCount = Count;
    if not Result then
      Fail($20);
  end;

  function DiscReady: Boolean;
  begin
    Result := (FDisc <> nil) and not FShellOpen;
    if not Result then
      Fail($80);
  end;

  function Active: Boolean;
  begin
    Result := FDrive <> TPS1CDDrive.Idle;
  end;

begin
  case Command of
    $01:
      if Params(0) then
      begin
        Ack;
        // Nop reports a shell that was opened once, then forgets it.
        if not FShellOpen then
          FShellWasOpen := False;
      end;
    $02:
      if Params(3) and DiscReady then
      begin
        if not ValidBCD(FParams[0], 100) or not ValidBCD(FParams[1], 60) or not ValidBCD(FParams[2], 75) then
          Fail($10)
        else
        begin
          FTarget := (FromBCD(FParams[0]) * 60 + FromBCD(FParams[1])) * 75 + FromBCD(FParams[2]) - 150;
          FSeekPending := True;
          Ack;
        end;
      end;
    $03:
      if (FParamCount <= 1) and DiscReady then
      begin
        var Track := 0;
        if (FParamCount = 1) and ValidBCD(FParams[0], 100) then
          Track := FromBCD(FParams[0]);
        Ack;
        FFastStep := 0;
        if Track > FDisc.TrackCount then
          Track := FDisc.TrackAt(FPosition) + 1;
        if Track >= 1 then
          StartDrive(TPS1CDDrive.SeekPlay, FDisc.Track(Track).StartLBA)
        else if FSeekPending then
          StartDrive(TPS1CDDrive.SeekPlay, FTarget)
        else if FDrive <> TPS1CDDrive.Playing then
          StartDrive(TPS1CDDrive.SeekPlay, FPosition);
        FSeekPending := False;
      end
      else if FParamCount > 1 then
        Fail($20);
    $04, $05:
      if Params(0) and DiscReady then
      begin
        if FDrive <> TPS1CDDrive.Playing then
          Fail($80)
        else
        begin
          Ack;
          FFastStep := FastStep;
          if Command = $05 then
            FFastStep := -FastStep;
        end;
      end;
    $06, $1B:
      if Params(0) and DiscReady then
      begin
        Ack;
        if FSeekPending then
          StartDrive(TPS1CDDrive.SeekRead, FTarget)
        else if FDrive <> TPS1CDDrive.Reading then
          StartDrive(TPS1CDDrive.SeekRead, FPosition);
        FSeekPending := False;
      end;
    $07:
      if Params(0) and DiscReady then
      begin
        if FMotorOn then
          Fail($20)
        else
        begin
          Ack;
          FMotorOn := True;
          FSpinUntil := FScheduler.Now + SpinUpDelay;
          Second(2, SpinUpDelay, ActionNone, []);
        end;
      end;
    $08:
      if Params(0) and DiscReady then
      begin
        var Delay: Int64 := IdleDelay;
        if MotorReady then
        begin
          Delay := StopDelaySingle;
          if (FMode and ModeDouble) <> 0 then
            Delay := StopDelayDouble;
        end;
        StopDrive;
        FSeekPending := False;
        Ack;
        FPosition := 0;
        FHeaderValid := False;
        Second(2, Delay, ActionStop, []);
      end;
    $09:
      if Params(0) and DiscReady then
      begin
        var Delay: Int64 := IdleDelay;
        if Active then
          Delay := PauseDelay;
        Ack;
        StopDrive;
        Second(2, Delay, ActionNone, []);
      end;
    $0A:
      // A second Init while one is still in progress is dropped silently.
      if FSecondAction <> ActionInit then
      begin
        StopDrive;
        FSeekPending := False;
        FMode := $20;
        // The head returns to the start; a header seen before stays valid
        // and follows the new position (ps1-tests cdrom/getloc).
        FPosition := 0;
        FLastRead := 0;
        if FHeaderValid then
        begin
          var Sector: TPS1CDSector;
          FHeaderValid := ReadDisc(0, Sector);
          Move(Sector[12], FHeader[0], 8);
        end;
        var Delay: Int64 := InitDelay;
        if (FDisc <> nil) and not FShellOpen then
        begin
          if not FMotorOn then
          begin
            FMotorOn := True;
            FSpinUntil := FScheduler.Now + SpinUpDelay;
          end;
          if FSpinUntil > FScheduler.Now then
            Inc(Delay, FSpinUntil - FScheduler.Now);
        end;
        Ack;
        Second(2, Delay, ActionInit, []);
      end;
    $0B, $0C:
      if Params(0) then
      begin
        FAudio.Muted := Command = $0B;
        Ack;
      end;
    $0D:
      if Params(2) then
      begin
        FFile := FParams[0];
        FChannel := FParams[1];
        Ack;
      end;
    $0E:
      if Params(1) then
      begin
        FMode := FParams[0];
        Ack;
      end;
    $0F:
      if Params(0) then
        Respond(Response(3, [Stat, FMode, 0, FFile, FChannel]));
    $10:
      if Params(0) and DiscReady then
      begin
        if not FHeaderValid or (FDrive in [TPS1CDDrive.SeekRead, TPS1CDDrive.SeekPlay, TPS1CDDrive.SeekOnly]) then
          Fail($80)
        else
          Respond(Response(3, [FHeader[0], FHeader[1], FHeader[2], FHeader[3], FHeader[4], FHeader[5],
                FHeader[6], FHeader[7]]));
      end;
    $11:
      if Params(0) and DiscReady then
      begin
        if not MotorReady then
          Fail($80)
        else
        begin
          var LBA := FPosition;
          if FDrive in [TPS1CDDrive.Reading, TPS1CDDrive.Playing] then
            LBA := FLastRead;
          PositionQ(LBA, Q);
          Respond(Response(3, [Q[1], Q[2], Q[3], Q[4], Q[5], Q[7], Q[8], Q[9]]));
        end;
      end;
    $12:
      if Params(1) and DiscReady then
      begin
        if FParams[0] = 0 then
          Fail($10)
        else
        begin
          Ack;
          FSeekPending := False;
          if FParams[0] = 1 then
          begin
            FSeekCommand := $16;
            StartDrive(TPS1CDDrive.SeekOnly, 0);
          end
          else
            Second(5, InitDelay, ActionNone, [Stat or StatSeekError, $40]);
        end;
      end;
    $13:
      if Params(0) and DiscReady then
        Respond(Response(3, [Stat, 1, BCD(FDisc.TrackCount)]));
    $14:
      if Params(1) and DiscReady then
      begin
        var Track := FromBCD(FParams[0]);
        if not ValidBCD(FParams[0], 100) or (Track > FDisc.TrackCount) then
          Fail($10)
        else
        begin
          var LBA := FDisc.LeadOut;
          if Track > 0 then
            LBA := FDisc.Track(Track).StartLBA;
          Inc(LBA, 150);
          Respond(Response(3, [Stat, BCD(LBA div 4500), BCD((LBA div 75) mod 60)]));
        end;
      end;
    $15, $16:
      if Params(0) and DiscReady then
      begin
        Ack;
        var Target := FPosition;
        if FSeekPending then
          Target := FTarget;
        FSeekPending := False;
        FSeekCommand := Command;
        StartDrive(TPS1CDDrive.SeekOnly, Target);
      end;
    $19:
      if FParamCount = 0 then
        Fail($20)
      else
        case FParams[0] of
          $04:
            Ack;
          $05:
            if DiscType = $20 then
              Respond(Response(3, [1, 1]))
            else
              Respond(Response(3, [0, 0]));
          $20:
            Respond(Response(3, [$97, $01, $10, $C2]));
          $21:
            Respond(Response(3, [Ord(FShellOpen) shl 1]));
          $22:
            case FRegion of
              'E':
                Respond(Response(3, [Ord('f'), Ord('o'), Ord('r'), Ord(' '), Ord('E'), Ord('u'), Ord('r'),
                      Ord('o'), Ord('p'), Ord('e')]));
              'I':
                Respond(Response(3, [Ord('f'), Ord('o'), Ord('r'), Ord(' '), Ord('J'), Ord('a'), Ord('p'),
                      Ord('a'), Ord('n')]));
            else
              Respond(Response(3, [Ord('f'), Ord('o'), Ord('r'), Ord(' '), Ord('U'), Ord('/'), Ord('C')]));
            end;
        else
          Fail($10);
        end;
    $1A:
      if Params(0) then
      begin
        if FShellOpen then
          Fail($80)
        else if FDisc = nil then
        begin
          Ack;
          Second(5, GetIDDelay, ActionNone, [$08, $40, 0, 0, 0, 0, 0, 0]);
        end
        else if not MotorReady then
          Fail($80)
        else
        begin
          Ack;
          var Kind := DiscType;
          if FDisc.Track(1).Audio then
            Second(5, GetIDDelay, ActionNone, [Stat or StatIdError, $90, 0, 0, 0, 0, 0, 0])
          else
            Second(2, GetIDDelay, ActionNone, [Stat, 0, Kind, 0, Ord('S'), Ord('C'), Ord('E'), RegionLetter]);
        end;
      end;
    $1C:
      begin
        // Restarts the controller; no completion interrupt follows.
        Ack;
        StopDrive;
        FQueueCount := 0;
        FDataQueued := False;
        FSecondAt := PS1Never;
        FSecondAction := ActionNone;
        FSeekPending := False;
        FHeaderValid := False;
        FMode := 0;
        FAudio.Muted := False;
      end;
    $1D:
      if Params(2) and DiscReady then
      begin
        Ack;
        var Point := FParams[1];
        var LBA := -1;
        var Control: Byte := $01;
        if ValidBCD(Point, 100) and (FromBCD(Point) >= 1) and (FromBCD(Point) <= FDisc.TrackCount) then
        begin
          LBA := FDisc.Track(FromBCD(Point)).StartLBA + 150;
          if not FDisc.Track(FromBCD(Point)).Audio then
            Control := $41;
        end
        else if Point = $A2 then
          LBA := FDisc.LeadOut + 150;
        if (FParams[0] <> 1) or (LBA < 0) then
          Second(5, InitDelay, ActionNone, [Stat or StatError, $80])
        else
          Second(2, InitDelay, ActionNone, [Control, 0, Point, 0, 0, 0, 0, BCD(LBA div 4500),
              BCD((LBA div 75) mod 60), BCD(LBA mod 75), 0]);
      end;
    $1E:
      if Params(0) and DiscReady then
      begin
        StopDrive;
        FSeekPending := False;
        Ack;
        Second(2, ReadTOCDelay, ActionNone, []);
      end;
  else
    Fail($40);
  end;
end;

procedure TPS1CDROM.OpenShell;
begin
  StopDrive;
  FShellOpen := True;
  FShellWasOpen := True;
  FMotorOn := False;
  FSeekPending := False;
  FHeaderValid := False;
  FSecondAt := PS1Never;
  FSecondAction := ActionNone;
  FDisc := nil;
  FStoredQ := False;
  Enqueue(Response(5, [Stat or StatError, $08]));
end;

procedure TPS1CDROM.CloseShell(Disc: TCDDisc);
begin
  FShellOpen := False;
  SetDisc(Disc);
  if FDisc <> nil then
  begin
    FMotorOn := True;
    FSpinUntil := FScheduler.Now + SpinUpDelay;
  end;
  FPosition := 0;
end;

procedure TPS1CDROM.SerializeState(State: TStateArchive);
begin
  State.Field(FIndex, SizeOf(FIndex));
  State.Field(FIntEnable, SizeOf(FIntEnable));
  State.Field(FIntFlag, SizeOf(FIntFlag));
  State.Field(FRequest, SizeOf(FRequest));
  State.Field(FParams, SizeOf(FParams));
  State.Field(FParamCount, SizeOf(FParamCount));
  State.Field(FResult, SizeOf(FResult));
  State.Field(FResultCount, SizeOf(FResultCount));
  State.Field(FResultRead, SizeOf(FResultRead));
  State.Field(FData, SizeOf(FData));
  State.Field(FDataCount, SizeOf(FDataCount));
  State.Field(FDataRead, SizeOf(FDataRead));
  State.Field(FCommand, SizeOf(FCommand));
  State.Field(FCommandPending, SizeOf(FCommandPending));
  State.Field(FCommandAt, SizeOf(FCommandAt));
  State.Field(FQueue, SizeOf(FQueue));
  State.Field(FQueueCount, SizeOf(FQueueCount));
  State.Field(FNextInterrupt, SizeOf(FNextInterrupt));
  State.Field(FDataQueued, SizeOf(FDataQueued));
  State.Field(FSecond, SizeOf(FSecond));
  State.Field(FSecondAt, SizeOf(FSecondAt));
  State.Field(FSecondAction, SizeOf(FSecondAction));
  State.Field(FDrive, SizeOf(FDrive));
  State.Field(FDriveAt, SizeOf(FDriveAt));
  State.Field(FSpinUntil, SizeOf(FSpinUntil));
  State.Field(FMotorOn, SizeOf(FMotorOn));
  State.Field(FShellOpen, SizeOf(FShellOpen));
  State.Field(FShellWasOpen, SizeOf(FShellWasOpen));
  State.Field(FMode, SizeOf(FMode));
  State.Field(FFile, SizeOf(FFile));
  State.Field(FChannel, SizeOf(FChannel));
  State.Field(FPosition, SizeOf(FPosition));
  State.Field(FTarget, SizeOf(FTarget));
  State.Field(FLastRead, SizeOf(FLastRead));
  State.Field(FSeekPending, SizeOf(FSeekPending));
  State.Field(FSeekCommand, SizeOf(FSeekCommand));
  State.Field(FPlayTrack, SizeOf(FPlayTrack));
  State.Field(FFastStep, SizeOf(FFastStep));
  State.Field(FDelivered, SizeOf(FDelivered));
  State.Field(FNewest, SizeOf(FNewest));
  State.Field(FDeliveredValid, SizeOf(FDeliveredValid));
  State.Field(FNewestValid, SizeOf(FNewestValid));
  State.Field(FHeader, SizeOf(FHeader));
  State.Field(FHeaderValid, SizeOf(FHeaderValid));
  State.Field(FLastQ, SizeOf(FLastQ));
  State.Field(FXAActive, SizeOf(FXAActive));
  FAudio.SerializeState(State);
  if State.Loading then
  begin
    if (FParamCount < 0) or (FParamCount > 16) or (FResultCount < 0) or (FResultCount > 16) or
      (FResultRead < 0) or (FResultRead >= 32) or (FDataCount < 0) or (FDataCount > Length(FData)) or
      (FDataRead < 0) or (FDataRead > FDataCount) or (FQueueCount < 0) or (FQueueCount > Length(FQueue)) or
      (Ord(FDrive) > Ord(High(TPS1CDDrive))) or (FSecondAction > ActionSpinUp) then
      raise EReadError.Create('PS1 snapshot CD-ROM');
    ScheduleNext;
  end;
end;

end.

