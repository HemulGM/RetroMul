unit J2ME.Compatibility;

interface

uses
  System.SysUtils, J2ME.Device, J2ME.Runtime, J2ME.Suite, J2ME.Input,
  JVM.Runtime, JVM.ClassFile, JVM.Types;

// Exact JAR identities only. Names and image dimensions are not reliable hints.
function TryJ2MECompatibilityScreen(const JarHash: string; out Size: TJ2MEScreenSize): Boolean;

function J2MECompatibilityIgnoredFlashDuration(Suite: TJ2MESuite): Int64;

function J2MECompatibilitySamsungVibrationMillis(Suite: TJ2MESuite): Boolean;

function J2MECompatibilityPlatform(Suite: TJ2MESuite): string;

function J2MECompatibilityLocale(Suite: TJ2MESuite): string;

function J2MECompatibilityKeyLayout(Suite: TJ2MESuite): TJ2MEKeyLayout;

function J2MECompatibilityCanvasFooter(Suite: TJ2MESuite): Boolean;

function J2MECompatibilityNativePixelFormat(Suite: TJ2MESuite): Integer;

function J2MECompatibilityExplicitInitialPaint(Suite: TJ2MESuite): string;

function J2MECompatibilityUsesOwnCanvasLock(Suite: TJ2MESuite): Boolean;

function J2MECompatibilityEmptyGameURLTemplate(Suite: TJ2MESuite): Boolean;

function TryJ2MECompatibilityAppProperty(Suite: TJ2MESuite; const Name: string; out Value: string): Boolean;

function J2MECompatibilitySummerSki(Suite: TJ2MESuite): Boolean;

function J2MECompatibilityStackAttack2(Suite: TJ2MESuite): Boolean;

function J2MECompatibilityMarslander(Suite: TJ2MESuite): Boolean;

function NormalizeJ2MECompatibilityResource(const Name: string; const Data: TBytes): TBytes;

procedure InstallJ2MECompatibilityClasses(Suite: TJ2MESuite; VM: TJVM; out ArmiesOfWarClass: TJVMClass);

procedure PrepareJ2MEFrameTimers(C: TJVMClass);

procedure InvokeArmiesOfWarCompatibility(VM: TJVM; Method: TJVMMethod; const Arguments: TArray<TJVMValue>);

// Reviewed guest code and text bytes identify a legacy device encoding.
function TryJ2MECompatibilityEncoding(Suite: TJ2MESuite; out Encoding: string): Boolean;

// Reviewed exporter defects; scope is the exact serialized resource, not a title.
function J2MECompatibilityM3GUnusedTexBias(const ModelHash: string): Boolean;

function J2MECompatibilityM3GOrphanCamera(const ModelHash: string): Boolean;

function J2MECompatibilityPNGTrailingData(const ImageHash: string): Boolean;

function NormalizeJ2MECompatibilityMIDI(const Data: TBytes): TBytes;

function NormalizeJ2MECompatibilityOTA(const Data: TBytes): TBytes;

function NormalizeJ2MECompatibilityWAV(const Data: TBytes): TBytes;

function TryInstallJ2MECompatibilityNokiaSound(Suite: TJ2MESuite; VM: TJVM): Boolean;

procedure MigrateJ2MECompatibilityScreen(const JarHash: string; Runtime: TJ2MERuntime); overload;

procedure MigrateJ2MECompatibilityScreen(const JarHash: string; Runtime: TJ2MERuntime; const Size: TJ2MEScreenSize); overload;

implementation

uses
  System.Classes, System.Math, System.Hash, System.StrUtils,
  System.Generics.Collections, Java.Classes, JVM.Bytecode, J2ME.Graphics;

const
  PoolHash = '0dd024a3bc2933d5d40289cfc0071da095dc3c491be428d8b78b647dcd3fe5b5';
  GuitarHero3LandscapeHash = 'da1b6ed7674b0e756dfe80a6cd8b023c6baffa627fa34ac5ff0b87287e8e9612';
  GuitarHero3PortraitHash = 'e9e6419b45954802b24ef9c52035aaa25c162f518ebcabf8bb1a708ec5e9a029';
  GuitarHeroWorldTourBackstageHash = 'd6a75d736c0dc9821ca8f84f256535cbf157788a6743d5488719393bdf12cf02';
  GuitarRockTourHash = '0261af5ba37bad5257d8a3957a7705dbb5af81487ee758e28c46fc8b2f1e9768';
  Bounce19Hash = 'de3eec815e8e75de6026300872ee507ba1494e401d679a03438e1b5d2d8b588f';
  BlockBreakerSiemensHash = '6527a55680c1f9e2ea2f7c4a34aae22d30a9623db1d8bf84be44dc1781b068d7';
  CollisionCourseSiemensHash = '4ac303671c3b9eb990fcfaeb9af130f62a98049b926c331760bd784f55361d2f';
  GameAPIDemoHash = 'fd9cd7763e69fc9add8ebec47414076c2c52cd365b2559bfb2f5dce08c5dd5b9';
  BalloonShooterHash = '78b1a07389e7aa8997916d1aee1f80f1ff63a2da0fc2457ed47d492159d8d8a6';
  MoorhuhnSiemensHash = 'e428da29faeefbe7996b208c82b92d1ded58309b1c2b4949413b7b104f8dd67b';
  RailRiderKernelHash = 'e0a062a2a697e044c6cbaccb7f4c742eb7f76d6ef96be9223878a6ad9ba92a16';
  RatZSiemensHash = '875688130648b3f84b8aac920f6d09c8cc0be1e3b13e2bbbef1d65265d9b7b3d';
  NinjaMasterHash = '51873044919a41dda1fb4630f0c037c42b0550ecfda1f85f37f5acb200ac3bd1';
  AncientEmpires103Hash = '9955552dc8c09b5416903316c2133d20a8f5fc4315666f8e1f89f3278bb93bd0';
  Asphalt3Hash = '5fe5be707b9996b99220caf19c403059fe11f3f2b201c5dbf792e75ee1e79340';
  DustNDirtHash = '8d4618bffbd3e0c6cd6216d05eebd25be6a3ce4213fa38a0639f32fd8737fa37';
  BiplanesHash = '356e01e2b47fb0fd8868e6729f928cad4c0ad79d43c57195f82e6be4a08ea72c';
  ParachutePanicHash = '1351ec8f6b0cba0ec0687800c244049151b76292db662c7c6a44e5475c7bb0ba';
  BMWRacingHash = '1c016383f9b5bab968269cbc0fed9939c4c5bf38a881eb11f292ee18a3082a55';
  BimmerStreetRacingHash = '262d2e1765c982cef3681ef6d33605d63c700397e0056da8d0415bceccf68057';
  NFSCarbonHash = '2b43fb9d5f9832e11ea597f329d451312ca019a6296299463679bb04403f540d';
  DiamondRushHash = '1a27a721a4440e8bdf63aa456732d71cb4e0cbd00054899dd233b0f69fd96b00';
  DieHardHash = '42c9116c1b1933d80d17ad5bf2e7f6a96a0a8dbaa2b828a9a05d1b9c6336e9b1';
  TennisOpen2007Hash = '5268e591b7fdbc1150cf2c7ccbb77d85a346c06ce248c89ffb55ef3da48c37e4';
  StackAttack2Hash = '21075f871178aa7cd955a0317a9832d634123c59390523b1b8839e92ec756934';
  ForgottenWarriorHash = 'f08c8034da70871fc6b0674288fc7b9f0d9d8a332b2b6cdb40d915372bfd25d1';
  SummerSkiHash = '66fc629e1272a07b64f6d1dc980812a6fabadaf5d24b457d689539f9800667d0';
  RaymanGolfSiemensHash = 'f3ef30455b259e92247ccc7d6ff4dd6ba4d0bd88f30a8b06eb1b5d32c6524af8';
  PrinceHaremSiemensHash = 'f14695f89339ea49d436c14f91040eb931fba9bd2f05dd1f16c7865ffba15c03';
  BrokenWingSiemensHash = '091f81d14c4abff2820bf255e7c88efb06dd9e004b7f6d818cbce676a618781c';
  MasteringMagicHash = '05b5c0bcb49d97cf9a1250cb783e842b8d792e08f616105480b04c849e50771c';
  Sims2MobileHash = '15ef83e0c8cb835c10e15ea17a631e06cce48b2612364fa0c7a299931eab8088';
  StuntmanNokiaHash = '9ea60fbe22b3201a260b709fabcb82c4b406e77d8c6062050d0e46c1734c7848';
  StuntmanOriginalHash = '964bd6ca0d19edd647055637ff33affe509133c8669f17605da714c7edaca0fd';
  Shrek2NokiaHash = 'a29b1d7077e3bf4b39d793eee1ae3fd246b124ac09c4058f0accba9d6f8093df';
  RTLRacerSiemensHash = '7b5d4977fb4e4a27750bc634c9b51725477833487a58a72013fe9dcb6a1c595e';
  ShepherdessHash = '4f345541bc0ee13745b79fe97cd49911f21d08c5af6dc127991efb8044cbc612';
  MarslanderSiemensHash = 'e93faa05eb3cce547138504955ae6fcda7b4489da3f0b2ce8e1d782f24fe1230';

function DataMatchesHash(const Data: TBytes; const Digest: string): Boolean;
begin
  if Length(Data) = 0 then
    Exit(False);
  var Hash := THashSHA2.Create;
  Hash.Update(Data[0], Length(Data));
  Result := SameText(Hash.HashAsString, Digest);
end;

function ResourceMatchesHash(Suite: TJ2MESuite; const Resource, Digest: string): Boolean;
begin
  Result := Suite.HasResource(Resource) and DataMatchesHash(Suite.ReadResource(Resource), Digest);
end;

function NormalizeJ2MECompatibilityResource(const Name: string; const Data: TBytes): TBytes;
const
  SimonGameScriptHash = '7291a5d5e7dd308980a8db320c7806e69eebabe6f2929638de1b85555f16cc67';
  SimonTurnGuard = 'if(yourturn.qf==true && gameover==false && numPulse < currentSec.Du())'#10'{'#10;
