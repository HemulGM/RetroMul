unit DC.Types;

interface

const
  DCCPUClock = 200000000; // SH-4 clocks per second; the scheduler's unit
  DCRAMSize = 16 * 1024 * 1024;
  DCVRAMSize = 8 * 1024 * 1024;
  DCARAMSize = 2 * 1024 * 1024;
  DCBootSize = 2 * 1024 * 1024;
  DCFlashSize = 128 * 1024;
  DCNever = High(Int64);

  // Holly SB_ISTNRM bits.
  HollyRenderDoneVideo = 0;
  HollyRenderDoneISP = 1;
  HollyRenderDoneTSP = 2;
  HollyVBlankIn = 3;
  HollyVBlankOut = 4;
  HollyHBlank = 5;
  HollyYUVDone = 6;
  HollyOpaqueDone = 7;
  HollyOpaqueModDone = 8;
  HollyTransDone = 9;
  HollyTransModDone = 10;
  HollyPVRDMA = 11;
  HollyMapleDMA = 12;
  HollyMapleVBlank = 13;
  HollyGDDMA = 14;
  HollyAICADMA = 15;
  HollyExt1DMA = 16;
  HollyExt2DMA = 17;
  HollyDevDMA = 18;
  HollyCh2DMA = 19;
  HollySortDMA = 20;
  HollyPunchThroughDone = 21;
  // SB_ISTEXT bits.
  HollyExtGDROM = 0;
  HollyExtAICA = 1;
  HollyExtModem = 2;
  HollyExtExpansion = 3;
  // SB_ISTERR bits used here.
  HollyErrISPOverflow = 0;
  HollyErrTSPOverflow = 1;
  HollyErrTAOutOfMemory = 2;
  HollyErrTAOverflow = 3;
  HollyErrMapleIllegal = 13;
  HollyErrMapleOverrun = 14;

type
  {$SCOPEDENUMS ON}
  // Each device has at most one pending event in its own slot.
  TDCEvent = (Periph, SPGLine, Render, Ch2DMA, SortDMA, PVRDMA, MapleDMA, GDROM, GDDMA, G2DMA, AICA, YUV);
  {$SCOPEDENUMS OFF}

  TDCRegion = (Japan, USA, Europe);
  TDCCable = (VGA, RGB, Composite);
  TDCBroadcast = (NTSC, PAL, PALM, PALN);

implementation

end.
