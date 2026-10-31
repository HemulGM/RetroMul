program PS2LodMonotoneTest;

// Checks that System.Math.Log2 of a Single never decreases as its argument
// grows, over every positive finite Single, under round-to-nearest and
// round-toward-zero (the Vulkan GS LOD threshold tables rely on it). Exits
// with code 1 on a violation.
{$APPTYPE CONSOLE}
{$O+}{$Q-}{$R-}
{$EXCESSPRECISION OFF}

uses
  System.SysUtils, System.Math, System.Diagnostics;

function Lod(Q: Single): Single;
begin
  Result := -Log2(Q);
end;

procedure Check(Mode: TRoundingMode);
var
  Bits: Cardinal;
  Q: Single absolute Bits;
begin
  SetRoundMode(Mode);
  var Watch := TStopwatch.StartNew;
  Bits := 1;
  var Last := Lod(Q);
  var Bad: Int64 := 0;
  while Bits < $7F800000 do
  begin
    var V := Lod(Q);
    if V > Last then
    begin
      Inc(Bad);
      if Bad <= 10 then
        Writeln(Format('  not monotone at %.8x: %.9g after %.9g', [Bits, V, Last]));
    end;
    Last := V;
    Inc(Bits);
  end;
  Writeln(Format('mode %d: %d violations, %d ms', [Ord(Mode), Bad, Watch.ElapsedMilliseconds]));
  if Bad > 0 then
    ExitCode := 1;
end;

begin
  SetExceptionMask(exAllArithmeticExceptions);
  Check(rmNearest);
  Check(rmTruncate);
end.
