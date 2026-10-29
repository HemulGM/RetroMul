unit A2600.Palette;

interface

uses
  A2600.Types;

procedure BuildA2600Palette(PAL: Boolean; out Palette: TA2600Palette);

implementation

uses
  System.Math;

procedure BuildA2600Palette(PAL: Boolean; out Palette: TA2600Palette);
const
  PALHues: array[0..15] of Integer = (0, 0, 2, 13, 3, 12, 4, 11, 5, 10, 6, 9, 7, 8, 0, 0);
begin
  // Analog YIQ approximation, opaque ARGB. Color zero is the grey ramp.
  for var i := 0 to 127 do
  begin
    var Hue := i div 8;
    if PAL then
      Hue := PALHues[Hue];
    var Luma := (i mod 8) * 0.125;
    var Angle := (Hue - 1) * Pi / 7 - 0.8;
    var Chroma := 0.23;
    if Hue = 0 then
      Chroma := 0;
    var U := Cos(Angle) * Chroma;
    var V := Sin(Angle) * Chroma;
    Palette[i] := $FF000000 or
      (Cardinal(EnsureRange(Round((Luma + 0.956 * U + 0.621 * V) * 255), 0, 255)) shl 16) or
      (Cardinal(EnsureRange(Round((Luma - 0.272 * U - 0.647 * V) * 255), 0, 255)) shl 8) or
      Cardinal(EnsureRange(Round((Luma - 1.106 * U + 1.703 * V) * 255), 0, 255));
  end;
end;

end.

