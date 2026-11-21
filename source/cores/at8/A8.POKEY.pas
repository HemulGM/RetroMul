unit A8.POKEY;

interface

uses
  A5200.POKEY, A8.Media, Core.Snapshots;

type
  TA8Pots = array[0..7] of Byte;

  TA8POKEY = class(TA5200POKEY)
  private
    FKeyInput: Word;
    FBreakDown: Boolean;
  protected
    procedure ScanKeys; override;
  public
    procedure Reset; override;
    procedure ClockComputer(Media: TA8Media; TapeMotor: Boolean; ClockHz: Integer);
    function ReadComputer(Index: Byte): Byte;
    procedure WriteComputer(Index, Value: Byte);
    procedure SetKeyboard(Keys: Word);
    procedure StartPotScan(const Pots: TA8Pots);
    procedure SerializeComputer(State: TStateArchive);
  end;

const
  A8NoKey = $FF;
  A8Shift = $100;
  A8Break = $200;

implementation

uses
  System.Math;

procedure TA8POKEY.Reset;
begin
  inherited;
  FKeyInput := A8NoKey;
  FBreakDown := False;
end;

procedure TA8POKEY.SetKeyboard(Keys: Word);
begin
  FKeyInput := Keys;
end;

procedure TA8POKEY.StartPotScan(const Pots: TA8Pots);
begin
  Move(Pots, FPots, SizeOf(FPots));
  FPotCycle := 0;
end;

procedure TA8POKEY.ScanKeys;
begin
  if FRegs[15] and 2 = 0 then
    Exit;
  var Key := Byte(FKeyInput);
  if (Key <> A8NoKey) and (not FKeyDown or (Key and $3F <> FLastKey and $3F)) then
  begin
    FLastKey := Key;
    RaiseIRQ($40);
  end;
  FKeyDown := Key <> A8NoKey;
  var BreakDown := FKeyInput and A8Break <> 0;
  if BreakDown and not FBreakDown then
    RaiseIRQ($80);
  FBreakDown := BreakDown;
end;

procedure TA8POKEY.ClockComputer(Media: TA8Media; TapeMotor: Boolean; ClockHz: Integer);
begin
  if Media.Kind = TA8MediaKind.Cassette then
    ClockTimers(nil, nil, Ord(Media.ClockTape(TapeMotor, ClockHz)))
  else
    ClockTimers(Media.Clock, Media.Transmit);
end;

function TA8POKEY.ReadComputer(Index: Byte): Byte;
begin
  Result := ReadRegister(Index);
  if (Index = 15) and (FKeyInput and A8Shift <> 0) then
    Result := Result and $F7;
end;

procedure TA8POKEY.WriteComputer(Index, Value: Byte);
begin
  WriteRegister(Index, Value);
end;

procedure TA8POKEY.SerializeComputer(State: TStateArchive);
begin
  SerializeState(State);
  State.Field(FSerialIn, SizeOf(FSerialIn));
  State.Field(FSerialOut, SizeOf(FSerialOut));
  State.Field(FShifter, SizeOf(FShifter));
  State.Field(FStatus, SizeOf(FStatus));
  State.Field(FSendPending, SizeOf(FSendPending));
  State.Field(FBreakDown, SizeOf(FBreakDown));
  State.Field(FKeyDown, SizeOf(FKeyDown));
  if State.Version = 1 then
  begin
    var RemainingCycles := FShiftCycles * A8SerialByteCycles div 10;
    State.Field(RemainingCycles, SizeOf(RemainingCycles));
    if State.Loading then
    begin
      RestoreTimerPhase;
      FShiftCycles := EnsureRange((RemainingCycles * 10 + A8SerialByteCycles - 1) div A8SerialByteCycles, 0, 10);
    end;
    Exit;
  end;
  SerializeTiming(State);
end;

end.
