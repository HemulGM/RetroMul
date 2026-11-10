unit PSP.GE.PascalShaders;

interface

{$SCOPEDENUMS ON}
{$BOOLEVAL OFF}

type
  TPSPGEKernel = (Raster, SelfTest, HLEVertex, HLEFragment, HLEBlendFragment,
    HLEDown, HLEClut);

const
  PSPGEEntryPoint: AnsiString = 'main';

function PSPGEKernelCode(Kernel: TPSPGEKernel): TArray<Cardinal>;

implementation

uses
  System.SysUtils, System.Classes, System.SyncObjs, PTS.Component,
  PTS.Compiler, PTS.Source, PTS.Diagnostics, RM.Vulkan.Loader;

{$R 'PSPGE.Pascal.res' 'PSPGE.Pascal.rc'}

const
  ResourceType = PChar(10);
  ResourceNames: array[TPSPGEKernel] of string = ('PSP_GE_RASTER', 'PSP_GE_SELF_TEST',
    'PSP_GE_HLE_VERTEX', 'PSP_GE_HLE_FRAGMENT', 'PSP_GE_HLE_BLEND_FRAGMENT',
    'PSP_GE_HLE_DOWN', 'PSP_GE_HLE_CLUT');
  SourceNames: array[TPSPGEKernel] of string = ('PSPGERaster.pasm', 'PSPGESelfTest.pasm',
    'PSPGEHLEVert.pasm', 'PSPGEHLEFrag.pasm', 'PSPGEHLEBlendFrag.pasm',
    'PSPGEHLEDown.pasm', 'PSPGEHLEClut.pasm');

var
  CacheLock: TCriticalSection;
  KernelCode: array[TPSPGEKernel] of TArray<Cardinal>;

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

function CompileKernel(Kernel: TPSPGEKernel): TArray<Cardinal>;
begin
  var Compiler := TShaderCompilerComponent.Create(nil);
  try
    Compiler.SourceName := SourceNames[Kernel];
    Compiler.EntryPointName := string(PSPGEEntryPoint);
    Compiler.Optimize := True;
    var Compiled: TCompilationResult;
    try
      Compiled := Compiler.Compile(ResourceText(ResourceNames[Kernel]), [
        TSourceText.Create('SoftDouble.pasm', ResourceText('PSP_GE_SOFT_DOUBLE')),
        TSourceText.Create('PSPGEHLEPush.pasm', ResourceText('PSP_GE_HLE_PUSH')),
        TSourceText.Create('PSPGEHLEFragment.pasm', ResourceText('PSP_GE_HLE_SHADE')),
        TSourceText.Create('PSPGEHLEBlend.pasm', ResourceText('PSP_GE_HLE_BLEND'))]);
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

function PSPGEKernelCode(Kernel: TPSPGEKernel): TArray<Cardinal>;
begin
  // Resources are immutable for this process; each shader is compiled once.
  CacheLock.Acquire;
  try
    if Length(KernelCode[Kernel]) = 0 then
      KernelCode[Kernel] := CompileKernel(Kernel);
    Result := KernelCode[Kernel];
  finally
    CacheLock.Release;
  end;
end;

initialization
  CacheLock := TCriticalSection.Create;

finalization
  CacheLock.Free;

end.
