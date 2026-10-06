unit Core.InputConfig;

interface

uses
  System.SysUtils, System.IniFiles, Core.Storage;

type
  TCoreInputPorts = record
    Devices: array[0..3] of string;
    Expansion: string;
  end;

function ReadCoreInputPorts(Ini: TCustomIniFile): TCoreInputPorts;

function LoadCoreInputPorts(const Storage: IStorage; const SystemId: string): TCoreInputPorts;

implementation

function ReadCoreInputPorts(Ini: TCustomIniFile): TCoreInputPorts;
begin
  for var I := 0 to 3 do
    Result.Devices[I] := Ini.ReadString('Ports', 'Port' + IntToStr(I + 1), 'auto').ToLower;
  Result.Expansion := Ini.ReadString('Ports', 'Expansion', 'auto').ToLower;
end;

function LoadCoreInputPorts(const Storage: IStorage; const SystemId: string): TCoreInputPorts;
begin
  var Ini := Storage.ReadConfig(Storage.ConfigFile(SystemId));
  try
    Result := ReadCoreInputPorts(Ini);
  finally
    Ini.Free;
  end;
end;

end.

