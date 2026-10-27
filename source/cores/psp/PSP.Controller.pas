unit PSP.Controller;

interface

uses
  System.SysUtils, System.Generics.Collections, Core.Emulation.Types, PSP.Memory,
  PSP.CPU, PSP.Kernel;

type
  TPSPControlSample = record
    Timestamp, Buttons: Cardinal;
    X, Y: Byte;
  end;

  TPSPControlWait = record
    Time: UInt64;
    Address, ThreadId: Cardinal;
    Negative: Boolean;
  end;

  TPSPController = class
  private
    FMemory: TPSPMemory;
    FCPU: TPSPCPU;
    FKernel: TPSPKernel;
    FMode, FCycle, FWrite, FUnread: Cardinal;
    FNextTime: UInt64;
    FHistory: array[0..63] of TPSPControlSample;
    FWaiting: TList<TPSPControlWait>;
    FLatch: array[0..3] of Cardinal;
    FLatchCount, FPrevious: Cardinal;
    FIdleReset, FIdleBack: Integer;
    function Period: Cardinal;
    procedure WriteSample(Address: Cardinal; const Sample: TPSPControlSample; Negative: Boolean);
  public
    constructor Create(Memory: TPSPMemory; CPU: TPSPCPU; Kernel: TPSPKernel);
    destructor Destroy; override;
    procedure Advance(Time: UInt64; const Input: TEmulatorInput);
    function Handle(NID: Cardinal; const Input: TEmulatorInput; out Value: Cardinal): Boolean;
  end;

implementation

uses
  System.Math;

constructor TPSPController.Create(Memory: TPSPMemory; CPU: TPSPCPU; Kernel: TPSPKernel);
begin
  inherited Create;
  FMemory := Memory;
  FCPU := CPU;
  FKernel := Kernel;
  FWaiting := TList<TPSPControlWait>.Create;
  FIdleReset := -1;
  FIdleBack := -1;
  for var I := 0 to 63 do
  begin
    FHistory[I].X := 128;
    FHistory[I].Y := 128;
  end;
end;

destructor TPSPController.Destroy;
begin
  FWaiting.Free;
  inherited;
end;

function TPSPController.Period: Cardinal;
begin
  Result := FCycle;
  if Result = 0 then
    Result := 16683;
end;

procedure TPSPController.WriteSample(Address: Cardinal; const Sample: TPSPControlSample; Negative: Boolean);
begin
  FMemory.Zero(Address, 16);
  FMemory.Write32(Address, Sample.Timestamp);
  var Buttons := Sample.Buttons;
  if Negative then
    Buttons := not Buttons;
  FMemory.Write32(Address + 4, Buttons);
  FMemory.Write8(Address + 8, Sample.X);
  FMemory.Write8(Address + 9, Sample.Y);
end;

procedure TPSPController.Advance(Time: UInt64; const Input: TEmulatorInput);
const
  Buttons: array[TEmulatorButton] of Cardinal =
    ($10, $40, $80, $20, $4000, $2000, $1, $8, $100, $8000, $1000, $200, 0);
begin
  while FNextTime <= Time do
  begin
    var Sample := Default(TPSPControlSample);
    Sample.Timestamp := Cardinal(FNextTime and $FFFFFFFF);
    for var Button in Input.Buttons do
      Sample.Buttons := Sample.Buttons or Buttons[Button];
    Sample.X := 128;
    Sample.Y := 128;
    if (FMode <> 0) and Input.Analog[0].Valid then
    begin
      Sample.X := (Integer(Input.Analog[0].X) + 32768) shr 8;
      Sample.Y := (Integer(Input.Analog[0].Y) + 32768) shr 8;
    end;
    var Changed := Sample.Buttons xor FPrevious;
    FLatch[0] := FLatch[0] or (Changed and Sample.Buttons);
    FLatch[1] := FLatch[1] or (Changed and FPrevious);
    FLatch[2] := FLatch[2] or Sample.Buttons;
    FLatch[3] := FLatch[3] or not Sample.Buttons;
    Inc(FLatchCount);
    FPrevious := Sample.Buttons;
    FHistory[FWrite] := Sample;
    FWrite := (FWrite + 1) and 63;
    FUnread := Min(Cardinal(64), FUnread + 1);
    while (FWaiting.Count > 0) and (FWaiting[0].Time <= FNextTime) do
    begin
      var Wait := FWaiting[0];
      FWaiting.Delete(0);
      if FKernel.IsWaitingUntil(Wait.ThreadId, Wait.Time) then
      begin
        WriteSample(Wait.Address, Sample, Wait.Negative);
        FUnread := 0;
        Break;
      end;
    end;
    Inc(FNextTime, Period);
  end;
