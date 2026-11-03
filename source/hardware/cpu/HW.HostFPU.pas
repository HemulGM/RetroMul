unit HW.HostFPU;

interface

// SSE control is deliberately isolated from portable emulation code. On hosts
// without MXCSR there is no SSE state to inherit between rendering workers.
function ReadHostMXCSR: Cardinal;

procedure WriteHostMXCSR(Value: Cardinal);

implementation

{$IF Defined(CPUX64) and (Defined(LINUX) or Defined(MACOS))}
uses
  Posix.Base;

type
  // Native fenv_t ABI, not an FXSAVE image. Only MXCSR is modified; the
  // current x87 environment is preserved by the fegetenv/fesetenv pair.
  THostFPUEnvironment = record
    {$IF Defined(LINUX)}
    // glibc sysdeps/x86/fpu/bits/fenv.h: 28-byte x87 environment + MXCSR.
    X87: array[0..27] of Byte;
    MXCSR: Cardinal;
    {$ELSE}
    // Darwin Source/Intel/fenv.h: control/status, MXCSR, reserved bytes.
    Control, Status: Word;
    MXCSR: Cardinal;
    Reserved: array[0..7] of Byte;
    {$ENDIF}
  end;

const
  HostMathLibrary = {$IF Defined(LINUX)}'libm.so'{$ELSE}libc{$ENDIF};

function ReadHostEnvironment(Environment: Pointer): Integer; cdecl; external HostMathLibrary name _PU + 'fegetenv';

function WriteHostEnvironment(Environment: Pointer): Integer; cdecl; external HostMathLibrary name _PU + 'fesetenv';
{$ENDIF}

function ReadHostMXCSR: Cardinal;
{$IF Defined(MSWINDOWS) and (Defined(CPUX86) or Defined(CPUX64))}
var
  Control: Cardinal;
asm
  STMXCSR Control
  MOV EAX, Control
end;
{$ELSEIF Defined(CPUX64) and (Defined(LINUX) or Defined(MACOS))}
var
  Environment: THostFPUEnvironment;
begin
  if ReadHostEnvironment(@Environment) = 0 then
    Result := Environment.MXCSR
  else
    Result := $1F80;
end;
{$ELSE}
begin
  Result := 0;
end;
{$ENDIF}

procedure WriteHostMXCSR(Value: Cardinal);
{$IF Defined(MSWINDOWS) and (Defined(CPUX86) or Defined(CPUX64))}
var
  Control: Cardinal;
asm
  MOV EAX, Value
  MOV Control, EAX
  LDMXCSR Control
end;
{$ELSEIF Defined(CPUX64) and (Defined(LINUX) or Defined(MACOS))}
var
  Environment: THostFPUEnvironment;
begin
  if ReadHostEnvironment(@Environment) = 0 then
  begin
    Environment.MXCSR := Value;
    WriteHostEnvironment(@Environment);
  end;
end;
{$ELSE}
begin
end;
{$ENDIF}

end.
