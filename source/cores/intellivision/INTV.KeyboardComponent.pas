unit INTV.KeyboardComponent;

interface

uses
  System.SysUtils, System.UITypes, Core.Input.Keyboard, Core.Snapshots, NES.CPU,
  INTV.KeyboardPeripherals;

type
  TIntvKeyboardFirmware = record
    MasterROM, KeyboardROM, CharacterROM, CartridgeROM: TBytes;
  end;

  TIntvKeyboardMatrix = array[0..9] of Byte;

  TIntvKeyboardComponent = class
  private
    const
      TextWidth = 320;
      TextHeight = 192;
      RowStride = 64;
  private
    FCPU: TCPU6502;
    FPeripherals: TIntvKeyboardPeripherals;
    FMasterROM: array[0..$FFF] of Word;
    FKeyboardROM, FCharacterROM, FKeyboardCart: TBytes;
    FShared: array[0..$3FFF] of Word;
    FVRAM: array[0..$7FF] of Byte;
    FControl: array[0..6] of Byte;
    FMatrix: TIntvKeyboardMatrix;
    FSelector, FTop, FCursorColumn, FCursorRow: Byte;
    FVideoEnabled, FTimingStarted, FClockIRQ: Boolean;
    procedure UpdateIRQ;
    function ReadIO(Address: Word): Byte;
    procedure WriteIO(Address: Word; Value: Byte);
    function ReadCRT(RegisterIndex: Integer): Byte;
    procedure WriteCRT(RegisterIndex: Integer; Value: Byte);
    procedure CommandCRT(RegisterIndex: Integer);
    function RowCount: Integer; inline;
  public
    constructor Create(const MasterROM, KeyboardROM, CharacterROM: TBytes; const KeyboardCart: TBytes = nil; Clock: Integer = 894886);
    destructor Destroy; override;
    procedure Reset;
    procedure Advance(Cycles: Integer);
    procedure VBlank;
    procedure SetInput(const Keys: THostKeyboardKeys);
    procedure SerializeState(State: TStateArchive);
    function ReadMaster(Address: Word): Word;
    procedure WriteMaster(Address, Value: Word);
    function ReadKeyboard(Address: Word): Byte;
    procedure WriteKeyboard(Address: Word; Value: Byte);
    procedure Overlay(const Pixels: TArray<TAlphaColor>);
    property Peripherals: TIntvKeyboardPeripherals read FPeripherals;
  end;

implementation

uses
  System.Classes, System.Math;

constructor TIntvKeyboardComponent.Create(const MasterROM, KeyboardROM, CharacterROM: TBytes; const KeyboardCart: TBytes; Clock: Integer);
begin
  inherited Create;
  if (Length(MasterROM) <> $2000) or (Length(KeyboardROM) <> $2000) or
    (Length(CharacterROM) <> $800) or ((KeyboardCart <> nil) and (Length(KeyboardCart) <> $2000)) then
    raise EReadError.Create('Invalid Keyboard Component ROM size');
  for var Index := 0 to High(FMasterROM) do
    FMasterROM[Index] := (MasterROM[Index * 2] shl 8) or MasterROM[Index * 2 + 1];
  FKeyboardROM := KeyboardROM;
  FCharacterROM := CharacterROM;
  FKeyboardCart := KeyboardCart;
  FPeripherals := TIntvKeyboardPeripherals.Create(Clock);
  FCPU := TCPU6502.Create;
  FCPU.DecimalArithmeticEnabled := True;
  FCPU.Connect(ReadKeyboard, WriteKeyboard);
  Reset;
end;

destructor TIntvKeyboardComponent.Destroy;
begin
  FCPU.Free;
  FPeripherals.Free;
  inherited;
end;

procedure TIntvKeyboardComponent.Reset;
begin
  FillChar(FShared, SizeOf(FShared), 0);
  FillChar(FVRAM, SizeOf(FVRAM), 0);
  FillChar(FControl, SizeOf(FControl), 0);
  FillChar(FMatrix, SizeOf(FMatrix), $FF);
  FSelector := 0;
  FTop := 0;
  FCursorColumn := 0;
  FCursorRow := 0;
  FVideoEnabled := False;
  FTimingStarted := False;
  FClockIRQ := False;
  FPeripherals.Reset;
  FCPU.Reset;
  FCPU.SetIrqLine(False);
end;

procedure TIntvKeyboardComponent.Advance(Cycles: Integer);
begin
  for var Cycle := 1 to Cycles do
  begin
    var PeripheralIRQ := FPeripherals.IRQ;
    FPeripherals.Clock;
    if PeripheralIRQ <> FPeripherals.IRQ then
      UpdateIRQ;
    FCPU.Clock;
  end;
