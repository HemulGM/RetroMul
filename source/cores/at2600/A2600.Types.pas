unit A2600.Types;

interface

uses
  System.UITypes;

const
  A2600NTSCClock = 1193191.666666667;
  A2600PALClock = 1182298.0;
  A2600SampleRate = 44100;
  A2600ClocksPerLine = 228;
  A2600CyclesPerLine = 76;
  A2600MaxFrameLines = 400;
  A2600FrameWidth = 320;

type
  TA2600Palette = array[0..127] of TAlphaColor;

function A2600CPUClock(PAL: Boolean): Double;

function A2600FrameRate(PAL: Boolean): Double;

implementation

function A2600CPUClock(PAL: Boolean): Double;
begin
  if PAL then
    Result := A2600PALClock
  else
    Result := A2600NTSCClock;
end;

function A2600FrameRate(PAL: Boolean): Double;
begin
  if PAL then
    Result := 50
  else
    Result := A2600NTSCClock / (A2600CyclesPerLine * 262);
end;

end.

