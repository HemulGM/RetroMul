unit A5200.Firmware;

interface

uses
  System.SysUtils;

function LoadBuiltinAtari5200BIOS: TBytes;

implementation

uses
  System.Classes, System.Hash;

{$R 'A5200.Firmware.res' 'A5200.Firmware.rc'}

function LoadBuiltinAtari5200BIOS: TBytes;
begin
  var Stream := TResourceStream.Create(HInstance, 'ATARI5200_BIOS', PChar(10));
  try
    if Stream.Size <> 2048 then
      raise EReadError.Create('Invalid Atari 5200 BIOS size');
    SetLength(Result, 2048);
    Stream.ReadBuffer(Result[0], 2048);
    var Hash := THashSHA2.Create;
    Hash.Update(Result);
    if not SameText(Hash.HashAsString, '06b250f18983d058c0f156ce7ee88ae48b6eaf11e6f10f21dccf6ac7ffb6a6af') then
      raise EReadError.Create('Invalid Atari 5200 BIOS checksum');
  finally
    Stream.Free;
  end;
end;

end.
