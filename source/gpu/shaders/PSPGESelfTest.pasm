// Float arithmetic required by the LLE rasterizer, compared with the CPU
// before the device is used. The embedded source is compiled at context startup.
uses SoftDouble;

const
  Stride = 16;

var
  [Binding(0, 0), ReadOnly] Inputs: array of Cardinal4;
  [Binding(0, 1), WriteOnly] Outputs: array of Cardinal;
  [PushConstant] P: record
    Count: Cardinal;
  end;

function Pack(Lo, Hi: Cardinal): UInt64;
begin
  Result := UInt64(Lo) or (UInt64(Hi) shl 32);
end;

[Vulkan11, StrictFloat, LocalSize(64, 1, 1)]
procedure Main;
var
  I, O: Cardinal;
  V: Cardinal4;
  FA, FB: Single;
  DA, DB: Double;

  procedure Put64(At: Cardinal; X: Double);
  var
    Bits: UInt64;
  begin
    Bits := DoubleToBits(X);
    Outputs[At] := Cardinal(Bits);
    Outputs[At + 1] := Cardinal(Bits shr 32);
  end;

begin
  I := GlobalInvocationID.X;
  if I >= P.Count then
    Exit;
  V := Inputs[I];
  FA := BitsToSingle(V.X);
  FB := BitsToSingle(V.Y);
  DA := BitsToDouble(Pack(V.X, V.Y));
  DB := BitsToDouble(Pack(V.Z, V.W));
  O := I * Stride;
  Outputs[O] := SingleToBits(FA * FB);
  Put64(O + 1, DA + DB);
  Put64(O + 3, DA * DB);
  Put64(O + 5, Double(FA) * DB);
  Outputs[O + 7] := SingleToBits(Single(DA));
  Put64(O + 8, Double(Int64(Pack(V.Z, V.W))));
  Put64(O + 10, RoundEven(DA));
  Put64(O + 12, SoftDiv(DA, DB));
  Outputs[O + 14] := if Abs(DA) < 2147483648.0 then Cardinal(Integer(DA)) else 0;
  Outputs[O + 15] := 0;
end;
