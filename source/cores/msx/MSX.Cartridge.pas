unit MSX.Cartridge;

interface

uses
  System.SysUtils, System.Classes, Core.Snapshots, MSX.Sound.SCC, MSX.Sound.OPLL,
  MSX.AudioBoard;

type
  TMSXMapper = (Plain, ASCII8, ASCII16, Konami, KonamiSCC, ASCII8SRAM,
    ASCII16SRAM, RType, GameMaster2, KoeiSRAM32, FMPAC, PAC,
    SCCPlus, SnatcherSCC, SDSnatcherSCC, PhilipsAudio, PanasonicAudio);

  TMSXMapperSet = set of TMSXMapper;

  TMSXMapperSource = (MapperFallback, MapperCode, MapperSignature, MapperDatabase);

  TMSXMapperConfidence = (MapperLow, MapperMedium, MapperHigh);

  TMSXMapperDetection = record
    Mapper: TMSXMapper;
    Candidates: TMSXMapperSet;
    Source: TMSXMapperSource;
    Confidence: TMSXMapperConfidence;
    Instructions, WriteSites: Integer;
    AnalysisLimited: Boolean;
  end;

  TMSXCartridge = class
  private
    FData: TBytes;
    FMapper: TMSXMapper;
    FBanks: array[0..3] of Byte;
    FRAM: array[0..$7FFF] of Byte;
    FPlainBase: Integer;
    FSCC: TSCC;
    FFM: TYM2413;
    FAudio: TMSXAudioBoard;
    FPACLow, FPACHigh, FFMControl: Byte;
    FSoundRAM: TBytes;
    FSoundMode: Byte;
    FDirty: Boolean;
    function ROMByte(Offset: Integer): Byte;
    function SRAMBank(Bank: Byte): Boolean;
    function PACEnabled: Boolean;
    function SoundBankPresent(Bank: Integer): Boolean;
    function SoundWindow(Address: Word): Boolean;
  public
    constructor Create(const Data: TBytes; MapperHint: Integer = -1);
    destructor Destroy; override;
    procedure Reset;
    function Read(Address: Word): Byte;
    procedure Write(Address: Word; Value: Byte);
    procedure WritePort(Port, Value: Byte);
    procedure AdvanceClocks(Cycles: Integer);
    function ReadPort(Port: Byte): Byte;
    function Interrupt: Boolean;
    procedure ConfigureAudioRAM(Bytes: Integer);
    function Sample: SmallInt;
    procedure SerializeState(State: TStateArchive);
    procedure LoadRAM(const Data: TBytes);
    function SaveRAM: TBytes;
    class function Recognizes(const Data: TBytes): Boolean; static;
    class function DetectMapper(const Data: TBytes; UseKnownHashes: Boolean = True): TMSXMapper; static;
    class function AnalyzeMapper(const Data: TBytes; UseKnownHashes: Boolean = True): TMSXMapperDetection; static;
    property Mapper: TMSXMapper read FMapper;
    property Dirty: Boolean read FDirty;
    property AudioBoard: TMSXAudioBoard read FAudio;
  end;

implementation

uses
  System.Hash, System.Math, MSX.MapperAnalysis;

{$REGION 'Known cartridge mappers'}
// Mapper identities for the Emu-Land MSX regression corpus.
// Metadata cross-checked against blueMSX msxromdb.xml (2012-12-09).
// Hardware behavior is implemented independently in MSX.Cartridge.
type
  TMSXKnownMapper = record
    Hash: string[40];
    Mapper: TMSXMapper;
  end;

