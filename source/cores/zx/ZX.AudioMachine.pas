unit ZX.AudioMachine;

interface

uses
  System.SysUtils, MD.Z80, ZX.Sound.YM2149, Core.AudioFilter;

type
  TZXAudioMachine = class
  private
    FCPU: TZ80State;
    FCallbacks: TZ80ReadAndWriteCallbacks;
    FChip: TYM2149F;
    FDebt, FNative, FInterruptTime, FPulse, FBeeper, FCPCAddress: Integer;
    FClock: Integer;
    FSamplePhase, FSumL, FSumR, FLevelL, FLevelR: Double;
    FDCLeft, FDCRight: TPCMDCBlocker;
    procedure PortWrite(Address, Value: Cardinal);
    function PortRead(Address: Cardinal): Cardinal;
  public
    RAM: array[0..65535] of Byte;
    constructor Create;
    destructor Destroy; override;
    procedure Reset(InitialHigh, InitialLow: Byte; Stack, Init, Play: Word);
    procedure Sample(out Left, Right: SmallInt);
    property CpuClock: Integer read FClock;
  end;

implementation

uses
  System.Math;

function MemRead(Context: Pointer; Address: Cardinal): Cardinal;
begin
  Result := TZXAudioMachine(Context).RAM[Address and $FFFF];
end;

procedure MemWrite(Context: Pointer; Address, Value: Cardinal);
begin
  TZXAudioMachine(Context).RAM[Address and $FFFF] := Value and 255;
end;

function IORead(Context: Pointer; Address: Cardinal): Cardinal;
begin
  Result := TZXAudioMachine(Context).PortRead(Address);
end;

procedure IOWrite(Context: Pointer; Address, Value: Cardinal);
begin
  TZXAudioMachine(Context).PortWrite(Address, Value);
end;

constructor TZXAudioMachine.Create;
begin
  inherited;
  FChip := TYM2149F.Create(1773450);
  FCallbacks := Default(TZ80ReadAndWriteCallbacks);
  FCallbacks.UserData := Self;
  FCallbacks.ReadCallback := MemRead;
  FCallbacks.WriteCallback := MemWrite;
  FCallbacks.PortReadCallback := IORead;
  FCallbacks.PortWriteCallback := IOWrite;
  FDCLeft.Configure(44100, 20);
  FDCRight.Configure(44100, 20);
  FClock := 3546900;
  FInterruptTime := FClock div 50;
  Z80Reset(FCPU);
end;

destructor TZXAudioMachine.Destroy;
begin
  FChip.Free;
  inherited;
end;

procedure TZXAudioMachine.Reset(InitialHigh, InitialLow: Byte; Stack, Init, Play: Word);
const
  Active: array[0..12] of Byte = ($F3, $CD, 0, 0, $ED, $56, $FB, $76, $CD, 0, 0, $18, $F7);
  Passive: array[0..9] of Byte = ($F3, $CD, 0, 0, $ED, $5E, $FB, $76, $18, $FA);
begin
  FCPU := Default(TZ80State);
  Z80Reset(FCPU);
  FCPU.A := InitialHigh;
  FCPU.F := InitialLow;
  FCPU.B := InitialHigh;
  FCPU.C := InitialLow;
  FCPU.D := InitialHigh;
  FCPU.E := InitialLow;
  FCPU.H := InitialHigh;
  FCPU.L := InitialLow;
  FCPU.AAlt := InitialHigh;
  FCPU.FAlt := InitialLow;
  FCPU.BAlt := InitialHigh;
  FCPU.CAlt := InitialLow;
  FCPU.DAlt := InitialHigh;
  FCPU.EAlt := InitialLow;
  FCPU.HAlt := InitialHigh;
  FCPU.LAlt := InitialLow;
  FCPU.IXH := InitialHigh;
  FCPU.IXL := InitialLow;
  FCPU.IYH := InitialHigh;
  FCPU.IYL := InitialLow;
  FCPU.StackPointer := Stack;
  if Play = 0 then
    for var I := 0 to High(Passive) do
      RAM[I] := Passive[I]
  else
  begin
    for var I := 0 to High(Active) do
      RAM[I] := Active[I];
    RAM[9] := Play and 255;
    RAM[10] := Play shr 8;
  end;
  RAM[2] := Init and 255;
  RAM[3] := Init shr 8;
  RAM[$38] := $FB;
  RAM[$39] := $C9;
  FChip.Free;
  FChip := nil;
  FChip := TYM2149F.Create(1773450);
  FClock := 3546900;
  FDebt := 0;
  FNative := 0;
  FSamplePhase := 0;
  FInterruptTime := FClock div 50;
  FPulse := 0;
  FBeeper := 0;
  FCPCAddress := 0;
  FLevelL := 0;
  FLevelR := 0;
  FDCLeft.Reset;
  FDCRight.Reset;
end;

procedure TZXAudioMachine.PortWrite(Address, Value: Cardinal);
begin
  Value := Value and 255;
  // CPC uses an 8255 latch; Spectrum uses partially decoded AY ports.
  if (Address shr 8) = $F4 then
    FCPCAddress := Value
  else if (Address shr 8) = $F6 then
  begin
    if FClock <> 2000000 then
    begin
      FChip.Free;
      FChip := nil;
      FChip := TYM2149F.Create(1000000);
      FClock := 2000000;
      FInterruptTime := FClock div 50;
    end;
    case Value and $C0 of
      $C0:
        FChip.WriteAddress(FCPCAddress);
      $80:
        FChip.WriteData(FCPCAddress);
    end;
  end
  else if (Address and $C002) = $C000 then
    FChip.WriteAddress(Value)
  else if (Address and $C002) = $8000 then
    FChip.WriteData(Value)
  else if (Address and 1) = 0 then
    FBeeper := Ord((Value and $10) <> 0);
end;

function TZXAudioMachine.PortRead(Address: Cardinal): Cardinal;
begin
  if (Address and $C002) = $C000 then
    Result := FChip.ReadData
  else
    Result := $FF;
end;

procedure TZXAudioMachine.Sample(out Left, Right: SmallInt);
begin
  FSamplePhase := FSamplePhase + FClock / 44100.0;
  var Count := Trunc(FSamplePhase);
  FSamplePhase := FSamplePhase - Count;
  FSumL := 0;
  FSumR := 0;
  for var I := 1 to Count do
  begin
    if FDebt = 0 then
      FDebt := Z80DoInstruction(FCPU, FCallbacks);
    Dec(FDebt);
    Dec(FInterruptTime);
    if FInterruptTime <= 0 then
    begin
      Inc(FInterruptTime, FClock div 50);
      FPulse := 32;
      Z80Interrupt(FCPU, 1);
    end;
    if FPulse > 0 then
    begin
      Dec(FPulse);
      if FPulse = 0 then
        Z80Interrupt(FCPU, 0);
    end;
    Inc(FNative);
    if FNative = 16 then
    begin
      FNative := 0;
      FChip.GenerateNative(FLevelL, FLevelR);
    end;
    FSumL := FSumL + FLevelL + FBeeper * 0.20;
    FSumR := FSumR + FLevelR + FBeeper * 0.20;
  end;
  Left := EnsureRange(Round(FDCLeft.Process(FSumL / Count) * 24000), -32768, 32767);
  Right := EnsureRange(Round(FDCRight.Process(FSumR / Count) * 24000), -32768, 32767);
end;

initialization
  ConstantInitialise;

end.

