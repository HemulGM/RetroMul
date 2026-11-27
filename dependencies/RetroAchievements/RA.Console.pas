unit RA.Console;

interface

{$SCOPEDENUMS ON}

const
  RAConsoleUnknown = 0;
  RAConsoleMegaDrive = 1;
  RAConsoleNintendo64 = 2;
  RAConsoleSuperNintendo = 3;
  RAConsoleGameBoy = 4;
  RAConsoleGameBoyAdvance = 5;
  RAConsoleGameBoyColor = 6;
  RAConsoleNintendo = 7;
  RAConsolePCEngine = 8;
  RAConsoleSegaCD = 9;
  RAConsoleSega32X = 10;
  RAConsoleMasterSystem = 11;
  RAConsolePlayStation = 12;
  RAConsoleAtariLynx = 13;
  RAConsoleNeoGeoPocket = 14;
  RAConsoleGameGear = 15;
  RAConsoleGameCube = 16;
  RAConsoleAtariJaguar = 17;
  RAConsoleNintendoDS = 18;
  RAConsoleWii = 19;
  RAConsoleWiiU = 20;
  RAConsolePlayStation2 = 21;
  RAConsoleXbox = 22;
  RAConsoleMagnavoxOdyssey2 = 23;
  RAConsolePokemonMini = 24;
  RAConsoleAtari2600 = 25;
  RAConsoleMSDOS = 26;
  RAConsoleArcade = 27;
  RAConsoleVirtualBoy = 28;
  RAConsoleMSX = 29;
  RAConsoleCommodore64 = 30;
  RAConsoleZX81 = 31;
  RAConsoleOric = 32;
  RAConsoleSG1000 = 33;
  RAConsoleVIC20 = 34;
  RAConsoleAmiga = 35;
  RAConsoleAtariSt = 36;
  RAConsoleAmstradPC = 37;
  RAConsoleAppleIi = 38;
  RAConsoleSaturn = 39;
  RAConsoleDreamcast = 40;
  RAConsolePSP = 41;
  RAConsoleCDI = 42;
  RAConsole3DO = 43;
  RAConsoleColecovision = 44;
  RAConsoleIntellivision = 45;
  RAConsoleVectrex = 46;
  RAConsolePC8800 = 47;
  RAConsolePC9800 = 48;
  RAConsolePCFX = 49;
  RAConsoleAtari5200 = 50;
  RAConsoleAtari7800 = 51;
  RAConsoleX68K = 52;
  RAConsoleWonderSwan = 53;
  RAConsoleCassettevision = 54;
  RAConsoleSuperCassettevision = 55;
  RAConsoleNeoGeoCD = 56;
  RAConsoleFairchildChannelF = 57;
  RAConsoleFMTowns = 58;
  RAConsoleZXSpectrum = 59;
  RAConsoleGameAndWatch = 60;
  RAConsoleNokiaNgage = 61;
  RAConsoleNintendo3DS = 62;
  RAConsoleSupervision = 63;
  RAConsoleSharpX1 = 64;
  RAConsoleTIC80 = 65;
  RAConsoleThomsonTO8 = 66;
  RAConsolePC6000 = 67;
  RAConsolePico = 68;
  RAConsoleMegaDuck = 69;
  RAConsoleZeebo = 70;
  RAConsoleArduboy = 71;
  RAConsoleWASM4 = 72;
  RAConsoleArcadia2001 = 73;
  RAConsoleIntertonVC4000 = 74;
  RAConsoleElektorTvGamesComputer = 75;
  RAConsolePCEngineCD = 76;
  RAConsoleAtariJaguarCD = 77;
  RAConsoleNintendoDSi = 78;
  RAConsoleTI83 = 79;
  RAConsoleUzebox = 80;
  RAConsoleFamicomDiskSystem = 81;
  RAConsolePlayStation3 = 82;
  RAConsoleHubs = 100;
  RAConsoleEvents = 101;
  RAConsoleStandalone = 102;

type
  TRAMemoryRegionKind = (SystemRAM, SaveRAM, VideoRAM, ReadOnly, HardwareController, VirtualRAM, Unused);

  TRAMemoryRegion = record
    StartAddress, EndAddress, RealAddress: Cardinal;
    Kind: TRAMemoryRegionKind;
    Description: string;
  end;

function RAConsoleName(ConsoleID: Cardinal): string;

function RAConsoleMemoryRegions(ConsoleID: Cardinal): TArray<TRAMemoryRegion>;

// Systems without a published map do not impose an upper bound.
function RAConsoleMaxAddress(ConsoleID: Cardinal): Cardinal;

implementation

type
  TRAConsoleDefinition = record
    Name: string;
    FirstRegion, RegionCount: Integer;
  end;

