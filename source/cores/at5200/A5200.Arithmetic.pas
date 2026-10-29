unit A5200.Arithmetic;

interface

function S32(Value: Int64): Integer;

function U8(Value: Int64): Byte;

function S16(Value: Int64): SmallInt;

function Sar32(Value: Int64; Bits: Integer): Integer;

implementation

function S32(Value: Int64): Integer;
begin
  Value := Value and $FFFFFFFF;
  if Value >= $80000000 then
    Dec(Value, $100000000);
  Result := Value;
end;

function U8(Value: Int64): Byte;
begin
  Result := Value and 255;
end;

function S16(Value: Int64): SmallInt;
begin
  Value := Value and 65535;
  if Value >= 32768 then
    Dec(Value, 65536);
  Result := Value;
end;

function Sar32(Value: Int64; Bits: Integer): Integer;
begin
  Bits := Bits and 31;
  Value := S32(Value);
  if Value >= 0 then
    Result := Value shr Bits
  else
    Result := -((-Value + (Int64(1) shl Bits) - 1) shr Bits);
end;

end.

