unit GB.Timer;

interface

uses
  Core.Snapshots, System.Classes, System.SysUtils, GB.InterruptManager;

type
  TGBTimer = class
  private
    class var
      FInstance: TGBTimer;
    class function GetInstance: TGBTimer; static;
  private
    FInterruptManager: TGBInterruptManager;
    FDivider, FControl, FModulo, FCounter, FTicksSinceOverflow: Integer;
    FPreviousBit, FOverflow, FReloadCycle, FColorHardware: Boolean;
    FFrequencyBits: array[0..3] of Integer;
    procedure IncrementCounter;
    procedure UpdateDivider(NewDivider: Integer);
  public
    constructor Create(AInterruptManager: TGBInterruptManager = nil; ColorHardware: Boolean = False); overload;
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
    class property Instance: TGBTimer read GetInstance;
    procedure SerializeState(State: TStateArchive);
  end;

implementation

{ TGBTimer }

procedure TGBTimer.ClearDivider;
begin
  UpdateDivider(0);
end;

constructor TGBTimer.Create(AInterruptManager: TGBInterruptManager; ColorHardware: Boolean);
begin
  FColorHardware := ColorHardware;
  FInterruptManager := AInterruptManager;
  if FInterruptManager = nil then
    FInterruptManager := TGBInterruptManager.Instance;
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

function TGBTimer.GetControl: Integer;
begin
  Result := FControl;
end;

function TGBTimer.GetCounter: Integer;
begin
  Result := FCounter;
end;

function TGBTimer.GetDivider: Integer;
begin
  Result := FDivider shr 8;
end;

class function TGBTimer.GetInstance: TGBTimer;
begin
  if FInstance = nil then
    FInstance := TGBTimer.Create;
  Result := FInstance;
end;

function TGBTimer.GetModulo: Integer;
begin
  Result := FModulo;
end;

procedure TGBTimer.IncrementCounter;
begin
  if FOverflow or FReloadCycle then
    Exit;
  Inc(FCounter);
  FCounter := FCounter mod $100;
  if FCounter <> 0 then
    Exit;
  FOverflow := True;
  FTicksSinceOverflow := 0;
end;

class procedure TGBTimer.ReleaseInstance;
begin
  FreeAndNil(FInstance);
end;

procedure TGBTimer.SetControl(Value: Integer);
begin
  // Changing the enabled divider input can clock TIMA without a CPU tick.
  var OldBitPosition := FFrequencyBits[FControl and 3];
  var OldTimerBit := ((FDivider and (1 shl OldBitPosition)) <> 0) and ((FControl and 4) <> 0);
  FControl := Value and 7;
  var NewBitPosition := FFrequencyBits[FControl and 3];
  var NewTimerBit := ((FDivider and (1 shl NewBitPosition)) <> 0) and ((FControl and 4) <> 0);
  if OldTimerBit and not NewTimerBit and (not FColorHardware or ((FControl and 4) <> 0)) then
    IncrementCounter;
  FPreviousBit := NewTimerBit;
end;

procedure TGBTimer.SetCounter(Value: Integer);
begin
  if FReloadCycle then
    Exit;
  FCounter := Value and $FF;
  FOverflow := False;
  FTicksSinceOverflow := 0;
end;

procedure TGBTimer.SetDivider(Value: Integer);
begin
  FDivider := Value;
end;

procedure TGBTimer.SetModulo(Value: Integer);
begin
  FModulo := Value and $FF;
  if FReloadCycle then
    FCounter := FModulo;
end;

procedure TGBTimer.Step(StepCount: Integer);
begin
  for var i := 0 to StepCount - 1 do
    Tick;
end;

procedure TGBTimer.Tick;
begin
  FReloadCycle := False;
  // Advance a pending overflow before the divider can start a new one.
  if FOverflow then
  begin
    Inc(FTicksSinceOverflow);
    if FTicksSinceOverflow = 4 then
    begin
      FCounter := FModulo;
      FInterruptManager.RaiseInterruptByIndex(2);
      FOverflow := False;
      FTicksSinceOverflow := 0;
      FReloadCycle := True;
    end;
  end;
  UpdateDivider((FDivider + 1) and $FFFF);
end;

procedure TGBTimer.UpdateDivider(NewDivider: Integer);
begin
  FDivider := NewDivider;
  var BitPosition := FFrequencyBits[FControl and 3];
  var TimerBit := ((FDivider and (1 shl BitPosition)) <> 0) and ((FControl and (1 shl 2)) <> 0);
  if not TimerBit and FPreviousBit then
    IncrementCounter;
  FPreviousBit := TimerBit;
end;

procedure TGBTimer.SerializeState(State: TStateArchive);
begin
  State.Field(FDivider, SizeOf(FDivider));
  State.Field(FControl, SizeOf(FControl));
  State.Field(FModulo, SizeOf(FModulo));
  State.Field(FCounter, SizeOf(FCounter));
  State.Field(FTicksSinceOverflow, SizeOf(FTicksSinceOverflow));
  State.Field(FPreviousBit, SizeOf(FPreviousBit));
  State.Field(FOverflow, SizeOf(FOverflow));
  State.Field(FReloadCycle, SizeOf(FReloadCycle));
  State.Field(FFrequencyBits, SizeOf(FFrequencyBits));
end;

end.

