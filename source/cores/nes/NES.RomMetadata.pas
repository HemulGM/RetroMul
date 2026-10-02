unit NES.RomMetadata;

interface

uses
  NES.Types, NES.Mapper;

function ResolveLegacyMapper(Declared: Integer; const Prg, Chr: NES.Types.TByteArray): Integer;

function IsLegacyPalRom(const Prg, Chr: NES.Types.TByteArray): Boolean;

function ResolveLegacyMirror(Declared: TMirrorMode; const Prg, Chr: NES.Types.TByteArray): TMirrorMode;

function IsLegacyBatteryRom(const Sha1: string): Boolean;

function IsLegacyPowerPadRom(const Sha1: string): Boolean;

function IsLegacyFamicomKeyboardRom(const Sha1: string): Boolean;

function IsLegacyDataRecorderRom(const Sha1: string): Boolean;

implementation

uses
  System.Hash, System.SysUtils;

function IsLegacyDataRecorderRom(const Sha1: string): Boolean;
const
  // Exact PRG+CHR identities; puNES nes20db.xml expansion type 32.
  Identities: array[0..7] of string = (
    'dee513dad7223cfc81bcd859d0aac6746349cb25', // Wrecking Crew
    'ba8d9227a0d02b62ee6cb9e691fa5a5134c303a8', // Excitebike NTSC
    '6281d62c1cbb34b1734d20747a8e3d8de2af1443', // Excitebike PAL
    '8363d8f95cc29cbf4191640e6bb25009dcaf5fb0', // Excitebike F1023 (collection dump)
    '3959de9e2f63b34bc992a60ddcc73027f401dc64', // Mach Rider NTSC rev0
    '65caac674f3847ed46654313382ecc0f854a0f54', // Mach Rider NTSC rev1
    'a322ba4cefaff2668763cc20491fcbfcace7347e', // Mach Rider PAL
    // Collection Machrider variant; not listed in puNES, canonical Mach Rider CHR.
    '8eb7512c7b6fefd332a6c667c76017a443692645');
begin
  for var Identity in Identities do
    if SameText(Sha1, Identity) then
      Exit(True);
  Result := False;
end;

type
  TMapperIdentity = record
    Declared, Actual: Integer;
    Sha1: string;
  end;

const
  MAPPER_IDENTITIES: array[0..15] of TMapperIdentity = (
    (Declared: 2; Actual: 1; Sha1: '5b05c8859f356013d37f0545f5de5fa1693da5da'),
    (Declared: 2; Actual: 206; Sha1: '881b6413fbcbfb9a0308583f0510c09283a72d2a'),
    (Declared: 70; Actual: 152; Sha1: '627d4f20667eded6f26a379c8477669348f3ecab'),
    (Declared: 88; Actual: 154; Sha1: 'ce34b12a46ae8d4432d06f461342f729e8be35e6'),
    (Declared: 16; Actual: 159; Sha1: '4037db53d45db20e3a131d722dcd317adc966deb'),
    (Declared: 8; Actual: 79; Sha1: '04e42ef95de5c857c560b67743310f8777980745'),
    (Declared: 15; Actual: 0; Sha1: 'efe9dd039206c59420ecd58436ef0cd8e640e30c'),
    (Declared: 71; Actual: 232; Sha1: '6f288136923adfa0b1dc7c5ca5782bf0892dfce1'),
    (Declared: 90; Actual: 209; Sha1: '2e0889131da5ba9505a15b94887113f4360d98cd'),
    (Declared: 12; Actual: 13; Sha1: '3e24edd8c06713b775eaa66f3468f71693a542a9'),
    (Declared: 11; Actual: 144; Sha1: '80cd18bb63a5b52b1f3ad36c9191845eb29dd807'),
    (Declared: 4; Actual: 119; Sha1: 'b3537088ed6f8379f2c30ca45061bfccba1007b9'),
    (Declared: 0; Actual: 3; Sha1: '4970ab23575cfd29db8f95d4f8fa34169478ca6a'),
    (Declared: 0; Actual: 3; Sha1: 'f3658b888b21f2ebff1d3f373f3b58486815468e'),
    (Declared: 7; Actual: 11; Sha1: '3e814b7307730e30ec6067cb4487f2a826a3f7d6'),
    (Declared: 7; Actual: 79; Sha1: '1d3b449f06d9698a42cd6255e684d313d1dd98bf'));

function IsLegacyPowerPadRom(const Sha1: string): Boolean;
begin
  // Exact legacy payloads, Power Pad side B. Super Team Games is also
  // identified as expansion device 12 in puNES misc/nes20db.xml.
  Result := SameText(Sha1, '0380a74aad3771edf2b37c739c489832ebe6d06b') or
    SameText(Sha1, 'e26f34a8a4c9419a8a90b0346fde019e8ab5aad2') or
    SameText(Sha1, 'ea660abbc1cdb74e85f932e38013e4fa5b9f6bb8');
end;

function IsLegacyFamicomKeyboardRom(const Sha1: string): Boolean;
begin
  // Family BASIC v1.0, v2.0, v2.1 and v3.0 payloads from puNES nes20db.xml.
  Result := SameText(Sha1, '4e819c20f41e06059f4336e05b4cbad52551423b') or
    SameText(Sha1, '17720ae1afc6a3750384d6b082391c0c2f8a0699') or
    SameText(Sha1, '8e90d9a6a6090307a7e408d1c1704d09ba8f94fc') or
    SameText(Sha1, 'e232c621bfedbfc6b100677bfbfc50b910248282');
