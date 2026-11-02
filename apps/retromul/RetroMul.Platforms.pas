unit RetroMul.Platforms;

interface

implementation

uses
  RM.Platforms.Atari7800, RM.Platforms.Jaguar, RM.Platforms.Lynx,
  RM.Platforms.Atari5200, RM.Platforms.Atari2600, RM.Platforms.CPS,
  RM.Platforms.DC, RM.Platforms.GameWatch, RM.Platforms.GB, RM.Platforms.NDS,
  RM.Platforms.GBA, RM.Platforms.GBC, RM.Platforms.MD, RM.Platforms.MSX,
  RM.Platforms.N64, RM.Platforms.NeoGeo, RM.Platforms.NES, RM.Platforms.WS,
  RM.Platforms.NGP, RM.Platforms.PCE, RM.Platforms.PS1, RM.Platforms.PSP,
  RM.Platforms.Saturn, RM.Platforms.SG1000, RM.Platforms.SMS, RM.Platforms.SNES,
  RM.Platforms.ZX, RM.Platforms.ColecoVision;

initialization
  TA7800Platform.RegisterPlatform;
  TJaguarPlatform.RegisterPlatform;
  TLynxPlatform.RegisterPlatform;
  TA5200Platform.RegisterPlatform;
  TA2600Platform.RegisterPlatform;
  TColecoVisionPlatform.RegisterPlatform;
  TCPSPlatform.RegisterPlatform;
  TDCPlatform.RegisterPlatform;
  TGWPlatform.RegisterPlatform;
  TGBPlatform.RegisterPlatform;
  TGBAPlatform.RegisterPlatform;
  TNDSPlatform.RegisterPlatform;
  TGBCPlatform.RegisterPlatform;
  TMDPlatform.RegisterPlatform;
  TMSXPlatform.RegisterPlatform;
  TN64Platform.RegisterPlatform;
  TNeoGeoPlatform.RegisterPlatform;
  TNESPlatform.RegisterPlatform;
  TNGPPlatform.RegisterPlatform;
  TWSPlatform.RegisterPlatform;
  TPCEPlatform.RegisterPlatform;
  TPS1Platform.RegisterPlatform;
  TPSPPlatform.RegisterPlatform;
  TSaturnPlatform.RegisterPlatform;
  TSG1000Platform.RegisterPlatform;
  TSMSPlatform.RegisterPlatform;
  TSNESPlatform.RegisterPlatform;
  TZXPlatform.RegisterPlatform;

end.

