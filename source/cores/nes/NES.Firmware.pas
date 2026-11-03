unit NES.Firmware;

interface

uses
  NES.Types;

function LoadBuiltinFdsBIOS: NES.Types.TByteArray;

implementation

uses
  System.Classes, System.SysUtils, System.Hash;

{$R 'NES.Firmware.res' 'NES.Firmware.rc'}

function LoadBuiltinFdsBIOS: NES.Types.TByteArray;
begin
  var Stream := TResourceStream.Create(HInstance, 'FDS_BIOS', PChar(10));
  try
    if Stream.Size <> $2000 then
      raise EReadError.Create('Invalid built-in FDS BIOS size');
    SetLength(Result, Stream.Size);
    Stream.ReadBuffer(Result[0], Length(Result));
    var Hash := THashSHA1.Create;
    Hash.Update(TBytes(Result));
    if not SameText(Hash.HashAsString, '57fe1bdee955bb48d357e463ccbf129496930b62') then
      raise EReadError.Create('Invalid built-in FDS BIOS checksum');
  finally
    Stream.Free;
  end;
end;

end.

