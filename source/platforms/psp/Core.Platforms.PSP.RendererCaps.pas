unit Core.Platforms.PSP.RendererCaps;

interface

uses
  Core.Platforms.PSP.Renderer, RM.Vulkan.Bindings;

type
  TPSPRendererSupport = record
    LLE, HLE: Boolean;
    LLEAPIVersion, HLEAPIVersion: Cardinal;
    LLEDevice, HLEDevice, LLEError, HLEError: string;
  end;

function DetectPSPRendererSupport: TPSPRendererSupport;
function PSPRendererSupport: TPSPRendererSupport;
function AvailablePSPRenderers(const Support: TPSPRendererSupport): TArray<TPSPRenderer>;

implementation

uses
  System.SysUtils, System.SyncObjs
  {$IF (Defined(MSWINDOWS) or Defined(LINUX) or Defined(ANDROID)) and not Defined(CPUX86)}
  , RM.Vulkan.Compute, PSP.GE.VulkanLLE
  {$ENDIF}
  ;

var
  SupportLock: TCriticalSection;
  SupportReady: Boolean;
  CachedSupport: TPSPRendererSupport;

function AvailablePSPRenderers(const Support: TPSPRendererSupport): TArray<TPSPRenderer>;
begin
  Result := [prCPU];
  if Support.LLE and (Support.LLEAPIVersion >= VK_API_VERSION_1_1) then
    Result := Result + [prVulkanLLE];
  if Support.HLE and (Support.HLEAPIVersion >= VK_API_VERSION_1_1) then
    Result := Result + [prVulkanHLE];
end;

{$IF (Defined(MSWINDOWS) or Defined(LINUX) or Defined(ANDROID)) and not Defined(CPUX86)}
function HLEFormatsSupported(Compute: TVulkanCompute): Boolean;
begin
  var Properties: VkFormatProperties;
  Compute.API.vkGetPhysicalDeviceFormatProperties(Compute.PhysicalDevice, VK_FORMAT_R8G8B8A8_UNORM, @Properties);
  var Required: Cardinal := VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT or
    VK_FORMAT_FEATURE_STORAGE_IMAGE_BIT or
    VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT;
  if Properties.optimalTilingFeatures and Required <> Required then
    Exit(False);
  Compute.API.vkGetPhysicalDeviceFormatProperties(Compute.PhysicalDevice, VK_FORMAT_D32_SFLOAT_S8_UINT, @Properties);
  if Properties.optimalTilingFeatures and VK_FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT <> 0 then
    Exit(True);
  Compute.API.vkGetPhysicalDeviceFormatProperties(Compute.PhysicalDevice, VK_FORMAT_D24_UNORM_S8_UINT, @Properties);
  Result := Properties.optimalTilingFeatures and VK_FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT <> 0;
end;
{$ENDIF}

function DetectPSPRendererSupport: TPSPRendererSupport;
begin
  Result := Default(TPSPRendererSupport);
  {$IF (Defined(MSWINDOWS) or Defined(LINUX) or Defined(ANDROID)) and not Defined(CPUX86)}
  var Compute: TVulkanCompute;
  if TryCreateVulkanCompute(Compute, Result.HLEError, '', False, True) then
  try
    Result.HLEDevice := Compute.Name;
    Result.HLEAPIVersion := Compute.APIVersion;
    Result.HLE := HLEFormatsSupported(Compute);
    if not Result.HLE then
      Result.HLEError := 'The Vulkan device lacks the required colour or depth/stencil formats.';
  finally
    Compute.Free;
  end;
  if TryCreateVulkanCompute(Compute, Result.LLEError) then
  try
    Result.LLEDevice := Compute.Name;
    Result.LLEAPIVersion := Compute.APIVersion;
    try
      Result.LLE := QualifyGEVulkanLLE(Compute, Result.LLEError);
    except
      on E: Exception do
        Result.LLEError := E.Message;
    end;
  finally
    Compute.Free;
  end;
  {$ELSE}
  Result.HLEError := 'Vulkan GE rendering is unavailable on this host.';
  Result.LLEError := Result.HLEError;
  {$ENDIF}
end;

function PSPRendererSupport: TPSPRendererSupport;
begin
  // Device capabilities do not change while this process uses its Vulkan driver.
  SupportLock.Acquire;
  try
    if not SupportReady then
    begin
      CachedSupport := DetectPSPRendererSupport;
      SupportReady := True;
    end;
    Result := CachedSupport;
  finally
    SupportLock.Release;
  end;
end;

initialization
  SupportLock := TCriticalSection.Create;

finalization
  SupportLock.Free;

end.
