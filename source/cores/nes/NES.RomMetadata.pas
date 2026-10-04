unit NES.RomMetadata;

interface

uses
  NES.Types, NES.Mapper;

function ResolveLegacyMapper(Declared: Integer; const Prg, Chr: NES.Types.TByteArray): Integer;

function IsLegacyPalRom(const Prg, Chr: NES.Types.TByteArray): Boolean;

function ResolveLegacyMirror(Declared: TMirrorMode; const Prg, Chr: NES.Types.TByteArray): TMirrorMode;

function IsLegacyBatteryRom(const Sha1: string): Boolean;

function IsLegacyMmc6Rom(const Sha1: string): Boolean;

function IsLegacyPowerPadRom(const Sha1: string): Boolean;

function IsLegacyFamicomKeyboardRom(const Sha1: string): Boolean;

function IsLegacyDataRecorderRom(const Sha1: string): Boolean;

implementation

uses
  Core.RomHashes, System.Hash, System.SysUtils;

function IsLegacyMmc6Rom(const Sha1: string): Boolean;
begin
  // Exact HKROM payloads; legacy iNES has no MMC6 submapper field.
  Result :=
    SameText(Sha1, ROM_NES_STARTROPICS_SHA1) or
    SameText(Sha1, ROM_NES_STARTROPICS_2_ZODA_S_REVENGE_SHA1);
end;

function IsLegacyDataRecorderRom(const Sha1: string): Boolean;
const
  // Exact PRG+CHR identities; puNES nes20db.xml expansion type 32.
  Identities: array[0..7] of string = (
    ROM_NES_WRECKING_CREW_SHA1, // Wrecking Crew
    ROM_NES_EXCITEBIKE_NTSC_SHA1, // Excitebike NTSC
    ROM_NES_EXCITEBIKE_PAL_SHA1, // Excitebike PAL
    ROM_NES_EXCITEBIKE_F1023_SHA1, // Excitebike F1023 (collection dump)
    ROM_NES_MACH_RIDER_NTSC_REV0_SHA1, // Mach Rider NTSC rev0
    ROM_NES_MACH_RIDER_NTSC_REV1_SHA1, // Mach Rider NTSC rev1
    ROM_NES_MACH_RIDER_PAL_SHA1, // Mach Rider PAL
    // Collection Machrider variant; not listed in puNES, canonical Mach Rider CHR.
    ROM_NES_MACH_RIDER_COLLECTION_SHA1);
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
    (Declared: MAPPER_UXROM; Actual: MAPPER_MMC1; Sha1: ROM_NES_FAXANADU_SHA1),
    (Declared: MAPPER_UXROM; Actual: MAPPER_DXROM; Sha1: ROM_NES_VS_SUPER_XEVIOUS_SHA1),
    (Declared: MAPPER_BANDAI_70; Actual: MAPPER_BANDAI_152; Sha1: ROM_NES_ARKANOID_2_SHA1),
    (Declared: MAPPER_NAMCO_118; Actual: MAPPER_NAMCO_154; Sha1: ROM_NES_DEVILMAN_SHA1),
    (Declared: MAPPER_BANDAI_FCG; Actual: MAPPER_BANDAI_159; Sha1: ROM_NES_DRAGON_BALL_Z_SHA1),
    (Declared: MAPPER_FFE_F3XXX; Actual: MAPPER_NINA03; Sha1: ROM_NES_MERMAIDS_OF_ATLANTIS_SHA1),
    (Declared: MAPPER_MULTICART_15; Actual: MAPPER_NROM; Sha1: ROM_NES_PACHICOM_SHA1),
    (Declared: MAPPER_CAMERICA; Actual: MAPPER_CAMERICA_QUATTRO; Sha1: ROM_NES_QUATTRO_SPORTS_SHA1),
    (Declared: MAPPER_JY_90; Actual: MAPPER_JY_209; Sha1: ROM_NES_SAMURAI_SPIRITS_2_SHA1),
    (Declared: MAPPER_MMC3_12; Actual: MAPPER_CPROM; Sha1: ROM_NES_VIDEOMATION_SHA1),
    (Declared: MAPPER_COLOR_DREAMS; Actual: MAPPER_AGCI; Sha1: ROM_NES_DEATH_RACE_SHA1),
    (Declared: MAPPER_MMC3; Actual: MAPPER_TQROM; Sha1: ROM_NES_PINBOT_SHA1),
    (Declared: MAPPER_NROM; Actual: MAPPER_CNROM; Sha1: ROM_NES_NINJA_KID_SHA1),
    (Declared: MAPPER_NROM; Actual: MAPPER_CNROM; Sha1: ROM_NES_PIPE_DREAM_SHA1),
    (Declared: MAPPER_AXROM; Actual: MAPPER_COLOR_DREAMS; Sha1: ROM_NES_SILENT_ASSAULT_SHA1),
    (Declared: MAPPER_AXROM; Actual: MAPPER_NINA03; Sha1: ROM_NES_TILES_OF_FATE_SHA1));

