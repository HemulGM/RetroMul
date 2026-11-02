unit WS.Types;

interface

const
  WS_CLOCK = 3072000;
  WS_WIDTH = 224;
  WS_HEIGHT = 144;
  WS_LINE_CLOCKS = 256;

type
  TWSRAM = array[0..$FFFF] of Byte;

  PWSRAM = ^TWSRAM;

  TWSIO = array[0..$FF] of Byte;

  PWSIO = ^TWSIO;

implementation

end.

