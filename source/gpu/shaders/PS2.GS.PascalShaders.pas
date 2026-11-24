unit PS2.GS.PascalShaders;

interface

{$SCOPEDENUMS ON}
{$BOOLEVAL OFF}

type
  TPS2GSKernel = (
    HLEVertex,
    HLEUpload,
    HLEFragment,
    HLEBlendFragment,
    LLESprite,
    LLETriangleShade,
    LLETriangleResolve,
    PackedPage,
    MirrorDecode,
    ColorLoad2,
    DirectColor,
    DirectBlend,
    DepthPack,
    DecodeImage,
    PaletteHybrid
  );

const
  PS2GSEntryPoint: AnsiString = 'main';

function PS2GSKernelCode(Kernel: TPS2GSKernel; Scale: Integer = 1): TArray<Cardinal>;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  PTS.Component,
  PTS.Compiler,
  PTS.Source,
  PTS.Diagnostics,
  RM.Vulkan.Loader;

{$R 'PS2GS.Pascal.res' 'PS2GS.Pascal.rc'}

const
  ResourceType = PChar(10);
  ResourceNames: array[TPS2GSKernel] of string = (
    'PS2_GS_HLE_VERTEX',
    'PS2_GS_HLE_UPLOAD',
    'PS2_GS_HLE_FRAGMENT',
    'PS2_GS_HLE_BLEND_FRAGMENT',
    'PS2_GS_LLE_SPRITE',
    'PS2_GS_LLE_TRIANGLE_SHADE',
    'PS2_GS_LLE_TRIANGLE_RESOLVE',
    'PS2_GS_PACKED_PAGE',
    'PS2_GS_MIRROR_DECODE',
    'PS2_GS_COLOR_LOAD2',
    'PS2_GS_DIRECT_COLOR',
    'PS2_GS_DIRECT_BLEND',
    'PS2_GS_DEPTH_PACK',
    'PS2_GS_DECODE_IMAGE',
    'PS2_GS_PALETTE_HYBRID'
  );
  SourceNames: array[TPS2GSKernel] of string = (
    'PS2GSHLEVert.pasm',
    'PS2GSHLEUpload.pasm',
    'PS2GSHLEFrag.pasm',
    'PS2GSHLEBlendFrag.pasm',
    'PS2GSLLESprite.pasm',
    'PS2GSLLETriangleShade.pasm',
    'PS2GSLLETriangleResolve.pasm',
    'PS2GSPackedPage.pasm',
    'PS2GSMirrorDecode.pasm',
    'PS2GSColorLoad2.pasm',
    'PS2GSDirectColor.pasm',
    'PS2GSDirectBlend.pasm',
    'PS2GSDepthPack.pasm',
    'PS2GSDecodeImage.pasm',
    'PS2GSPaletteHybrid.pasm'
  );

var
  CacheLock: TCriticalSection;
  KernelCode: array[TPS2GSKernel, 1..8] of TArray<Cardinal>;

function ResourceText(const Name: string): string;
begin
  if FindResource(HInstance, PChar(Name), ResourceType) = 0 then
    raise EVulkanError.Create('Missing Pascal shader resource: ' + Name);
  var Stream := TResourceStream.Create(HInstance, Name, ResourceType);
  try
    if (Stream.Size = 0) or (Stream.Size > 8 * 1024 * 1024) then
      raise EVulkanError.Create('Invalid Pascal shader resource size: ' + Name);
    var Bytes: TBytes;
    SetLength(Bytes, Stream.Size);
    Stream.ReadBuffer(Bytes[0], Length(Bytes));
    var Encoding := TUTF8Encoding.Create(False);
    try
      Result := Encoding.GetString(Bytes);
      var Encoded := Encoding.GetBytes(Result);
      if (Length(Encoded) <> Length(Bytes)) or
        not CompareMem(@Encoded[0], @Bytes[0], Length(Bytes)) then
        raise EVulkanError.Create('Invalid UTF-8 in Pascal shader resource: ' + Name);
    finally
      Encoding.Free;
    end;
  finally
    Stream.Free;
  end;
end;

function CompileKernel(Kernel: TPS2GSKernel; Scale: Integer): TArray<Cardinal>;
begin
  var Compiler := TShaderCompilerComponent.Create(nil);
  try
    Compiler.SourceName := SourceNames[Kernel];
    Compiler.EntryPointName := string(PS2GSEntryPoint);
    Compiler.Optimize := True;
    var Compiled: TCompilationResult;
    try
      Compiled := Compiler.Compile(ResourceText(ResourceNames[Kernel]), [
        TSourceText.Create('PS2GSHLEPush.pasm', ResourceText('PS2_GS_HLE_PUSH')),
        TSourceText.Create('PS2GSLLETypes.pasm', ResourceText('PS2_GS_LLE_TYPES')),
        TSourceText.Create('PS2GSLLETables.pasm', ResourceText('PS2_GS_LLE_TABLES')),
        TSourceText.Create('PS2GSLLEPixel.pasm', ResourceText('PS2_GS_LLE_PIXEL')),
        TSourceText.Create('PS2GSLLETriangleInputs.pasm', ResourceText('PS2_GS_LLE_TRIANGLE_INPUTS')),
        TSourceText.Create('PS2GSLLETriangleMath.pasm', ResourceText('PS2_GS_LLE_TRIANGLE_MATH')),
        TSourceText.Create('PS2GSHLEFragment.pasm', ResourceText('PS2_GS_HLE_SHADE')),
        TSourceText.Create('PS2GSUploadScale.pasm', Format('const UploadScale: Cardinal = %d;', [Scale]))]);
    except
      on E: EShaderError do
        raise EVulkanError.CreateFmt('%s(%d,%d): %s',
          [E.Position.FileName, E.Position.Line, E.Position.Column, E.Message]);
    end;
    if (Length(Compiled.SPIRV) < 20) or (Length(Compiled.SPIRV) mod SizeOf(Cardinal) <> 0) then
      raise EVulkanError.Create('Invalid SPIR-V from Pascal shader: ' + SourceNames[Kernel]);
    SetLength(Result, Length(Compiled.SPIRV) div SizeOf(Cardinal));
    Move(Compiled.SPIRV[0], Result[0], Length(Compiled.SPIRV));
  finally
    Compiler.Free;
  end;
end;

function PS2GSKernelCode(Kernel: TPS2GSKernel; Scale: Integer): TArray<Cardinal>;
begin
  if Kernel <> TPS2GSKernel.HLEUpload then
    Scale := 1;
  if (Scale < 1) or (Scale > 8) then
    raise EArgumentOutOfRangeException.Create('PS2 shader scale must be in 1..8');
  // The device scale is immutable; cache each compiled upload variant once.
  CacheLock.Acquire;
  try
    if Length(KernelCode[Kernel, Scale]) = 0 then
      KernelCode[Kernel, Scale] := CompileKernel(Kernel, Scale);
    Result := KernelCode[Kernel, Scale];
  finally
    CacheLock.Release;
  end;
end;

initialization
  CacheLock := TCriticalSection.Create;

finalization
  CacheLock.Free;

end.
