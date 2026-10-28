unit Core.Platforms.SMS.Adapter;

interface

uses
  Core.Platforms.SG1000.Adapter;

type
  // SMS and Game Gear use the existing Sega 8-bit adapter implementation.
  TSMSCoreAdapter = Core.Platforms.SG1000.Adapter.TSGCoreAdapter;

implementation

end.
