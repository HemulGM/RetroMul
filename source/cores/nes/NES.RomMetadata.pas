unit NES.RomMetadata;

interface

uses
  NES.Types, NES.Mapper;

type
  TLegacyDiscreteBoard = record
    Submapper: Integer;
    PrgRam, PrgNvRam: UInt64;
    Battery: Boolean;
  end;

  TCamericaBoard = record
    Submapper, Timing: Byte;
    Vertical: Boolean;
  end;

function TryResolveLegacyDiscreteBoard(Mapper: Integer; const Sha1: string; out Board: TLegacyDiscreteBoard): Boolean;

function TryResolveLegacyCamerica(const Sha1: string; out Board: TCamericaBoard): Boolean;

function TryResolveLegacyNrom(Mapper: Integer; const Sha1: string; out Mirror: TMirrorMode): Boolean;

function Vrc2HasFloatingInput(const Sha1: string): Boolean;

function ResolveLegacyMapper(Declared: Integer; const Prg, Chr: NES.Types.TByteArray): Integer;

function IsLegacyPalRom(const Prg, Chr: NES.Types.TByteArray): Boolean;

function ResolveLegacyMirror(Declared: TMirrorMode; const Prg, Chr: NES.Types.TByteArray): TMirrorMode;

function IsLegacyBatteryRom(const Sha1: string): Boolean;

function IsLegacyMmc6Rom(const Sha1: string): Boolean;

function IsLegacyMmc3WithoutPrgRam(const Sha1: string): Boolean;

function IsNesosRom(const Sha1: string): Boolean;

function IsLegacyMcAccRom(const Sha1: string): Boolean;

function HasLegacyTecChrOrder(const Sha1: string): Boolean;

function HasLegacyTecPrgOrder(const Sha1: string): Boolean;

function IsLegacyPowerPadRom(const Sha1: string): Boolean;

function IsLegacyVsZapperRom(const Sha1: string): Boolean;

function IsLegacyFamicomKeyboardRom(const Sha1: string): Boolean;

function IsLegacyDataRecorderRom(const Sha1: string): Boolean;

function IsLegacyMiraclePianoRom(const Sha1: string): Boolean;

implementation

uses
  NES.RomHashes, System.Hash, System.SysUtils;

type
  TDiscreteBoardIdentity = record
    Sha1: string[40];
    Mapper, Submapper: Byte;
    PrgRam, PrgNvRam: Word;
    Battery: Boolean;
  end;

  TCamericaBoardIdentity = record
    Sha1: string[40];
    Board: TCamericaBoard;
  end;

const
  {$I NES.RomDiscreteBoards.inc}
  {$I NES.RomCamericaBoards.inc}

function TryResolveLegacyCamerica(const Sha1: string; out Board: TCamericaBoard): Boolean;
begin
  for var Index := Low(LEGACY_CAMERICA_BOARDS) to High(LEGACY_CAMERICA_BOARDS) do
    if Sha1 = string(LEGACY_CAMERICA_BOARDS[Index].Sha1) then
    begin
      Board := LEGACY_CAMERICA_BOARDS[Index].Board;
      Exit(True);
    end;
  Result := False;
end;

function Vrc2HasFloatingInput(const Sha1: string): Boolean;
begin
  for var Identity in VRC2_FLOATING_INPUT do
    if Sha1 = string(Identity) then
      Exit(True);
  Result := False;
end;

function TryResolveLegacyDiscreteBoard(Mapper: Integer; const Sha1: string; out Board: TLegacyDiscreteBoard): Boolean;
begin
  Result := False;
  if (Mapper > MAPPER_BNROM_NINA001) or not (Mapper in [MAPPER_MMC1, MAPPER_UXROM, MAPPER_CNROM, MAPPER_AXROM, MAPPER_BANDAI_FCG,
      MAPPER_VRC4A_VRC4C, MAPPER_VRC2A, MAPPER_VRC2B_VRC4E, MAPPER_VRC2C_VRC4B, MAPPER_BNROM_NINA001]) then
    Exit;

  var First := Low(LEGACY_DISCRETE_BOARDS);
  var Last := High(LEGACY_DISCRETE_BOARDS);
  while First <= Last do
  begin
    var Index := (First + Last) div 2;
    var Order := CompareStr(Sha1, string(LEGACY_DISCRETE_BOARDS[Index].Sha1));
    if Order < 0 then
      Last := Index - 1
    else if Order > 0 then
      First := Index + 1
    else
    begin
      var Entry := LEGACY_DISCRETE_BOARDS[Index];
      if Entry.Mapper <> Mapper then
        Exit;
      Board.Submapper := Entry.Submapper;
      Board.PrgRam := Entry.PrgRam;
      Board.PrgNvRam := Entry.PrgNvRam;
      Board.Battery := Entry.Battery;
      Exit(True);
    end;
  end;
