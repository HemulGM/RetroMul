unit MSX.Sound.SCC;

interface

uses
  Core.AudioFilter;

type
  TSCC = class
  private
    FWave: array[0..4, 0..31] of ShortInt;
    FRegisters: array[0..15] of Byte;
    FPosition: array[0..4] of Integer;
    FCounter: array[0..4] of Double;
    FDC: TPCMDCBlocker;
  public
    constructor Create;
    procedure Reset;
    procedure WriteRegister(Index, Value: Byte; Plus: Boolean = False);
    function ReadRegister(Index: Byte; Plus: Boolean = False): Byte;
    function Sample: SmallInt;
  end;

implementation

uses
  System.Math;

constructor TSCC.Create;
begin
  inherited;
  FDC.Configure(44100, 20);
  Reset;
end;

procedure TSCC.Reset;
begin
  FillChar(FWave, SizeOf(FWave), 0);
  FillChar(FRegisters, SizeOf(FRegisters), 0);
  FillChar(FPosition, SizeOf(FPosition), 0);
  FillChar(FCounter, SizeOf(FCounter), 0);
  FDC.Reset;
end;

procedure TSCC.WriteRegister(Index, Value: Byte; Plus: Boolean);
begin
  var Base := $80;
  if Plus then
    Base := $A0;
  if Index < Base then
  begin
    var C := Index div 32;
    var V := Integer(Value);
    if V >= 128 then
      Dec(V, 256);
    FWave[C, Index and 31] := V;
    if not Plus and (C = 3) then
      FWave[4, Index and 31] := V;
  end
  else if Index < Base + 16 then
    FRegisters[Index - Base] := Value;
end;

function TSCC.ReadRegister(Index: Byte; Plus: Boolean): Byte;
begin
  var Base := $80;
  if Plus then
    Base := $A0;
  if Index < Base then
    Result := Integer(FWave[Index div 32, Index and 31]) and 255
  else if Index < Base + 16 then
    Result := FRegisters[Index - Base]
  else
    Result := $FF;
end;

function TSCC.Sample: SmallInt;
begin
  var Sum := 0.0;
  for var C := 0 to 4 do
  begin
    var Period := Integer(FRegisters[C * 2]) + (FRegisters[C * 2 + 1] and 15) * 256 + 1;
    FCounter[C] := FCounter[C] + 3579545.0 / (44100 * Period);
    var Steps := Trunc(FCounter[C]);
    FCounter[C] := Frac(FCounter[C]);
    FPosition[C] := (FPosition[C] + Steps) and 31;
    if (FRegisters[15] and (1 shl C) <> 0) and (Period > 8) then
      Sum := Sum + FWave[C, FPosition[C]] * (FRegisters[10 + C] and 15) * 3;
  end;
  Result := EnsureRange(Round(FDC.Process(Sum)), -32768, 32767);
end;

end.