function IsLegacyPowerPadRom(const Sha1: string): Boolean;
begin
  // Exact legacy payloads, Power Pad side B. Super Team Games is also
  // identified as expansion device 12 in puNES misc/nes20db.xml.
  Result :=
    SameText(Sha1, ROM_NES_SHORT_ORDER_SHA1) or
    SameText(Sha1, ROM_NES_STREET_COP_SHA1) or
    SameText(Sha1, ROM_NES_SUPER_TEAM_GAMES_SHA1);
end;

function IsLegacyFamicomKeyboardRom(const Sha1: string): Boolean;
begin
  // Family BASIC v1.0, v2.0, v2.1 and v3.0 payloads from puNES nes20db.xml.
  Result :=
    SameText(Sha1, ROM_NES_FAMILY_BASIC_V10_SHA1) or
    SameText(Sha1, ROM_NES_FAMILY_BASIC_V20_SHA1) or
    SameText(Sha1, ROM_NES_FAMILY_BASIC_V21_SHA1) or
    SameText(Sha1, ROM_NES_FAMILY_BASIC_V30_SHA1);
end;

function IsLegacyBatteryRom(const Sha1: string): Boolean;
const
  // Exact legacy payloads confirmed by FCEUmm ines-correct.h (236ccdfc).
  Identities: array[0..10] of string = (
    ROM_NES_DRAGON_BALL_Z_SHA1 { Dragon Ball Z.nes },
    ROM_NES_GEMFIRE_SHA1 { Gemfire (U).nes },
    ROM_NES_HEROES_OF_THE_LANCE_USA_SHA1 { Heros of the Lance.nes },
    ROM_NES_L_EMPEREUR_SHA1 { L'Empereur (U).nes },
    ROM_NES_NOBUNAGA_S_AMBITION_2_SHA1 { Nobunaga's Ambition 2 (U).nes },
    ROM_NES_NOBUNAGA_S_AMBITION_SHA1 { Nobunaga's Ambition.nes },
    ROM_NES_ROMANCE_OF_THE_THREE_KINGDOMS_2_SHA1 { Romance of the Three Kingdoms 2 (U).nes },
    ROM_NES_SECRET_LEGACY_OF_THE_MONGOL_DYNASTY_SHA1 { Secret Legacy of the Mongol Dynasty.nes },
    ROM_NES_STARTROPICS_2_ZODA_S_REVENGE_SHA1 { Startropics 2 - Zoda's Revenge.nes },
    ROM_NES_STARTROPICS_SHA1 { Startropics.nes },
    ROM_NES_UNCHARTED_WATERS_SHA1 { Uncharted Waters (U).nes });
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
    ROM_NES_BATTLE_STORM_SHA1,  // Battle Storm
    ROM_NES_DUE_K_SHA1); // Due K
  Vertical: array[0..5] of string = (
    ROM_NES_CASTELIA_SHA1,  // Castelia
    ROM_NES_NINJA_KID_SHA1,  // Ninja Kid
    ROM_NES_PIPE_DREAM_SHA1,  // Pipe Dream
    ROM_NES_SILENT_ASSAULT_SHA1,  // Silent Assault
    ROM_NES_TILES_OF_FATE_SHA1,  // Tiles of Fate
    ROM_NES_TRACK_AND_FIELD_SHA1); // Track and Field }
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
  if SameText(Hash.HashAsString, ROM_NES_SUPER_CARS_SHA1) then
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
  Result :=
    SameText(Hash.HashAsString, ROM_NES_ASTERIX_PAL_SHA1) or
    SameText(Hash.HashAsString, ROM_NES_ELITE_PAL_SHA1); { Elite PAL }
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