end;

procedure TIntvKeyboardComponent.VBlank;
begin
  FClockIRQ := True;
  UpdateIRQ;
end;

procedure TIntvKeyboardComponent.UpdateIRQ;
begin
  FCPU.SetIrqLine(FClockIRQ or FPeripherals.IRQ);
end;

procedure TIntvKeyboardComponent.SetInput(const Keys: THostKeyboardKeys);
const
  // Each row is indexed by the selector at $4044-$4047. Zero denotes an unconnected switch.
  KeyCodes: array[0..9, 0..7] of Byte = (
    (vkShift, vkControl, 0, 0, 0, 0, 0, 0),
    (vkF2, vkF1, 0, 0, 0, 0, 0, 0),
    (vkSpace, 0, vkX, vkV, vkN, $BC, $BF, 0),
    (vkMenu, 0, vkZ, vkC, vkB, vkM, $BE, vkRight),
    (vkTab, 0, vkS, vkF, vkH, vkK, $BA, vkDown),
    (vkQ, 0, vkW, vkR, vkY, vkI, vkP, $DD),
    (vk1, 0, vk3, vk5, vk7, vk9, $BD, vkUp),
    ($DB, 0, vk2, vk4, vk6, vk8, vk0, $BB),
    (vkEscape, 0, vkE, vkT, vkU, vkO, vkLeft, vkReturn),
    (vkA, 0, vkD, vkG, vkJ, vkL, $DE, vkBack));
begin
  FillChar(FMatrix, SizeOf(FMatrix), $FF);
  for var Row := Low(FMatrix) to High(FMatrix) do
    for var Column := 0 to 7 do
    begin
      var Key := KeyCodes[Row, Column];
      if (Key <> 0) and Keys[Key] then
        FMatrix[Row] := FMatrix[Row] and not (1 shl Column);
    end;
end;

procedure TIntvKeyboardComponent.SerializeState(State: TStateArchive);
const
  CPUStateLayout = 10;
begin
  State.Field(FShared, SizeOf(FShared));
  State.Field(FVRAM, SizeOf(FVRAM));
  State.Field(FControl, SizeOf(FControl));
  State.Field(FSelector, SizeOf(FSelector));
  State.Field(FTop, SizeOf(FTop));
  State.Field(FCursorColumn, SizeOf(FCursorColumn));
  State.Field(FCursorRow, SizeOf(FCursorRow));
  State.Field(FVideoEnabled, SizeOf(FVideoEnabled));
  State.Field(FTimingStarted, SizeOf(FTimingStarted));
  State.Field(FClockIRQ, SizeOf(FClockIRQ));
  FCPU.SerializeStateFields(State.Field, State.Loading, CPUStateLayout);
  if (State.Version = 0) or (State.Version >= 5) then
    FPeripherals.SerializeState(State)
  else if State.Loading then
    FPeripherals.Reset;
  if State.Loading then
  begin
    if (FSelector > 15) or (FTop > 63) or (FCursorRow > 63) then
      raise EReadError.Create('Invalid Keyboard Component register state');
    UpdateIRQ;
  end;
end;

function TIntvKeyboardComponent.ReadMaster(Address: Word): Word;
begin
  case Address of
    $7000..$7FFF:
      Result := FMasterROM[Address and $FFF] and $3FF;
    $8000..$BFFF:
      Result := FShared[Address - $8000];
  else
    Result := $FFFF;
  end;
end;

procedure TIntvKeyboardComponent.WriteMaster(Address, Value: Word);
begin
  if (Address >= $8000) and (Address <= $BFFF) then
    FShared[Address - $8000] := Value and $3FF;
end;

function TIntvKeyboardComponent.ReadKeyboard(Address: Word): Byte;
begin
  case Address of
    $0000..$3FFF:
      Result := Byte(FShared[Address]);
    $4000..$40BF:
      Result := ReadIO(Address);
    $40C0..$40CF:
      Result := ReadCRT(Address and $F);
    $4200..$7FFF:
      Result := FShared[Address and $3FFF] shr 8;
    $B7FE:
      Result := FPeripherals.ReadPrinter;
    $B800..$BFFF:
      Result := FVRAM[Address and $7FF];
    $C000..$DFFF:
      Result := FKeyboardROM[Address and $1FFF];
    $E000..$FFFF:
      if FKeyboardCart <> nil then
        Result := FKeyboardCart[Address and $1FFF]
      else
        Result := FKeyboardROM[Address and $1FFF];
  else
    Result := $FF;
  end;
