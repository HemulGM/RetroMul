unit GBC.Timer;

interface

uses
  Core.Snapshots, System.Classes, System.SysUtils, GBC.InterruptManager;

type
  TGBCTimer = class
  private
    class var
      FInstance: TGBCTimer;
    class function GetInstance: TGBCTimer; static;
  private
    FDivider, FControl, FModulo, FCounter, FTicksSinceOverflow: Integer;
    FPreviousBit, FOverflow: Boolean;
    FFrequencyBits: array[0..3] of Integer;
    procedure IncrementCounter;
    procedure UpdateDivider(NewDivider: Integer);
  public
    constructor Create; overload;
    procedure Step(StepCount: Integer);
    procedure Tick;
    procedure ClearDivider;
    function GetDivider: Integer;
    function GetCounter: Integer;
    procedure SetCounter(Value: Integer);
    function GetModulo: Integer;
    procedure SetModulo(Value: Integer);
    function GetControl: Integer;
    procedure SetControl(Value: Integer);
    procedure SetDivider(Value: Integer);
    class procedure ReleaseInstance;
    class property Instance: TGBCTimer read GetInstance;
    procedure SerializeState(State: TStateArchive);
  end;

implementation

{ TGBTimer }

procedure TGBCTimer.ClearDivider;
begin
  UpdateDivider(0);
end;

constructor TGBCTimer.Create;
begin
  FFrequencyBits[0] := 9;
  FFrequencyBits[1] := 3;
  FFrequencyBits[2] := 5;
  FFrequencyBits[3] := 7;
  FDivider := 0;
  FControl := 0;
  FModulo := 0;
  FCounter := 0;
  FTicksSinceOverflow := 0;
  FPreviousBit := False;
  FOverflow := False;
end;

function TGBCTimer.GetControl: Integer;
begin
  Result := FControl;
end;

function TGBCTimer.GetCounter: Integer;
begin
  Result := FCounter;
end;

function TGBCTimer.GetDivider: Integer;
begin
  Result := FDivider shr 8;
end;

class function TGBCTimer.GetInstance: TGBCTimer;
begin
  if FInstance = nil then
    FInstance := TGBCTimer.Create;
  Result := FInstance;
end;

function TGBCTimer.GetModulo: Integer;
begin
  Result := FModulo;
end;

procedure TGBCTimer.IncrementCounter;
begin
  Inc(FCounter);
  FCounter := FCounter mod $100;
  if FCounter <> 0 then
    Exit;
  FOverflow := True;
  FTicksSinceOverflow := 0;
end;

class procedure TGBCTimer.ReleaseInstance;
begin
  FreeAndNil(FInstance);
end;

procedure TGBCTimer.SetControl(Value: Integer);
begin
  // TAC is edge-triggered.  Changing either the enable bit or the selected
  // divider bit can create the same falling edge as a DIV reset.
  var OldBitPosition := FFrequencyBits[FControl and 3];
  var OldTimerBit := ((FDivider and (1 shl OldBitPosition)) <> 0) and
    ((FControl and 4) <> 0);
  FControl := Value and 7;
  var NewBitPosition := FFrequencyBits[FControl and 3];
  var NewTimerBit := ((FDivider and (1 shl NewBitPosition)) <> 0) and
    ((FControl and 4) <> 0);
  if OldTimerBit and not NewTimerBit then
    IncrementCounter;
  FPreviousBit := NewTimerBit;
end;

procedure TGBCTimer.SetCounter(Value: Integer);
begin
  if FTicksSinceOverflow >= 5 then
    Exit;
  FCounter := Value;
  FOverflow := False;
  FTicksSinceOverflow := 0;
end;

procedure TGBCTimer.SetDivider(Value: Integer);
begin
  FDivider := Value;
end;

procedure TGBCTimer.SetModulo(Value: Integer);
begin
  FModulo := Value;
end;

procedure TGBCTimer.Step(StepCount: Integer);
begin
  for var I := 0 to StepCount - 1 do
    Tick;
end;

procedure TGBCTimer.Tick;
begin
  UpdateDivider((FDivider + 1) and $ffff);
  if not FOverflow then
    Exit;
  Inc(FTicksSinceOverflow);
  if FTicksSinceOverflow = 4 then
    TGBCInterruptManager.Instance.RaiseInterruptByIndex(2); // 'TIMER_OVERFLOW';
  if FTicksSinceOverflow = 5 then
    FCounter := FModulo;
  if FTicksSinceOverflow = 6 then
  begin
    FCounter := FModulo;
    FOverflow := False;
    FTicksSinceOverflow := 0;
  end;
end;

procedure TGBCTimer.UpdateDivider(NewDivider: Integer);
begin
  FDivider := NewDivider;
  var BitPosition := FFrequencyBits[FControl and 3];
  var TimerBit := ((FDivider and (1 shl BitPosition)) <> 0) and ((FControl and (1 shl 2)) <> 0);
  if not TimerBit and FPreviousBit then
    IncrementCounter;
  FPreviousBit := TimerBit;
end;


procedure TGBCTimer.SerializeState(State: TStateArchive);
begin
  State.Field(FDivider, SizeOf(FDivider));
  State.Field(FControl, SizeOf(FControl));
  State.Field(FModulo, SizeOf(FModulo));
  State.Field(FCounter, SizeOf(FCounter));
  State.Field(FTicksSinceOverflow, SizeOf(FTicksSinceOverflow));
  State.Field(FPreviousBit, SizeOf(FPreviousBit));
  State.Field(FOverflow, SizeOf(FOverflow));
  State.Field(FFrequencyBits, SizeOf(FFrequencyBits));
end;

end.
