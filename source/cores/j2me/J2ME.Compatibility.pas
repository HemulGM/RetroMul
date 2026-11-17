unit J2ME.Compatibility;

interface

uses
  J2ME.Device, J2ME.Runtime, J2ME.Suite, J2ME.Input;

// Exact JAR identities only. Names and image dimensions are not reliable hints.
function TryJ2MECompatibilityScreen(const JarHash: string; out Size: TJ2MEScreenSize): Boolean;

function J2MECompatibilityKeyLayout(Suite: TJ2MESuite): TJ2MEKeyLayout;

// Reviewed guest code and text bytes identify a legacy device encoding.
function TryJ2MECompatibilityEncoding(Suite: TJ2MESuite; out Encoding: string): Boolean;

// Reviewed exporter defects; scope is the exact serialized resource, not a title.
function J2MECompatibilityM3GUnusedTexBias(const ModelHash: string): Boolean;

function J2MECompatibilityM3GOrphanCamera(const ModelHash: string): Boolean;

function J2MECompatibilityPNGTrailingData(const ImageHash: string): Boolean;

procedure MigrateJ2MECompatibilityScreen(const JarHash: string; Runtime: TJ2MERuntime); overload;

procedure MigrateJ2MECompatibilityScreen(const JarHash: string; Runtime: TJ2MERuntime; const Size: TJ2MEScreenSize); overload;

implementation

uses
  System.SysUtils, System.Classes, System.Math, System.Hash, JVM.Types,
  JVM.ClassFile;

const
  PoolHash = '0dd024a3bc2933d5d40289cfc0071da095dc3c491be428d8b78b647dcd3fe5b5';
  BiplanesHash = '356e01e2b47fb0fd8868e6729f928cad4c0ad79d43c57195f82e6be4a08ea72c';
  BMWRacingHash = '1c016383f9b5bab968269cbc0fed9939c4c5bf38a881eb11f292ee18a3082a55';
  NFSCarbonHash = '2b43fb9d5f9832e11ea597f329d451312ca019a6296299463679bb04403f540d';
  DiamondRushHash = '1a27a721a4440e8bdf63aa456732d71cb4e0cbd00054899dd233b0f69fd96b00';

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
  Hashes: array[0..116] of string = (
    '00033c6e9b1a43f3dc9211205d4120270213bb179928342a578ef0bb754bce20',
    '0143a0572a9e802fb09707f7b531508b3168f87fb30d9f759bbc2ee25d9d3a6b',
    '06110012a84d736ec2c354c0afabadd511780d9e265537986667733e72961c8b',
    '0700d0252b8a00dbf2ec78ef52959c26e05aca07f7d2673e6b3711b73e0b8632',
    '0cced26a0829cc08706f4be1bb54a230ff61946bdfabb0202814c512c908cc5b',
    '0f82a50aa19a92d027b080e0751d71630c7107b2b34bff22ad0cdeece624d8c6',
    '10451b1fde07158541b86f5783bcf8c52567caf09ec42caf19e0c64719926b01',
    '10dd033fd08afc7bd749066625cd27f4d46ee5ddb44f60fccd096d679a5537a7',
    '189f2f69bd839964d7c5f51ffe38bedf61e89d04fa5a5e3e02a1fdf85ece3f81',
    '213bad8936730358b5e82c3614092c12514be3ad7db399981f2e301b8e59fd0f',
    '21f5277edf8d9ef727cd763fe6f5c474c9553412f93a0a8795774fb42e113e14',
    '29a0dcab1abdf5b940c8878bf55ab7735f2265fcfb5d4a607a22fc077ab94f12',
    '2a94c17586bdcf55365c64d1828ded9ede7dac4f6223a43919ca2e6935f8ffb2',
    '2cb82b267e0a993a849c995b0b6e75fb3bb9d8ff64fbb8939bb0cf694cd5e3c8',
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
    'e3c7437cf9b7db1be8a4c9806b33eaf7f47a5054b92dc3fe5a9009aa4b5d7b84',
    'e67f231110137a860a59d3136dadbfc8ec2a9bc3f48b918061011564d7218ce1',
    'ea15fb57a4f629e725946611a9ea52f51677243c729c6d584b6f1d5a606ea74b',
    'ebbe8dece7e75290b29430248039f4977158f7c6086116c6dd869c3d4401549e',
    'efad30c217283ff0d86f1c183b2af729c387eba0e0793576195dd1772289c399',
    'f0052be3934e56dd464eff1cdc271f0a0e1ef76b8f5a1f527f9203c3906825dc',
    'f02a5827b2d94576f1300bc903fd08d82cebe54a58911b1cf5c0e2ce7de753a3',
    'f0591b67337f4be91beb188f5229716c40f89af6685902820e00703eff58f9d3',
    'f09b8fb0f58fe871118c0ef06c1baf6ebb3c276c25b8c0e2600ec9bb369fcc0f',
    'f3527314ce350dde2915bbe2ab7b341a5a09f5b965b93f105fcd415a8900c2f4',
    'f47f9ece2194900f422f1f291b6902744714f89aff1867609abf910a6ec96683',
    'f69be4fa3e1dea1e5e9af893dfeeb379783fde12cb31ca247e1bdbc56fee3b2d',
    'f87301a3691fcede41219524f1d5b350cc57c7527d461167ff9d00772e4cdb92',
    'fb4b7dd3cccf2685c32a398070402d61567d68e5ba4dca9058b6220db59952fe',
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
  // This exact port suspends its GameCanvas whenever sizeChanged width <> 320.
  // Both bytecode and a 320x240 menu/input run confirm the landscape layout.
  else if SameText(JarHash, BMWRacingHash) then
    Size := TJ2MEScreenSize.Create(320, 240)
  // This Sony Ericsson K750i build clips menus at 176x220 and uses fixed
  // positions at those edges, even though its 3D race viewport can grow.
  else if SameText(JarHash, NFSCarbonHash) then
    Size := TJ2MEScreenSize.Create(176, 220)
  // This export blocks its main paint path when width < height and draws
  // the actual game at fixed 320x240; its orientation warning is misleading.
  else if SameText(JarHash, DiamondRushHash) then
    Size := TJ2MEScreenSize.Create(320, 240)
  // This Motorola port paints a fixed 176x208 Canvas, including its softkeys.
  else if SameText(JarHash, PoolHash) then
    Size := TJ2MEScreenSize.Create(176, 208)
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
  // The same ordinary-Canvas resize applies to the fixed 176x208 Pool port.
  // A higher-priority descriptor requesting another size is not overridden.
  if SameText(JarHash, DiamondRushHash) or SameText(JarHash, PoolHash) then
  begin
    Runtime.ResizeCanvas(Size.Width, Size.Height);
    Exit;
  end;
  // These cached-field edits are exclusively for Biplanes. Other launch-size
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