const
  // RetroAchievements address maps from rcheevos v12.5.0, src/rcheevos/consoleinfo.c.
  MemoryRegions: array[0..245] of TRAMemoryRegion = (
    (StartAddress: $00000000; EndAddress: $0000FFFF; RealAddress: $00FF0000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM'),
    (StartAddress: $00010000; EndAddress: $0001FFFF; RealAddress: $00000000;
      Kind: TRAMemoryRegionKind.SaveRAM; Description: 'Cartridge RAM'),
    (StartAddress: $00000000; EndAddress: $001FFFFF; RealAddress: $80000000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM'),
    (StartAddress: $00200000; EndAddress: $003FFFFF; RealAddress: $80200000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM'),
    (StartAddress: $00400000; EndAddress: $007FFFFF; RealAddress: $80400000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM'),
    (StartAddress: $00000000; EndAddress: $0001FFFF; RealAddress: $007E0000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM'),
    (StartAddress: $00020000; EndAddress: $0009FFFF; RealAddress: $01000000;
      Kind: TRAMemoryRegionKind.SaveRAM; Description: 'Cartridge RAM'),
    (StartAddress: $000A0000; EndAddress: $000A07FF; RealAddress: $01080000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'I-RAM (SA-1)'),
    (StartAddress: $00000000; EndAddress: $000000FF; RealAddress: $00000000;
      Kind: TRAMemoryRegionKind.HardwareController; Description: 'Interrupt vector'),
    (StartAddress: $00000100; EndAddress: $0000014F; RealAddress: $00000100;
      Kind: TRAMemoryRegionKind.ReadOnly; Description: 'Cartridge header'),
    (StartAddress: $00000150; EndAddress: $00003FFF; RealAddress: $00000150;
      Kind: TRAMemoryRegionKind.ReadOnly; Description: 'Cartridge ROM (fixed)'),
    (StartAddress: $00004000; EndAddress: $00007FFF; RealAddress: $00004000;
      Kind: TRAMemoryRegionKind.ReadOnly; Description: 'Cartridge ROM (paged)'),
    (StartAddress: $00008000; EndAddress: $000097FF; RealAddress: $00008000;
      Kind: TRAMemoryRegionKind.VideoRAM; Description: 'Tile RAM'),
    (StartAddress: $00009800; EndAddress: $00009BFF; RealAddress: $00009800;
      Kind: TRAMemoryRegionKind.VideoRAM; Description: 'BG1 map data'),
    (StartAddress: $00009C00; EndAddress: $00009FFF; RealAddress: $00009C00;
      Kind: TRAMemoryRegionKind.VideoRAM; Description: 'BG2 map data'),
    (StartAddress: $0000A000; EndAddress: $0000BFFF; RealAddress: $0000A000;
      Kind: TRAMemoryRegionKind.SaveRAM; Description: 'Cartridge RAM (bank 0)'),
    (StartAddress: $0000C000; EndAddress: $0000CFFF; RealAddress: $0000C000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM (fixed)'),
    (StartAddress: $0000D000; EndAddress: $0000DFFF; RealAddress: $0000D000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM (fixed)'),
    (StartAddress: $0000E000; EndAddress: $0000FDFF; RealAddress: $0000C000;
      Kind: TRAMemoryRegionKind.VirtualRAM; Description: 'Echo RAM'),
    (StartAddress: $0000FE00; EndAddress: $0000FE9F; RealAddress: $0000FE00;
      Kind: TRAMemoryRegionKind.VideoRAM; Description: 'Sprite RAM'),
    (StartAddress: $0000FEA0; EndAddress: $0000FEFF; RealAddress: $0000FEA0;
      Kind: TRAMemoryRegionKind.Unused; Description: ''),
    (StartAddress: $0000FF00; EndAddress: $0000FF7F; RealAddress: $0000FF00;
      Kind: TRAMemoryRegionKind.HardwareController; Description: 'Hardware I/O'),
    (StartAddress: $0000FF80; EndAddress: $0000FFFE; RealAddress: $0000FF80;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'Quick RAM'),
    (StartAddress: $0000FFFF; EndAddress: $0000FFFF; RealAddress: $0000FFFF;
      Kind: TRAMemoryRegionKind.HardwareController; Description: 'Interrupt enable'),
    (StartAddress: $00010000; EndAddress: $00015FFF; RealAddress: $00010000;
      Kind: TRAMemoryRegionKind.Unused; Description: 'Unused (GameBoy Color exclusive)'),
    (StartAddress: $00016000; EndAddress: $00033FFF; RealAddress: $00016000;
      Kind: TRAMemoryRegionKind.SaveRAM; Description: 'Cartridge RAM (banks 1-15)'),
    (StartAddress: $00000000; EndAddress: $00007FFF; RealAddress: $03000000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM'),
    (StartAddress: $00008000; EndAddress: $00047FFF; RealAddress: $02000000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM'),
    (StartAddress: $00048000; EndAddress: $00057FFF; RealAddress: $0E000000;
      Kind: TRAMemoryRegionKind.SaveRAM; Description: 'Save RAM'),
    (StartAddress: $00000000; EndAddress: $000000FF; RealAddress: $00000000;
      Kind: TRAMemoryRegionKind.HardwareController; Description: 'Interrupt vector'),
    (StartAddress: $00000100; EndAddress: $0000014F; RealAddress: $00000100;
      Kind: TRAMemoryRegionKind.ReadOnly; Description: 'Cartridge header'),
    (StartAddress: $00000150; EndAddress: $00003FFF; RealAddress: $00000150;
      Kind: TRAMemoryRegionKind.ReadOnly; Description: 'Cartridge ROM (fixed)'),
    (StartAddress: $00004000; EndAddress: $00007FFF; RealAddress: $00004000;
      Kind: TRAMemoryRegionKind.ReadOnly; Description: 'Cartridge ROM (paged)'),
    (StartAddress: $00008000; EndAddress: $000097FF; RealAddress: $00008000;
      Kind: TRAMemoryRegionKind.VideoRAM; Description: 'Tile RAM'),
    (StartAddress: $00009800; EndAddress: $00009BFF; RealAddress: $00009800;
      Kind: TRAMemoryRegionKind.VideoRAM; Description: 'BG1 map data'),
    (StartAddress: $00009C00; EndAddress: $00009FFF; RealAddress: $00009C00;
      Kind: TRAMemoryRegionKind.VideoRAM; Description: 'BG2 map data'),
    (StartAddress: $0000A000; EndAddress: $0000BFFF; RealAddress: $0000A000;
      Kind: TRAMemoryRegionKind.SaveRAM; Description: 'Cartridge RAM (bank 0)'),
    (StartAddress: $0000C000; EndAddress: $0000CFFF; RealAddress: $0000C000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM (bank 0)'),
    (StartAddress: $0000D000; EndAddress: $0000DFFF; RealAddress: $0000D000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM (bank 1)'),
    (StartAddress: $0000E000; EndAddress: $0000FDFF; RealAddress: $0000C000;
      Kind: TRAMemoryRegionKind.VirtualRAM; Description: 'Echo RAM'),
    (StartAddress: $0000FE00; EndAddress: $0000FE9F; RealAddress: $0000FE00;
      Kind: TRAMemoryRegionKind.VideoRAM; Description: 'Sprite RAM'),
    (StartAddress: $0000FEA0; EndAddress: $0000FEFF; RealAddress: $0000FEA0;
      Kind: TRAMemoryRegionKind.Unused; Description: ''),
    (StartAddress: $0000FF00; EndAddress: $0000FF7F; RealAddress: $0000FF00;
      Kind: TRAMemoryRegionKind.HardwareController; Description: 'Hardware I/O'),
    (StartAddress: $0000FF80; EndAddress: $0000FFFE; RealAddress: $0000FF80;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'Quick RAM'),
    (StartAddress: $0000FFFF; EndAddress: $0000FFFF; RealAddress: $0000FFFF;
      Kind: TRAMemoryRegionKind.HardwareController; Description: 'Interrupt enable'),
    (StartAddress: $00010000; EndAddress: $00015FFF; RealAddress: $00010000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM (banks 2-7)'),
    (StartAddress: $00016000; EndAddress: $00033FFF; RealAddress: $00016000;
      Kind: TRAMemoryRegionKind.SaveRAM; Description: 'Cartridge RAM (banks 1-15)'),
    (StartAddress: $00000000; EndAddress: $000007FF; RealAddress: $00000000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM'),
    (StartAddress: $00000800; EndAddress: $00000FFF; RealAddress: $00000000;
      Kind: TRAMemoryRegionKind.VirtualRAM; Description: 'Mirror RAM'),
    (StartAddress: $00001000; EndAddress: $000017FF; RealAddress: $00000000;
      Kind: TRAMemoryRegionKind.VirtualRAM; Description: 'Mirror RAM'),
    (StartAddress: $00001800; EndAddress: $00001FFF; RealAddress: $00000000;
      Kind: TRAMemoryRegionKind.VirtualRAM; Description: 'Mirror RAM'),
    (StartAddress: $00002000; EndAddress: $00002007; RealAddress: $00002000;
      Kind: TRAMemoryRegionKind.HardwareController; Description: 'PPU Register'),
    (StartAddress: $00002008; EndAddress: $00003FFF; RealAddress: $00002008;
      Kind: TRAMemoryRegionKind.VirtualRAM; Description: 'Mirrored PPU Register'),
    (StartAddress: $00004000; EndAddress: $00004017; RealAddress: $00004000;
      Kind: TRAMemoryRegionKind.HardwareController; Description: 'APU and I/O register'),
    (StartAddress: $00004018; EndAddress: $0000401F; RealAddress: $00004018;
      Kind: TRAMemoryRegionKind.HardwareController; Description: 'APU and I/O test register'),
    (StartAddress: $00004020; EndAddress: $00005FFF; RealAddress: $00004020;
      Kind: TRAMemoryRegionKind.ReadOnly; Description: 'Cartridge data'),
    (StartAddress: $00006000; EndAddress: $00007FFF; RealAddress: $00006000;
      Kind: TRAMemoryRegionKind.SaveRAM; Description: 'Cartridge RAM'),
    (StartAddress: $00008000; EndAddress: $0000FFFF; RealAddress: $00008000;
      Kind: TRAMemoryRegionKind.ReadOnly; Description: 'Cartridge ROM'),
    (StartAddress: $00000000; EndAddress: $00001FFF; RealAddress: $001F0000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM'),
    (StartAddress: $00000000; EndAddress: $0000FFFF; RealAddress: $00FF0000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: '68000 RAM'),
    (StartAddress: $00010000; EndAddress: $0008FFFF; RealAddress: $80020000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'CD PRG RAM'),
    (StartAddress: $00090000; EndAddress: $000AFFFF; RealAddress: $00200000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'CD WORD RAM'),
    (StartAddress: $00000000; EndAddress: $0000FFFF; RealAddress: $00FF0000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM'),
    (StartAddress: $00010000; EndAddress: $0004FFFF; RealAddress: $06000000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: '32X RAM'),
    (StartAddress: $00050000; EndAddress: $0005FFFF; RealAddress: $00000000;
      Kind: TRAMemoryRegionKind.SaveRAM; Description: 'Cartridge RAM'),
    (StartAddress: $00000000; EndAddress: $00001FFF; RealAddress: $0000C000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM'),
    (StartAddress: $00002000; EndAddress: $00009FFF; RealAddress: $00010000;
      Kind: TRAMemoryRegionKind.SaveRAM; Description: 'Cartridge RAM'),
    (StartAddress: $00000000; EndAddress: $0000FFFF; RealAddress: $00000000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'Kernel RAM'),
    (StartAddress: $00010000; EndAddress: $001FFFFF; RealAddress: $00010000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM'),
    (StartAddress: $00200000; EndAddress: $002003FF; RealAddress: $1F800000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'Scratchpad RAM'),
    (StartAddress: $00000000; EndAddress: $000000FF; RealAddress: $00000000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'Zero Page'),
    (StartAddress: $00000100; EndAddress: $000001FF; RealAddress: $00000100;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'Stack'),
    (StartAddress: $00000200; EndAddress: $0000FBFF; RealAddress: $00000200;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM'),
    (StartAddress: $0000FC00; EndAddress: $0000FCFF; RealAddress: $0000FC00;
      Kind: TRAMemoryRegionKind.HardwareController; Description: 'SUZY hardware access'),
    (StartAddress: $0000FD00; EndAddress: $0000FDFF; RealAddress: $0000FD00;
      Kind: TRAMemoryRegionKind.HardwareController; Description: 'MIKEY hardware access'),
    (StartAddress: $0000FE00; EndAddress: $0000FFF7; RealAddress: $0000FE00;
      Kind: TRAMemoryRegionKind.HardwareController; Description: 'Boot ROM'),
    (StartAddress: $0000FFF8; EndAddress: $0000FFFF; RealAddress: $0000FFF8;
      Kind: TRAMemoryRegionKind.HardwareController; Description: 'Hardware vectors'),
    (StartAddress: $00000000; EndAddress: $00003FFF; RealAddress: $00004000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM'),
    (StartAddress: $00000000; EndAddress: $017FFFFF; RealAddress: $80000000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM'),
    (StartAddress: $00000000; EndAddress: $001FFFFF; RealAddress: $00000000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM'),
    (StartAddress: $00000000; EndAddress: $003FFFFF; RealAddress: $02000000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM'),
    (StartAddress: $00400000; EndAddress: $00FFFFFF; RealAddress: $02400000;
      Kind: TRAMemoryRegionKind.Unused; Description: 'Unused (DSi exclusive)'),
    (StartAddress: $01000000; EndAddress: $01003FFF; RealAddress: $0E000000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'Data TCM'),
    (StartAddress: $00000000; EndAddress: $017FFFFF; RealAddress: $80000000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM'),
    (StartAddress: $01800000; EndAddress: $0FFFFFFF; RealAddress: $81800000;
      Kind: TRAMemoryRegionKind.Unused; Description: 'Unused'),
    (StartAddress: $10000000; EndAddress: $13FFFFFF; RealAddress: $90000000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM'),
    (StartAddress: $00000000; EndAddress: $000FFFFF; RealAddress: $00000000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'Kernel RAM'),
    (StartAddress: $00100000; EndAddress: $01FFFFFF; RealAddress: $00100000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM'),
    (StartAddress: $02000000; EndAddress: $02003FFF; RealAddress: $70000000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'Scratchpad RAM'),
    (StartAddress: $00000000; EndAddress: $03FFFFFF; RealAddress: $00000000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM'),
    (StartAddress: $00000000; EndAddress: $0000003F; RealAddress: $00000000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'Internal RAM'),
    (StartAddress: $00000040; EndAddress: $0000013F; RealAddress: $00000040;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'External RAM'),
    (StartAddress: $00000000; EndAddress: $00000FFF; RealAddress: $00000000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'BIOS RAM'),
    (StartAddress: $00001000; EndAddress: $00001FFF; RealAddress: $00001000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM'),
    (StartAddress: $00000000; EndAddress: $0000007F; RealAddress: $00000080;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM'),
    (StartAddress: $00000000; EndAddress: $0009FFFF; RealAddress: $00000000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'Game Conventional Memory'),
    (StartAddress: $000A0000; EndAddress: $000FFFFF; RealAddress: $000A0000;
      Kind: TRAMemoryRegionKind.Unused; Description: 'Padding to align OS Conventional Memory'),
    (StartAddress: $00100000; EndAddress: $0019FFFF; RealAddress: $00100000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'OS Conventional Memory'),
    (StartAddress: $001A0000; EndAddress: $001FFFFF; RealAddress: $001A0000;
      Kind: TRAMemoryRegionKind.Unused; Description: 'Padding to align Expanded Memory'),
    (StartAddress: $00200000; EndAddress: $041FFFFF; RealAddress: $00200000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'Expanded Memory'),
    (StartAddress: $00000000; EndAddress: $0000FFFF; RealAddress: $05000000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM'),
    (StartAddress: $00010000; EndAddress: $0001FFFF; RealAddress: $06000000;
      Kind: TRAMemoryRegionKind.SaveRAM; Description: 'Cartridge RAM'),
    (StartAddress: $00000000; EndAddress: $0007FFFF; RealAddress: $00010000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM'),
    (StartAddress: $00000000; EndAddress: $000003FF; RealAddress: $00000000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'Kernel RAM'),
    (StartAddress: $00000400; EndAddress: $000007FF; RealAddress: $00000400;
      Kind: TRAMemoryRegionKind.VideoRAM; Description: 'Screen RAM'),
    (StartAddress: $00000800; EndAddress: $00009FFF; RealAddress: $00000800;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM'),
    (StartAddress: $0000A000; EndAddress: $0000BFFF; RealAddress: $0000A000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM'),
    (StartAddress: $0000C000; EndAddress: $0000CFFF; RealAddress: $0000C000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM'),
    (StartAddress: $0000D000; EndAddress: $0000DFFF; RealAddress: $0000D000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM'),
    (StartAddress: $0000E000; EndAddress: $0000FFFF; RealAddress: $0000E000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM'),
    (StartAddress: $00000000; EndAddress: $0000FFFF; RealAddress: $00000000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM'),
    (StartAddress: $00000000; EndAddress: $000003FF; RealAddress: $0000C000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM'),
    (StartAddress: $00000400; EndAddress: $00001FFF; RealAddress: $0000C400;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'Extended RAM'),
    (StartAddress: $00002000; EndAddress: $00003FFF; RealAddress: $00002000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'Extended RAM'),
    (StartAddress: $00004000; EndAddress: $00005FFF; RealAddress: $00008000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'Extended RAM'),
    (StartAddress: $00000000; EndAddress: $0007FFFF; RealAddress: $00000000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'Main RAM'),
    (StartAddress: $00080000; EndAddress: $000FFFFF; RealAddress: $00080000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'Extended RAM'),
    (StartAddress: $00000000; EndAddress: $0000003F; RealAddress: $00000000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'Firmware'),
    (StartAddress: $00000040; EndAddress: $0000B0FF; RealAddress: $00000040;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM'),
    (StartAddress: $0000B100; EndAddress: $0000BFFF; RealAddress: $0000B100;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'Stack and Firmware Data'),
    (StartAddress: $0000C000; EndAddress: $0000FFFF; RealAddress: $0000C000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'Screen Memory'),
    (StartAddress: $00010000; EndAddress: $0008FFFF; RealAddress: $00010000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'Extended RAM'),
    (StartAddress: $00000000; EndAddress: $0000FFFF; RealAddress: $00000000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'Main RAM'),
    (StartAddress: $00010000; EndAddress: $0001FFFF; RealAddress: $00010000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'Auxillary RAM'),
    (StartAddress: $00000000; EndAddress: $000FFFFF; RealAddress: $00200000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'Work RAM Low'),
    (StartAddress: $00100000; EndAddress: $001FFFFF; RealAddress: $06000000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'Work RAM High'),
    (StartAddress: $00000000; EndAddress: $00FFFFFF; RealAddress: $0C000000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM'),
    (StartAddress: $00000000; EndAddress: $007FFFFF; RealAddress: $08000000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'Kernel RAM'),
    (StartAddress: $00800000; EndAddress: $01FFFFFF; RealAddress: $08800000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM'),
    (StartAddress: $02000000; EndAddress: $03FFFFFF; RealAddress: $0A000000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'Extended RAM'),
    (StartAddress: $00000000; EndAddress: $001FFFFF; RealAddress: $00000000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'Main RAM'),
    (StartAddress: $00000000; EndAddress: $000003FF; RealAddress: $00006000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM'),
    (StartAddress: $00000400; EndAddress: $000023FF; RealAddress: $00010000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'SGM Low RAM'),
    (StartAddress: $00002400; EndAddress: $000083FF; RealAddress: $00012000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'SGM High RAM'),
    (StartAddress: $00000000; EndAddress: $0000007F; RealAddress: $00FFFFFF;
      Kind: TRAMemoryRegionKind.VideoRAM; Description: ''),
    (StartAddress: $00000080; EndAddress: $0000027F; RealAddress: $00000000;
      Kind: TRAMemoryRegionKind.HardwareController; Description: 'STIC Registers'),
    (StartAddress: $00000280; EndAddress: $0000047F; RealAddress: $00000080;
      Kind: TRAMemoryRegionKind.Unused; Description: ''),
    (StartAddress: $00000480; EndAddress: $00000DFF; RealAddress: $00000100;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM'),
    (StartAddress: $00000E00; EndAddress: $0000107F; RealAddress: $00000360;
      Kind: TRAMemoryRegionKind.Unused; Description: ''),
    (StartAddress: $00001080; EndAddress: $0000407F; RealAddress: $00000400;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'Cartridge RAM'),
    (StartAddress: $00004080; EndAddress: $0000807F; RealAddress: $00001000;
      Kind: TRAMemoryRegionKind.Unused; Description: ''),
    (StartAddress: $00008080; EndAddress: $0000C07F; RealAddress: $00002000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'Cartridge RAM'),
    (StartAddress: $0000C080; EndAddress: $0001007F; RealAddress: $00003000;
      Kind: TRAMemoryRegionKind.HardwareController; Description: 'Video RAM'),
    (StartAddress: $00010080; EndAddress: $0004007F; RealAddress: $00004000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'Cartridge RAM'),
    (StartAddress: $00000000; EndAddress: $000003FF; RealAddress: $0000C800;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM'),
    (StartAddress: $00000000; EndAddress: $0000FFFF; RealAddress: $00000000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'Main RAM'),
    (StartAddress: $00010000; EndAddress: $00010FFF; RealAddress: $00010000;
      Kind: TRAMemoryRegionKind.VideoRAM; Description: 'Text VRAM'),
    (StartAddress: $00000000; EndAddress: $001FFFFF; RealAddress: $00000000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM'),
    (StartAddress: $00200000; EndAddress: $00207FFF; RealAddress: $E0000000;
      Kind: TRAMemoryRegionKind.SaveRAM; Description: 'Internal Backup Memory'),
    (StartAddress: $00208000; EndAddress: $0020FFFF; RealAddress: $E8000000;
      Kind: TRAMemoryRegionKind.SaveRAM; Description: 'External Backup Memory'),
    (StartAddress: $00000000; EndAddress: $000017FF; RealAddress: $00000000;
      Kind: TRAMemoryRegionKind.HardwareController; Description: 'Hardware Interface'),
    (StartAddress: $00001800; EndAddress: $000027FF; RealAddress: $00001800;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM'),
    (StartAddress: $00002800; EndAddress: $00002FFF; RealAddress: $00002800;
      Kind: TRAMemoryRegionKind.VirtualRAM; Description: 'Mirrored RAM'),
    (StartAddress: $00003000; EndAddress: $000037FF; RealAddress: $00003000;
      Kind: TRAMemoryRegionKind.VirtualRAM; Description: 'Mirrored RAM'),
    (StartAddress: $00003800; EndAddress: $00003FFF; RealAddress: $00003800;
      Kind: TRAMemoryRegionKind.VirtualRAM; Description: 'Mirrored RAM'),
    (StartAddress: $00004000; EndAddress: $00007FFF; RealAddress: $00004000;
      Kind: TRAMemoryRegionKind.SaveRAM; Description: 'Cartridge RAM'),
    (StartAddress: $00008000; EndAddress: $0000FFFF; RealAddress: $00008000;
      Kind: TRAMemoryRegionKind.ReadOnly; Description: 'Cartridge ROM'),
    (StartAddress: $00000000; EndAddress: $0000FFFF; RealAddress: $00000000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM'),
    (StartAddress: $00010000; EndAddress: $0008FFFF; RealAddress: $00010000;
      Kind: TRAMemoryRegionKind.SaveRAM; Description: 'Cartridge RAM'),
    (StartAddress: $00000000; EndAddress: $00000FFF; RealAddress: $00000000;
      Kind: TRAMemoryRegionKind.ReadOnly; Description: 'System ROM'),
    (StartAddress: $00001000; EndAddress: $00001FFF; RealAddress: $00001000;
      Kind: TRAMemoryRegionKind.Unused; Description: ''),
    (StartAddress: $00002000; EndAddress: $00003FFF; RealAddress: $00002000;
      Kind: TRAMemoryRegionKind.VideoRAM; Description: 'Video RAM'),
    (StartAddress: $00004000; EndAddress: $00007FFF; RealAddress: $00004000;
      Kind: TRAMemoryRegionKind.Unused; Description: ''),
    (StartAddress: $00008000; EndAddress: $0000FF7F; RealAddress: $00008000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'Cartridge RAM'),
    (StartAddress: $0000FF80; EndAddress: $0000FFFF; RealAddress: $0000FF80;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM'),
    (StartAddress: $00000000; EndAddress: $0000F2FF; RealAddress: $00100000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM'),
    (StartAddress: $0000F300; EndAddress: $0000FFFF; RealAddress: $0010F300;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'Reserved RAM'),
    (StartAddress: $00000000; EndAddress: $0000003F; RealAddress: $00100000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM'),
    (StartAddress: $00000040; EndAddress: $0000083F; RealAddress: $00300000;
      Kind: TRAMemoryRegionKind.VideoRAM; Description: 'Video RAM'),
    (StartAddress: $00000840; EndAddress: $0001083F; RealAddress: $00000000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'Cartridge RAM'),
    (StartAddress: $00010840; EndAddress: $00010C3F; RealAddress: $00200000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'F2102 RAM'),
    (StartAddress: $00000000; EndAddress: $00003FFF; RealAddress: $00004000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'Screen RAM'),
    (StartAddress: $00004000; EndAddress: $00007FFF; RealAddress: $00008000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM'),
    (StartAddress: $00008000; EndAddress: $0000BFFF; RealAddress: $0000C000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM'),
    (StartAddress: $0000C000; EndAddress: $0000FFFF; RealAddress: $00010000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM'),
    (StartAddress: $00010000; EndAddress: $00013FFF; RealAddress: $00014000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM'),
    (StartAddress: $00014000; EndAddress: $00017FFF; RealAddress: $00018000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM'),
    (StartAddress: $00018000; EndAddress: $0001BFFF; RealAddress: $0001C000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM'),
    (StartAddress: $0001C000; EndAddress: $0001FFFF; RealAddress: $00020000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'Screen RAM'),
    (StartAddress: $00000000; EndAddress: $00001FFF; RealAddress: $00000000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM'),
    (StartAddress: $00002000; EndAddress: $00003FFF; RealAddress: $00002000;
      Kind: TRAMemoryRegionKind.HardwareController; Description: 'Registers'),
    (StartAddress: $00004000; EndAddress: $00005FFF; RealAddress: $00004000;
      Kind: TRAMemoryRegionKind.VideoRAM; Description: 'Video RAM'),
    (StartAddress: $00000000; EndAddress: $00003FFF; RealAddress: $00000000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'Video RAM'),
    (StartAddress: $00004000; EndAddress: $00005FFF; RealAddress: $00004000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'Tile RAM'),
    (StartAddress: $00006000; EndAddress: $00007FFF; RealAddress: $00006000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'Sprite RAM'),
    (StartAddress: $00008000; EndAddress: $0000FF7F; RealAddress: $00008000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'MAP RAM'),
    (StartAddress: $0000FF80; EndAddress: $0000FF8B; RealAddress: $0000FF80;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'Input State'),
    (StartAddress: $0000FF8C; EndAddress: $00014003; RealAddress: $0000FF8C;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'Sound RAM'),
    (StartAddress: $00014004; EndAddress: $00014403; RealAddress: $00014004;
      Kind: TRAMemoryRegionKind.SaveRAM; Description: 'Persistent Memory'),
    (StartAddress: $00014404; EndAddress: $00014603; RealAddress: $00014404;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'Sprite Flags'),
    (StartAddress: $00014604; EndAddress: $00014E03; RealAddress: $00014604;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System Font'),
    (StartAddress: $00014E04; EndAddress: $00017FFF; RealAddress: $00014E04;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM'),
    (StartAddress: $00000000; EndAddress: $0007FFFF; RealAddress: $00000000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM'),
    (StartAddress: $00000000; EndAddress: $000000FF; RealAddress: $00000000;
      Kind: TRAMemoryRegionKind.HardwareController; Description: 'Interrupt vector'),
    (StartAddress: $00000100; EndAddress: $0000014F; RealAddress: $00000100;
      Kind: TRAMemoryRegionKind.ReadOnly; Description: 'Cartridge header'),
    (StartAddress: $00000150; EndAddress: $00003FFF; RealAddress: $00000150;
      Kind: TRAMemoryRegionKind.ReadOnly; Description: 'Cartridge ROM (fixed)'),
    (StartAddress: $00004000; EndAddress: $00007FFF; RealAddress: $00004000;
      Kind: TRAMemoryRegionKind.ReadOnly; Description: 'Cartridge ROM (paged)'),
    (StartAddress: $00008000; EndAddress: $000097FF; RealAddress: $00008000;
      Kind: TRAMemoryRegionKind.VideoRAM; Description: 'Tile RAM'),
    (StartAddress: $00009800; EndAddress: $00009BFF; RealAddress: $00009800;
      Kind: TRAMemoryRegionKind.VideoRAM; Description: 'BG1 map data'),
    (StartAddress: $00009C00; EndAddress: $00009FFF; RealAddress: $00009C00;
      Kind: TRAMemoryRegionKind.VideoRAM; Description: 'BG2 map data'),
    (StartAddress: $0000A000; EndAddress: $0000BFFF; RealAddress: $0000A000;
      Kind: TRAMemoryRegionKind.SaveRAM; Description: 'Cartridge RAM (bank 0)'),
    (StartAddress: $0000C000; EndAddress: $0000CFFF; RealAddress: $0000C000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM (fixed)'),
    (StartAddress: $0000D000; EndAddress: $0000DFFF; RealAddress: $0000D000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM (fixed)'),
    (StartAddress: $0000E000; EndAddress: $0000FDFF; RealAddress: $0000C000;
      Kind: TRAMemoryRegionKind.VirtualRAM; Description: 'Echo RAM'),
    (StartAddress: $0000FE00; EndAddress: $0000FE9F; RealAddress: $0000FE00;
      Kind: TRAMemoryRegionKind.VideoRAM; Description: 'Sprite RAM'),
    (StartAddress: $0000FEA0; EndAddress: $0000FEFF; RealAddress: $0000FEA0;
      Kind: TRAMemoryRegionKind.Unused; Description: ''),
    (StartAddress: $0000FF00; EndAddress: $0000FF7F; RealAddress: $0000FF00;
      Kind: TRAMemoryRegionKind.HardwareController; Description: 'Hardware I/O'),
    (StartAddress: $0000FF80; EndAddress: $0000FFFE; RealAddress: $0000FF80;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'Quick RAM'),
    (StartAddress: $0000FFFF; EndAddress: $0000FFFF; RealAddress: $0000FFFF;
      Kind: TRAMemoryRegionKind.HardwareController; Description: 'Interrupt enable'),
    (StartAddress: $00000000; EndAddress: $000000FF; RealAddress: $00000000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'Registers'),
    (StartAddress: $00000100; EndAddress: $00000AFF; RealAddress: $00000100;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM'),
    (StartAddress: $00000B00; EndAddress: $00000EFF; RealAddress: $80000000;
      Kind: TRAMemoryRegionKind.SaveRAM; Description: 'EEPROM'),
    (StartAddress: $00000000; EndAddress: $000000FF; RealAddress: $00001800;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM'),
    (StartAddress: $00000100; EndAddress: $000001FF; RealAddress: $00001900;
      Kind: TRAMemoryRegionKind.HardwareController; Description: 'I/O Area'),
    (StartAddress: $00000200; EndAddress: $000002FF; RealAddress: $00001A00;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM'),
    (StartAddress: $00000000; EndAddress: $000003FF; RealAddress: $00001800;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'Cartridge RAM'),
    (StartAddress: $00000400; EndAddress: $000004FF; RealAddress: $00001E00;
      Kind: TRAMemoryRegionKind.HardwareController; Description: 'I/O Area'),
    (StartAddress: $00000500; EndAddress: $000005FF; RealAddress: $00001F00;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM'),
    (StartAddress: $00000000; EndAddress: $000013FF; RealAddress: $00000800;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM'),
    (StartAddress: $00001400; EndAddress: $000014FF; RealAddress: $00001C00;
      Kind: TRAMemoryRegionKind.Unused; Description: 'Unused'),
    (StartAddress: $00001500; EndAddress: $000016FF; RealAddress: $00001D00;
      Kind: TRAMemoryRegionKind.HardwareController; Description: 'I/O Area'),
    (StartAddress: $00001700; EndAddress: $000017FF; RealAddress: $00001F00;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM'),
    (StartAddress: $00000000; EndAddress: $00001FFF; RealAddress: $001F0000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM'),
    (StartAddress: $00002000; EndAddress: $00011FFF; RealAddress: $00100000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'CD RAM'),
    (StartAddress: $00012000; EndAddress: $00041FFF; RealAddress: $000D0000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'Super System Card RAM'),
    (StartAddress: $00042000; EndAddress: $000427FF; RealAddress: $001EE000;
      Kind: TRAMemoryRegionKind.SaveRAM; Description: 'CD Battery-backed RAM'),
    (StartAddress: $00000000; EndAddress: $00FFFFFF; RealAddress: $02000000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM'),
    (StartAddress: $01000000; EndAddress: $01003FFF; RealAddress: $0E000000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'Data TCM'),
    (StartAddress: $00000000; EndAddress: $00007FFF; RealAddress: $00008000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM'),
    (StartAddress: $00000000; EndAddress: $00000FFF; RealAddress: $00000000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM'),
    (StartAddress: $00000000; EndAddress: $000007FF; RealAddress: $00000000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'System RAM'),
    (StartAddress: $00000800; EndAddress: $00000FFF; RealAddress: $00000000;
      Kind: TRAMemoryRegionKind.VirtualRAM; Description: 'Mirror RAM'),
    (StartAddress: $00001000; EndAddress: $000017FF; RealAddress: $00000000;
      Kind: TRAMemoryRegionKind.VirtualRAM; Description: 'Mirror RAM'),
    (StartAddress: $00001800; EndAddress: $00001FFF; RealAddress: $00000000;
      Kind: TRAMemoryRegionKind.VirtualRAM; Description: 'Mirror RAM'),
    (StartAddress: $00002000; EndAddress: $00002007; RealAddress: $00002000;
      Kind: TRAMemoryRegionKind.HardwareController; Description: 'PPU Register'),
    (StartAddress: $00002008; EndAddress: $00003FFF; RealAddress: $00002008;
      Kind: TRAMemoryRegionKind.VirtualRAM; Description: 'Mirrored PPU Register'),
    (StartAddress: $00004000; EndAddress: $00004017; RealAddress: $00004000;
      Kind: TRAMemoryRegionKind.HardwareController; Description: 'APU and I/O register'),
    (StartAddress: $00004018; EndAddress: $0000401F; RealAddress: $00004018;
      Kind: TRAMemoryRegionKind.HardwareController; Description: 'APU and I/O test register'),
    (StartAddress: $00004020; EndAddress: $000040FF; RealAddress: $00004020;
      Kind: TRAMemoryRegionKind.HardwareController; Description: 'FDS I/O registers'),
    (StartAddress: $00004100; EndAddress: $00005FFF; RealAddress: $00004100;
      Kind: TRAMemoryRegionKind.ReadOnly; Description: 'Cartridge data'),
    (StartAddress: $00006000; EndAddress: $0000DFFF; RealAddress: $00006000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'FDS RAM'),
    (StartAddress: $0000E000; EndAddress: $0000FFFF; RealAddress: $0000E000;
      Kind: TRAMemoryRegionKind.ReadOnly; Description: 'FDS BIOS ROM'),
    (StartAddress: $00000000; EndAddress: $0FFFFFFF; RealAddress: $00000000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'Main RAM'),
    (StartAddress: $10000000; EndAddress: $2FFFFFFF; RealAddress: $10000000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'RSX Context + User RAM (64K pages)'),
    (StartAddress: $30000000; EndAddress: $3FFFFFFF; RealAddress: $30000000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'User RAM (64K pages)'),
    (StartAddress: $40000000; EndAddress: $4FFFFFFF; RealAddress: $40000000;
      Kind: TRAMemoryRegionKind.SystemRAM; Description: 'User RAM (1M pages)')
  );
  ConsoleDefinitions: array[0..102] of TRAConsoleDefinition = (
    (Name: 'Unknown'; FirstRegion: 0; RegionCount: 0),
    (Name: 'Sega Genesis'; FirstRegion: 0; RegionCount: 2),
    (Name: 'Nintendo 64'; FirstRegion: 2; RegionCount: 3),
    (Name: 'Super Nintendo Entertainment System'; FirstRegion: 5; RegionCount: 3),
    (Name: 'GameBoy'; FirstRegion: 8; RegionCount: 18),
    (Name: 'GameBoy Advance'; FirstRegion: 26; RegionCount: 3),
    (Name: 'GameBoy Color'; FirstRegion: 29; RegionCount: 18),
    (Name: 'Nintendo Entertainment System'; FirstRegion: 47; RegionCount: 11),
    (Name: 'PC Engine'; FirstRegion: 58; RegionCount: 1),
    (Name: 'Sega CD'; FirstRegion: 59; RegionCount: 3),
    (Name: 'Sega 32X'; FirstRegion: 62; RegionCount: 3),
    (Name: 'Master System'; FirstRegion: 65; RegionCount: 2),
    (Name: 'PlayStation'; FirstRegion: 67; RegionCount: 3),
    (Name: 'Atari Lynx'; FirstRegion: 70; RegionCount: 7),
    (Name: 'Neo Geo Pocket'; FirstRegion: 77; RegionCount: 1),
    (Name: 'Game Gear'; FirstRegion: 65; RegionCount: 2),
    (Name: 'GameCube'; FirstRegion: 78; RegionCount: 1),
    (Name: 'Atari Jaguar'; FirstRegion: 79; RegionCount: 1),
    (Name: 'Nintendo DS'; FirstRegion: 80; RegionCount: 3),
    (Name: 'Wii'; FirstRegion: 83; RegionCount: 3),
    (Name: 'Wii-U'; FirstRegion: 0; RegionCount: 0),
    (Name: 'PlayStation 2'; FirstRegion: 86; RegionCount: 3),
    (Name: 'XBOX'; FirstRegion: 89; RegionCount: 1),
    (Name: 'Magnavox Odyssey 2'; FirstRegion: 90; RegionCount: 2),
    (Name: 'Pokemon Mini'; FirstRegion: 92; RegionCount: 2),
    (Name: 'Atari 2600'; FirstRegion: 94; RegionCount: 1),
    (Name: 'MS-DOS'; FirstRegion: 95; RegionCount: 5),
    (Name: 'Arcade'; FirstRegion: 0; RegionCount: 0),
    (Name: 'Virtual Boy'; FirstRegion: 100; RegionCount: 2),
    (Name: 'MSX'; FirstRegion: 102; RegionCount: 1),
    (Name: 'Commodore 64'; FirstRegion: 103; RegionCount: 7),
    (Name: 'ZX-81'; FirstRegion: 0; RegionCount: 0),
    (Name: 'Oric'; FirstRegion: 110; RegionCount: 1),
    (Name: 'SG-1000'; FirstRegion: 111; RegionCount: 4),
    (Name: 'VIC-20'; FirstRegion: 0; RegionCount: 0),
    (Name: 'Amiga'; FirstRegion: 115; RegionCount: 2),
    (Name: 'Atari ST'; FirstRegion: 0; RegionCount: 0),
    (Name: 'Amstrad CPC'; FirstRegion: 117; RegionCount: 5),
    (Name: 'Apple II'; FirstRegion: 122; RegionCount: 2),
    (Name: 'Sega Saturn'; FirstRegion: 124; RegionCount: 2),
    (Name: 'Dreamcast'; FirstRegion: 126; RegionCount: 1),
    (Name: 'PlayStation Portable'; FirstRegion: 127; RegionCount: 3),
    (Name: 'CD-I'; FirstRegion: 0; RegionCount: 0),
    (Name: '3DO'; FirstRegion: 130; RegionCount: 1),
    (Name: 'ColecoVision'; FirstRegion: 131; RegionCount: 3),
    (Name: 'Intellivision'; FirstRegion: 134; RegionCount: 10),
    (Name: 'Vectrex'; FirstRegion: 144; RegionCount: 1),
    (Name: 'PC-8000/8800'; FirstRegion: 145; RegionCount: 2),
    (Name: 'PC-9800'; FirstRegion: 0; RegionCount: 0),
    (Name: 'PC-FX'; FirstRegion: 147; RegionCount: 3),
    (Name: 'Atari 5200'; FirstRegion: 0; RegionCount: 0),
    (Name: 'Atari 7800'; FirstRegion: 150; RegionCount: 7),
    (Name: 'X68K'; FirstRegion: 0; RegionCount: 0),
    (Name: 'WonderSwan'; FirstRegion: 157; RegionCount: 2),
    (Name: 'CassetteVision'; FirstRegion: 0; RegionCount: 0),
    (Name: 'Super CassetteVision'; FirstRegion: 159; RegionCount: 6),
    (Name: 'Neo Geo CD'; FirstRegion: 165; RegionCount: 2),
    (Name: 'Fairchild Channel F'; FirstRegion: 167; RegionCount: 4),
    (Name: 'FM Towns'; FirstRegion: 0; RegionCount: 0),
    (Name: 'ZX Spectrum'; FirstRegion: 171; RegionCount: 8),
    (Name: 'Game & Watch'; FirstRegion: 0; RegionCount: 0),
    (Name: 'Nokia N-Gage'; FirstRegion: 0; RegionCount: 0),
    (Name: 'Nintendo 3DS'; FirstRegion: 0; RegionCount: 0),
    (Name: 'Watara Supervision'; FirstRegion: 179; RegionCount: 3),
    (Name: 'Sharp X1'; FirstRegion: 0; RegionCount: 0),
    (Name: 'TIC-80'; FirstRegion: 182; RegionCount: 10),
    (Name: 'Thomson TO8'; FirstRegion: 192; RegionCount: 1),
    (Name: 'PC-6000'; FirstRegion: 0; RegionCount: 0),
    (Name: 'Sega Pico'; FirstRegion: 0; RegionCount: 0),
    (Name: 'Mega Duck'; FirstRegion: 193; RegionCount: 16),
    (Name: 'Zeebo'; FirstRegion: 0; RegionCount: 0),
    (Name: 'Arduboy'; FirstRegion: 209; RegionCount: 3),
    (Name: 'WASM-4'; FirstRegion: 110; RegionCount: 1),
    (Name: 'Arcadia 2001'; FirstRegion: 212; RegionCount: 3),
    (Name: 'Interton VC 4000'; FirstRegion: 215; RegionCount: 3),
    (Name: 'Elektor TV Games Computer'; FirstRegion: 218; RegionCount: 4),
    (Name: 'PC Engine CD'; FirstRegion: 222; RegionCount: 4),
    (Name: 'Atari Jaguar CD'; FirstRegion: 79; RegionCount: 1),
    (Name: 'Nintendo DSi'; FirstRegion: 226; RegionCount: 2),
    (Name: 'TI-83'; FirstRegion: 228; RegionCount: 1),
    (Name: 'Uzebox'; FirstRegion: 229; RegionCount: 1),
    (Name: 'Famicom Disk System'; FirstRegion: 230; RegionCount: 12),
    (Name: 'PlayStation 3'; FirstRegion: 242; RegionCount: 4),
    (Name: 'Unknown'; FirstRegion: 0; RegionCount: 0),
    (Name: 'Unknown'; FirstRegion: 0; RegionCount: 0),
    (Name: 'Unknown'; FirstRegion: 0; RegionCount: 0),
    (Name: 'Unknown'; FirstRegion: 0; RegionCount: 0),
    (Name: 'Unknown'; FirstRegion: 0; RegionCount: 0),
    (Name: 'Unknown'; FirstRegion: 0; RegionCount: 0),
    (Name: 'Unknown'; FirstRegion: 0; RegionCount: 0),
    (Name: 'Unknown'; FirstRegion: 0; RegionCount: 0),
    (Name: 'Unknown'; FirstRegion: 0; RegionCount: 0),
    (Name: 'Unknown'; FirstRegion: 0; RegionCount: 0),
    (Name: 'Unknown'; FirstRegion: 0; RegionCount: 0),
    (Name: 'Unknown'; FirstRegion: 0; RegionCount: 0),
    (Name: 'Unknown'; FirstRegion: 0; RegionCount: 0),
    (Name: 'Unknown'; FirstRegion: 0; RegionCount: 0),
    (Name: 'Unknown'; FirstRegion: 0; RegionCount: 0),
    (Name: 'Unknown'; FirstRegion: 0; RegionCount: 0),
    (Name: 'Unknown'; FirstRegion: 0; RegionCount: 0),
    (Name: 'Hubs'; FirstRegion: 0; RegionCount: 0),
    (Name: 'Events'; FirstRegion: 0; RegionCount: 0),
    (Name: 'Standalone'; FirstRegion: 0; RegionCount: 0)
  );

function RAConsoleName(ConsoleID: Cardinal): string;
begin
  if ConsoleID > High(ConsoleDefinitions) then
    ConsoleID := RAConsoleUnknown;
  Result := ConsoleDefinitions[ConsoleID].Name;
end;

function RAConsoleMemoryRegions(ConsoleID: Cardinal): TArray<TRAMemoryRegion>;
var
  Definition: TRAConsoleDefinition;
begin
  Result := nil;
  if ConsoleID > High(ConsoleDefinitions) then
    Exit;
  Definition := ConsoleDefinitions[ConsoleID];
  SetLength(Result, Definition.RegionCount);
  for var Index := 0 to Definition.RegionCount - 1 do
    Result[Index] := MemoryRegions[Definition.FirstRegion + Index];
end;

function RAConsoleMaxAddress(ConsoleID: Cardinal): Cardinal;
var
  Definition: TRAConsoleDefinition;
begin
  Result := High(Cardinal);
  if ConsoleID > High(ConsoleDefinitions) then
    Exit;
  Definition := ConsoleDefinitions[ConsoleID];
  if Definition.RegionCount <> 0 then
    Result := MemoryRegions[Definition.FirstRegion + Definition.RegionCount - 1].EndAddress;
end;

end.

