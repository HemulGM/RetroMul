unit PS1.Firmware;

interface

uses
  System.SysUtils, System.Classes, System.Hash, PS1.Types;

{$SCOPEDENUMS ON}

type
  TPS1Region = (Unknown, Japan, NorthAmerica, Europe);

  TPS1BIOSInfo = record
    Known: Boolean;
    Name: string;
    Region: TPS1Region;
    OpenBIOS: Boolean;
  end;

const
  PS1BuiltinOpenBIOS = 'openbios.bin';
  // Libreboot 26.10rev9 roms/playstation/openbios.bin (see firmware/manifest.json).
  PS1OpenBIOSSHA256 = 'da0bf3d3e0bf75d4bea49c037f9d0639d75c3ff4a569659965e04b9809b707c5';

// Identifies a 512 KiB BIOS image by hash; unknown images are reported as such.
function IdentifyPS1BIOS(const Data: TBytes): TPS1BIOSInfo;

function HasBuiltinPS1BIOS: Boolean;

// Loads a BIOS embedded as a resource, verifying size and SHA-256.
function LoadBuiltinPS1BIOS(const Name: string): TBytes;

implementation

// firmware/openbios.bin (MIT PCSX-Redux and uC-sdk notices in
// firmware/LICENSE.openbios.txt).
{$R 'PS1.Firmware.res' 'PS1.Firmware.rc'}

type
  TKnownBIOS = record
    SHA1, Name: string;
    Region: TPS1Region;
  end;

const
  // Retail dumps (SHA-1 of the 512 KiB image).
  KnownBIOS: array[0..14] of TKnownBIOS = (
    (SHA1: '343883a7b555646da8cee54aadd2795b6e7dd070'; Name: 'SCPH-1000'; Region: TPS1Region.Japan),
    (SHA1: '10155d8d6e6e832d6ea66db9bc098321fb5e8ebf'; Name: 'SCPH-1001'; Region: TPS1Region.NorthAmerica),
    (SHA1: '20b98f3d80f11cbf5a7bfd0779b0e63760ecc62c'; Name: 'SCPH-1002'; Region: TPS1Region.Europe),
    (SHA1: 'b06f4a861f74270be819aa2a07db8d0563a7cc4e'; Name: 'SCPH-3000'; Region: TPS1Region.Japan),
    (SHA1: 'e38466a4ba8005fba7e9e3c7b9efeba7205bee3f'; Name: 'SCPH-3500'; Region: TPS1Region.Japan),
    (SHA1: 'e340db2696274dda5fdc25e434a914db71e8b02b'; Name: 'SCPH-5000'; Region: TPS1Region.Japan),
    (SHA1: 'b05def971d8ec59f346f2d9ac21fb742e3eb6917'; Name: 'SCPH-5500'; Region: TPS1Region.Japan),
    (SHA1: '0555c6fae8906f3f09baf5988f00e55f88e9f30b'; Name: 'SCPH-5501/7003'; Region: TPS1Region.NorthAmerica),
    (SHA1: 'f6bc2d1f5eb6593de7d089c425ac681d6fffd3f0'; Name: 'SCPH-5502/5552'; Region: TPS1Region.Europe),
    (SHA1: '14df4f6c1e367ce097c11deae21566b4fe5647a9'; Name: 'SCPH-7001'; Region: TPS1Region.NorthAmerica),
    (SHA1: '8d5de56a79954f29e9006929ba3fed9b6a418c1d'; Name: 'SCPH-7002/7502/9002'; Region: TPS1Region.Europe),
    (SHA1: '339a48f4fcf63e10b5b867b8c93cfd40945faf6c'; Name: 'SCPH-100'; Region: TPS1Region.Japan),
    (SHA1: 'dcffe16bd90a723499ad46c641424981338d8378'; Name: 'SCPH-101'; Region: TPS1Region.NorthAmerica),
    (SHA1: 'beb0ac693c0dc26daf5665b3314db81480fa5c7c'; Name: 'SCPH-102 (A)'; Region: TPS1Region.Europe),
    (SHA1: 'dbc7339e5d85827c095764fc077b41f78fd2ecae'; Name: 'SCPH-102 (B)'; Region: TPS1Region.Europe));
  BuiltinNames: array[0..0] of string = (PS1BuiltinOpenBIOS);
  BuiltinResources: array[0..0] of string = ('PS1_OPENBIOS');
  BuiltinHashes: array[0..0] of string = (PS1OpenBIOSSHA256);
  ResourceType = PChar(10); // RCDATA

function IdentifyPS1BIOS(const Data: TBytes): TPS1BIOSInfo;
begin
  Result := Default(TPS1BIOSInfo);
  Result.Name := 'Unrecognized BIOS';
  if Length(Data) <> PS1BIOSSize then
    Exit;

  var SHA256 := THashSHA2.Create;
  SHA256.Update(Data);
  if SameText(SHA256.HashAsString, PS1OpenBIOSSHA256) then
  begin
    Result.Known := True;
    Result.OpenBIOS := True;
    Result.Name := 'OpenBIOS (PCSX-Redux)';
    Exit;
  end;
  var SHA1 := THashSHA1.Create;
  SHA1.Update(Data);
  var Digest := SHA1.HashAsString;
  for var Item in KnownBIOS do
    if SameText(Item.SHA1, Digest) then
    begin
      Result.Known := True;
      Result.Name := Item.Name;
      Result.Region := Item.Region;
      Exit;
    end;
end;

function HasBuiltinPS1BIOS: Boolean;
begin
  Result := FindResource(HInstance, PChar(BuiltinResources[0]), ResourceType) <> 0;
end;

function LoadBuiltinPS1BIOS(const Name: string): TBytes;
begin
  for var I := Low(BuiltinNames) to High(BuiltinNames) do
    if SameText(Name, BuiltinNames[I]) then
    begin
      if FindResource(HInstance, PChar(BuiltinResources[I]), ResourceType) = 0 then
        raise EPS1Error.CreateFmt('Built-in PS1 BIOS %s is not included in this build', [Name]);
      var Stream := TResourceStream.Create(HInstance, BuiltinResources[I], ResourceType);
      try
        if Stream.Size <> PS1BIOSSize then
          raise EPS1Error.Create('Invalid built-in PS1 BIOS size');
        SetLength(Result, Stream.Size);
        Stream.ReadBuffer(Result[0], Length(Result));
      finally
        Stream.Free;
      end;
      var Hash := THashSHA2.Create;
      Hash.Update(Result);
      if not SameText(Hash.HashAsString, BuiltinHashes[I]) then
        raise EPS1Error.Create('Built-in PS1 BIOS failed its SHA-256 check');
      Exit;
    end;
  raise EPS1Error.CreateFmt('Unknown built-in PS1 BIOS: %s', [Name]);
end;

end.

