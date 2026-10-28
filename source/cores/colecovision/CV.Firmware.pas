unit CV.Firmware;

interface

uses
  System.SysUtils;

function LoadBuiltinColecoBIOS: TBytes;

function ColecoBIOSForRegion(const BIOS: TBytes; PAL: Boolean): TBytes;

implementation

uses
  System.Classes, System.Hash;

{$R 'CV.Firmware.res' 'CV.Firmware.rc'}

function ColecoBIOSForRegion(const BIOS: TBytes; PAL: Boolean): TBytes;
begin
  Result := Copy(BIOS);
  var Hash := THashSHA1.Create;
  Hash.Update(Result);
  // AMERICA is the documented BIOS region byte. Only adapt our verified
  // stock image; custom firmware (including diagnostic NMI handlers) is data.
  if (Length(Result) = $2000) and
    SameText(Hash.HashAsString, '45bedc4cbdeac66c7df59e9e599195c778d86a92') then
    if PAL then
      Result[$69] := 50
    else
      Result[$69] := 60;
end;

function LoadBuiltinColecoBIOS: TBytes;
begin
  var Stream := TResourceStream.Create(HInstance, 'COLECO_BIOS', PChar(10));
  try
    if Stream.Size <> $2000 then
      raise EReadError.Create('Invalid built-in ColecoVision BIOS size');
    SetLength(Result, Stream.Size);
    Stream.ReadBuffer(Result[0], Length(Result));
    var Hash := THashSHA1.Create;
    Hash.Update(Result);
    if not SameText(Hash.HashAsString, '45bedc4cbdeac66c7df59e9e599195c778d86a92') then
      raise EReadError.Create('Invalid built-in ColecoVision BIOS checksum');
  finally
    Stream.Free;
  end;
end;

end.

