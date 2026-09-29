unit MD.Arithmetic;

// Explicit hardware arithmetic: independent of Delphi range/overflow settings.
interface

function Add32(A, B: Cardinal): Cardinal; inline;

function Sub32(A, B: Cardinal): Cardinal; inline;

function Mul32(A, B: Cardinal): Cardinal; inline;

implementation

function Add32(A, B: Cardinal): Cardinal;
begin
  Result := Cardinal((UInt64(A) + B) and $FFFFFFFF);
end;

function Sub32(A, B: Cardinal): Cardinal;
begin
  Result := Cardinal((Int64(A) - B) and $FFFFFFFF);
end;

function Mul32(A, B: Cardinal): Cardinal;
begin
  Result := Cardinal((UInt64(A) * B) and $FFFFFFFF);
end;

end.

