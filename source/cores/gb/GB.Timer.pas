unit GB.Timer;

interface

uses
  System.SysUtils, GB.InterruptManager;

type
  TGBTimer = class
  private
    class var
      FInstance: TGBTimer;
    class function GetInstance: TGBTimer; static;
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
    class property Instance: TGBTimer read GetInstance;
  end;

implementation

{ TGBTimer }

procedure TGBTimer.ClearDivider;
begin
  UpdateDivider(0);
end;

constructor TGBTimer.Create;
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
  FControl := Value;
end;

procedure TGBTimer.SetCounter(Value: Integer);
begin
  if FTicksSinceOverflow >= 5 then
    Exit;
  FCounter := Value;
  FOverflow := False;
  FTicksSinceOverflow := 0;
end;

procedure TGBTimer.SetDivider(Value: Integer);
begin
  FDivider := Value;
end;

procedure TGBTimer.SetModulo(Value: Integer);
begin
  FModulo := Value;
end;

procedure TGBTimer.Step(StepCount: Integer);
begin
  for var I := 0 to StepCount - 1 do
    Tick;
end;

procedure TGBTimer.Tick;
begin
  UpdateDivider((FDivider + 1) and $ffff);
  if not FOverflow then
    Exit;
  Inc(FTicksSinceOverflow);
  if FTicksSinceOverflow = 4 then
    TGBInterruptManager.Instance.RaiseInterruptByIndex(2); // 'TIMER_OVERFLOW';
  if FTicksSinceOverflow = 5 then
    FCounter := FModulo;
  if FTicksSinceOverflow = 6 then
  begin
    FCounter := FModulo;
    FOverflow := False;
    FTicksSinceOverflow := 0;
  end;
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

end.

