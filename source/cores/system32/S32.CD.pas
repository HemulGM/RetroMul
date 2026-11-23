unit S32.CD;

// MB89352 initiator + SCSI CD target. Register semantics: Fujitsu, Fast
// Track to SCSI (1989), chapters 4-5. Board wiring: Sega/MAME segas32.cpp.
// Single target, asynchronous 8-bit bus; no host network or native driver.
interface

uses
  System.SysUtils, Core.CD.Disc, Core.Snapshots;

type
  TS32CD = class
  private
    FDisc: TCDDisc; // borrowed, used only by the emulation worker
    FRegs: array[0..15] of Byte;
    FFIFO: array[0..7] of Byte;
    FCDB: array[0..15] of Byte;
    FBuffer: array[0..4095] of Byte;
    FAudio: array[0..2351] of Byte;
    FHead, FFilled, FCount, FPhase, FCDBAt, FCDBLength: Integer;
    FAt, FLength, FLBA, FBlocks, FWriteLength: Integer;
    FStatus, FSense, FASC: Byte;
    FTime, FSelectTime: Int64;
    FTransfer, FATN, FACK, FPlaying, FPaused, FAudioCompleted: Boolean;
    FAudioLBA, FAudioEnd, FAudioAt: Integer;
    FTrace: array[0..255] of Cardinal;
    FTraceAt: Integer;
    procedure Command(Value: Byte);
    procedure Pump;
    function TargetRead: Byte;
    procedure TargetWrite(Value: Byte);
    procedure ExecuteCDB;
    procedure Sense(Key, ASC: Byte);
    procedure SetAddress(Offset, LBA: Integer; MSF: Boolean);
    function CDB32(Offset: Integer): Cardinal;
    procedure StartAudio(StartLBA, EndLBA: Integer);
    function GetIRQ: Boolean;
  public
    constructor Create(Disc: TCDDisc);
    procedure Reset;
    procedure RunUntil(Target: Int64);
    function Read(RegisterIndex: Integer): Byte;
    procedure Write(RegisterIndex: Integer; Value: Byte);
    procedure Mix(var Samples: TArray<SmallInt>);
    procedure SerializeState(State: TStateArchive);
    function DebugState: string;
    function Trace: string;
    property IRQ: Boolean read GetIRQ;
    property Phase: Integer read FPhase;
  end;

implementation

uses
  System.Classes, System.Math;

constructor TS32CD.Create(Disc: TCDDisc);
begin
  inherited Create;
  FDisc := Disc;
  Reset;
end;

procedure TS32CD.Reset;
begin
  FillChar(FRegs, SizeOf(FRegs), 0);
  FillChar(FFIFO, SizeOf(FFIFO), 0);
  FillChar(FCDB, SizeOf(FCDB), 0);
  FillChar(FBuffer, SizeOf(FBuffer), 0);
  FillChar(FAudio, SizeOf(FAudio), 0);
  FRegs[1] := $80;
  FHead := 0;
  FFilled := 0;
  FCount := 0;
  FPhase := -1;
  FCDBAt := 0;
  FCDBLength := 0;
  FAt := 0;
  FLength := 0;
  FLBA := 0;
  FBlocks := 0;
  FWriteLength := 0;
  FStatus := 0;
  FSense := 0;
  FASC := 0;
  FTime := 0;
  FSelectTime := -1;
  FTransfer := False;
  FATN := False;
  FACK := False;
  FPlaying := False;
  FPaused := False;
  FAudioLBA := 0;
  FAudioEnd := 0;
  FAudioAt := 0;
  FAudioCompleted := False;
end;

function TS32CD.GetIRQ: Boolean;
begin
  Result := (FRegs[4] and 1 <> 0) or ((FRegs[1] and 1 <> 0) and (FRegs[4] <> 0));
end;

procedure TS32CD.RunUntil(Target: Int64);
begin
  FTime := Target;
  if (FSelectTime >= 0) and (FTime >= FSelectTime) then
  begin
    FSelectTime := -1;
    FRegs[6] := FRegs[6] and not $20;
    if (FRegs[11] and 1 <> 0) and (FRegs[0] <> 0) then
    begin
      FRegs[6] := FRegs[6] or $80;
      FRegs[4] := FRegs[4] or $10;
      FPhase := 2;
      if FATN then
        FPhase := 6;
      FCDBAt := 0;
      FCDBLength := 0;
      FStatus := 0;
    end
    else
      FRegs[4] := FRegs[4] or 4;
  end;
  Pump;