end;

procedure TIntvKeyboardComponent.WriteKeyboard(Address: Word; Value: Byte);
begin
  case Address of
    $0000..$3FFF:
      FShared[Address] := (FShared[Address] and $300) or Value;
    $4000..$40BF:
      WriteIO(Address, Value);
    $40C0..$40CF:
      WriteCRT(Address and $F, Value);
    $4200..$7FFF:
      begin
        var Index := Address and $3FFF;
        FShared[Index] := (FShared[Index] and $FF) or ((Value and 3) shl 8);
      end;
    $B7FE..$B7FF:
      begin
        FPeripherals.WritePrinter(Address, Value);
        UpdateIRQ;
      end;
    $B800..$BFFF:
      FVRAM[Address and $7FF] := Value;
  end;
end;

function TIntvKeyboardComponent.ReadIO(Address: Word): Byte;
begin
  Result := 0;
  case Address of
    $4000..$4005, $4007:
      Result := FPeripherals.ReadTape(Address);
    $4006:
      Result := Ord(not FClockIRQ) shl 7;
    $4060:
      if FSelector <= High(FMatrix) then
        Result := FMatrix[FSelector]
      else
        Result := $FF;
    $4080, $40A0:
      WriteIO(Address, 0);
  end;
end;

procedure TIntvKeyboardComponent.WriteIO(Address: Word; Value: Byte);
begin
  case Address of
    $4020..$4027, $4040..$4042, $4080:
      begin
        FPeripherals.WriteTape(Address, Value);
        UpdateIRQ;
      end;
    $4043:
      FVideoEnabled := Value and 1 <> 0;
    $4044..$4047:
      begin
        var Shift := Address - $4044;
        FSelector := (FSelector and not (1 shl Shift)) or ((Value and 1) shl Shift);
      end;
    $40A0:
      begin
        FClockIRQ := False;
        UpdateIRQ;
      end;
  end;
end;

function TIntvKeyboardComponent.RowCount: Integer;
begin
  Result := (FControl[3] and $3F) + 1;
end;

function TIntvKeyboardComponent.ReadCRT(RegisterIndex: Integer): Byte;
begin
  Result := $FF;
  case RegisterIndex of
    8:
      Result := FCursorColumn;
    9:
      Result := FCursorRow;
    $A, $B, $E:
      CommandCRT(RegisterIndex);
  end;
end;

procedure TIntvKeyboardComponent.WriteCRT(RegisterIndex: Integer; Value: Byte);
begin
  case RegisterIndex of
    0..6:
      begin
        FControl[RegisterIndex] := Value;
        if RegisterIndex = 6 then
          FTop := ((Value and $3F) + 1) mod RowCount;
      end;
    $C:
      FCursorColumn := Value;
    $D:
      FCursorRow := Value and $3F;
    $A, $B, $E:
      CommandCRT(RegisterIndex);
  end;
end;

procedure TIntvKeyboardComponent.CommandCRT(RegisterIndex: Integer);
begin
  case RegisterIndex of
    $A:
      FTimingStarted := False;
    $B:
      FTop := (FTop + 1) mod RowCount;
    $E:
      FTimingStarted := True;
  end;
end;

procedure TIntvKeyboardComponent.Overlay(const Pixels: TArray<TAlphaColor>);
const
  ColumnCounts: array[0..7] of Integer = (20, 32, 40, 64, 72, 80, 96, 132);
begin
  if not FVideoEnabled or not FTimingStarted then
    Exit;
  if Length(Pixels) <> TextWidth * TextHeight then
    raise EArgumentException.Create('Invalid Keyboard Component display surface');
  var Columns := Min(TextWidth div 8, ColumnCounts[FControl[2] and 7]);
  var Scans := (FControl[2] shr 3 and $F) + 1;
  for var Y := 0 to Min(TextHeight, Scans * RowCount) - 1 do
  begin
    var Row := (Y div Scans + FTop) mod RowCount;
    var GlyphY := Y mod Scans;
    for var Column := 0 to Columns - 1 do
    begin
      var Pattern := 0;
      if (Row = FCursorRow) and (Column + 1 = FCursorColumn) then
        Pattern := $FF
      else if GlyphY < 8 then
        Pattern := FCharacterROM[FVRAM[(Row * RowStride + Column) and $7FF] * 8 + GlyphY];
      for var Dot := 0 to 7 do
        if Pattern and ($80 shr Dot) <> 0 then
          Pixels[Y * TextWidth + Column * 8 + Dot] := $FFFFFFFF;
    end;
  end;
end;

end.

