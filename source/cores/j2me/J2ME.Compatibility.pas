unit J2ME.Compatibility;

interface

uses
  System.SysUtils, J2ME.Device, J2ME.Runtime, J2ME.Suite, J2ME.Input,
  JVM.Runtime, JVM.ClassFile, JVM.Types;

// Exact JAR identities only. Names and image dimensions are not reliable hints.
function TryJ2MECompatibilityScreen(const JarHash: string; out Size: TJ2MEScreenSize): Boolean;

function J2MECompatibilityKeyLayout(Suite: TJ2MESuite): TJ2MEKeyLayout;

function J2MECompatibilityCanvasFooter(Suite: TJ2MESuite): Boolean;

function J2MECompatibilityExplicitInitialPaint(Suite: TJ2MESuite): string;

function J2MECompatibilityEmptyGameURLTemplate(Suite: TJ2MESuite): Boolean;

function J2MECompatibilitySummerSki(Suite: TJ2MESuite): Boolean;

function J2MECompatibilityStackAttack2(Suite: TJ2MESuite): Boolean;

function J2MECompatibilityMarslander(Suite: TJ2MESuite): Boolean;

procedure InstallJ2MECompatibilityClasses(Suite: TJ2MESuite; VM: TJVM; out ArmiesOfWarClass: TJVMClass);

procedure InvokeArmiesOfWarCompatibility(VM: TJVM; Method: TJVMMethod; const Arguments: TArray<TJVMValue>);

// Reviewed guest code and text bytes identify a legacy device encoding.
function TryJ2MECompatibilityEncoding(Suite: TJ2MESuite; out Encoding: string): Boolean;

// Reviewed exporter defects; scope is the exact serialized resource, not a title.
function J2MECompatibilityM3GUnusedTexBias(const ModelHash: string): Boolean;

function J2MECompatibilityM3GOrphanCamera(const ModelHash: string): Boolean;

function J2MECompatibilityPNGTrailingData(const ImageHash: string): Boolean;

function NormalizeJ2MECompatibilityMIDI(const Data: TBytes): TBytes;

function NormalizeJ2MECompatibilityOTA(const Data: TBytes): TBytes;

procedure MigrateJ2MECompatibilityScreen(const JarHash: string; Runtime: TJ2MERuntime); overload;

procedure MigrateJ2MECompatibilityScreen(const JarHash: string; Runtime: TJ2MERuntime; const Size: TJ2MEScreenSize); overload;

implementation

uses
  System.Classes, System.Math, System.Hash, System.StrUtils, Java.Classes;

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
  NinjaMasterHash = '51873044919a41dda1fb4630f0c037c42b0550ecfda1f85f37f5acb200ac3bd1';
  AncientEmpires103Hash = '9955552dc8c09b5416903316c2133d20a8f5fc4315666f8e1f89f3278bb93bd0';
  Asphalt3Hash = '5fe5be707b9996b99220caf19c403059fe11f3f2b201c5dbf792e75ee1e79340';
  DustNDirtHash = '8d4618bffbd3e0c6cd6216d05eebd25be6a3ce4213fa38a0639f32fd8737fa37';
  BiplanesHash = '356e01e2b47fb0fd8868e6729f928cad4c0ad79d43c57195f82e6be4a08ea72c';
  BMWRacingHash = '1c016383f9b5bab968269cbc0fed9939c4c5bf38a881eb11f292ee18a3082a55';
  BimmerStreetRacingHash = '262d2e1765c982cef3681ef6d33605d63c700397e0056da8d0415bceccf68057';
  NFSCarbonHash = '2b43fb9d5f9832e11ea597f329d451312ca019a6296299463679bb04403f540d';
  DiamondRushHash = '1a27a721a4440e8bdf63aa456732d71cb4e0cbd00054899dd233b0f69fd96b00';
  StackAttack2Hash = '21075f871178aa7cd955a0317a9832d634123c59390523b1b8839e92ec756934';
  ForgottenWarriorHash = 'f08c8034da70871fc6b0674288fc7b9f0d9d8a332b2b6cdb40d915372bfd25d1';
  SummerSkiHash = '66fc629e1272a07b64f6d1dc980812a6fabadaf5d24b457d689539f9800667d0';
  RaymanGolfSiemensHash = 'f3ef30455b259e92247ccc7d6ff4dd6ba4d0bd88f30a8b06eb1b5d32c6524af8';
  PrinceHaremSiemensHash = 'f14695f89339ea49d436c14f91040eb931fba9bd2f05dd1f16c7865ffba15c03';
  BrokenWingSiemensHash = '091f81d14c4abff2820bf255e7c88efb06dd9e004b7f6d818cbce676a618781c';
  MarslanderSiemensHash = 'e93faa05eb3cce547138504955ae6fcda7b4489da3f0b2ce8e1d782f24fe1230';

function ResourceMatchesHash(Suite: TJ2MESuite; const Resource, Digest: string): Boolean;
begin
  if not Suite.HasResource(Resource) then
    Exit(False);
  var Data := Suite.ReadResource(Resource);
  if Length(Data) = 0 then
    Exit(False);
  var Hash := THashSHA2.Create;
  Hash.Update(Data[0], Length(Data));
  Result := SameText(Hash.HashAsString, Digest);
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
    ResourceMatchesHash(Suite, 'a/R6Kernel.class', 'e459b5335613ea976b60388dff7d1b047bcdcc00b942fee7fa5f6336249ba983') then
    Exit(TJ2MEKeyLayout.Siemens);
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

const
  MiamiEngineHash = '84cb79849ed0d232f4b213a4dccee69b0e5f574b749c29a52806e13fa6ba4b0d';
  MiamiMIDletHash = '8df29fcdec82a6233e3ca84c7774c03e9d1a7adb77044752628c6f917a19aa87';

