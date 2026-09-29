unit GB.Palettes;

interface

uses
  System.UITypes;

type
  TScreenPalette = record
    Name: string;
    Colors: array[0..3] of TAlphaColor;
  end;

const
  SCREEN_PALETTE_COUNT = 8;

const
  // Shades are ordered from lightest to darkest; Original preserves the initial palette.
  // DMG/Pocket/Light and GBC presets use RGB values from Gambatte's palette table:
  // https://github.com/libretro/gambatte-libretro/blob/master/libgambatte/libretro/gbcpalettes.h
  ScreenPalettes: array[0..SCREEN_PALETTE_COUNT - 1] of TScreenPalette = (
    (Name: 'Original'; Colors: ($FFE0F8D0, $FF88C070, $FF346856, $FF081820)),
    (Name: 'Game Boy DMG'; Colors: ($FF578200, $FF317400, $FF005121, $FF00420C)),
    (Name: 'Game Boy Pocket'; Colors: ($FFA7B19A, $FF86927C, $FF535F49, $FF2A3325)),
    (Name: 'Game Boy Light'; Colors: ($FF01CBDF, $FF01B6D5, $FF269BAD, $FF00778D)),
    (Name: 'Grayscale'; Colors: ($FFFFFFFF, $FFA5A5A5, $FF525252, $FF000000)),
    (Name: 'GBC Blue'; Colors: ($FFFFFFFF, $FF63A5FF, $FF0000FF, $FF000000)),
    (Name: 'GBC Brown'; Colors: ($FFFFFFFF, $FFFFAD63, $FF843100, $FF000000)),
    (Name: 'GBC Pastel'; Colors: ($FFFFFFA5, $FFFF9494, $FF9494FF, $FF000000)));

implementation

end.