begin
  Result := Data;
  if (Name <> 'xml/game.xml') or not DataMatchesHash(Data, SimonGameScriptHash) then
    Exit;

  // The color buttons can enqueue input during playback and after the last guess.
  // Ignore those callbacks before they change the timer or index the sequence.
  var Script := TEncoding.ASCII.GetString(Data);
  for var Color in ['green', 'blue', 'red', 'yellow'] do
  begin
    var Callback := Color + '();'#10'userPulse(' + Color + ');'#10'pauseLarge();'#10;
    Script := Script.Replace(Callback, SimonTurnGuard + Callback + '}'#10);
  end;
  Result := TEncoding.ASCII.GetBytes(Script);
end;

function J2MECompatibilityKeyLayout(Suite: TJ2MESuite): TJ2MEKeyLayout;
const
  Names: array[0..2] of string = ('a.class', 'b.class', 'Pool.class');
  Hashes: array[0..2] of string = (
    '169d60408b857a6a5f446accfd308f79331b97e1ad2a9a5c2c4b9eeecc1d50ac',
    '39de10dd3f8f9c0204b221a67f847d8995ef235f13fa2cf34e30bb191dac78de',
    'd96de6ca36651f8098abdc8e585d6c69c703d30a9689e57bb0b074004892da47');
begin
  Result := TJ2MEKeyLayout.Standard;
  if Suite = nil then
    Exit;
  // These Canvas implementations explicitly consume Siemens navigation
  // codes. The exact classes also cover copies with changed descriptors.
  if ResourceMatchesHash(Suite, 'a/RMGame.class', '91a35f7ad9154a32742e7a51c0c3f5710de8de717923880594485e3142cb6546') or
    ResourceMatchesHash(Suite, 'prince/k.class', '9c3d4b62052d3e6e8ad5cfbdef826fa05951afe93eee4a0b67737f1d54dac745') or
    ResourceMatchesHash(Suite, 'a/R6Kernel.class', 'e459b5335613ea976b60388dff7d1b047bcdcc00b942fee7fa5f6336249ba983') or
    ResourceMatchesHash(Suite, 'a/RRKernel.class', RailRiderKernelHash) or
    ResourceMatchesHash(Suite, 'jac/PlayGameCanvas.class', 'eef063cac05593d2f923f79bcc3c04acb36cc707fcc8ffb1cc662b6a8770f06d') or
    ResourceMatchesHash(Suite, 't.class', 'd4043be0e0113fec0e956454261d08c29809dc4f36440507843cef8f651d72be') or
    (ResourceMatchesHash(Suite, 'racegame/b.class', '1579b2e37a65459608347ef6b4c5838cde38a468603c0bb38a16edb4ed017069') and
    ResourceMatchesHash(Suite, 'racegame/c.class', 'edb8ff2907dfe7a94283a3a7ae41ce15a711975fcc7dcf46f3733824c3e68d66')) then
    Exit(TJ2MEKeyLayout.Siemens);
  // Snood dispatches its own Canvas commands from the standard -6/-7 keys.
  if ResourceMatchesHash(Suite, 'J.class', '370d401803b06defa2d3d94e8380844dfe6a292cb79d2eb29ab777c0b91fcf46') and
    ResourceMatchesHash(Suite, 'O.class', '0e9d0a08f525d56004f139df8b757fd3d32374ed1261821ef01aba5e33bdedc5') then
    Exit(TJ2MEKeyLayout.StandardWithRawSoftkeys);
  // Reviewed 3D Pool 1.2 Motorola port: a.bi maps navigation 1/6/2/5,
  // fire 20 and softkeys 21/22. Match all consumers, never the filename.
  for var I := Low(Names) to High(Names) do
  begin
    if not Suite.HasResource(Names[I]) then
      Exit;
    var Data := Suite.ReadResource(Names[I]);
    var Hash := THashSHA2.Create;
    if Length(Data) > 0 then
      Hash.Update(Data[0], Length(Data));
    if not SameText(Hash.HashAsString, Hashes[I]) then
      Exit;
  end;
  Result := TJ2MEKeyLayout.Motorola;
end;

function J2MECompatibilityCanvasFooter(Suite: TJ2MESuite): Boolean;
begin
  Result := False;
  // IRON MAN waits for the Canvas height to change after enabling fullscreen.
  // Match the shared canvas code so this applies to verified ports of that code.
  if (Suite = nil) or not Suite.HasResource('z.class') then
    Exit;
  var Data := Suite.ReadResource('z.class');
  if Length(Data) <> 54050 then
    Exit;
  var Hash := THashSHA2.Create;
  Hash.Update(Data[0], Length(Data));
  Result := SameText(Hash.HashAsString, '4892e43dc37d228ea5851d8ecc0afb12b7a60d5997aa26d392260175deef6bb0');
end;

function J2MECompatibilityNativePixelFormat(Suite: TJ2MESuite): Integer;
begin
  // Jewel Hunter selects a short array for the Nokia 12-bit color formats
  // and assumes one-bit grayscale for every other native pixel format.
  if (Suite <> nil) and
    ResourceMatchesHash(Suite, 'com/jixel/midp/games/jewels/Main.class',
    '8f72a36fba4da537e8d85f326997f634a9bddfbffdf3325ff17dc16311acb9e8') and
    ResourceMatchesHash(Suite, 'a.class',
      '0d77526549afceddd51e261d00f8faf9bd115965b370a3176068ebb594ca202b') then
    Exit(4444); // TYPE_USHORT_4444_ARGB
  // ChinaChess passes getNativePixelFormat straight to the short[] overloads.
  if (Suite <> nil) and
    ResourceMatchesHash(Suite, 'ChinaChess.class', '80a874d96901be8b9ba2f0bd4f01b3e61084dee33eef86786ac233a8c1e7d4a3') and
    ResourceMatchesHash(Suite, 'b.class', 'e0338337c5500feb2e776324bceb5ed7822f3172760a6beb0916006340cd13b4') then
    Exit(4444);
  Result := J2MEDefaultNativePixelFormat;
end;

const
  MiamiEngineHash = '84cb79849ed0d232f4b213a4dccee69b0e5f574b749c29a52806e13fa6ba4b0d';
  MiamiMIDletHash = '8df29fcdec82a6233e3ca84c7774c03e9d1a7adb77044752628c6f917a19aa87';

function NormalizeJ2MECompatibilityMIDI(const Data: TBytes): TBytes;

  function RepairControllerValues(const Digest: string; const Offsets: array of Integer): TBytes;
  begin
    var Hash := THashSHA2.Create;
    Hash.Update(Data[0], Length(Data));
    if not SameText(Hash.HashAsString, Digest) then
      Exit(Data);
    Result := Copy(Data);
    for var Offset in Offsets do
      Result[Offset] := Result[Offset] and $7F;
  end;

begin
  Result := Data;
  case Length(Data) of
    // Golf Tour's title uses $C0 for the centered CC 10 value.
    3044:
      Result := RepairControllerValues('089cc75e602ae948e324bc93da27f37d9bccb1dc41b6336b0caf412e992adb41',
        [82, 566, 1129, 1351, 1680, 2054, 2084, 2114, 2144, 2174, 2889, 2919, 2949, 2979, 3009, 3039]);
    // elkware's Backgammon puts $FD/$FE in the initial CC 10 events
    // of these three tracks. Keep their seven data bits.
        12230:
      Result := RepairControllerValues('4b093833bda324589f988d82423fd80d9b5233cba7f9d4dfc788562d4971e491',
        [61, 6477, 7260, 7800, 9656, 9659]); // _A1.mid
      877:
      Result := RepairControllerValues('e703f69573ed06f793e9236216759f9f251c5f97553bd1289f0a16240fbb9107',
        [67, 497, 519, 549, 713, 716]); // _A2.mid
      1585:
      Result := RepairControllerValues('8f7221b2fc0745a7ff99c661b5c6da2e3fb4b8c3c2faac95a9838931a310d70e',
        [70, 1133, 1155, 1185, 1349, 1352]); // _A3.mid
    // Poppin Panda's resource 168 uses $FF for the chorus and reverb levels.
      235:
      Result := RepairControllerValues('51b71799ec244efa645ef04c68e1bd1a7334fc682bf77636e6f0071eb55d7099',
        [135, 139, 205, 209]);
  end;
end;

function NormalizeJ2MECompatibilityWAV(const Data: TBytes): TBytes;
const
  RollerbladeJumpHash = 'd365948fe4dc612fdbec5975b0770a69c306b544efdcc1a7b80ef5773df6c65c';
  SonicSegaHash = '89a0bfabda87f3137fed30b560dc233fa570acccbd2c6f93e26821d45caa49af';
begin
  Result := Data;
  if (Length(Data) <> 4076) and (Length(Data) <> 26924) then
    Exit;
  var Hash := THashSHA2.Create;
  Hash.Update(Data[0], Length(Data));
  var Digest := Hash.HashAsString;
  if SameText(Digest, SonicSegaHash) then
  begin
    // Sonic 2's Sega jingle has all of its PCM, with a stale RIFF size.
    Result := Copy(Data);
    Result[4] := $24; // RIFF size: 26916 ($6924)
    Result[5] := $69;
    Exit;
  end;
  if not SameText(Digest, RollerbladeJumpHash) then
    Exit;
  // The final 48 bytes of this 8-bit mono clip are missing.
  // Update the little-endian RIFF and data sizes to the actual sample count.
  Result := Copy(Data);
  Result[4] := $E4;  // RIFF size: 4068 ($0FE4)
  Result[5] := $0F;
  Result[40] := $C0; // data size: 4032 ($0FC0)
end;

function TryInstallJ2MECompatibilityNokiaSound(Suite: TJ2MESuite; VM: TJVM): Boolean;
const
  SoundResource = 'com/nokia/mid/sound/Sound.class';
begin
  // VirtualPilot bundles a no-op Sound implementation. Its matching Nsound
  // sends an incomplete OTA ringtone as WAV and relies on that stub.
  Result := (Suite <> nil) and
    ResourceMatchesHash(Suite, 'Nsound.class', '404b8d68e73ff9d469cf70f2e130aa59970cb771c18cba4f616b9e24de4345f1') and
    ResourceMatchesHash(Suite, SoundResource, 'e7c770e34ac9aff30e195322e33079a7db4dad08f3adf3397177675a5932c0fa');
  if Result then
  begin
    var Sound := TJVMClass.Parse(Suite.ReadResource(SoundResource));
    try
      VM.DefineClass(Sound);
      Sound := nil;
    finally
      Sound.Free;
    end;
  end;
end;

function NormalizeJ2MECompatibilityOTA(const Data: TBytes): TBytes;
type
  TFieldEdit = record
    Offset, Width, Value: Integer;
  end;
const
  // Exact malformed effects. Keep normal OTA validation for every other clip.
  Repairs: array[0..30] of record
  Digest: string;
  First, Second: TFieldEdit;
  AppendEnd: Boolean;
end = (
    // Ice Age: Both patterns omit the final complete note from the count.
(Digest: '59293d6946d745b2368c2fcf0dc7375c94c315341dfca3f16d90944bd318a9c3';
      First: (Offset: 79; Width: 8; Value: 8);
      Second: (Offset: 0; Width: 0; Value: 0);
      AppendEnd: False),
    (Digest: 'eb13200831ea5c5690246498d4a4be198944263325b468df8a1b2610279e6f34';
      First: (Offset: 79; Width: 8; Value: 6);
      Second: (Offset: 0; Width: 0; Value: 0);
      AppendEnd: False),
    // KO Kickboxing: 31 complete instructions, then a partial note tag.
      (Digest: 'f4cc8dc7f8b19dc7ce31c272326fc9349d4e95984d4d063257820c0a7b8310a1';
      First: (Offset: 47; Width: 8; Value: 31);
      Second: (Offset: 381; Width: 3; Value: 0);
      AppendEnd: True),
    // Snakies 7210: Each of these patterns undercounts by one note.
      (Digest: '9986fd31cecb2e7538182b9ea8ad5887b67cf86595609ae61ee99913d06de181';
      First: (Offset: 79; Width: 8; Value: 5);
      Second: (Offset: 0; Width: 0; Value: 0);
      AppendEnd: False),
    (Digest: 'a15f5f921bab3cf51be86d14435fa9e84b7609c9ea6bce3e77d73d9cf7297958';
      First: (Offset: 79; Width: 8; Value: 9);
      Second: (Offset: 0; Width: 0; Value: 0);
      AppendEnd: False),
    (Digest: 'da1adf33d76f215ead41c52dea1b3708b9cedbafde10f935120424dbe5d9dd8d';
      First: (Offset: 79; Width: 8; Value: 4);
      Second: (Offset: 0; Width: 0; Value: 0);
      AppendEnd: False),
    // Backgamon 3510i stores eight one-pattern effects. Six count one
    // extra instruction; seven omit the command end after the last note.
      (Digest: 'fed17ed8673d0359baa04f365f4d98007c7143e34337750283fddb18e409e0c4';
      First: (Offset: 87; Width: 8; Value: 16);
      Second: (Offset: 0; Width: 0; Value: 0);
      AppendEnd: True),
    (Digest: '0a42cdd75a7d68c10259d2b5ac4183b76475c706e3dc04d8eaadcc7604f84f6f';
      First: (Offset: 0; Width: 0; Value: 0);
      Second: (Offset: 0; Width: 0; Value: 0);
      AppendEnd: True),
    (Digest: '772b47a996ebee3372a93fcee223404aa3bb479971b68e900e4cd43a1838fd48';
      First: (Offset: 87; Width: 8; Value: 10);
      Second: (Offset: 0; Width: 0; Value: 0);
      AppendEnd: True),
    (Digest: 'd480bf982a1b2cd702221c4d055064a76d98d112aeffcb14f977b1dee3c77d01';
      First: (Offset: 0; Width: 0; Value: 0);
      Second: (Offset: 0; Width: 0; Value: 0);
      AppendEnd: True),
    (Digest: '30ddfdd1eb0cf0365c32248c89f504c0aaa37e526213e49d263f19ff0ad0634c';
      First: (Offset: 87; Width: 8; Value: 12);
      Second: (Offset: 0; Width: 0; Value: 0);
      AppendEnd: False),
    (Digest: '6becffc3c52b011be79cb2351b52b690563962dccf2d56b05bdb2921878e90b6';
      First: (Offset: 87; Width: 8; Value: 26);
      Second: (Offset: 0; Width: 0; Value: 0);
      AppendEnd: True),
    (Digest: '85f145cea83f46ecf0106b8f118974d583ec8910ac7b9ab7cfb3992efc28b5af';
      First: (Offset: 87; Width: 8; Value: 126);
      Second: (Offset: 0; Width: 0; Value: 0);
      AppendEnd: True),
    (Digest: 'aaccc5784c4cc57a530cc8d25bfc5779d8aa5f7771f26f25455cc13fa6f6637e';
      First: (Offset: 87; Width: 8; Value: 18);
      Second: (Offset: 0; Width: 0; Value: 0);
      AppendEnd: True),
    // AirRaid: Reserved articulation -> natural.
      (Digest: 'ddf26d3626257e6aeda49fc58b93b54bb2e642b5b1007333ca62796c79f7e18f';
      First: (Offset: 122; Width: 2; Value: 0);
      Second: (Offset: 0; Width: 0; Value: 0);
      AppendEnd: False),
    // bijlee: Reserved articulation and five-bit scale marker.
      (Digest: '46a083e0dfa3cf33f225b8dfe46be0c143a5cbf60b039c858489e978ce50a1fd';
      First: (Offset: 98; Width: 2; Value: 0);
      Second: (Offset: 112; Width: 5; Value: 11);
      AppendEnd: False),
    // Cheers: Five-bit scale marker before the remaining complete notes.
      (Digest: 'a95c587193d9c2daa186e766c88a32044059b1000bcf984cdf654af4b929367b';
      First: (Offset: 137; Width: 5; Value: 11);
      Second: (Offset: 0; Width: 0; Value: 0);
      AppendEnd: False),
    // ChickenRun: Reserved articulation -> natural.
      (Digest: 'a7ffc280e8c8fc64fc7b11ebb8acd265a65d9701c2e81c11a0db6d2c2ece3077';
      First: (Offset: 90; Width: 2; Value: 0);
      Second: (Offset: 0; Width: 0; Value: 0);
      AppendEnd: False),
    // Cow_Bandits_sek700.ic.cz: Unassigned pitch -> rest of the original duration.
      (Digest: '62b102208d5585800de4afe1938fdb0eb87f79e58de6dfa4f8a8136e46c4e861';
      First: (Offset: 137; Width: 4; Value: 0);
      Second: (Offset: 0; Width: 0; Value: 0);
      AppendEnd: False),
    // Escape: Complete note stream missing its command end.
      (Digest: '2e3baa6bf501f48e3049a5c0267ee3c978e2d1c7a749ee1464e0bbafec61e684';
      First: (Offset: 0; Width: 0; Value: 0);
      Second: (Offset: 0; Width: 0; Value: 0);
      AppendEnd: True),
    // HeadBall: Nonzero filler after the last declared note.
      (Digest: '764a3a1444bfc540cf33ca2d09923b9a1f03dfd0e68d423ce6a59f00dd3b3a87';
      First: (Offset: 121; Width: 7; Value: 0);
      Second: (Offset: 0; Width: 0; Value: 0);
      AppendEnd: False),
    // KingOfFighter: Five complete instructions rather than six.
      (Digest: '948e9307161f7579cf4ae359a447a05da9391c6134824af5205b82902478fcf5';
      First: (Offset: 43; Width: 8; Value: 5);
      Second: (Offset: 0; Width: 0; Value: 0);
      AppendEnd: False),
    // Rack: Rack: nonzero programming and final sound filler.
      (Digest: 'f91fa175063d8241ecbbbc988140768a68bcede0d1f8456e4a0eda6bf4d2a539';
      First: (Offset: 15; Width: 1; Value: 0);
      Second: (Offset: 105; Width: 7; Value: 0);
      AppendEnd: False),
    // Torture Chamber (s60): Reserved articulation and five-bit scale marker.
      (Digest: 'b21337f3190f3bc9503162cb23fb018d9aff430c4f2c0e45b9590536576f7e58';
      First: (Offset: 82; Width: 2; Value: 0);
      Second: (Offset: 113; Width: 5; Value: 11);
      AppendEnd: False),
    // JewelQuest_N6230i_N6270: Nine complete instructions rather than fifteen.
      (Digest: '27ce0e67f74aedf782cb420d8c4d6d97041bf90d5243d312d0334e8a03527aca';
      First: (Offset: 47; Width: 8; Value: 9);
      Second: (Offset: 0; Width: 0; Value: 0);
      AppendEnd: False),
    // ChickenRun: articulation and five-bit scale marker.
      (Digest: 'b3877d3e2059529aff9daf1c4bdc5a1c0df619e14442c17ed986ad50cfeb3411';
      First: (Offset: 90; Width: 2; Value: 0);
      Second: (Offset: 121; Width: 5; Value: 11);
      AppendEnd: False),
    // ChickenRun: reserved articulation -> natural.
      (Digest: 'bad511df47c5498bf15c9a4241df3c664724cd769832c72d7a6b6be6fb6ac97c';
      First: (Offset: 106; Width: 2; Value: 0);
      Second: (Offset: 0; Width: 0; Value: 0);
      AppendEnd: False),
    // HeadBall: replace the nonzero terminator after ten complete instructions.
      (Digest: '50d75b0d9e990b3072030ca4fbf543804e5bdcdb6cd7394bbdd823ce8f8210f6';
      First: (Offset: 136; Width: 8; Value: 0);
      Second: (Offset: 0; Width: 0; Value: 0);
      AppendEnd: False),
    // Rack: nonzero programming filler.
      (Digest: 'a89a7cc5c3dd7ffb1a05030de3b4285554aca4f05d96ca31418d813072723474';
      First: (Offset: 15; Width: 1; Value: 0);
      Second: (Offset: 0; Width: 0; Value: 0);
      AppendEnd: False),
    // Rack: six complete instructions and a missing command end.
      (Digest: '1f4a25fd71acc4603638cf86b20c7be116f4240d9f17f02e9d06d3299d1904f6';
      First: (Offset: 15; Width: 1; Value: 0);
      Second: (Offset: 55; Width: 8; Value: 6);
      AppendEnd: True),
    // Rack: seventeen complete instructions rather than eighteen.
      (Digest: '9d7ec98ee1ef689d110833bcd21eb65b8b0a8d09ee7ccc9c5c359f6e3bdb6b02';
      First: (Offset: 15; Width: 1; Value: 0);
      Second: (Offset: 55; Width: 8; Value: 17);
      AppendEnd: False));
  // Blue Sphere Games releases embed edits of the Nokia example melody
  // that retain the example's declared count of 13 instructions.
  Melodies: array[0..12] of record
  Digest: string;
  Count: Byte;
end = (
    (Digest: 'cfd33338cd08231c9478f577dc91bbe0a6f35fdbbc0b5d6188673ec7a62338a6'; Count: 6),
    (Digest: '4244a0b6d22ba14f3e14c29aff1b85d99e9ebd04d31de593dd742a46dc593c06'; Count: 6),
    (Digest: 'f22241173b03c7d827a4cdf311f73165dda96867f3495bcb58e8a35d3ec64987'; Count: 10),
    (Digest: '057a905b127806dc1c918d2b571810d30fa1a29e345318ad89424c24af9e0f84'; Count: 3),
    (Digest: '56f2a17da7bccaa92835e6747ff75f017a3d2202da51139276771ae35606f5a4'; Count: 3),
    (Digest: 'dc7baa77ddaf71b00f18c68087a51ec3868d95d1ce17c7e45c388c73d935a48e'; Count: 3),
    (Digest: '16839d552ebf06d2b39d9627a0e0bdefa1c7140af67092d4d00bd762bbd71279'; Count: 9),
    (Digest: '67fd0e4a172de95a54103200909b3a77fa301b33b27300641ab912116d073f6d'; Count: 6),
    (Digest: 'd5bc7ffafffadd7762fcaa16a5806829618895b6fb6c4401dbf20d5db5f9f11a'; Count: 5),
    (Digest: 'e4649f1d907d381b6dfb6fcdca2df83f2988ec910c503cc145fa66183963276c'; Count: 2),
    (Digest: '6efb8081eeb13edc4ca432eb7e62fb87582cebbd9bfad989c172a1355dfc13a9'; Count: 2),
    (Digest: '5b16d64c6fbbf15e0cd8fe85264fb7a77419a28bfbacbd184b25b08cc9056d07'; Count: 2),
    (Digest: '0f5cc9dd4c722c8db7e778eaf807c86f82cdf3cfe3e5878a8822715b51c605ef'; Count: 15));

  procedure SetField(var Bytes: TBytes; const Edit: TFieldEdit);
  begin
    for var I := 0 to Edit.Width - 1 do
    begin
      var Position := Edit.Offset + I;
      var Index := Position div 8;
      var Mask := Byte(1 shl (7 - (Position mod 8)));
      if (Edit.Value and (1 shl (Edit.Width - I - 1))) <> 0 then
        Bytes[Index] := Bytes[Index] or Mask
      else
        Bytes[Index] := Bytes[Index] and not Mask;
    end;
  end;

begin
  Result := Data;
  if not (Length(Data) in [12, 13, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 28, 29, 30, 32, 36, 38, 48, 49, 168]) then
    Exit;
  var Hash := THashSHA2.Create;
  Hash.Update(Data[0], Length(Data));
  var Digest := Hash.HashAsString;
  for var Repair in Repairs do
    if Digest = Repair.Digest then
    begin
      Result := Copy(Data);
      SetField(Result, Repair.First);
      SetField(Result, Repair.Second);
      if Repair.AppendEnd then
        SetLength(Result, Length(Result) + 1);
      Exit;
    end;
  // Puzzle Bobble's second built-in effect has three complete patterns and
  // alignment bits, but no command-end byte. The next effect is initialized
  // in the same guest try block, so this omission suppresses both sounds.
  if Digest = '40351ce5ecb27f951be51a5737203912a494a62d90eef9436cb31dd0688ccf8f' then
    Exit(Data + [$00]);
  for var I := Low(Melodies) to High(Melodies) do
    if Digest = Melodies[I].Digest then
    begin
      Result := Copy(Data);
      // The count occupies bits 79..86. Its highest bit is already zero.
      Result[10] := (Melodies[I].Count shl 1) or (Data[10] and 1);
      // One Hells Pit effect ends after a complete note and alignment,
      // with no command-end byte. Its verified payload has a nonzero tail.
      if Data[High(Data)] <> 0 then
        SetLength(Result, Length(Result) + 1);
      Exit;
    end;
end;

function J2MECompatibilityExplicitInitialPaint(Suite: TJ2MESuite): string;
begin
  Result := '';
  if Suite = nil then
    Exit;

  // These ports show their Canvas before finishing asset initialization on
  // their game thread. Their explicit repaint signals that paint can run.
  if ResourceMatchesHash(Suite, 'GloftMMN2.class', MiamiMIDletHash) and
    ResourceMatchesHash(Suite, 'f.class', MiamiEngineHash) then
    Exit('f');
  if ResourceMatchesHash(Suite, 'Simpsons.class', 'c78c555d24d0de32aa93816fc1b5d2425379d720cf715b38a6c4c322dec51d7c') and
    ResourceMatchesHash(Suite, 'g.class', '76d3251f8c9017146e4994dce438ce68eb3eb4b7eab9899fb5be82f3ed22f87a') and
    ResourceMatchesHash(Suite, 'h.class', 'f31aac9894adef7ee6a4d2a506308ff42ba0fb452407904bd66211d055b2129f') then
    Exit('g');
end;

function J2MECompatibilityUsesOwnCanvasLock(Suite: TJ2MESuite): Boolean;
begin
  // True Crime 2 holds its game lock before entering synchronized Canvas methods.
  // Acquiring the Canvas monitor ahead of paint reverses that order. The game
  // serializes paint itself and does not call serviceRepaints.
  Result := (Suite <> nil) and
    ResourceMatchesHash(Suite, 'ae.class', '1741f4af26b886130e17334ee47c005907769ca20f210bb9793c7637f78d81a0') and
    ResourceMatchesHash(Suite, 'ac.class', '191af7dfd59f108ee43c82c683c0aca28390c4c09de04f5680477c66257e8643');
end;

function J2MECompatibilityEmptyGameURLTemplate(Suite: TJ2MESuite): Boolean;
begin
  // The Miami Nights 2 advertising code trims this optional property without
  // a null check. An empty template lets the game proceed without an ad URL.
  Result := (Suite <> nil) and
    ResourceMatchesHash(Suite, 'GloftMMN2.class', MiamiMIDletHash) and
    ResourceMatchesHash(Suite, 'c.class', '4d237f62c487763aa5f4d594564469bb7675e446f6acfa3a0b99627bccbe19ce');
end;

function TryJ2MECompatibilityAppProperty(Suite: TJ2MESuite; const Name: string; out Value: string): Boolean;
begin
  // My Little Farm expects this setting in the JAD and quits if it is absent.
  // The reviewed JAR can run offline with the setting disabled.
  Result := (Name = 'gmg-enabled') and
    ResourceMatchesHash(Suite, 'o.class', '54f7137d53c9aff174a69ba83f12e9a942b7708bd0c30828f81eb9689bbfc9c6') and
    ResourceMatchesHash(Suite, J2MEManifestName, '7ae33c77eab3e9421ac690f34a603df6b7f65c00ca94eb7242f8544a447e4e47');
  if Result then
    Value := 'false';
end;

function J2MECompatibilitySummerSki(Suite: TJ2MESuite): Boolean;
begin
  // This Summer Ski build only matches bare language codes before loading
  // its string table. For en-US it fails to load even its bundled English.
  Result := (Suite <> nil) and
    ResourceMatchesHash(Suite, 'SummerSki.class', '503d66ebf44a1df9ea210ee0d01c1da504defc340f3163bc6dc3c8b195a9483c') and
    ResourceMatchesHash(Suite, 'f.class', '67c081ca2b452cc621d2f8d97d46c5d11044b0c2eb2b047fedc32b039ed3b07b');
end;

function J2MECompatibilityStackAttack2(Suite: TJ2MESuite): Boolean;
begin
  Result := (Suite <> nil) and ResourceMatchesHash(Suite, 'StackAttack2.class',
    'a8a10e1651b4dd8a039199b0ac2f7039b167e6be9324b9c7ab21fcd93de94195');
end;

function J2MECompatibilityMarslander(Suite: TJ2MESuite): Boolean;
begin
  // The reviewed Siemens port uses res\... in Class.getResourceAsStream.
  Result := (Suite <> nil) and
    ResourceMatchesHash(Suite, 'Marslander.class', '83a60184fe02bb89b1ab8660d4cd493bc8d0204199ce13985ca3190058ccb6c2') and
    ResourceMatchesHash(Suite, 'd.class', '48bedcb94792ac7a351f5ba74bb6f7e16f3345a3eadb17aab0e209d583a557f2');
end;

procedure InstallMarslanderIntro(Suite: TJ2MESuite; VM: TJVM);
const
  DividePC = 271;
  SetFramePC = 324;
  Helper = '$setIntroFrame';
  HelperSignature = '(Ld;I)V';
begin
  if not J2MECompatibilityMarslander(Suite) or
    not ResourceMatchesHash(Suite, 'h.class', 'efff3756f4a80aaa97b14806406f3bd759e5a82062286b40102e2b934953b647') then
    Exit;
  for var Name in ['intro_star', 'intro_planet', 'intro_saturn'] do
  begin
    var Sprite := Suite.ReadResource('res/' + Name + '.spr');
    if (Length(Sprite) < 6) or (Sprite[0] <> 7) then
      Exit;
  end;

  var C := TJVMClass.Parse(Suite.ReadResource('h.class'));
  try
    var Run := C.FindMethod('run', '()V');
    // The initial random depth can be 1024, so the projection divisor can be zero.
    // Use the nearest nonzero divisor and keep the normal per-particle update.
    var GuardPC := Length(Run.Code);
    var ContinueOffset := DividePC + 3 - (GuardPC + 9);
    Run.Code := Run.Code + [
        $59, $9A, 0, 5, // dup; ifne divide
        $57, $04, // pop; iconst_1
        $6C, $36, 4, // idiv; istore 4
        $A7, Byte(ContinueOffset shr 8), Byte(ContinueOffset)];
    var GuardOffset := GuardPC - DividePC;
    Run.Code[DividePC] := $A7;
    Run.Code[DividePC + 1] := Byte(GuardOffset shr 8);
    Run.Code[DividePC + 2] := Byte(GuardOffset);
    Run.InstructionStarts := JVMInstructionMap(Run.Code, Run.MaxLocals);
    // The next instructions already clamp the wrapper's frame to 6.
    // Move the clamp before the native sprite access and keep the saved PCs.
    var B := TJavaClassBuilder.Create(C.Name, C.SuperName);
    try
      B.JavaClass.Constants := C.Constants;
      B.Start;
      B.Emit([$2A, $1B, $10, 6]);
      B.Ref($B8, B.Member('java/lang/Math', 'min', '(II)I'));
      B.Ref($B6, B.Member('d', 'setFrame', '(I)V'));
      B.Emit([$B1]);
      B.Finish(Helper, HelperSignature, JVM_ACC_PRIVATE or JVM_ACC_STATIC, 3, 2);
      var M := B.JavaClass.Methods.Extract(B.JavaClass.Methods.Last);
      M.Owner := C;
      C.Methods.Add(M);
      var Ref := B.Member(C.Name, Helper, HelperSignature);
      C.Constants := B.JavaClass.Constants;
      Run.Code[SetFramePC] := $B8;
      Run.Code[SetFramePC + 1] := Byte(Ref shr 8);
      Run.Code[SetFramePC + 2] := Byte(Ref);
    finally
      B.Free;
    end;
    VM.DefineClass(C);
    C := nil;
  finally
    C.Free;
  end;
end;

procedure PrepareJ2MEFrameTimers(C: TJVMClass);
const
  // Complete instruction templates, with constant-pool references normalized
  // by field identity/type. No title, class name, resource hash or FPS heuristic.
  Patterns: array[0..3] of string = (
    'B840005C402AB4100165883E2A1FB510012A59B420022AB430032AB420042E1101F4B8400164B520022A59B420021D1101F4B8400160B520022AB430032AB420041D4F2A2AB42004046010077EB520042AB42002067AAC',
    'B84000401F2AB4100165883E2A59B420021D60B520022A1FB510011D1101F4A400071101F43E2A59B420032AB430042AB420052E64B520032A59B420031D60B520032AB430042AB420051D4F2A2AB42005046010077EB520052AB42003067AAC',
    'B840005C402AB4100165883E2A1FB510011D1101F4A400071101F43E2A59B420022AB430032AB420042E64B520022A59B420021D60B520022AB430032AB420041D4F2A2AB42004046010077EB520042AB42002067AAC',
    'B840005C402AB4100165883E2A59B420021D60B520022A1FB510011D1101F4A400071101F43E2A59B420032AB430042AB420052E64B520032A59B420031D60B520032AB430042AB420051D4F2A2AB42005046010077EB520052AB42003067AAC');
  HelperName = '$elapsedFrameTime';
var
  Fields: TDictionary<string, Integer>;

  function Matches(M: TJVMMethod): Boolean;
  begin
    Result := False;
    if (M.Descriptor <> '()I') or ((M.Access and (JVM_ACC_STATIC or JVM_ACC_NATIVE)) <> 0) or
      not (Length(M.Code) in [86, 87, 96]) or (Length(M.Handlers) <> 0) then
      Exit;
    if (M.Code[0] <> $B8) or (M.Code[High(M.Code)] <> $AC) or
      (M.Code[High(M.Code) - 1] <> $7A) or (M.Code[High(M.Code) - 2] <> $06) then
      Exit;
    if Fields = nil then
      Fields := TDictionary<string, Integer>.Create
    else
      Fields.Clear;
    var Code := Copy(M.Code);
    for var PC := 0 to High(Code) do
      if M.InstructionStarts[PC] and (Code[PC] in [$B4..$B9]) then
      begin
        var Owner, Name, Desc: string;
        C.MemberRef((Word(Code[PC + 1]) shl 8) or Code[PC + 2], Owner, Name, Desc);
        var ID := 0;
        if Code[PC] in [$B4, $B5] then
        begin
          if Owner <> C.Name then
            Exit;
          var Key := Name + ':' + Desc;
          if not Fields.TryGetValue(Key, ID) then
          begin
            ID := Fields.Count + 1;
            Fields.Add(Key, ID);
          end;
          if Desc = 'J' then
            Inc(ID, $1000)
          else if Desc = 'I' then
            Inc(ID, $2000)
          else if Desc = '[I' then
            Inc(ID, $3000)
          else
            Exit;
        end
        else if (Code[PC] = $B8) and (Owner = 'java/lang/System') and
          (Name = 'currentTimeMillis') and (Desc = '()J') then
          ID := $4000
        else if (Code[PC] = $B8) and (Owner = 'java/lang/Math') and
          (Name = 'min') and (Desc = '(II)I') then
          ID := $4001
        else
          Exit;
        Code[PC + 1] := Byte(ID shr 8);
        Code[PC + 2] := Byte(ID);
      end;
    var Text := '';
    for var V in Code do
      Text := Text + IntToHex(V, 2);
    for var Pattern in Patterns do
      if Text = Pattern then
        Exit(True);
  end;

begin
  // The helper name also preserves snapshots made by the earlier Minesweeper
  // fix. A guest-defined collision is left untouched.
  if C.FindMethod(HelperName, '()I') <> nil then
    Exit;
  Fields := nil;
  try
    for var Clock in C.Methods.ToArray do
      if Matches(Clock) then
      begin
        var B := TJavaClassBuilder.Create(C.Name, C.SuperName);
        try
          B.JavaClass.Constants := C.Constants;
          B.Start;
          B.Emit(Clock.Code);
          B.Finish(HelperName, '()I', Clock.Access, Clock.MaxStack, Clock.MaxLocals);
          var M := B.JavaClass.Methods.Extract(B.JavaClass.Methods.Last);
          M.Owner := C;
          C.Methods.Add(M);
          var Tail := Length(M.Code) - 7;
          // Preserve the history updates and any separate elapsed-time counter.
          // Only replace the lossy integer mean by the actual frame interval.
          // No artificial minimum: multiple updates in one millisecond return 0.
          if Length(M.Code) = 87 then
          begin
            // This variant caps each ring contribution with Math.min rather
            // than capping local 3 before the ring update.
            var MinRef := B.Member('java/lang/Math', 'min', '(II)I');
            SetLength(M.Code, Tail);
            M.Code := M.Code + [$1D, $11, 1, $F4, $B8, Byte(MinRef shr 8), Byte(MinRef), $AC];
          end
          else
          begin
            M.Code[Tail] := $1D;
            for var PC := Tail + 1 to High(M.Code) - 1 do
              M.Code[PC] := $00;
          end;
          M.InstructionStarts := JVMInstructionMap(M.Code, M.MaxLocals);
          C.Constants := B.JavaClass.Constants;
          // New calls (including external/virtual ones) use the helper. Saved
          // frames resolve to their original method and instruction boundaries.
          Clock.EntryPoint := M;
        finally
          B.Free;
        end;
        Break;
      end;
  finally
    Fields.Free;
  end;
end;

procedure InstallAbsoluteMinesweeper(Suite: TJ2MESuite; VM: TJVM);
const
  Helper = '$menuTileLimit';
  Signature = '(IIII)I';
begin
  if not ResourceMatchesHash(Suite, 'DCField.class',
    '835e1e8264a433d841df0e137bf3582dff3a10e19fd4395dbc21149224a7cb8a') or
    not ResourceMatchesHash(Suite, 'g.class',
      '4eff2d345e371d2860f7ed1bca1c244ffdf20d34ce31979a310efcb807f12d61') or
    not ResourceMatchesHash(Suite, 'i.class',
      'fe447b0e7362d78f31d7a8aca17f6b840fcb5e38807384b8170a665c882bb8a4') then
    Exit;

  var C := TJVMClass.Parse(Suite.ReadResource('i.class'));
  try
    var Draw := C.FindMethod('a', '(Ljavax/microedition/lcdui/Graphics;IIIII)V');
    var B := TJavaClassBuilder.Create(C.Name, C.SuperName);
    try
      B.JavaClass.Constants := C.Constants;
      B.Start;
      // x + width - 2 * capWidth + tileWidth. The original compares an
      // absolute tile X against a relative width, leaving the right gap.
      B.Emit([$1A, $1B, $60, $1C, $04, $78, $64, $1D, $60, $AC]);
      B.Finish(Helper, Signature, JVM_ACC_PRIVATE or JVM_ACC_STATIC, 3, 4);
      var M := B.JavaClass.Methods.Extract(B.JavaClass.Methods.Last);
      M.Owner := C;
      C.Methods.Add(M);
      var Ref := B.Member(C.Name, Helper, Signature);
      C.Constants := B.JavaClass.Constants;
      var Code: TBytes := [$1C, $15, 4, $15, 7, $15, 8, $B8, Byte(Ref shr 8), Byte(Ref)];
      B.Start;
      B.Emit(Draw.Code);
      B.Finish('$drawMenuBar', Draw.Descriptor, JVM_ACC_PRIVATE, Draw.MaxStack, Draw.MaxLocals);
      M := B.JavaClass.Methods.Extract(B.JavaClass.Methods.Last);
      M.Owner := C;
      C.Methods.Add(M);
      Move(Code[0], M.Code[69], Length(Code));
      M.InstructionStarts := JVMInstructionMap(M.Code, M.MaxLocals);
      Ref := B.Member(C.Name, M.Name, M.Descriptor);
      // Redirect the constant-pool entry shared by the five calls. Leave the
      // old draw method intact for a snapshot suspended inside its tile loop.
      var Call := C.Constants[122];
      Call.B := B.JavaClass.Constants[Ref].B;
      B.JavaClass.Constants[122] := Call;
      C.Constants := B.JavaClass.Constants;
    finally
      B.Free;
    end;
    VM.DefineClass(C);
    C := nil;
  finally
    C.Free;
  end;
end;

procedure InstallBimmerScreenTimers(Suite: TJ2MESuite; VM: TJVM);
const
  TimerType = 'Ljava/util/Timer;';
  ReplaceTimer = '$replaceScreenTimer';
  ReplaceDesc = '(' + TimerType + ')V';
  CanvasType = 'javax/microedition/lcdui/Canvas';
  Repaint = '$repaintScreen';
  RepaintDesc = '(L' + CanvasType + ';)V';
  TaskNames: array[0..7] of string = ('i', 'b', 'r', 'v', 'w', 'j', 'x', 'l');
  TaskHashes: array[0..7] of string = (
    'c34b6ae46eeeff12b40606249d9218125163a6602a064dc1c7843c497426eb20',
    '529c9020948624e6e43aceaae8b4f5ecc9785e630c5665e85e367a50f1d00118',
    '4cead4667f5b8bacc4ac615c60ba444fc34cb565c00c5bcdc43cc9ac138a3986',
    '35d1f5f54cc4e42b74755fbe9f52923b2ab7897752642b6d31d8694b66efe881',
    'fb9ebebd6eec35ce087b54ac222f1ae6c079f108e4d547248a061a7222d22fc9',
    '41b1169465a2a923016f52f40a3438f88a4c1e1f8721797aba684f57252e010f',
    'dbcd2bbf1e32c458c5dd60000d1d281e134965715387f6c4ba92dd71dbed7d6e',
    '6e944027e237a263a16bd67eb51c31322fd48b6c9f427f44fafa70640ba810a6');
  TimerStores: array[0..13] of record
  Name: string;
  PC: Integer;
end = (
    (Name: 'b'; PC: 27), (Name: 'c'; PC: 9), (Name: 'c'; PC: 42),
    (Name: 'd'; PC: 1), (Name: 'd'; PC: 38), (Name: 'g'; PC: 26),
    (Name: 'g'; PC: 75), (Name: 'h'; PC: 1), (Name: 'h'; PC: 42),
    (Name: 'i'; PC: 22), (Name: 'j'; PC: 22), (Name: 'k'; PC: 1),
    (Name: 'k'; PC: 46), (Name: '<clinit>'; PC: 13));
var
  Tasks: array[Low(TaskNames)..High(TaskNames)] of TJVMClass;

  procedure ReplaceCall(Method: TJVMMethod; PC: Integer; Target: Word);
  begin
    Method.Code[PC] := $B8;
    Method.Code[PC + 1] := Byte(Target shr 8);
    Method.Code[PC + 2] := Byte(Target);
  end;

  procedure AddMethod(C: TJVMClass; B: TJavaClassBuilder);
  begin
    var Method := B.JavaClass.Methods.Extract(B.JavaClass.Methods.Last);
    Method.Owner := C;
    C.Methods.Add(Method);
  end;

begin
  if not ResourceMatchesHash(Suite, 'Bimmer.class',
    '6f233e16e36cf95a0ca81fed7ebb2aa16c9544aadf7459091d04c968f126a873') then
    Exit;
  for var I := Low(Tasks) to High(Tasks) do
    if not ResourceMatchesHash(Suite, TaskNames[I] + '.class', TaskHashes[I]) then
      Exit;

  var C := TJVMClass.Parse(Suite.ReadResource('Bimmer.class'));
  FillChar(Tasks, SizeOf(Tasks), 0);
  try
    // This game drops its Timer references when changing screens, leaving
    // recurring paint jobs in the old timer queue. Cancel before each store.
    var B := TJavaClassBuilder.Create(C.Name, C.SuperName);
    try
      B.JavaClass.Constants := C.Constants;
      var TimerField := B.Member(C.Name, 'k', TimerType, 9);
      B.Start;
      B.Ref($B2, TimerField);
      B.Emit([$59]); // dup
      B.Jump($C6, 'noOldTimer');
      B.Ref($B6, B.Member('java/util/Timer', 'cancel', '()V'));
      B.Jump($A7, 'assign');
      B.Mark('noOldTimer');
      B.Emit([$57]); // pop
      B.Mark('assign');
      B.Emit([$2A]);
      B.Ref($B3, TimerField);
      B.Emit([$B1]);
      B.Finish(ReplaceTimer, ReplaceDesc, JVM_ACC_PRIVATE or JVM_ACC_STATIC or JVM_ACC_SYNCHRONIZED, 2, 1);
      AddMethod(C, B);
      var StoreTarget := B.Member(C.Name, ReplaceTimer, ReplaceDesc);

      // A task already taken from the queue may finish after cancellation.
      // It may also finish after another screen has become current.
      B.Start;
      B.Emit([$2A]);
      B.Jump($C6, 'done');
      B.Emit([$2A]);
      B.Ref($B6, B.Member(CanvasType, 'isShown', '()Z'));
      B.Jump($99, 'done');
      B.Emit([$2A]);
      B.Ref($B6, B.Member(CanvasType, 'repaint', '()V'));
      B.Mark('done');
      B.Emit([$B1]);
      B.Finish(Repaint, RepaintDesc, JVM_ACC_STATIC, 1, 1);
      AddMethod(C, B);
      C.Constants := B.JavaClass.Constants;
      for var Site in TimerStores do
        ReplaceCall(C.FindMethod(Site.Name, '()V'), Site.PC, StoreTarget);
    finally
      B.Free;
    end;

    for var I := Low(Tasks) to High(Tasks) do
    begin
      var Task := TJVMClass.Parse(Suite.ReadResource(TaskNames[I] + '.class'));
      Tasks[I] := Task;
      var Builder := TJavaClassBuilder.Create(Task.Name, Task.SuperName);
      try
        Builder.JavaClass.Constants := Task.Constants;
        var Target := Builder.Member(C.Name, Repaint, RepaintDesc);
        Task.Constants := Builder.JavaClass.Constants;
        // Keep the original instruction offsets for saved JVM frames.
        ReplaceCall(Task.FindMethod('run', '()V'), 3, Target);
      finally
        Builder.Free;
      end;
    end;

    VM.DefineClass(C);
    C := nil;
    for var I := Low(Tasks) to High(Tasks) do
    begin
      VM.DefineClass(Tasks[I]);
      Tasks[I] := nil;
    end;
  finally
    for var Task in Tasks do
      Task.Free;
    C.Free;
  end;
end;

procedure InstallGolfTourVolume(Suite: TJ2MESuite; VM: TJVM);
const
  PlayerClass = 'gtour/game/o.class';
  VolumeKey = 'SoundMasterVolume';
begin
  if not ResourceMatchesHash(Suite, PlayerClass, '9074290c6bf1e3ed3dc60e3e07ff1e935c1824d1e9992a71e9e7993d19868af3') or
    not ResourceMatchesHash(Suite, 'gtour/game/GolfTourMidlet.class',
      'c80470e8be81d35026092bcafcf45adb83d845eefb45e01ddec5693cd41922d2') then
    Exit;

  var C := TJVMClass.Parse(Suite.ReadResource(PlayerClass));
  try
    // The MIDlet loads SoundMasterVolume from its descriptor. The player
    // reads MasterVolume instead and gets zero for the missing key.
    var TextIndex := C.Constant(44, 8).A;
    C.Constants[TextIndex].Text := VolumeKey;
    VM.DefineClass(C);
    C := nil;
  finally
    C.Free;
  end;
end;

procedure InstallStackAttack2Classes(Suite: TJ2MESuite; VM: TJVM);
const
  Names: array[0..3] of string = ('b', 'e', 'f', 'n');
  Hashes: array[0..3] of string = (
    '03e5341b02b57bd693cdc6f22d3a23668a4d156cf42d212b36166e329bd6044a',
    '21e455bc67f55f6c231d03adc3ca07205a8b27a9f2356a130bd938e6d515f435',
    '0bcfc7e440d8a5d52b61e1bbf134eb4b7565a1a0fe99e111aa44f7ab326230de',
    'bd25eb882d57051a63397ee693d2e26713e23831596696993cdc0d7c2cbecd07');
  FlushPC: array[1..3] of Integer = (256, 9, 24);
begin
  if not J2MECompatibilityStackAttack2(Suite) then
    Exit;
  for var I := Low(Names) to High(Names) do
    if not ResourceMatchesHash(Suite, Names[I] + '.class', Hashes[I]) then
      Exit;

  for var I := Low(Names) to High(Names) do
  begin
    var C := TJVMClass.Parse(Suite.ReadResource(Names[I] + '.class'));
    try
      if I = 0 then
      begin
        // The game reads its static key fields only from the callbacks in b.
        var ConstructorMethod := C.FindMethod('<init>', '(Z)V');
        ConstructorMethod.Code[1] := $03; // iconst_0, allow the key callbacks
      end
      else
      begin
        // These screens draw in overridden paint methods. Their game loops
        // flush an off-screen buffer that they never draw into.
        var RunMethod := C.FindMethod('run', '()V');
        var PC := FlushPC[I];
        var Builder := TJavaClassBuilder.Create(C.Name, C.SuperName);
        try
          Builder.JavaClass.Constants := C.Constants;
          var Target := Builder.Member('javax/microedition/lcdui/Canvas', 'repaint', '()V');
          C.Constants := Builder.JavaClass.Constants;
          RunMethod.Code[PC + 1] := Byte(Target shr 8);
          RunMethod.Code[PC + 2] := Byte(Target);
        finally
          Builder.Free;
        end;
      end;
      VM.DefineClass(C);
      C := nil;
    finally
      C.Free;
    end;
  end;
end;

procedure InstallSummerSkiFrameRate(Suite: TJ2MESuite; VM: TJVM);
const
  PatchPC = 162;
  HelperName = '$frameRate';
  HelperDesc = '(JJJ)I';
begin
  if not J2MECompatibilitySummerSki(Suite) or not ResourceMatchesHash(Suite, 'd.class',
      '1aa51cdb525115e9c2f503d457af54cb5a50947ca4b546b814ccb718e74ed0ac') then
    Exit;
  var C := TJVMClass.Parse(Suite.ReadResource('d.class'));
  try
    var RunMethod := C.FindMethod('run', '()V');
    if (RunMethod = nil) or (Length(RunMethod.Code) < PatchPC + 3) or
      (RunMethod.Code[PatchPC] <> $65) or (RunMethod.Code[PatchPC + 1] <> $6D) or
      (RunMethod.Code[PatchPC + 2] <> $88) then
      Exit;

    // The diagnostic FPS counter can sample the clock twice in the same
    // millisecond. Preserve the quotient for positive elapsed times and keep
    // the original PCs used by saved execution frames.
    var B := TJavaClassBuilder.Create(C.Name, C.SuperName);
    try
      B.JavaClass.Constants := C.Constants;
      B.Start;
      B.Emit([$20, $16, $04, $65, $37, $06]); // elapsed := now - start
      B.Emit([$16, $06, $09, $94]);
      B.Jump($9D, 'elapsed');
      B.Emit([$03, $AC]);
      B.Mark('elapsed');
      B.Emit([$1E, $16, $06, $6D, $88, $AC]);
      B.Finish(HelperName, HelperDesc, JVM_ACC_PRIVATE or JVM_ACC_STATIC, 4, 8);
      var Helper := B.JavaClass.Methods.Last;
      Helper.Owner := C;
      var Target := B.Member(C.Name, HelperName, HelperDesc);
      C.Constants := B.JavaClass.Constants;
      C.Methods.Add(Helper);
      B.JavaClass.Methods.Extract(Helper);
      RunMethod.Code[PatchPC] := $B8;
      RunMethod.Code[PatchPC + 1] := Byte(Target shr 8);
      RunMethod.Code[PatchPC + 2] := Byte(Target);
    finally
      B.Free;
    end;
    VM.DefineClass(C);
    C := nil;
  finally
    C.Free;
  end;
end;

procedure InstallGuitarHero5LocaleFallback(Suite: TJ2MESuite; VM: TJVM);
const
  Engine = 'm';
  LocalePC = 40;
  HelperName = '$resourceLocale';
  HelperDesc = '()I';
begin
  if not ResourceMatchesHash(Suite, 'Ghero5mm.class',
    '4c10edada84cc2a07736772d623104a394cd843a11bdffd06710e15d9160a68b') or
    not ResourceMatchesHash(Suite, Engine + '.class',
      '5b45c883f90a3cae5a0d4aa5ca4f1da20d7d0aaae31faefb8435e24e98d415c0') then
    Exit;
  var C := TJVMClass.Parse(Suite.ReadResource(Engine + '.class'));
  try
    var Resource := C.FindMethod('b', '(I)Ljava/io/DataInputStream;');
    if (Resource = nil) or (Length(Resource.Code) < LocalePC + 3) or
      (Resource.Code[LocalePC] <> $B2) then
      Exit;

    // The locale selector uses -1 until the first choice, but splash/menu
    // resources already use the locale table. Its first entry is English.
    var B := TJavaClassBuilder.Create(C.Name, C.SuperName);
    try
      B.JavaClass.Constants := C.Constants;
      B.Start;
      B.Ref($B2, B.Member(Engine, 'dp', 'I', 9));
      B.Emit([$59]); // Keep the selected locale for the nonnegative branch.
      B.Jump($9C, 'selected');
      B.Emit([$57, $03]);
      B.Mark('selected');
      B.Emit([$AC]);
      B.Finish(HelperName, HelperDesc, JVM_ACC_PRIVATE or JVM_ACC_STATIC, 2, 0);
      var Helper := B.JavaClass.Methods.Last;
      Helper.Owner := C;
      var Target := B.Member(Engine, HelperName, HelperDesc);
      C.Constants := B.JavaClass.Constants;
      C.Methods.Add(Helper);
      B.JavaClass.Methods.Extract(Helper);
      Resource.Code[LocalePC] := $B8;
      Resource.Code[LocalePC + 1] := Byte(Target shr 8);
      Resource.Code[LocalePC + 2] := Byte(Target);
    finally
      B.Free;
    end;
    VM.DefineClass(C);
    C := nil;
  finally
    C.Free;
  end;
end;

procedure InstallBalloonzUndoGuard(Suite: TJ2MESuite; VM: TJVM);
const
  CanvasClass = 'game/c';
  UndoScorePC = 106;
  GuardName = '$undoScore';
  GuardDesc = '(Lgame/c;)I';
begin
  if not ResourceMatchesHash(Suite, CanvasClass + '.class',
    '2e19facb30169308a8244ace6fa8d6a850894cb4b1acb7076c6f434936332e6d') then
    Exit;
  var C := TJVMClass.Parse(Suite.ReadResource(CanvasClass + '.class'));
  try
    var Command := C.FindMethod('commandAction',
      '(Ljavax/microedition/lcdui/Command;Ljavax/microedition/lcdui/Displayable;)V');
    if (Command = nil) or (Length(Command.Code) < UndoScorePC + 3) or
      (Command.Code[UndoScorePC] <> $B4) then
      Exit;

    // Undo is already on the splash screen, but the first move has not
    // stored a colour count (q) or initialized the undo score sentinel (m).
    // Return the existing "no undo" sentinel until a valid move was saved.
    var B := TJavaClassBuilder.Create(C.Name, C.SuperName);
    try
      B.JavaClass.Constants := C.Constants;
      B.Start;
      B.Emit([$2A]);
      B.Ref($B4, B.Member(CanvasClass, 'q', 'I', 9));
      B.Emit([$06]); // Three is the minimum saved colour count.
      B.Jump($A2, 'undoReady');
      B.Emit([$02, $AC]);
      B.Mark('undoReady');
      B.Emit([$2A]);
      B.Ref($B4, B.Member(CanvasClass, 'm', 'I', 9));
      B.Emit([$AC]);
      B.Finish(GuardName, GuardDesc, JVM_ACC_PRIVATE or JVM_ACC_STATIC, 2, 1);
      var Guard := B.JavaClass.Methods.Last;
      Guard.Owner := C;
      var Target := B.Member(CanvasClass, GuardName, GuardDesc);
      C.Constants := B.JavaClass.Constants;
      C.Methods.Add(Guard);
      B.JavaClass.Methods.Extract(Guard);
      // Replace getfield with an equally sized call so saved PCs stay valid.
      Command.Code[UndoScorePC] := $B8;
      Command.Code[UndoScorePC + 1] := Byte(Target shr 8);
      Command.Code[UndoScorePC + 2] := Byte(Target);
    finally
      B.Free;
    end;
    VM.DefineClass(C);
    C := nil;
  finally
    C.Free;
  end;
end;

function InstallArmiesOfWarClasses(Suite: TJ2MESuite; VM: TJVM): TJVMClass;
const
  PalettePC = 48;
  FireCallPC = 7;
  DiffusePC = 700;
  AfterDiffusePC = 839;
  ColorPC = 845;
  AfterColorPC = 916;
  Engine = 'j';
  Diffused = '$diffuseMenuFire';
  DiffuseDesc = '([BII)V';
  Colored = '$colorMenuFire';
  ColorDesc = '([B[I[III)V';
var
  Owner, Name, Descriptor: string;

  procedure Retarget(const Code: TBytes; PC: Integer; Index: Word);
  begin
    Code[PC + 1] := Byte(Index shr 8);
    Code[PC + 2] := Byte(Index);
  end;

begin
  Result := nil;
  if not ResourceMatchesHash(Suite, 'War.class', '3713a27e2bef560f400dd92eff095e40cfa1fbb68dac85b05254e822c6e75b1a') or
    not ResourceMatchesHash(Suite, 'j.class', '2451d8f26a58689cbc721e7baa47099155625acff0951d3e85e7a5b97b7f3178') or
    not ResourceMatchesHash(Suite, '2', '19609d8bd2e2accd59b0e2c4f7642c44b6c868b48d27782150d37b26184a7edc') then
    Exit;

  var C := TJVMClass.Parse(Suite.ReadResource('j.class'));
  try
    var Init := C.FindMethod('v', '(I)V');
    var Update := C.FindMethod('x', '(I)V');
    var Fire := C.FindMethod('W', '()V');
    if (Init = nil) or (Update = nil) or (Fire = nil) or
      (Length(Init.Code) < PalettePC + 3) or (Init.Code[PalettePC] <> $B8) or
      (Length(Update.Code) < FireCallPC + 3) or (Update.Code[FireCallPC] <> $B8) or
      (Length(Fire.Code) <> AfterColorPC + 1) or (Length(Fire.Handlers) <> 0) or (C.Major >= 50) then
      Exit;
    C.MemberRef((Word(Init.Code[PalettePC + 1]) shl 8) or Init.Code[PalettePC + 2], Owner, Name, Descriptor);
    if (Owner <> Engine) or (Name <> 'c') or (Descriptor <> '(I)[B') then
      Exit;
    C.MemberRef((Word(Update.Code[FireCallPC + 1]) shl 8) or Update.Code[FireCallPC + 2], Owner, Name, Descriptor);
    if (Owner <> Engine) or (Name <> 'W') or (Descriptor <> '()V') then
      Exit;

    var B := TJavaClassBuilder.Create(C.Name, C.SuperName);
    try
      B.JavaClass.Constants := C.Constants;
      // The last 208 entries of the 256-color resource are padding. The
      // original loop already kept the first 48 after catching its overflow.
      B.Start;
      B.Emit([$1A]);
      B.Ref($B8, B.Member(Engine, 'c', '(I)[B'));
      B.Emit([$4C, $2B]);
      B.Jump($C6, 'original');
      B.Emit([$2B, $BE, $11, 0, 192]);
      B.Jump($A4, 'original');
      B.Emit([$11, 0, 192, $BC, 8, $4D]);
      B.Emit([$2B, $03, $2C, $03, $11, 0, 192]);
      B.Ref($B8, B.Member('java/lang/System', 'arraycopy', '(Ljava/lang/Object;ILjava/lang/Object;II)V'));
      B.Emit([$2C, $B0]);
      B.Mark('original');
      B.Emit([$2B, $B0]);
      B.Finish('$readMenuFirePalette', '(I)[B', JVM_ACC_PRIVATE or JVM_ACC_STATIC, 5, 3);
      var PaletteMethod := B.JavaClass.Methods.Extract(B.JavaClass.Methods.Last);
      PaletteMethod.Owner := C;
      C.Methods.Add(PaletteMethod);
      Retarget(Init.Code, PalettePC, B.Member(Engine, PaletteMethod.Name, PaletteMethod.Descriptor));

      // Keep the saved frame PCs of the original W method valid. Only new
      // calls take a copy with the two dense numerical loops accelerated.
      var FastFire := TJVMMethod.Create;
      C.Methods.Add(FastFire);
      FastFire.Owner := C;
      FastFire.Name := '$updateMenuFire';
      FastFire.Descriptor := Fire.Descriptor;
      FastFire.Access := Fire.Access;
      FastFire.MaxLocals := Fire.MaxLocals;
      FastFire.MaxStack := Max(Fire.MaxStack, 5);
      FastFire.Signature := Fire.Signature;
      FastFire.Code := Copy(Fire.Code);
      var HeatField := B.Member(Engine, 'h', '[B', 9);
      var WidthField := B.Member(Engine, 'bI', 'I', 9);
      var HeightField := B.Member(Engine, 'bJ', 'I', 9);
      var PixelsField := B.Member(Engine, 'G', '[I', 9);
      var PaletteField := B.Member(Engine, 'H', '[I', 9);
      C.AddNative(Diffused, DiffuseDesc, True).Access := JVM_ACC_PRIVATE or JVM_ACC_STATIC or JVM_ACC_NATIVE;
      C.AddNative(Colored, ColorDesc, True).Access := JVM_ACC_PRIVATE or JVM_ACC_STATIC or JVM_ACC_NATIVE;

      var PC := DiffusePC;
      for var Index in TArray<Word>.Create(HeatField, WidthField, HeightField) do
      begin
        FastFire.Code[PC] := $B2;
        Retarget(FastFire.Code, PC, Index);
        Inc(PC, 3);
      end;
      FastFire.Code[PC] := $B8;
      Retarget(FastFire.Code, PC, B.Member(Engine, Diffused, DiffuseDesc));
      Inc(PC, 3);
      FastFire.Code[PC] := $A7;
      Retarget(FastFire.Code, PC, AfterDiffusePC - PC);
      FillChar(FastFire.Code[PC + 3], AfterDiffusePC - PC - 3, 0);

      PC := ColorPC;
      for var Index in TArray<Word>.Create(HeatField, PixelsField, PaletteField, WidthField, HeightField) do
      begin
        FastFire.Code[PC] := $B2;
        Retarget(FastFire.Code, PC, Index);
        Inc(PC, 3);
      end;
      FastFire.Code[PC] := $B8;
      Retarget(FastFire.Code, PC, B.Member(Engine, Colored, ColorDesc));
      Inc(PC, 3);
      FastFire.Code[PC] := $B1;
      FillChar(FastFire.Code[PC + 1], AfterColorPC - PC, 0);
      Retarget(Update.Code, FireCallPC, B.Member(Engine, FastFire.Name, FastFire.Descriptor));
      C.Constants := B.JavaClass.Constants;
    finally
      B.Free;
    end;

    VM.DefineClass(C);
    Result := C;
    C := nil;
  finally
    C.Free;
  end;
end;

procedure InvokeArmiesOfWarCompatibility(VM: TJVM; Method: TJVMMethod; const Arguments: TArray<TJVMValue>);
begin
  var Diffuse := Method.Name = '$diffuseMenuFire';
  if not Diffuse and (Method.Name <> '$colorMenuFire') then
    raise EJVMUnsupported.Create('Unknown Armies of War compatibility method');
  var Heat := VM.GetObject(Arguments[0].AsRef);
  var Width := Arguments[High(Arguments) - 1].AsInt;
  var Height := Arguments[High(Arguments)].AsInt;
  var Count := Int64(Width) * Height;
  if (Width < 1) or (Height < 4) or (Count > Heat.ElementCount) then
    VM.RaiseJava('java/lang/ArrayIndexOutOfBoundsException', 'Menu fire dimensions');

  if Diffuse then
  begin
    for var Y := 1 to Height - 2 do
      for var X := 0 to Width - 1 do
      begin
        var Index := Y * Width + X;
        var Value := (Heat.ElementValues[Index].AsInt and 255) +
          (Heat.ElementValues[Index + Width].AsInt and 255);
        // Java reads the neighboring bytes by linear index, including the
        // boundary pixels, and writes the row above in ascending order.
        if Y > Height div 4 then
          Value := (Value + (Heat.ElementValues[Index + 1].AsInt and 255) +
            (Heat.ElementValues[Index - 1].AsInt and 255)) div 4
        else
          Value := Value div 2;
        Heat.ElementValues[Index - Width] := TJVMValue.Int(Max(0, Value - 1));
      end;
    Exit;
  end;

  var Pixels := VM.GetObject(Arguments[1].AsRef);
  var Palette := VM.GetObject(Arguments[2].AsRef);
  var Colors, Output: PInteger;
  if (Count > Pixels.ElementCount) or (Palette.ElementCount = 0) or
    not Pixels.TryIntData(Output) or not Palette.TryIntData(Colors) then
    VM.RaiseJava('java/lang/ArrayIndexOutOfBoundsException', 'Menu fire pixels or palette');
  {$POINTERMATH ON}
  for var I := 0 to Integer(Count) - 1 do
  begin
    var Value := EnsureRange(Heat.ElementValues[I].AsInt, 0, Palette.ElementCount - 1);
    Output[I] := Colors[Value];
  end;
  {$POINTERMATH OFF}
end;

procedure InstallNinjaMasterLoadingPaint(Suite: TJ2MESuite; VM: TJVM);
const
  ScreenClass = 'Screen';
  GraphicsDesc = 'Ljavax/microedition/lcdui/Graphics;';
  PaintCallPC = 40;
  HelperName = '$drawLoadedBackground';
  HelperDesc = '(LSprite;' + GraphicsDesc + 'IIII)V';
begin
  if not ResourceMatchesHash(Suite, ScreenClass + '.class',
    'cb1db59292f589502ee9fa2aace1c6bbeff6563612243db4141fed14a6adb45d') or
    not ResourceMatchesHash(Suite, 'Deflex.class',
      '0fa347b91276bbef8bb96310d61027fbd27335cd721502e07f5ea359b375f3cf') then
    Exit;
  var C := TJVMClass.Parse(Suite.ReadResource(ScreenClass + '.class'));
  try
    var Paint := C.FindMethod('paint', '(' + GraphicsDesc + ')V');
    if (Paint = nil) or (Length(Paint.Code) < PaintCallPC + 3) or (Paint.Code[PaintCallPC] <> $B6) then
      Exit;

    // loadShit paints its progress before loading the background. Keep the
    // progress paint running, and retain the original paint instruction offsets.
    var B := TJavaClassBuilder.Create(C.Name, C.SuperName);
    try
      B.JavaClass.Constants := C.Constants;
      B.Start;
      B.Emit([$2A]); // background
      B.Jump($C6, 'done');
      B.Emit([$2A, $2B, $1C, $1D, $15, $04, $15, $05]);
      B.Ref($B6, B.Member('Sprite', 'P', '(' + GraphicsDesc + 'IIII)V'));
      B.Mark('done');
      B.Emit([$B1]);
      B.Finish(HelperName, HelperDesc, JVM_ACC_PRIVATE or JVM_ACC_STATIC, 6, 6);
      var Helper := B.JavaClass.Methods.Last;
      Helper.Owner := C;
      var Target := B.Member(ScreenClass, HelperName, HelperDesc);
      C.Constants := B.JavaClass.Constants;
      C.Methods.Add(Helper);
      B.JavaClass.Methods.Extract(Helper);
      Paint.Code[PaintCallPC] := $B8;
      Paint.Code[PaintCallPC + 1] := Byte(Target shr 8);
      Paint.Code[PaintCallPC + 2] := Byte(Target);
    finally
      B.Free;
    end;
    VM.DefineClass(C);
    C := nil;
  finally
    C.Free;
  end;
end;

type
  TScreenWorkerWait = record
    MethodName, Descriptor: string;
    PC: Integer;
  end;

procedure InstallGravityDefiedInputGuard(Suite: TJ2MESuite; VM: TJVM);
const
  CanvasClass = 'i';
  BikeClass = 'b';
  CallPC = 119;
  GuardName = '$applyInputIfBikeReady';
  GuardDesc = '(Lb;II)V';
begin
  // GD Red and Gravity Defied Pro use the same canvas. It can receive a
  // key event before the level loader has assigned its bike.
  if not ResourceMatchesHash(Suite, CanvasClass + '.class',
    'ce43b4f0fd1e05a6c8ae5ee9c9c256ed8ad5eaaea9d8cbe96a94402b69aedfcd') then
    Exit;

  var C := TJVMClass.Parse(Suite.ReadResource(CanvasClass + '.class'));
  try
    var Apply := C.FindMethod('xa', '()V');
    if (Apply = nil) or (Length(Apply.Code) < CallPC + 3) or
      (Apply.Code[CallPC] <> $B6) or (Apply.Code[CallPC + 1] <> $01) or
      (Apply.Code[CallPC + 2] <> $14) then
      Exit;

    var B := TJavaClassBuilder.Create(C.Name, C.SuperName);
    try
      B.JavaClass.Constants := C.Constants;
      B.Start;
      B.Emit([$2A]);
      B.Jump($C6, 'done');
      B.Emit([$2A, $1B, $1C]);
      B.Ref($B6, B.Member(BikeClass, 'a', '(II)V'));
      B.Mark('done');
      B.Emit([$B1]);
      B.Finish(GuardName, GuardDesc, JVM_ACC_PRIVATE or JVM_ACC_STATIC, 3, 3);
      var Guard := B.JavaClass.Methods.Last;
      var Target := B.Member(CanvasClass, GuardName, GuardDesc);
      Guard.Owner := C;
      C.Constants := B.JavaClass.Constants;
      C.Methods.Add(Guard);
      B.JavaClass.Methods.Extract(Guard);
      Apply.Code[CallPC] := $B8;
      Apply.Code[CallPC + 1] := Byte(Target shr 8);
      Apply.Code[CallPC + 2] := Byte(Target);
    finally
      B.Free;
    end;
    VM.DefineClass(C);
    C := nil;
  finally
    C.Free;
  end;
end;

procedure InstallEuromanSplashInputGuard(Suite: TJ2MESuite; VM: TJVM);
const
  SplashClass = 'a/a/a/c';
  GameClass = 'a/a/a/b';
  GuardDesc = '(La/a/a/b;)V';
  CallPCs: array[0..1] of Integer = (9, 24);
  CallNames: array[0..1] of string = ('if', 'new');
  GuardNames: array[0..1] of string = ('$splashLeftIfReady', '$splashRightIfReady');
begin
  if not ResourceMatchesHash(Suite, SplashClass + '.class',
    'a9d775e7dbc9e06d5e6b4291a6fa2b8f773b95dfc0eac99c99225489d3cf7e2d') or
    not ResourceMatchesHash(Suite, GameClass + '.class',
      '197b7267c146626067b0fc9c59d7a8f39c3161be3a1cdd91524f048768c70a3d') then
    Exit;

  var Splash := TJVMClass.Parse(Suite.ReadResource(SplashClass + '.class'));
  var Game: TJVMClass := nil;
  try
    var Key := Splash.FindMethod('keyPressed', '(I)V');
    if (Key = nil) or (Length(Key.Code) <> 28) then
      Exit;
    for var Index := 0 to High(CallPCs) do
    begin
      var PC := CallPCs[Index];
      if (Key.Code[PC] <> $B6) or (Key.Code[PC + 1] <> 0) or (Key.Code[PC + 2] <> 97 + Index) then
        Exit;
    end;

    Game := TJVMClass.Parse(Suite.ReadResource(GameClass + '.class'));
    var GameBuilder := TJavaClassBuilder.Create(Game.Name, Game.SuperName);
    try
      var SplashBuilder := TJavaClassBuilder.Create(Splash.Name, Splash.SuperName);
      try
        GameBuilder.JavaClass.Constants := Game.Constants;
        SplashBuilder.JavaClass.Constants := Splash.Constants;
        // The splash can receive soft keys before its loader has created the
        // game screen's graphics and background. Leave those keys on the
        // splash until both resources exist, without changing game state.
        for var Index := 0 to High(CallPCs) do
        begin
          GameBuilder.Start;
          GameBuilder.Emit([$2A]); // aload_0
          GameBuilder.Jump($C6, 'done'); // ifnull
          GameBuilder.Emit([$2A]);
          GameBuilder.Ref($B4, GameBuilder.Member(GameClass, 'az', 'Ljavax/microedition/lcdui/Image;', 9));
          GameBuilder.Jump($C6, 'done');
          GameBuilder.Emit([$2A]);
          GameBuilder.Ref($B6, GameBuilder.Member(GameClass, CallNames[Index], '()V'));
          GameBuilder.Mark('done');
          GameBuilder.Emit([$B1]);
          GameBuilder.Finish(GuardNames[Index], GuardDesc, JVM_ACC_STATIC, 1, 1);
          var Guard := GameBuilder.JavaClass.Methods.Extract(GameBuilder.JavaClass.Methods.Last);
          Guard.Owner := Game;
          Game.Methods.Add(Guard);

          var PC := CallPCs[Index];
          var Target := SplashBuilder.Member(GameClass, GuardNames[Index], GuardDesc);
          Key.Code[PC] := $B8;
          Key.Code[PC + 1] := Byte(Target shr 8);
          Key.Code[PC + 2] := Byte(Target);
        end;
        Game.Constants := GameBuilder.JavaClass.Constants;
        Splash.Constants := SplashBuilder.JavaClass.Constants;
      finally
        SplashBuilder.Free;
      end;
    finally
      GameBuilder.Free;
    end;
    VM.DefineClass(Game);
    Game := nil;
    VM.DefineClass(Splash);
    Splash := nil;
  finally
    Game.Free;
    Splash.Free;
  end;
end;

procedure InstallScreenWorkerJoin(Suite: TJ2MESuite; VM: TJVM; const ClassName, ClassHash: string; const Waits: array of TScreenWorkerWait);
const
  ThreadClass = 'java/lang/Thread';
  HelperName = '$waitForScreen';
  HelperDesc = '(Ljava/lang/Thread;)Z';
begin
  var ResourceName := ClassName + '.class';
  if not ResourceMatchesHash(Suite, ResourceName, ClassHash) then
    Exit;
  var C := TJVMClass.Parse(Suite.ReadResource(ResourceName));
  try
    for var Wait in Waits do
    begin
      var Caller := C.FindMethod(Wait.MethodName, Wait.Descriptor);
      if (Caller = nil) or (Length(Caller.Code) < Wait.PC + 3) or (Caller.Code[Wait.PC] <> $B6) then
        Exit;
    end;

    // Wait for each screen worker without spinning in the launcher's isAlive loop.
    var B := TJavaClassBuilder.Create(C.Name, C.SuperName);
    try
      B.JavaClass.Constants := C.Constants;
      B.Start;
      B.Mark('join');
      B.Emit([$2A]);
      B.Ref($B6, B.Member(ThreadClass, 'join', '()V'));
      B.Mark('done');
      B.Emit([$03, $AC]); // Return false after the worker has exited.
      B.Mark('interrupted');
      B.Emit([$57]);
      B.Ref($B8, B.Member(ThreadClass, 'currentThread', '()Ljava/lang/Thread;'));
      B.Ref($B6, B.Member(ThreadClass, 'interrupt', '()V'));
      B.Emit([$2A]);
      B.Ref($B6, B.Member(ThreadClass, 'isAlive', '()Z'));
      B.Emit([$AC]);
      B.Finish(HelperName, HelperDesc, JVM_ACC_PRIVATE or JVM_ACC_STATIC, 1, 1);
      var Handler: TJVMExceptionHandler;
      Handler.StartPC := B.Position('join');
      Handler.EndPC := B.Position('done');
      Handler.HandlerPC := B.Position('interrupted');
      Handler.CatchType := B.ClassRef('java/lang/InterruptedException');
      var Helper := B.JavaClass.Methods.Last;
      Helper.Handlers := [Handler];
      Helper.Owner := C;
      var Target := B.Member(C.Name, HelperName, HelperDesc);
      C.Constants := B.JavaClass.Constants;
      C.Methods.Add(Helper);
      B.JavaClass.Methods.Extract(Helper);
      for var Wait in Waits do
      begin
        var Caller := C.FindMethod(Wait.MethodName, Wait.Descriptor);
        Caller.Code[Wait.PC] := $B8;
        Caller.Code[Wait.PC + 1] := Byte(Target shr 8);
        Caller.Code[Wait.PC + 2] := Byte(Target);
      end;
    finally
      B.Free;
    end;
    VM.DefineClass(C);
    C := nil;
  finally
    C.Free;
  end;
end;

procedure InstallIronMan3MediaTimeLookup(Suite: TJ2MESuite; VM: TJVM);
const
  AudioClass = 'a';
  PlayerClass = 'javax/microedition/media/Player';
  TimeCallPC = 19;
  HelperName = '$mediaTimeIfAssigned';
  HelperDesc = '(Ljavax/microedition/media/Player;)J';
begin
  if not ResourceMatchesHash(Suite, AudioClass + '.class',
    '4654cb6b09ff1fd7f2b4a5c6aed32e72f9730b05010c7c14098e4baffa3983a0') then
    Exit;
  var C := TJVMClass.Parse(Suite.ReadResource(AudioClass + '.class'));
  try
    var ReadTime := C.FindMethod('a', '(I)J');
    if (ReadTime = nil) or (Length(ReadTime.Code) < TimeCallPC + 5) or
      (ReadTime.Code[TimeCallPC] <> $B9) then
      Exit;
    var TimeMethod := (Word(ReadTime.Code[TimeCallPC + 1]) shl 8) or ReadTime.Code[TimeCallPC + 2];
    var Owner, Name, Desc: string;
    C.MemberRef(TimeMethod, Owner, Name, Desc);
    if (Owner <> PlayerClass) or (Name <> 'getMediaTime') or (Desc <> '()J') then
      Exit;

    // The audio worker polls empty slots and already catches null to return
    // -1. Avoid throwing each time and keep the original call offsets.
    var B := TJavaClassBuilder.Create(C.Name, C.SuperName);
    try
      B.JavaClass.Constants := C.Constants;
      B.Start;
      B.Emit([$2A]);
      B.Jump($C7, 'assigned');
      B.Emit([$02, $85, $AD]); // return -1L
      B.Mark('assigned');
      B.Emit([$2A]);
      B.Ref($B9, TimeMethod);
      B.Emit([$01, $00, $AD]); // receiver slot count, reserved byte, lreturn
      B.Finish(HelperName, HelperDesc, JVM_ACC_PRIVATE or JVM_ACC_STATIC, 2, 1);
      var Helper := B.JavaClass.Methods.Last;
      Helper.Owner := C;
      var Target := B.Member(C.Name, HelperName, HelperDesc);
      C.Constants := B.JavaClass.Constants;
      C.Methods.Add(Helper);
      B.JavaClass.Methods.Extract(Helper);
      ReadTime.Code[TimeCallPC] := $B8;
      ReadTime.Code[TimeCallPC + 1] := Byte(Target shr 8);
      ReadTime.Code[TimeCallPC + 2] := Byte(Target);
      ReadTime.Code[TimeCallPC + 3] := $00;
      ReadTime.Code[TimeCallPC + 4] := $00;
    finally
      B.Free;
    end;
    VM.DefineClass(C);
    C := nil;
  finally
    C.Free;
  end;
end;

procedure InstallCrashBandicootSoundListener(Suite: TJ2MESuite; VM: TJVM);
const
  ListenerPath = 'CrashBandicoot/c.class';
  ListenerHash = 'b907aa7c85cdd08280ccfdd60c02c4fd7e71ff18290a89158f46311708052601';
  MIDletHash = 'a8decb306810a517a8e2ef08c61d1dd8612f25128d04fb9c28149de45274e6c0';
  SwitchPC = 1;
  StoppedCaseOffset = 19; // Low byte of the lookupswitch offset for state 1.
  HandlerPC = 31;
begin
  if not ResourceMatchesHash(Suite, ListenerPath, ListenerHash) or
    not ResourceMatchesHash(Suite, 'CrashBandicoot/GameTopLevel.class', MIDletHash) then
    Exit;
  var C := TJVMClass.Parse(Suite.ReadResource(ListenerPath));
  try
    var Callback := C.FindMethod('soundStateChanged', '(Lcom/nokia/mid/sound/Sound;I)V');
    if (Callback = nil) or (Length(Callback.Code) <> HandlerPC) then
      Exit;
    // A pending stop may belong to an older Sound. Release the event's Sound
    // and clear the shared slot only if it still refers to that instance.
    // Append the handler so older snapshots keep their instruction offsets.
    Callback.Code[StoppedCaseOffset] := HandlerPC - SwitchPC;
    Callback.Code := Callback.Code + [
        $2B,                 // aload_1
        $B6, $00, $03,       // Sound.release()
        $B2, $00, $02,       // getstatic c.do
        $2B,                 // aload_1
        $A6, $00, $07,       // if_acmpne return
        $01,                 // aconst_null
        $B3, $00, $02,       // putstatic c.do
        $B1];                // return
    Callback.MaxStack := Max(Callback.MaxStack, 2);
    VM.DefineClass(C);
    C := nil;
  finally
    C.Free;
  end;
end;

procedure InstallMotorolaFullCanvasCompatibility(Suite: TJ2MESuite; VM: TJVM);
const
  FullCn = 'com/hellomoto/fullscreen/FullCn';
  CanvasClass = 'javax/microedition/lcdui/Canvas';
  OldConstructor = '(L' + FullCn + ';)V';
  NewConstructor = '(L' + CanvasClass + ';)V';
  FantasyMIDlet = 'GameMIDlet';
  FantasyMIDletHash = '742caaa7d589e50f7ea934c4b139f297880daf4ff67ec362e17daa0d6290759c';
  MIDlets: array[0..20] of record
  Resource, Digest: string;
end = (
    (Resource: 'Sib/Sib.class'; Digest: 'f347ddc91c1de6d54ebc4fbe44380e30c4cb31d1fe4d8e707d0335eca6c0101d'),
    (Resource: 'AfterDark/AfterDark.class'; Digest: '932373232674fe8601418ca2d9db361abc7bff9b776ab81c7d1d1b2ceb78b44f'),
    (Resource: 'JDMidlet.class'; Digest: '7d11bcf3de7523f594a127cc9a460155ce747f9ea41787a4756e3552ed1390f9'),
    (Resource: 'Container/GameMIDlet.class'; Digest: '2764020351938aa5795e527ab75d6332f676926fc92cee809366c35f05dc9200'),
    (Resource: 'Arkanoid.class'; Digest: '0478c61b40c702ef33c1f48ab63034187f326bf5013e7e9745a53749287a3379'),
    (Resource: 'mbsBoot.class'; Digest: 'e1f41b1506ef5459aaf2516c77814cdaf253104f6ac4ea242330952eddaf6d18'),
    (Resource: 'CowBandits.class'; Digest: 'dd3899b95a3cd1623a3daea99b8fca384746543a965093ce8b12dffb2365018d'),
    (Resource: 'DOTC/DOTC.class'; Digest: 'ca39606759ffb13915fd2ddccc83f9e0dc5b247afe7fbc2a1c43db429235c552'),
    (Resource: 'com/sorrent/games/GameMIDlet3650.class'; Digest: 'c4a38f45c3929e9285bf833440bad7e8973039fc15ac8481710d2486f1ffdf64'),
    (Resource: 'com/xendex/games/Adventure/AdvMain.class'; Digest: '42f221ace6c81ac3f04a8171e6ff049330b6f74ec84d3a00b6d6ed9d30f420bf'),
    (Resource: 'Hockey/MainPRG.class'; Digest: '7d686273652438031915440281f3f5b82e6288efaed931c53408ff036a5c49da'),
    (Resource: 'mm/mm.class'; Digest: 'ae5bf3c86fbb4999a7fa03b4f069d05692f76ee87d31b8175e066340d9a0b11b'),
    (Resource: 'CMIDlet.class'; Digest: '563f765a5b9bca6e494370e728f695d130678b1c75ea2e9929d199e3d1293aae'),
    (Resource: 'MotoGP3/MotoGP3.class'; Digest: '6de88a20c3e760e141c681b7e75bf7073b7e4a01fb0a991fd6551e887b592a2b'),
    (Resource: 'Init.class'; Digest: '69a82f2339a5db49066becab10d89cec76217d4e0cd06ab8ae5f603a285f0fad'),
    (Resource: 'GolfMaster.class'; Digest: '5eef4995f4bfeedc480f8c04e2ffafab8102075330dc347469ca36d1d9f020d2'),
    (Resource: 'ShootingGallery.class'; Digest: 'cb5f7ef0dd2c765bbb9b452163753dc2a6be6bde6a6b1ce6bd037a5948337da2'),
    (Resource: 'themummy/TheMummyMidlet.class'; Digest: '658ad0c3adc30e5babaa2659d92c73a4cc2a50791790b6c1605e71ce96276af6'),
    (Resource: 'THAW.class'; Digest: '054c2f5f2a771ecadc45f1edb80b9e34a7f07af9e5e3c6978c8daba92a7c5bad'),
    (Resource: 'RMIDlet.class'; Digest: '35b475448d496c713cd440d3ea12465bbdba1ce1c978c66b4669f5fc46fe5a87'),
    (Resource: 'Midlet.class'; Digest: 'a54fc18536d3b19206d05102d192dca270c4d1ac67f224788763867bb80c6641'));
var
  RainbowConstructor, FantasyCanvas: Boolean;

  function IsReviewedPort: Boolean;
  begin
    for var Entry in MIDlets do
      if ResourceMatchesHash(Suite, Entry.Resource, Entry.Digest) then
        Exit(True);
    Result := False;
  end;

  function IsCanvasMethod(const Name, Descriptor: string): Boolean;
  begin
    Result := ((Descriptor = '()V') and MatchStr(Name, ['repaint', 'serviceRepaints'])) or
      ((Descriptor = '()I') and MatchStr(Name, ['getWidth', 'getHeight'])) or
      ((Descriptor = '(I)I') and MatchStr(Name, ['getGameAction', 'getKeyCode'])) or
      ((Name = 'getKeyName') and (Descriptor = '(I)Ljava/lang/String;')) or
      ((Name = 'repaint') and (Descriptor = '(IIII)V')) or
      ((Name = 'setFullScreenMode') and (Descriptor = '(Z)V')) or
      ((Name = 'isDoubleBuffered') and (Descriptor = '()Z'));
  end;

  procedure InstallClass(const ClassName: string);
  var
    C: TJVMClass;
    Owner, Name, Descriptor: string;
  begin
    var Data := Suite.LoadClass(ClassName);
    if Length(Data) = 0 then
      Exit;
    try
      C := TJVMClass.Parse(Data);
    except
      on EJVMFormatError do
        Exit; // Retain normal failure if this class is actually loaded.
    end;
    try
      if C.Name <> ClassName then
        Exit;
      // Rainbow Island's helper only checks this constructor argument for
      // null. Widen its descriptor and preverification type to Canvas.
      var WidenConstructor := RainbowConstructor and ((ClassName = 'e') or (ClassName = 'f'));
      // Fantasy Warriors casts the Nokia canvas to FullCn before calling
      // shared Canvas methods. Widen the cast and all its verifier references.
      var WidenCanvas := FantasyCanvas and (ClassName = FantasyMIDlet);
      if WidenConstructor or WidenCanvas then
        for var I := 1 to High(C.Constants) do
          if C.Constants[I].Tag = 1 then
          begin
            if WidenConstructor and (C.Constants[I].Text = OldConstructor) then
              C.Constants[I].Text := NewConstructor
            else if (WidenCanvas or (ClassName = 'f')) and (C.Constants[I].Text = FullCn) then
              C.Constants[I].Text := CanvasClass;
          end;
      if WidenConstructor and (ClassName = 'f') then
        C.FindMethod('<init>', OldConstructor).Descriptor := NewConstructor;

      var Builder: TJavaClassBuilder := nil;
      try
        for var Method in C.Methods do
          for var PC := 0 to High(Method.Code) do
            if Method.InstructionStarts[PC] and (Method.Code[PC] in [$B6, $B7]) then
            begin
              var Index := (Word(Method.Code[PC + 1]) shl 8) or Method.Code[PC + 2];
              if (Index = 0) or (Index >= Length(C.Constants)) or (C.Constants[Index].Tag <> 10) then
                Continue;
              C.MemberRef(Index, Owner, Name, Descriptor);
              if (Owner <> FullCn) or not IsCanvasMethod(Name, Descriptor) then
                Continue;
              // The reviewed Tony Hawk port also has a stale super call.
              if (Method.Code[PC] = $B7) and
                ((ClassName <> 'r') or (C.SuperName <> 'com/nokia/mid/ui/FullCanvas') or
                (Name <> 'getGameAction')) then
                Continue;
              if Builder = nil then
              begin
                Builder := TJavaClassBuilder.Create(C.Name, C.SuperName);
                Builder.JavaClass.Constants := C.Constants;
              end;
              var Target := Builder.Member(CanvasClass, Name, Descriptor);
              Method.Code[PC + 1] := Byte(Target shr 8);
              Method.Code[PC + 2] := Byte(Target);
            end;
        if Builder <> nil then
          C.Constants := Builder.JavaClass.Constants
        else if not (WidenConstructor or WidenCanvas) then
          Exit;
        VM.DefineClass(C);
        C := nil;
      finally
        Builder.Free;
      end;
    finally
      C.Free;
    end;
  end;

begin
  // These ports switched their game classes to Nokia FullCanvas but kept
  // Motorola owners on inherited Canvas calls. Point only virtual calls at
  // their common Canvas base, retaining dispatch and original bytecode PCs.
  if not (ResourceMatchesHash(Suite, FullCn + '.class',
    '5a49817b87b7b2f7f5ea2a12988322f0b2309e6dec36f4b8503b0b7720717884') or
    ResourceMatchesHash(Suite, FullCn + '.class',
      'af3c7d2de1a3c5049c3fdbadc4e294e0babd5d2a5f99b92f6735dbf698067cd2')) then
    Exit;
  FantasyCanvas :=
    ResourceMatchesHash(Suite, 'FantasyWarrior2_Evil.class', '40fb2b3f57d933ef9853e92c24c66997cb713b56e034bebd01e36b88c085ca95') and
    ResourceMatchesHash(Suite, FantasyMIDlet + '.class', FantasyMIDletHash) and
    ResourceMatchesHash(Suite, 'b.class', '33e64a82c826c517ef7eeaefe50713077170c0a7685e970cfc245e63de56b280');
  if not FantasyCanvas and not IsReviewedPort then
    Exit;
  RainbowConstructor :=
    ResourceMatchesHash(Suite, 'e.class', 'fcb0d5741b4bf40a885abc3a6a8e368ca32162b030f83a8f678cd3cea73aa942') and
    ResourceMatchesHash(Suite, 'f.class', '48c9af6224bc81aea22fd3cf180083dc528ac7dfbc0d44a1bfc7617afc8b083a');
  for var ClassName in Suite.ClassNames do
    if ClassName <> FullCn then
      InstallClass(ClassName);
end;

procedure InstallReviewedVirtualCalls(Suite: TJ2MESuite; VM: TJVM);
const
  OceansCallers: array[0..5] of record
  Name, Digest: string;
end = (
    (Name: 'a9'; Digest: '2863192d60b035fdfd7211d31a2ad1f4e965044c1d6e0c11177af7de2cba8b0d'),
    (Name: 'av'; Digest: '9af596123b8c286fa4780492305098d27b994dea1b1dbf7fef58d0bfb4cf1be2'),
    (Name: 'b2'; Digest: '4252c747623ed691d343918ce4e33dabf5e6b69fad4e9d028f6ebc44993d9728'),
    (Name: 'bk'; Digest: '26ffa7dddd17f2380a22518db0165e0025516fcfcf5c43b4ff5a025a883aa0f5'),
    (Name: 'bp'; Digest: '2cac52ed2936243784c62a90de4814d15c8fb2e7c2571e5735e6b7ae3356893b'),
    (Name: 'd'; Digest: '16b4c95059d023231b4c41c52a4a4c8959601eb23a4d90af15bd42c31bc4e9dc'));

  procedure Patch(const Caller, Digest, Name, Descriptor: string; PC: Integer);
  begin
    if not ResourceMatchesHash(Suite, Caller + '.class', Digest) then
      Exit;
    var C := TJVMClass.Parse(Suite.ReadResource(Caller + '.class'));
    try
      C.FindMethod(Name, Descriptor).Code[PC] := $B6;
      if Caller = 'bk' then
      begin
        // This engine also reads the selected actor's coordinates using
        // invokespecial through a bh field. Both accessors are public final.
        var Move := C.FindMethod('s', '(I)I');
        for var Offset in [19, 32, 44, 57] do
          Move.Code[Offset] := $B6;
      end;
      VM.DefineClass(C);
      C := nil;
    finally
      C.Free;
    end;
  end;

begin
  // These calls use invokespecial on a different instance. Their targets
  // are public final, so invokevirtual preserves dispatch and validates
  // the receiver against the actual owner.
  if ResourceMatchesHash(Suite, 'g.class',
    '2539ed14fb9b3c15f49f2b0cf6cfae6ffbb56d993147609528ba090f65f5bcce') then
    Patch('l', '3671554bacf1aa6d1ed995f921e0d4e31a4375c8e1f74db6c4f5cbab366bdfe8', 'ah', '()Z', 80);
  if ResourceMatchesHash(Suite, 'bh.class',
    '7ed6c37ea953ecf8c37f9cf8a053d014916b94b0994ccd441094094925d6c370') then
    for var Caller in OceansCallers do
      Patch(Caller.Name, Caller.Digest, 's', '(Lbh;)V', 1);
end;

procedure InstallPacedPolling(Suite: TJ2MESuite; VM: TJVM; const ClassName, Digest: string);
const
  ThreadClass = 'java/lang/Thread';
var
  C: TJVMClass;

  procedure PaceRead(const MethodName, MethodDescriptor, HelperName: string; const Sites: array of Integer; JoinWorker: Boolean = False; PollMillis: Integer = 8);
  var
    Owner, Name, Descriptor: string;
    Handler: TJVMExceptionHandler;
  begin
    var Caller := C.FindMethod(MethodName, MethodDescriptor);
    var First := Sites[0];
    var Opcode := Caller.Code[First];
    var Member := (Word(Caller.Code[First + 1]) shl 8) or Caller.Code[First + 2];
    C.MemberRef(Member, Owner, Name, Descriptor);
    var HelperDescriptor := Descriptor;
    if Opcode = $B2 then
      HelperDescriptor := '()' + Descriptor;
    var Locals: Word := 0;
    if Opcode in [$B4, $B6] then
    begin
      if Opcode = $B6 then
        HelperDescriptor := Copy(Descriptor, 3, MaxInt);
      HelperDescriptor := '(L' + Owner + ';)' + HelperDescriptor;
      Locals := 1;
    end;
    var Builder := TJavaClassBuilder.Create(C.Name, C.SuperName);
    try
      Builder.JavaClass.Constants := C.Constants;
      Builder.Start;
      Builder.Mark('wait');
      if JoinWorker then
      begin
        Builder.Emit([$2A]); // aload_0
        Builder.Ref($B6, Builder.Member(ThreadClass, 'join', '()V'));
      end
      else
      begin
        Builder.Ref($14, Builder.LongConstant(PollMillis)); // ldc2_w
        Builder.Ref($B8, Builder.Member(ThreadClass, 'sleep', '(J)V'));
      end;
      Builder.Mark('ready');
      Builder.Jump($A7, 'read');
      Builder.Mark('interrupt');
      Builder.Emit([$57]); // pop InterruptedException
      Builder.Ref($B8, Builder.Member(ThreadClass, 'currentThread', '()Ljava/lang/Thread;'));
      Builder.Ref($B6, Builder.Member(ThreadClass, 'interrupt', '()V'));
      Builder.Mark('read');
      if Opcode in [$B4, $B6] then
        Builder.Emit([$2A]);
      Builder.Ref(Opcode, Member);
      if HelperDescriptor.EndsWith('V') then
        Builder.Emit([$B1]) // return
      else if HelperDescriptor.EndsWith('J') then
        Builder.Emit([$AD]) // lreturn
      else
        Builder.Emit([$AC]); // ireturn, including boolean results
      Builder.Finish(HelperName, HelperDescriptor, JVM_ACC_PRIVATE or JVM_ACC_STATIC, 2, Locals);
      Handler.StartPC := Builder.Position('wait');
      Handler.EndPC := Builder.Position('ready');
      Handler.HandlerPC := Builder.Position('interrupt');
      Handler.CatchType := Builder.ClassRef('java/lang/InterruptedException');
      var Helper := Builder.JavaClass.Methods.Last;
      Helper.Handlers := [Handler];
      Helper.Owner := C;
      var Target := Builder.Member(C.Name, HelperName, HelperDescriptor);
      C.Constants := Builder.JavaClass.Constants;
      C.Methods.Add(Helper);
      Builder.JavaClass.Methods.Extract(Helper);
      // Keep each original instruction size and all save-state PCs intact.
      for var Site in Sites do
      begin
        Caller.Code[Site] := $B8;
        Caller.Code[Site + 1] := Byte(Target shr 8);
        Caller.Code[Site + 2] := Byte(Target);
      end;
    finally
      Builder.Free;
    end;
  end;

  procedure SetZeroIntervalFallback(DelayPC: Integer; const Name: string; Delay: Byte; const ExemptionField: string = '');
  const
    Descriptor = '()I';
  begin
    var Builder := TJavaClassBuilder.Create(C.Name, C.SuperName);
    try
      Builder.JavaClass.Constants := C.Constants;
      Builder.Start;
      var Run := C.FindMethod('run', '()V');
      var Interval := (Word(Run.Code[DelayPC + 1]) shl 8) or Run.Code[DelayPC + 2];
      Builder.Ref($B2, Interval);
      Builder.Emit([$59]); // dup
      Builder.Jump($9A, 'done'); // ifne
      if ExemptionField <> '' then
      begin
        Builder.Ref($B2, Builder.Member(C.Name, ExemptionField, 'Z', 9));
        Builder.Jump($9A, 'done'); // ifne
      end;
      Builder.Emit([$57, $10, Delay]); // pop; bipush fallback
      Builder.Mark('done');
      Builder.Emit([$AC]); // ireturn
      Builder.Finish(Name, Descriptor, JVM_ACC_PRIVATE or JVM_ACC_STATIC, 2, 0);
      var Helper := Builder.JavaClass.Methods.Last;
      Builder.JavaClass.Methods.Extract(Helper);
      Helper.Owner := C;
      C.Methods.Add(Helper);
      var Target := Builder.Member(C.Name, Name, Descriptor);
      C.Constants := Builder.JavaClass.Constants;
      Run.Code[DelayPC] := $B8;
      Run.Code[DelayPC + 1] := Byte(Target shr 8);
      Run.Code[DelayPC + 2] := Byte(Target);
    finally
      Builder.Free;
    end;
  end;

begin
  if not ResourceMatchesHash(Suite, ClassName + '.class', Digest) then
    Exit;
  C := TJVMClass.Parse(Suite.ReadResource(ClassName + '.class'));
  try
    if ClassName = 'bubble/GaMain' then
    begin
      // The foreground waits for a worker or for a screen's result.
      PaceRead('a', '(Lbubble/b;)I', '$joinScreenWorker', [24], True);
      PaceRead('a', '(Lbubble/a;)I', '$pollScreenResult', [4]);
    end
    else if ClassName = 'bubble/c' then
      // The gameplay thread polls the wall clock against its 16 ms target.
      PaceRead('run', '()V', '$pollFrameClock', [124], False, 1)
    else if ClassName = 'BalloonShooter/TitleScreen' then
      // The static title screen only yields while waiting for input.
      PaceRead('run', '()V', '$waitForTitleInput', [13])
    else if ClassName = 'Moorhuhn/k' then
      PaceRead('run', '()V', '$waitForTitleInput', [12])
    else if ClassName = 'j' then
    begin
      // RatZ waits for a 100 ms frame interval and separately polls its pause flag.
      PaceRead('run', '()V', '$waitForUnpause', [45]);
      PaceRead('run', '()V', '$waitForFrameInterval', [140], False, 1);
    end
    else if ClassName = 't' then // RatZ title screen worker, matched by hash.
      PaceRead('run', '()V', '$waitForTitleInput', [3])
    else if ClassName = 'a/RMGame' then
      PaceRead('run', '()V', '$paceFrame', [85], False, 4)
    else if ClassName = 'a/RRKernel' then
    begin
      // DrawMenu retains the Graphics passed to paint. Use the same mutable
      // image and explicit publication as the rest of this game's renderer.
      var Menu := C.FindMethod('DrawMenu', '()V');
      for var PC := 0 to High(Menu.Code) - 2 do
        if Menu.InstructionStarts[PC] and (Menu.Code[PC] = $B2) and
          (Menu.Code[PC + 1] = 0) and (Menu.Code[PC + 2] = 210) then
          Menu.Code[PC + 2] := 14; // g -> Exg
      SetLength(Menu.Code, Length(Menu.Code) - 1); // replace return
      Menu.Code := Menu.Code + [
          $B2, 0, 11, $03, $03, $B6, 0, 112, $B1]; // ExScreenImg.blitToScreen(0, 0)
      Menu.InstructionStarts := JVMInstructionMap(Menu.Code, Menu.MaxLocals);
      // This state sets the game's outer loop delay to zero.
      PaceRead('run', '()V', '$paceMenuDraw', [156, 174, 211, 235], False, 16);
      // Wait only on the clock poll after a frame has been simulated.
      PaceRead('d', '()V', '$waitForTrackFrame', [2537], False, 1);
      SetZeroIntervalFallback(304, '$idleDelay', 8, 'MenuShow');
    end
    else if ClassName = 'an' then
      // Mastering Magic's startup leaves v.b at zero. Later states supply
      // their own frame intervals, which still go through the original clock.
      SetZeroIntervalFallback(153, '$minimumIntroFrameInterval', 16)
    else if ClassName = 'a/RailRider' then
      // Keep checking inGame because it can clear before the worker exits.
      PaceRead('startApp', '()V', '$pollInGame', [36])
    else if ClassName = 'mib2/g' then
      // Wait in the yield-only loop without changing the intro's deadline.
      PaceRead('a', '(J)V', '$waitForIntroDeadline', [9], False, 1)
    else if ClassName = 'SnakeEvolution' then
      PaceRead('startApp', '()V', '$pollQuitFlag', [238])
    else
      PaceRead('startApp', '()V', '$pollGameState', [13, 38, 84, 167, 324, 533, 584, 628]);
    VM.DefineClass(C);
    C := nil;
  finally
    C.Free;
  end;
end;

procedure InstallWigglesRepaint(Suite: TJ2MESuite; VM: TJVM);
const
  CanvasClass = 'com/magmic/wiggles/I';
  WaitPC = 772;
  NotifyPC = 12;
begin
  if not ResourceMatchesHash(Suite, 'com/magmic/wiggles/Wiggles.class',
    '400e42a906aba177ca3f4def6379774b02b908be8aa8d2e5046666a83053ee88') or
    not ResourceMatchesHash(Suite, CanvasClass + '.class',
      'f842c6a2fd66cb6ef30af10543ef6c66cbdd718b0b662f6da87d31af2d951154') then
    Exit;
  var C := TJVMClass.Parse(Suite.ReadResource(CanvasClass + '.class'));
  try
    var Run := C.FindMethod('run', '()V');
    var Paint := C.FindMethod('paint', '(Ljavax/microedition/lcdui/Graphics;)V');
    // serviceRepaints already waits for paint to finish. The extra wait and
    // notify on an unlocked object are redundant; run retains its own timer.
    FillChar(Run.Code[WaitPC], 7, $00);
    FillChar(Paint.Code[NotifyPC], 7, $00);
    VM.DefineClass(C);
    C := nil;
  finally
    C.Free;
  end;
end;

procedure InstallWildWheelsCadence(Suite: TJ2MESuite; VM: TJVM);
const
  MIDlet = 'racegame/RaceMain';
  Game = 'racegame/c';
  TickPC = 12;
  HelperName = '$pacedTick';
  HelperDesc = '(L' + Game + ';)I';
begin
  if not ResourceMatchesHash(Suite, MIDlet + '.class',
    '9bbcb59e4952001362604343fe7ee93229830e17206de8b5d2e39aef630f2d7b') or
    not ResourceMatchesHash(Suite, Game + '.class',
      'edb8ff2907dfe7a94283a3a7ae41ce15a711975fcc7dcf46f3733824c3e68d66') then
    Exit;
  var C := TJVMClass.Parse(Suite.ReadResource(MIDlet + '.class'));
  try
    var Start := C.FindMethod('startApp', '()V');
    // The game converts ticks to milliseconds using 30 ms per tick. Its
    // tight startApp loop otherwise exhausts the 5,000-tick replay buffer.
    var B := TJavaClassBuilder.Create(C.Name, C.SuperName);
    try
      B.JavaClass.Constants := C.Constants;
      B.Start;
      B.Ref($14, B.LongConstant(30)); // ldc2_w
      B.Ref($B8, B.Member('java/lang/Thread', 'sleep', '(J)V'));
      B.Emit([$2A]); // aload_0
      B.Ref($B6, B.Member(Game, 'char', '()I'));
      B.Emit([$AC]); // ireturn
      B.Finish(HelperName, HelperDesc, JVM_ACC_PRIVATE or JVM_ACC_STATIC, 2, 1);
      var Helper := B.JavaClass.Methods.Last;
      Helper.Owner := C;
      var Target := B.Member(C.Name, HelperName, HelperDesc);
      C.Constants := B.JavaClass.Constants;
      C.Methods.Add(Helper);
      B.JavaClass.Methods.Extract(Helper);
      Start.Code[TickPC] := $B8;
      Start.Code[TickPC + 1] := Byte(Target shr 8);
      Start.Code[TickPC + 2] := Byte(Target);
    finally
      B.Free;
    end;
    VM.DefineClass(C);
    C := nil;
  finally
    C.Free;
  end;
end;

procedure InstallWildWheelsRecordingLimit(Suite: TJ2MESuite; VM: TJVM);
const
  CanvasClass = 'racegame/c';
  ReplayClass = 'racegame/h';
  RecordingDesc = '(III)V';
  HelperName = '$appendReplaySample';
  HelperDesc = '(L' + ReplayClass + ';III)V';
begin
  if not ResourceMatchesHash(Suite, CanvasClass + '.class',
    'edb8ff2907dfe7a94283a3a7ae41ce15a711975fcc7dcf46f3733824c3e68d66') or
    not ResourceMatchesHash(Suite, ReplayClass + '.class',
      'fd1a37767f55ff9db697d6787316014934ea19d030b0bff141079bf8bce5e5e9') then
    Exit;
  var C := TJVMClass.Parse(Suite.ReadResource(CanvasClass + '.class'));
  try
    var B := TJavaClassBuilder.Create(C.Name, C.SuperName);
    try
      B.JavaClass.Constants := C.Constants;
      B.Start;
      // Each update appends three bytes. The bundled ghost is read through
      // a separate object, and the score file stores only lap times.
      B.Emit([$2A]);
      B.Ref($B4, B.Member(ReplayClass, 'e', 'I', 9));
      B.Emit([$2A]);
      B.Ref($B4, B.Member(ReplayClass, 'try', '[B', 9));
      B.Emit([$BE, $06, $64]); // arraylength; iconst_3; isub
      B.Jump($A3, 'full'); // if_icmpgt
      B.Emit([$2A, $1B, $1C, $1D]);
      B.Ref($B6, B.Member(ReplayClass, 'if', RecordingDesc));
      B.Mark('full');
      B.Emit([$B1]);
      B.Finish(HelperName, HelperDesc, JVM_ACC_PRIVATE or JVM_ACC_STATIC, 4, 4);
      var Helper := B.JavaClass.Methods.Last;
      Helper.Owner := C;
      var Target := B.Member(C.Name, HelperName, HelperDesc);
      C.Constants := B.JavaClass.Constants;
      C.Methods.Add(Helper);
      B.JavaClass.Methods.Extract(Helper);
      var Preview := C.FindMethod('goto', '()I');
      var Race := C.FindMethod('long', '()I');
      Preview.Code[165] := $B8;
      Preview.Code[166] := Byte(Target shr 8);
      Preview.Code[167] := Byte(Target);
      Race.Code[147] := $B8;
      Race.Code[148] := Byte(Target shr 8);
      Race.Code[149] := Byte(Target);
    finally
      B.Free;
    end;
    VM.DefineClass(C);
    C := nil;
  finally
    C.Free;
  end;
end;

procedure InstallParachutePanicStartup(Suite: TJ2MESuite; VM: TJVM);
const
  MIDlet = 'MainEngine';
  AssignState = '$assignInitialState';
  StateDesc = '(LMainEngine;)V';
  AssignMenu = '$assignMenu';
  MenuDesc = '(Lc;)V';
begin
  if not ResourceMatchesHash(Suite, MIDlet + '.class',
    '04f5715239d32194896056d082d0caf3f581ad897f8de4fcf7794caa3c9eb3eb') or
    not ResourceMatchesHash(Suite, 'Engine.class',
      '13721d2dddfa199b1d411d8d83594014dad7d335685267cdab859fd3331c386a') then
    Exit;
  var C := TJVMClass.Parse(Suite.ReadResource(MIDlet + '.class'));
  try
    var Init := C.FindMethod('<init>', '()V');
    var B := TJavaClassBuilder.Create(C.Name, C.SuperName);
    try
      B.JavaClass.Constants := C.Constants;
      // Expose the initialized MIDlet to UI callbacks before constructing
      // the canvas. Retain the original instance field initialization.
      B.Start;
      B.Emit([$2A]);
      B.Ref($B3, B.Member('Engine', 'a', 'LMainEngine;', 9));
      B.Emit([$2A]);
      B.Ref($13, B.IntConstant(-793766371));
      B.Ref($B5, B.Member(MIDlet, 'd', 'I', 9));
      B.Emit([$B1]);
      B.Finish(AssignState, StateDesc, JVM_ACC_PRIVATE or JVM_ACC_STATIC, 2, 1);
      var InitialState := B.Member(MIDlet, AssignState, StateDesc);
      Init.Code[5] := $B8;
      Init.Code[6] := Byte(InitialState shr 8);
      Init.Code[7] := Byte(InitialState);
      FillChar(Init.Code[8], 2, $00);

      // Apply the font's line height after the menu is constructed.
      B.Start;
      B.Emit([$2A]);
      B.Ref($B3, B.Member('Engine', 'a', 'Lc;', 9));
      B.Emit([$2A]);
      B.Ref($B4, B.Member('c', 'a', 'Lab;', 9));
      B.Emit([$59]);
      B.Jump($C6, 'dropMenu');
      B.Ref($B2, B.Member('Engine', 'a', 'Lv;', 9));
      B.Emit([$59]);
      B.Jump($C6, 'dropFont');
      B.Ref($B6, B.Member('v', 'a', '()I'));
      B.Ref($B5, B.Member('ab', 'D', 'I', 9));
      B.Emit([$B1]);
      B.Mark('dropFont');
      B.Emit([$57]);
      B.Mark('dropMenu');
      B.Emit([$57, $B1]);
      B.Finish(AssignMenu, MenuDesc, JVM_ACC_PRIVATE or JVM_ACC_STATIC, 3, 1);
      var Menu := B.Member(MIDlet, AssignMenu, MenuDesc);
      FillChar(Init.Code[125], 15, $00);
      Init.Code[165] := $B8;
      Init.Code[166] := Byte(Menu shr 8);
      Init.Code[167] := Byte(Menu);
      C.Constants := B.JavaClass.Constants;
      while B.JavaClass.Methods.Count > 0 do
      begin
        var Helper := B.JavaClass.Methods.Last;
        Helper.Owner := C;
        C.Methods.Add(Helper);
        B.JavaClass.Methods.Extract(Helper);
      end;
    finally
      B.Free;
    end;
    VM.DefineClass(C);
    C := nil;
  finally
    C.Free;
  end;
end;

procedure InstallGomokuMonitorWait(Suite: TJ2MESuite; VM: TJVM);
const
  Worker = 'gomoku/d';
  WaitReceiverPC = 14;
begin
  if not ResourceMatchesHash(Suite, 'gomoku/GomokuMain.class',
    'ec63803357b91d4953243c83e139a24bebc81acda84b6d16fd3650a437fc161d') or
    not ResourceMatchesHash(Suite, Worker + '.class',
      '92eb553bfdb9dbf6d9a3f4a0235af226e60110fa57d1cf94aba193bf3d6be02e') then
    Exit;
  var C := TJVMClass.Parse(Suite.ReadResource(Worker + '.class'));
  try
    var Run := C.FindMethod('run', '()V');
    // Local 1 is the exact object held by monitorenter/monitorexit.
    // The worker previously called wait on this instead of that object.
    Run.Code[WaitReceiverPC] := $2B; // aload_1
    VM.DefineClass(C);
    C := nil;
  finally
    C.Free;
  end;
end;

procedure InstallJangbiStartup(Suite: TJ2MESuite; VM: TJVM);
const
  CanvasClass = 'JangbiCanvas';
  StartPC = 1469;
begin
  if not ResourceMatchesHash(Suite, 'Jangbi.class',
    'a8318c0cb2ce04c3e185033c653fc323adf7fe105a0e52cb8201788337c5aebe') or
    not ResourceMatchesHash(Suite, CanvasClass + '.class',
      '9158a457cb190860157d579bd319045d097b68f9760b8254b14d78791161b3ed') then
    Exit;
  var C := TJVMClass.Parse(Suite.ReadResource(CanvasClass + '.class'));
  try
    var Init := C.FindMethod('<init>', '(LJangbi;)V');
    // startApp initializes Display and starts the callSerially loop. Remove
    // the redundant constructor thread, which can run before that setup.
    FillChar(Init.Code[StartPC], 7, $00); // aload_0; getfield thread; invokevirtual start
    VM.DefineClass(C);
    C := nil;
  finally
    C.Free;
  end;
end;

procedure InstallChickenRaceSilentSound(Suite: TJ2MESuite; VM: TJVM);
const
  GuestClass = 'racer3d/s';
  SoundClass = 'com/nokia/mid/sound/Sound';
begin
  if not ResourceMatchesHash(Suite, GuestClass + '.class',
    '93d8877f7dfc9b7300b37957ba3ee5a7657f6edd82b3d37319ca77c6c2900c5f') then
    Exit;
  var C := TJVMClass.Parse(Suite.ReadResource(GuestClass + '.class'));
  try
    var Init := C.FindMethod('<clinit>', '()V');
    var B := TJavaClassBuilder.Create(C.Name, C.SuperName);
    try
      // This static fallback is deliberately empty. Construct a silent
      // one-millisecond tone, preserving instruction positions and the
      // normal format checks of the byte-array constructor.
      B.JavaClass.Constants := C.Constants;
      var Target := B.Member(SoundClass, '<init>', '(IJ)V');
      C.Constants := B.JavaClass.Constants;
      Init.Code[9] := $03;  // iconst_0: frequency
      Init.Code[10] := $0A; // lconst_1: duration
      Init.Code[11] := $00;
      Init.Code[12] := $00;
      Init.Code[14] := Byte(Target shr 8);
      Init.Code[15] := Byte(Target);
      Init.MaxStack := Max(5, Init.MaxStack);
      Init.InstructionStarts := JVMInstructionMap(Init.Code, Init.MaxLocals);
    finally
      B.Free;
    end;
    VM.DefineClass(C);
    C := nil;
  finally
    C.Free;
  end;
end;

procedure InstallResidentEvilPlayerGuard(Suite: TJ2MESuite; VM: TJVM);
const
  GuestClass = 'g';
  PlayerClass = 'javax/microedition/media/Player';
  Helper = '$loadedPlayerState';
  StateDesc = '()I';
  ReadPlayerStatePC = 168;
begin
  if not ResourceMatchesHash(Suite, GuestClass + '.class',
    '3988df95eb91c27d8aa3c5489ab2f1eed00fa664c80b586222fea4392b918067') then
    Exit;
  var C := TJVMClass.Parse(Suite.ReadResource(GuestClass + '.class'));
  try
    var Play := C.FindMethod('c', '(IZ)V');
    var B := TJavaClassBuilder.Create(C.Name, C.SuperName);
    try
      // The clip loader catches media errors and can leave the player nil.
      // Keep the original branch that returns when the player is not realized.
      B.JavaClass.Constants := C.Constants;
      B.Start;
      B.Ref($B2, B.Member(GuestClass, 'a', 'L' + PlayerClass + ';', 9));
      B.Emit([$59]); // dup
      B.Jump($C6, 'missing');
      B.Ref($B9, B.Member(PlayerClass, 'getState', StateDesc, 11));
      B.Emit([$01, $00, $AC]); // one receiver, ireturn
      B.Mark('missing');
      B.Emit([$57, $03, $AC]); // pop, iconst_0, ireturn
      B.Finish(Helper, StateDesc, JVM_ACC_PRIVATE or JVM_ACC_STATIC, 2, 0);
      var Method := B.JavaClass.Methods.Extract(B.JavaClass.Methods.Last);
      Method.Owner := C;
      C.Methods.Add(Method);
      var Target := B.Member(GuestClass, Helper, StateDesc);
      C.Constants := B.JavaClass.Constants;
      Play.Code[ReadPlayerStatePC] := $B8;
      Play.Code[ReadPlayerStatePC + 1] := Byte(Target shr 8);
      Play.Code[ReadPlayerStatePC + 2] := Byte(Target);
      FillChar(Play.Code[ReadPlayerStatePC + 3], 5, $00);
      Play.InstructionStarts := JVMInstructionMap(Play.Code, Play.MaxLocals);
    finally
      B.Free;
    end;
    VM.DefineClass(C);
    C := nil;
  finally
    C.Free;
  end;
end;

const
  RTLRacerMenuClass = 'rs_racer/b';

function IsRTLRacerSiemens(Suite: TJ2MESuite): Boolean;
begin
  Result := (Suite <> nil) and ResourceMatchesHash(Suite, RTLRacerMenuClass + '.class',
    '6f1c525a15dbae58d108a5e91658b75d99f89d10cb86eedcd155b405c5be0a37') and
    ResourceMatchesHash(Suite, 'rs_racer/f.class',
      '1723d26f913eea61c5b41e7a2873cfb86c137fc04c39d69caff36bddf3db83ec');
end;

const
  RTLRacerBitmapClass = 'rs_racer/f';
  RTLRacerGlyphLookup = '$menuGlyph';
  RTLRacerGlyphDescriptor = '(I)I';
  RTLRacerSpaceFrame = 29;

procedure InstallRTLRacerGlyphLookup(Suite: TJ2MESuite; VM: TJVM);
const
  UppercaseUmlauts: array[0..2] of Byte = ($C4, $D6, $DC);
begin
  var C := TJVMClass.Parse(Suite.ReadResource(RTLRacerBitmapClass + '.class'));
  try
    var B := TJavaClassBuilder.Create(C.Name, C.SuperName);
    try
      B.JavaClass.Constants := C.Constants;
      // Map uppercase Latin-1 to the original atlas. Other characters use
      // the existing space index instead of an out-of-range frame.
      B.Start;
      B.Emit([$1A, $10, Ord('A'), $64]); // letter - 'A'
      B.Emit([$59]);
      B.Jump($9B, 'other'); // iflt
      B.Emit([$59, $10, 25]);
      B.Jump($A3, 'other'); // if_icmpgt
      B.Emit([$AC]);
      B.Mark('other');
      B.Emit([$57]);
      for var I := 0 to 2 do
      begin
        // Byte values of uppercase A-diaeresis, O-diaeresis, U-diaeresis.
        var Next := IntToStr(I);
        B.Emit([$1A, $10, UppercaseUmlauts[I]]);
        B.Jump($A0, Next); // if_icmpne
        B.Emit([$10, Byte(26 + I), $AC]);
        B.Mark(Next);
      end;
      B.Emit([$10, RTLRacerSpaceFrame, $AC]);
      B.Finish(RTLRacerGlyphLookup, RTLRacerGlyphDescriptor, JVM_ACC_STATIC, 3, 1);
      var Glyph := B.Member(C.Name, RTLRacerGlyphLookup, RTLRacerGlyphDescriptor);

      // The per-letter bitmap path already returns a zero-filled bitmap for
      // blanks. Route its fallback through the same lookup as the menu.
      var Letter := C.FindMethod('a', '(Ljava/lang/String;Z)[B');
      Letter.Code[91] := RTLRacerSpaceFrame;
      Letter.Code[124] := $B8;
      Letter.Code[125] := Byte(Glyph shr 8);
      Letter.Code[126] := Byte(Glyph);
      Letter.Code[133] := RTLRacerSpaceFrame;
      Letter.InstructionStarts := JVMInstructionMap(Letter.Code, Letter.MaxLocals);
      C.Constants := B.JavaClass.Constants;
      var Helper := B.JavaClass.Methods.Extract(B.JavaClass.Methods.Last);
      Helper.Owner := C;
      C.Methods.Add(Helper);
    finally
      B.Free;
    end;
    VM.DefineClass(C);
    C := nil;
  finally
    C.Free;
  end;
end;

procedure InstallRTLRacerMenu(Suite: TJ2MESuite; VM: TJVM);
const
  ByteArrayGetter = '()[B';
begin
  if not IsRTLRacerSiemens(Suite) then
    Exit;
  InstallRTLRacerGlyphLookup(Suite, VM);
  var C := TJVMClass.Parse(Suite.ReadResource(RTLRacerMenuClass + '.class'));
  try
    var B := TJavaClassBuilder.Create(C.Name, C.SuperName);
    try
      B.JavaClass.Constants := C.Constants;

      var Glyph := B.Member(RTLRacerBitmapClass, RTLRacerGlyphLookup, RTLRacerGlyphDescriptor);
      var SingleLine := C.FindMethod('a', '(Ljava/lang/String;)V');
      var MultipleLines := C.FindMethod('a', '([Ljava/lang/String;)V');
      // Replace the three-byte 'bipush A; isub' at each call site.
      SingleLine.Code[45] := $B8;
      SingleLine.Code[46] := Byte(Glyph shr 8);
      SingleLine.Code[47] := Byte(Glyph);
      MultipleLines.Code[72] := $B8;
      MultipleLines.Code[73] := Byte(Glyph shr 8);
      MultipleLines.Code[74] := Byte(Glyph);
      SingleLine.InstructionStarts := JVMInstructionMap(SingleLine.Code, SingleLine.MaxLocals);
      MultipleLines.InstructionStarts := JVMInstructionMap(MultipleLines.Code, MultipleLines.MaxLocals);

      var Init := C.FindMethod('<init>', '(Lrs_racer/n;)V');
      // The font has 29 frames, each seven 1bpp bytes. The game reserves
      // index 29 for spaces. Append a blank bitmap and transparent mask,
      // then increase the frame count of both menu sprite constructors.
      for var Getter in ['r', 'a'] do
      begin
        var HelperName := '$menuFont' + Getter;
        B.Start;
        B.Ref($B8, B.Member(RTLRacerBitmapClass, Getter, ByteArrayGetter));
        B.Emit([$4B, $2A, $BE, $10, 7, $60, $BC, 8, $4C]); // new byte[source.length + 7]
        B.Emit([$2A, $03, $2B, $03, $2A, $BE]);
        B.Ref($B8, B.Member('java/lang/System', 'arraycopy', '(Ljava/lang/Object;ILjava/lang/Object;II)V'));
        B.Emit([$2B, $B0]);
        B.Finish(HelperName, ByteArrayGetter, JVM_ACC_PRIVATE or JVM_ACC_STATIC, 5, 2);
        var Target := B.Member(C.Name, HelperName, ByteArrayGetter);
        if Getter = 'r' then
        begin
          Init.Code[205] := Byte(Target shr 8);
          Init.Code[206] := Byte(Target);
          Init.Code[235] := Byte(Target shr 8);
          Init.Code[236] := Byte(Target);
        end
        else
        begin
          Init.Code[213] := Byte(Target shr 8);
          Init.Code[214] := Byte(Target);
        end;
      end;
      Init.Code[217] := RTLRacerSpaceFrame + 1;
      Init.Code[245] := RTLRacerSpaceFrame + 1;
      C.Constants := B.JavaClass.Constants;
      while B.JavaClass.Methods.Count > 0 do
      begin
        var Helper := B.JavaClass.Methods.Extract(B.JavaClass.Methods[0]);
        Helper.Owner := C;
        C.Methods.Add(Helper);
      end;
    finally
      B.Free;
    end;
    VM.DefineClass(C);
    C := nil;
  finally
    C.Free;
  end;
end;

procedure InstallRTLRacerTrack(Suite: TJ2MESuite; VM: TJVM);
const
  TrackClass = 'rs_racer/k.class';
begin
  if not IsRTLRacerSiemens(Suite) or not ResourceMatchesHash(Suite, TrackClass,
      '9640586f003271de80ef33d35bf4e37a68cf59df99aacb6bafc1254cc412a19d') then
    Exit;
  var C := TJVMClass.Parse(Suite.ReadResource(TrackClass));
  try
    var Init := C.FindMethod('<init>', '(BBBBLrs_racer/n;)V');
    // Both sprites receive a complete 32-byte strip copied to index zero.
    // Clear the stale source offset in the reserved Sprite constructor arg.
    for var OffsetPC in [458, 489] do
    begin
      FillChar(Init.Code[OffsetPC], 5, $00);
      Init.Code[OffsetPC] := $03; // iconst_0
    end;
    Init.InstructionStarts := JVMInstructionMap(Init.Code, Init.MaxLocals);
    VM.DefineClass(C);
    C := nil;
  finally
    C.Free;
  end;
end;

procedure InstallWormsFortsMinimapGuard(Suite: TJ2MESuite; VM: TJVM);
const
  MinimapResource = 'worms/e.class';
  ClearPC = 18;
  TerrainField = 30; // worms/e.a:Lworms/e;
begin
  if not ResourceMatchesHash(Suite, MinimapResource,
    'fd1b1db6a7a72d12183cc422ab926a2e5f59727358d86c495bb690903ca9ba35') or
    not ResourceMatchesHash(Suite, 'worms/WormsForts3D.class',
      '7fbda619888c2e4c2156fc944d9df9ab0634ecc0f57f61a318c1c82c8c5f5472') then
    Exit;
  var C := TJVMClass.Parse(Suite.ReadResource(MinimapResource));
  try
    var Paint := C.FindMethod('a', '()V');
    var GuardPC := Length(Paint.Code);
    var Clear := Copy(Paint.Code, ClearPC, 3);
    // Menu startup configures the minimap before a match provides terrain.
    // Clear the buffer in either case and draw the terrain once it exists.
    var DrawOffset := (ClearPC + Length(Clear)) - (GuardPC + Length(Clear) + 6);
    Paint.Code := Paint.Code + Clear + [
        $B2, 0, TerrainField, // getstatic
        $C6, 0, 6, // ifnull return
        $A7, Byte(DrawOffset shr 8), Byte(DrawOffset), // goto original terrain loop
        $B1];
    var GuardOffset := GuardPC - ClearPC;
    Paint.Code[ClearPC] := $A7;
    Paint.Code[ClearPC + 1] := Byte(GuardOffset shr 8);
    Paint.Code[ClearPC + 2] := Byte(GuardOffset);
    Paint.InstructionStarts := JVMInstructionMap(Paint.Code, Paint.MaxLocals);
    VM.DefineClass(C);
    C := nil;
  finally
    C.Free;
  end;
end;

procedure InstallWorms2LoadingYield(Suite: TJ2MESuite; VM: TJVM);
const
  CanvasResource = 'm.class';
  YieldName = '$yieldLoadingStep';
  YieldDescriptor = '(Lm;)V';
  LoaderWaitPC = 254;
begin
  if not ResourceMatchesHash(Suite, CanvasResource,
    'abfb4dc6b0d131e2fb50c57e0a7f061388164e705da31ad1182d170782af065a') or
    not ResourceMatchesHash(Suite, 'Worms/Worms.class',
      'f9addabaafad77a2586ce05a83b03311891fab27f1b1990158efae88bedfdde5') then
    Exit;

  var C := TJVMClass.Parse(Suite.ReadResource(CanvasResource));
  try
    var B := TJavaClassBuilder.Create(C.Name, C.SuperName);
    try
      B.JavaClass.Constants := C.Constants;
      B.Start;
      B.Ref($B8, B.Member('java/lang/Thread', 'yield', '()V'));
      B.Emit([$B1]);
      B.Finish(YieldName, YieldDescriptor, JVM_ACC_STATIC or JVM_ACC_PRIVATE, 1, 1);
      var YieldCall := B.Member(C.Name, YieldName, YieldDescriptor);
      var Loader := C.FindMethod('h', '()V');
      // Retain one scheduling point per asset step. The two explicit GCs
      // and 500 ms sleep are unnecessary here. Keep the other call in
      // hideNotify and preserve the original stack effect and snapshot PCs.
      Loader.Code[LoaderWaitPC] := $B8;
      Loader.Code[LoaderWaitPC + 1] := Byte(YieldCall shr 8);
      Loader.Code[LoaderWaitPC + 2] := Byte(YieldCall);
      C.Constants := B.JavaClass.Constants;
      var Helper := B.JavaClass.Methods.Extract(B.JavaClass.Methods.Last);
      Helper.Owner := C;
      C.Methods.Add(Helper);
    finally
      B.Free;
    end;
    VM.DefineClass(C);
    C := nil;
  finally
    C.Free;
  end;
end;

procedure InstallShrek2InputGuard(Suite: TJ2MESuite; VM: TJVM);
const
  CanvasClass = 'e.class';
  PressHelper = '$pressWhenReady';
  PressDescriptor = '(Ln;I)V';
  PressSwitchLowKey = -7;
  FirstPressTarget = 36;
  SelectKey = 53;
  FireKey = -5;
  ReleaseSwitchPC = 1;
  DefaultReleaseTarget = 4;
  FirstReleaseTarget = 16;
begin
  if not ResourceMatchesHash(Suite, CanvasClass,
    '7992155f532909b8d4d34fbc004554b5c381c4ae26ac2429ca8c9b27ea37604d') or
    not ResourceMatchesHash(Suite, 'n.class',
      '721ca62b17a5fb6b29e8aa31a2c3f0b11be06a77dfb97ade378b0ee4e162a404') then
    Exit;
  var C := TJVMClass.Parse(Suite.ReadResource(CanvasClass));
  try
    var B := TJavaClassBuilder.Create(C.Name, C.SuperName);
    try
      B.JavaClass.Constants := C.Constants;
      var Controller := B.Member(C.Name, 'b', 'Ln;', 9);
      var Actor := B.Member('n', 'C', 'Li;', 9);
      B.Start;
      B.Emit([$2A]);
      B.Jump($C6, 'done');
      B.Emit([$2A, $1B]);
      B.Ref($B6, B.Member('n', 'c', '(I)V'));
      B.Mark('done');
      B.Emit([$B1]);
      B.Finish(PressHelper, PressDescriptor, JVM_ACC_PRIVATE or JVM_ACC_STATIC, 2, 2);
      var Press := B.Member(C.Name, PressHelper, PressDescriptor);
      var Pressed := C.FindMethod('keyPressed', '(I)V');
      // Canvas is shown before the game thread constructs the controller.
      // Keep splash and softkey handling, guard only the gameplay calls.
      for var PC in [297, 309, 320, 331, 343, 354, 365] do
      begin
        Pressed.Code[PC] := $B8;
        Pressed.Code[PC + 1] := Byte(Press shr 8);
        Pressed.Code[PC + 2] := Byte(Press);
      end;

      // Nokia's negative FIRE key uses the same case as digit 5.
      Move(Pressed.Code[FirstPressTarget + (SelectKey - PressSwitchLowKey) * 4],
        Pressed.Code[FirstPressTarget + (FireKey - PressSwitchLowKey) * 4], 4);

      // Route both handled release cases through a readiness check. Append
      // branches to preserve the existing instruction positions for snapshots.
      var Released := C.FindMethod('keyReleased', '(I)V');
      var TargetPC := Length(Released.Code);
      var SelectReleasePC := TargetPC;
      for var OriginalPC in [116, 141] do
      begin
        var JumpBack := OriginalPC - (TargetPC + 17);
        Released.Code := Released.Code + [
            $2A, $B4, Byte(Controller shr 8), Byte(Controller),
            $C6, 0, 16, // return if controller is null
            $2A, $B4, Byte(Controller shr 8), Byte(Controller),
            $B4, Byte(Actor shr 8), Byte(Actor),
            $C6, 0, 6,  // return if actor is null
            $A7, Byte(JumpBack shr 8), Byte(JumpBack), $B1];
        var Offset := TargetPC - ReleaseSwitchPC;
        for var I := 0 to 12 do
        begin
          var Pos := FirstReleaseTarget + I * 8;
          if Released.Code[Pos + 3] = OriginalPC - ReleaseSwitchPC then
          begin
            Released.Code[Pos + 2] := Byte(Offset shr 8);
            Released.Code[Pos + 3] := Byte(Offset);
          end;
        end;
        TargetPC := Length(Released.Code);
      end;
      // The existing lookup has no negative FIRE entry. Test only that key
      // in its default branch and send it through the digit 5 release guard.
      var FireJump := SelectReleasePC - (TargetPC + 6);
      Released.Code := Released.Code + [
          $1B, $10, Byte(256 + FireKey),
          $A0, 0, 6, // if_icmpne: keep the default behavior
          $A7, Byte(FireJump shr 8), Byte(FireJump), $B1];
      var DefaultOffset := TargetPC - ReleaseSwitchPC;
      Released.Code[DefaultReleaseTarget + 2] := Byte(DefaultOffset shr 8);
      Released.Code[DefaultReleaseTarget + 3] := Byte(DefaultOffset);
      Released.InstructionStarts := JVMInstructionMap(Released.Code, Released.MaxLocals);
      C.Constants := B.JavaClass.Constants;
      var Helper := B.JavaClass.Methods.Extract(B.JavaClass.Methods.Last);
      Helper.Owner := C;
      C.Methods.Add(Helper);

      var RepaintPC := 1367;
      var Run := C.FindMethod('run', '()V');
      var RepaintRef := (Word(Run.Code[RepaintPC + 1]) shl 8) or Run.Code[RepaintPC + 2];
      var Mode := B.Member(C.Name, 'p', 'S', 9);
      B.Start;
      // Pause and menu have no timer. The loading state only needs pacing
      // once its ten load steps are complete. Gameplay has its own deadline.
      B.Ref($B2, Mode);
      B.Jump($99, 'wait'); // ifeq
      B.Ref($B2, Mode);
      B.Emit([$10, 8]); // bipush
      B.Jump($9F, 'wait'); // if_icmpeq
      B.Ref($B2, Mode);
      B.Emit([$04]); // iconst_1
      B.Jump($A0, 'paint'); // if_icmpne
      B.Emit([$2A]); // aload_0
      B.Ref($B4, B.Member(C.Name, 'o', 'S', 9));
      B.Emit([$10, 10]); // bipush
      B.Jump($A1, 'paint'); // if_icmplt
      B.Mark('wait');
      B.Ref($14, B.LongConstant(16)); // ldc2_w
      B.Ref($B8, B.Member('java/lang/Thread', 'sleep', '(J)V'));
      B.Mark('ready');
      B.Jump($A7, 'paint');
      B.Mark('interrupt');
      B.Emit([$57]); // pop
      B.Ref($B8, B.Member('java/lang/Thread', 'currentThread', '()Ljava/lang/Thread;'));
      B.Ref($B6, B.Member('java/lang/Thread', 'interrupt', '()V'));
      B.Mark('paint');
      B.Emit([$2A]); // aload_0
      B.Ref($B6, RepaintRef);
      B.Emit([$B1]); // return
      B.Finish('$repaintWithMenuDelay', '(Le;)V', JVM_ACC_PRIVATE or JVM_ACC_STATIC, 2, 1);
      var Repaint := B.JavaClass.Methods.Last;
      var Interrupted: TJVMExceptionHandler;
      Interrupted.StartPC := B.Position('wait');
      Interrupted.EndPC := B.Position('ready');
      Interrupted.HandlerPC := B.Position('interrupt');
      Interrupted.CatchType := B.ClassRef('java/lang/InterruptedException');
      Repaint.Handlers := [Interrupted];
      Repaint.Owner := C;
      C.Methods.Add(B.JavaClass.Methods.Extract(Repaint));
      var RepaintHelper := B.Member(C.Name, '$repaintWithMenuDelay', '(Le;)V');
      C.Constants := B.JavaClass.Constants;
      Run.Code[RepaintPC] := $B8;
      Run.Code[RepaintPC + 1] := Byte(RepaintHelper shr 8);
      Run.Code[RepaintPC + 2] := Byte(RepaintHelper);
    finally
      B.Free;
    end;
    VM.DefineClass(C);
    C := nil;
  finally
    C.Free;
  end;
end;

procedure InstallGuitarLegendStartup(Suite: TJ2MESuite; VM: TJVM);
const
  MIDletResource = 'GloftGILG.class';
  StartThreadPC = 21;
  StartThreadSize = 6;
  InitializationDonePC = 45;
  ResumePC = 49;
begin
  if not ResourceMatchesHash(Suite, MIDletResource,
    '5e95b1abbf64834fb7d9e2f719ccee43ddc25be589a1b1ba44d07b9072cc8c1b') or
    not ResourceMatchesHash(Suite, 'e.class',
      '27bb5d2162d2ca06dfdec613729f15dc6a1996834c6dfb749682e40a3ba7bee6') then
    Exit;
  var C := TJVMClass.Parse(Suite.ReadResource(MIDletResource));
  try
    var Start := C.FindMethod('startApp', '()V');
    var StartThread := Copy(Start.Code, StartThreadPC, StartThreadSize);
    var AppendPC := Length(Start.Code);
    // The game loop and startup share a static resource stream. Start the
    // loop only once the key map has been decoded and the stream closed.
    FillChar(Start.Code[StartThreadPC], StartThreadSize, 0);
    var Jump := AppendPC - InitializationDonePC;
    Start.Code[InitializationDonePC + 1] := Byte(Jump shr 8);
    Start.Code[InitializationDonePC + 2] := Byte(Jump);
    Jump := ResumePC - (AppendPC + StartThreadSize);
    Start.Code := Start.Code + StartThread + [$A7, Byte(Jump shr 8), Byte(Jump)];
    Start.InstructionStarts := JVMInstructionMap(Start.Code, Start.MaxLocals);
    VM.DefineClass(C);
    C := nil;
  finally
    C.Free;
  end;
end;

procedure InstallYetiSports2Gradient(Suite: TJ2MESuite; VM: TJVM);
const
  SplashResource = 'ys/pingu2/d.class';
  Graphics = 'javax/microedition/lcdui/Graphics';
  Helper = '$setGradientColor';
  HelperDescriptor = '(Ljavax/microedition/lcdui/Graphics;III)V';
  ColorPC = 88;
begin
  if not ResourceMatchesHash(Suite, SplashResource,
    '3b320d3d43905bd7d7e058f4c87b4bb23cadcb2936bb717ebe7d8eb4f9a2a0ea') or
    not ResourceMatchesHash(Suite, 'ys/pingu2/JMain.class',
      'cebed8098f8acaf0a324ee52e189ca4fa50397e46740dfdebe0cb3e233769778') then
    Exit;
  var C := TJVMClass.Parse(Suite.ReadResource(SplashResource));
  try
    var B := TJavaClassBuilder.Create(C.Name, C.SuperName);
    try
      B.JavaClass.Constants := C.Constants;
      B.Start;
      var MinRef := B.Member('java/lang/Math', 'min', '(II)I');
      // Green and blue grow on every scanline. Saturate them on taller displays.
      B.Emit([$2A, $1B, $1C, $11, 0, $FF]); // aload_0; iload_1; iload_2; sipush 255
      B.Ref($B8, MinRef);
      B.Emit([$1D, $11, 0, $FF]); // iload_3; sipush 255
      B.Ref($B8, MinRef);
      B.Ref($B6, B.Member(Graphics, 'setColor', '(III)V'));
      B.Emit([$B1]);
      B.Finish(Helper, HelperDescriptor, JVM_ACC_PRIVATE or JVM_ACC_STATIC, 5, 4);
      var Target := B.Member(C.Name, Helper, HelperDescriptor);
      var Paint := C.FindMethod('paint', '(Ljavax/microedition/lcdui/Graphics;)V');
      Paint.Code[ColorPC] := $B8;
      Paint.Code[ColorPC + 1] := Byte(Target shr 8);
      Paint.Code[ColorPC + 2] := Byte(Target);
      C.Constants := B.JavaClass.Constants;
      var Method := B.JavaClass.Methods.Extract(B.JavaClass.Methods.Last);
      Method.Owner := C;
      C.Methods.Add(Method);
    finally
      B.Free;
    end;
    VM.DefineClass(C);
    C := nil;
  finally
    C.Free;
  end;
end;

procedure InstallJacWorkerTarget(Suite: TJ2MESuite; VM: TJVM);
const
  MIDletResource = 'jac/jac.class';
  WorkerTargetPC = 127;
  WorkerTargetSize = 7;
begin
  if not ResourceMatchesHash(Suite, MIDletResource,
    '5dc550a4faea200fb8f331c746f01be0e134a99c1863e2b7d5c3bb033d38622a') then
    Exit;
  var C := TJVMClass.Parse(Suite.ReadResource(MIDletResource));
  try
    var Start := C.FindMethod('startApp', '()V');
    // run already operates on the static playfield. Give the thread the
    // running MIDlet instead of constructing a second one as its Runnable.
    FillChar(Start.Code[WorkerTargetPC], WorkerTargetSize, 0);
    Start.Code[WorkerTargetPC] := $2A; // aload_0
    Start.InstructionStarts := JVMInstructionMap(Start.Code, Start.MaxLocals);
    VM.DefineClass(C);
    C := nil;
  finally
    C.Free;
  end;
end;

procedure InstallNimStartupReturn(Suite: TJ2MESuite; VM: TJVM);
const
  NimClass = 'nim/Nim.class';
  LoopPC = 24;
begin
  if not ResourceMatchesHash(Suite, NimClass,
    '049bfab6f48884acbe982dff2ffc3bcd777731b20ddaaa0611efb4740af08d5f') then
    Exit;
  var C := TJVMClass.Parse(Suite.ReadResource(NimClass));
  try
    var Start := C.FindMethod('startApp', '()V');
    // The screen has been installed. Return control to MIDP instead of
    // remaining in the original goto-to-self while the menu handles input.
    Start.Code[LoopPC] := $B1; // return; the original branch operands are zero (nop)
    Start.InstructionStarts := JVMInstructionMap(Start.Code, Start.MaxLocals);
    VM.DefineClass(C);
    C := nil;
  finally
    C.Free;
  end;
end;

procedure InstallSimonInputGuard(Suite: TJ2MESuite; VM: TJVM);
const
  CanvasResource = 'bx.class';
  ControllerField = 43; // bm.j:Laq;
begin
  if not ResourceMatchesHash(Suite, CanvasResource,
    'b9f2f09865e400ad992fd12fc1b81fc3aa340d53fd6b98db53f8c726802aafa2') or
    not ResourceMatchesHash(Suite, 'bm.class',
      'fa94e47863a8bc49109925638cb5491f4d58586f9b24c8ff5a09e29625af9b91') then
    Exit;
  var C := TJVMClass.Parse(Suite.ReadResource(CanvasResource));
  try
    for var Name in ['keyPressed', 'keyReleased', 'keyRepeated'] do
    begin
      var Handler := C.FindMethod(Name, '(I)V');
      var GuardPC := Length(Handler.Code);
      // Canvas is displayed before the first controller is installed. Keep
      // the original offsets and leave the checked reference on the stack.
      var ContinueOffset := 3 - (GuardPC + 4);
      Handler.Code := Handler.Code + [
          $B2, 0, ControllerField, $59, // getstatic, dup
          $C7, Byte(ContinueOffset shr 8), Byte(ContinueOffset), // ifnonnull
          $57, $B1]; // pop, return
      Handler.Code[0] := $A7; // goto
      Handler.Code[1] := Byte(GuardPC shr 8);
      Handler.Code[2] := Byte(GuardPC);
      Handler.InstructionStarts := JVMInstructionMap(Handler.Code, Handler.MaxLocals);
    end;
    VM.DefineClass(C);
    C := nil;
  finally
    C.Free;
  end;
end;

procedure InstallSims2KeyFallback(Suite: TJ2MESuite; VM: TJVM);
const
  Canvas = 'javax/microedition/lcdui/Canvas';
  KeyMapClass = 'g.class';
  KeyMapDescriptor = '(Ljavax/microedition/lcdui/Canvas;I)I';
  HelperName = '$fallbackGameAction';
begin
  if not ResourceMatchesHash(Suite, KeyMapClass,
    'e803b4beb473f01b38cabba967c276e6021ae736f73de294dc530a2c7132c1bf') or
    not ResourceMatchesHash(Suite, 'e.class',
      '93a54d083a3d980a401473e75db43f244c20230f76f86eebf7a0bf9508852da6') then
    Exit;
  var C := TJVMClass.Parse(Suite.ReadResource(KeyMapClass));
  try
    var B := TJavaClassBuilder.Create(C.Name, C.SuperName);
    try
      B.JavaClass.Constants := C.Constants;
      B.Start;
      B.Emit([$2A]);
      B.Ref($C1, B.ClassRef('e'));
      B.Jump($99, 'otherCanvas');
      // The game Canvas calls this same lookup from getGameAction. An
      // unmapped key has the original sentinel value, avoiding recursion.
      B.Emit([$11, $03, $E7, $AC]); // sipush 999; ireturn
      B.Mark('otherCanvas');
      B.Emit([$2A, $1B]);
      B.Ref($B6, B.Member(Canvas, 'getGameAction', '(I)I'));
      B.Emit([$AC]);
      B.Finish(HelperName, KeyMapDescriptor, JVM_ACC_PRIVATE or JVM_ACC_STATIC, 2, 2);
      var Target := B.Member(C.Name, HelperName, KeyMapDescriptor);
      var KeyMap := C.FindMethod('a', KeyMapDescriptor);
      for var PC in [8, 390] do
      begin
        KeyMap.Code[PC] := $B8;
        KeyMap.Code[PC + 1] := Byte(Target shr 8);
        KeyMap.Code[PC + 2] := Byte(Target);
      end;
      C.Constants := B.JavaClass.Constants;
      var Helper := B.JavaClass.Methods.Extract(B.JavaClass.Methods.Last);
      Helper.Owner := C;
      C.Methods.Add(Helper);
    finally
      B.Free;
    end;
    VM.DefineClass(C);
    C := nil;
  finally
    C.Free;
  end;
end;

procedure InstallPopstarSplashLifetime(Suite: TJ2MESuite; VM: TJVM);
begin
  if not ResourceMatchesHash(Suite, 'Popstar.class', 'a085ef00bac05db41b3444f2f22b49090358d2332d97473223959c6f606d97a7') or
    not ResourceMatchesHash(Suite, 'e.class', 'b2c6ed4c7e9ccbb7a9ec153ccb4b47c73882177612e5d62523545d405d0e71bd') then
    Exit;
  var C := TJVMClass.Parse(Suite.ReadResource('Popstar.class'));
  try
    var RunMethod := C.FindMethod('run', '()V');
    // The splash can receive one more paint before setCurrent changes the
    // screen. Retain its small image set for the lifetime of the MIDlet.
    FillChar(RunMethod.Code[7], 7, $00); // aload_0; getfield e; invokevirtual e.b
    RunMethod.InstructionStarts := JVMInstructionMap(RunMethod.Code, RunMethod.MaxLocals);
    VM.DefineClass(C);
    C := nil;
  finally
    C.Free;
  end;
end;

procedure InstallFeanorImagePath(Suite: TJ2MESuite; VM: TJVM);
const
  Resource = 'SplitCanvas.class';
begin
  if not ResourceMatchesHash(Suite, Resource, '40dc31a4e87c76ae7e224007b6fd9e95691a4d74acad4bf9d88d10852f1118f5') or
    not ResourceMatchesHash(Suite, 'Feanor.class', 'dd228db83af092253c3819d54b91c815d9d3277fcdd001b0e2d34601803dbaa4') then
    Exit;
  var C := TJVMClass.Parse(Suite.ReadResource(Resource));
  try
    // This release builds its image paths with a Windows separator.
    // The corresponding JAR entries all use res/.
    for var I := 1 to High(C.Constants) do
      if (C.Constants[I].Tag = 1) and (C.Constants[I].Text = 'res\') then
        C.Constants[I].Text := 'res/';
    VM.DefineClass(C);
    C := nil;
  finally
    C.Free;
  end;
end;

procedure InstallFeanorGameLoopWait(Suite: TJ2MESuite; VM: TJVM);
const
  Resource = 'NHC.class';
  LoopStartPC = 14;
  LoopEndPC = 504;
  BranchPC = LoopEndPC + 5;
  LoopOffset = ( LoopStartPC - BranchPC) and $FFFF;
begin
  if not ResourceMatchesHash(Suite, Resource, '9e46273910f8ac2101db547bf66f846095545abfa8c4a3696d8372fc964e176e') or
    not ResourceMatchesHash(Suite, 'Feanor.class', 'dd228db83af092253c3819d54b91c815d9d3277fcdd001b0e2d34601803dbaa4') then
    Exit;
  var C := TJVMClass.Parse(Suite.ReadResource(Resource));
  try
    var GameLoop := C.FindMethod('gameThread', '()V');
    var SleepRefHigh := GameLoop.Code[5];
    var SleepRefLow := GameLoop.Code[6];
    // The receiver is always non-nil. Reuse the existing sleepFor helper
    // before returning to the state poll.
    SetLength(GameLoop.Code, LoopEndPC);
    GameLoop.Code := GameLoop.Code + [
        $2A, $08, $B6, SleepRefHigh, SleepRefLow,
        $A7, Byte(LoopOffset shr 8), Byte(LoopOffset and $FF)];
    GameLoop.InstructionStarts := JVMInstructionMap(GameLoop.Code, GameLoop.MaxLocals);
    VM.DefineClass(C);
    C := nil;
  finally
    C.Free;
  end;
end;

procedure InstallSkullCastleSoftkeys(Suite: TJ2MESuite; VM: TJVM);
const
  Path = 'Pinball/PinballCanvas.class';
  FirstCommandPC = 2239;
  AfterCommandsPC = 2260;
begin
  if not ResourceMatchesHash(Suite, Path, 'c03d554f82e93b7ddfaf6e758443e1c6cca94b4a2c1306c86513d65a4ab022db') then
    Exit;
  var C := TJVMClass.Parse(Suite.ReadResource(Path));
  try
    var Init := C.FindMethod('<init>', '()V');
    // The blank commands only translate softkeys into keyPressed calls.
    // FullCanvas receives those key codes directly.
    FillChar(Init.Code[FirstCommandPC], AfterCommandsPC - FirstCommandPC, $00);
    Init.InstructionStarts := JVMInstructionMap(Init.Code, Init.MaxLocals);
    VM.DefineClass(C);
    C := nil;
  finally
    C.Free;
  end;
end;

procedure InstallJ2MECompatibilityClasses(Suite: TJ2MESuite; VM: TJVM; out ArmiesOfWarClass: TJVMClass);
const
  RecordStore = 'javax/microedition/rms/RecordStore';
  CountPC = 8;
  GameAPIDemoWait: TScreenWorkerWait = (MethodName: 'Handle'; Descriptor: '(LGameAPI_Demo/MyScreen;Ljava/lang/String;)I'; PC: 25);
  BalloonShooterWait: TScreenWorkerWait = (MethodName: 'Handle'; Descriptor: '(LBalloonShooter/MyScreen;Ljava/lang/String;)I'; PC: 25);
  MoorhuhnTitleWait: TScreenWorkerWait = (MethodName: 'startApp'; Descriptor: '()V'; PC: 82);
  MoorhuhnScreenWait: TScreenWorkerWait = (MethodName: 'a'; Descriptor: '(LMoorhuhn/j;Ljava/lang/String;)I'; PC: 25);
  RatZWait: TScreenWorkerWait = (MethodName: 'p'; Descriptor: '(Le;)I'; PC: 48);
  RaymanGolfWait: TScreenWorkerWait = (MethodName: 'startApp'; Descriptor: '()V'; PC: 69);
  HelperName = '$countAndCloseCaptureStore';
  HelperDesc = '(Ljavax/microedition/rms/RecordStore;)I';
var
  Owner, Name, Desc: string;
begin
  ArmiesOfWarClass := nil;
  if Suite = nil then
    Exit;
  ArmiesOfWarClass := InstallArmiesOfWarClasses(Suite, VM);
  InstallStackAttack2Classes(Suite, VM);
  InstallSummerSkiFrameRate(Suite, VM);
  InstallGolfTourVolume(Suite, VM);
  InstallMarslanderIntro(Suite, VM);
  InstallBimmerScreenTimers(Suite, VM);
  InstallAbsoluteMinesweeper(Suite, VM);
  InstallBalloonzUndoGuard(Suite, VM);
  InstallGuitarHero5LocaleFallback(Suite, VM);
  InstallGuitarLegendStartup(Suite, VM);
  InstallCrashBandicootSoundListener(Suite, VM);
  InstallNinjaMasterLoadingPaint(Suite, VM);
  InstallScreenWorkerJoin(Suite, VM, 'GameAPI_Demo/GameAPI_Demo',
    '7c6686f61f88ae52f0bc1c829538f35722ead8215921619b0f92f001de36a685', [GameAPIDemoWait]);
  InstallScreenWorkerJoin(Suite, VM, 'BalloonShooter/BalloonShooter',
    '53f804d0dc59ff365fcc686fc5339c08ade5cbc9e79024454c32acd6ac33d8e0', [BalloonShooterWait]);
  InstallScreenWorkerJoin(Suite, VM, 'Moorhuhn/Moorhuhn',
    'be9504cc5585fbb560f0a5aa81c2bd6a5b4abad1e62f2d58a0f7fb74c2e1f292', [MoorhuhnTitleWait, MoorhuhnScreenWait]);
  InstallScreenWorkerJoin(Suite, VM, 'RatZ',
    'e16b04c7d82b6632894ce5f8d0c5085b0aa8f57458ccf9a20a7f340ef4ed9960', [RatZWait]);
  InstallScreenWorkerJoin(Suite, VM, 'a/Rayman',
    'f85947fdff9126bfea6f76d4ab60d699a2844c455f50b1e1d795fb963b9f4b01', [RaymanGolfWait]);
  InstallPacedPolling(Suite, VM, 'Moorhuhn/k',
    'fe89b0dbad56755649b6e3daccfe78579afec1f71228b1c3dc1bef89d587733c');
  InstallPacedPolling(Suite, VM, 't',
    'd4043be0e0113fec0e956454261d08c29809dc4f36440507843cef8f651d72be');
  InstallPacedPolling(Suite, VM, 'j',
    '3c0e43de4ed733b3c3105f83396f636e73d3e2f7a1dac7b38e459c367d12f99e');
  InstallPacedPolling(Suite, VM, 'a/RMGame',
    '91a35f7ad9154a32742e7a51c0c3f5710de8de717923880594485e3142cb6546');
  InstallPacedPolling(Suite, VM, 'BalloonShooter/TitleScreen',
    '50a443fbf84adbb147bb388f3623cfce590b7b362542d74ad8e9fa7db7e6722b');
  InstallIronMan3MediaTimeLookup(Suite, VM);
  InstallMotorolaFullCanvasCompatibility(Suite, VM);
  InstallReviewedVirtualCalls(Suite, VM);
  InstallPacedPolling(Suite, VM, 'blackjack/BlackJack',
    '3d92afe4ecc02081d62ed07dc57793c7a3673a262845f14306af07802f741ca9');
  InstallPacedPolling(Suite, VM, 'a/RRKernel', RailRiderKernelHash);
  if ResourceMatchesHash(Suite, 'v.class', '956a3981d55e61af85abe04f4f24ee00dcaacb7f5179440a05d23b501d52f7d4') then
    InstallPacedPolling(Suite, VM, 'an',
      'd99a593c87393d61f038d8f6ce606b987fc666f78200dfb4d7cecdf87e0bca25');
  InstallPacedPolling(Suite, VM, 'a/RailRider',
    '43eb0d03e7730e1da7f5f3294331949525afad2e8bc08501cbc725cf2dc32f5d');
  InstallPacedPolling(Suite, VM, 'mib2/g',
    '6468c90776f968c4767cddee7378da61332265f7f2608fe7c5b2027c90f35330');
  InstallPacedPolling(Suite, VM, 'SnakeEvolution',
    '805e1abcf96466b210f19e761bc584e9fe995018093cbc8f2afe9f8de481b0ce');
  InstallPacedPolling(Suite, VM, 'bubble/GaMain',
    '871be0c2b70103be23e71054976298a14351145d938c647b349b8262c3a7deab');
  InstallPacedPolling(Suite, VM, 'bubble/c',
    '61020b8c05e5de03a7f417c34dc5a289245294f7266d5ebbda0a37d9df9ac91e');
  InstallWigglesRepaint(Suite, VM);
  InstallJangbiStartup(Suite, VM);
  InstallGomokuMonitorWait(Suite, VM);
  InstallParachutePanicStartup(Suite, VM);
  InstallWildWheelsCadence(Suite, VM);
  InstallWildWheelsRecordingLimit(Suite, VM);
  InstallChickenRaceSilentSound(Suite, VM);
  InstallResidentEvilPlayerGuard(Suite, VM);
  InstallSkullCastleSoftkeys(Suite, VM);
  InstallFeanorImagePath(Suite, VM);
  InstallFeanorGameLoopWait(Suite, VM);
  InstallPopstarSplashLifetime(Suite, VM);
  InstallRTLRacerMenu(Suite, VM);
  InstallRTLRacerTrack(Suite, VM);
  InstallShrek2InputGuard(Suite, VM);
  InstallGravityDefiedInputGuard(Suite, VM);
  InstallEuromanSplashInputGuard(Suite, VM);
  InstallWorms2LoadingYield(Suite, VM);
  InstallWormsFortsMinimapGuard(Suite, VM);
  InstallSimonInputGuard(Suite, VM);
  InstallNimStartupReturn(Suite, VM);
  InstallJacWorkerTarget(Suite, VM);
  InstallYetiSports2Gradient(Suite, VM);
  InstallSims2KeyFallback(Suite, VM);
  if not ResourceMatchesHash(Suite, 'GloftMMN2.class', MiamiMIDletHash) or
    not ResourceMatchesHash(Suite, 'f.class', MiamiEngineHash) then
    Exit;

  var C := TJVMClass.Parse(Suite.ReadResource('f.class'));
  try
    var CountMethod := C.FindMethod('p', '()I');
    if (C.Name <> 'f') or (CountMethod = nil) or (Length(CountMethod.Code) < CountPC + 3) or
      (CountMethod.Code[CountPC] <> $B6) then
      Exit;
    C.MemberRef((Word(CountMethod.Code[CountPC + 1]) shl 8) or CountMethod.Code[CountPC + 2], Owner, Name, Desc);
    if (Owner <> RecordStore) or (Name <> 'getNumRecords') or (Desc <> '()I') then
      Exit;

    // The capture counter opens its own store handle and omits the close.
    // Use a guest finally block and keep the original instruction offsets.
    var B := TJavaClassBuilder.Create(C.Name, C.SuperName);
    try
      B.JavaClass.Constants := C.Constants;
      B.Start;
      B.Mark('count');
      B.Emit([$2A]);
      B.Ref($B6, B.Member(RecordStore, 'getNumRecords', '()I'));
      B.Emit([$3C]);
      B.Mark('close');
      B.Emit([$2A]);
      B.Ref($B6, B.Member(RecordStore, 'closeRecordStore', '()V'));
      B.Emit([$1B, $AC]);
      B.Mark('failed');
      B.Emit([$4C, $2A]);
      B.Ref($B6, B.Member(RecordStore, 'closeRecordStore', '()V'));
      B.Emit([$2B, $BF]);
      B.Finish(HelperName, HelperDesc, JVM_ACC_PRIVATE or JVM_ACC_STATIC, 1, 2);
      var Handler := Default(TJVMExceptionHandler);
      Handler.StartPC := B.Position('count');
      Handler.EndPC := B.Position('close');
      Handler.HandlerPC := B.Position('failed');
      var Helper := B.JavaClass.Methods.Last;
      Helper.Handlers := [Handler];
      Helper.Owner := C;
      var Target := B.Member(C.Name, HelperName, HelperDesc);
      C.Constants := B.JavaClass.Constants;
      C.Methods.Add(Helper);
      B.JavaClass.Methods.Extract(Helper);
      CountMethod.Code[CountPC] := $B8;
      CountMethod.Code[CountPC + 1] := Byte(Target shr 8);
      CountMethod.Code[CountPC + 2] := Byte(Target);
    finally
      B.Free;
    end;
    VM.DefineClass(C);
    C := nil;
  finally
    C.Free;
  end;
end;

function TryJ2MECompatibilityEncoding(Suite: TJ2MESuite; out Encoding: string): Boolean;
const
  Names: array[0..7] of string = ('Airburster/MainPRG.class', 'e.class',
    'lang01.txt', 'lang02.txt', 'lang03.txt', 'lang04.txt', 'lang05.txt', 'lang06.txt');
  Hashes: array[0..7] of string = (
    '0996cd18fa01c8bc0cff504cd82628f41ee71c04b3691c41aab2cd20585967cc',
    'aedda06e91d361a1cde8f4a9128a36ff8fafd70964fa5db23828f890a3eb210b',
    '35f91a5c3a67e0c325aca57b4e873d1b87f2335ccb5008c1543aa9ac4983b53e',
    'fcb932701873d31d79a6d79fd5cbabfe7ad9e15aa37aedb54f5ff1918e6495ef',
    'a2e573a158498f2cabf8d82f9eae48f880c877adb1ac94d55b48fc03787d3c77',
    'a40ec1d8327b2688a31802296da708739b58a5294743b0d78afe85f0c52953a9',
    'e480f215e1ec5e166e0c7016128aa0948dc21fe365baa95b1203402f45badda0',
    '72f8d9038a1394da2a5f8427ebe703b14dc8738ebea189f5ac0a375c0028f2a0');
begin
  Result := False;
  Encoding := '';
  if Suite = nil then
    Exit;
  // These ports pass decoded code units directly to 256-entry bitmap font
  // tables. Their reviewed font or language data uses one byte per glyph.
  if (ResourceMatchesHash(Suite, 'b.class', '6f3af8afcca93af102cc7943d9edb0a8b8a3149af52e29c09d3fa23d42671724') and
    ResourceMatchesHash(Suite, 'res-head.bin', 'c56086a64b7456dea754a8e73e537f82265cea8741fe05466963e6e745679af9')) or
    (ResourceMatchesHash(Suite, 'd.class', '927bfea8a55306c74c028c766351c1d84f6a48e0b1aed385f6a8aa2638482a0a') and
    ResourceMatchesHash(Suite, 'font_9x8.map', '582891d5d90f8beb302fc71818bf30ad77e45c320488ea028a802a20921f0e47')) or
    (ResourceMatchesHash(Suite, 'f.class', 'ed3e1bb70fc76f4223d4ecc79af39598e63247d4fb343fc66b4e1186f5710b5a') and
    ResourceMatchesHash(Suite, 'd2', 'c6784622c4e97ceae1df8fb29aa903b7d216b6c2190266c27aa055d0b38c267a')) then
  begin
    Encoding := 'ISO-8859-1';
    Exit(True);
  end;

  if IsRTLRacerSiemens(Suite) then
  begin
    Encoding := 'ISO-8859-1';
    Exit(True);
  end;

  // Airburster measures all language names with a Latin-1 bitmap font. Its
  // String(byte[],offset,length) calls rely on the phone's default encoding.
  // Match both consumers and every language resource; never guess from a name
  // or reinterpret malformed UTF-8 on a per-string basis.
  for var I := Low(Names) to High(Names) do
  begin
    if not Suite.HasResource(Names[I]) then
      Exit;
    var Data := Suite.ReadResource(Names[I]);
    var Hash := THashSHA2.Create;
    if Length(Data) > 0 then
      Hash.Update(Data[0], Length(Data));
    if not SameText(Hash.HashAsString, Hashes[I]) then
      Exit;
  end;
  Encoding := 'ISO-8859-1';
  Result := True;
end;

function J2MECompatibilityPlatform(Suite: TJ2MESuite): string;
begin
  // The color-only Jedi Dash release selects its resources on Nokia 7210.
  if (Suite <> nil) and
    ResourceMatchesHash(Suite, 'a/a/a/b/b.class', '00a045171a83baea95f582c27da06814f2d6c99e9df0c587df53837d40263947') and
    ResourceMatchesHash(Suite, 'res/colour/jedi.png', '30558568a9d0ba5b6f55b0fa2917eae0a9261fbf053aa4fb24a77fe6e54bb458') then
    Exit('Nokia7210');
  // This S40 City Bloxx release selects its Nokia device path from the
  // platform property and declares Nokia* in the bundled manifest.
  if (Suite <> nil) and
    ResourceMatchesHash(Suite, 'House.class', '029556e8b5c2236b2a11094ae3b7a4026df303c62368b80da713328fc85b7ab4') and
    ResourceMatchesHash(Suite, 'o.class', 'c2ec2deb2cca84740f669c60a97fbb5ba907dbc4bfb280b102da75328f6afb9f') then
    Exit('NokiaSeries40');
  Result := 'RetroMul';
end;

function J2MECompatibilityLocale(Suite: TJ2MESuite): string;
begin
  // Oil Rig only initializes its primary string table for a language code
  // in its exact-match list. This build ships only the English table.
  if (Suite <> nil) and
    ResourceMatchesHash(Suite, 'Oilrig.class', 'b2353712eef14284b2c264e4bdc3bfbb05f3f7308e3c8b339b44c45048e30e4d') and
    ResourceMatchesHash(Suite, 'c.class', '0201e582bdd0c30e3f9ee21c0007fe11f512c2e070ba63c6456fd5ce56792d8a') then
    Exit('en');
  Result := '';
end;

function J2MECompatibilityM3GUnusedTexBias(const ModelHash: string): Boolean;
const
  // Reviewed Golden Warrior / Bimmer / NFS Carbon / Planet Riders exports: only the unused
  // third bias component of two-component texture coordinates is normalized.
  // Planet Riders 1.3.2 hashes identify the decoded M3G bytes passed to Loader,
  // after its bo.a resource unscrambler (85 files, 83 distinct models).
  // Pearl Harbor Sky Conquerors uses the same exporter defect in 12 models.
  // Freeflight and Submarine3D have the same defect in five models.
  Hashes: array[0..133] of string = (
    '00033c6e9b1a43f3dc9211205d4120270213bb179928342a578ef0bb754bce20',
    '0143a0572a9e802fb09707f7b531508b3168f87fb30d9f759bbc2ee25d9d3a6b',
    '06110012a84d736ec2c354c0afabadd511780d9e265537986667733e72961c8b',
    '0700d0252b8a00dbf2ec78ef52959c26e05aca07f7d2673e6b3711b73e0b8632',
    '0cced26a0829cc08706f4be1bb54a230ff61946bdfabb0202814c512c908cc5b',
    '0f82a50aa19a92d027b080e0751d71630c7107b2b34bff22ad0cdeece624d8c6',
    '10451b1fde07158541b86f5783bcf8c52567caf09ec42caf19e0c64719926b01',
    '10dd033fd08afc7bd749066625cd27f4d46ee5ddb44f60fccd096d679a5537a7',
    '16b8a13f4c0b11cf55ffc20fc2757dc3c93c8b30b24471d8e6d1efb87c35b7b7',
    '189f2f69bd839964d7c5f51ffe38bedf61e89d04fa5a5e3e02a1fdf85ece3f81',
    '1bbc200deb6198db6f124bff580e563274a98f231c00147d8aa8b2874b476ff9',
    '213bad8936730358b5e82c3614092c12514be3ad7db399981f2e301b8e59fd0f',
    '21f5277edf8d9ef727cd763fe6f5c474c9553412f93a0a8795774fb42e113e14',
    '29a0dcab1abdf5b940c8878bf55ab7735f2265fcfb5d4a607a22fc077ab94f12',
    '2a120731facaff2ee5662bbf3b8679d1d3b68b6791d08438fbd75fbd4ee985a6',
    '2a94c17586bdcf55365c64d1828ded9ede7dac4f6223a43919ca2e6935f8ffb2',
    '2cb82b267e0a993a849c995b0b6e75fb3bb9d8ff64fbb8939bb0cf694cd5e3c8',
    '2da4fd03b46fe162805bfaf14ac1097414c6bbf4c40dcdef49303bd34c951baf',
    '2f2f4c292b5bf8e56dbc9b7b2a92c6e603e5e8a0dc4a7b4760739c6f34b9d151',
    '31b7859b3a42ba844ecd7675bf2c44c0ed9ce1908b2b129c939781ac01324e0e',
    '3637e5db3e9cd14af05b3fe0b25af112aa449df263a053f276d7d23220a5187f',
    '363a8376b9a30549dfa324ee4640cfbfb886fa66e81a41aab5ccce9ffaf55dda',
    '387586902b46b72dfcd54c08b240e4a100c65c6d7446da63e53aa056e1c6b431',
    '38f84a387472f09b469ab414236b58275e50b77341919be77cf1d6aebfedfcdf',
    '3938d8dfb70765db27fd8e43bdb343be81e8b4d84ed6beae892fd8608463851d',
    '3c281c478bf0eaffea22e81e6ded5939495f132ebfe405ed461979a11632e45b',
    '408e3c43e3da457f7c0881e97d0712930a37f1691821f65d5fb5d8bc4bab69b1',
    '4237ec4d812d5a4d18ef9f2bac3108f0d726c3fdee7ef923e2664a221aa70e30',
    '43d6a3959bf354a2a38f0286c53d2f4a8590b32f3c289b65712f4f16417ba55e',
    '463fb9d1125de526a2dd901fcc9dd018c665bdf5e0f3bdbbe3c2eebd99d9dc46',
    '471f07b45df2077023b9bf91c2850078e174c5e086423f626028a75dcd13896a',
    '491e40ca954ba10808d569b8ff6929bbf975a3eb1805c16e0d2a9cd59fcbb79e',
    '4be051e8df0dc2ff84a9d6f0390e409a34d75609fa58f9ae54cbbb814f2eebf0',
    '4c454cd8eeeae21ab48fa3cb8a28d9c060e0d514ec04c42cee2c609e71ac2b89',
    '4da16f5e7d32709418507d1b182a77aa786e9734e4aa800e3e373a4d9a1a060b',
    '4fcc449c06ffc6985245d1ba4c13a51f2b246d2bb69519ab7392a2407b3f7181',
    '51de71973d027a2872e923e095f11b40e3f54e46769dba5328aa098356bde667',
    '53a2457f67bdbf7260eb359771250ba3c039bc5cf1a6928cdaf80fc5a162a9b1',
    '5549033febcffbcc331d539992b4e11b59cf145c0f7ad56e9734efcbbad8c2d7',
    '556af7f2f29e999ac57c7b2c64956bd1ab7f8bd258c4ac80796b98d3bd8522e1',
    '5b6e781074d009dbce87a0e83913699fefc8f492ff2245eaf7a10468115f788c',
    '5dd8e44206b240c996d393538d8e64a9d222450a591bfa09c3219862e0c693bb',
    '5ddcc8ea7c82c259ba100fe3a4d73136adc022036a65a69e3fa38d6105bf3989',
    '62e843ca4f2c789f876eaec7efbf94f5190ab8af93c8b059826a1c49c281a5ee',
    '63a05d81affe74509d0455448ceac10fea029a623606f2aab31b656f8b165243',
    '68b0c0dcf272b5078afa2ae4c825794133225e2dfeeb8418426570311a4a609a',
    '6b2fbf406cbb1ae17cf73f7d55eed0174d03ea95bdf355f885a4bf36c32c7285',
    '6eb5a83a6225e6851cea8593ed4cb2c698974ec3ccc582079ac659b52c24a282',
    '72071f1ec2536578bf8521e7b41146ba29925cbf625e3a9ec9330fbd732aa6c8',
    '72f1e1ad8781a8c95df4fad3be1fe69b7739a036cd982916b3c8e5a7ae2c1735',
    '735730dfd9188b7c8cb4027cf8b54b81693c37f72123bc7eddb708d7952e53e7',
    '740bbacf74fcbe5eaa23c20057a489329f5c23733a166533e6784f0fc31107c8',
    '75d7e45f1d30f74ad9885516e34ecce226ca0f1312c36e4d8e9c5f62e91f0e4b',
    '7918d8cd45447e4e5c204026efaa2b691cb8b8ba3da37bce4dbe6c70c511c52c',
    '7bd450bc07cb28bcd6908e89bcca378df025232002d7adbd2deacd0a48e57823',
    '7e1f6832b0a59518e57d96aa6d4635d17a7be1442d9120c6060308d93f8e2b4b',
    '8227f63004e9d48013d12409635d6b305310eda918b56254c9d1098ca6ad46f1',
    '84782c3cb4f67bf1703781b66dd81a1987626f8549ca1840f71fda2a5ae35fa6',
    '8b7a5891aafbb61b347aa8f767563ea0299a075c1202eb139562fea8eb5e8c0d',
    '909e79148fd9111ecdfa3b9393d15dc69a65d2b303e7803c402ccc84a1e99cde',
    '912e6c59310b291454e1522ad0211161d241c04d580b2329c76c013f3e73a4f0',
    '921d3f011ea3150bf9c37f253cd64a1221dd6c4b7e802c883142f097aa279cd7',
    '9409a6c555a7d3ac2459426033e245ca689723408c422f85d0052e9a2c4db9a8',
    '957ae2da95f6bbc8ac3251dfd22070fad4022bcb17584aad6e445036c8d35751',
    '98ada568c48efd46e1aafa7954b311824d8941ae85bc19b72570af76f85a4e45',
    '9b94f0dd45b82d6523dedba84851e9e6d2d2da89ac458a66ee356230a4bf1d28',
    '9d9ff05b74aa1f349e8383ee075246ca7453111b283ec01567b9b242f0cbdabb',
    'a039d4c84b3c00c3f941f900a791926346649f699362b5af5c1d5a9781817f1a',
    'a2b860aed52539bf3aa3febb0fa9eab60715929d1848501a66fa0158ba0b5392',
    'a5c9ce697dbb3aa6152cb6182a41d110339c2ab93b058acb7c194d549d312795',
    'a75c903175254d0ae2065e1d0c7e35c30aba77537c81012679717fb0708bb268',
    'aa0dcea53b99f46b949aea6f3d755def723af41cdb87b007c60bfd451b6a1b21',
    'aeafc8b0b689d69deace70ac7d502153ef7495aefd65b8a6da5cbc9543ac9a36',
    'b160c7a0c0c76403a519e113c04fc921f69089c273081551bac25d4707068acc',
    'b1844113476279a4b962411965d5024e7da8dee68d3c16ec3986288b4414f761',
    'b1b6c69b676863b75d56e9554db770e8e28cee7f24288a899ffac30b2b4316fa',
    'b63cc53e20ef64fea7d445c4b2ecf5b294084252570c7e8d0da0dd5230876414',
    'b6bc4a33ef61dfb7cc7bc049e8e39d034b377f08f0410dce1687499ce0bc21fd',
    'b872b365e050cf1e5483bb37a34c1ef180461e65b1328db42856852a9e002a62',
    'bb4fbea6b4b8f91f01ae9af814fc301e9b68b0779a3cd0729955c0c04c78efba',
    'bc25ef063f36120e5ba246f9bbe3ac3ba0e8d9d45723f240084135ae76b02e20',
    'bd85347c4f7e443e6093d819e3443dc75dfbca0612943263173f145ca7d58ffb',
    'be288ed7b3a6793e2edee5a80e5029b1b720d18a83377e48281c6b36c39b9a44',
    'be6e1c54717e4274e958078f8c03f15881ad5d8b6a9d3b0da2eb5c2412d8c98c',
    'bfc61828f6df2cec1fe09079359c269aba4800267cd076cdd7bcd587d7bf444b',
    'c085497c697893781a1f87ef04b4ba54a78dfae1cc528035d0ad09b748dfecf3',
    'c345b576f814a5ee48a72918dc74bb5a0d9eeed264adc551b02c15f5063db75b',
    'c4c9023e7654ba40c6b7c6ea965c3cfca18a4bbbad9015b42f7f1aa9a7e91ba0',
    'c723191424cf3c7061c2f3136763f903e71f275ea1d8f7ccbb97e81d39a52630',
    'c7f561a58a0137c16b3edd18bd9fb803924febf867c9d385151909753de04fc2',
    'c86618ef7c75c05de09988eba3eea16a50e7054cccc82d2457fa93d05cd47cb0',
    'c8ef5bcef51e1e18b68e83036162a9b98b586fa9515d38b02b76c6226e37d4cf',
    'cd410073b2c91a5f59f7c616f27f109310343f66cd7a4e00be27e2452741fa91',
    'cd4fae9e852e3f767953245f719915b1e5903a7f1858bc61fc40d997471c8ad0',
    'cec59f97e9c373d53c721ebd562b20c9c8ba8f8b2ed11b6d7c2f317ef741c58a',
    'd51a931ce0a61afd47c9a6517b7414fa5a7602f813448cf052e8a7c357b86a25',
    'd5334661b0ed40dac746a84b8490b072df1178c8a0770b93ee47c6ae172c4bbb',
    'd5e9d040100d5b1457594b926eb6d52f0b0b84c96dc880168525c5f883d38afb',
    'd61ceadd73118456285022283e14b7cfa71c3fe286a084a16520ff60f5f01ec4',
    'd667815fb2503dde1dfca62c5ac4e5c737d69765594beb8536bcfcfd525732fa',
    'd740568c04c571dd9ac41f648f0b584c577d03e4a9ab61a90a3bf04fa71943d7',
    'd9882d64dbf313b9567979374b1e4f16e6198361a59473d3d4249d60f13299c0',
    'd98b6390a9a632650dad88d94bba461ff3c29fbca372b81068e0546f71ce62d5',
    'da5301d8bcb1490dcd66ad26031e40f6a42b54bd5a93e31a8504b90b4a7a027c',
    'da64c8095bdc4512302ceea99a66991bd56ef05dafab218390e01101ed84c786',
    'db487e1fea0963810fa3d9ff8a48400598c27de8931fb4f0aae54e04ad98a0c9',
    'dd891fa471b8cad448d63e390d6edd3a87afcb9b98f833ef213df1042d4678cb',
    'df05338203a80368ce9a45f910042f844b78905766b573a02f440143799b9ff5',
    'dfed31d2715c5692f4113d1e65ed6ec5b5b1f35c8532d03c8905d5e745bfb2e7',
    'e3c7437cf9b7db1be8a4c9806b33eaf7f47a5054b92dc3fe5a9009aa4b5d7b84',
    'e67f231110137a860a59d3136dadbfc8ec2a9bc3f48b918061011564d7218ce1',
    'e8d1842741df4b113b8b84f2b53063abc6c60fdcb18183c1fefa0308f0133d19',
    'ea15fb57a4f629e725946611a9ea52f51677243c729c6d584b6f1d5a606ea74b',
    'ebbe8dece7e75290b29430248039f4977158f7c6086116c6dd869c3d4401549e',
    'ec9bf28fe2a38bb14c1ce63b1b459e9b75066f61a2a935f59a8141a86f0acf61',
    'efad30c217283ff0d86f1c183b2af729c387eba0e0793576195dd1772289c399',
    'f0052be3934e56dd464eff1cdc271f0a0e1ef76b8f5a1f527f9203c3906825dc',
    'f02a5827b2d94576f1300bc903fd08d82cebe54a58911b1cf5c0e2ce7de753a3',
    'f0591b67337f4be91beb188f5229716c40f89af6685902820e00703eff58f9d3',
    'f09b8fb0f58fe871118c0ef06c1baf6ebb3c276c25b8c0e2600ec9bb369fcc0f',
    'f3527314ce350dde2915bbe2ab7b341a5a09f5b965b93f105fcd415a8900c2f4',
    'f47f9ece2194900f422f1f291b6902744714f89aff1867609abf910a6ec96683',
    'f69be4fa3e1dea1e5e9af893dfeeb379783fde12cb31ca247e1bdbc56fee3b2d',
    'f7eabd816d13b7b3d1b381496172a5de1a2c0fae74cbae159e7236f7c779192f',
    'f87301a3691fcede41219524f1d5b350cc57c7527d461167ff9d00772e4cdb92',
    'fb4b7dd3cccf2685c32a398070402d61567d68e5ba4dca9058b6220db59952fe',
    'fb653d48bcd5f8eedc16cc07d82f602dc186f641260668e3094696e2febd7abb',
    'fc2fd6b1ba903d54ce71182020691ba7c250d16b54bd5a99ebe0410c22abcb8b',
    'fee865c2c9788e4ac39e1b874c070b2e47e487c75097473e8fecf37922394d19',
    'c187f34dea346dd4c22f069b0505c7d2132ec7026c109562942704e7a7d44f12',
    'fecb4e6fec84c1cbbeaf9ac0122bc567a95b93e0e726512592608ca3d7c3ac2f',
    '6b9085d6a0dd8e1e4d3693493345f835655ac113d2d865bac76d525916344f2a',
    '548cf265ead876226cb72cd7de7d8e8f88389daec336d6ebd9878609c2d04a38',
    'bfe611dc52307437b74c32e12d288ccafed8b20d98234e7a63c131a29cd71032');
begin
  for var Hash in Hashes do
    if SameText(ModelHash, Hash) then
      Exit(True);
  Result := False;
end;

function J2MECompatibilityM3GOrphanCamera(const ModelHash: string): Boolean;
const
  // Reviewed Fast and Furious exports reference an active Camera but omit it
  // from the World's child list. Restore only that missing hierarchy edge.
  Hashes: array[0..5] of string = (
    '588606321d27bf1758cc5a99ed3baa1f2dbc3adc8aa4044d9cf288219f7f1f1b',
    '8db4815a157b391060296e307af2748b08a9cc45dce98d8a1fbc51f77917b7b8',
    'b3024716d2700ae2816873a4c2a7d4cfa288320049f84e07f92b88596f97b3dc',
    'b8afd791dee57e1086c442c176457879fd37c0ba76e01407635e023d81cde6ac',
    'f29e70085318abc565d0da9ab7d03c6bb5d541450b64dd8a20cfedd2cc41afa5',
    'f40649ef6282cec7f331d8a1721b25de5b9001366d446e8e95d7853df9e1d422');
begin
  for var Hash in Hashes do
    if SameText(ModelHash, Hash) then
      Exit(True);
  Result := False;
end;

function J2MECompatibilityPNGTrailingData(const ImageHash: string): Boolean;
begin
  // Reviewed Bimmer textures contain a complete small PNG followed by stale
  // bytes from a replaced image. Only these exact resource bytes are accepted.
  Result := SameText(ImageHash, '0ba212aadcedf1c9a02a7950ec78fa2b7a8a542db7821c459204c55c1129eea4') or
    SameText(ImageHash, '32d76534b493ed2f43ef5e28b5ff833945c2ca178b5767f324bc4f1132214fbc') or
    SameText(ImageHash, '0eb446c9d9a6b633ada119f04d41edc5f41cdfd7377adaf461b1b431e25a0fbe');
end;

function J2MECompatibilitySamsungVibrationMillis(Suite: TJ2MESuite): Boolean;
begin
  // Forgotten Warrior passes 1000 for its hit effect to Samsung's API.
  Result := ResourceMatchesHash(Suite, 'Default.class',
    '3cb754add333861e54e6aa3a543ac76b0cc707bb57483b9c0c8a2bfb238c6cfd') and
    ResourceMatchesHash(Suite, 'GameScreen.class',
      '45e4c411d1af0a9e3d03da89bc5e8bb622825a11e303c5a4226a7f9d989abd3e');
end;

function J2MECompatibilityIgnoredFlashDuration(Suite: TJ2MESuite): Int64;
begin
  Result := 0;
  // Stuntman 1.2.24 requests this duration on every startApp to keep the
  // display lit. Treat it as steady backlight on the virtual display.
  if ResourceMatchesHash(Suite, 'StuntmanMIDlet.class',
    '97316a4fcf1f8eea6912572fe633018cf3b909d6e1a9f41788dbec781999d441') then
    Result := 40000000;
end;

function IsSiemensFixedCanvasEdition(const JarHash: string): Boolean;
begin
  // RailRider uses a byte-aligned 104-pixel raster. The four Men in Black II
  // episodes draw a 96x80 playfield. Both target the Siemens 101x80 display.
  Result := MatchText(JarHash, [
      'd648580661c94875b88ffe368408d6a719c880b59be364a4848e9062d433b131',
      'b670f54bfb49e799447fcd81b5e02308a271ecabff00b35911bd925abcf8787d',
      '75f69626a7f18bae3587f6f3ae35452f5f7e9450163e773f4d5ea7852ce608fb',
      'e441913f0b502e365fcfe020c7255ec5dd0c37f86438ba5c4ee6d3e00006130a',
      'eb7f1d28e582e454902b9b5a321ae3a2f5c5e92d71b25f8b2509e340b442b9b3']);
end;

function TryJ2MECompatibilityScreen(const JarHash: string; out Size: TJ2MEScreenSize): Boolean;
begin
  Size := Default(TJ2MEScreenSize);
  Result := True;
  // This port has a 255x208 world and no sizeChanged handler. A taller phone
  // makes its camera limit negative and leaves rows outside its background.
  if SameText(JarHash, BiplanesHash) then
    Size := TJ2MEScreenSize.Create(176, 208)
  // Bounce 1.9 blits its fixed 128x128 gameplay buffer at the Canvas origin.
  else if SameText(JarHash, Bounce19Hash) then
    Size := TJ2MEScreenSize.Create(128, 128)
  // GemGame targets Nokia Series 40. Its splash gradient depends on width.
  // Decathlon's track gradients depend on height. Both fit a 128x128 Canvas.
  else if MatchText(JarHash, [
      '006f7dca129c19be8a28fc9305d393705087ddd393e7df8458948126f9530993',
      'f7f4089beb259376b8218f2f865ca3236f259611e08255be5e7dcfed654a65b6']) then
    Size := TJ2MEScreenSize.Create(128, 128)
  // Backgamon 3510i paints its fixed 96x65 board at the Canvas origin.
  else if SameText(JarHash, 'fd7dffd8d5478f2ca18d6e645d08cb4efd81b2b7c89a64287bea070cdeaf37f3') then
    Size := TJ2MEScreenSize.Create(96, 65)
  // These Nokia 7210 builds select their packaged artwork at 128x128.
  else if MatchText(JarHash, [
      '01be32f47a8f50c8723e1473124443a7394524c8810515b09e408cc5dc9b24d4',
      '4815b2dbac4e2a0e38b7164b32ecf0d8a22c5b6d8dce11d18f8e3687039152b7',
      'ce8554da281d372af9361b2992ece60ddfefd46581536cf4f69b24978e3a7429',
      'd67d0c2f12a5e87632ad16445e112c4e2c9d7312c7220e86d812e908013f518f',
      '88290b42a14cadff1bd61aeed043e35be9b7d168034846a956056d00c0ea9f97',
      'e5bcae5cfcd583e4549f983a42cef5d7cfea16939e36a9d6c9ab93c46af97bf1',
      'd64a5eadb4f7a918ce5c1cf1a4f5deb837c5e5c3771eb3903b1e6d696ffe8bca',
      'ae84bfea54a805be69231cad108e7e271e967136f40a1f676f9961c0e47521a2']) then
    Size := TJ2MEScreenSize.Create(128, 128)
  // Pro Mahjong for Nokia 7210 centers a fixed 128x128 board and menus.
  else if SameText(JarHash, 'e6879fc074e0114db5f40dfa55381217db7b5eeabdc70ded0c3911a48da09bda') then
    Size := TJ2MEScreenSize.Create(128, 128)
  // Gomoku draws a 128-pixel title. A larger Canvas makes its paint loop
  // exceed the fixed 22-by-22 board backing array.
  else if SameText(JarHash, 'c37f3311c62a868f6bfd42bfe9ba7a126f237deda8b5b5095f3a75e174b56199') then
    Size := TJ2MEScreenSize.Create(128, 128)
  // ChinaChess packages its complete board and logo at 176x208.
  else if SameText(JarHash, 'fd6839865d23cafded13433feadb3626e0f3670efc9fc5696fecb0fccf07dd7e') then
    Size := TJ2MEScreenSize.Create(176, 208)
  // Amigo positions the menu softkeys and sets the scene clip at 176x208.
  else if SameText(JarHash, '6f28751f73c541c8d33c3ca52cce0e39f403017f05adea53ae62da41521f2ee8') then
    Size := TJ2MEScreenSize.Create(176, 208)
  // Ice Age clips and centers its gameplay in a fixed 128x128 viewport.
  else if SameText(JarHash, '1b793d0de0cd3407564dc0475c35583f800791f6237093c48cc6b03b7e8152a3') then
    Size := TJ2MEScreenSize.Create(128, 128)
  // ChickenRun clears its fixed 128x128 playfield with a 128x110 background and an 18-pixel HUD.
  else if SameText(JarHash, '387404196dfea34a524ac0faa138a696c2cdcff365fc58ca58ac4283d5adbd75') then
    Size := TJ2MEScreenSize.Create(128, 128)
  // KO Kickboxing packages its splash, selection and ring at 176x208.
  else if SameText(JarHash, '83c82f9d4d59653150c5e62f86c682101fe2b0329e22fce258127d9f6c144bbc') then
    Size := TJ2MEScreenSize.Create(176, 208)
  // Yetisports Part 2 centers its 127x128 splash on a Nokia-sized screen.
  else if SameText(JarHash, 'db133476027c7bd3640b01eaa5c8db10dcde471fd698dcc01301ae7848beedf5') then
    Size := TJ2MEScreenSize.Create(128, 128)
  // Skull Castle Pinball allocates a 128x128 drawing surface.
  else if SameText(JarHash, '6c7cb112e4325f7a2d469cdc0588a9cf9aef016118f5d7b6828fdf9320bce361') then
    Size := TJ2MEScreenSize.Create(128, 128)
  // Snood uses a fixed 120x160 area for its custom menus and board.
  else if SameText(JarHash, '09e5a4feab79fde56ff284b4a55bbf523866b64d46341543d3d4179289ea9cbd') then
    Size := TJ2MEScreenSize.Create(120, 160)
  // Evil Dead Pinball draws a 128-pixel table above its score and softkeys.
  else if SameText(JarHash, '4bc3758d279e84b61b18ccb41d6bf2e953878b54a7ee01369ccac61433de7b78') then
    Size := TJ2MEScreenSize.Create(128, 128)
  // Ocean's Twelve draws a fixed 176x208 map and HUD.
  else if SameText(JarHash, '2cd1258f4d06ed1e9e066320271871e5b439b07ee8927ebf7428ee767abbefe5') then
    Size := TJ2MEScreenSize.Create(176, 208)
  // Haunts indexes a fixed 178-column array using its Canvas width.
  else if SameText(JarHash, '1a7d033bd84b3e2de395a92cd521159a9fef2392fb12ea2736d935d8ca249f54') then
    Size := TJ2MEScreenSize.Create(176, 208)
  // Jangbi packages fixed 128x128 title and map artwork.
  else if SameText(JarHash, 'b62840f3ae0410343065687e0c08c9a27dfc21d339df36acc1e1c1a5e20b54b8') then
    Size := TJ2MEScreenSize.Create(128, 128)
  // Shepherdess derives the camera bounds from an eight-row title map.
  // A larger Canvas can index outside that map. The 128x128 profile also
  // fits the game HUD and the tested gameplay stages.
  else if SameText(JarHash, ShepherdessHash) then
    Size := TJ2MEScreenSize.Create(128, 128)
  // These exact builds draw menus at fixed dimensions.
  else if SameText(JarHash, DieHardHash) then
    Size := TJ2MEScreenSize.Create(176, 208)
  else if SameText(JarHash, TennisOpen2007Hash) then
    Size := TJ2MEScreenSize.Create(128, 128)
  // The packed full-screen art and coordinate scales target 176x208.
  else if SameText(JarHash, AncientEmpires103Hash) then
    Size := TJ2MEScreenSize.Create(176, 208)
  // This Asphalt 3 build paints the sound prompt and game at fixed 176x208.
  else if SameText(JarHash, Asphalt3Hash) then
    Size := TJ2MEScreenSize.Create(176, 208)
  // DustNDirt rejects the device unless the Canvas matches the 176x208
  // image it reads from res.raw at startup.
  else if SameText(JarHash, DustNDirtHash) then
    Size := TJ2MEScreenSize.Create(176, 208)
  // These Guitar Hero builds use different fixed drawing areas for menus.
  else if MatchText(JarHash, [GuitarHero3LandscapeHash, GuitarHeroWorldTourBackstageHash]) then
    Size := TJ2MEScreenSize.Create(320, 240)
  else if SameText(JarHash, GuitarHero3PortraitHash) then
    Size := TJ2MEScreenSize.Create(240, 320)
  // This edition sets its drawing area to 320x240 in boxal.inf.
  else if SameText(JarHash, ParachutePanicHash) then
    Size := TJ2MEScreenSize.Create(320, 240)
  // The song and pause menu use a fixed 240x320 drawing area.
  else if SameText(JarHash, GuitarRockTourHash) then
    Size := TJ2MEScreenSize.Create(240, 320)
  // This exact port suspends its GameCanvas whenever sizeChanged width <> 320.
  // Both bytecode and a 320x240 menu/input run confirm the landscape layout.
  else if SameText(JarHash, BMWRacingHash) then
    Size := TJ2MEScreenSize.Create(320, 240)
  // This Sony Ericsson K750i build clips menus at 176x220 and uses fixed
  // positions at those edges, even though its 3D race viewport can grow.
  else if SameText(JarHash, NFSCarbonHash) then
    Size := TJ2MEScreenSize.Create(176, 220)
  // Shrek 2 draws a 176x208 title image above its fixed softkey bar.
  else if SameText(JarHash, Shrek2NokiaHash) then
    Size := TJ2MEScreenSize.Create(176, 220)
  // Stuntman paints its visible scene at 176x183; its larger images are
  // scrolling buffers. The earlier iomo version fills 120x160 directly.
  else if SameText(JarHash, StuntmanNokiaHash) then
    Size := TJ2MEScreenSize.Create(176, 183)
  else if SameText(JarHash, StuntmanOriginalHash) then
    Size := TJ2MEScreenSize.Create(120, 160)
  // This edition packages 176x220 splash screens and in-game menus.
  else if SameText(JarHash, Sims2MobileHash) then
    Size := TJ2MEScreenSize.Create(176, 220)
  // This edition places its menus, softkeys and splash in a 176x220 Canvas.
  else if SameText(JarHash, BimmerStreetRacingHash) then
    Size := TJ2MEScreenSize.Create(176, 220)
  // The Samsung build draws its full Canvas at fixed 176x220.
  else if SameText(JarHash, ForgottenWarriorHash) then
    Size := TJ2MEScreenSize.Create(176, 220)
  // This edition paints its splash, menus and levels in a fixed landscape viewport.
  else if SameText(JarHash, MasteringMagicHash) then
    Size := TJ2MEScreenSize.Create(320, 240)
  // This export blocks its main paint path when width < height and draws
  // the actual game at fixed 320x240; its orientation warning is misleading.
  else if SameText(JarHash, DiamondRushHash) then
    Size := TJ2MEScreenSize.Create(320, 240)
  // This Motorola port paints a fixed 176x208 Canvas, including its softkeys.
  else if SameText(JarHash, PoolHash) then
    Size := TJ2MEScreenSize.Create(176, 208)
  // Ninja Master fixes the height at 80 and loads a 101x80 background.
  else if SameText(JarHash, NinjaMasterHash) then
    Size := TJ2MEScreenSize.Create(101, 80)
  // The Worms K750 package contains full-screen splash art at 176x220.
  else if SameText(JarHash, '14951d46ec408620ba2871f5c0677ee4077c65774d811d8818c9ffbd464bbeca') then
    Size := TJ2MEScreenSize.Create(176, 220)
  // These Xidris builds place their full-screen art and menus at 101x80.
  else if MatchText(JarHash, [
      '12f94fc988fddb157e8383393dbd602cdae16b2b88038bbad01bedc87e2fda9a',
      '9739554c1c5c72c48e3680b8c463a5158a4a2bd7e0f132c42441f0316e6582d2',
      'f4ca5accb66c68b68e9c083cb2662dcbc9266e0f7a8b322c7de5789207de5143']) then
    Size := TJ2MEScreenSize.Create(101, 80)
  // Wild Wheels skips initialization unless both Canvas dimensions match.
  else if SameText(JarHash, 'cb6f53288d4655726bcbc3b8503d820e83e1f37692c477c517361ca1488cfaf4') then
    Size := TJ2MEScreenSize.Create(101, 80)
  // Sticker draws a fixed 96x76 board. Leave room for the LCDUI commands.
  else if SameText(JarHash, 'ebf2de3b16a028634a71f9ef15710dd498260703d3daa016e5d601b16ae26442') then
    Size := TJ2MEScreenSize.Create(101, 96)
  // Jac draws a 101x80 board and uses LCDUI commands during gameplay.
  else if SameText(JarHash, '023c5a028de10065693aaa6ac9fa64e37ac32334cd56cad31f8316b8bb5bac4b') then
    Size := TJ2MEScreenSize.Create(101, 96)
  else if IsSiemensFixedCanvasEdition(JarHash) then
    Size := TJ2MEScreenSize.Create(101, 80)
  // These Siemens editions use the monochrome 101x80 display.
  // The backing bitmap widths use byte-aligned rows.
  else if MatchText(JarHash, [StackAttack2Hash, SummerSkiHash, RaymanGolfSiemensHash,
      PrinceHaremSiemensHash, BrokenWingSiemensHash, MarslanderSiemensHash, GameAPIDemoHash,
      BalloonShooterHash, MoorhuhnSiemensHash, RatZSiemensHash,
      BlockBreakerSiemensHash, CollisionCourseSiemensHash, RTLRacerSiemensHash]) then
    Size := TJ2MEScreenSize.Create(101, 80)
  else
    Result := False;
end;

procedure MigrateJ2MECompatibilityScreen(const JarHash: string; Runtime: TJ2MERuntime);
begin
  var Size: TJ2MEScreenSize;
  if TryJ2MECompatibilityScreen(JarHash, Size) then
    MigrateJ2MECompatibilityScreen(JarHash, Runtime, Size);
end;

procedure MigrateJ2MECompatibilityScreen(const JarHash: string; Runtime: TJ2MERuntime; const Size: TJ2MEScreenSize);
const
  MIDletClass = 'com/nokia/mid/appl/boun/Bounce';
  UIClass = 'com/nokia/mid/appl/boun/BounceUI';
  CanvasClass = 'com/nokia/mid/appl/boun/BounceCanvas';
  TileCanvasClass = 'com/nokia/mid/appl/boun/TileCanvas';
var
  C: TJVMClass;

  function Field(const Name, Descriptor: string): TJVMField;
  begin
    for var F in C.Fields do
      if (F.Name = Name) and (F.Descriptor = Descriptor) then
        Exit(F);
    raise EReadError.Create('Incompatible saved phone layout');
  end;

  procedure Put(const Name: string; Value: Integer);
  begin
    Field(Name, 'I').Value := TJVMValue.Int(Value);
  end;

begin
  // Diamond Rush reads Canvas dimensions only in its orientation-warning
  // path; actual layout/buffers are fixed at 320x240. Resizing this ordinary
  // Canvas needs no guest-field edits and resumes the saved game moment.
  // Pool, Asphalt 3 and Mastering Magic also use fixed art on an ordinary Canvas.
  // A higher-priority descriptor can supply the target size.
  // RailRider and Men in Black II use ordinary Canvas with fixed backing rasters.
  if MatchText(JarHash, [DiamondRushHash, PoolHash, Asphalt3Hash, MasteringMagicHash]) or
    IsSiemensFixedCanvasEdition(JarHash) then
  begin
    Runtime.ResizeCanvas(Size.Width, Size.Height);
    Exit;
  end;
  if SameText(JarHash, Bounce19Hash) then
  begin
    // Bounce uses the Canvas size cached in its constructor to draw splashes
    // and clear the screen. Its 128x128 gameplay buffer is independent.
    var UIRef, CanvasRef, Cached: TJVMValue;
    if (Runtime.MIDletReference <> 0) and
      Runtime.VM.GetObject(Runtime.MIDletReference).Fields.TryGetValue(MIDletClass + '.mUI:L' + UIClass + ';', UIRef) and
      (UIRef.AsRef <> 0) and
      Runtime.VM.GetObject(UIRef.AsRef).Fields.TryGetValue(UIClass + '.mCanvas:L' + CanvasClass + ';', CanvasRef) and
      (CanvasRef.AsRef <> 0) then
    begin
      var Fields := Runtime.VM.GetObject(CanvasRef.AsRef).Fields;
      if Fields.TryGetValue(TileCanvasClass + '.mWidth:I', Cached) and (Cached.AsInt = Runtime.ScreenWidth) then
        Fields[TileCanvasClass + '.mWidth:I'] := TJVMValue.Int(Size.Width);
      if Fields.TryGetValue(TileCanvasClass + '.mHeight:I', Cached) and (Cached.AsInt = Runtime.ScreenHeight) then
        Fields[TileCanvasClass + '.mHeight:I'] := TJVMValue.Int(Size.Height);
    end;
    Runtime.ResizeCanvas(Size.Width, Size.Height);
    Exit;
  end;
  // The remaining cached-field edits apply to Biplanes. Other launch-size
  // profiles do not imply a compatible migration of old GameCanvas buffers.
  if not SameText(JarHash, BiplanesHash) then
    Exit;
  // A higher-priority descriptor can select another supported viewport. Do not
  // silently replace that decision with the database's preferred dimensions.
  if (Size.Width < 1) or (Size.Height < 1) or (Size.Width > 255) or (Size.Height > 208) then
    Exit;
  if (Runtime.ScreenWidth = Size.Width) and (Runtime.ScreenHeight = Size.Height) then
    Exit;
  C := Runtime.VM.LoadClass('b');
  // Only layout values cached from getWidth/getHeight by this exact port.
  // Gameplay, RMS, input, RNG and threads remain those of the saved moment.
  Put('r', Size.Width);
  Put('s', Size.Height);
  Put('ak', 255 - Size.Width);
  Put('al', 208 - Size.Height);
  Put('ai', EnsureRange(Field('ai', 'I').Value.AsInt, 0, 255 - Size.Width));
  Put('aj', EnsureRange(Field('aj', 'I').Value.AsInt, 0, 208 - Size.Height));
  Put('dt', Size.Width - 3);
  Put('ds', Size.Width - 5);
  Put('dq', Size.Width - 11);
  Put('dp', Size.Width - 13);
  var Ref := Field('d1', '[I').Value.AsRef;
  if Ref <> 0 then
  begin
    var A := Runtime.VM.GetObject(Ref);
    if Length(A.Elements) <> 2 then
      raise EReadError.Create('Incompatible saved phone layout');
    A.Elements[0] := TJVMValue.Int(Size.Height - 48);
    A.Elements[1] := TJVMValue.Int(Size.Height - 28);
  end;
  Runtime.ResizeCanvas(Size.Width, Size.Height);
end;

end.

