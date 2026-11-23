unit HW.EEPROM93Cxx;

interface

// Shared Microwire engine, generalized from RetroMul's CPS 93C46.
// Capacity is in bytes; battery files retain little-endian 16-bit cells.
uses
  System.SysUtils, Core.Snapshots;

type
  TSerialEEPROM93Cxx = class
  private
    FData: TBytes;
    FDirty: Boolean;
    FAddressBits, FCommandAddressBits, FDataBits, FAddress, FOperation, FBits, FReadBit: Integer;
    FShift: Cardinal;
    FSelected, FClock, FOutput, FEnabled: Boolean;
    FSequentialRead: Boolean;
    FICT93C46A, F93LC46B, FProgrammingPending, FStatusPolling: Boolean;
    FClockHz, FWriteUS, FEraseUS, FAllUS: Integer;
    FTime, FBusyUntil: Int64;
    function Cell(Address: Integer): Word;
    procedure SetCell(Address: Integer; Value: Word);
    function GetOutput: Boolean;
    procedure StartProgramming(Microseconds: Integer);
    procedure CommitProgramming;
    function GetOutputDriven: Boolean;
  public
    constructor Create(Size: Integer = 128; DataBits: Integer = 16; SequentialRead: Boolean = True; ExtraAddressBit: Boolean = False);
    // ICT 1990 databook pp.2-8..2-12: autoerase WRITE, five commands,
    // programming starts on CS falling. PE defaults high through its internal pull-up.
    procedure ConfigureICT93C46A;
    procedure Configure93LC46B;
    procedure Reset;
    procedure Lines(Selected, Clock, Data: Boolean);
    // Opt in per board. Untimed users retain their API and snapshot layout.
    procedure ConfigureTiming(ClockHz, WriteUS, EraseUS, AllUS: Integer);
    procedure RunUntil(Time: Int64);
    procedure SerializeState(State: TStateArchive);
    function Battery: TBytes;
    procedure LoadBattery(const Data: TBytes);
    property Output: Boolean read GetOutput;
    property OutputDriven: Boolean read GetOutputDriven;
    property Dirty: Boolean read FDirty;
  end;

implementation

constructor TSerialEEPROM93Cxx.Create(Size, DataBits: Integer; SequentialRead, ExtraAddressBit: Boolean);
begin
  inherited Create;
  if not (DataBits in [8, 16]) then
    raise EArgumentException.Create('Invalid Microwire organization');

  FDataBits := DataBits;
  FSequentialRead := SequentialRead;
  if (Size < 128) or (Size > 2048) or (Size and (Size - 1) <> 0) then
    raise EArgumentException.Create('Invalid Microwire capacity');
  FAddressBits := 0;
  var Cells := Size div (DataBits div 8);
  while Cells > 1 do
  begin
    Inc(FAddressBits);
    Cells := Cells shr 1;
  end;
  FCommandAddressBits := FAddressBits + Ord(ExtraAddressBit);
  SetLength(FData, Size);
  FillChar(FData[0], Size, $FF);
  Reset;
end;

function TSerialEEPROM93Cxx.Cell(Address: Integer): Word;
begin
  if FDataBits = 8 then
    Exit(FData[Address]);

  Result := Word(FData[Address * 2]) or (Word(FData[Address * 2 + 1]) shl 8);
end;

procedure TSerialEEPROM93Cxx.SetCell(Address: Integer; Value: Word);
begin
  if Cell(Address) <> (Value and ((1 shl FDataBits) - 1)) then
    FDirty := True;
  if FDataBits = 8 then
    FData[Address] := Byte(Value and $FF)
  else
  begin
    FData[Address * 2] := Byte(Value and $FF);
    FData[Address * 2 + 1] := Byte(Value shr 8);
  end;
end;

procedure TSerialEEPROM93Cxx.Reset;
begin
  FProgrammingPending := False;
  FStatusPolling := False;
  FTime := 0;
  FBusyUntil := 0;
  FSelected := False;
  FClock := False;
  FOutput := True;
  FEnabled := False;
  FAddress := 0;
  FOperation := 0;
  FBits := 0;
  FReadBit := -1;
  FShift := 0;
end;

procedure TSerialEEPROM93Cxx.ConfigureTiming(ClockHz, WriteUS, EraseUS, AllUS: Integer);
begin
  if (ClockHz <= 0) or (WriteUS <= 0) or (EraseUS <= 0) or (AllUS <= 0) then
    raise EArgumentException.Create('Invalid Microwire timing');
  FClockHz := ClockHz;
  FWriteUS := WriteUS;
  FEraseUS := EraseUS;
  FAllUS := AllUS;
