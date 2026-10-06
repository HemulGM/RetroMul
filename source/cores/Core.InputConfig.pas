unit Core.InputConfig;

interface

uses
  System.SysUtils, System.IniFiles, Core.Storage;

type
  TCoreInputPorts = record
    Devices: array[0..7] of string;
    Multitap: array[0..1] of Boolean;
    Expansion: string;
  end;

function ReadCoreInputPorts(Ini: TCustomIniFile): TCoreInputPorts;

function LoadCoreInputPorts(const Storage: IStorage; const SystemId: string): TCoreInputPorts;

implementation

function ReadCoreInputPorts(Ini: TCustomIniFile): TCoreInputPorts;
begin
  for var I := 0 to 7 do
    Result.Devices[I] := Ini.ReadString('Ports', 'Port' + IntToStr(I + 1), 'auto').ToLower;
  for var I := 0 to 1 do
    Result.Multitap[I] := Ini.ReadBool('Input', 'Multitap' + IntToStr(I + 1), False);
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