end;

function IsLegacyBatteryRom(const Sha1: string): Boolean;
const
  // Exact legacy payloads confirmed by FCEUmm ines-correct.h (236ccdfc).
  Identities: array[0..10] of string = (
    '4037db53d45db20e3a131d722dcd317adc966deb' { Dragon Ball Z.nes },
    '63347651e2405bc6e50dff42f050c60332221e03' { Gemfire (U).nes },
    '50e76171aa106895c745e7a4f8d9852db72aad12' { Heros of the Lance.nes },
    '6197d576dd1c2a2304be82b7be6768a13c40bcf9' { L'Empereur (U).nes },
    '66031e07d25b899ea3175a222c3939568d874883' { Nobunaga's Ambition 2 (U).nes },
    'd9fe4f00109b7d75456e1673c2b30de68a125a5b' { Nobunaga's Ambition.nes },
    '39f9094927fc87373f021244aabdc4db1e1c8f37' { Romance of the Three Kingdoms 2 (U).nes },
    '209911d7bd15abb7bef2e35a473df725b6738cd7' { Secret Legacy of the Mongol Dynasty.nes },
    'fcb1ef7398b842ebd28c3227852d7a132ce7b887' { Startropics 2 - Zoda's Revenge.nes },
    '74c53fe9ac779f146c59ac01e701c9bf912b3c7b' { Startropics.nes },
    '37267833c984f176db4b0bc9d45daba0fff45304' { Uncharted Waters (U).nes });
begin
  for var Identity in Identities do
    if SameText(Sha1, Identity) then
      Exit(True);
  Result := False;
end;

function ResolveLegacyMirror(Declared: TMirrorMode; const Prg, Chr: NES.Types.TByteArray): TMirrorMode;
const
  // Exact payloads; board wiring confirmed in puNES misc/nes20db.xml.
  Horizontal: array[0..1] of string = (
    '121a482aa2b2808d98d4070b4b6598d851334f54',  // Battle Storm
    'bf03da873d76a87ab669688d0c47d7554c08c176'); // Due K
  Vertical: array[0..5] of string = (
    '847d56e43754e402666a91188520737094e9ecfa',  // Castelia
    '4970ab23575cfd29db8f95d4f8fa34169478ca6a',  // Ninja Kid
    'f3658b888b21f2ebff1d3f373f3b58486815468e',  // Pipe Dream
    '3e814b7307730e30ec6067cb4487f2a826a3f7d6',  // Silent Assault
    '1d3b449f06d9698a42cd6255e684d313d1dd98bf',  // Tiles of Fate
    '047e37f639f36f1e5eb251c9b31b433052fd64b3'); // Track and Field }
begin
  Result := Declared;
  if Length(Prg) = 0 then
    Exit;
  var PayloadHash := THashSHA1.Create;
  PayloadHash.Update(Prg[0], Length(Prg));
  if Length(Chr) > 0 then
    PayloadHash.Update(Chr[0], Length(Chr));
  var Identity := PayloadHash.HashAsString;
  for var Entry in Horizontal do
    if SameText(Identity, Entry) then
      Exit(TMirrorMode.Horizontal);
  for var Entry in Vertical do
    if SameText(Identity, Entry) then
      Exit(TMirrorMode.Vertical);
  if (Declared <> TMirrorMode.Horizontal) or (Length(Prg) <> $20000) or (Length(Chr) <> 0) then
    Exit;
  var Hash := THashSHA1.Create;
  Hash.Update(Prg[0], Length(Prg));
  // Super Cars (USA), PRG CRC32 419461D0: NES-UNROM, vertical CIRAM wiring.
  // https://nescartdb.com/profile/view/1033/super-cars
  if SameText(Hash.HashAsString, '4f55afaf521841b3d50f8076be674321c1cf4623') then
    Result := TMirrorMode.Vertical;
end;

function IsLegacyPalRom(const Prg, Chr: NES.Types.TByteArray): Boolean;
begin
  Result := False;
  // Asterix: confirmed against PAL/NTSC runs; this legacy dump has byte 9 = 0.
  // Match payload identity, never a filename or all cartridges on mapper 2.
  if (Length(Prg) <> $20000) or (Length(Chr) <> 0) then
    Exit;
  var Hash := THashSHA1.Create;
  Hash.Update(Prg[0], Length(Prg));
  Result := SameText(Hash.HashAsString, '7b0b8d19bd56aa255501852136828300ee2d2457') or
    SameText(Hash.HashAsString, 'fcf9ff27f097892148eaec439ab79bc53164d751'); { Elite PAL }
end;

function ResolveLegacyMapper(Declared: Integer; const Prg, Chr: NES.Types.TByteArray): Integer;
begin
  Result := Declared;
  var Relevant := False;
  for var entry in MAPPER_IDENTITIES do
    Relevant := Relevant or (entry.Declared = Declared);
  if not Relevant or (Length(Prg) = 0) then
    Exit;
  var Hash := THashSHA1.Create;
  Hash.Update(Prg[0], Length(Prg));
  if Length(Chr) > 0 then
    Hash.Update(Chr[0], Length(Chr));
  var Digest := Hash.HashAsString;
  for var entry in MAPPER_IDENTITIES do
    if (entry.Declared = Declared) and SameText(entry.Sha1, Digest) then
      Exit(entry.Actual);
end;

end.

