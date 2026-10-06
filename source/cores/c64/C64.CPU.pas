unit C64.CPU;

interface

uses
  NES.CPU;

type
  // Shares the tested NMOS bus/opcode engine; adds MOS6510 decimal arithmetic.
  // The integrated 6510 DDR/data port belongs to the memory bus implementation.
  TCPU6510 = class(TCPU6502)
  protected
    procedure Adc(Value: UInt8); override;
    procedure Sbc(Value: UInt8); override;
  end;

implementation
// Decimal behavior follows the py65 NMOS reference (BSD-3-Clause).
// See LICENSE.py65.txt; exhaustive reference checks live under codex-work.

procedure TCPU6510.Adc(Value: UInt8);
var
  Low, High, AdjustLow, AdjustHigh, ALU, Previous: Integer;
begin
  if (P and FLAG_DECIMAL) = 0 then
  begin
    inherited;
    Exit;
  end;
  Previous := A;
  AdjustLow := 0;
  AdjustHigh := 0;
  Low := (A and 15) + (Value and 15) + (P and FLAG_CARRY);
  if Low > 9 then
    AdjustLow := 6;
  High := (A shr 4) + (Value shr 4) + Ord(Low > 9);
  if High > 9 then
    AdjustHigh := 6;
  ALU := ((High and 15) shl 4) or (Low and 15);
  P := P and $3C;
  if ALU = 0 then
    P := P or FLAG_ZERO;
  P := P or (ALU and $80);
  if High > 9 then
    P := P or FLAG_CARRY;
  if ((not (Previous xor Value)) and (Previous xor ALU) and $80) <> 0 then
    P := P or FLAG_OVERFLOW;
  A := (((High + AdjustHigh) and 15) shl 4) or ((Low + AdjustLow) and 15);
end;

procedure TCPU6510.Sbc(Value: UInt8);
var
  Low, High, Sum, ALU, AdjustLow, AdjustHigh, Previous: Integer;
begin
  if (P and FLAG_DECIMAL) = 0 then
  begin
    inherited Sbc(Value);
    Exit;
  end;
  Previous := A;
  AdjustLow := 0;
  AdjustHigh := 0;
  Low := (A and 15) + ((Value xor $FF) and 15) + (P and FLAG_CARRY);
  if Low <= 15 then
    AdjustLow := 10;
  High := (A shr 4) + ((Value xor $FF) shr 4) + Ord(Low > 15);
  if High <= 15 then
    AdjustHigh := 160;
  Sum := A + (Value xor $FF) + (P and FLAG_CARRY);
  ALU := Sum and $FF;
  P := P and $3C;
  if ALU = 0 then
    P := P or FLAG_ZERO;
  P := P or (ALU and $80);
  if Sum > 255 then
    P := P or FLAG_CARRY;
  if ((Previous xor Value) and (Previous xor ALU) and $80) <> 0 then
    P := P or FLAG_OVERFLOW;
  A := ((((ALU + AdjustHigh) shr 4) and 15) shl 4) or ((ALU + AdjustLow) and 15);
end;

end.

