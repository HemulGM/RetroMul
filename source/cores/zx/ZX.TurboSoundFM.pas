unit ZX.TurboSoundFM;

interface

uses
  HW.Sound.YM2203, Core.Snapshots;

type
  // NedoPC revision C, 2022 CPLD: doubled motherboard AY clock,
  // F8..FF control latch. YM IRQ pins are not connected to the Z80.
  TZXTurboSoundFM = class
  private
    FChips: array[0..1] of TYM2203;
    FAddress: array[0..1] of Byte;
    FTimerPhase: array[0..1, 0..1] of Integer;
    FNativePhase, FTimerBPhase, FBusy: array[0..1] of Integer;
    FControl: Byte;
    FClock: Integer;
    function Selected: Integer;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Reset(Clock: Integer);
    procedure WriteAddress(Value: Byte);
    procedure WriteData(Value: Byte);
    function ReadData: Byte;
    procedure Tick;
    procedure SetPan(Channel: Integer; Left, Right: Double);
    procedure Sample(out SSGLeft, SSGRight, FMLeft, FMRight: Double);
    procedure SerializeState(State: TStateArchive);
    property Clock: Integer read FClock;
  end;

implementation

uses
  System.SysUtils, System.Classes;

constructor TZXTurboSoundFM.Create;
begin
  inherited;
  Reset(3500000);
end;

destructor TZXTurboSoundFM.Destroy;
begin
  for var i := 0 to 1 do
    FChips[i].Free;
  inherited;
end;

procedure TZXTurboSoundFM.Reset(Clock: Integer);
begin
  for var i := 0 to 1 do
  begin
    if FClock <> Clock then
    begin
      FreeAndNil(FChips[i]);
      FChips[i] := TYM2203.Create(Clock);
    end
    else
      FChips[i].Reset;
  end;
  FClock := Clock;
  FControl := $FE; // chip D1, SSG readback, FM DACs disabled
  FillChar(FAddress, SizeOf(FAddress), 0);
  FillChar(FTimerPhase, SizeOf(FTimerPhase), 0);
  FillChar(FBusy, SizeOf(FBusy), 0);
  FillChar(FNativePhase, SizeOf(FNativePhase), 0);
  FillChar(FTimerBPhase, SizeOf(FTimerBPhase), 0);
end;

function TZXTurboSoundFM.Selected: Integer;
begin
  // Unlike the old AY-only Turbo Sound selector, bit 0 directly drives
  // CUR_CHIP in the revision-C CPLD (FE=D1, FF=D2).
  Result := FControl and 1;
end;

procedure TZXTurboSoundFM.WriteAddress(Value: Byte);
begin
  if (Value and $F8) = $F8 then
    FControl := Value
  else
  begin
    var i := Selected;
    FAddress[i] := Value;
    FChips[i].SelectRegister(Value);
    for var T := 0 to 1 do
      FTimerPhase[i, T] := FTimerPhase[i, T] mod FChips[i].NativeDivider;
    FNativePhase[i] := FNativePhase[i] mod FChips[i].NativeDivider;
  end;
end;

procedure TZXTurboSoundFM.WriteData(Value: Byte);
begin
  var i := Selected;
  // Prescalers are address strobes, not data registers.
  var Previous := FChips[i].ReadRegister($27);
  if not (FAddress[i] in [$2D, $2E, $2F]) then
    FChips[i].WriteRegister(FAddress[i], Value);
  if FAddress[i] = $27 then
    for var T := 0 to 1 do
      if ((Value and (1 shl T)) <> 0) and ((Previous and (1 shl T)) = 0) then
      begin
        FTimerPhase[i, T] := 0;
        // Timer B's /16 stage runs continuously. Its initial interval is
        // shortened by the current native-clock phase (ymfm update_timer).
        if T = 1 then
          FChips[i].ClockTimers(FTimerBPhase[i], 2);
      end;
  FBusy[i] := 32 * (FChips[i].NativeDivider div 12);
end;

function TZXTurboSoundFM.ReadData: Byte;
begin
  var i := Selected;
  if (FControl and 2) <> 0 then
  begin
    if FAddress[i] < 16 then
      Result := FChips[i].ReadRegister(FAddress[i])
    else
      Result := 0; // FM registers are write-only.
  end
  else
  begin
    Result := FChips[i].ReadStatus;
    if FBusy[i] <> 0 then
      Result := Result or $80;
  end;
end;

procedure TZXTurboSoundFM.Tick;
begin
  for var i := 0 to 1 do
  begin
    if FBusy[i] > 0 then
      Dec(FBusy[i]);
    Inc(FNativePhase[i]);
    if FNativePhase[i] = FChips[i].NativeDivider then
    begin
      FNativePhase[i] := 0;
      FTimerBPhase[i] := (FTimerBPhase[i] + 1) and 15;
    end;
    for var T := 0 to 1 do
    begin
      Inc(FTimerPhase[i, T]);
      if FTimerPhase[i, T] = FChips[i].NativeDivider then
      begin
        FTimerPhase[i, T] := 0;
        FChips[i].ClockTimers(1, 1 shl T);
      end;
    end;
  end;
end;

procedure TZXTurboSoundFM.SetPan(Channel: Integer; Left, Right: Double);
begin
  for var i := 0 to 1 do
    FChips[i].SetSSGPan(Channel, Left, Right);
end;

procedure TZXTurboSoundFM.Sample(out SSGLeft, SSGRight, FMLeft, FMRight: Double);
begin
  SSGLeft := 0;
  SSGRight := 0;
  FMLeft := 0;
  FMRight := 0;
  for var i := 0 to 1 do
  begin
    var FM: Integer;
    var L, R: SmallInt;
    FChips[i].SampleParts(FM, L, R, False);
    SSGLeft := SSGLeft + L / 65536.0;
    SSGRight := SSGRight + R / 65536.0;
    // FM DAC gating never stops operators, envelopes, SSG or timers.
    if (FControl and 4) = 0 then
      if i = 0 then
        FMLeft := FM / 65536.0
      else
        FMRight := FM / 65536.0;
  end;
end;

procedure TZXTurboSoundFM.SerializeState(State: TStateArchive);
begin
  var Clock := FClock;
  State.Field(Clock, SizeOf(Clock));
  if (Clock < 1000000) or (Clock > 4000000) then
    raise EReadError.Create('Invalid Turbo Sound FM clock');
  if State.Loading and (Clock <> FClock) then
    Reset(Clock);
  State.Field(FControl, SizeOf(FControl));
  State.Field(FAddress, SizeOf(FAddress));
  State.Field(FTimerPhase, SizeOf(FTimerPhase));
  State.Field(FBusy, SizeOf(FBusy));
  State.Field(FNativePhase, SizeOf(FNativePhase));
  State.Field(FTimerBPhase, SizeOf(FTimerBPhase));
  if (FControl and $F8) <> $F8 then
    raise EReadError.Create('Invalid Turbo Sound FM control');
  for var i := 0 to 1 do
  begin
    FChips[i].SerializeState(State);
    for var T := 0 to 1 do
      if (FTimerPhase[i, T] < 0) or (FTimerPhase[i, T] >= FChips[i].NativeDivider) then
        raise EReadError.Create('Invalid Turbo Sound FM timer phase');
    if (FNativePhase[i] < 0) or (FNativePhase[i] >= FChips[i].NativeDivider) or
      (FTimerBPhase[i] < 0) or (FTimerBPhase[i] > 15) or
      (FBusy[i] < 0) or (FBusy[i] > 192) then
      raise EReadError.Create('Invalid Turbo Sound FM bus state');
  end;
end;

end.