end;

function TryResolveLegacyNrom(Mapper: Integer; const Sha1: string; out Mirror: TMirrorMode): Boolean;
type
  TNromIdentity = record
    Declared: Integer;
    Sha1: string[40];
    Mirror: TMirrorMode;
  end;
const
  // Exact iNES payloads verified against documented cartridges and FFE copies.
  Boards: array[0..12] of TNromIdentity = (
    (Declared: MAPPER_MMC1; Sha1: '56b62975d355efc2ac4d5d757d1480caa7fcb8e4'; Mirror: TMirrorMode.Horizontal), // Antarctic Adventure.nes
    (Declared: MAPPER_MMC1; Sha1: '5d8cba2011229dc67ccff6c99e647238f260e7af'; Mirror: TMirrorMode.Vertical), // Donkey Kong Jr.nes
    (Declared: MAPPER_MMC1; Sha1: '6e164763a2644aab0f294b8e5cb41403eb838b38'; Mirror: TMirrorMode.Vertical), // Door Door.nes
    (Declared: MAPPER_UXROM; Sha1: 'd545bcffc46f5b6c577d189640c5c9c39e25cff5'; Mirror: TMirrorMode.Vertical), // Dough Boy.nes
    (Declared: MAPPER_CNROM; Sha1: '13854ef3982a19317b8ab96a6ca48db71192a20a'; Mirror: TMirrorMode.Horizontal), // Galaga.nes
    (Declared: MAPPER_CNROM; Sha1: 'c596a00550e499dab5bc80f796d623e1cea1cb03'; Mirror: TMirrorMode.Vertical), // Mappy.nes
    (Declared: MAPPER_MMC1; Sha1: 'f79067e75da0add53942f388bd4af416ef89cfcd'; Mirror: TMirrorMode.Vertical), // Pacland.nes
    (Declared: MAPPER_MULTICART_15; Sha1: 'ec9c23a9c60703b87aec31b0344cbb6ade19037e'; Mirror: TMirrorMode.Horizontal), // Pyramid.nes
    (Declared: MAPPER_CNROM; Sha1: 'f663d004bea0fe0518fb8b2e3a9070e1ef1d39f4'; Mirror: TMirrorMode.Horizontal), // Space Invaders.nes
    (Declared: MAPPER_CNROM; Sha1: '85b0031c86274a5805933c5422f7b8dcfab75134'; Mirror: TMirrorMode.Horizontal), // Stack-Up (JU).nes
    (Declared: MAPPER_MMC1; Sha1: '6b0680e20bf07da4aec02d2dd48692b85b2af4bd'; Mirror: TMirrorMode.Horizontal), // Warpman.nes
    (Declared: MAPPER_MMC1; Sha1: 'dee513dad7223cfc81bcd859d0aac6746349cb25'; Mirror: TMirrorMode.Horizontal), // Wrecking Crew.nes
    (Declared: MAPPER_CNROM; Sha1: 'ace488d8fa6ad5fb528f759e6bed66b3cfef042d'; Mirror: TMirrorMode.Horizontal)); // Zippy Race.nes
begin
  if (Mapper > MAPPER_MULTICART_15) or not (Mapper in [MAPPER_MMC1, MAPPER_UXROM, MAPPER_CNROM, MAPPER_MULTICART_15]) then
    Exit(False);

  for var Board in Boards do
    if (Mapper = Board.Declared) and (Sha1 = string(Board.Sha1)) then
    begin
      Mirror := Board.Mirror;
      Exit(True);
    end;
  Result := False;
end;

function IsLegacyVsZapperRom(const Sha1: string): Boolean;
begin
  // Exact payloads: original Vs. Duck Hunt and collection CHR variant.
  Result := SameText(Sha1, ROM_NES_VS_DUCK_HUNT_SHA1) or
    SameText(Sha1, ROM_NES_VS_DUCK_HUNT_COLLECTION_SHA1);
end;

function IsLegacyMiraclePianoRom(const Sha1: string): Boolean;
begin
  // Exact PRG+CHR identities: USA, France, Germany (puNES NES 2.0 DB).
  Result := SameText(Sha1, '7bf2e5dad66ce253c25ec97cf27461c6475f044d') or
    SameText(Sha1, 'acc9c9eb5defda865cb84bb6057d739ea4cfe5e0') or
    SameText(Sha1, 'f3d84dcc9fdb48e3f638e4f3205384721c10f710');
