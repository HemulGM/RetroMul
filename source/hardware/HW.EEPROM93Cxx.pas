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
    FAddressBits, FDataBits, FAddress, FOperation, FBits, FReadBit: Integer;
    FShift: Cardinal;
    FSelected, FClock, FOutput, FEnabled: Boolean;
    function Cell(Address: Integer): Word;
    procedure SetCell(Address: Integer; Value: Word);
  public
    constructor Create(Size: Integer = 128; DataBits: Integer = 16);
    procedure Reset;
    procedure Lines(Selected, Clock, Data: Boolean);
    procedure SerializeState(State: TStateArchive);
    function Battery: TBytes;
    procedure LoadBattery(const Data: TBytes);
    property Output: Boolean read FOutput;
    property Dirty: Boolean read FDirty;
  end;

implementation

constructor TSerialEEPROM93Cxx.Create(Size, DataBits: Integer);
begin
  inherited Create;
  if not (DataBits in [8, 16]) then
    raise EArgumentException.Create('Invalid Microwire organization');

  FDataBits := DataBits;
  if (Size < 128) or (Size > 2048) or (Size and (Size - 1) <> 0) then
    raise EArgumentException.Create('Invalid Microwire capacity');
  FAddressBits := 0;
  var Cells := Size div (DataBits div 8);
  while Cells > 1 do
  begin
    Inc(FAddressBits);
    Cells := Cells shr 1;
  end;
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

procedure TSerialEEPROM93Cxx.Lines(Selected, Clock, Data: Boolean);
begin
  if not Selected then
  begin
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
        FAddress := (FAddress + 1) and ((1 shl FAddressBits) - 1);
        FReadBit := FDataBits - 1;
      end;
      FOutput := Cell(FAddress) and (1 shl FReadBit) <> 0;
      Dec(FReadBit);
    end
    else if ((FBits <> 0) or Data) and (FBits < FAddressBits + 3 + FDataBits) then
    begin
      FShift := (FShift shl 1) or Cardinal(Ord(Data));
      Inc(FBits);
      if FBits = FAddressBits + 3 then
      begin
        FAddress := FShift and ((1 shl FAddressBits) - 1);
        FOperation := (FShift shr FAddressBits) and 3;
        case FOperation of
          2:
            begin
              FReadBit := FDataBits - 1;
              FOutput := False;
            end;
          3:
            if FEnabled then
              SetCell(FAddress, $FFFF);
          0:
            case FAddress shr (FAddressBits - 2) of
              0:
                FEnabled := False;
              3:
                FEnabled := True;
              2:
                if FEnabled then
                  for var I := 0 to (1 shl FAddressBits) - 1 do
                    SetCell(I, $FFFF);
            end;
        end;
      end;
      if (FBits = FAddressBits + 3 + FDataBits) and FEnabled then
      begin
        if FOperation = 1 then
          SetCell(FAddress, Word(FShift and $FFFF))
        else if (FOperation = 0) and (FAddress shr (FAddressBits - 2) = 1) then
          for var I := 0 to (1 shl FAddressBits) - 1 do
            SetCell(I, Word(FShift and $FFFF));
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
  if State.Loading then
    FDirty := True;

  if (FAddress < 0) or (FAddress >= (1 shl FAddressBits)) or (FOperation < 0) or (FOperation > 3) or
    (FBits < 0) or (FBits > FAddressBits + 3 + FDataBits) or (FReadBit < -1) or (FReadBit >= FDataBits) then
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