end;

procedure TSerialEEPROM93Cxx.ConfigureICT93C46A;
begin
  if (Length(FData) <> 128) or (FDataBits <> 16) then
    raise EArgumentException.Create('ICT 93C46A requires 64 x 16 organization');
  FICT93C46A := True;
  FSequentialRead := False;
end;

procedure TSerialEEPROM93Cxx.Configure93LC46B;
begin
  if (Length(FData) <> 128) or (FDataBits <> 16) or (FCommandAddressBits <> 6) then
    raise EArgumentException.Create('93LC46B requires 64 x 16 organization');
  F93LC46B := True;
  FSequentialRead := True;
end;

procedure TSerialEEPROM93Cxx.CommitProgramming;
begin
  // CS falling starts the self-timed operation.
  case FOperation of
    1:
      begin
        SetCell(FAddress, Word(FShift and $FFFF));
        StartProgramming(FWriteUS);
      end;
    3:
      begin
        SetCell(FAddress, $FFFF);
        StartProgramming(FEraseUS);
      end;
  else
    begin
      var CellValue: Word := $FFFF;
      if FAddress shr (FAddressBits - 2) = 1 then
        CellValue := Word(FShift and $FFFF);
      for var I := 0 to (1 shl FAddressBits) - 1 do
        SetCell(I, CellValue);
      StartProgramming(FAllUS);
    end;
  end;
  FProgrammingPending := False;
  FStatusPolling := F93LC46B;
end;

procedure TSerialEEPROM93Cxx.RunUntil(Time: Int64);
begin
  if Time < FTime then
    raise EArgumentException.Create('Microwire clock moved backwards');
  FTime := Time;
end;

procedure TSerialEEPROM93Cxx.StartProgramming(Microseconds: Integer);
begin
  if FClockHz > 0 then
    FBusyUntil := FTime + (Int64(FClockHz) * Microseconds + 999999) div 1000000;
end;

function TSerialEEPROM93Cxx.GetOutput: Boolean;
begin
  // DO reports ready/busy after CS is raised to poll a completed command.
  // While CS is low the board's pull-up supplies the inactive level.
  if FSelected and (FBits = 0) then
    Exit(FTime >= FBusyUntil);
  Result := FOutput;
end;

function TSerialEEPROM93Cxx.GetOutputDriven: Boolean;
begin
  Result := FSelected and ((FOperation = 2) or ((FBits = 0) and FStatusPolling));
end;