end;

function IsLegacyMmc6Rom(const Sha1: string): Boolean;
begin
  // Exact HKROM payloads; legacy iNES has no MMC6 submapper field.
  Result :=
    SameText(Sha1, ROM_NES_STARTROPICS_SHA1) or
    SameText(Sha1, ROM_NES_STARTROPICS_2_ZODA_S_REVENGE_SHA1);
end;

function IsLegacyMmc3WithoutPrgRam(const Sha1: string): Boolean;
begin
  // Low G Man expects an undriven CPU bus on its board without WRAM.
  Result := SameText(Sha1, '93b758fccb9a4d9e69e851172d2647aebabad461') or // North America
    SameText(Sha1, '9d0cdadb035f8ca61f4555b30ae0b8551a4188d6') or // PAL
    SameText(Sha1, '9d4572dbaa9e24efb2173dbde88207ab97dcaa94') or // L-N1
    SameText(Sha1, '7c9eb2410e3205a7f0f6b0a6ffaba9b21f0e8b4a');   // Prototype
end;

function IsNesosRom(const Sha1: string): Boolean;
begin
  Result := SameText(Sha1, 'f69b9e0b89616423cdea914273fdd1c6889cd8d1') or // Author's v1.0
    SameText(Sha1, '7221f3c7a5692e72a7dbe2f8c983753159ca2d93');          // WRAM enable patch
end;

function IsLegacyMcAccRom(const Sha1: string): Boolean;
const
  // PRG+CHR identities for mapper 4.3 in the 2026-09-26 NES 2.0 database.
  Identities: array[0..16] of string = (
    '6e14d69218f890d5b4806e19c599329f1b5079a1', // Alien 3
    '8a20080a4f8ef1268c1555913510733055031c5e', // George Foreman's KO Boxing
    '8fc3a23a8e89b1e952ac137c1e3f7c7181cbe777', // Mickey's Safari in Letterland
    'f65cc1b8a916e55b8ac025755ac6dc7fa3e40919', // Roger Clemens' MVP Baseball (rev0)
    'e6a3738c6e5bd1416feed8e1daf594e5f6a79888', // Roger Clemens' MVP Baseball (rev1)
    '0d173fa60b6d17592c1654463ecf0c20924c16c1', // Rollerblade Racer
    'beca615eeb6304720f9430676a935cf8c1f54ed7', // Spider-Man: Return of the Sinister Six
    'eb86ceeff011b93a81630b0d5118876581bfc72b', // T&C Surf Designs II
    'dbf35d2f94d0f5f6b39621e8a29e864eeaede173', // Terminator 2: Judgment Day
    'c78f57623c4fcb10ddfda88e519362be87e432c0', // The Incredible Crash Dummies
    'fe90ed67291b405970e911b0aa0fc489f1c9253f', // The Simpsons: Bart vs. the World
    '617b59e8fa49cb78ef867dbe517695048f247f08', // The Simpsons: Bartman Meets Radioactive Man
    '394395b825f3d16902df427e93c2310302a2b9af', // WWF King of the Ring
    'a4f6cc93bddff749b5f078bb31074c86234358e6', // WWF WrestleMania Steel Cage Challenge
    'ddf730ed69c7449a77262e4b3ae8040ddc48e689', // Terminator 2 (RAM initialization fix)
    '36f07ca29e0eb2d6242fc0aafa0a31110a29911e', // Alien 3: Lomax Edition
    '8b8446822b2eb17dc66fc5b1cb15f470938f120f'); // Jason X
begin
  for var Identity in Identities do
    if SameText(Sha1, Identity) then
      Exit(True);
  Result := False;
end;

function HasLegacyTecChrOrder(const Sha1: string): Boolean;
begin
  // Exact old dumps with the CHR halves reversed (NES 2.0 database).
  Result := SameText(Sha1, '63cbb7f2bc5b59b7f6646055c4e2b795cf65762c') or
    SameText(Sha1, 'c77e410593dc31da365c07a37d38f9351a3234de') or
    SameText(Sha1, 'c887ab789d85148447f1e8788dfc1b7b662d3d25') or
    SameText(Sha1, '63d5d340d988fd9b79ef0552d8cc3b14ea590774') or
    SameText(Sha1, '41a35feb4c8674f46a6495de84eaabb374b71977') or
    SameText(Sha1, 'c1dbc8f61c9fef47e20371907572b660f25d6276');
end;

