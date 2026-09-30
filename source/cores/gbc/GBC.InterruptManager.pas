unit GBC.InterruptManager;

interface

uses
  System.SysUtils;

type
  TGBCInterrupt = record
    Name: string;
    IsRaised: Boolean;
    IsEnabled: Boolean;
    Bit: Integer;
    Handler: Integer;
  end;

type
  TGBCInterruptArray = array of TGBCInterrupt;

type
  TGBCInterruptManager = class
  private
    class var
      FInstance: TGBCInterruptManager;
    class function GetInstance: TGBCInterruptManager; static;
  private
    FMasterEnabled: Boolean;
    FEnableRegisterUpperBits: Integer;
    FFlagRegisterUpperBits: Integer;
    FInterrupts: array[0..4] of TGBCInterrupt;
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

    function GetAllInterrupts: TGBCInterruptArray;

    class procedure ReleaseInstance;
    class property Instance: TGBCInterruptManager read GetInstance;
  end;

implementation

{ TGBInterruptManager }

procedure TGBCInterruptManager.ClearInterruptByIndex(InterruptIndex: Integer);
begin
  FInterrupts[InterruptIndex].IsRaised := False;
end;

constructor TGBCInterruptManager.Create;
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

procedure TGBCInterruptManager.DisableInterruptByIndex(InterruptIndex: Integer);
begin
  FInterrupts[InterruptIndex].IsEnabled := False;
end;

procedure TGBCInterruptManager.EnableInterruptByIndex(InterruptIndex: Integer);
begin
  FInterrupts[InterruptIndex].IsEnabled := True;
end;

procedure TGBCInterruptManager.EnableInterruptByReg(RegisterValue: Integer);
begin
  FEnableRegisterUpperBits := RegisterValue and $E0;
  RegisterValue := RegisterValue and $1F;
  for var i := 0 to High(FInterrupts) do
  begin
    FInterrupts[i].IsEnabled := (RegisterValue div FInterrupts[i].Bit) = 1;
    RegisterValue := RegisterValue mod FInterrupts[i].Bit;
  end;
end;

function TGBCInterruptManager.GetAllInterrupts: TGBCInterruptArray;
begin
  SetLength(Result, Length(FInterrupts));
  for var i := 0 to High(FInterrupts) do
    Result[i] := FInterrupts[i];
end;

class function TGBCInterruptManager.GetInstance: TGBCInterruptManager;
begin
  if FInstance = nil then
    FInstance := TGBCInterruptManager.Create;
  Result := FInstance;
end;

function TGBCInterruptManager.GetInterruptsEnabled: Integer;
begin
  Result := FEnableRegisterUpperBits;
  for var Interrupt in FInterrupts do
    if Interrupt.IsEnabled then
      Result := Result or Interrupt.Bit;
end;

function TGBCInterruptManager.GetInterruptsRaised: Integer;
begin
  Result := FFlagRegisterUpperBits;
  for var Interrupt in FInterrupts do
    if Interrupt.IsRaised then
      Result := Result or Interrupt.Bit;
end;

function TGBCInterruptManager.IsMasterEnabled: Boolean;
begin
  Result := FMasterEnabled;
end;

procedure TGBCInterruptManager.MasterDisable;
begin
  FMasterEnabled := False;
end;

procedure TGBCInterruptManager.MasterEnable;
begin
  FMasterEnabled := True;
end;

procedure TGBCInterruptManager.RaiseInterruptByIndex(InterruptIndex: Integer);
begin
  FInterrupts[InterruptIndex].IsRaised := True;
end;

procedure TGBCInterruptManager.RaiseInterruptByReg(RegisterValue: Integer);
begin
  FFlagRegisterUpperBits := RegisterValue and $E0;
  RegisterValue := RegisterValue and $1F;
  for var i := 0 to High(FInterrupts) do
  begin
    FInterrupts[i].IsRaised := (RegisterValue div FInterrupts[i].Bit) = 1;
    RegisterValue := RegisterValue mod FInterrupts[i].Bit;
  end;
end;

class procedure TGBCInterruptManager.ReleaseInstance;
begin
  FreeAndNil(FInstance);
end;

end.

