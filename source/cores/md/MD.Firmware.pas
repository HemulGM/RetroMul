unit MD.Firmware;

interface

uses
  System.SysUtils;

function LoadMDFirmware(const Name: string): TBytes;

implementation

uses
  System.Classes, System.Hash;

{$R 'MD.Firmware.res' 'MD.Firmware.rc'}

function LoadMDFirmware(const Name: string): TBytes;
const
  Names: array[0..6] of string = ('32x_g', '32x_m', '32x_s', 'cd_e', 'cd_j', 'cd_u', 'cd_u2');
  IDs: array[0..6] of string = ('MD_32X_G', 'MD_32X_M', 'MD_32X_S', 'MD_CD_E', 'MD_CD_J', 'MD_CD_U', 'MD_CD_U2');
  Sizes: array[0..6] of Integer = (256, 2048, 1024, 131072, 131072, 131072, 131072);
  Hashes: array[0..6] of string = (
    'dbebd76a448447cb6e524ac3cb0fd19fc065d944', '1e5b0b2441a4979b6966d942b20cc76c413b8c5e',
    '4103668c1bbd66c5e24558e73d4f3f92061a109a', 'f891e0ea651e2232af0c5c4cb46a0cae2ee8f356',
    '4846f448160059a7da0215a5df12ca160f26dd69', 'f4f315adcef9b8feb0364c21ab7f0eaf5457f3ed',
    '328a3228c29fba244b9db2055adc1ec4f7a87e6b');
begin
  for var I := 0 to High(Names) do
    if SameText(Name, Names[I]) then
    begin
      var Stream := TResourceStream.Create(HInstance, IDs[I], PChar(10));
      try
        if Stream.Size <> Sizes[I] then
          raise EReadError.Create('Invalid Sega BIOS size');
        SetLength(Result, Stream.Size);
        Stream.ReadBuffer(Result[0], Length(Result));
        var Hash := THashSHA1.Create;
        Hash.Update(Result);
        if not SameText(Hash.HashAsString, Hashes[I]) then
          raise EReadError.Create('Invalid Sega BIOS checksum');
      finally
        Stream.Free;
      end;
      Exit;
    end;
  raise EArgumentException.Create('Unknown Sega BIOS: ' + Name);
end;

end.