end;

function TS32CD.Read(RegisterIndex: Integer): Byte;
begin
  RegisterIndex := RegisterIndex and 15;
  Pump;
  case RegisterIndex of
    0:
      Result := 1 shl (FRegs[0] and 7);
    5:
      begin
        Result := 0;
        if FPhase >= 0 then
          Result := $08 or Byte(FPhase);
        if (FPhase >= 0) and not FACK then
          Result := Result or $80;
        if FACK then
          Result := Result or $40;
        if FATN then
          Result := Result or $20;
        if FSelectTime >= 0 then
          Result := Result or $10;
        if FRegs[2] and $10 <> 0 then
          Result := 0;
      end;
    6:
      begin
        Result := FRegs[6] and $F0;
        if FFilled = 0 then
          Result := Result or 1;
        if FFilled = 8 then
          Result := Result or 2;
        if FCount = 0 then
          Result := Result or 4;
        if FRegs[2] and $10 <> 0 then
          Result := Result or 8;
      end;
    9:
      Result := FRegs[9] and 15;
    10:
      begin
        Result := FRegs[10];
        if FFilled <> 0 then
        begin
          Result := FFIFO[FHead];
          FHead := (FHead + 1) and 7;
          Dec(FFilled);
          FRegs[10] := Result;
          FRegs[9] := (FRegs[9] - 1) and 15;
        end;
        Pump;
      end;
    11:
      if (FPhase = 3) and (FRegs[8] and 7 = 3) then
        Result := FStatus
      else
        Result := FRegs[11];
    12:
      Result := Byte(FCount shr 16);
    13:
      Result := Byte(FCount shr 8);
    14:
      Result := Byte(FCount);
    15:
      Result := $FF; // MB89352 has no EXBF register
  else
    Result := FRegs[RegisterIndex];
  end;
end;

procedure TS32CD.Write(RegisterIndex: Integer; Value: Byte);
begin
  RegisterIndex := RegisterIndex and 15;
  FTrace[FTraceAt and 255] := (Cardinal(RegisterIndex) shl 16) or (Cardinal(Value) shl 8) or Byte(FPhase);
  Inc(FTraceAt);
  case RegisterIndex of
    0:
      FRegs[0] := Value and 7;
    1:
      begin
        if Value and $80 <> 0 then
        begin
          var ID := FRegs[0];
          var Clock := FTime;
          Reset;
          FRegs[0] := ID;
          FTime := Clock;
        end;
        FRegs[1] := Value;
        if Value and $40 <> 0 then
        begin
          FTransfer := False;
          FFilled := 0;
          FHead := 0;
          FRegs[6] := FRegs[6] and $C0;
          FRegs[7] := 0;
          FRegs[4] := FRegs[4] and not 2;
        end;
      end;
    2:
      Command(Value);
    4:
      FRegs[4] := FRegs[4] and not Value;
    6, 7, 9, 15:
      ;
    10:
      begin
        FRegs[10] := Value;
        if FFilled < 8 then
        begin
          FFIFO[(FHead + FFilled) and 7] := Value;
          Inc(FFilled);
          FRegs[9] := (FRegs[9] - 1) and 15;
        end;
      end;
    12:
      FCount := (FCount and $FFFF) or (Integer(Value) shl 16);
    13:
      FCount := (FCount and $FF00FF) or (Integer(Value) shl 8);
    14:
      begin
        FCount := (FCount and $FFFF00) or Value;
        FRegs[9] := Value and 15;
      end;
  else
    FRegs[RegisterIndex] := Value;
  end;
  Pump;
end;

