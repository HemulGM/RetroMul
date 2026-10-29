unit A5200.Types;

interface

uses
  System.UITypes;

const
  A5200CPUClock = 1789772.0;
  A5200CyclesPerLine = 114;
  A5200LinesPerFrame = 262;
  A5200Width = 384;
  A5200Height = 240;

type
  TA5200Read = function(Address: Word): Byte of object;

  TA5200Scanline = array[0..455] of Byte;

  TA5200Palette = array[0..255] of TAlphaColor;

implementation

end.

