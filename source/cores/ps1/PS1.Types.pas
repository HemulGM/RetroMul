unit PS1.Types;

interface

uses
  System.SysUtils;

{$SCOPEDENUMS ON}

// Guest arithmetic wraps explicitly, so the core also runs with {$Q+}{$R+}.

const
  PS1CPUClock = 33868800; // 44100 Hz * 768
  PS1VideoClockNTSC = 53693175;
  PS1VideoClockPAL = 53203425;
  PS1CyclesPerSample = 768;
  PS1RAMSize = $200000;
  PS1RAMMask = PS1RAMSize - 1;
  PS1BIOSSize = $80000;
  PS1BIOSMask = PS1BIOSSize - 1;
  PS1ScratchpadSize = $400;
  PS1VRAMWidth = 1024;
  PS1VRAMHeight = 512;

type
  EPS1Error = class(Exception);

  TPS1VRAM = array[0..PS1VRAMWidth * PS1VRAMHeight - 1] of Word;

  PPS1VRAM = ^TPS1VRAM;

  // Fixed scheduler slots. The declaration order breaks ties between events
  // that are due on the same cycle, so it is part of the emulated behavior.
  TPS1Event = (GPU, Timer0, Timer1, Timer2, DMA, CDROM, CDAudio, SPU, SIO0, MDEC, GPUDraw);

  // I_STAT/I_MASK bit numbers.
  TPS1IRQ = (VBlank = 0, GPU = 1, CDROM = 2, DMA = 3, Timer0 = 4, Timer1 = 5,
    Timer2 = 6, SIO0 = 7, SIO1 = 8, SPU = 9, Lightpen = 10);

  // Sets the I_STAT bit; devices call it on the rising edge of their request.
  TPS1IRQRequest = procedure(Line: TPS1IRQ) of object;

  TPS1Notify = procedure of object;

function Add32(A, B: Cardinal): Cardinal; inline;

function Sub32(A, B: Cardinal): Cardinal; inline;

// Sign-extend the low 8/16 bits to 32 bits.
function SX8(Value: Cardinal): Cardinal; inline;

function SX16(Value: Cardinal): Cardinal; inline;

implementation

function Add32(A, B: Cardinal): Cardinal;
begin
  Result := Cardinal(UInt64(A) + B);
end;

function Sub32(A, B: Cardinal): Cardinal;
begin
  Result := Cardinal(UInt64(A) + (not B) + 1);
end;

function SX8(Value: Cardinal): Cardinal;
begin
  if (Value and $80) <> 0 then
    Result := Value or $FFFFFF00
  else
    Result := Value and $FF;
end;

function SX16(Value: Cardinal): Cardinal;
begin
  if (Value and $8000) <> 0 then
    Result := Value or $FFFF0000
  else
    Result := Value and $FFFF;
end;

end.