function HasLegacyTecPrgOrder(const Sha1: string): Boolean;
begin
  // Old GameStar Smart Genius dump with the two PRG chips in reverse order.
  Result := SameText(Sha1, '2edb1bac11b249211f841579be329a40b74d9975');
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
  MAPPER_IDENTITIES: array[0..36] of TMapperIdentity = (
    (Declared: MAPPER_UXROM; Actual: MAPPER_MMC1; Sha1: ROM_NES_FAXANADU_SHA1),
    (Declared: MAPPER_UXROM; Actual: MAPPER_DXROM; Sha1: ROM_NES_VS_SUPER_XEVIOUS_SHA1),
    (Declared: MAPPER_BANDAI_70; Actual: MAPPER_BANDAI_152; Sha1: ROM_NES_ARKANOID_2_SHA1),
    (Declared: MAPPER_NAMCO_118; Actual: MAPPER_NAMCO_154; Sha1: ROM_NES_DEVILMAN_SHA1),
    (Declared: MAPPER_BANDAI_FCG; Actual: MAPPER_BANDAI_159; Sha1: ROM_NES_DRAGON_BALL_Z_SHA1),
    (Declared: MAPPER_FFE_F3XXX; Actual: MAPPER_NINA03; Sha1: ROM_NES_MERMAIDS_OF_ATLANTIS_SHA1),
    (Declared: MAPPER_MULTICART_15; Actual: MAPPER_NROM; Sha1: ROM_NES_PACHICOM_SHA1),
    (Declared: MAPPER_CAMERICA; Actual: MAPPER_CAMERICA_QUATTRO; Sha1: ROM_NES_QUATTRO_SPORTS_SHA1),
    (Declared: MAPPER_JY_90; Actual: MAPPER_JY_209; Sha1: ROM_NES_SAMURAI_SPIRITS_2_SHA1),
    (Declared: MAPPER_JY_90; Actual: MAPPER_JY_281; Sha1: ROM_NES_JY052_TARZAN_SHA1),
    (Declared: MAPPER_MMC3_12; Actual: MAPPER_CPROM; Sha1: ROM_NES_VIDEOMATION_SHA1),
    (Declared: MAPPER_COLOR_DREAMS; Actual: MAPPER_AGCI; Sha1: ROM_NES_DEATH_RACE_SHA1),
    (Declared: MAPPER_MMC3; Actual: MAPPER_TQROM; Sha1: ROM_NES_PINBOT_SHA1),
    (Declared: MAPPER_MMC3; Actual: MAPPER_RAMBO1; Sha1: ROM_NES_ROAD_RUNNER_SHA1),
    (Declared: MAPPER_MMC3; Actual: MAPPER_RAMBO1; Sha1: ROM_NES_ROLLING_THUNDER_SHA1),
    (Declared: MAPPER_MMC3; Actual: MAPPER_DXROM; Sha1: ROM_NES_BABEL_SHA1),
    (Declared: MAPPER_MMC3; Actual: MAPPER_DXROM; Sha1: ROM_NES_GAUNTLET_UNLICENSED_SHA1),
    (Declared: MAPPER_MMC3; Actual: MAPPER_DXROM; Sha1: ROM_NES_PAC_MANIA_SHA1),
    (Declared: MAPPER_MMC3; Actual: MAPPER_DXROM; Sha1: ROM_NES_QUEST_OF_KI_SHA1),
    (Declared: MAPPER_MMC3; Actual: MAPPER_DXROM; Sha1: ROM_NES_RBI_BASEBALL_LICENSED_SHA1),
    (Declared: MAPPER_MMC3; Actual: MAPPER_DXROM; Sha1: ROM_NES_TOOBIN_SHA1),
    (Declared: MAPPER_MMC3; Actual: MAPPER_TXSROM; Sha1: ROM_NES_GOAL_2_PAL_SHA1),
    (Declared: MAPPER_MMC3; Actual: MAPPER_TXSROM; Sha1: ROM_NES_GOAL_TWO_NTSC_SHA1),
    (Declared: MAPPER_MMC3; Actual: MAPPER_TXSROM; Sha1: ROM_NES_PLAY_ACTION_FOOTBALL_SHA1),
    (Declared: MAPPER_CNROM; Actual: MAPPER_HES_148; Sha1: ROM_NES_HOT_SLOT_SHA1),
    (Declared: MAPPER_CNROM; Actual: MAPPER_HES_148; Sha1: ROM_NES_IDOL_SHISEN_MAAJAN_SHA1),
    (Declared: MAPPER_CNROM; Actual: MAPPER_HES_148; Sha1: ROM_NES_ORYU_MISSING_CHR_SHA1),
    (Declared: MAPPER_CNROM; Actual: MAPPER_HES_148; Sha1: ROM_NES_SHISEN_MAAJAN_SEIFUKU_SHA1),
    (Declared: MAPPER_CNROM; Actual: MAPPER_HES_148; Sha1: ROM_NES_SOAP_PANIC_MISSING_CHR_SHA1),
    (Declared: MAPPER_NROM; Actual: MAPPER_CNROM; Sha1: ROM_NES_ADVENTURES_OF_DINO_RIKI_SHA1),
    (Declared: MAPPER_NROM; Actual: MAPPER_CNROM; Sha1: ROM_NES_MYSTERY_QUEST_SHA1),
    (Declared: MAPPER_NROM; Actual: MAPPER_CNROM; Sha1: ROM_NES_NINJA_KID_SHA1),
    (Declared: MAPPER_NROM; Actual: MAPPER_CNROM; Sha1: ROM_NES_PIPE_DREAM_SHA1),
    (Declared: MAPPER_AXROM; Actual: MAPPER_COLOR_DREAMS; Sha1: ROM_NES_CASTLE_OF_DECEIT_SHA1),
    (Declared: MAPPER_AXROM; Actual: MAPPER_BNROM_NINA001; Sha1: ROM_NES_DEADLY_TOWERS_SHA1),
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
  Horizontal: array[0..12] of string = (
    ROM_NES_BABEL_SHA1,
    ROM_NES_BATTLE_STORM_SHA1,  // Battle Storm
    ROM_NES_DEADLY_TOWERS_SHA1,
    ROM_NES_DUE_K_SHA1, // Due K
    ROM_NES_GOAL_2_PAL_SHA1,
    ROM_NES_GOAL_TWO_NTSC_SHA1,
    ROM_NES_HOT_SLOT_SHA1,
    ROM_NES_ORYU_MISSING_CHR_SHA1,
    ROM_NES_PLAY_ACTION_FOOTBALL_SHA1,
    ROM_NES_ROAD_RUNNER_SHA1,
    ROM_NES_ROLLING_THUNDER_SHA1,
    ROM_NES_SHISEN_MAAJAN_SEIFUKU_SHA1,
    ROM_NES_TOOBIN_SHA1);
  Vertical: array[0..14] of string = (
    ROM_NES_MARIO_DUCK_HUNT_PAL_SHA1, // MHROM, fixed vertical CIRAM wiring
    ROM_NES_ADVENTURES_OF_DINO_RIKI_SHA1,
    ROM_NES_CASTELIA_SHA1,  // Castelia
    ROM_NES_CASTLE_OF_DECEIT_SHA1,
    ROM_NES_IDOL_SHISEN_MAAJAN_SHA1,
    ROM_NES_MYSTERY_QUEST_SHA1,
    ROM_NES_NINJA_KID_SHA1,  // Ninja Kid
    ROM_NES_PAC_MANIA_SHA1,
    ROM_NES_PIPE_DREAM_SHA1,  // Pipe Dream
    ROM_NES_QUEST_OF_KI_SHA1,
    ROM_NES_RBI_BASEBALL_LICENSED_SHA1,
    ROM_NES_SILENT_ASSAULT_SHA1,  // Silent Assault
    ROM_NES_SOAP_PANIC_MISSING_CHR_SHA1,
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
  if SameText(Identity, ROM_NES_GAUNTLET_UNLICENSED_SHA1) then
    Exit(TMirrorMode.FourScreen);
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
  if Length(Prg) = $10000 then
  begin
    var Payload := THashSHA1.Create;
    Payload.Update(Prg[0], Length(Prg));
    if Length(Chr) > 0 then
      Payload.Update(Chr[0], Length(Chr));
    if SameText(Payload.HashAsString, ROM_NES_MARIO_DUCK_HUNT_PAL_SHA1) then
      Exit(True);
  end;

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
  for var Entry in MAPPER_IDENTITIES do
    Relevant := Relevant or (Entry.Declared = Declared);

  if not Relevant or (Length(Prg) = 0) then
    Exit;

  var Hash := THashSHA1.Create;
  Hash.Update(Prg[0], Length(Prg));
  if Length(Chr) > 0 then
    Hash.Update(Chr[0], Length(Chr));
  var Digest := Hash.HashAsString;
  for var Entry in MAPPER_IDENTITIES do
    if (Entry.Declared = Declared) and SameText(Entry.Sha1, Digest) then
      Exit(Entry.Actual);
end;

end.