end;

function TPSPController.Handle(NID: Cardinal; const Input: TEmulatorInput; out Value: Cardinal): Boolean;
begin
  Result := True;
  Value := 0;
  var A := FCPU.Registers[4];
  var B := FCPU.Registers[5];
  case NID of
    $1F4011E6:
      if A > 1 then
        Value := $80000107
      else
      begin
        Value := FMode;
        FMode := A;
      end;
    $6A2774F3:
      if (A <> 0) and ((A < 5555) or (A > 20000)) then
        Value := $80000107
      else
      begin
        Value := FCycle;
        FCycle := A;
        FNextTime := FKernel.Time + Period;
        for var I := 0 to FWaiting.Count - 1 do
        begin
          var Wait := FWaiting[I];
          var OldTime := Wait.Time;
          Wait.Time := FNextTime + UInt64(I) * Period;
          FKernel.RescheduleWait(Wait.ThreadId, OldTime, Wait.Time);
          FWaiting[I] := Wait;
        end;
      end;
    $02BAAD91:
      FMemory.Write32(A, FCycle);
    $DA6B76A1:
      FMemory.Write32(A, FMode);
    $A7144800:
      if (Integer(A) < -1) or (Integer(A) > 128) or (Integer(B) < -1) or (Integer(B) > 128) then
        Value := $800001FE
      else
      begin
        FIdleReset := Integer(A);
        FIdleBack := Integer(B);
      end;
    $687660FA:
      begin
        if A <> 0 then
          FMemory.Write32(A, Cardinal(FIdleReset));
        if B <> 0 then
          FMemory.Write32(B, Cardinal(FIdleBack));
      end;
    $B1D0E5CD, $0B588501:
      begin
        Advance(FKernel.Time, Input);
        if (A and 3 <> 0) or not FMemory.IsValid(A, 16) then
        begin
          Value := $800200D3;
          Exit;
        end;
        for var I := 0 to 3 do
          FMemory.Write32(A + Cardinal(I) * 4, FLatch[I]);
        Value := FLatchCount;
        if NID = $0B588501 then
        begin
          FillChar(FLatch, SizeOf(FLatch), 0);
          FLatchCount := 0;
        end;
      end;
    $3A622550, $C152080A, $1F803938, $60B81F86:
      begin
        if (B = 0) or (B > 64) then
        begin
          Value := $80000107;
          Exit;
        end;
        if (A and 3 <> 0) or not FMemory.IsValid(A, B * 16) then
        begin
          Value := $800200D3;
          Exit;
        end;
        Advance(FKernel.Time, Input);
        var Negative := (NID = $C152080A) or (NID = $60B81F86);
        var Peek := (NID = $3A622550) or (NID = $C152080A);
        if not Peek and not FCPU.InterruptEnabled then
        begin
          Value := $80020064;
          Exit;
        end;
        if not Peek and not FKernel.DispatchEnabled then
        begin
          Value := $800201A7;
          Exit;
        end;
        var Count := B;
        if not Peek then
          Count := Min(Count, FUnread);
        if not Peek and (Count = 0) then
        begin
          var Wait: TPSPControlWait;
          Wait.Address := A;
          Wait.Negative := Negative;
          Wait.ThreadId := FKernel.CurrentThreadId;
          Wait.Time := FNextTime + UInt64(FWaiting.Count) * Period;
          FWaiting.Add(Wait);
          FKernel.WaitUntil(Wait.Time);
          Value := 1;
          Exit;
        end;
        for var I := 0 to Integer(Count) - 1 do
          WriteSample(A + Cardinal(I) * 16, FHistory[(FWrite + 64 - Count + Cardinal(I)) and 63], Negative);
        if not Peek then
          FUnread := 0;
        Value := Count;
      end;
  else
    Result := False;
  end;
end;

end.

