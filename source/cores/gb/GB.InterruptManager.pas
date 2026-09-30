unit GB.InterruptManager;

interface

uses
  System.SysUtils;

type
  TGBInterrupt = record
    Name: string;
    IsRaised: Boolean;
    IsEnabled: Boolean;
    Bit: Integer;
    Handler: Integer;
  end;

type
  TGBInterruptArray = array of TGBInterrupt;

type
  TGBInterruptManager = class
  private
    class var
      FInstance: TGBInterruptManager;
    class function GetInstance: TGBInterruptManager; static;
  private
    FMasterEnabled: Boolean;
    FEnableRegisterUpperBits: Integer;
    FFlagRegisterUpperBits: Integer;
    FInterrupts: array[0..4] of TGBInterrupt;
  public
    constructor Create; overload;
    procedure MasterEnable;
    procedure MasterDisable;
    function IsMasterEnabled: Boolean;

    procedure RaiseInterruptByReg(RegisterValue: Integer);
    procedure EnableInterruptByReg(RegisterValue: Integer);
    procedure RaiseInterruptByIndex(InterruptIndex: Integer);
    procedure EnableInterruptByIndex(InterruptIndex: Integer);
    procedure DisableInterruptByIndex(InterruptIndex: Integer);
    procedure ClearInterruptByIndex(InterruptIndex: Integer);

    function GetInterruptsEnabled: Integer;
    function GetInterruptsRaised: Integer;

    function GetAllInterrupts: TGBInterruptArray;

    class procedure ReleaseInstance;
    class property Instance: TGBInterruptManager read GetInstance;
  end;

implementation

{ TGBInterruptManager }

procedure TGBInterruptManager.ClearInterruptByIndex(InterruptIndex: Integer);
begin
  FInterrupts[InterruptIndex].IsRaised := False;
end;

constructor TGBInterruptManager.Create;
begin
  FInterrupts[0].Name := 'JOYPAD_INPUT';
  FInterrupts[0].Bit := 16;
  FInterrupts[0].Handler := $60;
  FInterrupts[0].IsRaised := False;
  FInterrupts[0].IsEnabled := False;

  FInterrupts[1].Name := 'SERIAL_TRANSFER_COMPLETE';
  FInterrupts[1].Bit := 8;
  FInterrupts[1].Handler := $58;
  FInterrupts[1].IsRaised := False;
  FInterrupts[1].IsEnabled := False;

  FInterrupts[2].Name := 'TIMER_OVERFLOW';
  FInterrupts[2].Bit := 4;
  FInterrupts[2].Handler := $50;
  FInterrupts[2].IsRaised := False;
  FInterrupts[2].IsEnabled := False;

  FInterrupts[3].Name := 'LCDC_STATUS';
  FInterrupts[3].Bit := 2;
  FInterrupts[3].Handler := $48;
  FInterrupts[3].IsRaised := False;
  FInterrupts[3].IsEnabled := False;

  FInterrupts[4].Name := 'VBLANK';
  FInterrupts[4].Bit := 1;
  FInterrupts[4].Handler := $40;
  FInterrupts[4].IsRaised := False;
  FInterrupts[4].IsEnabled := False;

  FMasterEnabled := False;
  FEnableRegisterUpperBits := 0;
  FFlagRegisterUpperBits := 0;
end;

procedure TGBInterruptManager.DisableInterruptByIndex(InterruptIndex: Integer);
begin
  FInterrupts[InterruptIndex].IsEnabled := False;
end;

procedure TGBInterruptManager.EnableInterruptByIndex(InterruptIndex: Integer);
begin
  FInterrupts[InterruptIndex].IsEnabled := True;
end;

procedure TGBInterruptManager.EnableInterruptByReg(RegisterValue: Integer);
begin
  FEnableRegisterUpperBits := RegisterValue and $E0;
  RegisterValue := RegisterValue and $1F;
  for var i := 0 to High(FInterrupts) do
  begin
    FInterrupts[i].IsEnabled := (RegisterValue div FInterrupts[i].Bit) = 1;
    RegisterValue := RegisterValue mod FInterrupts[i].Bit;
  end;
end;

function TGBInterruptManager.GetAllInterrupts: TGBInterruptArray;
begin
  SetLength(Result, Length(FInterrupts));
  for var i := 0 to High(FInterrupts) do
    Result[i] := FInterrupts[i];
end;

class function TGBInterruptManager.GetInstance: TGBInterruptManager;
begin
  if FInstance = nil then
    FInstance := TGBInterruptManager.Create;
  Result := FInstance;
end;

function TGBInterruptManager.GetInterruptsEnabled: Integer;
begin
  Result := FEnableRegisterUpperBits;
  for var Interrupt in FInterrupts do
    if Interrupt.IsEnabled then
      Result := Result or Interrupt.Bit;
end;

function TGBInterruptManager.GetInterruptsRaised: Integer;
begin
  Result := FFlagRegisterUpperBits;
  for var Interrupt in FInterrupts do
    if Interrupt.IsRaised then
      Result := Result or Interrupt.Bit;
end;

function TGBInterruptManager.IsMasterEnabled: Boolean;
begin
  Result := FMasterEnabled;
end;

procedure TGBInterruptManager.MasterDisable;
begin
  FMasterEnabled := False;
end;

procedure TGBInterruptManager.MasterEnable;
begin
  FMasterEnabled := True;
end;

procedure TGBInterruptManager.RaiseInterruptByIndex(InterruptIndex: Integer);
begin
  FInterrupts[InterruptIndex].IsRaised := True;
end;

procedure TGBInterruptManager.RaiseInterruptByReg(RegisterValue: Integer);
begin
  FFlagRegisterUpperBits := RegisterValue and $E0;
  RegisterValue := RegisterValue and $1F;
  for var i := 0 to High(FInterrupts) do
  begin
    FInterrupts[i].IsRaised := (RegisterValue div FInterrupts[i].Bit) = 1;
    RegisterValue := RegisterValue mod FInterrupts[i].Bit;
  end;
end;

class procedure TGBInterruptManager.ReleaseInstance;
begin
  FreeAndNil(FInstance);
end;

end.

