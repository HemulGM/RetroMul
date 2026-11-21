unit CPS1.PIC;

interface

uses
  System.SysUtils, CPS1.Boards, CPS.Cartridge, HW.PIC16C5x, CPS.EEPROM,
  Core.Snapshots;

type
  TCPSPICConsole = class(TCPS1BoardConsole)
  private
    FPIC: TPIC16C57;
    FSerial: TCPS93C46;
    FPortB, FPortC: Byte;
    FPending: Boolean;
    FCountdown: Integer;
    FSoundPhase: Int64;
    FSprites: TArray<Word>;
    FShared: array[0..$FFF] of Word;
    function ReadPort(Port: Integer): Byte;
    procedure WritePort(Port: Integer; Value: Byte);
  protected
    procedure AdvanceSound(Cycles: Integer); override;
    procedure FinishFrame; override;
  public
    constructor Create(Cart: TCPSCartridge);
    destructor Destroy; override;
    procedure Reset; override;
    function ReadWord(Address: Cardinal): Word; override;
    procedure WriteWord(Address: Cardinal; Value: Word; HighByte: Boolean = True; LowByte: Boolean = True); override;
    procedure SerializeState(State: TStateArchive); override;
    function Battery: TBytes; override;
    procedure LoadBattery(const Data: TBytes); override;
  end;

implementation

constructor TCPSPICConsole.Create(Cart: TCPSCartridge);
begin
  inherited;

  // Restore the skipped initialization in a private, CRC-selected program view.
  // The PIC revisions also need to preserve the full layer word on transfer.
  FProgram := Copy(FProgram);
  if Cart.RomSet.Init = 'init_punipic3' then
  begin
    if (FProgram[$5A6] <> $60) or (FProgram[$5A7] <> $00) or
      (FProgram[$5A8] <> $00) or (FProgram[$5A9] <> $6A) then
      raise ECPSRom.Create('Unrecognized Punisher bootleg set 3 program revision');

    FProgram[$5A6] := $4E;
    FProgram[$5A7] := $71;
    FProgram[$5A8] := $4E;
    FProgram[$5A9] := $71;
  end
  else
  begin
    if (FProgram[$5A8] <> $60) or (FProgram[$5A9] <> $68) or
      (FProgram[$4DF0] <> $0C) or (FProgram[$4DF1] <> $40) then
      raise ECPSRom.Create('Unrecognized Punisher PIC program revision');

    FProgram[$5A8] := $4E;
    FProgram[$5A9] := $71;
    var Patch := TBytes.Create($33, $ED, $DB, $2E, $00, $80, $01, $52, $4E, $75);
    Move(Patch[0], FProgram[$4DF0], Length(Patch));
  end;
  SetLength(FSprites, $2000);
  FSerial := TCPS93C46.Create(8);
  if Cart.HasRegion('pic') then
  begin
    FPIC := TPIC16C57.Create(Cart['pic'], 3750000);
    FPIC.OnReadPort := ReadPort;
    FPIC.OnWritePort := WritePort;
  end;
  FClock := 12000000;
  FZClock := 937500;
  Video.ConfigureBootleg($12, [$14, $16, $08, $0A], $46, 0, $46, $1000, $8000, True);
  Video.BindBootlegSprites(FSprites);
  Reset;
end;

destructor TCPSPICConsole.Destroy;
begin
  FPIC.Free;
  FSerial.Free;
  inherited;
end;

procedure TCPSPICConsole.Reset;
begin
  inherited;
  FPortB := 0;
  FPortC := $FF;
  FPending := False;
  FCountdown := 0;
  FSoundPhase := 0;
  FSoundEnabled := False;
  if Length(FSprites) > 0 then
    FillChar(FSprites[0], Length(FSprites) * SizeOf(Word), 0);
  FillChar(FShared, SizeOf(FShared), 0);
  if FSerial <> nil then
    FSerial.Reset;
  if FPIC <> nil then
    FPIC.Reset;
end;

function TCPSPICConsole.ReadPort(Port: Integer): Byte;
begin
  Result := $FF;
  if Port = 1 then
  begin
    if FPortC and $10 = 0 then
      Result := Result and FCommand;
    if (FPortC and 4 = 0) and (FPortC and 1 = 0) then
      Result := Result and FSound.OKIStatus;
  end;
  if Port = 2 then
    Result := Ord(FPending) shl 6;
end;

