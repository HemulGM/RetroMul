unit OneEmu.platform;

interface

procedure RegisterOneEmuPlatform;

implementation

uses
  RM.Platforms.NES;

procedure RegisterOneEmuPlatform;
begin
  TNESPlatform.RegisterPlatform;
end;

end.