procedure TS32CD.Command(Value: Byte);
begin
  FRegs[2] := Value;
  if FRegs[1] and $80 <> 0 then
    Exit;
  if Value and $10 <> 0 then
  begin
    FPhase := -1;
    FSelectTime := -1;
    FTransfer := False;
    FFilled := 0;
    FHead := 0;
    FRegs[6] := 0;
    FRegs[4] := FRegs[4] or 1;
    FPlaying := False;
    FSense := 6;
    FASC := $29;
    Exit;
  end;
  case Value and $E0 of
    0:
      if FSelectTime >= 0 then
      begin
        FSelectTime := -1;
        FRegs[6] := 0;
      end;
    $20:
      begin
        // Fujitsu TWAIT=(TCL+6..7)*TCLK, plus selection bus settling.
        FSelectTime := FTime + ((Int64((FCount and 15) + 10) * 16107950 + 7999999) div 8000000);
        FRegs[6] := FRegs[6] or $20;
      end;
    $40:
      FATN := False;
    $60:
      FATN := True;
    $80:
      if FPhase >= 0 then
      begin
        FTransfer := True;
        FRegs[6] := FRegs[6] or $30;
      end;
    $A0:
      begin
        FTransfer := False;
        FRegs[6] := FRegs[6] and not $30;
      end;
    $C0:
      FACK := False;
    $E0:
      if (FPhase >= 0) and not FACK then
      begin
        FACK := True;
        if FPhase and 1 <> 0 then
          FRegs[11] := TargetRead
        else
          TargetWrite(FRegs[11]);
      end;
  end;
end;

procedure TS32CD.Pump;
begin
  if not FTransfer or (FRegs[1] and $C0 <> 0) then
    Exit;
  while FCount > 0 do
  begin
    if (FPhase < 0) or (FPhase <> (FRegs[8] and 7)) then
    begin
      FRegs[4] := FRegs[4] or 8;
      FTransfer := False;
      FRegs[6] := FRegs[6] and not $30;
      Exit;
    end;
    if FPhase and 1 <> 0 then
    begin
      if FFilled = 8 then
        Exit;
      FFIFO[(FHead + FFilled) and 7] := TargetRead;
      Inc(FFilled);
    end
    else
    begin
      if FFilled = 0 then
        Exit;
      var Data := FFIFO[FHead];
      FHead := (FHead + 1) and 7;
      Dec(FFilled);
      TargetWrite(Data);
    end;
    Dec(FCount);
  end;
  // Terminal count is not command completion while received bytes remain
  // in the FIFO. Firmware polls INTS to decide when to stop reading DREG.
  if FFilled <> 0 then
    Exit;
  FTransfer := False;
  FRegs[6] := FRegs[6] and not $30;
  FRegs[4] := FRegs[4] or $10;
end;

function TS32CD.TargetRead: Byte;
begin
  Result := 0;
  case FPhase of
    1:
      begin
        if (FAt >= FLength) and (FBlocks > 0) then
        begin
          var Sector: TBytes;
          try
            FDisc.ReadData(FLBA, Sector);
            FLength := Min(Length(Sector), SizeOf(FBuffer));
            Move(Sector[0], FBuffer, FLength);
          except
            on E: EReadError do
            begin
              Sense(3, $11);
              FLength := 0;
              FBlocks := 1;
            end;
          end;
          Inc(FLBA);
          Dec(FBlocks);
          FAt := 0;
        end;
        if FAt < FLength then
        begin
          Result := FBuffer[FAt];
          Inc(FAt);
        end;
        if (FAt >= FLength) and (FBlocks = 0) then
          FPhase := 3;
      end;
    3:
      begin
        Result := FStatus;
        FPhase := 7;
      end;
    7:
      begin
        FPhase := -1;
        FRegs[6] := FRegs[6] and not $80;
        FRegs[4] := FRegs[4] or $20;
      end;
  end;
end;

procedure TS32CD.TargetWrite(Value: Byte);
begin
  case FPhase of
    6:
      begin
        FPhase := 2;
        FCDBAt := 0;
      end; // identify message for LUN 0
      2:
      begin
        if FCDBAt < Length(FCDB) then
          FCDB[FCDBAt] := Value;
        if FCDBAt = 0 then
          case Value shr 5 of
            0:
              FCDBLength := 6;
            1, 2:
              FCDBLength := 10;
            5:
              FCDBLength := 12;
          else
            FCDBLength := 6;
          end;
        Inc(FCDBAt);
        if FCDBAt = FCDBLength then
          ExecuteCDB;
      end;
    0:
      begin
        Dec(FWriteLength);
        if FWriteLength <= 0 then
          FPhase := 3;
      end;
  end;
end;

procedure TS32CD.Sense(Key, ASC: Byte);
begin
  FSense := Key;
  FASC := ASC;
  FStatus := 2;
end;