procedure TCPSPICConsole.WritePort(Port: Integer; Value: Byte);
begin
  case Port of
    0:
      FSound.SetSampleBank($38000, $8000, (Value and 15) * $8000);
    1:
      FPortB := Value;
    2:
      begin
        if (FPortC and $20 <> 0) and (Value and $20 = 0) then
          FPending := False;
        if (FPortC and 2 <> 0) and (Value and 2 = 0) and (Value and 4 = 0) then
          FSound.WriteOKI(FPortB);
        FPortC := Value;
      end;
  end;
end;

procedure TCPSPICConsole.AdvanceSound(Cycles: Integer);
begin
  if FPIC = nil then
    Exit;

  Inc(FCountdown, Cycles);
  while FCountdown > 0 do
    Dec(FCountdown, FPIC.Step);
  Inc(FSoundPhase, Int64(Cycles) * 3579545);
  FSound.Advance(FSoundPhase div 937500);
  FSoundPhase := FSoundPhase mod 937500;
end;

procedure TCPSPICConsole.FinishFrame;
begin
  FSound.EndFrame;
  Video.Render;
end;

function TCPSPICConsole.ReadWord(Address: Cardinal): Word;
begin
  Address := Address and $FFFFFE;
  if (Address >= $990000) and (Address < $994000) then
    Exit(FSprites[(Address - $990000) div 2]);

  if (Address >= $F18000) and (Address < $F1A000) then
    Exit(FShared[(Address - $F18000) div 2]);

  if Address = $F1C006 then
    Exit(Ord(FSerial.Output));

  Result := inherited;
end;

procedure TCPSPICConsole.WriteWord(Address: Cardinal; Value: Word; HighByte, LowByte: Boolean);

  function Merge(Old: Word): Word;
  begin
    Result := Old;
    if HighByte then
      Result := (Result and $FF) or (Value and $FF00);
    if LowByte then
      Result := (Result and $FF00) or (Value and $FF);
  end;

begin
  Address := Address and $FFFFFE;
  if (Address >= $990000) and (Address < $994000) then
  begin
    var i := (Address - $990000) div 2;
    FSprites[i] := Merge(FSprites[i]);
    Exit;
  end;

  if (Address >= $F18000) and (Address < $F1A000) then
  begin
    var i := (Address - $F18000) div 2;
    FShared[i] := Merge(FShared[i]);
    Exit;
  end;

  if Address = $F1C006 then
  begin
    if LowByte then
      FSerial.Lines(Value and $80 <> 0, Value and $40 <> 0, Value and 1 <> 0);
    Exit;
  end;

  if Address = $800006 then
  begin
    if LowByte then
      FCommand := Byte(Value and $FF)
    else if HighByte then
      FCommand := Byte(Value shr 8);
    FPending := True;
    Exit;
  end;

  if (Address >= $980000) and (Address < $980010) then
  begin
    Video.A[4] := 0;
    case (Address - $980000) div 2 of
      0:
        Video.A[7] := Merge(Video.A[7]);
      1:
        Video.A[6] := Merge(Video.A[6]);
      2:
        begin
          Video.A[9] := Merge(Video.A[9]);
          Video.A[$20 div 2] := Video.A[9];
        end;
      3:
        Video.A[8] := Word((Integer(Value) + $FFC0) and $FFFF);
      4:
        Video.A[11] := Merge(Video.A[11]);
      5:
        Video.A[10] := Merge(Video.A[10]);
      6:
        case Value of
          $14, $54:
            Video.A[2] := $9100;
          $24, $64:
            Video.A[2] := $90C0;
          $3C, $7C:
            Video.A[2] := $9180;
        end;
    end;
    Exit;
  end;

  inherited;
end;

procedure TCPSPICConsole.SerializeState(State: TStateArchive);
begin
  inherited;
  if FPIC <> nil then
    FPIC.SerializeState(State);
  FSerial.SerializeState(State);
  State.Field(FPortB, SizeOf(FPortB));
  State.Field(FPortC, SizeOf(FPortC));
  State.Field(FPending, SizeOf(FPending));
  State.Field(FCountdown, SizeOf(FCountdown));
  State.Field(FSoundPhase, SizeOf(FSoundPhase));
  State.Field(FSprites[0], Length(FSprites) * SizeOf(Word));
  State.Field(FShared, SizeOf(FShared));
  if (FCountdown < -1) or (FCountdown > 0) or (FSoundPhase < 0) or (FSoundPhase >= 937500) then
    raise EArgumentException.Create('Invalid CPS PIC board timing');
end;

function TCPSPICConsole.Battery: TBytes;
begin
  Result := FSerial.Battery;
end;

procedure TCPSPICConsole.LoadBattery(const Data: TBytes);
begin
  FSerial.LoadBattery(Data);
end;

end.

