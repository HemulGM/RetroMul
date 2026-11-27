unit INTV.Firmware;

interface

uses
  System.SysUtils;

function LoadBuiltinIntvFirmware(const Name: string): TBytes;

implementation

uses
  System.Classes, System.Hash;

{$R 'INTV.Firmware.res' 'INTV.Firmware.rc'}

function LoadBuiltinIntvFirmware(const Name: string): TBytes;
const
  Names: array[0..11] of string = (
    'exec.bin',
    'grom.bin',
    'exec2.bin',
    'searsexc.bin',
    'ecs.bin',
    'ivoice.bin',
    'wbexec.bin',
    'wbgrom.bin',
    'kbd-master.bin',
    'kbd-6502.bin',
    'kbd-font.bin',
    'kbd-basic.bin');
  Resources: array[0..11] of string = (
    'INTV_EXEC',
    'INTV_GROM',
    'INTV_EXEC2',
    'INTV_SEARSEXC',
    'INTV_ECS',
    'INTV_IVOICE',
    'INTV_WBEXEC',
    'INTV_WBGROM',
    'INTV_KBD_MASTER',
    'INTV_KBD_6502',
    'INTV_KBD_FONT',
    'INTV_KBD_BASIC');
  Sizes: array[0..11] of Integer = (
    8192,
    2048,
    8704,
    8192,
    24576,
    2048,
    16384,
    2048,
    8192,
    8192,
    2048,
    8192);
  Hashes: array[0..11] of string = (
    '1aeb614856beba95463166daf09304b414d5617d3f37d221724b3337fc4b2722',
    'a80b6841182547d08635ad30a6af71441c4c9eed9391b3dd22feb30d8e50cc85',
    'f96630a51878b11ce5f97d1b26970bca4870eaff01feed492a207d43940b5f28',
    '3b134a447ed5a335122328aa85f9bb0e268c33428470288cddb7225e1d1f3a76',
    '2fcea60039c4a8836b9bb71e391d70a145c724b4dae516be733fe842ba6687c7',
    'dabade432af1523f43029057071ca8c1ed3604498c784603e8733023382ad7a5',
    '28b83e8fdaf8dcc58f9526cffd71fd722876278d29ea3d1300c245c0fc15f309',
    '81457b6601f81a9b622a61b3f30b34b51159f2ca38aa1bbbabde22dbd78aa795',
    'ad5b6b0312dafe1dae40e4617843555e1f8240e0dc2ddf078f793ea2c6165a04',
    'cf494e3322962691136f995dab7e1a10dd04420c6c02c09a742bc8a6cb1e0d80',
    '6e8f4f76999996fd89a44eef9b5fa6c8b7b913ee5eaef5b96405d01d2a103165',
    '14ca57cb99c792e5afb71c80aef43cfe9cd01246b802bd933e37deff427aa704');
begin
  Result := nil;
  var Key := Name;
  if SameText(Key, 'kbd-exec.bin') then
    Key := 'exec.bin';
  if SameText(Key, 'kbd-grom.bin') then
    Key := 'grom.bin';
  if SameText(Key, 'sp0256-012.bin') or SameText(Key, '012.bin') then
    Key := 'ivoice.bin';
  for var Index := Low(Names) to High(Names) do
    if SameText(Key, Names[Index]) then
    begin
      var Stream := TResourceStream.Create(HInstance, Resources[Index], PChar(10));
      try
        if Stream.Size <> Sizes[Index] then
          raise EReadError.Create('Invalid built-in Intellivision firmware size: ' + Name);
        SetLength(Result, Stream.Size);
        Stream.ReadBuffer(Result[0], Length(Result));
        var Hash := THashSHA2.Create;
        Hash.Update(Result);
        if not SameText(Hash.HashAsString, Hashes[Index]) then
          raise EReadError.Create('Invalid built-in Intellivision firmware checksum: ' + Name);
      finally
        Stream.Free;
      end;
      Exit;
    end;
end;

end.

