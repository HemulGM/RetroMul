unit INTV.JLP;

interface

uses
  System.SysUtils, Core.Snapshots;

type
  TIntvJLP = class
  private
    const
      FirstFlashRow = 224;
      RowWords = 96;
      SectorRows = 8;
  private
    FWords: array[$8000..$9FFF] of Word;
    FFlash: TBytes;
    FLocutusRAM: TArray<Word>;
    FEnabled, FEnabledAtReset, FDirty: Boolean;
    FBusyAccesses: Integer;
    FRandom: Cardinal;
    procedure Calculate(Address: Word);
    procedure FlashCommand(Address: Word);
    function GetRAM(Address: Word): Word;
    procedure PutRAM(Address, Value: Word);
  public
    constructor Create(Mode, FlashSectors: Integer; const LocutusRAM: TArray<Word> = nil);
    procedure Reset;
    function ReadWord(Address: Word; out Value: Word): Boolean;
    function WriteWord(Address, Value: Word): Boolean;
    procedure LoadFlash(const Data: TBytes);
    function FlashData: TBytes;
    procedure MarkFlashSaved;
    procedure SerializeState(State: TStateArchive);
    function ExtendedPortsVisible: Boolean;
    function TryPreviousValue(Address: Word; out Value: Word): Boolean;
    function LoadLegacyRegister(Address: Word): Word;
    property Enabled: Boolean read FEnabled;
    property Dirty: Boolean read FDirty;
  end;

implementation

uses
  System.Classes;

constructor TIntvJLP.Create(Mode, FlashSectors: Integer; const LocutusRAM: TArray<Word>);
begin
  inherited Create;
  FLocutusRAM := LocutusRAM;
  if (Mode and 2 <> 0) and (FlashSectors > 0) then
  begin
    SetLength(FFlash, FlashSectors * SectorRows * RowWords * SizeOf(Word));
    FillChar(FFlash[0], Length(FFlash), $FF);
  end;
  FEnabledAtReset := Mode and 1 <> 0;
  FillChar(FWords, SizeOf(FWords), $FF);
  FillChar(FWords[$8040], ($9F9F - $8040 + 1) * SizeOf(Word), 0);
  if Length(FFlash) > 0 then
  begin
    FWords[$8023] := FirstFlashRow;
    FWords[$8024] := FirstFlashRow + Length(FFlash) div (RowWords * SizeOf(Word)) - 1;
  end
  else
  begin
    FWords[$8023] := 0;
    FWords[$8024] := 0;
  end;
  FWords[$802D] := 0;
  FWords[$802E] := 0;
  FWords[$802F] := 0;
  FWords[$9FFF] := 0;
  FRandom := $24485A21;
  Reset;
end;

procedure TIntvJLP.Reset;
begin
  FEnabled := FEnabledAtReset;
  FBusyAccesses := 0;
end;

function TIntvJLP.ReadWord(Address: Word; out Value: Word): Boolean;
begin
  Result := FEnabled;
  if not Result then
    Exit;
  Value := $FFFF;
  if FBusyAccesses > 0 then
  begin
    Dec(FBusyAccesses);
    Exit;
  end;
  if Address = $9FFE then
  begin
    FRandom := FRandom xor (FRandom shl 13);
    FRandom := FRandom xor (FRandom shr 17);
    FRandom := FRandom xor (FRandom shl 5);
    Value := Word(FRandom shr 16);
  end
  else if (Address >= $8040) and (Address <= $9F7F) then
    Value := GetRAM(Address)
  else
    Value := FWords[Address];
end;

function TIntvJLP.GetRAM(Address: Word): Word;
begin
  if FLocutusRAM <> nil then
    Result := FLocutusRAM[$8000 + Address]
  else
    Result := FWords[Address];
end;

procedure TIntvJLP.PutRAM(Address, Value: Word);
begin
  if FLocutusRAM <> nil then
    FLocutusRAM[$8000 + Address] := Value
  else
    FWords[Address] := Value;
end;

procedure TIntvJLP.Calculate(Address: Word);
begin
  var Pair := Address and $FFFE;
  var Left: Int64 := FWords[Pair];
  var Right: Int64 := FWords[Pair + 1];
  if (Pair = $9F80) or (Pair = $9F82) or (Pair = $9F88) then
    Left := SmallInt(Word(Left));
  if (Pair = $9F80) or (Pair = $9F84) or (Pair = $9F88) then
    Right := SmallInt(Word(Right));

  if Pair < $9F88 then
  begin
    var Product := Cardinal(Left * Right);
    FWords[$9F8E] := Word(Product);
    FWords[$9F8F] := Word(Product shr 16);
  end
  else if Right <> 0 then
  begin
    FWords[$9F8E] := Word(Left div Right);
    FWords[$9F8F] := Word(Left mod Right);
  end;
