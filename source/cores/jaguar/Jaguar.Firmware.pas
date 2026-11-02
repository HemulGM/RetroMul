unit Jaguar.Firmware;

interface

uses
  System.SysUtils;

function LoadJaguarBIOS: TBytes;

function LoadJaguarCDBIOS: TBytes;

function LoadJaguarNVMBIOS: TBytes;

function LoadJaguarWaveROM: TBytes;

implementation

uses
  System.Classes;

{$R 'Jaguar.Firmware.res' 'Jaguar.Firmware.rc'}

function LoadFirmware(const Name: string; Expected: Integer): TBytes;
begin
  var Stream := TResourceStream.Create(HInstance, Name, PChar(10));
  try
    if Stream.Size <> Expected then
      raise EReadError.Create('Invalid Jaguar BIOS resource');
    SetLength(Result, Expected);
    Stream.ReadBuffer(Result[0], Expected);
  finally
    Stream.Free;
  end;
end;

function LoadJaguarBIOS: TBytes;
begin
  Result := LoadFirmware('JAGUAR_BIOS', $20000);
end;

function LoadJaguarCDBIOS: TBytes;
begin
  Result := LoadFirmware('JAGUAR_CD_BIOS', $40000);
end;

function LoadJaguarNVMBIOS: TBytes;
begin
  Result := LoadFirmware('JAGUAR_NVM_BIOS', $700);
end;

function LoadJaguarWaveROM: TBytes;
begin
  Result := LoadFirmware('JAGUAR_WAVE_ROM', $1000);
end;

end.

