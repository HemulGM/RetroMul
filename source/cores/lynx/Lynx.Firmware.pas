unit Lynx.Firmware;

interface

uses
  System.SysUtils;

function LoadLynxBIOS: TBytes;

implementation

uses
  System.Classes;

{$R 'Lynx.Firmware.res' 'Lynx.Firmware.rc'}

function LoadLynxBIOS: TBytes;
begin
  var Stream := TResourceStream.Create(HInstance, 'LYNX_BOOT', PChar(10));
  try
    if Stream.Size <> 512 then
      raise EReadError.Create('Invalid built-in Lynx BIOS size');
    SetLength(Result, 512);
    Stream.ReadBuffer(Result[0], Length(Result));
  finally
    Stream.Free;
  end;
end;

end.

