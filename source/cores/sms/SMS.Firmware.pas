unit SMS.Firmware;

interface

uses
  System.SysUtils;

function LoadBuiltinSMSBIOS(Japanese: Boolean): TBytes;

function DefaultSMSBIOSJapanese(const ROM: TBytes): Boolean;

implementation

uses
  System.Classes, System.Hash;

{$R 'SMS.Firmware.res' 'SMS.Firmware.rc'}

function LoadBuiltinSMSBIOS(Japanese: Boolean): TBytes;
const
  IDs: array[Boolean] of string = ('SMS_BIOS_EXPORT', 'SMS_BIOS_JAPAN');
  Hashes: array[Boolean] of string = (
    'c315672807d8ddb8d91443729405c766dd95cae7',
    'a8c1b39a2e41137835eda6a5de6d46dd9fadbaf2');
begin
  var Stream := TResourceStream.Create(HInstance, IDs[Japanese], PChar(10));
  try
    if Stream.Size <> 8192 then
      raise EReadError.Create('Invalid built-in SMS BIOS size');
    SetLength(Result, Stream.Size);
    Stream.ReadBuffer(Result[0], Length(Result));
    var Hash := THashSHA1.Create;
    Hash.Update(Result);
    if not SameText(Hash.HashAsString, Hashes[Japanese]) then
      raise EReadError.Create('Invalid built-in SMS BIOS checksum');
  finally
    Stream.Free;
  end;
end;

function DefaultSMSBIOSJapanese(const ROM: TBytes): Boolean;
begin
  // The export BIOS authenticates the export cartridge header; the Japanese
  // BIOS can also start Japanese and headerless homebrew cartridges.
  Result := True;
  var Start := 0;
  if Length(ROM) mod $4000 = 512 then
    Start := 512;
  for var Offset in [$7FF0, $3FF0, $1FF0] do
    if (Length(ROM) >= Start + Offset + 16) and
      CompareMem(@ROM[Start + Offset], PAnsiChar(AnsiString('TMR SEGA')), 8) then
      Exit(ROM[Start + Offset + 15] shr 4 <> 4);
end;

end.

