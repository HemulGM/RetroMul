unit HW.HostFPU;

interface

// SSE control is deliberately isolated from portable emulation code. On hosts
// without MXCSR there is no SSE state to inherit between rendering workers.
function ReadHostMXCSR: Cardinal;

procedure WriteHostMXCSR(Value: Cardinal);

implementation

function ReadHostMXCSR: Cardinal;
{$IF Defined(CPUX86) or Defined(CPUX64)}
var
  Control: Cardinal;
asm
  STMXCSR Control
  MOV EAX, Control
end;
{$ELSE}
begin
  Result := 0;
end;
{$ENDIF}

procedure WriteHostMXCSR(Value: Cardinal);
{$IF Defined(CPUX86) or Defined(CPUX64)}
var
  Control: Cardinal;
asm
  MOV EAX, Value
  MOV Control, EAX
  LDMXCSR Control
end;
{$ELSE}
begin
end;
{$ENDIF}

end.