procedure TSerialEEPROM93Cxx.Lines(Selected, Clock, Data: Boolean);
begin
  if not Selected then
  begin
    if FProgrammingPending then
      CommitProgramming;
    FBits := 0;
    FShift := 0;
    FOperation := 0;
    FReadBit := -1;
    FOutput := True;
  end
  else if FSelected and Clock and not FClock then
  begin
    if FOperation = 2 then
    begin
      if FReadBit < 0 then
      begin
        // Original 93C46: the clock following D0 releases DO (DS11179C,
        // section 3.4). Enhanced variants may stream subsequent cells.
        if not FSequentialRead then
        begin
          FOutput := True;
          FSelected := Selected;
          FClock := Clock;
          Exit;
        end;
        FAddress := (FAddress + 1) and ((1 shl FAddressBits) - 1);
        FReadBit := FDataBits - 1;
      end;
      FOutput := Cell(FAddress) and (1 shl FReadBit) <> 0;
      Dec(FReadBit);
    end
    else if ((FBits < FCommandAddressBits + 3) or (FOperation = 1) or
      ((FOperation = 0) and (FAddress shr (FAddressBits - 2) = 1))) and
      ((FBits <> 0) or (Data and (FTime >= FBusyUntil))) and
      (FBits < FCommandAddressBits + 3 + FDataBits) then
    begin
      if FBits = 0 then
        FStatusPolling := False;
      FShift := (FShift shl 1) or Cardinal(Ord(Data));
      Inc(FBits);
      if FBits = FCommandAddressBits + 3 then
      begin
        FOperation := (FShift shr FCommandAddressBits) and 3;
        // Opcode 00 decodes the top two command bits. Other opcodes use the cell address.
        var CommandShift := (FCommandAddressBits - FAddressBits) * Ord(FOperation = 0);
        FAddress := (FShift shr CommandShift) and ((1 shl FAddressBits) - 1);
        case FOperation of
          2:
            begin
              FReadBit := FDataBits - 1;
              FOutput := False;
            end;
          3:
            if FEnabled and not FICT93C46A then
              if F93LC46B then
                FProgrammingPending := True
              else
              begin
                SetCell(FAddress, $FFFF);
                StartProgramming(FEraseUS);
              end;
          0:
            case FAddress shr (FAddressBits - 2) of
              0:
                FEnabled := False;
              3:
                FEnabled := True;
              2:
                if FEnabled and not FICT93C46A then
                  if F93LC46B then
                    FProgrammingPending := True
                  else
                  begin
                    for var I := 0 to (1 shl FAddressBits) - 1 do
                      SetCell(I, $FFFF);
                    StartProgramming(FAllUS);
                  end;
            end;
        end;
      end;
      if (FBits = FCommandAddressBits + 3 + FDataBits) and FEnabled then
      begin
        if FICT93C46A or F93LC46B then
        begin
          if (FOperation = 1) or
            ((FOperation = 0) and (FAddress shr (FAddressBits - 2) = 1)) then
            FProgrammingPending := True;
        end
        else if FOperation = 1 then
        begin
          SetCell(FAddress, Word(FShift and $FFFF));
          StartProgramming(FWriteUS);
        end
        else if (FOperation = 0) and (FAddress shr (FAddressBits - 2) = 1) then
        begin
          for var I := 0 to (1 shl FAddressBits) - 1 do
            // WRAL requires an earlier ERAL; programming cannot set a
            // discharged bit back to one (DS11179C, section 3.9).
            SetCell(I, Cell(I) and Word(FShift and $FFFF));
          StartProgramming(FAllUS);
        end;
      end;
    end;
  end;
  FSelected := Selected;
  FClock := Clock;
end;

procedure TSerialEEPROM93Cxx.SerializeState(State: TStateArchive);
begin
  State.Field(FData[0], Length(FData));
  State.Field(FAddress, SizeOf(FAddress));
  State.Field(FOperation, SizeOf(FOperation));
  State.Field(FBits, SizeOf(FBits));
  State.Field(FReadBit, SizeOf(FReadBit));
  State.Field(FShift, SizeOf(FShift));
  State.Field(FSelected, SizeOf(FSelected));
  State.Field(FClock, SizeOf(FClock));
  State.Field(FOutput, SizeOf(FOutput));
  State.Field(FEnabled, SizeOf(FEnabled));
  if FClockHz > 0 then
  begin
    State.Field(FTime, SizeOf(FTime));
    State.Field(FBusyUntil, SizeOf(FBusyUntil));
    if (FTime < 0) or (FBusyUntil < 0) then
      raise EArgumentException.Create('Invalid Microwire clock state');
  end;
  if FICT93C46A or F93LC46B then
  begin
    State.Field(FProgrammingPending, SizeOf(FProgrammingPending));
    if FProgrammingPending then
    begin
      var SpecialCommand := FAddress shr (FAddressBits - 2);
      var HasData := (FOperation = 1) or ((FOperation = 0) and (SpecialCommand = 1));
      var Erases := F93LC46B and ((FOperation = 3) or ((FOperation = 0) and (SpecialCommand = 2)));
      if not FSelected or not FEnabled or not (HasData or Erases) or
        (FBits <> FCommandAddressBits + 3 + Ord(HasData) * FDataBits) then
        raise EArgumentException.Create('Invalid pending Microwire programming state');
    end;
  end;
  if F93LC46B then
    State.Field(FStatusPolling, SizeOf(FStatusPolling));
  if State.Loading then
    FDirty := True;

  if (FAddress < 0) or (FAddress >= (1 shl FAddressBits)) or (FOperation < 0) or (FOperation > 3) or
    (FBits < 0) or (FBits > FCommandAddressBits + 3 + FDataBits) or (FReadBit < -1) or (FReadBit >= FDataBits) then
    raise EArgumentException.Create('Invalid Microwire state');
end;

function TSerialEEPROM93Cxx.Battery: TBytes;
begin
  Result := Copy(FData);
end;

procedure TSerialEEPROM93Cxx.LoadBattery(const Data: TBytes);
begin
  if Length(Data) <> Length(FData) then
    raise EArgumentException.Create('Invalid Microwire battery');

  FData := Copy(Data);
  FDirty := False;
end;

end.

