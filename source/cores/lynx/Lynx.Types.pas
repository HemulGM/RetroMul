unit Lynx.Types;

interface

type
  TLynxRAM = array[0..65535] of Byte;

  PLynxRAM = ^TLynxRAM;

const
  LynxMasterClock = 16000000;
  LynxWidth = 160;
  LynxHeight = 102;
  LynxSampleRate = 44100;

implementation

end.