function TS32CD.CDB32(Offset: Integer): Cardinal;
begin
  Result := (Cardinal(FCDB[Offset]) shl 24) or (Cardinal(FCDB[Offset + 1]) shl 16) or (Cardinal(FCDB[Offset + 2]) shl 8) or FCDB[Offset + 3];
end;

procedure TS32CD.SetAddress(Offset, LBA: Integer; MSF: Boolean);
begin
  if MSF then
  begin
    Inc(LBA, 150);
    FBuffer[Offset] := 0;
    FBuffer[Offset + 1] := LBA div 4500;
    FBuffer[Offset + 2] := (LBA div 75) mod 60;
    FBuffer[Offset + 3] := LBA mod 75;
  end
  else
  begin
    FBuffer[Offset] := Byte(Cardinal(LBA) shr 24);
    FBuffer[Offset + 1] := Byte(Cardinal(LBA) shr 16);
    FBuffer[Offset + 2] := Byte(Cardinal(LBA) shr 8);
    FBuffer[Offset + 3] := Byte(LBA);
  end;
end;

procedure TS32CD.StartAudio(StartLBA, EndLBA: Integer);
begin
  if (StartLBA < 0) or (StartLBA >= EndLBA) or (EndLBA > FDisc.LeadOut) then
  begin
    Sense(5, $21);
    Exit;
  end;
  if FDisc.IsData(StartLBA) then
  begin
    Sense(5, $64);
    Exit;
  end;
  FAudioLBA := StartLBA;
  FAudioEnd := EndLBA;
  FAudioAt := 0;
  FPlaying := True;
  FPaused := False;
  FAudioCompleted := False;
end;

