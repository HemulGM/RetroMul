unit Core.EmulatorFactory;

interface

uses
  System.SysUtils, System.IOUtils, Core.Emulation;

function CreateEmulationCore(const FileName: string): IEmulationCore;

implementation

uses
  Core.Adapter.NES, Core.Adapter.GB, Core.Adapter.GBC, Core.Adapter.MD;

function CreateEmulationCore(const FileName: string): IEmulationCore;
var
  Extension: string;
begin
  Extension := TPath.GetExtension(FileName).ToLower;
  if Extension = '.nes' then
    Result := TNesCoreAdapter.Create(FileName)
  else if Extension = '.gb' then
    Result := TGBCoreAdapter.Create(FileName)
  else if Extension = '.gbc' then
    Result := TGBCCoreAdapter.Create(FileName)
  else if (Extension = '.md') or (Extension = '.gen') or
    (Extension = '.bin') or (Extension = '.smd') then
    Result := TMDCoreAdapter.Create(FileName)
  else
    raise Exception.Create('Unsupported ROM type. Choose .nes, .gb, .gbc, .md, .gen, .bin or .smd');
end;

end.

