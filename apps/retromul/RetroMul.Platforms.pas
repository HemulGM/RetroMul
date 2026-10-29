unit RetroMul.Platforms;

interface

implementation

uses
  RM.Platforms.Atari5200, RM.Platforms.Atari2600, RM.Platforms.CPS, RM.Platforms.DC, RM.Platforms.GameWatch, RM.Platforms.GB,
  RM.Platforms.GBA, RM.Platforms.GBC, RM.Platforms.MD, RM.Platforms.MSX,
  RM.Platforms.N64, RM.Platforms.NeoGeo, RM.Platforms.NES, RM.Platforms.NGP,
  RM.Platforms.PCE, RM.Platforms.PS1, RM.Platforms.PSP, RM.Platforms.Saturn,
  RM.Platforms.SG1000, RM.Platforms.SMS, RM.Platforms.SNES, RM.Platforms.ZX,
  RM.Platforms.ColecoVision, System.SysUtils;

initialization
  TA5200Platform.RegisterPlatform;
  TA2600Platform.RegisterPlatform;
  TColecoVisionPlatform.RegisterPlatform;
  TCPSPlatform.RegisterPlatform;
  TDCPlatform.RegisterPlatform;
  TGWPlatform.RegisterPlatform;
  TGBPlatform.RegisterPlatform;
  TGBAPlatform.RegisterPlatform;
  TGBCPlatform.RegisterPlatform;
  TMDPlatform.RegisterPlatform;
  TMSXPlatform.RegisterPlatform;
  TN64Platform.RegisterPlatform;
  TNeoGeoPlatform.RegisterPlatform;
  TNESPlatform.RegisterPlatform;
  TNGPPlatform.RegisterPlatform;
  TPCEPlatform.RegisterPlatform;
  TPS1Platform.RegisterPlatform;
  TPSPPlatform.RegisterPlatform;
  TSaturnPlatform.RegisterPlatform;
  TSG1000Platform.RegisterPlatform;
  TSMSPlatform.RegisterPlatform;
  TSNESPlatform.RegisterPlatform;
  TZXPlatform.RegisterPlatform;

end.