procedure TS32CD.ExecuteCDB;
begin
  FPhase := 3;
  FStatus := 0;
  FAt := 0;
  FLength := 0;
  FBlocks := 0;
  FWriteLength := 0;
  FillChar(FBuffer, SizeOf(FBuffer), 0);
  var C := FCDB[0];
  if (FCDB[1] and $E0 <> 0) then
  begin
    Sense(5, $25);
    Exit;
  end;
  if (FDisc = nil) and not (C in [$03, $12]) then
  begin
    Sense(2, $3A);
    Exit;
  end;
  case C of
    $00, $1E:
      ;
    $1B:
      if FCDB[4] and 1 = 0 then
        FPlaying := False;
    $03:
      begin
        FBuffer[0] := $70;
        FBuffer[2] := FSense;
        FBuffer[7] := 10;
        FBuffer[12] := FASC;
        FLength := Min(18, Integer(FCDB[4]));
        FSense := 0;
        FASC := 0;
      end;
    $12:
      begin
        if FCDB[1] and 1 <> 0 then
        begin
          Sense(5, $24);
          Exit;
        end;
        FBuffer[0] := 5;
        FBuffer[1] := $80;
        FBuffer[2] := 2;
        FBuffer[3] := 2;
        FBuffer[4] := 31;
        var ID: AnsiString := 'RETROMUL' + 'SYSTEM32 CD-ROM  ' + '1.0 ';
        Move(ID[1], FBuffer[8], Min(Length(ID), 28));
        FLength := Min(36, Integer(FCDB[4]));
      end;
    $25:
      begin
        SetAddress(0, FDisc.LeadOut - 1, False);
        SetAddress(4, 2048, False);
        FLength := 8;
      end;
    $08, $28, $A8:
      begin
        if C = $08 then
        begin
          FLBA := ((Integer(FCDB[1]) and 31) shl 16) or (Integer(FCDB[2]) shl 8) or FCDB[3];
          FBlocks := FCDB[4];
          if FBlocks = 0 then
            FBlocks := 256;
        end
        else
        begin
          if CDB32(2) > Cardinal(High(Integer)) then
          begin
            Sense(5, $21);
            Exit;
          end;
          FLBA := Integer(CDB32(2));
          if C = $28 then
            FBlocks := (Integer(FCDB[7]) shl 8) or FCDB[8]
          else if CDB32(6) > Cardinal(High(Integer)) then
          begin
            Sense(5, $24);
            Exit;
          end
          else
            FBlocks := Integer(CDB32(6));
        end;
        if (Int64(FLBA) + FBlocks > FDisc.LeadOut) then
        begin
          FBlocks := 0;
          Sense(5, $21);
          Exit;
        end;
        if (FBlocks > 0) and not FDisc.IsData(FLBA) then
        begin
          FBlocks := 0;
          Sense(5, $64);
          Exit;
        end;
        FPlaying := False;
      end;
    $15, $55:
      begin
        if C = $15 then
          FWriteLength := FCDB[4]
        else
          FWriteLength := (Integer(FCDB[7]) shl 8) or FCDB[8];
        if FWriteLength <> 0 then
          FPhase := 0;
      end;
    $1A:
      begin
        FBuffer[0] := 11;
        FBuffer[3] := 8;
        FBuffer[9] := 8;
        FLength := Min(12, Integer(FCDB[4]));
      end;
    $2B:
      if CDB32(2) >= Cardinal(FDisc.LeadOut) then
        Sense(5, $21);
    $43:
      begin
        var MSF := FCDB[1] and 2 <> 0;
        var First := Integer(FCDB[6]);
        if First = 0 then
          First := 1;
        FBuffer[2] := 1;
        FBuffer[3] := FDisc.TrackCount;
        FLength := 4;
        for var N := First to FDisc.TrackCount do
        begin
          var Track := FDisc.Track(N);
          FBuffer[FLength + 1] := $10 or (4 * Ord(not Track.Audio));
          FBuffer[FLength + 2] := N;
          SetAddress(FLength + 4, Track.StartLBA, MSF);
          Inc(FLength, 8);
        end;
        FBuffer[FLength + 1] := $10;
        FBuffer[FLength + 2] := $AA;
        SetAddress(FLength + 4, FDisc.LeadOut, MSF);
        Inc(FLength, 8);
        FBuffer[0] := (FLength - 2) shr 8;
        FBuffer[1] := Byte(FLength - 2);
        FLength := Min(FLength, (Integer(FCDB[7]) shl 8) or FCDB[8]);
      end;
    $42:
      begin
        if (FCDB[2] and $40 <> 0) and (FCDB[3] <> 1) then
        begin
          Sense(5, $24);
          Exit;
        end;
        FBuffer[1] := $15;
        if FAudioCompleted then
          FBuffer[1] := $13;
        if FPlaying then
          if FPaused then
            FBuffer[1] := $12
          else
            FBuffer[1] := $11;
        if FCDB[2] and $40 <> 0 then
        begin
          FBuffer[3] := 12;
          FBuffer[4] := 1;
          var Position := EnsureRange(FAudioLBA, 0, Max(0, FDisc.LeadOut - 1));
          var Index := FDisc.TrackAt(Position);
          if Index < 0 then
            Index := Max(0, FDisc.TrackCount - 1);
          var Track := FDisc.Track(Index + 1);
          FBuffer[5] := $10 or (4 * Ord(not Track.Audio));
          FBuffer[6] := Index + 1;
          FBuffer[7] := 1;
          SetAddress(8, Position, FCDB[1] and 2 <> 0);
          SetAddress(12, Position - Track.StartLBA - 150 * Ord(FCDB[1] and 2 <> 0), FCDB[1] and 2 <> 0);
          FLength := 16;
        end
        else
          FLength := 4;
        FLength := Min(FLength, (Integer(FCDB[7]) shl 8) or FCDB[8]);
      end;
    $45:
      if CDB32(2) > Cardinal(High(Integer)) then
        Sense(5, $21)
      else
        StartAudio(Integer(CDB32(2)), Integer(CDB32(2)) + ((Integer(FCDB[7]) shl 8) or FCDB[8]));
    $47:
      StartAudio((Integer(FCDB[3]) * 60 + FCDB[4]) * 75 + FCDB[5] - 150, (Integer(FCDB[6]) * 60 + FCDB[7]) * 75 + FCDB[8] - 150);
    $48:
      begin
        if (FCDB[4] < 1) or (FCDB[4] > FDisc.TrackCount) or (FCDB[7] < FCDB[4]) then
        begin
          Sense(5, $24);
          Exit;
        end;
        var Start := FDisc.Track(FCDB[4]).StartLBA;
        var Finish := FDisc.LeadOut;
        if FCDB[7] < FDisc.TrackCount then
          Finish := FDisc.Track(FCDB[7] + 1).StartLBA;
        StartAudio(Start, Finish);
      end;
    $4B:
      FPaused := FCDB[8] and 1 = 0;
    $4E:
      FPlaying := False;
  else
    Sense(5, $20);
  end;
  if (FStatus = 0) and ((FLength <> 0) or (FBlocks <> 0)) then
    FPhase := 1;
