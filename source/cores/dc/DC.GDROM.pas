unit DC.GDROM;

// GD-ROM drive on the G1 ATA interface (005F7000..): the ATA registers, the
// packet (SPI) commands a boot ROM uses (status, mode, TOC, sessions, reads
// by PIO or G1 DMA, CD-DA control, sub-channel) and the CD-DA playback state
// shared with the high-level system calls and the AICA mixer (44.1 kHz
// stereo from audio sectors, 588 samples each).
// References: ATA/ATAPI-4 packet protocol; Marcus Comstedt's GD-ROM notes
// and the GD-ROM command list documented by the Dreamcast homebrew
// community. The security commands (70h/71h) report a media check result
// built from the disc (see SecurityReply).
{$IFDEF DC_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, System.Classes, Core.Snapshots, DC.Types, DC.Scheduler, DC.Interrupts, DC.Disc;

type
  TDCCDDAState = record
    Status: Integer;          // 0 none, 1 playing, 2 paused, 3 ended
    StartFAD, EndFAD, FAD: Cardinal;
    Repeats: Integer;         // 0..14, 15 = forever
    Sample: Integer;          // sample index in the current sector
  end;

  TDCGDROMState = record
    Status, Error, Features, Reason, ByteCount, ByteLimit, DriveSelect, DeviceControl: Cardinal;
    // Transfer phase: 0 idle, 1 packet wanted, 2 data to the host (PIO),
    // 3 data from the host (PIO), 4 data to the host by G1 DMA.
    Phase: Integer;
    Packet: array[0..11] of Byte;
    PacketPos: Integer;
    // Buffered chunk (DataPos..DataLen) and the sectors still to read.
    DataPos, DataLen: Integer;
    ReadFAD, ReadLeft: Cardinal;
    ReadRaw: Boolean;
    // Mode data written by SET_MODE at DataTarget.
    DataTarget: Integer;
    // What the next drive event does: 0 nothing, 1 present a PIO chunk,
    // 2 complete the command.
    Pending: Integer;
    IRQ: Boolean;
    SenseKey, SenseCode: Byte;
    // Lid open (drive status 6); a disc inserted since the last command
    // makes the next packet command report UNIT ATTENTION once.
    LidOpen, MediaChanged: Boolean;
    // Clock at which an open lid closes on the tray's disc (0: stays open).
    LidCloseAt: Int64;
    CurrentFAD: Cardinal;
    Mode: array[0..31] of Byte;
    CDDA: TDCCDDAState;
  end;

  TDCGDROM = class
  private
    FScheduler: TDCScheduler;
    FInterrupts: TDCInterrupts;
    FAudio: array[0..2351] of Byte;
    FAudioFAD: Cardinal;
    FAudioValid: Boolean;
    FData: TBytes;
    procedure RaiseIRQ;
    procedure SetPending(Kind: Integer; Delay: Int64);
    procedure Complete(Delay: Int64);
    procedure Fail(Key, Code: Byte);
    procedure SendData(const Data: array of Byte; Offset, Limit: Integer);
    procedure FillSectors;
    procedure StartRead(FAD, Count: Cardinal; Raw: Boolean);
    procedure ATACommand(Command: Cardinal);
    procedure PacketCommand;
    function ReadDataWord: Cardinal;
    procedure WriteDataWord(Value: Cardinal);
    function MediaType: Cardinal;
    function TrackControl(FAD: Cardinal; out Track: Integer): Byte;
    function SecurityReply: TBytes;
  public
    S: TDCGDROMState;
    // Not owned; nil without a disc or with the lid open.
    Disc: TDCDisc;
    // The disc in the tray (not owned): Disc, or the one inserted when the
    // lid closes.
    Tray: TDCDisc;
    // Diagnostics: packet commands are listed here when assigned.
    Trace: TStrings;
    constructor Create(Scheduler: TDCScheduler; Interrupts: TDCInterrupts);
    procedure Reset;
    function Read(Offset: Cardinal; Size: Integer): Cardinal;
    procedure Write(Offset, Value: Cardinal; Size: Integer);
    procedure Event;
    // Copies up to Count bytes of pending DMA data; returns the bytes moved.
    function DMARead(Dest: PByte; Count: Integer): Integer;
    // CD-DA control.
    procedure PlayTracks(First, Last, Repeats: Cardinal);
    procedure PlaySectors(StartFAD, EndFAD, Repeats: Cardinal);
    procedure PauseCDDA;
    procedure ResumeCDDA;
    procedure StopCDDA;
    procedure SeekCDDA(FAD: Cardinal);
    function CDDAPosition: Cardinal;
    // Sub-channel audio status (11h playing, 12h paused, 13h ended, 15h none).
    function AudioStatus: Byte;
    // Drive status code: 1 paused, 2 standby, 3 playing, 6 lid open,
    // 7 no disc.
    function DriveStatus: Cardinal;
    // Disc change: the lid opens (reads stop, the disc is gone, the tray is
    // empty), then closes on another disc wrapper (or none), at once or after
    // Delay clocks. Settle applies a close that is due; the drive does so
    // itself before it reports anything.
    procedure OpenLid;
    procedure CloseLid(NewDisc: TDCDisc);
    procedure CloseLidLater(NewDisc: TDCDisc; Delay: Int64);
    procedure Settle;
    // For the high-level system calls: INTRQ as the drive raises it when
    // data is ready, and its acknowledgement by a status read.
    procedure SetInterrupt(Active: Boolean);
    // Next CD-DA output sample; silence unless playing.
    procedure NextSample(out Left, Right: SmallInt);
    procedure SerializeState(Archive: TStateArchive);
  end;

implementation

const
  ATAStatusBSY = $80;
  ATAStatusDRDY = $40;
  ATAStatusDSC = $10;
  ATAStatusDRQ = $08;
  ATAStatusCHECK = $01;

  // Interrupt reason (sector count register): CoD and IO.
  ReasonCommand = 1;
  ReasonToHost = 2;

  PhaseIdle = 0;
  PhasePacket = 1;
  PhaseDataIn = 2;
  PhaseDataOut = 3;
  PhaseDMA = 4;

  PendingChunk = 1;
  PendingComplete = 2;

  // Clocks from a command to its result; reads take longer per sector.
  CommandDelay = 4000;
  SectorDelay = 2000;
  MaxChunkSectors = 32;

  DefaultMode: array[0..31] of Byte = (0, 0, 0, 0, 0, $B4, $19, 0, 0, 8,
    Ord('S'), Ord('E'), 32, 32, 32, 32, 32, 32,
    Ord('R'), Ord('e'), Ord('v'), 32, Ord('6'), Ord('.'), Ord('4'), Ord('3'),
    Ord('9'), Ord('9'), Ord('0'), Ord('4'), Ord('0'), Ord('8'));

  IdentifyText: AnsiString = 'SE              CD-ROM DRIVE    6.43990408      ';

constructor TDCGDROM.Create(Scheduler: TDCScheduler; Interrupts: TDCInterrupts);
begin
  inherited Create;
  FScheduler := Scheduler;
  FInterrupts := Interrupts;
  SetLength(FData, MaxChunkSectors * 2352);
  Reset;
end;

procedure TDCGDROM.Reset;
begin
  S := Default(TDCGDROMState);
  S.Status := ATAStatusDRDY or ATAStatusDSC;
  S.Reason := ReasonCommand or ReasonToHost;
  Move(DefaultMode, S.Mode, SizeOf(S.Mode));
  FAudioValid := False;
  FScheduler.Cancel(TDCEvent.GDROM);
  FInterrupts.SetExternal(HollyExtGDROM, False);
end;

function TDCGDROM.DriveStatus: Cardinal;
begin
  Settle;
  if S.LidOpen then
    Exit(6);
  if (Disc = nil) or not Disc.HasBootTrack then
    Exit(7);
  case S.CDDA.Status of
    1: Result := 3;
    2: Result := 1;
  else
    Result := 1;
  end;
end;

function TDCGDROM.MediaType: Cardinal;
begin
  // The medium as it is; the high-level system calls may report a GD-ROM
  // for self-booting copies, the drive does not.
  if Disc = nil then
    Exit(0);
  if Disc.IsGDROM then
    Exit(DCDiscGDROM);
  Result := DCDiscCDDA;
  for var T := 1 to Disc.Image.TrackCount do
    if not Disc.Image.Track(T).Audio then
    begin
      if Disc.Image.Track(T).DataOffset in [8, 24] then
        Exit(DCDiscCDROMXA);
      Result := DCDiscCDROM;
    end;
end;

function TDCGDROM.TrackControl(FAD: Cardinal; out Track: Integer): Byte;
begin
  Track := 0;
  Result := $41;
  if Disc = nil then
    Exit;
  Track := Disc.TrackOf(Integer(FAD) - 150);
  if (Track > 0) and Disc.Image.Track(Track).Audio then
    Result := $01;
end;

function TDCGDROM.AudioStatus: Byte;
begin
  case S.CDDA.Status of
    1: Result := $11;
    2: Result := $12;
    3: Result := $13;
  else
    Result := $15;
  end;
end;

function TDCGDROM.CDDAPosition: Cardinal;
begin
  if S.CDDA.Status in [1, 2] then
    Result := S.CDDA.FAD
  else
    Result := 0;
end;

procedure TDCGDROM.PlaySectors(StartFAD, EndFAD, Repeats: Cardinal);
begin
  S.CDDA.StartFAD := StartFAD;
  S.CDDA.EndFAD := EndFAD;
  S.CDDA.FAD := StartFAD;
  S.CDDA.Repeats := Integer(Repeats and 15);
  S.CDDA.Sample := 0;
  S.CDDA.Status := 1;
  FAudioValid := False;
end;

procedure TDCGDROM.PlayTracks(First, Last, Repeats: Cardinal);
begin
  if (Disc = nil) or (First < 1) or (Int64(First) > Disc.Image.TrackCount) then
    Exit;
  if (Last < First) or (Int64(Last) > Disc.Image.TrackCount) then
    Last := First;
  PlaySectors(Cardinal(Disc.Image.Track(First).StartLBA + 150), Cardinal(Disc.Image.Track(Last).EndLBA + 150 - 1), Repeats);
end;

procedure TDCGDROM.PauseCDDA;
begin
  if S.CDDA.Status = 1 then
    S.CDDA.Status := 2;
end;

procedure TDCGDROM.ResumeCDDA;
begin
  if S.CDDA.Status = 2 then
    S.CDDA.Status := 1;
end;

procedure TDCGDROM.StopCDDA;
begin
  S.CDDA.Status := 0;
end;

procedure TDCGDROM.SeekCDDA(FAD: Cardinal);
begin
  S.CDDA.FAD := FAD;
  S.CDDA.StartFAD := FAD;
  S.CDDA.Sample := 0;
  S.CDDA.Status := 2;
end;

procedure TDCGDROM.NextSample(out Left, Right: SmallInt);
begin
  Left := 0;
  Right := 0;
  if (S.CDDA.Status <> 1) or (Disc = nil) then
    Exit;
  if not FAudioValid or (FAudioFAD <> S.CDDA.FAD) then
  begin
    Disc.ReadAudio(Integer(S.CDDA.FAD) - 150, @FAudio[0]);
    FAudioFAD := S.CDDA.FAD;
    FAudioValid := True;
  end;
  Left := PSmallInt(@FAudio[S.CDDA.Sample * 4])^;
  Right := PSmallInt(@FAudio[S.CDDA.Sample * 4 + 2])^;
  Inc(S.CDDA.Sample);
  if S.CDDA.Sample = 588 then
  begin
    S.CDDA.Sample := 0;
    Inc(S.CDDA.FAD);
    if S.CDDA.FAD > S.CDDA.EndFAD then
    begin
      if S.CDDA.Repeats > 0 then
      begin
        if S.CDDA.Repeats < 15 then
          Dec(S.CDDA.Repeats);
        S.CDDA.FAD := S.CDDA.StartFAD;
      end
      else
        S.CDDA.Status := 3;
    end;
  end;
end;

procedure TDCGDROM.OpenLid;
begin
  S.LidCloseAt := 0;
  Tray := nil;
  if S.LidOpen then
    Exit;
  StopCDDA;
  // A transfer in progress ends with an error.
  if (S.Phase <> PhaseIdle) or (S.Pending <> 0) then
  begin
    FScheduler.Cancel(TDCEvent.GDROM);
    S.Pending := 0;
    S.ReadLeft := 0;
    Fail(2, $3A);
  end;
  S.LidOpen := True;
  S.CurrentFAD := 0;
  Disc := nil;
  FAudioValid := False;
end;

procedure TDCGDROM.CloseLid(NewDisc: TDCDisc);
begin
  S.LidOpen := False;
  S.LidCloseAt := 0;
  Tray := NewDisc;
  Disc := NewDisc;
  S.MediaChanged := Disc <> nil;
  FAudioValid := False;
end;

procedure TDCGDROM.CloseLidLater(NewDisc: TDCDisc; Delay: Int64);
begin
  OpenLid;
  Tray := NewDisc;
  if Delay < 1 then
    Delay := 1;
  S.LidCloseAt := FScheduler.Now + Delay;
end;

procedure TDCGDROM.Settle;
begin
  if S.LidOpen and (S.LidCloseAt <> 0) and (FScheduler.Now >= S.LidCloseAt) then
    CloseLid(Tray);
end;

{ ATA }

procedure TDCGDROM.RaiseIRQ;
begin
  S.IRQ := True;
  // nIEN (device control bit 1) keeps INTRQ low.
  if (S.DeviceControl and 2) = 0 then
    FInterrupts.SetExternal(HollyExtGDROM, True);
end;

procedure TDCGDROM.SetInterrupt(Active: Boolean);
begin
  if Active then
    RaiseIRQ
  else
  begin
    S.IRQ := False;
    FInterrupts.SetExternal(HollyExtGDROM, False);
  end;
end;

procedure TDCGDROM.SetPending(Kind: Integer; Delay: Int64);
begin
  S.Pending := Kind;
  S.Status := ATAStatusBSY;
  FScheduler.Schedule(TDCEvent.GDROM, FScheduler.Now + Delay);
end;

procedure TDCGDROM.Complete(Delay: Int64);
begin
  S.Phase := PhaseIdle;
  SetPending(PendingComplete, Delay);
end;

procedure TDCGDROM.Fail(Key, Code: Byte);
begin
  if Trace <> nil then
    Trace.Add(Format('fail %d %.2x', [Key, Code]));
  S.SenseKey := Key;
  S.SenseCode := Code;
  S.Phase := PhaseIdle;
  S.Error := (Cardinal(Key) shl 4) or $04;
  S.Status := ATAStatusDRDY or ATAStatusCHECK;
  S.Reason := ReasonCommand or ReasonToHost;
  RaiseIRQ;
end;

procedure TDCGDROM.SendData(const Data: array of Byte; Offset, Limit: Integer);
begin
  // Bytes Offset..Offset+Limit-1 of a response, as one PIO chunk.
  if Offset < 0 then
    Offset := 0;
  var Count := Length(Data) - Offset;
  if Count > Limit then
    Count := Limit;
  if Count <= 0 then
  begin
    Complete(CommandDelay);
    Exit;
  end;
  Move(Data[Offset], FData[0], Count);
  S.DataPos := 0;
  S.DataLen := Count;
  S.ReadLeft := 0;
  S.Phase := PhaseDataIn;
  SetPending(PendingChunk, CommandDelay);
end;

procedure TDCGDROM.FillSectors;
begin
  // As many sectors as the host's byte count allows (at least one).
  var Size := 2048;
  if S.ReadRaw then
    Size := 2352;
  var Count: Integer;
  if S.Phase = PhaseDataIn then
  begin
    var Limit := Integer(S.ByteLimit);
    if Limit = 0 then
      Limit := $10000;
    Count := Limit div Size;
  end
  else
    Count := MaxChunkSectors;
  if Count < 1 then
    Count := 1;
  if Count > MaxChunkSectors then
    Count := MaxChunkSectors;
  if Cardinal(Count) > S.ReadLeft then
    Count := Integer(S.ReadLeft);
  for var I := 0 to Count - 1 do
  begin
    var LBA := Integer(S.ReadFAD) - 150;
    if Disc = nil then
      FillChar(FData[I * Size], Size, 0)
    else if S.ReadRaw then
      Disc.ReadAudio(LBA, @FData[I * Size])
    else
      Disc.ReadData(LBA, @FData[I * Size]);
    S.CurrentFAD := S.ReadFAD;
    Inc(S.ReadFAD);
    Dec(S.ReadLeft);
  end;
  S.DataPos := 0;
  S.DataLen := Count * Size;
end;

procedure TDCGDROM.StartRead(FAD, Count: Cardinal; Raw: Boolean);
begin
  if (Disc = nil) or not Disc.HasBootTrack then
  begin
    Fail(2, $3A);
    Exit;
  end;
  StopCDDA;
  S.ReadFAD := FAD;
  S.ReadLeft := Count;
  S.ReadRaw := Raw;
  if Count = 0 then
  begin
    Complete(CommandDelay);
    Exit;
  end;
  if (S.Features and 1) <> 0 then
  begin
    // G1 DMA pulls the data; the drive signals completion afterwards.
    S.Phase := PhaseDMA;
    S.DataPos := 0;
    S.DataLen := 0;
    S.Status := ATAStatusDRDY or ATAStatusDRQ;
    S.Reason := ReasonToHost;
    Exit;
  end;
  S.Phase := PhaseDataIn;
  FillSectors;
  SetPending(PendingChunk, CommandDelay + Int64(S.DataLen div 2048 + 1) * SectorDelay);
end;

procedure TDCGDROM.ATACommand(Command: Cardinal);
begin
  FScheduler.Cancel(TDCEvent.GDROM);
  if (Trace <> nil) and (Command <> $A0) then
    Trace.Add(Format('ata %.2x', [Command]));
  S.Pending := 0;
  S.Error := 0;
  case Command of
    $00:
      begin
        // NOP: aborts the command in progress (ABRT), as the system calls do
        // to cancel a transfer.
        S.Phase := PhaseIdle;
        S.ReadLeft := 0;
        S.DataPos := 0;
        S.DataLen := 0;
        S.Error := $04;
        S.Status := ATAStatusDRDY or ATAStatusCHECK;
        S.Reason := ReasonCommand or ReasonToHost;
        RaiseIRQ;
      end;
    $08:
      begin
        // Soft reset: the packet device signature, no interrupt.
        S.Phase := PhaseIdle;
        S.Status := ATAStatusDRDY or ATAStatusDSC;
        S.Reason := ReasonCommand;
        S.ByteCount := $EB14;
        S.Error := 1;
        StopCDDA;
      end;
    $90:
      begin
        // Diagnostics: no error.
        S.Error := 1;
        Complete(CommandDelay);
      end;
    $A0:
      begin
        S.Phase := PhasePacket;
        S.PacketPos := 0;
        S.ByteLimit := S.ByteCount;
        S.Status := ATAStatusDRDY or ATAStatusDRQ;
        S.Reason := ReasonCommand;
      end;
    $A1:
      begin
        var Identify: array[0..79] of Byte;
        FillChar(Identify, SizeOf(Identify), 0);
        Move(PAnsiChar(IdentifyText)^, Identify[8], Length(IdentifyText));
        S.ByteLimit := 80;
        SendData(Identify, 0, 80);
      end;
    $EF:
      Complete(CommandDelay);
  else
    Fail(5, $20);
  end;
end;

function BE24(const P: array of Byte; Offset: Integer): Cardinal;
begin
  Result := (Cardinal(P[Offset]) shl 16) or (Cardinal(P[Offset + 1]) shl 8) or P[Offset + 2];
end;

// SYS_REQ_SECU (71h): the result of the drive's media check, obfuscated.
// Each result byte is preceded by a filler byte, a byte holding the distance
// N + 2 to the result byte and N - 1 more fillers, so the host extracts it
// by skipping (as documented with MAME's GD-ROM drive). The 43-byte result
// is a check byte (1Fh GD-ROM, 10h MIL-CD; the boot ROM tests bit 4) and,
// for GD-ROM, the disc ID, maker and hardware ID strings of its IP.BIN.
// Filler and distances come from a fixed generator; the length varies
// between about 300 and 700 bytes, as real replies vary in length.
function TDCGDROM.SecurityReply: TBytes;
begin
  var Plain: array[0..42] of Byte;
  FillChar(Plain, SizeOf(Plain), 0);
  Plain[0] := $10;
  if (Disc <> nil) and Disc.IsGDROM and Disc.HasBootTrack then
  begin
    Plain[0] := $1F;
    var IP := Disc.ReadBootSector(0);
    Move(IP[$40], Plain[1], 10);
    Move(IP[$70], Plain[11], 16);
    Move(IP[$00], Plain[27], 16);
  end;
  Result := nil;
  var Seed: Cardinal := $2C1F7A63;
  var Next :=
    function: Cardinal
    begin
      Seed := Seed * 1103515245 + 12345;
      Result := Seed shr 16;
    end;
  for var I := 0 to High(Plain) do
  begin
    var Distance := 1 + Integer(Next() mod 14);
    var Part: TBytes;
    SetLength(Part, Distance + 2);
    Part[0] := Byte(Next());
    Part[1] := Byte(Distance + 2);
    for var K := 2 to Distance do
      Part[K] := Byte(Next());
    Part[Distance + 1] := Plain[I];
    Result := Result + Part;
  end;
end;

function MSFToFAD(M, S, F: Byte): Cardinal;
begin
  Result := (Cardinal(M) * 60 + S) * 75 + F;
end;

procedure TDCGDROM.PacketCommand;
begin
  Settle;
  var P := S.Packet;
  if Trace <> nil then
  begin
    var Line := 'packet';
    for var I := 0 to 11 do
      Line := Line + ' ' + IntToHex(P[I], 2);
    Trace.Add(Line + Format(' limit %d', [S.ByteLimit]));
  end;
  S.SenseKey := 0;
  S.SenseCode := 0;
  // After a disc change the first medium command reports it.
  if S.MediaChanged and (P[0] in [$00, $14, $15, $20, $21, $30, $31, $40, $70, $71]) then
  begin
    S.MediaChanged := False;
    Fail(6, $28);
    Exit;
  end;
  case P[0] of
    $00, $16, $22, $70:
      // Test unit, tray, scan and security unlock need no data.
      if (Disc = nil) and (P[0] = $00) then
        Fail(2, $3A)
      else
        Complete(CommandDelay);
    $10:
      begin
        var Data: array[0..9] of Byte;
        FillChar(Data, SizeOf(Data), 0);
        var FAD := CDDAPosition;
        if FAD = 0 then
          FAD := S.CurrentFAD;
        var Track: Integer;
        Data[0] := Byte(DriveStatus);
        Data[1] := Byte(MediaType or Cardinal(S.CDDA.Repeats and 15));
        Data[2] := TrackControl(FAD, Track);
        Data[3] := Byte(Track);
        Data[4] := 1;
        Data[5] := Byte(FAD shr 16);
        Data[6] := Byte(FAD shr 8);
        Data[7] := Byte(FAD);
        Data[8] := 8;
        SendData(Data, P[2], P[4]);
      end;
    $11:
      SendData(S.Mode, P[2], P[4]);
    $12:
      begin
        // The mode bytes follow from the host.
        S.DataTarget := P[2];
        S.DataPos := 0;
        S.DataLen := P[4];
        if S.DataLen = 0 then
        begin
          Complete(CommandDelay);
          Exit;
        end;
        S.Phase := PhaseDataOut;
        S.ByteCount := Cardinal(S.DataLen);
        S.Status := ATAStatusDRDY or ATAStatusDRQ;
        S.Reason := 0;
        RaiseIRQ;
      end;
    $13:
      begin
        var Data: array[0..9] of Byte;
        FillChar(Data, SizeOf(Data), 0);
        Data[0] := $F0;
        Data[2] := S.SenseKey;
        Data[8] := S.SenseCode;
        SendData(Data, 0, P[4]);
      end;
    $14:
      begin
        var Words: TArray<Cardinal>;
        if Disc = nil then
        begin
          Fail(2, $3A);
          Exit;
        end;
        if not Disc.TOC(P[1] and 1, Words) then
        begin
          Fail(5, $24);
          Exit;
        end;
        // Entries as control/address then a big-endian FAD.
        var Data: array[0..407] of Byte;
        for var I := 0 to 101 do
        begin
          Data[I * 4] := Byte(Words[I] shr 24);
          Data[I * 4 + 1] := Byte(Words[I] shr 16);
          Data[I * 4 + 2] := Byte(Words[I] shr 8);
          Data[I * 4 + 3] := Byte(Words[I]);
        end;
        SendData(Data, 0, (Integer(P[3]) shl 8) or P[4]);
      end;
    $15:
      begin
        var Data: array[0..5] of Byte;
        FillChar(Data, SizeOf(Data), 0);
        Data[0] := Byte(DriveStatus);
        if Disc <> nil then
        begin
          var Sessions := 1;
          for var T := 1 to Disc.Image.TrackCount do
            if Disc.Image.Track(T).Session > Sessions then
              Sessions := Disc.Image.Track(T).Session;
          var FAD: Cardinal := 0;
          if P[2] = 0 then
          begin
            Data[2] := Byte(Sessions);
            FAD := Cardinal(Disc.Image.LeadOut + 150);
          end
          else
            for var T := 1 to Disc.Image.TrackCount do
              if Disc.Image.Track(T).Session = Integer(P[2]) then
              begin
                Data[2] := Byte(T);
                FAD := Cardinal(Disc.Image.Track(T).StartLBA + 150);
                Break;
              end;
          Data[3] := Byte(FAD shr 16);
          Data[4] := Byte(FAD shr 8);
          Data[5] := Byte(FAD);
        end;
        SendData(Data, 0, P[4]);
      end;
    $20:
      begin
        if Disc = nil then
        begin
          Fail(2, $3A);
          Exit;
        end;
        case P[1] and 7 of
          1: PlaySectors(BE24(P, 2), BE24(P, 8), P[6]);
          2: PlaySectors(MSFToFAD(P[2], P[3], P[4]), MSFToFAD(P[8], P[9], P[10]), P[6]);
          7: ResumeCDDA;
        end;
        Complete(CommandDelay);
      end;
    $21:
      begin
        case P[1] and 15 of
          1: SeekCDDA(BE24(P, 2));
          2: SeekCDDA(MSFToFAD(P[2], P[3], P[4]));
          3: StopCDDA;
          4: PauseCDDA;
        end;
        Complete(CommandDelay);
      end;
    $30, $31:
      begin
        var FAD := BE24(P, 2);
        if (P[1] and 1) <> 0 then
          FAD := MSFToFAD(P[2], P[3], P[4]);
        // Data select F: whole 2352-byte sectors (CD-DA); otherwise user data.
        StartRead(FAD, BE24(P, 8), (P[1] shr 4) = $F);
      end;
    $40:
      begin
        var Data: array[0..99] of Byte;
        FillChar(Data, SizeOf(Data), 0);
        var Size := 100;
        if (P[1] and 15) = 1 then
          Size := 14;
        var FAD := CDDAPosition;
        if FAD = 0 then
          FAD := S.CurrentFAD;
        var Track: Integer;
        Data[1] := AudioStatus;
        Data[3] := Byte(Size);
        Data[4] := TrackControl(FAD, Track);
        Data[5] := Byte(Track);
        Data[6] := 1;
        var Relative := 0;
        if Track > 0 then
          Relative := Integer(FAD) - 150 - Disc.Image.Track(Track).StartLBA;
        if Relative < 0 then
          Relative := 0;
        Data[7] := Byte(Relative shr 16);
        Data[8] := Byte(Relative shr 8);
        Data[9] := Byte(Relative);
        Data[11] := Byte(FAD shr 16);
        Data[12] := Byte(FAD shr 8);
        Data[13] := Byte(FAD);
        SendData(Data, 0, Size);
      end;
    $71:
      begin
        var Data := SecurityReply;
        SendData(Data, 0, Length(Data));
      end;
  else
    Fail(5, $20);
  end;
end;

function TDCGDROM.ReadDataWord: Cardinal;
begin
  Result := 0;
  if S.Phase <> PhaseDataIn then
    Exit;
  if S.DataPos + 1 < S.DataLen then
    Result := Cardinal(FData[S.DataPos]) or (Cardinal(FData[S.DataPos + 1]) shl 8)
  else if S.DataPos < S.DataLen then
    Result := FData[S.DataPos];
  Inc(S.DataPos, 2);
  if S.DataPos < S.DataLen then
    Exit;
  // Chunk taken: the next one, or the command ends.
  if S.ReadLeft > 0 then
  begin
    FillSectors;
    SetPending(PendingChunk, Int64(S.DataLen div 2048 + 1) * SectorDelay);
  end
  else
    Complete(CommandDelay);
end;

procedure TDCGDROM.WriteDataWord(Value: Cardinal);
begin
  case S.Phase of
    PhasePacket:
      begin
        S.Packet[S.PacketPos] := Byte(Value);
        S.Packet[S.PacketPos + 1] := Byte(Value shr 8);
        Inc(S.PacketPos, 2);
        if S.PacketPos >= 12 then
        begin
          S.Phase := PhaseIdle;
          S.Status := ATAStatusBSY;
          PacketCommand;
        end;
      end;
    PhaseDataOut:
      begin
        for var K := 0 to 1 do
          if S.DataPos < S.DataLen then
          begin
            var Target := S.DataTarget + S.DataPos;
            if (Target >= 0) and (Target < Length(S.Mode)) then
              S.Mode[Target] := Byte(Value shr (K * 8));
            Inc(S.DataPos);
          end;
        if S.DataPos >= S.DataLen then
          Complete(CommandDelay);
      end;
  end;
end;

procedure TDCGDROM.Event;
begin
  var Kind := S.Pending;
  S.Pending := 0;
  case Kind of
    PendingChunk:
      begin
        S.ByteCount := Cardinal(S.DataLen);
        S.Status := ATAStatusDRDY or ATAStatusDRQ;
        S.Reason := ReasonToHost;
        RaiseIRQ;
      end;
    PendingComplete:
      begin
        S.Status := ATAStatusDRDY or ATAStatusDSC;
        S.Reason := ReasonCommand or ReasonToHost;
        RaiseIRQ;
      end;
  end;
end;

function TDCGDROM.DMARead(Dest: PByte; Count: Integer): Integer;
begin
  Result := 0;
  if S.Phase <> PhaseDMA then
    Exit;
  while Result < Count do
  begin
    if S.DataPos >= S.DataLen then
    begin
      if S.ReadLeft = 0 then
        Break;
      FillSectors;
    end;
    var Chunk := S.DataLen - S.DataPos;
    if Chunk > Count - Result then
      Chunk := Count - Result;
    Move(FData[S.DataPos], (Dest + Result)^, Chunk);
    Inc(S.DataPos, Chunk);
    Inc(Result, Chunk);
  end;
  if (S.ReadLeft = 0) and (S.DataPos >= S.DataLen) then
    Complete(Int64(Result) * 12 + CommandDelay);
end;

function TDCGDROM.Read(Offset: Cardinal; Size: Integer): Cardinal;
begin
  case Offset and $FF of
    $18:
      Result := S.Status;
    $80:
      begin
        Result := ReadDataWord;
        if Size = 4 then
          Result := Result or (ReadDataWord shl 16);
      end;
    $84:
      Result := S.Error;
    $88:
      Result := S.Reason;
    $8C:
      Result := DriveStatus or MediaType;
    $90:
      Result := S.ByteCount and $FF;
    $94:
      Result := (S.ByteCount shr 8) and $FF;
    $98:
      Result := S.DriveSelect;
    $9C:
      begin
        // Reading the status acknowledges the interrupt.
        Result := S.Status;
        S.IRQ := False;
        FInterrupts.SetExternal(HollyExtGDROM, False);
      end;
  else
    Result := 0;
  end;
end;

procedure TDCGDROM.Write(Offset, Value: Cardinal; Size: Integer);
begin
  case Offset and $FF of
    $18:
      begin
        S.DeviceControl := Value and $FF;
        if (S.DeviceControl and 2) <> 0 then
          FInterrupts.SetExternal(HollyExtGDROM, False)
        else if S.IRQ then
          FInterrupts.SetExternal(HollyExtGDROM, True);
      end;
    $80:
      begin
        WriteDataWord(Value and $FFFF);
        if Size = 4 then
          WriteDataWord(Value shr 16);
      end;
    $84:
      S.Features := Value and $FF;
    $88:
      ;
    $90:
      S.ByteCount := (S.ByteCount and $FF00) or (Value and $FF);
    $94:
      S.ByteCount := (S.ByteCount and $FF) or ((Value and $FF) shl 8);
    $98:
      S.DriveSelect := Value and $FF;
    $9C:
      ATACommand(Value and $FF);
  end;
end;

procedure TDCGDROM.SerializeState(Archive: TStateArchive);
begin
  Archive.Field(S, SizeOf(S));
  Archive.Field(FData[0], Length(FData));
  if Archive.Loading then
  begin
    if (S.CDDA.Sample < 0) or (S.CDDA.Sample >= 588) or (S.CDDA.Status < 0) or (S.CDDA.Status > 3) or
      (S.DataPos < 0) or (S.DataLen < 0) or (S.DataLen > Length(FData)) or (S.PacketPos < 0) or (S.PacketPos > 12) or
      (S.Phase < PhaseIdle) or (S.Phase > PhaseDMA) then
      raise EReadError.Create('Dreamcast snapshot GD-ROM state');
    FAudioValid := False;
  end;
end;

end.