end;

procedure TIntvJLP.FlashCommand(Address: Word);
begin
  case Address of
    $802D:
      FBusyAccesses := 500;
    $802E:
      FBusyAccesses := 20;
    $802F:
      FBusyAccesses := 900;
  end;
  if (Length(FFlash) = 0) or (FWords[$8026] < FWords[$8023]) or
    (FWords[$8026] > FWords[$8024]) then
    Exit;
  var Row := FWords[$8026] - FirstFlashRow;
  var Offset := Row * RowWords * SizeOf(Word);
  if Address = $802F then
  begin
    Offset := (Row div SectorRows) * SectorRows * RowWords * SizeOf(Word);
    FillChar(FFlash[Offset], SectorRows * RowWords * SizeOf(Word), $FF);
    FDirty := True;
    Exit;
  end;
  var Start := Integer(FWords[$8025]);
  if (Start < $8040) or (Start > $9F7F - RowWords + 1) then
    Exit;
  if Address = $802D then
  begin
    for var Index := Offset to Offset + RowWords * SizeOf(Word) - 1 do
      if FFlash[Index] <> $FF then
        Exit;
    for var Index := 0 to RowWords - 1 do
    begin
      var Value := GetRAM(Start + Index);
      FFlash[Offset + Index * 2] := Byte(Value);
      FFlash[Offset + Index * 2 + 1] := Byte(Value shr 8);
    end;
    FDirty := True;
  end
  else
    for var Index := 0 to RowWords - 1 do
      PutRAM(Start + Index, FFlash[Offset + Index * 2] or (FFlash[Offset + Index * 2 + 1] shl 8));
end;

function TIntvJLP.WriteWord(Address, Value: Word): Boolean;
begin
  if FBusyAccesses > 0 then
  begin
    Dec(FBusyAccesses);
    Exit(True);
  end;
  if not FEnabled then
  begin
    Result := (Address = $8033) and (Value = $4A5A);
    FEnabled := Result;
    Exit;
  end;

  Result := True;
  case Address of
    $8040..$9F7F:
      PutRAM(Address, Value);
    $8025, $8026, $9F90..$9F9F, $9FFD:
      FWords[Address] := Value;
    $802D:
      if Value = $C0DE then
        FlashCommand(Address);
    $802E:
      if Value = $DEC0 then
        FlashCommand(Address);
    $802F:
      if Value = $BEEF then
        FlashCommand(Address);
    $8034:
      if Value = $6A7A then
        FEnabled := False;
    $9F80..$9F8B:
      begin
        FWords[Address] := Value;
        Calculate(Address);
      end;
    $9FFC:
      begin
        var CRC := FWords[$9FFD] xor Value;
        for var Bit := 0 to 15 do
          if CRC and 1 <> 0 then
            CRC := (CRC shr 1) xor $AD52
          else
            CRC := CRC shr 1;
        FWords[$9FFD] := CRC;
      end;
  end;
end;

procedure TIntvJLP.LoadFlash(const Data: TBytes);
begin
  if Length(Data) <> Length(FFlash) then
    raise EReadError.Create('Intellivision JLP flash image size differs from the cartridge');
  FFlash := Copy(Data);
  FDirty := False;
end;

function TIntvJLP.FlashData: TBytes;
begin
  Result := Copy(FFlash);
end;

procedure TIntvJLP.MarkFlashSaved;
begin
  FDirty := False;
end;

function TIntvJLP.ExtendedPortsVisible: Boolean;
begin
  Result := FEnabled and (FBusyAccesses = 0);
end;

function TIntvJLP.TryPreviousValue(Address: Word; out Value: Word): Boolean;
begin
  Result := ExtendedPortsVisible and (Address >= $8040) and (Address <= $9F7F);
  if Result then
    Value := GetRAM(Address);
end;

function TIntvJLP.LoadLegacyRegister(Address: Word): Word;
begin
  Result := FWords[Address];
end;

procedure TIntvJLP.SerializeState(State: TStateArchive);
begin
  // Flash is persistent media. Snapshot restore only affects the volatile state.
  State.Field(FWords[$8025], 2 * SizeOf(Word));
  if FLocutusRAM = nil then
    State.Field(FWords[$8040], ($9F9F - $8040 + 1) * SizeOf(Word))
  else
    State.Field(FWords[$9F80], ($9F9F - $9F80 + 1) * SizeOf(Word));
  State.Field(FWords[$9FFD], SizeOf(Word));
  State.Field(FEnabled, SizeOf(FEnabled));
  State.Field(FBusyAccesses, SizeOf(FBusyAccesses));
  State.Field(FRandom, SizeOf(FRandom));
  if (FBusyAccesses < 0) or (FBusyAccesses > 900) then
    raise EReadError.Create('Invalid JLP flash timing in Intellivision snapshot');
end;

end.

