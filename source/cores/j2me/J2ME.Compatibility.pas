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
  // Reviewed Golden Warrior / Bimmer / NFS Carbon exports: only the unused
  // third bias component of two-component texture coordinates is normalized.
  Hashes: array[0..33] of string = (
    '00033c6e9b1a43f3dc9211205d4120270213bb179928342a578ef0bb754bce20',
    '0f82a50aa19a92d027b080e0751d71630c7107b2b34bff22ad0cdeece624d8c6',
    '10dd033fd08afc7bd749066625cd27f4d46ee5ddb44f60fccd096d679a5537a7',
    '189f2f69bd839964d7c5f51ffe38bedf61e89d04fa5a5e3e02a1fdf85ece3f81',
    '213bad8936730358b5e82c3614092c12514be3ad7db399981f2e301b8e59fd0f',
    '29a0dcab1abdf5b940c8878bf55ab7735f2265fcfb5d4a607a22fc077ab94f12',
    '2a94c17586bdcf55365c64d1828ded9ede7dac4f6223a43919ca2e6935f8ffb2',
    '38f84a387472f09b469ab414236b58275e50b77341919be77cf1d6aebfedfcdf',
    '3c281c478bf0eaffea22e81e6ded5939495f132ebfe405ed461979a11632e45b',
    '471f07b45df2077023b9bf91c2850078e174c5e086423f626028a75dcd13896a',
    '4c454cd8eeeae21ab48fa3cb8a28d9c060e0d514ec04c42cee2c609e71ac2b89',
    '556af7f2f29e999ac57c7b2c64956bd1ab7f8bd258c4ac80796b98d3bd8522e1',
    '5b6e781074d009dbce87a0e83913699fefc8f492ff2245eaf7a10468115f788c',
    '5dd8e44206b240c996d393538d8e64a9d222450a591bfa09c3219862e0c693bb',
    '5ddcc8ea7c82c259ba100fe3a4d73136adc022036a65a69e3fa38d6105bf3989',
    '740bbacf74fcbe5eaa23c20057a489329f5c23733a166533e6784f0fc31107c8',
    '75d7e45f1d30f74ad9885516e34ecce226ca0f1312c36e4d8e9c5f62e91f0e4b',
    '8b7a5891aafbb61b347aa8f767563ea0299a075c1202eb139562fea8eb5e8c0d',
    'b1844113476279a4b962411965d5024e7da8dee68d3c16ec3986288b4414f761',
    'b63cc53e20ef64fea7d445c4b2ecf5b294084252570c7e8d0da0dd5230876414',
    'be288ed7b3a6793e2edee5a80e5029b1b720d18a83377e48281c6b36c39b9a44',
    'bfc61828f6df2cec1fe09079359c269aba4800267cd076cdd7bcd587d7bf444b',
    'c86618ef7c75c05de09988eba3eea16a50e7054cccc82d2457fa93d05cd47cb0',
    'cd410073b2c91a5f59f7c616f27f109310343f66cd7a4e00be27e2452741fa91',
    'cd4fae9e852e3f767953245f719915b1e5903a7f1858bc61fc40d997471c8ad0',
    'd5e9d040100d5b1457594b926eb6d52f0b0b84c96dc880168525c5f883d38afb',
    'd667815fb2503dde1dfca62c5ac4e5c737d69765594beb8536bcfcfd525732fa',
    'd740568c04c571dd9ac41f648f0b584c577d03e4a9ab61a90a3bf04fa71943d7',
    'da64c8095bdc4512302ceea99a66991bd56ef05dafab218390e01101ed84c786',
    'db487e1fea0963810fa3d9ff8a48400598c27de8931fb4f0aae54e04ad98a0c9',
    'e3c7437cf9b7db1be8a4c9806b33eaf7f47a5054b92dc3fe5a9009aa4b5d7b84',
    'f09b8fb0f58fe871118c0ef06c1baf6ebb3c276c25b8c0e2600ec9bb369fcc0f',
    'f69be4fa3e1dea1e5e9af893dfeeb379783fde12cb31ca247e1bdbc56fee3b2d',
    'f87301a3691fcede41219524f1d5b350cc57c7527d461167ff9d00772e4cdb92');
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