end;

procedure TS32CD.Mix(var Samples: TArray<SmallInt>);
begin
  for var I := 0 to Length(Samples) div 2 - 1 do
    if FPlaying and not FPaused and (FDisc <> nil) then
    begin
      if FAudioAt = 0 then
      begin
        if FAudioLBA >= FAudioEnd then
        begin
          FPlaying := False;
          FAudioCompleted := True;
          Continue;
        end;
        var Data: TBytes;
        FDisc.ReadAudio(FAudioLBA, Data);
        Move(Data[0], FAudio, SizeOf(FAudio));
      end;
      for var C := 0 to 1 do
      begin
        var At := FAudioAt * 4 + C * 2;
        var Value := SmallInt(Word(FAudio[At]) or (Word(FAudio[At + 1]) shl 8));
        Samples[I * 2 + C] := EnsureRange(Integer(Samples[I * 2 + C]) + Value, -32768, 32767);
      end;
      Inc(FAudioAt);
      if FAudioAt = 588 then
      begin
        FAudioAt := 0;
        Inc(FAudioLBA);
        if FAudioLBA >= FAudioEnd then
        begin
          FPlaying := False;
          FAudioCompleted := True;
        end;
      end;
    end;
end;

procedure TS32CD.SerializeState(State: TStateArchive);
begin
  State.Field(FRegs, SizeOf(FRegs));
  State.Field(FFIFO, SizeOf(FFIFO));
  State.Field(FCDB, SizeOf(FCDB));
  State.Field(FBuffer, SizeOf(FBuffer));
  State.Field(FAudio, SizeOf(FAudio));
  State.Field(FHead, SizeOf(FHead));
  State.Field(FFilled, SizeOf(FFilled));
  State.Field(FCount, SizeOf(FCount));
  State.Field(FPhase, SizeOf(FPhase));
  State.Field(FCDBAt, SizeOf(FCDBAt));
  State.Field(FCDBLength, SizeOf(FCDBLength));
  State.Field(FAt, SizeOf(FAt));
  State.Field(FLength, SizeOf(FLength));
  State.Field(FLBA, SizeOf(FLBA));
  State.Field(FBlocks, SizeOf(FBlocks));
  State.Field(FWriteLength, SizeOf(FWriteLength));
  State.Field(FStatus, SizeOf(FStatus));
  State.Field(FSense, SizeOf(FSense));
  State.Field(FASC, SizeOf(FASC));
  State.Field(FTime, SizeOf(FTime));
  State.Field(FSelectTime, SizeOf(FSelectTime));
  State.Field(FTransfer, SizeOf(FTransfer));
  State.Field(FATN, SizeOf(FATN));
  State.Field(FACK, SizeOf(FACK));
  State.Field(FPlaying, SizeOf(FPlaying));
  State.Field(FPaused, SizeOf(FPaused));
  State.Field(FAudioCompleted, SizeOf(FAudioCompleted));
  State.Field(FAudioLBA, SizeOf(FAudioLBA));
  State.Field(FAudioEnd, SizeOf(FAudioEnd));
  State.Field(FAudioAt, SizeOf(FAudioAt));
  if (FHead < 0) or (FHead > 7) or (FFilled < 0) or (FFilled > 8) or (FCount < 0) or (FCount > $FFFFFF) or
    (FPhase < -1) or (FPhase > 7) or (FAt < 0) or (FLength < 0) or (FAt > FLength) or (FLength > SizeOf(FBuffer)) or
    (FAudioAt < 0) or (FAudioAt >= 588) or (FCDBAt < 0) or (FCDBAt > 16) then
    raise EReadError.Create('Invalid System 32 SCSI state');
end;

function TS32CD.DebugState: string;
begin
  Result := Format('SCSI phase=%d cdb=%.2x ints=%.2x fifo=%d count=%d lba=%d audio=%d cmd=%.2x pctl=%.2x ack=%d', [FPhase, FCDB[0], FRegs[4], FFilled, FCount, FLBA, FAudioLBA, FRegs[2], FRegs[8], Ord(FACK)]);
end;

function TS32CD.Trace: string;
begin
  Result := '';
  for var I := Max(0, FTraceAt - 256) to FTraceAt - 1 do
    Result := Result + IntToHex(FTrace[I and 255], 6) + ' ';
end;

end.