function NormalizeJ2MECompatibilityMIDI(const Data: TBytes): TBytes;
const
  GolfTourTitleMIDIHash = '089cc75e602ae948e324bc93da27f37d9bccb1dc41b6336b0caf412e992adb41';
  PanValueOffsets: array[0..15] of Integer = (
    82, 566, 1129, 1351, 1680, 2054, 2084, 2114, 2144, 2174, 2889, 2919, 2949, 2979, 3009, 3039);
begin
  Result := Data;
  if Length(Data) <> 3044 then
    Exit;
  var Hash := THashSHA2.Create;
  Hash.Update(Data[0], Length(Data));
  if not SameText(Hash.HashAsString, GolfTourTitleMIDIHash) then
    Exit;
  // Golf Tour's title music initializes CC 10 on all 16 channels with $C0.
  // Clear the stray high bit to recover the centered pan value.
  Result := Copy(Data);
  for var Offset in PanValueOffsets do
    Result[Offset] := $40;
end;

function NormalizeJ2MECompatibilityOTA(const Data: TBytes): TBytes;
const
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
begin
  Result := Data;
  if not (Length(Data) in [15, 16, 18, 21, 22, 24, 25, 29, 32]) then
    Exit;
  var Hash := THashSHA2.Create;
  Hash.Update(Data[0], Length(Data));
  var Digest := Hash.HashAsString;
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

function J2MECompatibilityEmptyGameURLTemplate(Suite: TJ2MESuite): Boolean;
begin
  // The Miami Nights 2 advertising code trims this optional property without
  // a null check. An empty template lets the game proceed without an ad URL.
  Result := (Suite <> nil) and
    ResourceMatchesHash(Suite, 'GloftMMN2.class', MiamiMIDletHash) and
    ResourceMatchesHash(Suite, 'c.class', '4d237f62c487763aa5f4d594564469bb7675e446f6acfa3a0b99627bccbe19ce');
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

procedure InstallGameAPIDemoScreenWait(Suite: TJ2MESuite; VM: TJVM);
const
  MIDletClass = 'GameAPI_Demo/GameAPI_Demo';
  ThreadClass = 'java/lang/Thread';
  WaitCallPC = 25;
  HelperName = '$waitForScreen';
  HelperDesc = '(Ljava/lang/Thread;)Z';
begin
  if not ResourceMatchesHash(Suite, MIDletClass + '.class',
    '7c6686f61f88ae52f0bc1c829538f35722ead8215921619b0f92f001de36a685') then
    Exit;
  var C := TJVMClass.Parse(Suite.ReadResource(MIDletClass + '.class'));
  try
    var Handle := C.FindMethod('Handle', '(LGameAPI_Demo/MyScreen;Ljava/lang/String;)I');
    if (Handle = nil) or (Length(Handle.Code) < WaitCallPC + 3) or (Handle.Code[WaitCallPC] <> $B6) then
      Exit;

    // This MIDlet polls isAlive until each screen's worker exits. Suspend
    // the launcher using JVM join, preserving the existing Handle offsets.
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
      Handle.Code[WaitCallPC] := $B8;
      Handle.Code[WaitCallPC + 1] := Byte(Target shr 8);
      Handle.Code[WaitCallPC + 2] := Byte(Target);
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

procedure InstallJ2MECompatibilityClasses(Suite: TJ2MESuite; VM: TJVM; out ArmiesOfWarClass: TJVMClass);
const
  RecordStore = 'javax/microedition/rms/RecordStore';
  CountPC = 8;
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
  InstallBalloonzUndoGuard(Suite, VM);
  InstallGuitarHero5LocaleFallback(Suite, VM);
  InstallCrashBandicootSoundListener(Suite, VM);
  InstallNinjaMasterLoadingPaint(Suite, VM);
  InstallGameAPIDemoScreenWait(Suite, VM);
  InstallIronMan3MediaTimeLookup(Suite, VM);
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

function J2MECompatibilityM3GUnusedTexBias(const ModelHash: string): Boolean;
const
  // Reviewed Golden Warrior / Bimmer / NFS Carbon / Planet Riders exports: only the unused
  // third bias component of two-component texture coordinates is normalized.
  // Planet Riders 1.3.2 hashes identify the decoded M3G bytes passed to Loader,
  // after its bo.a resource unscrambler (85 files, 83 distinct models).
  // Pearl Harbor Sky Conquerors uses the same exporter defect in 12 models.
  Hashes: array[0..128] of string = (
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
    'fee865c2c9788e4ac39e1b874c070b2e47e487c75097473e8fecf37922394d19');
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
  // This edition places its menus, softkeys and splash in a 176x220 Canvas.
  else if SameText(JarHash, BimmerStreetRacingHash) then
    Size := TJ2MEScreenSize.Create(176, 220)
  // The Samsung build draws its full Canvas at fixed 176x220.
  else if SameText(JarHash, ForgottenWarriorHash) then
    Size := TJ2MEScreenSize.Create(176, 220)
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
  // These Siemens editions use the monochrome 101x80 display.
  // The backing bitmap widths use byte-aligned rows.
  else if MatchText(JarHash, [StackAttack2Hash, SummerSkiHash, RaymanGolfSiemensHash,
      PrinceHaremSiemensHash, BrokenWingSiemensHash, MarslanderSiemensHash, GameAPIDemoHash,
      BlockBreakerSiemensHash, CollisionCourseSiemensHash]) then
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
  // Pool and Asphalt 3 also paint to fixed buffers on an ordinary Canvas.
  // A higher-priority descriptor can supply the target size.
  if MatchText(JarHash, [DiamondRushHash, PoolHash, Asphalt3Hash]) then
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