const
  MSXKnownMappers: array[0..119] of TMSXKnownMapper = (
    (Hash: '0413bb3aeacb0c28429b8c85b42796dbe48bef6d'; Mapper: KonamiSCC) { Gofer no Yabou Episode 2 - Nemesis 3 The Eve Of Destruction },
    (Hash: '05280f0a26ac5c42ab63b80a487bb909683e7461'; Mapper: ASCII8) { Dragon Quest 2 - MSX2 Version },
    (Hash: '0733cd627467a866846e15caf1770a5594eaf4cc'; Mapper: ASCII8) { 1942 - MSX1 Version },
    (Hash: '07448ffb20f260df159a19df2cae1ee5545a0aef'; Mapper: Plain) { King's Valley },
    (Hash: '09af3b68be4eea5f5594d5d2d124d92b127dd390'; Mapper: Plain) { Macross },
    (Hash: '0cf26bf02c5b94df118129a681a7f14add708177'; Mapper: Plain) { King's Valley },
    (Hash: '0d459788b6c464b50cbc2436e67a2cef248e0c4a'; Mapper: KonamiSCC) { Salamander - Operation X },
    (Hash: '12f6f31f495bfb384c9ca9067bfbf8f98af6adf9'; Mapper: ASCII16) { Aleste },
    (Hash: '1642891b693df616f27431299352e1d7750ac94b'; Mapper: ASCII8) { Arkanoid 2 },
    (Hash: '1f17e46190635a3214057d33ad4a768939d5a071'; Mapper: ASCII16) { Acrojet },
    (Hash: '2183f07fa3ba87360100b2fa21fda0f55c0f8814'; Mapper: Plain) { Arkanoid },
    (Hash: '21ac0ae7da47abf30986b479489134c79405f95d'; Mapper: KonamiSCC) { Metal Gear 2 - Solid Snake - Demo },
    (Hash: '2220363ae56ef707ab2471fcdb36f4816ad1d32c'; Mapper: KonamiSCC) { Parodius - Tako Saves Earth },
    (Hash: '23e702084e3031158a50a0560746767bbc1b7bee'; Mapper: ASCII16) { Zanac-Ex },
    (Hash: '25f5adeca8a2ddb754d25eb18cff0d84e5b003bc'; Mapper: Konami) { Knightmare III - Shalom },
    (Hash: '2a34f0221193712c43f336f08d2a6e58a1a8974a'; Mapper: Plain) { Galaga },
    (Hash: '2a4aef32db28c059c30f5f972f1c09708ef6ce62'; Mapper: KoeiSRAM32) { Daikoukai Jidai },
    (Hash: '2e0436303648097e8e936c5467574aff5e3f1517'; Mapper: KonamiSCC) { King's Valley 2 - The Seal Of El Giza - MSX2 Edit Contest Version },
    (Hash: '2fc050dbc44ba9dfb72299129d48e5e5e1c892c3'; Mapper: ASCII8) { Star Virgin },
    (Hash: '3194153a9c93aa24b37804a764f112bdef091bf8'; Mapper: ASCII8SRAM) { Siryousensen - War Of The Dead },
    (Hash: '32dd4df2b39461c0694f6bb84de0709478a69d31'; Mapper: ASCII16) { Gakuen Monogatari - High School Story },
    (Hash: '33536dac686b375ba13faf76a3baf2d6978904e0'; Mapper: Plain) { 10 Yard Fight },
    (Hash: '37bd4680a36c3a1a078e2bc47b631d858d9296b8'; Mapper: RType) { R-Type },
    (Hash: '397716d26a075c6d731f0b04f3fa24aa39521798'; Mapper: Plain) { Dragon Slayer 1 },
    (Hash: '3df7c19f739d74d6efdfd8151343e5a55d4ac842'; Mapper: ASCII8) { Dragon Quest 2 - MSX1 Version },
    (Hash: '414fd2a22076f45502c2329b45bda9f8730dcaae'; Mapper: ASCII8SRAM) { Taiyou no Shinden - Asteka II },
    (Hash: '418f6248221c79039fe6c44fc5a9514842e3ec71'; Mapper: ASCII8) { Project A2 },
    (Hash: '42fbb18722df3e34e5b0f935a2dc0ce0d85099e9'; Mapper: KonamiSCC) { F1 Spirit - The Way To Formula 1 },
    (Hash: '469b07eef08348c9acc14e63ba0cd35aef236983'; Mapper: Plain) { Back To The Future },
    (Hash: '46e9ed7b7f6dfda8eee266476c9ebc4dd9d8fcc2'; Mapper: Plain) { Zanac A.I. },
    (Hash: '475c3af7495922759a5f424d2e22d7e4073d5992'; Mapper: KoeiSRAM32) { Europe War },
    (Hash: '4b04574b3b71958664ac730987c4c8ebedeba890'; Mapper: Plain) { Lode Runner 2 },
    (Hash: '4d51d3c5036311392b173a576bc7d91dc9fed6cb'; Mapper: Konami) { Knightmare II - The Maze of Galious },
    (Hash: '4ff2aad8371e382e203c7f29b665612a8c9d937c'; Mapper: Konami) { Treasure Of Usas, The },
    (Hash: '5324e053709ff8da6c18ae4afba6a2e0c3a722ba'; Mapper: Plain) { Bomber Man },
    (Hash: '5380e913d8dac23470446844cab21f6921101af8'; Mapper: ASCII16) { Aliens 2 },
    (Hash: '5400c0c929b31a70e76aac676b91d40445f1b427'; Mapper: Plain) { Black Onyx 1, The },
    (Hash: '5460a88c25386b1b950b57fc1325fd75587cc825'; Mapper: Konami) { Akumajyo Drakyula - Vampire Killer },
    (Hash: '55183b7b7df66950dbb65ef1065d7d987e0fdf5a'; Mapper: ASCII16) { Andorogynus },
    (Hash: '5577e483caca553cfbfc0cba26f3ab2444569f81'; Mapper: ASCII8) { Dragon Quest 1 - MSX2 Version },
    (Hash: '55fb4e3d3a762b613b635ee9745d92f0f3711272'; Mapper: ASCII8) { Maison Ikkoku Final },
    (Hash: '57827f8d49369e4dbf20a968e535374d35ff1648'; Mapper: Plain) { Yie Ar Kung-Fu II - The Emperor Yie-Gah },
    (Hash: '5bbcbd47f05a2742cfb0cad88856eb2df6e469fe'; Mapper: Plain) { Tank Battalion },
    (Hash: '5c278deb1390eb45c79b7667b1ea1c54183123ac'; Mapper: ASCII8) { Ninja Kun - Ashura no Sho },
    (Hash: '5ec8811254dc762c6852289a08acf22954404f0d'; Mapper: KonamiSCC) { King's Valley 2 - The Seal Of El Giza - MSX2 Version },
    (Hash: '5ef7d03b138a2023f6def241b671c666f97ed83b'; Mapper: Konami) { Akumajyo Drakyula - Vampire Killer },
    (Hash: '5fb90be078e432db92dd39e621d12f612dbea4a8'; Mapper: Plain) { Alien 8 },
    (Hash: '5fd07ed5b7c0492d42ed91a54a0fe80ce6e4e40d'; Mapper: ASCII16SRAM) { Take The A-Train },
    (Hash: '609d0bac4933d1bcc877746a3e14d82c204f40e7'; Mapper: Plain) { Yie Ar Kung-Fu II - The Emperor Yie-Gah },
    (Hash: '612c18616bc800d9eb69b9da3cd29eca31f50c1c'; Mapper: Konami) { Hinotori - Firebird },
    (Hash: '615c08820b926e28b143cd7812852e011d3eeffb'; Mapper: Plain) { Castle, The },
    (Hash: '61695eb1dc6242d8a70c7ef2172cf86a26e3c2dd'; Mapper: Plain) { Pac-Man },
    (Hash: '632cb0834441626d20cc113cfad2e3a7ec0e0dc7'; Mapper: Konami) { Treasure Of Usas, The },
    (Hash: '639cb280544b060a618af23daf234a44baaf88de'; Mapper: Plain) { Alibaba And 40 Thieves },
    (Hash: '66508bbdc3b133b9a69ea96789bc134eea46796a'; Mapper: ASCII16) { A-Class Mahjong },
    (Hash: '6844758ff5c2c410115d4d7cf12498c42e931732'; Mapper: KonamiSCC) { Gradius 2 - Nemesis 2 Beta },
    (Hash: '6b8a684ddbadd798a8e599449b823bceca9cdb58'; Mapper: Plain) { A.E. },
    (Hash: '6bde4e6761286a2909858ecef04155e17072996e'; Mapper: ASCII8) { A Life M36 Planet },
    (Hash: '6c1814c70d69a50ec60e39ef281f0b8cd7bf8598'; Mapper: ASCII8SRAM) { Dragon Slayer 2 - Xanadu },
    (Hash: '6d7a8ea1b283ecc1cc94c359e5f053a6e82ab3f5'; Mapper: ASCII8) { Dragon Slayer 4 - MSX2 Version },
    (Hash: '709fb35338f21897e275237cc4c5615d0a5c2753'; Mapper: ASCII8) { Batman - Rescue The Rovin },
    (Hash: '7393f677e0fae5fc83071c6b74756117b7d75e2d'; Mapper: KonamiSCC) { Gofer no Yabou Episode 2 - Nemesis 3 The Eve Of Destruction },
    (Hash: '7b94a728a5945a53d518c18994e1e09a09ec3c1b'; Mapper: ASCII8) { Dragon Quest 1 - MSX1 Version },
    (Hash: '811dca8fc14a2b00f503fbef74fdeae4f2873d4c'; Mapper: Plain) { Castle Excellent },
    (Hash: '818a6cedbfdf3a5af0c844f32a18e3930178c798'; Mapper: Plain) { Lode Runner },
    (Hash: '866cb3ab10f17e4fb356fbd7277bbf17c4e27ebe'; Mapper: Plain) { Athletic Land },
    (Hash: '87a7fa43602f74c47151e79f1aaf7f641331ba51'; Mapper: ASCII8) { Double Vision },
    (Hash: '90003c78975d00b1e5612fd00dffabb70d616ecd'; Mapper: KonamiSCC) { Contra - Gryzor },
    (Hash: '90bdd12d632d2e909ac5d69235ad0366f430b734'; Mapper: Plain) { Athletic Land },
    (Hash: '937464eb371c68add2236bcef91d24a8ce7c4ed1'; Mapper: KonamiSCC) { A1 Spirit - The Way To Formula 1 },
    (Hash: 'a1e14912d45944b9a6baef1d4d3a04c1ae8df923'; Mapper: Plain) { River Raid },
    (Hash: 'a21adba681956ec35816af673a9d4f6c7743253a'; Mapper: ASCII8) { Crimson },
    (Hash: 'a3090a15c95334da3e0f94030eadee02b5032c0c'; Mapper: Plain) { Yie Ar Kung-Fu },
    (Hash: 'a52021f1b257c7c35d626d5d642134091c45e4f4'; Mapper: Konami) { Metal Gear },
    (Hash: 'a58ca651f4c12bf07cf3840d5e37b534f5fc075e'; Mapper: ASCII16) { Fantasy Zone 2 - The Tears Of Opa-Opa },
    (Hash: 'a72724a79c2c50ec66046c0828934b5cad11b7c9'; Mapper: Plain) { Pac-Man },
    (Hash: 'a8059dc1820b461418713acf2af14f3a25734bd3'; Mapper: ASCII8) { Arugisu no Yoku },
    (Hash: 'a8313b0dce35faa80b399a220f19b04333fdec1d'; Mapper: Plain) { Mappy },
    (Hash: 'aa2ba89e0b1c91a4405f516ef003ad14a401096c'; Mapper: Plain) { Galaxian },
    (Hash: 'ab30cdeaacbdf14e6366d43d881338178fc665cb'; Mapper: KonamiSCC) { Gradius 2 - Nemesis 2 },
    (Hash: 'af310ee21b5534f32ea92c0ae34a44d828d157a7'; Mapper: ASCII8) { Tetris },
    (Hash: 'af567ea6e27912d6d5bf1c8e9bc18e9b393fd1ab'; Mapper: KonamiSCC) { Metal Gear 2 - Solid Snake },
    (Hash: 'b1248f7b9d4e16a894555c51c533d3fd9a90802e'; Mapper: Plain) { Goonies, The },
    (Hash: 'b58e77f819dfbde72845801cff4b4e0a2f20ef5f'; Mapper: Konami) { Akumajyo Drakyula - Vampire Killer },
    (Hash: 'b63fc17c1d004ca4d7f3b1ef8962210a779ca665'; Mapper: ASCII16) { Dragon Slayer 3 - Romancia - MSX2 Version },
    (Hash: 'b9c98b80216983f97e28293b576ca9be3602c1a1'; Mapper: Plain) { Sparkie },
    (Hash: 'bf4a0bab1e8eaa70a8b12cd9a81d7a90a74c9e26'; Mapper: Plain) { Road Fighter },
    (Hash: 'c4a919f31d20008b5d6540aa5d2be59aa4cef5cf'; Mapper: ASCII8) { Arsene Lupin 3rd - Babiron no Ougon Densetsu },
    (Hash: 'c8ff858d239c62a859f15c2f1bf44e1d657cec13'; Mapper: Plain) { Majyo Densetsu - Knightmare },
    (Hash: 'c9135b1e451193bd4c06d8143eaca934cc89fe05'; Mapper: ASCII8) { 1942 - MSX2 Version },
    (Hash: 'cfd872d005b7bd4cdd6e06c4c0162191f0b0415d'; Mapper: KonamiSCC) { King's Valley 2 - The Seal Of El Giza - MSX1 Version },
    (Hash: 'd53e0c8bcd98820afe820f756af35cc97911bfe4'; Mapper: Konami) { Yumetairiku Adventure - Penguin Adventure },
    (Hash: 'd5902afbd8dfb1ea96fc8cf4d62cf6e4fa40d4f7'; Mapper: ASCII8) { Pac-Mania - MSX2 Version },
    (Hash: 'd63e20369f98487767810a0c57603bef6a2a07e5'; Mapper: KonamiSCC) { Gradius 2 - Nemesis 2 },
    (Hash: 'd723f2eb1c887db5448fd56be5e7c57e60d88e63'; Mapper: Konami) { Hinotori - Firebird },
    (Hash: 'e065238580b9e118b6c9e789d797cdd99e0a1c69'; Mapper: ASCII16) { Ikari },
    (Hash: 'e11afc03db4e1d03976d02796b29da9c65d4ff3d'; Mapper: ASCII8) { Fairy Land Story, The },
    (Hash: 'e2abb08abacce57703fc008881279890328f6277'; Mapper: Plain) { Galaxian },
    (Hash: 'e31ac6520e912c27ce96431a1dfb112bf71cb7b9'; Mapper: Konami) { Gradius - Nemesis },
    (Hash: 'e700493e1c4c14f711e9c1c262fe3e8d76931ca3'; Mapper: Plain) { Bomber Man Special },
    (Hash: 'e73946f1f26589d77926276ca4f9dbee60c53fde'; Mapper: ASCII8) { Bubble Bobble },
    (Hash: 'e78511a2b8cca37a96aa396c938863c92a20c797'; Mapper: Konami) { Akumajyo Drakyula - Vampire Killer },
    (Hash: 'e7d06c0a5c7f256c061e5b8173fdcc145d2fc4d6'; Mapper: Plain) { Mappy },
    (Hash: 'e894a38f3e2ad435cc5d17a66600e6016b5e47fb'; Mapper: Plain) { Antartic Adventure },
    (Hash: 'e89fc7437d8f9aed1640689a32ebbf047699b147'; Mapper: ASCII8) { Arsene Lupin 3rd - Cariostoro no Siro },
    (Hash: 'ead699582641d103a94775a08121ecc336b99eae'; Mapper: ASCII8SRAM) { Heroes of The Lance },
    (Hash: 'ecbf33a376a7a108176f8d1009d042e01519241c'; Mapper: ASCII8) { Dragon Buster },
    (Hash: 'ee501fde62b25ddd1c82798ee1b233b8813e717b'; Mapper: ASCII8) { Maison Ikkoku },
    (Hash: 'efdf63f01293251dc593163a42f31556fd042282'; Mapper: ASCII8) { Ashguine 2 },
    (Hash: 'f0e4168ea18188fca2581526c2503223b9a28581'; Mapper: Konami) { Gradius - Nemesis },
    (Hash: 'f182d4785e3eed00292f7ff4795c9dcc6c990a0a'; Mapper: ASCII8) { Hydlide 3 - The Space Memories MSX2 Version },
    (Hash: 'f57b46154cf0711e3f5218e00f67c375d95d1d5d'; Mapper: ASCII8) { Ashguine 1 },
    (Hash: 'f6199f48ff994fc9a8e33a8581bb3bb16dd301ab'; Mapper: KonamiSCC) { Space Manbow },
    (Hash: 'f787271597abbcb1297e4e8a4a9561959a195649'; Mapper: ASCII8) { Rastan Saga },
    (Hash: 'f84d7fc089b31440cac1f4fbee3d45b2f6c90e37'; Mapper: ASCII16) { Xevious - Fardraut Saga },
    (Hash: 'faa5aef23febc61a875e28eebe3aadf83e1f5ba7'; Mapper: Plain) { Galaga },
    (Hash: 'fc9adbd816109f7705f342c01f168bb09ca4b2ff'; Mapper: ASCII8) { Deep Forest },
    (Hash: 'fd71df03b0e9f3caf701ecfc6d5232060cab3b13'; Mapper: Konami) { Ganbare Goemon - Samurai },
    (Hash: 'fe4bd35e87dd50fddd255172129b9bec38691188'; Mapper: Konami) { King Kong 2 },
    (Hash: 'ff72a1788d47f9876d9fabd720f6a289fb409090'; Mapper: KonamiSCC)



 { F1 Spirit - The Way To Formula 1 }
    );
{$ENDREGION}

class function TMSXCartridge.Recognizes(const Data: TBytes): Boolean;
begin
  Result := (Length(Data) >= $2000) and (Length(Data) <= $800000) and
    (((Data[0] = $41) and (Data[1] = $42)) or
    ((Length(Data) >= $4010) and (Data[$4000] = $41) and (Data[$4001] = $42)));
end;

class function TMSXCartridge.DetectMapper(const Data: TBytes; UseKnownHashes: Boolean): TMSXMapper;
begin
  Result := AnalyzeMapper(Data, UseKnownHashes).Mapper;
end;

class function TMSXCartridge.AnalyzeMapper(const Data: TBytes; UseKnownHashes: Boolean): TMSXMapperDetection;
var
  Scores: array[ASCII8..KonamiSCC] of Integer;
  Groups: array[0..8] of Integer;
  Best, Second: Integer;

  function Group(Address: Integer): Integer;
  begin
    Result := -1;
    case Address of
      $5000..$57FF:
        Result := 0;
      $6000..$67FF:
        Result := 1;
      $6800..$6FFF:
        Result := 2;
      $7000..$77FF:
        Result := 3;
      $7800..$7FFF:
        Result := 4;
      $8000..$8FFF:
        Result := 5;
      $9000..$97FF:
        Result := 6;
      $A000..$AFFF:
        Result := 7;
      $B000..$B7FF:
        Result := 8;
    end;
  end;

  function Evidence(const W: TMSXCodeWrite): Boolean;
  begin
    Result := False;
    if Group(W.Address) < 0 then
      Exit;
    case W.Address of
      $5000, $6000, $6800, $7000, $7800, $8000, $9000, $A000, $B000, $77FF, $77F8:
        Exit(True);
    end;
    Result := ((W.Value >= 0) and (W.Value <= Max(16, Length(Data) div $2000))) or
      ((W.Value < 0) and W.Indexed and (W.Depth = 0));
  end;

  procedure ScoreCluster(Depth: Integer);
  var
    local: array[ASCII8..KonamiSCC] of Integer;
  begin
    local[ASCII8] := 12 * (Ord(Groups[2] > 0) + Ord(Groups[4] > 0)) + Min(8, Groups[2] + Groups[4]) + Ord(Groups[1] > 0) + Ord(Groups[3] > 0);
    local[ASCII16] := 5 * (Ord(Groups[1] > 0) + Ord(Groups[3] > 0)) + Min(8, Groups[1] + Groups[3]);
    local[Konami] := 8 * (Ord(Groups[5] > 0) + Ord(Groups[7] > 0)) + Min(8, Groups[5] + Groups[7]) + Ord(Groups[1] > 0);
    local[KonamiSCC] := 8 * (Ord(Groups[0] > 0) + Ord(Groups[6] > 0) + Ord(Groups[8] > 0)) + Min(8, Groups[0] + Groups[6] + Groups[8]) + Ord(Groups[3] > 0);
    for var M := ASCII8 to KonamiSCC do
      Scores[M] := Max(Scores[M], local[M] - Depth * 2);
  end;

begin
  Result := Default(TMSXMapperDetection);
  Result.Mapper := Plain;
  Result.Candidates := [Plain];
  if UseKnownHashes then
  begin
    var Hash := THashSHA1.Create;
    Hash.Update(Data);
    var Identity := Hash.HashAsString;
    for var Known in MSXKnownMappers do
      if SameText(string(Known.Hash), Identity) then
      begin
        Result.Mapper := Known.Mapper;
        Result.Candidates := [Known.Mapper];
        Result.Source := MapperDatabase;
        Result.Confidence := MapperHigh;
        Exit;
      end;
    if Identity = 'c7463e1fd0433c5d41b70670d6c10fd781b66426' then
      Result.Mapper := PhilipsAudio
    else if (Identity = '36d47cf70618fdb460f97a8ceb75013ec4529063') or
      (Identity = 'a45692849acf29ddb653707a62747985439f6d4f') or
      (Identity = '930eae7057af1652abae794072b296a59decd61b') then
      Result.Mapper := PanasonicAudio;
    if Result.Mapper <> Plain then
    begin
      Result.Candidates := [Result.Mapper];
      Result.Source := MapperDatabase;
      Result.Confidence := MapperHigh;
      Exit;
    end;
  end;
  if (Length(Data) = $10000) and (TEncoding.ASCII.GetString(Data, $18, 8) = 'PAC2OPLL') then
  begin
    Result.Mapper := FMPAC;
    Result.Candidates := [FMPAC];
    Result.Source := MapperSignature;
    Result.Confidence := MapperHigh;
    Exit;
  end;
  if (Length(Data) = $60000) and (Data[$3C000] = $41) and (Data[$3C001] = $42) then
  begin
    Result.Mapper := RType;
    Result.Candidates := [RType];
    Result.Source := MapperSignature;
    Result.Confidence := MapperMedium;
    Exit;
  end;
  var Code := AnalyzeMSXCode(Data);
  Result.Instructions := Code.Instructions;
  Result.AnalysisLimited := Code.Limited;
  FillChar(Scores, SizeOf(Scores), 0);
  // Bank-control routines usually write several selectors near one another.
  // Score local clusters, not the total frequency of arbitrary ROM writes.
  // Speculative bank mappings have less weight than the initial executable page.
  for var Anchor in Code.Writes do
  begin
    if not Evidence(Anchor) then
      Continue;
    Inc(Result.WriteSites);
    FillChar(Groups, SizeOf(Groups), 0);
    for var W in Code.Writes do
      if Evidence(W) and (W.Depth = Anchor.Depth) and (W.Offset >= Anchor.Offset) and (W.Offset <= Anchor.Offset + 48) then
        Inc(Groups[Group(W.Address)]);
    ScoreCluster(Anchor.Depth);
  end;
  Best := 0;
  Second := 0;
  for var M := ASCII8 to KonamiSCC do
    if (Scores[M] > 0) and (Scores[M] >= Best) then
    begin
      Second := Best;
      Best := Scores[M];
      Result.Mapper := M;
    end
    else
      Second := Max(Second, Scores[M]);
  if Best = 0 then
  begin
    if Length(Data) > $10000 then
    begin
      Result.Mapper := ASCII8;
      Result.Candidates := [ASCII8, ASCII16, Konami, KonamiSCC];
    end
    else if (Code.EntryPoints > 0) and not Code.Limited then
      Result.Confidence := MapperMedium;
    Exit;
  end;
  if Result.Mapper = ASCII8 then
    for var Select in Code.Writes do
      if (Select.Address >= $6000) and (Select.Address < $8000) and (Select.Value = Length(Data) div $2000) then
        for var W in Code.Writes do
          if (W.Offset > Select.Offset) and (W.Offset < Select.Offset + 128) and (W.Depth = Select.Depth) and (W.Value >= 0) and
            ((W.Address < $6000) or (W.Address >= $8000)) and
            ((W.Address - $4000) div $2000 = (Select.Address - $6000) div $800) then
            Result.Mapper := ASCII8SRAM;
  Result.Source := MapperCode;
  Result.Candidates := [Result.Mapper];
  if (Best - Second >= 6) and (Result.WriteSites >= 2) and not Code.Limited then
    Result.Confidence := MapperHigh
  else if (Best > Second) and not Code.Limited then
    Result.Confidence := MapperMedium;
  for var M := ASCII8 to KonamiSCC do
    if Best - Scores[M] < 6 then
      Include(Result.Candidates, M);
  // SRAM wiring is not described by the AB header or bank address alone.
  // Preserve alternatives instead of claiming that a banked family proves SRAM.
  if (ASCII8 in Result.Candidates) or (ASCII8SRAM in Result.Candidates) then
    Result.Candidates := Result.Candidates + [ASCII8SRAM, KoeiSRAM32];
  if ASCII16 in Result.Candidates then
    Include(Result.Candidates, ASCII16SRAM);
  var Count := 0;
  for var M := Low(TMSXMapper) to High(TMSXMapper) do
    if M in Result.Candidates then
      Inc(Count);
  if Count > 1 then
    Result.Confidence := MapperMedium;
  if Code.Limited then
  begin
    Result.Confidence := MapperLow;
    Result.Candidates := Result.Candidates + [ASCII8, ASCII16, Konami, KonamiSCC, ASCII8SRAM, ASCII16SRAM, KoeiSRAM32];
  end;
end;

constructor TMSXCartridge.Create(const Data: TBytes; MapperHint: Integer);
begin
  inherited Create;
  if (Length(Data) < $2000) or (Length(Data) > $800000) or (Length(Data) mod $2000 <> 0) then
    raise EReadError.Create('MSX cartridge must contain 8 KiB to 8 MiB in 8 KiB banks');
  FData := Copy(Data);
  if (MapperHint >= 0) and (MapperHint <= Ord(High(TMSXMapper))) then
    FMapper := TMSXMapper(MapperHint)
  else
    FMapper := DetectMapper(Data);
  FPlainBase := $4000;
  if Length(Data) = $10000 then
    FPlainBase := 0
  else if (Data[0] = $41) and (Data[1] = $42) then
  begin
    var Init := Integer(Data[2]) or (Integer(Data[3]) shl 8);
    if (Init = 0) then
      Init := Integer(Data[8]) or (Integer(Data[9]) shl 8);
    if (Length(Data) <= $4000) and (Init >= $8000) then
      FPlainBase := $8000;
  end
  else if (Length(Data) > $4000) and (Data[$4000] = $41) and (Data[$4001] = $42) then
    FPlainBase := 0;
  FillChar(FRAM, SizeOf(FRAM), $FF);
  FSCC := TSCC.Create;
  if FMapper in [SCCPlus, SnatcherSCC, SDSnatcherSCC] then
  begin
    SetLength(FSoundRAM, $20000);
    FillChar(FSoundRAM[0], Length(FSoundRAM), $FF);
  end;
  if FMapper = FMPAC then
  begin
    if Length(Data) <> $10000 then
      raise EReadError.Create('FM-PAC requires a 64 KiB ROM');
    FFM := TYM2413.Create;
  end;
  if FMapper in [PhilipsAudio, PanasonicAudio] then
    FAudio := TMSXAudioBoard.Create(Data, FMapper = PanasonicAudio);
  Reset;
end;

destructor TMSXCartridge.Destroy;
begin
  FAudio.Free;
  FFM.Free;
  FSCC.Free;
  inherited;
end;

procedure TMSXCartridge.Reset;
begin
  for var i := 0 to 3 do
    FBanks[i] := i;
  if FMapper in [ASCII8, ASCII8SRAM, KoeiSRAM32] then
    FillChar(FBanks, SizeOf(FBanks), 0);
  if FMapper in [ASCII16, ASCII16SRAM] then
  begin
    FBanks[0] := 0;
    FBanks[1] := 0;
  end;
  if FMapper = RType then
    FBanks[1] := 15;
  FPACLow := 0;
  FPACHigh := 0;
  FFMControl := 0;
  FSoundMode := 0;
  if FAudio <> nil then
    FAudio.Reset;
  if FMapper = FMPAC then
  begin
    FBanks[0] := 0;
    FFM.Reset;
  end;
  FSCC.Reset;
end;

function TMSXCartridge.PACEnabled: Boolean;
begin
  Result := (FPACLow = $4D) and (FPACHigh = $69);
end;

function TMSXCartridge.SoundBankPresent(Bank: Integer): Boolean;
begin
  Result := True;
  if FMapper = SnatcherSCC then
    Result := Bank < 8;
  if FMapper = SDSnatcherSCC then
    Result := Bank >= 8;
end;

function TMSXCartridge.SoundWindow(Address: Word): Boolean;
begin
  if FSoundMode and $20 <> 0 then
    Result := (FBanks[3] and $80 <> 0) and (Address >= $B800) and (Address < $C000)
  else
    Result := (FBanks[2] and $3F = $3F) and (Address >= $9800) and (Address < $A000);
end;

function TMSXCartridge.ROMByte(Offset: Integer): Byte;
begin
  Result := FData[Offset mod Length(FData)];
end;

function TMSXCartridge.SRAMBank(Bank: Byte): Boolean;
begin
  if FMapper = ASCII16SRAM then
    Exit(Bank = $10);
  Result := (FMapper in [ASCII8SRAM, KoeiSRAM32]) and
    ((Integer(Bank) and (Length(FData) div $2000)) <> 0);
end;

function TMSXCartridge.Read(Address: Word): Byte;
begin
  Result := $FF;
  if FAudio <> nil then
    Exit(FAudio.ReadMemory(Address));
  if FMapper in [SCCPlus, SnatcherSCC, SDSnatcherSCC] then
  begin
    if (Address < $4000) or (Address >= $C000) then
      Exit;
    if SoundWindow(Address) then
      Exit(FSCC.ReadRegister(Address and $FF, FSoundMode and $20 <> 0, True));
    var Bank := FBanks[(Address - $4000) shr 13] and 15;
    if SoundBankPresent(Bank) then
      Result := FSoundRAM[Bank * $2000 + (Address and $1FFF)];
    Exit;
  end;
  if FMapper in [FMPAC, PAC] then
  begin
    if (Address < $4000) or (Address >= $8000) then
      Exit;
    if FMapper = FMPAC then
      case Address of
        $7FF6:
          Exit(FFMControl);
        $7FF7:
          Exit(FBanks[0]);
      end;
    if PACEnabled then
      case Address of
        $4000..$5FFD:
          Exit(FRAM[Address and $1FFF]);
        $5FFE:
          Exit(FPACLow);
        $5FFF:
          Exit(FPACHigh);
      end
    else if FMapper = FMPAC then
      Result := FData[Integer(FBanks[0]) * $4000 + (Address and $3FFF)];
    Exit;
  end;
  if FMapper = Plain then
  begin
    // Small ROMs are mirrored within each 32 KiB cartridge window.
    if Length(FData) <= $4000 then
      Exit(ROMByte(Address and (Length(FData) - 1)));
    if (Address >= FPlainBase) and (Integer(Address) < FPlainBase + Length(FData)) then
      Result := FData[Integer(Address) - FPlainBase];
    Exit;
  end;
  if (Address < $4000) or (Address >= $C000) then
    Exit;
  var Page := (Address - $4000) div $2000;
  var Bank := FBanks[Page];
  if (FMapper = KonamiSCC) and ((FBanks[2] and $3F) = $3F) and
    ((Address and $F800) = $9800) then
    Exit(FSCC.ReadRegister(Address and $FF));
  case FMapper of
    ASCII16, ASCII16SRAM:
      begin
        Bank := FBanks[Page div 2];
        if SRAMBank(Bank) then
          Exit(FRAM[Address and $7FF]);
        Exit(ROMByte(Integer(Bank) * $4000 + (Address and $3FFF)));
      end;
    RType:
      begin
        if Address < $8000 then
          Exit(ROMByte($3C000 + (Address and $3FFF)));
        Exit(ROMByte(Integer(FBanks[1]) * $4000 + (Address and $3FFF)));
      end;
    GameMaster2:
      if (Page > 0) and (Bank and $10 <> 0) then
        Exit(FRAM[((Integer(Bank) and $20) shl 7) or (Address and $FFF)]);
  end;
  if SRAMBank(Bank) then
    if FMapper = KoeiSRAM32 then
      Exit(FRAM[(Integer(Bank and 3) shl 13) or (Address and $1FFF)])
    else if Page >= 2 then
      Exit(FRAM[Address and $1FFF]);
  Result := ROMByte(Integer(Bank) * $2000 + (Address and $1FFF));
end;

procedure TMSXCartridge.Write(Address: Word; Value: Byte);
begin
  if FAudio <> nil then
  begin
    FAudio.WriteMemory(Address, Value);
    Exit;
  end;
  if FMapper in [SCCPlus, SnatcherSCC, SDSnatcherSCC] then
  begin
    if (Address < $4000) or (Address >= $C000) then
      Exit;
    if Address or 1 = $BFFF then
    begin
      FSoundMode := Value;
      Exit;
    end;
    var Page := (Address - $4000) shr 13;
    var Writable := (FSoundMode and $10 <> 0) or ((Page = 0) and (FSoundMode and 1 <> 0)) or
      ((Page = 1) and (FSoundMode and 2 <> 0)) or ((Page = 2) and (FSoundMode and $24 = $24));
    if Writable then
    begin
      var Bank := FBanks[Page] and 15;
      if SoundBankPresent(Bank) then
        FSoundRAM[Bank * $2000 + (Address and $1FFF)] := Value;
    end
    else if Address and $1800 = $1000 then
      FBanks[Page] := Value
    else if SoundWindow(Address) then
      FSCC.WriteRegister(Address and $FF, Value, FSoundMode and $20 <> 0, True);
    Exit;
  end;
  if FMapper in [FMPAC, PAC] then
  begin
    if (Address < $4000) or (Address >= $8000) then
      Exit;
    case Address of
      $5FFE:
        if FFMControl and $10 = 0 then
          FPACLow := Value;
      $5FFF:
        if FFMControl and $10 = 0 then
          FPACHigh := Value;
      $7FF4, $7FF5:
        if FFM <> nil then
          FFM.WritePort(Address and 1, Value);
      $7FF6:
        if FFM <> nil then
        begin
          FFMControl := Value and $11;
          // Bit 4 locks out SRAM and clears both enable-key latches.
          if FFMControl and $10 <> 0 then
          begin
            FPACLow := 0;
            FPACHigh := 0;
          end;
        end;
      $7FF7:
        if FFM <> nil then
          FBanks[0] := Value and 3;
    else
      if PACEnabled and (Address < $5FFE) then
      begin
        FRAM[Address and $1FFF] := Value;
        FDirty := True;
      end;
    end;
    Exit;
  end;
  if (Address < $4000) or (Address >= $C000) then
    Exit;
  var Page := (Address - $4000) div $2000;
  case FMapper of
    ASCII8, ASCII8SRAM, KoeiSRAM32:
      if (Address >= $6000) and (Address < $8000) then
        FBanks[(Address - $6000) div $800] := Value
      else if ((Address >= $8000) or (FMapper = KoeiSRAM32)) and SRAMBank(FBanks[Page]) then
      begin
        var Offset := Address and $1FFF;
        if FMapper = KoeiSRAM32 then
          Inc(Offset, Integer(FBanks[Page] and 3) shl 13);
        FRAM[Offset] := Value;
        FDirty := True;
      end;
    ASCII16, ASCII16SRAM:
      if (Address >= $6000) and (Address < $7800) and (Address and $800 = 0) then
        FBanks[(Address - $6000) div $1000] := Value
      else if (Address >= $8000) and SRAMBank(FBanks[1]) then
      begin
        FRAM[Address and $7FF] := Value;
        FDirty := True;
      end;
    Konami:
      if Address >= $6000 then
        FBanks[Page] := Value;
    KonamiSCC:
      if ((Address and $F800) = $9800) and ((FBanks[2] and $3F) = $3F) then
        FSCC.WriteRegister(Address and $FF, Value)
      else if (Address and $1800) = $1000 then
        FBanks[Page] := Value;
    RType:
      if (Address >= $7000) and (Address < $8000) then
      begin
        FBanks[1] := Value and $1F;
        if Value and $10 <> 0 then
          FBanks[1] := Value and $17;
      end;
    GameMaster2:
      if (Address >= $6000) and (Address < $B000) and (Address and $1000 = 0) then
        FBanks[Page] := Value
      else if (Address >= $B000) and (FBanks[3] and $10 <> 0) then
      begin
        FRAM[((Integer(FBanks[3]) and $20) shl 7) or (Address and $FFF)] := Value;
        FDirty := True;
      end;
  end;
end;

procedure TMSXCartridge.WritePort(Port, Value: Byte);
begin
  if FAudio <> nil then
    FAudio.WritePort(Port, Value);
  if (FFM <> nil) and (FFMControl and 1 <> 0) and (Port in [$7C, $7D]) then
    FFM.WritePort(Port and 1, Value);
end;

procedure TMSXCartridge.AdvanceClocks(Cycles: Integer);
begin
  if FAudio <> nil then
    FAudio.AdvanceClocks(Cycles);
  if FMapper in [KonamiSCC, SCCPlus, SnatcherSCC, SDSnatcherSCC] then
    FSCC.Advance(Cycles);
end;

function TMSXCartridge.ReadPort(Port: Byte): Byte;
begin
  Result := $FF;
  if FAudio <> nil then
    Result := FAudio.ReadPort(Port);
end;

function TMSXCartridge.Interrupt: Boolean;
begin
  Result := (FAudio <> nil) and FAudio.Interrupt;
end;

procedure TMSXCartridge.ConfigureAudioRAM(Bytes: Integer);
begin
  if FAudio <> nil then
    FAudio.ConfigureSampleRAM(Bytes);
end;

function TMSXCartridge.Sample: SmallInt;
begin
  Result := FSCC.Sample(False);
  if FAudio <> nil then
    Result := EnsureRange(Integer(Result) + FAudio.Sample, -32768, 32767);
  if FFM <> nil then
  begin
    var L, R: SmallInt;
    FFM.Sample(L, R);
    Result := EnsureRange(Integer(Result) + (Integer(L) + Integer(R)) div 2, -32768, 32767);
  end;
end;

procedure TMSXCartridge.LoadRAM(const Data: TBytes);
begin
  if FMapper in [FMPAC, PAC] then
  begin
    if (Length(Data) <> 8206) or (TEncoding.ASCII.GetString(Data, 0, 16) <> 'PAC2 BACKUP DATA') then
      raise EReadError.Create('Invalid PAC SRAM backup');
    Move(Data[16], FRAM, $1FFE);
    FDirty := False;
    Exit;
  end;
  if Length(Data) <> SizeOf(FRAM) then
    raise EReadError.Create('Invalid MSX cartridge SRAM');
  Move(Data[0], FRAM, SizeOf(FRAM));
  FDirty := False;
end;

function TMSXCartridge.SaveRAM: TBytes;
begin
  if FMapper in [FMPAC, PAC] then
  begin
    Result := TEncoding.ASCII.GetBytes('PAC2 BACKUP DATA');
    SetLength(Result, 8206);
    Move(FRAM, Result[16], $1FFE);
    Exit;
  end;
  SetLength(Result, SizeOf(FRAM));
  Move(FRAM, Result[0], SizeOf(FRAM));
end;

procedure TMSXCartridge.SerializeState(State: TStateArchive);
begin
  var Mapper := FMapper;
  State.Field(Mapper, SizeOf(Mapper));
  if State.Loading and (Mapper <> FMapper) then
    raise EReadError.Create('MSX snapshot mapper differs');
  State.Field(FBanks, SizeOf(FBanks));
  State.Field(FRAM, SizeOf(FRAM));
  FSCC.SerializeState(State);
  if FAudio <> nil then
    FAudio.SerializeState(State);
  if FMapper in [SCCPlus, SnatcherSCC, SDSnatcherSCC] then
  begin
    State.Field(FSoundMode, SizeOf(FSoundMode));
    State.Field(FSoundRAM[0], Length(FSoundRAM));
  end;
  if FMapper in [FMPAC, PAC] then
  begin
    State.Field(FPACLow, SizeOf(FPACLow));
    State.Field(FPACHigh, SizeOf(FPACHigh));
    State.Field(FFMControl, SizeOf(FFMControl));
    if FFM <> nil then
      FFM.SerializeState(State);
    if State.Loading and ((FFMControl and $EE <> 0) or (FBanks[0] > 3)) then
      raise EReadError.Create('Invalid FM-PAC state');
  end;
  if State.Loading then
    FDirty := FMapper in [ASCII8SRAM, ASCII16SRAM, GameMaster2, KoeiSRAM32, FMPAC, PAC];
end;

end.

